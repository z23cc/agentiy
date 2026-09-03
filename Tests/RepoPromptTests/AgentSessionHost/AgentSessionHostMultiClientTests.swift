import AgentryCoreBridge
import RepoPromptDomainRuntime
import XCTest

/// ADR-0011 P4: two clients on one host session — attach count, first-answer-wins,
/// and per-attachment backpressure → `resnapshotRequired`.
final class AgentSessionHostMultiClientTests: XCTestCase {
    private var harness: AgentSessionHostTestHarness!

    override func setUpWithError() throws {
        harness = try AgentSessionHostTestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    func testTwoClientsAttachSameSession() async throws {
        try harness.startServer()
        let writer = try await harness.connect()
        let started = try await harness.startSession(writer)
        let first = try await writer.attach(sessionID: started.sessionId)
        XCTAssertTrue(first.snapshotFollows)

        let secondClient = try await harness.connect()
        let second = try await secondClient.attach(sessionID: started.sessionId)
        XCTAssertTrue(second.snapshotFollows)

        let list = try await writer.listSessions()
        let summary = list.sessions.first { $0.sessionId == started.sessionId }
        XCTAssertEqual(summary?.attachedClientCount, 2)
        XCTAssertEqual(harness.servers.first?.router.attachmentCount(sessionID: started.sessionId), 2)
    }

    func testFirstAnswerWinsAcrossTwoClientsAndCountsStale() async throws {
        try harness.startServer(script: AgentSessionScriptedExecutorScript(
            streamChunksPerTurn: 1,
            requestApprovalBeforeCompleting: true,
            chunkDelay: 0.05
        ))
        let first = try await harness.connect()
        let firstReader = AgentSessionHostTestHarness.EventReader(first)
        let started = try await harness.startSession(first)
        _ = try await first.attach(sessionID: started.sessionId)
        let snapshot = try await firstReader.readSnapshot(codec: harness.codec)

        let second = try await harness.connect()
        let secondReader = AgentSessionHostTestHarness.EventReader(second)
        _ = try await second.attach(sessionID: started.sessionId)
        _ = try await secondReader.readSnapshot(codec: harness.codec)

        let pending: AgentHostPendingInteractionV1
        if let already = firstReader.pendingInteraction(in: snapshot) {
            pending = already
        } else {
            let requested = try await firstReader.collect { event in
                guard case let .event(notification) = event,
                      case let .interaction(interaction) = notification.event?.body,
                      case .requested = interaction.kind
                else { return false }
                return true
            }
            guard case let .event(notification) = requested.last,
                  case let .interaction(interaction) = notification.event?.body,
                  case let .requested(request) = interaction.kind,
                  let interaction = request.interaction
            else {
                return XCTFail("expected an interaction request")
            }
            pending = interaction
        }

        let answer = AgentHostInteractionAnswerV1(
            skipped: false,
            answer: .approval(AgentHostApprovalDecisionV1(kind: .accept, execpolicyAmendmentJson: ""))
        )
        func respond(on client: AgentSessionHostClient) -> AgentHostCommandRequestCommandV1 {
            .respondInteraction(AgentHostRespondInteractionV1(
                key: AgentSessionHostClient.mutationKey(),
                sessionId: started.sessionId,
                interactionId: pending.interactionId,
                interactionGeneration: pending.interactionGeneration,
                answer: answer
            ))
        }

        let winner = try await first.send(respond(on: first))
        guard case let .result(winnerResult) = winner,
              case let .interactionResponded(accepted) = winnerResult.result
        else {
            return XCTFail("expected accepted, got \(winner)")
        }
        XCTAssertEqual(accepted.disposition, .accepted)

        let loser = try await second.send(respond(on: second))
        guard case let .result(loserResult) = loser,
              case let .interactionResponded(superseded) = loserResult.result
        else {
            return XCTFail("expected superseded, got \(loser)")
        }
        XCTAssertEqual(superseded.disposition, .superseded)
        XCTAssertGreaterThanOrEqual(
            harness.servers.first?.router.staleInteractionResponseCount(sessionID: started.sessionId) ?? 0,
            1
        )
    }

    func testSlowClientOverflowsWhilePeerKeepsEvents() async throws {
        try harness.startServer(script: AgentSessionScriptedExecutorScript(
            streamChunksPerTurn: 4000,
            chunkText: String(repeating: "x", count: 200)
        )) {
            $0.outboundLimits = .init(maxEventFrames: 16, maxEventBytes: 1024 * 1024)
        }
        let writer = try await harness.connect()
        let started = try await harness.startSession(writer)

        let slow = try await harness.connect { $0.eventBufferCapacity = 2 }
        _ = try await slow.attach(sessionID: started.sessionId)

        let peer = try await harness.connect()
        let peerReader = AgentSessionHostTestHarness.EventReader(peer)
        _ = try await peer.attach(sessionID: started.sessionId)
        _ = try await peerReader.readSnapshot(codec: harness.codec)

        try await Task.sleep(nanoseconds: 1_500_000_000)

        // Do not drain the snapshot first — the 2-slot socket buffer may only
        // still hold the overflow control frame.
        let slowReader = AgentSessionHostTestHarness.EventReader(slow)
        let slowEvents = try await slowReader.collect(timeout: 20) { event in
            if case .resnapshotRequired = event { return true }
            return false
        }
        guard case let .resnapshotRequired(required) = slowEvents.last else {
            return XCTFail("slow client must receive resnapshotRequired")
        }
        XCTAssertEqual(required.sessionId, started.sessionId)
        XCTAssertEqual(required.reason, .backpressureOverflow)

        let peerStillListed = try await peer.listSessions()
        XCTAssertEqual(peerStillListed.sessions.first { $0.sessionId == started.sessionId }?.attachedClientCount, 2)
        XCTAssertFalse(
            peerReader.collected.isEmpty,
            "the draining peer must keep receiving while the slow attachment overflows"
        )
    }
}
