import AgentryCoreBridge
@testable import RepoPromptApp
import RepoPromptWorkspaceCore
import XCTest

/// Differential parity test for the P3-3 slice-2a workspace path-matching RESOLUTION PIPELINE
/// Rust port: every case below drives BOTH the real Swift ladder (`PathMatcher.locate`) and the
/// real Rust seam (`RustPathMatchResolver`, the real `AgentryCoreBridge` runtime, no mocking)
/// against the SAME `PathMatchSnapshot` fixture, then asserts IDENTICAL resolution outcomes (same
/// corrected root+path, or same `nil`). Hard assertions from day one, no `XCTExpectFailure`.
///
/// See `rust/crates/runtime/src/pathmatch/{indexes.rs,resolve.rs}`'s module docs for the full
/// wire shape and THREE documented Foundation/ICU/filesystem scope-boundary decisions this port
/// draws:
///  1. Initial `StandardizedPath.absolute` (NSString.standardizingPath) stays Swift-side --
///     encoded once per query as `standardizedPath` below.
///  2. Symlink resolution (`resolvingSymlinksInPath`) is NOT ported; Rust treats a
///     symlink-resolved path as identical to its standardized form. This is exactly Swift's own
///     behavior for every fixture here (none of these paths exist on real disk), so it is not a
///     source of divergence for this suite.
///  3. Root-alias case-insensitive matching (`aliasRootCandidates`, `buildHeadTrimVariants`) is
///     ASCII-fold approximated Rust-side, not full ICU. Fixtures that exercise alias/head-trim
///     matching use ASCII root names; the Unicode (İ/virama) fixtures below are routed through
///     stages where the wire text is Swift-precomputed (canonical keys, cleaned-lower scoring
///     components) and are NOT alias/head-trim fixtures, so bit-identical parity holds for them.
final class PathMatchResolveRustSwiftDifferentialTests: XCTestCase {
    // MARK: - Fixture construction (real production types/functions only)

    private struct RootFixture {
        let fullPath: String
        let name: String
    }

    private struct FileFixture {
        let fullPath: String
        let relativePath: String
        let rootFullPath: String
    }

    private struct FolderFixture {
        let fullPath: String
        let relativePath: String
        let rootFullPath: String
    }

    private func buildSnapshot(
        roots: [RootFixture],
        files: [FileFixture],
        folders: [FolderFixture] = [],
        selectedFileFullPaths: Set<String> = [],
        caseSensitive: Bool = false
    ) -> PathMatchSnapshot {
        var filesByFullPath: [String: FileRecord] = [:]
        for entry in files {
            filesByFullPath[entry.fullPath] = FrozenFileRecord(
                name: (entry.relativePath as NSString).lastPathComponent,
                relativePath: entry.relativePath,
                fullPath: entry.fullPath,
                rootFolderPath: entry.rootFullPath
            )
        }
        var foldersByFullPath: [String: FolderRecord] = [:]
        for entry in folders {
            foldersByFullPath[entry.fullPath] = FrozenFolderRecord(
                name: (entry.relativePath as NSString).lastPathComponent,
                relativePath: entry.relativePath,
                fullPath: entry.fullPath,
                rootPath: entry.rootFullPath
            )
        }
        let rootFolders: [FolderRecord] = roots.map { root in
            FrozenFolderRecord(name: root.name, relativePath: "", fullPath: root.fullPath, rootPath: root.fullPath, displayName: root.name)
        }
        let staticData = StaticPathMatchData(
            filesByFullPath: filesByFullPath,
            foldersByFullPath: foldersByFullPath,
            rootFolders: rootFolders,
            id: 1,
            caseSensitive: caseSensitive
        )
        let indexes = PathMatchIndexes.build(
            files: staticData.filesByFullPath,
            folders: staticData.foldersByFullPath,
            caseSensitive: caseSensitive
        )
        return PathMatchSnapshot(staticData: staticData, selectedFileFullPaths: selectedFileFullPaths, indexes: indexes)
    }

    // MARK: - Wire encoding (mirrors what a real production caller would compute)

    private func component(_ s: String) -> CorePathMatchComponentV1 {
        let cleanedValue = PathMatcher.cleaned(s)
        return CorePathMatchComponentV1(
            text: cleanedValue.lowercased(),
            characterCount: cleanedValue.count,
            cleanedByteLength: cleanedValue.utf8.count
        )
    }

    private func lastTwoCanonical(_ relativePath: String, caseSensitive: Bool) -> String {
        let comps = relativePath.split(separator: "/").map(String.init)
        guard comps.count >= 2 else { return "" }
        let joined = comps[comps.count - 2] + "/" + comps[comps.count - 1]
        return PathMatchIndexes.canonical(joined, caseSensitive: caseSensitive)
    }

    private func rootOrdinal(fullPath: String, roots: [FolderRecord]) -> UInt64 {
        guard let idx = roots.firstIndex(where: { $0.fullPath == fullPath }) else {
            XCTFail("fixture bug: no root matches full path \(fullPath)")
            return 0
        }
        return UInt64(idx)
    }

    private func encodeRoots(_ snapshot: PathMatchSnapshot) -> [CorePathMatchResolveRootV1] {
        snapshot.rootFolders.map { CorePathMatchResolveRootV1(fullPath: $0.fullPath, name: $0.name) }
    }

    private func encodeFiles(_ snapshot: PathMatchSnapshot) -> [CorePathMatchResolveFileV1] {
        snapshot.filesByFullPath.values.map { file in
            let comps = file.relativePath.split(separator: "/").map(String.init)
            return CorePathMatchResolveFileV1(
                fullPath: file.fullPath,
                relativePath: file.relativePath,
                rootOrdinal: rootOrdinal(fullPath: file.rootFolderPath, roots: snapshot.rootFolders),
                nameCanonical: PathMatchIndexes.canonical(file.name, caseSensitive: snapshot.caseSensitive),
                ext: (file.name as NSString).pathExtension.lowercased(),
                lastTwoCanonical: lastTwoCanonical(file.relativePath, caseSensitive: snapshot.caseSensitive),
                components: comps.map(component)
            )
        }
    }

    private func encodeFolders(_ snapshot: PathMatchSnapshot) -> [CorePathMatchResolveFolderV1] {
        snapshot.foldersByFullPath.values.map { folder in
            let comps = folder.relativePath.split(separator: "/").map(String.init)
            return CorePathMatchResolveFolderV1(
                fullPath: folder.fullPath,
                relativePath: folder.relativePath,
                rootOrdinal: rootOrdinal(fullPath: folder.rootPath, roots: snapshot.rootFolders),
                nameCanonical: PathMatchIndexes.canonical(folder.name, caseSensitive: snapshot.caseSensitive),
                components: comps.map(component)
            )
        }
    }

    private func standardizedPath(for userPath: String) -> String {
        let raw = PathCharPolicy.foldHomoglyphsIfNeeded(userPath.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !raw.isEmpty else { return "" }
        return StandardizedPath.absolute(raw)
    }

    private func rawComponents(_ standardized: String) -> [String] {
        guard !standardized.isEmpty else { return [] }
        return standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init)
    }

    private func buildQuery(_ userPath: String, caseSensitive: Bool) -> CorePathMatchResolveQueryV1 {
        let std = standardizedPath(for: userPath)
        let comps = rawComponents(std)
        let canonical = comps.map { PathMatchIndexes.canonical($0, caseSensitive: caseSensitive) }
        let cleanedLower = comps.map(component)
        return CorePathMatchResolveQueryV1(standardizedPath: std, canonicalComponents: canonical, cleanedLowerComponents: cleanedLower)
    }

    // MARK: - Parity harness

    @discardableResult
    private func assertParity(
        snapshot: PathMatchSnapshot,
        userPaths: [String],
        options: PathLocateOptions = PathLocateOptions(
            exactMatchOnly: false,
            allowLeadingRootAliasTrim: true,
            allowHeadTrimAliases: true,
            allowAbsoluteSuffixFallback: true,
            useSelectedRootBias: true
        ),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [PathMatchLocation?] {
        let swiftResults = userPaths.map { PathMatcher.locate(userPath: $0, options: options, snapshot: snapshot) }

        let roots = encodeRoots(snapshot)
        let files = encodeFiles(snapshot)
        let folders = encodeFolders(snapshot)
        let queries = userPaths.map { buildQuery($0, caseSensitive: snapshot.caseSensitive) }

        let rustResults = try await RustPathMatchResolver().locateMany(
            caseSensitive: snapshot.caseSensitive,
            exactMatchOnly: options.exactMatchOnly,
            allowLeadingRootAliasTrim: options.allowLeadingRootAliasTrim,
            allowHeadTrimAliases: options.allowHeadTrimAliases,
            allowAbsoluteSuffixFallback: options.allowAbsoluteSuffixFallback,
            roots: roots,
            files: files,
            folders: folders,
            selectedFileFullPaths: Array(snapshot.selectedFileFullPaths),
            queries: queries
        )

        XCTAssertEqual(swiftResults.count, rustResults.count, file: file, line: line)
        for (idx, userPath) in userPaths.enumerated() {
            guard idx < rustResults.count else { continue }
            let swiftLoc = swiftResults[idx]
            let rustLoc = rustResults[idx]
            switch (swiftLoc, rustLoc) {
            case (nil, nil):
                continue
            case let (swiftLoc?, rustLoc?):
                XCTAssertEqual(
                    swiftLoc.correctedPath, rustLoc.correctedPath,
                    "query '\(userPath)' correctedPath mismatch", file: file, line: line
                )
                let expectedRootOrdinal = rootOrdinal(fullPath: swiftLoc.rootPath, roots: snapshot.rootFolders)
                XCTAssertEqual(
                    rustLoc.rootOrdinal, expectedRootOrdinal,
                    "query '\(userPath)' root mismatch", file: file, line: line
                )
            case (nil, .some):
                XCTFail("query '\(userPath)': Swift nil but Rust matched", file: file, line: line)
            case (.some, nil):
                XCTFail("query '\(userPath)': Swift matched but Rust nil", file: file, line: line)
            }
        }
        return swiftResults
    }

    private let defaultOptions = PathLocateOptions(
        exactMatchOnly: false,
        allowLeadingRootAliasTrim: true,
        allowHeadTrimAliases: true,
        allowAbsoluteSuffixFallback: true,
        useSelectedRootBias: true
    )

    // MARK: - Direct / exact stages

    func testDirectFullPathAndRelativeExactMatch() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Workspace/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Workspace/Root/src/App.swift", relativePath: "src/App.swift", rootFullPath: "/Workspace/Root")]
        )
        let results = try await assertParity(
            snapshot: snapshot,
            userPaths: ["/Workspace/Root/src/App.swift", "src/App.swift", "Root/src/App.swift"]
        )
        XCTAssertTrue(results.allSatisfy { $0 != nil }, "all three exact-match forms must resolve")
    }

    func testAbsoluteParentFolderOptimization() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Root/src/App.swift", relativePath: "src/App.swift", rootFullPath: "/Root")],
            folders: [FolderFixture(fullPath: "/Root/src", relativePath: "src", rootFullPath: "/Root")]
        )
        try await assertParity(snapshot: snapshot, userPaths: ["/Root/src/App.swift"])
    }

    // MARK: - Multi-root + alias + selected-path bias

    func testMultiRootAliasDisambiguationAndSelectionBias() async throws {
        let snapshot = buildSnapshot(
            roots: [
                RootFixture(fullPath: "/A", name: "AliasA"),
                RootFixture(fullPath: "/B", name: "AliasB")
            ],
            files: [
                FileFixture(fullPath: "/A/shared/File.swift", relativePath: "shared/File.swift", rootFullPath: "/A"),
                FileFixture(fullPath: "/B/shared/File.swift", relativePath: "shared/File.swift", rootFullPath: "/B")
            ],
            selectedFileFullPaths: ["/B/shared/File.swift"]
        )
        try await assertParity(
            snapshot: snapshot,
            userPaths: ["AliasB/shared/File.swift", "AliasA/shared/File.swift", "shared/File.swift"]
        )
    }

    func testHeadTrimVariantRescue() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Workspace/Backend", name: "Backend")],
            files: [FileFixture(fullPath: "/Workspace/Backend/src/Foo.swift", relativePath: "src/Foo.swift", rootFullPath: "/Workspace/Backend")]
        )
        let results = try await assertParity(snapshot: snapshot, userPaths: ["apps/Backend/src/Foo.swift"])
        XCTAssertEqual(
            results.first.flatMap(\.self)?.correctedPath, "src/Foo.swift",
            "fixture bug: head-trim rescue must actually resolve on the Swift reference side, or this test would trivially pass via both-nil"
        )
    }

    // MARK: - Single-component fuzzy + tie-breaks

    func testSingleComponentExactAndFuzzyMatch() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [
                FileFixture(fullPath: "/Root/src/App-Delegate.swift", relativePath: "src/App-Delegate.swift", rootFullPath: "/Root"),
                FileFixture(fullPath: "/Root/src/Util.swift", relativePath: "src/Util.swift", rootFullPath: "/Root")
            ]
        )
        try await assertParity(snapshot: snapshot, userPaths: ["App_Delegate.swift", "Util.swift", "Missing.swift"])
    }

    func testSingleComponentTieBreakSelectedFileAndDepth() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [
                FileFixture(fullPath: "/Root/a/App.swift", relativePath: "a/App.swift", rootFullPath: "/Root"),
                FileFixture(fullPath: "/Root/b/App.swift", relativePath: "b/App.swift", rootFullPath: "/Root")
            ],
            selectedFileFullPaths: ["/Root/b/App.swift"]
        )
        try await assertParity(snapshot: snapshot, userPaths: ["App.swift"])
    }

    // MARK: - Strict suffix / fuzzy suffix ladder (3, 5, whole path)

    func testStrictSuffixMatch() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Root/pkg/src/App.swift", relativePath: "pkg/src/App.swift", rootFullPath: "/Root")]
        )
        try await assertParity(snapshot: snapshot, userPaths: ["src/App.swift"])
    }

    func testFuzzySuffixThreeAndFiveAndWholePath() async throws {
        // NOTE on suffix-5 coverage: `candidatesFor`'s index-key derivation (last component,
        // last-two-components, extension) is WINDOW-INDEPENDENT -- it always reads the query
        // array's own last one/two components regardless of `suffixCount` (a property of the
        // real Swift `PathMatcher.candidatesFor`/`fuzzyMatchWithSuffixLimit`, not an artifact of
        // this port -- see `resolve.rs`'s `find_best_multi_component_match` doc comment). Because
        // of that, the suffix-3 and suffix-5 calls always gather the IDENTICAL candidate set, and
        // every pairwise component comparison the 3-window makes recurs byte-for-byte at the same
        // relative-from-the-end position in the 5-window. A candidate that fails EVERY comparison
        // the 3-window makes therefore also fails the (superset) 5-window -- suffix-5 can only
        // ever also return `nil` whenever suffix-3 already did. This makes the suffix-5 stage
        // structurally unable to be the FIRST stage to find a match for any fixture, in both the
        // real Swift implementation and this port; it is exercised here only as "whichever stage
        // finds this candidate", not as an independently decisive stage. See this slice's report
        // for the full finding.
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [
                FileFixture(fullPath: "/Root/pkg/app-utils/App.swift", relativePath: "pkg/app-utils/App.swift", rootFullPath: "/Root"),
                FileFixture(
                    fullPath: "/Root/a/b/c/app-utils/App.swift",
                    relativePath: "a/b/c/app-utils/App.swift",
                    rootFullPath: "/Root"
                )
            ]
        )
        let results = try await assertParity(
            snapshot: snapshot,
            userPaths: [
                "pkg/app_utils/App.swift",
                "b/c/app_utils/App.swift"
            ]
        )
        XCTAssertTrue(results.allSatisfy { $0 != nil }, "both fuzzy-suffix fixtures must resolve on the Swift reference side")
    }

    // MARK: - One-missing-component fallback

    func testOneMissingComponentFallback() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(
                fullPath: "/Root/pkg/extra/src/App.swift",
                relativePath: "pkg/extra/src/App.swift",
                rootFullPath: "/Root"
            )]
        )
        try await assertParity(snapshot: snapshot, userPaths: ["pkg/src/App.swift"])
    }

    // MARK: - `exactMatchOnly`

    func testExactMatchOnlyGating() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Root/src/App.swift", relativePath: "src/App.swift", rootFullPath: "/Root")]
        )
        let exactOptions = PathLocateOptions(
            exactMatchOnly: true,
            allowLeadingRootAliasTrim: true,
            allowHeadTrimAliases: false,
            allowAbsoluteSuffixFallback: false,
            useSelectedRootBias: false
        )
        try await assertParity(
            snapshot: snapshot,
            userPaths: ["/Root/src/App.swift", "App_Delegate.swift"],
            options: exactOptions
        )
    }

    // MARK: - Case-sensitive vs case-insensitive policy

    func testCaseSensitivePolicyRejectsCaseMismatch() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Root/src/App.swift", relativePath: "src/App.swift", rootFullPath: "/Root")],
            caseSensitive: true
        )
        let results = try await assertParity(snapshot: snapshot, userPaths: ["app.swift", "App.swift", "src/App.swift"])
        XCTAssertNil(results[0], "fixture bug: case-mismatched query must fail under caseSensitive policy")
        XCTAssertEqual(results[1]?.correctedPath, "src/App.swift")
        XCTAssertEqual(results[2]?.correctedPath, "src/App.swift")
    }

    func testCaseInsensitivePolicyMatchesCaseMismatch() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Root/src/App.swift", relativePath: "src/App.swift", rootFullPath: "/Root")],
            caseSensitive: false
        )
        try await assertParity(snapshot: snapshot, userPaths: ["app.swift"])
    }

    // MARK: - Absolute suffix fallback

    func testAbsoluteSuffixFallbackUnderUnloadedPrefix() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Root/src/App.swift", relativePath: "src/App.swift", rootFullPath: "/Root")],
            folders: [FolderFixture(fullPath: "/Root/src", relativePath: "src", rootFullPath: "/Root")]
        )
        try await assertParity(snapshot: snapshot, userPaths: ["/Elsewhere/Prefix/src/App.swift"])
    }

    func testAbsoluteSuffixFallbackLastTwoComponentScanWithNoFolderRecords() async throws {
        // No folder records are registered at all, so `findAbsoluteParentQualifiedTail`'s primary
        // per-parent-window folder-existence loop can never succeed for ANY window width -- this
        // exercises ONLY its last-resort "scan every file, compare last-two-components as a
        // lowercased suffix" fallback branch, the one place in the entire ladder port that
        // approximates `.lowercased()`/`hasSuffix` on arbitrary relative-path text with an
        // ASCII-only fold (see `resolve.rs`'s module doc, boundary note 3). ASCII-only fixture, so
        // bit-identical parity is expected here.
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Root/pkg/src/App.swift", relativePath: "pkg/src/App.swift", rootFullPath: "/Root")]
        )
        let results = try await assertParity(snapshot: snapshot, userPaths: ["/Unrelated/Prefix/src/App.swift"])
        XCTAssertEqual(
            results.first.flatMap(\.self)?.correctedPath, "pkg/src/App.swift",
            "fixture bug: the last-two-component fallback scan must actually resolve on the Swift reference side"
        )
    }

    // MARK: - No match

    func testNoMatchReturnsNilOnBothSides() async throws {
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Root/src/App.swift", relativePath: "src/App.swift", rootFullPath: "/Root")]
        )
        try await assertParity(snapshot: snapshot, userPaths: ["totally/unrelated/Path.rs"])
    }

    // MARK: - Unicode fixtures (İ, Devanagari virama) -- filename-only fuzzy stages, ASCII root names

    func testUnicodeTurkishDottedCapitalIFuzzyFilenameMatch() async throws {
        // İ (U+0130) vs ASCII "i" -- routed through the single-component fuzzy stage, whose wire
        // text is entirely Swift-precomputed `canonical()`/`cleaned()` text; NOT an alias/head-trim
        // fixture (see this file's top doc, boundary note 3).
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Root/src/istanbul.swift", relativePath: "src/istanbul.swift", rootFullPath: "/Root")]
        )
        try await assertParity(snapshot: snapshot, userPaths: ["\u{0130}stanbul.swift"])
    }

    func testUnicodeDevanagariViramaClusterMultiComponentMatch() async throws {
        let cluster = "\u{0915}\u{094D}\u{0916}"
        let stem = String(repeating: cluster, count: 5)
        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(
                fullPath: "/Root/pkg/test\(stem).swift",
                relativePath: "pkg/test\(stem).swift",
                rootFullPath: "/Root"
            )]
        )
        try await assertParity(snapshot: snapshot, userPaths: ["pkg/test\(stem).swift"])
    }

    // MARK: - >256-byte components

    func testOver256ByteComponentExactEqualityFallback() async throws {
        let longStem = String(repeating: "a", count: 300)
        let longName = "\(longStem).swift"
        var oneDiff = longStem
        oneDiff.removeLast()
        oneDiff += "b"
        let longNameOneDiff = "\(oneDiff).swift"

        let snapshot = buildSnapshot(
            roots: [RootFixture(fullPath: "/Root", name: "Root")],
            files: [FileFixture(fullPath: "/Root/src/\(longName)", relativePath: "src/\(longName)", rootFullPath: "/Root")]
        )
        let results = try await assertParity(snapshot: snapshot, userPaths: [longName, longNameOneDiff])
        XCTAssertEqual(
            results.first.flatMap(\.self)?.correctedPath, "src/\(longName)",
            "fixture bug: the byte-identical >256-byte candidate must resolve via the exact index hit"
        )
    }

    // MARK: - Generated multi-root workspace sweep

    func testGeneratedMultiRootWorkspaceSweep() async throws {
        // Files 0/1/2 are deliberately duplicated (identical relative path) across ALL roots, but
        // each duplicate set is set up so Swift's OWN explicit, order-independent tie-break
        // criteria decide a winner: file 0 via "root contains a selected file" (Root1 owns the
        // selected file 1, so Root1's copy of file 0 wins over Root0's/Root2's), file 1 via
        // "selected file" directly, file 2 via an explicit root-alias prefix in the query (so it's
        // never actually a multi-root lookup). File 3 is root-UNIQUE (root index baked into its
        // path) specifically because a query matching identical relative paths across 3
        // unselected, non-alias-qualified roots would hit `findStrictSuffixMatch`'s
        // Dictionary-iteration-order-dependent tie-break fallback -- see this slice's report,
        // "tie-break determinism" finding -- which is exactly the kind of genuine, Swift-itself-
        // nondeterministic tie this suite's fixtures are built to avoid (see this file's top doc).
        var roots: [RootFixture] = []
        var files: [FileFixture] = []
        for rootIndex in 0 ..< 3 {
            let rootPath = "/Workspace/Root\(rootIndex)"
            roots.append(RootFixture(fullPath: rootPath, name: "Root\(rootIndex)"))
            for fileIndex in 0 ..< 3 {
                let relativePath = "pkg\(fileIndex % 2)/Module\(fileIndex)/File\(fileIndex).swift"
                files.append(FileFixture(fullPath: "\(rootPath)/\(relativePath)", relativePath: relativePath, rootFullPath: rootPath))
            }
            let uniqueRelativePath = "pkg1/Module3_\(rootIndex)/File3_\(rootIndex).swift"
            files.append(FileFixture(
                fullPath: "\(rootPath)/\(uniqueRelativePath)", relativePath: uniqueRelativePath, rootFullPath: rootPath
            ))
        }
        let snapshot = buildSnapshot(
            roots: roots,
            files: files,
            selectedFileFullPaths: ["/Workspace/Root1/pkg1/Module1/File1.swift"]
        )
        let queries = [
            "File0.swift", // ambiguous, but Root1 wins via "root contains a selected file"
            "Root2/pkg0/Module2/File2.swift", // explicit root-alias prefix, never ambiguous
            "Module3_2/File3_2.swift", // root-unique, exercises the fuzzy suffix ladder cleanly
            "pkg1/Module1/File1.swift", // ambiguous, but Root1 wins via "selected file" directly
            "File1.swift", // ambiguous across roots -- selection bias should decide
            "totally/unrelated.swift"
        ]
        try await assertParity(snapshot: snapshot, userPaths: queries)
    }
}
