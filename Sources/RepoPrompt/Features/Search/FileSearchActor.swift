import AgentryCoreBridge
import Foundation
@_exported import RepoPromptSearchCore

// Wildmatch flags for pattern matching
private let WM_NOESCAPE: UInt32 = 0x01
private let WM_PATHNAME: UInt32 = 0x02
private let WM_CASEFOLD: UInt32 = 0x10 // must match wildmatch.h
private let WM_WILDSTAR: UInt32 = 0x40 // must match wildmatch.h
private let WM_MATCH: Int32 = 0

// MARK: – NEW unified-search support –––––––––––––––––––––––––––––––––

/// Enhanced search options for fine-grained control
struct SearchOptions {
    var mode: SearchMode = .auto
    var caseInsensitive: Bool = true
    var wholeWord: Bool = false
    var includeExtensions: [String] = [] // e.g., [".js", ".ts", ".swift"]
    var excludePatterns: [String] = [] // e.g., ["node_modules", ".git", "*.log"]
    var contextLines: Int = 0 // Number of lines before/after match
    var maxResults: Int = 250
    var countOnly: Bool = false
    var fuzzySpaceMatching: Bool = true // Enable/disable fuzzy space matching
    var allowLiteralUnescapeFallback: Bool = true // Helpful rescue for over-escaped literals in auto flows
    var contentFreshnessPolicy: FileContentFreshnessPolicy = .cachedMetadata
}

/// Codable wrapper for regex pattern errors
struct PatternErrorInfo: Codable {
    let errorType: String
    let description: String

    init(_ error: RegexPatternFailure) {
        errorType = String(reflecting: Swift.type(of: error))
        description = error.localizedDescription
    }
}

/// Codable wrapper for per-file errors
struct PerFileError: Codable {
    let filePath: String
    let error: PatternErrorInfo

    init(filePath: String, error: RegexPatternFailure) {
        self.filePath = filePath
        self.error = PatternErrorInfo(error)
    }
}

/// Result returned by the new `FileSearchActor.searchUnified`.
struct SearchResults: Codable {
    /// Absolute file paths whose *path* matched the pattern (may be omitted).
    var paths: [String]?
    /// Individual in-file hits (same payload as `SearchMatch`, may be omitted).
    var matches: [SearchMatch]?
    /// Number of files that contained content matches (optional when count-only)
    var contentFileCount: Int?
    /// Total count of matches (useful for count-only mode)
    var totalCount: Int?
    /// Number of files actually searched after all filters are applied.
    var searchedFileCount: Int?
    /// Number of files admitted by the path scope before extension/exclude filtering.
    var scopedFileCount: Int?
    /// Error that occurred during path search phase
    var pathError: PatternErrorInfo?
    /// Error that occurred during content search phase
    var contentError: PatternErrorInfo?
    /// Per-file errors that occurred during scanning
    var perFileErrors: [PerFileError]?
    /// Optional warning surfaced when the requested pattern was implicitly repaired.
    var warningMessage: String?

    init(
        paths: [String] = [],
        matches: [SearchMatch] = [],
        contentFileCount: Int? = nil,
        totalCount: Int? = nil,
        searchedFileCount: Int? = nil,
        scopedFileCount: Int? = nil,
        pathError: RegexPatternFailure? = nil,
        contentError: RegexPatternFailure? = nil,
        perFileErrors: [(String, RegexPatternFailure)] = [],
        warningMessage: String? = nil
    ) {
        self.paths = paths.isEmpty ? nil : paths
        self.matches = matches.isEmpty ? nil : matches
        self.contentFileCount = contentFileCount
        self.totalCount = totalCount
        self.searchedFileCount = searchedFileCount
        self.scopedFileCount = scopedFileCount
        self.pathError = pathError.map(PatternErrorInfo.init)
        self.contentError = contentError.map(PatternErrorInfo.init)
        self.perFileErrors = perFileErrors.isEmpty ? nil : perFileErrors.map { path, error in
            PerFileError(filePath: path, error: error)
        }
        self.warningMessage = warningMessage
    }
}

private struct SearchScanSummary {
    let lineMatchCount: Int

    var matchedFile: Bool {
        lineMatchCount > 0
    }
}

private struct SearchContentResult {
    let matches: [SearchMatch]
    let totalCount: Int
    let matchedFileCount: Int
    let perFileErrors: [(String, RegexPatternFailure)]
}

private struct RustSearchByteRangeMaterializer {
    let selectedLines: [String]

    init(text: String, lineRangeWords: ArraySlice<UInt64>) throws {
        let utf8 = text.utf8
        var cursor = utf8.startIndex
        var cursorOffset = 0
        var lines: [String] = []
        lines.reserveCapacity(lineRangeWords.count / CoreCompactRegexBatchResult.lineRangeStride)
        for index in stride(from: lineRangeWords.startIndex, to: lineRangeWords.endIndex, by: 2) {
            let startOffset = Int(lineRangeWords[index])
            let endOffset = Int(lineRangeWords[index + 1])
            utf8.formIndex(&cursor, offsetBy: startOffset - cursorOffset)
            guard let start = String.Index(cursor, within: text) else {
                throw CoreSearchError.malformedRange
            }
            utf8.formIndex(&cursor, offsetBy: endOffset - startOffset)
            guard let end = String.Index(cursor, within: text) else {
                throw CoreSearchError.malformedRange
            }
            lines.append(String(text[start ..< end]))
            cursorOffset = endOffset
        }
        selectedLines = lines
    }
}

private struct SearchFileScanBatch {
    let ordinal: Int
    let summary: SearchScanSummary
    let errors: [(String, RegexPatternFailure)]
    var materializedMatches: [SearchMatch]?
}

private struct RustLoadedSearchFile {
    let input: SearchFileInput
    let snapshot: FileSearchContentSnapshot
    let text: String
}

private struct RustSearchScanPlan {
    let pattern: String
    let caseInsensitive: Bool
    let wholeWord: Bool
    let multilineAnchors: Bool
    let lineOriented: Bool
    let contextLines: Int
    let countOnly: Bool
    let maxCollectedMatches: Int?
    let contentFreshnessPolicy: FileContentFreshnessPolicy
    let client: CoreSearchClient
}

private struct SearchFileDescriptor {
    let id: UUID
    let name: String
    let relativePath: String
    let standardizedRelativePath: String
    let fullPath: String
    let standardizedFullPath: String
    let standardizedRootFolderPath: String
    let fileExtension: String?
    let contentSnapshot: (FileContentFreshnessPolicy) async throws -> FileSearchContentSnapshot

    init(file: FileViewModel) {
        id = file.id
        name = file.name
        relativePath = file.relativePath
        standardizedRelativePath = file.standardizedRelativePath
        fullPath = file.fullPath
        standardizedFullPath = file.standardizedFullPath
        standardizedRootFolderPath = file.standardizedRootFolderPath
        fileExtension = file.fileExtension
        contentSnapshot = { policy in
            await file.searchContentSnapshot(freshnessPolicy: policy)
        }
    }

    init(
        record: WorkspaceFileRecord,
        rootPath: String,
        store: WorkspaceFileContextStore
    ) {
        id = record.id
        name = record.name
        relativePath = record.relativePath
        standardizedRelativePath = record.standardizedRelativePath
        fullPath = record.fullPath
        standardizedFullPath = record.standardizedFullPath
        standardizedRootFolderPath = StandardizedPath.absolute(rootPath)
        fileExtension = {
            let ext = (record.name as NSString).pathExtension
            return ext.isEmpty ? nil : ext
        }()
        contentSnapshot = { policy in
            let freshnessPolicy = switch policy {
            case .validateDiskMetadata:
                "validateDiskMetadata"
            case .cachedMetadata:
                "cachedMetadata"
            }
            let freshnessState = EditFlowPerf.begin(
                EditFlowPerf.Stage.Search.contentFreshnessValidation,
                EditFlowPerf.Dimensions(
                    contentSource: "storeSnapshot",
                    freshnessPolicy: freshnessPolicy
                )
            )
            var outcome = "error"
            defer {
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Search.contentFreshnessValidation,
                    freshnessState,
                    EditFlowPerf.Dimensions(
                        outcome: outcome,
                        contentSource: "storeSnapshot",
                        freshnessPolicy: freshnessPolicy
                    )
                )
            }
            do {
                let snapshot = try await store.searchContentSnapshot(
                    for: record,
                    freshnessPolicy: policy
                )
                outcome = snapshot.isFresh ? "current" : "missing"
                return snapshot
            } catch is CancellationError {
                outcome = "cancelled"
                throw CancellationError()
            } catch {
                throw error
            }
        }
    }
}

private struct SearchFileInput {
    let ordinal: Int
    let file: SearchFileDescriptor
}

private struct SearchContentBatch {
    let index: Int
    let range: Range<Int>
}

private struct SearchContentBatchResult {
    let index: Int
    let fileResults: [SearchFileScanBatch]
}

private struct RustSearchPathScanPlan {
    let pattern: String
    let caseInsensitive: Bool
    let aliasByRootPath: [String: String]?
    let client: CoreSearchClient
}

private struct SearchPathInput {
    let ordinal: Int
    let file: SearchFileDescriptor
}

private struct SearchPathBatch {
    let index: Int
    let range: Range<Int>
}

private struct SearchPathBatchResult {
    let index: Int
    let hits: [(ordinal: Int, path: String)]
}

struct OrderedSearchBatchWindow {
    let batchCount: Int
    let maxEnqueueLead: Int
    private(set) var nextBatchToEnqueue = 0
    private(set) var nextBatchToDrain = 0

    init(batchCount: Int, maxEnqueueLead: Int) {
        precondition(batchCount >= 0)
        precondition(maxEnqueueLead > 0)
        self.batchCount = batchCount
        self.maxEnqueueLead = maxEnqueueLead
    }

    var enqueueLead: Int {
        nextBatchToEnqueue - nextBatchToDrain
    }

    mutating func takeNextBatchToEnqueue() -> Int? {
        guard nextBatchToEnqueue < batchCount,
              nextBatchToEnqueue < nextBatchToDrain + maxEnqueueLead
        else { return nil }
        defer { nextBatchToEnqueue += 1 }
        return nextBatchToEnqueue
    }

    mutating func advanceDrainFrontier() {
        precondition(nextBatchToDrain < nextBatchToEnqueue)
        nextBatchToDrain += 1
    }
}

/// Ripgrep-style asynchronous searcher, fully cancellable.
actor FileSearchActor {
    static func pathSearchInputPrecedes(_ lhsPath: String, _ rhsPath: String) -> Bool {
        WorkspaceInventoryOrdering.compareUTF8Binary(lhsPath, rhsPath) == .orderedAscending
    }

    private static func descriptors(
        for files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore
    ) -> [SearchFileDescriptor] {
        files.compactMap { file in
            guard let root = rootsByID[file.rootID] else { return nil }
            return SearchFileDescriptor(
                record: file,
                rootPath: root.standardizedFullPath,
                store: store
            )
        }
    }

    /// ------------------------------------------------------------------
    ///  HELPER METHODS FOR USER-FRIENDLY GLOBS
    /// ------------------------------------------------------------------
    /// Helper: does a glob end with a wildcard token?
    private static func endsWithWildcard(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        return last == "*" || last == "?"
    }

    /// Helper: generate friendly fallback candidates for path globs
    private static func pathGlobCandidates(for pattern: String) -> [String] {
        var cands: [String] = [pattern]
        let hasSlash = pattern.contains("/")
        let needsSuffixStar = !endsWithWildcard(pattern)

        // Try matching at any depth if user didn't scope with '/'
        if !hasSlash, !pattern.hasPrefix("**/") {
            cands.append("**/" + pattern)
        }
        // If user forgot a trailing wildcard, try broadening
        if needsSuffixStar {
            cands.append(pattern + "*")
            if !hasSlash, !pattern.hasPrefix("**/") {
                cands.append("**/" + pattern + "*")
            }
        }
        // Deduplicate while preserving order
        var seen = Set<String>()
        var out: [String] = []
        for c in cands where seen.insert(c).inserted {
            out.append(c)
        }
        return out
    }

    /// ------------------------------------------------------------------
    ///  SAFETY CONSTANTS
    /// ------------------------------------------------------------------
    /// For very large files we avoid full-buffer PCRE2 scanning.
    /// Patterns like `xml.*trim` with unanchored greedy quantifiers can be extremely
    /// slow on large buffers because each C match call is synchronous and cannot be
    /// interrupted by cooperative cancellation.
    private static let maxPCRE2FullScanBytes = 1_000_000 // 1 MB

    /// Number of paths evaluated by each path worker task.
    private static let pathScanBatchSize = 128

    /// Maximum number of file-scan tasks that run in parallel.
    /// We default to the number of CPU cores (but at least 4) so the search
    /// stays responsive without flooding the executor with thousands of jobs.
    private static let maxConcurrentTasks = max(4, ProcessInfo.processInfo.activeProcessorCount)

    /// Resolves the measured production content-batch size from a stable worker count.
    /// The policy targets eight batches per worker, then clamps nonempty batches to 2...4 files.
    /// A single-file search remains a single-file batch.
    static func contentScanBatchSize(fileCount: Int, workerCount: Int) -> Int {
        guard fileCount > 0 else { return 0 }
        let resolvedWorkerCount = max(4, workerCount)
        let (filesPerWorkerTarget, overflowed) = resolvedWorkerCount.multipliedReportingOverflow(by: 8)
        let targetBatchSize: Int
        if overflowed || filesPerWorkerTarget >= fileCount {
            targetBatchSize = 1
        } else {
            let quotient = fileCount / filesPerWorkerTarget
            let remainder = fileCount % filesPerWorkerTarget
            targetBatchSize = quotient + (remainder == 0 ? 0 : 1)
        }
        return min(fileCount, min(4, max(2, targetBatchSize)))
    }

    // NEW: Regex meta detection for literal over-escape heuristics
    private static let regexMeta: Set<Character> = ["(", ")", "[", "]", "{", "}", ".", "*", "+", "?", "|", "^", "$"]

    /// Looks like a literal with unnecessary escapes (e.g., "\\(") and no "\\\\"
    private static func looksOverEscapedLiteral(_ s: String) -> Bool {
        if s.contains("\\\\") {
            return false
        } // double-backslash present → likely intended literal backslash
        let chars = Array(s)
        var i = 0
        var saw = false
        while i < chars.count - 1 {
            if chars[i] == "\\", regexMeta.contains(chars[i + 1]) {
                saw = true
                i += 2
            } else {
                i += 1
            }
        }
        return saw
    }

    /// Remove a single leading "\\" before regex meta characters only (for literal fallback)
    private static func unescapeLiteralRegexEscapes(_ s: String) -> String {
        let chars = Array(s)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if i < chars.count - 1, chars[i] == "\\", regexMeta.contains(chars[i + 1]) {
                out.append(chars[i + 1])
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }

    /// Repairs literal patterns that were double-escaped through JSON or tool layers.
    /// Example: `"frame\\\\("` → `"frame("`
    private static func repairedLiteralPattern(_ pattern: String) -> String? {
        var candidate = pattern
        if Self.looksOverEscapedRegex(candidate) {
            let compressed = Self.compressDoubleEscapesBeforeMeta(candidate)
            if compressed != candidate {
                candidate = compressed
                let chars = Array(candidate)
                if chars.count == 2, chars[0] == "\\", regexMeta.contains(chars[1]) {
                    return nil
                }
            }
        }
        guard Self.looksOverEscapedLiteral(candidate) else { return nil }
        let repaired = Self.unescapeLiteralRegexEscapes(candidate)
        return repaired != pattern ? repaired : nil
    }

    /// Detects patterns that likely have double-escapes before regex meta (e.g., "\\\\(")
    private static func looksOverEscapedRegex(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count >= 3 else { return false }
        var i = 0
        while i < chars.count - 2 {
            if chars[i] == "\\", chars[i + 1] == "\\", regexMeta.contains(chars[i + 2]) {
                return true
            }
            i += 1
        }
        return false
    }

    /// Compresses double backslashes into a single backslash when directly before regex meta.
    /// Example: "\\\\(" -> "\\(" (keeps intent to escape '(' for regex)
    private static func compressDoubleEscapesBeforeMeta(_ s: String) -> String {
        let chars = Array(s)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if i < chars.count - 2, chars[i] == "\\", chars[i + 1] == "\\", regexMeta.contains(chars[i + 2]) {
                // Keep a single escape before meta
                out.append("\\")
                out.append(chars[i + 2])
                i += 3
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }

    private static func materializeMatches(
        from batch: SearchFileScanBatch,
        remaining: Int
    ) -> [SearchMatch] {
        guard remaining > 0, let matches = batch.materializedMatches else { return [] }
        return Array(matches.prefix(remaining))
    }

    // MARK: - Public entry points ----------------------------------------------

    /// Enhanced search with full options support and auto-correction reporting
    func search(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel]
    ) async throws -> [SearchMatch] {
        var materializingOptions = options
        materializingOptions.countOnly = false
        let result = try await searchWithErrors(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            options: materializingOptions,
            in: files.map(SearchFileDescriptor.init(file:))
        )
        return result.matches
    }

    func search(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore
    ) async throws -> [SearchMatch] {
        var materializingOptions = options
        materializingOptions.countOnly = false
        let result = try await searchWithErrors(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            options: materializingOptions,
            in: Self.descriptors(
                for: files,
                rootsByID: rootsByID,
                store: store
            )
        )
        return result.matches
    }

    /// Internal search function that returns both matches and per-file errors
    private func searchWithErrors(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [SearchFileDescriptor]
    ) async throws -> SearchContentResult {
        // Filter files by extensions and exclude patterns first
        let filteredFiles = try await filterFiles(files, options: options)
        func hasMatches(_ result: SearchContentResult) -> Bool {
            result.totalCount > 0
        }

        var primary = try await searchContentWithErrors(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            caseInsensitive: options.caseInsensitive,
            wholeWord: options.wholeWord,
            fuzzySpaceMatching: options.fuzzySpaceMatching,
            contextLines: options.contextLines,
            countOnly: options.countOnly,
            maxResults: options.maxResults,
            contentFreshnessPolicy: options.contentFreshnessPolicy,
            in: filteredFiles
        )

        // Auto-fallback: if user over-escaped literals (e.g., "frame\\(") and got no results,
        // try again with de-escaped literal. Only when not in regex mode and allowed.
        if !isRegex,
           !hasMatches(primary),
           options.allowLiteralUnescapeFallback,
           let repaired = Self.repairedLiteralPattern(pattern)
        {
            if repaired != pattern {
                primary = try await searchContentWithErrors(
                    pattern: repaired,
                    isRegex: false,
                    wasAutoCorrected: &wasAutoCorrected,
                    caseInsensitive: options.caseInsensitive,
                    wholeWord: options.wholeWord,
                    fuzzySpaceMatching: options.fuzzySpaceMatching,
                    contextLines: options.contextLines,
                    countOnly: options.countOnly,
                    maxResults: options.maxResults,
                    contentFreshnessPolicy: options.contentFreshnessPolicy,
                    in: filteredFiles
                )
                if hasMatches(primary) {
                    wasAutoCorrected = true
                }
            }
        }

        // NEW: Regex over-escape auto-fix for MCP inputs – only when regex mode returns no matches
        if isRegex, !hasMatches(primary) {
            // 1) Compress accidental double-escapes before meta (e.g., "\\\\(" -> "\\(")
            if Self.looksOverEscapedRegex(pattern) {
                let compressed = Self.compressDoubleEscapesBeforeMeta(pattern)
                if compressed != pattern {
                    let corrected1 = try await searchContentWithErrors(
                        pattern: compressed,
                        isRegex: true,
                        wasAutoCorrected: &wasAutoCorrected,
                        caseInsensitive: options.caseInsensitive,
                        wholeWord: options.wholeWord,
                        fuzzySpaceMatching: options.fuzzySpaceMatching,
                        contextLines: options.contextLines,
                        countOnly: options.countOnly,
                        maxResults: options.maxResults,
                        contentFreshnessPolicy: options.contentFreshnessPolicy,
                        in: filteredFiles
                    )
                    if hasMatches(corrected1) {
                        wasAutoCorrected = true
                        return corrected1
                    }
                }
            }

            // 2) As a last resort, interpret intent literally with regex-safe escaping
            let literalCandidate = Self.unescapeLiteralRegexEscapes(pattern)
            if literalCandidate != pattern {
                let quoted = NSRegularExpression.escapedPattern(for: literalCandidate)
                let corrected3 = try await searchContentWithErrors(
                    pattern: quoted,
                    isRegex: true,
                    wasAutoCorrected: &wasAutoCorrected,
                    caseInsensitive: options.caseInsensitive,
                    wholeWord: options.wholeWord,
                    fuzzySpaceMatching: options.fuzzySpaceMatching,
                    contextLines: options.contextLines,
                    countOnly: options.countOnly,
                    maxResults: options.maxResults,
                    contentFreshnessPolicy: options.contentFreshnessPolicy,
                    in: filteredFiles
                )
                if hasMatches(corrected3) {
                    wasAutoCorrected = true
                    return corrected3
                }
            }
        }

        return primary
    }

    /// Enhanced search with full options support (backward compatibility)
    func search(
        pattern: String,
        isRegex: Bool = false,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel]
    ) async throws -> [SearchMatch] {
        var autoCorrected: Bool? = nil
        return try await search(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &autoCorrected,
            options: options,
            in: files
        )
    }

    func search(
        pattern: String,
        isRegex: Bool = false,
        options: SearchOptions = SearchOptions(),
        in files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore
    ) async throws -> [SearchMatch] {
        var autoCorrected: Bool? = nil
        return try await search(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &autoCorrected,
            options: options,
            in: files,
            rootsByID: rootsByID,
            store: store
        )
    }

    /// Filter files based on include/exclude patterns
    private func filterFiles(
        _ files: [SearchFileDescriptor],
        options: SearchOptions
    ) async throws -> [SearchFileDescriptor] {
        let extensionFiltered = files.filter { file in
            guard !options.includeExtensions.isEmpty else { return true }
            return options.includeExtensions.contains("." + (file.fileExtension ?? ""))
        }
        guard !options.excludePatterns.isEmpty, !extensionFiltered.isEmpty else {
            return extensionFiltered
        }

        func literalWildmatch(_ literal: String) -> String {
            var escaped = ""
            escaped.reserveCapacity(literal.count + 2)
            for character in literal {
                if character == "\\" || character == "[" || character == "]" {
                    escaped.append("\\")
                }
                escaped.append(character)
            }
            return "*\(escaped)*"
        }

        let snapshots = extensionFiltered.map {
            FileSearchPathSnapshot(
                standardizedFullPath: $0.relativePath,
                standardizedRelativePath: $0.relativePath,
                standardizedRootPath: $0.standardizedRootFolderPath,
                clientDisplayPath: $0.relativePath
            )
        }
        let clauses = options.excludePatterns.map { pattern -> SearchPathClause in
            let effective = pattern.contains("*") || pattern.contains("?")
                ? pattern
                : literalWildmatch(pattern)
            return .glob(pattern: effective, restrictedRootPath: nil)
        }
        let client = try await AgentryCoreService.shared.searchClient()
        let excluded = try await filterPathIndicesResult(
            snapshots: snapshots,
            spec: SearchPathFilterSpec(caseInsensitive: true, clauses: clauses),
            client: client
        )
        if excluded.cancelled {
            throw CancellationError()
        }
        let excludedIndices = Set(excluded.matchedSnapshotIndices)
        return extensionFiltered.enumerated().compactMap {
            excludedIndices.contains($0.offset) ? nil : $0.element
        }
    }

    private func searchContent(
        pattern: String,
        isRegex: Bool,
        wasAutoCorrected: inout Bool?,
        caseInsensitive: Bool,
        wholeWord: Bool,
        fuzzySpaceMatching: Bool,
        contextLines: Int,
        maxResults: Int,
        in files: [SearchFileDescriptor]
    ) async throws -> [SearchMatch] {
        let result = try await searchContentWithErrors(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            caseInsensitive: caseInsensitive,
            wholeWord: wholeWord,
            fuzzySpaceMatching: fuzzySpaceMatching,
            contextLines: contextLines,
            countOnly: false,
            maxResults: maxResults,
            in: files
        )
        return result.matches
    }

    private func searchContentWithErrors(
        pattern: String,
        isRegex: Bool,
        wasAutoCorrected: inout Bool?,
        caseInsensitive: Bool,
        wholeWord: Bool,
        fuzzySpaceMatching: Bool,
        contextLines: Int,
        countOnly: Bool,
        maxResults: Int,
        contentFreshnessPolicy: FileContentFreshnessPolicy = .cachedMetadata,
        in files: [SearchFileDescriptor]
    ) async throws -> SearchContentResult {
        if !isRegex && pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SearchContentResult(matches: [], totalCount: 0, matchedFileCount: 0, perFileErrors: [])
        }
        try Task.checkCancellation()

        let client = try await AgentryCoreService.shared.searchClient()
        let effectivePattern: String
        let effectiveWholeWord: Bool
        if isRegex {
            effectivePattern = pattern
            effectiveWholeWord = wholeWord
        } else if fuzzySpaceMatching, pattern.contains(" ") {
            effectivePattern = Self.convertSpacesToFuzzyRegex(pattern)
            effectiveWholeWord = false
        } else {
            effectivePattern = NSRegularExpression.escapedPattern(for: pattern)
            effectiveWholeWord = wholeWord
        }
        let lineOriented = !isRegex
            || Self.isLineAnchored(pattern)
            || pattern.first == "^"
            || pattern.last == "$"
            || Self.isExpensiveUnanchored(pattern)
        let plan = RustSearchScanPlan(
            pattern: effectivePattern,
            caseInsensitive: caseInsensitive,
            wholeWord: effectiveWholeWord,
            multilineAnchors: pattern.contains("^") || pattern.contains("$"),
            lineOriented: lineOriented,
            contextLines: contextLines,
            countOnly: countOnly,
            maxCollectedMatches: countOnly ? nil : max(0, maxResults),
            contentFreshnessPolicy: contentFreshnessPolicy,
            client: client
        )

        if isRegex {
            do {
                let probe = try await client.searchRegex(CoreRegexSearchRequest(
                    pattern: effectivePattern,
                    subject: "",
                    caseInsensitive: caseInsensitive,
                    wholeWord: effectiveWholeWord,
                    multilineAnchors: plan.multilineAnchors,
                    collectMatches: false,
                    contextLines: 0,
                    matchPolicy: lineOriented ? .contentLine : .contentFullBuffer
                ))
                if probe.diagnostic.repairKind != .none {
                    wasAutoCorrected = true
                }
            } catch let error as CoreSearchError {
                if let failure = Self.regexPatternFailure(for: error, pattern: pattern) {
                    throw failure
                }
                throw error
            }
        }

        let entries = files
            .sorted { $0.fullPath < $1.fullPath }
            .enumerated()
            .map { SearchFileInput(ordinal: $0.offset, file: $0.element) }
        let contentBatchSize = Self.contentScanBatchSize(
            fileCount: entries.count,
            workerCount: Self.maxConcurrentTasks
        )
        let batches = Self.makeContentBatches(entries, batchSize: contentBatchSize)
        let rustScanKind = isRegex
            ? (lineOriented ? "rust-regex-line" : "rust-regex-full-buffer")
            : "rust-literal-line"
        let contentScanState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.contentScanTotal,
            EditFlowPerf.Dimensions(
                taskCount: batches.count,
                workerCount: Self.maxConcurrentTasks,
                admittedFileCount: files.count,
                scanKind: rustScanKind,
                batchSize: contentBatchSize,
                isRegex: isRegex,
                countOnly: countOnly
            )
        )
        var contentScanOutcome = "completed"
        var scannedFileCount = 0
        var batchWindow = OrderedSearchBatchWindow(
            batchCount: batches.count,
            maxEnqueueLead: Self.maxConcurrentTasks
        )
        var pending: [Int: SearchContentBatchResult] = [:]
        var emittedMatches: [SearchMatch] = []
        var totalCount = 0
        var matchedFileCount = 0
        var perFileErrors: [(String, RegexPatternFailure)] = []
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentScanTotal,
                contentScanState,
                EditFlowPerf.Dimensions(
                    outcome: contentScanOutcome,
                    matchCount: totalCount,
                    taskCount: batches.count,
                    workerCount: Self.maxConcurrentTasks,
                    admittedFileCount: files.count,
                    scannedFileCount: scannedFileCount,
                    matchedFileCount: matchedFileCount,
                    scanKind: rustScanKind,
                    batchSize: contentBatchSize,
                    isRegex: isRegex,
                    countOnly: countOnly
                )
            )
        }

        func refillBatchWindow(into group: inout ThrowingTaskGroup<SearchContentBatchResult, Error>) {
            while let batchIndex = batchWindow.takeNextBatchToEnqueue() {
                let batch = batches[batchIndex]
                group.addTask { [entries] in
                    try await Self.scanRustContentBatch(batch, entries: entries, plan: plan)
                }
            }
        }

        do {
            try await withThrowingTaskGroup(of: SearchContentBatchResult.self) { group in
                refillBatchWindow(into: &group)
                scanLoop: while let batchResult = try await group.next() {
                    scannedFileCount += batchResult.fileResults.count
                    pending[batchResult.index] = batchResult
                    var drainAdvanced = false
                    while let ready = pending.removeValue(forKey: batchWindow.nextBatchToDrain) {
                        for fileResult in ready.fileResults {
                            perFileErrors.append(contentsOf: fileResult.errors)
                            totalCount += fileResult.summary.lineMatchCount
                            if fileResult.summary.matchedFile {
                                matchedFileCount += 1
                            }
                            if !countOnly, emittedMatches.count < maxResults {
                                emittedMatches.append(contentsOf: Self.materializeMatches(
                                    from: fileResult,
                                    remaining: maxResults - emittedMatches.count
                                ))
                            }
                            if !countOnly, emittedMatches.count >= maxResults {
                                contentScanOutcome = "capped"
                                group.cancelAll()
                                break scanLoop
                            }
                        }
                        batchWindow.advanceDrainFrontier()
                        drainAdvanced = true
                    }
                    if drainAdvanced {
                        refillBatchWindow(into: &group)
                    }
                }
            }
        } catch {
            contentScanOutcome = error is CancellationError ? "cancelled" : "failed"
            throw error
        }

        if countOnly {
            return SearchContentResult(
                matches: [],
                totalCount: totalCount,
                matchedFileCount: matchedFileCount,
                perFileErrors: perFileErrors
            )
        }
        return SearchContentResult(
            matches: emittedMatches,
            totalCount: emittedMatches.count,
            matchedFileCount: Set(emittedMatches.map(\.filePath)).count,
            perFileErrors: perFileErrors
        )
    }

    private static func scanRustContentBatch(
        _ batch: SearchContentBatch,
        entries: [SearchFileInput],
        plan: RustSearchScanPlan
    ) async throws -> SearchContentBatchResult {
        let batchSize = batch.range.count
        let scanKind = plan.lineOriented ? "rust-line" : "rust-full-buffer"
        let perfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.contentBatch,
            EditFlowPerf.Dimensions(
                workerCount: Self.maxConcurrentTasks,
                scanKind: scanKind,
                batchSize: batchSize,
                isRegex: true,
                countOnly: plan.countOnly,
                caseInsensitive: plan.caseInsensitive,
                wholeWord: plan.wholeWord,
                contextLines: plan.contextLines
            )
        )
        var fileResults: [SearchFileScanBatch] = []
        fileResults.reserveCapacity(batchSize)
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentBatch,
                perfState,
                EditFlowPerf.Dimensions(
                    matchCount: fileResults.reduce(0) { $0 + $1.summary.lineMatchCount },
                    workerCount: Self.maxConcurrentTasks,
                    scannedFileCount: fileResults.count,
                    scanKind: scanKind,
                    batchSize: batchSize,
                    isRegex: true,
                    countOnly: plan.countOnly,
                    caseInsensitive: plan.caseInsensitive,
                    wholeWord: plan.wholeWord,
                    contextLines: plan.contextLines
                )
            )
        }
        var loaded: [RustLoadedSearchFile] = []
        loaded.reserveCapacity(batchSize)
        for index in batch.range {
            try Task.checkCancellation()
            let input = entries[index]
            do {
                let snapshot = try await input.file.contentSnapshot(plan.contentFreshnessPolicy)
                guard let text = snapshot.content else {
                    fileResults.append(emptyRustFileResult(input))
                    continue
                }
                loaded.append(RustLoadedSearchFile(input: input, snapshot: snapshot, text: text))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ContentReadSchedulerError {
                throw StoreBackedWorkspaceSearchAdmissionError.contentReadQueueFull(
                    retryAfterMilliseconds: error.retryAfterMilliseconds
                )
            } catch let error as StoreBackedWorkspaceSearchAdmissionError {
                throw error
            } catch {
                fileResults.append(emptyRustFileResult(input))
            }
        }

        let grouped = Dictionary(grouping: loaded) {
            plan.lineOriented || $0.text.utf8.count > Self.maxPCRE2FullScanBytes
        }
        for linePolicy in [false, true] {
            guard let files = grouped[linePolicy], !files.isEmpty else { continue }
            do {
                let result = try await plan.client.searchRegexBatchCompactV1(CoreRegexSearchBatchRequest(
                    pattern: plan.pattern,
                    subjects: files.map(\.text),
                    caseInsensitive: plan.caseInsensitive,
                    wholeWord: plan.wholeWord,
                    multilineAnchors: plan.multilineAnchors,
                    collectMatches: !plan.countOnly,
                    maxCollectedMatches: plan.maxCollectedMatches.flatMap(UInt32.init(exactly:)),
                    contextLines: UInt16(clamping: plan.contextLines),
                    matchPolicy: linePolicy ? .contentLine : .contentFullBuffer
                ))
                for (file, summary) in zip(files, result.subjectSummaries) {
                    try fileResults.append(rustFileResult(
                        file,
                        summary: summary,
                        batchResult: result,
                        plan: plan
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CoreSearchError {
                guard let failure = regexPatternFailure(for: error, pattern: plan.pattern) else {
                    throw error
                }
                fileResults.append(contentsOf: files.map {
                    SearchFileScanBatch(
                        ordinal: $0.input.ordinal,
                        summary: SearchScanSummary(lineMatchCount: 0),
                        errors: [($0.input.file.relativePath, failure)]
                    )
                })
            }
        }
        fileResults.sort { $0.ordinal < $1.ordinal }
        return SearchContentBatchResult(index: batch.index, fileResults: fileResults)
    }

    private static func emptyRustFileResult(_ input: SearchFileInput) -> SearchFileScanBatch {
        SearchFileScanBatch(
            ordinal: input.ordinal,
            summary: SearchScanSummary(lineMatchCount: 0),
            errors: []
        )
    }

    private static func rustFileResult(
        _ loaded: RustLoadedSearchFile,
        summary: CoreCompactRegexSubjectSummary,
        batchResult: CoreCompactRegexBatchResult,
        plan: RustSearchScanPlan
    ) throws -> SearchFileScanBatch {
        let file = loaded.input.file
        let matches = try materializeRustMatches(
            summary: summary,
            batchResult: batchResult,
            text: loaded.text,
            filePath: file.fullPath,
            contextLines: plan.contextLines
        )
        return SearchFileScanBatch(
            ordinal: loaded.input.ordinal,
            summary: SearchScanSummary(lineMatchCount: Int(summary.matchingLineCount)),
            errors: [],
            materializedMatches: matches
        )
    }

    #if DEBUG
        static func materializeRustMatchesForBenchmark(
            summary: CoreCompactRegexSubjectSummary,
            batchResult: CoreCompactRegexBatchResult,
            text: String,
            filePath: String,
            contextLines: Int
        ) throws -> [SearchMatch] {
            try materializeRustMatches(
                summary: summary,
                batchResult: batchResult,
                text: text,
                filePath: filePath,
                contextLines: contextLines
            )
        }
    #endif

    private static func materializeRustMatches(
        summary: CoreCompactRegexSubjectSummary,
        batchResult: CoreCompactRegexBatchResult,
        text: String,
        filePath: String,
        contextLines: Int
    ) throws -> [SearchMatch] {
        let lineStart = Int(summary.lineRangeStart) * CoreCompactRegexBatchResult.lineRangeStride
        let lineEnd = lineStart
            + Int(summary.lineRangeCount) * CoreCompactRegexBatchResult.lineRangeStride
        let materializer = try RustSearchByteRangeMaterializer(
            text: text,
            lineRangeWords: batchResult.lineRangeWords[lineStart ..< lineEnd]
        )
        let hitStart = Int(summary.hitStart) * CoreCompactRegexBatchResult.hitStride
        let hitEnd = hitStart + Int(summary.hitCount) * CoreCompactRegexBatchResult.hitStride
        var matches: [SearchMatch] = []
        matches.reserveCapacity(Int(summary.hitCount))
        for index in stride(from: hitStart, to: hitEnd, by: CoreCompactRegexBatchResult.hitStride) {
            let selectedLineIndex = Int(batchResult.hitWords[index + 1])
            let beforeCount = Int(batchResult.hitWords[index + 4])
            let afterCount = Int(batchResult.hitWords[index + 5])
            let before = Array(
                materializer.selectedLines[(selectedLineIndex - beforeCount) ..< selectedLineIndex]
            )
            let after = afterCount > 0
                ? Array(materializer.selectedLines[(selectedLineIndex + 1) ... (selectedLineIndex + afterCount)])
                : []
            matches.append(SearchMatch(
                filePath: filePath,
                lineNumber: Int(batchResult.hitWords[index]),
                lineText: materializer.selectedLines[selectedLineIndex],
                contextBefore: contextLines > 0 && !before.isEmpty ? before : nil,
                contextAfter: contextLines > 0 && !after.isEmpty ? after : nil
            ))
        }
        return matches
    }

    private static func regexPatternFailure(
        for error: CoreSearchError,
        pattern: String
    ) -> RegexPatternFailure? {
        switch error {
        case .patternTooComplex:
            SearchPatternTooComplexError()
        case let .invalidPattern(reason):
            switch reason {
            case .invalidEscape: SearchPatternError.invalidEscape(pattern)
            case .unmatchedBrackets: SearchPatternError.unmatchedBrackets(pattern)
            case .unmatchedParentheses: SearchPatternError.unmatchedParentheses(pattern)
            case .invalidQuantifier: SearchPatternError.invalidQuantifier(pattern)
            case .variableLengthLookbehind:
                SearchPatternError.invalidRegex(
                    pattern,
                    "Variable-length lookbehind is unsupported; use fixed or bounded width."
                )
            case .other: SearchPatternError.invalidRegex(pattern, "Failed to compile regular expression")
            }
        case .matchLimitExceeded:
            SearchPatternError.invalidRegex(pattern, "Regex match limit exceeded")
        case .depthLimitExceeded:
            SearchPatternError.invalidRegex(pattern, "Regex depth limit exceeded")
        case .heapLimitExceeded:
            SearchPatternError.invalidRegex(pattern, "Regex heap limit exceeded")
        case .jitUnavailable, .cancelled, .runtimeInvalidated, .runtimeStopped,
             .runtimePoisoned, .malformedRange, .transportFailure:
            nil
        }
    }

    private static func makeContentBatches(
        _ entries: [SearchFileInput],
        batchSize: Int
    ) -> [SearchContentBatch] {
        guard !entries.isEmpty else { return [] }
        precondition(batchSize > 0)
        var batches: [SearchContentBatch] = []
        batches.reserveCapacity(((entries.count - 1) / batchSize) + 1)
        var batchIndex = 0
        var start = 0
        while start < entries.count {
            let end = min(start + batchSize, entries.count)
            batches.append(SearchContentBatch(index: batchIndex, range: start ..< end))
            batchIndex += 1
            start = end
        }
        return batches
    }

    func searchPaths(
        pattern: String,
        limit: Int = 100,
        in files: [FileViewModel],
        caseInsensitive: Bool = true,
        isRegex: Bool = false, // ← NEW
        aliasByRootPath: [String: String]? = nil
    ) async throws -> [String] {
        try await searchPaths(
            pattern: pattern,
            limit: limit,
            in: files.map(SearchFileDescriptor.init(file:)),
            caseInsensitive: caseInsensitive,
            isRegex: isRegex,
            aliasByRootPath: aliasByRootPath
        )
    }

    func searchPaths(
        pattern: String,
        limit: Int = 100,
        in files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore,
        caseInsensitive: Bool = true,
        isRegex: Bool = false,
        aliasByRootPath: [String: String]? = nil
    ) async throws -> [String] {
        try await searchPaths(
            pattern: pattern,
            limit: limit,
            in: Self.descriptors(
                for: files,
                rootsByID: rootsByID,
                store: store
            ),
            caseInsensitive: caseInsensitive,
            isRegex: isRegex,
            aliasByRootPath: aliasByRootPath
        )
    }

    private func searchPaths(
        pattern: String,
        limit: Int = 100,
        in files: [SearchFileDescriptor],
        caseInsensitive: Bool = true,
        isRegex: Bool = false,
        aliasByRootPath: [String: String]? = nil
    ) async throws -> [String] {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !files.isEmpty, limit > 0 else { return [] }
        try Task.checkCancellation()
        let client = try await AgentryCoreService.shared.searchClient()
        #if DEBUG
            let sortAndInputStart = WorkspaceFileSearchDebugTiming.now()
        #endif
        let sortedFiles = files.sorted { Self.pathSearchInputPrecedes($0.fullPath, $1.fullPath) }
        let hasWildcards = trimmed.contains("*") || trimmed.contains("?")
        let strongRegex = Self.containsRegexSyntax(trimmed)
        let useGlob = hasWildcards && (!isRegex || !strongRegex)

        if useGlob {
            let snapshots = sortedFiles.map { file -> FileSearchPathSnapshot in
                let candidates = Self.candidatePaths(for: file, aliasByRootPath: aliasByRootPath)
                let relative = candidates.first ?? file.standardizedRelativePath
                return FileSearchPathSnapshot(
                    standardizedFullPath: relative,
                    standardizedRelativePath: relative,
                    standardizedRootPath: file.standardizedRootFolderPath,
                    clientDisplayPath: candidates.last ?? relative
                )
            }
            let result = try await filterPathIndicesResult(
                snapshots: snapshots,
                spec: SearchPathFilterSpec(
                    caseInsensitive: caseInsensitive,
                    clauses: Self.pathGlobCandidates(for: trimmed).map {
                        .glob(pattern: $0, restrictedRootPath: nil)
                    }
                ),
                client: client
            )
            if result.cancelled {
                throw CancellationError()
            }
            return result.matchedSnapshotIndices.prefix(limit).map {
                sortedFiles[$0].standardizedFullPath
            }
        }

        let effectivePattern = isRegex ? trimmed : NSRegularExpression.escapedPattern(for: trimmed)
        do {
            _ = try await client.searchRegex(CoreRegexSearchRequest(
                mode: .path,
                pattern: effectivePattern,
                subject: "",
                caseInsensitive: caseInsensitive,
                collectMatches: false,
                matchPolicy: .shortPath
            ))
        } catch let error as CoreSearchError {
            if let failure = Self.regexPatternFailure(for: error, pattern: trimmed) {
                throw failure
            }
            throw error
        }

        let plan = RustSearchPathScanPlan(
            pattern: effectivePattern,
            caseInsensitive: caseInsensitive,
            aliasByRootPath: aliasByRootPath,
            client: client
        )
        let entries = sortedFiles.enumerated().map {
            SearchPathInput(ordinal: $0.offset, file: $0.element)
        }
        #if DEBUG
            let sortAndInputEnd = WorkspaceFileSearchDebugTiming.now()
            WorkspaceFileSearchDebugContext.collector?.recordSortAndInput(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: sortAndInputStart,
                    through: sortAndInputEnd
                ),
                inputCount: entries.count
            )
            let batchAndEnqueueStart = WorkspaceFileSearchDebugTiming.now()
        #endif
        let batches = Self.makePathBatches(entries)
        var batchWindow = OrderedSearchBatchWindow(
            batchCount: batches.count,
            maxEnqueueLead: Self.maxConcurrentTasks
        )
        var pending: [Int: SearchPathBatchResult] = [:]
        var hits: [String] = []
        #if DEBUG
            let diagnosticReturnLimit = max(
                1,
                WorkspaceFileSearchDebugContext.collector?.requestedPathLimit() ?? limit
            )
            var diagnosticDrainedBatchCount = 0
            var diagnosticEntriesExamined = 0
            var diagnosticDrainedBatchCountThroughHit = 0
            var diagnosticEntriesExaminedThroughHit = 0
            var diagnosticReturnedHitOrdinal = 0
            var diagnosticReturnedHitPrefixLength = 0
            var diagnosticDrainStart: UInt64 = 0
            var diagnosticFirstHitEnd: UInt64?
        #endif

        func refillBatchWindow(into group: inout ThrowingTaskGroup<SearchPathBatchResult, Error>) {
            while let batchIndex = batchWindow.takeNextBatchToEnqueue() {
                let batch = batches[batchIndex]
                group.addTask { [entries] in
                    try await Self.scanRustPathBatch(batch, entries: entries, plan: plan)
                }
            }
        }

        try await withThrowingTaskGroup(of: SearchPathBatchResult.self) { group in
            refillBatchWindow(into: &group)
            #if DEBUG
                let initialEnqueueEnd = WorkspaceFileSearchDebugTiming.now()
                WorkspaceFileSearchDebugContext.collector?.recordBatchAndInitialEnqueue(
                    nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                        since: batchAndEnqueueStart,
                        through: initialEnqueueEnd
                    ),
                    totalBatchCount: batches.count,
                    initiallyEnqueuedBatchCount: batchWindow.nextBatchToEnqueue
                )
                diagnosticDrainStart = initialEnqueueEnd
            #endif
            scanLoop: while let batchResult = try await group.next() {
                pending[batchResult.index] = batchResult
                var drainAdvanced = false
                while let ready = pending.removeValue(forKey: batchWindow.nextBatchToDrain) {
                    #if DEBUG
                        diagnosticDrainedBatchCount += 1
                        diagnosticEntriesExamined += batches[ready.index].range.count
                    #endif
                    for hit in ready.hits.sorted(by: { $0.ordinal < $1.ordinal }) {
                        hits.append(hit.path)
                        #if DEBUG
                            if diagnosticFirstHitEnd == nil, hits.count >= diagnosticReturnLimit {
                                diagnosticDrainedBatchCountThroughHit = diagnosticDrainedBatchCount
                                diagnosticEntriesExaminedThroughHit = diagnosticEntriesExamined
                                diagnosticReturnedHitOrdinal = hit.ordinal + 1
                                diagnosticReturnedHitPrefixLength = hits.count
                                diagnosticFirstHitEnd = WorkspaceFileSearchDebugTiming.now()
                            }
                        #endif
                        if hits.count >= limit {
                            group.cancelAll()
                            break scanLoop
                        }
                    }
                    batchWindow.advanceDrainFrontier()
                    drainAdvanced = true
                }
                if drainAdvanced {
                    refillBatchWindow(into: &group)
                }
            }
        }
        #if DEBUG
            let diagnosticGroupEnd = WorkspaceFileSearchDebugTiming.now()
            let diagnosticDrainEnd = diagnosticFirstHitEnd ?? diagnosticGroupEnd
            if diagnosticFirstHitEnd == nil {
                diagnosticDrainedBatchCountThroughHit = diagnosticDrainedBatchCount
                diagnosticEntriesExaminedThroughHit = diagnosticEntriesExamined
            }
            WorkspaceFileSearchDebugContext.collector?.recordDeterministicDrainToHit(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: diagnosticDrainStart,
                    through: diagnosticDrainEnd
                ),
                drainedBatchCount: diagnosticDrainedBatchCountThroughHit,
                entriesExamined: diagnosticEntriesExaminedThroughHit,
                returnedHitOrdinal: diagnosticReturnedHitOrdinal,
                returnedHitPrefixLength: diagnosticReturnedHitPrefixLength
            )
            WorkspaceFileSearchDebugContext.collector?.recordPostHitResidual(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: diagnosticDrainEnd,
                    through: diagnosticGroupEnd
                )
            )
        #endif
        return hits
    }

    private static func scanRustPathBatch(
        _ batch: SearchPathBatch,
        entries: [SearchPathInput],
        plan: RustSearchPathScanPlan
    ) async throws -> SearchPathBatchResult {
        var hits: [(ordinal: Int, path: String)] = []
        for index in batch.range {
            try Task.checkCancellation()
            let entry = entries[index]
            let candidates = candidatePaths(for: entry.file, aliasByRootPath: plan.aliasByRootPath)
            var matched = false
            for candidate in candidates {
                let result = try await plan.client.searchRegex(CoreRegexSearchRequest(
                    mode: .path,
                    pattern: plan.pattern,
                    subject: candidate,
                    caseInsensitive: plan.caseInsensitive,
                    collectMatches: false,
                    matchPolicy: .shortPath
                ))
                if result.matchingLineCount > 0 {
                    matched = true
                    break
                }
            }
            if matched {
                hits.append((entry.ordinal, entry.file.standardizedFullPath))
            }
        }
        return SearchPathBatchResult(index: batch.index, hits: hits)
    }

    private static func makePathBatches(_ entries: [SearchPathInput]) -> [SearchPathBatch] {
        guard !entries.isEmpty else { return [] }
        var batches: [SearchPathBatch] = []
        batches.reserveCapacity((entries.count + pathScanBatchSize - 1) / pathScanBatchSize)
        var batchIndex = 0
        var start = 0
        while start < entries.count {
            let end = min(start + pathScanBatchSize, entries.count)
            batches.append(SearchPathBatch(index: batchIndex, range: start ..< end))
            batchIndex += 1
            start = end
        }
        return batches
    }

    private static func candidatePaths(for file: SearchFileDescriptor, aliasByRootPath: [String: String]?) -> [String] {
        var seen = Set<String>()
        var candidates: [String] = []

        func appendCandidate(_ path: String) {
            guard !path.isEmpty else { return }
            if seen.insert(path).inserted {
                candidates.append(path)
            }
        }

        // 1) Standardized repo-relative path (what path search exposes)
        let relativePath = StandardizedPath.relative(file.standardizedRelativePath)
        appendCandidate(relativePath)

        // 2) Optional alias-prefixed path for multi-root workspaces
        if let aliasByRootPath {
            let rootKey = file.standardizedRootFolderPath
            if let alias = aliasByRootPath[rootKey] {
                let aliasPrefixed = relativePath.isEmpty ? alias : "\(alias)/\(relativePath)"
                appendCandidate(aliasPrefixed)
            }
        }

        // NOTE: We deliberately DO NOT include file.standardizedFullPath here.
        // Including the full absolute path caused queries like "Bomb" to match
        // every file when the workspace root was named "BombSquad", because the
        // absolute path "/Users/.../BombSquad/..." matched even though users
        // only see repo-relative paths in results. Any tooling that needs
        // absolute-path matching should use WorkspaceFilesViewModel + PathMatchWorker.

        return candidates
    }

    // MARK: – NEW unified search entry point ––––––––––––––––––––––––––––

    /// Unified search combining path and content search with full SearchOptions support and auto-correction reporting
    func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel],
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        try await searchUnified(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            options: options,
            in: files.map(SearchFileDescriptor.init(file:)),
            aliasByRootPath: aliasByRootPath
        )
    }

    func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore,
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        #if DEBUG
            let descriptorStart = WorkspaceFileSearchDebugTiming.now()
            let descriptors = Self.descriptors(
                for: files,
                rootsByID: rootsByID,
                store: store
            )
            let descriptorEnd = WorkspaceFileSearchDebugTiming.now()
            WorkspaceFileSearchDebugContext.collector?.recordDescriptors(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: descriptorStart,
                    through: descriptorEnd
                ),
                sourceCount: files.count,
                builtCount: descriptors.count
            )
            return try await searchUnified(
                pattern: pattern,
                isRegex: isRegex,
                wasAutoCorrected: &wasAutoCorrected,
                options: options,
                in: descriptors,
                aliasByRootPath: aliasByRootPath
            )
        #else
            return try await searchUnified(
                pattern: pattern,
                isRegex: isRegex,
                wasAutoCorrected: &wasAutoCorrected,
                options: options,
                in: Self.descriptors(
                    for: files,
                    rootsByID: rootsByID,
                    store: store
                ),
                aliasByRootPath: aliasByRootPath
            )
        #endif
    }

    private func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        wasAutoCorrected: inout Bool?,
        options: SearchOptions = SearchOptions(),
        in files: [SearchFileDescriptor],
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        try Task.checkCancellation()

        // No auto-detection - only use regex when explicitly requested
        let effectiveIsRegex = isRegex

        // Filter files by extensions and exclude patterns first
        #if DEBUG
            let filterStart = WorkspaceFileSearchDebugTiming.now()
        #endif
        let filteredFiles = try await filterFiles(files, options: options)
        #if DEBUG
            let filterEnd = WorkspaceFileSearchDebugTiming.now()
            WorkspaceFileSearchDebugContext.collector?.recordActorFilter(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: filterStart, through: filterEnd),
                admittedCount: filteredFiles.count
            )
        #endif

        // Decide effective strategy when `.auto`
        let effectiveMode: SearchMode = {
            if options.mode != .auto {
                return options.mode
            }
            return Self.inferMode(pattern)
        }()
        let perfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.actorSearchUnified,
            EditFlowPerf.Dimensions(
                searchMode: effectiveMode.rawValue,
                fileCount: filteredFiles.count,
                maxResults: options.maxResults,
                isRegex: effectiveIsRegex,
                countOnly: options.countOnly,
                caseInsensitive: options.caseInsensitive,
                wholeWord: options.wholeWord,
                contextLines: options.contextLines
            )
        )
        var perfStatus = "ok"
        var perfMatchCount: Int?
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.actorSearchUnified,
                perfState,
                EditFlowPerf.Dimensions(
                    status: perfStatus,
                    matchCount: perfMatchCount,
                    searchMode: effectiveMode.rawValue,
                    fileCount: filteredFiles.count,
                    maxResults: options.maxResults,
                    isRegex: effectiveIsRegex,
                    countOnly: options.countOnly,
                    caseInsensitive: options.caseInsensitive,
                    wholeWord: options.wholeWord,
                    contextLines: options.contextLines
                )
            )
        }

        var pathHits: [String] = []
        var contentHits: [SearchMatch] = []
        var totalCount: Int? = nil
        var contentFileCount: Int? = nil
        let searchedFileCount = filteredFiles.count
        var pathError: RegexPatternFailure? = nil
        var contentError: RegexPatternFailure? = nil
        var perFileErrors: [(String, RegexPatternFailure)] = []

        // 1) Path search when requested
        if effectiveMode == .path || effectiveMode == .both {
            do {
                pathHits = try await searchPaths(
                    pattern: pattern,
                    limit: options.maxResults,
                    in: filteredFiles,
                    caseInsensitive: options.caseInsensitive,
                    isRegex: effectiveIsRegex,
                    aliasByRootPath: aliasByRootPath
                )
            } catch let e as RegexPatternFailure {
                pathError = e
            }
        }

        // 2) Content search when requested
        if effectiveMode == .content || effectiveMode == .both {
            do {
                if options.countOnly {
                    let result = try await searchWithErrors(
                        pattern: pattern,
                        isRegex: effectiveIsRegex,
                        wasAutoCorrected: &wasAutoCorrected,
                        options: SearchOptions(
                            caseInsensitive: options.caseInsensitive,
                            wholeWord: options.wholeWord,
                            includeExtensions: [], // Already filtered
                            excludePatterns: [], // Already filtered
                            maxResults: Int.max,
                            countOnly: true,
                            fuzzySpaceMatching: options.fuzzySpaceMatching,
                            contentFreshnessPolicy: options.contentFreshnessPolicy
                        ),
                        in: filteredFiles
                    )
                    totalCount = result.totalCount
                    contentFileCount = result.matchedFileCount
                    perFileErrors.append(contentsOf: result.perFileErrors)
                } else {
                    let result = try await searchWithErrors(
                        pattern: pattern,
                        isRegex: effectiveIsRegex,
                        wasAutoCorrected: &wasAutoCorrected,
                        options: SearchOptions(
                            caseInsensitive: options.caseInsensitive,
                            wholeWord: options.wholeWord,
                            includeExtensions: [], // Already filtered
                            excludePatterns: [], // Already filtered
                            contextLines: options.contextLines,
                            maxResults: options.maxResults,
                            fuzzySpaceMatching: options.fuzzySpaceMatching,
                            contentFreshnessPolicy: options.contentFreshnessPolicy
                        ),
                        in: filteredFiles
                    )
                    contentHits = result.matches
                    contentFileCount = Set(contentHits.map(\.filePath)).count
                    perFileErrors.append(contentsOf: result.perFileErrors)
                }
            } catch let e as RegexPatternFailure {
                contentError = e
            }
        }

        // Only re-throw when both phases fail (if both were requested)
        if effectiveMode == .both, pathError != nil, contentError != nil {
            // Both phases failed, re-throw the content error as it's usually more specific
            perfStatus = "error"
            throw contentError!
        } else if effectiveMode == .path, pathError != nil {
            // Only path search was requested and it failed
            perfStatus = "error"
            throw pathError!
        } else if effectiveMode == .content, contentError != nil {
            // Only content search was requested and it failed
            perfStatus = "error"
            throw contentError!
        }
        perfMatchCount = totalCount ?? (pathHits.count + contentHits.count)

        let resultConstructionState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.resultConstruction,
            EditFlowPerf.Dimensions(
                matchCount: perfMatchCount,
                admittedFileCount: searchedFileCount,
                matchedFileCount: contentFileCount,
                contentMatchCount: totalCount ?? contentHits.count,
                pathMatchCount: pathHits.count,
                errorCount: perFileErrors.count,
                searchMode: effectiveMode.rawValue,
                countOnly: options.countOnly
            )
        )
        let results = SearchResults(
            paths: pathHits,
            matches: contentHits,
            contentFileCount: contentFileCount,
            totalCount: totalCount,
            searchedFileCount: searchedFileCount,
            pathError: pathError,
            contentError: contentError,
            perFileErrors: perFileErrors
        )
        EditFlowPerf.end(
            EditFlowPerf.Stage.Search.resultConstruction,
            resultConstructionState,
            EditFlowPerf.Dimensions(
                outcome: "completed",
                matchCount: perfMatchCount,
                admittedFileCount: searchedFileCount,
                matchedFileCount: contentFileCount,
                contentMatchCount: totalCount ?? contentHits.count,
                pathMatchCount: pathHits.count,
                errorCount: perFileErrors.count,
                searchMode: effectiveMode.rawValue,
                countOnly: options.countOnly
            )
        )
        return results
    }

    /// Unified search combining path and content search with full SearchOptions support (backward compatibility)
    func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        options: SearchOptions = SearchOptions(),
        in files: [FileViewModel],
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        // Entry point for MCP tool integration

        var autoCorrected: Bool? = nil
        return try await searchUnified(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &autoCorrected,
            options: options,
            in: files,
            aliasByRootPath: aliasByRootPath
        )
    }

    func searchUnified(
        pattern: String,
        isRegex: Bool = false,
        options: SearchOptions = SearchOptions(),
        in files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        store: WorkspaceFileContextStore,
        aliasByRootPath: [String: String]? = nil
    ) async throws -> SearchResults {
        var autoCorrected: Bool? = nil
        return try await searchUnified(
            pattern: pattern,
            isRegex: isRegex,
            wasAutoCorrected: &autoCorrected,
            options: options,
            in: files,
            rootsByID: rootsByID,
            store: store,
            aliasByRootPath: aliasByRootPath
        )
    }

    // MARK: – Helper to choose automatic mode ––––––––––––––––––––––––

    static func inferredAutoMode(_ raw: String) -> SearchMode {
        // Quick heuristics (order matters) - designed for intuitive user experience

        // REGEX PATTERNS should search content, not paths
        if containsRegexSyntax(raw) {
            return .content
        }

        // Strong path indicators should override other signals
        if raw.hasPrefix("*") || raw.hasPrefix(".") {
            return .path
        }

        // Check for wildcards anywhere in the pattern
        if raw.contains("*") || raw.contains("?") {
            return .path
        }

        // Forward slashes are strong path indicators unless it's clearly content (like a sentence)
        if raw.contains("/") {
            // If it has spaces but is short and path-like, still treat as path
            if raw.contains(" "), raw.count > 20 {
                return .content // Long patterns with spaces are likely content
            }
            return .path
        }

        // Backslashes are ambiguous: they may indicate Windows paths, or escaped literal metacharacters.
        if raw.contains("\\") {
            if backslashesOnlyEscapeRegexMeta(raw) {
                return .content
            }
            if raw.contains(" "), raw.count > 20 {
                return .content
            }
            return .path
        }

        // Content indicators
        if raw.contains("\n") {
            return .content
        }
        if raw.contains(" "), raw.count > 10 {
            return .content
        }

        // Short patterns should search both to be thorough
        if raw.count <= 3 {
            return .both
        }

        // Identifier-like tokens (e.g., "Player", "Bomb", "MyClass.swift") should search both
        // paths and content - this is the most intuitive UX for code search
        if isIdentifierLike(raw) {
            return .both
        }

        // Medium patterns with spaces are likely content searches
        if raw.contains(" ") {
            return .content
        }

        // Everything else defaults to content (most common use case)
        return .content
    }

    private static func inferMode(_ raw: String) -> SearchMode {
        inferredAutoMode(raw)
    }

    private static func backslashesOnlyEscapeRegexMeta(_ raw: String) -> Bool {
        let chars = Array(raw)
        var index = 0
        var sawEscapedMeta = false
        while index < chars.count {
            guard chars[index] == "\\" else {
                index += 1
                continue
            }
            if index + 2 < chars.count,
               chars[index + 1] == "\\",
               regexMeta.contains(chars[index + 2])
            {
                sawEscapedMeta = true
                index += 3
                continue
            }
            if index + 1 < chars.count,
               regexMeta.contains(chars[index + 1])
            {
                sawEscapedMeta = true
                index += 2
                continue
            }
            return false
        }
        return sawEscapedMeta
    }

    /// Checks if a pattern looks like an identifier or filename (no spaces, no regex chars).
    /// Used to determine if auto mode should search both paths and content.
    private static func isIdentifierLike(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }

        // Must be a single token (no spaces or path separators)
        if s.contains(" ") || s.contains("/") || s.contains("\\") {
            return false
        }

        // No obvious regex metacharacters
        let forbidden: Set<Character> = ["*", "+", "?", "[", "]", "{", "}", "(", ")", "|", "^", "$"]
        if s.contains(where: forbidden.contains) {
            return false
        }

        // Restrict to common identifier/filename characters: letters, digits, dot, underscore, hyphen
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        if s.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return false
        }

        return true
    }

    // MARK: - Helper to detect regex patterns  ------------------------------

    /// Detects if a pattern contains regex syntax that should trigger regex mode
    static func containsRegexSyntax(_ pattern: String) -> Bool {
        let explicitRegexTokens = [
            "(?=", "(?<!", "(?<=", "(?!", "(?>", "[[:", "\\Q", "\\E",
            "(?i)", "(?m)", "(?s)", "(?x)"
        ]
        if explicitRegexTokens.contains(where: pattern.contains) || containsInlineOptionGroup(pattern) {
            return true
        }

        // Check for clear regex patterns that are unlikely to be literal searches

        // Check for parentheses (capture groups) - but only if they look like regex
        // e.g., "(foo|bar)" or "func()" - we need to be smart about this
        if pattern.contains("(") && pattern.contains(")") {
            // Check if it's likely a regex group (has | inside or special chars)
            if let openParen = pattern.firstIndex(of: "("),
               let closeParen = pattern.firstIndex(of: ")"),
               openParen < closeParen
            {
                let insideParens = String(pattern[pattern.index(after: openParen) ..< closeParen])
                // If there's a pipe inside parens, it's likely regex
                if insideParens.contains("|") {
                    return true
                }
                // If the pattern starts with common regex anchors/modifiers before the paren
                let beforeParen = String(pattern[..<openParen])
                if beforeParen.hasSuffix("?:") || beforeParen.hasSuffix("?=") ||
                    beforeParen.hasSuffix("?!") || beforeParen.hasSuffix("?<=") ||
                    beforeParen.hasSuffix("?<!")
                {
                    return true
                }
            }
        }

        // Pipe operator with non-empty alternatives on both sides (e.g., "foo|bar")
        // This avoids false positives for lone pipes or pipes at edges
        if pattern.contains("|") {
            let components = pattern.split(separator: "|", omittingEmptySubsequences: false)
            // Only treat as regex if there are at least 2 non-empty components
            let nonEmptyCount = components.count(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            if nonEmptyCount >= 2 {
                return true
            }
        }

        // Common regex patterns that are very unlikely to be literal searches
        let strongRegexPatterns = [
            "\\b", // Word boundary
            "\\w", // Word character
            "\\d", // Digit
            "\\s", // Whitespace
            "\\n", // Newline
            "\\t", // Tab
            "^$", // Empty line
            ".*", // Any character sequence
            ".+" // At least one character
        ]

        for regexPattern in strongRegexPatterns {
            if pattern.contains(regexPattern) {
                return true
            }
        }

        // Check for character classes [...]
        if let openBracket = pattern.firstIndex(of: "["),
           let closeBracket = pattern.firstIndex(of: "]"),
           openBracket < closeBracket
        {
            return true
        }

        // Check for quantifiers {n,m}
        if let openBrace = pattern.firstIndex(of: "{"),
           let closeBrace = pattern.firstIndex(of: "}"),
           openBrace < closeBrace
        {
            let between = pattern[pattern.index(after: openBrace) ..< closeBrace]
            // Check if it looks like a quantifier (digits and comma)
            if between.allSatisfy({ $0.isNumber || $0 == "," }) {
                return true
            }
        }

        // Check for anchors at start/end
        if pattern.hasPrefix("^") || pattern.hasSuffix("$") {
            return true
        }

        return false
    }

    private static func containsInlineOptionGroup(_ pattern: String) -> Bool {
        var searchStart = pattern.startIndex
        while let intro = pattern.range(of: "(?", range: searchStart ..< pattern.endIndex) {
            var index = intro.upperBound
            var sawFlag = false
            var awaitingFlagAfterHyphen = false
            while index < pattern.endIndex {
                let character = pattern[index]
                if "imsxUJ".contains(character) {
                    sawFlag = true
                    awaitingFlagAfterHyphen = false
                    index = pattern.index(after: index)
                    continue
                }
                if character == "-" {
                    awaitingFlagAfterHyphen = true
                    index = pattern.index(after: index)
                    continue
                }
                if character == ")" || character == ":", sawFlag, !awaitingFlagAfterHyphen {
                    return true
                }
                break
            }
            searchStart = intro.upperBound
        }
        return false
    }

    private static func isLineAnchored(_ pattern: String) -> Bool {
        pattern.first == "^" && pattern.last == "$" && !pattern.contains("\n")
    }

    private static func isExpensiveUnanchored(_ pattern: String) -> Bool {
        guard !isLineAnchored(pattern) else { return false }
        var escaped = false
        var previousWasDot = false
        for character in pattern {
            if escaped {
                escaped = false
                previousWasDot = false
                continue
            }
            if character == "\\" {
                escaped = true
                previousWasDot = false
                continue
            }
            if previousWasDot, character == "*" || character == "+" {
                return true
            }
            previousWasDot = character == "."
        }
        return false
    }

    // MARK: - Literal substring helper --------------------------------------

    private static func containsSubstring(_ haystack: String, needle: String, caseInsensitive: Bool) -> Bool {
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        return haystack.range(of: needle, options: options) != nil
    }

    // MARK: - Helper for fuzzy space matching  ------------------------------

    /// Converts spaces in a literal pattern to flexible PCRE2 whitespace regex patterns.
    /// Each literal space becomes `\s+`, preserving the existing fuzzy-space behavior.
    private static func convertSpacesToFuzzyRegex(_ pattern: String) -> String {
        pattern
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
    }
}
