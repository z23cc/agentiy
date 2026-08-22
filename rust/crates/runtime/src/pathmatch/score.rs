//! P3-3 slice-1 port of the workspace path-matching scoring kernel
//! (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathMatcher.swift`'s
//! `computeWeightedMatchScorePrecleaned` + `similarityScoreMax` + the bounded-Levenshtein
//! `similarityScore`, plus the `fuzzyMatchWithSuffixLimit` selected-root `+0.5` bonus that the
//! task's grounding note folds into "the scoring core").
//!
//! # Wire/cleaning scope boundary (read before touching this file)
//!
//! The Swift kernel's inputs pass through THREE Foundation/ICU-dependent steps before any
//! Levenshtein math happens: NFC canonicalization + homoglyph folding + `CharacterSet.alphanumerics`
//! filtering (`PathCharPolicy.foldHomoglyphsIfNeeded` / `PathMatcher.cleaned()`), then Unicode
//! case-folding (`String.lowercased()` / `NSString.caseInsensitiveCompare`). None of those three
//! have a Rust std equivalent, and adding a normalization crate is out of scope for this slice.
//! Per the task's own escape hatch ("keep any Foundation-Unicode-dependent casing decision on the
//! Swift side... OR port it with differential fixtures proving parity... choose per-site"), this
//! kernel draws the line as follows:
//!
//! 1. **NFC + homoglyph fold + alphanumeric filter (`cleaned()`)**: kept Swift-side. The wire
//!    always carries strings that have ALREADY been run through the real `PathMatcher.cleaned()` --
//!    exactly what `computeWeightedMatchScorePrecleaned` does internally for both the query
//!    (upstream, by its caller) and each candidate path component (inline, via its own `cleaned()`
//!    call). `policy.rs` ports the LOCALE-INDEPENDENT part of that table (for its own unit tests)
//!    but is not used to re-clean production wire input.
//! 2. **Case folding**: also kept Swift-side. The wire carries `cleaned(component).lowercased()`,
//!    matching the ONLY `caseSensitive` value any production call site ever passes
//!    (`caseSensitive: false`). Because both Swift's ASCII fast path and its Unicode
//!    `unicodeSimilarityScore` path re-lowercase internally regardless of whether the input was
//!    already lowercase, and Unicode lowercasing is idempotent, pre-lowering Swift-side produces
//!    IDENTICAL results to the unmodified production code path -- verified by
//!    `PathMatchRustSwiftDifferentialTests` (composed/decomposed and non-ASCII case-pair fixtures).
//!    Consequently this kernel has NO `caseSensitive` wire parameter: every comparison here is a
//!    byte/scalar-literal comparison of already-compare-ready input. ONE EXCEPTION: lowercasing can
//!    change UTF-8 byte length (`İ` U+0130, 2 bytes, lowercases to `i` + COMBINING DOT ABOVE, 3
//!    bytes) -- see point 4 below for why the 256-byte gate can't simply measure the pooled
//!    (lowered) text either.
//! 3. **The `abs(len(user) - len(path)) > 6` early-exit guard**: Swift's `.count` here is
//!    EXTENDED GRAPHEME CLUSTER count (ICU segmentation), a third counting regime distinct from
//!    both the byte-length 256 gate and the scalar-based Levenshtein distance. An initial version
//!    of this kernel counted Unicode SCALARS here instead (reasoning that `cleaned()`'s
//!    alphanumeric-only filter should leave post-`cleaned()` strings scalar==grapheme almost
//!    always). `PathMatchRustSwiftDifferentialTests`' diagnostic probe DISPROVED that: several
//!    scripts' `Mn`/`Mc` combining marks pass through `cleaned()`'s slow path unchanged (they're
//!    dropped from the ALLOWED set but simply left as separate scalars when NOT filtered -- e.g.
//!    Devanagari virama clusters, which ARE one grapheme over several scalars post-`cleaned()`),
//!    and a constructed fixture showed the scalar-based guard actively diverging from Swift's
//!    grapheme-based guard (Swift matched with `nil` avoided; scalar-counting Rust incorrectly hit
//!    the guard and returned `nil`). Per the task's "port it with differential fixtures proving
//!    parity... OR keep on Swift side" escape hatch, this guard is therefore KEPT Swift-side: the
//!    wire carries a precomputed grapheme-count word per pooled string
//!    (`char_count_words`, index-aligned with `string_range_words`), computed by the caller as
//!    `PathMatcher.cleaned(component).count` -- exactly what the guard reads in production, before
//!    any lowering. The pooled TEXT itself is still `cleaned(component).lowercased()` per point 2
//!    above; only the guard's LENGTH reads the separate precomputed count instead of
//!    `text.chars().count()`. The Levenshtein DP itself is unaffected: it still operates on the
//!    pooled text's Unicode scalars, matching the "Levenshtein operates on Unicode scalars"
//!    contract used everywhere else in this module.
//!
//! 4. **The `maxByteCount <= 256` gate deciding whether `similarityScore` runs its real Levenshtein
//!    DP or falls back to exact/case-insensitive-equality-only**: Swift computes `maxByteCount`
//!    from `userComp`/`pathComp` -- the CLEANED-BUT-NOT-YET-LOWERED strings -- BEFORE the
//!    `caseSensitive: false` re-lowering described in point 2 happens. Gating on the pooled
//!    (already-lowered) text's OWN byte length instead is a distinct bug from point 2's, and
//!    `PathMatchRustSwiftDifferentialTests`' diagnostic probe found a real instance: a query/
//!    candidate pair sized so the CLEANED length sits at exactly 256 bytes (Swift takes the normal
//!    DP path) while the LOWERED length exceeds 256 (an implementation gating on lowered length
//!    would take the fallback path instead) produced a real DP match in Swift for a near-identical
//!    pair that a lowered-length gate rejected outright. Per the same escape hatch as point 3, the
//!    gate length is therefore ALSO carried on the wire: `cleaned_byte_len_words`, index-aligned
//!    with `string_range_words` alongside `char_count_words`, holding
//!    `PathMatcher.cleaned(component).utf8.count` (pre-lowering). `similarity_score`'s 256-check
//!    uses `max(user_comp.cleaned_byte_len, path_comp.cleaned_byte_len)` instead of
//!    `text.len()` (the lowered pooled string's own byte length).
//!
//! The `firstAlnumLowercasedByte` early-exit guard has NO Foundation dependency (it's a pure
//! byte-value scan skipping non-ASCII bytes entirely) and is ported verbatim regardless of the
//! above.
//!
//! # Wire shape
//!
//! One request scores ONE query (an ordered, already-suffix-limited list of cleaned+lowercased
//! path components, filename last) against a BATCH of candidates. Each candidate supplies its
//! total path-component count (for the depth penalty and the `total >= query.len()` guard) and the
//! cleaned+lowercased TAIL of its path components (length `query.len()`, filename last) -- exactly
//! the components `computeWeightedMatchScorePrecleaned` would ever read, so the wire never carries
//! path components the kernel wouldn't otherwise inspect. The response returns, for each candidate
//! that scored (i.e. every Swift-side non-`nil` outcome), its caller-assigned ordinal and score --
//! non-matching candidates are simply absent, mirroring `nil` as a business outcome rather than a
//! sentinel value.
//!
//! The returned score already includes the `fuzzyMatchWithSuffixLimit` selected-root `+0.5` bonus
//! (see the task's grounding note), computed from a per-candidate `root_ordinal` looked up against
//! a request-level `selected_root_ordinals` set -- this kernel has no other caller-tunable "policy
//! flag" beyond `threshold` (weights, the depth penalty, and the match-count bonus are fixed
//! constants in the Swift source, so they're fixed constants here too).

use super::contract::{CANDIDATE_STRIDE, PATH_MATCH_CONTRACT_VERSION_V1, SCORE_SCALE, STRING_RANGE_STRIDE};
use super::policy;
use std::collections::HashSet;
use std::fmt;

// ---- wire types -------------------------------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PathMatchScoreRequestV1 {
    pub contract_version: u16,
    pub threshold: f64,

    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    /// `PathMatcher.cleaned(component).count` (Swift EXTENDED GRAPHEME CLUSTER count, pre-lowering)
    /// for each pooled string, index-aligned with `string_range_words` (i.e. entry `i` here
    /// corresponds to pool index `i`, the same index space as `query_indices`/
    /// `candidate_tail_indices`). See the module doc's point 3 for why this is carried explicitly
    /// rather than recomputed from the pooled (lowercased) text's scalar count.
    pub char_count_words: Vec<u64>,
    /// `PathMatcher.cleaned(component).utf8.count` (pre-lowering UTF-8 byte count), index-aligned
    /// with `string_range_words` the same way as `char_count_words`. See the module doc's point 4.
    pub cleaned_byte_len_words: Vec<u64>,

    /// Ordered pool indices for the query components (already `cleaned().lowercased()`), filename
    /// last. Length is the "N" every candidate's tail is measured against.
    pub query_indices: Vec<u64>,

    /// Candidate rows, stride `CANDIDATE_STRIDE`:
    /// `root_ordinal, total_component_count, tail_start, tail_count, ordinal`.
    pub candidate_words: Vec<u64>,
    /// Flat pool of pool indices sliced by each candidate's `(tail_start, tail_count)`: the
    /// candidate's last `query_indices.len()` path components, cleaned+lowercased, filename last.
    pub candidate_tail_indices: Vec<u64>,

    /// Root ordinals for which `rootsWithSelection` was non-empty (the `fuzzyMatchWithSuffixLimit`
    /// `+0.5` bonus policy input).
    pub selected_root_ordinals: Vec<u64>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PathMatchScoreResultV1 {
    /// Caller-assigned ordinals of candidates that scored (Swift-side non-`nil`), in candidate
    /// input order.
    pub matched_ordinals: Vec<u64>,
    /// `round(score * SCORE_SCALE)`, index-aligned with `matched_ordinals`. Integer-scaled per the
    /// task's preference; drift insurance alongside `matched_scores_bits`.
    pub matched_scores_scaled: Vec<i64>,
    /// `f64::to_bits(score)`, index-aligned with `matched_ordinals`. The real parity check: bit-
    /// identical `f64` equality, not just integer-scaled agreement.
    pub matched_scores_bits: Vec<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PathMatchScoreError {
    InvalidRequest(String),
    Cancelled,
}

impl fmt::Display for PathMatchScoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest(value) => write!(formatter, "invalid path-match score request: {value}"),
            Self::Cancelled => formatter.write_str("path-match score compute cancelled"),
        }
    }
}
impl std::error::Error for PathMatchScoreError {}

// ---- encode (request-builder helpers; used by Rust unit tests and mirrored by the Swift codec) -

impl PathMatchScoreRequestV1 {
    /// `char_count` MUST be `PathMatcher.cleaned(value's pre-lowering cleaned form).count` (Swift
    /// grapheme count) and `cleaned_byte_len` MUST be that same pre-lowering cleaned form's
    /// `.utf8.count` -- both the Swift caller's authoritative values, NOT recomputed here. Rust
    /// unit tests may pass `value.chars().count() as u64` / `value.len() as u64` for plain-ASCII
    /// fixtures where scalar/grapheme/byte counts all coincide; see
    /// `guard_uses_precomputed_char_count_not_scalar_count` and
    /// `gate_uses_precomputed_cleaned_byte_len_not_lowered_text_len` for why those substitutions
    /// are unsafe for real (non-ASCII) input.
    pub fn push_string(&mut self, value: &str, char_count: u64, cleaned_byte_len: u64) -> u64 {
        let start = self.utf8_blob.len() as u64;
        self.utf8_blob.extend_from_slice(value.as_bytes());
        let end = self.utf8_blob.len() as u64;
        let index = (self.string_range_words.len() / STRING_RANGE_STRIDE) as u64;
        self.string_range_words.push(start);
        self.string_range_words.push(end);
        self.char_count_words.push(char_count);
        self.cleaned_byte_len_words.push(cleaned_byte_len);
        index
    }

    /// `components` are `(text, char_count, cleaned_byte_len)` triples -- see `push_string`'s doc.
    pub fn push_query(&mut self, components: &[(&str, u64, u64)]) {
        self.query_indices =
            components.iter().map(|&(text, count, byte_len)| self.push_string(text, count, byte_len)).collect();
    }

    /// `tail` are `(text, char_count, cleaned_byte_len)` triples -- see `push_string`'s doc.
    pub fn push_candidate(
        &mut self,
        root_ordinal: u64,
        total_component_count: u64,
        tail: &[(&str, u64, u64)],
        ordinal: u64,
    ) {
        let tail_start = self.candidate_tail_indices.len() as u64;
        for &(text, count, byte_len) in tail {
            let idx = self.push_string(text, count, byte_len);
            self.candidate_tail_indices.push(idx);
        }
        let tail_count = self.candidate_tail_indices.len() as u64 - tail_start;
        self.candidate_words.extend([
            root_ordinal,
            total_component_count,
            tail_start,
            tail_count,
            ordinal,
        ]);
    }
}

// ---- decode + fail-closed validation -----------------------------------------------------------

fn usize_word(value: u64) -> Result<usize, PathMatchScoreError> {
    usize::try_from(value)
        .map_err(|_| PathMatchScoreError::InvalidRequest("compact word exceeds platform index".into()))
}

fn validate_shape(request: &PathMatchScoreRequestV1) -> Result<(), PathMatchScoreError> {
    if request.string_range_words.len() % STRING_RANGE_STRIDE != 0 {
        return Err(PathMatchScoreError::InvalidRequest(
            "string_range_words length is not a multiple of STRING_RANGE_STRIDE".into(),
        ));
    }
    if request.candidate_words.len() % CANDIDATE_STRIDE != 0 {
        return Err(PathMatchScoreError::InvalidRequest(
            "candidate_words length is not a multiple of CANDIDATE_STRIDE".into(),
        ));
    }
    let pooled_count = request.string_range_words.len() / STRING_RANGE_STRIDE;
    if request.char_count_words.len() != pooled_count {
        return Err(PathMatchScoreError::InvalidRequest(
            "char_count_words length does not match the pooled string count".into(),
        ));
    }
    if request.cleaned_byte_len_words.len() != pooled_count {
        return Err(PathMatchScoreError::InvalidRequest(
            "cleaned_byte_len_words length does not match the pooled string count".into(),
        ));
    }
    Ok(())
}

/// A decoded pooled string plus its caller-supplied grapheme count and pre-lowering cleaned byte
/// length (see `push_string`'s doc and the module doc's points 3 and 4). The text is used for both
/// the `firstAlnumLowercasedByte` guard and the Levenshtein similarity; `char_count` is used only
/// for the length guard; `cleaned_byte_len` is used only for the 256-byte gate.
struct PooledComponent<'a> {
    text: &'a str,
    char_count: i64,
    cleaned_byte_len: usize,
}

fn decode_string(request: &PathMatchScoreRequestV1, index: u64) -> Result<PooledComponent<'_>, PathMatchScoreError> {
    let row = usize_word(index)?;
    let base = row
        .checked_mul(STRING_RANGE_STRIDE)
        .ok_or_else(|| PathMatchScoreError::InvalidRequest("string pool index overflow".into()))?;
    let range = request
        .string_range_words
        .get(base..base + STRING_RANGE_STRIDE)
        .ok_or_else(|| PathMatchScoreError::InvalidRequest("string pool index out of range".into()))?;
    let start = usize_word(range[0])?;
    let end = usize_word(range[1])?;
    if end < start || end > request.utf8_blob.len() {
        return Err(PathMatchScoreError::InvalidRequest("string range out of bounds".into()));
    }
    // Non-stripping UTF-8 decode: `str::from_utf8` validates without ever discarding bytes (e.g. a
    // legitimate leading U+FEFF stays byte-aligned), and rejects malformed input fail-closed.
    let text = std::str::from_utf8(&request.utf8_blob[start..end])
        .map_err(|_| PathMatchScoreError::InvalidRequest("string range is not valid UTF-8".into()))?;
    let char_count = *request
        .char_count_words
        .get(row)
        .ok_or_else(|| PathMatchScoreError::InvalidRequest("char count pool index out of range".into()))?;
    let char_count = i64::try_from(char_count)
        .map_err(|_| PathMatchScoreError::InvalidRequest("char count exceeds platform index".into()))?;
    let cleaned_byte_len = *request
        .cleaned_byte_len_words
        .get(row)
        .ok_or_else(|| PathMatchScoreError::InvalidRequest("cleaned byte len pool index out of range".into()))?;
    let cleaned_byte_len = usize_word(cleaned_byte_len)?;
    Ok(PooledComponent { text, char_count, cleaned_byte_len })
}

fn decode_query(request: &PathMatchScoreRequestV1) -> Result<Vec<PooledComponent<'_>>, PathMatchScoreError> {
    request.query_indices.iter().map(|&index| decode_string(request, index)).collect()
}

fn decode_tail<'a>(
    request: &'a PathMatchScoreRequestV1,
    tail_start: u64,
    tail_count: u64,
    query_len: usize,
) -> Result<Vec<PooledComponent<'a>>, PathMatchScoreError> {
    let start = usize_word(tail_start)?;
    let count = usize_word(tail_count)?;
    if count != query_len {
        return Err(PathMatchScoreError::InvalidRequest(
            "candidate tail length does not match query length".into(),
        ));
    }
    let end = start
        .checked_add(count)
        .ok_or_else(|| PathMatchScoreError::InvalidRequest("candidate tail range overflow".into()))?;
    let indices = request
        .candidate_tail_indices
        .get(start..end)
        .ok_or_else(|| PathMatchScoreError::InvalidRequest("candidate tail range out of bounds".into()))?;
    indices.iter().map(|&index| decode_string(request, index)).collect()
}

// ---- scoring kernel -----------------------------------------------------------------------------

/// Mirrors `PathMatcher.firstAlnumLowercasedByte`: pure byte-value scan, no Foundation dependency,
/// so it's ported verbatim regardless of the cleaning/casing scope boundary above.
fn first_alnum_lowered_byte(s: &str) -> Option<u8> {
    for b in s.bytes() {
        if b.is_ascii_digit() {
            return Some(b);
        }
        if b.is_ascii_uppercase() {
            return Some(b + 32);
        }
        if b.is_ascii_lowercase() {
            return Some(b);
        }
    }
    None
}

const MAX_SIMILARITY_BYTE_LEN: usize = 256;

/// Mirrors `PathMatcher.levenshteinDistanceCapped<T: Equatable>`, specialized to `char`
/// (Unicode scalars) since that's the only element type this kernel ever needs.
fn levenshtein_distance_capped(a_in: &[char], b_in: &[char], max_dist: i64) -> i64 {
    let big = max_dist + 1;
    if max_dist < 0 {
        return big;
    }
    let (mut a, mut b) = (a_in, b_in);
    if a.is_empty() {
        return b.len() as i64;
    }
    if b.is_empty() {
        return a.len() as i64;
    }
    if a.len() > b.len() {
        std::mem::swap(&mut a, &mut b);
    }
    let len_a = a.len() as i64;
    let len_b = b.len() as i64;
    if (len_a - len_b).abs() > max_dist {
        return big;
    }
    if max_dist == 0 {
        if len_a != len_b {
            return big;
        }
        return if a == b { 0 } else { big };
    }

    let len_b_usize = b.len();
    let mut prev = vec![big; len_b_usize + 1];
    let mut curr = vec![big; len_b_usize + 1];
    prev[0] = 0;
    let hi0 = max_dist.min(len_b) as usize;
    for (j, slot) in prev.iter_mut().enumerate().take(hi0 + 1).skip(1) {
        *slot = j as i64;
    }

    for i in 1..=len_a {
        let j_lo = (i - max_dist).max(1);
        let j_hi = (i + max_dist).min(len_b);
        for slot in curr.iter_mut() {
            *slot = big;
        }
        if j_lo == 1 {
            curr[0] = i;
        }
        let mut row_min = big;
        for j in j_lo..=j_hi {
            let ju = j as usize;
            let ins = curr[ju - 1] + 1;
            let del = prev[ju] + 1;
            let sub = prev[ju - 1] + i64::from(a[(i - 1) as usize] != b[ju - 1]);
            let v = ins.min(del).min(sub);
            curr[ju] = v;
            if v < row_min {
                row_min = v;
            }
        }
        if row_min > max_dist {
            return big;
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    let dist = prev[len_b_usize];
    if dist > max_dist { big } else { dist }
}

/// Mirrors `PathMatcher.similarityScore`. `a`/`b` are already compare-ready (cleaned, lowercased)
/// per the module doc's scope boundary, so there is no `caseSensitive` parameter here.
/// `gate_byte_len` is `max(a's, b's) PRE-lowering cleaned UTF-8 byte length` -- see the module
/// doc's point 4 for why this can't be recomputed from `a.len()`/`b.len()` (the LOWERED text).
fn similarity_score(a: &str, b: &str, threshold: f64, strip_separators: bool, gate_byte_len: usize) -> f64 {
    if a.is_empty() && b.is_empty() {
        return 1.0;
    }
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let t = threshold.clamp(0.0, 1.0);

    if gate_byte_len > MAX_SIMILARITY_BYTE_LEN {
        // See module doc point 2: inputs are already Swift-lowered, so plain equality here is the
        // Rust-side realization of Swift's `caseInsensitiveCompare` fallback.
        return if a == b { 1.0 } else { 0.0 };
    }

    // Uniform Unicode-scalar comparison: for ASCII input this is byte-for-byte identical to
    // Swift's byte fast path; for non-ASCII it matches Swift's `unicodeSimilarityScore` scalar
    // path. The ASCII-lowering pass below is harmless/idempotent on the already-lowered input
    // (see module doc point 2) -- ported for parity with Swift's own redundant re-lowering.
    let a_chars: Vec<char> = a
        .chars()
        .map(policy::to_lower_ascii_char)
        .filter(|&c| !(strip_separators && (c == '-' || c == '_')))
        .collect();
    let b_chars: Vec<char> = b
        .chars()
        .map(policy::to_lower_ascii_char)
        .filter(|&c| !(strip_separators && (c == '-' || c == '_')))
        .collect();

    let max_len = a_chars.len().max(b_chars.len());
    if max_len == 0 {
        return 1.0;
    }
    if t >= 1.0 {
        return if a_chars == b_chars { 1.0 } else { 0.0 };
    }
    let max_dist = ((1.0 - t) * max_len as f64).ceil() as i64;
    let dist = levenshtein_distance_capped(&a_chars, &b_chars, max_dist);
    if dist > max_dist {
        0.0
    } else {
        1.0 - dist as f64 / max_len as f64
    }
}

/// Mirrors `PathMatcher.similarityScoreMax`.
fn similarity_score_max(a: &str, b: &str, threshold: f64, gate_byte_len: usize) -> f64 {
    let base = similarity_score(a, b, threshold, false, gate_byte_len);
    let folded = similarity_score(a, b, threshold, true, gate_byte_len);
    base.max(folded)
}

/// Mirrors `PathMatcher.computeWeightedMatchScorePrecleaned`. `query` and `candidate_tail` are
/// both already cleaned+lowercased and in forward order (filename last); `candidate_tail.len()`
/// MUST equal `query.len()` (the caller/decoder is responsible for that -- see `decode_tail`).
/// Returns `None` for every early-exit `nil` outcome in the Swift source.
fn weighted_component_score(
    query: &[PooledComponent<'_>],
    candidate_total_component_count: usize,
    candidate_tail: &[PooledComponent<'_>],
    threshold: f64,
) -> Option<f64> {
    debug_assert_eq!(query.len(), candidate_tail.len());
    if candidate_total_component_count < query.len() {
        return None;
    }

    let n = query.len();
    let mut total_score = 0.0_f64;
    let mut matched_count: i64 = 0;

    for i in 0..n {
        let user_index = n - 1 - i;
        let path_index = n - 1 - i;
        let user_comp = &query[user_index];
        let path_comp = &candidate_tail[path_index];

        if let (Some(u), Some(p)) =
            (first_alnum_lowered_byte(user_comp.text), first_alnum_lowered_byte(path_comp.text))
        {
            if u != p {
                return None;
            }
        }

        // Precomputed Swift grapheme count -- NOT `text.chars().count()` (scalar count). See the
        // module doc's point 3: these regimes provably diverge for real input.
        if (user_comp.char_count - path_comp.char_count).abs() > 6 {
            return None;
        }

        let component_threshold = if i == 0 { threshold + 0.05 } else { threshold };
        // Precomputed pre-lowering cleaned byte lengths -- see the module doc's point 4.
        let gate_byte_len = user_comp.cleaned_byte_len.max(path_comp.cleaned_byte_len);
        let sim = similarity_score_max(user_comp.text, path_comp.text, component_threshold, gate_byte_len);
        if sim < component_threshold {
            return None;
        }

        let weight = if i == 0 { 2.0 } else { 1.0 };
        total_score += sim * weight;
        matched_count += 1;
    }

    let depth_penalty = (candidate_total_component_count - n) as f64;
    let match_bonus = matched_count as f64 * 0.1;
    Some(total_score - depth_penalty + match_bonus)
}

/// Bonus added when a candidate's root is in `selected_root_ordinals` -- mirrors
/// `PathMatcher.rootSelectionBonus`.
const ROOT_SELECTION_BONUS: f64 = 0.5;

// ---- service --------------------------------------------------------------------------------

#[derive(Default)]
pub struct PathMatchScoreService;

impl PathMatchScoreService {
    pub fn compute(&self, request: &PathMatchScoreRequestV1) -> Result<PathMatchScoreResultV1, PathMatchScoreError> {
        self.compute_with_cancellation(request, None)
    }

    pub fn compute_with_cancellation(
        &self,
        request: &PathMatchScoreRequestV1,
        cancellation: Option<&crate::LeafCancellation>,
    ) -> Result<PathMatchScoreResultV1, PathMatchScoreError> {
        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(PathMatchScoreError::Cancelled);
        }
        if request.contract_version != PATH_MATCH_CONTRACT_VERSION_V1 {
            return Err(PathMatchScoreError::InvalidRequest(format!(
                "unknown contract version {}",
                request.contract_version
            )));
        }
        if !(0.0..=1.0).contains(&request.threshold) {
            return Err(PathMatchScoreError::InvalidRequest("threshold must be within [0, 1]".into()));
        }
        validate_shape(request)?;
        let query = decode_query(request)?;
        let selected: HashSet<u64> = request.selected_root_ordinals.iter().copied().collect();

        let mut result = PathMatchScoreResultV1::default();
        let candidate_count = request.candidate_words.len() / CANDIDATE_STRIDE;
        for row_index in 0..candidate_count {
            if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
                return Err(PathMatchScoreError::Cancelled);
            }
            let base = row_index * CANDIDATE_STRIDE;
            let row = &request.candidate_words[base..base + CANDIDATE_STRIDE];
            let root_ordinal = row[0];
            let total_component_count = usize_word(row[1])?;
            let tail_start = row[2];
            let tail_count = row[3];
            let ordinal = row[4];

            if total_component_count < query.len() {
                continue;
            }
            let tail = decode_tail(request, tail_start, tail_count, query.len())?;
            if let Some(score) = weighted_component_score(&query, total_component_count, &tail, request.threshold) {
                let adjusted = score + if selected.contains(&root_ordinal) { ROOT_SELECTION_BONUS } else { 0.0 };
                result.matched_ordinals.push(ordinal);
                result.matched_scores_scaled.push((adjusted * SCORE_SCALE).round() as i64);
                result.matched_scores_bits.push(adjusted.to_bits());
            }
        }
        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(PathMatchScoreError::Cancelled);
        }
        Ok(result)
    }
}

// ---- tests --------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn request(threshold: f64) -> PathMatchScoreRequestV1 {
        PathMatchScoreRequestV1 {
            contract_version: PATH_MATCH_CONTRACT_VERSION_V1,
            threshold,
            ..Default::default()
        }
    }

    fn score_at(request: &PathMatchScoreRequestV1, ordinal: u64) -> Option<(i64, f64)> {
        let response = PathMatchScoreService.compute(request).unwrap();
        response
            .matched_ordinals
            .iter()
            .position(|&o| o == ordinal)
            .map(|i| (response.matched_scores_scaled[i], f64::from_bits(response.matched_scores_bits[i])))
    }

    /// Test-only convenience: plain-ASCII fixtures where byte/scalar/grapheme counts all coincide,
    /// so `text.chars().count()`/`text.len()` are safe stand-ins for the Swift-authoritative
    /// grapheme count and cleaned byte length `push_string` otherwise requires explicitly. See
    /// `guard_uses_precomputed_char_count_not_scalar_count` and
    /// `gate_uses_precomputed_cleaned_byte_len_not_lowered_text_len` for why these substitutions
    /// are UNSAFE for real non-ASCII input (that's exactly the bugs these wire fields prevent).
    fn ascii_pairs<'a>(components: &[&'a str]) -> Vec<(&'a str, u64, u64)> {
        components.iter().map(|&c| (c, c.chars().count() as u64, c.len() as u64)).collect()
    }

    trait AsciiPush {
        fn push_ascii_query(&mut self, components: &[&str]);
        fn push_ascii_candidate(&mut self, root_ordinal: u64, total_component_count: u64, tail: &[&str], ordinal: u64);
    }
    impl AsciiPush for PathMatchScoreRequestV1 {
        fn push_ascii_query(&mut self, components: &[&str]) {
            self.push_query(&ascii_pairs(components));
        }
        fn push_ascii_candidate(&mut self, root_ordinal: u64, total_component_count: u64, tail: &[&str], ordinal: u64) {
            self.push_candidate(root_ordinal, total_component_count, &ascii_pairs(tail), ordinal);
        }
    }

    #[test]
    fn exact_filename_match_uses_filename_weight_two() {
        let mut req = request(0.9);
        req.push_ascii_query(&["app.swift"]);
        req.push_ascii_candidate(0, 1, &["app.swift"], 1);
        let (_, score) = score_at(&req, 1).expect("expected a match");
        // sim=1.0 * weight 2.0, depth penalty 0, match bonus 0.1 * 1 = 0.1 -> 2.1
        assert!((score - 2.1).abs() < 1e-9, "score was {score}");
    }

    #[test]
    fn directory_component_uses_weight_one() {
        let mut req = request(0.9);
        req.push_ascii_query(&["src", "app.swift"]);
        req.push_ascii_candidate(0, 2, &["src", "app.swift"], 1);
        let (_, score) = score_at(&req, 1).expect("expected a match");
        // filename: 1.0*2.0, dir: 1.0*1.0, depth penalty 0, match bonus 0.1*2=0.2 -> 3.2
        assert!((score - 3.2).abs() < 1e-9, "score was {score}");
    }

    #[test]
    fn depth_penalty_subtracts_one_per_extra_component() {
        let mut req = request(0.9);
        req.push_ascii_query(&["app.swift"]);
        req.push_ascii_candidate(0, 4, &["app.swift"], 1);
        let (_, score) = score_at(&req, 1).expect("expected a match");
        // sim 1.0*2.0 - depth penalty 3 + match bonus 0.1 -> -0.9
        assert!((score - (-0.9)).abs() < 1e-9, "score was {score}");
    }

    #[test]
    fn selected_root_bonus_is_applied() {
        let mut req = request(0.9);
        req.push_ascii_query(&["app.swift"]);
        req.push_ascii_candidate(7, 1, &["app.swift"], 1);
        req.selected_root_ordinals = vec![7];
        let (_, score) = score_at(&req, 1).expect("expected a match");
        assert!((score - 2.6).abs() < 1e-9, "score was {score}"); // 2.1 + 0.5
    }

    #[test]
    fn non_selected_root_gets_no_bonus() {
        let mut req = request(0.9);
        req.push_ascii_query(&["app.swift"]);
        req.push_ascii_candidate(7, 1, &["app.swift"], 1);
        req.selected_root_ordinals = vec![99];
        let (_, score) = score_at(&req, 1).expect("expected a match");
        assert!((score - 2.1).abs() < 1e-9, "score was {score}");
    }

    #[test]
    fn filename_threshold_bump_rejects_below_plus_point_zero_five() {
        // "app.swift" vs "apt.swift": 1 substitution out of 9 chars -> sim ~0.888..., which
        // clears a bare 0.85 threshold but not 0.85+0.05=0.90 at the filename position.
        let mut req = request(0.85);
        req.push_ascii_query(&["app.swift"]);
        req.push_ascii_candidate(0, 1, &["apt.swift"], 1);
        assert!(score_at(&req, 1).is_none());
    }

    #[test]
    fn exact_match_only_threshold_disables_filename_position_entirely() {
        // Real (if surprising) Swift semantics, ported verbatim: `componentThreshold` for the
        // filename position is `threshold + 0.05` UNCLAMPED, so at `exactMatchOnly`'s 0.9999 it
        // becomes 1.0499 -- higher than the maximum achievable `sim` (1.0). `sim < componentThreshold`
        // is therefore true even for a byte-identical filename, so `fuzzyMatchWithSuffixLimit`'s
        // scoring path can NEVER match on the filename component when `exactMatchOnly` reaches it
        // (production relies on `findStrictSuffixMatch` running first for real exact-match hits).
        let mut req = request(0.9999);
        req.push_ascii_query(&["app.swift"]);
        req.push_ascii_candidate(0, 1, &["apt.swift"], 1);
        req.push_ascii_candidate(0, 1, &["app.swift"], 2); // byte-identical candidate
        assert!(score_at(&req, 1).is_none());
        assert!(score_at(&req, 2).is_none(), "even a byte-identical filename is rejected at this threshold");
    }

    #[test]
    fn separator_fold_lets_dash_underscore_variants_match() {
        let mut req = request(0.9);
        req.push_ascii_query(&["foo-bar.swift"]);
        req.push_ascii_candidate(0, 1, &["foobar.swift"], 1);
        assert!(score_at(&req, 1).is_some(), "expected stripSeparators branch to win via max()");
    }

    #[test]
    fn first_alnum_byte_mismatch_rejects_immediately() {
        let mut req = request(0.5); // very lax threshold -- guard must still reject
        req.push_ascii_query(&["zzz.swift"]);
        req.push_ascii_candidate(0, 1, &["aaa.swift"], 1);
        assert!(score_at(&req, 1).is_none());
    }

    #[test]
    fn length_diff_guard_rejects_beyond_six() {
        let mut req = request(0.1); // very lax threshold -- guard must still reject
        req.push_ascii_query(&["a.swift"]);
        req.push_ascii_candidate(0, 1, &["aaaaaaaaaaaaaaa.swift"], 1); // +14 vs 7 => diff way past 6
        assert!(score_at(&req, 1).is_none());
    }

    #[test]
    fn candidate_shorter_than_query_is_immediate_nil() {
        let mut req = request(0.5);
        req.push_ascii_query(&["src", "app.swift"]);
        req.push_ascii_candidate(0, 1, &[], 1); // total_component_count(1) < query.len()(2)
        assert!(score_at(&req, 1).is_none());
    }

    #[test]
    fn byte_length_over_256_falls_back_to_exact_equality_only() {
        let long_a = "a".repeat(300);
        let long_b_diff_one = {
            let mut s = "a".repeat(299);
            s.push('b');
            s
        };
        let mut req = request(0.5); // lax threshold: only the 256-gate should decide this
        req.push_ascii_query(&[long_a.as_str()]);
        req.push_ascii_candidate(0, 1, &[long_a.as_str()], 1);
        req.push_ascii_candidate(0, 1, &[long_b_diff_one.as_str()], 2);
        assert!(score_at(&req, 1).is_some(), "identical >256-byte strings must match");
        assert!(score_at(&req, 2).is_none(), "one-byte-different >256-byte strings must not match");
    }

    #[test]
    fn byte_length_gate_uses_max_of_both_original_lengths() {
        // Short query against a >256-byte candidate: gate still trips because it's max(a,b).
        let long = "a".repeat(300);
        let mut req = request(0.5);
        req.push_ascii_query(&["a"]);
        req.push_ascii_candidate(0, 1, &[long.as_str()], 1);
        assert!(score_at(&req, 1).is_none(), "short vs long-different must fail via the 256 gate, not Levenshtein");
    }

    #[test]
    fn empty_query_scores_only_via_depth_penalty() {
        let mut req = request(0.5);
        req.push_ascii_query(&[]);
        req.push_ascii_candidate(0, 3, &[], 1);
        let (_, score) = score_at(&req, 1).expect("expected a match (empty query always satisfies the loop)");
        assert!((score - (-3.0)).abs() < 1e-9, "score was {score}");
    }

    #[test]
    fn non_matching_candidates_are_absent_from_the_response() {
        let mut req = request(0.9);
        req.push_ascii_query(&["app.swift"]);
        req.push_ascii_candidate(0, 1, &["app.swift"], 1);
        req.push_ascii_candidate(0, 1, &["zzzzzzzz.swift"], 2);
        let response = PathMatchScoreService.compute(&req).unwrap();
        assert_eq!(response.matched_ordinals, vec![1]);
    }

    #[test]
    fn rejects_unknown_contract_version() {
        let mut req = request(0.9);
        req.contract_version = 999;
        req.push_ascii_query(&["app.swift"]);
        req.push_ascii_candidate(0, 1, &["app.swift"], 1);
        assert!(matches!(
            PathMatchScoreService.compute(&req),
            Err(PathMatchScoreError::InvalidRequest(_))
        ));
    }

    #[test]
    fn rejects_out_of_range_threshold() {
        let mut req = request(1.5);
        req.push_ascii_query(&["app.swift"]);
        assert!(matches!(
            PathMatchScoreService.compute(&req),
            Err(PathMatchScoreError::InvalidRequest(_))
        ));
    }

    #[test]
    fn cancellation_before_compute_is_reported() {
        let identity = crate::RuntimeIdentity::fresh(&"a".repeat(64), &"b".repeat(64)).unwrap();
        let cancellation = crate::LeafCancellation::new(identity);
        cancellation.cancel();
        let mut req = request(0.9);
        req.push_ascii_query(&["app.swift"]);
        req.push_ascii_candidate(0, 1, &["app.swift"], 1);
        assert!(matches!(
            PathMatchScoreService.compute_with_cancellation(&req, Some(&cancellation)),
            Err(PathMatchScoreError::Cancelled)
        ));
    }

    #[test]
    fn similarity_score_max_matches_bare_and_folded_branches() {
        assert!((similarity_score_max("foobar", "foobar", 0.9, 6) - 1.0).abs() < 1e-9);
        assert!(similarity_score_max("foo-bar", "foo_bar", 0.99, 7) >= 0.99);
    }

    #[test]
    fn levenshtein_capped_matches_uncapped_for_small_inputs() {
        let a: Vec<char> = "kitten".chars().collect();
        let b: Vec<char> = "sitting".chars().collect();
        assert_eq!(levenshtein_distance_capped(&a, &b, 10), 3);
        assert_eq!(levenshtein_distance_capped(&a, &b, 3), 3); // maxDist exactly covers the true distance
    }

    #[test]
    fn levenshtein_capped_returns_big_when_exceeding_cap() {
        let a: Vec<char> = "kitten".chars().collect();
        let b: Vec<char> = "sitting".chars().collect();
        let capped = levenshtein_distance_capped(&a, &b, 1);
        assert_eq!(capped, 2); // big = maxDist+1 = 2, actual distance 3 > 1
    }

    #[test]
    fn guard_uses_precomputed_char_count_not_scalar_count() {
        // Reproduces the real divergence `PathMatchRustSwiftDifferentialTests` found: a Devanagari
        // virama cluster ("\u{0915}\u{094D}\u{0916}") is ONE Swift grapheme over THREE Unicode
        // scalars. A query/candidate pair built from repeated clusters has a small grapheme-count
        // difference (passes Swift's real guard) but a large scalar-count difference (would
        // incorrectly fail a scalar-counting guard). Supplying the TRUE (grapheme) counts must
        // match; supplying scalar counts (the old, buggy behavior) must reject.
        let cluster = "\u{0915}\u{094D}\u{0916}";
        let query_text = format!("test{}.swift", cluster.repeat(5));
        let candidate_text = format!("test{}.swift", cluster.repeat(8));
        // "test" (4) + 5 clusters (5 graphemes) + ".swift" (6) = 15 graphemes for the query;
        // "test" (4) + 8 clusters (8 graphemes) + ".swift" (6) = 18 for the candidate: diff = 3.
        let query_grapheme_count = 4 + 5 + 6;
        let candidate_grapheme_count = 4 + 8 + 6;
        assert_eq!((query_grapheme_count - candidate_grapheme_count as i64).unsigned_abs(), 3);

        let mut req_with_true_counts = request(0.5);
        req_with_true_counts.push_query(&[(query_text.as_str(), query_grapheme_count as u64, query_text.len() as u64)]);
        req_with_true_counts.push_candidate(
            0,
            1,
            &[(candidate_text.as_str(), candidate_grapheme_count as u64, candidate_text.len() as u64)],
            1,
        );
        assert!(
            score_at(&req_with_true_counts, 1).is_some(),
            "true grapheme counts (diff=3) must clear the length guard, matching Swift"
        );

        let mut req_with_scalar_counts = request(0.5);
        let query_scalar_count = query_text.chars().count() as u64;
        let candidate_scalar_count = candidate_text.chars().count() as u64;
        assert!(candidate_scalar_count - query_scalar_count > 6, "fixture must exceed the guard via scalar counting");
        req_with_scalar_counts.push_query(&[(query_text.as_str(), query_scalar_count, query_text.len() as u64)]);
        req_with_scalar_counts.push_candidate(
            0,
            1,
            &[(candidate_text.as_str(), candidate_scalar_count, candidate_text.len() as u64)],
            1,
        );
        assert!(
            score_at(&req_with_scalar_counts, 1).is_none(),
            "scalar counts (diff=9) must trip the length guard -- this is the bug the precomputed-count wire field exists to avoid"
        );
    }

    #[test]
    fn gate_reads_precomputed_length_rather_than_text_len() {
        // Unit-level check that `similarity_score`'s 256-byte gate actually reads
        // `PooledComponent::cleaned_byte_len` and NOT `text.len()`: two synthetic 200-byte texts
        // are scored once with a small precomputed gate length (must take the real Levenshtein DP
        // path) and once with a large one (must take the exact-equality-only fallback), proving the
        // field -- not the pooled text's own length -- decides the branch. This is a mechanism
        // check with synthetic values, not a Unicode reproduction; see
        // `PathMatchRustSwiftDifferentialTests.testByteGateUsesPreLoweringLengthAcrossTheLoweringByteGrowthBoundary`
        // for the real İ (U+0130, 2-to-3-byte lowering growth) fixture that found this bug.
        let query_text = "a".repeat(200); // pretend "lowered" form -- see below
        let mut candidate_text = "a".repeat(199);
        candidate_text.push('b'); // one substitution near the end

        let mut req_with_true_len = request(0.5);
        // Pretend the TRUE pre-lowering cleaned length is small (well under 256) even though the
        // pooled text itself is exactly 200 bytes (already under 256 here too, but the point is
        // this value -- NOT `text.len()` -- decides the gate).
        req_with_true_len.push_query(&[(query_text.as_str(), query_text.chars().count() as u64, 10)]);
        req_with_true_len.push_candidate(0, 1, &[(candidate_text.as_str(), candidate_text.chars().count() as u64, 10)], 1);
        let (_, true_len_score) = score_at(&req_with_true_len, 1).expect("small precomputed gate length must take the DP path and match");
        assert!(true_len_score > 0.9, "expected a high-similarity DP match, got {true_len_score}");

        let mut req_with_lowered_len = request(0.5);
        // Now pretend the precomputed length is the pooled text's own (>256) length -- the old,
        // buggy stand-in this field exists to replace.
        let over_gate = 300_u64;
        req_with_lowered_len.push_query(&[(query_text.as_str(), query_text.chars().count() as u64, over_gate)]);
        req_with_lowered_len.push_candidate(
            0,
            1,
            &[(candidate_text.as_str(), candidate_text.chars().count() as u64, over_gate)],
            1,
        );
        assert!(
            score_at(&req_with_lowered_len, 1).is_none(),
            "large precomputed gate length must take the exact-equality fallback and reject a near-but-not-identical pair"
        );
    }
}
