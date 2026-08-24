//! P6-5 (design §3.2/§5.3 table row "Permission **protocol**", `docs/architecture/
//! rust-agent-claude-v1.md` §7.1's `approvalRequest`/`approvalCancelled` row): the `can_use_tool`
//! control-request **protocol** half only. Ported from
//! `ClaudeNativeProcessSessionController.swift:1770-1853` (`handleControlRequest`'s `can_use_tool`
//! case) and `:2011-2135` (`buildApprovalRequest`/`permissionResponsePayload`/
//! `allowPermissionResponsePayload`), with the **policy** half deliberately left out: auto-approval
//! matching (`repoPromptPermissionAutoApprovalMatch`, `MCPIntegrationHelper`), approval-request
//! modeling (`AgentApprovalRequest`, its `stableID` derivation), and secure-store decisions all stay
//! Swift/core-owned per `docs/architecture/provider-plugins.md`'s ownership table and design §3.2.
//!
//! **What that split means concretely.** This module never decides whether to auto-approve --
//! [`parse_can_use_tool_request`] always extracts the raw fields a caller needs to *either* run its
//! own auto-approval policy *or* surface a user-facing approval request; it is the caller's job
//! (Swift, today; the future scope's host-facing half at P6-6) to decide, then call
//! [`encode_permission_decision`] with the outcome. This module owns only: recognizing a
//! `can_use_tool` request, extracting its fields, and encoding the two decision shapes
//! (`allowPermissionResponsePayload`/the `"deny"` payload) into the wire's `control_response`
//! envelope -- unchanged from what `ClaudeSDKProtocolCodec`'s encoders already do (contract §2.1);
//! this module supplies the payload, not a new envelope encoding.

use serde_json::{Map, Value};

use super::codec::{self, ControlRequest};

/// Port of the fields `buildApprovalRequest(from:)` (`:2011-2018`) extracts from a `can_use_tool`
/// request's `request` object, *before* any policy (auto-approval matching, kind classification,
/// stable-ID derivation) is applied -- those stay Swift-side (module doc).
#[derive(Debug, Clone, PartialEq)]
pub struct CanUseToolRequest {
    pub request_id: String,
    /// The complete original `request` object. The protocol layer preserves it so the Swift-owned
    /// permission policy can evaluate the exact same nested labels/tool/server identifiers as the
    /// legacy controller instead of reconstructing a lossy subset from projected fields.
    pub request: Map<String, Value>,
    /// `payload["tool_name"]`, trimmed; `""` (not `"tool"`) when absent -- matches
    /// `buildApprovalRequest`'s local (`:2013`), which defaults to `"tool"` only at its own call
    /// site's `AgentApprovalRequest` construction, a policy-layer default this module does not
    /// reproduce (module doc: policy stays Swift-side).
    pub tool_name: String,
    pub input: Map<String, Value>,
    pub blocked_path: Option<String>,
    pub decision_reason: Option<String>,
    pub description: Option<String>,
    pub tool_use_id: Option<String>,
    /// `payload["permission_suggestions"]`, preserved for `.acceptForSession` /
    /// `.acceptWithExecpolicyAmendment` response parity.
    pub permission_suggestions: Vec<Map<String, Value>>,
}

/// Recognizes a `can_use_tool` control request and extracts its protocol-level fields. Returns
/// `None` for any other subtype -- port of `handleControlRequest`'s `switch request.subtype` having
/// exactly one case this module concerns itself with (`:1776-1777`); every other subtype (including
/// the `default` branch's "Unsupported control request subtype" error response, `:1840-1852`) is
/// out of this module's scope (it is a protocol-error reply, not a permission decision).
pub fn parse_can_use_tool_request(request: &ControlRequest) -> Option<CanUseToolRequest> {
    if request.subtype != "can_use_tool" {
        return None;
    }
    let payload = &request.request;
    Some(CanUseToolRequest {
        request_id: request.request_id.clone(),
        request: payload.clone(),
        tool_name: trimmed_string(payload, "tool_name").unwrap_or_default(),
        input: object_field(payload, "input").unwrap_or_default(),
        blocked_path: string_field(payload, "blocked_path"),
        decision_reason: string_field(payload, "decision_reason"),
        description: string_field(payload, "description"),
        tool_use_id: trimmed_string(payload, "tool_use_id"),
        permission_suggestions: object_array_field(payload, "permission_suggestions"),
    })
}

/// A permission decision, ported from `AgentApprovalDecision`'s two wire-relevant outcomes
/// (`permissionResponsePayload(decision:pendingRequest:)`, `:2088-2115`) -- `.accept`/
/// `.acceptForSession`/`.acceptWithExecpolicyAmendment` all collapse to `Allow` (the only
/// difference between them, `includeUpdatedPermissions`, is carried explicitly here rather than as
/// three decision variants); `.decline`/`.cancel` collapse to `Deny` (the only difference,
/// `interrupt: true`, is likewise carried explicitly).
#[derive(Debug, Clone, PartialEq)]
pub enum PermissionDecision {
    Allow {
        /// Port of `allowPermissionResponsePayload`'s `includeUpdatedPermissions` (`:2117-2135`):
        /// when `true` and the original request carried a non-empty `permission_suggestions` array,
        /// it is echoed back as `updatedPermissions`.
        include_updated_permissions: bool,
    },
    Deny {
        message: String,
        interrupt: bool,
    },
}

/// Port of `permissionResponsePayload`/`allowPermissionResponsePayload` (`:2088-2135`), producing
/// the **encoded control-response line** (matching `respondToPermissionRequest`'s
/// `encodeControlResponseSuccess` call, `:506-510` -- **both** allow and deny go through the
/// success-subtype encoder; `"behavior":"deny"` is a valid protocol payload, not a protocol error).
/// `original_input`/`permission_suggestions`/`tool_use_id` are the same fields
/// [`parse_can_use_tool_request`] extracted from the original request (contract: `updatedInput`
/// always echoes the *original* request's `input`, never the decision's own).
pub fn encode_permission_decision(
    request_id: &str,
    decision: &PermissionDecision,
    original_input: &Map<String, Value>,
    permission_suggestions: Option<&[Map<String, Value>]>,
    tool_use_id: Option<&str>,
) -> Vec<u8> {
    let response = permission_response_payload(
        decision,
        original_input,
        permission_suggestions,
        tool_use_id,
    );
    codec::encode_control_response_success(request_id, Some(&response))
}

/// Builds the exact response object before it is wrapped in the `control_response` envelope. This
/// is shared with the scope's DEBUG raw-event logger so observability records the same bytes/fields
/// that are actually sent rather than a separately reconstructed approximation.
#[must_use]
pub fn permission_response_payload(
    decision: &PermissionDecision,
    original_input: &Map<String, Value>,
    permission_suggestions: Option<&[Map<String, Value>]>,
    tool_use_id: Option<&str>,
) -> Map<String, Value> {
    match decision {
        PermissionDecision::Allow {
            include_updated_permissions,
        } => allow_permission_response_payload(
            original_input,
            *include_updated_permissions,
            permission_suggestions,
            tool_use_id,
        ),
        PermissionDecision::Deny { message, interrupt } => {
            let mut payload = Map::new();
            payload.insert("behavior".to_string(), Value::String("deny".to_string()));
            payload.insert("message".to_string(), Value::String(message.clone()));
            if *interrupt {
                payload.insert("interrupt".to_string(), Value::Bool(true));
            }
            payload
        }
    }
}

/// Port of `allowPermissionResponsePayload(pendingRequest:includeUpdatedPermissions:)`
/// (`:2117-2135`).
fn allow_permission_response_payload(
    original_input: &Map<String, Value>,
    include_updated_permissions: bool,
    permission_suggestions: Option<&[Map<String, Value>]>,
    tool_use_id: Option<&str>,
) -> Map<String, Value> {
    let mut payload = Map::new();
    payload.insert("behavior".to_string(), Value::String("allow".to_string()));
    payload.insert(
        "updatedInput".to_string(),
        Value::Object(original_input.clone()),
    );
    if include_updated_permissions {
        if let Some(suggestions) = permission_suggestions {
            if !suggestions.is_empty() {
                payload.insert(
                    "updatedPermissions".to_string(),
                    Value::Array(suggestions.iter().cloned().map(Value::Object).collect()),
                );
            }
        }
    }
    if let Some(tool_use_id) = tool_use_id {
        let trimmed = tool_use_id.trim();
        if !trimmed.is_empty() {
            payload.insert("toolUseID".to_string(), Value::String(trimmed.to_string()));
        }
    }
    payload
}

/// Port of the `default` branch's protocol-error reply (`:1840-1852`) for any control-request
/// subtype this module (and, at P6-6, the wider scope) does not recognize.
pub fn encode_unsupported_subtype_response(request_id: &str, subtype: &str) -> Vec<u8> {
    codec::encode_control_response_error(
        request_id,
        &format!("Unsupported control request subtype: {subtype}"),
    )
}

fn string_field(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_string)
}

fn trimmed_string(object: &Map<String, Value>, key: &str) -> Option<String> {
    string_field(object, key).map(|s| s.trim().to_string())
}

fn object_field(object: &Map<String, Value>, key: &str) -> Option<Map<String, Value>> {
    object.get(key).and_then(Value::as_object).cloned()
}

fn object_array_field(object: &Map<String, Value>, key: &str) -> Vec<Map<String, Value>> {
    object
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_object)
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn can_use_tool_request(payload: Value) -> ControlRequest {
        ControlRequest {
            request_id: "req-perm-1".to_string(),
            request: payload.as_object().unwrap().clone(),
            subtype: "can_use_tool".to_string(),
        }
    }

    #[test]
    fn recognizes_can_use_tool_and_extracts_every_field() {
        let request = can_use_tool_request(json!({
            "tool_name": "  Bash  ",
            "input": {"command": "ls"},
            "blocked_path": "/etc/shadow",
            "decision_reason": "matched a blocked pattern",
            "description": "list files",
            "tool_use_id": " toolu_1 ",
            "permission_suggestions": [{"type": "addRules", "rules": ["Bash(ls:*)"]}]
        }));
        let parsed = parse_can_use_tool_request(&request).expect("must recognize can_use_tool");
        assert_eq!(parsed.request_id, "req-perm-1");
        assert_eq!(parsed.tool_name, "Bash");
        assert_eq!(
            parsed.input.get("command").and_then(Value::as_str),
            Some("ls")
        );
        assert_eq!(parsed.blocked_path.as_deref(), Some("/etc/shadow"));
        assert_eq!(
            parsed.decision_reason.as_deref(),
            Some("matched a blocked pattern")
        );
        assert_eq!(parsed.description.as_deref(), Some("list files"));
        assert_eq!(parsed.tool_use_id.as_deref(), Some("toolu_1"));
        assert_eq!(
            parsed.request.get("tool_name").and_then(Value::as_str),
            Some("  Bash  ")
        );
        assert_eq!(parsed.permission_suggestions.len(), 1);
        assert_eq!(
            parsed.permission_suggestions[0]
                .get("type")
                .and_then(Value::as_str),
            Some("addRules")
        );
    }

    #[test]
    fn a_non_can_use_tool_subtype_is_not_recognized() {
        let mut request = can_use_tool_request(json!({}));
        request.subtype = "initialize".to_string();
        assert_eq!(parse_can_use_tool_request(&request), None);
    }

    #[test]
    fn missing_optional_fields_default_cleanly() {
        let request = can_use_tool_request(json!({}));
        let parsed = parse_can_use_tool_request(&request).unwrap();
        assert_eq!(parsed.tool_name, "");
        assert!(parsed.input.is_empty());
        assert_eq!(parsed.blocked_path, None);
        assert_eq!(parsed.tool_use_id, None);
        assert!(parsed.request.is_empty());
        assert!(parsed.permission_suggestions.is_empty());
    }

    #[test]
    fn allow_response_echoes_the_original_input_and_wraps_as_control_response_success() {
        let mut original_input = Map::new();
        original_input.insert(
            "path".to_string(),
            Value::String("Sources/App.swift".to_string()),
        );
        let encoded = encode_permission_decision(
            "req-perm-1",
            &PermissionDecision::Allow {
                include_updated_permissions: false,
            },
            &original_input,
            None,
            Some("toolu_1"),
        );
        let decoded: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(decoded["type"], "control_response");
        assert_eq!(decoded["response"]["subtype"], "success");
        assert_eq!(decoded["response"]["request_id"], "req-perm-1");
        assert_eq!(decoded["response"]["response"]["behavior"], "allow");
        assert_eq!(
            decoded["response"]["response"]["updatedInput"]["path"],
            "Sources/App.swift"
        );
        assert_eq!(decoded["response"]["response"]["toolUseID"], "toolu_1");
        assert!(
            decoded["response"]["response"]
                .get("updatedPermissions")
                .is_none()
        );
    }

    #[test]
    fn allow_response_includes_updated_permissions_only_when_requested_and_non_empty() {
        let original_input = Map::new();
        let mut suggestion = Map::new();
        suggestion.insert("type".to_string(), Value::String("addRules".to_string()));
        let suggestions = vec![suggestion];

        let without_flag = encode_permission_decision(
            "req-1",
            &PermissionDecision::Allow {
                include_updated_permissions: false,
            },
            &original_input,
            Some(&suggestions),
            None,
        );
        let decoded: Value = serde_json::from_slice(&without_flag).unwrap();
        assert!(
            decoded["response"]["response"]
                .get("updatedPermissions")
                .is_none()
        );

        let with_flag = encode_permission_decision(
            "req-1",
            &PermissionDecision::Allow {
                include_updated_permissions: true,
            },
            &original_input,
            Some(&suggestions),
            None,
        );
        let decoded: Value = serde_json::from_slice(&with_flag).unwrap();
        assert_eq!(
            decoded["response"]["response"]["updatedPermissions"][0]["type"],
            "addRules"
        );
    }

    #[test]
    fn deny_response_carries_the_message_and_optional_interrupt_flag_via_success_envelope() {
        let original_input = Map::new();
        let encoded = encode_permission_decision(
            "req-2",
            &PermissionDecision::Deny {
                message: "Permission denied by user.".to_string(),
                interrupt: false,
            },
            &original_input,
            None,
            None,
        );
        let decoded: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(
            decoded["response"]["subtype"], "success",
            "deny is a valid decision, not a protocol error"
        );
        assert_eq!(decoded["response"]["response"]["behavior"], "deny");
        assert_eq!(
            decoded["response"]["response"]["message"],
            "Permission denied by user."
        );
        assert!(decoded["response"]["response"].get("interrupt").is_none());

        let cancelled = encode_permission_decision(
            "req-3",
            &PermissionDecision::Deny {
                message: "Permission cancelled by user.".to_string(),
                interrupt: true,
            },
            &original_input,
            None,
            None,
        );
        let decoded: Value = serde_json::from_slice(&cancelled).unwrap();
        assert_eq!(decoded["response"]["response"]["interrupt"], true);
    }

    #[test]
    fn unsupported_subtype_encodes_as_a_control_response_error() {
        let encoded = encode_unsupported_subtype_response("req-4", "some_future_subtype");
        let decoded: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(decoded["response"]["subtype"], "error");
        assert_eq!(
            decoded["response"]["error"],
            "Unsupported control request subtype: some_future_subtype"
        );
    }
}
