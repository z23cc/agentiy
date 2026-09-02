import AgentryCoreBridge
@testable import RepoPromptApp
import XCTest

/// Differential parity test for the P3-4 pure-Rust token-accounting port
/// (`rust/crates/runtime/src/tokenacct/`): every case below drives BOTH the real Swift
/// `TokenCalculationService` (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/TokenAccounting/
/// TokenCalculationService.swift`) and the real Rust seam (`RustTokenAccountingProbe`, the real
/// `AgentryCoreBridge` runtime, no mocking) over the SAME input, then asserts IDENTICAL counts,
/// render modes, line counts, `TokenInfo` formatted strings/percentages, folder rollups, and
/// composed codemap content. Hard assertions from day one, no `XCTExpectFailure`.
///
/// # Slice assembly: fed from the REAL builder, not synthesized
///
/// Per `rust/crates/runtime/src/tokenacct/entries.rs`'s module doc, this port does not re-derive
/// slice assemblies from `ranges` -- callers precompute-and-carry `combinedText`/
/// `totalCharacters`. This harness computes those the same way `TokenCalculationService` itself
/// does: by calling the REAL `FileViewModel.buildSliceAssembly(from:ranges:)`.
///
/// # `renderMode` asymmetry
///
/// Swift's `PromptEntriesEvaluation.RenderMode` has only `.full`/`.slice`/`.codemap` -- resolved
/// AND unresolved codemap entries both report `.codemap` (distinguished only by `displayTokens ==
/// 0`/`displayLineCount == nil`). The Rust wire's `render_mode` distinguishes them as separate
/// values (`2` vs `3`) for its own internal-consistency checks. `assertRenderModeParity` below
/// folds both Rust codemap variants onto Swift's single `.codemap` case.
final class TokenAccountingRustSwiftDifferentialTests: XCTestCase {
    override func setUpWithError() throws {
        try MigrationDifferentialGate.requireEnabled(
            "Token accounting has no production Rust caller; this Swift/Rust differential is opt-in"
        )
        try super.setUpWithError()
    }

    // MARK: - Fixture construction

    private struct EntrySpec {
        var relativePath: String
        var isCodemapRequested: Bool = false
        var codeMapContent: String?
        var availableCodeMapTokenCount: Int = 0
        var ranges: [LineRange]?
        var loadedContent: String?
        var cachedFullTokenCount: Int?
    }

    /// Builds the real `PromptFileEntrySnapshot` (drives the real Swift service) and its
    /// ordinal `CoreTokenAccountingEntryV1` counterpart (drives the Rust seam) from ONE spec,
    /// computing slice assembly via the REAL `FileViewModel.buildSliceAssembly` exactly the way
    /// `TokenCalculationService.buildSliceAssemblies` does (ranges present-and-nonempty AND
    /// loaded content present).
    private func buildPair(_ spec: EntrySpec) -> (PromptFileEntrySnapshot, CoreTokenAccountingEntryV1) {
        let fileID = UUID()
        let snapshot = PromptFileEntrySnapshot(
            fileID: fileID,
            relativePath: spec.relativePath,
            renderedDisplayPath: spec.relativePath,
            isCodemapRequested: spec.isCodemapRequested,
            ranges: spec.ranges,
            cachedFullTokenCount: spec.cachedFullTokenCount,
            loadedContent: spec.loadedContent,
            codeMapContent: spec.codeMapContent,
            availableCodeMapTokenCount: spec.availableCodeMapTokenCount
        )

        var sliceCombinedText: String?
        var sliceTotalCharacters = 0
        if let ranges = spec.ranges, !ranges.isEmpty, let content = spec.loadedContent {
            let assembly = FileViewModel.buildSliceAssembly(from: content, ranges: ranges)
            sliceCombinedText = assembly.combinedText
            sliceTotalCharacters = assembly.totalCharacters
        }

        let coreEntry = CoreTokenAccountingEntryV1(
            isCodemapRequested: spec.isCodemapRequested,
            codemapContent: spec.codeMapContent,
            availableCodemapTokenCount: spec.availableCodeMapTokenCount,
            sliceCombinedText: sliceCombinedText,
            sliceTotalCharacters: sliceTotalCharacters,
            loadedContent: spec.loadedContent,
            loadedContentCharCount: spec.loadedContent?.count ?? 0,
            cachedFullTokenCount: spec.cachedFullTokenCount,
            relativePath: spec.relativePath
        )
        return (snapshot, coreEntry)
    }

    private func assertRenderModeParity(
        _ swift: PromptEntriesEvaluation.RenderMode,
        _ rust: CoreTokenAccountingRenderModeV1,
        _ context: String,
        file: StaticString,
        line: UInt
    ) {
        switch (swift, rust) {
        case (.full, .full), (.slice, .slice), (.codemap, .codemap), (.codemap, .codemapUnresolved):
            break
        default:
            XCTFail("\(context): renderMode mismatch swift=\(swift) rust=\(rust)", file: file, line: line)
        }
    }

    @discardableResult
    private func assertParity(
        specs: [EntrySpec],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> PromptEntriesEvaluation {
        var snapshots: [PromptFileEntrySnapshot] = []
        var coreEntries: [CoreTokenAccountingEntryV1] = []
        for spec in specs {
            let (snapshot, coreEntry) = buildPair(spec)
            snapshots.append(snapshot)
            coreEntries.append(coreEntry)
        }

        let service = TokenCalculationService()
        let evaluation = await service.evaluatePromptEntries(snapshots)
        let rust = try await RustTokenAccountingProbe().compute(entries: coreEntries, components: [])

        XCTAssertEqual(evaluation.fullCount, rust.aggregates.fullCount, "fullCount", file: file, line: line)
        XCTAssertEqual(evaluation.sliceCount, rust.aggregates.sliceCount, "sliceCount", file: file, line: line)
        XCTAssertEqual(evaluation.codemapCount, rust.aggregates.codemapCount, "codemapCount", file: file, line: line)
        XCTAssertEqual(evaluation.fullTokens, rust.aggregates.fullTokens, "fullTokens", file: file, line: line)
        XCTAssertEqual(evaluation.sliceTokens, rust.aggregates.sliceTokens, "sliceTokens", file: file, line: line)
        XCTAssertEqual(evaluation.codemapTokens, rust.aggregates.codemapTokens, "codemapTokens", file: file, line: line)
        XCTAssertEqual(evaluation.totalContentTokens, rust.aggregates.totalContentTokens, "totalContentTokens", file: file, line: line)
        XCTAssertEqual(evaluation.charCount, rust.aggregates.charCount, "charCount", file: file, line: line)
        XCTAssertEqual(evaluation.totalDisplayTokens, rust.totalDisplayTokens, "totalDisplayTokens", file: file, line: line)
        let combinedDisplayTokens = evaluation.totalContentTokens + evaluation.codemapTokens
        XCTAssertEqual(combinedDisplayTokens, rust.combinedDisplayTokens, "combinedDisplayTokens", file: file, line: line)
        XCTAssertEqual(evaluation.codeMapContent, rust.codeMapContent, "codeMapContent", file: file, line: line)
        XCTAssertEqual(evaluation.codeMapFileCount, rust.codeMapFileCount, "codeMapFileCount", file: file, line: line)
        XCTAssertEqual(evaluation.codeMapTokenCount, rust.codeMapTokenCount, "codeMapTokenCount", file: file, line: line)

        XCTAssertEqual(snapshots.count, rust.entries.count, "entry count", file: file, line: line)
        for (index, snapshot) in snapshots.enumerated() where index < rust.entries.count {
            let context = "entry[\(index)] path=\(snapshot.relativePath)"
            guard let swiftResult = evaluation.entryResultsByFileID[snapshot.fileID] else {
                XCTFail("\(context): missing Swift entry result", file: file, line: line)
                continue
            }
            let rustResult = rust.entries[index]

            assertRenderModeParity(swiftResult.renderMode, rustResult.renderMode, context, file: file, line: line)
            XCTAssertEqual(swiftResult.displayTokens, rustResult.displayTokens, "\(context): displayTokens", file: file, line: line)
            XCTAssertEqual(swiftResult.fullTokens, rustResult.fullTokens, "\(context): fullTokens", file: file, line: line)
            XCTAssertEqual(swiftResult.codemapTokens, rustResult.codemapTokens, "\(context): codemapTokens", file: file, line: line)
            XCTAssertEqual(swiftResult.displayLineCount, rustResult.displayLineCount, "\(context): displayLineCount", file: file, line: line)

            guard let tokenInfo = evaluation.fileTokenInfo[snapshot.fileID] else {
                XCTFail("\(context): missing Swift fileTokenInfo", file: file, line: line)
                continue
            }
            XCTAssertEqual(tokenInfo.count, rustResult.displayTokens, "\(context): TokenInfo.count", file: file, line: line)
            XCTAssertEqual(tokenInfo.fullCount, rustResult.fullTokens, "\(context): TokenInfo.fullCount", file: file, line: line)
            XCTAssertEqual(tokenInfo.codemapCount, rustResult.codemapTokens, "\(context): TokenInfo.codemapCount", file: file, line: line)
            XCTAssertEqual(tokenInfo.formatted, rustResult.formatted, "\(context): TokenInfo.formatted", file: file, line: line)
            XCTAssertEqual(
                tokenInfo.percentage.bitPattern, rustResult.percentage.bitPattern,
                "\(context): TokenInfo.percentage bit-exact", file: file, line: line
            )
        }

        let swiftFolders = evaluation.folderTokenInfo
            .map { (name: $0.key, info: $0.value) }
            .sorted { $0.name < $1.name }
        let rustFolders = rust.folders.sorted { $0.name < $1.name }
        XCTAssertEqual(swiftFolders.map(\.name), rustFolders.map(\.name), "folder names", file: file, line: line)
        for (swiftFolder, rustFolder) in zip(swiftFolders, rustFolders) {
            let context = "folder='\(swiftFolder.name)'"
            XCTAssertEqual(swiftFolder.info.count, rustFolder.tokens, "\(context): count", file: file, line: line)
            XCTAssertEqual(swiftFolder.info.formatted, rustFolder.formatted, "\(context): formatted", file: file, line: line)
            XCTAssertEqual(
                swiftFolder.info.percentage.bitPattern, rustFolder.percentage.bitPattern,
                "\(context): percentage bit-exact", file: file, line: line
            )
        }

        return evaluation
    }

    // MARK: - Full mode: source code in several languages + markdown

    func testFullModeAcrossLanguagesAndMarkdown() async throws {
        let swiftSource = """
        struct Example {
            let value: Int
            func greet() -> String { "hello, \\(value)" }
        }
        """
        let pythonSource = "def greet(name):\n    return f\"hello, {name}\"\n\nclass Example:\n    pass\n"
        let jsSource = "export function greet(name) {\n  return `hello, ${name}`;\n}\n"
        let rustSource = "pub fn greet(name: &str) -> String {\n    format!(\"hello, {name}\")\n}\n"
        let goSource = "package main\n\nfunc Greet(name string) string {\n\treturn \"hello, \" + name\n}\n"
        let markdown = "# Title\n\nSome **bold** text and a [link](https://example.com).\n\n- one\n- two\n"

        try await assertParity(specs: [
            EntrySpec(relativePath: "src/Example.swift", loadedContent: swiftSource),
            EntrySpec(relativePath: "src/example.py", loadedContent: pythonSource),
            EntrySpec(relativePath: "src/example.js", loadedContent: jsSource),
            EntrySpec(relativePath: "src/example.rs", loadedContent: rustSource),
            EntrySpec(relativePath: "src/example.go", loadedContent: goSource),
            EntrySpec(relativePath: "docs/README.md", loadedContent: markdown)
        ])
    }

    func testFullModePrefersCachedFullTokenCountOverEstimate() async throws {
        try await assertParity(specs: [
            EntrySpec(relativePath: "a.swift", loadedContent: "small body", cachedFullTokenCount: 999),
            EntrySpec(relativePath: "b.swift", loadedContent: "another body")
        ])
    }

    func testFullModeWithoutLoadedContentFallsBackToCachedCountAndByteMultipliedCharCount() async throws {
        try await assertParity(specs: [
            EntrySpec(relativePath: "cached-only.swift", cachedFullTokenCount: 42),
            EntrySpec(relativePath: "zero.swift")
        ])
    }

    // MARK: - Slice mode: real FileViewModel.buildSliceAssembly, multiple ranges, merges

    func testSliceModeWithSingleAndMultipleMergingRanges() async throws {
        let content = (1 ... 20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try await assertParity(specs: [
            EntrySpec(
                relativePath: "src/pkg/File.swift",
                ranges: [LineRange(start: 2, end: 4)],
                loadedContent: content
            ),
            EntrySpec(
                relativePath: "src/pkg/Other.swift",
                ranges: [LineRange(start: 1, end: 3), LineRange(start: 3, end: 5), LineRange(start: 10, end: 12)],
                loadedContent: content
            ),
            EntrySpec(
                relativePath: "src/pkg/Cached.swift",
                ranges: [LineRange(start: 5, end: 7)],
                loadedContent: content,
                cachedFullTokenCount: 12345
            )
        ])
    }

    func testRangesPresentButNoLoadedContentFallsBackToFullModeBranch() async throws {
        // `sliceAssemblies` is only built when `loadedContent != nil` -- a ranges-bearing entry
        // with no loaded content must resolve to the full-mode branch, not slice mode.
        try await assertParity(specs: [
            EntrySpec(
                relativePath: "no-content.swift",
                ranges: [LineRange(start: 1, end: 3)],
                loadedContent: nil,
                cachedFullTokenCount: 7
            )
        ])
    }

    func testEmptyRangesArrayFallsBackToFullModeBranch() async throws {
        try await assertParity(specs: [
            EntrySpec(relativePath: "empty-ranges.swift", ranges: [], loadedContent: "some body text")
        ])
    }

    // MARK: - Codemap: resolved (incl. empty content), unresolved, mixed with content entries

    func testResolvedCodemapEntryWithEmptyContentCountsTowardAggregateButNotComposed() async throws {
        try await assertParity(specs: [
            EntrySpec(
                relativePath: "a.swift",
                isCodemapRequested: true,
                codeMapContent: "",
                availableCodeMapTokenCount: 42
            ),
            EntrySpec(
                relativePath: "b.swift",
                isCodemapRequested: true,
                codeMapContent: "func b() {}",
                availableCodeMapTokenCount: 7
            )
        ])
    }

    func testUnresolvedCodemapEntryHasZeroDisplayTokensAndNilLineCount() async throws {
        try await assertParity(specs: [
            EntrySpec(
                relativePath: "unresolved.swift",
                isCodemapRequested: true,
                codeMapContent: nil,
                availableCodeMapTokenCount: 0,
                loadedContent: "cached body for full-tokens fallback",
                cachedFullTokenCount: nil
            )
        ])
    }

    func testMixedContentSliceAndCodemapEntriesInOneBatch() async throws {
        let content = (1 ... 10).map { "line \($0)" }.joined(separator: "\n")
        try await assertParity(specs: [
            EntrySpec(relativePath: "src/full.swift", loadedContent: "full file body"),
            EntrySpec(relativePath: "src/slice.swift", ranges: [LineRange(start: 2, end: 5)], loadedContent: content),
            EntrySpec(
                relativePath: "src/resolved.swift",
                isCodemapRequested: true,
                codeMapContent: "func resolved() {}",
                availableCodeMapTokenCount: 11
            ),
            EntrySpec(
                relativePath: "src/unresolved.swift",
                isCodemapRequested: true,
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            )
        ])
    }

    // MARK: - CJK, emoji, combining marks, very long lines

    func testCJKEmojiCombiningMarksAndVeryLongLines() async throws {
        let cjk = "你好，世界。これはテストです。 한국어 테스트입니다.\n"
        // Family emoji: a 4-codepoint ZWJ sequence, 1 Swift Character, 25 UTF-8 bytes.
        let familyEmoji = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}\n"
        // "e" + combining acute accent (U+0301), a 2-scalar single grapheme cluster.
        let combining = "cafe\u{0301} re\u{0301}sume\u{0301}\n"
        let veryLongLine = String(repeating: "x", count: 20000) + "\n" + String(repeating: "y", count: 5000)

        try await assertParity(specs: [
            EntrySpec(relativePath: "unicode/cjk.txt", loadedContent: cjk),
            EntrySpec(relativePath: "unicode/emoji.txt", loadedContent: familyEmoji),
            EntrySpec(relativePath: "unicode/combining.txt", loadedContent: combining),
            EntrySpec(relativePath: "unicode/long-line.txt", loadedContent: veryLongLine),
            EntrySpec(
                relativePath: "unicode/mixed-slice.txt",
                ranges: [LineRange(start: 1, end: 2)],
                loadedContent: cjk + familyEmoji + combining
            )
        ])
    }

    // MARK: - Empty / whitespace-only content

    func testEmptyAndWhitespaceOnlyContent() async throws {
        try await assertParity(specs: [
            EntrySpec(relativePath: "empty.txt", loadedContent: ""),
            EntrySpec(relativePath: "spaces.txt", loadedContent: "   "),
            EntrySpec(relativePath: "blank-lines.txt", loadedContent: "\n\n\n"),
            EntrySpec(relativePath: "tabs-and-newlines.txt", loadedContent: "\t\t\n \t\n\n")
        ])
    }

    // MARK: - Line-ending variants: CRLF, CR, LF, mixed

    func testLineEndingVariants() async throws {
        let lf = "a\nb\nc\n"
        let crlf = "a\r\nb\r\nc\r\n"
        let cr = "a\rb\rc\r"
        let mixed = "a\r\nb\nc\rd\r\n"
        let content20Lines = (1 ... 8).map { "row\($0)" }.joined(separator: "\r\n") + "\r\n"

        try await assertParity(specs: [
            EntrySpec(relativePath: "endings/lf.txt", loadedContent: lf),
            EntrySpec(relativePath: "endings/crlf.txt", loadedContent: crlf),
            EntrySpec(relativePath: "endings/cr.txt", loadedContent: cr),
            EntrySpec(relativePath: "endings/mixed.txt", loadedContent: mixed),
            EntrySpec(
                relativePath: "endings/crlf-slice.txt",
                ranges: [LineRange(start: 2, end: 4)],
                loadedContent: content20Lines
            )
        ])
    }

    // MARK: - Huge (~1MB) content

    func testHugeFileAroundOneMegabyteFullAndSliceModes() async throws {
        let lineText = String(repeating: "a", count: 99) + "\n" // 100 bytes/line
        let hugeContent = String(repeating: lineText, count: 10000) // ~1,000,000 bytes, 10000 lines
        XCTAssertEqual(hugeContent.utf8.count, 1_000_000)

        // A second ~1MB fixture using multi-byte content to also exercise char-count precompute
        // at scale: "é" (2 UTF-8 bytes) repeated, one grapheme per repeat.
        let multibyteLine = String(repeating: "\u{00E9}", count: 49) + "\n" // 99 bytes/line
        let hugeMultibyteContent = String(repeating: multibyteLine, count: 10000)

        try await assertParity(specs: [
            EntrySpec(relativePath: "huge/full.txt", loadedContent: hugeContent),
            EntrySpec(
                relativePath: "huge/slice.txt",
                ranges: [LineRange(start: 1, end: 5000)],
                loadedContent: hugeContent
            ),
            EntrySpec(relativePath: "huge/multibyte-full.txt", loadedContent: hugeMultibyteContent)
        ])
    }

    // MARK: - Folder rollups across nested paths, including leading/doubled/trailing slash edges

    func testFolderRollupAcrossNestedAndEdgeCasePaths() async throws {
        // `extractFolderPath` is the one site where Rust's stdlib `split('/')` default (keeps
        // empty subsequences) diverges from Swift's `split(separator:)` default (drops them) --
        // these fixtures exercise exactly that: leading `/`, doubled `/`, and trailing `/`.
        try await assertParity(specs: [
            EntrySpec(relativePath: "src/pkg/a.swift", loadedContent: "aaaa"),
            EntrySpec(relativePath: "src/pkg/b.swift", loadedContent: "bbbbbbbb"),
            EntrySpec(relativePath: "src/other/c.swift", loadedContent: "c"),
            EntrySpec(relativePath: "top-level.swift", loadedContent: "top"),
            EntrySpec(
                relativePath: "src/pkg/d.swift",
                isCodemapRequested: true,
                codeMapContent: "func d() {}",
                availableCodeMapTokenCount: 9
            ),
            EntrySpec(relativePath: "/lead/e.swift", loadedContent: "e"),
            EntrySpec(relativePath: "dbl//slash/f.swift", loadedContent: "ff"),
            EntrySpec(relativePath: "trail/g/", loadedContent: "ggg"),
            EntrySpec(relativePath: "bare.swift", loadedContent: "gggg")
        ])
    }

    // MARK: - TokenInfo tie-case: exact dyadic percentage (count ≡ 0 mod 125 of a 1000 total)

    func testPercentageTieCaseAtExactEighths() async throws {
        try await assertParity(specs: [
            EntrySpec(relativePath: "a.swift", cachedFullTokenCount: 125),
            EntrySpec(relativePath: "b.swift", cachedFullTokenCount: 375),
            EntrySpec(relativePath: "c.swift", cachedFullTokenCount: 500)
        ])
    }

    // MARK: - Component breakdown (calculateComponentBreakdown)

    func testComponentBreakdownAcrossDuplicateFlagAndEmptyOptionalTexts() async throws {
        struct ComponentSpec {
            let promptText: String
            let selectedInstructionsText: String
            let fileTreeText: String
            let gitDiffText: String?
            let metadataText: String?
            let duplicateUserInstructionsAtTop: Bool
        }
        let specs = [
            ComponentSpec(
                promptText: "Implement the feature described above.",
                selectedInstructionsText: "Follow the style guide.",
                fileTreeText: "src/\n  a.swift\n  b.swift\n",
                gitDiffText: "diff --git a/a.swift b/a.swift\n+added line\n",
                metadataText: "workspace: repoprompt-ce",
                duplicateUserInstructionsAtTop: true
            ),
            ComponentSpec(
                promptText: "Short prompt.",
                selectedInstructionsText: "",
                fileTreeText: "",
                gitDiffText: nil,
                metadataText: nil,
                duplicateUserInstructionsAtTop: false
            ),
            ComponentSpec(
                promptText: "",
                selectedInstructionsText: "",
                fileTreeText: "",
                gitDiffText: "",
                metadataText: "",
                duplicateUserInstructionsAtTop: true
            )
        ]

        var rustComponents: [CoreTokenAccountingComponentV1] = []
        var swiftBreakdowns: [TokenComponentBreakdown] = []
        for spec in specs {
            swiftBreakdowns.append(TokenCalculationService.calculateComponentBreakdown(
                promptText: spec.promptText,
                selectedInstructionsText: spec.selectedInstructionsText,
                fileTreeText: spec.fileTreeText,
                gitDiffText: spec.gitDiffText,
                metadataText: spec.metadataText,
                duplicateUserInstructionsAtTop: spec.duplicateUserInstructionsAtTop
            ))
            rustComponents.append(CoreTokenAccountingComponentV1(
                promptText: spec.promptText,
                selectedInstructionsText: spec.selectedInstructionsText,
                fileTreeText: spec.fileTreeText,
                gitDiffText: spec.gitDiffText ?? "",
                metadataText: spec.metadataText ?? "",
                duplicateUserInstructionsAtTop: spec.duplicateUserInstructionsAtTop
            ))
        }

        let rust = try await RustTokenAccountingProbe().compute(entries: [], components: rustComponents)
        XCTAssertEqual(rust.components.count, swiftBreakdowns.count)
        for (index, swiftBreakdown) in swiftBreakdowns.enumerated() where index < rust.components.count {
            let rustBreakdown = rust.components[index]
            let context = "component[\(index)]"
            XCTAssertEqual(swiftBreakdown.prompt, rustBreakdown.prompt, "\(context): prompt")
            XCTAssertEqual(swiftBreakdown.duplicatePrompt, rustBreakdown.duplicatePrompt, "\(context): duplicatePrompt")
            XCTAssertEqual(swiftBreakdown.instructions, rustBreakdown.instructions, "\(context): instructions")
            XCTAssertEqual(swiftBreakdown.fileTree, rustBreakdown.fileTree, "\(context): fileTree")
            XCTAssertEqual(swiftBreakdown.gitDiff, rustBreakdown.gitDiff, "\(context): gitDiff")
            XCTAssertEqual(swiftBreakdown.metadata, rustBreakdown.metadata, "\(context): metadata")
        }
    }
}
