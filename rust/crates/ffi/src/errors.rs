use agentry_proto::DecodeError;
use agentry_runtime::{
    IdentifierError, IdentityError, RegistryError, RuntimeError, SearchError, SubscriptionError,
};

/// Stable error categories exported by ABI epoch 1.
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error, uniffi::Error)]
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
