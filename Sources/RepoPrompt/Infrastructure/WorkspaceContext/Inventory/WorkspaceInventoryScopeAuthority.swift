import AgentryCoreBridge
import Foundation

// ================================================================================================
// P4-6b: THE CUTOVER's production mutation/read authority (design doc
// `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §8.3's "Cutover" slice;
// contract doc `docs/architecture/rust-inventory-scope-v1.md`).
//
// Unlike `WorkspaceInventoryScopeShadowForwarder` (P4-5, `#if DEBUG`-only, comparison-only,
// deletable at cutover -- nothing in the product ever read it), this type IS the authority
// `WorkspaceFileContextStore` routes every mutation and read of inventory record content through.
// It ships in release builds. There is no shadow arm behind it after cutover (§8.5: "the shadow
// arm is the safety mechanism, and it lives entirely before the cutover").
//
// Root lifecycle mirrors the shadow forwarder's own technique (its doc comment on why root
// lifecycle is driven lazily rather than by hooking every one of the store's many root-load call
// sites): `openRootIfNeeded` opens a fresh Rust root/lifetime the first time a given (rootID,
// Swift lifetimeID) pair is observed by a mutation choke point, and re-opens on Swift lifetime
// change (root reload/re-add mints a fresh Swift lifetime). `closeRoot` is called once, from
// `WorkspaceFileContextStore.unloadRoots`, the single well-defined root-teardown site.
//
// Mint routing (contract doc §11.4's testable contract, restated): a path with an
// already-known id is never re-minted -- it goes through the id-supplied `applyDelta`/
// `bulkSeed`. A path being staged for the first time in a root lifetime, or re-added after
// removal, goes through `applyDeltaDiscovery`/`bulkSeedDiscovery` and always mints a fresh id.
// It is this type's caller's responsibility (`WorkspaceFileContextStore`'s mutation choke points)
// to know which path a given batch takes -- this type does not infer it.
actor WorkspaceInventoryScopeAuthority {
    private struct RootBinding {
        let swiftLifetimeID: UUID?
        let rustLifetimeID: String
    }

    private let bridge: AgentryCoreBridge
    private var scope: CoreInventoryScope?
    private var bindingsByRootID: [UUID: RootBinding] = [:]

    init(bridge: AgentryCoreBridge) {
        self.bridge = bridge
    }

    private func requireScope() async throws -> CoreInventoryScope {
        if let scope { return scope }
        let opened = try await CoreInventoryScope.open(bridge: bridge)
        scope = opened
        return opened
    }

    /// Opens (or reuses) the Rust-side root for `rootID`. A new `swiftLifetimeID` closes any
    /// stale binding first -- root reload/re-add mints a fresh Swift lifetime, and the authority
    /// must track that transition the same way the pre-cutover Swift authority did.
    @discardableResult
    func openRootIfNeeded(
        rootID: UUID,
        swiftLifetimeID: UUID?,
        name: String,
        standardizedFullPath: String
    ) async throws -> String {
        let scope = try await requireScope()
        if let existing = bindingsByRootID[rootID] {
            if existing.swiftLifetimeID == swiftLifetimeID {
                return existing.rustLifetimeID
            }
            _ = try? await scope.closeRoot(rootID: rootID, rootLifetimeID: existing.rustLifetimeID)
            bindingsByRootID.removeValue(forKey: rootID)
        }
        let rustLifetimeID = try await scope.openRoot(
            rootID: rootID, name: name, standardizedFullPath: standardizedFullPath
        )
        bindingsByRootID[rootID] = RootBinding(swiftLifetimeID: swiftLifetimeID, rustLifetimeID: rustLifetimeID)
        return rustLifetimeID
    }

    func closeRoot(rootID: UUID) async {
        guard let scope, let binding = bindingsByRootID.removeValue(forKey: rootID) else { return }
        _ = try? await scope.closeRoot(rootID: rootID, rootLifetimeID: binding.rustLifetimeID)
    }

    func hasRoot(_ rootID: UUID) -> Bool {
        bindingsByRootID[rootID] != nil
    }

    private func requireBinding(rootID: UUID) throws -> RootBinding {
        guard let binding = bindingsByRootID[rootID] else {
            throw WorkspaceInventoryScopeAuthorityError.rootNotOpen(rootID)
        }
        return binding
    }

    // MARK: - Bulk load (initial root read; §11.3's discovery bulk-chunk path)

    struct BulkSeedDiscoveryResult {
        /// Parallel to the concatenated input order across all chunks (files then folders).
        var mintedFileIDs: [UUID]
        var mintedFolderIDs: [UUID]
        var generation: UInt64
        var rootLifetimeID: String
    }

    /// Seeds `rootID`'s entire initial record set via the bulk-load control plane
    /// (`beginBulkLoad`/`pushBulkChunkDiscovery`/`commitBulkLoad`), chunked to bound per-call
    /// latency (mirrors `WorkspaceInventoryScopeShadowForwarder.bulkSeed`'s chunking). Every
    /// record is id-less on entry -- an initial root read has no "already-known id" to reuse.
    func bulkSeedDiscovery(
        rootID: UUID,
        files: [CoreDiscoveredFileRecordV1],
        folders: [CoreDiscoveredFolderRecordV1],
        chunkSize: Int = 2000
    ) async throws -> BulkSeedDiscoveryResult {
        let binding = try requireBinding(rootID: rootID)
        let scope = try await requireScope()
        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: binding.rustLifetimeID)
        var mintedFileIDs: [UUID] = []
        var mintedFolderIDs: [UUID] = []
        mintedFileIDs.reserveCapacity(files.count)
        mintedFolderIDs.reserveCapacity(folders.count)
        do {
            let chunkCount = max(
                (files.count + chunkSize - 1) / chunkSize,
                (folders.count + chunkSize - 1) / chunkSize
            )
            for chunkIndex in 0 ..< max(chunkCount, files.isEmpty && folders.isEmpty ? 0 : 1) {
                let fileStart = min(chunkIndex * chunkSize, files.count)
                let fileEnd = min(fileStart + chunkSize, files.count)
                let folderStart = min(chunkIndex * chunkSize, folders.count)
                let folderEnd = min(folderStart + chunkSize, folders.count)
                let receipt = try await scope.pushBulkChunkDiscovery(
                    bulkLoadID: bulkLoadID,
                    rootID: rootID,
                    files: Array(files[fileStart ..< fileEnd]),
                    folders: Array(folders[folderStart ..< folderEnd])
                )
                mintedFileIDs.append(contentsOf: receipt.mintedFileIDs)
                mintedFolderIDs.append(contentsOf: receipt.mintedFolderIDs)
            }
        } catch {
            _ = try? await scope.abortBulkLoad(bulkLoadID: bulkLoadID)
            throw error
        }
        let commitReceipt = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)
        return BulkSeedDiscoveryResult(
            mintedFileIDs: mintedFileIDs,
            mintedFolderIDs: mintedFolderIDs,
            generation: commitReceipt.generation,
            rootLifetimeID: commitReceipt.rootLifetimeID
        )
    }

    // MARK: - Delta application (incremental; the hot path)

    /// Id-supplied delta apply -- modifications (content update on an already-known id) and
    /// removals. Contract doc §11.4: "a path with an already-known id is never re-minted."
    func applyDelta(
        rootID: UUID,
        requiresFullResync: Bool = false,
        source: String,
        event: CoreInventoryAppliedIndexBatchEventV1
    ) async throws -> CoreInventoryDeltaReceipt {
        let binding = try requireBinding(rootID: rootID)
        let scope = try await requireScope()
        return try await scope.applyDelta(CoreInventoryDeltaCommand(
            rootID: rootID,
            rootLifetimeID: binding.rustLifetimeID,
            requiresFullResync: requiresFullResync,
            source: source,
            event: event
        ))
    }

    /// Discovery delta apply -- newly-discovered paths (first time in this root lifetime, or
    /// re-added after removal). Every entry in `event.upsertedFiles`/`upsertedFolders` mints a
    /// fresh id unconditionally; the receipt echoes minted ids in `upsertedFiles`/`upsertedFolders`
    /// order so the caller (which knows the discovered paths in that order but not yet their ids)
    /// can zip them back together (contract doc §11.3).
    func applyDeltaDiscovery(
        rootID: UUID,
        requiresFullResync: Bool = false,
        source: String,
        event: CoreInventoryDiscoveryAppliedIndexBatchEventV1
    ) async throws -> CoreInventoryDeltaDiscoveryReceipt {
        let binding = try requireBinding(rootID: rootID)
        let scope = try await requireScope()
        return try await scope.applyDeltaDiscovery(CoreInventoryDeltaDiscoveryCommand(
            rootID: rootID,
            rootLifetimeID: binding.rustLifetimeID,
            requiresFullResync: requiresFullResync,
            source: source,
            event: event
        ))
    }

    // MARK: - Reads (Tier 1: handle + narrow reads; §6.1)

    func resolveRecords(
        rootID: UUID,
        expectedCatalogGeneration: UInt64? = nil,
        fileIDs: [UUID],
        folderIDs: [UUID]
    ) async throws -> CoreInventoryRecordBlock {
        let scope = try await requireScope()
        return try await scope.resolveRecords(
            rootID: rootID,
            expectedCatalogGeneration: expectedCatalogGeneration,
            fileIDs: fileIDs,
            folderIDs: folderIDs
        )
    }

    /// P4-6b prep-4: id-keyed, no-root-known resolve (contract doc §12 amendment) -- the primitive
    /// `WorkspaceFileContextStore.inventoryRecordFacts(fileIDs:folderIDs:)`'s direct (non-
    /// `appliedIndexRecordLookup`) callers need, several of which discover the owning root *from*
    /// the resolved record rather than supplying one.
    func resolveRecordsScopeWide(fileIDs: [UUID], folderIDs: [UUID]) async throws -> CoreInventoryRecordBlock {
        let scope = try await requireScope()
        return try await scope.resolveRecordsScopeWide(fileIDs: fileIDs, folderIDs: folderIDs)
    }

    /// Opens a snapshot handle and immediately resolves `relativePaths` against it, closing the
    /// handle afterward -- `inventoryLookupPaths` is handle-based at the facade layer (contract
    /// doc §5.3) but every call site of this authority wants a one-shot, root-scoped lookup, so
    /// the handle lifecycle is kept internal here rather than pushed onto every caller.
    func lookupPaths(rootID: UUID, relativePaths: [String]) async throws -> CoreInventoryPathLookupResult {
        let scope = try await requireScope()
        let snapshot = try await scope.openSnapshot(rootID: rootID)
        defer { Task { await snapshot.close() } }
        return try await snapshot.lookupPaths(relativePaths: relativePaths)
    }

    func openSnapshot(rootID: UUID) async throws -> CoreInventorySnapshot {
        let scope = try await requireScope()
        return try await scope.openSnapshot(rootID: rootID)
    }

    /// One immutable, fully-paged authority generation in Rust-published order. This is the
    /// P4-8 read contract used by Swift presentation adapters: callers receive complete ordered
    /// tables or an error, never a partial page prefix or independently reconstructed ordering.
    struct OrderedSnapshotRead {
        let generation: UInt64
        let rootLifetimeID: String
        let files: [CoreInventoryFileRecordV1]
        let folders: [CoreInventoryFolderRecordV1]
    }

    func readOrderedSnapshot(
        rootID: UUID,
        expectedSwiftLifetimeID: UUID?,
        pageSize: UInt64 = 4096
    ) async throws -> OrderedSnapshotRead {
        guard pageSize > 0 else {
            throw WorkspaceInventoryScopeAuthorityError.invalidPageSize(pageSize)
        }
        let binding = try requireBinding(rootID: rootID)
        guard binding.swiftLifetimeID == expectedSwiftLifetimeID else {
            throw WorkspaceInventoryScopeAuthorityError.swiftLifetimeMismatch(rootID)
        }
        let scope = try await requireScope()
        let snapshot = try await scope.openSnapshot(rootID: rootID)
        do {
            guard snapshot.rootLifetimeID == binding.rustLifetimeID else {
                throw WorkspaceInventoryScopeAuthorityError.rustLifetimeMismatch(rootID)
            }

            var files: [CoreInventoryFileRecordV1] = []
            var folders: [CoreInventoryFolderRecordV1] = []
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let page = try await snapshot.page(offset: offset, limit: pageSize)
                try Task.checkCancellation()
                let expectedReturnedCount = UInt64(max(page.files.count, page.folders.count))
                guard page.returnedCount == expectedReturnedCount else {
                    throw WorkspaceInventoryScopeAuthorityError.invalidPageProgress(
                        rootID: rootID,
                        returnedCount: page.returnedCount,
                        expectedReturnedCount: expectedReturnedCount
                    )
                }
                files.append(contentsOf: page.files)
                folders.append(contentsOf: page.folders)
                guard page.hasMore else { break }
                guard page.returnedCount > 0 else {
                    throw WorkspaceInventoryScopeAuthorityError.invalidPageProgress(
                        rootID: rootID,
                        returnedCount: 0,
                        expectedReturnedCount: expectedReturnedCount
                    )
                }
                offset += page.returnedCount
            }

            await snapshot.close()
            try Task.checkCancellation()
            let currentBinding = try requireBinding(rootID: rootID)
            guard currentBinding.swiftLifetimeID == expectedSwiftLifetimeID else {
                throw WorkspaceInventoryScopeAuthorityError.swiftLifetimeMismatch(rootID)
            }
            guard currentBinding.rustLifetimeID == snapshot.rootLifetimeID else {
                throw WorkspaceInventoryScopeAuthorityError.rustLifetimeMismatch(rootID)
            }
            return OrderedSnapshotRead(
                generation: snapshot.generation,
                rootLifetimeID: snapshot.rootLifetimeID,
                files: files,
                folders: folders
            )
        } catch {
            await snapshot.close()
            throw error
        }
    }

    /// The B2 codemap graph-index catalog shard (§4.3.1): built authority-side under the
    /// codemap-capable extension set supplied at scope-open time.
    func openProjectedShard(rootID: UUID) async throws -> CoreInventorySnapshot {
        let scope = try await requireScope()
        return try await scope.openProjectedShard(rootID: rootID)
    }

    func query(
        rootID: UUID,
        pattern: String,
        limit: UInt64,
        haystackVariant: CoreInventoryQueryHaystackVariant,
        nonEmptyRelativePrefix: String,
        emptyRelativePathValue: String,
        logicalPrefix: (nonEmptyRelativePrefix: String, emptyRelativePathValue: String)? = nil
    ) async throws -> CoreInventoryQueryResult {
        let scope = try await requireScope()
        let snapshot = try await scope.openSnapshot(rootID: rootID)
        defer { Task { await snapshot.close() } }
        return try await snapshot.query(
            pattern: pattern,
            limit: limit,
            haystackVariant: haystackVariant,
            nonEmptyRelativePrefix: nonEmptyRelativePrefix,
            emptyRelativePathValue: emptyRelativePathValue,
            logicalPrefix: logicalPrefix
        )
    }

    func events(
        maxQueuedEvents: UInt64 = 256,
        maxQueuedBytes: UInt64 = 1_048_576
    ) async throws -> CoreInventoryScopeEventStream {
        let scope = try await requireScope()
        return try await scope.events(maxQueuedEvents: maxQueuedEvents, maxQueuedBytes: maxQueuedBytes)
    }

    /// P4-6b gap-closure: discoverability toggle. `try?`-tolerant at every choke-point call
    /// site by design (matching this type's other mutation methods) -- a failure here degrades
    /// to "not yet marked managed-only," not data loss.
    func setFileManagedOnly(rootID: UUID, fileID: UUID, managedOnly: Bool) async throws {
        let scope = try await requireScope()
        try await scope.setFileManagedOnly(rootID: rootID, fileID: fileID, managedOnly: managedOnly)
    }

    func setFolderManagedOnly(rootID: UUID, folderID: UUID, managedOnly: Bool) async throws {
        let scope = try await requireScope()
        try await scope.setFolderManagedOnly(rootID: rootID, folderID: folderID, managedOnly: managedOnly)
    }

    func diagnostics() async throws -> CoreInventoryDiagnosticsV1 {
        let scope = try await requireScope()
        return try await scope.diagnostics()
    }

    /// Idempotent teardown -- called once, from the store's own shutdown path.
    func close() async {
        for (rootID, binding) in bindingsByRootID {
            _ = try? await scope?.closeRoot(rootID: rootID, rootLifetimeID: binding.rustLifetimeID)
        }
        bindingsByRootID.removeAll()
        await scope?.close()
        scope = nil
    }
}

enum WorkspaceInventoryScopeAuthorityError: Error, Equatable {
    case rootNotOpen(UUID)
    case swiftLifetimeMismatch(UUID)
    case rustLifetimeMismatch(UUID)
    case invalidPageSize(UInt64)
    case invalidPageProgress(rootID: UUID, returnedCount: UInt64, expectedReturnedCount: UInt64)
}

extension WorkspaceInventoryScopeAuthorityError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .rootNotOpen(rootID):
            "Inventory scope authority has no open Rust root for \(rootID)."
        case let .swiftLifetimeMismatch(rootID):
            "Inventory scope authority Swift lifetime changed while reading root \(rootID)."
        case let .rustLifetimeMismatch(rootID):
            "Inventory scope authority Rust lifetime changed while reading root \(rootID)."
        case let .invalidPageSize(pageSize):
            "Inventory scope authority snapshot page size must be positive, got \(pageSize)."
        case let .invalidPageProgress(rootID, returnedCount, expectedReturnedCount):
            "Inventory scope authority snapshot page for root \(rootID) reported \(returnedCount) records; expected \(expectedReturnedCount)."
        }
    }
}
