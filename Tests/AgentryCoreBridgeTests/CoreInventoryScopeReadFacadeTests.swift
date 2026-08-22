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
