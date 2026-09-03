import AgentryCoreBridge
import Foundation
import Logging

/// Tunables of one host process. Production uses the defaults; tests shrink queues and timers.
package struct AgentSessionHostConfiguration {
    /// Exit after this many seconds with no connections, no attachments and no live run; `nil` never.
    package var idleExitSeconds: TimeInterval?
    package var outboundLimits: AgentSessionHostOutboundQueue.Limits
    package var maximumClients: Int
    package var replayBatchRecords: UInt32
    package var replayBatchBytes: UInt32
    package var acceptPollInterval: TimeInterval
    package var peerVerifier: any AgentSessionHostPeerVerifier
    package var capabilities: [AgentHostCapabilityV1]

    package init(
        idleExitSeconds: TimeInterval? = 300,
        outboundLimits: AgentSessionHostOutboundQueue.Limits = AgentSessionHostOutboundQueue.Limits(),
        maximumClients: Int = 64,
        replayBatchRecords: UInt32 = 256,
        replayBatchBytes: UInt32 = 1024 * 1024,
        acceptPollInterval: TimeInterval = 0.5,
        peerVerifier: any AgentSessionHostPeerVerifier = AgentSessionHostSameProductPeerVerifier(),
        capabilities: [AgentHostCapabilityV1] = [.snapshotStreaming, .prepareUpdate]
    ) {
        self.idleExitSeconds = idleExitSeconds
        self.outboundLimits = outboundLimits
        self.maximumClients = maximumClients
        self.replayBatchRecords = replayBatchRecords
        self.replayBatchBytes = replayBatchBytes
        self.acceptPollInterval = acceptPollInterval
        self.peerVerifier = peerVerifier
        self.capabilities = capabilities
    }
}

package typealias AgentSessionHostConnectionID = UUID

/// Host-level side effect a command asks the server to perform after the response is queued.
package enum AgentSessionHostControlEffect: Equatable {
    case shutdown(mode: AgentHostShutdownModeV1, deadlineSeconds: UInt32)
}

package struct AgentSessionRouterRecoveryReport: Equatable {
    package struct Skipped: Equatable {
        package var path: String
        package var reason: String
    }

    package var recoveredSessionIDs: [String] = []
    package var importedSessionIDs: [String] = []
    package var demotedSessionIDs: [String] = []
    package var tornTailSessionIDs: [String] = []
    package var skipped: [Skipped] = []

    package init() {}
}

/// Opaque `generation` bytes: host instance nonce (16 bytes) ‖ big-endian executor attempt.
package enum AgentSessionHostGeneration {
    package static func make(nonce: Data, attempt: UInt32) -> Data {
        var generation = nonce
        withUnsafeBytes(of: attempt.bigEndian) { generation.append(contentsOf: $0) }
        return generation
    }
}

/// `SessionRouter { sessionID → SessionExecutor }` (design §4.2). Owns the event logs, derived state,
/// idempotency bookkeeping, attachments and fanout for every hosted session; delegates execution to
/// one `AgentSessionExecutor` per session and never assumes where that executor runs. Folding and
/// snapshot `compact` use Rust `CoreAgentSessionTranscriptReducer`; `.events` bytes come from
/// `AgentSessionLog` FFI, then attached clients are fed from that append (design §7.2 / P6-b
/// publish). All state is guarded by one lock; executor methods are always invoked with the lock
/// released so an executor may emit synchronously from any thread without deadlocking.
package final class AgentSessionRouter: @unchecked Sendable {
    package let hostInstanceID: String
    package let paths: AgentSessionHostPaths
    package let codec: CoreAgentHostProtocol
    package let limits: AgentHostProtocolLimitsV1
    package let configuration: AgentSessionHostConfiguration
    package let executorFactory: any AgentSessionExecutorFactory
    package let hostNonce: Data

    private let logger: Logger
    private let lock = NSLock()
    private var sessions: [String: HostedSession] = [:]
    private var connections: [AgentSessionHostConnectionID: ConnectionRecord] = [:]
    private var hostControlOperations: [String: (fingerprint: String, outcome: AgentHostCommandResponseOutcomeV1)] = [:]
    private var acceptingNewSessions = true
    private var shuttingDown = false

    private struct Attachment {
        var suspended = false
        var attachedAtCursor: UInt64
    }

    private final class HostedSession {
        let sessionID: String
        let directory: URL
        let log: CoreAgentSessionLog
        var state: AgentSessionHostFoldedState
        var attempt: UInt32
        var generation: Data
        var executor: (any AgentSessionExecutor)?
        var attachments: [AgentSessionHostConnectionID: Attachment] = [:]
        var closed = false

        init(sessionID: String, directory: URL, log: CoreAgentSessionLog, state: AgentSessionHostFoldedState, nonce: Data, attempt: UInt32) {
            self.sessionID = sessionID
            self.directory = directory
            self.log = log
            self.state = state
            self.attempt = attempt
            generation = AgentSessionHostGeneration.make(nonce: nonce, attempt: attempt)
            self.state.setGeneration(generation)
        }
    }

    private struct ConnectionRecord {
        var outbound: AgentSessionHostOutboundQueue
        var capabilities: Set<AgentHostCapabilityV1>
    }

    private final class Sink: AgentSessionExecutorSink, @unchecked Sendable {
        weak var router: AgentSessionRouter?
        let sessionID: String

        init(router: AgentSessionRouter, sessionID: String) {
            self.router = router
            self.sessionID = sessionID
        }

        func emit(_ body: AgentHostAgentSessionEventBodyV1) {
            router?.record(sessionID: sessionID, body: body)
        }
    }

    package init(
        paths: AgentSessionHostPaths,
        codec: CoreAgentHostProtocol,
        limits: AgentHostProtocolLimitsV1,
        configuration: AgentSessionHostConfiguration,
        executorFactory: any AgentSessionExecutorFactory,
        hostInstanceID: String = UUID().uuidString.lowercased(),
        logger: Logger = Logger(label: "com.agentry.agent-host.router")
    ) {
        self.paths = paths
        self.codec = codec
        self.limits = limits
        self.configuration = configuration
        self.executorFactory = executorFactory
        self.hostInstanceID = hostInstanceID
        self.logger = logger
        var nonce = Data(count: 16)
        let uuid = UUID().uuid
        withUnsafeBytes(of: uuid) { nonce = Data($0) }
        hostNonce = nonce
    }

    // MARK: Observability

    package var sessionCount: Int {
        lock.withLock { sessions.count }
    }

    package var connectionCount: Int {
        lock.withLock { connections.count }
    }

    package var attachmentCount: Int {
        lock.withLock { sessions.values.reduce(0) { $0 + $1.attachments.count } }
    }

    package var isAcceptingNewSessions: Bool {
        lock.withLock { acceptingNewSessions && !shuttingDown }
    }

    /// No connections, no attachments, and no session with a live run or pending interaction.
    package var isIdle: Bool {
        lock.withLock {
            connections.isEmpty && sessions.values.allSatisfy { $0.attachments.isEmpty && !$0.state.hasLiveRun }
        }
    }

    package func currentGeneration(sessionID: String) -> Data? {
        lock.withLock { sessions[sessionID.lowercased()]?.generation }
    }

    package func sessionSummary(sessionID: String) -> AgentHostSessionSummaryV1? {
        lock.withLock { sessions[sessionID.lowercased()]?.state.summary }
    }

    package func attachmentCount(sessionID: String) -> Int {
        lock.withLock { sessions[sessionID.lowercased()]?.attachments.count ?? 0 }
    }

    package func staleInteractionResponseCount(sessionID: String) -> UInt64 {
        lock.withLock { sessions[sessionID.lowercased()]?.state.staleInteractionResponseCount ?? 0 }
    }

    /// Lock must be held. Session ids are stored lowercase (wire UUIDs are case-insensitive).
    private func hosted(_ sessionID: String) -> HostedSession? {
        sessions[sessionID.lowercased()]
    }

    // MARK: Connections

    package func register(outbound: AgentSessionHostOutboundQueue, capabilities: [AgentHostCapabilityV1]) -> AgentSessionHostConnectionID? {
        lock.withLock {
            guard !shuttingDown, connections.count < configuration.maximumClients else { return nil }
            let id = AgentSessionHostConnectionID()
            connections[id] = ConnectionRecord(outbound: outbound, capabilities: Set(capabilities))
            return id
        }
    }

    package func unregister(connection id: AgentSessionHostConnectionID) {
        lock.withLock {
            connections[id] = nil
            for session in sessions.values where session.attachments[id] != nil {
                session.attachments[id] = nil
                session.state.setAttachedClientCount(session.attachments.count)
            }
        }
    }

    package func broadcast(notice: AgentHostHostNoticeV1) {
        lock.withLock {
            for record in connections.values {
                send(.notice(notice), via: record.outbound)
            }
        }
    }

    // MARK: Recovery (design §7.1 / §7.3)

    package func recover() -> AgentSessionRouterRecoveryReport {
        var report = AgentSessionRouterRecoveryReport()
        let importReport = AgentSessionLegacyJSONImport.importMissingLogs(
            directories: paths.existingSessionDirectories(),
            codec: codec
        )
        report.importedSessionIDs = importReport.importedSessionIDs
        report.skipped.append(contentsOf: importReport.skipped)
        for directory in paths.existingSessionDirectories() {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files.sorted() where file.hasPrefix("AgentSession-") && file.hasSuffix(".events") {
                let sessionID = String(file.dropFirst("AgentSession-".count).dropLast(".events".count)).lowercased()
                let path = directory.appendingPathComponent(file).path
                do {
                    try recoverSession(sessionID: sessionID, directory: directory, report: &report)
                } catch {
                    logger.error("agent-host recovery skipped \(path): \(error)")
                    report.skipped.append(.init(path: path, reason: String(describing: error)))
                }
            }
        }
        return report
    }

    private func recoverSession(sessionID: String, directory: URL, report: inout AgentSessionRouterRecoveryReport) throws {
        let names = try codec.sessionLogFileNames(sessionID: sessionID)
        let log = try CoreAgentSessionLog.open(
            path: directory.appendingPathComponent(names.events).path,
            sessionID: sessionID,
            options: AgentSessionLogOpenOptionsV1(createIfMissing: false, loadSnapshot: true)
        )
        let openReport = try log.openReport()
        var state: AgentSessionHostFoldedState
        var cursor: UInt64
        switch openReport.snapshot {
        case let .loaded(snapshot):
            state = try AgentSessionHostFoldedState(snapshot: snapshot)
            cursor = openReport.replayFrom
        case let .corrupt(reason):
            logger.warning("agent-host recovery: snapshot for \(sessionID) corrupt (\(reason)); replaying the log")
            state = AgentSessionHostFoldedState(placeholderSessionID: sessionID)
            cursor = 1
        case .missing, .notRequested:
            state = AgentSessionHostFoldedState(placeholderSessionID: sessionID)
            cursor = 1
        }
        while cursor < openReport.nextCursor {
            let batch = try log.readFrom(
                cursor: cursor,
                maxRecords: configuration.replayBatchRecords,
                maxBytes: configuration.replayBatchBytes
            )
            for entry in batch.entries {
                try state.apply(entry.event, cursor: entry.cursor)
            }
            if batch.endOfLog || batch.entries.isEmpty { break }
            cursor = batch.nextCursor
        }
        guard state.hasMetadata else {
            try? log.close()
            report.skipped.append(.init(path: directory.appendingPathComponent(names.events).path, reason: "no session metadata record"))
            return
        }
        if openReport.tornTail != nil {
            report.tornTailSessionIDs.append(sessionID)
        }

        let session = HostedSession(sessionID: sessionID, directory: directory, log: log, state: state, nonce: hostNonce, attempt: 1)
        lock.withLock {
            sessions[sessionID] = session
            if session.state.hasLiveRun || session.state.summary.status == .running {
                let now = AgentSessionHostClock.rfc3339()
                for pending in session.state.pendingInteractions {
                    _ = try? appendEvent(session, .interaction(AgentHostInteractionEventV1(kind: .settled(AgentHostInteractionSettledV1(
                        interactionId: pending.interactionId,
                        interactionGeneration: pending.interactionGeneration,
                        settlement: .cancelledByProvider,
                        answer: nil,
                        operationId: ""
                    )))), durability: .deferred)
                }
                let demoted = session.state.summary(
                    status: .waitingForInput,
                    statusText: "interrupted: host restarted",
                    clearingActiveRun: true,
                    now: now
                )
                _ = try? appendEvent(session, .sessionMetadataChanged(AgentHostSessionMetadataChangedV1(summary: demoted)), durability: .sync)
                report.demotedSessionIDs.append(sessionID)
            }
            report.recoveredSessionIDs.append(sessionID)
        }
    }

    // MARK: Executor events

    /// Entry point for executors: append, reduce, fan out; sync + compact at turn boundaries.
    package func record(sessionID: String, body: AgentHostAgentSessionEventBodyV1) {
        lock.withLock {
            guard let session = sessions[sessionID], !session.closed else { return }
            do {
                _ = try appendEvent(session, body, durability: .deferred)
            } catch {
                logger.error("agent-host: append failed for \(sessionID): \(error)")
                return
            }
            if case let .runLifecycle(lifecycle) = body, case .terminated = lifecycle.kind {
                checkpoint(session)
            }
        }
    }

    /// Lock must be held.
    @discardableResult
    private func appendEvent(
        _ session: HostedSession,
        _ body: AgentHostAgentSessionEventBodyV1,
        durability: AgentSessionLogDurabilityV1
    ) throws -> UInt64 {
        let event = AgentHostAgentSessionEventV1(recordedAt: AgentSessionHostClock.rfc3339(), body: body)
        let cursor = try session.log.append(event, durability: durability)
        try session.state.apply(event, cursor: cursor)
        fanout(session, cursor: cursor, event: event)
        return cursor
    }

    /// Lock must be held.
    private func fanout(_ session: HostedSession, cursor: UInt64, event: AgentHostAgentSessionEventV1) {
        for (connectionID, attachment) in session.attachments where !attachment.suspended {
            guard let record = connections[connectionID] else {
                session.attachments[connectionID] = nil
                continue
            }
            let notification = AgentHostEventNotificationV1(
                sessionId: session.sessionID,
                generation: session.generation,
                deliveryCursor: cursor,
                event: event
            )
            guard let frame = encode(.event(notification)) else { continue }
            if !record.outbound.enqueueEvent(frame, sessionID: session.sessionID, cursor: cursor) {
                suspend(session, connectionID: connectionID, reason: .backpressureOverflow, outbound: record.outbound)
            }
        }
    }

    /// Lock must be held. Drops queued deltas, marks the attachment suspended and asks for a re-attach.
    private func suspend(
        _ session: HostedSession,
        connectionID: AgentSessionHostConnectionID,
        reason: AgentHostResnapshotReasonV1,
        outbound: AgentSessionHostOutboundQueue
    ) {
        guard var attachment = session.attachments[connectionID], !attachment.suspended else { return }
        outbound.dropEvents(sessionID: session.sessionID)
        attachment.suspended = true
        session.attachments[connectionID] = attachment
        let lastDelivered = outbound.lastWrittenEventCursor(sessionID: session.sessionID) ?? attachment.attachedAtCursor
        send(.resnapshotRequired(AgentHostResnapshotRequiredV1(
            sessionId: session.sessionID,
            generation: session.generation,
            reason: reason,
            lastDeliveredCursor: lastDelivered
        )), via: outbound)
    }

    /// Lock must be held. `sync` then `compact`; failures are logged, never fatal for the run.
    @discardableResult
    private func checkpoint(_ session: HostedSession) -> AgentHostSessionCheckpointV1 {
        do {
            try session.log.sync()
            let receipt = try session.log.compact(session.state.snapshot(generation: session.generation, now: AgentSessionHostClock.rfc3339()))
            return AgentHostSessionCheckpointV1(sessionId: session.sessionID, succeeded: true, throughCursor: receipt.throughCursor, detail: "")
        } catch {
            logger.warning("agent-host: checkpoint failed for \(session.sessionID): \(error)")
            return AgentHostSessionCheckpointV1(sessionId: session.sessionID, succeeded: false, throughCursor: session.state.lastCursor, detail: String(describing: error))
        }
    }

    // MARK: Commands

    package func handle(
        _ request: AgentHostCommandRequestV1,
        from connectionID: AgentSessionHostConnectionID
    ) -> AgentSessionHostControlEffect? {
        guard let command = request.command else {
            respond(request.requestId, .rejected(.init(reason: .invalidArgument, detail: "empty command")), to: connectionID)
            return nil
        }
        switch command {
        case let .listSessions(list):
            handleList(request, list, connectionID)
        case let .attach(attach):
            handleAttach(request, attach, connectionID)
        case let .detach(detach):
            handleDetach(request, detach, connectionID)
        case let .start(start):
            handleStart(request, start, connectionID)
        case let .steer(steer):
            handleSteer(request, steer, connectionID)
        case let .interrupt(interrupt):
            handleInterrupt(request, interrupt, connectionID)
        case let .respondInteraction(respond):
            handleRespondInteraction(request, respond, connectionID)
        case let .stop(stop):
            handleStop(request, stop, connectionID)
        case let .hostControl(control):
            return handleHostControl(request, control, connectionID)
        }
        return nil
    }

    private func handleList(_ request: AgentHostCommandRequestV1, _ list: AgentHostListSessionsV1, _ connectionID: AgentSessionHostConnectionID) {
        lock.withLock {
            let summaries = sessions.values
                .filter { list.includeTerminal || !$0.state.isTerminal }
                .filter { list.workspaceId.isEmpty || $0.state.summary.workspaceId == list.workspaceId }
                .map(\.state.summary)
                .sorted { $0.createdAt < $1.createdAt }
            respondLocked(request.requestId, .result(.init(result: .sessionList(.init(sessions: summaries)))), to: connectionID)
        }
    }

    private func handleAttach(_ request: AgentHostCommandRequestV1, _ attach: AgentHostAttachV1, _ connectionID: AgentSessionHostConnectionID) {
        lock.withLock {
            guard let record = connections[connectionID] else { return }
            guard let session = hosted(attach.sessionId), !session.closed else {
                respondLocked(request.requestId, .rejected(.init(reason: .unknownSession, detail: attach.sessionId)), to: connectionID)
                return
            }
            guard record.capabilities.contains(.snapshotStreaming) else {
                respondLocked(request.requestId, .rejected(.init(reason: .capabilityMissing, detail: "snapshotStreaming")), to: connectionID)
                return
            }
            let end = session.state.lastCursor
            let replay: AgentHostAttachReplayV1
            var snapshotFollows = false
            var replayFrom: UInt64 = end + 1
            if let resume = attach.resumeCursor {
                if attach.resumeGeneration != session.generation {
                    replay = .unavailable
                    snapshotFollows = true
                } else if resume <= end, end - resume <= UInt64(configuration.outboundLimits.maxEventFrames) {
                    replay = .complete
                    replayFrom = resume + 1
                } else {
                    // Either the client is ahead of what survived on disk, or the gap is larger than one
                    // attachment budget can carry; both are served by a snapshot (design §5.5).
                    replay = .partial
                    snapshotFollows = true
                }
            } else {
                replay = .complete
                snapshotFollows = true
            }

            // Re-attaching resets any suspended attachment (post-resnapshotRequired recovery).
            record.outbound.dropEvents(sessionID: session.sessionID)
            session.attachments[connectionID] = Attachment(suspended: false, attachedAtCursor: end)
            session.state.setAttachedClientCount(session.attachments.count)

            let result = AgentHostAttachResultV1(
                sessionId: session.sessionID,
                generation: session.generation,
                replay: replay,
                snapshotFollows: snapshotFollows,
                snapshotThroughCursor: snapshotFollows ? end : 0,
                nextCursor: snapshotFollows ? end + 1 : replayFrom,
                summary: session.state.summary
            )
            respondLocked(request.requestId, .result(.init(result: .attached(result))), to: connectionID)
            if snapshotFollows {
                streamSnapshot(session, via: record.outbound, connectionID: connectionID)
            } else if replayFrom <= end {
                replayLog(session, from: replayFrom, through: end, via: record.outbound, connectionID: connectionID)
            }
        }
    }

    /// Lock must be held. Snapshot bytes come from the same reducer that `compact` persists.
    private func streamSnapshot(_ session: HostedSession, via outbound: AgentSessionHostOutboundQueue, connectionID: AgentSessionHostConnectionID) {
        let snapshot = session.state.snapshot(generation: session.generation, now: AgentSessionHostClock.rfc3339())
        let bytes: Data
        do {
            bytes = try codec.encodeSnapshot(snapshot)
        } catch {
            logger.error("agent-host: snapshot encode failed for \(session.sessionID): \(error)")
            suspend(session, connectionID: connectionID, reason: .unspecified, outbound: outbound)
            return
        }
        let chunkSize = max(1, Int(limits.maximumSnapshotChunkBytes))
        let chunkCount = max(1, (bytes.count + chunkSize - 1) / chunkSize)
        send(.snapshotBegin(AgentHostSnapshotBeginV1(
            sessionId: session.sessionID,
            generation: session.generation,
            throughCursor: snapshot.throughCursor,
            byteLength: UInt64(bytes.count),
            digestSha256: DomainContentDigest.sha256(bytes),
            chunkCount: UInt32(chunkCount)
        )), via: outbound)
        var offset = 0
        var index: UInt32 = 0
        repeat {
            let end = min(bytes.count, offset + chunkSize)
            send(.snapshotChunk(AgentHostSnapshotChunkV1(
                sessionId: session.sessionID,
                chunkIndex: index,
                offset: UInt64(offset),
                data: bytes.subdata(in: offset ..< end)
            )), via: outbound)
            offset = end
            index += 1
        } while offset < bytes.count
        send(.snapshotEnd(AgentHostSnapshotEndV1(
            sessionId: session.sessionID,
            throughCursor: snapshot.throughCursor,
            nextCursor: snapshot.throughCursor + 1
        )), via: outbound)
    }

    /// Lock must be held. Replays `[from, through]` from the log through the bounded event queue.
    private func replayLog(_ session: HostedSession, from: UInt64, through: UInt64, via outbound: AgentSessionHostOutboundQueue, connectionID: AgentSessionHostConnectionID) {
        var cursor = from
        while cursor <= through {
            let batch: AgentSessionLogReadBatchV1
            do {
                batch = try session.log.readFrom(cursor: cursor, maxRecords: configuration.replayBatchRecords, maxBytes: configuration.replayBatchBytes)
            } catch {
                logger.warning("agent-host: replay read failed for \(session.sessionID) at \(cursor): \(error)")
                suspend(session, connectionID: connectionID, reason: .logCompacted, outbound: outbound)
                return
            }
            for entry in batch.entries where entry.cursor <= through {
                let notification = AgentHostEventNotificationV1(
                    sessionId: session.sessionID,
                    generation: session.generation,
                    deliveryCursor: entry.cursor,
                    event: entry.event
                )
                guard let frame = encode(.event(notification)) else { continue }
                if !outbound.enqueueEvent(frame, sessionID: session.sessionID, cursor: entry.cursor) {
                    suspend(session, connectionID: connectionID, reason: .backpressureOverflow, outbound: outbound)
                    return
                }
            }
            if batch.endOfLog || batch.entries.isEmpty { return }
            cursor = batch.nextCursor
        }
    }

    private func handleDetach(_ request: AgentHostCommandRequestV1, _ detach: AgentHostDetachV1, _ connectionID: AgentSessionHostConnectionID) {
        lock.withLock {
            guard let session = hosted(detach.sessionId), session.attachments[connectionID] != nil else {
                respondLocked(request.requestId, .rejected(.init(reason: .notAttached, detail: detach.sessionId)), to: connectionID)
                return
            }
            session.attachments[connectionID] = nil
            session.state.setAttachedClientCount(session.attachments.count)
            connections[connectionID]?.outbound.dropEvents(sessionID: session.sessionID)
            respondLocked(request.requestId, .result(.init(result: .detached(.init(sessionId: session.sessionID)))), to: connectionID)
        }
    }

    // MARK: Idempotency (design §5.4)

    private enum MutationGate {
        case proceed(fingerprint: String)
        case replay(AgentHostCommandResponseOutcomeV1)
        case reject(AgentHostCommandRejectedV1)
    }

    /// Lock must be held when `session` is non-nil.
    private func gate(_ session: HostedSession?, request: AgentHostCommandRequestV1, key: AgentHostMutationKeyV1?) -> MutationGate {
        guard let key, !key.operationId.isEmpty else {
            return .reject(.init(reason: .invalidArgument, detail: "mutation key with operation_id is required"))
        }
        let fingerprint: String
        do {
            fingerprint = try codec.commandFingerprint(request)
        } catch {
            return .reject(.init(reason: .invalidArgument, detail: "fingerprint: \(error)"))
        }
        guard let session, let accepted = session.state.acceptedOperations[key.operationId] else {
            return .proceed(fingerprint: fingerprint)
        }
        guard accepted.argumentFingerprint == fingerprint else {
            return .replay(.operationConflict(.init(
                operationId: key.operationId,
                recordedFingerprint: accepted.argumentFingerprint,
                submittedFingerprint: fingerprint
            )))
        }
        guard let settled = session.state.settledOperations[key.operationId] else {
            return .replay(.uncertain(.init(operationId: key.operationId, detail: "accepted at \(accepted.acceptedAt) but never settled")))
        }
        switch settled.settlement {
        case let .result(result): return .replay(.result(result))
        case let .rejected(rejected): return .replay(.rejected(rejected))
        case nil: return .replay(.uncertain(.init(operationId: key.operationId, detail: "settled without a settlement body")))
        }
    }

    /// Lock must be held.
    private func accept(_ session: HostedSession, operationID: String, fingerprint: String, kind: String) throws {
        try appendEvent(session, .commandAccepted(AgentHostCommandAcceptedV1(
            operationId: operationID,
            argumentFingerprint: fingerprint,
            commandKind: kind,
            acceptedAt: AgentSessionHostClock.rfc3339()
        )), durability: .sync)
    }

    /// Lock must be held.
    private func settle(_ session: HostedSession, operationID: String, settlement: AgentHostCommandSettledSettlementV1) {
        do {
            try appendEvent(session, .commandSettled(AgentHostCommandSettledV1(
                operationId: operationID,
                settledAt: AgentSessionHostClock.rfc3339(),
                settlement: settlement
            )), durability: .sync)
        } catch {
            logger.error("agent-host: settle append failed for \(session.sessionID)/\(operationID): \(error)")
        }
    }

    private func outcome(for settlement: AgentHostCommandSettledSettlementV1) -> AgentHostCommandResponseOutcomeV1 {
        switch settlement {
        case let .result(result): .result(result)
        case let .rejected(rejected): .rejected(rejected)
        }
    }

    // MARK: start / steer / interrupt / respond_interaction / stop

    private func handleStart(_ request: AgentHostCommandRequestV1, _ start: AgentHostStartV1, _ connectionID: AgentSessionHostConnectionID) {
        guard let spec = start.spec, UUID(uuidString: spec.sessionId) != nil else {
            respond(request.requestId, .rejected(.init(reason: .invalidArgument, detail: "spec.session_id must be a UUID")), to: connectionID)
            return
        }
        guard AgentSessionHostPaths.isSafePathComponent(spec.workspaceId) else {
            respond(request.requestId, .rejected(.init(reason: .unknownWorkspace, detail: spec.workspaceId)), to: connectionID)
            return
        }
        guard spec.parentSessionId.isEmpty else {
            respond(request.requestId, .rejected(.init(reason: .capabilityMissing, detail: "fork is not available in this host")), to: connectionID)
            return
        }
        let sessionID = spec.sessionId.lowercased()

        let prepared: (session: HostedSession, executor: any AgentSessionExecutor, operationID: String)? = lock.withLock {
            if let existing = sessions[sessionID] {
                switch gate(existing, request: request, key: start.key) {
                case let .replay(outcome): respondLocked(request.requestId, outcome, to: connectionID)
                case let .reject(rejected): respondLocked(request.requestId, .rejected(rejected), to: connectionID)
                case .proceed: respondLocked(request.requestId, .rejected(.init(reason: .sessionExists, detail: sessionID)), to: connectionID)
                }
                return nil
            }
            guard acceptingNewSessions, !shuttingDown else {
                respondLocked(request.requestId, .rejected(.init(reason: .hostShuttingDown, detail: "host is not accepting new sessions")), to: connectionID)
                return nil
            }
            let fingerprint: String
            switch gate(nil, request: request, key: start.key) {
            case let .proceed(value):
                fingerprint = value
            case let .reject(rejected):
                respondLocked(request.requestId, .rejected(rejected), to: connectionID)
                return nil
            case let .replay(outcome):
                respondLocked(request.requestId, outcome, to: connectionID)
                return nil
            }
            let operationID = start.key?.operationId ?? ""
            do {
                let session = try openSession(sessionID: sessionID, spec: spec)
                sessions[sessionID] = session
                try accept(session, operationID: operationID, fingerprint: fingerprint, kind: "start")
                try appendEvent(session, .sessionMetadataChanged(.init(summary: session.state.summary)), durability: .sync)
                let executor = try executorFactory.makeExecutor(sessionID: sessionID, spec: spec, sink: Sink(router: self, sessionID: sessionID))
                session.executor = executor
                return (session, executor, operationID)
            } catch {
                logger.error("agent-host: start \(sessionID) failed before execution: \(error)")
                if let session = sessions[sessionID] {
                    settle(session, operationID: operationID, settlement: .rejected(.init(reason: .providerUnavailable, detail: String(describing: error))))
                }
                respondLocked(request.requestId, .rejected(.init(reason: .providerUnavailable, detail: String(describing: error))), to: connectionID)
                return nil
            }
        }
        guard let prepared else { return }

        let started = Result { try prepared.executor.start(spec: spec) }
        lock.withLock {
            let session = prepared.session
            let settlement: AgentHostCommandSettledSettlementV1
            switch started {
            case .success:
                settlement = .result(.init(result: .started(AgentHostSessionStartedV1(
                    sessionId: session.sessionID,
                    generation: session.generation,
                    nextCursor: session.state.lastCursor + 1,
                    summary: session.state.summary
                ))))
            case let .failure(error):
                let failed = session.state.summary(status: .failed, statusText: "start failed: \(error)", clearingActiveRun: true, now: AgentSessionHostClock.rfc3339())
                _ = try? appendEvent(session, .sessionMetadataChanged(.init(summary: failed)), durability: .sync)
                session.executor = nil
                settlement = .rejected(.init(reason: .providerUnavailable, detail: String(describing: error)))
            }
            settle(session, operationID: prepared.operationID, settlement: settlement)
            respondLocked(request.requestId, outcome(for: settlement), to: connectionID)
        }
    }

    /// Lock must be held.
    private func openSession(sessionID: String, spec: AgentHostSessionSpecV1) throws -> HostedSession {
        let directory = try paths.resolvedSessionDirectory(workspaceID: spec.workspaceId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let names = try codec.sessionLogFileNames(sessionID: sessionID)
        let log = try CoreAgentSessionLog.open(
            path: directory.appendingPathComponent(names.events).path,
            sessionID: sessionID,
            options: AgentSessionLogOpenOptionsV1(createIfMissing: true, loadSnapshot: false)
        )
        let state = try AgentSessionHostFoldedState(spec: spec, now: AgentSessionHostClock.rfc3339())
        return HostedSession(sessionID: sessionID, directory: directory, log: log, state: state, nonce: hostNonce, attempt: 1)
    }

    /// Lock must be held. Recovered sessions have no executor; one is created lazily with a resume spec.
    /// Returns the executor and whether `start` must be called before use.
    private func ensureExecutor(_ session: HostedSession) throws -> (executor: any AgentSessionExecutor, needsStart: Bool, spec: AgentHostSessionSpecV1?) {
        if let executor = session.executor { return (executor, false, nil) }
        let summary = session.state.summary
        let spec = AgentHostSessionSpecV1(
            sessionId: session.sessionID,
            workspaceId: summary.workspaceId,
            worktreeId: summary.worktreeId,
            sessionName: summary.sessionName,
            providerId: summary.providerId,
            agentId: summary.agentId,
            agentDisplayName: summary.agentDisplayName,
            modelId: summary.modelId,
            reasoningEffort: summary.reasoningEffort,
            parentSessionId: "",
            parentForkCursor: 0,
            initialMessage: nil,
            permissionPolicy: nil,
            credentialEnvelopeId: "",
            resumeProviderSessionId: summary.providerSessionId
        )
        let executor = try executorFactory.makeExecutor(sessionID: session.sessionID, spec: spec, sink: Sink(router: self, sessionID: session.sessionID))
        session.executor = executor
        session.attempt += 1
        let previousGeneration = session.generation
        session.generation = AgentSessionHostGeneration.make(nonce: hostNonce, attempt: session.attempt)
        session.state.setGeneration(session.generation)
        if previousGeneration != session.generation {
            for (connectionID, _) in session.attachments {
                if let outbound = connections[connectionID]?.outbound {
                    suspend(session, connectionID: connectionID, reason: .generationChanged, outbound: outbound)
                }
            }
        }
        return (executor, true, spec)
    }

    private func handleSteer(_ request: AgentHostCommandRequestV1, _ steer: AgentHostSteerV1, _ connectionID: AgentSessionHostConnectionID) {
        guard let message = steer.message else {
            respond(request.requestId, .rejected(.init(reason: .invalidArgument, detail: "message is required")), to: connectionID)
            return
        }
        let prepared: (session: HostedSession, executor: any AgentSessionExecutor, needsStart: Bool, spec: AgentHostSessionSpecV1?, operationID: String, cursor: UInt64)? = lock.withLock {
            guard let session = hosted(steer.sessionId), !session.closed else {
                respondLocked(request.requestId, .rejected(.init(reason: .unknownSession, detail: steer.sessionId)), to: connectionID)
                return nil
            }
            switch gate(session, request: request, key: steer.key) {
            case let .replay(outcome): respondLocked(request.requestId, outcome, to: connectionID)
                return nil
            case let .reject(rejected): respondLocked(request.requestId, .rejected(rejected), to: connectionID)
                return nil
            case let .proceed(fingerprint):
                guard !session.state.isTerminal else {
                    respondLocked(request.requestId, .rejected(.init(reason: .sessionNotActive, detail: steer.sessionId)), to: connectionID)
                    return nil
                }
                let operationID = steer.key?.operationId ?? ""
                do {
                    try accept(session, operationID: operationID, fingerprint: fingerprint, kind: "steer")
                    let cursor = try appendEvent(session, .userMessage(message), durability: .sync)
                    let ensured = try ensureExecutor(session)
                    return (session, ensured.executor, ensured.needsStart, ensured.spec, operationID, cursor)
                } catch {
                    let rejected = AgentHostCommandRejectedV1(reason: .providerUnavailable, detail: String(describing: error))
                    settle(session, operationID: operationID, settlement: .rejected(rejected))
                    respondLocked(request.requestId, .rejected(rejected), to: connectionID)
                    return nil
                }
            }
        }
        guard let prepared else { return }

        let outcome = Result<Void, Error> {
            if prepared.needsStart, let spec = prepared.spec {
                _ = try prepared.executor.start(spec: spec)
            }
            _ = try prepared.executor.steer(message: message, delivery: steer.delivery)
        }
        lock.withLock {
            let settlement: AgentHostCommandSettledSettlementV1 = switch outcome {
            case .success:
                .result(.init(result: .steered(AgentHostSteeredV1(sessionId: prepared.session.sessionID, messageId: message.messageId, recordedCursor: prepared.cursor))))
            case let .failure(error):
                .rejected(.init(reason: .providerUnavailable, detail: String(describing: error)))
            }
            settle(prepared.session, operationID: prepared.operationID, settlement: settlement)
            respondLocked(request.requestId, self.outcome(for: settlement), to: connectionID)
        }
    }

    private func handleInterrupt(_ request: AgentHostCommandRequestV1, _ interrupt: AgentHostInterruptV1, _ connectionID: AgentSessionHostConnectionID) {
        let prepared: (session: HostedSession, executor: (any AgentSessionExecutor)?, operationID: String)? = lock.withLock {
            guard let session = hosted(interrupt.sessionId), !session.closed else {
                respondLocked(request.requestId, .rejected(.init(reason: .unknownSession, detail: interrupt.sessionId)), to: connectionID)
                return nil
            }
            switch gate(session, request: request, key: interrupt.key) {
            case let .replay(outcome): respondLocked(request.requestId, outcome, to: connectionID)
                return nil
            case let .reject(rejected): respondLocked(request.requestId, .rejected(rejected), to: connectionID)
                return nil
            case let .proceed(fingerprint):
                let operationID = interrupt.key?.operationId ?? ""
                do {
                    try accept(session, operationID: operationID, fingerprint: fingerprint, kind: "interrupt")
                } catch {
                    respondLocked(request.requestId, .rejected(.init(reason: .providerUnavailable, detail: String(describing: error))), to: connectionID)
                    return nil
                }
                return (session, session.executor, operationID)
            }
        }
        guard let prepared else { return }
        let result = prepared.executor?.interrupt(turnID: interrupt.turnId) ?? .noTurnInFlight
        lock.withLock {
            let settlement: AgentHostCommandSettledSettlementV1 = .result(.init(result: .interrupted(AgentHostInterruptResultV1(
                sessionId: prepared.session.sessionID,
                outcome: result,
                detail: ""
            ))))
            settle(prepared.session, operationID: prepared.operationID, settlement: settlement)
            respondLocked(request.requestId, outcome(for: settlement), to: connectionID)
        }
    }

    private func handleRespondInteraction(_ request: AgentHostCommandRequestV1, _ respondInteraction: AgentHostRespondInteractionV1, _ connectionID: AgentSessionHostConnectionID) {
        let delivery: (executor: any AgentSessionExecutor, interactionID: String, answer: AgentHostInteractionAnswerV1)? = lock.withLock {
            guard let session = hosted(respondInteraction.sessionId), !session.closed else {
                respondLocked(request.requestId, .rejected(.init(reason: .unknownSession, detail: respondInteraction.sessionId)), to: connectionID)
                return nil
            }
            switch gate(session, request: request, key: respondInteraction.key) {
            case let .replay(outcome): respondLocked(request.requestId, outcome, to: connectionID)
                return nil
            case let .reject(rejected): respondLocked(request.requestId, .rejected(rejected), to: connectionID)
                return nil
            case let .proceed(fingerprint):
                let operationID = respondInteraction.key?.operationId ?? ""
                do {
                    try accept(session, operationID: operationID, fingerprint: fingerprint, kind: "respond_interaction")
                } catch {
                    respondLocked(request.requestId, .rejected(.init(reason: .providerUnavailable, detail: String(describing: error))), to: connectionID)
                    return nil
                }
                let answer = respondInteraction.answer ?? AgentHostInteractionAnswerV1(skipped: true, answer: nil)
                var disposition: AgentHostInteractionResponseDispositionV1
                var pendingDelivery: (any AgentSessionExecutor, String, AgentHostInteractionAnswerV1)?
                if let pending = session.state.pendingInteractions.first(where: { $0.interactionId == respondInteraction.interactionId }) {
                    if pending.interactionGeneration != respondInteraction.interactionGeneration {
                        disposition = .staleGeneration
                        session.state.recordStaleInteractionResponse()
                    } else {
                        disposition = .accepted
                        do {
                            try appendEvent(session, .interaction(.init(kind: .settled(AgentHostInteractionSettledV1(
                                interactionId: pending.interactionId,
                                interactionGeneration: pending.interactionGeneration,
                                settlement: .answered,
                                answer: answer,
                                operationId: operationID
                            )))), durability: .sync)
                            if let executor = session.executor {
                                pendingDelivery = (executor, pending.interactionId, answer)
                            }
                        } catch {
                            disposition = .unspecified
                        }
                    }
                } else if session.state.settledInteractionIDs.contains(respondInteraction.interactionId) {
                    disposition = .superseded
                    session.state.recordStaleInteractionResponse()
                } else {
                    disposition = .unknownInteraction
                }
                let settlement: AgentHostCommandSettledSettlementV1 = .result(.init(result: .interactionResponded(AgentHostInteractionRespondedV1(
                    sessionId: session.sessionID,
                    interactionId: respondInteraction.interactionId,
                    disposition: disposition
                ))))
                settle(session, operationID: operationID, settlement: settlement)
                respondLocked(request.requestId, outcome(for: settlement), to: connectionID)
                return pendingDelivery.map { ($0.0, $0.1, $0.2) }
            }
        }
        guard let delivery else { return }
        do {
            try delivery.executor.deliverInteractionAnswer(interactionID: delivery.interactionID, answer: delivery.answer)
        } catch {
            logger.warning("agent-host: executor rejected interaction answer \(delivery.interactionID): \(error)")
        }
    }

    private func handleStop(_ request: AgentHostCommandRequestV1, _ stop: AgentHostStopV1, _ connectionID: AgentSessionHostConnectionID) {
        let prepared: (session: HostedSession, executor: (any AgentSessionExecutor)?, operationID: String)? = lock.withLock {
            guard let session = hosted(stop.sessionId), !session.closed else {
                respondLocked(request.requestId, .rejected(.init(reason: .unknownSession, detail: stop.sessionId)), to: connectionID)
                return nil
            }
            switch gate(session, request: request, key: stop.key) {
            case let .replay(outcome): respondLocked(request.requestId, outcome, to: connectionID)
                return nil
            case let .reject(rejected): respondLocked(request.requestId, .rejected(rejected), to: connectionID)
                return nil
            case let .proceed(fingerprint):
                guard !session.state.isTerminal else {
                    respondLocked(request.requestId, .rejected(.init(reason: .sessionNotActive, detail: stop.sessionId)), to: connectionID)
                    return nil
                }
                let operationID = stop.key?.operationId ?? ""
                do {
                    try accept(session, operationID: operationID, fingerprint: fingerprint, kind: "stop")
                } catch {
                    respondLocked(request.requestId, .rejected(.init(reason: .providerUnavailable, detail: String(describing: error))), to: connectionID)
                    return nil
                }
                let executor = session.executor
                session.executor = nil
                return (session, executor, operationID)
            }
        }
        guard let prepared else { return }
        let status = prepared.executor?.stop(reason: stop.reason) ?? .completed
        lock.withLock {
            let session = prepared.session
            let terminalSummary = session.state.summary(status: status, statusText: "stopped", clearingActiveRun: true, now: AgentSessionHostClock.rfc3339())
            _ = try? appendEvent(session, .sessionMetadataChanged(.init(summary: terminalSummary)), durability: .sync)
            let settlement: AgentHostCommandSettledSettlementV1 = .result(.init(result: .stopped(AgentHostStoppedV1(sessionId: session.sessionID, status: status))))
            settle(session, operationID: prepared.operationID, settlement: settlement)
            respondLocked(request.requestId, outcome(for: settlement), to: connectionID)
            checkpoint(session)
        }
    }

    // MARK: host_control (design §4.4)

    private func handleHostControl(_ request: AgentHostCommandRequestV1, _ control: AgentHostHostControlV1, _ connectionID: AgentSessionHostConnectionID) -> AgentSessionHostControlEffect? {
        guard let action = control.action else {
            respond(request.requestId, .rejected(.init(reason: .invalidArgument, detail: "empty host_control action")), to: connectionID)
            return nil
        }
        return lock.withLock {
            guard let record = connections[connectionID] else { return nil }
            guard let key = control.key, !key.operationId.isEmpty else {
                respondLocked(request.requestId, .rejected(.init(reason: .invalidArgument, detail: "mutation key with operation_id is required")), to: connectionID)
                return nil
            }
            let fingerprint: String
            do {
                fingerprint = try codec.commandFingerprint(request)
            } catch {
                respondLocked(request.requestId, .rejected(.init(reason: .invalidArgument, detail: "fingerprint: \(error)")), to: connectionID)
                return nil
            }
            if let previous = hostControlOperations[key.operationId] {
                if previous.fingerprint == fingerprint {
                    respondLocked(request.requestId, previous.outcome, to: connectionID)
                } else {
                    respondLocked(request.requestId, .operationConflict(.init(operationId: key.operationId, recordedFingerprint: previous.fingerprint, submittedFingerprint: fingerprint)), to: connectionID)
                }
                return nil
            }
            switch action {
            case .prepareUpdate:
                guard record.capabilities.contains(.prepareUpdate) else {
                    respondLocked(request.requestId, .rejected(.init(reason: .capabilityMissing, detail: "prepareUpdate")), to: connectionID)
                    return nil
                }
                let result = checkpointAllLocked()
                if result.allCheckpointed {
                    acceptingNewSessions = false
                    let notice = AgentHostHostNoticeV1(kind: .updatePending, detail: "host checkpointed every session; no new sessions", deadlineAt: "", sessionId: "")
                    for other in connections.values {
                        send(.notice(notice), via: other.outbound)
                    }
                }
                let outcome: AgentHostCommandResponseOutcomeV1 = .result(.init(result: .hostControl(.init(result: .prepareUpdate(result)))))
                hostControlOperations[key.operationId] = (fingerprint, outcome)
                respondLocked(request.requestId, outcome, to: connectionID)
                return nil
            case let .shutdown(shutdown):
                let seconds = shutdown.deadlineSeconds == 0 ? 5 : shutdown.deadlineSeconds
                let deadline = AgentSessionHostClock.rfc3339(Date().addingTimeInterval(TimeInterval(seconds)))
                let outcome: AgentHostCommandResponseOutcomeV1 = .result(.init(result: .hostControl(.init(result: .shutdown(.init(deadlineAt: deadline))))))
                hostControlOperations[key.operationId] = (fingerprint, outcome)
                respondLocked(request.requestId, outcome, to: connectionID)
                return .shutdown(mode: shutdown.mode, deadlineSeconds: seconds)
            }
        }
    }

    /// `sync` + `compact` every open session. Any failure means the host refuses the update.
    package func checkpointAll() -> AgentHostPrepareUpdateResultV1 {
        lock.withLock { checkpointAllLocked() }
    }

    private func checkpointAllLocked() -> AgentHostPrepareUpdateResultV1 {
        let checkpoints = sessions.values
            .filter { !$0.closed }
            .sorted { $0.sessionID < $1.sessionID }
            .map { checkpoint($0) }
        return AgentHostPrepareUpdateResultV1(allCheckpointed: checkpoints.allSatisfy(\.succeeded), checkpoints: checkpoints)
    }

    // MARK: Shutdown (design §7.3 ordering)

    /// Stops accepting work, terminates every executor (lock released), then checkpoints and closes
    /// every log. Idempotent.
    package func shutdown() {
        let executors: [any AgentSessionExecutor] = lock.withLock {
            shuttingDown = true
            acceptingNewSessions = false
            return sessions.values.compactMap(\.executor)
        }
        for executor in executors {
            executor.terminate()
        }
        lock.withLock {
            for session in sessions.values where !session.closed {
                session.executor = nil
                if session.state.hasLiveRun {
                    let interrupted = session.state.summary(status: .waitingForInput, statusText: "interrupted: host shutdown", clearingActiveRun: true, now: AgentSessionHostClock.rfc3339())
                    _ = try? appendEvent(session, .sessionMetadataChanged(.init(summary: interrupted)), durability: .deferred)
                }
                checkpoint(session)
                do {
                    try session.log.close()
                } catch {
                    logger.warning("agent-host: close failed for \(session.sessionID): \(error)")
                }
                session.closed = true
            }
        }
    }

    // MARK: Outbound helpers

    private func encode(_ body: AgentHostHostMessageBodyV1) -> Data? {
        do {
            return try codec.encodeHostMessage(AgentHostHostMessageV1(body: body))
        } catch {
            logger.error("agent-host: host message encode failed: \(error)")
            return nil
        }
    }

    private func send(_ body: AgentHostHostMessageBodyV1, via outbound: AgentSessionHostOutboundQueue) {
        guard let frame = encode(body) else { return }
        outbound.enqueueControl(frame)
    }

    private func respond(_ requestID: String, _ outcome: AgentHostCommandResponseOutcomeV1, to connectionID: AgentSessionHostConnectionID) {
        lock.withLock { respondLocked(requestID, outcome, to: connectionID) }
    }

    /// Lock must be held.
    private func respondLocked(_ requestID: String, _ outcome: AgentHostCommandResponseOutcomeV1, to connectionID: AgentSessionHostConnectionID) {
        guard let record = connections[connectionID] else { return }
        send(.response(AgentHostCommandResponseV1(requestId: requestID, outcome: outcome)), via: record.outbound)
    }
}
