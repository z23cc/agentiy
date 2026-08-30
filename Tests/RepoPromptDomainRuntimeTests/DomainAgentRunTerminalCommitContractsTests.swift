import Foundation
import XCTest
@testable import RepoPromptDomainRuntime

final class DomainAgentRunTerminalCommitContractsTests: XCTestCase {
    private func makeOwnership(
        tabID: UUID = UUID(),
        attemptID: UUID = UUID()
    ) -> DomainAgentRunOwnership {
        DomainAgentRunOwnership(
            attemptID: attemptID,
            binding: DomainAgentRunBindingIdentity(
                tabID: tabID,
                persistentSessionID: UUID()
            )
        )
    }

    func testPhaseIsExclusiveAndReportsTypedRejection() {
        var state = DomainAgentRunTerminalCommitState()

        XCTAssertEqual(state.begin(), .acquired)
        XCTAssertEqual(state.begin(), .alreadyInProgress)
        XCTAssertTrue(state.isInProgress)

        state.abort()

        XCTAssertFalse(state.isInProgress)
        XCTAssertEqual(state.begin(), .acquired)
    }

    func testStagedReceiptBindsCommitToOwnershipAndClearsPriorResult() {
        var state = DomainAgentRunTerminalCommitState()
        let ownership = makeOwnership()
        let commitID = UUID()

        state.record(.stale)
        XCTAssertTrue(state.stage(commitID: commitID, ownership: ownership))

        XCTAssertEqual(
            state.stagedReceipt,
            DomainAgentRunTerminalCommitReceipt(commitID: commitID, ownership: ownership)
        )
        XCTAssertNil(state.publicationResult)
        XCTAssertTrue(state.matches(ownership: ownership))
        XCTAssertFalse(state.matches(ownership: makeOwnership()))
    }

    func testPublicationResultMayArriveAfterPhaseCompletes() {
        var state = DomainAgentRunTerminalCommitState()
        let ownership = makeOwnership()
        _ = state.begin(ownership: ownership)
        XCTAssertTrue(state.stage(commitID: UUID(), ownership: ownership))
        state.complete()

        state.record(.rejected(reason: "transient"))

        XCTAssertFalse(state.isInProgress)
        XCTAssertEqual(state.publicationResult, .rejected(reason: "transient"))
        XCTAssertTrue(state.matches(ownership: ownership))
    }

    func testBeginRejectsOwnerChangedAfterCompatibilityPreStage() {
        var state = DomainAgentRunTerminalCommitState()
        let first = makeOwnership()
        let successor = makeOwnership()

        XCTAssertTrue(state.stage(commitID: UUID(), ownership: first))
        XCTAssertEqual(state.begin(ownership: successor), .staleOwnership)
        XCTAssertFalse(state.isInProgress)
        XCTAssertTrue(state.matches(ownership: first))
    }

    func testTrackerRejectsStaleStageAndResetsTerminalStateForSuccessorAttempt() {
        var tracker = DomainAgentRunLifecycleTracker()
        let first = tracker.begin(
            tabID: UUID(),
            persistentSessionID: UUID(),
            timestampUptimeNanoseconds: 10
        )
        let stale = makeOwnership()
        XCTAssertEqual(tracker.beginTerminalCommit(), .acquired)
        XCTAssertFalse(tracker.stageTerminalCommit(commitID: UUID(), ownership: stale))
        XCTAssertTrue(tracker.stageTerminalCommit(commitID: UUID(), ownership: first))
        tracker.recordTerminalPublicationResult(.accepted(successorEpoch: nil))

        let second = tracker.begin(
            tabID: first.binding.tabID,
            persistentSessionID: first.binding.persistentSessionID,
            timestampUptimeNanoseconds: 20
        )

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(tracker.terminalCommitInProgress)
        XCTAssertNil(tracker.terminalCommitReceipt)
        XCTAssertNil(tracker.terminalCommitPublicationResult)
    }

    func testBindingInvalidationClearsReceiptAndResultWithoutReleasingPhase() {
        var tracker = DomainAgentRunLifecycleTracker()
        let ownership = tracker.begin(
            tabID: UUID(),
            persistentSessionID: nil,
            timestampUptimeNanoseconds: 1
        )
        XCTAssertEqual(tracker.beginTerminalCommit(), .acquired)
        XCTAssertTrue(tracker.stageTerminalCommit(commitID: UUID(), ownership: ownership))
        tracker.recordTerminalPublicationResult(.accepted(successorEpoch: nil))

        tracker.invalidateTerminalCommit()

        XCTAssertTrue(tracker.terminalCommitInProgress)
        XCTAssertNil(tracker.terminalCommitReceipt)
        XCTAssertNil(tracker.terminalCommitPublicationResult)
    }
}
