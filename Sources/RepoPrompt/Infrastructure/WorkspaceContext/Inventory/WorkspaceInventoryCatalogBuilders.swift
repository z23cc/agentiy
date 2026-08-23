import Foundation

/// Immutable root-shard construction output: the sorted files/folders for a set of roots plus
/// their materialized `WorkspaceSearchCatalogEntry` values, in catalog order.
///
/// Mirrors `WorkspaceFileContextStore.AuthoritativeCatalogComponents` — kept as a distinct,
/// non-actor-coupled type so it can be ported to Rust 1:1 as part of P3-2.
struct WorkspaceInventoryCatalogComponents {
    let files: [WorkspaceFileRecord]
    let folders: [WorkspaceFolderRecord]
    let entries: [WorkspaceSearchCatalogEntry]
}

/// Output of applying a single logical file/folder mutation to a previously-built catalog shard's
/// file/folder lists, keeping them sorted in place.
///
/// Mirrors `WorkspaceFileContextStore.RootCatalogShardBuilderOutput`.
struct WorkspaceInventoryCatalogShardPatch {
    let files: [WorkspaceFileRecord]
    let folders: [WorkspaceFolderRecord]
    let logicalMutationCount: Int
    let pathIndexChangedFileIDs: Set<UUID>
}

/// Deterministic, side-effect-free construction of workspace catalog shards: sorting/filtering
/// discoverable files and folders into catalog order, assembling `WorkspaceSearchCatalogEntry`
/// values, applying single-mutation patches to an existing sorted shard, and k-way merging
/// per-root sorted shards into one globally-ordered list.
///
/// Extracted from `WorkspaceFileContextStore` (P3-1). Every function here takes its inputs as
/// explicit parameters (no actor state, no filesystem I/O, no watcher/selection/graph/persistence
/// coupling) so this is the seam P3-2 ports to Rust. `WorkspaceFileContextStore` retains thin
/// wrapper methods that supply the actor-state parameters (`filesByID`, `foldersByID`,
/// `managedOnlyFileIDs`, `managedOnlyFolderIDs`, etc.) and adapt the plain results back into its
/// own private shard/component types.
///
/// DO NOT change comparison semantics, sort order, or the single-logical-mutation patch behavior
/// during this extraction — those are preserved verbatim from the pre-extraction implementation.
enum WorkspaceInventoryCatalogBuilders {
    /// Builds sorted, discoverable files/folders and their search catalog entries for `roots`,
    /// filtering out managed-only (non-discoverable) files/folders from `filesByID`/`foldersByID`.
    ///
    /// Uses root-relative-path ordering when there is exactly one root (`searchRootCatalogFilePrecedes`)
    /// and root-qualified full-path ordering otherwise (`searchCatalogFilePrecedes`), matching the
    /// pre-extraction behavior exactly.
    static func buildAuthoritativeCatalogComponents(
        roots: [WorkspaceRootRecord],
        filesByID: [UUID: WorkspaceFileRecord],
        foldersByID: [UUID: WorkspaceFolderRecord],
        managedOnlyFileIDs: Set<UUID>,
        managedOnlyFolderIDs: Set<UUID>
    ) -> WorkspaceInventoryCatalogComponents {
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let allowedRootIDs = Set(rootsByID.keys)
        let filePrecedes: (WorkspaceFileRecord, WorkspaceFileRecord) -> Bool = roots.count == 1
            ? WorkspaceInventoryOrdering.searchRootCatalogFilePrecedes
            : WorkspaceInventoryOrdering.searchCatalogFilePrecedes
        #if DEBUG
            let filterStart = WorkspaceFileSearchDebugTiming.now()
            let filteredFiles = filesByID.values
                .filter { allowedRootIDs.contains($0.rootID) && !managedOnlyFileIDs.contains($0.id) }
            let filteredFolders = foldersByID.values
                .filter { allowedRootIDs.contains($0.rootID) && !managedOnlyFolderIDs.contains($0.id) }
            let filterEnd = WorkspaceFileSearchDebugTiming.now()
            WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordFilter(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: filterStart, through: filterEnd)
            )
            let sortStart = WorkspaceFileSearchDebugTiming.now()
            let fileSortStart = WorkspaceFileSearchDebugTiming.now()
            let files = filteredFiles.sorted(by: filePrecedes)
            let fileSortEnd = WorkspaceFileSearchDebugTiming.now()
            let folderSortStart = WorkspaceFileSearchDebugTiming.now()
            let folders = filteredFolders.sorted(by: WorkspaceInventoryOrdering.searchCatalogFolderPrecedes)
            let folderSortEnd = WorkspaceFileSearchDebugTiming.now()
            let sortEnd = WorkspaceFileSearchDebugTiming.now()
            WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordSort(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: sortStart, through: sortEnd),
                fileNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: fileSortStart,
                    through: fileSortEnd
                ),
                folderNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: folderSortStart,
                    through: folderSortEnd
                ),
                fileInputCount: filteredFiles.count,
                folderInputCount: filteredFolders.count
            )
            let materializationStart = WorkspaceFileSearchDebugTiming.now()
            let entries = files.compactMap { file -> WorkspaceSearchCatalogEntry? in
                guard let root = rootsByID[file.rootID] else { return nil }
                return WorkspaceSearchCatalogEntry(file: file, root: root)
            }
            let materializationEnd = WorkspaceFileSearchDebugTiming.now()
            WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordMaterialization(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: materializationStart,
                    through: materializationEnd
                )
            )
        #else
            let files = filesByID.values
                .filter { allowedRootIDs.contains($0.rootID) && !managedOnlyFileIDs.contains($0.id) }
                .sorted(by: filePrecedes)
            let folders = foldersByID.values
                .filter { allowedRootIDs.contains($0.rootID) && !managedOnlyFolderIDs.contains($0.id) }
                .sorted(by: WorkspaceInventoryOrdering.searchCatalogFolderPrecedes)
            let entries = files.compactMap { file -> WorkspaceSearchCatalogEntry? in
                guard let root = rootsByID[file.rootID] else { return nil }
                return WorkspaceSearchCatalogEntry(file: file, root: root)
            }
        #endif
        return WorkspaceInventoryCatalogComponents(files: files, folders: folders, entries: entries)
    }

    /// Builds the publication payload for a hidden root's pending in-memory index buffers,
    /// without consulting any globally visible store map. This is the catalog half of the 8D
    /// atomic root publication invariant.
    static func buildPendingCatalogComponents(
        root: WorkspaceRootRecord,
        filesByID: [UUID: WorkspaceFileRecord],
        foldersByID: [UUID: WorkspaceFolderRecord]
    ) -> WorkspaceInventoryCatalogComponents {
        let files = filesByID.values.sorted(by: WorkspaceInventoryOrdering.searchRootCatalogFilePrecedes)
        let folders = foldersByID.values.sorted(by: WorkspaceInventoryOrdering.searchCatalogFolderPrecedes)
        let entries = files.map { WorkspaceSearchCatalogEntry(file: $0, root: root) }
        return WorkspaceInventoryCatalogComponents(files: files, folders: folders, entries: entries)
    }

    /// Applies one applied-index batch event to a previously-built, sorted shard's files/folders,
    /// producing a patched (still sorted) files/folders list plus the file IDs whose path-index
    /// entries changed. Returns `nil` when the event cannot be safely applied as a patch (e.g. it
    /// references files/folders inconsistent with `filesByID`/`foldersByID`, or the event mixes
    /// removed and upserted identities/paths) — the caller must fall back to an authoritative
    /// rebuild in that case.
    ///
    /// NOTE: only ever applies a single logical mutation (`touchedFileIDs.first` /
    /// `touchedFolderIDs.first`) even though it computes the full touched-ID sets; this is
    /// existing behavior guarded by `maxLogicalMutationCount` (1 at the only call site) and is
    /// preserved verbatim by this extraction.
    static func buildRootCatalogShardPatch(
        event: WorkspaceAppliedIndexBatchEvent,
        previousFiles: [WorkspaceFileRecord],
        previousFolders: [WorkspaceFolderRecord],
        filesByID: [UUID: WorkspaceFileRecord],
        foldersByID: [UUID: WorkspaceFolderRecord],
        maxLogicalMutationCount: Int
    ) -> WorkspaceInventoryCatalogShardPatch? {
        let oldFilesByID = Dictionary(uniqueKeysWithValues: previousFiles.map { ($0.id, $0) })
        let oldFileIDsByPath = Dictionary(
            previousFiles.map { ($0.standardizedRelativePath, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let oldFoldersByID = Dictionary(uniqueKeysWithValues: previousFolders.map { ($0.id, $0) })
        let oldFolderIDsByPath = Dictionary(
            previousFolders.map { ($0.standardizedRelativePath, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        let upsertedFilesByID = Dictionary(event.upsertedFiles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let upsertedFoldersByID = Dictionary(event.upsertedFolders.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard upsertedFilesByID.count == event.upsertedFiles.count,
              upsertedFoldersByID.count == event.upsertedFolders.count,
              event.upsertedFiles.allSatisfy({ $0.rootID == event.rootID && filesByID[$0.id] == $0 }),
              event.upsertedFolders.allSatisfy({ $0.rootID == event.rootID && foldersByID[$0.id] == $0 })
        else { return nil }
        let representedFolderIDs = Set(oldFoldersByID.keys).union(upsertedFoldersByID.keys)
        for file in upsertedFilesByID.values {
            var parentFolderID = file.parentFolderID
            while let folderID = parentFolderID {
                guard representedFolderIDs.contains(folderID),
                      let folder = foldersByID[folderID]
                else { return nil }
                parentFolderID = folder.parentFolderID
            }
        }

        let removedFileIDs = Set(event.removedFileIDs)
        let removedFolderIDs = Set(event.removedFolderIDs)
        let removedFilePaths = Set(event.removedFilePaths.map(StandardizedPath.relative))
        let removedFolderPaths = Set(event.removedFolderPaths.map(StandardizedPath.relative))
        let modifiedFileIDs = Set(event.modifiedFileIDs)
        let modifiedFolderIDs = Set(event.modifiedFolderIDs)
        guard removedFileIDs.count == event.removedFileIDs.count,
              removedFolderIDs.count == event.removedFolderIDs.count,
              modifiedFileIDs.count == event.modifiedFileIDs.count,
              modifiedFolderIDs.count == event.modifiedFolderIDs.count,
              modifiedFileIDs.allSatisfy({ filesByID[$0]?.rootID == event.rootID }),
              modifiedFolderIDs.allSatisfy({ foldersByID[$0]?.rootID == event.rootID })
        else { return nil }

        var touchedFileIDs = Set(upsertedFilesByID.keys)
        var touchedFolderIDs = Set(upsertedFoldersByID.keys)
        for id in removedFileIDs {
            guard oldFilesByID[id] != nil else { return nil }
            touchedFileIDs.insert(id)
        }
        for path in removedFilePaths {
            guard let id = oldFileIDsByPath[path] else { return nil }
            touchedFileIDs.insert(id)
        }
        for id in modifiedFileIDs {
            guard oldFilesByID[id] != nil else { return nil }
            touchedFileIDs.insert(id)
        }
        for id in removedFolderIDs {
            guard oldFoldersByID[id] != nil else { return nil }
            touchedFolderIDs.insert(id)
        }
        for path in removedFolderPaths {
            guard let id = oldFolderIDsByPath[path] else { return nil }
            touchedFolderIDs.insert(id)
        }
        for id in modifiedFolderIDs {
            guard oldFoldersByID[id] != nil else { return nil }
            touchedFolderIDs.insert(id)
        }

        let upsertedFilePaths = Set(upsertedFilesByID.values.map(\.standardizedRelativePath))
        let upsertedFolderPaths = Set(upsertedFoldersByID.values.map(\.standardizedRelativePath))
        var pathIndexChangedFileIDs = touchedFileIDs
        for path in removedFilePaths.union(upsertedFilePaths) {
            if let oldFileID = oldFileIDsByPath[path] {
                pathIndexChangedFileIDs.insert(oldFileID)
            }
        }
        guard removedFileIDs.isDisjoint(with: upsertedFilesByID.keys),
              removedFolderIDs.isDisjoint(with: upsertedFoldersByID.keys),
              removedFilePaths.isDisjoint(with: upsertedFilePaths),
              removedFolderPaths.isDisjoint(with: upsertedFolderPaths),
              modifiedFileIDs.isDisjoint(with: removedFileIDs),
              modifiedFolderIDs.isDisjoint(with: removedFolderIDs)
        else { return nil }

        let logicalMutationCount = touchedFileIDs.count + touchedFolderIDs.count
        guard logicalMutationCount <= maxLogicalMutationCount else {
            return WorkspaceInventoryCatalogShardPatch(
                files: previousFiles,
                folders: previousFolders,
                logicalMutationCount: logicalMutationCount,
                pathIndexChangedFileIDs: []
            )
        }

        func insertFile(_ file: WorkspaceFileRecord, into files: inout [WorkspaceFileRecord]) {
            var lowerBound = 0
            var upperBound = files.count
            while lowerBound < upperBound {
                let midpoint = (lowerBound + upperBound) / 2
                if WorkspaceInventoryOrdering.searchRootCatalogFilePrecedes(files[midpoint], file) {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
            files.insert(file, at: lowerBound)
        }

        func insertFolder(_ folder: WorkspaceFolderRecord, into folders: inout [WorkspaceFolderRecord]) {
            var lowerBound = 0
            var upperBound = folders.count
            while lowerBound < upperBound {
                let midpoint = (lowerBound + upperBound) / 2
                if WorkspaceInventoryOrdering.searchCatalogFolderPrecedes(folders[midpoint], folder) {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
            folders.insert(folder, at: lowerBound)
        }

        var files = previousFiles
        if let touchedFileID = touchedFileIDs.first {
            files.removeAll { file in
                file.id == touchedFileID
                    || removedFilePaths.contains(file.standardizedRelativePath)
                    || upsertedFilePaths.contains(file.standardizedRelativePath)
            }
            if let upserted = upsertedFilesByID[touchedFileID] {
                insertFile(upserted, into: &files)
            } else if modifiedFileIDs.contains(touchedFileID), let modified = filesByID[touchedFileID] {
                insertFile(modified, into: &files)
            }
        }

        var folders = previousFolders
        if let touchedFolderID = touchedFolderIDs.first {
            folders.removeAll { folder in
                folder.id == touchedFolderID
                    || removedFolderPaths.contains(folder.standardizedRelativePath)
                    || upsertedFolderPaths.contains(folder.standardizedRelativePath)
            }
            if let upserted = upsertedFoldersByID[touchedFolderID] {
                insertFolder(upserted, into: &folders)
            } else if modifiedFolderIDs.contains(touchedFolderID), let modified = foldersByID[touchedFolderID] {
                insertFolder(modified, into: &folders)
            }
        }

        return WorkspaceInventoryCatalogShardPatch(
            files: files,
            folders: folders,
            logicalMutationCount: logicalMutationCount,
            pathIndexChangedFileIDs: pathIndexChangedFileIDs
        )
    }

    /// k-way merges already-sorted per-root (files, entries) lists — each pair sorted by
    /// `WorkspaceInventoryOrdering.searchCatalogFilePrecedes`/`.searchCatalogEntryPrecedes` and
    /// index-aligned (`entries[i]` corresponds to `files[i]`) — into one globally-ordered
    /// (files, entries) pair, breaking ties between equally-ordered files by source-list index
    /// then source-list position (stable merge).
    static func mergeRootCatalogShardFileEntryLists(
        _ shards: [(files: [WorkspaceFileRecord], entries: [WorkspaceSearchCatalogEntry])]
    ) -> (files: [WorkspaceFileRecord], entries: [WorkspaceSearchCatalogEntry]) {
        struct MergeCursor {
            let shardIndex: Int
            let elementIndex: Int
        }

        let totalFileCount = shards.reduce(0) { $0 + $1.files.count }
        var files: [WorkspaceFileRecord] = []
        var entries: [WorkspaceSearchCatalogEntry] = []
        files.reserveCapacity(totalFileCount)
        entries.reserveCapacity(totalFileCount)
        var heap: [MergeCursor] = []
        heap.reserveCapacity(shards.count)

        func cursorPrecedes(_ lhs: MergeCursor, _ rhs: MergeCursor) -> Bool {
            let lhsFile = shards[lhs.shardIndex].files[lhs.elementIndex]
            let rhsFile = shards[rhs.shardIndex].files[rhs.elementIndex]
            if WorkspaceInventoryOrdering.searchCatalogFilePrecedes(lhsFile, rhsFile) { return true }
            if WorkspaceInventoryOrdering.searchCatalogFilePrecedes(rhsFile, lhsFile) { return false }
            if lhs.shardIndex == rhs.shardIndex { return lhs.elementIndex < rhs.elementIndex }
            return lhs.shardIndex < rhs.shardIndex
        }

        func push(_ cursor: MergeCursor) {
            heap.append(cursor)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard cursorPrecedes(heap[index], heap[parent]) else { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }

        func pop() -> MergeCursor? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let first = heap[0]
            heap[0] = heap.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                let next = right < heap.count && cursorPrecedes(heap[right], heap[left]) ? right : left
                guard cursorPrecedes(heap[next], heap[index]) else { break }
                heap.swapAt(index, next)
                index = next
            }
            return first
        }

        for shardIndex in shards.indices where !shards[shardIndex].files.isEmpty {
            push(MergeCursor(shardIndex: shardIndex, elementIndex: 0))
        }
        while let cursor = pop() {
            let shard = shards[cursor.shardIndex]
            files.append(shard.files[cursor.elementIndex])
            entries.append(shard.entries[cursor.elementIndex])
            let nextElementIndex = cursor.elementIndex + 1
            if nextElementIndex < shard.files.count {
                push(MergeCursor(shardIndex: cursor.shardIndex, elementIndex: nextElementIndex))
            }
        }
        return (files, entries)
    }
}
