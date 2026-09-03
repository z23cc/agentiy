import AgentryUniFFIRaw
import Foundation

// ADR-0011 P6-b (B track; design §4.1.1, §7.1, §8 "P6-b" publish cutover): the bridge surface
// over the Rust port of the Agent Session Host transcript / snapshot reducer
// (`agentry_runtime::agent_session_transcript`). Same shape as `CoreAgentRunLifecycle.swift`:
// the generated `AgentHost…V1` records are already re-exported by `CoreAgentSessionHost.swift`,
// this file only wraps the reducer object so callers never import `AgentryUniFFIRaw`. Every call
// is a bounded synchronous pure state transition; time, cursor, and identities are inputs.
// The Swift host folds and `compact`s through this object; `.events` bytes still come from
// `CoreAgentSessionLog` FFI.

/// `AgentSessionHostSessionState` in Rust (`AgentSessionTranscriptReducerV1`): event → transcript /
/// snapshot value-state reducer.
public final class CoreAgentSessionTranscriptReducer: Sendable {
    private let raw: AgentSessionTranscriptReducerV1

    public init(placeholderSessionID sessionID: String) {
        raw = AgentSessionTranscriptReducerV1.placeholder(sessionId: sessionID)
    }

    public init(summary: AgentHostSessionSummaryV1) throws {
        raw = try CoreAgentSessionHostErrorMapping.rethrow {
            try AgentSessionTranscriptReducerV1.fromSummary(summary: summary)
        }
    }

    public init(snapshot: AgentHostAgentSessionSnapshotV1) throws {
        raw = try CoreAgentSessionHostErrorMapping.rethrow {
            try AgentSessionTranscriptReducerV1.fromSnapshot(snapshot: snapshot)
        }
    }

    public func reset() throws {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.reset() }
    }

    public func apply(_ event: AgentHostAgentSessionEventV1, cursor: UInt64) throws {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.apply(event: event, cursor: cursor) }
    }

    public func setGeneration(_ generation: Data) throws {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.setGeneration(generation: generation) }
    }

    public func setAttachedClientCount(_ count: Int) throws {
        let clamped = UInt32(max(0, count))
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.setAttachedClientCount(count: clamped) }
    }

    public func snapshot(generation: Data, now: String) throws -> AgentHostAgentSessionSnapshotV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.snapshot(generation: generation, now: now) }
    }

    public func summary() throws -> AgentHostSessionSummaryV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.summary() }
    }

    public func hostOwnedSummary(
        status: AgentHostSessionStatusV1,
        statusText: String,
        clearingActiveRun: Bool,
        now: String
    ) throws -> AgentHostSessionSummaryV1 {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.hostOwnedSummary(
                status: status,
                statusText: statusText,
                clearingActiveRun: clearingActiveRun,
                now: now
            )
        }
    }

    public func lastCursor() throws -> UInt64 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.lastCursor() }
    }

    public func hasMetadata() throws -> Bool {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.hasMetadata() }
    }

    public func isTerminal() throws -> Bool {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.isTerminal() }
    }

    public func hasLiveRun() throws -> Bool {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.hasLiveRun() }
    }

    public func transcript() throws -> [AgentHostTranscriptEntryV1] {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.transcript() }
    }

    public func pendingInteractions() throws -> [AgentHostPendingInteractionV1] {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.pendingInteractions() }
    }

    public func unsettledOperations() throws -> [AgentHostCommandAcceptedV1] {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.unsettledOperations() }
    }

    public func canonicalState() throws -> String {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.canonicalState() }
    }
}
