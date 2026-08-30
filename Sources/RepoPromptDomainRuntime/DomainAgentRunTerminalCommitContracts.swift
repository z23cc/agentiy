import Foundation

/// Result of attempting to enter the single terminal-commit phase for an
/// Agent run attempt.
package enum DomainAgentRunTerminalCommitBeginResult: Equatable, Sendable {
    case acquired
    case alreadyInProgress
    case staleOwnership
}

/// Provider-neutral identity of a staged terminal commit.
///
/// The full revision remains an App projection because it contains App-owned
/// counters and publication adapters. This receipt is the semantic identity
/// used by the Domain reducer to fence duplicate and stale settlement work.
package struct DomainAgentRunTerminalCommitReceipt: Equatable, Sendable {
    package let commitID: UUID
    package let ownership: DomainAgentRunOwnership

    package init(commitID: UUID, ownership: DomainAgentRunOwnership) {
        self.commitID = commitID
        self.ownership = ownership
    }
}

/// Domain-owned phased terminal-commit state.
///
/// This state deliberately does not execute provider teardown or publish a
/// transcript. It owns only the semantic phase and exactly-once receipt
/// fences; App hosts apply the accepted state through their bound capabilities.
package struct DomainAgentRunTerminalCommitState: Equatable, Sendable {
    package private(set) var isInProgress = false
    package private(set) var stagedReceipt: DomainAgentRunTerminalCommitReceipt? = nil
    package private(set) var publicationResult: DomainAgentRunTerminalPublicationResult? = nil
    private var phaseOwnership: DomainAgentRunOwnership? = nil

    package init() {}

    package mutating func begin(
        ownership: DomainAgentRunOwnership? = nil
    ) -> DomainAgentRunTerminalCommitBeginResult {
        guard !isInProgress else { return .alreadyInProgress }
        if let existingOwnership = phaseOwnership,
           let ownership,
           existingOwnership != ownership
        {
            return .staleOwnership
        }
        isInProgress = true
        if let ownership {
            phaseOwnership = ownership
        }
        return .acquired
    }

    @discardableResult
    package mutating func stage(
        commitID: UUID,
        ownership: DomainAgentRunOwnership
    ) -> Bool {
        // Existing App tests and a few compatibility call sites stage a
        // revision before acquiring the phase. Once a phase owner exists,
        // successor/stale owners are rejected. The owner is retained after
        // active liveness ends because the barrier stages after draining the
        // provider and ending the active run state.
        guard phaseOwnership == nil || phaseOwnership == ownership else {
            return false
        }
        phaseOwnership = ownership
        stagedReceipt = DomainAgentRunTerminalCommitReceipt(
            commitID: commitID,
            ownership: ownership
        )
        // A newly staged commit invalidates the result from any prior phase.
        publicationResult = nil
        return true
    }

    /// Publication is intentionally unguarded. A retry may receive a result
    /// after the phase has completed, and binding invalidation can clear the
    /// staged receipt while publication is suspended.
    package mutating func record(
        _ result: DomainAgentRunTerminalPublicationResult
    ) {
        publicationResult = result
    }

    package mutating func abort() {
        isInProgress = false
    }

    package mutating func complete() {
        isInProgress = false
    }

    package mutating func invalidate() {
        stagedReceipt = nil
        publicationResult = nil
    }

    package mutating func reset() {
        isInProgress = false
        stagedReceipt = nil
        publicationResult = nil
        phaseOwnership = nil
    }

    package func matches(ownership: DomainAgentRunOwnership) -> Bool {
        stagedReceipt?.ownership == ownership
    }
}
