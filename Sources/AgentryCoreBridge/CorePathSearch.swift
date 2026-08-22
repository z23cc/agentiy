import Foundation

// ---- Public friendly domain types (P3-3 slice-2b phase-2 path-search DIFFERENTIAL-ONLY seam) --
//
// IMPORTANT: this seam is DIFFERENTIAL-ONLY -- see
// rust/crates/runtime/src/pathsearch/wire.rs's module doc. It batches an entire corpus plus every
// query into ONE call, rebuilding the whole Rust `PathSearchIndex` per call -- this is NOT the
// eventual production shape (which needs the P4 stateful scope-registry handle primitive; a
// per-keystroke caller rebuilding the whole corpus every query would pay the same whole-table tax
// the P3-2c inventory benchmark measured to be prohibitive, 57545bfa). This module exists so
// `RustPathSearchProbe` can drive the real Rust seam (no mocking) against the real C-backed Swift
// `PathSearchIndex` (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift`)
// and assert exact parity.

/// One path-search query's mode: mirrors `PathSearchIndex`'s two entry points
/// (`searchSynchronously` vs `searchProjectedSynchronously`).
public enum CorePathSearchQueryModeV1: Sendable, Equatable {
    /// `PathSearchIndex.searchSynchronously` / Rust `PathSearchIndex::find`.
    case find
    /// `PathSearchIndex.searchProjectedSynchronously` / Rust `PathSearchIndex::projected_find`.
    /// The matched subject is `displayPrefix + relativePath + "\n" + absolutePrefix +
    /// relativePath` -- see `engine.rs`'s module doc.
    case projected(displayPrefix: String, absolutePrefix: String)
}

public struct CorePathSearchQueryV1: Sendable, Equatable {
    public let pattern: String
    public let limit: Int
    public let mode: CorePathSearchQueryModeV1

    public init(pattern: String, limit: Int, mode: CorePathSearchQueryModeV1) {
        self.pattern = pattern
        self.limit = limit
        self.mode = mode
    }
}

/// Mirrors `PathSearchIndex.ProjectedSearchDiagnostics` -- present only for `.projected` queries
/// (`nil` for `.find` queries, which have no diagnostic contract in the C source this was ported
/// from).
public struct CorePathSearchStatsV1: Sendable, Equatable {
    public let examinedCount: Int
    public let matchedCount: Int
    public let heapPeakCount: Int
    public let heapComparisonCount: Int
    public let scratchBytes: Int

    public init(
        examinedCount: Int,
        matchedCount: Int,
        heapPeakCount: Int,
        heapComparisonCount: Int,
        scratchBytes: Int
    ) {
        self.examinedCount = examinedCount
        self.matchedCount = matchedCount
        self.heapPeakCount = heapPeakCount
        self.heapComparisonCount = heapComparisonCount
        self.scratchBytes = scratchBytes
    }
}

/// One query's result: corpus ordinals in result order (0-based, into the request's `corpusPaths`
/// array, in the same order `find`/`projected_find` themselves produce), plus projected
/// diagnostics when the query was `.projected`.
public struct CorePathSearchQueryResultV1: Sendable, Equatable {
    public let ordinals: [UInt64]
    public let projectedStats: CorePathSearchStatsV1?

    public init(ordinals: [UInt64], projectedStats: CorePathSearchStatsV1?) {
        self.ordinals = ordinals
        self.projectedStats = projectedStats
    }
}

// ---- CoreComputeClient surface ----------------------------------------------------------------

extension CoreComputeClient {
    /// DIFFERENTIAL-ONLY: Rust port of `PathSearchIndex::find`/`projected_find`, batched -- builds
    /// ONE Rust `PathSearchIndex` from `corpusPaths` and runs every query against it in one call.
    /// See this file's top doc for why this is NOT the production shape. Returns one entry per
    /// query, index-aligned with `queries`.
    public func pathSearchFindV1(
        corpusPaths: [String],
        queries: [CorePathSearchQueryV1]
    ) async throws -> [CorePathSearchQueryResultV1] {
        guard !queries.isEmpty else { return [] }
        for query in queries {
            guard query.limit >= 0 else {
                throw CoreComputeError.invalidRequest("limit must be non-negative")
            }
        }

        var builder = CorePathSearchRequestBuilder()
        for path in corpusPaths {
            builder.pushCorpusPath(path)
        }
        let queryModes = queries.map(\.mode)
        for query in queries {
            switch query.mode {
            case .find:
                builder.pushFindQuery(pattern: query.pattern, limit: UInt64(query.limit))
            case let .projected(displayPrefix, absolutePrefix):
                builder.pushProjectedQuery(
                    pattern: query.pattern,
                    limit: UInt64(query.limit),
                    displayPrefix: displayPrefix,
                    absolutePrefix: absolutePrefix
                )
            }
        }
        var request = CoreCompactPathSearchFindRequestV1()
        builder.fill(into: &request)

        return try await performPathSearch(request) { compact in
            try CorePathSearchCompactValidator.decode(compact, queryModes: queryModes, corpusCount: corpusPaths.count)
        }
    }

    /// Shared control-flow template (see `CorePathMatch.swift`'s identically-shaped `perform`
    /// helpers): `prepareComputeOperation()` -> detached transport call with cooperative
    /// cancellation -> fail-closed decode -> `validateComputeCompletion` -> return the decoded,
    /// typed result.
    private func performPathSearch(
        _ request: CoreCompactPathSearchFindRequestV1,
        decode: @Sendable (CoreCompactPathSearchFindResultV1) throws -> [CorePathSearchQueryResultV1]
    ) async throws -> [CorePathSearchQueryResultV1] {
        let context = try await bridge.prepareComputeOperation()
        defer { try? context.transport.closeLeafCancellation(context.cancellation, identity: context.identity) }
        do {
            let compact = try await withTaskCancellationHandler {
                if Task.isCancelled {
                    try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
                    throw CancellationError()
                }
                return try await Task.detached(priority: nil) {
                    try context.transport.pathSearchFindV1(
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
    func pathSearchFindV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactPathSearchFindRequestV1
    ) throws -> CoreCompactPathSearchFindResultV1 {
        throw CoreTransportError.unexpected("path-search compact transport is unavailable")
    }
}

// ---- Compact wire mirrors (bridge-internal) ---------------------------------------------------
//
// Mirrors rust/crates/runtime/src/pathsearch/{contract.rs,wire.rs} exactly: word-table strides
// and the pool-plus-flat-corpus shape. DO NOT change any stride or field order here without a
// matching Rust-side change -- these two sides are validated by
// PathSearchRustSwiftDifferentialTests, not by the type system.

private let corePathSearchContractVersionV1: UInt16 = 1
private let corePathSearchStringRangeStride = 2
private let corePathSearchResultRangeStride = 2
private let corePathSearchStatsStride = 5

struct CoreCompactPathSearchFindRequestV1 {
    var contractVersion: UInt16 = corePathSearchContractVersionV1
    var utf8Blob = Data()
    var stringRangeWords: [UInt64] = []
    var corpusPathIndices: [UInt64] = []
    var queryWords: [UInt64] = []
}

struct CoreCompactPathSearchFindResultV1: Equatable {
    let resultOrdinals: [UInt64]
    let resultRangeWords: [UInt64]
    let statsWords: [UInt64]
}

// ---- encode --------------------------------------------------------------------------------

/// Accumulates the shared string pool + tables for one compact path-search request, mirroring the
/// Rust `PathSearchFindRequestV1::push_string`/`push_corpus_path`/`push_find_query`/
/// `push_projected_query` methods in `wire.rs`. Field/row order below MUST match those exactly.
private struct CorePathSearchRequestBuilder {
    var utf8Blob = Data()
    var stringRangeWords: [UInt64] = []
    var corpusPathIndices: [UInt64] = []
    var queryWords: [UInt64] = []

    mutating func pushString(_ text: String) -> UInt64 {
        let start = UInt64(utf8Blob.count)
        utf8Blob.append(contentsOf: Array(text.utf8))
        let end = UInt64(utf8Blob.count)
        let index = UInt64(stringRangeWords.count / corePathSearchStringRangeStride)
        stringRangeWords.append(start)
        stringRangeWords.append(end)
        return index
    }

    mutating func pushCorpusPath(_ path: String) {
        let idx = pushString(path)
        corpusPathIndices.append(idx)
    }

    /// `mode_flag == 0` -- both projected-prefix pool entries MUST be empty (Rust decode rejects
    /// a find-mode query carrying a non-empty projected prefix).
    mutating func pushFindQuery(pattern: String, limit: UInt64) {
        let patternIdx = pushString(pattern)
        let emptyIdx = pushString("")
        queryWords.append(contentsOf: [patternIdx, limit, 0, emptyIdx, emptyIdx])
    }

    /// `mode_flag == 1`.
    mutating func pushProjectedQuery(
        pattern: String,
        limit: UInt64,
        displayPrefix: String,
        absolutePrefix: String
    ) {
        let patternIdx = pushString(pattern)
        let displayIdx = pushString(displayPrefix)
        let absoluteIdx = pushString(absolutePrefix)
        queryWords.append(contentsOf: [patternIdx, limit, 1, displayIdx, absoluteIdx])
    }

    func fill(into request: inout CoreCompactPathSearchFindRequestV1) {
        request.utf8Blob = utf8Blob
        request.stringRangeWords = stringRangeWords
        request.corpusPathIndices = corpusPathIndices
        request.queryWords = queryWords
    }
}

// ---- decode + fail-closed validation -----------------------------------------------------------

enum CorePathSearchCompactValidator {
    static func decode(
        _ value: CoreCompactPathSearchFindResultV1,
        queryModes: [CorePathSearchQueryModeV1],
        corpusCount: Int
    ) throws -> [CorePathSearchQueryResultV1] {
        let queryCount = queryModes.count
        guard value.resultRangeWords.count == queryCount * corePathSearchResultRangeStride,
              value.statsWords.count == queryCount * corePathSearchStatsStride
        else { throw CoreComputeError.malformedResponse }

        let totalOrdinals = UInt64(value.resultOrdinals.count)
        var results: [CorePathSearchQueryResultV1] = []
        results.reserveCapacity(queryCount)
        var expectedStart: UInt64 = 0

        for queryIndex in 0 ..< queryCount {
            let rangeBase = queryIndex * corePathSearchResultRangeStride
            let start = value.resultRangeWords[rangeBase]
            let count = value.resultRangeWords[rangeBase + 1]
            guard start == expectedStart else { throw CoreComputeError.malformedResponse }
            let (end, overflowed) = start.addingReportingOverflow(count)
            guard !overflowed, end <= totalOrdinals,
                  let startIndex = Int(exactly: start), let endIndex = Int(exactly: end)
            else { throw CoreComputeError.malformedResponse }
            let ordinals = Array(value.resultOrdinals[startIndex ..< endIndex])
            guard ordinals.allSatisfy({ $0 < UInt64(corpusCount) }) else {
                throw CoreComputeError.malformedResponse
            }
            expectedStart = end

            let statsBase = queryIndex * corePathSearchStatsStride
            let statsWords = Array(value.statsWords[statsBase ..< statsBase + corePathSearchStatsStride])
            let projectedStats: CorePathSearchStatsV1?
            switch queryModes[queryIndex] {
            case .find:
                guard statsWords.allSatisfy({ $0 == 0 }) else { throw CoreComputeError.malformedResponse }
                projectedStats = nil
            case .projected:
                projectedStats = CorePathSearchStatsV1(
                    examinedCount: try intWord(statsWords[0]),
                    matchedCount: try intWord(statsWords[1]),
                    heapPeakCount: try intWord(statsWords[2]),
                    heapComparisonCount: try intWord(statsWords[3]),
                    scratchBytes: try intWord(statsWords[4])
                )
            }
            results.append(CorePathSearchQueryResultV1(ordinals: ordinals, projectedStats: projectedStats))
        }
        guard expectedStart == totalOrdinals else { throw CoreComputeError.malformedResponse }
        return results
    }

    private static func intWord(_ value: UInt64) throws -> Int {
        guard let converted = Int(exactly: value) else { throw CoreComputeError.malformedResponse }
        return converted
    }
}
