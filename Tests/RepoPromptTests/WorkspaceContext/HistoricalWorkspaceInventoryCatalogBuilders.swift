import Foundation
@testable import RepoPromptApp

/// Immutable output of the frozen historical Swift full-snapshot benchmark. P4-8c removes its
/// product fallback/shadow callers, and P4-8d removes the last pending-root product use.
struct WorkspaceInventoryCatalogComponents {
    let files: [WorkspaceFileRecord]
    let folders: [WorkspaceFolderRecord]
    let entries: [WorkspaceSearchCatalogEntry]
}

/// Historical output of the retired Swift catalog-shard patch benchmark. P4-8b removes every
/// product caller; this type remains only to interpret the registered pre-cutover Swift baseline.
struct WorkspaceInventoryCatalogShardPatch {
    let files: [WorkspaceFileRecord]
    let folders: [WorkspaceFolderRecord]
    let logicalMutationCount: Int
    let pathIndexChangedFileIDs: Set<UUID>
}

/// Test-only, deterministic historical Swift benchmark support. P4-8e-b moves the frozen
/// full-snapshot and single-mutation reference arms out of product Sources; none of these helpers
/// may become a product fallback, parity authority, shadow, or presentation path.
///
/// Extracted from `WorkspaceFileContextStore` (P3-1). Every function here takes its inputs as
/// explicit parameters (no actor state, no filesystem I/O, no watcher/selection/graph/persistence
/// coupling). P4-8a retired normal per-root Swift construction, P4-8b retired event patching, and
/// P4-8c retired the full-snapshot fallback and DEBUG shadow, and P4-8d retired pending-root Swift
/// This file is compiled only into RepoPromptTests.
enum HistoricalWorkspaceInventoryCatalogBuilders {
    /// Frozen P4-1 Swift full-snapshot benchmark arm. P4-8c removes every product caller; preserve
    /// its pre-cutover filtering, ordering, and materialization semantics so registered benchmark
    /// evidence remains interpretable. It must not become a fallback, parity, or shadow authority.
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

    /// Historical P4-1 Swift benchmark arm. Product applied-index events no longer call this
    /// function as of P4-8b; they publish a complete ordered Rust generation. Keep the old single-
    /// mutation semantics unchanged so previously registered benchmark evidence stays interpretable.
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
            // The root-self-referencing marker (`parentFolderID == event.rootID`) is the walk's
            // implicit terminal case; the loop condition stops before ever consulting
            // `representedFolderIDs`/`foldersByID` for it, so it does not matter whether either
            // happens to carry a synthesized root-marker entry. `foldersByID` (this function's
            // parameter) is always Rust-sourced and never carries it (root-marker exclusion,
            // contract doc §5.4); `representedFolderIDs`, derived in part from the caller's
            // previously-built shard folders, may carry a synthesized root-marker record (Item 0
            // fix, `buildAuthoritativeCatalogComponents`) -- harmlessly, since it is never touched by
            // a Rust-sourced event and this walk never looks it up. A lookup miss here is not
            // "unrepresented ancestor", it's "reached the root"; treating it as a lookup failure
            // would decline every top-level file's patch unconditionally.
            while let folderID = parentFolderID, folderID != event.rootID {
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
}
