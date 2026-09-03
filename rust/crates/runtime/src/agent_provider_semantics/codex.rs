//! Codex app-server protocol semantics above the JSON-RPC transport:
//! notification classification, approval/permissions parse, model-option
//! negotiation, and the turn/tool/approval reducer.

use std::collections::{BTreeMap, BTreeSet};

use agentry_proto::agent_host::v1::{
    ApprovalDecisionKind, ApprovalKind, ApprovalRequest, ApprovalRequestIdSource, RuntimeError,
    RuntimeEvent, StreamResult, TurnCompleted, runtime_event,
};
use serde_json::{Map, Value, json};

use super::json::{
    first_string, parse_object, serialize_json, sha256_uuid,
};
use super::permission::approval_kind_for_method;

/// `CodexNativeSessionController.TurnStatus`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexTurnStatus {
    Idle,
    InFlight,
    Completed,
    Interrupted,
    Failed,
}

impl CodexTurnStatus {
    #[must_use]
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Interrupted | Self::Failed)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexToolPhase {
    Pending,
    Running,
    Completed,
    Failed,
}

impl CodexToolPhase {
    #[must_use]
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed)
    }
}

/// `classifyServerRequestMethod`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexServerRequestKind {
    RequestUserInput,
    AuthTokensRefresh,
    McpElicitation,
    Permissions,
    DynamicToolUnsupported,
    Approval,
    UnknownUnsupported,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, PartialOrd, Ord)]
pub enum CodexReasoningEffort {
    None,
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
    Ultra,
}

impl CodexReasoningEffort {
    pub const DISPLAY_ORDER: [Self; 8] = [
        Self::None,
        Self::Minimal,
        Self::Low,
        Self::Medium,
        Self::High,
        Self::Xhigh,
        Self::Max,
        Self::Ultra,
    ];

    #[must_use]
    pub fn parse(raw: Option<&str>) -> Option<Self> {
        match raw?.trim().to_ascii_lowercase().as_str() {
            "none" => Some(Self::None),
            "minimal" => Some(Self::Minimal),
            "low" => Some(Self::Low),
            "medium" => Some(Self::Medium),
            "high" => Some(Self::High),
            "xhigh" | "x-high" => Some(Self::Xhigh),
            "max" | "maximum" => Some(Self::Max),
            "ultra" => Some(Self::Ultra),
            _ => None,
        }
    }

    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Minimal => "minimal",
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::Xhigh => "xhigh",
            Self::Max => "max",
            Self::Ultra => "ultra",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexModelSpecifier {
    pub base_model: Option<String>,
    pub reasoning_effort: Option<CodexReasoningEffort>,
    pub service_tier: Option<String>,
}

impl CodexModelSpecifier {
    #[must_use]
    pub fn parse(raw: Option<&str>) -> Self {
        let (base_model, reasoning_effort, service_tier) = split_legacy_model_id(raw);
        let base_model = base_model.and_then(|value| {
            let trimmed = value.trim();
            if trimmed.is_empty() || trimmed.eq_ignore_ascii_case("default") {
                None
            } else {
                Some(trimmed.to_string())
            }
        });
        if base_model.is_none() {
            Self {
                base_model: None,
                reasoning_effort: None,
                service_tier: None,
            }
        } else {
            Self {
                base_model,
                reasoning_effort,
                service_tier,
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexModelOption {
    pub raw_value: String,
    pub display_name: String,
    pub is_placeholder_default: bool,
    pub is_provider_default: bool,
    pub supported_reasoning_efforts: Vec<CodexReasoningEffort>,
    pub default_reasoning_effort: Option<CodexReasoningEffort>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexSelection {
    pub model_raw: String,
    pub reasoning_effort: Option<CodexReasoningEffort>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexSemanticState {
    pub status: CodexTurnStatus,
    pub turn_id: Option<String>,
    pub active_turn_ids: BTreeSet<String>,
    pub tools: BTreeMap<String, CodexToolPhase>,
    pub pending_approval_id: Option<String>,
}

impl Default for CodexSemanticState {
    fn default() -> Self {
        Self {
            status: CodexTurnStatus::Idle,
            turn_id: None,
            active_turn_ids: BTreeSet::new(),
            tools: BTreeMap::new(),
            pending_approval_id: None,
        }
    }
}

impl CodexSemanticState {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    #[must_use]
    pub fn is_terminal(&self) -> bool {
        self.status.is_terminal()
    }

    /// Apply a classified notification/server-request and return emitted events.
    pub fn apply(
        &mut self,
        method: &str,
        params_json: &str,
        run_id: &str,
        request_id: Option<&str>,
    ) -> Vec<RuntimeEvent> {
        if self.is_terminal() && !is_turn_started(method) {
            return Vec::new();
        }
        let params = parse_object(params_json).unwrap_or_default();
        if is_turn_started(method) {
            let turn_id = turn_id_from_params(&params);
            if let Some(turn_id) = turn_id.clone() {
                self.active_turn_ids.insert(turn_id.clone());
                self.turn_id = Some(turn_id);
            }
            self.status = CodexTurnStatus::InFlight;
            self.pending_approval_id = None;
            return Vec::new();
        }
        if is_turn_completed(method) {
            return self.apply_turn_completed(&params, run_id);
        }
        if method == "codex/event/task_complete" {
            return Vec::new();
        }
        if let Some(kind) = classify_server_request(method) {
            return self.apply_server_request(kind, method, &params, run_id, request_id);
        }
        classify_stream_or_error(method, &params, run_id, self.turn_id.as_deref().unwrap_or(""))
    }

    fn apply_turn_completed(
        &mut self,
        params: &Map<String, Value>,
        run_id: &str,
    ) -> Vec<RuntimeEvent> {
        let turn_payload = params.get("turn").and_then(Value::as_object);
        let status_raw = turn_payload
            .and_then(|object| first_string(object, &["status"]))
            .unwrap_or_else(|| "completed".to_string());
        let status = map_turn_status(&status_raw);
        let parsed_turn_id = turn_payload
            .and_then(|object| first_string(object, &["id", "turn_id"]))
            .or_else(|| notification_turn_id(params));
        let turn_id = parsed_turn_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let was_active = turn_id
            .as_ref()
            .is_some_and(|id| self.active_turn_ids.contains(id));
        let tracking_uncertain = self.active_turn_ids.is_empty() || self.turn_id.is_none();
        let matches_current = turn_id.is_some() && turn_id == self.turn_id;
        let nil_completion = turn_id.is_none()
            && self.active_turn_ids.len() <= 1
            && self.turn_id.is_some();
        let accepted = was_active || matches_current || tracking_uncertain || nil_completion;
        let resolved = turn_id
            .clone()
            .or_else(|| if nil_completion { self.turn_id.clone() } else { None });
        if let Some(id) = turn_id.as_ref() {
            self.active_turn_ids.remove(id);
            if self.turn_id.as_ref() == Some(id) {
                self.turn_id = None;
            }
        } else if nil_completion {
            if let Some(id) = self.turn_id.clone() {
                self.active_turn_ids.remove(&id);
            }
            self.turn_id = None;
        }
        if !accepted {
            return Vec::new();
        }
        self.status = match status {
            "interrupted" => CodexTurnStatus::Interrupted,
            "failed" => CodexTurnStatus::Failed,
            _ => CodexTurnStatus::Completed,
        };
        self.pending_approval_id = None;
        vec![RuntimeEvent {
            run_id: run_id.to_string(),
            turn_id: resolved.clone().unwrap_or_default(),
            kind: Some(runtime_event::Kind::TurnCompleted(TurnCompleted {
                turn_id: resolved.unwrap_or_default(),
                stop_reason: status.to_string(),
            })),
        }]
    }

    fn apply_server_request(
        &mut self,
        kind: CodexServerRequestKind,
        method: &str,
        params: &Map<String, Value>,
        run_id: &str,
        request_id: Option<&str>,
    ) -> Vec<RuntimeEvent> {
        match kind {
            CodexServerRequestKind::Approval | CodexServerRequestKind::Permissions => {
                let Some(request_id) = request_id else {
                    return Vec::new();
                };
                let Some(request) = parse_approval_request(
                    request_id,
                    method,
                    params,
                    None,
                    self.turn_id.as_deref(),
                ) else {
                    return Vec::new();
                };
                if self.pending_approval_id.is_none() {
                    self.pending_approval_id = Some(request.approval_id.clone());
                }
                vec![RuntimeEvent {
                    run_id: run_id.to_string(),
                    turn_id: request.turn_id.clone(),
                    kind: Some(runtime_event::Kind::ApprovalRequest(request)),
                }]
            }
            _ => Vec::new(),
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

#[must_use]
pub fn classify_server_request(method: &str) -> Option<CodexServerRequestKind> {
    Some(match method {
        "item/tool/requestUserInput" => CodexServerRequestKind::RequestUserInput,
        "account/chatgptAuthTokens/refresh" => CodexServerRequestKind::AuthTokensRefresh,
        "mcpServer/elicitation/request" => CodexServerRequestKind::McpElicitation,
        "item/permissions/requestApproval" => CodexServerRequestKind::Permissions,
        "item/tool/call" => CodexServerRequestKind::DynamicToolUnsupported,
        "item/commandExecution/requestApproval"
        | "item/fileChange/requestApproval"
        | "applyPatchApproval"
        | "execCommandApproval" => CodexServerRequestKind::Approval,
        other if other.to_ascii_lowercase().contains("requestapproval") => {
            CodexServerRequestKind::Approval
        }
        _ => return None,
    })
}

#[must_use]
pub fn map_turn_status(raw: &str) -> &'static str {
    match raw.to_ascii_lowercase().as_str() {
        "completed" => "completed",
        "interrupted" => "interrupted",
        "failed" => "failed",
        _ => "completed",
    }
}

#[must_use]
pub fn parse_approval_request(
    request_id: &str,
    method: &str,
    params: &Map<String, Value>,
    active_thread_id: Option<&str>,
    current_turn_id: Option<&str>,
) -> Option<ApprovalRequest> {
    let explicit_thread = notification_thread_id(params).or_else(|| first_string(params, &["thread"]));
    if let (Some(active), Some(explicit)) = (active_thread_id, explicit_thread.as_deref())
        && explicit != active
    {
        return None;
    }
    let thread_id = explicit_thread
        .or_else(|| active_thread_id.map(ToString::to_string))
        .filter(|value| !value.is_empty())?;

    let explicit_turn = notification_turn_id(params);
    let turn_id = explicit_turn
        .clone()
        .or_else(|| current_turn_id.map(ToString::to_string))
        .unwrap_or_else(|| format!("turn:{request_id}"));
    let item_id = notification_item_id(params).unwrap_or_else(|| format!("item:{request_id}"));
    let stable_turn_id = explicit_turn.unwrap_or_else(|| format!("turn:{request_id}"));

    let reason = first_string(params, &["reason", "message", "prompt", "description"]).unwrap_or_default();
    let command = first_string(
        params,
        &[
            "command",
            "cmd",
            "rawCommand",
            "raw_command",
            "shellCommand",
            "shell_command",
            "argv",
            "args",
            "exec",
            "script",
        ],
    );
    let cwd = first_string(
        params,
        &[
            "cwd",
            "workingDirectory",
            "working_directory",
            "workdir",
            "directory",
        ],
    )
    .unwrap_or_default();
    let grant_root = first_string(params, &["grantRoot", "grant_root"]).unwrap_or_default();
    let amendment = first_json_string(
        params,
        &[
            "proposedExecpolicyAmendment",
            "proposed_execpolicy_amendment",
            "execpolicyAmendment",
            "execpolicy_amendment",
        ],
    )
    .unwrap_or_default();

    let kind = approval_kind_for_method(method, command.as_ref().is_some_and(|value| !value.is_empty()));
    let approval_id = sha256_uuid(&format!(
        "approval-request|{request_id}|{method}|{}|{thread_id}|{stable_turn_id}|{item_id}",
        kind_raw(kind)
    ));
    Some(ApprovalRequest {
        approval_id,
        request_id: request_id.to_string(),
        request_id_source: ApprovalRequestIdSource::Codex as i32,
        method: method.to_string(),
        kind: kind as i32,
        thread_id,
        turn_id,
        item_id,
        reason,
        command: command.into_iter().collect(),
        cwd,
        grant_root,
        proposed_execpolicy_amendment_json: amendment,
        details: Vec::new(),
    })
}

/// `buildApprovalResult`.
#[must_use]
pub fn build_approval_result(
    decision: ApprovalDecisionKind,
    kind: ApprovalKind,
    amendment_json: Option<&str>,
) -> String {
    match decision {
        ApprovalDecisionKind::Accept => json!({"decision": "accept"}).to_string(),
        ApprovalDecisionKind::Decline => json!({"decision": "decline"}).to_string(),
        ApprovalDecisionKind::Cancel => json!({"decision": "cancel"}).to_string(),
        ApprovalDecisionKind::AcceptForSession => {
            json!({"decision": "acceptForSession"}).to_string()
        }
        ApprovalDecisionKind::AcceptWithExecpolicyAmendment => {
            if kind != ApprovalKind::CommandExecution {
                return json!({"decision": "decline"}).to_string();
            }
            if let Some(raw) = amendment_json
                && let Ok(parsed) = serde_json::from_str::<Value>(raw)
            {
                return json!({
                    "decision": {
                        "acceptWithExecpolicyAmendment": {
                            "execpolicy_amendment": parsed
                        }
                    }
                })
                .to_string();
            }
            json!({"decision": "acceptForSession"}).to_string()
        }
        ApprovalDecisionKind::Unspecified => json!({"decision": "decline"}).to_string(),
    }
}

/// `buildPermissionsResult`.
#[must_use]
pub fn build_permissions_result(
    decision: ApprovalDecisionKind,
    permissions_json: &str,
) -> String {
    let permissions = serde_json::from_str::<Value>(permissions_json).unwrap_or(json!({}));
    let (permissions, scope) = match decision {
        ApprovalDecisionKind::Accept => (permissions, "turn"),
        ApprovalDecisionKind::AcceptForSession => (permissions, "session"),
        _ => (json!({}), "turn"),
    };
    json!({
        "permissions": permissions,
        "scope": scope,
        "strictAutoReview": false
    })
    .to_string()
}

#[must_use]
pub fn collapse_model_options(options: &[CodexModelOption]) -> Vec<CodexModelOption> {
    struct Collapsed {
        raw_value: String,
        display_name: String,
        is_placeholder_default: bool,
        is_provider_default: bool,
        supported: BTreeSet<CodexReasoningEffort>,
        default_effort: Option<CodexReasoningEffort>,
    }

    let mut by_raw: BTreeMap<String, Collapsed> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();

    for option in options {
        let specifier = CodexModelSpecifier::parse(Some(option.raw_value.as_str()));
        let normalized_raw = if option.is_placeholder_default {
            "default".to_string()
        } else {
            service_tier_aware_base_id(&option.raw_value)
        };
        let key = normalized_raw.to_ascii_lowercase();
        if !by_raw.contains_key(&key) {
            let is_default_placeholder = normalized_raw.eq_ignore_ascii_case("default");
            order.push(key.clone());
            by_raw.insert(
                key.clone(),
                Collapsed {
                    raw_value: normalized_raw.clone(),
                    display_name: if is_default_placeholder {
                        "Default".to_string()
                    } else {
                        codex_display_name(&normalized_raw)
                    },
                    is_placeholder_default: option.is_placeholder_default,
                    is_provider_default: option.is_provider_default,
                    supported: BTreeSet::new(),
                    default_effort: option.default_reasoning_effort,
                },
            );
        }
        if let Some(record) = by_raw.get_mut(&key) {
            if option.is_placeholder_default {
                record.is_placeholder_default = true;
            }
            if option.is_provider_default {
                record.is_provider_default = true;
            }
            if let Some(explicit) = option.default_reasoning_effort {
                record.default_effort = Some(explicit);
            }
            if let Some(parsed) = specifier.reasoning_effort {
                record.supported.insert(parsed);
                if option.is_provider_default {
                    record.default_effort = Some(parsed);
                }
            }
            for effort in &option.supported_reasoning_efforts {
                record.supported.insert(*effort);
            }
        }
    }

    let mut collapsed: Vec<CodexModelOption> = Vec::new();
    for key in &order {
        let Some(record) = by_raw.get(key) else {
            continue;
        };
        let ordered: Vec<CodexReasoningEffort> = CodexReasoningEffort::DISPLAY_ORDER
            .into_iter()
            .filter(|effort| record.supported.contains(effort))
            .collect();
        collapsed.push(CodexModelOption {
            raw_value: record.raw_value.clone(),
            display_name: record.display_name.clone(),
            is_placeholder_default: record.is_placeholder_default,
            is_provider_default: record.is_provider_default,
            supported_reasoning_efforts: ordered,
            default_reasoning_effort: record.default_effort,
        });
    }

    let insertion: BTreeMap<String, usize> = collapsed
        .iter()
        .enumerate()
        .map(|(index, option)| (option.raw_value.to_ascii_lowercase(), index))
        .collect();
    collapsed.sort_by(|lhs, rhs| {
        match (lhs.is_placeholder_default, rhs.is_placeholder_default) {
            (true, false) => return std::cmp::Ordering::Less,
            (false, true) => return std::cmp::Ordering::Greater,
            _ => {}
        }
        match codex_base_precedes(&lhs.raw_value, &rhs.raw_value) {
            std::cmp::Ordering::Equal => {}
            other => return other,
        }
        let left = insertion
            .get(&lhs.raw_value.to_ascii_lowercase())
            .copied()
            .unwrap_or(usize::MAX);
        let right = insertion
            .get(&rhs.raw_value.to_ascii_lowercase())
            .copied()
            .unwrap_or(usize::MAX);
        left.cmp(&right)
            .then_with(|| lhs.display_name.cmp(&rhs.display_name))
    });
    collapsed
}

#[must_use]
pub fn negotiate_selection(
    selected_model_raw: &str,
    explicit_effort: Option<&str>,
    last_used_effort: Option<&str>,
    supported: &[CodexReasoningEffort],
    default_effort: Option<CodexReasoningEffort>,
    preserving_explicit_effort: bool,
) -> CodexSelection {
    let specifier = CodexModelSpecifier::parse(Some(selected_model_raw));
    let model_raw = service_tier_aware_base_id(selected_model_raw);
    if supported.is_empty() {
        return CodexSelection {
            model_raw,
            reasoning_effort: None,
        };
    }
    let explicit = if preserving_explicit_effort {
        CodexReasoningEffort::parse(explicit_effort)
    } else {
        None
    };
    let parsed = specifier.reasoning_effort;
    let last_used = CodexReasoningEffort::parse(last_used_effort);
    let chosen = [explicit, parsed, last_used, default_effort]
        .into_iter()
        .flatten()
        .find(|effort| supported.contains(effort))
        .or_else(|| {
            if supported.contains(&CodexReasoningEffort::Medium) {
                Some(CodexReasoningEffort::Medium)
            } else {
                supported.first().copied()
            }
        });
    CodexSelection {
        model_raw,
        reasoning_effort: chosen,
    }
}

fn classify_stream_or_error(
    method: &str,
    params: &Map<String, Value>,
    run_id: &str,
    turn_id: &str,
) -> Vec<RuntimeEvent> {
    match method {
        "item/agentMessage/delta" | "codex/event/agent_message" => {
            let text = first_string(params, &["delta", "text", "message"]).filter(|value| !value.is_empty());
            let Some(text) = text else {
                return Vec::new();
            };
            vec![runtime_event_stream(
                run_id,
                turn_id,
                StreamResult {
                    item_type: "content".to_string(),
                    text: Some(text),
                    ..empty_stream()
                },
            )]
        }
        "item/reasoning/summaryTextDelta" | "item/reasoning/textDelta" => {
            let text = first_string(params, &["delta", "text"]).filter(|value| !value.is_empty());
            let Some(text) = text else {
                return Vec::new();
            };
            vec![runtime_event_stream(
                run_id,
                turn_id,
                StreamResult {
                    item_type: "reasoning".to_string(),
                    reasoning: Some(text),
                    ..empty_stream()
                },
            )]
        }
        "item/started" => classify_tool_item(params, run_id, turn_id, false),
        "item/completed" => classify_tool_item(params, run_id, turn_id, true),
        "error" => {
            let message = first_string(params, &["message", "error", "reason"])
                .unwrap_or_else(|| "Codex error".to_string());
            vec![RuntimeEvent {
                run_id: run_id.to_string(),
                turn_id: turn_id.to_string(),
                kind: Some(runtime_event::Kind::Error(RuntimeError {
                    code: "codex.error".to_string(),
                    message,
                    recoverable: false,
                })),
            }]
        }
        _ => Vec::new(),
    }
}

fn classify_tool_item(
    params: &Map<String, Value>,
    run_id: &str,
    turn_id: &str,
    completed: bool,
) -> Vec<RuntimeEvent> {
    let item = params
        .get("item")
        .and_then(Value::as_object)
        .unwrap_or(params);
    let tool_name = first_string(item, &["tool", "name", "toolName", "type"]).unwrap_or_else(|| "tool".to_string());
    let item_id = first_string(
        item,
        &[
            "id",
            "itemId",
            "item_id",
            "callId",
            "call_id",
            "invocationId",
            "invocation_id",
            "toolCallId",
            "tool_call_id",
        ],
    )
    .unwrap_or_else(|| tool_name.clone());
    let args = item
        .get("arguments")
        .or_else(|| item.get("args"))
        .or_else(|| item.get("input"))
        .and_then(serialize_json);
    if completed {
        let output = item
            .get("result")
            .or_else(|| item.get("output"))
            .or_else(|| item.get("content"))
            .and_then(serialize_json);
        let is_error = item.get("isError").and_then(Value::as_bool).unwrap_or(false);
        vec![runtime_event_stream(
            run_id,
            turn_id,
            StreamResult {
                item_type: "tool_result".to_string(),
                tool_name: Some(tool_name),
                tool_args: args.clone(),
                tool_args_json: args,
                tool_output: output.clone(),
                tool_result_json: output,
                tool_invocation_id: Some(item_id),
                tool_is_error: Some(is_error),
                ..empty_stream()
            },
        )]
    } else {
        vec![runtime_event_stream(
            run_id,
            turn_id,
            StreamResult {
                item_type: "tool_call".to_string(),
                tool_name: Some(tool_name),
                tool_args: args.clone(),
                tool_args_json: args,
                tool_invocation_id: Some(item_id),
                ..empty_stream()
            },
        )]
    }
}

fn runtime_event_stream(run_id: &str, turn_id: &str, stream: StreamResult) -> RuntimeEvent {
    RuntimeEvent {
        run_id: run_id.to_string(),
        turn_id: turn_id.to_string(),
        kind: Some(runtime_event::Kind::Stream(stream)),
    }
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

fn is_turn_started(method: &str) -> bool {
    matches!(method, "turn/started" | "codex/event/turn_started")
}

fn is_turn_completed(method: &str) -> bool {
    matches!(method, "turn/completed" | "codex/event/turn_completed")
}

fn turn_id_from_params(params: &Map<String, Value>) -> Option<String> {
    params
        .get("turn")
        .and_then(Value::as_object)
        .and_then(|object| first_string(object, &["id", "turn_id"]))
        .or_else(|| notification_turn_id(params))
}

fn notification_thread_id(params: &Map<String, Value>) -> Option<String> {
    first_string(params, &["threadId", "thread_id", "threadID"])
        .or_else(|| {
            params
                .get("thread")
                .and_then(Value::as_object)
                .and_then(|object| first_string(object, &["id", "threadId", "thread_id"]))
        })
}

fn notification_turn_id(params: &Map<String, Value>) -> Option<String> {
    first_string(params, &["turnId", "turn_id", "turnID"]).or_else(|| {
        params
            .get("turn")
            .and_then(Value::as_object)
            .and_then(|object| first_string(object, &["id", "turnId", "turn_id"]))
    })
}

fn notification_item_id(params: &Map<String, Value>) -> Option<String> {
    first_string(params, &["itemId", "item_id", "itemID", "id"]).or_else(|| {
        params
            .get("item")
            .and_then(Value::as_object)
            .and_then(|object| first_string(object, &["id", "itemId", "item_id"]))
    })
}

fn first_json_string(params: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(value) = params.get(*key) {
            if let Some(text) = value.as_str() {
                return Some(text.to_string());
            }
            if let Ok(encoded) = serde_json::to_string(value) {
                return Some(encoded);
            }
        }
    }
    None
}

fn kind_raw(kind: ApprovalKind) -> &'static str {
    match kind {
        ApprovalKind::CommandExecution => "commandExecution",
        ApprovalKind::FileChange => "fileChange",
        ApprovalKind::Unspecified => "unspecified",
    }
}

fn split_legacy_model_id(
    raw: Option<&str>,
) -> (Option<String>, Option<CodexReasoningEffort>, Option<String>) {
    let Some(raw) = raw.map(str::trim).filter(|value| !value.is_empty()) else {
        return (None, None, None);
    };
    if raw.eq_ignore_ascii_case("default") {
        return (None, None, None);
    }
    let suffixes: &[(&str, CodexReasoningEffort, bool)] = &[
        ("-xhigh", CodexReasoningEffort::Xhigh, false),
        ("-maximum", CodexReasoningEffort::Max, true),
        ("-ultra", CodexReasoningEffort::Ultra, true),
        ("-max", CodexReasoningEffort::Max, true),
        ("-medium", CodexReasoningEffort::Medium, false),
        ("-minimal", CodexReasoningEffort::Minimal, false),
        ("-high", CodexReasoningEffort::High, false),
        ("-none", CodexReasoningEffort::None, false),
        ("-low", CodexReasoningEffort::Low, false),
    ];
    let mut base = raw.to_string();
    let mut effort = None;
    let lowered = raw.to_ascii_lowercase();
    for (suffix, candidate, requires_family) in suffixes {
        if lowered.ends_with(suffix) {
            let candidate_base = raw[..raw.len() - suffix.len()].trim();
            if candidate_base.is_empty() {
                break;
            }
            if !requires_family || supports_extended_effort(*candidate, candidate_base) {
                base = candidate_base.to_string();
                effort = Some(*candidate);
            }
            break;
        }
    }

    let mut tier = None;
    let base_lowered = base.to_ascii_lowercase();
    if let Some(stripped) = base_lowered.strip_suffix("-fast") {
        let original = base[..stripped.len()].trim();
        if !original.is_empty() {
            base = original.to_string();
            tier = Some("fast".to_string());
        }
    }
    (Some(base), effort, tier)
}

fn supports_extended_effort(effort: CodexReasoningEffort, candidate: &str) -> bool {
    let support_base = service_tier_stripped_base(candidate).to_ascii_lowercase();
    match support_base.as_str() {
        "gpt-5.6" | "gpt-5.6-sol" | "gpt-5.6-terra" => {
            matches!(effort, CodexReasoningEffort::Max | CodexReasoningEffort::Ultra)
        }
        "gpt-5.6-luna" => effort == CodexReasoningEffort::Max,
        _ => false,
    }
}

fn service_tier_stripped_base(candidate: &str) -> String {
    let mut base = candidate.trim().to_string();
    let lowered = base.to_ascii_lowercase();
    if let Some(stripped) = lowered.strip_suffix("-fast") {
        let original = base[..stripped.len()].trim();
        if !original.is_empty() {
            base = original.to_string();
        }
    }
    base
}

#[must_use]
pub fn service_tier_aware_base_id(raw_model: &str) -> String {
    let trimmed = raw_model.trim();
    let specifier = CodexModelSpecifier::parse(Some(trimmed));
    let mut base_id = specifier
        .base_model
        .unwrap_or_else(|| trimmed.to_string())
        .trim()
        .to_string();
    if let Some(tier) = specifier
        .service_tier
        .as_deref()
        .filter(|tier| *tier == "fast" && is_fast_eligible(&base_id))
    {
        base_id.push('-');
        base_id.push_str(tier);
    }
    base_id
}

fn is_fast_eligible(base_model_id: &str) -> bool {
    gpt_version(base_model_id).is_some_and(|(major, minor)| major > 5 || (major == 5 && minor >= 3))
}

fn gpt_version(base_model_id: &str) -> Option<(u32, u32)> {
    let normalized = base_model_id.trim().to_ascii_lowercase();
    let rest = normalized.strip_prefix("gpt-")?;
    let version: String = rest
        .chars()
        .take_while(|ch| ch.is_ascii_digit() || *ch == '.')
        .collect();
    let mut parts = version.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next().and_then(|part| part.parse().ok()).unwrap_or(0);
    Some((major, minor))
}

fn codex_display_name(raw_model: &str) -> String {
    let trimmed = raw_model.trim();
    if trimmed.is_empty() {
        return raw_model.to_string();
    }
    let normalized = trimmed
        .replace('_', " ")
        .replace('-', " ")
        .replace('/', " ");
    let tokens: Vec<String> = normalized
        .split_whitespace()
        .map(|token| {
            let lower = token.to_ascii_lowercase();
            match lower.as_str() {
                "gpt" => "GPT".to_string(),
                "codex" => "Codex".to_string(),
                "openai" => "OpenAI".to_string(),
                "max" => "Max".to_string(),
                _ if lower.chars().all(|ch| ch.is_ascii_digit() || ch == '.') => token.to_string(),
                _ => {
                    let mut chars = token.chars();
                    match chars.next() {
                        Some(first) => {
                            format!("{}{}", first.to_ascii_uppercase(), chars.as_str().to_ascii_lowercase())
                        }
                        None => String::new(),
                    }
                }
            }
        })
        .collect();
    let mut output = tokens.join(" ");
    if let Some(stripped) = output.strip_prefix("GPT ") {
        output = format!("GPT-{stripped}");
    }
    output
}

fn codex_base_precedes(lhs: &str, rhs: &str) -> std::cmp::Ordering {
    let left = gpt_version(lhs).unwrap_or((0, 0));
    let right = gpt_version(rhs).unwrap_or((0, 0));
    match right.cmp(&left) {
        std::cmp::Ordering::Equal => {
            let left_fast = lhs.to_ascii_lowercase().ends_with("-fast");
            let right_fast = rhs.to_ascii_lowercase().ends_with("-fast");
            match (left_fast, right_fast) {
                (false, true) => std::cmp::Ordering::Less,
                (true, false) => std::cmp::Ordering::Greater,
                _ => std::cmp::Ordering::Equal,
            }
        }
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turn_status_unknown_completes() {
        assert_eq!(map_turn_status("done"), "completed");
        assert_eq!(map_turn_status("interrupted"), "interrupted");
    }

    #[test]
    fn server_request_classification() {
        assert_eq!(
            classify_server_request("item/commandExecution/requestApproval"),
            Some(CodexServerRequestKind::Approval)
        );
        assert_eq!(
            classify_server_request("item/permissions/requestApproval"),
            Some(CodexServerRequestKind::Permissions)
        );
        assert_eq!(
            classify_server_request("foo/RequestApproval"),
            Some(CodexServerRequestKind::Approval)
        );
        assert_eq!(classify_server_request("session/update"), None);
    }

    #[test]
    fn turn_reducer_is_absorbing() {
        let mut state = CodexSemanticState::new();
        let started = state.apply(
            "turn/started",
            r#"{"turn":{"id":"t1"}}"#,
            "run",
            None,
        );
        assert!(started.is_empty());
        assert_eq!(state.status, CodexTurnStatus::InFlight);
        let completed = state.apply(
            "turn/completed",
            r#"{"turn":{"id":"t1","status":"completed"}}"#,
            "run",
            None,
        );
        assert_eq!(completed.len(), 1);
        assert!(state.is_terminal());
        let ignored = state.apply(
            "turn/completed",
            r#"{"turn":{"id":"t1","status":"failed"}}"#,
            "run",
            None,
        );
        assert!(ignored.is_empty());
        assert_eq!(state.status, CodexTurnStatus::Completed);
    }

    #[test]
    fn collapse_matches_named_fixture_order() {
        let collapsed = collapse_model_options(&[
            CodexModelOption {
                raw_value: "default".to_string(),
                display_name: "Default".to_string(),
                is_placeholder_default: true,
                is_provider_default: false,
                supported_reasoning_efforts: Vec::new(),
                default_reasoning_effort: None,
            },
            option("gpt-5.2-high", false),
            option("gpt-5.4-fast-high", false),
            CodexModelOption {
                raw_value: "gpt-5.6-sol-high".to_string(),
                display_name: "GPT-5.6 Sol High".to_string(),
                is_placeholder_default: false,
                is_provider_default: true,
                supported_reasoning_efforts: Vec::new(),
                default_reasoning_effort: None,
            },
            option("gpt-5.4-low", false),
            option("gpt-5.6-sol-low", false),
            option("gpt-5.4-fast-low", false),
        ]);
        let raws: Vec<&str> = collapsed.iter().map(|option| option.raw_value.as_str()).collect();
        assert_eq!(
            raws,
            ["default", "gpt-5.6-sol", "gpt-5.4", "gpt-5.4-fast", "gpt-5.2"]
        );
        let sol = collapsed.iter().find(|option| option.raw_value == "gpt-5.6-sol").unwrap();
        assert_eq!(
            sol.supported_reasoning_efforts,
            vec![CodexReasoningEffort::Low, CodexReasoningEffort::High]
        );
        assert_eq!(sol.default_reasoning_effort, Some(CodexReasoningEffort::High));
        assert!(sol.is_provider_default);
    }

    fn option(raw: &str, provider_default: bool) -> CodexModelOption {
        CodexModelOption {
            raw_value: raw.to_string(),
            display_name: raw.to_string(),
            is_placeholder_default: false,
            is_provider_default: provider_default,
            supported_reasoning_efforts: Vec::new(),
            default_reasoning_effort: None,
        }
    }

    #[test]
    fn specifier_does_not_strip_codex_max_as_effort() {
        let parsed = CodexModelSpecifier::parse(Some("gpt-5.1-codex-max"));
        assert_eq!(parsed.base_model.as_deref(), Some("gpt-5.1-codex-max"));
        assert_eq!(parsed.reasoning_effort, None);
    }

    #[test]
    fn approval_result_amendment_falls_back() {
        assert_eq!(
            build_approval_result(ApprovalDecisionKind::Accept, ApprovalKind::CommandExecution, None),
            r#"{"decision":"accept"}"#
        );
        assert_eq!(
            build_approval_result(
                ApprovalDecisionKind::AcceptWithExecpolicyAmendment,
                ApprovalKind::FileChange,
                Some("{}")
            ),
            r#"{"decision":"decline"}"#
        );
    }
}
