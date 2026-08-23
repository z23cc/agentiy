import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

/// E-P6-2 Part A (design section 8 / contract section 5.1): spawn-attribute parity between
/// `ProcessLauncher.spawn` (this file, the **Swift arm**) and
/// `agent_claude_derisking_spike::spawn::spawn` (`rust/spikes/agent-claude-derisking-spike/tests/spawn_and_reaper.rs`,
/// the **Rust arm**), both launching the shared `probe` binary
/// (`rust/spikes/agent-claude-derisking-spike/bin/probe.rs`) with matching configurations.
///
/// **On "byte-identical" reports.** PID/PGID absolute values can never be byte-identical across
/// two independent spawns (the OS assigns them); this suite and its Rust counterpart each assert
/// the same *invocation-independent* property set (own-process-group, signal disposition/mask,
/// FD-table shape, `cwd`, visible env-key set, argv) against the same probe binary and
/// configuration list. Both green is the parity evidence recorded in
/// `rust/benchmarks/results/v1/p6-2-claude-derisking-v1.md` -- see that doc for why no single
/// harness diffs the two runners' raw output directly (no shared harness links `swift test` and
/// `cargo test` together in this repo).
///
/// **Configuration 1 of 9 ("with cwd") is intentionally absent.** `ProcessLauncher.spawn` supports
/// `workingDirectory` today (via `posix_spawn_file_actions_addchdir_np`); the Rust arm does not
/// yet, because that symbol has no `nix` wrapper and no `libc` declaration on Apple targets --
/// confirmed absent during this spike, and named a P6-4 (not P6-2) prerequisite by this task's
/// binding carry-forward. Testing `workingDirectory` only on the Swift side would not be a parity
/// check, so it is omitted here too and recorded as a deferred row in the results doc.
final class SpawnAttributeParityTests: XCTestCase {
    private struct FdReport: Decodable {
        let fd: Int32
        let cloexec: Bool
    }

    private struct ProbeReport: Decodable {
        let pid: Int32
        let pgid: Int32
        let sigpipe_disposition: String
        let blocked_signals: [Int32]
        let open_fds: [FdReport]
        let env_keys: [String]
        let argv: [String]
    }

    /// Built by `cargo build -p agent-claude-derisking-spike --bin probe` (see the P6-2 results
    /// doc's reproduction steps). Not built automatically here -- this is de-risking-spike
    /// evidence, not a production build dependency of the Swift test target.
    private func probeBinaryPath() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // drop filename -> .../ClaudeCompatible
            .deletingLastPathComponent() // ClaudeCompatible -> .../AgentMode
            .deletingLastPathComponent() // AgentMode -> .../RepoPromptTests
            .deletingLastPathComponent() // RepoPromptTests -> .../Tests
            .deletingLastPathComponent() // Tests -> repo root
        // The observed `cargo` target dir for this workspace-external spike resolves to a
        // `.build/cargo` sibling of the repo root (not `<repoRoot>/.build/cargo`) -- computed
        // relative to `repoRoot` rather than hardcoded with a machine-specific home directory.
        let candidates = [
            repoRoot.deletingLastPathComponent()
                .appendingPathComponent(".build/cargo/aarch64-apple-darwin/debug/probe").path,
            repoRoot.appendingPathComponent(".build/cargo/aarch64-apple-darwin/debug/probe").path,
            repoRoot.appendingPathComponent("rust/spikes/agent-claude-derisking-spike/target/debug/probe").path
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw XCTSkip(
            "probe binary not found in any candidate path (\(candidates)) -- run "
                + "`cargo build -p agent-claude-derisking-spike --bin probe` first"
        )
    }

    /// Spawns the probe, captures its one-line JSON report, blocking-reaps it with a raw
    /// `waitpid` (test cleanup only -- not exercising `ChildStatusReaperRegistry`, which is Part
    /// B/Rust-reaper territory, not Part A's attribute-parity concern), and returns the report.
    private func spawnProbeAndCapture(
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> ProbeReport {
        let spawned = try ProcessLauncher.spawn(
            command: probeBinaryPath(),
            arguments: arguments,
            environment: environment,
            workingDirectory: nil
        )
        let data = spawned.stdout.readDataToEndOfFile()
        var status: Int32 = 0
        let waited = waitpid(spawned.pid, &status, 0)
        XCTAssertEqual(waited, spawned.pid, "waitpid must reap the spawned probe")
        XCTAssertTrue(status == 0, "probe must exit 0, raw status=\(status)")
        return try JSONDecoder().decode(ProbeReport.self, from: data)
    }

    func testConfig1BaselineNoEnv() throws {
        let report = try spawnProbeAndCapture()
        XCTAssertEqual(report.pgid, report.pid, "spawned process must be its own group leader")
        XCTAssertEqual(report.sigpipe_disposition, "default")
        XCTAssertFalse(report.blocked_signals.contains(SIGCHLD), "SIGCHLD must not be blocked (empty sigmask)")
        XCTAssertTrue(report.env_keys.isEmpty, "empty environment map must not inherit the parent's env")
        for expected: Int32 in [0, 1, 2] {
            let fd = try XCTUnwrap(report.open_fds.first { $0.fd == expected }, "fd \(expected) must be present")
            XCTAssertFalse(fd.cloexec, "fd \(expected) (dup2 target) must not be FD_CLOEXEC")
        }
    }

    func testConfig2WithCustomEnvKey() throws {
        let report = try spawnProbeAndCapture(environment: ["AGENT_CLAUDE_SPIKE_PROBE_VAR": "probe-value"])
        XCTAssertEqual(report.env_keys, ["AGENT_CLAUDE_SPIKE_PROBE_VAR"])
    }

    func testConfig3WithoutEnvDoesNotInheritParent() throws {
        // Sanity: the *test process itself* has a non-empty environment, so an empty report is
        // real evidence of "full replacement, not merge".
        XCTAssertFalse(ProcessInfo.processInfo.environment.isEmpty)
        let report = try spawnProbeAndCapture()
        XCTAssertTrue(report.env_keys.isEmpty)
    }

    func testConfig4DeepArgv() throws {
        let args = (0 ..< 64).map { "--arg-\($0)=value-\($0)" }
        let report = try spawnProbeAndCapture(arguments: args)
        XCTAssertEqual(Array(report.argv.dropFirst()), args)
    }

    func testConfig5ArgvSpacesAndUTF8() throws {
        let args = ["an argument with spaces", "日本語の引数", "emoji-🦀-argument"]
        let report = try spawnProbeAndCapture(arguments: args)
        XCTAssertEqual(Array(report.argv.dropFirst()), args)
    }

    func testConfig6MissingBinary() throws {
        XCTAssertThrowsError(
            try ProcessLauncher.spawn(
                command: "/definitely/not/a/real/path/agent-claude-spike-missing-binary",
                arguments: [],
                environment: [:],
                workingDirectory: nil
            )
        ) { error in
            guard case let ProcessLauncherError.spawnFailed(errnoValue) = error else {
                return XCTFail("expected .spawnFailed, got \(error)")
            }
            XCTAssertEqual(errnoValue, ENOENT)
        }
    }

    func testConfig7NonExecutableBinary() throws {
        let path = NSTemporaryDirectory() + "agent-claude-spike-non-exec-\(ProcessInfo.processInfo.processIdentifier)"
        FileManager.default.createFile(atPath: path, contents: Data("not executable\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(
            try ProcessLauncher.spawn(command: path, arguments: [], environment: [:], workingDirectory: nil)
        ) { error in
            guard case let ProcessLauncherError.spawnFailed(errnoValue) = error else {
                return XCTFail("expected .spawnFailed, got \(error)")
            }
            XCTAssertEqual(errnoValue, EACCES)
        }
    }

    func testConfig8ShellForksGrandchildSameGroup() throws {
        let marker = NSTemporaryDirectory() + "agent-claude-spike-grandchild-swift-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.removeItem(atPath: marker)
        let spawned = try ProcessLauncher.spawn(
            command: "/bin/sh",
            arguments: ["-c", "(sleep 1; /bin/echo grandchild-ran > \(marker)) & exit 0"],
            environment: [:],
            workingDirectory: nil
        )
        var status: Int32 = 0
        let waited = waitpid(spawned.pid, &status, 0)
        XCTAssertEqual(waited, spawned.pid)
        XCTAssertTrue(status == 0)

        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker),
            "grandchild must have survived the root's exit and completed"
        )
        try? FileManager.default.removeItem(atPath: marker)
    }
}
