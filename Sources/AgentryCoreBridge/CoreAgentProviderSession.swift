import AgentryUniFFIRaw
import Foundation
import os

// P6 provider transport authority facade. This is deliberately smaller than CoreAgentSession:
// Codex and ACP keep provider-specific request/response normalization in Swift, while the Claude
// headless variant additionally asks Rust to translate its stream-json payloads. Rust always owns
// process lifetime, framing, serialized writes, and sequence assignment.

public enum CoreAgentProviderProtocol: Sendable {
    case codexAppServer
    case acp
    case claudeHeadless

    var ffiValue: AgentryUniFFIRaw.AgentProviderProtocolV1 {
        switch self {
        case .codexAppServer: .codexAppServer
        case .acp: .acp
        case .claudeHeadless: .claudeHeadless
        }
    }
}

extension CoreRuntimeTransport {
    func agentProviderOpenScope(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreAgentProviderScopeConfigV1
    ) throws -> AgentryUniFFIRaw.AgentProviderScopeHandleV1 {
        throw CoreTransportError.unexpected("agent-provider-v1 transport is unavailable")
    }

    func agentProviderStart(
        identity: CoreRuntimeIdentity,
        scopeID: String
    ) throws -> AgentryUniFFIRaw.AgentProviderStartReceiptV1 {
        throw CoreTransportError.unexpected("agent-provider-v1 transport is unavailable")
    }

    func agentProviderStartWithStdin(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        payload: Data
    ) throws -> AgentryUniFFIRaw.AgentProviderStartReceiptV1 {
        throw CoreTransportError.unexpected("agent-provider-v1 transport is unavailable")
    }

    func agentProviderSendLine(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        payload: Data
    ) throws -> UInt64 {
        throw CoreTransportError.unexpected("agent-provider-v1 transport is unavailable")
    }

    func agentProviderShutdown(identity: CoreRuntimeIdentity, scopeID: String) throws {
        throw CoreTransportError.unexpected("agent-provider-v1 transport is unavailable")
    }
}

extension AgentryCoreBridge {
    func agentProviderOpenScope(
        config: AgentryUniFFIRaw.CoreAgentProviderScopeConfigV1
    ) throws -> AgentryUniFFIRaw.AgentProviderScopeHandleV1 {
        let identity = try requireIdentity()
        do { return try transport.agentProviderOpenScope(identity: identity, config: config) }
        catch { throw mapTransportError(error) }
    }

    func agentProviderStart(scopeID: String) throws -> AgentryUniFFIRaw.AgentProviderStartReceiptV1 {
        let identity = try requireIdentity()
        do { return try transport.agentProviderStart(identity: identity, scopeID: scopeID) }
        catch { throw mapTransportError(error) }
    }

    func agentProviderStartWithStdin(
        scopeID: String,
        payload: Data
    ) throws -> AgentryUniFFIRaw.AgentProviderStartReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.agentProviderStartWithStdin(
                identity: identity,
                scopeID: scopeID,
                payload: payload
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    @discardableResult
    func agentProviderSendLine(scopeID: String, payload: Data) throws -> UInt64 {
        let identity = try requireIdentity()
        do { return try transport.agentProviderSendLine(identity: identity, scopeID: scopeID, payload: payload) }
        catch { throw mapTransportError(error) }
    }

    func agentProviderShutdown(scopeID: String) throws {
        let identity = try requireIdentity()
        do { try transport.agentProviderShutdown(identity: identity, scopeID: scopeID) }
        catch { throw mapTransportError(error) }
    }
}

public struct CoreAgentProviderEvent: @unchecked Sendable {
    public let kind: String
    public let provider: String
    public let sequence: UInt64
    public let payload: Any

    public init(kind: String, provider: String, sequence: UInt64, payload: Any) {
        self.kind = kind
        self.provider = provider
        self.sequence = sequence
        self.payload = payload
    }

    public var payloadDictionary: [String: Any]? { payload as? [String: Any] }
}

public struct CoreAgentProviderEventStream: AsyncSequence, Sendable {
    public typealias Element = CoreAgentProviderEvent
    private let events: CoreEventStream
    private let bridge: AgentryCoreBridge
    private let subscription: CoreSubscription

    init(bridge: AgentryCoreBridge, subscription: CoreSubscription) {
        events = subscription.events
        self.bridge = bridge
        self.subscription = subscription
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(inner: events.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var inner: AsyncThrowingStream<CoreEvent, Error>.Iterator

        public mutating func next() async throws -> CoreAgentProviderEvent? {
            while let event = try await inner.next() {
                let data: Data
                switch event.payload {
                case let .utf8(raw):
                    guard let utf8 = raw.data(using: .utf8) else { continue }
                    data = utf8
                case let .bytes(bytes):
                    data = bytes
                default:
                    continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = object["kind"] as? String,
                      let provider = object["provider"] as? String,
                      let sequence = (object["sequence"] as? NSNumber)?.uint64Value
                else { continue }
                return CoreAgentProviderEvent(
                    kind: kind,
                    provider: provider,
                    sequence: sequence,
                    payload: object["payload"] ?? NSNull()
                )
            }
            return nil
        }
    }

    public func close() async throws { try await bridge.closeSubscription(subscription) }
}

public final class CoreAgentProviderSession: @unchecked Sendable {
    private let bridge: AgentryCoreBridge
    public let scopeID: String
    public let subscriptionScopeID: String
    private let closedFlag = OSAllocatedUnfairLock(initialState: false)
    private let subscriptionLock = OSAllocatedUnfairLock<CoreSubscription?>(initialState: nil)

    private init(bridge: AgentryCoreBridge, scopeID: String, subscriptionScopeID: String) {
        self.bridge = bridge
        self.scopeID = scopeID
        self.subscriptionScopeID = subscriptionScopeID
    }

    public static func open(
        bridge: AgentryCoreBridge,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        protocolKind: CoreAgentProviderProtocol,
        maxStderrBytes: UInt64 = 8_192
    ) async throws -> CoreAgentProviderSession {
        let handle = try await bridge.agentProviderOpenScope(config: .init(
            command: command,
            arguments: arguments,
            environment: environment.map { AgentryUniFFIRaw.CoreAgentProviderEnvironmentEntryV1(key: $0.key, value: $0.value) },
            workingDirectory: workingDirectory,
            protocol: protocolKind.ffiValue,
            maxStderrBytes: maxStderrBytes
        ))
        return CoreAgentProviderSession(bridge: bridge, scopeID: handle.scopeId, subscriptionScopeID: handle.subscriptionScopeId)
    }

    public func start() async throws -> CoreAgentStartReceipt {
        let receipt = try await bridge.agentProviderStart(scopeID: scopeID)
        return CoreAgentStartReceipt(pid: receipt.pid, processGroupID: receipt.processGroupId)
    }

    /// Claude Code headless `-p` startup. Rust writes the complete prompt and
    /// closes stdin as one authority operation, preventing a Swift writer from
    /// racing EOF or leaving the child waiting forever for more input.
    public func startWithStdin(_ payload: Data) async throws -> CoreAgentStartReceipt {
        let receipt = try await bridge.agentProviderStartWithStdin(scopeID: scopeID, payload: payload)
        return CoreAgentStartReceipt(pid: receipt.pid, processGroupID: receipt.processGroupId)
    }

    @discardableResult
    public func sendLine(_ payload: Data) async throws -> UInt64 {
        try await bridge.agentProviderSendLine(scopeID: scopeID, payload: payload)
    }

    public func events(maxQueuedEvents: UInt64 = 256, maxQueuedBytes: UInt64 = 1_048_576) async throws -> CoreAgentProviderEventStream {
        let scope = try CoreScopeID(rawValue: subscriptionScopeID)
        let subscription = try await bridge.openSubscription(scopeID: scope, maxQueuedEvents: maxQueuedEvents, maxQueuedBytes: maxQueuedBytes)
        subscriptionLock.withLock { $0 = subscription }
        return CoreAgentProviderEventStream(bridge: bridge, subscription: subscription)
    }

    public func shutdown() async {
        guard closedFlag.withLock({ state in
            guard !state else { return false }
            state = true
            return true
        }) else { return }
        let subscription = subscriptionLock.withLock { value in
            defer { value = nil }
            return value
        }
        if let subscription {
            try? await bridge.closeSubscription(subscription)
        }
        try? await bridge.agentProviderShutdown(scopeID: scopeID)
    }

    deinit {
        let shouldClose = closedFlag.withLock { state in
            guard !state else { return false }
            state = true
            return true
        }
        guard shouldClose else { return }
        let bridge = bridge
        let scopeID = scopeID
        let subscription = subscriptionLock.withLock { value in
            defer { value = nil }
            return value
        }
        Task {
            if let subscription {
                try? await bridge.closeSubscription(subscription)
            }
            try? await bridge.agentProviderShutdown(scopeID: scopeID)
        }
    }
}
