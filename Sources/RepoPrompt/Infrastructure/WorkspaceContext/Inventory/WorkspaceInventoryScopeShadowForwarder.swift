#if DEBUG
    import AgentryCoreBridge
    import Foundation

    // ================================================================================================
    // P4-5: the shadow arm's Rust-scope forwarder (design doc
    // `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §8.2, step list entry P4-5).
    //
    // `WorkspaceFileContextStore` remains the sole mutation authority. This type is a thin,
    // DEBUG-only, opt-in-only wrapper around one `CoreInventoryScope` (the ARC-driven facade P4-4
    // landed in `AgentryCoreBridge`) that mirrors the store's own applied-index batches into a Rust
    // shadow scope nothing in the product reads. It is compiled out of release builds by the
    // enclosing `#if DEBUG` exactly as `enableCatalogShardShadowValidation` already is (§3.4 /
    // §8.2's four acceptance conditions: no persist, no product read, DEBUG-only-and-opt-in,
    // deletable at cutover).
    //
    // Root lifecycle is driven entirely by the applied-index event stream itself (`rootPath` +
    // `rootLifetimeID` + `isRootUnload`), not by hooking every one of the store's many root-load
    // call sites -- this keeps the shadow arm additive and out of the store's synchronous,
    // no-await root-publication critical sections (`WorkspaceFileContextStore.swift`'s "No await,
    // callback, task creation, or throwing operation is allowed" seeded-root commit comment).
    // `openRootIfNeeded` opens a fresh Rust root/lifetime the first time a given (rootID, Swift
    // lifetimeID) pair is observed and re-opens on lifetime change; `closeRoot` tombstones it on
    // `isRootUnload`.
    actor WorkspaceInventoryScopeShadowForwarder {
        struct ShadowRootRecordMismatch: Error {}

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

        /// Opens (or reuses) the Rust-side root for `rootID`. A new Swift `swiftLifetimeID` closes
        /// any stale binding first -- root reload/re-add mints a fresh Swift lifetime, and the
        /// shadow scope must track that transition the same way the real authority does.
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

        /// Whether `rootID` currently has a live Rust-side binding -- the caller uses this to
        /// decide whether a root's *first* sync must be a bulk load (§8.2's "bulk load, canonical
        /// deltas, rebuilds, unloads" enumeration) rather than an incremental delta:
        /// `WorkspaceFileContextStore` never announces its own initial root seed as an
        /// applied-index event (shard publication is lazy, §3.4), so there is no delta batch to
        /// forward for a root's starting state -- only the bulk-load path can seed it.
        func hasRoot(_ rootID: UUID) -> Bool {
            bindingsByRootID[rootID] != nil
        }

        /// Seeds `rootID`'s entire current record set into the shadow scope via the bulk-load
        /// control plane (`beginBulkLoad` / `pushBulkChunk` / `commitBulkLoad`) -- the same atomic
        /// staging-then-publish contract Rust's `InventoryScope` documents (contract doc §5.2),
        /// chunked to bound per-call latency the way the store's own `buildPendingCatalogComponents`
        /// already is expected to.
        func bulkSeed(rootID: UUID, files: [WorkspaceFileRecord], folders: [WorkspaceFolderRecord]) async throws {
            guard let binding = bindingsByRootID[rootID] else { throw ShadowRootRecordMismatch() }
            let scope = try await requireScope()
            let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: binding.rustLifetimeID)
            let chunkSize = 2000
            let coreFiles = files.map(Self.coreFileRecord)
            let coreFolders = folders.map(Self.coreFolderRecord)
            do {
                // Push files and folders together per chunk (both lists share the same chunk
                // boundaries). Staging itself was never the bug -- `pushBulkChunk`'s
                // `foldersStaged` receipt always reported the pushed folder correctly. The P4-5
                // shadow-arm differential surfaced a REAL, separate bug on the *read* side instead:
                // `inventory_snapshot_page`'s FFI wire encoder (`rust/crates/ffi/src/api.rs`)
                // hardcoded an empty folders list on every page response regardless of what a bulk
                // load staged/committed, so a correctly-staged folder was simply never paged back
                // out. Fixed at `InventoryScope::snapshot_page` (now returns a `SnapshotPage` with
                // both `files` and `folders`) plus the FFI encoder, with a Rust-side regression
                // test (`snapshot_page_returns_bulk_loaded_folders_not_just_files`,
                // `rust/crates/runtime/tests/inventory_scope_contract.rs`) pinning it.
                let chunkCount = max(
                    (coreFiles.count + chunkSize - 1) / chunkSize,
                    (coreFolders.count + chunkSize - 1) / chunkSize
                )
                for chunkIndex in 0 ..< max(chunkCount, coreFiles.isEmpty && coreFolders.isEmpty ? 0 : 1) {
                    let fileStart = min(chunkIndex * chunkSize, coreFiles.count)
                    let fileEnd = min(fileStart + chunkSize, coreFiles.count)
                    let folderStart = min(chunkIndex * chunkSize, coreFolders.count)
                    let folderEnd = min(folderStart + chunkSize, coreFolders.count)
                    _ = try await scope.pushBulkChunk(
                        bulkLoadID: bulkLoadID,
                        rootID: rootID,
                        files: Array(coreFiles[fileStart ..< fileEnd]),
                        folders: Array(coreFolders[folderStart ..< folderEnd])
                    )
                }
            } catch {
                _ = try? await scope.abortBulkLoad(bulkLoadID: bulkLoadID)
                throw error
            }
            _ = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)
        }

        /// Forwards one applied-index batch verbatim -- the same upsert/remove/modify sets Swift
        /// just committed to its own tables, translated field-for-field into the facade's wire
        /// types (never re-derived: no new UUID minting, no re-classification). Reentrancy/ordering
        /// is the caller's responsibility (`WorkspaceFileContextStore`'s pending-event buffer is
        /// drained strictly FIFO into this actor, one `await` at a time).
        @discardableResult
        func apply(_ event: WorkspaceAppliedIndexBatchEvent) async throws -> CoreInventoryDeltaReceipt {
            let scope = try await requireScope()
            guard let binding = bindingsByRootID[event.rootID] else {
                throw ShadowRootRecordMismatch()
            }
            let command = CoreInventoryDeltaCommand(
                rootID: event.rootID,
                rootLifetimeID: binding.rustLifetimeID,
                watcherAcceptedWatermark: nil,
                requiresFullResync: event.requiresFullResync,
                expectedAppliedIndexGeneration: nil,
                source: "workspace-file-context-store-shadow",
                event: CoreInventoryAppliedIndexBatchEventV1(
                    rootID: event.rootID,
                    upsertedFiles: event.upsertedFiles.map(Self.coreFileRecord),
                    upsertedFolders: event.upsertedFolders.map(Self.coreFolderRecord),
                    removedFileIDs: event.removedFileIDs,
                    removedFolderIDs: event.removedFolderIDs,
                    removedFilePaths: event.removedFilePaths,
                    removedFolderPaths: event.removedFolderPaths,
                    modifiedFileIDs: event.modifiedFileIDs,
                    modifiedFolderIDs: event.modifiedFolderIDs
                )
            )
            return try await scope.applyDelta(command)
        }

        /// Pages the shadow scope's entire current table for one root -- files and folders, sorted
        /// the same way the Swift shard sorts (`standardizedRelativePath`), so the caller can
        /// byte-compare field-for-field without needing its own reordering logic.
        func snapshotAllRecords(
            rootID: UUID,
            pageSize: UInt64 = 4096
        ) async throws -> (files: [CoreInventoryFileRecordV1], folders: [CoreInventoryFolderRecordV1], generation: UInt64) {
            let scope = try await requireScope()
            let snapshot = try await scope.openSnapshot(rootID: rootID)
            defer { Task { await snapshot.close() } }
            var files: [CoreInventoryFileRecordV1] = []
            var folders: [CoreInventoryFolderRecordV1] = []
            var offset: UInt64 = 0
            while true {
                let page = try await snapshot.page(offset: offset, limit: pageSize)
                files.append(contentsOf: page.files)
                folders.append(contentsOf: page.folders)
                offset += page.returnedCount
                if !page.hasMore || page.returnedCount == 0 { break }
            }
            return (
                files.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath },
                folders.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath },
                snapshot.generation
            )
        }

        /// The index comparison arm (§8.2): runs one query against the shadow scope's own
        /// path-index build for `rootID`. Handle-based like every other read-plane export --
        /// `openSnapshot` first, `query` against the resulting handle.
        func query(
            rootID: UUID,
            pattern: String,
            limit: UInt64,
            haystackVariant: CoreInventoryQueryHaystackVariant,
            nonEmptyRelativePrefix: String,
            emptyRelativePathValue: String
        ) async throws -> CoreInventoryQueryResult {
            let scope = try await requireScope()
            let snapshot = try await scope.openSnapshot(rootID: rootID)
            defer { Task { await snapshot.close() } }
            return try await snapshot.query(
                pattern: pattern,
                limit: limit,
                haystackVariant: haystackVariant,
                nonEmptyRelativePrefix: nonEmptyRelativePrefix,
                emptyRelativePathValue: emptyRelativePathValue
            )
        }

        /// P4-6b prep slice 2: exposes the shadow scope's own event stream for the republication
        /// adapter's DEBUG verification (design doc §4.3) -- the shadow scope publishes real
        /// `CoreInventoryScopeEvent`s for every mutation this forwarder mirrors into it, exactly
        /// as a swapped-in authoritative scope would. Must be called once, before any mutation
        /// this test run wants to observe (register-before-suspend, matching `CoreInventoryScope
        /// .events()`'s own contract).
        func events(
            maxQueuedEvents: UInt64 = 256,
            maxQueuedBytes: UInt64 = 1_048_576
        ) async throws -> CoreInventoryScopeEventStream {
            let scope = try await requireScope()
            return try await scope.events(maxQueuedEvents: maxQueuedEvents, maxQueuedBytes: maxQueuedBytes)
        }

        /// P4-6b prep slice 1's dual-read comparator: resolves the shadow scope's own
        /// id-keyed facts via the new `inventoryResolveRecords` facade, root-based like the
        /// FFI export itself (contract doc §5.3) -- no handle needed, no `expectedCatalogGeneration`
        /// pin (the comparator always wants the shadow's live generation, matching how the
        /// authoritative-side read it compares against is also always live).
        func resolveRecords(
            rootID: UUID,
            fileIDs: [UUID],
            folderIDs: [UUID]
        ) async throws -> CoreInventoryRecordBlock {
            let scope = try await requireScope()
            return try await scope.resolveRecords(rootID: rootID, fileIDs: fileIDs, folderIDs: folderIDs)
        }

        /// P4-6b prep slice 1's dual-read comparator: resolves the shadow scope's own
        /// path-keyed facts via the new `inventoryLookupPaths` facade. Handle-based like the
        /// index comparison arm's `query` above -- `openSnapshot` first, `lookupPaths` against
        /// the resulting handle.
        func lookupPaths(
            rootID: UUID,
            relativePaths: [String]
        ) async throws -> CoreInventoryPathLookupResult {
            let scope = try await requireScope()
            let snapshot = try await scope.openSnapshot(rootID: rootID)
            defer { Task { await snapshot.close() } }
            return try await snapshot.lookupPaths(relativePaths: relativePaths)
        }

        /// P4-6b prep slice 2 (checkpointed item 3): the shadow scope's own diagnostics snapshot,
        /// for the diagnostics-only parity suite. Field-for-field this mirrors Swift's
        /// `RootCatalogShardDebugSnapshot`/`RootCatalogShardGenerationDebugSnapshot` (contract doc
        /// §5c), but only the config-level fields (`liveGenerationCapPerRoot`,
        /// `maxPatchLogicalMutationCount`) and root-membership are cross-arm-guaranteed today --
        /// see that suite's header for the full parity/non-parity breakdown.
        func diagnostics() async throws -> CoreInventoryDiagnosticsV1 {
            let scope = try await requireScope()
            return try await scope.diagnostics()
        }

        /// Idempotent teardown -- part of §8.2's "deletable" acceptance condition: closing this
        /// forwarder releases every Rust-side resource the shadow arm opened, leaving nothing
        /// behind for the product to observe.
        func close() async {
            for (rootID, binding) in bindingsByRootID {
                _ = try? await scope?.closeRoot(rootID: rootID, rootLifetimeID: binding.rustLifetimeID)
            }
            bindingsByRootID.removeAll()
            await scope?.close()
            scope = nil
        }

        /// Normalizes a parent-folder reference that points at the root's own self-referencing
        /// folder record (`id == rootID`, `relativePath == ""` -- see
        /// `WorkspaceInventoryScopeShadowForwarder`'s doc comment) to `nil`. That record is never
        /// forwarded to the shadow scope (§8.2's root-marker exclusion), so a raw `parentFolderID
        /// == rootID` would be a dangling reference on the Rust side.
        private static func normalizedParentFolderID(_ parentFolderID: UUID?, rootID: UUID) -> UUID? {
            parentFolderID == rootID ? nil : parentFolderID
        }

        private static func coreFileRecord(_ file: WorkspaceFileRecord) -> CoreInventoryFileRecordV1 {
            CoreInventoryFileRecordV1(
                id: file.id,
                rootID: file.rootID,
                name: file.name,
                relativePath: file.relativePath,
                standardizedRelativePath: file.standardizedRelativePath,
                fullPath: file.fullPath,
                standardizedFullPath: file.standardizedFullPath,
                parentFolderID: normalizedParentFolderID(file.parentFolderID, rootID: file.rootID),
                modificationDate: file.modificationDate
            )
        }

        private static func coreFolderRecord(_ folder: WorkspaceFolderRecord) -> CoreInventoryFolderRecordV1 {
            CoreInventoryFolderRecordV1(
                id: folder.id,
                rootID: folder.rootID,
                name: folder.name,
                relativePath: folder.relativePath,
                standardizedRelativePath: folder.standardizedRelativePath,
                fullPath: folder.fullPath,
                standardizedFullPath: folder.standardizedFullPath,
                parentFolderID: normalizedParentFolderID(folder.parentFolderID, rootID: folder.rootID),
                modificationDate: folder.modificationDate
            )
        }
    }
#endif
