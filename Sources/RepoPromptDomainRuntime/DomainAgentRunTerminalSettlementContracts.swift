import Foundation

/// Result of registering the provider-neutral teardown obligation for one run owner.
package enum DomainAgentRunTerminalTeardownRegistrationResult: Equatable, Sendable {
    case registered
    case alreadyRegistered
}

/// Provider-neutral settlement fences shared by the App terminal barrier and
/// headless Agent Mode hosts.
///
/// The coordinator owns only semantic identity: bounded successor tombstones
/// and ownership-bound teardown tokens. It never stores a Task, provider
/// closure, transcript object, or UI reference. App hosts retain those
/// physical resources and use the token fence when they complete them.
package struct DomainAgentRunTerminalSettlementCoordinator: Equatable, Sendable {
    package static let maxProviderSuccessorTombstones = 512

    private var consumedProviderSuccessorIDs: Set<UUID> = []
    private var consumedProviderSuccessorOrder: [UUID] = []
    private var teardownTokenByOwnership: [DomainAgentRunOwnership: UUID] = [:]

    package init() {}

    package func hasConsumedProviderSuccessor(id: UUID) -> Bool {
        consumedProviderSuccessorIDs.contains(id)
    }

    /// Records a successfully delivered successor callback. Failed callback
    /// attempts are deliberately not tombstoned so a later publication retry
    /// can deliver the successor again.
    @discardableResult
    package mutating func recordProviderSuccessorConsumption(
        id: UUID,
        deliverySucceeded: Bool = true
    ) -> Bool {
        guard deliverySucceeded else { return false }
        guard consumedProviderSuccessorIDs.insert(id).inserted else {
            return false
        }
        consumedProviderSuccessorOrder.append(id)
        while consumedProviderSuccessorOrder.count > Self.maxProviderSuccessorTombstones {
            let expiredID = consumedProviderSuccessorOrder.removeFirst()
            consumedProviderSuccessorIDs.remove(expiredID)
        }
        return true
    }

    package var consumedProviderSuccessorCount: Int {
        consumedProviderSuccessorIDs.count
    }

    package mutating func registerTeardown(
        ownership: DomainAgentRunOwnership,
        token: UUID
    ) -> DomainAgentRunTerminalTeardownRegistrationResult {
        guard teardownTokenByOwnership[ownership] == nil else {
            return .alreadyRegistered
        }
        teardownTokenByOwnership[ownership] = token
        return .registered
    }

    package func hasPendingTeardown(for ownership: DomainAgentRunOwnership) -> Bool {
        teardownTokenByOwnership[ownership] != nil
    }

    package func teardownToken(for ownership: DomainAgentRunOwnership) -> UUID? {
        teardownTokenByOwnership[ownership]
    }

    /// Completes only the currently registered token. A stale completion from
    /// an older App Task cannot clear a replacement obligation.
    @discardableResult
    package mutating func completeTeardown(
        ownership: DomainAgentRunOwnership,
        token: UUID
    ) -> Bool {
        guard teardownTokenByOwnership[ownership] == token else {
            return false
        }
        teardownTokenByOwnership.removeValue(forKey: ownership)
        return true
    }

    package mutating func reset() {
        consumedProviderSuccessorIDs.removeAll()
        consumedProviderSuccessorOrder.removeAll()
        teardownTokenByOwnership.removeAll()
    }
}
