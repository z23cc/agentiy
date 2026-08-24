import AgentryUniFFIRaw
import Foundation
import os

// ============================================================================================
// P6-6: `CoreAgentSession` -- the bridge-owned, ARC-driven facade over the Rust `AgentClaudeScope`
// (`docs/architecture/rust-agent-claude-v1.md`, `docs/designs/p6-claude-vertical-2026-08-23.md`
// §11 P6-6). Mirrors `CoreInventoryScope`'s idiom exactly: a transport-protocol extension with
// unavailable-throwing defaults, an `AgentryCoreBridge` extension wrapping `requireIdentity()` +
// `mapTransportError`, and a `final class` facade with `closedFlag` + idempotent `close()` +
// `deinit` backstop. Deliberately NOT scaled to `CoreInventoryScope.swift`'s size -- this domain
// has seven commands, one event stream, and `close()`, not inventory's bulk-load/snapshot/paging/
// query/resolve surface.
// ============================================================================================

extension CoreRuntimeTransport {
    func agentOpenScope(
        identity: CoreRuntimeIdentity, config: AgentryUniFFIRaw.CoreAgentClaudeScopeConfigV1
    ) throws -> AgentryUniFFIRaw.AgentClaudeScopeHandleV1 {
        throw CoreTransportError.unexpected("agent-claude-v1 transport is unavailable")
    }

    func agentStartOrResume(
        identity: CoreRuntimeIdentity, scopeID: String, resumeSessionID: String?
    ) throws -> AgentryUniFFIRaw.AgentClaudeStartReceiptV1 {
        throw CoreTransportError.unexpected("agent-claude-v1 transport is unavailable")
    }

    func agentSendUserMessage(identity: CoreRuntimeIdentity, scopeID: String, text: String) throws -> UInt64 {
        throw CoreTransportError.unexpected("agent-claude-v1 transport is unavailable")
    }

    func agentInterruptTurn(
        identity: CoreRuntimeIdentity, scopeID: String, turnGeneration: UInt64, reason: String
    ) throws -> AgentryUniFFIRaw.AgentClaudeInterruptReceiptV1 {
        throw CoreTransportError.unexpected("agent-claude-v1 transport is unavailable")
    }

    func agentRespondPermission(
        identity: CoreRuntimeIdentity, scopeID: String, requestID: String, decision: AgentryUniFFIRaw.AgentClaudePermissionDecisionV1
    ) throws {
        throw CoreTransportError.unexpected("agent-claude-v1 transport is unavailable")
    }

    func agentApplyModelAndEffort(
        identity: CoreRuntimeIdentity, scopeID: String, model: String?, effort: String?
    ) throws -> AgentryUniFFIRaw.AgentClaudeFlagSettingsReceiptV1 {
        throw CoreTransportError.unexpected("agent-claude-v1 transport is unavailable")
    }

    func agentShutdown(identity: CoreRuntimeIdentity, scopeID: String) throws {
        throw CoreTransportError.unexpected("agent-claude-v1 transport is unavailable")
    }
}

extension AgentryCoreBridge {
    func agentOpenScope(config: AgentryUniFFIRaw.CoreAgentClaudeScopeConfigV1) throws -> AgentryUniFFIRaw.AgentClaudeScopeHandleV1 {
        let identity = try requireIdentity()
        do {
            return try transport.agentOpenScope(identity: identity, config: config)
        } catch {
            throw mapTransportError(error)
        }
    }

    func agentStartOrResume(scopeID: String, resumeSessionID: String?) throws -> AgentryUniFFIRaw.AgentClaudeStartReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.agentStartOrResume(identity: identity, scopeID: scopeID, resumeSessionID: resumeSessionID)
        } catch {
            throw mapTransportError(error)
        }
    }

    func agentSendUserMessage(scopeID: String, text: String) throws -> UInt64 {
        let identity = try requireIdentity()
        do {
            return try transport.agentSendUserMessage(identity: identity, scopeID: scopeID, text: text)
        } catch {
            throw mapTransportError(error)
        }
    }

    func agentInterruptTurn(scopeID: String, turnGeneration: UInt64, reason: String) throws -> AgentryUniFFIRaw.AgentClaudeInterruptReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.agentInterruptTurn(identity: identity, scopeID: scopeID, turnGeneration: turnGeneration, reason: reason)
        } catch {
            throw mapTransportError(error)
        }
    }

    func agentRespondPermission(scopeID: String, requestID: String, decision: AgentryUniFFIRaw.AgentClaudePermissionDecisionV1) throws {
        let identity = try requireIdentity()
        do {
            try transport.agentRespondPermission(identity: identity, scopeID: scopeID, requestID: requestID, decision: decision)
        } catch {
            throw mapTransportError(error)
        }
    }

    func agentApplyModelAndEffort(scopeID: String, model: String?, effort: String?) throws -> AgentryUniFFIRaw.AgentClaudeFlagSettingsReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.agentApplyModelAndEffort(identity: identity, scopeID: scopeID, model: model, effort: effort)
        } catch {
            throw mapTransportError(error)
        }
    }

    func agentShutdown(scopeID: String) throws {
        let identity = try requireIdentity()
        do {
            try transport.agentShutdown(identity: identity, scopeID: scopeID)
        } catch {
            throw mapTransportError(error)
        }
    }
}

// ---- CoreAgentSession: ARC-driven facade over one AgentClaudeScope ---------------------------

public struct CoreAgentSessionConfig: Sendable {
    public var command: String
    public var arguments: [String]
    /// Never logged (design R8) -- the same posture as today's `process.spawned` raw-event record,
    /// which carries `command`/`arguments`/`workingDirectory` and deliberately not `environment`.
    public var environment: [String: String]
    public var workingDirectory: String?
    public var permissionMode: String?
    public var mcpConfigPath: String?
    public var mcpStrictMode: Bool
    public var disallowedBuiltInTools: [String]
    public var appendSystemPrompt: String?
    /// P6-7 (`docs/architecture/rust-agent-claude-v1.md` §15.5): the `initialize` control
    /// request's `systemPrompt` override (contract §2.5) -- sent once during
    /// `CoreAgentSession.startOrResume`'s session-startup handshake. Distinct from
    /// `appendSystemPrompt`'s CLI-argv `--append-system-prompt` mechanism (GLM-only).
    public var systemPromptOverride: String?
    public var idleFallbackMillis: UInt64
    public var interruptAckTimeoutMillis: UInt64

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        permissionMode: String? = nil,
        mcpConfigPath: String? = nil,
        mcpStrictMode: Bool = false,
        disallowedBuiltInTools: [String] = [],
        appendSystemPrompt: String? = nil,
        systemPromptOverride: String? = nil,
        idleFallbackMillis: UInt64 = 1_000,
        interruptAckTimeoutMillis: UInt64 = 1_500
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.permissionMode = permissionMode
        self.mcpConfigPath = mcpConfigPath
        self.mcpStrictMode = mcpStrictMode
        self.disallowedBuiltInTools = disallowedBuiltInTools
        self.appendSystemPrompt = appendSystemPrompt
        self.systemPromptOverride = systemPromptOverride
        self.idleFallbackMillis = idleFallbackMillis
        self.interruptAckTimeoutMillis = interruptAckTimeoutMillis
    }
}

public struct CoreAgentStartReceipt: Sendable, Equatable {
    public let pid: Int32
    public let processGroupID: Int32
}

/// Contract §4: the fast-enqueue receipt for `interruptTurn`. The actual outcome (one of the five
/// contract §5.3 variants: acknowledged/noTurnInFlight/staleGeneration/timedOut/failed) arrives
/// later as an `interruptOutcome` event on the session's event stream, correlated by this same
/// `requestID`.
public struct CoreAgentInterruptReceipt: Sendable, Equatable {
    public let requestID: String
}

/// P6-7: the fast-enqueue receipt for `applyModelAndEffort`. The actual ACK (contract §2.2's
/// applied/timedOut/failed outcomes) arrives later as a `flagSettingsApplied` event on the
/// session's event stream, correlated by this same `requestID` -- mirrors
/// `CoreAgentInterruptReceipt`'s shape and doc comment exactly.
public struct CoreAgentFlagSettingsReceipt: Sendable, Equatable {
    public let requestID: String
}

/// Contract §7.1's permission **protocol** half only -- policy (auto-approval matching, secure-
/// store decisions) is caller-owned per `docs/architecture/provider-plugins.md`'s ownership table.
public enum CoreAgentPermissionDecision: Sendable, Equatable {
    case allow(includeUpdatedPermissions: Bool)
    case deny(message: String, interrupt: Bool)
}

/// The decoded batched event envelope (design D-6): `kind` is one of the contract §7.1 catalog
/// names (`assistantDelta`, `turnCompleted`, `interruptOutcome`, ...); `fields` carries the
/// kind-specific payload as raw JSON-decoded values (`String`/`NSNumber`/`Bool`/nested
/// dictionaries/arrays). Fail-open, not fail-closed: a payload this decoder cannot parse yields
/// `nil` at the `CoreAgentSessionEventEnvelope.decoded` call site rather than throwing and killing
/// the whole stream -- the same forward-compatibility posture `CoreInventoryScopeEventDecoder`
/// already takes (`.unknown` there; `nil` here, since this catalog has no single "ignore me"
/// case).
public struct CoreAgentSessionEvent: @unchecked Sendable {
    public let kind: String
    public let turnID: UInt64?
    public let fields: [String: Any]

    public func stringField(_ key: String) -> String? {
        fields[key] as? String
    }

    public func uint64Field(_ key: String) -> UInt64? {
        (fields[key] as? NSNumber)?.uint64Value
    }

    public func boolField(_ key: String) -> Bool? {
        fields[key] as? Bool
    }
}

enum CoreAgentSessionEventDecoder {
    static func decode(_ event: CoreEvent) -> CoreAgentSessionEvent? {
        let data: Data
        switch event.payload {
        case let .utf8(string): data = Data(string.utf8)
        case let .bytes(bytes): data = bytes
        case .gap, .rejected: return nil
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["v"] as? Int, version == 1,
              let kind = object["kind"] as? String
        else {
            return nil
        }
        var fields = object
        fields.removeValue(forKey: "v")
        fields.removeValue(forKey: "kind")
        let turnID = (fields.removeValue(forKey: "turn_id") as? NSNumber)?.uint64Value
        return CoreAgentSessionEvent(kind: kind, turnID: turnID, fields: fields)
    }
}

/// One drained event, carrying both the raw generic-subscription-surface fact (`raw.kind` --
/// `.gap`/`.payloadRejected`/`.data`/`.terminal`, contract §5.4's pressure-policy outcomes) and the
/// decoded agent-claude event when the payload is one this vertical produced.
public struct CoreAgentSessionEventEnvelope: @unchecked Sendable {
    public let raw: CoreEvent
    public let decoded: CoreAgentSessionEvent?

    public var isGap: Bool { raw.kind == .gap }
    public var isPayloadRejected: Bool { raw.kind == .payloadRejected }
}

public struct CoreAgentSessionEventStream: AsyncSequence, Sendable {
    public typealias Element = CoreAgentSessionEventEnvelope

    private let events: CoreEventStream
    private let bridge: AgentryCoreBridge
    let subscription: CoreSubscription

    init(bridge: AgentryCoreBridge, subscription: CoreSubscription) {
        events = subscription.events
        self.subscription = subscription
        self.bridge = bridge
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(inner: events.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var inner: AsyncThrowingStream<CoreEvent, Error>.Iterator

        public mutating func next() async throws -> CoreAgentSessionEventEnvelope? {
            guard let event = try await inner.next() else { return nil }
            return CoreAgentSessionEventEnvelope(raw: event, decoded: CoreAgentSessionEventDecoder.decode(event))
        }
    }

    /// Idempotent, product-facing close over the underlying generic subscription -- mirrors
    /// `CoreInventoryScopeEventStream.close()`'s convention exactly, including its doc comment's
    /// reasoning: an `AsyncSequence` value type has no `deinit` backstop, so callers are expected
    /// to close explicitly once done draining. Design §4.7's "no subscription outlives its
    /// drainer" policy (P6-6 done-when) is what this discipline exists to satisfy: closing the
    /// last presentation consumer's stream closes the subscription without stopping the run --
    /// covered by `CoreAgentSessionTests.closingTheEventStreamClosesTheSubscriptionNotTheRun`.
    public func close() async throws {
        try await bridge.closeSubscription(subscription)
    }
}

/// Bridge-owned ARC wrapper over one Rust `AgentClaudeScope` (contract doc, design §11 P6-6). The
/// raw `AgentClaudeScopeId` is never exposed above this type.
public final class CoreAgentSession: @unchecked Sendable {
    private let bridge: AgentryCoreBridge
    public let scopeID: String
    /// The `ScopeId` this session's event-plane notifications publish into -- computed once
    /// Rust-side (`AgentClaudeScopeId::to_subscription_scope_id`) and carried here verbatim, never
    /// re-derived on the Swift side (mirrors `CoreInventoryScope.subscriptionScopeID`'s doc
    /// comment).
    public let subscriptionScopeID: String
    private let closedFlag = OSAllocatedUnfairLock(initialState: false)

    private init(bridge: AgentryCoreBridge, scopeID: String, subscriptionScopeID: String) {
        self.bridge = bridge
        self.scopeID = scopeID
        self.subscriptionScopeID = subscriptionScopeID
    }

    public static func open(bridge: AgentryCoreBridge, config: CoreAgentSessionConfig) async throws -> CoreAgentSession {
        let handle = try await bridge.agentOpenScope(config: .init(
            command: config.command,
            arguments: config.arguments,
            environment: config.environment.map { AgentryUniFFIRaw.CoreAgentClaudeEnvironmentEntryV1(key: $0.key, value: $0.value) },
            workingDirectory: config.workingDirectory,
            permissionMode: config.permissionMode,
            mcpConfigPath: config.mcpConfigPath,
            mcpStrictMode: config.mcpStrictMode,
            disallowedBuiltInTools: config.disallowedBuiltInTools,
            appendSystemPrompt: config.appendSystemPrompt,
            systemPrompt: config.systemPromptOverride,
            idleFallbackMillis: config.idleFallbackMillis,
            interruptAckTimeoutMillis: config.interruptAckTimeoutMillis
        ))
        return CoreAgentSession(bridge: bridge, scopeID: handle.scopeId, subscriptionScopeID: handle.subscriptionScopeId)
    }

    /// P6-6: the agent-claude event stream (contract §7.1), reusing `AgentryCoreBridge`'s fixed
    /// `openSubscription` path verbatim -- register-before-suspend is already correct there (the
    /// 83f848b2 lesson `CoreInventoryScope.events()`'s doc comment names), so this facade does not
    /// re-derive a second register/await sequence. This session's events publish under
    /// `subscriptionScopeID`, computed Rust-side and carried on this instance since `open()`.
    public func events(maxQueuedEvents: UInt64 = 256, maxQueuedBytes: UInt64 = 1_048_576) async throws -> CoreAgentSessionEventStream {
        let scopeID = try CoreScopeID(rawValue: subscriptionScopeID)
        let subscription = try await bridge.openSubscription(scopeID: scopeID, maxQueuedEvents: maxQueuedEvents, maxQueuedBytes: maxQueuedBytes)
        return CoreAgentSessionEventStream(bridge: bridge, subscription: subscription)
    }

    /// Contract §5.1: spawns the child and starts the reader threads. Returns `pid`/
    /// `processGroupID` synchronously so the caller's expected-agent-PID fence (design §4.6) can
    /// register immediately on return.
    public func startOrResume(resumeSessionID: String? = nil) async throws -> CoreAgentStartReceipt {
        let receipt = try await bridge.agentStartOrResume(scopeID: scopeID, resumeSessionID: resumeSessionID)
        return CoreAgentStartReceipt(pid: receipt.pid, processGroupID: receipt.processGroupId)
    }

    /// Returns the newly minted `turnGeneration` (contract §4's interrupt-fencing token).
    public func sendUserMessage(_ text: String) async throws -> UInt64 {
        try await bridge.agentSendUserMessage(scopeID: scopeID, text: text)
    }

    /// Contract §4: fenced by `generation`, no pre-check (design §5.3 -- the pre-check is
    /// *removed*, not made remote). The outcome arrives later as an `interruptOutcome` event.
    public func interruptTurn(generation: UInt64, reason: String) async throws -> CoreAgentInterruptReceipt {
        let receipt = try await bridge.agentInterruptTurn(scopeID: scopeID, turnGeneration: generation, reason: reason)
        return CoreAgentInterruptReceipt(requestID: receipt.requestId)
    }

    public func respondPermission(requestID: String, decision: CoreAgentPermissionDecision) async throws {
        let rawDecision: AgentryUniFFIRaw.AgentClaudePermissionDecisionV1
        switch decision {
        case let .allow(includeUpdatedPermissions):
            rawDecision = .allow(includeUpdatedPermissions: includeUpdatedPermissions)
        case let .deny(message, interrupt):
            rawDecision = .deny(message: message, interrupt: interrupt)
        }
        try await bridge.agentRespondPermission(scopeID: scopeID, requestID: requestID, decision: rawDecision)
    }

    /// P6-7: real ACK tracking (`docs/architecture/rust-agent-claude-v1.md` §15.3), replacing the
    /// P6-6 fire-and-forget placeholder. Returns immediately with a request-id receipt; the caller
    /// correlates the later `flagSettingsApplied` event on `events()` against `requestID` to observe
    /// applied/timedOut/failed, mirroring `interruptTurn`'s command+event shape.
    @discardableResult
    public func applyModelAndEffort(model: String? = nil, effort: String? = nil) async throws -> CoreAgentFlagSettingsReceipt {
        let receipt = try await bridge.agentApplyModelAndEffort(scopeID: scopeID, model: model, effort: effort)
        return CoreAgentFlagSettingsReceipt(requestID: receipt.requestId)
    }

    /// Idempotent, product-facing shutdown/close. Flushes deferred turn completions, escalates
    /// SIGTERM -> grace -> SIGKILL against the process group, then removes the scope from the
    /// registry -- there is no separate close call for this domain (design's seven-export
    /// enumeration). `deinit` is a backstop only.
    public func close() async {
        let alreadyClosed = closedFlag.withLock { flag -> Bool in
            let was = flag
            flag = true
            return was
        }
        guard !alreadyClosed else { return }
        try? await bridge.agentShutdown(scopeID: scopeID)
    }

    deinit {
        let alreadyClosed = closedFlag.withLock { flag -> Bool in
            let was = flag
            flag = true
            return was
        }
        guard !alreadyClosed else { return }
        let deinitScopeID = scopeID
        let deinitBridge = bridge
        Task.detached {
            try? await deinitBridge.agentShutdown(scopeID: deinitScopeID)
        }
    }
}
