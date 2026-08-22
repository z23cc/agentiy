import Foundation

// ---- Public friendly domain types (P3-4 token-accounting DIFFERENTIAL-ONLY seam) --------------
//
// IMPORTANT: this seam is DIFFERENTIAL-ONLY -- see rust/crates/runtime/src/tokenacct/wire.rs's
// module doc. It batches a whole snapshot's entries plus every component-breakdown row into ONE
// call -- this is NOT the eventual production shape (no production caller drives
// `TokenCalculationService` this way; it is an `actor` invoked per live view-model snapshot).
// This module exists so `RustTokenAccountingProbe` can drive the real Rust seam (no mocking)
// against the real `TokenCalculationService` and assert exact parity.
//
// See `rust/crates/runtime/src/tokenacct/mod.rs`'s module doc for the Unicode/ICU decisions: the
// two grapheme-cluster-count (`String.count`) sites -- `loadedContentCharCount` and
// `sliceTotalCharacters` below -- are precompute-and-carry: callers MUST supply the real Swift
// `String.count` value here, never a byte or scalar count, and the Rust kernel never recomputes
// them from the pooled text.

/// One `PromptFileEntrySnapshot`-equivalent row, ordinal-identified (no `fileID` -- see
/// `rust/crates/runtime/src/tokenacct/entries.rs`'s module doc for why duplicate-identity
/// snapshots have no analog on this wire).
public struct CoreTokenAccountingEntryV1: Sendable, Equatable {
    public let isCodemapRequested: Bool
    /// Mirrors `entry.codeMapContent` -- `nil` means "unresolved" (`codeMapContent == nil`),
    /// `Some(text)` (including `Some("")`) means "resolved".
    public let codemapContent: String?
    public let availableCodemapTokenCount: Int
    /// Mirrors `sliceAssemblies[entry.fileID] != nil` -- the REAL
    /// `FileViewModel.buildSliceAssembly` result's `combinedText`, or `nil` if this entry
    /// resolved to the full-mode branch (no ranges, or ranges but no loaded content).
    public let sliceCombinedText: String?
    /// Precomputed `assembly.totalCharacters` (`combinedText.count`); only meaningful when
    /// `sliceCombinedText != nil`.
    public let sliceTotalCharacters: Int
    public let loadedContent: String?
    /// Precomputed `loadedContent!.count`; only meaningful when `loadedContent != nil`.
    public let loadedContentCharCount: Int
    public let cachedFullTokenCount: Int?
    public let relativePath: String

    public init(
        isCodemapRequested: Bool,
        codemapContent: String?,
        availableCodemapTokenCount: Int,
        sliceCombinedText: String?,
        sliceTotalCharacters: Int,
        loadedContent: String?,
        loadedContentCharCount: Int,
        cachedFullTokenCount: Int?,
        relativePath: String
    ) {
        self.isCodemapRequested = isCodemapRequested
        self.codemapContent = codemapContent
        self.availableCodemapTokenCount = availableCodemapTokenCount
        self.sliceCombinedText = sliceCombinedText
        self.sliceTotalCharacters = sliceTotalCharacters
        self.loadedContent = loadedContent
        self.loadedContentCharCount = loadedContentCharCount
        self.cachedFullTokenCount = cachedFullTokenCount
        self.relativePath = relativePath
    }
}

/// One `calculateComponentBreakdown` call's inputs. `gitDiffText`/`metadataText` use `""` for
/// Swift's `nil` (behaviorally identical -- `estimateTokens(for: "") == 0` either way).
public struct CoreTokenAccountingComponentV1: Sendable, Equatable {
    public let promptText: String
    public let selectedInstructionsText: String
    public let fileTreeText: String
    public let gitDiffText: String
    public let metadataText: String
    public let duplicateUserInstructionsAtTop: Bool

    public init(
        promptText: String,
        selectedInstructionsText: String,
        fileTreeText: String,
        gitDiffText: String,
        metadataText: String,
        duplicateUserInstructionsAtTop: Bool
    ) {
        self.promptText = promptText
        self.selectedInstructionsText = selectedInstructionsText
        self.fileTreeText = fileTreeText
        self.gitDiffText = gitDiffText
        self.metadataText = metadataText
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
    }
}

public enum CoreTokenAccountingRenderModeV1: Sendable, Equatable {
    case full
    case slice
    /// `PromptEntriesEvaluation.RenderMode.codemap`, resolved (`codeMapContent != nil`).
    case codemap
    /// `PromptEntriesEvaluation.RenderMode.codemap`, unresolved (`codeMapContent == nil`).
    case codemapUnresolved
}

/// One entry's result, index-aligned with the request's `entries`. Mirrors
/// `PromptEntriesEvaluation.EntryResult` plus its derived per-file `TokenInfo.formatted`/
/// `percentage` (against `combinedDisplayTokens`).
public struct CoreTokenAccountingEntryResultV1: Sendable, Equatable {
    public let renderMode: CoreTokenAccountingRenderModeV1
    public let displayTokens: Int
    public let fullTokens: Int
    public let codemapTokens: Int
    public let displayLineCount: Int?
    public let charCountContribution: Int
    public let formatted: String
    public let percentage: Double
}

/// Mirrors `AggregatedEntryTokens` (minus the per-file/folder maps, reported separately below).
public struct CoreTokenAccountingAggregatesV1: Sendable, Equatable {
    public let totalContentTokens: Int
    public let fullCount: Int
    public let sliceCount: Int
    public let codemapCount: Int
    public let fullTokens: Int
    public let sliceTokens: Int
    /// The resolved-codemap-bucket total (ALL entries, including empty-content ones) -- NOT the
    /// same number as `codeMapTokenCount` below. See
    /// `rust/crates/runtime/src/tokenacct/entries.rs`'s `Aggregates::codemap_tokens` doc.
    public let codemapTokens: Int
    public let charCount: Int
}

/// One folder's rollup, in first-encounter order (sort by `name` before comparing against
/// Swift's `[String: TokenInfo]`).
public struct CoreTokenAccountingFolderV1: Sendable, Equatable {
    public let name: String
    public let tokens: Int
    public let formatted: String
    public let percentage: Double
}

/// One component-breakdown row's result, index-aligned with the request's `components`. Mirrors
/// `TokenComponentBreakdown`.
public struct CoreTokenAccountingComponentResultV1: Sendable, Equatable {
    public let prompt: Int
    public let duplicatePrompt: Int
    public let instructions: Int
    public let fileTree: Int
    public let gitDiff: Int
    public let metadata: Int
}

public struct CoreTokenAccountingResponseV1: Sendable, Equatable {
    public let entries: [CoreTokenAccountingEntryResultV1]
    public let aggregates: CoreTokenAccountingAggregatesV1
    /// `aggregates.totalContentTokens + aggregates.codemapTokens` -- the percentage denominator
    /// `entries[*].percentage`/`folders[*].percentage` share.
    public let combinedDisplayTokens: Int
    /// `aggregates.totalContentTokens + codeMapTokenCount` -- mirrors
    /// `PromptEntriesEvaluation.totalDisplayTokens`.
    public let totalDisplayTokens: Int
    public let codeMapContent: String
    public let codeMapFileCount: Int
    public let codeMapTokenCount: Int
    public let folders: [CoreTokenAccountingFolderV1]
    public let components: [CoreTokenAccountingComponentResultV1]
}

// ---- CoreComputeClient surface ----------------------------------------------------------------

extension CoreComputeClient {
    /// DIFFERENTIAL-ONLY: Rust port of `TokenCalculationService.calculateEntryTokens`/
    /// `evaluatePromptEntries`/`calculateComponentBreakdown`, batched. See this file's top doc
    /// for why this is NOT the production shape.
    public func tokenAccountingV1(
        entries: [CoreTokenAccountingEntryV1],
        components: [CoreTokenAccountingComponentV1]
    ) async throws -> CoreTokenAccountingResponseV1 {
        for entry in entries {
            guard entry.availableCodemapTokenCount >= 0,
                  entry.sliceTotalCharacters >= 0,
                  entry.loadedContentCharCount >= 0,
                  (entry.cachedFullTokenCount ?? 0) >= 0
            else {
                throw CoreComputeError.invalidRequest("token-accounting entry counts must be non-negative")
            }
        }

        var builder = CoreTokenAccountingRequestBuilder()
        for entry in entries {
            builder.pushEntry(entry)
        }
        for component in components {
            builder.pushComponent(component)
        }
        var request = CoreCompactTokenAccountingRequestV1()
        builder.fill(into: &request)

        return try await performTokenAccounting(request) { compact in
            try CoreTokenAccountingCompactValidator.decode(
                compact,
                entryCount: entries.count,
                componentCount: components.count
            )
        }
    }

    /// Shared control-flow template (see `CorePathSearch.swift`'s identically-shaped
    /// `performPathSearch`): `prepareComputeOperation()` -> detached transport call with
    /// cooperative cancellation -> fail-closed decode -> `validateComputeCompletion` -> return
    /// the decoded, typed result.
    private func performTokenAccounting(
        _ request: CoreCompactTokenAccountingRequestV1,
        decode: @Sendable (CoreCompactTokenAccountingResultV1) throws -> CoreTokenAccountingResponseV1
    ) async throws -> CoreTokenAccountingResponseV1 {
        let context = try await bridge.prepareComputeOperation()
        defer { try? context.transport.closeLeafCancellation(context.cancellation, identity: context.identity) }
        do {
            let compact = try await withTaskCancellationHandler {
                if Task.isCancelled {
                    try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
                    throw CancellationError()
                }
                return try await Task.detached(priority: nil) {
                    try context.transport.tokenAccountingV1(
                        identity: context.identity,
                        cancellation: context.cancellation,
                        request: request
                    )
                }.value
            } onCancel: {
                try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
            }
            if Task.isCancelled { throw CancellationError() }
            let decoded = try decode(compact)
            try context.transport.closeLeafCancellation(context.cancellation, identity: context.identity)
            try await bridge.validateComputeCompletion(identity: context.identity)
            return decoded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await bridge.mapComputeFailure(error)
        }
    }
}

extension CoreRuntimeTransport {
    func tokenAccountingV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactTokenAccountingRequestV1
    ) throws -> CoreCompactTokenAccountingResultV1 {
        throw CoreTransportError.unexpected("token-accounting compact transport is unavailable")
    }
}

// ---- Compact wire mirrors (bridge-internal) ---------------------------------------------------
//
// Mirrors rust/crates/runtime/src/tokenacct/{contract.rs,wire.rs} exactly: word-table strides
// and the pool-plus-flat-row shape. DO NOT change any stride or field order here without a
// matching Rust-side change -- these two sides are validated by
// TokenAccountingRustSwiftDifferentialTests, not by the type system.

private let coreTokenAccountingContractVersionV1: UInt16 = 1
private let coreTokenAccountingStringRangeStride = 2
private let coreTokenAccountingEntryStride = 13
private let coreTokenAccountingEntryResultStride = 7
private let coreTokenAccountingComponentStride = 6
private let coreTokenAccountingComponentResultStride = 6

struct CoreCompactTokenAccountingRequestV1 {
    var contractVersion: UInt16 = coreTokenAccountingContractVersionV1
    var utf8Blob = Data()
    var stringRangeWords: [UInt64] = []
    var entryWords: [UInt64] = []
    var componentWords: [UInt64] = []
}

struct CoreCompactTokenAccountingResultV1: Equatable {
    let entryResultWords: [UInt64]
    let entryFormatted: [String]
    let entryPercentage: [Double]
    let aggregateWords: [UInt64]
    let combinedDisplayTokens: UInt64
    let totalDisplayTokens: UInt64
    let codeMapContent: String
    let codeMapFileCount: UInt64
    let codeMapTokenCount: UInt64
    let folderNames: [String]
    let folderTokenCounts: [UInt64]
    let folderFormatted: [String]
    let folderPercentage: [Double]
    let componentResultWords: [UInt64]
}

// ---- encode --------------------------------------------------------------------------------

/// Accumulates the shared string pool + tables for one compact token-accounting request,
/// mirroring the Rust `TokenAccountingRequestV1::push_string`/`push_content_entry`/
/// `push_codemap_entry`/`push_component` methods in `wire.rs`. Field/row order below MUST match
/// those exactly.
private struct CoreTokenAccountingRequestBuilder {
    var utf8Blob = Data()
    var stringRangeWords: [UInt64] = []
    var entryWords: [UInt64] = []
    var componentWords: [UInt64] = []

    mutating func pushString(_ text: String) -> UInt64 {
        let start = UInt64(utf8Blob.count)
        utf8Blob.append(contentsOf: Array(text.utf8))
        let end = UInt64(utf8Blob.count)
        let index = UInt64(stringRangeWords.count / coreTokenAccountingStringRangeStride)
        stringRangeWords.append(start)
        stringRangeWords.append(end)
        return index
    }

    mutating func pushEntry(_ entry: CoreTokenAccountingEntryV1) {
        let codemapContentPresent: UInt64 = entry.codemapContent != nil ? 1 : 0
        let codemapContentIdx = pushString(entry.codemapContent ?? "")
        let resolvedAsSlice: UInt64 = entry.sliceCombinedText != nil ? 1 : 0
        let sliceCombinedTextIdx = pushString(entry.sliceCombinedText ?? "")
        let sliceTotalCharacters = entry.sliceCombinedText != nil ? UInt64(entry.sliceTotalCharacters) : 0
        let loadedContentPresent: UInt64 = entry.loadedContent != nil ? 1 : 0
        let loadedContentIdx = pushString(entry.loadedContent ?? "")
        let loadedContentCharCount = entry.loadedContent != nil ? UInt64(entry.loadedContentCharCount) : 0
        let cachedFullTokenCountPresent: UInt64 = entry.cachedFullTokenCount != nil ? 1 : 0
        let relativePathIdx = pushString(entry.relativePath)
        entryWords.append(contentsOf: [
            entry.isCodemapRequested ? 1 : 0,
            codemapContentPresent,
            codemapContentIdx,
            UInt64(entry.availableCodemapTokenCount),
            resolvedAsSlice,
            sliceCombinedTextIdx,
            sliceTotalCharacters,
            loadedContentPresent,
            loadedContentIdx,
            loadedContentCharCount,
            cachedFullTokenCountPresent,
            UInt64(entry.cachedFullTokenCount ?? 0),
            relativePathIdx
        ])
    }

    mutating func pushComponent(_ component: CoreTokenAccountingComponentV1) {
        let promptIdx = pushString(component.promptText)
        let instructionsIdx = pushString(component.selectedInstructionsText)
        let fileTreeIdx = pushString(component.fileTreeText)
        let gitDiffIdx = pushString(component.gitDiffText)
        let metadataIdx = pushString(component.metadataText)
        componentWords.append(contentsOf: [
            promptIdx, instructionsIdx, fileTreeIdx, gitDiffIdx, metadataIdx,
            component.duplicateUserInstructionsAtTop ? 1 : 0
        ])
    }

    func fill(into request: inout CoreCompactTokenAccountingRequestV1) {
        request.utf8Blob = utf8Blob
        request.stringRangeWords = stringRangeWords
        request.entryWords = entryWords
        request.componentWords = componentWords
    }
}

// ---- decode + fail-closed validation -----------------------------------------------------------

enum CoreTokenAccountingCompactValidator {
    static func decode(
        _ value: CoreCompactTokenAccountingResultV1,
        entryCount: Int,
        componentCount: Int
    ) throws -> CoreTokenAccountingResponseV1 {
        guard value.entryResultWords.count == entryCount * coreTokenAccountingEntryResultStride,
              value.entryFormatted.count == entryCount,
              value.entryPercentage.count == entryCount,
              value.aggregateWords.count == 8,
              value.componentResultWords.count == componentCount * coreTokenAccountingComponentResultStride,
              value.folderTokenCounts.count == value.folderNames.count,
              value.folderFormatted.count == value.folderNames.count,
              value.folderPercentage.count == value.folderNames.count
        else { throw CoreComputeError.malformedResponse }

        var entryResults: [CoreTokenAccountingEntryResultV1] = []
        entryResults.reserveCapacity(entryCount)
        for entryIndex in 0 ..< entryCount {
            let base = entryIndex * coreTokenAccountingEntryResultStride
            let renderModeRaw = value.entryResultWords[base]
            let renderMode: CoreTokenAccountingRenderModeV1
            switch renderModeRaw {
            case 0: renderMode = .full
            case 1: renderMode = .slice
            case 2: renderMode = .codemap
            case 3: renderMode = .codemapUnresolved
            default: throw CoreComputeError.malformedResponse
            }
            let displayLineCountPresent = value.entryResultWords[base + 4]
            guard displayLineCountPresent == 0 || displayLineCountPresent == 1 else {
                throw CoreComputeError.malformedResponse
            }
            entryResults.append(CoreTokenAccountingEntryResultV1(
                renderMode: renderMode,
                displayTokens: try intWord(value.entryResultWords[base + 1]),
                fullTokens: try intWord(value.entryResultWords[base + 2]),
                codemapTokens: try intWord(value.entryResultWords[base + 3]),
                displayLineCount: displayLineCountPresent == 1
                    ? try intWord(value.entryResultWords[base + 5]) : nil,
                charCountContribution: try intWord(value.entryResultWords[base + 6]),
                formatted: value.entryFormatted[entryIndex],
                percentage: value.entryPercentage[entryIndex]
            ))
        }

        let aggregates = CoreTokenAccountingAggregatesV1(
            totalContentTokens: try intWord(value.aggregateWords[0]),
            fullCount: try intWord(value.aggregateWords[1]),
            sliceCount: try intWord(value.aggregateWords[2]),
            codemapCount: try intWord(value.aggregateWords[3]),
            fullTokens: try intWord(value.aggregateWords[4]),
            sliceTokens: try intWord(value.aggregateWords[5]),
            codemapTokens: try intWord(value.aggregateWords[6]),
            charCount: try intWord(value.aggregateWords[7])
        )

        var folders: [CoreTokenAccountingFolderV1] = []
        folders.reserveCapacity(value.folderNames.count)
        for folderIndex in 0 ..< value.folderNames.count {
            folders.append(CoreTokenAccountingFolderV1(
                name: value.folderNames[folderIndex],
                tokens: try intWord(value.folderTokenCounts[folderIndex]),
                formatted: value.folderFormatted[folderIndex],
                percentage: value.folderPercentage[folderIndex]
            ))
        }

        var componentResults: [CoreTokenAccountingComponentResultV1] = []
        componentResults.reserveCapacity(componentCount)
        for componentIndex in 0 ..< componentCount {
            let base = componentIndex * coreTokenAccountingComponentResultStride
            componentResults.append(CoreTokenAccountingComponentResultV1(
                prompt: try intWord(value.componentResultWords[base]),
                duplicatePrompt: try intWord(value.componentResultWords[base + 1]),
                instructions: try intWord(value.componentResultWords[base + 2]),
                fileTree: try intWord(value.componentResultWords[base + 3]),
                gitDiff: try intWord(value.componentResultWords[base + 4]),
                metadata: try intWord(value.componentResultWords[base + 5])
            ))
        }

        return CoreTokenAccountingResponseV1(
            entries: entryResults,
            aggregates: aggregates,
            combinedDisplayTokens: try intWord(value.combinedDisplayTokens),
            totalDisplayTokens: try intWord(value.totalDisplayTokens),
            codeMapContent: value.codeMapContent,
            codeMapFileCount: try intWord(value.codeMapFileCount),
            codeMapTokenCount: try intWord(value.codeMapTokenCount),
            folders: folders,
            components: componentResults
        )
    }

    private static func intWord(_ value: UInt64) throws -> Int {
        guard let converted = Int(exactly: value) else { throw CoreComputeError.malformedResponse }
        return converted
    }
}
