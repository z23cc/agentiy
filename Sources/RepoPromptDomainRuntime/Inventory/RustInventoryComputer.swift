import AgentryCoreBridge
import Foundation

/// Production Rust compute seam for the P3-2 workspace inventory catalog-builder port. Follows
/// `RustApplyEditsComputer`'s shape: one injectable closure per operation, each defaulting to the
/// real `AgentryCoreService.shared.computeClient()` seam, so callers (today: only
/// `InventoryRustSwiftDifferentialTests`) can drive the Rust builders directly without an
/// intervening domain-model translation layer -- `AgentryCoreBridge`'s `CoreInventory*V1` types
/// are the whole surface; there is no separate `RepoPromptDomainRuntime`-owned mirror of them.
///
/// Not yet wired into any production caller: `WorkspaceFileContextStore` continues to call the
/// Swift `WorkspaceInventoryCatalogBuilders` reference implementation directly.
package struct RustInventoryComputer: Sendable {
    package typealias AuthoritativeCatalogOperation = @Sendable (
        _ roots: [CoreInventoryRootRecordV1],
        _ filesByID: [UUID: CoreInventoryFileRecordV1],
        _ foldersByID: [UUID: CoreInventoryFolderRecordV1],
        _ managedOnlyFileIDs: Set<UUID>,
        _ managedOnlyFolderIDs: Set<UUID>
    ) async throws -> CoreInventoryCatalogComponentsV1

    package typealias PendingCatalogOperation = @Sendable (
        _ root: CoreInventoryRootRecordV1,
        _ filesByID: [UUID: CoreInventoryFileRecordV1],
        _ foldersByID: [UUID: CoreInventoryFolderRecordV1]
    ) async throws -> CoreInventoryCatalogComponentsV1

    package typealias ShardPatchOperation = @Sendable (
        _ event: CoreInventoryAppliedIndexBatchEventV1,
        _ previousFiles: [CoreInventoryFileRecordV1],
        _ previousFolders: [CoreInventoryFolderRecordV1],
        _ filesByID: [UUID: CoreInventoryFileRecordV1],
        _ foldersByID: [UUID: CoreInventoryFolderRecordV1],
        _ maxLogicalMutationCount: Int
    ) async throws -> CoreInventoryCatalogShardPatchV1?

    package typealias MergeShardsOperation = @Sendable (
        _ shards: [(files: [CoreInventoryFileRecordV1], entries: [CoreInventorySearchCatalogEntryV1])]
    ) async throws -> (files: [CoreInventoryFileRecordV1], entries: [CoreInventorySearchCatalogEntryV1])

    private let authoritativeCatalogOperation: AuthoritativeCatalogOperation
    private let pendingCatalogOperation: PendingCatalogOperation
    private let shardPatchOperation: ShardPatchOperation
    private let mergeShardsOperation: MergeShardsOperation

    package init(
        authoritativeCatalogOperation: @escaping AuthoritativeCatalogOperation = {
            roots, filesByID, foldersByID, managedOnlyFileIDs, managedOnlyFolderIDs in
            let client = try await AgentryCoreService.shared.computeClient()
            return try await client.inventoryBuildAuthoritativeCatalogComponents(
                roots: roots,
                filesByID: filesByID,
                foldersByID: foldersByID,
                managedOnlyFileIDs: managedOnlyFileIDs,
                managedOnlyFolderIDs: managedOnlyFolderIDs
            )
        },
        pendingCatalogOperation: @escaping PendingCatalogOperation = { root, filesByID, foldersByID in
            let client = try await AgentryCoreService.shared.computeClient()
            return try await client.inventoryBuildPendingCatalogComponents(
                root: root,
                filesByID: filesByID,
                foldersByID: foldersByID
            )
        },
        shardPatchOperation: @escaping ShardPatchOperation = {
            event, previousFiles, previousFolders, filesByID, foldersByID, maxLogicalMutationCount in
            let client = try await AgentryCoreService.shared.computeClient()
            return try await client.inventoryBuildRootCatalogShardPatch(
                event: event,
                previousFiles: previousFiles,
                previousFolders: previousFolders,
                filesByID: filesByID,
                foldersByID: foldersByID,
                maxLogicalMutationCount: maxLogicalMutationCount
            )
        },
        mergeShardsOperation: @escaping MergeShardsOperation = { shards in
            let client = try await AgentryCoreService.shared.computeClient()
            return try await client.inventoryMergeRootCatalogShardFileEntryLists(shards)
        }
    ) {
        self.authoritativeCatalogOperation = authoritativeCatalogOperation
        self.pendingCatalogOperation = pendingCatalogOperation
        self.shardPatchOperation = shardPatchOperation
        self.mergeShardsOperation = mergeShardsOperation
    }

    /// Rust port of `WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents`.
    package func buildAuthoritativeCatalogComponents(
        roots: [CoreInventoryRootRecordV1],
        filesByID: [UUID: CoreInventoryFileRecordV1],
        foldersByID: [UUID: CoreInventoryFolderRecordV1],
        managedOnlyFileIDs: Set<UUID>,
        managedOnlyFolderIDs: Set<UUID>
    ) async throws -> CoreInventoryCatalogComponentsV1 {
        try await authoritativeCatalogOperation(roots, filesByID, foldersByID, managedOnlyFileIDs, managedOnlyFolderIDs)
    }

    /// Rust port of `WorkspaceInventoryCatalogBuilders.buildPendingCatalogComponents`.
    package func buildPendingCatalogComponents(
        root: CoreInventoryRootRecordV1,
        filesByID: [UUID: CoreInventoryFileRecordV1],
        foldersByID: [UUID: CoreInventoryFolderRecordV1]
    ) async throws -> CoreInventoryCatalogComponentsV1 {
        try await pendingCatalogOperation(root, filesByID, foldersByID)
    }

    /// Rust port of `WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch`. Returns `nil`
    /// for the `NotPatchable` business outcome (fall back to authoritative rebuild).
    package func buildRootCatalogShardPatch(
        event: CoreInventoryAppliedIndexBatchEventV1,
        previousFiles: [CoreInventoryFileRecordV1],
        previousFolders: [CoreInventoryFolderRecordV1],
        filesByID: [UUID: CoreInventoryFileRecordV1],
        foldersByID: [UUID: CoreInventoryFolderRecordV1],
        maxLogicalMutationCount: Int
    ) async throws -> CoreInventoryCatalogShardPatchV1? {
        try await shardPatchOperation(event, previousFiles, previousFolders, filesByID, foldersByID, maxLogicalMutationCount)
    }

    /// Rust port of `WorkspaceInventoryCatalogBuilders.mergeRootCatalogShardFileEntryLists`.
    package func mergeRootCatalogShardFileEntryLists(
        _ shards: [(files: [CoreInventoryFileRecordV1], entries: [CoreInventorySearchCatalogEntryV1])]
    ) async throws -> (files: [CoreInventoryFileRecordV1], entries: [CoreInventorySearchCatalogEntryV1]) {
        try await mergeShardsOperation(shards)
    }
}
