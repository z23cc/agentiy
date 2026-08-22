@testable import AgentryCoreBridge
import Foundation
import XCTest

/// P4-4b end-to-end bridge test: `CoreInventoryScope.events()` against the real Rust
/// `InventoryScope` through the full UniFFI round trip (not `FakeCoreTransport`) -- the
/// Swift-side counterpart to `agentry_ffi::api::tests::
/// inventory_scope_events_flow_through_the_generic_subscription_surface` and
/// `inventory_scope_overflow_produces_a_gap_then_a_fresh_snapshot_still_recovers`. Exercises the
/// exact same fixed `AgentryCoreBridge.openSubscription` registration-order path every other
/// subscription consumer uses (83f848b2's lesson) -- `events()` does not re-derive it.
/// Drains a `CoreInventoryScopeEventStream` in the background into a plain array, polled by the
/// test with a bounded total wait -- a genuine delivery problem (wake-pipe race, actor deadlock)
/// then fails the test fast and legibly instead of hanging the whole run indefinitely. A single
/// task owns the `AsyncIterator` for the stream's whole lifetime, avoiding the hazard of copying
/// an iterator across concurrency boundaries.
private actor CoreInventoryScopeEventCollector {
    private(set) var events: [CoreInventoryScopeEvent] = []
    private(set) var finished = false
    private(set) var failure: (any Error)?

    func run(_ stream: CoreInventoryScopeEventStream) async {
        do {
            for try await event in stream {
                events.append(event)
            }
        } catch {
            failure = error
        }
        finished = true
    }

    /// Polls until at least `count` events have arrived, the stream ends, or `timeoutSeconds`
    /// elapses -- whichever comes first.
    func waitForAtLeast(_ count: Int, timeoutSeconds: Double) async throws -> [CoreInventoryScopeEvent] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while events.count < count, !finished, Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        if let failure { throw failure }
        return events
    }

    /// Polls until any collected event matches `predicate`, the stream ends, or `timeoutSeconds`
    /// elapses.
    func waitUntil(
        timeoutSeconds: Double,
        matching predicate: @Sendable (CoreInventoryScopeEvent) -> Bool
    ) async throws -> CoreInventoryScopeEvent? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let match = events.first(where: predicate) { return match }
            if finished { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        if let failure { throw failure }
        return events.first(where: predicate)
    }
}

final class CoreInventoryScopeEventsTests: XCTestCase {
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

    private func fullResyncEvent(rootID: UUID, fileID: UUID, name: String) -> CoreInventoryAppliedIndexBatchEventV1 {
        CoreInventoryAppliedIndexBatchEventV1(
            rootID: rootID,
            upsertedFiles: [sampleFile(id: fileID, rootID: rootID, name: name, relativePath: name)],
            upsertedFolders: [],
            removedFileIDs: [],
            removedFolderIDs: [],
            removedFilePaths: [],
            removedFolderPaths: [],
            modifiedFileIDs: [],
            modifiedFolderIDs: []
        )
    }

    func testEventsFlowThroughTheRealBridgeSubscriptionSurface() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let scope = try await CoreInventoryScope.open(bridge: bridge)

        // Subscribe before any mutation, exactly like the Rust FFI test, so nothing publishes
        // before the queue exists.
        let stream = try await scope.events()

        let rootID = UUID()
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        let fileID = UUID()
        let deltaReceipt = try await scope.applyDelta(.init(
            rootID: rootID,
            rootLifetimeID: rootLifetimeID,
            requiresFullResync: true,
            source: "test",
            event: fullResyncEvent(rootID: rootID, fileID: fileID, name: "A.swift")
        ))
        switch deltaReceipt.outcome {
        case .rebuiltAuthoritative: break
        default: XCTFail("fresh root + full resync must rebuild")
        }

        // open_root -> rootPublished; apply_delta (fresh root, full resync) -> shardFallback,
        // generationAdvanced, appliedIndexBatch.
        let collector = CoreInventoryScopeEventCollector()
        let collectorTask = Task { await collector.run(stream) }
        let seen = try await collector.waitForAtLeast(4, timeoutSeconds: 20)
        XCTAssertEqual(seen.count, 4, "timed out waiting for events to arrive over the real wake-pipe/subscription path")

        guard case let .rootPublished(rootPublished) = seen[0] else {
            return XCTFail("expected rootPublished first, got \(seen[0])")
        }
        XCTAssertEqual(rootPublished.rootID, rootID)
        XCTAssertEqual(rootPublished.rootLifetimeID, rootLifetimeID)

        guard case let .shardFallback(fallback) = seen[1] else {
            return XCTFail("expected shardFallback second, got \(seen[1])")
        }
        XCTAssertEqual(fallback.rootID, rootID)
        XCTAssertEqual(fallback.reason, .fullResync)

        guard case let .generationAdvanced(advanced) = seen[2] else {
            return XCTFail("expected generationAdvanced third, got \(seen[2])")
        }
        XCTAssertEqual(advanced.rootID, rootID)
        XCTAssertEqual(advanced.rootLifetimeID, rootLifetimeID)
        XCTAssertEqual(advanced.appliedIndexGeneration, deltaReceipt.appliedIndexGeneration)
        XCTAssertEqual(advanced.catalogGeneration, deltaReceipt.catalogGeneration)
        XCTAssertTrue(advanced.rebuiltAuthoritative)
        XCTAssertEqual(advanced.upsertedCount, 1)

        guard case let .appliedIndexBatch(batch) = seen[3] else {
            return XCTFail("expected appliedIndexBatch fourth, got \(seen[3])")
        }
        XCTAssertEqual(batch.rootID, rootID)
        XCTAssertEqual(batch.upsertedFiles.map(\.name), ["A.swift"])

        collectorTask.cancel()
        try await stream.close()
        await scope.close()
        _ = try await bridge.close()
    }

    func testOverflowProducesAGapThenAFreshSnapshotStillRecovers() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        // A deliberately tiny queue (`maxQueuedEvents: 2`; `reservedTerminalSlots` reserves 1, so
        // exactly 1 usable data-plane slot): the real bridge's `wakeFired()` drains the Rust hub
        // queue continuously in the background, so racing a slow, sequentially-awaited mutation
        // loop against real-time draining is not deterministic (a fast enough drain never lets
        // the queue back up at all). A single `apply_delta` publishes its 3 non-lossless events
        // (shardFallback, generationAdvanced, appliedIndexBatch) back-to-back inside one
        // synchronous Rust call, with no Swift-observable suspension point in between -- against a
        // 1-slot budget that burst alone deterministically evicts/gaps at least 2 of the 3,
        // regardless of drain timing.
        let stream = try await scope.events(maxQueuedEvents: 2, maxQueuedBytes: 1_048_576)

        let rootID = UUID()
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        let fileID = UUID()
        _ = try await scope.applyDelta(.init(
            rootID: rootID,
            rootLifetimeID: rootLifetimeID,
            requiresFullResync: true,
            source: "test",
            event: fullResyncEvent(rootID: rootID, fileID: fileID, name: "f.swift")
        ))
        let lastRootID = rootID
        let lastFileID = fileID

        // Drain until a gap marker appears, the stream ends, or a bounded timeout elapses --
        // never an unbounded loop.
        let collector = CoreInventoryScopeEventCollector()
        let collectorTask = Task { await collector.run(stream) }
        let gapEvent = try await collector.waitUntil(timeoutSeconds: 30) { event in
            if case .gap = event { return true }
            return false
        }
        guard case let .gap(droppedCount) = gapEvent else {
            return XCTFail("expected a gap marker from the 1-slot-budget burst, got \(String(describing: gapEvent))")
        }
        XCTAssertGreaterThan(droppedCount, 0)
        collectorTask.cancel()

        // Resnapshot recovery (contract doc §5b): a fresh `openSnapshot` against the last root
        // touched must still serve current, correct data -- the gap does not poison the scope
        // itself, only the stale event-stream projection.
        let snapshot = try await scope.openSnapshot(rootID: lastRootID)
        let page = try await snapshot.page(offset: 0, limit: 10)
        XCTAssertEqual(page.files.count, 1)
        XCTAssertEqual(page.files.first?.id, lastFileID)
        XCTAssertEqual(page.files.first?.name, "f.swift")
        await snapshot.close()

        try await stream.close()
        await scope.close()
        _ = try await bridge.close()
    }
}
