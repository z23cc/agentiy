@testable import AgentryCoreBridge
import Foundation
import XCTest

/// P4-6b prep slice 1: the Swift facade completion for `inventoryResolveRecords` /
/// `inventoryLookupPaths` / `inventoryOpenProjectedShard` (contract doc §5.3/§6) -- the Rust/FFI
/// side was already implemented and tested; only the Swift wire codec (`FactBlock`/`FactRow`,
/// resolve/lookup request encoding) and facade methods were missing, disclosed as deferred
/// follow-up work in `CoreInventoryScope.swift`'s own header comment. This file exercises the
/// closure through the real bridge/FFI round trip.
final class CoreInventoryScopeReadFacadeTests: XCTestCase {
    private func sampleFile(id: UUID, rootID: UUID, name: String, relativePath: String) -> CoreInventoryFileRecordV1 {
        CoreInventoryFileRecordV1(
            id: id, rootID: rootID, name: name, relativePath: relativePath,
            standardizedRelativePath: relativePath, fullPath: "/repo/\(relativePath)",
            standardizedFullPath: "/repo/\(relativePath)", parentFolderID: nil, modificationDate: nil
        )
    }

    private func sampleFolder(id: UUID, rootID: UUID, relativePath: String) -> CoreInventoryFolderRecordV1 {
        CoreInventoryFolderRecordV1(
            id: id, rootID: rootID, name: relativePath, relativePath: relativePath,
            standardizedRelativePath: relativePath, fullPath: "/repo/\(relativePath)",
            standardizedFullPath: "/repo/\(relativePath)", parentFolderID: nil, modificationDate: nil
        )
    }

    // MARK: - snapshot paging

    func testSnapshotPagingContinuesUntilLongerFolderTableIsExhausted() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: rootLifetimeID)
        _ = try await scope.pushBulkChunk(
            bulkLoadID: bulkLoadID,
            rootID: rootID,
            files: [sampleFile(id: UUID(), rootID: rootID, name: "Only.swift", relativePath: "Only.swift")],
            folders: ["A", "B", "C"].map { sampleFolder(id: UUID(), rootID: rootID, relativePath: $0) }
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)

        let snapshot = try await scope.openSnapshot(rootID: rootID)
        let first = try await snapshot.page(offset: 0, limit: 2)
        XCTAssertEqual(first.files.count, 1)
        XCTAssertEqual(first.folders.map(\.relativePath), ["A", "B"])
        XCTAssertEqual(first.returnedCount, 2)
        XCTAssertTrue(first.hasMore)

        let second = try await snapshot.page(offset: first.returnedCount, limit: 2)
        XCTAssertTrue(second.files.isEmpty)
        XCTAssertEqual(second.folders.map(\.relativePath), ["C"])
        XCTAssertEqual(second.returnedCount, 1)
        XCTAssertFalse(second.hasMore)

        await snapshot.close()
        await scope.close()
        _ = try await bridge.close()
    }

    // MARK: - resolveRecords

    func testResolveRecordsReturnsFactsForPresentAndAbsentIdsInRequestOrder() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: rootLifetimeID)
        let presentFileID = UUID()
        _ = try await scope.pushBulkChunk(
            bulkLoadID: bulkLoadID, rootID: rootID,
            files: [sampleFile(id: presentFileID, rootID: rootID, name: "App.swift", relativePath: "App.swift")],
            folders: []
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)

        let absentFileID = UUID()
        let absentFolderID = UUID()
        let block = try await scope.resolveRecords(
            rootID: rootID, fileIDs: [presentFileID, absentFileID], folderIDs: [absentFolderID]
        )
        XCTAssertEqual(block.generation, 0)
        XCTAssertEqual(block.filesByID.count, 2)
        XCTAssertEqual(block.foldersByID.count, 1)

        let present = try XCTUnwrap(block.filesByID[presentFileID])
        XCTAssertTrue(present.exists)
        XCTAssertEqual(present.fileID, presentFileID)
        XCTAssertNil(present.folderID)
        XCTAssertEqual(present.rootID, rootID)
        XCTAssertTrue(present.isDiscoverable)
        XCTAssertTrue(present.pathRoundTripsToSelf)
        XCTAssertEqual(present.standardizedRelativePath, "App.swift")
        XCTAssertEqual(present.name, "App.swift")

        let absentFile = try XCTUnwrap(block.filesByID[absentFileID])
        XCTAssertFalse(absentFile.exists)
        XCTAssertNil(absentFile.fileID)
        XCTAssertNil(absentFile.standardizedRelativePath)

        let absentFolder = try XCTUnwrap(block.foldersByID[absentFolderID])
        XCTAssertFalse(absentFolder.exists)

        await scope.close()
        _ = try await bridge.close()
    }

    // MARK: - resolveRecordsScopeWide (P4-6b prep-4 gap-closure)

    /// The id-keyed, no-root-known-in-advance shape `WorkspaceFileContextStore
    /// .inventoryRecordFacts(fileIDs:folderIDs:)`'s direct callers need: an id resolves against
    /// whichever open root actually holds it, and its fact carries that root's id so the caller
    /// can discover it after the fact -- proven here across two distinct roots in one scope.
    func testResolveRecordsScopeWideFindsIdsAcrossMultipleOpenRootsAndReportsAbsent() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootA = UUID()
        let rootB = UUID()
        let lifetimeA = try await scope.openRoot(rootID: rootA, name: "a", standardizedFullPath: "/a")
        let lifetimeB = try await scope.openRoot(rootID: rootB, name: "b", standardizedFullPath: "/b")
        let fileInA = UUID()
        let fileInB = UUID()
        let bulkA = try await scope.beginBulkLoad(rootID: rootA, rootLifetimeID: lifetimeA)
        _ = try await scope.pushBulkChunk(
            bulkLoadID: bulkA, rootID: rootA,
            files: [sampleFile(id: fileInA, rootID: rootA, name: "A.swift", relativePath: "src/A.swift")], folders: []
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: bulkA)
        let bulkB = try await scope.beginBulkLoad(rootID: rootB, rootLifetimeID: lifetimeB)
        _ = try await scope.pushBulkChunk(
            bulkLoadID: bulkB, rootID: rootB,
            files: [sampleFile(id: fileInB, rootID: rootB, name: "B.swift", relativePath: "src/B.swift")], folders: []
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: bulkB)

        let missingID = UUID()
        let block = try await scope.resolveRecordsScopeWide(fileIDs: [fileInA, fileInB, missingID], folderIDs: [])
        XCTAssertEqual(block.filesByID.count, 3)

        let factA = try XCTUnwrap(block.filesByID[fileInA])
        XCTAssertTrue(factA.exists)
        XCTAssertEqual(factA.rootID, rootA)
        XCTAssertEqual(factA.name, "A.swift")

        let factB = try XCTUnwrap(block.filesByID[fileInB])
        XCTAssertTrue(factB.exists)
        XCTAssertEqual(factB.rootID, rootB)
        XCTAssertEqual(factB.name, "B.swift")

        let missing = try XCTUnwrap(block.filesByID[missingID])
        XCTAssertFalse(missing.exists)
        XCTAssertNil(missing.rootID)

        await scope.close()
        _ = try await bridge.close()
    }

    /// §4.3.1's D-8 staleness check: `expectedCatalogGeneration` pinning a mismatched generation
    /// returns a whole-block-stale result (`generation == nil`, both dictionaries empty) rather
    /// than silently reading whatever the live generation currently is.
    func testResolveRecordsReportsWholeBlockStaleOnGenerationMismatch() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: rootLifetimeID)
        let fileID = UUID()
        _ = try await scope.pushBulkChunk(
            bulkLoadID: bulkLoadID, rootID: rootID,
            files: [sampleFile(id: fileID, rootID: rootID, name: "App.swift", relativePath: "App.swift")], folders: []
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)

        let block = try await scope.resolveRecords(
            rootID: rootID, expectedCatalogGeneration: 99, fileIDs: [fileID], folderIDs: []
        )
        XCTAssertNil(block.generation, "a mismatched expected generation must report whole-block stale")
        XCTAssertTrue(block.filesByID.isEmpty)
        XCTAssertTrue(block.foldersByID.isEmpty)

        await scope.close()
        _ = try await bridge.close()
    }

    // MARK: - lookupPaths

    func testLookupPathsResolvesPresentAndAbsentPathsInRequestOrder() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: rootLifetimeID)
        let fileID = UUID()
        _ = try await scope.pushBulkChunk(
            bulkLoadID: bulkLoadID, rootID: rootID,
            files: [sampleFile(id: fileID, rootID: rootID, name: "App.swift", relativePath: "App.swift")], folders: []
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)

        let snapshot = try await scope.openSnapshot(rootID: rootID)
        let result = try await snapshot.lookupPaths(relativePaths: ["App.swift", "Missing.swift"])
        XCTAssertEqual(result.factsByPath.count, 2)
        let present = try XCTUnwrap(result.factsByPath["App.swift"])
        XCTAssertTrue(present.exists)
        XCTAssertEqual(present.fileID, fileID)
        let absent = try XCTUnwrap(result.factsByPath["Missing.swift"])
        XCTAssertFalse(absent.exists)

        await snapshot.close()
        await scope.close()
        _ = try await bridge.close()
    }

    // MARK: - openProjectedShard

    func testOpenProjectedShardFiltersToCodemapCapableExtensionsAndIsPageable() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge, config: .init(codemapCapableExtensions: ["swift"]))
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: rootLifetimeID)
        _ = try await scope.pushBulkChunk(
            bulkLoadID: bulkLoadID, rootID: rootID,
            files: [
                sampleFile(id: UUID(), rootID: rootID, name: "App.swift", relativePath: "App.swift"),
                sampleFile(id: UUID(), rootID: rootID, name: "README.md", relativePath: "README.md"),
            ],
            folders: []
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)

        let projected = try await scope.openProjectedShard(rootID: rootID)
        let page = try await projected.page(offset: 0, limit: 10)
        XCTAssertEqual(page.files.map(\.name), ["App.swift"], "the projected shard must filter to codemap-capable extensions only")

        await projected.close()
        await scope.close()
        _ = try await bridge.close()
    }
}
