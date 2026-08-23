@testable import RepoPromptApp
import XCTest

/// P4-7c c1 (design doc §6.2): holder #4's rewire differential. §6.2's original complication --
/// `AgentContextFileBrowseModelTests` was a whole-class quarantine that could not validate a
/// rewire -- no longer applies at this HEAD: the root-marker fix landed in the same slice that
/// unblocked P4-7b (`docs/architecture/rust-inventory-scope-v1.md` §12.5) took the class to
/// 23/23 green (`rg XCTSkip Tests/RepoPromptTests/AgentMode/AgentContextFileBrowseModelTests.swift`
/// returns zero), so §6.2's rewire branch is taken outright rather than its deferral branch. This
/// file is the differential §6.2 still calls for -- pinned outside the (now merely large, not
/// quarantined) model-mutation suite, exercising the search/candidate path directly.
///
/// **The oracle is a reimplementation, not the deleted production code**, matching
/// `AgentFileTagSuggestionParityDifferentialTests`'s documented convention exactly: this holder's
/// pre-rewrite `searchHaystack(for:lookupContext:)` was byte-identical in component list, order,
/// and trim/empty-drop semantics to `AgentFileTagSuggestionService`'s pre-a3 haystack (confirmed
/// during P4-7c recon by direct comparison of both methods' source), so this oracle is the same
/// haystack shape driving the same `PathSearchIndex` infra that stays in the tree until P4-7c's
/// deletion gate.
///
/// **How the differential is wired end-to-end.** `AgentContextFileBrowseService.search` re-scores
/// and re-groups whatever candidates its (private) candidate-generation step returns
/// (`storeBackedCandidates`'s doc comment states the same argument `AgentFileTagSuggestionService`
/// a3 makes: the method's own ordering is not independently load-bearing once
/// `score(records:query:physicalRoots:lookupContext:)` re-ranks). Rather than reach for a private
/// testing hook, this suite injects the oracle *as* the service's `indexedSearch` closure on a
/// second instance -- both instances then run the identical downstream revalidate/score/group
/// pipeline, so an end-to-end `search(...)` comparison is exactly as strict as a raw-candidate
/// comparison would have been, without touching a private symbol.
@MainActor
final class AgentContextFileBrowseSearchParityTests: XCTestCase {
    // MARK: - Fixture

    @discardableResult
    private func writeCorpus(under root: URL, suffix: String) throws -> [String] {
        let relativePaths = [
            "Sources/App\(suffix).swift",
            "Sources/Utils/Helper\(suffix).swift",
            "README\(suffix).md",
            "中文/文件\(suffix).swift",
            "emoji/🎉Party\(suffix).swift"
        ]
        for relativePath in relativePaths {
            try write("content-\(relativePath)", to: root.appendingPathComponent(relativePath))
        }
        return relativePaths
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeTestDirectory(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Oracle (pre-rewrite algorithm, reimplemented independently -- see file doc comment)

    private nonisolated static func oracleHaystack(entry: WorkspaceSearchCatalogEntry, lookupContext: WorkspaceLookupContext) -> String {
        let logicalPath = lookupContext.bindingProjection?.projectedLogicalDisplayPath(
            forPhysicalPath: entry.standardizedFullPath,
            display: .relative
        )
        return [logicalPath, entry.displayPath, entry.name, entry.standardizedRelativePath, entry.standardizedFullPath]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Global (all visible roots combined into one index), matching the pre-rewrite
    /// `storeBackedCandidates` shape exactly -- this holder never fanned out per root the way
    /// `AgentFileTagSuggestionService` did pre-a3, so unlike that suite's named-divergence test,
    /// there is no per-root-vs-global superset case to pin here: the new `.suggestion` fan-out is
    /// still a strict behavior change from this global oracle at multi-root scale (same accepted
    /// divergence class as a3's), but this holder is scoped to the single/dominant `.allRoots`
    /// admissibility-gated fallback case, where the corpus below is single-root.
    private func oracleIndexedSearch(
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) -> AgentContextFileBrowseService.IndexedSearch {
        { [store] query, limit async in
            let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace, requirement: .recordsOnly)
            let entries = snapshot.entries.filter { !$0.standardizedRelativePath.hasPrefix("_git_data") }
            let haystacks = entries.map { Self.oracleHaystack(entry: $0, lookupContext: lookupContext) }
            let index = await PathSearchIndex.build(paths: haystacks)
            let hits = await index.search(query, limit: limit)
            var seenIDs = Set<UUID>()
            var results: [WorkspaceSearchCatalogEntry] = []
            for hit in hits where entries.indices.contains(hit.index) {
                let entry = entries[hit.index]
                guard seenIDs.insert(entry.id).inserted else { continue }
                results.append(entry)
            }
            return WorkspaceSearchQueryResult(
                query: query,
                indexedGeneration: snapshot.generation,
                snapshotGeneration: snapshot.generation,
                results: results,
                isIndexReady: true,
                isStale: false
            )
        }
    }

    private func queryPatterns() -> [(pattern: String, limit: Int)] {
        [
            ("*.swift", 300),
            ("Sources App", 300),
            ("中文", 300),
            ("🎉", 300),
            ("swift", 10000)
        ]
    }

    // MARK: - Differential: new `.suggestion`-backed fallback vs. the pre-rewrite oracle

    /// `AgentContextFileBrowseService(store:indexedSearch: nil)` never has a fast-path index to
    /// consult, so every `search(...)` call routes through the rewired `storeBackedCandidates` --
    /// this is holder #4's fallback path, forced deterministically rather than relying on a live
    /// index happening to be stale.
    func testSearchResultsMatchPreRewriteOracleForAdmissibleAllRootScope() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "BrowseSearchParity")
        try writeCorpus(under: container, suffix: "1")
        _ = try await store.loadRoot(path: container.path)
        let lookupContext = WorkspaceLookupContext.visibleWorkspace

        let newService = AgentContextFileBrowseService(store: store, indexedSearch: nil)
        let oracleService = AgentContextFileBrowseService(
            store: store,
            indexedSearch: oracleIndexedSearch(store: store, lookupContext: lookupContext)
        )

        for (pattern, limit) in queryPatterns() {
            let actual = try await newService.search(
                query: pattern,
                scope: .allRoots,
                lookupContext: lookupContext,
                limit: limit
            )
            let expected = try await oracleService.search(
                query: pattern,
                scope: .allRoots,
                lookupContext: lookupContext,
                limit: limit
            )
            guard case let .available(actualResult) = actual, case let .available(expectedResult) = expected else {
                XCTFail("pattern='\(pattern)' limit=\(limit): expected both arms available")
                continue
            }
            XCTAssertEqual(
                actualResult.matches.map(\.file.id),
                expectedResult.matches.map(\.file.id),
                "pattern='\(pattern)' limit=\(limit)"
            )
            XCTAssertEqual(actualResult.source, .storeCatalog)
        }
    }

    // MARK: - Limit boundaries (mirrors AgentFileTagSuggestionParityDifferentialTests)

    func testEmptyQueryReturnsAvailableEmptyGroupsThroughTheRewiredPath() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "BrowseSearchParityEmptyQuery")
        try writeCorpus(under: container, suffix: "1")
        _ = try await store.loadRoot(path: container.path)
        let service = AgentContextFileBrowseService(store: store, indexedSearch: nil)

        let result = try await service.search(
            query: "",
            scope: .allRoots,
            lookupContext: .visibleWorkspace,
            limit: 300
        )
        guard case let .available(available) = result else {
            return XCTFail("expected available result for an empty query")
        }
        XCTAssertTrue(available.groups.isEmpty)
    }

    func testLimitOneReturnsAtMostOneMatchThroughTheRewiredPath() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "BrowseSearchParityLimitOne")
        try writeCorpus(under: container, suffix: "1")
        _ = try await store.loadRoot(path: container.path)
        let service = AgentContextFileBrowseService(store: store, indexedSearch: nil)

        let result = try await service.search(
            query: "BrowseSearchParityLimitOne",
            scope: .allRoots,
            lookupContext: .visibleWorkspace,
            limit: 1
        )
        guard case let .available(available) = result else {
            return XCTFail("expected available result")
        }
        XCTAssertLessThanOrEqual(available.matches.count, 1)
    }
}
