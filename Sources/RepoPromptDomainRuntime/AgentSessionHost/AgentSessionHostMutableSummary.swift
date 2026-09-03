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
