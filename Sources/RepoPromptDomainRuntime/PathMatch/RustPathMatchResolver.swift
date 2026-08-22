import AgentryCoreBridge
import Foundation

/// Rust compute seam for the P3-3 slice-2a workspace path-matching RESOLUTION PIPELINE port
/// (the full `PathMatcher.locate` ladder, batched like `PathMatchWorker.locateMany`). Shaped like
/// `RustPathMatchScorer`: an injectable operation closure defaulting to the real
/// `AgentryCoreService` bridge.
///
/// NO PRODUCTION CALLER YET for this slice -- `PathMatcher.swift` still resolves paths entirely in
/// Swift. This type exists so `PathMatchRustSwiftDifferentialTests` can drive the real Rust seam
/// (no mocking) against the real Swift ladder and assert exact parity before any production call
/// site is wired up in a later slice.
package struct RustPathMatchResolver {
    package typealias ResolveOperation = @Sendable (
        _ caseSensitive: Bool,
        _ exactMatchOnly: Bool,
        _ allowLeadingRootAliasTrim: Bool,
        _ allowHeadTrimAliases: Bool,
        _ allowAbsoluteSuffixFallback: Bool,
        _ roots: [CorePathMatchResolveRootV1],
        _ files: [CorePathMatchResolveFileV1],
        _ folders: [CorePathMatchResolveFolderV1],
        _ selectedFileFullPaths: [String],
        _ queries: [CorePathMatchResolveQueryV1]
    ) async throws -> [CorePathMatchResolveLocationV1?]

    private let resolveOperation: ResolveOperation

    package init(
        resolveOperation: @escaping ResolveOperation = { caseSensitive, exactMatchOnly, allowLeadingRootAliasTrim,
            allowHeadTrimAliases, allowAbsoluteSuffixFallback, roots, files, folders, selectedFileFullPaths, queries in
            let client = try await AgentryCoreService.shared.computeClient()
            return try await client.pathMatchLocateManyBatchV1(
                caseSensitive: caseSensitive,
                exactMatchOnly: exactMatchOnly,
                allowLeadingRootAliasTrim: allowLeadingRootAliasTrim,
                allowHeadTrimAliases: allowHeadTrimAliases,
                allowAbsoluteSuffixFallback: allowAbsoluteSuffixFallback,
                roots: roots,
                files: files,
                folders: folders,
                selectedFileFullPaths: selectedFileFullPaths,
                queries: queries
            )
        }
    ) {
        self.resolveOperation = resolveOperation
    }

    /// Resolves every query in `queries` against one shared snapshot (`roots`/`files`/`folders` +
    /// `selectedFileFullPaths`), sharing the same `PathLocateOptions`-derived policy for the whole
    /// batch -- mirrors `PathMatchWorker.locateMany`. Returns one entry per query, index-aligned,
    /// `nil` for "no match".
    package func locateMany(
        caseSensitive: Bool,
        exactMatchOnly: Bool,
        allowLeadingRootAliasTrim: Bool,
        allowHeadTrimAliases: Bool,
        allowAbsoluteSuffixFallback: Bool,
        roots: [CorePathMatchResolveRootV1],
        files: [CorePathMatchResolveFileV1],
        folders: [CorePathMatchResolveFolderV1],
        selectedFileFullPaths: [String] = [],
        queries: [CorePathMatchResolveQueryV1]
    ) async throws -> [CorePathMatchResolveLocationV1?] {
        try await resolveOperation(
            caseSensitive,
            exactMatchOnly,
            allowLeadingRootAliasTrim,
            allowHeadTrimAliases,
            allowAbsoluteSuffixFallback,
            roots,
            files,
            folders,
            selectedFileFullPaths,
            queries
        )
    }
}
