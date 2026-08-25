//! Snapshot handle table: `SnapshotHandleId -> Arc<RootGeneration>` plus mass-invalidation and
//! DEBUG leak observability, per `docs/architecture/rust-inventory-scope-v1.md` §4.
//!
//! Layer mapping (§4's four layers -- layers 1/2 belong to the bridge/scope callers, this module
//! owns layers 3 and the bookkeeping half of layer 4):
//! - Layer 3 (mass invalidation): `invalidate_for_root_close` / `invalidate_all` cover
//!   `inventoryCloseRoot` (per-root) and scope/identity-change invalidation (whole table).
//! - Layer 4 (leak observability): `open_handle` records an origin tag and an open timestamp;
//!   `oldest_open_age` / `origin_histogram` surface what `InventoryDiagnosticsV1` needs.

use std::collections::HashMap;
use std::time::Instant;

use super::composition::ComposedCatalogArtifact;
use super::generation::RootGeneration;
use super::ids::{ComposedSnapshotHandleId, GenerationToken, RootId, SnapshotHandleId};
use std::sync::Arc;

/// Snapshot and composed handles share the public UniFFI `u64` carrier. Reserve the high bit for
/// composed handles so a raw ID passed to the wrong API can never alias an unrelated open handle
/// in the other table; the typed Rust IDs and Swift facades remain the compile-time boundary.
const COMPOSED_HANDLE_NAMESPACE_BIT: u64 = 1 << 63;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InvalidationReason {
    RootClosed,
    ScopeClosed,
    IdentityChanged,
}

/// A read on an invalidated (or never-issued) handle returns this typed business outcome, never
/// a panic or undefined behavior (§4 layer 3).
#[derive(Clone, Debug, PartialEq)]
pub enum HandleReadOutcome {
    Open { generation: Arc<RootGeneration> },
    HandleInvalidated { reason: InvalidationReason },
}

struct OpenHandle {
    root_id: RootId,
    generation: Arc<RootGeneration>,
    origin_tag: &'static str,
    opened_at: Instant,
}

#[derive(Default)]
pub struct HandleTable {
    minter: super::ids::CounterMinter,
    open: HashMap<SnapshotHandleId, OpenHandle>,
    invalidated: HashMap<SnapshotHandleId, InvalidationReason>,
    max_open_observed: usize,
}

impl HandleTable {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn open_handle(
        &mut self,
        root_id: RootId,
        generation: Arc<RootGeneration>,
        origin_tag: &'static str,
    ) -> SnapshotHandleId {
        let sequence = self.minter.next();
        assert_eq!(
            sequence & COMPOSED_HANDLE_NAMESPACE_BIT,
            0,
            "snapshot handle namespace exhausted"
        );
        let id = SnapshotHandleId::from_raw(sequence);
        self.open.insert(
            id,
            OpenHandle {
                root_id,
                generation,
                origin_tag,
                opened_at: Instant::now(),
            },
        );
        self.max_open_observed = self.max_open_observed.max(self.open.len());
        id
    }

    /// Idempotent close: closing twice, or closing an already-invalidated handle, is a no-op
    /// business outcome, not an error.
    pub fn close_handle(&mut self, id: SnapshotHandleId) {
        self.open.remove(&id);
        self.invalidated.remove(&id);
    }

    pub fn read(&self, id: SnapshotHandleId) -> HandleReadOutcome {
        if let Some(handle) = self.open.get(&id) {
            HandleReadOutcome::Open {
                generation: Arc::clone(&handle.generation),
            }
        } else if let Some(reason) = self.invalidated.get(&id) {
            HandleReadOutcome::HandleInvalidated { reason: *reason }
        } else {
            // Never issued (or already fully forgotten after an earlier close): total, not a
            // panic. No production path this models exercises this branch under correct usage.
            HandleReadOutcome::HandleInvalidated {
                reason: InvalidationReason::ScopeClosed,
            }
        }
    }

    /// `generationToken` equality check against a still-open handle, without materializing the
    /// full generation -- the mechanical anchor for `WorkspaceCatalogShardTests`'s `===`
    /// port (§4 "Instance-identity contract").
    #[must_use]
    pub fn token_of(&self, id: SnapshotHandleId) -> Option<GenerationToken> {
        self.open.get(&id).map(|handle| handle.generation.token)
    }

    /// `(root_id, generation_number)` for a still-open handle -- used by the scope to route
    /// `note_handle_closed_for_generation` to the right root on close.
    #[must_use]
    pub fn root_and_generation_of(&self, id: SnapshotHandleId) -> Option<(RootId, u64)> {
        self.open
            .get(&id)
            .map(|handle| (handle.root_id, handle.generation.generation))
    }

    /// Count of open handles referencing a specific `(root_id, generation_number)` pair -- used
    /// by `RootState::publish` bookkeeping to decide whether the outgoing generation must be
    /// retained.
    #[must_use]
    pub fn refcount_for_generation(&self, root_id: RootId, generation_number: u64) -> usize {
        self.open
            .values()
            .filter(|handle| {
                handle.root_id == root_id && handle.generation.generation == generation_number
            })
            .count()
    }

    /// `inventoryCloseRoot`'s mass invalidation: every handle over that root lifetime.
    pub fn invalidate_for_root(&mut self, root_id: RootId, reason: InvalidationReason) {
        let doomed: Vec<SnapshotHandleId> = self
            .open
            .iter()
            .filter(|(_, handle)| handle.root_id == root_id)
            .map(|(id, _)| *id)
            .collect();
        for id in doomed {
            self.open.remove(&id);
            self.invalidated.insert(id, reason);
        }
    }

    /// `inventoryCloseScope` / identity-change mass invalidation: every handle in the scope.
    /// Returns one `(root, generation)` entry per drained handle so callers that keep roots alive
    /// (identity invalidation) can release retained-generation bookkeeping exactly once.
    pub fn invalidate_all(&mut self, reason: InvalidationReason) -> Vec<(RootId, u64)> {
        let ids: Vec<SnapshotHandleId> = self.open.keys().copied().collect();
        let mut drained_generations = Vec::with_capacity(ids.len());
        for id in ids {
            let handle = self.open.remove(&id).expect("id came from open");
            drained_generations.push((handle.root_id, handle.generation.generation));
            self.invalidated.insert(id, reason);
        }
        drained_generations
    }

    #[must_use]
    pub fn open_count(&self) -> usize {
        self.open.len()
    }

    #[must_use]
    pub fn max_open_observed(&self) -> usize {
        self.max_open_observed
    }

    /// DEBUG leak observability (§4 layer 4): age of the oldest still-open handle.
    #[must_use]
    pub fn oldest_open_age(&self, now: Instant) -> Option<std::time::Duration> {
        self.open
            .values()
            .map(|handle| now.saturating_duration_since(handle.opened_at))
            .max()
    }

    /// DEBUG leak observability: open-handle count grouped by origin tag.
    #[must_use]
    pub fn origin_histogram(&self) -> HashMap<&'static str, usize> {
        let mut histogram = HashMap::new();
        for handle in self.open.values() {
            *histogram.entry(handle.origin_tag).or_insert(0) += 1;
        }
        histogram
    }
}

#[derive(Clone, Debug)]
pub enum ComposedHandleReadOutcome {
    Open {
        artifact: Arc<ComposedCatalogArtifact>,
    },
    HandleInvalidated {
        reason: InvalidationReason,
    },
}

struct OpenComposedHandle {
    artifact: Arc<ComposedCatalogArtifact>,
    origin_tag: &'static str,
    opened_at: Instant,
}

/// Separate typed handle table for immutable multi-root compositions. A composition is invalidated
/// when any source root closes, and a single-root reuse contributes to generation-retention
/// accounting exactly like an ordinary snapshot handle.
#[derive(Default)]
pub struct ComposedHandleTable {
    minter: super::ids::CounterMinter,
    open: HashMap<ComposedSnapshotHandleId, OpenComposedHandle>,
    invalidated: HashMap<ComposedSnapshotHandleId, InvalidationReason>,
    max_open_observed: usize,
}

impl ComposedHandleTable {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn open_handle(
        &mut self,
        artifact: Arc<ComposedCatalogArtifact>,
        origin_tag: &'static str,
    ) -> ComposedSnapshotHandleId {
        let sequence = self.minter.next();
        assert_eq!(
            sequence & COMPOSED_HANDLE_NAMESPACE_BIT,
            0,
            "composed snapshot handle namespace exhausted"
        );
        let id = ComposedSnapshotHandleId::from_raw(sequence | COMPOSED_HANDLE_NAMESPACE_BIT);
        self.open.insert(
            id,
            OpenComposedHandle {
                artifact,
                origin_tag,
                opened_at: Instant::now(),
            },
        );
        self.max_open_observed = self.max_open_observed.max(self.open.len());
        id
    }

    pub fn close_handle(&mut self, id: ComposedSnapshotHandleId) {
        self.open.remove(&id);
        self.invalidated.remove(&id);
    }

    pub fn read(&self, id: ComposedSnapshotHandleId) -> ComposedHandleReadOutcome {
        if let Some(handle) = self.open.get(&id) {
            ComposedHandleReadOutcome::Open {
                artifact: Arc::clone(&handle.artifact),
            }
        } else if let Some(reason) = self.invalidated.get(&id) {
            ComposedHandleReadOutcome::HandleInvalidated { reason: *reason }
        } else {
            ComposedHandleReadOutcome::HandleInvalidated {
                reason: InvalidationReason::ScopeClosed,
            }
        }
    }

    #[must_use]
    pub fn reused_root_and_generation_of(
        &self,
        id: ComposedSnapshotHandleId,
    ) -> Option<(RootId, u64)> {
        self.open
            .get(&id)
            .and_then(|handle| handle.artifact.reused_root_generation())
    }

    #[must_use]
    pub fn refcount_for_generation(&self, root_id: RootId, generation_number: u64) -> usize {
        self.open
            .values()
            .filter(|handle| {
                handle.artifact.reused_root_generation() == Some((root_id, generation_number))
            })
            .count()
    }

    pub fn invalidate_for_root(&mut self, root_id: RootId, reason: InvalidationReason) {
        let doomed: Vec<ComposedSnapshotHandleId> = self
            .open
            .iter()
            .filter(|(_, handle)| handle.artifact.source_root_ids().contains(&root_id))
            .map(|(id, _)| *id)
            .collect();
        for id in doomed {
            self.open.remove(&id);
            self.invalidated.insert(id, reason);
        }
    }

    /// Returns the reused single-root generation for each drained handle, if any. Generic
    /// multi-root artifacts do not contribute to retained-generation bookkeeping.
    pub fn invalidate_all(&mut self, reason: InvalidationReason) -> Vec<(RootId, u64)> {
        let ids: Vec<ComposedSnapshotHandleId> = self.open.keys().copied().collect();
        let mut drained_generations = Vec::new();
        for id in ids {
            let handle = self.open.remove(&id).expect("id came from open");
            if let Some(reused) = handle.artifact.reused_root_generation() {
                drained_generations.push(reused);
            }
            self.invalidated.insert(id, reason);
        }
        drained_generations
    }

    #[must_use]
    pub fn open_count(&self) -> usize {
        self.open.len()
    }

    #[must_use]
    pub fn max_open_observed(&self) -> usize {
        self.max_open_observed
    }

    #[must_use]
    pub fn oldest_open_age(&self, now: Instant) -> Option<std::time::Duration> {
        self.open
            .values()
            .map(|handle| now.saturating_duration_since(handle.opened_at))
            .max()
    }

    #[must_use]
    pub fn origin_histogram(&self) -> HashMap<&'static str, usize> {
        let mut histogram = HashMap::new();
        for handle in self.open.values() {
            *histogram.entry(handle.origin_tag).or_insert(0) += 1;
        }
        histogram
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn generation(root_id: RootId, generation_number: u64) -> Arc<RootGeneration> {
        let lifetime = super::super::ids::RootLifetimeId::from_bytes([9; 16]);
        let mut root_generation = RootGeneration::empty(root_id, lifetime);
        root_generation.generation = generation_number;
        root_generation.token = GenerationToken::new(lifetime, generation_number);
        Arc::new(root_generation)
    }

    #[test]
    fn open_then_close_is_idempotent_and_read_reports_invalidated_after_close() {
        let mut table = HandleTable::new();
        let root_id: RootId = [1; 16];
        let handle = table.open_handle(root_id, generation(root_id, 1), "test");
        assert!(matches!(table.read(handle), HandleReadOutcome::Open { .. }));
        table.close_handle(handle);
        table.close_handle(handle); // idempotent
        assert!(matches!(
            table.read(handle),
            HandleReadOutcome::HandleInvalidated { .. }
        ));
    }

    #[test]
    fn root_close_invalidates_only_that_roots_handles() {
        let mut table = HandleTable::new();
        let root_a: RootId = [1; 16];
        let root_b: RootId = [2; 16];
        let handle_a = table.open_handle(root_a, generation(root_a, 1), "test");
        let handle_b = table.open_handle(root_b, generation(root_b, 1), "test");
        table.invalidate_for_root(root_a, InvalidationReason::RootClosed);
        assert_eq!(
            table.read(handle_a),
            HandleReadOutcome::HandleInvalidated {
                reason: InvalidationReason::RootClosed
            }
        );
        assert!(matches!(
            table.read(handle_b),
            HandleReadOutcome::Open { .. }
        ));
    }

    #[test]
    fn scope_close_invalidates_every_handle() {
        let mut table = HandleTable::new();
        let root: RootId = [1; 16];
        let handles: Vec<_> = (0..5)
            .map(|_| table.open_handle(root, generation(root, 1), "test"))
            .collect();
        let drained = table.invalidate_all(InvalidationReason::ScopeClosed);
        assert_eq!(drained.len(), handles.len());
        for handle in handles {
            assert_eq!(
                table.read(handle),
                HandleReadOutcome::HandleInvalidated {
                    reason: InvalidationReason::ScopeClosed
                }
            );
        }
        assert_eq!(table.open_count(), 0);
    }

    #[test]
    fn same_generation_yields_equal_token_different_generation_yields_different_token() {
        let mut table = HandleTable::new();
        let root: RootId = [1; 16];
        let gen1 = generation(root, 1);
        let handle_a = table.open_handle(root, Arc::clone(&gen1), "test");
        let handle_b = table.open_handle(root, Arc::clone(&gen1), "test");
        let handle_c = table.open_handle(root, generation(root, 2), "test");
        assert_eq!(table.token_of(handle_a), table.token_of(handle_b));
        assert_ne!(table.token_of(handle_a), table.token_of(handle_c));
    }

    #[test]
    fn a_leaked_handle_never_blocks_further_opens() {
        let mut table = HandleTable::new();
        let root: RootId = [1; 16];
        let _leaked = table.open_handle(root, generation(root, 1), "leak");
        for _ in 0..1000 {
            table.open_handle(root, generation(root, 1), "churn");
        }
        assert_eq!(table.open_count(), 1001);
    }
}
