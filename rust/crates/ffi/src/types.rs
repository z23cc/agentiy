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

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreSearchScoreCandidateV1 {
    pub name: Vec<u8>,
    pub path: Vec<u8>,
    pub name_lower: Vec<u8>,
    pub path_lower: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreSearchScoreQueryV1 {
    pub raw: Vec<u8>,
    pub lowered: Vec<u8>,
    pub has_slash: bool,
    pub is_wildcard: bool,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreSearchScoreBatchRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub candidates: Vec<CoreSearchScoreCandidateV1>,
    pub query: CoreSearchScoreQueryV1,
    pub fuzzy_threshold: f64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreSearchScoreBatchResultV1 {
    pub scores: Vec<i32>,
}

/// Stable encoding identity returned by the standalone TD-5 text decoder.
#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreTextEncodingV1 {
    Utf8,
    Utf16BigEndian,
    Utf16LittleEndian,
    Utf32BigEndian,
    Utf32LittleEndian,
    Legacy,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreTextDecodeRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub raw_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreTextDecodeResultV1 {
    pub text: String,
    pub encoding: CoreTextEncodingV1,
    /// Canonical `encoding_rs` label for `Legacy`; absent for Unicode encodings.
    pub legacy_encoding_name: Option<String>,
    pub bom_present: bool,
    pub had_replacements: bool,
    pub policy_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceDocumentProjectionRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub document_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspacePersistenceMetadataRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub payload_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspacePersistenceMetadataValidationV1 {
    pub workspace_id: String,
    pub operation_id: String,
    pub schema_version: u16,
    pub content_digest: String,
    pub canonical_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspacePersistenceMetadataResponseV1 {
    pub validation: Option<CoreWorkspacePersistenceMetadataValidationV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCatalogValidationRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub catalog_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCatalogSeedRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub seed_request_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCatalogValidationV1 {
    pub catalog_version: u16,
    pub revision: u64,
    pub entry_count: u64,
    pub deletion_count: u64,
    pub content_digest: String,
    pub canonical_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCatalogResponseV1 {
    pub validation: Option<CoreWorkspaceCatalogValidationV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceCommandOriginV1 {
    AppPresentation { window_id: i64 },
    AppMcp { connection_id: Option<String> },
    Standalone,
    ExternalReload,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceCommandKindV1 {
    Create,
    Replace,
    Save,
    Delete,
    ResolveExternalConflict,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceTabLocationV1 {
    Composed,
    Stashed,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProtectedAgentIdentityV1 {
    pub tab_id: String,
    pub location: CoreWorkspaceTabLocationV1,
    pub active_agent_session_id: Option<String>,
    pub is_pinned: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCommandIdentityRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub operation_id: String,
    pub expected_catalog_revision: Option<u64>,
    pub expected_workspace_revision: Option<u64>,
    pub expected_context_revision: Option<u64>,
    pub origin: CoreWorkspaceCommandOriginV1,
    pub command_kind: CoreWorkspaceCommandKindV1,
    pub workspace_id: String,
    pub file_url: Option<String>,
    pub content_digest: Option<String>,
    pub accept_external: Option<bool>,
    pub protected_agent_identities: Vec<CoreWorkspaceProtectedAgentIdentityV1>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCommandIdentityV1 {
    pub workspace_id: String,
    pub command_kind: CoreWorkspaceCommandKindV1,
    pub fingerprint: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCommandIdentityResponseV1 {
    pub identity: Option<CoreWorkspaceCommandIdentityV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceRecordedOperationV1 {
    pub operation_id: String,
    pub fingerprint: String,
    pub recorded_at: f64,
    pub disposition: String,
    pub before: Option<CoreWorkspaceProjectionRevisionStateV1>,
    pub after: Option<CoreWorkspaceProjectionRevisionStateV1>,
    pub catalog_revision: u64,
    pub resulting_digest: Option<String>,
    pub error_code: Option<String>,
    pub diagnostic: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceRecoveryArtifactEvidenceV1 {
    Absent,
    Present { bytes: Vec<u8> },
    Unavailable { reason: String },
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticRecoveryEvidenceV1 {
    pub workspace_id: String,
    pub journal: CoreWorkspaceRecoveryArtifactEvidenceV1,
    pub saved_document: CoreWorkspaceRecoveryArtifactEvidenceV1,
    pub saved_revision: CoreWorkspaceRecoveryArtifactEvidenceV1,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticDeletionRecoveryEvidenceV1 {
    pub workspace_id: String,
    pub sidecar: CoreWorkspaceRecoveryArtifactEvidenceV1,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticFullRecoveryV1 {
    pub catalog_bytes: Vec<u8>,
    pub workspaces: Vec<CoreWorkspaceSemanticRecoveryEvidenceV1>,
    pub deletions: Vec<CoreWorkspaceSemanticDeletionRecoveryEvidenceV1>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticTargetRecoveryV1 {
    pub catalog_bytes: Vec<u8>,
    pub workspace_id: String,
    pub journal: CoreWorkspaceRecoveryArtifactEvidenceV1,
    pub saved_document: CoreWorkspaceRecoveryArtifactEvidenceV1,
    pub saved_revision: CoreWorkspaceRecoveryArtifactEvidenceV1,
    pub deletion_sidecar: CoreWorkspaceRecoveryArtifactEvidenceV1,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceSemanticRecoveryAdmissionDispositionV1 {
    Installed,
    Preserved,
    Quarantined,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticContextRecoveryV1 {
    pub context_id: String,
    pub revisions: CoreWorkspaceProjectionRevisionStateV1,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticContextTombstoneV1 {
    pub context_id: String,
    pub revision: u64,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticActiveRecoveryV1 {
    pub workspace_id: String,
    pub file_url: String,
    pub document_bytes: Vec<u8>,
    pub document_digest: String,
    pub saved_digest: String,
    pub revisions: CoreWorkspaceProjectionRevisionStateV1,
    pub context_revisions: Vec<CoreWorkspaceSemanticContextRecoveryV1>,
    pub context_tombstones: Vec<CoreWorkspaceSemanticContextTombstoneV1>,
    pub operations: Vec<CoreWorkspaceRecordedOperationV1>,
    pub health: CoreWorkspaceProjectionHealthV1,
    pub external_document_bytes: Option<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticUnavailableRecoveryV1 {
    pub workspace_id: String,
    pub file_url: String,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceSemanticRecoveryRowV1 {
    Active {
        row: CoreWorkspaceSemanticActiveRecoveryV1,
    },
    Unavailable {
        row: CoreWorkspaceSemanticUnavailableRecoveryV1,
    },
    Deleted {
        workspace_id: String,
        file_url: String,
    },
}

#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceSemanticTargetDirectiveV1 {
    Upsert {
        row: CoreWorkspaceSemanticActiveRecoveryV1,
    },
    Unavailable {
        row: CoreWorkspaceSemanticUnavailableRecoveryV1,
    },
    Delete {
        workspace_id: String,
        file_url: String,
    },
    NoChange,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticJournalRewriteV1 {
    pub workspace_id: String,
    pub expected_artifact_digest: String,
    pub replacement_canonical_bytes: Vec<u8>,
    pub replacement_canonical_digest: String,
}

#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceSemanticRecoveryProjectionV1 {
    Full {
        rows: Vec<CoreWorkspaceSemanticRecoveryRowV1>,
    },
    Target {
        directive: CoreWorkspaceSemanticTargetDirectiveV1,
    },
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticRecoveryPreviewV1 {
    pub catalog_revision: u64,
    pub catalog_digest: String,
    pub target_workspace_id: Option<String>,
    pub global_health: CoreWorkspaceProjectionHealthV1,
    pub admission_disposition: CoreWorkspaceSemanticRecoveryAdmissionDispositionV1,
    pub projection: CoreWorkspaceSemanticRecoveryProjectionV1,
    pub journal_rewrites: Vec<CoreWorkspaceSemanticJournalRewriteV1>,
    pub projection_digest: String,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticInitialRecoveryRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub recovery: CoreWorkspaceSemanticFullRecoveryV1,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceCommandAdmissionLookupScopeV1 {
    Workspace,
    Global,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceCommandAdmissionAcquireKindV1 {
    Claimed,
    Pending,
    Collision,
    Replay,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceCommandLifecycleDirectiveV1 {
    ContinueExecution,
    Cancelled,
    DeadlineExceeded,
    ShutdownRequested,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCommandAdmissionDiagnosticsV1 {
    pub global_operation_count: u64,
    pub workspace_count: u64,
    pub workspace_operation_count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCommandAdmissionRecoveryReceiptV1 {
    pub catalog_revision: u64,
    pub catalog_digest: String,
    pub target_workspace_id: Option<String>,
    pub diagnostics: CoreWorkspaceCommandAdmissionDiagnosticsV1,
}

impl From<CoreWorkspaceRecordedOperationV1>
    for runtime::workspace_persistence_journal::WorkspaceRecordedOperationV1
{
    fn from(value: CoreWorkspaceRecordedOperationV1) -> Self {
        Self {
            operation_id: value.operation_id,
            fingerprint: value.fingerprint,
            recorded_at: value.recorded_at,
            disposition: value.disposition,
            before: value.before.map(Into::into),
            after: value.after.map(Into::into),
            catalog_revision: value.catalog_revision,
            resulting_digest: value.resulting_digest,
            error_code: value.error_code,
            diagnostic: value.diagnostic,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceRecordedOperationV1>
    for CoreWorkspaceRecordedOperationV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceRecordedOperationV1) -> Self {
        Self {
            operation_id: value.operation_id,
            fingerprint: value.fingerprint,
            recorded_at: value.recorded_at,
            disposition: value.disposition,
            before: value.before.map(Into::into),
            after: value.after.map(Into::into),
            catalog_revision: value.catalog_revision,
            resulting_digest: value.resulting_digest,
            error_code: value.error_code,
            diagnostic: value.diagnostic,
        }
    }
}

impl From<CoreWorkspaceRecoveryArtifactEvidenceV1>
    for runtime::workspace_persistence_journal::WorkspaceRecoveryArtifactEvidenceV1
{
    fn from(value: CoreWorkspaceRecoveryArtifactEvidenceV1) -> Self {
        match value {
            CoreWorkspaceRecoveryArtifactEvidenceV1::Absent => Self::Absent,
            CoreWorkspaceRecoveryArtifactEvidenceV1::Present { bytes } => Self::Present(bytes),
            CoreWorkspaceRecoveryArtifactEvidenceV1::Unavailable { reason } => {
                Self::Unavailable(reason)
            }
        }
    }
}

impl From<CoreWorkspaceSemanticFullRecoveryV1>
    for runtime::workspace_persistence_journal::WorkspaceSemanticFullRecoveryV1
{
    fn from(value: CoreWorkspaceSemanticFullRecoveryV1) -> Self {
        Self {
            catalog_bytes: value.catalog_bytes,
            workspaces: value
                .workspaces
                .into_iter()
                .map(|workspace| runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryEvidenceV1 {
                    workspace_id: workspace.workspace_id,
                    journal: workspace.journal.into(),
                    saved_document: workspace.saved_document.into(),
                    saved_revision: workspace.saved_revision.into(),
                })
                .collect(),
            deletions: value
                .deletions
                .into_iter()
                .map(|deletion| runtime::workspace_persistence_journal::WorkspaceSemanticDeletionRecoveryEvidenceV1 {
                    workspace_id: deletion.workspace_id,
                    sidecar: deletion.sidecar.into(),
                })
                .collect(),
        }
    }
}

impl From<CoreWorkspaceSemanticTargetRecoveryV1>
    for runtime::workspace_persistence_journal::WorkspaceSemanticTargetRecoveryV1
{
    fn from(value: CoreWorkspaceSemanticTargetRecoveryV1) -> Self {
        Self {
            catalog_bytes: value.catalog_bytes,
            workspace_id: value.workspace_id,
            journal: value.journal.into(),
            saved_document: value.saved_document.into(),
            saved_revision: value.saved_revision.into(),
            deletion_sidecar: value.deletion_sidecar.into(),
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryAdmissionDispositionV1>
    for CoreWorkspaceSemanticRecoveryAdmissionDispositionV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryAdmissionDispositionV1,
    ) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryAdmissionDispositionV1 as RuntimeDisposition;
        match value {
            RuntimeDisposition::Installed => Self::Installed,
            RuntimeDisposition::Preserved => Self::Preserved,
            RuntimeDisposition::Quarantined => Self::Quarantined,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSemanticContextRecoveryV1>
    for CoreWorkspaceSemanticContextRecoveryV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceSemanticContextRecoveryV1,
    ) -> Self {
        Self {
            context_id: value.context_id,
            revisions: value.revisions.into(),
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSemanticActiveRecoveryV1>
    for CoreWorkspaceSemanticActiveRecoveryV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceSemanticActiveRecoveryV1,
    ) -> Self {
        Self {
            workspace_id: value.workspace_id,
            file_url: value.file_url,
            document_bytes: value.document_bytes,
            document_digest: value.document_digest,
            saved_digest: value.saved_digest,
            revisions: value.revisions.into(),
            context_revisions: value
                .context_revisions
                .into_iter()
                .map(Into::into)
                .collect(),
            context_tombstones: value
                .context_tombstones
                .into_iter()
                .map(
                    |(context_id, revision)| CoreWorkspaceSemanticContextTombstoneV1 {
                        context_id,
                        revision,
                    },
                )
                .collect(),
            operations: value.operations.into_iter().map(Into::into).collect(),
            health: value.health.into(),
            external_document_bytes: value.external_document_bytes,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSemanticUnavailableRecoveryV1>
    for CoreWorkspaceSemanticUnavailableRecoveryV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceSemanticUnavailableRecoveryV1,
    ) -> Self {
        Self {
            workspace_id: value.workspace_id,
            file_url: value.file_url,
            reason: value.reason,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryRowV1>
    for CoreWorkspaceSemanticRecoveryRowV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryRowV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryRowV1 as RuntimeRow;
        match value {
            RuntimeRow::Active { row } => Self::Active { row: row.into() },
            RuntimeRow::Unavailable { row } => Self::Unavailable { row: row.into() },
            RuntimeRow::Deleted {
                workspace_id,
                file_url,
            } => Self::Deleted {
                workspace_id,
                file_url,
            },
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSemanticTargetDirectiveV1>
    for CoreWorkspaceSemanticTargetDirectiveV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceSemanticTargetDirectiveV1,
    ) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceSemanticTargetDirectiveV1 as RuntimeDirective;
        match value {
            RuntimeDirective::Upsert { row } => Self::Upsert { row: row.into() },
            RuntimeDirective::Unavailable { row } => Self::Unavailable { row: row.into() },
            RuntimeDirective::Delete {
                workspace_id,
                file_url,
            } => Self::Delete {
                workspace_id,
                file_url,
            },
            RuntimeDirective::NoChange => Self::NoChange,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSemanticJournalRewriteV1>
    for CoreWorkspaceSemanticJournalRewriteV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceSemanticJournalRewriteV1,
    ) -> Self {
        Self {
            workspace_id: value.workspace_id,
            expected_artifact_digest: value.expected_artifact_digest,
            replacement_canonical_bytes: value.replacement_canonical_bytes,
            replacement_canonical_digest: value.replacement_canonical_digest,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryProjectionV1>
    for CoreWorkspaceSemanticRecoveryProjectionV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryProjectionV1,
    ) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryProjectionV1 as RuntimeProjection;
        match value {
            RuntimeProjection::Full { rows } => Self::Full {
                rows: rows.into_iter().map(Into::into).collect(),
            },
            RuntimeProjection::Target { directive } => Self::Target {
                directive: directive.into(),
            },
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryPreviewV1>
    for CoreWorkspaceSemanticRecoveryPreviewV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceSemanticRecoveryPreviewV1,
    ) -> Self {
        Self {
            catalog_revision: value.catalog_revision,
            catalog_digest: value.catalog_digest,
            target_workspace_id: value.target_workspace_id,
            global_health: value.global_health.into(),
            admission_disposition: value.admission_disposition.into(),
            projection: value.projection.into(),
            journal_rewrites: value.journal_rewrites.into_iter().map(Into::into).collect(),
            projection_digest: value.projection_digest,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionLookupScopeV1>
    for CoreWorkspaceCommandAdmissionLookupScopeV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceCommandAdmissionLookupScopeV1,
    ) -> Self {
        match value {
            runtime::workspace_persistence_journal::WorkspaceCommandAdmissionLookupScopeV1::Workspace => Self::Workspace,
            runtime::workspace_persistence_journal::WorkspaceCommandAdmissionLookupScopeV1::Global => Self::Global,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionRecoveryReceiptV1>
    for CoreWorkspaceCommandAdmissionRecoveryReceiptV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceCommandAdmissionRecoveryReceiptV1,
    ) -> Self {
        Self {
            catalog_revision: value.catalog_revision,
            catalog_digest: value.catalog_digest,
            target_workspace_id: value.target_workspace_id,
            diagnostics: value.diagnostics.into(),
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionDiagnosticsV1>
    for CoreWorkspaceCommandAdmissionDiagnosticsV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceCommandAdmissionDiagnosticsV1,
    ) -> Self {
        Self {
            global_operation_count: value.global_operation_count as u64,
            workspace_count: value.workspace_count as u64,
            workspace_operation_count: value.workspace_operation_count as u64,
        }
    }
}

impl From<CoreWorkspaceCommandOriginV1>
    for runtime::workspace_persistence_journal::WorkspaceCommandOriginV1
{
    fn from(value: CoreWorkspaceCommandOriginV1) -> Self {
        match value {
            CoreWorkspaceCommandOriginV1::AppPresentation { window_id } => {
                Self::AppPresentation { window_id }
            }
            CoreWorkspaceCommandOriginV1::AppMcp { connection_id } => {
                Self::AppMcp { connection_id }
            }
            CoreWorkspaceCommandOriginV1::Standalone => Self::Standalone,
            CoreWorkspaceCommandOriginV1::ExternalReload => Self::ExternalReload,
        }
    }
}

impl From<CoreWorkspaceCommandKindV1>
    for runtime::workspace_persistence_journal::WorkspaceCommandKindV1
{
    fn from(value: CoreWorkspaceCommandKindV1) -> Self {
        match value {
            CoreWorkspaceCommandKindV1::Create => Self::Create,
            CoreWorkspaceCommandKindV1::Replace => Self::Replace,
            CoreWorkspaceCommandKindV1::Save => Self::Save,
            CoreWorkspaceCommandKindV1::Delete => Self::Delete,
            CoreWorkspaceCommandKindV1::ResolveExternalConflict => Self::ResolveExternalConflict,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceCommandKindV1>
    for CoreWorkspaceCommandKindV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceCommandKindV1) -> Self {
        match value {
            runtime::workspace_persistence_journal::WorkspaceCommandKindV1::Create => Self::Create,
            runtime::workspace_persistence_journal::WorkspaceCommandKindV1::Replace => Self::Replace,
            runtime::workspace_persistence_journal::WorkspaceCommandKindV1::Save => Self::Save,
            runtime::workspace_persistence_journal::WorkspaceCommandKindV1::Delete => Self::Delete,
            runtime::workspace_persistence_journal::WorkspaceCommandKindV1::ResolveExternalConflict => {
                Self::ResolveExternalConflict
            }
        }
    }
}

impl From<CoreWorkspaceTabLocationV1>
    for runtime::workspace_persistence_journal::WorkspaceTabLocationV1
{
    fn from(value: CoreWorkspaceTabLocationV1) -> Self {
        match value {
            CoreWorkspaceTabLocationV1::Composed => Self::Composed,
            CoreWorkspaceTabLocationV1::Stashed => Self::Stashed,
        }
    }
}

impl From<CoreWorkspaceProtectedAgentIdentityV1>
    for runtime::workspace_persistence_journal::WorkspaceProtectedAgentIdentityV1
{
    fn from(value: CoreWorkspaceProtectedAgentIdentityV1) -> Self {
        Self {
            tab_id: value.tab_id,
            location: value.location.into(),
            active_agent_session_id: value.active_agent_session_id,
            is_pinned: value.is_pinned,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceCommandIdentityV1>
    for CoreWorkspaceCommandIdentityV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceCommandIdentityV1) -> Self {
        Self {
            workspace_id: value.workspace_id,
            command_kind: value.command_kind.into(),
            fingerprint: value.fingerprint,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceWorkingJournalValidationRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub journal_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceWorkingJournalSeedRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub seed_request_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceWorkingJournalValidationV1 {
    pub workspace_id: String,
    pub journal_version: u16,
    pub content_digest: String,
    pub canonical_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceJournalMutationTransactionRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub raw_journal_bytes: Option<Vec<u8>>,
    pub effective_journal_bytes: Vec<u8>,
    pub request_bytes: Vec<u8>,
    pub candidate_document_bytes: Vec<u8>,
    pub disk_document_bytes: Option<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSaveTransactionRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub raw_journal_bytes: Option<Vec<u8>>,
    pub effective_journal_bytes: Vec<u8>,
    pub request_bytes: Vec<u8>,
    pub candidate_document_bytes: Vec<u8>,
    pub disk_document_bytes: Option<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceDeleteTransactionRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub raw_catalog_bytes: Option<Vec<u8>>,
    pub effective_catalog_bytes: Vec<u8>,
    pub effective_journal_bytes: Vec<u8>,
    pub request_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCreateTransactionRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub raw_catalog_bytes: Option<Vec<u8>>,
    pub effective_catalog_bytes: Vec<u8>,
    pub raw_journal_bytes: Option<Vec<u8>>,
    pub effective_journal_bytes: Option<Vec<u8>>,
    pub request_bytes: Vec<u8>,
    pub document_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspacePendingSaveRecoveryRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub contract_version: u16,
    pub raw_journal_bytes: Vec<u8>,
    pub expected_workspace_id: String,
    pub expected_file_url: String,
    pub document_bytes: Option<Vec<u8>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceJournalMutationActionKindV1 {
    WriteJournal,
    WriteSavedRevision,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceJournalMutationFinalizationV1 {
    Finalized,
    RevisionSidecarMissing,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceJournalMutationCommitReceiptV1 {
    pub workspace_id: String,
    pub request_digest: String,
    pub catalog_revision: u64,
    pub committed_journal: CoreWorkspaceWorkingJournalValidationV1,
    pub saved_revision: Option<CoreWorkspacePersistenceMetadataValidationV1>,
    pub resulting_working_revision: u64,
    pub resulting_saved_revision: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceJournalMutationDirectiveV1 {
    Action {
        action_id: u64,
        request_digest: String,
        kind: CoreWorkspaceJournalMutationActionKindV1,
        expected_raw_journal_digest: Option<String>,
        canonical_bytes: Vec<u8>,
        content_digest: String,
        logical_expected_revision: Option<u64>,
        authority_receipt: Option<CoreWorkspaceJournalMutationCommitReceiptV1>,
        post_authority_success_finalization: Option<CoreWorkspaceJournalMutationFinalizationV1>,
        post_authority_failure_finalization: Option<CoreWorkspaceJournalMutationFinalizationV1>,
    },
    Committed {
        receipt: CoreWorkspaceJournalMutationCommitReceiptV1,
        finalization: CoreWorkspaceJournalMutationFinalizationV1,
    },
    Failed {
        failure: CoreWorkspaceSaveFailureV1,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceSaveActionKindV1 {
    WritePendingJournal,
    PublishWorkspaceDocument,
    WriteCommittedJournal,
    WriteSavedRevision,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceSaveFinalizationV1 {
    Finalized,
    PendingJournalRetained,
    RevisionSidecarMissing,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceSaveFailureV1 {
    Cancelled,
    StateConflict { expected: u64, actual: u64 },
    WriteFailed,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSaveCommitReceiptV1 {
    pub workspace_id: String,
    pub operation_id: String,
    pub request_digest: String,
    pub catalog_revision: u64,
    pub document_digest: String,
    pub committed_journal: CoreWorkspaceWorkingJournalValidationV1,
    pub saved_revision: CoreWorkspacePersistenceMetadataValidationV1,
    pub resulting_working_revision: u64,
    pub resulting_saved_revision: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceSaveDirectiveV1 {
    Action {
        action_id: u64,
        request_digest: String,
        kind: CoreWorkspaceSaveActionKindV1,
        expected_raw_journal_digest: Option<String>,
        canonical_bytes: Vec<u8>,
        content_digest: String,
        logical_expected_revision: Option<u64>,
        authority_receipt: Option<CoreWorkspaceSaveCommitReceiptV1>,
        post_authority_success_finalization: Option<CoreWorkspaceSaveFinalizationV1>,
        post_authority_failure_finalization: Option<CoreWorkspaceSaveFinalizationV1>,
    },
    Committed {
        receipt: CoreWorkspaceSaveCommitReceiptV1,
        finalization: CoreWorkspaceSaveFinalizationV1,
    },
    Failed {
        failure: CoreWorkspaceSaveFailureV1,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceSaveActionReportV1 {
    Success {
        action_id: u64,
        written_digest: String,
    },
    Cancelled {
        action_id: u64,
    },
    StateConflict {
        action_id: u64,
        expected: u64,
        actual: u64,
    },
    WriteFailed {
        action_id: u64,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceCreateActionKindV1 {
    WritePendingJournal,
    PublishWorkspaceDocument,
    WriteCommittedJournal,
    WriteSavedRevision,
    RemoveDeletionSidecar,
    PublishCatalog,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceCreateFailureV1 {
    Cancelled,
    StateConflict { expected: u64, actual: u64 },
    WriteFailed,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCreateCommitReceiptV1 {
    pub workspace_id: String,
    pub operation_id: String,
    pub request_digest: String,
    pub document_digest: String,
    pub catalog: CoreWorkspaceCatalogValidationV1,
    pub committed_journal: CoreWorkspaceWorkingJournalValidationV1,
    pub saved_revision: Option<CoreWorkspacePersistenceMetadataValidationV1>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceCreateDirectiveV1 {
    Action {
        action_id: u64,
        request_digest: String,
        kind: CoreWorkspaceCreateActionKindV1,
        expected_raw_digest: Option<String>,
        canonical_bytes: Vec<u8>,
        content_digest: String,
        logical_expected_revision: Option<u64>,
        authority_receipt: Option<CoreWorkspaceCreateCommitReceiptV1>,
    },
    Committed {
        receipt: CoreWorkspaceCreateCommitReceiptV1,
    },
    Failed {
        failure: CoreWorkspaceCreateFailureV1,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceDeleteActionKindV1 {
    PublishCatalog,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceDeleteFailureV1 {
    Cancelled,
    StateConflict { expected: u64, actual: u64 },
    WriteFailed,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceDeleteCommitReceiptV1 {
    pub workspace_id: String,
    pub operation_id: String,
    pub request_digest: String,
    pub catalog: CoreWorkspaceCatalogValidationV1,
    pub tombstone: CoreWorkspacePersistenceMetadataValidationV1,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceDeleteDirectiveV1 {
    Action {
        action_id: u64,
        request_digest: String,
        kind: CoreWorkspaceDeleteActionKindV1,
        expected_raw_catalog_digest: Option<String>,
        canonical_bytes: Vec<u8>,
        content_digest: String,
        logical_expected_revision: u64,
        authority_receipt: CoreWorkspaceDeleteCommitReceiptV1,
    },
    Committed {
        receipt: CoreWorkspaceDeleteCommitReceiptV1,
    },
    Failed {
        failure: CoreWorkspaceDeleteFailureV1,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspacePendingSaveRecoveryV1 {
    NoPending {
        journal: CoreWorkspaceWorkingJournalValidationV1,
    },
    PendingNotCommitted {
        journal: CoreWorkspaceWorkingJournalValidationV1,
    },
    Committed {
        clean_journal: CoreWorkspaceWorkingJournalValidationV1,
        document_digest: String,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceWorkingJournalValidationErrorKindV1 {
    InputTooLarge,
    OutputTooLarge,
    Malformed,
    FutureSchema,
    InvalidIdentity,
    DuplicateCatalogIdentity,
    InvalidFileUrl,
    InvalidRevisionState,
    InvalidDigest,
    InvalidWorkingDocument,
    InvalidContextTable,
    InvalidOperationLedger,
    InvalidPendingSave,
    InvalidTimestamp,
    ExternalDocumentConflict,
    StaleRecoverySnapshot,
    FullRecoveryRequired,
    InvalidTransaction,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceWorkingJournalValidationResponseV1 {
    pub validation: Option<CoreWorkspaceWorkingJournalValidationV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

impl From<runtime::workspace_persistence_journal::WorkspaceCatalogValidationV1>
    for CoreWorkspaceCatalogValidationV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceCatalogValidationV1) -> Self {
        Self {
            catalog_version: value.catalog_version,
            revision: value.revision,
            entry_count: value.entry_count as u64,
            deletion_count: value.deletion_count as u64,
            content_digest: value.content_digest,
            canonical_bytes: value.canonical_bytes,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspacePersistenceMetadataValidationV1>
    for CoreWorkspacePersistenceMetadataValidationV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspacePersistenceMetadataValidationV1,
    ) -> Self {
        Self {
            workspace_id: value.workspace_id,
            operation_id: value.operation_id,
            schema_version: value.schema_version,
            content_digest: value.content_digest,
            canonical_bytes: value.canonical_bytes,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceWorkingJournalValidationV1>
    for CoreWorkspaceWorkingJournalValidationV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceWorkingJournalValidationV1,
    ) -> Self {
        Self {
            workspace_id: value.workspace_id,
            journal_version: value.journal_version,
            content_digest: value.content_digest,
            canonical_bytes: value.canonical_bytes,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceJournalMutationCommitReceiptV1>
    for CoreWorkspaceJournalMutationCommitReceiptV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceJournalMutationCommitReceiptV1,
    ) -> Self {
        Self {
            workspace_id: value.workspace_id,
            request_digest: value.request_digest,
            catalog_revision: value.catalog_revision,
            committed_journal: value.committed_journal.into(),
            saved_revision: value.saved_revision.map(Into::into),
            resulting_working_revision: value.resulting_working_revision,
            resulting_saved_revision: value.resulting_saved_revision,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceJournalMutationDirectiveV1>
    for CoreWorkspaceJournalMutationDirectiveV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceJournalMutationDirectiveV1,
    ) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceJournalMutationDirectiveV1 as RuntimeDirective;
        match value {
            RuntimeDirective::Action {
                action_id,
                request_digest,
                kind,
                expected_raw_journal_digest,
                canonical_bytes,
                content_digest,
                logical_expected_revision,
                authority_receipt,
                post_authority_success_finalization,
                post_authority_failure_finalization,
            } => Self::Action {
                action_id,
                request_digest,
                kind: kind.into(),
                expected_raw_journal_digest,
                canonical_bytes,
                content_digest,
                logical_expected_revision,
                authority_receipt: authority_receipt.map(Into::into),
                post_authority_success_finalization: post_authority_success_finalization
                    .map(Into::into),
                post_authority_failure_finalization: post_authority_failure_finalization
                    .map(Into::into),
            },
            RuntimeDirective::Committed {
                receipt,
                finalization,
            } => Self::Committed {
                receipt: receipt.into(),
                finalization: finalization.into(),
            },
            RuntimeDirective::Failed { failure } => Self::Failed {
                failure: failure.into(),
            },
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceJournalMutationActionKindV1>
    for CoreWorkspaceJournalMutationActionKindV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceJournalMutationActionKindV1,
    ) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceJournalMutationActionKindV1 as RuntimeKind;
        match value {
            RuntimeKind::WriteJournal => Self::WriteJournal,
            RuntimeKind::WriteSavedRevision => Self::WriteSavedRevision,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceJournalMutationFinalizationV1>
    for CoreWorkspaceJournalMutationFinalizationV1
{
    fn from(
        value: runtime::workspace_persistence_journal::WorkspaceJournalMutationFinalizationV1,
    ) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceJournalMutationFinalizationV1 as RuntimeFinalization;
        match value {
            RuntimeFinalization::Finalized => Self::Finalized,
            RuntimeFinalization::RevisionSidecarMissing => Self::RevisionSidecarMissing,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSaveCommitReceiptV1>
    for CoreWorkspaceSaveCommitReceiptV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceSaveCommitReceiptV1) -> Self {
        Self {
            workspace_id: value.workspace_id,
            operation_id: value.operation_id,
            request_digest: value.request_digest,
            catalog_revision: value.catalog_revision,
            document_digest: value.document_digest,
            committed_journal: value.committed_journal.into(),
            saved_revision: value.saved_revision.into(),
            resulting_working_revision: value.resulting_working_revision,
            resulting_saved_revision: value.resulting_saved_revision,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSaveDirectiveV1>
    for CoreWorkspaceSaveDirectiveV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceSaveDirectiveV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceSaveDirectiveV1 as RuntimeDirective;
        match value {
            RuntimeDirective::Action {
                action_id,
                request_digest,
                kind,
                expected_raw_journal_digest,
                canonical_bytes,
                content_digest,
                logical_expected_revision,
                authority_receipt,
                post_authority_success_finalization,
                post_authority_failure_finalization,
            } => Self::Action {
                action_id,
                request_digest,
                kind: kind.into(),
                expected_raw_journal_digest,
                canonical_bytes,
                content_digest,
                logical_expected_revision,
                authority_receipt: authority_receipt.map(Into::into),
                post_authority_success_finalization: post_authority_success_finalization
                    .map(Into::into),
                post_authority_failure_finalization: post_authority_failure_finalization
                    .map(Into::into),
            },
            RuntimeDirective::Committed {
                receipt,
                finalization,
            } => Self::Committed {
                receipt: receipt.into(),
                finalization: finalization.into(),
            },
            RuntimeDirective::Failed { failure } => Self::Failed {
                failure: failure.into(),
            },
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSaveActionKindV1>
    for CoreWorkspaceSaveActionKindV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceSaveActionKindV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceSaveActionKindV1 as RuntimeKind;
        match value {
            RuntimeKind::WritePendingJournal => Self::WritePendingJournal,
            RuntimeKind::PublishWorkspaceDocument => Self::PublishWorkspaceDocument,
            RuntimeKind::WriteCommittedJournal => Self::WriteCommittedJournal,
            RuntimeKind::WriteSavedRevision => Self::WriteSavedRevision,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSaveFinalizationV1>
    for CoreWorkspaceSaveFinalizationV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceSaveFinalizationV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceSaveFinalizationV1 as RuntimeFinalization;
        match value {
            RuntimeFinalization::Finalized => Self::Finalized,
            RuntimeFinalization::PendingJournalRetained => Self::PendingJournalRetained,
            RuntimeFinalization::RevisionSidecarMissing => Self::RevisionSidecarMissing,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceSaveFailureV1>
    for CoreWorkspaceSaveFailureV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceSaveFailureV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceSaveFailureV1 as RuntimeFailure;
        match value {
            RuntimeFailure::Cancelled => Self::Cancelled,
            RuntimeFailure::StateConflict { expected, actual } => {
                Self::StateConflict { expected, actual }
            }
            RuntimeFailure::WriteFailed => Self::WriteFailed,
        }
    }
}

impl From<CoreWorkspaceSaveActionReportV1>
    for runtime::workspace_persistence_journal::WorkspaceSaveActionReportV1
{
    fn from(value: CoreWorkspaceSaveActionReportV1) -> Self {
        match value {
            CoreWorkspaceSaveActionReportV1::Success {
                action_id,
                written_digest,
            } => Self::Success {
                action_id,
                written_digest,
            },
            CoreWorkspaceSaveActionReportV1::Cancelled { action_id } => {
                Self::Cancelled { action_id }
            }
            CoreWorkspaceSaveActionReportV1::StateConflict {
                action_id,
                expected,
                actual,
            } => Self::StateConflict {
                action_id,
                expected,
                actual,
            },
            CoreWorkspaceSaveActionReportV1::WriteFailed { action_id } => {
                Self::WriteFailed { action_id }
            }
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceCreateCommitReceiptV1>
    for CoreWorkspaceCreateCommitReceiptV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceCreateCommitReceiptV1) -> Self {
        Self {
            workspace_id: value.workspace_id,
            operation_id: value.operation_id,
            request_digest: value.request_digest,
            document_digest: value.document_digest,
            catalog: value.catalog.into(),
            committed_journal: value.committed_journal.into(),
            saved_revision: value.saved_revision.map(Into::into),
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceCreateDirectiveV1>
    for CoreWorkspaceCreateDirectiveV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceCreateDirectiveV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceCreateDirectiveV1 as RuntimeDirective;
        match value {
            RuntimeDirective::Action {
                action_id,
                request_digest,
                kind,
                expected_raw_digest,
                canonical_bytes,
                content_digest,
                logical_expected_revision,
                authority_receipt,
            } => Self::Action {
                action_id,
                request_digest,
                kind: kind.into(),
                expected_raw_digest,
                canonical_bytes,
                content_digest,
                logical_expected_revision,
                authority_receipt: authority_receipt.map(Into::into),
            },
            RuntimeDirective::Committed { receipt } => Self::Committed {
                receipt: receipt.into(),
            },
            RuntimeDirective::Failed { failure } => Self::Failed {
                failure: failure.into(),
            },
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceCreateActionKindV1>
    for CoreWorkspaceCreateActionKindV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceCreateActionKindV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceCreateActionKindV1 as RuntimeKind;
        match value {
            RuntimeKind::WritePendingJournal => Self::WritePendingJournal,
            RuntimeKind::PublishWorkspaceDocument => Self::PublishWorkspaceDocument,
            RuntimeKind::WriteCommittedJournal => Self::WriteCommittedJournal,
            RuntimeKind::WriteSavedRevision => Self::WriteSavedRevision,
            RuntimeKind::RemoveDeletionSidecar => Self::RemoveDeletionSidecar,
            RuntimeKind::PublishCatalog => Self::PublishCatalog,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceCreateFailureV1>
    for CoreWorkspaceCreateFailureV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceCreateFailureV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceCreateFailureV1 as RuntimeFailure;
        match value {
            RuntimeFailure::Cancelled => Self::Cancelled,
            RuntimeFailure::StateConflict { expected, actual } => {
                Self::StateConflict { expected, actual }
            }
            RuntimeFailure::WriteFailed => Self::WriteFailed,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceDeleteCommitReceiptV1>
    for CoreWorkspaceDeleteCommitReceiptV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceDeleteCommitReceiptV1) -> Self {
        Self {
            workspace_id: value.workspace_id,
            operation_id: value.operation_id,
            request_digest: value.request_digest,
            catalog: value.catalog.into(),
            tombstone: value.tombstone.into(),
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceDeleteDirectiveV1>
    for CoreWorkspaceDeleteDirectiveV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceDeleteDirectiveV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceDeleteDirectiveV1 as RuntimeDirective;
        match value {
            RuntimeDirective::Action {
                action_id,
                request_digest,
                kind,
                expected_raw_catalog_digest,
                canonical_bytes,
                content_digest,
                logical_expected_revision,
                authority_receipt,
            } => Self::Action {
                action_id,
                request_digest,
                kind: kind.into(),
                expected_raw_catalog_digest,
                canonical_bytes,
                content_digest,
                logical_expected_revision,
                authority_receipt: authority_receipt.into(),
            },
            RuntimeDirective::Committed { receipt } => Self::Committed {
                receipt: receipt.into(),
            },
            RuntimeDirective::Failed { failure } => Self::Failed {
                failure: failure.into(),
            },
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceDeleteActionKindV1>
    for CoreWorkspaceDeleteActionKindV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceDeleteActionKindV1) -> Self {
        match value {
            runtime::workspace_persistence_journal::WorkspaceDeleteActionKindV1::PublishCatalog => {
                Self::PublishCatalog
            }
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspaceDeleteFailureV1>
    for CoreWorkspaceDeleteFailureV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspaceDeleteFailureV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspaceDeleteFailureV1 as RuntimeFailure;
        match value {
            RuntimeFailure::Cancelled => Self::Cancelled,
            RuntimeFailure::StateConflict { expected, actual } => {
                Self::StateConflict { expected, actual }
            }
            RuntimeFailure::WriteFailed => Self::WriteFailed,
        }
    }
}

impl From<runtime::workspace_persistence_journal::WorkspacePendingSaveRecoveryV1>
    for CoreWorkspacePendingSaveRecoveryV1
{
    fn from(value: runtime::workspace_persistence_journal::WorkspacePendingSaveRecoveryV1) -> Self {
        use runtime::workspace_persistence_journal::WorkspacePendingSaveRecoveryV1 as RuntimeRecovery;
        match value {
            RuntimeRecovery::NoPending { journal } => Self::NoPending {
                journal: journal.into(),
            },
            RuntimeRecovery::PendingNotCommitted { journal } => Self::PendingNotCommitted {
                journal: journal.into(),
            },
            RuntimeRecovery::Committed {
                clean_journal,
                document_digest,
            } => Self::Committed {
                clean_journal: clean_journal.into(),
                document_digest,
            },
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceContextProjectionV1 {
    pub context_id: String,
    pub name: String,
    pub active_agent_session_id: Option<String>,
    pub active_chat_session_id: Option<String>,
    pub prompt: String,
    pub selection: Vec<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceProjectionHealthKindV1 {
    Writable,
    ExternalConflict,
    DegradedReadOnly,
    Removed,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionHealthV1 {
    pub kind: CoreWorkspaceProjectionHealthKindV1,
    pub reason: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceContextAuthorityStateV1 {
    pub context_id: String,
    pub revisions: CoreWorkspaceProjectionRevisionStateV1,
    pub health: CoreWorkspaceProjectionHealthV1,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionAuthorityStateV1 {
    pub revisions: CoreWorkspaceProjectionRevisionStateV1,
    pub health: CoreWorkspaceProjectionHealthV1,
    pub contexts: Vec<CoreWorkspaceContextAuthorityStateV1>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceDocumentProjectionV1 {
    pub workspace_id: String,
    pub schema_version: i64,
    pub name: String,
    pub repo_paths: Vec<String>,
    pub active_context_id: Option<String>,
    pub contexts: Vec<CoreWorkspaceContextProjectionV1>,
    pub authority: Option<CoreWorkspaceProjectionAuthorityStateV1>,
}

impl From<runtime::workspace_context::WorkspaceDocumentProjection>
    for CoreWorkspaceDocumentProjectionV1
{
    fn from(value: runtime::workspace_context::WorkspaceDocumentProjection) -> Self {
        Self {
            workspace_id: value.workspace_id,
            schema_version: value.schema_version,
            name: value.name,
            repo_paths: value.repo_paths,
            active_context_id: value.active_context_id,
            contexts: value
                .contexts
                .into_iter()
                .map(|context| CoreWorkspaceContextProjectionV1 {
                    context_id: context.context_id,
                    name: context.name,
                    active_agent_session_id: context.active_agent_session_id,
                    active_chat_session_id: context.active_chat_session_id,
                    prompt: context.prompt,
                    selection: context.selection,
                })
                .collect(),
            authority: None,
        }
    }
}

impl From<&runtime::workspace_context::WorkspaceProjectionEntry>
    for CoreWorkspaceDocumentProjectionV1
{
    fn from(value: &runtime::workspace_context::WorkspaceProjectionEntry) -> Self {
        let mut projection: Self = value.projection.clone().into();
        projection.authority = value.authority.clone().map(Into::into);
        projection
    }
}

impl From<runtime::workspace_context::WorkspaceProjectionHealthKind>
    for CoreWorkspaceProjectionHealthKindV1
{
    fn from(value: runtime::workspace_context::WorkspaceProjectionHealthKind) -> Self {
        use runtime::workspace_context::WorkspaceProjectionHealthKind as RuntimeKind;
        match value {
            RuntimeKind::Writable => Self::Writable,
            RuntimeKind::ExternalConflict => Self::ExternalConflict,
            RuntimeKind::DegradedReadOnly => Self::DegradedReadOnly,
            RuntimeKind::Removed => Self::Removed,
        }
    }
}

impl From<CoreWorkspaceProjectionHealthKindV1>
    for runtime::workspace_context::WorkspaceProjectionHealthKind
{
    fn from(value: CoreWorkspaceProjectionHealthKindV1) -> Self {
        use runtime::workspace_context::WorkspaceProjectionHealthKind as RuntimeKind;
        match value {
            CoreWorkspaceProjectionHealthKindV1::Writable => RuntimeKind::Writable,
            CoreWorkspaceProjectionHealthKindV1::ExternalConflict => RuntimeKind::ExternalConflict,
            CoreWorkspaceProjectionHealthKindV1::DegradedReadOnly => RuntimeKind::DegradedReadOnly,
            CoreWorkspaceProjectionHealthKindV1::Removed => RuntimeKind::Removed,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionScopeConfigV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub maximum_workspace_count: u64,
    pub maximum_retained_bytes: u64,
    pub maximum_snapshot_handle_count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionScopeHandleV1 {
    pub scope_id: String,
    pub scope_incarnation: u64,
    pub generation: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionReplaceRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub scope_incarnation: u64,
    pub expected_generation: u64,
    pub document_bytes: Vec<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionUpsertRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub scope_incarnation: u64,
    pub expected_generation: u64,
    pub document_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionRemoveRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub scope_incarnation: u64,
    pub expected_generation: u64,
    pub workspace_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionMutationReceiptV1 {
    pub previous_generation: u64,
    pub generation: u64,
    pub changed: bool,
    pub workspace_count: u64,
    pub retained_bytes: u64,
}

impl From<runtime::workspace_context::WorkspaceProjectionMutationReceipt>
    for CoreWorkspaceProjectionMutationReceiptV1
{
    fn from(value: runtime::workspace_context::WorkspaceProjectionMutationReceipt) -> Self {
        Self {
            previous_generation: value.previous_generation,
            generation: value.generation,
            changed: value.changed,
            workspace_count: u64::try_from(value.snapshot.entries.len()).unwrap_or(u64::MAX),
            retained_bytes: u64::try_from(value.snapshot.retained_bytes).unwrap_or(u64::MAX),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceProjectionPublicationKindV1 {
    Bootstrapped,
    WorkspaceCreated,
    WorkspaceDeleted,
    WorkingStateCommitted,
    SavedDocumentCommitted,
    ExternalReloaded,
    ExternalConflict,
    Degraded,
    RoutingChanged,
    OperationDeduplicated,
}

impl From<CoreWorkspaceProjectionPublicationKindV1>
    for runtime::workspace_context::WorkspaceProjectionPublicationKind
{
    fn from(value: CoreWorkspaceProjectionPublicationKindV1) -> Self {
        use runtime::workspace_context::WorkspaceProjectionPublicationKind as RuntimeKind;
        match value {
            CoreWorkspaceProjectionPublicationKindV1::Bootstrapped => RuntimeKind::Bootstrapped,
            CoreWorkspaceProjectionPublicationKindV1::WorkspaceCreated => {
                RuntimeKind::WorkspaceCreated
            }
            CoreWorkspaceProjectionPublicationKindV1::WorkspaceDeleted => {
                RuntimeKind::WorkspaceDeleted
            }
            CoreWorkspaceProjectionPublicationKindV1::WorkingStateCommitted => {
                RuntimeKind::WorkingStateCommitted
            }
            CoreWorkspaceProjectionPublicationKindV1::SavedDocumentCommitted => {
                RuntimeKind::SavedDocumentCommitted
            }
            CoreWorkspaceProjectionPublicationKindV1::ExternalReloaded => {
                RuntimeKind::ExternalReloaded
            }
            CoreWorkspaceProjectionPublicationKindV1::ExternalConflict => {
                RuntimeKind::ExternalConflict
            }
            CoreWorkspaceProjectionPublicationKindV1::Degraded => RuntimeKind::Degraded,
            CoreWorkspaceProjectionPublicationKindV1::RoutingChanged => RuntimeKind::RoutingChanged,
            CoreWorkspaceProjectionPublicationKindV1::OperationDeduplicated => {
                RuntimeKind::OperationDeduplicated
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionRevisionStateV1 {
    pub working_revision: u64,
    pub saved_revision: u64,
    pub dirty_revision: Option<u64>,
}

impl From<CoreWorkspaceProjectionRevisionStateV1>
    for runtime::workspace_context::WorkspaceProjectionRevisionState
{
    fn from(value: CoreWorkspaceProjectionRevisionStateV1) -> Self {
        Self {
            working_revision: value.working_revision,
            saved_revision: value.saved_revision,
            dirty_revision: value.dirty_revision,
        }
    }
}

impl From<runtime::workspace_context::WorkspaceProjectionRevisionState>
    for CoreWorkspaceProjectionRevisionStateV1
{
    fn from(value: runtime::workspace_context::WorkspaceProjectionRevisionState) -> Self {
        Self {
            working_revision: value.working_revision,
            saved_revision: value.saved_revision,
            dirty_revision: value.dirty_revision,
        }
    }
}

impl From<CoreWorkspaceProjectionHealthV1>
    for runtime::workspace_context::WorkspaceProjectionHealth
{
    fn from(value: CoreWorkspaceProjectionHealthV1) -> Self {
        Self {
            kind: value.kind.into(),
            reason: value.reason,
        }
    }
}

impl From<runtime::workspace_context::WorkspaceProjectionHealth>
    for CoreWorkspaceProjectionHealthV1
{
    fn from(value: runtime::workspace_context::WorkspaceProjectionHealth) -> Self {
        Self {
            kind: value.kind.into(),
            reason: value.reason,
        }
    }
}

impl From<CoreWorkspaceProjectionAuthorityStateV1>
    for runtime::workspace_context::WorkspaceProjectionAuthorityState
{
    fn from(value: CoreWorkspaceProjectionAuthorityStateV1) -> Self {
        Self {
            revisions: value.revisions.into(),
            health: value.health.into(),
            contexts: value
                .contexts
                .into_iter()
                .map(
                    |context| runtime::workspace_context::WorkspaceContextAuthorityState {
                        context_id: context.context_id,
                        revisions: context.revisions.into(),
                        health: context.health.into(),
                    },
                )
                .collect(),
        }
    }
}

impl From<runtime::workspace_context::WorkspaceProjectionAuthorityState>
    for CoreWorkspaceProjectionAuthorityStateV1
{
    fn from(value: runtime::workspace_context::WorkspaceProjectionAuthorityState) -> Self {
        Self {
            revisions: value.revisions.into(),
            health: value.health.into(),
            contexts: value
                .contexts
                .into_iter()
                .map(|context| CoreWorkspaceContextAuthorityStateV1 {
                    context_id: context.context_id,
                    revisions: context.revisions.into(),
                    health: context.health.into(),
                })
                .collect(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionPublicationEventV1 {
    pub sequence: u64,
    pub catalog_revision: u64,
    pub kind: CoreWorkspaceProjectionPublicationKindV1,
    pub workspace_id: Option<String>,
    pub context_id: Option<String>,
    pub operation_id: Option<String>,
    pub revisions: Option<CoreWorkspaceProjectionRevisionStateV1>,
}

impl From<CoreWorkspaceProjectionPublicationEventV1>
    for runtime::workspace_context::WorkspaceProjectionPublicationEvent
{
    fn from(value: CoreWorkspaceProjectionPublicationEventV1) -> Self {
        Self {
            sequence: value.sequence,
            catalog_revision: value.catalog_revision,
            kind: value.kind.into(),
            workspace_id: value.workspace_id,
            context_id: value.context_id,
            operation_id: value.operation_id,
            revisions: value.revisions.map(Into::into),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionPublishRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub scope_incarnation: u64,
    pub expected_generation: u64,
    pub expected_catalog_revision: u64,
    pub expected_publication_sequence: u64,
    pub rebased: bool,
    pub document_bytes: Vec<Vec<u8>>,
    pub event: CoreWorkspaceProjectionPublicationEventV1,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionPublishedWorkspaceV1 {
    pub document_bytes: Vec<u8>,
    pub authority: CoreWorkspaceProjectionAuthorityStateV1,
}

impl From<CoreWorkspaceProjectionPublishedWorkspaceV1>
    for runtime::workspace_context::WorkspaceProjectionPublishedWorkspace
{
    fn from(value: CoreWorkspaceProjectionPublishedWorkspaceV1) -> Self {
        Self {
            document_bytes: value.document_bytes,
            authority: value.authority.into(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionPublishAuthoritativeRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub scope_incarnation: u64,
    pub expected_generation: u64,
    pub expected_catalog_revision: u64,
    pub expected_publication_sequence: u64,
    pub rebased: bool,
    pub workspaces: Vec<CoreWorkspaceProjectionPublishedWorkspaceV1>,
    pub event: CoreWorkspaceProjectionPublicationEventV1,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionUpsertAuthoritativeRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub scope_incarnation: u64,
    pub expected_generation: u64,
    pub expected_catalog_revision: u64,
    pub expected_publication_sequence: u64,
    pub workspace: CoreWorkspaceProjectionPublishedWorkspaceV1,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionPublicationReceiptV1 {
    pub previous_generation: u64,
    pub generation: u64,
    pub projection_changed: bool,
    pub workspace_count: u64,
    pub retained_bytes: u64,
    pub previous_catalog_revision: u64,
    pub previous_publication_sequence: u64,
    pub catalog_revision: u64,
    pub publication_sequence: u64,
    pub event_log_floor_sequence: u64,
    pub event_log_count: u64,
    pub rebased: bool,
}

impl From<runtime::workspace_context::WorkspaceProjectionPublicationReceipt>
    for CoreWorkspaceProjectionPublicationReceiptV1
{
    fn from(value: runtime::workspace_context::WorkspaceProjectionPublicationReceipt) -> Self {
        Self {
            previous_generation: value.projection.previous_generation,
            generation: value.projection.generation,
            projection_changed: value.projection.changed,
            workspace_count: u64::try_from(value.projection.snapshot.entries.len())
                .unwrap_or(u64::MAX),
            retained_bytes: u64::try_from(value.projection.snapshot.retained_bytes)
                .unwrap_or(u64::MAX),
            previous_catalog_revision: value.previous_catalog_revision,
            previous_publication_sequence: value.previous_publication_sequence,
            catalog_revision: value.catalog_revision,
            publication_sequence: value.publication_sequence,
            event_log_floor_sequence: value.event_log_floor_sequence,
            event_log_count: u64::try_from(value.event_log_count).unwrap_or(u64::MAX),
            rebased: value.rebased,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionRestoreCheckpointRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub scope_incarnation: u64,
    pub checkpoint_bytes: Vec<u8>,
    pub begin_new_publication_epoch: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionRestoreCheckpointReceiptV1 {
    pub generation: u64,
    pub workspace_count: u64,
    pub retained_bytes: u64,
    pub catalog_revision: u64,
    pub publication_sequence: u64,
    pub event_log_floor_sequence: u64,
    pub event_log_count: u64,
    pub began_new_publication_epoch: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionSnapshotRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub scope_incarnation: u64,
    pub expected_generation: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionSnapshotHandleV1 {
    pub handle_id: u64,
    pub generation: u64,
    pub workspace_count: u64,
    pub retained_bytes: u64,
    pub catalog_revision: u64,
    pub publication_sequence: u64,
    pub event_log_floor_sequence: u64,
    pub event_log_count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionSnapshotPageV1 {
    pub generation: u64,
    pub offset: u64,
    pub returned_count: u64,
    pub has_more: bool,
    pub workspaces: Vec<CoreWorkspaceDocumentProjectionV1>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceProjectionDiagnosticsV1 {
    pub generation: u64,
    pub open_snapshot_handle_count: u64,
    pub catalog_revision: u64,
    pub publication_sequence: u64,
    pub event_log_floor_sequence: u64,
    pub event_log_count: u64,
}

impl From<runtime::textdecode::TextDecodeOutcome> for CoreTextDecodeResultV1 {
    fn from(value: runtime::textdecode::TextDecodeOutcome) -> Self {
        let (encoding, legacy_encoding_name) = match value.detected_encoding {
            runtime::textdecode::DetectedEncoding::Utf8 => (CoreTextEncodingV1::Utf8, None),
            runtime::textdecode::DetectedEncoding::Utf16 {
                endian: runtime::textdecode::Endian::Big,
            } => (CoreTextEncodingV1::Utf16BigEndian, None),
            runtime::textdecode::DetectedEncoding::Utf16 {
                endian: runtime::textdecode::Endian::Little,
            } => (CoreTextEncodingV1::Utf16LittleEndian, None),
            runtime::textdecode::DetectedEncoding::Utf32 {
                endian: runtime::textdecode::Endian::Big,
            } => (CoreTextEncodingV1::Utf32BigEndian, None),
            runtime::textdecode::DetectedEncoding::Utf32 {
                endian: runtime::textdecode::Endian::Little,
            } => (CoreTextEncodingV1::Utf32LittleEndian, None),
            runtime::textdecode::DetectedEncoding::Legacy(encoding) => {
                (CoreTextEncodingV1::Legacy, Some(encoding.name().to_owned()))
            }
        };
        Self {
            text: value.text,
            encoding,
            legacy_encoding_name,
            bom_present: matches!(value.bom, runtime::textdecode::BomDisposition::Present(_)),
            had_replacements: value.had_replacements,
            policy_id: value.policy_version.canonical_id().to_owned(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreCodeMapSourceKindV1 {
    Decoded,
    DecodeFailedUndecodable,
    /// TD-3 (design §6.1): `source_utf8` carries genuinely raw, possibly-non-UTF-8 bytes;
    /// `textdecode` (never fails) runs as codemap's first step instead of a strict UTF-8 check.
    Raw,
}

impl From<CoreCodeMapSourceKindV1> for runtime::codemap::CodeMapSourceKind {
    fn from(value: CoreCodeMapSourceKindV1) -> Self {
        match value {
            CoreCodeMapSourceKindV1::Decoded => Self::Decoded,
            CoreCodeMapSourceKindV1::DecodeFailedUndecodable => Self::DecodeFailedUndecodable,
            CoreCodeMapSourceKindV1::Raw => Self::Raw,
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

/// TD-3 §6.1/F2: `DecodedUtf8` is the existing, GUI-apply-edits-depended-upon path --
/// `original_utf8` is already-decoded UTF-8 text bytes, strictly re-validated Rust-side
/// (unchanged). `Raw` is the additive ladder-6 (headless `agentry-mcp`, D-6) construction path --
/// `original_utf8` carries genuinely raw disk bytes; `textdecode` runs as apply-edits' first
/// step, preserving the single-FFI-crossing shape (design §6.1, round-2 Finding F2).
#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreApplyEditsSourceKindV1 {
    DecodedUtf8,
    Raw,
}

impl From<CoreApplyEditsSourceKindV1> for runtime::apply_edits::ApplySourceKind {
    fn from(value: CoreApplyEditsSourceKindV1) -> Self {
        match value {
            CoreApplyEditsSourceKindV1::DecodedUtf8 => Self::DecodedUtf8,
            CoreApplyEditsSourceKindV1::Raw => Self::Raw,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreApplyEditsSubjectRequestV1 {
    pub path_label: String,
    pub original_utf8: Vec<u8>,
    pub source_kind: CoreApplyEditsSourceKindV1,
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
            source_kind: self.source_kind.into(),
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
    pub original_text_string_index: u64,
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
            original_text_string_index: value.original_text_string_index,
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

// ---- Inventory (P3-2) -- retired at P4-8, superseded by inventory-scope-v1 below ---------
//
// The whole-table `inventory-compute-v1` wire (`CoreInventoryTableRangeV1`,
// `CoreInventoryComputeRequestV1`/`ResultV1`, and their `From` impls into
// `agentry_runtime::inventory::{InventoryTableRange, InventoryComputeRequestV1,
// InventoryComputeResultV1}`) was deleted here along with its Rust-side codec
// (`agentry_runtime::inventory::compact`/`contract`) and Swift-side FFI seam
// (`RustInventoryComputer`, `CoreComputeClient.inventoryBuild*`, `CoreRuntime.inventory_compute_v1`
// / `inventoryComputeV1`). Superseded by the stateful `inventory-scope-v1` surface immediately
// below.

// ---- Path match (P3-3 slice 1) -------------------------------------------------------------

/// Compact-v1 batch request driving `PathMatchScoreService` (`agentry_runtime::pathmatch`). See
/// `rust/crates/runtime/src/pathmatch/score.rs` for the pool-plus-ranges wire shape and the
/// scoring-kernel scope-boundary documentation (what is/isn't ported vs. kept Swift-side).
#[derive(Clone, Debug, uniffi::Record)]
pub struct CorePathMatchScoreRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub contract_version: u16,
    pub threshold: f64,

    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub char_count_words: Vec<u64>,
    pub cleaned_byte_len_words: Vec<u64>,

    pub query_indices: Vec<u64>,

    pub candidate_words: Vec<u64>,
    pub candidate_tail_indices: Vec<u64>,

    pub selected_root_ordinals: Vec<u64>,
}

impl CorePathMatchScoreRequestV1 {
    pub(crate) fn into_runtime_request(self) -> runtime::pathmatch::PathMatchScoreRequestV1 {
        runtime::pathmatch::PathMatchScoreRequestV1 {
            contract_version: self.contract_version,
            threshold: self.threshold,
            utf8_blob: self.utf8_blob,
            string_range_words: self.string_range_words,
            char_count_words: self.char_count_words,
            cleaned_byte_len_words: self.cleaned_byte_len_words,
            query_indices: self.query_indices,
            candidate_words: self.candidate_words,
            candidate_tail_indices: self.candidate_tail_indices,
            selected_root_ordinals: self.selected_root_ordinals,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CorePathMatchScoreResultV1 {
    pub matched_ordinals: Vec<u64>,
    pub matched_scores_scaled: Vec<i64>,
    pub matched_scores_bits: Vec<u64>,
}

impl From<runtime::pathmatch::PathMatchScoreResultV1> for CorePathMatchScoreResultV1 {
    fn from(value: runtime::pathmatch::PathMatchScoreResultV1) -> Self {
        Self {
            matched_ordinals: value.matched_ordinals,
            matched_scores_scaled: value.matched_scores_scaled,
            matched_scores_bits: value.matched_scores_bits,
        }
    }
}

// ---- Path resolve (P3-3 slice 2a) ---------------------------------------------------------

/// Compact-v1 batch request driving `PathMatchResolveService` (`agentry_runtime::pathmatch`) --
/// the full `PathMatcher.locate` resolution ladder over one immutable snapshot, batched exactly
/// like `PathMatchWorker.locateMany`. See `rust/crates/runtime/src/pathmatch/indexes.rs` for the
/// pool-plus-tables wire shape and the Foundation/ICU/filesystem scope-boundary documentation.
#[derive(Clone, Debug, uniffi::Record)]
pub struct CorePathMatchResolveRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub contract_version: u16,

    pub case_sensitive: bool,
    pub exact_match_only: bool,
    pub allow_leading_root_alias_trim: bool,
    pub allow_head_trim_aliases: bool,
    pub allow_absolute_suffix_fallback: bool,

    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub char_count_words: Vec<u64>,
    pub cleaned_byte_len_words: Vec<u64>,

    pub root_words: Vec<u64>,
    pub file_words: Vec<u64>,
    pub folder_words: Vec<u64>,
    pub component_indices: Vec<u64>,

    pub selected_file_full_path_indices: Vec<u64>,

    pub query_words: Vec<u64>,
    pub query_canonical_component_indices: Vec<u64>,
    pub query_cleaned_lower_component_indices: Vec<u64>,
}

impl CorePathMatchResolveRequestV1 {
    pub(crate) fn into_runtime_request(self) -> runtime::pathmatch::PathMatchResolveRequestV1 {
        runtime::pathmatch::PathMatchResolveRequestV1 {
            contract_version: self.contract_version,
            case_sensitive: self.case_sensitive,
            exact_match_only: self.exact_match_only,
            allow_leading_root_alias_trim: self.allow_leading_root_alias_trim,
            allow_head_trim_aliases: self.allow_head_trim_aliases,
            allow_absolute_suffix_fallback: self.allow_absolute_suffix_fallback,
            utf8_blob: self.utf8_blob,
            string_range_words: self.string_range_words,
            char_count_words: self.char_count_words,
            cleaned_byte_len_words: self.cleaned_byte_len_words,
            root_words: self.root_words,
            file_words: self.file_words,
            folder_words: self.folder_words,
            component_indices: self.component_indices,
            selected_file_full_path_indices: self.selected_file_full_path_indices,
            query_words: self.query_words,
            query_canonical_component_indices: self.query_canonical_component_indices,
            query_cleaned_lower_component_indices: self.query_cleaned_lower_component_indices,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CorePathMatchResolveLocationV1 {
    pub root_ordinal: u64,
    pub corrected_path: String,
}

impl From<runtime::pathmatch::PathMatchResolveLocation> for CorePathMatchResolveLocationV1 {
    fn from(value: runtime::pathmatch::PathMatchResolveLocation) -> Self {
        Self {
            root_ordinal: value.root_ordinal,
            corrected_path: value.corrected_path,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CorePathMatchResolveResultV1 {
    /// Index-aligned with the request's queries (`query_words`, stride `QUERY_STRIDE`). `None`
    /// for a query that found no match -- mirrors `PathMatchLocation?`.
    pub locations: Vec<Option<CorePathMatchResolveLocationV1>>,
}

impl From<runtime::pathmatch::PathMatchResolveResultV1> for CorePathMatchResolveResultV1 {
    fn from(value: runtime::pathmatch::PathMatchResolveResultV1) -> Self {
        Self {
            locations: value
                .locations
                .into_iter()
                .map(|loc| loc.map(Into::into))
                .collect(),
        }
    }
}

// ---- Path search (P3-3 slice 2b phase 2, DIFFERENTIAL-ONLY) ------------------------------

/// Compact-v1 batch request driving `PathSearchFindService` (`agentry_runtime::pathsearch`) --
/// a whole corpus plus a batch of queries in ONE call. See
/// `rust/crates/runtime/src/pathsearch/wire.rs`'s module doc for the pool-plus-flat-corpus wire
/// shape and, critically, why this is a DIFFERENTIAL-TEST-ONLY shape rather than the eventual
/// production entry point (production needs the P4 stateful scope-registry handle primitive).
#[derive(Clone, Debug, uniffi::Record)]
pub struct CorePathSearchFindRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub contract_version: u16,

    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub corpus_path_indices: Vec<u64>,
    pub query_words: Vec<u64>,
}

impl CorePathSearchFindRequestV1 {
    pub(crate) fn into_runtime_request(self) -> runtime::pathsearch::PathSearchFindRequestV1 {
        runtime::pathsearch::PathSearchFindRequestV1 {
            contract_version: self.contract_version,
            utf8_blob: self.utf8_blob,
            string_range_words: self.string_range_words,
            corpus_path_indices: self.corpus_path_indices,
            query_words: self.query_words,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CorePathSearchFindResultV1 {
    pub result_ordinals: Vec<u64>,
    pub result_range_words: Vec<u64>,
    pub stats_words: Vec<u64>,
}

impl From<runtime::pathsearch::PathSearchFindResponseV1> for CorePathSearchFindResultV1 {
    fn from(value: runtime::pathsearch::PathSearchFindResponseV1) -> Self {
        Self {
            result_ordinals: value.result_ordinals,
            result_range_words: value.result_range_words,
            stats_words: value.stats_words,
        }
    }
}

// ---- Token accounting (P3-4, DIFFERENTIAL-ONLY) --------------------------------------------

/// Compact-v1 batch request driving `TokenAccountingService` (`agentry_runtime::tokenacct`) --
/// a batch of entry rows plus a batch of component-breakdown rows in ONE call. See
/// `rust/crates/runtime/src/tokenacct/wire.rs`'s module doc for the wire shape and, critically,
/// why this is a DIFFERENTIAL-TEST-ONLY shape rather than the eventual production entry point.
#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreTokenAccountingRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub cancellation: std::sync::Arc<crate::api::LeafCancellation>,
    pub contract_version: u16,

    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub entry_words: Vec<u64>,
    pub component_words: Vec<u64>,
}

impl CoreTokenAccountingRequestV1 {
    pub(crate) fn into_runtime_request(self) -> runtime::tokenacct::TokenAccountingRequestV1 {
        runtime::tokenacct::TokenAccountingRequestV1 {
            contract_version: self.contract_version,
            utf8_blob: self.utf8_blob,
            string_range_words: self.string_range_words,
            entry_words: self.entry_words,
            component_words: self.component_words,
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CoreTokenAccountingResultV1 {
    pub entry_result_words: Vec<u64>,
    pub entry_formatted: Vec<String>,
    pub entry_percentage: Vec<f64>,
    pub aggregate_words: Vec<u64>,
    pub combined_display_tokens: u64,
    pub total_display_tokens: u64,
    pub code_map_content: String,
    pub code_map_file_count: u64,
    pub code_map_token_count: u64,
    pub folder_names: Vec<String>,
    pub folder_token_counts: Vec<u64>,
    pub folder_formatted: Vec<String>,
    pub folder_percentage: Vec<f64>,
    pub component_result_words: Vec<u64>,
}

impl From<runtime::tokenacct::TokenAccountingResponseV1> for CoreTokenAccountingResultV1 {
    fn from(value: runtime::tokenacct::TokenAccountingResponseV1) -> Self {
        Self {
            entry_result_words: value.entry_result_words,
            entry_formatted: value.entry_formatted,
            entry_percentage: value.entry_percentage,
            aggregate_words: value.aggregate_words,
            combined_display_tokens: value.combined_display_tokens,
            total_display_tokens: value.total_display_tokens,
            code_map_content: value.code_map_content,
            code_map_file_count: value.code_map_file_count,
            code_map_token_count: value.code_map_token_count,
            folder_names: value.folder_names,
            folder_token_counts: value.folder_token_counts,
            folder_formatted: value.folder_formatted,
            folder_percentage: value.folder_percentage,
            component_result_words: value.component_result_words,
        }
    }
}

// ================================================================================================
// P4-4: `inventory-scope-v1` FFI surface (contract doc §5.3; design §11 P4-4). `RootId` is
// `agentry_runtime::inventory::InventoryUuid` (`[u8; 16]`), exposed here as `Vec<u8>` (matching
// how file/folder/root ids already round-trip through the crate's other inventory surfaces).
// `InventoryScopeId`/`RootLifetimeId` are scope-minted (never caller-supplied) and exposed as
// their `Display` impl's 32-lowercase-hex-char form, parsed back by `parse_hex16`. Deliberate
// divergence from the contract's model-level pseudocode, flagged once here rather than at every
// call site: `ScopeRegistry` holds multiple concurrently open scopes with independently-counted
// `SnapshotHandleId`/`BulkLoadId` values, so every handle-based call below also takes an explicit
// `scope_id` to route to the right `InventoryScope` -- the contract's pseudocode omits it because
// it describes the model from inside one already-selected `InventoryScope`.
// ================================================================================================

pub(crate) fn parse_root_id(bytes: &[u8]) -> Result<runtime::inventory_scope::RootId, CoreError> {
    <[u8; 16]>::try_from(bytes).map_err(|_| CoreError::InventoryScopeInvalidRequest {
        message: "root_id must be exactly 16 bytes".to_owned(),
    })
}

fn parse_hex16<T>(
    value: &str,
    from_bytes: impl FnOnce([u8; 16]) -> T,
    field: &'static str,
) -> Result<T, CoreError> {
    if value.len() != 32 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(CoreError::InventoryScopeInvalidRequest {
            message: format!("{field} must be 32 lowercase hex characters"),
        });
    }
    let mut bytes = [0u8; 16];
    for (index, chunk) in value.as_bytes().chunks_exact(2).enumerate() {
        let text = std::str::from_utf8(chunk).expect("ascii hexdigit checked above");
        bytes[index] =
            u8::from_str_radix(text, 16).map_err(|_| CoreError::InventoryScopeInvalidRequest {
                message: format!("{field} contains invalid hex"),
            })?;
    }
    Ok(from_bytes(bytes))
}

pub(crate) fn parse_inventory_scope_id(
    value: &str,
) -> Result<runtime::inventory_scope::InventoryScopeId, CoreError> {
    parse_hex16(
        value,
        runtime::inventory_scope::InventoryScopeId::from_bytes,
        "scope_id",
    )
}

pub(crate) fn parse_root_lifetime_id(
    value: &str,
) -> Result<runtime::inventory_scope::RootLifetimeId, CoreError> {
    parse_hex16(
        value,
        runtime::inventory_scope::RootLifetimeId::from_bytes,
        "root_lifetime_id",
    )
}

pub(crate) fn wire_error(error: runtime::inventory_scope::WireError) -> CoreError {
    CoreError::InventoryScopeInvalidRequest {
        message: error.to_string(),
    }
}

// ================================================================================================
// P6-6: agent-claude-v1 FFI surface (`docs/architecture/rust-agent-claude-v1.md`,
// `docs/designs/p6-claude-vertical-2026-08-23.md` §11 P6-6). Every export is synchronous and fast
// (charter §8.2: fast enqueue-only FFI, work inside the runtime, results via terminal events),
// matching every other export in this file -- none traverse the P0 operation registry. Event-plane
// events cross as the versioned, batched `agent_claude::event::AgentClaudeEvent` JSON envelope
// (design D-6), decoded Swift-side from the generic `RuntimeEvent.payload` bytes the existing
// `openSubscription`/`tryDrain` surface already returns -- no new subscription export, mirroring
// `inventory-scope-v1`'s precedent of reusing the generic subscription surface verbatim.
// ================================================================================================

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreAgentClaudeEnvironmentEntryV1 {
    pub key: String,
    pub value: String,
}

/// Contract §5.1: the already-resolved spawn command this crate receives. **Never logged** (design
/// R8) -- `environment` in particular must never reach any diagnostic sink, including this crate's
/// own `RuntimeEvent` stream; see `agent_claude::scope::AgentClaudeScopeConfig`'s doc comment.
#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreAgentClaudeScopeConfigV1 {
    pub command: String,
    pub arguments: Vec<String>,
    pub environment: Vec<CoreAgentClaudeEnvironmentEntryV1>,
    pub working_directory: Option<String>,
    pub permission_mode: Option<String>,
    pub mcp_config_path: Option<String>,
    pub mcp_strict_mode: bool,
    pub disallowed_built_in_tools: Vec<String>,
    /// GLM's `--append-system-prompt` workaround (contract §2.5 item 1) -- inert (`None`) for every
    /// production `claudeCode` configuration this vertical's scope covers.
    pub append_system_prompt: Option<String>,
    /// P6-7 (§15.5): the `initialize` control request's `systemPrompt` override -- a protocol-
    /// level field sent once during `agent_start_or_resume`'s session-startup handshake, distinct
    /// from `append_system_prompt`'s CLI-argv mechanism. `None` omits the `systemPrompt` key.
    pub system_prompt: Option<String>,
    pub idle_fallback_millis: u64,
    pub interrupt_ack_timeout_millis: u64,
    /// P6-7 (D-9/R9, `docs/architecture/rust-agent-claude-v1.md` §15.6): whether the raw-event
    /// JSONL log is active, resolved by Swift from the same `app_settings` key
    /// (`agent_mode.claude_raw_event_logging_enabled`) its own writer reads.
    pub raw_event_log_enabled: bool,
    /// The already-resolved absolute log-file path (Swift's `makeRawEventLogFileURL`). `None`
    /// disables logging regardless of `raw_event_log_enabled`.
    pub raw_event_log_file_path: Option<String>,
    pub raw_event_log_run_id: String,
    pub raw_event_log_tab_id: String,
    pub raw_event_log_window_id: i64,
    pub raw_event_log_initial_session_id: String,
}

impl CoreAgentClaudeScopeConfigV1 {
    pub(crate) fn runtime_config(&self) -> runtime::agent_claude::AgentClaudeScopeConfig {
        runtime::agent_claude::AgentClaudeScopeConfig {
            command: self.command.clone(),
            arguments: self.arguments.clone(),
            environment: self
                .environment
                .iter()
                .map(|entry| (entry.key.clone(), entry.value.clone()))
                .collect(),
            working_directory: self.working_directory.clone(),
            permission_mode: self.permission_mode.clone(),
            mcp_config_path: self.mcp_config_path.clone(),
            mcp_strict_mode: self.mcp_strict_mode,
            disallowed_built_in_tools: self.disallowed_built_in_tools.clone(),
            append_system_prompt: self.append_system_prompt.clone(),
            system_prompt: self.system_prompt.clone(),
            idle_fallback: std::time::Duration::from_millis(self.idle_fallback_millis),
            interrupt_ack_timeout: std::time::Duration::from_millis(
                self.interrupt_ack_timeout_millis,
            ),
            raw_event_log_enabled: self.raw_event_log_enabled,
            raw_event_log_file_path: self.raw_event_log_file_path.clone(),
            raw_event_log_run_id: self.raw_event_log_run_id.clone(),
            raw_event_log_tab_id: self.raw_event_log_tab_id.clone(),
            raw_event_log_window_id: self.raw_event_log_window_id,
            raw_event_log_initial_session_id: self.raw_event_log_initial_session_id.clone(),
            raw_argv_for_testing: false,
        }
    }
}

/// Mirrors `InventoryScopeHandleV1`'s doc comment exactly: `subscription_scope_id` is computed
/// once, Rust-side, at `agent_open_scope` time and handed to Swift here so it never re-derives the
/// `AgentClaudeScopeId -> ScopeId` conversion. Pass this string as `SubscriptionScope.scope_id` to
/// the existing, unchanged generic `CoreRuntime.openSubscription`/`tryDrain` surface.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct AgentClaudeScopeHandleV1 {
    pub scope_id: String,
    pub subscription_scope_id: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Record)]
pub struct AgentClaudeStartReceiptV1 {
    pub pid: i32,
    pub process_group_id: i32,
}

/// Contract §4: the fast-enqueue receipt for `agent_interrupt_turn`. The actual outcome (one of
/// the five contract §5.3 variants) arrives later as an `interruptOutcome` terminal-class event on
/// the subscription, correlated by this same `request_id` -- charter §8.2's command+event shape,
/// not an async FFI method.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct AgentClaudeInterruptReceiptV1 {
    pub request_id: String,
}

/// The four host/runtime handshake states for a model/effort intent. Swift supplies the
/// platform-specific launch-environment comparison fact; Rust owns logging, protocol dispatch,
/// and the correlated outcome event.
#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum AgentClaudeFlagSettingsDispositionV1 {
    Initial,
    Live,
    PendingInitialHandshake,
    RestartRequired,
}

impl From<AgentClaudeFlagSettingsDispositionV1> for runtime::agent_claude::FlagSettingsDisposition {
    fn from(value: AgentClaudeFlagSettingsDispositionV1) -> Self {
        match value {
            AgentClaudeFlagSettingsDispositionV1::Initial => Self::Initial,
            AgentClaudeFlagSettingsDispositionV1::Live => Self::Live,
            AgentClaudeFlagSettingsDispositionV1::PendingInitialHandshake => {
                Self::PendingInitialHandshake
            }
            AgentClaudeFlagSettingsDispositionV1::RestartRequired => Self::RestartRequired,
        }
    }
}

/// P6-7: the fast-enqueue receipt for `agent_apply_model_and_effort`. The actual outcome arrives
/// later as a `flagSettingsApplied` terminal-class event on the subscription, correlated by this
/// same `request_id` -- charter §8.2's command+event shape, mirroring
/// `AgentClaudeInterruptReceiptV1` exactly.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct AgentClaudeFlagSettingsReceiptV1 {
    pub request_id: String,
}

/// Contract §7.1's permission **protocol** half: the two decision shapes
/// `agent_claude::permission::PermissionDecision` already defines, re-exposed at the FFI boundary
/// with the exact same two-case split (`agent_claude::scope::PermissionDecisionInput`'s doc comment
/// explains why this is a third, FFI-owned name rather than exporting the protocol module's type
/// directly).
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum AgentClaudePermissionDecisionV1 {
    Allow {
        include_updated_permissions: bool,
    },
    AutoAllowRepoPrompt {
        match_source: String,
        normalized_tool_name: Option<String>,
        server_identifier: Option<String>,
    },
    AutoAllowFallback,
    Deny {
        message: String,
        interrupt: bool,
    },
}

impl From<AgentClaudePermissionDecisionV1> for runtime::agent_claude::PermissionDecisionInput {
    fn from(value: AgentClaudePermissionDecisionV1) -> Self {
        match value {
            AgentClaudePermissionDecisionV1::Allow {
                include_updated_permissions,
            } => Self::Allow {
                include_updated_permissions,
            },
            AgentClaudePermissionDecisionV1::AutoAllowRepoPrompt {
                match_source,
                normalized_tool_name,
                server_identifier,
            } => Self::AutoAllowRepoPrompt {
                match_source,
                normalized_tool_name,
                server_identifier,
            },
            AgentClaudePermissionDecisionV1::AutoAllowFallback => Self::AutoAllowFallback,
            AgentClaudePermissionDecisionV1::Deny { message, interrupt } => {
                Self::Deny { message, interrupt }
            }
        }
    }
}

/// Routes a caller-supplied scope-id string to the typed `AgentClaudeScopeId` this crate's registry
/// addresses scopes by (contract doc §1: "handles are explicit IDs, not proxy objects", the same
/// discipline `parse_inventory_scope_id` enforces for the inventory-scope-v1 surface).
pub(crate) fn parse_agent_claude_scope_id(
    value: &str,
) -> Result<runtime::agent_claude::AgentClaudeScopeId, CoreError> {
    value
        .parse()
        .map_err(|_| CoreError::AgentClaudeInvalidRequest {
            message: "invalid agent-claude scope id".to_string(),
        })
}

// `From<AgentScopeError>`/`From<ScopeRegistryError>` for `CoreError` live in `errors.rs`, matching
// every other domain's error-mapping placement in this crate.

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreInventoryScopeConfigV1 {
    pub live_generation_cap: u64,
    pub max_patch_logical_mutation_count: u64,
    /// Lower-cased, no leading dot (contract doc §6: Swift-owned codemap-capable-extension
    /// policy, passed in at scope-open time rather than resolved implicitly inside Rust).
    pub codemap_capable_extensions: Vec<String>,
}

impl CoreInventoryScopeConfigV1 {
    pub(crate) fn runtime_config(
        &self,
    ) -> Result<runtime::inventory_scope::InventoryScopeConfig, CoreError> {
        let live_generation_cap =
            usize::try_from(self.live_generation_cap).map_err(|_| CoreError::InvalidArgument)?;
        let max_patch_logical_mutation_count =
            usize::try_from(self.max_patch_logical_mutation_count)
                .map_err(|_| CoreError::InvalidArgument)?;
        Ok(runtime::inventory_scope::InventoryScopeConfig {
            live_generation_cap,
            max_patch_logical_mutation_count,
            // D-5 is deliberately internal rather than a new public FFI knob. Debug archives
            // self-check every patch by default; release archives retain the zero-cost path.
            self_check_patches: cfg!(debug_assertions),
            codemap_capable_extensions: self
                .codemap_capable_extensions
                .iter()
                .map(|extension| extension.to_ascii_lowercase())
                .collect(),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryScopeHandleV1 {
    pub scope_id: String,
    /// P4-4b: the `ScopeId` (canonical dashed-hex UUID) this scope's event-plane notifications
    /// (contract doc §5b) publish into -- `InventoryScopeId::to_subscription_scope_id`'s output,
    /// computed once by `inventory_open_scope` and handed to Swift here so it never re-derives
    /// the conversion. Pass this string as `SubscriptionScope.scope_id` to the existing, unchanged
    /// generic `CoreRuntime.openSubscription`/`tryDrain` surface -- there is no separate
    /// inventory-scope-specific subscribe/drain export; P0's machinery is reused verbatim.
    pub subscription_scope_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryRootOpenV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub root_id: Vec<u8>,
    pub name: String,
    pub standardized_full_path: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryRootLifetimeV1 {
    pub root_id: Vec<u8>,
    pub root_lifetime_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryRootUnloadReceiptV1 {
    pub root_id: Vec<u8>,
    pub root_lifetime_id: String,
    pub final_generation: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryRootDiagnosticsV1 {
    pub root_id: Vec<u8>,
    pub lifetime_id: Option<String>,
    pub published_topology_generation: Option<u64>,
    pub live_topology_generations: Vec<u64>,
    pub retained_topology_generations: Vec<u64>,
    pub build_count: u64,
    pub path_index_build_count: u64,
    pub overlay_path_index_build_count: u64,
    pub patch_count: u64,
    pub authoritative_rebuild_count: u64,
    pub fallback_count: u64,
    /// Fixed order matching `RootCatalogShardFallbackReason::ALL` (§5c's 8-case table, in the
    /// same order this crate's own `zeroed_fallback_reason_counts` iterates).
    pub fallback_reason_counts: Vec<u64>,
    pub last_applied_index_generation: Option<u64>,
    pub delta_state_dirty: bool,
    pub backstop_count: u64,
    pub max_live_generation_count: u64,
}

impl From<runtime::inventory_scope::RootDiagnostics> for InventoryRootDiagnosticsV1 {
    fn from(value: runtime::inventory_scope::RootDiagnostics) -> Self {
        let fallback_reason_counts = runtime::inventory_scope::RootCatalogShardFallbackReason::ALL
            .into_iter()
            .map(|reason| {
                value
                    .fallback_reason_counts
                    .get(&reason)
                    .copied()
                    .unwrap_or(0)
            })
            .collect();
        Self {
            root_id: value.root_id.to_vec(),
            lifetime_id: value.lifetime_id.map(|id| id.to_string()),
            published_topology_generation: value.published_topology_generation,
            live_topology_generations: value.live_topology_generations,
            retained_topology_generations: value.retained_topology_generations,
            build_count: value.build_count,
            path_index_build_count: value.path_index_build_count,
            overlay_path_index_build_count: value.overlay_path_index_build_count,
            patch_count: value.patch_count,
            authoritative_rebuild_count: value.authoritative_rebuild_count,
            fallback_count: value.fallback_count,
            fallback_reason_counts,
            last_applied_index_generation: value.last_applied_index_generation,
            delta_state_dirty: value.delta_state_dirty,
            backstop_count: value.backstop_count,
            max_live_generation_count: value.max_live_generation_count,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryDiagnosticsV1 {
    pub live_generation_cap_per_root: u64,
    pub max_patch_logical_mutation_count: u64,
    pub published_shard_count: u64,
    pub total_build_count: u64,
    pub total_backstop_count: u64,
    pub single_shard_composition_reuse_count: u64,
    pub generic_merge_element_visit_count: u64,
    pub shadow_comparison_count: u64,
    pub shadow_mismatch_count: u64,
    pub last_shadow_byte_count: u64,
    pub roots: Vec<InventoryRootDiagnosticsV1>,
    pub longest_critical_section_nanos: u64,
    pub open_handle_count: u64,
    pub oldest_open_handle_age_millis: Option<u64>,
}

impl From<runtime::inventory_scope::InventoryDiagnosticsV1> for InventoryDiagnosticsV1 {
    fn from(value: runtime::inventory_scope::InventoryDiagnosticsV1) -> Self {
        Self {
            live_generation_cap_per_root: value.live_generation_cap_per_root as u64,
            max_patch_logical_mutation_count: value.max_patch_logical_mutation_count as u64,
            published_shard_count: value.published_shard_count,
            total_build_count: value.total_build_count,
            total_backstop_count: value.total_backstop_count,
            single_shard_composition_reuse_count: value.single_shard_composition_reuse_count,
            generic_merge_element_visit_count: value.generic_merge_element_visit_count,
            shadow_comparison_count: value.shadow_comparison_count,
            shadow_mismatch_count: value.shadow_mismatch_count,
            last_shadow_byte_count: value.last_shadow_byte_count,
            roots: value.roots.into_iter().map(Into::into).collect(),
            longest_critical_section_nanos: u64::try_from(
                value.longest_critical_section.as_nanos(),
            )
            .unwrap_or(u64::MAX),
            open_handle_count: value.handles.open_count as u64,
            oldest_open_handle_age_millis: value
                .handles
                .oldest_open_age
                .map(|age| u64::try_from(age.as_millis()).unwrap_or(u64::MAX)),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct BulkChunkReceiptV1 {
    pub files_staged: u64,
    pub folders_staged: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum InventoryPublishModeV1 {
    AtomicPublish,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryGenerationReceiptV1 {
    pub root_id: Vec<u8>,
    pub generation: u64,
    pub root_lifetime_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryDeltaCommandV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub root_id: Vec<u8>,
    pub root_lifetime_id: String,
    pub watcher_accepted_watermark: Option<u64>,
    pub requires_full_resync: bool,
    pub expected_applied_index_generation: Option<u64>,
    pub source: String,
    /// The compact `inventory-scope-v1` delta blob (contract doc §5.1) --
    /// `runtime::inventory_scope::encode_delta_event` / `decode_delta_event`.
    pub event_bytes: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum InventoryRejectionReasonV1 {
    StaleWatermark { expected: u64, actual: u64 },
    LifetimeMismatch,
    GenerationGap { expected: u64, actual: u64 },
    UnknownRoot,
    ScopeClosed,
    IdentityMismatch,
}

impl From<runtime::inventory_scope::InventoryRejectionReason> for InventoryRejectionReasonV1 {
    fn from(value: runtime::inventory_scope::InventoryRejectionReason) -> Self {
        match value {
            runtime::inventory_scope::InventoryRejectionReason::StaleWatermark {
                expected,
                actual,
            } => Self::StaleWatermark { expected, actual },
            runtime::inventory_scope::InventoryRejectionReason::LifetimeMismatch => {
                Self::LifetimeMismatch
            }
            runtime::inventory_scope::InventoryRejectionReason::GenerationGap {
                expected,
                actual,
            } => Self::GenerationGap { expected, actual },
            runtime::inventory_scope::InventoryRejectionReason::UnknownRoot => Self::UnknownRoot,
            runtime::inventory_scope::InventoryRejectionReason::ScopeClosed => Self::ScopeClosed,
            runtime::inventory_scope::InventoryRejectionReason::IdentityMismatch => {
                Self::IdentityMismatch
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum InventoryApplyOutcomeV1 {
    Patched,
    RebuiltAuthoritative,
    Rejected { reason: InventoryRejectionReasonV1 },
}

impl From<runtime::inventory_scope::InventoryApplyOutcome> for InventoryApplyOutcomeV1 {
    fn from(value: runtime::inventory_scope::InventoryApplyOutcome) -> Self {
        match value {
            runtime::inventory_scope::InventoryApplyOutcome::Patched => Self::Patched,
            runtime::inventory_scope::InventoryApplyOutcome::RebuiltAuthoritative => {
                Self::RebuiltAuthoritative
            }
            runtime::inventory_scope::InventoryApplyOutcome::Rejected(reason) => Self::Rejected {
                reason: reason.into(),
            },
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryDeltaReceiptV1 {
    pub applied_index_generation: u64,
    pub catalog_generation: Option<u64>,
    pub outcome: InventoryApplyOutcomeV1,
}

impl From<runtime::inventory_scope::InventoryDeltaReceipt> for InventoryDeltaReceiptV1 {
    fn from(value: runtime::inventory_scope::InventoryDeltaReceipt) -> Self {
        Self {
            applied_index_generation: value.applied_index_generation,
            catalog_generation: value.catalog_generation,
            outcome: value.outcome.into(),
        }
    }
}

// ---- discovery mint site (§4.1.1 of the P4 design doc; docs/architecture/rust-inventory-
// scope-v1.md's "Discovery mint site" section) -- additive parallel to the id-supplied
// `BulkChunkReceiptV1` / `InventoryDeltaCommandV1` / `InventoryDeltaReceiptV1` above, which are
// unchanged. ----------------------------------------------------------------------------------

/// `inventoryPushBulkChunkDiscovery`'s receipt: the usual staged counts, plus the minted file/
/// folder ids (each a raw 16-byte UUID, matching `root_id`'s `Vec<u8>` convention elsewhere in
/// this file) in the same order as the discovery bulk chunk's input record vectors.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct BulkChunkDiscoveryReceiptV1 {
    pub files_staged: u64,
    pub folders_staged: u64,
    pub minted_file_ids: Vec<Vec<u8>>,
    pub minted_folder_ids: Vec<Vec<u8>>,
}

/// `InventoryDeltaCommandV1`'s discovery counterpart: identical shape, `event_bytes` carries the
/// compact `inventory-scope-v1` **discovery** delta blob --
/// `runtime::inventory_scope::encode_discovery_delta_event` / `decode_discovery_delta_event`.
#[derive(Clone, Debug, uniffi::Record)]
pub struct InventoryDeltaDiscoveryCommandV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub root_id: Vec<u8>,
    pub root_lifetime_id: String,
    pub watcher_accepted_watermark: Option<u64>,
    pub requires_full_resync: bool,
    pub expected_applied_index_generation: Option<u64>,
    pub source: String,
    pub event_bytes: Vec<u8>,
}

/// `inventoryApplyDeltaDiscoveryV1`'s receipt: the usual delta receipt fields, plus the minted
/// file/folder ids in the same order as the discovery event's `upserted_files`/`upserted_folders`
/// on the input command. Populated even on a `Rejected` outcome -- see
/// `runtime::inventory_scope::InventoryDeltaDiscoveryReceipt`'s doc comment for why that's safe.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryDeltaDiscoveryReceiptV1 {
    pub applied_index_generation: u64,
    pub catalog_generation: Option<u64>,
    pub outcome: InventoryApplyOutcomeV1,
    pub minted_file_ids: Vec<Vec<u8>>,
    pub minted_folder_ids: Vec<Vec<u8>>,
}

impl From<runtime::inventory_scope::InventoryDeltaDiscoveryReceipt>
    for InventoryDeltaDiscoveryReceiptV1
{
    fn from(value: runtime::inventory_scope::InventoryDeltaDiscoveryReceipt) -> Self {
        Self {
            applied_index_generation: value.receipt.applied_index_generation,
            catalog_generation: value.receipt.catalog_generation,
            outcome: value.receipt.outcome.into(),
            minted_file_ids: value.minted_file_ids.iter().map(|id| id.to_vec()).collect(),
            minted_folder_ids: value
                .minted_folder_ids
                .iter()
                .map(|id| id.to_vec())
                .collect(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum InventoryHandleInvalidationReasonV1 {
    RootClosed,
    ScopeClosed,
    IdentityChanged,
}

impl From<runtime::inventory_scope::InvalidationReason> for InventoryHandleInvalidationReasonV1 {
    fn from(value: runtime::inventory_scope::InvalidationReason) -> Self {
        match value {
            runtime::inventory_scope::InvalidationReason::RootClosed => Self::RootClosed,
            runtime::inventory_scope::InvalidationReason::ScopeClosed => Self::ScopeClosed,
            runtime::inventory_scope::InvalidationReason::IdentityChanged => Self::IdentityChanged,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventorySnapshotRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub root_id: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventorySnapshotHandleV1 {
    pub handle_id: u64,
    pub generation: u64,
    pub root_lifetime_id: String,
}

/// One exact source generation for a stateful multi-root catalog composition. A missing expected
/// generation is strict: the root must still have no published generation and contributes no rows.
#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryComposedRootDescriptorV1 {
    pub root_id: Vec<u8>,
    pub root_lifetime_id: String,
    pub expected_generation: Option<u64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum InventoryCompositionAccountingV1 {
    NormalPresentation,
    UncachedFallback,
}

impl From<InventoryCompositionAccountingV1> for runtime::inventory_scope::CompositionAccounting {
    fn from(value: InventoryCompositionAccountingV1) -> Self {
        match value {
            InventoryCompositionAccountingV1::NormalPresentation => Self::NormalPresentation,
            InventoryCompositionAccountingV1::UncachedFallback => Self::UncachedFallback,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryComposedSnapshotRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub roots: Vec<InventoryComposedRootDescriptorV1>,
    pub accounting: InventoryCompositionAccountingV1,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryComposedSnapshotHandleV1 {
    pub handle_id: u64,
    pub row_count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CompactInventoryPageV1 {
    /// `runtime::inventory_scope::encode_bulk_chunk(files, &[])` -- files only, folders section
    /// always empty (snapshot pages are file rows; see contract doc §5.3).
    pub bytes: Vec<u8>,
    pub returned_count: u64,
    /// **Flagged simplification:** `true` iff exactly `limit` rows were returned. This is exact
    /// except at a page boundary that lands precisely on the last row (a page of exactly `limit`
    /// remaining rows is indistinguishable from "more may follow" without an extra count query) --
    /// a caller that pages until an empty/undersized page still terminates correctly, just
    /// possibly one empty round trip later than a precise count would allow.
    pub has_more: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryResolveRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub root_id: Vec<u8>,
    pub expected_catalog_generation: Option<u64>,
    /// `runtime::inventory_scope::encode_resolve_request(file_ids, folder_ids)`.
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CompactRecordBlockV1 {
    /// `runtime::inventory_scope::encode_fact_block` -- carries the whole-block `stale` case as
    /// data (contract doc §5.3), never as a thrown error.
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CompactLookupResultV1 {
    /// Identical fact shape to `CompactRecordBlockV1`, keyed by path.
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CompactQueryV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub handle_id: u64,
    /// `runtime::inventory_scope::encode_query_request`.
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CompactQueryResultV1 {
    /// `runtime::inventory_scope::encode_query_response`.
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct InventoryProjectedShardRequestV1 {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: String,
    pub root_id: Vec<u8>,
}
