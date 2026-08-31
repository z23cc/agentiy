import Darwin
import Foundation
import Logging
import MCP
import RepoPromptDomainRuntime

actor DirectHeadlessChildEndpoint {
    struct Handshake: Codable {
        let launchToken: String
        let clientPrincipal: String
        let providerIdentifier: String
        let runID: UUID
        let endpointIdentity: String?

        init(
            launchToken: String,
            clientPrincipal: String,
            providerIdentifier: String,
            runID: UUID,
            endpointIdentity: String? = nil
        ) {
            self.launchToken = launchToken
            self.clientPrincipal = clientPrincipal
            self.providerIdentifier = providerIdentifier
            self.runID = runID
            self.endpointIdentity = endpointIdentity
        }
    }

    struct Descriptor: Equatable {
        let socketPath: String
        let socketIdentity: String
        let ownerProcessID: Int32
    }

    enum EndpointError: Error, Equatable {
        case pathTooLong
        case socket(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case invalidDirectory
        case untrustedPeer
        case endpointIdentityMismatch
        case handshakeTimeout
        case handshakeTooLarge
        case handshakeRead(errno: Int32)
        case invalidHandshake
    }

    typealias ClientHandler = @Sendable (
        _ fd: Int32,
        _ observedPeerPID: Int32?,
        _ handshake: Handshake
    ) async -> Void

    private struct ClientTask {
        let fd: Int32
        let task: Task<Void, Never>
    }

    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    nonisolated let socketURL: URL
    nonisolated let ownerProcessID: Int32
    private let directoryURL: URL
    private let logger: Logger
    private var listenFD: Int32 = -1
    private var socketIdentity: SocketIdentity?
    private var directoryIdentity: SocketIdentity?
    private var acceptTask: Task<Void, Never>?
    private var clientTasks: [UUID: ClientTask] = [:]

    init(directory: URL, logger: Logger) {
        directoryURL = directory
        socketURL = directory.appendingPathComponent("c-\(UUID().uuidString.prefix(12)).sock", isDirectory: false)
        ownerProcessID = getpid()
        self.logger = logger
    }

    func descriptor() -> Descriptor? {
        guard let socketIdentity else { return nil }
        return Descriptor(
            socketPath: socketURL.path,
            socketIdentity: Self.identityDescription(socketIdentity),
            ownerProcessID: ownerProcessID
        )
    }

    func start(handler: @escaping ClientHandler) throws {
        guard listenFD < 0 else { return }
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard Self.privateDirectoryIsTrusted(at: directory.path),
              let directoryIdentity = Self.identity(at: directory.path)
        else {
            throw EndpointError.invalidDirectory
        }
        self.directoryIdentity = directoryIdentity

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            cleanupDirectoryIfOwned()
            throw EndpointError.socket(errno: errno)
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketURL.path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            cleanupDirectoryIfOwned()
            throw EndpointError.pathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = byte
                }
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            cleanupDirectoryIfOwned()
            throw EndpointError.bind(errno: code)
        }
        guard chmod(socketURL.path, 0o600) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(socketURL.path)
            cleanupDirectoryIfOwned()
            throw EndpointError.bind(errno: code)
        }
        guard Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(socketURL.path)
            cleanupDirectoryIfOwned()
            throw EndpointError.listen(errno: code)
        }
        guard let socketIdentity = Self.identity(at: socketURL.path),
              Self.privateSocketIsTrusted(at: socketURL.path)
        else {
            Darwin.close(fd)
            unlink(socketURL.path)
            cleanupDirectoryIfOwned()
            throw EndpointError.bind(errno: EACCES)
        }
        listenFD = fd
        self.socketIdentity = socketIdentity
        acceptTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await Self.acceptLoop(endpoint: self, fd: fd, handler: handler)
        }
    }

    func stop(timeout: Duration = .seconds(5)) async {
        let listener = listenFD
        listenFD = -1
        if listener >= 0 {
            Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        acceptTask?.cancel()
        let accept = acceptTask
        acceptTask = nil
        let clients = Array(clientTasks.values)
        for client in clients {
            Darwin.shutdown(client.fd, SHUT_RDWR)
            client.task.cancel()
        }
        await accept?.value
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !clientTasks.isEmpty, ContinuousClock().now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !clientTasks.isEmpty {
            logger.warning("Private child endpoint stop timed out", metadata: ["remaining_clients": "\(clientTasks.count)"])
            clientTasks.removeAll()
        }
        if socketIdentity == Self.identity(at: socketURL.path) {
            unlink(socketURL.path)
        }
        socketIdentity = nil
        if directoryIdentity == Self.identity(at: directoryURL.path),
           (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path).isEmpty) == true
        {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        directoryIdentity = nil
    }

    private nonisolated static func acceptLoop(
        endpoint: DirectHeadlessChildEndpoint,
        fd: Int32,
        handler: @escaping ClientHandler
    ) async {
        while !Task.isCancelled {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0)
            let polled = Darwin.poll(&descriptor, 1, 100)
            if polled == 0 { continue }
            if polled < 0 {
                if errno == EINTR { continue }
                return
            }
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(fd, $0, &length)
                }
            }
            if clientFD < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            await endpoint.acceptClient(fd: clientFD, handler: handler)
        }
    }

    private func acceptClient(fd: Int32, handler: @escaping ClientHandler) {
        let id = UUID()
        let logger = logger
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let endpoint = self else {
                Darwin.close(fd)
                return
            }
            defer { Darwin.close(fd) }
            do {
                let handshake = try Self.readHandshake(fd: fd)
                let currentSocketIdentity = await endpoint.socketIdentitySnapshot()
                let expectedEndpointIdentity = Self.identityDescription(currentSocketIdentity)
                guard let endpointIdentity = handshake.endpointIdentity,
                      endpointIdentity == expectedEndpointIdentity
                else {
                    throw EndpointError.endpointIdentityMismatch
                }
                let peerPID = Self.peerPID(fd: fd)
                let ownerProcessID = await endpoint.ownerProcessIDSnapshot()
                guard let peerPID, Self.isDescendant(peerPID, of: ownerProcessID) else {
                    throw EndpointError.untrustedPeer
                }
                await handler(fd, peerPID, handshake)
            } catch {
                logger.warning("Rejected private child endpoint connection", metadata: ["error": "\(error)"])
            }
            await endpoint.clientFinished(id)
        }
        clientTasks[id] = ClientTask(fd: fd, task: task)
    }

    private func clientFinished(_ id: UUID) {
        clientTasks.removeValue(forKey: id)
    }

    private func cleanupDirectoryIfOwned() {
        guard let directoryIdentity,
              directoryIdentity == Self.identity(at: directoryURL.path),
              (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path).isEmpty) == true
        else { return }
        try? FileManager.default.removeItem(at: directoryURL)
        self.directoryIdentity = nil
    }

    private func socketIdentitySnapshot() -> SocketIdentity? {
        socketIdentity
    }

    private func ownerProcessIDSnapshot() -> Int32 {
        ownerProcessID
    }

    private nonisolated static func readHandshake(fd: Int32) throws -> Handshake {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while ContinuousClock().now < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0)
            let polled = Darwin.poll(&descriptor, 1, 100)
            if polled == 0 { continue }
            if polled < 0 {
                if errno == EINTR { continue }
                throw EndpointError.handshakeRead(errno: errno)
            }
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { throw EndpointError.invalidHandshake }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw EndpointError.handshakeRead(errno: errno)
            }
            if byte == 0x0A {
                guard let handshake = try? JSONDecoder().decode(Handshake.self, from: Data(bytes)) else {
                    throw EndpointError.invalidHandshake
                }
                return handshake
            }
            bytes.append(byte)
            if bytes.count > 16 * 1024 { throw EndpointError.handshakeTooLarge }
        }
        throw EndpointError.handshakeTimeout
    }

    private nonisolated static func peerPID(fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    private nonisolated static func privateDirectoryIsTrusted(at path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o077) == 0
        else { return false }
        return true
    }

    private nonisolated static func privateSocketIsTrusted(at path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFSOCK,
              (info.st_mode & 0o077) == 0
        else { return false }
        return true
    }

    private nonisolated static func identityDescription(_ identity: SocketIdentity) -> String {
        "\(UInt64(identity.device)):\(UInt64(identity.inode))"
    }

    private nonisolated static func identityDescription(_ identity: SocketIdentity?) -> String? {
        identity.map(identityDescription)
    }

    private nonisolated static func isDescendant(_ pid: Int32, of ownerPID: Int32) -> Bool {
        guard pid > 0, ownerPID > 0 else { return false }
        if pid == ownerPID { return true }
        var current = pid_t(pid)
        for _ in 0 ..< 32 {
            guard let parent = parentPID(of: current), parent > 1, parent != current else {
                return false
            }
            if parent == pid_t(ownerPID) { return true }
            current = parent
        }
        return false
    }

    private nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout.stride(ofValue: info)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info.kp_eproc.e_ppid
    }

    private nonisolated static func identity(at path: String) -> SocketIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return SocketIdentity(device: info.st_dev, inode: info.st_ino)
    }
}

actor DirectHeadlessChildLaunchCoordinator {
    enum CoordinatorError: Error {
        case unavailable
        case missingRoutingContext
    }

    private var runtime: MCPDomainRuntime?
    private var authority: DomainChildLaunchAuthority?

    func configure(
        runtime: MCPDomainRuntime,
        endpointDescriptor: String,
        endpointIdentity: String
    ) {
        self.runtime = runtime
        authority = DomainChildLaunchAuthority(
            endpointDescriptor: endpointDescriptor,
            endpointIdentity: endpointIdentity,
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            credentialStore: runtime.credentialEnvelopeStore,
            issueLaunchToken: { request in
                try await runtime.routingCoordinator.issueLaunchToken(request)
            },
            revokeLaunchToken: { tokenID in
                await runtime.routingCoordinator.revokeLaunchToken(tokenID)
            }
        )
    }

    func prepare(
        toolName: String,
        arguments: [String: MCP.Value],
        securityContext: DomainToolInvocationSecurityContext
    ) async throws -> DomainChildLaunchCarrier? {
        guard let runtime, let authority else { throw CoordinatorError.unavailable }
        let registration = try await runtime.routingCoordinator.currentRegistration(
            connectionID: securityContext.connectionID
        )
        let handle = try await runtime.routingCoordinator.resolveReadContext(connection: registration)
        let provider = arguments["provider"]?.stringValue
            ?? arguments["model_id"]?.stringValue
            ?? "headless"
        let runID = Self.resolvedRunID(
            toolName: toolName,
            arguments: arguments,
            securityContext: securityContext
        )
        let request = DomainRunLaunchReservationRequest(
            runID: runID,
            context: handle.context,
            expectedContextRevision: handle.contextRevision,
            windowID: nil,
            clientPrincipal: securityContext.principal.stableKey ?? securityContext.principal.displayName,
            providerIdentifier: provider,
            runPurpose: toolName,
            additionalTools: Set(arguments["additional_tools"]?.arrayValue?.compactMap(\.stringValue) ?? []),
            expectedProcessID: nil,
            lifetime: .seconds(60)
        )
        return try await authority.prepare(request: request)
    }

    nonisolated static func resolvedRunID(
        toolName: String,
        arguments: [String: MCP.Value],
        securityContext: DomainToolInvocationSecurityContext
    ) -> UUID {
        let operation = arguments["op"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let createsSession = (toolName == "agent_run" && (operation ?? "start") == "start")
            || (toolName == "agent_explore" && operation == "start")
        if createsSession { return UUID() }
        return securityContext.principal.runID ?? UUID()
    }
}
