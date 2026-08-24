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
        addTeardownBlock { await session.close() } // XCTest awaits teardown blocks; a bare `Task` in `defer` would not be.

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
        // stopping the run. Two halves: the run survives (sending a message after close succeeds),
        // and the subscription itself is genuinely gone Rust-side, not just locally -- proven by
        // draining the closed subscription ID directly through `bridge.transport` (bypassing the
        // Swift-side facade's own local-dict guard, which would otherwise short-circuit before ever
        // reaching the real transport and prove nothing). Without this second half, the test would
        // pass identically if `close()` were a no-op.
        let (bridge, session) = try await openLongRunningSession()
        addTeardownBlock { await session.close() } // XCTest awaits teardown blocks; a bare `Task` in `defer` would not be.

        let stream = try await session.events()
        try await stream.close()

        let generation = try await session.sendUserMessage("still alive after the stream closed")
        XCTAssertGreaterThan(generation, 0, "the run must survive its last subscriber's stream closing")

        do {
            _ = try await bridge.transport.tryDrain(subscriptionID: stream.subscription.subscriptionID, identity: stream.subscription.runtimeIdentity)
            XCTFail("draining the closed subscription's real ID must fail once it has genuinely been removed Rust-side")
        } catch {
            XCTAssertEqual(error as? CoreTransportError, .subscriptionNotFound)
        }
    }

    /// `CoreAgentSessionEventEnvelope.isGap`/`.isPayloadRejected` are new public API this slice
    /// adds (contract §5.4's pressure-policy outcomes surfaced Swift-side) with no prior coverage.
    /// A live-process gap/oversize production run (the FFI-layer twins in `api.rs` -- `agent_claude
    /// _gap_pressure_and_recovery_surfaces_through_the_ffi_drain_surface` and `agent_claude_oversize
    /// _single_event_payload_is_rejected_through_the_ffi_drain_surface`, both driving a real
    /// synthetic CLI subprocess) is not reproduced here: `CoreAgentClaudeScopeConfigV1` has no way
    /// to reach the test-only synthetic CLI's `AGENT_CLAUDE_SYNTHETIC_CLI_ARGS` env-var escape hatch
    /// from a SwiftPM test target (there is no build-time wiring handing a Rust `cargo`-built test
    /// binary's path to a Swift XCTest bundle). This instead proves the decode/flag logic those two
    /// raw `CoreEvent` kinds drive once they reach the Swift facade -- `CoreEvent`'s memberwise
    /// init is internal, reachable via `@testable import` without a live subscription.
    func testEventEnvelopeSurfacesGapAndPayloadRejectedWithoutADecodedEvent() {
        let gapEvent = CoreEvent(kind: .gap, authoritySequence: 0, deliveryCursor: 1, payload: .gap(droppedCount: 3), payloadOmitted: false)
        let gapEnvelope = CoreAgentSessionEventEnvelope(raw: gapEvent, decoded: CoreAgentSessionEventDecoder.decode(gapEvent))
        XCTAssertTrue(gapEnvelope.isGap)
        XCTAssertFalse(gapEnvelope.isPayloadRejected)
        XCTAssertNil(gapEnvelope.decoded, "a gap payload carries no agent-claude-shaped event to decode")

        let rejectedEvent = CoreEvent(
            kind: .payloadRejected,
            authoritySequence: 0,
            deliveryCursor: 2,
            payload: .rejected(actualBytes: 2_000_000, maximumBytes: 1_048_576, resnapshotRequired: true),
            payloadOmitted: true
        )
        let rejectedEnvelope = CoreAgentSessionEventEnvelope(raw: rejectedEvent, decoded: CoreAgentSessionEventDecoder.decode(rejectedEvent))
        XCTAssertTrue(rejectedEnvelope.isPayloadRejected)
        XCTAssertFalse(rejectedEnvelope.isGap)
        XCTAssertNil(rejectedEnvelope.decoded, "a rejected payload carries no agent-claude-shaped event to decode")
    }
}
