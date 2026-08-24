use agentry_proto::DecodeError;
use agentry_runtime::agent_claude::{
    AgentScopeError, ScopeRegistryError as AgentClaudeScopeRegistryError,
};
use agentry_runtime::inventory_scope::{BulkLoadError, ScopeError, ScopeRegistryError};
use agentry_runtime::{
    IdentifierError, IdentityError, RegistryError, RuntimeError, SearchError, SubscriptionError,
};

use crate::types::InventoryHandleInvalidationReasonV1;

/// Stable error categories exported by ABI epoch 1.
#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("invalid argument")]
    InvalidArgument,
    #[error("incompatible ABI or build identity")]
    IncompatibleAbi,
    #[error("stale runtime identity")]
    StaleRuntimeIdentity,
    #[error("runtime is poisoned")]
    RuntimePoisoned,
    #[error("runtime is stopped")]
    RuntimeStopped,
    #[error("operation ID conflicts with an existing request")]
    OperationConflict,
    #[error("operation deadline expired")]
    DeadlineExpired,
    #[error("subscription was not found")]
    SubscriptionNotFound,
    #[error("queue limit exceeded")]
    QueueLimitExceeded,
    #[error("payload is too large")]
    PayloadTooLarge,
    #[error("shutdown timed out")]
    ShutdownTimedOut,
    #[error("an internal panic was contained")]
    InternalPanic,
    #[error("search pattern is too complex")]
    PatternTooComplex,
    #[error("invalid regex escape sequence")]
    InvalidEscape,
    #[error("unmatched regex brackets")]
    UnmatchedBrackets,
    #[error("unmatched regex parentheses")]
    UnmatchedParentheses,
    #[error("invalid regex quantifier")]
    InvalidQuantifier,
    #[error("variable-length lookbehind is unsupported")]
    VariableLengthLookbehind,
    #[error("invalid regex pattern")]
    InvalidPattern,
    #[error("regex match limit exceeded")]
    MatchLimitExceeded,
    #[error("regex depth limit exceeded")]
    DepthLimitExceeded,
    #[error("regex heap limit exceeded")]
    HeapLimitExceeded,
    #[error("PCRE2 JIT is unavailable")]
    JitUnavailable,
    #[error("search was cancelled")]
    SearchCancelled,
    #[error("search result violated an internal invariant")]
    SearchInvariant,
    #[error("invalid codemap request")]
    CodeMapInvalidRequest,
    #[error("codemap parser or query service is unavailable")]
    CodeMapServiceUnavailable,
    #[error("codemap computation was cancelled")]
    CodeMapCancelled,
    #[error("codemap result violated an internal invariant")]
    CodeMapInvariant,
    #[error("{message}")]
    ApplyEditsInvalidParams { message: String },
    #[error("apply-edits computation was cancelled")]
    ApplyEditsCancelled,
    #[error("apply-edits result violated an internal invariant")]
    ApplyEditsInvariant,
    /// TD-3 §5.3.1 mechanism 2 (design `docs/designs/textdecode-policy-v2-2026-08-22.md`):
    /// a `Raw`-sourced apply-edits subject decoded lossily (`had_replacements`); write-back is
    /// refused rather than silently overwriting bytes that cannot be faithfully round-tripped.
    #[error("{message}")]
    ApplyEditsLossyDecodeBlocksWriteBack { message: String },
    /// P4-8: no longer constructed -- `inventory-compute-v1` (the only producer of these three
    /// variants) was retired in favor of the stateful `inventory-scope-v1` surface, which has its
    /// own `InventoryScope*`-prefixed error variants below. Left in place rather than removed:
    /// these are wire-exposed `uniffi::Error` cases and pruning them is an ABI-epoch decision, not
    /// a byproduct of an unrelated cleanup.
    #[error("{message}")]
    InventoryInvalidRequest { message: String },
    #[error("inventory computation was cancelled")]
    InventoryCancelled,
    #[error("inventory result violated an internal invariant")]
    InventoryInvariant,
    #[error("{message}")]
    PathMatchInvalidRequest { message: String },
    #[error("path-match score computation was cancelled")]
    PathMatchCancelled,
    #[error("{message}")]
    PathResolveInvalidRequest { message: String },
    #[error("path-resolve computation was cancelled")]
    PathResolveCancelled,
    #[error("{message}")]
    PathSearchInvalidRequest { message: String },
    #[error("path-search computation was cancelled")]
    PathSearchCancelled,
    #[error("{message}")]
    TokenAccountingInvalidRequest { message: String },
    #[error("token-accounting computation was cancelled")]
    TokenAccountingCancelled,
    #[error("unknown inventory scope")]
    InventoryScopeUnknownScope,
    #[error("unknown inventory root")]
    InventoryScopeUnknownRoot,
    #[error("inventory root lifetime mismatch")]
    InventoryScopeLifetimeMismatch,
    #[error("inventory root has no published generation yet")]
    InventoryScopeNoPublishedGeneration,
    #[error("unknown inventory bulk load")]
    InventoryScopeBulkLoadUnknown,
    #[error("inventory bulk load is already terminal")]
    InventoryScopeBulkLoadAlreadyTerminal,
    #[error("inventory bulk load root mismatch")]
    InventoryScopeBulkLoadRootMismatch,
    #[error("inventory snapshot handle invalidated")]
    InventoryHandleInvalidated {
        reason: InventoryHandleInvalidationReasonV1,
    },
    #[error("{message}")]
    InventoryScopeInvalidRequest { message: String },
    // P6-6: agent-claude-v1 (docs/architecture/rust-agent-claude-v1.md, design §11 P6-6).
    #[error("unknown agent-claude scope")]
    AgentClaudeUnknownScope,
    #[error("agent-claude scope is closed")]
    AgentClaudeScopeClosed,
    #[error("agent-claude scope already has a running process")]
    AgentClaudeAlreadyRunning,
    #[error("agent-claude scope has no running process")]
    AgentClaudeNotRunning,
    #[error("unknown agent-claude permission request id")]
    AgentClaudeUnknownPermissionRequest,
    #[error("agent-claude spawn failed: {message}")]
    AgentClaudeSpawnFailed { message: String },
    #[error("agent-claude reaper registration failed: {message}")]
    AgentClaudeReaperFailed { message: String },
    #[error("agent-claude transport write failed: {message}")]
    AgentClaudeTransportWriteFailed { message: String },
    #[error("{message}")]
    AgentClaudeInvalidRequest { message: String },
    /// P6-7 (§15.5): the CLI answered a session-startup handshake control request (`initialize`/
    /// `set_permission_mode`, contract §2.5) with `subtype: "error"`, carrying its own message --
    /// port of `ControllerError.invalidControlResponse`.
    #[error("agent-claude control response error: {message}")]
    AgentClaudeControlResponseError { message: String },
}

impl From<IdentifierError> for CoreError {
    fn from(_: IdentifierError) -> Self {
        Self::InvalidArgument
    }
}

impl From<IdentityError> for CoreError {
    fn from(value: IdentityError) -> Self {
        match value {
            IdentityError::IncompatibleAbi { .. } => Self::IncompatibleAbi,
            IdentityError::InvalidInstanceNonce
            | IdentityError::InvalidBuildFingerprint
            | IdentityError::InvalidBindingChecksum => Self::InvalidArgument,
        }
    }
}

impl From<RegistryError> for CoreError {
    fn from(value: RegistryError) -> Self {
        match value {
            RegistryError::StaleRuntimeIdentity => Self::StaleRuntimeIdentity,
            RegistryError::OperationConflict => Self::OperationConflict,
            RegistryError::DeadlineExpired => Self::DeadlineExpired,
            RegistryError::InvalidDeadline => Self::InvalidArgument,
            RegistryError::ShuttingDown => Self::RuntimeStopped,
        }
    }
}

impl From<SubscriptionError> for CoreError {
    fn from(value: SubscriptionError) -> Self {
        match value {
            SubscriptionError::StaleRuntimeIdentity => Self::StaleRuntimeIdentity,
            SubscriptionError::SubscriptionNotFound => Self::SubscriptionNotFound,
            SubscriptionError::InvalidLimits => Self::InvalidArgument,
            SubscriptionError::QueueLimitExceeded => Self::QueueLimitExceeded,
            SubscriptionError::RuntimeStopped => Self::RuntimeStopped,
            SubscriptionError::Wake(_) => Self::RuntimeStopped,
        }
    }
}

impl From<RuntimeError> for CoreError {
    fn from(value: RuntimeError) -> Self {
        match value {
            RuntimeError::InvalidConfig(_) => Self::InvalidArgument,
            RuntimeError::Startup(_) => Self::RuntimeStopped,
            RuntimeError::Registry(error) => error.into(),
            RuntimeError::Subscription(error) => error.into(),
            RuntimeError::DataLaneSaturated => Self::QueueLimitExceeded,
            RuntimeError::ShuttingDown => Self::RuntimeStopped,
        }
    }
}

impl From<SearchError> for CoreError {
    fn from(value: SearchError) -> Self {
        match value {
            SearchError::PatternTooComplex => Self::PatternTooComplex,
            SearchError::InvalidEscape => Self::InvalidEscape,
            SearchError::UnmatchedBrackets => Self::UnmatchedBrackets,
            SearchError::UnmatchedParentheses => Self::UnmatchedParentheses,
            SearchError::InvalidQuantifier => Self::InvalidQuantifier,
            SearchError::VariableLengthLookbehind => Self::VariableLengthLookbehind,
            SearchError::InvalidPattern { .. } => Self::InvalidPattern,
            SearchError::MatchLimitExceeded => Self::MatchLimitExceeded,
            SearchError::DepthLimitExceeded => Self::DepthLimitExceeded,
            SearchError::HeapLimitExceeded => Self::HeapLimitExceeded,
            SearchError::JitUnavailable(_) => Self::JitUnavailable,
            SearchError::Cancelled => Self::SearchCancelled,
            SearchError::InternalInvariant(_) => Self::SearchInvariant,
        }
    }
}

impl From<agentry_runtime::codemap::CodeMapError> for CoreError {
    fn from(value: agentry_runtime::codemap::CodeMapError) -> Self {
        match value {
            agentry_runtime::codemap::CodeMapError::InvalidRequest(_) => {
                Self::CodeMapInvalidRequest
            }
            agentry_runtime::codemap::CodeMapError::Parser(_)
            | agentry_runtime::codemap::CodeMapError::Query(_)
            | agentry_runtime::codemap::CodeMapError::ParserReturnedNilTree => {
                Self::CodeMapServiceUnavailable
            }
            agentry_runtime::codemap::CodeMapError::Internal(_) => Self::CodeMapInvariant,
            agentry_runtime::codemap::CodeMapError::Cancelled => Self::CodeMapCancelled,
        }
    }
}

impl From<agentry_runtime::apply_edits::ApplyError> for CoreError {
    fn from(value: agentry_runtime::apply_edits::ApplyError) -> Self {
        match value {
            agentry_runtime::apply_edits::ApplyError::InvalidParams(message) => {
                Self::ApplyEditsInvalidParams { message }
            }
            agentry_runtime::apply_edits::ApplyError::Internal(_) => Self::ApplyEditsInvariant,
            agentry_runtime::apply_edits::ApplyError::Cancelled => Self::ApplyEditsCancelled,
            agentry_runtime::apply_edits::ApplyError::LossyDecodeBlocksWriteBack(message) => {
                Self::ApplyEditsLossyDecodeBlocksWriteBack { message }
            }
        }
    }
}

impl From<agentry_runtime::pathmatch::PathMatchScoreError> for CoreError {
    fn from(value: agentry_runtime::pathmatch::PathMatchScoreError) -> Self {
        match value {
            agentry_runtime::pathmatch::PathMatchScoreError::InvalidRequest(message) => {
                Self::PathMatchInvalidRequest { message }
            }
            agentry_runtime::pathmatch::PathMatchScoreError::Cancelled => Self::PathMatchCancelled,
        }
    }
}

impl From<agentry_runtime::pathmatch::PathMatchResolveError> for CoreError {
    fn from(value: agentry_runtime::pathmatch::PathMatchResolveError) -> Self {
        match value {
            agentry_runtime::pathmatch::PathMatchResolveError::InvalidRequest(message) => {
                Self::PathResolveInvalidRequest { message }
            }
            agentry_runtime::pathmatch::PathMatchResolveError::Cancelled => {
                Self::PathResolveCancelled
            }
        }
    }
}

impl From<agentry_runtime::pathsearch::PathSearchFindError> for CoreError {
    fn from(value: agentry_runtime::pathsearch::PathSearchFindError) -> Self {
        match value {
            agentry_runtime::pathsearch::PathSearchFindError::InvalidRequest(message) => {
                Self::PathSearchInvalidRequest { message }
            }
            agentry_runtime::pathsearch::PathSearchFindError::Cancelled => {
                Self::PathSearchCancelled
            }
        }
    }
}

impl From<agentry_runtime::tokenacct::TokenAccountingError> for CoreError {
    fn from(value: agentry_runtime::tokenacct::TokenAccountingError) -> Self {
        match value {
            agentry_runtime::tokenacct::TokenAccountingError::InvalidRequest(message) => {
                Self::TokenAccountingInvalidRequest { message }
            }
            agentry_runtime::tokenacct::TokenAccountingError::Cancelled => {
                Self::TokenAccountingCancelled
            }
        }
    }
}

impl From<ScopeError> for CoreError {
    fn from(value: ScopeError) -> Self {
        match value {
            ScopeError::IdentityMismatch => Self::StaleRuntimeIdentity,
            ScopeError::ScopeClosed => Self::RuntimeStopped,
            ScopeError::UnknownRoot => Self::InventoryScopeUnknownRoot,
            ScopeError::LifetimeMismatch => Self::InventoryScopeLifetimeMismatch,
            ScopeError::NoPublishedGeneration => Self::InventoryScopeNoPublishedGeneration,
        }
    }
}

impl From<ScopeRegistryError> for CoreError {
    fn from(value: ScopeRegistryError) -> Self {
        match value {
            ScopeRegistryError::IdentityMismatch => Self::StaleRuntimeIdentity,
            ScopeRegistryError::UnknownScope => Self::InventoryScopeUnknownScope,
        }
    }
}

impl From<BulkLoadError> for CoreError {
    fn from(value: BulkLoadError) -> Self {
        match value {
            BulkLoadError::Unknown => Self::InventoryScopeBulkLoadUnknown,
            BulkLoadError::AlreadyTerminal => Self::InventoryScopeBulkLoadAlreadyTerminal,
            BulkLoadError::RootMismatch => Self::InventoryScopeBulkLoadRootMismatch,
        }
    }
}

impl From<AgentScopeError> for CoreError {
    fn from(value: AgentScopeError) -> Self {
        match value {
            AgentScopeError::IdentityMismatch => Self::StaleRuntimeIdentity,
            AgentScopeError::ScopeClosed => Self::AgentClaudeScopeClosed,
            AgentScopeError::AlreadyRunning => Self::AgentClaudeAlreadyRunning,
            AgentScopeError::NotRunning => Self::AgentClaudeNotRunning,
            AgentScopeError::UnknownScope => Self::AgentClaudeUnknownScope,
            AgentScopeError::UnknownPermissionRequest => Self::AgentClaudeUnknownPermissionRequest,
            AgentScopeError::Spawn(message) => Self::AgentClaudeSpawnFailed { message },
            AgentScopeError::Reaper(message) => Self::AgentClaudeReaperFailed { message },
            AgentScopeError::TransportWrite(message) => {
                Self::AgentClaudeTransportWriteFailed { message }
            }
            AgentScopeError::InvalidArgument(what) => Self::AgentClaudeInvalidRequest {
                message: what.to_string(),
            },
            AgentScopeError::ControlResponseError(message) => {
                Self::AgentClaudeControlResponseError { message }
            }
        }
    }
}

impl From<AgentClaudeScopeRegistryError> for CoreError {
    fn from(value: AgentClaudeScopeRegistryError) -> Self {
        match value {
            AgentClaudeScopeRegistryError::IdentityMismatch => Self::StaleRuntimeIdentity,
            AgentClaudeScopeRegistryError::UnknownScope => Self::AgentClaudeUnknownScope,
        }
    }
}

impl From<DecodeError> for CoreError {
    fn from(value: DecodeError) -> Self {
        match value {
            DecodeError::EnvelopeTooLarge { .. }
            | DecodeError::DeclaredPayloadTooLarge { .. }
            | DecodeError::DecodedSizeExceeded { .. }
            | DecodeError::CollectionTooLarge { .. }
            | DecodeError::StringTooLong { .. } => Self::PayloadTooLarge,
            DecodeError::HeaderTooShort { .. }
            | DecodeError::InvalidMagic
            | DecodeError::UnsupportedSchemaVersion { .. }
            | DecodeError::UnknownPayloadKind { .. }
            | DecodeError::UnsupportedFlags { .. }
            | DecodeError::TruncatedPayload { .. }
            | DecodeError::TrailingBytes { .. }
            | DecodeError::InvalidUtf8 => Self::InvalidArgument,
        }
    }
}
