import Foundation

public struct CoreApplyEditsOperationV1: Sendable, Equatable, Hashable {
    public let search: String
    public let replacement: String
    public let replaceAll: Bool

    public init(search: String, replacement: String, replaceAll: Bool = false) {
        self.search = search
        self.replacement = replacement
        self.replaceAll = replaceAll
    }
}

public enum CoreApplyEditsModeV1: Sendable, Equatable {
    case rewrite(replacement: String)
    case single(CoreApplyEditsOperationV1)
    case batch([CoreApplyEditsOperationV1])
}

/// TD-3 §6.1/round-2 Finding F2: `decodedUTF8` is the existing, GUI-apply-edits-depended-upon
/// path -- `originalUTF8` is already-decoded UTF-8 text bytes, strictly re-validated Rust-side
/// (unchanged). `raw` is the additive ladder-6 (headless `agentry-mcp`, D-6) construction path --
/// `originalUTF8` carries genuinely raw disk bytes; Rust's apply-edits handler calls
/// `textdecode()` internally as its first step, preserving the single-FFI-crossing shape.
public enum CoreApplyEditsSourceKind: Sendable, Equatable, Hashable {
    case decodedUTF8
    case raw
}

public struct CoreApplyEditsSubjectRequestV1: Sendable, Equatable {
    public let pathLabel: String
    public let originalUTF8: Data
    public let sourceKind: CoreApplyEditsSourceKind
    public let mode: CoreApplyEditsModeV1
    public let verbose: Bool
    public let includeToolCardUnifiedDiff: Bool

    public init(
        pathLabel: String,
        originalUTF8: Data,
        sourceKind: CoreApplyEditsSourceKind = .decodedUTF8,
        mode: CoreApplyEditsModeV1,
        verbose: Bool = false,
        includeToolCardUnifiedDiff: Bool = false
    ) {
        self.pathLabel = pathLabel
        self.originalUTF8 = originalUTF8
        self.sourceKind = sourceKind
        self.mode = mode
        self.verbose = verbose
        self.includeToolCardUnifiedDiff = includeToolCardUnifiedDiff
    }

    public init(
        pathLabel: String,
        original: String,
        mode: CoreApplyEditsModeV1,
        verbose: Bool = false,
        includeToolCardUnifiedDiff: Bool = false
    ) {
        self.init(
            pathLabel: pathLabel,
            originalUTF8: Data(original.utf8),
            sourceKind: .decodedUTF8,
            mode: mode,
            verbose: verbose,
            includeToolCardUnifiedDiff: includeToolCardUnifiedDiff
        )
    }

    /// Additive raw-bytes construction path used only by `DirectHeadlessFileEditHost` (ladder 6,
    /// design D-6). `rawBytes` is genuinely raw, possibly-non-UTF-8 disk bytes.
    public init(
        pathLabel: String,
        rawBytes: Data,
        mode: CoreApplyEditsModeV1,
        verbose: Bool = false,
        includeToolCardUnifiedDiff: Bool = false
    ) {
        self.init(
            pathLabel: pathLabel,
            originalUTF8: rawBytes,
            sourceKind: .raw,
            mode: mode,
            verbose: verbose,
            includeToolCardUnifiedDiff: includeToolCardUnifiedDiff
        )
    }
}

public struct CoreApplyEditsBatchRequestV1: Sendable, Equatable {
    public static let contractVersion: UInt16 = 1

    public let contractVersion: UInt16
    public let subjects: [CoreApplyEditsSubjectRequestV1]

    public init(contractVersion: UInt16 = Self.contractVersion, subjects: [CoreApplyEditsSubjectRequestV1]) {
        self.contractVersion = contractVersion
        self.subjects = subjects
    }
}

public enum CoreApplyEditsStatus: UInt8, Sendable, Equatable, Hashable {
    case success = 0
    case partial = 1
    case failed = 2
}

public enum CoreApplyEditsOutcomeStatus: UInt8, Sendable, Equatable, Hashable {
    case success = 0
    case failed = 1
}

public enum CoreApplyEditsDiffLineType: UInt8, Sendable, Equatable, Hashable {
    case context = 0
    case addition = 1
    case removal = 2
}

public struct CoreApplyEditsByteEdit: Sendable, Equatable, Hashable {
    public let oldRange: Range<Int>
    public let newRange: Range<Int>

    public init(oldRange: Range<Int>, newRange: Range<Int>) {
        self.oldRange = oldRange
        self.newRange = newRange
    }
}

public struct CoreApplyEditsDiffLine: Sendable, Equatable, Hashable {
    public let type: CoreApplyEditsDiffLineType
    public let content: String

    public init(type: CoreApplyEditsDiffLineType, content: String) {
        self.type = type
        self.content = content
    }
}

public struct CoreApplyEditsChunk: Sendable, Equatable, Hashable {
    public let startLine: Int
    public let oldByteRange: Range<Int>
    public let newByteRange: Range<Int>
    public let lines: [CoreApplyEditsDiffLine]

    public init(
        startLine: Int,
        oldByteRange: Range<Int>,
        newByteRange: Range<Int>,
        lines: [CoreApplyEditsDiffLine]
    ) {
        self.startLine = startLine
        self.oldByteRange = oldByteRange
        self.newByteRange = newByteRange
        self.lines = lines
    }
}

public struct CoreApplyEditsOperationOutcome: Sendable, Equatable, Hashable {
    public let operationIndex: Int
    public let status: CoreApplyEditsOutcomeStatus
    public let error: String?

    public init(operationIndex: Int, status: CoreApplyEditsOutcomeStatus, error: String?) {
        self.operationIndex = operationIndex
        self.status = status
        self.error = error
    }
}

public struct CoreApplyEditsStats: Sendable, Equatable, Hashable {
    public let linesChanged: Int
    public let chunkCount: Int

    public init(linesChanged: Int, chunkCount: Int) {
        self.linesChanged = linesChanged
        self.chunkCount = chunkCount
    }
}

public struct CoreApplyEditsSubjectResultV1: Sendable, Equatable {
    public let updatedText: String
    public let byteEdits: [CoreApplyEditsByteEdit]
    public let chunks: [CoreApplyEditsChunk]
    public let editsRequested: Int
    public let editsApplied: Int
    public let status: CoreApplyEditsStatus
    public let outcomes: [CoreApplyEditsOperationOutcome]?
    public let stats: CoreApplyEditsStats?
    public let note: String?
    public let unifiedDiff: String?
    public let toolCardUnifiedDiff: String?

    public init(
        updatedText: String,
        byteEdits: [CoreApplyEditsByteEdit],
        chunks: [CoreApplyEditsChunk],
        editsRequested: Int,
        editsApplied: Int,
        status: CoreApplyEditsStatus,
        outcomes: [CoreApplyEditsOperationOutcome]?,
        stats: CoreApplyEditsStats?,
        note: String?,
        unifiedDiff: String?,
        toolCardUnifiedDiff: String?
    ) {
        self.updatedText = updatedText
        self.byteEdits = byteEdits
        self.chunks = chunks
        self.editsRequested = editsRequested
        self.editsApplied = editsApplied
        self.status = status
        self.outcomes = outcomes
        self.stats = stats
        self.note = note
        self.unifiedDiff = unifiedDiff
        self.toolCardUnifiedDiff = toolCardUnifiedDiff
    }
}

public struct CoreApplyEditsBatchResultV1: Sendable, Equatable {
    public let subjects: [CoreApplyEditsSubjectResultV1]

    public init(subjects: [CoreApplyEditsSubjectResultV1]) {
        self.subjects = subjects
    }
}

/// TD-3 §5.3.1 mechanism 2 (design `docs/designs/textdecode-policy-v2-2026-08-22.md`): a
/// `Raw`-sourced apply-edits subject decoded lossily; write-back is refused. Deliberately its
/// own dedicated error type rather than a new `CoreComputeError` case: `CoreComputeError` is
/// shared, `default`-free-switched-over machinery reaching well beyond apply-edits (codemap,
/// inventory, path-match, ...), including consumer code this task's surface does not own --
/// adding a case there would force every one of those switches to grow an arm. Caught
/// specifically by `applyEditsBatchV1`'s own catch block below (apply-edits-specific, not the
/// shared `mapComputeFailure` path) and by `RustApplyEditsComputer`'s raw-bytes error mapping.
public struct CoreApplyEditsLossyDecodeBlocksWriteBackError: Error, Sendable, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

extension CoreComputeClient {
    public func applyEditsBatchV1(_ request: CoreApplyEditsBatchRequestV1) async throws -> CoreApplyEditsBatchResultV1 {
        try Self.validate(request)
        guard !request.subjects.isEmpty else { return .init(subjects: []) }
        let context = try await bridge.prepareComputeOperation()
        defer { try? context.transport.closeLeafCancellation(context.cancellation, identity: context.identity) }
        do {
            let compact = try await withTaskCancellationHandler {
                if Task.isCancelled {
                    try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
                    throw CancellationError()
                }
                return try await Task.detached(priority: nil) {
                    try context.transport.applyEditsBatchCompactV1(
                        identity: context.identity,
                        cancellation: context.cancellation,
                        request: request
                    )
                }.value
            } onCancel: {
                try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
            }
            if Task.isCancelled { throw CancellationError() }
            let validated = try CoreApplyEditsCompactValidator.validate(compact, request: request)
            try context.transport.closeLeafCancellation(context.cancellation, identity: context.identity)
            try await bridge.validateComputeCompletion(identity: context.identity)
            return CoreApplyEditsBatchResultV1(subjects: validated.map(\.materialized))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Intercepted here, ahead of the shared `mapComputeFailure` path, specifically to
            // avoid adding a case to `CoreComputeError` (see
            // `CoreApplyEditsLossyDecodeBlocksWriteBackError`'s doc comment).
            if let transportError = error as? CoreTransportError,
               case let .applyEditsLossyDecodeBlocksWriteBack(message) = transportError
            {
                throw CoreApplyEditsLossyDecodeBlocksWriteBackError(message: message)
            }
            throw await bridge.mapComputeFailure(error)
        }
    }

    private static func validate(_ request: CoreApplyEditsBatchRequestV1) throws {
        guard request.contractVersion == CoreApplyEditsBatchRequestV1.contractVersion else {
            throw CoreComputeError.invalidRequest("unsupported apply-edits contract version")
        }
        for subject in request.subjects {
            if subject.sourceKind == .decodedUTF8 {
                guard String(data: subject.originalUTF8, encoding: .utf8) != nil else {
                    throw CoreComputeError.invalidRequest("apply-edits original is not UTF-8")
                }
            }
            // `.raw` accepts any byte sequence: Rust's textdecode() never fails (design §5.1).
            switch subject.mode {
            case .rewrite:
                break
            case .single:
                break
            case let .batch(operations):
                guard !operations.isEmpty else {
                    throw CoreComputeError.invalidRequest("edits array cannot be empty")
                }
            }
        }
    }
}

extension CoreRuntimeTransport {
    func applyEditsBatchCompactV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreApplyEditsBatchRequestV1
    ) throws -> CoreCompactApplyEditsBatchResultV1 {
        throw CoreTransportError.unexpected("apply-edits compact transport is unavailable")
    }
}

struct CoreCompactApplyEditsSubjectSummaryV1: Equatable {
    let inputByteCount: UInt64
    let blobStart: UInt64
    let blobCount: UInt64
    let stringStart: UInt64
    let stringCount: UInt64
    let updatedTextStringIndex: UInt64
    let byteEditStart: UInt64
    let byteEditCount: UInt64
    let chunkStart: UInt64
    let chunkCount: UInt64
    let diffLineStart: UInt64
    let diffLineCount: UInt64
    let outcomeStart: UInt64
    let outcomeCount: UInt64
    let editsRequested: UInt64
    let editsApplied: UInt64
    let resultStatusTag: UInt64
    let outcomesPresent: Bool
    let statsPresent: Bool
    let linesChanged: UInt64
    let statsChunkCount: UInt64
    let noteStringIndex: UInt64
    let unifiedDiffStringIndex: UInt64
    let toolCardDiffStringIndex: UInt64
    let originalTextStringIndex: UInt64
}

struct CoreCompactApplyEditsBatchResultV1: Equatable {
    let subjectSummaries: [CoreCompactApplyEditsSubjectSummaryV1]
    let utf8Blob: Data
    let stringRangeWords: [UInt64]
    let byteEditWords: [UInt64]
    let chunkWords: [UInt64]
    let diffLineWords: [UInt64]
    let outcomeWords: [UInt64]
}

private struct CoreValidatedApplyEditsSubject {
    let materialized: CoreApplyEditsSubjectResultV1
}

private enum CoreApplyEditsCompactValidator {
    static let optional = UInt64.max
    static let stringStride = 2
    static let byteEditStride = 4
    static let chunkStride = 8
    static let diffLineStride = 2
    static let outcomeStride = 3

    static func validate(
        _ value: CoreCompactApplyEditsBatchResultV1,
        request: CoreApplyEditsBatchRequestV1
    ) throws -> [CoreValidatedApplyEditsSubject] {
        guard value.subjectSummaries.count == request.subjects.count,
              value.stringRangeWords.count.isMultiple(of: stringStride),
              value.byteEditWords.count.isMultiple(of: byteEditStride),
              value.chunkWords.count.isMultiple(of: chunkStride),
              value.diffLineWords.count.isMultiple(of: diffLineStride),
              value.outcomeWords.count.isMultiple(of: outcomeStride)
        else { throw CoreComputeError.malformedResponse }

        let totals = Counts(value)
        var cursors = Counts()
        var validated: [CoreValidatedApplyEditsSubject] = []
        validated.reserveCapacity(request.subjects.count)
        for (summary, input) in zip(value.subjectSummaries, request.subjects) {
            let ranges = try Ranges(summary)
            guard cursors.starts(ranges), ranges.inBounds(totals) else {
                throw CoreComputeError.malformedResponse
            }

            let strings = try validateStrings(value, ranges: ranges)
            func string(_ index: UInt64) throws -> String {
                guard let index = Int(exactly: index), index >= ranges.strings.start,
                      index - ranges.strings.start < strings.count
                else { throw CoreComputeError.malformedResponse }
                return strings[index - ranges.strings.start]
            }
            func optionalString(_ index: UInt64) throws -> String? {
                index == optional ? nil : try string(index)
            }

            // TD-3 §6.1: `byteEdits`/`chunks` offsets below are relative to whatever buffer
            // `apply_subject` actually diffed against Rust-side. For `.decodedUTF8` (the
            // untouched, GUI-apply-edits-depended-upon path) that's always exactly
            // `input.originalUTF8` -- re-derived locally, byte-for-byte identical to before.
            // For `.raw` (ladder 6, D-6) it's `textdecode`'s output, which Swift cannot
            // re-derive from the raw request bytes alone, so Rust echoes it back via
            // `originalTextStringIndex`; its UTF-8 validity is already enforced by
            // `validateStrings`' blob-wide check above.
            let original: String
            switch input.sourceKind {
            case .decodedUTF8:
                // Non-stripping decode: Foundation's String(data:encoding:) removes a
                // leading U+FEFF BOM, desynchronizing Swift-side validation from the
                // Rust engine's byte offsets (which operate on the exact request
                // bytes). Validity is enforced by the strict guard below; the working
                // copy must round-trip the bytes exactly.
                guard summary.inputByteCount == UInt64(input.originalUTF8.count),
                      String(data: input.originalUTF8, encoding: .utf8) != nil
                else { throw CoreComputeError.malformedResponse }
                original = String(decoding: input.originalUTF8, as: UTF8.self)
            case .raw:
                original = try string(summary.originalTextStringIndex)
            }

            let updated = try string(summary.updatedTextStringIndex)
            let edits = try validateByteEdits(value, ranges: ranges, original: original, updated: updated)
            let chunks = try validateChunks(value, ranges: ranges, original: original, updated: updated, string: string)
            let outcomes = try validateOutcomes(value, summary: summary, ranges: ranges, string: string)
            let status = try validateSummary(summary, ranges: ranges, outcomes: outcomes, chunkCount: chunks.count)
            let stats = try summary.statsPresent
                ? CoreApplyEditsStats(linesChanged: integer(summary.linesChanged), chunkCount: integer(summary.statsChunkCount))
                : nil
            try validated.append(.init(materialized: .init(
                updatedText: updated,
                byteEdits: edits,
                chunks: chunks,
                editsRequested: integer(summary.editsRequested),
                editsApplied: integer(summary.editsApplied),
                status: status,
                outcomes: outcomes,
                stats: stats,
                note: optionalString(summary.noteStringIndex),
                unifiedDiff: optionalString(summary.unifiedDiffStringIndex),
                toolCardUnifiedDiff: optionalString(summary.toolCardDiffStringIndex)
            )))
            cursors.advance(ranges)
        }
        guard cursors == totals else { throw CoreComputeError.malformedResponse }
        return validated
    }

    private static func validateStrings(
        _ value: CoreCompactApplyEditsBatchResultV1,
        ranges: Ranges
    ) throws -> [String] {
        guard let blobEnd = ranges.blob.end, blobEnd <= value.utf8Blob.count,
              String(data: value.utf8Blob[ranges.blob.start ..< blobEnd], encoding: .utf8) != nil
        else { throw CoreComputeError.malformedResponse }
        var byteCursor = ranges.blob.start
        var output: [String] = []
        output.reserveCapacity(ranges.strings.count)
        for row in try applyRows(value.stringRangeWords, range: ranges.strings, stride: stringStride) {
            guard let start = Int(exactly: row[0]), let end = Int(exactly: row[1]),
                  start == byteCursor, start <= end, end <= blobEnd,
                  applyUTF8Boundary(start, in: value.utf8Blob), applyUTF8Boundary(end, in: value.utf8Blob),
                  String(data: value.utf8Blob[start ..< end], encoding: .utf8) != nil
            else { throw CoreComputeError.malformedResponse }
            // Non-stripping decode (see the `original` note above): a string that
            // legitimately begins with U+FEFF (e.g. BOM-preserving updatedText)
            // must keep it so byte offsets stay aligned with the Rust engine.
            output.append(String(decoding: value.utf8Blob[start ..< end], as: UTF8.self))
            byteCursor = end
        }
        guard byteCursor == blobEnd else { throw CoreComputeError.malformedResponse }
        return output
    }

    private static func validateByteEdits(
        _ value: CoreCompactApplyEditsBatchResultV1,
        ranges: Ranges,
        original: String,
        updated: String
    ) throws -> [CoreApplyEditsByteEdit] {
        var oldCursor = 0
        var newCursor = 0
        var edits: [CoreApplyEditsByteEdit] = []
        for row in try applyRows(value.byteEditWords, range: ranges.edits, stride: byteEditStride) {
            guard let oldStart = Int(exactly: row[0]), let oldEnd = Int(exactly: row[1]),
                  let newStart = Int(exactly: row[2]), let newEnd = Int(exactly: row[3]),
                  oldStart >= oldCursor, oldStart <= oldEnd, oldEnd <= original.utf8.count,
                  newStart >= newCursor, newStart <= newEnd, newEnd <= updated.utf8.count,
                  applyStringBoundary(oldStart, in: original), applyStringBoundary(oldEnd, in: original),
                  applyStringBoundary(newStart, in: updated), applyStringBoundary(newEnd, in: updated)
            else { throw CoreComputeError.malformedResponse }
            edits.append(.init(oldRange: oldStart ..< oldEnd, newRange: newStart ..< newEnd))
            oldCursor = oldEnd
            newCursor = newEnd
        }
        var reconstructed = Data()
        var cursor = 0
        let originalData = Data(original.utf8)
        let updatedData = Data(updated.utf8)
        for edit in edits {
            reconstructed.append(originalData[cursor ..< edit.oldRange.lowerBound])
            reconstructed.append(updatedData[edit.newRange])
            cursor = edit.oldRange.upperBound
        }
        reconstructed.append(originalData[cursor...])
        guard reconstructed == updatedData else { throw CoreComputeError.malformedResponse }
        return edits
    }

    private static func validateChunks(
        _ value: CoreCompactApplyEditsBatchResultV1,
        ranges: Ranges,
        original: String,
        updated: String,
        string: (UInt64) throws -> String
    ) throws -> [CoreApplyEditsChunk] {
        var expectedLine = ranges.lines.start
        var chunks: [CoreApplyEditsChunk] = []
        for row in try applyRows(value.chunkWords, range: ranges.chunks, stride: chunkStride) {
            guard row[7] == 0,
                  let startLine = Int(exactly: row[0]),
                  let oldStart = Int(exactly: row[1]), let oldEnd = Int(exactly: row[2]),
                  let newStart = Int(exactly: row[3]), let newEnd = Int(exactly: row[4]),
                  let lineStart = Int(exactly: row[5]), let lineCount = Int(exactly: row[6]),
                  lineStart == expectedLine,
                  oldStart <= oldEnd, oldEnd <= original.utf8.count,
                  newStart <= newEnd, newEnd <= updated.utf8.count,
                  applyStringBoundary(oldStart, in: original), applyStringBoundary(oldEnd, in: original),
                  applyStringBoundary(newStart, in: updated), applyStringBoundary(newEnd, in: updated),
                  lineCount <= ranges.lines.endValue - lineStart
            else { throw CoreComputeError.malformedResponse }
            let lines = try applyRows(
                value.diffLineWords,
                range: .init(start: lineStart, count: lineCount),
                stride: diffLineStride
            ).map { row -> CoreApplyEditsDiffLine in
                guard let type = CoreApplyEditsDiffLineType(rawValue: UInt8(exactly: row[0]) ?? .max) else {
                    throw CoreComputeError.malformedResponse
                }
                return try .init(type: type, content: string(row[1]))
            }
            chunks.append(.init(
                startLine: startLine,
                oldByteRange: oldStart ..< oldEnd,
                newByteRange: newStart ..< newEnd,
                lines: lines
            ))
            expectedLine += lineCount
        }
        guard expectedLine == ranges.lines.endValue,
              reconstructWithChunks(original: original, chunks: chunks) == updated
        else { throw CoreComputeError.malformedResponse }
        return chunks
    }

    private static func validateOutcomes(
        _ value: CoreCompactApplyEditsBatchResultV1,
        summary: CoreCompactApplyEditsSubjectSummaryV1,
        ranges: Ranges,
        string: (UInt64) throws -> String
    ) throws -> [CoreApplyEditsOperationOutcome]? {
        guard summary.outcomesPresent || ranges.outcomes.count == 0 else { throw CoreComputeError.malformedResponse }
        guard summary.outcomesPresent else { return nil }
        guard summary.outcomeCount == summary.editsRequested else { throw CoreComputeError.malformedResponse }
        var output: [CoreApplyEditsOperationOutcome] = []
        for (expected, row) in try applyRows(value.outcomeWords, range: ranges.outcomes, stride: outcomeStride).enumerated() {
            guard row[0] == UInt64(expected),
                  let status = CoreApplyEditsOutcomeStatus(rawValue: UInt8(exactly: row[1]) ?? .max)
            else { throw CoreComputeError.malformedResponse }
            let error: String?
            switch status {
            case .success:
                guard row[2] == optional else { throw CoreComputeError.malformedResponse }
                error = nil
            case .failed:
                guard row[2] != optional else { throw CoreComputeError.malformedResponse }
                error = try string(row[2])
            }
            output.append(.init(operationIndex: expected, status: status, error: error))
        }
        return output
    }

    private static func validateSummary(
        _ summary: CoreCompactApplyEditsSubjectSummaryV1,
        ranges: Ranges,
        outcomes: [CoreApplyEditsOperationOutcome]?,
        chunkCount: Int
    ) throws -> CoreApplyEditsStatus {
        guard let status = CoreApplyEditsStatus(rawValue: UInt8(exactly: summary.resultStatusTag) ?? .max),
              let requested = Int(exactly: summary.editsRequested),
              let applied = Int(exactly: summary.editsApplied),
              applied <= requested,
              status == (applied == requested ? .success : (applied == 0 ? .failed : .partial))
        else { throw CoreComputeError.malformedResponse }
        if let outcomes {
            guard outcomes.count(where: { $0.status == .success }) == applied else {
                throw CoreComputeError.malformedResponse
            }
        }
        if summary.statsPresent {
            guard summary.statsChunkCount == UInt64(chunkCount) else { throw CoreComputeError.malformedResponse }
        } else {
            guard summary.linesChanged == 0, summary.statsChunkCount == 0 else { throw CoreComputeError.malformedResponse }
        }
        _ = ranges
        return status
    }

    private static func reconstructWithChunks(original: String, chunks: [CoreApplyEditsChunk]) -> String? {
        var lines = splitLinesPreservingEndings(original)
        var adjusted = chunks.map(\.startLine)
        for (index, chunk) in chunks.enumerated() {
            let start = adjusted[index]
            let old = chunk.lines.filter { $0.type != .addition }.map(\.content)
            let replacement = chunk.lines.filter { $0.type != .removal }.map(\.content)
            guard start <= lines.count, old.count <= lines.count - start,
                  Array(lines[start ..< start + old.count]) == old
            else { return nil }
            lines.replaceSubrange(start ..< start + old.count, with: replacement)
            let delta = chunk.lines.count(where: { $0.type == .addition })
                - chunk.lines.count(where: { $0.type == .removal })
            if delta != 0 {
                for later in (index + 1) ..< adjusted.count where adjusted[later] > start {
                    adjusted[later] = max(0, min(lines.count, adjusted[later] + delta))
                }
            }
        }
        return lines.joined()
    }

    private static func splitLinesPreservingEndings(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        let bytes = Array(value.utf8)
        var lines: [String] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == 10 {
                lines.append(String(decoding: bytes[start ... index], as: UTF8.self))
                start = index + 1
            } else if bytes[index] == 13 {
                if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                lines.append(String(decoding: bytes[start ... index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        if start < bytes.count { lines.append(String(decoding: bytes[start...], as: UTF8.self)) }
        return lines
    }
}

private struct ApplyRange: Equatable {
    let start: Int
    let count: Int
    var end: Int? {
        let (value, overflow) = start.addingReportingOverflow(count)
        return overflow ? nil : value
    }

    var endValue: Int {
        end ?? -1
    }
}

private struct Ranges {
    let blob: ApplyRange
    let strings: ApplyRange
    let edits: ApplyRange
    let chunks: ApplyRange
    let lines: ApplyRange
    let outcomes: ApplyRange

    init(_ value: CoreCompactApplyEditsSubjectSummaryV1) throws {
        blob = try .init(value.blobStart, value.blobCount)
        strings = try .init(value.stringStart, value.stringCount)
        edits = try .init(value.byteEditStart, value.byteEditCount)
        chunks = try .init(value.chunkStart, value.chunkCount)
        lines = try .init(value.diffLineStart, value.diffLineCount)
        outcomes = try .init(value.outcomeStart, value.outcomeCount)
    }

    func inBounds(_ totals: Counts) -> Bool {
        [
            (blob, totals.blob),
            (strings, totals.strings),
            (edits, totals.edits),
            (chunks, totals.chunks),
            (lines, totals.lines),
            (outcomes, totals.outcomes)
        ]
        .allSatisfy { range, total in range.start >= 0 && range.end.map { $0 <= total } == true }
    }
}

private extension ApplyRange {
    init(_ start: UInt64, _ count: UInt64) throws {
        guard let start = Int(exactly: start), let count = Int(exactly: count) else {
            throw CoreComputeError.malformedResponse
        }
        self.init(start: start, count: count)
    }
}

private struct Counts: Equatable {
    var blob = 0
    var strings = 0
    var edits = 0
    var chunks = 0
    var lines = 0
    var outcomes = 0

    init() {}
    init(_ value: CoreCompactApplyEditsBatchResultV1) {
        blob = value.utf8Blob.count
        strings = value.stringRangeWords.count / 2
        edits = value.byteEditWords.count / 4
        chunks = value.chunkWords.count / 8
        lines = value.diffLineWords.count / 2
        outcomes = value.outcomeWords.count / 3
    }

    func starts(_ ranges: Ranges) -> Bool {
        blob == ranges.blob.start && strings == ranges.strings.start && edits == ranges.edits.start
            && chunks == ranges.chunks.start && lines == ranges.lines.start && outcomes == ranges.outcomes.start
    }

    mutating func advance(_ ranges: Ranges) {
        blob = ranges.blob.endValue
        strings = ranges.strings.endValue
        edits = ranges.edits.endValue
        chunks = ranges.chunks.endValue
        lines = ranges.lines.endValue
        outcomes = ranges.outcomes.endValue
    }
}

private func applyRows(_ values: [UInt64], range: ApplyRange, stride: Int) throws -> [[UInt64]] {
    guard let rowEnd = range.end else { throw CoreComputeError.malformedResponse }
    let (start, startOverflow) = range.start.multipliedReportingOverflow(by: stride)
    let (end, endOverflow) = rowEnd.multipliedReportingOverflow(by: stride)
    guard !startOverflow, !endOverflow, start >= 0, end <= values.count else {
        throw CoreComputeError.malformedResponse
    }
    return Swift.stride(from: start, to: end, by: stride).map { Array(values[$0 ..< $0 + stride]) }
}

private func applyUTF8Boundary(_ offset: Int, in data: Data) -> Bool {
    offset == 0 || offset == data.count || (offset > 0 && offset < data.count && data[offset] & 0xC0 != 0x80)
}

private func applyStringBoundary(_ offset: Int, in value: String) -> Bool {
    guard offset >= 0, offset <= value.utf8.count else { return false }
    let index = value.utf8.index(value.utf8.startIndex, offsetBy: offset)
    return index.samePosition(in: value) != nil
}

private func integer(_ value: UInt64) throws -> Int {
    guard let value = Int(exactly: value) else { throw CoreComputeError.malformedResponse }
    return value
}
