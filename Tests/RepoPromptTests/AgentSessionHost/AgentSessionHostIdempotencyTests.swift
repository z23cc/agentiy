import AgentryCoreBridge
import RepoPromptDomainRuntime
import XCTest

/// Design §5.4 / §9: every mutating command is keyed by `operation_id`; the host records
/// `CommandAccepted` before acting and `CommandSettled` after, so a retry replays the recorded outcome,
/// a reused id with different arguments is an `OperationConflict`, and an id that was accepted but never
/// settled (crash in between) answers `uncertain` after the log is reopened.
final class AgentSessionHostIdempotencyTests: XCTestCase {
    private var harness: AgentSessionHostTestHarness!

    override func setUpWithError() throws {
        harness = try AgentSessionHostTestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    func testStartRetryReplaysRecordedResultAndNewIDOnExistingSessionIsRejected() async throws {
        try harness.startServer()
        let client = try await harness.connect()
        let spec = AgentSessionHostTestHarness.spec()
        let operationID = UUID().uuidString.lowercased()
        let first = try await harness.startSession(client, spec: spec, operationID: operationID)
        let retry = try await harness.startSession(client, spec: spec, operationID: operationID)
        XCTAssertEqual(first, retry, "same operation id + same arguments replays the recorded `started` result")

        let list = try await client.listSessions()
        XCTAssertEqual(list.sessions.count, 1, "the retry must not create a second session")

        let other = try await client.send(.start(AgentHostStartV1(key: AgentSessionHostClient.mutationKey(), spec: spec)))
        guard case let .rejected(rejected) = other else { return XCTFail("expected rejection, got \(other)") }
        XCTAssertEqual(rejected.reason, .sessionExists)
    }

    func testSteerRetryIsRecordedAndDifferentArgumentsConflict() async throws {
        try harness.startServer()
        let client = try await harness.connect()
        let started = try await harness.startSession(client)
        let operationID = UUID().uuidString.lowercased()
        let message = AgentSessionHostTestHarness.message("follow-up")
        let steer: AgentHostCommandRequestCommandV1 = .steer(AgentHostSteerV1(
            key: AgentSessionHostClient.mutationKey(operationID: operationID),
            sessionId: started.sessionId,
            message: message,
            delivery: .queueForNextTurn
        ))

        let first = try await client.send(steer)
        guard case let .result(result) = first, case let .steered(steered) = result.result else {
            return XCTFail("expected steered, got \(first)")
        }
        XCTAssertEqual(steered.messageId, message.messageId)
        XCTAssertGreaterThan(steered.recordedCursor, 0)

        let retry = try await client.send(steer)
        guard case let .result(retryResult) = retry, case let .steered(replayed) = retryResult.result else {
            return XCTFail("expected replayed steered, got \(retry)")
        }
        XCTAssertEqual(replayed, steered, "recorded: identical outcome, no second turn")

        let conflict = try await client.send(AgentSessionHostTestHarness.steer(sessionID: started.sessionId, text: "something else", operationID: operationID))
        guard case let .operationConflict(details) = conflict else { return XCTFail("expected operationConflict, got \(conflict)") }
        XCTAssertEqual(details.operationId, operationID)
        XCTAssertNotEqual(details.recordedFingerprint, details.submittedFingerprint)

        let unkeyed = try await client.send(.steer(AgentHostSteerV1(key: nil, sessionId: started.sessionId, message: message, delivery: .queueForNextTurn)))
        guard case let .rejected(rejected) = unkeyed else { return XCTFail("expected rejection, got \(unkeyed)") }
        XCTAssertEqual(rejected.reason, .invalidArgument)
    }

    func testAcceptedButUnsettledOperationAnswersUncertainAfterReopen() async throws {
        try harness.startServer()
        let client = try await harness.connect()
        let started = try await harness.startSession(client)
        client.close()
        harness.stopServers()

        // Forge a crash between CommandAccepted and CommandSettled directly in the event log.
        let operationID = UUID().uuidString.lowercased()
        let message = AgentSessionHostTestHarness.message("lost in the crash")
        let command: AgentHostCommandRequestCommandV1 = .steer(AgentHostSteerV1(
            key: AgentSessionHostClient.mutationKey(operationID: operationID),
            sessionId: started.sessionId,
            message: message,
            delivery: .queueForNextTurn
        ))
        let fingerprint = try harness.codec.commandFingerprint(AgentHostCommandRequestV1(requestId: "any-request-id", command: command))
        let names = try harness.codec.sessionLogFileNames(sessionID: started.sessionId)
        let logPath = try harness.paths.sessionDirectory(workspaceID: "ws-test").appendingPathComponent(names.events).path
        let log = try CoreAgentSessionLog.open(
            path: logPath,
            sessionID: started.sessionId,
            options: AgentSessionLogOpenOptionsV1(createIfMissing: false, loadSnapshot: false)
        )
        _ = try log.append(AgentHostAgentSessionEventV1(
            recordedAt: AgentSessionHostClock.rfc3339(),
            body: .commandAccepted(AgentHostCommandAcceptedV1(
                operationId: operationID,
                argumentFingerprint: fingerprint,
                commandKind: "steer",
                acceptedAt: AgentSessionHostClock.rfc3339()
            ))
        ), durability: .sync)
        try log.close()

        try harness.startServer()
        let client2 = try await harness.connect()
        let uncertain = try await client2.send(command)
        guard case let .uncertain(details) = uncertain else { return XCTFail("expected uncertain, got \(uncertain)") }
        XCTAssertEqual(details.operationId, operationID)

        let conflict = try await client2.send(AgentSessionHostTestHarness.steer(sessionID: started.sessionId, text: "different", operationID: operationID))
        guard case .operationConflict = conflict else { return XCTFail("expected operationConflict, got \(conflict)") }

        // The unsettled operation is visible in the snapshot so a client can reconcile it.
        let reader = AgentSessionHostTestHarness.EventReader(client2)
        _ = try await client2.attach(sessionID: started.sessionId)
        let snapshot = try await reader.readSnapshot(codec: harness.codec)
        XCTAssertEqual(snapshot.unsettledOperations.map(\.operationId), [operationID])
    }

    func testInterruptStopAndRespondInteractionSettleThroughTheLog() async throws {
        try harness.startServer(script: AgentSessionScriptedExecutorScript(streamChunksPerTurn: 1, requestApprovalBeforeCompleting: true, chunkDelay: 0.05))
        let client = try await harness.connect()
        let reader = AgentSessionHostTestHarness.EventReader(client)
        let started = try await harness.startSession(client)
        _ = try await client.attach(sessionID: started.sessionId)
        let snapshot = try await reader.readSnapshot(codec: harness.codec)
        let pending: AgentHostPendingInteractionV1
        if let already = reader.pendingInteraction(in: snapshot) {
            pending = already
        } else {
            let requested = try await reader.collect { event in
                guard case let .event(notification) = event, case let .interaction(interaction) = notification.event?.body,
                      case .requested = interaction.kind else { return false }
                return true
            }
            guard case let .event(notification) = requested.last, case let .interaction(interaction) = notification.event?.body,
                  case let .requested(request) = interaction.kind, let interaction = request.interaction
            else { return XCTFail("expected an interaction request") }
            pending = interaction
        }

        // A stale generation never settles; then first writer wins and the second answer is superseded.
        let answer = AgentHostInteractionAnswerV1(skipped: false, answer: .approval(AgentHostApprovalDecisionV1(kind: .accept, execpolicyAmendmentJson: "")))
        func respond(generation: Data) -> AgentHostCommandRequestCommandV1 {
            .respondInteraction(AgentHostRespondInteractionV1(
                key: AgentSessionHostClient.mutationKey(),
                sessionId: started.sessionId,
                interactionId: pending.interactionId,
                interactionGeneration: generation,
                answer: answer
            ))
        }
        let stale = try await client.send(respond(generation: Data([0xFF])))
        guard case let .result(staleResult) = stale, case let .interactionResponded(staleResponded) = staleResult.result else {
            return XCTFail("expected interactionResponded, got \(stale)")
        }
        XCTAssertEqual(staleResponded.disposition, .staleGeneration)

        let winner = try await client.send(respond(generation: pending.interactionGeneration))
        guard case let .result(winnerResult) = winner, case let .interactionResponded(responded) = winnerResult.result else {
            return XCTFail("expected interactionResponded, got \(winner)")
        }
        XCTAssertEqual(responded.disposition, .accepted)
        let loser = try await client.send(respond(generation: pending.interactionGeneration))
        guard case let .result(loserResult) = loser, case let .interactionResponded(superseded) = loserResult.result else {
            return XCTFail("expected interactionResponded, got \(loser)")
        }
        XCTAssertEqual(superseded.disposition, .superseded)
        let unknown = try await client.send(.respondInteraction(AgentHostRespondInteractionV1(
            key: AgentSessionHostClient.mutationKey(),
            sessionId: started.sessionId,
            interactionId: "never-requested",
            interactionGeneration: pending.interactionGeneration,
            answer: answer
        )))
        guard case let .result(unknownResult) = unknown, case let .interactionResponded(unknownResponded) = unknownResult.result else {
            return XCTFail("expected interactionResponded, got \(unknown)")
        }
        XCTAssertEqual(unknownResponded.disposition, .unknownInteraction)

        // The answered interaction lets the scripted turn finish.
        _ = try await reader.readUntilRunTerminated()

        let noTurn = try await client.send(.interrupt(AgentHostInterruptV1(key: AgentSessionHostClient.mutationKey(), sessionId: started.sessionId, turnId: "")))
        guard case let .result(interruptResult) = noTurn, case let .interrupted(interrupted) = interruptResult.result else {
            return XCTFail("expected interrupted, got \(noTurn)")
        }
        XCTAssertEqual(interrupted.outcome, .noTurnInFlight)

        let stopped = try await client.send(.stop(AgentHostStopV1(key: AgentSessionHostClient.mutationKey(), sessionId: started.sessionId, reason: .userRequested)))
        guard case let .result(stopResult) = stopped, case let .stopped(stoppedResult) = stopResult.result else {
            return XCTFail("expected stopped, got \(stopped)")
        }
        XCTAssertEqual(stoppedResult.status, .completed)
        let hidden = try await client.listSessions()
        XCTAssertTrue(hidden.sessions.isEmpty, "terminal sessions are hidden by default")
        let shown = try await client.listSessions(includeTerminal: true)
        XCTAssertEqual(shown.sessions.first?.status, .completed)

        let again = try await client.send(AgentSessionHostTestHarness.steer(sessionID: started.sessionId, text: "too late"))
        guard case let .rejected(rejected) = again else { return XCTFail("expected rejection, got \(again)") }
        XCTAssertEqual(rejected.reason, .sessionNotActive)
    }
}
