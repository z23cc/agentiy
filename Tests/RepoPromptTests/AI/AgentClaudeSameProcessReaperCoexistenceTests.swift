import AgentryCoreBridge
@testable import RepoPromptApp
import XCTest

/// P6-6 (`docs/designs/p6-claude-vertical-2026-08-23.md` §4.2, `docs/architecture/
/// rust-agent-claude-v1.md` §5.2): the same-process Swift/Rust reaper coexistence obligation the
/// campaign carries forward to this slice ("explicitly deferred to the FFI-bridge slice"). Drives a
/// Rust-supervised child through the real `CoreAgentSession`/FFI bridge while Swift's own
/// `ProcessTermination`/`ChildStatusReaperRegistry` reaps a *separate* child, concurrently, in this
/// one test process -- proving the two sole-reaper-owner sets are genuinely disjoint by PID (design
/// §4.2: "the two reap-ownership sets... are disjoint by PID; neither can steal from the other").
/// The complementary "no SIGCHLD handler is installed" half of contract §5.2 is proven in isolation
/// by `rust/crates/runtime/tests/agent_claude_process_coexistence_hostile.rs` -- not repeated here,
/// since the full app test bundle links unrelated dependencies that could install a handler for a
/// reason unrelated to this slice, making that specific check unreliable at this layer (see the
/// comment at its would-be call site below for the full reasoning).
final class AgentClaudeSameProcessReaperCoexistenceTests: XCTestCase {
    func testRustSupervisedAndSwiftSupervisedChildrenReapConcurrentlyWithoutCrossAttribution() async throws {
        // Swift side: a real child through the shared `ProcessLauncher`/`ProcessTermination` path,
        // exercising coexistence with Rust's Claude child reaper in the same host process.
        let swiftChild = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "sleep 1; exit 0"],
            environment: [:],
            workingDirectory: nil
        )
        swiftChild.stdin?.closeFile()
        let swiftObserver = ChildProcessExitObserver(pid: swiftChild.pid)

        // Rust side: a real agent-claude scope through the actual FFI bridge (not a fake
        // transport) -- what this test needs is a real `posix_spawn` + a real Rust-side reap
        // happening concurrently with the Swift side above, in this one process. `/bin/sleep` was
        // an inert stand-in pre-P6-7-§15.5: `start_or_resume` did not yet send anything requiring a
        // response, so any real child sufficed. It now blocks on the session-startup `initialize`
        // handshake (contract §2.5) before returning, and `/bin/sleep` cannot answer it (it exits
        // almost immediately on the injected `-p --verbose ...` flags it does not understand) --
        // this needs the real synthetic CLI in `scripted` mode instead, matching the Rust-side
        // fix for the same gap (`rust/crates/ffi/src/api.rs`'s agent-claude tests).
        let cliPath = try syntheticCLIPath()
        let script = try writeScript("SLEEP 3000\n")
        let bridge = try await AgentryCoreBridge.start()
        let session = try await CoreAgentSession.open(
            bridge: bridge,
            config: CoreAgentSessionConfig(
                command: cliPath,
                environment: ["AGENT_CLAUDE_SYNTHETIC_CLI_ARGS": "scripted\n\(script.path)"]
            )
        )
        defer { try? FileManager.default.removeItem(at: script) }
        let rustReceipt = try await session.startOrResume()
        XCTAssertGreaterThan(rustReceipt.pid, 0)

        async let swiftOutcome = swiftObserver.wait(timeout: 5)
        async let rustShutdown: Void = session.close()
        let (outcome, _) = await (swiftOutcome, rustShutdown)

        XCTAssertNotNil(outcome, "the Swift-supervised child must still be reaped correctly while a Rust-supervised child reaps concurrently")
        if case let .exited(status)? = outcome {
            XCTAssertEqual(status, .exited(code: 0))
        }

        // Deliberately NOT re-asserting "no SIGCHLD handler installed" here: unlike the Rust side's
        // clean, minimal cargo-test process (`rust/crates/runtime/tests/
        // agent_claude_process_coexistence_hostile.rs`, which owns and passes this exact assertion
        // in isolation), the full `RepoPromptTests` XCTest bundle links the whole app's dependency
        // graph -- a handler installed by an unrelated linked library for an unrelated reason would
        // make this a false positive against *this* slice's own code, not a real regression. The
        // load-bearing proof this test exists for -- neither reaper starves, blocks, or
        // cross-attributes the other's PID when both run in one process concurrently -- is the
        // assertion above.
    }

    // MARK: - Fixtures

    /// Mirrors `ClaudeRustBackedTurnLevelDifferentialTests`'s identically named helper.
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

    private func writeScript(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p6-7-reaper-coexistence-\(UUID().uuidString).script")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
