//! Port of `path_search_index_t`, `path_search_create`, `path_search_lower_bound`/
//! `path_search_upper_bound`, and the non-projected `path_search_find`.
//!
//! # C-semantics decision table (index construction / binary-search bounds)
//!
//! | C behavior | Rust port decision |
//! |---|---|
//! | `forward_paths` = paths sorted by `path_compare` (`strcmp`, ties broken by ascending original index) | [`PathSearchIndex::forward_order`]: `Vec<usize>` of original indices sorted by `(path bytes, original index)` ascending. We never materialize a sorted copy of the strings themselves (unlike the C struct's `char** forward_paths`) since only the *order* is observable behavior; this is a representational simplification, not a behavioral difference. |
//! | `reversed_paths` = `path_reverse(path)` for each path, then sorted the same way | [`PathSearchIndex::reversed_order`]: sorted by comparing the **byte-reversed** string, without ever materializing a reversed copy — see [`compare_reversed`], which walks both operands from their last byte backward. This matters for correctness, not just efficiency: `path_reverse` is a **raw byte reversal**, not Unicode-aware, so a materialized `String` reversal would be invalid UTF-8 for any non-ASCII path (e.g. multi-byte UTF-8 sequences get their byte order scrambled). Operating on byte slices throughout avoids ever needing to construct an invalid `String`. |
//! | `strcmp` (full-string compare, used by `path_compare`/`qsort`) — NUL-terminated, so identical-length equal strings tie at the terminating NUL, unequal-length strings differ at the shorter one's NUL (`0`, always less than any other byte) | Ported via plain `[u8]::cmp` (which *is* strcmp-equivalent lexicographic byte comparison for the "no embedded NUL" case that real filesystem paths satisfy) for the forward order, and via [`compare_reversed`] (which explicitly treats "ran out of bytes" as byte `0`) for the reversed order. |
//! | `strncmp(array[mid], key, key_len)` in `path_search_lower_bound`/`path_search_upper_bound` — compares at most `key_len` bytes, treating a shorter `array[mid]` as NUL-padded | [`strncmp_prefix`] (forward/prefix bound) and [`strncmp_suffix`] (reversed/suffix bound) both explicitly substitute byte `0` for out-of-range positions, matching `strncmp`'s NUL-padding exactly. |
//! | `qsort` is not guaranteed stable, so `path_compare` breaks ties on `original_index` explicitly to make the sort deterministic | Rust's `sort_by`/`sort_unstable_by` both accept an explicit `(bytes, original_index)` comparator here too, so the result is deterministic regardless of which sort Rust picks. |
//! | `maximum_path_length` = max byte length across paths, used later to size the projected-search scratch buffer | Ported as [`PathSearchIndex::maximum_path_length`] (in UTF-8 bytes, matching `strlen`). |
//! | `path_search_create` returns `NULL` for `count == 0` (Swift special-cases this and never calls into C for an empty index) | Not ported as a nullable/optional type: [`PathSearchIndex::new`] accepts an empty slice and produces a valid, empty index whose `find`/`projected_find` simply return no matches — behaviorally identical to the Swift wrapper's early-return, without needing a null-pointer analogue in safe Rust. |
//! | `path_search_find`: candidates are the *prefix-bound* range of `forward_paths` (already lexically sorted), optionally intersected with the *suffix-bound* range of `reversed_paths` via an `O(count)` boolean membership array | Ported in [`PathSearchIndex::find`] exactly this way: prefix range from `forward_order`, optional suffix intersection using the same `O(count)` boolean-array technique (`suffix_membership`), preserving forward (i.e. ascending path-lexical) order among candidates — this is what makes results already come out in ascending `tie_break_key` order (score is always `1`, so no separate ranking step is needed; see `engine.rs` for `path_search_projected_find_cancellable`'s ordering, which differs). |
//! | **The prefix/suffix bound narrowing is case-*sensitive* (`strncmp` on the literal, unmodified pattern bytes) even though the subsequent regex/AND match is case-*insensitive*** | Ported as-is: [`strncmp_prefix`]/[`strncmp_suffix`] never fold case. This is a genuine, load-bearing C behavior, not an incidental detail — a wildcard pattern like `"Foo*"` only matches paths whose *literal prefix* is byte-exactly `"Foo"`, even though `[^/]*` (and `REG_ICASE` generally) would otherwise happily match `"foobar"` too; the case-insensitive matcher only ever sees candidates that already survived the case-sensitive bound. See `foo_star_prefix_bound_is_case_sensitive_even_though_match_is_case_insensitive` and `swift_suffix_bound_is_case_sensitive_even_though_match_is_case_insensitive` in `tests.rs`. This matters for phase 2: a future "obvious cleanup" that case-folds the bound search would silently change production search results, and the planned Swift-side differential must expect this asymmetry rather than flag it as a mismatch. |
//! | `result->capacity = min(limit, candidate_count)`; matches are collected in candidate order until `result->count == limit` | Ported as a plain early-`break` once `limit` matches have been collected; `limit == 0` yields no matches without needing a zero-capacity allocation. |
//! | `search_result_t.tie_break_keys[i]` borrows the matched path string directly | [`PathSearchMatch::tie_break_key`] is an owned `String` clone of the matched path (safe Rust has no borrow-from-index-of-matching-lifetime shortcut worth taking here without also threading the index's lifetime through the return type — a straightforward, small-vector-of-short-strings clone, not a hot-path concern at this phase). |

use std::cmp::Ordering;

use super::glob::{self, Mode};

/// One match from [`PathSearchIndex::find`], mirroring the (`indices`, `scores`, `tie_break_keys`)
/// triple in `search_result_t` for the non-projected search path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PathSearchMatch {
    /// Original (insertion) index into the paths passed to [`PathSearchIndex::new`].
    pub index: usize,
    /// Always `1` — the C engine's matcher is purely boolean (see `search_result_t` doc in
    /// `path_search.h`).
    pub score: i32,
    /// Equal to the matched path itself in this (non-projected) mode.
    pub tie_break_key: String,
}

/// One match from [`super::engine`]'s `projected_find`, mirroring the (`indices`, `scores`) pair
/// `path_search_projected_find_cancellable` returns (that function omits `tie_break_keys`; per
/// the header comment, the caller reconstructs them — out of scope for the engine port).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProjectedPathSearchMatch {
    /// Ordinal position (0-based) into the *relative* index's paths.
    pub index: usize,
    /// Always `1`, for the same reason as [`PathSearchMatch::score`].
    pub score: i32,
}

/// Immutable path search index: a behavioral port of `path_search_index_t` /
/// `path_search_create`.
#[derive(Clone, Debug)]
pub struct PathSearchIndex {
    original_paths: Vec<String>,
    /// Original indices, sorted ascending by `(path bytes, original index)` — mirrors
    /// `forward_paths`/`forward_indices` after `path_search_create`'s sort.
    forward_order: Vec<usize>,
    /// Original indices, sorted ascending by `(byte-reversed path, original index)` — mirrors
    /// `reversed_paths`/`reversed_indices` after `path_search_create`'s sort.
    reversed_order: Vec<usize>,
    /// Largest path length in UTF-8 bytes (`strlen` equivalent), mirroring
    /// `path_search_index_t.maximum_path_length`.
    maximum_path_length: usize,
}

impl PathSearchIndex {
    /// Builds an index from `paths`. Unlike `path_search_create`, this never fails / returns an
    /// optional: an empty `paths` slice produces a valid, empty index (see the module doc's
    /// decision table).
    #[must_use]
    pub fn new(paths: &[String]) -> Self {
        let original_paths: Vec<String> = paths.to_vec();
        let count = original_paths.len();
        let maximum_path_length = original_paths.iter().map(|p| p.len()).max().unwrap_or(0);

        let mut forward_order: Vec<usize> = (0..count).collect();
        forward_order.sort_by(|&a, &b| {
            original_paths[a]
                .as_bytes()
                .cmp(original_paths[b].as_bytes())
                .then(a.cmp(&b))
        });

        let mut reversed_order: Vec<usize> = (0..count).collect();
        reversed_order.sort_by(|&a, &b| {
            compare_reversed(original_paths[a].as_bytes(), original_paths[b].as_bytes())
                .then(a.cmp(&b))
        });

        Self {
            original_paths,
            forward_order,
            reversed_order,
            maximum_path_length,
        }
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.original_paths.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.original_paths.is_empty()
    }

    #[must_use]
    pub fn path(&self, original_index: usize) -> Option<&str> {
        self.original_paths.get(original_index).map(String::as_str)
    }

    pub(super) fn original_paths(&self) -> &[String] {
        &self.original_paths
    }

    pub(super) fn maximum_path_length(&self) -> usize {
        self.maximum_path_length
    }

    /// Port of `path_search_find`.
    #[must_use]
    pub fn find(&self, pattern: &str, limit: usize) -> Vec<PathSearchMatch> {
        let parts = glob::decompose(pattern);

        let prefix_start = self.lower_bound_forward(&parts.prefix);
        let prefix_end = self.upper_bound_forward(&parts.prefix);

        let candidates: Vec<usize> = if parts.suffix.is_empty() {
            self.forward_order[prefix_start..prefix_end].to_vec()
        } else {
            let suffix_start = self.lower_bound_reversed(&parts.suffix);
            let suffix_end = self.upper_bound_reversed(&parts.suffix);
            let mut suffix_membership = vec![false; self.len()];
            for &original_index in &self.reversed_order[suffix_start..suffix_end] {
                suffix_membership[original_index] = true;
            }
            self.forward_order[prefix_start..prefix_end]
                .iter()
                .copied()
                .filter(|&original_index| suffix_membership[original_index])
                .collect()
        };

        let mut result = Vec::with_capacity(limit.min(candidates.len()));
        for original_index in candidates {
            if result.len() >= limit {
                break;
            }
            let path = &self.original_paths[original_index];
            let matched = match &parts.mode {
                Mode::SpaceAnd(terms) => terms
                    .iter()
                    .all(|term| glob::ascii_case_insensitive_contains(path.as_bytes(), term)),
                Mode::Glob(tokens) => glob::matches(path.as_bytes(), tokens),
            };
            if matched {
                result.push(PathSearchMatch {
                    index: original_index,
                    score: 1,
                    tie_break_key: path.clone(),
                });
            }
        }
        result
    }

    /// Port of `path_search_lower_bound(forward_paths, count, prefix)`.
    fn lower_bound_forward(&self, prefix: &[u8]) -> usize {
        lower_bound(self.len(), |mid| {
            strncmp_prefix(
                self.original_paths[self.forward_order[mid]].as_bytes(),
                prefix,
            )
        })
    }

    /// Port of `path_search_upper_bound(forward_paths, count, prefix)`.
    fn upper_bound_forward(&self, prefix: &[u8]) -> usize {
        upper_bound(self.len(), |mid| {
            strncmp_prefix(
                self.original_paths[self.forward_order[mid]].as_bytes(),
                prefix,
            )
        })
    }

    /// Port of `path_search_lower_bound(reversed_paths, count, reversed_suffix)`, expressed
    /// directly against the un-reversed `suffix` bytes (see [`strncmp_suffix`]).
    fn lower_bound_reversed(&self, suffix: &[u8]) -> usize {
        lower_bound(self.len(), |mid| {
            strncmp_suffix(
                self.original_paths[self.reversed_order[mid]].as_bytes(),
                suffix,
            )
        })
    }

    /// Port of `path_search_upper_bound(reversed_paths, count, reversed_suffix)`.
    fn upper_bound_reversed(&self, suffix: &[u8]) -> usize {
        upper_bound(self.len(), |mid| {
            strncmp_suffix(
                self.original_paths[self.reversed_order[mid]].as_bytes(),
                suffix,
            )
        })
    }
}

/// Generic port of `path_search_lower_bound`'s binary-search shape, parameterized over any
/// `strncmp`-like comparator `cmp(mid)` = "how does `order[mid]` compare against the search key".
fn lower_bound(count: usize, cmp: impl Fn(usize) -> Ordering) -> usize {
    let mut left = 0usize;
    let mut right = count;
    while left < right {
        let mid = left + (right - left) / 2;
        if cmp(mid) == Ordering::Less {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    left
}

/// Generic port of `path_search_upper_bound`'s binary-search shape.
fn upper_bound(count: usize, cmp: impl Fn(usize) -> Ordering) -> usize {
    let mut left = 0usize;
    let mut right = count;
    while left < right {
        let mid = left + (right - left) / 2;
        if cmp(mid) != Ordering::Greater {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    left
}

/// Port of `strncmp(s, key, key.len())`, comparing unsigned bytes and NUL-padding `s` if it is
/// shorter than `key`.
fn strncmp_prefix(s: &[u8], key: &[u8]) -> Ordering {
    for (i, &key_byte) in key.iter().enumerate() {
        let s_byte = s.get(i).copied().unwrap_or(0);
        match s_byte.cmp(&key_byte) {
            Ordering::Equal => continue,
            other => return other,
        }
    }
    Ordering::Equal
}

/// Port of `strncmp(reversed_paths[mid], reversed_suffix, strlen(reversed_suffix))`, expressed
/// directly in terms of the un-reversed `path`/`suffix` bytes: byte `i` of the reversed path is
/// `path[path.len() - 1 - i]`, and byte `i` of the reversed suffix is `suffix[suffix.len() - 1 -
/// i]`. NUL-pads `path` (from the "reversed" side, i.e. once its *front* bytes are exhausted) the
/// same way `strncmp_prefix` NUL-pads from the back.
fn strncmp_suffix(path: &[u8], suffix: &[u8]) -> Ordering {
    let n = suffix.len();
    for i in 0..n {
        let path_byte = if i < path.len() {
            path[path.len() - 1 - i]
        } else {
            0
        };
        let suffix_byte = suffix[n - 1 - i];
        match path_byte.cmp(&suffix_byte) {
            Ordering::Equal => continue,
            other => return other,
        }
    }
    Ordering::Equal
}

/// Compares `a` and `b` as if both were byte-reversed and then compared with `strcmp` — without
/// ever materializing a reversed copy of either. Walks both operands from their last byte
/// backward; running out of bytes is treated as the `strcmp` NUL terminator (always less than any
/// other byte), matching `path_compare`'s use of `strcmp` on the fully-reversed strings.
fn compare_reversed(a: &[u8], b: &[u8]) -> Ordering {
    let mut ia = a.len();
    let mut ib = b.len();
    loop {
        let next_a = if ia == 0 {
            None
        } else {
            ia -= 1;
            Some(a[ia])
        };
        let next_b = if ib == 0 {
            None
        } else {
            ib -= 1;
            Some(b[ib])
        };
        match (next_a, next_b) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(byte_a), Some(byte_b)) => match byte_a.cmp(&byte_b) {
                Ordering::Equal => continue,
                other => return other,
            },
        }
    }
}
