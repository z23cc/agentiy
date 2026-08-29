import AgentryCoreBridge
import Foundation

/// Projection/read values shared with the prepared command-admission aggregate.
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

package struct DomainWorkspaceContextAuthorityReadState: Sendable, Equatable {
    package let contextID: UUID
    package let revisions: DomainRevisionState
    package let health: DomainAuthorityHealth
}

package struct DomainWorkspaceAuthorityReadState: Sendable, Equatable {
    package let revisions: DomainRevisionState
    package let health: DomainAuthorityHealth
    package let contexts: [DomainWorkspaceContextAuthorityReadState]
}

package struct DomainWorkspaceAuthoritativeProjectionRead: Sendable, Equatable {
    package let projection: DomainWorkspaceDocumentReadProjection?
    package let authority: DomainWorkspaceAuthorityReadState?
    package let contentDigest: String?
    package let generation: UInt64
    package let catalogRevision: UInt64
    package let publicationSequence: UInt64
    package let eventLogFloorSequence: UInt64
    package let eventLogCount: UInt64
    package let projectionDigest: String?
}

package struct DomainWorkspaceAuthorityProjectionSyncReceipt: Sendable, Equatable {
    package let previousGeneration: UInt64
    package let generation: UInt64
    package let projectionChanged: Bool
    package let workspaceCount: UInt64
    package let retainedBytes: UInt64
    package let catalogRevision: UInt64
    package let publicationSequence: UInt64
    package let projectionDigest: String
}

package struct DomainWorkspaceAuthorityPublicationCandidate: Sendable, Equatable {
    package let workspaces: [DomainWorkspaceSnapshot]
    package let catalogRevision: UInt64
    package let kind: DomainWorkspaceEventKind
    package let workspaceID: UUID?
    package let contextID: UUID?
    package let operationID: UUID?
    package let revisions: DomainRevisionState?
}

package struct DomainWorkspaceAuthorityPublicationReceipt: Sendable, Equatable {
    package let previousGeneration: UInt64
    package let generation: UInt64
    package let projectionChanged: Bool
    package let workspaceCount: UInt64
    package let retainedBytes: UInt64
    package let previousCatalogRevision: UInt64
    package let previousPublicationSequence: UInt64
    package let catalogRevision: UInt64
    package let publicationSequence: UInt64
    package let eventLogFloorSequence: UInt64
    package let eventLogCount: UInt64
    package let projectionDigest: String
}

/// Shared mappings for aggregate publication and immutable authority reads. Swift remains the
/// durable document writer and supplies physical routing; no independent projection scope or
/// comparison authority exists after P5-7i.
package enum DomainWorkspaceRustProjection {
    package static func corePublishedWorkspace(
        _ workspace: DomainWorkspaceSnapshot
    ) -> CoreWorkspaceProjectionPublishedWorkspace {
        CoreWorkspaceProjectionPublishedWorkspace(
            documentBytes: workspace.document.documentBytes,
            authority: CoreWorkspaceProjectionAuthorityState(
                revisions: coreRevisionState(workspace.revisions),
                health: coreHealth(workspace.health),
                contexts: workspace.contexts.map { context in
                    CoreWorkspaceContextAuthorityState(
                        contextID: context.metadata.identity.contextID,
                        revisions: coreRevisionState(context.revisions),
                        health: coreHealth(context.health)
                    )
                }
            )
        )
    }

    package static func corePublicationCandidate(
        _ candidate: DomainWorkspaceAuthorityPublicationCandidate
    ) -> CoreWorkspaceAuthorityPublicationCandidate {
        CoreWorkspaceAuthorityPublicationCandidate(
            workspaces: candidate.workspaces.map(corePublishedWorkspace),
            draft: CoreWorkspaceAuthorityPublicationDraft(
                catalogRevision: candidate.catalogRevision,
                kind: corePublicationKind(candidate.kind),
                workspaceID: candidate.workspaceID,
                contextID: candidate.contextID,
                operationID: candidate.operationID,
                revisions: candidate.revisions.map(coreRevisionState)
            )
        )
    }

    package static func authorityPublicationReceipt(
        _ receipt: CoreWorkspaceAuthorityPublicationReceipt
    ) -> DomainWorkspaceAuthorityPublicationReceipt {
        DomainWorkspaceAuthorityPublicationReceipt(
            previousGeneration: receipt.previousGeneration,
            generation: receipt.generation,
            projectionChanged: receipt.projectionChanged,
            workspaceCount: receipt.workspaceCount,
            retainedBytes: receipt.retainedBytes,
            previousCatalogRevision: receipt.previousCatalogRevision,
            previousPublicationSequence: receipt.previousPublicationSequence,
            catalogRevision: receipt.catalogRevision,
            publicationSequence: receipt.publicationSequence,
            eventLogFloorSequence: receipt.eventLogFloorSequence,
            eventLogCount: receipt.eventLogCount,
            projectionDigest: receipt.projectionDigest
        )
    }

    package static func corePublicationKind(
        _ kind: DomainWorkspaceEventKind
    ) -> CoreWorkspaceProjectionPublicationKind {
        switch kind {
        case .bootstrapped: .bootstrapped
        case .workspaceCreated: .workspaceCreated
        case .workspaceDeleted: .workspaceDeleted
        case .workingStateCommitted: .workingStateCommitted
        case .savedDocumentCommitted: .savedDocumentCommitted
        case .externalReloaded: .externalReloaded
        case .externalConflict: .externalConflict
        case .degraded: .degraded
        case .routingChanged: .routingChanged
        case .operationDeduplicated: .operationDeduplicated
        }
    }

    package static func coreRevisionState(
        _ revisions: DomainRevisionState
    ) -> CoreWorkspaceProjectionRevisionState {
        CoreWorkspaceProjectionRevisionState(
            workingRevision: revisions.workingRevision,
            savedRevision: revisions.savedRevision,
            dirtyRevision: revisions.dirtyRevision
        )
    }

    package static func coreHealth(
        _ health: DomainAuthorityHealth
    ) -> CoreWorkspaceProjectionHealth {
        switch health {
        case .writable:
            CoreWorkspaceProjectionHealth(kind: .writable)
        case let .externalConflict(reason):
            CoreWorkspaceProjectionHealth(kind: .externalConflict, reason: reason)
        case let .degradedReadOnly(reason):
            CoreWorkspaceProjectionHealth(kind: .degradedReadOnly, reason: reason)
        case .removed:
            CoreWorkspaceProjectionHealth(kind: .removed)
        }
    }

    package static func domainAuthorityState(
        _ authority: CoreWorkspaceProjectionAuthorityState
    ) -> DomainWorkspaceAuthorityReadState {
        DomainWorkspaceAuthorityReadState(
            revisions: domainRevisionState(authority.revisions),
            health: domainHealth(authority.health),
            contexts: authority.contexts.map { context in
                DomainWorkspaceContextAuthorityReadState(
                    contextID: context.contextID,
                    revisions: domainRevisionState(context.revisions),
                    health: domainHealth(context.health)
                )
            }
        )
    }

    package static func authorityProjection(
        _ workspace: DomainWorkspaceSnapshot
    ) -> DomainWorkspaceAuthorityReadState {
        DomainWorkspaceAuthorityReadState(
            revisions: workspace.revisions,
            health: workspace.health,
            contexts: workspace.contexts.map { context in
                DomainWorkspaceContextAuthorityReadState(
                    contextID: context.metadata.identity.contextID,
                    revisions: context.revisions,
                    health: context.health
                )
            }
        )
    }

    package static func workspaceSnapshot(
        topology: DomainWorkspaceSnapshot,
        authority: DomainWorkspaceAuthorityReadState
    ) -> DomainWorkspaceSnapshot? {
        guard topology.contexts.map({ $0.metadata.identity.contextID })
            == authority.contexts.map(\.contextID)
        else { return nil }
        return DomainWorkspaceSnapshot(
            document: topology.document,
            revisions: authority.revisions,
            health: authority.health,
            contexts: zip(topology.contexts, authority.contexts).map { context, authority in
                DomainContextSnapshot(
                    metadata: context.metadata,
                    revisions: authority.revisions,
                    health: authority.health
                )
            }
        )
    }

    package static func domainProjection(
        _ projected: CoreWorkspaceDocumentProjectionV1
    ) -> DomainWorkspaceDocumentReadProjection {
        DomainWorkspaceDocumentReadProjection(
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

    private static func domainRevisionState(
        _ revisions: CoreWorkspaceProjectionRevisionState
    ) -> DomainRevisionState {
        DomainRevisionState(
            workingRevision: revisions.workingRevision,
            savedRevision: revisions.savedRevision,
            dirtyRevision: revisions.dirtyRevision
        )
    }

    private static func domainHealth(
        _ health: CoreWorkspaceProjectionHealth
    ) -> DomainAuthorityHealth {
        switch health.kind {
        case .writable: .writable
        case .externalConflict: .externalConflict(reason: health.reason ?? "external_conflict")
        case .degradedReadOnly: .degradedReadOnly(reason: health.reason ?? "projection_unavailable")
        case .removed: .removed
        }
    }
}
