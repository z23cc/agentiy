import AgentryCoreBridge
import Foundation

/// Production Rust compute seam for `apply_edits`. Shared by the GUI app's
/// `MCPApplyEditsToolProvider` and the standalone headless `agentry-mcp`
/// binary's `DirectHeadlessCapabilityBackends` -- both processes reach the
/// same Rust core through `AgentryCoreService`.
package struct RustApplyEditsComputer: ApplyEditsComputing {
    package typealias ApplyOperation = @Sendable (CoreApplyEditsBatchRequestV1) async throws -> CoreApplyEditsBatchResultV1

    private let applyOperation: ApplyOperation

    package init(applyOperation: @escaping ApplyOperation = { request in
        let client = try await AgentryCoreService.shared.computeClient()
        return try await client.applyEditsBatchV1(request)
    }) {
        self.applyOperation = applyOperation
    }

    package func apply(
        request: ApplyEditsRequest,
        to originalText: String,
        options: ApplyEditsExecutionOptions
    ) async throws -> ApplyEditsResult {
        let subject = CoreApplyEditsSubjectRequestV1(
            pathLabel: request.path,
            original: originalText,
            mode: Self.coreMode(request.mode),
            verbose: request.verbose,
            includeToolCardUnifiedDiff: options.includeToolCardUnifiedDiff
        )
        return try await Self.run(subject, applyOperation: applyOperation)
    }

    /// TD-3 §6.1/round-2 Finding F2: additive raw-bytes path used only by hosts conforming to
    /// `RawBytesFileEditHost` (ladder 6, `DirectHeadlessFileEditHost`). `rawBytes` is genuinely
    /// raw, possibly-non-UTF-8 disk bytes; Rust's apply-edits handler calls `textdecode()`
    /// internally as its first step -- the existing `original: String`-based path above (which
    /// GUI apply-edits depends on) is untouched.
    package func apply(
        request: ApplyEditsRequest,
        toRawBytes rawBytes: Data,
        options: ApplyEditsExecutionOptions
    ) async throws -> ApplyEditsResult {
        let subject = CoreApplyEditsSubjectRequestV1(
            pathLabel: request.path,
            rawBytes: rawBytes,
            mode: Self.coreMode(request.mode),
            verbose: request.verbose,
            includeToolCardUnifiedDiff: options.includeToolCardUnifiedDiff
        )
        return try await Self.run(subject, applyOperation: applyOperation)
    }

    private static func run(
        _ subject: CoreApplyEditsSubjectRequestV1,
        applyOperation: ApplyOperation
    ) async throws -> ApplyEditsResult {
        do {
            let result = try await applyOperation(.init(subjects: [subject]))
            guard result.subjects.count == 1, let subject = result.subjects.first else {
                throw ApplyEditsError.internalError("The Rust core returned an invalid apply_edits result.")
            }
            return Self.materialize(subject)
        } catch let error as ApplyEditsError {
            throw error
        } catch let error as CoreApplyEditsLossyDecodeBlocksWriteBackError {
            throw ApplyEditsError.lossyDecodeBlocksWriteBack(error.message)
        } catch let error as CoreComputeError {
            switch error {
            case let .invalidRequest(message):
                throw ApplyEditsError.invalidParams(message)
            case .malformedResponse, .runtimeInvalidated, .runtimeStopped, .runtimePoisoned, .transportFailure:
                throw ApplyEditsError.internalError(error.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ApplyEditsError.internalError(error.localizedDescription)
        }
    }

    private static func coreMode(_ mode: ApplyEditsMode) -> CoreApplyEditsModeV1 {
        switch mode {
        case let .rewrite(newText, _):
            .rewrite(replacement: newText)
        case let .single(search, replace, replaceAll):
            .single(.init(search: search, replacement: replace, replaceAll: replaceAll))
        case let .batch(operations):
            .batch(operations.map {
                .init(search: $0.search, replacement: $0.replace, replaceAll: $0.replaceAll)
            })
        }
    }

    private static func materialize(_ result: CoreApplyEditsSubjectResultV1) -> ApplyEditsResult {
        let status: ApplyEditsStatus = switch result.status {
        case .success: .success
        case .partial: .partial
        case .failed: .failed
        }
        let outcomes = result.outcomes?.map { outcome in
            let status = switch outcome.status {
            case .success: "success"
            case .failed: "failed"
            }
            return EditOutcome(index: outcome.operationIndex, status: status, error: outcome.error)
        }
        return ApplyEditsResult(
            updatedText: result.updatedText,
            diffChunks: result.chunks.map { chunk in
                DiffChunk(
                    lines: chunk.lines.map { line in
                        let prefix = switch line.type {
                        case .context: " "
                        case .addition: "+"
                        case .removal: "-"
                        }
                        return DiffLine(content: prefix + line.content)
                    },
                    startLine: chunk.startLine
                )
            },
            unifiedDiff: result.unifiedDiff,
            toolCardUnifiedDiff: result.toolCardUnifiedDiff,
            stats: result.stats.map { .init(linesChanged: $0.linesChanged, chunks: $0.chunkCount) },
            note: result.note,
            fileCreated: false,
            fileOverwritten: false,
            editsRequested: result.editsRequested,
            editsApplied: result.editsApplied,
            status: status,
            outcomes: outcomes
        )
    }
}
