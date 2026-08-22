import AgentryCoreBridge
import Foundation

/// Rust compute seam for the P3-4 token-accounting port
/// (`rust/crates/runtime/src/tokenacct/`, a behavioral port of the estimation heuristics, line
/// counting, and entry-metrics aggregation in
/// `Sources/RepoPrompt/Infrastructure/WorkspaceContext/TokenAccounting/TokenCalculationService.swift`).
/// Shaped like `RustPathSearchProbe`: an injectable operation closure defaulting to the real
/// `AgentryCoreService` bridge.
///
/// NO PRODUCTION CALLER -- THIS IS DIFFERENTIAL-ONLY. `TokenCalculationService.swift` (the
/// production actor) is untouched by this slice. `RustTokenAccountingProbe` exists ONLY so
/// `TokenAccountingRustSwiftDifferentialTests` can drive the real Rust seam (no mocking) against
/// the real Swift `TokenCalculationService` and assert exact parity. It is named "Probe" -- not
/// "Client", "Service", or "Accountant" -- specifically so nobody mistakes it for a production
/// entry point: it batches an entire snapshot's entries plus every component-breakdown row into
/// ONE call (see `rust/crates/runtime/src/tokenacct/wire.rs`'s module doc for why that is fine
/// for a differential test and NOT how a real per-keystroke `TokenCalculationService` caller is
/// shaped).
package struct RustTokenAccountingProbe {
    package typealias ComputeOperation = @Sendable (
        _ entries: [CoreTokenAccountingEntryV1],
        _ components: [CoreTokenAccountingComponentV1]
    ) async throws -> CoreTokenAccountingResponseV1

    private let computeOperation: ComputeOperation

    package init(
        computeOperation: @escaping ComputeOperation = { entries, components in
            let client = try await AgentryCoreService.shared.computeClient()
            return try await client.tokenAccountingV1(entries: entries, components: components)
        }
    ) {
        self.computeOperation = computeOperation
    }

    /// Runs `evaluatePromptEntries`'s entry-metrics computation over every entry in `entries`
    /// (index-aligned response) plus `calculateComponentBreakdown` over every row in
    /// `components` (index-aligned response), in ONE Rust call.
    package func compute(
        entries: [CoreTokenAccountingEntryV1],
        components: [CoreTokenAccountingComponentV1]
    ) async throws -> CoreTokenAccountingResponseV1 {
        try await computeOperation(entries, components)
    }
}
