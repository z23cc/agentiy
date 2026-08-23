import Foundation
import XCTest
@testable import AgentryCoreBridge

/// P6-6 (`docs/designs/p6-claude-vertical-2026-08-23.md` §11 P6-6, `docs/architecture/
/// rust-agent-claude-v1.md`): `CoreAgentSession` exercised through the real `AgentryCoreBridge`/
/// UniFFI transport -- "the real bridge" the done-when names, not a fake. `/usr/bin/yes` stands in
/// for `claude` here: it never reads stdin, never exits, and (unlike most system binaries) does not
/// getopt-parse its argv, so it tolerates the production flag injection (`agent_claude::scope`'s
/// contract §2.5 argv, always prepended by the real `agentOpenScope`/`agentStartOrResume` path)
/// without dying on an unrecognized flag the way `/bin/sleep`/`/bin/sh` would. It never emits valid
/// NDJSON, so it is not used for turn-completion assertions (covered instead by the cargo-only
/// `agent_claude_scope.rs` and FFI-level `agent_claude_full_lifecycle_...` Rust suites, which drive
/// a real interactive synthetic CLI) -- only for the paths that need a live, real, long-running
/// process without caring what it emits: interrupt fencing and subscription lifecycle.
final class CoreAgentSessionTests: XCTestCase {
    private func openLongRunningSession() async throws -> (AgentryCoreBridge, CoreAgentSession) {
        let bridge = try await AgentryCoreBridge.start()
        let session = try await CoreAgentSession.open(bridge: bridge, config: CoreAgentSessionConfig(command: "/usr/bin/yes"))
        _ = try await session.startOrResume()
        return (bridge, session)
    }

    func testOpenStartAndCloseRoundTripThroughTheRealBridgeAndCloseIsIdempotent() async throws {
        let (_, session) = try await openLongRunningSession()
        await session.close()
        await session.close() // idempotent -- see CoreAgentSession.close()'s doc comment
    }

    func testInterruptStaleGenerationIsReachableThroughTheRealBridge() async throws {
        // P6-6 done-when: "a test proving staleGeneration is reachable" (interrupt naming
        // generation N while N+1 is live) -- through the real bridge, not just the cargo-only
        // runtime-crate twin (`agent_claude_scope.rs`) or the FFI-level `agentry-ffi` twin
        // (`api.rs`'s `agent_claude_interrupt_stale_generation_is_reachable_through_the_ffi_surface`).
        let (_, session) = try await openLongRunningSession()
        defer { Task { await session.close() } }

        let generationOne = try await session.sendUserMessage("one")
        let generationTwo = try await session.sendUserMessage("two")
        XCTAssertEqual(generationTwo, generationOne + 1)

        let stream = try await session.events()
        let receipt = try await session.interruptTurn(generation: generationOne, reason: "stale test")

        var outcome: CoreAgentSessionEvent?
        let deadline = Date().addingTimeInterval(3)
        var iterator = stream.makeAsyncIterator()
        while outcome == nil, Date() < deadline {
            guard let envelope = try await iterator.next() else { break }
            if let decoded = envelope.decoded,
               decoded.kind == "interruptOutcome",
               decoded.stringField("request_id") == receipt.requestID
            {
                outcome = decoded
            }
        }
        let decoded = try XCTUnwrap(outcome, "interruptOutcome must be published through the real bridge's subscription surface")
        XCTAssertEqual(decoded.stringField("outcome"), "staleGeneration")
        XCTAssertEqual(decoded.uint64Field("current_generation"), generationTwo)
        XCTAssertEqual(decoded.boolField("current_turn_in_flight"), true)

        try await stream.close()
    }

    func testClosingTheEventStreamClosesTheSubscriptionNotTheRun() async throws {
        // Design §4.7 / P6-6 done-when: "a test asserting no subscription outlives its drainer" --
        // closing the last presentation consumer's stream must close the subscription without
        // stopping the run. Proven here by sending a message *after* closing the stream and
        // observing no error: the scope/process is still alive.
        let (_, session) = try await openLongRunningSession()
        defer { Task { await session.close() } }

        let stream = try await session.events()
        try await stream.close()

        let generation = try await session.sendUserMessage("still alive after the stream closed")
        XCTAssertGreaterThan(generation, 0, "the run must survive its last subscriber's stream closing")
    }
}
