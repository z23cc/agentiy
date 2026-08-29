import Foundation

package enum DomainExternalReloadActivity: Equatable, Sendable {
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
}

package struct DomainWorkspaceReadFence: Sendable {
    package let workspace: DomainWorkspaceSnapshot
    package let catalogRevision: UInt64
    package let publicationSequence: UInt64
}

package struct DomainWorkspaceAuthoritativeReadFence: Sendable {
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
    private enum ExternalReloadPass: Sendable {
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
        let snapshot = DomainWorkspaceCatalogSnapshot(
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
        return snapshot
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
        guard health.acceptsMutations else {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "runtime_authority_not_writable"
            )
        }
        if let expected = envelope.expectedCatalogRevision, expected != catalogRevision {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "catalog_revision_mismatch"
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
        case let .saveWorkspaceDocument(workspaceID):
            await saveWorkspace(
                workspaceID,
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                permit: permit
            )
        case let .resolveExternalConflict(workspaceID, acceptExternal, protectedAgentIdentities):
            await resolveExternalConflict(
                workspaceID,
                acceptExternal: acceptExternal,
                protectedAgentIdentities: protectedAgentIdentities,
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
        case .saveWorkspaceDocument, .deleteWorkspace, .resolveExternalConflict:
            nil
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

    private func recordCommandAdmissionFinalization(
        _ finalization: DomainWorkspaceCommandFinalization,
        workspaceID: UUID?
    ) {
        guard finalization != .reconciled else { return }
        quarantineCommandAdmission()
        markCommandAdmissionReceiptMissing(workspaceID: workspaceID)
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
            quarantineCommandAdmission()
            return unrecordedCommandIdentityRejection(
                envelope,
                disposition: .readOnly,
                errorCode: .runtimeReadOnlyDegraded,
                diagnostic: "workspace_command_admission_scope_invalid"
            )
        }
        if (prior.disposition == .applied || prior.disposition == .unchanged),
           case let .createWorkspace(document) = envelope.command
        {
            do {
                catalogRevision = try await max(
                    catalogRevision,
                    persistence.repairRecoveredCreate(
                        document: document,
                        now: Date(),
                        permit: permit
                    )
                )
            } catch {
                return persistenceFailureOutcome(envelope, record: record, error: error)
            }
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
        applyMutationAccessSnapshot(await mutationAccess.snapshot())
    }

    func finishMutationAccessDrainAndRelease() async {
        await mutationAccess.finishDrainAndRelease()
        applyMutationAccessSnapshot(await mutationAccess.snapshot())
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
                applyMutationAccessSnapshot(await mutationAccess.snapshot())
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
            let nextUnavailable = Dictionary(uniqueKeysWithValues:
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
            health = refreshed.health
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
                health = refreshed.health
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
            let external = await persistence.externalDocument(
                for: makeSnapshot(current),
                savedDigest: observedSavedDigest,
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
            case let .missing(metadata):
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
            case let .invalid(metadata):
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
            case let .changed(document, metadata):
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
                #if DEBUG
                    if let testBeforeExternalReconciliation {
                        await testBeforeExternalReconciliation(workspaceID)
                    }
                #endif
                switch await reconcileExternalDocument(
                    workspaceID: workspaceID,
                    externalDocument: document,
                    fileMetadata: metadata,
                    permit: permit
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

            do {
                let persisted = try await persistence.persistConflictRebaseRecovery(
                    document: localDocument,
                    externalSavedDigest: externalDocument.contentDigest,
                    expectedRevisions: before,
                    now: Date(),
                    permit: permit
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.document = localDocument
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.contextRevisions = persisted.journal.contextRevisions
                record.contextTombstones = persisted.journal.contextTombstones
                record.operations = persisted.journal.operations
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
            } catch let error as DomainPersistenceError {
                switch error {
                case .stateConflict:
                    await refreshAfterCASConflict(
                        workspaceID: workspaceID,
                        fileURL: localDocument.fileURL,
                        permit: permit
                    )
                    if Task.isCancelled { return .recoveryPending }
                    if attempt + 1 < Self.maximumCASRecoveryAttempts { continue }
                    return .recoveryPending
                case .externalDocumentConflict, .cancelled:
                    return .recoveryPending
                default:
                    if var current = records[workspaceID] {
                        current.health = .degradedReadOnly(
                            reason: "workspace_persistence_rebase_failed"
                        )
                        records[workspaceID] = current
                        publish(
                            kind: .degraded,
                            workspaceID: workspaceID,
                            contextID: nil,
                            operationID: nil,
                            revisions: current.revisions,
                            diagnostic: "workspace_persistence_rebase_failed"
                        )
                    }
                    return .failed
                }
            } catch is CancellationError {
                return .recoveryPending
            } catch {
                if var current = records[workspaceID] {
                    current.health = .degradedReadOnly(
                        reason: "workspace_persistence_rebase_failed"
                    )
                    records[workspaceID] = current
                    publish(
                        kind: .degraded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: current.revisions,
                        diagnostic: "workspace_persistence_rebase_failed"
                    )
                }
                return .failed
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
        do {
            let persisted = try await persistence.persistWorkingRecovery(
                document: localDocument,
                expectedRevision: before.workingRevision,
                now: Date(),
                permit: permit
            )
            catalogRevision = max(catalogRevision, persisted.catalogRevision)
            record.document = localDocument
            record.revisions = persisted.journal.revisions
            record.contextRevisions = persisted.journal.contextRevisions
            record.contextTombstones = persisted.journal.contextTombstones
            record.operations = persisted.journal.operations
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
        } catch let error as DomainPersistenceError {
            if case .stateConflict = error {
                await refreshAfterCASConflict(
                    workspaceID: workspaceID,
                    fileURL: localDocument.fileURL,
                    permit: permit
                )
                return .recoveryPending
            }
            if case .cancelled = error { return .recoveryPending }
            if var current = records[workspaceID] {
                current.health = .degradedReadOnly(
                    reason: "workspace_persistence_replay_failed"
                )
                records[workspaceID] = current
                publish(
                    kind: .degraded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: current.revisions,
                    diagnostic: "workspace_persistence_replay_failed"
                )
            }
            return .failed
        } catch is CancellationError {
            return .recoveryPending
        } catch {
            if var current = records[workspaceID] {
                current.health = .degradedReadOnly(
                    reason: "workspace_persistence_replay_failed"
                )
                records[workspaceID] = current
                publish(
                    kind: .degraded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: current.revisions,
                    diagnostic: "workspace_persistence_replay_failed"
                )
            }
            return .failed
        }
    }

    private func reconcileExternalDocument(
        workspaceID: UUID,
        externalDocument: DomainWorkspaceDocument,
        fileMetadata: DomainFileMetadata,
        permit: DomainWorkspaceMutationPermit
    ) async -> DirtyExternalRebaseResult {
        for attempt in 0 ..< Self.maximumCASRecoveryAttempts {
            guard var record = records[workspaceID], record.health.acceptsMutations else {
                return .failed
            }
            if record.revisions.dirtyRevision != nil {
                return await rebaseDirtyWorkingDocument(
                    workspaceID: workspaceID,
                    localDocument: record.document,
                    externalDocument: externalDocument,
                    fileMetadata: fileMetadata,
                    permit: permit
                )
            }

            let before = record.revisions
            do {
                let persisted = try await persistence.persistExternalReloadRecovery(
                    document: externalDocument,
                    expectedRevision: before.workingRevision,
                    now: Date(),
                    permit: permit
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.document = externalDocument
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.contextRevisions = persisted.journal.contextRevisions
                record.contextTombstones = persisted.journal.contextTombstones
                record.operations = persisted.journal.operations
                record.externalDocument = nil
                record.fileMetadata = fileMetadata
                records[workspaceID] = record
                readRegistrations.removeValue(forKey: workspaceID)
                let diagnostic: String? = if persisted.revisionSidecarMissing {
                    "external_reload_revision_sidecar_missing"
                } else if attempt == 0 {
                    nil
                } else {
                    "external_reload_revision_replayed"
                }
                publish(
                    kind: .externalReloaded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: record.revisions,
                    diagnostic: diagnostic
                )
                return .applied
            } catch let error as DomainPersistenceError {
                switch error {
                case .stateConflict:
                    await refreshAfterCASConflict(
                        workspaceID: workspaceID,
                        fileURL: externalDocument.fileURL,
                        permit: permit
                    )
                    if Task.isCancelled { return .recoveryPending }
                    if attempt + 1 < Self.maximumCASRecoveryAttempts { continue }
                    return .recoveryPending
                case .cancelled:
                    return .recoveryPending
                default:
                    if var current = records[workspaceID] {
                        current.health = .degradedReadOnly(
                            reason: "workspace_external_reload_persistence_failed"
                        )
                        records[workspaceID] = current
                        publish(
                            kind: .degraded,
                            workspaceID: workspaceID,
                            contextID: nil,
                            operationID: nil,
                            revisions: current.revisions,
                            diagnostic: "workspace_external_reload_persistence_failed"
                        )
                    }
                    return .failed
                }
            } catch is CancellationError {
                return .recoveryPending
            } catch {
                if var current = records[workspaceID] {
                    current.health = .degradedReadOnly(
                        reason: "workspace_external_reload_persistence_failed"
                    )
                    records[workspaceID] = current
                    publish(
                        kind: .degraded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: current.revisions,
                        diagnostic: "workspace_external_reload_persistence_failed"
                    )
                }
                return .failed
            }
        }
        return .recoveryPending
    }

    private func createWorkspace(
        _ document: DomainWorkspaceDocument,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome {
        if let expected = envelope.expectedCatalogRevision, expected != catalogRevision {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "catalog_revision_mismatch"
            )
        }
        if let existing = records[document.workspaceID] {
            if existing.document.contentDigest == document.contentDigest {
                return await unchangedOutcome(envelope, fingerprint: fingerprint, commandClaim: commandClaim, record: existing, permit: permit)
            }
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "workspace_already_exists"
            )
        }
        guard envelope.expectedWorkspaceRevision == nil || envelope.expectedWorkspaceRevision == 0 else {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "workspace_does_not_exist_at_expected_revision"
            )
        }
        let now = Date()
        let recorded = DomainRecordedOperation(
            operationID: envelope.operationID,
            fingerprint: fingerprint,
            recordedAt: now
        )
        do {
            let persisted = try await persistence.persistCreated(
                document: document,
                expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                operationID: envelope.operationID,
                operation: recorded,
                now: now,
                permit: permit,
                commandClaim: commandClaim,
            )
            catalogRevision = persisted.catalogRevision
            let record = WorkspaceRecord(
                document: document,
                savedDigest: persisted.journal.savedDigest,
                revisions: persisted.journal.revisions,
                contextRevisions: persisted.journal.contextRevisions,
                contextTombstones: persisted.journal.contextTombstones,
                operations: persisted.journal.operations,
                health: .writable,
                externalDocument: nil,
                fileMetadata: .missing
            )
            records[document.workspaceID] = record
            installCommandAuthorityFinalization(
                persisted.authorityFinalization,
                lifecycleWorkspaceID: document.workspaceID,
                origin: envelope.origin,
                diagnostic: nil
            )
            return commandResultOutcome(
                persisted.authorityFinalization,
                envelope: envelope,
                workspace: makeSnapshot(record),
                byteCount: document.documentBytes.count,
                diagnostic: nil
            )
        } catch let error as DomainPersistenceError {
            if case .runtimeShutdownRequested = error {
                return finalizeLifecycleShutdown(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            if case .cancelled = error {
                return finalizeLifecycleCancellation(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            if case .stateConflict = error {
                await refreshAfterCASConflict(
                    workspaceID: document.workspaceID,
                    fileURL: document.fileURL,
                    permit: permit
                )
                return finalizeTransientOutcome(
                    DomainCommandOutcome(
                        operationID: envelope.operationID,
                        disposition: .conflict,
                        before: nil,
                        after: records[document.workspaceID]?.revisions,
                        catalogRevision: catalogRevision,
                        resultingDigest: records[document.workspaceID]?.document.contentDigest,
                        errorCode: .stateConflict,
                        diagnostic: "durable_create_conflict",
                        workspace: records[document.workspaceID].map(makeSnapshot)
                    ),
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            return persistenceFailureOutcome(envelope, record: nil, error: error)
        } catch {
            return persistenceFailureOutcome(envelope, record: nil, error: error)
        }
    }

    private func deleteWorkspace(
        _ workspaceID: UUID,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome {
        if let expected = envelope.expectedCatalogRevision, expected != catalogRevision {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .conflict,
                errorCode: .stateConflict,
                diagnostic: "catalog_revision_mismatch"
            )
        }
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
        guard record.health.acceptsMutations else {
            return healthRejectionOutcome(envelope, fingerprint: fingerprint, commandClaim: commandClaim, record: record)
        }
        if let expected = envelope.expectedWorkspaceRevision,
           expected != record.revisions.workingRevision
        {
            return finalizeConflictOutcome(
                envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                record: record,
                diagnostic: "workspace_revision_mismatch"
            )
        }
        let operation = DomainRecordedOperation(
            operationID: envelope.operationID,
            fingerprint: fingerprint,
            recordedAt: Date()
        )
        do {
            let deleted = try await persistence.persistDeleted(
                document: record.document,
                expectedWorkspaceRevision: record.revisions.workingRevision,
                expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                operation: operation,
                now: operation.recordedAt,
                permit: permit,
                commandClaim: commandClaim,
            )
            records.removeValue(forKey: workspaceID)
            catalogRevision = deleted.catalogRevision
            let cleanupDiagnostic = deleted.tombstone.operation.diagnostic
            installCommandAuthorityFinalization(
                deleted.authorityFinalization,
                lifecycleWorkspaceID: nil,
                origin: envelope.origin,
                diagnostic: cleanupDiagnostic
            )
            return commandResultOutcome(
                deleted.authorityFinalization,
                envelope: envelope,
                workspace: nil,
                byteCount: 0,
                diagnostic: cleanupDiagnostic
            )
        } catch let error as DomainPersistenceError {
            if case .runtimeShutdownRequested = error {
                return finalizeLifecycleShutdown(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            if case .cancelled = error {
                return finalizeLifecycleCancellation(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            if case .stateConflict = error {
                await refreshAfterCASConflict(
                    workspaceID: workspaceID,
                    fileURL: record.document.fileURL,
                    permit: permit
                )
                return finalizeTransientOutcome(
                    DomainCommandOutcome(
                        operationID: envelope.operationID,
                        disposition: .conflict,
                        before: record.revisions,
                        after: records[workspaceID]?.revisions,
                        catalogRevision: catalogRevision,
                        resultingDigest: records[workspaceID]?.document.contentDigest,
                        errorCode: .stateConflict,
                        diagnostic: "durable_delete_conflict",
                        workspace: records[workspaceID].map(makeSnapshot)
                    ),
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            return persistenceFailureOutcome(envelope, record: record, error: error)
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
    }

    private func replaceWorkingDocument(
        _ document: DomainWorkspaceDocument,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit
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

        var isDurableReplay = false
        while let current = records[document.workspaceID] {
            var record = current
            guard record.health.acceptsMutations else {
                return healthRejectionOutcome(envelope, fingerprint: fingerprint, commandClaim: commandClaim, record: record)
            }
            if !isDurableReplay,
               let expected = envelope.expectedWorkspaceRevision,
               expected != record.revisions.workingRevision
            {
                return finalizeConflictOutcome(
                    envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim,
                    record: record,
                    diagnostic: "workspace_revision_mismatch"
                )
            }
            let changedContextIDs = Self.changedContextIDs(from: record.document, to: document)
            if let expectedContext = envelope.expectedContextRevision {
                guard changedContextIDs.count == 1,
                      let changedContextID = changedContextIDs.first
                else {
                    return finalizeConflictOutcome(
                        envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim,
                        record: record,
                        diagnostic: isDurableReplay
                            ? "context_revision_scope_mismatch_after_refresh"
                            : "context_revision_scope_mismatch"
                    )
                }
                if !isDurableReplay,
                   expectedContext != record.contextRevisions[changedContextID]?.workingRevision
                {
                    return finalizeConflictOutcome(
                        envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim,
                        record: record,
                        diagnostic: "context_revision_mismatch"
                    )
                }
            }
            guard record.document.contentDigest != document.contentDigest else {
                return await unchangedOutcome(envelope, fingerprint: fingerprint, commandClaim: commandClaim, record: record, permit: permit)
            }

            let before = record.revisions
            let now = Date()
            let authorityDiagnostic = isDurableReplay ? "durable_workspace_revision_replayed" : nil
            let persisted: DomainPersistenceWorkingCommit
            do {
                persisted = try await persistence.persistWorking(
                    document: document,
                    expectedRevision: before.workingRevision,
                    operationID: envelope.operationID,
                    fingerprint: fingerprint,
                    now: now,
                    permit: permit,
                    commandClaim: commandClaim,
                    )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
            } catch let error as DomainPersistenceError {
                if case .runtimeShutdownRequested = error {
                    return finalizeLifecycleShutdown(
                        envelope: envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim
                    )
                }
                if case .cancelled = error {
                    return finalizeLifecycleCancellation(
                        envelope: envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim
                    )
                }
                if case .stateConflict = error {
                    await refreshAfterCASConflict(
                        workspaceID: document.workspaceID,
                        fileURL: document.fileURL,
                        permit: permit
                    )
                    if let replayed = await recordedOutcomeAfterReconciliation(
                        for: envelope,
                        fingerprint: fingerprint,
                        permit: permit
                    ) {
                        return replayed
                    }
                    guard !Task.isCancelled else {
                        return persistenceFailureOutcome(
                            envelope,
                            record: records[document.workspaceID] ?? record,
                            error: DomainPersistenceError.cancelled
                        )
                    }
                    if !isDurableReplay {
                        isDurableReplay = true
                        continue
                    }
                    let refreshed = records[document.workspaceID]
                    return finalizeTransientOutcome(
                        DomainCommandOutcome(
                            operationID: envelope.operationID,
                            disposition: .conflict,
                            before: before,
                            after: refreshed?.revisions,
                            catalogRevision: catalogRevision,
                            resultingDigest: refreshed?.document.contentDigest,
                            errorCode: .stateConflict,
                            diagnostic: "durable_workspace_revision_mismatch_after_replay",
                            workspace: refreshed.map(makeSnapshot)
                        ),
                        envelope: envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim
                    )
                }
                return persistenceFailureOutcome(envelope, record: record, error: error)
            } catch {
                return persistenceFailureOutcome(envelope, record: record, error: error)
            }
            record.document = document
            record.revisions = persisted.journal.revisions
            record.contextRevisions = persisted.journal.contextRevisions
            record.contextTombstones = persisted.journal.contextTombstones
            record.operations = persisted.journal.operations
            records[document.workspaceID] = record
            installCommandAuthorityFinalization(
                persisted.authorityFinalization,
                lifecycleWorkspaceID: document.workspaceID,
                origin: envelope.origin,
                diagnostic: authorityDiagnostic
            )
            return commandResultOutcome(
                persisted.authorityFinalization,
                envelope: envelope,
                workspace: makeSnapshot(record),
                byteCount: document.documentBytes.count,
                diagnostic: authorityDiagnostic
            )
        }

        return finalizeTransientOutcome(
            envelope: envelope,
            fingerprint: fingerprint,
            commandClaim: commandClaim,
            disposition: .invalid,
            errorCode: .workspaceUnavailable,
            diagnostic: "workspace_requires_explicit_create_command"
        )
    }

    private func saveWorkspace(
        _ workspaceID: UUID,
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit,
        validateExpectedRevision: Bool = true,
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
        guard record.health.acceptsMutations else {
            return healthRejectionOutcome(envelope, fingerprint: fingerprint, commandClaim: commandClaim, record: record)
        }
        if validateExpectedRevision,
           let expected = envelope.expectedWorkspaceRevision,
           expected != record.revisions.workingRevision
        {
            return finalizeConflictOutcome(
                envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                record: record,
                diagnostic: "workspace_revision_mismatch"
            )
        }
        guard record.revisions.dirtyRevision != nil else {
            return await unchangedOutcome(envelope, fingerprint: fingerprint, commandClaim: commandClaim, record: record, permit: permit)
        }
        let before = record.revisions
        let now = Date()
        let authorityDiagnostic = allowsExternalRecovery ? nil : "external_document_rebased_and_saved"
        var authorityFinalization = DomainWorkspaceCommandAuthorityFinalization(
            commandFinalization: .unreconciled,
            commandResult: nil,
            authorityPublication: nil
        )
        do {
            let saved = try await persistence.persistSaved(
                document: record.document,
                expectedWorkingRevision: before.workingRevision,
                operationID: envelope.operationID,
                fingerprint: fingerprint,
                now: now,
                permit: permit,
                commandClaim: commandClaim,
            )
            catalogRevision = max(catalogRevision, saved.catalogRevision)
            record.savedDigest = saved.journal.savedDigest
            record.revisions = saved.journal.revisions
            record.contextRevisions = saved.journal.contextRevisions
            record.operations = saved.journal.operations
            records[workspaceID] = record
            authorityFinalization = saved.authorityFinalization
            installCommandAuthorityFinalization(
                authorityFinalization,
                lifecycleWorkspaceID: workspaceID,
                origin: envelope.origin,
                diagnostic: authorityDiagnostic
            )
        } catch let error as DomainPersistenceError {
            if case .runtimeShutdownRequested = error {
                return finalizeLifecycleShutdown(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            if case .cancelled = error {
                return finalizeLifecycleCancellation(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            if case .stateConflict = error {
                await refreshAfterCASConflict(
                    workspaceID: workspaceID,
                    fileURL: record.document.fileURL,
                    permit: permit
                )
                guard allowsCASRecovery else {
                    return finalizeConflictOutcome(
                        envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim,
                        record: records[workspaceID] ?? record,
                        diagnostic: "durable_save_revision_mismatch_after_replay"
                    )
                }
                switch await replayCapturedWorkingDocument(
                    workspaceID: workspaceID,
                    localDocument: record.document,
                    permit: permit
                ) {
                case .applied:
                    return await saveWorkspace(
                        workspaceID,
                        envelope: envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim,
                        permit: permit,
                        validateExpectedRevision: false,
                        allowsCASRecovery: false,
                        allowsExternalRecovery: allowsExternalRecovery
                    )
                case .recoveryPending:
                    return finalizeConflictOutcome(
                        envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim,
                        record: records[workspaceID] ?? record,
                        diagnostic: "durable_save_revision_replay_pending"
                    )
                case .failed:
                    return healthRejectionOutcome(
                        envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim,
                        record: records[workspaceID] ?? record
                    )
                }
            }
            guard case .externalDocumentConflict = error else {
                return persistenceFailureOutcome(envelope, record: record, error: error)
            }
            guard allowsExternalRecovery else {
                return finalizeConflictOutcome(
                    envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim,
                    record: record,
                    diagnostic: "external_document_changed_during_recovered_save"
                )
            }

            let observedRevisions = record.revisions
            let observedSavedDigest = record.savedDigest
            let observedMetadata = record.fileMetadata
            let external = await persistence.externalDocument(
                for: makeSnapshot(record),
                savedDigest: observedSavedDigest,
                knownMetadata: observedMetadata
            )
            guard var current = records[workspaceID],
                  current.revisions == observedRevisions,
                  current.savedDigest == observedSavedDigest,
                  current.fileMetadata == observedMetadata
            else {
                return finalizeConflictOutcome(
                    envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim,
                    record: records[workspaceID] ?? record,
                    diagnostic: "external_document_changed_during_save_recovery"
                )
            }

            switch external {
            case let .changed(document, metadata):
                switch await rebaseDirtyWorkingDocument(
                    workspaceID: workspaceID,
                    localDocument: record.document,
                    externalDocument: document,
                    fileMetadata: metadata,
                    permit: permit
                ) {
                case .applied:
                    return await saveWorkspace(
                        workspaceID,
                        envelope: envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim,
                        permit: permit,
                        validateExpectedRevision: false,
                        allowsCASRecovery: allowsCASRecovery,
                        allowsExternalRecovery: false
                    )
                case .recoveryPending:
                    return finalizeConflictOutcome(
                        envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim,
                        record: records[workspaceID] ?? record,
                        diagnostic: "external_document_rebase_pending"
                    )
                case .failed:
                    return healthRejectionOutcome(
                        envelope,
                        fingerprint: fingerprint,
                        commandClaim: commandClaim,
                        record: records[workspaceID] ?? record
                    )
                }
            case let .invalid(metadata):
                current.health = .degradedReadOnly(reason: "external_workspace_decode_failed")
                current.externalDocument = nil
                current.fileMetadata = metadata
                records[workspaceID] = current
                publish(
                    kind: .degraded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: envelope.operationID,
                    origin: envelope.origin,
                    revisions: current.revisions,
                    diagnostic: "external_workspace_decode_failed"
                )
                return healthRejectionOutcome(envelope, fingerprint: fingerprint, commandClaim: commandClaim, record: current)
            case let .unchanged(metadata), let .missing(metadata):
                current.fileMetadata = metadata
                records[workspaceID] = current
                return finalizeConflictOutcome(
                    envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim,
                    record: current,
                    diagnostic: "external_document_changed_during_save_recovery"
                )
            case .cancelled:
                return finalizeLifecycleCancellation(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
        return commandResultOutcome(
            authorityFinalization,
            envelope: envelope,
            workspace: makeSnapshot(record),
            byteCount: record.document.documentBytes.count,
            diagnostic: authorityDiagnostic
        )
    }

    private func resolveExternalConflict(
        _ workspaceID: UUID,
        acceptExternal: Bool,
        protectedAgentIdentities: [DomainProtectedAgentIdentity],
        envelope: DomainWorkspaceCommandEnvelope,
        fingerprint: String,
        commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim,
        permit: DomainWorkspaceMutationPermit
    ) async -> DomainCommandOutcome {
        guard var record = records[workspaceID],
              case .externalConflict = record.health,
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
        let before = record.revisions
        if let expected = envelope.expectedWorkspaceRevision,
           expected != before.workingRevision
        {
            return finalizeConflictOutcome(
                envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                record: record,
                diagnostic: "workspace_revision_mismatch"
            )
        }
        if acceptExternal,
           let diagnostic = Self.protectedAgentIdentityConflict(
               local: record.document,
               external: external,
               callerClaims: protectedAgentIdentities
           )
        {
            return finalizeTransientOutcome(
                envelope: envelope,
                fingerprint: fingerprint,
                commandClaim: commandClaim,
                disposition: .conflict,
                errorCode: .protectedAgentIdentityConflict,
                diagnostic: diagnostic
            )
        }
        let now = Date()
        let authorityDiagnostic = acceptExternal
            ? "external_conflict_accepted"
            : "local_conflict_rebased"
        var authorityFinalization = DomainWorkspaceCommandAuthorityFinalization(
            commandFinalization: .unreconciled,
            commandResult: nil,
            authorityPublication: nil
        )
        do {
            if acceptExternal {
                let persisted = try await persistence.persistExternalReload(
                    document: external,
                    expectedRevision: before.workingRevision,
                    operationID: envelope.operationID,
                    fingerprint: fingerprint,
                    now: now,
                    permit: permit,
                    commandClaim: commandClaim,
                    )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.document = external
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.contextRevisions = persisted.journal.contextRevisions
                record.operations = persisted.journal.operations
                authorityFinalization = persisted.authorityFinalization
            } else {
                let persisted = try await persistence.persistConflictRebase(
                    document: record.document,
                    externalSavedDigest: external.contentDigest,
                    expectedRevisions: before,
                    operationID: envelope.operationID,
                    fingerprint: fingerprint,
                    now: now,
                    permit: permit,
                    commandClaim: commandClaim,
                    )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.operations = persisted.journal.operations
                authorityFinalization = persisted.authorityFinalization
            }
        } catch let error as DomainPersistenceError {
            if case .runtimeShutdownRequested = error {
                return finalizeLifecycleShutdown(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            if case .cancelled = error {
                return finalizeLifecycleCancellation(
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            if case .stateConflict = error {
                await refreshAfterCASConflict(
                    workspaceID: workspaceID,
                    fileURL: record.document.fileURL,
                    permit: permit
                )
                let refreshed = records[workspaceID]
                return finalizeTransientOutcome(
                    DomainCommandOutcome(
                        operationID: envelope.operationID,
                        disposition: .conflict,
                        before: before,
                        after: refreshed?.revisions,
                        catalogRevision: catalogRevision,
                        resultingDigest: refreshed?.document.contentDigest,
                        errorCode: .stateConflict,
                        diagnostic: "durable_workspace_revision_mismatch",
                        workspace: refreshed.map(makeSnapshot)
                    ),
                    envelope: envelope,
                    fingerprint: fingerprint,
                    commandClaim: commandClaim
                )
            }
            return persistenceFailureOutcome(envelope, record: record, error: error)
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
        record.health = .writable
        record.externalDocument = nil
        records[workspaceID] = record
        installCommandAuthorityFinalization(
            authorityFinalization,
            lifecycleWorkspaceID: workspaceID,
            origin: envelope.origin,
            diagnostic: authorityDiagnostic
        )
        return commandResultOutcome(
            authorityFinalization,
            envelope: envelope,
            workspace: makeSnapshot(record),
            byteCount: record.document.documentBytes.count,
            diagnostic: authorityDiagnostic
        )
    }

    private func commandResultOutcome(
        _ finalization: DomainWorkspaceCommandAuthorityFinalization,
        envelope: DomainWorkspaceCommandEnvelope,
        workspace: DomainWorkspaceSnapshot?,
        byteCount: Int,
        diagnostic: String?
    ) -> DomainCommandOutcome {
        let valid: Bool = {
            guard finalization.commandFinalization == .reconciled,
                  let result = finalization.commandResult,
                  let publication = finalization.authorityPublication,
                  let expectedWorkspaceID = envelope.workspaceID,
                  result.workspaceID == expectedWorkspaceID,
                  result.operation.operationID == envelope.operationID,
                  publication.catalogRevision == result.catalogRevision,
                  publication.publicationSequence == self.publicationSequence,
                  publication.event.kind == result.publicationKind,
                  publication.event.operationID == result.operation.operationID
            else { return false }
            return true
        }()
        guard valid,
              let result = finalization.commandResult
        else {
            let outcome = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .failed,
                before: workspace?.revisions,
                after: workspace?.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: workspace?.document.contentDigest,
                errorCode: .persistenceFailure,
                diagnostic: "workspace_command_result_receipt_missing",
                workspace: workspace
            )
            recordMetric(envelope: envelope, outcome: outcome, byteCount: byteCount)
            return outcome
        }
        let operation = result.operation
        let outcome = DomainCommandOutcome(
            operationID: operation.operationID,
            disposition: operation.disposition,
            before: operation.before,
            after: operation.after,
            catalogRevision: result.catalogRevision,
            resultingDigest: result.resultingDigest,
            diagnostic: diagnostic,
            workspace: workspace
        )
        recordMetric(envelope: envelope, outcome: outcome, byteCount: byteCount)
        return outcome
    }

    private func commandPublicationInvalidatesReadRegistration(
        _ kind: DomainWorkspaceEventKind
    ) -> Bool {
        switch kind {
        case .workspaceCreated, .workspaceDeleted, .workingStateCommitted,
             .savedDocumentCommitted, .externalReloaded, .externalConflict,
             .operationDeduplicated:
            true
        case .bootstrapped, .degraded, .routingChanged:
            false
        }
    }

    private func installCommandAuthorityFinalization(
        _ finalization: DomainWorkspaceCommandAuthorityFinalization,
        lifecycleWorkspaceID: UUID?,
        origin: DomainCommandOrigin,
        diagnostic: String?
    ) {
        defer {
            recordCommandAdmissionFinalization(
                finalization.commandFinalization,
                workspaceID: lifecycleWorkspaceID
            )
        }
        let nextPublicationSequence = publicationSequence.addingReportingOverflow(1)
        guard !nextPublicationSequence.overflow,
              let receipt = finalization.authorityPublication,
              receipt.previousPublicationSequence == publicationSequence,
              receipt.publicationSequence == nextPublicationSequence.partialValue,
              receipt.catalogRevision == catalogRevision,
              receipt.event.sequence == receipt.publicationSequence,
              receipt.event.catalogRevision == receipt.catalogRevision,
              receipt.event.workspaceID == lifecycleWorkspaceID || lifecycleWorkspaceID == nil,
              (finalization.commandFinalization == .reconciled
                  ? finalization.commandResult.map {
                      $0.catalogRevision == receipt.catalogRevision
                          && $0.publicationKind == receipt.event.kind
                          && $0.operation.operationID == receipt.event.operationID
                  } == true
                  : finalization.commandResult == nil)
        else {
            quarantineCommandAdmission()
            markCommandAdmissionReceiptMissing(workspaceID: lifecycleWorkspaceID)
            return
        }
        let event = receipt.event
        if commandPublicationInvalidatesReadRegistration(event.kind),
           let workspaceID = event.workspaceID
        {
            readRegistrations.removeValue(forKey: workspaceID)
        }
        publicationSequence = receipt.publicationSequence
        let publishedEvent = DomainWorkspaceEvent(
            runtimeID: identity.runtimeID,
            sequence: event.sequence,
            catalogRevision: event.catalogRevision,
            kind: event.kind,
            workspaceID: event.workspaceID,
            contextID: event.contextID,
            operationID: event.operationID,
            origin: origin,
            revisions: event.revisions,
            timestamp: Date(),
            diagnostic: diagnostic
        )
        for continuation in subscribers.values {
            continuation.yield(publishedEvent)
        }
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
            let receipt = try commandAdmission.publishAuthorityState(
                workspaces: authoritativeReadSnapshots(),
                catalogRevision: catalogRevision,
                kind: kind,
                workspaceID: workspaceID,
                contextID: contextID,
                operationID: operationID,
                revisions: revisions
            )
            guard receipt.previousPublicationSequence == publicationSequence,
                  receipt.catalogRevision == catalogRevision
            else {
                throw DomainWorkspaceCommandAdmissionError.invalidReceipt
            }
            publicationSequence = receipt.publicationSequence
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

    private static func protectedAgentIdentityConflict(
        local: DomainWorkspaceDocument,
        external: DomainWorkspaceDocument,
        callerClaims: [DomainProtectedAgentIdentity]
    ) -> String? {
        var protectedByTabID = Dictionary(
            uniqueKeysWithValues: local.metadata.agentIdentityClaims
                .filter(\.requiresProtection)
                .map { ($0.tabID, $0) }
        )
        for callerClaim in callerClaims where callerClaim.requiresProtection {
            if let existing = protectedByTabID[callerClaim.tabID] {
                guard existing.location == callerClaim.location else {
                    return "protected_agent_identity_precondition_mismatch"
                }
                if let existingSessionID = existing.activeAgentSessionID,
                   let callerSessionID = callerClaim.activeAgentSessionID,
                   existingSessionID != callerSessionID
                {
                    return "protected_agent_identity_precondition_mismatch"
                }
                protectedByTabID[callerClaim.tabID] = DomainProtectedAgentIdentity(
                    tabID: callerClaim.tabID,
                    location: existing.location,
                    activeAgentSessionID: callerClaim.activeAgentSessionID ?? existing.activeAgentSessionID,
                    isPinned: existing.isPinned || callerClaim.isPinned
                )
            } else {
                protectedByTabID[callerClaim.tabID] = callerClaim
            }
        }

        let externalByTabID = Dictionary(
            uniqueKeysWithValues: external.metadata.agentIdentityClaims.map { ($0.tabID, $0) }
        )
        let sessionCounts = Dictionary(
            grouping: external.metadata.agentIdentityClaims.compactMap(\.activeAgentSessionID),
            by: { $0 }
        ).mapValues(\.count)
        for claim in protectedByTabID.values {
            guard let candidate = externalByTabID[claim.tabID] else {
                return "protected_agent_identity_missing"
            }
            guard candidate.location == claim.location else {
                return "protected_agent_identity_location_changed"
            }
            guard candidate.activeAgentSessionID == claim.activeAgentSessionID else {
                return "protected_agent_identity_rebound"
            }
            guard !claim.isPinned || candidate.isPinned else {
                return "protected_agent_identity_unpinned"
            }
            if let sessionID = claim.activeAgentSessionID,
               sessionCounts[sessionID] != 1
            {
                return "protected_agent_identity_duplicated"
            }
        }
        return nil
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
        var record = original
        let operation = DomainRecordedOperation(
            operationID: envelope.operationID,
            fingerprint: fingerprint,
            recordedAt: Date()
        )
        do {
            let persisted = try await persistence.persistUnchanged(
                document: record.document,
                expectedRevision: record.revisions.workingRevision,
                operation: operation,
                now: operation.recordedAt,
                permit: permit,
                commandClaim: commandClaim,
            )
            catalogRevision = max(catalogRevision, persisted.catalogRevision)
            record.operations = persisted.journal.operations
            records[record.document.workspaceID] = record
            installCommandAuthorityFinalization(
                persisted.authorityFinalization,
                lifecycleWorkspaceID: record.document.workspaceID,
                origin: envelope.origin,
                diagnostic: nil
            )
            return commandResultOutcome(
                persisted.authorityFinalization,
                envelope: envelope,
                workspace: makeSnapshot(record),
                byteCount: record.document.documentBytes.count,
                diagnostic: nil
            )
        } catch {
            return persistenceFailureOutcome(envelope, record: record, error: error)
        }
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

    private static func changedContextIDs(
        from previous: DomainWorkspaceDocument?,
        to next: DomainWorkspaceDocument
    ) -> Set<UUID> {
        guard let previous else { return [] }
        let old = Dictionary(uniqueKeysWithValues: previous.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        let new = Dictionary(uniqueKeysWithValues: next.metadata.contexts.map {
            ($0.identity.contextID, $0.contentDigest)
        })
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
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
        case let .saveWorkspaceDocument(workspaceID): workspaceID
        case let .deleteWorkspace(workspaceID): workspaceID
            case let .resolveExternalConflict(workspaceID, _, _): workspaceID
        }
    }
}
