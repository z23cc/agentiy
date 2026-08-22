import AgentryCoreBridge
import Foundation

/// Rust compute seam for the P3-3 slice-1 workspace path-matching scoring kernel port
/// (`PathMatcher.computeWeightedMatchScorePrecleaned` + `similarityScoreMax` + the
/// `fuzzyMatchWithSuffixLimit` selected-root `+0.5` bonus). Shaped like
/// `RustApplyEditsComputer`/`RustInventoryComputer`: an injectable operation closure defaulting to
/// the real `AgentryCoreService` bridge.
///
/// NO PRODUCTION CALLER YET for this slice -- `PathMatcher.swift` still resolves paths entirely in
/// Swift. This type exists so `PathMatchRustSwiftDifferentialTests` can drive the real Rust seam
/// (no mocking) against the real Swift scoring kernel and assert exact parity before any
/// production call site is wired up in a later slice.
package struct RustPathMatchScorer {
    package typealias ScoreOperation = @Sendable (
        _ query: [CorePathMatchComponentV1],
        _ candidates: [CorePathMatchCandidateV1],
        _ threshold: Double,
        _ selectedRootOrdinals: Set<UInt64>
    ) async throws -> [CorePathMatchScoreV1]

    private let scoreOperation: ScoreOperation

    package init(
        scoreOperation: @escaping ScoreOperation = { query, candidates, threshold, selectedRootOrdinals in
            let client = try await AgentryCoreService.shared.computeClient()
            return try await client.pathMatchScoreBatchV1(
                query: query,
                candidates: candidates,
                threshold: threshold,
                selectedRootOrdinals: selectedRootOrdinals
            )
        }
    ) {
        self.scoreOperation = scoreOperation
    }

    /// Scores `query` (already cleaned + lowercased path components, filename last) against every
    /// `candidate` in one batch call. Returns only candidates that scored (mirrors Swift's `nil`
    /// as a business outcome), in candidate input order otherwise.
    package func score(
        query: [CorePathMatchComponentV1],
        candidates: [CorePathMatchCandidateV1],
        threshold: Double,
        selectedRootOrdinals: Set<UInt64> = []
    ) async throws -> [CorePathMatchScoreV1] {
        try await scoreOperation(query, candidates, threshold, selectedRootOrdinals)
    }
}
