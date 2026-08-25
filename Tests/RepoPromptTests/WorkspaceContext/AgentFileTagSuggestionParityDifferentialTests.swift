import AgentryCoreBridge
@testable import RepoPromptApp
import XCTest

/// P4-7a phase a3 (design doc `p4-7-pathsearch-production-cutover-v2-2026-08-23.md` §5.3): the
/// mandated hard-assertion differential -- "result set and order, over a fixed query corpus x a
/// fixed corpus of entries, asserted element-by-element -- not as a set, not as a prefix."
///
/// P4-7c c3 update: the oracle-driven differential methods (`testResultSetAndOrderMatchesOracleSingleRootNoBindingProjection`,
/// `testResultSetAndOrderMatchesPerRootOracleTwoRoots`, `testMultiRootFanOutIsASupersetOfThePreCutoverGlobalTruncation`,
/// and the oracle loop inside what was `testResultSetAndOrderMatchesOracleSingleRootWorktreeBound`)
/// and their `oracle*` helpers are deleted in this commit. They independently reproduced the
/// pre-cutover algorithm (`searchHaystack` + a private per-root `PathSearchIndex`) purely as a
/// comparison fixture, driving a real `PathSearchIndex` instance -- the type this slice deletes,
/// so they can no longer compile. Their evidentiary value (proving a3's `.suggestion`-backed
/// cutover matched the pre-cutover algorithm result-for-result, including the named per-root-vs-
/// global truncation divergence) was already captured at a3 and is preserved in this file's git
/// history and the a3 commit message; it is not re-derived here. `testWorktreeBoundDisplayPathIsReconstructedFromRootName`,
/// below, salvages the one oracle-*independent* assertion the deleted worktree-bound test carried
/// (§1.5 Check A: `displayPath` is reconstructed from the queried root's own name, not a caller-
/// prefix-composed value) -- that pin does not touch the oracle and survives unchanged. The four
/// oracle-independent tests below (limit boundaries, byte accounting) are otherwise untouched.
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

    // MARK: - Salvaged oracle-independent pin (§1.5 Check A)

    /// a2's advisor note, closed the loop: `.suggestion` ignores `request.prefix` entirely
    /// (a1's `suggestion_query_ignores_the_indexkey_prefix_field`), so the returned entry's
    /// `displayPath` must be the stored default (`rootName + "/" + relativePath`), reconstructed
    /// locally from the candidate + the queried root's own name/path
    /// (`AgentFileTagSuggestionService.catalogEntry(from:rootPath:rootName:)`) -- not a
    /// caller-prefix-composed value. This is the configuration (§1.5 Check A) where the two
    /// would diverge if that regressed. Oracle-independent: carried no `PathSearchIndex`
    /// dependency even before P4-7c c3 deleted the oracle-driven differential above it.
    func testWorktreeBoundDisplayPathIsReconstructedFromRootName() async throws {
        let store = WorkspaceFileContextStore()
        let container = try makeTestDirectory(name: "SuggestionSingleRootWorktree")
        try writeCorpus(under: container, suffix: "1")
        let record = try await store.loadRoot(path: container.path)
        let physicalRoot = WorkspaceRootRef(id: record.id, name: record.name, fullPath: record.standardizedFullPath)
        let projection = makeWorktreeBoundProjection(physicalRoot: physicalRoot)
        let service = makeService(store: store, bindingProjection: projection)

        let results = await service.catalogResultsForTesting(for: "App1", limit: 10)
        guard let appEntry = results.first(where: { $0.name == "App1.swift" }) else {
            return XCTFail("expected App1.swift in results")
        }
        XCTAssertEqual(appEntry.displayPath, "\(record.name)/Sources/App1.swift")
    }

    // MARK: - Limit boundaries

    func testLimitZeroReturnsNoResults() async throws {
        let store = WorkspaceFileContextStore()
        let container = try makeTestDirectory(name: "SuggestionLimitZero")
        try writeCorpus(under: container, suffix: "1")
        _ = try await store.loadRoot(path: container.path)
        let service = makeService(store: store, bindingProjection: nil)

        let results = await service.catalogResultsForTesting(for: "swift", limit: 0)
        XCTAssertTrue(results.isEmpty)
    }

    func testLimitOneReturnsExactlyOneResultWhenMatchesExist() async throws {
        let store = WorkspaceFileContextStore()
        let container = try makeTestDirectory(name: "SuggestionLimitOne")
        try writeCorpus(under: container, suffix: "1")
        _ = try await store.loadRoot(path: container.path)
        let service = makeService(store: store, bindingProjection: nil)

        let results = await service.catalogResultsForTesting(for: "SuggestionLimitOne", limit: 1)
        XCTAssertEqual(results.count, 1)
    }

    func testLimitGreaterThanCorpusReturnsEveryMatchOnce() async throws {
        let store = WorkspaceFileContextStore()
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
        let store = WorkspaceFileContextStore()
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
