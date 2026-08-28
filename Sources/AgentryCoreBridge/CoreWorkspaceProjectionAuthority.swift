import AgentryUniFFIRaw
import Foundation

/// Shared projection/publication values used by the prepared command-admission aggregate.
/// P5-7i retired the independently stateful projection scope and checkpoint facade.
public enum CoreWorkspaceProjectionPublicationKind: Sendable, Equatable {
    case bootstrapped
    case workspaceCreated
    case workspaceDeleted
    case workingStateCommitted
    case savedDocumentCommitted
    case externalReloaded
    case externalConflict
    case degraded
    case routingChanged
    case operationDeduplicated
}

public enum CoreWorkspaceProjectionHealthKind: Sendable, Equatable {
    case writable
    case externalConflict
    case degradedReadOnly
    case removed
}

public struct CoreWorkspaceProjectionHealth: Sendable, Equatable {
    public let kind: CoreWorkspaceProjectionHealthKind
    public let reason: String?

    public init(kind: CoreWorkspaceProjectionHealthKind, reason: String? = nil) {
        self.kind = kind
        self.reason = reason
    }
}

public struct CoreWorkspaceProjectionRevisionState: Sendable, Equatable {
    public let workingRevision: UInt64
    public let savedRevision: UInt64
    public let dirtyRevision: UInt64?

    public init(workingRevision: UInt64, savedRevision: UInt64, dirtyRevision: UInt64?) {
        self.workingRevision = workingRevision
        self.savedRevision = savedRevision
        self.dirtyRevision = dirtyRevision
    }
}

public struct CoreWorkspaceContextAuthorityState: Sendable, Equatable {
    public let contextID: UUID
    public let revisions: CoreWorkspaceProjectionRevisionState
    public let health: CoreWorkspaceProjectionHealth

    public init(
        contextID: UUID,
        revisions: CoreWorkspaceProjectionRevisionState,
        health: CoreWorkspaceProjectionHealth
    ) {
        self.contextID = contextID
        self.revisions = revisions
        self.health = health
    }
}

public struct CoreWorkspaceProjectionAuthorityState: Sendable, Equatable {
    public let revisions: CoreWorkspaceProjectionRevisionState
    public let health: CoreWorkspaceProjectionHealth
    public let contexts: [CoreWorkspaceContextAuthorityState]

    public init(
        revisions: CoreWorkspaceProjectionRevisionState,
        health: CoreWorkspaceProjectionHealth,
        contexts: [CoreWorkspaceContextAuthorityState]
    ) {
        self.revisions = revisions
        self.health = health
        self.contexts = contexts
    }
}

public struct CoreWorkspaceProjectionPublishedWorkspace: Sendable, Equatable {
    public let documentBytes: Data
    public let authority: CoreWorkspaceProjectionAuthorityState

    public init(documentBytes: Data, authority: CoreWorkspaceProjectionAuthorityState) {
        self.documentBytes = documentBytes
        self.authority = authority
    }
}

public struct CoreWorkspaceProjectionPublicationEvent: Sendable, Equatable {
    public let sequence: UInt64
    public let catalogRevision: UInt64
    public let kind: CoreWorkspaceProjectionPublicationKind
    public let workspaceID: UUID?
    public let contextID: UUID?
    public let operationID: UUID?
    public let revisions: CoreWorkspaceProjectionRevisionState?

    public init(
        sequence: UInt64,
        catalogRevision: UInt64,
        kind: CoreWorkspaceProjectionPublicationKind,
        workspaceID: UUID?,
        contextID: UUID?,
        operationID: UUID?,
        revisions: CoreWorkspaceProjectionRevisionState?
    ) {
        self.sequence = sequence
        self.catalogRevision = catalogRevision
        self.kind = kind
        self.workspaceID = workspaceID
        self.contextID = contextID
        self.operationID = operationID
        self.revisions = revisions
    }
}

func coreWorkspaceDocumentProjection(
    _ value: AgentryUniFFIRaw.CoreWorkspaceDocumentProjectionV1
) throws -> CoreWorkspaceDocumentProjectionV1 {
    func optionalUUID(_ raw: String?) throws -> UUID? {
        guard let raw else { return nil }
        guard let value = UUID(uuidString: raw) else { throw CoreBridgeError.invalidArgument }
        return value
    }

    guard let workspaceID = UUID(uuidString: value.workspaceId),
          let schemaVersion = Int(exactly: value.schemaVersion)
    else {
        throw CoreBridgeError.invalidArgument
    }
    let contexts = try value.contexts.map { context -> CoreWorkspaceContextProjectionV1 in
        guard let contextID = UUID(uuidString: context.contextId) else {
            throw CoreBridgeError.invalidArgument
        }
        return CoreWorkspaceContextProjectionV1(
            contextID: contextID,
            name: context.name,
            activeAgentSessionID: try optionalUUID(context.activeAgentSessionId),
            activeChatSessionID: try optionalUUID(context.activeChatSessionId),
            prompt: context.prompt,
            selection: context.selection
        )
    }
    let authority = try value.authority.map { raw -> CoreWorkspaceProjectionAuthorityState in
        let contexts = try raw.contexts.map { context -> CoreWorkspaceContextAuthorityState in
            guard let contextID = UUID(uuidString: context.contextId) else {
                throw CoreBridgeError.invalidArgument
            }
            return CoreWorkspaceContextAuthorityState(
                contextID: contextID,
                revisions: coreWorkspaceProjectionRevisionState(context.revisions),
                health: try coreWorkspaceProjectionHealth(context.health)
            )
        }
        guard contexts.map(\.contextID) == value.contexts.compactMap({ UUID(uuidString: $0.contextId) }) else {
            throw CoreBridgeError.invalidArgument
        }
        return CoreWorkspaceProjectionAuthorityState(
            revisions: coreWorkspaceProjectionRevisionState(raw.revisions),
            health: try coreWorkspaceProjectionHealth(raw.health),
            contexts: contexts
        )
    }
    return CoreWorkspaceDocumentProjectionV1(
        workspaceID: workspaceID,
        schemaVersion: schemaVersion,
        name: value.name,
        repoPaths: value.repoPaths,
        activeContextID: try optionalUUID(value.activeContextId),
        contexts: contexts,
        authority: authority
    )
}

private func coreWorkspaceProjectionRevisionState(
    _ raw: AgentryUniFFIRaw.CoreWorkspaceProjectionRevisionStateV1
) -> CoreWorkspaceProjectionRevisionState {
    CoreWorkspaceProjectionRevisionState(
        workingRevision: raw.workingRevision,
        savedRevision: raw.savedRevision,
        dirtyRevision: raw.dirtyRevision
    )
}

private func coreWorkspaceProjectionHealth(
    _ raw: AgentryUniFFIRaw.CoreWorkspaceProjectionHealthV1
) throws -> CoreWorkspaceProjectionHealth {
    let kind: CoreWorkspaceProjectionHealthKind = switch raw.kind {
    case .writable: .writable
    case .externalConflict: .externalConflict
    case .degradedReadOnly: .degradedReadOnly
    case .removed: .removed
    }
    switch kind {
    case .writable, .removed:
        guard raw.reason == nil else { throw CoreBridgeError.invalidArgument }
    case .externalConflict, .degradedReadOnly:
        guard let reason = raw.reason, !reason.isEmpty else { throw CoreBridgeError.invalidArgument }
    }
    return CoreWorkspaceProjectionHealth(kind: kind, reason: raw.reason)
}

func coreWorkspaceProjectionRawHealth(
    _ health: CoreWorkspaceProjectionHealth
) -> AgentryUniFFIRaw.CoreWorkspaceProjectionHealthV1 {
    let kind: AgentryUniFFIRaw.CoreWorkspaceProjectionHealthKindV1 = switch health.kind {
    case .writable: .writable
    case .externalConflict: .externalConflict
    case .degradedReadOnly: .degradedReadOnly
    case .removed: .removed
    }
    return .init(kind: kind, reason: health.reason)
}

func coreWorkspaceProjectionRawRevisionState(
    _ revisions: CoreWorkspaceProjectionRevisionState
) -> AgentryUniFFIRaw.CoreWorkspaceProjectionRevisionStateV1 {
    .init(
        workingRevision: revisions.workingRevision,
        savedRevision: revisions.savedRevision,
        dirtyRevision: revisions.dirtyRevision
    )
}

func coreWorkspaceProjectionRawPublishedWorkspace(
    _ workspace: CoreWorkspaceProjectionPublishedWorkspace
) -> AgentryUniFFIRaw.CoreWorkspaceProjectionPublishedWorkspaceV1 {
    .init(
        documentBytes: workspace.documentBytes,
        authority: .init(
            revisions: coreWorkspaceProjectionRawRevisionState(workspace.authority.revisions),
            health: coreWorkspaceProjectionRawHealth(workspace.authority.health),
            contexts: workspace.authority.contexts.map { context in
                .init(
                    contextId: context.contextID.uuidString.lowercased(),
                    revisions: coreWorkspaceProjectionRawRevisionState(context.revisions),
                    health: coreWorkspaceProjectionRawHealth(context.health)
                )
            }
        )
    )
}
