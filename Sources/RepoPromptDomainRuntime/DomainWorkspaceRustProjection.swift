import AgentryCoreBridge
import Foundation

/// Transport-neutral read shape shared by P5-1a differential tests and later shadow wiring.
package struct DomainWorkspaceContextReadProjection: Sendable, Equatable {
    package let contextID: UUID
    package let name: String
    package let activeAgentSessionID: UUID?
    package let activeChatSessionID: UUID?
    package let prompt: String
    package let selection: [String]
}

package struct DomainWorkspaceDocumentReadProjection: Sendable, Equatable {
    package let workspaceID: UUID
    package let schemaVersion: Int
    package let name: String
    package let repoPaths: [String]
    package let activeContextID: UUID?
    package let contexts: [DomainWorkspaceContextReadProjection]
}

/// P5-1a comparison-only Rust projector. Swift remains the production document/read authority.
package enum DomainWorkspaceRustProjection {
    package static func project(
        documentBytes: Data,
        coreService: AgentryCoreService = .shared
    ) async throws -> DomainWorkspaceDocumentReadProjection {
        let client = try await coreService.computeClient()
        let projected = try await client.projectWorkspaceDocumentV1(documentBytes)
        return DomainWorkspaceDocumentReadProjection(
            workspaceID: projected.workspaceID,
            schemaVersion: projected.schemaVersion,
            name: projected.name,
            repoPaths: projected.repoPaths,
            activeContextID: projected.activeContextID,
            contexts: projected.contexts.map { context in
                DomainWorkspaceContextReadProjection(
                    contextID: context.contextID,
                    name: context.name,
                    activeAgentSessionID: context.activeAgentSessionID,
                    activeChatSessionID: context.activeChatSessionID,
                    prompt: context.prompt,
                    selection: context.selection
                )
            }
        )
    }
}
