import Foundation

// ---- Public friendly domain types (P3-3 slice-1 path-match scoring-kernel seam) ---------------
//
// Unlike `CoreInventory.swift`, this seam has no app-level "record" shape to mirror -- the Swift
// scoring kernel (`PathMatcher.computeWeightedMatchScorePrecleaned`) operates purely on ordered
// arrays of path-component strings plus a couple of integers, so the friendly types below ARE the
// wire shape (modulo pooling). See `rust/crates/runtime/src/pathmatch/score.rs`'s module doc for
// the full wire-shape and Foundation/Unicode-cleaning scope-boundary rationale.
//
// IMPORTANT: every component's `text` here MUST already be `PathMatcher.cleaned(_:).lowercased()`
// -- exactly what `computeWeightedMatchScorePrecleaned` produces for its own inputs internally.
// This module does NOT clean or case-fold; that stays Swift-side in the (future) production
// caller, consistent with keeping Foundation/ICU-dependent NFC/case-folding decisions out of the
// Rust kernel.
//
// `characterCount` MUST be `PathMatcher.cleaned(_:).count` -- the Swift EXTENDED GRAPHEME CLUSTER
// count of the CLEANED-BUT-NOT-YET-LOWERCASED component (i.e. computed from the same intermediate
// value `text` was derived from, before `.lowercased()`). This is a third Foundation-dependent
// scope-boundary decision (see `score.rs`'s module doc, point 3): the length-guard inside the
// Rust kernel needs Swift's authoritative grapheme count, which a differential-test fixture proved
// can diverge from Rust's own scalar count for real (non-ASCII) input, so it's carried explicitly
// rather than recomputed Rust-side from `text`.
//
// `cleanedByteLength` MUST be `PathMatcher.cleaned(_:).utf8.count` -- the UTF-8 byte count of that
// SAME CLEANED-BUT-NOT-YET-LOWERCASED intermediate value. This is a fourth Foundation-dependent
// scope-boundary decision (see `score.rs`'s module doc, point 4): lowercasing can change UTF-8
// byte length (e.g. İ U+0130, 2 bytes, lowercases to "i" + COMBINING DOT ABOVE, 3 bytes), so the
// Rust kernel's 256-byte gate needs this PRE-lowering length explicitly -- a differential-test
// fixture proved gating on `text`'s own (post-lowering) byte length diverges from Swift's real
// behavior for real (non-ASCII) input.

/// One already-cleaned, already-lowercased path component plus its Swift-authoritative grapheme
/// count and pre-lowering cleaned UTF-8 byte length. See the file-level doc for exactly how all
/// three fields must be derived.
public struct CorePathMatchComponentV1: Sendable, Equatable {
    public let text: String
    public let characterCount: Int
    public let cleanedByteLength: Int

    public init(text: String, characterCount: Int, cleanedByteLength: Int) {
        self.text = text
        self.characterCount = characterCount
        self.cleanedByteLength = cleanedByteLength
    }

    /// Derives all three wire fields from a single already-cleaned (NFC + homoglyph-folded +
    /// alphanumeric-filtered, e.g. `PathMatcher.cleaned(_:)`) string, so a caller cannot
    /// accidentally source `text`, `characterCount`, and `cleanedByteLength` from three different
    /// intermediate strings. Prefer this initializer at any future production call site; the
    /// three-field initializer above stays available for tests that need to inject deliberate
    /// field mismatches.
    public init(cleaned: String) {
        self.text = cleaned.lowercased()
        self.characterCount = cleaned.count
        self.cleanedByteLength = cleaned.utf8.count
    }
}

public struct CorePathMatchCandidateV1: Sendable, Equatable {
    /// Caller-assigned opaque identifier, round-tripped in the response so callers can map a
    /// match back to their own candidate list without relying on response ordering.
    public let ordinal: UInt64
    /// Caller-assigned opaque identifier for the candidate's root, used to look up the
    /// `selectedRootOrdinals` `+0.5` bonus. Not otherwise meaningful to the kernel.
    public let rootOrdinal: UInt64
    /// The candidate's FULL path-component count (`relativePath.split(separator: "/").count`),
    /// used for the `pathComponents.count >= userComponentsClean.count` guard and the depth
    /// penalty -- NOT `tailComponents.count`, which is capped to the query length.
    public let totalComponentCount: Int
    /// The candidate's LAST `query.count` path components, filename last. May be shorter than
    /// `query.count` (or empty) when `totalComponentCount < query.count`; the kernel rejects those
    /// candidates without reading `tailComponents`.
    public let tailComponents: [CorePathMatchComponentV1]

    public init(
        ordinal: UInt64,
        rootOrdinal: UInt64,
        totalComponentCount: Int,
        tailComponents: [CorePathMatchComponentV1]
    ) {
        self.ordinal = ordinal
        self.rootOrdinal = rootOrdinal
        self.totalComponentCount = totalComponentCount
        self.tailComponents = tailComponents
    }
}

public struct CorePathMatchScoreV1: Sendable, Equatable {
    public let ordinal: UInt64
    /// `round(score * SCORE_SCALE)` -- drift insurance alongside `scoreBits`, not the primary
    /// parity check.
    public let scaledScore: Int64
    /// `score.bitPattern` -- the real parity check: reconstruct via `Double(bitPattern:)` and
    /// assert bit-identical equality against the Swift reference score.
    public let scoreBits: UInt64

    public init(ordinal: UInt64, scaledScore: Int64, scoreBits: UInt64) {
        self.ordinal = ordinal
        self.scaledScore = scaledScore
        self.scoreBits = scoreBits
    }

    public var score: Double { Double(bitPattern: scoreBits) }
}

// ---- CoreComputeClient surface ----------------------------------------------------------------

extension CoreComputeClient {
    /// Rust port of the `PathMatcher` scoring kernel (`computeWeightedMatchScorePrecleaned` +
    /// `similarityScoreMax` + the `fuzzyMatchWithSuffixLimit` selected-root `+0.5` bonus). Scores
    /// `query` against every candidate in one batch call; candidates that don't match (Swift-side
    /// `nil`) are simply absent from the result, in candidate input order otherwise.
    public func pathMatchScoreBatchV1(
        query: [CorePathMatchComponentV1],
        candidates: [CorePathMatchCandidateV1],
        threshold: Double,
        selectedRootOrdinals: Set<UInt64>
    ) async throws -> [CorePathMatchScoreV1] {
        guard threshold.isFinite, threshold >= 0, threshold <= 1 else {
            throw CoreComputeError.invalidRequest("threshold must be within [0, 1]")
        }
        guard !candidates.isEmpty else { return [] }

        var builder = CorePathMatchRequestBuilder()
        var request = CoreCompactPathMatchRequestV1(threshold: threshold)
        request.queryIndices = builder.pushQuery(query)
        for candidate in candidates {
            builder.pushCandidate(
                rootOrdinal: candidate.rootOrdinal,
                totalComponentCount: candidate.totalComponentCount,
                tailComponents: candidate.tailComponents,
                ordinal: candidate.ordinal
            )
        }
        request.selectedRootOrdinals = Array(selectedRootOrdinals)
        builder.fill(into: &request)

        return try await perform(request) { compact in
            try CorePathMatchCompactValidator.decode(compact)
        }
    }

    /// Shared control-flow template (see `CoreInventory.swift`'s identically-named helper):
    /// `prepareComputeOperation()` -> detached transport call with cooperative cancellation ->
    /// fail-closed decode -> `validateComputeCompletion` -> return the decoded, typed result.
    private func perform(
        _ request: CoreCompactPathMatchRequestV1,
        decode: @Sendable (CoreCompactPathMatchResultV1) throws -> [CorePathMatchScoreV1]
    ) async throws -> [CorePathMatchScoreV1] {
        let context = try await bridge.prepareComputeOperation()
        defer { try? context.transport.closeLeafCancellation(context.cancellation, identity: context.identity) }
        do {
            let compact = try await withTaskCancellationHandler {
                if Task.isCancelled {
                    try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
                    throw CancellationError()
                }
                return try await Task.detached(priority: nil) {
                    try context.transport.pathMatchScoreBatchV1(
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
    func pathMatchScoreBatchV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactPathMatchRequestV1
    ) throws -> CoreCompactPathMatchResultV1 {
        throw CoreTransportError.unexpected("path-match score compact transport is unavailable")
    }
}

// ---- Compact wire mirrors (bridge-internal) ---------------------------------------------------
//
// Mirrors `rust/crates/runtime/src/pathmatch/contract.rs` / `score.rs` exactly: word-table
// strides and the pool-plus-ranges shape. DO NOT change any stride or field order here without a
// matching Rust-side change -- these two sides are validated by
// `PathMatchRustSwiftDifferentialTests`, not by the type system.

private let corePathMatchContractVersionV1: UInt16 = 1
private let corePathMatchStringRangeStride = 2

struct CoreCompactPathMatchRequestV1 {
    var contractVersion: UInt16 = corePathMatchContractVersionV1
    var threshold: Double

    var utf8Blob = Data()
    var stringRangeWords: [UInt64] = []
    var charCountWords: [UInt64] = []
    var cleanedByteLenWords: [UInt64] = []

    var queryIndices: [UInt64] = []

    var candidateWords: [UInt64] = []
    var candidateTailIndices: [UInt64] = []

    var selectedRootOrdinals: [UInt64] = []

    init(threshold: Double) {
        self.threshold = threshold
    }
}

struct CoreCompactPathMatchResultV1: Equatable {
    let matchedOrdinals: [UInt64]
    let matchedScoresScaled: [Int64]
    let matchedScoresBits: [UInt64]
}

// ---- encode --------------------------------------------------------------------------------

/// Accumulates the shared string pool for one compact path-match request, mirroring the Rust
/// `PathMatchScoreRequestV1::push_string` / `push_query` / `push_candidate` methods in `score.rs`.
/// Field/row order below MUST match those exactly.
private struct CorePathMatchRequestBuilder {
    var utf8Blob = Data()
    var stringRangeWords: [UInt64] = []
    var charCountWords: [UInt64] = []
    var cleanedByteLenWords: [UInt64] = []
    var candidateWords: [UInt64] = []
    var candidateTailIndices: [UInt64] = []

    mutating func pushString(_ component: CorePathMatchComponentV1) -> UInt64 {
        let start = UInt64(utf8Blob.count)
        utf8Blob.append(contentsOf: Array(component.text.utf8))
        let end = UInt64(utf8Blob.count)
        let index = UInt64(stringRangeWords.count / corePathMatchStringRangeStride)
        stringRangeWords.append(start)
        stringRangeWords.append(end)
        charCountWords.append(UInt64(component.characterCount))
        cleanedByteLenWords.append(UInt64(component.cleanedByteLength))
        return index
    }

    mutating func pushQuery(_ components: [CorePathMatchComponentV1]) -> [UInt64] {
        components.map { pushString($0) }
    }

    mutating func pushCandidate(
        rootOrdinal: UInt64,
        totalComponentCount: Int,
        tailComponents: [CorePathMatchComponentV1],
        ordinal: UInt64
    ) {
        let tailStart = UInt64(candidateTailIndices.count)
        for component in tailComponents {
            candidateTailIndices.append(pushString(component))
        }
        let tailCount = UInt64(candidateTailIndices.count) - tailStart
        candidateWords.append(contentsOf: [
            rootOrdinal,
            UInt64(totalComponentCount),
            tailStart,
            tailCount,
            ordinal,
        ])
    }

    /// Copies every accumulated pool into `request`, leaving `queryIndices`/`selectedRootOrdinals`
    /// (already assigned by the caller) untouched.
    func fill(into request: inout CoreCompactPathMatchRequestV1) {
        request.utf8Blob = utf8Blob
        request.stringRangeWords = stringRangeWords
        request.charCountWords = charCountWords
        request.cleanedByteLenWords = cleanedByteLenWords
        request.candidateWords = candidateWords
        request.candidateTailIndices = candidateTailIndices
    }
}

// ---- decode + fail-closed validation ---------------------------------------------------------

enum CorePathMatchCompactValidator {
    static func decode(_ value: CoreCompactPathMatchResultV1) throws -> [CorePathMatchScoreV1] {
        guard value.matchedOrdinals.count == value.matchedScoresScaled.count,
              value.matchedOrdinals.count == value.matchedScoresBits.count
        else { throw CoreComputeError.malformedResponse }
        return (0 ..< value.matchedOrdinals.count).map { index in
            CorePathMatchScoreV1(
                ordinal: value.matchedOrdinals[index],
                scaledScore: value.matchedScoresScaled[index],
                scoreBits: value.matchedScoresBits[index]
            )
        }
    }
}
