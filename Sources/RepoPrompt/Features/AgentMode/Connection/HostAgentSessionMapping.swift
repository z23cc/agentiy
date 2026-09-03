import AgentryCoreBridge
import Foundation
import RepoPromptDomainRuntime

/// 1:1 mapping between frozen `agent_host_v1` payloads and the P1.5 client seam.
/// Host extras the GUI used to carry in-process (`executionContext`, `draftText`,
/// `codexAttemptID`) are dropped here; send status is derived from `SessionSummary`.
enum HostAgentSessionMapping {
    static func cursor(generation: Data, delivery: UInt64) -> AgentSessionCursor {
        AgentSessionCursor(generation: generation, deliveryCursor: delivery)
    }

    static func replay(_ value: AgentHostAttachReplayV1) -> AgentSessionReplayFidelity {
        switch value {
        case .complete: .complete
        case .partial: .partial
        case .unavailable, .unspecified: .unavailable
        }
    }

    static func runState(_ status: AgentHostSessionStatusV1, pending: AgentHostPendingInteractionV1?) -> AgentSessionRunState {
        if let pending {
            switch pending.kind {
            case .approval, .hookApproval: return .waitingForApproval
            case .question, .userInput, .mcpElicitation, .instruction, .unspecified: return .waitingForQuestion
            }
        }
        switch status {
        case .running: return .running
        case .waitingForInput: return .waitingForUser
        case .completed: return .completed
        case .failed, .expired: return .failed
        case .cancelled: return .cancelled
        case .unspecified: return .idle
        }
    }

    static func listedSummary(_ summary: AgentHostSessionSummaryV1) -> AgentSessionListedSummary? {
        guard let sessionID = UUID(uuidString: summary.sessionId) else { return nil }
        return AgentSessionListedSummary(
            sessionID: sessionID,
            workspaceID: UUID(uuidString: summary.workspaceId),
            sessionName: summary.sessionName,
            runState: runState(summary.status, pending: summary.interaction),
            attachedClientCount: Int(summary.attachedClientCount),
            lastCursor: summary.lastCursor,
            generation: summary.generation,
            statusText: summary.statusText
        )
    }

    static func sendOutcome(from summary: AgentHostSessionSummaryV1?) -> AgentSessionSendOutcome {
        switch summary?.status {
        case .failed, .expired:
            .failed(reason: summary?.statusText.isEmpty == false ? summary!.statusText : "provider failed")
        case .cancelled:
            .cancelled
        default:
            .accepted
        }
    }

    static func provider(id: String) -> AgentProviderKind {
        AgentProviderKind(rawValue: id) ?? .claudeCode
    }

    static func snapshot(
        _ host: AgentHostAgentSessionSnapshotV1?,
        summary: AgentHostSessionSummaryV1?,
        tabID: UUID,
        sessionID: UUID
    ) -> AgentSessionSnapshot {
        let summary = host?.summary ?? summary
        let pending = host?.pendingInteractions.first ?? summary?.interaction
        return AgentSessionSnapshot(
            tabID: tabID,
            sessionID: sessionID,
            provider: provider(id: summary?.providerId ?? ""),
            modelRaw: summary?.modelId ?? "",
            runState: runState(summary?.status ?? .unspecified, pending: pending),
            runID: UUID(uuidString: summary?.activeRunId ?? ""),
            providerSessionID: summary.flatMap { $0.providerSessionId.isEmpty ? nil : $0.providerSessionId },
            items: (host?.transcript ?? []).enumerated().compactMap { index, entry in
                chatItem(entry, sequence: index)
            },
            pendingInteraction: pending.flatMap(pendingInteraction)
        )
    }

    static func chatItem(_ entry: AgentHostTranscriptEntryV1, sequence: Int) -> AgentChatItem? {
        let kind: AgentChatItemKind
        switch entry.role {
        case .user: kind = .user
        case .assistant: kind = .assistant
        case .tool: kind = entry.toolResultJson.isEmpty ? .toolCall : .toolResult
        case .system: kind = .system
        case .unspecified: return nil
        }
        return AgentChatItem(
            id: UUID(uuidString: entry.entryId) ?? UUID(),
            timestamp: AgentSessionHostClock.date(rfc3339: entry.createdAt) ?? Date(),
            kind: kind,
            text: entry.text,
            toolName: entry.toolName.isEmpty ? nil : entry.toolName,
            toolInvocationID: UUID(uuidString: entry.toolInvocationId),
            toolArgsJSON: entry.toolArgsJson.isEmpty ? nil : entry.toolArgsJson,
            toolResultJSON: entry.toolResultJson.isEmpty ? nil : entry.toolResultJson,
            toolIsError: entry.toolName.isEmpty ? nil : entry.toolIsError,
            reasoning: entry.reasoning.isEmpty ? nil : entry.reasoning,
            sequenceIndex: sequence
        )
    }

    static func pendingInteraction(_ pending: AgentHostPendingInteractionV1) -> AgentSessionSnapshot.PendingInteraction? {
        guard let id = UUID(uuidString: pending.interactionId) else { return nil }
        switch pending.kind {
        case .approval, .hookApproval: return .approval(id)
        case .question, .instruction, .unspecified: return .askUser(id)
        case .userInput: return .userInput(id)
        case .mcpElicitation: return .mcpElicitation(id)
        }
    }

    static func userMessage(_ message: AgentSessionUserMessage) -> AgentHostUserMessageV1 {
        AgentHostUserMessageV1(
            messageId: message.messageID.uuidString.lowercased(),
            text: message.text,
            attachments: [],
            createdAt: AgentSessionHostClock.rfc3339()
        )
    }

    static func sessionSpec(_ spec: AgentSessionStartSpec, sessionID: UUID) -> AgentHostSessionSpecV1 {
        let provider = spec.provider ?? .claudeCode
        return AgentHostSessionSpecV1(
            sessionId: sessionID.uuidString.lowercased(),
            workspaceId: spec.workspaceID?.uuidString.lowercased() ?? "unspecified",
            worktreeId: spec.worktreeID ?? "",
            sessionName: spec.sessionName ?? "",
            providerId: provider.rawValue,
            agentId: provider.rawValue,
            agentDisplayName: provider.displayName,
            modelId: spec.modelRaw ?? "",
            reasoningEffort: "",
            parentSessionId: "",
            parentForkCursor: 0,
            initialMessage: userMessage(spec.message),
            permissionPolicy: nil,
            credentialEnvelopeId: spec.credentialEnvelopeID ?? "",
            resumeProviderSessionId: spec.resumeProviderSessionID ?? ""
        )
    }

    static func stopReason(_ reason: AgentSessionStopReason) -> AgentHostStopReasonV1 {
        switch reason {
        case .userRequested: .userRequested
        case .workspaceClosing: .workspaceClosing
        case .executionLocationChange: .executionLocationChange
        case .hostPolicy: .hostPolicy
        }
    }

    static func interruptOutcome(_ value: AgentHostInterruptOutcomeV1) -> AgentSessionInterruptOutcome {
        switch value {
        case .acknowledged: .acknowledged
        case .noTurnInFlight: .noTurnInFlight
        case .staleGeneration: .staleGeneration
        case .timedOut: .timedOut
        case .failed, .unspecified: .failed
        }
    }

    static func respondDisposition(_ value: AgentHostInteractionResponseDispositionV1) -> AgentInteractionResponseDisposition {
        switch value {
        case .accepted: .accepted
        case .superseded: .superseded
        case .staleGeneration: .staleGeneration
        case .unknownInteraction: .unknownInteraction
        case .expired, .unspecified: .expired
        }
    }

    static func stopStatus(_ status: AgentHostSessionStatusV1) -> AgentSessionRunState {
        runState(status, pending: nil)
    }

    static func interactionAnswer(_ answer: AgentInteractionAnswer) -> AgentHostInteractionAnswerV1 {
        switch answer {
        case let .approval(decision), let .permissions(decision):
            return AgentHostInteractionAnswerV1(skipped: false, answer: .approval(approvalDecision(decision)))
        case .skipAskUser:
            return AgentHostInteractionAnswerV1(skipped: true, answer: nil)
        case let .askUser(drafts):
            let text = drafts.values.map { draft in
                (draft.selectedOptionLabels + [draft.customResponse]).filter { !$0.isEmpty }.joined(separator: "\n")
            }.joined(separator: "\n")
            return AgentHostInteractionAnswerV1(skipped: drafts.values.contains(where: \.skipped), answer: .text(.init(text: text)))
        case let .userInput(response):
            let text = response.answersByQuestionID.values.flatMap(\.self).joined(separator: "\n")
            return AgentHostInteractionAnswerV1(skipped: false, answer: .text(.init(text: text)))
        case let .mcpElicitation(response):
            let action: AgentHostElicitationActionV1 = switch response.action {
            case .accept: .accept
            case .decline: .decline
            case .cancel: .cancel
            }
            let content = (try? JSONSerialization.data(withJSONObject: response.jsonObject["content"] as Any))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let meta = (try? JSONSerialization.data(withJSONObject: response.jsonObject["_meta"] as Any))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return AgentHostInteractionAnswerV1(
                skipped: response.action != .accept,
                answer: .elicitation(AgentHostElicitationAnswerV1(action: action, contentJson: content, metaJson: meta))
            )
        case let .codexHookReview(decision):
            return AgentHostInteractionAnswerV1(skipped: false, answer: .text(.init(text: String(describing: decision))))
        }
    }

    static func approvalDecision(_ decision: AgentApprovalDecision) -> AgentHostApprovalDecisionV1 {
        switch decision {
        case .accept:
            AgentHostApprovalDecisionV1(kind: .accept, execpolicyAmendmentJson: "")
        case .acceptForSession:
            AgentHostApprovalDecisionV1(kind: .acceptForSession, execpolicyAmendmentJson: "")
        case let .acceptWithExecpolicyAmendment(json):
            AgentHostApprovalDecisionV1(kind: .acceptWithExecpolicyAmendment, execpolicyAmendmentJson: json)
        case .decline:
            AgentHostApprovalDecisionV1(kind: .decline, execpolicyAmendmentJson: "")
        case .cancel:
            AgentHostApprovalDecisionV1(kind: .cancel, execpolicyAmendmentJson: "")
        }
    }

    static func rejection(_ rejected: AgentHostCommandRejectedV1, operationID: UUID) -> AgentSessionConnectionError {
        switch rejected.reason {
        case .unknownSession:
            if let sessionID = UUID(uuidString: rejected.detail) {
                return .sessionNotFound(sessionID)
            }
            return .commandRejected(rejected.detail.isEmpty ? "unknown session" : rejected.detail)
        default:
            return .commandRejected(rejected.detail.isEmpty ? String(describing: rejected.reason) : rejected.detail)
        }
    }

    static func startResult(
        _ started: AgentHostSessionStartedV1,
        tabID _: UUID
    ) throws -> AgentSessionStartResult {
        guard let sessionID = UUID(uuidString: started.sessionId) else {
            throw AgentSessionConnectionError.commandRejected("host returned a non-UUID session id")
        }
        return AgentSessionStartResult(
            sessionID: sessionID,
            sendOutcome: sendOutcome(from: started.summary),
            cursor: cursor(generation: started.generation, delivery: started.nextCursor)
        )
    }

    static func steerResult(_ steered: AgentHostSteeredV1, generation: Data) throws -> AgentSessionSteerResult {
        guard let sessionID = UUID(uuidString: steered.sessionId) else {
            throw AgentSessionConnectionError.commandRejected("host returned a non-UUID session id")
        }
        let messageID = UUID(uuidString: steered.messageId) ?? UUID()
        return AgentSessionSteerResult(
            sessionID: sessionID,
            messageID: messageID,
            sendOutcome: .accepted,
            recordedCursor: cursor(generation: generation, delivery: steered.recordedCursor)
        )
    }

    static func interruptResult(_ interrupted: AgentHostInterruptResultV1) throws -> AgentSessionInterruptResult {
        guard let sessionID = UUID(uuidString: interrupted.sessionId) else {
            throw AgentSessionConnectionError.commandRejected("host returned a non-UUID session id")
        }
        return AgentSessionInterruptResult(
            sessionID: sessionID,
            outcome: interruptOutcome(interrupted.outcome),
            detail: interrupted.detail.isEmpty ? nil : interrupted.detail
        )
    }

    static func respondResult(_ responded: AgentHostInteractionRespondedV1) throws -> AgentSessionRespondResult {
        guard let sessionID = UUID(uuidString: responded.sessionId),
              let interactionID = UUID(uuidString: responded.interactionId)
        else {
            throw AgentSessionConnectionError.commandRejected("host returned a non-UUID interaction id")
        }
        return AgentSessionRespondResult(
            sessionID: sessionID,
            interactionID: interactionID,
            disposition: respondDisposition(responded.disposition)
        )
    }

    static func stopResult(_ stopped: AgentHostStoppedV1) throws -> AgentSessionStopResult {
        guard let sessionID = UUID(uuidString: stopped.sessionId) else {
            throw AgentSessionConnectionError.commandRejected("host returned a non-UUID session id")
        }
        return AgentSessionStopResult(sessionID: sessionID, status: stopStatus(stopped.status))
    }

    static func commandOutcome(
        _ settlement: AgentHostCommandSettledSettlementV1?,
        generation: Data,
        operationID: UUID
    ) -> AgentSessionCommandOutcome {
        switch settlement {
        case let .result(result):
            switch result.result {
            case let .started(started):
                if let mapped = try? startResult(started, tabID: UUID()) { return .started(mapped) }
            case let .steered(steered):
                if let mapped = try? steerResult(steered, generation: generation) { return .steered(mapped) }
            case let .interrupted(interrupted):
                if let mapped = try? interruptResult(interrupted) { return .interrupted(mapped) }
            case let .interactionResponded(responded):
                if let mapped = try? respondResult(responded) { return .interactionResponded(mapped) }
            case let .stopped(stopped):
                if let mapped = try? stopResult(stopped) { return .stopped(mapped) }
            default:
                break
            }
            return .rejected(.commandRejected("unmapped command settlement"))
        case let .rejected(rejected):
            return .rejected(rejection(rejected, operationID: operationID))
        case nil:
            return .rejected(.commandRejected("empty command settlement"))
        }
    }

    static func runtimeEvent(_ event: AgentHostRuntimeEventV1) -> NativeAgentRuntimeEvent? {
        switch event.kind {
        case let .stream(stream):
            return .stream(AIStreamResult(
                type: stream.itemType,
                text: stream.text,
                reasoning: stream.reasoning,
                promptTokens: stream.promptTokens.map(Int.init),
                completionTokens: stream.completionTokens.map(Int.init),
                cost: stream.cost,
                toolName: stream.toolName,
                toolArgs: stream.toolArgs,
                toolOutput: stream.toolOutput,
                toolInvocationID: stream.toolInvocationId.flatMap(UUID.init(uuidString:)),
                toolResultJSON: stream.toolResultJson,
                toolArgsJSON: stream.toolArgsJson,
                toolIsError: stream.toolIsError,
                providerSessionID: stream.providerSessionId,
                stopReason: stream.stopReason,
                modelContextWindow: stream.modelContextWindow.map(Int.init),
                contextUsedTokens: stream.contextUsedTokens.map(Int.init),
                contentMessageID: stream.contentMessageId
            ))
        case let .runtimeInit(status):
            return .runtimeInit(NativeAgentRuntimeRuntimeInitStatus(
                sessionID: status.providerSessionId.isEmpty ? nil : status.providerSessionId,
                tools: status.tools,
                mcpServerStatuses: Dictionary(uniqueKeysWithValues: status.mcpServerStatuses.map { ($0.key, $0.value) }),
                initializeResponse: nil
            ))
        case let .error(error):
            return .error(error.message)
        case let .turnCompleted(completed):
            let status: NativeAgentRuntimeTurnStatus = switch completed.stopReason {
            case "cancelled", "interrupt": .cancelled
            case "error", "failed": .failed
            default: .completed
            }
            return .turnCompleted(turnID: UUID(uuidString: completed.turnId) ?? UUID(), status: status)
        case let .approvalCancelled(cancelled):
            return .approvalCancelled(requestID: cancelled.approvalId)
        case .approvalRequest, nil:
            return nil
        }
    }

    static func terminalOutcome(_ terminated: AgentHostRunTerminatedV1) -> DomainAgentRunTerminalOutcome {
        let text = terminated.outcome?.assistantText
        switch terminated.outcome?.kind {
        case .completed: return .completed(assistantText: text)
        case .cancelled: return .cancelled(assistantText: text)
        case .failed, .unspecified, nil: return .failedWithoutClassification(assistantText: text)
        }
    }
}
