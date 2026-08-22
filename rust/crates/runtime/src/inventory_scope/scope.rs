//! `InventoryScope`: the stateful, ID-addressed mutable domain scope §1 describes. Owns one
//! `Mutex<ScopeState>` per scope (§2's mechanism table row 1); published per-root artifacts are
//! `Arc<RootGeneration>`, immutable once published (row 2); an authoritative rebuild is computed
//! outside the lock from a cloned snapshot, installed under the lock only (row 4, and see
//! `state_machine`'s module doc comment for the flagged reading of "expensive work" for the
//! rebuild path specifically).
//!
//! **Scope discipline, per P4-3a's exit criteria:** this module implements the plain Rust surface
//! P4-3a's done-when names -- open/close scope+root, apply delta, bulk load
//! begin/push/commit/abort, snapshot open/page/close, diagnostics. It does not implement
//! `inventoryQuery`, `inventoryOpenProjectedShard`, `inventoryResolveRecords`, the wire codec, or
//! event-plane publication into `SubscriptionHub` -- those remain P4-4's (FFI + bridge) exit
//! criteria. **P4-3b lands in this module too:** `apply_delta`/`rebuild_and_install` publish a
//! `RootGeneration` whose `path_index` field (see `generation.rs`/`path_index`'s module doc
//! comments) is built by `state_machine::attempt_patch`/`rebuild_generation`, not by this file --
//! this file only orchestrates *when* those functions run, unchanged from P4-3a.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Barrier, Mutex};
use std::time::{Duration, Instant};

use crate::RuntimeIdentity;
use crate::inventory::{InventoryFileRecord, InventoryFolderRecord};

use super::bulk_load::{BulkLoadError, BulkLoadTable};
use super::delta::{InventoryDeltaCommand, InventoryDeltaReceipt};
use super::diagnostics::{HandleDiagnostics, InventoryDiagnosticsV1, RootDiagnostics};
use super::fallback::{
    InventoryApplyOutcome, InventoryRejectionReason, RootCatalogShardFallbackReason,
};
use super::handles::{HandleReadOutcome, HandleTable, InvalidationReason};
use super::identity_maps::IdentityMaps;
use super::ids::{
    BulkLoadId, GenerationToken, InventoryScopeId, RootId, RootLifetimeId, SnapshotHandleId,
    UuidMinter,
};
use super::ingress_gate;
use super::state_machine::{self, PatchAttempt, RootState};

const MAX_REBUILD_INSTALL_ATTEMPTS: u32 = 4;

#[derive(Clone, Debug)]
pub struct InventoryScopeConfig {
    /// §4 layer 2's `cap = 8`, preserved verbatim.
    pub live_generation_cap: usize,
    /// D-1's N, set to 1 per P4-2 §9b's provisional finding.
    pub max_patch_logical_mutation_count: usize,
}

impl Default for InventoryScopeConfig {
    fn default() -> Self {
        Self {
            live_generation_cap: 8,
            max_patch_logical_mutation_count: 1,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScopeError {
    IdentityMismatch,
    ScopeClosed,
    UnknownRoot,
    LifetimeMismatch,
    NoPublishedGeneration,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RootUnloadReceipt {
    pub root_id: RootId,
    pub root_lifetime_id: RootLifetimeId,
    pub final_generation: Option<u64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InventoryGenerationReceipt {
    pub root_id: RootId,
    pub generation: u64,
    pub token: GenerationToken,
}

/// **Flagged minimal choice:** the contract names `InventoryPublishModeV1` as a
/// `inventoryCommitBulkLoad` parameter without enumerating its cases beyond `atomicPublish`; this
/// is the only variant P4-3a models.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InventoryPublishMode {
    AtomicPublish,
}

struct ScopeState {
    closed: bool,
    roots: HashMap<RootId, RootState>,
    handles: HandleTable,
    bulk_loads: BulkLoadTable,
}

pub struct InventoryScope {
    identity: RuntimeIdentity,
    scope_id: InventoryScopeId,
    config: InventoryScopeConfig,
    lifetime_minter: UuidMinter,
    state: Mutex<ScopeState>,
    longest_critical_section_nanos: AtomicU64,
    rebuild_test_barrier: Mutex<Option<Arc<Barrier>>>,
    force_stale_base_once: AtomicBool,
    /// Set immediately before parking on a test-installed rebuild barrier, cleared immediately
    /// after. Lets a concurrency test spin-wait deterministically for "the writer has released
    /// the lock and is now parked in the expensive compute phase" without a wall-clock sleep or
    /// a race where the test's read loop finishes before the writer even starts.
    parked_on_rebuild_barrier: AtomicBool,
}

impl InventoryScope {
    #[must_use]
    pub fn new(
        identity: RuntimeIdentity,
        scope_id: InventoryScopeId,
        config: InventoryScopeConfig,
    ) -> Self {
        Self::with_minter(identity, scope_id, config, UuidMinter::fresh())
    }

    /// Deterministic construction for tests: `RootLifetimeId`s are minted from a seeded stream.
    #[must_use]
    pub fn new_seeded_for_testing(
        identity: RuntimeIdentity,
        scope_id: InventoryScopeId,
        config: InventoryScopeConfig,
        seed: u64,
    ) -> Self {
        Self::with_minter(identity, scope_id, config, UuidMinter::seeded(seed))
    }

    fn with_minter(
        identity: RuntimeIdentity,
        scope_id: InventoryScopeId,
        config: InventoryScopeConfig,
        lifetime_minter: UuidMinter,
    ) -> Self {
        Self {
            identity,
            scope_id,
            config,
            lifetime_minter,
            state: Mutex::new(ScopeState {
                closed: false,
                roots: HashMap::new(),
                handles: HandleTable::new(),
                bulk_loads: BulkLoadTable::new(),
            }),
            longest_critical_section_nanos: AtomicU64::new(0),
            rebuild_test_barrier: Mutex::new(None),
            force_stale_base_once: AtomicBool::new(false),
            parked_on_rebuild_barrier: AtomicBool::new(false),
        }
    }

    #[must_use]
    pub const fn scope_id(&self) -> InventoryScopeId {
        self.scope_id
    }

    #[must_use]
    pub const fn identity(&self) -> &RuntimeIdentity {
        &self.identity
    }

    /// Every state-plane lock acquisition goes through here: the crate's exceptionless
    /// poison-recovery idiom (`.unwrap_or_else(|poisoned| poisoned.into_inner())`), plus §2's
    /// longest-critical-section instrumentation.
    fn with_state<R>(&self, f: impl FnOnce(&mut ScopeState) -> R) -> R {
        let mut guard = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let started = Instant::now();
        let result = f(&mut guard);
        let elapsed_nanos = u64::try_from(started.elapsed().as_nanos()).unwrap_or(u64::MAX);
        drop(guard);
        self.longest_critical_section_nanos
            .fetch_max(elapsed_nanos, Ordering::Relaxed);
        result
    }

    // ---------------------------------------------------------------- control plane: root open/close

    pub fn open_root(
        &self,
        identity: &RuntimeIdentity,
        root_id: RootId,
        name: String,
        standardized_full_path: String,
    ) -> Result<RootLifetimeId, ScopeError> {
        if identity != &self.identity {
            return Err(ScopeError::IdentityMismatch);
        }
        let lifetime = RootLifetimeId::mint(&self.lifetime_minter);
        self.with_state(|state| {
            if state.closed {
                return Err(ScopeError::ScopeClosed);
            }
            if state.roots.remove(&root_id).is_some() {
                // Implicit close of the prior lifetime (§4's "close-root -> reopen mints a new
                // RootLifetimeId" port anchor): invalidate its handles and abort its in-flight
                // bulk loads before installing the fresh `RootState`.
                state
                    .handles
                    .invalidate_for_root(root_id, InvalidationReason::RootClosed);
                state.bulk_loads.abort_all_for_root(root_id);
            }
            state.roots.insert(
                root_id,
                RootState::new(
                    root_id,
                    name,
                    standardized_full_path,
                    lifetime,
                    self.config.live_generation_cap,
                ),
            );
            Ok(lifetime)
        })
    }

    pub fn close_root(
        &self,
        identity: &RuntimeIdentity,
        root_id: RootId,
        root_lifetime_id: RootLifetimeId,
    ) -> Result<RootUnloadReceipt, ScopeError> {
        if identity != &self.identity {
            return Err(ScopeError::IdentityMismatch);
        }
        self.with_state(|state| {
            if state.closed {
                return Err(ScopeError::ScopeClosed);
            }
            match state.roots.get(&root_id) {
                None => Err(ScopeError::UnknownRoot),
                Some(root) if root.root_lifetime != root_lifetime_id => {
                    Err(ScopeError::LifetimeMismatch)
                }
                Some(_) => {
                    let removed = state.roots.remove(&root_id).expect("checked above");
                    state
                        .handles
                        .invalidate_for_root(root_id, InvalidationReason::RootClosed);
                    state.bulk_loads.abort_all_for_root(root_id);
                    Ok(RootUnloadReceipt {
                        root_id,
                        root_lifetime_id,
                        final_generation: removed.published.map(|generation| generation.generation),
                    })
                }
            }
        })
    }

    pub fn close(&self, identity: &RuntimeIdentity) -> Result<(), ScopeError> {
        if identity != &self.identity {
            return Err(ScopeError::IdentityMismatch);
        }
        self.with_state(|state| {
            state.closed = true;
            state
                .handles
                .invalidate_all(InvalidationReason::ScopeClosed);
            state.roots.clear();
        });
        Ok(())
    }

    /// Mass invalidation triggered by a `RuntimeIdentity` change (§4 layer 3). P4-3a does not
    /// wire this to a real process-wide identity swap (that lives above this crate's cargo-only
    /// scope); it is the operation CoreRuntime later calls.
    pub fn invalidate_all_for_identity_change(&self) {
        self.with_state(|state| {
            state
                .handles
                .invalidate_all(InvalidationReason::IdentityChanged)
        });
    }

    // ---------------------------------------------------------------------------- ingest: apply_delta

    pub fn apply_delta(
        &self,
        identity: &RuntimeIdentity,
        command: InventoryDeltaCommand,
    ) -> InventoryDeltaReceipt {
        if identity != &self.identity {
            return reject(InventoryRejectionReason::IdentityMismatch, 0, None);
        }

        enum Phase1 {
            Done(InventoryDeltaReceipt),
            NeedsRebuild { base_generation: Option<u64> },
        }

        let phase1 = self.with_state(|state| -> Phase1 {
            if state.closed {
                return Phase1::Done(reject(InventoryRejectionReason::ScopeClosed, 0, None));
            }
            let Some(root) = state.roots.get_mut(&command.root_id) else {
                return Phase1::Done(reject(InventoryRejectionReason::UnknownRoot, 0, None));
            };
            if root.root_lifetime != command.root_lifetime_id {
                return Phase1::Done(reject(
                    InventoryRejectionReason::LifetimeMismatch,
                    root.last_applied_index_generation,
                    root.published.as_ref().map(|g| g.generation),
                ));
            }
            if let Err(reason) = root.ingress_gate.admit_watermark(
                command.watcher_accepted_watermark,
                command.requires_full_resync,
            ) {
                return Phase1::Done(reject(
                    reason,
                    root.last_applied_index_generation,
                    root.published.as_ref().map(|g| g.generation),
                ));
            }
            if let Err(reason) = ingress_gate::check_generation_gap(
                command.expected_applied_index_generation,
                root.last_applied_index_generation,
                command.requires_full_resync,
            ) {
                return Phase1::Done(reject(
                    reason,
                    root.last_applied_index_generation,
                    root.published.as_ref().map(|g| g.generation),
                ));
            }

            root.apply_event_to_maps(&command.event);

            let rebuild_reason = if command.requires_full_resync {
                Some(RootCatalogShardFallbackReason::FullResync)
            } else if root.published.is_none() {
                Some(RootCatalogShardFallbackReason::MissingReusableShard)
            } else if root.event_touches_managed_only(&command.event) {
                Some(RootCatalogShardFallbackReason::UnsafeOrAmbiguousBatch)
            } else {
                None
            };

            if let Some(reason) = rebuild_reason {
                root.counters.record_fallback(reason);
                return Phase1::NeedsRebuild {
                    base_generation: root.published.as_ref().map(|g| g.generation),
                };
            }

            match state_machine::attempt_patch(
                root,
                &command.event,
                self.config.max_patch_logical_mutation_count,
            ) {
                PatchAttempt::Patched(generation) => {
                    let outgoing_generation_number = root.published.as_ref().map(|g| g.generation);
                    let outgoing_refcount =
                        outgoing_generation_number.map_or(0, |generation_number| {
                            state
                                .handles
                                .refcount_for_generation(command.root_id, generation_number)
                        });
                    let root = state
                        .roots
                        .get_mut(&command.root_id)
                        .expect("checked above");
                    let published = root.publish(generation, outgoing_refcount);
                    root.last_applied_index_generation += 1;
                    root.counters.patch_count += 1;
                    Phase1::Done(InventoryDeltaReceipt {
                        applied_index_generation: root.last_applied_index_generation,
                        catalog_generation: Some(published.generation),
                        outcome: InventoryApplyOutcome::Patched,
                    })
                }
                PatchAttempt::NeedsRebuild(reason) => {
                    root.counters.record_fallback(reason);
                    Phase1::NeedsRebuild {
                        base_generation: root.published.as_ref().map(|g| g.generation),
                    }
                }
            }
        });

        match phase1 {
            Phase1::Done(receipt) => receipt,
            Phase1::NeedsRebuild { base_generation } => {
                self.rebuild_and_install(command.root_id, base_generation)
            }
        }
    }

    /// The expensive path: clone inputs under a brief lock, compute the sort/filter outside it,
    /// install under a second brief lock only if the base generation is still current. Bounded
    /// retry exists purely as a defensive backstop under this crate's single-writer contract
    /// (§5.2.1 explicitly rejects optimistic-versioning machinery *because* the workload is
    /// single-writer) -- see `PatchApplicationBackstop`'s doc comment and
    /// `testing_force_stale_base_once` for how the path is exercised in tests.
    fn rebuild_and_install(
        &self,
        root_id: RootId,
        base_generation: Option<u64>,
    ) -> InventoryDeltaReceipt {
        enum Install {
            Done(InventoryDeltaReceipt),
            Stale,
            RootGone,
        }

        for attempt in 0..MAX_REBUILD_INSTALL_ATTEMPTS {
            let Some(input) = self.with_state(|state| {
                state
                    .roots
                    .get(&root_id)
                    .map(RootState::snapshot_for_rebuild)
            }) else {
                return reject(InventoryRejectionReason::UnknownRoot, 0, None);
            };

            if let Some(barrier) = self
                .rebuild_test_barrier
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .take()
            {
                self.parked_on_rebuild_barrier.store(true, Ordering::SeqCst);
                barrier.wait();
                self.parked_on_rebuild_barrier
                    .store(false, Ordering::SeqCst);
            }

            let force_stale =
                attempt == 0 && self.force_stale_base_once.swap(false, Ordering::SeqCst);

            let Ok(generation) = state_machine::rebuild_generation(&input) else {
                return reject(InventoryRejectionReason::UnknownRoot, 0, None);
            };

            let install = self.with_state(|state| -> Install {
                let current_generation = match state.roots.get(&root_id) {
                    None => return Install::RootGone,
                    Some(root) => root.published.as_ref().map(|g| g.generation),
                };
                if force_stale || current_generation != base_generation {
                    if let Some(root) = state.roots.get_mut(&root_id) {
                        root.counters.record_fallback(
                            RootCatalogShardFallbackReason::PatchApplicationBackstop,
                        );
                    }
                    return Install::Stale;
                }
                let outgoing_refcount = current_generation.map_or(0, |generation_number| {
                    state
                        .handles
                        .refcount_for_generation(root_id, generation_number)
                });
                let root = state.roots.get_mut(&root_id).expect("checked above");
                let published = root.publish(generation, outgoing_refcount);
                root.last_applied_index_generation += 1;
                root.counters.authoritative_rebuild_count += 1;
                Install::Done(InventoryDeltaReceipt {
                    applied_index_generation: root.last_applied_index_generation,
                    catalog_generation: Some(published.generation),
                    outcome: InventoryApplyOutcome::RebuiltAuthoritative,
                })
            });

            match install {
                Install::Done(receipt) => return receipt,
                Install::RootGone => return reject(InventoryRejectionReason::UnknownRoot, 0, None),
                Install::Stale => {}
            }
        }
        // Retries exhausted: under the single-writer contract this is unreachable in correct
        // usage. Degrade to a rejection (never panic, never loop forever).
        reject(
            InventoryRejectionReason::GenerationGap {
                expected: base_generation.unwrap_or(0),
                actual: base_generation.unwrap_or(0),
            },
            0,
            None,
        )
    }

    // -------------------------------------------------------------------------------- bulk load

    pub fn begin_bulk_load(
        &self,
        identity: &RuntimeIdentity,
        root_id: RootId,
        root_lifetime_id: RootLifetimeId,
    ) -> Result<BulkLoadId, ScopeError> {
        if identity != &self.identity {
            return Err(ScopeError::IdentityMismatch);
        }
        self.with_state(|state| {
            if state.closed {
                return Err(ScopeError::ScopeClosed);
            }
            match state.roots.get(&root_id) {
                None => Err(ScopeError::UnknownRoot),
                Some(root) if root.root_lifetime != root_lifetime_id => {
                    Err(ScopeError::LifetimeMismatch)
                }
                Some(_) => Ok(state.bulk_loads.begin(root_id, root_lifetime_id)),
            }
        })
    }

    pub fn push_bulk_chunk(
        &self,
        identity: &RuntimeIdentity,
        bulk_load_id: BulkLoadId,
        root_id: RootId,
        files: Vec<InventoryFileRecord>,
        folders: Vec<InventoryFolderRecord>,
    ) -> Result<(), BulkLoadError> {
        if identity != &self.identity {
            return Err(BulkLoadError::Unknown);
        }
        self.with_state(|state| {
            state
                .bulk_loads
                .push_chunk(bulk_load_id, root_id, files, folders)
        })
    }

    pub fn abort_bulk_load(
        &self,
        identity: &RuntimeIdentity,
        bulk_load_id: BulkLoadId,
    ) -> Result<(), BulkLoadError> {
        if identity != &self.identity {
            return Err(BulkLoadError::Unknown);
        }
        self.with_state(|state| state.bulk_loads.abort(bulk_load_id))
    }

    /// Publishes the entire staged root in **one** critical section (§5.2's atomic root
    /// publication invariant), replacing the root's identity maps wholesale -- a bulk load is a
    /// full replacement, not a delta.
    pub fn commit_bulk_load(
        &self,
        identity: &RuntimeIdentity,
        bulk_load_id: BulkLoadId,
        _publish_mode: InventoryPublishMode,
    ) -> Result<InventoryGenerationReceipt, BulkLoadError> {
        if identity != &self.identity {
            return Err(BulkLoadError::Unknown);
        }
        self.with_state(|state| {
            let (root_id, root_lifetime, staging) =
                state.bulk_loads.take_for_commit(bulk_load_id)?;
            let Some(root) = state.roots.get_mut(&root_id) else {
                return Err(BulkLoadError::RootMismatch);
            };
            if root.root_lifetime != root_lifetime {
                return Err(BulkLoadError::RootMismatch);
            }
            root.maps = IdentityMaps::default();
            for file in staging.files {
                root.maps.upsert_file(file);
            }
            for folder in staging.folders {
                root.maps.upsert_folder(folder);
            }
            let input = root.snapshot_for_rebuild();
            let generation = state_machine::rebuild_generation(&input)
                .map_err(|_| BulkLoadError::RootMismatch)?;
            let current_generation = root.published.as_ref().map(|g| g.generation);
            let outgoing_refcount = current_generation.map_or(0, |generation_number| {
                state
                    .handles
                    .refcount_for_generation(root_id, generation_number)
            });
            let root = state.roots.get_mut(&root_id).expect("checked above");
            let published = root.publish(generation, outgoing_refcount);
            root.last_applied_index_generation += 1;
            root.counters.authoritative_rebuild_count += 1;
            Ok(InventoryGenerationReceipt {
                root_id,
                generation: published.generation,
                token: published.token,
            })
        })
    }

    // ----------------------------------------------------------------------------- read plane

    pub fn open_snapshot(
        &self,
        identity: &RuntimeIdentity,
        root_id: RootId,
        origin_tag: &'static str,
    ) -> Result<SnapshotHandleId, ScopeError> {
        if identity != &self.identity {
            return Err(ScopeError::IdentityMismatch);
        }
        self.with_state(|state| {
            if state.closed {
                return Err(ScopeError::ScopeClosed);
            }
            let Some(root) = state.roots.get(&root_id) else {
                return Err(ScopeError::UnknownRoot);
            };
            let Some(generation) = root.published.clone() else {
                return Err(ScopeError::NoPublishedGeneration);
            };
            Ok(state.handles.open_handle(root_id, generation, origin_tag))
        })
    }

    #[must_use]
    pub fn read_snapshot(&self, handle_id: SnapshotHandleId) -> HandleReadOutcome {
        self.with_state(|state| state.handles.read(handle_id))
    }

    /// Clones the `Arc<RootGeneration>` under the lock, then does paging work outside it (§2 row
    /// 2, verbatim).
    #[must_use]
    pub fn snapshot_page(
        &self,
        handle_id: SnapshotHandleId,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<InventoryFileRecord>, InvalidationReason> {
        match self.with_state(|state| state.handles.read(handle_id)) {
            HandleReadOutcome::Open { generation } => Ok(generation
                .files
                .iter()
                .skip(offset)
                .take(limit)
                .cloned()
                .collect()),
            HandleReadOutcome::HandleInvalidated { reason } => Err(reason),
        }
    }

    pub fn close_snapshot(&self, handle_id: SnapshotHandleId) {
        self.with_state(|state| {
            if let Some((root_id, generation_number)) =
                state.handles.root_and_generation_of(handle_id)
            {
                if let Some(root) = state.roots.get_mut(&root_id) {
                    root.note_handle_closed_for_generation(generation_number);
                }
            }
            state.handles.close_handle(handle_id);
        });
    }

    // ------------------------------------------------------------------------------ diagnostics

    pub fn diagnostics(
        &self,
        identity: &RuntimeIdentity,
    ) -> Result<InventoryDiagnosticsV1, ScopeError> {
        if identity != &self.identity {
            return Err(ScopeError::IdentityMismatch);
        }
        Ok(self.with_state(|state| {
            let roots: Vec<RootDiagnostics> = state
                .roots
                .values()
                .map(|root| RootDiagnostics {
                    root_id: root.root_id,
                    lifetime_id: Some(root.root_lifetime),
                    published_topology_generation: root.counters.published_topology_generation,
                    live_topology_generations: root.live_topology_generations(),
                    retained_topology_generations: root.retained_topology_generations(),
                    build_count: root.counters.build_count,
                    path_index_build_count: root.counters.path_index_build_count,
                    overlay_path_index_build_count: root.counters.overlay_path_index_build_count,
                    patch_count: root.counters.patch_count,
                    authoritative_rebuild_count: root.counters.authoritative_rebuild_count,
                    fallback_count: root.counters.fallback_count,
                    fallback_reason_counts: root.counters.fallback_reason_counts.clone(),
                    last_applied_index_generation: Some(root.last_applied_index_generation),
                    delta_state_dirty: root.counters.delta_state_dirty,
                    backstop_count: root.counters.backstop_count,
                    max_live_generation_count: root.counters.max_live_generation_count,
                })
                .collect();
            InventoryDiagnosticsV1 {
                live_generation_cap_per_root: self.config.live_generation_cap,
                max_patch_logical_mutation_count: self.config.max_patch_logical_mutation_count,
                published_shard_count: state
                    .roots
                    .values()
                    .filter(|root| root.published.is_some())
                    .count() as u64,
                total_build_count: state
                    .roots
                    .values()
                    .map(|root| root.counters.build_count)
                    .sum(),
                total_backstop_count: state
                    .roots
                    .values()
                    .map(|root| root.counters.backstop_count)
                    .sum(),
                // Multi-root snapshot composition (design §4.1 item 7 -- k-way merge across
                // roots, distinct from this step's per-root index orchestration): not built by
                // any landed step yet; flagged for whichever later step adds multi-root snapshot
                // composition (P4-4's read surface or beyond).
                single_shard_composition_reuse_count: 0,
                generic_merge_element_visit_count: 0,
                // No shadow arm exists at P4-3a (P4-5's job); the self-check testing hook below
                // is the only reachable trigger, and it is not wired to these counters
                // automatically -- flagged in `fallback::RootCatalogShardFallbackReason::ShadowValidationMismatch`.
                shadow_comparison_count: 0,
                shadow_mismatch_count: 0,
                last_shadow_byte_count: 0,
                roots,
                longest_critical_section: Duration::from_nanos(
                    self.longest_critical_section_nanos.load(Ordering::Relaxed),
                ),
                handles: HandleDiagnostics {
                    open_count: state.handles.open_count(),
                    oldest_open_age: state.handles.oldest_open_age(Instant::now()),
                    origin_histogram: state.handles.origin_histogram(),
                },
            }
        }))
    }

    // --------------------------------------------------------------------------- testing hooks

    /// Installs a one-shot barrier the next authoritative rebuild's compute phase waits on
    /// **after releasing the state lock** -- lets a test deterministically control rebuild
    /// timing instead of racing wall-clock sleeps (the reader-never-blocked-by-rebuild test).
    pub fn testing_install_rebuild_barrier(&self, barrier: Arc<Barrier>) {
        *self
            .rebuild_test_barrier
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(barrier);
    }

    /// Forces the next rebuild's install phase to observe a stale base exactly once, exercising
    /// `PatchApplicationBackstop` -- a path this crate's single-writer contract does not reach in
    /// normal operation (see `rebuild_and_install`'s doc comment).
    pub fn testing_force_stale_base_once(&self) {
        self.force_stale_base_once.store(true, Ordering::SeqCst);
    }

    /// True while a writer is parked on a `testing_install_rebuild_barrier`-installed barrier,
    /// with the state lock already released. A test spin-waits on this (not a sleep) to know
    /// when it is safe to start asserting non-blocked reads, deterministically -- see
    /// `inventory_scope_concurrency.rs`.
    #[must_use]
    pub fn testing_is_parked_on_rebuild_barrier(&self) -> bool {
        self.parked_on_rebuild_barrier.load(Ordering::SeqCst)
    }

    /// P4-3b testing accessor: the currently published generation's path search index, for
    /// build-kind and ordered-candidate coverage. Not part of the read plane proper --
    /// `inventoryQuery`'s real FFI-facing shape is P4-4's job (§5.3); this is a direct `Arc` clone
    /// used only by this crate's own tests.
    #[must_use]
    pub fn testing_published_path_index(
        &self,
        root_id: RootId,
    ) -> Option<Arc<super::path_index::RootPathIndex>> {
        self.with_state(|state| {
            state
                .roots
                .get(&root_id)
                .and_then(|root| root.published.as_ref())
                .map(|generation| Arc::clone(&generation.path_index))
        })
    }

    /// Marks a file managed-only (or clears that mark) directly against a root's identity maps,
    /// bypassing the delta pipeline entirely. **Testing-only, flagged:** P4-3a's delta pipeline
    /// does not model managed-only registration as a distinct wire operation (that concept's real
    /// call site lives above this crate); this hook exists so managed-only-triggered fallback
    /// paths (`UnsafeOrAmbiguousBatch` via a managed-only touch, `ShadowValidationMismatch`) are
    /// genuinely reachable and testable at P4-3a.
    pub fn testing_set_file_managed_only(
        &self,
        root_id: RootId,
        id: crate::inventory::InventoryUuid,
        managed_only: bool,
    ) {
        self.with_state(|state| {
            if let Some(root) = state.roots.get_mut(&root_id) {
                root.maps.set_file_managed_only(id, managed_only);
            }
        });
    }

    /// Compares the currently published generation against a fresh authoritative rebuild of the
    /// same root and records `ShadowValidationMismatch` on disagreement. Exercises a fallback
    /// reason whose real (P4-5) trigger -- the shadow arm -- does not exist yet at P4-3a; see
    /// that reason's doc comment.
    pub fn testing_self_check_patch_against_rebuild(&self, root_id: RootId) -> bool {
        self.with_state(|state| {
            let Some(root) = state.roots.get_mut(&root_id) else {
                return false;
            };
            let Some(published) = root.published.clone() else {
                return false;
            };
            let input = root.snapshot_for_rebuild();
            let Ok(rebuilt) = state_machine::rebuild_generation(&input) else {
                return false;
            };
            let mismatch = rebuilt.files != published.files || rebuilt.folders != published.folders;
            if mismatch {
                root.counters
                    .record_fallback(RootCatalogShardFallbackReason::ShadowValidationMismatch);
            }
            mismatch
        })
    }
}

fn reject(
    reason: InventoryRejectionReason,
    applied_index_generation: u64,
    catalog_generation: Option<u64>,
) -> InventoryDeltaReceipt {
    InventoryDeltaReceipt {
        applied_index_generation,
        catalog_generation,
        outcome: InventoryApplyOutcome::Rejected(reason),
    }
}
