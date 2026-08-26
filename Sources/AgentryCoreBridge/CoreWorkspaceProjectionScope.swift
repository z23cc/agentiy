import AgentryUniFFIRaw
import Foundation
import os

/// P5-2b bounds for one explicitly partitioned Rust workspace projection scope.
public struct CoreWorkspaceProjectionScopeConfiguration: Sendable, Equatable {
    public var maximumWorkspaceCount: UInt64
    public var maximumRetainedBytes: UInt64
    public var maximumSnapshotHandleCount: UInt64

    public init(
        maximumWorkspaceCount: UInt64 = 256,
        maximumRetainedBytes: UInt64 = 64 * 1024 * 1024,
        maximumSnapshotHandleCount: UInt64 = 64
    ) {
        self.maximumWorkspaceCount = maximumWorkspaceCount
        self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumSnapshotHandleCount = maximumSnapshotHandleCount
    }
}

public struct CoreWorkspaceProjectionMutationReceipt: Sendable, Equatable {
    public let previousGeneration: UInt64
    public let generation: UInt64
    public let changed: Bool
    public let workspaceCount: UInt64
    public let retainedBytes: UInt64
}

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

public struct CoreWorkspaceProjectionPublicationReceipt: Sendable, Equatable {
    public let previousGeneration: UInt64
    public let generation: UInt64
    public let projectionChanged: Bool
    public let workspaceCount: UInt64
    public let retainedBytes: UInt64
    public let previousCatalogRevision: UInt64
    public let previousPublicationSequence: UInt64
    public let catalogRevision: UInt64
    public let publicationSequence: UInt64
    public let eventLogFloorSequence: UInt64
    public let eventLogCount: UInt64
    public let rebased: Bool
}

public struct CoreWorkspaceProjectionCheckpointRestoreReceipt: Sendable, Equatable {
    public let generation: UInt64
    public let workspaceCount: UInt64
    public let retainedBytes: UInt64
    public let catalogRevision: UInt64
    public let publicationSequence: UInt64
    public let eventLogFloorSequence: UInt64
    public let eventLogCount: UInt64
    public let beganNewPublicationEpoch: Bool
}

public struct CoreWorkspaceProjectionDiagnostics: Sendable, Equatable {
    public let generation: UInt64
    public let openSnapshotHandleCount: UInt64
    public let catalogRevision: UInt64
    public let publicationSequence: UInt64
    public let eventLogFloorSequence: UInt64
    public let eventLogCount: UInt64
}

public struct CoreWorkspaceProjectionSnapshotPage: Sendable, Equatable {
    public let generation: UInt64
    public let offset: UInt64
    public let returnedCount: UInt64
    public let hasMore: Bool
    public let workspaces: [CoreWorkspaceDocumentProjectionV1]
}

extension AgentryCoreBridge {
    func workspaceProjectionOpenScopeV1(
        scopeID: UUID,
        configuration: CoreWorkspaceProjectionScopeConfiguration
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionScopeHandleV1 {
        let identity = try requireIdentity()
        let rawIdentity = coreWorkspaceProjectionRawIdentity(identity)
        do {
            return try transport.workspaceProjectionOpenScopeV1(
                identity: identity,
                config: .init(
                    runtimeIdentity: rawIdentity,
                    scopeId: scopeID.uuidString.lowercased(),
                    maximumWorkspaceCount: configuration.maximumWorkspaceCount,
                    maximumRetainedBytes: configuration.maximumRetainedBytes,
                    maximumSnapshotHandleCount: configuration.maximumSnapshotHandleCount
                )
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionCloseScopeV1(scopeID: String, scopeIncarnation: UInt64) throws {
        let identity = try requireIdentity()
        do {
            try transport.workspaceProjectionCloseScopeV1(
                identity: identity,
                scopeID: scopeID,
                scopeIncarnation: scopeIncarnation
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionReplaceV1(
        scopeID: String,
        scopeIncarnation: UInt64,
        expectedGeneration: UInt64,
        documents: [Data]
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.workspaceProjectionReplaceV1(
                identity: identity,
                request: .init(
                    runtimeIdentity: coreWorkspaceProjectionRawIdentity(identity),
                    scopeId: scopeID,
                    scopeIncarnation: scopeIncarnation,
                    expectedGeneration: expectedGeneration,
                    documentBytes: documents
                )
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionUpsertV1(
        scopeID: String,
        scopeIncarnation: UInt64,
        expectedGeneration: UInt64,
        document: Data
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.workspaceProjectionUpsertV1(
                identity: identity,
                request: .init(
                    runtimeIdentity: coreWorkspaceProjectionRawIdentity(identity),
                    scopeId: scopeID,
                    scopeIncarnation: scopeIncarnation,
                    expectedGeneration: expectedGeneration,
                    documentBytes: document
                )
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionPublishV1(
        scopeID: String,
        scopeIncarnation: UInt64,
        expectedGeneration: UInt64,
        expectedCatalogRevision: UInt64,
        expectedPublicationSequence: UInt64,
        rebased: Bool,
        documents: [Data],
        event: CoreWorkspaceProjectionPublicationEvent
    ) async throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionPublicationReceiptV1 {
        let identity = try requireIdentity()
        let transport = transport
        do {
            let receipt = try await Task.detached(priority: .utility) {
                try transport.workspaceProjectionPublishV1(
                    identity: identity,
                    request: .init(
                        runtimeIdentity: coreWorkspaceProjectionRawIdentity(identity),
                        scopeId: scopeID,
                        scopeIncarnation: scopeIncarnation,
                        expectedGeneration: expectedGeneration,
                        expectedCatalogRevision: expectedCatalogRevision,
                        expectedPublicationSequence: expectedPublicationSequence,
                        rebased: rebased,
                        documentBytes: documents,
                        event: coreWorkspaceProjectionRawPublicationEvent(event)
                    )
                )
            }.value
            try validateWorkspaceProjectionCompletion(identity: identity)
            return receipt
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionRemoveV1(
        scopeID: String,
        scopeIncarnation: UInt64,
        expectedGeneration: UInt64,
        workspaceID: UUID
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.workspaceProjectionRemoveV1(
                identity: identity,
                request: .init(
                    runtimeIdentity: coreWorkspaceProjectionRawIdentity(identity),
                    scopeId: scopeID,
                    scopeIncarnation: scopeIncarnation,
                    expectedGeneration: expectedGeneration,
                    workspaceId: workspaceID.uuidString.lowercased()
                )
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionExportCheckpointV1(
        scopeID: String,
        scopeIncarnation: UInt64
    ) async throws -> Data {
        let identity = try requireIdentity()
        let transport = transport
        do {
            let checkpoint = try await Task.detached(priority: .utility) {
                try transport.workspaceProjectionExportCheckpointV1(
                    identity: identity,
                    scopeID: scopeID,
                    scopeIncarnation: scopeIncarnation
                )
            }.value
            try validateWorkspaceProjectionCompletion(identity: identity)
            return checkpoint
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionRestoreCheckpointV1(
        scopeID: String,
        scopeIncarnation: UInt64,
        checkpoint: Data,
        beginNewPublicationEpoch: Bool
    ) async throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionRestoreCheckpointReceiptV1 {
        let identity = try requireIdentity()
        let transport = transport
        do {
            let receipt = try await Task.detached(priority: .utility) {
                try transport.workspaceProjectionRestoreCheckpointV1(
                    identity: identity,
                    request: .init(
                        runtimeIdentity: coreWorkspaceProjectionRawIdentity(identity),
                        scopeId: scopeID,
                        scopeIncarnation: scopeIncarnation,
                        checkpointBytes: checkpoint,
                        beginNewPublicationEpoch: beginNewPublicationEpoch
                    )
                )
            }.value
            try validateWorkspaceProjectionCompletion(identity: identity)
            return receipt
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionOpenSnapshotV1(
        scopeID: String,
        scopeIncarnation: UInt64,
        expectedGeneration: UInt64?
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionSnapshotHandleV1 {
        let identity = try requireIdentity()
        do {
            return try transport.workspaceProjectionOpenSnapshotV1(
                identity: identity,
                request: .init(
                    runtimeIdentity: coreWorkspaceProjectionRawIdentity(identity),
                    scopeId: scopeID,
                    scopeIncarnation: scopeIncarnation,
                    expectedGeneration: expectedGeneration
                )
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionSnapshotPageV1(
        scopeID: String,
        scopeIncarnation: UInt64,
        handleID: UInt64,
        offset: UInt64,
        limit: UInt64
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionSnapshotPageV1 {
        let identity = try requireIdentity()
        do {
            return try transport.workspaceProjectionSnapshotPageV1(
                identity: identity,
                scopeID: scopeID,
                scopeIncarnation: scopeIncarnation,
                handleID: handleID,
                offset: offset,
                limit: limit
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionCloseSnapshotV1(
        scopeID: String,
        scopeIncarnation: UInt64,
        handleID: UInt64
    ) throws {
        let identity = try requireIdentity()
        do {
            try transport.workspaceProjectionCloseSnapshotV1(
                identity: identity,
                scopeID: scopeID,
                scopeIncarnation: scopeIncarnation,
                handleID: handleID
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func workspaceProjectionDiagnosticsV1(
        scopeID: String,
        scopeIncarnation: UInt64
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionDiagnosticsV1 {
        let identity = try requireIdentity()
        do {
            return try transport.workspaceProjectionDiagnosticsV1(
                identity: identity,
                scopeID: scopeID,
                scopeIncarnation: scopeIncarnation
            )
        } catch {
            throw mapTransportError(error)
        }
    }
}

/// Bridge-owned scope facade. `scopeID` must be the owning domain runtime's explicit identity;
/// process-wide Rust state is never shared implicitly between domain profiles.
public final class CoreWorkspaceProjectionScope: @unchecked Sendable {
    private let bridge: AgentryCoreBridge
    public let scopeID: UUID
    private let rawScopeID: String
    private let scopeIncarnation: UInt64
    private let closedFlag = OSAllocatedUnfairLock(initialState: false)

    private init(
        bridge: AgentryCoreBridge,
        scopeID: UUID,
        rawScopeID: String,
        scopeIncarnation: UInt64
    ) {
        self.bridge = bridge
        self.scopeID = scopeID
        self.rawScopeID = rawScopeID
        self.scopeIncarnation = scopeIncarnation
    }

    public static func open(
        bridge: AgentryCoreBridge,
        scopeID: UUID,
        configuration: CoreWorkspaceProjectionScopeConfiguration = .init()
    ) async throws -> CoreWorkspaceProjectionScope {
        let handle = try await bridge.workspaceProjectionOpenScopeV1(
            scopeID: scopeID, configuration: configuration
        )
        let canonicalScopeID = scopeID.uuidString.lowercased()
        guard let returnedScopeID = UUID(uuidString: handle.scopeId), returnedScopeID == scopeID,
              handle.scopeIncarnation > 0,
              handle.generation == 0
        else {
            try? await bridge.workspaceProjectionCloseScopeV1(
                scopeID: canonicalScopeID,
                scopeIncarnation: handle.scopeIncarnation
            )
            throw CoreBridgeError.invalidArgument
        }
        return CoreWorkspaceProjectionScope(
            bridge: bridge,
            scopeID: scopeID,
            rawScopeID: handle.scopeId,
            scopeIncarnation: handle.scopeIncarnation
        )
    }

    public func replaceDocuments(
        expectedGeneration: UInt64,
        documents: [Data]
    ) async throws -> CoreWorkspaceProjectionMutationReceipt {
        try ensureOpen()
        return try coreWorkspaceProjectionMutationReceipt(
            await bridge.workspaceProjectionReplaceV1(
                scopeID: rawScopeID,
                scopeIncarnation: scopeIncarnation,
                expectedGeneration: expectedGeneration,
                documents: documents
            ),
            expectedPreviousGeneration: expectedGeneration
        )
    }

    public func upsertDocument(
        expectedGeneration: UInt64,
        document: Data
    ) async throws -> CoreWorkspaceProjectionMutationReceipt {
        try ensureOpen()
        return try coreWorkspaceProjectionMutationReceipt(
            await bridge.workspaceProjectionUpsertV1(
                scopeID: rawScopeID,
                scopeIncarnation: scopeIncarnation,
                expectedGeneration: expectedGeneration,
                document: document
            ),
            expectedPreviousGeneration: expectedGeneration
        )
    }

    public func publish(
        expectedGeneration: UInt64,
        expectedCatalogRevision: UInt64,
        expectedPublicationSequence: UInt64,
        rebased: Bool,
        documents: [Data],
        event: CoreWorkspaceProjectionPublicationEvent
    ) async throws -> CoreWorkspaceProjectionPublicationReceipt {
        try ensureOpen()
        let raw = try await bridge.workspaceProjectionPublishV1(
            scopeID: rawScopeID,
            scopeIncarnation: scopeIncarnation,
            expectedGeneration: expectedGeneration,
            expectedCatalogRevision: expectedCatalogRevision,
            expectedPublicationSequence: expectedPublicationSequence,
            rebased: rebased,
            documents: documents,
            event: event
        )
        let expectedNextGeneration = expectedGeneration.addingReportingOverflow(1)
        let generationIsValid = if raw.projectionChanged {
            !expectedNextGeneration.overflow && raw.generation == expectedNextGeneration.partialValue
        } else {
            raw.generation == expectedGeneration
        }
        guard raw.previousGeneration == expectedGeneration,
              generationIsValid,
              raw.workspaceCount == UInt64(documents.count),
              raw.previousCatalogRevision == expectedCatalogRevision,
              raw.previousPublicationSequence == expectedPublicationSequence,
              raw.catalogRevision == event.catalogRevision,
              raw.publicationSequence == event.sequence,
              raw.eventLogCount > 0,
              raw.eventLogCount <= 256,
              raw.eventLogFloorSequence > 0,
              raw.eventLogFloorSequence <= raw.publicationSequence,
              raw.publicationSequence - raw.eventLogFloorSequence + 1 == raw.eventLogCount,
              raw.rebased == rebased
        else {
            throw CoreBridgeError.invalidArgument
        }
        return CoreWorkspaceProjectionPublicationReceipt(
            previousGeneration: raw.previousGeneration,
            generation: raw.generation,
            projectionChanged: raw.projectionChanged,
            workspaceCount: raw.workspaceCount,
            retainedBytes: raw.retainedBytes,
            previousCatalogRevision: raw.previousCatalogRevision,
            previousPublicationSequence: raw.previousPublicationSequence,
            catalogRevision: raw.catalogRevision,
            publicationSequence: raw.publicationSequence,
            eventLogFloorSequence: raw.eventLogFloorSequence,
            eventLogCount: raw.eventLogCount,
            rebased: raw.rebased
        )
    }

    public func removeWorkspace(
        expectedGeneration: UInt64,
        workspaceID: UUID
    ) async throws -> CoreWorkspaceProjectionMutationReceipt {
        try ensureOpen()
        return try coreWorkspaceProjectionMutationReceipt(
            await bridge.workspaceProjectionRemoveV1(
                scopeID: rawScopeID,
                scopeIncarnation: scopeIncarnation,
                expectedGeneration: expectedGeneration,
                workspaceID: workspaceID
            ),
            expectedPreviousGeneration: expectedGeneration
        )
    }

    public func exportCheckpoint() async throws -> Data {
        try ensureOpen()
        let checkpoint = try await bridge.workspaceProjectionExportCheckpointV1(
            scopeID: rawScopeID,
            scopeIncarnation: scopeIncarnation
        )
        guard checkpoint.count <= 128 * 1024 * 1024 else {
            throw CoreBridgeError.workspaceProjectionCapacityExceeded
        }
        return checkpoint
    }

    public func restoreCheckpoint(
        _ checkpoint: Data,
        beginNewPublicationEpoch: Bool
    ) async throws -> CoreWorkspaceProjectionCheckpointRestoreReceipt {
        try ensureOpen()
        guard checkpoint.count <= 128 * 1024 * 1024 else {
            throw CoreBridgeError.workspaceProjectionCapacityExceeded
        }
        let raw = try await bridge.workspaceProjectionRestoreCheckpointV1(
            scopeID: rawScopeID,
            scopeIncarnation: scopeIncarnation,
            checkpoint: checkpoint,
            beginNewPublicationEpoch: beginNewPublicationEpoch
        )
        let logIsValid = if raw.eventLogCount == 0 {
            raw.publicationSequence == 0 && raw.eventLogFloorSequence == 1
        } else {
            raw.eventLogCount <= 256
                && raw.eventLogFloorSequence > 0
                && raw.eventLogFloorSequence <= raw.publicationSequence
                && raw.publicationSequence - raw.eventLogFloorSequence + 1 == raw.eventLogCount
        }
        guard raw.workspaceCount <= 256,
              raw.retainedBytes <= 64 * 1024 * 1024,
              raw.beganNewPublicationEpoch == beginNewPublicationEpoch,
              logIsValid,
              !beginNewPublicationEpoch || (
                  raw.catalogRevision == 0
                      && raw.publicationSequence == 0
                      && raw.eventLogCount == 0
              )
        else {
            throw CoreBridgeError.invalidArgument
        }
        return CoreWorkspaceProjectionCheckpointRestoreReceipt(
            generation: raw.generation,
            workspaceCount: raw.workspaceCount,
            retainedBytes: raw.retainedBytes,
            catalogRevision: raw.catalogRevision,
            publicationSequence: raw.publicationSequence,
            eventLogFloorSequence: raw.eventLogFloorSequence,
            eventLogCount: raw.eventLogCount,
            beganNewPublicationEpoch: raw.beganNewPublicationEpoch
        )
    }

    public func openSnapshot(expectedGeneration: UInt64? = nil) async throws -> CoreWorkspaceProjectionSnapshot {
        try ensureOpen()
        let handle = try await bridge.workspaceProjectionOpenSnapshotV1(
            scopeID: rawScopeID,
            scopeIncarnation: scopeIncarnation,
            expectedGeneration: expectedGeneration
        )
        guard handle.handleId > 0,
              expectedGeneration.map({ $0 == handle.generation }) ?? true
        else {
            try? await bridge.workspaceProjectionCloseSnapshotV1(
                scopeID: rawScopeID,
                scopeIncarnation: scopeIncarnation,
                handleID: handle.handleId
            )
            throw CoreBridgeError.invalidArgument
        }
        return CoreWorkspaceProjectionSnapshot(
            bridge: bridge,
            scopeID: rawScopeID,
            scopeIncarnation: scopeIncarnation,
            handleID: handle.handleId,
            generation: handle.generation,
            workspaceCount: handle.workspaceCount,
            retainedBytes: handle.retainedBytes
        )
    }

    public func diagnostics() async throws -> CoreWorkspaceProjectionDiagnostics {
        try ensureOpen()
        let value = try await bridge.workspaceProjectionDiagnosticsV1(
            scopeID: rawScopeID,
            scopeIncarnation: scopeIncarnation
        )
        return CoreWorkspaceProjectionDiagnostics(
            generation: value.generation,
            openSnapshotHandleCount: value.openSnapshotHandleCount,
            catalogRevision: value.catalogRevision,
            publicationSequence: value.publicationSequence,
            eventLogFloorSequence: value.eventLogFloorSequence,
            eventLogCount: value.eventLogCount
        )
    }

    public func close() async {
        let alreadyClosed = closedFlag.withLock { flag -> Bool in
            let wasClosed = flag
            flag = true
            return wasClosed
        }
        guard !alreadyClosed else { return }
        try? await bridge.workspaceProjectionCloseScopeV1(
            scopeID: rawScopeID,
            scopeIncarnation: scopeIncarnation
        )
    }

    private func ensureOpen() throws {
        guard !closedFlag.withLock({ $0 }) else {
            throw CoreBridgeError.workspaceProjectionScopeClosed
        }
    }

    deinit {
        let alreadyClosed = closedFlag.withLock { flag -> Bool in
            let wasClosed = flag
            flag = true
            return wasClosed
        }
        guard !alreadyClosed else { return }
        let bridge = bridge
        let rawScopeID = rawScopeID
        let scopeIncarnation = scopeIncarnation
        Task {
            try? await bridge.workspaceProjectionCloseScopeV1(
                scopeID: rawScopeID,
                scopeIncarnation: scopeIncarnation
            )
        }
    }
}

/// ARC lease over one immutable Rust workspace projection generation.
public final class CoreWorkspaceProjectionSnapshot: @unchecked Sendable {
    private let bridge: AgentryCoreBridge
    private let scopeID: String
    private let scopeIncarnation: UInt64
    private let handleID: UInt64
    public let generation: UInt64
    public let workspaceCount: UInt64
    public let retainedBytes: UInt64
    private let closedFlag = OSAllocatedUnfairLock(initialState: false)

    fileprivate init(
        bridge: AgentryCoreBridge,
        scopeID: String,
        scopeIncarnation: UInt64,
        handleID: UInt64,
        generation: UInt64,
        workspaceCount: UInt64,
        retainedBytes: UInt64
    ) {
        self.bridge = bridge
        self.scopeID = scopeID
        self.scopeIncarnation = scopeIncarnation
        self.handleID = handleID
        self.generation = generation
        self.workspaceCount = workspaceCount
        self.retainedBytes = retainedBytes
    }

    public func page(offset: UInt64, limit: UInt64) async throws -> CoreWorkspaceProjectionSnapshotPage {
        guard limit > 0 else { throw CoreBridgeError.invalidArgument }
        try ensureOpen()
        let raw = try await bridge.workspaceProjectionSnapshotPageV1(
            scopeID: scopeID,
            scopeIncarnation: scopeIncarnation,
            handleID: handleID,
            offset: offset,
            limit: limit
        )
        let expectedOffset = min(offset, workspaceCount)
        let (endOffset, offsetOverflowed) = raw.offset.addingReportingOverflow(raw.returnedCount)
        guard raw.generation == generation,
              raw.offset == expectedOffset,
              raw.returnedCount == UInt64(raw.workspaces.count),
              raw.returnedCount <= limit,
              !offsetOverflowed,
              endOffset <= workspaceCount,
              raw.hasMore == (endOffset < workspaceCount)
        else {
            throw CoreBridgeError.invalidArgument
        }
        return CoreWorkspaceProjectionSnapshotPage(
            generation: raw.generation,
            offset: raw.offset,
            returnedCount: raw.returnedCount,
            hasMore: raw.hasMore,
            workspaces: try raw.workspaces.map(coreWorkspaceDocumentProjection)
        )
    }

    public func close() async {
        let alreadyClosed = closedFlag.withLock { flag -> Bool in
            let wasClosed = flag
            flag = true
            return wasClosed
        }
        guard !alreadyClosed else { return }
        try? await bridge.workspaceProjectionCloseSnapshotV1(
            scopeID: scopeID,
            scopeIncarnation: scopeIncarnation,
            handleID: handleID
        )
    }

    private func ensureOpen() throws {
        guard !closedFlag.withLock({ $0 }) else {
            throw CoreBridgeError.workspaceProjectionUnknownSnapshotHandle
        }
    }

    deinit {
        let alreadyClosed = closedFlag.withLock { flag -> Bool in
            let wasClosed = flag
            flag = true
            return wasClosed
        }
        guard !alreadyClosed else { return }
        let bridge = bridge
        let scopeID = scopeID
        let scopeIncarnation = scopeIncarnation
        let handleID = handleID
        Task {
            try? await bridge.workspaceProjectionCloseSnapshotV1(
                scopeID: scopeID,
                scopeIncarnation: scopeIncarnation,
                handleID: handleID
            )
        }
    }
}

private func coreWorkspaceProjectionMutationReceipt(
    _ raw: AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1,
    expectedPreviousGeneration: UInt64
) throws -> CoreWorkspaceProjectionMutationReceipt {
    let expectedGeneration = raw.previousGeneration.addingReportingOverflow(1)
    guard raw.previousGeneration == expectedPreviousGeneration,
          raw.changed
          ? (!expectedGeneration.overflow && raw.generation == expectedGeneration.partialValue)
          : raw.generation == raw.previousGeneration
    else {
        throw CoreBridgeError.invalidArgument
    }
    return CoreWorkspaceProjectionMutationReceipt(
        previousGeneration: raw.previousGeneration,
        generation: raw.generation,
        changed: raw.changed,
        workspaceCount: raw.workspaceCount,
        retainedBytes: raw.retainedBytes
    )
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
    return CoreWorkspaceDocumentProjectionV1(
        workspaceID: workspaceID,
        schemaVersion: schemaVersion,
        name: value.name,
        repoPaths: value.repoPaths,
        activeContextID: try optionalUUID(value.activeContextId),
        contexts: contexts
    )
}

private func coreWorkspaceProjectionRawPublicationEvent(
    _ event: CoreWorkspaceProjectionPublicationEvent
) -> AgentryUniFFIRaw.CoreWorkspaceProjectionPublicationEventV1 {
    let kind: AgentryUniFFIRaw.CoreWorkspaceProjectionPublicationKindV1
    switch event.kind {
    case .bootstrapped: kind = .bootstrapped
    case .workspaceCreated: kind = .workspaceCreated
    case .workspaceDeleted: kind = .workspaceDeleted
    case .workingStateCommitted: kind = .workingStateCommitted
    case .savedDocumentCommitted: kind = .savedDocumentCommitted
    case .externalReloaded: kind = .externalReloaded
    case .externalConflict: kind = .externalConflict
    case .degraded: kind = .degraded
    case .routingChanged: kind = .routingChanged
    case .operationDeduplicated: kind = .operationDeduplicated
    }
    return .init(
        sequence: event.sequence,
        catalogRevision: event.catalogRevision,
        kind: kind,
        workspaceId: event.workspaceID?.uuidString.lowercased(),
        contextId: event.contextID?.uuidString.lowercased(),
        operationId: event.operationID?.uuidString.lowercased(),
        revisions: event.revisions.map {
            .init(
                workingRevision: $0.workingRevision,
                savedRevision: $0.savedRevision,
                dirtyRevision: $0.dirtyRevision
            )
        }
    )
}

private func coreWorkspaceProjectionRawIdentity(
    _ identity: CoreRuntimeIdentity
) -> AgentryUniFFIRaw.RuntimeIdentity {
    .init(
        abiEpoch: identity.abiEpoch,
        instanceNonce: identity.instanceNonce,
        buildFingerprint: identity.buildFingerprint,
        bindingChecksum: identity.bindingChecksum
    )
}
