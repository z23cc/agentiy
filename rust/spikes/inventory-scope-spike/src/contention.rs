//! E-4: apply/read contention under an in-flight authoritative rebuild, and the per-root-vs-
//! per-scope lock evidence for open question 6.
//!
//! Two lock topologies, both built on `std::sync::Mutex` (never `RwLock` -- rejected per the
//! contract doc §2 "Rejected, per the design (§5.2.1)"), each wrapping a `RootTable`:
//!
//! - [`PerScopeLock`]: one `Mutex` guards every root in the scope (today's §5.2.1 default).
//! - [`PerRootLock`]: one `Mutex` per root.
//!
//! The out-of-lock rebuild discipline is modeled directly: `simulate_expensive_rebuild` builds a
//! full replacement table with **no lock held**, and only the O(1) pointer-swap installation step
//! takes the lock -- mirroring §2's "Expensive authoritative rebuild (backstop) | Computed outside
//! the lock from an Arc-cloned base plus the delta log; the lock is taken only to install the
//! result".

use crate::RootTable;
use std::sync::{Arc, Mutex};
use std::time::Instant;

pub struct PerScopeLock {
    roots: Arc<Mutex<Vec<RootTable>>>,
}

impl PerScopeLock {
    pub fn new(roots: Vec<RootTable>) -> Self {
        PerScopeLock { roots: Arc::new(Mutex::new(roots)) }
    }

    pub fn read_resolve(&self, root_index: usize, ids: &[u64]) -> (Vec<crate::FactRecord>, std::time::Duration) {
        let start = Instant::now();
        let guard = self.roots.lock().unwrap_or_else(|p| p.into_inner());
        let result = guard[root_index].resolve_by_ids(ids);
        (result, start.elapsed())
    }

    pub fn apply_delta(&self, root_index: usize, op: crate::DeltaOp) {
        let mut guard = self.roots.lock().unwrap_or_else(|p| p.into_inner());
        guard[root_index].apply_op(op);
    }

    /// Installs a freshly (out-of-lock) rebuilt table for one root -- the lock is held only for
    /// the swap.
    pub fn install_rebuilt(&self, root_index: usize, rebuilt: RootTable) {
        let mut guard = self.roots.lock().unwrap_or_else(|p| p.into_inner());
        guard[root_index] = rebuilt;
    }

    pub fn clone_handle(&self) -> Self {
        PerScopeLock { roots: Arc::clone(&self.roots) }
    }
}

pub struct PerRootLock {
    roots: Vec<Arc<Mutex<RootTable>>>,
}

impl PerRootLock {
    pub fn new(roots: Vec<RootTable>) -> Self {
        PerRootLock { roots: roots.into_iter().map(|r| Arc::new(Mutex::new(r))).collect() }
    }

    pub fn read_resolve(&self, root_index: usize, ids: &[u64]) -> (Vec<crate::FactRecord>, std::time::Duration) {
        let start = Instant::now();
        let guard = self.roots[root_index].lock().unwrap_or_else(|p| p.into_inner());
        let result = guard.resolve_by_ids(ids);
        (result, start.elapsed())
    }

    pub fn apply_delta(&self, root_index: usize, op: crate::DeltaOp) {
        let mut guard = self.roots[root_index].lock().unwrap_or_else(|p| p.into_inner());
        guard.apply_op(op);
    }

    pub fn install_rebuilt(&self, root_index: usize, rebuilt: RootTable) {
        let mut guard = self.roots[root_index].lock().unwrap_or_else(|p| p.into_inner());
        *guard = rebuilt;
    }

    pub fn clone_handle(&self) -> Self {
        PerRootLock { roots: self.roots.clone() }
    }
}

/// Builds a full replacement table with no lock held anywhere in this function -- the "expensive
/// authoritative rebuild backstop" (§7.2 layer 2) computed outside the critical section.
pub fn simulate_expensive_rebuild(root_id: crate::RootId, file_count: usize) -> RootTable {
    let files: Vec<crate::FileRecord> = (0..file_count as u64).map(|i| crate::FileRecord::synthetic(root_id, i)).collect();
    RootTable::build_authoritative(root_id, files)
}
