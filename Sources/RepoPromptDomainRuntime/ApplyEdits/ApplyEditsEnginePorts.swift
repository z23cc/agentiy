import Foundation

package protocol ApplyEditsComputing: Sendable {
    func apply(
        request: ApplyEditsRequest,
        to originalText: String,
        options: ApplyEditsExecutionOptions
    ) async throws -> ApplyEditsResult

    /// TD-3 §6.1 additive raw-bytes path (round-2 Finding F2): used only by hosts that conform
    /// to `RawBytesFileEditHost` (currently `DirectHeadlessFileEditHost`, ladder 6/D-6). The
    /// default implementation below decodes strictly as UTF-8 for any conformer that does not
    /// override it -- `RustApplyEditsComputer` overrides this with the real raw-bytes-carrying
    /// FFI construction path so Rust's `textdecode()` runs as the single-crossing first step.
    func apply(
        request: ApplyEditsRequest,
        toRawBytes rawBytes: Data,
        options: ApplyEditsExecutionOptions
    ) async throws -> ApplyEditsResult
}

extension ApplyEditsComputing {
    package func apply(
        request: ApplyEditsRequest,
        toRawBytes rawBytes: Data,
        options: ApplyEditsExecutionOptions
    ) async throws -> ApplyEditsResult {
        guard let text = String(data: rawBytes, encoding: .utf8) else {
            throw ApplyEditsError.invalidParams("apply_edits requires a UTF-8 text file")
        }
        return try await apply(request: request, to: text, options: options)
    }
}
