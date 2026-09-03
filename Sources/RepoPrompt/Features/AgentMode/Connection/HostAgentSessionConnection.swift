import AgentryCoreBridge
import Foundation
import RepoPromptDomainRuntime

/// Production `AgentSessionConnection` (ADR-0011 P3): the GUI talks only to the Agent Session Host.
///
/// Wraps `AgentSessionHostClient`. In-process extras (`StartSpec.executionContext`,
/// `UserMessage.draftText`, `UserMessage.codexAttemptID`) are ignored. `events` is the sole
/// consumer of `client.events` and republishes onto the seam. A socket drop between accept and
/// settle is `.uncertain` — clients re-attach; they must not retry blindly.
actor HostAgentSessionConnection: AgentSessionConnection {
    struct Configuration {
        var client: AgentSessionHostClientConfiguration
        var snapshotTimeout: TimeInterval
        var launchContext: HostAgentSessionLaunchPreparation.Context

        static func makeProductionConfiguration() -> Configuration {
            let protocolVersion = (try? CoreAgentHostProtocol().limits().protocolVersion) ?? 1
            let paths = AgentSessionHostPaths.resolve(protocolVersion: protocolVersion)
            var client = AgentSessionHostClientConfiguration(paths: paths, clientKind: .gui)
            if let executable = AgentSessionHostExecutable.resolve() {
                client.spawn = .spawnIfAbsent(
                    executable: executable,
                    environment: AgentSessionHostLaunchEnvironment.production(),
                    leaseWait: 15
                )
            }
            return Configuration(
                client: client,
                snapshotTimeout: 15,
                launchContext: .production()
            )
        }
    }

    private let configuration: Configuration
    private let codec = CoreAgentHostProtocol()
    private var injectedClient: AgentSessionHostClient?
    private var client: AgentSessionHostClient?
    private var eventPump: Task<Void, Never>?
    private var snapshotAssembler = AgentSessionHostSnapshotAssembler()
    private var latestSnapshots: [String: AgentHostAgentSessionSnapshotV1] = [:]
    private var snapshotWaiters: [String: CheckedContinuation<AgentHostAgentSessionSnapshotV1, Error>] = [:]
    private var tabIDBySessionID: [UUID: UUID] = [:]
    private var generationBySessionID: [UUID: Data] = [:]
    private var interactionGenerationByID: [UUID: Data] = [:]
    private var attachedSessionIDs: Set<UUID> = []
    private var pendingWorkingDirectory: String?
    private let eventContinuation: AsyncStream<AgentSessionConnectionEvent>.Continuation
    let events: AsyncStream<AgentSessionConnectionEvent>

    init(configuration: Configuration) {
        self.configuration = configuration
        var continuation: AsyncStream<AgentSessionConnectionEvent>.Continuation?
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventContinuation = continuation!
    }

    /// Test seam: a pre-connected client (in-process host harness). Starts the event pump immediately.
    init(client: AgentSessionHostClient, snapshotTimeout: TimeInterval = 15) {
        configuration = Configuration(
            client: client.configuration,
            snapshotTimeout: snapshotTimeout,
            launchContext: .disabled()
        )
        injectedClient = client
        self.client = client
        var continuation: AsyncStream<AgentSessionConnectionEvent>.Continuation?
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventContinuation = continuation!
    }

    deinit {
        eventPump?.cancel()
        eventContinuation.finish()
    }

    // MARK: - AgentSessionConnection

    func attach(sessionID: UUID, resume: AgentSessionCursor?) async throws -> AgentSessionAttachResult {
        let client = try await ensureClient()
        let key = sessionID.uuidString.lowercased()
        latestSnapshots[key] = nil
        let outcome: AgentHostCommandResponseOutcomeV1
        do {
            outcome = try await client.send(.attach(.init(
                sessionId: key,
                resumeCursor: resume?.deliveryCursor,
                resumeGeneration: resume?.generation ?? Data()
            )))
        } catch {
            throw mapTransport(error, operationID: UUID(), mutating: false)
        }
        let attached = try unpackAttached(outcome)
        remember(sessionID: sessionID, generation: attached.generation)
        let hostSnapshot: AgentHostAgentSessionSnapshotV1? = if attached.snapshotFollows {
            try await waitForSnapshot(sessionID: key)
        } else {
            latestSnapshots.removeValue(forKey: key)
        }
        if let hostSnapshot {
            rememberInteractions(hostSnapshot.pendingInteractions)
        }
        let tabID = tabIDBySessionID[sessionID] ?? sessionID
        let snapshot = HostAgentSessionMapping.snapshot(
            hostSnapshot,
            summary: attached.summary ?? hostSnapshot?.summary,
            tabID: tabID,
            sessionID: sessionID
        )
        attachedSessionIDs.insert(sessionID)
        let cursor = HostAgentSessionMapping.cursor(generation: attached.generation, delivery: attached.nextCursor)
        eventContinuation.yield(.attached(sessionID: sessionID, cursor: cursor))
        return AgentSessionAttachResult(
            snapshot: snapshot,
            cursor: cursor,
            replay: HostAgentSessionMapping.replay(attached.replay)
        )
    }

    func detach(sessionID: UUID) async {
        attachedSessionIDs.remove(sessionID)
        if let client, client.isConnected {
            try? await client.detach(sessionID: sessionID.uuidString.lowercased())
        }
        eventContinuation.yield(.detached(sessionID: sessionID))
    }

    func start(_ spec: AgentSessionStartSpec, operationID: UUID) async throws -> AgentSessionStartResult {
        let prepared = try await HostAgentSessionLaunchPreparation.prepare(
            spec,
            context: configuration.launchContext
        )
        if let cwd = prepared.worktreeID, HostAgentSessionLaunchPreparation.looksLikeFilesystemPath(cwd) {
            pendingWorkingDirectory = cwd
        }
        let sessionID = prepared.resumeSessionID ?? UUID()
        tabIDBySessionID[sessionID] = prepared.tabID
        let hostSpec = HostAgentSessionMapping.sessionSpec(prepared, sessionID: sessionID)
        let outcome = try await sendMutating(
            .start(.init(key: mutationKey(operationID), spec: hostSpec)),
            operationID: operationID
        )
        switch outcome {
        case let .result(result):
            guard case let .started(started) = result.result else {
                throw AgentSessionConnectionError.commandRejected("start settled without SessionStarted")
            }
            remember(sessionID: sessionID, generation: started.generation)
            let mapped = try HostAgentSessionMapping.startResult(started, tabID: prepared.tabID)
            publishLocalSettlement(
                sessionID: mapped.sessionID,
                operationID: operationID,
                outcome: .started(mapped),
                cursor: mapped.cursor
            )
            return mapped
        case let .rejected(rejected) where rejected.reason == .sessionExists:
            let steered = try await steer(
                sessionID: sessionID,
                message: prepared.message,
                operationID: operationID
            )
            let mapped = AgentSessionStartResult(
                sessionID: sessionID,
                sendOutcome: steered.sendOutcome,
                cursor: steered.recordedCursor
            )
            publishLocalSettlement(
                sessionID: sessionID,
                operationID: operationID,
                outcome: .started(mapped),
                cursor: mapped.cursor
            )
            return mapped
        default:
            throw mapOutcome(outcome, operationID: operationID)
        }
    }

    func steer(sessionID: UUID, message: AgentSessionUserMessage, operationID: UUID) async throws -> AgentSessionSteerResult {
        let outcome = try await sendMutating(
            .steer(.init(
                key: mutationKey(operationID),
                sessionId: sessionID.uuidString.lowercased(),
                message: HostAgentSessionMapping.userMessage(message),
                delivery: .queueForNextTurn
            )),
            operationID: operationID
        )
        guard case let .result(result) = outcome, case let .steered(steered) = result.result else {
            throw mapOutcome(outcome, operationID: operationID)
        }
        let mapped = try HostAgentSessionMapping.steerResult(steered, generation: generationBySessionID[sessionID] ?? Data())
        publishLocalSettlement(
            sessionID: sessionID,
            operationID: operationID,
            outcome: .steered(mapped),
            cursor: mapped.recordedCursor
        )
        return mapped
    }

    func interrupt(sessionID: UUID, reason _: AgentSessionInterruptReason, operationID: UUID) async throws -> AgentSessionInterruptResult {
        let outcome = try await sendMutating(
            .interrupt(.init(
                key: mutationKey(operationID),
                sessionId: sessionID.uuidString.lowercased(),
                turnId: ""
            )),
            operationID: operationID
        )
        guard case let .result(result) = outcome, case let .interrupted(interrupted) = result.result else {
            throw mapOutcome(outcome, operationID: operationID)
        }
        let mapped = try HostAgentSessionMapping.interruptResult(interrupted)
        publishLocalSettlement(
            sessionID: sessionID,
            operationID: operationID,
            outcome: .interrupted(mapped),
            cursor: nil
        )
        return mapped
    }

    func respond(
        sessionID: UUID,
        interactionID: UUID,
        answer: AgentInteractionAnswer,
        operationID: UUID
    ) async throws -> AgentSessionRespondResult {
        let generation = interactionGenerationByID[interactionID] ?? Data()
        let outcome = try await sendMutating(
            .respondInteraction(.init(
                key: mutationKey(operationID),
                sessionId: sessionID.uuidString.lowercased(),
                interactionId: interactionID.uuidString.lowercased(),
                interactionGeneration: generation,
                answer: HostAgentSessionMapping.interactionAnswer(answer)
            )),
            operationID: operationID
        )
        guard case let .result(result) = outcome, case let .interactionResponded(responded) = result.result else {
            throw mapOutcome(outcome, operationID: operationID)
        }
        let mapped = try HostAgentSessionMapping.respondResult(responded)
        publishLocalSettlement(
            sessionID: sessionID,
            operationID: operationID,
            outcome: .interactionResponded(mapped),
            cursor: nil
        )
        return mapped
    }

    func stop(sessionID: UUID, reason: AgentSessionStopReason, operationID: UUID) async throws -> AgentSessionStopResult {
        let outcome = try await sendMutating(
            .stop(.init(
                key: mutationKey(operationID),
                sessionId: sessionID.uuidString.lowercased(),
                reason: HostAgentSessionMapping.stopReason(reason)
            )),
            operationID: operationID
        )
        guard case let .result(result) = outcome, case let .stopped(stopped) = result.result else {
            throw mapOutcome(outcome, operationID: operationID)
        }
        attachedSessionIDs.remove(sessionID)
        let mapped = try HostAgentSessionMapping.stopResult(stopped)
        publishLocalSettlement(
            sessionID: sessionID,
            operationID: operationID,
            outcome: .stopped(mapped),
            cursor: nil
        )
        return mapped
    }

    func detachAll() async {
        let ids = attachedSessionIDs
        for sessionID in ids {
            await detach(sessionID: sessionID)
        }
    }

    func prepareHostUpdate() async throws -> AgentSessionPrepareUpdateResult {
        let client: AgentSessionHostClient
        do {
            client = try await ensureClient()
        } catch {
            return AgentSessionPrepareUpdateResult(allCheckpointed: true, detail: "no host")
        }
        let outcome: AgentHostCommandResponseOutcomeV1
        do {
            outcome = try await client.send(.hostControl(.init(
                key: mutationKey(UUID()),
                action: .prepareUpdate(.init(deadlineSeconds: 5))
            )))
        } catch {
            throw AgentSessionConnectionError.uncertain(operationID: UUID(), detail: String(describing: error))
        }
        guard case let .result(result) = outcome,
              case let .hostControl(control) = result.result,
              case let .prepareUpdate(prepared) = control.result
        else {
            throw mapOutcome(outcome, operationID: UUID())
        }
        let failed = prepared.checkpoints.count(where: { !$0.succeeded })
        let detail = prepared.allCheckpointed
            ? "checkpointed \(prepared.checkpoints.count) session(s)"
            : "\(failed) session(s) failed to checkpoint"
        return AgentSessionPrepareUpdateResult(allCheckpointed: prepared.allCheckpointed, detail: detail)
    }

    func listSessions(includeTerminal: Bool, workspaceID: UUID?) async throws -> [AgentSessionListedSummary] {
        let client: AgentSessionHostClient
        do {
            client = try await ensureClient()
        } catch {
            return []
        }
        let list: AgentHostSessionListV1
        do {
            list = try await client.listSessions(
                includeTerminal: includeTerminal,
                workspaceID: workspaceID?.uuidString.lowercased() ?? ""
            )
        } catch {
            throw AgentSessionConnectionError.commandRejected("list_sessions: \(error)")
        }
        return list.sessions.compactMap(HostAgentSessionMapping.listedSummary)
    }

    // MARK: - Client

    private func ensureClient() async throws -> AgentSessionHostClient {
        if let client, client.isConnected {
            if eventPump == nil {
                startEventPump(client)
            }
            return client
        }
        if let injected = injectedClient, injected.isConnected {
            client = injected
            startEventPump(injected)
            return injected
        }
        do {
            let connected = try await AgentSessionHostClient.connect(configuration: clientConfiguration())
            client = connected
            startEventPump(connected)
            return connected
        } catch {
            client = nil
            throw AgentSessionConnectionError.commandRejected("Agent Session Host is unavailable: \(error)")
        }
    }

    private func clientConfiguration() -> AgentSessionHostClientConfiguration {
        var client = configuration.client
        guard let cwd = pendingWorkingDirectory,
              HostAgentSessionLaunchPreparation.looksLikeFilesystemPath(cwd),
              case let .spawnIfAbsent(executable, extraArguments, environment, leaseWait) = client.spawn
        else {
            return client
        }
        var env = environment ?? AgentSessionHostLaunchEnvironment.production()
        env[AgentSessionHostLaunchEnvironment.workingDirectoryKey] = cwd
        client.spawn = .spawnIfAbsent(
            executable: executable,
            extraArguments: extraArguments,
            environment: env,
            leaseWait: leaseWait
        )
        return client
    }

    private func startEventPump(_ client: AgentSessionHostClient) {
        eventPump?.cancel()
        let stream = client.events
        eventPump = Task { [weak self] in
            for await event in stream {
                await self?.handleClientEvent(event)
            }
        }
    }

    private func handleClientEvent(_ event: AgentSessionHostClientEvent) {
        do {
            if let snapshot = try snapshotAssembler.consume(event, codec: codec) {
                let key = snapshot.sessionId.lowercased()
                latestSnapshots[key] = snapshot
                rememberInteractions(snapshot.pendingInteractions)
                if let waiter = snapshotWaiters.removeValue(forKey: key) {
                    waiter.resume(returning: snapshot)
                }
            }
        } catch {
            failSnapshotWaiters(error)
        }
        switch event {
        case let .event(notification):
            publishNotification(notification)
        case let .resnapshotRequired(required):
            if let sessionID = UUID(uuidString: required.sessionId) {
                eventContinuation.yield(.resnapshotRequired(sessionID: sessionID))
            }
        case let .disconnected(error):
            client = nil
            eventPump = nil
            failSnapshotWaiters(error ?? AgentSessionHostClientError.disconnected)
        case .snapshotBegin, .snapshotChunk, .snapshotEnd, .notice:
            break
        }
    }

    private func publishNotification(_ notification: AgentHostEventNotificationV1) {
        let sessionID = UUID(uuidString: notification.sessionId)
        if let sessionID {
            remember(sessionID: sessionID, generation: notification.generation)
        }
        let cursor = HostAgentSessionMapping.cursor(
            generation: notification.generation,
            delivery: notification.deliveryCursor
        )
        switch notification.event?.body {
        case let .commandAccepted(accepted):
            let operationID = UUID(uuidString: accepted.operationId) ?? UUID()
            eventContinuation.yield(.commandAccepted(sessionID: sessionID, operationID: operationID, cursor: cursor))
        case let .commandSettled(settled):
            let operationID = UUID(uuidString: settled.operationId) ?? UUID()
            let outcome = HostAgentSessionMapping.commandOutcome(
                settled.settlement,
                generation: notification.generation,
                operationID: operationID
            )
            eventContinuation.yield(.commandSettled(
                sessionID: sessionID,
                operationID: operationID,
                outcome: outcome,
                cursor: cursor
            ))
        case let .runtimeEvent(runtime):
            if let sessionID, let mapped = HostAgentSessionMapping.runtimeEvent(runtime) {
                eventContinuation.yield(.runtime(sessionID: sessionID, event: mapped, cursor: cursor))
            }
        case let .runLifecycle(lifecycle):
            if case let .terminated(terminated) = lifecycle.kind, let sessionID {
                eventContinuation.yield(.runTerminated(
                    sessionID: sessionID,
                    outcome: HostAgentSessionMapping.terminalOutcome(terminated),
                    cursor: cursor
                ))
            }
        case let .interaction(interaction):
            if case let .requested(requested) = interaction.kind {
                rememberInteractions([requested.interaction].compactMap(\.self))
            }
        default:
            break
        }
    }

    private func waitForSnapshot(sessionID: String) async throws -> AgentHostAgentSessionSnapshotV1 {
        if let ready = latestSnapshots.removeValue(forKey: sessionID) {
            return ready
        }
        return try await withCheckedThrowingContinuation { continuation in
            snapshotWaiters[sessionID] = continuation
            let timeout = configuration.snapshotTimeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.timeoutSnapshotWaiter(sessionID: sessionID)
            }
        }
    }

    private func timeoutSnapshotWaiter(sessionID: String) {
        guard let waiter = snapshotWaiters.removeValue(forKey: sessionID) else { return }
        waiter.resume(throwing: AgentSessionConnectionError.commandRejected("attach snapshot timed out"))
    }

    private func failSnapshotWaiters(_ error: Error) {
        let waiters = snapshotWaiters
        snapshotWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: error)
        }
    }

    private func sendMutating(
        _ command: AgentHostCommandRequestCommandV1,
        operationID: UUID
    ) async throws -> AgentHostCommandResponseOutcomeV1 {
        let client: AgentSessionHostClient
        do {
            client = try await ensureClient()
        } catch {
            throw mapTransport(error, operationID: operationID, mutating: true)
        }
        do {
            return try await client.send(command)
        } catch {
            throw mapTransport(error, operationID: operationID, mutating: true)
        }
    }

    private func unpackAttached(_ outcome: AgentHostCommandResponseOutcomeV1) throws -> AgentHostAttachResultV1 {
        switch outcome {
        case let .result(result):
            guard case let .attached(attached) = result.result else {
                throw AgentSessionConnectionError.commandRejected("attach settled without AttachResult")
            }
            return attached
        case let .rejected(rejected):
            throw HostAgentSessionMapping.rejection(rejected, operationID: UUID())
        case let .uncertain(uncertain):
            throw AgentSessionConnectionError.uncertain(
                operationID: UUID(uuidString: uncertain.operationId) ?? UUID(),
                detail: uncertain.detail
            )
        case let .operationConflict(conflict):
            throw AgentSessionConnectionError.operationConflict(UUID(uuidString: conflict.operationId) ?? UUID())
        }
    }

    private func mapOutcome(_ outcome: AgentHostCommandResponseOutcomeV1, operationID: UUID) -> AgentSessionConnectionError {
        switch outcome {
        case let .rejected(rejected):
            HostAgentSessionMapping.rejection(rejected, operationID: operationID)
        case let .uncertain(uncertain):
            .uncertain(operationID: UUID(uuidString: uncertain.operationId) ?? operationID, detail: uncertain.detail)
        case let .operationConflict(conflict):
            .operationConflict(UUID(uuidString: conflict.operationId) ?? operationID)
        case .result:
            .commandRejected("unexpected host result")
        }
    }

    private func mapTransport(_ error: Error, operationID: UUID, mutating: Bool) -> AgentSessionConnectionError {
        if mutating {
            if case let .uncertain(operationID, detail) = error as? AgentSessionConnectionError {
                return .uncertain(operationID: operationID, detail: detail)
            }
            return .uncertain(operationID: operationID, detail: String(describing: error))
        }
        if let connectionError = error as? AgentSessionConnectionError {
            return connectionError
        }
        return .commandRejected(String(describing: error))
    }

    private func mutationKey(_ operationID: UUID) -> AgentHostMutationKeyV1 {
        AgentSessionHostClient.mutationKey(operationID: operationID.uuidString.lowercased())
    }

    private func remember(sessionID: UUID, generation: Data) {
        generationBySessionID[sessionID] = generation
    }

    /// Commanding clients observe settlement on the RPC path even before they attach
    /// (host fan-out only goes to attachments). Attached clients may also see the
    /// same settlement as an `EventNotification`; the VM treats a second refresh as a no-op.
    private func publishLocalSettlement(
        sessionID: UUID?,
        operationID: UUID,
        outcome: AgentSessionCommandOutcome,
        cursor: AgentSessionCursor?
    ) {
        eventContinuation.yield(.commandAccepted(sessionID: sessionID, operationID: operationID, cursor: cursor))
        eventContinuation.yield(.commandSettled(
            sessionID: sessionID,
            operationID: operationID,
            outcome: outcome,
            cursor: cursor
        ))
    }

    private func rememberInteractions(_ pending: [AgentHostPendingInteractionV1]) {
        for item in pending {
            if let id = UUID(uuidString: item.interactionId) {
                interactionGenerationByID[id] = item.interactionGeneration
            }
        }
    }
}
