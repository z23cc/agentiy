import AgentryCoreBridge
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// ADR-0011 P6-b (B track) differential harness: every `AgentSessionHostSessionState` branch is
/// replayed through the Swift reducer and its Rust twin, asserting identical snapshots, flags, and
/// canonical JSON after every transition. A seeded random corpus then widens coverage.
///
/// Reproduce with `AGENTRY_P6B_DIFFERENTIAL_SEED=<seed>`; widen with `AGENTRY_P6B_DIFFERENTIAL_SCALE=<n>`.
final class AgentSessionTranscriptRustDifferentialTests: XCTestCase {
    func testScenarioPlaceholderHasNoMetadata() throws {
        let dual = try P6BDualTranscriptReducer()
        XCTAssertFalse(dual.swift.hasMetadata)
        XCTAssertEqual(dual.swift.lastCursor, 0)
    }

    func testScenarioUserMessageAppendsAndDedupes() throws {
        let dual = try P6BDualTranscriptReducer()
        let message = P6BFixtures.userMessage(id: "m1", text: "hello", createdAt: "t1")
        try dual.apply(P6BFixtures.event("rec-1", .userMessage(message)), cursor: 1)
        try dual.apply(P6BFixtures.event("rec-2", .userMessage(message)), cursor: 2)
        XCTAssertEqual(dual.swift.transcript.count, 1)
        XCTAssertEqual(dual.swift.transcript[0].entryId, "m1")
        XCTAssertEqual(dual.swift.transcript[0].throughCursor, 1)
    }

    func testScenarioEmptyMessageIdUsesUserCursor() throws {
        let dual = try P6BDualTranscriptReducer()
        try dual.apply(P6BFixtures.event("rec-1", .userMessage(P6BFixtures.userMessage(id: "", text: "hi"))), cursor: 7)
        XCTAssertEqual(dual.swift.transcript[0].entryId, "user-7")
        XCTAssertEqual(dual.swift.transcript[0].createdAt, "rec-1")
    }

    func testScenarioRunStartedAppendsMessageSetsRunningAndDiscardsDraft() throws {
        let dual = try P6BDualTranscriptReducer()
        try dual.apply(
            P6BFixtures.event("t0", P6BFixtures.runtime("run-1", "turn-1", .stream(P6BFixtures.stream(itemType: "content", text: "draft")))),
            cursor: 1
        )
        try dual.apply(
            P6BFixtures.event("t1", P6BFixtures.lifecycle("run-2", .started(AgentHostRunStartedV1(
                attemptId: "a1",
                message: P6BFixtures.userMessage(id: "m1", text: "steer", createdAt: "t1")
            )))),
            cursor: 2
        )
        XCTAssertEqual(dual.swift.summary.activeRunId, "run-2")
        XCTAssertEqual(dual.swift.summary.status, .running)
        try dual.apply(
            P6BFixtures.event("t2", P6BFixtures.runtime("run-2", "turn-2", .turnCompleted(AgentHostTurnCompletedV1(turnId: "turn-2", stopReason: "")))),
            cursor: 3
        )
        XCTAssertEqual(dual.swift.transcript.count, 1)
    }

    func testScenarioStreamContentAccumulatesFinalReplacesAndFlushCommits() throws {
        let dual = try P6BDualTranscriptReducer()
        try dual.apply(
            P6BFixtures.event("t0", P6BFixtures.runtime("run-1", "turn-1", .stream(P6BFixtures.stream(itemType: "content", text: "Hel")))),
            cursor: 1
        )
        try dual.apply(
            P6BFixtures.event("t1", P6BFixtures.runtime("run-1", "turn-1", .stream(P6BFixtures.stream(itemType: "content", text: "lo", providerSessionId: "ps-9")))),
            cursor: 2
        )
        try dual.apply(
            P6BFixtures.event("t2", P6BFixtures.runtime("run-1", "turn-1", .stream(P6BFixtures.stream(itemType: "final_content", text: "Hello!")))),
            cursor: 3
        )
        try dual.apply(
            P6BFixtures.event("t3", P6BFixtures.runtime("run-1", "turn-1", .turnCompleted(AgentHostTurnCompletedV1(turnId: "turn-1", stopReason: "")))),
            cursor: 4
        )
        XCTAssertEqual(dual.swift.transcript[0].text, "Hello!")
        XCTAssertEqual(dual.swift.transcript[0].entryId, "assistant-4")
        XCTAssertEqual(dual.swift.summary.latestAssistantPreview, "Hello!")
        XCTAssertEqual(dual.swift.summary.providerSessionId, "ps-9")
    }

    func testScenarioEmptyDraftAndToolItemsDoNotAppend() throws {
        let dual = try P6BDualTranscriptReducer()
        try dual.apply(
            P6BFixtures.event("t0", P6BFixtures.runtime("run-1", "turn-1", .stream(P6BFixtures.stream(itemType: "reasoning", text: "think")))),
            cursor: 1
        )
        try dual.apply(
            P6BFixtures.event("t1", P6BFixtures.runtime("run-1", "turn-1", .stream(P6BFixtures.stream(itemType: "tool_call")))),
            cursor: 2
        )
        try dual.apply(
            P6BFixtures.event("t2", P6BFixtures.runtime("run-1", "turn-1", .turnCompleted(AgentHostTurnCompletedV1(turnId: "turn-1", stopReason: "")))),
            cursor: 3
        )
        XCTAssertTrue(dual.swift.transcript.isEmpty)
    }

    func testScenarioTerminatedFailedSettlesPending() throws {
        let dual = try P6BDualTranscriptReducer()
        try dual.apply(
            P6BFixtures.event("t0", .interaction(AgentHostInteractionEventV1(
                kind: .requested(AgentHostInteractionRequestedV1(interaction: P6BFixtures.pending(id: "q1")))
            ))),
            cursor: 1
        )
        XCTAssertTrue(dual.swift.hasLiveRun)
        try dual.apply(
            P6BFixtures.event("t1", P6BFixtures.lifecycle("run-1", .terminated(AgentHostRunTerminatedV1(
                outcome: AgentHostTerminalOutcomeV1(kind: .failed, assistantText: nil, failureReason: .timeout),
                signal: nil
            )))),
            cursor: 2
        )
        XCTAssertEqual(dual.swift.summary.status, .failed)
        XCTAssertEqual(dual.swift.summary.statusText, "failed")
        XCTAssertTrue(dual.swift.pendingInteractions.isEmpty)
        XCTAssertTrue(dual.swift.isTerminal)
    }

    func testScenarioStageDescribeAndCancelledTermination() throws {
        let dual = try P6BDualTranscriptReducer()
        let stages: [(AgentHostLifecycleStageV1, String)] = [
            (.unspecified, "running"),
            (.starting, "starting"),
            (.preparingRuntime, "preparing runtime"),
            (.running, "running"),
            (.waitingForInteraction, "waiting for interaction"),
            (.retrying, "retrying"),
            (.cancelling, "cancelling"),
        ]
        for (index, pair) in stages.enumerated() {
            try dual.apply(
                P6BFixtures.event("t", P6BFixtures.lifecycle("run-1", .stageChanged(AgentHostRunStageChangedV1(
                    stage: pair.0,
                    retryIntent: .none
                )))),
                cursor: UInt64(index + 1)
            )
            XCTAssertEqual(dual.swift.summary.statusText, pair.1)
        }
        try dual.apply(
            P6BFixtures.event("t2", P6BFixtures.lifecycle("run-1", .terminated(AgentHostRunTerminatedV1(
                outcome: AgentHostTerminalOutcomeV1(kind: .cancelled, assistantText: nil, failureReason: .unspecified),
                signal: nil
            )))),
            cursor: 20
        )
        XCTAssertEqual(dual.swift.summary.status, .waitingForInput)
        XCTAssertEqual(dual.swift.summary.statusText, "interrupted")
        XCTAssertFalse(dual.swift.isTerminal)
    }

    func testScenarioInteractionReplaceSettleAndCommandOrder() throws {
        let dual = try P6BDualTranscriptReducer()
        try dual.apply(
            P6BFixtures.event("t0", .interaction(AgentHostInteractionEventV1(
                kind: .requested(AgentHostInteractionRequestedV1(interaction: P6BFixtures.pending(id: "q1")))
            ))),
            cursor: 1
        )
        try dual.apply(
            P6BFixtures.event("t1", .interaction(AgentHostInteractionEventV1(
                kind: .requested(AgentHostInteractionRequestedV1(interaction: P6BFixtures.pending(id: "q1", prompt: "again")))
            ))),
            cursor: 2
        )
        XCTAssertEqual(dual.swift.pendingInteractions.count, 1)
        XCTAssertEqual(dual.swift.pendingInteractions[0].prompt, "again")
        try dual.apply(
            P6BFixtures.event("t2", .interaction(AgentHostInteractionEventV1(
                kind: .settled(AgentHostInteractionSettledV1(
                    interactionId: "q1",
                    interactionGeneration: Data([1, 2]),
                    settlement: .answered,
                    answer: nil,
                    operationId: "op-1"
                ))
            ))),
            cursor: 3
        )
        try dual.apply(
            P6BFixtures.event("t3", .commandAccepted(AgentHostCommandAcceptedV1(
                operationId: "op-b", argumentFingerprint: "fb", commandKind: "steer", acceptedAt: "t3"
            ))),
            cursor: 4
        )
        try dual.apply(
            P6BFixtures.event("t4", .commandAccepted(AgentHostCommandAcceptedV1(
                operationId: "op-a", argumentFingerprint: "fa", commandKind: "start", acceptedAt: "t2"
            ))),
            cursor: 5
        )
        XCTAssertEqual(dual.swift.unsettledOperations.map(\.operationId), ["op-a", "op-b"])
        try dual.apply(
            P6BFixtures.event("t5", .commandSettled(AgentHostCommandSettledV1(
                operationId: "op-a", settledAt: "t5", settlement: nil
            ))),
            cursor: 6
        )
        XCTAssertEqual(dual.swift.unsettledOperations.map(\.operationId), ["op-b"])
    }

    func testScenarioMetadataPreservesAttachedCountAndGeneration() throws {
        let dual = try P6BDualTranscriptReducer()
        try dual.setAttachedClientCount(3)
        try dual.setGeneration(Data([9, 9]))
        let incoming = P6BFixtures.emptySummary(
            sessionName: "renamed",
            status: .running,
            transcriptItemCount: 50,
            updatedAt: "from-summary",
            attachedClientCount: 99,
            generation: Data([1])
        )
        try dual.apply(
            P6BFixtures.event("recorded", .sessionMetadataChanged(AgentHostSessionMetadataChangedV1(summary: incoming))),
            cursor: 4
        )
        XCTAssertTrue(dual.swift.hasMetadata)
        XCTAssertEqual(dual.swift.summary.sessionName, "renamed")
        XCTAssertEqual(dual.swift.summary.attachedClientCount, 3)
        XCTAssertEqual(dual.swift.summary.generation, Data([9, 9]))
        XCTAssertEqual(dual.swift.summary.updatedAt, "from-summary")
    }

    func testScenarioImportedForkedAndNilBodyOnlyAdvanceCursor() throws {
        let dual = try P6BDualTranscriptReducer()
        try dual.apply(
            P6BFixtures.event("t0", .imported(AgentHostImportedV1(
                legacyDigest: "aa", legacyFormat: "json", importedItemCount: 2, importedAt: "t0"
            ))),
            cursor: 1
        )
        try dual.apply(
            P6BFixtures.event("t1", .forkedFrom(AgentHostForkedFromV1(
                sessionId: "parent", cursor: 3, generation: Data([1])
            ))),
            cursor: 2
        )
        try dual.apply(P6BFixtures.event("t2", nil), cursor: 1)
        XCTAssertEqual(dual.swift.lastCursor, 2)
        XCTAssertTrue(dual.swift.transcript.isEmpty)
        XCTAssertEqual(dual.swift.summary.updatedAt, "t2")
    }

    func testScenarioRuntimeInitErrorAndApproval() throws {
        let dual = try P6BDualTranscriptReducer()
        try dual.apply(
            P6BFixtures.event("t0", P6BFixtures.runtime("run-1", "turn-1", .runtimeInit(AgentHostRuntimeInitStatusV1(
                providerSessionId: "ps-init", tools: [], mcpServerStatuses: [], initializeResponse: nil
            )))),
            cursor: 1
        )
        try dual.apply(
            P6BFixtures.event("t1", P6BFixtures.runtime("run-1", "turn-1", .error(AgentHostRuntimeErrorV1(
                code: "e", message: "boom", recoverable: true
            )))),
            cursor: 2
        )
        try dual.apply(
            P6BFixtures.event("t2", P6BFixtures.runtime("run-1", "turn-1", .approvalRequest(AgentHostApprovalRequestV1(
                approvalId: "a",
                requestId: "r",
                requestIdSource: .unspecified,
                method: "",
                kind: .unspecified,
                threadId: "",
                turnId: "",
                itemId: "",
                reason: "",
                command: [],
                cwd: "",
                grantRoot: "",
                proposedExecpolicyAmendmentJson: "",
                details: []
            )))),
            cursor: 3
        )
        XCTAssertEqual(dual.swift.summary.providerSessionId, "ps-init")
        XCTAssertEqual(dual.swift.summary.statusText, "boom")
        XCTAssertTrue(dual.swift.transcript.isEmpty)
    }

    func testScenarioSnapshotRoundTripAndPreviewTruncation() throws {
        let dual = try P6BDualTranscriptReducer()
        let long = String(repeating: "a", count: 250)
        try dual.apply(
            P6BFixtures.event("t0", P6BFixtures.runtime("run-1", "turn-1", .stream(P6BFixtures.stream(itemType: "content", text: long)))),
            cursor: 1
        )
        try dual.apply(
            P6BFixtures.event("t1", P6BFixtures.runtime("run-1", "turn-1", .turnCompleted(AgentHostTurnCompletedV1(turnId: "turn-1", stopReason: "")))),
            cursor: 2
        )
        XCTAssertEqual(dual.swift.summary.latestAssistantPreview.count, 200)
        let snapshot = dual.swift.snapshot(generation: Data([7]), now: "now")
        let restored = try P6BDualTranscriptReducer(snapshot: snapshot)
        XCTAssertEqual(restored.swift.lastCursor, 2)
        XCTAssertTrue(restored.swift.hasMetadata)
    }

    func testScenarioFromSummaryHostOwnedAndReset() throws {
        let summary = P6BFixtures.emptySummary(status: .running, activeRunId: "run-1")
        let dual = try P6BDualTranscriptReducer(summary: summary)
        XCTAssertTrue(dual.swift.hasMetadata)
        _ = try dual.hostOwnedSummary(status: .cancelled, statusText: "stopped", clearingActiveRun: true, now: "now")
        XCTAssertEqual(dual.swift.summary.activeRunId, "run-1")
        try dual.reset()
        XCTAssertFalse(dual.swift.hasMetadata)
    }

    func testScenarioCompletedTerminationAndSteerDedupe() throws {
        let dual = try P6BDualTranscriptReducer()
        let message = P6BFixtures.userMessage(id: "m-steer", text: "again", createdAt: "t0")
        try dual.apply(P6BFixtures.event("t0", .userMessage(message)), cursor: 1)
        try dual.apply(
            P6BFixtures.event("t1", P6BFixtures.lifecycle("run-1", .started(AgentHostRunStartedV1(
                attemptId: "a1",
                message: message
            )))),
            cursor: 2
        )
        XCTAssertEqual(dual.swift.transcript.count, 1)
        try dual.apply(
            P6BFixtures.event("t2", P6BFixtures.lifecycle("run-1", .terminated(AgentHostRunTerminatedV1(
                outcome: AgentHostTerminalOutcomeV1(kind: .completed, assistantText: nil, failureReason: .unspecified),
                signal: nil
            )))),
            cursor: 3
        )
        XCTAssertEqual(dual.swift.summary.status, .waitingForInput)
        XCTAssertEqual(dual.swift.summary.statusText, "turn completed")
        XCTAssertFalse(dual.swift.isTerminal)
    }

    func testSeededRandomCorpusAgrees() throws {
        var rng = P6ASplitMix64(seed: P6BDifferentialConfiguration.seed)
        let dual = try P6BDualTranscriptReducer()
        let steps = 2_048 * P6BDifferentialConfiguration.scale
        for _ in 0..<steps {
            let (event, cursor) = P6BCorpus.event(from: &rng)
            try dual.apply(event, cursor: cursor)
        }
    }
}
