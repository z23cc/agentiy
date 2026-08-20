mod cache;
mod fast_plans;
mod lines;
mod path;
mod pattern;
mod regex;
mod wildmatch;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::RuntimeIdentity;

pub use path::{
    FolderSuffixRequest, PathClause, PathDiagnostic, PathFilterRequest, PathFilterResult,
    PathSnapshot,
};
pub use regex::SearchLeaf;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ByteRange {
    pub start: u64,
    pub end: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RegexSearchMode {
    Content,
    Path,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MatchPolicy {
    ContentFullBuffer,
    ContentLine,
    ShortPath,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum LimitPolicy {
    FileSearchFullBuffer,
    FileSearchLine,
    PathSearchShortSubject,
}

impl LimitPolicy {
    pub const fn limits(self) -> (u32, u32, u32) {
        match self {
            Self::FileSearchFullBuffer => (10_000_000, 100_000, 64 * 1024),
            Self::FileSearchLine => (1_000_000, 10_000, 16 * 1024),
            Self::PathSearchShortSubject => (100_000, 1_000, 4 * 1024),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RepairKind {
    None,
    DoubleEscapeCompression,
    Normalise,
    NormaliseThenCompression,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EngineKind {
    AsciiWholeWord,
    AnchoredDeclaration,
    AsciiMarker,
    PathSuffix,
    AnchoredLinePrefilter,
    Pcre2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JitStatus {
    NotApplicable,
    Active,
    Pcre2InterpreterFallback,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LimitFailure {
    Match,
    Depth,
    Heap,
}

#[derive(Clone, Debug, Eq, PartialEq)]
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

#[derive(Clone, Debug)]
pub struct RegexSearchRequest {
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
    pub cancellation: LeafCancellation,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RegexLineHit {
    pub line_number: u32,
    pub line_byte_range: ByteRange,
    pub match_byte_range: ByteRange,
    pub context_before_byte_ranges: Vec<ByteRange>,
    pub context_after_byte_ranges: Vec<ByteRange>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RegexSearchResult {
    pub hits: Vec<RegexLineHit>,
    pub matching_line_count: u64,
    pub cancelled: bool,
    pub diagnostic: RegexDiagnostic,
}

pub const COMPACT_LINE_RANGE_STRIDE: usize = 2;
pub const COMPACT_HIT_STRIDE: usize = 6;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompactRegexSubjectSummary {
    pub line_range_start: u64,
    pub line_range_count: u64,
    pub hit_start: u64,
    pub hit_count: u64,
    pub matching_line_count: u64,
    pub cancelled: bool,
    pub diagnostic: RegexDiagnostic,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompactRegexBatchResult {
    pub subject_summaries: Vec<CompactRegexSubjectSummary>,
    pub line_range_words: Vec<u64>,
    pub hit_words: Vec<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SearchError {
    PatternTooComplex,
    InvalidEscape,
    UnmatchedBrackets,
    UnmatchedParentheses,
    InvalidQuantifier,
    VariableLengthLookbehind,
    InvalidPattern {
        offset: Option<usize>,
        message: String,
    },
    MatchLimitExceeded,
    DepthLimitExceeded,
    HeapLimitExceeded,
    JitUnavailable(String),
    Cancelled,
    InternalInvariant(String),
}

impl std::fmt::Display for SearchError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PatternTooComplex => formatter.write_str("search pattern is too complex"),
            Self::InvalidEscape => formatter.write_str("invalid regex escape sequence"),
            Self::UnmatchedBrackets => formatter.write_str("unmatched regex brackets"),
            Self::UnmatchedParentheses => formatter.write_str("unmatched regex parentheses"),
            Self::InvalidQuantifier => formatter.write_str("invalid regex quantifier"),
            Self::VariableLengthLookbehind => formatter
                .write_str("variable-length lookbehind is unsupported; use fixed or bounded width"),
            Self::InvalidPattern { message, .. } => {
                write!(formatter, "invalid regex pattern: {message}")
            }
            Self::MatchLimitExceeded => formatter.write_str("regex match limit exceeded"),
            Self::DepthLimitExceeded => formatter.write_str("regex depth limit exceeded"),
            Self::HeapLimitExceeded => formatter.write_str("regex heap limit exceeded"),
            Self::JitUnavailable(message) => write!(formatter, "PCRE2 JIT unavailable: {message}"),
            Self::Cancelled => formatter.write_str("search cancelled"),
            Self::InternalInvariant(message) => {
                write!(formatter, "search invariant failed: {message}")
            }
        }
    }
}

impl std::error::Error for SearchError {}

#[derive(Clone, Debug)]
pub struct LeafCancellation {
    inner: Arc<LeafCancellationState>,
}

#[derive(Debug)]
struct LeafCancellationState {
    identity: RuntimeIdentity,
    cancelled: AtomicBool,
    closed: AtomicBool,
}

impl LeafCancellation {
    pub fn new(identity: RuntimeIdentity) -> Self {
        Self {
            inner: Arc::new(LeafCancellationState {
                identity,
                cancelled: AtomicBool::new(false),
                closed: AtomicBool::new(false),
            }),
        }
    }

    pub fn identity(&self) -> &RuntimeIdentity {
        &self.inner.identity
    }

    pub fn cancel(&self) {
        self.inner.cancelled.store(true, Ordering::Release);
    }

    pub fn close(&self) {
        self.inner.closed.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.cancelled.load(Ordering::Acquire)
    }

    pub fn is_closed(&self) -> bool {
        self.inner.closed.load(Ordering::Acquire)
    }
}
