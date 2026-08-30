import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainAgentRunLifecycleContractsTests: XCTestCase {
    func testOwnershipCapturesImmutableTurnEpoch() {
        let sessionID = UUID()
        let epoch = DomainAgentRunTurnEpoch(
            sessionID: sessionID,
            activationID: UUID(),
            registrationGeneration: 7,
            id: UUID(),
            ordinal: 3,
            continuityGeneration: 1,
            transitionKind: .relatedFollowUp
        )
        var tracker = DomainAgentRunLifecycleTracker()
        let ownership = tracker.begin(
            tabID: UUID(),
            persistentSessionID: sessionID,
            turnEpoch: epoch,
            timestampUptimeNanoseconds: 100
        )

        XCTAssertEqual(ownership.turnEpoch, epoch)
        XCTAssertEqual(tracker.activeOwnership?.turnEpoch, epoch)
    }

    func testOwnershipRejectsStaleSignalsAndSequenceViolations() {
        let tabID = UUID()
        let sessionID = UUID()
        var tracker = DomainAgentRunLifecycleTracker()
        let ownership = tracker.begin(
            tabID: tabID,
            persistentSessionID: sessionID,
            timestampUptimeNanoseconds: 100
        )
        let staleOwnership = DomainAgentRunOwnership(
            binding: DomainAgentRunBindingIdentity(tabID: tabID, persistentSessionID: sessionID)
        )

        XCTAssertEqual(
            tracker.accept(.init(
                ownership: staleOwnership,
                sequence: 1,
                timestampUptimeNanoseconds: 110,
                kind: .providerEvent,
                stage: .running,
                retryIntent: .none
            )),
            .rejected(.staleOwnership)
        )

        let accepted = DomainAgentRunProgressSignal(
            ownership: ownership,
            sequence: 1,
            timestampUptimeNanoseconds: 120,
            kind: .providerEvent,
            stage: .running,
            retryIntent: .none
        )
        guard case let .accepted(snapshot) = tracker.accept(accepted) else {
            return XCTFail("Expected first current-ownership signal to be accepted")
        }
        XCTAssertEqual(snapshot.lastAcceptedSequence, 1)
        XCTAssertEqual(tracker.accept(accepted), .rejected(.duplicateSequence))
        XCTAssertEqual(
            tracker.accept(.init(
                ownership: ownership,
                sequence: 0,
                timestampUptimeNanoseconds: 130,
                kind: .providerEvent,
                stage: .running,
                retryIntent: .none
            )),
            .rejected(.outOfOrderSequence)
        )
        XCTAssertEqual(
            tracker.accept(.init(
                ownership: ownership,
                sequence: 2,
                timestampUptimeNanoseconds: 119,
                kind: .providerEvent,
                stage: .running,
                retryIntent: .none
            )),
            .rejected(.nonMonotonicTimestamp)
        )
    }

    func testHeartbeatAdvancesSignalTimeWithoutManufacturingProgress() {
        var tracker = DomainAgentRunLifecycleTracker()
        let ownership = tracker.begin(
            tabID: UUID(),
            persistentSessionID: nil,
            timestampUptimeNanoseconds: 100
        )

        guard case let .accepted(providerSnapshot) = tracker.record(
            ownership: ownership,
            kind: .providerEvent,
            stage: .running,
            timestampUptimeNanoseconds: 200
        ) else {
            return XCTFail("Expected provider progress")
        }
        guard case let .accepted(heartbeatSnapshot) = tracker.record(
            ownership: ownership,
            kind: .heartbeat,
            stage: .running,
            timestampUptimeNanoseconds: 300
        ) else {
            return XCTFail("Expected heartbeat")
        }

        XCTAssertEqual(providerSnapshot.lastRealProgressUptimeNanoseconds, 200)
        XCTAssertEqual(heartbeatSnapshot.lastSignalUptimeNanoseconds, 300)
        XCTAssertEqual(heartbeatSnapshot.lastHeartbeatUptimeNanoseconds, 300)
        XCTAssertEqual(heartbeatSnapshot.lastRealProgressUptimeNanoseconds, 200)
    }

    func testRetryIntentAndStageRemainNonRenderingLifecycleState() {
        var tracker = DomainAgentRunLifecycleTracker()
        let ownership = tracker.begin(
            tabID: UUID(),
            persistentSessionID: nil,
            timestampUptimeNanoseconds: 10
        )

        guard case let .accepted(snapshot) = tracker.record(
            ownership: ownership,
            kind: .stageTransition,
            stage: .retrying,
            retryIntent: .providerManaged,
            timestampUptimeNanoseconds: 20
        ) else {
            return XCTFail("Expected retry transition")
        }

        XCTAssertEqual(snapshot.stage, .retrying)
        XCTAssertEqual(snapshot.retryIntent, .providerManaged)
    }

    func testEndRequiresCurrentOwnershipAndResetsTheReducer() {
        var tracker = DomainAgentRunLifecycleTracker()
        let ownership = tracker.begin(tabID: UUID(), persistentSessionID: nil, timestampUptimeNanoseconds: 1)
        let stale = DomainAgentRunOwnership(
            binding: DomainAgentRunBindingIdentity(tabID: UUID(), persistentSessionID: nil)
        )

        XCTAssertFalse(tracker.end(ifCurrent: stale))
        XCTAssertTrue(tracker.end(ifCurrent: ownership))
        XCTAssertNil(tracker.activeOwnership)
        XCTAssertNil(tracker.liveness)
    }

    func testProcessIdentityUsesExactRunFenceAndForceClearSemantics() {
        let firstRunID = UUID()
        let successorRunID = UUID()
        var identity = DomainAgentRunProcessIdentityState()

        identity.install(firstRunID)
        identity.bumpTerminalDrainGeneration()
        XCTAssertEqual(identity.runID, firstRunID)
        XCTAssertEqual(identity.terminalDrainGeneration, 1)

        XCTAssertFalse(identity.clear(ifCurrent: successorRunID))
        XCTAssertEqual(identity.runID, firstRunID)

        identity.install(successorRunID)
        XCTAssertFalse(identity.clear(ifCurrent: firstRunID))
        XCTAssertEqual(identity.runID, successorRunID)
        XCTAssertTrue(identity.clear(ifCurrent: successorRunID))
        XCTAssertNil(identity.runID)

        identity.install(firstRunID)
        identity.forceClear()
        XCTAssertNil(identity.runID)
    }

    func testNewAttemptResetsDrainGenerationButPreservesProcessIdentity() {
        let runID = UUID()
        var tracker = DomainAgentRunLifecycleTracker()
        tracker.installProcessRunID(runID)
        tracker.bumpTerminalDrainGeneration()
        tracker.bumpTerminalDrainGeneration()
        XCTAssertEqual(tracker.terminalDrainGeneration, 2)

        let ownership = tracker.begin(
            tabID: UUID(),
            persistentSessionID: UUID(),
            timestampUptimeNanoseconds: 100
        )

        XCTAssertEqual(tracker.processRunID, runID)
        XCTAssertEqual(tracker.terminalDrainGeneration, 0)
        XCTAssertEqual(tracker.activeOwnership, ownership)
    }

    func testTrackerProcessIdentityClearRemainsStaleSafeAfterSuccessorInstallation() {
        var tracker = DomainAgentRunLifecycleTracker()
        let firstRunID = UUID()
        let successorRunID = UUID()
        tracker.installProcessRunID(firstRunID)
        tracker.installProcessRunID(successorRunID)

        XCTAssertFalse(tracker.clearProcessRunID(ifCurrent: firstRunID))
        XCTAssertEqual(tracker.processRunID, successorRunID)
        XCTAssertTrue(tracker.clearProcessRunID(ifCurrent: successorRunID))
        XCTAssertNil(tracker.processRunID)
    }
}
