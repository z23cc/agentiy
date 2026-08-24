import Foundation
@testable import RepoPromptApp
import XCTest

/// P6-7 (`docs/designs/p6-claude-vertical-2026-08-23.md` §3.4/§11 P6-7): the turn-level
/// differential -- "identical input stream => identical ordered `AIStreamResult`s, turn IDs,
/// statuses, approval requests, `providerSessionID`". Drives **both** arms
/// (`ClaudeNativeProcessSessionController`, the still-authoritative Swift arm, and
/// `ClaudeRustBackedNativeSessionAdapter`, the DEBUG-only Rust-backed arm) against the **same**
/// real child process -- `agent-claude-synthetic-cli`'s `scripted` mode
/// (`rust/crates/runtime/tests/support/synthetic_cli.rs`) -- through the identical
/// `NativeAgentRuntimeControlling` contract: real spawn, real EOF/shutdown, no in-process
/// parsing shortcut. This is the harness this session's task brief names explicitly: "drive BOTH
/// arms via the synthetic CLI's scripted/OUT mechanism (real process, real EOF/shutdown), NOT
/// in-process parsing".
///
/// **How the same synthetic-CLI binary is driven identically by two different `buildArguments`
/// implementations.** Neither `ClaudeNativeProcessSessionController.buildArguments` (Swift) nor
/// `agent_claude::scope::build_arguments` (Rust) has a raw-argv escape hatch in production, and
/// this test does not want one -- both must exercise their real, unmodified argv-construction
/// path. `synthetic_cli.rs` is built for exactly this: `AGENT_CLAUDE_SYNTHETIC_CLI_ARGS`, when
/// set, overrides the binary's mode/args from an environment variable instead of positional argv,
/// entirely independent of what argv it actually received. `ScriptedSyntheticCLIEnvironmentResolver`
/// (below) injects that one environment variable through each arm's existing
/// `ClaudeCodeLaunchEnvironmentResolving` seam -- the same injection point production code uses
/// for Keychain/backend-config resolution -- so both arms launch through their real, unmodified
/// spawn path pointed at the same script.
final class ClaudeRustBackedTurnLevelDifferentialTests: XCTestCase {
    // MARK: - Canonical, arm-agnostic event representation

    /// `AIStreamResult` minus `toolInvocationID` (an arm-local `UUID`, never comparable by value
    /// across arms -- normalized to a first-appearance ordinal instead, mirroring
    /// `ClaudeCodecShadowComparator`'s and the P6-7 adapter's own documented structural exclusion)
    /// and `cleanupHandle` (always nil on both arms here, never set by either).
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
            events.contains { if case .turnCompleted = $0 { true } else { false } }
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
            if let existing = map[id] { return existing }
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

    /// Injects `AGENT_CLAUDE_SYNTHETIC_CLI_ARGS` through the real `ClaudeCodeLaunchEnvironmentResolving`
    /// seam both arms already accept as a constructor dependency -- see this file's top doc comment.
    private struct ScriptedSyntheticCLIEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
        let overrides: [String: String]

        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel _: String?) async throws -> ClaudeCodeLaunchEnvironment {
            ClaudeCodeLaunchEnvironment(effectiveModel: nil, environmentOverrides: overrides, backend: .defaultClaude)
        }
    }

    // MARK: - Fixtures

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

    private func makeConfig(commandPath: String) -> ClaudeCodeAgentConfig {
        .agentMode(
            commandName: commandPath,
            permissionMode: "default",
            allowNativeBashTool: false,
            disallowedBuiltInTools: [],
            mcpStrictMode: false,
            toolSearchEnabled: false
        )
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

    func testIdenticalScriptedTurnProducesAnIdenticalCanonicalEventSequenceAcrossBothArms() async throws {
        // Both arms' `startOrResume` require the embedded MCP server to be reachable before
        // spawning (Swift's `prepareRuntimeIfNeeded` hard-requires it; the Rust adapter's own MCP
        // config lease acquisition is best-effort but still calls into the same service). Other
        // suites already start it and leave it running for the rest of the process
        // (`CodexMCPRoutingReadinessTests`'s convention); starting it here as well makes this test
        // independent of run order/filtering.
        _ = await ServerNetworkManager.shared.start()
        let cliPath = try syntheticCLIPath()
        let sessionID = "p6-7-diff-session-\(UUID().uuidString.prefix(8))"
        let scriptURL = try writeScript([
            // P6-7 (§15.5): both arms now perform a real session-startup control-request round
            // trip before `startOrResume` returns (Swift always did; the Rust arm's `initialize`
            // handshake -- plus `set_permission_mode`, since `makeConfig` below sets a non-empty
            // `permissionMode` -- closed the gap this margin needs to outlast). 500 ms is the
            // margin `ClaudeRustBackedNativeSessionAdapter`'s own outer-deadline comments and this
            // suite's other cross-process synchronization already use as "comfortably generous
            // under parallel-test-run contention"; 200 ms measured flaky under `--filter Claude`'s
            // full concurrent load (both arms' handshakes racing the script's own OUT lines).
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

        let swiftConfig = makeConfig(commandPath: cliPath)
        let swiftController = ClaudeNativeProcessSessionController(
            runID: runID,
            tabID: tabID,
            windowID: 1,
            workspacePath: workspacePath,
            config: swiftConfig,
            environmentResolver: resolver
        )

        let rustConfig = makeConfig(commandPath: cliPath)
        let rustController = ClaudeRustBackedNativeSessionAdapter(
            runID: runID,
            tabID: tabID,
            workspacePath: workspacePath,
            config: rustConfig,
            runtimeConfig: ClaudeCompatiblePluginBridge.runtimeConfig(from: rustConfig, mode: .agentMode),
            environmentResolver: resolver
        )

        let swiftCollector = try await drive(controller: swiftController)
        let rustCollector = try await drive(controller: rustController)

        let swiftEvents = await swiftCollector.events
        let rustEvents = await rustCollector.events

        XCTAssertFalse(swiftEvents.isEmpty, "Swift arm must have produced events for a well-formed scripted turn")
        XCTAssertFalse(rustEvents.isEmpty, "Rust arm must have produced events for a well-formed scripted turn")
        XCTAssertEqual(
            swiftEvents,
            rustEvents,
            "Rust-backed arm must produce an identical canonical event sequence to the Swift arm for the same scripted turn"
        )

        XCTAssertEqual(swiftEvents.count(where: { if case .turnCompleted = $0 { true } else { false } }), 1)
        guard case let .turnCompleted(_, status) = swiftEvents.first(where: {
            if case .turnCompleted = $0 { true } else { false }
        }) else {
            return XCTFail("expected exactly one turnCompleted event")
        }
        XCTAssertEqual(status, "completed", "the idle-released turn must complete with .completed, not fall back to timedOut")

        // design's "identical providerSessionID" requirement, checked explicitly (not merely
        // implied by cross-arm event equality): the message_stop result on both arms must carry
        // the literal session id the script declared.
        let messageStopEvents = swiftEvents.compactMap { event -> String?? in
            if case let .stream(result) = event, result.type == "message_stop" { return result.providerSessionID }
            return nil
        }
        XCTAssertEqual(messageStopEvents.count, 1)
        XCTAssertEqual(messageStopEvents.first ?? nil, sessionID)
    }
}
