//! Typed UniFFI mirrors of the frozen agent-host-v1 schema
//! (`rust/crates/proto/schema/agent_host_v1.proto`, design §5, §7.2) plus lossless conversions to and
//! from the prost types in `agentry_proto::agent_host::v1`.
//!
//! Hand-owned, frozen with the schema at end of P2 (ADR-0011). Every `From`/`TryFrom` destructures
//! the prost struct without `..`, so a schema field added without a mirror field fails to compile
//! instead of silently dropping data at the boundary. Proto → mirror is fallible only because an
//! enum value this build does not know is refused (ADR-0006 fail-closed) rather than aliased to
//! `Unspecified`. Field names, enum members, and doc comments follow the schema one-for-one; the
//! `AgentHost…V1` prefix keeps the Swift namespace clear of the unprefixed schema names.

use crate::errors::CoreError;
use agentry_proto::agent_host::v1;

fn unknown_enum(enum_name: &str, value: i32) -> CoreError {
    CoreError::AgentHostFrameMalformed {
        message: format!("unknown {enum_name} value {value}"),
    }
}

fn enum_from_i32<P, M>(enum_name: &str, value: i32) -> Result<M, CoreError>
where
    P: TryFrom<i32> + Into<M>,
{
    P::try_from(value)
        .map(Into::into)
        .map_err(|_| unknown_enum(enum_name, value))
}

fn enums_from_i32<P, M>(enum_name: &str, values: Vec<i32>) -> Result<Vec<M>, CoreError>
where
    P: TryFrom<i32> + Into<M>,
{
    values
        .into_iter()
        .map(|value| enum_from_i32::<P, M>(enum_name, value))
        .collect()
}

fn messages_from<P, M>(values: Vec<P>) -> Result<Vec<M>, CoreError>
where
    M: TryFrom<P, Error = CoreError>,
{
    values.into_iter().map(M::try_from).collect()
}

// ---- enumerations -------------------------------------------------------------------------

/// Capabilities are advertised by both sides in the handshake. Clients list what they can do
/// (notably `CAPABILITY_CAN_PRESENT`); hosts list which optional commands they support.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostCapabilityV1 {
    Unspecified,
    /// Client: can present interactions (approvals, questions, elicitations) to a human. A host only
    /// routes `InteractionRequested` prompts to clients that advertise this; when no attached client
    /// can present, `PermissionPolicy.approval_policy` decides the fallback.
    CanPresent,
    /// Client: accepts `SnapshotBegin`/`SnapshotChunk`/`SnapshotEnd` streams. Required by v1 clients.
    SnapshotStreaming,
    /// Host: supports `HostControl { prepare_update }`.
    PrepareUpdate,
    /// Host: supports `SessionSpec.parent_session_id` forks (`ForkedFrom` records).
    Fork,
    /// Host: supports importing legacy Swift-owned sessions (`Imported` records).
    Import,
}

impl From<v1::Capability> for AgentHostCapabilityV1 {
    fn from(value: v1::Capability) -> Self {
        match value {
            v1::Capability::Unspecified => Self::Unspecified,
            v1::Capability::CanPresent => Self::CanPresent,
            v1::Capability::SnapshotStreaming => Self::SnapshotStreaming,
            v1::Capability::PrepareUpdate => Self::PrepareUpdate,
            v1::Capability::Fork => Self::Fork,
            v1::Capability::Import => Self::Import,
        }
    }
}

impl From<AgentHostCapabilityV1> for v1::Capability {
    fn from(value: AgentHostCapabilityV1) -> Self {
        match value {
            AgentHostCapabilityV1::Unspecified => Self::Unspecified,
            AgentHostCapabilityV1::CanPresent => Self::CanPresent,
            AgentHostCapabilityV1::SnapshotStreaming => Self::SnapshotStreaming,
            AgentHostCapabilityV1::PrepareUpdate => Self::PrepareUpdate,
            AgentHostCapabilityV1::Fork => Self::Fork,
            AgentHostCapabilityV1::Import => Self::Import,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostClientKindV1 {
    Unspecified,
    Gui,
    Cli,
    Mcp,
    Test,
}

impl From<v1::ClientKind> for AgentHostClientKindV1 {
    fn from(value: v1::ClientKind) -> Self {
        match value {
            v1::ClientKind::Unspecified => Self::Unspecified,
            v1::ClientKind::Gui => Self::Gui,
            v1::ClientKind::Cli => Self::Cli,
            v1::ClientKind::Mcp => Self::Mcp,
            v1::ClientKind::Test => Self::Test,
        }
    }
}

impl From<AgentHostClientKindV1> for v1::ClientKind {
    fn from(value: AgentHostClientKindV1) -> Self {
        match value {
            AgentHostClientKindV1::Unspecified => Self::Unspecified,
            AgentHostClientKindV1::Gui => Self::Gui,
            AgentHostClientKindV1::Cli => Self::Cli,
            AgentHostClientKindV1::Mcp => Self::Mcp,
            AgentHostClientKindV1::Test => Self::Test,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostHandshakeRejectReasonV1 {
    Unspecified,
    ProtocolVersionMismatch,
    BuildFingerprintMismatch,
    ExecutableIdentityMismatch,
    HostShuttingDown,
    TooManyClients,
    MissingCapability,
    MalformedHello,
}

impl From<v1::HandshakeRejectReason> for AgentHostHandshakeRejectReasonV1 {
    fn from(value: v1::HandshakeRejectReason) -> Self {
        match value {
            v1::HandshakeRejectReason::Unspecified => Self::Unspecified,
            v1::HandshakeRejectReason::ProtocolVersionMismatch => Self::ProtocolVersionMismatch,
            v1::HandshakeRejectReason::BuildFingerprintMismatch => Self::BuildFingerprintMismatch,
            v1::HandshakeRejectReason::ExecutableIdentityMismatch => {
                Self::ExecutableIdentityMismatch
            }
            v1::HandshakeRejectReason::HostShuttingDown => Self::HostShuttingDown,
            v1::HandshakeRejectReason::TooManyClients => Self::TooManyClients,
            v1::HandshakeRejectReason::MissingCapability => Self::MissingCapability,
            v1::HandshakeRejectReason::MalformedHello => Self::MalformedHello,
        }
    }
}

impl From<AgentHostHandshakeRejectReasonV1> for v1::HandshakeRejectReason {
    fn from(value: AgentHostHandshakeRejectReasonV1) -> Self {
        match value {
            AgentHostHandshakeRejectReasonV1::Unspecified => Self::Unspecified,
            AgentHostHandshakeRejectReasonV1::ProtocolVersionMismatch => {
                Self::ProtocolVersionMismatch
            }
            AgentHostHandshakeRejectReasonV1::BuildFingerprintMismatch => {
                Self::BuildFingerprintMismatch
            }
            AgentHostHandshakeRejectReasonV1::ExecutableIdentityMismatch => {
                Self::ExecutableIdentityMismatch
            }
            AgentHostHandshakeRejectReasonV1::HostShuttingDown => Self::HostShuttingDown,
            AgentHostHandshakeRejectReasonV1::TooManyClients => Self::TooManyClients,
            AgentHostHandshakeRejectReasonV1::MissingCapability => Self::MissingCapability,
            AgentHostHandshakeRejectReasonV1::MalformedHello => Self::MalformedHello,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostHostNoticeKindV1 {
    Unspecified,
    /// The host will close all connections after `HostNotice.deadline_at`.
    ShuttingDown,
    /// A `prepare_update` checkpoint completed; clients should expect a restart.
    UpdatePending,
    /// The set of sessions changed (started, stopped, imported); clients may re-run `list_sessions`.
    SessionListChanged,
}

impl From<v1::HostNoticeKind> for AgentHostHostNoticeKindV1 {
    fn from(value: v1::HostNoticeKind) -> Self {
        match value {
            v1::HostNoticeKind::Unspecified => Self::Unspecified,
            v1::HostNoticeKind::ShuttingDown => Self::ShuttingDown,
            v1::HostNoticeKind::UpdatePending => Self::UpdatePending,
            v1::HostNoticeKind::SessionListChanged => Self::SessionListChanged,
        }
    }
}

impl From<AgentHostHostNoticeKindV1> for v1::HostNoticeKind {
    fn from(value: AgentHostHostNoticeKindV1) -> Self {
        match value {
            AgentHostHostNoticeKindV1::Unspecified => Self::Unspecified,
            AgentHostHostNoticeKindV1::ShuttingDown => Self::ShuttingDown,
            AgentHostHostNoticeKindV1::UpdatePending => Self::UpdatePending,
            AgentHostHostNoticeKindV1::SessionListChanged => Self::SessionListChanged,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostSteerDeliveryV1 {
    Unspecified,
    /// Queue the message; it starts the next turn once the current one ends.
    QueueForNextTurn,
    /// Deliver into the running turn if the provider supports mid-turn steering, else queue.
    InjectIntoCurrentTurn,
}

impl From<v1::SteerDelivery> for AgentHostSteerDeliveryV1 {
    fn from(value: v1::SteerDelivery) -> Self {
        match value {
            v1::SteerDelivery::Unspecified => Self::Unspecified,
            v1::SteerDelivery::QueueForNextTurn => Self::QueueForNextTurn,
            v1::SteerDelivery::InjectIntoCurrentTurn => Self::InjectIntoCurrentTurn,
        }
    }
}

impl From<AgentHostSteerDeliveryV1> for v1::SteerDelivery {
    fn from(value: AgentHostSteerDeliveryV1) -> Self {
        match value {
            AgentHostSteerDeliveryV1::Unspecified => Self::Unspecified,
            AgentHostSteerDeliveryV1::QueueForNextTurn => Self::QueueForNextTurn,
            AgentHostSteerDeliveryV1::InjectIntoCurrentTurn => Self::InjectIntoCurrentTurn,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostStopReasonV1 {
    Unspecified,
    UserRequested,
    WorkspaceClosing,
    ExecutionLocationChange,
    HostPolicy,
}

impl From<v1::StopReason> for AgentHostStopReasonV1 {
    fn from(value: v1::StopReason) -> Self {
        match value {
            v1::StopReason::Unspecified => Self::Unspecified,
            v1::StopReason::UserRequested => Self::UserRequested,
            v1::StopReason::WorkspaceClosing => Self::WorkspaceClosing,
            v1::StopReason::ExecutionLocationChange => Self::ExecutionLocationChange,
            v1::StopReason::HostPolicy => Self::HostPolicy,
        }
    }
}

impl From<AgentHostStopReasonV1> for v1::StopReason {
    fn from(value: AgentHostStopReasonV1) -> Self {
        match value {
            AgentHostStopReasonV1::Unspecified => Self::Unspecified,
            AgentHostStopReasonV1::UserRequested => Self::UserRequested,
            AgentHostStopReasonV1::WorkspaceClosing => Self::WorkspaceClosing,
            AgentHostStopReasonV1::ExecutionLocationChange => Self::ExecutionLocationChange,
            AgentHostStopReasonV1::HostPolicy => Self::HostPolicy,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostShutdownModeV1 {
    Unspecified,
    /// Let running turns finish until `deadline_seconds`, then interrupt.
    Graceful,
    /// Interrupt every turn immediately, checkpoint, exit.
    Immediate,
}

impl From<v1::ShutdownMode> for AgentHostShutdownModeV1 {
    fn from(value: v1::ShutdownMode) -> Self {
        match value {
            v1::ShutdownMode::Unspecified => Self::Unspecified,
            v1::ShutdownMode::Graceful => Self::Graceful,
            v1::ShutdownMode::Immediate => Self::Immediate,
        }
    }
}

impl From<AgentHostShutdownModeV1> for v1::ShutdownMode {
    fn from(value: AgentHostShutdownModeV1) -> Self {
        match value {
            AgentHostShutdownModeV1::Unspecified => Self::Unspecified,
            AgentHostShutdownModeV1::Graceful => Self::Graceful,
            AgentHostShutdownModeV1::Immediate => Self::Immediate,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostCommandRejectionReasonV1 {
    Unspecified,
    InvalidArgument,
    UnknownSession,
    NotAttached,
    SessionNotActive,
    SessionExists,
    UnknownWorkspace,
    CapabilityMissing,
    HandshakeRequired,
    HostShuttingDown,
    LimitExceeded,
    ProviderUnavailable,
}

impl From<v1::CommandRejectionReason> for AgentHostCommandRejectionReasonV1 {
    fn from(value: v1::CommandRejectionReason) -> Self {
        match value {
            v1::CommandRejectionReason::Unspecified => Self::Unspecified,
            v1::CommandRejectionReason::InvalidArgument => Self::InvalidArgument,
            v1::CommandRejectionReason::UnknownSession => Self::UnknownSession,
            v1::CommandRejectionReason::NotAttached => Self::NotAttached,
            v1::CommandRejectionReason::SessionNotActive => Self::SessionNotActive,
            v1::CommandRejectionReason::SessionExists => Self::SessionExists,
            v1::CommandRejectionReason::UnknownWorkspace => Self::UnknownWorkspace,
            v1::CommandRejectionReason::CapabilityMissing => Self::CapabilityMissing,
            v1::CommandRejectionReason::HandshakeRequired => Self::HandshakeRequired,
            v1::CommandRejectionReason::HostShuttingDown => Self::HostShuttingDown,
            v1::CommandRejectionReason::LimitExceeded => Self::LimitExceeded,
            v1::CommandRejectionReason::ProviderUnavailable => Self::ProviderUnavailable,
        }
    }
}

impl From<AgentHostCommandRejectionReasonV1> for v1::CommandRejectionReason {
    fn from(value: AgentHostCommandRejectionReasonV1) -> Self {
        match value {
            AgentHostCommandRejectionReasonV1::Unspecified => Self::Unspecified,
            AgentHostCommandRejectionReasonV1::InvalidArgument => Self::InvalidArgument,
            AgentHostCommandRejectionReasonV1::UnknownSession => Self::UnknownSession,
            AgentHostCommandRejectionReasonV1::NotAttached => Self::NotAttached,
            AgentHostCommandRejectionReasonV1::SessionNotActive => Self::SessionNotActive,
            AgentHostCommandRejectionReasonV1::SessionExists => Self::SessionExists,
            AgentHostCommandRejectionReasonV1::UnknownWorkspace => Self::UnknownWorkspace,
            AgentHostCommandRejectionReasonV1::CapabilityMissing => Self::CapabilityMissing,
            AgentHostCommandRejectionReasonV1::HandshakeRequired => Self::HandshakeRequired,
            AgentHostCommandRejectionReasonV1::HostShuttingDown => Self::HostShuttingDown,
            AgentHostCommandRejectionReasonV1::LimitExceeded => Self::LimitExceeded,
            AgentHostCommandRejectionReasonV1::ProviderUnavailable => Self::ProviderUnavailable,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostAttachReplayV1 {
    Unspecified,
    /// Every event after `resume_cursor` will be delivered; no snapshot stream follows.
    Complete,
    /// Part of the requested tail was compacted away; a snapshot through `snapshot_through_cursor`
    /// follows, then events after it.
    Partial,
    /// The generation changed or the cursor is unknown; a full snapshot follows, then the tail.
    Unavailable,
}

impl From<v1::AttachReplay> for AgentHostAttachReplayV1 {
    fn from(value: v1::AttachReplay) -> Self {
        match value {
            v1::AttachReplay::Unspecified => Self::Unspecified,
            v1::AttachReplay::Complete => Self::Complete,
            v1::AttachReplay::Partial => Self::Partial,
            v1::AttachReplay::Unavailable => Self::Unavailable,
        }
    }
}

impl From<AgentHostAttachReplayV1> for v1::AttachReplay {
    fn from(value: AgentHostAttachReplayV1) -> Self {
        match value {
            AgentHostAttachReplayV1::Unspecified => Self::Unspecified,
            AgentHostAttachReplayV1::Complete => Self::Complete,
            AgentHostAttachReplayV1::Partial => Self::Partial,
            AgentHostAttachReplayV1::Unavailable => Self::Unavailable,
        }
    }
}

/// Mirrors the five-outcome interrupt contract shared with the Claude runtime surface.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostInterruptOutcomeV1 {
    Unspecified,
    Acknowledged,
    NoTurnInFlight,
    StaleGeneration,
    TimedOut,
    Failed,
}

impl From<v1::InterruptOutcome> for AgentHostInterruptOutcomeV1 {
    fn from(value: v1::InterruptOutcome) -> Self {
        match value {
            v1::InterruptOutcome::Unspecified => Self::Unspecified,
            v1::InterruptOutcome::Acknowledged => Self::Acknowledged,
            v1::InterruptOutcome::NoTurnInFlight => Self::NoTurnInFlight,
            v1::InterruptOutcome::StaleGeneration => Self::StaleGeneration,
            v1::InterruptOutcome::TimedOut => Self::TimedOut,
            v1::InterruptOutcome::Failed => Self::Failed,
        }
    }
}

impl From<AgentHostInterruptOutcomeV1> for v1::InterruptOutcome {
    fn from(value: AgentHostInterruptOutcomeV1) -> Self {
        match value {
            AgentHostInterruptOutcomeV1::Unspecified => Self::Unspecified,
            AgentHostInterruptOutcomeV1::Acknowledged => Self::Acknowledged,
            AgentHostInterruptOutcomeV1::NoTurnInFlight => Self::NoTurnInFlight,
            AgentHostInterruptOutcomeV1::StaleGeneration => Self::StaleGeneration,
            AgentHostInterruptOutcomeV1::TimedOut => Self::TimedOut,
            AgentHostInterruptOutcomeV1::Failed => Self::Failed,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostInteractionResponseDispositionV1 {
    Unspecified,
    /// This answer settled the interaction.
    Accepted,
    /// Another writer settled it first (first-writer-wins).
    Superseded,
    StaleGeneration,
    UnknownInteraction,
    /// The interaction timed out or was cancelled by the provider before the answer arrived.
    Expired,
}

impl From<v1::InteractionResponseDisposition> for AgentHostInteractionResponseDispositionV1 {
    fn from(value: v1::InteractionResponseDisposition) -> Self {
        match value {
            v1::InteractionResponseDisposition::Unspecified => Self::Unspecified,
            v1::InteractionResponseDisposition::Accepted => Self::Accepted,
            v1::InteractionResponseDisposition::Superseded => Self::Superseded,
            v1::InteractionResponseDisposition::StaleGeneration => Self::StaleGeneration,
            v1::InteractionResponseDisposition::UnknownInteraction => Self::UnknownInteraction,
            v1::InteractionResponseDisposition::Expired => Self::Expired,
        }
    }
}

impl From<AgentHostInteractionResponseDispositionV1> for v1::InteractionResponseDisposition {
    fn from(value: AgentHostInteractionResponseDispositionV1) -> Self {
        match value {
            AgentHostInteractionResponseDispositionV1::Unspecified => Self::Unspecified,
            AgentHostInteractionResponseDispositionV1::Accepted => Self::Accepted,
            AgentHostInteractionResponseDispositionV1::Superseded => Self::Superseded,
            AgentHostInteractionResponseDispositionV1::StaleGeneration => Self::StaleGeneration,
            AgentHostInteractionResponseDispositionV1::UnknownInteraction => {
                Self::UnknownInteraction
            }
            AgentHostInteractionResponseDispositionV1::Expired => Self::Expired,
        }
    }
}

/// Mirrors the session status vocabulary of the Agent Mode domain snapshot.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostSessionStatusV1 {
    Unspecified,
    Running,
    WaitingForInput,
    Completed,
    Failed,
    Cancelled,
    Expired,
}

impl From<v1::SessionStatus> for AgentHostSessionStatusV1 {
    fn from(value: v1::SessionStatus) -> Self {
        match value {
            v1::SessionStatus::Unspecified => Self::Unspecified,
            v1::SessionStatus::Running => Self::Running,
            v1::SessionStatus::WaitingForInput => Self::WaitingForInput,
            v1::SessionStatus::Completed => Self::Completed,
            v1::SessionStatus::Failed => Self::Failed,
            v1::SessionStatus::Cancelled => Self::Cancelled,
            v1::SessionStatus::Expired => Self::Expired,
        }
    }
}

impl From<AgentHostSessionStatusV1> for v1::SessionStatus {
    fn from(value: AgentHostSessionStatusV1) -> Self {
        match value {
            AgentHostSessionStatusV1::Unspecified => Self::Unspecified,
            AgentHostSessionStatusV1::Running => Self::Running,
            AgentHostSessionStatusV1::WaitingForInput => Self::WaitingForInput,
            AgentHostSessionStatusV1::Completed => Self::Completed,
            AgentHostSessionStatusV1::Failed => Self::Failed,
            AgentHostSessionStatusV1::Cancelled => Self::Cancelled,
            AgentHostSessionStatusV1::Expired => Self::Expired,
        }
    }
}

/// Mirrors the domain `FailureReason` vocabulary.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostFailureReasonV1 {
    Unspecified,
    ProcessCrash,
    Timeout,
    AgentError,
    Cancelled,
}

impl From<v1::FailureReason> for AgentHostFailureReasonV1 {
    fn from(value: v1::FailureReason) -> Self {
        match value {
            v1::FailureReason::Unspecified => Self::Unspecified,
            v1::FailureReason::ProcessCrash => Self::ProcessCrash,
            v1::FailureReason::Timeout => Self::Timeout,
            v1::FailureReason::AgentError => Self::AgentError,
            v1::FailureReason::Cancelled => Self::Cancelled,
        }
    }
}

impl From<AgentHostFailureReasonV1> for v1::FailureReason {
    fn from(value: AgentHostFailureReasonV1) -> Self {
        match value {
            AgentHostFailureReasonV1::Unspecified => Self::Unspecified,
            AgentHostFailureReasonV1::ProcessCrash => Self::ProcessCrash,
            AgentHostFailureReasonV1::Timeout => Self::Timeout,
            AgentHostFailureReasonV1::AgentError => Self::AgentError,
            AgentHostFailureReasonV1::Cancelled => Self::Cancelled,
        }
    }
}

/// Provider-neutral approval routing. Mirrors the Codex approval-policy vocabulary
/// (on request / unless trusted / never) plus the ACP "decline when unattended" fallback.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostApprovalPolicyV1 {
    Unspecified,
    /// Ask an attached presenting client for every request.
    OnRequest,
    /// Ask only for requests the provider does not classify as trusted.
    UnlessTrusted,
    /// Never ask; approve automatically.
    Never,
    /// Decline automatically when no attached client can present.
    DeclineUnattended,
}

impl From<v1::ApprovalPolicy> for AgentHostApprovalPolicyV1 {
    fn from(value: v1::ApprovalPolicy) -> Self {
        match value {
            v1::ApprovalPolicy::Unspecified => Self::Unspecified,
            v1::ApprovalPolicy::OnRequest => Self::OnRequest,
            v1::ApprovalPolicy::UnlessTrusted => Self::UnlessTrusted,
            v1::ApprovalPolicy::Never => Self::Never,
            v1::ApprovalPolicy::DeclineUnattended => Self::DeclineUnattended,
        }
    }
}

impl From<AgentHostApprovalPolicyV1> for v1::ApprovalPolicy {
    fn from(value: AgentHostApprovalPolicyV1) -> Self {
        match value {
            AgentHostApprovalPolicyV1::Unspecified => Self::Unspecified,
            AgentHostApprovalPolicyV1::OnRequest => Self::OnRequest,
            AgentHostApprovalPolicyV1::UnlessTrusted => Self::UnlessTrusted,
            AgentHostApprovalPolicyV1::Never => Self::Never,
            AgentHostApprovalPolicyV1::DeclineUnattended => Self::DeclineUnattended,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostToolDispositionV1 {
    Unspecified,
    Allow,
    Deny,
    Ask,
}

impl From<v1::ToolDisposition> for AgentHostToolDispositionV1 {
    fn from(value: v1::ToolDisposition) -> Self {
        match value {
            v1::ToolDisposition::Unspecified => Self::Unspecified,
            v1::ToolDisposition::Allow => Self::Allow,
            v1::ToolDisposition::Deny => Self::Deny,
            v1::ToolDisposition::Ask => Self::Ask,
        }
    }
}

impl From<AgentHostToolDispositionV1> for v1::ToolDisposition {
    fn from(value: AgentHostToolDispositionV1) -> Self {
        match value {
            AgentHostToolDispositionV1::Unspecified => Self::Unspecified,
            AgentHostToolDispositionV1::Allow => Self::Allow,
            AgentHostToolDispositionV1::Deny => Self::Deny,
            AgentHostToolDispositionV1::Ask => Self::Ask,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostResnapshotReasonV1 {
    Unspecified,
    /// The client fell behind the per-client queue and events were dropped.
    BackpressureOverflow,
    /// The session's generation changed (fork, import, or recovery).
    GenerationChanged,
    /// The requested tail was compacted away.
    LogCompacted,
    /// The host restarted; in-memory subscriptions were lost.
    HostRestarted,
}

impl From<v1::ResnapshotReason> for AgentHostResnapshotReasonV1 {
    fn from(value: v1::ResnapshotReason) -> Self {
        match value {
            v1::ResnapshotReason::Unspecified => Self::Unspecified,
            v1::ResnapshotReason::BackpressureOverflow => Self::BackpressureOverflow,
            v1::ResnapshotReason::GenerationChanged => Self::GenerationChanged,
            v1::ResnapshotReason::LogCompacted => Self::LogCompacted,
            v1::ResnapshotReason::HostRestarted => Self::HostRestarted,
        }
    }
}

impl From<AgentHostResnapshotReasonV1> for v1::ResnapshotReason {
    fn from(value: AgentHostResnapshotReasonV1) -> Self {
        match value {
            AgentHostResnapshotReasonV1::Unspecified => Self::Unspecified,
            AgentHostResnapshotReasonV1::BackpressureOverflow => Self::BackpressureOverflow,
            AgentHostResnapshotReasonV1::GenerationChanged => Self::GenerationChanged,
            AgentHostResnapshotReasonV1::LogCompacted => Self::LogCompacted,
            AgentHostResnapshotReasonV1::HostRestarted => Self::HostRestarted,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostApprovalRequestIdSourceV1 {
    Unspecified,
    Codex,
    ClaudeControl,
    Acp,
}

impl From<v1::ApprovalRequestIdSource> for AgentHostApprovalRequestIdSourceV1 {
    fn from(value: v1::ApprovalRequestIdSource) -> Self {
        match value {
            v1::ApprovalRequestIdSource::Unspecified => Self::Unspecified,
            v1::ApprovalRequestIdSource::Codex => Self::Codex,
            v1::ApprovalRequestIdSource::ClaudeControl => Self::ClaudeControl,
            v1::ApprovalRequestIdSource::Acp => Self::Acp,
        }
    }
}

impl From<AgentHostApprovalRequestIdSourceV1> for v1::ApprovalRequestIdSource {
    fn from(value: AgentHostApprovalRequestIdSourceV1) -> Self {
        match value {
            AgentHostApprovalRequestIdSourceV1::Unspecified => Self::Unspecified,
            AgentHostApprovalRequestIdSourceV1::Codex => Self::Codex,
            AgentHostApprovalRequestIdSourceV1::ClaudeControl => Self::ClaudeControl,
            AgentHostApprovalRequestIdSourceV1::Acp => Self::Acp,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostApprovalKindV1 {
    Unspecified,
    CommandExecution,
    FileChange,
}

impl From<v1::ApprovalKind> for AgentHostApprovalKindV1 {
    fn from(value: v1::ApprovalKind) -> Self {
        match value {
            v1::ApprovalKind::Unspecified => Self::Unspecified,
            v1::ApprovalKind::CommandExecution => Self::CommandExecution,
            v1::ApprovalKind::FileChange => Self::FileChange,
        }
    }
}

impl From<AgentHostApprovalKindV1> for v1::ApprovalKind {
    fn from(value: AgentHostApprovalKindV1) -> Self {
        match value {
            AgentHostApprovalKindV1::Unspecified => Self::Unspecified,
            AgentHostApprovalKindV1::CommandExecution => Self::CommandExecution,
            AgentHostApprovalKindV1::FileChange => Self::FileChange,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostLifecycleStageV1 {
    Unspecified,
    Starting,
    PreparingRuntime,
    Running,
    WaitingForInteraction,
    Retrying,
    Cancelling,
}

impl From<v1::LifecycleStage> for AgentHostLifecycleStageV1 {
    fn from(value: v1::LifecycleStage) -> Self {
        match value {
            v1::LifecycleStage::Unspecified => Self::Unspecified,
            v1::LifecycleStage::Starting => Self::Starting,
            v1::LifecycleStage::PreparingRuntime => Self::PreparingRuntime,
            v1::LifecycleStage::Running => Self::Running,
            v1::LifecycleStage::WaitingForInteraction => Self::WaitingForInteraction,
            v1::LifecycleStage::Retrying => Self::Retrying,
            v1::LifecycleStage::Cancelling => Self::Cancelling,
        }
    }
}

impl From<AgentHostLifecycleStageV1> for v1::LifecycleStage {
    fn from(value: AgentHostLifecycleStageV1) -> Self {
        match value {
            AgentHostLifecycleStageV1::Unspecified => Self::Unspecified,
            AgentHostLifecycleStageV1::Starting => Self::Starting,
            AgentHostLifecycleStageV1::PreparingRuntime => Self::PreparingRuntime,
            AgentHostLifecycleStageV1::Running => Self::Running,
            AgentHostLifecycleStageV1::WaitingForInteraction => Self::WaitingForInteraction,
            AgentHostLifecycleStageV1::Retrying => Self::Retrying,
            AgentHostLifecycleStageV1::Cancelling => Self::Cancelling,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostRetryIntentV1 {
    Unspecified,
    None,
    ProviderManaged,
    ApplicationManaged,
}

impl From<v1::RetryIntent> for AgentHostRetryIntentV1 {
    fn from(value: v1::RetryIntent) -> Self {
        match value {
            v1::RetryIntent::Unspecified => Self::Unspecified,
            v1::RetryIntent::None => Self::None,
            v1::RetryIntent::ProviderManaged => Self::ProviderManaged,
            v1::RetryIntent::ApplicationManaged => Self::ApplicationManaged,
        }
    }
}

impl From<AgentHostRetryIntentV1> for v1::RetryIntent {
    fn from(value: AgentHostRetryIntentV1) -> Self {
        match value {
            AgentHostRetryIntentV1::Unspecified => Self::Unspecified,
            AgentHostRetryIntentV1::None => Self::None,
            AgentHostRetryIntentV1::ProviderManaged => Self::ProviderManaged,
            AgentHostRetryIntentV1::ApplicationManaged => Self::ApplicationManaged,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostEpochTransitionKindV1 {
    Unspecified,
    Initial,
    RelatedFollowUp,
    Steering,
    Unrelated,
}

impl From<v1::EpochTransitionKind> for AgentHostEpochTransitionKindV1 {
    fn from(value: v1::EpochTransitionKind) -> Self {
        match value {
            v1::EpochTransitionKind::Unspecified => Self::Unspecified,
            v1::EpochTransitionKind::Initial => Self::Initial,
            v1::EpochTransitionKind::RelatedFollowUp => Self::RelatedFollowUp,
            v1::EpochTransitionKind::Steering => Self::Steering,
            v1::EpochTransitionKind::Unrelated => Self::Unrelated,
        }
    }
}

impl From<AgentHostEpochTransitionKindV1> for v1::EpochTransitionKind {
    fn from(value: AgentHostEpochTransitionKindV1) -> Self {
        match value {
            AgentHostEpochTransitionKindV1::Unspecified => Self::Unspecified,
            AgentHostEpochTransitionKindV1::Initial => Self::Initial,
            AgentHostEpochTransitionKindV1::RelatedFollowUp => Self::RelatedFollowUp,
            AgentHostEpochTransitionKindV1::Steering => Self::Steering,
            AgentHostEpochTransitionKindV1::Unrelated => Self::Unrelated,
        }
    }
}

/// Mirrors the domain terminal outcome kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostTerminalOutcomeKindV1 {
    Unspecified,
    Completed,
    Cancelled,
    Failed,
}

impl From<v1::TerminalOutcomeKind> for AgentHostTerminalOutcomeKindV1 {
    fn from(value: v1::TerminalOutcomeKind) -> Self {
        match value {
            v1::TerminalOutcomeKind::Unspecified => Self::Unspecified,
            v1::TerminalOutcomeKind::Completed => Self::Completed,
            v1::TerminalOutcomeKind::Cancelled => Self::Cancelled,
            v1::TerminalOutcomeKind::Failed => Self::Failed,
        }
    }
}

impl From<AgentHostTerminalOutcomeKindV1> for v1::TerminalOutcomeKind {
    fn from(value: AgentHostTerminalOutcomeKindV1) -> Self {
        match value {
            AgentHostTerminalOutcomeKindV1::Unspecified => Self::Unspecified,
            AgentHostTerminalOutcomeKindV1::Completed => Self::Completed,
            AgentHostTerminalOutcomeKindV1::Cancelled => Self::Cancelled,
            AgentHostTerminalOutcomeKindV1::Failed => Self::Failed,
        }
    }
}

/// Mirrors the provider termination signal vocabulary.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostTerminationSignalKindV1 {
    Unspecified,
    Completed,
    Cancelled,
    Superseded,
    StartupFailure,
    ProviderFailure,
    Timeout,
    ProcessExited,
    TransportClosed,
    UnexpectedEnd,
}

impl From<v1::TerminationSignalKind> for AgentHostTerminationSignalKindV1 {
    fn from(value: v1::TerminationSignalKind) -> Self {
        match value {
            v1::TerminationSignalKind::Unspecified => Self::Unspecified,
            v1::TerminationSignalKind::Completed => Self::Completed,
            v1::TerminationSignalKind::Cancelled => Self::Cancelled,
            v1::TerminationSignalKind::Superseded => Self::Superseded,
            v1::TerminationSignalKind::StartupFailure => Self::StartupFailure,
            v1::TerminationSignalKind::ProviderFailure => Self::ProviderFailure,
            v1::TerminationSignalKind::Timeout => Self::Timeout,
            v1::TerminationSignalKind::ProcessExited => Self::ProcessExited,
            v1::TerminationSignalKind::TransportClosed => Self::TransportClosed,
            v1::TerminationSignalKind::UnexpectedEnd => Self::UnexpectedEnd,
        }
    }
}

impl From<AgentHostTerminationSignalKindV1> for v1::TerminationSignalKind {
    fn from(value: AgentHostTerminationSignalKindV1) -> Self {
        match value {
            AgentHostTerminationSignalKindV1::Unspecified => Self::Unspecified,
            AgentHostTerminationSignalKindV1::Completed => Self::Completed,
            AgentHostTerminationSignalKindV1::Cancelled => Self::Cancelled,
            AgentHostTerminationSignalKindV1::Superseded => Self::Superseded,
            AgentHostTerminationSignalKindV1::StartupFailure => Self::StartupFailure,
            AgentHostTerminationSignalKindV1::ProviderFailure => Self::ProviderFailure,
            AgentHostTerminationSignalKindV1::Timeout => Self::Timeout,
            AgentHostTerminationSignalKindV1::ProcessExited => Self::ProcessExited,
            AgentHostTerminationSignalKindV1::TransportClosed => Self::TransportClosed,
            AgentHostTerminationSignalKindV1::UnexpectedEnd => Self::UnexpectedEnd,
        }
    }
}

/// Mirrors the domain interaction kind vocabulary.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostInteractionKindV1 {
    Unspecified,
    Instruction,
    Question,
    UserInput,
    Approval,
    HookApproval,
    McpElicitation,
}

impl From<v1::InteractionKind> for AgentHostInteractionKindV1 {
    fn from(value: v1::InteractionKind) -> Self {
        match value {
            v1::InteractionKind::Unspecified => Self::Unspecified,
            v1::InteractionKind::Instruction => Self::Instruction,
            v1::InteractionKind::Question => Self::Question,
            v1::InteractionKind::UserInput => Self::UserInput,
            v1::InteractionKind::Approval => Self::Approval,
            v1::InteractionKind::HookApproval => Self::HookApproval,
            v1::InteractionKind::McpElicitation => Self::McpElicitation,
        }
    }
}

impl From<AgentHostInteractionKindV1> for v1::InteractionKind {
    fn from(value: AgentHostInteractionKindV1) -> Self {
        match value {
            AgentHostInteractionKindV1::Unspecified => Self::Unspecified,
            AgentHostInteractionKindV1::Instruction => Self::Instruction,
            AgentHostInteractionKindV1::Question => Self::Question,
            AgentHostInteractionKindV1::UserInput => Self::UserInput,
            AgentHostInteractionKindV1::Approval => Self::Approval,
            AgentHostInteractionKindV1::HookApproval => Self::HookApproval,
            AgentHostInteractionKindV1::McpElicitation => Self::McpElicitation,
        }
    }
}

/// Mirrors the domain interaction response-type vocabulary.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostInteractionResponseTypeV1 {
    Unspecified,
    Text,
    Choice,
    Structured,
    Decision,
    Elicitation,
}

impl From<v1::InteractionResponseType> for AgentHostInteractionResponseTypeV1 {
    fn from(value: v1::InteractionResponseType) -> Self {
        match value {
            v1::InteractionResponseType::Unspecified => Self::Unspecified,
            v1::InteractionResponseType::Text => Self::Text,
            v1::InteractionResponseType::Choice => Self::Choice,
            v1::InteractionResponseType::Structured => Self::Structured,
            v1::InteractionResponseType::Decision => Self::Decision,
            v1::InteractionResponseType::Elicitation => Self::Elicitation,
        }
    }
}

impl From<AgentHostInteractionResponseTypeV1> for v1::InteractionResponseType {
    fn from(value: AgentHostInteractionResponseTypeV1) -> Self {
        match value {
            AgentHostInteractionResponseTypeV1::Unspecified => Self::Unspecified,
            AgentHostInteractionResponseTypeV1::Text => Self::Text,
            AgentHostInteractionResponseTypeV1::Choice => Self::Choice,
            AgentHostInteractionResponseTypeV1::Structured => Self::Structured,
            AgentHostInteractionResponseTypeV1::Decision => Self::Decision,
            AgentHostInteractionResponseTypeV1::Elicitation => Self::Elicitation,
        }
    }
}

/// Mirrors the approval decision vocabulary.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostApprovalDecisionKindV1 {
    Unspecified,
    Accept,
    AcceptForSession,
    AcceptWithExecpolicyAmendment,
    Decline,
    Cancel,
}

impl From<v1::ApprovalDecisionKind> for AgentHostApprovalDecisionKindV1 {
    fn from(value: v1::ApprovalDecisionKind) -> Self {
        match value {
            v1::ApprovalDecisionKind::Unspecified => Self::Unspecified,
            v1::ApprovalDecisionKind::Accept => Self::Accept,
            v1::ApprovalDecisionKind::AcceptForSession => Self::AcceptForSession,
            v1::ApprovalDecisionKind::AcceptWithExecpolicyAmendment => {
                Self::AcceptWithExecpolicyAmendment
            }
            v1::ApprovalDecisionKind::Decline => Self::Decline,
            v1::ApprovalDecisionKind::Cancel => Self::Cancel,
        }
    }
}

impl From<AgentHostApprovalDecisionKindV1> for v1::ApprovalDecisionKind {
    fn from(value: AgentHostApprovalDecisionKindV1) -> Self {
        match value {
            AgentHostApprovalDecisionKindV1::Unspecified => Self::Unspecified,
            AgentHostApprovalDecisionKindV1::Accept => Self::Accept,
            AgentHostApprovalDecisionKindV1::AcceptForSession => Self::AcceptForSession,
            AgentHostApprovalDecisionKindV1::AcceptWithExecpolicyAmendment => {
                Self::AcceptWithExecpolicyAmendment
            }
            AgentHostApprovalDecisionKindV1::Decline => Self::Decline,
            AgentHostApprovalDecisionKindV1::Cancel => Self::Cancel,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostElicitationActionV1 {
    Unspecified,
    Accept,
    Decline,
    Cancel,
}

impl From<v1::ElicitationAction> for AgentHostElicitationActionV1 {
    fn from(value: v1::ElicitationAction) -> Self {
        match value {
            v1::ElicitationAction::Unspecified => Self::Unspecified,
            v1::ElicitationAction::Accept => Self::Accept,
            v1::ElicitationAction::Decline => Self::Decline,
            v1::ElicitationAction::Cancel => Self::Cancel,
        }
    }
}

impl From<AgentHostElicitationActionV1> for v1::ElicitationAction {
    fn from(value: AgentHostElicitationActionV1) -> Self {
        match value {
            AgentHostElicitationActionV1::Unspecified => Self::Unspecified,
            AgentHostElicitationActionV1::Accept => Self::Accept,
            AgentHostElicitationActionV1::Decline => Self::Decline,
            AgentHostElicitationActionV1::Cancel => Self::Cancel,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostInteractionSettlementV1 {
    Unspecified,
    Answered,
    TimedOut,
    CancelledByProvider,
    AutoResolvedByPolicy,
    SessionTerminated,
}

impl From<v1::InteractionSettlement> for AgentHostInteractionSettlementV1 {
    fn from(value: v1::InteractionSettlement) -> Self {
        match value {
            v1::InteractionSettlement::Unspecified => Self::Unspecified,
            v1::InteractionSettlement::Answered => Self::Answered,
            v1::InteractionSettlement::TimedOut => Self::TimedOut,
            v1::InteractionSettlement::CancelledByProvider => Self::CancelledByProvider,
            v1::InteractionSettlement::AutoResolvedByPolicy => Self::AutoResolvedByPolicy,
            v1::InteractionSettlement::SessionTerminated => Self::SessionTerminated,
        }
    }
}

impl From<AgentHostInteractionSettlementV1> for v1::InteractionSettlement {
    fn from(value: AgentHostInteractionSettlementV1) -> Self {
        match value {
            AgentHostInteractionSettlementV1::Unspecified => Self::Unspecified,
            AgentHostInteractionSettlementV1::Answered => Self::Answered,
            AgentHostInteractionSettlementV1::TimedOut => Self::TimedOut,
            AgentHostInteractionSettlementV1::CancelledByProvider => Self::CancelledByProvider,
            AgentHostInteractionSettlementV1::AutoResolvedByPolicy => Self::AutoResolvedByPolicy,
            AgentHostInteractionSettlementV1::SessionTerminated => Self::SessionTerminated,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AgentHostTranscriptRoleV1 {
    Unspecified,
    User,
    Assistant,
    Tool,
    System,
}

impl From<v1::TranscriptRole> for AgentHostTranscriptRoleV1 {
    fn from(value: v1::TranscriptRole) -> Self {
        match value {
            v1::TranscriptRole::Unspecified => Self::Unspecified,
            v1::TranscriptRole::User => Self::User,
            v1::TranscriptRole::Assistant => Self::Assistant,
            v1::TranscriptRole::Tool => Self::Tool,
            v1::TranscriptRole::System => Self::System,
        }
    }
}

impl From<AgentHostTranscriptRoleV1> for v1::TranscriptRole {
    fn from(value: AgentHostTranscriptRoleV1) -> Self {
        match value {
            AgentHostTranscriptRoleV1::Unspecified => Self::Unspecified,
            AgentHostTranscriptRoleV1::User => Self::User,
            AgentHostTranscriptRoleV1::Assistant => Self::Assistant,
            AgentHostTranscriptRoleV1::Tool => Self::Tool,
            AgentHostTranscriptRoleV1::System => Self::System,
        }
    }
}

// ---- messages -----------------------------------------------------------------------------

/// One frame from a client (GUI, CLI, or MCP process) to the host.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostClientMessageV1 {
    pub body: Option<AgentHostClientMessageBodyV1>,
}

/// `ClientMessage.body` (`oneof body`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostClientMessageBodyV1 {
    /// Must be the first frame on a new connection.
    Hello(AgentHostHelloV1),
    /// Any subsequent frame.
    Command(AgentHostCommandRequestV1),
}

impl TryFrom<v1::client_message::Body> for AgentHostClientMessageBodyV1 {
    type Error = CoreError;

    fn try_from(value: v1::client_message::Body) -> Result<Self, CoreError> {
        Ok(match value {
            v1::client_message::Body::Hello(inner) => Self::Hello(inner.try_into()?),
            v1::client_message::Body::Command(inner) => Self::Command(inner.try_into()?),
        })
    }
}

impl From<AgentHostClientMessageBodyV1> for v1::client_message::Body {
    fn from(value: AgentHostClientMessageBodyV1) -> Self {
        match value {
            AgentHostClientMessageBodyV1::Hello(inner) => Self::Hello(inner.into()),
            AgentHostClientMessageBodyV1::Command(inner) => Self::Command(inner.into()),
        }
    }
}

impl TryFrom<v1::ClientMessage> for AgentHostClientMessageV1 {
    type Error = CoreError;

    fn try_from(value: v1::ClientMessage) -> Result<Self, CoreError> {
        let v1::ClientMessage { body } = value;
        Ok(Self {
            body: body.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostClientMessageV1> for v1::ClientMessage {
    fn from(value: AgentHostClientMessageV1) -> Self {
        let AgentHostClientMessageV1 { body } = value;
        Self {
            body: body.map(Into::into),
        }
    }
}

/// One frame from the host to a client.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostHostMessageV1 {
    pub body: Option<AgentHostHostMessageBodyV1>,
}

/// `HostMessage.body` (`oneof body`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostHostMessageBodyV1 {
    /// Successful handshake reply; first frame on the connection.
    Welcome(AgentHostWelcomeV1),
    /// Handshake refusal; the host closes the connection after sending it.
    HandshakeRejected(AgentHostHandshakeRejectedV1),
    /// Reply to a `CommandRequest`, correlated by `request_id`.
    Response(AgentHostCommandResponseV1),
    /// Live or replayed event for a session the client is attached to.
    Event(AgentHostEventNotificationV1),
    /// Snapshot stream header (see `AttachResult`).
    SnapshotBegin(AgentHostSnapshotBeginV1),
    /// Snapshot stream body chunk (`data` <= 512 KiB).
    SnapshotChunk(AgentHostSnapshotChunkV1),
    /// Snapshot stream trailer; live events resume after it.
    SnapshotEnd(AgentHostSnapshotEndV1),
    /// The host dropped events for this client; it must re-attach and take a fresh snapshot.
    ResnapshotRequired(AgentHostResnapshotRequiredV1),
    /// Unsolicited host-level notice (shutdown, update pending, session list changed).
    Notice(AgentHostHostNoticeV1),
}

impl TryFrom<v1::host_message::Body> for AgentHostHostMessageBodyV1 {
    type Error = CoreError;

    fn try_from(value: v1::host_message::Body) -> Result<Self, CoreError> {
        Ok(match value {
            v1::host_message::Body::Welcome(inner) => Self::Welcome(inner.try_into()?),
            v1::host_message::Body::HandshakeRejected(inner) => {
                Self::HandshakeRejected(inner.try_into()?)
            }
            v1::host_message::Body::Response(inner) => Self::Response(inner.try_into()?),
            v1::host_message::Body::Event(inner) => Self::Event(inner.try_into()?),
            v1::host_message::Body::SnapshotBegin(inner) => Self::SnapshotBegin(inner.try_into()?),
            v1::host_message::Body::SnapshotChunk(inner) => Self::SnapshotChunk(inner.try_into()?),
            v1::host_message::Body::SnapshotEnd(inner) => Self::SnapshotEnd(inner.try_into()?),
            v1::host_message::Body::ResnapshotRequired(inner) => {
                Self::ResnapshotRequired(inner.try_into()?)
            }
            v1::host_message::Body::Notice(inner) => Self::Notice(inner.try_into()?),
        })
    }
}

impl From<AgentHostHostMessageBodyV1> for v1::host_message::Body {
    fn from(value: AgentHostHostMessageBodyV1) -> Self {
        match value {
            AgentHostHostMessageBodyV1::Welcome(inner) => Self::Welcome(inner.into()),
            AgentHostHostMessageBodyV1::HandshakeRejected(inner) => {
                Self::HandshakeRejected(inner.into())
            }
            AgentHostHostMessageBodyV1::Response(inner) => Self::Response(inner.into()),
            AgentHostHostMessageBodyV1::Event(inner) => Self::Event(inner.into()),
            AgentHostHostMessageBodyV1::SnapshotBegin(inner) => Self::SnapshotBegin(inner.into()),
            AgentHostHostMessageBodyV1::SnapshotChunk(inner) => Self::SnapshotChunk(inner.into()),
            AgentHostHostMessageBodyV1::SnapshotEnd(inner) => Self::SnapshotEnd(inner.into()),
            AgentHostHostMessageBodyV1::ResnapshotRequired(inner) => {
                Self::ResnapshotRequired(inner.into())
            }
            AgentHostHostMessageBodyV1::Notice(inner) => Self::Notice(inner.into()),
        }
    }
}

impl TryFrom<v1::HostMessage> for AgentHostHostMessageV1 {
    type Error = CoreError;

    fn try_from(value: v1::HostMessage) -> Result<Self, CoreError> {
        let v1::HostMessage { body } = value;
        Ok(Self {
            body: body.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostHostMessageV1> for v1::HostMessage {
    fn from(value: AgentHostHostMessageV1) -> Self {
        let AgentHostHostMessageV1 { body } = value;
        Self {
            body: body.map(Into::into),
        }
    }
}

/// Identity of the executable on either end of the connection. Used to refuse mixing a debug GUI
/// with a release host (or vice versa) and to surface who is connected in diagnostics.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostExecutableIdentityV1 {
    /// Bundle identifier of the containing app, e.g. the debug and release bundles differ.
    pub bundle_identifier: String,
    /// Executable name, e.g. `agentry-mcp`.
    pub executable_name: String,
    /// Marketing version string.
    pub version: String,
    /// Build number string.
    pub build_number: String,
    /// Process identifier; informational only.
    pub pid: u32,
    /// Code-signing team identifier; empty when ad-hoc signed or unsigned.
    pub code_signing_team_identifier: String,
}

impl TryFrom<v1::ExecutableIdentity> for AgentHostExecutableIdentityV1 {
    type Error = CoreError;

    fn try_from(value: v1::ExecutableIdentity) -> Result<Self, CoreError> {
        let v1::ExecutableIdentity {
            bundle_identifier,
            executable_name,
            version,
            build_number,
            pid,
            code_signing_team_identifier,
        } = value;
        Ok(Self {
            bundle_identifier,
            executable_name,
            version,
            build_number,
            pid,
            code_signing_team_identifier,
        })
    }
}

impl From<AgentHostExecutableIdentityV1> for v1::ExecutableIdentity {
    fn from(value: AgentHostExecutableIdentityV1) -> Self {
        let AgentHostExecutableIdentityV1 {
            bundle_identifier,
            executable_name,
            version,
            build_number,
            pid,
            code_signing_team_identifier,
        } = value;
        Self {
            bundle_identifier,
            executable_name,
            version,
            build_number,
            pid,
            code_signing_team_identifier,
        }
    }
}

/// First client frame.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostHelloV1 {
    /// Must equal the host's protocol version (1 for this file).
    pub protocol_version: u32,
    /// `CoreBuildFingerprint` of the Rust core linked into the client (ADR-0007). The host compares it
    /// with its own; a mismatch is rejected because both sides must share one codec build.
    pub build_fingerprint: String,
    pub executable: Option<AgentHostExecutableIdentityV1>,
    pub capabilities: Vec<AgentHostCapabilityV1>,
    /// Caller-generated UUID for this connection; echoed in `Welcome.client_id`.
    pub client_id: String,
    pub client_kind: AgentHostClientKindV1,
}

impl TryFrom<v1::Hello> for AgentHostHelloV1 {
    type Error = CoreError;

    fn try_from(value: v1::Hello) -> Result<Self, CoreError> {
        let v1::Hello {
            protocol_version,
            build_fingerprint,
            executable,
            capabilities,
            client_id,
            client_kind,
        } = value;
        Ok(Self {
            protocol_version,
            build_fingerprint,
            executable: executable.map(TryInto::try_into).transpose()?,
            capabilities: enums_from_i32::<v1::Capability, _>("Capability", capabilities)?,
            client_id,
            client_kind: enum_from_i32::<v1::ClientKind, _>("ClientKind", client_kind)?,
        })
    }
}

impl From<AgentHostHelloV1> for v1::Hello {
    fn from(value: AgentHostHelloV1) -> Self {
        let AgentHostHelloV1 {
            protocol_version,
            build_fingerprint,
            executable,
            capabilities,
            client_id,
            client_kind,
        } = value;
        Self {
            protocol_version,
            build_fingerprint,
            executable: executable.map(Into::into),
            capabilities: capabilities
                .into_iter()
                .map(|value| v1::Capability::from(value) as i32)
                .collect(),
            client_id,
            client_kind: v1::ClientKind::from(client_kind) as i32,
        }
    }
}

/// Successful handshake reply.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostWelcomeV1 {
    pub protocol_version: u32,
    /// The host's `CoreBuildFingerprint`; clients re-check it (bidirectional verification).
    pub build_fingerprint: String,
    pub executable: Option<AgentHostExecutableIdentityV1>,
    pub capabilities: Vec<AgentHostCapabilityV1>,
    /// UUID minted once per host process lifetime; changes when the host restarts.
    pub host_instance_id: String,
    /// Echo of `Hello.client_id`.
    pub client_id: String,
    /// Advertised framing limits so clients never hard-code them (1 MiB / 512 KiB in v1).
    pub maximum_frame_bytes: u32,
    pub maximum_snapshot_chunk_bytes: u32,
    /// RFC 3339 host start time.
    pub host_started_at: String,
}

impl TryFrom<v1::Welcome> for AgentHostWelcomeV1 {
    type Error = CoreError;

    fn try_from(value: v1::Welcome) -> Result<Self, CoreError> {
        let v1::Welcome {
            protocol_version,
            build_fingerprint,
            executable,
            capabilities,
            host_instance_id,
            client_id,
            maximum_frame_bytes,
            maximum_snapshot_chunk_bytes,
            host_started_at,
        } = value;
        Ok(Self {
            protocol_version,
            build_fingerprint,
            executable: executable.map(TryInto::try_into).transpose()?,
            capabilities: enums_from_i32::<v1::Capability, _>("Capability", capabilities)?,
            host_instance_id,
            client_id,
            maximum_frame_bytes,
            maximum_snapshot_chunk_bytes,
            host_started_at,
        })
    }
}

impl From<AgentHostWelcomeV1> for v1::Welcome {
    fn from(value: AgentHostWelcomeV1) -> Self {
        let AgentHostWelcomeV1 {
            protocol_version,
            build_fingerprint,
            executable,
            capabilities,
            host_instance_id,
            client_id,
            maximum_frame_bytes,
            maximum_snapshot_chunk_bytes,
            host_started_at,
        } = value;
        Self {
            protocol_version,
            build_fingerprint,
            executable: executable.map(Into::into),
            capabilities: capabilities
                .into_iter()
                .map(|value| v1::Capability::from(value) as i32)
                .collect(),
            host_instance_id,
            client_id,
            maximum_frame_bytes,
            maximum_snapshot_chunk_bytes,
            host_started_at,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostHandshakeRejectedV1 {
    pub reason: AgentHostHandshakeRejectReasonV1,
    pub detail: String,
    pub host_protocol_version: u32,
    pub host_build_fingerprint: String,
}

impl TryFrom<v1::HandshakeRejected> for AgentHostHandshakeRejectedV1 {
    type Error = CoreError;

    fn try_from(value: v1::HandshakeRejected) -> Result<Self, CoreError> {
        let v1::HandshakeRejected {
            reason,
            detail,
            host_protocol_version,
            host_build_fingerprint,
        } = value;
        Ok(Self {
            reason: enum_from_i32::<v1::HandshakeRejectReason, _>("HandshakeRejectReason", reason)?,
            detail,
            host_protocol_version,
            host_build_fingerprint,
        })
    }
}

impl From<AgentHostHandshakeRejectedV1> for v1::HandshakeRejected {
    fn from(value: AgentHostHandshakeRejectedV1) -> Self {
        let AgentHostHandshakeRejectedV1 {
            reason,
            detail,
            host_protocol_version,
            host_build_fingerprint,
        } = value;
        Self {
            reason: v1::HandshakeRejectReason::from(reason) as i32,
            detail,
            host_protocol_version,
            host_build_fingerprint,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostHostNoticeV1 {
    pub kind: AgentHostHostNoticeKindV1,
    pub detail: String,
    /// RFC 3339; set for `SHUTTING_DOWN`.
    pub deadline_at: String,
    /// Set when the notice concerns one session.
    pub session_id: String,
}

impl TryFrom<v1::HostNotice> for AgentHostHostNoticeV1 {
    type Error = CoreError;

    fn try_from(value: v1::HostNotice) -> Result<Self, CoreError> {
        let v1::HostNotice {
            kind,
            detail,
            deadline_at,
            session_id,
        } = value;
        Ok(Self {
            kind: enum_from_i32::<v1::HostNoticeKind, _>("HostNoticeKind", kind)?,
            detail,
            deadline_at,
            session_id,
        })
    }
}

impl From<AgentHostHostNoticeV1> for v1::HostNotice {
    fn from(value: AgentHostHostNoticeV1) -> Self {
        let AgentHostHostNoticeV1 {
            kind,
            detail,
            deadline_at,
            session_id,
        } = value;
        Self {
            kind: v1::HostNoticeKind::from(kind) as i32,
            detail,
            deadline_at,
            session_id,
        }
    }
}

/// Idempotency key carried by every mutating command. `operation_id` is a caller-generated UUID;
/// `argument_fingerprint` is the lowercase hex SHA-256 of the command's deterministic encoding with
/// the `key` field cleared (computed by `agentry_proto::agent_host::command_fingerprint`, exposed to
/// Swift through the FFI). The host records `CommandAccepted { operation_id, argument_fingerprint }`
/// before executing; a retry with the same id and fingerprint returns the recorded settlement, the
/// same id with a different fingerprint is an `OperationConflict`.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostMutationKeyV1 {
    pub operation_id: String,
    pub argument_fingerprint: String,
}

impl TryFrom<v1::MutationKey> for AgentHostMutationKeyV1 {
    type Error = CoreError;

    fn try_from(value: v1::MutationKey) -> Result<Self, CoreError> {
        let v1::MutationKey {
            operation_id,
            argument_fingerprint,
        } = value;
        Ok(Self {
            operation_id,
            argument_fingerprint,
        })
    }
}

impl From<AgentHostMutationKeyV1> for v1::MutationKey {
    fn from(value: AgentHostMutationKeyV1) -> Self {
        let AgentHostMutationKeyV1 {
            operation_id,
            argument_fingerprint,
        } = value;
        Self {
            operation_id,
            argument_fingerprint,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostCommandRequestV1 {
    /// Per-connection UUID echoed in `CommandResponse.request_id`.
    pub request_id: String,
    pub command: Option<AgentHostCommandRequestCommandV1>,
}

/// `CommandRequest.command` (`oneof command`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostCommandRequestCommandV1 {
    ListSessions(AgentHostListSessionsV1),
    Attach(AgentHostAttachV1),
    Detach(AgentHostDetachV1),
    Start(AgentHostStartV1),
    Steer(AgentHostSteerV1),
    Interrupt(AgentHostInterruptV1),
    RespondInteraction(AgentHostRespondInteractionV1),
    Stop(AgentHostStopV1),
    HostControl(AgentHostHostControlV1),
}

impl TryFrom<v1::command_request::Command> for AgentHostCommandRequestCommandV1 {
    type Error = CoreError;

    fn try_from(value: v1::command_request::Command) -> Result<Self, CoreError> {
        Ok(match value {
            v1::command_request::Command::ListSessions(inner) => {
                Self::ListSessions(inner.try_into()?)
            }
            v1::command_request::Command::Attach(inner) => Self::Attach(inner.try_into()?),
            v1::command_request::Command::Detach(inner) => Self::Detach(inner.try_into()?),
            v1::command_request::Command::Start(inner) => Self::Start(inner.try_into()?),
            v1::command_request::Command::Steer(inner) => Self::Steer(inner.try_into()?),
            v1::command_request::Command::Interrupt(inner) => Self::Interrupt(inner.try_into()?),
            v1::command_request::Command::RespondInteraction(inner) => {
                Self::RespondInteraction(inner.try_into()?)
            }
            v1::command_request::Command::Stop(inner) => Self::Stop(inner.try_into()?),
            v1::command_request::Command::HostControl(inner) => {
                Self::HostControl(inner.try_into()?)
            }
        })
    }
}

impl From<AgentHostCommandRequestCommandV1> for v1::command_request::Command {
    fn from(value: AgentHostCommandRequestCommandV1) -> Self {
        match value {
            AgentHostCommandRequestCommandV1::ListSessions(inner) => {
                Self::ListSessions(inner.into())
            }
            AgentHostCommandRequestCommandV1::Attach(inner) => Self::Attach(inner.into()),
            AgentHostCommandRequestCommandV1::Detach(inner) => Self::Detach(inner.into()),
            AgentHostCommandRequestCommandV1::Start(inner) => Self::Start(inner.into()),
            AgentHostCommandRequestCommandV1::Steer(inner) => Self::Steer(inner.into()),
            AgentHostCommandRequestCommandV1::Interrupt(inner) => Self::Interrupt(inner.into()),
            AgentHostCommandRequestCommandV1::RespondInteraction(inner) => {
                Self::RespondInteraction(inner.into())
            }
            AgentHostCommandRequestCommandV1::Stop(inner) => Self::Stop(inner.into()),
            AgentHostCommandRequestCommandV1::HostControl(inner) => Self::HostControl(inner.into()),
        }
    }
}

impl TryFrom<v1::CommandRequest> for AgentHostCommandRequestV1 {
    type Error = CoreError;

    fn try_from(value: v1::CommandRequest) -> Result<Self, CoreError> {
        let v1::CommandRequest {
            request_id,
            command,
        } = value;
        Ok(Self {
            request_id,
            command: command.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostCommandRequestV1> for v1::CommandRequest {
    fn from(value: AgentHostCommandRequestV1) -> Self {
        let AgentHostCommandRequestV1 {
            request_id,
            command,
        } = value;
        Self {
            request_id,
            command: command.map(Into::into),
        }
    }
}

/// Read-only. Lists sessions the host knows about (running, waiting, and -- when requested --
/// terminal ones still on disk).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostListSessionsV1 {
    pub include_terminal: bool,
    /// Optional filter by workspace.
    pub workspace_id: String,
}

impl TryFrom<v1::ListSessions> for AgentHostListSessionsV1 {
    type Error = CoreError;

    fn try_from(value: v1::ListSessions) -> Result<Self, CoreError> {
        let v1::ListSessions {
            include_terminal,
            workspace_id,
        } = value;
        Ok(Self {
            include_terminal,
            workspace_id,
        })
    }
}

impl From<AgentHostListSessionsV1> for v1::ListSessions {
    fn from(value: AgentHostListSessionsV1) -> Self {
        let AgentHostListSessionsV1 {
            include_terminal,
            workspace_id,
        } = value;
        Self {
            include_terminal,
            workspace_id,
        }
    }
}

/// Read-only for the session; registers this connection as a subscriber. The host answers with an
/// `AttachResult` and, when a snapshot is needed, a snapshot stream, then delivers events in cursor
/// order. Idempotent: attaching twice replaces the previous subscription.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostAttachV1 {
    pub session_id: String,
    /// Last cursor the client has already applied; absent means "from the beginning".
    pub resume_cursor: Option<u64>,
    /// Generation the `resume_cursor` belongs to. A different current generation yields
    /// `ATTACH_REPLAY_UNAVAILABLE` and a full snapshot.
    pub resume_generation: Vec<u8>,
}

impl TryFrom<v1::Attach> for AgentHostAttachV1 {
    type Error = CoreError;

    fn try_from(value: v1::Attach) -> Result<Self, CoreError> {
        let v1::Attach {
            session_id,
            resume_cursor,
            resume_generation,
        } = value;
        Ok(Self {
            session_id,
            resume_cursor,
            resume_generation,
        })
    }
}

impl From<AgentHostAttachV1> for v1::Attach {
    fn from(value: AgentHostAttachV1) -> Self {
        let AgentHostAttachV1 {
            session_id,
            resume_cursor,
            resume_generation,
        } = value;
        Self {
            session_id,
            resume_cursor,
            resume_generation,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostDetachV1 {
    pub session_id: String,
}

impl TryFrom<v1::Detach> for AgentHostDetachV1 {
    type Error = CoreError;

    fn try_from(value: v1::Detach) -> Result<Self, CoreError> {
        let v1::Detach { session_id } = value;
        Ok(Self { session_id })
    }
}

impl From<AgentHostDetachV1> for v1::Detach {
    fn from(value: AgentHostDetachV1) -> Self {
        let AgentHostDetachV1 { session_id } = value;
        Self { session_id }
    }
}

/// Mutating. Creates and starts a session. `spec.session_id` is caller-generated so a retried
/// `Start` with the same `key` is idempotent and a colliding session id with a different key is a
/// rejection (`COMMAND_REJECTION_REASON_SESSION_EXISTS`).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostStartV1 {
    pub key: Option<AgentHostMutationKeyV1>,
    pub spec: Option<AgentHostSessionSpecV1>,
}

impl TryFrom<v1::Start> for AgentHostStartV1 {
    type Error = CoreError;

    fn try_from(value: v1::Start) -> Result<Self, CoreError> {
        let v1::Start { key, spec } = value;
        Ok(Self {
            key: key.map(TryInto::try_into).transpose()?,
            spec: spec.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostStartV1> for v1::Start {
    fn from(value: AgentHostStartV1) -> Self {
        let AgentHostStartV1 { key, spec } = value;
        Self {
            key: key.map(Into::into),
            spec: spec.map(Into::into),
        }
    }
}

/// Mutating. Sends a user message to a session.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSteerV1 {
    pub key: Option<AgentHostMutationKeyV1>,
    pub session_id: String,
    pub message: Option<AgentHostUserMessageV1>,
    pub delivery: AgentHostSteerDeliveryV1,
}

impl TryFrom<v1::Steer> for AgentHostSteerV1 {
    type Error = CoreError;

    fn try_from(value: v1::Steer) -> Result<Self, CoreError> {
        let v1::Steer {
            key,
            session_id,
            message,
            delivery,
        } = value;
        Ok(Self {
            key: key.map(TryInto::try_into).transpose()?,
            session_id,
            message: message.map(TryInto::try_into).transpose()?,
            delivery: enum_from_i32::<v1::SteerDelivery, _>("SteerDelivery", delivery)?,
        })
    }
}

impl From<AgentHostSteerV1> for v1::Steer {
    fn from(value: AgentHostSteerV1) -> Self {
        let AgentHostSteerV1 {
            key,
            session_id,
            message,
            delivery,
        } = value;
        Self {
            key: key.map(Into::into),
            session_id,
            message: message.map(Into::into),
            delivery: v1::SteerDelivery::from(delivery) as i32,
        }
    }
}

/// Mutating. Interrupts the in-flight turn (mirrors the `interruptTurn` cancellation intent). The
/// session stays alive and resumable; use `Stop` to terminate the runtime.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostInterruptV1 {
    pub key: Option<AgentHostMutationKeyV1>,
    pub session_id: String,
    /// Turn the caller believes is running; empty means "whatever is running".
    pub turn_id: String,
}

impl TryFrom<v1::Interrupt> for AgentHostInterruptV1 {
    type Error = CoreError;

    fn try_from(value: v1::Interrupt) -> Result<Self, CoreError> {
        let v1::Interrupt {
            key,
            session_id,
            turn_id,
        } = value;
        Ok(Self {
            key: key.map(TryInto::try_into).transpose()?,
            session_id,
            turn_id,
        })
    }
}

impl From<AgentHostInterruptV1> for v1::Interrupt {
    fn from(value: AgentHostInterruptV1) -> Self {
        let AgentHostInterruptV1 {
            key,
            session_id,
            turn_id,
        } = value;
        Self {
            key: key.map(Into::into),
            session_id,
            turn_id,
        }
    }
}

/// Mutating. Answers a pending interaction. First writer wins: the first accepted answer settles the
/// interaction; later answers are reported as `INTERACTION_RESPONSE_DISPOSITION_SUPERSEDED`.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostRespondInteractionV1 {
    pub key: Option<AgentHostMutationKeyV1>,
    pub session_id: String,
    pub interaction_id: String,
    /// Must equal `PendingInteraction.interaction_generation`; a mismatch is
    /// `INTERACTION_RESPONSE_DISPOSITION_STALE_GENERATION`.
    pub interaction_generation: Vec<u8>,
    pub answer: Option<AgentHostInteractionAnswerV1>,
}

impl TryFrom<v1::RespondInteraction> for AgentHostRespondInteractionV1 {
    type Error = CoreError;

    fn try_from(value: v1::RespondInteraction) -> Result<Self, CoreError> {
        let v1::RespondInteraction {
            key,
            session_id,
            interaction_id,
            interaction_generation,
            answer,
        } = value;
        Ok(Self {
            key: key.map(TryInto::try_into).transpose()?,
            session_id,
            interaction_id,
            interaction_generation,
            answer: answer.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostRespondInteractionV1> for v1::RespondInteraction {
    fn from(value: AgentHostRespondInteractionV1) -> Self {
        let AgentHostRespondInteractionV1 {
            key,
            session_id,
            interaction_id,
            interaction_generation,
            answer,
        } = value;
        Self {
            key: key.map(Into::into),
            session_id,
            interaction_id,
            interaction_generation,
            answer: answer.map(Into::into),
        }
    }
}

/// Mutating. Terminates the session's provider runtime (mirrors the `cancelSessionRuntime` intent).
/// The event log is kept; the session becomes terminal (`SESSION_STATUS_CANCELLED`).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostStopV1 {
    pub key: Option<AgentHostMutationKeyV1>,
    pub session_id: String,
    pub reason: AgentHostStopReasonV1,
}

impl TryFrom<v1::Stop> for AgentHostStopV1 {
    type Error = CoreError;

    fn try_from(value: v1::Stop) -> Result<Self, CoreError> {
        let v1::Stop {
            key,
            session_id,
            reason,
        } = value;
        Ok(Self {
            key: key.map(TryInto::try_into).transpose()?,
            session_id,
            reason: enum_from_i32::<v1::StopReason, _>("StopReason", reason)?,
        })
    }
}

impl From<AgentHostStopV1> for v1::Stop {
    fn from(value: AgentHostStopV1) -> Self {
        let AgentHostStopV1 {
            key,
            session_id,
            reason,
        } = value;
        Self {
            key: key.map(Into::into),
            session_id,
            reason: v1::StopReason::from(reason) as i32,
        }
    }
}

/// Ask the host to flush every log, write a snapshot per session, and refuse new work so an app
/// update can restart it (design §5.4 `prepare_update`).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostPrepareUpdateV1 {
    pub deadline_seconds: u32,
}

impl TryFrom<v1::PrepareUpdate> for AgentHostPrepareUpdateV1 {
    type Error = CoreError;

    fn try_from(value: v1::PrepareUpdate) -> Result<Self, CoreError> {
        let v1::PrepareUpdate { deadline_seconds } = value;
        Ok(Self { deadline_seconds })
    }
}

impl From<AgentHostPrepareUpdateV1> for v1::PrepareUpdate {
    fn from(value: AgentHostPrepareUpdateV1) -> Self {
        let AgentHostPrepareUpdateV1 { deadline_seconds } = value;
        Self { deadline_seconds }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostShutdownV1 {
    pub mode: AgentHostShutdownModeV1,
    pub deadline_seconds: u32,
}

impl TryFrom<v1::Shutdown> for AgentHostShutdownV1 {
    type Error = CoreError;

    fn try_from(value: v1::Shutdown) -> Result<Self, CoreError> {
        let v1::Shutdown {
            mode,
            deadline_seconds,
        } = value;
        Ok(Self {
            mode: enum_from_i32::<v1::ShutdownMode, _>("ShutdownMode", mode)?,
            deadline_seconds,
        })
    }
}

impl From<AgentHostShutdownV1> for v1::Shutdown {
    fn from(value: AgentHostShutdownV1) -> Self {
        let AgentHostShutdownV1 {
            mode,
            deadline_seconds,
        } = value;
        Self {
            mode: v1::ShutdownMode::from(mode) as i32,
            deadline_seconds,
        }
    }
}

/// Mutating host-level control. Idempotency for host control is per host process lifetime (there
/// is no host-level log in v1).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostHostControlV1 {
    pub key: Option<AgentHostMutationKeyV1>,
    pub action: Option<AgentHostHostControlActionV1>,
}

/// `HostControl.action` (`oneof action`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostHostControlActionV1 {
    PrepareUpdate(AgentHostPrepareUpdateV1),
    Shutdown(AgentHostShutdownV1),
}

impl TryFrom<v1::host_control::Action> for AgentHostHostControlActionV1 {
    type Error = CoreError;

    fn try_from(value: v1::host_control::Action) -> Result<Self, CoreError> {
        Ok(match value {
            v1::host_control::Action::PrepareUpdate(inner) => {
                Self::PrepareUpdate(inner.try_into()?)
            }
            v1::host_control::Action::Shutdown(inner) => Self::Shutdown(inner.try_into()?),
        })
    }
}

impl From<AgentHostHostControlActionV1> for v1::host_control::Action {
    fn from(value: AgentHostHostControlActionV1) -> Self {
        match value {
            AgentHostHostControlActionV1::PrepareUpdate(inner) => Self::PrepareUpdate(inner.into()),
            AgentHostHostControlActionV1::Shutdown(inner) => Self::Shutdown(inner.into()),
        }
    }
}

impl TryFrom<v1::HostControl> for AgentHostHostControlV1 {
    type Error = CoreError;

    fn try_from(value: v1::HostControl) -> Result<Self, CoreError> {
        let v1::HostControl { key, action } = value;
        Ok(Self {
            key: key.map(TryInto::try_into).transpose()?,
            action: action.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostHostControlV1> for v1::HostControl {
    fn from(value: AgentHostHostControlV1) -> Self {
        let AgentHostHostControlV1 { key, action } = value;
        Self {
            key: key.map(Into::into),
            action: action.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostCommandResponseV1 {
    pub request_id: String,
    pub outcome: Option<AgentHostCommandResponseOutcomeV1>,
}

/// `CommandResponse.outcome` (`oneof outcome`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostCommandResponseOutcomeV1 {
    /// Success. For mutating commands this means a `CommandSettled` record exists.
    Result(AgentHostCommandResultV1),
    /// Same `operation_id` seen before with a different `argument_fingerprint`.
    OperationConflict(AgentHostOperationConflictV1),
    /// The host cannot tell whether the operation settled (for example the connection dropped between
    /// `CommandAccepted` and `CommandSettled`). The client must re-attach and read the settlement
    /// from the event log instead of retrying blindly.
    Uncertain(AgentHostOperationUncertainV1),
    /// The command was not accepted at all; nothing was recorded.
    Rejected(AgentHostCommandRejectedV1),
}

impl TryFrom<v1::command_response::Outcome> for AgentHostCommandResponseOutcomeV1 {
    type Error = CoreError;

    fn try_from(value: v1::command_response::Outcome) -> Result<Self, CoreError> {
        Ok(match value {
            v1::command_response::Outcome::Result(inner) => Self::Result(inner.try_into()?),
            v1::command_response::Outcome::OperationConflict(inner) => {
                Self::OperationConflict(inner.try_into()?)
            }
            v1::command_response::Outcome::Uncertain(inner) => Self::Uncertain(inner.try_into()?),
            v1::command_response::Outcome::Rejected(inner) => Self::Rejected(inner.try_into()?),
        })
    }
}

impl From<AgentHostCommandResponseOutcomeV1> for v1::command_response::Outcome {
    fn from(value: AgentHostCommandResponseOutcomeV1) -> Self {
        match value {
            AgentHostCommandResponseOutcomeV1::Result(inner) => Self::Result(inner.into()),
            AgentHostCommandResponseOutcomeV1::OperationConflict(inner) => {
                Self::OperationConflict(inner.into())
            }
            AgentHostCommandResponseOutcomeV1::Uncertain(inner) => Self::Uncertain(inner.into()),
            AgentHostCommandResponseOutcomeV1::Rejected(inner) => Self::Rejected(inner.into()),
        }
    }
}

impl TryFrom<v1::CommandResponse> for AgentHostCommandResponseV1 {
    type Error = CoreError;

    fn try_from(value: v1::CommandResponse) -> Result<Self, CoreError> {
        let v1::CommandResponse {
            request_id,
            outcome,
        } = value;
        Ok(Self {
            request_id,
            outcome: outcome.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostCommandResponseV1> for v1::CommandResponse {
    fn from(value: AgentHostCommandResponseV1) -> Self {
        let AgentHostCommandResponseV1 {
            request_id,
            outcome,
        } = value;
        Self {
            request_id,
            outcome: outcome.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostOperationConflictV1 {
    pub operation_id: String,
    pub recorded_fingerprint: String,
    pub submitted_fingerprint: String,
}

impl TryFrom<v1::OperationConflict> for AgentHostOperationConflictV1 {
    type Error = CoreError;

    fn try_from(value: v1::OperationConflict) -> Result<Self, CoreError> {
        let v1::OperationConflict {
            operation_id,
            recorded_fingerprint,
            submitted_fingerprint,
        } = value;
        Ok(Self {
            operation_id,
            recorded_fingerprint,
            submitted_fingerprint,
        })
    }
}

impl From<AgentHostOperationConflictV1> for v1::OperationConflict {
    fn from(value: AgentHostOperationConflictV1) -> Self {
        let AgentHostOperationConflictV1 {
            operation_id,
            recorded_fingerprint,
            submitted_fingerprint,
        } = value;
        Self {
            operation_id,
            recorded_fingerprint,
            submitted_fingerprint,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostOperationUncertainV1 {
    pub operation_id: String,
    pub detail: String,
}

impl TryFrom<v1::OperationUncertain> for AgentHostOperationUncertainV1 {
    type Error = CoreError;

    fn try_from(value: v1::OperationUncertain) -> Result<Self, CoreError> {
        let v1::OperationUncertain {
            operation_id,
            detail,
        } = value;
        Ok(Self {
            operation_id,
            detail,
        })
    }
}

impl From<AgentHostOperationUncertainV1> for v1::OperationUncertain {
    fn from(value: AgentHostOperationUncertainV1) -> Self {
        let AgentHostOperationUncertainV1 {
            operation_id,
            detail,
        } = value;
        Self {
            operation_id,
            detail,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostCommandRejectedV1 {
    pub reason: AgentHostCommandRejectionReasonV1,
    pub detail: String,
}

impl TryFrom<v1::CommandRejected> for AgentHostCommandRejectedV1 {
    type Error = CoreError;

    fn try_from(value: v1::CommandRejected) -> Result<Self, CoreError> {
        let v1::CommandRejected { reason, detail } = value;
        Ok(Self {
            reason: enum_from_i32::<v1::CommandRejectionReason, _>(
                "CommandRejectionReason",
                reason,
            )?,
            detail,
        })
    }
}

impl From<AgentHostCommandRejectedV1> for v1::CommandRejected {
    fn from(value: AgentHostCommandRejectedV1) -> Self {
        let AgentHostCommandRejectedV1 { reason, detail } = value;
        Self {
            reason: v1::CommandRejectionReason::from(reason) as i32,
            detail,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostCommandResultV1 {
    pub result: Option<AgentHostCommandResultCaseV1>,
}

/// `CommandResult.result` (`oneof result`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostCommandResultCaseV1 {
    SessionList(AgentHostSessionListV1),
    Attached(AgentHostAttachResultV1),
    Detached(AgentHostDetachedV1),
    Started(AgentHostSessionStartedV1),
    Steered(AgentHostSteeredV1),
    Interrupted(AgentHostInterruptResultV1),
    InteractionResponded(AgentHostInteractionRespondedV1),
    Stopped(AgentHostStoppedV1),
    HostControl(AgentHostHostControlResultV1),
}

impl TryFrom<v1::command_result::Result> for AgentHostCommandResultCaseV1 {
    type Error = CoreError;

    fn try_from(value: v1::command_result::Result) -> Result<Self, CoreError> {
        Ok(match value {
            v1::command_result::Result::SessionList(inner) => Self::SessionList(inner.try_into()?),
            v1::command_result::Result::Attached(inner) => Self::Attached(inner.try_into()?),
            v1::command_result::Result::Detached(inner) => Self::Detached(inner.try_into()?),
            v1::command_result::Result::Started(inner) => Self::Started(inner.try_into()?),
            v1::command_result::Result::Steered(inner) => Self::Steered(inner.try_into()?),
            v1::command_result::Result::Interrupted(inner) => Self::Interrupted(inner.try_into()?),
            v1::command_result::Result::InteractionResponded(inner) => {
                Self::InteractionResponded(inner.try_into()?)
            }
            v1::command_result::Result::Stopped(inner) => Self::Stopped(inner.try_into()?),
            v1::command_result::Result::HostControl(inner) => Self::HostControl(inner.try_into()?),
        })
    }
}

impl From<AgentHostCommandResultCaseV1> for v1::command_result::Result {
    fn from(value: AgentHostCommandResultCaseV1) -> Self {
        match value {
            AgentHostCommandResultCaseV1::SessionList(inner) => Self::SessionList(inner.into()),
            AgentHostCommandResultCaseV1::Attached(inner) => Self::Attached(inner.into()),
            AgentHostCommandResultCaseV1::Detached(inner) => Self::Detached(inner.into()),
            AgentHostCommandResultCaseV1::Started(inner) => Self::Started(inner.into()),
            AgentHostCommandResultCaseV1::Steered(inner) => Self::Steered(inner.into()),
            AgentHostCommandResultCaseV1::Interrupted(inner) => Self::Interrupted(inner.into()),
            AgentHostCommandResultCaseV1::InteractionResponded(inner) => {
                Self::InteractionResponded(inner.into())
            }
            AgentHostCommandResultCaseV1::Stopped(inner) => Self::Stopped(inner.into()),
            AgentHostCommandResultCaseV1::HostControl(inner) => Self::HostControl(inner.into()),
        }
    }
}

impl TryFrom<v1::CommandResult> for AgentHostCommandResultV1 {
    type Error = CoreError;

    fn try_from(value: v1::CommandResult) -> Result<Self, CoreError> {
        let v1::CommandResult { result } = value;
        Ok(Self {
            result: result.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostCommandResultV1> for v1::CommandResult {
    fn from(value: AgentHostCommandResultV1) -> Self {
        let AgentHostCommandResultV1 { result } = value;
        Self {
            result: result.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSessionListV1 {
    pub sessions: Vec<AgentHostSessionSummaryV1>,
}

impl TryFrom<v1::SessionList> for AgentHostSessionListV1 {
    type Error = CoreError;

    fn try_from(value: v1::SessionList) -> Result<Self, CoreError> {
        let v1::SessionList { sessions } = value;
        Ok(Self {
            sessions: messages_from(sessions)?,
        })
    }
}

impl From<AgentHostSessionListV1> for v1::SessionList {
    fn from(value: AgentHostSessionListV1) -> Self {
        let AgentHostSessionListV1 { sessions } = value;
        Self {
            sessions: sessions.into_iter().map(Into::into).collect(),
        }
    }
}

/// Returned atomically with the cursor the live stream starts at (design §5.5).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostAttachResultV1 {
    pub session_id: String,
    /// Current generation; every following `EventNotification` for this session carries it.
    pub generation: Vec<u8>,
    pub replay: AgentHostAttachReplayV1,
    /// True when a `SnapshotBegin`..`SnapshotEnd` stream follows this response.
    pub snapshot_follows: bool,
    /// Cursor the snapshot covers (0 when no snapshot follows).
    pub snapshot_through_cursor: u64,
    /// First `delivery_cursor` that will be pushed after this response (and after the snapshot).
    pub next_cursor: u64,
    pub summary: Option<AgentHostSessionSummaryV1>,
}

impl TryFrom<v1::AttachResult> for AgentHostAttachResultV1 {
    type Error = CoreError;

    fn try_from(value: v1::AttachResult) -> Result<Self, CoreError> {
        let v1::AttachResult {
            session_id,
            generation,
            replay,
            snapshot_follows,
            snapshot_through_cursor,
            next_cursor,
            summary,
        } = value;
        Ok(Self {
            session_id,
            generation,
            replay: enum_from_i32::<v1::AttachReplay, _>("AttachReplay", replay)?,
            snapshot_follows,
            snapshot_through_cursor,
            next_cursor,
            summary: summary.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostAttachResultV1> for v1::AttachResult {
    fn from(value: AgentHostAttachResultV1) -> Self {
        let AgentHostAttachResultV1 {
            session_id,
            generation,
            replay,
            snapshot_follows,
            snapshot_through_cursor,
            next_cursor,
            summary,
        } = value;
        Self {
            session_id,
            generation,
            replay: v1::AttachReplay::from(replay) as i32,
            snapshot_follows,
            snapshot_through_cursor,
            next_cursor,
            summary: summary.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostDetachedV1 {
    pub session_id: String,
}

impl TryFrom<v1::Detached> for AgentHostDetachedV1 {
    type Error = CoreError;

    fn try_from(value: v1::Detached) -> Result<Self, CoreError> {
        let v1::Detached { session_id } = value;
        Ok(Self { session_id })
    }
}

impl From<AgentHostDetachedV1> for v1::Detached {
    fn from(value: AgentHostDetachedV1) -> Self {
        let AgentHostDetachedV1 { session_id } = value;
        Self { session_id }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSessionStartedV1 {
    pub session_id: String,
    pub generation: Vec<u8>,
    pub next_cursor: u64,
    pub summary: Option<AgentHostSessionSummaryV1>,
}

impl TryFrom<v1::SessionStarted> for AgentHostSessionStartedV1 {
    type Error = CoreError;

    fn try_from(value: v1::SessionStarted) -> Result<Self, CoreError> {
        let v1::SessionStarted {
            session_id,
            generation,
            next_cursor,
            summary,
        } = value;
        Ok(Self {
            session_id,
            generation,
            next_cursor,
            summary: summary.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostSessionStartedV1> for v1::SessionStarted {
    fn from(value: AgentHostSessionStartedV1) -> Self {
        let AgentHostSessionStartedV1 {
            session_id,
            generation,
            next_cursor,
            summary,
        } = value;
        Self {
            session_id,
            generation,
            next_cursor,
            summary: summary.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSteeredV1 {
    pub session_id: String,
    pub message_id: String,
    /// Log cursor of the record that captured the message.
    pub recorded_cursor: u64,
}

impl TryFrom<v1::Steered> for AgentHostSteeredV1 {
    type Error = CoreError;

    fn try_from(value: v1::Steered) -> Result<Self, CoreError> {
        let v1::Steered {
            session_id,
            message_id,
            recorded_cursor,
        } = value;
        Ok(Self {
            session_id,
            message_id,
            recorded_cursor,
        })
    }
}

impl From<AgentHostSteeredV1> for v1::Steered {
    fn from(value: AgentHostSteeredV1) -> Self {
        let AgentHostSteeredV1 {
            session_id,
            message_id,
            recorded_cursor,
        } = value;
        Self {
            session_id,
            message_id,
            recorded_cursor,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostInterruptResultV1 {
    pub session_id: String,
    pub outcome: AgentHostInterruptOutcomeV1,
    pub detail: String,
}

impl TryFrom<v1::InterruptResult> for AgentHostInterruptResultV1 {
    type Error = CoreError;

    fn try_from(value: v1::InterruptResult) -> Result<Self, CoreError> {
        let v1::InterruptResult {
            session_id,
            outcome,
            detail,
        } = value;
        Ok(Self {
            session_id,
            outcome: enum_from_i32::<v1::InterruptOutcome, _>("InterruptOutcome", outcome)?,
            detail,
        })
    }
}

impl From<AgentHostInterruptResultV1> for v1::InterruptResult {
    fn from(value: AgentHostInterruptResultV1) -> Self {
        let AgentHostInterruptResultV1 {
            session_id,
            outcome,
            detail,
        } = value;
        Self {
            session_id,
            outcome: v1::InterruptOutcome::from(outcome) as i32,
            detail,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostInteractionRespondedV1 {
    pub session_id: String,
    pub interaction_id: String,
    pub disposition: AgentHostInteractionResponseDispositionV1,
}

impl TryFrom<v1::InteractionResponded> for AgentHostInteractionRespondedV1 {
    type Error = CoreError;

    fn try_from(value: v1::InteractionResponded) -> Result<Self, CoreError> {
        let v1::InteractionResponded {
            session_id,
            interaction_id,
            disposition,
        } = value;
        Ok(Self {
            session_id,
            interaction_id,
            disposition: enum_from_i32::<v1::InteractionResponseDisposition, _>(
                "InteractionResponseDisposition",
                disposition,
            )?,
        })
    }
}

impl From<AgentHostInteractionRespondedV1> for v1::InteractionResponded {
    fn from(value: AgentHostInteractionRespondedV1) -> Self {
        let AgentHostInteractionRespondedV1 {
            session_id,
            interaction_id,
            disposition,
        } = value;
        Self {
            session_id,
            interaction_id,
            disposition: v1::InteractionResponseDisposition::from(disposition) as i32,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostStoppedV1 {
    pub session_id: String,
    pub status: AgentHostSessionStatusV1,
}

impl TryFrom<v1::Stopped> for AgentHostStoppedV1 {
    type Error = CoreError;

    fn try_from(value: v1::Stopped) -> Result<Self, CoreError> {
        let v1::Stopped { session_id, status } = value;
        Ok(Self {
            session_id,
            status: enum_from_i32::<v1::SessionStatus, _>("SessionStatus", status)?,
        })
    }
}

impl From<AgentHostStoppedV1> for v1::Stopped {
    fn from(value: AgentHostStoppedV1) -> Self {
        let AgentHostStoppedV1 { session_id, status } = value;
        Self {
            session_id,
            status: v1::SessionStatus::from(status) as i32,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSessionCheckpointV1 {
    pub session_id: String,
    pub succeeded: bool,
    /// Cursor the written snapshot covers.
    pub through_cursor: u64,
    pub detail: String,
}

impl TryFrom<v1::SessionCheckpoint> for AgentHostSessionCheckpointV1 {
    type Error = CoreError;

    fn try_from(value: v1::SessionCheckpoint) -> Result<Self, CoreError> {
        let v1::SessionCheckpoint {
            session_id,
            succeeded,
            through_cursor,
            detail,
        } = value;
        Ok(Self {
            session_id,
            succeeded,
            through_cursor,
            detail,
        })
    }
}

impl From<AgentHostSessionCheckpointV1> for v1::SessionCheckpoint {
    fn from(value: AgentHostSessionCheckpointV1) -> Self {
        let AgentHostSessionCheckpointV1 {
            session_id,
            succeeded,
            through_cursor,
            detail,
        } = value;
        Self {
            session_id,
            succeeded,
            through_cursor,
            detail,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostPrepareUpdateResultV1 {
    pub all_checkpointed: bool,
    pub checkpoints: Vec<AgentHostSessionCheckpointV1>,
}

impl TryFrom<v1::PrepareUpdateResult> for AgentHostPrepareUpdateResultV1 {
    type Error = CoreError;

    fn try_from(value: v1::PrepareUpdateResult) -> Result<Self, CoreError> {
        let v1::PrepareUpdateResult {
            all_checkpointed,
            checkpoints,
        } = value;
        Ok(Self {
            all_checkpointed,
            checkpoints: messages_from(checkpoints)?,
        })
    }
}

impl From<AgentHostPrepareUpdateResultV1> for v1::PrepareUpdateResult {
    fn from(value: AgentHostPrepareUpdateResultV1) -> Self {
        let AgentHostPrepareUpdateResultV1 {
            all_checkpointed,
            checkpoints,
        } = value;
        Self {
            all_checkpointed,
            checkpoints: checkpoints.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostShutdownAcceptedV1 {
    /// RFC 3339 time by which the host will have exited.
    pub deadline_at: String,
}

impl TryFrom<v1::ShutdownAccepted> for AgentHostShutdownAcceptedV1 {
    type Error = CoreError;

    fn try_from(value: v1::ShutdownAccepted) -> Result<Self, CoreError> {
        let v1::ShutdownAccepted { deadline_at } = value;
        Ok(Self { deadline_at })
    }
}

impl From<AgentHostShutdownAcceptedV1> for v1::ShutdownAccepted {
    fn from(value: AgentHostShutdownAcceptedV1) -> Self {
        let AgentHostShutdownAcceptedV1 { deadline_at } = value;
        Self { deadline_at }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostHostControlResultV1 {
    pub result: Option<AgentHostHostControlResultCaseV1>,
}

/// `HostControlResult.result` (`oneof result`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostHostControlResultCaseV1 {
    PrepareUpdate(AgentHostPrepareUpdateResultV1),
    Shutdown(AgentHostShutdownAcceptedV1),
}

impl TryFrom<v1::host_control_result::Result> for AgentHostHostControlResultCaseV1 {
    type Error = CoreError;

    fn try_from(value: v1::host_control_result::Result) -> Result<Self, CoreError> {
        Ok(match value {
            v1::host_control_result::Result::PrepareUpdate(inner) => {
                Self::PrepareUpdate(inner.try_into()?)
            }
            v1::host_control_result::Result::Shutdown(inner) => Self::Shutdown(inner.try_into()?),
        })
    }
}

impl From<AgentHostHostControlResultCaseV1> for v1::host_control_result::Result {
    fn from(value: AgentHostHostControlResultCaseV1) -> Self {
        match value {
            AgentHostHostControlResultCaseV1::PrepareUpdate(inner) => {
                Self::PrepareUpdate(inner.into())
            }
            AgentHostHostControlResultCaseV1::Shutdown(inner) => Self::Shutdown(inner.into()),
        }
    }
}

impl TryFrom<v1::HostControlResult> for AgentHostHostControlResultV1 {
    type Error = CoreError;

    fn try_from(value: v1::HostControlResult) -> Result<Self, CoreError> {
        let v1::HostControlResult { result } = value;
        Ok(Self {
            result: result.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostHostControlResultV1> for v1::HostControlResult {
    fn from(value: AgentHostHostControlResultV1) -> Self {
        let AgentHostHostControlResultV1 { result } = value;
        Self {
            result: result.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostToolPreferenceV1 {
    pub tool_id: String,
    pub disposition: AgentHostToolDispositionV1,
}

impl TryFrom<v1::ToolPreference> for AgentHostToolPreferenceV1 {
    type Error = CoreError;

    fn try_from(value: v1::ToolPreference) -> Result<Self, CoreError> {
        let v1::ToolPreference {
            tool_id,
            disposition,
        } = value;
        Ok(Self {
            tool_id,
            disposition: enum_from_i32::<v1::ToolDisposition, _>("ToolDisposition", disposition)?,
        })
    }
}

impl From<AgentHostToolPreferenceV1> for v1::ToolPreference {
    fn from(value: AgentHostToolPreferenceV1) -> Self {
        let AgentHostToolPreferenceV1 {
            tool_id,
            disposition,
        } = value;
        Self {
            tool_id,
            disposition: v1::ToolDisposition::from(disposition) as i32,
        }
    }
}

/// Opaque provider-specific setting validated by the host's provider adapter (for example a Claude
/// permission mode). Kept as key/value so the wire contract does not change per provider.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostProviderSettingV1 {
    pub key: String,
    pub value: String,
}

impl TryFrom<v1::ProviderSetting> for AgentHostProviderSettingV1 {
    type Error = CoreError;

    fn try_from(value: v1::ProviderSetting) -> Result<Self, CoreError> {
        let v1::ProviderSetting { key, value } = value;
        Ok(Self { key, value })
    }
}

impl From<AgentHostProviderSettingV1> for v1::ProviderSetting {
    fn from(value: AgentHostProviderSettingV1) -> Self {
        let AgentHostProviderSettingV1 { key, value } = value;
        Self { key, value }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostPermissionPolicyV1 {
    pub approval_policy: AgentHostApprovalPolicyV1,
    pub tool_preferences: Vec<AgentHostToolPreferenceV1>,
    pub provider_settings: Vec<AgentHostProviderSettingV1>,
    /// 0 means the host default.
    pub interaction_timeout_seconds: u32,
}

impl TryFrom<v1::PermissionPolicy> for AgentHostPermissionPolicyV1 {
    type Error = CoreError;

    fn try_from(value: v1::PermissionPolicy) -> Result<Self, CoreError> {
        let v1::PermissionPolicy {
            approval_policy,
            tool_preferences,
            provider_settings,
            interaction_timeout_seconds,
        } = value;
        Ok(Self {
            approval_policy: enum_from_i32::<v1::ApprovalPolicy, _>(
                "ApprovalPolicy",
                approval_policy,
            )?,
            tool_preferences: messages_from(tool_preferences)?,
            provider_settings: messages_from(provider_settings)?,
            interaction_timeout_seconds,
        })
    }
}

impl From<AgentHostPermissionPolicyV1> for v1::PermissionPolicy {
    fn from(value: AgentHostPermissionPolicyV1) -> Self {
        let AgentHostPermissionPolicyV1 {
            approval_policy,
            tool_preferences,
            provider_settings,
            interaction_timeout_seconds,
        } = value;
        Self {
            approval_policy: v1::ApprovalPolicy::from(approval_policy) as i32,
            tool_preferences: tool_preferences.into_iter().map(Into::into).collect(),
            provider_settings: provider_settings.into_iter().map(Into::into).collect(),
            interaction_timeout_seconds,
        }
    }
}

/// Reference to a large object stored outside the frame (design §5.2 large-object rule).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostArtifactRefV1 {
    pub artifact_id: String,
    pub byte_length: u64,
    /// Lowercase hex SHA-256 of the artifact bytes.
    pub digest_sha256: String,
    pub media_type: String,
    pub display_name: String,
}

impl TryFrom<v1::ArtifactRef> for AgentHostArtifactRefV1 {
    type Error = CoreError;

    fn try_from(value: v1::ArtifactRef) -> Result<Self, CoreError> {
        let v1::ArtifactRef {
            artifact_id,
            byte_length,
            digest_sha256,
            media_type,
            display_name,
        } = value;
        Ok(Self {
            artifact_id,
            byte_length,
            digest_sha256,
            media_type,
            display_name,
        })
    }
}

impl From<AgentHostArtifactRefV1> for v1::ArtifactRef {
    fn from(value: AgentHostArtifactRefV1) -> Self {
        let AgentHostArtifactRefV1 {
            artifact_id,
            byte_length,
            digest_sha256,
            media_type,
            display_name,
        } = value;
        Self {
            artifact_id,
            byte_length,
            digest_sha256,
            media_type,
            display_name,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostUserMessageV1 {
    /// Caller-generated UUID; used for `Steered.message_id` and transcript correlation.
    pub message_id: String,
    pub text: String,
    pub attachments: Vec<AgentHostArtifactRefV1>,
    /// RFC 3339.
    pub created_at: String,
}

impl TryFrom<v1::UserMessage> for AgentHostUserMessageV1 {
    type Error = CoreError;

    fn try_from(value: v1::UserMessage) -> Result<Self, CoreError> {
        let v1::UserMessage {
            message_id,
            text,
            attachments,
            created_at,
        } = value;
        Ok(Self {
            message_id,
            text,
            attachments: messages_from(attachments)?,
            created_at,
        })
    }
}

impl From<AgentHostUserMessageV1> for v1::UserMessage {
    fn from(value: AgentHostUserMessageV1) -> Self {
        let AgentHostUserMessageV1 {
            message_id,
            text,
            attachments,
            created_at,
        } = value;
        Self {
            message_id,
            text,
            attachments: attachments.into_iter().map(Into::into).collect(),
            created_at,
        }
    }
}

/// Everything the host needs to start a session. Paths, provider commands, environment and
/// credentials are resolved by the host from the opaque identifiers below.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSessionSpecV1 {
    /// Caller-generated UUID.
    pub session_id: String,
    pub workspace_id: String,
    /// Optional execution-location binding; the host resolves it to a canonical worktree.
    pub worktree_id: String,
    pub session_name: String,
    /// Provider identifier owned by the host's provider registry (for example `claude`, `codex`, or
    /// an ACP provider id).
    pub provider_id: String,
    pub agent_id: String,
    pub agent_display_name: String,
    pub model_id: String,
    /// Reasoning effort vocabulary of the provider (for Claude-compatible runtimes:
    /// `max|xhigh|high|medium|low`).
    pub reasoning_effort: String,
    /// Set to fork from an existing session (`ForkedFrom` record); requires `CAPABILITY_FORK`.
    pub parent_session_id: String,
    /// Cursor in the parent to fork at; 0 means the parent's current end.
    pub parent_fork_cursor: u64,
    pub initial_message: Option<AgentHostUserMessageV1>,
    pub permission_policy: Option<AgentHostPermissionPolicyV1>,
    /// Debug builds only (design §11 row 4): opaque handle to a host-side credential envelope. Never
    /// plaintext; release hosts reject a non-empty value.
    pub credential_envelope_id: String,
    /// Opaque provider session identifier to resume instead of starting fresh.
    pub resume_provider_session_id: String,
}

impl TryFrom<v1::SessionSpec> for AgentHostSessionSpecV1 {
    type Error = CoreError;

    fn try_from(value: v1::SessionSpec) -> Result<Self, CoreError> {
        let v1::SessionSpec {
            session_id,
            workspace_id,
            worktree_id,
            session_name,
            provider_id,
            agent_id,
            agent_display_name,
            model_id,
            reasoning_effort,
            parent_session_id,
            parent_fork_cursor,
            initial_message,
            permission_policy,
            credential_envelope_id,
            resume_provider_session_id,
        } = value;
        Ok(Self {
            session_id,
            workspace_id,
            worktree_id,
            session_name,
            provider_id,
            agent_id,
            agent_display_name,
            model_id,
            reasoning_effort,
            parent_session_id,
            parent_fork_cursor,
            initial_message: initial_message.map(TryInto::try_into).transpose()?,
            permission_policy: permission_policy.map(TryInto::try_into).transpose()?,
            credential_envelope_id,
            resume_provider_session_id,
        })
    }
}

impl From<AgentHostSessionSpecV1> for v1::SessionSpec {
    fn from(value: AgentHostSessionSpecV1) -> Self {
        let AgentHostSessionSpecV1 {
            session_id,
            workspace_id,
            worktree_id,
            session_name,
            provider_id,
            agent_id,
            agent_display_name,
            model_id,
            reasoning_effort,
            parent_session_id,
            parent_fork_cursor,
            initial_message,
            permission_policy,
            credential_envelope_id,
            resume_provider_session_id,
        } = value;
        Self {
            session_id,
            workspace_id,
            worktree_id,
            session_name,
            provider_id,
            agent_id,
            agent_display_name,
            model_id,
            reasoning_effort,
            parent_session_id,
            parent_fork_cursor,
            initial_message: initial_message.map(Into::into),
            permission_policy: permission_policy.map(Into::into),
            credential_envelope_id,
            resume_provider_session_id,
        }
    }
}

/// Session metadata returned by `list_sessions`, `attach`, and `start`, and recorded on every
/// `SessionMetadataChanged` event. Mirrors the domain snapshot's provider-neutral fields; worktree
/// binding is referenced by id only.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSessionSummaryV1 {
    pub session_id: String,
    pub workspace_id: String,
    pub worktree_id: String,
    pub session_name: String,
    pub provider_id: String,
    pub agent_id: String,
    pub agent_display_name: String,
    pub model_id: String,
    pub reasoning_effort: String,
    pub status: AgentHostSessionStatusV1,
    pub status_text: String,
    pub latest_assistant_preview: String,
    /// Present while an interaction is pending.
    pub interaction: Option<AgentHostPendingInteractionV1>,
    pub transcript_item_count: u64,
    /// RFC 3339.
    pub created_at: String,
    /// RFC 3339.
    pub updated_at: String,
    pub parent_session_id: String,
    pub failure_reason: AgentHostFailureReasonV1,
    /// Opaque provider session identifier (resume handle).
    pub provider_session_id: String,
    /// Identifier of the run currently owning the session, empty when idle or terminal.
    pub active_run_id: String,
    pub attached_client_count: u32,
    /// Current log generation and end cursor, so listings can be compared without attaching.
    pub generation: Vec<u8>,
    pub last_cursor: u64,
}

impl TryFrom<v1::SessionSummary> for AgentHostSessionSummaryV1 {
    type Error = CoreError;

    fn try_from(value: v1::SessionSummary) -> Result<Self, CoreError> {
        let v1::SessionSummary {
            session_id,
            workspace_id,
            worktree_id,
            session_name,
            provider_id,
            agent_id,
            agent_display_name,
            model_id,
            reasoning_effort,
            status,
            status_text,
            latest_assistant_preview,
            interaction,
            transcript_item_count,
            created_at,
            updated_at,
            parent_session_id,
            failure_reason,
            provider_session_id,
            active_run_id,
            attached_client_count,
            generation,
            last_cursor,
        } = value;
        Ok(Self {
            session_id,
            workspace_id,
            worktree_id,
            session_name,
            provider_id,
            agent_id,
            agent_display_name,
            model_id,
            reasoning_effort,
            status: enum_from_i32::<v1::SessionStatus, _>("SessionStatus", status)?,
            status_text,
            latest_assistant_preview,
            interaction: interaction.map(TryInto::try_into).transpose()?,
            transcript_item_count,
            created_at,
            updated_at,
            parent_session_id,
            failure_reason: enum_from_i32::<v1::FailureReason, _>("FailureReason", failure_reason)?,
            provider_session_id,
            active_run_id,
            attached_client_count,
            generation,
            last_cursor,
        })
    }
}

impl From<AgentHostSessionSummaryV1> for v1::SessionSummary {
    fn from(value: AgentHostSessionSummaryV1) -> Self {
        let AgentHostSessionSummaryV1 {
            session_id,
            workspace_id,
            worktree_id,
            session_name,
            provider_id,
            agent_id,
            agent_display_name,
            model_id,
            reasoning_effort,
            status,
            status_text,
            latest_assistant_preview,
            interaction,
            transcript_item_count,
            created_at,
            updated_at,
            parent_session_id,
            failure_reason,
            provider_session_id,
            active_run_id,
            attached_client_count,
            generation,
            last_cursor,
        } = value;
        Self {
            session_id,
            workspace_id,
            worktree_id,
            session_name,
            provider_id,
            agent_id,
            agent_display_name,
            model_id,
            reasoning_effort,
            status: v1::SessionStatus::from(status) as i32,
            status_text,
            latest_assistant_preview,
            interaction: interaction.map(Into::into),
            transcript_item_count,
            created_at,
            updated_at,
            parent_session_id,
            failure_reason: v1::FailureReason::from(failure_reason) as i32,
            provider_session_id,
            active_run_id,
            attached_client_count,
            generation,
            last_cursor,
        }
    }
}

/// Live or replayed event for an attached session. `delivery_cursor` is the log record ordinal
/// (1-based, contiguous per generation); clients persist `(generation, delivery_cursor)` to resume.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostEventNotificationV1 {
    pub session_id: String,
    pub generation: Vec<u8>,
    pub delivery_cursor: u64,
    pub event: Option<AgentHostAgentSessionEventV1>,
}

impl TryFrom<v1::EventNotification> for AgentHostEventNotificationV1 {
    type Error = CoreError;

    fn try_from(value: v1::EventNotification) -> Result<Self, CoreError> {
        let v1::EventNotification {
            session_id,
            generation,
            delivery_cursor,
            event,
        } = value;
        Ok(Self {
            session_id,
            generation,
            delivery_cursor,
            event: event.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostEventNotificationV1> for v1::EventNotification {
    fn from(value: AgentHostEventNotificationV1) -> Self {
        let AgentHostEventNotificationV1 {
            session_id,
            generation,
            delivery_cursor,
            event,
        } = value;
        Self {
            session_id,
            generation,
            delivery_cursor,
            event: event.map(Into::into),
        }
    }
}

/// Snapshot stream header. The concatenated `SnapshotChunk.data` bytes form one encoded
/// `AgentSessionSnapshot` whose length and digest are given here.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSnapshotBeginV1 {
    pub session_id: String,
    pub generation: Vec<u8>,
    pub through_cursor: u64,
    pub byte_length: u64,
    /// Lowercase hex SHA-256 of the assembled snapshot bytes.
    pub digest_sha256: String,
    pub chunk_count: u32,
}

impl TryFrom<v1::SnapshotBegin> for AgentHostSnapshotBeginV1 {
    type Error = CoreError;

    fn try_from(value: v1::SnapshotBegin) -> Result<Self, CoreError> {
        let v1::SnapshotBegin {
            session_id,
            generation,
            through_cursor,
            byte_length,
            digest_sha256,
            chunk_count,
        } = value;
        Ok(Self {
            session_id,
            generation,
            through_cursor,
            byte_length,
            digest_sha256,
            chunk_count,
        })
    }
}

impl From<AgentHostSnapshotBeginV1> for v1::SnapshotBegin {
    fn from(value: AgentHostSnapshotBeginV1) -> Self {
        let AgentHostSnapshotBeginV1 {
            session_id,
            generation,
            through_cursor,
            byte_length,
            digest_sha256,
            chunk_count,
        } = value;
        Self {
            session_id,
            generation,
            through_cursor,
            byte_length,
            digest_sha256,
            chunk_count,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSnapshotChunkV1 {
    pub session_id: String,
    pub chunk_index: u32,
    pub offset: u64,
    /// At most 512 KiB.
    pub data: Vec<u8>,
}

impl TryFrom<v1::SnapshotChunk> for AgentHostSnapshotChunkV1 {
    type Error = CoreError;

    fn try_from(value: v1::SnapshotChunk) -> Result<Self, CoreError> {
        let v1::SnapshotChunk {
            session_id,
            chunk_index,
            offset,
            data,
        } = value;
        Ok(Self {
            session_id,
            chunk_index,
            offset,
            data,
        })
    }
}

impl From<AgentHostSnapshotChunkV1> for v1::SnapshotChunk {
    fn from(value: AgentHostSnapshotChunkV1) -> Self {
        let AgentHostSnapshotChunkV1 {
            session_id,
            chunk_index,
            offset,
            data,
        } = value;
        Self {
            session_id,
            chunk_index,
            offset,
            data,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSnapshotEndV1 {
    pub session_id: String,
    pub through_cursor: u64,
    /// `EventNotification.delivery_cursor` resumes here.
    pub next_cursor: u64,
}

impl TryFrom<v1::SnapshotEnd> for AgentHostSnapshotEndV1 {
    type Error = CoreError;

    fn try_from(value: v1::SnapshotEnd) -> Result<Self, CoreError> {
        let v1::SnapshotEnd {
            session_id,
            through_cursor,
            next_cursor,
        } = value;
        Ok(Self {
            session_id,
            through_cursor,
            next_cursor,
        })
    }
}

impl From<AgentHostSnapshotEndV1> for v1::SnapshotEnd {
    fn from(value: AgentHostSnapshotEndV1) -> Self {
        let AgentHostSnapshotEndV1 {
            session_id,
            through_cursor,
            next_cursor,
        } = value;
        Self {
            session_id,
            through_cursor,
            next_cursor,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostResnapshotRequiredV1 {
    pub session_id: String,
    pub generation: Vec<u8>,
    pub reason: AgentHostResnapshotReasonV1,
    /// Last cursor the host believes this client received.
    pub last_delivered_cursor: u64,
}

impl TryFrom<v1::ResnapshotRequired> for AgentHostResnapshotRequiredV1 {
    type Error = CoreError;

    fn try_from(value: v1::ResnapshotRequired) -> Result<Self, CoreError> {
        let v1::ResnapshotRequired {
            session_id,
            generation,
            reason,
            last_delivered_cursor,
        } = value;
        Ok(Self {
            session_id,
            generation,
            reason: enum_from_i32::<v1::ResnapshotReason, _>("ResnapshotReason", reason)?,
            last_delivered_cursor,
        })
    }
}

impl From<AgentHostResnapshotRequiredV1> for v1::ResnapshotRequired {
    fn from(value: AgentHostResnapshotRequiredV1) -> Self {
        let AgentHostResnapshotRequiredV1 {
            session_id,
            generation,
            reason,
            last_delivered_cursor,
        } = value;
        Self {
            session_id,
            generation,
            reason: v1::ResnapshotReason::from(reason) as i32,
            last_delivered_cursor,
        }
    }
}

/// One provider-neutral streaming chunk. Mirrors the provider stream result DTO; fields are
/// `optional` so "absent" survives the round trip.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostStreamResultV1 {
    /// Provider stream item type (`content`, `reasoning`, `tool_call`, `tool_result`,
    /// `final_content`, `usage`, ...); mirrors the stream result's `type`. Kept as a string because
    /// providers extend it.
    pub item_type: String,
    pub text: Option<String>,
    pub reasoning: Option<String>,
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    pub cost: Option<f64>,
    pub tool_name: Option<String>,
    pub tool_args: Option<String>,
    pub tool_output: Option<String>,
    pub tool_invocation_id: Option<String>,
    pub tool_result_json: Option<String>,
    pub tool_args_json: Option<String>,
    pub tool_is_error: Option<bool>,
    pub provider_session_id: Option<String>,
    pub stop_reason: Option<String>,
    pub model_context_window: Option<u64>,
    pub context_used_tokens: Option<u64>,
    pub content_message_id: Option<String>,
}

impl TryFrom<v1::StreamResult> for AgentHostStreamResultV1 {
    type Error = CoreError;

    fn try_from(value: v1::StreamResult) -> Result<Self, CoreError> {
        let v1::StreamResult {
            item_type,
            text,
            reasoning,
            prompt_tokens,
            completion_tokens,
            cost,
            tool_name,
            tool_args,
            tool_output,
            tool_invocation_id,
            tool_result_json,
            tool_args_json,
            tool_is_error,
            provider_session_id,
            stop_reason,
            model_context_window,
            context_used_tokens,
            content_message_id,
        } = value;
        Ok(Self {
            item_type,
            text,
            reasoning,
            prompt_tokens,
            completion_tokens,
            cost,
            tool_name,
            tool_args,
            tool_output,
            tool_invocation_id,
            tool_result_json,
            tool_args_json,
            tool_is_error,
            provider_session_id,
            stop_reason,
            model_context_window,
            context_used_tokens,
            content_message_id,
        })
    }
}

impl From<AgentHostStreamResultV1> for v1::StreamResult {
    fn from(value: AgentHostStreamResultV1) -> Self {
        let AgentHostStreamResultV1 {
            item_type,
            text,
            reasoning,
            prompt_tokens,
            completion_tokens,
            cost,
            tool_name,
            tool_args,
            tool_output,
            tool_invocation_id,
            tool_result_json,
            tool_args_json,
            tool_is_error,
            provider_session_id,
            stop_reason,
            model_context_window,
            context_used_tokens,
            content_message_id,
        } = value;
        Self {
            item_type,
            text,
            reasoning,
            prompt_tokens,
            completion_tokens,
            cost,
            tool_name,
            tool_args,
            tool_output,
            tool_invocation_id,
            tool_result_json,
            tool_args_json,
            tool_is_error,
            provider_session_id,
            stop_reason,
            model_context_window,
            context_used_tokens,
            content_message_id,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostKeyValueV1 {
    pub key: String,
    pub value: String,
}

impl TryFrom<v1::KeyValue> for AgentHostKeyValueV1 {
    type Error = CoreError;

    fn try_from(value: v1::KeyValue) -> Result<Self, CoreError> {
        let v1::KeyValue { key, value } = value;
        Ok(Self { key, value })
    }
}

impl From<AgentHostKeyValueV1> for v1::KeyValue {
    fn from(value: AgentHostKeyValueV1) -> Self {
        let AgentHostKeyValueV1 { key, value } = value;
        Self { key, value }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostRuntimeInitializeResponseV1 {
    pub commands: Vec<String>,
    pub agents: Vec<String>,
    pub output_style: String,
    pub available_output_styles: Vec<String>,
    pub account: String,
    pub pid: u32,
    pub models_json: String,
    pub fast_mode_state_json: String,
}

impl TryFrom<v1::RuntimeInitializeResponse> for AgentHostRuntimeInitializeResponseV1 {
    type Error = CoreError;

    fn try_from(value: v1::RuntimeInitializeResponse) -> Result<Self, CoreError> {
        let v1::RuntimeInitializeResponse {
            commands,
            agents,
            output_style,
            available_output_styles,
            account,
            pid,
            models_json,
            fast_mode_state_json,
        } = value;
        Ok(Self {
            commands,
            agents,
            output_style,
            available_output_styles,
            account,
            pid,
            models_json,
            fast_mode_state_json,
        })
    }
}

impl From<AgentHostRuntimeInitializeResponseV1> for v1::RuntimeInitializeResponse {
    fn from(value: AgentHostRuntimeInitializeResponseV1) -> Self {
        let AgentHostRuntimeInitializeResponseV1 {
            commands,
            agents,
            output_style,
            available_output_styles,
            account,
            pid,
            models_json,
            fast_mode_state_json,
        } = value;
        Self {
            commands,
            agents,
            output_style,
            available_output_styles,
            account,
            pid,
            models_json,
            fast_mode_state_json,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostRuntimeInitStatusV1 {
    /// Opaque provider session identifier.
    pub provider_session_id: String,
    pub tools: Vec<String>,
    pub mcp_server_statuses: Vec<AgentHostKeyValueV1>,
    pub initialize_response: Option<AgentHostRuntimeInitializeResponseV1>,
}

impl TryFrom<v1::RuntimeInitStatus> for AgentHostRuntimeInitStatusV1 {
    type Error = CoreError;

    fn try_from(value: v1::RuntimeInitStatus) -> Result<Self, CoreError> {
        let v1::RuntimeInitStatus {
            provider_session_id,
            tools,
            mcp_server_statuses,
            initialize_response,
        } = value;
        Ok(Self {
            provider_session_id,
            tools,
            mcp_server_statuses: messages_from(mcp_server_statuses)?,
            initialize_response: initialize_response.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostRuntimeInitStatusV1> for v1::RuntimeInitStatus {
    fn from(value: AgentHostRuntimeInitStatusV1) -> Self {
        let AgentHostRuntimeInitStatusV1 {
            provider_session_id,
            tools,
            mcp_server_statuses,
            initialize_response,
        } = value;
        Self {
            provider_session_id,
            tools,
            mcp_server_statuses: mcp_server_statuses.into_iter().map(Into::into).collect(),
            initialize_response: initialize_response.map(Into::into),
        }
    }
}

/// Mirrors the provider approval request DTO. `cwd` and `grant_root` are descriptive text shown to
/// the human deciding; receivers never resolve them.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostApprovalRequestV1 {
    pub approval_id: String,
    pub request_id: String,
    pub request_id_source: AgentHostApprovalRequestIdSourceV1,
    pub method: String,
    pub kind: AgentHostApprovalKindV1,
    pub thread_id: String,
    pub turn_id: String,
    pub item_id: String,
    pub reason: String,
    pub command: Vec<String>,
    pub cwd: String,
    pub grant_root: String,
    pub proposed_execpolicy_amendment_json: String,
    pub details: Vec<String>,
}

impl TryFrom<v1::ApprovalRequest> for AgentHostApprovalRequestV1 {
    type Error = CoreError;

    fn try_from(value: v1::ApprovalRequest) -> Result<Self, CoreError> {
        let v1::ApprovalRequest {
            approval_id,
            request_id,
            request_id_source,
            method,
            kind,
            thread_id,
            turn_id,
            item_id,
            reason,
            command,
            cwd,
            grant_root,
            proposed_execpolicy_amendment_json,
            details,
        } = value;
        Ok(Self {
            approval_id,
            request_id,
            request_id_source: enum_from_i32::<v1::ApprovalRequestIdSource, _>(
                "ApprovalRequestIdSource",
                request_id_source,
            )?,
            method,
            kind: enum_from_i32::<v1::ApprovalKind, _>("ApprovalKind", kind)?,
            thread_id,
            turn_id,
            item_id,
            reason,
            command,
            cwd,
            grant_root,
            proposed_execpolicy_amendment_json,
            details,
        })
    }
}

impl From<AgentHostApprovalRequestV1> for v1::ApprovalRequest {
    fn from(value: AgentHostApprovalRequestV1) -> Self {
        let AgentHostApprovalRequestV1 {
            approval_id,
            request_id,
            request_id_source,
            method,
            kind,
            thread_id,
            turn_id,
            item_id,
            reason,
            command,
            cwd,
            grant_root,
            proposed_execpolicy_amendment_json,
            details,
        } = value;
        Self {
            approval_id,
            request_id,
            request_id_source: v1::ApprovalRequestIdSource::from(request_id_source) as i32,
            method,
            kind: v1::ApprovalKind::from(kind) as i32,
            thread_id,
            turn_id,
            item_id,
            reason,
            command,
            cwd,
            grant_root,
            proposed_execpolicy_amendment_json,
            details,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostApprovalCancelledV1 {
    pub approval_id: String,
    pub reason: String,
}

impl TryFrom<v1::ApprovalCancelled> for AgentHostApprovalCancelledV1 {
    type Error = CoreError;

    fn try_from(value: v1::ApprovalCancelled) -> Result<Self, CoreError> {
        let v1::ApprovalCancelled {
            approval_id,
            reason,
        } = value;
        Ok(Self {
            approval_id,
            reason,
        })
    }
}

impl From<AgentHostApprovalCancelledV1> for v1::ApprovalCancelled {
    fn from(value: AgentHostApprovalCancelledV1) -> Self {
        let AgentHostApprovalCancelledV1 {
            approval_id,
            reason,
        } = value;
        Self {
            approval_id,
            reason,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostTurnCompletedV1 {
    pub turn_id: String,
    pub stop_reason: String,
}

impl TryFrom<v1::TurnCompleted> for AgentHostTurnCompletedV1 {
    type Error = CoreError;

    fn try_from(value: v1::TurnCompleted) -> Result<Self, CoreError> {
        let v1::TurnCompleted {
            turn_id,
            stop_reason,
        } = value;
        Ok(Self {
            turn_id,
            stop_reason,
        })
    }
}

impl From<AgentHostTurnCompletedV1> for v1::TurnCompleted {
    fn from(value: AgentHostTurnCompletedV1) -> Self {
        let AgentHostTurnCompletedV1 {
            turn_id,
            stop_reason,
        } = value;
        Self {
            turn_id,
            stop_reason,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostRuntimeErrorV1 {
    pub code: String,
    pub message: String,
    pub recoverable: bool,
}

impl TryFrom<v1::RuntimeError> for AgentHostRuntimeErrorV1 {
    type Error = CoreError;

    fn try_from(value: v1::RuntimeError) -> Result<Self, CoreError> {
        let v1::RuntimeError {
            code,
            message,
            recoverable,
        } = value;
        Ok(Self {
            code,
            message,
            recoverable,
        })
    }
}

impl From<AgentHostRuntimeErrorV1> for v1::RuntimeError {
    fn from(value: AgentHostRuntimeErrorV1) -> Self {
        let AgentHostRuntimeErrorV1 {
            code,
            message,
            recoverable,
        } = value;
        Self {
            code,
            message,
            recoverable,
        }
    }
}

/// Mirrors the native runtime event family (stream / runtimeInit / approvalRequest /
/// approvalCancelled / turnCompleted / error).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostRuntimeEventV1 {
    pub run_id: String,
    pub turn_id: String,
    pub kind: Option<AgentHostRuntimeEventKindV1>,
}

/// `RuntimeEvent.kind` (`oneof kind`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostRuntimeEventKindV1 {
    Stream(AgentHostStreamResultV1),
    RuntimeInit(AgentHostRuntimeInitStatusV1),
    ApprovalRequest(AgentHostApprovalRequestV1),
    ApprovalCancelled(AgentHostApprovalCancelledV1),
    TurnCompleted(AgentHostTurnCompletedV1),
    Error(AgentHostRuntimeErrorV1),
}

impl TryFrom<v1::runtime_event::Kind> for AgentHostRuntimeEventKindV1 {
    type Error = CoreError;

    fn try_from(value: v1::runtime_event::Kind) -> Result<Self, CoreError> {
        Ok(match value {
            v1::runtime_event::Kind::Stream(inner) => Self::Stream(inner.try_into()?),
            v1::runtime_event::Kind::RuntimeInit(inner) => Self::RuntimeInit(inner.try_into()?),
            v1::runtime_event::Kind::ApprovalRequest(inner) => {
                Self::ApprovalRequest(inner.try_into()?)
            }
            v1::runtime_event::Kind::ApprovalCancelled(inner) => {
                Self::ApprovalCancelled(inner.try_into()?)
            }
            v1::runtime_event::Kind::TurnCompleted(inner) => Self::TurnCompleted(inner.try_into()?),
            v1::runtime_event::Kind::Error(inner) => Self::Error(inner.try_into()?),
        })
    }
}

impl From<AgentHostRuntimeEventKindV1> for v1::runtime_event::Kind {
    fn from(value: AgentHostRuntimeEventKindV1) -> Self {
        match value {
            AgentHostRuntimeEventKindV1::Stream(inner) => Self::Stream(inner.into()),
            AgentHostRuntimeEventKindV1::RuntimeInit(inner) => Self::RuntimeInit(inner.into()),
            AgentHostRuntimeEventKindV1::ApprovalRequest(inner) => {
                Self::ApprovalRequest(inner.into())
            }
            AgentHostRuntimeEventKindV1::ApprovalCancelled(inner) => {
                Self::ApprovalCancelled(inner.into())
            }
            AgentHostRuntimeEventKindV1::TurnCompleted(inner) => Self::TurnCompleted(inner.into()),
            AgentHostRuntimeEventKindV1::Error(inner) => Self::Error(inner.into()),
        }
    }
}

impl TryFrom<v1::RuntimeEvent> for AgentHostRuntimeEventV1 {
    type Error = CoreError;

    fn try_from(value: v1::RuntimeEvent) -> Result<Self, CoreError> {
        let v1::RuntimeEvent {
            run_id,
            turn_id,
            kind,
        } = value;
        Ok(Self {
            run_id,
            turn_id,
            kind: kind.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostRuntimeEventV1> for v1::RuntimeEvent {
    fn from(value: AgentHostRuntimeEventV1) -> Self {
        let AgentHostRuntimeEventV1 {
            run_id,
            turn_id,
            kind,
        } = value;
        Self {
            run_id,
            turn_id,
            kind: kind.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostTurnEpochV1 {
    pub turn_id: String,
    pub epoch: u64,
    pub transition: AgentHostEpochTransitionKindV1,
}

impl TryFrom<v1::TurnEpoch> for AgentHostTurnEpochV1 {
    type Error = CoreError;

    fn try_from(value: v1::TurnEpoch) -> Result<Self, CoreError> {
        let v1::TurnEpoch {
            turn_id,
            epoch,
            transition,
        } = value;
        Ok(Self {
            turn_id,
            epoch,
            transition: enum_from_i32::<v1::EpochTransitionKind, _>(
                "EpochTransitionKind",
                transition,
            )?,
        })
    }
}

impl From<AgentHostTurnEpochV1> for v1::TurnEpoch {
    fn from(value: AgentHostTurnEpochV1) -> Self {
        let AgentHostTurnEpochV1 {
            turn_id,
            epoch,
            transition,
        } = value;
        Self {
            turn_id,
            epoch,
            transition: v1::EpochTransitionKind::from(transition) as i32,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostTerminalOutcomeV1 {
    pub kind: AgentHostTerminalOutcomeKindV1,
    pub assistant_text: Option<String>,
    pub failure_reason: AgentHostFailureReasonV1,
}

impl TryFrom<v1::TerminalOutcome> for AgentHostTerminalOutcomeV1 {
    type Error = CoreError;

    fn try_from(value: v1::TerminalOutcome) -> Result<Self, CoreError> {
        let v1::TerminalOutcome {
            kind,
            assistant_text,
            failure_reason,
        } = value;
        Ok(Self {
            kind: enum_from_i32::<v1::TerminalOutcomeKind, _>("TerminalOutcomeKind", kind)?,
            assistant_text,
            failure_reason: enum_from_i32::<v1::FailureReason, _>("FailureReason", failure_reason)?,
        })
    }
}

impl From<AgentHostTerminalOutcomeV1> for v1::TerminalOutcome {
    fn from(value: AgentHostTerminalOutcomeV1) -> Self {
        let AgentHostTerminalOutcomeV1 {
            kind,
            assistant_text,
            failure_reason,
        } = value;
        Self {
            kind: v1::TerminalOutcomeKind::from(kind) as i32,
            assistant_text,
            failure_reason: v1::FailureReason::from(failure_reason) as i32,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostTerminationSignalV1 {
    pub kind: AgentHostTerminationSignalKindV1,
    pub assistant_text: Option<String>,
    pub failure_reason: AgentHostFailureReasonV1,
}

impl TryFrom<v1::TerminationSignal> for AgentHostTerminationSignalV1 {
    type Error = CoreError;

    fn try_from(value: v1::TerminationSignal) -> Result<Self, CoreError> {
        let v1::TerminationSignal {
            kind,
            assistant_text,
            failure_reason,
        } = value;
        Ok(Self {
            kind: enum_from_i32::<v1::TerminationSignalKind, _>("TerminationSignalKind", kind)?,
            assistant_text,
            failure_reason: enum_from_i32::<v1::FailureReason, _>("FailureReason", failure_reason)?,
        })
    }
}

impl From<AgentHostTerminationSignalV1> for v1::TerminationSignal {
    fn from(value: AgentHostTerminationSignalV1) -> Self {
        let AgentHostTerminationSignalV1 {
            kind,
            assistant_text,
            failure_reason,
        } = value;
        Self {
            kind: v1::TerminationSignalKind::from(kind) as i32,
            assistant_text,
            failure_reason: v1::FailureReason::from(failure_reason) as i32,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostRunStartedV1 {
    pub attempt_id: String,
    pub message: Option<AgentHostUserMessageV1>,
}

impl TryFrom<v1::RunStarted> for AgentHostRunStartedV1 {
    type Error = CoreError;

    fn try_from(value: v1::RunStarted) -> Result<Self, CoreError> {
        let v1::RunStarted {
            attempt_id,
            message,
        } = value;
        Ok(Self {
            attempt_id,
            message: message.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostRunStartedV1> for v1::RunStarted {
    fn from(value: AgentHostRunStartedV1) -> Self {
        let AgentHostRunStartedV1 {
            attempt_id,
            message,
        } = value;
        Self {
            attempt_id,
            message: message.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostRunStageChangedV1 {
    pub stage: AgentHostLifecycleStageV1,
    pub retry_intent: AgentHostRetryIntentV1,
}

impl TryFrom<v1::RunStageChanged> for AgentHostRunStageChangedV1 {
    type Error = CoreError;

    fn try_from(value: v1::RunStageChanged) -> Result<Self, CoreError> {
        let v1::RunStageChanged {
            stage,
            retry_intent,
        } = value;
        Ok(Self {
            stage: enum_from_i32::<v1::LifecycleStage, _>("LifecycleStage", stage)?,
            retry_intent: enum_from_i32::<v1::RetryIntent, _>("RetryIntent", retry_intent)?,
        })
    }
}

impl From<AgentHostRunStageChangedV1> for v1::RunStageChanged {
    fn from(value: AgentHostRunStageChangedV1) -> Self {
        let AgentHostRunStageChangedV1 {
            stage,
            retry_intent,
        } = value;
        Self {
            stage: v1::LifecycleStage::from(stage) as i32,
            retry_intent: v1::RetryIntent::from(retry_intent) as i32,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostRunTerminatedV1 {
    pub outcome: Option<AgentHostTerminalOutcomeV1>,
    pub signal: Option<AgentHostTerminationSignalV1>,
}

impl TryFrom<v1::RunTerminated> for AgentHostRunTerminatedV1 {
    type Error = CoreError;

    fn try_from(value: v1::RunTerminated) -> Result<Self, CoreError> {
        let v1::RunTerminated { outcome, signal } = value;
        Ok(Self {
            outcome: outcome.map(TryInto::try_into).transpose()?,
            signal: signal.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostRunTerminatedV1> for v1::RunTerminated {
    fn from(value: AgentHostRunTerminatedV1) -> Self {
        let AgentHostRunTerminatedV1 { outcome, signal } = value;
        Self {
            outcome: outcome.map(Into::into),
            signal: signal.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostRunLifecycleEventV1 {
    pub run_id: String,
    pub epoch: Option<AgentHostTurnEpochV1>,
    pub kind: Option<AgentHostRunLifecycleEventKindV1>,
}

/// `RunLifecycleEvent.kind` (`oneof kind`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostRunLifecycleEventKindV1 {
    Started(AgentHostRunStartedV1),
    StageChanged(AgentHostRunStageChangedV1),
    Terminated(AgentHostRunTerminatedV1),
}

impl TryFrom<v1::run_lifecycle_event::Kind> for AgentHostRunLifecycleEventKindV1 {
    type Error = CoreError;

    fn try_from(value: v1::run_lifecycle_event::Kind) -> Result<Self, CoreError> {
        Ok(match value {
            v1::run_lifecycle_event::Kind::Started(inner) => Self::Started(inner.try_into()?),
            v1::run_lifecycle_event::Kind::StageChanged(inner) => {
                Self::StageChanged(inner.try_into()?)
            }
            v1::run_lifecycle_event::Kind::Terminated(inner) => Self::Terminated(inner.try_into()?),
        })
    }
}

impl From<AgentHostRunLifecycleEventKindV1> for v1::run_lifecycle_event::Kind {
    fn from(value: AgentHostRunLifecycleEventKindV1) -> Self {
        match value {
            AgentHostRunLifecycleEventKindV1::Started(inner) => Self::Started(inner.into()),
            AgentHostRunLifecycleEventKindV1::StageChanged(inner) => {
                Self::StageChanged(inner.into())
            }
            AgentHostRunLifecycleEventKindV1::Terminated(inner) => Self::Terminated(inner.into()),
        }
    }
}

impl TryFrom<v1::RunLifecycleEvent> for AgentHostRunLifecycleEventV1 {
    type Error = CoreError;

    fn try_from(value: v1::RunLifecycleEvent) -> Result<Self, CoreError> {
        let v1::RunLifecycleEvent {
            run_id,
            epoch,
            kind,
        } = value;
        Ok(Self {
            run_id,
            epoch: epoch.map(TryInto::try_into).transpose()?,
            kind: kind.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostRunLifecycleEventV1> for v1::RunLifecycleEvent {
    fn from(value: AgentHostRunLifecycleEventV1) -> Self {
        let AgentHostRunLifecycleEventV1 {
            run_id,
            epoch,
            kind,
        } = value;
        Self {
            run_id,
            epoch: epoch.map(Into::into),
            kind: kind.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostInteractionOptionV1 {
    pub option_id: String,
    pub label: String,
    pub description: String,
    pub preferred: bool,
}

impl TryFrom<v1::InteractionOption> for AgentHostInteractionOptionV1 {
    type Error = CoreError;

    fn try_from(value: v1::InteractionOption) -> Result<Self, CoreError> {
        let v1::InteractionOption {
            option_id,
            label,
            description,
            preferred,
        } = value;
        Ok(Self {
            option_id,
            label,
            description,
            preferred,
        })
    }
}

impl From<AgentHostInteractionOptionV1> for v1::InteractionOption {
    fn from(value: AgentHostInteractionOptionV1) -> Self {
        let AgentHostInteractionOptionV1 {
            option_id,
            label,
            description,
            preferred,
        } = value;
        Self {
            option_id,
            label,
            description,
            preferred,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostInteractionFieldV1 {
    pub field_id: String,
    pub label: String,
    pub placeholder: String,
    pub required: bool,
    pub secret: bool,
    pub options: Vec<AgentHostInteractionOptionV1>,
    pub allows_multiple: bool,
}

impl TryFrom<v1::InteractionField> for AgentHostInteractionFieldV1 {
    type Error = CoreError;

    fn try_from(value: v1::InteractionField) -> Result<Self, CoreError> {
        let v1::InteractionField {
            field_id,
            label,
            placeholder,
            required,
            secret,
            options,
            allows_multiple,
        } = value;
        Ok(Self {
            field_id,
            label,
            placeholder,
            required,
            secret,
            options: messages_from(options)?,
            allows_multiple,
        })
    }
}

impl From<AgentHostInteractionFieldV1> for v1::InteractionField {
    fn from(value: AgentHostInteractionFieldV1) -> Self {
        let AgentHostInteractionFieldV1 {
            field_id,
            label,
            placeholder,
            required,
            secret,
            options,
            allows_multiple,
        } = value;
        Self {
            field_id,
            label,
            placeholder,
            required,
            secret,
            options: options.into_iter().map(Into::into).collect(),
            allows_multiple,
        }
    }
}

/// Interaction awaiting an answer. `interaction_generation` is the host-internal generation that a
/// `RespondInteraction` must echo; it changes when the same interaction is re-issued.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostPendingInteractionV1 {
    pub interaction_id: String,
    pub interaction_generation: Vec<u8>,
    pub kind: AgentHostInteractionKindV1,
    pub response_type: AgentHostInteractionResponseTypeV1,
    pub title: String,
    pub prompt: String,
    pub context: String,
    pub allows_multiple: bool,
    pub options: Vec<AgentHostInteractionOptionV1>,
    pub fields: Vec<AgentHostInteractionFieldV1>,
    pub details: Vec<String>,
    /// Populated for approval interactions.
    pub approval: Option<AgentHostApprovalRequestV1>,
    /// RFC 3339.
    pub requested_at: String,
    /// 0 means no timeout.
    pub timeout_seconds: u32,
    /// Run and turn that raised it.
    pub run_id: String,
    pub turn_id: String,
}

impl TryFrom<v1::PendingInteraction> for AgentHostPendingInteractionV1 {
    type Error = CoreError;

    fn try_from(value: v1::PendingInteraction) -> Result<Self, CoreError> {
        let v1::PendingInteraction {
            interaction_id,
            interaction_generation,
            kind,
            response_type,
            title,
            prompt,
            context,
            allows_multiple,
            options,
            fields,
            details,
            approval,
            requested_at,
            timeout_seconds,
            run_id,
            turn_id,
        } = value;
        Ok(Self {
            interaction_id,
            interaction_generation,
            kind: enum_from_i32::<v1::InteractionKind, _>("InteractionKind", kind)?,
            response_type: enum_from_i32::<v1::InteractionResponseType, _>(
                "InteractionResponseType",
                response_type,
            )?,
            title,
            prompt,
            context,
            allows_multiple,
            options: messages_from(options)?,
            fields: messages_from(fields)?,
            details,
            approval: approval.map(TryInto::try_into).transpose()?,
            requested_at,
            timeout_seconds,
            run_id,
            turn_id,
        })
    }
}

impl From<AgentHostPendingInteractionV1> for v1::PendingInteraction {
    fn from(value: AgentHostPendingInteractionV1) -> Self {
        let AgentHostPendingInteractionV1 {
            interaction_id,
            interaction_generation,
            kind,
            response_type,
            title,
            prompt,
            context,
            allows_multiple,
            options,
            fields,
            details,
            approval,
            requested_at,
            timeout_seconds,
            run_id,
            turn_id,
        } = value;
        Self {
            interaction_id,
            interaction_generation,
            kind: v1::InteractionKind::from(kind) as i32,
            response_type: v1::InteractionResponseType::from(response_type) as i32,
            title,
            prompt,
            context,
            allows_multiple,
            options: options.into_iter().map(Into::into).collect(),
            fields: fields.into_iter().map(Into::into).collect(),
            details,
            approval: approval.map(Into::into),
            requested_at,
            timeout_seconds,
            run_id,
            turn_id,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostApprovalDecisionV1 {
    pub kind: AgentHostApprovalDecisionKindV1,
    /// Set for `ACCEPT_WITH_EXECPOLICY_AMENDMENT`.
    pub execpolicy_amendment_json: String,
}

impl TryFrom<v1::ApprovalDecision> for AgentHostApprovalDecisionV1 {
    type Error = CoreError;

    fn try_from(value: v1::ApprovalDecision) -> Result<Self, CoreError> {
        let v1::ApprovalDecision {
            kind,
            execpolicy_amendment_json,
        } = value;
        Ok(Self {
            kind: enum_from_i32::<v1::ApprovalDecisionKind, _>("ApprovalDecisionKind", kind)?,
            execpolicy_amendment_json,
        })
    }
}

impl From<AgentHostApprovalDecisionV1> for v1::ApprovalDecision {
    fn from(value: AgentHostApprovalDecisionV1) -> Self {
        let AgentHostApprovalDecisionV1 {
            kind,
            execpolicy_amendment_json,
        } = value;
        Self {
            kind: v1::ApprovalDecisionKind::from(kind) as i32,
            execpolicy_amendment_json,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostFieldAnswerV1 {
    pub field_id: String,
    pub values: Vec<String>,
    pub skipped: bool,
}

impl TryFrom<v1::FieldAnswer> for AgentHostFieldAnswerV1 {
    type Error = CoreError;

    fn try_from(value: v1::FieldAnswer) -> Result<Self, CoreError> {
        let v1::FieldAnswer {
            field_id,
            values,
            skipped,
        } = value;
        Ok(Self {
            field_id,
            values,
            skipped,
        })
    }
}

impl From<AgentHostFieldAnswerV1> for v1::FieldAnswer {
    fn from(value: AgentHostFieldAnswerV1) -> Self {
        let AgentHostFieldAnswerV1 {
            field_id,
            values,
            skipped,
        } = value;
        Self {
            field_id,
            values,
            skipped,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostTextAnswerV1 {
    pub text: String,
}

impl TryFrom<v1::TextAnswer> for AgentHostTextAnswerV1 {
    type Error = CoreError;

    fn try_from(value: v1::TextAnswer) -> Result<Self, CoreError> {
        let v1::TextAnswer { text } = value;
        Ok(Self { text })
    }
}

impl From<AgentHostTextAnswerV1> for v1::TextAnswer {
    fn from(value: AgentHostTextAnswerV1) -> Self {
        let AgentHostTextAnswerV1 { text } = value;
        Self { text }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostChoiceAnswerV1 {
    pub selected_option_ids: Vec<String>,
    pub custom_response: String,
}

impl TryFrom<v1::ChoiceAnswer> for AgentHostChoiceAnswerV1 {
    type Error = CoreError;

    fn try_from(value: v1::ChoiceAnswer) -> Result<Self, CoreError> {
        let v1::ChoiceAnswer {
            selected_option_ids,
            custom_response,
        } = value;
        Ok(Self {
            selected_option_ids,
            custom_response,
        })
    }
}

impl From<AgentHostChoiceAnswerV1> for v1::ChoiceAnswer {
    fn from(value: AgentHostChoiceAnswerV1) -> Self {
        let AgentHostChoiceAnswerV1 {
            selected_option_ids,
            custom_response,
        } = value;
        Self {
            selected_option_ids,
            custom_response,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostStructuredAnswerV1 {
    pub answers: Vec<AgentHostFieldAnswerV1>,
}

impl TryFrom<v1::StructuredAnswer> for AgentHostStructuredAnswerV1 {
    type Error = CoreError;

    fn try_from(value: v1::StructuredAnswer) -> Result<Self, CoreError> {
        let v1::StructuredAnswer { answers } = value;
        Ok(Self {
            answers: messages_from(answers)?,
        })
    }
}

impl From<AgentHostStructuredAnswerV1> for v1::StructuredAnswer {
    fn from(value: AgentHostStructuredAnswerV1) -> Self {
        let AgentHostStructuredAnswerV1 { answers } = value;
        Self {
            answers: answers.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostElicitationAnswerV1 {
    pub action: AgentHostElicitationActionV1,
    pub content_json: String,
    pub meta_json: String,
}

impl TryFrom<v1::ElicitationAnswer> for AgentHostElicitationAnswerV1 {
    type Error = CoreError;

    fn try_from(value: v1::ElicitationAnswer) -> Result<Self, CoreError> {
        let v1::ElicitationAnswer {
            action,
            content_json,
            meta_json,
        } = value;
        Ok(Self {
            action: enum_from_i32::<v1::ElicitationAction, _>("ElicitationAction", action)?,
            content_json,
            meta_json,
        })
    }
}

impl From<AgentHostElicitationAnswerV1> for v1::ElicitationAnswer {
    fn from(value: AgentHostElicitationAnswerV1) -> Self {
        let AgentHostElicitationAnswerV1 {
            action,
            content_json,
            meta_json,
        } = value;
        Self {
            action: v1::ElicitationAction::from(action) as i32,
            content_json,
            meta_json,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostInteractionAnswerV1 {
    /// True when the client declined to answer (the prompt was dismissed or timed out client-side).
    pub skipped: bool,
    pub answer: Option<AgentHostInteractionAnswerAnswerV1>,
}

/// `InteractionAnswer.answer` (`oneof answer`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostInteractionAnswerAnswerV1 {
    Approval(AgentHostApprovalDecisionV1),
    Text(AgentHostTextAnswerV1),
    Choice(AgentHostChoiceAnswerV1),
    Structured(AgentHostStructuredAnswerV1),
    Elicitation(AgentHostElicitationAnswerV1),
}

impl TryFrom<v1::interaction_answer::Answer> for AgentHostInteractionAnswerAnswerV1 {
    type Error = CoreError;

    fn try_from(value: v1::interaction_answer::Answer) -> Result<Self, CoreError> {
        Ok(match value {
            v1::interaction_answer::Answer::Approval(inner) => Self::Approval(inner.try_into()?),
            v1::interaction_answer::Answer::Text(inner) => Self::Text(inner.try_into()?),
            v1::interaction_answer::Answer::Choice(inner) => Self::Choice(inner.try_into()?),
            v1::interaction_answer::Answer::Structured(inner) => {
                Self::Structured(inner.try_into()?)
            }
            v1::interaction_answer::Answer::Elicitation(inner) => {
                Self::Elicitation(inner.try_into()?)
            }
        })
    }
}

impl From<AgentHostInteractionAnswerAnswerV1> for v1::interaction_answer::Answer {
    fn from(value: AgentHostInteractionAnswerAnswerV1) -> Self {
        match value {
            AgentHostInteractionAnswerAnswerV1::Approval(inner) => Self::Approval(inner.into()),
            AgentHostInteractionAnswerAnswerV1::Text(inner) => Self::Text(inner.into()),
            AgentHostInteractionAnswerAnswerV1::Choice(inner) => Self::Choice(inner.into()),
            AgentHostInteractionAnswerAnswerV1::Structured(inner) => Self::Structured(inner.into()),
            AgentHostInteractionAnswerAnswerV1::Elicitation(inner) => {
                Self::Elicitation(inner.into())
            }
        }
    }
}

impl TryFrom<v1::InteractionAnswer> for AgentHostInteractionAnswerV1 {
    type Error = CoreError;

    fn try_from(value: v1::InteractionAnswer) -> Result<Self, CoreError> {
        let v1::InteractionAnswer { skipped, answer } = value;
        Ok(Self {
            skipped,
            answer: answer.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostInteractionAnswerV1> for v1::InteractionAnswer {
    fn from(value: AgentHostInteractionAnswerV1) -> Self {
        let AgentHostInteractionAnswerV1 { skipped, answer } = value;
        Self {
            skipped,
            answer: answer.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostInteractionRequestedV1 {
    pub interaction: Option<AgentHostPendingInteractionV1>,
}

impl TryFrom<v1::InteractionRequested> for AgentHostInteractionRequestedV1 {
    type Error = CoreError;

    fn try_from(value: v1::InteractionRequested) -> Result<Self, CoreError> {
        let v1::InteractionRequested { interaction } = value;
        Ok(Self {
            interaction: interaction.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostInteractionRequestedV1> for v1::InteractionRequested {
    fn from(value: AgentHostInteractionRequestedV1) -> Self {
        let AgentHostInteractionRequestedV1 { interaction } = value;
        Self {
            interaction: interaction.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostInteractionSettledV1 {
    pub interaction_id: String,
    pub interaction_generation: Vec<u8>,
    pub settlement: AgentHostInteractionSettlementV1,
    /// The winning answer when `ANSWERED` or `AUTO_RESOLVED_BY_POLICY`.
    pub answer: Option<AgentHostInteractionAnswerV1>,
    /// `operation_id` of the winning `RespondInteraction`, empty otherwise.
    pub operation_id: String,
}

impl TryFrom<v1::InteractionSettled> for AgentHostInteractionSettledV1 {
    type Error = CoreError;

    fn try_from(value: v1::InteractionSettled) -> Result<Self, CoreError> {
        let v1::InteractionSettled {
            interaction_id,
            interaction_generation,
            settlement,
            answer,
            operation_id,
        } = value;
        Ok(Self {
            interaction_id,
            interaction_generation,
            settlement: enum_from_i32::<v1::InteractionSettlement, _>(
                "InteractionSettlement",
                settlement,
            )?,
            answer: answer.map(TryInto::try_into).transpose()?,
            operation_id,
        })
    }
}

impl From<AgentHostInteractionSettledV1> for v1::InteractionSettled {
    fn from(value: AgentHostInteractionSettledV1) -> Self {
        let AgentHostInteractionSettledV1 {
            interaction_id,
            interaction_generation,
            settlement,
            answer,
            operation_id,
        } = value;
        Self {
            interaction_id,
            interaction_generation,
            settlement: v1::InteractionSettlement::from(settlement) as i32,
            answer: answer.map(Into::into),
            operation_id,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostInteractionEventV1 {
    pub kind: Option<AgentHostInteractionEventKindV1>,
}

/// `InteractionEvent.kind` (`oneof kind`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostInteractionEventKindV1 {
    Requested(AgentHostInteractionRequestedV1),
    Settled(AgentHostInteractionSettledV1),
}

impl TryFrom<v1::interaction_event::Kind> for AgentHostInteractionEventKindV1 {
    type Error = CoreError;

    fn try_from(value: v1::interaction_event::Kind) -> Result<Self, CoreError> {
        Ok(match value {
            v1::interaction_event::Kind::Requested(inner) => Self::Requested(inner.try_into()?),
            v1::interaction_event::Kind::Settled(inner) => Self::Settled(inner.try_into()?),
        })
    }
}

impl From<AgentHostInteractionEventKindV1> for v1::interaction_event::Kind {
    fn from(value: AgentHostInteractionEventKindV1) -> Self {
        match value {
            AgentHostInteractionEventKindV1::Requested(inner) => Self::Requested(inner.into()),
            AgentHostInteractionEventKindV1::Settled(inner) => Self::Settled(inner.into()),
        }
    }
}

impl TryFrom<v1::InteractionEvent> for AgentHostInteractionEventV1 {
    type Error = CoreError;

    fn try_from(value: v1::InteractionEvent) -> Result<Self, CoreError> {
        let v1::InteractionEvent { kind } = value;
        Ok(Self {
            kind: kind.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostInteractionEventV1> for v1::InteractionEvent {
    fn from(value: AgentHostInteractionEventV1) -> Self {
        let AgentHostInteractionEventV1 { kind } = value;
        Self {
            kind: kind.map(Into::into),
        }
    }
}

/// Recorded before a mutating command executes.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostCommandAcceptedV1 {
    pub operation_id: String,
    pub argument_fingerprint: String,
    /// Which command it was, for replay tooling.
    pub command_kind: String,
    /// RFC 3339.
    pub accepted_at: String,
}

impl TryFrom<v1::CommandAccepted> for AgentHostCommandAcceptedV1 {
    type Error = CoreError;

    fn try_from(value: v1::CommandAccepted) -> Result<Self, CoreError> {
        let v1::CommandAccepted {
            operation_id,
            argument_fingerprint,
            command_kind,
            accepted_at,
        } = value;
        Ok(Self {
            operation_id,
            argument_fingerprint,
            command_kind,
            accepted_at,
        })
    }
}

impl From<AgentHostCommandAcceptedV1> for v1::CommandAccepted {
    fn from(value: AgentHostCommandAcceptedV1) -> Self {
        let AgentHostCommandAcceptedV1 {
            operation_id,
            argument_fingerprint,
            command_kind,
            accepted_at,
        } = value;
        Self {
            operation_id,
            argument_fingerprint,
            command_kind,
            accepted_at,
        }
    }
}

/// Recorded once a mutating command has a durable outcome. A retry with the same `MutationKey`
/// returns `settlement` without re-executing.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostCommandSettledV1 {
    pub operation_id: String,
    /// RFC 3339.
    pub settled_at: String,
    pub settlement: Option<AgentHostCommandSettledSettlementV1>,
}

/// `CommandSettled.settlement` (`oneof settlement`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostCommandSettledSettlementV1 {
    Result(AgentHostCommandResultV1),
    Rejected(AgentHostCommandRejectedV1),
}

impl TryFrom<v1::command_settled::Settlement> for AgentHostCommandSettledSettlementV1 {
    type Error = CoreError;

    fn try_from(value: v1::command_settled::Settlement) -> Result<Self, CoreError> {
        Ok(match value {
            v1::command_settled::Settlement::Result(inner) => Self::Result(inner.try_into()?),
            v1::command_settled::Settlement::Rejected(inner) => Self::Rejected(inner.try_into()?),
        })
    }
}

impl From<AgentHostCommandSettledSettlementV1> for v1::command_settled::Settlement {
    fn from(value: AgentHostCommandSettledSettlementV1) -> Self {
        match value {
            AgentHostCommandSettledSettlementV1::Result(inner) => Self::Result(inner.into()),
            AgentHostCommandSettledSettlementV1::Rejected(inner) => Self::Rejected(inner.into()),
        }
    }
}

impl TryFrom<v1::CommandSettled> for AgentHostCommandSettledV1 {
    type Error = CoreError;

    fn try_from(value: v1::CommandSettled) -> Result<Self, CoreError> {
        let v1::CommandSettled {
            operation_id,
            settled_at,
            settlement,
        } = value;
        Ok(Self {
            operation_id,
            settled_at,
            settlement: settlement.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostCommandSettledV1> for v1::CommandSettled {
    fn from(value: AgentHostCommandSettledV1) -> Self {
        let AgentHostCommandSettledV1 {
            operation_id,
            settled_at,
            settlement,
        } = value;
        Self {
            operation_id,
            settled_at,
            settlement: settlement.map(Into::into),
        }
    }
}

/// First record of a log created by importing a legacy Swift-owned session (design §7.2 import).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostImportedV1 {
    /// Lowercase hex SHA-256 of the legacy persisted session bytes.
    pub legacy_digest: String,
    pub legacy_format: String,
    pub imported_item_count: u64,
    /// RFC 3339.
    pub imported_at: String,
}

impl TryFrom<v1::Imported> for AgentHostImportedV1 {
    type Error = CoreError;

    fn try_from(value: v1::Imported) -> Result<Self, CoreError> {
        let v1::Imported {
            legacy_digest,
            legacy_format,
            imported_item_count,
            imported_at,
        } = value;
        Ok(Self {
            legacy_digest,
            legacy_format,
            imported_item_count,
            imported_at,
        })
    }
}

impl From<AgentHostImportedV1> for v1::Imported {
    fn from(value: AgentHostImportedV1) -> Self {
        let AgentHostImportedV1 {
            legacy_digest,
            legacy_format,
            imported_item_count,
            imported_at,
        } = value;
        Self {
            legacy_digest,
            legacy_format,
            imported_item_count,
            imported_at,
        }
    }
}

/// First record of a log created by forking another session at `cursor` (design §7.2 fork).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostForkedFromV1 {
    pub session_id: String,
    pub cursor: u64,
    pub generation: Vec<u8>,
}

impl TryFrom<v1::ForkedFrom> for AgentHostForkedFromV1 {
    type Error = CoreError;

    fn try_from(value: v1::ForkedFrom) -> Result<Self, CoreError> {
        let v1::ForkedFrom {
            session_id,
            cursor,
            generation,
        } = value;
        Ok(Self {
            session_id,
            cursor,
            generation,
        })
    }
}

impl From<AgentHostForkedFromV1> for v1::ForkedFrom {
    fn from(value: AgentHostForkedFromV1) -> Self {
        let AgentHostForkedFromV1 {
            session_id,
            cursor,
            generation,
        } = value;
        Self {
            session_id,
            cursor,
            generation,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostSessionMetadataChangedV1 {
    pub summary: Option<AgentHostSessionSummaryV1>,
}

impl TryFrom<v1::SessionMetadataChanged> for AgentHostSessionMetadataChangedV1 {
    type Error = CoreError;

    fn try_from(value: v1::SessionMetadataChanged) -> Result<Self, CoreError> {
        let v1::SessionMetadataChanged { summary } = value;
        Ok(Self {
            summary: summary.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostSessionMetadataChangedV1> for v1::SessionMetadataChanged {
    fn from(value: AgentHostSessionMetadataChangedV1) -> Self {
        let AgentHostSessionMetadataChangedV1 { summary } = value;
        Self {
            summary: summary.map(Into::into),
        }
    }
}

/// One event-log record. On disk each record is `u32 big-endian length || u32 big-endian CRC32C ||
/// encoded AgentSessionEvent`; the record ordinal (1-based) is the `delivery_cursor`. On the wire
/// the same message travels inside `EventNotification`, so every record is also an event.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostAgentSessionEventV1 {
    /// RFC 3339 time the host recorded it.
    pub recorded_at: String,
    pub body: Option<AgentHostAgentSessionEventBodyV1>,
}

/// `AgentSessionEvent.body` (`oneof body`).
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentHostAgentSessionEventBodyV1 {
    RuntimeEvent(AgentHostRuntimeEventV1),
    RunLifecycle(AgentHostRunLifecycleEventV1),
    Interaction(AgentHostInteractionEventV1),
    SessionMetadataChanged(AgentHostSessionMetadataChangedV1),
    /// A user message accepted by `Steer` or `Start`.
    UserMessage(AgentHostUserMessageV1),
    CommandAccepted(AgentHostCommandAcceptedV1),
    CommandSettled(AgentHostCommandSettledV1),
    Imported(AgentHostImportedV1),
    ForkedFrom(AgentHostForkedFromV1),
}

impl TryFrom<v1::agent_session_event::Body> for AgentHostAgentSessionEventBodyV1 {
    type Error = CoreError;

    fn try_from(value: v1::agent_session_event::Body) -> Result<Self, CoreError> {
        Ok(match value {
            v1::agent_session_event::Body::RuntimeEvent(inner) => {
                Self::RuntimeEvent(inner.try_into()?)
            }
            v1::agent_session_event::Body::RunLifecycle(inner) => {
                Self::RunLifecycle(inner.try_into()?)
            }
            v1::agent_session_event::Body::Interaction(inner) => {
                Self::Interaction(inner.try_into()?)
            }
            v1::agent_session_event::Body::SessionMetadataChanged(inner) => {
                Self::SessionMetadataChanged(inner.try_into()?)
            }
            v1::agent_session_event::Body::UserMessage(inner) => {
                Self::UserMessage(inner.try_into()?)
            }
            v1::agent_session_event::Body::CommandAccepted(inner) => {
                Self::CommandAccepted(inner.try_into()?)
            }
            v1::agent_session_event::Body::CommandSettled(inner) => {
                Self::CommandSettled(inner.try_into()?)
            }
            v1::agent_session_event::Body::Imported(inner) => Self::Imported(inner.try_into()?),
            v1::agent_session_event::Body::ForkedFrom(inner) => Self::ForkedFrom(inner.try_into()?),
        })
    }
}

impl From<AgentHostAgentSessionEventBodyV1> for v1::agent_session_event::Body {
    fn from(value: AgentHostAgentSessionEventBodyV1) -> Self {
        match value {
            AgentHostAgentSessionEventBodyV1::RuntimeEvent(inner) => {
                Self::RuntimeEvent(inner.into())
            }
            AgentHostAgentSessionEventBodyV1::RunLifecycle(inner) => {
                Self::RunLifecycle(inner.into())
            }
            AgentHostAgentSessionEventBodyV1::Interaction(inner) => Self::Interaction(inner.into()),
            AgentHostAgentSessionEventBodyV1::SessionMetadataChanged(inner) => {
                Self::SessionMetadataChanged(inner.into())
            }
            AgentHostAgentSessionEventBodyV1::UserMessage(inner) => Self::UserMessage(inner.into()),
            AgentHostAgentSessionEventBodyV1::CommandAccepted(inner) => {
                Self::CommandAccepted(inner.into())
            }
            AgentHostAgentSessionEventBodyV1::CommandSettled(inner) => {
                Self::CommandSettled(inner.into())
            }
            AgentHostAgentSessionEventBodyV1::Imported(inner) => Self::Imported(inner.into()),
            AgentHostAgentSessionEventBodyV1::ForkedFrom(inner) => Self::ForkedFrom(inner.into()),
        }
    }
}

impl TryFrom<v1::AgentSessionEvent> for AgentHostAgentSessionEventV1 {
    type Error = CoreError;

    fn try_from(value: v1::AgentSessionEvent) -> Result<Self, CoreError> {
        let v1::AgentSessionEvent { recorded_at, body } = value;
        Ok(Self {
            recorded_at,
            body: body.map(TryInto::try_into).transpose()?,
        })
    }
}

impl From<AgentHostAgentSessionEventV1> for v1::AgentSessionEvent {
    fn from(value: AgentHostAgentSessionEventV1) -> Self {
        let AgentHostAgentSessionEventV1 { recorded_at, body } = value;
        Self {
            recorded_at,
            body: body.map(Into::into),
        }
    }
}

/// Provider-neutral transcript entry folded from `StreamResult`s and user messages.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostTranscriptEntryV1 {
    pub entry_id: String,
    pub role: AgentHostTranscriptRoleV1,
    pub text: String,
    pub reasoning: String,
    pub tool_name: String,
    pub tool_invocation_id: String,
    pub tool_args_json: String,
    pub tool_result_json: String,
    pub tool_is_error: bool,
    pub attachments: Vec<AgentHostArtifactRefV1>,
    /// RFC 3339.
    pub created_at: String,
    pub turn_id: String,
    /// Cursor of the last log record folded into this entry.
    pub through_cursor: u64,
}

impl TryFrom<v1::TranscriptEntry> for AgentHostTranscriptEntryV1 {
    type Error = CoreError;

    fn try_from(value: v1::TranscriptEntry) -> Result<Self, CoreError> {
        let v1::TranscriptEntry {
            entry_id,
            role,
            text,
            reasoning,
            tool_name,
            tool_invocation_id,
            tool_args_json,
            tool_result_json,
            tool_is_error,
            attachments,
            created_at,
            turn_id,
            through_cursor,
        } = value;
        Ok(Self {
            entry_id,
            role: enum_from_i32::<v1::TranscriptRole, _>("TranscriptRole", role)?,
            text,
            reasoning,
            tool_name,
            tool_invocation_id,
            tool_args_json,
            tool_result_json,
            tool_is_error,
            attachments: messages_from(attachments)?,
            created_at,
            turn_id,
            through_cursor,
        })
    }
}

impl From<AgentHostTranscriptEntryV1> for v1::TranscriptEntry {
    fn from(value: AgentHostTranscriptEntryV1) -> Self {
        let AgentHostTranscriptEntryV1 {
            entry_id,
            role,
            text,
            reasoning,
            tool_name,
            tool_invocation_id,
            tool_args_json,
            tool_result_json,
            tool_is_error,
            attachments,
            created_at,
            turn_id,
            through_cursor,
        } = value;
        Self {
            entry_id,
            role: v1::TranscriptRole::from(role) as i32,
            text,
            reasoning,
            tool_name,
            tool_invocation_id,
            tool_args_json,
            tool_result_json,
            tool_is_error,
            attachments: attachments.into_iter().map(Into::into).collect(),
            created_at,
            turn_id,
            through_cursor,
        }
    }
}

/// State reduced from the log through `through_cursor`. Never authoritative: a missing or corrupt
/// snapshot is rebuilt by replaying the log.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentHostAgentSessionSnapshotV1 {
    pub session_id: String,
    pub generation: Vec<u8>,
    pub through_cursor: u64,
    pub summary: Option<AgentHostSessionSummaryV1>,
    pub transcript: Vec<AgentHostTranscriptEntryV1>,
    /// Interactions still pending at `through_cursor`.
    pub pending_interactions: Vec<AgentHostPendingInteractionV1>,
    /// Mutating operations accepted but not yet settled at `through_cursor`.
    pub unsettled_operations: Vec<AgentHostCommandAcceptedV1>,
    /// RFC 3339.
    pub written_at: String,
}

impl TryFrom<v1::AgentSessionSnapshot> for AgentHostAgentSessionSnapshotV1 {
    type Error = CoreError;

    fn try_from(value: v1::AgentSessionSnapshot) -> Result<Self, CoreError> {
        let v1::AgentSessionSnapshot {
            session_id,
            generation,
            through_cursor,
            summary,
            transcript,
            pending_interactions,
            unsettled_operations,
            written_at,
        } = value;
        Ok(Self {
            session_id,
            generation,
            through_cursor,
            summary: summary.map(TryInto::try_into).transpose()?,
            transcript: messages_from(transcript)?,
            pending_interactions: messages_from(pending_interactions)?,
            unsettled_operations: messages_from(unsettled_operations)?,
            written_at,
        })
    }
}

impl From<AgentHostAgentSessionSnapshotV1> for v1::AgentSessionSnapshot {
    fn from(value: AgentHostAgentSessionSnapshotV1) -> Self {
        let AgentHostAgentSessionSnapshotV1 {
            session_id,
            generation,
            through_cursor,
            summary,
            transcript,
            pending_interactions,
            unsettled_operations,
            written_at,
        } = value;
        Self {
            session_id,
            generation,
            through_cursor,
            summary: summary.map(Into::into),
            transcript: transcript.into_iter().map(Into::into).collect(),
            pending_interactions: pending_interactions.into_iter().map(Into::into).collect(),
            unsettled_operations: unsettled_operations.into_iter().map(Into::into).collect(),
            written_at,
        }
    }
}
