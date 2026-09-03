import AgentryCoreBridge
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// ADR-0011 P6-b publish cutover: the host writes `.events` through `AgentSessionLog` and
/// folds / `compact`s from Rust `CoreAgentSessionTranscriptReducer`. This corpus asserts
/// canonical-JSON agreement with the Swift oracle and byte-level agreement of the log and
/// encoded snapshot.
final class AgentSessionTranscriptPublishAgreementTests: XCTestCase {
    private let sessionID = "11111111-2222-3333-4444-555555555555"
    private let generation = Data([0x67, 0x65, 0x6E])
    private let writtenAt = "2026-09-03T00:00:00Z"

    func testNamedPublishCorpusAgreesOnLogBytesSnapshotBytesAndCanonicalJSON() throws {
        try runPublishCorpus(events: namedPublishEvents(), label: "named")
    }

    func testSeededPublishCorpusAgreesOnLogBytesAndCanonicalJSON() throws {
        var rng = P6ASplitMix64(seed: P6BDifferentialConfiguration.seed)
        let steps = 256 * P6BDifferentialConfiguration.scale
        var events: [AgentHostAgentSessionEventV1] = []
        events.reserveCapacity(steps)
        for _ in 0..<steps {
            let (event, _) = P6BCorpus.event(from: &rng)
            events.append(rebinding(event, sessionID: sessionID))
        }
        try runPublishCorpus(events: events, label: "seeded")
    }

    func testFoldedStateCommandIndexMatchesSwiftOracle() throws {
        var swift = AgentSessionHostSessionState.placeholder(sessionID: sessionID)
        let folded = AgentSessionHostFoldedState(placeholderSessionID: sessionID)
        var cursor: UInt64 = 0
        for event in namedPublishEvents() {
            cursor += 1
            swift.apply(event, cursor: cursor)
            try folded.apply(event, cursor: cursor)
            XCTAssertEqual(swift.acceptedOperations, folded.acceptedOperations, "accepted @\(cursor)")
            XCTAssertEqual(swift.settledOperations, folded.settledOperations, "settled @\(cursor)")
            XCTAssertEqual(swift.settledInteractionIDs, folded.settledInteractionIDs, "settled IDs @\(cursor)")
            XCTAssertEqual(swift.p6bCanonical, try folded.canonicalState(), "canonical @\(cursor)")
        }
    }

    private func runPublishCorpus(events: [AgentHostAgentSessionEventV1], label: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentry-p6b-publish-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codec = CoreAgentHostProtocol()
        let names = try codec.sessionLogFileNames(sessionID: sessionID)
        let leftEvents = root.appendingPathComponent("left-\(names.events)")
        let rightEvents = root.appendingPathComponent("right-\(names.events)")
        let left = try CoreAgentSessionLog.open(
            path: leftEvents.path,
            sessionID: sessionID,
            options: AgentSessionLogOpenOptionsV1(createIfMissing: true, loadSnapshot: false)
        )
        let right = try CoreAgentSessionLog.open(
            path: rightEvents.path,
            sessionID: sessionID,
            options: AgentSessionLogOpenOptionsV1(createIfMissing: true, loadSnapshot: false)
        )
        defer {
            try? left.close()
            try? right.close()
        }

        let dual = try P6BDualTranscriptReducer(sessionID: sessionID)
        let folded = AgentSessionHostFoldedState(placeholderSessionID: sessionID)
        for event in events {
            let cursor = try left.append(event, durability: .sync)
            let rightCursor = try right.append(event, durability: .sync)
            XCTAssertEqual(cursor, rightCursor, "\(label) log cursors")
            try dual.apply(event, cursor: cursor)
            try folded.apply(event, cursor: cursor)
            XCTAssertEqual(try folded.canonicalState(), try dual.rust.canonicalState(), "\(label) folded \(cursor)")
        }

        XCTAssertEqual(
            try Data(contentsOf: leftEvents),
            try Data(contentsOf: rightEvents),
            "\(label) .events bytes"
        )

        let rustSnapshot = try dual.rust.snapshot(generation: generation, now: writtenAt)
        let swiftSnapshot = dual.swift.snapshot(generation: generation, now: writtenAt)
        XCTAssertEqual(
            try codec.encodeSnapshot(rustSnapshot),
            try codec.encodeSnapshot(swiftSnapshot),
            "\(label) encodeSnapshot bytes"
        )
        XCTAssertEqual(rustSnapshot, swiftSnapshot, "\(label) snapshot records")

        let rustReceipt = try left.compact(rustSnapshot)
        let swiftReceipt = try right.compact(swiftSnapshot)
        XCTAssertEqual(rustReceipt.throughCursor, swiftReceipt.throughCursor, "\(label) compact cursor")

        try left.close()
        let fromSnapshot = try CoreAgentSessionLog.open(
            path: leftEvents.path,
            sessionID: sessionID,
            options: AgentSessionLogOpenOptionsV1(createIfMissing: false, loadSnapshot: true)
        )
        defer { try? fromSnapshot.close() }
        let snapshotReport = try fromSnapshot.openReport()
        let recoveredSnapshot = try recover(from: fromSnapshot, report: snapshotReport)
        XCTAssertEqual(
            recoveredSnapshot.snapshot(generation: generation, now: writtenAt),
            rustSnapshot,
            "\(label) snapshot+tail reopen"
        )

        let fromLog = try CoreAgentSessionLog.open(
            path: rightEvents.path,
            sessionID: sessionID,
            options: AgentSessionLogOpenOptionsV1(createIfMissing: false, loadSnapshot: false)
        )
        defer { try? fromLog.close() }
        let logReport = try fromLog.openReport()
        let recoveredLog = try recover(from: fromLog, report: logReport)
        XCTAssertEqual(try recoveredLog.canonicalState(), try dual.rust.canonicalState(), "\(label) full-replay canonical")
    }

    private func recover(
        from log: CoreAgentSessionLog,
        report: AgentSessionLogOpenReportV1
    ) throws -> AgentSessionHostFoldedState {
        let state: AgentSessionHostFoldedState
        var cursor: UInt64
        switch report.snapshot {
        case let .loaded(snapshot):
            state = try AgentSessionHostFoldedState(snapshot: snapshot)
            cursor = report.replayFrom
        case .missing, .notRequested, .corrupt:
            state = AgentSessionHostFoldedState(placeholderSessionID: sessionID)
            cursor = 1
        }
        while cursor < report.nextCursor {
            let batch = try log.readFrom(cursor: cursor, maxRecords: 256, maxBytes: 1_048_576)
            for entry in batch.entries {
                try state.apply(entry.event, cursor: entry.cursor)
            }
            if batch.endOfLog || batch.entries.isEmpty { break }
            cursor = batch.nextCursor
        }
        return state
    }

    private func namedPublishEvents() -> [AgentHostAgentSessionEventV1] {
        let message = P6BFixtures.userMessage(id: "m1", text: "hello", createdAt: "t1")
        return [
            P6BFixtures.event("t0", .sessionMetadataChanged(AgentHostSessionMetadataChangedV1(
                summary: P6BFixtures.emptySummary(sessionID: sessionID, sessionName: "publish", status: .waitingForInput, updatedAt: "t0")
            ))),
            P6BFixtures.event("t1", .userMessage(message)),
            P6BFixtures.event("t2", P6BFixtures.lifecycle("run-1", .started(AgentHostRunStartedV1(
                attemptId: "a1",
                message: message
            )))),
            P6BFixtures.event("t3", P6BFixtures.runtime("run-1", "turn-1", .stream(P6BFixtures.stream(itemType: "content", text: "Hel")))),
            P6BFixtures.event("t4", P6BFixtures.runtime("run-1", "turn-1", .stream(P6BFixtures.stream(itemType: "content", text: "lo", providerSessionId: "ps-9")))),
            P6BFixtures.event("t5", P6BFixtures.runtime("run-1", "turn-1", .stream(P6BFixtures.stream(itemType: "final_content", text: "Hello!")))),
            P6BFixtures.event("t6", .interaction(AgentHostInteractionEventV1(
                kind: .requested(AgentHostInteractionRequestedV1(interaction: P6BFixtures.pending(id: "q1")))
            ))),
            P6BFixtures.event("t7", .commandAccepted(AgentHostCommandAcceptedV1(
                operationId: "op-a", argumentFingerprint: "fa", commandKind: "steer", acceptedAt: "t7"
            ))),
            P6BFixtures.event("t8", .interaction(AgentHostInteractionEventV1(
                kind: .settled(AgentHostInteractionSettledV1(
                    interactionId: "q1",
                    interactionGeneration: Data([1, 2]),
                    settlement: .answered,
                    answer: nil,
                    operationId: "op-a"
                ))
            ))),
            P6BFixtures.event("t9", .commandSettled(AgentHostCommandSettledV1(
                operationId: "op-a", settledAt: "t9", settlement: nil
            ))),
            P6BFixtures.event("t10", P6BFixtures.runtime("run-1", "turn-1", .turnCompleted(AgentHostTurnCompletedV1(
                turnId: "turn-1", stopReason: ""
            )))),
            P6BFixtures.event("t11", P6BFixtures.lifecycle("run-1", .terminated(AgentHostRunTerminatedV1(
                outcome: AgentHostTerminalOutcomeV1(kind: .completed, assistantText: nil, failureReason: .unspecified),
                signal: nil
            )))),
        ]
    }

    private func rebinding(_ event: AgentHostAgentSessionEventV1, sessionID: String) -> AgentHostAgentSessionEventV1 {
        guard case let .sessionMetadataChanged(change) = event.body, let summary = change.summary else {
            return event
        }
        var next = AgentSessionHostMutableSummary(summary)
        next.sessionId = sessionID
        return AgentHostAgentSessionEventV1(
            recordedAt: event.recordedAt,
            body: .sessionMetadataChanged(AgentHostSessionMetadataChangedV1(summary: next.value))
        )
    }
}
