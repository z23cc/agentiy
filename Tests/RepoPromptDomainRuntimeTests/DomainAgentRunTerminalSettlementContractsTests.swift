import Foundation
import XCTest
@testable import RepoPromptDomainRuntime

final class DomainAgentRunTerminalSettlementContractsTests: XCTestCase {
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

    func testProviderSuccessorConsumptionIsExactlyOnce() {
        var coordinator = DomainAgentRunTerminalSettlementCoordinator()
        let successorID = UUID()

        XCTAssertFalse(coordinator.hasConsumedProviderSuccessor(id: successorID))
        XCTAssertTrue(coordinator.recordProviderSuccessorConsumption(id: successorID))
        XCTAssertTrue(coordinator.hasConsumedProviderSuccessor(id: successorID))
        XCTAssertFalse(coordinator.recordProviderSuccessorConsumption(id: successorID))
        XCTAssertEqual(coordinator.consumedProviderSuccessorCount, 1)
    }

    func testFailedSuccessorDeliveryDoesNotCreateATombstone() {
        var coordinator = DomainAgentRunTerminalSettlementCoordinator()
        let successorID = UUID()

        // A failed host callback must remain retryable and therefore cannot be
        // recorded as a consumed successor.
        XCTAssertFalse(coordinator.hasConsumedProviderSuccessor(id: successorID))
        XCTAssertEqual(coordinator.consumedProviderSuccessorCount, 0)
        XCTAssertFalse(
            coordinator.recordProviderSuccessorConsumption(
                id: successorID,
                deliverySucceeded: false
            )
        )
        XCTAssertFalse(coordinator.hasConsumedProviderSuccessor(id: successorID))
        XCTAssertTrue(coordinator.recordProviderSuccessorConsumption(id: successorID))
    }

    func testSuccessorTombstonesUseBoundedFIFOEviction() {
        var coordinator = DomainAgentRunTerminalSettlementCoordinator()
        let first = UUID()
        XCTAssertTrue(coordinator.recordProviderSuccessorConsumption(id: first))

        for _ in 1 ..< DomainAgentRunTerminalSettlementCoordinator.maxProviderSuccessorTombstones {
            XCTAssertTrue(coordinator.recordProviderSuccessorConsumption(id: UUID()))
        }
        XCTAssertEqual(
            coordinator.consumedProviderSuccessorCount,
            DomainAgentRunTerminalSettlementCoordinator.maxProviderSuccessorTombstones
        )
        XCTAssertTrue(coordinator.hasConsumedProviderSuccessor(id: first))

        let newest = UUID()
        XCTAssertTrue(coordinator.recordProviderSuccessorConsumption(id: newest))
        XCTAssertEqual(
            coordinator.consumedProviderSuccessorCount,
            DomainAgentRunTerminalSettlementCoordinator.maxProviderSuccessorTombstones
        )
        XCTAssertFalse(coordinator.hasConsumedProviderSuccessor(id: first))
        XCTAssertTrue(coordinator.hasConsumedProviderSuccessor(id: newest))
    }

    func testTeardownRegistrationAndCompletionAreTokenBound() {
        var coordinator = DomainAgentRunTerminalSettlementCoordinator()
        let ownership = makeOwnership()
        let token = UUID()
        let staleToken = UUID()

        XCTAssertEqual(
            coordinator.registerTeardown(ownership: ownership, token: token),
            .registered
        )
        XCTAssertTrue(coordinator.hasPendingTeardown(for: ownership))
        XCTAssertEqual(coordinator.teardownToken(for: ownership), token)
        XCTAssertEqual(
            coordinator.registerTeardown(ownership: ownership, token: UUID()),
            .alreadyRegistered
        )
        XCTAssertFalse(coordinator.completeTeardown(ownership: ownership, token: staleToken))
        XCTAssertTrue(coordinator.hasPendingTeardown(for: ownership))
        XCTAssertTrue(coordinator.completeTeardown(ownership: ownership, token: token))
        XCTAssertFalse(coordinator.hasPendingTeardown(for: ownership))
        XCTAssertFalse(coordinator.completeTeardown(ownership: ownership, token: token))
    }

    func testTeardownTokensAreIndependentAcrossOwners() {
        var coordinator = DomainAgentRunTerminalSettlementCoordinator()
        let first = makeOwnership()
        let second = makeOwnership()
        let firstToken = UUID()
        let secondToken = UUID()

        XCTAssertEqual(
            coordinator.registerTeardown(ownership: first, token: firstToken),
            .registered
        )
        XCTAssertEqual(
            coordinator.registerTeardown(ownership: second, token: secondToken),
            .registered
        )
        XCTAssertTrue(coordinator.completeTeardown(ownership: first, token: firstToken))
        XCTAssertFalse(coordinator.hasPendingTeardown(for: first))
        XCTAssertTrue(coordinator.hasPendingTeardown(for: second))
        XCTAssertTrue(coordinator.completeTeardown(ownership: second, token: secondToken))
    }

    func testResetClearsSettlementFences() {
        var coordinator = DomainAgentRunTerminalSettlementCoordinator()
        let ownership = makeOwnership()
        let successorID = UUID()
        let token = UUID()
        XCTAssertTrue(coordinator.recordProviderSuccessorConsumption(id: successorID))
        XCTAssertEqual(
            coordinator.registerTeardown(ownership: ownership, token: token),
            .registered
        )

        coordinator.reset()

        XCTAssertFalse(coordinator.hasConsumedProviderSuccessor(id: successorID))
        XCTAssertFalse(coordinator.hasPendingTeardown(for: ownership))
        XCTAssertNil(coordinator.teardownToken(for: ownership))
    }
}
