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
//! `inventoryQuery`, `inventoryOpenProjectedShard`, or `inventoryResolveRecords` -- those remain
//! P4-4's (FFI) exit criteria. **P4-4b lands event-plane publication into `SubscriptionHub` in
//! this module** (see the "event plane (P4-4b)" section below and its lock-ordering rule);
//! `attach_event_sink` still leaves the FFI layer owning the `SubscriptionHub` instance itself
//! and the `InventoryScopeId -> ScopeId` derivation (`InventoryScopeId::to_subscription_scope_id`
//! in `ids.rs`). **P4-3b lands in this module too:** `apply_delta`/`rebuild_and_install` publish a
//! `RootGeneration` whose `path_index` field (see `generation.rs`/`path_index`'s module doc
//! comments) is built by `state_machine::attempt_patch`/`rebuild_generation`, not by this file --
//! this file only orchestrates *when* those functions run, unchanged from P4-3a.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Barrier, Mutex};
use std::time::{Duration, Instant};

use crate::inventory::{InventoryFileRecord, InventoryFolderRecord, InventoryUuid};
use crate::{EventClass, EventInput, RuntimeEventKind, RuntimeIdentity, ScopeId, SubscriptionHub};

use super::bulk_load::{BulkLoadError, BulkLoadTable};
use super::delta::{InventoryDeltaCommand, InventoryDeltaReceipt};
use super::wire::{DiscoveredFileRecord, DiscoveredFolderRecord, InventoryDiscoveryAppliedIndexBatchEvent};
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
    /// P4-4 (contract doc §6 / design §5.3): "the codemap-capable extension->language table
    /// (`SyntaxManager.supportsCodeMap`, `CodeMapSyntaxEngine.extensionToLanguage`) is
    /// Swift-owned policy passed **in** at `inventoryOpenScope` as scope configuration, not
    /// resolved implicitly inside Rust." Lower-cased extensions, no leading dot (matches
    /// `resolve::extension_of`'s normalization). Consumed by
    /// [`InventoryScope::open_projected_shard`].
    pub codemap_capable_extensions: std::collections::HashSet<String>,
}

impl Default for InventoryScopeConfig {
    fn default() -> Self {
        Self {
            live_generation_cap: 8,
            max_patch_logical_mutation_count: 1,
            codemap_capable_extensions: std::collections::HashSet::new(),
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

/// `InventoryScope::snapshot_page`'s return shape. Fixes a gap `WorkspaceInventoryScopeShadowForwarder`
/// surfaced (design doc `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §8.2):
/// the FFI read plane (`inventory_snapshot_page`, `rust/crates/ffi/src/api.rs`) previously encoded
/// every page response with a hardcoded empty folders list regardless of what a bulk load staged
/// or committed -- `RootGeneration.folders` was correctly populated end-to-end, but nothing ever
/// paged it back out to a caller. No P4-4/P4-4b test exercised this because every existing
/// bulk-load round trip pushed `folders: []`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SnapshotPage {
    pub files: Vec<InventoryFileRecord>,
    pub folders: Vec<InventoryFolderRecord>,
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

/// [`InventoryScope::push_bulk_chunk_discovery`]'s receipt (§4.1.1): the minted file/folder ids,
/// in the same order as the input vectors the caller supplied.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BulkChunkDiscoveryReceipt {
    pub minted_file_ids: Vec<InventoryUuid>,
    pub minted_folder_ids: Vec<InventoryUuid>,
}

/// [`InventoryDeltaCommand`]'s discovery counterpart: identical shape, `event` carries id-less
/// upserts.
#[derive(Clone, Debug)]
pub struct InventoryDeltaDiscoveryCommand {
    pub scope_id: InventoryScopeId,
    pub root_id: RootId,
    pub root_lifetime_id: RootLifetimeId,
    pub watcher_accepted_watermark: Option<u64>,
    pub requires_full_resync: bool,
    pub expected_applied_index_generation: Option<u64>,
    pub source: String,
    pub event: InventoryDiscoveryAppliedIndexBatchEvent,
}

/// [`InventoryScope::apply_delta_discovery`]'s receipt: the normal [`InventoryDeltaReceipt`] plus
/// the minted file/folder ids, in the same order as `event.upserted_files`/`upserted_folders` on
/// the input command. **The minted ids are populated even on a `Rejected` outcome** -- minting
/// happens before the gate runs (the ids are needed to *build* the event the gate evaluates), so
/// a caller must not assume a rejected delta's minted ids were "not really minted"; they were
/// minted and then never staged anywhere, which is safe (ids are cheap, per-scope, and never
/// persisted) but is worth stating so a caller doesn't try to "un-mint" or reuse them.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InventoryDeltaDiscoveryReceipt {
    pub receipt: InventoryDeltaReceipt,
    pub minted_file_ids: Vec<InventoryUuid>,
    pub minted_folder_ids: Vec<InventoryUuid>,
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

/// P4-4b: where this scope publishes event-plane notifications (contract doc §5b). `Option`
/// (not required at construction) so every existing cargo-only construction path
/// (`new`/`new_seeded_for_testing`, this crate's own concurrency/property tests) keeps compiling
/// unchanged; a scope with no sink attached simply drops its event batches (`publish_events`
/// no-ops). The FFI layer (`rust/crates/ffi/src/api.rs`) attaches the real sink immediately
/// after minting a scope via `attach_event_sink`.
#[derive(Clone)]
struct InventoryEventSink {
    hub: Arc<SubscriptionHub>,
    scope_id: ScopeId,
}

pub struct InventoryScope {
    identity: RuntimeIdentity,
    scope_id: InventoryScopeId,
    config: InventoryScopeConfig,
    lifetime_minter: UuidMinter,
    /// §4.1.1's discovery mint site: mints file/folder record identity, deliberately on its own
    /// `UuidMinter` stream (never `lifetime_minter`'s) so a test-seeded scope's record ids and
    /// lifetime ids are independent sequences. `&self`-callable like every other minter here
    /// (`UuidMinter::next_bytes`/`next_v4_bytes` are interior-mutable via their own `AtomicU64`).
    record_minter: UuidMinter,
    state: Mutex<ScopeState>,
    longest_critical_section_nanos: AtomicU64,
    rebuild_test_barrier: Mutex<Option<Arc<Barrier>>>,
    force_stale_base_once: AtomicBool,
    /// Set immediately before parking on a test-installed rebuild barrier, cleared immediately
    /// after. Lets a concurrency test spin-wait deterministically for "the writer has released
    /// the lock and is now parked in the expensive compute phase" without a wall-clock sleep or
    /// a race where the test's read loop finishes before the writer even starts.
    parked_on_rebuild_barrier: AtomicBool,
    event_sink: Mutex<Option<InventoryEventSink>>,
    /// Mirrors `rebuild_test_barrier`/`parked_on_rebuild_barrier` exactly, for the same reason:
    /// `inventory_scope_event_lock_ordering.rs` needs a way to park a publish call
    /// deterministically (post-`with_state`) and prove a concurrent `with_state`-guarded reader
    /// makes progress while it is parked -- see `publish_events`'s doc comment for what that
    /// proves.
    publish_test_barrier: Mutex<Option<Arc<Barrier>>>,
    parked_on_publish_barrier: AtomicBool,
    /// Best-effort publish failures (wake-pipe I/O error, a lossless event that cannot fit even
    /// after eviction) -- see `publish_events`'s doc comment for why these never surface as a
    /// mutation error. DEBUG/diagnostic counter only; not part of `InventoryDiagnosticsV1` (no
    /// Swift-side precedent field to port it into, unlike every other diagnostics counter -- see
    /// contract doc §5c).
    publish_failure_count: AtomicU64,
}

/// Splitmix64 salt XORed into a caller-supplied seed to derive the record minter's seed from the
/// lifetime minter's, so `new_seeded_for_testing(seed)` gives two independent-but-deterministic
/// streams from one caller-facing parameter rather than adding a second seed argument (which
/// would ripple through every existing call site of an already-`pub` test constructor).
const RECORD_MINTER_SEED_SALT: u64 = 0x9E37_79B9_7F4A_7C15;

impl InventoryScope {
    #[must_use]
    pub fn new(
        identity: RuntimeIdentity,
        scope_id: InventoryScopeId,
        config: InventoryScopeConfig,
    ) -> Self {
        Self::with_minters(identity, scope_id, config, UuidMinter::fresh(), UuidMinter::fresh())
    }

    /// Deterministic construction for tests: `RootLifetimeId`s and record ids are each minted
    /// from their own seeded stream (record stream seeded with `seed ^ RECORD_MINTER_SEED_SALT`
    /// so the two never coincidentally produce the same byte sequence).
    #[must_use]
    pub fn new_seeded_for_testing(
        identity: RuntimeIdentity,
        scope_id: InventoryScopeId,
        config: InventoryScopeConfig,
        seed: u64,
    ) -> Self {
        Self::with_minters(
            identity,
            scope_id,
            config,
            UuidMinter::seeded(seed),
            UuidMinter::seeded(seed ^ RECORD_MINTER_SEED_SALT),
        )
    }

    fn with_minters(
        identity: RuntimeIdentity,
        scope_id: InventoryScopeId,
        config: InventoryScopeConfig,
        lifetime_minter: UuidMinter,
        record_minter: UuidMinter,
    ) -> Self {
        Self {
            identity,
            scope_id,
            config,
            lifetime_minter,
            record_minter,
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
            event_sink: Mutex::new(None),
            publish_test_barrier: Mutex::new(None),
            parked_on_publish_barrier: AtomicBool::new(false),
            publish_failure_count: AtomicU64::new(0),
        }
    }

    /// Wires this scope's event-plane publication (contract doc §5b) into the shared
    /// `SubscriptionHub`. Called once by the FFI layer immediately after minting the scope
    /// (`ScopeRegistry::open_scope`) -- see `InventoryScopeId::to_subscription_scope_id` for the
    /// `ScopeId` derivation the caller must use so the generic `openSubscription`/`tryDrain` FFI
    /// surface (already scope-generic, unchanged by this step) addresses the same hub queue this
    /// scope publishes into. Idempotent: a later call simply replaces the sink; no production
    /// call site does this more than once.
    pub fn attach_event_sink(&self, hub: Arc<SubscriptionHub>, scope_id: ScopeId) {
        *self
            .event_sink
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(InventoryEventSink { hub, scope_id });
    }

    #[must_use]
    pub fn publish_failure_count(&self) -> u64 {
        self.publish_failure_count.load(Ordering::Relaxed)
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
        let result = self.with_state(|state| {
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
        });
        if result.is_ok() {
            let payload = super::wire::encode_root_published(&super::wire::RootLifecycleEvent {
                root_id,
                root_lifetime_id: *lifetime.as_bytes(),
            });
            self.publish_events(vec![(EventClass::Lossless, None, payload)]);
        }
        result
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
        let result = self.with_state(|state| {
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
        });
        if result.is_ok() {
            let payload = super::wire::encode_root_unloaded(&super::wire::RootLifecycleEvent {
                root_id,
                root_lifetime_id: *root_lifetime_id.as_bytes(),
            });
            self.publish_events(vec![(EventClass::Lossless, None, payload)]);
        }
        result
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
        // Best-effort per `publish_events`'s doc comment, and in this specific case usually a
        // guaranteed no-op through the hub: the real call sequence for a process-wide identity
        // swap is `SubscriptionHub::replace_identity` (which clears every queue and rejects
        // publishes against the old identity) alongside this method, so by the time this fires
        // the hub has typically already moved on -- `SubscriptionHub::publish(&self.identity, ..)`
        // returns `StaleRuntimeIdentity` and the failure counter absorbs it. Still emitted,
        // scope-wide (`root_id: None`), for the window before that swap lands.
        let payload = super::wire::encode_resnapshot_required(&super::wire::ResnapshotRequiredEvent {
            root_id: None,
            reason: super::wire::ResnapshotReason::IdentityChanged,
        });
        self.publish_events(vec![(EventClass::Lossless, None, payload)]);
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
            NeedsRebuild {
                base_generation: Option<u64>,
                reason: RootCatalogShardFallbackReason,
            },
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
                    reason,
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
                        reason,
                    }
                }
            }
        });

        match phase1 {
            Phase1::Done(receipt) => {
                if matches!(receipt.outcome, InventoryApplyOutcome::Patched) {
                    let events = self.delta_success_events(
                        command.root_id,
                        command.root_lifetime_id,
                        &receipt,
                        &command.event,
                    );
                    self.publish_events(events);
                }
                receipt
            }
            Phase1::NeedsRebuild { base_generation, reason } => {
                self.publish_events(vec![Self::shard_fallback_event(command.root_id, reason)]);
                let receipt = self.rebuild_and_install(command.root_id, base_generation);
                if matches!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative) {
                    let events = self.delta_success_events(
                        command.root_id,
                        command.root_lifetime_id,
                        &receipt,
                        &command.event,
                    );
                    self.publish_events(events);
                }
                receipt
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

    /// Discovery-path counterpart to [`Self::apply_delta`] (§4.1.1): `command.event`'s upserts
    /// carry no caller-supplied id -- this mints one for each via [`Self::mint_file_id`]/
    /// [`Self::mint_folder_id`], builds the equivalent fully-formed [`InventoryDeltaCommand`],
    /// and applies it through the *exact same, unchanged* [`Self::apply_delta`] the id-supplied
    /// path uses -- every gate (watermark, generation, lifetime), the patch/rebuild state
    /// machine, and the published-generation bookkeeping are identical to today's tested path.
    pub fn apply_delta_discovery(
        &self,
        identity: &RuntimeIdentity,
        command: InventoryDeltaDiscoveryCommand,
    ) -> InventoryDeltaDiscoveryReceipt {
        let upserted_files: Vec<InventoryFileRecord> = command
            .event
            .upserted_files
            .into_iter()
            .map(|discovered| discovered.into_minted(self.mint_file_id()))
            .collect();
        let upserted_folders: Vec<InventoryFolderRecord> = command
            .event
            .upserted_folders
            .into_iter()
            .map(|discovered| discovered.into_minted(self.mint_folder_id()))
            .collect();
        let minted_file_ids: Vec<InventoryUuid> = upserted_files.iter().map(|file| file.id).collect();
        let minted_folder_ids: Vec<InventoryUuid> =
            upserted_folders.iter().map(|folder| folder.id).collect();
        let full_command = InventoryDeltaCommand {
            scope_id: command.scope_id,
            root_id: command.root_id,
            root_lifetime_id: command.root_lifetime_id,
            watcher_accepted_watermark: command.watcher_accepted_watermark,
            requires_full_resync: command.requires_full_resync,
            expected_applied_index_generation: command.expected_applied_index_generation,
            source: command.source,
            event: crate::inventory::InventoryAppliedIndexBatchEvent {
                root_id: command.event.root_id,
                upserted_files,
                upserted_folders,
                removed_file_ids: command.event.removed_file_ids,
                removed_folder_ids: command.event.removed_folder_ids,
                removed_file_paths: command.event.removed_file_paths,
                removed_folder_paths: command.event.removed_folder_paths,
                modified_file_ids: command.event.modified_file_ids,
                modified_folder_ids: command.event.modified_folder_ids,
            },
        };
        InventoryDeltaDiscoveryReceipt {
            receipt: self.apply_delta(identity, full_command),
            minted_file_ids,
            minted_folder_ids,
        }
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

    /// Mints a fresh RFC4122-v4-shaped file record id from this scope's dedicated
    /// `record_minter` stream (§4.1.1's discovery mint site -- never `lifetime_minter`'s).
    #[must_use]
    pub fn mint_file_id(&self) -> InventoryUuid {
        self.record_minter.next_v4_bytes()
    }

    /// See [`Self::mint_file_id`]: identical stream, for folder record identity.
    #[must_use]
    pub fn mint_folder_id(&self) -> InventoryUuid {
        self.record_minter.next_v4_bytes()
    }

    /// Discovery-path counterpart to [`Self::push_bulk_chunk`] (§4.1.1): `discovered_files`/
    /// `discovered_folders` carry no caller-supplied `id` -- this mints one for each via
    /// [`Self::mint_file_id`]/[`Self::mint_folder_id`], then stages the now-fully-formed records
    /// through the *exact same, unchanged* [`Self::push_bulk_chunk`] the id-supplied path uses.
    /// The receipt echoes the minted ids **in the same order as the input vectors** so the caller
    /// (which knows the discovered paths in that same order but not yet their ids) can zip them
    /// back together.
    pub fn push_bulk_chunk_discovery(
        &self,
        identity: &RuntimeIdentity,
        bulk_load_id: BulkLoadId,
        root_id: RootId,
        discovered_files: Vec<DiscoveredFileRecord>,
        discovered_folders: Vec<DiscoveredFolderRecord>,
    ) -> Result<BulkChunkDiscoveryReceipt, BulkLoadError> {
        let files: Vec<InventoryFileRecord> = discovered_files
            .into_iter()
            .map(|discovered| discovered.into_minted(self.mint_file_id()))
            .collect();
        let folders: Vec<InventoryFolderRecord> = discovered_folders
            .into_iter()
            .map(|discovered| discovered.into_minted(self.mint_folder_id()))
            .collect();
        let minted_file_ids: Vec<InventoryUuid> = files.iter().map(|file| file.id).collect();
        let minted_folder_ids: Vec<InventoryUuid> = folders.iter().map(|folder| folder.id).collect();
        self.push_bulk_chunk(identity, bulk_load_id, root_id, files, folders)?;
        Ok(BulkChunkDiscoveryReceipt {
            minted_file_ids,
            minted_folder_ids,
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
        let result = self.with_state(|state| {
            let (root_id, root_lifetime, staging) =
                state.bulk_loads.take_for_commit(bulk_load_id)?;
            let Some(root) = state.roots.get_mut(&root_id) else {
                return Err(BulkLoadError::RootMismatch);
            };
            if root.root_lifetime != root_lifetime {
                return Err(BulkLoadError::RootMismatch);
            }
            let upserted_count = (staging.files.len() + staging.folders.len()) as u64;
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
            Ok((
                InventoryGenerationReceipt {
                    root_id,
                    generation: published.generation,
                    token: published.token,
                },
                upserted_count,
            ))
        });
        match result {
            Ok((receipt, upserted_count)) => {
                // A bulk-load commit is a full replacement, not a delta: no `InventoryDeltaCommand`
                // exists to carry `inventoryAppliedIndexBatch` payload content, so only
                // `inventoryGenerationAdvanced` is emitted here (contract doc §5b's "generations +
                // change summary counts" -- removed/modified are meaningless for a wholesale
                // replacement, so both are 0; `upserted_count` covers every staged record).
                let payload = super::wire::encode_generation_advanced(&super::wire::GenerationAdvancedEvent {
                    root_id: receipt.root_id,
                    root_lifetime_id: *receipt.token.root_lifetime().as_bytes(),
                    applied_index_generation: receipt.generation,
                    catalog_generation: Some(receipt.generation),
                    rebuilt_authoritative: true,
                    upserted_count,
                    removed_count: 0,
                    modified_count: 0,
                });
                self.publish_events(vec![(
                    EventClass::Coalescible,
                    Some(root_coalesce_key("genAdvanced", receipt.root_id)),
                    payload,
                )]);
                Ok(receipt)
            }
            Err(error) => Err(error),
        }
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
    /// 2, verbatim). Both `files` and `folders` are paged by the same `offset`/`limit` window
    /// independently (not a combined/interleaved cursor) -- a caller that wants every record for
    /// the root pages each list to exhaustion the way
    /// `WorkspaceInventoryScopeShadowForwarder.snapshotAllRecords` (Swift bridge,
    /// `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Inventory/
    /// WorkspaceInventoryScopeShadowForwarder.swift`) does.
    #[must_use]
    pub fn snapshot_page(
        &self,
        handle_id: SnapshotHandleId,
        offset: usize,
        limit: usize,
    ) -> Result<SnapshotPage, InvalidationReason> {
        match self.with_state(|state| state.handles.read(handle_id)) {
            HandleReadOutcome::Open { generation } => Ok(SnapshotPage {
                files: generation.files.iter().skip(offset).take(limit).cloned().collect(),
                folders: generation.folders.iter().skip(offset).take(limit).cloned().collect(),
            }),
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

    // --------------------------------------------------------------------- event plane (P4-4b)
    //
    // **Lock-ordering rule (binding, not a style note): `SubscriptionHub`'s lock is always
    // innermost. `InventoryScope` never calls into `SubscriptionHub` while holding
    // `self.state`'s guard.** The two locks have a fixed total order because
    // `SubscriptionHub::open_subscription` runs its snapshot-provider closure *while holding
    // the hub's own lock* (see that method's doc comment) -- if this scope's snapshot were ever
    // read from inside that provider, or if a mutation method here called `hub.publish()` from
    // inside `with_state`, a concurrent thread doing the other order would deadlock (hub-lock ->
    // scope-lock on one thread, scope-lock -> hub-lock on the other: classic ABBA). Two
    // consequences, both load-bearing:
    //   1. Every mutation method below runs entirely inside `with_state`, computing whatever
    //      event payload data it needs from values already produced under the lock (the
    //      mutation's own return value, or a local the closure already had in hand); lets
    //      `with_state` return, dropping the guard; and only then calls `publish_events`, the
    //      sole call site that reaches `SubscriptionHub`.
    //   2. `InventoryScope` never opens a subscription itself and never supplies a
    //      scope-state-reading snapshot provider to `SubscriptionHub::open_subscription` -- the
    //      FFI layer opens inventory subscriptions with an empty initial snapshot (`Vec::new`),
    //      matching how every other P0 consumer of the generic subscription surface already
    //      does it (`rust/crates/ffi/src/api.rs`'s `open_subscription`). Resnapshot recovery
    //      (contract doc §5b) is a separate, ordinary `inventoryOpenSnapshot` call, never a read
    //      folded into subscription bootstrap.
    // `inventory_scope_event_lock_ordering.rs` proves rule 1 empirically: it parks a publish call
    // on a test barrier (mirroring `rebuild_test_barrier`/`parked_on_rebuild_barrier` below) and
    // asserts a concurrent `with_state`-guarded reader completes within a bounded timeout while
    // the publisher is parked -- a violation that moved the publish call inside `with_state`
    // would make that reader block for the barrier's full duration instead, failing the test.

    /// Publishes a batch of already-encoded events, each tagged with its `EventClass` and
    /// optional coalesce key. Called only after the mutation that produced them has already
    /// released `self.state`'s guard -- see this section's lock-ordering rule. Best-effort:
    /// `SubscriptionHub::publish` can fail (wake-pipe I/O error, a lossless event too large even
    /// after evicting every droppable/coalescible entry), and the mutation that triggered this
    /// batch has already committed under its own lock by the time this runs, so a publish
    /// failure is recorded (`publish_failure_count`) and swallowed, never surfaced as a mutation
    /// error to the caller who already received a successful receipt.
    fn publish_events(&self, events: Vec<(EventClass, Option<String>, Vec<u8>)>) {
        if events.is_empty() {
            return;
        }
        // Self-enforcing complement to the barrier-based proof (`testing_try_lock_state`'s doc
        // comment): a debug-only, always-on tripwire for a future refactor that moves a
        // `publish_events` call inside `with_state` by mistake.
        debug_assert!(
            self.testing_try_lock_state(),
            "publish_events called while `self.state` is still locked -- see the event-plane \
             section's lock-ordering rule"
        );
        let sink = self
            .event_sink
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        let Some(sink) = sink else {
            return; // no sink attached (cargo-only construction, or FFI never called attach_event_sink)
        };

        if let Some(barrier) = self
            .publish_test_barrier
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
        {
            self.parked_on_publish_barrier.store(true, Ordering::SeqCst);
            barrier.wait();
            self.parked_on_publish_barrier.store(false, Ordering::SeqCst);
        }

        for (class, coalesce_key, payload) in events {
            let input = EventInput {
                kind: RuntimeEventKind::Data,
                class,
                payload,
                coalesce_key,
            };
            if sink.hub.publish(&self.identity, &sink.scope_id, input).is_err() {
                self.publish_failure_count.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    /// `inventoryGenerationAdvanced` + `inventoryAppliedIndexBatch` (contract doc §5b), emitted
    /// together for every non-rejected `apply_delta`/`commit_bulk_load` outcome. **Flagged
    /// interpretation:** the contract table gives both events the same coalesce-key shape
    /// ("scope:root"); read literally as byte-identical keys, publishing both for the same root
    /// back-to-back would coalesce the first into the second inside the hub's queue, silently
    /// dropping the generation-advanced notification. This scope instead namespaces the key per
    /// event kind (`genAdvanced:<root>` / `appliedIndexBatch:<root>`) so each kind coalesces
    /// independently against its own prior entry for the same root -- "scope:root" read as the
    /// key's *shape* (bounded per scope+root), not a literal cross-kind collision.
    fn delta_success_events(
        &self,
        root_id: RootId,
        root_lifetime_id: RootLifetimeId,
        receipt: &InventoryDeltaReceipt,
        event: &crate::inventory::InventoryAppliedIndexBatchEvent,
    ) -> Vec<(EventClass, Option<String>, Vec<u8>)> {
        let rebuilt_authoritative = matches!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative);
        let generation_advanced = super::wire::encode_generation_advanced(&super::wire::GenerationAdvancedEvent {
            root_id,
            root_lifetime_id: *root_lifetime_id.as_bytes(),
            applied_index_generation: receipt.applied_index_generation,
            catalog_generation: receipt.catalog_generation,
            rebuilt_authoritative,
            upserted_count: (event.upserted_files.len() + event.upserted_folders.len()) as u64,
            removed_count: (event.removed_file_ids.len()
                + event.removed_folder_ids.len()
                + event.removed_file_paths.len()
                + event.removed_folder_paths.len()) as u64,
            modified_count: (event.modified_file_ids.len() + event.modified_folder_ids.len()) as u64,
        });
        let applied_index_batch = super::wire::encode_delta_event(event);
        vec![
            (
                EventClass::Coalescible,
                Some(root_coalesce_key("genAdvanced", root_id)),
                generation_advanced,
            ),
            (
                EventClass::Coalescible,
                Some(root_coalesce_key("appliedIndexBatch", root_id)),
                applied_index_batch,
            ),
        ]
    }

    /// `inventoryShardFallback` (Droppable, diagnostic-only per contract doc §5b).
    fn shard_fallback_event(
        root_id: RootId,
        reason: RootCatalogShardFallbackReason,
    ) -> (EventClass, Option<String>, Vec<u8>) {
        let payload = super::wire::encode_shard_fallback(&super::wire::ShardFallbackEvent { root_id, reason });
        let reason_tag = RootCatalogShardFallbackReason::ALL
            .iter()
            .position(|candidate| *candidate == reason)
            .unwrap_or(usize::MAX);
        (
            EventClass::Droppable,
            Some(format!("fallback:{}:{reason_tag}", hex16(&root_id))),
            payload,
        )
    }

    // ------------------------------------------------------------------- P4-4 read/query surface

    /// `inventoryResolveRecords` (contract doc §5.3): batch, binding-validated point lookup by
    /// id, against the scope's *live* identity maps (this is deliberate, not a handle-pinned
    /// read: B1/B3's real callers need current-state truth, e.g. discoverability at the moment
    /// of a codemap binding check, the same way `appliedIndexRecordLookup` reads the live maps
    /// today). `expected_catalog_generation` is the contract's optional staleness guard: a
    /// mismatch against the root's current generation returns a whole-block stale outcome
    /// (`generation: None`) rather than computing per-row facts against a generation the caller
    /// didn't ask for.
    pub fn resolve_records(
        &self,
        identity: &RuntimeIdentity,
        root_id: RootId,
        expected_catalog_generation: Option<u64>,
        file_ids: &[crate::inventory::InventoryUuid],
        folder_ids: &[crate::inventory::InventoryUuid],
    ) -> Result<(Option<u64>, RootLifetimeId, Vec<super::wire::FactRow>), ScopeError> {
        if identity != &self.identity {
            return Err(ScopeError::IdentityMismatch);
        }
        self.with_state(|state| {
            if state.closed {
                return Err(ScopeError::ScopeClosed);
            }
            let root = state.roots.get(&root_id).ok_or(ScopeError::UnknownRoot)?;
            let generation = root.published.as_ref().map(|generation| generation.generation);
            if let Some(expected) = expected_catalog_generation {
                if Some(expected) != generation {
                    return Ok((None, root.root_lifetime, Vec::new()));
                }
            }
            Ok((
                generation,
                root.root_lifetime,
                super::resolve::resolve_by_ids(root, file_ids, folder_ids),
            ))
        })
    }

    /// `inventoryLookupPaths`: the identical fact shape, keyed by path, against the same live
    /// identity maps as `resolve_records` (see that method's doc comment). Handle-based per
    /// contract doc §5.3's read-plane listing: the `SnapshotHandleId` selects which root's live
    /// maps to read and is validated (an invalidated handle is a typed business outcome, not
    /// silently ignored), but does not pin the read to that handle's captured generation.
    pub fn lookup_paths(
        &self,
        identity: &RuntimeIdentity,
        handle_id: SnapshotHandleId,
        paths: &[String],
    ) -> Result<super::resolve::LookupPathsOutcome, ScopeError> {
        if identity != &self.identity {
            return Err(ScopeError::IdentityMismatch);
        }
        self.with_state(|state| match state.handles.read(handle_id) {
            HandleReadOutcome::HandleInvalidated { reason } => {
                Ok(super::resolve::LookupPathsOutcome::HandleInvalidated { reason })
            }
            HandleReadOutcome::Open { generation } => {
                let root_id = generation.root_id;
                let Some(root) = state.roots.get(&root_id) else {
                    return Ok(super::resolve::LookupPathsOutcome::HandleInvalidated {
                        reason: InvalidationReason::RootClosed,
                    });
                };
                let live_generation = root.published.as_ref().map(|generation| generation.generation);
                Ok(super::resolve::LookupPathsOutcome::Facts {
                    generation: live_generation,
                    root_lifetime: root.root_lifetime,
                    rows: super::resolve::lookup_by_paths(root, paths),
                })
            }
        })
    }

    /// `inventoryQuery` (contract doc §5.3/§6): filtered/ranked query against the generation a
    /// `SnapshotHandleId` was opened over, per the requested haystack variant and per-root
    /// display prefix.
    pub fn query(
        &self,
        identity: &RuntimeIdentity,
        handle_id: SnapshotHandleId,
        request: super::query::InventoryQueryRequest,
    ) -> Result<super::query::QueryReadOutcome, ScopeError> {
        if identity != &self.identity {
            return Err(ScopeError::IdentityMismatch);
        }
        self.with_state(|state| match state.handles.read(handle_id) {
            HandleReadOutcome::HandleInvalidated { reason } => {
                Ok(super::query::QueryReadOutcome::HandleInvalidated { reason })
            }
            HandleReadOutcome::Open { generation } => Ok(super::query::QueryReadOutcome::Open(
                super::query::run_query(&generation, &request),
            )),
        })
    }

    /// `inventoryOpenProjectedShard` (B2): builds the codemap graph-index catalog shard
    /// authority-side under the scope's configured `codemap_capable_extensions` (contract doc
    /// §6: this policy is passed in at `inventoryOpenScope`, not per-call) and opens a snapshot
    /// handle over it, paged the same way as any other snapshot (`inventorySnapshotPage`).
    pub fn open_projected_shard(
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
            let root = state.roots.get_mut(&root_id).ok_or(ScopeError::UnknownRoot)?;
            let synthetic_generation = root.mint_projected_shard_generation();
            let shard = super::resolve::build_projected_shard(
                root,
                &self.config.codemap_capable_extensions,
                synthetic_generation,
            )
            .ok_or(ScopeError::NoPublishedGeneration)?;
            Ok(state.handles.open_handle(root_id, shard, origin_tag))
        })
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

    /// Installs a one-shot barrier the next `publish_events` call waits on, mirroring
    /// `testing_install_rebuild_barrier` exactly -- see the event-plane section's lock-ordering
    /// rule doc comment and `inventory_scope_event_lock_ordering.rs` for what this proves.
    pub fn testing_install_publish_barrier(&self, barrier: Arc<Barrier>) {
        *self
            .publish_test_barrier
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(barrier);
    }

    /// True while a mutation is parked inside `publish_events` on a
    /// `testing_install_publish_barrier`-installed barrier, with `self.state`'s guard already
    /// released (by construction: `publish_events` is only ever called after `with_state`
    /// returns). Mirrors `testing_is_parked_on_rebuild_barrier` exactly.
    #[must_use]
    pub fn testing_is_parked_on_publish_barrier(&self) -> bool {
        self.parked_on_publish_barrier.load(Ordering::SeqCst)
    }

    /// Non-blocking attempt to acquire `self.state`'s lock, immediately releasing it on success.
    /// A cheap, always-available complement to the barrier-based proof above: if a future
    /// refactor ever moved a `publish_events` call inside `with_state`, this would return
    /// `false` at the moment the (misplaced) publish ran, rather than only failing when a test
    /// happens to race a concurrent reader against it.
    #[must_use]
    pub fn testing_try_lock_state(&self) -> bool {
        self.state.try_lock().is_ok()
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

fn hex16(bytes: &crate::inventory::InventoryUuid) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn root_coalesce_key(prefix: &str, root_id: RootId) -> String {
    format!("{prefix}:{}", hex16(&root_id))
}
