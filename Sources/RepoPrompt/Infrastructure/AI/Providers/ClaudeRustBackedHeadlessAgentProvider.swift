import AgentryCoreBridge
import Foundation

/// Immutable launch inputs shared by headless providers. Physical preparation
/// (MCP config lease and compatible-backend environment) remains Swift-owned;
/// once the process is opened, Rust owns stdin/NDJSON/termination.
struct HeadlessAgentContext {
    let runID: UUID
    let configURL: URL?
    let configLease: MCPConfigLease?
    let workingDirectory: String
    let environment: [String: String]
    let launchEnvironment: ClaudeCodeLaunchEnvironment?

    init(
        runID: UUID,
        configURL: URL? = nil,
        configLease: MCPConfigLease? = nil,
        workingDirectory: String? = nil,
        environment: [String: String],
        launchEnvironment: ClaudeCodeLaunchEnvironment? = nil
    ) {
        self.runID = runID
        self.configLease = configLease
        self.configURL = configLease?.url ?? configURL
        self.workingDirectory = workingDirectory ?? FileManager.default.temporaryDirectory.path
        self.environment = environment
        self.launchEnvironment = launchEnvironment
    }
}

/// Rust-backed implementation of Claude Code's headless `-p` mode.
///
/// Swift still resolves credentials, compatible-backend environment, prompt
/// packaging and the app-facing stream DTO. It does not spawn a process, frame
/// stdout, parse provider JSON, or decide stream semantics. Those operations
/// are performed by the Rust `AgentProviderScope`'s ClaudeHeadless variant.
final class ClaudeRustBackedHeadlessAgentProvider: HeadlessAgentProvider {
    private let config: ClaudeCodeAgentConfig
    private let environmentResolver: any ClaudeCodeLaunchEnvironmentResolving
    private let configService = MCPConfigExportService.shared
    private let toolTracking = AgentToolTrackingController()
    private let bridgeProvider: @Sendable () async throws -> AgentryCoreBridge
    private var streamTask: Task<Void, Never>?
    private var activeSession: CoreAgentProviderSession?
    private var invocationUUIDByRustID: [UInt64: UUID] = [:]

    init(
        config: ClaudeCodeAgentConfig,
        environmentResolver: any ClaudeCodeLaunchEnvironmentResolving = ClaudeCodeLaunchEnvironmentResolver(),
        bridgeProvider: @escaping @Sendable () async throws -> AgentryCoreBridge = {
            guard let bridge = try await AgentryCoreService.shared.runtime() as? AgentryCoreBridge else {
                throw CoreBridgeError.transportFailure("AgentryCoreBridge runtime is unavailable")
            }
            return bridge
        }
    ) {
        self.config = config
        self.environmentResolver = environmentResolver
        self.bridgeProvider = bridgeProvider
    }

    private var enableDebugLogging: Bool {
        config.enableDebugLogging
    }

    func prepare(runID: UUID? = nil) async throws -> HeadlessAgentContext {
        let actualRunID = runID ?? UUID()
        do {
            guard await ServerNetworkManager.shared.isRunning() else {
                throw AIProviderError.invalidConfiguration(
                    detail: "Could not start MCP server. Check MCP settings and try again."
                )
            }
            let configLease = try await configService.prepareLaunchConfig()
            let launchEnvironment = try await environmentResolver.resolve(
                variant: config.runtimeVariant,
                requestedModel: config.modelString
            )
            return HeadlessAgentContext(
                runID: actualRunID,
                configLease: configLease,
                environment: ProcessInfo.processInfo.environment,
                launchEnvironment: launchEnvironment
            )
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidConfiguration(
                detail: "Failed to prepare agent run: \(error.localizedDescription)"
            )
        }
    }

    func buildArguments(
        context: HeadlessAgentContext,
        resumeSessionID: String? = nil,
        systemPromptOverride: String? = nil
    ) -> [String] {
        ClaudeCompatibleProviderRuntimeBridge.buildHeadlessArguments(
            config: config,
            context: context,
            resumeSessionID: resumeSessionID,
            systemPromptOverride: systemPromptOverride
        )
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            streamTask?.cancel()
            streamTask = Task {
                do {
                    // A replacement stream owns the previous scope before it prepares a new one;
                    // cancellation alone is not a transport terminalization guarantee.
                    await activeSession?.shutdown()
                    activeSession = nil
                    let context = try await prepare(runID: runID)
                    defer { Task { await cleanup(context: context) } }
                    let delivery = ClaudeAgentToolPreferences.agentModePromptDelivery()
                    let userMessage = ClaudeCompatibleProviderRuntimeBridge.providerBoundUserMessage(
                        message.userMessage,
                        instructions: message.systemPrompt,
                        delivery: delivery
                    )
                    let args = buildArguments(
                        context: context,
                        resumeSessionID: message.resumeSessionID,
                        systemPromptOverride: ClaudeCompatibleProviderRuntimeBridge.nativeSystemPromptOverride(
                            instructions: message.systemPrompt,
                            delivery: delivery
                        )
                    )
                    let additionalEnvironment = config.effortEnvironmentOverrides.merging(
                        context.launchEnvironment?.environmentOverrides ?? [:]
                    ) { _, resolverValue in resolverValue }
                    let environment = await ProcessEnvironmentBuilder.build(
                        ProcessEnvironmentRequest(
                            purpose: .cliRunner,
                            overrides: additionalEnvironment,
                            additionalRemovedKeys: context.launchEnvironment?.removedEnvironmentKeys ?? [],
                            enableDebugLogging: enableDebugLogging
                        )
                    ).environment
                    let command = CommandPathResolver.resolve(
                        config.commandName,
                        environment: environment,
                        additionalPaths: CLIPathHints.claudeCode,
                        preferredBasenames: [config.commandName]
                    )
                    let bridge = try await bridgeProvider()
                    let session = try await CoreAgentProviderSession.open(
                        bridge: bridge,
                        command: command,
                        arguments: args,
                        environment: environment,
                        workingDirectory: context.workingDirectory,
                        protocolKind: .claudeHeadless,
                        maxStderrBytes: 256 * 1024
                    )
                    activeSession = session
                    let eventStream = try await session.events()
                    let start = try await session.startWithStdin(Data(userMessage.utf8))
                    await ServerNetworkManager.shared.registerExpectedAgentPID(
                        start.pid,
                        for: config.runtimeVariant.agentKind.mcpClientNameHint ?? "claude-code",
                        runID: context.runID
                    )
                    defer {
                        Task {
                            await ServerNetworkManager.shared.clearExpectedAgentPID(
                                start.pid,
                                for: config.runtimeVariant.agentKind.mcpClientNameHint ?? "claude-code",
                                runID: context.runID
                            )
                        }
                    }
                    toolTracking.startTracking(
                        runID: context.runID,
                        clientNameHint: "claude-code",
                        continuation: continuation
                    )

                    var sawCompletion = false
                    var stderrTail = ""
                    var iterator = eventStream.makeAsyncIterator()
                    eventLoop: while let event = try await iterator.next() {
                        switch event.kind {
                        case "streamResult":
                            guard let payload = event.payloadDictionary,
                                  let result = payload["result"] as? [String: Any],
                                  let mapped = decodeStreamResult(result)
                            else { continue }
                            continuation.yield(mapped)
                            if mapped.type == "message_stop" { sawCompletion = true }
                        case "stderrTail":
                            if let payload = event.payloadDictionary,
                               let text = payload["text"] as? String
                            {
                                stderrTail = text
                            }
                        case "processExited":
                            let payload = event.payloadDictionary
                            let exitCode = (payload?["exit_code"] as? NSNumber)?.int32Value
                            let timedOut = payload?["timed_out"] as? Bool == true
                            guard sawCompletion else {
                                if timedOut {
                                    throw AIProviderError.invalidConfiguration(
                                        detail: "Claude CLI timed out. Please retry shortly."
                                    )
                                }
                                if let exitCode, exitCode != 0 {
                                    throw mapProcessFailure(exitCode: exitCode, stderr: stderrTail)
                                }
                                throw AIProviderError.apiError(
                                    source: NSError(
                                        domain: "ClaudeCLI",
                                        code: Int(exitCode ?? -1),
                                        userInfo: [
                                            NSLocalizedDescriptionKey: stderrTail.isEmpty
                                                ? "Claude CLI exited before reporting a completion result."
                                                : stderrTail
                                        ]
                                    )
                                )
                            }
                            break eventLoop
                        default:
                            continue
                        }
                        if sawCompletion { break }
                    }
                    if !sawCompletion {
                        throw AIProviderError.apiError(
                            source: NSError(
                                domain: "ClaudeCLI",
                                code: -999,
                                userInfo: [NSLocalizedDescriptionKey: "Claude CLI did not report a completion result."]
                            )
                        )
                    }
                    await session.shutdown()
                    activeSession = nil
                    try? await eventStream.close()
                    await toolTracking.stopTracking()
                    continuation.finish()
                } catch {
                    // Errors are terminal for the Rust scope as well as the Swift stream. Keep
                    // shutdown explicit so malformed output, early exit, and bridge failures do
                    // not leave a child process behind after the continuation fails.
                    await activeSession?.shutdown()
                    activeSession = nil
                    await toolTracking.stopTracking()
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.streamTask?.cancel()
                Task { await self?.activeSession?.shutdown() }
            }
        }
    }

    func dispose() async {
        streamTask?.cancel()
        await activeSession?.shutdown()
        activeSession = nil
        await toolTracking.stopTracking()
    }

    private func cleanup(context: HeadlessAgentContext) async {
        context.configLease?.release()
    }

    private func decodeStreamResult(_ fields: [String: Any]) -> AIStreamResult? {
        guard let type = fields["type"] as? String else { return nil }
        let invocationID: UUID? = (fields["invocation_id"] as? NSNumber).map { value in
            let rustID = value.uint64Value
            if let existing = invocationUUIDByRustID[rustID] { return existing }
            let minted = UUID()
            invocationUUIDByRustID[rustID] = minted
            return minted
        }
        let provider = ClaudeCompatiblePluginStreamResult(
            type: type,
            text: fields["text"] as? String,
            reasoning: fields["reasoning"] as? String,
            promptTokens: (fields["prompt_tokens"] as? NSNumber)?.intValue,
            completionTokens: (fields["completion_tokens"] as? NSNumber)?.intValue,
            cost: (fields["cost"] as? NSNumber)?.doubleValue,
            toolName: fields["tool_name"] as? String,
            toolArgs: fields["tool_args"] as? String,
            toolOutput: fields["tool_output"] as? String,
            toolInvocationID: invocationID,
            toolResultJSON: fields["tool_result_json"] as? String,
            toolArgsJSON: fields["tool_args_json"] as? String,
            toolIsError: fields["tool_is_error"] as? Bool,
            providerSessionID: fields["provider_session_id"] as? String,
            stopReason: fields["stop_reason"] as? String,
            modelContextWindow: (fields["model_context_window"] as? NSNumber)?.intValue,
            contextUsedTokens: (fields["context_used_tokens"] as? NSNumber)?.intValue,
            contentMessageID: fields["content_message_id"] as? String
        )
        return ClaudeCompatiblePluginBridge.streamResult(from: provider)
    }

    private func mapError(_ error: Error) -> Error {
        if let core = error as? CoreBridgeError {
            return AIProviderError.apiError(source: core)
        }
        return error
    }

    private func mapProcessFailure(exitCode: Int32, stderr: String) -> Error {
        let lower = stderr.lowercased()
        if lower.contains("command not found") || lower.contains("no such file") {
            return AIProviderError.invalidConfiguration(detail: "Claude CLI not found. Install it and ensure it is available on PATH.")
        }
        if lower.contains("unauthorized") || lower.contains("login") {
            return AIProviderError.invalidConfiguration(detail: "Claude CLI not authenticated. Run `claude login` in a terminal and try again.")
        }
        if lower.contains("rate limit") || lower.contains("too many requests") {
            return AIProviderError.invalidConfiguration(detail: "Claude CLI rate limited. Please wait and retry.")
        }
        if stderr.isEmpty {
            return AIProviderError.apiError(
                source: NSError(
                    domain: "ClaudeCLI",
                    code: Int(exitCode),
                    userInfo: [NSLocalizedDescriptionKey: "Claude CLI exited with status \(exitCode)"]
                )
            )
        }
        return AIProviderError.apiError(
            source: NSError(domain: "ClaudeCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: stderr])
        )
    }
}
