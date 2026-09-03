//! Fixed-key-order JSON for the Swift ⇄ Rust differential harness.

use agentry_proto::agent_host::v1::{
    ApprovalRequest, RuntimeEvent, StreamResult, ToolDisposition, TurnCompleted, runtime_event,
};

use crate::agent_run_lifecycle::Canonical;

use super::acp::{AcpSemanticState, ToolCallPhase};
use super::codex::{CodexSemanticState, CodexToolPhase, CodexTurnStatus};
use super::permission::{
    AutoApprovalMatch, AutoApprovalSource, PermissionEvalReason, PermissionEvalResult,
};

/// Render a `RuntimeEvent` for cross-implementation comparison.
#[must_use]
pub fn runtime_event(event: &RuntimeEvent) -> String {
    let mut json = Canonical::object();
    json.string("runId", &event.run_id)
        .string("turnId", &event.turn_id);
    match event.kind.as_ref() {
        Some(runtime_event::Kind::Stream(stream)) => {
            json.raw("kind", &stream_result(stream));
        }
        Some(runtime_event::Kind::ApprovalRequest(request)) => {
            json.raw("kind", &approval_request(request));
        }
        Some(runtime_event::Kind::ApprovalCancelled(cancelled)) => {
            json.raw(
                "kind",
                &Canonical::object()
                    .string("type", "approvalCancelled")
                    .string("approvalId", &cancelled.approval_id)
                    .string("reason", &cancelled.reason)
                    .finish(),
            );
        }
        Some(runtime_event::Kind::TurnCompleted(completed)) => {
            json.raw("kind", &turn_completed(completed));
        }
        Some(runtime_event::Kind::Error(error)) => {
            json.raw(
                "kind",
                &Canonical::object()
                    .string("type", "error")
                    .string("code", &error.code)
                    .string("message", &error.message)
                    .bool("recoverable", error.recoverable)
                    .finish(),
            );
        }
        Some(runtime_event::Kind::RuntimeInit(init)) => {
            json.raw(
                "kind",
                &Canonical::object()
                    .string("type", "runtimeInit")
                    .string("providerSessionId", &init.provider_session_id)
                    .finish(),
            );
        }
        None => {
            json.raw("kind", "null");
        }
    }
    json.finish()
}

#[must_use]
pub fn stream_result(stream: &StreamResult) -> String {
    Canonical::object()
        .string("type", "stream")
        .string("itemType", &stream.item_type)
        .optional_string("text", stream.text.as_deref())
        .optional_string("reasoning", stream.reasoning.as_deref())
        .optional_string("toolName", stream.tool_name.as_deref())
        .optional_string("toolInvocationId", stream.tool_invocation_id.as_deref())
        .optional_string("contentMessageId", stream.content_message_id.as_deref())
        .finish()
}

#[must_use]
pub fn approval_request(request: &ApprovalRequest) -> String {
    Canonical::object()
        .string("type", "approvalRequest")
        .string("approvalId", &request.approval_id)
        .string("requestId", &request.request_id)
        .string("method", &request.method)
        .string("kind", kind_name(request.kind))
        .string("threadId", &request.thread_id)
        .string("turnId", &request.turn_id)
        .string("itemId", &request.item_id)
        .string("reason", &request.reason)
        .string("cwd", &request.cwd)
        .finish()
}

#[must_use]
pub fn turn_completed(completed: &TurnCompleted) -> String {
    Canonical::object()
        .string("type", "turnCompleted")
        .string("turnId", &completed.turn_id)
        .string("stopReason", &completed.stop_reason)
        .finish()
}

#[must_use]
pub fn permission_eval(result: &PermissionEvalResult) -> String {
    Canonical::object()
        .string("disposition", disposition_name(result.disposition))
        .string("reason", reason_name(result.reason))
        .optional_string("matchedToolId", result.matched_tool_id.as_deref())
        .raw(
            "autoApproval",
            &result
                .auto_approval
                .as_ref()
                .map(auto_approval)
                .unwrap_or_else(|| "null".to_string()),
        )
        .finish()
}

fn auto_approval(match_: &AutoApprovalMatch) -> String {
    Canonical::object()
        .string("source", source_name(match_.source))
        .optional_string("normalizedToolName", match_.normalized_tool_name.as_deref())
        .optional_string("serverIdentifier", match_.server_identifier.as_deref())
        .finish()
}

#[must_use]
pub fn acp_state(state: &AcpSemanticState) -> String {
    let mut tools = String::from("[");
    for (index, (id, phase)) in state.tools.iter().enumerate() {
        if index > 0 {
            tools.push(',');
        }
        tools.push_str(
            &Canonical::object()
                .string("id", id)
                .string("phase", acp_phase_name(*phase))
                .finish(),
        );
    }
    tools.push(']');
    Canonical::object()
        .optional_string("pendingApprovalId", state.pending_approval_id.as_deref())
        .optional_string("turnTerminal", state.turn_terminal.as_deref())
        .raw("tools", &tools)
        .finish()
}

#[must_use]
pub fn codex_state(state: &CodexSemanticState) -> String {
    let mut tools = String::from("[");
    for (index, (id, phase)) in state.tools.iter().enumerate() {
        if index > 0 {
            tools.push(',');
        }
        tools.push_str(
            &Canonical::object()
                .string("id", id)
                .string("phase", codex_phase_name(*phase))
                .finish(),
        );
    }
    tools.push(']');
    Canonical::object()
        .string("status", codex_status_name(state.status))
        .optional_string("turnId", state.turn_id.as_deref())
        .optional_string("pendingApprovalId", state.pending_approval_id.as_deref())
        .raw("tools", &tools)
        .finish()
}

fn kind_name(kind: i32) -> &'static str {
    match kind {
        1 => "commandExecution",
        2 => "fileChange",
        _ => "unspecified",
    }
}

fn disposition_name(value: ToolDisposition) -> &'static str {
    match value {
        ToolDisposition::Allow => "allow",
        ToolDisposition::Deny => "deny",
        ToolDisposition::Ask => "ask",
        ToolDisposition::Unspecified => "unspecified",
    }
}

fn reason_name(value: PermissionEvalReason) -> &'static str {
    match value {
        PermissionEvalReason::ToolPreference => "toolPreference",
        PermissionEvalReason::RepoPromptAutoApproval => "repoPromptAutoApproval",
        PermissionEvalReason::ApprovalPolicyNever => "approvalPolicyNever",
        PermissionEvalReason::ApprovalPolicyUnlessTrusted => "approvalPolicyUnlessTrusted",
        PermissionEvalReason::ApprovalPolicyAsk => "approvalPolicyAsk",
    }
}

fn source_name(value: AutoApprovalSource) -> &'static str {
    match value {
        AutoApprovalSource::TopLevelToolName => "topLevelToolName",
        AutoApprovalSource::NestedToolName => "nestedToolName",
        AutoApprovalSource::ServerIdentifier => "serverIdentifier",
    }
}

fn acp_phase_name(value: ToolCallPhase) -> &'static str {
    match value {
        ToolCallPhase::Pending => "pending",
        ToolCallPhase::Running => "running",
        ToolCallPhase::Completed => "completed",
        ToolCallPhase::Failed => "failed",
    }
}

fn codex_phase_name(value: CodexToolPhase) -> &'static str {
    match value {
        CodexToolPhase::Pending => "pending",
        CodexToolPhase::Running => "running",
        CodexToolPhase::Completed => "completed",
        CodexToolPhase::Failed => "failed",
    }
}

fn codex_status_name(value: CodexTurnStatus) -> &'static str {
    match value {
        CodexTurnStatus::Idle => "idle",
        CodexTurnStatus::InFlight => "inFlight",
        CodexTurnStatus::Completed => "completed",
        CodexTurnStatus::Interrupted => "interrupted",
        CodexTurnStatus::Failed => "failed",
    }
}
