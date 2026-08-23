@testable import RepoPromptApp
import XCTest

/// P4-7c c1 (design doc §6.2): holder #4's rewire coverage. §6.2's original complication --
/// `AgentContextFileBrowseModelTests` was a whole-class quarantine that could not validate a
/// rewire -- no longer applies at this HEAD: the root-marker fix landed in the same slice that
/// unblocked P4-7b (`docs/architecture/rust-inventory-scope-v1.md` §12.5) took the class to
/// 23/23 green (`rg XCTSkip Tests/RepoPromptTests/AgentMode/AgentContextFileBrowseModelTests.swift`
/// returns zero), so §6.2's rewire branch is taken outright rather than its deferral branch. This
/// file is the coverage §6.2 still calls for -- pinned outside the (now merely large, not
/// quarantined) model-mutation suite, exercising the search/candidate path directly.
///
/// P4-7c c3 update: `testSearchResultsMatchPreRewriteOracleForAdmissibleAllRootScope` and its
/// `oracleHaystack`/`oracleIndexedSearch` helpers are deleted in this commit. That oracle
/// reimplemented the pre-rewrite haystack shape driving a real `PathSearchIndex` instance -- the
/// type this slice deletes -- so it can no longer compile. Its evidentiary value (proving the c1
/// rewire's `.suggestion`-backed fallback matched the pre-rewrite algorithm result-for-result over
/// five query patterns/two Unicode corpora) was already captured at c1 and is preserved in this
/// file's git history and the c1 commit message; it is not re-derived here. The two
/// oracle-independent behavioral pins below (empty query, limit boundary) survive unchanged.
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
