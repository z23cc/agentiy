import AgentryCoreBridge
import Foundation

/// Production `SessionExecutor` factory for `agentry-mcp agent-host`.
///
/// Claude-family sessions use `CoreAgentSession`. Codex/ACP speak the app-server /
/// ACP JSON-RPC turn protocol on `CoreHostedRuntimeSession` (or an injected
/// scripted transport) and classify/normalize/evaluate/negotiate through the
/// P6-c Core semantic objects.
///
/// Host unit tests keep `AgentSessionScriptedExecutorFactory`.
package struct ProviderAgentSessionExecutorFactory: AgentSessionExecutorFactory {
    package var applicationSupportRoot: URL

    package init(applicationSupportRoot: URL) {
        self.applicationSupportRoot = applicationSupportRoot
    }

    package func makeExecutor(
        sessionID: String,
        spec: AgentHostSessionSpecV1,
        sink: AgentSessionExecutorSink
    ) throws -> AgentSessionExecutor {
        ProviderAgentSessionExecutor(
            sessionID: sessionID,
            spec: spec,
            sink: sink,
            applicationSupportRoot: applicationSupportRoot
        )
    }
}

package enum ProviderAgentSessionExecutorError: Error, Equatable {
    case coreUnavailable(String)
    case launchFailed(String)
    case alreadyStarted
    case notStarted
    case terminated
}

/// Headless-legal hosted-runtime executor. AppKit-free.
package final class ProviderAgentSessionExecutor: AgentSessionExecutor, @unchecked Sendable {
    package let sessionID: String

    private let spec: AgentHostSessionSpecV1
    private let sink: AgentSessionExecutorSink
    private let applicationSupportRoot: URL
    private let injectedTransport: (any ProviderHostedRuntimeTransport)?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var started = false
    private var terminated = false
    private var currentRun: AgentSessionExecutorRunReceipt?
    /// Last turn that started. ACP `session/update` often arrives while
    /// `session/prompt` is still in flight; the prompt response can settle the
    /// run before the event pump hops onto this queue.
    private var lastTurnReceipt: AgentSessionExecutorRunReceipt?
    private var cancelledTurnIDs: Set<String> = []
    private var lastTurnGeneration: UInt64 = 0
    private var claudeSession: CoreAgentSession?
    private var hostedTransport: (any ProviderHostedRuntimeTransport)?
    private var hostedKind: Family = .claude
    private var providerSessionID = ""
    private var negotiatedModel: String = ""
    private var negotiatedEffort: String = ""
    private let permissionEvaluator = CoreAgentPermissionPolicyEvaluator()
    private let hostedCodex = CoreHostedCodexSemantics()
    private let hostedAcp = CoreHostedAcpSemantics()
    private let hostedCodexLifecycle = CoreHostedCodexLifecycle()
    private var pendingInteraction: PendingHostedInteraction?
    package private(set) var lastClaudePermissionDecision: (requestID: String, decision: CoreAgentPermissionDecision)?

    package init(
        sessionID: String,
        spec: AgentHostSessionSpecV1,
        sink: AgentSessionExecutorSink,
        applicationSupportRoot: URL,
        hostedTransport: (any ProviderHostedRuntimeTransport)? = nil
    ) {
        self.sessionID = sessionID
        self.spec = spec
        self.sink = sink
        self.applicationSupportRoot = applicationSupportRoot
        injectedTransport = hostedTransport
        queue = DispatchQueue(label: "com.agentry.agent-host.provider-executor.\(sessionID)")
    }

    package func start(spec: AgentHostSessionSpecV1) throws -> AgentSessionExecutorRunReceipt {
        try lock.withLock {
            guard !terminated else { throw ProviderAgentSessionExecutorError.terminated }
            guard !started else { throw ProviderAgentSessionExecutorError.alreadyStarted }
            started = true
        }
        try launchBlocking(spec)
        emitRuntimeInit(hostedSessionID: providerSessionID.isEmpty ? spec.resumeProviderSessionId : providerSessionID)
        guard let message = spec.initialMessage else {
            return AgentSessionExecutorRunReceipt(runID: "", turnID: "")
        }
        return beginTurn(message: message)
    }

    package func steer(
        message: AgentHostUserMessageV1,
        delivery _: AgentHostSteerDeliveryV1
    ) throws -> AgentSessionExecutorRunReceipt {
        try lock.withLock {
            guard !terminated else { throw ProviderAgentSessionExecutorError.terminated }
            guard started else { throw ProviderAgentSessionExecutorError.notStarted }
        }
        return beginTurn(message: message)
    }

    package func interrupt(turnID: String) -> AgentHostInterruptOutcomeV1 {
        let run: AgentSessionExecutorRunReceipt? = lock.withLock {
            guard let currentRun else { return nil }
            if !turnID.isEmpty, turnID != currentRun.turnID { return nil }
            cancelledTurnIDs.insert(currentRun.turnID)
            return currentRun
        }
        guard let run else { return .noTurnInFlight }
        interruptProvider()
        queue.async { [self] in
            terminateRun(run, kind: .cancelled, outcome: .cancelled, failureReason: .cancelled)
        }
        return .acknowledged
    }

    package func deliverInteractionAnswer(interactionID: String, answer: AgentHostInteractionAnswerV1) throws {
        let pending: PendingHostedInteraction = try lock.withLock {
            guard let pendingInteraction, pendingInteraction.interactionID == interactionID else {
                throw AgentSessionExecutorError.unknownInteraction(interactionID)
            }
            self.pendingInteraction = nil
            return pendingInteraction
        }
        queue.async { [self] in
            fulfill(pending, answer: answer)
        }
    }

    package func stop(reason _: AgentHostStopReasonV1) -> AgentHostSessionStatusV1 {
        let run: AgentSessionExecutorRunReceipt? = lock.withLock {
            terminated = true
            pendingInteraction = nil
            guard let currentRun else { return nil }
            cancelledTurnIDs.insert(currentRun.turnID)
            return currentRun
        }
        interruptProvider()
        closeSessions()
        if let run {
            queue.sync { [self] in
                terminateRun(run, kind: .cancelled, outcome: .cancelled, failureReason: .cancelled)
            }
            return .cancelled
        }
        return .completed
    }

    package func terminate() {
        lock.withLock {
            terminated = true
            if let currentRun { cancelledTurnIDs.insert(currentRun.turnID) }
            currentRun = nil
            pendingInteraction = nil
        }
        interruptProvider()
        closeSessions()
        queue.sync {}
    }

    // MARK: Launch

    private func launchBlocking(_ spec: AgentHostSessionSpecV1) throws {
        let box = LaunchBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                try await self.launch(spec)
                box.error = nil
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
    }

    private func launch(_ spec: AgentHostSessionSpecV1) async throws {
        hostedKind = family(of: spec.providerId)
        switch hostedKind {
        case .claude:
            try await launchClaude(spec)
        case .codex, .acp:
            try await launchHosted(spec)
        }
    }

    private func launchClaude(_ spec: AgentHostSessionSpecV1) async throws {
        let owner = try await AgentryCoreService.shared.runtime()
        guard let bridge = owner as? AgentryCoreBridge else {
            throw ProviderAgentSessionExecutorError.coreUnavailable("AgentryCoreBridge is not the process runtime owner")
        }
        let environment = try credentialEnvironment(for: spec)
        let session = try await CoreAgentSession.open(
            bridge: bridge,
            config: CoreAgentSessionConfig(
                command: commandName(for: spec.providerId),
                environment: environment,
                workingDirectory: spec.worktreeId.isEmpty ? nil : spec.worktreeId
            )
        )
        let opened = try await session.startOrResume(
            resumeSessionID: spec.resumeProviderSessionId.isEmpty ? nil : spec.resumeProviderSessionId,
            model: spec.modelId.isEmpty ? nil : spec.modelId
        )
        lock.withLock {
            claudeSession = session
            providerSessionID = spec.resumeProviderSessionId
        }
        _ = opened
        startClaudePump(session)
    }

    private func launchHosted(_ spec: AgentHostSessionSpecV1) async throws {
        let transport: any ProviderHostedRuntimeTransport
        if let injectedTransport {
            transport = injectedTransport
        } else {
            transport = try await openLiveTransport(spec)
        }
        lock.withLock { hostedTransport = transport }
        let stream = try await transport.events()
        try await transport.start()
        startHostedPump(stream)
        do {
            switch hostedKind {
            case .codex:
                try await bootstrapCodex(spec, transport: transport)
            case .acp:
                try await bootstrapACP(spec, transport: transport)
            case .claude:
                break
            }
        } catch {
            await transport.shutdown()
            throw ProviderAgentSessionExecutorError.launchFailed(String(describing: error))
        }
    }

    private func openLiveTransport(_ spec: AgentHostSessionSpecV1) async throws -> ProviderHostedLiveTransport {
        let owner = try await AgentryCoreService.shared.runtime()
        guard let bridge = owner as? AgentryCoreBridge else {
            throw ProviderAgentSessionExecutorError.coreUnavailable("AgentryCoreBridge is not the process runtime owner")
        }
        let environment = try credentialEnvironment(for: spec)
        let kind: ProviderHostedRuntimeKind = hostedKind == .codex ? .codexAppServer : .acp
        let session = try await CoreHostedRuntimeSession.open(
            bridge: bridge,
            command: commandName(for: spec.providerId),
            arguments: hostedKind == .codex ? ["app-server"] : [],
            environment: environment,
            workingDirectory: spec.worktreeId.isEmpty ? nil : spec.worktreeId,
            protocolKind: kind == .codexAppServer ? .codexAppServer : .acp
        )
        return ProviderHostedLiveTransport(session: session, kind: kind)
    }

    private func credentialEnvironment(for spec: AgentHostSessionSpecV1) throws -> [String: String] {
        let envelopeSecret: String?
        if !spec.credentialEnvelopeId.isEmpty {
            let bytes = try AgentSessionHostCredentials.redeemEnvelope(
                envelopeID: spec.credentialEnvelopeId,
                applicationSupportRoot: applicationSupportRoot
            )
            envelopeSecret = String(data: bytes, encoding: .utf8)
        } else {
            envelopeSecret = nil
        }
        return AgentSessionHostCredentials.environment(
            forProviderID: spec.providerId,
            envelopeSecret: envelopeSecret
        )
    }

    private enum Family { case claude, codex, acp }

    private func family(of providerID: String) -> Family {
        switch providerID {
        case "codexExec": .codex
        case "openCode", "cursor", "grokBuild": .acp
        default: .claude
        }
    }

    private func commandName(for providerID: String) -> String {
        switch providerID {
        case "codexExec": "codex"
        case "openCode": "opencode"
        case "cursor": "cursor-agent"
        case "grokBuild": "grok"
        default: "claude"
        }
    }

    private func acpKind(of providerID: String) -> CoreHostedAcpRuntimeKind {
        switch providerID {
        case "cursor": .cursor
        case "grokBuild": .grokBuild
        default: .openCode
        }
    }

    // MARK: Codex / ACP bootstrap

    private func bootstrapCodex(_ spec: AgentHostSessionSpecV1, transport: any ProviderHostedRuntimeTransport) async throws {
        try hostedCodex.reset()
        try hostedCodexLifecycle.reset()
        let initializeParams = ProviderHostedJSON.string(fromJSONObject: [
            "clientInfo": [
                "name": "agentry",
                "title": "Agentry",
                "version": "dev"
            ],
            "capabilities": ["experimentalApi": true]
        ])
        let initializeData = try await transport.request(
            method: "initialize",
            paramsJSON: initializeParams,
            timeoutMilliseconds: 30_000
        )
        try await transport.notify(method: "initialized", paramsJSON: nil)
        await negotiateCodexSelection(spec: spec, initializeJSON: ProviderHostedJSON.string(from: initializeData), transport: transport)
        var threadParams: [String: Any] = [:]
        if !spec.worktreeId.isEmpty { threadParams["cwd"] = spec.worktreeId }
        if !negotiatedModel.isEmpty { threadParams["model"] = negotiatedModel }
        if !negotiatedEffort.isEmpty { threadParams["effort"] = negotiatedEffort }
        let method = spec.resumeProviderSessionId.isEmpty ? "thread/start" : "thread/resume"
        if !spec.resumeProviderSessionId.isEmpty {
            threadParams["threadId"] = spec.resumeProviderSessionId
        }
        let threadData = try await transport.request(
            method: method,
            paramsJSON: ProviderHostedJSON.string(fromJSONObject: threadParams),
            timeoutMilliseconds: 30_000
        )
        let thread = ProviderHostedJSON.object(from: threadData) ?? [:]
        let threadID = ((thread["thread"] as? [String: Any])?["id"] as? String)
            ?? (thread["threadId"] as? String)
            ?? spec.resumeProviderSessionId
        lock.withLock { providerSessionID = threadID }
    }

    private typealias AgentHostModelOptionV1 = CoreHostedCodexModelOption

    private func negotiateCodexSelection(
        spec: AgentHostSessionSpecV1,
        initializeJSON: String,
        transport: any ProviderHostedRuntimeTransport
    ) async {
        var options = collapseModelOptions(initializeJSON: initializeJSON)
        if options.isEmpty, let data = try? await transport.request(
            method: "model/list",
            paramsJSON: #"{"limit":100}"#,
            timeoutMilliseconds: 5_000
        ) {
            options = modelOptions(fromListJSON: ProviderHostedJSON.string(from: data))
        }
        let selection = negotiateSelection(
            modelOptions: options,
            requestedModel: spec.modelId.isEmpty ? nil : spec.modelId,
            requestedEffort: spec.reasoningEffort.isEmpty ? nil : spec.reasoningEffort
        )
        negotiatedModel = selection.model
        negotiatedEffort = selection.effort
    }

    private func collapseModelOptions(initializeJSON: String) -> [CoreHostedCodexModelOption] {
        modelOptions(fromInitializeJSON: initializeJSON)
    }

    private func negotiateSelection(
        modelOptions: [CoreHostedCodexModelOption],
        requestedModel: String?,
        requestedEffort: String?
    ) -> (model: String, effort: String) {
        let selected = (requestedModel?.isEmpty == false)
            ? requestedModel!
            : (modelOptions.first(where: { $0.isProviderDefault })?.rawValue ?? modelOptions.first?.rawValue ?? "default")
        let match = modelOptions.first { $0.rawValue.caseInsensitiveCompare(selected) == .orderedSame }
            ?? modelOptions.first
        let negotiated = try? hostedCodex.negotiateSelection(
            selectedModelRaw: selected,
            explicitEffort: (requestedEffort?.isEmpty == false) ? requestedEffort : nil,
            lastUsedEffort: nil,
            supported: match?.supportedReasoningEfforts ?? [],
            defaultEffort: match?.defaultReasoningEffort,
            preservingExplicitEffort: true
        )
        let model = negotiated?.modelRaw ?? selected
        let effort: String
        if let negotiatedEffort = negotiated?.reasoningEffort {
            effort = effortWire(negotiatedEffort)
        } else {
            effort = requestedEffort ?? ""
        }
        return (model, effort)
    }

    private func modelOptions(fromInitializeJSON json: String) -> [CoreHostedCodexModelOption] {
        let object = ProviderHostedJSON.object(from: json)
        let rawOptions: [CoreHostedCodexModelOption]
        if let models = object["models"] as? [[String: Any]] {
            rawOptions = models.compactMap(modelOption(from:))
        } else {
            rawOptions = []
        }
        return (try? hostedCodex.collapseModelOptions(rawOptions)) ?? rawOptions
    }

    private func modelOptions(fromListJSON json: String) -> [CoreHostedCodexModelOption] {
        let object = ProviderHostedJSON.object(from: json)
        let items = (object["data"] as? [[String: Any]]) ?? []
        let rawOptions = items.compactMap(modelOption(from:))
        return (try? hostedCodex.collapseModelOptions(rawOptions)) ?? rawOptions
    }

    private func modelOption(from entry: [String: Any]) -> CoreHostedCodexModelOption? {
        let raw = (entry["id"] as? String) ?? (entry["model"] as? String) ?? (entry["rawValue"] as? String)
        guard let raw, !raw.isEmpty else { return nil }
        let display = (entry["displayName"] as? String) ?? raw
        let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { item -> CoreHostedCodexReasoningEffort? in
            parseEffort((item["reasoningEffort"] as? String) ?? (item["effort"] as? String))
        } + (entry["supportedReasoningEfforts"] as? [String] ?? []).compactMap(parseEffort)
        return CoreHostedCodexModelOption(
            rawValue: raw,
            displayName: display,
            isPlaceholderDefault: raw.caseInsensitiveCompare("default") == .orderedSame,
            isProviderDefault: (entry["isDefault"] as? Bool) ?? (entry["isProviderDefault"] as? Bool) ?? false,
            supportedReasoningEfforts: efforts,
            defaultReasoningEffort: parseEffort(entry["defaultReasoningEffort"] as? String)
        )
    }

    private func parseEffort(_ raw: String?) -> CoreHostedCodexReasoningEffort? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none": CoreHostedCodexReasoningEffort.none
        case "minimal": .minimal
        case "low": .low
        case "medium": .medium
        case "high": .high
        case "xhigh", "x-high": .xhigh
        case "max", "maximum": .max
        case "ultra": .ultra
        default: nil
        }
    }

    private func effortWire(_ effort: CoreHostedCodexReasoningEffort) -> String {
        switch effort {
        case .none: "none"
        case .minimal: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh: "xhigh"
        case .max: "max"
        case .ultra: "ultra"
        }
    }

    private func bootstrapACP(_ spec: AgentHostSessionSpecV1, transport: any ProviderHostedRuntimeTransport) async throws {
        try hostedAcp.reset()
        let initializeParams = ProviderHostedJSON.string(fromJSONObject: [
            "protocolVersion": 1,
            "clientInfo": ["name": "agentry", "version": "dev"],
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false
            ]
        ])
        _ = try await transport.request(
            method: "initialize",
            paramsJSON: initializeParams,
            timeoutMilliseconds: 30_000
        )
        var sessionParams: [String: Any] = [
            "cwd": spec.worktreeId,
            "mcpServers": [] as [Any]
        ]
        let opened: [String: Any]
        if spec.resumeProviderSessionId.isEmpty {
            opened = waitJSON(try await transport.request(
                method: "session/new",
                paramsJSON: ProviderHostedJSON.string(fromJSONObject: sessionParams),
                timeoutMilliseconds: 30_000
            ))
        } else {
            sessionParams["sessionId"] = spec.resumeProviderSessionId
            do {
                opened = waitJSON(try await transport.request(
                    method: "session/load",
                    paramsJSON: ProviderHostedJSON.string(fromJSONObject: sessionParams),
                    timeoutMilliseconds: 30_000
                ))
            } catch {
                sessionParams.removeValue(forKey: "sessionId")
                opened = waitJSON(try await transport.request(
                    method: "session/new",
                    paramsJSON: ProviderHostedJSON.string(fromJSONObject: sessionParams),
                    timeoutMilliseconds: 30_000
                ))
            }
        }
        let sessionID = (opened["sessionId"] as? String) ?? spec.resumeProviderSessionId
        guard !sessionID.isEmpty else {
            throw ProviderAgentSessionExecutorError.launchFailed("session/new response missing sessionId")
        }
        lock.withLock { providerSessionID = sessionID }
    }

    private func waitJSON(_ data: Data) -> [String: Any] {
        ProviderHostedJSON.object(from: data) ?? [:]
    }

    // MARK: Turns

    private func beginTurn(message: AgentHostUserMessageV1) -> AgentSessionExecutorRunReceipt {
        let receipt = AgentSessionExecutorRunReceipt(
            runID: UUID().uuidString.lowercased(),
            turnID: UUID().uuidString.lowercased()
        )
        lock.withLock {
            currentRun = receipt
            lastTurnReceipt = receipt
        }
        queue.async { [self] in
            guard isLive(receipt) else { return }
            emitLifecycle(receipt, kind: .started(AgentHostRunStartedV1(
                attemptId: UUID().uuidString.lowercased(),
                message: message
            )))
            emitLifecycle(receipt, kind: .stageChanged(AgentHostRunStageChangedV1(
                stage: .running,
                retryIntent: .none
            )))
            deliver(message.text, receipt: receipt)
        }
        return receipt
    }

    private func deliver(_ text: String, receipt: AgentSessionExecutorRunReceipt) {
        switch hostedKind {
        case .claude:
            deliverClaude(text, receipt: receipt)
        case .codex:
            deliverCodex(text, receipt: receipt)
        case .acp:
            deliverACP(text, receipt: receipt)
        }
    }

    private func deliverClaude(_ text: String, receipt: AgentSessionExecutorRunReceipt) {
        let session = lock.withLock { claudeSession }
        guard let session else {
            emitStream(receipt, itemType: "error", text: "claude session is not open")
            terminateRun(receipt, kind: .providerFailure, outcome: .failed, failureReason: .agentError, assistantText: "claude session is not open")
            return
        }
        Task {
            do {
                let generation = try await session.sendUserMessage(text)
                self.lock.withLock { self.lastTurnGeneration = generation }
            } catch {
                self.queue.async {
                    guard self.isLive(receipt) else { return }
                    self.emitStream(receipt, itemType: "error", text: String(describing: error))
                    self.terminateRun(
                        receipt,
                        kind: .providerFailure,
                        outcome: .failed,
                        failureReason: .agentError,
                        assistantText: String(describing: error)
                    )
                }
            }
        }
    }

    private func deliverCodex(_ text: String, receipt: AgentSessionExecutorRunReceipt) {
        let transport = lock.withLock { hostedTransport }
        let threadID = lock.withLock { providerSessionID }
        guard let transport, !threadID.isEmpty else {
            failTurn(receipt, "codex thread is not open")
            return
        }
        if (try? hostedCodex.isTerminal()) == true {
            try? hostedCodex.reset()
            try? hostedCodexLifecycle.reset()
        }
        var params: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": text, "text_elements": [] as [Any]]]
        ]
        if !spec.worktreeId.isEmpty { params["cwd"] = spec.worktreeId }
        if !negotiatedModel.isEmpty { params["model"] = negotiatedModel }
        if !negotiatedEffort.isEmpty { params["effort"] = negotiatedEffort }
        Task {
            do {
                let data = try await transport.request(
                    method: "turn/start",
                    paramsJSON: ProviderHostedJSON.string(fromJSONObject: params),
                    timeoutMilliseconds: nil
                )
                self.queue.async { self.finishCodexTurnStart(data, receipt: receipt) }
            } catch {
                self.queue.async { self.failTurn(receipt, String(describing: error)) }
            }
        }
    }

    private func finishCodexTurnStart(_ data: Data, receipt: AgentSessionExecutorRunReceipt) {
        guard isLive(receipt) else { return }
        guard let object = ProviderHostedJSON.object(from: data),
              let turn = object["turn"] as? [String: Any]
        else { return }
        let paramsJSON = ProviderHostedJSON.string(fromJSONObject: ["turn": turn])
        let events = (try? hostedCodex.applyNotification(
            method: "turn/started",
            paramsJSON: paramsJSON,
            runId: receipt.runID
        )) ?? []
        emitSemanticEvents(events, receipt: receipt)
        if let status = turn["status"] as? String, ["completed", "interrupted", "failed"].contains(status.lowercased()) {
            let completed = (try? hostedCodex.applyNotification(
                method: "turn/completed",
                paramsJSON: paramsJSON,
                runId: receipt.runID
            )) ?? []
            emitSemanticEvents(completed, receipt: receipt)
        }
    }

    private func deliverACP(_ text: String, receipt: AgentSessionExecutorRunReceipt) {
        let transport = lock.withLock { hostedTransport }
        let acpSessionID = lock.withLock { providerSessionID }
        guard let transport, !acpSessionID.isEmpty else {
            failTurn(receipt, "acp session is not open")
            return
        }
        if (try? hostedAcp.isTerminal()) == true {
            try? hostedAcp.reset()
        }
        let params = ProviderHostedJSON.string(fromJSONObject: [
            "sessionId": acpSessionID,
            "prompt": [["type": "text", "text": text]]
        ])
        Task {
            do {
                let data = try await transport.request(
                    method: "session/prompt",
                    paramsJSON: params,
                    timeoutMilliseconds: nil
                )
                // Prompt responses race session/update notifications. Yield so
                // the event pump can enqueue inbound before we absorb stopReason.
                await Task.yield()
                self.queue.async { self.finishACPPrompt(data, receipt: receipt) }
            } catch {
                self.queue.async { self.failTurn(receipt, String(describing: error)) }
            }
        }
    }

    private func finishACPPrompt(_ data: Data, receipt: AgentSessionExecutorRunReceipt) {
        guard isLive(receipt) else { return }
        let stopReason = ProviderHostedJSON.object(from: data)?["stopReason"] as? String
        if let event = try? hostedAcp.applyStopReason(stopReason, runId: receipt.runID, turnId: receipt.turnID) {
            emitSemanticEvents([event], receipt: receipt)
        }
    }

    private func failTurn(_ receipt: AgentSessionExecutorRunReceipt, _ message: String) {
        emitStream(receipt, itemType: "error", text: message)
        terminateRun(receipt, kind: .providerFailure, outcome: .failed, failureReason: .agentError, assistantText: message)
    }

    private func interruptProvider() {
        if let session = lock.withLock({ claudeSession }) {
            let generation = lock.withLock { lastTurnGeneration }
            Task { try? await session.interruptTurn(generation: generation, reason: "interrupt") }
        }
        let transport = lock.withLock { hostedTransport }
        let hostedSessionID = lock.withLock { providerSessionID }
        let kind = hostedKind
        Task {
            await transport?.cancelInFlight()
            switch kind {
            case .codex:
                if !hostedSessionID.isEmpty {
                    _ = try? await transport?.request(
                        method: "turn/interrupt",
                        paramsJSON: ProviderHostedJSON.string(fromJSONObject: ["threadId": hostedSessionID]),
                        timeoutMilliseconds: 5_000
                    )
                }
            case .acp:
                if !hostedSessionID.isEmpty {
                    try? await transport?.notify(
                        method: "session/cancel",
                        paramsJSON: ProviderHostedJSON.string(fromJSONObject: ["sessionId": hostedSessionID])
                    )
                }
            case .claude:
                break
            }
        }
    }

    private func closeSessions() {
        let claude = lock.withLock { () -> CoreAgentSession? in
            let session = claudeSession
            claudeSession = nil
            return session
        }
        let hosted = lock.withLock { () -> (any ProviderHostedRuntimeTransport)? in
            let session = hostedTransport
            hostedTransport = nil
            return session
        }
        if let claude {
            Task { await claude.close() }
        }
        if let hosted {
            Task { await hosted.shutdown() }
        }
    }

    private func startClaudePump(_ session: CoreAgentSession) {
        Task {
            guard let stream = try? await session.events() else { return }
            var iterator = stream.makeAsyncIterator()
            while let envelope = try? await iterator.next() {
                if let event = envelope.decoded {
                    self.queue.async { self.handleClaudeEvent(event) }
                }
            }
        }
    }

    private func startHostedPump(_ stream: AsyncStream<ProviderHostedRuntimeInbound>) {
        Task {
            for await inbound in stream {
                self.queue.async { self.handleHostedInbound(inbound) }
            }
        }
    }

    package func handleClaudeEvent(_ event: CoreAgentSessionEvent) {
        let receipt = lock.withLock { currentRun }
        guard let receipt, isLive(receipt) else { return }
        switch event.kind {
        case "stream", "assistant", "content":
            emitStream(receipt, itemType: "content", text: event.stringField("text") ?? "")
        case "result", "turn_completed", "turnCompleted":
            let text = event.stringField("result") ?? event.stringField("text")
            terminateRun(receipt, kind: .completed, outcome: .completed, failureReason: .unspecified, assistantText: text)
        case "error":
            let text = event.stringField("message") ?? "provider error"
            terminateRun(receipt, kind: .providerFailure, outcome: .failed, failureReason: .agentError, assistantText: text)
        case "approvalRequest", "can_use_tool":
            handleClaudePermissionRequest(event, receipt: receipt)
        case "approvalCancelled":
            handleClaudeApprovalCancelled(event)
        default:
            if let text = event.stringField("text"), !text.isEmpty {
                emitStream(receipt, itemType: event.kind, text: text)
            }
        }
    }

    private func handleClaudePermissionRequest(_ event: CoreAgentSessionEvent, receipt: AgentSessionExecutorRunReceipt) {
        let requestID = event.stringField("request_id") ?? event.stringField("requestId") ?? event.stringField("id") ?? UUID().uuidString.lowercased()
        let toolName = (event.stringField("tool_name") ?? event.stringField("toolName") ?? event.stringField("tool"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tool"
        let input = (event.fields["input"] as? [String: Any]) ?? (event.fields["inputJson"] as? [String: Any]) ?? [:]
        let command = (input["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let blockedPath = event.stringField("blocked_path") ?? event.stringField("blockedPath")
        let decisionReason = event.stringField("decision_reason") ?? event.stringField("decisionReason")
        let description = event.stringField("description")
        let toolUseID = (event.stringField("tool_use_id") ?? event.stringField("toolUseId"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = description ?? decisionReason ?? toolName

        let lowerTool = toolName.lowercased()
        let kind: AgentHostApprovalKindV1
        if lowerTool.contains("bash") || lowerTool.contains("command") || lowerTool.contains("exec") || command != nil {
            kind = .commandExecution
        } else if lowerTool.contains("file") || lowerTool.contains("edit") || lowerTool.contains("write") || lowerTool.contains("patch") || blockedPath != nil {
            kind = .fileChange
        } else {
            kind = .unspecified
        }

        let itemID = (toolUseID?.isEmpty == false ? toolUseID! : requestID)
        let approval = AgentHostApprovalRequestV1(
            approvalId: itemID,
            requestId: requestID,
            requestIdSource: .claudeControl,
            method: "can_use_tool",
            kind: kind,
            threadId: lock.withLock { providerSessionID },
            turnId: receipt.turnID,
            itemId: itemID,
            reason: reason,
            command: command.map { [$0] } ?? [],
            cwd: spec.worktreeId,
            grantRoot: blockedPath ?? "",
            proposedExecpolicyAmendmentJson: "",
            details: []
        )

        let policy = spec.permissionPolicy ?? AgentHostPermissionPolicyV1(
            approvalPolicy: .declineUnattended,
            toolPreferences: [],
            providerSettings: [],
            interactionTimeoutSeconds: 0
        )
        let payload = (event.fields["request_payload"] as? [String: Any]) ?? event.fields
        let payloadJSON = ProviderHostedJSON.string(fromJSONObject: payload)
        let request = AgentPermissionEvalRequestV1(
            toolId: itemID,
            requestToolName: toolName,
            requestPayloadJson: payloadJSON,
            providerTrusted: false,
            kind: kind
        )
        let result = try? permissionEvaluator.evaluate(policy: policy, request: request)
        let disposition = result?.disposition ?? .ask
        switch disposition {
        case .allow:
            respondClaudePermission(requestID: requestID, decision: .allow(includeUpdatedPermissions: false))
        case .deny:
            respondClaudePermission(requestID: requestID, decision: .deny(message: "Permission denied by policy", interrupt: false))
        case .ask, .unspecified:
            requestClaudeAsk(
                requestID: requestID,
                approval: approval,
                paramsJSON: payloadJSON,
                receipt: receipt
            )
        }
    }

    private func respondClaudePermission(requestID: String, decision: CoreAgentPermissionDecision) {
        lastClaudePermissionDecision = (requestID, decision)
        let session = lock.withLock { claudeSession }
        guard let session else { return }
        Task {
            try? await session.respondPermission(requestID: requestID, decision: decision)
        }
    }

    private func requestClaudeAsk(
        requestID: String,
        approval: AgentHostApprovalRequestV1,
        paramsJSON: String,
        receipt: AgentSessionExecutorRunReceipt
    ) {
        let interactionID = approval.approvalId.isEmpty ? requestID : approval.approvalId
        let pending = PendingHostedInteraction(
            interactionID: interactionID,
            idJSON: Data(requestID.utf8),
            approval: approval,
            permissions: false,
            acpOptions: [],
            paramsJSON: paramsJSON,
            receipt: receipt
        )
        lock.withLock { pendingInteraction = pending }
        let interaction = AgentHostPendingInteractionV1(
            interactionId: interactionID,
            interactionGeneration: Data(interactionID.utf8.prefix(8)),
            kind: .approval,
            responseType: .decision,
            title: approval.reason.isEmpty ? approval.method : approval.reason,
            prompt: approval.reason.isEmpty ? "Approve this tool call?" : approval.reason,
            context: approval.command.joined(separator: " "),
            allowsMultiple: false,
            options: [],
            fields: [],
            details: approval.details,
            approval: approval,
            requestedAt: AgentSessionHostClock.rfc3339(),
            timeoutSeconds: spec.permissionPolicy?.interactionTimeoutSeconds ?? 0,
            runId: receipt.runID,
            turnId: receipt.turnID
        )
        sink.emit(.interaction(AgentHostInteractionEventV1(
            kind: .requested(AgentHostInteractionRequestedV1(interaction: interaction))
        )))
        emitLifecycle(receipt, kind: .stageChanged(AgentHostRunStageChangedV1(
            stage: .waitingForInteraction,
            retryIntent: .none
        )))
    }

    private func handleClaudeApprovalCancelled(_ event: CoreAgentSessionEvent) {
        let requestID = event.stringField("request_id")
        let pending = lock.withLock { () -> PendingHostedInteraction? in
            guard let current = pendingInteraction else { return nil }
            if let requestID, current.approval.requestId != requestID {
                return nil
            }
            pendingInteraction = nil
            return current
        }
        if let pending, isLive(pending.receipt) {
            emitLifecycle(pending.receipt, kind: .stageChanged(AgentHostRunStageChangedV1(
                stage: .running,
                retryIntent: .none
            )))
        }
    }

    private func handleHostedInbound(_ inbound: ProviderHostedRuntimeInbound) {
        switch inbound {
        case let .notification(method, paramsJSON):
            guard !isTerminated, let receipt = activeOrLastTurnReceipt() else { return }
            handleNotification(method: method, paramsJSON: paramsJSON, receipt: receipt)
        case let .serverRequest(idJSON, idDisplay, method, paramsJSON):
            guard let receipt = liveReceipt() else { return }
            handleServerRequest(idJSON: idJSON, idDisplay: idDisplay, method: method, paramsJSON: paramsJSON, receipt: receipt)
        case .processExited:
            guard let receipt = liveReceipt() else { return }
            failTurn(receipt, "provider process exited")
        case let .protocolError(message):
            guard let receipt = liveReceipt() else { return }
            emitStream(receipt, itemType: "error", text: message)
        }
    }

    private var isTerminated: Bool {
        lock.withLock { terminated }
    }

    private func liveReceipt() -> AgentSessionExecutorRunReceipt? {
        let receipt = lock.withLock { currentRun }
        guard let receipt, isLive(receipt) else { return nil }
        return receipt
    }

    private func activeOrLastTurnReceipt() -> AgentSessionExecutorRunReceipt? {
        lock.withLock { currentRun ?? lastTurnReceipt }
    }

    private func handleNotification(method: String, paramsJSON: String, receipt: AgentSessionExecutorRunReceipt) {
        switch hostedKind {
        case .codex:
            let payload = unwrapUpdate(paramsJSON)
            let events = (try? hostedCodex.applyNotification(
                method: method,
                paramsJSON: payload,
                runId: receipt.runID
            )) ?? []
            emitSemanticEvents(events, receipt: receipt)
            if let lifecycle = try? hostedCodexLifecycle.applyFileChange(method: method, paramsJSON: payload) {
                emitLifecycleEvent(lifecycle, receipt: receipt)
            }
            if let runningUpdate = try? hostedCodexLifecycle.parseCommandExecutionRunningUpdate(method: method, paramsJSON: payload) {
                let applyResult = try? hostedCodexLifecycle.applyCommandExecutionRunningUpdate(runningUpdate, items: [])
                _ = applyResult
                if let output = runningUpdate.appendedOutput, !output.isEmpty {
                    emitStream(receipt, itemType: "commandExecution", text: output)
                }
            }
        case .acp:
            if method == "session/update" {
                let payload = unwrapUpdate(paramsJSON)
                let events = (try? hostedAcp.normalizeSessionUpdate(
                    payloadJSON: payload,
                    provider: acpKind(of: spec.providerId),
                    fallbackToolCallId: UUID().uuidString.lowercased(),
                    runId: receipt.runID,
                    turnId: receipt.turnID
                )) ?? []
                emitSemanticEvents(events, receipt: receipt)
            }
        case .claude:
            break
        }
    }

    private func unwrapUpdate(_ paramsJSON: String) -> String {
        let object = ProviderHostedJSON.object(from: paramsJSON)
        if let update = object["update"] as? [String: Any] {
            return ProviderHostedJSON.string(fromJSONObject: update)
        }
        return paramsJSON.isEmpty ? "{}" : paramsJSON
    }

    private func handleServerRequest(
        idJSON: Data,
        idDisplay: String,
        method: String,
        paramsJSON: String,
        receipt: AgentSessionExecutorRunReceipt
    ) {
        switch hostedKind {
        case .codex:
            handleCodexServerRequest(idJSON: idJSON, idDisplay: idDisplay, method: method, paramsJSON: paramsJSON, receipt: receipt)
        case .acp:
            handleACPPermissionRequest(idJSON: idJSON, idDisplay: idDisplay, method: method, paramsJSON: paramsJSON, receipt: receipt)
        case .claude:
            break
        }
    }

    private func handleCodexServerRequest(
        idJSON: Data,
        idDisplay: String,
        method: String,
        paramsJSON: String,
        receipt: AgentSessionExecutorRunReceipt
    ) {
        let kind = try? hostedCodex.classifyServerRequest(method)
        let events = (try? hostedCodex.applyNotification(
            method: method,
            paramsJSON: paramsJSON,
            runId: receipt.runID,
            requestId: idDisplay
        )) ?? []
        emitSemanticEvents(events.filter { event in
            if case .approvalRequest = event.kind { return false }
            return true
        }, receipt: receipt)
        let threadID = lock.withLock { providerSessionID }
        switch kind {
        case .approval, .permissions:
            guard let approval = try? hostedCodex.parseApprovalRequest(
                requestId: idDisplay,
                method: method,
                paramsJSON: paramsJSON,
                activeThreadId: threadID.isEmpty ? nil : threadID,
                currentTurnId: receipt.turnID
            ) else {
                respondHosted(idJSON: idJSON, resultJSON: Data(#"{"decision":"decline"}"#.utf8))
                return
            }
            settlePermission(
                idJSON: idJSON,
                approval: approval,
                paramsJSON: paramsJSON,
                permissions: kind == .permissions,
                acpOptions: [],
                receipt: receipt
            )
        default:
            respondHostedError(idJSON: idJSON, code: -32601, message: "Unsupported Codex client method: \(method)")
        }
    }

    private func handleACPPermissionRequest(
        idJSON: Data,
        idDisplay: String,
        method: String,
        paramsJSON: String,
        receipt: AgentSessionExecutorRunReceipt
    ) {
        guard method == "session/request_permission" else {
            respondHostedError(idJSON: idJSON, code: -32601, message: "Unsupported ACP client method: \(method)")
            return
        }
        let params = ProviderHostedJSON.object(from: paramsJSON)
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let toolCallID = (toolCall["toolCallId"] as? String) ?? idDisplay
        let toolTitle = toolCall["title"] as? String
        let toolKind = toolCall["kind"] as? String
        let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> CoreHostedAcpPermissionOption? in
            guard let optionID = option["optionId"] as? String, let kind = option["kind"] as? String else { return nil }
            return CoreHostedAcpPermissionOption(optionId: optionID, kind: kind)
        }
        let approvalKind = (try? hostedAcp.approvalKind(forToolKind: toolKind)) ?? .unspecified
        let rawInput = toolCall["rawInput"]
        let command: [String]
        if let rawDict = rawInput as? [String: Any], let cmd = rawDict["command"] as? String {
            command = [cmd]
        } else if let cmd = rawInput as? String {
            command = [cmd]
        } else {
            command = []
        }
        let approval = AgentHostApprovalRequestV1(
            approvalId: toolCallID,
            requestId: idDisplay,
            requestIdSource: .acp,
            method: method,
            kind: approvalKind,
            threadId: lock.withLock { providerSessionID },
            turnId: receipt.turnID,
            itemId: toolCallID,
            reason: toolTitle ?? "",
            command: command,
            cwd: spec.worktreeId,
            grantRoot: "",
            proposedExecpolicyAmendmentJson: "",
            details: []
        )
        settlePermission(
            idJSON: idJSON,
            approval: approval,
            paramsJSON: paramsJSON,
            permissions: false,
            acpOptions: options,
            receipt: receipt
        )
    }

    private func settlePermission(
        idJSON: Data,
        approval: AgentHostApprovalRequestV1,
        paramsJSON: String,
        permissions: Bool,
        acpOptions: [CoreHostedAcpPermissionOption],
        receipt: AgentSessionExecutorRunReceipt
    ) {
        let policy = spec.permissionPolicy ?? AgentHostPermissionPolicyV1(
            approvalPolicy: .declineUnattended,
            toolPreferences: [],
            providerSettings: [],
            interactionTimeoutSeconds: 0
        )
        let request = AgentPermissionEvalRequestV1(
            toolId: approval.itemId.isEmpty ? approval.approvalId : approval.itemId,
            requestToolName: approval.reason.isEmpty ? approval.method : approval.reason,
            requestPayloadJson: paramsJSON,
            providerTrusted: false,
            kind: approval.kind
        )
        let result = try? permissionEvaluator.evaluate(policy: policy, request: request)
        let disposition = result?.disposition ?? .ask
        switch disposition {
        case .allow:
            if hostedKind == .acp {
                let toolName = approval.reason.isEmpty ? approval.method : approval.reason
                if let autoOptionID = try? hostedAcp.autoApprovalOptionId(
                    requestToolName: toolName,
                    payloadJSON: paramsJSON,
                    options: acpOptions,
                    provider: acpKind(of: spec.providerId)
                ), !autoOptionID.isEmpty {
                    respondPermission(
                        idJSON: idJSON,
                        decision: .accept,
                        approval: approval,
                        permissions: permissions,
                        acpOptions: acpOptions,
                        paramsJSON: paramsJSON,
                        acpSelectedOptionId: autoOptionID
                    )
                } else {
                    requestAsk(
                        idJSON: idJSON,
                        approval: approval,
                        permissions: permissions,
                        acpOptions: acpOptions,
                        paramsJSON: paramsJSON,
                        receipt: receipt
                    )
                }
                return
            }
            respondPermission(
                idJSON: idJSON,
                decision: .accept,
                approval: approval,
                permissions: permissions,
                acpOptions: acpOptions,
                paramsJSON: paramsJSON
            )
        case .deny:
            respondPermission(
                idJSON: idJSON,
                decision: .decline,
                approval: approval,
                permissions: permissions,
                acpOptions: acpOptions,
                paramsJSON: paramsJSON
            )
        case .ask, .unspecified:
            // Host policy (design §5.6): ask, including DECLINE_UNATTENDED, waits.
            // Zero attached clients do not become deny.
            requestAsk(
                idJSON: idJSON,
                approval: approval,
                permissions: permissions,
                acpOptions: acpOptions,
                paramsJSON: paramsJSON,
                receipt: receipt
            )
        }
    }

    private func requestAsk(
        idJSON: Data,
        approval: AgentHostApprovalRequestV1,
        permissions: Bool,
        acpOptions: [CoreHostedAcpPermissionOption],
        paramsJSON: String,
        receipt: AgentSessionExecutorRunReceipt
    ) {
        let interactionID = approval.approvalId.isEmpty ? UUID().uuidString.lowercased() : approval.approvalId
        let pending = PendingHostedInteraction(
            interactionID: interactionID,
            idJSON: idJSON,
            approval: approval,
            permissions: permissions,
            acpOptions: acpOptions,
            paramsJSON: paramsJSON,
            receipt: receipt
        )
        lock.withLock { pendingInteraction = pending }
        let interaction = AgentHostPendingInteractionV1(
            interactionId: interactionID,
            interactionGeneration: Data(interactionID.utf8.prefix(8)),
            kind: .approval,
            responseType: .decision,
            title: approval.reason.isEmpty ? approval.method : approval.reason,
            prompt: approval.reason.isEmpty ? "Approve this tool call?" : approval.reason,
            context: approval.command.joined(separator: " "),
            allowsMultiple: false,
            options: [],
            fields: [],
            details: approval.details,
            approval: approval,
            requestedAt: AgentSessionHostClock.rfc3339(),
            timeoutSeconds: spec.permissionPolicy?.interactionTimeoutSeconds ?? 0,
            runId: receipt.runID,
            turnId: receipt.turnID
        )
        sink.emit(.interaction(AgentHostInteractionEventV1(
            kind: .requested(AgentHostInteractionRequestedV1(interaction: interaction))
        )))
        emitLifecycle(receipt, kind: .stageChanged(AgentHostRunStageChangedV1(
            stage: .waitingForInteraction,
            retryIntent: .none
        )))
    }

    private func fulfill(_ pending: PendingHostedInteraction, answer: AgentHostInteractionAnswerV1) {
        let decision: AgentHostApprovalDecisionKindV1
        if answer.skipped {
            decision = .cancel
        } else if case let .approval(value)? = answer.answer {
            decision = value.kind
        } else {
            decision = .decline
        }
        if hostedKind == .claude || pending.approval.requestIdSource == .claudeControl {
            let requestID = String(data: pending.idJSON, encoding: .utf8) ?? pending.approval.requestId
            let claudeDecision: CoreAgentPermissionDecision
            switch decision {
            case .accept, .acceptForSession, .acceptWithExecpolicyAmendment:
                claudeDecision = .allow(includeUpdatedPermissions: false)
            case .decline:
                claudeDecision = .deny(message: "Permission declined by user", interrupt: false)
            case .cancel, .unspecified:
                claudeDecision = .deny(message: "Permission cancelled by user", interrupt: answer.skipped)
            }
            respondClaudePermission(requestID: requestID, decision: claudeDecision)
        } else {
            respondPermission(
                idJSON: pending.idJSON,
                decision: decision,
                approval: pending.approval,
                permissions: pending.permissions,
                acpOptions: pending.acpOptions,
                paramsJSON: pending.paramsJSON
            )
        }
        if isLive(pending.receipt) {
            emitLifecycle(pending.receipt, kind: .stageChanged(AgentHostRunStageChangedV1(
                stage: .running,
                retryIntent: .none
            )))
        }
    }

    private func respondPermission(
        idJSON: Data,
        decision: AgentHostApprovalDecisionKindV1,
        approval: AgentHostApprovalRequestV1,
        permissions: Bool,
        acpOptions: [CoreHostedAcpPermissionOption],
        paramsJSON: String,
        acpSelectedOptionId: String? = nil
    ) {
        _ = try? hostedCodex.settleApproval(approval.approvalId)
        _ = try? hostedAcp.settleApproval(approval.approvalId)
        if hostedKind == .acp {
            if let acpSelectedOptionId {
                let result: [String: Any] = [
                    "outcome": "selected",
                    "optionId": acpSelectedOptionId
                ]
                respondHosted(idJSON: idJSON, resultJSON: Data(ProviderHostedJSON.string(fromJSONObject: result).utf8))
                return
            }
            let mapping = (try? hostedAcp.mapApprovalDecision(
                decision,
                options: acpOptions,
                provider: acpKind(of: spec.providerId)
            )) ?? CoreHostedAcpDecisionMapping(outcome: "cancelled", optionId: nil)
            var result: [String: Any] = ["outcome": mapping.outcome]
            if let optionID = mapping.optionId { result["optionId"] = optionID }
            respondHosted(idJSON: idJSON, resultJSON: Data(ProviderHostedJSON.string(fromJSONObject: result).utf8))
            return
        }
        if permissions {
            let payload = ProviderHostedJSON.object(from: paramsJSON)
            let permissionsJSON = ProviderHostedJSON.string(fromJSONObject: payload["permissions"] ?? [:] as [String: Any])
            let result = (try? hostedCodex.buildPermissionsResult(decision: decision, permissionsJSON: permissionsJSON))
                ?? #"{"permissions":{},"scope":"turn","strictAutoReview":false}"#
            respondHosted(idJSON: idJSON, resultJSON: Data(result.utf8))
            return
        }
        let amendment = approval.proposedExecpolicyAmendmentJson.isEmpty ? nil : approval.proposedExecpolicyAmendmentJson
        let result = (try? hostedCodex.buildApprovalResult(
            decision: decision,
            kind: approval.kind,
            amendmentJSON: amendment
        )) ?? #"{"decision":"decline"}"#
        respondHosted(idJSON: idJSON, resultJSON: Data(result.utf8))
    }

    private func respondHosted(idJSON: Data, resultJSON: Data) {
        let transport = lock.withLock { hostedTransport }
        Task { try? await transport?.respond(requestIDJSON: idJSON, resultJSON: resultJSON) }
    }

    private func respondHostedError(idJSON: Data, code: Int64, message: String) {
        let transport = lock.withLock { hostedTransport }
        Task { try? await transport?.respondError(requestIDJSON: idJSON, code: code, message: message) }
    }

    private func emitSemanticEvents(_ events: [AgentHostRuntimeEventV1], receipt: AgentSessionExecutorRunReceipt) {
        for event in events {
            var stamped = event
            if stamped.runId.isEmpty || stamped.turnId.isEmpty {
                stamped = AgentHostRuntimeEventV1(
                    runId: stamped.runId.isEmpty ? receipt.runID : stamped.runId,
                    turnId: stamped.turnId.isEmpty ? receipt.turnID : stamped.turnId,
                    kind: stamped.kind
                )
            }
            sink.emit(.runtimeEvent(stamped))
            switch stamped.kind {
            case let .turnCompleted(completed):
                let status = completed.stopReason.lowercased()
                let kind: AgentHostTerminationSignalKindV1
                let outcome: AgentHostTerminalOutcomeKindV1
                let failure: AgentHostFailureReasonV1
                switch status {
                case "cancelled", "interrupted":
                    kind = .cancelled
                    outcome = .cancelled
                    failure = .cancelled
                case "failed":
                    kind = .providerFailure
                    outcome = .failed
                    failure = .agentError
                default:
                    kind = .completed
                    outcome = .completed
                    failure = .unspecified
                }
                terminateRun(receipt, kind: kind, outcome: outcome, failureReason: failure)
            case let .error(error):
                terminateRun(
                    receipt,
                    kind: .providerFailure,
                    outcome: .failed,
                    failureReason: .agentError,
                    assistantText: error.message
                )
            default:
                break
            }
        }
    }

    private func emitLifecycleEvent(_ event: CoreHostedCodexLifecycleEvent, receipt: AgentSessionExecutorRunReceipt) {
        sink.emit(.runtimeEvent(AgentHostRuntimeEventV1(
            runId: receipt.runID,
            turnId: receipt.turnID,
            kind: .stream(AgentHostStreamResultV1(
                itemType: event.kind,
                text: event.name,
                reasoning: nil,
                promptTokens: nil,
                completionTokens: nil,
                cost: nil,
                toolName: event.name,
                toolArgs: event.argsJson,
                toolOutput: event.resultJson,
                toolInvocationId: event.invocationId,
                toolResultJson: event.resultJson,
                toolArgsJson: event.argsJson,
                toolIsError: event.isError,
                providerSessionId: nil,
                stopReason: nil,
                modelContextWindow: nil,
                contextUsedTokens: nil,
                contentMessageId: nil
            ))
        )))
    }

    // MARK: Emit

    private func isLive(_ receipt: AgentSessionExecutorRunReceipt) -> Bool {
        lock.withLock { !terminated && currentRun == receipt && !cancelledTurnIDs.contains(receipt.turnID) }
    }

    private func emitRuntimeInit(hostedSessionID: String) {
        sink.emit(.runtimeEvent(AgentHostRuntimeEventV1(
            runId: "",
            turnId: "",
            kind: .runtimeInit(AgentHostRuntimeInitStatusV1(
                providerSessionId: hostedSessionID,
                tools: [],
                mcpServerStatuses: [],
                initializeResponse: nil
            ))
        )))
    }

    private func emitLifecycle(_ receipt: AgentSessionExecutorRunReceipt, kind: AgentHostRunLifecycleEventKindV1) {
        sink.emit(.runLifecycle(AgentHostRunLifecycleEventV1(runId: receipt.runID, epoch: nil, kind: kind)))
    }

    private func emitStream(_ receipt: AgentSessionExecutorRunReceipt, itemType: String, text: String) {
        sink.emit(.runtimeEvent(AgentHostRuntimeEventV1(
            runId: receipt.runID,
            turnId: receipt.turnID,
            kind: .stream(AgentHostStreamResultV1(
                itemType: itemType,
                text: text,
                reasoning: nil,
                promptTokens: nil,
                completionTokens: nil,
                cost: nil,
                toolName: nil,
                toolArgs: nil,
                toolOutput: nil,
                toolInvocationId: nil,
                toolResultJson: nil,
                toolArgsJson: nil,
                toolIsError: nil,
                providerSessionId: nil,
                stopReason: nil,
                modelContextWindow: nil,
                contextUsedTokens: nil,
                contentMessageId: nil
            ))
        )))
    }

    private func terminateRun(
        _ receipt: AgentSessionExecutorRunReceipt,
        kind: AgentHostTerminationSignalKindV1,
        outcome: AgentHostTerminalOutcomeKindV1,
        failureReason: AgentHostFailureReasonV1,
        assistantText: String? = nil
    ) {
        let shouldEmit: Bool = lock.withLock {
            guard currentRun == receipt else { return false }
            currentRun = nil
            cancelledTurnIDs.remove(receipt.turnID)
            pendingInteraction = nil
            return true
        }
        guard shouldEmit else { return }
        sink.emit(.runLifecycle(AgentHostRunLifecycleEventV1(
            runId: receipt.runID,
            epoch: nil,
            kind: .terminated(AgentHostRunTerminatedV1(
                outcome: AgentHostTerminalOutcomeV1(kind: outcome, assistantText: assistantText, failureReason: failureReason),
                signal: AgentHostTerminationSignalV1(kind: kind, assistantText: assistantText, failureReason: failureReason)
            ))
        )))
    }

    private struct PendingHostedInteraction {
        var interactionID: String
        var idJSON: Data
        var approval: AgentHostApprovalRequestV1
        var permissions: Bool
        var acpOptions: [CoreHostedAcpPermissionOption]
        var paramsJSON: String
        var receipt: AgentSessionExecutorRunReceipt
    }

    private final class LaunchBox: @unchecked Sendable {
        var error: Error?
    }
}
