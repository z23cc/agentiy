//! Port of `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/
//! ClaudeSDKNDJSONTranslator.swift` (952 lines) -- contract §2.3-§2.8. Byte-exact/behavior-exact
//! per design D-1: every branch, threshold, and suppression rule below is ported, not simplified.
//!
//! One deliberate representational substitution, noted because it is NOT behavior drift: Swift's
//! `toolInvocationID: UUID?` becomes `InvocationId(u64)`, a per-translator monotonic counter. The
//! only contract this field carries is "the same synthetic identifier is reused for a `tool_call`
//! and its matching `tool_result`" (contract §2.3's `tool_use`/`tool_result` rows) -- global
//! uniqueness across the app is never observed by anything this slice ports, and this slice has no
//! `uuid` crate in the workspace dependency set. Revisit at the FFI-crossing step (P6-6) if a wire
//! contract ever needs true UUID shape.

use std::collections::HashMap;

use serde_json::{Map, Value};

use super::REASONING_EXTRACTION_ENABLED;

/// Newtype substitute for Swift's `UUID` -- see module doc.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct InvocationId(pub u64);

/// Port of `ClaudeProviderStreamResult` (contract §2.3 table + `ClaudeProviderStreamResult.swift`).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct StreamResult {
    pub kind: String,
    pub text: Option<String>,
    pub reasoning: Option<String>,
    pub prompt_tokens: Option<i64>,
    pub completion_tokens: Option<i64>,
    pub cost: Option<f64>,
    pub tool_name: Option<String>,
    pub tool_args: Option<String>,
    pub tool_output: Option<String>,
    pub tool_invocation_id: Option<InvocationId>,
    pub tool_result_json: Option<String>,
    pub tool_args_json: Option<String>,
    pub tool_is_error: Option<bool>,
    pub provider_session_id: Option<String>,
    pub stop_reason: Option<String>,
    pub model_context_window: Option<i64>,
    pub context_used_tokens: Option<i64>,
    pub content_message_id: Option<String>,
}

impl StreamResult {
    fn new(kind: impl Into<String>) -> Self {
        Self { kind: kind.into(), ..Default::default() }
    }
}

/// `ClaudeProviderStreamResult.lifecycleType`.
pub const LIFECYCLE_TYPE: &str = "lifecycle";

struct TokenUsage {
    input_tokens: i64,
    output_tokens: i64,
    context_used_tokens: Option<i64>,
}

/// Port of `ClaudeSDKNDJSONTranslator`. `treats_tool_result_errors_as_host_owned` is contract §8's
/// host-owned-tool-name predicate, ported as data (see `agent_claude::tool_owned`).
pub struct Translator {
    pub cli_session_id: Option<String>,
    tool_name_by_tool_use_id: HashMap<String, String>,
    invocation_id_by_tool_use_id: HashMap<String, InvocationId>,
    next_invocation_id: u64,
    treats_tool_result_errors_as_host_owned: Box<dyn Fn(&str) -> bool + Send>,
}

impl Default for Translator {
    fn default() -> Self {
        Self::new(Box::new(|_| false))
    }
}

impl Translator {
    pub fn new(treats_tool_result_errors_as_host_owned: Box<dyn Fn(&str) -> bool + Send>) -> Self {
        Self {
            cli_session_id: None,
            tool_name_by_tool_use_id: HashMap::new(),
            invocation_id_by_tool_use_id: HashMap::new(),
            next_invocation_id: 0,
            treats_tool_result_errors_as_host_owned,
        }
    }

    /// Port of `parseNDJSONLine(_:)`: raw-bytes convenience entry point (parses JSON directly,
    /// bypassing the codec envelope layer -- used the same way the Swift package's own tests
    /// drive the translator).
    pub fn parse_ndjson_line(&mut self, line_data: &[u8]) -> Vec<StreamResult> {
        let Some(trimmed) = super::framer::trimmed_ascii_whitespace(line_data) else {
            return Vec::new();
        };
        if trimmed.is_empty() {
            return Vec::new();
        }
        let Ok(Value::Object(json)) = serde_json::from_slice::<Value>(trimmed) else {
            return Vec::new();
        };
        self.parse_message_dictionary(&json)
    }

    /// Port of `parseStreamPayload(_:)`: translates an already-decoded codec stream payload.
    pub fn parse_stream_payload(&mut self, payload: &Map<String, Value>) -> Vec<StreamResult> {
        self.parse_message_dictionary(payload)
    }

    fn parse_message_dictionary(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        if let Some(session_id) = first_string(json, &["session_id", "sessionId"]) {
            self.cli_session_id = Some(session_id);
        }
        let message_type = json.get("type").and_then(Value::as_str).unwrap_or("");
        match message_type {
            "system" => self.parse_system_message(json),
            "assistant" | "message" => self.parse_assistant_message(json),
            "user" => self.parse_user_message(json),
            "stream_event" => self.parse_stream_event(json),
            "tool_use" => self.parse_top_level_tool_use(json),
            "tool_result" => self.parse_top_level_tool_result(json),
            "result" => self.parse_result_message(json),
            "tool_progress" => self.parse_tool_progress_message(json),
            "auth_status" => self.parse_auth_status_message(json),
            "tool_use_summary" => self.parse_tool_use_summary_message(json),
            "rate_limit_event" => self.parse_rate_limit_event_message(json),
            "error" => {
                if let Some(message) = first_string(json, &["error", "message"]) {
                    if !message.is_empty() {
                        return vec![StreamResult { text: Some(message), ..StreamResult::new("error") }];
                    }
                }
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    fn parse_system_message(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        let subtype = json.get("subtype").and_then(Value::as_str).map(str::to_lowercase);
        let subtype = subtype.as_deref();

        if subtype == Some("init") {
            if let Some(session_id) = first_string(json, &["session_id", "sessionId"]) {
                self.cli_session_id = Some(session_id);
            }
            return vec![StreamResult { text: Some("initialized".to_string()), ..StreamResult::new(LIFECYCLE_TYPE) }];
        }

        if subtype == Some("status") {
            let status = first_string(json, &["status"]).map(|s| s.trim().to_string());
            let mut fragments: Vec<String> = Vec::new();
            if let Some(status) = status {
                if !status.is_empty() && status != "null" {
                    if status.eq_ignore_ascii_case("compacting") {
                        fragments.push("Compacting context".to_string());
                    } else {
                        fragments.push(status);
                    }
                }
            }
            if fragments.is_empty() {
                return Vec::new();
            }
            return vec![StreamResult { text: Some(fragments.join(" — ")), ..StreamResult::new("status") }];
        }

        if subtype == Some("task_started") {
            let task_id = first_string(json, &["task_id"]);
            let description = first_string(json, &["description"]);
            let fragments = joined_non_empty_fragments(
                &[Some("Task started".to_string()), task_id, description],
                " — ",
            );
            return match fragments {
                Some(text) => vec![StreamResult { text: Some(text), ..StreamResult::new("system") }],
                None => Vec::new(),
            };
        }

        if subtype == Some("task_notification") {
            let task_id = first_string(json, &["task_id"]);
            let status = first_string(json, &["status"]);
            let summary = first_string(json, &["summary"]);
            let fragments = joined_non_empty_fragments(
                &[Some("Task update".to_string()), task_id, status, summary],
                " — ",
            );
            return match fragments {
                Some(text) => vec![StreamResult { text: Some(text), ..StreamResult::new("system") }],
                None => Vec::new(),
            };
        }

        if subtype == Some("compact_boundary") {
            let metadata = json.get("compact_metadata").and_then(Value::as_object).cloned().unwrap_or_default();
            let trigger = first_string(&metadata, &["trigger"]);
            let pre_tokens = number_to_int(metadata.get("pre_tokens"));
            let mut fragments = vec!["Context compacted".to_string()];
            if let Some(trigger) = trigger {
                if !trigger.is_empty() {
                    fragments.push(format!("trigger: {trigger}"));
                }
            }
            if let Some(pre_tokens) = pre_tokens {
                if pre_tokens > 0 {
                    fragments.push(format!("at ~{pre_tokens} tokens"));
                }
            }
            return vec![StreamResult { text: Some(fragments.join(" — ")), ..StreamResult::new("system") }];
        }

        if subtype == Some("session_state_changed") {
            let state = first_string(
                json,
                &["session_state", "sessionState", "state", "current_state", "currentState"],
            )
            .map(|s| s.trim().to_lowercase());
            return match state {
                Some(state) if !state.is_empty() => {
                    vec![StreamResult { text: Some(state), ..StreamResult::new("session_state_changed") }]
                }
                _ => Vec::new(),
            };
        }

        if subtype == Some("task_progress") {
            let fragments: Vec<String> = ["message", "text", "summary", "description", "status"]
                .iter()
                .filter_map(|key| first_string(json, &[key]).map(|v| v.trim().to_string()))
                .filter(|v| !v.is_empty())
                .collect();
            if fragments.is_empty() {
                if let Some(task_id) = first_string(json, &["task_id", "taskId"]) {
                    let trimmed = task_id.trim();
                    if !trimmed.is_empty() {
                        return vec![StreamResult {
                            text: Some(format!("Task {trimmed}")),
                            ..StreamResult::new("task_progress")
                        }];
                    }
                }
                return Vec::new();
            }
            return vec![StreamResult { text: Some(fragments.join(" — ")), ..StreamResult::new("task_progress") }];
        }

        if let Some(message) = first_string(json, &["message"]) {
            if !message.is_empty() {
                return vec![StreamResult { text: Some(message), ..StreamResult::new("system") }];
            }
        }
        Vec::new()
    }

    fn parse_assistant_message(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        let payload = json.get("message").and_then(Value::as_object).unwrap_or(json);
        let usage_result = parse_usage(payload.get("usage").and_then(Value::as_object)).map(|usage| StreamResult {
            prompt_tokens: Some(usage.input_tokens),
            completion_tokens: Some(usage.output_tokens),
            context_used_tokens: usage.context_used_tokens,
            ..StreamResult::new("usage")
        });

        let Some(content) = payload.get("content").and_then(Value::as_array) else {
            let mut results = Vec::new();
            if let Some(fallback) = extract_string(payload.get("content")) {
                if !fallback.is_empty() {
                    if let Some(usage_result) = usage_result {
                        results.push(usage_result);
                    }
                    results.push(StreamResult { text: Some(fallback), ..StreamResult::new("content") });
                    return results;
                }
            }
            if let Some(usage_result) = usage_result {
                results.push(usage_result);
            }
            return results;
        };

        let mut results = Vec::new();
        if let Some(usage_result) = usage_result {
            results.push(usage_result);
        }
        for item in content {
            let Some(block) = item.as_object() else { continue };
            let Some(block_type) = block.get("type").and_then(Value::as_str) else { continue };
            match block_type {
                "text" => {
                    if let Some(text) = block.get("text").and_then(Value::as_str) {
                        if !text.is_empty() {
                            results.push(StreamResult { text: Some(text.to_string()), ..StreamResult::new("content") });
                        }
                    }
                }
                "thinking" => {
                    if !REASONING_EXTRACTION_ENABLED {
                        continue;
                    }
                    if let Some(text) = block.get("thinking").and_then(Value::as_str) {
                        if !text.is_empty() {
                            results.push(StreamResult {
                                reasoning: Some(text.to_string()),
                                ..StreamResult::new("reasoning")
                            });
                        }
                    }
                }
                "tool_use" => {
                    let tool_name = block.get("name").and_then(Value::as_str).unwrap_or("tool").to_string();
                    let tool_use_id = tool_use_id(block);
                    if let Some(id) = &tool_use_id {
                        if !id.is_empty() {
                            self.tool_name_by_tool_use_id.insert(id.clone(), tool_name.clone());
                        }
                    }
                    let invocation_id = self.resolve_invocation_id(tool_use_id.as_deref());
                    let input = block.get("input").and_then(Value::as_object).cloned().unwrap_or_default();
                    let input_json = serialize_json_object_string(&input);
                    results.push(StreamResult {
                        tool_name: Some(tool_name),
                        tool_args: input_json.clone(),
                        tool_invocation_id: invocation_id,
                        tool_args_json: input_json,
                        ..StreamResult::new("tool_call")
                    });
                }
                "tool_result" => {
                    let tool_use_id = tool_use_id(block);
                    let tool_name =
                        self.resolve_tool_name(block.get("name").and_then(Value::as_str), tool_use_id.as_deref());
                    let is_error =
                        self.infer_tool_result_error(block, &tool_name, None);
                    let output = serialize_tool_result_content(block.get("content"));
                    let invocation_id = self.resolve_invocation_id(tool_use_id.as_deref());
                    results.push(StreamResult {
                        tool_name: Some(tool_name),
                        tool_output: Some(output.clone()),
                        tool_invocation_id: invocation_id,
                        tool_result_json: Some(output),
                        tool_is_error: is_error,
                        ..StreamResult::new("tool_result")
                    });
                }
                _ => continue,
            }
        }
        results
    }

    fn parse_user_message(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        let payload = json.get("message").and_then(Value::as_object).unwrap_or(json);
        let Some(content) = payload.get("content").and_then(Value::as_array) else {
            return Vec::new();
        };
        let mut results = Vec::new();
        for item in content {
            let Some(block) = item.as_object() else { continue };
            if block.get("type").and_then(Value::as_str) != Some("tool_result") {
                continue;
            }
            let tool_use_id = tool_use_id(block);
            let tool_name = self.resolve_tool_name(block.get("name").and_then(Value::as_str), tool_use_id.as_deref());
            let is_error = self.infer_tool_result_error(block, &tool_name, None);
            let output = serialize_tool_result_content(block.get("content"));
            let invocation_id = self.resolve_invocation_id(tool_use_id.as_deref());
            results.push(StreamResult {
                tool_name: Some(tool_name),
                tool_output: Some(output.clone()),
                tool_invocation_id: invocation_id,
                tool_result_json: Some(output),
                tool_is_error: is_error,
                ..StreamResult::new("tool_result")
            });
        }
        results
    }

    fn parse_stream_event(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        let Some(event) = json.get("event").and_then(Value::as_object) else {
            return Vec::new();
        };
        let Some(event_type) = event.get("type").and_then(Value::as_str) else {
            return Vec::new();
        };

        match event_type {
            "content_block_delta" => {
                let Some(delta) = event.get("delta").and_then(Value::as_object) else {
                    return Vec::new();
                };
                let Some(delta_type) = delta.get("type").and_then(Value::as_str) else {
                    return Vec::new();
                };
                match delta_type {
                    "text_delta" => {
                        if let Some(text) = delta.get("text").and_then(Value::as_str) {
                            if !text.is_empty() {
                                return vec![StreamResult { text: Some(text.to_string()), ..StreamResult::new("content") }];
                            }
                        }
                        Vec::new()
                    }
                    "thinking_delta" => {
                        if !REASONING_EXTRACTION_ENABLED {
                            return Vec::new();
                        }
                        if let Some(text) = delta.get("thinking").and_then(Value::as_str) {
                            if !text.is_empty() {
                                return vec![StreamResult {
                                    reasoning: Some(text.to_string()),
                                    ..StreamResult::new("reasoning")
                                }];
                            }
                        }
                        Vec::new()
                    }
                    _ => Vec::new(),
                }
            }
            "message_start" => {
                let Some(message) = event.get("message").and_then(Value::as_object) else {
                    return Vec::new();
                };
                let Some(usage) = parse_usage(message.get("usage").and_then(Value::as_object)) else {
                    return Vec::new();
                };
                vec![StreamResult {
                    prompt_tokens: Some(usage.input_tokens),
                    completion_tokens: Some(usage.output_tokens),
                    context_used_tokens: usage.context_used_tokens,
                    ..StreamResult::new("usage")
                }]
            }
            "message_delta" => {
                let mut results = Vec::new();
                if let Some(usage) = parse_usage(event.get("usage").and_then(Value::as_object)) {
                    results.push(StreamResult {
                        prompt_tokens: Some(usage.input_tokens),
                        completion_tokens: Some(usage.output_tokens),
                        context_used_tokens: usage.context_used_tokens,
                        ..StreamResult::new("usage")
                    });
                }
                if let Some(delta) = event.get("delta").and_then(Value::as_object) {
                    if let Some(stop_reason) = first_string(delta, &["stop_reason", "stopReason"]) {
                        if !stop_reason.trim().is_empty() {
                            results.push(StreamResult {
                                stop_reason: Some(stop_reason),
                                ..StreamResult::new("message_stop")
                            });
                        }
                    }
                }
                results
            }
            "message_stop" => vec![StreamResult::new("message_stop")],
            _ => Vec::new(),
        }
    }

    fn parse_top_level_tool_use(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        let tool_name = first_string(json, &["tool_name", "toolName", "name"]).unwrap_or_else(|| "tool".to_string());
        let tool_use_id = tool_use_id(json);
        if let Some(id) = &tool_use_id {
            if !id.is_empty() {
                self.tool_name_by_tool_use_id.insert(id.clone(), tool_name.clone());
            }
        }
        let invocation_id = self.resolve_invocation_id(tool_use_id.as_deref());
        let args = json
            .get("tool_args")
            .or_else(|| json.get("toolArgs"))
            .or_else(|| json.get("input"))
            .or_else(|| json.get("arguments"))
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let args_json = serialize_json_object_string(&args);
        vec![StreamResult {
            tool_name: Some(tool_name),
            tool_args: args_json.clone(),
            tool_invocation_id: invocation_id,
            tool_args_json: args_json,
            ..StreamResult::new("tool_call")
        }]
    }

    fn parse_top_level_tool_result(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        let tool_use_id = tool_use_id(json);
        let result_payload = json
            .get("tool_result")
            .or_else(|| json.get("toolResult"))
            .or_else(|| json.get("content"))
            .or_else(|| json.get("result"))
            .or_else(|| json.get("output"))
            .or_else(|| json.get("response"));
        let output = serialize_tool_result_content(result_payload);
        let tool_name = self.resolve_tool_name(
            first_string(json, &["tool_name", "toolName", "name"]).as_deref(),
            tool_use_id.as_deref(),
        );
        let invocation_id = self.resolve_invocation_id(tool_use_id.as_deref());
        let is_error = self.infer_tool_result_error(json, &tool_name, result_payload);
        vec![StreamResult {
            tool_name: Some(tool_name),
            tool_output: Some(output.clone()),
            tool_invocation_id: invocation_id,
            tool_result_json: Some(output),
            tool_is_error: is_error,
            ..StreamResult::new("tool_result")
        }]
    }

    fn parse_result_message(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        let usage = parse_usage(json.get("usage").and_then(Value::as_object));
        let model_context_window = parse_model_context_window(json.get("modelUsage").and_then(Value::as_object));
        let cost = json.get("total_cost_usd").and_then(Value::as_f64);
        let stop_reason = first_string(json, &["stop_reason", "stopReason"]);
        let result_subtype =
            first_string(json, &["subtype"]).map(|s| s.trim().to_lowercase());
        let is_error = bool_value(json, &["is_error", "isError"]) == Some(true);
        if let Some(result_session_id) = first_string(json, &["session_id", "sessionId"]) {
            self.cli_session_id = Some(result_session_id);
        }

        let mut results = Vec::new();
        let result_errors = extract_result_error_messages(json);
        let should_emit_result_error =
            is_error || result_subtype.as_deref().is_some_and(|s| s.contains("error")) || !result_errors.is_empty();
        let should_suppress_result_error =
            should_suppress_result_error_emission(result_subtype.as_deref(), stop_reason.as_deref(), &result_errors);
        if should_emit_result_error && !should_suppress_result_error {
            if let Some(error_message) = result_errors.first() {
                if !error_message.is_empty() {
                    results.push(StreamResult { text: Some(error_message.clone()), ..StreamResult::new("error") });
                }
            }
        }
        if let Some(Value::String(final_text)) = json.get("result") {
            if !final_text.is_empty() {
                results.push(StreamResult { text: Some(final_text.clone()), ..StreamResult::new("final_content") });
            }
        }
        // Note: contextUsedTokens is intentionally nil here (contract §2.3): `result.usage` is an
        // aggregate billed-turn total, not a live context snapshot.
        results.push(StreamResult {
            prompt_tokens: usage.as_ref().map(|u| u.input_tokens),
            completion_tokens: usage.as_ref().map(|u| u.output_tokens),
            cost,
            provider_session_id: self.cli_session_id.clone(),
            stop_reason,
            model_context_window,
            ..StreamResult::new("message_stop")
        });
        results
    }

    fn parse_tool_progress_message(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        let tool_name = first_string(json, &["tool_name", "toolName", "name"]);
        let status = first_string(json, &["status", "stage"]);
        let detail = first_string(json, &["message", "text", "progress"]);
        let fragments: Vec<String> = [tool_name.clone(), status, detail]
            .into_iter()
            .filter_map(|v| v.map(|s| s.trim().to_string()))
            .filter(|s| !s.is_empty())
            .collect();
        if fragments.is_empty() {
            return Vec::new();
        }
        vec![StreamResult { text: Some(fragments.join(" — ")), tool_name, ..StreamResult::new("tool_progress") }]
    }

    fn parse_auth_status_message(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        if let Some(is_authenticating) = json.get("isAuthenticating").and_then(Value::as_bool) {
            // Mirrors Swift's `(json["output"] as? [String])?` -- an all-or-nothing cast: `None`
            // for the whole thing if any element isn't a string, not "skip the non-string ones".
            let output = json.get("output").and_then(Value::as_array).and_then(|values| {
                values
                    .iter()
                    .map(Value::as_str)
                    .collect::<Option<Vec<&str>>>()
            }).map(|values| {
                values
                    .into_iter()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ")
            });
            let error = first_string(json, &["error"]);
            let mut fragments = vec![if is_authenticating { "Authenticating".to_string() } else { "Authenticated".to_string() }];
            if let Some(output) = output {
                if !output.is_empty() {
                    fragments.push(output);
                }
            }
            if let Some(error) = error {
                if !error.is_empty() {
                    fragments.push(error);
                }
            }
            return vec![StreamResult { text: Some(fragments.join(" — ")), ..StreamResult::new("auth_status") }];
        }

        let status = first_string(json, &["status", "auth_status", "authStatus"]);
        let message = first_string(json, &["message", "text", "detail"]);
        let parts: Vec<String> = [status, message]
            .into_iter()
            .filter_map(|v| v.map(|s| s.trim().to_string()))
            .filter(|s| !s.is_empty())
            .collect();
        if parts.is_empty() {
            return Vec::new();
        }
        vec![StreamResult { text: Some(parts.join(" — ")), ..StreamResult::new("auth_status") }]
    }

    fn parse_tool_use_summary_message(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        let Some(summary) = first_string(json, &["summary"]) else { return Vec::new() };
        if summary.is_empty() {
            return Vec::new();
        }
        vec![StreamResult { text: Some(format!("Tool summary — {summary}")), ..StreamResult::new("system") }]
    }

    fn parse_rate_limit_event_message(&mut self, json: &Map<String, Value>) -> Vec<StreamResult> {
        let Some(info) = json.get("rate_limit_info").and_then(Value::as_object) else {
            return Vec::new();
        };
        let status = first_string(info, &["status"]).map(|s| s.trim().to_lowercase());
        if status.as_deref() == Some("allowed") {
            return Vec::new();
        }
        let rate_limit_type = first_string(info, &["rateLimitType", "rate_limit_type"]);
        let overage_status = first_string(info, &["overageStatus", "overage_status"]);
        let fragments: Vec<String> = [Some("Rate limit".to_string()), status, rate_limit_type, overage_status]
            .into_iter()
            .filter_map(|v| v.map(|s| s.trim().to_string()))
            .filter(|s| !s.is_empty())
            .collect();
        if fragments.is_empty() {
            return Vec::new();
        }
        vec![StreamResult { text: Some(fragments.join(" — ")), ..StreamResult::new("system") }]
    }

    fn resolve_tool_name(&mut self, raw_name: Option<&str>, tool_use_id: Option<&str>) -> String {
        let trimmed_raw = raw_name.map(str::trim);
        let mapped = tool_use_id.and_then(|id| self.tool_name_by_tool_use_id.get(id).cloned());
        let resolved = match trimmed_raw {
            Some(raw) if !raw.is_empty() => raw.to_string(),
            _ => mapped.unwrap_or_else(|| "tool".to_string()),
        };
        if let Some(id) = tool_use_id {
            if !id.is_empty() && !resolved.is_empty() && resolved != "tool" {
                self.tool_name_by_tool_use_id.insert(id.to_string(), resolved.clone());
            }
        }
        resolved
    }

    fn resolve_invocation_id(&mut self, tool_use_id: Option<&str>) -> Option<InvocationId> {
        let tool_use_id = tool_use_id?;
        if tool_use_id.is_empty() {
            return None;
        }
        if let Some(existing) = self.invocation_id_by_tool_use_id.get(tool_use_id) {
            return Some(*existing);
        }
        let generated = InvocationId(self.next_invocation_id);
        self.next_invocation_id += 1;
        self.invocation_id_by_tool_use_id.insert(tool_use_id.to_string(), generated);
        Some(generated)
    }

    fn infer_tool_result_error(
        &self,
        payload: &Map<String, Value>,
        tool_name: &str,
        result_payload: Option<&Value>,
    ) -> Option<bool> {
        if (self.treats_tool_result_errors_as_host_owned)(tool_name) {
            return None;
        }
        if let Some(explicit) = bool_value(payload, &["is_error", "isError"]) {
            return Some(explicit);
        }
        if let Some(inferred) = infer_tool_result_error_signal(&Value::Object(payload.clone())) {
            return Some(inferred);
        }
        if let Some(result_payload) = result_payload {
            if let Some(inferred) = infer_tool_result_error_signal(result_payload) {
                return Some(inferred);
            }
        }
        None
    }
}

fn joined_non_empty_fragments(candidates: &[Option<String>], separator: &str) -> Option<String> {
    let fragments: Vec<String> = candidates
        .iter()
        .filter_map(|v| v.as_ref().map(|s| s.trim().to_string()))
        .filter(|s| !s.is_empty())
        .collect();
    if fragments.is_empty() { None } else { Some(fragments.join(separator)) }
}

fn first_string(json: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(value) = json.get(*key).and_then(Value::as_str) {
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    None
}

fn tool_use_id(json: &Map<String, Value>) -> Option<String> {
    first_string(json, &["tool_use_id", "toolUseId", "toolUseID", "id"])
}

fn extract_result_error_messages(json: &Map<String, Value>) -> Vec<String> {
    let mut messages: Vec<String> = Vec::new();

    if let Some(errors) = json.get("errors").and_then(Value::as_array) {
        for entry in errors {
            match entry {
                Value::String(message) => {
                    let trimmed = message.trim();
                    if !trimmed.is_empty() {
                        messages.push(trimmed.to_string());
                    }
                }
                Value::Object(object) => {
                    if let Some(message) = first_string(object, &["message", "error"]) {
                        let trimmed = message.trim().to_string();
                        if !trimmed.is_empty() {
                            messages.push(trimmed);
                        }
                    }
                }
                _ => continue,
            }
        }
    }

    if let Some(explicit) = first_string(json, &["error", "message"]) {
        let trimmed = explicit.trim().to_string();
        if !trimmed.is_empty() && !messages.contains(&trimmed) {
            messages.push(trimmed);
        }
    }

    messages
}

fn is_interrupted_turn_signal(value: Option<&str>) -> bool {
    let Some(value) = value else { return false };
    let value = value.trim().to_lowercase();
    if value.is_empty() {
        return false;
    }
    value.contains("interrupt")
        || value.contains("cancel")
        || value.contains("aborted")
        || value.contains("request was aborted")
}

/// Port of `shouldSuppressUserFacingStreamResult(_:)` (D-2, contract §6, "Suppression rules").
/// A `"system"` result whose text starts with `"Task started"`/`"Task update"` is suppressed
/// (surfacing it prematurely ends the active assistant transcript segment); an `"error"` result is
/// suppressed when `should_suppress_user_facing_error` recognizes it as an abort artifact.
/// Everything else passes through.
pub fn should_suppress_user_facing_stream_result(result: &StreamResult) -> bool {
    if result.kind == "system" {
        if let Some(text) = &result.text {
            if text.starts_with("Task started") || text.starts_with("Task update") {
                return true;
            }
        }
    }
    if result.kind != "error" {
        return false;
    }
    let Some(text) = &result.text else { return false };
    if text.trim().is_empty() {
        return false;
    }
    should_suppress_user_facing_error(text)
}

/// Port of `ClaudeAbortArtifactFilter.shouldSuppressUserFacingError` (`ProviderSupport.swift:29-62`).
pub fn should_suppress_user_facing_error(message: &str) -> bool {
    let lowered = message.trim().to_lowercase();
    if lowered.is_empty() {
        return false;
    }
    if lowered.contains("json parse error") || lowered.contains("syntaxerror") {
        if lowered.contains("unrecognized token '/'")
            || lowered.contains("/$bunfs/root/src/entrypoints/cli.js")
            || lowered.contains("entrypoints/cli.js")
            || lowered.contains("at <parse>")
            || lowered.contains("at parse")
        {
            return true;
        }
    }
    if lowered.contains("non-fatal") && lowered.contains("lock acquisition failed") {
        return true;
    }
    if lowered.contains("aborterror")
        || lowered.contains("the operation was aborted")
        || lowered.contains("request was aborted")
    {
        return true;
    }
    if lowered.starts_with("[ede_diagnostic]") || lowered.contains("internal diagnostic:") {
        return true;
    }
    false
}

fn should_suppress_result_error_emission(subtype: Option<&str>, stop_reason: Option<&str>, errors: &[String]) -> bool {
    if errors.is_empty() {
        return false;
    }
    if is_interrupted_turn_signal(subtype) || is_interrupted_turn_signal(stop_reason) {
        return true;
    }
    let normalized_errors: Vec<String> = errors
        .iter()
        .map(|e| e.trim().to_lowercase())
        .filter(|e| !e.is_empty())
        .collect();
    if normalized_errors.is_empty() {
        return false;
    }
    normalized_errors
        .iter()
        .all(|message| is_interrupted_turn_signal(Some(message)) || should_suppress_user_facing_error(message))
}

fn bool_value(object: &Map<String, Value>, keys: &[&str]) -> Option<bool> {
    for key in keys {
        let Some(value) = object.get(*key) else { continue };
        match value {
            Value::Bool(b) => return Some(*b),
            Value::Number(n) => return Some(n.as_f64().is_some_and(|f| f != 0.0)),
            Value::String(text) => match text.trim().to_lowercase().as_str() {
                "true" | "1" | "yes" | "y" => return Some(true),
                "false" | "0" | "no" | "n" => return Some(false),
                _ => continue,
            },
            _ => continue,
        }
    }
    None
}

fn int_value(object: &Map<String, Value>, keys: &[&str]) -> Option<i64> {
    for key in keys {
        let Some(value) = object.get(*key) else { continue };
        match value {
            Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    return Some(i);
                }
                if let Some(f) = n.as_f64() {
                    return Some(f as i64);
                }
            }
            Value::String(text) => {
                if let Ok(parsed) = text.trim().parse::<i64>() {
                    return Some(parsed);
                }
            }
            _ => continue,
        }
    }
    None
}

fn infer_tool_result_error_signal(value: &Value) -> Option<bool> {
    match value {
        Value::Object(object) => infer_tool_result_error_signal_from_object(object),
        Value::Array(array) => {
            let mut saw_success_signal = false;
            for element in array {
                if let Some(inferred) = infer_tool_result_error_signal(element) {
                    if inferred {
                        return Some(true);
                    }
                    saw_success_signal = true;
                }
            }
            if saw_success_signal { Some(false) } else { None }
        }
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }
            let looks_json = (trimmed.starts_with('{') && trimmed.ends_with('}'))
                || (trimmed.starts_with('[') && trimmed.ends_with(']'));
            if looks_json {
                if let Ok(parsed) = serde_json::from_str::<Value>(trimmed) {
                    return infer_tool_result_error_signal(&parsed);
                }
            }
            None
        }
        _ => None,
    }
}

fn infer_tool_result_error_signal_from_object(object: &Map<String, Value>) -> Option<bool> {
    if let Some(explicit) = bool_value(object, &["is_error", "isError"]) {
        return Some(explicit);
    }

    if let Some(status) = first_string(object, &["status", "result", "outcome", "state", "subtype"]) {
        if let Some(inference) = infer_status_error(&status) {
            return Some(inference);
        }
    }

    if let Some(exit_code) = int_value(object, &["exitCode", "exit_code", "code"]) {
        if exit_code == 0 {
            return Some(false);
        }
        if exit_code > 0 {
            return Some(true);
        }
    }

    if let Some(error) = first_string(object, &["error", "error_message", "errorMessage"]) {
        if !error.trim().is_empty() {
            return Some(true);
        }
    }
    if let Some(errors) = object.get("errors").and_then(Value::as_array) {
        if !errors.is_empty() {
            return Some(true);
        }
    }
    if bool_value(object, &["success", "ok"]) == Some(true) {
        return Some(false);
    }

    let nested_keys = [
        "tool_result", "toolResult", "result", "output", "response", "content", "payload", "data",
        "value", "tool_use_result", "toolUseResult",
    ];
    for key in nested_keys {
        if let Some(nested) = object.get(key) {
            if let Some(inferred) = infer_tool_result_error_signal(nested) {
                return Some(inferred);
            }
        }
    }

    if let Some(content_blocks) = object.get("content").and_then(Value::as_array) {
        if !content_blocks.is_empty() {
            return Some(false);
        }
    }
    None
}

fn infer_status_error(value: &str) -> Option<bool> {
    match value.trim().to_lowercase().as_str() {
        "ok" | "success" | "succeeded" | "complete" | "completed" => Some(false),
        "error" | "failed" | "failure" | "rejected" | "denied" | "cancelled" | "canceled" => Some(true),
        _ => None,
    }
}

fn serialize_json_object_string(value: &Map<String, Value>) -> Option<String> {
    if value.is_empty() {
        return None;
    }
    Some(foundation_pretty_printed_json(&Value::Object(value.clone())))
}

/// Byte-exact port of `JSONSerialization.data(withJSONObject:options: [.prettyPrinted, .sortedKeys])`'s
/// output shape (contract §2.6/§2.3's `tool_call` `input`/`args` and tool-result-content
/// serialization). `serde_json::to_string_pretty` is NOT a byte-exact stand-in for
/// `.prettyPrinted`: verified against a real macOS Foundation run, the two agree on string
/// escaping and number formatting but diverge on (a) the colon separator -- Foundation emits
/// `"key" : value` (space both sides), serde_json emits `"key": value` (space after only) -- and
/// (b) empty containers -- Foundation emits `{\n\n}` / `[\n\n<indent>]` (a blank second line, no
/// trailing whitespace on it), serde_json emits the compact `{}` / `[]` even in pretty mode. Both
/// differences are reproduced explicitly below rather than left to whichever formatter happened to
/// be convenient, because P6-7's turn-level differential asserts identical `AIStreamResult` values
/// field-for-field, and these strings (`toolArgsJSON`/`toolResultJSON`/`toolOutput`) are fields.
fn foundation_pretty_printed_json(value: &Value) -> String {
    fn write(value: &Value, indent: usize, out: &mut String) {
        match value {
            Value::Object(map) => {
                if map.is_empty() {
                    out.push_str("{\n\n");
                    out.push_str(&" ".repeat(indent));
                    out.push('}');
                    return;
                }
                let mut keys: Vec<&String> = map.keys().collect();
                keys.sort();
                let inner_indent = indent + 2;
                out.push_str("{\n");
                for (i, key) in keys.iter().enumerate() {
                    out.push_str(&" ".repeat(inner_indent));
                    out.push_str(&serde_json::to_string(key.as_str()).unwrap_or_else(|_| format!("{key:?}")));
                    out.push_str(" : ");
                    write(&map[*key], inner_indent, out);
                    if i + 1 < keys.len() {
                        out.push(',');
                    }
                    out.push('\n');
                }
                out.push_str(&" ".repeat(indent));
                out.push('}');
            }
            Value::Array(array) => {
                if array.is_empty() {
                    out.push_str("[\n\n");
                    out.push_str(&" ".repeat(indent));
                    out.push(']');
                    return;
                }
                let inner_indent = indent + 2;
                out.push_str("[\n");
                for (i, element) in array.iter().enumerate() {
                    out.push_str(&" ".repeat(inner_indent));
                    write(element, inner_indent, out);
                    if i + 1 < array.len() {
                        out.push(',');
                    }
                    out.push('\n');
                }
                out.push_str(&" ".repeat(indent));
                out.push(']');
            }
            scalar => out.push_str(&serde_json::to_string(scalar).unwrap_or_default()),
        }
    }
    let mut out = String::new();
    write(value, 0, &mut out);
    out
}

/// Port of `serializeToolResultContent(_:)` (contract §2.6). The blocks-array branch mirrors
/// Swift's `value as? [[String: Any]]` cast semantics precisely: that cast is all-or-nothing --
/// it fails for the WHOLE array if even one element isn't a dictionary, falling through to the
/// generic path rather than silently skipping the non-dictionary element. A `filter_map` here
/// would silently keep the dictionary elements and change behavior for a mixed array.
fn serialize_tool_result_content(value: Option<&Value>) -> String {
    let Some(value) = value else { return String::new() };
    if let Some(text) = value.as_str() {
        return text.to_string();
    }
    if let Some(blocks) = value.as_array() {
        if blocks.iter().all(Value::is_object) {
            let text_blocks: Vec<String> = blocks
                .iter()
                .filter_map(|block| {
                    let block = block.as_object()?;
                    let block_type = block.get("type").and_then(Value::as_str).map(str::to_lowercase);
                    if block_type.as_deref() == Some("text") || block_type.as_deref() == Some("output_text") {
                        block.get("text").and_then(Value::as_str).map(str::to_string)
                    } else {
                        None
                    }
                })
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            if !text_blocks.is_empty() {
                return text_blocks.join("\n");
            }
        }
    }
    if matches!(value, Value::Object(_) | Value::Array(_)) {
        return foundation_pretty_printed_json(value);
    }
    swift_description(value)
}

/// Approximates Swift's `String(describing:)` fallback for a JSON scalar that isn't a string,
/// object, or (text-bearing) array -- the last-resort branch of `serializeToolResultContent`.
fn swift_description(value: &Value) -> String {
    match value {
        Value::Null => "<null>".to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        other => other.to_string(),
    }
}

fn extract_string(value: Option<&Value>) -> Option<String> {
    match value {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Object(object)) => object.get("text").and_then(Value::as_str).map(str::to_string),
        Some(Value::Array(array)) => Some(array.iter().filter_map(|v| extract_string(Some(v))).collect::<Vec<_>>().join("")),
        _ => None,
    }
}

fn parse_model_context_window(value: Option<&Map<String, Value>>) -> Option<i64> {
    let value = value?;
    for usage_any in value.values() {
        let Some(usage) = usage_any.as_object() else { continue };
        if let Some(context_window) = number_to_int(usage.get("contextWindow")) {
            if context_window > 0 {
                return Some(context_window);
            }
        }
    }
    None
}

fn parse_usage(value: Option<&Map<String, Value>>) -> Option<TokenUsage> {
    let value = value?;

    let input = number_to_int(value.get("input_tokens")).or_else(|| number_to_int(value.get("inputTokens")));
    let output = number_to_int(value.get("output_tokens")).or_else(|| number_to_int(value.get("outputTokens")));
    let cache_read = number_to_int(value.get("cache_read_input_tokens"))
        .or_else(|| number_to_int(value.get("cacheReadInputTokens")));
    let cache_creation = number_to_int(value.get("cache_creation_input_tokens"))
        .or_else(|| number_to_int(value.get("cacheCreationInputTokens")));

    let has_any_usage_field = input.is_some() || output.is_some() || cache_read.is_some() || cache_creation.is_some();
    if !has_any_usage_field {
        return None;
    }

    let normalized_input = input.unwrap_or(0).max(0);
    let normalized_output = output.unwrap_or(0).max(0);
    let has_context_breakdown = input.is_some() || cache_read.is_some() || cache_creation.is_some();
    let context_used_tokens = if has_context_breakdown {
        Some(saturated_non_negative_sum(&[normalized_input, cache_read.unwrap_or(0).max(0), cache_creation.unwrap_or(0).max(0)]))
    } else {
        None
    };

    Some(TokenUsage {
        input_tokens: normalized_input,
        output_tokens: normalized_output,
        context_used_tokens,
    })
}

fn saturated_non_negative_sum(values: &[i64]) -> i64 {
    let mut total: i64 = 0;
    for &value in values {
        let non_negative = value.max(0);
        total = match total.checked_add(non_negative) {
            Some(sum) => sum,
            None => return i64::MAX,
        };
    }
    total
}

/// Port of `numberToInt(_:)` (contract §2.4). Tolerant of an integral or exactly-representable
/// floating-point JSON number, or a numeric string; `None` for a boolean, non-finite double, or
/// fractional double (mirrors Swift's `Int(exactly:)`, which requires an exact whole-number match).
fn number_to_int(value: Option<&Value>) -> Option<i64> {
    match value {
        Some(Value::Number(n)) => {
            if let Some(i) = n.as_i64() {
                return Some(i);
            }
            if let Some(u) = n.as_u64() {
                return i64::try_from(u).ok();
            }
            let d = n.as_f64()?;
            if !d.is_finite() || d.fract() != 0.0 {
                return None;
            }
            exact_i64_from_f64(d)
        }
        Some(Value::String(s)) => {
            let trimmed = s.trim();
            if let Ok(i) = trimmed.parse::<i64>() {
                return Some(i);
            }
            let d: f64 = trimmed.parse().ok()?;
            if !d.is_finite() || d.fract() != 0.0 {
                return None;
            }
            exact_i64_from_f64(d)
        }
        _ => None,
    }
}

fn exact_i64_from_f64(d: f64) -> Option<i64> {
    if d < i64::MIN as f64 || d > i64::MAX as f64 {
        return None;
    }
    Some(d as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn line(value: serde_json::Value) -> Vec<u8> {
        serde_json::to_vec(&value).unwrap()
    }

    /// Rust arm of `ClaudeSDKNDJSONTranslatorTests
    /// .testAssistantToolAndResultSmokePreservesUsageArgsAndStableInvocationID` -- the identical
    /// literal fixture, hand-mirrored (design §11's reference-arm definition: two independently
    /// asserting suites checked against the same contract semantics, not a shared-file read).
    #[test]
    fn assistant_tool_and_result_smoke_preserves_usage_args_and_stable_invocation_id() {
        let mut translator = Translator::new(Box::new(|name| name == "mcp__RepoPromptCE__read_file"));
        let results = translator.parse_ndjson_line(&line(json!({
            "type": "assistant",
            "message": {
                "usage": {
                    "input_tokens": 7,
                    "output_tokens": 3,
                    "cache_read_input_tokens": 5,
                    "cache_creation_input_tokens": 2
                },
                "content": [
                    {"type": "text", "text": "Hello"},
                    {"type": "tool_use", "id": "toolu_1", "name": "mcp__RepoPromptCE__read_file", "input": {"path": "Sources/App.swift"}}
                ]
            }
        })));

        assert_eq!(results.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["usage", "content", "tool_call"]);
        assert_eq!(results[0].prompt_tokens, Some(7));
        assert_eq!(results[0].completion_tokens, Some(3));
        assert_eq!(results[0].context_used_tokens, Some(14));
        assert_eq!(results[1].text.as_deref(), Some("Hello"));
        assert_eq!(results[2].tool_name.as_deref(), Some("mcp__RepoPromptCE__read_file"));
        let invocation_id = results[2].tool_invocation_id.expect("tool_call must carry an invocation id");
        let args: Value = serde_json::from_str(results[2].tool_args_json.as_deref().unwrap()).unwrap();
        assert_eq!(args, json!({"path": "Sources/App.swift"}));

        let tool_result = translator
            .parse_ndjson_line(&line(json!({
                "type": "user",
                "message": {
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": "toolu_1",
                        "content": [{"type": "text", "text": "contents"}]
                    }]
                }
            })))
            .remove(0);
        assert_eq!(tool_result.kind, "tool_result");
        assert_eq!(tool_result.tool_name.as_deref(), Some("mcp__RepoPromptCE__read_file"));
        assert_eq!(tool_result.tool_output.as_deref(), Some("contents"));
        assert_eq!(tool_result.tool_invocation_id, Some(invocation_id));
        assert_eq!(
            tool_result.tool_is_error, None,
            "Host-owned tool result errors are tracked by the host completion handler, not inferred here."
        );
    }

    /// Rust arm of `ClaudeSDKNDJSONTranslatorTests
    /// .testLifecycleAndStreamSmokeCoversSessionCancellationDeltaStopAndContextUsage`.
    #[test]
    fn lifecycle_and_stream_smoke_covers_session_cancellation_delta_stop_and_context_usage() {
        let mut translator = Translator::default();

        let init_results = translator.parse_ndjson_line(&line(json!({
            "type": "system", "subtype": "init", "session_id": "claude-session-1"
        })));
        assert_eq!(init_results.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), [LIFECYCLE_TYPE]);
        assert_eq!(translator.cli_session_id.as_deref(), Some("claude-session-1"));

        let usage = translator.parse_ndjson_line(&line(json!({
            "type": "stream_event",
            "event": {"type": "message_start", "message": {"usage": {"inputTokens": 4, "outputTokens": 0, "cacheReadInputTokens": 6}}}
        })));
        assert_eq!(usage[0].kind, "usage");
        assert_eq!(usage[0].context_used_tokens, Some(10));

        let delta = translator.parse_ndjson_line(&line(json!({
            "type": "stream_event",
            "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "partial"}}
        })));
        assert_eq!(delta[0].kind, "content");
        assert_eq!(delta[0].text.as_deref(), Some("partial"));

        let stop = translator.parse_ndjson_line(&line(json!({
            "type": "stream_event",
            "event": {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn"},
                "usage": {"input_tokens": 4, "output_tokens": 9}
            }
        })));
        assert_eq!(stop.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["usage", "message_stop"]);
        assert_eq!(stop.last().unwrap().stop_reason.as_deref(), Some("end_turn"));

        let cancelled = translator.parse_ndjson_line(&line(json!({
            "type": "result",
            "subtype": "error_during_execution",
            "session_id": "claude-session-2",
            "is_error": true,
            "errors": ["Request was aborted by user"],
            "stop_reason": "cancelled",
            "usage": {"input_tokens": 11, "output_tokens": 0},
            "total_cost_usd": 0.12
        })));
        assert_eq!(cancelled.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["message_stop"]);
        let cancelled_stop = &cancelled[0];
        assert_eq!(cancelled_stop.provider_session_id.as_deref(), Some("claude-session-2"));
        assert_eq!(cancelled_stop.prompt_tokens, Some(11));
        assert_eq!(cancelled_stop.completion_tokens, Some(0));
        assert_eq!(cancelled_stop.cost, Some(0.12));
        assert_eq!(cancelled_stop.stop_reason.as_deref(), Some("cancelled"));
        assert_eq!(translator.cli_session_id.as_deref(), Some("claude-session-2"));
    }

    #[test]
    fn thinking_blocks_and_deltas_are_dropped_while_reasoning_feature_disabled() {
        assert!(!REASONING_EXTRACTION_ENABLED, "flip this test's expectations if the upstream feature flag ever flips");
        let mut translator = Translator::default();
        let assistant = translator.parse_ndjson_line(&line(json!({
            "type": "assistant",
            "message": {"content": [
                {"type": "thinking", "thinking": "pondering"},
                {"type": "text", "text": "Here is the answer."}
            ]}
        })));
        assert_eq!(assistant.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["content"]);
        assert_eq!(assistant[0].text.as_deref(), Some("Here is the answer."));

        let delta = translator.parse_ndjson_line(&line(json!({
            "type": "stream_event",
            "event": {"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": "more"}}
        })));
        assert!(delta.is_empty());
    }

    #[test]
    fn result_without_errors_emits_final_content_then_message_stop() {
        let mut translator = Translator::default();
        let results = translator.parse_ndjson_line(&line(json!({
            "type": "result",
            "subtype": "success",
            "session_id": "claude-session-realcapture-1",
            "result": "All done.",
            "total_cost_usd": 0.0421,
            "usage": {"input_tokens": 120, "output_tokens": 45},
            "stop_reason": "end_turn"
        })));
        assert_eq!(results.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["final_content", "message_stop"]);
        assert_eq!(results[0].text.as_deref(), Some("All done."));
        let stop = &results[1];
        assert_eq!(stop.prompt_tokens, Some(120));
        assert_eq!(stop.completion_tokens, Some(45));
        assert_eq!(stop.cost, Some(0.0421));
        assert_eq!(stop.provider_session_id.as_deref(), Some("claude-session-realcapture-1"));
        assert_eq!(stop.stop_reason.as_deref(), Some("end_turn"));
        assert_eq!(stop.context_used_tokens, None);
    }

    #[test]
    fn result_with_genuine_error_is_not_suppressed() {
        let mut translator = Translator::default();
        let results = translator.parse_ndjson_line(&line(json!({
            "type": "result",
            "subtype": "error_max_turns",
            "is_error": true,
            "errors": ["Maximum turns exceeded for this task"],
            "session_id": "claude-session-realcapture-2",
            "usage": {"input_tokens": 50, "output_tokens": 10}
        })));
        assert_eq!(results.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["error", "message_stop"]);
        assert_eq!(results[0].text.as_deref(), Some("Maximum turns exceeded for this task"));
        assert_eq!(results[1].provider_session_id.as_deref(), Some("claude-session-realcapture-2"));
    }

    #[test]
    fn session_state_changed_sequence_including_idle_emits_lowercased_trimmed_text() {
        let mut translator = Translator::default();
        let texts: Vec<String> = [
            json!({"type": "system", "subtype": "session_state_changed", "session_state": "running"}),
            json!({"type": "system", "subtype": "session_state_changed", "current_state": "Compacting"}),
            json!({"type": "system", "subtype": "session_state_changed", "state": "IDLE"}),
        ]
        .into_iter()
        .map(|value| {
            let results = translator.parse_ndjson_line(&line(value));
            assert_eq!(results.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["session_state_changed"]);
            results[0].text.clone().unwrap()
        })
        .collect();
        assert_eq!(texts, ["running", "compacting", "idle"]);
    }

    #[test]
    fn suppression_rules_match_d2() {
        let suppressed_task = StreamResult { text: Some("Task started — build".to_string()), ..StreamResult::new("system") };
        assert!(should_suppress_user_facing_stream_result(&suppressed_task));

        let passthrough_system =
            StreamResult { text: Some("Compacting context".to_string()), ..StreamResult::new("system") };
        assert!(!should_suppress_user_facing_stream_result(&passthrough_system));

        let suppressed_error =
            StreamResult { text: Some("Request was aborted".to_string()), ..StreamResult::new("error") };
        assert!(should_suppress_user_facing_stream_result(&suppressed_error));

        let genuine_error =
            StreamResult { text: Some("Maximum turns exceeded".to_string()), ..StreamResult::new("error") };
        assert!(!should_suppress_user_facing_stream_result(&genuine_error));
    }

    #[test]
    fn auth_status_with_a_mixed_output_array_drops_the_whole_output_not_just_the_bad_element() {
        // Mirrors Swift's `(json["output"] as? [String])?` cast: one non-string element fails the
        // WHOLE cast (output stays nil), not "join the string elements and skip the rest".
        let mut translator = Translator::default();
        let results = translator.parse_ndjson_line(&line(json!({
            "type": "auth_status",
            "isAuthenticating": true,
            "output": ["fine", 42],
            "error": "boom"
        })));
        assert_eq!(results[0].text.as_deref(), Some("Authenticating — boom"), "the mixed-type output array must be dropped entirely, not partially joined");
    }

    #[test]
    fn task_notification_joins_task_id_status_and_summary() {
        let mut translator = Translator::default();
        let results = translator.parse_ndjson_line(&line(json!({
            "type": "system",
            "subtype": "task_notification",
            "task_id": "t-1",
            "status": "running",
            "summary": "halfway there"
        })));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].text.as_deref(), Some("Task update — t-1 — running — halfway there"));
    }

    /// Byte-exact against a real macOS Foundation run: `JSONSerialization.data(withJSONObject:
    /// ["b": 2, "a": ["x": 1, "y": [1,2,3]], "c": "hello"], options: [.prettyPrinted, .sortedKeys])`.
    #[test]
    fn foundation_pretty_printed_json_matches_a_captured_foundation_sample_byte_for_byte() {
        let value = json!({"b": 2, "a": {"x": 1, "y": [1, 2, 3]}, "c": "hello"});
        let expected = "{\n  \"a\" : {\n    \"x\" : 1,\n    \"y\" : [\n      1,\n      2,\n      3\n    ]\n  },\n  \"b\" : 2,\n  \"c\" : \"hello\"\n}";
        assert_eq!(foundation_pretty_printed_json(&value), expected);
    }

    /// Byte-exact against a real macOS Foundation run for the empty-container special case:
    /// `JSONSerialization.data(withJSONObject: ["a": []], options: [.prettyPrinted, .sortedKeys])`
    /// emits a blank second line before the closing bracket, not the compact `[]` a naive port
    /// (e.g. `serde_json::to_string_pretty`) would produce.
    #[test]
    fn foundation_pretty_printed_json_matches_foundations_empty_container_quirk() {
        let value = json!({"a": []});
        assert_eq!(foundation_pretty_printed_json(&value), "{\n  \"a\" : [\n\n  ]\n}");
        assert_eq!(foundation_pretty_printed_json(&json!({})), "{\n\n}");
    }

    #[test]
    fn tool_result_content_with_a_mixed_array_falls_through_to_the_generic_path() {
        // Mirrors Swift's `value as? [[String: Any]]` cast: one non-dictionary element fails the
        // WHOLE cast, so this must NOT extract "a" from the text block and ignore the string --
        // it must fall through to pretty-printing the entire array.
        let value = json!([{"type": "text", "text": "a"}, "raw-string-not-a-block"]);
        let output = serialize_tool_result_content(Some(&value));
        assert_eq!(output, foundation_pretty_printed_json(&value));
        assert_ne!(output, "a", "must not silently drop the non-dictionary element");
    }

    #[test]
    fn number_to_int_rejects_bool_and_fractional_double() {
        assert_eq!(number_to_int(Some(&json!(42))), Some(42));
        assert_eq!(number_to_int(Some(&json!(42.0))), Some(42));
        assert_eq!(number_to_int(Some(&json!(42.5))), None);
        assert_eq!(number_to_int(Some(&json!(true))), None);
        assert_eq!(number_to_int(Some(&json!("17"))), Some(17));
    }
}
