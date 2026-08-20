import Foundation

public struct CoreByteRange: Sendable, Equatable, Hashable {
    public let start: UInt64
    public let end: UInt64

    public init(start: UInt64, end: UInt64) {
        self.start = start
        self.end = end
    }
}

public enum CoreRegexSearchMode: Sendable, Equatable {
    case content
    case path
}

public enum CoreMatchPolicy: Sendable, Equatable {
    case contentFullBuffer
    case contentLine
    case shortPath
}

public enum CoreLimitPolicy: Sendable, Equatable {
    case fileSearchFullBuffer
    case fileSearchLine
    case pathSearchShortSubject
}

public enum CoreRepairKind: Sendable, Equatable {
    case none
    case doubleEscapeCompression
    case normalise
    case normaliseThenCompression
}

public enum CoreSearchEngine: Sendable, Equatable {
    case asciiWholeWord
    case anchoredDeclaration
    case asciiMarker
    case pathSuffix
    case anchoredLinePrefilter
    case pcre2
}

public enum CoreJITStatus: Sendable, Equatable {
    case notApplicable
    case active
    case pcre2InterpreterFallback
}

public enum CoreLimitFailure: Sendable, Equatable {
    case match
    case depth
    case heap
}

public struct CoreRegexDiagnostic: Sendable, Equatable {
    public let engine: CoreSearchEngine
    public let jitStatus: CoreJITStatus
    public let cacheHit: Bool
    public let repairKind: CoreRepairKind
    public let limitPolicy: CoreLimitPolicy
    public let subjectByteCount: UInt64
    public let lineCount: UInt64
    public let hitCount: UInt64
    public let matchingLineCount: UInt64
    public let cancelled: Bool
    public let limitFailure: CoreLimitFailure?

    public init(
        engine: CoreSearchEngine,
        jitStatus: CoreJITStatus,
        cacheHit: Bool,
        repairKind: CoreRepairKind,
        limitPolicy: CoreLimitPolicy,
        subjectByteCount: UInt64,
        lineCount: UInt64,
        hitCount: UInt64,
        matchingLineCount: UInt64,
        cancelled: Bool,
        limitFailure: CoreLimitFailure?
    ) {
        self.engine = engine
        self.jitStatus = jitStatus
        self.cacheHit = cacheHit
        self.repairKind = repairKind
        self.limitPolicy = limitPolicy
        self.subjectByteCount = subjectByteCount
        self.lineCount = lineCount
        self.hitCount = hitCount
        self.matchingLineCount = matchingLineCount
        self.cancelled = cancelled
        self.limitFailure = limitFailure
    }
}

public struct CoreRegexSearchRequest: Sendable, Equatable {
    public let mode: CoreRegexSearchMode
    public let pattern: String
    public let subject: String
    public let caseInsensitive: Bool
    public let wholeWord: Bool
    public let multilineAnchors: Bool
    public let collectMatches: Bool
    public let maxCollectedMatches: UInt32?
    public let contextLines: UInt16
    public let matchPolicy: CoreMatchPolicy

    public init(
        mode: CoreRegexSearchMode = .content,
        pattern: String,
        subject: String,
        caseInsensitive: Bool = false,
        wholeWord: Bool = false,
        multilineAnchors: Bool = false,
        collectMatches: Bool = true,
        maxCollectedMatches: UInt32? = nil,
        contextLines: UInt16 = 0,
        matchPolicy: CoreMatchPolicy = .contentFullBuffer
    ) {
        self.mode = mode
        self.pattern = pattern
        self.subject = subject
        self.caseInsensitive = caseInsensitive
        self.wholeWord = wholeWord
        self.multilineAnchors = multilineAnchors
        self.collectMatches = collectMatches
        self.maxCollectedMatches = maxCollectedMatches
        self.contextLines = contextLines
        self.matchPolicy = matchPolicy
    }
}

public struct CoreRegexLineHit: Sendable, Equatable {
    public let lineNumber: UInt32
    public let lineByteRange: CoreByteRange
    public let matchByteRange: CoreByteRange
    public let contextBeforeByteRanges: [CoreByteRange]
    public let contextAfterByteRanges: [CoreByteRange]

    public init(
        lineNumber: UInt32,
        lineByteRange: CoreByteRange,
        matchByteRange: CoreByteRange,
        contextBeforeByteRanges: [CoreByteRange],
        contextAfterByteRanges: [CoreByteRange]
    ) {
        self.lineNumber = lineNumber
        self.lineByteRange = lineByteRange
        self.matchByteRange = matchByteRange
        self.contextBeforeByteRanges = contextBeforeByteRanges
        self.contextAfterByteRanges = contextAfterByteRanges
    }
}

public struct CoreRegexSearchResult: Sendable, Equatable {
    public let hits: [CoreRegexLineHit]
    public let matchingLineCount: UInt64
    public let cancelled: Bool
    public let diagnostic: CoreRegexDiagnostic

    public init(
        hits: [CoreRegexLineHit],
        matchingLineCount: UInt64,
        cancelled: Bool,
        diagnostic: CoreRegexDiagnostic
    ) {
        self.hits = hits
        self.matchingLineCount = matchingLineCount
        self.cancelled = cancelled
        self.diagnostic = diagnostic
    }
}

public struct CorePathSnapshot: Sendable, Equatable {
    public let standardizedFullPath: String
    public let standardizedRelativePath: String
    public let standardizedRootPath: String
    public let clientDisplayPath: String

    public init(
        standardizedFullPath: String,
        standardizedRelativePath: String,
        standardizedRootPath: String,
        clientDisplayPath: String
    ) {
        self.standardizedFullPath = standardizedFullPath
        self.standardizedRelativePath = standardizedRelativePath
        self.standardizedRootPath = standardizedRootPath
        self.clientDisplayPath = clientDisplayPath
    }
}

public enum CorePathClause: Sendable, Equatable {
    case exactFile(absPath: String, relPath: String, restrictedRootPath: String?)
    case exactFolder(absLower: String, relLower: String, restrictedRootPath: String?)
    case glob(pattern: String, restrictedRootPath: String?)
    case legacyPrefix(candidateLower: String)
}

public struct CorePathFilterRequest: Sendable, Equatable {
    public let snapshots: [CorePathSnapshot]
    public let clauses: [CorePathClause]
    public let caseInsensitive: Bool

    public init(
        snapshots: [CorePathSnapshot],
        clauses: [CorePathClause],
        caseInsensitive: Bool = false
    ) {
        self.snapshots = snapshots
        self.clauses = clauses
        self.caseInsensitive = caseInsensitive
    }
}

public struct CorePathDiagnostic: Sendable, Equatable {
    public let visitedSnapshotCount: UInt64
    public let matchedSnapshotCount: UInt64
    public let cancelled: Bool

    public init(visitedSnapshotCount: UInt64, matchedSnapshotCount: UInt64, cancelled: Bool) {
        self.visitedSnapshotCount = visitedSnapshotCount
        self.matchedSnapshotCount = matchedSnapshotCount
        self.cancelled = cancelled
    }
}

public struct CorePathFilterResult: Sendable, Equatable {
    public let matchedSnapshotIndices: [UInt32]
    public let visitedSnapshotCount: UInt64
    public let cancelled: Bool
    public let diagnostic: CorePathDiagnostic

    public init(
        matchedSnapshotIndices: [UInt32],
        visitedSnapshotCount: UInt64,
        cancelled: Bool,
        diagnostic: CorePathDiagnostic
    ) {
        self.matchedSnapshotIndices = matchedSnapshotIndices
        self.visitedSnapshotCount = visitedSnapshotCount
        self.cancelled = cancelled
        self.diagnostic = diagnostic
    }
}

public struct CoreFolderSuffixRequest: Sendable, Equatable {
    public let fragment: String
    public let relativePaths: [String]
    public let caseInsensitive: Bool

    public init(fragment: String, relativePaths: [String], caseInsensitive: Bool = false) {
        self.fragment = fragment
        self.relativePaths = relativePaths
        self.caseInsensitive = caseInsensitive
    }
}

public enum CoreInvalidPatternReason: Sendable, Equatable {
    case invalidEscape
    case unmatchedBrackets
    case unmatchedParentheses
    case invalidQuantifier
    case variableLengthLookbehind
    case other
}

public enum CoreSearchError: Error, Sendable, Equatable {
    case invalidPattern(CoreInvalidPatternReason)
    case patternTooComplex
    case matchLimitExceeded
    case depthLimitExceeded
    case heapLimitExceeded
    case jitUnavailable
    case cancelled
    case runtimeInvalidated
    case runtimeStopped
    case runtimePoisoned
    case malformedRange
    case transportFailure(String)
}

extension CoreSearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPattern: "The search pattern is invalid."
        case .patternTooComplex: "The search pattern is too complex."
        case .matchLimitExceeded: "The regex match limit was exceeded."
        case .depthLimitExceeded: "The regex depth limit was exceeded."
        case .heapLimitExceeded: "The regex heap limit was exceeded."
        case .jitUnavailable: "PCRE2 JIT is unavailable."
        case .cancelled: "The search was cancelled."
        case .runtimeInvalidated: "The Rust runtime was invalidated."
        case .runtimeStopped: "The Rust runtime is stopped."
        case .runtimePoisoned: "The Rust runtime is poisoned."
        case .malformedRange: "The Rust search result contained an invalid UTF-8 byte range."
        case let .transportFailure(message): "Rust search transport failed: \(message)"
        }
    }
}

protocol CoreLeafCancellationHandle: AnyObject, Sendable {}

struct CoreSearchOperationContext: Sendable {
    let transport: any CoreRuntimeTransport
    let identity: CoreRuntimeIdentity
    let cancellation: any CoreLeafCancellationHandle
}

public struct CoreSearchClient: Sendable {
    private let bridge: AgentryCoreBridge

    init(bridge: AgentryCoreBridge) {
        self.bridge = bridge
    }

    public func searchRegex(_ request: CoreRegexSearchRequest) async throws -> CoreRegexSearchResult {
        let context = try await bridge.prepareSearchOperation()
        defer { try? context.transport.closeLeafCancellation(context.cancellation, identity: context.identity) }
        do {
            let result = try await withTaskCancellationHandler {
                if Task.isCancelled {
                    try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
                    throw CancellationError()
                }
                return try await Task.detached(priority: nil) {
                    try context.transport.searchRegex(
                        identity: context.identity,
                        cancellation: context.cancellation,
                        request: request
                    )
                }.value
            } onCancel: {
                try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
            }
            if Task.isCancelled || result.cancelled {
                throw CancellationError()
            }
            try Self.validate(result, subject: request.subject)
            try context.transport.closeLeafCancellation(context.cancellation, identity: context.identity)
            try await bridge.validateSearchCompletion(identity: context.identity)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await bridge.mapSearchFailure(error)
        }
    }

    public func filterPaths(_ request: CorePathFilterRequest) async throws -> CorePathFilterResult {
        let context = try await bridge.prepareSearchOperation()
        defer { try? context.transport.closeLeafCancellation(context.cancellation, identity: context.identity) }
        do {
            let result = try await withTaskCancellationHandler {
                if Task.isCancelled {
                    try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
                }
                return try await Task.detached(priority: nil) {
                    try context.transport.filterPaths(
                        identity: context.identity,
                        cancellation: context.cancellation,
                        request: request
                    )
                }.value
            } onCancel: {
                try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
            }
            try Self.validate(result, snapshotCount: request.snapshots.count)
            try context.transport.closeLeafCancellation(context.cancellation, identity: context.identity)
            try await bridge.validateSearchCompletion(identity: context.identity)
            return result
        } catch {
            throw await bridge.mapSearchFailure(error)
        }
    }

    public func folderSuffixIndices(_ request: CoreFolderSuffixRequest) async throws -> [UInt32] {
        let context = try await bridge.prepareSearchOperation()
        defer { try? context.transport.closeLeafCancellation(context.cancellation, identity: context.identity) }
        do {
            let indices = try await withTaskCancellationHandler {
                if Task.isCancelled {
                    try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
                }
                return try await Task.detached(priority: nil) {
                    try context.transport.folderSuffixIndices(
                        identity: context.identity,
                        cancellation: context.cancellation,
                        request: request
                    )
                }.value
            } onCancel: {
                try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
            }
            guard indices.allSatisfy({ Int($0) < request.relativePaths.count }),
                  zip(indices, indices.dropFirst()).allSatisfy({ $0 < $1 })
            else {
                throw CoreSearchError.malformedRange
            }
            try context.transport.closeLeafCancellation(context.cancellation, identity: context.identity)
            try await bridge.validateSearchCompletion(identity: context.identity)
            return indices
        } catch {
            throw await bridge.mapSearchFailure(error)
        }
    }

    private static func validate(_ result: CoreRegexSearchResult, subject: String) throws {
        let ranges = result.hits.flatMap {
            [$0.lineByteRange, $0.matchByteRange]
                + $0.contextBeforeByteRanges
                + $0.contextAfterByteRanges
        }
        guard ranges.allSatisfy({ valid($0, in: subject) }),
              zip(result.hits, result.hits.dropFirst()).allSatisfy({ $0.lineNumber < $1.lineNumber }),
              result.diagnostic.hitCount == UInt64(result.hits.count),
              result.diagnostic.matchingLineCount == result.matchingLineCount
        else {
            throw CoreSearchError.malformedRange
        }
    }

    private static func valid(_ range: CoreByteRange, in subject: String) -> Bool {
        guard range.start <= range.end,
              let start = Int(exactly: range.start),
              let end = Int(exactly: range.end),
              end <= subject.utf8.count
        else {
            return false
        }
        let utf8 = subject.utf8
        let startIndex = utf8.index(utf8.startIndex, offsetBy: start)
        let endIndex = utf8.index(utf8.startIndex, offsetBy: end)
        return startIndex.samePosition(in: subject) != nil && endIndex.samePosition(in: subject) != nil
    }

    private static func validate(_ result: CorePathFilterResult, snapshotCount: Int) throws {
        guard result.matchedSnapshotIndices.allSatisfy({ Int($0) < snapshotCount }),
              zip(result.matchedSnapshotIndices, result.matchedSnapshotIndices.dropFirst())
              .allSatisfy({ $0 < $1 }),
              result.visitedSnapshotCount <= UInt64(snapshotCount),
              result.diagnostic.visitedSnapshotCount == result.visitedSnapshotCount,
              result.diagnostic.matchedSnapshotCount == UInt64(result.matchedSnapshotIndices.count),
              result.diagnostic.cancelled == result.cancelled
        else {
            throw CoreSearchError.malformedRange
        }
    }
}
