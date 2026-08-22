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

// ---- Public friendly domain types (P3-3 slice-2a resolution-pipeline seam) --------------------
//
// Unlike the scoring-kernel types above, this seam mirrors an entire PathMatchSnapshot (roots +
// files + folders + candidate-bucket source text) plus a batch of queries -- see
// rust/crates/runtime/src/pathmatch/indexes.rs's module doc for the full wire shape and the
// three Foundation/ICU/filesystem boundary decisions this port draws. Every field documented
// below as "canonical" or "cleaned" MUST be produced by calling the REAL production functions
// (PathMatchIndexes.canonical, PathMatcher.cleaned, StandardizedPath.absolute, NSString's
// pathExtension.lowercased()) -- this module does not reimplement them, exactly like the
// scoring-kernel seam above.

/// One root folder. `fullPath`/`name` are RAW (uncleaned) text -- see the module doc's boundary
/// note 3 (ASCII-fold-approximated root-alias matching happens Rust-side on this raw text).
public struct CorePathMatchResolveRootV1: Sendable, Equatable {
    public let fullPath: String
    public let name: String

    public init(fullPath: String, name: String) {
        self.fullPath = fullPath
        self.name = name
    }
}

/// One file record. `fullPath`/`relativePath` are RAW (uncleaned) text; `nameCanonical` MUST be
/// PathMatchIndexes.canonical(name, caseSensitive: <snapshot policy>); `ext` MUST be the
/// lowercased NSString pathExtension of `name` (empty when absent); `lastTwoCanonical` MUST be
/// the canonical form of the last two relative-path components joined by a slash (canonicalized
/// as ONE joined string, matching PathMatchIndexes.byLastTwo's key) when the relative path has at
/// least two components, else an empty string; `components` MUST be each RAW relative-path
/// component's CorePathMatchComponentV1(cleaned: PathMatcher.cleaned(component)), forward order.
public struct CorePathMatchResolveFileV1: Sendable, Equatable {
    public let fullPath: String
    public let relativePath: String
    public let rootOrdinal: UInt64
    public let nameCanonical: String
    public let ext: String
    public let lastTwoCanonical: String
    public let components: [CorePathMatchComponentV1]

    public init(
        fullPath: String,
        relativePath: String,
        rootOrdinal: UInt64,
        nameCanonical: String,
        ext: String,
        lastTwoCanonical: String,
        components: [CorePathMatchComponentV1]
    ) {
        self.fullPath = fullPath
        self.relativePath = relativePath
        self.rootOrdinal = rootOrdinal
        self.nameCanonical = nameCanonical
        self.ext = ext
        self.lastTwoCanonical = lastTwoCanonical
        self.components = components
    }
}

/// One folder record. Same shape as CorePathMatchResolveFileV1 minus `ext`/`lastTwoCanonical`
/// (Swift's PathMatchIndexes.build never indexes folders by extension or last-two-components).
public struct CorePathMatchResolveFolderV1: Sendable, Equatable {
    public let fullPath: String
    public let relativePath: String
    public let rootOrdinal: UInt64
    public let nameCanonical: String
    public let components: [CorePathMatchComponentV1]

    public init(
        fullPath: String,
        relativePath: String,
        rootOrdinal: UInt64,
        nameCanonical: String,
        components: [CorePathMatchComponentV1]
    ) {
        self.fullPath = fullPath
        self.relativePath = relativePath
        self.rootOrdinal = rootOrdinal
        self.nameCanonical = nameCanonical
        self.components = components
    }
}

/// One query. `standardizedPath` MUST be StandardizedPath.absolute applied to
/// PathCharPolicy.foldHomoglyphsIfNeeded applied to the trimmed user path -- exactly
/// PathMatcher.locate's own first few lines (see resolve.rs's module doc for why this is the
/// ONLY Foundation-touching step the wire needs per query). `canonicalComponents`/
/// `cleanedLowerComponents` MUST be index-aligned, one pair per RAW component of splitting
/// `standardizedPath` on "/" (trimming leading/trailing "/" first, omitting empty components,
/// exactly like PathMatcher.locate's own userComponents split) --
/// PathMatchIndexes.canonical(component, caseSensitive:) and
/// CorePathMatchComponentV1(cleaned: PathMatcher.cleaned(component)) respectively.
public struct CorePathMatchResolveQueryV1: Sendable, Equatable {
    public let standardizedPath: String
    public let canonicalComponents: [String]
    public let cleanedLowerComponents: [CorePathMatchComponentV1]

    public init(
        standardizedPath: String,
        canonicalComponents: [String],
        cleanedLowerComponents: [CorePathMatchComponentV1]
    ) {
        self.standardizedPath = standardizedPath
        self.canonicalComponents = canonicalComponents
        self.cleanedLowerComponents = cleanedLowerComponents
    }
}

public struct CorePathMatchResolveLocationV1: Sendable, Equatable {
    public let rootOrdinal: UInt64
    public let correctedPath: String

    public init(rootOrdinal: UInt64, correctedPath: String) {
        self.rootOrdinal = rootOrdinal
        self.correctedPath = correctedPath
    }
}

// ---- CoreComputeClient surface ----------------------------------------------------------------

extension CoreComputeClient {
    /// Rust port of the full PathMatcher.locate resolution ladder, batched exactly like
    /// PathMatchWorker.locateMany's single shared PathLocateOptions-derived policy over one
    /// immutable snapshot. Returns one entry per query, index-aligned, nil for "no match"
    /// (mirrors PathMatchLocation?).
    public func pathMatchLocateManyBatchV1(
        caseSensitive: Bool,
        exactMatchOnly: Bool,
        allowLeadingRootAliasTrim: Bool,
        allowHeadTrimAliases: Bool,
        allowAbsoluteSuffixFallback: Bool,
        roots: [CorePathMatchResolveRootV1],
        files: [CorePathMatchResolveFileV1],
        folders: [CorePathMatchResolveFolderV1],
        selectedFileFullPaths: [String],
        queries: [CorePathMatchResolveQueryV1]
    ) async throws -> [CorePathMatchResolveLocationV1?] {
        guard !queries.isEmpty else { return [] }

        var builder = CorePathMatchResolveRequestBuilder()
        var request = CoreCompactPathMatchResolveRequestV1(
            caseSensitive: caseSensitive,
            exactMatchOnly: exactMatchOnly,
            allowLeadingRootAliasTrim: allowLeadingRootAliasTrim,
            allowHeadTrimAliases: allowHeadTrimAliases,
            allowAbsoluteSuffixFallback: allowAbsoluteSuffixFallback
        )
        for root in roots {
            builder.pushRoot(root)
        }
        for file in files {
            builder.pushFile(file)
        }
        for folder in folders {
            builder.pushFolder(folder)
        }
        for path in selectedFileFullPaths {
            builder.pushSelectedFileFullPath(path)
        }
        for query in queries {
            builder.pushQuery(query)
        }
        builder.fill(into: &request)

        return try await performResolve(request) { compact in
            CorePathMatchResolveCompactValidator.decode(compact)
        }
    }

    private func performResolve(
        _ request: CoreCompactPathMatchResolveRequestV1,
        decode: @Sendable (CoreCompactPathMatchResolveResultV1) -> [CorePathMatchResolveLocationV1?]
    ) async throws -> [CorePathMatchResolveLocationV1?] {
        let context = try await bridge.prepareComputeOperation()
        defer { try? context.transport.closeLeafCancellation(context.cancellation, identity: context.identity) }
        do {
            let compact = try await withTaskCancellationHandler {
                if Task.isCancelled {
                    try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
                    throw CancellationError()
                }
                return try await Task.detached(priority: nil) {
                    try context.transport.pathMatchLocateManyBatchV1(
                        identity: context.identity,
                        cancellation: context.cancellation,
                        request: request
                    )
                }.value
            } onCancel: {
                try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
            }
            if Task.isCancelled { throw CancellationError() }
            let decoded = decode(compact)
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
    func pathMatchLocateManyBatchV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactPathMatchResolveRequestV1
    ) throws -> CoreCompactPathMatchResolveResultV1 {
        throw CoreTransportError.unexpected("path-resolve compact transport is unavailable")
    }
}

// ---- Compact wire mirrors (bridge-internal) ---------------------------------------------------
//
// Mirrors rust/crates/runtime/src/pathmatch/{contract.rs,indexes.rs} exactly: word-table strides
// and the pool-plus-tables shape. DO NOT change any stride or field order here without a matching
// Rust-side change -- these two sides are validated by PathMatchRustSwiftDifferentialTests, not
// by the type system.

private let corePathMatchResolveContractVersionV1: UInt16 = 1

struct CoreCompactPathMatchResolveRequestV1 {
    var contractVersion: UInt16 = corePathMatchResolveContractVersionV1
    var caseSensitive: Bool
    var exactMatchOnly: Bool
    var allowLeadingRootAliasTrim: Bool
    var allowHeadTrimAliases: Bool
    var allowAbsoluteSuffixFallback: Bool

    var utf8Blob = Data()
    var stringRangeWords: [UInt64] = []
    var charCountWords: [UInt64] = []
    var cleanedByteLenWords: [UInt64] = []

    var rootWords: [UInt64] = []
    var fileWords: [UInt64] = []
    var folderWords: [UInt64] = []
    var componentIndices: [UInt64] = []

    var selectedFileFullPathIndices: [UInt64] = []

    var queryWords: [UInt64] = []
    var queryCanonicalComponentIndices: [UInt64] = []
    var queryCleanedLowerComponentIndices: [UInt64] = []

    init(
        caseSensitive: Bool,
        exactMatchOnly: Bool,
        allowLeadingRootAliasTrim: Bool,
        allowHeadTrimAliases: Bool,
        allowAbsoluteSuffixFallback: Bool
    ) {
        self.caseSensitive = caseSensitive
        self.exactMatchOnly = exactMatchOnly
        self.allowLeadingRootAliasTrim = allowLeadingRootAliasTrim
        self.allowHeadTrimAliases = allowHeadTrimAliases
        self.allowAbsoluteSuffixFallback = allowAbsoluteSuffixFallback
    }
}

struct CoreCompactPathMatchResolveResultV1: Equatable {
    let locations: [CorePathMatchResolveLocationV1?]
}

// ---- encode --------------------------------------------------------------------------------

/// Accumulates the shared string pool + tables for one compact path-resolve request, mirroring
/// the Rust PathMatchResolveRequestV1 push_string/push_root/push_file/push_folder/push_query
/// methods in indexes.rs. Field/row order below MUST match those exactly.
private struct CorePathMatchResolveRequestBuilder {
    var utf8Blob = Data()
    var stringRangeWords: [UInt64] = []
    var charCountWords: [UInt64] = []
    var cleanedByteLenWords: [UInt64] = []
    var rootWords: [UInt64] = []
    var fileWords: [UInt64] = []
    var folderWords: [UInt64] = []
    var componentIndices: [UInt64] = []
    var selectedFileFullPathIndices: [UInt64] = []
    var queryWords: [UInt64] = []
    var queryCanonicalComponentIndices: [UInt64] = []
    var queryCleanedLowerComponentIndices: [UInt64] = []

    mutating func pushString(text: String, characterCount: Int, cleanedByteLength: Int) -> UInt64 {
        let start = UInt64(utf8Blob.count)
        utf8Blob.append(contentsOf: Array(text.utf8))
        let end = UInt64(utf8Blob.count)
        let index = UInt64(stringRangeWords.count / corePathMatchStringRangeStride)
        stringRangeWords.append(start)
        stringRangeWords.append(end)
        charCountWords.append(UInt64(characterCount))
        cleanedByteLenWords.append(UInt64(cleanedByteLength))
        return index
    }

    mutating func pushPlainString(_ text: String) -> UInt64 {
        pushString(text: text, characterCount: text.count, cleanedByteLength: text.utf8.count)
    }

    mutating func pushComponent(_ component: CorePathMatchComponentV1) -> UInt64 {
        pushString(text: component.text, characterCount: component.characterCount, cleanedByteLength: component.cleanedByteLength)
    }

    mutating func pushRoot(_ root: CorePathMatchResolveRootV1) {
        let fullPathIdx = pushPlainString(root.fullPath)
        let nameIdx = pushPlainString(root.name)
        rootWords.append(contentsOf: [fullPathIdx, nameIdx])
    }

    mutating func pushFile(_ file: CorePathMatchResolveFileV1) {
        let fullPathIdx = pushPlainString(file.fullPath)
        let relativePathIdx = pushPlainString(file.relativePath)
        let nameCanonicalIdx = pushPlainString(file.nameCanonical)
        let extIdx = pushPlainString(file.ext)
        let lastTwoCanonicalIdx = pushPlainString(file.lastTwoCanonical)
        let componentStart = UInt64(componentIndices.count)
        for component in file.components {
            componentIndices.append(pushComponent(component))
        }
        let componentCount = UInt64(componentIndices.count) - componentStart
        fileWords.append(contentsOf: [
            fullPathIdx,
            relativePathIdx,
            file.rootOrdinal,
            nameCanonicalIdx,
            extIdx,
            lastTwoCanonicalIdx,
            componentStart,
            componentCount,
        ])
    }

    mutating func pushFolder(_ folder: CorePathMatchResolveFolderV1) {
        let fullPathIdx = pushPlainString(folder.fullPath)
        let relativePathIdx = pushPlainString(folder.relativePath)
        let nameCanonicalIdx = pushPlainString(folder.nameCanonical)
        let componentStart = UInt64(componentIndices.count)
        for component in folder.components {
            componentIndices.append(pushComponent(component))
        }
        let componentCount = UInt64(componentIndices.count) - componentStart
        folderWords.append(contentsOf: [
            fullPathIdx,
            relativePathIdx,
            folder.rootOrdinal,
            nameCanonicalIdx,
            componentStart,
            componentCount,
        ])
    }

    mutating func pushSelectedFileFullPath(_ path: String) {
        selectedFileFullPathIndices.append(pushPlainString(path))
    }

    mutating func pushQuery(_ query: CorePathMatchResolveQueryV1) {
        let standardizedPathIdx = pushPlainString(query.standardizedPath)
        let canonicalStart = UInt64(queryCanonicalComponentIndices.count)
        for component in query.canonicalComponents {
            queryCanonicalComponentIndices.append(pushPlainString(component))
        }
        let componentCount = UInt64(queryCanonicalComponentIndices.count) - canonicalStart
        let cleanedLowerStart = UInt64(queryCleanedLowerComponentIndices.count)
        for component in query.cleanedLowerComponents {
            queryCleanedLowerComponentIndices.append(pushComponent(component))
        }
        queryWords.append(contentsOf: [standardizedPathIdx, canonicalStart, componentCount, cleanedLowerStart])
    }

    func fill(into request: inout CoreCompactPathMatchResolveRequestV1) {
        request.utf8Blob = utf8Blob
        request.stringRangeWords = stringRangeWords
        request.charCountWords = charCountWords
        request.cleanedByteLenWords = cleanedByteLenWords
        request.rootWords = rootWords
        request.fileWords = fileWords
        request.folderWords = folderWords
        request.componentIndices = componentIndices
        request.selectedFileFullPathIndices = selectedFileFullPathIndices
        request.queryWords = queryWords
        request.queryCanonicalComponentIndices = queryCanonicalComponentIndices
        request.queryCleanedLowerComponentIndices = queryCleanedLowerComponentIndices
    }
}

// ---- decode -----------------------------------------------------------------------------------

enum CorePathMatchResolveCompactValidator {
    static func decode(_ value: CoreCompactPathMatchResolveResultV1) -> [CorePathMatchResolveLocationV1?] {
        value.locations
    }
}
