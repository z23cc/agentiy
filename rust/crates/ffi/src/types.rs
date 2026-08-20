use crate::errors::CoreError;
use agentry_runtime as runtime;

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct RuntimeIdentity {
    pub abi_epoch: u32,
    pub instance_nonce: String,
    pub build_fingerprint: String,
    pub binding_checksum: String,
}

impl RuntimeIdentity {
    pub(crate) fn parse(&self) -> Result<runtime::RuntimeIdentity, CoreError> {
        Ok(runtime::RuntimeIdentity::new(
            self.abi_epoch,
            self.instance_nonce.clone(),
            self.build_fingerprint.clone(),
            self.binding_checksum.clone(),
        )?)
    }
}

impl From<&runtime::RuntimeIdentity> for RuntimeIdentity {
    fn from(value: &runtime::RuntimeIdentity) -> Self {
        Self {
            abi_epoch: value.abi_epoch(),
            instance_nonce: value.instance_nonce().to_owned(),
            build_fingerprint: value.build_fingerprint().to_owned(),
            binding_checksum: value.binding_checksum().to_owned(),
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreConfig {
    pub expected_abi_epoch: u32,
    pub expected_build_fingerprint: String,
    pub expected_binding_checksum: String,
    pub data_lane_capacity: u64,
    pub cancel_tombstone_millis: u64,
    pub shutdown_grace_millis: u64,
}

impl CoreConfig {
    pub(crate) fn runtime_config(&self) -> Result<runtime::RuntimeConfig, CoreError> {
        let data_lane_capacity =
            usize::try_from(self.data_lane_capacity).map_err(|_| CoreError::InvalidArgument)?;
        if data_lane_capacity == 0
            || self.cancel_tombstone_millis == 0
            || self.shutdown_grace_millis == 0
        {
            return Err(CoreError::InvalidArgument);
        }
        Ok(runtime::RuntimeConfig {
            data_lane_capacity,
            cancel_tombstone_window: std::time::Duration::from_millis(self.cancel_tombstone_millis),
            shutdown_grace: std::time::Duration::from_millis(self.shutdown_grace_millis),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreHandshake {
    pub runtime_identity: RuntimeIdentity,
    pub abi_epoch: u32,
    pub payload_schema_versions: Vec<u16>,
    pub build_fingerprint: String,
    pub binding_checksum: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct OperationId {
    pub value: String,
}

impl OperationId {
    pub(crate) fn parse(&self) -> Result<runtime::OperationId, CoreError> {
        Ok(runtime::OperationId::parse(self.value.clone())?)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct ScopeId {
    pub value: String,
}

impl ScopeId {
    pub(crate) fn parse(&self) -> Result<runtime::ScopeId, CoreError> {
        Ok(runtime::ScopeId::parse(self.value.clone())?)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct RequestFingerprint {
    pub value: String,
}

impl RequestFingerprint {
    pub(crate) fn parse(&self) -> Result<runtime::RequestFingerprint, CoreError> {
        Ok(runtime::RequestFingerprint::parse(self.value.clone())?)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CommandEnvelope {
    pub runtime_identity: RuntimeIdentity,
    pub operation_id: OperationId,
    pub request_fingerprint: RequestFingerprint,
    pub scope_id: ScopeId,
    pub deadline_unix_millis: Option<u64>,
    pub payload: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum AdmissionDisposition {
    Accepted,
    Duplicate,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum OperationState {
    Admitted,
    Running,
    CancelRequested,
    Succeeded,
    Cancelled,
    DeadlineExceeded,
    Failed,
}

impl From<runtime::OperationState> for OperationState {
    fn from(value: runtime::OperationState) -> Self {
        match value {
            runtime::OperationState::Admitted => Self::Admitted,
            runtime::OperationState::Running => Self::Running,
            runtime::OperationState::CancelRequested => Self::CancelRequested,
            runtime::OperationState::Terminal(runtime::TerminalOutcome::Success) => Self::Succeeded,
            runtime::OperationState::Terminal(runtime::TerminalOutcome::Cancelled) => {
                Self::Cancelled
            }
            runtime::OperationState::Terminal(runtime::TerminalOutcome::DeadlineExceeded) => {
                Self::DeadlineExceeded
            }
            runtime::OperationState::Terminal(runtime::TerminalOutcome::Failed) => Self::Failed,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct AdmissionReceipt {
    pub runtime_identity: RuntimeIdentity,
    pub operation_id: OperationId,
    pub disposition: AdmissionDisposition,
    pub state: OperationState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CancelDisposition {
    Requested,
    Tombstoned,
    AlreadyRequested,
    AlreadyTerminal,
}

impl From<runtime::CancelOutcome> for CancelDisposition {
    fn from(value: runtime::CancelOutcome) -> Self {
        match value {
            runtime::CancelOutcome::Requested => Self::Requested,
            runtime::CancelOutcome::Tombstoned => Self::Tombstoned,
            runtime::CancelOutcome::AlreadyRequested => Self::AlreadyRequested,
            runtime::CancelOutcome::AlreadyTerminal => Self::AlreadyTerminal,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CancelReceipt {
    pub operation_id: OperationId,
    pub disposition: CancelDisposition,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct SubscriptionScope {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: ScopeId,
    pub max_queued_events: u64,
    pub max_queued_bytes: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct SubscriptionId {
    pub value: u64,
    pub runtime_identity: RuntimeIdentity,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct SubscriptionBootstrap {
    pub subscription_id: SubscriptionId,
    pub stream_id: u64,
    pub initial_snapshot: Vec<u8>,
    pub next_delivery_cursor: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum RuntimeEventKind {
    Admitted,
    Progress,
    Data,
    Gap,
    HostRequest,
    PayloadRejected,
    Terminal,
}

impl From<runtime::RuntimeEventKind> for RuntimeEventKind {
    fn from(value: runtime::RuntimeEventKind) -> Self {
        match value {
            runtime::RuntimeEventKind::Admitted => Self::Admitted,
            runtime::RuntimeEventKind::Progress => Self::Progress,
            runtime::RuntimeEventKind::Data => Self::Data,
            runtime::RuntimeEventKind::Gap => Self::Gap,
            runtime::RuntimeEventKind::HostRequest => Self::HostRequest,
            runtime::RuntimeEventKind::PayloadRejected => Self::PayloadRejected,
            runtime::RuntimeEventKind::Terminal => Self::Terminal,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct RuntimeEvent {
    pub kind: RuntimeEventKind,
    pub authority_sequence: u64,
    pub delivery_cursor: u64,
    pub payload: Vec<u8>,
    pub payload_omitted: bool,
}

impl From<runtime::RuntimeEvent> for RuntimeEvent {
    fn from(value: runtime::RuntimeEvent) -> Self {
        Self {
            kind: value.kind.into(),
            authority_sequence: value.authority_sequence,
            delivery_cursor: value.delivery_cursor,
            payload: value.payload,
            payload_omitted: value.payload_omitted,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct OversizeEvent {
    pub kind: RuntimeEventKind,
    pub actual_bytes: u64,
    pub maximum_bytes: u64,
    pub resnapshot_required: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct DrainBatch {
    pub events: Vec<RuntimeEvent>,
    pub has_more: bool,
    pub next_delivery_cursor: u64,
    pub dropped_count: u64,
    pub oversize: Option<OversizeEvent>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct HostResponse {
    pub runtime_identity: RuntimeIdentity,
    pub request_id: String,
    pub payload: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct ShutdownReceipt {
    pub already_started: bool,
    pub cancelled_operations: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Record)]
pub struct ByteRange {
    pub start: u64,
    pub end: u64,
}

impl From<runtime::ByteRange> for ByteRange {
    fn from(value: runtime::ByteRange) -> Self {
        Self {
            start: value.start,
            end: value.end,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum RegexSearchMode {
    Content,
    Path,
}

impl From<RegexSearchMode> for runtime::RegexSearchMode {
    fn from(value: RegexSearchMode) -> Self {
        match value {
            RegexSearchMode::Content => Self::Content,
            RegexSearchMode::Path => Self::Path,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum MatchPolicy {
    ContentFullBuffer,
    ContentLine,
    ShortPath,
}

impl From<MatchPolicy> for runtime::MatchPolicy {
    fn from(value: MatchPolicy) -> Self {
        match value {
            MatchPolicy::ContentFullBuffer => Self::ContentFullBuffer,
            MatchPolicy::ContentLine => Self::ContentLine,
            MatchPolicy::ShortPath => Self::ShortPath,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum LimitPolicy {
    FileSearchFullBuffer,
    FileSearchLine,
    PathSearchShortSubject,
}

impl From<runtime::LimitPolicy> for LimitPolicy {
    fn from(value: runtime::LimitPolicy) -> Self {
        match value {
            runtime::LimitPolicy::FileSearchFullBuffer => Self::FileSearchFullBuffer,
            runtime::LimitPolicy::FileSearchLine => Self::FileSearchLine,
            runtime::LimitPolicy::PathSearchShortSubject => Self::PathSearchShortSubject,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum RepairKind {
    None,
    DoubleEscapeCompression,
    Normalise,
    NormaliseThenCompression,
}

impl From<runtime::RepairKind> for RepairKind {
    fn from(value: runtime::RepairKind) -> Self {
        match value {
            runtime::RepairKind::None => Self::None,
            runtime::RepairKind::DoubleEscapeCompression => Self::DoubleEscapeCompression,
            runtime::RepairKind::Normalise => Self::Normalise,
            runtime::RepairKind::NormaliseThenCompression => Self::NormaliseThenCompression,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum EngineKind {
    AsciiWholeWord,
    AnchoredDeclaration,
    AsciiMarker,
    PathSuffix,
    AnchoredLinePrefilter,
    Pcre2,
}

impl From<runtime::EngineKind> for EngineKind {
    fn from(value: runtime::EngineKind) -> Self {
        match value {
            runtime::EngineKind::AsciiWholeWord => Self::AsciiWholeWord,
            runtime::EngineKind::AnchoredDeclaration => Self::AnchoredDeclaration,
            runtime::EngineKind::AsciiMarker => Self::AsciiMarker,
            runtime::EngineKind::PathSuffix => Self::PathSuffix,
            runtime::EngineKind::AnchoredLinePrefilter => Self::AnchoredLinePrefilter,
            runtime::EngineKind::Pcre2 => Self::Pcre2,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum JitStatus {
    NotApplicable,
    Active,
    Pcre2InterpreterFallback,
}

impl From<runtime::JitStatus> for JitStatus {
    fn from(value: runtime::JitStatus) -> Self {
        match value {
            runtime::JitStatus::NotApplicable => Self::NotApplicable,
            runtime::JitStatus::Active => Self::Active,
            runtime::JitStatus::Pcre2InterpreterFallback => Self::Pcre2InterpreterFallback,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum LimitFailure {
    Match,
    Depth,
    Heap,
}

impl From<runtime::LimitFailure> for LimitFailure {
    fn from(value: runtime::LimitFailure) -> Self {
        match value {
            runtime::LimitFailure::Match => Self::Match,
            runtime::LimitFailure::Depth => Self::Depth,
            runtime::LimitFailure::Heap => Self::Heap,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct RegexDiagnostic {
    pub engine: EngineKind,
    pub jit_status: JitStatus,
    pub cache_hit: bool,
    pub repair_kind: RepairKind,
    pub limit_policy: LimitPolicy,
    pub subject_byte_count: u64,
    pub line_count: u64,
    pub hit_count: u64,
    pub matching_line_count: u64,
    pub cancelled: bool,
    pub limit_failure: Option<LimitFailure>,
}

impl From<runtime::RegexDiagnostic> for RegexDiagnostic {
    fn from(value: runtime::RegexDiagnostic) -> Self {
        Self {
            engine: value.engine.into(),
            jit_status: value.jit_status.into(),
            cache_hit: value.cache_hit,
            repair_kind: value.repair_kind.into(),
            limit_policy: value.limit_policy.into(),
            subject_byte_count: value.subject_byte_count,
            line_count: value.line_count,
            hit_count: value.hit_count,
            matching_line_count: value.matching_line_count,
            cancelled: value.cancelled,
            limit_failure: value.limit_failure.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct RegexSearchRequest {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub mode: RegexSearchMode,
    pub pattern: String,
    pub subject: String,
    pub case_insensitive: bool,
    pub whole_word: bool,
    pub multiline_anchors: bool,
    pub collect_matches: bool,
    pub max_collected_matches: Option<u32>,
    pub context_lines: u16,
    pub match_policy: MatchPolicy,
}

impl RegexSearchRequest {
    pub(crate) fn runtime_request(&self) -> runtime::RegexSearchRequest {
        runtime::RegexSearchRequest {
            mode: self.mode.into(),
            pattern: self.pattern.clone(),
            subject: self.subject.clone(),
            case_insensitive: self.case_insensitive,
            whole_word: self.whole_word,
            multiline_anchors: self.multiline_anchors,
            collect_matches: self.collect_matches,
            max_collected_matches: self.max_collected_matches,
            context_lines: self.context_lines,
            match_policy: self.match_policy.into(),
            cancellation: self.cancellation.runtime_handle().clone(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct RegexLineHit {
    pub line_number: u32,
    pub line_byte_range: ByteRange,
    pub match_byte_range: ByteRange,
    pub context_before_byte_ranges: Vec<ByteRange>,
    pub context_after_byte_ranges: Vec<ByteRange>,
}

impl From<runtime::RegexLineHit> for RegexLineHit {
    fn from(value: runtime::RegexLineHit) -> Self {
        Self {
            line_number: value.line_number,
            line_byte_range: value.line_byte_range.into(),
            match_byte_range: value.match_byte_range.into(),
            context_before_byte_ranges: value
                .context_before_byte_ranges
                .into_iter()
                .map(Into::into)
                .collect(),
            context_after_byte_ranges: value
                .context_after_byte_ranges
                .into_iter()
                .map(Into::into)
                .collect(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct RegexSearchResult {
    pub hits: Vec<RegexLineHit>,
    pub matching_line_count: u64,
    pub cancelled: bool,
    pub diagnostic: RegexDiagnostic,
}

impl From<runtime::RegexSearchResult> for RegexSearchResult {
    fn from(value: runtime::RegexSearchResult) -> Self {
        Self {
            hits: value.hits.into_iter().map(Into::into).collect(),
            matching_line_count: value.matching_line_count,
            cancelled: value.cancelled,
            diagnostic: value.diagnostic.into(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct PathSnapshot {
    pub standardized_full_path: String,
    pub standardized_relative_path: String,
    pub standardized_root_path: String,
    pub client_display_path: String,
}

impl From<&PathSnapshot> for runtime::PathSnapshot {
    fn from(value: &PathSnapshot) -> Self {
        Self {
            standardized_full_path: value.standardized_full_path.clone(),
            standardized_relative_path: value.standardized_relative_path.clone(),
            standardized_root_path: value.standardized_root_path.clone(),
            client_display_path: value.client_display_path.clone(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum PathClause {
    ExactFile {
        abs_path: String,
        rel_path: String,
        restricted_root_path: Option<String>,
    },
    ExactFolder {
        abs_lower: String,
        rel_lower: String,
        restricted_root_path: Option<String>,
    },
    Glob {
        pattern: String,
        restricted_root_path: Option<String>,
    },
    LegacyPrefix {
        candidate_lower: String,
    },
}

impl From<&PathClause> for runtime::PathClause {
    fn from(value: &PathClause) -> Self {
        match value {
            PathClause::ExactFile {
                abs_path,
                rel_path,
                restricted_root_path,
            } => Self::ExactFile {
                abs_path: abs_path.clone(),
                rel_path: rel_path.clone(),
                restricted_root_path: restricted_root_path.clone(),
            },
            PathClause::ExactFolder {
                abs_lower,
                rel_lower,
                restricted_root_path,
            } => Self::ExactFolder {
                abs_lower: abs_lower.clone(),
                rel_lower: rel_lower.clone(),
                restricted_root_path: restricted_root_path.clone(),
            },
            PathClause::Glob {
                pattern,
                restricted_root_path,
            } => Self::Glob {
                pattern: pattern.clone(),
                restricted_root_path: restricted_root_path.clone(),
            },
            PathClause::LegacyPrefix { candidate_lower } => Self::LegacyPrefix {
                candidate_lower: candidate_lower.clone(),
            },
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct PathFilterRequest {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub snapshots: Vec<PathSnapshot>,
    pub clauses: Vec<PathClause>,
    pub case_insensitive: bool,
}

impl PathFilterRequest {
    pub(crate) fn runtime_request(&self) -> runtime::PathFilterRequest {
        runtime::PathFilterRequest {
            snapshots: self.snapshots.iter().map(Into::into).collect(),
            clauses: self.clauses.iter().map(Into::into).collect(),
            case_insensitive: self.case_insensitive,
            cancellation: self.cancellation.runtime_handle().clone(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct PathDiagnostic {
    pub visited_snapshot_count: u64,
    pub matched_snapshot_count: u64,
    pub cancelled: bool,
}

impl From<runtime::PathDiagnostic> for PathDiagnostic {
    fn from(value: runtime::PathDiagnostic) -> Self {
        Self {
            visited_snapshot_count: value.visited_snapshot_count,
            matched_snapshot_count: value.matched_snapshot_count,
            cancelled: value.cancelled,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct PathFilterResult {
    pub matched_snapshot_indices: Vec<u32>,
    pub visited_snapshot_count: u64,
    pub cancelled: bool,
    pub diagnostic: PathDiagnostic,
}

impl From<runtime::PathFilterResult> for PathFilterResult {
    fn from(value: runtime::PathFilterResult) -> Self {
        Self {
            matched_snapshot_indices: value.matched_snapshot_indices,
            visited_snapshot_count: value.visited_snapshot_count,
            cancelled: value.cancelled,
            diagnostic: value.diagnostic.into(),
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FolderSuffixRequest {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub fragment: String,
    pub relative_paths: Vec<String>,
    pub case_insensitive: bool,
}

impl FolderSuffixRequest {
    pub(crate) fn runtime_request(&self) -> runtime::FolderSuffixRequest {
        runtime::FolderSuffixRequest {
            fragment: self.fragment.clone(),
            relative_paths: self.relative_paths.clone(),
            case_insensitive: self.case_insensitive,
            cancellation: self.cancellation.runtime_handle().clone(),
        }
    }
}
