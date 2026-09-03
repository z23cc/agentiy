import AgentryCoreBridge
import RepoPromptDomainRuntime
import XCTest

/// Design §5.5 / §9: attach returns an atomic snapshot + cursor, replays from the event log when the
/// client's cursor is in range (`complete`), falls back to a snapshot when the host has less than the
/// client believes (`partial`), and declares replay `unavailable` when the generation changed.
final class AgentSessionHostAttachReplayTests: XCTestCase {
    private var harness: AgentSessionHostTestHarness!

    override func setUpWithError() throws {
        harness = try AgentSessionHostTestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    func testFreshAttachStreamsSnapshotThenLiveEventsWithMonotonicCursors() async throws {
        try harness.startServer(script: AgentSessionScriptedExecutorScript(streamChunksPerTurn: 3, chunkDelay: 0.05))
        let client = try await harness.connect()
        let reader = AgentSessionHostTestHarness.EventReader(client)
        let started = try await harness.startSession(client)
        let attached = try await client.attach(sessionID: started.sessionId)

        XCTAssertEqual(attached.replay, .complete)
        XCTAssertTrue(attached.snapshotFollows)
        XCTAssertEqual(attached.generation, started.generation)
        let snapshot = try await reader.readSnapshot(codec: harness.codec)
        XCTAssertEqual(snapshot.sessionId, started.sessionId)
        XCTAssertEqual(snapshot.throughCursor, attached.snapshotThroughCursor)
        XCTAssertEqual(attached.nextCursor, snapshot.throughCursor + 1)
        XCTAssertEqual(snapshot.summary?.workspaceId, "ws-test")

        let live = try await reader.readUntilRunTerminated()
        XCTAssertFalse(live.isEmpty)
        XCTAssertEqual(live.first?.deliveryCursor, attached.nextCursor)
        let cursors = live.map(\.deliveryCursor)
        XCTAssertEqual(cursors, try Array(XCTUnwrap(cursors.first) ... cursors.last!), "cursors must be contiguous")
        XCTAssertTrue(live.allSatisfy { $0.generation == started.generation })

        let list = try await client.listSessions()
        XCTAssertEqual(list.sessions.count, 1)
        XCTAssertEqual(list.sessions.first?.status, .waitingForInput)
        XCTAssertEqual(list.sessions.first?.attachedClientCount, 1)
        XCTAssertEqual(list.sessions.first?.transcriptItemCount, 2, "user message + assistant reply")
    }

    func testResumeWithinLogReplaysCompleteWithoutSnapshot() async throws {
        try harness.startServer()
        let client = try await harness.connect()
        let reader = AgentSessionHostTestHarness.EventReader(client)
        let started = try await harness.startSession(client)
        _ = try await client.attach(sessionID: started.sessionId)
        _ = try await reader.readSnapshot(codec: harness.codec)
        let end = try await harness.waitUntilTurnSettled(client: client, sessionID: started.sessionId, reader: reader)
        try await client.detach(sessionID: started.sessionId)
        reader.drainBuffered()

        let resumed = try await client.attach(sessionID: started.sessionId, resumeCursor: end - 2, resumeGeneration: started.generation)
        XCTAssertEqual(resumed.replay, .complete)
        XCTAssertFalse(resumed.snapshotFollows)
        XCTAssertEqual(resumed.nextCursor, end - 1)
        let replayed = try await reader.collect { event in
            guard case let .event(notification) = event else { return false }
            return notification.deliveryCursor == end
        }
        let cursors = replayed.compactMap { event -> UInt64? in
            guard case let .event(notification) = event else { return nil }
            return notification.deliveryCursor
        }
        XCTAssertEqual(cursors, [end - 1, end])

        // Fully caught up: nothing to replay, no snapshot, cursor stays at the end.
        try await client.detach(sessionID: started.sessionId)
        let caughtUp = try await client.attach(sessionID: started.sessionId, resumeCursor: end, resumeGeneration: started.generation)
        XCTAssertEqual(caughtUp.replay, .complete)
        XCTAssertFalse(caughtUp.snapshotFollows)
        XCTAssertEqual(caughtUp.nextCursor, end + 1)
    }

    func testResumeBeyondHostLogIsPartialWithSnapshot() async throws {
        try harness.startServer()
        let client = try await harness.connect()
        let reader = AgentSessionHostTestHarness.EventReader(client)
        let started = try await harness.startSession(client)
        _ = try await client.attach(sessionID: started.sessionId)
        _ = try await reader.readSnapshot(codec: harness.codec)
        let end = try await harness.waitUntilTurnSettled(client: client, sessionID: started.sessionId, reader: reader)
        try await client.detach(sessionID: started.sessionId)
        reader.drainBuffered()

        let partial = try await client.attach(sessionID: started.sessionId, resumeCursor: end + 50, resumeGeneration: started.generation)
        XCTAssertEqual(partial.replay, .partial)
        XCTAssertTrue(partial.snapshotFollows)
        let snapshot = try await reader.readSnapshot(codec: harness.codec)
        XCTAssertEqual(snapshot.throughCursor, end)
        XCTAssertEqual(partial.nextCursor, end + 1)
    }

    func testResumeWithForeignGenerationIsUnavailableWithSnapshot() async throws {
        try harness.startServer()
        let client = try await harness.connect()
        let reader = AgentSessionHostTestHarness.EventReader(client)
        let started = try await harness.startSession(client)
        _ = try await client.attach(sessionID: started.sessionId)
        _ = try await reader.readSnapshot(codec: harness.codec)
        let end = try await harness.waitUntilTurnSettled(client: client, sessionID: started.sessionId, reader: reader)
        try await client.detach(sessionID: started.sessionId)
        reader.drainBuffered()

        let foreign = Data(repeating: 0xAB, count: started.generation.count)
        let unavailable = try await client.attach(sessionID: started.sessionId, resumeCursor: end - 1, resumeGeneration: foreign)
        XCTAssertEqual(unavailable.replay, .unavailable)
        XCTAssertTrue(unavailable.snapshotFollows)
        XCTAssertEqual(unavailable.generation, started.generation)
        let snapshot = try await reader.readSnapshot(codec: harness.codec)
        XCTAssertEqual(snapshot.throughCursor, end)
    }

    func testHostRestartChangesGenerationRecoversSessionAndDemotesActiveRun() async throws {
        // A turn that never completes leaves the session `running` on disk when the host stops.
        try harness.startServer(script: AgentSessionScriptedExecutorScript(streamChunksPerTurn: 2, autoCompleteTurns: false, chunkDelay: 0.05))
        let client = try await harness.connect()
        let reader = AgentSessionHostTestHarness.EventReader(client)
        let started = try await harness.startSession(client)
        _ = try await client.attach(sessionID: started.sessionId)
        _ = try await reader.readSnapshot(codec: harness.codec)
        let observed = try await reader.collect { event in
            guard case let .event(notification) = event, case let .runtimeEvent(runtime) = notification.event?.body,
                  case let .stream(stream) = runtime.kind else { return false }
            return stream.text == "scripted-chunk 1"
        }
        let lastSeen = try XCTUnwrap(observed.compactMap { event -> UInt64? in
            guard case let .event(notification) = event else { return nil }
            return notification.deliveryCursor
        }.last)
        let summaryBefore = try await client.listSessions().sessions.first
        XCTAssertEqual(summaryBefore?.status, .running)
        XCTAssertFalse(summaryBefore?.activeRunId.isEmpty ?? true)

        client.close()
        harness.stopServers()

        // A graceful stop already records the interruption; simulate a crash mid-run by appending a
        // bare `RunStarted` after the fact so the on-disk state is `active` again (design §7.3).
        let names = try harness.codec.sessionLogFileNames(sessionID: started.sessionId)
        let logPath = try harness.paths.sessionDirectory(workspaceID: "ws-test").appendingPathComponent(names.events).path
        let crashed = try CoreAgentSessionLog.open(
            path: logPath,
            sessionID: started.sessionId,
            options: AgentSessionLogOpenOptionsV1(createIfMissing: false, loadSnapshot: false)
        )
        _ = try crashed.append(AgentHostAgentSessionEventV1(
            recordedAt: AgentSessionHostClock.rfc3339(),
            body: .runLifecycle(AgentHostRunLifecycleEventV1(
                runId: "crashed-run",
                epoch: nil,
                kind: .started(AgentHostRunStartedV1(attemptId: "crashed-attempt", message: nil))
            ))
        ), durability: .sync)
        try crashed.close()

        let restarted = try harness.startServer()
        XCTAssertEqual(restarted.recoveryReport.recoveredSessionIDs, [started.sessionId])
        XCTAssertEqual(restarted.recoveryReport.demotedSessionIDs, [started.sessionId])
        let client2 = try await harness.connect()
        let reader2 = AgentSessionHostTestHarness.EventReader(client2)
        let recovered = try await client2.listSessions().sessions
        XCTAssertEqual(recovered.map(\.sessionId), [started.sessionId])
        XCTAssertNotEqual(recovered.first?.generation, started.generation, "host restart must mint a new generation")
        XCTAssertEqual(recovered.first?.status, .waitingForInput, "shutdown/restart demotes an active run")
        XCTAssertEqual(recovered.first?.activeRunId, "")

        let attached = try await client2.attach(sessionID: started.sessionId, resumeCursor: lastSeen, resumeGeneration: started.generation)
        XCTAssertEqual(attached.replay, .unavailable)
        XCTAssertTrue(attached.snapshotFollows)
        let snapshot = try await reader2.readSnapshot(codec: harness.codec)
        XCTAssertEqual(snapshot.summary?.status, .waitingForInput)
        XCTAssertGreaterThan(snapshot.throughCursor, lastSeen)
        XCTAssertEqual(snapshot.transcript.first?.role, .user)
    }

    func testAttachUnknownSessionAndDetachWhenNotAttachedAreRejected() async throws {
        try harness.startServer()
        let client = try await harness.connect()
        let unknown = try await client.send(.attach(.init(sessionId: UUID().uuidString.lowercased(), resumeCursor: nil, resumeGeneration: Data())))
        guard case let .rejected(rejected) = unknown else { return XCTFail("expected rejection, got \(unknown)") }
        XCTAssertEqual(rejected.reason, .unknownSession)

        let started = try await harness.startSession(client)
        let detached = try await client.send(.detach(.init(sessionId: started.sessionId)))
        guard case let .rejected(notAttached) = detached else { return XCTFail("expected rejection, got \(detached)") }
        XCTAssertEqual(notAttached.reason, .notAttached)
    }
}
