import AgentryUniFFIRaw
import Foundation

// ADR-0011 P6-a (B track; design §4.1.1, §7.1, §8 "P6-a"): the bridge surface over the Rust port
// of the Agent Mode run-lifecycle reducers (`agentry_runtime::agent_run_lifecycle`, mirroring
// `DomainAgentRun*`). Same shape as `CoreAgentSessionHost.swift`: the generated `AgentRun…V1`
// records/enums are re-exported by name, the five Rust objects are wrapped so callers never import
// `AgentryUniFFIRaw`, and every failure arrives as a `CoreBridgeError`. Every call is a bounded
// synchronous pure state transition; time and identities are inputs, never read or minted here.
// UUIDs cross as RFC 4122 text (either case in, lowercase out).

// MARK: - Typed record re-exports

public typealias AgentRunBeginAttemptV1 = AgentryUniFFIRaw.AgentRunBeginAttemptV1
public typealias AgentRunBindingIdentityV1 = AgentryUniFFIRaw.AgentRunBindingIdentityV1
public typealias AgentRunEpochTransitionKindV1 = AgentryUniFFIRaw.AgentRunEpochTransitionKindV1
public typealias AgentRunExecutionOperationEndingV1 = AgentryUniFFIRaw.AgentRunExecutionOperationEndingV1
public typealias AgentRunExecutionOperationResultV1 = AgentryUniFFIRaw.AgentRunExecutionOperationResultV1
public typealias AgentRunExecutionReportV1 = AgentryUniFFIRaw.AgentRunExecutionReportV1
public typealias AgentRunExecutionResultV1 = AgentryUniFFIRaw.AgentRunExecutionResultV1
public typealias AgentRunExecutionTraceEventV1 = AgentryUniFFIRaw.AgentRunExecutionTraceEventV1
public typealias AgentRunFailureReasonV1 = AgentryUniFFIRaw.AgentRunFailureReasonV1
public typealias AgentRunLifecycleStageV1 = AgentryUniFFIRaw.AgentRunLifecycleStageV1
public typealias AgentRunLifecycleTrackerSnapshotV1 = AgentryUniFFIRaw.AgentRunLifecycleTrackerSnapshotV1
public typealias AgentRunLivenessSignalKindV1 = AgentryUniFFIRaw.AgentRunLivenessSignalKindV1
public typealias AgentRunLivenessSnapshotV1 = AgentryUniFFIRaw.AgentRunLivenessSnapshotV1
public typealias AgentRunOwnershipV1 = AgentryUniFFIRaw.AgentRunOwnershipV1
public typealias AgentRunProcessIdentitySnapshotV1 = AgentryUniFFIRaw.AgentRunProcessIdentitySnapshotV1
public typealias AgentRunProgressAcceptanceV1 = AgentryUniFFIRaw.AgentRunProgressAcceptanceV1
public typealias AgentRunProgressRejectionV1 = AgentryUniFFIRaw.AgentRunProgressRejectionV1
public typealias AgentRunProgressSignalV1 = AgentryUniFFIRaw.AgentRunProgressSignalV1
public typealias AgentRunProviderExecutionResultV1 = AgentryUniFFIRaw.AgentRunProviderExecutionResultV1
public typealias AgentRunProviderOperationEndingV1 = AgentryUniFFIRaw.AgentRunProviderOperationEndingV1
public typealias AgentRunRetryIntentV1 = AgentryUniFFIRaw.AgentRunRetryIntentV1
public typealias AgentRunSemanticResolutionV1 = AgentryUniFFIRaw.AgentRunSemanticResolutionV1
public typealias AgentRunTeardownRegistrationResultV1 = AgentryUniFFIRaw.AgentRunTeardownRegistrationResultV1
public typealias AgentRunTerminalCommitBeginResultV1 = AgentryUniFFIRaw.AgentRunTerminalCommitBeginResultV1
public typealias AgentRunTerminalCommitReceiptV1 = AgentryUniFFIRaw.AgentRunTerminalCommitReceiptV1
public typealias AgentRunTerminalCommitSnapshotV1 = AgentryUniFFIRaw.AgentRunTerminalCommitSnapshotV1
public typealias AgentRunTerminalOutcomeKindV1 = AgentryUniFFIRaw.AgentRunTerminalOutcomeKindV1
public typealias AgentRunTerminalOutcomeV1 = AgentryUniFFIRaw.AgentRunTerminalOutcomeV1
public typealias AgentRunTerminalPublicationResultV1 = AgentryUniFFIRaw.AgentRunTerminalPublicationResultV1
public typealias AgentRunTerminalSettlementSnapshotV1 = AgentryUniFFIRaw.AgentRunTerminalSettlementSnapshotV1
public typealias AgentRunTerminationSignalV1 = AgentryUniFFIRaw.AgentRunTerminationSignalV1
public typealias AgentRunTurnEpochV1 = AgentryUniFFIRaw.AgentRunTurnEpochV1

// MARK: - Error mapping

enum CoreAgentRunLifecycleErrorMapping {
    static func map(_ error: Error) -> CoreBridgeError {
        guard let error = error as? AgentryUniFFIRaw.CoreError else {
            if let bridgeError = error as? CoreBridgeError { return bridgeError }
            return .transportFailure(String(describing: error))
        }
        return switch error {
        case .InvalidArgument: .invalidArgument
        case .InternalPanic, .RuntimePoisoned: .runtimeInvalidated
        case let .AgentRunLifecycleInvalidRequest(message): .agentRunLifecycleInvalidRequest(message)
        default: .transportFailure(String(describing: error))
        }
    }

    static func rethrow<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch {
            throw map(error)
        }
    }
}

// MARK: - Lifecycle tracker

/// `DomainAgentRunLifecycleTracker` in Rust (`AgentRunLifecycleTrackerV1`): ownership + liveness
/// reducer embedding the terminal-commit phase and process identity for one run host.
public final class CoreAgentRunLifecycleTracker: Sendable {
    private let raw: AgentRunLifecycleTrackerV1

    public init() {
        raw = AgentRunLifecycleTrackerV1()
    }

    /// Back to the freshly constructed value.
    public func reset() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.reset() }
    }

    public func begin(_ attempt: AgentRunBeginAttemptV1) throws -> AgentRunOwnershipV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.begin(attempt: attempt) }
    }

    /// Mints the next sequence and accepts the resulting signal.
    public func record(
        ownership: AgentRunOwnershipV1,
        kind: AgentRunLivenessSignalKindV1,
        stage: AgentRunLifecycleStageV1,
        retryIntent: AgentRunRetryIntentV1,
        timestampUptimeNanoseconds: UInt64
    ) throws -> AgentRunProgressAcceptanceV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow {
            try raw.record(
                ownership: ownership,
                kind: kind,
                stage: stage,
                retryIntent: retryIntent,
                timestampUptimeNanoseconds: timestampUptimeNanoseconds
            )
        }
    }

    /// Accepts a caller-sequenced signal.
    public func accept(_ signal: AgentRunProgressSignalV1) throws -> AgentRunProgressAcceptanceV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.accept(signal: signal) }
    }

    /// Ends the active attempt; with `expectedOwnership`, only if it is still the owner.
    public func end(ifCurrent expectedOwnership: AgentRunOwnershipV1? = nil) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.end(expectedOwnership: expectedOwnership) }
    }

    public func installProcessRunID(_ runID: String) throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.installProcessRunId(runId: runID) }
    }

    public func clearProcessRunID(ifCurrent runID: String) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.clearProcessRunIdIfCurrent(runId: runID) }
    }

    public func forceClearProcessRunID() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.forceClearProcessRunId() }
    }

    public func bumpTerminalDrainGeneration() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.bumpTerminalDrainGeneration() }
    }

    public func beginTerminalCommit() throws -> AgentRunTerminalCommitBeginResultV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.beginTerminalCommit() }
    }

    public func stageTerminalCommit(commitID: String, ownership: AgentRunOwnershipV1) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow {
            try raw.stageTerminalCommit(commitId: commitID, ownership: ownership)
        }
    }

    public func recordTerminalPublicationResult(_ result: AgentRunTerminalPublicationResultV1) throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.recordTerminalPublicationResult(result: result) }
    }

    public func abortTerminalCommit() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.abortTerminalCommit() }
    }

    public func completeTerminalCommit() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.completeTerminalCommit() }
    }

    public func invalidateTerminalCommit() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.invalidateTerminalCommit() }
    }

    public func hasTerminalCommit(for ownership: AgentRunOwnershipV1) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.hasTerminalCommit(ownership: ownership) }
    }

    /// Every `package`-visible property of the Swift tracker, typed.
    public func state() throws -> AgentRunLifecycleTrackerSnapshotV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.state() }
    }

    /// Fixed-format JSON of `state()` for string comparison across implementations.
    public func canonicalState() throws -> String {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.canonicalState() }
    }
}

// MARK: - Process identity

/// `DomainAgentRunProcessIdentityState` in Rust (`AgentRunProcessIdentityStateV1`).
public final class CoreAgentRunProcessIdentityState: Sendable {
    private let raw: AgentRunProcessIdentityStateV1

    public init(runID: String? = nil, terminalDrainGeneration: UInt64 = 0) throws {
        raw = try CoreAgentRunLifecycleErrorMapping.rethrow {
            try AgentRunProcessIdentityStateV1(runId: runID, terminalDrainGeneration: terminalDrainGeneration)
        }
    }

    public func install(_ runID: String) throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.install(runId: runID) }
    }

    public func clear(ifCurrent runID: String) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.clearIfCurrent(runId: runID) }
    }

    public func forceClear() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.forceClear() }
    }

    public func bumpTerminalDrainGeneration() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.bumpTerminalDrainGeneration() }
    }

    public func resetForNewAttempt() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.resetForNewAttempt() }
    }

    public func state() throws -> AgentRunProcessIdentitySnapshotV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.state() }
    }

    public func canonicalState() throws -> String {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.canonicalState() }
    }
}

// MARK: - Terminal commit

/// `DomainAgentRunTerminalCommitState` in Rust (`AgentRunTerminalCommitStateV1`).
public final class CoreAgentRunTerminalCommitState: Sendable {
    private let raw: AgentRunTerminalCommitStateV1

    public init() {
        raw = AgentRunTerminalCommitStateV1()
    }

    public func begin(ownership: AgentRunOwnershipV1? = nil) throws -> AgentRunTerminalCommitBeginResultV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.begin(ownership: ownership) }
    }

    public func stage(commitID: String, ownership: AgentRunOwnershipV1) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.stage(commitId: commitID, ownership: ownership) }
    }

    public func record(_ result: AgentRunTerminalPublicationResultV1) throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.record(result: result) }
    }

    public func abort() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.abort() }
    }

    public func complete() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.complete() }
    }

    public func invalidate() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.invalidate() }
    }

    public func reset() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.reset() }
    }

    public func matches(ownership: AgentRunOwnershipV1) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.matches(ownership: ownership) }
    }

    public func state() throws -> AgentRunTerminalCommitSnapshotV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.state() }
    }

    public func canonicalState() throws -> String {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.canonicalState() }
    }
}

// MARK: - Terminal settlement

/// `DomainAgentRunTerminalSettlementCoordinator` in Rust (`AgentRunTerminalSettlementCoordinatorV1`).
public final class CoreAgentRunTerminalSettlementCoordinator: Sendable {
    private let raw: AgentRunTerminalSettlementCoordinatorV1

    public init() {
        raw = AgentRunTerminalSettlementCoordinatorV1()
    }

    public func hasConsumedProviderSuccessor(id: String) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.hasConsumedProviderSuccessor(id: id) }
    }

    /// Returns whether a new tombstone was recorded.
    public func recordProviderSuccessorConsumption(id: String, deliverySucceeded: Bool = true) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow {
            try raw.recordProviderSuccessorConsumption(id: id, deliverySucceeded: deliverySucceeded)
        }
    }

    public func registerTeardown(
        ownership: AgentRunOwnershipV1,
        token: String
    ) throws -> AgentRunTeardownRegistrationResultV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.registerTeardown(ownership: ownership, token: token) }
    }

    public func hasPendingTeardown(for ownership: AgentRunOwnershipV1) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.hasPendingTeardown(ownership: ownership) }
    }

    /// Lowercase UUID text of the registered token, if any.
    public func teardownToken(for ownership: AgentRunOwnershipV1) throws -> String? {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.teardownToken(ownership: ownership) }
    }

    public func completeTeardown(ownership: AgentRunOwnershipV1, token: String) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.completeTeardown(ownership: ownership, token: token) }
    }

    public func reset() throws {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.reset() }
    }

    public func state() throws -> AgentRunTerminalSettlementSnapshotV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.state() }
    }

    public func canonicalState() throws -> String {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.canonicalState() }
    }
}

// MARK: - Semantic authority

/// `DomainAgentRunProviderSemanticAuthority` plus the pure classification half of
/// `DomainAgentRunExecutionCore` in Rust (`AgentRunSemanticAuthorityV1`). Stateless.
public final class CoreAgentRunSemanticAuthority: Sendable {
    private let raw: AgentRunSemanticAuthorityV1

    public init() {
        raw = AgentRunSemanticAuthorityV1()
    }

    public func resolve(_ signal: AgentRunTerminationSignalV1) throws -> AgentRunSemanticResolutionV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.resolve(signal: signal) }
    }

    public func outcome(_ signal: AgentRunTerminationSignalV1) throws -> AgentRunTerminalOutcomeV1? {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.outcome(signal: signal) }
    }

    public func isTerminal(_ signal: AgentRunTerminationSignalV1) throws -> Bool {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.isTerminal(signal: signal) }
    }

    /// Classification of `DomainAgentRunExecutionCore.execute` given how the operation ended.
    public func classifyExecution(
        _ ending: AgentRunExecutionOperationEndingV1,
        failureReason: AgentRunFailureReasonV1 = .agentError,
        deferFailureClassification: Bool = false
    ) throws -> AgentRunExecutionReportV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow {
            try raw.classifyExecution(
                ending: ending,
                failureReason: failureReason,
                deferFailureClassification: deferFailureClassification
            )
        }
    }

    /// Classification of `DomainAgentRunExecutionCore.executeProvider` given how the operation ended.
    public func classifyProviderExecution(
        _ ending: AgentRunProviderOperationEndingV1
    ) throws -> AgentRunExecutionReportV1 {
        try CoreAgentRunLifecycleErrorMapping.rethrow { try raw.classifyProviderExecution(ending: ending) }
    }
}
