import AgentryCoreBridge
import RepoPromptDomainRuntime
import XCTest

/// Design §5.5 / §9: a slow attachment never grows an unbounded queue. When its per-session budget
/// overflows the host drops the queued deltas, suspends the attachment, and sends `resnapshotRequired`;
/// a re-attach with the reported cursor resumes from the log.
final class AgentSessionHostBackpressureTests: XCTestCase {
    private var harness: AgentSessionHostTestHarness!

    override func setUpWithError() throws {
        harness = try AgentSessionHostTestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    func testOutboundQueueDropsSessionEventsOnOverflowAndReportsFalse() {
        let queue = AgentSessionHostOutboundQueue(limits: .init(maxEventFrames: 3, maxEventBytes: 1024))
        let frame = Data(repeating: 1, count: 10)
        XCTAssertTrue(queue.enqueueEvent(frame, sessionID: "s", cursor: 1))
        XCTAssertTrue(queue.enqueueEvent(frame, sessionID: "s", cursor: 2))
        XCTAssertTrue(queue.enqueueEvent(frame, sessionID: "s", cursor: 3))
        queue.enqueueControl(Data(repeating: 2, count: 4))
        XCTAssertFalse(queue.enqueueEvent(frame, sessionID: "s", cursor: 4), "fourth event exceeds the frame budget")
        XCTAssertEqual(queue.pendingFrameCount, 1, "overflow drops every queued event of that session but keeps control frames")
        XCTAssertTrue(queue.enqueueEvent(frame, sessionID: "other", cursor: 1), "other sessions keep their own budget")
        XCTAssertEqual(queue.dequeue(), Data(repeating: 2, count: 4))
        XCTAssertEqual(queue.lastWrittenEventCursor(sessionID: "other"), nil)
        XCTAssertEqual(queue.dequeue(), frame)
        XCTAssertEqual(queue.lastWrittenEventCursor(sessionID: "other"), 1)

        let byteLimited = AgentSessionHostOutboundQueue(limits: .init(maxEventFrames: 100, maxEventBytes: 25))
        XCTAssertTrue(byteLimited.enqueueEvent(frame, sessionID: "s", cursor: 1))
        XCTAssertTrue(byteLimited.enqueueEvent(frame, sessionID: "s", cursor: 2))
        XCTAssertFalse(byteLimited.enqueueEvent(frame, sessionID: "s", cursor: 3), "third event exceeds the byte budget")
        byteLimited.close()
        XCTAssertNil(byteLimited.dequeue())
    }

    func testSlowClientReceivesResnapshotRequiredInsteadOfUnboundedBacklog() async throws {
        try harness.startServer(script: AgentSessionScriptedExecutorScript(streamChunksPerTurn: 4000, chunkText: String(repeating: "x", count: 200))) {
            $0.outboundLimits = .init(maxEventFrames: 16, maxEventBytes: 1024 * 1024)
        }
        // Tiny client-side buffer: the reader thread stops draining the socket almost immediately, so
        // the host's writer blocks and the per-attachment budget is what absorbs the burst.
        let client = try await harness.connect { $0.eventBufferCapacity = 2 }
        let started = try await harness.startSession(client)
        let attached = try await client.attach(sessionID: started.sessionId)
        XCTAssertTrue(attached.snapshotFollows)

        // Do not read anything for a while: the scripted turn floods 4000 events at the host.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let reader = AgentSessionHostTestHarness.EventReader(client)
        _ = try await reader.readSnapshot(codec: harness.codec)
        let events = try await reader.collect(timeout: 20) { event in
            if case .resnapshotRequired = event { return true }
            return false
        }
        guard case let .resnapshotRequired(required) = events.last else {
            return XCTFail("expected resnapshotRequired")
        }
        XCTAssertEqual(required.sessionId, started.sessionId)
        XCTAssertEqual(required.reason, .backpressureOverflow)
        XCTAssertEqual(required.generation, started.generation)
        let deliveredCursors = events.compactMap { event -> UInt64? in
            guard case let .event(notification) = event else { return nil }
            return notification.deliveryCursor
        }
        XCTAssertLessThan(deliveredCursors.count, 4000, "the backlog must have been cut, not delivered")
        XCTAssertEqual(
            deliveredCursors.last ?? attached.snapshotThroughCursor,
            required.lastDeliveredCursor,
            "lastDeliveredCursor names exactly the last event frame the writer put on the socket"
        )

        // The attachment is suspended: nothing else arrives until the client re-attaches.
        do {
            _ = try await reader.next(timeout: 0.5)
            XCTFail("suspended attachment must stay silent")
        } catch AgentSessionHostTestHarness.HarnessError.timeout {}

        // Re-attach from the reported cursor. The gap is far larger than one attachment budget, so the
        // host serves a snapshot (`partial`) rather than pushing thousands of deltas through the queue.
        let resumed = try await client.attach(sessionID: started.sessionId, resumeCursor: required.lastDeliveredCursor, resumeGeneration: required.generation)
        XCTAssertEqual(resumed.replay, .partial)
        XCTAssertTrue(resumed.snapshotFollows)
        let snapshot = try await reader.readSnapshot(codec: harness.codec)
        XCTAssertGreaterThan(snapshot.throughCursor, required.lastDeliveredCursor)
        XCTAssertEqual(resumed.nextCursor, snapshot.throughCursor + 1)

        // A small gap replays `complete` from the log through the same bounded queue.
        try await client.detach(sessionID: started.sessionId)
        let small = try await client.attach(sessionID: started.sessionId, resumeCursor: snapshot.throughCursor - 3, resumeGeneration: required.generation)
        XCTAssertEqual(small.replay, .complete)
        XCTAssertFalse(small.snapshotFollows)
        let replayed = try await reader.collect { event in
            guard case let .event(notification) = event else { return false }
            return notification.deliveryCursor == snapshot.throughCursor
        }
        XCTAssertEqual(replayed.count, 3)
    }
}
