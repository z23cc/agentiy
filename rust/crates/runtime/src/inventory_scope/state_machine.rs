//! `RootState`: one root's identity maps, generation/publish bookkeeping, ingress gate, and
//! diagnostics counters, plus the pure patch/rebuild decision functions the scope's `apply_delta`
//! orchestrates around its own lock-acquire/release boundaries (§2's discipline: the *decision*
//! and the *cheap* map mutation happen under the lock; the *expensive* rebuild sort/filter is
//! computed by `rebuild_generation` outside it -- see `scope.rs`).
//!
//! **`requires_full_resync` handling, flagged:** the contract names this flag and its fallback
//! fate ("Preserved -- driven by `requiresFullResync`") without specifying a distinct wire shape
//! for "replace everything" versus a normal delta at P4-3a (no wire codec exists yet; P4-4 owns
//! it). This module's minimal choice: a full-resync command's event content is applied to the
//! identity maps exactly like a steady-state delta (upserts/removals as given), then the root is
//! unconditionally rebuilt from the resulting maps rather than patched. A caller that needs to
//! represent "the whole root changed" expresses it as a full complement of upserts plus explicit
//! removals for anything gone -- the same shape `build_authoritative_catalog_components` already
//! consumes.

use std::collections::HashMap;
use std::sync::Arc;

use crate::inventory::{
    self as builders, InventoryAppliedIndexBatchEvent, InventoryCatalogShardPatch, InventoryError,
    InventoryFileRecord, InventoryFolderRecord, InventoryRootRecord, InventorySearchCatalogEntry,
    InventoryUuid,
};

use super::fallback::RootCatalogShardFallbackReason;
use super::generation::RootGeneration;
use super::identity_maps::IdentityMaps;
use super::ids::{GenerationToken, RootId, RootLifetimeId};
use super::ingress_gate::IngressGateState;
use super::path_index::{BuildKind, RootPathIndex};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RootCounters {
    pub build_count: u64,
    pub patch_count: u64,
    pub authoritative_rebuild_count: u64,
    pub fallback_count: u64,
    pub fallback_reason_counts: HashMap<RootCatalogShardFallbackReason, u64>,
    pub backstop_count: u64,
    pub delta_state_dirty: bool,
    pub published_topology_generation: Option<u64>,
    /// Present in the live Swift struct (`RootCatalogShardGenerationDebugSnapshot.swift:245`) --
    /// see `diagnostics.rs`'s module doc comment for why it is carried despite §5c's prose table
    /// omitting it. The observed maximum of (published ? 1 : 0) + retained-generation count.
    pub max_live_generation_count: u64,
    /// P4-3b: incremented on every `.full`-build-kind publish, mirroring
    /// `rootCatalogShardFullPathIndexBuildCountsByRootID` (`WorkspaceFileContextStore.swift:7608-7610`).
    pub path_index_build_count: u64,
    /// P4-3b: incremented on every `.overlay`- or `.projectedReuse`-build-kind publish, mirroring
    /// `rootCatalogShardOverlayPathIndexBuildCountsByRootID` (`:7611-7614`; both kinds share one
    /// counter in the Swift source -- `.reused` increments neither, per `:7615-7616`).
    pub overlay_path_index_build_count: u64,
}

impl RootCounters {
    pub fn new() -> Self {
        Self {
            fallback_reason_counts: super::fallback::zeroed_fallback_reason_counts(),
            ..Default::default()
        }
    }

    pub fn record_fallback(&mut self, reason: RootCatalogShardFallbackReason) {
        self.fallback_count += 1;
        *self.fallback_reason_counts.entry(reason).or_insert(0) += 1;
    }
}

pub struct RootState {
    pub root_id: RootId,
    pub name: String,
    pub standardized_full_path: String,
    pub root_lifetime: RootLifetimeId,
    pub maps: IdentityMaps,
    pub published: Option<Arc<RootGeneration>>,
    next_generation: u64,
    pub ingress_gate: IngressGateState,
    pub last_applied_index_generation: u64,
    pub counters: RootCounters,
    pub live_generation_cap: usize,
    /// Generation numbers superseded by a newer publish but still referenced by at least one
    /// open snapshot handle, mapped to that reference count. Populated/decremented by the scope
    /// as handles open/close (`note_handle_opened_for_generation` / `_closed_`).
    pub retained_generation_refcounts: HashMap<u64, usize>,
    /// P4-4: mints out-of-band generation numbers for `inventoryOpenProjectedShard`'s derived,
    /// non-authoritative `RootGeneration` artifacts (`resolve::build_projected_shard`). Counts
    /// DOWN from `u64::MAX` so a projected shard's synthetic generation number can never collide
    /// with a real published generation (`next_generation` counts up from 0) -- if it did, a
    /// projected-shard handle would be indistinguishable from a real snapshot handle to
    /// `HandleTable::refcount_for_generation`'s (root_id, generation_number) lookup, corrupting
    /// the live-generation-cap accounting in `publish`/`note_handle_closed_for_generation`.
    pub projected_shard_mint_counter: u64,
}

impl RootState {
    #[must_use]
    pub fn new(
        root_id: RootId,
        name: String,
        standardized_full_path: String,
        root_lifetime: RootLifetimeId,
        live_generation_cap: usize,
    ) -> Self {
        Self {
            root_id,
            name,
            standardized_full_path,
            root_lifetime,
            maps: IdentityMaps::default(),
            published: None,
            next_generation: 0,
            ingress_gate: IngressGateState::new(),
            last_applied_index_generation: 0,
            counters: RootCounters::new(),
            live_generation_cap,
            retained_generation_refcounts: HashMap::new(),
            projected_shard_mint_counter: 0,
        }
    }

    /// Mints the next out-of-band generation number for a projected shard (see the field doc
    /// comment above). Infallible in practice: exhausting `u64::MAX` projected-shard opens for a
    /// single root within one process lifetime is not a real scenario.
    pub fn mint_projected_shard_generation(&mut self) -> u64 {
        let value = u64::MAX - self.projected_shard_mint_counter;
        self.projected_shard_mint_counter += 1;
        value
    }

    #[must_use]
    pub fn root_record(&self) -> InventoryRootRecord {
        InventoryRootRecord {
            id: self.root_id,
            name: self.name.clone(),
            standardized_full_path: self.standardized_full_path.clone(),
        }
    }

    /// §4 layer 2, four effects plus proceed: the cap check happens on every publish. If
    /// superseding the currently-published generation would leave more than `live_generation_cap`
    /// distinct generations retained by open handles, the mutation still installs the new
    /// generation, but is flagged: shard marked dirty, `RetentionBoundary` fallback recorded,
    /// `backstop_count` incremented, and the diagnostics-facing `published_topology_generation`
    /// cleared to `None` (the internal `Arc` pointer used to serve reads is unaffected -- reads
    /// always see the true latest generation regardless of this diagnostic clearing).
    pub fn publish(
        &mut self,
        mut generation: RootGeneration,
        outgoing_handle_refcount: usize,
    ) -> Arc<RootGeneration> {
        let generation_number = self.next_generation;
        self.next_generation += 1;
        generation.root_id = self.root_id;
        generation.root_lifetime = self.root_lifetime;
        generation.generation = generation_number;
        generation.token = GenerationToken::new(self.root_lifetime, generation_number);

        if let Some(outgoing) = &self.published {
            if outgoing_handle_refcount > 0 {
                self.retained_generation_refcounts
                    .insert(outgoing.generation, outgoing_handle_refcount);
            }
        }

        let live_count = self.retained_generation_refcounts.len() + 1; // +1 for the generation just published
        self.counters.max_live_generation_count = self
            .counters
            .max_live_generation_count
            .max(live_count as u64);
        let hit_cap = self.retained_generation_refcounts.len() > self.live_generation_cap;
        if hit_cap {
            self.counters.delta_state_dirty = true;
            self.counters
                .record_fallback(RootCatalogShardFallbackReason::RetentionBoundary);
            self.counters.backstop_count += 1;
            self.counters.published_topology_generation = None;
        } else {
            self.counters.delta_state_dirty = false;
            self.counters.published_topology_generation = Some(generation_number);
        }

        match generation.path_index.build_kind() {
            BuildKind::Full => self.counters.path_index_build_count += 1,
            BuildKind::Overlay | BuildKind::ProjectedReuse => {
                self.counters.overlay_path_index_build_count += 1;
            }
            BuildKind::Reused => {}
        }

        let published = Arc::new(generation);
        self.published = Some(Arc::clone(&published));
        self.counters.build_count += 1;
        published
    }

    pub fn note_handle_closed_for_generation(&mut self, generation_number: u64) {
        if let Some(count) = self
            .retained_generation_refcounts
            .get_mut(&generation_number)
        {
            *count -= 1;
            if *count == 0 {
                self.retained_generation_refcounts
                    .remove(&generation_number);
            }
        }
    }

    #[must_use]
    pub fn live_topology_generations(&self) -> Vec<u64> {
        self.published
            .as_ref()
            .map(|generation| vec![generation.generation])
            .unwrap_or_default()
    }

    #[must_use]
    pub fn retained_topology_generations(&self) -> Vec<u64> {
        let mut generations: Vec<u64> =
            self.retained_generation_refcounts.keys().copied().collect();
        generations.sort_unstable();
        generations
    }

    /// Applies an `InventoryAppliedIndexBatchEvent`'s upserts/removals to this root's identity
    /// maps. Bounded by the touched-record count in the event, never by root size -- an O(1)-ish
    /// (per touched record) critical-section-safe mutation.
    pub fn apply_event_to_maps(&mut self, event: &InventoryAppliedIndexBatchEvent) {
        for file in &event.upserted_files {
            self.maps.upsert_file(file.clone());
        }
        for folder in &event.upserted_folders {
            self.maps.upsert_folder(folder.clone());
        }
        for id in &event.removed_file_ids {
            self.maps.remove_file(*id);
        }
        for path in &event.removed_file_paths {
            let standardized = builders::standardized_relative_path(path);
            if let Some(id) = self
                .maps
                .file_id_by_relative_path
                .get(&standardized)
                .copied()
            {
                self.maps.remove_file(id);
            }
        }
        for id in &event.removed_folder_ids {
            self.maps.remove_folder(*id);
        }
        for path in &event.removed_folder_paths {
            let standardized = builders::standardized_relative_path(path);
            if let Some(id) = self
                .maps
                .folder_id_by_relative_path
                .get(&standardized)
                .copied()
            {
                self.maps.remove_folder(id);
            }
        }
        // `modified_file_ids`/`modified_folder_ids` name records whose content changed without a
        // path change; the authoritative content already lives in `files_by_id`/`folders_by_id`
        // (the caller is expected to have upserted the modified record's new content via
        // `upserted_files`/`upserted_folders` when the modification is anything the map needs to
        // reflect -- matching `build_root_catalog_shard_patch`'s own contract, which reads
        // `files_by_id`/`folders_by_id` for the modified id rather than trusting the event to
        // carry the new content directly). No map mutation happens here for modified-only ids.
    }

    /// True if any id this event touches (upserted, removed, or modified) is presently
    /// managed-only. `build_root_catalog_shard_patch` has no managed-only concept at all (P3-2
    /// scope), so a patch that touched a managed-only record would silently reintroduce it into
    /// the discoverable shard -- this scope-level pre-check vetoes that before calling the
    /// builder, falling back to an authoritative rebuild (which *does* filter managed-only via
    /// `build_authoritative_catalog_components`) instead.
    #[must_use]
    pub fn event_touches_managed_only(&self, event: &InventoryAppliedIndexBatchEvent) -> bool {
        let touches = |id: &InventoryUuid, managed: &std::collections::HashSet<InventoryUuid>| {
            managed.contains(id)
        };
        event
            .upserted_files
            .iter()
            .any(|file| touches(&file.id, &self.maps.managed_only_file_ids))
            || event
                .upserted_folders
                .iter()
                .any(|folder| touches(&folder.id, &self.maps.managed_only_folder_ids))
            || event
                .removed_file_ids
                .iter()
                .any(|id| touches(id, &self.maps.managed_only_file_ids))
            || event
                .removed_folder_ids
                .iter()
                .any(|id| touches(id, &self.maps.managed_only_folder_ids))
            || event
                .modified_file_ids
                .iter()
                .any(|id| touches(id, &self.maps.managed_only_file_ids))
            || event
                .modified_folder_ids
                .iter()
                .any(|id| touches(id, &self.maps.managed_only_folder_ids))
    }
}

pub enum PatchAttempt {
    Patched(RootGeneration),
    NeedsRebuild(RootCatalogShardFallbackReason),
}

/// Attempts a single-logical-mutation patch against the currently published generation. Must be
/// called only when `root.published` is `Some` (callers route the missing-shard case to rebuild
/// before reaching here).
pub fn attempt_patch(
    root: &RootState,
    event: &InventoryAppliedIndexBatchEvent,
    max_logical_mutation_count: usize,
) -> PatchAttempt {
    let published = root
        .published
        .as_ref()
        .expect("attempt_patch requires an existing published generation");

    let patch_result: Result<Option<InventoryCatalogShardPatch>, InventoryError> =
        builders::build_root_catalog_shard_patch(
            event,
            &published.files,
            &published.folders,
            &root.maps.files_by_id,
            &root.maps.folders_by_id,
            max_logical_mutation_count,
        );

    let patch = match patch_result {
        Err(_) => {
            return PatchAttempt::NeedsRebuild(
                RootCatalogShardFallbackReason::UnsafeOrAmbiguousBatch,
            );
        }
        Ok(None) => {
            return PatchAttempt::NeedsRebuild(
                RootCatalogShardFallbackReason::UnsafeOrAmbiguousBatch,
            );
        }
        Ok(Some(patch)) => patch,
    };

    if patch.logical_mutation_count > max_logical_mutation_count {
        return PatchAttempt::NeedsRebuild(RootCatalogShardFallbackReason::PatchThresholdExceeded);
    }

    let root_record = root.root_record();
    let entries: Vec<InventorySearchCatalogEntry> = patch
        .files
        .iter()
        .map(|file| InventorySearchCatalogEntry::new(file, &root_record))
        .collect();

    // P4-3b: the index is built from `published.path_index` (the *previous* generation's own
    // published index -- scope-internal state) plus `entries` (this generation's own, freshly
    // computed, already-in-hand output) and `patch.path_index_changed_file_ids` (the same patch
    // attempt's own output) -- never from `root.maps`/`files_by_id` or any other table. See
    // `path_index`'s module doc comment for the build-kind -> trigger table this implements.
    let path_index = Arc::new(
        published
            .path_index
            .applying_patch(&entries, &patch.path_index_changed_file_ids),
    );

    PatchAttempt::Patched(RootGeneration {
        root_id: root.root_id,
        root_lifetime: root.root_lifetime,
        generation: 0, // overwritten by `RootState::publish`
        token: GenerationToken::new(root.root_lifetime, 0), // overwritten by `publish`
        files: patch.files,
        folders: patch.folders,
        entries,
        path_index,
    })
}

/// The input snapshot a rebuild needs, cloned under the lock (bounded by root size -- see the
/// module-level doc comment in `mod.rs` for why this is the flagged, pragmatic reading of §2's
/// "expensive work happens outside the lock" for the rebuild path: the *clone* is a memcpy-shaped
/// cost; the *sort and filter* `build_authoritative_catalog_components` performs is the CPU-bound
/// cost this design moves outside the lock).
pub struct RebuildInput {
    pub root_record: InventoryRootRecord,
    pub files_by_id: HashMap<InventoryUuid, InventoryFileRecord>,
    pub folders_by_id: HashMap<InventoryUuid, InventoryFolderRecord>,
    pub managed_only_file_ids: std::collections::HashSet<InventoryUuid>,
    pub managed_only_folder_ids: std::collections::HashSet<InventoryUuid>,
    pub root_lifetime: RootLifetimeId,
}

impl RootState {
    #[must_use]
    pub fn snapshot_for_rebuild(&self) -> RebuildInput {
        RebuildInput {
            root_record: self.root_record(),
            files_by_id: self.maps.files_by_id.clone(),
            folders_by_id: self.maps.folders_by_id.clone(),
            managed_only_file_ids: self.maps.managed_only_file_ids.clone(),
            managed_only_folder_ids: self.maps.managed_only_folder_ids.clone(),
            root_lifetime: self.root_lifetime,
        }
    }
}

/// The expensive, outside-the-lock compute step: filter to discoverable records and sort into
/// relative-path order via the reused P3-2 builder, single-root branch (§4.3.1.2's discoverable
/// shard shape).
pub fn rebuild_generation(input: &RebuildInput) -> Result<RootGeneration, InventoryError> {
    let components = builders::build_authoritative_catalog_components(
        std::slice::from_ref(&input.root_record),
        &input.files_by_id,
        &input.folders_by_id,
        &input.managed_only_file_ids,
        &input.managed_only_folder_ids,
    )?;
    // P4-3b: `.full` build kind -- a fresh index over exactly this rebuild's own `entries`
    // output, no table-shaped input (see `path_index`'s module doc comment).
    let path_index = Arc::new(RootPathIndex::full(&components.entries));
    Ok(RootGeneration {
        root_id: input.root_record.id,
        root_lifetime: input.root_lifetime,
        generation: 0, // overwritten by `RootState::publish`
        token: GenerationToken::new(input.root_lifetime, 0), // overwritten by `publish`
        files: components.files,
        folders: components.folders,
        entries: components.entries,
        path_index,
    })
}
