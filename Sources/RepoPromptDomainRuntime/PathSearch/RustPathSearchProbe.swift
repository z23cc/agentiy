import AgentryCoreBridge
import Foundation

/// Rust compute seam for the P3-3 slice-2b phase-2 path-search port
/// (`rust/crates/runtime/src/pathsearch/`, a behavioral port of
/// `Sources/RepoPromptC/src/Utils/path_search.c`). Shaped like `RustPathMatchResolver`: an
/// injectable operation closure defaulting to the real `AgentryCoreService` bridge.
///
/// NO PRODUCTION CALLER -- THIS IS DIFFERENTIAL-ONLY. `PathSearchIndex.swift` (the C-backed
/// production search index) is untouched by this slice. `RustPathSearchProbe` exists ONLY so
/// `PathSearchRustSwiftDifferentialTests` can drive the real Rust seam (no mocking) against the
/// real C-backed `PathSearchIndex` and assert exact parity. It is named "Probe" -- not "Client",
/// "Service", or "Index" -- specifically so nobody mistakes it for a production entry point: it
/// rebuilds the ENTIRE Rust corpus index on every call (see
/// `rust/crates/runtime/src/pathsearch/wire.rs`'s module doc for why that is fine for a
/// differential test and NOT fine for a per-keystroke production caller -- production cutover
/// needs the P4 stateful scope-registry handle primitive, not this shape).
package struct RustPathSearchProbe {
    package typealias FindOperation = @Sendable (
        _ corpusPaths: [String],
        _ queries: [CorePathSearchQueryV1]
    ) async throws -> [CorePathSearchQueryResultV1]

    private let findOperation: FindOperation

    package init(
        findOperation: @escaping FindOperation = { corpusPaths, queries in
            let client = try await AgentryCoreService.shared.computeClient()
            return try await client.pathSearchFindV1(corpusPaths: corpusPaths, queries: queries)
        }
    ) {
        self.findOperation = findOperation
    }

    /// Runs every query in `queries` against ONE Rust `PathSearchIndex` built from `corpusPaths`
    /// for this call -- mirrors driving the real Swift `PathSearchIndex` with the same corpus and
    /// query list. Returns one entry per query, index-aligned.
    package func find(
        corpusPaths: [String],
        queries: [CorePathSearchQueryV1]
    ) async throws -> [CorePathSearchQueryResultV1] {
        try await findOperation(corpusPaths, queries)
    }
}
