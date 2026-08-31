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

/// Capability exposed only by Rust-owned Codex app-server sessions. ACP and legacy
/// injected sessions intentionally do not conform, so production Codex calls cannot
/// silently fall back to Swift request correlation.
protocol CodexAppServerRuntimeSession: AgentProviderRuntimeSession {
    func codexRequest(method: String, params: Data?, timeoutMilliseconds: UInt64?, cancellationToken: String?) async throws -> Data
    func codexCancel(cancellationToken: String) async throws -> Bool
    func codexNotify(method: String, params: Data?) async throws -> UInt64
    func codexRespond(requestID: Data, result: Data) async throws -> UInt64
    func codexRespondError(requestID: Data, code: Int64, message: String, data: Data?) async throws -> UInt64
    func codexState() async throws -> CoreCodexSessionState
}

/// Capability exposed by Rust-owned ACP sessions. ACP controllers retain provider policy and
/// decoding, while request IDs, pending correlation, response validation, and inbound ordering
/// remain in the runtime authority.
protocol AcpRuntimeSession: AgentProviderRuntimeSession {
    func acpRequest(method: String, params: Data?, timeoutMilliseconds: UInt64?, cancellationToken: String?) async throws -> CoreAcpResponse
    func acpCancel(cancellationToken: String) async throws -> Bool
    func acpNotify(method: String, params: Data?, expectedSessionGeneration: UInt64?) async throws -> CoreAcpControlReceipt
    func acpRespond(requestID: Data, result: Data) async throws -> CoreAcpControlReceipt
    func acpRespondError(requestID: Data, code: Int64, message: String, data: Data?) async throws -> CoreAcpControlReceipt
    func acpState() async throws -> CoreAcpSessionState
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
        switch protocolKind {
        case .codexAppServer:
            return CodexAgentProviderRuntimeSessionAdapter(session: session)
        case .acp:
            return AcpAgentProviderRuntimeSessionAdapter(session: session)
        }
    }
}

private class CoreAgentProviderRuntimeSessionAdapter: AgentProviderRuntimeSession, @unchecked Sendable {
    fileprivate let session: CoreAgentProviderSession

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

private final class AcpAgentProviderRuntimeSessionAdapter: CoreAgentProviderRuntimeSessionAdapter, AcpRuntimeSession {
    func acpRequest(method: String, params: Data?, timeoutMilliseconds: UInt64?, cancellationToken: String?) async throws -> CoreAcpResponse {
        try await session.agentProviderAcpRequest(method: method, params: params, timeoutMilliseconds: timeoutMilliseconds, cancellationToken: cancellationToken)
    }

    func acpCancel(cancellationToken: String) async throws -> Bool {
        try await session.agentProviderAcpCancel(cancellationToken: cancellationToken)
    }

    func acpNotify(method: String, params: Data?, expectedSessionGeneration: UInt64?) async throws -> CoreAcpControlReceipt {
        try await session.agentProviderAcpNotify(method: method, params: params, expectedSessionGeneration: expectedSessionGeneration)
    }

    func acpRespond(requestID: Data, result: Data) async throws -> CoreAcpControlReceipt {
        try await session.agentProviderAcpRespond(requestID: requestID, result: result)
    }

    func acpRespondError(requestID: Data, code: Int64, message: String, data: Data?) async throws -> CoreAcpControlReceipt {
        try await session.agentProviderAcpRespondError(requestID: requestID, code: code, message: message, data: data)
    }

    func acpState() async throws -> CoreAcpSessionState {
        try await session.agentProviderAcpState()
    }
}

private final class CodexAgentProviderRuntimeSessionAdapter: CoreAgentProviderRuntimeSessionAdapter, CodexAppServerRuntimeSession {
    func codexRequest(method: String, params: Data?, timeoutMilliseconds: UInt64?, cancellationToken: String?) async throws -> Data {
        try await session.codexRequest(method: method, params: params, timeoutMilliseconds: timeoutMilliseconds, cancellationToken: cancellationToken)
    }

    func codexCancel(cancellationToken: String) async throws -> Bool {
        try await session.codexCancel(cancellationToken: cancellationToken)
    }

    func codexNotify(method: String, params: Data?) async throws -> UInt64 {
        try await session.codexNotify(method: method, params: params)
    }

    func codexRespond(requestID: Data, result: Data) async throws -> UInt64 {
        try await session.codexRespond(requestID: requestID, result: result)
    }

    func codexRespondError(requestID: Data, code: Int64, message: String, data: Data?) async throws -> UInt64 {
        try await session.codexRespondError(requestID: requestID, code: code, message: message, data: data)
    }

    func codexState() async throws -> CoreCodexSessionState {
        try await session.codexState()
    }
}
