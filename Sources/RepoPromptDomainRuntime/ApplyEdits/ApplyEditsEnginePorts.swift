import Foundation

package protocol ApplyEditsComputing: Sendable {
    func apply(
        request: ApplyEditsRequest,
        to originalText: String,
        options: ApplyEditsExecutionOptions
    ) async throws -> ApplyEditsResult
}
