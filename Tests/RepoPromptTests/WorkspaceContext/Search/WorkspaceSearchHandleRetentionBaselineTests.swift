@testable import RepoPromptApp
import XCTest

/// P4-7b §4.5/§9 (phase b2, ordered ahead of any handle-vending exercise per the design's own
/// caution: capture the pre-flip baseline *before* introducing retention, not after). Records, on
/// unmodified-behavior code (nothing in this suite calls `searchRootQueryHandles` inside the
/// storm), two numbers over a fixed edit-storm fixture:
///
/// 1. `retentionBoundary` fallback occurrences -- the rate b3's done-when requires *not increase*
///    over (§4.5's "test that fails on any increase over the b2 baseline"). Expected `0` today:
///    nothing in the current search path opens a Rust snapshot handle repeatedly, so there is
///    nothing to apply retention pressure. This assertion is the recorded baseline, not a
///    tautology -- it is what changes (or doesn't) once b3 wires `searchRootQueryHandles` into the
///    hot path.
/// 2. `patchApplicationBackstop` occurrences -- reported per RK-5, kept as a *separate* number from
///    the SLO precisely so Bucket-B's independent regression (contract doc §12.3/§9b) is never
///    conflated with a P4-7b retention effect. Not gated to a specific count (Bucket-B's rate is
///    out of scope for this campaign to fix or pin) -- only bounded and captured as documented
///    evidence.
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
    /// -- the only requirement any real caller uses post-flip -- which still exercises the identical
    /// shard patch/rebuild/fallback-counting machinery this baseline measures; `requirement` only
    /// gates whether `composeSearchCatalogSnapshot` unwraps `shard.pathSearchIndex`, not whether the
    /// shard is built, patched, or counted.
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
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: true)
        let root = try makeTestDirectory(name: "HandleRetentionBaselineEditStorm")
        try write("seed", to: root.appendingPathComponent("Seed.swift"))
        let record = try await store.loadRoot(path: root.path)
        // Stops the live FSEvents watcher so this storm's manually-replayed deltas
        // (`replayObservedFileSystemDeltas`) are the *only* delta stream the store observes --
        // matching `WorkspaceCatalogShardTests.loadStoppedRoot`'s pattern. Without this, the real
        // watcher observing the same on-disk writes this storm makes races the manual replay,
        // producing spurious unsafe/ambiguous-batch fallbacks that authoritatively rebuild on
        // every iteration and mask the patch path entirely -- the first draft of this baseline hit
        // exactly that (`patchCount == 0` over the whole storm), which is why this call is here.
        await store.stopWatchingRoot(id: record.id)

        // Storm size chosen to be well past `maxRootCatalogShardPatchLogicalMutationCount` (1 at
        // the only call site today, per `WorkspaceInventoryCatalogBuilders`' doc comment) many
        // times over, so the storm exercises both the patch and rebuild paths repeatedly, matching
        // the "edit-storm" shape RK-5/§4.5 describe rather than a single mutation.
        try await runEditStorm(store: store, rootID: record.id, rootURL: root, iterationCount: 40)

        let diagnostics = await store.storeWorkDiagnosticsSnapshot()
        let shard = try XCTUnwrap(
            diagnostics.rootCatalogShards.roots.first { $0.rootID == record.id },
            "expected shard diagnostics for the storm's root"
        )

        let retentionBoundaryCount = shard.fallbackReasonCounts[.retentionBoundary] ?? 0
        let patchApplicationBackstopCount = shard.fallbackReasonCounts[.patchApplicationBackstop] ?? 0

        // Fixture sanity: a baseline over a storm that never reaches the patch path measures
        // nothing (the exact §4.7 failure mode -- an assertion that reads as passing while proving
        // nothing -- this document elsewhere warns against). This storm must genuinely patch.
        XCTAssertGreaterThan(shard.patchCount, 0, "fixture sanity: this storm must exercise the patch path")

        // The b2 baseline this suite exists to record. If this ever goes non-zero on unmodified
        // pre-b3 code, something else in the tree has started retaining Rust snapshot handles
        // across this storm -- worth investigating on its own, not folded into P4-7b's numbers.
        XCTAssertEqual(
            retentionBoundaryCount, 0,
            "P4-7b b2 baseline: retentionBoundary must be 0 before any handle-vending is wired into the hot path"
        )

        // Reported, not gated (RK-5): Bucket-B's rate is this storm's own independent number,
        // captured here so a later b3/b4 read can cite it without re-deriving it. Bounded by the
        // storm size only so a totally unrelated regression (every single delta backstopping) is
        // still caught as a build-breaking signal rather than silently accepted.
        XCTAssertLessThanOrEqual(
            patchApplicationBackstopCount, 40,
            "patchApplicationBackstop count is bounded by the storm's own iteration count"
        )
        #if DEBUG
            // Not asserted against a literal -- Bucket-B's exact rate is explicitly out of scope
            // to pin (design doc §10) -- printed so the number is visible in the test log for the
            // commit message / contract doc amendment to cite.
            print(
                "P4-7b b2 baseline (pre-handle-vending): retentionBoundary=\(retentionBoundaryCount) " +
                    "patchApplicationBackstop=\(patchApplicationBackstopCount) " +
                    "authoritativeRebuildCount=\(shard.authoritativeRebuildCount) patchCount=\(shard.patchCount)"
            )
        #endif
    }

    /// Confirms `searchRootQueryHandles` itself -- exercised, but only opened once per generation
    /// and never repeatedly within one -- does not move the baseline either. This is the b2-side
    /// half of the ordering the design calls for: prove the vending method is inert against this
    /// exact storm before b3 wires it into the always-subscribed hot path.
    func testRetentionBoundaryUnaffectedByOptInHandleVendingAcrossTheSameStorm() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: true)
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
        XCTAssertGreaterThan(shard.patchCount, 0, "fixture sanity: this storm must actually exercise the patch path, or retentionBoundary=0 would measure nothing (the mistake this suite's header doc records and corrects)")
        XCTAssertEqual(
            shard.fallbackReasonCounts[.retentionBoundary] ?? 0, 0,
            "opening-and-dropping a handle per generation (b2's shape) must not itself trip retention pressure"
        )
    }
}
