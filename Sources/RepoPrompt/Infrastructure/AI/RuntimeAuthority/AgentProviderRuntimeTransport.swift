import AgentryCoreBridge
import Foundation

/// Provider transport families whose process lifetime is owned by the Rust runtime authority.
/// Provider controllers remain responsible for protocol meaning and normalized UI events.
enum AgentProviderRuntimeProtocol {
    case codexAppServer
    case acp

    var bridgeValue: CoreAgentProviderProtocol {
        switch self {
        case .codexAppServer: .codexAppServer
        case .acp: .acp
        }
    }
}

protocol AgentProviderRuntimeSession: AnyObject, Sendable {
    var scopeID: String { get }
    func start() async throws -> CoreAgentStartReceipt
    func sendLine(_ payload: Data) async throws -> UInt64
    func events() async throws -> CoreAgentProviderEventStream
    func shutdown() async
}

protocol AgentProviderRuntimeTransport: Sendable {
    func open(
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        protocolKind: AgentProviderRuntimeProtocol,
        maxStderrBytes: UInt64
    ) async throws -> any AgentProviderRuntimeSession
}

/// Production implementation backed by the process-wide AgentryCoreService bridge.
/// Tests can inject a protocol implementation without starting Rust or a child process.
struct CoreAgentProviderRuntimeTransport: AgentProviderRuntimeTransport {
    let bridgeProvider: @Sendable () async throws -> AgentryCoreBridge

    init(bridgeProvider: @escaping @Sendable () async throws -> AgentryCoreBridge = {
        guard let bridge = try await AgentryCoreService.shared.runtime() as? AgentryCoreBridge else {
            throw CoreBridgeError.transportFailure("AgentryCoreBridge runtime is unavailable")
        }
        return bridge
    }) {
        self.bridgeProvider = bridgeProvider
    }

    func open(
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        protocolKind: AgentProviderRuntimeProtocol,
        maxStderrBytes: UInt64
    ) async throws -> any AgentProviderRuntimeSession {
        let bridge = try await bridgeProvider()
        let session = try await CoreAgentProviderSession.open(
            bridge: bridge,
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            protocolKind: protocolKind.bridgeValue,
            maxStderrBytes: maxStderrBytes
        )
        return CoreAgentProviderRuntimeSessionAdapter(session: session)
    }
}

private final class CoreAgentProviderRuntimeSessionAdapter: AgentProviderRuntimeSession, @unchecked Sendable {
    private let session: CoreAgentProviderSession

    init(session: CoreAgentProviderSession) {
        self.session = session
    }

    var scopeID: String {
        session.scopeID
    }

    func start() async throws -> CoreAgentStartReceipt {
        try await session.start()
    }

    func sendLine(_ payload: Data) async throws -> UInt64 {
        try await session.sendLine(payload)
    }

    func events() async throws -> CoreAgentProviderEventStream {
        try await session.events()
    }

    func shutdown() async {
        await session.shutdown()
    }
}
