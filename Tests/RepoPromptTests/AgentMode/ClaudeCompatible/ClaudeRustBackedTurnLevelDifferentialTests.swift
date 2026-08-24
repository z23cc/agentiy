import Foundation
@testable import RepoPromptApp
import XCTest

/// P6-7...P6-10 (`docs/architecture/rust-agent-claude-v1.md` §15): post-cutover adapter
/// regressions over the real `agent-claude-synthetic-cli` child process. The class keeps its
/// historical differential name so existing focused filters remain stable, but P6-10 removed the
/// retired Swift runtime arm after its frozen corpus was transferred to Rust/golden assertions.
/// Every test still uses real spawn, EOF, shutdown, framing, bridge transport, and the production
/// `NativeAgentRuntimeControlling` façade; there is no in-process parsing shortcut.
///
/// `AGENT_CLAUDE_SYNTHETIC_CLI_ARGS` overrides only the synthetic binary's fixture mode while the
/// production Rust authority still builds its real argv. The launch recorder exposes only argv and
/// explicitly allowlisted environment keys, allowing stable post-oracle contract assertions without
/// logging ambient credentials.
final class ClaudeRustBackedTurnLevelDifferentialTests: XCTestCase {
    // MARK: - Canonical, arm-agnostic event representation

    /// Canonical event representation retained from the original two-arm differential. Invocation
    /// IDs are normalized to first-appearance ordinals so correlation is asserted without pinning
    /// runtime-generated UUID values; `cleanupHandle` remains outside the wire contract.
    private struct CanonicalStreamResult: Equatable {
        let type: String
        let text: String?
        let reasoning: String?
        let promptTokens: Int?
        let completionTokens: Int?
        let cost: Double?
        let toolName: String?
        let toolArgs: String?
        let toolOutput: String?
        let toolInvocationOrdinal: Int?
        let toolResultJSON: String?
        let toolArgsJSON: String?
        let toolIsError: Bool?
        let providerSessionID: String?
        let stopReason: String?
        let modelContextWindow: Int?
        let contextUsedTokens: Int?
        let contentMessageID: String?
    }

    private enum CanonicalEvent: Equatable {
        case stream(CanonicalStreamResult)
        case approvalRequest(method: String, kind: String, command: String?, cwd: String?, grantRoot: String?, reason: String?)
        case approvalCancelled
        case turnCompleted(turnOrdinal: Int, status: String)
        case error(String)
    }

    /// Collects one arm's `NativeAgentRuntimeEvent`s into the canonical form above.
    /// `.runtimeInit` is deliberately not collected: the P6-7 adapter's doc comment names its
    /// `RuntimeInitStatus` reconstruction as out of scope for this differential (no tool/MCP-status
    /// wire fields exist yet), so comparing it would fail on a known, already-documented gap rather
    /// than a real regression.
    private actor DifferentialCollector {
        private(set) var events: [CanonicalEvent] = []
        private var turnOrdinalByID: [UUID: Int] = [:]
        private var invocationOrdinalByID: [UUID: Int] = [:]

        func consume(_ event: NativeAgentRuntimeEvent) {
            switch event {
            case let .stream(result):
                events.append(.stream(canonicalize(result)))
            case .runtimeInit:
                break
            case let .approvalRequest(request):
                events.append(.approvalRequest(
                    method: request.method,
                    kind: request.kind.rawValue,
                    command: request.command,
                    cwd: request.cwd,
                    grantRoot: request.grantRoot,
                    reason: request.reason
                ))
            case .approvalCancelled:
                events.append(.approvalCancelled)
            case let .turnCompleted(turnID, status):
                events.append(.turnCompleted(turnOrdinal: ordinal(for: turnID, in: &turnOrdinalByID), status: statusName(status)))
            case let .error(message):
                events.append(.error(message))
            }
        }

        var hasCompletedATurn: Bool {
            events.contains {
                if case .turnCompleted = $0 {
                    true
                } else {
                    false
                }
            }
        }

        var completedTurnCount: Int {
            events.count {
                if case .turnCompleted = $0 {
                    true
                } else {
                    false
                }
            }
        }

        private func canonicalize(_ result: AIStreamResult) -> CanonicalStreamResult {
            CanonicalStreamResult(
                type: result.type,
                text: result.text,
                reasoning: result.reasoning,
                promptTokens: result.promptTokens,
                completionTokens: result.completionTokens,
                cost: result.cost,
                toolName: result.toolName,
                toolArgs: result.toolArgs,
                toolOutput: result.toolOutput,
                toolInvocationOrdinal: result.toolInvocationID.map { ordinal(for: $0, in: &invocationOrdinalByID) },
                toolResultJSON: result.toolResultJSON,
                toolArgsJSON: result.toolArgsJSON,
                toolIsError: result.toolIsError,
                providerSessionID: result.providerSessionID,
                stopReason: result.stopReason,
                modelContextWindow: result.modelContextWindow,
                contextUsedTokens: result.contextUsedTokens,
                contentMessageID: result.contentMessageID
            )
        }

        private func ordinal(for id: UUID, in map: inout [UUID: Int]) -> Int {
            if let existing = map[id] {
                return existing
            }
            let next = map.count
            map[id] = next
            return next
        }

        private func statusName(_ status: NativeAgentRuntimeTurnStatus) -> String {
            switch status {
            case .completed: "completed"
            case .cancelled: "cancelled"
            case .failed: "failed"
            }
        }
    }

    private struct PermissionFailureSnapshot {
        let requestID: String?
        let errors: [String]
    }

    private actor PermissionFailureCollector {
        private var requestID: String?
        private var errors: [String] = []

        func consume(_ event: NativeAgentRuntimeEvent) {
            switch event {
            case let .approvalRequest(request):
                if case let .claudeControl(identifier) = request.requestID {
                    requestID = identifier
                }
            case let .error(message):
                errors.append(message)
            default:
                break
            }
        }

        func snapshot() -> PermissionFailureSnapshot {
            PermissionFailureSnapshot(requestID: requestID, errors: errors)
        }
    }

    private enum ExpectedPIDEvent: Equatable {
        case registered(pid: pid_t, clientName: String, runID: UUID)
        case cleared(pid: pid_t, clientName: String, runID: UUID)
    }

    private actor ExpectedPIDRecorder {
        private var events: [ExpectedPIDEvent] = []

        nonisolated var registrar: ClaudeRustBackedNativeSessionAdapter.ExpectedAgentPIDRegistrar {
            .init(
                register: { [weak self] pid, clientName, runID in
                    await self?.record(.registered(pid: pid, clientName: clientName, runID: runID))
                },
                clear: { [weak self] pid, clientName, runID in
                    await self?.record(.cleared(pid: pid, clientName: clientName, runID: runID))
                }
            )
        }

        func snapshot() -> [ExpectedPIDEvent] {
            events
        }

        private func record(_ event: ExpectedPIDEvent) {
            events.append(event)
        }
    }

    /// Injects synthetic fixture facts through the production
    /// `ClaudeCodeLaunchEnvironmentResolving` constructor seam.
    private struct ScriptedSyntheticCLIEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
        let overrides: [String: String]

        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel _: String?) async throws -> ClaudeCodeLaunchEnvironment {
            ClaudeCodeLaunchEnvironment(effectiveModel: nil, environmentOverrides: overrides, backend: .defaultClaude)
        }
    }

    private struct SwitchingSyntheticCLIEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
        let syntheticCLIArguments: String

        func resolve(
            variant _: ClaudeCodeRuntimeVariant,
            requestedModel: String?
        ) async throws -> ClaudeCodeLaunchEnvironment {
            var overrides = ["AGENT_CLAUDE_SYNTHETIC_CLI_ARGS": syntheticCLIArguments]
            if requestedModel == "alternate-model" {
                overrides["AGENTRY_TEST_BACKEND"] = "alternate"
            }
            return ClaudeCodeLaunchEnvironment(
                effectiveModel: requestedModel,
                environmentOverrides: overrides,
                backend: .defaultClaude
            )
        }
    }

    // MARK: - Fixtures

    private struct SyntheticLaunchRecord: Decodable, Equatable {
        let argv: [String]
        let environment: [String: String]
    }

    private func syntheticCLIPath() throws -> String {
        let repoRoot = try RepoRoot.url()
        let path = repoRoot
            .appendingPathComponent(".build/cargo/aarch64-apple-darwin/debug/agent-claude-synthetic-cli")
            .path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip(
                "agent-claude-synthetic-cli not found at \(path) -- run `make dev-cargo-build` or "
                    + "`make dev-cargo-test CARGO_PACKAGE=all` first"
            )
        }
        return path
    }

    private func writeScript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p6-7-differential-\(UUID().uuidString).script")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeConfig(
        commandPath: String,
        runtimeVariant: ClaudeCodeRuntimeVariant = .standard
    ) -> ClaudeCodeAgentConfig {
        .agentMode(
            commandName: commandPath,
            runtimeVariant: runtimeVariant,
            permissionMode: "default",
            allowNativeBashTool: false,
            disallowedBuiltInTools: [],
            mcpStrictMode: false,
            toolSearchEnabled: false
        )
    }

    private func readLaunchRecord(at url: URL) throws -> SyntheticLaunchRecord {
        try JSONDecoder().decode(SyntheticLaunchRecord.self, from: Data(contentsOf: url))
    }

    private func normalizedLaunchArguments(_ arguments: [String]) -> [String] {
        var normalized = arguments
        if let index = normalized.firstIndex(of: "--mcp-config"), normalized.indices.contains(index + 1) {
            normalized[index + 1] = "<host-owned-mcp-config>"
        }
        return normalized
    }

    private func expectedLaunchArguments(for variant: ClaudeCodeRuntimeVariant) -> [String] {
        var arguments = [
            "-p",
            "--verbose",
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--permission-prompt-tool",
            "stdio"
        ]
        if variant == .glm {
            arguments += ["--append-system-prompt", "Running within this desktop app."]
        }
        arguments += ["--mcp-config", "<host-owned-mcp-config>"]
        return arguments
    }

    /// Drives one arm through a full session lifecycle against the scripted synthetic CLI: start,
    /// send one user message, auto-accept any approval request, wait for the turn to complete (or
    /// time out), then shut down -- real process, real EOF/shutdown throughout.
    private func drive(controller: any NativeAgentRuntimeControlling) async throws -> DifferentialCollector {
        let collector = DifferentialCollector()
        await controller.ensureEventsStreamReady()
        let eventsStream = await controller.events
        let pumpTask = Task {
            for await event in eventsStream {
                if case let .approvalRequest(request) = event,
                   case let .claudeControl(requestID) = request.requestID
                {
                    await controller.respondToPermissionRequest(id: requestID, decision: .accept)
                }
                await collector.consume(event)
            }
        }
        _ = try await controller.startOrResume(
            existingSessionID: nil,
            model: nil,
            effortLevel: nil,
            systemPromptOverride: nil
        )
        _ = try await controller.sendUserMessage("run the differential turn")

        let deadline = Date().addingTimeInterval(10)
        while await !collector.hasCompletedATurn, Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        await controller.shutdown()
        pumpTask.cancel()
        return collector
    }

    // MARK: - Tests

    func testLiveModelSwitchThatChangesLaunchEnvironmentRequiresRestart() async throws {
        _ = await ServerNetworkManager.shared.start()
        let cliPath = try syntheticCLIPath()
        let scriptURL = try writeScript(["SLEEP 5000"])
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let resolver = SwitchingSyntheticCLIEnvironmentResolver(
            syntheticCLIArguments: "scripted\n\(scriptURL.path)"
        )
        let config = makeConfig(commandPath: cliPath)
        let controller = ClaudeRustBackedNativeSessionAdapter(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: FileManager.default.temporaryDirectory.path,
            config: config,
            runtimeConfig: ClaudeCompatiblePluginBridge.runtimeConfig(from: config, mode: .agentMode),
            environmentResolver: resolver
        )

        _ = try await controller.startOrResume(
            existingSessionID: nil,
            model: nil,
            effortLevel: nil,
            systemPromptOverride: nil
        )
        do {
            try await controller.applyModelAndEffort(model: "alternate-model", effortLevel: nil)
            XCTFail("a launch-environment-changing live model switch must require restart")
        } catch NativeAgentRuntimeControllerError.liveModelSwitchRequiresRestart {
            // Expected.
        } catch {
            XCTFail("expected liveModelSwitchRequiresRestart, got \(error)")
        }
        await controller.shutdown()
    }

    func testCompatibleVariantsPreserveFrozenLaunchAndTurnContract() async throws {
        _ = await ServerNetworkManager.shared.start()
        let cliPath = try syntheticCLIPath()
        let variants: [ClaudeCodeRuntimeVariant] = [.glm, .kimi, .customCompatible]

        for variant in variants {
            let sessionID = "p6-9-\(variant.rawValue)-\(UUID().uuidString.prefix(8))"
            let scriptURL = try writeScript([
                "SLEEP 500",
                #"OUT {"type":"system","subtype":"init","session_id":"\#(sessionID)"}"#,
                #"OUT {"type":"assistant","message":{"content":[{"type":"text","text":"variant parity"}]}}"#,
                #"OUT {"type":"system","subtype":"session_state_changed","session_state":"running"}"#,
                // Non-idle session state is intentionally coalescible under pressure (§7.1). Pace
                // the next progress-class event so this launch/translation differential compares
                // both observable sequences rather than testing the separately frozen loss policy.
                "SLEEP 500",
                #"OUT {"type":"result","subtype":"success","session_id":"\#(sessionID)"}"#,
                #"OUT {"type":"system","subtype":"session_state_changed","session_state":"idle"}"#
            ])
            let launchURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("p6-9-rust-\(variant.rawValue)-\(UUID().uuidString).json")
            defer {
                try? FileManager.default.removeItem(at: scriptURL)
                try? FileManager.default.removeItem(at: launchURL)
            }

            let resolver = ScriptedSyntheticCLIEnvironmentResolver(overrides: [
                "AGENT_CLAUDE_SYNTHETIC_CLI_ARGS": "scripted\n\(scriptURL.path)",
                "AGENT_CLAUDE_SYNTHETIC_CLI_RECORD_LAUNCH_PATH": launchURL.path,
                "AGENT_CLAUDE_SYNTHETIC_CLI_RECORD_ENV_KEYS": "AGENTRY_VARIANT_SENTINEL,CLAUDE_CODE_ENTRYPOINT",
                "AGENTRY_VARIANT_SENTINEL": variant.rawValue
            ])
            let config = makeConfig(commandPath: cliPath, runtimeVariant: variant)
            let controller = ClaudeRustBackedNativeSessionAdapter(
                runID: UUID(),
                tabID: UUID(),
                windowID: 1,
                workspacePath: FileManager.default.temporaryDirectory.path,
                config: config,
                runtimeConfig: ClaudeCompatiblePluginBridge.runtimeConfig(from: config, mode: .agentMode),
                environmentResolver: resolver
            )

            let collector = try await drive(controller: controller)
            let events = await collector.events
            XCTAssertTrue(events.contains {
                if case let .turnCompleted(_, status) = $0 { return status == "completed" }
                return false
            }, "\(variant.rawValue) must complete its scripted turn")
            XCTAssertFalse(events.contains {
                if case .error = $0 { return true }
                return false
            })

            let launch = try readLaunchRecord(at: launchURL)
            XCTAssertEqual(
                normalizedLaunchArguments(launch.argv),
                expectedLaunchArguments(for: variant),
                "\(variant.rawValue) production argv drifted from the frozen P6-9 contract"
            )
            XCTAssertEqual(launch.environment["AGENTRY_VARIANT_SENTINEL"], variant.rawValue)
            XCTAssertEqual(launch.environment["CLAUDE_CODE_ENTRYPOINT"], "sdk-ts")
        }
    }

    func testRustArmRebuildsItsScopeAfterTheSupervisedProcessExits() async throws {
        _ = await ServerNetworkManager.shared.start()
        let cliPath = try syntheticCLIPath()
        let providerSessionID = "p6-8-restart-\(UUID().uuidString.prefix(8))"
        let scriptURL = try writeScript([
            "SLEEP 500",
            #"OUT {"type":"system","subtype":"init","session_id":"\#(providerSessionID)"}"#,
            #"OUT {"type":"assistant","message":{"content":[{"type":"text","text":"restart fixture"}]}}"#,
            #"OUT {"type":"result","subtype":"success","session_id":"\#(providerSessionID)"}"#
        ])
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let resolver = ScriptedSyntheticCLIEnvironmentResolver(
            overrides: ["AGENT_CLAUDE_SYNTHETIC_CLI_ARGS": "scripted\n\(scriptURL.path)"]
        )
        let config = makeConfig(commandPath: cliPath)
        let runID = UUID()
        let expectedPIDRecorder = ExpectedPIDRecorder()
        let controller = ClaudeRustBackedNativeSessionAdapter(
            runID: runID,
            tabID: UUID(),
            windowID: 1,
            workspacePath: FileManager.default.temporaryDirectory.path,
            config: config,
            runtimeConfig: ClaudeCompatiblePluginBridge.runtimeConfig(from: config, mode: .agentMode),
            environmentResolver: resolver,
            expectedAgentPIDRegistrar: expectedPIDRecorder.registrar
        )
        let collector = DifferentialCollector()
        await controller.ensureEventsStreamReady()
        let stream = await controller.events
        let pump = Task {
            for await event in stream {
                await collector.consume(event)
            }
        }
        defer { pump.cancel() }

        for expectedCount in 1 ... 2 {
            _ = try await controller.startOrResume(
                existingSessionID: expectedCount == 1 ? nil : providerSessionID,
                model: nil,
                effortLevel: nil,
                systemPromptOverride: nil
            )
            _ = try await controller.sendUserMessage("restart turn \(expectedCount)")

            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let completedTurnCount = await collector.completedTurnCount
                let hasActiveSession = await controller.hasActiveSession
                if completedTurnCount >= expectedCount, !hasActiveSession {
                    break
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let completedTurnCount = await collector.completedTurnCount
            let hasActiveSession = await controller.hasActiveSession
            XCTAssertEqual(completedTurnCount, expectedCount)
            XCTAssertFalse(hasActiveSession, "processExited must invalidate the dead Rust process before the next turn")

            let pidDeadline = Date().addingTimeInterval(3)
            var pidEvents = await expectedPIDRecorder.snapshot()
            while pidEvents.count < expectedCount * 2, Date() < pidDeadline {
                try await Task.sleep(nanoseconds: 25_000_000)
                pidEvents = await expectedPIDRecorder.snapshot()
            }
            XCTAssertEqual(pidEvents.count, expectedCount * 2)
        }

        await controller.shutdown()
        let pidEvents = await expectedPIDRecorder.snapshot()
        XCTAssertEqual(pidEvents.count, 4)
        for pairStart in stride(from: 0, to: pidEvents.count, by: 2) {
            guard case let .registered(pid, clientName, registeredRunID) = pidEvents[pairStart],
                  case let .cleared(clearedPID, clearedClientName, clearedRunID) = pidEvents[pairStart + 1]
            else {
                return XCTFail("each supervised child must register then clear one expected-PID fence")
            }
            XCTAssertGreaterThan(pid, 0)
            XCTAssertEqual(clearedPID, pid)
            XCTAssertEqual(clientName, AgentProviderKind.claudeMCPClientID)
            XCTAssertEqual(clearedClientName, clientName)
            XCTAssertEqual(registeredRunID, runID)
            XCTAssertEqual(clearedRunID, runID)
        }
    }

    func testInterruptOutcomeArrivingBeforeReceiptRegistrationIsRetained() async throws {
        _ = await ServerNetworkManager.shared.start()
        let cliPath = try syntheticCLIPath()
        let scriptURL = try writeScript([
            "AWAITACKS 2",
            "SLEEP 5000"
        ])
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let resolver = ScriptedSyntheticCLIEnvironmentResolver(
            overrides: ["AGENT_CLAUDE_SYNTHETIC_CLI_ARGS": "scripted\n\(scriptURL.path)"]
        )
        let config = makeConfig(commandPath: cliPath)
        let controller = ClaudeRustBackedNativeSessionAdapter(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: FileManager.default.temporaryDirectory.path,
            config: config,
            runtimeConfig: ClaudeCompatiblePluginBridge.runtimeConfig(from: config, mode: .agentMode),
            environmentResolver: resolver,
            interruptReceiptRegistrationHookForTesting: {
                // Rust's authoritative ACK deadline is 1.5 s. Holding registration for longer
                // guarantees the correlated event reaches the actor before the continuation exists;
                // without the early-outcome cache this call falls through to the 4 s outer timeout.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        )

        await controller.ensureEventsStreamReady()
        _ = try await controller.startOrResume(
            existingSessionID: nil,
            model: nil,
            effortLevel: nil,
            systemPromptOverride: nil
        )
        _ = try await controller.sendUserMessage("interrupt the early-outcome fixture")
        let startedAt = Date()
        let outcome = await controller.interruptTurn(reason: "early-outcome regression")
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertEqual(outcome, .acknowledged)
        XCTAssertLessThan(elapsed, 4, "the cached outcome must win before the adapter's outer timeout")
        await controller.shutdown()
    }

    func testFailedUserPermissionWriteEmitsTerminalErrorAndClosesScope() async throws {
        _ = await ServerNetworkManager.shared.start()
        let cliPath = try syntheticCLIPath()
        let scriptURL = try writeScript([
            "AWAITACKS 2",
            #"OUT {"type":"control_request","request_id":"perm-write-failure","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#,
            "SLEEP 100"
        ])
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let resolver = ScriptedSyntheticCLIEnvironmentResolver(
            overrides: ["AGENT_CLAUDE_SYNTHETIC_CLI_ARGS": "scripted\n\(scriptURL.path)"]
        )
        let config = makeConfig(commandPath: cliPath)
        let controller = ClaudeRustBackedNativeSessionAdapter(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: FileManager.default.temporaryDirectory.path,
            config: config,
            runtimeConfig: ClaudeCompatiblePluginBridge.runtimeConfig(from: config, mode: .agentMode),
            environmentResolver: resolver
        )
        let collector = PermissionFailureCollector()
        await controller.ensureEventsStreamReady()
        let stream = await controller.events
        let pump = Task {
            for await event in stream {
                await collector.consume(event)
            }
        }
        defer { pump.cancel() }

        _ = try await controller.startOrResume(
            existingSessionID: nil,
            model: nil,
            effortLevel: nil,
            systemPromptOverride: nil
        )
        let exitDeadline = Date().addingTimeInterval(5)
        var snapshot = await collector.snapshot()
        while Date() < exitDeadline {
            let hasActiveSession = await controller.hasActiveSession
            if snapshot.requestID != nil, !hasActiveSession {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
            snapshot = await collector.snapshot()
        }
        guard let requestID = snapshot.requestID else {
            await controller.shutdown()
            return XCTFail("expected the synthetic permission request before process exit")
        }
        let hasActiveSessionAfterEOF = await controller.hasActiveSession
        XCTAssertFalse(hasActiveSessionAfterEOF, "the fixture must close stdout before the user responds")

        await controller.respondToPermissionRequest(id: requestID, decision: .accept)
        let errorDeadline = Date().addingTimeInterval(5)
        snapshot = await collector.snapshot()
        while snapshot.errors.isEmpty, Date() < errorDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
            snapshot = await collector.snapshot()
        }
        XCTAssertTrue(
            snapshot.errors.contains { $0.contains("Failed to submit Claude approval decision") },
            "a failed user-selected response must surface the same terminal protocol error as the legacy controller"
        )
        let hasActiveSessionAfterFailure = await controller.hasActiveSession
        XCTAssertFalse(hasActiveSessionAfterFailure)
        await controller.shutdown()
    }

    func testScriptedTurnProducesTheFrozenCanonicalEventSequence() async throws {
        // `startOrResume` requires the embedded MCP server to be reachable before spawning; the
        // Rust adapter's MCP config lease acquisition calls into the same service. Other
        // suites already start it and leave it running for the rest of the process
        // (`CodexMCPRoutingReadinessTests`'s convention); starting it here as well makes this test
        // independent of run order/filtering.
        _ = await ServerNetworkManager.shared.start()
        let cliPath = try syntheticCLIPath()
        let sessionID = "p6-7-diff-session-\(UUID().uuidString.prefix(8))"
        let scriptURL = try writeScript([
            // P6-7 (§15.5): the Rust authority performs a real session-startup control-request
            // round trip before `startOrResume` returns. Its `initialize` handshake plus
            // `set_permission_mode`, since `makeConfig` below sets a non-empty
            // `permissionMode` -- closed the gap this margin needs to outlast). 500 ms is the
            // margin `ClaudeRustBackedNativeSessionAdapter`'s own outer-deadline comments and this
            // suite's other cross-process synchronization already use as "comfortably generous
            // under parallel-test-run contention"; 200 ms measured flaky under `--filter Claude`'s
            // full concurrent load. The old ordering inversion is no longer sleep-mitigated:
            // §15.7 root-caused it to overlapping, actor-reentrant bridge drainers and made wake
            // draining single-flight. This delay now serves only as a startup/handshake scheduling
            // margin; the Rust scope order test, gated bridge regression, and this differential pin
            // event ordering independently of wall-clock spacing.
            "SLEEP 500",
            #"OUT {"type":"system","subtype":"init","session_id":"\#(sessionID)"}"#,
            #"OUT {"type":"assistant","message":{"content":[{"type":"text","text":"Hello from the differential"}]}}"#,
            #"OUT {"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"OUT {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"file1\nfile2"}]}}"#,
            #"OUT {"type":"control_request","request_id":"perm-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf /tmp/x"},"description":"remove scratch dir"}}"#,
            #"OUT {"type":"system","subtype":"session_state_changed","session_state":"running"}"#,
            "SLEEP 150",
            #"OUT {"type":"result","subtype":"success","session_id":"\#(sessionID)","usage":{"input_tokens":10,"output_tokens":20}}"#,
            "SLEEP 150",
            #"OUT {"type":"system","subtype":"session_state_changed","session_state":"idle"}"#
        ])
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let resolver = ScriptedSyntheticCLIEnvironmentResolver(
            overrides: ["AGENT_CLAUDE_SYNTHETIC_CLI_ARGS": "scripted\n\(scriptURL.path)"]
        )
        let runID = UUID()
        let tabID = UUID()
        let workspacePath = FileManager.default.temporaryDirectory.path

        let config = makeConfig(commandPath: cliPath)
        let controller = ClaudeRustBackedNativeSessionAdapter(
            runID: runID,
            tabID: tabID,
            windowID: 1,
            workspacePath: workspacePath,
            config: config,
            runtimeConfig: ClaudeCompatiblePluginBridge.runtimeConfig(from: config, mode: .agentMode),
            environmentResolver: resolver
        )

        let collector = try await drive(controller: controller)
        let events = await collector.events

        XCTAssertFalse(events.isEmpty, "the Rust authority must produce events for a well-formed scripted turn")
        XCTAssertFalse(events.contains {
            if case .error = $0 { return true }
            return false
        })

        XCTAssertEqual(events.count(where: {
            if case .turnCompleted = $0 {
                true
            } else {
                false
            }
        }), 1)
        guard case let .turnCompleted(_, status) = events.first(where: {
            if case .turnCompleted = $0 {
                true
            } else {
                false
            }
        }) else {
            return XCTFail("expected exactly one turnCompleted event")
        }
        XCTAssertEqual(status, "completed", "the idle-released turn must complete with .completed, not fall back to timedOut")

        // The message_stop result must carry the literal provider session id the script declared.
        let messageStopEvents = events.compactMap { event -> String?? in
            if case let .stream(result) = event, result.type == "message_stop" {
                return result.providerSessionID
            }
            return nil
        }
        XCTAssertEqual(messageStopEvents.count, 1)
        XCTAssertEqual(messageStopEvents.first ?? nil, sessionID)
    }
}
