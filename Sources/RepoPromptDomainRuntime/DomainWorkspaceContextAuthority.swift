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
    private let projectionObservationSink: DomainWorkspaceProjectionObservationSink
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
    private var catalogMutationInProgress = false
    private var catalogMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var didBootstrap = false

    init(
        identity: DomainRuntimeIdentity,
        persistence: DomainPersistenceCoordinator,
        mutationAccess: DomainWorkspaceMutationAccess,
        metrics: DomainRuntimeMetricsSink,
        projectionObservationSink: DomainWorkspaceProjectionObservationSink,
        commandIdentityResolver: DomainWorkspaceCommandIdentityResolver? = nil
    ) {
        self.identity = identity
        self.persistence = persistence
        self.mutationAccess = mutationAccess
        workspaceAuthorityScope = mutationAccess.scope
        self.metrics = metrics
        self.projectionObservationSink = projectionObservationSink
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
        health = loaded.health
        catalogRevision = loaded.catalogRevision
        unavailableWorkspaces = Dictionary(uniqueKeysWithValues: loaded.unavailableWorkspaces.map {
            ($0.workspaceID, $0)
        })
        records = Dictionary(uniqueKeysWithValues: loaded.workspaces.map { workspace in
            (workspace.document.workspaceID, makeRecord(from: workspace))
        })
        projectionObservationSink.observe(
            records.values.map(\.document),
            source: .bootstrap
        )
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
        projectionObservationSink.observe(
            snapshot.workspaces.map(\.document),
            source: .catalogSnapshot
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
        if let snapshot {
            projectionObservationSink.observe(snapshot.document, source: .workspaceRead)
        }
        return snapshot.map {
            DomainWorkspaceReadFence(
                workspace: $0,
                catalogRevision: catalogRevision,
                publicationSequence: publicationSequence
            )
        }
    }

    /// Command outcomes and mutation admission must report canonical record state; the read
    /// overlay is routing-only and must never leak into recovery health or revision baselines.
    func canonicalWorkspaceSnapshot(_ workspaceID: UUID) -> DomainWorkspaceSnapshot? {
        let snapshot = records[workspaceID].map(makeSnapshot)
        if let snapshot {
            projectionObservationSink.observe(snapshot.document, source: .canonicalWorkspaceRead)
        }
        return snapshot
    }

    func contextSnapshot(_ identity: DomainContextIdentity) -> DomainContextSnapshot? {
        workspaceSnapshot(identity.workspaceID)?.contexts.first {
            $0.metadata.identity.contextID == identity.contextID
        }
    }

    func registerReadDocument(_ document: DomainWorkspaceDocument) async -> DomainWorkspaceSnapshot {
        await bootstrap()
        let previous = readRegistrations[document.workspaceID]
            ?? records[document.workspaceID].map(makeSnapshot)
        if let previous, previous.document.contentDigest == document.contentDigest {
            projectionObservationSink.observe(previous.document, source: .readRegistration)
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
            Self.updatedContextRevisions(
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
        projectionObservationSink.observe(projected.document, source: .readRegistration)
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
            if let document = outcome.workspace?.document {
                projectionObservationSink.observe(document, source: .commandOutcome)
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

    private func applyCommandAdmissionRecovery(
        _ recovery: DomainWorkspaceCommandAdmissionRecovery
    ) -> Bool {
        guard let validator = commandIdentityValidator else { return false }
        do {
            if let commandAdmission {
                _ = try commandAdmission.applyFullRecovery(recovery)
            } else {
                commandAdmission = try validator.beginCommandAdmission(recovery: recovery)
            }
            return true
        } catch {
            quarantineCommandAdmission()
            return false
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

    @discardableResult
    private func applyCommandAdmissionTargetRecovery(
        _ recovery: DomainWorkspaceCommandAdmissionTargetRecovery
    ) -> Bool {
        guard let commandAdmission else { return false }
        do {
            _ = try commandAdmission.applyTargetRecovery(recovery)
            return true
        } catch {
            quarantineCommandAdmission()
            return false
        }
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
        invalidateReadRegistrationIfSuperseded(
            workspaceID: workspaceID,
            disposition: prior.disposition,
            resultingDigest: prior.resultingDigest
        )
        return prior.outcome(workspace: record.map(makeSnapshot))
    }

    @discardableResult
    func activateMutationAccess() async -> DomainWorkspaceMutationAccessSnapshot {
        await bootstrap()
        let accessSnapshot = await mutationAccess.activate { permit in
            await self.reconcileAfterLeaseAcquisition(permit: permit)
        }
        applyMutationAccessSnapshot(accessSnapshot)
        projectionObservationSink.observe(
            records.values.map(\.document),
            source: .leaseReconciliation
        )
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
        if activity != .unchanged {
            projectionObservationSink.observe(
                records.values.map(\.document),
                source: .externalReload
            )
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
        let durableCatalog = await persistence.bootstrap(permit: permit)
        guard !Task.isCancelled,
              durableCatalog.health.acceptsMutations,
              let admissionRecovery = durableCatalog.admissionRecovery,
              applyCommandAdmissionRecovery(admissionRecovery)
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
            let durableCatalog = await persistence.bootstrap(permit: permit)
            guard !Task.isCancelled else { return .incomplete }
            let previousHealth = health
            guard durableCatalog.health.acceptsMutations else {
                health = durableCatalog.health
                catalogRevision = max(catalogRevision, durableCatalog.catalogRevision)
                if previousHealth != health {
                    publish(
                        kind: .degraded,
                        workspaceID: nil,
                        contextID: nil,
                        operationID: nil,
                        revisions: nil,
                        diagnostic: "workspace_catalog_degraded"
                    )
                }
                return .incomplete
            }
            guard let admissionRecovery = durableCatalog.admissionRecovery,
                  applyCommandAdmissionRecovery(admissionRecovery)
            else {
                markCommandAdmissionReceiptMissing(workspaceID: nil)
                return .incomplete
            }
            health = durableCatalog.health
            catalogRevision = max(catalogRevision, durableCatalog.catalogRevision)
            for workspaceID in durableCatalog.deletedWorkspaceIDs.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                unavailableWorkspaces.removeValue(forKey: workspaceID)
                if records.removeValue(forKey: workspaceID) != nil {
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
            }
            for unavailable in durableCatalog.unavailableWorkspaces {
                guard records[unavailable.workspaceID] == nil else { continue }
                unavailableWorkspaces[unavailable.workspaceID] = unavailable
                recoveryPending = true
            }
            for workspace in durableCatalog.workspaces
                where records[workspace.document.workspaceID] == nil
            {
                let workspaceID = workspace.document.workspaceID
                records[workspaceID] = makeRecord(from: workspace)
                readRegistrations.removeValue(forKey: workspaceID)
                unavailableWorkspaces.removeValue(forKey: workspaceID)
                changed = true
                publish(
                    kind: .externalReloaded,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: workspace.revisions,
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
            recoveryPending = recoveryPending || !health.acceptsMutations
        }

        for workspaceID in unavailableWorkspaces.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard let unavailable = unavailableWorkspaces[workspaceID] else { continue }
            let refreshed = await persistence.refreshWorkspace(
                workspaceID: workspaceID,
                fallbackFileURL: unavailable.fileURL
            )
            guard unavailableWorkspaces[workspaceID]?.fileMetadata == unavailable.fileMetadata,
                  let refreshed,
                  refreshed.health.acceptsMutations,
                  !refreshed.workspaceIsDeleted,
                  let recovered = refreshed.workspace,
                  recovered.health.acceptsMutations,
                  let admissionRecovery = refreshed.admissionRecovery,
                  applyCommandAdmissionTargetRecovery(admissionRecovery)
            else {
                recoveryPending = true
                continue
            }
            catalogRevision = max(catalogRevision, refreshed.catalogRevision)
            records[workspaceID] = makeRecord(from: recovered)
            readRegistrations.removeValue(forKey: workspaceID)
            unavailableWorkspaces.removeValue(forKey: workspaceID)
            changed = true
            publish(
                kind: .externalReloaded,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: nil,
                revisions: recovered.revisions,
                diagnostic: "workspace_document_recovered"
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
                    fallbackFileURL: current.document.fileURL
                )
                guard records[workspaceID]?.revisions == current.revisions else { continue }
                if let refreshed,
                   refreshed.health.acceptsMutations,
                   !refreshed.workspaceIsDeleted,
                   let recovered = refreshed.workspace,
                   recovered.health.acceptsMutations,
                   let admissionRecovery = refreshed.admissionRecovery,
                   applyCommandAdmissionTargetRecovery(admissionRecovery)
                {
                    catalogRevision = max(catalogRevision, refreshed.catalogRevision)
                    current = makeRecord(from: recovered)
                    records[workspaceID] = current
                    readRegistrations.removeValue(forKey: workspaceID)
                    changed = true
                    publish(
                        kind: .externalReloaded,
                        workspaceID: workspaceID,
                        contextID: nil,
                        operationID: nil,
                        revisions: current.revisions,
                        diagnostic: "workspace_persistence_recovered"
                    )
                } else {
                    recoveryPending = true
                    continue
                }
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
            externalDocument: nil,
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
            let revisions: DomainRevisionState
            let contextRevisions: [UUID: DomainRevisionState]
            let contextTombstones: [UUID: UInt64]
            if restoresCapturedDocument {
                let nextWorking = before.workingRevision &+ 1
                revisions = DomainRevisionState(
                    workingRevision: nextWorking,
                    savedRevision: before.savedRevision,
                    dirtyRevision: nextWorking
                )
                let contextUpdate = Self.updatedContextRevisions(
                    previousDocument: record.document,
                    nextDocument: localDocument,
                    previousRevisions: record.contextRevisions,
                    workspaceRevision: revisions
                )
                contextRevisions = contextUpdate.revisions
                contextTombstones = record.contextTombstones.merging(
                    contextUpdate.tombstones
                ) { _, new in new }
            } else {
                revisions = before
                contextRevisions = record.contextRevisions
                contextTombstones = record.contextTombstones
            }

            do {
                let persisted = try await persistence.persistConflictRebase(
                    document: localDocument,
                    externalSavedDigest: externalDocument.contentDigest,
                    expectedRevisions: before,
                    newRevisions: revisions,
                    contextRevisions: contextRevisions,
                    contextTombstones: contextTombstones,
                    operations: record.operations,
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
                        fileURL: localDocument.fileURL
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
        let nextWorking = before.workingRevision &+ 1
        let revisions = DomainRevisionState(
            workingRevision: nextWorking,
            savedRevision: before.savedRevision,
            dirtyRevision: nextWorking
        )
        let contextUpdate = Self.updatedContextRevisions(
            previousDocument: record.document,
            nextDocument: localDocument,
            previousRevisions: record.contextRevisions,
            workspaceRevision: revisions
        )
        do {
            let persisted = try await persistence.persistWorking(
                document: localDocument,
                expectedRevision: before.workingRevision,
                newRevision: revisions,
                contextRevisions: contextUpdate.revisions,
                contextTombstones: record.contextTombstones.merging(
                    contextUpdate.tombstones
                ) { _, new in new },
                operations: record.operations,
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
                    fileURL: localDocument.fileURL
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
            let next = before.workingRevision &+ 1
            let revisions = DomainRevisionState(
                workingRevision: next,
                savedRevision: next,
                dirtyRevision: nil
            )
            let contextUpdate = Self.updatedContextRevisions(
                previousDocument: record.document,
                nextDocument: externalDocument,
                previousRevisions: record.contextRevisions,
                workspaceRevision: revisions
            )
            do {
                let persisted = try await persistence.persistExternalReload(
                    document: externalDocument,
                    expectedRevision: before.workingRevision,
                    newRevision: next,
                    contextRevisions: contextUpdate.revisions,
                    contextTombstones: record.contextTombstones.merging(
                        contextUpdate.tombstones
                    ) { _, new in new },
                    operations: record.operations,
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
                        fileURL: externalDocument.fileURL
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
        await acquireCatalogMutation()
        defer { releaseCatalogMutation() }
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
        let revisions = DomainRevisionState(
            workingRevision: 1,
            savedRevision: 1,
            dirtyRevision: nil
        )
        let contextRevisions = Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
            ($0.identity.contextID, revisions)
        })
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: nil,
            after: revisions,
            catalogRevision: catalogRevision &+ 1,
            resultingDigest: document.contentDigest
        )
        let recorded = DomainRecordedOperation(
            fingerprint: fingerprint,
            recordedAt: Date(),
            outcome: provisional
        )
        do {
            let persisted = try await persistence.persistCreated(
                document: document,
                expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                operationID: envelope.operationID,
                contextRevisions: contextRevisions,
                operation: recorded,
                now: recorded.recordedAt,
                permit: permit,
                commandClaim: commandClaim
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
            recordCommandAdmissionFinalization(
                persisted.commandFinalization,
                workspaceID: document.workspaceID
            )
            let outcome = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: nil,
                after: record.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: document.contentDigest,
                workspace: makeSnapshot(record)
            )
            publish(
                kind: .workspaceCreated,
                workspaceID: document.workspaceID,
                contextID: nil,
                operationID: envelope.operationID,
                origin: envelope.origin,
                revisions: record.revisions,
                diagnostic: nil
            )
            recordMetric(envelope: envelope, outcome: outcome, byteCount: document.documentBytes.count)
            return outcome
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
                    fileURL: document.fileURL
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
        await acquireCatalogMutation()
        defer { releaseCatalogMutation() }
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
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: record.revisions,
            after: nil,
            catalogRevision: catalogRevision &+ 1,
            resultingDigest: nil
        )
        let operation = DomainRecordedOperation(
            fingerprint: fingerprint,
            recordedAt: Date(),
            outcome: provisional
        )
        do {
            let deleted = try await persistence.persistDeleted(
                document: record.document,
                expectedWorkspaceRevision: record.revisions.workingRevision,
                expectedCatalogRevision: envelope.expectedCatalogRevision ?? catalogRevision,
                operation: operation,
                now: operation.recordedAt,
                permit: permit,
                commandClaim: commandClaim
            )
            records.removeValue(forKey: workspaceID)
            catalogRevision = deleted.catalogRevision
            let cleanupDiagnostic = deleted.tombstone.operation.diagnostic
            recordCommandAdmissionFinalization(
                deleted.commandFinalization,
                workspaceID: nil
            )
            let outcome = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: record.revisions,
                after: nil,
                catalogRevision: catalogRevision,
                resultingDigest: nil,
                diagnostic: cleanupDiagnostic
            )
            publish(
                kind: .workspaceDeleted,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: envelope.operationID,
                origin: envelope.origin,
                revisions: nil,
                diagnostic: cleanupDiagnostic
            )
            recordMetric(envelope: envelope, outcome: outcome, byteCount: 0)
            return outcome
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
                    fileURL: record.document.fileURL
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

            let changedContextID = changedContextIDs.count == 1 ? changedContextIDs.first : nil
            let before = record.revisions
            let nextWorking = before.workingRevision &+ 1
            let revisions = DomainRevisionState(
                workingRevision: nextWorking,
                savedRevision: before.savedRevision,
                dirtyRevision: nextWorking
            )
            let contextUpdate = Self.updatedContextRevisions(
                previousDocument: record.document,
                nextDocument: document,
                previousRevisions: record.contextRevisions,
                workspaceRevision: revisions
            )
            let provisional = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: before,
                after: revisions,
                catalogRevision: catalogRevision,
                resultingDigest: document.contentDigest,
                workspace: nil
            )
            let recorded = DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: provisional)
            let operations = record.operations + [recorded]
            let persisted: DomainPersistenceWorkingCommit
            do {
                persisted = try await persistence.persistWorking(
                    document: document,
                    expectedRevision: before.workingRevision,
                    newRevision: revisions,
                    contextRevisions: contextUpdate.revisions,
                    contextTombstones: record.contextTombstones.merging(contextUpdate.tombstones) { _, new in new },
                    operations: operations,
                    now: recorded.recordedAt,
                    permit: permit,
                    commandClaim: commandClaim
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
                        fileURL: document.fileURL
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
            recordCommandAdmissionFinalization(
                persisted.commandFinalization,
                workspaceID: document.workspaceID
            )
            let applied = DomainCommandOutcome(
                operationID: envelope.operationID,
                disposition: .applied,
                before: before,
                after: record.revisions,
                catalogRevision: catalogRevision,
                resultingDigest: document.contentDigest,
                workspace: makeSnapshot(record)
            )
            publish(
                kind: .workingStateCommitted,
                workspaceID: document.workspaceID,
                contextID: changedContextID,
                operationID: envelope.operationID,
                origin: envelope.origin,
                revisions: record.revisions,
                diagnostic: isDurableReplay ? "durable_workspace_revision_replayed" : nil
            )
            recordMetric(envelope: envelope, outcome: applied, byteCount: document.documentBytes.count)
            return applied
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
        let after = DomainRevisionState(
            workingRevision: before.workingRevision,
            savedRevision: before.workingRevision,
            dirtyRevision: nil
        )
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: after,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest
        )
        let recorded = DomainRecordedOperation(fingerprint: fingerprint, recordedAt: Date(), outcome: provisional)
        let operations = record.operations + [recorded]
        do {
            let saved = try await persistence.persistSaved(
                document: record.document,
                expectedWorkingRevision: before.workingRevision,
                operationID: envelope.operationID,
                contextRevisions: record.contextRevisions,
                contextTombstones: record.contextTombstones,
                operations: operations,
                now: recorded.recordedAt,
                permit: permit,
                commandClaim: commandClaim
            )
            catalogRevision = max(catalogRevision, saved.catalogRevision)
            record.savedDigest = saved.journal.savedDigest
            record.revisions = saved.journal.revisions
            record.contextRevisions = saved.journal.contextRevisions
            record.operations = saved.journal.operations
            records[workspaceID] = record
            recordCommandAdmissionFinalization(
                saved.commandFinalization,
                workspaceID: workspaceID
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
                    fileURL: record.document.fileURL
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
        let applied = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            workspace: makeSnapshot(record)
        )
        publish(
            kind: .savedDocumentCommitted,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: envelope.operationID,
            origin: envelope.origin,
            revisions: record.revisions,
            diagnostic: allowsExternalRecovery ? nil : "external_document_rebased_and_saved"
        )
        recordMetric(envelope: envelope, outcome: applied, byteCount: record.document.documentBytes.count)
        return applied
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
        let after = acceptExternal
            ? DomainRevisionState(
                workingRevision: before.workingRevision &+ 1,
                savedRevision: before.workingRevision &+ 1,
                dirtyRevision: nil
            )
            : before
        let resultingDocument = acceptExternal ? external : record.document
        let provisional = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: after,
            catalogRevision: catalogRevision,
            resultingDigest: resultingDocument.contentDigest
        )
        let operation = DomainRecordedOperation(fingerprint: fingerprint, recordedAt: now, outcome: provisional)
        let operations = record.operations + [operation]
        var commandFinalization = DomainWorkspaceCommandFinalization.unreconciled
        do {
            if acceptExternal {
                let contextRevisions = Dictionary(uniqueKeysWithValues: external.metadata.contexts.map {
                    ($0.identity.contextID, after)
                })
                let persisted = try await persistence.persistExternalReload(
                    document: external,
                    expectedRevision: before.workingRevision,
                    newRevision: after.workingRevision,
                    contextRevisions: contextRevisions,
                    contextTombstones: record.contextTombstones,
                    operations: operations,
                    now: now,
                    permit: permit,
                    commandClaim: commandClaim
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.document = external
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.contextRevisions = persisted.journal.contextRevisions
                record.operations = persisted.journal.operations
                commandFinalization = persisted.commandFinalization
            } else {
                let persisted = try await persistence.persistConflictRebase(
                    document: record.document,
                    externalSavedDigest: external.contentDigest,
                    expectedRevisions: before,
                    newRevisions: after,
                    contextRevisions: record.contextRevisions,
                    contextTombstones: record.contextTombstones,
                    operations: operations,
                    now: now,
                    permit: permit,
                    commandClaim: commandClaim
                )
                catalogRevision = max(catalogRevision, persisted.catalogRevision)
                record.savedDigest = persisted.journal.savedDigest
                record.revisions = persisted.journal.revisions
                record.operations = persisted.journal.operations
                commandFinalization = persisted.commandFinalization
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
                    fileURL: record.document.fileURL
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
        recordCommandAdmissionFinalization(
            commandFinalization,
            workspaceID: workspaceID
        )
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .applied,
            before: before,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            workspace: makeSnapshot(record)
        )
        publish(
            kind: acceptExternal ? .externalReloaded : .workingStateCommitted,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: envelope.operationID,
            origin: envelope.origin,
            revisions: record.revisions,
            diagnostic: acceptExternal ? "external_conflict_accepted" : "local_conflict_rebased"
        )
        return outcome
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
        publicationSequence &+= 1
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
        projectionObservationSink.observePublication(
            event,
            workspaces: records.values.map(makeSnapshot)
        )
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private func acquireCatalogMutation() async {
        guard catalogMutationInProgress else {
            catalogMutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            catalogMutationWaiters.append(continuation)
        }
    }

    private func releaseCatalogMutation() {
        guard !catalogMutationWaiters.isEmpty else {
            catalogMutationInProgress = false
            return
        }
        catalogMutationWaiters.removeFirst().resume()
    }

    private func refreshAfterCASConflict(workspaceID: UUID, fileURL: URL) async {
        let previous = records[workspaceID]
        guard let refreshed = await persistence.refreshWorkspace(
            workspaceID: workspaceID,
            fallbackFileURL: fileURL
        ) else { return }
        guard let admissionRecovery = refreshed.admissionRecovery,
              applyCommandAdmissionTargetRecovery(admissionRecovery)
        else {
            markCommandAdmissionReceiptMissing(workspaceID: workspaceID)
            return
        }
        health = refreshed.health
        catalogRevision = max(catalogRevision, refreshed.catalogRevision)
        if refreshed.workspaceIsDeleted {
            records.removeValue(forKey: workspaceID)
            unavailableWorkspaces.removeValue(forKey: workspaceID)
            return
        }
        guard let workspace = refreshed.workspace else {
            if var previous {
                previous.health = .degradedReadOnly(reason: "workspace_document_unavailable")
                records[workspaceID] = previous
            }
            return
        }
        let canPreserveConflict = previous?.document.contentDigest == workspace.document.contentDigest
            && previous?.revisions == workspace.revisions
        let priorConflictDocument: DomainWorkspaceDocument? = if canPreserveConflict,
                                                                 case .externalConflict = previous?.health
        {
            previous?.externalDocument
        } else {
            nil
        }
        records[workspaceID] = WorkspaceRecord(
            document: workspace.document,
            savedDigest: workspace.savedDigest,
            revisions: workspace.revisions,
            contextRevisions: workspace.contextRevisions,
            contextTombstones: workspace.contextTombstones,
            operations: workspace.operations,
            health: priorConflictDocument == nil ? workspace.health : previous?.health ?? workspace.health,
            externalDocument: priorConflictDocument,
            fileMetadata: workspace.fileMetadata
        )
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
        let outcome = DomainCommandOutcome(
            operationID: envelope.operationID,
            disposition: .unchanged,
            before: record.revisions,
            after: record.revisions,
            catalogRevision: catalogRevision,
            resultingDigest: record.document.contentDigest,
            workspace: makeSnapshot(record)
        )
        let operation = DomainRecordedOperation(
            fingerprint: fingerprint,
            recordedAt: Date(),
            outcome: outcome
        )
        do {
            let persisted = try await persistence.persistUnchanged(
                document: record.document,
                expectedRevision: record.revisions.workingRevision,
                operation: operation,
                now: operation.recordedAt,
                permit: permit,
                commandClaim: commandClaim
            )
            catalogRevision = max(catalogRevision, persisted.catalogRevision)
            record.operations = persisted.journal.operations
            records[record.document.workspaceID] = record
            recordCommandAdmissionFinalization(
                persisted.commandFinalization,
                workspaceID: record.document.workspaceID
            )
            return outcome
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

    private static func updatedContextRevisions(
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
