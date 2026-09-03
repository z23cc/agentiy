import Foundation
import RepoPromptDomainRuntime

/// Tests-only `AgentSessionConnection` wrapping the in-process execution stack.
///
/// Production constructs `HostAgentSessionConnection` (ADR-0011 P3). This type remains for
/// P1.5 connection tests and any harness that assembles the in-process stack without a host.
///
/// The actor runs on the main executor (`unownedExecutor` = `MainActor`) because the stack
/// it wraps — provider coordinators, run service, `AgentTabSession` mutation — is
/// `@MainActor`; binding the actor there keeps command ordering identical to the direct
/// calls it replaces and adds no cross-thread hops. `HostAgentSessionConnection` (P3) will
/// be a real off-main actor speaking to the host socket.
///
/// Responsibilities:
/// - session registry (`attach`/`detach`) and per-session replay cursors (design §5.5);
/// - `operationID` idempotency journal (design §5.4): a retry with the same ID and the same
///   payload returns the recorded outcome, a different payload is rejected. The journal is
///   a per-connection LRU bounded at `journalCapacity` operations, and every operation a
///   session settled is evicted when that session is stopped or its generation rotates;
/// - command lifecycle events (`commandAccepted` / `commandSettled`) and the runtime event
///   vocabulary on `events`. The value a command returns is the same payload its
///   `commandSettled` event carries, exactly like `CommandResponse` on the wire.
///
/// Wiring: the composition root constructs the executor and the connection, hands the
/// connection to the view model as `any AgentSessionConnection`, then attaches the view
/// model to the executor. Commands without an executor fail with `.executorUnavailable`.
actor InProcessAgentSessionConnection: AgentSessionConnection {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        MainActor.sharedUnownedExecutor
    }

    private enum JournalEntry {
        case inFlight(fingerprint: String, task: Task<AgentSessionCommandOutcome, Error>)
        case settled(fingerprint: String, result: Result<AgentSessionCommandOutcome, AgentSessionConnectionError>)

        var fingerprint: String {
            switch self {
            case let .inFlight(fingerprint, _), let .settled(fingerprint, _):
                fingerprint
            }
        }
    }

    /// One execution lineage behind a session: the presentation cache whose execution state
    /// backs it plus the opaque generation minted when that lineage was registered.
    private struct Lineage {
        let sessionIdentity: ObjectIdentifier
        let generation: Data
    }

    /// Upper bound on remembered operations per connection. A client retries an uncertain
    /// command promptly, so a bound in the low thousands keeps every plausible retry window
    /// while capping memory for long-lived windows. Least recently used entries go first.
    static let journalCapacity = 1024
    /// Epoch used for cursors of sessions that were never registered with this connection.
    private static let unregisteredEpoch = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Distinguishes cursors minted by this connection instance from any earlier one.
    private let instanceNonce = UUID()
    private var executor: (any InProcessAgentSessionExecuting)?
    private var attachedSessionIDs: Set<UUID> = []
    private var lineageBySessionID: [UUID: Lineage] = [:]
    private var deliveryCursorBySessionID: [UUID: UInt64] = [:]
    private var journal: [UUID: JournalEntry] = [:]
    /// Least recently used first.
    private var journalOrder: [UUID] = []
    private var journalOperationsBySessionID: [UUID: Set<UUID>] = [:]
    private var sessionIDByJournalOperation: [UUID: UUID] = [:]
    private let eventContinuation: AsyncStream<AgentSessionConnectionEvent>.Continuation
    let events: AsyncStream<AgentSessionConnectionEvent>

    init(executor: (any InProcessAgentSessionExecuting)? = nil) {
        self.executor = executor
        var continuation: AsyncStream<AgentSessionConnectionEvent>.Continuation?
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        // The `AsyncStream` initializer invokes its build closure synchronously.
        eventContinuation = continuation!
    }

    // MARK: - Composition

    /// Installs or replaces the execution stack. The composition root passes the executor
    /// at construction; harnesses use this to swap a fake in later.
    func installExecutor(_ executor: any InProcessAgentSessionExecuting) {
        self.executor = executor
    }

    var hasExecutor: Bool {
        executor != nil
    }

    var attachedSessions: Set<UUID> {
        attachedSessionIDs
    }

    /// Number of operations currently remembered by the idempotency journal.
    var journalCount: Int {
        journal.count
    }

    /// Whether the journal still remembers `operationID`.
    func journalContains(_ operationID: UUID) -> Bool {
        journal[operationID] != nil
    }

    // MARK: - AgentSessionConnection

    func attach(sessionID: UUID, resume: AgentSessionCursor?) async throws -> AgentSessionAttachResult {
        let executor = try requireExecutor()
        guard let session = try await resolveSession(sessionID, executor: executor) else {
            throw AgentSessionConnectionError.sessionNotFound(sessionID)
        }
        registerGeneration(for: sessionID, session: session)
        attachedSessionIDs.insert(sessionID)
        let snapshot = await executor.snapshot(of: session)
        let cursor = advanceCursor(for: sessionID)
        eventContinuation.yield(.attached(sessionID: sessionID, cursor: cursor))
        return AgentSessionAttachResult(
            snapshot: snapshot,
            cursor: cursor,
            replay: replayFidelity(resume: resume, current: cursor)
        )
    }

    func detach(sessionID: UUID) async {
        guard attachedSessionIDs.remove(sessionID) != nil else { return }
        eventContinuation.yield(.detached(sessionID: sessionID))
    }

    func start(_ spec: AgentSessionStartSpec, operationID: UUID) async throws -> AgentSessionStartResult {
        let outcome = try await perform(
            operationID: operationID,
            sessionID: nil,
            fingerprint: "start|\(spec.tabID)|\(spec.resumeSessionID?.uuidString ?? "-")|\(spec.message.messageID)|\(spec.message.text)|\(spec.message.attachments.count)|\(spec.message.taggedFileAttachments.count)"
        ) { [self] in
            let executor = try requireExecutor()
            let started = try await executor.startRun(spec)
            if let session = await executor.session(forTab: spec.tabID) {
                registerGeneration(for: started.sessionID, session: session)
            }
            return Settlement(sessionID: started.sessionID) { cursor in
                .started(AgentSessionStartResult(
                    sessionID: started.sessionID,
                    sendOutcome: started.sendOutcome,
                    cursor: cursor
                ))
            }
        }
        guard case let .started(result) = outcome else {
            throw AgentSessionConnectionError.commandRejected("start settled without a SessionStarted payload")
        }
        return result
    }

    func steer(sessionID: UUID, message: AgentSessionUserMessage, operationID: UUID) async throws -> AgentSessionSteerResult {
        let outcome = try await perform(
            operationID: operationID,
            sessionID: sessionID,
            fingerprint: "steer|\(sessionID)|\(message.messageID)|\(message.text)|\(message.attachments.count)|\(message.taggedFileAttachments.count)"
        ) { [self] in
            let (executor, session) = try await requireLiveSession(sessionID)
            let sendOutcome = try await executor.steer(session: session, message: message)
            return Settlement(sessionID: sessionID) { cursor in
                .steered(AgentSessionSteerResult(
                    sessionID: sessionID,
                    messageID: message.messageID,
                    sendOutcome: sendOutcome,
                    recordedCursor: cursor
                ))
            }
        }
        guard case let .steered(result) = outcome else {
            throw AgentSessionConnectionError.commandRejected("steer settled without a Steered payload")
        }
        return result
    }

    func interrupt(sessionID: UUID, reason: AgentSessionInterruptReason, operationID: UUID) async throws -> AgentSessionInterruptResult {
        let outcome = try await perform(
            operationID: operationID,
            sessionID: sessionID,
            fingerprint: "interrupt|\(sessionID)|\(reason.rawValue)"
        ) { [self] in
            let (executor, session) = try await requireLiveSession(sessionID)
            let interruptOutcome = await executor.interrupt(session: session, reason: reason)
            return Settlement(sessionID: sessionID) { _ in
                .interrupted(AgentSessionInterruptResult(
                    sessionID: sessionID,
                    outcome: interruptOutcome,
                    detail: nil
                ))
            }
        }
        guard case let .interrupted(result) = outcome else {
            throw AgentSessionConnectionError.commandRejected("interrupt settled without an InterruptResult payload")
        }
        return result
    }

    func respond(sessionID: UUID, interactionID: UUID, answer: AgentInteractionAnswer, operationID: UUID) async throws -> AgentSessionRespondResult {
        let outcome = try await perform(
            operationID: operationID,
            sessionID: sessionID,
            fingerprint: "respond|\(sessionID)|\(interactionID)|\(String(describing: answer))"
        ) { [self] in
            let (executor, session) = try await requireLiveSession(sessionID)
            let disposition = try await executor.respond(session: session, interactionID: interactionID, answer: answer)
            return Settlement(sessionID: sessionID) { _ in
                .interactionResponded(AgentSessionRespondResult(
                    sessionID: sessionID,
                    interactionID: interactionID,
                    disposition: disposition
                ))
            }
        }
        guard case let .interactionResponded(result) = outcome else {
            throw AgentSessionConnectionError.commandRejected("respond settled without an InteractionResponded payload")
        }
        return result
    }

    func stop(sessionID: UUID, reason: AgentSessionStopReason, operationID: UUID) async throws -> AgentSessionStopResult {
        let outcome = try await perform(
            operationID: operationID,
            sessionID: sessionID,
            fingerprint: "stop|\(sessionID)|\(reason.rawValue)"
        ) { [self] in
            let (executor, session) = try await requireLiveSession(sessionID)
            let status = await executor.stop(session: session, reason: reason)
            return Settlement(sessionID: sessionID) { _ in
                .stopped(AgentSessionStopResult(sessionID: sessionID, status: status))
            }
        }
        guard case let .stopped(result) = outcome else {
            throw AgentSessionConnectionError.commandRejected("stop settled without a Stopped payload")
        }
        // The session is closed from this client's point of view: nothing it settled can be
        // retried meaningfully, so release its journal entries (per-session eviction).
        evictJournal(forSession: sessionID, keeping: operationID)
        return result
    }

    func detachAll() async {
        let ids = attachedSessionIDs
        for sessionID in ids {
            await detach(sessionID: sessionID)
        }
    }

    func prepareHostUpdate() async throws -> AgentSessionPrepareUpdateResult {
        AgentSessionPrepareUpdateResult(allCheckpointed: true, detail: "in-process")
    }

    func listSessions(includeTerminal _: Bool, workspaceID _: UUID?) async throws -> [AgentSessionListedSummary] {
        []
    }

    // MARK: - Execution-side publication

    /// Publishes a provider-neutral runtime event for an attached session. Execution-side
    /// callers only; unattached sessions are dropped because no client is listening.
    func publishRuntimeEvent(_ event: NativeAgentRuntimeEvent, sessionID: UUID) {
        guard attachedSessionIDs.contains(sessionID) else { return }
        let cursor = advanceCursor(for: sessionID)
        eventContinuation.yield(.runtime(sessionID: sessionID, event: event, cursor: cursor))
    }

    /// Publishes the typed termination of the current run for an attached session.
    func publishRunTermination(_ outcome: DomainAgentRunTerminalOutcome, sessionID: UUID) {
        guard attachedSessionIDs.contains(sessionID) else { return }
        let cursor = advanceCursor(for: sessionID)
        eventContinuation.yield(.runTerminated(sessionID: sessionID, outcome: outcome, cursor: cursor))
    }

    /// Rotates the generation behind a session (its execution state was recreated) and
    /// tells attached clients to resnapshot. Operations settled against the old generation
    /// are forgotten: a retry would target a lineage that no longer exists.
    func invalidateGeneration(for sessionID: UUID) {
        lineageBySessionID[sessionID] = nil
        deliveryCursorBySessionID[sessionID] = nil
        evictJournal(forSession: sessionID, keeping: nil)
        guard attachedSessionIDs.contains(sessionID) else { return }
        eventContinuation.yield(.resnapshotRequired(sessionID: sessionID))
    }

    // MARK: - Cursors

    func currentCursor(for sessionID: UUID) -> AgentSessionCursor {
        AgentSessionCursor(
            generation: generation(for: sessionID),
            deliveryCursor: deliveryCursorBySessionID[sessionID] ?? 0
        )
    }

    private func advanceCursor(for sessionID: UUID) -> AgentSessionCursor {
        let next = (deliveryCursorBySessionID[sessionID] ?? 0) &+ 1
        deliveryCursorBySessionID[sessionID] = next
        return AgentSessionCursor(generation: generation(for: sessionID), deliveryCursor: next)
    }

    private func generation(for sessionID: UUID) -> Data {
        if let lineage = lineageBySessionID[sessionID] {
            return lineage.generation
        }
        return Self.generationBytes(nonce: instanceNonce, epoch: Self.unregisteredEpoch)
    }

    /// Starts a new lineage (fresh generation, delivery cursor back to zero) when the
    /// session is seen for the first time, after `invalidateGeneration`, or when a
    /// different presentation cache now backs the session (for example after a
    /// workspace switch replaced the tab session).
    private func registerGeneration(for sessionID: UUID, session: AgentTabSession) {
        let identity = ObjectIdentifier(session)
        if let lineage = lineageBySessionID[sessionID], lineage.sessionIdentity == identity {
            return
        }
        lineageBySessionID[sessionID] = Lineage(
            sessionIdentity: identity,
            generation: Self.generationBytes(nonce: instanceNonce, epoch: UUID())
        )
        deliveryCursorBySessionID[sessionID] = 0
    }

    /// Opaque generation bytes: connection instance nonce plus a per-lineage epoch. Either
    /// changing invalidates every earlier delivery cursor; clients never parse them.
    private static func generationBytes(nonce: UUID, epoch: UUID) -> Data {
        var data = Data(count: 32)
        withUnsafeBytes(of: nonce.uuid) { data.replaceSubrange(0 ..< 16, with: $0) }
        withUnsafeBytes(of: epoch.uuid) { data.replaceSubrange(16 ..< 32, with: $0) }
        return data
    }

    private func replayFidelity(resume: AgentSessionCursor?, current: AgentSessionCursor) -> AgentSessionReplayFidelity {
        guard let resume else { return .complete }
        guard resume.sharesGeneration(with: current) else { return .unavailable }
        // The attach event itself is the only event since a cursor that was current.
        return resume.deliveryCursor &+ 1 >= current.deliveryCursor ? .complete : .partial
    }

    // MARK: - Command plumbing

    /// What a command body hands back: the session the settlement is bound to and a builder
    /// that receives the settlement cursor, so the returned payload and the `commandSettled`
    /// event carry the identical value.
    private struct Settlement {
        let sessionID: UUID
        let makeOutcome: (AgentSessionCursor) -> AgentSessionCommandOutcome
    }

    private func requireExecutor() throws -> any InProcessAgentSessionExecuting {
        guard let executor else { throw AgentSessionConnectionError.executorUnavailable }
        return executor
    }

    // The executor is `@MainActor` and this actor runs on the main executor, so the awaits
    // below never suspend (same executor); they only satisfy static isolation checking.

    private func resolveSession(_ sessionID: UUID, executor: any InProcessAgentSessionExecuting) async throws -> AgentTabSession? {
        do {
            return try await executor.session(forSessionID: sessionID)
        } catch {
            throw Self.connectionError(from: error)
        }
    }

    private func requireLiveSession(_ sessionID: UUID) async throws -> (any InProcessAgentSessionExecuting, AgentTabSession) {
        let executor = try requireExecutor()
        guard let session = try await resolveSession(sessionID, executor: executor) else {
            throw AgentSessionConnectionError.sessionNotFound(sessionID)
        }
        return (executor, session)
    }

    private func perform(
        operationID: UUID,
        sessionID: UUID?,
        fingerprint: String,
        _ body: @escaping () async throws -> Settlement
    ) async throws -> AgentSessionCommandOutcome {
        if let entry = journal[operationID] {
            guard entry.fingerprint == fingerprint else {
                throw AgentSessionConnectionError.operationConflict(operationID)
            }
            touchJournal(operationID)
            switch entry {
            case let .inFlight(_, task):
                return try await task.value
            case let .settled(_, result):
                return try result.get()
            }
        }
        let task = Task<AgentSessionCommandOutcome, Error> { [self] in
            let settlement = try await body()
            // Advancing the cursor here, inside the journaled task, keeps a retry that joins
            // the in-flight task and the original caller on one settlement value.
            let cursor = advanceCursor(for: settlement.sessionID)
            return settlement.makeOutcome(cursor)
        }
        recordJournal(operationID, entry: .inFlight(fingerprint: fingerprint, task: task), sessionID: sessionID)
        eventContinuation.yield(.commandAccepted(
            sessionID: sessionID,
            operationID: operationID,
            cursor: sessionID.map(currentCursor)
        ))
        let result: Result<AgentSessionCommandOutcome, AgentSessionConnectionError>
        // The journal and the settled event carry the seam error vocabulary; the original
        // caller still receives the executor's typed error so in-process clients keep
        // switching on it (the wire only ever delivers `CommandRejected`).
        var originalError: Error?
        do {
            let settledOutcome = try await task.value
            result = .success(settledOutcome)
        } catch {
            originalError = error
            result = .failure(Self.connectionError(from: error))
        }
        let outcome: AgentSessionCommandOutcome = switch result {
        case let .success(outcome): outcome
        case let .failure(error): .rejected(error)
        }
        let settledSessionID = sessionID ?? outcome.sessionID
        recordJournal(operationID, entry: .settled(fingerprint: fingerprint, result: result), sessionID: settledSessionID)
        eventContinuation.yield(.commandSettled(
            sessionID: settledSessionID,
            operationID: operationID,
            outcome: outcome,
            cursor: settledSessionID.map(currentCursor)
        ))
        if let originalError {
            throw originalError
        }
        return try result.get()
    }

    // MARK: - Idempotency journal (bounded LRU)

    private func recordJournal(_ operationID: UUID, entry: JournalEntry, sessionID: UUID?) {
        if journal[operationID] == nil {
            journalOrder.append(operationID)
        } else {
            touchJournal(operationID)
        }
        journal[operationID] = entry
        if let sessionID, sessionIDByJournalOperation[operationID] == nil {
            sessionIDByJournalOperation[operationID] = sessionID
            journalOperationsBySessionID[sessionID, default: []].insert(operationID)
        }
        while journalOrder.count > Self.journalCapacity {
            forgetJournal(journalOrder.removeFirst())
        }
    }

    private func touchJournal(_ operationID: UUID) {
        guard let index = journalOrder.lastIndex(of: operationID) else { return }
        journalOrder.remove(at: index)
        journalOrder.append(operationID)
    }

    private func forgetJournal(_ operationID: UUID) {
        journal[operationID] = nil
        if let sessionID = sessionIDByJournalOperation.removeValue(forKey: operationID) {
            journalOperationsBySessionID[sessionID]?.remove(operationID)
            if journalOperationsBySessionID[sessionID]?.isEmpty == true {
                journalOperationsBySessionID[sessionID] = nil
            }
        }
    }

    /// Drops every operation settled against `sessionID`, except `keeping` (the closing
    /// operation itself stays retry-safe until it ages out of the LRU).
    private func evictJournal(forSession sessionID: UUID, keeping: UUID?) {
        guard let operations = journalOperationsBySessionID[sessionID] else { return }
        for operationID in operations where operationID != keeping {
            if let index = journalOrder.lastIndex(of: operationID) {
                journalOrder.remove(at: index)
            }
            forgetJournal(operationID)
        }
    }

    private static func connectionError(from error: Error) -> AgentSessionConnectionError {
        if let connectionError = error as? AgentSessionConnectionError {
            return connectionError
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .commandRejected(message)
    }
}
