//! E-1c: the `staleWatermark` ingress gate, mirroring the three rules frozen in
//! `docs/architecture/rust-inventory-scope-v1.md` §5.1 and verified against the live
//! implementation during P4-2 (not just the contract doc's summary of it):
//!
//! 1. **Non-strict comparison** (`accepted >= lastApplied`) -- verified against
//!    `WorkspaceFileContextStore.swift:3459`
//!    (`guard watermark >= pending.lastAppliedWatcherWatermark else { ... }`).
//! 2. **`nil` bypasses the sequence check entirely, never coerced to zero** -- verified against
//!    the `if let watermark = publication.watcherAcceptedWatermark { ... }` optional-binding shape
//!    at `WorkspaceFileContextStore.swift:3459-3464`: when the field is `nil` the watermark
//!    comparison block does not execute at all, and `lastAppliedWatcherWatermark` is left
//!    unchanged. Edit-path/synthetic-mutation publications pass `watcherAcceptedWatermark: nil`
//!    (`WorkspaceFileContextStore.swift:6222`, `:6241`).
//! 3. **Pressure collapse preserves min(lowest)/max(high) monotonicity** -- verified against
//!    `FileSystemWatcherIngressMailbox.swift:198-225`'s `collapseQueuedPayloads`: the fold over
//!    `payloads` computes `lowestAcceptedWatermark = min(...)` and
//!    `acceptedHighWatermark = max(...)` unconditionally across every payload being collapsed
//!    (including the incoming one), then emits exactly one `.overflowRootRescan` sentinel payload
//!    carrying that range. This is a structural (not measured) guarantee in the existing Swift
//!    code -- the fold cannot un-collapse to a lower high-watermark by construction. This module's
//!    gate models the corresponding "collapsed publication must not be rejected" requirement on
//!    the *new* Rust-side seam.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RejectionReason {
    pub kind: RejectionKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RejectionKind {
    StaleWatermark { expected: u64, actual: u64 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApplyOutcome {
    Patched,
    RebuiltAuthoritative,
    Rejected(RejectionKind),
}

/// One synthetic ingress publication, shaped after `FileSystemDeltaPublication`'s fields that the
/// gate actually reads.
#[derive(Clone, Debug)]
pub struct Publication {
    pub label: &'static str,
    pub watcher_accepted_watermark: Option<u64>,
    pub requires_full_resync: bool,
}

pub struct IngressGateState {
    last_applied_watermark: Option<u64>,
}

impl IngressGateState {
    pub fn new() -> Self {
        IngressGateState { last_applied_watermark: None }
    }

    /// Admits (or rejects) one publication. `requiresFullResync` bypasses the watermark check
    /// entirely (a full resync is definitionally not stale -- it re-establishes the baseline),
    /// matching the seeded-replay guard's structure at `WorkspaceFileContextStore.swift:3446-3453`
    /// where a `requiresFullResync` publication is routed to a distinct fallback path rather than
    /// being run through the watermark comparison.
    pub fn admit(&mut self, publication: &Publication) -> ApplyOutcome {
        if publication.requires_full_resync {
            if let Some(w) = publication.watcher_accepted_watermark {
                self.last_applied_watermark = Some(self.last_applied_watermark.map_or(w, |last| last.max(w)));
            }
            return ApplyOutcome::RebuiltAuthoritative;
        }
        match publication.watcher_accepted_watermark {
            None => ApplyOutcome::Patched, // nil bypasses the sequence check entirely (rule 2)
            Some(w) => match self.last_applied_watermark {
                Some(last) if w < last => ApplyOutcome::Rejected(RejectionKind::StaleWatermark { expected: last, actual: w }),
                _ => {
                    self.last_applied_watermark = Some(w); // non-strict >= admits w == last too (rule 1)
                    ApplyOutcome::Patched
                }
            },
        }
    }
}

impl Default for IngressGateState {
    fn default() -> Self {
        Self::new()
    }
}
