@testable import RepoPromptApp
import XCTest

/// P4-7b §4.7 (phase b4) -- the never-landed P4-6b co-location gate, finally passable and landed
/// here. Design doc §4.1.0's invariant: "no build may ever ship in which the inventory tables are
/// in Rust and the search index that reads them is in Swift." This is the behavioral half of that
/// gate; the mechanical half is `Scripts/source_layout_guardrails.sh`'s P4-7b §4.1.0 section
/// (asserts `makeRootPathSearchIndex` never returns and `WorkspaceSearchService` never constructs
/// a Swift path index outside its DEBUG-only ground-truth helper).
///
/// Distinct from "index accounting" as a *counter that exists* -- this suite is the counter
/// actually being exercised, across every shape a search-driven catalog generation can take
/// (cold rebuild, non-empty query, empty query, live event-driven rebuild), asserting it stays at
/// 0 throughout. §4.7's own done-when is explicit that this is *not* "zero
/// `fetchFileTreePageIndex` invocations" -- the page-through survives for other shard consumers
/// (§1.2.1) -- so this suite does not assert anything about page-through call counts, only about
/// Swift path-index *construction*.
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
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let root = try makeTestDirectory(name: "ColocationGate")
        try write("alpha", to: root.appendingPathComponent("Sources/Alpha.swift"))
        try write("beta", to: root.appendingPathComponent("Sources/Beta.swift"))
        let record = try await store.loadRoot(path: root.path)

        let service = WorkspaceSearchService()
        var constructionCount = await service.debugPathIndexConstructionCount
        XCTAssertEqual(constructionCount, 0)

        // Cold rebuild.
        _ = await service.rebuildIndex(from: store, rootScope: .visibleWorkspace)
        constructionCount = await service.debugPathIndexConstructionCount
        XCTAssertEqual(constructionCount, 0, "cold rebuild must not construct a Swift path index")

        // Non-empty query (per-root `inventoryQuery(.indexKey)`, merged in Swift -- §4.4).
        let nonEmpty = await service.search("Alpha", limit: 10)
        XCTAssertFalse(nonEmpty.results.isEmpty)
        constructionCount = await service.debugPathIndexConstructionCount
        XCTAssertEqual(constructionCount, 0, "a non-empty query must not construct a Swift path index")

        // Empty query (per-root `inventorySnapshotPage`, merged in Swift -- §4.2.1).
        let empty = await service.search("", limit: 10)
        XCTAssertFalse(empty.results.isEmpty)
        constructionCount = await service.debugPathIndexConstructionCount
        XCTAssertEqual(constructionCount, 0, "an empty query must not construct a Swift path index")

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
        constructionCount = await service.debugPathIndexConstructionCount
        XCTAssertEqual(constructionCount, 0, "a live, event-driven rebuild must not construct a Swift path index")

        let gammaResult = await service.search("Gamma", limit: 10)
        XCTAssertEqual(gammaResult.results.map(\.standardizedRelativePath), ["Sources/Gamma.swift"])
        constructionCount = await service.debugPathIndexConstructionCount
        XCTAssertEqual(constructionCount, 0)
    }
}
