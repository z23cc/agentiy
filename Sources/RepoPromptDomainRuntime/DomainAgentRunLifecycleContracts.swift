import Foundation

/// Runtime-only binding captured when a provider run attempt begins.
///
/// This identity is intentionally separate from durable session metadata. It is a compact,
/// Sendable fence that can be shared by App and headless execution hosts without importing UI,
/// provider, transcript, or persistence types.
package struct DomainAgentRunBindingIdentity: Equatable, Hashable, Sendable {
    package let tabID: UUID
    package let persistentSessionID: UUID?
    package let persistentBindingGeneration: UUID?
    package let bindingTransitionGeneration: UInt64
    package let generation: UUID

    package init(
        tabID: UUID,
        persistentSessionID: UUID?,
        persistentBindingGeneration: UUID? = nil,
        bindingTransitionGeneration: UInt64 = 0,
        generation: UUID = UUID()
    ) {
        self.tabID = tabID
        self.persistentSessionID = persistentSessionID
        self.persistentBindingGeneration = persistentBindingGeneration
        self.bindingTransitionGeneration = bindingTransitionGeneration
        self.generation = generation
    }
}

/// Provider-neutral ownership token for one logical run attempt.
package struct DomainAgentRunOwnership: Equatable, Hashable, Sendable {
    package let attemptID: UUID
    package let binding: DomainAgentRunBindingIdentity
    package let turnEpoch: DomainAgentRunTurnEpoch?

    package init(
        attemptID: UUID = UUID(),
        binding: DomainAgentRunBindingIdentity,
        turnEpoch: DomainAgentRunTurnEpoch? = nil
    ) {
        self.attemptID = attemptID
        self.binding = binding
        self.turnEpoch = turnEpoch
    }
}

package enum DomainAgentRunLifecycleStage: String, Equatable, Hashable, Sendable {
    case starting
    case preparingRuntime
    case running
    case waitingForInteraction
    case retrying
    case cancelling
}

package enum DomainAgentRunLivenessSignalKind: String, Equatable, Hashable, Sendable {
    case stageTransition
    case providerEvent
    case toolActivity
    case interaction
    case heartbeat

    package var isRealProgress: Bool {
        self != .heartbeat
    }
}

package enum DomainAgentRunRetryIntent: String, Equatable, Hashable, Sendable {
    case none
    case providerManaged
    case applicationManaged
}

package struct DomainAgentRunProgressSignal: Equatable, Sendable {
    package let ownership: DomainAgentRunOwnership
    package let sequence: UInt64
    package let timestampUptimeNanoseconds: UInt64
    package let kind: DomainAgentRunLivenessSignalKind
    package let stage: DomainAgentRunLifecycleStage
    package let retryIntent: DomainAgentRunRetryIntent

    package init(
        ownership: DomainAgentRunOwnership,
        sequence: UInt64,
        timestampUptimeNanoseconds: UInt64,
        kind: DomainAgentRunLivenessSignalKind,
        stage: DomainAgentRunLifecycleStage,
        retryIntent: DomainAgentRunRetryIntent
    ) {
        self.ownership = ownership
        self.sequence = sequence
        self.timestampUptimeNanoseconds = timestampUptimeNanoseconds
        self.kind = kind
        self.stage = stage
        self.retryIntent = retryIntent
    }
}

package struct DomainAgentRunLivenessSnapshot: Equatable, Sendable {
    package let ownership: DomainAgentRunOwnership
    package var stage: DomainAgentRunLifecycleStage
    package var retryIntent: DomainAgentRunRetryIntent
    package var lastAcceptedSequence: UInt64
    package var lastSignalUptimeNanoseconds: UInt64
    package var lastRealProgressUptimeNanoseconds: UInt64
    package var lastHeartbeatUptimeNanoseconds: UInt64?

    package init(
        ownership: DomainAgentRunOwnership,
        stage: DomainAgentRunLifecycleStage,
        retryIntent: DomainAgentRunRetryIntent,
        lastAcceptedSequence: UInt64,
        lastSignalUptimeNanoseconds: UInt64,
        lastRealProgressUptimeNanoseconds: UInt64,
        lastHeartbeatUptimeNanoseconds: UInt64?
    ) {
        self.ownership = ownership
        self.stage = stage
        self.retryIntent = retryIntent
        self.lastAcceptedSequence = lastAcceptedSequence
        self.lastSignalUptimeNanoseconds = lastSignalUptimeNanoseconds
        self.lastRealProgressUptimeNanoseconds = lastRealProgressUptimeNanoseconds
        self.lastHeartbeatUptimeNanoseconds = lastHeartbeatUptimeNanoseconds
    }
}

package enum DomainAgentRunProgressRejection: String, Equatable, Sendable {
    case noActiveOwnership
    case staleOwnership
    case duplicateSequence
    case outOfOrderSequence
    case nonMonotonicTimestamp
}

package enum DomainAgentRunProgressAcceptance: Equatable, Sendable {
    case accepted(DomainAgentRunLivenessSnapshot)
    case rejected(DomainAgentRunProgressRejection)
}

/// Provider-neutral, non-rendering ownership and liveness reducer.
///
/// The reducer never mutates transcript, persistence, UI bindings, provider state, or tasks.
/// Its monotonic sequence and timestamp fences make stale callbacks and successor attempts
/// deterministic across App and headless execution hosts.
package struct DomainAgentRunLifecycleTracker: Equatable, Sendable {
    package private(set) var activeOwnership: DomainAgentRunOwnership?
    package private(set) var liveness: DomainAgentRunLivenessSnapshot?
    private var nextSequence: UInt64 = 1

    package init() {}

    package mutating func begin(
        tabID: UUID,
        persistentSessionID: UUID?,
        persistentBindingGeneration: UUID? = nil,
        bindingTransitionGeneration: UInt64 = 0,
        attemptID: UUID = UUID(),
        turnEpoch: DomainAgentRunTurnEpoch? = nil,
        timestampUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> DomainAgentRunOwnership {
        let ownership = DomainAgentRunOwnership(
            attemptID: attemptID,
            binding: DomainAgentRunBindingIdentity(
                tabID: tabID,
                persistentSessionID: persistentSessionID,
                persistentBindingGeneration: persistentBindingGeneration,
                bindingTransitionGeneration: bindingTransitionGeneration
            ),
            turnEpoch: turnEpoch
        )
        activeOwnership = ownership
        liveness = DomainAgentRunLivenessSnapshot(
            ownership: ownership,
            stage: .starting,
            retryIntent: .none,
            lastAcceptedSequence: 0,
            lastSignalUptimeNanoseconds: timestampUptimeNanoseconds,
            lastRealProgressUptimeNanoseconds: timestampUptimeNanoseconds,
            lastHeartbeatUptimeNanoseconds: nil
        )
        nextSequence = 1
        return ownership
    }

    @discardableResult
    package mutating func record(
        ownership: DomainAgentRunOwnership,
        kind: DomainAgentRunLivenessSignalKind,
        stage: DomainAgentRunLifecycleStage,
        retryIntent: DomainAgentRunRetryIntent = .none,
        timestampUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> DomainAgentRunProgressAcceptance {
        let signal = DomainAgentRunProgressSignal(
            ownership: ownership,
            sequence: nextSequence,
            timestampUptimeNanoseconds: timestampUptimeNanoseconds,
            kind: kind,
            stage: stage,
            retryIntent: retryIntent
        )
        nextSequence &+= 1
        return accept(signal)
    }

    @discardableResult
    package mutating func accept(_ signal: DomainAgentRunProgressSignal) -> DomainAgentRunProgressAcceptance {
        guard let activeOwnership, var snapshot = liveness else {
            return .rejected(.noActiveOwnership)
        }
        guard signal.ownership == activeOwnership else {
            return .rejected(.staleOwnership)
        }
        if signal.sequence == snapshot.lastAcceptedSequence {
            return .rejected(.duplicateSequence)
        }
        guard signal.sequence > snapshot.lastAcceptedSequence else {
            return .rejected(.outOfOrderSequence)
        }
        guard signal.timestampUptimeNanoseconds >= snapshot.lastSignalUptimeNanoseconds else {
            return .rejected(.nonMonotonicTimestamp)
        }

        snapshot.stage = signal.stage
        snapshot.retryIntent = signal.retryIntent
        snapshot.lastAcceptedSequence = signal.sequence
        snapshot.lastSignalUptimeNanoseconds = signal.timestampUptimeNanoseconds
        if signal.kind == .heartbeat {
            snapshot.lastHeartbeatUptimeNanoseconds = signal.timestampUptimeNanoseconds
        } else {
            snapshot.lastRealProgressUptimeNanoseconds = signal.timestampUptimeNanoseconds
        }
        liveness = snapshot
        nextSequence = max(nextSequence, signal.sequence &+ 1)
        return .accepted(snapshot)
    }

    @discardableResult
    package mutating func end(ifCurrent expectedOwnership: DomainAgentRunOwnership? = nil) -> Bool {
        guard let activeOwnership else { return false }
        if let expectedOwnership, expectedOwnership != activeOwnership {
            return false
        }
        self.activeOwnership = nil
        liveness = nil
        nextSequence = 1
        return true
    }
}
