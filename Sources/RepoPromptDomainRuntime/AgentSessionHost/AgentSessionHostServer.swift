import AgentryCoreBridge
import Darwin
import Foundation
import Logging

/// Process exit codes of `agentry-mcp agent-host` (sysexits.h values where one fits).
package enum AgentSessionHostExitCode: Int32 {
    /// Clean exit: idle exit, `shutdown` command, or SIGTERM/SIGINT.
    case success = 0
    /// Bad command line.
    case usage = 2
    /// Lease acquired but the host could not start (socket, recovery, unsupported log schema).
    case startupFailure = 70
    /// Another live host holds the per-user lease.
    case leaseContended = 75
}

package enum AgentSessionHostServerError: Error {
    case leaseContended(observedOwner: AgentSessionHostLeaseOwner?)
    case leaseFailed(String)
    case alreadyStarted
    case socket(String)
}

/// The host process shell (design §4.1): lease → recovery → socket → accept loop → idle exit. One
/// server per process. Tests start it in-process on redirected paths; the CLI runs `run()` to block.
package final class AgentSessionHostServer: @unchecked Sendable {
    package let paths: AgentSessionHostPaths
    package let configuration: AgentSessionHostConfiguration
    package let codec: CoreAgentHostProtocol
    package let limits: AgentHostProtocolLimitsV1
    package let hostInstanceID: String
    package let hostStartedAt: String
    package let router: AgentSessionRouter
    package private(set) var recoveryReport = AgentSessionRouterRecoveryReport()

    private let logger: Logger
    private let stateLock = NSLock()
    private let wakeup = NSCondition()
    private var lease: AgentSessionHostLease?
    private var listener: AgentSessionHostSocketListener?
    private var acceptThread: Thread?
    private var connections: [UUID: Connection] = [:]
    private var started = false
    private var stopRequested = false
    private var runLoopActive = false
    private var stopping = false
    private var stopped = false
    private var idleSince: Date?
    private var activity: NSObjectProtocol?

    package init(
        paths: AgentSessionHostPaths,
        configuration: AgentSessionHostConfiguration,
        executorFactory: any AgentSessionExecutorFactory,
        logger: Logger = Logger(label: "com.agentry.agent-host")
    ) throws {
        self.paths = paths
        self.configuration = configuration
        self.logger = logger
        codec = CoreAgentHostProtocol()
        limits = try codec.limits()
        hostInstanceID = UUID().uuidString.lowercased()
        hostStartedAt = AgentSessionHostClock.rfc3339()
        router = AgentSessionRouter(
            paths: paths,
            codec: codec,
            limits: limits,
            configuration: configuration,
            executorFactory: executorFactory,
            hostInstanceID: hostInstanceID,
            logger: logger
        )
    }

    /// Convenience: paths derived from the environment for the frozen protocol version of this codec.
    package static func resolvePaths(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AgentSessionHostPaths {
        let limits = try CoreAgentHostProtocol().limits()
        return AgentSessionHostPaths.resolve(environment: environment, protocolVersion: limits.protocolVersion)
    }

    package var socketPath: String {
        paths.socketURL.path
    }

    package var connectionCount: Int {
        stateLock.withLock { connections.count }
    }

    package var isRunning: Bool {
        stateLock.withLock { started && !stopped }
    }

    // MARK: Lifecycle

    /// Acquires the lease, recovers sessions from disk, binds the socket and starts accepting.
    package func start() throws {
        try stateLock.withLock {
            guard !started else { throw AgentSessionHostServerError.alreadyStarted }
            started = true
        }
        let owner = AgentSessionHostLeaseOwner(
            hostInstanceID: hostInstanceID,
            buildFingerprint: CoreBuildIdentity.buildFingerprint,
            socketPath: socketPath
        )
        switch AgentSessionHostLease.acquire(paths: paths, owner: owner) {
        case let .acquired(lease):
            self.lease = lease
        case let .contended(observedOwner):
            throw AgentSessionHostServerError.leaseContended(observedOwner: observedOwner)
        case let .failed(reason):
            throw AgentSessionHostServerError.leaseFailed(reason)
        }

        recoveryReport = router.recover()
        if !recoveryReport.recoveredSessionIDs.isEmpty
            || !recoveryReport.importedSessionIDs.isEmpty
            || !recoveryReport.skipped.isEmpty
        {
            logger.info("agent-host recovered \(recoveryReport.recoveredSessionIDs.count) session(s); imported \(recoveryReport.importedSessionIDs.count); demoted \(recoveryReport.demotedSessionIDs.count); skipped \(recoveryReport.skipped.count)")
        }

        do {
            listener = try AgentSessionHostSocketListener.bind(path: socketPath)
        } catch {
            lease?.release()
            lease = nil
            throw AgentSessionHostServerError.socket(String(describing: error))
        }

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: "agentry-mcp agent-host"
        )
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "agent-host.accept"
        acceptThread = thread
        thread.start()
        logger.info("agent-host listening at \(socketPath) instance=\(hostInstanceID)")
    }

    /// Blocks until shutdown is requested or the idle deadline passes, then runs the shutdown sequence.
    package func run() -> AgentSessionHostExitCode {
        wakeup.lock()
        runLoopActive = true
        while !stopRequested {
            _ = wakeup.wait(until: Date().addingTimeInterval(1))
            if stopRequested { break }
            wakeup.unlock()
            let idleExit = checkIdle()
            wakeup.lock()
            if idleExit {
                logger.info("agent-host idle for \(configuration.idleExitSeconds ?? 0)s; exiting")
                break
            }
        }
        wakeup.unlock()
        stop()
        return .success
    }

    /// Asks `run()` to return; safe from any thread (including signal handlers via dispatch). When no
    /// `run()` loop is active (in-process embedding), the shutdown sequence runs on its own thread.
    package func requestShutdown(reason: String) {
        logger.info("agent-host shutdown requested: \(reason)")
        wakeup.lock()
        let firstRequest = !stopRequested
        stopRequested = true
        let loopActive = runLoopActive
        wakeup.broadcast()
        wakeup.unlock()
        if firstRequest, !loopActive {
            let thread = Thread { [self] in stop() }
            thread.name = "agent-host.stop"
            thread.start()
        }
    }

    /// Full shutdown sequence (design §7.3): stop accepting, notify clients, terminate executors,
    /// checkpoint and close logs, close connections, unlink socket, release lease. Idempotent.
    package func stop() {
        let shouldStop: Bool = stateLock.withLock {
            guard started, !stopping, !stopped else { return false }
            stopping = true
            return true
        }
        guard shouldStop else { return }
        wakeup.lock()
        stopRequested = true
        wakeup.broadcast()
        wakeup.unlock()

        listener?.close()
        if let acceptThread, acceptThread != Thread.current {
            while !acceptThread.isFinished {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        router.broadcast(notice: AgentHostHostNoticeV1(
            kind: .shuttingDown,
            detail: "host is shutting down",
            deadlineAt: AgentSessionHostClock.rfc3339(Date().addingTimeInterval(1)),
            sessionId: ""
        ))
        router.shutdown()
        let open = stateLock.withLock { Array(connections.values) }
        for connection in open {
            connection.finish()
        }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, stateLock.withLock({ !connections.isEmpty }) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        for connection in open {
            connection.close()
        }
        lease?.release()
        lease = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        stateLock.withLock { stopped = true }
        logger.info("agent-host stopped")
    }

    /// True when the idle deadline has been reached.
    private func checkIdle() -> Bool {
        guard let idleSeconds = configuration.idleExitSeconds else { return false }
        let idle = router.isIdle && stateLock.withLock { connections.isEmpty }
        let now = Date()
        return stateLock.withLock {
            if !idle {
                idleSince = nil
                return false
            }
            if idleSince == nil { idleSince = now }
            return now.timeIntervalSince(idleSince ?? now) >= idleSeconds
        }
    }

    // MARK: Accept loop

    private func acceptLoop() {
        guard let listener else { return }
        while true {
            do {
                guard let descriptor = try listener.accept(timeout: configuration.acceptPollInterval) else {
                    if stateLock.withLock({ stopping || stopped }) { return }
                    continue
                }
                let transport = AgentSessionHostFrameTransport(descriptor: descriptor, codec: codec, limits: limits)
                let connection = Connection(server: self, transport: transport)
                stateLock.withLock { connections[connection.id] = connection }
                connection.start()
            } catch {
                if case AgentSessionHostTransportError.closed = error { return }
                logger.warning("agent-host accept failed: \(error)")
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    fileprivate func connectionClosed(_ id: UUID) {
        stateLock.withLock { connections[id] = nil }
    }

    fileprivate func performControlEffect(_ effect: AgentSessionHostControlEffect) {
        switch effect {
        case let .shutdown(mode, _):
            requestShutdown(reason: "shutdown command (\(mode))")
        }
    }

    // MARK: Connection

    /// One client connection: reader thread (handshake, then commands into the router) and writer
    /// thread draining the bounded outbound queue.
    private final class Connection: @unchecked Sendable {
        let id = UUID()
        private weak var server: AgentSessionHostServer?
        private let transport: AgentSessionHostFrameTransport
        private let outbound: AgentSessionHostOutboundQueue
        private let lock = NSLock()
        private var routerID: AgentSessionHostConnectionID?
        private var closed = false

        init(server: AgentSessionHostServer, transport: AgentSessionHostFrameTransport) {
            self.server = server
            self.transport = transport
            outbound = AgentSessionHostOutboundQueue(limits: server.configuration.outboundLimits)
        }

        func start() {
            let reader = Thread { [self] in readLoop() }
            reader.name = "agent-host.connection.read"
            reader.start()
            let writer = Thread { [self] in writeLoop() }
            writer.name = "agent-host.connection.write"
            writer.start()
        }

        /// Queue a final drain then close.
        func finish() {
            outbound.finish()
        }

        func close() {
            let firstClose: Bool = lock.withLock {
                guard !closed else { return false }
                closed = true
                return true
            }
            guard firstClose else { return }
            transport.close()
            outbound.close()
            if let routerID {
                server?.router.unregister(connection: routerID)
            }
            server?.connectionClosed(id)
        }

        private func readLoop() {
            var closeAfterRead = true
            defer {
                if closeAfterRead { close() }
            }
            guard let server else { return }
            do {
                let first = try transport.readFrame()
                let hello = try server.codec.decodeClientMessage(frame: first)
                guard case let .hello(helloBody) = hello.body else {
                    reject(.malformedHello, detail: "first frame must be Hello")
                    // Writer drains HandshakeRejected, then close()s.
                    closeAfterRead = false
                    return
                }
                guard handshake(helloBody, server: server) else {
                    closeAfterRead = false
                    return
                }
                while true {
                    let frame = try transport.readFrame()
                    let message = try server.codec.decodeClientMessage(frame: frame)
                    switch message.body {
                    case let .command(request):
                        guard let routerID else { return }
                        if let effect = server.router.handle(request, from: routerID) {
                            server.performControlEffect(effect)
                        }
                    case .hello:
                        server.logger.warning("agent-host: duplicate Hello on connection \(id); closing")
                        return
                    case nil:
                        return
                    }
                }
            } catch {
                switch error {
                case AgentSessionHostTransportError.closed:
                    break
                case CoreBridgeError.agentHostFrameTooLarge:
                    server.logger.warning("agent-host: frame over limit on connection \(id); closing")
                default:
                    server.logger.debug("agent-host: connection \(id) read ended: \(error)")
                }
            }
        }

        private func handshake(_ hello: AgentHostHelloV1, server: AgentSessionHostServer) -> Bool {
            guard hello.protocolVersion == server.limits.protocolVersion else {
                reject(.protocolVersionMismatch, detail: "client protocol \(hello.protocolVersion), host \(server.limits.protocolVersion)")
                return false
            }
            guard hello.buildFingerprint == CoreBuildIdentity.buildFingerprint else {
                reject(.buildFingerprintMismatch, detail: "client core build differs from host core build")
                return false
            }
            if case let .rejected(detail) = server.configuration.peerVerifier.verify(peerProcessID: transport.peerProcessID, hello: hello) {
                reject(.executableIdentityMismatch, detail: detail)
                return false
            }
            guard hello.capabilities.contains(.snapshotStreaming) else {
                reject(.missingCapability, detail: "snapshotStreaming is required")
                return false
            }
            guard !server.stateLock.withLock({ server.stopping || server.stopped }) else {
                reject(.hostShuttingDown, detail: "host is shutting down")
                return false
            }
            guard let routerID = server.router.register(outbound: outbound, capabilities: hello.capabilities) else {
                reject(.tooManyClients, detail: "client limit \(server.configuration.maximumClients) reached")
                return false
            }
            lock.withLock { self.routerID = routerID }
            let welcome = AgentHostWelcomeV1(
                protocolVersion: server.limits.protocolVersion,
                buildFingerprint: CoreBuildIdentity.buildFingerprint,
                executable: AgentSessionHostExecutableIdentity.current(),
                capabilities: server.configuration.capabilities,
                hostInstanceId: server.hostInstanceID,
                clientId: hello.clientId,
                maximumFrameBytes: server.limits.maximumFrameBytes,
                maximumSnapshotChunkBytes: server.limits.maximumSnapshotChunkBytes,
                hostStartedAt: server.hostStartedAt
            )
            enqueue(.welcome(welcome))
            return true
        }

        private func reject(_ reason: AgentHostHandshakeRejectReasonV1, detail: String) {
            guard let server else { return }
            enqueue(.handshakeRejected(AgentHostHandshakeRejectedV1(
                reason: reason,
                detail: detail,
                hostProtocolVersion: server.limits.protocolVersion,
                hostBuildFingerprint: CoreBuildIdentity.buildFingerprint
            )))
            outbound.finish()
            // Do not close here: writeLoop drains the reject frame, then close()s.
        }

        private func enqueue(_ body: AgentHostHostMessageBodyV1) {
            guard let server else { return }
            do {
                try outbound.enqueueControl(server.codec.encodeHostMessage(AgentHostHostMessageV1(body: body)))
            } catch {
                server.logger.error("agent-host: encode failed on connection \(id): \(error)")
            }
        }

        private func writeLoop() {
            defer { close() }
            while let frame = outbound.dequeue() {
                do {
                    try transport.writeFrame(frame)
                } catch {
                    return
                }
            }
            // Finished draining: give the peer a moment to read the tail before the socket closes.
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
