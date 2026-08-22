//! P3-3 slice-2b phase-2: compact batch wire (request + response) for a DIFFERENTIAL-ONLY
//! `PathSearchIndex` entry point, driving [`super::PathSearchIndex::find`] and
//! [`super::PathSearchIndex::projected_find`] over ONE corpus for a BATCH of queries in a single
//! call.
//!
//! # Scope: this is NOT the production shape
//!
//! `PathSearchIndex` is built once per shard generation and queried per keystroke in the real
//! Swift caller (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift`).
//! A stateless FFI call that re-encodes and rebuilds the whole corpus on every query would pay the
//! same whole-table tax the P3-2c inventory benchmark measured (57545bfa) to be prohibitive for a
//! per-keystroke hot path. This wire exists ONLY to drive a byte-exact differential test
//! (`PathSearchRustSwiftDifferentialTests`) that proves this Rust port matches the live C engine;
//! production cutover needs the P4 stateful scope-registry handle primitive, not this shape.
//!
//! To amortize corpus rebuilding across a single differential test call anyway, one request
//! batches an entire corpus plus every query the test wants to run against it, and builds exactly
//! one [`super::PathSearchIndex`] for the whole call.
//!
//! # Wire shape
//!
//! - **String pool**: `utf8_blob` + `string_range_words` (stride [`super::STRING_RANGE_STRIDE`]:
//!   `start, end` byte offsets), exactly like `pathmatch`'s pool convention -- see
//!   `pathmatch::indexes`'s module doc. No `char_count`/`cleaned_byte_len` companion arrays: this
//!   wire never Unicode-cleans anything, so plain UTF-8 byte ranges are the whole story.
//! - **Corpus**: `corpus_path_indices: Vec<u64>` -- a FLAT list of pool indices, one per corpus
//!   path, in original (insertion) order. Order is load-bearing: it defines the ordinals
//!   `PathSearchIndex::new` assigns and that this wire's results report back. There is no
//!   per-row struct/stride here (unlike `pathmatch::indexes`'s root/file/folder tables) because a
//!   corpus row IS a single pool index -- no other per-path field exists to pack alongside it.
//! - **Queries** (stride [`super::QUERY_STRIDE`]): `pattern_idx, limit, mode_flag,
//!   display_prefix_idx, absolute_prefix_idx`.
//!   - `mode_flag == 0` ("find"): drives [`super::PathSearchIndex::find`]. Both prefix indices
//!     MUST resolve to an empty pooled string -- decode rejects a find-mode query that carries a
//!     non-empty projected prefix, rather than silently ignoring it, so a builder bug can never
//!     produce a request whose wire shape lies about which fields are live.
//!   - `mode_flag == 1` ("projected"): drives [`super::PathSearchIndex::projected_find`] with
//!     `cancellation: None` (this wire's ONLY cancellation channel is the batch-level
//!     `LeafCancellation` threaded through [`PathSearchFindService::compute_with_cancellation`];
//!     per-query cancellation tokens are out of scope for this differential-only call, per the
//!     task's explicit "optional cancellation ignored for now").
//!   - Any other `mode_flag` value is a decode error.
//!
//! # Response shape
//!
//! - `result_ordinals: Vec<u64>` -- corpus ordinals (0-based, into `corpus_path_indices`'s
//!   order), flat, one contiguous slice per query in query order, in the same result order
//!   `find`/`projected_find` themselves produce (ascending prefix/suffix-bound order for `find`;
//!   ascending [`super::engine`]'s `projected_compare` order for `projected_find`).
//! - `result_range_words` (stride [`super::RESULT_RANGE_STRIDE`]): `start, count` into
//!   `result_ordinals`, index-aligned with queries.
//! - `stats_words` (stride [`super::STATS_STRIDE`]): `examined_count, matched_count,
//!   heap_peak_count, heap_comparison_count, scratch_bytes`, index-aligned with queries.
//!   ALL-ZERO for find-mode queries (`find` has no diagnostic contract to report), and the real
//!   [`super::PathSearchWorkStats`] fields (minus `cancelled`, which becomes an operation-level
//!   error -- see below) for a completed projected-mode query.
//!
//! Scores and tie-break strings do NOT cross this wire: both `find` and `projected_find` always
//! report score `1` (see `index.rs`/`engine.rs` docs), and a corpus ordinal fully identifies a
//! candidate (including duplicate corpus paths) -- the Swift differential harness reconstructs
//! paths/tie-break keys itself from its own reference corpus array, exactly like it would for the
//! real C-backed `PathSearchIndex`.
//!
//! # Empty-corpus / zero-limit normalization
//!
//! The real Swift `PathSearchIndex` special-cases an empty corpus and a non-positive `limit`
//! BEFORE ever calling into C, returning empty results / all-zero diagnostics without invoking
//! `path_search_find`/`path_search_projected_find_cancellable` at all. This service reproduces
//! that exact early-return behavior (rather than calling into `super::PathSearchIndex` with an
//! empty index or `limit == 0` and relying on its own, independently-arrived-at empty-result
//! behavior to coincidentally match) so the differential harness can assert bit-identical
//! diagnostics for these edges too, not just "both sides returned no matches".
//!
//! # Cancellation semantics
//!
//! [`super::ProjectedSearchOutcome::Cancelled`] can only arise here if the batch-level
//! `LeafCancellation` fires; since per-query cancellation tokens are out of scope for this wire
//! (see above), `projected_find` is always called with `cancellation: None` and can never itself
//! observe an internal cancellation -- so `Cancelled` is defensive/unreachable in practice, not a
//! real code path this service exercises. If it were ever reached, this service treats it as
//! [`PathSearchFindError::Cancelled`] for the WHOLE batch (discarding any already-computed
//! results) rather than a completed-with-zero-stats result, mirroring how every other batch
//! service in this crate treats cancellation as a batch-level failure, not a per-item outcome.

use std::fmt;

use super::contract::{
    PATH_SEARCH_CONTRACT_VERSION_V1, QUERY_STRIDE, RESULT_RANGE_STRIDE, STATS_STRIDE,
    STRING_RANGE_STRIDE,
};
use super::engine::ProjectedSearchOutcome;
use super::index::PathSearchIndex;

// ---- wire types ---------------------------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PathSearchFindRequestV1 {
    pub contract_version: u16,
    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub corpus_path_indices: Vec<u64>,
    pub query_words: Vec<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PathSearchFindError {
    InvalidRequest(String),
    Cancelled,
}

impl fmt::Display for PathSearchFindError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest(value) => {
                write!(formatter, "invalid path-search request: {value}")
            }
            Self::Cancelled => formatter.write_str("path-search compute cancelled"),
        }
    }
}
impl std::error::Error for PathSearchFindError {}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PathSearchFindResponseV1 {
    pub result_ordinals: Vec<u64>,
    pub result_range_words: Vec<u64>,
    pub stats_words: Vec<u64>,
}

// ---- encode (request-builder helpers; used by Rust unit tests and mirrored by the Swift codec) -

impl PathSearchFindRequestV1 {
    /// Pools `text` verbatim (no dedup -- see `pathmatch::indexes`'s `push_string` doc for the
    /// same convention). Never fails; wire-level UTF-8/NUL validation happens at decode time.
    pub fn push_string(&mut self, text: &str) -> u64 {
        let start = self.utf8_blob.len() as u64;
        self.utf8_blob.extend_from_slice(text.as_bytes());
        let end = self.utf8_blob.len() as u64;
        let index = (self.string_range_words.len() / STRING_RANGE_STRIDE) as u64;
        self.string_range_words.push(start);
        self.string_range_words.push(end);
        index
    }

    /// Appends one corpus path, preserving insertion order (load-bearing -- see the module doc).
    /// Returns the assigned corpus ordinal.
    pub fn push_corpus_path(&mut self, path: &str) -> u64 {
        let ordinal = self.corpus_path_indices.len() as u64;
        let idx = self.push_string(path);
        self.corpus_path_indices.push(idx);
        ordinal
    }

    /// Appends a `mode_flag == 0` ("find") query. Returns the assigned query ordinal.
    pub fn push_find_query(&mut self, pattern: &str, limit: u64) -> u64 {
        let ordinal = (self.query_words.len() / QUERY_STRIDE) as u64;
        let pattern_idx = self.push_string(pattern);
        let empty_idx = self.push_string("");
        self.query_words
            .extend([pattern_idx, limit, 0, empty_idx, empty_idx]);
        ordinal
    }

    /// Appends a `mode_flag == 1` ("projected") query. Returns the assigned query ordinal.
    pub fn push_projected_query(
        &mut self,
        pattern: &str,
        limit: u64,
        display_prefix: &str,
        absolute_prefix: &str,
    ) -> u64 {
        let ordinal = (self.query_words.len() / QUERY_STRIDE) as u64;
        let pattern_idx = self.push_string(pattern);
        let display_prefix_idx = self.push_string(display_prefix);
        let absolute_prefix_idx = self.push_string(absolute_prefix);
        self.query_words.extend([
            pattern_idx,
            limit,
            1,
            display_prefix_idx,
            absolute_prefix_idx,
        ]);
        ordinal
    }
}

// ---- decode + fail-closed validation -------------------------------------------------------

fn usize_word(value: u64) -> Result<usize, PathSearchFindError> {
    usize::try_from(value).map_err(|_| {
        PathSearchFindError::InvalidRequest("compact word exceeds platform index".into())
    })
}

fn validate_shape(request: &PathSearchFindRequestV1) -> Result<(), PathSearchFindError> {
    if request.string_range_words.len() % STRING_RANGE_STRIDE != 0 {
        return Err(PathSearchFindError::InvalidRequest(
            "string_range_words length is not a multiple of STRING_RANGE_STRIDE".into(),
        ));
    }
    if request.query_words.len() % QUERY_STRIDE != 0 {
        return Err(PathSearchFindError::InvalidRequest(
            "query_words length is not a multiple of QUERY_STRIDE".into(),
        ));
    }
    Ok(())
}

fn decode_text(request: &PathSearchFindRequestV1, index: u64) -> Result<&str, PathSearchFindError> {
    let row = usize_word(index)?;
    let base = row
        .checked_mul(STRING_RANGE_STRIDE)
        .ok_or_else(|| PathSearchFindError::InvalidRequest("string pool index overflow".into()))?;
    let range = request
        .string_range_words
        .get(base..base + STRING_RANGE_STRIDE)
        .ok_or_else(|| {
            PathSearchFindError::InvalidRequest("string pool index out of range".into())
        })?;
    let start = usize_word(range[0])?;
    let end = usize_word(range[1])?;
    if end < start || end > request.utf8_blob.len() {
        return Err(PathSearchFindError::InvalidRequest(
            "string range out of bounds".into(),
        ));
    }
    let text = std::str::from_utf8(&request.utf8_blob[start..end]).map_err(|_| {
        PathSearchFindError::InvalidRequest("string range is not valid UTF-8".into())
    })?;
    if text.as_bytes().contains(&0) {
        return Err(PathSearchFindError::InvalidRequest(
            "string contains an embedded NUL byte".into(),
        ));
    }
    Ok(text)
}

pub(crate) enum DecodedQueryMode<'a> {
    Find,
    Projected {
        display_prefix: &'a str,
        absolute_prefix: &'a str,
    },
}

pub(crate) struct DecodedQuery<'a> {
    pub pattern: &'a str,
    pub limit: usize,
    pub mode: DecodedQueryMode<'a>,
}

pub(crate) struct DecodedRequest<'a> {
    /// Owned corpus paths, in original order (load-bearing -- see the module doc). Owned rather
    /// than borrowed because `PathSearchIndex::new` needs `&[String]`.
    pub corpus_paths: Vec<String>,
    pub queries: Vec<DecodedQuery<'a>>,
}

pub(crate) fn decode(
    request: &PathSearchFindRequestV1,
) -> Result<DecodedRequest<'_>, PathSearchFindError> {
    if request.contract_version != PATH_SEARCH_CONTRACT_VERSION_V1 {
        return Err(PathSearchFindError::InvalidRequest(format!(
            "unknown contract version {}",
            request.contract_version
        )));
    }
    validate_shape(request)?;

    let mut corpus_paths = Vec::with_capacity(request.corpus_path_indices.len());
    for &idx in &request.corpus_path_indices {
        corpus_paths.push(decode_text(request, idx)?.to_owned());
    }

    let mut queries = Vec::with_capacity(request.query_words.len() / QUERY_STRIDE);
    for row in request.query_words.chunks_exact(QUERY_STRIDE) {
        let pattern = decode_text(request, row[0])?;
        let limit = usize_word(row[1])?;
        let display_prefix = decode_text(request, row[3])?;
        let absolute_prefix = decode_text(request, row[4])?;
        let mode = match row[2] {
            0 => {
                if !display_prefix.is_empty() || !absolute_prefix.is_empty() {
                    return Err(PathSearchFindError::InvalidRequest(
                        "find-mode query must carry empty projected prefixes".into(),
                    ));
                }
                DecodedQueryMode::Find
            }
            1 => DecodedQueryMode::Projected {
                display_prefix,
                absolute_prefix,
            },
            other => {
                return Err(PathSearchFindError::InvalidRequest(format!(
                    "unknown query mode_flag {other}"
                )));
            }
        };
        queries.push(DecodedQuery {
            pattern,
            limit,
            mode,
        });
    }

    Ok(DecodedRequest {
        corpus_paths,
        queries,
    })
}

// ---- service --------------------------------------------------------------------------------

/// Batch entry mirroring the differential test's one-call-per-corpus shape: decode once, build
/// ONE [`PathSearchIndex`] for the whole request, then run every query against it in order. See
/// the module doc for why this is NOT the eventual production shape.
#[derive(Default)]
pub struct PathSearchFindService;

impl PathSearchFindService {
    pub fn compute(
        &self,
        request: &PathSearchFindRequestV1,
    ) -> Result<PathSearchFindResponseV1, PathSearchFindError> {
        self.compute_with_cancellation(request, None)
    }

    pub fn compute_with_cancellation(
        &self,
        request: &PathSearchFindRequestV1,
        cancellation: Option<&crate::LeafCancellation>,
    ) -> Result<PathSearchFindResponseV1, PathSearchFindError> {
        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(PathSearchFindError::Cancelled);
        }
        let decoded = decode(request)?;
        let index = PathSearchIndex::new(&decoded.corpus_paths);
        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(PathSearchFindError::Cancelled);
        }

        let mut response = PathSearchFindResponseV1::default();
        for (query_index, query) in decoded.queries.iter().enumerate() {
            if query_index % 256 == 0
                && cancellation.is_some_and(crate::LeafCancellation::is_cancelled)
            {
                return Err(PathSearchFindError::Cancelled);
            }

            let start = response.result_ordinals.len() as u64;
            match &query.mode {
                DecodedQueryMode::Find => {
                    if query.limit == 0 || index.is_empty() {
                        response.result_range_words.extend([start, 0]);
                    } else {
                        let matches = index.find(query.pattern, query.limit);
                        response
                            .result_ordinals
                            .extend(matches.iter().map(|m| m.index as u64));
                        response
                            .result_range_words
                            .extend([start, matches.len() as u64]);
                    }
                    response.stats_words.extend([0u64; STATS_STRIDE]);
                }
                DecodedQueryMode::Projected {
                    display_prefix,
                    absolute_prefix,
                } => {
                    if query.limit == 0 || index.is_empty() {
                        response.result_range_words.extend([start, 0]);
                        response.stats_words.extend([0u64; STATS_STRIDE]);
                        continue;
                    }
                    match index.projected_find(
                        query.pattern,
                        display_prefix,
                        absolute_prefix,
                        query.limit,
                        None,
                    ) {
                        ProjectedSearchOutcome::Completed(matches, stats) => {
                            response
                                .result_ordinals
                                .extend(matches.iter().map(|m| m.index as u64));
                            response
                                .result_range_words
                                .extend([start, matches.len() as u64]);
                            response.stats_words.extend([
                                stats.examined_count as u64,
                                stats.matched_count as u64,
                                stats.heap_peak_count as u64,
                                stats.heap_comparison_count as u64,
                                stats.scratch_bytes as u64,
                            ]);
                        }
                        // Defensive/unreachable in practice: `cancellation: None` is always
                        // passed to `projected_find` above (see the module doc). Treated as a
                        // whole-batch cancellation, not a per-query outcome, for consistency
                        // with every other batch service in this crate.
                        ProjectedSearchOutcome::Cancelled(_) => {
                            return Err(PathSearchFindError::Cancelled);
                        }
                    }
                }
            }
        }

        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(PathSearchFindError::Cancelled);
        }
        debug_assert_eq!(
            response.result_range_words.len(),
            decoded.queries.len() * RESULT_RANGE_STRIDE
        );
        debug_assert_eq!(
            response.stats_words.len(),
            decoded.queries.len() * STATS_STRIDE
        );
        Ok(response)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request_with(
        corpus: &[&str],
        queries: impl FnOnce(&mut PathSearchFindRequestV1),
    ) -> PathSearchFindRequestV1 {
        let mut request = PathSearchFindRequestV1 {
            contract_version: PATH_SEARCH_CONTRACT_VERSION_V1,
            ..Default::default()
        };
        for path in corpus {
            request.push_corpus_path(path);
        }
        queries(&mut request);
        request
    }

    #[test]
    fn find_and_projected_queries_round_trip_in_one_batch() {
        let request = request_with(
            &["a/App.swift", "b/App.swift", "c/Other.swift"],
            |request| {
                request.push_find_query("App.swift", 10);
                request.push_projected_query("App.swift", 10, "disp/", "/abs/");
            },
        );
        let response = PathSearchFindService.compute(&request).expect("compute");
        assert_eq!(response.result_range_words, vec![0, 2, 2, 2]);
        assert_eq!(response.result_ordinals, vec![0, 1, 0, 1]);
        assert_eq!(response.stats_words.len(), 2 * STATS_STRIDE);
        assert_eq!(&response.stats_words[..STATS_STRIDE], &[0u64; STATS_STRIDE]);
        assert!(
            response.stats_words[STATS_STRIDE] > 0,
            "examined_count must be nonzero"
        );
    }

    #[test]
    fn empty_corpus_and_zero_limit_normalize_to_empty_results_and_zero_stats() {
        let request = request_with(&[], |request| {
            request.push_find_query("anything", 10);
            request.push_projected_query("anything", 10, "", "");
        });
        let response = PathSearchFindService.compute(&request).expect("compute");
        assert_eq!(response.result_ordinals, Vec::<u64>::new());
        assert_eq!(response.result_range_words, vec![0, 0, 0, 0]);
        assert_eq!(response.stats_words, vec![0u64; 2 * STATS_STRIDE]);

        let zero_limit = request_with(&["a.txt"], |request| {
            request.push_find_query("a.txt", 0);
            request.push_projected_query("a.txt", 0, "", "");
        });
        let response = PathSearchFindService.compute(&zero_limit).expect("compute");
        assert_eq!(response.result_ordinals, Vec::<u64>::new());
        assert_eq!(response.stats_words, vec![0u64; 2 * STATS_STRIDE]);
    }

    #[test]
    fn find_mode_query_with_nonempty_projected_prefix_is_rejected() {
        let mut request = PathSearchFindRequestV1 {
            contract_version: PATH_SEARCH_CONTRACT_VERSION_V1,
            ..Default::default()
        };
        request.push_corpus_path("a.txt");
        let pattern_idx = request.push_string("a.txt");
        let empty_idx = request.push_string("");
        let dirty_idx = request.push_string("not-empty");
        request
            .query_words
            .extend([pattern_idx, 10, 0, dirty_idx, empty_idx]);
        assert_eq!(
            PathSearchFindService.compute(&request),
            Err(PathSearchFindError::InvalidRequest(
                "find-mode query must carry empty projected prefixes".into()
            ))
        );
    }

    #[test]
    fn unknown_mode_flag_is_rejected() {
        let mut request = PathSearchFindRequestV1 {
            contract_version: PATH_SEARCH_CONTRACT_VERSION_V1,
            ..Default::default()
        };
        request.push_corpus_path("a.txt");
        let pattern_idx = request.push_string("a.txt");
        let empty_idx = request.push_string("");
        request
            .query_words
            .extend([pattern_idx, 10, 2, empty_idx, empty_idx]);
        assert_eq!(
            PathSearchFindService.compute(&request),
            Err(PathSearchFindError::InvalidRequest(
                "unknown query mode_flag 2".into()
            ))
        );
    }

    #[test]
    fn unknown_contract_version_is_rejected() {
        let request = PathSearchFindRequestV1 {
            contract_version: 2,
            ..Default::default()
        };
        assert_eq!(
            PathSearchFindService.compute(&request),
            Err(PathSearchFindError::InvalidRequest(
                "unknown contract version 2".into()
            ))
        );
    }

    #[test]
    fn embedded_nul_byte_is_rejected() {
        let mut request = PathSearchFindRequestV1 {
            contract_version: PATH_SEARCH_CONTRACT_VERSION_V1,
            ..Default::default()
        };
        request.push_corpus_path("a\0b.txt");
        assert_eq!(
            PathSearchFindService.compute(&request),
            Err(PathSearchFindError::InvalidRequest(
                "string contains an embedded NUL byte".into()
            ))
        );
    }

    #[test]
    fn pre_cancelled_leaf_short_circuits_before_decode() {
        let request = request_with(&["a.txt"], |request| {
            request.push_find_query("a.txt", 10);
        });
        let identity = crate::RuntimeIdentity::fresh(&"a".repeat(64), &"b".repeat(64)).unwrap();
        let cancellation = crate::LeafCancellation::new(identity);
        cancellation.cancel();
        assert_eq!(
            PathSearchFindService.compute_with_cancellation(&request, Some(&cancellation)),
            Err(PathSearchFindError::Cancelled)
        );
    }
}
