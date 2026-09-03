import AgentryCoreBridge
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

// ADR-0011 P6-b differential harness support: applies the same `AgentHostAgentSessionEventV1`
// to `AgentSessionHostSessionState` and `CoreAgentSessionTranscriptReducer`, then compares the
// snapshot, package-visible flags, and canonical JSON. Any disagreement is a Rust bug (fix in
// Rust) or a Swift bug (report; never change the Swift reducer here).

// MARK: - Seed / size

enum P6BDifferentialConfiguration {
    static let defaultSeed: UInt64 = 0xB6E7_5EED_0000_0006

    static var seed: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["AGENTRY_P6B_DIFFERENTIAL_SEED"],
           let value = UInt64(raw)
        {
            return value
        }
        return defaultSeed
    }

    static var scale: Int {
        if let raw = ProcessInfo.processInfo.environment["AGENTRY_P6B_DIFFERENTIAL_SCALE"],
           let value = Int(raw), value > 0
        {
            return value
        }
        return 1
    }
}

// MARK: - Hex / enum names (must match rust/crates/runtime/src/agent_session_transcript)

enum P6BCanonicalNames {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func status(_ value: AgentHostSessionStatusV1) -> String {
        switch value {
        case .unspecified: "unspecified"
        case .running: "running"
        case .waitingForInput: "waitingForInput"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .expired: "expired"
        }
    }

    static func failure(_ value: AgentHostFailureReasonV1) -> String {
        switch value {
        case .unspecified: "unspecified"
        case .processCrash: "processCrash"
        case .timeout: "timeout"
        case .agentError: "agentError"
        case .cancelled: "cancelled"
        }
    }

    static func role(_ value: AgentHostTranscriptRoleV1) -> String {
        switch value {
        case .unspecified: "unspecified"
        case .user: "user"
        case .assistant: "assistant"
        case .tool: "tool"
        case .system: "system"
        }
    }

    static func interactionKind(_ value: AgentHostInteractionKindV1) -> String {
        switch value {
        case .unspecified: "unspecified"
        case .instruction: "instruction"
        case .question: "question"
        case .userInput: "userInput"
        case .approval: "approval"
        case .hookApproval: "hookApproval"
        case .mcpElicitation: "mcpElicitation"
        }
    }
}

extension AgentSessionHostSessionState {
    var p6bCanonical: String {
        let accepted = acceptedOperations.values.sorted { $0.operationId < $1.operationId }
        let settled = settledOperations.values.sorted { $0.operationId < $1.operationId }
        let settledIDs = settledInteractionIDs.sorted()
        return P6ACanonical.object()
            .u64("lastCursor", lastCursor)
            .bool("hasMetadata", hasMetadata)
            .bool("isTerminal", isTerminal)
            .bool("hasLiveRun", hasLiveRun)
            .raw("summary", summary.p6bCanonical)
            .raw("transcript", "[\(transcript.map(\.p6bCanonical).joined(separator: ","))]")
            .raw("pendingInteractions", "[\(pendingInteractions.map(\.p6bCanonical).joined(separator: ","))]")
            .raw("acceptedOperations", "[\(accepted.map(\.p6bCanonical).joined(separator: ","))]")
            .raw("settledOperations", "[\(settled.map(\.p6bCanonical).joined(separator: ","))]")
            .raw("settledInteractionIDs", "[\(settledIDs.map(P6ACanonical.jsonString).joined(separator: ","))]")
            .finish()
    }
}

extension AgentHostSessionSummaryV1 {
    var p6bCanonical: String {
        P6ACanonical.object()
            .string("sessionId", sessionId)
            .string("workspaceId", workspaceId)
            .string("worktreeId", worktreeId)
            .string("sessionName", sessionName)
            .string("providerId", providerId)
            .string("agentId", agentId)
            .string("agentDisplayName", agentDisplayName)
            .string("modelId", modelId)
            .string("reasoningEffort", reasoningEffort)
            .string("status", P6BCanonicalNames.status(status))
            .string("statusText", statusText)
            .string("latestAssistantPreview", latestAssistantPreview)
            .string("interactionId", interaction?.interactionId)
            .u64("transcriptItemCount", transcriptItemCount)
            .string("createdAt", createdAt)
            .string("updatedAt", updatedAt)
            .string("parentSessionId", parentSessionId)
            .string("failureReason", P6BCanonicalNames.failure(failureReason))
            .string("providerSessionId", providerSessionId)
            .string("activeRunId", activeRunId)
            .u64("attachedClientCount", UInt64(attachedClientCount))
            .string("generation", P6BCanonicalNames.hex(generation))
            .u64("lastCursor", lastCursor)
            .finish()
    }
}

extension AgentHostTranscriptEntryV1 {
    var p6bCanonical: String {
        let attachments = attachments.map { P6ACanonical.jsonString($0.artifactId) }.joined(separator: ",")
        return P6ACanonical.object()
            .string("entryId", entryId)
            .string("role", P6BCanonicalNames.role(role))
            .string("text", text)
            .string("reasoning", reasoning)
            .string("toolName", toolName)
            .string("toolInvocationId", toolInvocationId)
            .string("toolArgsJson", toolArgsJson)
            .string("toolResultJson", toolResultJson)
            .bool("toolIsError", toolIsError)
            .raw("attachments", "[\(attachments)]")
            .string("createdAt", createdAt)
            .string("turnId", turnId)
            .u64("throughCursor", throughCursor)
            .finish()
    }
}

extension AgentHostPendingInteractionV1 {
    var p6bCanonical: String {
        P6ACanonical.object()
            .string("interactionId", interactionId)
            .string("generation", P6BCanonicalNames.hex(interactionGeneration))
            .string("kind", P6BCanonicalNames.interactionKind(kind))
            .string("title", title)
            .string("prompt", prompt)
            .string("runId", runId)
            .string("turnId", turnId)
            .string("requestedAt", requestedAt)
            .finish()
    }
}

extension AgentHostCommandAcceptedV1 {
    var p6bCanonical: String {
        P6ACanonical.object()
            .string("operationId", operationId)
            .string("argumentFingerprint", argumentFingerprint)
            .string("commandKind", commandKind)
            .string("acceptedAt", acceptedAt)
            .finish()
    }
}

extension AgentHostCommandSettledV1 {
    var p6bCanonical: String {
        let settlement: String = switch self.settlement {
        case .result: "result"
        case .rejected: "rejected"
        case nil: "none"
        }
        return P6ACanonical.object()
            .string("operationId", operationId)
            .string("settledAt", settledAt)
            .string("settlement", settlement)
            .finish()
    }
}

// MARK: - Event fixtures

enum P6BFixtures {
    static let sessionID = "sess-p6b"
    static let compareGeneration = Data([0x67, 0x65, 0x6E])
    static let compareNow = "2026-09-03T00:00:00Z"

    static func emptySummary(
        sessionID: String = sessionID,
        sessionName: String = "",
        status: AgentHostSessionStatusV1 = .unspecified,
        statusText: String = "",
        transcriptItemCount: UInt64 = 0,
        updatedAt: String = "",
        failureReason: AgentHostFailureReasonV1 = .unspecified,
        activeRunId: String = "",
        attachedClientCount: UInt32 = 0,
        generation: Data = Data()
    ) -> AgentHostSessionSummaryV1 {
        AgentHostSessionSummaryV1(
            sessionId: sessionID,
            workspaceId: "",
            worktreeId: "",
            sessionName: sessionName,
            providerId: "",
            agentId: "",
            agentDisplayName: "",
            modelId: "",
            reasoningEffort: "",
            status: status,
            statusText: statusText,
            latestAssistantPreview: "",
            interaction: nil,
            transcriptItemCount: transcriptItemCount,
            createdAt: "",
            updatedAt: updatedAt,
            parentSessionId: "",
            failureReason: failureReason,
            providerSessionId: "",
            activeRunId: activeRunId,
            attachedClientCount: attachedClientCount,
            generation: generation,
            lastCursor: 0
        )
    }

    static func userMessage(id: String, text: String, createdAt: String = "") -> AgentHostUserMessageV1 {
        AgentHostUserMessageV1(messageId: id, text: text, attachments: [], createdAt: createdAt)
    }

    static func event(_ recordedAt: String, _ body: AgentHostAgentSessionEventBodyV1?) -> AgentHostAgentSessionEventV1 {
        AgentHostAgentSessionEventV1(recordedAt: recordedAt, body: body)
    }

    static func stream(itemType: String, text: String? = nil, providerSessionId: String? = nil) -> AgentHostStreamResultV1 {
        AgentHostStreamResultV1(
            itemType: itemType,
            text: text,
            reasoning: nil,
            promptTokens: nil,
            completionTokens: nil,
            cost: nil,
            toolName: nil,
            toolArgs: nil,
            toolOutput: nil,
            toolInvocationId: nil,
            toolResultJson: nil,
            toolArgsJson: nil,
            toolIsError: nil,
            providerSessionId: providerSessionId,
            stopReason: nil,
            modelContextWindow: nil,
            contextUsedTokens: nil,
            contentMessageId: nil
        )
    }

    static func runtime(_ runID: String, _ turnID: String, _ kind: AgentHostRuntimeEventKindV1) -> AgentHostAgentSessionEventBodyV1 {
        .runtimeEvent(AgentHostRuntimeEventV1(runId: runID, turnId: turnID, kind: kind))
    }

    static func lifecycle(_ runID: String, _ kind: AgentHostRunLifecycleEventKindV1) -> AgentHostAgentSessionEventBodyV1 {
        .runLifecycle(AgentHostRunLifecycleEventV1(runId: runID, epoch: nil, kind: kind))
    }

    static func pending(id: String, prompt: String = "choose") -> AgentHostPendingInteractionV1 {
        AgentHostPendingInteractionV1(
            interactionId: id,
            interactionGeneration: Data([1, 2]),
            kind: .question,
            responseType: .unspecified,
            title: "ask",
            prompt: prompt,
            context: "",
            allowsMultiple: false,
            options: [],
            fields: [],
            details: [],
            approval: nil,
            requestedAt: "t0",
            timeoutSeconds: 0,
            runId: "run-1",
            turnId: "turn-1"
        )
    }
}

// MARK: - Dual reducer

final class P6BDualTranscriptReducer {
    private(set) var swift: AgentSessionHostSessionState
    let rust: CoreAgentSessionTranscriptReducer
    private var step = 0
    private let file: StaticString
    private let line: UInt

    init(
        sessionID: String = P6BFixtures.sessionID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        swift = .placeholder(sessionID: sessionID)
        rust = CoreAgentSessionTranscriptReducer(placeholderSessionID: sessionID)
        self.file = file
        self.line = line
        try assertAgreement("init")
    }

    init(
        summary: AgentHostSessionSummaryV1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        swift = AgentSessionHostSessionState(summary: AgentSessionHostMutableSummary(summary))
        rust = try CoreAgentSessionTranscriptReducer(summary: summary)
        self.file = file
        self.line = line
        try assertAgreement("init-summary")
    }

    init(
        snapshot: AgentHostAgentSessionSnapshotV1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        swift = AgentSessionHostSessionState(snapshot: snapshot)
        rust = try CoreAgentSessionTranscriptReducer(snapshot: snapshot)
        self.file = file
        self.line = line
        try assertAgreement("init-snapshot")
    }

    func assertAgreement(_ label: String) throws {
        let rustSnapshot = try rust.snapshot(generation: P6BFixtures.compareGeneration, now: P6BFixtures.compareNow)
        let swiftSnapshot = swift.snapshot(generation: P6BFixtures.compareGeneration, now: P6BFixtures.compareNow)
        XCTAssertEqual(swift.lastCursor, try rust.lastCursor(), "lastCursor \(label)", file: file, line: line)
        XCTAssertEqual(swift.hasMetadata, try rust.hasMetadata(), "hasMetadata \(label)", file: file, line: line)
        XCTAssertEqual(swift.isTerminal, try rust.isTerminal(), "isTerminal \(label)", file: file, line: line)
        XCTAssertEqual(swift.hasLiveRun, try rust.hasLiveRun(), "hasLiveRun \(label)", file: file, line: line)
        XCTAssertEqual(swiftSnapshot, rustSnapshot, "snapshot \(label)", file: file, line: line)
        XCTAssertEqual(swift.p6bCanonical, try rust.canonicalState(), "canonical \(label)", file: file, line: line)
    }

    func apply(_ event: AgentHostAgentSessionEventV1, cursor: UInt64) throws {
        step += 1
        let label = "apply#\(step)@\(cursor)"
        swift.apply(event, cursor: cursor)
        try rust.apply(event, cursor: cursor)
        try assertAgreement(label)
    }

    func setGeneration(_ generation: Data) throws {
        swift.setGeneration(generation)
        try rust.setGeneration(generation)
        try assertAgreement("setGeneration")
    }

    func setAttachedClientCount(_ count: Int) throws {
        swift.setAttachedClientCount(count)
        try rust.setAttachedClientCount(count)
        try assertAgreement("setAttachedClientCount")
    }

    func hostOwnedSummary(
        status: AgentHostSessionStatusV1,
        statusText: String,
        clearingActiveRun: Bool,
        now: String
    ) throws -> AgentHostSessionSummaryV1 {
        let swiftSummary = swift.summary(
            status: status,
            statusText: statusText,
            clearingActiveRun: clearingActiveRun,
            now: now
        )
        let rustSummary = try rust.hostOwnedSummary(
            status: status,
            statusText: statusText,
            clearingActiveRun: clearingActiveRun,
            now: now
        )
        XCTAssertEqual(swiftSummary, rustSummary, "hostOwnedSummary", file: file, line: line)
        try assertAgreement("hostOwnedSummary-state")
        return swiftSummary
    }

    func reset() throws {
        swift = .placeholder(sessionID: swift.summary.sessionId)
        try rust.reset()
        try assertAgreement("reset")
    }
}

// MARK: - Corpus

enum P6BCorpus {
    static func event(from rng: inout P6ASplitMix64) -> (AgentHostAgentSessionEventV1, UInt64) {
        let cursorBase = UInt64(rng.below(32)) + 1
        let recorded = "t-\(rng.below(20))"
        switch rng.below(16) {
        case 0:
            return (P6BFixtures.event(recorded, .userMessage(P6BFixtures.userMessage(
                id: rng.percent(20) ? "" : "m\(rng.below(4))",
                text: "hello-\(rng.below(6))"
            ))), cursorBase)
        case 1:
            let withMessage = rng.percent(70)
            return (P6BFixtures.event(recorded, P6BFixtures.lifecycle(
                "run-\(rng.below(3))",
                .started(AgentHostRunStartedV1(
                    attemptId: "a\(rng.below(3))",
                    message: withMessage ? P6BFixtures.userMessage(id: "m\(rng.below(4))", text: "start") : nil
                ))
            )), cursorBase)
        case 2:
            return (P6BFixtures.event(recorded, P6BFixtures.runtime(
                "run-1",
                "turn-1",
                .stream(P6BFixtures.stream(
                    itemType: "content",
                    text: "c\(rng.below(8))",
                    providerSessionId: rng.percent(30) ? "ps-\(rng.below(2))" : nil
                ))
            )), cursorBase)
        case 3:
            return (P6BFixtures.event(recorded, P6BFixtures.runtime(
                "run-1",
                "turn-1",
                .stream(P6BFixtures.stream(itemType: "final_content", text: rng.percent(50) ? "final" : nil))
            )), cursorBase)
        case 4:
            return (P6BFixtures.event(recorded, P6BFixtures.runtime(
                "run-1",
                "turn-1",
                .stream(P6BFixtures.stream(itemType: rng.pick(["reasoning", "tool_call", "usage"]), text: "ignored"))
            )), cursorBase)
        case 5:
            return (P6BFixtures.event(recorded, P6BFixtures.runtime(
                "run-1",
                "turn-1",
                .turnCompleted(AgentHostTurnCompletedV1(turnId: "turn-1", stopReason: ""))
            )), cursorBase)
        case 6:
            let kinds: [AgentHostTerminalOutcomeKindV1] = [.completed, .cancelled, .failed, .unspecified]
            return (P6BFixtures.event(recorded, P6BFixtures.lifecycle(
                "run-1",
                .terminated(AgentHostRunTerminatedV1(
                    outcome: AgentHostTerminalOutcomeV1(
                        kind: rng.pick(kinds),
                        assistantText: nil,
                        failureReason: rng.percent(40) ? .timeout : .unspecified
                    ),
                    signal: nil
                ))
            )), cursorBase)
        case 7:
            let stages: [AgentHostLifecycleStageV1] = [
                .unspecified, .starting, .preparingRuntime, .running,
                .waitingForInteraction, .retrying, .cancelling,
            ]
            return (P6BFixtures.event(recorded, P6BFixtures.lifecycle(
                "run-1",
                .stageChanged(AgentHostRunStageChangedV1(stage: rng.pick(stages), retryIntent: .none))
            )), cursorBase)
        case 8:
            let summary = P6BFixtures.emptySummary(
                sessionName: "meta-\(rng.below(3))",
                status: .running,
                transcriptItemCount: 50,
                updatedAt: "from-summary",
                attachedClientCount: 99,
                generation: Data([1])
            )
            return (P6BFixtures.event(recorded, .sessionMetadataChanged(AgentHostSessionMetadataChangedV1(summary: summary))), cursorBase)
        case 9:
            let id = "op\(rng.below(4))"
            return (P6BFixtures.event(recorded, .commandAccepted(AgentHostCommandAcceptedV1(
                operationId: id,
                argumentFingerprint: "f\(id)",
                commandKind: "steer",
                acceptedAt: "t\(rng.below(5))"
            ))), cursorBase)
        case 10:
            return (P6BFixtures.event(recorded, .commandSettled(AgentHostCommandSettledV1(
                operationId: "op\(rng.below(4))",
                settledAt: recorded,
                settlement: nil
            ))), cursorBase)
        case 11:
            return (P6BFixtures.event(recorded, .interaction(AgentHostInteractionEventV1(
                kind: .requested(AgentHostInteractionRequestedV1(interaction: P6BFixtures.pending(id: "q\(rng.below(3))")))
            ))), cursorBase)
        case 12:
            return (P6BFixtures.event(recorded, .interaction(AgentHostInteractionEventV1(
                kind: .settled(AgentHostInteractionSettledV1(
                    interactionId: "q\(rng.below(3))",
                    interactionGeneration: Data([1, 2]),
                    settlement: .answered,
                    answer: nil,
                    operationId: ""
                ))
            ))), cursorBase)
        case 13:
            return (P6BFixtures.event(recorded, P6BFixtures.runtime(
                "run-1",
                "turn-1",
                .runtimeInit(AgentHostRuntimeInitStatusV1(
                    providerSessionId: rng.percent(80) ? "ps-init" : "",
                    tools: [],
                    mcpServerStatuses: [],
                    initializeResponse: nil
                ))
            )), cursorBase)
        case 14:
            return (P6BFixtures.event(recorded, P6BFixtures.runtime(
                "run-1",
                "turn-1",
                .error(AgentHostRuntimeErrorV1(code: "e", message: "boom-\(rng.below(3))", recoverable: true))
            )), cursorBase)
        default:
            if rng.percent(50) {
                return (P6BFixtures.event(recorded, .imported(AgentHostImportedV1(
                    legacyDigest: "aa",
                    legacyFormat: "json",
                    importedItemCount: 0,
                    importedAt: recorded
                ))), cursorBase)
            }
            return (P6BFixtures.event(recorded, nil), cursorBase)
        }
    }
}
