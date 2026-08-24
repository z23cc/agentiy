//! Owned runtime, operation, subscription, and wake lifecycle for Agentry.

// P6-4 (docs/architecture/rust-agent-claude-v1.md §5.2/§12): downgraded from `forbid` to `deny`
// so `agent_claude::process::addchdir` can carry the confirmed, unconditional, narrowly-scoped
// `#[allow(unsafe_code)]` exception for the hand-declared `posix_spawn_file_actions_addchdir_np`
// extern "C" binding -- `forbid` cannot be downgraded by any inner attribute, `deny` can. This is
// one of the crate's two `#[allow(unsafe_code)]` sites -- the other is
// `agent_claude::process::reaper::waitid_probe` (a second Apple-specific `nix` gap found during
// P6-2). `Scripts/rust_ffi_guardrails.py` asserts these are the only two.
#![deny(unsafe_code)]

pub mod agent_claude;
pub mod apply_edits;
pub mod codemap;
mod config;
mod identity;
pub mod inventory;
pub mod inventory_scope;
mod lifecycle;
mod observability;
mod operation;
mod panic_forensics;
pub mod pathmatch;
pub mod pathsearch;
mod registry;
mod search;
pub mod searchscore;
mod subscription;
pub mod textdecode;
pub mod tokenacct;
mod wake_pipe;

pub use config::RuntimeConfig;
pub use identity::{ABI_EPOCH, IdentityError, RuntimeIdentity};
pub use lifecycle::{CoreRuntime, LifecycleState, RuntimeError, ShutdownReceipt};
pub use observability::{
    DiagnosticRecord, DiagnosticSeverity, drain_diagnostics, record_diagnostic,
};
pub use operation::{
    AdmissionOutcome, AdmissionRequest, CancelOutcome, IdentifierError, OperationDiagnostics,
    OperationId, OperationSnapshot, OperationState, RequestFingerprint, ScopeId, TerminalOutcome,
};
pub use panic_forensics::{PanicRecord, install_panic_hook, recent_panics};
pub use registry::{OperationRegistry, RegistryError};
pub use search::{
    ByteRange, CompactRegexBatchResult, CompactRegexSubjectSummary, EngineKind,
    FolderSuffixRequest, JitStatus, LeafCancellation, LimitFailure, LimitPolicy, MatchPolicy,
    PathClause, PathDiagnostic, PathFilterRequest, PathFilterResult, PathSnapshot, RegexDiagnostic,
    RegexLineHit, RegexSearchMode, RegexSearchRequest, RegexSearchResult, RepairKind, SearchError,
    SearchLeaf,
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
