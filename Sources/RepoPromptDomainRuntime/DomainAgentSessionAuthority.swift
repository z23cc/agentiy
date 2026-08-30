import Foundation

/// Ordered, bounded lifecycle evidence emitted by the canonical agent-session authority.
/// The stream is domain-neutral: MCP/provider adapters may observe it, but cannot author
/// session identity, epoch or terminal decisions outside the authority.
package enum DomainAgentSessionEventKind: String, Codable, Equatable, Sendable {
    case registered
    case resumed
    case epochBegan = "epoch_began"
    case snapshotPublished = "snapshot_published"
    case terminalPublished = "terminal_published"
    case cleanedUp = "cleaned_up"
    case expired
    case shutdownBegan = "shutdown_began"
    case shutdownCompleted = "shutdown_completed"
}

package struct DomainAgentSessionEvent: Codable, Equatable, Sendable {
    package let sequence: UInt64
    package let eventID: UUID
    package let kind: DomainAgentSessionEventKind
    package let sessionID: UUID?
    package let registration: DomainAgentSessionRegistration?
    package let epoch: DomainAgentRunTurnEpoch?
    package let terminalCommitID: UUID?
    package let occurredAt: Date

    package init(
        sequence: UInt64,
        eventID: UUID = UUID(),
        kind: DomainAgentSessionEventKind,
        sessionID: UUID?,
        registration: DomainAgentSessionRegistration?,
        epoch: DomainAgentRunTurnEpoch? = nil,
        terminalCommitID: UUID? = nil,
        occurredAt: Date = Date()
    ) {
        self.sequence = sequence
        self.eventID = eventID
        self.kind = kind
        self.sessionID = sessionID
        self.registration = registration
        self.epoch = epoch
        self.terminalCommitID = terminalCommitID
        self.occurredAt = occurredAt
    }
}

package struct DomainAgentSessionHistoryRequest: Equatable, Sendable {
    package let sessionID: UUID?
    package let afterSequence: UInt64?
    package let limit: Int

    package init(sessionID: UUID? = nil, afterSequence: UInt64? = nil, limit: Int = 100) {
        self.sessionID = sessionID
        self.afterSequence = afterSequence
        self.limit = max(1, min(limit, 256))
    }
}

package struct DomainAgentSessionHistoryResult: Equatable, Sendable {
    package let events: [DomainAgentSessionEvent]
    package let nextSequence: UInt64?
    package let isTruncated: Bool

    package init(events: [DomainAgentSessionEvent], nextSequence: UInt64?, isTruncated: Bool) {
        self.events = events
        self.nextSequence = nextSequence
        self.isTruncated = isTruncated
    }
}

package extension DomainAgentSessionAuthority {
    /// Returns the current immutable event tail. Event sequence is monotonic for the
    /// runtime identity and never reused after shutdown.
    func sessionEventHistory(
        _ request: DomainAgentSessionHistoryRequest = .init()
    ) -> DomainAgentSessionHistoryResult {
        let lowerBound = request.afterSequence ?? 0
        let matching = sessionEventTail.filter { event in
            event.sequence > lowerBound && (request.sessionID == nil || event.sessionID == request.sessionID)
        }
        let page = Array(matching.prefix(request.limit))
        let truncated = matching.count > page.count
        return DomainAgentSessionHistoryResult(
            events: page,
            nextSequence: truncated ? page.last?.sequence : nil,
            isTruncated: truncated
        )
    }

    /// Subscriptions are bufferingNewest(1) because callers can always replay the bounded
    /// tail by sequence; no consumer can turn this into an unbounded persistence queue.
    func sessionEvents() -> AsyncStream<DomainAgentSessionEvent> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            sessionEventSubscribers[subscriberID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSessionEventSubscriber(subscriberID) }
            }
        }
    }

    func currentSessionEventSequence() -> UInt64 {
        sessionEventSequence
    }

    func sessionEventTailCount() -> Int {
        sessionEventTail.count
    }

    func appendSessionEvent(
        _ kind: DomainAgentSessionEventKind,
        sessionID: UUID?,
        registration: DomainAgentSessionRegistration?,
        epoch: DomainAgentRunTurnEpoch? = nil,
        commitID: UUID? = nil
    ) {
        sessionEventSequence &+= 1
        let event = DomainAgentSessionEvent(
            sequence: sessionEventSequence,
            kind: kind,
            sessionID: sessionID,
            registration: registration,
            epoch: epoch,
            terminalCommitID: commitID
        )
        sessionEventTail.append(event)
        if sessionEventTail.count > max(1, sessionEventTailLimit) {
            sessionEventTail.removeFirst(sessionEventTail.count - max(1, sessionEventTailLimit))
        }
        for continuation in sessionEventSubscribers.values {
            continuation.yield(event)
        }
    }

    func removeSessionEventSubscriber(_ id: UUID) {
        sessionEventSubscribers.removeValue(forKey: id)
    }
}
