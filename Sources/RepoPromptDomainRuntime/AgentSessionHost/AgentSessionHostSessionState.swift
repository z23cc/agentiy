import AgentryCoreBridge
import Foundation

/// Mutable mirror of the immutable generated `AgentHostSessionSummaryV1` so the reducer can update
/// single fields; `value` materializes the wire record.
package struct AgentSessionHostMutableSummary: Equatable {
    package var sessionId: String
    package var workspaceId = ""
    package var worktreeId = ""
    package var sessionName = ""
    package var providerId = ""
    package var agentId = ""
    package var agentDisplayName = ""
    package var modelId = ""
    package var reasoningEffort = ""
    package var status: AgentHostSessionStatusV1 = .unspecified
    package var statusText = ""
    package var latestAssistantPreview = ""
    package var interaction: AgentHostPendingInteractionV1?
    package var transcriptItemCount: UInt64 = 0
    package var createdAt = ""
    package var updatedAt = ""
    package var parentSessionId = ""
    package var failureReason: AgentHostFailureReasonV1 = .unspecified
    package var providerSessionId = ""
    package var activeRunId = ""
    package var attachedClientCount: UInt32 = 0
    package var generation = Data()
    package var lastCursor: UInt64 = 0

    package init(sessionId: String) {
        self.sessionId = sessionId
    }

    package init(_ summary: AgentHostSessionSummaryV1) {
        sessionId = summary.sessionId
        workspaceId = summary.workspaceId
        worktreeId = summary.worktreeId
        sessionName = summary.sessionName
        providerId = summary.providerId
        agentId = summary.agentId
        agentDisplayName = summary.agentDisplayName
        modelId = summary.modelId
        reasoningEffort = summary.reasoningEffort
        status = summary.status
        statusText = summary.statusText
        latestAssistantPreview = summary.latestAssistantPreview
        interaction = summary.interaction
        transcriptItemCount = summary.transcriptItemCount
        createdAt = summary.createdAt
        updatedAt = summary.updatedAt
        parentSessionId = summary.parentSessionId
        failureReason = summary.failureReason
        providerSessionId = summary.providerSessionId
        activeRunId = summary.activeRunId
        attachedClientCount = summary.attachedClientCount
        generation = summary.generation
        lastCursor = summary.lastCursor
    }

    package init(spec: AgentHostSessionSpecV1, now: String) {
        sessionId = spec.sessionId
        workspaceId = spec.workspaceId
        worktreeId = spec.worktreeId
        sessionName = spec.sessionName
        providerId = spec.providerId
        agentId = spec.agentId
        agentDisplayName = spec.agentDisplayName
        modelId = spec.modelId
        reasoningEffort = spec.reasoningEffort
        parentSessionId = spec.parentSessionId
        providerSessionId = spec.resumeProviderSessionId
        status = .waitingForInput
        statusText = "starting"
        createdAt = now
        updatedAt = now
    }

    package var value: AgentHostSessionSummaryV1 {
        AgentHostSessionSummaryV1(
            sessionId: sessionId,
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            sessionName: sessionName,
            providerId: providerId,
            agentId: agentId,
            agentDisplayName: agentDisplayName,
            modelId: modelId,
            reasoningEffort: reasoningEffort,
            status: status,
            statusText: statusText,
            latestAssistantPreview: latestAssistantPreview,
            interaction: interaction,
            transcriptItemCount: transcriptItemCount,
            createdAt: createdAt,
            updatedAt: updatedAt,
            parentSessionId: parentSessionId,
            failureReason: failureReason,
            providerSessionId: providerSessionId,
            activeRunId: activeRunId,
            attachedClientCount: attachedClientCount,
            generation: generation,
            lastCursor: lastCursor
        )
    }
}

/// Swift value-state oracle for the P6-b differential harness.
///
/// Production host folding and snapshot `compact` use `AgentSessionHostFoldedState` →
/// `CoreAgentSessionTranscriptReducer`. Do not wire this type back into the host (ADR-0006: no
/// product rollback switch). Delete it when the live-oracle differentials no longer need it.
package struct AgentSessionHostSessionState {
    package private(set) var mutableSummary: AgentSessionHostMutableSummary
    package private(set) var transcript: [AgentHostTranscriptEntryV1] = []
    package private(set) var pendingInteractions: [AgentHostPendingInteractionV1] = []
    /// Every `CommandAccepted` seen, by operation id; the fingerprint lives here.
    package private(set) var acceptedOperations: [String: AgentHostCommandAcceptedV1] = [:]
    package private(set) var settledOperations: [String: AgentHostCommandSettledV1] = [:]
    package private(set) var settledInteractionIDs: Set<String> = []
    /// Later `respond_interaction` answers that lost first-writer-wins (design §5.6 / M5).
    package private(set) var staleInteractionResponseCount: UInt64 = 0
    /// Cursor of the last event folded in (0 when none).
    package private(set) var lastCursor: UInt64 = 0
    /// True once a `SessionMetadataChanged` record has been seen; a log without one is unusable.
    package private(set) var hasMetadata = false
    private var assistantDraft: AssistantDraft?

    private struct AssistantDraft {
        var runID: String
        var turnID: String
        var text: String
        var createdAt: String
    }

    package init(summary: AgentSessionHostMutableSummary) {
        mutableSummary = summary
        hasMetadata = summary.status != .unspecified
    }

    /// Placeholder state for a recovered log whose first record has not been read yet.
    package static func placeholder(sessionID: String) -> AgentSessionHostSessionState {
        AgentSessionHostSessionState(summary: AgentSessionHostMutableSummary(sessionId: sessionID))
    }

    package init(snapshot: AgentHostAgentSessionSnapshotV1) {
        if let summary = snapshot.summary {
            mutableSummary = AgentSessionHostMutableSummary(summary)
            hasMetadata = true
        } else {
            mutableSummary = AgentSessionHostMutableSummary(sessionId: snapshot.sessionId)
        }
        transcript = snapshot.transcript
        pendingInteractions = snapshot.pendingInteractions
        for accepted in snapshot.unsettledOperations {
            acceptedOperations[accepted.operationId] = accepted
        }
        lastCursor = snapshot.throughCursor
    }

    package var summary: AgentHostSessionSummaryV1 {
        mutableSummary.value
    }

    package var isTerminal: Bool {
        switch mutableSummary.status {
        case .completed, .failed, .cancelled, .expired: true
        case .unspecified, .running, .waitingForInput: false
        }
    }

    package var hasLiveRun: Bool {
        !mutableSummary.activeRunId.isEmpty || !pendingInteractions.isEmpty
    }

    package var unsettledOperations: [AgentHostCommandAcceptedV1] {
        acceptedOperations.values
            .filter { settledOperations[$0.operationId] == nil }
            .sorted { ($0.acceptedAt, $0.operationId) < ($1.acceptedAt, $1.operationId) }
    }

    // MARK: Reduction

    package mutating func apply(_ event: AgentHostAgentSessionEventV1, cursor: UInt64) {
        lastCursor = max(lastCursor, cursor)
        mutableSummary.lastCursor = lastCursor
        mutableSummary.updatedAt = event.recordedAt
        guard let body = event.body else { return }
        switch body {
        case let .sessionMetadataChanged(change):
            if let next = change.summary {
                var replacement = AgentSessionHostMutableSummary(next)
                replacement.attachedClientCount = mutableSummary.attachedClientCount
                replacement.generation = mutableSummary.generation
                replacement.lastCursor = lastCursor
                replacement.interaction = pendingInteractions.first
                replacement.transcriptItemCount = UInt64(transcript.count)
                mutableSummary = replacement
                hasMetadata = true
            }
        case let .userMessage(message):
            appendUserMessage(message, cursor: cursor, recordedAt: event.recordedAt)
        case let .runLifecycle(lifecycle):
            applyLifecycle(lifecycle, cursor: cursor, recordedAt: event.recordedAt)
        case let .runtimeEvent(runtime):
            applyRuntime(runtime, cursor: cursor, recordedAt: event.recordedAt)
        case let .interaction(interaction):
            switch interaction.kind {
            case let .requested(requested):
                if let pending = requested.interaction {
                    pendingInteractions.removeAll { $0.interactionId == pending.interactionId }
                    pendingInteractions.append(pending)
                }
            case let .settled(settled):
                pendingInteractions.removeAll { $0.interactionId == settled.interactionId }
                settledInteractionIDs.insert(settled.interactionId)
            case nil:
                break
            }
            mutableSummary.interaction = pendingInteractions.first
        case let .commandAccepted(accepted):
            acceptedOperations[accepted.operationId] = accepted
        case let .commandSettled(settled):
            settledOperations[settled.operationId] = settled
        case .imported, .forkedFrom:
            break
        }
    }

    /// User messages arrive twice for a steer (`UserMessage` record, then the executor's `RunStarted`
    /// carrying the same message) and once for the initial message; dedupe by message id.
    private mutating func appendUserMessage(_ message: AgentHostUserMessageV1, cursor: UInt64, recordedAt: String) {
        let entryID = message.messageId.isEmpty ? "user-\(cursor)" : message.messageId
        guard !transcript.contains(where: { $0.role == .user && $0.entryId == entryID }) else { return }
        transcript.append(AgentHostTranscriptEntryV1(
            entryId: entryID,
            role: .user,
            text: message.text,
            reasoning: "",
            toolName: "",
            toolInvocationId: "",
            toolArgsJson: "",
            toolResultJson: "",
            toolIsError: false,
            attachments: message.attachments,
            createdAt: message.createdAt.isEmpty ? recordedAt : message.createdAt,
            turnId: "",
            throughCursor: cursor
        ))
        mutableSummary.transcriptItemCount = UInt64(transcript.count)
    }

    private mutating func applyLifecycle(_ lifecycle: AgentHostRunLifecycleEventV1, cursor: UInt64, recordedAt: String) {
        switch lifecycle.kind {
        case let .started(started):
            if let message = started.message {
                appendUserMessage(message, cursor: cursor, recordedAt: recordedAt)
            }
            mutableSummary.activeRunId = lifecycle.runId
            mutableSummary.status = .running
            mutableSummary.statusText = "running"
            mutableSummary.failureReason = .unspecified
            assistantDraft = nil
        case let .stageChanged(stage):
            mutableSummary.statusText = Self.describe(stage.stage)
        case let .terminated(terminated):
            flushAssistantDraft(cursor: cursor, recordedAt: recordedAt)
            mutableSummary.activeRunId = ""
            switch terminated.outcome?.kind ?? .unspecified {
            case .completed, .unspecified:
                mutableSummary.status = .waitingForInput
                mutableSummary.statusText = "turn completed"
            case .cancelled:
                mutableSummary.status = .waitingForInput
                mutableSummary.statusText = "interrupted"
            case .failed:
                mutableSummary.status = .failed
                mutableSummary.statusText = "failed"
                mutableSummary.failureReason = terminated.outcome?.failureReason ?? .unspecified
            }
            for pending in pendingInteractions {
                settledInteractionIDs.insert(pending.interactionId)
            }
            pendingInteractions.removeAll()
            mutableSummary.interaction = nil
        case nil:
            break
        }
    }

    private mutating func applyRuntime(_ runtime: AgentHostRuntimeEventV1, cursor: UInt64, recordedAt: String) {
        switch runtime.kind {
        case let .stream(stream):
            switch stream.itemType {
            case "content":
                var draft = assistantDraft ?? AssistantDraft(runID: runtime.runId, turnID: runtime.turnId, text: "", createdAt: recordedAt)
                draft.text += stream.text ?? ""
                assistantDraft = draft
            case "final_content":
                var draft = assistantDraft ?? AssistantDraft(runID: runtime.runId, turnID: runtime.turnId, text: "", createdAt: recordedAt)
                if let text = stream.text, !text.isEmpty { draft.text = text }
                assistantDraft = draft
            default:
                break
            }
            if let providerSessionID = stream.providerSessionId, !providerSessionID.isEmpty {
                mutableSummary.providerSessionId = providerSessionID
            }
        case let .runtimeInit(status):
            if !status.providerSessionId.isEmpty {
                mutableSummary.providerSessionId = status.providerSessionId
            }
        case .turnCompleted:
            flushAssistantDraft(cursor: cursor, recordedAt: recordedAt)
        case let .error(error):
            mutableSummary.statusText = error.message
        case .approvalRequest, .approvalCancelled, nil:
            break
        }
    }

    private mutating func flushAssistantDraft(cursor: UInt64, recordedAt: String) {
        guard let draft = assistantDraft else { return }
        assistantDraft = nil
        guard !draft.text.isEmpty else { return }
        transcript.append(AgentHostTranscriptEntryV1(
            entryId: "assistant-\(cursor)",
            role: .assistant,
            text: draft.text,
            reasoning: "",
            toolName: "",
            toolInvocationId: "",
            toolArgsJson: "",
            toolResultJson: "",
            toolIsError: false,
            attachments: [],
            createdAt: draft.createdAt.isEmpty ? recordedAt : draft.createdAt,
            turnId: draft.turnID,
            throughCursor: cursor
        ))
        mutableSummary.transcriptItemCount = UInt64(transcript.count)
        mutableSummary.latestAssistantPreview = String(draft.text.prefix(200))
    }

    // MARK: Host-owned fields

    package mutating func setGeneration(_ generation: Data) {
        mutableSummary.generation = generation
    }

    package mutating func setAttachedClientCount(_ count: Int) {
        mutableSummary.attachedClientCount = UInt32(max(0, count))
    }

    package mutating func recordStaleInteractionResponse() {
        staleInteractionResponseCount &+= 1
    }

    /// The summary the host records when it changes status itself (stop, restart demotion).
    package func summary(
        status: AgentHostSessionStatusV1,
        statusText: String,
        clearingActiveRun: Bool,
        now: String
    ) -> AgentHostSessionSummaryV1 {
        var next = mutableSummary
        next.status = status
        next.statusText = statusText
        if clearingActiveRun { next.activeRunId = "" }
        next.updatedAt = now
        return next.value
    }

    package func snapshot(generation: Data, now: String) -> AgentHostAgentSessionSnapshotV1 {
        AgentHostAgentSessionSnapshotV1(
            sessionId: mutableSummary.sessionId,
            generation: generation,
            throughCursor: lastCursor,
            summary: summary,
            transcript: transcript,
            pendingInteractions: pendingInteractions,
            unsettledOperations: unsettledOperations,
            writtenAt: now
        )
    }

    private static func describe(_ stage: AgentHostLifecycleStageV1) -> String {
        switch stage {
        case .unspecified: "running"
        case .starting: "starting"
        case .preparingRuntime: "preparing runtime"
        case .running: "running"
        case .waitingForInteraction: "waiting for interaction"
        case .retrying: "retrying"
        case .cancelling: "cancelling"
        }
    }
}
