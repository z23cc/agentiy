import AgentryCoreBridge
import Foundation
import OSLog
import RepoPromptDomainRuntime

enum RepoSearchBatchScorer {
    typealias ScoreBatch = @Sendable (CoreSearchScoreBatchRequestV1) async throws -> [Int32]

    private static let logger = Logger(subsystem: "com.repoprompt.workspace", category: "SearchScoring")

    struct Candidate {
        let name: String
        let path: String
        let nameLower: String
        let pathLower: String
    }

    static func scores(
        for candidates: [Candidate],
        query: RepoSearchQuery,
        fuzzyThreshold: Double,
        scoreBatch: ScoreBatch = { request in
            let client = try await AgentryCoreService.shared.computeClient()
            return try await client.scoreSearchMatchesV1(request)
        }
    ) async -> [Int32] {
        guard !candidates.isEmpty, !query.isEmpty else { return [] }

        do {
            return try await scoreBatch(.init(
                candidates: candidates.map { candidate in
                    CoreSearchScoreCandidateV1(
                        name: candidate.name,
                        path: candidate.path,
                        nameLower: candidate.nameLower,
                        pathLower: candidate.pathLower
                    )
                },
                query: CoreSearchScoreQueryV1(
                    raw: query.raw,
                    lowered: query.lowered,
                    hasSlash: query.hasSlash,
                    isWildcard: query.isWildcard
                ),
                fuzzyThreshold: fuzzyThreshold
            ))
        } catch {
            logger.error(
                "Search scoring failed; returning zero scores: \(String(describing: error), privacy: .public)"
            )
            return Array(repeating: 0, count: candidates.count)
        }
    }
}
