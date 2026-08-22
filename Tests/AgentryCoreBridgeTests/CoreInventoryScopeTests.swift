@testable import AgentryCoreBridge
import Foundation
import XCTest

/// P4-4 end-to-end bridge test: exercises `CoreInventoryScope` / `CoreInventorySnapshot` against
/// the real Rust `InventoryScope` through the full UniFFI round trip (not `FakeCoreTransport`) --
/// the Swift-side counterpart to `agentry_ffi::api::tests::
/// inventory_scope_full_lifecycle_round_trips_through_the_ffi_surface`.
final class CoreInventoryScopeTests: XCTestCase {
    private func sampleFile(id: UUID, rootID: UUID, name: String, relativePath: String) -> CoreInventoryFileRecordV1 {
        CoreInventoryFileRecordV1(
            id: id,
            rootID: rootID,
            name: name,
            relativePath: relativePath,
            standardizedRelativePath: relativePath,
            fullPath: "/repo/\(relativePath)",
            standardizedFullPath: "/repo/\(relativePath)",
            parentFolderID: nil,
            modificationDate: nil
        )
    }

    func testFullLifecycleRoundTripsThroughTheRealBridge() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()

        let scope = try await CoreInventoryScope.open(
            bridge: bridge,
            config: .init(codemapCapableExtensions: ["swift"])
        )
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")

        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: rootLifetimeID)
        let files = [
            sampleFile(id: UUID(), rootID: rootID, name: "App.swift", relativePath: "App.swift"),
            sampleFile(id: UUID(), rootID: rootID, name: "README.md", relativePath: "README.md"),
        ]
        let chunkReceipt = try await scope.pushBulkChunk(bulkLoadID: bulkLoadID, rootID: rootID, files: files, folders: [])
        XCTAssertEqual(chunkReceipt.filesStaged, 2)
        XCTAssertEqual(chunkReceipt.foldersStaged, 0)

        let generationReceipt = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)
        XCTAssertEqual(generationReceipt.generation, 0)

        let snapshot = try await scope.openSnapshot(rootID: rootID)
        XCTAssertEqual(snapshot.generation, 0)
        let page = try await snapshot.page(offset: 0, limit: 10)
        XCTAssertEqual(page.files.count, 2)
        XCTAssertEqual(page.returnedCount, 2)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(Set(page.files.map(\.name)), Set(["App.swift", "README.md"]))

        // Ingest: apply a delta adding a third file.
        let event = CoreInventoryAppliedIndexBatchEventV1(
            rootID: rootID,
            upsertedFiles: [sampleFile(id: UUID(), rootID: rootID, name: "Extra.swift", relativePath: "Extra.swift")],
            upsertedFolders: [],
            removedFileIDs: [],
            removedFolderIDs: [],
            removedFilePaths: [],
            removedFolderPaths: [],
            modifiedFileIDs: [],
            modifiedFolderIDs: []
        )
        let deltaReceipt = try await scope.applyDelta(.init(
            rootID: rootID,
            rootLifetimeID: rootLifetimeID,
            source: "test",
            event: event
        ))
        switch deltaReceipt.outcome {
        case .patched, .rebuiltAuthoritative: break
        case let .rejected(reason): XCTFail("unexpected rejection: \(reason)")
        }

        let diagnostics = try await scope.diagnostics()
        XCTAssertEqual(diagnostics.roots.count, 1)
        XCTAssertGreaterThanOrEqual(diagnostics.roots[0].buildCount, 2)

        // The old snapshot handle keeps seeing its own frozen generation after the delta.
        let oldPage = try await snapshot.page(offset: 0, limit: 10)
        XCTAssertEqual(oldPage.files.count, 2, "an already-open handle is unaffected by a later mutation")

        await snapshot.close()
        await snapshot.close() // idempotent

        let unloadFinalGeneration = try await scope.closeRoot(rootID: rootID, rootLifetimeID: rootLifetimeID)
        XCTAssertEqual(unloadFinalGeneration, 1)

        await scope.close()
        await scope.close() // idempotent

        _ = try await bridge.close()
    }

    func testStaleWatermarkDeltaIsABusinessOutcomeNotAThrownError() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")

        func makeEvent() -> CoreInventoryAppliedIndexBatchEventV1 {
            CoreInventoryAppliedIndexBatchEventV1(
                rootID: rootID,
                upsertedFiles: [sampleFile(id: UUID(), rootID: rootID, name: "A.swift", relativePath: "A.swift")],
                upsertedFolders: [],
                removedFileIDs: [],
                removedFolderIDs: [],
                removedFilePaths: [],
                removedFolderPaths: [],
                modifiedFileIDs: [],
                modifiedFolderIDs: []
            )
        }

        let first = try await scope.applyDelta(.init(
            rootID: rootID,
            rootLifetimeID: rootLifetimeID,
            watcherAcceptedWatermark: 100,
            source: "watcher",
            event: makeEvent()
        ))
        if case .rejected = first.outcome { XCTFail("first delta should be admitted") }

        let stale = try await scope.applyDelta(.init(
            rootID: rootID,
            rootLifetimeID: rootLifetimeID,
            watcherAcceptedWatermark: 50,
            source: "watcher",
            event: makeEvent()
        ))
        guard case let .rejected(reason) = stale.outcome else {
            return XCTFail("stale watermark delta should be rejected as a business outcome")
        }
        XCTAssertTrue(reason.contains("staleWatermark") || reason.lowercased().contains("stale"), "unexpected reason: \(reason)")

        await scope.close()
        _ = try await bridge.close()
    }

    func testClosingRootInvalidatesOpenHandlesAsATypedErrorNotAPanic() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: rootLifetimeID)
        _ = try await scope.pushBulkChunk(
            bulkLoadID: bulkLoadID,
            rootID: rootID,
            files: [sampleFile(id: UUID(), rootID: rootID, name: "A.swift", relativePath: "A.swift")],
            folders: []
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)
        let snapshot = try await scope.openSnapshot(rootID: rootID)

        _ = try await scope.closeRoot(rootID: rootID, rootLifetimeID: rootLifetimeID)

        do {
            _ = try await snapshot.page(offset: 0, limit: 10)
            XCTFail("expected a handle-invalidated error after the owning root closed")
        } catch let CoreBridgeError.inventoryHandleInvalidated(reason) {
            XCTAssertEqual(reason, .rootClosed)
        }

        await scope.close()
        _ = try await bridge.close()
    }
}
