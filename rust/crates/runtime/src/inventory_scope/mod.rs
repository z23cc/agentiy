//! P4-3a: the Rust stateful inventory scope (cargo-only, zero FFI dependency).
//!
//! Implements the `ScopeRegistry` + `InventoryScope` primitives frozen by
//! `docs/architecture/rust-inventory-scope-v1.md` (the P4-1 contract) and scoped by
//! `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §11's P4-3a entry: identity
//! maps, path resolution, UUID minting with a test seed, the discoverability filter, per-root
//! generations and lifetime fencing, sorted shard tables (reusing `inventory::ordering` /
//! `inventory::builders` verbatim), the patch/rebuild state machine covering all eight
//! `RootCatalogShardFallbackReason` cases, the live-generation cap and backstop, snapshot handles
//! with generation tokens, bulk-load staging with atomic commit, `InventoryDiagnosticsV1`, and the
//! §5.2.1 locking model with longest-critical-section instrumentation.
//!
//! **Explicitly out of scope for this step** (owned by later steps, not this one -- see the
//! design's migration-order DAG, §11): the `inventory-scope-v1` wire codec, the FFI/bridge
//! surface, `inventoryQuery`/`inventoryOpenProjectedShard`/`inventoryResolveRecords`, event-plane
//! publication into `SubscriptionHub`, and the index/path-search orchestration (P4-3b). Zero FFI
//! dependency: this module imports nothing from `uniffi` or the `ffi` crate, and `lib.rs` adds
//! only its module line.
//!
//! Module map:
//! - `ids`: explicit typed identifiers + the UUID minter (production + seeded-for-test modes).
//! - `fallback`: the eight `RootCatalogShardFallbackReason` cases and `InventoryRejectionReason`.
//! - `ingress_gate`: the `staleWatermark` gate and the flagged `generationGap` check.
//! - `identity_maps`: per-root file/folder identity maps, the discoverability filter, and the two
//!   O(1) maintained discoverable-count aggregates (§4.3.1.2, D-12).
//! - `generation`: `RootGeneration`, the immutable `Arc`-retained published per-root artifact.
//! - `handles`: the snapshot handle table (open/close/invalidate, DEBUG leak observability).
//! - `bulk_load`: `BulkLoadId` staging with abort-vs-commit terminal-state semantics.
//! - `state_machine`: `RootState` (generation/publish bookkeeping, diagnostics counters) and the
//!   pure patch-attempt / rebuild functions the scope orchestrates around its lock boundaries.
//! - `delta`: `InventoryDeltaCommand` / `InventoryDeltaReceipt`.
//! - `diagnostics`: `InventoryDiagnosticsV1` and its field-for-field Swift parity mapping.
//! - `scope`: `InventoryScope`, the `Mutex<ScopeState>`-owning orchestrator and its public API.
//! - `registry`: `ScopeRegistry`, the ID-addressed holder of `InventoryScope` instances.

// §5.2.1 freezes the closure spelling `.unwrap_or_else(|poisoned| poisoned.into_inner())` for
// every `.lock()` site in this module (enforced by `tests/inventory_scope_lock_idiom.rs`), which
// conflicts with clippy pedantic's `redundant_closure_for_method_calls` (it would rather see the
// equivalent function-reference spelling `std::sync::PoisonError::into_inner`, already used
// elsewhere in this crate at `search/cache.rs:49,:71`). The contract's explicit, testable
// requirement wins; this allow is scoped to this module only.
#![allow(clippy::redundant_closure_for_method_calls)]

pub mod bulk_load;
pub mod delta;
pub mod diagnostics;
pub mod fallback;
pub mod generation;
pub mod handles;
pub mod identity_maps;
pub mod ids;
pub mod ingress_gate;
pub mod registry;
pub mod scope;
pub mod state_machine;

pub use bulk_load::{BulkLoadError, BulkLoadStaging, BulkLoadTable};
pub use delta::{InventoryDeltaCommand, InventoryDeltaReceipt};
pub use diagnostics::{HandleDiagnostics, InventoryDiagnosticsV1, RootDiagnostics};
pub use fallback::{
    InventoryApplyOutcome, InventoryRejectionReason, RootCatalogShardFallbackReason,
};
pub use generation::RootGeneration;
pub use handles::{HandleReadOutcome, HandleTable, InvalidationReason};
pub use identity_maps::IdentityMaps;
pub use ids::{
    BulkLoadId, GenerationToken, InventoryScopeId, RootId, RootLifetimeId, SnapshotHandleId,
    UuidMinter,
};
pub use registry::{ScopeRegistry, ScopeRegistryError};
pub use scope::{
    InventoryGenerationReceipt, InventoryPublishMode, InventoryScope, InventoryScopeConfig,
    RootUnloadReceipt, ScopeError,
};
pub use state_machine::{RootCounters, RootState};
