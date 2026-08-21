//! P3-2 port of the workspace inventory catalog builders
//! (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Inventory/`).

mod builders;
mod compact;
mod contract;
mod ordering;

pub use builders::{
    InventoryAppliedIndexBatchEvent, InventoryCatalogComponents, InventoryCatalogShardPatch,
    InventoryError, InventoryFileRecord, InventoryFolderRecord, InventoryRootRecord,
    InventorySearchCatalogEntry, InventoryUuid, build_authoritative_catalog_components,
    build_pending_catalog_components, build_root_catalog_shard_patch,
    merge_root_catalog_shard_file_entry_lists, standardized_relative_path,
};
pub use compact::{
    InventoryComputeError, InventoryComputeRequestV1, InventoryComputeResultV1,
    InventoryComputeService, InventoryTableRange,
};
pub use contract::{
    ENTRY_STRIDE, INVENTORY_CONTRACT_VERSION_V1, InventoryOperation, InventoryShardPatchOutcomeTag,
    OPTIONAL_WORD, RECORD_STRIDE, ROOT_STRIDE, SHARD_STRIDE, STRING_RANGE_STRIDE, UUID_STRIDE,
};
pub use ordering::{
    compare_utf8_binary, entry_order, file_full_path_order, file_relative_path_order, folder_order,
    search_catalog_entry_precedes, search_catalog_file_precedes, search_catalog_folder_precedes,
    search_root_catalog_file_precedes,
};
