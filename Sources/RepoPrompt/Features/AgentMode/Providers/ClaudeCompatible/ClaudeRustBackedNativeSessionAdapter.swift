#if DEBUG
    import AgentryCoreBridge
    import Foundation
    import RepoPromptDomainRuntime

    /// P6-7 (`docs/designs/p6-claude-vertical-2026-08-23.md` §11 P6-7, `docs/architecture/
    /// rust-agent-claude-v1.md`): the Rust-backed `NativeAgentRuntimeControlling` adapter -- a
    /// second, still-not-authoritative implementation selectable only behind a DEBUG-only flag
    /// (`ClaudeRustBackedNativeSessionAdapterSelection`, wired at
    /// `ClaudeAgentModeCoordinator.makeDefaultController`). Wraps one `CoreAgentSession` (the
    /// bridge-owned ARC facade over one Rust `AgentClaudeScope`) and translates its wire event
    /// stream (contract §7.1) back into the same `NativeAgentRuntimeEvent`/
    /// `NativeAgentRuntimeSessionRef`/`NativeAgentRuntimeInterruptOutcome` shapes
    /// `ClaudeNativeProcessSessionController` already produces, so the coordinator (and the P6-7
    /// turn-level differential, `ClaudeRustBackedTurnLevelDifferentialTests`) can drive either arm
    /// through the identical `NativeAgentRuntimeControlling` contract.
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
    ///    §7's not-drift list pins today's four meanings; `ClaudeNativeProcessSessionController`
    ///    shares the same typealias, so widening it would ripple into the still-authoritative arm).
    ///
    /// **Known gap, discovered while building this adapter (not fixed here -- see P6-7 session
    /// report).** `agent_claude::scope::AgentClaudeScope::start_or_resume` never sends the CLI's
    /// SDK `initialize` control request (`ClaudeNativeProcessSessionController.
    /// initializeIfNeeded`/`buildInitializeRequest`, `systemPrompt` override) before accepting user
    /// messages -- confirmed by reading `agent_claude::permission`/`scope.rs` end to end; the only
    /// `"initialize"` reference in `rust/crates/runtime/src/agent_claude/` is an unrelated negative
    /// test fixture. This adapter's `systemPromptOverride` parameter is therefore accepted for
    /// protocol conformance but has **no effect** through the Rust arm today. It does not affect
    /// this session's turn-level differential (driven by the synthetic CLI's `scripted` mode, whose
    /// background responder ACKs *any* control request regardless of subtype, so both arms complete
    /// their respective handshakes against it) or the corpus/cargo-only differentials, but it is a
    /// real, confirmed blocker for the P6-8 real-CLI soak (item 8, separately blocked pending
    /// E-P6-1 user approval) and must be closed before that soak has any chance of passing against
    /// the actual `claude` CLI.
    ///
    /// **What this arm does not yet reconstruct.** `RuntimeInitStatus`'s tool list / MCP server
    /// status map / `InitializeResponseSnapshot` (account, commands, agents, output style) are not
    /// threaded through the wire at P6-7 -- the Rust `runtimeInit` event carries only the full
    /// `StreamResult` field set (`stream_result_wire_fields`), which has no tool/MCP-status
    /// sub-fields. This is out of scope for the turn-level differential (which compares
    /// `AIStreamResult` sequences, turn IDs/statuses, approval requests, and `providerSessionID` --
    /// design §3.4's table -- not the tools/MCP preview surface), so `.runtimeInit` is published
    /// with a minimal snapshot (`sessionID` only) rather than left unemitted, preserving the event
    /// shape for any UI that reads it without claiming parity this arm does not have.
    ///
    /// **Diagnostics not surfaced.** `transcriptTruncated` (D-8), `framerOverflow`, `stderrTail`,
    /// and `protocolDrift` events are received and acknowledged (draining the subscription) but not
    /// translated into a coordinator-visible event -- they have no Swift-arm equivalent to diff
    /// against (D-8 is new, Rust-only machinery; the others are today's raw-event-log-only
    /// diagnostics), so surfacing them would not be comparable across arms and is left for a later
    /// step that wires D-9's Rust-side raw-event log (this session's report names it as owed).
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
            case timedOut
            case failed(message: String)
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
        private let workspacePath: String?
        private let config: ClaudeCodeAgentConfig
        private let environmentResolver: any ClaudeCodeLaunchEnvironmentResolving
        private let bridgeProvider: @Sendable () async throws -> AgentryCoreBridge

        private var session: CoreAgentSession?
        private var configLease: MCPConfigLease?
        private var isInitialized = false
        private var providerSessionID: String?

        private var eventsStream: AsyncStream<NativeAgentRuntimeEvent>?
        private var eventsContinuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation?
        private var pumpTask: Task<Void, Never>?

        private var turnIDByGeneration: [UInt64: UUID] = [:]
        private var pendingGenerations: Set<UInt64> = []
        private var latestGeneration: UInt64 = 0
        private var invocationUUIDByRustID: [UInt64: UUID] = [:]

        private var pendingInterrupts: [String: CheckedContinuation<RustInterruptOutcome, Never>] = [:]
        private var pendingFlagSettings: [String: CheckedContinuation<FlagSettingsOutcome, Never>] = [:]

        init(
            runID: UUID,
            tabID: UUID,
            workspacePath: String?,
            config: ClaudeCodeAgentConfig,
            runtimeConfig: ClaudeCompatiblePluginRuntimeConfig,
            environmentResolver: any ClaudeCodeLaunchEnvironmentResolving = ClaudeCodeLaunchEnvironmentResolver(),
            bridgeProvider: @escaping @Sendable () async throws -> AgentryCoreBridge = ClaudeRustBackedNativeSessionAdapter
                .defaultBridgeProvider
        ) {
            self.runID = runID
            self.tabID = tabID
            self.workspacePath = workspacePath
            self.config = config
            self.runtimeConfig = runtimeConfig
            self.environmentResolver = environmentResolver
            self.bridgeProvider = bridgeProvider
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
            systemPromptOverride _: String?
        ) async throws -> NativeAgentRuntimeSessionRef {
            if session != nil, isInitialized {
                return NativeAgentRuntimeSessionRef(sessionID: providerSessionID ?? existingSessionID)
            }
            await ensureEventsStreamReady()

            // Model/effort resolution mirrors `ClaudeNativeProcessSessionController.
            // resolveLaunchFlagSettings` verbatim -- same pure helpers, same precedence.
            let modelSpecifier = model.map { ClaudeModelSpecifier(raw: $0) }
            let requestedModel = modelSpecifier != nil ? model : config.modelString
            let effectiveEffortLevel = modelSpecifier?.explicitEffortLevel
                ?? effortLevel
                ?? config.effortLevel
            let launchEnvironment = try await environmentResolver.resolve(
                variant: config.runtimeVariant,
                requestedModel: requestedModel
            )
            let requestEffortLevel = launchEnvironment.suppressesEffortSettings ? nil : effectiveEffortLevel

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
                // treats the lease as an input, not a hard precondition on this arm's parity bar);
                // the CLI simply launches without RepoPrompt's own MCP server wired in.
                mcpConfigPath = nil
            }

            let appendSystemPrompt = config.runtimeVariant == .glm ? Self.glmZAIAppendSystemPrompt : nil

            let sessionConfig = CoreAgentSessionConfig(
                command: resolvedCommand,
                arguments: [],
                environment: environment,
                workingDirectory: workspacePath,
                permissionMode: config.permissionMode,
                mcpConfigPath: mcpConfigPath,
                mcpStrictMode: config.mcpStrictMode,
                disallowedBuiltInTools: config.disallowedBuiltInTools,
                appendSystemPrompt: appendSystemPrompt
            )

            let newSession = try await CoreAgentSession.open(bridge: bridge, config: sessionConfig)
            session = newSession

            // Subscription before spawn (design §5.1's atomic-bootstrap discipline, mirrored here
            // even though this session is fresh and has no history to bootstrap): opening the event
            // stream before `startOrResume` ensures no early event can publish into a subscription
            // that does not exist yet.
            let stream = try await newSession.events()
            startEventPump(stream: stream)

            do {
                _ = try await newSession.startOrResume(resumeSessionID: existingSessionID)
            } catch {
                await teardownAfterStartFailure()
                throw NativeAgentRuntimeControllerError.initializationFailed(String(describing: error))
            }
            isInitialized = true

            if requestEffortLevel != nil || launchEnvironment.effectiveModel != nil {
                // Best-effort initial flag settings: fire the command, do not block session
                // start-up on the ACK (mirrors the fast-enqueue contract; the coordinator observes
                // the eventual outcome only if it calls `applyModelAndEffort` again later).
                _ = try? await newSession.applyModelAndEffort(
                    model: launchEnvironment.effectiveModel,
                    effort: requestEffortLevel?.rawValue
                )
            }

            return NativeAgentRuntimeSessionRef(sessionID: providerSessionID ?? existingSessionID)
        }

        func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
            NativeAgentRuntimeSessionRef(sessionID: providerSessionID)
        }

        func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {
            guard let session else { throw NativeAgentRuntimeControllerError.processNotRunning }
            let receipt: CoreAgentFlagSettingsReceipt
            do {
                receipt = try await session.applyModelAndEffort(model: model, effort: effortLevel?.rawValue)
            } catch {
                throw NativeAgentRuntimeControllerError.inputWriteFailed(String(describing: error))
            }
            let outcome = await awaitFlagSettingsOutcome(requestID: receipt.requestID)
            switch outcome {
            case .applied:
                return
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
            let rustDecision: CoreAgentPermissionDecision
            switch decision {
            case .accept:
                rustDecision = .allow(includeUpdatedPermissions: false)
            case .acceptForSession, .acceptWithExecpolicyAmendment:
                rustDecision = .allow(includeUpdatedPermissions: true)
            case .decline:
                rustDecision = .deny(message: "Permission denied by user.", interrupt: false)
            case .cancel:
                rustDecision = .deny(message: "Permission cancelled by user.", interrupt: true)
            }
            try? await session.respondPermission(requestID: id, decision: rustDecision)
        }

        func shutdown() async {
            pumpTask?.cancel()
            pumpTask = nil
            if let session {
                await session.close()
            }
            session = nil
            isInitialized = false
            configLease?.release()
            configLease = nil
            for continuation in pendingInterrupts.values {
                continuation.resume(returning: .failed)
            }
            pendingInterrupts.removeAll()
            for continuation in pendingFlagSettings.values {
                continuation.resume(returning: .failed(message: "session shut down"))
            }
            pendingFlagSettings.removeAll()
            eventsContinuation?.finish()
            eventsContinuation = nil
        }

        // MARK: - Event pump

        private func startEventPump(stream: CoreAgentSessionEventStream) {
            pumpTask = Task { [weak self] in
                do {
                    for try await envelope in stream {
                        guard let self else { return }
                        await self.handle(envelope: envelope)
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
            case "transcriptTruncated", "framerOverflow", "stderrTail", "protocolDrift":
                // Diagnostics with no Swift-arm equivalent to diff against -- see this type's doc
                // comment ("Diagnostics not surfaced").
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
        /// app-DTO mapping the still-authoritative Swift arm uses -- rather than re-deriving a
        /// second mapping. `invocation_id` (a Rust `InvocationId(u64)`, per-arm only, never
        /// compared cross-arm by value) is remapped to a locally-minted, stable-per-generation
        /// `UUID` via `invocationUUIDByRustID` so within-arm `tool_call`/`tool_result` correlation
        /// still works the way `AIStreamResult.toolInvocationID` is meant to be used.
        private func reconstructStreamResult(_ decoded: CoreAgentSessionEvent) -> AIStreamResult? {
            guard let type = decoded.stringField("type") else { return nil }
            let invocationID: UUID? = decoded.uint64Field("invocation_id").map { rustID in
                if let existing = invocationUUIDByRustID[rustID] { return existing }
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

        /// Mirrors `ClaudeNativeProcessSessionController.buildApprovalRequest(from:)` field for
        /// field, reconstructing from the Rust `approval_request` event's fields
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
            pumpTask?.cancel()
            pumpTask = nil
            if let session {
                await session.close()
            }
            session = nil
            configLease?.release()
            configLease = nil
        }

        // MARK: - Interrupt / flag-settings correlation

        private func issueInterrupt(session: CoreAgentSession, generation: UInt64, reason: String) async -> RustInterruptOutcome {
            let receipt: CoreAgentInterruptReceipt
            do {
                receipt = try await session.interruptTurn(generation: generation, reason: reason)
            } catch {
                return .failed
            }
            return await awaitInterruptOutcome(requestID: receipt.requestID)
        }

        private func awaitInterruptOutcome(requestID: String) async -> RustInterruptOutcome {
            await withCheckedContinuation { (continuation: CheckedContinuation<RustInterruptOutcome, Never>) in
                pendingInterrupts[requestID] = continuation
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.interruptOuterDeadlineNanoseconds)
                    await self?.resolvePendingInterruptOnOuterTimeout(requestID: requestID)
                }
            }
        }

        private func awaitFlagSettingsOutcome(requestID: String) async -> FlagSettingsOutcome {
            await withCheckedContinuation { (continuation: CheckedContinuation<FlagSettingsOutcome, Never>) in
                pendingFlagSettings[requestID] = continuation
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.flagSettingsOuterDeadlineNanoseconds)
                    await self?.resolvePendingFlagSettingsOnOuterTimeout(requestID: requestID)
                }
            }
        }

        private func resolvePendingInterrupt(_ decoded: CoreAgentSessionEvent) {
            guard let requestID = decoded.stringField("request_id"),
                  let continuation = pendingInterrupts.removeValue(forKey: requestID)
            else {
                return
            }
            if let currentGeneration = decoded.uint64Field("current_generation") {
                latestGeneration = max(latestGeneration, currentGeneration)
            }
            switch decoded.stringField("outcome") {
            case "acknowledged":
                continuation.resume(returning: .acknowledged)
            case "noTurnInFlight":
                continuation.resume(returning: .noTurnInFlight)
            case "staleGeneration":
                let currentGeneration = decoded.uint64Field("current_generation") ?? latestGeneration
                let currentTurnInFlight = decoded.boolField("current_turn_in_flight") ?? false
                continuation.resume(returning: .staleGeneration(
                    currentGeneration: currentGeneration,
                    currentTurnInFlight: currentTurnInFlight
                ))
            case "timedOut":
                continuation.resume(returning: .timedOut)
            default:
                continuation.resume(returning: .failed)
            }
        }

        private func resolvePendingInterruptOnOuterTimeout(requestID: String) {
            guard let continuation = pendingInterrupts.removeValue(forKey: requestID) else { return }
            continuation.resume(returning: .timedOut)
        }

        private func resolvePendingFlagSettings(_ decoded: CoreAgentSessionEvent) {
            guard let requestID = decoded.stringField("request_id"),
                  let continuation = pendingFlagSettings.removeValue(forKey: requestID)
            else {
                return
            }
            switch decoded.stringField("outcome") {
            case "applied":
                continuation.resume(returning: .applied)
            case "timedOut":
                continuation.resume(returning: .timedOut)
            default:
                continuation.resume(returning: .failed(message: decoded.stringField("error") ?? "unknown flag-settings failure"))
            }
        }

        private func resolvePendingFlagSettingsOnOuterTimeout(requestID: String) {
            guard let continuation = pendingFlagSettings.removeValue(forKey: requestID) else { return }
            continuation.resume(returning: .timedOut)
        }

        /// Same literal `ProcessLauncher`/`ClaudeNativeProcessSessionController` uses (issue #295) --
        /// duplicated here (not shared) since the original is `private static` on the Swift
        /// controller and this is a deliberately independent arm.
        private static let glmZAIAppendSystemPrompt = "Running within this desktop app."
    }
#endif
