import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import XCTest

/// Differential parity test for the P3-2 workspace-inventory catalog-builder Rust port: every
/// case below drives BOTH the Swift reference implementation (`WorkspaceInventoryCatalogBuilders`
/// / `WorkspaceInventoryOrdering`) and the Rust seam (`RustInventoryComputer`, the real
/// `AgentryCoreBridge` runtime, no mocking) with the same fixture, then asserts hard exact
/// equality between the two outputs -- no `XCTExpectFailure`.
///
/// One documented, deliberate scope boundary (see `WorkspaceInventoryOrdering.swift` and
/// `rust/crates/runtime/src/inventory/ordering.rs`): the FOLDER comparator uses Swift's native
/// Unicode-canonical `String` `<` on the Swift side but byte order on the Rust side (the FILE/
/// entry comparators already use byte order on both sides, so they never diverge). Every folder
/// name fixture in this file other than `testFolderComparatorByteOrderVersusCanonicalDivergence`
/// is therefore constrained to a single canonical UTF-8 encoding per logical name (no
/// multi-combining-mark permutations of the same visual string), so ordinary parity assertions
/// never depend on that boundary.
final class InventoryRustSwiftDifferentialTests: XCTestCase {
    // MARK: - App-level -> Core*V1 translation (test-owned; production has no such translator)

    private func core(_ root: WorkspaceRootRecord) -> CoreInventoryRootRecordV1 {
        CoreInventoryRootRecordV1(id: root.id, name: root.name, standardizedFullPath: root.standardizedFullPath)
    }

    private func core(_ file: WorkspaceFileRecord) -> CoreInventoryFileRecordV1 {
        CoreInventoryFileRecordV1(
            id: file.id,
            rootID: file.rootID,
            name: file.name,
            relativePath: file.relativePath,
            standardizedRelativePath: file.standardizedRelativePath,
            fullPath: file.fullPath,
            standardizedFullPath: file.standardizedFullPath,
            parentFolderID: file.parentFolderID,
            modificationDate: file.modificationDate
        )
    }

    private func core(_ folder: WorkspaceFolderRecord) -> CoreInventoryFolderRecordV1 {
        CoreInventoryFolderRecordV1(
            id: folder.id,
            rootID: folder.rootID,
            name: folder.name,
            relativePath: folder.relativePath,
            standardizedRelativePath: folder.standardizedRelativePath,
            fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath,
            parentFolderID: folder.parentFolderID,
            modificationDate: folder.modificationDate
        )
    }

    private func core(_ entry: WorkspaceSearchCatalogEntry) -> CoreInventorySearchCatalogEntryV1 {
        CoreInventorySearchCatalogEntryV1(
            id: entry.id,
            rootID: entry.rootID,
            rootPath: entry.rootPath,
            rootName: entry.rootName,
            name: entry.name,
            relativePath: entry.relativePath,
            standardizedRelativePath: entry.standardizedRelativePath,
            fullPath: entry.fullPath,
            standardizedFullPath: entry.standardizedFullPath,
            displayPath: entry.displayPath
        )
    }

    private func core(_ event: WorkspaceAppliedIndexBatchEvent) -> CoreInventoryAppliedIndexBatchEventV1 {
        CoreInventoryAppliedIndexBatchEventV1(
            rootID: event.rootID,
            upsertedFiles: event.upsertedFiles.map(core),
            upsertedFolders: event.upsertedFolders.map(core),
            removedFileIDs: event.removedFileIDs,
            removedFolderIDs: event.removedFolderIDs,
            removedFilePaths: event.removedFilePaths,
            removedFolderPaths: event.removedFolderPaths,
            modifiedFileIDs: event.modifiedFileIDs,
            modifiedFolderIDs: event.modifiedFolderIDs
        )
    }

    // MARK: - Comparison helpers (hard exact-equality, order included)

    private func assertFileEqual(
        _ swiftValue: WorkspaceFileRecord,
        _ rustValue: CoreInventoryFileRecordV1,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(swiftValue.id, rustValue.id, "id \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.rootID, rustValue.rootID, "rootID \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.name, rustValue.name, "name \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.relativePath, rustValue.relativePath, "relativePath \(message)", file: file, line: line)
        XCTAssertEqual(
            swiftValue.standardizedRelativePath, rustValue.standardizedRelativePath,
            "standardizedRelativePath \(message)", file: file, line: line
        )
        XCTAssertEqual(swiftValue.fullPath, rustValue.fullPath, "fullPath \(message)", file: file, line: line)
        XCTAssertEqual(
            swiftValue.standardizedFullPath, rustValue.standardizedFullPath,
            "standardizedFullPath \(message)", file: file, line: line
        )
        XCTAssertEqual(swiftValue.parentFolderID, rustValue.parentFolderID, "parentFolderID \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.modificationDate, rustValue.modificationDate, "modificationDate \(message)", file: file, line: line)
    }

    private func assertFilesEqual(
        _ swiftValues: [WorkspaceFileRecord],
        _ rustValues: [CoreInventoryFileRecordV1],
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(swiftValues.count, rustValues.count, "file count \(message)", file: file, line: line)
        for (swiftValue, rustValue) in zip(swiftValues, rustValues) {
            assertFileEqual(swiftValue, rustValue, message, file: file, line: line)
        }
    }

    private func assertFolderEqual(
        _ swiftValue: WorkspaceFolderRecord,
        _ rustValue: CoreInventoryFolderRecordV1,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(swiftValue.id, rustValue.id, "id \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.rootID, rustValue.rootID, "rootID \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.name, rustValue.name, "name \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.relativePath, rustValue.relativePath, "relativePath \(message)", file: file, line: line)
        XCTAssertEqual(
            swiftValue.standardizedRelativePath, rustValue.standardizedRelativePath,
            "standardizedRelativePath \(message)", file: file, line: line
        )
        XCTAssertEqual(swiftValue.fullPath, rustValue.fullPath, "fullPath \(message)", file: file, line: line)
        XCTAssertEqual(
            swiftValue.standardizedFullPath, rustValue.standardizedFullPath,
            "standardizedFullPath \(message)", file: file, line: line
        )
        XCTAssertEqual(swiftValue.parentFolderID, rustValue.parentFolderID, "parentFolderID \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.modificationDate, rustValue.modificationDate, "modificationDate \(message)", file: file, line: line)
    }

    private func assertFoldersEqual(
        _ swiftValues: [WorkspaceFolderRecord],
        _ rustValues: [CoreInventoryFolderRecordV1],
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(swiftValues.count, rustValues.count, "folder count \(message)", file: file, line: line)
        for (swiftValue, rustValue) in zip(swiftValues, rustValues) {
            assertFolderEqual(swiftValue, rustValue, message, file: file, line: line)
        }
    }

    private func assertEntryEqual(
        _ swiftValue: WorkspaceSearchCatalogEntry,
        _ rustValue: CoreInventorySearchCatalogEntryV1,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(swiftValue.id, rustValue.id, "id \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.rootID, rustValue.rootID, "rootID \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.rootPath, rustValue.rootPath, "rootPath \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.rootName, rustValue.rootName, "rootName \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.name, rustValue.name, "name \(message)", file: file, line: line)
        XCTAssertEqual(swiftValue.relativePath, rustValue.relativePath, "relativePath \(message)", file: file, line: line)
        XCTAssertEqual(
            swiftValue.standardizedRelativePath, rustValue.standardizedRelativePath,
            "standardizedRelativePath \(message)", file: file, line: line
        )
        XCTAssertEqual(swiftValue.fullPath, rustValue.fullPath, "fullPath \(message)", file: file, line: line)
        XCTAssertEqual(
            swiftValue.standardizedFullPath, rustValue.standardizedFullPath,
            "standardizedFullPath \(message)", file: file, line: line
        )
        XCTAssertEqual(swiftValue.displayPath, rustValue.displayPath, "displayPath \(message)", file: file, line: line)
    }

    private func assertEntriesEqual(
        _ swiftValues: [WorkspaceSearchCatalogEntry],
        _ rustValues: [CoreInventorySearchCatalogEntryV1],
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(swiftValues.count, rustValues.count, "entry count \(message)", file: file, line: line)
        for (swiftValue, rustValue) in zip(swiftValues, rustValues) {
            assertEntryEqual(swiftValue, rustValue, message, file: file, line: line)
        }
    }

    private func assertComponentsEqual(
        _ swiftValue: WorkspaceInventoryCatalogComponents,
        _ rustValue: CoreInventoryCatalogComponentsV1,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertFilesEqual(swiftValue.files, rustValue.files, message, file: file, line: line)
        assertFoldersEqual(swiftValue.folders, rustValue.folders, message, file: file, line: line)
        assertEntriesEqual(swiftValue.entries, rustValue.entries, message, file: file, line: line)
    }

    // MARK: - Fixtures

    private func makeRoot(name: String = "Root", fullPath: String = "/workspace/root") -> WorkspaceRootRecord {
        WorkspaceRootRecord(name: name, fullPath: fullPath)
    }

    private func makeFile(
        rootID: UUID,
        relativePath: String,
        parentFolderID: UUID? = nil,
        modificationDate: Date? = nil,
        rootFullPath: String = "/workspace/root"
    ) -> WorkspaceFileRecord {
        let name = (relativePath as NSString).lastPathComponent
        return WorkspaceFileRecord(
            rootID: rootID,
            name: name,
            relativePath: relativePath,
            fullPath: rootFullPath + "/" + relativePath,
            parentFolderID: parentFolderID,
            modificationDate: modificationDate
        )
    }

    private func makeFolder(
        rootID: UUID,
        relativePath: String,
        parentFolderID: UUID? = nil,
        modificationDate: Date? = nil,
        rootFullPath: String = "/workspace/root"
    ) -> WorkspaceFolderRecord {
        let name = (relativePath as NSString).lastPathComponent
        return WorkspaceFolderRecord(
            rootID: rootID,
            name: name,
            relativePath: relativePath,
            fullPath: rootFullPath + "/" + relativePath,
            parentFolderID: parentFolderID,
            modificationDate: modificationDate
        )
    }

    // MARK: - buildAuthoritativeCatalogComponents

    func testAuthoritativeCatalogEmptyInputsProduceEmptyComponents() async throws {
        let swiftResult = WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents(
            roots: [],
            filesByID: [:],
            foldersByID: [:],
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        let rustResult = try await RustInventoryComputer().buildAuthoritativeCatalogComponents(
            roots: [],
            filesByID: [:],
            foldersByID: [:],
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        assertComponentsEqual(swiftResult, rustResult, "empty")
    }

    func testAuthoritativeCatalogMultipleRootsWithNestedFolders() async throws {
        let rootA = makeRoot(name: "Alpha", fullPath: "/workspace/alpha")
        let rootB = makeRoot(name: "Beta", fullPath: "/workspace/beta")

        let folderA1 = makeFolder(rootID: rootA.id, relativePath: "src", rootFullPath: rootA.fullPath)
        let folderA2 = makeFolder(
            rootID: rootA.id, relativePath: "src/nested", parentFolderID: folderA1.id, rootFullPath: rootA.fullPath
        )
        let fileA1 = makeFile(rootID: rootA.id, relativePath: "README.md", rootFullPath: rootA.fullPath)
        let fileA2 = makeFile(
            rootID: rootA.id, relativePath: "src/main.swift", parentFolderID: folderA1.id, rootFullPath: rootA.fullPath
        )
        let fileA3 = makeFile(
            rootID: rootA.id, relativePath: "src/nested/deep.swift", parentFolderID: folderA2.id, rootFullPath: rootA.fullPath
        )

        let folderB1 = makeFolder(rootID: rootB.id, relativePath: "lib", rootFullPath: rootB.fullPath)
        let fileB1 = makeFile(
            rootID: rootB.id, relativePath: "lib/util.swift", parentFolderID: folderB1.id, rootFullPath: rootB.fullPath
        )

        let filesByID = Dictionary(uniqueKeysWithValues: [fileA1, fileA2, fileA3, fileB1].map { ($0.id, $0) })
        let foldersByID = Dictionary(uniqueKeysWithValues: [folderA1, folderA2, folderB1].map { ($0.id, $0) })

        let swiftResult = WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents(
            roots: [rootA, rootB],
            filesByID: filesByID,
            foldersByID: foldersByID,
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        let rustResult = try await RustInventoryComputer().buildAuthoritativeCatalogComponents(
            roots: [core(rootA), core(rootB)],
            filesByID: filesByID.mapValues(core),
            foldersByID: foldersByID.mapValues(core),
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        assertComponentsEqual(swiftResult, rustResult, "multi-root nested")
    }

    func testAuthoritativeCatalogFiltersManagedOnlyAndForeignRootFiles() async throws {
        let rootA = makeRoot(name: "Alpha", fullPath: "/workspace/alpha")
        let rootOutOfScope = makeRoot(name: "Outside", fullPath: "/workspace/outside")

        let fileVisible = makeFile(rootID: rootA.id, relativePath: "visible.swift", rootFullPath: rootA.fullPath)
        let fileManagedOnly = makeFile(rootID: rootA.id, relativePath: "managed.swift", rootFullPath: rootA.fullPath)
        let fileForeignRoot = makeFile(
            rootID: rootOutOfScope.id, relativePath: "foreign.swift", rootFullPath: rootOutOfScope.fullPath
        )
        let folderVisible = makeFolder(rootID: rootA.id, relativePath: "visibleFolder", rootFullPath: rootA.fullPath)
        let folderManagedOnly = makeFolder(rootID: rootA.id, relativePath: "managedFolder", rootFullPath: rootA.fullPath)

        let filesByID = Dictionary(uniqueKeysWithValues: [fileVisible, fileManagedOnly, fileForeignRoot].map { ($0.id, $0) })
        let foldersByID = Dictionary(uniqueKeysWithValues: [folderVisible, folderManagedOnly].map { ($0.id, $0) })
        let managedOnlyFileIDs: Set<UUID> = [fileManagedOnly.id]
        let managedOnlyFolderIDs: Set<UUID> = [folderManagedOnly.id]

        let swiftResult = WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents(
            roots: [rootA],
            filesByID: filesByID,
            foldersByID: foldersByID,
            managedOnlyFileIDs: managedOnlyFileIDs,
            managedOnlyFolderIDs: managedOnlyFolderIDs
        )
        let rustResult = try await RustInventoryComputer().buildAuthoritativeCatalogComponents(
            roots: [core(rootA)],
            filesByID: filesByID.mapValues(core),
            foldersByID: foldersByID.mapValues(core),
            managedOnlyFileIDs: managedOnlyFileIDs,
            managedOnlyFolderIDs: managedOnlyFolderIDs
        )
        assertComponentsEqual(swiftResult, rustResult, "managed-only + foreign-root filtering")
        // Sanity: the filtering actually happened, so parity isn't vacuous.
        XCTAssertEqual(swiftResult.files.map(\.id), [fileVisible.id])
        XCTAssertEqual(swiftResult.folders.map(\.id), [folderVisible.id])
    }

    func testAuthoritativeCatalogUnicodeFileNamesIncludingCJKEmojiAndCombiningMarks() async throws {
        let root = makeRoot(name: "Unicode\u{20}\u{6839}", fullPath: "/workspace/unicode")
        // File/entry ordering uses byte-order (`compareUTF8Binary`) on BOTH sides -- unlike
        // folders, these are safe to exercise with combining-mark permutations of the same
        // logical name.
        let names = [
            "\u{65e5}\u{672c}\u{8a9e}.swift", // CJK: "Japanese" in kanji/hiragana
            "\u{1f600}emoji.swift", // leading emoji
            "cafe\u{0301}.swift", // "café" as e + combining acute (NFD)
            "caf\u{00e9}.swift", // "café" as precomposed é (NFC)
            "\u{0410}\u{0411}\u{0412}.swift", // Cyrillic
            "plain.swift"
        ]
        let files = names.map { makeFile(rootID: root.id, relativePath: $0, rootFullPath: root.fullPath) }
        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })

        let swiftResult = WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents(
            roots: [root],
            filesByID: filesByID,
            foldersByID: [:],
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        let rustResult = try await RustInventoryComputer().buildAuthoritativeCatalogComponents(
            roots: [core(root)],
            filesByID: filesByID.mapValues(core),
            foldersByID: [:],
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        assertComponentsEqual(swiftResult, rustResult, "unicode file names")
        XCTAssertEqual(swiftResult.files.count, names.count)
    }

    func testAuthoritativeCatalogPathCollisionTieBreaksByUUIDString() async throws {
        // Two files that sort identically on standardizedFullPath (same root, same relative
        // path is impossible with distinct IDs in the same dictionary keyed by ID, so instead
        // force an identical *sort key* via two different roots whose root-qualified full paths
        // collide) -- this exercises the UUID-string tiebreak in both comparators, not just the
        // primary path key.
        let rootA = makeRoot(name: "RootA", fullPath: "/workspace/shared")
        let rootB = makeRoot(name: "RootB", fullPath: "/workspace/shared")
        // Deliberately construct two well-known, distinct UUIDs so the tiebreak is exercised
        // deterministically rather than depending on random UUID generation order.
        let idLow = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let idHigh = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFE"))
        let fileLow = WorkspaceFileRecord(
            id: idLow, rootID: rootA.id, name: "same.swift", relativePath: "same.swift",
            fullPath: "/workspace/shared/same.swift", parentFolderID: nil
        )
        let fileHigh = WorkspaceFileRecord(
            id: idHigh, rootID: rootB.id, name: "same.swift", relativePath: "same.swift",
            fullPath: "/workspace/shared/same.swift", parentFolderID: nil
        )
        let filesByID = [fileLow.id: fileLow, fileHigh.id: fileHigh]

        let swiftResult = WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents(
            roots: [rootA, rootB],
            filesByID: filesByID,
            foldersByID: [:],
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        let rustResult = try await RustInventoryComputer().buildAuthoritativeCatalogComponents(
            roots: [core(rootA), core(rootB)],
            filesByID: filesByID.mapValues(core),
            foldersByID: [:],
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        assertComponentsEqual(swiftResult, rustResult, "path-collision UUID tiebreak")
        // Sanity: the tiebreak actually engaged (both share the same standardizedFullPath), and
        // both sides agree on which UUID sorts first (lexicographically-lower uuidString).
        XCTAssertEqual(swiftResult.files.map(\.id), [idLow, idHigh])
    }

    func testAuthoritativeCatalogModificationDatesRoundTripIncludingNilAndExactValues() async throws {
        let root = makeRoot()
        let withDate = makeFile(
            rootID: root.id, relativePath: "dated.swift",
            modificationDate: Date(timeIntervalSinceReferenceDate: 12345.5), rootFullPath: root.fullPath
        )
        let withoutDate = makeFile(rootID: root.id, relativePath: "undated.swift", rootFullPath: root.fullPath)
        let folderWithDate = makeFolder(
            rootID: root.id, relativePath: "datedFolder",
            modificationDate: Date(timeIntervalSinceReferenceDate: 0), rootFullPath: root.fullPath
        )
        let folderWithoutDate = makeFolder(rootID: root.id, relativePath: "undatedFolder", rootFullPath: root.fullPath)

        let filesByID = [withDate.id: withDate, withoutDate.id: withoutDate]
        let foldersByID = [folderWithDate.id: folderWithDate, folderWithoutDate.id: folderWithoutDate]

        let swiftResult = WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents(
            roots: [root],
            filesByID: filesByID,
            foldersByID: foldersByID,
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        let rustResult = try await RustInventoryComputer().buildAuthoritativeCatalogComponents(
            roots: [core(root)],
            filesByID: filesByID.mapValues(core),
            foldersByID: foldersByID.mapValues(core),
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        assertComponentsEqual(swiftResult, rustResult, "modification-date round trip")
    }

    // MARK: - Documented folder-comparator boundary

    func testFolderComparatorByteOrderVersusCanonicalDivergenceIsDocumented() async throws {
        // "café" as precomposed (NFC) vs. decomposed (NFD) -- canonically equivalent, byte-
        // different. Swift's native `String` `==`/`<` treats these as equal (Unicode canonical
        // equivalence); raw UTF-8 byte comparison does not. This is the exact, previously-scoped
        // divergence documented in `WorkspaceInventoryOrdering.searchCatalogFolderPrecedes` and
        // `rust/crates/runtime/src/inventory/ordering.rs`. Unlike every other fixture in this
        // file, this test deliberately drives BOTH comparators on real byte-different-but-
        // canonically-equal folder names and asserts they produce OPPOSITE orders -- pinning the
        // divergence as a demonstrated fact via the real Rust seam, rather than a hand-simulated
        // byte comparison, and without letting it leak into the general parity fixture pool.
        let precomposed = "caf\u{00e9}" // precomposed é (U+00E9): NFC
        let decomposed = "cafe\u{0301}" // e + combining acute accent (U+0301): NFD
        XCTAssertNotEqual(Array(precomposed.utf8), Array(decomposed.utf8), "fixture must be byte-different")
        XCTAssertEqual(precomposed, decomposed, "Swift String equality is Unicode-canonical, not byte-exact")

        let root = makeRoot()
        // Chosen so the UUID tiebreak Swift falls back to (paths are canonically equal) picks the
        // OPPOSITE order from raw UTF-8 byte comparison (decomposed's bytes sort first) -- this is
        // what makes the divergence visible rather than accidental.
        let lowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highID = try XCTUnwrap(UUID(uuidString: "ffffffff-ffff-ffff-ffff-fffffffffffe"))
        let folderPrecomposed = WorkspaceFolderRecord(
            id: lowID, rootID: root.id, name: precomposed, relativePath: precomposed,
            fullPath: root.fullPath + "/" + precomposed, parentFolderID: nil
        )
        let folderDecomposed = WorkspaceFolderRecord(
            id: highID, rootID: root.id, name: decomposed, relativePath: decomposed,
            fullPath: root.fullPath + "/" + decomposed, parentFolderID: nil
        )
        XCTAssertEqual(
            folderPrecomposed.standardizedFullPath, folderDecomposed.standardizedFullPath,
            "fixture requires Unicode-canonically-equal standardizedFullPath"
        )
        XCTAssertNotEqual(
            Array(folderPrecomposed.standardizedFullPath.utf8), Array(folderDecomposed.standardizedFullPath.utf8),
            "fixture requires byte-different standardizedFullPath"
        )
        let foldersByID = [folderPrecomposed.id: folderPrecomposed, folderDecomposed.id: folderDecomposed]

        // Swift's comparator: canonically-equal standardizedFullPath -> falls through to the
        // UUID-string tiebreak (P3-2 scope boundary: this is Swift-only behavior, not ported).
        let swiftComponents = WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents(
            roots: [root], filesByID: [:], foldersByID: foldersByID,
            managedOnlyFileIDs: [], managedOnlyFolderIDs: []
        )
        XCTAssertEqual(swiftComponents.folders.map(\.id), [folderPrecomposed.id, folderDecomposed.id])

        // Rust's comparator: real byte-order comparison of standardizedFullPath -- exercised
        // through the actual Rust seam, not a hand-simulated byte comparison.
        let rustComponents = try await RustInventoryComputer().buildAuthoritativeCatalogComponents(
            roots: [core(root)], filesByID: [:], foldersByID: foldersByID.mapValues(core),
            managedOnlyFileIDs: [], managedOnlyFolderIDs: []
        )
        XCTAssertEqual(rustComponents.folders.map(\.id), [folderDecomposed.id, folderPrecomposed.id])

        // The documented boundary, made explicit: the two comparators disagree on this input.
        XCTAssertNotEqual(swiftComponents.folders.map(\.id), rustComponents.folders.map(\.id))
    }

    // MARK: - buildPendingCatalogComponents

    func testPendingCatalogSingleRootSortsByRootRelativePath() async throws {
        let root = makeRoot()
        let fileB = makeFile(rootID: root.id, relativePath: "b.swift", rootFullPath: root.fullPath)
        let fileA = makeFile(rootID: root.id, relativePath: "a.swift", rootFullPath: root.fullPath)
        let folderZ = makeFolder(rootID: root.id, relativePath: "z", rootFullPath: root.fullPath)
        let folderA = makeFolder(rootID: root.id, relativePath: "a", rootFullPath: root.fullPath)
        let filesByID = [fileB.id: fileB, fileA.id: fileA]
        let foldersByID = [folderZ.id: folderZ, folderA.id: folderA]

        let swiftResult = WorkspaceInventoryCatalogBuilders.buildPendingCatalogComponents(
            root: root, filesByID: filesByID, foldersByID: foldersByID
        )
        let rustResult = try await RustInventoryComputer().buildPendingCatalogComponents(
            root: core(root), filesByID: filesByID.mapValues(core), foldersByID: foldersByID.mapValues(core)
        )
        assertComponentsEqual(swiftResult, rustResult, "pending catalog")
        XCTAssertEqual(swiftResult.files.map(\.id), [fileA.id, fileB.id])
    }

    func testPendingCatalogEmptyInputsProduceEmptyComponents() async throws {
        let root = makeRoot()
        let swiftResult = WorkspaceInventoryCatalogBuilders.buildPendingCatalogComponents(
            root: root, filesByID: [:], foldersByID: [:]
        )
        let rustResult = try await RustInventoryComputer().buildPendingCatalogComponents(
            root: core(root), filesByID: [:], foldersByID: [:]
        )
        assertComponentsEqual(swiftResult, rustResult, "pending catalog empty")
    }

    // MARK: - buildRootCatalogShardPatch

    /// Drives one `buildRootCatalogShardPatch` event through both builders and asserts hard
    /// equality of the resulting shard, mutation count, and changed-path-index ID set.
    private func assertShardPatchParity(
        event: WorkspaceAppliedIndexBatchEvent,
        previousFiles: [WorkspaceFileRecord],
        previousFolders: [WorkspaceFolderRecord],
        filesByID: [UUID: WorkspaceFileRecord],
        foldersByID: [UUID: WorkspaceFolderRecord],
        maxLogicalMutationCount: Int,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (swift: WorkspaceInventoryCatalogShardPatch?, rust: CoreInventoryCatalogShardPatchV1?) {
        let swiftResult = WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch(
            event: event,
            previousFiles: previousFiles,
            previousFolders: previousFolders,
            filesByID: filesByID,
            foldersByID: foldersByID,
            maxLogicalMutationCount: maxLogicalMutationCount
        )
        let rustResult = try await RustInventoryComputer().buildRootCatalogShardPatch(
            event: core(event),
            previousFiles: previousFiles.map(core),
            previousFolders: previousFolders.map(core),
            filesByID: filesByID.mapValues(core),
            foldersByID: foldersByID.mapValues(core),
            maxLogicalMutationCount: maxLogicalMutationCount
        )
        XCTAssertEqual(swiftResult == nil, rustResult == nil, "nil-outcome parity \(message)", file: file, line: line)
        if let swiftPatch = swiftResult, let rustPatch = rustResult {
            assertFilesEqual(swiftPatch.files, rustPatch.files, message, file: file, line: line)
            assertFoldersEqual(swiftPatch.folders, rustPatch.folders, message, file: file, line: line)
            XCTAssertEqual(
                swiftPatch.logicalMutationCount, rustPatch.logicalMutationCount,
                "logicalMutationCount \(message)", file: file, line: line
            )
            XCTAssertEqual(
                swiftPatch.pathIndexChangedFileIDs, rustPatch.pathIndexChangedFileIDs,
                "pathIndexChangedFileIDs \(message)", file: file, line: line
            )
        }
        return (swiftResult, rustResult)
    }

    func testShardPatchAppliesFileRemoval() async throws {
        let root = makeRoot()
        let fileKeep = makeFile(rootID: root.id, relativePath: "keep.swift", rootFullPath: root.fullPath)
        let fileRemove = makeFile(rootID: root.id, relativePath: "remove.swift", rootFullPath: root.fullPath)
        let previousFiles = [fileKeep, fileRemove].sorted(by: WorkspaceInventoryOrdering.searchRootCatalogFilePrecedes)
        let event = WorkspaceAppliedIndexBatchEvent(
            rootID: root.id, rootPath: root.fullPath, generation: 1,
            removedFilePaths: [fileRemove.relativePath]
        )
        let (swiftResult, _) = try await assertShardPatchParity(
            event: event, previousFiles: previousFiles, previousFolders: [],
            filesByID: [fileKeep.id: fileKeep], foldersByID: [:], maxLogicalMutationCount: 1,
            "remove"
        )
        XCTAssertEqual(swiftResult?.files.map(\.id), [fileKeep.id])
    }

    func testShardPatchAppliesFileAddition() async throws {
        let root = makeRoot()
        let fileExisting = makeFile(rootID: root.id, relativePath: "existing.swift", rootFullPath: root.fullPath)
        let fileNew = makeFile(rootID: root.id, relativePath: "added.swift", rootFullPath: root.fullPath)
        let event = WorkspaceAppliedIndexBatchEvent(
            rootID: root.id, rootPath: root.fullPath, generation: 1,
            upsertedFiles: [fileNew]
        )
        let (swiftResult, _) = try await assertShardPatchParity(
            event: event, previousFiles: [fileExisting], previousFolders: [],
            filesByID: [fileNew.id: fileNew], foldersByID: [:], maxLogicalMutationCount: 1,
            "add"
        )
        XCTAssertEqual(Set(swiftResult?.files.map(\.id) ?? []), Set([fileExisting.id, fileNew.id]))
    }

    /// "Rename" as this store models it: the file's identity (`id`) is stable across the event;
    /// only its path changed, surfaced via `modifiedFileIDs` + an updated `filesByID` entry (not
    /// a remove+upsert pair, which would count as two touched IDs against the mutation budget).
    func testShardPatchAppliesFileRenameByIDPreservingModification() async throws {
        let root = makeRoot()
        let original = makeFile(rootID: root.id, relativePath: "old-name.swift", rootFullPath: root.fullPath)
        let renamed = WorkspaceFileRecord(
            id: original.id, rootID: root.id, name: "new-name.swift", relativePath: "new-name.swift",
            fullPath: root.fullPath + "/new-name.swift", parentFolderID: nil
        )
        let event = WorkspaceAppliedIndexBatchEvent(
            rootID: root.id, rootPath: root.fullPath, generation: 1,
            modifiedFileIDs: [original.id]
        )
        let (swiftResult, _) = try await assertShardPatchParity(
            event: event, previousFiles: [original], previousFolders: [],
            filesByID: [renamed.id: renamed], foldersByID: [:], maxLogicalMutationCount: 1,
            "rename"
        )
        XCTAssertEqual(swiftResult?.files.map(\.id), [renamed.id])
        XCTAssertEqual(swiftResult?.files.first?.standardizedRelativePath, "new-name.swift")
    }

    func testShardPatchReturnsNilForNotPatchableOutcomeOnBothSides() async throws {
        let root = makeRoot()
        let foreignRootID = UUID()
        // Upserted file's rootID disagrees with the event's root -> both builders must decline
        // (return nil) rather than silently applying an inconsistent patch.
        let mismatched = makeFile(rootID: foreignRootID, relativePath: "a.swift", rootFullPath: root.fullPath)
        let event = WorkspaceAppliedIndexBatchEvent(
            rootID: root.id,
            rootPath: root.fullPath,
            generation: 1,
            upsertedFiles: [mismatched]
        )
        let filesByID = [mismatched.id: mismatched]

        let swiftResult = WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch(
            event: event,
            previousFiles: [],
            previousFolders: [],
            filesByID: filesByID,
            foldersByID: [:],
            maxLogicalMutationCount: 1
        )
        let rustResult = try await RustInventoryComputer().buildRootCatalogShardPatch(
            event: core(event),
            previousFiles: [],
            previousFolders: [],
            filesByID: filesByID.mapValues(core),
            foldersByID: [:],
            maxLogicalMutationCount: 1
        )
        XCTAssertNil(swiftResult, "Swift builder should decline a root-mismatched upsert")
        XCTAssertNil(rustResult, "Rust seam should decline a root-mismatched upsert")
    }

    func testShardPatchExceedingMutationBudgetReturnsUnchangedShardOnBothSides() async throws {
        let root = makeRoot()
        let fileA = makeFile(rootID: root.id, relativePath: "a.swift", rootFullPath: root.fullPath)
        let fileB = makeFile(rootID: root.id, relativePath: "b.swift", rootFullPath: root.fullPath)
        let previousFiles = [fileA, fileB].sorted(by: WorkspaceInventoryOrdering.searchRootCatalogFilePrecedes)
        // Two modifications in one event but a budget of only 1 logical mutation -> Swift
        // returns the shard unchanged with `logicalMutationCount` reporting the actual
        // (over-budget) count. `filesByID` is keyed by each record's OWN `id` everywhere else in
        // this suite (and, implicitly, by the compact wire's `files_by_id` row pool, which
        // reconstructs its map from each row's own id field) -- these updated records MUST keep
        // `fileA.id` / `fileB.id` rather than `makeFile`'s fresh default id.
        let newFileA = WorkspaceFileRecord(
            id: fileA.id, rootID: root.id, name: "a.swift", relativePath: "a.swift",
            fullPath: root.fullPath + "/a.swift", parentFolderID: nil,
            modificationDate: Date(timeIntervalSinceReferenceDate: 1)
        )
        let newFileB = WorkspaceFileRecord(
            id: fileB.id, rootID: root.id, name: "b.swift", relativePath: "b.swift",
            fullPath: root.fullPath + "/b.swift", parentFolderID: nil,
            modificationDate: Date(timeIntervalSinceReferenceDate: 2)
        )
        let event = WorkspaceAppliedIndexBatchEvent(
            rootID: root.id,
            rootPath: root.fullPath,
            generation: 1,
            modifiedFileIDs: [fileA.id, fileB.id]
        )
        let filesByID = [fileA.id: newFileA, fileB.id: newFileB]

        let swiftResult = WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch(
            event: event,
            previousFiles: previousFiles,
            previousFolders: [],
            filesByID: filesByID,
            foldersByID: [:],
            maxLogicalMutationCount: 1
        )
        let rustResult = try await RustInventoryComputer().buildRootCatalogShardPatch(
            event: core(event),
            previousFiles: previousFiles.map(core),
            previousFolders: [],
            filesByID: filesByID.mapValues(core),
            foldersByID: [:],
            maxLogicalMutationCount: 1
        )
        let swiftPatch = try XCTUnwrap(swiftResult)
        let rustPatch = try XCTUnwrap(rustResult)
        assertFilesEqual(swiftPatch.files, rustPatch.files, "over-budget shard patch")
        XCTAssertEqual(swiftPatch.logicalMutationCount, rustPatch.logicalMutationCount)
        XCTAssertEqual(swiftPatch.pathIndexChangedFileIDs, rustPatch.pathIndexChangedFileIDs)
        XCTAssertEqual(swiftPatch.logicalMutationCount, 2)
        XCTAssertTrue(swiftPatch.pathIndexChangedFileIDs.isEmpty)
        // The shard must be truly UNCHANGED, not merely same-count/same-ids: neither side may
        // have applied `newFileA`/`newFileB`'s updated modification dates.
        XCTAssertEqual(swiftPatch.files, previousFiles)
        assertFilesEqual(previousFiles, rustPatch.files, "over-budget shard patch must equal previousFiles exactly")
    }

    // MARK: - mergeRootCatalogShardFileEntryLists

    func testMergeEmptyShardListProducesEmptyLists() async throws {
        let swiftResult = WorkspaceInventoryCatalogBuilders.mergeRootCatalogShardFileEntryLists([])
        let rustResult = try await RustInventoryComputer().mergeRootCatalogShardFileEntryLists([])
        assertFilesEqual(swiftResult.files, rustResult.files, "merge empty")
        assertEntriesEqual(swiftResult.entries, rustResult.entries, "merge empty")
    }

    func testMergeMultipleShardsInterleavesInGlobalOrder() async throws {
        let root = makeRoot()
        func shard(_ relativePaths: [String]) -> (files: [WorkspaceFileRecord], entries: [WorkspaceSearchCatalogEntry]) {
            let files = relativePaths
                .map { makeFile(rootID: root.id, relativePath: $0, rootFullPath: root.fullPath) }
                .sorted(by: WorkspaceInventoryOrdering.searchCatalogFilePrecedes)
            let entries = files.map { WorkspaceSearchCatalogEntry(file: $0, root: root) }
            return (files, entries)
        }
        let shardOne = shard(["b.swift", "d.swift", "f.swift"])
        let shardTwo = shard(["a.swift", "c.swift"])
        let shardThree = shard(["e.swift"])
        let shardEmpty: (files: [WorkspaceFileRecord], entries: [WorkspaceSearchCatalogEntry]) = (files: [], entries: [])

        let swiftShards = [shardOne, shardTwo, shardThree, shardEmpty]
        let swiftResult = WorkspaceInventoryCatalogBuilders.mergeRootCatalogShardFileEntryLists(swiftShards)

        let rustShards: [(files: [CoreInventoryFileRecordV1], entries: [CoreInventorySearchCatalogEntryV1])] = swiftShards.map {
            (files: $0.files.map(core), entries: $0.entries.map(core))
        }
        let rustResult = try await RustInventoryComputer().mergeRootCatalogShardFileEntryLists(rustShards)

        assertFilesEqual(swiftResult.files, rustResult.files, "merge multi-shard")
        assertEntriesEqual(swiftResult.entries, rustResult.entries, "merge multi-shard")
        XCTAssertEqual(swiftResult.files.map(\.standardizedRelativePath), ["a.swift", "b.swift", "c.swift", "d.swift", "e.swift", "f.swift"])
    }

    // MARK: - End-to-end UUID wire round trip

    func testUUIDWireRoundTripPreservesExactUUIDString() async throws {
        let knownIDs = try [
            XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")),
            XCTUnwrap(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")),
            XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        ]
        let root = makeRoot()
        let files = knownIDs.enumerated().map { index, id in
            WorkspaceFileRecord(
                id: id, rootID: root.id, name: "f\(index).swift", relativePath: "f\(index).swift",
                fullPath: root.fullPath + "/f\(index).swift", parentFolderID: nil
            )
        }
        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })

        let rustResult = try await RustInventoryComputer().buildAuthoritativeCatalogComponents(
            roots: [core(root)],
            filesByID: filesByID.mapValues(core),
            foldersByID: [:],
            managedOnlyFileIDs: [],
            managedOnlyFolderIDs: []
        )
        let decodedIDStrings = Set(rustResult.files.map { $0.id.uuidString.lowercased() })
        let expectedIDStrings = Set(knownIDs.map { $0.uuidString.lowercased() })
        XCTAssertEqual(decodedIDStrings, expectedIDStrings)
    }
}
