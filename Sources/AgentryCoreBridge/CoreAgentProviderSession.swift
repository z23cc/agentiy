import AgentryUniFFIRaw
import Foundation
import os

// P7-1 provider transport authority facade. Rust owns Codex JSON-RPC correlation, pending
// requests, timeout/error classification, lifecycle state, process lifetime, framing, serialized
// writes, and sequence assignment. Swift retains only provider-facing decoding and policy/UI
// adaptation; ACP uses the same Rust-owned JSON-RPC reducer and Claude uses the Rust stream
// translator.

public struct CoreAcpControlReceipt: Sendable, Equatable {
    public let outboundSequence: UInt64
    public let lifecycle: String
    public let sessionGeneration: UInt64
    public let promptGeneration: UInt64?

    public init(
        outboundSequence: UInt64,
        lifecycle: String,
        sessionGeneration: UInt64,
        promptGeneration: UInt64?
    ) {
        self.outboundSequence = outboundSequence
        self.lifecycle = lifecycle
        self.sessionGeneration = sessionGeneration
        self.promptGeneration = promptGeneration
    }
}

public struct CoreAcpResponse: Sendable, Equatable {
    public let result: Data
    public let inboundSequence: UInt64
    public let outboundSequence: UInt64
    public let lifecycle: String
    public let sessionGeneration: UInt64
    public let promptGeneration: UInt64?

    public init(
        result: Data,
        inboundSequence: UInt64,
        outboundSequence: UInt64 = 0,
        lifecycle: String = "unknown",
        sessionGeneration: UInt64 = 0,
        promptGeneration: UInt64? = nil
    ) {
        self.result = result
        self.inboundSequence = inboundSequence
        self.outboundSequence = outboundSequence
        self.lifecycle = lifecycle
        self.sessionGeneration = sessionGeneration
        self.promptGeneration = promptGeneration
    }
}

public struct CoreAcpSessionState: Sendable, Equatable {
    public let lifecycle: String
    public let initialized: Bool
    public let authenticated: Bool
    public let sessionID: String?
    public let sessionGeneration: UInt64
    public let promptGeneration: UInt64
    public let activePromptGeneration: UInt64?
    public let pendingRequestCount: UInt64

    public init(
        lifecycle: String,
        initialized: Bool,
        authenticated: Bool = false,
        sessionID: String? = nil,
        sessionGeneration: UInt64 = 0,
        promptGeneration: UInt64 = 0,
        activePromptGeneration: UInt64? = nil,
        pendingRequestCount: UInt64
    ) {
        self.lifecycle = lifecycle
        self.initialized = initialized
        self.authenticated = authenticated
        self.sessionID = sessionID
        self.sessionGeneration = sessionGeneration
        self.promptGeneration = promptGeneration
        self.activePromptGeneration = activePromptGeneration
        self.pendingRequestCount = pendingRequestCount
    }
}

public struct CoreCodexSessionState: Sendable, Equatable {
    public let lifecycle: String
    public let initialized: Bool
    public let threadID: String?
    public let turnID: String?
    public let pendingRequestCount: UInt64

    public init(lifecycle: String, initialized: Bool, threadID: String?, turnID: String?, pendingRequestCount: UInt64) {
        self.lifecycle = lifecycle
        self.initialized = initialized
        self.threadID = threadID
        self.turnID = turnID
        self.pendingRequestCount = pendingRequestCount
    }
}

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

    func agentProviderCodexRequest(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        method: String,
        params: Data?,
        timeoutMilliseconds: UInt64?,
        cancellationToken: String?
    ) throws -> Data {
        throw CoreTransportError.unexpected("codex app-server semantic transport is unavailable")
    }

    func agentProviderCodexCancel(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        cancellationToken: String
    ) throws -> Bool {
        throw CoreTransportError.unexpected("codex app-server semantic transport is unavailable")
    }

    func agentProviderCodexNotify(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        method: String,
        params: Data?
    ) throws -> UInt64 {
        throw CoreTransportError.unexpected("codex app-server semantic transport is unavailable")
    }

    func agentProviderCodexRespond(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        requestID: Data,
        result: Data
    ) throws -> UInt64 {
        throw CoreTransportError.unexpected("codex app-server semantic transport is unavailable")
    }

    func agentProviderCodexRespondError(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        requestID: Data,
        code: Int64,
        message: String,
        data: Data?
    ) throws -> UInt64 {
        throw CoreTransportError.unexpected("codex app-server semantic transport is unavailable")
    }

    func agentProviderCodexState(
        identity: CoreRuntimeIdentity,
        scopeID: String
    ) throws -> AgentryUniFFIRaw.CoreCodexSessionStateV1 {
        throw CoreTransportError.unexpected("codex app-server semantic transport is unavailable")
    }

    func agentProviderAcpRequest(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        method: String,
        params: Data?,
        timeoutMilliseconds: UInt64?,
        cancellationToken: String?
    ) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpResponseV1 {
        throw CoreTransportError.unexpected("acp semantic transport is unavailable")
    }

    func agentProviderAcpCancel(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        cancellationToken: String
    ) throws -> Bool {
        throw CoreTransportError.unexpected("acp semantic transport is unavailable")
    }

    func agentProviderAcpNotify(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        method: String,
        params: Data?,
        expectedSessionGeneration: UInt64?
    ) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpControlReceiptV1 {
        throw CoreTransportError.unexpected("acp semantic transport is unavailable")
    }

    func agentProviderAcpRespond(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        requestID: Data,
        result: Data
    ) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpControlReceiptV1 {
        throw CoreTransportError.unexpected("acp semantic transport is unavailable")
    }

    func agentProviderAcpRespondError(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        requestID: Data,
        code: Int64,
        message: String,
        data: Data?
    ) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpControlReceiptV1 {
        throw CoreTransportError.unexpected("acp semantic transport is unavailable")
    }

    func agentProviderAcpState(
        identity: CoreRuntimeIdentity,
        scopeID: String
    ) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpSessionStateV1 {
        throw CoreTransportError.unexpected("acp semantic transport is unavailable")
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

    func agentProviderCodexRequest(scopeID: String, method: String, params: Data?, timeoutMilliseconds: UInt64?, cancellationToken: String?) async throws -> Data {
        let identity = try requireIdentity()
        let transport = transport
        do {
            return try await Task.detached(priority: .userInitiated) {
                try transport.agentProviderCodexRequest(
                    identity: identity,
                    scopeID: scopeID,
                    method: method,
                    params: params,
                    timeoutMilliseconds: timeoutMilliseconds,
                    cancellationToken: cancellationToken
                )
            }.value
        } catch {
            throw mapTransportError(error)
        }
    }

    @discardableResult
    func agentProviderCodexCancel(scopeID: String, cancellationToken: String) async throws -> Bool {
        let identity = try requireIdentity()
        do { return try transport.agentProviderCodexCancel(identity: identity, scopeID: scopeID, cancellationToken: cancellationToken) }
        catch { throw mapTransportError(error) }
    }

    @discardableResult
    func agentProviderCodexNotify(scopeID: String, method: String, params: Data?) async throws -> UInt64 {
        let identity = try requireIdentity()
        do { return try transport.agentProviderCodexNotify(identity: identity, scopeID: scopeID, method: method, params: params) }
        catch { throw mapTransportError(error) }
    }

    @discardableResult
    func agentProviderCodexRespond(scopeID: String, requestID: Data, result: Data) async throws -> UInt64 {
        let identity = try requireIdentity()
        do { return try transport.agentProviderCodexRespond(identity: identity, scopeID: scopeID, requestID: requestID, result: result) }
        catch { throw mapTransportError(error) }
    }

    @discardableResult
    func agentProviderCodexRespondError(scopeID: String, requestID: Data, code: Int64, message: String, data: Data?) async throws -> UInt64 {
        let identity = try requireIdentity()
        do { return try transport.agentProviderCodexRespondError(identity: identity, scopeID: scopeID, requestID: requestID, code: code, message: message, data: data) }
        catch { throw mapTransportError(error) }
    }

    func agentProviderCodexState(scopeID: String) async throws -> AgentryUniFFIRaw.CoreCodexSessionStateV1 {
        let identity = try requireIdentity()
        do { return try transport.agentProviderCodexState(identity: identity, scopeID: scopeID) }
        catch { throw mapTransportError(error) }
    }

    func agentProviderAcpRequest(scopeID: String, method: String, params: Data?, timeoutMilliseconds: UInt64?, cancellationToken: String?) async throws -> CoreAcpResponse {
        let identity = try requireIdentity()
        let transport = transport
        do {
            let response = try await Task.detached(priority: .userInitiated) {
                try transport.agentProviderAcpRequest(
                    identity: identity,
                    scopeID: scopeID,
                    method: method,
                    params: params,
                    timeoutMilliseconds: timeoutMilliseconds,
                    cancellationToken: cancellationToken
                )
            }.value
            return CoreAcpResponse(
                result: response.result,
                inboundSequence: response.inboundSequence,
                outboundSequence: response.outboundSequence,
                lifecycle: response.lifecycle,
                sessionGeneration: response.sessionGeneration,
                promptGeneration: response.promptGeneration
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    @discardableResult
    func agentProviderAcpCancel(scopeID: String, cancellationToken: String) async throws -> Bool {
        let identity = try requireIdentity()
        do { return try transport.agentProviderAcpCancel(identity: identity, scopeID: scopeID, cancellationToken: cancellationToken) }
        catch { throw mapTransportError(error) }
    }

    @discardableResult
    func agentProviderAcpNotify(scopeID: String, method: String, params: Data?, expectedSessionGeneration: UInt64? = nil) async throws -> CoreAcpControlReceipt {
        let identity = try requireIdentity()
        do {
            let receipt = try transport.agentProviderAcpNotify(identity: identity, scopeID: scopeID, method: method, params: params, expectedSessionGeneration: expectedSessionGeneration)
            return CoreAcpControlReceipt(
                outboundSequence: receipt.outboundSequence,
                lifecycle: receipt.lifecycle,
                sessionGeneration: receipt.sessionGeneration,
                promptGeneration: receipt.promptGeneration
            )
        } catch { throw mapTransportError(error) }
    }

    @discardableResult
    func agentProviderAcpRespond(scopeID: String, requestID: Data, result: Data) async throws -> CoreAcpControlReceipt {
        let identity = try requireIdentity()
        do {
            let receipt = try transport.agentProviderAcpRespond(identity: identity, scopeID: scopeID, requestID: requestID, result: result)
            return CoreAcpControlReceipt(
                outboundSequence: receipt.outboundSequence,
                lifecycle: receipt.lifecycle,
                sessionGeneration: receipt.sessionGeneration,
                promptGeneration: receipt.promptGeneration
            )
        } catch { throw mapTransportError(error) }
    }

    @discardableResult
    func agentProviderAcpRespondError(scopeID: String, requestID: Data, code: Int64, message: String, data: Data?) async throws -> CoreAcpControlReceipt {
        let identity = try requireIdentity()
        do {
            let receipt = try transport.agentProviderAcpRespondError(identity: identity, scopeID: scopeID, requestID: requestID, code: code, message: message, data: data)
            return CoreAcpControlReceipt(
                outboundSequence: receipt.outboundSequence,
                lifecycle: receipt.lifecycle,
                sessionGeneration: receipt.sessionGeneration,
                promptGeneration: receipt.promptGeneration
            )
        } catch { throw mapTransportError(error) }
    }

    func agentProviderAcpState(scopeID: String) async throws -> CoreAcpSessionState {
        let identity = try requireIdentity()
        do {
            let state = try transport.agentProviderAcpState(identity: identity, scopeID: scopeID)
            return CoreAcpSessionState(
                lifecycle: state.lifecycle,
                initialized: state.initialized,
                authenticated: state.authenticated,
                sessionID: state.sessionId,
                sessionGeneration: state.sessionGeneration,
                promptGeneration: state.promptGeneration,
                activePromptGeneration: state.activePromptGeneration,
                pendingRequestCount: state.pendingRequestCount
            )
        } catch {
            throw mapTransportError(error)
        }
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

    public func codexRequest(
        method: String,
        params: Data?,
        timeoutMilliseconds: UInt64?,
        cancellationToken: String? = nil
    ) async throws -> Data {
        try await bridge.agentProviderCodexRequest(
            scopeID: scopeID,
            method: method,
            params: params,
            timeoutMilliseconds: timeoutMilliseconds,
            cancellationToken: cancellationToken
        )
    }

    @discardableResult
    public func codexCancel(cancellationToken: String) async throws -> Bool {
        try await bridge.agentProviderCodexCancel(scopeID: scopeID, cancellationToken: cancellationToken)
    }

    @discardableResult
    public func codexNotify(method: String, params: Data?) async throws -> UInt64 {
        try await bridge.agentProviderCodexNotify(scopeID: scopeID, method: method, params: params)
    }

    @discardableResult
    public func codexRespond(requestID: Data, result: Data) async throws -> UInt64 {
        try await bridge.agentProviderCodexRespond(scopeID: scopeID, requestID: requestID, result: result)
    }

    @discardableResult
    public func codexRespondError(requestID: Data, code: Int64, message: String, data: Data?) async throws -> UInt64 {
        try await bridge.agentProviderCodexRespondError(scopeID: scopeID, requestID: requestID, code: code, message: message, data: data)
    }

    public func codexState() async throws -> CoreCodexSessionState {
        let state = try await bridge.agentProviderCodexState(scopeID: scopeID)
        return CoreCodexSessionState(
            lifecycle: state.lifecycle,
            initialized: state.initialized,
            threadID: state.threadId,
            turnID: state.turnId,
            pendingRequestCount: state.pendingRequestCount
        )
    }

    public func agentProviderAcpRequest(
        method: String,
        params: Data?,
        timeoutMilliseconds: UInt64?,
        cancellationToken: String? = nil
    ) async throws -> CoreAcpResponse {
        try await bridge.agentProviderAcpRequest(
            scopeID: scopeID,
            method: method,
            params: params,
            timeoutMilliseconds: timeoutMilliseconds,
            cancellationToken: cancellationToken
        )
    }

    @discardableResult
    public func agentProviderAcpCancel(cancellationToken: String) async throws -> Bool {
        try await bridge.agentProviderAcpCancel(scopeID: scopeID, cancellationToken: cancellationToken)
    }

    @discardableResult
    public func agentProviderAcpNotify(method: String, params: Data?, expectedSessionGeneration: UInt64? = nil) async throws -> CoreAcpControlReceipt {
        try await bridge.agentProviderAcpNotify(scopeID: scopeID, method: method, params: params, expectedSessionGeneration: expectedSessionGeneration)
    }

    @discardableResult
    public func agentProviderAcpRespond(requestID: Data, result: Data) async throws -> CoreAcpControlReceipt {
        try await bridge.agentProviderAcpRespond(scopeID: scopeID, requestID: requestID, result: result)
    }

    @discardableResult
    public func agentProviderAcpRespondError(requestID: Data, code: Int64, message: String, data: Data?) async throws -> CoreAcpControlReceipt {
        try await bridge.agentProviderAcpRespondError(scopeID: scopeID, requestID: requestID, code: code, message: message, data: data)
    }

    public func agentProviderAcpState() async throws -> CoreAcpSessionState {
        try await bridge.agentProviderAcpState(scopeID: scopeID)
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
