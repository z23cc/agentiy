//! Port of `WorkspacePathSearchOverlayHistory<Payload>`
//! (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift:320-432`).
//!
//! Persistent newest-first overlay history shared by the materialized and projected path index
//! shapes (`materialized.rs` / `projected.rs`). Recent payloads are copied only within a fixed
//! bound (16); once that bound is exceeded, a full batch of 17 moves into an immutable
//! `Arc`-linked page, and pages share older tails across retained generations without nesting
//! payload histories -- this is what lets a long chain of small overlay patches stay cheap to
//! retain across the live-generation cap (§4 layer 2) instead of re-copying on every publish.

use std::sync::Arc;

const MAXIMUM_RECENT_PAYLOAD_COUNT: usize = 16;
const COMPACTED_PAGE_PAYLOAD_COUNT: usize = MAXIMUM_RECENT_PAYLOAD_COUNT + 1;

/// One node of the compacted overlay-history chain.
///
/// Ordinary `Arc` drop is recursive: dropping the head of a long chain whose tail is uniquely
/// owned would walk the whole chain on the stack. The Swift source solves the equivalent problem
/// in `Page.deinit` with `isKnownUniquelyReferenced`; `Arc::get_mut` is the exact Rust analogue
/// (it returns `Some` iff this is the only strong reference and there are no weak references --
/// true here, since nothing in this history ever takes a `Weak<Page<_>>`), so the same iterative
/// unlink ports directly. See the `Drop` impl below.
struct Page<Payload> {
    payloads_newest_first: Vec<Payload>,
    /// Mutated only by `Drop`, which is handed `&mut self` directly by the language -- unlike the
    /// Swift class, whose `deinit` only owns `self` and must reach into a *sibling* page's field,
    /// hence `isKnownUniquelyReferenced` there. Read-only everywhere else.
    previous: Option<Arc<Page<Payload>>>,
}

impl<Payload> Page<Payload> {
    fn new(payloads_newest_first: Vec<Payload>, previous: Option<Arc<Page<Payload>>>) -> Self {
        debug_assert_eq!(
            payloads_newest_first.len(),
            COMPACTED_PAGE_PAYLOAD_COUNT,
            "every compacted page holds exactly {COMPACTED_PAGE_PAYLOAD_COUNT} payloads (Swift \
             precondition at PathSearchIndex.swift:356)"
        );
        Self {
            payloads_newest_first,
            previous,
        }
    }
}

impl<Payload> Drop for Page<Payload> {
    fn drop(&mut self) {
        // Retain the tail before severing this page's link (mirrors the Swift deinit's `var tail
        // = previous; previous = nil`). Iteratively dismantle only a unique prefix; a retained
        // generation or an active traversal may still own any shared tail, at which point we stop
        // and let ordinary (now bounded, since the prefix above it is already gone) `Arc` drop
        // handle the rest whenever its other owner releases it.
        let mut tail = self.previous.take();
        while let Some(mut page) = tail {
            let Some(inner) = Arc::get_mut(&mut page) else {
                break;
            };
            tail = inner.previous.take();
            // `page` (a uniquely-owned `Arc`) drops here. Its own `Drop::drop` runs, but its
            // `previous` is already `None`, so that call is a no-op -- no recursion.
        }
    }
}

/// Persistent newest-first payload history. See the module doc comment.
pub struct OverlayHistory<Payload> {
    /// Cheap-to-clone-when-unchanged: wrapped in `Arc` so the common "nothing changed, share
    /// everything" case (`BuildKind::Reused`) is a pointer clone rather than a `Vec` copy.
    recent_payloads_newest_first: Arc<Vec<Payload>>,
    compacted_page_head: Option<Arc<Page<Payload>>>,
}

// Hand-written rather than `#[derive(Clone)]`: the derive macro adds a spurious `Payload: Clone`
// bound to the impl even though every field is already cheaply `Arc`-clonable regardless of
// `Payload`'s own bounds.
impl<Payload> Clone for OverlayHistory<Payload> {
    fn clone(&self) -> Self {
        Self {
            recent_payloads_newest_first: Arc::clone(&self.recent_payloads_newest_first),
            compacted_page_head: self.compacted_page_head.clone(),
        }
    }
}

// Hand-written for the same reason as `Clone` above: `#[derive(Debug)]` would add a spurious
// `Payload: Debug` bound to the whole impl. Both payload types used in this crate (`materialized`
// / `projected`) do derive `Debug`, so this could have been a plain derive without a *practical*
// problem today, but hand-writing it keeps the type's own bound-free contract consistent with
// `Clone`'s and avoids depending on that coincidence.
impl<Payload> std::fmt::Debug for OverlayHistory<Payload> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("OverlayHistory")
            .field(
                "recent_payload_count",
                &self.recent_payloads_newest_first.len(),
            )
            .field("has_compacted_pages", &self.compacted_page_head.is_some())
            .finish()
    }
}

impl<Payload> Default for OverlayHistory<Payload> {
    fn default() -> Self {
        Self::new()
    }
}

impl<Payload> OverlayHistory<Payload> {
    #[must_use]
    pub fn new() -> Self {
        Self {
            recent_payloads_newest_first: Arc::new(Vec::new()),
            compacted_page_head: None,
        }
    }

    /// Port of `WorkspacePathSearchOverlayHistory.appending(_:)`.
    #[must_use]
    pub fn appending(&self, payload: Payload) -> Self
    where
        Payload: Clone,
    {
        if self.recent_payloads_newest_first.len() < MAXIMUM_RECENT_PAYLOAD_COUNT {
            let mut recent = Vec::with_capacity(self.recent_payloads_newest_first.len() + 1);
            recent.push(payload);
            recent.extend(self.recent_payloads_newest_first.iter().cloned());
            return Self {
                recent_payloads_newest_first: Arc::new(recent),
                compacted_page_head: self.compacted_page_head.clone(),
            };
        }

        let mut page_payloads = Vec::with_capacity(COMPACTED_PAGE_PAYLOAD_COUNT);
        page_payloads.push(payload);
        page_payloads.extend(self.recent_payloads_newest_first.iter().cloned());
        Self {
            recent_payloads_newest_first: Arc::new(Vec::new()),
            compacted_page_head: Some(Arc::new(Page::new(
                page_payloads,
                self.compacted_page_head.clone(),
            ))),
        }
    }

    /// Port of `WorkspacePathSearchOverlayHistory.visitNewestFirst(_:)`.
    pub fn visit_newest_first(&self, mut body: impl FnMut(&Payload)) {
        for payload in self.recent_payloads_newest_first.iter() {
            body(payload);
        }
        let mut page = self.compacted_page_head.clone();
        while let Some(current) = page {
            for payload in &current.payloads_newest_first {
                body(payload);
            }
            // NOT `page.clone_from(&current.previous)` (clippy's `assigning_clones` suggestion):
            // `current` was moved out of `page` by this `while let`, so `page` has no valid prior
            // value for `clone_from` to reuse -- a plain re-assignment is required here.
            page = current.previous.clone();
        }
    }

    /// Port of `WorkspacePathSearchOverlayHistory.metricsForTesting`.
    #[must_use]
    pub fn metrics_for_testing(&self) -> OverlayHistoryMetrics {
        let mut compacted_page_count = 0usize;
        let mut compacted_payload_count = 0usize;
        let mut maximum_compacted_page_payload_count = 0usize;
        let mut page = self.compacted_page_head.clone();
        while let Some(current) = page {
            compacted_page_count += 1;
            compacted_payload_count += current.payloads_newest_first.len();
            maximum_compacted_page_payload_count =
                maximum_compacted_page_payload_count.max(current.payloads_newest_first.len());
            page = current.previous.clone(); // see the `visit_newest_first` comment above
        }
        OverlayHistoryMetrics {
            recent_payload_count: self.recent_payloads_newest_first.len(),
            compacted_page_count,
            compacted_payload_count,
            maximum_compacted_page_payload_count,
        }
    }
}

/// Port of `WorkspacePathSearchOverlayHistoryMetrics`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OverlayHistoryMetrics {
    pub recent_payload_count: usize,
    pub compacted_page_count: usize,
    pub compacted_payload_count: usize,
    pub maximum_compacted_page_payload_count: usize,
}

impl OverlayHistoryMetrics {
    #[must_use]
    pub const fn total_payload_count(&self) -> usize {
        self.recent_payload_count + self.compacted_payload_count
    }

    #[must_use]
    pub fn is_within_structural_bounds(&self) -> bool {
        self.recent_payload_count <= MAXIMUM_RECENT_PAYLOAD_COUNT
            && self.maximum_compacted_page_payload_count <= COMPACTED_PAGE_PAYLOAD_COUNT
            && self.compacted_payload_count
                == self.compacted_page_count * COMPACTED_PAGE_PAYLOAD_COUNT
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Debug, Eq, PartialEq)]
    struct P(u32);

    #[test]
    fn empty_history_visits_nothing_and_reports_zero_metrics() {
        let history: OverlayHistory<P> = OverlayHistory::new();
        let mut visited = Vec::new();
        history.visit_newest_first(|p| visited.push(p.clone()));
        assert!(visited.is_empty());
        let metrics = history.metrics_for_testing();
        assert_eq!(metrics.recent_payload_count, 0);
        assert_eq!(metrics.compacted_page_count, 0);
        assert_eq!(metrics.total_payload_count(), 0);
        assert!(metrics.is_within_structural_bounds());
    }

    #[test]
    fn appending_stays_in_recent_until_the_bound_then_compacts_newest_first() {
        let mut history: OverlayHistory<P> = OverlayHistory::new();
        for i in 0..16 {
            history = history.appending(P(i));
        }
        let metrics = history.metrics_for_testing();
        assert_eq!(metrics.recent_payload_count, 16);
        assert_eq!(metrics.compacted_page_count, 0);
        assert!(metrics.is_within_structural_bounds());

        // The 17th append compacts all 16 recent + the new one into one page; recent resets.
        history = history.appending(P(16));
        let metrics = history.metrics_for_testing();
        assert_eq!(metrics.recent_payload_count, 0);
        assert_eq!(metrics.compacted_page_count, 1);
        assert_eq!(metrics.compacted_payload_count, 17);
        assert_eq!(metrics.maximum_compacted_page_payload_count, 17);
        assert!(metrics.is_within_structural_bounds());

        let mut visited = Vec::new();
        history.visit_newest_first(|p| visited.push(p.0));
        assert_eq!(visited, (0..=16).rev().collect::<Vec<_>>());
    }

    #[test]
    fn cloning_shares_state_and_appending_does_not_mutate_the_original() {
        let mut history: OverlayHistory<P> = OverlayHistory::new();
        for i in 0..20 {
            history = history.appending(P(i));
        }
        let snapshot = history.clone();
        history = history.appending(P(20));

        let mut snapshot_visited = Vec::new();
        snapshot.visit_newest_first(|p| snapshot_visited.push(p.0));
        assert_eq!(snapshot_visited, (0..20).rev().collect::<Vec<_>>());

        let mut history_visited = Vec::new();
        history.visit_newest_first(|p| history_visited.push(p.0));
        assert_eq!(history_visited, (0..=20).rev().collect::<Vec<_>>());
    }

    #[test]
    fn long_chain_drops_without_stack_overflow() {
        // Regression guard for the iterative-unlink `Drop` impl: a naive recursive `Arc` drop
        // over a chain this long would risk stack overflow in a debug build.
        let mut history: OverlayHistory<P> = OverlayHistory::new();
        for i in 0..(17 * 5000) {
            history = history.appending(P(i));
        }
        drop(history);
    }
}
