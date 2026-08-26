import AgentryUniFFIRaw
import Foundation

/// Read-only Rust projection of one composed context's headless prompt/selection fields.
public struct CoreWorkspaceContextProjectionV1: Sendable, Equatable {
    public let contextID: UUID
    public let name: String
    public let activeAgentSessionID: UUID?
    public let activeChatSessionID: UUID?
    public let prompt: String
    public let selection: [String]

    public init(
        contextID: UUID,
        name: String,
        activeAgentSessionID: UUID?,
        activeChatSessionID: UUID?,
        prompt: String,
        selection: [String]
    ) {
        self.contextID = contextID
        self.name = name
        self.activeAgentSessionID = activeAgentSessionID
        self.activeChatSessionID = activeChatSessionID
        self.prompt = prompt
        self.selection = selection
    }
}

/// P5-1a's complete, order-preserving projection of one canonical workspace document.
public struct CoreWorkspaceDocumentProjectionV1: Sendable, Equatable {
    public static let contractVersion: UInt16 = 1
    public static let maximumDocumentBytes = 32 * 1024 * 1024

    public let workspaceID: UUID
    public let schemaVersion: Int
    public let name: String
    public let repoPaths: [String]
    public let activeContextID: UUID?
    public let contexts: [CoreWorkspaceContextProjectionV1]

    public init(
        workspaceID: UUID,
        schemaVersion: Int,
        name: String,
        repoPaths: [String],
        activeContextID: UUID?,
        contexts: [CoreWorkspaceContextProjectionV1]
    ) {
        self.workspaceID = workspaceID
        self.schemaVersion = schemaVersion
        self.name = name
        self.repoPaths = repoPaths
        self.activeContextID = activeContextID
        self.contexts = contexts
    }
}

public extension CoreComputeClient {
    /// Projects one complete `workspace.json` buffer through Rust without retaining or mutating it.
    func projectWorkspaceDocumentV1(_ documentBytes: Data) async throws -> CoreWorkspaceDocumentProjectionV1 {
        try Task.checkCancellation()
        guard documentBytes.count <= CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes else {
            throw CoreComputeError.invalidRequest(
                "workspace document exceeds \(CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes)-byte projection limit"
            )
        }
        let context = try await bridge.prepareDirectComputeOperation()
        do {
            let result = try await Task.detached(priority: nil) {
                try context.transport.workspaceDocumentProjectionV1(
                    identity: context.identity,
                    documentBytes: documentBytes
                )
            }.value
            try Task.checkCancellation()
            try await bridge.validateComputeCompletion(identity: context.identity)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await bridge.mapComputeFailure(error)
        }
    }
}

extension CoreRuntimeTransport {
    func workspaceProjectionOpenScopeV1(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreWorkspaceProjectionScopeConfigV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionScopeHandleV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionCloseScopeV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        scopeIncarnation: UInt64
    ) throws {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionReplaceV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionReplaceRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionUpsertV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionUpsertRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionPublishV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionPublishRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionPublicationReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionRemoveV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionRemoveRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionExportCheckpointV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        scopeIncarnation: UInt64
    ) throws -> Data {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionRestoreCheckpointV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionRestoreCheckpointRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionRestoreCheckpointReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionOpenSnapshotV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionSnapshotRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionSnapshotHandleV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionSnapshotPageV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        scopeIncarnation: UInt64,
        handleID: UInt64,
        offset: UInt64,
        limit: UInt64
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionSnapshotPageV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionCloseSnapshotV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        scopeIncarnation: UInt64,
        handleID: UInt64
    ) throws {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionDiagnosticsV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        scopeIncarnation: UInt64
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionDiagnosticsV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceDocumentProjectionV1(
        identity: CoreRuntimeIdentity,
        documentBytes: Data
    ) throws -> CoreWorkspaceDocumentProjectionV1 {
        throw CoreTransportError.unexpected("workspace document projection transport is unavailable")
    }
}
