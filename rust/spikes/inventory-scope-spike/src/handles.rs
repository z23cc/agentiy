//! E-3: handle lifetime and backstop soak model.
//!
//! Models the four-layer generation-lease/handle-lifecycle contract from
//! `docs/architecture/rust-inventory-scope-v1.md` §4 at the granularity E-3 actually measures:
//! open/close/leak/scope-close/root-unload/identity-swap over a handle table, asserting (a) no
//! unbounded memory growth, (b) a leaked handle never blocks a mutation (writer liveness), (c)
//! every handle is invalidated on scope-close/identity-change, (d) a read against an invalidated
//! handle returns a typed outcome, never a panic/UB. Safe Rust with `unsafe_code = "forbid""`
//! (workspace lint, this spike inherits none of it since it isolates its own `[workspace]`, so the
//! forbid is re-declared at the crate root instead) makes double-free/use-after-free structurally
//! unreachable rather than merely tested-for -- there is no raw pointer or manual deallocation
//! anywhere in this module for a leaked/invalidated handle to dangle.

use std::collections::HashMap;

pub type HandleId = u64;
pub type RootId = u32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReadOutcome {
    Ok,
    HandleInvalidated { reason: InvalidationReason },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvalidationReason {
    RootClosed,
    ScopeClosed,
    IdentityChanged,
}

struct OpenHandle {
    root_id: RootId,
    #[allow(dead_code)] // diagnostic-only field (mirrors the design's DEBUG leak-origin histogram, §4 layer 4); not read by this spike's assertions
    origin_tag: &'static str,
}

pub struct HandleTable {
    next_id: HandleId,
    open: HashMap<HandleId, OpenHandle>,
    invalidated: HashMap<HandleId, InvalidationReason>,
    /// Mutation liveness proxy: incremented every time a mutation is attempted; must never be
    /// gated by `open`/`invalidated` size, which is exactly what "a leaked handle never blocks a
    /// mutation" means operationally.
    pub mutation_count: u64,
    pub max_open_handles_observed: usize,
}

impl HandleTable {
    pub fn new() -> Self {
        HandleTable {
            next_id: 1,
            open: HashMap::new(),
            invalidated: HashMap::new(),
            mutation_count: 0,
            max_open_handles_observed: 0,
        }
    }

    pub fn open_handle(&mut self, root_id: RootId, origin_tag: &'static str) -> HandleId {
        let id = self.next_id;
        self.next_id += 1;
        self.open.insert(id, OpenHandle { root_id, origin_tag });
        self.max_open_handles_observed = self.max_open_handles_observed.max(self.open.len());
        id
    }

    /// Idempotent close -- closing twice, or closing an already-invalidated handle, is a no-op.
    pub fn close_handle(&mut self, id: HandleId) {
        self.open.remove(&id);
        self.invalidated.remove(&id);
    }

    pub fn close_scope(&mut self) {
        for (id, _) in self.open.drain() {
            self.invalidated.insert(id, InvalidationReason::ScopeClosed);
        }
    }

    pub fn close_root(&mut self, root_id: RootId) {
        let doomed: Vec<HandleId> = self.open.iter().filter(|(_, h)| h.root_id == root_id).map(|(id, _)| *id).collect();
        for id in doomed {
            self.open.remove(&id);
            self.invalidated.insert(id, InvalidationReason::RootClosed);
        }
    }

    pub fn identity_swap(&mut self) {
        for (id, _) in self.open.drain() {
            self.invalidated.insert(id, InvalidationReason::IdentityChanged);
        }
    }

    /// A mutation attempt -- must always succeed regardless of open/leaked handle count. This is
    /// the writer-liveness guarantee (§7.1 guarantee 2) E-3 exercises: a leaked handle costs
    /// memory (its `OpenHandle` entry persists), never progress.
    pub fn apply_mutation(&mut self) {
        self.mutation_count += 1;
    }

    pub fn read(&self, id: HandleId) -> ReadOutcome {
        if self.open.contains_key(&id) {
            ReadOutcome::Ok
        } else if let Some(reason) = self.invalidated.get(&id) {
            ReadOutcome::HandleInvalidated { reason: *reason }
        } else {
            // Unknown id (never issued, or already fully forgotten after a prior close): treat as
            // invalidated-for-an-unspecified-reason rather than panicking. No production code path
            // this spike models exercises this branch; it exists so `read` is total.
            ReadOutcome::HandleInvalidated { reason: InvalidationReason::ScopeClosed }
        }
    }

    pub fn open_count(&self) -> usize {
        self.open.len()
    }

    /// Total tracked entries (open + invalidated-but-not-yet-closed). Bounded growth means this
    /// stays proportional to "handles opened since the last close/invalidate sweep", not to total
    /// iterations run -- i.e. invalidation must actually evict from `open`, and repeated
    /// close_handle/leak cycles must not accumulate forever in `invalidated` either.
    pub fn tracked_entry_count(&self) -> usize {
        self.open.len() + self.invalidated.len()
    }
}

impl Default for HandleTable {
    fn default() -> Self {
        Self::new()
    }
}
