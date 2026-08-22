@testable import AgentryCoreBridge
import Foundation
import XCTest

/// P4-5: the shadow arm + differential (design doc
/// `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §8.2). Two things live here
/// that `CoreInventoryScopeTests`/`CoreInventoryScopeEventsTests` (P4-4/P4-4b) don't already cover:
///
/// 1. `inventoryQuery` -- the Swift facade completion this step adds (the FFI export and Rust wire
///    codec already existed; only the Swift-side facade/codec were missing, per
///    `CoreInventoryScope.swift`'s "do not yet have Swift facade methods" note).
/// 2. The remaining named adversarial delta-sequence scenarios from §8.2's coverage list not
///    already exercised by P4-4's tests: `generationGap` and `lifetimeMismatch` typed rejections
///    (`staleWatermark` and overflow -> gap -> resnapshot are already covered by
///    `CoreInventoryScopeTests.testStaleWatermarkDeltaIsABusinessOutcomeNotAThrownError` and
///    `CoreInventoryScopeEventsTests.testOverflowProducesAGapThenAFreshSnapshotStillRecovers`).
final class CoreInventoryScopeShadowDifferentialTests: XCTestCase {
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

    // MARK: - inventoryQuery facade completion

    func testQueryReturnsOrderedCandidatesMatchingTheBulkLoadedFiles() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")

        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: rootLifetimeID)
        let files = [
            sampleFile(id: UUID(), rootID: rootID, name: "App.swift", relativePath: "App.swift"),
            sampleFile(id: UUID(), rootID: rootID, name: "README.md", relativePath: "README.md"),
            sampleFile(id: UUID(), rootID: rootID, name: "Utils.swift", relativePath: "src/Utils.swift"),
        ]
        _ = try await scope.pushBulkChunk(bulkLoadID: bulkLoadID, rootID: rootID, files: files, folders: [])
        _ = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)

        let snapshot = try await scope.openSnapshot(rootID: rootID)
        let result = try await snapshot.query(
            pattern: "*.swift",
            limit: 10,
            haystackVariant: .indexKey,
            nonEmptyRelativePrefix: "",
            emptyRelativePathValue: ""
        )
        XCTAssertEqual(result.generation, 0)
        XCTAssertEqual(Set(result.candidates.map(\.standardizedRelativePath)), Set(["App.swift", "src/Utils.swift"]))
        XCTAssertFalse(result.candidates.contains { $0.standardizedRelativePath == "README.md" })

        // The empty query is the whole-catalog merge order -- every record comes back.
        let emptyQueryResult = try await snapshot.query(
            pattern: "",
            limit: 10,
            haystackVariant: .indexKey,
            nonEmptyRelativePrefix: "",
            emptyRelativePathValue: ""
        )
        XCTAssertEqual(emptyQueryResult.candidates.count, 3)

        await snapshot.close()
        await scope.close()
        _ = try await bridge.close()
    }

    func testQueryAgainstAnInvalidatedHandleIsATypedErrorNotAPanic() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: rootLifetimeID)
        _ = try await scope.pushBulkChunk(
            bulkLoadID: bulkLoadID, rootID: rootID,
            files: [sampleFile(id: UUID(), rootID: rootID, name: "A.swift", relativePath: "A.swift")], folders: []
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)
        let snapshot = try await scope.openSnapshot(rootID: rootID)

        _ = try await scope.closeRoot(rootID: rootID, rootLifetimeID: rootLifetimeID)

        do {
            _ = try await snapshot.query(pattern: "*", limit: 10, haystackVariant: .indexKey, nonEmptyRelativePrefix: "", emptyRelativePathValue: "")
            XCTFail("expected a handle-invalidated error after the owning root closed")
        } catch let CoreBridgeError.inventoryHandleInvalidated(reason) {
            XCTAssertEqual(reason, .rootClosed)
        }

        await scope.close()
        _ = try await bridge.close()
    }

    // MARK: - Adversarial delta sequences (§8.2 coverage set, the two named scenarios not already
    // exercised by P4-4's tests)

    func testGenerationGapDeltaIsRejectedAsATypedBusinessOutcome() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")

        func makeEvent() -> CoreInventoryAppliedIndexBatchEventV1 {
            CoreInventoryAppliedIndexBatchEventV1(
                rootID: rootID,
                upsertedFiles: [sampleFile(id: UUID(), rootID: rootID, name: "A.swift", relativePath: "A.swift")],
                upsertedFolders: [], removedFileIDs: [], removedFolderIDs: [],
                removedFilePaths: [], removedFolderPaths: [], modifiedFileIDs: [], modifiedFolderIDs: []
            )
        }

        let first = try await scope.applyDelta(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID,
            expectedAppliedIndexGeneration: 0, source: "test", event: makeEvent()
        ))
        if case .rejected = first.outcome { XCTFail("first delta at the correct expected generation should be admitted") }

        // Skips ahead of the scope's own counter -- a generation gap.
        let gapped = try await scope.applyDelta(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID,
            expectedAppliedIndexGeneration: 5, source: "test", event: makeEvent()
        ))
        guard case let .rejected(reason) = gapped.outcome else {
            return XCTFail("a generation-gapped expectation should be rejected as a business outcome, not silently admitted")
        }
        XCTAssertTrue(
            reason.lowercased().contains("generation"),
            "expected a generationGap-flavored rejection reason, got: \(reason)"
        )

        await scope.close()
        _ = try await bridge.close()
    }

    func testStaleLifetimeIDDeltaIsRejectedAsATypedBusinessOutcome() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let firstLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        _ = try await scope.closeRoot(rootID: rootID, rootLifetimeID: firstLifetimeID)
        // Reopening the same rootID mints a fresh lifetime, exactly as a Swift root reload/re-add
        // would -- the shadow forwarder's `openRootIfNeeded` re-open-on-lifetime-change path.
        let secondLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        XCTAssertNotEqual(firstLifetimeID, secondLifetimeID)

        let event = CoreInventoryAppliedIndexBatchEventV1(
            rootID: rootID,
            upsertedFiles: [sampleFile(id: UUID(), rootID: rootID, name: "A.swift", relativePath: "A.swift")],
            upsertedFolders: [], removedFileIDs: [], removedFolderIDs: [],
            removedFilePaths: [], removedFolderPaths: [], modifiedFileIDs: [], modifiedFolderIDs: []
        )
        let staleReceipt = try await scope.applyDelta(.init(
            rootID: rootID, rootLifetimeID: firstLifetimeID, source: "test", event: event
        ))
        guard case let .rejected(reason) = staleReceipt.outcome else {
            return XCTFail("a delta carrying the pre-reopen lifetime id should be rejected, not admitted")
        }
        XCTAssertTrue(
            reason.lowercased().contains("lifetime"),
            "expected a lifetimeMismatch-flavored rejection reason, got: \(reason)"
        )

        await scope.close()
        _ = try await bridge.close()
    }
}
