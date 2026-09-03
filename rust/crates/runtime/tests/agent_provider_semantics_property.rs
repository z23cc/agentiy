//! ADR-0011 P6-c: property tests for Codex/ACP semantic reducers and the
//! permission-policy evaluator. The Swift ⇄ Rust equivalence is proven by the
//! differential harness; these tests pin absorbing-terminal and first-match
//! laws. No untrusted bytes are decoded here (parsed JSON / typed fields), so
//! there is no new fuzz target.

use proptest::prelude::*;

use agentry_proto::agent_host::v1::{
    ApprovalKind, ApprovalPolicy, PermissionPolicy, ToolDisposition, ToolPreference,
};
use agentry_runtime::agent_provider_semantics::acp::{
    AcpSemanticState, terminal_event,
};
use agentry_runtime::agent_provider_semantics::codex::CodexSemanticState;
use agentry_runtime::agent_provider_semantics::codex_lifecycle::{
    FileChangeLifecycleState, sanitize_command_output,
};
use agentry_runtime::agent_provider_semantics::permission::{
    PermissionEvalReason, PermissionEvalRequest, evaluate as evaluate_permission_policy,
};

fn disposition_strategy() -> impl Strategy<Value = ToolDisposition> {
    prop_oneof![
        Just(ToolDisposition::Allow),
        Just(ToolDisposition::Deny),
        Just(ToolDisposition::Ask),
    ]
}

fn approval_strategy() -> impl Strategy<Value = ApprovalPolicy> {
    prop_oneof![
        Just(ApprovalPolicy::OnRequest),
        Just(ApprovalPolicy::UnlessTrusted),
        Just(ApprovalPolicy::Never),
        Just(ApprovalPolicy::DeclineUnattended),
        Just(ApprovalPolicy::Unspecified),
    ]
}

proptest! {
    #[test]
    fn first_tool_preference_wins(
        first in disposition_strategy(),
        second in disposition_strategy(),
        policy in approval_strategy(),
    ) {
        let policy = PermissionPolicy {
            approval_policy: policy as i32,
            tool_preferences: vec![
                ToolPreference { tool_id: "read_file".into(), disposition: first as i32 },
                ToolPreference { tool_id: "read_file".into(), disposition: second as i32 },
            ],
            provider_settings: Vec::new(),
            interaction_timeout_seconds: 0,
        };
        let result = evaluate_permission_policy(
            &policy,
            &PermissionEvalRequest {
                tool_id: "read_file".into(),
                request_tool_name: Some("read_file".into()),
                request_payload_json: "{}".into(),
                provider_trusted: false,
                kind: ApprovalKind::CommandExecution,
            },
        );
        prop_assert_eq!(result.disposition, first);
        prop_assert_eq!(result.reason, PermissionEvalReason::ToolPreference);
    }

    #[test]
    fn decline_unattended_never_denies(
        trusted in any::<bool>(),
        tool in "[A-Za-z_]{1,12}",
    ) {
        let policy = PermissionPolicy {
            approval_policy: ApprovalPolicy::DeclineUnattended as i32,
            tool_preferences: Vec::new(),
            provider_settings: Vec::new(),
            interaction_timeout_seconds: 0,
        };
        let result = evaluate_permission_policy(
            &policy,
            &PermissionEvalRequest {
                tool_id: tool,
                request_tool_name: None,
                request_payload_json: "{}".into(),
                provider_trusted: trusted,
                kind: ApprovalKind::CommandExecution,
            },
        );
        prop_assert_ne!(result.disposition, ToolDisposition::Deny);
    }

    #[test]
    fn acp_terminal_is_absorbing(first in "cancelled|completed|failed", second in "cancelled|completed|failed") {
        let mut state = AcpSemanticState::new();
        state.apply_events(&[terminal_event(Some(&first), "run", "t1")]);
        let first_reason = state.turn_terminal.clone();
        state.apply_events(&[terminal_event(Some(&second), "run", "t2")]);
        prop_assert_eq!(state.turn_terminal.clone(), first_reason);
        prop_assert!(state.is_terminal());
    }

    #[test]
    fn codex_terminal_is_absorbing(status in "completed|interrupted|failed") {
        let mut state = CodexSemanticState::new();
        let _ = state.apply("turn/started", r#"{"turn":{"id":"t1"}}"#, "run", None);
        let completed = format!(r#"{{"turn":{{"id":"t1","status":"{status}"}}}}"#);
        let first = state.apply("turn/completed", &completed, "run", None);
        prop_assert_eq!(first.len(), 1);
        prop_assert!(state.is_terminal());
        let second = state.apply(
            "turn/completed",
            r#"{"turn":{"id":"t1","status":"failed"}}"#,
            "run",
            None,
        );
        prop_assert!(second.is_empty());
        prop_assert!(state.is_terminal());
    }

    #[test]
    fn sanitizer_is_idempotent(raw in r"[\x08\r\x1b a-zA-Z0-9\[\]]{0,48}") {
        let once = sanitize_command_output(&raw);
        let twice = sanitize_command_output(&once);
        prop_assert_eq!(once, twice);
    }

    #[test]
    fn file_change_late_delta_suppressed_after_complete(
        item in "[A-Za-z0-9_-]{1,12}",
        delta in "[A-Za-z0-9 ]{0,24}",
    ) {
        let mut state = FileChangeLifecycleState::new();
        let params = format!(
            r#"{{"item":{{"id":"{item}","type":"fileChange","status":"completed"}}}}"#
        );
        let _ = state.apply_lifecycle("item/started", &params);
        let _ = state.apply_lifecycle("item/completed", &params);
        let late = format!(r#"{{"itemId":"{item}","delta":"{delta}"}}"#);
        prop_assert!(state.apply_output_delta(&late).is_none());
    }
}
