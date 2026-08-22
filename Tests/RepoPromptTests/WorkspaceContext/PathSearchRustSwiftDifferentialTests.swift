import AgentryCoreBridge
@testable import RepoPromptApp
import XCTest

/// Differential parity test for the P3-3 slice-2b phase-2 pure-Rust path-search port
/// (`rust/crates/runtime/src/pathsearch/`): every case below drives BOTH the real, C-backed Swift
/// `PathSearchIndex` (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift`,
/// which calls straight through to `path_search_create`/`path_search_find`/
/// `path_search_projected_find_cancellable`) and the real Rust seam (`RustPathSearchProbe`, the
/// real `AgentryCoreBridge` runtime, no mocking) against the SAME corpus, then asserts IDENTICAL
/// result ordinal sequences (same order, same original indices) and, for projected queries,
/// bit-identical diagnostics. Hard assertions from day one, no `XCTExpectFailure`.
///
/// Unlike the pathmatch-resolve differential suite, this port has NO Foundation/ICU escape hatch
/// -- see `rust/crates/runtime/src/pathsearch/mod.rs`'s module doc: the C engine's `REG_ICASE`
/// case folding is pinned as ASCII-only (C-locale) behavior, so ANY divergence on non-ASCII
/// fixtures here is a real bug, not an expected/documented asymmetry.
final class PathSearchRustSwiftDifferentialTests: XCTestCase {
    // MARK: - Parity harness

    private struct SwiftQueryResult {
        let ordinals: [Int]
        let stats: PathSearchIndex.ProjectedSearchDiagnostics?
    }

    private func swiftResult(index: PathSearchIndex, query: CorePathSearchQueryV1) async -> SwiftQueryResult {
        switch query.mode {
        case .find:
            let candidates = index.searchSynchronously(query.pattern, limit: query.limit)
            return SwiftQueryResult(ordinals: candidates.map(\.index), stats: nil)
        case let .projected(displayPrefix, absolutePrefix):
            let outcome = await index.searchProjected(
                query.pattern, displayPrefix: displayPrefix, absolutePrefix: absolutePrefix, limit: query.limit
            )
            switch outcome {
            case let .completed(candidates, diagnostics):
                return SwiftQueryResult(ordinals: candidates.map(\.index), stats: diagnostics)
            case .cancelled:
                XCTFail("Swift reference projected search unexpectedly reported cancellation")
                return SwiftQueryResult(ordinals: [], stats: nil)
            }
        }
    }

    @discardableResult
    private func assertParity(
        corpus: [String],
        queries: [CorePathSearchQueryV1],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [SwiftQueryResult] {
        let index = PathSearchIndex(paths: corpus)
        var swiftResults: [SwiftQueryResult] = []
        swiftResults.reserveCapacity(queries.count)
        for query in queries {
            await swiftResults.append(swiftResult(index: index, query: query))
        }

        let rustResults = try await RustPathSearchProbe().find(corpusPaths: corpus, queries: queries)

        XCTAssertEqual(swiftResults.count, rustResults.count, file: file, line: line)
        for (queryIndex, query) in queries.enumerated() {
            guard queryIndex < rustResults.count, queryIndex < swiftResults.count else { continue }
            let swift = swiftResults[queryIndex]
            let rust = rustResults[queryIndex]
            let context = "query[\(queryIndex)]='\(query.pattern)' limit=\(query.limit)"

            XCTAssertEqual(
                swift.ordinals, rust.ordinals.map(Int.init),
                "\(context): ordinal sequence mismatch", file: file, line: line
            )

            switch query.mode {
            case .find:
                XCTAssertNil(rust.projectedStats, "\(context): find-mode query must report nil stats", file: file, line: line)
            case .projected:
                guard let swiftStats = swift.stats, let rustStats = rust.projectedStats else {
                    XCTFail("\(context): expected projected diagnostics on both sides", file: file, line: line)
                    continue
                }
                XCTAssertEqual(swiftStats.examinedCount, rustStats.examinedCount, "\(context): examinedCount", file: file, line: line)
                XCTAssertEqual(swiftStats.matchedCount, rustStats.matchedCount, "\(context): matchedCount", file: file, line: line)
                XCTAssertEqual(swiftStats.heapPeakCount, rustStats.heapPeakCount, "\(context): heapPeakCount", file: file, line: line)
                XCTAssertEqual(
                    swiftStats.heapComparisonCount, rustStats.heapComparisonCount, "\(context): heapComparisonCount",
                    file: file, line: line
                )
                XCTAssertEqual(swiftStats.scratchBytes, rustStats.scratchBytes, "\(context): scratchBytes", file: file, line: line)
            }
        }
        return swiftResults
    }

    private func find(_ pattern: String, limit: Int = 300) -> CorePathSearchQueryV1 {
        CorePathSearchQueryV1(pattern: pattern, limit: limit, mode: .find)
    }

    private func projected(_ pattern: String, display: String, absolute: String, limit: Int = 300) -> CorePathSearchQueryV1 {
        CorePathSearchQueryV1(pattern: pattern, limit: limit, mode: .projected(displayPrefix: display, absolutePrefix: absolute))
    }

    // MARK: - Recovery-fixture corpus (byte-for-byte from PathSearchIndexRecoveryTests.swift)

    private let recoveryCorpus = [
        "/Volumes/Repo/Sources/Zeta/Widget.swift",
        "Sources/βeta/Search/Unicode.swift",
        "Sources/App/Search/Alpha.swift",
        "Sources/App/Search/Alpha.swift",
        "Sources/App/Features/SearchPanel.swift",
        "docs/absolute-search-notes.md",
        "Worktree/Sources/CompositeCatalogTarget.rpfixture\n/Volumes/Worktree/Sources/CompositeCatalogTarget.rpfixture"
    ]

    func testRecoveryFixtureCorpusReplaysExactQueries() async throws {
        try await assertParity(corpus: recoveryCorpus, queries: [
            find("Alpha.swift", limit: 10),
            find("Alpha.swift", limit: 1),
            find("*.swift", limit: 3),
            find("*.swift", limit: 20),
            find("App Search", limit: 20),
            find("βeta", limit: 20),
            find("Volumes Widget", limit: 20),
            find("CompositeCatalogTarget", limit: 20),
            find("swift", limit: 0)
        ])
    }

    func testRecoveryFixtureCorpusProjectedQueries() async throws {
        try await assertParity(corpus: recoveryCorpus, queries: [
            projected("*.swift", display: "Root/", absolute: "/tmp/Root/", limit: 300),
            projected("Alpha.swift", display: "Root/", absolute: "/tmp/Root/", limit: 1),
            projected("CompositeCatalogTarget", display: "Root/", absolute: "/tmp/Root/", limit: 300)
        ])
    }

    // MARK: - Glob semantics: * vs ** vs ?, literal metacharacters

    func testStarDoesNotCrossSlashButDoubleStarDoes() async throws {
        let corpus = ["src/a.swift", "src/sub/b.swift"]
        try await assertParity(corpus: corpus, queries: [
            find("src/*.swift"),
            find("src/**.swift")
        ])
    }

    func testLeadingStarAndDoubleStarBehaveIdenticallyAsUnanchoredWildcard() async throws {
        let corpus = ["a/b.txt", "c/d/e.txt", "flat.txt"]
        try await assertParity(corpus: corpus, queries: [find("*"), find("**")])
    }

    func testQuestionMarkMatchesExactlyOneNonSlashByte() async throws {
        let corpus = ["a.txt", "ab.txt", "a/x.txt"]
        try await assertParity(corpus: corpus, queries: [find("a?.txt"), find("?.txt")])
    }

    func testLiteralRegexMetacharactersAreMatchedLiterally() async throws {
        let corpus = ["[test].txt", "a(b).c", "a.b+c", "a^b$c", "a|b.txt", "back\\slash.txt"]
        try await assertParity(corpus: corpus, queries: [
            find("[test].txt"),
            find("a(b).c"),
            find("a.b+c"),
            find("a^b$c"),
            find("a|b.txt"),
            find("back\\slash.txt")
        ])
    }

    func testCaseSensitivePrefixBoundNarrowingDespiteCaseInsensitiveMatch() async throws {
        // Pinned C quirk: the prefix/suffix binary-search bound is case-SENSITIVE even though the
        // subsequent regex/DP match is case-INSENSITIVE -- see index.rs's module doc decision
        // table. "Foo*" only ever considers candidates whose literal prefix is byte-exactly "Foo".
        let corpus = ["Foobar.txt", "foobar.txt", "FOOBAR.txt"]
        try await assertParity(corpus: corpus, queries: [find("Foo*"), find("foo*"), find("FOO*")])
    }

    // MARK: - Multi-term space-AND, including the 20-term cap

    func testSpaceSeparatedAndTerms() async throws {
        let corpus = ["Sources/App/Features/SearchPanel.swift", "Sources/App/Search/Alpha.swift", "docs/notes.md"]
        try await assertParity(corpus: corpus, queries: [
            find("App Search"),
            find("App Features Panel"),
            find("nonexistent term combo")
        ])
    }

    func testMoreThanTwentySpaceTermsExercisesTheCap() async throws {
        // 25 distinct single-character terms; only the target path's own tokens (well within the
        // first 20) are guaranteed present. Both engines must silently drop terms past the cap
        // identically -- this test asserts AGREEMENT, not a specific match/no-match outcome.
        let manyTerms = (0 ..< 25).map { String(UnicodeScalar(97 + $0)!) }.joined(separator: " ")
        let corpus = ["a-b-c-d-e-f-g-h-i-j.txt", "unrelated.txt"]
        try await assertParity(corpus: corpus, queries: [find(manyTerms)])
    }

    // MARK: - Empty / degenerate patterns

    func testEmptyAndDegeneratePatterns() async throws {
        let corpus = ["a.txt", "b/c.txt"]
        try await assertParity(corpus: corpus, queries: [
            find(""),
            find(" "),
            find("   "),
            find("*"),
            find("**"),
            find("?")
        ])
    }

    func testEmptyPatternWorkspaceIndexKeyOrderingAndLimit() async throws {
        // Exact P4-5 shadow-index arm shape: one root-local, plain PathSearchIndex over
        // displayPath + "\n" + standardizedFullPath keys, queried with limit 50. Smaller and zero
        // limits pin the suspected truncation/tie-break confounders; the duplicate pins ordinal ties.
        let corpus = [
            "ShadowIndex/src/Zeta.swift\n/tmp/ShadowIndex/src/Zeta.swift",
            "ShadowIndex/README.md\n/tmp/ShadowIndex/README.md",
            "ShadowIndex/src/Alpha.swift\n/tmp/ShadowIndex/src/Alpha.swift",
            "ShadowIndex/src/Alpha.swift\n/tmp/ShadowIndex/src/Alpha.swift"
        ]
        let results = try await assertParity(corpus: corpus, queries: [
            find("", limit: 0),
            find("", limit: 1),
            find("", limit: 3),
            find("", limit: 50)
        ])
        XCTAssertEqual(results[0].ordinals, [])
        XCTAssertEqual(results[1].ordinals, [1])
        XCTAssertEqual(results[2].ordinals, [1, 2, 3])
        XCTAssertEqual(results[3].ordinals, [1, 2, 3, 0])
    }

    func testEmptyPatternProjectedWorkspaceOrderingAndLimit() async throws {
        // Projected storage is not the P4-5 shadow arm's failing invocation, but it is the other
        // workspace path-search shape and shares the same eventual merged tie-break key.
        let corpus = ["src/Zeta.swift", "README.md", "src/Alpha.swift", "src/Alpha.swift"]
        let results = try await assertParity(corpus: corpus, queries: [
            projected("", display: "ShadowIndex/", absolute: "/tmp/ShadowIndex/", limit: 0),
            projected("", display: "ShadowIndex/", absolute: "/tmp/ShadowIndex/", limit: 1),
            projected("", display: "ShadowIndex/", absolute: "/tmp/ShadowIndex/", limit: 3),
            projected("", display: "ShadowIndex/", absolute: "/tmp/ShadowIndex/", limit: 50)
        ])
        XCTAssertEqual(results[0].ordinals, [])
        XCTAssertEqual(results[1].ordinals, [1])
        XCTAssertEqual(results[2].ordinals, [1, 2, 3])
        XCTAssertEqual(results[3].ordinals, [1, 2, 3, 0])
    }

    func testZeroLimitAndEmptyCorpus() async throws {
        try await assertParity(corpus: ["a.txt", "b.txt"], queries: [find("a.txt", limit: 0)])
        try await assertParity(corpus: [], queries: [find("anything"), projected("anything", display: "d/", absolute: "/a/")])
    }

    // MARK: - Non-ASCII: pinned ASCII-only case folding, no ICU escape hatch

    func testNonAsciiBytesUseAsciiOnlyCaseFoldingLikeCLocale() async throws {
        // İ (U+0130 dotted capital I) must NOT fold to ASCII "i" -- unlike the pathmatch-resolve
        // suite, there is no Foundation/ICU boundary here to route around this; both C (REG_ICASE
        // under the process locale) and this Rust port are pinned to ASCII-only folding.
        let corpus = ["İstanbul.swift", "istanbul.swift", "café/naïve.md", "Кириллица.txt"]
        try await assertParity(corpus: corpus, queries: [
            find("istanbul.swift"),
            find("\u{0130}stanbul.swift"),
            find("café/naïve.md"),
            find("CAFÉ/NAÏVE.md"),
            find("кириллица.txt"),
            find("КИРИЛЛИЦА.txt")
        ])
    }

    // MARK: - Newline-containing keys and the projected \n separator

    func testNewlineContainingCorpusKeys() async throws {
        let corpus = ["a\nb.txt", "plain.txt", "multi\nline\nkey.md"]
        try await assertParity(corpus: corpus, queries: [
            find("a\nb.txt"),
            find("a*b.txt"),
            find("multi*key.md")
        ])
    }

    func testProjectedSearchMatchesAcrossTheEmbeddedNewlineSeparator() async throws {
        // The matched subject is displayPrefix + relativePath + "\n" + absolutePrefix +
        // relativePath. "**" (StarAny) has no `\n` special case, so a pattern spanning the
        // embedded separator via `**` must match -- see engine.rs's module doc.
        let corpus = ["File.swift", "Other.md"]
        try await assertParity(corpus: corpus, queries: [
            projected("**File.swift**File.swift", display: "Disp/", absolute: "/Abs/"),
            projected("Disp*File*", display: "Disp/", absolute: "/Abs/"),
            projected("*Abs*", display: "Disp/", absolute: "/Abs/")
        ])
    }

    func testProjectedDisplayAndAbsolutePrefixesIndependentlyMatch() async throws {
        let corpus = ["src/Model.swift"]
        try await assertParity(corpus: corpus, queries: [
            projected("MyRepo*", display: "MyRepo/", absolute: "/tmp/MyRepo/"),
            projected("*tmp*", display: "MyRepo/", absolute: "/tmp/MyRepo/"),
            projected("NoMatchPrefix*", display: "MyRepo/", absolute: "/tmp/MyRepo/")
        ])
    }

    // MARK: - Deep nesting

    func testDeeplyNestedPaths() async throws {
        let depths = (0 ..< 40).map { depth in
            (0 ... depth).map { "level\($0)" }.joined(separator: "/") + "/leaf\(depth).swift"
        }
        try await assertParity(corpus: depths, queries: [
            find("*.swift", limit: 100),
            find("leaf39.swift"),
            find("level0/level1/level2/*", limit: 100),
            projected("*.swift", display: "Root/", absolute: "/tmp/Root/", limit: 100)
        ])
    }

    // MARK: - Duplicates: corpus paths and queries within one batch

    func testDuplicateCorpusPathsAndDuplicateQueriesInOneBatch() async throws {
        let corpus = ["dup/App.swift", "dup/App.swift", "unique/Other.swift"]
        let query = find("App.swift")
        try await assertParity(corpus: corpus, queries: [query, query, find("unique/*")])
    }

    // MARK: - Limit truncation + tie-break ordering at scale

    func testLimitTruncationTieBreakOrderingAcrossManyDuplicates() async throws {
        let corpus = (0 ..< 30).map { "dir\($0 % 3)/Dup.swift" }
        try await assertParity(corpus: corpus, queries: [
            find("Dup.swift", limit: 0),
            find("Dup.swift", limit: 1),
            find("Dup.swift", limit: 5),
            find("Dup.swift", limit: 29),
            find("Dup.swift", limit: 30),
            find("Dup.swift", limit: 1000)
        ])
    }

    // MARK: - Mixed-case ASCII

    func testMixedCaseAsciiCorpusAndPatterns() async throws {
        let corpus = ["Sources/App/ViewController.swift", "sources/app/viewcontroller.swift", "SOURCES/APP/VIEWCONTROLLER.SWIFT"]
        try await assertParity(corpus: corpus, queries: [
            find("ViewController.swift"),
            find("SOURCES/*"),
            find("sources/app/*")
        ])
    }

    // MARK: - Large generated corpus for ordering stability at scale

    func testGeneratedFiveThousandPathCorpusOrderingStability() async throws {
        var corpus: [String] = []
        corpus.reserveCapacity(5000)
        for index in 0 ..< 5000 {
            let package = "pkg\(index % 7)"
            let module = "mod\(index % 13)"
            let depth = "deep\(index % 5)"
            let name = index % 17 == 0 ? "File\(index).SWIFT" : "file\(index).swift"
            corpus.append("\(package)/\(module)/\(depth)/\(name)")
        }
        let repeatedQuery = find("file42*")
        try await assertParity(corpus: corpus, queries: [
            find("*.swift", limit: 50),
            find("pkg3/mod5/*", limit: 100),
            find("pkg0 mod0 deep0", limit: 50),
            find("**42.swift", limit: 50),
            repeatedQuery,
            repeatedQuery,
            projected("*.swift", display: "Root/", absolute: "/tmp/Root/", limit: 50)
        ])
    }
}
