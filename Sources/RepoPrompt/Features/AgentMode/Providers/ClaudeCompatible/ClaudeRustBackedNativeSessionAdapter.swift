import AgentryCoreBridge
import Darwin
import Foundation
import RepoPromptDomainRuntime

/// P6-8 through P6-10 (`docs/architecture/rust-agent-claude-v1.md` §15.8-§15.10): the production
/// `NativeAgentRuntimeControlling` adapter for all interactive Claude-compatible variants.
/// `ClaudeAgentModeCoordinator.makeDefaultController` constructs it directly for standard Claude,
/// GLM, Kimi, and custom-compatible backends. The adapter wraps one `CoreAgentSession` (the bridge-owned ARC facade over one Rust
/// `AgentClaudeScope`) and translates its wire event stream (contract §7.1) into the existing
/// `NativeAgentRuntimeEvent`/`NativeAgentRuntimeSessionRef`/`NativeAgentRuntimeInterruptOutcome`
/// shapes, keeping the coordinator boundary unchanged.
///
/// **Three impedance mismatches this type owns (contract doc names the wire shapes each
/// answers):**
/// 1. `turnGeneration: UInt64` (Rust; also the wire `turn_id` -- `AgentClaudeScope::
///    send_user_message` mints one `u64` that serves as both) <-> `UUID` (the Swift-facing
///    `sendUserMessage`/`turnCompleted` shape). `turnIDByGeneration` is the bidirectional map;
///    it also answers `hasTurnInFlight` (D-7) as an event-derived fact -- a generation is
///    "pending" from `sendUserMessage` until its `turnCompleted` event arrives, regardless of
///    status -- rather than a synchronous actor read, since there is no actor state to read.
/// 2. Command+event -> awaited return. `interruptTurn`/`applyModelAndEffort` return
///    synchronously in the protocol, but their real outcome arrives later as a correlated
///    `interruptOutcome`/`flagSettingsApplied` event (contract §4/§2.2). `pendingInterrupts`/
///    `pendingFlagSettings` are continuation registries keyed by `request_id`, resolved by the
///    event pump; each registration also arms an outer-deadline fallback task (design §4: "Swift
///    keeps an outer deadline as belt-and-braces only") so a dropped/never-published event
///    cannot hang the caller forever.
/// 3. Five Rust interrupt outcomes -> four Swift `NativeAgentRuntimeInterruptOutcome` cases.
///    `staleGeneration` is absorbed here via contract §4's bounded single retry -- it is never
///    surfaced to the coordinator, and this type never widens the shared four-case enum (design
///    §7's not-drift list pins today's four meanings at the provider-neutral seam).
///
/// **Closed (P6-7 §15.5, `docs/architecture/rust-agent-claude-v1.md` §15.5).**
/// `agent_claude::scope::AgentClaudeScope::start_or_resume` previously never sent the CLI's SDK
/// `initialize` control request before accepting user messages -- confirmed by reading
/// `agent_claude::permission`/`scope.rs` end to end at the time. `start_or_resume` now performs
/// the full session-startup handshake (`initialize`, optionally carrying `systemPrompt`, then
/// `set_permission_mode` when `config.permission_mode` is non-empty) synchronously before
/// returning, preserving the frozen P6-1 initialization and permission-mode contract. This adapter's
/// `systemPromptOverride` parameter is threaded through `CoreAgentSessionConfig.
/// systemPromptOverride` and has real effect through the Rust implementation.
///
/// **Intentional production boundary.** `RuntimeInitStatus`'s tool list / MCP server status map /
/// `InitializeResponseSnapshot` (account, commands, agents, output style) are not threaded
/// through the wire: the Rust `runtimeInit` event carries the `StreamResult` field set, which
/// has no tool/MCP-status sub-fields. `.runtimeInit` therefore publishes the same minimal
/// snapshot used throughout the accepted P6-7 differential and P6-8 real-CLI soak (`sessionID`
/// only). Extending that preview surface is a separate additive contract change, not a rollback
/// path to the Swift process controller.
///
/// **Diagnostics stay below the coordinator surface.** `transcriptTruncated` (D-8),
/// `framerOverflow`, `stderrTail`, and `protocolDrift` events are drained but not translated into
/// coordinator-visible events. D-9/R9 records them in the Rust-owned raw-event JSONL; exposing a
/// new UI event would be a product behavior change rather than migration parity.
actor ClaudeRustBackedNativeSessionAdapter: NativeAgentRuntimeControlling {
    private enum RustInterruptOutcome {
        case acknowledged
        case noTurnInFlight
        case staleGeneration(currentGeneration: UInt64, currentTurnInFlight: Bool)
        case timedOut
        case failed
    }

    private enum FlagSettingsOutcome {
        case applied
        case pending
        case restartRequired
        case timedOut
        case failed(message: String)
    }

    private struct LaunchEnvironmentSignature: Equatable {
        let environmentOverrides: [String: String]
        let removedEnvironmentKeys: Set<String>
        let backend: ClaudeCodeLaunchEnvironment.Backend

        init(_ launchEnvironment: ClaudeCodeLaunchEnvironment) {
            environmentOverrides = launchEnvironment.environmentOverrides
            removedEnvironmentKeys = launchEnvironment.removedEnvironmentKeys
            backend = launchEnvironment.backend
        }
    }

    private struct ResolvedFlagSettings {
        let launchEnvironment: ClaudeCodeLaunchEnvironment
        let requestModel: String?
        let requestEffortLevel: NativeAgentRuntimeEffortLevel?
    }

    private struct PendingFlagSettingsIntent {
        let model: String?
        let effort: String?
    }

    struct ExpectedAgentPIDRegistrar {
        let register: @Sendable (_ pid: pid_t, _ clientName: String, _ runID: UUID) async -> Void
        let clear: @Sendable (_ pid: pid_t, _ clientName: String, _ runID: UUID) async -> Void

        static let serverNetworkManager = ExpectedAgentPIDRegistrar(
            register: { pid, clientName, runID in
                await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: clientName, runID: runID)
            },
            clear: { pid, clientName, runID in
                await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID)
            }
        )
    }

    /// Belt-and-braces outer deadlines (design §4/§2.2: "Swift keeps an outer deadline as
    /// belt-and-braces only"). Both are comfortably above Rust's own authoritative deadlines
    /// (1.5 s interrupt ACK, 5.0 s flag-settings ACK) so Rust's own timeout path always wins the
    /// race under normal operation; these only fire if the correlated event never arrives at all
    /// (e.g. a dropped subscription).
    private static let interruptOuterDeadlineNanoseconds: UInt64 = 4_000_000_000
    private static let flagSettingsOuterDeadlineNanoseconds: UInt64 = 8_000_000_000

    let runtimeConfig: ClaudeCompatiblePluginRuntimeConfig
    private let runID: UUID
    private let tabID: UUID
    private let windowID: Int
    private let workspacePath: String?
    private let config: ClaudeCodeAgentConfig
    private let environmentResolver: any ClaudeCodeLaunchEnvironmentResolving
    private let bridgeProvider: @Sendable () async throws -> AgentryCoreBridge
    private let expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar
    private let interruptReceiptRegistrationHookForTesting: (@Sendable () async -> Void)?

    private var session: CoreAgentSession?
    private var registeredExpectedAgentPID: pid_t?
    private var exitedProcessPIDs: Set<pid_t> = []
    private var configLease: MCPConfigLease?
    private var isInitialized = false
    private var providerSessionID: String?
    private var latestFlagSettingsIntentGeneration: UInt64 = 0
    private var activeLaunchEnvironmentSignature: LaunchEnvironmentSignature?

    private var eventsStream: AsyncStream<NativeAgentRuntimeEvent>?
    private var eventsContinuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation?
    private var coreEventStream: CoreAgentSessionEventStream?
    private var pumpTask: Task<Void, Never>?

    private var turnIDByGeneration: [UInt64: UUID] = [:]
    private var pendingGenerations: Set<UInt64> = []
    private var latestGeneration: UInt64 = 0
    private var invocationUUIDByRustID: [UInt64: UUID] = [:]

    private var pendingInterrupts: [String: CheckedContinuation<RustInterruptOutcome, Never>] = [:]
    private var earlyInterruptOutcomes: [String: RustInterruptOutcome] = [:]
    private var pendingFlagSettings: [String: CheckedContinuation<FlagSettingsOutcome, Never>] = [:]
    private var earlyFlagSettingsOutcomes: [String: FlagSettingsOutcome] = [:]
    private var pendingInitialFlagSettingsIntent: PendingFlagSettingsIntent?

    init(
        runID: UUID,
        tabID: UUID,
        windowID: Int,
        workspacePath: String?,
        config: ClaudeCodeAgentConfig,
        runtimeConfig: ClaudeCompatiblePluginRuntimeConfig,
        environmentResolver: any ClaudeCodeLaunchEnvironmentResolving = ClaudeCodeLaunchEnvironmentResolver(),
        bridgeProvider: @escaping @Sendable () async throws -> AgentryCoreBridge = ClaudeRustBackedNativeSessionAdapter
            .defaultBridgeProvider,
        expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar = .serverNetworkManager,
        interruptReceiptRegistrationHookForTesting: (@Sendable () async -> Void)? = nil
    ) {
        self.runID = runID
        self.tabID = tabID
        self.windowID = windowID
        self.workspacePath = workspacePath
        self.config = config
        self.runtimeConfig = runtimeConfig
        self.environmentResolver = environmentResolver
        self.bridgeProvider = bridgeProvider
        self.expectedAgentPIDRegistrar = expectedAgentPIDRegistrar
        self.interruptReceiptRegistrationHookForTesting = interruptReceiptRegistrationHookForTesting
    }

    deinit {
        guard config.toolContext == .agentRun,
              let registeredExpectedAgentPID,
              let clientName = config.runtimeVariant.agentKind.mcpClientNameHint
        else {
            return
        }
        let runID = runID
        let clear = expectedAgentPIDRegistrar.clear
        Task {
            await clear(registeredExpectedAgentPID, clientName, runID)
        }
    }

    private static func defaultBridgeProvider() async throws -> AgentryCoreBridge {
        guard let bridge = try await AgentryCoreService.shared.runtime() as? AgentryCoreBridge else {
            throw NativeAgentRuntimeControllerError.initializationFailed("AgentryCoreBridge runtime is unavailable")
        }
        return bridge
    }

    // MARK: - NativeAgentRuntimeControlling

    var hasActiveSession: Bool {
        get async { session != nil && isInitialized }
    }

    var hasTurnInFlight: Bool {
        get async { !pendingGenerations.isEmpty }
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        get async {
            if eventsStream == nil {
                await ensureEventsStreamReady()
            }
            return eventsStream!
        }
    }

    func ensureEventsStreamReady() async {
        guard eventsContinuation == nil else { return }
        let pipe = AsyncStream<NativeAgentRuntimeEvent>.makeStream()
        eventsStream = pipe.stream
        eventsContinuation = pipe.continuation
    }

    func resetEventsStreamForNewRun() async {
        eventsContinuation?.finish()
        let pipe = AsyncStream<NativeAgentRuntimeEvent>.makeStream()
        eventsStream = pipe.stream
        eventsContinuation = pipe.continuation
    }

    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        if session != nil, isInitialized {
            return NativeAgentRuntimeSessionRef(sessionID: providerSessionID ?? existingSessionID)
        }
        if session != nil {
            // P6-8 real-binary soak: `processExited` invalidates the live process without
            // discarding the provider session ID. Retire the dead Rust scope/subscription
            // before opening its replacement so the next turn resumes instead of writing to
            // the old stdin (which deterministically fails with EPIPE).
            await closeCoreSessionForReplacement()
        }
        await ensureEventsStreamReady()

        // Model/effort resolution preserves the frozen P6-1 launch-setting precedence through the
        // same pure host helpers used by the accepted P6-8/P6-9 cutover evidence.
        latestFlagSettingsIntentGeneration = 0
        let resolvedFlagSettings = try await resolveFlagSettings(model: model, effortLevel: effortLevel)
        let launchEnvironment = resolvedFlagSettings.launchEnvironment
        let requestEffortLevel = resolvedFlagSettings.requestEffortLevel

        let bridge = try await bridgeProvider()

        // Launch environment: same base builder + override/removal merge as
        // `resolvedLaunchEnvironment`/`effectiveLaunchEnvironment`, plus the config's own
        // process/effort overrides (`ClaudeCodeAgentConfig.processEnvironmentOverrides`/
        // `effortEnvironmentOverrides`).
        let builderResult = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .claudeNative,
                additionalRemovedKeys: ["NODE_OPTIONS"],
                enableDebugLogging: config.enableDebugLogging
            )
        )
        var environment = builderResult.environment
        for key in launchEnvironment.removedEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        for (key, value) in launchEnvironment.environmentOverrides {
            environment[key] = value
        }
        if environment["CLAUDE_CODE_ENTRYPOINT"].map({ !$0.isEmpty }) != true {
            environment["CLAUDE_CODE_ENTRYPOINT"] = "sdk-ts"
        }
        for (key, value) in config.processEnvironmentOverrides {
            environment[key] = value
        }
        for (key, value) in config.effortEnvironmentOverrides {
            environment[key] = value
        }

        let resolvedCommand = CommandPathResolver.resolve(
            config.commandName,
            environment: environment,
            additionalPaths: CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints),
            logger: config.enableDebugLogging ? { print("[ClaudeRustBackedSession] \($0)") } : nil,
            preferredBasenames: [config.commandName]
        )

        var mcpConfigPath: String?
        do {
            let lease = try await MCPConfigExportService.shared.prepareLaunchConfig()
            configLease = lease
            mcpConfigPath = lease.url.path
        } catch {
            // Host-owned lease acquisition failing is not fatal to the session (design §4.6
            // treats the lease as an input, not a hard precondition on adapter startup);
            // the CLI simply launches without RepoPrompt's own MCP server wired in.
            mcpConfigPath = nil
        }

        let appendSystemPrompt = config.runtimeVariant == .glm ? Self.glmZAIAppendSystemPrompt : nil

        // P6-7 D-9/R9 (`docs/architecture/rust-agent-claude-v1.md` §15.6): resolved via the
        // SAME host-policy functions the legacy writer used -- same
        // `app_settings`-backed UserDefaults keys, same file-naming scheme -- rather than a
        // second resolution path. No real session id is known yet at a fresh start, so this
        // mirrors Swift's own first-write behavior (`ensureRawEventLogFileReadyIfNeeded`'s
        // `sessionIDHint ?? sessionID ?? tabID.uuidString` fallback chain, minus the
        // `sessionID`/`sessionIDHint` legs neither exist yet here): a resume prefers the known
        // `existingSessionID`, a fresh start falls back to `tabID`. Unlike Swift, this path is
        // resolved once and never rotates afterwards (§15.6's named simplification).
        let rawEventLogEnabled = ClaudeNativeRuntimeHostPolicy.isRawEventFileLoggingEnabled()
        let rawEventLogInitialSessionID = ClaudeNativeRuntimeHostPolicy.normalizedSessionIdentifier(
            existingSessionID ?? tabID.uuidString
        )
        let rawEventLogFilePath: String? =
            if rawEventLogEnabled {
                ClaudeNativeRuntimeHostPolicy.makeRawEventLogFileURL(
                    workspacePath: workspacePath,
                    sessionID: rawEventLogInitialSessionID
                )?.path
            } else {
                nil
            }

        let sessionConfig = CoreAgentSessionConfig(
            command: resolvedCommand,
            arguments: [],
            environment: environment,
            workingDirectory: workspacePath,
            permissionMode: config.permissionMode,
            mcpConfigPath: mcpConfigPath,
            mcpStrictMode: config.mcpStrictMode,
            disallowedBuiltInTools: config.disallowedBuiltInTools,
            appendSystemPrompt: appendSystemPrompt,
            systemPromptOverride: systemPromptOverride,
            rawEventLogEnabled: rawEventLogEnabled,
            rawEventLogFilePath: rawEventLogFilePath,
            rawEventLogRunID: runID.uuidString,
            rawEventLogTabID: tabID.uuidString,
            rawEventLogWindowID: Int64(windowID),
            rawEventLogInitialSessionID: rawEventLogInitialSessionID
        )

        let newSession = try await CoreAgentSession.open(bridge: bridge, config: sessionConfig)
        session = newSession
        activeLaunchEnvironmentSignature = LaunchEnvironmentSignature(launchEnvironment)

        // Subscription before spawn (design §5.1's atomic-bootstrap discipline, mirrored here
        // even though this session is fresh and has no history to bootstrap): opening the event
        // stream before `startOrResume` ensures no early event can publish into a subscription
        // that does not exist yet.
        let stream = try await newSession.events()
        startEventPump(stream: stream)

        let startReceipt: CoreAgentStartReceipt
        do {
            startReceipt = try await newSession.startOrResume(
                resumeSessionID: existingSessionID,
                model: model,
                effortLevel: effortLevel?.rawValue
            )
        } catch {
            await teardownAfterStartFailure()
            throw NativeAgentRuntimeControllerError.initializationFailed(String(describing: error))
        }
        if exitedProcessPIDs.remove(startReceipt.pid) != nil {
            await teardownAfterStartFailure()
            throw NativeAgentRuntimeControllerError.initializationFailed(
                "Claude process exited during startup (pid \(startReceipt.pid))"
            )
        }
        await registerExpectedAgentPIDIfNeeded(startReceipt.pid)
        guard session === newSession,
              exitedProcessPIDs.remove(startReceipt.pid) == nil
        else {
            await teardownAfterStartFailure()
            throw NativeAgentRuntimeControllerError.initializationFailed(
                "Claude process exited while arming MCP routing (pid \(startReceipt.pid))"
            )
        }
        isInitialized = true

        let initialIntent = pendingInitialFlagSettingsIntent ?? PendingFlagSettingsIntent(
            model: resolvedFlagSettings.requestModel,
            effort: requestEffortLevel?.rawValue
        )
        pendingInitialFlagSettingsIntent = nil
        if initialIntent.model != nil || initialIntent.effort != nil {
            // Best-effort initial flag settings: fire the command, do not block session
            // start-up on the ACK (mirrors the fast-enqueue contract; the coordinator observes
            // the eventual outcome only if it calls `applyModelAndEffort` again later).
            _ = try? await newSession.applyModelAndEffort(
                model: initialIntent.model,
                effort: initialIntent.effort,
                disposition: .initial
            )
        }

        return NativeAgentRuntimeSessionRef(sessionID: providerSessionID ?? existingSessionID)
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: providerSessionID)
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {
        // Frozen contract behavior: return silently when no process exists. Once `session` is
        // assigned but handshake is still pending,
        // the branch below retains the latest intent for post-handshake application.
        guard let session else { return }

        latestFlagSettingsIntentGeneration &+= 1
        let intentGeneration = latestFlagSettingsIntentGeneration
        let resolved = try await resolveFlagSettings(model: model, effortLevel: effortLevel)
        guard intentGeneration == latestFlagSettingsIntentGeneration,
              self.session === session
        else {
            return
        }
        let requiresRestart = activeLaunchEnvironmentSignature.map {
            $0 != LaunchEnvironmentSignature(resolved.launchEnvironment)
        } ?? false
        let disposition: CoreAgentFlagSettingsDisposition
        if requiresRestart {
            disposition = .restartRequired
        } else if !isInitialized {
            pendingInitialFlagSettingsIntent = PendingFlagSettingsIntent(
                model: resolved.requestModel,
                effort: resolved.requestEffortLevel?.rawValue
            )
            disposition = .pendingInitialHandshake
        } else {
            guard resolved.requestModel != nil || resolved.requestEffortLevel != nil else { return }
            disposition = .live
        }

        let receipt: CoreAgentFlagSettingsReceipt
        do {
            receipt = try await session.applyModelAndEffort(
                model: requiresRestart ? model : resolved.requestModel,
                effort: resolved.requestEffortLevel?.rawValue,
                disposition: disposition
            )
        } catch {
            throw NativeAgentRuntimeControllerError.inputWriteFailed(String(describing: error))
        }
        let outcome = await awaitFlagSettingsOutcome(requestID: receipt.requestID)
        switch outcome {
        case .applied, .pending:
            return
        case .restartRequired:
            throw NativeAgentRuntimeControllerError.liveModelSwitchRequiresRestart
        case .timedOut:
            throw NativeAgentRuntimeControllerError.controlRequestTimedOut(requestID: receipt.requestID)
        case let .failed(message):
            throw NativeAgentRuntimeControllerError.invalidControlResponse(message)
        }
    }

    func sendUserMessage(_ text: String) async throws -> UUID {
        guard let session else { throw NativeAgentRuntimeControllerError.processNotRunning }
        let generation: UInt64
        do {
            generation = try await session.sendUserMessage(text)
        } catch {
            throw NativeAgentRuntimeControllerError.inputWriteFailed(String(describing: error))
        }
        let turnID = UUID()
        turnIDByGeneration[generation] = turnID
        pendingGenerations.insert(generation)
        latestGeneration = max(latestGeneration, generation)
        return turnID
    }

    /// Contract §4/design §5.3: Swift issues the interrupt with no pre-check (the pre-check is
    /// *removed*, not made remote), naming the latest known generation; Rust owns the entire
    /// decision. `staleGeneration` is absorbed by the bounded single retry below and never
    /// surfaces past this method.
    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome {
        guard let session else { return .noTurnInFlight }
        let generation = latestGeneration
        switch await issueInterrupt(session: session, generation: generation, reason: reason) {
        case .acknowledged:
            return .acknowledged
        case .noTurnInFlight:
            return .noTurnInFlight
        case .timedOut:
            return .timedOut
        case .failed:
            return .failed
        case let .staleGeneration(currentGeneration, currentTurnInFlight):
            latestGeneration = max(latestGeneration, currentGeneration)
            guard currentTurnInFlight else { return .noTurnInFlight }
            // Bounded single retry against the authoritative generation (design §5.3): never a
            // loop, and a second `staleGeneration` maps to `failed` rather than retrying again,
            // routing an unresolvable race into the coordinator's existing race-tolerant branch.
            switch await issueInterrupt(session: session, generation: currentGeneration, reason: reason) {
            case .acknowledged:
                return .acknowledged
            case .noTurnInFlight:
                return .noTurnInFlight
            case .timedOut:
                return .timedOut
            case .failed, .staleGeneration:
                return .failed
            }
        }
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {
        guard let session else { return }
        let rustDecision: CoreAgentPermissionDecision = switch decision {
        case .accept:
            .allow(includeUpdatedPermissions: false)
        case .acceptForSession, .acceptWithExecpolicyAmendment:
            .allow(includeUpdatedPermissions: true)
        case .decline:
            .deny(message: "Permission denied by user.", interrupt: false)
        case .cancel:
            .deny(message: "Permission cancelled by user.", interrupt: true)
        }
        do {
            try await session.respondPermission(requestID: id, decision: rustDecision)
        } catch {
            emit(.error("Failed to submit Claude approval decision: \(error.localizedDescription)"))
            await closeCoreSessionForReplacement()
        }
    }

    func shutdown() async {
        await closeCoreSessionForReplacement()
        eventsContinuation?.finish()
        eventsContinuation = nil
    }

    // MARK: - Event pump

    private func startEventPump(stream: CoreAgentSessionEventStream) {
        coreEventStream = stream
        pumpTask = Task { [weak self] in
            do {
                for try await envelope in stream {
                    guard let self else { return }
                    await handle(envelope: envelope)
                }
            } catch {
                // Subscription-level failure (e.g. the bridge tearing down): nothing further to
                // drain. `shutdown()`/deinit already handle process-side cleanup independently.
            }
        }
    }

    private func handle(envelope: CoreAgentSessionEventEnvelope) async {
        guard let decoded = envelope.decoded else { return }
        switch decoded.kind {
        case "assistantDelta", "reasoningDelta", "toolUseStarted", "toolResult", "taskProgress", "error":
            if let result = reconstructStreamResult(decoded) {
                recordProviderSessionID(from: result)
                emit(.stream(result))
            }
        case "sessionStateChanged":
            let text = decoded.stringField("text") ?? ""
            emit(.stream(AIStreamResult(type: "session_state_changed", text: text)))
        case "runtimeInit":
            if let result = reconstructStreamResult(decoded) {
                recordProviderSessionID(from: result)
                emit(.stream(result))
            }
            emit(.runtimeInit(NativeAgentRuntimeRuntimeInitStatus(
                sessionID: providerSessionID,
                tools: [],
                mcpServerStatuses: [:],
                initializeResponse: nil
            )))
        case "turnCompleted":
            guard let generation = decoded.turnID else { return }
            let turnID = turnIDByGeneration.removeValue(forKey: generation) ?? UUID()
            pendingGenerations.remove(generation)
            emit(.turnCompleted(turnID: turnID, status: mapTurnStatus(decoded.stringField("status"))))
        case "approvalRequest":
            if await autoApproveRepoPromptPermissionIfNeeded(decoded) {
                break
            }
            if let request = reconstructApprovalRequest(decoded) {
                emit(.approvalRequest(request))
            }
        case "approvalCancelled":
            if let requestID = decoded.stringField("request_id") {
                emit(.approvalCancelled(requestID: requestID))
            }
        case "interruptOutcome":
            resolvePendingInterrupt(decoded)
        case "flagSettingsApplied":
            resolvePendingFlagSettings(decoded)
        case "processExited":
            // Rust publishes this only for the currently fenced, unexpectedly ended child and
            // only after its pending turn/control terminal facts. Make the controller inactive
            // immediately; the next `startOrResume` retires this dead scope and resumes with the
            // preserved provider session ID. Retain the PID long enough to fence a startup/EOF
            // race and clear exactly the expected-agent registration that owned this child.
            let exitedPID = decoded.uint64Field("pid").flatMap(pid_t.init(exactly:))
            if let exitedPID {
                exitedProcessPIDs.insert(exitedPID)
            }
            isInitialized = false
            activeLaunchEnvironmentSignature = nil
            pendingGenerations.removeAll()
            turnIDByGeneration.removeAll()
            latestGeneration = 0
            invocationUUIDByRustID.removeAll()
            configLease?.release()
            configLease = nil
            if exitedPID == nil || exitedPID == registeredExpectedAgentPID {
                await clearExpectedAgentPIDIfNeeded()
            }
        case "transcriptTruncated", "framerOverflow", "stderrTail", "protocolDrift":
            // Diagnostics intentionally retained in the Rust raw-event log rather than promoted to
            // coordinator-visible events; see this type's production-boundary doc comment.
            break
        default:
            break
        }
    }

    private func mapTurnStatus(_ raw: String?) -> NativeAgentRuntimeTurnStatus {
        switch raw {
        case "cancelled": .cancelled
        case "failed": .failed
        default: .completed
        }
    }

    private func recordProviderSessionID(from result: AIStreamResult) {
        guard let candidate = result.providerSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else {
            return
        }
        providerSessionID = candidate
    }

    /// Rebuilds an `AIStreamResult` from the full `stream_result_wire_fields` field set
    /// (contract §15.2), field name for field name, then reuses
    /// `ClaudeCompatiblePluginBridge.streamResult(from:)` -- the exact same package-DTO ->
    /// app-DTO mapping the retained Swift comparison implementation uses -- rather than re-deriving a
    /// second mapping. `invocation_id` (a Rust `InvocationId(u64)`, per-arm only, never
    /// compared cross-arm by value) is remapped to a locally-minted, stable-per-generation
    /// `UUID` via `invocationUUIDByRustID` so within-arm `tool_call`/`tool_result` correlation
    /// still works the way `AIStreamResult.toolInvocationID` is meant to be used.
    private func reconstructStreamResult(_ decoded: CoreAgentSessionEvent) -> AIStreamResult? {
        guard let type = decoded.stringField("type") else { return nil }
        let invocationID: UUID? = decoded.uint64Field("invocation_id").map { rustID in
            if let existing = invocationUUIDByRustID[rustID] {
                return existing
            }
            let minted = UUID()
            invocationUUIDByRustID[rustID] = minted
            return minted
        }
        let provider = ClaudeCompatiblePluginStreamResult(
            type: type,
            text: decoded.stringField("text"),
            reasoning: decoded.stringField("reasoning"),
            promptTokens: (decoded.fields["prompt_tokens"] as? NSNumber)?.intValue,
            completionTokens: (decoded.fields["completion_tokens"] as? NSNumber)?.intValue,
            cost: (decoded.fields["cost"] as? NSNumber)?.doubleValue,
            toolName: decoded.stringField("tool_name"),
            toolArgs: decoded.stringField("tool_args"),
            toolOutput: decoded.stringField("tool_output"),
            toolInvocationID: invocationID,
            toolResultJSON: decoded.stringField("tool_result_json"),
            toolArgsJSON: decoded.stringField("tool_args_json"),
            toolIsError: decoded.boolField("tool_is_error"),
            providerSessionID: decoded.stringField("provider_session_id"),
            stopReason: decoded.stringField("stop_reason"),
            modelContextWindow: (decoded.fields["model_context_window"] as? NSNumber)?.intValue,
            contextUsedTokens: (decoded.fields["context_used_tokens"] as? NSNumber)?.intValue,
            contentMessageID: decoded.stringField("content_message_id")
        )
        return ClaudeCompatiblePluginBridge.streamResult(from: provider)
    }

    /// Runs the existing Swift/core-owned RepoPrompt permission policy before any request is
    /// surfaced to UI. Rust deliberately emits the complete original request payload but makes
    /// no policy decision; when this predicate matches, the adapter sends an automatic allow
    /// command back to the same Rust scope. The distinct decision case lets Rust preserve the
    /// legacy `approval.autoApprove.repoPrompt` raw-event record without moving policy or raw
    /// protocol bytes across the event plane.
    private func autoApproveRepoPromptPermissionIfNeeded(_ decoded: CoreAgentSessionEvent) async -> Bool {
        guard let session,
              let requestID = decoded.stringField("request_id")
        else {
            return false
        }
        let toolName = decoded.stringField("tool_name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestPayload = decoded.fields["request_payload"] as? [String: Any]
            ?? [
                "tool_name": toolName,
                "input": decoded.fields["input"] as? [String: Any] ?? [:]
            ]
        guard let match = ClaudeNativeRuntimeHostPolicy.repoPromptPermissionAutoApprovalMatch(
            toolName: toolName,
            requestPayload: requestPayload
        ) else {
            return false
        }
        do {
            try await session.respondPermission(
                requestID: requestID,
                decision: .autoAllowRepoPrompt(
                    matchSource: match.source.rawValue,
                    normalizedToolName: match.normalizedToolName,
                    serverIdentifier: match.serverIdentifier
                )
            )
        } catch {
            emit(.error("Failed auto-approving RepoPrompt Claude permission request: \(error.localizedDescription)"))
            return false
        }
        return true
    }

    /// Preserves the frozen approval-request mapping field for field, reconstructing from the Rust
    /// `approval_request` event's fields
    /// (`rust/crates/runtime/src/agent_claude/event.rs`) instead of a decoded
    /// `control_request` payload. `threadID`/`turnID` use the identical formula (constant per
    /// session/run, not per-turn) so a differential driving both arms with the same
    /// `runID`/`tabID` gets byte-identical stable IDs.
    private func reconstructApprovalRequest(_ decoded: CoreAgentSessionEvent) -> AgentApprovalRequest? {
        guard let requestID = decoded.stringField("request_id") else { return nil }
        let toolName = decoded.stringField("tool_name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tool"
        let input = decoded.fields["input"] as? [String: Any] ?? [:]
        let blockedPath = decoded.stringField("blocked_path")
        let decisionReason = decoded.stringField("decision_reason")
        let description = decoded.stringField("description")
        let toolUseID = decoded.stringField("tool_use_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = (input["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTool = toolName.lowercased()
        let kind: AgentApprovalKind = normalizedTool.contains("bash") || normalizedTool.contains("shell")
            ? .commandExecution
            : .fileChange

        let threadID = providerSessionID ?? "claude:\(tabID.uuidString.lowercased())"
        let turnID = "turn:\(runID.uuidString.lowercased())"
        let itemID = (toolUseID?.isEmpty == false ? toolUseID! : requestID)

        let approvalID = AgentApprovalRequest.stableID(
            requestID: .claudeControl(requestID),
            method: "control/can_use_tool",
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        let detailSeed = approvalID.uuidString
        var details: [AgentApprovalDetail] = []
        var detailIndex = 0
        func appendDetail(label: String, value: String, isCode: Bool = false) {
            details.append(AgentApprovalDetail(
                id: AgentApprovalDetail.stableID(
                    requestSeed: detailSeed,
                    index: detailIndex,
                    label: label,
                    value: value,
                    isCode: isCode
                ),
                label: label,
                value: value,
                isCode: isCode
            ))
            detailIndex += 1
        }
        appendDetail(label: "Tool", value: toolName, isCode: true)
        if let command, !command.isEmpty {
            appendDetail(label: "Command", value: command, isCode: true)
        }
        if let blockedPath, !blockedPath.isEmpty {
            appendDetail(label: "Blocked Path", value: blockedPath, isCode: true)
        }
        if let decisionReason, !decisionReason.isEmpty {
            appendDetail(label: "Reason", value: decisionReason)
        }
        if let description, !description.isEmpty {
            appendDetail(label: "Description", value: description)
        }

        return AgentApprovalRequest(
            id: approvalID,
            requestID: .claudeControl(requestID),
            method: "control/can_use_tool",
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            reason: decisionReason,
            command: command,
            cwd: workspacePath,
            grantRoot: blockedPath,
            details: details
        )
    }

    private func emit(_ event: NativeAgentRuntimeEvent) {
        eventsContinuation?.yield(event)
    }

    private func teardownAfterStartFailure() async {
        await closeCoreSessionForReplacement()
    }

    /// Retires one Rust scope without finishing the adapter's outer event stream. The latter is
    /// session-facing and must stay alive across a process crash/restart; the core stream is
    /// scope-facing and must close with its drainer (contract §4.7).
    private func closeCoreSessionForReplacement() async {
        // Retire actor-visible ownership before the first await so a reentrant start cannot reuse
        // a scope that is already closing.
        isInitialized = false
        let retiringSession = session
        session = nil
        let retiringEventStream = coreEventStream
        coreEventStream = nil
        pumpTask?.cancel()
        pumpTask = nil
        activeLaunchEnvironmentSignature = nil
        configLease?.release()
        configLease = nil

        for continuation in pendingInterrupts.values {
            continuation.resume(returning: .failed)
        }
        pendingInterrupts.removeAll()
        earlyInterruptOutcomes.removeAll()
        for continuation in pendingFlagSettings.values {
            continuation.resume(returning: .failed(message: "session shut down"))
        }
        pendingFlagSettings.removeAll()
        earlyFlagSettingsOutcomes.removeAll()
        pendingInitialFlagSettingsIntent = nil
        latestFlagSettingsIntentGeneration = 0
        turnIDByGeneration.removeAll()
        pendingGenerations.removeAll()
        latestGeneration = 0
        invocationUUIDByRustID.removeAll()

        if let retiringEventStream {
            try? await retiringEventStream.close()
        }
        if let retiringSession {
            await retiringSession.close()
        }
        await clearExpectedAgentPIDIfNeeded()
        exitedProcessPIDs.removeAll()
    }

    private func registerExpectedAgentPIDIfNeeded(_ pid: pid_t) async {
        guard config.toolContext == .agentRun,
              let clientName = config.runtimeVariant.agentKind.mcpClientNameHint
        else {
            return
        }
        registeredExpectedAgentPID = pid
        await expectedAgentPIDRegistrar.register(pid, clientName, runID)
    }

    private func clearExpectedAgentPIDIfNeeded() async {
        guard let registeredExpectedAgentPID,
              let clientName = config.runtimeVariant.agentKind.mcpClientNameHint
        else {
            return
        }
        self.registeredExpectedAgentPID = nil
        await expectedAgentPIDRegistrar.clear(registeredExpectedAgentPID, clientName, runID)
    }

    // MARK: - Interrupt / flag-settings correlation

    private func issueInterrupt(session: CoreAgentSession, generation: UInt64, reason: String) async -> RustInterruptOutcome {
        let receipt: CoreAgentInterruptReceipt
        do {
            receipt = try await session.interruptTurn(generation: generation, reason: reason)
        } catch {
            return .failed
        }
        if let interruptReceiptRegistrationHookForTesting {
            await interruptReceiptRegistrationHookForTesting()
        }
        return await awaitInterruptOutcome(requestID: receipt.requestID)
    }

    private func awaitInterruptOutcome(requestID: String) async -> RustInterruptOutcome {
        if let early = earlyInterruptOutcomes.removeValue(forKey: requestID) {
            return early
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<RustInterruptOutcome, Never>) in
            pendingInterrupts[requestID] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.interruptOuterDeadlineNanoseconds)
                await self?.resolvePendingInterruptOnOuterTimeout(requestID: requestID)
            }
        }
    }

    private func awaitFlagSettingsOutcome(requestID: String) async -> FlagSettingsOutcome {
        if let early = earlyFlagSettingsOutcomes.removeValue(forKey: requestID) {
            return early
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<FlagSettingsOutcome, Never>) in
            pendingFlagSettings[requestID] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.flagSettingsOuterDeadlineNanoseconds)
                await self?.resolvePendingFlagSettingsOnOuterTimeout(requestID: requestID)
            }
        }
    }

    private func resolvePendingInterrupt(_ decoded: CoreAgentSessionEvent) {
        guard let requestID = decoded.stringField("request_id") else { return }
        if let currentGeneration = decoded.uint64Field("current_generation") {
            latestGeneration = max(latestGeneration, currentGeneration)
        }
        let outcome: RustInterruptOutcome = switch decoded.stringField("outcome") {
        case "acknowledged":
            .acknowledged
        case "noTurnInFlight":
            .noTurnInFlight
        case "staleGeneration":
            .staleGeneration(
                currentGeneration: decoded.uint64Field("current_generation") ?? latestGeneration,
                currentTurnInFlight: decoded.boolField("current_turn_in_flight") ?? false
            )
        case "timedOut":
            .timedOut
        default:
            .failed
        }
        if let continuation = pendingInterrupts.removeValue(forKey: requestID) {
            continuation.resume(returning: outcome)
        } else {
            earlyInterruptOutcomes[requestID] = outcome
        }
    }

    private func resolvePendingInterruptOnOuterTimeout(requestID: String) {
        guard let continuation = pendingInterrupts.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: .timedOut)
    }

    private func resolvePendingFlagSettings(_ decoded: CoreAgentSessionEvent) {
        guard let requestID = decoded.stringField("request_id") else { return }
        let outcome: FlagSettingsOutcome = switch decoded.stringField("outcome") {
        case "applied": .applied
        case "pending": .pending
        case "restartRequired": .restartRequired
        case "timedOut": .timedOut
        default: .failed(message: decoded.stringField("error") ?? "unknown flag-settings failure")
        }
        if let continuation = pendingFlagSettings.removeValue(forKey: requestID) {
            continuation.resume(returning: outcome)
        } else {
            earlyFlagSettingsOutcomes[requestID] = outcome
        }
    }

    private func resolvePendingFlagSettingsOnOuterTimeout(requestID: String) {
        guard let continuation = pendingFlagSettings.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: .timedOut)
    }

    private func resolveFlagSettings(
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?
    ) async throws -> ResolvedFlagSettings {
        let modelSpecifier = model.map { ClaudeModelSpecifier(raw: $0) }
        let requestedModel = modelSpecifier != nil ? model : config.modelString
        let effectiveEffortLevel = modelSpecifier?.explicitEffortLevel
            ?? effortLevel
            ?? config.effortLevel
        let launchEnvironment = try await environmentResolver.resolve(
            variant: config.runtimeVariant,
            requestedModel: requestedModel
        )
        return ResolvedFlagSettings(
            launchEnvironment: launchEnvironment,
            requestModel: Self.normalizedFlagSettingsModel(launchEnvironment.effectiveModel),
            requestEffortLevel: launchEnvironment.suppressesEffortSettings ? nil : effectiveEffortLevel
        )
    }

    private static func normalizedFlagSettingsModel(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame else { return nil }
        return trimmed
    }

    /// Frozen issue #295 literal, kept local so GLM launch behavior cannot drift with unrelated
    /// prompt rendering changes.
    private static let glmZAIAppendSystemPrompt = "Running within this desktop app."
}
