import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Seam contract for the P1/P1.5 production `AgentSessionConnection` (ADR-0011, design §5.4–§5.5, §6).
///
/// The executor is faked so these tests pin the connection's own responsibilities: session
/// registry, cursor/generation semantics, `operationID` idempotency (bounded LRU journal),
/// command lifecycle events whose payloads equal the returned results, and fail-closed
/// behavior without an executor. Provider execution itself is covered by the coordinator
/// and run-service suites.
@MainActor
final class InProcessAgentSessionConnectionTests: XCTestCase {
    // MARK: - Attach / detach

    func testAttachUnknownSessionThrowsSessionNotFound() async {
        let (connection, _) = makeConnection()
        let sessionID = UUID()

        await assertThrows(.sessionNotFound(sessionID)) {
            _ = try await connection.attach(sessionID: sessionID, resume: nil)
        }
    }

    func testAttachReturnsSnapshotAndFirstCursorAndEmitsAttachedEvent() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, session) = executor.registerSession()
        session.selectedAgent = .codexExec
        var events = await connection.events.makeAsyncIterator()

        let result = try await connection.attach(sessionID: sessionID, resume: nil)

        XCTAssertEqual(result.snapshot.tabID, session.tabID)
        XCTAssertEqual(result.snapshot.provider, .codexExec)
        XCTAssertEqual(result.snapshot.runState, .idle)
        XCTAssertNil(result.snapshot.pendingInteraction)
        XCTAssertEqual(result.cursor.deliveryCursor, 1)
        XCTAssertFalse(result.cursor.generation.isEmpty)
        XCTAssertEqual(result.replay, .complete)
        let attached = await connection.attachedSessions
        XCTAssertEqual(attached, [sessionID])

        guard case let .attached(eventSessionID, eventCursor)? = await events.next() else {
            return XCTFail("expected an attached event")
        }
        XCTAssertEqual(eventSessionID, sessionID)
        XCTAssertEqual(eventCursor, result.cursor)
    }

    func testAttachWithCurrentCursorReportsCompleteReplay() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        let first = try await connection.attach(sessionID: sessionID, resume: nil)

        let second = try await connection.attach(sessionID: sessionID, resume: first.cursor)

        XCTAssertEqual(second.replay, .complete)
        XCTAssertTrue(second.cursor.sharesGeneration(with: first.cursor))
        XCTAssertEqual(second.cursor.deliveryCursor, first.cursor.deliveryCursor + 1)
    }

    func testAttachWithMissedEventsReportsPartialReplay() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        let first = try await connection.attach(sessionID: sessionID, resume: nil)
        await connection.publishRuntimeEvent(.error("one"), sessionID: sessionID)
        await connection.publishRuntimeEvent(.error("two"), sessionID: sessionID)

        let second = try await connection.attach(sessionID: sessionID, resume: first.cursor)

        XCTAssertEqual(second.replay, .partial)
        XCTAssertTrue(second.cursor.sharesGeneration(with: first.cursor))
    }

    func testAttachWithForeignGenerationReportsUnavailableReplay() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        let foreign = AgentSessionCursor(generation: Data(repeating: 0xAB, count: 32), deliveryCursor: 7)

        let result = try await connection.attach(sessionID: sessionID, resume: foreign)

        XCTAssertEqual(result.replay, .unavailable)
        XCTAssertFalse(result.cursor.sharesGeneration(with: foreign))
    }

    func testInvalidateGenerationRequestsResnapshotAndRetiresOldCursors() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        let first = try await connection.attach(sessionID: sessionID, resume: nil)
        var events = await connection.events.makeAsyncIterator()
        _ = await events.next() // attached

        await connection.invalidateGeneration(for: sessionID)

        guard case let .resnapshotRequired(eventSessionID)? = await events.next() else {
            return XCTFail("expected a resnapshotRequired event")
        }
        XCTAssertEqual(eventSessionID, sessionID)

        let second = try await connection.attach(sessionID: sessionID, resume: first.cursor)
        XCTAssertEqual(second.replay, .unavailable)
        XCTAssertFalse(second.cursor.sharesGeneration(with: first.cursor))
        XCTAssertEqual(second.cursor.deliveryCursor, 1, "a new lineage restarts delivery numbering")
    }

    func testReplacedPresentationCacheStartsNewLineage() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        let first = try await connection.attach(sessionID: sessionID, resume: nil)

        // A workspace switch discards the tab session and hydrates the same persisted
        // session into a fresh presentation cache.
        executor.sessionsByID[sessionID] = AgentTabSession(tabID: UUID())
        let second = try await connection.attach(sessionID: sessionID, resume: first.cursor)

        XCTAssertEqual(second.replay, .unavailable)
        XCTAssertFalse(second.cursor.sharesGeneration(with: first.cursor))
    }

    func testDetachEmitsOnlyForAttachedSessions() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        var events = await connection.events.makeAsyncIterator()

        await connection.detach(sessionID: sessionID)
        _ = try await connection.attach(sessionID: sessionID, resume: nil)
        await connection.detach(sessionID: sessionID)

        guard case .attached? = await events.next() else {
            return XCTFail("detaching an unattached session must not emit")
        }
        guard case let .detached(eventSessionID)? = await events.next() else {
            return XCTFail("expected a detached event")
        }
        XCTAssertEqual(eventSessionID, sessionID)
        let attached = await connection.attachedSessions
        XCTAssertTrue(attached.isEmpty)
    }

    // MARK: - Runtime publication

    func testRuntimeEventsAdvanceCursorOnlyForAttachedSessions() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        var events = await connection.events.makeAsyncIterator()

        await connection.publishRuntimeEvent(.error("dropped"), sessionID: sessionID)
        let attach = try await connection.attach(sessionID: sessionID, resume: nil)
        await connection.publishRuntimeEvent(.error("delivered"), sessionID: sessionID)
        await connection.publishRunTermination(.completed(assistantText: "done"), sessionID: sessionID)

        guard case .attached? = await events.next() else {
            return XCTFail("events for unattached sessions must be dropped")
        }
        guard case let .runtime(runtimeSessionID, .error(message), runtimeCursor)? = await events.next() else {
            return XCTFail("expected a runtime event")
        }
        XCTAssertEqual(runtimeSessionID, sessionID)
        XCTAssertEqual(message, "delivered")
        XCTAssertEqual(runtimeCursor.deliveryCursor, attach.cursor.deliveryCursor + 1)
        guard case let .runTerminated(terminatedSessionID, outcome, terminalCursor)? = await events.next() else {
            return XCTFail("expected a runTerminated event")
        }
        XCTAssertEqual(terminatedSessionID, sessionID)
        XCTAssertEqual(outcome, .completed(assistantText: "done"))
        XCTAssertEqual(terminalCursor.deliveryCursor, runtimeCursor.deliveryCursor + 1)
        XCTAssertTrue(terminalCursor.sharesGeneration(with: attach.cursor))
    }

    func testSessionScopedEventsCarryStrictlyIncreasingCursorsWithinOneGeneration() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        var events = await connection.events.makeAsyncIterator()

        let attach = try await connection.attach(sessionID: sessionID, resume: nil)
        _ = try await connection.steer(sessionID: sessionID, message: .init(text: "a"), operationID: UUID())
        await connection.publishRuntimeEvent(.error("mid"), sessionID: sessionID)
        _ = try await connection.interrupt(sessionID: sessionID, reason: .userRequested, operationID: UUID())
        await connection.publishRunTermination(.cancelled(), sessionID: sessionID)

        var cursors: [AgentSessionCursor] = []
        // attached, accepted, settled, runtime, accepted, settled, runTerminated
        for _ in 0 ..< 7 {
            guard let event = await events.next() else { return XCTFail("stream ended early") }
            if let cursor = event.cursor {
                cursors.append(cursor)
            }
        }
        XCTAssertTrue(cursors.allSatisfy { $0.sharesGeneration(with: attach.cursor) })
        // `commandAccepted` reports the cursor current at acceptance (not an advance), so the
        // sequence is non-decreasing overall and strictly increasing across deliveries.
        let deliveries = cursors.map(\.deliveryCursor)
        XCTAssertEqual(deliveries, deliveries.sorted())
        XCTAssertEqual(Set(deliveries).count, deliveries.count - 2, "only the two acceptance cursors repeat")
    }

    // MARK: - Start

    func testStartDelegatesToExecutorAndEmitsCommandLifecycle() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, session) = executor.registerSession()
        executor.startResult = .success(.init(sessionID: sessionID, sendOutcome: .sent))
        let operationID = UUID()
        let spec = AgentSessionStartSpec(tabID: session.tabID, message: .init(text: "hello"))
        var events = await connection.events.makeAsyncIterator()

        let result = try await connection.start(spec, operationID: operationID)

        XCTAssertEqual(result.sessionID, sessionID)
        XCTAssertEqual(result.sendOutcome, .sent)
        XCTAssertEqual(executor.startSpecs.map(\.tabID), [session.tabID])
        XCTAssertEqual(executor.startSpecs.map(\.message), [spec.message])
        guard case let .commandAccepted(acceptedSessionID, acceptedOperationID, acceptedCursor)? = await events.next() else {
            return XCTFail("expected a commandAccepted event")
        }
        XCTAssertNil(acceptedSessionID, "start is not session-addressed until it settles")
        XCTAssertEqual(acceptedOperationID, operationID)
        XCTAssertNil(acceptedCursor)
        guard case let .commandSettled(settledSessionID, settledOperationID, outcome, settledCursor)? = await events.next() else {
            return XCTFail("expected a commandSettled event")
        }
        XCTAssertEqual(settledSessionID, sessionID)
        XCTAssertEqual(settledOperationID, operationID)
        XCTAssertEqual(outcome, .started(result), "the settled payload is the returned value")
        XCTAssertEqual(settledCursor, result.cursor)
    }

    func testStartPassesExecutionContextThroughUnchanged() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, session) = executor.registerSession()
        executor.startResult = .success(.init(sessionID: sessionID, sendOutcome: .accepted))
        let context = AgentTabSession.CodexFallbackSubmissionContext(
            queueID: UUID(),
            providerText: "hello",
            images: [],
            taggedFileAttachments: [],
            draftText: "hello",
            optimisticUserItemID: UUID(),
            origin: .manual,
            dispatchTicket: 7
        )

        _ = try await connection.start(
            AgentSessionStartSpec(tabID: session.tabID, message: .init(text: "hello"), executionContext: context),
            operationID: UUID()
        )

        let received = executor.startSpecs.first?.executionContext as? AgentTabSession.CodexFallbackSubmissionContext
        XCTAssertEqual(received, context)
    }

    func testStartRetryWithSameOperationIDReplaysWithoutReexecuting() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, session) = executor.registerSession()
        executor.startResult = .success(.init(sessionID: sessionID, sendOutcome: .queuedForNextTurn(queueID: UUID())))
        let operationID = UUID()
        let spec = AgentSessionStartSpec(tabID: session.tabID, message: .init(text: "hello"))

        let first = try await connection.start(spec, operationID: operationID)
        let second = try await connection.start(spec, operationID: operationID)

        XCTAssertEqual(first, second)
        XCTAssertEqual(executor.startSpecs.count, 1, "an idempotent retry must not start a second run")
    }

    func testReusedOperationIDWithDifferentPayloadIsRejected() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, session) = executor.registerSession()
        executor.startResult = .success(.init(sessionID: sessionID, sendOutcome: .sent))
        let operationID = UUID()
        let messageID = UUID()

        _ = try await connection.start(
            AgentSessionStartSpec(tabID: session.tabID, message: .init(messageID: messageID, text: "hello")),
            operationID: operationID
        )
        await assertThrows(.operationConflict(operationID)) {
            _ = try await connection.start(
                AgentSessionStartSpec(tabID: session.tabID, message: .init(messageID: messageID, text: "different")),
                operationID: operationID
            )
        }
        XCTAssertEqual(executor.startSpecs.count, 1)
    }

    func testRejectedStartSettlesAsRejectedAndRethrows() async {
        let (connection, executor) = makeConnection()
        let (_, session) = executor.registerSession()
        executor.startResult = .failure(AgentSessionConnectionError.commandRejected("provider unavailable"))
        let operationID = UUID()
        let spec = AgentSessionStartSpec(tabID: session.tabID, message: .init(text: "hello"))
        var events = await connection.events.makeAsyncIterator()

        await assertThrows(.commandRejected("provider unavailable")) {
            _ = try await connection.start(spec, operationID: operationID)
        }

        _ = await events.next() // accepted
        guard case let .commandSettled(settledSessionID, _, outcome, _)? = await events.next() else {
            return XCTFail("expected a commandSettled event")
        }
        XCTAssertNil(settledSessionID)
        XCTAssertEqual(outcome, .rejected(.commandRejected("provider unavailable")))

        // The rejection is journaled too: the same retry gets the same answer without re-running.
        await assertThrows(.commandRejected("provider unavailable")) {
            _ = try await connection.start(spec, operationID: operationID)
        }
        XCTAssertEqual(executor.startSpecs.count, 1)
    }

    func testExecutorTypedErrorsPropagateToTheCallerAndSettleAsRejected() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        executor.respondError = AgentCodexHookReviewResolutionError.busy
        var events = await connection.events.makeAsyncIterator()

        do {
            _ = try await connection.respond(
                sessionID: sessionID,
                interactionID: UUID(),
                answer: .codexHookReview(.approveAll),
                operationID: UUID()
            )
            XCTFail("expected the executor error to propagate")
        } catch let error as AgentCodexHookReviewResolutionError {
            XCTAssertEqual(error, .busy, "in-process clients keep the executor's typed error")
        }

        _ = await events.next() // accepted
        guard case let .commandSettled(_, _, outcome, _)? = await events.next() else {
            return XCTFail("expected a commandSettled event")
        }
        XCTAssertEqual(
            outcome,
            .rejected(.commandRejected(AgentCodexHookReviewResolutionError.busy.errorDescription ?? "")),
            "the journal and the event carry the seam vocabulary"
        )
    }

    // MARK: - Session-addressed commands: results mirror `CommandResponse` payloads

    func testSessionCommandsResolveLiveSessionDelegateAndReturnMirroredPayloads() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, session) = executor.registerSession()
        let interactionID = UUID()
        let message = AgentSessionUserMessage(text: "more")
        executor.steerOutcome = .sent
        executor.interruptOutcome = .acknowledged
        executor.respondDisposition = .accepted
        executor.stopStatus = .cancelled
        var events = await connection.events.makeAsyncIterator()

        let steered = try await connection.steer(sessionID: sessionID, message: message, operationID: UUID())
        let interrupted = try await connection.interrupt(sessionID: sessionID, reason: .userRequested, operationID: UUID())
        let responded = try await connection.respond(
            sessionID: sessionID,
            interactionID: interactionID,
            answer: .approval(.accept),
            operationID: UUID()
        )
        let stopped = try await connection.stop(sessionID: sessionID, reason: .workspaceClosing, operationID: UUID())

        XCTAssertEqual(steered, AgentSessionSteerResult(
            sessionID: sessionID,
            messageID: message.messageID,
            sendOutcome: .sent,
            recordedCursor: steered.recordedCursor
        ))
        XCTAssertEqual(interrupted, AgentSessionInterruptResult(sessionID: sessionID, outcome: .acknowledged, detail: nil))
        XCTAssertEqual(responded, AgentSessionRespondResult(sessionID: sessionID, interactionID: interactionID, disposition: .accepted))
        XCTAssertEqual(stopped, AgentSessionStopResult(sessionID: sessionID, status: .cancelled))

        XCTAssertEqual(executor.steered.map(\.tabID), [session.tabID])
        XCTAssertEqual(executor.steered.map(\.text), ["more"])
        XCTAssertEqual(executor.interrupted.map(\.tabID), [session.tabID])
        XCTAssertEqual(executor.interrupted.map(\.reason), [.userRequested])
        XCTAssertEqual(executor.responded.map(\.tabID), [session.tabID])
        XCTAssertEqual(executor.responded.map(\.interactionID), [interactionID])
        XCTAssertEqual(executor.stopped.map(\.tabID), [session.tabID])
        XCTAssertEqual(executor.stopped.map(\.reason), [.workspaceClosing])

        // Settlement equivalence: every `commandSettled` payload is the value that was returned.
        var settledOutcomes: [AgentSessionCommandOutcome] = []
        for _ in 0 ..< 8 {
            guard let event = await events.next() else { return XCTFail("stream ended early") }
            if case let .commandSettled(_, _, outcome, cursor) = event {
                settledOutcomes.append(outcome)
                XCTAssertNotNil(cursor)
            }
        }
        XCTAssertEqual(settledOutcomes, [
            .steered(steered),
            .interrupted(interrupted),
            .interactionResponded(responded),
            .stopped(stopped)
        ])
    }

    func testSteerRecordedCursorEqualsSettlementCursor() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        var events = await connection.events.makeAsyncIterator()

        let steered = try await connection.steer(sessionID: sessionID, message: .init(text: "x"), operationID: UUID())

        _ = await events.next() // accepted
        guard case let .commandSettled(_, _, _, cursor)? = await events.next() else {
            return XCTFail("expected a commandSettled event")
        }
        XCTAssertEqual(cursor, steered.recordedCursor)
    }

    func testSessionCommandsRejectUnknownSessions() async {
        let (connection, executor) = makeConnection()
        let sessionID = UUID()

        await assertThrows(.sessionNotFound(sessionID)) {
            _ = try await connection.steer(sessionID: sessionID, message: .init(text: "more"), operationID: UUID())
        }
        await assertThrows(.sessionNotFound(sessionID)) {
            _ = try await connection.interrupt(sessionID: sessionID, reason: .userRequested, operationID: UUID())
        }
        await assertThrows(.sessionNotFound(sessionID)) {
            _ = try await connection.stop(sessionID: sessionID, operationID: UUID())
        }
        XCTAssertTrue(executor.steered.isEmpty)
        XCTAssertTrue(executor.interrupted.isEmpty)
        XCTAssertTrue(executor.stopped.isEmpty)
    }

    func testSecondClientSharesJournalAndSeesSettlements() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        let steerOperation = UUID()
        let interruptOperation = UUID()
        var events = await connection.events.makeAsyncIterator()

        let attached = try await connection.attach(sessionID: sessionID, resume: nil)
        let steerMessage = AgentSessionUserMessage(text: "from mcp", codexAttemptID: UUID())
        let steered = try await connection.steer(
            sessionID: sessionID,
            message: steerMessage,
            operationID: steerOperation
        )
        let interrupted = try await connection.interrupt(
            sessionID: sessionID,
            reason: .userRequested,
            operationID: interruptOperation
        )

        XCTAssertEqual(steered.sendOutcome, .accepted)
        XCTAssertEqual(interrupted.outcome, .acknowledged)
        XCTAssertEqual(executor.steered.count, 1)
        XCTAssertEqual(executor.interrupted.count, 1)

        // A second client retrying the same operation IDs must not re-execute.
        let steeredAgain = try await connection.steer(
            sessionID: sessionID,
            message: steerMessage,
            operationID: steerOperation
        )
        XCTAssertEqual(steeredAgain, steered)
        XCTAssertEqual(executor.steered.count, 1)

        var settled: [AgentSessionCommandOutcome] = []
        for _ in 0 ..< 5 {
            guard let event = await events.next() else { return XCTFail("stream ended early") }
            if case let .commandSettled(_, _, outcome, cursor) = event {
                settled.append(outcome)
                XCTAssertNotNil(cursor)
            }
        }
        XCTAssertEqual(settled, [.steered(steered), .interrupted(interrupted)])
        XCTAssertEqual(attached.replay, .complete)
    }

    func testRespondSkipAskUserAndPermissionsReachTheExecutor() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        let askID = UUID()
        let permissionsID = UUID()

        let skipped = try await connection.respond(
            sessionID: sessionID,
            interactionID: askID,
            answer: .skipAskUser,
            operationID: UUID()
        )
        let permissions = try await connection.respond(
            sessionID: sessionID,
            interactionID: permissionsID,
            answer: .permissions(.accept),
            operationID: UUID()
        )

        XCTAssertEqual(skipped.disposition, .accepted)
        XCTAssertEqual(permissions.disposition, .accepted)
        XCTAssertEqual(executor.responded.map(\.interactionID), [askID, permissionsID])
    }

    func testStopRetryWithSameOperationIDDoesNotStopTwice() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, session) = executor.registerSession()
        let operationID = UUID()

        let first = try await connection.stop(sessionID: sessionID, operationID: operationID)
        let second = try await connection.stop(sessionID: sessionID, operationID: operationID)

        XCTAssertEqual(first, second)
        XCTAssertEqual(executor.stopped.map(\.tabID), [session.tabID])
        XCTAssertEqual(executor.stopped.map(\.reason), [.userRequested], "the protocol default is the wire default")
    }

    // MARK: - Idempotency journal bounds

    func testJournalEvictsLeastRecentlyUsedOperationsBeyondCapacity() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        let capacity = InProcessAgentSessionConnection.journalCapacity
        let oldest = UUID()

        _ = try await connection.interrupt(sessionID: sessionID, reason: .userRequested, operationID: oldest)
        for _ in 0 ..< (capacity - 1) {
            _ = try await connection.interrupt(sessionID: sessionID, reason: .userRequested, operationID: UUID())
        }
        var count = await connection.journalCount
        XCTAssertEqual(count, capacity)
        var containsOldest = await connection.journalContains(oldest)
        XCTAssertTrue(containsOldest)

        // Touching the oldest entry (an idempotent retry) makes it most recently used …
        _ = try await connection.interrupt(sessionID: sessionID, reason: .userRequested, operationID: oldest)
        _ = try await connection.interrupt(sessionID: sessionID, reason: .userRequested, operationID: UUID())

        // … so a new operation evicts the *second* oldest instead.
        count = await connection.journalCount
        XCTAssertEqual(count, capacity)
        containsOldest = await connection.journalContains(oldest)
        XCTAssertTrue(containsOldest)
        XCTAssertEqual(executor.interrupted.count, capacity + 1, "the retry did not re-execute")
    }

    func testEvictedOperationIsReexecutedOnRetry() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        let evicted = UUID()

        _ = try await connection.interrupt(sessionID: sessionID, reason: .userRequested, operationID: evicted)
        for _ in 0 ..< InProcessAgentSessionConnection.journalCapacity {
            _ = try await connection.interrupt(sessionID: sessionID, reason: .userRequested, operationID: UUID())
        }
        let contains = await connection.journalContains(evicted)
        XCTAssertFalse(contains)

        _ = try await connection.interrupt(sessionID: sessionID, reason: .userRequested, operationID: evicted)

        XCTAssertEqual(executor.interrupted.count, InProcessAgentSessionConnection.journalCapacity + 2)
    }

    func testStopEvictsTheSessionsJournalExceptTheStopItself() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, _) = executor.registerSession()
        let (otherSessionID, _) = executor.registerSession()
        let steerOperation = UUID()
        let otherOperation = UUID()
        let stopOperation = UUID()

        _ = try await connection.steer(sessionID: sessionID, message: .init(text: "a"), operationID: steerOperation)
        _ = try await connection.steer(sessionID: otherSessionID, message: .init(text: "b"), operationID: otherOperation)
        _ = try await connection.stop(sessionID: sessionID, operationID: stopOperation)

        let steerRemembered = await connection.journalContains(steerOperation)
        let otherRemembered = await connection.journalContains(otherOperation)
        let stopRemembered = await connection.journalContains(stopOperation)
        XCTAssertFalse(steerRemembered, "operations of a stopped session are released")
        XCTAssertTrue(otherRemembered, "other sessions keep their journal")
        XCTAssertTrue(stopRemembered, "the stop stays retry-safe")

        // A stop retry is still idempotent; the released steer re-executes if retried.
        _ = try await connection.stop(sessionID: sessionID, operationID: stopOperation)
        _ = try await connection.steer(sessionID: sessionID, message: .init(text: "a"), operationID: steerOperation)
        XCTAssertEqual(executor.stopped.count, 1)
        XCTAssertEqual(executor.steered.count, 3)
    }

    func testStartJournalEntryBelongsToTheStartedSession() async throws {
        let (connection, executor) = makeConnection()
        let (sessionID, session) = executor.registerSession()
        executor.startResult = .success(.init(sessionID: sessionID, sendOutcome: .sent))
        let startOperation = UUID()

        _ = try await connection.start(
            AgentSessionStartSpec(tabID: session.tabID, message: .init(text: "hello")),
            operationID: startOperation
        )
        await connection.invalidateGeneration(for: sessionID)

        let remembered = await connection.journalContains(startOperation)
        XCTAssertFalse(remembered, "a rotated generation forgets operations settled against it")
    }

    // MARK: - Composition

    func testCommandsWithoutExecutorFailClosed() async {
        let connection = InProcessAgentSessionConnection()
        let sessionID = UUID()
        let hasExecutor = await connection.hasExecutor
        XCTAssertFalse(hasExecutor)

        await assertThrows(.executorUnavailable) {
            _ = try await connection.attach(sessionID: sessionID, resume: nil)
        }
        await assertThrows(.executorUnavailable) {
            _ = try await connection.start(
                AgentSessionStartSpec(tabID: UUID(), message: .init(text: "hello")),
                operationID: UUID()
            )
        }
        await assertThrows(.executorUnavailable) {
            _ = try await connection.stop(sessionID: sessionID, operationID: UUID())
        }
    }

    func testInstallExecutorEnablesCommands() async throws {
        let connection = InProcessAgentSessionConnection()
        let executor = FakeInProcessAgentSessionExecutor()
        let (sessionID, _) = executor.registerSession()

        await connection.installExecutor(executor)

        let result = try await connection.attach(sessionID: sessionID, resume: nil)
        XCTAssertEqual(result.replay, .complete)
    }

    // MARK: - Production executor mappings (pure)

    func testNativeSendOutcomeMapsLosslesslyOntoSeamSendOutcome() {
        let queueID = UUID()
        XCTAssertEqual(InProcessAgentSessionExecutor.sendOutcome(from: nil), .accepted)
        XCTAssertEqual(InProcessAgentSessionExecutor.sendOutcome(from: .sent), .sent)
        XCTAssertEqual(
            InProcessAgentSessionExecutor.sendOutcome(from: .queuedFallback(queueID: queueID, reason: .staleAuthoritativeIdentity)),
            .queuedForNextTurn(queueID: queueID)
        )
        XCTAssertEqual(
            InProcessAgentSessionExecutor.sendOutcome(from: .preDispatchRejected(message: "r")),
            .rejectedBeforeDispatch(reason: "r")
        )
        XCTAssertEqual(InProcessAgentSessionExecutor.sendOutcome(from: .stale(reason: "s")), .staleTarget(reason: "s"))
        XCTAssertEqual(InProcessAgentSessionExecutor.sendOutcome(from: .cancelled), .cancelled)
        XCTAssertEqual(InProcessAgentSessionExecutor.sendOutcome(from: .failed(message: "f")), .failed(reason: "f"))
        XCTAssertTrue(AgentSessionSendOutcome.accepted.didSend)
        XCTAssertTrue(AgentSessionSendOutcome.queuedForNextTurn(queueID: queueID).didSend)
        XCTAssertFalse(AgentSessionSendOutcome.staleTarget(reason: "s").didSend)
    }

    func testInterruptReasonSelectsCancellationIntentAndSettlementPoint() {
        typealias Executor = InProcessAgentSessionExecutor
        XCTAssertEqual(Executor.cancellation(for: .userRequested).intent, .userStop)
        XCTAssertEqual(Executor.cancellation(for: .userRequested).completion, .terminalPublished)
        XCTAssertEqual(Executor.cancellation(for: .supersededBySteer).intent, .userStop)
        XCTAssertEqual(Executor.cancellation(for: .executionLocationChange).intent, .executionLocationChange)
        XCTAssertEqual(Executor.cancellation(for: .executionLocationChange).completion, .terminalPublished)
        XCTAssertEqual(Executor.cancellation(for: .runtimeShutdown).intent, .runtimeShutdown)
        XCTAssertEqual(Executor.cancellation(for: .runtimeShutdown).completion, .terminalTeardownCompleted)
        XCTAssertEqual(Executor.cancellation(for: .clientTeardown).intent, .userStop)
        XCTAssertEqual(Executor.cancellation(for: .clientTeardown).completion, .terminalTeardownCompleted)
    }

    // MARK: - Helpers

    private func makeConnection() -> (InProcessAgentSessionConnection, FakeInProcessAgentSessionExecutor) {
        let executor = FakeInProcessAgentSessionExecutor()
        return (InProcessAgentSessionConnection(executor: executor), executor)
    }

    private func assertThrows(
        _ expected: AgentSessionConnectionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected) to be thrown", file: file, line: line)
        } catch let error as AgentSessionConnectionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

@MainActor
private final class FakeInProcessAgentSessionExecutor: InProcessAgentSessionExecuting {
    struct SteerCall: Equatable {
        let tabID: UUID
        let text: String
    }

    struct InterruptCall: Equatable {
        let tabID: UUID
        let reason: AgentSessionInterruptReason
    }

    struct RespondCall: Equatable {
        let tabID: UUID
        let interactionID: UUID
    }

    struct StopCall: Equatable {
        let tabID: UUID
        let reason: AgentSessionStopReason
    }

    var sessionsByTab: [UUID: AgentTabSession] = [:]
    var sessionsByID: [UUID: AgentTabSession] = [:]
    var startResult: Result<InProcessAgentSessionStartOutcome, Error> = .failure(AgentSessionConnectionError.commandRejected("unconfigured"))
    var steerOutcome: AgentSessionSendOutcome = .accepted
    var interruptOutcome: AgentSessionInterruptOutcome = .acknowledged
    var respondDisposition: AgentInteractionResponseDisposition = .accepted
    var respondError: Error?
    var stopStatus: AgentSessionRunState = .idle
    private(set) var startSpecs: [AgentSessionStartSpec] = []
    private(set) var steered: [SteerCall] = []
    private(set) var interrupted: [InterruptCall] = []
    private(set) var responded: [RespondCall] = []
    private(set) var stopped: [StopCall] = []

    @discardableResult
    func registerSession(sessionID: UUID = UUID()) -> (UUID, AgentTabSession) {
        let session = AgentTabSession(tabID: UUID())
        sessionsByTab[session.tabID] = session
        sessionsByID[sessionID] = session
        return (sessionID, session)
    }

    func session(forTab tabID: UUID) -> AgentTabSession? {
        sessionsByTab[tabID]
    }

    func session(forSessionID sessionID: UUID) throws -> AgentTabSession? {
        sessionsByID[sessionID]
    }

    func startRun(_ spec: AgentSessionStartSpec) async throws -> InProcessAgentSessionStartOutcome {
        startSpecs.append(spec)
        return try startResult.get()
    }

    func steer(session: AgentTabSession, message: AgentSessionUserMessage) async throws -> AgentSessionSendOutcome {
        steered.append(SteerCall(tabID: session.tabID, text: message.text))
        return steerOutcome
    }

    func interrupt(session: AgentTabSession, reason: AgentSessionInterruptReason) async -> AgentSessionInterruptOutcome {
        interrupted.append(InterruptCall(tabID: session.tabID, reason: reason))
        return interruptOutcome
    }

    func respond(session: AgentTabSession, interactionID: UUID, answer _: AgentInteractionAnswer) async throws -> AgentInteractionResponseDisposition {
        responded.append(RespondCall(tabID: session.tabID, interactionID: interactionID))
        if let respondError { throw respondError }
        return respondDisposition
    }

    func stop(session: AgentTabSession, reason: AgentSessionStopReason) async -> AgentSessionRunState {
        stopped.append(StopCall(tabID: session.tabID, reason: reason))
        return stopStatus
    }

    func snapshot(of session: AgentTabSession) -> AgentSessionSnapshot {
        InProcessAgentSessionExecutor.makeSnapshot(of: session)
    }
}
