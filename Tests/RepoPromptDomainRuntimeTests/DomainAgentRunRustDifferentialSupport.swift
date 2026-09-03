import AgentryCoreBridge
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

// ADR-0011 P6-a differential harness support: lowers Swift `DomainAgentRun*` values into the
// UniFFI `AgentRun…V1` mirrors (UUIDs lowercased, because Rust renders RFC 4122 text lowercase
// while `UUID.uuidString` is uppercase), renders Swift reducer state with the same fixed
// canonical JSON encoder the Rust side documents in `agent_run_lifecycle::canonical`, and wraps
// each Swift reducer together with its Rust twin so every transition is applied to both and
// compared. Any disagreement fails the calling test at the offending step.

// MARK: - Deterministic PRNG

/// SplitMix64: the corpus generator must be reproducible from a seed alone.
struct P6ASplitMix64 {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }

    mutating func percent(_ probability: Int) -> Bool {
        below(100) < probability
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[below(values.count)]
    }

    mutating func uuid() -> UUID {
        let high = next()
        let low = next()
        func byte(_ value: UInt64, _ shift: UInt64) -> UInt8 {
            UInt8(truncatingIfNeeded: value >> shift)
        }
        return UUID(uuid: (
            byte(high, 56), byte(high, 48), byte(high, 40), byte(high, 32),
            byte(high, 24), byte(high, 16), byte(high, 8), byte(high, 0),
            byte(low, 56), byte(low, 48), byte(low, 40), byte(low, 32),
            byte(low, 24), byte(low, 16), byte(low, 8), byte(low, 0)
        ))
    }
}

/// Seed / size knobs. Defaults are fixed so CI is reproducible; override with
/// `AGENTRY_P6A_DIFFERENTIAL_SEED` and `AGENTRY_P6A_DIFFERENTIAL_SCALE` (a multiplier) to widen.
enum P6ADifferentialConfiguration {
    static let defaultSeed: UInt64 = 0xA6E7_5EED_0000_0006

    static var seed: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["AGENTRY_P6A_DIFFERENTIAL_SEED"],
           let value = UInt64(raw)
        {
            return value
        }
        return defaultSeed
    }

    static var scale: Int {
        if let raw = ProcessInfo.processInfo.environment["AGENTRY_P6A_DIFFERENTIAL_SCALE"],
           let value = Int(raw), value > 0
        {
            return value
        }
        return 1
    }

    /// Distinct sub-seeds per reducer so widening one corpus does not perturb the others.
    static func seed(for reducer: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in reducer.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0100_0000_01B3
        }
        return seed ^ hash
    }
}

// MARK: - Swift -> V1 lowering

extension UUID {
    var p6aLowered: String {
        uuidString.lowercased()
    }
}

extension DomainAgentRunEpochTransitionKind {
    var p6aV1: AgentRunEpochTransitionKindV1 {
        switch self {
        case .initial: .initial
        case .relatedFollowUp: .relatedFollowUp
        case .steering: .steering
        case .unrelated: .unrelated
        }
    }
}

extension DomainAgentRunTurnEpoch {
    var p6aV1: AgentRunTurnEpochV1 {
        AgentRunTurnEpochV1(
            runtimeId: runtimeID.p6aLowered,
            runtimeGeneration: runtimeGeneration,
            sessionId: sessionID.p6aLowered,
            activationId: activationID.p6aLowered,
            registrationGeneration: registrationGeneration,
            id: id.p6aLowered,
            ordinal: ordinal,
            continuityGeneration: continuityGeneration,
            transitionKind: transitionKind.p6aV1
        )
    }
}

extension DomainAgentRunBindingIdentity {
    var p6aV1: AgentRunBindingIdentityV1 {
        AgentRunBindingIdentityV1(
            tabId: tabID.p6aLowered,
            persistentSessionId: persistentSessionID?.p6aLowered,
            persistentBindingGeneration: persistentBindingGeneration?.p6aLowered,
            bindingTransitionGeneration: bindingTransitionGeneration,
            generation: generation.p6aLowered
        )
    }
}

extension DomainAgentRunOwnership {
    var p6aV1: AgentRunOwnershipV1 {
        AgentRunOwnershipV1(
            attemptId: attemptID.p6aLowered,
            binding: binding.p6aV1,
            turnEpoch: turnEpoch?.p6aV1
        )
    }
}

extension DomainAgentRunLifecycleStage {
    var p6aV1: AgentRunLifecycleStageV1 {
        switch self {
        case .starting: .starting
        case .preparingRuntime: .preparingRuntime
        case .running: .running
        case .waitingForInteraction: .waitingForInteraction
        case .retrying: .retrying
        case .cancelling: .cancelling
        }
    }
}

extension DomainAgentRunLivenessSignalKind {
    var p6aV1: AgentRunLivenessSignalKindV1 {
        switch self {
        case .stageTransition: .stageTransition
        case .providerEvent: .providerEvent
        case .toolActivity: .toolActivity
        case .interaction: .interaction
        case .heartbeat: .heartbeat
        }
    }
}

extension DomainAgentRunRetryIntent {
    var p6aV1: AgentRunRetryIntentV1 {
        switch self {
        case .none: .none
        case .providerManaged: .providerManaged
        case .applicationManaged: .applicationManaged
        }
    }
}

extension DomainAgentRunProgressSignal {
    var p6aV1: AgentRunProgressSignalV1 {
        AgentRunProgressSignalV1(
            ownership: ownership.p6aV1,
            sequence: sequence,
            timestampUptimeNanoseconds: timestampUptimeNanoseconds,
            kind: kind.p6aV1,
            stage: stage.p6aV1,
            retryIntent: retryIntent.p6aV1
        )
    }
}

extension DomainAgentRunLivenessSnapshot {
    var p6aV1: AgentRunLivenessSnapshotV1 {
        AgentRunLivenessSnapshotV1(
            ownership: ownership.p6aV1,
            stage: stage.p6aV1,
            retryIntent: retryIntent.p6aV1,
            lastAcceptedSequence: lastAcceptedSequence,
            lastSignalUptimeNanoseconds: lastSignalUptimeNanoseconds,
            lastRealProgressUptimeNanoseconds: lastRealProgressUptimeNanoseconds,
            lastHeartbeatUptimeNanoseconds: lastHeartbeatUptimeNanoseconds
        )
    }
}

extension DomainAgentRunProgressRejection {
    var p6aV1: AgentRunProgressRejectionV1 {
        switch self {
        case .noActiveOwnership: .noActiveOwnership
        case .staleOwnership: .staleOwnership
        case .duplicateSequence: .duplicateSequence
        case .outOfOrderSequence: .outOfOrderSequence
        case .nonMonotonicTimestamp: .nonMonotonicTimestamp
        }
    }
}

extension DomainAgentRunProgressAcceptance {
    var p6aV1: AgentRunProgressAcceptanceV1 {
        switch self {
        case let .accepted(snapshot): .accepted(snapshot: snapshot.p6aV1)
        case let .rejected(rejection): .rejected(rejection: rejection.p6aV1)
        }
    }
}

extension DomainAgentRunTerminalPublicationResult {
    var p6aV1: AgentRunTerminalPublicationResultV1 {
        switch self {
        case let .accepted(successorEpoch): .accepted(successorEpoch: successorEpoch?.p6aV1)
        case .stale: .stale
        case let .rejected(reason): .rejected(reason: reason)
        }
    }
}

extension DomainAgentRunTerminalCommitReceipt {
    var p6aV1: AgentRunTerminalCommitReceiptV1 {
        AgentRunTerminalCommitReceiptV1(commitId: commitID.p6aLowered, ownership: ownership.p6aV1)
    }
}

extension DomainAgentRunTerminalCommitBeginResult {
    var p6aV1: AgentRunTerminalCommitBeginResultV1 {
        switch self {
        case .acquired: .acquired
        case .alreadyInProgress: .alreadyInProgress
        case .staleOwnership: .staleOwnership
        }
    }
}

extension DomainAgentRunTerminalTeardownRegistrationResult {
    var p6aV1: AgentRunTeardownRegistrationResultV1 {
        switch self {
        case .registered: .registered
        case .alreadyRegistered: .alreadyRegistered
        }
    }
}

extension DomainAgentRunSnapshot.FailureReason {
    var p6aV1: AgentRunFailureReasonV1 {
        switch self {
        case .processCrash: .processCrash
        case .timeout: .timeout
        case .agentError: .agentError
        case .cancelled: .cancelled
        }
    }
}

extension DomainAgentRunTerminalOutcome.Kind {
    var p6aV1: AgentRunTerminalOutcomeKindV1 {
        switch self {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }
}

extension DomainAgentRunTerminalOutcome {
    var p6aV1: AgentRunTerminalOutcomeV1 {
        AgentRunTerminalOutcomeV1(
            kind: kind.p6aV1,
            assistantText: assistantText,
            failureReason: failureReason?.p6aV1
        )
    }
}

extension DomainAgentRunProviderTerminationSignal {
    var p6aV1: AgentRunTerminationSignalV1 {
        switch self {
        case let .completed(text): .completed(assistantText: text)
        case let .cancelled(text): .cancelled(assistantText: text)
        case .superseded: .superseded
        case let .startupFailure(text): .startupFailure(assistantText: text)
        case let .providerFailure(text, reason): .providerFailure(assistantText: text, reason: reason?.p6aV1)
        case let .timeout(text): .timeout(assistantText: text)
        case let .processExited(text): .processExited(assistantText: text)
        case let .transportClosed(text): .transportClosed(assistantText: text)
        case let .unexpectedEnd(text): .unexpectedEnd(assistantText: text)
        }
    }
}

extension DomainAgentRunProviderSemanticResolution {
    var p6aV1: AgentRunSemanticResolutionV1 {
        switch self {
        case let .terminal(outcome): .terminal(outcome: outcome.p6aV1)
        case .superseded: .superseded
        }
    }
}

extension DomainAgentRunExecutionOperationResult {
    var p6aV1: AgentRunExecutionOperationResultV1 {
        switch self {
        case let .completed(text): .completed(assistantText: text)
        case let .terminal(outcome): .terminal(outcome: outcome.p6aV1)
        case .superseded: .superseded
        }
    }
}

extension DomainAgentRunProviderExecutionResult {
    var p6aV1: AgentRunProviderExecutionResultV1 {
        switch self {
        case let .completed(text): .completed(assistantText: text)
        case let .cancelled(text): .cancelled(assistantText: text)
        case let .failed(signal): .failed(signal: signal.p6aV1)
        case .superseded: .superseded
        }
    }
}

extension DomainAgentRunExecutionTraceEvent {
    var p6aV1: AgentRunExecutionTraceEventV1 {
        switch self {
        case .executionStarted: .executionStarted
        case let .terminalOutcomeProduced(kind): .terminalOutcomeProduced(kind: kind.p6aV1)
        case .executionSuperseded: .executionSuperseded
        }
    }
}

extension DomainAgentRunExecutionReport {
    var p6aV1: AgentRunExecutionReportV1 {
        let result: AgentRunExecutionResultV1 = switch self.result {
        case let .terminal(outcome): .terminal(outcome: outcome.p6aV1)
        case .superseded: .superseded
        }
        return AgentRunExecutionReportV1(result: result, trace: trace.map(\.p6aV1))
    }
}

extension DomainAgentRunLifecycleTracker {
    var p6aV1: AgentRunLifecycleTrackerSnapshotV1 {
        AgentRunLifecycleTrackerSnapshotV1(
            activeOwnership: activeOwnership?.p6aV1,
            liveness: liveness?.p6aV1,
            processRunId: processRunID?.p6aLowered,
            terminalDrainGeneration: terminalDrainGeneration,
            terminalCommitInProgress: terminalCommitInProgress,
            terminalCommitReceipt: terminalCommitReceipt?.p6aV1,
            terminalCommitPublicationResult: terminalCommitPublicationResult?.p6aV1
        )
    }
}

extension DomainAgentRunProcessIdentityState {
    var p6aV1: AgentRunProcessIdentitySnapshotV1 {
        AgentRunProcessIdentitySnapshotV1(
            runId: runID?.p6aLowered,
            terminalDrainGeneration: terminalDrainGeneration
        )
    }
}

extension DomainAgentRunTerminalCommitState {
    var p6aV1: AgentRunTerminalCommitSnapshotV1 {
        AgentRunTerminalCommitSnapshotV1(
            isInProgress: isInProgress,
            stagedReceipt: stagedReceipt?.p6aV1,
            publicationResult: publicationResult?.p6aV1
        )
    }
}

extension DomainAgentRunTerminalSettlementCoordinator {
    var p6aV1: AgentRunTerminalSettlementSnapshotV1 {
        AgentRunTerminalSettlementSnapshotV1(
            consumedProviderSuccessorCount: UInt64(consumedProviderSuccessorCount),
            maxProviderSuccessorTombstones: UInt64(Self.maxProviderSuccessorTombstones)
        )
    }
}

// MARK: - Swift canonical encoder (mirrors `agent_run_lifecycle::canonical`)

/// Ordered JSON object builder with serde_json-compatible string escaping.
final class P6ACanonical {
    private var buffer = "{"
    private var hasField = false

    static func object() -> P6ACanonical {
        P6ACanonical()
    }

    static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    @discardableResult
    func raw(_ key: String, _ rendered: String) -> P6ACanonical {
        if hasField { buffer += "," }
        hasField = true
        buffer += Self.jsonString(key)
        buffer += ":"
        buffer += rendered
        return self
    }

    @discardableResult
    func string(_ key: String, _ value: String?) -> P6ACanonical {
        raw(key, value.map(Self.jsonString) ?? "null")
    }

    @discardableResult
    func u64(_ key: String, _ value: UInt64?) -> P6ACanonical {
        raw(key, value.map(String.init) ?? "null")
    }

    @discardableResult
    func bool(_ key: String, _ value: Bool) -> P6ACanonical {
        raw(key, value ? "true" : "false")
    }

    @discardableResult
    func uuid(_ key: String, _ value: UUID?) -> P6ACanonical {
        string(key, value?.p6aLowered)
    }

    @discardableResult
    func nested(_ key: String, _ value: String?) -> P6ACanonical {
        raw(key, value ?? "null")
    }

    func finish() -> String {
        buffer + "}"
    }

    // Values

    static func canonical(_ epoch: DomainAgentRunTurnEpoch) -> String {
        object()
            .uuid("runtimeID", epoch.runtimeID)
            .u64("runtimeGeneration", epoch.runtimeGeneration)
            .uuid("sessionID", epoch.sessionID)
            .uuid("activationID", epoch.activationID)
            .u64("registrationGeneration", epoch.registrationGeneration)
            .uuid("id", epoch.id)
            .u64("ordinal", epoch.ordinal)
            .u64("continuityGeneration", epoch.continuityGeneration)
            .string("transitionKind", epoch.transitionKind.rawValue)
            .finish()
    }

    static func canonical(_ binding: DomainAgentRunBindingIdentity) -> String {
        object()
            .uuid("tabID", binding.tabID)
            .uuid("persistentSessionID", binding.persistentSessionID)
            .uuid("persistentBindingGeneration", binding.persistentBindingGeneration)
            .u64("bindingTransitionGeneration", binding.bindingTransitionGeneration)
            .uuid("generation", binding.generation)
            .finish()
    }

    static func canonical(_ ownership: DomainAgentRunOwnership) -> String {
        object()
            .uuid("attemptID", ownership.attemptID)
            .nested("binding", canonical(ownership.binding))
            .nested("turnEpoch", ownership.turnEpoch.map(canonical))
            .finish()
    }

    static func canonical(_ liveness: DomainAgentRunLivenessSnapshot) -> String {
        object()
            .nested("ownership", canonical(liveness.ownership))
            .string("stage", liveness.stage.rawValue)
            .string("retryIntent", liveness.retryIntent.rawValue)
            .u64("lastAcceptedSequence", liveness.lastAcceptedSequence)
            .u64("lastSignalUptimeNanoseconds", liveness.lastSignalUptimeNanoseconds)
            .u64("lastRealProgressUptimeNanoseconds", liveness.lastRealProgressUptimeNanoseconds)
            .u64("lastHeartbeatUptimeNanoseconds", liveness.lastHeartbeatUptimeNanoseconds)
            .finish()
    }

    static func canonical(_ result: DomainAgentRunTerminalPublicationResult) -> String {
        switch result {
        case let .accepted(successorEpoch):
            object()
                .string("result", "accepted")
                .nested("successorEpoch", successorEpoch.map(canonical))
                .finish()
        case .stale:
            object().string("result", "stale").finish()
        case let .rejected(reason):
            object().string("result", "rejected").string("reason", reason).finish()
        }
    }

    static func canonical(_ receipt: DomainAgentRunTerminalCommitReceipt) -> String {
        object()
            .uuid("commitID", receipt.commitID)
            .nested("ownership", canonical(receipt.ownership))
            .finish()
    }

    // Observable reducer state

    static func canonical(_ tracker: DomainAgentRunLifecycleTracker) -> String {
        object()
            .nested("activeOwnership", tracker.activeOwnership.map(canonical))
            .nested("liveness", tracker.liveness.map(canonical))
            .uuid("processRunID", tracker.processRunID)
            .u64("terminalDrainGeneration", tracker.terminalDrainGeneration)
            .bool("terminalCommitInProgress", tracker.terminalCommitInProgress)
            .nested("terminalCommitReceipt", tracker.terminalCommitReceipt.map(canonical))
            .nested("terminalCommitPublicationResult", tracker.terminalCommitPublicationResult.map(canonical))
            .finish()
    }

    static func canonical(_ identity: DomainAgentRunProcessIdentityState) -> String {
        object()
            .uuid("runID", identity.runID)
            .u64("terminalDrainGeneration", identity.terminalDrainGeneration)
            .finish()
    }

    static func canonical(_ state: DomainAgentRunTerminalCommitState) -> String {
        object()
            .bool("isInProgress", state.isInProgress)
            .nested("stagedReceipt", state.stagedReceipt.map(canonical))
            .nested("publicationResult", state.publicationResult.map(canonical))
            .finish()
    }

    static func canonical(_ coordinator: DomainAgentRunTerminalSettlementCoordinator) -> String {
        object()
            .u64("consumedProviderSuccessorCount", UInt64(coordinator.consumedProviderSuccessorCount))
            .finish()
    }
}

// MARK: - Dual drivers

/// Records how many transitions were compared and where the last one came from, so a failure
/// message identifies the step even inside a random corpus.
final class P6ADifferentialLedger {
    private(set) var transitions = 0
    var context = ""

    func step(_ label: String) -> String {
        transitions += 1
        return "\(context) step#\(transitions) \(label)"
    }
}

/// `DomainAgentRunLifecycleTracker` ⇄ `AgentRunLifecycleTrackerV1`.
final class P6ADualLifecycleTracker {
    private(set) var swift = DomainAgentRunLifecycleTracker()
    let rust = CoreAgentRunLifecycleTracker()
    let ledger: P6ADifferentialLedger
    private let file: StaticString
    private let line: UInt

    init(ledger: P6ADifferentialLedger = P6ADifferentialLedger(), file: StaticString = #filePath, line: UInt = #line) {
        self.ledger = ledger
        self.file = file
        self.line = line
    }

    func assertAgreement(_ label: String) throws {
        XCTAssertEqual(try rust.state(), swift.p6aV1, "state \(label)", file: file, line: line)
        XCTAssertEqual(try rust.canonicalState(), P6ACanonical.canonical(swift), "canonical \(label)", file: file, line: line)
    }

    @discardableResult
    func begin(
        tabID: UUID,
        persistentSessionID: UUID?,
        persistentBindingGeneration: UUID? = nil,
        bindingTransitionGeneration: UInt64 = 0,
        attemptID: UUID = UUID(),
        turnEpoch: DomainAgentRunTurnEpoch? = nil,
        timestampUptimeNanoseconds: UInt64
    ) throws -> DomainAgentRunOwnership {
        let label = ledger.step("begin")
        let ownership = swift.begin(
            tabID: tabID,
            persistentSessionID: persistentSessionID,
            persistentBindingGeneration: persistentBindingGeneration,
            bindingTransitionGeneration: bindingTransitionGeneration,
            attemptID: attemptID,
            turnEpoch: turnEpoch,
            timestampUptimeNanoseconds: timestampUptimeNanoseconds
        )
        // Swift mints the binding generation inside `begin`; Rust takes every identity as input.
        let rustOwnership = try rust.begin(AgentRunBeginAttemptV1(
            tabId: tabID.p6aLowered,
            persistentSessionId: persistentSessionID?.p6aLowered,
            persistentBindingGeneration: persistentBindingGeneration?.p6aLowered,
            bindingTransitionGeneration: bindingTransitionGeneration,
            bindingGeneration: ownership.binding.generation.p6aLowered,
            attemptId: attemptID.p6aLowered,
            turnEpoch: turnEpoch?.p6aV1,
            timestampUptimeNanoseconds: timestampUptimeNanoseconds
        ))
        XCTAssertEqual(rustOwnership, ownership.p6aV1, label, file: file, line: line)
        try assertAgreement(label)
        return ownership
    }

    @discardableResult
    func record(
        ownership: DomainAgentRunOwnership,
        kind: DomainAgentRunLivenessSignalKind,
        stage: DomainAgentRunLifecycleStage,
        retryIntent: DomainAgentRunRetryIntent = .none,
        timestampUptimeNanoseconds: UInt64
    ) throws -> DomainAgentRunProgressAcceptance {
        let label = ledger.step("record \(kind) \(stage) \(retryIntent) t=\(timestampUptimeNanoseconds)")
        let result = swift.record(
            ownership: ownership,
            kind: kind,
            stage: stage,
            retryIntent: retryIntent,
            timestampUptimeNanoseconds: timestampUptimeNanoseconds
        )
        let rustResult = try rust.record(
            ownership: ownership.p6aV1,
            kind: kind.p6aV1,
            stage: stage.p6aV1,
            retryIntent: retryIntent.p6aV1,
            timestampUptimeNanoseconds: timestampUptimeNanoseconds
        )
        XCTAssertEqual(rustResult, result.p6aV1, label, file: file, line: line)
        try assertAgreement(label)
        return result
    }

    @discardableResult
    func accept(_ signal: DomainAgentRunProgressSignal) throws -> DomainAgentRunProgressAcceptance {
        let label = ledger.step("accept seq=\(signal.sequence) t=\(signal.timestampUptimeNanoseconds)")
        let result = swift.accept(signal)
        let rustResult = try rust.accept(signal.p6aV1)
        XCTAssertEqual(rustResult, result.p6aV1, label, file: file, line: line)
        try assertAgreement(label)
        return result
    }

    @discardableResult
    func end(ifCurrent expected: DomainAgentRunOwnership? = nil) throws -> Bool {
        let label = ledger.step("end expected=\(expected != nil)")
        let result = swift.end(ifCurrent: expected)
        XCTAssertEqual(try rust.end(ifCurrent: expected?.p6aV1), result, label, file: file, line: line)
        try assertAgreement(label)
        return result
    }

    func installProcessRunID(_ runID: UUID) throws {
        let label = ledger.step("installProcessRunID")
        swift.installProcessRunID(runID)
        try rust.installProcessRunID(runID.p6aLowered)
        try assertAgreement(label)
    }

    @discardableResult
    func clearProcessRunID(ifCurrent runID: UUID) throws -> Bool {
        let label = ledger.step("clearProcessRunID")
        let result = swift.clearProcessRunID(ifCurrent: runID)
        XCTAssertEqual(try rust.clearProcessRunID(ifCurrent: runID.p6aLowered), result, label, file: file, line: line)
        try assertAgreement(label)
        return result
    }

    func forceClearProcessRunID() throws {
        let label = ledger.step("forceClearProcessRunID")
        swift.forceClearProcessRunID()
        try rust.forceClearProcessRunID()
        try assertAgreement(label)
    }

    func bumpTerminalDrainGeneration() throws {
        let label = ledger.step("bumpTerminalDrainGeneration")
        swift.bumpTerminalDrainGeneration()
        try rust.bumpTerminalDrainGeneration()
        try assertAgreement(label)
    }

    @discardableResult
    func beginTerminalCommit() throws -> DomainAgentRunTerminalCommitBeginResult {
        let label = ledger.step("beginTerminalCommit")
        let result = swift.beginTerminalCommit()
        XCTAssertEqual(try rust.beginTerminalCommit(), result.p6aV1, label, file: file, line: line)
        try assertAgreement(label)
        return result
    }

    @discardableResult
    func stageTerminalCommit(commitID: UUID, ownership: DomainAgentRunOwnership) throws -> Bool {
        let label = ledger.step("stageTerminalCommit")
        let result = swift.stageTerminalCommit(commitID: commitID, ownership: ownership)
        XCTAssertEqual(
            try rust.stageTerminalCommit(commitID: commitID.p6aLowered, ownership: ownership.p6aV1),
            result,
            label,
            file: file,
            line: line
        )
        try assertAgreement(label)
        return result
    }

    func recordTerminalPublicationResult(_ result: DomainAgentRunTerminalPublicationResult) throws {
        let label = ledger.step("recordTerminalPublicationResult")
        swift.recordTerminalPublicationResult(result)
        try rust.recordTerminalPublicationResult(result.p6aV1)
        try assertAgreement(label)
    }

    func abortTerminalCommit() throws {
        let label = ledger.step("abortTerminalCommit")
        swift.abortTerminalCommit()
        try rust.abortTerminalCommit()
        try assertAgreement(label)
    }

    func completeTerminalCommit() throws {
        let label = ledger.step("completeTerminalCommit")
        swift.completeTerminalCommit()
        try rust.completeTerminalCommit()
        try assertAgreement(label)
    }

    func invalidateTerminalCommit() throws {
        let label = ledger.step("invalidateTerminalCommit")
        swift.invalidateTerminalCommit()
        try rust.invalidateTerminalCommit()
        try assertAgreement(label)
    }

    func hasTerminalCommit(for ownership: DomainAgentRunOwnership) throws -> Bool {
        let label = ledger.step("hasTerminalCommit")
        let result = swift.hasTerminalCommit(for: ownership)
        XCTAssertEqual(try rust.hasTerminalCommit(for: ownership.p6aV1), result, label, file: file, line: line)
        return result
    }

    func reset() throws {
        let label = ledger.step("reset")
        swift = DomainAgentRunLifecycleTracker()
        try rust.reset()
        try assertAgreement(label)
    }
}

/// `DomainAgentRunProcessIdentityState` ⇄ `AgentRunProcessIdentityStateV1`.
final class P6ADualProcessIdentity {
    private(set) var swift: DomainAgentRunProcessIdentityState
    let rust: CoreAgentRunProcessIdentityState
    let ledger: P6ADifferentialLedger
    private let file: StaticString
    private let line: UInt

    init(
        runID: UUID? = nil,
        terminalDrainGeneration: UInt64 = 0,
        ledger: P6ADifferentialLedger = P6ADifferentialLedger(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        swift = DomainAgentRunProcessIdentityState(runID: runID, terminalDrainGeneration: terminalDrainGeneration)
        rust = try CoreAgentRunProcessIdentityState(
            runID: runID?.p6aLowered,
            terminalDrainGeneration: terminalDrainGeneration
        )
        self.ledger = ledger
        self.file = file
        self.line = line
        try assertAgreement("init")
    }

    func assertAgreement(_ label: String) throws {
        XCTAssertEqual(try rust.state(), swift.p6aV1, "state \(label)", file: file, line: line)
        XCTAssertEqual(try rust.canonicalState(), P6ACanonical.canonical(swift), "canonical \(label)", file: file, line: line)
    }

    func install(_ runID: UUID) throws {
        let label = ledger.step("install")
        swift.install(runID)
        try rust.install(runID.p6aLowered)
        try assertAgreement(label)
    }

    @discardableResult
    func clear(ifCurrent runID: UUID) throws -> Bool {
        let label = ledger.step("clearIfCurrent")
        let result = swift.clear(ifCurrent: runID)
        XCTAssertEqual(try rust.clear(ifCurrent: runID.p6aLowered), result, label, file: file, line: line)
        try assertAgreement(label)
        return result
    }

    func forceClear() throws {
        let label = ledger.step("forceClear")
        swift.forceClear()
        try rust.forceClear()
        try assertAgreement(label)
    }

    func bumpTerminalDrainGeneration() throws {
        let label = ledger.step("bumpTerminalDrainGeneration")
        swift.bumpTerminalDrainGeneration()
        try rust.bumpTerminalDrainGeneration()
        try assertAgreement(label)
    }

    func resetForNewAttempt() throws {
        let label = ledger.step("resetForNewAttempt")
        swift.resetForNewAttempt()
        try rust.resetForNewAttempt()
        try assertAgreement(label)
    }
}

/// `DomainAgentRunTerminalCommitState` ⇄ `AgentRunTerminalCommitStateV1`.
final class P6ADualTerminalCommit {
    private(set) var swift = DomainAgentRunTerminalCommitState()
    let rust = CoreAgentRunTerminalCommitState()
    let ledger: P6ADifferentialLedger
    private let file: StaticString
    private let line: UInt

    init(ledger: P6ADifferentialLedger = P6ADifferentialLedger(), file: StaticString = #filePath, line: UInt = #line) {
        self.ledger = ledger
        self.file = file
        self.line = line
    }

    func assertAgreement(_ label: String) throws {
        XCTAssertEqual(try rust.state(), swift.p6aV1, "state \(label)", file: file, line: line)
        XCTAssertEqual(try rust.canonicalState(), P6ACanonical.canonical(swift), "canonical \(label)", file: file, line: line)
    }

    @discardableResult
    func begin(ownership: DomainAgentRunOwnership? = nil) throws -> DomainAgentRunTerminalCommitBeginResult {
        let label = ledger.step("begin ownership=\(ownership != nil)")
        let result = swift.begin(ownership: ownership)
        XCTAssertEqual(try rust.begin(ownership: ownership?.p6aV1), result.p6aV1, label, file: file, line: line)
        try assertAgreement(label)
        return result
    }

    @discardableResult
    func stage(commitID: UUID, ownership: DomainAgentRunOwnership) throws -> Bool {
        let label = ledger.step("stage")
        let result = swift.stage(commitID: commitID, ownership: ownership)
        XCTAssertEqual(
            try rust.stage(commitID: commitID.p6aLowered, ownership: ownership.p6aV1),
            result,
            label,
            file: file,
            line: line
        )
        try assertAgreement(label)
        return result
    }

    func record(_ result: DomainAgentRunTerminalPublicationResult) throws {
        let label = ledger.step("record")
        swift.record(result)
        try rust.record(result.p6aV1)
        try assertAgreement(label)
    }

    func abort() throws {
        let label = ledger.step("abort")
        swift.abort()
        try rust.abort()
        try assertAgreement(label)
    }

    func complete() throws {
        let label = ledger.step("complete")
        swift.complete()
        try rust.complete()
        try assertAgreement(label)
    }

    func invalidate() throws {
        let label = ledger.step("invalidate")
        swift.invalidate()
        try rust.invalidate()
        try assertAgreement(label)
    }

    func reset() throws {
        let label = ledger.step("reset")
        swift.reset()
        try rust.reset()
        try assertAgreement(label)
    }

    func matches(ownership: DomainAgentRunOwnership) throws -> Bool {
        let label = ledger.step("matches")
        let result = swift.matches(ownership: ownership)
        XCTAssertEqual(try rust.matches(ownership: ownership.p6aV1), result, label, file: file, line: line)
        return result
    }
}

/// `DomainAgentRunTerminalSettlementCoordinator` ⇄ `AgentRunTerminalSettlementCoordinatorV1`.
///
/// The Swift collections are private, so agreement is proven by probing every identity the
/// scenario has ever used after each transition, in addition to the observable count.
final class P6ADualSettlement {
    private(set) var swift = DomainAgentRunTerminalSettlementCoordinator()
    let rust = CoreAgentRunTerminalSettlementCoordinator()
    let ledger: P6ADifferentialLedger
    private let file: StaticString
    private let line: UInt
    private var knownSuccessorIDs: [UUID] = []
    private var knownOwnerships: [DomainAgentRunOwnership] = []

    init(ledger: P6ADifferentialLedger = P6ADifferentialLedger(), file: StaticString = #filePath, line: UInt = #line) {
        self.ledger = ledger
        self.file = file
        self.line = line
    }

    private func remember(successor id: UUID) {
        if !knownSuccessorIDs.contains(id) { knownSuccessorIDs.append(id) }
        // Probing every tombstone ever seen is quadratic; keep the probe window a little
        // wider than the FIFO bound so eviction of the oldest entries is still observed.
        let window = DomainAgentRunTerminalSettlementCoordinator.maxProviderSuccessorTombstones + 64
        if knownSuccessorIDs.count > window {
            knownSuccessorIDs.removeFirst(knownSuccessorIDs.count - window)
        }
    }

    private func remember(_ ownership: DomainAgentRunOwnership) {
        if !knownOwnerships.contains(ownership) { knownOwnerships.append(ownership) }
    }

    func assertAgreement(_ label: String, probe: Bool = true) throws {
        XCTAssertEqual(try rust.state(), swift.p6aV1, "state \(label)", file: file, line: line)
        XCTAssertEqual(try rust.canonicalState(), P6ACanonical.canonical(swift), "canonical \(label)", file: file, line: line)
        guard probe else { return }
        for id in knownSuccessorIDs {
            XCTAssertEqual(
                try rust.hasConsumedProviderSuccessor(id: id.p6aLowered),
                swift.hasConsumedProviderSuccessor(id: id),
                "probe successor \(id) \(label)",
                file: file,
                line: line
            )
        }
        for ownership in knownOwnerships {
            XCTAssertEqual(
                try rust.hasPendingTeardown(for: ownership.p6aV1),
                swift.hasPendingTeardown(for: ownership),
                "probe pending \(label)",
                file: file,
                line: line
            )
            XCTAssertEqual(
                try rust.teardownToken(for: ownership.p6aV1),
                swift.teardownToken(for: ownership)?.p6aLowered,
                "probe token \(label)",
                file: file,
                line: line
            )
        }
    }

    func hasConsumedProviderSuccessor(id: UUID) throws -> Bool {
        let label = ledger.step("hasConsumedProviderSuccessor")
        let result = swift.hasConsumedProviderSuccessor(id: id)
        XCTAssertEqual(try rust.hasConsumedProviderSuccessor(id: id.p6aLowered), result, label, file: file, line: line)
        return result
    }

    @discardableResult
    func recordProviderSuccessorConsumption(id: UUID, deliverySucceeded: Bool = true, probe: Bool = true) throws -> Bool {
        let label = ledger.step("recordProviderSuccessorConsumption delivered=\(deliverySucceeded)")
        remember(successor: id)
        let result = swift.recordProviderSuccessorConsumption(id: id, deliverySucceeded: deliverySucceeded)
        XCTAssertEqual(
            try rust.recordProviderSuccessorConsumption(id: id.p6aLowered, deliverySucceeded: deliverySucceeded),
            result,
            label,
            file: file,
            line: line
        )
        try assertAgreement(label, probe: probe)
        return result
    }

    @discardableResult
    func registerTeardown(ownership: DomainAgentRunOwnership, token: UUID) throws -> DomainAgentRunTerminalTeardownRegistrationResult {
        let label = ledger.step("registerTeardown")
        remember(ownership)
        let result = swift.registerTeardown(ownership: ownership, token: token)
        XCTAssertEqual(
            try rust.registerTeardown(ownership: ownership.p6aV1, token: token.p6aLowered),
            result.p6aV1,
            label,
            file: file,
            line: line
        )
        try assertAgreement(label)
        return result
    }

    func hasPendingTeardown(for ownership: DomainAgentRunOwnership) throws -> Bool {
        let label = ledger.step("hasPendingTeardown")
        let result = swift.hasPendingTeardown(for: ownership)
        XCTAssertEqual(try rust.hasPendingTeardown(for: ownership.p6aV1), result, label, file: file, line: line)
        return result
    }

    func teardownToken(for ownership: DomainAgentRunOwnership) throws -> UUID? {
        let label = ledger.step("teardownToken")
        let result = swift.teardownToken(for: ownership)
        XCTAssertEqual(try rust.teardownToken(for: ownership.p6aV1), result?.p6aLowered, label, file: file, line: line)
        return result
    }

    @discardableResult
    func completeTeardown(ownership: DomainAgentRunOwnership, token: UUID) throws -> Bool {
        let label = ledger.step("completeTeardown")
        remember(ownership)
        let result = swift.completeTeardown(ownership: ownership, token: token)
        XCTAssertEqual(
            try rust.completeTeardown(ownership: ownership.p6aV1, token: token.p6aLowered),
            result,
            label,
            file: file,
            line: line
        )
        try assertAgreement(label)
        return result
    }

    func reset() throws {
        let label = ledger.step("reset")
        swift.reset()
        try rust.reset()
        try assertAgreement(label)
    }
}

// MARK: - Fixture vocabulary shared by scenarios and corpora

enum P6AFixtures {
    static let assistantTexts: [String?] = [
        nil,
        "",
        "done",
        "a\"quoted\" \\ backslash / slash",
        "line\nbreak\ttab\r\u{08}\u{0C}\u{01}\u{1F}",
        "unicode é ✓ 日本語 😀",
        String(repeating: "x", count: 300)
    ]

    static let stages: [DomainAgentRunLifecycleStage] = [
        .starting, .preparingRuntime, .running, .waitingForInteraction, .retrying, .cancelling
    ]
    static let signalKinds: [DomainAgentRunLivenessSignalKind] = [
        .stageTransition, .providerEvent, .toolActivity, .interaction, .heartbeat
    ]
    static let retryIntents: [DomainAgentRunRetryIntent] = [.none, .providerManaged, .applicationManaged]
    static let failureReasons: [DomainAgentRunSnapshot.FailureReason] = [.processCrash, .timeout, .agentError, .cancelled]
    static let transitionKinds: [DomainAgentRunEpochTransitionKind] = [.initial, .relatedFollowUp, .steering, .unrelated]

    static func epoch(_ rng: inout P6ASplitMix64) -> DomainAgentRunTurnEpoch {
        DomainAgentRunTurnEpoch(
            runtimeID: rng.uuid(),
            runtimeGeneration: UInt64(rng.below(4)),
            sessionID: rng.uuid(),
            activationID: rng.uuid(),
            registrationGeneration: UInt64(rng.below(9)),
            id: rng.uuid(),
            ordinal: UInt64(rng.below(20)),
            continuityGeneration: UInt64(rng.below(5)),
            transitionKind: rng.pick(transitionKinds)
        )
    }

    /// A pool of ownerships that are pairwise distinct but share components, so equality-based
    /// fences are exercised on near-misses (same binding/different attempt, same attempt/different
    /// generation, with/without epoch) rather than only on unrelated identities.
    static func ownershipPool(_ rng: inout P6ASplitMix64) -> [DomainAgentRunOwnership] {
        let tabID = rng.uuid()
        let sessionID = rng.uuid()
        let generation = rng.uuid()
        let attemptID = rng.uuid()
        let sharedEpoch = epoch(&rng)
        let base = DomainAgentRunBindingIdentity(
            tabID: tabID,
            persistentSessionID: sessionID,
            persistentBindingGeneration: nil,
            bindingTransitionGeneration: 0,
            generation: generation
        )
        return [
            DomainAgentRunOwnership(attemptID: attemptID, binding: base),
            DomainAgentRunOwnership(attemptID: rng.uuid(), binding: base),
            DomainAgentRunOwnership(
                attemptID: attemptID,
                binding: DomainAgentRunBindingIdentity(
                    tabID: tabID,
                    persistentSessionID: sessionID,
                    persistentBindingGeneration: nil,
                    bindingTransitionGeneration: 0,
                    generation: rng.uuid()
                )
            ),
            DomainAgentRunOwnership(
                attemptID: attemptID,
                binding: DomainAgentRunBindingIdentity(
                    tabID: tabID,
                    persistentSessionID: nil,
                    persistentBindingGeneration: rng.uuid(),
                    bindingTransitionGeneration: 3,
                    generation: generation
                )
            ),
            DomainAgentRunOwnership(attemptID: attemptID, binding: base, turnEpoch: sharedEpoch),
            DomainAgentRunOwnership(attemptID: attemptID, binding: base, turnEpoch: epoch(&rng)),
            DomainAgentRunOwnership(
                attemptID: rng.uuid(),
                binding: DomainAgentRunBindingIdentity(tabID: rng.uuid(), persistentSessionID: nil, generation: rng.uuid())
            )
        ]
    }

    static func publicationResult(_ rng: inout P6ASplitMix64) -> DomainAgentRunTerminalPublicationResult {
        switch rng.below(4) {
        case 0: .accepted(successorEpoch: nil)
        case 1: .accepted(successorEpoch: epoch(&rng))
        case 2: .stale
        default: .rejected(reason: rng.pick(assistantTexts) ?? "different_commit_already_published")
        }
    }

    static func terminationSignal(_ rng: inout P6ASplitMix64) -> DomainAgentRunProviderTerminationSignal {
        let text = rng.pick(assistantTexts)
        switch rng.below(9) {
        case 0: return .completed(assistantText: text)
        case 1: return .cancelled(assistantText: text)
        case 2: return .superseded
        case 3: return .startupFailure(assistantText: text)
        case 4:
            let reason: DomainAgentRunSnapshot.FailureReason? = rng.percent(50) ? rng.pick(failureReasons) : nil
            return .providerFailure(assistantText: text, reason: reason)
        case 5: return .timeout(assistantText: text)
        case 6: return .processExited(assistantText: text)
        case 7: return .transportClosed(assistantText: text)
        default: return .unexpectedEnd(assistantText: text)
        }
    }

    /// Every termination-signal shape with every text/reason combination the enum admits.
    static var exhaustiveTerminationSignals: [DomainAgentRunProviderTerminationSignal] {
        var signals: [DomainAgentRunProviderTerminationSignal] = [.superseded]
        for text in assistantTexts {
            signals.append(.completed(assistantText: text))
            signals.append(.cancelled(assistantText: text))
            signals.append(.startupFailure(assistantText: text))
            signals.append(.providerFailure(assistantText: text, reason: nil))
            for reason in failureReasons {
                signals.append(.providerFailure(assistantText: text, reason: reason))
            }
            signals.append(.timeout(assistantText: text))
            signals.append(.processExited(assistantText: text))
            signals.append(.transportClosed(assistantText: text))
            signals.append(.unexpectedEnd(assistantText: text))
        }
        return signals
    }

    static var exhaustiveTerminalOutcomes: [DomainAgentRunTerminalOutcome] {
        var outcomes: [DomainAgentRunTerminalOutcome] = []
        for text in assistantTexts {
            outcomes.append(.completed(assistantText: text))
            outcomes.append(.cancelled(assistantText: text))
            outcomes.append(.failedWithoutClassification(assistantText: text))
            for reason in failureReasons {
                outcomes.append(.failed(assistantText: text, reason: reason))
            }
        }
        return outcomes
    }
}

enum P6AFixtureError: Error {
    case failed(String)
}

/// How a Swift execution-core operation closure should end, mirrored to the Rust
/// `AgentRunExecutionOperationEndingV1` / `AgentRunProviderOperationEndingV1` inputs.
enum P6AOperationEnding<Result> {
    case returned(Result)
    case threwCancellation
    case threwError(String)

    func perform() throws -> Result {
        switch self {
        case let .returned(result): return result
        case .threwCancellation: throw CancellationError()
        case let .threwError(text): throw P6AFixtureError.failed(text)
        }
    }

    /// The failure-text mapper the Swift core is given; Rust receives the same text directly.
    var failureText: String {
        if case let .threwError(text) = self { return text }
        return "unexpected failure-text mapper call"
    }
}

extension P6AOperationEnding where Result == DomainAgentRunExecutionOperationResult {
    var p6aV1: AgentRunExecutionOperationEndingV1 {
        switch self {
        case let .returned(result): .returned(result: result.p6aV1)
        case .threwCancellation: .threwCancellation
        case let .threwError(text): .threwError(failureText: text)
        }
    }
}

extension P6AOperationEnding where Result == DomainAgentRunProviderExecutionResult {
    var p6aV1: AgentRunProviderOperationEndingV1 {
        switch self {
        case let .returned(result): .returned(result: result.p6aV1)
        case .threwCancellation: .threwCancellation
        case let .threwError(text): .threwError(failureText: text)
        }
    }
}
