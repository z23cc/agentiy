//! MCP permission-policy evaluator and the RepoPrompt auto-approval matcher.
//!
//! The evaluator is the P6-c product-policy function: `PermissionPolicy` +
//! `ToolPreference` + a pending tool/approval request → `allow | deny | ask`.
//! Presentation and "no client attached" routing stay on the host (design §5.6:
//! zero attached clients wait; they do not auto-deny). `DECLINE_UNATTENDED`
//! therefore evaluates to `ask`, same as `ON_REQUEST`.

use agentry_proto::agent_host::v1::{
    ApprovalKind, ApprovalPolicy, PermissionPolicy, ToolDisposition, ToolPreference,
};
use serde_json::{Map, Value};

use super::json::{collect_strings, first_string, parse_object};
use crate::agent_claude::tool_owned::{
    REPO_PROMPT_MCP_SERVER_NAME, is_repoprompt_tool_name, resolve_repoprompt_tool_name,
};

/// Inputs the evaluator needs that are not already on `PermissionPolicy`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PermissionEvalRequest {
    pub tool_id: String,
    pub request_tool_name: Option<String>,
    pub request_payload_json: String,
    pub provider_trusted: bool,
    pub kind: ApprovalKind,
}

/// Why the evaluator chose a disposition. Proto has no structured reason field
/// (reported as a P6-c gap); this is the local vocabulary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PermissionEvalReason {
    ToolPreference,
    RepoPromptAutoApproval,
    ApprovalPolicyNever,
    ApprovalPolicyUnlessTrusted,
    ApprovalPolicyAsk,
}

/// `source` tags from `MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AutoApprovalSource {
    TopLevelToolName,
    NestedToolName,
    ServerIdentifier,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AutoApprovalMatch {
    pub source: AutoApprovalSource,
    pub normalized_tool_name: Option<String>,
    pub server_identifier: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionEvalResult {
    pub disposition: ToolDisposition,
    pub reason: PermissionEvalReason,
    pub matched_tool_id: Option<String>,
    pub auto_approval: Option<AutoApprovalMatch>,
}

/// Evaluate session policy against one pending tool/approval request.
///
/// Priority:
/// 1. First `tool_preferences` match (exact, then case-insensitive, then
///    RepoPrompt canonical alias). Explicit `DENY`/`ALLOW`/`ASK` wins.
/// 2. RepoPrompt auto-approval match → `ALLOW` (today's product overlay).
/// 3. `approval_policy`: `NEVER` → allow; `UNLESS_TRUSTED` → allow if trusted
///    else ask; everything else (including `DECLINE_UNATTENDED`) → ask.
#[must_use]
pub fn evaluate(policy: &PermissionPolicy, request: &PermissionEvalRequest) -> PermissionEvalResult {
    let payload = parse_object(&request.request_payload_json).unwrap_or_default();
    let auto_approval = repo_prompt_auto_approval_match(
        request.request_tool_name.as_deref(),
        &payload,
    );

    if let Some((preference, matched_tool_id)) =
        matching_tool_preference(&policy.tool_preferences, request, auto_approval.as_ref())
    {
        let disposition = ToolDisposition::try_from(preference.disposition)
            .unwrap_or(ToolDisposition::Unspecified);
        if matches!(
            disposition,
            ToolDisposition::Allow | ToolDisposition::Deny | ToolDisposition::Ask
        ) {
            return PermissionEvalResult {
                disposition,
                reason: PermissionEvalReason::ToolPreference,
                matched_tool_id: Some(matched_tool_id),
                auto_approval,
            };
        }
    }

    if auto_approval.is_some() {
        return PermissionEvalResult {
            disposition: ToolDisposition::Allow,
            reason: PermissionEvalReason::RepoPromptAutoApproval,
            matched_tool_id: request_tool_id(request, auto_approval.as_ref()),
            auto_approval,
        };
    }

    let approval_policy =
        ApprovalPolicy::try_from(policy.approval_policy).unwrap_or(ApprovalPolicy::Unspecified);
    match approval_policy {
        ApprovalPolicy::Never => PermissionEvalResult {
            disposition: ToolDisposition::Allow,
            reason: PermissionEvalReason::ApprovalPolicyNever,
            matched_tool_id: None,
            auto_approval: None,
        },
        ApprovalPolicy::UnlessTrusted if request.provider_trusted => PermissionEvalResult {
            disposition: ToolDisposition::Allow,
            reason: PermissionEvalReason::ApprovalPolicyUnlessTrusted,
            matched_tool_id: None,
            auto_approval: None,
        },
        ApprovalPolicy::UnlessTrusted
        | ApprovalPolicy::OnRequest
        | ApprovalPolicy::DeclineUnattended
        | ApprovalPolicy::Unspecified => PermissionEvalResult {
            disposition: ToolDisposition::Ask,
            reason: PermissionEvalReason::ApprovalPolicyAsk,
            matched_tool_id: None,
            auto_approval: None,
        },
    }
}

fn request_tool_id(
    request: &PermissionEvalRequest,
    auto_approval: Option<&AutoApprovalMatch>,
) -> Option<String> {
    if !request.tool_id.trim().is_empty() {
        return Some(request.tool_id.clone());
    }
    auto_approval
        .and_then(|match_| match_.normalized_tool_name.clone())
        .or_else(|| request.request_tool_name.clone())
}

fn matching_tool_preference<'a>(
    preferences: &'a [ToolPreference],
    request: &PermissionEvalRequest,
    auto_approval: Option<&AutoApprovalMatch>,
) -> Option<(&'a ToolPreference, String)> {
    let candidates = preference_candidates(request, auto_approval);
    for preference in preferences {
        let preference_id = preference.tool_id.trim();
        if preference_id.is_empty() {
            continue;
        }
        for candidate in &candidates {
            if preference_matches(preference_id, candidate) {
                return Some((preference, preference.tool_id.clone()));
            }
        }
    }
    None
}

fn preference_candidates(
    request: &PermissionEvalRequest,
    auto_approval: Option<&AutoApprovalMatch>,
) -> Vec<String> {
    let mut candidates = Vec::new();
    push_unique(&mut candidates, Some(request.tool_id.as_str()));
    push_unique(&mut candidates, request.request_tool_name.as_deref());
    if let Some(match_) = auto_approval {
        push_unique(&mut candidates, match_.normalized_tool_name.as_deref());
    }
    if let Some(canonical) = canonical_tool_name(request.tool_id.as_str()) {
        push_unique(&mut candidates, Some(canonical.as_str()));
    }
    if let Some(name) = request.request_tool_name.as_deref()
        && let Some(canonical) = canonical_tool_name(name)
    {
        push_unique(&mut candidates, Some(canonical.as_str()));
    }
    candidates
}

fn preference_matches(preference_id: &str, candidate: &str) -> bool {
    if preference_id == candidate {
        return true;
    }
    if preference_id.eq_ignore_ascii_case(candidate) {
        return true;
    }
    match (canonical_tool_name(preference_id), canonical_tool_name(candidate)) {
        (Some(left), Some(right)) => left == right,
        _ => false,
    }
}

fn push_unique(values: &mut Vec<String>, candidate: Option<&str>) {
    let Some(raw) = candidate else {
        return;
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return;
    }
    if values.iter().any(|existing| existing == trimmed) {
        return;
    }
    values.push(trimmed.to_string());
}

fn canonical_tool_name(raw: &str) -> Option<String> {
    resolve_repoprompt_tool_name(Some(raw))?.canonical_name
}

fn normalized_tool_name(raw: &str) -> String {
    resolve_repoprompt_tool_name(Some(raw))
        .map(|resolved| resolved.normalized_name)
        .unwrap_or_else(|| raw.trim().to_ascii_lowercase())
}

fn is_tool_name_with_server_prefix(raw: &str) -> bool {
    resolve_repoprompt_tool_name(Some(raw))
        .is_some_and(|resolved| resolved.has_explicit_server_prefix)
}

/// `MCPIntegrationHelper.isRepoPromptServerIdentifier`.
#[must_use]
pub fn is_repoprompt_server_identifier(raw: Option<&str>) -> bool {
    let Some(raw) = raw else {
        return false;
    };
    let lowered = raw.trim().to_ascii_lowercase();
    if lowered.is_empty() {
        return false;
    }
    let server = REPO_PROMPT_MCP_SERVER_NAME.to_ascii_lowercase();
    lowered == server || lowered.contains(&server)
}

/// `MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch`.
#[must_use]
pub fn repo_prompt_auto_approval_match(
    request_tool_name: Option<&str>,
    payload: &Map<String, Value>,
) -> Option<AutoApprovalMatch> {
    if let Some(tool_name) = request_tool_name
        && is_repoprompt_tool_name(tool_name)
    {
        return Some(AutoApprovalMatch {
            source: AutoApprovalSource::TopLevelToolName,
            normalized_tool_name: Some(normalized_tool_name(tool_name)),
            server_identifier: None,
        });
    }

    if let Some(match_) = label_match(request_tool_name) {
        return Some(match_);
    }

    for label in label_candidates(payload) {
        if let Some(match_) = label_match(Some(label.as_str())) {
            return Some(match_);
        }
    }

    for tool_name in tool_name_candidates(payload) {
        if is_repoprompt_tool_name(&tool_name) {
            return Some(AutoApprovalMatch {
                source: AutoApprovalSource::NestedToolName,
                normalized_tool_name: Some(normalized_tool_name(&tool_name)),
                server_identifier: None,
            });
        }
    }

    if let Some(server_name) = server_identifier_in(payload) {
        return Some(AutoApprovalMatch {
            source: AutoApprovalSource::ServerIdentifier,
            normalized_tool_name: None,
            server_identifier: Some(server_name),
        });
    }

    None
}

/// `ACPAgentSessionController.isStrictACPRepoPromptPermissionMatch`.
#[must_use]
pub fn is_strict_acp_repoprompt_match(
    match_: &AutoApprovalMatch,
    request_tool_name: Option<&str>,
    payload: &Map<String, Value>,
) -> bool {
    match match_.source {
        AutoApprovalSource::ServerIdentifier => true,
        AutoApprovalSource::TopLevelToolName => {
            if request_tool_name.is_some_and(is_tool_name_with_server_prefix) {
                return true;
            }
            server_identifier_in(payload).is_some()
        }
        AutoApprovalSource::NestedToolName => {
            contains_server_prefixed_tool_name(payload) || server_identifier_in(payload).is_some()
        }
    }
}

#[must_use]
pub fn contains_server_prefixed_tool_name(payload: &Map<String, Value>) -> bool {
    tool_name_candidates(payload)
        .iter()
        .any(|tool_name| is_tool_name_with_server_prefix(tool_name))
}

fn server_identifier_in(payload: &Map<String, Value>) -> Option<String> {
    for server_name in server_candidates(payload) {
        if is_repoprompt_server_identifier(Some(server_name.as_str())) {
            return Some(server_name);
        }
    }
    None
}

fn label_match(raw_label: Option<&str>) -> Option<AutoApprovalMatch> {
    let label = raw_label.map(str::trim).filter(|value| !value.is_empty())?;
    let legacy = format!("({REPO_PROMPT_MCP_SERVER_NAME} MCP Server)");
    if label.to_ascii_lowercase().contains(&legacy.to_ascii_lowercase()) {
        return Some(AutoApprovalMatch {
            source: AutoApprovalSource::ServerIdentifier,
            normalized_tool_name: None,
            server_identifier: Some(REPO_PROMPT_MCP_SERVER_NAME.to_string()),
        });
    }

    let (server_label, tool_label) = label.split_once(':')?;
    let server_label = server_label.trim();
    let tool_label = tool_label.trim();
    if !is_repoprompt_permission_server_label(server_label) || canonical_tool_name(tool_label).is_none()
    {
        return None;
    }
    Some(AutoApprovalMatch {
        source: AutoApprovalSource::ServerIdentifier,
        normalized_tool_name: Some(normalized_tool_name(tool_label)),
        server_identifier: Some(server_label.to_string()),
    })
}

fn is_repoprompt_permission_server_label(raw_label: &str) -> bool {
    let lowered = raw_label.trim().to_ascii_lowercase();
    if lowered.is_empty() {
        return false;
    }
    let server = REPO_PROMPT_MCP_SERVER_NAME.to_ascii_lowercase();
    lowered == server
        || lowered.starts_with(&format!("{server}-"))
        || lowered.starts_with(&format!("{server} "))
        || lowered.contains(&format!("{server} mcp server"))
}

fn label_candidates(payload: &Map<String, Value>) -> Vec<String> {
    collect_strings(
        payload,
        &[
            &["title"],
            &["toolTitle"],
            &["tool_title"],
            &["displayName"],
            &["display_name"],
            &["rawInput", "title"],
            &["rawInput", "toolTitle"],
            &["rawInput", "tool_title"],
            &["toolCall", "title"],
            &["toolCall", "name"],
            &["toolCall", "displayName"],
            &["toolCall", "display_name"],
            &["rawInput", "toolCall", "title"],
            &["rawInput", "toolCall", "name"],
            &["rawInput", "toolCall", "displayName"],
            &["rawInput", "toolCall", "display_name"],
            &["request", "title"],
            &["request", "toolTitle"],
            &["request", "tool_title"],
            &["request", "toolCall", "title"],
            &["request", "toolCall", "name"],
            &["request", "toolCall", "displayName"],
            &["request", "toolCall", "display_name"],
            &["request", "_meta", "tool_title"],
            &["request", "_meta", "tool_description"],
        ],
    )
}

fn server_candidates(payload: &Map<String, Value>) -> Vec<String> {
    collect_strings(
        payload,
        &[
            &["server_name"],
            &["serverName"],
            &["server"],
            &["mcp_server"],
            &["mcpServer"],
            &["rawInput", "server_name"],
            &["rawInput", "serverName"],
            &["rawInput", "server"],
            &["rawInput", "mcp_server"],
            &["rawInput", "mcpServer"],
            &["serverInfo", "name"],
            &["tool", "server"],
            &["tool", "server_name"],
            &["tool", "serverName"],
            &["toolCall", "server"],
            &["toolCall", "server_name"],
            &["toolCall", "serverName"],
            &["rawInput", "toolCall", "server"],
            &["rawInput", "toolCall", "server_name"],
            &["rawInput", "toolCall", "serverName"],
            &["request", "server"],
            &["request", "server_name"],
            &["request", "serverName"],
            &["request", "tool", "server"],
            &["request", "tool", "server_name"],
            &["request", "tool", "serverName"],
            &["request", "toolCall", "server"],
            &["request", "toolCall", "server_name"],
            &["request", "toolCall", "serverName"],
            &["request", "_meta", "connector_name"],
        ],
    )
}

fn tool_name_candidates(payload: &Map<String, Value>) -> Vec<String> {
    let mut values = collect_strings(
        payload,
        &[
            &["tool_name"],
            &["toolName"],
            &["name"],
            &["rawInput", "tool_name"],
            &["rawInput", "toolName"],
            &["rawInput", "name"],
            &["tool", "tool_name"],
            &["tool", "toolName"],
            &["tool", "name"],
            &["toolCall", "tool_name"],
            &["toolCall", "toolName"],
            &["toolCall", "name"],
            &["toolCall", "title"],
            &["rawInput", "tool", "tool_name"],
            &["rawInput", "tool", "toolName"],
            &["rawInput", "tool", "name"],
            &["rawInput", "toolCall", "tool_name"],
            &["rawInput", "toolCall", "toolName"],
            &["rawInput", "toolCall", "name"],
            &["rawInput", "toolCall", "title"],
            &["request", "tool_name"],
            &["request", "toolName"],
            &["request", "name"],
            &["request", "tool", "tool_name"],
            &["request", "tool", "toolName"],
            &["request", "tool", "name"],
            &["request", "toolCall", "tool_name"],
            &["request", "toolCall", "toolName"],
            &["request", "toolCall", "name"],
            &["request", "toolCall", "title"],
            &["request", "_meta", "tool_title"],
            &["request", "_meta", "tool_description"],
            &["request", "_meta", "connector_name"],
        ],
    );

    if let Some(Value::Array(suggestions)) = payload.get("permission_suggestions") {
        for suggestion in suggestions {
            let Some(rules) = suggestion.get("rules").and_then(Value::as_array) else {
                continue;
            };
            for rule in rules {
                if let Some(object) = rule.as_object()
                    && let Some(tool_name) = first_string(object, &["toolName"])
                    && !values.iter().any(|existing| existing == &tool_name)
                {
                    values.push(tool_name);
                }
            }
        }
    }
    values
}

/// Kind inference used by Codex `parseApprovalRequest` and ACP `approvalKind(for:)`.
#[must_use]
pub fn approval_kind_for_method(method: &str, command_present: bool) -> ApprovalKind {
    let normalized = normalize_approval_key(method);
    if normalized.contains("filechange") || normalized.contains("file_change") {
        return ApprovalKind::FileChange;
    }
    if normalized.contains("commandexecution") || normalized.contains("command") {
        return ApprovalKind::CommandExecution;
    }
    if command_present {
        ApprovalKind::CommandExecution
    } else {
        ApprovalKind::FileChange
    }
}

/// ACP `approvalKind(for: toolKind)`.
#[must_use]
pub fn approval_kind_for_tool_kind(tool_kind: Option<&str>) -> ApprovalKind {
    match tool_kind.map(str::trim) {
        Some("edit" | "delete" | "move") => ApprovalKind::FileChange,
        _ => ApprovalKind::CommandExecution,
    }
}

#[must_use]
pub fn normalize_approval_key(method: &str) -> String {
    method
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .map(|ch| ch.to_ascii_lowercase())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn policy(approval: ApprovalPolicy, preferences: Vec<ToolPreference>) -> PermissionPolicy {
        PermissionPolicy {
            approval_policy: approval as i32,
            tool_preferences: preferences,
            provider_settings: Vec::new(),
            interaction_timeout_seconds: 0,
        }
    }

    fn pref(tool_id: &str, disposition: ToolDisposition) -> ToolPreference {
        ToolPreference {
            tool_id: tool_id.to_string(),
            disposition: disposition as i32,
        }
    }

    fn request(tool_id: &str, tool_name: Option<&str>, payload: Value, trusted: bool) -> PermissionEvalRequest {
        PermissionEvalRequest {
            tool_id: tool_id.to_string(),
            request_tool_name: tool_name.map(str::to_string),
            request_payload_json: payload.to_string(),
            provider_trusted: trusted,
            kind: ApprovalKind::CommandExecution,
        }
    }

    #[test]
    fn tool_preference_deny_beats_auto_approval() {
        let payload = json!({"tool_name": "mcp__RepoPromptCE__read_file"});
        let result = evaluate(
            &policy(
                ApprovalPolicy::OnRequest,
                vec![pref("read_file", ToolDisposition::Deny)],
            ),
            &request("read_file", Some("mcp__RepoPromptCE__read_file"), payload, false),
        );
        assert_eq!(result.disposition, ToolDisposition::Deny);
        assert_eq!(result.reason, PermissionEvalReason::ToolPreference);
    }

    #[test]
    fn repo_prompt_auto_approval_allows_on_request() {
        let payload = json!({
            "tool_name": "mcp__RepoPromptCE__read_file",
            "tool_use_id": "toolu_read_1",
            "input": {"path": "Sources/App.swift"}
        });
        let result = evaluate(
            &policy(ApprovalPolicy::OnRequest, Vec::new()),
            &request(
                "",
                Some("mcp__RepoPromptCE__read_file"),
                payload,
                false,
            ),
        );
        assert_eq!(result.disposition, ToolDisposition::Allow);
        assert_eq!(result.reason, PermissionEvalReason::RepoPromptAutoApproval);
        assert_eq!(
            result.auto_approval.as_ref().map(|match_| match_.source),
            Some(AutoApprovalSource::TopLevelToolName)
        );
        assert_eq!(
            result
                .auto_approval
                .as_ref()
                .and_then(|match_| match_.normalized_tool_name.as_deref()),
            Some("read_file")
        );
    }

    #[test]
    fn nested_permission_suggestions_match() {
        let payload = json!({
            "permission_suggestions": [{"rules": [{"toolName": "mcp__RepoPromptCE__read_file"}]}]
        });
        let match_ = repo_prompt_auto_approval_match(Some("Bash"), payload.as_object().unwrap());
        assert_eq!(
            match_.as_ref().map(|value| value.source),
            Some(AutoApprovalSource::NestedToolName)
        );
        assert_eq!(
            match_
                .as_ref()
                .and_then(|value| value.normalized_tool_name.as_deref()),
            Some("read_file")
        );
    }

    #[test]
    fn unknown_bash_is_not_auto_approved() {
        let payload = json!({"input": {"command": "rm -rf /tmp/example"}});
        assert!(repo_prompt_auto_approval_match(Some("Bash"), payload.as_object().unwrap()).is_none());
        let result = evaluate(
            &policy(ApprovalPolicy::OnRequest, Vec::new()),
            &request("", Some("Bash"), payload, false),
        );
        assert_eq!(result.disposition, ToolDisposition::Ask);
    }

    #[test]
    fn never_allows_without_preference() {
        let result = evaluate(
            &policy(ApprovalPolicy::Never, Vec::new()),
            &request("bash", Some("Bash"), json!({}), false),
        );
        assert_eq!(result.disposition, ToolDisposition::Allow);
        assert_eq!(result.reason, PermissionEvalReason::ApprovalPolicyNever);
    }

    #[test]
    fn unless_trusted_asks_when_untrusted() {
        let result = evaluate(
            &policy(ApprovalPolicy::UnlessTrusted, Vec::new()),
            &request("bash", Some("Bash"), json!({}), false),
        );
        assert_eq!(result.disposition, ToolDisposition::Ask);
    }

    #[test]
    fn decline_unattended_asks_not_denies() {
        let result = evaluate(
            &policy(ApprovalPolicy::DeclineUnattended, Vec::new()),
            &request("bash", Some("Bash"), json!({}), false),
        );
        assert_eq!(result.disposition, ToolDisposition::Ask);
        assert_eq!(result.reason, PermissionEvalReason::ApprovalPolicyAsk);
    }

}
