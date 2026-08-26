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

package enum DomainWorkspaceProjectionMismatchField: String, CaseIterable, Sendable {
    case workspaceID = "workspace_id"
    case schemaVersion = "schema_version"
    case name
    case repoPaths = "repo_paths"
    case activeContextID = "active_context_id"
    case contextCount = "context_count"
    case contextOrder = "context_order"
    case contextName = "context_name"
    case contextActiveAgentSessionID = "context_active_agent_session_id"
    case contextActiveChatSessionID = "context_active_chat_session_id"
    case contextPrompt = "context_prompt"
    case contextSelection = "context_selection"
}

package enum DomainWorkspaceSwiftProjectionError: Error, Equatable {
    case invalidContextDocument(UUID)
}

package enum DomainWorkspaceStatefulRustProjectionError: Error, Equatable {
    case invalidWorkspaceIdentity
    case missingWorkspace(UUID)
    case invalidPageProgress
    case stopped
}

package enum DomainWorkspaceProjectionScopeIdentity {
    package static func scopeID(storageScopeDigest: String) -> UUID {
        let hex = String(storageScopeDigest.prefix(32)).lowercased()
        let parts = [8, 4, 4, 4, 12]
        var index = hex.startIndex
        var values: [Substring] = []
        for length in parts {
            guard let end = hex.index(index, offsetBy: length, limitedBy: hex.endIndex) else {
                preconditionFailure("workspace authority storage digest must contain 32 hex characters")
            }
            values.append(hex[index ..< end])
            index = end
        }
        guard index == hex.endIndex,
              hex.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
              let scopeID = UUID(uuidString: values.map(String.init).joined(separator: "-"))
        else {
            preconditionFailure("workspace authority storage digest must be lowercase SHA-256")
        }
        return scopeID
    }
}

package struct DomainWorkspaceStatefulRustPublication: Sendable {
    package let receipt: CoreWorkspaceProjectionPublicationReceipt
    package let checkpoint: Data?
}

/// P5-2c's single-writer client over one runtime-partitioned Rust projection scope. Every observed
/// document is committed under exact generation CAS, then resolved from an immutable snapshot of
/// that same generation. This remains comparison-only; Swift production reads are unchanged.
package actor DomainWorkspaceStatefulRustProjector {
    private let scopeID: UUID
    private let coreService: AgentryCoreService
    private let maximumRetainedWorkspaceCount: Int
    private var scope: CoreWorkspaceProjectionScope?
    private var generation: UInt64 = 0
    private var catalogRevision: UInt64 = 0
    private var publicationSequence: UInt64 = 0
    private var accessSequence: UInt64 = 0
    private var lastAccessSequenceByWorkspaceID: [UUID: UInt64] = [:]
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStopped = false

    package init(
        scopeID: UUID,
        coreService: AgentryCoreService = .shared,
        maximumRetainedWorkspaceCount: Int = 128
    ) {
        precondition(maximumRetainedWorkspaceCount > 0)
        self.scopeID = scopeID
        self.coreService = coreService
        self.maximumRetainedWorkspaceCount = maximumRetainedWorkspaceCount
    }

    package func project(documentBytes: Data) async throws -> DomainWorkspaceDocumentReadProjection {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        let workspaceID = try workspaceID(documentBytes: documentBytes)
        let scope = try await requireScope()
        if lastAccessSequenceByWorkspaceID[workspaceID] == nil,
           lastAccessSequenceByWorkspaceID.count >= maximumRetainedWorkspaceCount
        {
            _ = try await evictLeastRecentlyUsedWorkspace(excluding: workspaceID, from: scope)
        }
        let receipt: CoreWorkspaceProjectionMutationReceipt
        while true {
            do {
                try Task.checkCancellation()
                receipt = try await scope.upsertDocument(
                    expectedGeneration: generation,
                    document: documentBytes
                )
                break
            } catch CoreBridgeError.workspaceProjectionCapacityExceeded {
                guard try await evictLeastRecentlyUsedWorkspace(excluding: workspaceID, from: scope) else {
                    throw CoreBridgeError.workspaceProjectionCapacityExceeded
                }
            }
        }
        generation = receipt.generation
        touch(workspaceID)
        let snapshot = try await scope.openSnapshot(expectedGeneration: generation)
        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let page = try await snapshot.page(offset: offset, limit: 64)
                if let workspace = page.workspaces.first(where: { $0.workspaceID == workspaceID }) {
                    await snapshot.close()
                    return DomainWorkspaceRustProjection.domainProjection(workspace)
                }
                guard page.hasMore else {
                    throw DomainWorkspaceStatefulRustProjectionError.missingWorkspace(workspaceID)
                }
                guard page.returnedCount > 0 else {
                    throw DomainWorkspaceStatefulRustProjectionError.invalidPageProgress
                }
                let next = offset.addingReportingOverflow(page.returnedCount)
                guard !next.overflow else {
                    throw DomainWorkspaceStatefulRustProjectionError.invalidPageProgress
                }
                offset = next.partialValue
            }
        } catch {
            await snapshot.close()
            throw error
        }
    }

    package func publish(
        documents: [DomainWorkspaceDocument],
        event: DomainWorkspaceEvent
    ) async throws -> DomainWorkspaceStatefulRustPublication {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        let scope = try await requireScope()
        let nextSequence = publicationSequence.addingReportingOverflow(1)
        let hasContinuousCursor = publicationSequence > 0
            && !nextSequence.overflow
            && event.sequence == nextSequence.partialValue
            && event.catalogRevision >= catalogRevision
        try Task.checkCancellation()
        let receipt = try await scope.publish(
            expectedGeneration: generation,
            expectedCatalogRevision: catalogRevision,
            expectedPublicationSequence: publicationSequence,
            rebased: !hasContinuousCursor,
            documents: documents.map(\.documentBytes),
            event: CoreWorkspaceProjectionPublicationEvent(
                sequence: event.sequence,
                catalogRevision: event.catalogRevision,
                kind: corePublicationKind(event.kind),
                workspaceID: event.workspaceID,
                contextID: event.contextID,
                operationID: event.operationID,
                revisions: event.revisions.map {
                    CoreWorkspaceProjectionRevisionState(
                        workingRevision: $0.workingRevision,
                        savedRevision: $0.savedRevision,
                        dirtyRevision: $0.dirtyRevision
                    )
                }
            )
        )
        generation = receipt.generation
        catalogRevision = receipt.catalogRevision
        publicationSequence = receipt.publicationSequence
        accessSequence = 0
        lastAccessSequenceByWorkspaceID.removeAll(keepingCapacity: true)
        for document in documents.sorted(by: { $0.workspaceID.uuidString < $1.workspaceID.uuidString }) {
            touch(document.workspaceID)
        }
        let checkpoint = try? await scope.exportCheckpoint()
        return DomainWorkspaceStatefulRustPublication(
            receipt: receipt,
            checkpoint: checkpoint
        )
    }

    package func prepare() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        _ = try await requireScope()
    }

    package func restoreCheckpointForNewPublicationEpoch(
        _ checkpoint: Data
    ) async throws -> CoreWorkspaceProjectionCheckpointRestoreReceipt {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        let scope = try await requireScope()
        let receipt = try await scope.restoreCheckpoint(
            checkpoint,
            beginNewPublicationEpoch: true
        )
        generation = receipt.generation
        catalogRevision = receipt.catalogRevision
        publicationSequence = receipt.publicationSequence
        accessSequence = 0
        lastAccessSequenceByWorkspaceID.removeAll(keepingCapacity: true)
        return receipt
    }

    package func shutdown() async {
        await acquireOperation()
        defer { releaseOperation() }
        isStopped = true
        let scope = scope
        self.scope = nil
        generation = 0
        catalogRevision = 0
        publicationSequence = 0
        accessSequence = 0
        lastAccessSequenceByWorkspaceID.removeAll()
        await scope?.close()
    }

    private func acquireOperation() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private func evictLeastRecentlyUsedWorkspace(
        excluding workspaceID: UUID,
        from scope: CoreWorkspaceProjectionScope
    ) async throws -> Bool {
        guard let eviction = lastAccessSequenceByWorkspaceID
            .filter({ $0.key != workspaceID })
            .min(by: { left, right in
                if left.value == right.value {
                    return left.key.uuidString < right.key.uuidString
                }
                return left.value < right.value
            })?.key
        else { return false }
        try Task.checkCancellation()
        let receipt = try await scope.removeWorkspace(
            expectedGeneration: generation,
            workspaceID: eviction
        )
        generation = receipt.generation
        lastAccessSequenceByWorkspaceID.removeValue(forKey: eviction)
        return true
    }

    private func touch(_ workspaceID: UUID) {
        if accessSequence == .max {
            let ordered = lastAccessSequenceByWorkspaceID.sorted {
                if $0.value == $1.value {
                    return $0.key.uuidString < $1.key.uuidString
                }
                return $0.value < $1.value
            }
            lastAccessSequenceByWorkspaceID.removeAll(keepingCapacity: true)
            for (index, entry) in ordered.enumerated() {
                lastAccessSequenceByWorkspaceID[entry.key] = UInt64(index + 1)
            }
            accessSequence = UInt64(ordered.count)
        }
        accessSequence += 1
        lastAccessSequenceByWorkspaceID[workspaceID] = accessSequence
    }

    private func requireScope() async throws -> CoreWorkspaceProjectionScope {
        guard !isStopped else { throw DomainWorkspaceStatefulRustProjectionError.stopped }
        if let scope { return scope }
        let opened = try await coreService.workspaceProjectionScope(scopeID: scopeID)
        guard !isStopped else {
            await opened.close()
            throw DomainWorkspaceStatefulRustProjectionError.stopped
        }
        scope = opened
        return opened
    }

    private func corePublicationKind(
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

    private func workspaceID(documentBytes: Data) throws -> UUID {
        guard let object = try JSONSerialization.jsonObject(with: documentBytes) as? [String: Any],
              let rawID = object["id"] as? String,
              let workspaceID = UUID(uuidString: rawID)
        else {
            throw DomainWorkspaceStatefulRustProjectionError.invalidWorkspaceIdentity
        }
        return workspaceID
    }
}

/// P5-1a comparison-only Rust projector. Swift remains the production document/read authority.
package enum DomainWorkspaceRustProjection {
    package static func swiftProjection(
        _ document: DomainWorkspaceDocument
    ) throws -> DomainWorkspaceDocumentReadProjection {
        let metadata = document.metadata
        return DomainWorkspaceDocumentReadProjection(
            workspaceID: document.workspaceID,
            schemaVersion: metadata.schemaVersion,
            name: metadata.name,
            repoPaths: metadata.repoPaths,
            activeContextID: metadata.activeContextID,
            contexts: try metadata.contexts.map { context in
                guard let object = try JSONSerialization.jsonObject(
                    with: context.documentBytes
                ) as? [String: Any] else {
                    throw DomainWorkspaceSwiftProjectionError.invalidContextDocument(
                        context.identity.contextID
                    )
                }
                return DomainWorkspaceContextReadProjection(
                    contextID: context.identity.contextID,
                    name: context.name,
                    activeAgentSessionID: context.activeAgentSessionID,
                    activeChatSessionID: context.activeChatSessionID,
                    prompt: object["prompt"] as? String ?? "",
                    selection: object["selectedPaths"] as? [String]
                        ?? object["selection"] as? [String]
                        ?? []
                )
            }
        )
    }

    package static func mismatchFields(
        expected: DomainWorkspaceDocumentReadProjection,
        actual: DomainWorkspaceDocumentReadProjection
    ) -> Set<DomainWorkspaceProjectionMismatchField> {
        var fields = Set<DomainWorkspaceProjectionMismatchField>()
        if expected.workspaceID != actual.workspaceID { fields.insert(.workspaceID) }
        if expected.schemaVersion != actual.schemaVersion { fields.insert(.schemaVersion) }
        if expected.name != actual.name { fields.insert(.name) }
        if expected.repoPaths != actual.repoPaths { fields.insert(.repoPaths) }
        if expected.activeContextID != actual.activeContextID { fields.insert(.activeContextID) }
        if expected.contexts.count != actual.contexts.count { fields.insert(.contextCount) }

        let expectedIDs = expected.contexts.map(\.contextID)
        let actualIDs = actual.contexts.map(\.contextID)
        if expectedIDs != actualIDs { fields.insert(.contextOrder) }
        var expectedByID: [UUID: DomainWorkspaceContextReadProjection] = [:]
        for context in expected.contexts {
            if expectedByID.updateValue(context, forKey: context.contextID) != nil {
                fields.insert(.contextOrder)
            }
        }
        var actualByID: [UUID: DomainWorkspaceContextReadProjection] = [:]
        for context in actual.contexts {
            if actualByID.updateValue(context, forKey: context.contextID) != nil {
                fields.insert(.contextOrder)
            }
        }
        for contextID in Set(expectedByID.keys).intersection(actualByID.keys) {
            guard let expectedContext = expectedByID[contextID],
                  let actualContext = actualByID[contextID]
            else { continue }
            if expectedContext.name != actualContext.name { fields.insert(.contextName) }
            if expectedContext.activeAgentSessionID != actualContext.activeAgentSessionID {
                fields.insert(.contextActiveAgentSessionID)
            }
            if expectedContext.activeChatSessionID != actualContext.activeChatSessionID {
                fields.insert(.contextActiveChatSessionID)
            }
            if expectedContext.prompt != actualContext.prompt { fields.insert(.contextPrompt) }
            if expectedContext.selection != actualContext.selection { fields.insert(.contextSelection) }
        }
        return fields
    }

    package static func project(
        documentBytes: Data,
        coreService: AgentryCoreService = .shared
    ) async throws -> DomainWorkspaceDocumentReadProjection {
        let client = try await coreService.computeClient()
        let projected = try await client.projectWorkspaceDocumentV1(documentBytes)
        return domainProjection(projected)
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
}
