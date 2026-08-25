//! `crate::inventory_scope`'s state machine reuses `build_authoritative_catalog_components` /
//! `build_root_catalog_shard_patch` and the whole of `ordering` verbatim for the stateful
//! `InventoryScope` (P4). The former stateless whole-table `inventory-compute-v1` wire codec
//! (`compact`/`contract`) retired at P4-8: it is superseded by `inventory_scope::wire`'s own
//! interning codec, and its Swift-side FFI seam (`RustInventoryComputer`,
//! `CoreComputeClient.inventoryBuild*`) was deleted in the same step. `WorkspaceInventoryCatalogBuilders`
//! (the historical Swift reference implementation these builders port) is being retired at P4-8.
//! The stateful scope reuses the borrowed multi-root merge directly during P4-8e composition; the
//! remaining historical builder arms stay Rust-side as frozen behavior/benchmark evidence.

mod builders;
mod ordering;

pub use builders::{
    InventoryAppliedIndexBatchEvent, InventoryCatalogComponents, InventoryCatalogShardPatch,
    InventoryError, InventoryFileRecord, InventoryFolderRecord, InventoryRootRecord,
    InventorySearchCatalogEntry, InventoryUuid, build_authoritative_catalog_components,
    build_pending_catalog_components, build_root_catalog_shard_patch,
    merge_root_catalog_shard_file_entry_lists, merge_root_catalog_shard_file_entry_slices,
    standardized_relative_path,
};
pub use ordering::{
    compare_utf8_binary, entry_order, file_full_path_order, file_relative_path_order, folder_order,
    search_catalog_entry_precedes, search_catalog_file_precedes, search_catalog_folder_precedes,
    search_root_catalog_file_precedes,
};
