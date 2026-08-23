import Foundation
@testable import RepoPromptApp
import XCTest

/// P6-5 (`docs/designs/p6-claude-vertical-2026-08-23.md` P6-5's done-when): the DEBUG shadow arm's
/// zero-mismatch gate.
///
/// **What this file proves, and what it explicitly does not (named per the campaign's
/// execute-on-synthetic + blocked-named handling).** The done-when calls for "the shadow arm
/// reports zero mismatches over a real multi-turn working session including at least one
/// interrupt, one approval and one tool-heavy turn" -- that is real traffic against the actual
/// `claude` CLI, which is user-blocked (inherited carry-forward E-P6-1(a)/(b), same root cause
/// recorded in `rust/benchmarks/results/v1/p6-2-claude-derisking-v1.md` §7). This file instead
/// replays the frozen P6-3 synthetic corpus (`rust/crates/runtime/tests/fixtures/claude-ndjson/v1/
/// synthetic/`) through the controller's REAL `handleLine` dispatch (`test_handleLine`, not a
/// harness that bypasses it), and asserts zero mismatches -- the execute-on-synthetic half of the
/// gate. The real-session half remains blocked; see this session's final report for the exact
/// remaining step.
final class ClaudeCodecShadowComparatorTests: XCTestCase {
    private func makeController(enableComparator: Bool) -> ClaudeNativeProcessSessionController {
        ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            enableClaudeCodecShadowComparator: enableComparator
        )
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../ClaudeCompatible
            .deletingLastPathComponent() // .../AgentMode
            .deletingLastPathComponent() // .../Tests/RepoPromptTests
            .deletingLastPathComponent() // .../Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("rust/crates/runtime/tests/fixtures/claude-ndjson/v1/synthetic")
            .appendingPathComponent(name)
    }

    private func fixtureLines(_ name: String) throws -> [Data] {
        let raw = try Data(contentsOf: fixtureURL(name))
        return raw.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }.map(Data.init)
    }

    // MARK: - Opt-in-only, matching the established shadow-arm mechanism

    func testComparatorDefaultsToDisabled() async {
        let controller = makeController(enableComparator: false)
        await controller.test_handleLine(Data(#"{"type":"system","subtype":"status","status":"hi"}"#.utf8))
        let mismatches = await controller.test_claudeCodecShadowComparatorMismatches()
        let compared = await controller.test_claudeCodecShadowComparatorComparedCount()
        XCTAssertEqual(mismatches, [], "a disabled comparator must never report anything")
        XCTAssertEqual(compared, 0, "a disabled comparator must never compare anything")
    }

    /// Mirrors `WorkspaceInventoryScopeShadowTests
    /// .testShadowArmParameterIsAbsentFromTheReleaseInitializer` (design doc §3.4 precedent):
    /// source-text inspection proving the release initializer overload (the `#else` branch) never
    /// declares `enableClaudeCodecShadowComparator`.
    func testShadowComparatorParameterIsAbsentFromTheReleaseInitializer() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../ClaudeCompatible
            .deletingLastPathComponent() // .../AgentMode
            .deletingLastPathComponent() // .../Tests/RepoPromptTests
            .deletingLastPathComponent() // .../Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(
                "Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard let anchorRange = source.range(of: "enableClaudeCodecShadowComparator: Bool = false"),
              let elseRange = source.range(of: "\n    #else\n", range: anchorRange.upperBound ..< source.endIndex),
              let endIfRange = source.range(of: "\n    #endif\n", range: elseRange.upperBound ..< source.endIndex)
        else {
            XCTFail("Could not locate the controller's #if DEBUG / #else / #endif init region")
            return
        }
        let releaseInitSource = source[elseRange.upperBound ..< endIfRange.lowerBound]
        XCTAssertFalse(
            releaseInitSource.contains("enableClaudeCodecShadowComparator"),
            "The release initializer overload must not accept enableClaudeCodecShadowComparator"
        )
        XCTAssertFalse(
            releaseInitSource.contains("ClaudeCodecShadowComparator"),
            "The release initializer overload must never reference ClaudeCodecShadowComparator at all"
        )
    }

    // MARK: - Zero-mismatch over the synthetic corpus, through the real handleLine dispatch

    /// The well-formed, single-line, directly-comparable fixtures -- excludes the four D-1
    /// recovery-heuristic fixtures (`d1-*`), `non-utf8-bytes.ndjson`, and
    /// `oversized-line-over-1mb.ndjson`: those are out of the live shadow arm's scope by
    /// construction (`ClaudeCodecShadowComparator`'s own doc -- recovery-required lines are
    /// `NotComparable` and skipped, not compared), already exhaustively covered by the P6-3 corpus
    /// differential and the `claude-ndjson-v1` fuzz target instead (design §3.4).
    private static let comparableFixtures = [
        "crlf-line-ending.ndjson",
        "realcapture-can-use-tool-round-trip.ndjson",
        "realcapture-result-with-genuine-error.ndjson",
        "realcapture-result-without-errors.ndjson",
        "realcapture-session-state-changed-idle-sequence.ndjson",
        "realcapture-thinking-and-reasoning-dropped.ndjson"
    ]

    /// Fixtures whose corpus content includes an authoritative `result`/`message_stop` line -- a
    /// real turn boundary, which `handleStreamPayload`'s protocol-drift guard correctly expects a
    /// corresponding sent turn for. `test_beginTurnTracking()` sets up exactly that precondition
    /// (module doc on that hook: it does not bypass the guard, it satisfies it).
    private static let fixturesRequiringAnInFlightTurn: Set<String> = [
        "realcapture-result-with-genuine-error.ndjson",
        "realcapture-result-without-errors.ndjson"
    ]

    func testZeroMismatchesReplayingTheSyntheticCorpusThroughRealHandleLineDispatch() async throws {
        let controller = makeController(enableComparator: true)
        var totalLinesFed = 0
        for fixtureName in Self.comparableFixtures {
            if Self.fixturesRequiringAnInFlightTurn.contains(fixtureName) {
                await controller.test_beginTurnTracking()
            }
            for line in try fixtureLines(fixtureName) {
                await controller.test_handleLine(line)
                totalLinesFed += 1
            }
        }
        let mismatches = await controller.test_claudeCodecShadowComparatorMismatches()
        let compared = await controller.test_claudeCodecShadowComparatorComparedCount()
        XCTAssertTrue(mismatches.isEmpty, "shadow arm reported mismatches: \(mismatches.joined(separator: "\n"))")
        XCTAssertGreaterThan(compared, 0, "the corpus must actually exercise the comparator, not merely skip every line")
        XCTAssertGreaterThan(totalLinesFed, 0)
    }

    /// The `sessionStateChanged(idle)` sequence specifically, isolated from the rest of the corpus
    /// -- this is the fixture that exercises the design §5.2/§7.1 "classification trap" row through
    /// the live translation path (not the state machine -- `turn_state.rs`'s own tests cover that
    /// half; this is purely "does the translator agree on the text of each state").
    func testSessionStateChangedIdleSequenceMatchesAcrossBothArms() async throws {
        let controller = makeController(enableComparator: true)
        for line in try fixtureLines("realcapture-session-state-changed-idle-sequence.ndjson") {
            await controller.test_handleLine(line)
        }
        let mismatches = await controller.test_claudeCodecShadowComparatorMismatches()
        XCTAssertEqual(mismatches, [])
        let compared = await controller.test_claudeCodecShadowComparatorComparedCount()
        XCTAssertEqual(compared, 3, "all three session_state_changed lines (running/compacting/idle) must be compared")
    }
}
