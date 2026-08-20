//! Owned runtime, operation, subscription, and wake lifecycle for Agentry.

#![forbid(unsafe_code)]

mod config;
mod identity;
mod lifecycle;
mod operation;
mod registry;
mod search;
mod subscription;
mod wake_pipe;

pub use config::RuntimeConfig;
pub use identity::{ABI_EPOCH, IdentityError, RuntimeIdentity};
pub use lifecycle::{CoreRuntime, LifecycleState, RuntimeError, ShutdownReceipt};
pub use operation::{
    AdmissionOutcome, AdmissionRequest, CancelOutcome, IdentifierError, OperationDiagnostics,
    OperationId, OperationSnapshot, OperationState, RequestFingerprint, ScopeId, TerminalOutcome,
};
pub use registry::{OperationRegistry, RegistryError};
pub use search::{
    ByteRange, EngineKind, FolderSuffixRequest, JitStatus, LeafCancellation, LimitFailure,
    LimitPolicy, MatchPolicy, PathClause, PathDiagnostic, PathFilterRequest, PathFilterResult,
    PathSnapshot, RegexDiagnostic, RegexLineHit, RegexSearchMode, RegexSearchRequest,
    RegexSearchResult, RepairKind, SearchError, SearchLeaf,
};
pub use subscription::{
    DEFAULT_DRAIN_MAX_BYTES, DEFAULT_DRAIN_MAX_EVENTS, DEFAULT_MAX_QUEUED_BYTES,
    DEFAULT_MAX_QUEUED_EVENTS, DrainBatch, DrainOutcome, EventClass, EventDetail, EventInput,
    HARD_DRAIN_MAX_BYTES, HARD_DRAIN_MAX_EVENTS, MINIMUM_DRAIN_MAX_BYTES, OversizeDrain,
    PublishSummary, RESERVED_TERMINAL_CONTROL_BYTES, RESERVED_TERMINAL_SLOTS, RuntimeEvent,
    RuntimeEventKind, StreamId, SubscriptionBootstrap, SubscriptionConfig, SubscriptionError,
    SubscriptionHub, SubscriptionId,
};
pub use wake_pipe::{WakePipe, WakePipeError, WakeSignal};

/// Schema version admitted by the runtime.
pub const EXPECTED_ENVELOPE_SCHEMA_VERSION: u16 = agentry_proto::ENVELOPE_SCHEMA_VERSION;
