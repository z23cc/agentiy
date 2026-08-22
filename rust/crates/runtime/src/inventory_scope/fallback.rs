//! Fallback/rejection reason catalog.
//!
//! `RootCatalogShardFallbackReason` is the byte-for-byte port of the Swift authority list at
//! `WorkspaceFileContextStore.swift:219-228` (`RootCatalogShardFallbackReason`), re-verified
//! against that source during this step. Do not add, remove, reorder, or rename cases without
//! re-checking that anchor -- `docs/architecture/rust-inventory-scope-v1.md` §5c's diagnostics
//! field map is meaningless if this enum drifts from it.

use std::collections::HashMap;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
pub enum RootCatalogShardFallbackReason {
    /// Cold-start / evicted-shard path: no published generation exists yet for the root.
    MissingReusableShard,
    /// A generation sequencing gap was detected; promoted to
    /// `InventoryRejectionReason::GenerationGap` on the delta receipt rather than silently
    /// absorbed (§5.1, §5c table).
    GenerationGap,
    /// Driven by `requires_full_resync` on the incoming delta command.
    FullResync,
    /// The patch builder returned "not patchable" (`Ok(None)`), or this scope's own managed-only
    /// pre-check vetoed a patch attempt before calling the builder (see `state_machine` module
    /// doc comment for why the builder alone cannot detect a managed-only touch).
    UnsafeOrAmbiguousBatch,
    /// The live-generation cap (`cap = 8`) was exceeded by open-handle retention pressure. Not a
    /// rejection: see `RootState::note_retention_boundary` -- the mutation proceeds.
    RetentionBoundary,
    /// `build_root_catalog_shard_patch`'s `logical_mutation_count > max_logical_mutation_count`
    /// echo-with-empty-changed-ids case (`builders.rs` `logical_mutation_count` check).
    PatchThresholdExceeded,
    /// A patch (or rebuild) was computed against a base generation that was no longer current by
    /// install time. Under this crate's single-writer contract this is not expected in normal
    /// operation (§5.2.1 rejects optimistic-versioning machinery specifically because the
    /// workload is single-writer); it exists as a defensive backstop-of-the-backstop and is
    /// exercised by a dedicated test via `InventoryScope::testing_force_stale_base_once`.
    PatchApplicationBackstop,
    /// Repurposed per D-5 (no shadow arm exists at P4-3a): triggered only by the optional,
    /// config-gated internal self-check (`InventoryScopeConfig::self_check_patches`) that
    /// compares a patch result against an authoritative rebuild of the same delta. Flagged as
    /// underspecified-at-this-step: the contract defers the real shadow arm to P4-5.
    ShadowValidationMismatch,
}

impl RootCatalogShardFallbackReason {
    pub const ALL: [Self; 8] = [
        Self::MissingReusableShard,
        Self::GenerationGap,
        Self::FullResync,
        Self::UnsafeOrAmbiguousBatch,
        Self::RetentionBoundary,
        Self::PatchThresholdExceeded,
        Self::PatchApplicationBackstop,
        Self::ShadowValidationMismatch,
    ];
}

/// A zero-initialized counter map covering all eight reasons, matching
/// `RootCatalogShardGenerationDebugSnapshot.fallbackReasonCounts` (§5c).
#[must_use]
pub fn zeroed_fallback_reason_counts() -> HashMap<RootCatalogShardFallbackReason, u64> {
    RootCatalogShardFallbackReason::ALL
        .into_iter()
        .map(|reason| (reason, 0))
        .collect()
}

/// `InventoryRejectionReason` (§5.1). A business outcome, not an error -- delivered on
/// `InventoryDeltaReceipt` alongside `InventoryApplyOutcome::Rejected`, the same modeling choice
/// already made for `InventoryShardPatchOutcomeTag::NotPatchable`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InventoryRejectionReason {
    StaleWatermark {
        expected: u64,
        actual: u64,
    },
    LifetimeMismatch,
    /// **Deviation, flagged:** the contract names this reason but does not specify what quantity
    /// it compares (§5.1's `InventoryDeltaCommandV1` field list has no explicit generation
    /// field). P4-3a's minimal choice: `InventoryDeltaCommand` carries an optional
    /// `expected_applied_index_generation`, symmetric with the receipt's own
    /// `applied_index_generation` field -- a resuming consumer asserts the generation it believes
    /// is current; a mismatch rejects rather than silently rebuilding, per §5c's "promoted"
    /// language. See `state_machine::check_generation_gap`.
    GenerationGap {
        expected: u64,
        actual: u64,
    },
    UnknownRoot,
    ScopeClosed,
    IdentityMismatch,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InventoryApplyOutcome {
    Patched,
    RebuiltAuthoritative,
    Rejected(InventoryRejectionReason),
}

impl InventoryApplyOutcome {
    #[must_use]
    pub const fn is_rejected(&self) -> bool {
        matches!(self, Self::Rejected(_))
    }
}
