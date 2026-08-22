//! `InventoryDiagnosticsV1`: field-for-field parity with
//! `WorkspaceFileContextStore.swift:249-261`'s `RootCatalogShardDebugSnapshot` and its per-root
//! child `RootCatalogShardGenerationDebugSnapshot` (`:230-245`), per
//! `docs/architecture/rust-inventory-scope-v1.md` §5c, plus the new per-scope fields §5c documents
//! as having no Swift-side precedent (critical-section timing, DEBUG handle leak observability).
//!
//! **Note on `maxLiveGenerationCount`:** carried below (`RootDiagnostics::max_live_generation_count`)
//! even though §5c's prose table does not list it explicitly -- it *is* present in the live Swift
//! struct (`RootCatalogShardGenerationDebugSnapshot.swift:245`) read during this step, so omitting
//! it would silently drop a field the "field-for-field parity" requirement demands. Flagged per
//! the task's "if the contract underspecifies something ... flag" instruction.
//!
//! **Note on `liveTopologyGenerations` vs `retainedTopologyGenerations`:** the contract does not
//! precisely define the split. Minimal choice made here, flagged: `live` = the currently
//! published generation for the root (at most one, since a root's steady-state publish model
//! keeps exactly one generation authoritative at a time); `retained` = older generations still
//! held alive only because an open snapshot handle references them (tracked via
//! `RootState::note_retention_boundary`'s bookkeeping, not literal `Arc` strong-count
//! introspection, which is not a stable/portable signal to report).

use std::collections::HashMap;
use std::time::Duration;

use super::fallback::RootCatalogShardFallbackReason;
use super::ids::{RootId, RootLifetimeId};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RootDiagnostics {
    pub root_id: RootId,
    pub lifetime_id: Option<RootLifetimeId>,
    pub published_topology_generation: Option<u64>,
    pub live_topology_generations: Vec<u64>,
    pub retained_topology_generations: Vec<u64>,
    pub build_count: u64,
    pub path_index_build_count: u64,
    pub overlay_path_index_build_count: u64,
    pub patch_count: u64,
    pub authoritative_rebuild_count: u64,
    pub fallback_count: u64,
    pub fallback_reason_counts: HashMap<RootCatalogShardFallbackReason, u64>,
    pub last_applied_index_generation: Option<u64>,
    pub delta_state_dirty: bool,
    pub backstop_count: u64,
    pub max_live_generation_count: u64,
}

impl RootDiagnostics {
    #[must_use]
    pub fn new(root_id: RootId) -> Self {
        Self {
            root_id,
            fallback_reason_counts: super::fallback::zeroed_fallback_reason_counts(),
            ..Default::default()
        }
    }
}

/// DEBUG-only leak-observability surface (§4 layer 4): no Swift-side precedent.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HandleDiagnostics {
    pub open_count: usize,
    pub oldest_open_age: Option<Duration>,
    pub origin_histogram: HashMap<&'static str, usize>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct InventoryDiagnosticsV1 {
    pub live_generation_cap_per_root: usize,
    pub max_patch_logical_mutation_count: usize,
    pub published_shard_count: u64,
    pub total_build_count: u64,
    pub total_backstop_count: u64,
    pub single_shard_composition_reuse_count: u64,
    pub generic_merge_element_visit_count: u64,
    pub shadow_comparison_count: u64,
    pub shadow_mismatch_count: u64,
    pub last_shadow_byte_count: u64,
    pub roots: Vec<RootDiagnostics>,
    /// *(new, §5c)* longest single critical section observed on this scope's state mutex, since
    /// scope open. See `state_machine`'s critical-section instrumentation for what is measured.
    pub longest_critical_section: Duration,
    /// *(new, §5c)* DEBUG handle leak observability.
    pub handles: HandleDiagnostics,
}
