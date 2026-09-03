//! ACP protocol semantics above the JSON-RPC transport: session-update
//! normalization, permission-option policy, prompt `stopReason` terminals, and
//! the tool/approval reducer.
//!
//! Ports `ACPDefaultSessionUpdateNormalizer`, `ACPToolUpdateResultAdapter`,
//! `ACPPermissionOptionPolicy`, the Grok/Cursor/OpenCode adapters, and
//! `ACPAgentSessionController.terminalState(for:)`.

use std::collections::BTreeMap;

use agentry_proto::agent_host::v1::{
    ApprovalDecisionKind, ApprovalKind, ApprovalRequest, ApprovalRequestIdSource, RuntimeEvent,
    StreamResult, TurnCompleted, runtime_event,
};
use serde_json::{Map, Value, json};

use super::json::{
    extract_content_text, first_string, float_value, int_value, parse_object, serialize_json,
    sha256_uuid,
};
use super::permission::{
    approval_kind_for_tool_kind, is_repoprompt_server_identifier, is_strict_acp_repoprompt_match,
    repo_prompt_auto_approval_match,
};
use crate::agent_claude::tool_owned::REPO_PROMPT_MCP_SERVER_NAME;

/// `ACPProviderID`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AcpProviderId {
    OpenCode,
    Cursor,
    GrokBuild,
}

/// `OpenCodeAgentConfig.ToolProfile`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OpenCodeToolProfile {
    Headless,
    NoTools,
    AgentMode,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AcpPermissionOption {
    pub option_id: String,
    pub kind: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ToolCallPhase {
    Pending,
    Running,
    Completed,
    Failed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AcpSemanticState {
    pub tools: BTreeMap<String, ToolCallPhase>,
    pub pending_approval_id: Option<String>,
    pub turn_terminal: Option<String>,
}

impl Default for AcpSemanticState {
    fn default() -> Self {
        Self {
            tools: BTreeMap::new(),
            pending_approval_id: None,
            turn_terminal: None,
        }
    }
}

impl AcpSemanticState {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// Absorbing: a terminal turn ignores later updates.
    #[must_use]
    pub fn is_terminal(&self) -> bool {
        self.turn_terminal.is_some()
    }

    pub fn apply_events(&mut self, events: &[RuntimeEvent]) {
        if self.is_terminal() {
            return;
        }
        for event in events {
            match event.kind.as_ref() {
                Some(runtime_event::Kind::Stream(stream)) => match stream.item_type.as_str() {
                    "tool_call" => {
                        if let Some(id) = stream.tool_invocation_id.as_ref() {
                            self.tools
                                .entry(id.clone())
                                .or_insert(ToolCallPhase::Pending);
                        }
                    }
                    "tool_result" => {
                        if let Some(id) = stream.tool_invocation_id.as_ref() {
                            let next = if stream.tool_is_error == Some(true) {
                                ToolCallPhase::Failed
                            } else if stream
                                .tool_result_json
                                .as_deref()
                                .is_some_and(|json| json.contains("\"status\":\"running\""))
                            {
                                ToolCallPhase::Running
                            } else if stream
                                .tool_result_json
                                .as_deref()
                                .is_some_and(|json| json.contains("\"status\":\"pending\""))
                            {
                                ToolCallPhase::Pending
                            } else {
                                ToolCallPhase::Completed
                            };
                            let current = self.tools.entry(id.clone()).or_insert(next);
                            if !matches!(*current, ToolCallPhase::Completed | ToolCallPhase::Failed)
                            {
                                *current = next;
                            }
                        }
                    }
                    _ => {}
                },
                Some(runtime_event::Kind::ApprovalRequest(request)) => {
                    if self.pending_approval_id.is_none() {
                        self.pending_approval_id = Some(request.approval_id.clone());
                    }
                }
                Some(runtime_event::Kind::ApprovalCancelled(_)) => {
                    self.pending_approval_id = None;
                }
                Some(runtime_event::Kind::TurnCompleted(completed)) => {
                    self.turn_terminal = Some(completed.stop_reason.clone());
                    self.pending_approval_id = None;
                }
                _ => {}
            }
        }
    }

    pub fn settle_approval(&mut self, approval_id: &str) -> bool {
        if self.pending_approval_id.as_deref() == Some(approval_id) {
            self.pending_approval_id = None;
            true
        } else {
            false
        }
    }
}

/// Normalize a `session/update` payload into provider-neutral `RuntimeEvent`s.
#[must_use]
pub fn normalize_session_update(
    payload_json: &str,
    provider: AcpProviderId,
    fallback_tool_call_id: &str,
    run_id: &str,
    turn_id: &str,
    open_code_profile: OpenCodeToolProfile,
) -> Vec<RuntimeEvent> {
    let Some(payload) = parse_object(payload_json) else {
        return Vec::new();
    };
    let events = match provider {
        AcpProviderId::GrokBuild => normalize_grok(&payload, fallback_tool_call_id),
        AcpProviderId::Cursor => normalize_cursor(&payload, fallback_tool_call_id),
        AcpProviderId::OpenCode => {
            normalize_open_code(&payload, fallback_tool_call_id, open_code_profile)
        }
    };
    events
        .into_iter()
        .map(|kind| RuntimeEvent {
            run_id: run_id.to_string(),
            turn_id: turn_id.to_string(),
            kind: Some(kind),
        })
        .collect()
}

fn normalize_grok(
    payload: &Map<String, Value>,
    fallback_tool_call_id: &str,
) -> Vec<runtime_event::Kind> {
    let session_update = first_string(payload, &["sessionUpdate"]).map(|value| value.to_ascii_lowercase());
    match session_update.as_deref() {
        Some("tool_call" | "tool_call_update") => {
            let adapted = adapted_terminal_tool_update(payload, session_update.as_deref().unwrap());
            normalize_default(&adapted, fallback_tool_call_id)
        }
        _ => normalize_default(payload, fallback_tool_call_id),
    }
}

fn normalize_cursor(
    payload: &Map<String, Value>,
    fallback_tool_call_id: &str,
) -> Vec<runtime_event::Kind> {
    let session_update = first_string(payload, &["sessionUpdate"]).map(|value| value.to_ascii_lowercase());
    match session_update.as_deref() {
        Some("tool_call" | "tool_call_update") => {
            if should_suppress_placeholder_tool(payload) {
                return Vec::new();
            }
            let adapted = adapted_terminal_tool_update(payload, session_update.as_deref().unwrap());
            normalize_default(&adapted, fallback_tool_call_id)
        }
        _ => normalize_default(payload, fallback_tool_call_id),
    }
}

fn normalize_open_code(
    payload: &Map<String, Value>,
    fallback_tool_call_id: &str,
    profile: OpenCodeToolProfile,
) -> Vec<runtime_event::Kind> {
    let session_update = first_string(payload, &["sessionUpdate"]).map(|value| value.to_ascii_lowercase());
    match session_update.as_deref() {
        Some("session_info_update") => {
            if should_suppress_open_code_status(payload) {
                return Vec::new();
            }
            normalize_default(payload, fallback_tool_call_id)
        }
        Some("tool_call") => normalize_open_code_tool(payload, fallback_tool_call_id, profile, true),
        Some("tool_call_update") => {
            normalize_open_code_tool(payload, fallback_tool_call_id, profile, false)
        }
        _ => normalize_default(payload, fallback_tool_call_id),
    }
}

fn normalize_default(
    payload: &Map<String, Value>,
    fallback_tool_call_id: &str,
) -> Vec<runtime_event::Kind> {
    let Some(session_update) = first_string(payload, &["sessionUpdate"]).map(|value| value.to_ascii_lowercase())
    else {
        return Vec::new();
    };
    match session_update.as_str() {
        "agent_message_chunk" => {
            let Some(text) = payload
                .get("content")
                .and_then(extract_content_text)
                .filter(|text| !text.is_empty())
            else {
                return Vec::new();
            };
            let message_id = first_string(payload, &["messageId", "messageID"])
                .filter(|value| !value.is_empty());
            vec![runtime_event::Kind::Stream(StreamResult {
                item_type: "content".to_string(),
                text: Some(text),
                content_message_id: message_id,
                ..empty_stream()
            })]
        }
        "agent_thought_chunk" => {
            let Some(text) = payload
                .get("content")
                .and_then(extract_content_text)
                .filter(|text| !text.is_empty())
            else {
                return Vec::new();
            };
            vec![runtime_event::Kind::Stream(StreamResult {
                item_type: "reasoning".to_string(),
                reasoning: Some(text),
                ..empty_stream()
            })]
        }
        "tool_call" => normalize_tool_call(payload, fallback_tool_call_id),
        "tool_call_update" => normalize_tool_call_update(payload, fallback_tool_call_id),
        "usage_update" => normalize_usage(payload),
        "session_info_update" => {
            if let Some(title) = first_string(payload, &["title"]).filter(|value| !value.is_empty()) {
                vec![runtime_event::Kind::Stream(StreamResult {
                    item_type: "status".to_string(),
                    text: Some(title),
                    ..empty_stream()
                })]
            } else {
                Vec::new()
            }
        }
        "available_commands_update" | "plan" | "user_message_chunk" => Vec::new(),
        _ => Vec::new(),
    }
}

fn normalize_tool_call(
    payload: &Map<String, Value>,
    fallback_tool_call_id: &str,
) -> Vec<runtime_event::Kind> {
    let tool_call_id = first_string(payload, &["toolCallId"])
        .unwrap_or_else(|| fallback_tool_call_id.to_string());
    let tool_name = normalized_tool_name(payload);
    let args_json = payload.get("rawInput").and_then(serialize_json);
    vec![runtime_event::Kind::Stream(StreamResult {
        item_type: "tool_call".to_string(),
        tool_name: Some(tool_name),
        tool_args: args_json.clone(),
        tool_args_json: args_json,
        tool_invocation_id: Some(stable_invocation_id(&tool_call_id)),
        ..empty_stream()
    })]
}

fn normalize_tool_call_update(
    payload: &Map<String, Value>,
    fallback_tool_call_id: &str,
) -> Vec<runtime_event::Kind> {
    let tool_call_id = first_string(payload, &["toolCallId"])
        .unwrap_or_else(|| fallback_tool_call_id.to_string());
    let tool_name = normalized_tool_name(payload);
    let invocation_id = stable_invocation_id(&tool_call_id);
    let status = first_string(payload, &["status"]).map(|value| value.to_ascii_lowercase());
    let args_json = payload.get("rawInput").and_then(serialize_json);
    let output_json = payload
        .get("rawOutput")
        .and_then(serialize_json)
        .or_else(|| payload.get("content").and_then(serialize_json))
        .or_else(|| payload.get("content").and_then(extract_content_text));
    let title = first_string(payload, &["title"]);
    let progress_text = payload
        .get("content")
        .and_then(extract_content_text)
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty());

    if matches!(status.as_deref(), Some("completed" | "failed")) {
        return vec![runtime_event::Kind::Stream(StreamResult {
            item_type: "tool_result".to_string(),
            tool_name: Some(tool_name),
            tool_args: args_json.clone(),
            tool_args_json: args_json,
            tool_output: output_json.clone(),
            tool_result_json: output_json,
            tool_invocation_id: Some(invocation_id),
            tool_is_error: Some(status.as_deref() == Some("failed")),
            ..empty_stream()
        })];
    }

    if let Some(lifecycle) = durable_lifecycle_status(status.as_deref()) {
        let result_json = durable_lifecycle_result_json(
            &lifecycle,
            title.as_deref(),
            progress_text.as_deref(),
            payload.get("content"),
            payload.get("rawInput"),
        );
        return vec![runtime_event::Kind::Stream(StreamResult {
            item_type: "tool_result".to_string(),
            tool_name: Some(tool_name),
            tool_args: args_json.clone(),
            tool_args_json: args_json,
            tool_output: Some(result_json.clone()),
            tool_result_json: Some(result_json),
            tool_invocation_id: Some(invocation_id),
            tool_is_error: Some(false),
            ..empty_stream()
        })];
    }

    Vec::new()
}

fn normalize_usage(payload: &Map<String, Value>) -> Vec<runtime_event::Kind> {
    let used = payload.get("used").and_then(int_value).and_then(|value| u64::try_from(value).ok());
    let size = payload.get("size").and_then(int_value).and_then(|value| u64::try_from(value).ok());
    let cost = payload.get("cost").and_then(|value| {
        value
            .as_object()
            .and_then(|object| object.get("amount"))
            .and_then(float_value)
            .or_else(|| float_value(value))
    });
    if used.is_none() && size.is_none() && cost.is_none() {
        return Vec::new();
    }
    vec![runtime_event::Kind::Stream(StreamResult {
        item_type: "usage".to_string(),
        cost,
        model_context_window: size,
        context_used_tokens: used,
        ..empty_stream()
    })]
}

fn durable_lifecycle_status(status: Option<&str>) -> Option<String> {
    let status = status?.trim().to_ascii_lowercase();
    if status.is_empty() {
        return None;
    }
    match status.as_str() {
        "in_progress" | "inprogress" | "in-progress" | "running" => Some("running".to_string()),
        "pending" => Some("pending".to_string()),
        _ => None,
    }
}

fn durable_lifecycle_result_json(
    status: &str,
    title: Option<&str>,
    progress_text: Option<&str>,
    raw_content: Option<&Value>,
    raw_input: Option<&Value>,
) -> String {
    let mut payload = json!({"status": status});
    if let Some(object) = payload.as_object_mut() {
        if let Some(title) = title.filter(|value| !value.is_empty()) {
            object.insert("title".to_string(), Value::String(title.to_string()));
        }
        if let Some(progress) = progress_text.filter(|value| !value.is_empty()) {
            object.insert("progress".to_string(), Value::String(progress.to_string()));
        }
        if let Some(content) = raw_content {
            object.insert("content".to_string(), content.clone());
        }
        if let Some(input) = raw_input {
            object.insert("rawInput".to_string(), input.clone());
        }
    }
    serialize_json(&payload).unwrap_or_else(|| format!(r#"{{"status":"{status}"}}"#))
}

fn adapted_terminal_tool_update(
    payload: &Map<String, Value>,
    session_update: &str,
) -> Map<String, Value> {
    let status = first_string(payload, &["status"]).map(|value| value.to_ascii_lowercase());
    if session_update != "tool_call_update"
        || !matches!(status.as_deref(), Some("completed" | "failed"))
    {
        return payload.clone();
    }
    let status = status.unwrap();
    let result_payload = terminal_result_payload(payload, &status);
    let mut adapted = payload.clone();
    if result_payload
        .get("status")
        .and_then(Value::as_str)
        .is_some_and(|value| value.eq_ignore_ascii_case("failed"))
    {
        adapted.insert("status".to_string(), Value::String("failed".to_string()));
    }
    adapted.insert("rawOutput".to_string(), Value::Object(result_payload));
    adapted
}

fn terminal_result_payload(payload: &Map<String, Value>, status: &str) -> Map<String, Value> {
    let failed = status == "failed" || raw_output_indicates_failure(payload.get("rawOutput"));
    let mut result = Map::new();
    result.insert(
        "status".to_string(),
        Value::String(if failed { "failed" } else { "success" }.to_string()),
    );
    result.insert("acp_status".to_string(), Value::String(status.to_string()));
    if let Some(title) = first_string(payload, &["title"]).filter(|value| !value.is_empty()) {
        result.insert("title".to_string(), Value::String(title));
    }
    if let Some(kind) =
        first_string(payload, &["kind", "toolKind"]).filter(|value| !value.is_empty())
    {
        result.insert("kind".to_string(), Value::String(kind));
    }
    if let Some(raw_output) = payload.get("rawOutput") {
        result.insert("rawOutput".to_string(), raw_output.clone());
    }
    if let Some(content) = payload.get("content") {
        result.insert("content".to_string(), content.clone());
    }
    if let Some(raw_input) = payload.get("rawInput")
        && value_is_meaningful(raw_input)
    {
        result.insert("rawInput".to_string(), raw_input.clone());
    }
    result
}

fn raw_output_indicates_failure(value: Option<&Value>) -> bool {
    let Some(object) = value.and_then(Value::as_object) else {
        return false;
    };
    if object.get("success").and_then(Value::as_bool) == Some(false) {
        return true;
    }
    if let Some(status) = first_string(object, &["status", "result", "outcome", "state"]) {
        let lowered = status.trim().to_ascii_lowercase();
        if matches!(
            lowered.as_str(),
            "failed" | "failure" | "error" | "cancelled" | "canceled"
        ) {
            return true;
        }
    }
    for key in ["exitCode", "exit_code", "code"] {
        if let Some(code) = object.get(key).and_then(int_value)
            && code != 0
        {
            return true;
        }
    }
    for key in ["error", "errorMessage", "error_message"] {
        if object
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|message| !message.trim().is_empty())
        {
            return true;
        }
    }
    false
}

fn value_is_meaningful(value: &Value) -> bool {
    match value {
        Value::String(text) => !text.trim().is_empty(),
        Value::Array(items) => items.iter().any(value_is_meaningful),
        Value::Object(object) => object.values().any(value_is_meaningful),
        Value::Null => false,
        _ => true,
    }
}

fn should_suppress_placeholder_tool(payload: &Map<String, Value>) -> bool {
    let normalized = normalized_tool_name(payload)
        .trim()
        .to_ascii_lowercase();
    if normalized != "other" && normalized != "tool" {
        return false;
    }
    !has_meaningful_placeholder_payload(payload)
}

fn has_meaningful_placeholder_payload(payload: &Map<String, Value>) -> bool {
    if payload.get("rawInput").is_some_and(value_is_meaningful) {
        return true;
    }
    if payload
        .get("rawOutput")
        .is_some_and(raw_output_is_meaningful)
    {
        return true;
    }
    payload.get("content").is_some_and(value_is_meaningful)
}

fn raw_output_is_meaningful(value: &Value) -> bool {
    if let Some(object) = value.as_object() {
        if raw_output_indicates_failure(Some(value)) {
            return true;
        }
        let meaningful_keys: Vec<&String> = object
            .keys()
            .filter(|key| {
                let normalized = key.trim().to_ascii_lowercase();
                normalized != "success" && normalized != "status"
            })
            .collect();
        if meaningful_keys.is_empty() {
            return false;
        }
        return meaningful_keys
            .iter()
            .any(|key| object.get(*key).is_some_and(value_is_meaningful));
    }
    value_is_meaningful(value)
}

fn normalize_open_code_tool(
    payload: &Map<String, Value>,
    fallback_tool_call_id: &str,
    profile: OpenCodeToolProfile,
    is_call: bool,
) -> Vec<runtime_event::Kind> {
    let is_repo_prompt = is_repoprompt_tool_payload(payload);
    let status = first_string(payload, &["status"]).map(|value| {
        value
            .trim()
            .to_ascii_lowercase()
    });
    let has_terminal_failure = is_terminal_failure_status(status.as_deref());
    let is_terminal = status.as_deref() == Some("completed") || has_terminal_failure;
    let is_failure = has_terminal_failure || raw_output_indicates_failure(payload.get("rawOutput"));
    let canonical = if is_repo_prompt {
        None
    } else {
        canonical_open_code_tool_name(payload)
    };
    if should_suppress_open_code_tool(
        payload,
        canonical.as_deref(),
        profile,
        is_call,
        is_repo_prompt,
        is_terminal,
        is_failure,
    ) {
        return Vec::new();
    }
    let adapted = adapted_open_code_payload(payload, canonical.as_deref(), is_repo_prompt);
    normalize_default(&adapted, fallback_tool_call_id)
}

fn should_suppress_open_code_tool(
    payload: &Map<String, Value>,
    canonical_tool_name: Option<&str>,
    profile: OpenCodeToolProfile,
    is_call: bool,
    is_repo_prompt: bool,
    is_terminal: bool,
    is_failure: bool,
) -> bool {
    if is_repo_prompt {
        return false;
    }
    match profile {
        OpenCodeToolProfile::Headless | OpenCodeToolProfile::NoTools => {
            if is_terminal && is_failure {
                return !has_meaningful_failure_payload(payload);
            }
            true
        }
        OpenCodeToolProfile::AgentMode => {
            if is_terminal && is_failure && has_meaningful_failure_payload(payload) {
                return false;
            }
            if canonical_tool_name.is_some() {
                if !is_call && !is_terminal && !has_meaningful_payload(payload) {
                    return true;
                }
                return false;
            }
            if is_path_like_or_code_like_title(first_string(
                payload,
                &["title", "toolName", "name", "tool", "kind", "toolKind"],
            )) {
                return true;
            }
            !has_meaningful_payload(payload)
        }
    }
}

fn should_suppress_open_code_status(payload: &Map<String, Value>) -> bool {
    let Some(title) = first_string(payload, &["title"]) else {
        return true;
    };
    is_path_like_or_code_like_title(Some(title))
}

fn adapted_open_code_payload(
    payload: &Map<String, Value>,
    canonical_tool_name: Option<&str>,
    is_repo_prompt: bool,
) -> Map<String, Value> {
    let mut adapted = payload.clone();
    if let Some(status) = first_string(payload, &["status"]).map(|value| value.to_ascii_lowercase())
        && matches!(status.as_str(), "error" | "cancelled" | "canceled")
    {
        adapted.insert("status".to_string(), Value::String("failed".to_string()));
    }
    if !is_repo_prompt && let Some(name) = canonical_tool_name {
        adapted.insert("title".to_string(), Value::String(name.to_string()));
        adapted.insert("toolName".to_string(), Value::String(name.to_string()));
    }
    adapted
}

fn is_terminal_failure_status(status: Option<&str>) -> bool {
    matches!(status, Some("failed" | "error" | "cancelled" | "canceled"))
}

fn is_repoprompt_tool_payload(payload: &Map<String, Value>) -> bool {
    if repo_prompt_tool_name_from_title(payload).is_some() {
        return true;
    }
    for key in ["toolName", "name", "tool", "title", "kind", "toolKind"] {
        let Some(value) = first_string(payload, &[key]) else {
            continue;
        };
        if explicit_repoprompt_tool_name(&value).is_some() {
            return true;
        }
        let normalized = value.trim().to_ascii_lowercase();
        if normalized.contains("repoprompt")
            && (normalized.contains("tool")
                || normalized.contains("mcp")
                || normalized.contains("server"))
        {
            return true;
        }
    }
    false
}

fn canonical_open_code_tool_name(payload: &Map<String, Value>) -> Option<String> {
    let identifiers: Vec<String> = ["kind", "toolKind", "toolName", "name", "tool", "title"]
        .iter()
        .filter_map(|key| first_string(payload, &[key]))
        .map(|value| normalized_token(&value))
        .collect();
    let raw_input = payload.get("rawInput").and_then(Value::as_object);
    let raw_input_text = payload
        .get("rawInput")
        .and_then(serialize_json)
        .unwrap_or_default()
        .to_ascii_lowercase();

    if identifiers.iter().any(|value| {
        matches_any(value, &["execute", "bash", "shell", "terminal", "command", "run"])
    }) || has_any_key(raw_input, &["command", "cmd", "script", "shell"])
    {
        return Some("bash".to_string());
    }
    if identifiers
        .iter()
        .any(|value| matches_any(value, &["edit", "write", "patch", "update", "modify"]))
        || has_any_key(
            raw_input,
            &[
                "oldString",
                "newString",
                "replacement",
                "replace",
                "content",
                "diff",
                "patch",
            ],
        )
    {
        return Some("edit".to_string());
    }
    if identifiers
        .iter()
        .any(|value| matches_any(value, &["search", "grep", "glob", "codesearch", "find"]))
        || has_any_key(raw_input, &["pattern", "query", "glob", "regex", "needle"])
    {
        return Some("search".to_string());
    }
    if identifiers
        .iter()
        .any(|value| matches_any(value, &["webfetch", "web-fetch", "fetch", "http"]))
        || has_any_key(raw_input, &["url", "uri"])
    {
        return Some("webfetch".to_string());
    }
    if identifiers
        .iter()
        .any(|value| matches_any(value, &["websearch", "web-search"]))
    {
        return Some("websearch".to_string());
    }
    if identifiers
        .iter()
        .any(|value| matches_any(value, &["todo", "todowrite", "todo-write"]))
    {
        return Some("todowrite".to_string());
    }
    if identifiers
        .iter()
        .any(|value| matches_any(value, &["read", "view", "open", "cat"]))
        || (has_any_key(raw_input, &["path", "filePath", "filepath"])
            && !raw_input_text.contains("oldstring")
            && !raw_input_text.contains("newstring"))
    {
        return Some("read".to_string());
    }
    None
}

fn matches_any(value: &str, tokens: &[&str]) -> bool {
    tokens.iter().any(|token| value == *token)
}

fn has_any_key(object: Option<&Map<String, Value>>, keys: &[&str]) -> bool {
    let Some(object) = object else {
        return false;
    };
    keys.iter().any(|key| object.contains_key(*key))
}

fn normalized_token(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

fn has_meaningful_payload(payload: &Map<String, Value>) -> bool {
    payload.get("rawInput").is_some_and(value_is_meaningful)
        || payload.get("rawOutput").is_some_and(value_is_meaningful)
        || payload.get("content").is_some_and(value_is_meaningful)
}

fn has_meaningful_failure_payload(payload: &Map<String, Value>) -> bool {
    raw_output_indicates_failure(payload.get("rawOutput"))
        || payload
            .get("rawOutput")
            .is_some_and(value_is_meaningful)
        || payload.get("content").is_some_and(value_is_meaningful)
}

fn is_path_like_or_code_like_title(title: Option<String>) -> bool {
    let Some(title) = title.filter(|value| !value.trim().is_empty()) else {
        return false;
    };
    let trimmed = title.trim();
    trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains('.')
        || trimmed.contains('(')
}

fn empty_stream() -> StreamResult {
    StreamResult {
        item_type: String::new(),
        text: None,
        reasoning: None,
        prompt_tokens: None,
        completion_tokens: None,
        cost: None,
        tool_name: None,
        tool_args: None,
        tool_output: None,
        tool_invocation_id: None,
        tool_result_json: None,
        tool_args_json: None,
        tool_is_error: None,
        provider_session_id: None,
        stop_reason: None,
        model_context_window: None,
        context_used_tokens: None,
        content_message_id: None,
    }
}

fn stable_invocation_id(tool_call_id: &str) -> String {
    sha256_uuid(&format!("acp-tool|{tool_call_id}"))
}

fn normalized_tool_name(payload: &Map<String, Value>) -> String {
    if let Some(name) = repo_prompt_tool_name_from_title(payload) {
        return name;
    }
    if let Some(identifier) = first_machine_identifier(payload, &["toolName", "name", "tool"]) {
        return explicit_repoprompt_tool_name(&identifier).unwrap_or(identifier);
    }
    if let Some(title) = first_string(payload, &["title"])
        && is_machine_identifier(&title)
    {
        return explicit_repoprompt_tool_name(&title).unwrap_or(title);
    }
    if let Some(kind) = first_machine_identifier(payload, &["toolKind", "kind"]) {
        return explicit_repoprompt_tool_name(&kind).unwrap_or(kind);
    }
    if let Some(title) = first_string(payload, &["title"]) {
        return title;
    }
    "tool".to_string()
}

fn repo_prompt_tool_name_from_title(payload: &Map<String, Value>) -> Option<String> {
    let raw_title = first_string(payload, &["title"])?;
    repo_prompt_tool_name_from_parenthesized(&raw_title)
        .or_else(|| repo_prompt_tool_name_from_prefixed(&raw_title))
}

fn repo_prompt_tool_name_from_parenthesized(raw_title: &str) -> Option<String> {
    // Swift: /^([A-Za-z0-9_.:\/-]+)\s+\((.+)\)$/
    if !raw_title.ends_with(')') {
        return None;
    }
    let open = raw_title.rfind('(')?;
    if open == 0 {
        return None;
    }
    let prefix = &raw_title[..open];
    let tool_name = prefix.trim_end();
    if tool_name.is_empty()
        || !is_machine_identifier(tool_name)
        || !prefix.starts_with(tool_name)
        || prefix[tool_name.len()..].is_empty()
        || !prefix[tool_name.len()..].chars().all(char::is_whitespace)
    {
        return None;
    }
    let server_name = &raw_title[open + 1..raw_title.len() - 1];
    if !is_repoprompt_server_identifier(Some(server_name)) {
        return None;
    }
    let canonical = canonical_repoprompt_name(tool_name)?;
    Some(explicit_name(&canonical))
}

fn repo_prompt_tool_name_from_prefixed(raw_title: &str) -> Option<String> {
    let trimmed = raw_title.trim();
    let prefix = format!("{}-", REPO_PROMPT_MCP_SERVER_NAME.to_ascii_lowercase());
    if !trimmed.to_ascii_lowercase().starts_with(&prefix) {
        return None;
    }
    let body = trimmed[prefix.len()..].trim();
    let mut candidates = vec![body.to_string()];
    if let Some((head, tail)) = body.split_once(':') {
        candidates.insert(0, head.trim().to_string());
        candidates.insert(1, tail.trim().to_string());
    }
    for candidate in candidates {
        if let Some(canonical) = canonical_repoprompt_name(&candidate) {
            return Some(explicit_name(&canonical));
        }
    }
    None
}

fn explicit_repoprompt_tool_name(raw_name: &str) -> Option<String> {
    let resolved = crate::agent_claude::tool_owned::resolve_repoprompt_tool_name(Some(raw_name))?;
    if !resolved.has_explicit_server_prefix {
        return None;
    }
    Some(explicit_name(resolved.canonical_name.as_ref()?))
}

fn explicit_name(canonical: &str) -> String {
    format!("mcp__{REPO_PROMPT_MCP_SERVER_NAME}__{canonical}")
}

fn first_machine_identifier(payload: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(value) = first_string(payload, &[key])
            && is_machine_identifier(&value)
        {
            return Some(value);
        }
    }
    None
}

fn is_machine_identifier(value: &str) -> bool {
    !value.is_empty()
        && !value.chars().any(char::is_whitespace)
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | ':' | '-' | '/'))
}

/// `ACPAgentSessionController.terminalState(for:)` mapped onto `TurnCompleted.stop_reason`.
#[must_use]
pub fn terminal_from_stop_reason(stop_reason: Option<&str>, turn_id: &str) -> TurnCompleted {
    let mapped = match stop_reason.map(str::trim).map(str::to_ascii_lowercase).as_deref() {
        Some("end_turn" | "max_tokens" | "max_turn_requests") => "completed",
        Some("cancelled") => "cancelled",
        Some("refusal") => "failed",
        _ => "completed",
    };
    TurnCompleted {
        turn_id: turn_id.to_string(),
        stop_reason: mapped.to_string(),
    }
}

#[must_use]
pub fn terminal_event(stop_reason: Option<&str>, run_id: &str, turn_id: &str) -> RuntimeEvent {
    RuntimeEvent {
        run_id: run_id.to_string(),
        turn_id: turn_id.to_string(),
        kind: Some(runtime_event::Kind::TurnCompleted(terminal_from_stop_reason(
            stop_reason,
            turn_id,
        ))),
    }
}

/// `ACPPermissionOptionPolicy`.
#[must_use]
pub fn normalized_option_value(value: Option<&str>) -> Option<String> {
    let normalized = value?.trim().to_ascii_lowercase();
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

#[must_use]
pub fn denylisted_auto_select_option_ids(provider: AcpProviderId) -> &'static [&'static str] {
    match provider {
        AcpProviderId::OpenCode | AcpProviderId::Cursor => &[],
        AcpProviderId::GrokBuild => &["enable-always-approve"],
    }
}

#[must_use]
pub fn is_auto_selectable(option_id: Option<&str>, provider: AcpProviderId) -> bool {
    let Some(normalized) = normalized_option_value(option_id) else {
        return false;
    };
    !denylisted_auto_select_option_ids(provider).contains(&normalized.as_str())
}

fn safe_options<'a>(
    options: &'a [AcpPermissionOption],
    provider: AcpProviderId,
) -> Vec<&'a AcpPermissionOption> {
    options
        .iter()
        .filter(|option| is_auto_selectable(Some(option.option_id.as_str()), provider))
        .collect()
}

enum Preference {
    OptionId(&'static str),
    Kind(&'static str),
}

fn option_id_for(
    options: &[&AcpPermissionOption],
    preferences: &[Preference],
) -> Option<String> {
    for preference in preferences {
        match *preference {
            Preference::OptionId(preferred) => {
                let Some(normalized) = normalized_option_value(Some(preferred)) else {
                    continue;
                };
                if let Some(option) = options.iter().find(|option| {
                    normalized_option_value(Some(option.option_id.as_str())).as_deref()
                        == Some(normalized.as_str())
                }) {
                    return Some(option.option_id.clone());
                }
            }
            Preference::Kind(preferred) => {
                let Some(normalized) = normalized_option_value(Some(preferred)) else {
                    continue;
                };
                if let Some(option) = options.iter().find(|option| {
                    normalized_option_value(Some(option.kind.as_str())).as_deref()
                        == Some(normalized.as_str())
                }) {
                    return Some(option.option_id.clone());
                }
            }
        }
    }
    None
}

fn generic_allow_preferences(session_scoped: bool) -> Vec<Preference> {
    if session_scoped {
        vec![
            Preference::OptionId("always"),
            Preference::OptionId("allow_always"),
            Preference::Kind("allow_always"),
            Preference::OptionId("once"),
            Preference::OptionId("allow_once"),
            Preference::Kind("allow_once"),
        ]
    } else {
        vec![
            Preference::OptionId("once"),
            Preference::OptionId("allow_once"),
            Preference::Kind("allow_once"),
            Preference::OptionId("always"),
            Preference::OptionId("allow_always"),
            Preference::Kind("allow_always"),
        ]
    }
}

fn grok_allow_preferences(session_scoped: bool) -> Vec<Preference> {
    if session_scoped {
        vec![
            Preference::OptionId("allow-edits-session"),
            Preference::OptionId("always"),
            Preference::OptionId("allow_always"),
            Preference::Kind("allow_always"),
        ]
    } else {
        vec![
            Preference::OptionId("allow-once"),
            Preference::OptionId("once"),
            Preference::OptionId("allow_once"),
            Preference::Kind("allow_once"),
        ]
    }
}

fn reject_preferences() -> Vec<Preference> {
    vec![
        Preference::OptionId("reject-once"),
        Preference::OptionId("reject_once"),
        Preference::OptionId("reject"),
        Preference::Kind("reject_once"),
        Preference::Kind("reject"),
        Preference::OptionId("reject_always"),
        Preference::OptionId("reject-always"),
        Preference::Kind("reject_always"),
        Preference::OptionId("deny_once"),
        Preference::OptionId("deny-once"),
        Preference::OptionId("deny"),
        Preference::Kind("deny_once"),
        Preference::Kind("deny"),
        Preference::OptionId("cancel"),
        Preference::Kind("cancel"),
    ]
}

#[must_use]
pub fn preferred_allow_option_id(
    options: &[AcpPermissionOption],
    provider: AcpProviderId,
    session_scoped: bool,
) -> String {
    let filtered = safe_options(options, provider);
    let preferences = match provider {
        AcpProviderId::OpenCode | AcpProviderId::Cursor => generic_allow_preferences(session_scoped),
        AcpProviderId::GrokBuild => grok_allow_preferences(session_scoped),
    };
    option_id_for(&filtered, &preferences)
        .or_else(|| filtered.first().map(|option| option.option_id.clone()))
        .unwrap_or_default()
}

#[must_use]
pub fn preferred_reject_option_id(options: &[AcpPermissionOption]) -> Option<String> {
    let refs: Vec<&AcpPermissionOption> = options.iter().collect();
    option_id_for(&refs, &reject_preferences())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AcpDecisionMapping {
    pub outcome: String,
    pub option_id: Option<String>,
}

/// `respondToPermissionRequest` decision → wire outcome (not UI).
#[must_use]
pub fn map_approval_decision(
    decision: ApprovalDecisionKind,
    options: &[AcpPermissionOption],
    provider: AcpProviderId,
) -> AcpDecisionMapping {
    match decision {
        ApprovalDecisionKind::Cancel => AcpDecisionMapping {
            outcome: "cancelled".to_string(),
            option_id: None,
        },
        ApprovalDecisionKind::Accept => AcpDecisionMapping {
            outcome: "selected".to_string(),
            option_id: Some(preferred_allow_option_id(options, provider, false))
                .filter(|value| !value.is_empty()),
        },
        ApprovalDecisionKind::AcceptForSession
        | ApprovalDecisionKind::AcceptWithExecpolicyAmendment => AcpDecisionMapping {
            outcome: "selected".to_string(),
            option_id: Some(preferred_allow_option_id(options, provider, true))
                .filter(|value| !value.is_empty()),
        },
        ApprovalDecisionKind::Decline => {
            if let Some(option_id) = preferred_reject_option_id(options) {
                AcpDecisionMapping {
                    outcome: "selected".to_string(),
                    option_id: Some(option_id),
                }
            } else {
                AcpDecisionMapping {
                    outcome: "cancelled".to_string(),
                    option_id: None,
                }
            }
        }
        ApprovalDecisionKind::Unspecified => AcpDecisionMapping {
            outcome: "cancelled".to_string(),
            option_id: None,
        },
    }
}

/// RepoPrompt auto-approval option for ACP (strict gate + denylist).
#[must_use]
pub fn auto_approval_option_id(
    request_tool_name: Option<&str>,
    payload_json: &str,
    options: &[AcpPermissionOption],
    provider: AcpProviderId,
) -> Option<String> {
    let payload = parse_object(payload_json).unwrap_or_default();
    let match_ = repo_prompt_auto_approval_match(request_tool_name, &payload)?;
    if !is_strict_acp_repoprompt_match(&match_, request_tool_name, &payload) {
        return None;
    }
    let preferences = match provider {
        AcpProviderId::OpenCode | AcpProviderId::Cursor => vec![
            Preference::OptionId("always"),
            Preference::OptionId("allow_always"),
            Preference::Kind("allow_always"),
            Preference::OptionId("once"),
            Preference::OptionId("allow_once"),
            Preference::Kind("allow_once"),
        ],
        AcpProviderId::GrokBuild => vec![
            Preference::OptionId("allow-once"),
            Preference::OptionId("once"),
            Preference::OptionId("allow_once"),
            Preference::Kind("allow_once"),
        ],
    };
    let filtered = safe_options(options, provider);
    option_id_for(&filtered, &preferences)
}

#[must_use]
pub fn approval_request_from_permission(
    request_id: &str,
    tool_call_id: &str,
    tool_title: Option<&str>,
    tool_kind: Option<&str>,
    raw_input_json: Option<&str>,
    cwd: &str,
    session_id: &str,
) -> ApprovalRequest {
    let kind = approval_kind_for_tool_kind(tool_kind);
    let approval_id = sha256_uuid(&format!(
        "approval-request|{request_id}|session/request_permission|{}|{session_id}|{session_id}|{tool_call_id}",
        kind_raw(kind)
    ));
    ApprovalRequest {
        approval_id,
        request_id: request_id.to_string(),
        request_id_source: ApprovalRequestIdSource::Acp as i32,
        method: "session/request_permission".to_string(),
        kind: kind as i32,
        thread_id: session_id.to_string(),
        turn_id: session_id.to_string(),
        item_id: tool_call_id.to_string(),
        reason: tool_title.unwrap_or_default().to_string(),
        command: raw_input_json
            .map(|value| vec![value.to_string()])
            .unwrap_or_default(),
        cwd: cwd.to_string(),
        grant_root: String::new(),
        proposed_execpolicy_amendment_json: String::new(),
        details: Vec::new(),
    }
}

fn kind_raw(kind: ApprovalKind) -> &'static str {
    match kind {
        ApprovalKind::CommandExecution => "commandExecution",
        ApprovalKind::FileChange => "fileChange",
        ApprovalKind::Unspecified => "unspecified",
    }
}

// Local alias so the parenthesized-title helper can call the existing resolver
// without expanding `tool_owned`'s public surface mid-port.
fn canonical_repoprompt_name(raw: &str) -> Option<String> {
    crate::agent_claude::tool_owned::resolve_repoprompt_tool_name(Some(raw))?.canonical_name
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_message_chunk_is_content() {
        let events = normalize_session_update(
            r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello from grok"}}"#,
            AcpProviderId::GrokBuild,
            "fallback",
            "run",
            "turn",
            OpenCodeToolProfile::AgentMode,
        );
        match events[0].kind.as_ref() {
            Some(runtime_event::Kind::Stream(stream)) => {
                assert_eq!(stream.item_type, "content");
                assert_eq!(stream.text.as_deref(), Some("hello from grok"));
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn turn_completed_update_is_ignored() {
        let events = normalize_session_update(
            r#"{"sessionUpdate":"turn_completed","usage":{"totalTokens":42}}"#,
            AcpProviderId::GrokBuild,
            "fallback",
            "run",
            "turn",
            OpenCodeToolProfile::AgentMode,
        );
        assert!(events.is_empty());
    }

    #[test]
    fn grok_enable_always_approve_is_not_auto_selectable() {
        assert!(!is_auto_selectable(Some("enable-always-approve"), AcpProviderId::GrokBuild));
        assert!(is_auto_selectable(Some("allow-once"), AcpProviderId::GrokBuild));
        assert!(is_auto_selectable(
            Some("  Enable-Always-Approve "),
            AcpProviderId::Cursor
        ));
        assert!(!is_auto_selectable(
            Some("  Enable-Always-Approve "),
            AcpProviderId::GrokBuild
        ));
    }

    #[test]
    fn stop_reason_maps_to_absorbing_terminal() {
        assert_eq!(
            terminal_from_stop_reason(Some("end_turn"), "t1").stop_reason,
            "completed"
        );
        assert_eq!(
            terminal_from_stop_reason(Some("cancelled"), "t1").stop_reason,
            "cancelled"
        );
        assert_eq!(
            terminal_from_stop_reason(Some("refusal"), "t1").stop_reason,
            "failed"
        );
        let mut state = AcpSemanticState::new();
        state.apply_events(&[terminal_event(Some("end_turn"), "run", "t1")]);
        assert!(state.is_terminal());
        state.apply_events(&[terminal_event(Some("cancelled"), "run", "t2")]);
        assert_eq!(state.turn_terminal.as_deref(), Some("completed"));
    }
}
