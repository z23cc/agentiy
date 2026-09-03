import AgentryCoreBridge
import Foundation

/// Host-side session fold after ADR-0011 P6-b publish cutover.
///
/// Transcript / snapshot / summary come from `CoreAgentSessionTranscriptReducer` (Rust
/// `SessionState`). `AgentSessionLog` remains the only `.events` writer. Command and
/// interaction lookups are a RAM index of the same events the reducer already folded —
/// UniFFI does not export those maps, and this is not a second transcript fold.
/// `staleInteractionResponseCount` is host-owned (never part of the value-state reducer).
package final class AgentSessionHostFoldedState {
    private let reducer: CoreAgentSessionTranscriptReducer
    private var cachedSummary: AgentHostSessionSummaryV1
    private var cachedLastCursor: UInt64 = 0
    private var cachedHasMetadata = false
    private var cachedIsTerminal = false
    private var cachedHasLiveRun = false
    private var cachedPending: [AgentHostPendingInteractionV1] = []
    package private(set) var acceptedOperations: [String: AgentHostCommandAcceptedV1] = [:]
    package private(set) var settledOperations: [String: AgentHostCommandSettledV1] = [:]
    package private(set) var settledInteractionIDs: Set<String> = []
    package private(set) var staleInteractionResponseCount: UInt64 = 0

    package init(placeholderSessionID sessionID: String) {
        reducer = CoreAgentSessionTranscriptReducer(placeholderSessionID: sessionID)
        cachedSummary = AgentSessionHostMutableSummary(sessionId: sessionID).value
        refreshObservables()
    }

    package init(summary: AgentHostSessionSummaryV1) throws {
        reducer = try CoreAgentSessionTranscriptReducer(summary: summary)
        cachedSummary = summary
        refreshObservables()
    }

    package convenience init(spec: AgentHostSessionSpecV1, now: String) throws {
        try self.init(summary: AgentSessionHostMutableSummary(spec: spec, now: now).value)
    }

    package init(snapshot: AgentHostAgentSessionSnapshotV1) throws {
        reducer = try CoreAgentSessionTranscriptReducer(snapshot: snapshot)
        cachedSummary = snapshot.summary ?? AgentSessionHostMutableSummary(sessionId: snapshot.sessionId).value
        for accepted in snapshot.unsettledOperations {
            acceptedOperations[accepted.operationId] = accepted
        }
        refreshObservables()
    }

    package var summary: AgentHostSessionSummaryV1 { cachedSummary }
    package var lastCursor: UInt64 { cachedLastCursor }
    package var hasMetadata: Bool { cachedHasMetadata }
    package var isTerminal: Bool { cachedIsTerminal }
    package var hasLiveRun: Bool { cachedHasLiveRun }
    package var pendingInteractions: [AgentHostPendingInteractionV1] { cachedPending }

    package func apply(_ event: AgentHostAgentSessionEventV1, cursor: UInt64) throws {
        if case let .runLifecycle(lifecycle) = event.body, case .terminated = lifecycle.kind {
            for pending in cachedPending {
                settledInteractionIDs.insert(pending.interactionId)
            }
        }
        try reducer.apply(event, cursor: cursor)
        index(event)
        refreshObservables()
    }

    package func setGeneration(_ generation: Data) {
        try? reducer.setGeneration(generation)
        refreshObservables()
    }

    package func setAttachedClientCount(_ count: Int) {
        try? reducer.setAttachedClientCount(count)
        refreshObservables()
    }

    package func recordStaleInteractionResponse() {
        staleInteractionResponseCount &+= 1
    }

    package func summary(
        status: AgentHostSessionStatusV1,
        statusText: String,
        clearingActiveRun: Bool,
        now: String
    ) -> AgentHostSessionSummaryV1 {
        if let next = try? reducer.hostOwnedSummary(
            status: status,
            statusText: statusText,
            clearingActiveRun: clearingActiveRun,
            now: now
        ) {
            return next
        }
        var fallback = AgentSessionHostMutableSummary(cachedSummary)
        fallback.status = status
        fallback.statusText = statusText
        if clearingActiveRun { fallback.activeRunId = "" }
        fallback.updatedAt = now
        return fallback.value
    }

    package func snapshot(generation: Data, now: String) -> AgentHostAgentSessionSnapshotV1 {
        if let snapshot = try? reducer.snapshot(generation: generation, now: now) {
            return snapshot
        }
        return AgentHostAgentSessionSnapshotV1(
            sessionId: cachedSummary.sessionId,
            generation: generation,
            throughCursor: cachedLastCursor,
            summary: cachedSummary,
            transcript: (try? reducer.transcript()) ?? [],
            pendingInteractions: cachedPending,
            unsettledOperations: (try? reducer.unsettledOperations()) ?? [],
            writtenAt: now
        )
    }

    package func canonicalState() throws -> String {
        try reducer.canonicalState()
    }

    private func index(_ event: AgentHostAgentSessionEventV1) {
        switch event.body {
        case let .commandAccepted(accepted):
            acceptedOperations[accepted.operationId] = accepted
        case let .commandSettled(settled):
            settledOperations[settled.operationId] = settled
        case let .interaction(interaction):
            if case let .settled(settled) = interaction.kind {
                settledInteractionIDs.insert(settled.interactionId)
            }
        default:
            break
        }
    }

    private func refreshObservables() {
        if let summary = try? reducer.summary() {
            cachedSummary = summary
        }
        cachedLastCursor = (try? reducer.lastCursor()) ?? cachedLastCursor
        cachedHasMetadata = (try? reducer.hasMetadata()) ?? cachedHasMetadata
        cachedIsTerminal = (try? reducer.isTerminal()) ?? cachedIsTerminal
        cachedHasLiveRun = (try? reducer.hasLiveRun()) ?? cachedHasLiveRun
        cachedPending = (try? reducer.pendingInteractions()) ?? cachedPending
    }
}
