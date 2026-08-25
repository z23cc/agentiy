@testable import RepoPromptApp
import XCTest

/// P4-7b §4.7 (phase b4) -- the never-landed P4-6b co-location gate, finally passable and landed
/// here. Design doc §4.1.0's invariant: "no build may ever ship in which the inventory tables are
/// in Rust and the search index that reads them is in Swift." This is the behavioral half of that
/// gate; the mechanical half is `Scripts/source_layout_guardrails.sh`'s P4-7b §4.1.0 section
/// (asserts `makeRootPathSearchIndex` never returns and `WorkspaceSearchService` never constructs
/// a Swift path index outside its DEBUG-only ground-truth helper).
///
/// §4.7's own done-when is explicit that this is *not* "zero `fetchFileTreePageIndex`
/// invocations" -- the page-through survives for other shard consumers (§1.2.1) -- so this suite
/// does not assert anything about page-through call counts, only about Swift path-index
/// *construction* during a search-driven catalog generation.
///
/// This suite's history is worth stating plainly rather than leaving implicit, because it took
/// three attempts to land honestly. Draft 1 asserted a dedicated
/// `WorkspaceSearchService.debugPathIndexConstructionCount` instance counter; that counter had no
/// code path anywhere in the actor's instance-level surface that could ever increment it, so the
/// assertion was `0 == 0` by construction -- vacuous. Draft 2 switched to the store's
/// `pathIndexBuildCount`/`overlayPathIndexBuildCount` shard diagnostics, reasoning that
/// `registerPublishedRootCatalogShard` -- their one live increment site -- funnels every shard
/// publication through it; a live test run disproved this: `WorkspaceSearchService`'s post-b3
/// production path (`searchRootQueryHandles` -> `authority.openSnapshot`) never touches the shard
/// system at all (the store's own comment: "keep catalog publication fully lazy until a caller
/// requests a catalog capability"), so `rootCatalogShards.roots` is empty throughout this suite's
/// scenarios and the sum is 0 for the trivial reason -- vacuous again, just for a different
/// structural cause than draft 1.
///
/// The honest conclusion, landed here as draft 3: §4.7's "zero Swift path-index constructions" is
/// a *structural* property post-b3, not a runtime quantity -- there is no construction site left in
/// the service's own code to instrument, by design. `Scripts/source_layout_guardrails.sh`'s grep is
/// the actual enforcement, exercised on every invocation. What this suite adds on top, honestly:
/// (1) correct results through every shape a search-driven catalog generation takes (cold rebuild,
/// non-empty query, empty query, live event-driven rebuild) -- real coverage of the flipped path,
/// not a construction check; (2) `discardedQueryErrorCount` (§4.6, incremented by
/// `handleQueryInvalidation`/`handleQueryTransportFailure` on the live query path) stays 0 across
/// all four shapes, distinguishing "search returned results" from "search silently degraded and
/// returned results anyway" -- the one instrumentation point the flipped path actually has; and
/// (3) a blunt backstop noted for the record rather than exercised here: a regression that made the
/// service request the retired `.recordsAndPathIndexes` capability again would `preconditionFailure`
/// in `composeSearchCatalogSnapshot` (D-14) -- unmissable, if not a clean assertion.
final class WorkspaceSearchColocationGateTests: XCTestCase {
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

    func testSearchDrivenCatalogGenerationConstructsZeroSwiftPathIndexes() async throws {
        let store = WorkspaceFileContextStore()
        let root = try makeTestDirectory(name: "ColocationGate")
        try write("alpha", to: root.appendingPathComponent("Sources/Alpha.swift"))
        try write("beta", to: root.appendingPathComponent("Sources/Beta.swift"))
        let record = try await store.loadRoot(path: root.path)

        let service = WorkspaceSearchService()
        var discardedErrorCount = await service.discardedQueryErrorCount
        XCTAssertEqual(discardedErrorCount, 0)

        // Cold rebuild.
        _ = await service.rebuildIndex(from: store, rootScope: .visibleWorkspace)
        discardedErrorCount = await service.discardedQueryErrorCount
        XCTAssertEqual(discardedErrorCount, 0, "cold rebuild must not silently discard a query error")

        // Non-empty query (per-root `inventoryQuery(.indexKey)`, merged in Swift -- §4.4).
        let nonEmpty = await service.search("Alpha", limit: 10)
        XCTAssertFalse(nonEmpty.results.isEmpty)
        discardedErrorCount = await service.discardedQueryErrorCount
        XCTAssertEqual(discardedErrorCount, 0, "a non-empty query must not silently discard a query error")

        // Empty query (per-root `inventorySnapshotPage`, merged in Swift -- §4.2.1).
        let empty = await service.search("", limit: 10)
        XCTAssertFalse(empty.results.isEmpty)
        discardedErrorCount = await service.discardedQueryErrorCount
        XCTAssertEqual(discardedErrorCount, 0, "an empty query must not silently discard a query error")

        // Live, event-driven rebuild -- the shape a real search-driven catalog generation takes
        // in production (`startKeepingFresh` -> `appliedIndexEvents()` -> `scheduleRebuild` ->
        // `rebuildFromStoreIfCurrent`), not just the explicit one-shot `rebuildIndex` call above.
        await service.startKeepingFresh(with: store, debounceNanoseconds: 0)
        try write("gamma", to: root.appendingPathComponent("Sources/Gamma.swift"))
        await store.replayObservedFileSystemDeltas(rootID: record.id, deltas: [.fileAdded("Sources/Gamma.swift")])
        let expectedGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
        let deadline = Date().addingTimeInterval(2)
        var reachedGeneration = await service.indexedGeneration
        while Date() < deadline, reachedGeneration != expectedGeneration {
            try await Task.sleep(nanoseconds: 10_000_000)
            reachedGeneration = await service.indexedGeneration
        }
        XCTAssertEqual(reachedGeneration, expectedGeneration, "live rebuild did not reach the target generation in time")
        discardedErrorCount = await service.discardedQueryErrorCount
        XCTAssertEqual(discardedErrorCount, 0, "a live, event-driven rebuild must not silently discard a query error")

        let gammaResult = await service.search("Gamma", limit: 10)
        XCTAssertEqual(gammaResult.results.map(\.standardizedRelativePath), ["Sources/Gamma.swift"])
        discardedErrorCount = await service.discardedQueryErrorCount
        XCTAssertEqual(discardedErrorCount, 0)
    }
}
