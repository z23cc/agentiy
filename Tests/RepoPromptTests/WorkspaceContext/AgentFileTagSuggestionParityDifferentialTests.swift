import AgentryCoreBridge
@testable import RepoPromptApp
import XCTest

/// P4-7a phase a3 (design doc `p4-7-pathsearch-production-cutover-v2-2026-08-23.md` §5.3): the
/// mandated hard-assertion differential -- "result set and order, over a fixed query corpus x a
/// fixed corpus of entries, asserted element-by-element -- not as a set, not as a prefix."
///
/// **The oracle is a reimplementation, not the deleted production code.** `storeBackedCatalogResults`
/// no longer builds a Swift `PathSearchIndex` at all (that is the whole point of the cutover) --
/// this suite's `oracle*` functions independently reproduce the pre-cutover algorithm
/// (`searchHaystack` + a private per-root `PathSearchIndex`) purely as a comparison fixture, using
/// infra (`PathSearchIndex`) that stays in the tree until P4-7c's deletion gate.
///
/// **The oracle is per-root, matching the new implementation's own shape, not the old single-
/// global-index shape (design §14's discipline: name what changed).** The pre-cutover
/// implementation ran one index over every visible root's entries combined and truncated to
/// `limit` globally; `storeBackedCatalogResults` now issues one `inventoryQuery(.suggestion)` per
/// root, each truncated to `limit`, concatenated. `testMultiRootFanOutIsASupersetOfGlobalTruncation`
/// below pins that difference by name, comparing against a *global* oracle instead, rather than
/// letting a single-root-only suite pass while silently not exercising the one case that changed.
@MainActor
final class AgentFileTagSuggestionParityDifferentialTests: XCTestCase {
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

    private func makeService(
        store: WorkspaceFileContextStore,
        bindingProjection: WorkspaceRootBindingProjection?,
        maxResults: Int = 300
    ) -> AgentFileTagSuggestionService {
        AgentFileTagSuggestionService(
            store: store,
            searchService: nil,
            selectionCoordinator: nil,
            lookupContextProvider: {
                WorkspaceLookupContext(rootScope: .visibleWorkspace, bindingProjection: bindingProjection)
            },
            maxResults: maxResults
        )
    }

    // MARK: - Oracle (pre-cutover algorithm, reimplemented independently -- see file doc comment)

    private func oracleHaystack(entry: WorkspaceSearchCatalogEntry, bindingProjection: WorkspaceRootBindingProjection?) -> String {
        let logicalPath = bindingProjection?.projectedLogicalDisplayPath(
            forPhysicalPath: entry.standardizedFullPath,
            display: .relative
        )
        return [logicalPath, entry.displayPath, entry.name, entry.standardizedRelativePath, entry.standardizedFullPath]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func oracleSearch(entries: [WorkspaceSearchCatalogEntry], query: String, limit: Int, bindingProjection: WorkspaceRootBindingProjection?) async -> [WorkspaceSearchCatalogEntry] {
        guard limit > 0 else { return [] }
        let haystacks = entries.map { oracleHaystack(entry: $0, bindingProjection: bindingProjection) }
        let index = await PathSearchIndex.build(paths: haystacks)
        let hits = await index.search(query, limit: limit)
        var seenIDs = Set<UUID>()
        var results: [WorkspaceSearchCatalogEntry] = []
        for hit in hits where entries.indices.contains(hit.index) {
            let entry = entries[hit.index]
            guard seenIDs.insert(entry.id).inserted else { continue }
            results.append(entry)
        }
        return results
    }

    /// Matches the new implementation's own shape: one index per root, each truncated to `limit`,
    /// concatenated in `store.rootRefs(scope:)`'s order.
    private func oraclePerRootResults(
        store: WorkspaceFileContextStore,
        query: String,
        limit: Int,
        bindingProjection: WorkspaceRootBindingProjection?
    ) async -> [WorkspaceSearchCatalogEntry] {
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace, requirement: .recordsOnly)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        var seenIDs = Set<UUID>()
        var results: [WorkspaceSearchCatalogEntry] = []
        for root in roots {
            let entries = snapshot.entries.filter { $0.rootID == root.id }
            for entry in await oracleSearch(entries: entries, query: query, limit: limit, bindingProjection: bindingProjection)
                where seenIDs.insert(entry.id).inserted
            {
                results.append(entry)
            }
        }
        return results
    }

    /// The pre-cutover shape: one global index over every visible root's entries combined,
    /// truncated to `limit` globally.
    private func oracleGlobalResults(
        store: WorkspaceFileContextStore,
        query: String,
        limit: Int,
        bindingProjection: WorkspaceRootBindingProjection?
    ) async -> [WorkspaceSearchCatalogEntry] {
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace, requirement: .recordsOnly)
        return await oracleSearch(entries: snapshot.entries, query: query, limit: limit, bindingProjection: bindingProjection)
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

    private func makeWorktreeBoundProjection(physicalRoot: WorkspaceRootRef) -> WorkspaceRootBindingProjection {
        let logicalRoot = WorkspaceRootRef(id: UUID(), name: "LogicalApp", fullPath: "/logical/App")
        let binding = AgentSessionWorktreeBinding(
            id: "binding-1",
            repositoryID: "repo-1",
            repoKey: "repo-key",
            logicalRootPath: logicalRoot.fullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: "wt-1",
            worktreeRootPath: physicalRoot.fullPath,
            source: "test"
        )
        return WorkspaceRootBindingProjection(
            sessionID: UUID(),
            boundRoots: [.init(logicalRoot: logicalRoot, physicalRoot: physicalRoot, binding: binding)]
        )
    }

    // MARK: - Single root: per-root/global oracle coincide, element-by-element equality holds in both binding configurations

    func testResultSetAndOrderMatchesOracleSingleRootNoBindingProjection() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "SuggestionSingleRoot")
        try writeCorpus(under: container, suffix: "1")
        _ = try await store.loadRoot(path: container.path)
        let service = makeService(store: store, bindingProjection: nil)

        for (pattern, limit) in queryPatterns() {
            let actual = await service.catalogResultsForTesting(for: pattern, limit: limit)
            let expected = await oraclePerRootResults(store: store, query: pattern, limit: limit, bindingProjection: nil)
            XCTAssertEqual(actual.map(\.id), expected.map(\.id), "pattern='\(pattern)' limit=\(limit)")
        }
    }

    func testResultSetAndOrderMatchesOracleSingleRootWorktreeBound() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "SuggestionSingleRootWorktree")
        try writeCorpus(under: container, suffix: "1")
        let record = try await store.loadRoot(path: container.path)
        let physicalRoot = WorkspaceRootRef(id: record.id, name: record.name, fullPath: record.standardizedFullPath)
        let projection = makeWorktreeBoundProjection(physicalRoot: physicalRoot)
        let service = makeService(store: store, bindingProjection: projection)

        for (pattern, limit) in queryPatterns() {
            let actual = await service.catalogResultsForTesting(for: pattern, limit: limit)
            let expected = await oraclePerRootResults(store: store, query: pattern, limit: limit, bindingProjection: projection)
            XCTAssertEqual(actual.map(\.id), expected.map(\.id), "pattern='\(pattern)' limit=\(limit)")
        }

        // a2's advisor note, closed the loop: `.suggestion` ignores `request.prefix` entirely
        // (a1's `suggestion_query_ignores_the_indexkey_prefix_field`), so the returned entry's
        // `displayPath` must be the stored default (`rootName + "/" + relativePath`), reconstructed
        // locally from the candidate + the queried root's own name/path
        // (`AgentFileTagSuggestionService.catalogEntry(from:rootPath:rootName:)`) -- not a
        // caller-prefix-composed value. This is the configuration (§1.5 Check A) where the two
        // would diverge if that regressed.
        let results = await service.catalogResultsForTesting(for: "App1", limit: 10)
        guard let appEntry = results.first(where: { $0.name == "App1.swift" }) else {
            return XCTFail("expected App1.swift in results")
        }
        XCTAssertEqual(appEntry.displayPath, "\(record.name)/Sources/App1.swift")
    }

    // MARK: - Multi-root: the per-root oracle still holds element-by-element, in both configs.

    func testResultSetAndOrderMatchesPerRootOracleTwoRoots() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let containerA = try makeTestDirectory(name: "SuggestionMultiRootA")
        let containerB = try makeTestDirectory(name: "SuggestionMultiRootB")
        try writeCorpus(under: containerA, suffix: "A")
        try writeCorpus(under: containerB, suffix: "B")
        _ = try await store.loadRoot(path: containerA.path)
        _ = try await store.loadRoot(path: containerB.path)
        let service = makeService(store: store, bindingProjection: nil)

        for (pattern, limit) in queryPatterns() {
            let actual = await service.catalogResultsForTesting(for: pattern, limit: limit)
            let expected = await oraclePerRootResults(store: store, query: pattern, limit: limit, bindingProjection: nil)
            XCTAssertEqual(actual.map(\.id), expected.map(\.id), "pattern='\(pattern)' limit=\(limit)")
        }
    }

    // MARK: - Named divergence from the pre-cutover global-truncation behavior (design §14)

    /// The per-root fan-out is a strict superset of the old global-truncation result whenever the
    /// per-root limit is smaller than the combined match count -- a real, intentionally-accepted
    /// fallback-path behavior change (see this file's and `storeBackedCatalogResults`'s doc
    /// comments), pinned here rather than left as an untested assumption.
    func testMultiRootFanOutIsASupersetOfThePreCutoverGlobalTruncation() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let containerA = try makeTestDirectory(name: "SuggestionSupersetA")
        let containerB = try makeTestDirectory(name: "SuggestionSupersetB")
        try writeCorpus(under: containerA, suffix: "A")
        try writeCorpus(under: containerB, suffix: "B")
        _ = try await store.loadRoot(path: containerA.path)
        _ = try await store.loadRoot(path: containerB.path)
        let service = makeService(store: store, bindingProjection: nil)

        // "SuggestionSuperset" is a literal substring of every entry's `standardizedFullPath`
        // (both containers are named `SuggestionSupersetA-<uuid>`/`SuggestionSupersetB-<uuid>`),
        // so it matches all 5 entries in each of the 2 roots -- 10 combined matches against a
        // limit of 3.
        let limit = 3
        let newResults = await service.catalogResultsForTesting(for: "SuggestionSuperset", limit: limit)
        let globalOracle = await oracleGlobalResults(store: store, query: "SuggestionSuperset", limit: limit, bindingProjection: nil)

        XCTAssertEqual(globalOracle.count, limit, "the old global oracle must actually truncate for this to be a meaningful comparison")
        XCTAssertGreaterThan(
            newResults.count, globalOracle.count,
            "per-root fan-out (each root capped at \(limit)) must return more candidates than the old single global index capped at \(limit) once combined matches exceed the limit"
        )
        XCTAssertEqual(Set(newResults.map(\.id)).count, newResults.count, "no duplicate ids across the concatenated per-root results")
    }

    // MARK: - Limit boundaries

    func testLimitZeroReturnsNoResults() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "SuggestionLimitZero")
        try writeCorpus(under: container, suffix: "1")
        _ = try await store.loadRoot(path: container.path)
        let service = makeService(store: store, bindingProjection: nil)

        let results = await service.catalogResultsForTesting(for: "swift", limit: 0)
        XCTAssertTrue(results.isEmpty)
    }

    func testLimitOneReturnsExactlyOneResultWhenMatchesExist() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "SuggestionLimitOne")
        try writeCorpus(under: container, suffix: "1")
        _ = try await store.loadRoot(path: container.path)
        let service = makeService(store: store, bindingProjection: nil)

        let results = await service.catalogResultsForTesting(for: "SuggestionLimitOne", limit: 1)
        XCTAssertEqual(results.count, 1)
    }

    func testLimitGreaterThanCorpusReturnsEveryMatchOnce() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "SuggestionLimitOverCorpus")
        let relativePaths = try writeCorpus(under: container, suffix: "1")
        _ = try await store.loadRoot(path: container.path)
        let service = makeService(store: store, bindingProjection: nil)

        let results = await service.catalogResultsForTesting(for: "SuggestionLimitOverCorpus", limit: 10000)
        XCTAssertEqual(results.count, relativePaths.count)
        XCTAssertEqual(Set(results.map(\.id)).count, results.count, "dedup: no entry appears twice")
    }

    // MARK: - Byte accounting (design §5.3's done-when)

    /// Discharges parent §11's "the whole-entries walk is provably gone": zero
    /// `searchCatalogSnapshot` calls -- the sole choke point that vends `.entries` -- across a
    /// `.suggestion`-routed `catalogResultsForTesting` call, in both binding configurations.
    func testSuggestionPathNeverCallsSearchCatalogSnapshot() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "SuggestionByteAccounting")
        let record = try await store.loadRoot(path: container.path)
        try writeCorpus(under: container, suffix: "1")
        _ = try await store.searchCatalogSnapshot(rootScope: .visibleWorkspace) // settle any load-time snapshot work

        let physicalRoot = WorkspaceRootRef(id: record.id, name: record.name, fullPath: record.standardizedFullPath)
        let projections: [WorkspaceRootBindingProjection?] = [nil, makeWorktreeBoundProjection(physicalRoot: physicalRoot)]
        for projection in projections {
            let service = makeService(store: store, bindingProjection: projection)
            await store.resetSearchCatalogSnapshotRequestCountForTesting()
            _ = await service.catalogResultsForTesting(for: "swift", limit: 64)
            let requestCount = await store.searchCatalogSnapshotRequestCountForTesting()
            XCTAssertEqual(
                requestCount, 0,
                "the .suggestion-routed suggestion path must never call searchCatalogSnapshot (bindingProjection == nil: \(projection == nil))"
            )
        }
    }
}
