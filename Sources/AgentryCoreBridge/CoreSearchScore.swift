import Foundation

/// One search-score input row. Original and lowercased strings remain separate because the
/// caller-supplied lowercase representation is part of the legacy scorer contract.
public struct CoreSearchScoreCandidateV1: Sendable, Equatable {
    public let name: String
    public let path: String
    public let nameLower: String
    public let pathLower: String

    public init(name: String, path: String, nameLower: String, pathLower: String) {
        self.name = name
        self.path = path
        self.nameLower = nameLower
        self.pathLower = pathLower
    }
}

/// Query facts prepared by the product layer. Rust does not lowercase or infer wildcard/slash
/// state again, so the byte-visible legacy contract has one authority.
public struct CoreSearchScoreQueryV1: Sendable, Equatable {
    public let raw: String
    public let lowered: String
    public let hasSlash: Bool
    public let isWildcard: Bool

    public init(raw: String, lowered: String, hasSlash: Bool, isWildcard: Bool) {
        self.raw = raw
        self.lowered = lowered
        self.hasSlash = hasSlash
        self.isWildcard = isWildcard
    }
}

public struct CoreSearchScoreBatchRequestV1: Sendable, Equatable {
    public static let contractVersion: UInt16 = 1

    public let candidates: [CoreSearchScoreCandidateV1]
    public let query: CoreSearchScoreQueryV1
    public let fuzzyThreshold: Double

    public init(
        candidates: [CoreSearchScoreCandidateV1],
        query: CoreSearchScoreQueryV1,
        fuzzyThreshold: Double
    ) {
        self.candidates = candidates
        self.query = query
        self.fuzzyThreshold = fuzzyThreshold
    }
}

public extension CoreComputeClient {
    /// Scores all candidates in one synchronous Rust batch while using the shared actor-owned
    /// runtime lifecycle. V1 intentionally has no leaf-cancellation field: the legacy C scorer was
    /// synchronous and uncancellable. Awaiting the detached UniFFI call adds no V1 cancellation
    /// token or cooperative cancellation semantics.
    func scoreSearchMatchesV1(_ request: CoreSearchScoreBatchRequestV1) async throws -> [Int32] {
        guard !request.candidates.isEmpty, !request.query.raw.isEmpty else { return [] }
        let context = try await bridge.prepareDirectComputeOperation()
        do {
            let scores = try await Task.detached(priority: nil) {
                try context.transport.searchScoreBatchV1(
                    identity: context.identity,
                    request: request
                )
            }.value
            try CoreSearchScoreResponseValidator.validate(
                scores,
                candidateCount: request.candidates.count
            )
            try await bridge.validateComputeCompletion(identity: context.identity)
            return scores
        } catch {
            throw await bridge.mapComputeFailure(error)
        }
    }
}

extension CoreRuntimeTransport {
    func searchScoreBatchV1(
        identity _: CoreRuntimeIdentity,
        request _: CoreSearchScoreBatchRequestV1
    ) throws -> [Int32] {
        throw CoreTransportError.unexpected("search-score transport is unavailable")
    }
}

enum CoreSearchScoreResponseValidator {
    static func validate(_ scores: [Int32], candidateCount: Int) throws {
        guard scores.count == candidateCount else {
            throw CoreComputeError.malformedResponse
        }
    }
}
