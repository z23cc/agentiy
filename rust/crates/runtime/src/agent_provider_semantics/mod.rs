//! ADR-0011 P6-c (B track; design §4.1.1 layer table, §5.6, §8 row "P6-c"):
//! Codex/ACP protocol semantics and MCP permission-policy evaluation.
//!
//! Sits above the existing `agent_provider` / `provider_json_rpc` transport.
//! Everything here is a pure function or value-state reducer: no I/O, no
//! clocks, no identity generation. Time and identities are inputs. Presentation
//! and durable append stay where they are; this module is the future semantic
//! owner, proven equivalent first (P7-1 / P7-2 gate).
//!
//! Inventory:
//!
//! | Swift | Rust |
//! |-------|------|
//! | `MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch` + proto `PermissionPolicy` | [`permission`] |
//! | `ACPDefaultSessionUpdateNormalizer` + provider adapters + option policy | [`acp`] |
//! | `CodexNativeSessionController` classify/parse + model collapse/selection | [`codex`] |
//! | Codex bash / file-change lifecycle synthesis (P6 leftover) | [`codex_lifecycle`] |

#![allow(clippy::module_name_repetitions)]

pub mod acp;
pub mod canonical;
pub mod codex;
pub mod codex_lifecycle;
mod json;
pub mod permission;

pub use acp::{
    AcpDecisionMapping, AcpPermissionOption, AcpProviderId, AcpSemanticState, OpenCodeToolProfile,
    auto_approval_option_id, is_auto_selectable, map_approval_decision, normalize_session_update,
    preferred_allow_option_id, preferred_reject_option_id, terminal_event, terminal_from_stop_reason,
};
pub use codex::{
    CodexModelOption, CodexModelSpecifier, CodexReasoningEffort, CodexSelection,
    CodexSemanticState, CodexServerRequestKind, CodexTurnStatus, build_approval_result,
    build_permissions_result, classify_server_request, collapse_model_options, map_turn_status,
    negotiate_selection, parse_approval_request,
};
pub use codex_lifecycle::{
    BashItem, CodexLifecycleState, CommandExecutionRunningUpdate, FileChangeLifecycleState,
    ToolLifecycleEvent, apply_command_execution_running_update, parse_command_execution_running_update,
    sanitize_command_output, with_command_execution_running_status,
};
pub use permission::{
    AutoApprovalMatch, AutoApprovalSource, PermissionEvalReason, PermissionEvalRequest,
    PermissionEvalResult, evaluate as evaluate_permission_policy, repo_prompt_auto_approval_match,
};
