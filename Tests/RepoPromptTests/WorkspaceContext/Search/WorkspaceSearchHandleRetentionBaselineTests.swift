@testable import RepoPromptApp
import XCTest

/// P4-7b §4.5/§9 retention baseline, carried forward through P4-8b's retirement of the Swift
/// shard patch path. The fixed 40-event storm continues to prove that ordinary catalog refreshes
/// and open-then-drop Rust query handles do not trip `retentionBoundary`.
///
/// P4-8b additionally pins the compatibility diagnostics: every accepted event publishes through
/// the direct authoritative Rust snapshot path, while `patchCount`, `patchApplicationBackstop`, and
/// `patchThresholdExceeded` remain zero-valued tombstones.
final class WorkspaceSearchHandleRetentionBaselineTests: XCTestCase {
    private func makeTestDirectory(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The shared edit-storm fixture (b2 defines it; b3 re-runs the identical shape post-flip and
    /// compares against the numbers this test records). One file added per iteration, with an
    /// active `searchCatalogSnapshot(requirement: .recordsOnly)` read between each delta -- simulating
    /// `WorkspaceSearchService.startKeepingFresh`'s always-subscribed shape, the scenario in which
    /// handle retention pressure (post-b3) would show up if it were going to.
    ///
    /// P4-7b b3 update: originally requested `.recordsAndPathIndexes` (that was still the live,
    /// functional capability when this baseline was authored in b2). b3 deletes
    /// `makeRootPathSearchIndex` -- every shard's `pathSearchIndex` is now always nil -- so
    /// requesting `.recordsAndPathIndexes` now intentionally `preconditionFailure`s in
    /// `composeSearchCatalogSnapshot` (D-14: "`.recordsAndPathIndexes` unreachable", fail loud not
    /// silent, per §4.6's fallback policy applied to the read side too). Switched to `.recordsOnly`
    /// -- the only requirement any real caller uses post-flip -- which still exercises the same
    /// shard publication, fallback, and retention machinery this baseline measures.
    private func runEditStorm(
        store: WorkspaceFileContextStore,
        rootID: UUID,
        rootURL: URL,
        iterationCount: Int
    ) async throws {
        for index in 0 ..< iterationCount {
            let relativePath = String(format: "%04d-Storm.swift", index)
            try write("storm-\(index)", to: rootURL.appendingPathComponent(relativePath))
            await store.replayObservedFileSystemDeltas(rootID: rootID, deltas: [.fileAdded(relativePath)])
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace, requirement: .recordsOnly)
        }
    }

    func testRetentionBoundaryAndBackstopBaselineOverFixedEditStorm() async throws {
        let store = WorkspaceFileContextStore()
        let root = try makeTestDirectory(name: "HandleRetentionBaselineEditStorm")
        try write("seed", to: root.appendingPathComponent("Seed.swift"))
        let record = try await store.loadRoot(path: root.path)
        // Stop the live watcher so manually replayed deltas are the only event stream. Otherwise
        // duplicate real/manual events introduce unrelated unsafe/ambiguous fallbacks.
        await store.stopWatchingRoot(id: record.id)

        // Preserve the registered 40-event fixture so retention behavior remains comparable across
        // the P4-8b switch from patch publication to direct authoritative rebuilds.
        try await runEditStorm(store: store, rootID: record.id, rootURL: root, iterationCount: 40)

        let diagnostics = await store.storeWorkDiagnosticsSnapshot()
        let shard = try XCTUnwrap(
            diagnostics.rootCatalogShards.roots.first { $0.rootID == record.id },
            "expected shard diagnostics for the storm's root"
        )

        let retentionBoundaryCount = shard.fallbackReasonCounts[.retentionBoundary] ?? 0
        let patchApplicationBackstopCount = shard.fallbackReasonCounts[.patchApplicationBackstop] ?? 0
        let patchThresholdExceededCount = shard.fallbackReasonCounts[.patchThresholdExceeded] ?? 0

        XCTAssertGreaterThan(
            shard.authoritativeRebuildCount, 0,
            "fixture sanity: the storm must exercise authoritative shard publication"
        )
        XCTAssertEqual(shard.patchCount, 0)
        XCTAssertEqual(patchApplicationBackstopCount, 0)
        XCTAssertEqual(patchThresholdExceededCount, 0)

        // The b2 baseline this suite exists to record. If this ever goes non-zero on unmodified
        // pre-b3 code, something else in the tree has started retaining Rust snapshot handles
        // across this storm -- worth investigating on its own, not folded into P4-7b's numbers.
        XCTAssertEqual(
            retentionBoundaryCount, 0,
            "P4-7b b2 baseline: retentionBoundary must be 0 before any handle-vending is wired into the hot path"
        )

        #if DEBUG
            print(
                "P4-8b direct-rebuild baseline: retentionBoundary=\(retentionBoundaryCount) " +
                    "authoritativeRebuildCount=\(shard.authoritativeRebuildCount) patchCount=\(shard.patchCount)"
            )
        #endif
    }

    /// Confirms `searchRootQueryHandles` itself -- exercised, but only opened once per generation
    /// and never repeatedly within one -- does not move the baseline either. This is the b2-side
    /// half of the ordering the design calls for: prove the vending method is inert against this
    /// exact storm before b3 wires it into the always-subscribed hot path.
    func testRetentionBoundaryUnaffectedByOptInHandleVendingAcrossTheSameStorm() async throws {
        let store = WorkspaceFileContextStore()
        let root = try makeTestDirectory(name: "HandleRetentionBaselineEditStormWithVending")
        try write("seed", to: root.appendingPathComponent("Seed.swift"))
        let record = try await store.loadRoot(path: root.path)
        await store.stopWatchingRoot(id: record.id)

        for index in 0 ..< 40 {
            let relativePath = String(format: "%04d-Storm.swift", index)
            try write("storm-\(index)", to: root.appendingPathComponent(relativePath))
            await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded(relativePath)])
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace, requirement: .recordsOnly)
            // Open-then-drop immediately -- the b2 shape (no retained holder across iterations),
            // matching how the differential suite uses it, not b3's hold-per-generation policy.
            _ = await store.searchRootQueryHandles(rootScope: .visibleWorkspace)
        }

        let diagnostics = await store.storeWorkDiagnosticsSnapshot()
        let shard = try XCTUnwrap(diagnostics.rootCatalogShards.roots.first { $0.rootID == record.id })
        XCTAssertGreaterThan(shard.authoritativeRebuildCount, 0)
        XCTAssertEqual(shard.patchCount, 0)
        XCTAssertEqual(shard.fallbackReasonCounts[.patchApplicationBackstop] ?? 0, 0)
        XCTAssertEqual(shard.fallbackReasonCounts[.patchThresholdExceeded] ?? 0, 0)
        XCTAssertEqual(
            shard.fallbackReasonCounts[.retentionBoundary] ?? 0, 0,
            "opening-and-dropping a handle per generation (b2's shape) must not itself trip retention pressure"
        )
    }
}
