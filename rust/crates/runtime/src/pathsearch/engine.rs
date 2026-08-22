//! Port of `path_search_projected_find_cancellable` (and its non-cancellable wrapper
//! `path_search_projected_find`, which is just `projected_find` called with no cancellation
//! token), `path_search_cancellation_*`, and the bounded top-K max-heap it uses.
//!
//! # C-semantics decision table (projected search / cancellation / top-K ordering)
//!
//! | C behavior | Rust port decision |
//! |---|---|
//! | Matched subject is `display_prefix + relative_path + "\n" + absolute_prefix + relative_path`, built into a reusable `scratch` buffer per candidate | Ported identically in [`PathSearchIndex::projected_find`] via a reused `Vec<u8>` scratch buffer (`scratch.clear()` + four `extend_from_slice`/`push` calls per candidate) — same subject bytes, same embedded literal `\n`. `[^/]`/`[^/]*` tokens don't special-case `\n` (see `glob.rs`), so the embedded separator is transparent to matching, exactly as in C. |
//! | No prefix/suffix binary-search restriction is applied in this function — every candidate in `0..relative_index->count` is examined | Ported identically: [`PathSearchIndex::projected_find`] does a full linear scan, no bound-narrowing. (The bound optimization in `PathSearchIndex::find` genuinely doesn't apply here since there is no pre-sorted array of *projected* keys to binary-search.) |
//! | Cooperative cancellation: checked every 64 items (`(index & 63) == 0`), `atomic_bool` with acquire/release ordering | Ported as [`PathSearchCancellation`] (an `AtomicBool` with `Ordering::Release`/`Ordering::Acquire`), checked at the same `index % 64 == 0` cadence. |
//! | On cancellation, already-collected heap contents are discarded (`heap_count = 0`) and `stats.cancelled = true`; `examined_count`/`matched_count` reflect work done *before* the cancellation was observed | Ported identically via [`ProjectedSearchOutcome::Cancelled`], which carries the [`PathSearchWorkStats`] but no matches. |
//! | Top-K selection: a max-heap of size `min(limit, relative_index->count)`, ordered by [`projected_compare`] (see below); once full, a new candidate replaces the root only if it compares *less than* the current root | Ported as a hand-rolled binary heap (`sift_up`/`sift_down` mirroring the C versions structurally) rather than `std::collections::BinaryHeap`. This is a deliberate choice, not a requirement: **top-K-smallest-then-sort-ascending is a pure function of the comparator's total order**, independent of which correctly-implemented heap algorithm computes it (see the parity argument in the `pathsearch` module doc) — but the hand-rolled version keeps the *diagnostic counters* (`heap_peak_count`, `heap_comparison_count`) structurally comparable to the C source for anyone diffing the two implementations later. |
//! | Ordering key `projected_index_compare`: byte-compares `relative_path + "\n" + absolute_prefix + relative_path` **(note: `display_prefix` is deliberately excluded from this comparator, unlike the *matched* subject above)**; ties broken by comparing the raw ordinal `index`/`heap[...]` values (ascending) | Ported byte-for-byte as [`projected_compare`] / [`projected_key_byte`], which stream the same four conceptual segments (`relative_path`, `"\n"`, `absolute_prefix`, `relative_path`) without ever concatenating them, and fall back to comparing the two ordinal indices when both streams are simultaneously exhausted. Since `display_prefix` is a constant across every candidate in one call, omitting it from the comparator doesn't change relative order *within* a single `projected_find` call — it only matters if a caller later merges results from multiple `projected_find` calls with different `display_prefix`es and expects `display_prefix` to participate in a merged tie-break; that merge logic lives in Swift (`candidatePrecedes`, which *does* fold `display_prefix` into its `tie_break_key`) and is out of scope for this engine port. |
//! | Extraction: repeatedly pop the heap root into the *end* of the result array, walking backward, so final output is ascending by [`projected_compare`] | Ported identically in the extraction loop at the end of [`PathSearchIndex::projected_find`]. |
//! | `stats.scratch_bytes = display_length + absolute_length + maximum_path_length*2 + 2`, with a `SIZE_MAX`-overflow guard before allocating | Ported as the same formula using `checked_add`/`checked_mul`; on overflow (unreachable in practice — would require path lengths approaching `usize::MAX`) `projected_find` returns an empty, non-cancelled result with all-zero stats, mirroring the C function's `NULL`-return-on-overflow failure mode as a safe-Rust equivalent (a `NULL` `search_result_t*` and an empty match list are observationally the same to callers). |
//! | `path_search_projected_find` (no cancellation) is defined as `path_search_projected_find_cancellable(..., NULL, NULL)` | Ported as [`PathSearchIndex::projected_find`] accepting `cancellation: Option<&PathSearchCancellation>`; passing `None` reproduces the no-cancellation entry point without a separate function. |
//! | Cancellation is a `projected_find`-only concept in C — `path_search_find` (`index.rs`) has no cancellation token, no per-64-item check, and no `path_search_work_stats_t` output at all | Not ported onto [`PathSearchIndex::find`]: this is a deliberate parity decision, not a dropped deliverable — `find`'s candidate-narrowing binary search plus bounded regex scan is the fast path the C source never made cancellable, so this port doesn't invent cancellation for it either. |

use std::cmp::Ordering;
use std::sync::atomic::{AtomicBool, Ordering as AtomicOrdering};

use super::glob::{self, Mode};
use super::index::{PathSearchIndex, ProjectedPathSearchMatch};

/// Port of `path_search_cancellation_t` / `path_search_cancellation_create` /
/// `path_search_cancellation_cancel`.
#[derive(Debug, Default)]
pub struct PathSearchCancellation(AtomicBool);

impl PathSearchCancellation {
    #[must_use]
    pub fn new() -> Self {
        Self(AtomicBool::new(false))
    }

    pub fn cancel(&self) {
        self.0.store(true, AtomicOrdering::Release);
    }

    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.0.load(AtomicOrdering::Acquire)
    }
}

/// Port of `path_search_work_stats_t`.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct PathSearchWorkStats {
    pub examined_count: usize,
    pub matched_count: usize,
    pub heap_peak_count: usize,
    pub heap_comparison_count: usize,
    pub scratch_bytes: usize,
    pub cancelled: bool,
}

/// Outcome of [`PathSearchIndex::projected_find`], distinguishing a completed search from one
/// cooperatively cancelled mid-scan (mirroring the Swift wrapper's
/// `ProjectedSearchOutcome`/`stats.cancelled` split rather than the C function's single
/// always-non-null-but-possibly-empty return).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProjectedSearchOutcome {
    Completed(Vec<ProjectedPathSearchMatch>, PathSearchWorkStats),
    Cancelled(PathSearchWorkStats),
}

impl PathSearchIndex {
    /// Port of `path_search_projected_find_cancellable` (and, when `cancellation` is `None`,
    /// `path_search_projected_find`).
    #[must_use]
    pub fn projected_find(
        &self,
        pattern: &str,
        display_prefix: &str,
        absolute_prefix: &str,
        limit: usize,
        cancellation: Option<&PathSearchCancellation>,
    ) -> ProjectedSearchOutcome {
        let parts = glob::decompose(pattern);
        let display_bytes = display_prefix.as_bytes();
        let absolute_bytes = absolute_prefix.as_bytes();

        let mut stats = PathSearchWorkStats::default();

        let Some(scratch_bytes) = display_bytes
            .len()
            .checked_add(absolute_bytes.len())
            .and_then(|v| self.maximum_path_length().checked_mul(2).map(|m| (v, m)))
            .and_then(|(v, m)| v.checked_add(m))
            .and_then(|v| v.checked_add(2))
        else {
            return ProjectedSearchOutcome::Completed(Vec::new(), stats);
        };
        stats.scratch_bytes = scratch_bytes;

        let capacity = limit.min(self.len());
        let mut heap: Vec<usize> = Vec::with_capacity(capacity);
        let mut scratch = Vec::with_capacity(scratch_bytes);

        for index in 0..self.len() {
            if index % 64 == 0 {
                if let Some(token) = cancellation {
                    if token.is_cancelled() {
                        stats.cancelled = true;
                        break;
                    }
                }
            }

            let relative_path = self.original_paths()[index].as_bytes();
            stats.examined_count += 1;

            scratch.clear();
            scratch.extend_from_slice(display_bytes);
            scratch.extend_from_slice(relative_path);
            scratch.push(b'\n');
            scratch.extend_from_slice(absolute_bytes);
            scratch.extend_from_slice(relative_path);

            let matched = match &parts.mode {
                Mode::SpaceAnd(terms) => terms
                    .iter()
                    .all(|term| glob::ascii_case_insensitive_contains(&scratch, term)),
                Mode::Glob(tokens) => glob::matches(&scratch, tokens),
            };

            if matched {
                stats.matched_count += 1;
                if heap.len() < capacity {
                    heap.push(index);
                    let last = heap.len() - 1;
                    sift_up(&mut heap, last, self, absolute_bytes, &mut stats);
                    stats.heap_peak_count = stats.heap_peak_count.max(heap.len());
                } else if capacity > 0
                    && projected_compare(self, absolute_bytes, index, heap[0], &mut stats)
                        == Ordering::Less
                {
                    heap[0] = index;
                    sift_down(&mut heap, self, absolute_bytes, &mut stats);
                }
            }
        }

        if cancellation.is_some_and(PathSearchCancellation::is_cancelled) {
            stats.cancelled = true;
            heap.clear();
        }

        if stats.cancelled {
            return ProjectedSearchOutcome::Cancelled(stats);
        }

        let total = heap.len();
        let mut result = vec![0usize; total];
        let mut heap_len = total;
        for output in (1..=total).rev() {
            result[output - 1] = heap[0];
            heap_len -= 1;
            if heap_len > 0 {
                heap[0] = heap[heap_len];
                heap.truncate(heap_len);
                sift_down(&mut heap, self, absolute_bytes, &mut stats);
            } else {
                heap.truncate(0);
            }
        }

        let matches = result
            .into_iter()
            .map(|index| ProjectedPathSearchMatch { index, score: 1 })
            .collect();
        ProjectedSearchOutcome::Completed(matches, stats)
    }
}

/// Streams byte `pos` of the conceptual key `relative_path + "\n" + absolute_prefix +
/// relative_path` without ever concatenating it, mirroring `projected_key_cursor_t` /
/// `projected_key_next`.
fn projected_key_byte(relative_path: &[u8], absolute_prefix: &[u8], pos: usize) -> Option<u8> {
    let mut remaining = pos;
    if remaining < relative_path.len() {
        return Some(relative_path[remaining]);
    }
    remaining -= relative_path.len();
    if remaining == 0 {
        return Some(b'\n');
    }
    remaining -= 1;
    if remaining < absolute_prefix.len() {
        return Some(absolute_prefix[remaining]);
    }
    remaining -= absolute_prefix.len();
    if remaining < relative_path.len() {
        return Some(relative_path[remaining]);
    }
    None
}

/// Port of `projected_index_compare`. `lhs`/`rhs` are ordinal positions into `index`'s original
/// paths (the same values stored in the heap).
fn projected_compare(
    index: &PathSearchIndex,
    absolute_prefix: &[u8],
    lhs: usize,
    rhs: usize,
    stats: &mut PathSearchWorkStats,
) -> Ordering {
    stats.heap_comparison_count += 1;
    let lhs_path = index.original_paths()[lhs].as_bytes();
    let rhs_path = index.original_paths()[rhs].as_bytes();
    let mut pos = 0usize;
    loop {
        let a = projected_key_byte(lhs_path, absolute_prefix, pos);
        let b = projected_key_byte(rhs_path, absolute_prefix, pos);
        match (a, b) {
            (None, None) => return lhs.cmp(&rhs),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(byte_a), Some(byte_b)) => match byte_a.cmp(&byte_b) {
                Ordering::Equal => {
                    pos += 1;
                    continue;
                }
                other => return other,
            },
        }
    }
}

/// Port of `projected_heap_sift_up`.
fn sift_up(
    heap: &mut [usize],
    mut position: usize,
    index: &PathSearchIndex,
    absolute_prefix: &[u8],
    stats: &mut PathSearchWorkStats,
) {
    while position > 0 {
        let parent = (position - 1) / 2;
        if projected_compare(index, absolute_prefix, heap[parent], heap[position], stats)
            != Ordering::Less
        {
            break;
        }
        heap.swap(parent, position);
        position = parent;
    }
}

/// Port of `projected_heap_sift_down`. Operates on the whole slice (`heap.len()` is the heap
/// size), mirroring the C function's explicit `count` parameter.
fn sift_down(
    heap: &mut [usize],
    index: &PathSearchIndex,
    absolute_prefix: &[u8],
    stats: &mut PathSearchWorkStats,
) {
    let count = heap.len();
    let mut position = 0usize;
    loop {
        let left = position * 2 + 1;
        if left >= count {
            break;
        }
        let right = left + 1;
        let mut worst = left;
        if right < count
            && projected_compare(index, absolute_prefix, heap[left], heap[right], stats)
                == Ordering::Less
        {
            worst = right;
        }
        if projected_compare(index, absolute_prefix, heap[position], heap[worst], stats)
            != Ordering::Less
        {
            break;
        }
        heap.swap(position, worst);
        position = worst;
    }
}
