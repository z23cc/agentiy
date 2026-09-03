import AgentryCoreBridge
import Foundation
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

/// Shared fixture for the P2 host tests: an isolated Application Support root (own lease, own socket
/// subdirectory, own session logs), an in-process host, and clients that talk to it.
final class AgentSessionHostTestHarness {
    let root: URL
    let codec = CoreAgentHostProtocol()
    let limits: AgentHostProtocolLimitsV1
    let paths: AgentSessionHostPaths
    private(set) var servers: [AgentSessionHostServer] = []
    private(set) var clients: [AgentSessionHostClient] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentry-ash-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        limits = try codec.limits()
        paths = AgentSessionHostPaths(
            applicationSupportRoot: root,
            protocolVersion: limits.protocolVersion,
            isolatedSocketDirectory: true
        )
    }

    func tearDown() {
        for client in clients {
            client.close()
        }
        for server in servers {
            server.stop()
        }
        clients.removeAll()
        servers.removeAll()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: paths.socketDirectory)
    }

    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[AgentryProductIdentity.applicationSupportRootOverrideEnvironmentKey] = root.path
        return environment
    }

    @discardableResult
    func startServer(
        script: AgentSessionScriptedExecutorScript = AgentSessionScriptedExecutorScript(),
        configure: (inout AgentSessionHostConfiguration) -> Void = { _ in }
    ) throws -> AgentSessionHostServer {
        var configuration = AgentSessionHostConfiguration(idleExitSeconds: nil)
        configuration.acceptPollInterval = 0.05
        configure(&configuration)
        let server = try AgentSessionHostServer(
            paths: paths,
            configuration: configuration,
            executorFactory: AgentSessionScriptedExecutorFactory(script: script)
        )
        try server.start()
        servers.append(server)
        return server
    }

    func stopServers() {
        for server in servers {
            server.stop()
        }
        servers.removeAll()
    }

    func clientConfiguration(_ configure: (inout AgentSessionHostClientConfiguration) -> Void = { _ in }) -> AgentSessionHostClientConfiguration {
        var configuration = AgentSessionHostClientConfiguration(paths: paths, clientKind: .test)
        configuration.responseTimeout = 15
        configure(&configuration)
        return configuration
    }

    func connect(_ configure: (inout AgentSessionHostClientConfiguration) -> Void = { _ in }) async throws -> AgentSessionHostClient {
        let client = try await AgentSessionHostClient.connect(configuration: clientConfiguration(configure))
        clients.append(client)
        return client
    }

    @discardableResult
    func track(_ client: AgentSessionHostClient) -> AgentSessionHostClient {
        clients.append(client)
        return client
    }

    // MARK: Commands

    static func message(_ text: String) -> AgentHostUserMessageV1 {
        AgentHostUserMessageV1(messageId: UUID().uuidString.lowercased(), text: text, attachments: [], createdAt: AgentSessionHostClock.rfc3339())
    }

    static func spec(sessionID: String = UUID().uuidString.lowercased(), workspaceID: String = "ws-test", message: String? = "hello") -> AgentHostSessionSpecV1 {
        AgentHostSessionSpecV1(
            sessionId: sessionID,
            workspaceId: workspaceID,
            worktreeId: "",
            sessionName: "P2 test session",
            providerId: "scripted",
            agentId: "scripted",
            agentDisplayName: "Scripted",
            modelId: "scripted-model",
            reasoningEffort: "",
            parentSessionId: "",
            parentForkCursor: 0,
            initialMessage: message.map { Self.message($0) },
            permissionPolicy: nil,
            credentialEnvelopeId: "",
            resumeProviderSessionId: ""
        )
    }

    static func steer(sessionID: String, text: String, operationID: String = UUID().uuidString.lowercased()) -> AgentHostCommandRequestCommandV1 {
        .steer(AgentHostSteerV1(
            key: AgentSessionHostClient.mutationKey(operationID: operationID),
            sessionId: sessionID,
            message: message(text),
            delivery: .queueForNextTurn
        ))
    }

    func startSession(
        _ client: AgentSessionHostClient,
        spec: AgentHostSessionSpecV1 = AgentSessionHostTestHarness.spec(),
        operationID: String = UUID().uuidString.lowercased()
    ) async throws -> AgentHostSessionStartedV1 {
        let outcome = try await client.send(.start(AgentHostStartV1(key: AgentSessionHostClient.mutationKey(operationID: operationID), spec: spec)))
        guard case let .result(result) = outcome, case let .started(started) = result.result else {
            throw HarnessError.unexpectedOutcome(String(describing: outcome))
        }
        return started
    }

    enum HarnessError: Error {
        case unexpectedOutcome(String)
        case timeout(String)
    }

    // MARK: Event collection

    /// Reads pushed frames from one client until `stop` returns true or the deadline passes.
    /// Pumps a client's event stream into a buffer on demand. Reading is explicit (`next`), so a test
    /// that wants to look like a slow client simply does not create a reader (or does not call it).
    final class EventReader: @unchecked Sendable {
        private let lock = NSLock()
        private var buffered: [AgentSessionHostClientEvent] = []
        private var finished = false
        private var pump: Task<Void, Never>?
        private(set) var collected: [AgentSessionHostClientEvent] = []

        init(_ client: AgentSessionHostClient) {
            let stream = client.events
            pump = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    lock.withLock { buffered.append(event) }
                }
                guard let self else { return }
                lock.withLock { finished = true }
            }
        }

        deinit {
            pump?.cancel()
        }

        func next(timeout: TimeInterval = 10) async throws -> AgentSessionHostClientEvent {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let (event, ended): (AgentSessionHostClientEvent?, Bool) = lock.withLock {
                    (buffered.isEmpty ? nil : buffered.removeFirst(), finished)
                }
                if let event {
                    collected.append(event)
                    return event
                }
                if ended { throw HarnessError.timeout("stream ended") }
                if Date() >= deadline { throw HarnessError.timeout("no event within \(timeout)s") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        func collect(timeout: TimeInterval = 10, until stop: (AgentSessionHostClientEvent) -> Bool) async throws -> [AgentSessionHostClientEvent] {
            var batch: [AgentSessionHostClientEvent] = []
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let event = try await next(timeout: max(0.1, deadline.timeIntervalSinceNow))
                batch.append(event)
                if stop(event) { return batch }
            }
            throw HarnessError.timeout("condition not met; saw \(batch.count) events")
        }

        /// Reads through `SnapshotEnd`, returning the decoded snapshot. Non-snapshot frames that
        /// arrive in the same window (live events already in flight) are parked so later `collect`
        /// / `readUntilRunTerminated` still see them.
        func readSnapshot(codec: CoreAgentHostProtocol, timeout: TimeInterval = 10) async throws -> AgentHostAgentSessionSnapshotV1 {
            var assembler = AgentSessionHostSnapshotAssembler()
            var parked: [AgentSessionHostClientEvent] = []
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let event = try await next(timeout: max(0.1, deadline.timeIntervalSinceNow))
                switch event {
                case .snapshotBegin, .snapshotChunk, .snapshotEnd:
                    if let snapshot = try assembler.consume(event, codec: codec) {
                        lock.withLock { buffered.insert(contentsOf: parked, at: 0) }
                        return snapshot
                    }
                case .resnapshotRequired:
                    throw HarnessError.timeout("resnapshotRequired while waiting for snapshot")
                default:
                    parked.append(event)
                }
            }
            lock.withLock { buffered.insert(contentsOf: parked, at: 0) }
            throw HarnessError.timeout("snapshot not completed")
        }

        /// Reads events until the run's `terminated` lifecycle record; returns the delivered cursors.
        func readUntilRunTerminated(timeout: TimeInterval = 10) async throws -> [AgentHostEventNotificationV1] {
            let events = try await collect(timeout: timeout) { event in
                guard case let .event(notification) = event,
                      case let .runLifecycle(lifecycle) = notification.event?.body,
                      case .terminated = lifecycle.kind
                else { return false }
                return true
            }
            return events.compactMap { event -> AgentHostEventNotificationV1? in
                guard case let .event(notification) = event else { return nil }
                return notification
            }
        }

        func pendingInteraction(in snapshot: AgentHostAgentSessionSnapshotV1) -> AgentHostPendingInteractionV1? {
            snapshot.pendingInteractions.first ?? snapshot.summary?.interaction
        }

        /// Drops unread leftover frames so a later attach's snapshot/replay is not mixed with them.
        func drainBuffered() {
            lock.withLock { buffered.removeAll() }
        }
    }

    /// Waits until `sessionID` is no longer `running`. Uses `list_sessions.lastCursor` so a turn that
    /// finished before attach still settles; live events are drained so the reader stays current.
    func waitUntilTurnSettled(
        client: AgentSessionHostClient,
        sessionID: String,
        reader: EventReader,
        timeout: TimeInterval = 10
    ) async throws -> UInt64 {
        let deadline = Date().addingTimeInterval(timeout)
        let needle = sessionID.lowercased()
        while Date() < deadline {
            let list = try await client.listSessions()
            if let summary = list.sessions.first(where: { $0.sessionId.lowercased() == needle }),
               summary.status != .running,
               summary.activeRunId.isEmpty
            {
                return summary.lastCursor
            }
            _ = try? await reader.next(timeout: 0.05)
        }
        throw HarnessError.timeout("turn did not settle for \(sessionID)")
    }

    // MARK: Process helpers (cross-process suites)

    static func agentryMCPExecutableURL() throws -> URL {
        guard let executable = AgentSessionHostExecutable.resolve() else {
            throw XCTSkip("Rust agent-host binary is not built (expected .build/cargo/.../agentry-mcp or bundled agentry-agent-host)")
        }
        return executable
    }

    func launchHostProcess(extraArguments: [String] = ["--idle-exit-seconds", "0"]) throws -> Process {
        let process = Process()
        process.executableURL = try Self.agentryMCPExecutableURL()
        process.arguments = ["agent-host"] + extraArguments
        process.environment = AgentSessionHostLaunchEnvironment.testProcess(from: environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    func waitForSocket(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: paths.socketURL.path) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    static func waitForExit(_ process: Process, timeout: TimeInterval = 15) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return process.isRunning ? nil : process.terminationStatus
    }
}
