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
    pub(crate) fn into_runtime_request(self) -> runtime::RegexSearchRequest {
        runtime::RegexSearchRequest {
            mode: self.mode.into(),
            pattern: self.pattern,
            subject: self.subject,
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

#[derive(Clone, Debug, uniffi::Record)]
pub struct RegexSearchBatchRequest {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub mode: RegexSearchMode,
    pub pattern: String,
    pub subjects: Vec<String>,
    pub case_insensitive: bool,
    pub whole_word: bool,
    pub multiline_anchors: bool,
    pub collect_matches: bool,
    pub max_collected_matches: Option<u32>,
    pub context_lines: u16,
    pub match_policy: MatchPolicy,
}

impl RegexSearchBatchRequest {
    pub(crate) fn into_runtime_requests(self) -> Vec<runtime::RegexSearchRequest> {
        let cancellation = self.cancellation.runtime_handle().clone();
        self.subjects
            .into_iter()
            .map(|subject| runtime::RegexSearchRequest {
                mode: self.mode.into(),
                pattern: self.pattern.clone(),
                subject,
                case_insensitive: self.case_insensitive,
                whole_word: self.whole_word,
                multiline_anchors: self.multiline_anchors,
                collect_matches: self.collect_matches,
                max_collected_matches: self.max_collected_matches,
                context_lines: self.context_lines,
                match_policy: self.match_policy.into(),
                cancellation: cancellation.clone(),
            })
            .collect()
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
pub struct CompactRegexSubjectSummary {
    pub line_range_start: u64,
    pub line_range_count: u64,
    pub hit_start: u64,
    pub hit_count: u64,
    pub matching_line_count: u64,
    pub cancelled: bool,
    pub engine: EngineKind,
    pub jit_status: JitStatus,
    pub cache_hit: bool,
    pub repair_kind: RepairKind,
    pub limit_policy: LimitPolicy,
    pub subject_byte_count: u64,
    pub line_count: u64,
    pub diagnostic_hit_count: u64,
    pub diagnostic_matching_line_count: u64,
    pub diagnostic_cancelled: bool,
    pub limit_failure: Option<LimitFailure>,
}

impl From<runtime::CompactRegexSubjectSummary> for CompactRegexSubjectSummary {
    fn from(value: runtime::CompactRegexSubjectSummary) -> Self {
        let diagnostic = value.diagnostic;
        Self {
            line_range_start: value.line_range_start,
            line_range_count: value.line_range_count,
            hit_start: value.hit_start,
            hit_count: value.hit_count,
            matching_line_count: value.matching_line_count,
            cancelled: value.cancelled,
            engine: diagnostic.engine.into(),
            jit_status: diagnostic.jit_status.into(),
            cache_hit: diagnostic.cache_hit,
            repair_kind: diagnostic.repair_kind.into(),
            limit_policy: diagnostic.limit_policy.into(),
            subject_byte_count: diagnostic.subject_byte_count,
            line_count: diagnostic.line_count,
            diagnostic_hit_count: diagnostic.hit_count,
            diagnostic_matching_line_count: diagnostic.matching_line_count,
            diagnostic_cancelled: diagnostic.cancelled,
            limit_failure: diagnostic.limit_failure.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CompactRegexBatchResult {
    pub subject_summaries: Vec<CompactRegexSubjectSummary>,
    pub line_range_words: Vec<u64>,
    pub hit_words: Vec<u64>,
}

impl From<runtime::CompactRegexBatchResult> for CompactRegexBatchResult {
    fn from(value: runtime::CompactRegexBatchResult) -> Self {
        Self {
            subject_summaries: value
                .subject_summaries
                .into_iter()
                .map(Into::into)
                .collect(),
            line_range_words: value.line_range_words,
            hit_words: value.hit_words,
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

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreCodeMapSourceKindV1 {
    Decoded,
    DecodeFailedUndecodable,
}

impl From<CoreCodeMapSourceKindV1> for runtime::codemap::CodeMapSourceKind {
    fn from(value: CoreCodeMapSourceKindV1) -> Self {
        match value {
            CoreCodeMapSourceKindV1::Decoded => Self::Decoded,
            CoreCodeMapSourceKindV1::DecodeFailedUndecodable => Self::DecodeFailedUndecodable,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreCodeMapSubjectRequestV1 {
    pub language_id: u16,
    pub source_kind: CoreCodeMapSourceKindV1,
    pub source_utf8: Vec<u8>,
}

impl From<CoreCodeMapSubjectRequestV1> for runtime::codemap::CodeMapSubjectRequestV1 {
    fn from(value: CoreCodeMapSubjectRequestV1) -> Self {
        Self {
            language_id: value.language_id,
            source_kind: value.source_kind.into(),
            source_utf8: value.source_utf8,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreCodeMapBatchRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub contract_version: u16,
    pub subjects: Vec<CoreCodeMapSubjectRequestV1>,
}

impl CoreCodeMapBatchRequestV1 {
    pub(crate) fn into_runtime_request(self) -> runtime::codemap::CodeMapBatchRequestV1 {
        runtime::codemap::CodeMapBatchRequestV1 {
            contract_version: self.contract_version,
            subjects: self.subjects.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, uniffi::Record)]
pub struct CoreCompactTableRangeV1 {
    pub start: u64,
    pub count: u64,
}

impl From<runtime::codemap::TableRange> for CoreCompactTableRangeV1 {
    fn from(value: runtime::codemap::TableRange) -> Self {
        Self {
            start: value.start,
            count: value.count,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreCompactCodeMapSubjectSummaryV1 {
    pub language_id: u16,
    pub source_byte_count: u64,
    pub outcome_tag: u64,
    pub outcome_actual: u64,
    pub outcome_limit: u64,
    pub blob: CoreCompactTableRangeV1,
    pub strings: CoreCompactTableRangeV1,
    pub string_indices: CoreCompactTableRangeV1,
    pub class_pool: CoreCompactTableRangeV1,
    pub interface_pool: CoreCompactTableRangeV1,
    pub alias_pool: CoreCompactTableRangeV1,
    pub function_pool: CoreCompactTableRangeV1,
    pub parameter_pool: CoreCompactTableRangeV1,
    pub property_pool: CoreCompactTableRangeV1,
    pub enum_pool: CoreCompactTableRangeV1,
    pub variable_pool: CoreCompactTableRangeV1,
    pub imports: CoreCompactTableRangeV1,
    pub exports: CoreCompactTableRangeV1,
    pub classes: CoreCompactTableRangeV1,
    pub interfaces: CoreCompactTableRangeV1,
    pub aliases: CoreCompactTableRangeV1,
    pub literal_unions: CoreCompactTableRangeV1,
    pub functions: CoreCompactTableRangeV1,
    pub enums: CoreCompactTableRangeV1,
    pub global_vars: CoreCompactTableRangeV1,
    pub macros: CoreCompactTableRangeV1,
    pub referenced_types: CoreCompactTableRangeV1,
}

impl From<runtime::codemap::CompactCodeMapSubjectSummaryV1> for CoreCompactCodeMapSubjectSummaryV1 {
    fn from(value: runtime::codemap::CompactCodeMapSubjectSummaryV1) -> Self {
        Self {
            language_id: value.language_id,
            source_byte_count: value.source_byte_count,
            outcome_tag: u64::from(value.outcome_tag as u16),
            outcome_actual: value.outcome_actual,
            outcome_limit: value.outcome_limit,
            blob: value.blob.into(),
            strings: value.strings.into(),
            string_indices: value.string_indices.into(),
            class_pool: value.class_pool.into(),
            interface_pool: value.interface_pool.into(),
            alias_pool: value.alias_pool.into(),
            function_pool: value.function_pool.into(),
            parameter_pool: value.parameter_pool.into(),
            property_pool: value.property_pool.into(),
            enum_pool: value.enum_pool.into(),
            variable_pool: value.variable_pool.into(),
            imports: value.imports.into(),
            exports: value.exports.into(),
            classes: value.classes.into(),
            interfaces: value.interfaces.into(),
            aliases: value.aliases.into(),
            literal_unions: value.literal_unions.into(),
            functions: value.functions.into(),
            enums: value.enums.into(),
            global_vars: value.global_vars.into(),
            macros: value.macros.into(),
            referenced_types: value.referenced_types.into(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreCompactCodeMapBatchResultV1 {
    pub subject_summaries: Vec<CoreCompactCodeMapSubjectSummaryV1>,
    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub string_index_words: Vec<u64>,
    pub class_words: Vec<u64>,
    pub interface_words: Vec<u64>,
    pub alias_words: Vec<u64>,
    pub function_words: Vec<u64>,
    pub parameter_words: Vec<u64>,
    pub property_words: Vec<u64>,
    pub enum_words: Vec<u64>,
    pub variable_words: Vec<u64>,
}

impl From<runtime::codemap::CompactCodeMapBatchResultV1> for CoreCompactCodeMapBatchResultV1 {
    fn from(value: runtime::codemap::CompactCodeMapBatchResultV1) -> Self {
        Self {
            subject_summaries: value
                .subject_summaries
                .into_iter()
                .map(Into::into)
                .collect(),
            utf8_blob: value.utf8_blob,
            string_range_words: value.string_range_words,
            string_index_words: value.string_index_words,
            class_words: value.class_words,
            interface_words: value.interface_words,
            alias_words: value.alias_words,
            function_words: value.function_words,
            parameter_words: value.parameter_words,
            property_words: value.property_words,
            enum_words: value.enum_words,
            variable_words: value.variable_words,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreApplyEditsOperationV1 {
    pub search: String,
    pub replace: String,
    pub replace_all: bool,
}

impl From<CoreApplyEditsOperationV1> for runtime::apply_edits::ApplyOperation {
    fn from(value: CoreApplyEditsOperationV1) -> Self {
        Self {
            search: value.search,
            replace: value.replace,
            replace_all: value.replace_all,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreApplyEditsSubjectRequestV1 {
    pub path_label: String,
    pub original_utf8: Vec<u8>,
    pub mode_tag: u64,
    pub rewrite_replacement: Option<String>,
    pub operations: Vec<CoreApplyEditsOperationV1>,
    pub verbose: bool,
    pub include_tool_card_unified_diff: bool,
}

impl CoreApplyEditsSubjectRequestV1 {
    fn into_runtime_request(self) -> Result<runtime::apply_edits::ApplySubjectRequest, CoreError> {
        let invalid_params = || CoreError::ApplyEditsInvalidParams {
            message: "invalid apply-edits request".into(),
        };
        let mode = match self.mode_tag {
            0 => {
                if !self.operations.is_empty() {
                    return Err(invalid_params());
                }
                runtime::apply_edits::ApplyMode::Rewrite {
                    replacement: self.rewrite_replacement.ok_or_else(&invalid_params)?,
                }
            }
            1 => {
                if self.rewrite_replacement.is_some() || self.operations.len() != 1 {
                    return Err(invalid_params());
                }
                let mut operations = self.operations.into_iter();
                runtime::apply_edits::ApplyMode::Single {
                    operation: operations.next().ok_or_else(&invalid_params)?.into(),
                }
            }
            2 => {
                if self.rewrite_replacement.is_some() || self.operations.is_empty() {
                    return Err(invalid_params());
                }
                runtime::apply_edits::ApplyMode::Batch {
                    operations: self.operations.into_iter().map(Into::into).collect(),
                }
            }
            _ => return Err(invalid_params()),
        };
        Ok(runtime::apply_edits::ApplySubjectRequest {
            path_label: self.path_label,
            original: self.original_utf8,
            mode,
            verbose: self.verbose,
            include_tool_card_unified_diff: self.include_tool_card_unified_diff,
        })
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreApplyEditsBatchRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub contract_version: u16,
    pub subjects: Vec<CoreApplyEditsSubjectRequestV1>,
}

impl CoreApplyEditsBatchRequestV1 {
    pub(crate) fn into_runtime_request(
        self,
    ) -> Result<runtime::apply_edits::ApplyEditsBatchRequestV1, CoreError> {
        Ok(runtime::apply_edits::ApplyEditsBatchRequestV1 {
            contract_version: self.contract_version,
            subjects: self
                .subjects
                .into_iter()
                .map(CoreApplyEditsSubjectRequestV1::into_runtime_request)
                .collect::<Result<_, _>>()?,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreCompactApplyEditsSubjectSummaryV1 {
    pub input_byte_count: u64,
    pub blob_start: u64,
    pub blob_count: u64,
    pub string_start: u64,
    pub string_count: u64,
    pub updated_text_string_index: u64,
    pub byte_edit_start: u64,
    pub byte_edit_count: u64,
    pub chunk_start: u64,
    pub chunk_count: u64,
    pub diff_line_start: u64,
    pub diff_line_count: u64,
    pub outcome_start: u64,
    pub outcome_count: u64,
    pub edits_requested: u64,
    pub edits_applied: u64,
    pub result_status_tag: u64,
    pub outcomes_present: bool,
    pub stats_present: bool,
    pub lines_changed: u64,
    pub stats_chunk_count: u64,
    pub note_string_index: u64,
    pub unified_diff_string_index: u64,
    pub tool_card_diff_string_index: u64,
}

impl From<runtime::apply_edits::CompactSubjectSummary> for CoreCompactApplyEditsSubjectSummaryV1 {
    fn from(value: runtime::apply_edits::CompactSubjectSummary) -> Self {
        Self {
            input_byte_count: value.input_byte_count,
            blob_start: value.blob_start,
            blob_count: value.blob_count,
            string_start: value.string_start,
            string_count: value.string_count,
            updated_text_string_index: value.updated_text_string_index,
            byte_edit_start: value.byte_edit_start,
            byte_edit_count: value.byte_edit_count,
            chunk_start: value.chunk_start,
            chunk_count: value.chunk_count,
            diff_line_start: value.diff_line_start,
            diff_line_count: value.diff_line_count,
            outcome_start: value.outcome_start,
            outcome_count: value.outcome_count,
            edits_requested: value.edits_requested,
            edits_applied: value.edits_applied,
            result_status_tag: value.result_status_tag,
            outcomes_present: value.outcomes_present,
            stats_present: value.stats_present,
            lines_changed: value.lines_changed,
            stats_chunk_count: value.stats_chunk_count,
            note_string_index: value.note_string_index,
            unified_diff_string_index: value.unified_diff_string_index,
            tool_card_diff_string_index: value.tool_card_diff_string_index,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreCompactApplyEditsBatchResultV1 {
    pub subject_summaries: Vec<CoreCompactApplyEditsSubjectSummaryV1>,
    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub byte_edit_words: Vec<u64>,
    pub chunk_words: Vec<u64>,
    pub diff_line_words: Vec<u64>,
    pub outcome_words: Vec<u64>,
}

impl From<runtime::apply_edits::CompactBatchResult> for CoreCompactApplyEditsBatchResultV1 {
    fn from(value: runtime::apply_edits::CompactBatchResult) -> Self {
        Self {
            subject_summaries: value
                .subject_summaries
                .into_iter()
                .map(Into::into)
                .collect(),
            utf8_blob: value.utf8_blob,
            string_range_words: value.string_range_words,
            byte_edit_words: value.byte_edit_words,
            chunk_words: value.chunk_words,
            diff_line_words: value.diff_line_words,
            outcome_words: value.outcome_words,
        }
    }
}

// ---- Inventory (P3-2) --------------------------------------------------------------------

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, uniffi::Record)]
pub struct CoreInventoryTableRangeV1 {
    pub start: u64,
    pub count: u64,
}

impl From<CoreInventoryTableRangeV1> for runtime::inventory::InventoryTableRange {
    fn from(value: CoreInventoryTableRangeV1) -> Self {
        Self {
            start: value.start,
            count: value.count,
        }
    }
}

impl From<runtime::inventory::InventoryTableRange> for CoreInventoryTableRangeV1 {
    fn from(value: runtime::inventory::InventoryTableRange) -> Self {
        Self {
            start: value.start,
            count: value.count,
        }
    }
}

/// Compact-v1 request driving all four `WorkspaceInventoryCatalogBuilders` ports
/// (`agentry_runtime::inventory`), tagged by `operation`. See
/// `rust/crates/runtime/src/inventory/compact.rs` for the pool-plus-ranges wire shape and which
/// fields each operation reads.
#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreInventoryComputeRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub contract_version: u16,
    pub operation: u16,

    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub string_index_words: Vec<u64>,
    pub uuid_words: Vec<u64>,

    pub root_words: Vec<u64>,
    pub file_words: Vec<u64>,
    pub folder_words: Vec<u64>,
    pub entry_words: Vec<u64>,
    pub shard_words: Vec<u64>,

    pub roots: CoreInventoryTableRangeV1,
    pub files_by_id: CoreInventoryTableRangeV1,
    pub folders_by_id: CoreInventoryTableRangeV1,
    pub managed_only_file_ids: CoreInventoryTableRangeV1,
    pub managed_only_folder_ids: CoreInventoryTableRangeV1,

    pub previous_files: CoreInventoryTableRangeV1,
    pub previous_folders: CoreInventoryTableRangeV1,
    pub event_root_id_hi: u64,
    pub event_root_id_lo: u64,
    pub event_upserted_files: CoreInventoryTableRangeV1,
    pub event_upserted_folders: CoreInventoryTableRangeV1,
    pub event_removed_file_ids: CoreInventoryTableRangeV1,
    pub event_removed_folder_ids: CoreInventoryTableRangeV1,
    pub event_removed_file_paths: CoreInventoryTableRangeV1,
    pub event_removed_folder_paths: CoreInventoryTableRangeV1,
    pub event_modified_file_ids: CoreInventoryTableRangeV1,
    pub event_modified_folder_ids: CoreInventoryTableRangeV1,
    pub max_logical_mutation_count: u64,

    pub shards: CoreInventoryTableRangeV1,
}

impl CoreInventoryComputeRequestV1 {
    pub(crate) fn into_runtime_request(self) -> runtime::inventory::InventoryComputeRequestV1 {
        runtime::inventory::InventoryComputeRequestV1 {
            contract_version: self.contract_version,
            operation: self.operation,
            utf8_blob: self.utf8_blob,
            string_range_words: self.string_range_words,
            string_index_words: self.string_index_words,
            uuid_words: self.uuid_words,
            root_words: self.root_words,
            file_words: self.file_words,
            folder_words: self.folder_words,
            entry_words: self.entry_words,
            shard_words: self.shard_words,
            roots: self.roots.into(),
            files_by_id: self.files_by_id.into(),
            folders_by_id: self.folders_by_id.into(),
            managed_only_file_ids: self.managed_only_file_ids.into(),
            managed_only_folder_ids: self.managed_only_folder_ids.into(),
            previous_files: self.previous_files.into(),
            previous_folders: self.previous_folders.into(),
            event_root_id_hi: self.event_root_id_hi,
            event_root_id_lo: self.event_root_id_lo,
            event_upserted_files: self.event_upserted_files.into(),
            event_upserted_folders: self.event_upserted_folders.into(),
            event_removed_file_ids: self.event_removed_file_ids.into(),
            event_removed_folder_ids: self.event_removed_folder_ids.into(),
            event_removed_file_paths: self.event_removed_file_paths.into(),
            event_removed_folder_paths: self.event_removed_folder_paths.into(),
            event_modified_file_ids: self.event_modified_file_ids.into(),
            event_modified_folder_ids: self.event_modified_folder_ids.into(),
            max_logical_mutation_count: self.max_logical_mutation_count,
            shards: self.shards.into(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreInventoryComputeResultV1 {
    pub operation: u16,

    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub uuid_words: Vec<u64>,
    pub file_words: Vec<u64>,
    pub folder_words: Vec<u64>,
    pub entry_words: Vec<u64>,

    pub components_files: CoreInventoryTableRangeV1,
    pub components_folders: CoreInventoryTableRangeV1,
    pub components_entries: CoreInventoryTableRangeV1,

    pub shard_patch_outcome: u16,
    pub shard_patch_files: CoreInventoryTableRangeV1,
    pub shard_patch_folders: CoreInventoryTableRangeV1,
    pub shard_patch_logical_mutation_count: u64,
    pub shard_patch_changed_file_ids: CoreInventoryTableRangeV1,

    pub merged_files: CoreInventoryTableRangeV1,
    pub merged_entries: CoreInventoryTableRangeV1,
}

impl From<runtime::inventory::InventoryComputeResultV1> for CoreInventoryComputeResultV1 {
    fn from(value: runtime::inventory::InventoryComputeResultV1) -> Self {
        Self {
            operation: value.operation,
            utf8_blob: value.utf8_blob,
            string_range_words: value.string_range_words,
            uuid_words: value.uuid_words,
            file_words: value.file_words,
            folder_words: value.folder_words,
            entry_words: value.entry_words,
            components_files: value.components_files.into(),
            components_folders: value.components_folders.into(),
            components_entries: value.components_entries.into(),
            shard_patch_outcome: value.shard_patch_outcome,
            shard_patch_files: value.shard_patch_files.into(),
            shard_patch_folders: value.shard_patch_folders.into(),
            shard_patch_logical_mutation_count: value.shard_patch_logical_mutation_count,
            shard_patch_changed_file_ids: value.shard_patch_changed_file_ids.into(),
            merged_files: value.merged_files.into(),
            merged_entries: value.merged_entries.into(),
        }
    }
}
