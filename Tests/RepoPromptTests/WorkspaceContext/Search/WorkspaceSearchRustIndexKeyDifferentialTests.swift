import AgentryCoreBridge
@testable import RepoPromptApp
import XCTest

/// P4-7b §4.3 (phase b2) -- the read facade + hard-assertion differential, no cutover. Runs the
/// Swift arm (`WorkspaceSearchRootPathIndex.search` + the *unchanged* Swift merge comparator) and
/// the Rust arm (`WorkspaceFileContextStore.searchRootQueryHandles`'s handles, queried via
/// `CoreInventorySnapshot.query(haystackVariant: .indexKey)`, merged with the *same* comparator)
/// over the same generation, and asserts ordered-candidate identity equality.
///
/// Corpus/query shape follows `PathSearchRustSwiftDifferentialTests`' P4-3b corpus in spirit
/// (leading star, `**` vs `*`, the 20-term space-AND cap, CJK/emoji/combining-mark paths, limit
/// boundaries) adapted onto real on-disk roots, plus the three root-visibility configurations
/// §4.3's done-when names: single visible root; two roots with unique names; two roots with
/// *ambiguous* (identical) names -- the configuration §1.5 Check A identified as the one where a
/// reconstructed tie-break key would have been wrong. This suite pins that P4-7b did not need to
/// reconstruct: `tie_break_key` rides the wire directly (b1), so ambiguous names are not expected
/// to move ordering on *either* arm -- this differential is the regression guard for that, not a
/// bug hunt.
///
/// Every corpus path here is unique root-wide, so `tie_break_key` never ties across two distinct
/// entries -- the C-engine-level duplicate-tie-break-key ordering case is already pinned by
/// `PathSearchRustSwiftDifferentialTests.testLimitTruncationTieBreakOrderingAcrossManyDuplicates`
/// against the stateless kernel; this suite does not need to re-prove it at the store-integration
/// layer.
final class WorkspaceSearchRustIndexKeyDifferentialTests: XCTestCase {
    // MARK: - Fixture

    private struct RootFixture {
        let url: URL
        let record: WorkspaceRootRecord
    }

    /// Writes a small adversarial corpus under `root` and returns the relative paths written, so
    /// callers can build query patterns that are guaranteed to have matches.
    @discardableResult
    private func writeCorpus(under root: URL, suffix: String) throws -> [String] {
        let relativePaths = [
            "Sources/App\(suffix).swift",
            "Sources/Utils/Helper\(suffix).swift",
            "README\(suffix).md",
            "docs/CafeNote\(suffix).md",
            "café/naïve\(suffix).swift",
            "中文/文件\(suffix).swift",
            "emoji/🎉Party\(suffix).swift",
            "Combining/e\u{301}-Decomposed\(suffix).swift"
        ]
        for relativePath in relativePaths {
            try write("content-\(relativePath)", to: root.appendingPathComponent(relativePath))
        }
        return relativePaths
    }

    private func makeRootFixture(store: WorkspaceFileContextStore, name: String, suffix: String) async throws -> RootFixture {
        let container = try makeTestDirectory(name: name)
        try writeCorpus(under: container, suffix: suffix)
        let record = try await store.loadRoot(path: container.path)
        return RootFixture(url: container, record: record)
    }

    /// Two roots sharing the exact same basename (`.name` is the directory's own last path
    /// component, `WorkspaceFileContextStore.loadRoot`'s `rootLoadName`) -- constructed by hand
    /// rather than through `makeTestDirectory` twice, which always mints a unique-suffixed
    /// basename and so can never collide.
    private func makeAmbiguousRootFixturePair(
        store: WorkspaceFileContextStore,
        sharedName: String
    ) async throws -> (a: RootFixture, b: RootFixture) {
        let container = try makeTestDirectory(name: "AmbiguousContainer")
        let rootAURL = container.appendingPathComponent("ParentA/\(sharedName)", isDirectory: true)
        let rootBURL = container.appendingPathComponent("ParentB/\(sharedName)", isDirectory: true)
        try writeCorpus(under: rootAURL, suffix: "A")
        try writeCorpus(under: rootBURL, suffix: "B")
        let recordA = try await store.loadRoot(path: rootAURL.path)
        let recordB = try await store.loadRoot(path: rootBURL.path)
        XCTAssertEqual(recordA.name, recordB.name, "fixture must produce genuinely ambiguous root names")
        return (RootFixture(url: rootAURL, record: recordA), RootFixture(url: rootBURL, record: recordB))
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

    // MARK: - Query corpus (P4-3b shape, adapted onto real roots)

    private func queryPatterns() -> [(pattern: String, limit: Int)] {
        var patterns: [(String, Int)] = [
            ("*.swift", 300),
            ("**.swift", 300),
            ("*Helper*", 300),
            ("Sources App", 300),
            ("café", 300),
            ("naïve", 300),
            ("中文", 300),
            ("文件", 300),
            ("🎉", 300),
            ("e\u{301}", 300),
            ("swift", 0),
            ("swift", 1),
            ("swift", 10000)
        ]
        // The 20-term space-AND cap: 25 distinct single-character terms, well past the cap. Both
        // engines must silently drop terms past the cap identically (agreement, not a specific
        // match outcome -- mirrors `PathSearchRustSwiftDifferentialTests
        // .testMoreThanTwentySpaceTermsExercisesTheCap`).
        let manyTerms = (0 ..< 25).map { String(UnicodeScalar(97 + $0)!) }.joined(separator: " ")
        patterns.append((manyTerms, 300))
        return patterns
    }

    // MARK: - Arms

    /// The Swift arm: `WorkspaceSearchRootPathIndex.search`, one call per root, merged with the
    /// exact comparator `WorkspaceSearchService.candidatePrecedes` uses (score is always `1` on
    /// both engines, so `WorkspaceInventoryOrdering.compareUTF8Binary(tieBreakKey)` carries the
    /// entire order; ties fall back to `searchCatalogEntryPrecedes`, unreachable here given the
    /// corpus's unique paths).
    private func swiftMergedIDs(
        rootPathIndexes: [WorkspaceSearchRootPathIndex],
        pattern: String,
        limit: Int
    ) -> [UUID] {
        rootPathIndexes
            .flatMap { $0.search(pattern, limit: limit) }
            .sorted(by: candidatePrecedesForTesting)
            .prefix(limit)
            .map(\.entry.id)
    }

    private func candidatePrecedesForTesting(
        _ lhs: WorkspaceSearchRootPathIndex.Candidate,
        _ rhs: WorkspaceSearchRootPathIndex.Candidate
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        switch WorkspaceInventoryOrdering.compareUTF8Binary(lhs.tieBreakKey, rhs.tieBreakKey) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return WorkspaceInventoryOrdering.searchCatalogEntryPrecedes(lhs.entry, rhs.entry)
        }
    }

    /// The Rust arm: one `CoreInventorySnapshot.query(haystackVariant: .indexKey)` call per root's
    /// handle, merged with the same shape of comparator over `tieBreakKey`/`id`.
    private func rustMergedIDs(
        handles: WorkspaceSearchRootQueryHandles,
        pattern: String,
        limit: Int
    ) async throws -> [UUID] {
        var all: [CoreInventoryQueryCandidateV1] = []
        for handle in handles.perRoot {
            let result = try await handle.snapshot.query(
                pattern: pattern,
                limit: UInt64(limit),
                haystackVariant: .indexKey,
                nonEmptyRelativePrefix: "",
                emptyRelativePathValue: ""
            )
            all.append(contentsOf: result.candidates)
        }
        return all
            .sorted { lhs, rhs in
                switch WorkspaceInventoryOrdering.compareUTF8Binary(lhs.tieBreakKey, rhs.tieBreakKey) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.id.uuidString < rhs.id.uuidString
                }
            }
            .prefix(limit)
            .map(\.id)
    }

    /// Empty query: Swift's `mergeRootEntries` k-way merges retained per-root entry arrays by
    /// `WorkspaceInventoryOrdering.searchCatalogEntryPrecedes` -- catalog order, not tie-break
    /// order (§4.2.1). Rust's analogue is `inventorySnapshotPage` (`CoreInventorySnapshot.page`),
    /// paging `generation.files`, itself sorted into the single-root branch's relative-path order
    /// (`rebuild_generation`'s doc comment) -- which, within one root, is the identical sequence
    /// full-path order produces (a constant per-root prefix does not change intra-root relative
    /// order), so per-root paged sequences and Swift's per-root `entries` arrays are directly
    /// comparable before this test's own k-way merge. Entries are files-only (§1.5.2's carry-
    /// forward) -- folders are not read here.
    private func swiftEmptyQueryMergedIDs(rootPathIndexes: [WorkspaceSearchRootPathIndex]) -> [UUID] {
        rootPathIndexes
            .flatMap(\.entries)
            .sorted(by: WorkspaceInventoryOrdering.searchCatalogEntryPrecedes)
            .map(\.id)
    }

    private func rustEmptyQueryMergedIDs(handles: WorkspaceSearchRootQueryHandles) async throws -> [UUID] {
        var all: [(fullPath: String, id: UUID)] = []
        for handle in handles.perRoot {
            var offset: UInt64 = 0
            while true {
                let page = try await handle.snapshot.page(offset: offset, limit: 4096)
                for file in page.files {
                    all.append((file.standardizedFullPath, file.id))
                }
                offset += page.returnedCount
                if !page.hasMore || page.returnedCount == 0 { break }
            }
        }
        return all
            .sorted { lhs, rhs in
                WorkspaceInventoryOrdering.compareUTF8Binary(lhs.fullPath, rhs.fullPath) == .orderedAscending
            }
            .map(\.id)
    }

    // MARK: - Ordered-candidate differential across the 3 root-visibility configurations

    private func assertOrderedCandidateParity(
        store: WorkspaceFileContextStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let recordsAndIndexes = await store.searchCatalogSnapshot(
            rootScope: .visibleWorkspace,
            requirement: .recordsAndPathIndexes
        )
        let rootPathIndexes = recordsAndIndexes.rootPathIndexes
        XCTAssertFalse(rootPathIndexes.isEmpty, "fixture must produce at least one path index", file: file, line: line)

        guard let handles = await store.searchRootQueryHandles(rootScope: .visibleWorkspace) else {
            XCTFail("expected search root query handles to open against a loaded workspace", file: file, line: line)
            return
        }
        XCTAssertEqual(handles.perRoot.count, rootPathIndexes.count, file: file, line: line)
        XCTAssertEqual(handles.scopeGeneration, recordsAndIndexes.generation, "b2's staleness key is the Swift scope generation, not any Rust generation (§1.5 Check B)", file: file, line: line)

        for (pattern, limit) in queryPatterns() {
            let swiftIDs = swiftMergedIDs(rootPathIndexes: rootPathIndexes, pattern: pattern, limit: limit)
            let rustIDs = try await rustMergedIDs(handles: handles, pattern: pattern, limit: limit)
            XCTAssertEqual(
                swiftIDs, rustIDs,
                "ordered candidate identity mismatch for pattern='\(pattern)' limit=\(limit)",
                file: file, line: line
            )
        }

        let swiftEmptyIDs = swiftEmptyQueryMergedIDs(rootPathIndexes: rootPathIndexes)
        let rustEmptyIDs = try await rustEmptyQueryMergedIDs(handles: handles)
        XCTAssertEqual(
            swiftEmptyIDs, rustEmptyIDs,
            "empty-query merge order mismatch (§4.2.1 -- must be catalog order, not tie-break order)",
            file: file, line: line
        )
    }

    func testOrderedCandidateParitySingleVisibleRoot() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        _ = try await makeRootFixture(store: store, name: "SingleRoot", suffix: "1")
        try await assertOrderedCandidateParity(store: store)
    }

    func testOrderedCandidateParityTwoRootsUniqueNames() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        _ = try await makeRootFixture(store: store, name: "UniqueRootAlpha", suffix: "A")
        _ = try await makeRootFixture(store: store, name: "UniqueRootBeta", suffix: "B")
        try await assertOrderedCandidateParity(store: store)
    }

    func testOrderedCandidateParityTwoRootsAmbiguousNames() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        _ = try await makeAmbiguousRootFixturePair(store: store, sharedName: "SharedRootName")
        try await assertOrderedCandidateParity(store: store)
    }

    /// `CoreInventorySnapshot.page`'s own doc comment: files and folders are paged by the same
    /// `offset`/`limit` window *independently*, and `returned_count`/`has_more` are computed from
    /// `files` alone (`rust/crates/ffi/src/api.rs`'s `returned_count = page.files.len()`). Every
    /// other fixture in this suite has under 4096 files, so `rustEmptyQueryMergedIDs`'s paging loop
    /// never advances past its first page and the `hasMore`/`offset` advance logic is untested --
    /// this is the one fixture that forces a second `page` call.
    func testEmptyQueryParityAcrossMultiplePagesOfFiles() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "MultiPageEmptyQuery")
        let fileCount = 4096 + 250
        for index in 0 ..< fileCount {
            try write("f\(index)", to: container.appendingPathComponent(String(format: "Many/%05d.swift", index)))
        }
        _ = try await store.loadRoot(path: container.path)

        let recordsAndIndexes = await store.searchCatalogSnapshot(
            rootScope: .visibleWorkspace,
            requirement: .recordsAndPathIndexes
        )
        let rootPathIndexes = recordsAndIndexes.rootPathIndexes
        XCTAssertEqual(rootPathIndexes.reduce(0) { $0 + $1.count }, fileCount)

        guard let handles = await store.searchRootQueryHandles(rootScope: .visibleWorkspace) else {
            return XCTFail("expected search root query handles to open against the large-corpus root")
        }

        let swiftEmptyIDs = swiftEmptyQueryMergedIDs(rootPathIndexes: rootPathIndexes)
        let rustEmptyIDs = try await rustEmptyQueryMergedIDs(handles: handles)
        XCTAssertEqual(swiftEmptyIDs.count, fileCount)
        XCTAssertEqual(
            swiftEmptyIDs, rustEmptyIDs,
            "empty-query merge order mismatch across a multi-page corpus (\(fileCount) files, more than one page at limit 4096)"
        )
    }

    // MARK: - Discoverability-set differential (RK-12)

    /// Compares the raw managed-only *ID sets* each engine filters on, not a derived "resulting
    /// discoverable records" set -- the latter would also differ by the Item 0 root-marker-folder
    /// synthesis (docs/architecture/rust-inventory-scope-v1.md §12.5), a Swift-only synthetic
    /// folder record Rust never claims to filter, and comparing resulting sets would misfire as an
    /// RK-12 disagreement it is not. `managedOnlyFileIDsForTesting`/`managedOnlyFolderIDsForTesting`
    /// are Swift's own filter membership; `inventoryRecordFacts`'s `isDiscoverable` is Rust's own
    /// independent `managed_only`-derived bit (`CoreInventoryFactRowV1.isDiscoverable`, decoded
    /// straight off the wire -- not re-derived from Swift's sets), so this is a genuine two-engine
    /// comparison, not a tautology.
    func testDiscoverabilitySetAgreesIncludingAfterManagedOnlyToggle() async throws {
        let store = WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
        let container = try makeTestDirectory(name: "DiscoverabilityDifferential")
        try write("*.ignored\n", to: container.appendingPathComponent(".gitignore"))
        let ignoredURL = container.appendingPathComponent("Hidden.ignored")
        try write("hidden", to: ignoredURL)
        try write("visible", to: container.appendingPathComponent("Visible.swift"))
        let record = try await store.loadRoot(path: container.path)

        // Before any toggle: no managed-only files exist yet on either side.
        try await assertDiscoverabilitySetsAgree(store: store, rootID: record.id)

        // Materialize a managed-only record the same way
        // `testExactAbsoluteScopeHelperExcludesManagedOnlyIgnoredFiles` does: resolving an
        // ignored-but-explicitly-requested file promotes it to a managed-only catalog member on
        // both engines (`WorkspaceInventoryScopeAuthority.setFileManagedOnly`'s `try?`-tolerant
        // call site).
        let readableService = WorkspaceReadableFileService(store: store)
        let readable = try await readableService.resolveReadableFile(ignoredURL.path, rootScope: .visibleWorkspace)
        guard case .workspace = readable else {
            return XCTFail("expected the ignored absolute read to materialize a managed-only record")
        }

        try await assertDiscoverabilitySetsAgree(store: store, rootID: record.id)
    }

    private func assertDiscoverabilitySetsAgree(
        store: WorkspaceFileContextStore,
        rootID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let swiftManagedOnlyFileIDs = await store.managedOnlyFileIDsForTesting()
        let swiftManagedOnlyFolderIDs = await store.managedOnlyFolderIDsForTesting()
        guard !swiftManagedOnlyFileIDs.isEmpty || !swiftManagedOnlyFolderIDs.isEmpty else {
            // Nothing managed-only yet on the Swift side -- the pre-toggle call in the test above.
            // Still worth confirming Rust agrees there is nothing to disagree about, over the files
            // that do exist.
            let pageIndex = try await debugPageIndex(store: store, rootID: rootID)
            for fileID in pageIndex.filesByID.keys {
                let facts = await store.inventoryRecordFacts(fileIDs: [fileID], folderIDs: [])
                XCTAssertEqual(facts.filesByID[fileID]?.isDiscoverable, true, "unexpected pre-toggle managed-only disagreement", file: file, line: line)
            }
            return
        }
        for fileID in swiftManagedOnlyFileIDs {
            let facts = await store.inventoryRecordFacts(fileIDs: [fileID], folderIDs: [])
            let rustManagedOnly = facts.filesByID[fileID].map { !$0.isDiscoverable } ?? true
            XCTAssertTrue(
                rustManagedOnly,
                "RK-12: Swift marks file \(fileID) managed-only but Rust's isDiscoverable disagrees",
                file: file, line: line
            )
        }
        for folderID in swiftManagedOnlyFolderIDs {
            let facts = await store.inventoryRecordFacts(fileIDs: [], folderIDs: [folderID])
            let rustManagedOnly = facts.foldersByID[folderID].map { !$0.isDiscoverable } ?? true
            XCTAssertTrue(
                rustManagedOnly,
                "RK-12: Swift marks folder \(folderID) managed-only but Rust's isDiscoverable disagrees",
                file: file, line: line
            )
        }
    }

    private func debugPageIndex(store: WorkspaceFileContextStore, rootID: UUID) async throws -> (filesByID: [UUID: WorkspaceFileRecord], foldersByID: [UUID: WorkspaceFolderRecord]) {
        let files = await store.files(inRoot: rootID)
        let folders = await store.folders(inRoot: rootID)
        return (
            Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) }),
            Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        )
    }
}
