import Foundation

package enum DomainCommandOrigin: Codable, Equatable, Sendable {
    case appPresentation(windowID: Int)
    case appMCP(connectionID: UUID?)
    case standalone
    case externalReload
}

package enum DomainWorkspaceCommand: Codable, Equatable, Sendable {
    case createWorkspace(DomainWorkspaceDocument)
    case replaceWorkingDocument(DomainWorkspaceDocument)
    /// Selection/context mutations carry an explicit target and digest fence. They still use
    /// the canonical working-document transaction underneath, but cannot be mistaken for an
    /// unscoped document replacement by GUI or headless callers.
    case replaceSelection(DomainWorkspaceSelectionMutationRequest)
    /// Prompt, chat-session, and tab metadata mutations carry a complete-context digest fence.
    /// They share the same Rust working-journal transaction without widening selection semantics.
    case replaceContext(DomainWorkspaceContextMutationRequest)
    case saveWorkspaceDocument(workspaceID: UUID)
    case deleteWorkspace(workspaceID: UUID)
    case resolveExternalConflict(
        workspaceID: UUID,
        acceptExternal: Bool,
        protectedAgentIdentities: [DomainProtectedAgentIdentity]
    )
}

package enum DomainWorkspaceSelectionMutationKind: String, Codable, Equatable, Sendable {
    case replaceFilesSelection
}

package struct DomainWorkspaceSelectionMutationRequest: Codable, Equatable, Sendable {
    package let workspaceID: UUID
    package let contextID: UUID
    package let expectedSelectionDigest: String
    package let candidateSelectionDigest: String
    package let mutationKind: DomainWorkspaceSelectionMutationKind
    package let candidateDocument: DomainWorkspaceDocument

    package init(
        workspaceID: UUID,
        contextID: UUID,
        expectedSelectionDigest: String,
        candidateSelectionDigest: String,
        mutationKind: DomainWorkspaceSelectionMutationKind = .replaceFilesSelection,
        candidateDocument: DomainWorkspaceDocument
    ) {
        self.workspaceID = workspaceID
        self.contextID = contextID
        self.expectedSelectionDigest = expectedSelectionDigest
        self.candidateSelectionDigest = candidateSelectionDigest
        self.mutationKind = mutationKind
        self.candidateDocument = candidateDocument
    }

    package var descriptor: DomainWorkspaceSelectionMutationDescriptor {
        DomainWorkspaceSelectionMutationDescriptor(
            workspaceID: workspaceID,
            contextID: contextID,
            expectedSelectionDigest: expectedSelectionDigest,
            candidateSelectionDigest: candidateSelectionDigest,
            mutationKind: mutationKind
        )
    }
}

/// Metadata bound into the Rust journal transaction. The candidate document remains the sole
/// persisted representation; this descriptor is only an integrity and target fence.
package struct DomainWorkspaceSelectionMutationDescriptor: Codable, Equatable, Sendable {
    package let workspaceID: UUID
    package let contextID: UUID
    package let expectedSelectionDigest: String
    package let candidateSelectionDigest: String
    package let mutationKind: DomainWorkspaceSelectionMutationKind

    package init(
        workspaceID: UUID,
        contextID: UUID,
        expectedSelectionDigest: String,
        candidateSelectionDigest: String,
        mutationKind: DomainWorkspaceSelectionMutationKind
    ) {
        self.workspaceID = workspaceID
        self.contextID = contextID
        self.expectedSelectionDigest = expectedSelectionDigest
        self.candidateSelectionDigest = candidateSelectionDigest
        self.mutationKind = mutationKind
    }
}

package enum DomainWorkspaceContextMutationKind: String, Codable, Equatable, Sendable {
    case replacePrompt
    case replaceChatSession
    case replaceTabContext
}

package struct DomainWorkspaceContextMutationRequest: Codable, Equatable, Sendable {
    package let workspaceID: UUID
    package let contextID: UUID
    package let expectedContextDigest: String
    package let candidateContextDigest: String
    package let mutationKind: DomainWorkspaceContextMutationKind
    package let candidateDocument: DomainWorkspaceDocument

    package init(
        workspaceID: UUID,
        contextID: UUID,
        expectedContextDigest: String,
        candidateContextDigest: String,
        mutationKind: DomainWorkspaceContextMutationKind,
        candidateDocument: DomainWorkspaceDocument
    ) {
        self.workspaceID = workspaceID
        self.contextID = contextID
        self.expectedContextDigest = expectedContextDigest
        self.candidateContextDigest = candidateContextDigest
        self.mutationKind = mutationKind
        self.candidateDocument = candidateDocument
    }

    package var descriptor: DomainWorkspaceContextMutationDescriptor {
        DomainWorkspaceContextMutationDescriptor(
            workspaceID: workspaceID,
            contextID: contextID,
            expectedContextDigest: expectedContextDigest,
            candidateContextDigest: candidateContextDigest,
            mutationKind: mutationKind
        )
    }
}

/// Metadata bound into the Rust journal transaction for a complete compose-tab context change.
package struct DomainWorkspaceContextMutationDescriptor: Codable, Equatable, Sendable {
    package let workspaceID: UUID
    package let contextID: UUID
    package let expectedContextDigest: String
    package let candidateContextDigest: String
    package let mutationKind: DomainWorkspaceContextMutationKind

    package init(
        workspaceID: UUID,
        contextID: UUID,
        expectedContextDigest: String,
        candidateContextDigest: String,
        mutationKind: DomainWorkspaceContextMutationKind
    ) {
        self.workspaceID = workspaceID
        self.contextID = contextID
        self.expectedContextDigest = expectedContextDigest
        self.candidateContextDigest = candidateContextDigest
        self.mutationKind = mutationKind
    }
}

package struct DomainWorkspaceCommandEnvelope: Codable, Equatable, Sendable {
    package let operationID: UUID
    package let expectedCatalogRevision: UInt64?
    package let expectedWorkspaceRevision: UInt64?
    package let expectedContextRevision: UInt64?
    package let origin: DomainCommandOrigin
    package let command: DomainWorkspaceCommand

    package init(
        operationID: UUID,
        expectedCatalogRevision: UInt64? = nil,
        expectedWorkspaceRevision: UInt64? = nil,
        expectedContextRevision: UInt64? = nil,
        origin: DomainCommandOrigin,
        command: DomainWorkspaceCommand
    ) {
        self.operationID = operationID
        self.expectedCatalogRevision = expectedCatalogRevision
        self.expectedWorkspaceRevision = expectedWorkspaceRevision
        self.expectedContextRevision = expectedContextRevision
        self.origin = origin
        self.command = command
    }
}

package enum DomainCommandDisposition: String, Codable, Sendable {
    case applied
    case unchanged
    case conflict
    case readOnly
    case invalid
    case failed
    case deduplicated
}

package enum DomainCommandErrorCode: String, Codable, Sendable {
    case stateConflict = "state_conflict"
    case runtimeReadOnlyDegraded = "runtime_read_only_degraded"
    case workspaceExternalConflict = "workspace_external_conflict"
    case workspaceReadOnlyDegraded = "workspace_read_only_degraded"
    case protectedAgentIdentityConflict = "protected_agent_identity_conflict"
    case operationIDCollision = "operation_id_collision"
    case workspaceUnavailable = "workspace_unavailable"
    case invalidDocument = "invalid_document"
    case persistenceFailure = "persistence_failure"
    case lockTimedOut = "lock_timed_out"
    case cancelled
}

package struct DomainCommandOutcome: Codable, Equatable, Sendable {
    package let operationID: UUID
    package let disposition: DomainCommandDisposition
    package let before: DomainRevisionState?
    package let after: DomainRevisionState?
    package let catalogRevision: UInt64
    package let resultingDigest: String?
    package let errorCode: DomainCommandErrorCode?
    package let diagnostic: String?
    package let workspace: DomainWorkspaceSnapshot?

    package init(
        operationID: UUID,
        disposition: DomainCommandDisposition,
        before: DomainRevisionState?,
        after: DomainRevisionState?,
        catalogRevision: UInt64,
        resultingDigest: String?,
        errorCode: DomainCommandErrorCode? = nil,
        diagnostic: String? = nil,
        workspace: DomainWorkspaceSnapshot? = nil
    ) {
        self.operationID = operationID
        self.disposition = disposition
        self.before = before
        self.after = after
        self.catalogRevision = catalogRevision
        self.resultingDigest = resultingDigest
        self.errorCode = errorCode
        self.diagnostic = diagnostic
        self.workspace = workspace
    }
}

struct DomainRecordedOperation: Codable, Equatable, Sendable {
    let operationID: UUID
    let fingerprint: String
    let recordedAt: Date
    let disposition: DomainCommandDisposition
    let before: DomainRevisionState?
    let after: DomainRevisionState?
    let catalogRevision: UInt64
    let resultingDigest: String?
    let errorCode: DomainCommandErrorCode?
    let diagnostic: String?

    /// Command facts supplied to Rust semantic planning. Revision, catalog, digest, and
    /// diagnostic fields are intentionally absent; Rust derives those fields from the
    /// authoritative journal/catalog state and candidate bytes.
    init(operationID: UUID, fingerprint: String, recordedAt: Date) {
        self.operationID = operationID
        self.fingerprint = fingerprint
        self.recordedAt = recordedAt
        disposition = .applied
        before = nil
        after = nil
        catalogRevision = 0
        resultingDigest = nil
        errorCode = nil
        diagnostic = nil
    }

    init(fingerprint: String, recordedAt: Date, outcome: DomainCommandOutcome) {
        operationID = outcome.operationID
        self.fingerprint = fingerprint
        self.recordedAt = recordedAt
        disposition = outcome.disposition
        before = outcome.before
        after = outcome.after
        catalogRevision = outcome.catalogRevision
        resultingDigest = outcome.resultingDigest
        errorCode = outcome.errorCode
        diagnostic = outcome.diagnostic
    }

    func outcome(workspace: DomainWorkspaceSnapshot?) -> DomainCommandOutcome {
        DomainCommandOutcome(
            operationID: operationID,
            disposition: .deduplicated,
            before: before,
            after: after,
            catalogRevision: catalogRevision,
            resultingDigest: resultingDigest,
            errorCode: errorCode,
            diagnostic: diagnostic,
            workspace: workspace
        )
    }
}
