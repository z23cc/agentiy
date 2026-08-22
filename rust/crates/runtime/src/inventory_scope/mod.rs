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
//! **Explicitly out of scope for P4-3a/P4-3b** (owned by P4-4, not those steps -- see the
//! design's migration-order DAG, §11): the FFI/bridge surface remains outside this module (that
//! lives in `rust/crates/ffi` and `Sources/AgentryCoreBridge`). Zero FFI dependency here still
//! holds: this module imports nothing from `uniffi` or the `ffi` crate.
//!
//! **P4-4b landed in this module** (the piece P4-4 deliberately deferred, design §11): event-plane
//! publication into `SubscriptionHub` (still same-crate, `subscription.rs` -- no new external
//! dependency). `InventoryScope::attach_event_sink`/`publish_events` (`scope.rs`'s "event plane
//! (P4-4b)" section) own the binding lock-ordering rule: this scope's mutation methods never call
//! into `SubscriptionHub` while holding `Mutex<ScopeState>`.
//!
//! **P4-3b landed in this module** (index orchestration into the scope, cargo-only): the
//! `path_index` submodule, welded onto `RootGeneration` and wired through
//! `state_machine::attempt_patch`/`rebuild_generation` per §4.1.0's co-location invariant.
//!
//! **P4-4 landed in this module** (cargo-only additions the FFI crate then exposes): the
//! `wire` submodule (the `inventory-scope-v1` codec: interning, fail-closed decode, limits) and
//! `query`/`resolve` (the `inventoryQuery` / `inventoryResolveRecords` / `inventoryLookupPaths` /
//! `inventoryOpenProjectedShard` domain logic, added as new `InventoryScope` methods in
//! `scope.rs`).
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
//! - `path_index`: P4-3b's per-root path search index orchestration, welded onto `RootGeneration`.
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
pub mod path_index;
pub mod query;
pub mod registry;
pub mod resolve;
pub mod scope;
pub mod state_machine;
pub mod wire;

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
pub use path_index::{
    BuildKind, OverlayHistoryMetrics, PathIndexCandidate, ProjectedPathIndex, RelativePathBase,
    RootPathIndex,
};
pub use query::{
    InventoryQueryCandidate, InventoryQueryRequest, InventoryQueryResult, QueryHaystackVariant,
    QueryPrefix, QueryReadOutcome,
};
pub use registry::{ScopeRegistry, ScopeRegistryError};
pub use resolve::{LookupPathsOutcome, build_projected_shard};
pub use scope::{
    BulkChunkDiscoveryReceipt, InventoryDeltaDiscoveryCommand, InventoryDeltaDiscoveryReceipt,
    InventoryGenerationReceipt, InventoryPublishMode, InventoryScope, InventoryScopeConfig,
    RootUnloadReceipt, ScopeError, SnapshotPage,
};
pub use state_machine::{RootCounters, RootState};
pub use wire::{
    DiscoveredFileRecord, DiscoveredFolderRecord, FactBlock, FactRow, GenerationAdvancedEvent,
    INVENTORY_SCOPE_CONTRACT_VERSION_V1, InventoryDiscoveryAppliedIndexBatchEvent,
    QueryCandidateRow, ResnapshotReason, ResnapshotRequiredEvent, RootLifecycleEvent,
    ShardFallbackEvent, WireError, decode_bulk_chunk, decode_delta_event,
    decode_discovery_bulk_chunk, decode_discovery_delta_event, decode_fact_block,
    decode_generation_advanced, decode_lookup_request, decode_query_request,
    decode_query_response, decode_resnapshot_required, decode_resolve_request,
    decode_root_published, decode_root_unloaded, decode_shard_fallback, encode_bulk_chunk,
    encode_delta_event, encode_discovery_bulk_chunk, encode_discovery_delta_event,
    encode_fact_block, encode_generation_advanced, encode_lookup_request, encode_query_request,
    encode_query_response, encode_resnapshot_required, encode_resolve_request,
    encode_root_published, encode_root_unloaded, encode_shard_fallback, uuid_to_words,
};
