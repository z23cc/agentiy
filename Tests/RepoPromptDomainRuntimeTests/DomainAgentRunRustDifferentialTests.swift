import AgentryCoreBridge
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// ADR-0011 P6-a (B track) differential harness: every Swift `DomainAgentRun*` reducer test
/// scenario is replayed through the Swift reducer and its Rust twin
/// (`agentry_runtime::agent_run_lifecycle` via `AgentryCoreBridge`), asserting identical results,
/// identical observable state, and identical canonical JSON after every transition. Seeded random
/// corpora then widen coverage to event orderings the hand-written scenarios never reach.
///
/// Any disagreement is a Rust bug (fix in Rust) or a Swift bug (report; never change Swift here).
/// Reproduce a corpus with `AGENTRY_P6A_DIFFERENTIAL_SEED=<seed>`; widen it with
/// `AGENTRY_P6A_DIFFERENTIAL_SCALE=<n>`.
final class DomainAgentRunRustDifferentialTests: XCTestCase {
    // MARK: - Lifecycle tracker scenarios (DomainAgentRunLifecycleContractsTests)

    func testScenarioOwnershipCapturesImmutableTurnEpoch() throws {
        var rng = P6ASplitMix64(seed: 1)
        let tracker = P6ADualLifecycleTracker()
        let epoch = P6AFixtures.epoch(&rng)
        let ownership = try tracker.begin(
            tabID: rng.uuid(),
            persistentSessionID: epoch.sessionID,
            turnEpoch: epoch,
            timestampUptimeNanoseconds: 100
        )
        XCTAssertEqual(ownership.turnEpoch, epoch)
        XCTAssertEqual(try tracker.rust.state().activeOwnership?.turnEpoch, epoch.p6aV1)
    }

    func testScenarioOwnershipRejectsStaleSignalsAndSequenceViolations() throws {
        var rng = P6ASplitMix64(seed: 2)
        let tracker = P6ADualLifecycleTracker()
        let tabID = rng.uuid()
        let sessionID = rng.uuid()
        let ownership = try tracker.begin(tabID: tabID, persistentSessionID: sessionID, timestampUptimeNanoseconds: 100)
        let stale = DomainAgentRunOwnership(
            attemptID: rng.uuid(),
            binding: DomainAgentRunBindingIdentity(tabID: tabID, persistentSessionID: sessionID, generation: rng.uuid())
        )

        XCTAssertEqual(
            try tracker.accept(.init(ownership: stale, sequence: 1, timestampUptimeNanoseconds: 110, kind: .providerEvent, stage: .running, retryIntent: .none)),
            .rejected(.staleOwnership)
        )
        let accepted = DomainAgentRunProgressSignal(
            ownership: ownership, sequence: 1, timestampUptimeNanoseconds: 120, kind: .providerEvent, stage: .running, retryIntent: .none
        )
        guard case let .accepted(snapshot) = try tracker.accept(accepted) else {
            return XCTFail("Expected first current-ownership signal to be accepted")
        }
        XCTAssertEqual(snapshot.lastAcceptedSequence, 1)
        XCTAssertEqual(try tracker.accept(accepted), .rejected(.duplicateSequence))
        XCTAssertEqual(
            try tracker.accept(.init(ownership: ownership, sequence: 0, timestampUptimeNanoseconds: 130, kind: .providerEvent, stage: .running, retryIntent: .none)),
            .rejected(.outOfOrderSequence)
        )
        XCTAssertEqual(
            try tracker.accept(.init(ownership: ownership, sequence: 2, timestampUptimeNanoseconds: 119, kind: .providerEvent, stage: .running, retryIntent: .none)),
            .rejected(.nonMonotonicTimestamp)
        )
        // Beyond the Swift test: a caller-sequenced jump must advance Rust's private
        // `nextSequence` identically, which the following `record` observes.
        XCTAssertEqual(
            try tracker.accept(.init(ownership: ownership, sequence: 40, timestampUptimeNanoseconds: 140, kind: .toolActivity, stage: .running, retryIntent: .none)).p6aV1.isAccepted,
            true
        )
        guard case let .accepted(afterJump) = try tracker.record(ownership: ownership, kind: .heartbeat, stage: .running, timestampUptimeNanoseconds: 150) else {
            return XCTFail("Expected record after sequence jump to be accepted")
        }
        XCTAssertEqual(afterJump.lastAcceptedSequence, 41)
    }

    func testScenarioHeartbeatAdvancesSignalTimeWithoutManufacturingProgress() throws {
        var rng = P6ASplitMix64(seed: 3)
        let tracker = P6ADualLifecycleTracker()
        let ownership = try tracker.begin(tabID: rng.uuid(), persistentSessionID: nil, timestampUptimeNanoseconds: 100)
        try tracker.record(ownership: ownership, kind: .providerEvent, stage: .running, timestampUptimeNanoseconds: 200)
        guard case let .accepted(heartbeat) = try tracker.record(ownership: ownership, kind: .heartbeat, stage: .running, timestampUptimeNanoseconds: 300) else {
            return XCTFail("Expected heartbeat")
        }
        XCTAssertEqual(heartbeat.lastHeartbeatUptimeNanoseconds, 300)
        XCTAssertEqual(heartbeat.lastRealProgressUptimeNanoseconds, 200)
    }

    func testScenarioRetryIntentAndStageRemainNonRenderingLifecycleState() throws {
        var rng = P6ASplitMix64(seed: 4)
        let tracker = P6ADualLifecycleTracker()
        let ownership = try tracker.begin(tabID: rng.uuid(), persistentSessionID: nil, timestampUptimeNanoseconds: 10)
        guard case let .accepted(snapshot) = try tracker.record(
            ownership: ownership, kind: .stageTransition, stage: .retrying, retryIntent: .providerManaged, timestampUptimeNanoseconds: 20
        ) else {
            return XCTFail("Expected retry transition")
        }
        XCTAssertEqual(snapshot.stage, .retrying)
        XCTAssertEqual(snapshot.retryIntent, .providerManaged)
    }

    func testScenarioEndRequiresCurrentOwnershipAndResetsTheReducer() throws {
        var rng = P6ASplitMix64(seed: 5)
        let tracker = P6ADualLifecycleTracker()
        let ownership = try tracker.begin(tabID: rng.uuid(), persistentSessionID: nil, timestampUptimeNanoseconds: 1)
        let stale = DomainAgentRunOwnership(
            attemptID: rng.uuid(),
            binding: DomainAgentRunBindingIdentity(tabID: rng.uuid(), persistentSessionID: nil, generation: rng.uuid())
        )
        XCTAssertFalse(try tracker.end(ifCurrent: stale))
        XCTAssertTrue(try tracker.end(ifCurrent: ownership))
        XCTAssertFalse(try tracker.end())
        XCTAssertEqual(
            try tracker.record(ownership: ownership, kind: .heartbeat, stage: .running, timestampUptimeNanoseconds: 2),
            .rejected(.noActiveOwnership)
        )
    }

    func testScenarioProcessIdentityUsesExactRunFenceAndForceClearSemantics() throws {
        var rng = P6ASplitMix64(seed: 6)
        let first = rng.uuid()
        let successor = rng.uuid()
        let identity = try P6ADualProcessIdentity()

        try identity.install(first)
        try identity.bumpTerminalDrainGeneration()
        XCTAssertFalse(try identity.clear(ifCurrent: successor))
        try identity.install(successor)
        XCTAssertFalse(try identity.clear(ifCurrent: first))
        XCTAssertTrue(try identity.clear(ifCurrent: successor))
        try identity.install(first)
        try identity.forceClear()
        try identity.resetForNewAttempt()

        // Non-default construction is also part of the Swift surface.
        let seeded = try P6ADualProcessIdentity(runID: first, terminalDrainGeneration: 41)
        try seeded.bumpTerminalDrainGeneration()
        XCTAssertEqual(try seeded.rust.state().terminalDrainGeneration, 42)
    }

    func testScenarioNewAttemptResetsDrainGenerationButPreservesProcessIdentity() throws {
        var rng = P6ASplitMix64(seed: 7)
        let tracker = P6ADualLifecycleTracker()
        let runID = rng.uuid()
        try tracker.installProcessRunID(runID)
        try tracker.bumpTerminalDrainGeneration()
        try tracker.bumpTerminalDrainGeneration()
        try tracker.begin(tabID: rng.uuid(), persistentSessionID: rng.uuid(), timestampUptimeNanoseconds: 100)
        XCTAssertEqual(try tracker.rust.state().processRunId, runID.p6aLowered)
        XCTAssertEqual(try tracker.rust.state().terminalDrainGeneration, 0)
    }

    func testScenarioTrackerProcessIdentityClearRemainsStaleSafeAfterSuccessorInstallation() throws {
        var rng = P6ASplitMix64(seed: 8)
        let tracker = P6ADualLifecycleTracker()
        let first = rng.uuid()
        let successor = rng.uuid()
        try tracker.installProcessRunID(first)
        try tracker.installProcessRunID(successor)
        XCTAssertFalse(try tracker.clearProcessRunID(ifCurrent: first))
        XCTAssertTrue(try tracker.clearProcessRunID(ifCurrent: successor))
        try tracker.installProcessRunID(first)
        try tracker.forceClearProcessRunID()
    }

    // MARK: - Terminal commit scenarios (DomainAgentRunTerminalCommitContractsTests)

    func testScenarioPhaseIsExclusiveAndReportsTypedRejection() throws {
        let state = P6ADualTerminalCommit()
        XCTAssertEqual(try state.begin(), .acquired)
        XCTAssertEqual(try state.begin(), .alreadyInProgress)
        try state.abort()
        XCTAssertEqual(try state.begin(), .acquired)
        try state.complete()
        XCTAssertEqual(try state.begin(), .acquired)
    }

    func testScenarioStagedReceiptBindsCommitToOwnershipAndClearsPriorResult() throws {
        var rng = P6ASplitMix64(seed: 9)
        let pool = P6AFixtures.ownershipPool(&rng)
        let state = P6ADualTerminalCommit()
        try state.record(.stale)
        XCTAssertTrue(try state.stage(commitID: rng.uuid(), ownership: pool[0]))
        XCTAssertTrue(try state.matches(ownership: pool[0]))
        XCTAssertFalse(try state.matches(ownership: pool[1]))
        XCTAssertFalse(try state.stage(commitID: rng.uuid(), ownership: pool[1]))
        XCTAssertTrue(try state.stage(commitID: rng.uuid(), ownership: pool[0]))
    }

    func testScenarioPublicationResultMayArriveAfterPhaseCompletes() throws {
        var rng = P6ASplitMix64(seed: 10)
        let pool = P6AFixtures.ownershipPool(&rng)
        let state = P6ADualTerminalCommit()
        _ = try state.begin(ownership: pool[0])
        XCTAssertTrue(try state.stage(commitID: rng.uuid(), ownership: pool[0]))
        try state.complete()
        try state.record(.rejected(reason: "transient"))
        XCTAssertTrue(try state.matches(ownership: pool[0]))
        try state.record(.accepted(successorEpoch: P6AFixtures.epoch(&rng)))
        try state.invalidate()
        try state.reset()
    }

    func testScenarioBeginRejectsOwnerChangedAfterCompatibilityPreStage() throws {
        var rng = P6ASplitMix64(seed: 11)
        let pool = P6AFixtures.ownershipPool(&rng)
        let state = P6ADualTerminalCommit()
        XCTAssertTrue(try state.stage(commitID: rng.uuid(), ownership: pool[0]))
        XCTAssertEqual(try state.begin(ownership: pool[1]), .staleOwnership)
        XCTAssertEqual(try state.begin(ownership: nil), .acquired)
        try state.abort()
        XCTAssertEqual(try state.begin(ownership: pool[0]), .acquired)
    }

    func testScenarioTrackerRejectsStaleStageAndResetsTerminalStateForSuccessorAttempt() throws {
        var rng = P6ASplitMix64(seed: 12)
        let pool = P6AFixtures.ownershipPool(&rng)
        let tracker = P6ADualLifecycleTracker()
        let first = try tracker.begin(tabID: rng.uuid(), persistentSessionID: rng.uuid(), timestampUptimeNanoseconds: 10)
        XCTAssertEqual(try tracker.beginTerminalCommit(), .acquired)
        XCTAssertFalse(try tracker.stageTerminalCommit(commitID: rng.uuid(), ownership: pool[3]))
        XCTAssertTrue(try tracker.stageTerminalCommit(commitID: rng.uuid(), ownership: first))
        XCTAssertTrue(try tracker.hasTerminalCommit(for: first))
        XCTAssertFalse(try tracker.hasTerminalCommit(for: pool[3]))
        try tracker.recordTerminalPublicationResult(.accepted(successorEpoch: nil))
        try tracker.completeTerminalCommit()
        try tracker.begin(
            tabID: first.binding.tabID,
            persistentSessionID: first.binding.persistentSessionID,
            timestampUptimeNanoseconds: 20
        )
        XCTAssertFalse(try tracker.hasTerminalCommit(for: first))
    }

    func testScenarioBindingInvalidationClearsReceiptAndResultWithoutReleasingPhase() throws {
        var rng = P6ASplitMix64(seed: 13)
        let tracker = P6ADualLifecycleTracker()
        let ownership = try tracker.begin(tabID: rng.uuid(), persistentSessionID: nil, timestampUptimeNanoseconds: 1)
        XCTAssertEqual(try tracker.beginTerminalCommit(), .acquired)
        XCTAssertTrue(try tracker.stageTerminalCommit(commitID: rng.uuid(), ownership: ownership))
        try tracker.recordTerminalPublicationResult(.accepted(successorEpoch: nil))
        try tracker.invalidateTerminalCommit()
        XCTAssertTrue(try tracker.rust.state().terminalCommitInProgress)
        XCTAssertNil(try tracker.rust.state().terminalCommitReceipt)
        try tracker.abortTerminalCommit()
        // The phase owner outlives `end`: a successor must still be fenced out.
        XCTAssertTrue(try tracker.end())
        XCTAssertEqual(try tracker.beginTerminalCommit(), .acquired)
        XCTAssertTrue(try tracker.stageTerminalCommit(commitID: rng.uuid(), ownership: ownership))
        try tracker.reset()
    }

    // MARK: - Settlement scenarios (DomainAgentRunTerminalSettlementContractsTests)

    func testScenarioProviderSuccessorConsumptionIsExactlyOnce() throws {
        var rng = P6ASplitMix64(seed: 14)
        let coordinator = P6ADualSettlement()
        let successor = rng.uuid()
        XCTAssertFalse(try coordinator.hasConsumedProviderSuccessor(id: successor))
        XCTAssertTrue(try coordinator.recordProviderSuccessorConsumption(id: successor))
        XCTAssertTrue(try coordinator.hasConsumedProviderSuccessor(id: successor))
        XCTAssertFalse(try coordinator.recordProviderSuccessorConsumption(id: successor))
    }

    func testScenarioFailedSuccessorDeliveryDoesNotCreateATombstone() throws {
        var rng = P6ASplitMix64(seed: 15)
        let coordinator = P6ADualSettlement()
        let successor = rng.uuid()
        XCTAssertFalse(try coordinator.recordProviderSuccessorConsumption(id: successor, deliverySucceeded: false))
        XCTAssertFalse(try coordinator.hasConsumedProviderSuccessor(id: successor))
        XCTAssertTrue(try coordinator.recordProviderSuccessorConsumption(id: successor))
        XCTAssertFalse(try coordinator.recordProviderSuccessorConsumption(id: successor, deliverySucceeded: false))
        XCTAssertTrue(try coordinator.hasConsumedProviderSuccessor(id: successor))
    }

    func testScenarioSuccessorTombstonesUseBoundedFIFOEviction() throws {
        var rng = P6ASplitMix64(seed: 16)
        let coordinator = P6ADualSettlement()
        let bound = DomainAgentRunTerminalSettlementCoordinator.maxProviderSuccessorTombstones
        let first = rng.uuid()
        XCTAssertTrue(try coordinator.recordProviderSuccessorConsumption(id: first))
        for _ in 1 ..< bound {
            // Probing all known IDs each step is O(n²) at this size; probe at the boundaries.
            XCTAssertTrue(try coordinator.recordProviderSuccessorConsumption(id: rng.uuid(), probe: false))
        }
        try coordinator.assertAgreement("at bound")
        XCTAssertTrue(try coordinator.hasConsumedProviderSuccessor(id: first))
        let newest = rng.uuid()
        XCTAssertTrue(try coordinator.recordProviderSuccessorConsumption(id: newest))
        XCTAssertFalse(try coordinator.hasConsumedProviderSuccessor(id: first))
        XCTAssertTrue(try coordinator.hasConsumedProviderSuccessor(id: newest))
        // Re-recording an evicted ID re-tombstones it and evicts the next-oldest.
        XCTAssertTrue(try coordinator.recordProviderSuccessorConsumption(id: first))
        XCTAssertEqual(try coordinator.rust.state().consumedProviderSuccessorCount, UInt64(bound))
    }

    func testScenarioTeardownRegistrationAndCompletionAreTokenBound() throws {
        var rng = P6ASplitMix64(seed: 17)
        let pool = P6AFixtures.ownershipPool(&rng)
        let coordinator = P6ADualSettlement()
        let token = rng.uuid()
        XCTAssertEqual(try coordinator.registerTeardown(ownership: pool[0], token: token), .registered)
        XCTAssertTrue(try coordinator.hasPendingTeardown(for: pool[0]))
        XCTAssertEqual(try coordinator.teardownToken(for: pool[0]), token)
        XCTAssertEqual(try coordinator.registerTeardown(ownership: pool[0], token: rng.uuid()), .alreadyRegistered)
        XCTAssertFalse(try coordinator.completeTeardown(ownership: pool[0], token: rng.uuid()))
        XCTAssertFalse(try coordinator.completeTeardown(ownership: pool[1], token: token))
        XCTAssertTrue(try coordinator.completeTeardown(ownership: pool[0], token: token))
        XCTAssertFalse(try coordinator.completeTeardown(ownership: pool[0], token: token))
        XCTAssertNil(try coordinator.teardownToken(for: pool[0]))
    }

    func testScenarioTeardownTokensAreIndependentAcrossOwners() throws {
        var rng = P6ASplitMix64(seed: 18)
        let pool = P6AFixtures.ownershipPool(&rng)
        let coordinator = P6ADualSettlement()
        let tokens = pool.map { _ in rng.uuid() }
        for (ownership, token) in zip(pool, tokens) {
            XCTAssertEqual(try coordinator.registerTeardown(ownership: ownership, token: token), .registered)
        }
        XCTAssertTrue(try coordinator.completeTeardown(ownership: pool[0], token: tokens[0]))
        XCTAssertTrue(try coordinator.hasPendingTeardown(for: pool[1]))
        XCTAssertTrue(try coordinator.completeTeardown(ownership: pool[4], token: tokens[4]))
        XCTAssertFalse(try coordinator.completeTeardown(ownership: pool[5], token: tokens[4]))
    }

    func testScenarioResetClearsSettlementFences() throws {
        var rng = P6ASplitMix64(seed: 19)
        let pool = P6AFixtures.ownershipPool(&rng)
        let coordinator = P6ADualSettlement()
        let successor = rng.uuid()
        XCTAssertTrue(try coordinator.recordProviderSuccessorConsumption(id: successor))
        XCTAssertEqual(try coordinator.registerTeardown(ownership: pool[0], token: rng.uuid()), .registered)
        try coordinator.reset()
        XCTAssertFalse(try coordinator.hasConsumedProviderSuccessor(id: successor))
        XCTAssertFalse(try coordinator.hasPendingTeardown(for: pool[0]))
    }

    // MARK: - Semantic authority scenarios (DomainAgentRunProviderSemanticContractsTests)

    func testScenarioEveryTerminationSignalResolvesIdentically() throws {
        let authority = CoreAgentRunSemanticAuthority()
        let signals = P6AFixtures.exhaustiveTerminationSignals
        for signal in signals {
            let expected = DomainAgentRunProviderSemanticAuthority.resolve(signal)
            XCTAssertEqual(try authority.resolve(signal.p6aV1), expected.p6aV1, "resolve \(signal)")
            XCTAssertEqual(
                try authority.outcome(signal.p6aV1),
                DomainAgentRunProviderSemanticAuthority.outcome(signal)?.p6aV1,
                "outcome \(signal)"
            )
            XCTAssertEqual(
                try authority.isTerminal(signal.p6aV1),
                DomainAgentRunProviderSemanticAuthority.isTerminal(signal),
                "isTerminal \(signal)"
            )
        }
        print("P6A_DIFFERENTIAL semantic-authority signals=\(signals.count) agreement=100%")
    }

    func testScenarioExecuteProviderClassificationMatchesSwiftCore() async throws {
        let authority = CoreAgentRunSemanticAuthority()
        var endings: [P6AOperationEnding<DomainAgentRunProviderExecutionResult>] = [
            .threwCancellation
        ]
        for text in P6AFixtures.assistantTexts {
            endings.append(.returned(.completed(assistantText: text)))
            endings.append(.returned(.cancelled(assistantText: text)))
            endings.append(.threwError(text ?? "unclassified provider failure"))
        }
        for signal in P6AFixtures.exhaustiveTerminationSignals {
            endings.append(.returned(.failed(signal: signal)))
        }
        endings.append(.returned(.superseded))

        for ending in endings {
            let swiftReport = await DomainAgentRunExecutionCore.executeProvider(
                failureText: { _ in ending.failureText }
            ) {
                try ending.perform()
            }
            XCTAssertEqual(try authority.classifyProviderExecution(ending.p6aV1), swiftReport.p6aV1, "\(ending)")
        }
        print("P6A_DIFFERENTIAL execute-provider endings=\(endings.count) agreement=100%")
    }

    // MARK: - Execution core scenarios (DomainAgentRunExecutionContractsTests classification half)

    func testScenarioExecuteClassificationMatchesSwiftCore() async throws {
        let authority = CoreAgentRunSemanticAuthority()
        var endings: [P6AOperationEnding<DomainAgentRunExecutionOperationResult>] = [
            .threwCancellation,
            .returned(.superseded)
        ]
        for text in P6AFixtures.assistantTexts {
            endings.append(.returned(.completed(assistantText: text)))
            endings.append(.threwError(text ?? "mapped failure"))
        }
        for outcome in P6AFixtures.exhaustiveTerminalOutcomes {
            endings.append(.returned(.terminal(outcome)))
        }

        var compared = 0
        for ending in endings {
            for failureReason in P6AFixtures.failureReasons {
                for deferFailureClassification in [false, true] {
                    let swiftReport = await DomainAgentRunExecutionCore.execute(
                        failureReason: failureReason,
                        deferFailureClassification: deferFailureClassification,
                        failureText: { _ in ending.failureText }
                    ) {
                        try ending.perform()
                    }
                    XCTAssertEqual(
                        try authority.classifyExecution(
                            ending.p6aV1,
                            failureReason: failureReason.p6aV1,
                            deferFailureClassification: deferFailureClassification
                        ),
                        swiftReport.p6aV1,
                        "\(ending) reason=\(failureReason) defer=\(deferFailureClassification)"
                    )
                    compared += 1
                }
            }
        }
        print("P6A_DIFFERENTIAL execute classifications=\(compared) agreement=100%")
    }

    // MARK: - Seeded random corpora

    func testCorpusLifecycleTrackerAgreesOnRandomEventSequences() throws {
        let seed = P6ADifferentialConfiguration.seed(for: "tracker")
        let sequences = 160 * P6ADifferentialConfiguration.scale
        let stepsPerSequence = 64
        var rng = P6ASplitMix64(seed: seed)
        let ledger = P6ADifferentialLedger()

        for sequence in 0 ..< sequences {
            ledger.context = "tracker seed=\(seed) sequence=\(sequence)"
            let tracker = P6ADualLifecycleTracker(ledger: ledger)
            let pool = P6AFixtures.ownershipPool(&rng)
            let runIDs = (0 ..< 3).map { _ in rng.uuid() }
            var timestamp = UInt64(rng.below(1000))
            var active: DomainAgentRunOwnership?

            func ownershipChoice() -> DomainAgentRunOwnership {
                if let active, rng.percent(70) { return active }
                return rng.pick(pool)
            }
            func nextTimestamp() -> UInt64 {
                // Mostly monotonic, occasionally equal, occasionally backwards.
                switch rng.below(10) {
                case 0: timestamp = timestamp > 7 ? timestamp - 7 : 0
                case 1: break
                default: timestamp += UInt64(1 + rng.below(50))
                }
                return timestamp
            }

            for _ in 0 ..< stepsPerSequence {
                switch rng.below(100) {
                case 0 ..< 8:
                    let template = rng.pick(pool)
                    active = try tracker.begin(
                        tabID: template.binding.tabID,
                        persistentSessionID: template.binding.persistentSessionID,
                        persistentBindingGeneration: template.binding.persistentBindingGeneration,
                        bindingTransitionGeneration: template.binding.bindingTransitionGeneration,
                        attemptID: rng.percent(50) ? template.attemptID : rng.uuid(),
                        turnEpoch: rng.percent(50) ? template.turnEpoch : nil,
                        timestampUptimeNanoseconds: nextTimestamp()
                    )
                case 8 ..< 30:
                    try tracker.record(
                        ownership: ownershipChoice(),
                        kind: rng.pick(P6AFixtures.signalKinds),
                        stage: rng.pick(P6AFixtures.stages),
                        retryIntent: rng.pick(P6AFixtures.retryIntents),
                        timestampUptimeNanoseconds: nextTimestamp()
                    )
                case 30 ..< 46:
                    let last = tracker.swift.liveness?.lastAcceptedSequence ?? 0
                    let sequenceChoice: UInt64 = switch rng.below(6) {
                    case 0: last
                    case 1: last > 0 ? last - 1 : 0
                    case 2: last &+ 1
                    case 3: last &+ UInt64(2 + rng.below(5))
                    case 4: UInt64.max - UInt64(rng.below(2))
                    default: 0
                    }
                    try tracker.accept(DomainAgentRunProgressSignal(
                        ownership: ownershipChoice(),
                        sequence: sequenceChoice,
                        timestampUptimeNanoseconds: nextTimestamp(),
                        kind: rng.pick(P6AFixtures.signalKinds),
                        stage: rng.pick(P6AFixtures.stages),
                        retryIntent: rng.pick(P6AFixtures.retryIntents)
                    ))
                case 46 ..< 52:
                    let expected: DomainAgentRunOwnership? = rng.percent(40) ? nil : ownershipChoice()
                    if try tracker.end(ifCurrent: expected) { active = nil }
                case 52 ..< 57:
                    try tracker.installProcessRunID(rng.pick(runIDs))
                case 57 ..< 62:
                    try tracker.clearProcessRunID(ifCurrent: rng.pick(runIDs))
                case 62 ..< 64:
                    try tracker.forceClearProcessRunID()
                case 64 ..< 68:
                    try tracker.bumpTerminalDrainGeneration()
                case 68 ..< 74:
                    try tracker.beginTerminalCommit()
                case 74 ..< 81:
                    try tracker.stageTerminalCommit(commitID: rng.uuid(), ownership: ownershipChoice())
                case 81 ..< 86:
                    try tracker.recordTerminalPublicationResult(P6AFixtures.publicationResult(&rng))
                case 86 ..< 89:
                    try tracker.abortTerminalCommit()
                case 89 ..< 92:
                    try tracker.completeTerminalCommit()
                case 92 ..< 95:
                    try tracker.invalidateTerminalCommit()
                case 95 ..< 99:
                    _ = try tracker.hasTerminalCommit(for: ownershipChoice())
                default:
                    try tracker.reset()
                    active = nil
                }
            }
        }
        print("P6A_DIFFERENTIAL tracker seed=\(seed) sequences=\(sequences) transitions=\(ledger.transitions) agreement=100%")
        XCTAssertEqual(ledger.transitions, sequences * stepsPerSequence)
    }

    func testCorpusTerminalCommitAgreesOnRandomEventSequences() throws {
        let seed = P6ADifferentialConfiguration.seed(for: "terminal-commit")
        let sequences = 120 * P6ADifferentialConfiguration.scale
        let stepsPerSequence = 48
        var rng = P6ASplitMix64(seed: seed)
        let ledger = P6ADifferentialLedger()

        for sequence in 0 ..< sequences {
            ledger.context = "terminal-commit seed=\(seed) sequence=\(sequence)"
            let state = P6ADualTerminalCommit(ledger: ledger)
            let pool = P6AFixtures.ownershipPool(&rng)
            for _ in 0 ..< stepsPerSequence {
                switch rng.below(100) {
                case 0 ..< 22:
                    try state.begin(ownership: rng.percent(30) ? nil : rng.pick(pool))
                case 22 ..< 44:
                    try state.stage(commitID: rng.uuid(), ownership: rng.pick(pool))
                case 44 ..< 58:
                    try state.record(P6AFixtures.publicationResult(&rng))
                case 58 ..< 68:
                    try state.abort()
                case 68 ..< 78:
                    try state.complete()
                case 78 ..< 86:
                    try state.invalidate()
                case 86 ..< 96:
                    _ = try state.matches(ownership: rng.pick(pool))
                default:
                    try state.reset()
                }
            }
        }
        print("P6A_DIFFERENTIAL terminal-commit seed=\(seed) sequences=\(sequences) transitions=\(ledger.transitions) agreement=100%")
        XCTAssertEqual(ledger.transitions, sequences * stepsPerSequence)
    }

    func testCorpusProcessIdentityAgreesOnRandomEventSequences() throws {
        let seed = P6ADifferentialConfiguration.seed(for: "process-identity")
        let sequences = 120 * P6ADifferentialConfiguration.scale
        let stepsPerSequence = 32
        var rng = P6ASplitMix64(seed: seed)
        let ledger = P6ADifferentialLedger()

        for sequence in 0 ..< sequences {
            ledger.context = "process-identity seed=\(seed) sequence=\(sequence)"
            let runIDs = (0 ..< 3).map { _ in rng.uuid() }
            let identity = try P6ADualProcessIdentity(
                runID: rng.percent(50) ? rng.pick(runIDs) : nil,
                terminalDrainGeneration: rng.percent(20) ? UInt64.max - UInt64(rng.below(3)) : UInt64(rng.below(5)),
                ledger: ledger
            )
            for _ in 0 ..< stepsPerSequence {
                switch rng.below(100) {
                case 0 ..< 30: try identity.install(rng.pick(runIDs))
                case 30 ..< 60: try identity.clear(ifCurrent: rng.pick(runIDs))
                case 60 ..< 70: try identity.forceClear()
                case 70 ..< 90: try identity.bumpTerminalDrainGeneration()
                default: try identity.resetForNewAttempt()
                }
            }
        }
        print("P6A_DIFFERENTIAL process-identity seed=\(seed) sequences=\(sequences) transitions=\(ledger.transitions) agreement=100%")
        XCTAssertEqual(ledger.transitions, sequences * stepsPerSequence)
    }

    func testCorpusSettlementAgreesOnRandomEventSequences() throws {
        let seed = P6ADifferentialConfiguration.seed(for: "settlement")
        let sequences = 80 * P6ADifferentialConfiguration.scale
        let stepsPerSequence = 48
        var rng = P6ASplitMix64(seed: seed)
        let ledger = P6ADifferentialLedger()

        for sequence in 0 ..< sequences {
            ledger.context = "settlement seed=\(seed) sequence=\(sequence)"
            let coordinator = P6ADualSettlement(ledger: ledger)
            let pool = P6AFixtures.ownershipPool(&rng)
            let successors = (0 ..< 6).map { _ in rng.uuid() }
            let tokens = (0 ..< 4).map { _ in rng.uuid() }
            for _ in 0 ..< stepsPerSequence {
                switch rng.below(100) {
                case 0 ..< 12:
                    _ = try coordinator.hasConsumedProviderSuccessor(id: rng.pick(successors))
                case 12 ..< 40:
                    try coordinator.recordProviderSuccessorConsumption(
                        id: rng.percent(80) ? rng.pick(successors) : rng.uuid(),
                        deliverySucceeded: rng.percent(75)
                    )
                case 40 ..< 60:
                    try coordinator.registerTeardown(ownership: rng.pick(pool), token: rng.pick(tokens))
                case 60 ..< 68:
                    _ = try coordinator.hasPendingTeardown(for: rng.pick(pool))
                case 68 ..< 76:
                    _ = try coordinator.teardownToken(for: rng.pick(pool))
                case 76 ..< 97:
                    try coordinator.completeTeardown(ownership: rng.pick(pool), token: rng.pick(tokens))
                default:
                    try coordinator.reset()
                }
            }
        }
        print("P6A_DIFFERENTIAL settlement seed=\(seed) sequences=\(sequences) transitions=\(ledger.transitions) agreement=100%")
        XCTAssertEqual(ledger.transitions, sequences * stepsPerSequence)
    }

    func testCorpusSemanticAuthorityAgreesOnRandomSignals() async throws {
        let seed = P6ADifferentialConfiguration.seed(for: "semantic")
        let samples = 400 * P6ADifferentialConfiguration.scale
        var rng = P6ASplitMix64(seed: seed)
        let authority = CoreAgentRunSemanticAuthority()

        for index in 0 ..< samples {
            let signal = P6AFixtures.terminationSignal(&rng)
            XCTAssertEqual(
                try authority.resolve(signal.p6aV1),
                DomainAgentRunProviderSemanticAuthority.resolve(signal).p6aV1,
                "seed=\(seed) sample=\(index) \(signal)"
            )
            let providerEnding: P6AOperationEnding<DomainAgentRunProviderExecutionResult> = switch rng.below(5) {
            case 0: .threwCancellation
            case 1: .threwError(rng.pick(P6AFixtures.assistantTexts) ?? "boom")
            case 2: .returned(.completed(assistantText: rng.pick(P6AFixtures.assistantTexts)))
            case 3: .returned(.superseded)
            default: .returned(.failed(signal: signal))
            }
            let swiftReport = await DomainAgentRunExecutionCore.executeProvider(
                failureText: { _ in providerEnding.failureText }
            ) {
                try providerEnding.perform()
            }
            XCTAssertEqual(
                try authority.classifyProviderExecution(providerEnding.p6aV1),
                swiftReport.p6aV1,
                "seed=\(seed) sample=\(index) \(providerEnding)"
            )
        }
        print("P6A_DIFFERENTIAL semantic seed=\(seed) samples=\(samples) agreement=100%")
    }

    // MARK: - Boundary behaviour that only the Rust side can exhibit

    func testRustRejectsMalformedIdentitiesWithTypedBridgeError() throws {
        let tracker = CoreAgentRunLifecycleTracker()
        XCTAssertThrowsError(try tracker.installProcessRunID("not-a-uuid")) { error in
            guard case let .agentRunLifecycleInvalidRequest(message)? = error as? CoreBridgeError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.hasPrefix("runId:"), message)
        }
        XCTAssertThrowsError(try CoreAgentRunProcessIdentityState(runID: "", terminalDrainGeneration: 0))
        // Uppercase text (Swift's `uuidString`) is accepted and rendered back lowercase.
        let runID = UUID()
        try tracker.installProcessRunID(runID.uuidString)
        XCTAssertEqual(try tracker.state().processRunId, runID.p6aLowered)
    }
}

private extension AgentRunProgressAcceptanceV1 {
    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}
