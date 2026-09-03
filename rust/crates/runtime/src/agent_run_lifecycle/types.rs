//! Provider-neutral value vocabulary shared by the reducers. Field-for-field mirrors of
//! `DomainAgentRunLifecycleContracts.swift`, `DomainAgentRunExecutionContracts.swift`,
//! `DomainAgentRunProviderSemanticContracts.swift`, and `DomainAgentSessionModels.swift`
//! (`DomainAgentRunTurnEpoch`, `DomainAgentRunTerminalPublicationResult`, `FailureReason`).
//!
//! None of these enums carries an `Unspecified` member: that value exists only on the wire
//! (`agent_host_v1.proto`) and is rejected at the conversion boundary (`proto` module), so a
//! reducer can never hold a state the Swift original cannot.

use super::uuid::RunUuid;

/// `DomainAgentRunLifecycleStage`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum LifecycleStage {
    Starting,
    PreparingRuntime,
    Running,
    WaitingForInteraction,
    Retrying,
    Cancelling,
}

impl LifecycleStage {
    pub const ALL: [Self; 6] = [
        Self::Starting,
        Self::PreparingRuntime,
        Self::Running,
        Self::WaitingForInteraction,
        Self::Retrying,
        Self::Cancelling,
    ];

    /// Swift `rawValue`.
    #[must_use]
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Starting => "starting",
            Self::PreparingRuntime => "preparingRuntime",
            Self::Running => "running",
            Self::WaitingForInteraction => "waitingForInteraction",
            Self::Retrying => "retrying",
            Self::Cancelling => "cancelling",
        }
    }
}

/// `DomainAgentRunLivenessSignalKind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum LivenessSignalKind {
    StageTransition,
    ProviderEvent,
    ToolActivity,
    Interaction,
    Heartbeat,
}

impl LivenessSignalKind {
    pub const ALL: [Self; 5] = [
        Self::StageTransition,
        Self::ProviderEvent,
        Self::ToolActivity,
        Self::Interaction,
        Self::Heartbeat,
    ];

    /// Heartbeats advance signal time but never manufacture real progress (P14).
    #[must_use]
    pub const fn is_real_progress(self) -> bool {
        !matches!(self, Self::Heartbeat)
    }

    #[must_use]
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::StageTransition => "stageTransition",
            Self::ProviderEvent => "providerEvent",
            Self::ToolActivity => "toolActivity",
            Self::Interaction => "interaction",
            Self::Heartbeat => "heartbeat",
        }
    }
}

/// `DomainAgentRunRetryIntent`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum RetryIntent {
    None,
    ProviderManaged,
    ApplicationManaged,
}

impl RetryIntent {
    pub const ALL: [Self; 3] = [Self::None, Self::ProviderManaged, Self::ApplicationManaged];

    #[must_use]
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::ProviderManaged => "providerManaged",
            Self::ApplicationManaged => "applicationManaged",
        }
    }
}

/// `DomainAgentRunEpochTransitionKind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum EpochTransitionKind {
    Initial,
    RelatedFollowUp,
    Steering,
    Unrelated,
}

impl EpochTransitionKind {
    pub const ALL: [Self; 4] = [
        Self::Initial,
        Self::RelatedFollowUp,
        Self::Steering,
        Self::Unrelated,
    ];

    #[must_use]
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Initial => "initial",
            Self::RelatedFollowUp => "relatedFollowUp",
            Self::Steering => "steering",
            Self::Unrelated => "unrelated",
        }
    }
}

/// `DomainAgentRunTurnEpoch`: the full canonical epoch identity. Ownership equality compares every
/// field, exactly as the Swift `Equatable` synthesis does. The wire `TurnEpoch` is a lossy
/// projection of this value (see `proto::ProtoTurnEpoch`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TurnEpoch {
    pub runtime_id: RunUuid,
    pub runtime_generation: u64,
    pub session_id: RunUuid,
    pub activation_id: RunUuid,
    pub registration_generation: u64,
    pub id: RunUuid,
    pub ordinal: u64,
    pub continuity_generation: u64,
    pub transition_kind: EpochTransitionKind,
}

/// `DomainAgentRunBindingIdentity`: runtime-only binding captured when an attempt begins.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BindingIdentity {
    pub tab_id: RunUuid,
    pub persistent_session_id: Option<RunUuid>,
    pub persistent_binding_generation: Option<RunUuid>,
    pub binding_transition_generation: u64,
    /// Swift mints this with `UUID()` by default; here it is always an input.
    pub generation: RunUuid,
}

/// `DomainAgentRunOwnership`: the ownership token for one logical run attempt.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Ownership {
    pub attempt_id: RunUuid,
    pub binding: BindingIdentity,
    pub turn_epoch: Option<TurnEpoch>,
}

/// `DomainAgentRunProgressSignal`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ProgressSignal {
    pub ownership: Ownership,
    pub sequence: u64,
    pub timestamp_uptime_nanoseconds: u64,
    pub kind: LivenessSignalKind,
    pub stage: LifecycleStage,
    pub retry_intent: RetryIntent,
}

/// `DomainAgentRunLivenessSnapshot`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct LivenessSnapshot {
    pub ownership: Ownership,
    pub stage: LifecycleStage,
    pub retry_intent: RetryIntent,
    pub last_accepted_sequence: u64,
    pub last_signal_uptime_nanoseconds: u64,
    pub last_real_progress_uptime_nanoseconds: u64,
    pub last_heartbeat_uptime_nanoseconds: Option<u64>,
}

/// `DomainAgentRunProgressRejection`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProgressRejection {
    NoActiveOwnership,
    StaleOwnership,
    DuplicateSequence,
    OutOfOrderSequence,
    NonMonotonicTimestamp,
}

impl ProgressRejection {
    #[must_use]
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::NoActiveOwnership => "noActiveOwnership",
            Self::StaleOwnership => "staleOwnership",
            Self::DuplicateSequence => "duplicateSequence",
            Self::OutOfOrderSequence => "outOfOrderSequence",
            Self::NonMonotonicTimestamp => "nonMonotonicTimestamp",
        }
    }
}

/// `DomainAgentRunProgressAcceptance`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProgressAcceptance {
    Accepted(LivenessSnapshot),
    Rejected(ProgressRejection),
}

/// `DomainAgentRunTerminalPublicationResult`. Recorded by the terminal-commit reducer; produced
/// by the session authority, which remains in Swift for P6-a.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum TerminalPublicationResult {
    Accepted { successor_epoch: Option<TurnEpoch> },
    Stale,
    Rejected { reason: String },
}

impl TerminalPublicationResult {
    #[must_use]
    pub fn successor_epoch(&self) -> Option<TurnEpoch> {
        match self {
            Self::Accepted { successor_epoch } => *successor_epoch,
            Self::Stale | Self::Rejected { .. } => None,
        }
    }

    #[must_use]
    pub const fn is_resolved(&self) -> bool {
        matches!(self, Self::Accepted { .. } | Self::Stale)
    }
}

/// `DomainAgentRunSnapshot.FailureReason`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum FailureReason {
    ProcessCrash,
    Timeout,
    AgentError,
    Cancelled,
}

impl FailureReason {
    pub const ALL: [Self; 4] = [
        Self::ProcessCrash,
        Self::Timeout,
        Self::AgentError,
        Self::Cancelled,
    ];

    #[must_use]
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::ProcessCrash => "process_crash",
            Self::Timeout => "timeout",
            Self::AgentError => "agent_error",
            Self::Cancelled => "cancelled",
        }
    }
}

/// `DomainAgentRunTerminalOutcome.Kind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum TerminalOutcomeKind {
    Completed,
    Cancelled,
    Failed,
}

impl TerminalOutcomeKind {
    #[must_use]
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
            Self::Failed => "failed",
        }
    }
}

/// `DomainAgentRunTerminalOutcome`. The Swift initializer is private and only the four named
/// constructors exist; the same four are the only producers here.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct TerminalOutcome {
    pub kind: TerminalOutcomeKind,
    pub assistant_text: Option<String>,
    pub failure_reason: Option<FailureReason>,
}

impl TerminalOutcome {
    #[must_use]
    pub const fn completed(assistant_text: Option<String>) -> Self {
        Self {
            kind: TerminalOutcomeKind::Completed,
            assistant_text,
            failure_reason: None,
        }
    }

    #[must_use]
    pub const fn cancelled(assistant_text: Option<String>) -> Self {
        Self {
            kind: TerminalOutcomeKind::Cancelled,
            assistant_text,
            failure_reason: Some(FailureReason::Cancelled),
        }
    }

    #[must_use]
    pub const fn failed(assistant_text: Option<String>, reason: FailureReason) -> Self {
        Self {
            kind: TerminalOutcomeKind::Failed,
            assistant_text,
            failure_reason: Some(reason),
        }
    }

    /// Failure whose classification is deferred to the settled-transcript classifier at the
    /// publication boundary (P17).
    #[must_use]
    pub const fn failed_without_classification(assistant_text: Option<String>) -> Self {
        Self {
            kind: TerminalOutcomeKind::Failed,
            assistant_text,
            failure_reason: None,
        }
    }
}

/// `DomainAgentRunProviderTerminationSignal`: typed termination facts from a provider adapter.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum TerminationSignal {
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
        reason: Option<FailureReason>,
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
