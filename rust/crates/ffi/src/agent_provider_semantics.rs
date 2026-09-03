//! ADR-0011 P6-c (B track; design §4.1.1, §5.6, §8 "P6-c"): bounded synchronous
//! UniFFI surface over Codex/ACP protocol semantics and the MCP permission
//! evaluator. Reuses `AgentHost*V1` records. No `RuntimeIdentity`: these are
//! pure functions / value-state reducers the host embeds. No new `CoreError`
//! variant — malformed JSON params yield empty output, matching Swift ignore.

use std::sync::{Arc, Mutex, MutexGuard};

use crate::agent_host_types::{
    AgentHostApprovalDecisionKindV1, AgentHostApprovalKindV1, AgentHostApprovalRequestV1,
    AgentHostPermissionPolicyV1, AgentHostRuntimeEventV1, AgentHostToolDispositionV1,
};
use crate::errors::CoreError;
use crate::panic_guard::PanicGuard;
use agentry_proto::agent_host::v1;
use agentry_runtime as runtime;
use agentry_runtime::agent_provider_semantics::acp::{
    AcpPermissionOption, AcpProviderId, AcpSemanticState, OpenCodeToolProfile,
};
use agentry_runtime::agent_provider_semantics::codex::{
    CodexModelOption, CodexReasoningEffort, CodexSemanticState, CodexServerRequestKind,
};
use agentry_runtime::agent_provider_semantics::permission::{
    AutoApprovalSource, PermissionEvalReason, PermissionEvalRequest,
};

fn lock<T>(state: &Mutex<T>) -> Result<MutexGuard<'_, T>, CoreError> {
    state.lock().map_err(|_| CoreError::RuntimePoisoned)
}

fn events_from(events: Vec<v1::RuntimeEvent>) -> Result<Vec<AgentHostRuntimeEventV1>, CoreError> {
    events.into_iter().map(TryInto::try_into).collect()
}

// ---- shared records ----------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentPermissionEvalReasonV1 {
    ToolPreference,
    RepoPromptAutoApproval,
    ApprovalPolicyNever,
    ApprovalPolicyUnlessTrusted,
    ApprovalPolicyAsk,
}

impl From<PermissionEvalReason> for AgentPermissionEvalReasonV1 {
    fn from(value: PermissionEvalReason) -> Self {
        match value {
            PermissionEvalReason::ToolPreference => Self::ToolPreference,
            PermissionEvalReason::RepoPromptAutoApproval => Self::RepoPromptAutoApproval,
            PermissionEvalReason::ApprovalPolicyNever => Self::ApprovalPolicyNever,
            PermissionEvalReason::ApprovalPolicyUnlessTrusted => Self::ApprovalPolicyUnlessTrusted,
            PermissionEvalReason::ApprovalPolicyAsk => Self::ApprovalPolicyAsk,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRepoPromptAutoApprovalSourceV1 {
    TopLevelToolName,
    NestedToolName,
    ServerIdentifier,
}

impl From<AutoApprovalSource> for AgentRepoPromptAutoApprovalSourceV1 {
    fn from(value: AutoApprovalSource) -> Self {
        match value {
            AutoApprovalSource::TopLevelToolName => Self::TopLevelToolName,
            AutoApprovalSource::NestedToolName => Self::NestedToolName,
            AutoApprovalSource::ServerIdentifier => Self::ServerIdentifier,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentRepoPromptAutoApprovalMatchV1 {
    pub source: AgentRepoPromptAutoApprovalSourceV1,
    pub normalized_tool_name: Option<String>,
    pub server_identifier: Option<String>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentPermissionEvalRequestV1 {
    pub tool_id: String,
    pub request_tool_name: Option<String>,
    pub request_payload_json: String,
    pub provider_trusted: bool,
    pub kind: AgentHostApprovalKindV1,
}

impl From<AgentPermissionEvalRequestV1> for PermissionEvalRequest {
    fn from(value: AgentPermissionEvalRequestV1) -> Self {
        Self {
            tool_id: value.tool_id,
            request_tool_name: value.request_tool_name,
            request_payload_json: value.request_payload_json,
            provider_trusted: value.provider_trusted,
            kind: v1::ApprovalKind::from(value.kind),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentPermissionEvalResultV1 {
    pub disposition: AgentHostToolDispositionV1,
    pub reason: AgentPermissionEvalReasonV1,
    pub matched_tool_id: Option<String>,
    pub auto_approval: Option<AgentRepoPromptAutoApprovalMatchV1>,
    pub canonical: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentProviderAcpProviderIdV1 {
    OpenCode,
    Cursor,
    GrokBuild,
}

impl From<AgentProviderAcpProviderIdV1> for AcpProviderId {
    fn from(value: AgentProviderAcpProviderIdV1) -> Self {
        match value {
            AgentProviderAcpProviderIdV1::OpenCode => Self::OpenCode,
            AgentProviderAcpProviderIdV1::Cursor => Self::Cursor,
            AgentProviderAcpProviderIdV1::GrokBuild => Self::GrokBuild,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentProviderOpenCodeToolProfileV1 {
    Headless,
    NoTools,
    AgentMode,
}

impl From<AgentProviderOpenCodeToolProfileV1> for OpenCodeToolProfile {
    fn from(value: AgentProviderOpenCodeToolProfileV1) -> Self {
        match value {
            AgentProviderOpenCodeToolProfileV1::Headless => Self::Headless,
            AgentProviderOpenCodeToolProfileV1::NoTools => Self::NoTools,
            AgentProviderOpenCodeToolProfileV1::AgentMode => Self::AgentMode,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentProviderAcpPermissionOptionV1 {
    pub option_id: String,
    pub kind: String,
}

impl From<AgentProviderAcpPermissionOptionV1> for AcpPermissionOption {
    fn from(value: AgentProviderAcpPermissionOptionV1) -> Self {
        Self {
            option_id: value.option_id,
            kind: value.kind,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentProviderAcpDecisionMappingV1 {
    pub outcome: String,
    pub option_id: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentProviderCodexServerRequestKindV1 {
    RequestUserInput,
    AuthTokensRefresh,
    McpElicitation,
    Permissions,
    DynamicToolUnsupported,
    Approval,
    UnknownUnsupported,
}

impl From<CodexServerRequestKind> for AgentProviderCodexServerRequestKindV1 {
    fn from(value: CodexServerRequestKind) -> Self {
        match value {
            CodexServerRequestKind::RequestUserInput => Self::RequestUserInput,
            CodexServerRequestKind::AuthTokensRefresh => Self::AuthTokensRefresh,
            CodexServerRequestKind::McpElicitation => Self::McpElicitation,
            CodexServerRequestKind::Permissions => Self::Permissions,
            CodexServerRequestKind::DynamicToolUnsupported => Self::DynamicToolUnsupported,
            CodexServerRequestKind::Approval => Self::Approval,
            CodexServerRequestKind::UnknownUnsupported => Self::UnknownUnsupported,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentProviderCodexReasoningEffortV1 {
    None,
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
    Ultra,
}

impl From<CodexReasoningEffort> for AgentProviderCodexReasoningEffortV1 {
    fn from(value: CodexReasoningEffort) -> Self {
        match value {
            CodexReasoningEffort::None => Self::None,
            CodexReasoningEffort::Minimal => Self::Minimal,
            CodexReasoningEffort::Low => Self::Low,
            CodexReasoningEffort::Medium => Self::Medium,
            CodexReasoningEffort::High => Self::High,
            CodexReasoningEffort::Xhigh => Self::Xhigh,
            CodexReasoningEffort::Max => Self::Max,
            CodexReasoningEffort::Ultra => Self::Ultra,
        }
    }
}

impl From<AgentProviderCodexReasoningEffortV1> for CodexReasoningEffort {
    fn from(value: AgentProviderCodexReasoningEffortV1) -> Self {
        match value {
            AgentProviderCodexReasoningEffortV1::None => Self::None,
            AgentProviderCodexReasoningEffortV1::Minimal => Self::Minimal,
            AgentProviderCodexReasoningEffortV1::Low => Self::Low,
            AgentProviderCodexReasoningEffortV1::Medium => Self::Medium,
            AgentProviderCodexReasoningEffortV1::High => Self::High,
            AgentProviderCodexReasoningEffortV1::Xhigh => Self::Xhigh,
            AgentProviderCodexReasoningEffortV1::Max => Self::Max,
            AgentProviderCodexReasoningEffortV1::Ultra => Self::Ultra,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentProviderCodexModelOptionV1 {
    pub raw_value: String,
    pub display_name: String,
    pub is_placeholder_default: bool,
    pub is_provider_default: bool,
    pub supported_reasoning_efforts: Vec<AgentProviderCodexReasoningEffortV1>,
    pub default_reasoning_effort: Option<AgentProviderCodexReasoningEffortV1>,
}

impl From<AgentProviderCodexModelOptionV1> for CodexModelOption {
    fn from(value: AgentProviderCodexModelOptionV1) -> Self {
        Self {
            raw_value: value.raw_value,
            display_name: value.display_name,
            is_placeholder_default: value.is_placeholder_default,
            is_provider_default: value.is_provider_default,
            supported_reasoning_efforts: value
                .supported_reasoning_efforts
                .into_iter()
                .map(Into::into)
                .collect(),
            default_reasoning_effort: value.default_reasoning_effort.map(Into::into),
        }
    }
}

impl From<CodexModelOption> for AgentProviderCodexModelOptionV1 {
    fn from(value: CodexModelOption) -> Self {
        Self {
            raw_value: value.raw_value,
            display_name: value.display_name,
            is_placeholder_default: value.is_placeholder_default,
            is_provider_default: value.is_provider_default,
            supported_reasoning_efforts: value
                .supported_reasoning_efforts
                .into_iter()
                .map(Into::into)
                .collect(),
            default_reasoning_effort: value.default_reasoning_effort.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentProviderCodexSelectionV1 {
    pub model_raw: String,
    pub reasoning_effort: Option<AgentProviderCodexReasoningEffortV1>,
}

// ---- permission evaluator ----------------------------------------------------------

#[derive(uniffi::Object)]
pub struct AgentPermissionPolicyEvaluatorV1 {
    guard: PanicGuard,
}

#[uniffi::export]
impl AgentPermissionPolicyEvaluatorV1 {
    #[uniffi::constructor]
    #[must_use]
    pub fn new() -> Arc<Self> {
        runtime::install_panic_hook();
        Arc::new(Self {
            guard: PanicGuard::new(),
        })
    }

    pub fn evaluate(
        &self,
        policy: AgentHostPermissionPolicyV1,
        request: AgentPermissionEvalRequestV1,
    ) -> Result<AgentPermissionEvalResultV1, CoreError> {
        self.guard.call(|| {
            let policy: v1::PermissionPolicy = policy.into();
            let result =
                runtime::agent_provider_semantics::evaluate_permission_policy(&policy, &request.into());
            Ok(AgentPermissionEvalResultV1 {
                disposition: AgentHostToolDispositionV1::from(result.disposition),
                reason: result.reason.into(),
                matched_tool_id: result.matched_tool_id.clone(),
                auto_approval: result.auto_approval.as_ref().map(|match_| {
                    AgentRepoPromptAutoApprovalMatchV1 {
                        source: match_.source.into(),
                        normalized_tool_name: match_.normalized_tool_name.clone(),
                        server_identifier: match_.server_identifier.clone(),
                    }
                }),
                canonical: runtime::agent_provider_semantics::canonical::permission_eval(&result),
            })
        })
    }

    pub fn match_repo_prompt_auto_approval(
        &self,
        request_tool_name: Option<String>,
        request_payload_json: String,
    ) -> Result<Option<AgentRepoPromptAutoApprovalMatchV1>, CoreError> {
        self.guard.call(|| {
            let payload = serde_json::from_str::<serde_json::Value>(&request_payload_json)
                .ok()
                .and_then(|value| value.as_object().cloned())
                .unwrap_or_default();
            Ok(
                runtime::agent_provider_semantics::repo_prompt_auto_approval_match(
                    request_tool_name.as_deref(),
                    &payload,
                )
                .map(|match_| AgentRepoPromptAutoApprovalMatchV1 {
                    source: match_.source.into(),
                    normalized_tool_name: match_.normalized_tool_name,
                    server_identifier: match_.server_identifier,
                }),
            )
        })
    }
}

// ---- ACP semantics -----------------------------------------------------------------

#[derive(uniffi::Object)]
pub struct AgentProviderAcpSemanticsV1 {
    guard: PanicGuard,
    state: Mutex<AcpSemanticState>,
}

#[uniffi::export]
impl AgentProviderAcpSemanticsV1 {
    #[uniffi::constructor]
    #[must_use]
    pub fn new() -> Arc<Self> {
        runtime::install_panic_hook();
        Arc::new(Self {
            guard: PanicGuard::new(),
            state: Mutex::new(AcpSemanticState::new()),
        })
    }

    pub fn reset(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.reset();
            Ok(())
        })
    }

    pub fn normalize_session_update(
        &self,
        payload_json: String,
        provider: AgentProviderAcpProviderIdV1,
        fallback_tool_call_id: String,
        run_id: String,
        turn_id: String,
        open_code_profile: AgentProviderOpenCodeToolProfileV1,
    ) -> Result<Vec<AgentHostRuntimeEventV1>, CoreError> {
        self.guard.call(|| {
            let events = runtime::agent_provider_semantics::normalize_session_update(
                &payload_json,
                provider.into(),
                &fallback_tool_call_id,
                &run_id,
                &turn_id,
                open_code_profile.into(),
            );
            lock(&self.state)?.apply_events(&events);
            events_from(events)
        })
    }

    pub fn apply_stop_reason(
        &self,
        stop_reason: Option<String>,
        run_id: String,
        turn_id: String,
    ) -> Result<AgentHostRuntimeEventV1, CoreError> {
        self.guard.call(|| {
            let event = runtime::agent_provider_semantics::terminal_event(
                stop_reason.as_deref(),
                &run_id,
                &turn_id,
            );
            lock(&self.state)?.apply_events(std::slice::from_ref(&event));
            event.try_into()
        })
    }

    pub fn is_auto_selectable(
        &self,
        option_id: Option<String>,
        provider: AgentProviderAcpProviderIdV1,
    ) -> Result<bool, CoreError> {
        self.guard.call(|| {
            Ok(runtime::agent_provider_semantics::is_auto_selectable(
                option_id.as_deref(),
                provider.into(),
            ))
        })
    }

    pub fn map_approval_decision(
        &self,
        decision: AgentHostApprovalDecisionKindV1,
        options: Vec<AgentProviderAcpPermissionOptionV1>,
        provider: AgentProviderAcpProviderIdV1,
    ) -> Result<AgentProviderAcpDecisionMappingV1, CoreError> {
        self.guard.call(|| {
            let options: Vec<AcpPermissionOption> = options.into_iter().map(Into::into).collect();
            let mapped = runtime::agent_provider_semantics::map_approval_decision(
                v1::ApprovalDecisionKind::from(decision),
                &options,
                provider.into(),
            );
            Ok(AgentProviderAcpDecisionMappingV1 {
                outcome: mapped.outcome,
                option_id: mapped.option_id,
            })
        })
    }

    pub fn auto_approval_option_id(
        &self,
        request_tool_name: Option<String>,
        payload_json: String,
        options: Vec<AgentProviderAcpPermissionOptionV1>,
        provider: AgentProviderAcpProviderIdV1,
    ) -> Result<Option<String>, CoreError> {
        self.guard.call(|| {
            let options: Vec<AcpPermissionOption> = options.into_iter().map(Into::into).collect();
            Ok(runtime::agent_provider_semantics::auto_approval_option_id(
                request_tool_name.as_deref(),
                &payload_json,
                &options,
                provider.into(),
            ))
        })
    }

    pub fn approval_kind_for_tool_kind(
        &self,
        tool_kind: Option<String>,
    ) -> Result<AgentHostApprovalKindV1, CoreError> {
        self.guard.call(|| {
            Ok(AgentHostApprovalKindV1::from(
                runtime::agent_provider_semantics::permission::approval_kind_for_tool_kind(
                    tool_kind.as_deref(),
                ),
            ))
        })
    }

    pub fn settle_approval(&self, approval_id: String) -> Result<bool, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.settle_approval(&approval_id)))
    }

    pub fn is_terminal(&self) -> Result<bool, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.is_terminal()))
    }

    pub fn canonical_state(&self) -> Result<String, CoreError> {
        self.guard.call(|| {
            Ok(runtime::agent_provider_semantics::canonical::acp_state(
                &*lock(&self.state)?,
            ))
        })
    }
}

// ---- Codex semantics ---------------------------------------------------------------

#[derive(uniffi::Object)]
pub struct AgentProviderCodexSemanticsV1 {
    guard: PanicGuard,
    state: Mutex<CodexSemanticState>,
}

#[uniffi::export]
impl AgentProviderCodexSemanticsV1 {
    #[uniffi::constructor]
    #[must_use]
    pub fn new() -> Arc<Self> {
        runtime::install_panic_hook();
        Arc::new(Self {
            guard: PanicGuard::new(),
            state: Mutex::new(CodexSemanticState::new()),
        })
    }

    pub fn reset(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.reset();
            Ok(())
        })
    }

    pub fn apply_notification(
        &self,
        method: String,
        params_json: String,
        run_id: String,
        request_id: Option<String>,
    ) -> Result<Vec<AgentHostRuntimeEventV1>, CoreError> {
        self.guard.call(|| {
            let events = lock(&self.state)?.apply(
                &method,
                &params_json,
                &run_id,
                request_id.as_deref(),
            );
            events_from(events)
        })
    }

    pub fn classify_server_request(
        &self,
        method: String,
    ) -> Result<Option<AgentProviderCodexServerRequestKindV1>, CoreError> {
        self.guard.call(|| {
            Ok(
                runtime::agent_provider_semantics::classify_server_request(&method).map(Into::into),
            )
        })
    }

    pub fn parse_approval_request(
        &self,
        request_id: String,
        method: String,
        params_json: String,
        active_thread_id: Option<String>,
        current_turn_id: Option<String>,
    ) -> Result<Option<AgentHostApprovalRequestV1>, CoreError> {
        self.guard.call(|| {
            let Some(params) = serde_json::from_str::<serde_json::Value>(&params_json)
                .ok()
                .and_then(|value| value.as_object().cloned())
            else {
                return Ok(None);
            };
            runtime::agent_provider_semantics::parse_approval_request(
                &request_id,
                &method,
                &params,
                active_thread_id.as_deref(),
                current_turn_id.as_deref(),
            )
            .map(TryInto::try_into)
            .transpose()
        })
    }

    pub fn map_turn_status(&self, raw: String) -> Result<String, CoreError> {
        self.guard
            .call(|| Ok(runtime::agent_provider_semantics::map_turn_status(&raw).to_string()))
    }

    pub fn collapse_model_options(
        &self,
        options: Vec<AgentProviderCodexModelOptionV1>,
    ) -> Result<Vec<AgentProviderCodexModelOptionV1>, CoreError> {
        self.guard.call(|| {
            let options: Vec<CodexModelOption> = options.into_iter().map(Into::into).collect();
            Ok(runtime::agent_provider_semantics::collapse_model_options(&options)
                .into_iter()
                .map(Into::into)
                .collect())
        })
    }

    pub fn negotiate_selection(
        &self,
        selected_model_raw: String,
        explicit_effort: Option<String>,
        last_used_effort: Option<String>,
        supported: Vec<AgentProviderCodexReasoningEffortV1>,
        default_effort: Option<AgentProviderCodexReasoningEffortV1>,
        preserving_explicit_effort: bool,
    ) -> Result<AgentProviderCodexSelectionV1, CoreError> {
        self.guard.call(|| {
            let supported: Vec<CodexReasoningEffort> = supported.into_iter().map(Into::into).collect();
            let selection = runtime::agent_provider_semantics::negotiate_selection(
                &selected_model_raw,
                explicit_effort.as_deref(),
                last_used_effort.as_deref(),
                &supported,
                default_effort.map(Into::into),
                preserving_explicit_effort,
            );
            Ok(AgentProviderCodexSelectionV1 {
                model_raw: selection.model_raw,
                reasoning_effort: selection.reasoning_effort.map(Into::into),
            })
        })
    }

    pub fn build_approval_result(
        &self,
        decision: AgentHostApprovalDecisionKindV1,
        kind: AgentHostApprovalKindV1,
        amendment_json: Option<String>,
    ) -> Result<String, CoreError> {
        self.guard.call(|| {
            Ok(runtime::agent_provider_semantics::build_approval_result(
                v1::ApprovalDecisionKind::from(decision),
                v1::ApprovalKind::from(kind),
                amendment_json.as_deref(),
            ))
        })
    }

    pub fn build_permissions_result(
        &self,
        decision: AgentHostApprovalDecisionKindV1,
        permissions_json: String,
    ) -> Result<String, CoreError> {
        self.guard.call(|| {
            Ok(runtime::agent_provider_semantics::build_permissions_result(
                v1::ApprovalDecisionKind::from(decision),
                &permissions_json,
            ))
        })
    }

    pub fn settle_approval(&self, approval_id: String) -> Result<bool, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.settle_approval(&approval_id)))
    }

    pub fn is_terminal(&self) -> Result<bool, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.is_terminal()))
    }

    pub fn canonical_state(&self) -> Result<String, CoreError> {
        self.guard.call(|| {
            Ok(runtime::agent_provider_semantics::canonical::codex_state(
                &*lock(&self.state)?,
            ))
        })
    }
}

// ---- Codex bash / file-change lifecycle (P6 leftover) --------------------------------

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AgentProviderCodexLifecycleEventV1 {
    pub kind: String,
    pub name: String,
    pub invocation_id: Option<String>,
    pub args_json: Option<String>,
    pub result_json: Option<String>,
    pub is_error: Option<bool>,
    pub dedup_key: String,
}

impl From<runtime::agent_provider_semantics::ToolLifecycleEvent> for AgentProviderCodexLifecycleEventV1 {
    fn from(value: runtime::agent_provider_semantics::ToolLifecycleEvent) -> Self {
        Self {
            kind: value.kind_name().to_string(),
            name: value.name().to_string(),
            invocation_id: value.invocation_id().map(str::to_string),
            args_json: value.args_json().map(str::to_string),
            result_json: value.result_json().map(str::to_string),
            is_error: value.is_error(),
            dedup_key: value.dedup_key().to_string(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AgentProviderCodexBashItemV1 {
    pub kind: String,
    pub tool_name: Option<String>,
    pub invocation_id: Option<String>,
    pub args_json: Option<String>,
    pub result_json: Option<String>,
    pub tool_is_error: Option<bool>,
}

impl From<AgentProviderCodexBashItemV1> for runtime::agent_provider_semantics::BashItem {
    fn from(value: AgentProviderCodexBashItemV1) -> Self {
        Self {
            kind: value.kind,
            tool_name: value.tool_name,
            invocation_id: value.invocation_id,
            args_json: value.args_json,
            result_json: value.result_json,
            tool_is_error: value.tool_is_error,
        }
    }
}

impl From<runtime::agent_provider_semantics::BashItem> for AgentProviderCodexBashItemV1 {
    fn from(value: runtime::agent_provider_semantics::BashItem) -> Self {
        Self {
            kind: value.kind,
            tool_name: value.tool_name,
            invocation_id: value.invocation_id,
            args_json: value.args_json,
            result_json: value.result_json,
            tool_is_error: value.tool_is_error,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AgentProviderCodexRunningUpdateV1 {
    pub invocation_id: Option<String>,
    pub process_id: Option<String>,
    pub appended_output: Option<String>,
    pub seals_assistant_boundary: bool,
}

impl From<AgentProviderCodexRunningUpdateV1> for runtime::agent_provider_semantics::CommandExecutionRunningUpdate {
    fn from(value: AgentProviderCodexRunningUpdateV1) -> Self {
        Self {
            invocation_id: value.invocation_id,
            process_id: value.process_id,
            appended_output: value.appended_output,
            seals_assistant_boundary: value.seals_assistant_boundary,
        }
    }
}

impl From<runtime::agent_provider_semantics::CommandExecutionRunningUpdate> for AgentProviderCodexRunningUpdateV1 {
    fn from(value: runtime::agent_provider_semantics::CommandExecutionRunningUpdate) -> Self {
        Self {
            invocation_id: value.invocation_id,
            process_id: value.process_id,
            appended_output: value.appended_output,
            seals_assistant_boundary: value.seals_assistant_boundary,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AgentProviderCodexRunningApplyV1 {
    pub applied: bool,
    pub items: Vec<AgentProviderCodexBashItemV1>,
}

#[derive(uniffi::Object)]
pub struct AgentProviderCodexLifecycleV1 {
    guard: PanicGuard,
    state: Mutex<runtime::agent_provider_semantics::CodexLifecycleState>,
}

#[uniffi::export]
impl AgentProviderCodexLifecycleV1 {
    #[uniffi::constructor]
    #[must_use]
    pub fn new() -> Arc<Self> {
        runtime::install_panic_hook();
        Arc::new(Self {
            guard: PanicGuard::new(),
            state: Mutex::new(runtime::agent_provider_semantics::CodexLifecycleState::new()),
        })
    }

    pub fn reset(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.reset();
            Ok(())
        })
    }

    pub fn apply_file_change(
        &self,
        method: String,
        params_json: String,
    ) -> Result<Option<AgentProviderCodexLifecycleEventV1>, CoreError> {
        self.guard.call(|| {
            Ok(lock(&self.state)?
                .apply_file_change(&method, &params_json)
                .map(Into::into))
        })
    }

    pub fn apply_file_change_lifecycle(
        &self,
        method: String,
        params_json: String,
    ) -> Result<Option<AgentProviderCodexLifecycleEventV1>, CoreError> {
        self.guard.call(|| {
            Ok(lock(&self.state)?
                .file_change
                .apply_lifecycle(&method, &params_json)
                .map(Into::into))
        })
    }

    pub fn apply_file_change_output_delta(
        &self,
        params_json: String,
    ) -> Result<Option<AgentProviderCodexLifecycleEventV1>, CoreError> {
        self.guard.call(|| {
            Ok(lock(&self.state)?
                .file_change
                .apply_output_delta(&params_json)
                .map(Into::into))
        })
    }

    pub fn apply_command_execution_running_update(
        &self,
        update: AgentProviderCodexRunningUpdateV1,
        items: Vec<AgentProviderCodexBashItemV1>,
    ) -> Result<AgentProviderCodexRunningApplyV1, CoreError> {
        self.guard.call(|| {
            let mut items: Vec<runtime::agent_provider_semantics::BashItem> =
                items.into_iter().map(Into::into).collect();
            let applied = runtime::agent_provider_semantics::apply_command_execution_running_update(
                &update.into(),
                &mut items,
            );
            Ok(AgentProviderCodexRunningApplyV1 {
                applied,
                items: items.into_iter().map(Into::into).collect(),
            })
        })
    }

    pub fn parse_command_execution_running_update(
        &self,
        method: String,
        params_json: String,
    ) -> Result<Option<AgentProviderCodexRunningUpdateV1>, CoreError> {
        self.guard.call(|| {
            Ok(
                runtime::agent_provider_semantics::parse_command_execution_running_update(
                    &method,
                    &params_json,
                )
                .map(Into::into),
            )
        })
    }

    pub fn sanitize_command_output(&self, raw: String) -> Result<String, CoreError> {
        self.guard.call(|| {
            Ok(runtime::agent_provider_semantics::sanitize_command_output(&raw))
        })
    }

    pub fn with_command_execution_running_status(
        &self,
        result_json: Option<String>,
        process_id: Option<String>,
        append_output: Option<String>,
    ) -> Result<String, CoreError> {
        self.guard.call(|| {
            Ok(
                runtime::agent_provider_semantics::with_command_execution_running_status(
                    result_json.as_deref(),
                    process_id.as_deref(),
                    append_output.as_deref(),
                ),
            )
        })
    }

    pub fn canonical_state(&self) -> Result<String, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.canonical()))
    }
}
