//! ADR-0011 P6-a: typed UniFFI mirrors of the `agentry_runtime::agent_run_lifecycle` value
//! vocabulary (the Rust port of `DomainAgentRun*`). Every enum mirrors the Swift `package` enum
//! one-for-one -- there is no `Unspecified` member because the reducers cannot hold one -- so the
//! only fallible conversion is UUID text (`AgentRunLifecycleInvalidRequest`). UUIDs cross as RFC
//! 4122 text in either case and are rendered back lowercase; Swift's `UUID.uuidString` is
//! uppercase, so the differential harness compares through `UUID(uuidString:)`, not strings.

use crate::errors::CoreError;
use agentry_runtime::agent_run_lifecycle as lifecycle;

pub(crate) fn parse_uuid(field: &str, value: &str) -> Result<lifecycle::RunUuid, CoreError> {
    lifecycle::RunUuid::parse(value).map_err(|error| CoreError::AgentRunLifecycleInvalidRequest {
        message: format!("{field}: {error}"),
    })
}

fn parse_optional_uuid(
    field: &str,
    value: Option<&str>,
) -> Result<Option<lifecycle::RunUuid>, CoreError> {
    value.map(|value| parse_uuid(field, value)).transpose()
}

fn render_uuid(value: lifecycle::RunUuid) -> String {
    value.to_string()
}

fn render_optional_uuid(value: Option<lifecycle::RunUuid>) -> Option<String> {
    value.map(render_uuid)
}

// ---- enumerations -------------------------------------------------------------------------

macro_rules! mirror_enum {
    ($(#[$meta:meta])* $mirror:ident => $domain:path, [$($variant:ident),+ $(,)?]) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
        pub enum $mirror {
            $($variant,)+
        }

        impl From<$domain> for $mirror {
            fn from(value: $domain) -> Self {
                match value { $(<$domain>::$variant => Self::$variant,)+ }
            }
        }

        impl From<$mirror> for $domain {
            fn from(value: $mirror) -> Self {
                match value { $(<$mirror>::$variant => Self::$variant,)+ }
            }
        }
    };
}

mirror_enum!(
    /// `DomainAgentRunLifecycleStage`.
    AgentRunLifecycleStageV1 => lifecycle::LifecycleStage,
    [Starting, PreparingRuntime, Running, WaitingForInteraction, Retrying, Cancelling]
);
mirror_enum!(
    /// `DomainAgentRunLivenessSignalKind`.
    AgentRunLivenessSignalKindV1 => lifecycle::LivenessSignalKind,
    [StageTransition, ProviderEvent, ToolActivity, Interaction, Heartbeat]
);
mirror_enum!(
    /// `DomainAgentRunRetryIntent`.
    AgentRunRetryIntentV1 => lifecycle::RetryIntent,
    [None, ProviderManaged, ApplicationManaged]
);
mirror_enum!(
    /// `DomainAgentRunEpochTransitionKind`.
    AgentRunEpochTransitionKindV1 => lifecycle::EpochTransitionKind,
    [Initial, RelatedFollowUp, Steering, Unrelated]
);
mirror_enum!(
    /// `DomainAgentRunProgressRejection`.
    AgentRunProgressRejectionV1 => lifecycle::ProgressRejection,
    [NoActiveOwnership, StaleOwnership, DuplicateSequence, OutOfOrderSequence, NonMonotonicTimestamp]
);
mirror_enum!(
    /// `DomainAgentRunSnapshot.FailureReason`.
    AgentRunFailureReasonV1 => lifecycle::FailureReason,
    [ProcessCrash, Timeout, AgentError, Cancelled]
);
mirror_enum!(
    /// `DomainAgentRunTerminalOutcome.Kind`.
    AgentRunTerminalOutcomeKindV1 => lifecycle::TerminalOutcomeKind,
    [Completed, Cancelled, Failed]
);
mirror_enum!(
    /// `DomainAgentRunTerminalCommitBeginResult`.
    AgentRunTerminalCommitBeginResultV1 => lifecycle::TerminalCommitBeginResult,
    [Acquired, AlreadyInProgress, StaleOwnership]
);
mirror_enum!(
    /// `DomainAgentRunTerminalTeardownRegistrationResult`.
    AgentRunTeardownRegistrationResultV1 => lifecycle::TeardownRegistrationResult,
    [Registered, AlreadyRegistered]
);

// ---- identity records ---------------------------------------------------------------------

/// `DomainAgentRunTurnEpoch` (full domain fence, not the lossy wire `TurnEpoch`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunTurnEpochV1 {
    pub runtime_id: String,
    pub runtime_generation: u64,
    pub session_id: String,
    pub activation_id: String,
    pub registration_generation: u64,
    pub id: String,
    pub ordinal: u64,
    pub continuity_generation: u64,
    pub transition_kind: AgentRunEpochTransitionKindV1,
}

impl TryFrom<AgentRunTurnEpochV1> for lifecycle::TurnEpoch {
    type Error = CoreError;

    fn try_from(value: AgentRunTurnEpochV1) -> Result<Self, CoreError> {
        Ok(Self {
            runtime_id: parse_uuid("turnEpoch.runtimeId", &value.runtime_id)?,
            runtime_generation: value.runtime_generation,
            session_id: parse_uuid("turnEpoch.sessionId", &value.session_id)?,
            activation_id: parse_uuid("turnEpoch.activationId", &value.activation_id)?,
            registration_generation: value.registration_generation,
            id: parse_uuid("turnEpoch.id", &value.id)?,
            ordinal: value.ordinal,
            continuity_generation: value.continuity_generation,
            transition_kind: value.transition_kind.into(),
        })
    }
}

impl From<lifecycle::TurnEpoch> for AgentRunTurnEpochV1 {
    fn from(value: lifecycle::TurnEpoch) -> Self {
        Self {
            runtime_id: render_uuid(value.runtime_id),
            runtime_generation: value.runtime_generation,
            session_id: render_uuid(value.session_id),
            activation_id: render_uuid(value.activation_id),
            registration_generation: value.registration_generation,
            id: render_uuid(value.id),
            ordinal: value.ordinal,
            continuity_generation: value.continuity_generation,
            transition_kind: value.transition_kind.into(),
        }
    }
}

fn optional_epoch(
    value: Option<AgentRunTurnEpochV1>,
) -> Result<Option<lifecycle::TurnEpoch>, CoreError> {
    value.map(TryInto::try_into).transpose()
}

/// `DomainAgentRunBindingIdentity`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunBindingIdentityV1 {
    pub tab_id: String,
    pub persistent_session_id: Option<String>,
    pub persistent_binding_generation: Option<String>,
    pub binding_transition_generation: u64,
    pub generation: String,
}

impl TryFrom<AgentRunBindingIdentityV1> for lifecycle::BindingIdentity {
    type Error = CoreError;

    fn try_from(value: AgentRunBindingIdentityV1) -> Result<Self, CoreError> {
        Ok(Self {
            tab_id: parse_uuid("binding.tabId", &value.tab_id)?,
            persistent_session_id: parse_optional_uuid(
                "binding.persistentSessionId",
                value.persistent_session_id.as_deref(),
            )?,
            persistent_binding_generation: parse_optional_uuid(
                "binding.persistentBindingGeneration",
                value.persistent_binding_generation.as_deref(),
            )?,
            binding_transition_generation: value.binding_transition_generation,
            generation: parse_uuid("binding.generation", &value.generation)?,
        })
    }
}

impl From<lifecycle::BindingIdentity> for AgentRunBindingIdentityV1 {
    fn from(value: lifecycle::BindingIdentity) -> Self {
        Self {
            tab_id: render_uuid(value.tab_id),
            persistent_session_id: render_optional_uuid(value.persistent_session_id),
            persistent_binding_generation: render_optional_uuid(
                value.persistent_binding_generation,
            ),
            binding_transition_generation: value.binding_transition_generation,
            generation: render_uuid(value.generation),
        }
    }
}

/// `DomainAgentRunOwnership`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunOwnershipV1 {
    pub attempt_id: String,
    pub binding: AgentRunBindingIdentityV1,
    pub turn_epoch: Option<AgentRunTurnEpochV1>,
}

impl TryFrom<AgentRunOwnershipV1> for lifecycle::Ownership {
    type Error = CoreError;

    fn try_from(value: AgentRunOwnershipV1) -> Result<Self, CoreError> {
        Ok(Self {
            attempt_id: parse_uuid("ownership.attemptId", &value.attempt_id)?,
            binding: value.binding.try_into()?,
            turn_epoch: optional_epoch(value.turn_epoch)?,
        })
    }
}

impl From<lifecycle::Ownership> for AgentRunOwnershipV1 {
    fn from(value: lifecycle::Ownership) -> Self {
        Self {
            attempt_id: render_uuid(value.attempt_id),
            binding: value.binding.into(),
            turn_epoch: value.turn_epoch.map(Into::into),
        }
    }
}

pub(crate) fn optional_ownership(
    value: Option<AgentRunOwnershipV1>,
) -> Result<Option<lifecycle::Ownership>, CoreError> {
    value.map(TryInto::try_into).transpose()
}

/// Inputs to `AgentRunLifecycleTrackerV1.begin`. Mirrors the Swift `begin(...)` parameter list,
/// with the two identities Swift would mint (`attempt_id`, `binding_generation`) made explicit.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunBeginAttemptV1 {
    pub tab_id: String,
    pub persistent_session_id: Option<String>,
    pub persistent_binding_generation: Option<String>,
    pub binding_transition_generation: u64,
    pub binding_generation: String,
    pub attempt_id: String,
    pub turn_epoch: Option<AgentRunTurnEpochV1>,
    pub timestamp_uptime_nanoseconds: u64,
}

impl TryFrom<AgentRunBeginAttemptV1> for lifecycle::BeginAttempt {
    type Error = CoreError;

    fn try_from(value: AgentRunBeginAttemptV1) -> Result<Self, CoreError> {
        Ok(Self {
            tab_id: parse_uuid("begin.tabId", &value.tab_id)?,
            persistent_session_id: parse_optional_uuid(
                "begin.persistentSessionId",
                value.persistent_session_id.as_deref(),
            )?,
            persistent_binding_generation: parse_optional_uuid(
                "begin.persistentBindingGeneration",
                value.persistent_binding_generation.as_deref(),
            )?,
            binding_transition_generation: value.binding_transition_generation,
            binding_generation: parse_uuid("begin.bindingGeneration", &value.binding_generation)?,
            attempt_id: parse_uuid("begin.attemptId", &value.attempt_id)?,
            turn_epoch: optional_epoch(value.turn_epoch)?,
            timestamp_uptime_nanoseconds: value.timestamp_uptime_nanoseconds,
        })
    }
}

// ---- liveness records ---------------------------------------------------------------------

/// `DomainAgentRunProgressSignal`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunProgressSignalV1 {
    pub ownership: AgentRunOwnershipV1,
    pub sequence: u64,
    pub timestamp_uptime_nanoseconds: u64,
    pub kind: AgentRunLivenessSignalKindV1,
    pub stage: AgentRunLifecycleStageV1,
    pub retry_intent: AgentRunRetryIntentV1,
}

impl TryFrom<AgentRunProgressSignalV1> for lifecycle::ProgressSignal {
    type Error = CoreError;

    fn try_from(value: AgentRunProgressSignalV1) -> Result<Self, CoreError> {
        Ok(Self {
            ownership: value.ownership.try_into()?,
            sequence: value.sequence,
            timestamp_uptime_nanoseconds: value.timestamp_uptime_nanoseconds,
            kind: value.kind.into(),
            stage: value.stage.into(),
            retry_intent: value.retry_intent.into(),
        })
    }
}

/// `DomainAgentRunLivenessSnapshot`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunLivenessSnapshotV1 {
    pub ownership: AgentRunOwnershipV1,
    pub stage: AgentRunLifecycleStageV1,
    pub retry_intent: AgentRunRetryIntentV1,
    pub last_accepted_sequence: u64,
    pub last_signal_uptime_nanoseconds: u64,
    pub last_real_progress_uptime_nanoseconds: u64,
    pub last_heartbeat_uptime_nanoseconds: Option<u64>,
}

impl From<lifecycle::LivenessSnapshot> for AgentRunLivenessSnapshotV1 {
    fn from(value: lifecycle::LivenessSnapshot) -> Self {
        Self {
            ownership: value.ownership.into(),
            stage: value.stage.into(),
            retry_intent: value.retry_intent.into(),
            last_accepted_sequence: value.last_accepted_sequence,
            last_signal_uptime_nanoseconds: value.last_signal_uptime_nanoseconds,
            last_real_progress_uptime_nanoseconds: value.last_real_progress_uptime_nanoseconds,
            last_heartbeat_uptime_nanoseconds: value.last_heartbeat_uptime_nanoseconds,
        }
    }
}

/// `DomainAgentRunProgressAcceptance`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRunProgressAcceptanceV1 {
    Accepted {
        snapshot: AgentRunLivenessSnapshotV1,
    },
    Rejected {
        rejection: AgentRunProgressRejectionV1,
    },
}

impl From<lifecycle::ProgressAcceptance> for AgentRunProgressAcceptanceV1 {
    fn from(value: lifecycle::ProgressAcceptance) -> Self {
        match value {
            lifecycle::ProgressAcceptance::Accepted(snapshot) => Self::Accepted {
                snapshot: snapshot.into(),
            },
            lifecycle::ProgressAcceptance::Rejected(rejection) => Self::Rejected {
                rejection: rejection.into(),
            },
        }
    }
}

// ---- terminal commit records --------------------------------------------------------------

/// `DomainAgentRunTerminalPublicationResult`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRunTerminalPublicationResultV1 {
    Accepted {
        successor_epoch: Option<AgentRunTurnEpochV1>,
    },
    Stale,
    Rejected {
        reason: String,
    },
}

impl TryFrom<AgentRunTerminalPublicationResultV1> for lifecycle::TerminalPublicationResult {
    type Error = CoreError;

    fn try_from(value: AgentRunTerminalPublicationResultV1) -> Result<Self, CoreError> {
        Ok(match value {
            AgentRunTerminalPublicationResultV1::Accepted { successor_epoch } => Self::Accepted {
                successor_epoch: optional_epoch(successor_epoch)?,
            },
            AgentRunTerminalPublicationResultV1::Stale => Self::Stale,
            AgentRunTerminalPublicationResultV1::Rejected { reason } => Self::Rejected { reason },
        })
    }
}

impl From<lifecycle::TerminalPublicationResult> for AgentRunTerminalPublicationResultV1 {
    fn from(value: lifecycle::TerminalPublicationResult) -> Self {
        match value {
            lifecycle::TerminalPublicationResult::Accepted { successor_epoch } => Self::Accepted {
                successor_epoch: successor_epoch.map(Into::into),
            },
            lifecycle::TerminalPublicationResult::Stale => Self::Stale,
            lifecycle::TerminalPublicationResult::Rejected { reason } => Self::Rejected { reason },
        }
    }
}

/// `DomainAgentRunTerminalCommitReceipt`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunTerminalCommitReceiptV1 {
    pub commit_id: String,
    pub ownership: AgentRunOwnershipV1,
}

impl From<lifecycle::TerminalCommitReceipt> for AgentRunTerminalCommitReceiptV1 {
    fn from(value: lifecycle::TerminalCommitReceipt) -> Self {
        Self {
            commit_id: render_uuid(value.commit_id),
            ownership: value.ownership.into(),
        }
    }
}

// ---- observable state records -------------------------------------------------------------

/// Observable `DomainAgentRunLifecycleTracker` state (every `package`-visible property).
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunLifecycleTrackerSnapshotV1 {
    pub active_ownership: Option<AgentRunOwnershipV1>,
    pub liveness: Option<AgentRunLivenessSnapshotV1>,
    pub process_run_id: Option<String>,
    pub terminal_drain_generation: u64,
    pub terminal_commit_in_progress: bool,
    pub terminal_commit_receipt: Option<AgentRunTerminalCommitReceiptV1>,
    pub terminal_commit_publication_result: Option<AgentRunTerminalPublicationResultV1>,
}

impl From<&lifecycle::LifecycleTracker> for AgentRunLifecycleTrackerSnapshotV1 {
    fn from(tracker: &lifecycle::LifecycleTracker) -> Self {
        Self {
            active_ownership: tracker.active_ownership().copied().map(Into::into),
            liveness: tracker.liveness().copied().map(Into::into),
            process_run_id: render_optional_uuid(tracker.process_run_id()),
            terminal_drain_generation: tracker.terminal_drain_generation(),
            terminal_commit_in_progress: tracker.terminal_commit_in_progress(),
            terminal_commit_receipt: tracker.terminal_commit_receipt().copied().map(Into::into),
            terminal_commit_publication_result: tracker
                .terminal_commit_publication_result()
                .cloned()
                .map(Into::into),
        }
    }
}

/// Observable `DomainAgentRunProcessIdentityState`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunProcessIdentitySnapshotV1 {
    pub run_id: Option<String>,
    pub terminal_drain_generation: u64,
}

impl From<&lifecycle::ProcessIdentityState> for AgentRunProcessIdentitySnapshotV1 {
    fn from(state: &lifecycle::ProcessIdentityState) -> Self {
        Self {
            run_id: render_optional_uuid(state.run_id()),
            terminal_drain_generation: state.terminal_drain_generation(),
        }
    }
}

/// Observable `DomainAgentRunTerminalCommitState`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunTerminalCommitSnapshotV1 {
    pub is_in_progress: bool,
    pub staged_receipt: Option<AgentRunTerminalCommitReceiptV1>,
    pub publication_result: Option<AgentRunTerminalPublicationResultV1>,
}

impl From<&lifecycle::TerminalCommitState> for AgentRunTerminalCommitSnapshotV1 {
    fn from(state: &lifecycle::TerminalCommitState) -> Self {
        Self {
            is_in_progress: state.is_in_progress(),
            staged_receipt: state.staged_receipt().copied().map(Into::into),
            publication_result: state.publication_result().cloned().map(Into::into),
        }
    }
}

/// Observable `DomainAgentRunTerminalSettlementCoordinator` state.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunTerminalSettlementSnapshotV1 {
    pub consumed_provider_successor_count: u64,
    /// `maxProviderSuccessorTombstones` (512), exported so clients need not hard-code it.
    pub max_provider_successor_tombstones: u64,
}

impl From<&lifecycle::TerminalSettlementCoordinator> for AgentRunTerminalSettlementSnapshotV1 {
    fn from(coordinator: &lifecycle::TerminalSettlementCoordinator) -> Self {
        Self {
            consumed_provider_successor_count: u64::try_from(
                coordinator.consumed_provider_successor_count(),
            )
            .unwrap_or(u64::MAX),
            max_provider_successor_tombstones: u64::try_from(
                lifecycle::MAX_PROVIDER_SUCCESSOR_TOMBSTONES,
            )
            .unwrap_or(u64::MAX),
        }
    }
}

// ---- semantic authority records -----------------------------------------------------------

/// `DomainAgentRunTerminalOutcome`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunTerminalOutcomeV1 {
    pub kind: AgentRunTerminalOutcomeKindV1,
    pub assistant_text: Option<String>,
    pub failure_reason: Option<AgentRunFailureReasonV1>,
}

impl From<lifecycle::TerminalOutcome> for AgentRunTerminalOutcomeV1 {
    fn from(value: lifecycle::TerminalOutcome) -> Self {
        Self {
            kind: value.kind.into(),
            assistant_text: value.assistant_text,
            failure_reason: value.failure_reason.map(Into::into),
        }
    }
}

impl From<AgentRunTerminalOutcomeV1> for lifecycle::TerminalOutcome {
    fn from(value: AgentRunTerminalOutcomeV1) -> Self {
        Self {
            kind: value.kind.into(),
            assistant_text: value.assistant_text,
            failure_reason: value.failure_reason.map(Into::into),
        }
    }
}

/// `DomainAgentRunProviderTerminationSignal`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRunTerminationSignalV1 {
    Completed {
        assistant_text: Option<String>,
    },
    Cancelled {
        assistant_text: Option<String>,
    },
    Superseded,
    StartupFailure {
        assistant_text: Option<String>,
    },
    ProviderFailure {
        assistant_text: Option<String>,
        reason: Option<AgentRunFailureReasonV1>,
    },
    Timeout {
        assistant_text: Option<String>,
    },
    ProcessExited {
        assistant_text: Option<String>,
    },
    TransportClosed {
        assistant_text: Option<String>,
    },
    UnexpectedEnd {
        assistant_text: Option<String>,
    },
}

impl From<AgentRunTerminationSignalV1> for lifecycle::TerminationSignal {
    fn from(value: AgentRunTerminationSignalV1) -> Self {
        match value {
            AgentRunTerminationSignalV1::Completed { assistant_text } => {
                Self::Completed { assistant_text }
            }
            AgentRunTerminationSignalV1::Cancelled { assistant_text } => {
                Self::Cancelled { assistant_text }
            }
            AgentRunTerminationSignalV1::Superseded => Self::Superseded,
            AgentRunTerminationSignalV1::StartupFailure { assistant_text } => {
                Self::StartupFailure { assistant_text }
            }
            AgentRunTerminationSignalV1::ProviderFailure {
                assistant_text,
                reason,
            } => Self::ProviderFailure {
                assistant_text,
                reason: reason.map(Into::into),
            },
            AgentRunTerminationSignalV1::Timeout { assistant_text } => {
                Self::Timeout { assistant_text }
            }
            AgentRunTerminationSignalV1::ProcessExited { assistant_text } => {
                Self::ProcessExited { assistant_text }
            }
            AgentRunTerminationSignalV1::TransportClosed { assistant_text } => {
                Self::TransportClosed { assistant_text }
            }
            AgentRunTerminationSignalV1::UnexpectedEnd { assistant_text } => {
                Self::UnexpectedEnd { assistant_text }
            }
        }
    }
}

/// `DomainAgentRunProviderSemanticResolution`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRunSemanticResolutionV1 {
    Terminal { outcome: AgentRunTerminalOutcomeV1 },
    Superseded,
}

impl From<lifecycle::SemanticResolution> for AgentRunSemanticResolutionV1 {
    fn from(value: lifecycle::SemanticResolution) -> Self {
        match value {
            lifecycle::SemanticResolution::Terminal(outcome) => Self::Terminal {
                outcome: outcome.into(),
            },
            lifecycle::SemanticResolution::Superseded => Self::Superseded,
        }
    }
}

/// `DomainAgentRunExecutionOperationResult`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRunExecutionOperationResultV1 {
    Completed { assistant_text: Option<String> },
    Terminal { outcome: AgentRunTerminalOutcomeV1 },
    Superseded,
}

impl From<AgentRunExecutionOperationResultV1> for lifecycle::ExecutionOperationResult {
    fn from(value: AgentRunExecutionOperationResultV1) -> Self {
        match value {
            AgentRunExecutionOperationResultV1::Completed { assistant_text } => {
                Self::Completed { assistant_text }
            }
            AgentRunExecutionOperationResultV1::Terminal { outcome } => {
                Self::Terminal(outcome.into())
            }
            AgentRunExecutionOperationResultV1::Superseded => Self::Superseded,
        }
    }
}

/// `DomainAgentRunProviderExecutionResult`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRunProviderExecutionResultV1 {
    Completed { assistant_text: Option<String> },
    Cancelled { assistant_text: Option<String> },
    Failed { signal: AgentRunTerminationSignalV1 },
    Superseded,
}

impl From<AgentRunProviderExecutionResultV1> for lifecycle::ProviderExecutionResult {
    fn from(value: AgentRunProviderExecutionResultV1) -> Self {
        match value {
            AgentRunProviderExecutionResultV1::Completed { assistant_text } => {
                Self::Completed { assistant_text }
            }
            AgentRunProviderExecutionResultV1::Cancelled { assistant_text } => {
                Self::Cancelled { assistant_text }
            }
            AgentRunProviderExecutionResultV1::Failed { signal } => Self::Failed {
                signal: signal.into(),
            },
            AgentRunProviderExecutionResultV1::Superseded => Self::Superseded,
        }
    }
}

/// How the Swift `DomainAgentRunExecutionCore.execute` operation closure ended.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRunExecutionOperationEndingV1 {
    Returned {
        result: AgentRunExecutionOperationResultV1,
    },
    ThrewCancellation,
    ThrewError {
        failure_text: String,
    },
}

impl From<AgentRunExecutionOperationEndingV1>
    for lifecycle::OperationEnding<lifecycle::ExecutionOperationResult>
{
    fn from(value: AgentRunExecutionOperationEndingV1) -> Self {
        match value {
            AgentRunExecutionOperationEndingV1::Returned { result } => {
                Self::Returned(result.into())
            }
            AgentRunExecutionOperationEndingV1::ThrewCancellation => Self::ThrewCancellation,
            AgentRunExecutionOperationEndingV1::ThrewError { failure_text } => {
                Self::ThrewError { failure_text }
            }
        }
    }
}

/// How the Swift `DomainAgentRunExecutionCore.executeProvider` operation closure ended.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRunProviderOperationEndingV1 {
    Returned {
        result: AgentRunProviderExecutionResultV1,
    },
    ThrewCancellation,
    ThrewError {
        failure_text: String,
    },
}

impl From<AgentRunProviderOperationEndingV1>
    for lifecycle::OperationEnding<lifecycle::ProviderExecutionResult>
{
    fn from(value: AgentRunProviderOperationEndingV1) -> Self {
        match value {
            AgentRunProviderOperationEndingV1::Returned { result } => Self::Returned(result.into()),
            AgentRunProviderOperationEndingV1::ThrewCancellation => Self::ThrewCancellation,
            AgentRunProviderOperationEndingV1::ThrewError { failure_text } => {
                Self::ThrewError { failure_text }
            }
        }
    }
}

/// `DomainAgentRunExecutionResult`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRunExecutionResultV1 {
    Terminal { outcome: AgentRunTerminalOutcomeV1 },
    Superseded,
}

/// `DomainAgentRunExecutionTraceEvent`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentRunExecutionTraceEventV1 {
    ExecutionStarted,
    TerminalOutcomeProduced { kind: AgentRunTerminalOutcomeKindV1 },
    ExecutionSuperseded,
}

/// `DomainAgentRunExecutionReport`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AgentRunExecutionReportV1 {
    pub result: AgentRunExecutionResultV1,
    pub trace: Vec<AgentRunExecutionTraceEventV1>,
}

impl From<lifecycle::ExecutionReport> for AgentRunExecutionReportV1 {
    fn from(value: lifecycle::ExecutionReport) -> Self {
        Self {
            result: match value.result {
                lifecycle::ExecutionResult::Terminal(outcome) => {
                    AgentRunExecutionResultV1::Terminal {
                        outcome: outcome.into(),
                    }
                }
                lifecycle::ExecutionResult::Superseded => AgentRunExecutionResultV1::Superseded,
            },
            trace: value
                .trace
                .into_iter()
                .map(|event| match event {
                    lifecycle::ExecutionTraceEvent::ExecutionStarted => {
                        AgentRunExecutionTraceEventV1::ExecutionStarted
                    }
                    lifecycle::ExecutionTraceEvent::TerminalOutcomeProduced(kind) => {
                        AgentRunExecutionTraceEventV1::TerminalOutcomeProduced { kind: kind.into() }
                    }
                    lifecycle::ExecutionTraceEvent::ExecutionSuperseded => {
                        AgentRunExecutionTraceEventV1::ExecutionSuperseded
                    }
                })
                .collect(),
        }
    }
}
