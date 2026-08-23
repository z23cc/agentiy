@testable import AgentryCoreBridge
import Foundation
import XCTest

/// P4-5: the shadow arm + differential (design doc
/// `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §8.2). Three things live here
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
/// 3. §8.2's "out-of-order watermarks" scenario, driven end-to-end through the real bridge: an
///    admitted delta, a stale (out-of-order) rejection that must not mutate table state, a
///    full-resync-flagged delta that bypasses the gate on a *lower* watermark, and a follow-up
///    delta proving the tracked baseline advanced via `max()` rather than regressing -- the same
///    contract `ingress_gate.rs` unit-proves against the bare gate struct, re-proven here through
///    the full Swift -> FFI -> Rust round trip.
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
        // P4-7b §4.2: the wire's `tie_break_key` field (widened stride, decoded here through the
        // full Swift -> FFI -> Rust round trip) must resolve to non-empty subject text for every
        // candidate -- a stride/field misalignment would decode empty strings or throw, not pass
        // silently. It is deliberately NOT asserted equal to `displayPath + "\n" + standardizedFullPath`
        // here: this call's prefix arguments are empty, so the wire's caller-composed `displayPath`
        // diverges from the index's own stored subject text (§1.5 Check A) -- that equality is
        // pinned against the index's real composition in the Rust-side
        // `index_key_query_tie_break_key_matches_the_indexs_own_subject_text_over_adversarial_entries`.
        XCTAssertFalse(result.candidates.contains { $0.tieBreakKey.isEmpty })

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

    // MARK: - Adversarial watermark sequencing (§8.2 item 3: "out-of-order watermarks")
    //
    // `WorkspaceInventoryScopeShadowTests.swift` (the store-integration half of the gate) cannot
    // exercise this: `WorkspaceInventoryScopeShadowForwarder.apply` always forwards
    // `watcherAcceptedWatermark: nil` -- Swift's own FSEvents watermark gating stays entirely in
    // Swift per design doc §4.2 and never crosses the FFI, so there is no Swift-side table to
    // diverge against. What's untested end-to-end is whether `IngressGateState`'s contract
    // (`rust/crates/runtime/src/inventory_scope/ingress_gate.rs`, unit-proven by
    // `full_resync_bypasses_watermark_check_and_advances_baseline_via_max`) survives the real
    // Swift -> FFI -> Rust round trip through `CoreInventoryScope.applyDelta`, not just the bare
    // gate struct in isolation. This is that same sequence, driven through the full bridge.
    func testOutOfOrderWatermarkSequenceInterleavedWithFullResyncMatchesTheIngressGateContractThroughTheBridge() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")

        func makeEvent(_ name: String) -> CoreInventoryAppliedIndexBatchEventV1 {
            CoreInventoryAppliedIndexBatchEventV1(
                rootID: rootID,
                upsertedFiles: [sampleFile(id: UUID(), rootID: rootID, name: name, relativePath: name)],
                upsertedFolders: [], removedFileIDs: [], removedFolderIDs: [],
                removedFilePaths: [], removedFolderPaths: [], modifiedFileIDs: [], modifiedFolderIDs: []
            )
        }

        // 1. Baseline admitted at watermark 100.
        let first = try await scope.applyDelta(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID,
            watcherAcceptedWatermark: 100, source: "watcher", event: makeEvent("First.swift")
        ))
        if case .rejected = first.outcome { XCTFail("first delta at watermark 100 should be admitted") }

        // 2. Out-of-order: a lower watermark than the last-applied baseline is rejected, and must
        //    not mutate table state -- the rejection is a pure no-op, not a partial apply.
        let outOfOrder = try await scope.applyDelta(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID,
            watcherAcceptedWatermark: 50, source: "watcher", event: makeEvent("OutOfOrder.swift")
        ))
        guard case let .rejected(reason) = outOfOrder.outcome else {
            return XCTFail("watermark 50 after baseline 100 should be rejected as out-of-order")
        }
        XCTAssertTrue(reason.lowercased().contains("stale"), "unexpected reason: \(reason)")

        let snapshotAfterRejection = try await scope.openSnapshot(rootID: rootID)
        let pageAfterRejection = try await snapshotAfterRejection.page(offset: 0, limit: 10)
        XCTAssertEqual(pageAfterRejection.files.count, 1, "a rejected delta must not mutate table state")
        XCTAssertFalse(pageAfterRejection.files.contains { $0.name == "OutOfOrder.swift" })
        await snapshotAfterRejection.close()

        // 3. A full-resync-flagged delta bypasses the watermark check even carrying a *lower*
        //    watermark than the tracked baseline (rule 3: pressure collapse must always pass) --
        //    and the baseline advances via max(), not replacement.
        let resync = try await scope.applyDelta(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID,
            watcherAcceptedWatermark: 30, requiresFullResync: true, source: "watcher",
            event: makeEvent("Resync.swift")
        ))
        if case .rejected = resync.outcome { XCTFail("a requiresFullResync delta must bypass the watermark gate unconditionally") }

        // 4. The baseline is still 100 (max(100, 30)), not 30 -- a subsequent watermark of 80 must
        //    still be rejected as stale against the *preserved* baseline, proving the resync's
        //    lower watermark did not wrongly regress the tracked sequence.
        let stillStale = try await scope.applyDelta(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID,
            watcherAcceptedWatermark: 80, source: "watcher", event: makeEvent("StillStale.swift")
        ))
        guard case .rejected = stillStale.outcome else {
            return XCTFail("watermark 80 must still be rejected -- the resync's lower watermark must not have regressed the baseline")
        }

        // 5. A genuinely advancing watermark (150) is admitted, proving the gate recovered
        //    cleanly rather than wedging shut.
        let recovered = try await scope.applyDelta(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID,
            watcherAcceptedWatermark: 150, source: "watcher", event: makeEvent("Recovered.swift")
        ))
        if case .rejected = recovered.outcome { XCTFail("watermark 150 should be admitted -- the gate must recover after a resync") }

        await scope.close()
        _ = try await bridge.close()
    }
}
