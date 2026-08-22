//! `InventoryDeltaCommand` / `InventoryDeltaReceipt`: the cargo-level (pre-wire-codec) shape of
//! §5.1's `InventoryDeltaCommandV1` / `InventoryDeltaReceiptV1`.
//!
//! **Flagged simplification:** at P4-3a there is no `inventory-scope-v1` wire codec yet (P4-4's
//! job), so `InventoryDeltaCommand.event` carries the typed `InventoryAppliedIndexBatchEvent`
//! directly rather than "a compact `inventory-scope-v1` delta blob of path-keyed operations" --
//! same information, no bytes. `source` is carried as an opaque label for forward
//! compatibility/diagnostics only; no P4-3a logic branches on it (the contract does not say any
//! should).

use super::fallback::InventoryApplyOutcome;
use super::ids::{InventoryScopeId, RootId, RootLifetimeId};
use crate::inventory::InventoryAppliedIndexBatchEvent;

#[derive(Clone, Debug)]
pub struct InventoryDeltaCommand {
    pub scope_id: InventoryScopeId,
    pub root_id: RootId,
    pub root_lifetime_id: RootLifetimeId,
    pub watcher_accepted_watermark: Option<u64>,
    pub requires_full_resync: bool,
    /// See `fallback::InventoryRejectionReason::GenerationGap`'s doc comment: the flagged minimal
    /// interpretation of the contract's `generationGap` reason.
    pub expected_applied_index_generation: Option<u64>,
    pub source: String,
    pub event: InventoryAppliedIndexBatchEvent,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InventoryDeltaReceipt {
    pub applied_index_generation: u64,
    pub catalog_generation: Option<u64>,
    pub outcome: InventoryApplyOutcome,
}
