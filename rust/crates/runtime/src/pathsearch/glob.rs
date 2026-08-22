//! Port of `pattern_decompose` / the glob-to-regex translation and matching from
//! `path_search.c`, plus the `strcasestr`-based space-separated AND-term mode.
//!
//! # C-semantics decision table
//!
//! | C behavior (`path_search.c`) | Rust port decision |
//! |---|---|
//! | `is_wildcard = strpbrk(pattern, "*?") != NULL` | Identical: any byte `*`/`?` anywhere in the pattern. |
//! | `has_spaces = strchr(pattern,' ') && !is_wildcard` | Identical: literal ASCII `' '` (0x20) only — not `\t`/other whitespace, matching `strchr`. |
//! | Literal prefix/suffix scan uses `meta_chars = "*?[]{}()|.+^$\\"` (14 bytes) to bound the literal run before the first / after the last metachar, only when `is_wildcard` | Ported byte-for-byte via [`META_CHARS`]; used only to size the `forward_paths`/`reversed_paths` binary-search bound (an optimization, not part of match semantics) — see `index.rs`. |
//! | Glob body translation: `*` + another `*` -> consume both, emit "match any bytes" (`.*`); lone `*` -> "match any non-`/` bytes" (`[^/]*`); `?` -> "match exactly one non-`/` byte" (`[^/]`); other regex metachars `[]{}().|+^$\` -> literal byte; anything else -> literal byte | Ported as [`Token`] construction in [`build_tokens`], run over **every** byte of the original pattern regardless of what fed the leading-anchor decision (this reproduces a real C quirk: a pattern that starts with a single `*` gets *both* a free-start `.*` **and** a `[^/]*` token for that same `*`, which is redundant but harmless — see `build_tokens` doc). |
//! | Leading anchor: `.*` if `!is_wildcard`, else `.*` if `pattern[0]=='*'`, else `^` | Ported as an optional leading [`Token::StarAny`]; "`^`" is simply "no leading star token" since our matcher requires the token sequence to consume the **entire** subject (see [`matches`]). |
//! | Trailing anchor: `.*` if `!is_wildcard`, else `$` | Ported as an optional trailing [`Token::StarAny`] for literal mode; wildcard mode needs no trailing token because [`matches`] always requires full consumption. |
//! | `regcomp(..., REG_EXTENDED \| REG_ICASE)` / `regexec` case-insensitivity | POSIX `REG_ICASE` under the process's locale — pinned here as **ASCII-only** case folding (`A`-`Z` <-> `a`-`z`); non-ASCII bytes must match byte-for-byte, exactly like `strcasestr`'s C-locale behavior. Implemented via the existing [`crate::pathmatch::to_lower_ascii`] table (already unit-tested against the Swift ASCII-lowering table). |
//! | `.` (dot-any) implicitly matches embedded `\n` because `REG_NEWLINE` is never set | [`Token::StarAny`]/[`Token::StarNonSlash`] have no special-case for `\n`; only `/` is excluded (matching `[^/]`). This matters for `path_search_projected_find_cancellable`, whose matched subject embeds a literal `\n` separator — see `engine.rs`. |
//! | `^`/`$` anchor the *whole subject*, not per-line (no `REG_NEWLINE`) | [`matches`] always matches the whole subject byte range `0..subject.len()`; there is no multi-line mode. |
//! | Regex match is boolean existence only (`regexec(...) == 0`), no submatch/leftmost-longest semantics observable | [`matches`] only returns `bool`; see the module-level parity argument in `pathsearch::mod` doc for why backtracking-vs-POSIX-longest doesn't change match/no-match here. |
//! | `SPACE_AND:` mode: `strtok(pattern_copy, " ")` splits on literal spaces, skips empty tokens, caps at `term_count < 20` (terms beyond the 20th are silently dropped, not just ignored-but-parsed) | Ported in [`split_terms`]: split on `b' '`, filter empty, `take(20)`. |
//! | `strcasestr(path, term)` per term, AND across all terms; empty term list (e.g. pattern is only spaces) matches everything | Ported as [`ascii_case_insensitive_contains`] (ASCII-fold substring search, empty needle always matches) combined with `terms.iter().all(...)` (vacuously `true` for zero terms). |
//! | `strncmp`/binary-search "NUL-pads" the shorter operand | Not applicable to matching (`glob.rs`); ported for the *index* binary-search bounds in `index.rs`. |
//!
//! # Invalid glob -> regex edges
//!
//! There are none to fixture: the C translator escapes *every* ERE metachar
//! (`[]{}().|+^$\`) it encounters outside the dedicated `*`/`?`/`**` handling, so the ERE string
//! `regcomp` receives can never contain an unbalanced `[`, an unescaped `(`, etc. — `regcomp`
//! cannot fail on output from `pattern_decompose`. This Rust port goes further: [`build_tokens`]
//! has no "compile" step that can fail at all (there is no intermediate regex string to be
//! malformed), so a byte sequence like `"[*.swift"` (an unbalanced bracket immediately followed
//! by a wildcard) is not a special case — it just becomes `Token::Lit(b'[')` followed by the
//! usual `.swift` suffix tokens, matched byte-for-byte like any other literal.
//!
//! Not ported (out of scope / dead code in the source): `wildmatch.h` is `#include`d by
//! `path_search.c` but no `wildmatch_*` function is ever called from it, so there is nothing to
//! port from that header for this engine.

use crate::pathmatch::to_lower_ascii;

/// `meta_chars` from `pattern_decompose`, byte-for-byte: `*?[]{}()|.+^$\`.
const META_CHARS: &[u8] = b"*?[]{}()|.+^$\\";

/// The escape-set used inside the glob->token body loop (matches C's second, narrower
/// `strchr("[]{}().|+^$\\", c)` — `*` and `?` are handled separately before this check is
/// reached, so this set is `META_CHARS` minus `*` and `?`). Since both branches of the body loop
/// treat matched and unmatched bytes identically as literal-byte tokens, this set only exists
/// for documentation parity with the C source; it has no behavioral effect on [`build_tokens`].
#[allow(dead_code)]
const ESCAPE_CHARS: &[u8] = b"[]{}().|+^$\\";

/// Maximum number of space-separated AND terms honored by `SPACE_AND` mode, mirroring the C
/// engine's fixed `char* terms[20]` stack array and its `term_count < 20` guard.
const MAX_SPACE_TERMS: usize = 20;

/// A single token in the compiled glob body, mirroring one construct emitted by the C
/// glob-to-regex translator.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Token {
    /// A single literal byte, matched with ASCII-only case-insensitive comparison. Covers both
    /// "ordinary" pattern bytes and the escaped-metachar case (`[]{}().|+^$\` -> literal), since
    /// both translate to a literal-byte match in the regex the C engine builds.
    Lit(u8),
    /// `[^/]` — exactly one byte that is not `/`.
    AnyNonSlash,
    /// `[^/]*` — zero or more bytes, none of which is `/`.
    StarNonSlash,
    /// `.*` — zero or more bytes of any value (including `/` and `\n`).
    StarAny,
}

/// The two mutually exclusive matching strategies `pattern_decompose` can select, mirroring the
/// `SPACE_AND:` marker-prefix branch vs. the regular regex branch in `path_search.c`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Mode {
    /// Space-separated AND-substring search: every term must be an ASCII-case-insensitive
    /// substring of the subject. Terms are raw bytes (not lowercased) since comparison folds at
    /// match time; capped at [`MAX_SPACE_TERMS`].
    SpaceAnd(Vec<Vec<u8>>),
    /// Compiled glob token sequence, matched via [`matches`].
    Glob(Vec<Token>),
}

/// Rust port of `pattern_parts_t` / `pattern_decompose`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PatternParts {
    /// Longest literal byte run before the first metachar (empty when the pattern has no
    /// `*`/`?`, or when the pattern starts with a metachar). Used only for the optional
    /// prefix binary-search bound in `index.rs`; never used for matching directly.
    pub prefix: Vec<u8>,
    /// Longest literal byte run after the last metachar (empty unless the pattern has a
    /// `*`/`?`). Used only for the optional suffix binary-search bound in `index.rs`.
    pub suffix: Vec<u8>,
    /// Whether the original pattern contained `*` or `?`.
    pub is_wildcard: bool,
    /// The compiled matching strategy.
    pub mode: Mode,
}

/// Rust port of `pattern_decompose`.
#[must_use]
pub fn decompose(pattern: &str) -> PatternParts {
    let bytes = pattern.as_bytes();
    let is_wildcard = bytes.iter().any(|&b| b == b'*' || b == b'?');
    let has_spaces = bytes.contains(&b' ') && !is_wildcard;

    let (prefix, suffix) = literal_bounds(bytes, is_wildcard);

    let mode = if has_spaces {
        Mode::SpaceAnd(split_terms(bytes, MAX_SPACE_TERMS))
    } else {
        Mode::Glob(build_tokens(bytes, is_wildcard))
    };

    PatternParts {
        prefix,
        suffix,
        is_wildcard,
        mode,
    }
}

/// Port of the prefix/suffix scanning in `pattern_decompose`. Only invoked (with a non-trivial
/// result) when `is_wildcard` is true, exactly like the C source.
fn literal_bounds(bytes: &[u8], is_wildcard: bool) -> (Vec<u8>, Vec<u8>) {
    if !is_wildcard {
        return (Vec::new(), Vec::new());
    }

    let len = bytes.len();
    let mut prefix_len = 0usize;
    for &b in bytes {
        if META_CHARS.contains(&b) {
            break;
        }
        prefix_len += 1;
    }
    let prefix = bytes[..prefix_len].to_vec();

    // Mirrors `for (i = len; i > prefix_len; i--) if (meta_chars contains pattern[i-1]) { ... }`:
    // scan from the end backward for the first (i.e. rightmost) metachar.
    let mut suffix_start = len;
    for i in (prefix_len + 1..=len).rev() {
        if META_CHARS.contains(&bytes[i - 1]) {
            suffix_start = i;
            break;
        }
    }
    let suffix = if suffix_start < len {
        bytes[suffix_start..].to_vec()
    } else {
        Vec::new()
    };

    (prefix, suffix)
}

/// Port of the glob->token body translation in `pattern_decompose` (the `for` loop plus the
/// leading/trailing anchor decisions that surround it).
///
/// Faithfully reproduces a real C quirk: the leading-anchor decision (`.*` vs `^`) is made by
/// peeking at `pattern[0]` *before* the body loop runs, but the body loop still processes
/// `pattern[0]` itself afterward. So a pattern starting with a single `*` (not `**`) emits a
/// leading [`Token::StarAny`] **and** a [`Token::StarNonSlash`] for that same character — the
/// second token is redundant (a [`Token::StarAny`] already permits anything `[^/]*` would) but
/// changes nothing about which subjects match, so we port the redundancy as-is rather than
/// special-casing it away.
fn build_tokens(bytes: &[u8], is_wildcard: bool) -> Vec<Token> {
    let len = bytes.len();
    let mut tokens = Vec::with_capacity(len + 2);

    if !is_wildcard || bytes.first() == Some(&b'*') {
        tokens.push(Token::StarAny);
    }

    let mut i = 0usize;
    while i < len {
        let c = bytes[i];
        if c == b'*' {
            if i + 1 < len && bytes[i + 1] == b'*' {
                tokens.push(Token::StarAny);
                i += 2;
            } else {
                tokens.push(Token::StarNonSlash);
                i += 1;
            }
        } else if c == b'?' {
            tokens.push(Token::AnyNonSlash);
            i += 1;
        } else {
            // Both the "escaped metachar" and "ordinary byte" branches in the C source produce a
            // literal-byte match; see `ESCAPE_CHARS` doc.
            tokens.push(Token::Lit(c));
            i += 1;
        }
    }

    if !is_wildcard {
        tokens.push(Token::StarAny);
    }

    tokens
}

/// Port of the `strtok(pattern_copy, " ")` term-collection loop shared by `path_search_find`'s
/// `SPACE_AND:` branch and `path_search_projected_find_cancellable`'s `is_space_and` branch.
fn split_terms(bytes: &[u8], max_terms: usize) -> Vec<Vec<u8>> {
    bytes
        .split(|&b| b == b' ')
        .filter(|term| !term.is_empty())
        .take(max_terms)
        .map(<[u8]>::to_vec)
        .collect()
}

/// ASCII-only case fold of a single byte, matching the C-locale behavior of `tolower`/`REG_ICASE`
/// pinned by this port (see the module doc's decision table).
#[inline]
#[must_use]
fn fold(b: u8) -> u8 {
    to_lower_ascii(b)
}

/// Port of `strcasestr`: ASCII-case-insensitive substring search. An empty `needle` matches
/// unconditionally, matching glibc/BSD `strcasestr("...", "")` returning the haystack pointer.
#[must_use]
pub fn ascii_case_insensitive_contains(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() {
        return true;
    }
    if needle.len() > haystack.len() {
        return false;
    }
    haystack
        .windows(needle.len())
        .any(|window| window.iter().zip(needle).all(|(&h, &n)| fold(h) == fold(n)))
}

/// Reusable DP scratch buffers for [`matches_with_scratch`], hoisting the two per-call
/// `Vec<bool>` allocations [`matches`] would otherwise make on every invocation -- the phase-1
/// perf note ("hoist glob scratch buffers before wiring live"). Callers that invoke matching in a
/// tight loop over many subjects against the same token sequence (e.g. `engine::projected_find`'s
/// per-candidate scan) should construct one `MatchScratch` before the loop and reuse it via
/// [`matches_with_scratch`] instead of calling [`matches`] per candidate.
#[derive(Debug, Default)]
pub struct MatchScratch {
    prev: Vec<bool>,
    current: Vec<bool>,
}

impl MatchScratch {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

/// Matches `subject` against a compiled [`Token`] sequence, requiring the **entire** subject to
/// be consumed (this is what makes a leading [`Token::StarAny`] behave like a free-start regex
/// and its absence behave like a `^`-anchored one, and what makes the always-present-in-wildcard-
/// mode implicit `$` unnecessary as a token).
///
/// Implemented as the standard O(n·m) two-row dynamic-programming wildcard-matching algorithm
/// (`dp[i][k]` = does `subject[..i]` match `tokens[..k]`), generalized for two star flavors
/// (`[^/]*` and `.*`) instead of one. This recognizes the same regular language as the C-built
/// POSIX ERE for these constructs without invoking any regex engine — see the parity argument in
/// the `pathsearch` module doc.
///
/// Reuses `scratch`'s two `Vec<bool>` rows instead of allocating fresh ones each call -- both
/// rows are unconditionally cleared and resized to `tokens.len() + 1` at the top of every call, so
/// no state from a previous (possibly longer- or shorter-token) call can leak into this one.
#[must_use]
pub fn matches_with_scratch(subject: &[u8], tokens: &[Token], scratch: &mut MatchScratch) -> bool {
    let m = tokens.len();

    // Row 0: subject prefix of length 0. Only star tokens can match zero bytes. `clear()` +
    // `resize()` always yields an all-`false` row regardless of the buffer's prior contents/
    // length, so this is behaviorally identical to a fresh `vec![false; m + 1]`.
    scratch.prev.clear();
    scratch.prev.resize(m + 1, false);
    scratch.prev[0] = true;
    for (k, token) in tokens.iter().enumerate() {
        if matches!(token, Token::StarAny | Token::StarNonSlash) {
            scratch.prev[k + 1] = scratch.prev[k];
        }
    }

    scratch.current.clear();
    scratch.current.resize(m + 1, false);
    for &subject_byte in subject {
        scratch.current[0] = false;
        for (k, token) in tokens.iter().enumerate() {
            scratch.current[k + 1] = match *token {
                Token::Lit(c) => scratch.prev[k] && fold(subject_byte) == fold(c),
                Token::AnyNonSlash => scratch.prev[k] && subject_byte != b'/',
                Token::StarNonSlash => {
                    scratch.current[k] || (scratch.prev[k + 1] && subject_byte != b'/')
                }
                Token::StarAny => scratch.current[k] || scratch.prev[k + 1],
            };
        }
        std::mem::swap(&mut scratch.prev, &mut scratch.current);
    }

    scratch.prev[m]
}

/// Convenience wrapper over [`matches_with_scratch`] that allocates a throwaway [`MatchScratch`]
/// for a single call. Prefer [`matches_with_scratch`] with a hoisted, reused `MatchScratch` in any
/// loop that matches many subjects against the same token sequence.
#[must_use]
pub fn matches(subject: &[u8], tokens: &[Token]) -> bool {
    let mut scratch = MatchScratch::new();
    matches_with_scratch(subject, tokens, &mut scratch)
}
