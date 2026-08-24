import Foundation
@testable import RepoPromptApp
import XCTest

/// D-10 (`docs/architecture/rust-agent-claude-v1.md`, P6-7): regression coverage for a found-and-
/// fixed pre-existing Swift bug, not intentional drift.
///
/// `ClaudeNativeProcessSessionController.shutdown()` called `clearTurnIDQueue()` **before**
/// `cancelAuthoritativeLifecycleState()`. The latter flushes deferred (result-observed-but-not-
/// yet-idle-confirmed) turn completions by dequeuing each pending status's turn ID, guarded by
/// `hasPendingTurnIDs` -- clearing the queue first emptied it out from under that guard, so the
/// flush loop broke on its very first iteration and `shutdown()` silently dropped every deferred
/// completion. This contradicted contract §4.5 ("any --shutdown--> flush deferred with original
/// status") and diverged from Rust's `turn_state::on_shutdown`, which already implemented the
/// contractual behavior -- found and documented in P6-5's `turn_state.rs` module doc, named as the
/// P6-7 differential's job to adjudicate. Verified contractual: Rust is authoritative per campaign
/// norms, and Swift's own EOF path (`handleStdoutEOF`, which does not clear the turn ID queue
/// before flushing) already exhibited the correct behavior, confirming this was an ordering bug
/// isolated to `shutdown()`, not an intentional behavioral difference.
final class ClaudeNativeShutdownDeferredFlushTests: XCTestCase {
    private func makeController() -> ClaudeNativeProcessSessionController {
        ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard)
        )
    }

    /// Drives the controller through: a turn begins, `session_state_changed` (running) is
    /// observed (arming authoritative-lifecycle deferral), then a `result`/`message_stop` line
    /// arrives -- the turn is now `ResultObserved`, deferred pending `idle`, never dequeued
    /// (`turnInFlight` stays true). `idle` never arrives. `shutdown()` is called directly, as a
    /// product-driven shutdown (not stdout EOF) -- exactly the path the bug lived in.
    func testShutdownFlushesADeferredResultObservedTurnWithItsOriginalStatusInsteadOfDroppingIt() async throws {
        let controller = makeController()
        let turnID = await controller.test_beginTurnTracking()

        await controller.test_handleLine(Data(
            #"{"type":"system","subtype":"session_state_changed","session_state":"running"}"#.utf8
        ))
        await controller.test_handleLine(Data(
            #"{"type":"result","subtype":"success","session_id":"claude-session-shutdown-flush-test","result":"All done.","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1},"stop_reason":"end_turn"}"#.utf8
        ))

        // The deferred turn must still be in flight -- idle never arrived, and shutdown must not
        // have run yet.
        let inFlightBeforeShutdown = await controller.hasTurnInFlight
        XCTAssertTrue(inFlightBeforeShutdown, "the ResultObserved turn must remain in flight until idle or the fallback timer, per contract §4.5")

        await controller.shutdown()

        var turnCompletions: [(turnID: UUID, status: ClaudeNativeProcessSessionController.TurnStatus)] = []
        let eventsStream = await controller.events
        for await event in eventsStream {
            if case let .turnCompleted(completedTurnID, status) = event {
                turnCompletions.append((completedTurnID, status))
            }
        }

        XCTAssertEqual(
            turnCompletions.map(\.turnID), [turnID],
            "shutdown() must flush the one deferred ResultObserved turn exactly once, not drop it -- the D-10 regression emitted zero"
        )
        XCTAssertEqual(
            turnCompletions.first?.status, .completed,
            "the flushed completion must carry its original result-derived status, never rewritten to .failed"
        )
    }

    /// A turn that never reached `result` (pure `TurnInFlight`, no deferred status recorded) is
    /// NOT flushed as a completion on `shutdown()` -- contract §4.5's shutdown arrow has no Failed
    /// edge; only stdout EOF fails un-resulted in-flight turns. This pins the boundary of the D-10
    /// fix so a future change doesn't overcorrect into flushing everything.
    func testShutdownDoesNotSynthesizeACompletionForATurnThatNeverReceivedAResult() async throws {
        let controller = makeController()
        _ = await controller.test_beginTurnTracking()

        await controller.shutdown()

        var turnCompletions = 0
        let eventsStream = await controller.events
        for await event in eventsStream {
            if case .turnCompleted = event {
                turnCompletions += 1
            }
        }
        XCTAssertEqual(turnCompletions, 0, "shutdown() must not fabricate a completion for a turn with no observed result")
    }
}
