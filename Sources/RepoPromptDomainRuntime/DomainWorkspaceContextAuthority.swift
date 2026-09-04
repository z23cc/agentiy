import AgentryCoreBridge
import Foundation
import os

#if DEBUG
    package extension DomainWorkspaceStore {
        static let catalogDirectorySyncTestHooks = OSAllocatedUnfairLock(
            initialState: [String: @Sendable () throws -> Void]()
        )

        static func setCatalogDirectorySyncTestHook(
            for catalogURL: URL,
            _ hook: (@Sendable () throws -> Void)?
        ) {
            catalogDirectorySyncTestHooks.withLock { hooks in
                hooks[catalogURL.standardizedFileURL.path] = hook
            }
        }

        static func takeCatalogDirectorySyncTestHook(
            for catalogURL: URL
        ) -> (@Sendable () throws -> Void)? {
            catalogDirectorySyncTestHooks.withLock { hooks in
                hooks.removeValue(forKey: catalogURL.standardizedFileURL.path)
            }
        }
    }
#endif

package enum DomainExternalReloadActivity: Equatable {
    case changed
    case unchanged
    case recoveryPending
}

package struct DomainWorkspaceStore {
    private let authority: DomainWorkspaceContextAuthority

    init(authority: DomainWorkspaceContextAuthority) {
        self.authority = authority
    }

    package func snapshot() async -> DomainWorkspaceCatalogSnapshot {
        await authority.readySnapshot()
    }

    package func subscribe() async -> DomainWorkspaceSnapshotSubscription {
        await authority.readySubscription()
    }

    package func execute(_ command: DomainWorkspaceCommandEnvelope) async -> DomainCommandOutcome {
        await authority.execute(command)
    }

    /// Typed selection/context mutation seam shared by app presentation and headless adapters.
    /// Callers provide only the candidate and its selection digest fence; the authority constructs
    /// the ordinary command envelope so no adapter can bypass Rust admission or publication.
    package func applySelectionMutation(
        _ request: DomainWorkspaceSelectionMutationRequest,
        operationID: UUID,
        expectedWorkspaceRevision: UInt64? = nil,
        expectedContextRevision: UInt64? = nil,
        origin: DomainCommandOrigin
    ) async -> DomainCommandOutcome {
        await authority.execute(DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedWorkspaceRevision: expectedWorkspaceRevision,
            expectedContextRevision: expectedContextRevision,
            origin: origin,
            command: .replaceSelection(request)
        ))
    }

    package func applyContextMutation(
        _ request: DomainWorkspaceContextMutationRequest,
        operationID: UUID,
        expectedWorkspaceRevision: UInt64? = nil,
        expectedContextRevision: UInt64? = nil,
        origin: DomainCommandOrigin
    ) async -> DomainCommandOutcome {
        await authority.execute(DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedWorkspaceRevision: expectedWorkspaceRevision,
            expectedContextRevision: expectedContextRevision,
            origin: origin,
            command: .replaceContext(request)
        ))
    }

    @discardableResult
    package func reloadExternalChanges() async -> DomainExternalReloadActivity {
        await authority.reloadExternalChanges()
    }

    #if DEBUG
        package func testSetBeforeExternalReconciliation(
            _ hook: (@Sendable (UUID) async -> Void)?
        ) async {
            await authority.testSetBeforeExternalReconciliation(hook)
        }
    #endif

    /// Registers the app's current in-memory document as an awaited read authority.
    ///
    /// This compatibility seam is intentionally transient: it makes newly created and ephemeral
    /// workspaces immediately routable without waiting for debounced durable publication, while
    /// leaving the normal command/persistence path authoritative for mutations.
    package func registerReadDocument(_ document: DomainWorkspaceDocument) async -> DomainWorkspaceSnapshot {
        await authority.registerReadDocument(document)
    }

    package func workspaceSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceSnapshot? {
        await authority.workspaceSnapshot(workspaceID)
    }

    /// Returns only persisted command-authority state. Read registrations are routing overlays and
    /// must not influence mutation admission, recovery CAS baselines, or authority health.
    package func canonicalWorkspaceSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceSnapshot? {
        await authority.canonicalWorkspaceSnapshot(workspaceID)
    }

    package func isWorkspaceQuarantined(_ workspaceID: UUID) async -> Bool {
        await authority.isWorkspaceQuarantined(workspaceID)
    }

    package func quarantinedWorkspaces() async -> [UUID] {
        await authority.quarantinedWorkspaces()
    }
}

package struct DomainWorkspaceReadFence {
    package let workspace: DomainWorkspaceSnapshot
    package let catalogRevision: UInt64
    package let publicationSequence: UInt64
}

package struct DomainWorkspaceAuthoritativeReadFence {
    package let workspace: DomainWorkspaceSnapshot
    package let projection: DomainWorkspaceDocumentReadProjection
    package let generation: UInt64
    package let catalogRevision: UInt64
    package let publicationSequence: UInt64
    package let projectionDigest: String
}

package struct DomainContextStore {
    private let authority: DomainWorkspaceContextAuthority

    init(authority: DomainWorkspaceContextAuthority) {
        self.authority = authority
    }

    package func snapshot(_ identity: DomainContextIdentity) async -> DomainContextSnapshot? {
        await authority.contextSnapshot(identity)
    }

    package func workspaceSnapshot(_ workspaceID: UUID) async -> DomainWorkspaceSnapshot? {
        await authority.workspaceSnapshot(workspaceID)
    }

    package func workspaceReadFence(_ workspaceID: UUID) async -> DomainWorkspaceReadFence? {
        await authority.workspaceReadFence(workspaceID)
    }

    package func workspaceAuthoritativeReadFence(
        _ workspaceID: UUID
    ) async -> DomainWorkspaceAuthoritativeReadFence? {
        await authority.workspaceAuthoritativeReadFence(workspaceID)
    }
}

actor DomainWorkspaceContextAuthority {
    private static let maximumCASRecoveryAttempts = 2

    #if DEBUG
        private var testBeforeExternalReconciliation: (@Sendable (UUID) async -> Void)?
    #endif

    private enum DirtyExternalRebaseResult {
        case applied
        case recoveryPending
        case failed
    }

    /// Acquisition reconciliation must distinguish a complete pass that leaves isolated records
    /// read-only from a globally interrupted pass. Only the former may open command admission.
    private enum ExternalReloadPass {
        case completed(DomainExternalReloadActivity)
        case incomplete

        var activity: DomainExternalReloadActivity {
            switch self {
            case let .completed(activity): activity
            case .incomplete: .recoveryPending
            }
        }

        var completedSuccessfully: Bool {
            if case .completed = self { return true }
            return false
        }
    }

    private struct WorkspaceRecord {
        var document: DomainWorkspaceDocument
        var savedDigest: String
        var revisions: DomainRevisionState
        var contextRevisions: [UUID: DomainRevisionState]
        var contextTombstones: [UUID: UInt64]
        var operations: [DomainRecordedOperation]
        var health: DomainAuthorityHealth
        var externalDocument: DomainWorkspaceDocument?
        var fileMetadata: DomainFileMetadata
    }

    private let identity: DomainRuntimeIdentity
    private let persistence: DomainPersistenceCoordinator
    private let mutationAccess: DomainWorkspaceMutationAccess
    private let workspaceAuthorityScope: DomainWorkspaceAuthorityLeaseScope
    private let metrics: DomainRuntimeMetricsSink
    private let commandIdentityResolver: DomainWorkspaceCommandIdentityResolver?
    private var commandIdentityValidator: DomainWorkspaceRustJournal.PreparedValidator?
    private var commandAdmission: DomainWorkspaceRustJournal.PreparedCommandAdmission?
    private var records: [UUID: WorkspaceRecord] = [:]
    /// Awaited in-memory registrations used only by read routing. They are not catalog entries and
    /// never persist ephemeral/test workspaces. A later command invalidates the overlay.
    private var readRegistrations: [UUID: DomainWorkspaceSnapshot] = [:]
    private var unavailableWorkspaces: [UUID: DomainPersistenceBootstrap.UnavailableWorkspace] = [:]
    private var health: DomainAuthorityHealth = .writable
    private var mutationAccessSnapshot: DomainWorkspaceMutationAccessSnapshot
    private var catalogRevision: UInt64 = 0
    private var publicationSequence: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<DomainWorkspaceEvent>.Continuation] = [:]
    private var bootstrapTask: Task<DomainPersistenceBootstrap, Never>?
    private var commandConvergenceInProgress = false
    private var commandConvergenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var didBootstrap = false

    init(
        identity: DomainRuntimeIdentity,
        persistence: DomainPersistenceCoordinator,
        mutationAccess: DomainWorkspaceMutationAccess,
        metrics: DomainRuntimeMetricsSink,
        commandIdentityResolver: DomainWorkspaceCommandIdentityResolver? = nil
    ) {
        self.identity = identity
        self.persistence = persistence
        self.mutationAccess = mutationAccess
        workspaceAuthorityScope = mutationAccess.scope
        self.metrics = metrics
        self.commandIdentityResolver = commandIdentityResolver
        mutationAccessSnapshot = DomainWorkspaceMutationAccessSnapshot(
            generation: 0,
            state: .unavailable,
            reason: "canonical_storage_lease_not_acquired",
            storageScopeDigest: mutationAccess.scope.storageScopeDigest,
            owner: nil,
            observedContendingOwner: nil,
            activePermitCount: 0
        )
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        let task: Task<DomainPersistenceBootstrap, Never>
        if let bootstrapTask {
            task = bootstrapTask
        } else {
            let persistence = persistence
            let created = Task { await persistence.bootstrap() }
            bootstrapTask = created
            task = created
        }
        let loaded = await task.value
        guard !didBootstrap else { return }
        if let recovery = loaded.semanticRecovery,
           let preview = loaded.semanticPreview
        {
            do {
                let commit = try recovery.commit(expected: preview)
                try installSemanticRecoveryAuthority(commit)
            } catch {
                recovery.close()
                quarantineCommandAdmission()
                health = .degradedReadOnly(reason: "workspace_semantic_recovery_failed")
                catalogRevision = 0
                unavailableWorkspaces = [:]
                records = [:]
                didBootstrap = true
                bootstrapTask = nil
                publish(
                    kind: .degraded,
                    workspaceID: nil,
                    contextID: nil,
                    operationID: nil,
                    revisions: nil,
                    diagnostic: "workspace_semantic_recovery_failed"
                )
                return
            }
        }
        health = health.acceptsMutations ? loaded.health : health
        catalogRevision = loaded.catalogRevision
        unavailableWorkspaces = Dictionary(uniqueKeysWithValues: loaded.unavailableWorkspaces.map {
            ($0.workspaceID, $0)
        })
        records = Dictionary(uniqueKeysWithValues: loaded.workspaces.map { workspace in
            (workspace.document.workspaceID, makeRecord(from: workspace))
        })
        didBootstrap = true
        bootstrapTask = nil
        let projectedHealth = effectiveHealth(health)
        publish(
            kind: projectedHealth.acceptsMutations ? .bootstrapped : .degraded,
            workspaceID: nil,
            contextID: nil,
            operationID: nil,
            revisions: nil,
            diagnostic: projectedHealth.acceptsMutations ? nil : projectedHealthDiagnostic
        )
    }

    func snapshot() -> DomainWorkspaceCatalogSnapshot {
        DomainWorkspaceCatalogSnapshot(
            runtimeIdentity: identity,
            isBootstrapped: didBootstrap,
            publicationSequence: publicationSequence,
            catalogRevision: catalogRevision,
            health: effectiveHealth(health),
            workspaces: records.values.map(makeSnapshot).sorted {
                let lhs = $0.document.metadata.name.localizedCaseInsensitiveCompare($1.document.metadata.name)
                if lhs != .orderedSame { return lhs == .orderedAscending }
                return $0.document.workspaceID.uuidString < $1.document.workspaceID.uuidString
            }
        )
    }

    func workspaceSnapshot(_ workspaceID: UUID) -> DomainWorkspaceSnapshot? {
        workspaceReadFence(workspaceID)?.workspace
    }

    /// Atomically captures the Swift writer's complete semantic row and publication cursor. Rust
    /// publishes and serves that row as one immutable authority generation; this Swift value is the
    /// mutation/reconciliation fence. Read registrations remain routing overlays, so they change the
    /// document fence without inventing a catalog event.
    func workspaceReadFence(_ workspaceID: UUID) -> DomainWorkspaceReadFence? {
        let snapshot = if let registration = readRegistrations[workspaceID] {
            projectSnapshot(registration)
        } else {
            records[workspaceID].map(makeSnapshot)
        }
        return snapshot.map {
            DomainWorkspaceReadFence(
                workspace: $0,
                catalogRevision: catalogRevision,
                publicationSequence: publicationSequence
            )
        }
    }

    /// Captures the Swift topology overlay and the immutable Rust aggregate row in one actor turn.
    /// There is no asynchronous observer, checkpoint restore, or repair path in this read boundary.
    func workspaceAuthoritativeReadFence(
        _ workspaceID: UUID
    ) -> DomainWorkspaceAuthoritativeReadFence? {
        let topology = if let registration = readRegistrations[workspaceID] {
            projectSnapshot(registration)
        } else {
            records[workspaceID].map(makeSnapshot)
        }
        guard let topology,
              let commandAdmission,
              let read = try? commandAdmission.authorityRead(workspaceID: workspaceID),
              read.catalogRevision == catalogRevision,
              read.publicationSequence == publicationSequence,
              read.contentDigest == topology.document.contentDigest,
              let projectionDigest = read.projectionDigest,
              let projection = read.projection,
              let authority = read.authority,
              let workspace = DomainWorkspaceRustProjection.workspaceSnapshot(
                  topology: topology,
                  authority: authority
              )
        else { return nil }
        return DomainWorkspaceAuthoritativeReadFence(
            workspace: workspace,
            projection: projection,
            generation: read.generation,
            catalogRevision: read.catalogRevision,
            publicationSequence: read.publicationSequence,
            projectionDigest: projectionDigest
        )
    }

    /// Command outcomes and mutation admission must report canonical record state; the read
    /// overlay is routing-only and must never leak into recovery health or revision baselines.
    func canonicalWorkspaceSnapshot(_ workspaceID: UUID) -> DomainWorkspaceSnapshot? {
        records[workspaceID].map(makeSnapshot)
    }

    func isWorkspaceQuarantined(_ workspaceID: UUID) -> Bool {
        guard let validator = commandIdentityValidator else { return false }
        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
        return (try? validator.isWorkspaceQuarantined(storageDirectory: storageDir, workspaceID: workspaceID))?.isQuarantined ?? false
    }

    func quarantinedWorkspaces() -> [UUID] {
        guard let validator = commandIdentityValidator else { return [] }
        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
        return (try? validator.quarantinedWorkspaces(storageDirectory: storageDir))?.map(\.workspaceID) ?? []
    }

    func contextSnapshot(_ identity: DomainContextIdentity) -> DomainContextSnapshot? {
        workspaceSnapshot(identity.workspaceID)?.contexts.first {
            $0.metadata.identity.contextID == identity.contextID
        }
    }

    func registerReadDocument(_ document: DomainWorkspaceDocument) async -> DomainWorkspaceSnapshot {
        await bootstrap()
        await acquireCommandConvergence()
        defer { releaseCommandConvergence() }
        let previous = readRegistrations[document.workspaceID]
            ?? records[document.workspaceID].map(makeSnapshot)
        if let previous, previous.document.contentDigest == document.contentDigest {
            return previous
        }

        let before = previous?.revisions ?? .initial
        let nextWorking = before.workingRevision &+ 1
        let revisions = DomainRevisionState(
            workingRevision: nextWorking,
            savedRevision: before.savedRevision,
            dirtyRevision: nextWorking
        )
        let contextRevisions: [UUID: DomainRevisionState] = if let previous {
            Self.updatedReadOverlayContextRevisions(
                previousDocument: previous.document,
                nextDocument: document,
                previousRevisions: Dictionary(uniqueKeysWithValues: previous.contexts.map {
                    ($0.metadata.identity.contextID, $0.revisions)
                }),
                workspaceRevision: revisions
            ).revisions
        } else {
            Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                ($0.identity.contextID, revisions)
            })
        }
        let registration = DomainWorkspaceSnapshot(
            document: document,
            revisions: revisions,
            health: .writable,
            contexts: document.metadata.contexts.map { metadata in
                DomainContextSnapshot(
                    metadata: metadata,
                    revisions: contextRevisions[metadata.identity.contextID] ?? revisions,
                    health: .writable
                )
            }
        )
        readRegistrations[document.workspaceID] = registration
        let projected = projectSnapshot(registration)
        synchronizeReadAuthorityProjection()
        return projected
    }

    func readySnapshot() async -> DomainWorkspaceCatalogSnapshot {
        await bootstrap()
        return snapshot()
    }

    func readySubscription() async -> DomainWorkspaceSnapshotSubscription {
        await bootstrap()
        return subscribe()
    }

    private func subscribe() -> DomainWorkspaceSnapshotSubscription {
        let token = UUID()
        let stream = AsyncStream<DomainWorkspaceEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(token) }
            }
        }
        return DomainWorkspaceSnapshotSubscription(snapshot: snapshot(), events: stream)
    }

    func execute(_ envelope: DomainWorkspaceCommandEnvelope) async -> DomainCommandOutcome {
        await bootstrap()
        let cancellationAdmission = commandAdmission
        return await withTaskCancellationHandler {
            let outcome: DomainCommandOutcome
            do {
                outcome = try await mutationAccess.withCommandPermit { permit in
                    await self.executeAdmitted(envelope, permit: permit)
                }
            } catch is CancellationError {
                let snapshot = await mutationAccess.snapshot()
                applyMutationAccessSnapshot(snapshot)
                outcome = unrecordedCommandIdentityRejection(
                    envelope,
                    disposition: .failed,
                    errorCode: .cancelled,
                    diagnostic: "workspace_command_identity_cancelled"
                )
            } catch let DomainWorkspaceMutationAccessError.unavailable(reason) {
                let snapshot = await mutationAccess.snapshot()
                applyMutationAccessSnapshot(snapshot)
                outcome = unrecordedMutationAccessRejection(envelope, reason: reason)
            } catch {
                let snapshot = await mutationAccess.snapshot()
                applyMutationAccessSnapshot(snapshot)
                outcome = unrecordedMutationAccessRejection(
                    envelope,
                    reason: "canonical_storage_mutation_permit_invalid"
                )
            }
            return outcome
        } onCancel: {
            guard let cancellationAdmission else { return }
            _ = try? cancellationAdmission.cancel(operationID: envelope.operationID)
        }
    }

    private func executeAdmitted(
        _ envelope: DomainWorkspaceCommandEnvelope,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome {
        guard let commandIdentityInput = DomainWorkspaceCommandIdentityInput(envelope),
              let commandIdentityBytes = commandIdentityInput.estimatedRetainedBytes,
              commandIdentityBytes <= DomainWorkspaceCommandIdentityInput.maximumRetainedBytes
        else {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .invalid,
                errorCode: .invalidDocument,
                diagnostic: "workspace_command_identity_input_too_large"
            )
        }
        guard let workspaceID = envelope.workspaceID else {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .invalid,
                errorCode: .invalidDocument,
                diagnostic: "workspace_command_identity_workspace_missing"
            )
        }
        if unavailableWorkspaces[workspaceID] != nil {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_document_unavailable"
            )
        }
        if let record = records[workspaceID], !record.health.acceptsMutations {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .workspaceReadOnlyDegraded,
                diagnostic: record.health.reason ?? "workspace_read_only"
            )
        }
        if let commandIdentityResolver {
            do {
                try Task.checkCancellation()
                // Tests may delay or fail before the authoritative acquire, but the injected
                // fingerprint is never used for a production identity or admission decision.
                _ = try await commandIdentityResolver(commandIdentityInput)
                try Task.checkCancellation()
            } catch is CancellationError {
                return unrecordedCommandIdentityRejection(
                    envelope,
                    disposition: .failed,
                    errorCode: .cancelled,
                    diagnostic: "workspace_command_identity_cancelled"
                )
            } catch {
                return unrecordedCommandIdentityRejection(
                    envelope,
                    disposition: .readOnly,
                    errorCode: .runtimeReadOnlyDegraded,
                    diagnostic: "workspace_command_identity_rust_unavailable"
                )
            }
        }
        var fingerprint = ""
        var acquiredClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim?
        admissionReservation: while true {
            let acquisition: DomainWorkspaceCommandAdmissionAcquisition
            do {
                try Task.checkCancellation()
                acquisition = try resolveCommandAcquisition(commandIdentityInput)
            } catch is CancellationError {
                return unrecordedCommandIdentityRejection(
                    envelope,
                    disposition: .failed,
                    errorCode: .cancelled,
                    diagnostic: "workspace_command_identity_cancelled"
                )
            } catch let error as DomainWorkspaceCommandAdmissionError {
                switch error {
                case .invalidInput:
                    return unrecordedCommandIdentityRejection(
                        envelope,
                        disposition: .invalid,
                        errorCode: .invalidDocument,
                        diagnostic: "workspace_command_identity_input_invalid"
                    )
                case .invalidReceipt:
                    quarantineCommandAdmission()
                    return unrecordedCommandIdentityRejection(
                        envelope,
                        disposition: .readOnly,
                        errorCode: .runtimeReadOnlyDegraded,
                        diagnostic: "workspace_command_identity_receipt_invalid"
                    )
                case .capacityExceeded:
                    return unrecordedCommandIdentityRejection(
                        envelope,
                        disposition: .failed,
                        errorCode: .persistenceFailure,
                        diagnostic: "workspace_command_lifecycle_capacity_exceeded"
                    )
                case .deadlineExceeded:
                    return unrecordedCommandIdentityRejection(
                        envelope,
                        disposition: .failed,
                        errorCode: .cancelled,
                        diagnostic: "workspace_command_deadline_exceeded"
                    )
                case .shuttingDown:
                    return unrecordedCommandIdentityRejection(
                        envelope,
                        disposition: .failed,
                        errorCode: .cancelled,
                        diagnostic: "workspace_command_runtime_shutdown"
                    )
                case .unavailable:
                    quarantineCommandAdmission()
                    return unrecordedCommandIdentityRejection(
                        envelope,
                        disposition: .readOnly,
                        errorCode: .runtimeReadOnlyDegraded,
                        diagnostic: "workspace_command_identity_rust_unavailable"
                    )
                }
            } catch {
                quarantineCommandAdmission()
                return unrecordedCommandIdentityRejection(
                    envelope,
                    disposition: .readOnly,
                    errorCode: .runtimeReadOnlyDegraded,
                    diagnostic: "workspace_command_identity_rust_unavailable"
                )
            }
            switch acquisition {
            case let .claimed(receiptFingerprint, claim):
                fingerprint = receiptFingerprint
                acquiredClaim = claim
                break admissionReservation
            case let .pending(receiptFingerprint, _):
                guard isLowercaseSHA256(receiptFingerprint) else {
                    quarantineCommandAdmission()
                    return unrecordedCommandIdentityRejection(
                        envelope,
                        disposition: .readOnly,
                        errorCode: .runtimeReadOnlyDegraded,
                        diagnostic: "workspace_command_identity_receipt_invalid"
                    )
                }
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    return unrecordedCommandIdentityRejection(
                        envelope,
                        disposition: .failed,
                        errorCode: .cancelled,
                        diagnostic: "workspace_command_identity_cancelled"
                    )
                }
                continue admissionReservation
            case let .collision(receiptFingerprint, scope):
                guard isLowercaseSHA256(receiptFingerprint) else {
                    quarantineCommandAdmission()
                    return unrecordedCommandIdentityRejection(
                        envelope,
                        disposition: .readOnly,
                        errorCode: .runtimeReadOnlyDegraded,
                        diagnostic: "workspace_command_identity_receipt_invalid"
                    )
                }
                if case let .deleteWorkspace(targetID) = envelope.command, scope == .global {
                    let diagnostic = readDeletionDiagnostic(workspaceID: targetID)
                    return DomainCommandOutcome(
                        operationID: envelope.operationID,
                        disposition: .deduplicated,
                        before: nil,
                        after: nil,
                        catalogRevision: catalogRevision,
                        resultingDigest: nil,
                        diagnostic: diagnostic,
                        workspace: nil
                    )
                }
                return collisionOutcome(
                    envelope.operationID,
                    workspace: scope == .global ? nil : records[workspaceID].map(makeSnapshot)
                )
            case let .replay(receiptFingerprint, scope, operation):
                // Durable transaction finalization may expose an exact replay while the first
                // actor invocation is still resuming from physical I/O. Join the command convergence
                // fence so its actor row and aggregate publication are installed before replay.
                await acquireCommandConvergence()
                releaseCommandConvergence()
                guard let recorded = await recordedOutcome(
                    for: envelope,
                    fingerprint: receiptFingerprint,
                    scope: scope,
                    operation: operation,
                    permit: permit
                ) else {
                    quarantineCommandAdmission()
                    return unrecordedCommandIdentityRejection(
                        envelope,
                        disposition: .readOnly,
                        errorCode: .runtimeReadOnlyDegraded,
                        diagnostic: "workspace_command_admission_receipt_invalid"
                    )
                }
                return recorded
            }
        }
        guard let commandClaim = acquiredClaim,
              isLowercaseSHA256(fingerprint)
        else {
            quarantineCommandAdmission()
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_identity_receipt_invalid"
            )
        }
        defer {
            _ = try? commandClaim.abandon()
        }
        // One actor convergence fence keeps the Swift mirror used to build a complete candidate
        // aligned with the single Rust aggregate head reserved through physical authority.
        await acquireCommandConvergence()
        defer { releaseCommandConvergence() }
        if let stopped = commandLifecycleStopOutcome(
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim
        ) {
            return stopped
        }
        let candidateDocumentBytes = commandDocument(envelope.command)?.documentBytes
        let externalDocumentBytes = commandExternalDocument(envelope.command)?.documentBytes
        if let document = commandDocument(envelope.command),
           let diagnostic = invalidDocumentDiagnostic(document)
        {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .invalid,
                errorCode: .invalidDocument,
                diagnostic: diagnostic
            )
        }
        if rejectsEphemeralPersistence(envelope.command) {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .invalid,
                errorCode: .invalidDocument,
                diagnostic: "ephemeral_workspace_not_persistable"
            )
        }
        // An unavailable catalog row is physical evidence (missing/corrupt bytes), not an
        // authoritative semantic absence. Keep this narrow diagnostic before Rust preflight so a
        // bad document cannot be mistaken for a request to create a new workspace with the same ID.
        if unavailableWorkspaces[workspaceID] != nil {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_document_unavailable"
            )
        }
        do {
            let preflight = try commandClaim.semanticPreflight(
                commandIdentityInput,
                candidateDocumentBytes: candidateDocumentBytes,
                externalDocumentBytes: externalDocumentBytes
            )
            if let preflightOutcome = await semanticPreflightOutcome(
                preflight,
                envelope: envelope,
                workspaceID: workspaceID,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                permit: permit
            ) {
                return preflightOutcome
            }
        } catch {
            quarantineCommandAdmission()
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_semantic_preflight_unavailable"
            )
        }

        if let stopped = commandLifecycleStopOutcome(
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim
        ) {
            return stopped
        }

        let outcome: DomainCommandOutcome = switch envelope.command {
        case let .createWorkspace(document):
            await createWorkspace(
                document,
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                permit: permit
            )
        case let .replaceWorkingDocument(document):
            await replaceWorkingDocument(
                document,
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                permit: permit
            )
        case let .replaceSelection(request):
            await replaceWorkingDocument(
                request.candidateDocument,
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                permit: permit,
                selectionMutation: request
            )
        case let .replaceContext(request):
            await replaceWorkingDocument(
                request.candidateDocument,
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                permit: permit,
                contextMutation: request
            )
        case let .saveWorkspaceDocument(workspaceID):
            await saveWorkspace(
                workspaceID,
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                permit: permit
            )
        case let .resolveExternalConflict(workspaceID, acceptExternal, _):
            await resolveExternalConflict(
                workspaceID,
                acceptExternal: acceptExternal,
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                permit: permit
            )
        case let .deleteWorkspace(workspaceID):
            await deleteWorkspace(
                workspaceID,
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                permit: permit
            )
        }
        invalidateReadRegistrationIfSuperseded(
            workspaceID: workspaceID,
            disposition: outcome.disposition,
            resultingDigest: outcome.resultingDigest
        )
        return outcome
    }

    /// Keep the read overlay while persistence is suspended/re-entrant. Any completed canonical
    /// transition supersedes it, including a different newer document and a deduplicated replay
    /// of a completed command. A failed command must not reopen the publication race, so replayed
    /// transients key on the original recorded disposition, never on the replay's `.deduplicated`.
    private func invalidateReadRegistrationIfSuperseded(
        workspaceID: UUID?,
        disposition: DomainCommandDisposition,
        resultingDigest: String?
    ) {
        guard let workspaceID,
              let registration = readRegistrations[workspaceID]
        else { return }
        switch disposition {
        case .applied, .deduplicated:
            readRegistrations.removeValue(forKey: workspaceID)
        case .unchanged where resultingDigest == nil
            || resultingDigest == registration.document.contentDigest:
            readRegistrations.removeValue(forKey: workspaceID)
        default:
            break
        }
    }

    private func rejectsEphemeralPersistence(_ command: DomainWorkspaceCommand) -> Bool {
        switch command {
        case let .createWorkspace(document), let .replaceWorkingDocument(document):
            document.metadata.isEphemeral
        case let .replaceSelection(request):
            request.candidateDocument.metadata.isEphemeral
        case let .replaceContext(request):
            request.candidateDocument.metadata.isEphemeral
        case let .saveWorkspaceDocument(workspaceID),
             let .resolveExternalConflict(workspaceID, _, _):
            records[workspaceID]?.document.metadata.isEphemeral == true
        case .deleteWorkspace:
            false
        }
    }

    private func commandDocument(_ command: DomainWorkspaceCommand) -> DomainWorkspaceDocument? {
        switch command {
        case let .createWorkspace(document), let .replaceWorkingDocument(document):
            document
        case let .replaceSelection(request):
            request.candidateDocument
        case let .replaceContext(request):
            request.candidateDocument
        case .saveWorkspaceDocument, .deleteWorkspace, .resolveExternalConflict:
            nil
        }
    }

    private func commandExternalDocument(_ command: DomainWorkspaceCommand) -> DomainWorkspaceDocument? {
        switch command {
        case let .resolveExternalConflict(workspaceID, _, _):
            records[workspaceID]?.externalDocument
        case .createWorkspace, .replaceWorkingDocument, .replaceSelection, .replaceContext,
             .saveWorkspaceDocument, .deleteWorkspace:
            nil
        }
    }

    private func semanticPreflightOutcome(
        _ preflight: DomainWorkspaceSemanticPreflight,
        envelope: DomainWorkspaceCommandEnvelope,
        workspaceID: UUID,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome? {
        guard preflight.workspaceID == workspaceID else {
            quarantineCommandAdmission()
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_semantic_preflight_identity_invalid"
            )
        }
        let diagnostic = preflight.diagnostic ?? "workspace_command_semantic_preflight_rejected"
        let errorCode: DomainCommandErrorCode = diagnostic.hasPrefix("protected_agent_identity_")
            ? .protectedAgentIdentityConflict
            : .stateConflict
        let state = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .conflict,
            before: preflight.revisions,
            after: preflight.revisions,
            catalogRevision: preflight.catalogRevision,
            resultingDigest: preflight.contentDigest,
            errorCode: errorCode,
            diagnostic: diagnostic,
            workspace: records[workspaceID].map(makeSnapshot)
        )
        switch preflight.disposition {
        case .proceed:
            return nil
        case .unchanged:
            guard let record = records[workspaceID] else {
                quarantineCommandAdmission()
                return unrecordedCommandIdentityRejection(
                    envelope,
                    disposition: .readOnly,
                    errorCode: .runtimeReadOnlyDegraded,
                    diagnostic: "workspace_command_semantic_preflight_mirror_missing"
                )
            }
            return await unchangedOutcome(
                envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                record: record,
                permit: permit
            )
        case .conflict:
            return finalizeTransientOutcome(
                state,
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim
            )
        case .missing:
            return finalizeTransientOutcome(
                DomainCommandOutcome(
                    operationID: envelope.operationID,
                    disposition: .invalid,
                    before: preflight.revisions,
                    after: preflight.revisions,
                    catalogRevision: preflight.catalogRevision,
                    resultingDigest: preflight.contentDigest,
                    errorCode: .workspaceUnavailable,
                    diagnostic: diagnostic,
                    workspace: records[workspaceID].map(makeSnapshot)
                ),
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim
            )
        case .unavailable:
            let (disposition, errorCode): (DomainCommandDisposition, DomainCommandErrorCode) = switch preflight.health {
            case .some(.externalConflict):
                (.conflict, .workspaceExternalConflict)
            case .some(.removed):
                (.invalid, .workspaceUnavailable)
            default:
                (.readOnly, .workspaceReadOnlyDegraded)
            }
            return finalizeTransientOutcome(
                DomainCommandOutcome(
                    operationID: envelope.operationID,
                    disposition: disposition,
                    before: preflight.revisions,
                    after: preflight.revisions,
                    catalogRevision: preflight.catalogRevision,
                    resultingDigest: preflight.contentDigest,
                    errorCode: errorCode,
                    diagnostic: diagnostic,
                    workspace: records[workspaceID].map(makeSnapshot)
                ),
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim
            )
        }
    }

    private func invalidDocumentDiagnostic(_ document: DomainWorkspaceDocument) -> String? {
        guard workspaceAuthorityScope.containsWorkspaceDocument(document.fileURL) else {
            return "workspace_document_outside_lease_scope"
        }
        guard document.metadata.workspaceID == document.workspaceID else {
            return "workspace_document_id_mismatch"
        }
        var contextIDs = Set<UUID>()
        for context in document.metadata.contexts {
            guard context.identity.workspaceID == document.workspaceID else {
                return "context_workspace_id_mismatch"
            }
            guard contextIDs.insert(context.identity.contextID).inserted else {
                return "duplicate_context_id"
            }
        }
        return nil
    }

    private func resolveCommandAcquisition(
        _ input: DomainWorkspaceCommandIdentityInput
    ) throws -> DomainWorkspaceCommandAdmissionAcquisition {
        guard let commandAdmission else {
            throw DomainWorkspaceCommandAdmissionError.unavailable
        }
        return try commandAdmission.acquire(input)
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private func installSemanticRecoveryAuthority(
        _ commit: DomainWorkspaceSemanticRecoveryCommit
    ) throws {
        switch commit.admissionDisposition {
        case .installed, .preserved:
            guard commit.admissionReceipt != nil else {
                throw DomainWorkspaceCommandAdmissionError.invalidReceipt
            }
            if let admission = commit.admission {
                guard commandAdmission == nil else {
                    admission.close()
                    throw DomainWorkspaceCommandAdmissionError.invalidReceipt
                }
                commandAdmission = admission
            } else if commandAdmission == nil {
                throw DomainWorkspaceCommandAdmissionError.invalidReceipt
            }
        case .quarantined:
            guard commit.admission == nil, commit.admissionReceipt == nil else {
                throw DomainWorkspaceCommandAdmissionError.invalidReceipt
            }
            // Existing admission remains alive but the Rust capability rejects new acquire until a
            // later authoritative artifact recovery atomically clears quarantine.
            if commandAdmission == nil {
                return
            }
        }
    }

    private func quarantineCommandAdmission() {
        commandAdmission?.close()
        commandAdmission = nil
    }

    private func markCommandAdmissionReceiptMissing(workspaceID: UUID?) {
        let degraded = DomainAuthorityHealth.degradedReadOnly(
            reason: "workspace_command_admission_receipt_missing"
        )
        health = degraded
        if let workspaceID, var record = records[workspaceID] {
            record.health = degraded
            records[workspaceID] = record
        }
        publish(
            kind: .degraded,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: nil,
            revisions: workspaceID.flatMap { records[$0]?.revisions },
            diagnostic: "workspace_command_admission_receipt_missing"
        )
    }

    private func recordedOutcomeAfterReconciliation(
        for envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome? {
        guard let input = DomainWorkspaceCommandIdentityInput(envelope),
              let admission = commandAdmission
        else { return nil }
        do {
            switch try admission.acquire(input) {
            case let .replay(receiptFingerprint, scope, operation):
                guard receiptFingerprint == fingerprint else {
                    throw DomainWorkspaceCommandAdmissionError.invalidReceipt
                }
                return await recordedOutcome(
                    for: envelope,
                    fingerprint: fingerprint,
                    scope: scope,
                    operation: operation,
                    permit: permit
                )
            case .pending:
                return nil
            case let .claimed(_, claim):
                _ = try? claim.abandon()
                throw DomainWorkspaceCommandAdmissionError.invalidReceipt
            case let .collision(_, scope):
                if case let .deleteWorkspace(targetID) = envelope.command, scope == .global {
                    let diagnostic = readDeletionDiagnostic(workspaceID: targetID)
                    return DomainCommandOutcome(
                        operationID: envelope.operationID,
                        disposition: .deduplicated,
                        before: nil,
                        after: nil,
                        catalogRevision: catalogRevision,
                        resultingDigest: nil,
                        diagnostic: diagnostic,
                        workspace: nil
                    )
                }
                return collisionOutcome(
                    envelope.operationID,
                    workspace: scope == .global
                        ? nil
                        : envelope.workspaceID.flatMap { records[$0].map(makeSnapshot) }
                )
            }
        } catch {
            quarantineCommandAdmission()
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_admission_rust_unavailable"
            )
        }
    }

    private func recordedOutcome(
        for envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        scope: DomainWorkspaceCommandAdmissionLookupScope,
        operation prior: DomainRecordedOperation,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome? {
        guard let workspaceID = envelope.workspaceID else {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_admission_receipt_invalid"
            )
        }
        guard prior.operationID == envelope.operationID,
              prior.fingerprint == fingerprint
        else {
            quarantineCommandAdmission()
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_admission_receipt_invalid"
            )
        }
        let record = records[workspaceID]
        if scope == .workspace, record == nil {
            if case .deleteWorkspace = envelope.command {
                // Deletion drops the canonical record, so nil is expected.
            } else {
                quarantineCommandAdmission()
                return unrecordedCommandIdentityRejection(
                    envelope,
                    disposition: .readOnly,
                    errorCode: .runtimeReadOnlyDegraded,
                    diagnostic: "workspace_command_admission_scope_invalid"
                )
            }
        }
        if prior.disposition == .applied || prior.disposition == .unchanged,
           case .createWorkspace = envelope.command
        {
            catalogRevision = max(catalogRevision, prior.catalogRevision)
        }
        invalidateReadRegistrationIfSuperseded(
            workspaceID: workspaceID,
            disposition: prior.disposition,
            resultingDigest: prior.resultingDigest
        )
        if scope == .workspace, let record {
            publish(
                kind: .operationDeduplicated,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: envelope.operationID,
                origin: envelope.origin,
                revisions: record.revisions,
                diagnostic: nil
            )
        }
        return prior.outcome(workspace: record.map(makeSnapshot))
    }

    @discardableResult
    func activateMutationAccess() async -> DomainWorkspaceMutationAccessSnapshot {
        await bootstrap()
        let accessSnapshot = await mutationAccess.activate { permit in
            await self.reconcileAfterLeaseAcquisition(permit: permit)
        }
        applyMutationAccessSnapshot(accessSnapshot)
        return accessSnapshot
    }

    func beginMutationAccessDrain() async {
        await mutationAccess.beginDrain()
        await applyMutationAccessSnapshot(mutationAccess.snapshot())
    }

    func finishMutationAccessDrainAndRelease() async {
        await mutationAccess.finishDrainAndRelease()
        await applyMutationAccessSnapshot(mutationAccess.snapshot())
    }

    func reloadExternalChanges() async -> DomainExternalReloadActivity {
        await bootstrap()
        let priorAccess = mutationAccessSnapshot
        let activated = await activateMutationAccess()
        let activity: DomainExternalReloadActivity
        if !activated.acceptsMutations {
            activity = .recoveryPending
        } else if !priorAccess.acceptsMutations {
            activity = .changed
        } else {
            do {
                let pass = try await mutationAccess.withCommandPermit { permit in
                    await self.reloadExternalChangesAdmitted(permit: permit)
                }
                activity = pass.activity
            } catch {
                await applyMutationAccessSnapshot(mutationAccess.snapshot())
                activity = .recoveryPending
            }
        }
        return activity
    }

    private func reconcileAfterLeaseAcquisition(
        permit: DomainWorkspaceMutationPermit
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if commandIdentityValidator == nil {
            do {
                commandIdentityValidator = try await DomainWorkspaceRustJournal.prepare()
            } catch {
                return false
            }
        }
        guard !Task.isCancelled else { return false }
        if let validator = commandIdentityValidator {
            recoverInterruptedCreates(validator: validator, permit: permit)
        }
        let durableCatalog = await persistence.bootstrap(
            permit: permit,
            commandAdmission: commandAdmission
        )
        guard !Task.isCancelled,
              let semanticRecovery = durableCatalog.semanticRecovery,
              let semanticPreview = durableCatalog.semanticPreview
        else { return false }
        do {
            let commit = try semanticRecovery.commit(expected: semanticPreview)
            try installSemanticRecoveryAuthority(commit)
        } catch {
            semanticRecovery.close()
            return false
        }
        guard durableCatalog.health.acceptsMutations,
              commandAdmission != nil
        else { return false }

        health = durableCatalog.health
        catalogRevision = durableCatalog.catalogRevision
        unavailableWorkspaces = Dictionary(uniqueKeysWithValues: durableCatalog.unavailableWorkspaces.map {
            ($0.workspaceID, $0)
        })
        records = Dictionary(uniqueKeysWithValues: durableCatalog.workspaces.map { workspace in
            (workspace.document.workspaceID, makeRecord(from: workspace))
        })
        let reload = await reloadExternalChangesAdmitted(permit: permit)
        guard reload.completedSuccessfully,
              !Task.isCancelled,
              health.acceptsMutations,
              commandAdmission != nil
        else { return false }
        return true
    }

    private func recoverInterruptedCreates(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        permit: DomainWorkspaceMutationPermit
    ) {
        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
        let storageURL = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory
        let catalogURL = storageURL.appendingPathComponent(".agentry-domain-runtime/workspace-catalog.json")
        let journalsDir = storageURL.appendingPathComponent(".agentry-domain-runtime/working-journals")
        guard let catalogBytes = try? Data(contentsOf: catalogURL),
              let validation = try? validator.validateCatalog(catalogBytes)
        else { return }
        let catalog = validation.catalog
        guard let journalURLs = try? FileManager.default.contentsOfDirectory(at: journalsDir, includingPropertiesForKeys: nil)
        else { return }
        for journalURL in journalURLs where journalURL.pathExtension == "json" {
            guard let workspaceID = UUID(uuidString: journalURL.deletingPathExtension().lastPathComponent),
                  !catalog.entries.contains(where: { $0.workspaceID == workspaceID }),
                  let journalBytes = try? Data(contentsOf: journalURL),
                  let journalObj = try? JSONSerialization.jsonObject(with: journalBytes) as? [String: Any],
                  let fileURLString = journalObj["fileURL"] as? String,
                  let fileURL = URL(string: fileURLString),
                  let docBytes = try? Data(contentsOf: fileURL),
                  let document = try? DomainWorkspaceDocument.decode(documentBytes: docBytes, fileURL: fileURL),
                  document.workspaceID == workspaceID
            else { continue }
            _ = try? validator.createWorkspaceDirect(
                storageDirectory: storageDir,
                workspaceID: workspaceID,
                workspaceName: document.metadata.name,
                documentBytes: docBytes,
                expectedCatalogRevision: catalog.revision,
                operationID: UUID(),
                fingerprint: "0000000000000000000000000000000000000000000000000000000000000000"
            )
        }
    }

    private func reloadExternalChangesAdmitted(
        permit: DomainWorkspaceMutationPermit
    ) async -> ExternalReloadPass {
        guard !Task.isCancelled else { return .incomplete }
        var changed = false
        var recoveryPending = false

        let observedCatalogRevision: UInt64?
        do {
            observedCatalogRevision = try await persistence.currentCatalogRevision()
        } catch DomainPersistenceError.cancelled {
            return .incomplete
        } catch is CancellationError {
            return .incomplete
        } catch {
            let degraded = DomainAuthorityHealth.degradedReadOnly(
                reason: "workspace_catalog_probe_failed"
            )
            if health != degraded {
                health = degraded
                publish(
                    kind: .degraded,
                    workspaceID: nil,
                    contextID: nil,
                    operationID: nil,
                    revisions: nil,
                    diagnostic: "workspace_catalog_probe_failed"
                )
            }
            return .incomplete
        }

        let catalogChanged = observedCatalogRevision.map { $0 != catalogRevision }
            ?? (catalogRevision != 0)
        if catalogChanged || !health.acceptsMutations {
            let durableCatalog = await persistence.bootstrap(
                permit: permit,
                commandAdmission: commandAdmission
            )
            guard !Task.isCancelled,
                  let semanticRecovery = durableCatalog.semanticRecovery,
                  let semanticPreview = durableCatalog.semanticPreview
            else {
                markCommandAdmissionReceiptMissing(workspaceID: nil)
                return .incomplete
            }
            do {
                let commit = try semanticRecovery.commit(expected: semanticPreview)
                try installSemanticRecoveryAuthority(commit)
            } catch {
                semanticRecovery.close()
                return .incomplete
            }

            let previousHealth = health
            let previousWorkspaceIDs = Set(records.keys)
            let nextRecords = Dictionary(uniqueKeysWithValues: durableCatalog.workspaces.map {
                ($0.document.workspaceID, makeRecord(from: $0))
            })
            let nextUnavailable = Dictionary(
                uniqueKeysWithValues:
                durableCatalog.unavailableWorkspaces.map { ($0.workspaceID, $0) }
            )
            let nextWorkspaceIDs = Set(nextRecords.keys)
            health = durableCatalog.health
            catalogRevision = durableCatalog.catalogRevision
            records = nextRecords
            unavailableWorkspaces = nextUnavailable
            for workspaceID in previousWorkspaceIDs.subtracting(nextWorkspaceIDs).sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                readRegistrations.removeValue(forKey: workspaceID)
                changed = true
                publish(
                    kind: .workspaceDeleted,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: nil,
                    diagnostic: "external_catalog_deletion"
                )
            }
            for workspaceID in nextWorkspaceIDs.subtracting(previousWorkspaceIDs).sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                readRegistrations.removeValue(forKey: workspaceID)
                changed = true
                publish(
                    kind: .externalReloaded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: records[workspaceID]?.revisions,
                    diagnostic: "external_catalog_addition"
                )
            }
            if previousHealth != health {
                changed = true
                publish(
                    kind: health.acceptsMutations ? .externalReloaded : .degraded,
                    workspaceID: nil,
                    contextID: nil,
                    operationID: nil,
                    revisions: nil,
                    diagnostic: health.acceptsMutations
                        ? "workspace_catalog_recovered"
                        : "workspace_catalog_degraded"
                )
            }
            changed = changed || catalogChanged
            recoveryPending = !unavailableWorkspaces.isEmpty || !health.acceptsMutations
            guard health.acceptsMutations, commandAdmission != nil else {
                return .incomplete
            }
        }

        for workspaceID in unavailableWorkspaces.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard let unavailable = unavailableWorkspaces[workspaceID] else { continue }
            let refreshed = await persistence.refreshWorkspace(
                workspaceID: workspaceID,
                fallbackFileURL: unavailable.fileURL,
                permit: permit,
                commandAdmission: commandAdmission
            )
            guard unavailableWorkspaces[workspaceID]?.fileMetadata == unavailable.fileMetadata,
                  let refreshed,
                  let semanticRecovery = refreshed.semanticRecovery,
                  let semanticPreview = refreshed.semanticPreview
            else {
                recoveryPending = true
                continue
            }
            do {
                let commit = try semanticRecovery.commit(expected: semanticPreview)
                try installSemanticRecoveryAuthority(commit)
            } catch {
                semanticRecovery.close()
                recoveryPending = true
                continue
            }
            catalogRevision = max(catalogRevision, refreshed.catalogRevision)
            readRegistrations.removeValue(forKey: workspaceID)
            if refreshed.workspaceIsDeleted {
                records.removeValue(forKey: workspaceID)
                unavailableWorkspaces.removeValue(forKey: workspaceID)
                changed = true
                publish(
                    kind: .workspaceDeleted,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: nil,
                    diagnostic: "external_catalog_deletion"
                )
                continue
            }
            if let nextUnavailable = refreshed.unavailableWorkspace {
                records.removeValue(forKey: workspaceID)
                unavailableWorkspaces[workspaceID] = nextUnavailable
                recoveryPending = true
                changed = true
                publish(
                    kind: .degraded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: nil,
                    diagnostic: nextUnavailable.reason
                )
                continue
            }
            if refreshed.workspaceIsNoChange {
                recoveryPending = true
                continue
            }
            guard let recovered = refreshed.workspace, commandAdmission != nil else {
                recoveryPending = true
                continue
            }
            health = refreshed.health
            records[workspaceID] = makeRecord(from: recovered)
            unavailableWorkspaces.removeValue(forKey: workspaceID)
            changed = true
            recoveryPending = recoveryPending
                || !health.acceptsMutations
                || !recovered.health.acceptsMutations
            publish(
                kind: recovered.health.acceptsMutations ? .externalReloaded : .degraded,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: nil,
                revisions: recovered.revisions,
                diagnostic: recovered.health.acceptsMutations
                    ? "workspace_document_recovered"
                    : recovered.health.reason
            )
        }

        for workspaceID in records.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var current = records[workspaceID],
                  workspaceAuthorityScope.containsWorkspaceDocument(current.document.fileURL)
            else { continue }
            if case .externalConflict = current.health { continue }
            if case let .degradedReadOnly(reason) = current.health, !reason.hasPrefix("external_") {
                // Journal/persistence-scoped degradation heals through a full reload once the
                // sidecar state is repaired. Saved-file-scoped ("external_*") degradation is
                // recovered by the metadata probe below instead, so a journal-backed reload
                // cannot flip health back to writable while the saved document is still bad.
                let refreshed = await persistence.refreshWorkspace(
                    workspaceID: workspaceID,
                    fallbackFileURL: current.document.fileURL,
                    permit: permit,
                    commandAdmission: commandAdmission
                )
                guard records[workspaceID]?.revisions == current.revisions,
                      let refreshed,
                      let semanticRecovery = refreshed.semanticRecovery,
                      let semanticPreview = refreshed.semanticPreview
                else {
                    recoveryPending = true
                    continue
                }
                do {
                    let commit = try semanticRecovery.commit(expected: semanticPreview)
                    try installSemanticRecoveryAuthority(commit)
                } catch {
                    semanticRecovery.close()
                    recoveryPending = true
                    continue
                }
                catalogRevision = max(catalogRevision, refreshed.catalogRevision)
                readRegistrations.removeValue(forKey: workspaceID)
                if refreshed.workspaceIsDeleted {
                    records.removeValue(forKey: workspaceID)
                    unavailableWorkspaces.removeValue(forKey: workspaceID)
                    changed = true
                    publish(
                        kind: .workspaceDeleted,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: nil,
                        diagnostic: "external_catalog_deletion"
                    )
                    continue
                }
                if let nextUnavailable = refreshed.unavailableWorkspace {
                    records.removeValue(forKey: workspaceID)
                    unavailableWorkspaces[workspaceID] = nextUnavailable
                    recoveryPending = true
                    changed = true
                    publish(
                        kind: .degraded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: nil,
                        diagnostic: nextUnavailable.reason
                    )
                    continue
                }
                if refreshed.workspaceIsNoChange {
                    recoveryPending = true
                    continue
                }
                guard let recovered = refreshed.workspace, commandAdmission != nil else {
                    recoveryPending = true
                    continue
                }
                health = refreshed.health
                current = makeRecord(from: recovered)
                records[workspaceID] = current
                unavailableWorkspaces.removeValue(forKey: workspaceID)
                changed = true
                recoveryPending = recoveryPending
                    || !health.acceptsMutations
                    || !current.health.acceptsMutations
                publish(
                    kind: current.health.acceptsMutations ? .externalReloaded : .degraded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: current.revisions,
                    diagnostic: current.health.acceptsMutations
                        ? "workspace_persistence_recovered"
                        : current.health.reason
                )
            }
            if !health.acceptsMutations {
                recoveryPending = true
                continue
            }
            if case let .degradedReadOnly(reason) = current.health,
               !reason.hasPrefix("external_")
            {
                recoveryPending = true
                continue
            }

            let observedRevision = current.revisions
            let observedSavedDigest = current.savedDigest
            let observedMetadata = current.fileMetadata
            let external = await persistence.externalObservationEvidence(
                for: makeSnapshot(current),
                knownMetadata: observedMetadata
            )
            guard !Task.isCancelled else { return .incomplete }
            guard var record = records[workspaceID],
                  record.revisions == observedRevision,
                  record.savedDigest == observedSavedDigest,
                  record.fileMetadata == observedMetadata
            else { continue }

            switch external {
            case .cancelled:
                return .incomplete
            case let .unchanged(metadata):
                let recoveredExternalDegradation: Bool
                if case let .degradedReadOnly(reason) = record.health,
                   reason.hasPrefix("external_"),
                   record.fileMetadata != metadata
                {
                    record.health = .writable
                    record.externalDocument = nil
                    recoveredExternalDegradation = true
                    changed = true
                } else {
                    recoveredExternalDegradation = false
                }
                if record.fileMetadata != metadata || recoveredExternalDegradation {
                    record.fileMetadata = metadata
                    records[workspaceID] = record
                }
                if recoveredExternalDegradation {
                    publish(
                        kind: .externalReloaded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: record.revisions,
                        diagnostic: "external_workspace_recovered"
                    )
                } else if !record.health.acceptsMutations {
                    recoveryPending = true
                }
            case let .absent(metadata):
                // A vanished saved document (unplugged volume, external cleanup) must not
                // brick the journal-backed workspace: an explicit save rewrites it and a
                // returning file is detected by the next metadata change.
                if record.fileMetadata != metadata {
                    record.fileMetadata = metadata
                    records[workspaceID] = record
                }
                if !record.health.acceptsMutations {
                    recoveryPending = true
                }
            case let .unavailable(metadata, reason):
                let degraded = DomainAuthorityHealth.degradedReadOnly(reason: reason)
                let shouldPublish = record.health != degraded || record.fileMetadata != metadata
                record.health = degraded
                record.fileMetadata = metadata
                records[workspaceID] = record
                recoveryPending = true
                if shouldPublish {
                    publish(
                        kind: .degraded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: record.revisions,
                        diagnostic: reason
                    )
                }
            case let .present(bytes, metadata, _):
                guard let document = try? DomainWorkspaceDocument.decode(
                    documentBytes: bytes,
                    fileURL: record.document.fileURL
                ),
                    document.workspaceID == workspaceID
                else {
                    let degraded = DomainAuthorityHealth.degradedReadOnly(
                        reason: "external_workspace_decode_failed"
                    )
                    let shouldPublish = record.health != degraded
                    record.health = degraded
                    record.fileMetadata = metadata
                    records[workspaceID] = record
                    recoveryPending = true
                    if shouldPublish {
                        publish(
                            kind: .degraded,
                            workspaceID: workspaceID,
                            contextID: nil,
                            operationID: nil,
                            revisions: record.revisions,
                            diagnostic: "external_workspace_decode_failed"
                        )
                    }
                    continue
                }
                if document.metadata.isEphemeral || record.document.metadata.isEphemeral {
                    record.document = document
                    record.fileMetadata = metadata
                    records[workspaceID] = record
                    readRegistrations.removeValue(forKey: workspaceID)
                    publish(
                        kind: .externalReloaded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: record.revisions,
                        diagnostic: "ephemeral_external_reload_not_persisted"
                    )
                    changed = true
                    continue
                }
                guard let commandAdmission else {
                    recoveryPending = true
                    continue
                }
                let plan: DomainExternalObservationRecoveryPlan
                do {
                    plan = try commandAdmission.prepareExternalObservationRecovery(
                        workspaceID: workspaceID,
                        fileURL: record.document.fileURL,
                        catalogRevision: catalogRevision,
                        workspaceRevision: record.revisions.workingRevision,
                        currentDocumentDigest: record.document.contentDigest,
                        savedDigest: record.savedDigest,
                        externalDocumentBytes: bytes,
                        updatedAt: Date()
                    )
                } catch {
                    recoveryPending = true
                    continue
                }
                if plan.disposition == .noChange {
                    let recoveredExternalDegradation: Bool
                    if case let .degradedReadOnly(reason) = record.health,
                       reason.hasPrefix("external_"),
                       record.fileMetadata != metadata
                    {
                        record.health = .writable
                        record.externalDocument = nil
                        recoveredExternalDegradation = true
                        changed = true
                    } else {
                        recoveredExternalDegradation = false
                    }
                    if record.fileMetadata != metadata || recoveredExternalDegradation {
                        record.fileMetadata = metadata
                        records[workspaceID] = record
                    }
                    if recoveredExternalDegradation {
                        publish(
                            kind: .externalReloaded,
                            workspaceID: workspaceID,
                            contextID: nil,
                            operationID: nil,
                            revisions: record.revisions,
                            diagnostic: "external_workspace_recovered"
                        )
                    }
                    continue
                }
                let candidateDocument: DomainWorkspaceDocument
                switch plan.candidate {
                case .externalDocument:
                    candidateDocument = document
                case .existingWorkingDocument:
                    candidateDocument = record.document
                case .none:
                    recoveryPending = true
                    continue
                }
                #if DEBUG
                    if let testBeforeExternalReconciliation {
                        await testBeforeExternalReconciliation(workspaceID)
                    }
                #endif
                switch await reconcileExternalObservation(
                    workspaceID: workspaceID,
                    candidateDocument: candidateDocument,
                    externalDocumentBytes: bytes,
                    fileMetadata: metadata,
                    plan: plan,
                    permit: permit,
                    commandAdmission: commandAdmission
                ) {
                case .applied:
                    changed = true
                case .recoveryPending, .failed:
                    recoveryPending = true
                }
            }
        }

        guard commandAdmission != nil else { return .incomplete }
        if changed { return .completed(.changed) }
        return .completed(recoveryPending ? .recoveryPending : .unchanged)
    }

    #if DEBUG
        func testSetBeforeExternalReconciliation(
            _ hook: (@Sendable (UUID) async -> Void)?
        ) {
            testBeforeExternalReconciliation = hook
        }
    #endif

    private func makeRecord(
        from workspace: DomainPersistenceBootstrap.Workspace
    ) -> WorkspaceRecord {
        WorkspaceRecord(
            document: workspace.document,
            savedDigest: workspace.savedDigest,
            revisions: workspace.revisions,
            contextRevisions: workspace.contextRevisions,
            contextTombstones: workspace.contextTombstones,
            operations: workspace.operations,
            health: workspaceAuthorityScope.containsWorkspaceDocument(workspace.document.fileURL)
                ? workspace.health
                : .degradedReadOnly(reason: "workspace_document_outside_lease_scope"),
            externalDocument: workspace.externalDocument,
            fileMetadata: workspace.fileMetadata
        )
    }

    private func rebaseDirtyWorkingDocument(
        workspaceID: UUID,
        localDocument: DomainWorkspaceDocument,
        externalDocument: DomainWorkspaceDocument,
        fileMetadata: DomainFileMetadata,
        permit: DomainWorkspaceMutationPermit
    ) async -> DirtyExternalRebaseResult {
        guard localDocument.workspaceID == workspaceID,
              externalDocument.workspaceID == workspaceID
        else { return .failed }

        // Recovery intentionally replays the captured local document as a whole-document winner.
        // A refresh updates only its durable CAS baseline; substituting refreshed bytes here would
        // silently discard this runtime's unsaved user state. The bounded loop prevents livelock.
        for attempt in 0 ..< Self.maximumCASRecoveryAttempts {
            guard var record = records[workspaceID], record.health.acceptsMutations else {
                return .failed
            }
            let before = record.revisions
            let restoresCapturedDocument = record.document.contentDigest != localDocument.contentDigest

            guard let validator = commandIdentityValidator else { return .failed }
            let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
            do {
                let commandResult = try validator.mutateWorkingDirect(
                    storageDirectory: storageDir,
                    workspaceID: workspaceID,
                    candidateDocumentBytes: localDocument.documentBytes,
                    expectedWorkingRevision: before.workingRevision,
                    operationID: UUID()
                )
                catalogRevision = max(catalogRevision, commandResult.catalogRevision)
                record.document = localDocument
                let afterRevisions = DomainWorkspaceRustProjection.directCommandRevisionState(
                    commandResult.after,
                    fallbackWorking: before.workingRevision + 1,
                    fallbackSaved: before.savedRevision,
                    fallbackDirty: before.workingRevision + 1
                )
                record.savedDigest = commandResult.resultingDigest ?? record.savedDigest
                record.revisions = afterRevisions
                record.health = .writable
                record.externalDocument = nil
                record.fileMetadata = fileMetadata
                records[workspaceID] = record
                readRegistrations.removeValue(forKey: workspaceID)
                publish(
                    kind: .workingStateCommitted,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: record.revisions,
                    diagnostic: restoresCapturedDocument
                        ? "external_document_rebased_after_revision_replay"
                        : "external_document_rebased_keeping_local"
                )
                return .applied
            } catch {
                if attempt + 1 < Self.maximumCASRecoveryAttempts {
                    await refreshAfterCASConflict(
                        workspaceID: workspaceID,
                        fileURL: localDocument.fileURL,
                        permit: permit
                    )
                    continue
                }
                return .recoveryPending
            }
        }
        return .recoveryPending
    }

    private func replayCapturedWorkingDocument(
        workspaceID: UUID,
        localDocument: DomainWorkspaceDocument,
        permit: DomainWorkspaceMutationPermit
    ) async -> DirtyExternalRebaseResult {
        guard localDocument.workspaceID == workspaceID,
              var record = records[workspaceID],
              record.health.acceptsMutations
        else { return .failed }
        guard record.document.contentDigest != localDocument.contentDigest else {
            return .applied
        }

        let before = record.revisions
        guard let validator = commandIdentityValidator else { return .failed }
        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
        do {
            let commandResult = try validator.mutateWorkingDirect(
                storageDirectory: storageDir,
                workspaceID: workspaceID,
                candidateDocumentBytes: localDocument.documentBytes,
                expectedWorkingRevision: before.workingRevision,
                operationID: UUID()
            )
            catalogRevision = max(catalogRevision, commandResult.catalogRevision)
            record.document = localDocument
            let afterRevisions = DomainWorkspaceRustProjection.directCommandRevisionState(
                commandResult.after,
                fallbackWorking: before.workingRevision + 1,
                fallbackSaved: before.savedRevision,
                fallbackDirty: before.workingRevision + 1
            )
            record.revisions = afterRevisions
            record.externalDocument = nil
            records[workspaceID] = record
            readRegistrations.removeValue(forKey: workspaceID)
            publish(
                kind: .workingStateCommitted,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: nil,
                revisions: record.revisions,
                diagnostic: "working_document_replayed_after_save_revision_race"
            )
            return .applied
        } catch {
            return .failed
        }
    }

    private func reconcileExternalObservation(
        workspaceID: UUID,
        candidateDocument: DomainWorkspaceDocument,
        externalDocumentBytes: Data,
        fileMetadata: DomainFileMetadata,
        plan: DomainExternalObservationRecoveryPlan,
        permit: DomainWorkspaceMutationPermit,
        commandAdmission: DomainWorkspaceRustJournal.PreparedCommandAdmission
    ) async -> DirtyExternalRebaseResult {
        guard candidateDocument.workspaceID == workspaceID,
              candidateDocument.fileURL.standardizedFileURL == plan.expectedFileURL.standardizedFileURL,
              plan.workspaceID == workspaceID
        else { return .failed }
        guard let record = records[workspaceID], record.health.acceptsMutations else {
            return .failed
        }
        let before = record.revisions
        guard let validator = commandIdentityValidator else { return .failed }
        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
        let commandResult: CoreWorkspaceCommandResultV1
        do {
            commandResult = try validator.mutateWorkingDirect(
                storageDirectory: storageDir,
                workspaceID: workspaceID,
                candidateDocumentBytes: candidateDocument.documentBytes,
                expectedWorkingRevision: before.workingRevision,
                operationID: UUID()
            )
            guard var current = records[workspaceID], current.revisions == before else {
                return .recoveryPending
            }
            catalogRevision = max(catalogRevision, commandResult.catalogRevision)
            current.document = candidateDocument
            let afterRevisions = DomainWorkspaceRustProjection.directCommandRevisionState(
                commandResult.after,
                fallbackWorking: plan.transition == .externalReload ? before.workingRevision + 1 : before.workingRevision,
                fallbackSaved: plan.transition == .externalReload ? before.workingRevision + 1 : before.savedRevision,
                fallbackDirty: plan.transition == .externalReload ? nil : before.dirtyRevision
            )
            current.savedDigest = commandResult.resultingDigest ?? (plan.transition == .conflictRebase ? plan.externalDocumentDigest : current.savedDigest)
            current.revisions = afterRevisions
            current.health = .writable
            current.externalDocument = nil
            current.fileMetadata = fileMetadata
            records[workspaceID] = current
            readRegistrations.removeValue(forKey: workspaceID)
            let expectedKind: DomainWorkspaceEventKind = plan.transition == .externalReload
                ? .externalReloaded
                : .workingStateCommitted
            publish(
                kind: expectedKind,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: nil,
                revisions: afterRevisions,
                diagnostic: plan.diagnostic
            )
            return .applied
        } catch {
            return .failed
        }
    }

    private func createWorkspace(
        _ document: DomainWorkspaceDocument,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome {
        guard let validator = commandIdentityValidator else {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_validator_unavailable"
            )
        }
        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
        let expectedCatalogRev = envelope.expectedCatalogRevision ?? catalogRevision
        let commandResult: CoreWorkspaceCommandResultV1
        do {
            commandResult = try validator.createWorkspaceDirect(
                storageDirectory: storageDir,
                workspaceID: document.workspaceID,
                workspaceName: document.metadata.name,
                documentBytes: document.documentBytes,
                expectedCatalogRevision: expectedCatalogRev,
                operationID: envelope.operationID,
                fingerprint: fingerprint
            )
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            return mapDirectJournalValidationError(error, envelope: envelope, workspaceID: document.workspaceID)
        } catch {
            return persistenceFailureOutcome(envelope, record: nil, error: error)
        }

        catalogRevision = commandResult.catalogRevision
        let revState = DomainWorkspaceRustProjection.directCommandRevisionState(commandResult.after)
        var record = WorkspaceRecord(
            document: document,
            savedDigest: commandResult.resultingDigest ?? document.contentDigest,
            revisions: revState,
            contextRevisions: [:],
            contextTombstones: [:],
            operations: [],
            health: .writable,
            externalDocument: nil,
            fileMetadata: .missing
        )
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: nil,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            diagnostic: nil,
            workspace: makeSnapshot(record)
        )
        let finalOutcome = finalizeTransientOutcome(
            outcome,
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim
        )
        record.operations = [DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: finalOutcome)]
        records[document.workspaceID] = record

        publish(
            kind: .workspaceCreated,
            workspaceID: document.workspaceID,
            contextID: nil,
            operationID: envelope.operationID,
            origin: envelope.origin,
            revisions: revState,
            diagnostic: nil
        )

        return finalOutcome
    }

    private func deleteWorkspace(
        _ workspaceID: UUID,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome {
        guard let record = records[workspaceID] else {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .invalid,
                errorCode: .workspaceUnavailable,
                diagnostic: "workspace_not_found"
            )
        }
        guard let validator = commandIdentityValidator else {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_validator_unavailable"
            )
        }
        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
        let storageDirURL = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory
        let catalogURL = storageDirURL
            .appendingPathComponent(".agentry-domain-runtime/workspace-catalog.json")
        let journalURL = storageDirURL
            .appendingPathComponent(".agentry-domain-runtime/working-journals/\(workspaceID.uuidString.lowercased()).json")
        let savedJournalBytes = try? Data(contentsOf: journalURL)

        #if DEBUG
            let syncHook = DomainWorkspaceStore.takeCatalogDirectorySyncTestHook(for: catalogURL)
            var directorySyncWarning: String? = nil
            if let syncHook {
                do {
                    try syncHook()
                } catch {
                    directorySyncWarning = "catalog directory sync indeterminate: \(error.localizedDescription)"
                }
            }
        #endif

        let commandResult: CoreWorkspaceCommandResultV1
        do {
            commandResult = try validator.deleteWorkspaceDirect(
                storageDirectory: storageDir,
                workspaceID: workspaceID,
                expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                operationID: envelope.operationID
            )
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            _ = try? commandClaim.abandon()
            if error == .invalidRevisionState || error == .externalDocumentConflict {
                await refreshAfterCASConflict(
                    workspaceID: workspaceID,
                    fileURL: record.document.fileURL,
                    permit: permit
                )
            }
            return mapDirectJournalValidationError(error, envelope: envelope, workspaceID: workspaceID, record: record)
        } catch {
            _ = try? commandClaim.abandon()
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }

        records.removeValue(forKey: workspaceID)
        readRegistrations.removeValue(forKey: workspaceID)
        catalogRevision = commandResult.catalogRevision

        var cleanupWarnings: [String] = []
        let deletionDiagnostic: String?

        #if DEBUG
            if let syncWarning = directorySyncWarning {
                if let saved = savedJournalBytes {
                    try? saved.write(to: journalURL, options: .atomic)
                }
                deletionDiagnostic = syncWarning
            } else {
                if FileManager.default.fileExists(atPath: record.document.fileURL.path) {
                    do {
                        try FileManager.default.removeItem(at: record.document.fileURL)
                    } catch {
                        cleanupWarnings.append("workspace document: \(error.localizedDescription)")
                    }
                }
                let workspaceDirectory = record.document.fileURL.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: workspaceDirectory.path) {
                    do {
                        try FileManager.default.removeItem(at: workspaceDirectory)
                    } catch {
                        cleanupWarnings.append("workspace directory: \(error.localizedDescription)")
                    }
                }
                if !cleanupWarnings.isEmpty {
                    deletionDiagnostic = "artifact_cleanup_incomplete: \(cleanupWarnings.joined(separator: "; "))"
                } else {
                    deletionDiagnostic = commandResult.operation.diagnostic
                }
            }
        #else
            if FileManager.default.fileExists(atPath: record.document.fileURL.path) {
                do {
                    try FileManager.default.removeItem(at: record.document.fileURL)
                } catch {
                    cleanupWarnings.append("workspace document: \(error.localizedDescription)")
                }
            }
            let workspaceDirectory = record.document.fileURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: workspaceDirectory.path) {
                do {
                    try FileManager.default.removeItem(at: workspaceDirectory)
                } catch {
                    cleanupWarnings.append("workspace directory: \(error.localizedDescription)")
                }
            }
            if !cleanupWarnings.isEmpty {
                deletionDiagnostic = "artifact_cleanup_incomplete: \(cleanupWarnings.joined(separator: "; "))"
            } else {
                deletionDiagnostic = commandResult.operation.diagnostic
            }
        #endif

        let tombstoneCandidates = [
            storageDirURL.appendingPathComponent(".agentry-domain-runtime/deletion-tombstones/\(workspaceID.uuidString.lowercased()).json"),
            storageDirURL.appendingPathComponent(".agentry-domain-runtime/deletion-tombstones/\(workspaceID.uuidString.uppercased()).json"),
            storageDirURL.appendingPathComponent("DomainRuntime/deletion-tombstones/\(workspaceID.uuidString.lowercased()).json")
        ]
        for tombstoneFile in tombstoneCandidates {
            guard let data = try? Data(contentsOf: tombstoneFile),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var op = json["operation"] as? [String: Any]
            else { continue }
            op["fingerprint"] = fingerprint
            if let diag = deletionDiagnostic {
                op["diagnostic"] = diag
            }
            json["operation"] = op
            if let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? updated.write(to: tombstoneFile, options: .atomic)
            }
        }

        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: record.revisions,
            after: nil,
            catalogRevision: catalogRevision,
            resultingDigest: nil,
            diagnostic: deletionDiagnostic,
            workspace: nil
        )
        let finalOutcome = finalizeTransientOutcome(
            outcome,
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim
        )

        publish(
            kind: .workspaceDeleted,
            workspaceID: nil,
            contextID: nil,
            operationID: envelope.operationID,
            origin: envelope.origin,
            revisions: nil,
            diagnostic: deletionDiagnostic
        )

        return finalOutcome
    }

    private func replaceWorkingDocument(
        _ document: DomainWorkspaceDocument,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit,
        selectionMutation: DomainWorkspaceSelectionMutationRequest? = nil,
        contextMutation: DomainWorkspaceContextMutationRequest? = nil
    ) async -> DomainCommandOutcome {
        guard document.workspaceID == envelope.workspaceID else {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .invalid,
                errorCode: .invalidDocument,
                diagnostic: "workspace_identity_mismatch"
            )
        }

        if let selectionMutation {
            guard selectionMutation.workspaceID == document.workspaceID,
                  selectionMutation.candidateDocument.workspaceID == document.workspaceID,
                  selectionMutation.candidateDocument.metadata.contexts.contains(where: {
                      $0.identity.contextID == selectionMutation.contextID
                  }),
                  let currentRecord = records[document.workspaceID],
                  (try? DomainWorkspaceSelectionDigest.make(
                      document: currentRecord.document,
                      contextID: selectionMutation.contextID
                  )) == selectionMutation.expectedSelectionDigest,
                  (try? DomainWorkspaceSelectionDigest.make(
                      document: selectionMutation.candidateDocument,
                      contextID: selectionMutation.contextID
                  )) == selectionMutation.candidateSelectionDigest
            else {
                return finalizeTransientOutcome(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim,
                    disposition: .conflict,
                    errorCode: .stateConflict,
                    diagnostic: "selection_digest_or_target_mismatch"
                )
            }
        }
        if let contextMutation {
            guard contextMutation.workspaceID == document.workspaceID,
                  contextMutation.candidateDocument.workspaceID == document.workspaceID,
                  contextMutation.candidateDocument.metadata.contexts.contains(where: {
                      $0.identity.contextID == contextMutation.contextID
                  }),
                  let currentRecord = records[document.workspaceID],
                  (try? DomainWorkspaceContextDigest.make(
                      document: currentRecord.document,
                      contextID: contextMutation.contextID
                  )) == contextMutation.expectedContextDigest,
                  (try? DomainWorkspaceContextDigest.make(
                      document: contextMutation.candidateDocument,
                      contextID: contextMutation.contextID
                  )) == contextMutation.candidateContextDigest
            else {
                return finalizeTransientOutcome(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim,
                    disposition: .conflict,
                    errorCode: .stateConflict,
                    diagnostic: "context_digest_or_target_mismatch"
                )
            }
        }
        guard !(selectionMutation != nil && contextMutation != nil) else {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .invalid,
                errorCode: .invalidDocument,
                diagnostic: "workspace_context_mutation_descriptor_ambiguous"
            )
        }

        guard var record = records[document.workspaceID] else {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .invalid,
                errorCode: .workspaceUnavailable,
                diagnostic: "workspace_requires_explicit_create_command"
            )
        }

        guard let validator = commandIdentityValidator else {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_validator_unavailable"
            )
        }

        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
        let lockURL = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory
            .appendingPathComponent(".agentry-domain-runtime/locks/workspace-\(document.workspaceID.uuidString.lowercased()).lock")
        if FileManager.default.fileExists(atPath: lockURL.path) {
            let lockFD = open(lockURL.path, O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            if lockFD >= 0 {
                defer { close(lockFD) }
                while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                    do {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(10))
                    } catch is CancellationError {
                        return unrecordedCommandIdentityRejection(
                            envelope,
                            disposition: .failed,
                            errorCode: .cancelled,
                            diagnostic: "workspace_command_identity_cancelled"
                        )
                    } catch {
                        break
                    }
                }
                flock(lockFD, LOCK_UN)
            }
        }
        let before = record.revisions
        let commandResult: CoreWorkspaceCommandResultV1
        do {
            commandResult = try validator.mutateWorkingDirect(
                storageDirectory: storageDir,
                workspaceID: document.workspaceID,
                candidateDocumentBytes: document.documentBytes,
                expectedWorkingRevision: before.workingRevision,
                operationID: envelope.operationID
            )
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            return mapDirectJournalValidationError(error, envelope: envelope, workspaceID: document.workspaceID, record: record)
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }

        let afterRevisions = DomainWorkspaceRustProjection.directCommandRevisionState(
            commandResult.after,
            fallbackWorking: before.workingRevision + 1,
            fallbackSaved: before.savedRevision,
            fallbackDirty: before.workingRevision + 1
        )
        record.document = document
        record.revisions = afterRevisions
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: afterRevisions,
            catalogRevision: catalogRevision,
            resultingDigest: document.contentDigest,
            diagnostic: nil,
            workspace: makeSnapshot(record)
        )
        let finalOutcome = finalizeTransientOutcome(
            outcome,
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim
        )
        record.operations.append(DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: finalOutcome))
        records[document.workspaceID] = record

        publish(
            kind: .workingStateCommitted,
            workspaceID: document.workspaceID,
            contextID: selectionMutation?.contextID ?? contextMutation?.contextID,
            operationID: envelope.operationID,
            origin: envelope.origin,
            revisions: afterRevisions,
            diagnostic: nil
        )

        return finalOutcome
    }

    private func saveWorkspace(
        _ workspaceID: UUID,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit,
        allowsCASRecovery: Bool = true,
        allowsExternalRecovery: Bool = true
    ) async -> DomainCommandOutcome {
        guard var record = records[workspaceID] else {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .invalid,
                errorCode: .workspaceUnavailable,
                diagnostic: "workspace_not_found"
            )
        }
        guard let validator = commandIdentityValidator else {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_validator_unavailable"
            )
        }
        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
        let before = record.revisions
        let authorityDiagnostic = allowsExternalRecovery ? nil : "external_document_rebased_and_saved"
        let commandResult: CoreWorkspaceCommandResultV1
        do {
            commandResult = try validator.saveWorkspaceDirect(
                storageDirectory: storageDir,
                workspaceID: workspaceID,
                documentBytes: record.document.documentBytes,
                expectedWorkingRevision: before.workingRevision,
                expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                operationID: envelope.operationID,
                fingerprint: fingerprint
            )
        } catch CoreWorkspaceWorkingJournalValidationError.externalDocumentConflict where allowsExternalRecovery {
            if let diskBytes = try? Data(contentsOf: record.document.fileURL),
               let externalDoc = try? DomainWorkspaceDocument.decode(
                   documentBytes: diskBytes,
                   fileURL: record.document.fileURL
               )
            {
                let rebaseOutcome = await rebaseDirtyWorkingDocument(
                    workspaceID: workspaceID,
                    localDocument: record.document,
                    externalDocument: externalDoc,
                    fileMetadata: record.fileMetadata,
                    permit: permit
                )
                if rebaseOutcome == .applied {
                    return await saveWorkspace(
                        workspaceID,
                        envelope: envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim,
                        permit: permit,
                        allowsCASRecovery: allowsCASRecovery,
                        allowsExternalRecovery: false
                    )
                }
            }
            return mapDirectJournalValidationError(.externalDocumentConflict, envelope: envelope, workspaceID: workspaceID, record: record)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            return mapDirectJournalValidationError(error, envelope: envelope, workspaceID: workspaceID, record: record)
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }

        catalogRevision = max(catalogRevision, commandResult.catalogRevision)
        let afterRevisions = DomainWorkspaceRustProjection.directCommandRevisionState(
            commandResult.after,
            fallbackWorking: before.workingRevision,
            fallbackSaved: before.workingRevision,
            fallbackDirty: nil
        )
        record.savedDigest = commandResult.resultingDigest ?? record.savedDigest
        record.revisions = afterRevisions
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: afterRevisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            diagnostic: authorityDiagnostic,
            workspace: makeSnapshot(record)
        )
        let finalOutcome = finalizeTransientOutcome(
            outcome,
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim
        )
        record.operations.append(DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: finalOutcome))
        records[workspaceID] = record

        publish(
            kind: .savedDocumentCommitted,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: envelope.operationID,
            origin: envelope.origin,
            revisions: afterRevisions,
            diagnostic: authorityDiagnostic
        )

        return finalOutcome
    }

    private func resolveExternalConflict(
        _ workspaceID: UUID,
        acceptExternal: Bool,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome {
        guard var record = records[workspaceID],
              let external = record.externalDocument
        else {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .invalid,
                errorCode: .workspaceUnavailable,
                diagnostic: "workspace_has_no_external_conflict"
            )
        }
        guard let validator = commandIdentityValidator else {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_validator_unavailable"
            )
        }
        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory.path
        let before = record.revisions
        let authorityDiagnostic = acceptExternal
            ? "external_conflict_accepted"
            : "local_conflict_rebased"
        let commandResult: CoreWorkspaceCommandResultV1
        do {
            if acceptExternal {
                commandResult = try validator.mutateWorkingDirect(
                    storageDirectory: storageDir,
                    workspaceID: workspaceID,
                    candidateDocumentBytes: external.documentBytes,
                    expectedWorkingRevision: before.workingRevision,
                    operationID: envelope.operationID
                )
                record.document = external
            } else {
                commandResult = try validator.saveWorkspaceDirect(
                    storageDirectory: storageDir,
                    workspaceID: workspaceID,
                    documentBytes: record.document.documentBytes,
                    expectedWorkingRevision: before.workingRevision,
                    expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                    operationID: envelope.operationID,
                    fingerprint: fingerprint
                )
            }
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            return mapDirectJournalValidationError(error, envelope: envelope, workspaceID: workspaceID, record: record)
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }

        catalogRevision = max(catalogRevision, commandResult.catalogRevision)
        let afterRevisions = DomainWorkspaceRustProjection.directCommandRevisionState(
            commandResult.after,
            fallbackWorking: before.workingRevision + 1,
            fallbackSaved: acceptExternal ? before.savedRevision : before.workingRevision + 1,
            fallbackDirty: nil
        )
        record.savedDigest = commandResult.resultingDigest ?? record.savedDigest
        record.revisions = afterRevisions
        record.externalDocument = nil
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: afterRevisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            diagnostic: authorityDiagnostic,
            workspace: makeSnapshot(record)
        )
        let finalOutcome = finalizeTransientOutcome(
            outcome,
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim
        )
        record.operations.append(DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: finalOutcome))
        records[workspaceID] = record

        publish(
            kind: acceptExternal ? .workingStateCommitted : .savedDocumentCommitted,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: envelope.operationID,
            origin: envelope.origin,
            revisions: afterRevisions,
            diagnostic: authorityDiagnostic
        )

        return finalOutcome
    }

    private func makeSnapshot(_ record: WorkspaceRecord) -> DomainWorkspaceSnapshot {
        let projectedHealth = effectiveHealth(record.health)
        return DomainWorkspaceSnapshot(
            document: record.document,
            revisions: record.revisions,
            health: projectedHealth,
            contexts: record.document.metadata.contexts.map { metadata in
                DomainContextSnapshot(
                    metadata: metadata,
                    revisions: record.contextRevisions[metadata.identity.contextID] ?? record.revisions,
                    health: projectedHealth
                )
            }
        )
    }

    private func projectSnapshot(_ snapshot: DomainWorkspaceSnapshot) -> DomainWorkspaceSnapshot {
        let scopedHealth: DomainAuthorityHealth = workspaceAuthorityScope.containsWorkspaceDocument(
            snapshot.document.fileURL
        )
            ? snapshot.health
            : .degradedReadOnly(reason: "workspace_document_outside_lease_scope")
        let projectedHealth = effectiveHealth(scopedHealth)
        guard projectedHealth != snapshot.health else { return snapshot }
        return DomainWorkspaceSnapshot(
            document: snapshot.document,
            revisions: snapshot.revisions,
            health: projectedHealth,
            contexts: snapshot.contexts.map { context in
                DomainContextSnapshot(
                    metadata: context.metadata,
                    revisions: context.revisions,
                    health: projectedHealth
                )
            }
        )
    }

    private func effectiveHealth(_ durableHealth: DomainAuthorityHealth) -> DomainAuthorityHealth {
        guard durableHealth.acceptsMutations else { return durableHealth }
        guard mutationAccessSnapshot.acceptsMutations else {
            return .degradedReadOnly(reason: mutationAccessSnapshot.reason)
        }
        return .writable
    }

    private var projectedHealthDiagnostic: String? {
        let projected = effectiveHealth(health)
        guard !projected.acceptsMutations else { return nil }
        switch projected {
        case let .degradedReadOnly(reason), let .externalConflict(reason):
            return reason
        case .removed:
            return "workspace_authority_removed"
        case .writable:
            return nil
        }
    }

    private func applyMutationAccessSnapshot(
        _ next: DomainWorkspaceMutationAccessSnapshot
    ) {
        guard next.generation > mutationAccessSnapshot.generation
        else { return }
        let previous = mutationAccessSnapshot
        mutationAccessSnapshot = next
        guard previous.state != next.state || previous.reason != next.reason else { return }
        publish(
            kind: next.acceptsMutations && health.acceptsMutations ? .externalReloaded : .degraded,
            workspaceID: nil,
            contextID: nil,
            operationID: nil,
            revisions: nil,
            diagnostic: next.acceptsMutations ? "canonical_storage_lease_acquired" : next.reason
        )
    }

    func mutationAccessStateSnapshot() -> DomainWorkspaceMutationAccessSnapshot {
        mutationAccessSnapshot
    }

    private func publish(
        kind: DomainWorkspaceEventKind,
        workspaceID: UUID?,
        contextID: UUID?,
        operationID: UUID?,
        origin: DomainCommandOrigin? = nil,
        revisions: DomainRevisionState?,
        diagnostic: String?
    ) {
        if operationID != nil, let workspaceID {
            switch kind {
            case .workspaceCreated, .workspaceDeleted, .workingStateCommitted,
                 .savedDocumentCommitted, .externalReloaded, .externalConflict,
                 .operationDeduplicated:
                readRegistrations.removeValue(forKey: workspaceID)
            case .bootstrapped, .degraded, .routingChanged:
                break
            }
        }
        guard let commandAdmission else { return }
        do {
            // Publication is a canonical semantic transition. Read registrations are restored
            // through the separate routing synchronization below rather than being admitted as
            // semantic rows or preflight baselines.
            let hadRoutingOverlay = !readRegistrations.isEmpty
            let isQuarantined = if let workspaceID {
                unavailableWorkspaces[workspaceID] != nil
                    || records[workspaceID]?.health.acceptsMutations == false
            } else {
                false
            }
            let admissionWorkspaceID = isQuarantined ? nil : workspaceID
            let admissionContextID = isQuarantined ? nil : contextID
            let admissionRevisions = isQuarantined ? nil : revisions
            let receipt = try commandAdmission.publishAuthorityState(
                workspaces: canonicalReadSnapshots(),
                catalogRevision: catalogRevision,
                kind: kind,
                workspaceID: admissionWorkspaceID,
                contextID: admissionContextID,
                operationID: operationID,
                revisions: admissionRevisions
            )
            guard receipt.previousPublicationSequence == publicationSequence,
                  receipt.catalogRevision == catalogRevision
            else {
                throw DomainWorkspaceCommandAdmissionError.invalidReceipt
            }
            publicationSequence = receipt.publicationSequence
            if hadRoutingOverlay {
                synchronizeReadAuthorityProjection()
            }
        } catch {
            quarantineCommandAdmission()
            let degraded = DomainAuthorityHealth.degradedReadOnly(
                reason: "workspace_command_admission_receipt_missing"
            )
            health = degraded
            if let workspaceID, var record = records[workspaceID] {
                record.health = degraded
                records[workspaceID] = record
            }
            return
        }
        let event = DomainWorkspaceEvent(
            runtimeID: identity.runtimeID,
            sequence: publicationSequence,
            catalogRevision: catalogRevision,
            kind: kind,
            workspaceID: workspaceID,
            contextID: contextID,
            operationID: operationID,
            origin: origin,
            revisions: revisions,
            timestamp: Date(),
            diagnostic: diagnostic
        )
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func synchronizeReadAuthorityProjection() {
        guard let commandAdmission else { return }
        do {
            let receipt = try commandAdmission.synchronizeAuthorityProjection(
                workspaces: authoritativeReadSnapshots()
            )
            guard receipt.catalogRevision == catalogRevision,
                  receipt.publicationSequence == publicationSequence
            else {
                throw DomainWorkspaceCommandAdmissionError.invalidReceipt
            }
        } catch {
            quarantineCommandAdmission()
            markCommandAdmissionReceiptMissing(workspaceID: nil)
        }
    }

    private func authoritativeReadSnapshots() -> [DomainWorkspaceSnapshot] {
        var snapshots = Dictionary(uniqueKeysWithValues: records.map { workspaceID, record in
            (workspaceID, makeSnapshot(record))
        })
        for (workspaceID, registration) in readRegistrations {
            snapshots[workspaceID] = projectSnapshot(registration)
        }
        return snapshots.values.sorted {
            $0.document.workspaceID.uuidString < $1.document.workspaceID.uuidString
        }
    }

    private func canonicalReadSnapshots() -> [DomainWorkspaceSnapshot] {
        records.values.map(makeSnapshot).sorted {
            $0.document.workspaceID.uuidString < $1.document.workspaceID.uuidString
        }
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func acquireCommandConvergence() async {
        guard commandConvergenceInProgress else {
            commandConvergenceInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            commandConvergenceWaiters.append(continuation)
        }
    }

    private func releaseCommandConvergence() {
        guard !commandConvergenceWaiters.isEmpty else {
            commandConvergenceInProgress = false
            return
        }
        commandConvergenceWaiters.removeFirst().resume()
    }

    private func refreshAfterCASConflict(
        workspaceID: UUID,
        fileURL: URL,
        permit: DomainWorkspaceMutationPermit
    ) async {
        guard let refreshed = await persistence.refreshWorkspace(
            workspaceID: workspaceID,
            fallbackFileURL: fileURL,
            permit: permit,
            commandAdmission: commandAdmission
        ),
            let semanticRecovery = refreshed.semanticRecovery,
            let semanticPreview = refreshed.semanticPreview
        else { return }
        do {
            let commit = try semanticRecovery.commit(expected: semanticPreview)
            try installSemanticRecoveryAuthority(commit)
        } catch {
            semanticRecovery.close()
            return
        }
        health = refreshed.health
        catalogRevision = max(catalogRevision, refreshed.catalogRevision)
        readRegistrations.removeValue(forKey: workspaceID)
        if refreshed.workspaceIsDeleted {
            records.removeValue(forKey: workspaceID)
            unavailableWorkspaces.removeValue(forKey: workspaceID)
            return
        }
        if let nextUnavailable = refreshed.unavailableWorkspace {
            records.removeValue(forKey: workspaceID)
            unavailableWorkspaces[workspaceID] = nextUnavailable
            return
        }
        if refreshed.workspaceIsNoChange {
            return
        }
        guard let workspace = refreshed.workspace else { return }
        records[workspaceID] = makeRecord(from: workspace)
        unavailableWorkspaces.removeValue(forKey: workspaceID)
    }

    private func healthRejectionOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        record: WorkspaceRecord
    ) -> DomainCommandOutcome {
        let disposition: DomainCommandDisposition
        let errorCode: DomainCommandErrorCode
        let diagnostic: String
        switch record.health {
        case .writable:
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .failed,
                errorCode: .persistenceFailure,
                diagnostic: "unexpected_writable_health_rejection"
            )
        case let .externalConflict(reason):
            disposition = .conflict
            errorCode = .workspaceExternalConflict
            diagnostic = reason
        case let .degradedReadOnly(reason):
            disposition = .readOnly
            errorCode = .workspaceReadOnlyDegraded
            diagnostic = reason
        case .removed:
            disposition = .invalid
            errorCode = .workspaceUnavailable
            diagnostic = "workspace_removed"
        }
        return finalizeTransientOutcome(
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim,
            disposition: disposition,
            errorCode: errorCode,
            diagnostic: diagnostic
        )
    }

    private func finalizeConflictOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        record: WorkspaceRecord,
        diagnostic: String
    ) -> DomainCommandOutcome {
        finalizeTransientOutcome(
            DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .conflict,
                before: record.revisions,
                after: record.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: record.document.contentDigest,
                errorCode: .stateConflict,
                diagnostic: diagnostic,
                workspace: makeSnapshot(record)
            ),
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim
        )
    }

    private func unchangedOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        record original: WorkspaceRecord,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome {
        let record = original
        guard commandIdentityValidator != nil else {
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_validator_unavailable"
            )
        }
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .unchanged,
            before: record.revisions,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            diagnostic: nil,
            workspace: makeSnapshot(record)
        )
        let finalOutcome = finalizeTransientOutcome(
            outcome,
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim
        )
        var updatedRecord = record
        updatedRecord.operations.append(DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: finalOutcome))
        records[record.document.workspaceID] = updatedRecord

        publish(
            kind: .operationDeduplicated,
            workspaceID: record.document.workspaceID,
            contextID: nil,
            operationID: envelope.operationID,
            origin: envelope.origin,
            revisions: record.revisions,
            diagnostic: nil
        )

        return finalOutcome
    }

    private func readDeletionDiagnostic(workspaceID: UUID) -> String? {
        let storageDir = workspaceAuthorityScope.canonicalWorkspaceStorageDirectory
        let candidates = [
            storageDir.appendingPathComponent(".agentry-domain-runtime/deletion-tombstones/\(workspaceID.uuidString.lowercased()).json"),
            storageDir.appendingPathComponent(".agentry-domain-runtime/deletion-tombstones/\(workspaceID.uuidString.uppercased()).json"),
            storageDir.appendingPathComponent(".agentry-domain-runtime/deletions/\(workspaceID.uuidString.lowercased()).deletion"),
            storageDir.appendingPathComponent(".agentry-domain-runtime/deletions/\(workspaceID.uuidString.uppercased()).deletion"),
            storageDir.appendingPathComponent("DomainRuntime/deletion-tombstones/\(workspaceID.uuidString.lowercased()).json")
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = json["operation"] as? [String: Any]
            else { continue }
            return op["diagnostic"] as? String
        }
        return nil
    }

    private func collisionOutcome(
        _ operationID: UUID,
        workspace: DomainWorkspaceSnapshot?
    ) -> DomainCommandOutcome {
        DomainCommandOutcome(
            operationID: operationID,
            disposition: .invalid,
            before: workspace?.revisions,
            after: workspace?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: workspace?.document.contentDigest,
            errorCode: .operationIDCollision,
            diagnostic: "operation_id_reused_with_different_command",
            workspace: workspace
        )
    }

    private func persistenceFailureOutcome(
        _ envelope: DomainWorkspaceCommandEnvelope,
        record: WorkspaceRecord?,
        error: Error
    ) -> DomainCommandOutcome {
        let code: DomainCommandErrorCode = switch error {
        case DomainPersistenceError.lockTimedOut: .lockTimedOut
        case DomainPersistenceError.cancelled,
             DomainPersistenceError.runtimeShutdownRequested: .cancelled
        case DomainPersistenceError.mutationPermitInvalid: .runtimeReadOnlyDegraded
        case DomainPersistenceError.workspaceOutsideMutationScope: .workspaceReadOnlyDegraded
        default: .persistenceFailure
        }
        let disposition: DomainCommandDisposition = switch error {
        case DomainPersistenceError.mutationPermitInvalid,
             DomainPersistenceError.workspaceOutsideMutationScope:
            .readOnly
        default:
            .failed
        }
        return DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: disposition,
            before: record?.revisions,
            after: record?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record?.document.contentDigest,
            errorCode: code,
            diagnostic: String(describing: error),
            workspace: record.map(makeSnapshot)
        )
    }

    private func mapDirectJournalValidationError(
        _ error: CoreWorkspaceWorkingJournalValidationError,
        envelope: DomainWorkspaceCommandEnvelope,
        workspaceID: UUID,
        record: WorkspaceRecord? = nil
    ) -> DomainCommandOutcome {
        switch error {
        case .invalidRevisionState, .externalDocumentConflict:
            return DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .conflict,
                before: record?.revisions,
                after: record?.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: record?.document.contentDigest,
                errorCode: .stateConflict,
                diagnostic: "rust_direct_mutation_conflict",
                workspace: record.map(makeSnapshot)
            )
        case .workspaceQuarantined:
            if var r = record {
                r.health = .degradedReadOnly(reason: "workspace_quarantined")
                records[workspaceID] = r
            }
            return DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .readOnly,
                before: record?.revisions,
                after: record?.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: record?.document.contentDigest,
                errorCode: .workspaceReadOnlyDegraded,
                diagnostic: "workspace_quarantined",
                workspace: record.map(makeSnapshot)
            )
        case .storageLeaseRequired:
            return DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .readOnly,
                before: record?.revisions,
                after: record?.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: record?.document.contentDigest,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "canonical_storage_lease_required",
                workspace: record.map(makeSnapshot)
            )
        case .unsupportedCatalogSchemaVersion:
            return DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .readOnly,
                before: record?.revisions,
                after: record?.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: record?.document.contentDigest,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "unsupported_catalog_schema_version",
                workspace: record.map(makeSnapshot)
            )
        case .persistenceIoError:
            return DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .failed,
                before: record?.revisions,
                after: record?.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: record?.document.contentDigest,
                errorCode: .persistenceFailure,
                diagnostic: "persistence_io_error",
                workspace: record.map(makeSnapshot)
            )
        default:
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
    }

    /// Rejects before deduplication/admission. The operation ID is deliberately not retained: a
    /// later lease holder must be free to execute the same envelope after ownership handoff.
    private func unrecordedMutationAccessRejection(
        _ envelope: DomainWorkspaceCommandEnvelope,
        reason: String
    ) -> DomainCommandOutcome {
        let workspace = envelope.workspaceID.flatMap(canonicalWorkspaceSnapshot)
        return DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .readOnly,
            before: workspace?.revisions,
            after: workspace?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: workspace?.document.contentDigest,
            errorCode: .runtimeReadOnlyDegraded,
            diagnostic: reason,
            workspace: workspace
        )
    }

    /// Rejects before a trustworthy Rust identity exists. The operation remains retryable because
    /// no Swift-derived fingerprint may enter the durable/global deduplication ledger.
    private func unrecordedCommandIdentityRejection(
        _ envelope: DomainWorkspaceCommandEnvelope,
        disposition: DomainCommandDisposition,
        errorCode: DomainCommandErrorCode,
        diagnostic: String
    ) -> DomainCommandOutcome {
        let workspace = envelope.workspaceID.flatMap(canonicalWorkspaceSnapshot)
        return DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: disposition,
            before: workspace?.revisions,
            after: workspace?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: workspace?.document.contentDigest,
            errorCode: errorCode,
            diagnostic: diagnostic,
            workspace: workspace
        )
    }

    private func finalizeLifecycleCancellation(
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim
    ) -> DomainCommandOutcome {
        finalizeTransientOutcome(
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim,
            disposition: .failed,
            errorCode: .cancelled,
            diagnostic: "workspace_command_identity_cancelled"
        )
    }

    private func finalizeLifecycleShutdown(
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim
    ) -> DomainCommandOutcome {
        finalizeTransientOutcome(
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim,
            disposition: .failed,
            errorCode: .cancelled,
            diagnostic: "workspace_command_runtime_shutdown"
        )
    }

    private func commandLifecycleStopOutcome(
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim
    ) -> DomainCommandOutcome? {
        do {
            switch try commandClaim.checkpoint() {
            case .continueExecution:
                return nil
            case .cancelled:
                return finalizeTransientOutcome(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim,
                    disposition: .failed,
                    errorCode: .cancelled,
                    diagnostic: "workspace_command_identity_cancelled"
                )
            case .deadlineExceeded:
                return finalizeTransientOutcome(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim,
                    disposition: .failed,
                    errorCode: .cancelled,
                    diagnostic: "workspace_command_deadline_exceeded"
                )
            case .shutdownRequested:
                return finalizeTransientOutcome(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim,
                    disposition: .failed,
                    errorCode: .cancelled,
                    diagnostic: "workspace_command_runtime_shutdown"
                )
            }
        } catch {
            quarantineCommandAdmission()
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_lifecycle_receipt_invalid"
            )
        }
    }

    private func finalizeTransientOutcome(
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        disposition: DomainCommandDisposition,
        errorCode: DomainCommandErrorCode,
        diagnostic: String
    ) -> DomainCommandOutcome {
        let workspace = envelope.workspaceID.flatMap(canonicalWorkspaceSnapshot)
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: disposition,
            before: workspace?.revisions,
            after: workspace?.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: workspace?.document.contentDigest,
            errorCode: errorCode,
            diagnostic: diagnostic,
            workspace: workspace
        )
        return finalizeTransientOutcome(
            outcome,
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim
        )
    }

    private func finalizeTransientOutcome(
        _ outcome: DomainCommandOutcome,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim
    ) -> DomainCommandOutcome {
        let operation = DomainRecordedOperation(
            fingerprint: fingerprint,
            recordedAt: Date(),
            outcome: outcome
        )
        do {
            _ = try commandClaim.finalizeTransient(operation: operation)
            return outcome
        } catch let lifecycleError as DomainWorkspaceCommandLifecycleFinalizationError {
            let stopped = lifecycleStoppedOutcome(
                replacing: outcome,
                lifecycleError: lifecycleError
            )
            do {
                _ = try commandClaim.finalizeTransient(
                    operation: DomainRecordedOperation(
                        fingerprint: fingerprint,
                        recordedAt: Date(),
                        outcome: stopped
                    )
                )
            } catch {
                markCommandAdmissionReceiptMissing(workspaceID: envelope.workspaceID)
            }
            return stopped
        } catch {
            markCommandAdmissionReceiptMissing(workspaceID: envelope.workspaceID)
            return outcome
        }
    }

    private func lifecycleStoppedOutcome(
        replacing outcome: DomainCommandOutcome,
        lifecycleError: DomainWorkspaceCommandLifecycleFinalizationError
    ) -> DomainCommandOutcome {
        let diagnostic = switch lifecycleError {
        case .cancelled: "workspace_command_identity_cancelled"
        case .deadlineExceeded: "workspace_command_deadline_exceeded"
        case .shuttingDown: "workspace_command_runtime_shutdown"
        }
        return DomainCommandOutcome(
            operationID: outcome.operationID,
            disposition: .failed,
            before: outcome.before,
            after: outcome.after,
            catalogRevision: outcome.catalogRevision,
            resultingDigest: outcome.resultingDigest,
            errorCode: .cancelled,
            diagnostic: diagnostic,
            workspace: outcome.workspace
        )
    }

    private func recordMetric(
        envelope: DomainWorkspaceCommandEnvelope,
        outcome: DomainCommandOutcome,
        byteCount: Int
    ) {
        metrics.record(DomainRuntimeMetric(
            phase: .commit,
            name: "EditFlow.DomainRuntime.Commit",
            dimensions: [
                "runtime_id": identity.runtimeID.uuidString,
                "runtime_generation": "\(identity.lifecycleGeneration)",
                "runtime_mode": identity.mode.rawValue,
                "operation_id": envelope.operationID.uuidString,
                "workspace_id": envelope.workspaceID?.uuidString ?? "none",
                "context_revision": envelope.expectedContextRevision.map(String.init) ?? "none",
                "catalog_revision": "\(outcome.catalogRevision)",
                "working_revision": outcome.after.map { "\($0.workingRevision)" } ?? "none",
                "saved_revision": outcome.after.map { "\($0.savedRevision)" } ?? "none",
                "dirty_revision": outcome.after?.dirtyRevision.map(String.init) ?? "none",
                "disposition": outcome.disposition.rawValue,
                "byte_count": "\(byteCount)"
            ]
        ))
    }

    /// Read-only overlay helper. Durable command and recovery paths receive context authority from Rust.
    private static func updatedReadOverlayContextRevisions(
        previousDocument: DomainWorkspaceDocument,
        nextDocument: DomainWorkspaceDocument,
        previousRevisions: [UUID: DomainRevisionState],
        workspaceRevision: DomainRevisionState
    ) -> (revisions: [UUID: DomainRevisionState], tombstones: [UUID: UInt64]) {
        let old = Dictionary(uniqueKeysWithValues: previousDocument.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        let new = Dictionary(uniqueKeysWithValues: nextDocument.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        var revisions: [UUID: DomainRevisionState] = [:]
        for (contextID, digest) in new {
            if old[contextID] == digest, let existing = previousRevisions[contextID] {
                revisions[contextID] = existing
            } else {
                let previous = previousRevisions[contextID] ?? .initial
                let nextWorking = previous.workingRevision &+ 1
                revisions[contextID] = DomainRevisionState(
                    workingRevision: nextWorking,
                    savedRevision: previous.savedRevision,
                    dirtyRevision: nextWorking
                )
            }
        }
        let tombstones = Dictionary(uniqueKeysWithValues: old.keys.filter { new[$0] == nil }.map {
            ($0, workspaceRevision.workingRevision)
        })
        return (revisions, tombstones)
    }
}

private extension DomainWorkspaceCommandEnvelope {
    var workspaceID: UUID? {
        switch command {
        case let .createWorkspace(document): document.workspaceID
        case let .replaceWorkingDocument(document): document.workspaceID
        case let .replaceSelection(request): request.workspaceID
        case let .replaceContext(request): request.workspaceID
        case let .saveWorkspaceDocument(workspaceID): workspaceID
        case let .deleteWorkspace(workspaceID): workspaceID
        case let .resolveExternalConflict(workspaceID, _, _): workspaceID
        }
    }
}
