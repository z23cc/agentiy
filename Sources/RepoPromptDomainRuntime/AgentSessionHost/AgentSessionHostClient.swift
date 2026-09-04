import AgentryCoreBridge
import Darwin
import Foundation

/// How `AgentSessionHostClient.connect` behaves when no host is listening.
package enum AgentSessionHostSpawnPolicy {
    /// Do not spawn. Used by Sparkle's two-phase update gate against an already-running host.
    case never
    /// Launch the Rust `agentry-mcp agent-host` from `executable` and wait up to `leaseWait` for its
    /// socket. A concurrently launched host that loses the lease exits 75 and the winner's socket is
    /// used. Production resolves `agentry-agent-host` (never the Swift MCP CLI).
    case spawnIfAbsent(executable: URL, extraArguments: [String] = [], environment: [String: String]? = nil, leaseWait: TimeInterval = 10)
    /// The Rust helper is required and was not found. Connecting still succeeds if a host is already
    /// listening; otherwise connect fails closed instead of silently running without a host.
    case rustHelperMissing
}

package struct AgentSessionHostClientConfiguration {
    package var paths: AgentSessionHostPaths
    package var clientKind: AgentHostClientKindV1
    package var capabilities: [AgentHostCapabilityV1]
    package var executableIdentity: AgentHostExecutableIdentityV1
    /// Fingerprint announced in `Hello`; tests override it to exercise host-side rejection.
    package var buildFingerprint: String
    /// Fingerprint the host must announce in `Welcome`; tests override it to exercise client-side rejection.
    package var expectedHostBuildFingerprint: String
    /// Protocol version announced in `Hello`; `nil` uses the codec's frozen version.
    package var protocolVersionOverride: UInt32?
    package var responseTimeout: TimeInterval
    package var connectTimeout: TimeInterval
    /// Pushed frames buffered ahead of the consumer before the reader stops reading the socket, which
    /// is what lets the host see a slow client as backpressure instead of unbounded memory.
    package var eventBufferCapacity: Int
    package var spawn: AgentSessionHostSpawnPolicy

    package init(
        paths: AgentSessionHostPaths,
        clientKind: AgentHostClientKindV1 = .gui,
        capabilities: [AgentHostCapabilityV1] = [.snapshotStreaming, .prepareUpdate],
        executableIdentity: AgentHostExecutableIdentityV1 = AgentSessionHostExecutableIdentity.current(),
        buildFingerprint: String = CoreBuildIdentity.buildFingerprint,
        expectedHostBuildFingerprint: String = CoreBuildIdentity.buildFingerprint,
        protocolVersionOverride: UInt32? = nil,
        responseTimeout: TimeInterval = 30,
        connectTimeout: TimeInterval = 5,
        eventBufferCapacity: Int = 1024,
        spawn: AgentSessionHostSpawnPolicy = .never
    ) {
        self.paths = paths
        self.clientKind = clientKind
        self.capabilities = capabilities
        self.executableIdentity = executableIdentity
        self.buildFingerprint = buildFingerprint
        self.expectedHostBuildFingerprint = expectedHostBuildFingerprint
        self.protocolVersionOverride = protocolVersionOverride
        self.responseTimeout = responseTimeout
        self.connectTimeout = connectTimeout
        self.eventBufferCapacity = max(1, eventBufferCapacity)
        self.spawn = spawn
    }
}

package enum AgentSessionHostClientError: Error {
    case hostUnavailable(String)
    case handshakeRejected(AgentHostHandshakeRejectedV1)
    case hostBuildFingerprintMismatch(expected: String, actual: String)
    case hostProtocolVersionMismatch(expected: UInt32, actual: UInt32)
    case unexpectedMessage(String)
    case disconnected
    case responseTimedOut(requestID: String)
    case snapshotCorrupt(String)
    case spawnFailed(String)
}

/// Everything the host pushes that is not a response to one of this client's requests.
package enum AgentSessionHostClientEvent {
    case event(AgentHostEventNotificationV1)
    case snapshotBegin(AgentHostSnapshotBeginV1)
    case snapshotChunk(AgentHostSnapshotChunkV1)
    case snapshotEnd(AgentHostSnapshotEndV1)
    case resnapshotRequired(AgentHostResnapshotRequiredV1)
    case notice(AgentHostHostNoticeV1)
    /// Terminal: the connection is gone. `error` is `nil` for an orderly close.
    case disconnected(Error?)
}

/// Protocol-only client of the Agent Session Host (design §5; P3's `HostAgentSessionConnection`
/// wraps it). Connects, completes the bidirectional handshake, correlates responses by `request_id`
/// and exposes pushed frames as one ordered `AsyncStream`. It knows nothing about view models.
package final class AgentSessionHostClient: @unchecked Sendable {
    package let configuration: AgentSessionHostClientConfiguration
    package let welcome: AgentHostWelcomeV1
    package let events: AsyncStream<AgentSessionHostClientEvent>

    private let codec: CoreAgentHostProtocol
    private let transport: AgentSessionHostFrameTransport
    private let eventBuffer: BoundedHandoff<AgentSessionHostClientEvent>
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<AgentHostCommandResponseV1, Error>] = [:]
    private var closed = false

    private init(
        configuration: AgentSessionHostClientConfiguration,
        codec: CoreAgentHostProtocol,
        transport: AgentSessionHostFrameTransport,
        welcome: AgentHostWelcomeV1
    ) {
        self.configuration = configuration
        self.codec = codec
        self.transport = transport
        self.welcome = welcome
        let buffer = BoundedHandoff<AgentSessionHostClientEvent>(capacity: configuration.eventBufferCapacity)
        eventBuffer = buffer
        events = AsyncStream(unfolding: { await buffer.next() })
    }

    deinit {
        close()
    }

    package var isConnected: Bool {
        lock.withLock { !closed } && transport.isOpen
    }

    // MARK: Connect

    /// Connects (spawning a host first when the policy allows) and completes the handshake.
    package static func connect(configuration: AgentSessionHostClientConfiguration) async throws -> AgentSessionHostClient {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try connectBlocking(configuration: configuration) })
            }
            thread.name = "agent-host.client.connect"
            thread.start()
        }
    }

    /// Synchronous connect for callers that already sit on a background thread.
    package static func connectBlocking(configuration: AgentSessionHostClientConfiguration) throws -> AgentSessionHostClient {
        let codec = CoreAgentHostProtocol()
        let limits = try codec.limits()
        let descriptor = try openSocket(configuration: configuration)
        let transport = AgentSessionHostFrameTransport(descriptor: descriptor, codec: codec, limits: limits)
        do {
            let hello = AgentHostHelloV1(
                protocolVersion: configuration.protocolVersionOverride ?? limits.protocolVersion,
                buildFingerprint: configuration.buildFingerprint,
                executable: configuration.executableIdentity,
                capabilities: configuration.capabilities,
                clientId: UUID().uuidString.lowercased(),
                clientKind: configuration.clientKind
            )
            try transport.writeFrame(codec.encodeClientMessage(AgentHostClientMessageV1(body: .hello(hello))))
            let reply = try codec.decodeHostMessage(frame: transport.readFrame())
            switch reply.body {
            case let .welcome(welcome):
                guard welcome.protocolVersion == limits.protocolVersion else {
                    throw AgentSessionHostClientError.hostProtocolVersionMismatch(expected: limits.protocolVersion, actual: welcome.protocolVersion)
                }
                guard welcome.buildFingerprint == configuration.expectedHostBuildFingerprint else {
                    throw AgentSessionHostClientError.hostBuildFingerprintMismatch(expected: configuration.expectedHostBuildFingerprint, actual: welcome.buildFingerprint)
                }
                let client = AgentSessionHostClient(configuration: configuration, codec: codec, transport: transport, welcome: welcome)
                client.startReader()
                return client
            case let .handshakeRejected(rejected):
                throw AgentSessionHostClientError.handshakeRejected(rejected)
            default:
                throw AgentSessionHostClientError.unexpectedMessage("expected Welcome or HandshakeRejected")
            }
        } catch {
            transport.close()
            throw error
        }
    }

    private static func openSocket(configuration: AgentSessionHostClientConfiguration) throws -> Int32 {
        let path = configuration.paths.socketURL.path
        do {
            return try AgentSessionHostSocketListener.connect(path: path)
        } catch {
            switch configuration.spawn {
            case let .spawnIfAbsent(executable, extraArguments, environment, leaseWait):
                try spawnHost(executable: executable, extraArguments: extraArguments, environment: environment)
                let deadline = Date().addingTimeInterval(leaseWait)
                var lastError: Error = error
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                    do {
                        return try AgentSessionHostSocketListener.connect(path: path)
                    } catch {
                        lastError = error
                    }
                }
                throw AgentSessionHostClientError.hostUnavailable("\(path) after spawning host: \(lastError)")
            case .rustHelperMissing:
                throw AgentSessionHostClientError.spawnFailed(
                    "Rust agent-host helper not found (expected Contents/MacOS/agentry-agent-host or .build/cargo/.../agentry-mcp)"
                )
            case .never:
                throw AgentSessionHostClientError.hostUnavailable("\(path): \(error)")
            }
        }
    }

    /// Detached launch of `agentry-mcp agent-host`. The host calls `setsid()` itself; a loser of the
    /// lease race exits with code 75, which is harmless here because we only wait for the socket.
    private static func spawnHost(executable: URL, extraArguments: [String], environment: [String: String]?) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["agent-host"] + extraArguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AgentSessionHostClientError.spawnFailed(String(describing: error))
        }
    }

    // MARK: Commands

    /// Sends one command and returns its response outcome.
    package func send(_ command: AgentHostCommandRequestCommandV1) async throws -> AgentHostCommandResponseOutcomeV1 {
        let requestID = UUID().uuidString.lowercased()
        let request = AgentHostCommandRequestV1(requestId: requestID, command: command)
        let frame = try codec.encodeClientMessage(AgentHostClientMessageV1(body: .command(request)))
        let timeout = configuration.responseTimeout
        let response: AgentHostCommandResponseV1 = try await withCheckedThrowingContinuation { continuation in
            let accepted: Bool = lock.withLock {
                guard !closed else { return false }
                pending[requestID] = continuation
                return true
            }
            guard accepted else {
                continuation.resume(throwing: AgentSessionHostClientError.disconnected)
                return
            }
            do {
                try transport.writeFrame(frame)
            } catch {
                if let waiting = lock.withLock({ pending.removeValue(forKey: requestID) }) {
                    waiting.resume(throwing: error)
                }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let waiting = lock.withLock({ pending.removeValue(forKey: requestID) }) else { return }
                waiting.resume(throwing: AgentSessionHostClientError.responseTimedOut(requestID: requestID))
            }
        }
        guard let outcome = response.outcome else {
            throw AgentSessionHostClientError.unexpectedMessage("response without outcome")
        }
        return outcome
    }

    package func listSessions(includeTerminal: Bool = false, workspaceID: String = "") async throws -> AgentHostSessionListV1 {
        let outcome = try await send(.listSessions(.init(includeTerminal: includeTerminal, workspaceId: workspaceID)))
        guard case let .result(result) = outcome, case let .sessionList(list) = result.result else {
            throw AgentSessionHostClientError.unexpectedMessage("list_sessions: \(outcome)")
        }
        return list
    }

    /// Attaches; pass the last applied cursor and its generation to resume, or neither for a fresh
    /// attach. The snapshot/replay frames follow on `events`.
    package func attach(sessionID: String, resumeCursor: UInt64? = nil, resumeGeneration: Data = Data()) async throws -> AgentHostAttachResultV1 {
        let outcome = try await send(.attach(.init(sessionId: sessionID, resumeCursor: resumeCursor, resumeGeneration: resumeGeneration)))
        guard case let .result(result) = outcome, case let .attached(attached) = result.result else {
            throw AgentSessionHostClientError.unexpectedMessage("attach: \(outcome)")
        }
        return attached
    }

    package func detach(sessionID: String) async throws {
        _ = try await send(.detach(.init(sessionId: sessionID)))
    }

    /// Mutating commands carry a caller-generated `operationID` (design §5.4); retries reuse it.
    package static func mutationKey(operationID: String = UUID().uuidString.lowercased()) -> AgentHostMutationKeyV1 {
        AgentHostMutationKeyV1(operationId: operationID, argumentFingerprint: "")
    }

    package func start(_ spec: AgentHostSessionSpecV1, operationID: String = UUID().uuidString.lowercased()) async throws -> AgentHostSessionStartedV1 {
        let outcome = try await send(.start(.init(key: Self.mutationKey(operationID: operationID), spec: spec)))
        guard case let .result(result) = outcome, case let .started(started) = result.result else {
            throw AgentSessionHostClientError.unexpectedMessage("start: \(outcome)")
        }
        return started
    }

    package func steer(sessionID: String, message: AgentHostUserMessageV1, delivery: AgentHostSteerDeliveryV1 = .queueForNextTurn, operationID: String = UUID().uuidString.lowercased()) async throws -> AgentHostSteeredV1 {
        let outcome = try await send(.steer(.init(key: Self.mutationKey(operationID: operationID), sessionId: sessionID, message: message, delivery: delivery)))
        guard case let .result(result) = outcome, case let .steered(steered) = result.result else {
            throw AgentSessionHostClientError.unexpectedMessage("steer: \(outcome)")
        }
        return steered
    }

    package func interrupt(sessionID: String, turnID: String = "", operationID: String = UUID().uuidString.lowercased()) async throws -> AgentHostInterruptResultV1 {
        let outcome = try await send(.interrupt(.init(key: Self.mutationKey(operationID: operationID), sessionId: sessionID, turnId: turnID)))
        guard case let .result(result) = outcome, case let .interrupted(interrupted) = result.result else {
            throw AgentSessionHostClientError.unexpectedMessage("interrupt: \(outcome)")
        }
        return interrupted
    }

    package func respond(sessionID: String, interactionID: String, generation: Data, answer: AgentHostInteractionAnswerV1, operationID: String = UUID().uuidString.lowercased()) async throws -> AgentHostInteractionRespondedV1 {
        let outcome = try await send(.respondInteraction(.init(
            key: Self.mutationKey(operationID: operationID),
            sessionId: sessionID,
            interactionId: interactionID,
            interactionGeneration: generation,
            answer: answer
        )))
        guard case let .result(result) = outcome, case let .interactionResponded(responded) = result.result else {
            throw AgentSessionHostClientError.unexpectedMessage("respond_interaction: \(outcome)")
        }
        return responded
    }

    package func stop(sessionID: String, reason: AgentHostStopReasonV1 = .userRequested, operationID: String = UUID().uuidString.lowercased()) async throws -> AgentHostStoppedV1 {
        let outcome = try await send(.stop(.init(key: Self.mutationKey(operationID: operationID), sessionId: sessionID, reason: reason)))
        guard case let .result(result) = outcome, case let .stopped(stopped) = result.result else {
            throw AgentSessionHostClientError.unexpectedMessage("stop: \(outcome)")
        }
        return stopped
    }

    package func prepareUpdate(deadlineSeconds: UInt32 = 5, operationID: String = UUID().uuidString.lowercased()) async throws -> AgentHostPrepareUpdateResultV1 {
        let outcome = try await send(.hostControl(.init(
            key: Self.mutationKey(operationID: operationID),
            action: .prepareUpdate(.init(deadlineSeconds: deadlineSeconds))
        )))
        guard case let .result(result) = outcome, case let .hostControl(control) = result.result,
              case let .prepareUpdate(prepared) = control.result
        else {
            throw AgentSessionHostClientError.unexpectedMessage("prepare_update: \(outcome)")
        }
        return prepared
    }

    package func shutdown(mode: AgentHostShutdownModeV1 = .graceful, deadlineSeconds: UInt32 = 5, operationID: String = UUID().uuidString.lowercased()) async throws -> AgentHostShutdownAcceptedV1 {
        let outcome = try await send(.hostControl(.init(
            key: Self.mutationKey(operationID: operationID),
            action: .shutdown(.init(mode: mode, deadlineSeconds: deadlineSeconds))
        )))
        guard case let .result(result) = outcome, case let .hostControl(control) = result.result,
              case let .shutdown(accepted) = control.result
        else {
            throw AgentSessionHostClientError.unexpectedMessage("shutdown: \(outcome)")
        }
        return accepted
    }

    /// Closes this connection and opens a new one with the same configuration. Spawn-if-absent and
    /// lease-wait still apply. Re-attach with the last applied `resumeCursor` / `resumeGeneration`.
    package func reconnect() async throws -> AgentSessionHostClient {
        close()
        return try await AgentSessionHostClient.connect(configuration: configuration)
    }

    /// `reconnect()` then `attach` with the caller's cursor. Generation mismatch yields `unavailable`.
    package func reconnectAndAttach(
        sessionID: String,
        resumeCursor: UInt64,
        resumeGeneration: Data
    ) async throws -> (client: AgentSessionHostClient, attach: AgentHostAttachResultV1) {
        let client = try await reconnect()
        let attach = try await client.attach(sessionID: sessionID, resumeCursor: resumeCursor, resumeGeneration: resumeGeneration)
        return (client, attach)
    }

    package func close() {
        let firstClose: Bool = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard firstClose else { return }
        transport.close()
        failPending(with: AgentSessionHostClientError.disconnected)
        eventBuffer.finish(with: .disconnected(nil))
    }

    // MARK: Reader

    private func startReader() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "agent-host.client.read"
        thread.start()
    }

    private func readLoop() {
        var terminalError: Error?
        do {
            while true {
                let message = try codec.decodeHostMessage(frame: transport.readFrame())
                switch message.body {
                case let .response(response):
                    if let waiting = lock.withLock({ pending.removeValue(forKey: response.requestId) }) {
                        waiting.resume(returning: response)
                    }
                case let .event(event): eventBuffer.push(.event(event))
                case let .snapshotBegin(begin): eventBuffer.push(.snapshotBegin(begin))
                case let .snapshotChunk(chunk): eventBuffer.push(.snapshotChunk(chunk))
                case let .snapshotEnd(end): eventBuffer.push(.snapshotEnd(end))
                case let .resnapshotRequired(required): eventBuffer.push(.resnapshotRequired(required))
                case let .notice(notice): eventBuffer.push(.notice(notice))
                case .welcome, .handshakeRejected:
                    throw AgentSessionHostClientError.unexpectedMessage("handshake frame after Welcome")
                case nil:
                    throw AgentSessionHostClientError.unexpectedMessage("empty host message")
                }
            }
        } catch {
            if case AgentSessionHostTransportError.closed = error {
                terminalError = lock.withLock { closed } ? nil : AgentSessionHostClientError.disconnected
            } else {
                terminalError = error
            }
        }
        let alreadyClosed: Bool = lock.withLock {
            let was = closed
            closed = true
            return was
        }
        transport.close()
        failPending(with: terminalError ?? AgentSessionHostClientError.disconnected)
        if !alreadyClosed {
            eventBuffer.finish(with: .disconnected(terminalError))
        }
    }

    private func failPending(with error: Error) {
        let waiting = lock.withLock {
            let all = Array(pending.values)
            pending.removeAll()
            return all
        }
        for continuation in waiting {
            continuation.resume(throwing: error)
        }
    }
}

/// Bounded producer/consumer handoff between the blocking reader thread and the async consumer. The
/// producer blocks when `capacity` items are waiting, so an unread socket is the backpressure signal.
final class BoundedHandoff<Element: Sendable>: @unchecked Sendable {
    private let capacity: Int
    private let condition = NSCondition()
    private var items: [Element] = []
    private var waitingConsumer: CheckedContinuation<Element?, Never>?
    private var finished = false

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Blocks while the buffer is full; drops nothing unless finished.
    func push(_ element: Element) {
        let waiter: CheckedContinuation<Element?, Never>?
        condition.lock()
        while items.count >= capacity, !finished, waitingConsumer == nil {
            condition.wait()
        }
        if finished {
            condition.unlock()
            return
        }
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            waiter = consumer
            condition.unlock()
        } else {
            items.append(element)
            waiter = nil
            condition.unlock()
        }
        waiter?.resume(returning: element)
    }

    /// Delivers `last` after everything queued, then ends the stream. Idempotent.
    func finish(with last: Element) {
        let waiter: CheckedContinuation<Element?, Never>?
        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        finished = true
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            waiter = consumer
            condition.unlock()
        } else {
            items.append(last)
            waiter = nil
            condition.broadcast()
            condition.unlock()
        }
        waiter?.resume(returning: last)
    }

    /// Single consumer; `nil` once finished and drained.
    func next() async -> Element? {
        await withCheckedContinuation { continuation in
            condition.lock()
            if !items.isEmpty {
                let element = items.removeFirst()
                condition.broadcast()
                condition.unlock()
                continuation.resume(returning: element)
            } else if finished {
                condition.unlock()
                continuation.resume(returning: nil)
            } else {
                waitingConsumer = continuation
                condition.unlock()
            }
        }
    }
}

/// Reassembles a `SnapshotBegin` … `SnapshotChunk`* … `SnapshotEnd` sequence into a decoded snapshot,
/// verifying length and SHA-256 digest.
package struct AgentSessionHostSnapshotAssembler {
    private var begin: AgentHostSnapshotBeginV1?
    private var bytes = Data()

    package init() {}

    /// Feeds one client event. Returns the snapshot when `SnapshotEnd` completes a valid stream.
    package mutating func consume(_ event: AgentSessionHostClientEvent, codec: CoreAgentHostProtocol) throws -> AgentHostAgentSessionSnapshotV1? {
        switch event {
        case let .snapshotBegin(header):
            begin = header
            bytes = Data()
            bytes.reserveCapacity(Int(clamping: header.byteLength))
            return nil
        case let .snapshotChunk(chunk):
            guard begin != nil else { throw AgentSessionHostClientError.snapshotCorrupt("chunk before begin") }
            guard UInt64(bytes.count) == chunk.offset else {
                throw AgentSessionHostClientError.snapshotCorrupt("chunk offset \(chunk.offset) != \(bytes.count)")
            }
            bytes.append(chunk.data)
            return nil
        case let .snapshotEnd(end):
            guard let header = begin else { throw AgentSessionHostClientError.snapshotCorrupt("end before begin") }
            defer {
                begin = nil
                bytes = Data()
            }
            guard UInt64(bytes.count) == header.byteLength else {
                throw AgentSessionHostClientError.snapshotCorrupt("length \(bytes.count) != \(header.byteLength)")
            }
            guard DomainContentDigest.sha256(bytes) == header.digestSha256 else {
                throw AgentSessionHostClientError.snapshotCorrupt("digest mismatch")
            }
            let snapshot = try codec.decodeSnapshot(bytes: bytes)
            guard snapshot.throughCursor == end.throughCursor else {
                throw AgentSessionHostClientError.snapshotCorrupt("through cursor \(snapshot.throughCursor) != \(end.throughCursor)")
            }
            return snapshot
        case .event, .resnapshotRequired, .notice, .disconnected:
            return nil
        }
    }
}
