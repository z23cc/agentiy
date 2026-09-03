import Foundation
import RepoPromptDomainRuntime

@MainActor
final class ClaudeIntegratedAgentModeRunner {
    private enum ConsumeEventsOutcome {
        case completed
        case cancelled
        case failed(
            errorText: String?,
            shouldShutdownSession: Bool,
            signal: DomainAgentRunProviderTerminationSignal
        )
    }

    private let claudeCoordinator: ClaudeAgentModeCoordinator
    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier
    /// Fire-and-forget mirror of every consumed native runtime event for the seam (P1.5).
    var runtimeEventObserver: (@MainActor (NativeAgentRuntimeEvent, AgentTabSession) -> Void)?

    #if DEBUG
        private func reasoningDebug(_ message: @autoclosure () -> String) {
            guard ClaudeReasoningExtractionFeature.isEnabled else { return }
            let line = "[ClaudeReasoningDebug][Runner] \(message())"
            print(line)
            ClaudeReasoningDebugLog.append(line)
        }
    #else
        private func reasoningDebug(_ message: @autoclosure () -> String) {}
    #endif

    private func reasoningDebugSnippet(_ text: String, limit: Int = 160) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit)
            .description
    }

    init(
        claudeCoordinator: ClaudeAgentModeCoordinator,
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier
    ) {
        self.claudeCoordinator = claudeCoordinator
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        makeLease: (_ runID: UUID) -> MCPBootstrapLease
    ) async {
        let attachmentReservationID = hooks.attachments.reserveAttachmentsForTurn(attachments, session)

        if initialMessageForRun != initialUserMessage,
           !session.pendingNonCodexUserInputTokenQueue.isEmpty
        {
            session.pendingNonCodexUserInputTokenQueue[0] = hooks.usage.estimateRuntimeTokens(initialMessageForRun)
        }
        hooks.usage.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()

        let runID = session.inProcessExecution.claudeController.flatMap { _ in
            AgentModeProcessRunIdentity.existingProcessRunID(for: session)
        } ?? AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        let lease = makeLease(runID)
        let ownership = session.beginRunAttempt(source: "claudeNative")
        session.installRunAttemptTerminalResources(ownership: ownership) { terminalState in
            {
                switch terminalState {
                case .failed:
                    await lease.failAndRelease()
                case .cancelled:
                    await lease.cancelAndCleanup()
                default:
                    break
                }
            }
        }
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.claudeExpectedTurnIDs.removeAll()
        hooks.presentation.setAgentRunActive(session, true)
        hooks.bindingObservation.updateBindings(session)

        session.agentTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            await withTaskCancellationHandler {
                let acquired = await lease.acquire()
                guard acquired else {
                    await self.handleAcquireFailure(
                        tabID: tabID,
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID
                    )
                    return
                }

                await self.claudeCoordinator.ensureClaudeToolTrackingIfNeeded(
                    for: session,
                    runID: runID
                )

                let providerName = session.selectedAgent.rawValue
                var didSendToProvider = false
                var nativeFailureMetadata: (errorText: String?, shouldShutdownSession: Bool)?
                let report = await DomainAgentRunExecutionCore.executeProvider(
                    failureText: { _ in nativeFailureMetadata?.errorText ?? "" }
                ) {
                    await lease.providerInitializationStarted(provider: providerName)
                    let sendOutcome = await self.claudeCoordinator.sendClaudeNativeMessage(
                        session: session,
                        text: initialMessageForRun,
                        attachments: attachments,
                        intent: .runAttempt(ownership: ownership, runID: runID)
                    )
                    let providerInitializationOutcome = switch sendOutcome {
                    case .sent:
                        "ready"
                    case .failed:
                        Task.isCancelled ? "cancelled" : "failed"
                    case .superseded:
                        "superseded"
                    }
                    await lease.providerInitializationCompleted(
                        provider: providerName,
                        outcome: providerInitializationOutcome
                    )

                    switch sendOutcome {
                    case .sent:
                        didSendToProvider = true
                        self.hooks.providerInput.recordPendingHandoffSendOutcome(session, true)
                    case .failed:
                        nativeFailureMetadata = (errorText: nil, shouldShutdownSession: false)
                        return .failed(signal: .startupFailure(assistantText: nil))
                    case .superseded:
                        return .superseded
                    }

                    self.hooks.attachments.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
                    self.hooks.attachments.markAttachmentsConsumed(session, attachmentReservationID)
                    _ = await lease.releaseWhenRouted()

                    guard let events = await self.claudeCoordinator.events(for: session) else {
                        nativeFailureMetadata = (
                            errorText: "Claude native events stream not available.",
                            shouldShutdownSession: false
                        )
                        return .failed(signal: .startupFailure(
                            assistantText: "Claude native events stream not available."
                        ))
                    }

                    session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
                    switch await self.consumeEvents(
                        events,
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID
                    ) {
                    case .completed:
                        return .completed(assistantText: nil)
                    case .cancelled:
                        return .cancelled(assistantText: nil)
                    case let .failed(errorText, shouldShutdownSession, signal):
                        nativeFailureMetadata = (errorText, shouldShutdownSession)
                        return .failed(signal: signal)
                    }
                }

                switch report.result {
                case .superseded:
                    if self.claudeCoordinator.runAttemptIsCurrent(
                        ownership,
                        runID: runID,
                        for: session
                    ) {
                        self.hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
                        let revision = await self.finalize(
                            session: session,
                            runID: runID,
                            ownership: ownership,
                            attachmentReservationID: attachmentReservationID,
                            outcome: .cancelled(),
                            errorText: nil,
                            notifyTurnComplete: false
                        )
                        if revision == nil {
                            await lease.cancelAndCleanup()
                        }
                    } else {
                        await lease.cancelAndCleanup()
                    }
                case let .terminal(outcome):
                    if !didSendToProvider {
                        self.hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
                    }
                    await self.finalize(
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID,
                        outcome: outcome,
                        errorText: outcome.kind == .failed ? nativeFailureMetadata?.errorText : nil,
                        notifyTurnComplete: outcome.kind == .completed,
                        shouldShutdownSession: outcome.kind == .failed
                            && nativeFailureMetadata?.shouldShutdownSession == true
                    )
                }
            } onCancel: {}
        }
    }

    private func consumeEvents(
        _ events: AsyncStream<NativeAgentRuntimeEvent>,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        var exitedDueToAttemptMismatch = false

        eventLoop: for await event in events {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                exitedDueToAttemptMismatch = true
                break eventLoop
            }

            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
            }
            runtimeEventObserver?(event, session)

            switch event {
            case let .stream(result):
                #if DEBUG
                    if ClaudeReasoningExtractionFeature.isEnabled, result.type == "reasoning" {
                        let text = result.reasoning ?? result.text ?? ""
                        reasoningDebug("stream reasoning run=\(runID.uuidString) attempt=\(runAttemptID.uuidString) tab=\(session.tabID.uuidString) len=\(text.count) snippet=\(reasoningDebugSnippet(text))")
                    }
                #endif
                await hooks.transcript.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            case let .runtimeInit(status):
                // Persist provider session ID as soon as it becomes available from
                // runtime init events (initialize response or system/init stream).
                if let newSessionID = status.sessionID,
                   !newSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   newSessionID != session.providerSessionID
                {
                    session.providerSessionID = newSessionID
                    session.providerCleanupHandle = ProviderConversationCleanupHandle.resolved(
                        provider: session.selectedAgent.rawValue,
                        explicit: nil,
                        providerSessionID: newSessionID,
                        codexConversationID: session.codexConversationID,
                        codexRolloutPath: session.codexRolloutPath
                    )
                    session.isDirty = true
                    hooks.persistence.scheduleSave(session)
                }
                if status.isRepoPromptServerFailed {
                    return .failed(
                        errorText: "RepoPrompt MCP failed to initialize for Claude (session \(status.sessionID ?? "unknown")).",
                        shouldShutdownSession: true,
                        signal: .startupFailure(
                            assistantText: "RepoPrompt MCP failed to initialize for Claude (session \(status.sessionID ?? "unknown"))."
                        )
                    )
                }
            case let .approvalRequest(request):
                if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                    session.recordRunProgress(ownership: ownership, kind: .interaction, stage: .waitingForInteraction)
                }
                session.pendingApproval = request
                session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                session.setRunningStatus(nil, source: nil)
                session.runState = .waitingForApproval
                hooks.bindingObservation.updateBindings(session)
            case let .approvalCancelled(requestID):
                if session.pendingApproval?.requestID == .claudeControl(requestID) {
                    session.pendingApproval = nil
                    if session.runState == .waitingForApproval {
                        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                        session.setRunningStatus("Thinking…", source: .transport)
                        session.runState = .running
                    }
                    hooks.bindingObservation.updateBindings(session)
                }
            case let .turnCompleted(turnID, turnStatus):
                guard session.claudeExpectedTurnIDs.contains(turnID) else {
                    // Stale completion from a previous cancelled run attempt; ignore.
                    continue eventLoop
                }
                session.claudeExpectedTurnIDs.remove(turnID)

                let wasProtectedClaudeTurn = session.claudeSupersedingProtectedTurnIDs.remove(turnID) != nil
                let hasLegacyUnscopedProtection = session.claudeSupersedingProtectedTurnIDs.isEmpty
                    && session.pendingSupersedingTurnCompletions > 0
                if wasProtectedClaudeTurn || hasLegacyUnscopedProtection {
                    session.pendingSupersedingTurnCompletions = max(0, session.pendingSupersedingTurnCompletions - 1)
                    // Keep run alive for the next (superseding) turn regardless of the
                    // stale turn's reported terminal status. Old interrupted turns can land
                    // as .cancelled, .failed, or even .completed after the superseding send
                    // is already in flight.
                    if !session.runState.isActive {
                        session.runState = .running
                    }
                    hooks.presentation.setAgentRunActive(session, true)
                    hooks.bindingObservation.updateBindings(session)
                    continue eventLoop
                }
                // No superseding turn expected — terminal for this run.
                session.pendingSupersedingTurnCompletions = 0
                session.claudeSupersedingProtectedTurnIDs.removeAll()
                switch turnStatus {
                case .completed:
                    return .completed
                case .cancelled:
                    return .cancelled
                case .failed:
                    return .failed(
                        errorText: nil,
                        shouldShutdownSession: false,
                        signal: .providerFailure(assistantText: nil, reason: nil)
                    )
                }
            case let .error(message):
                session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                session.setRunningStatus(nil, source: nil)
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    #if !DEBUG
                        // Suppress known non-actionable abort side-effect errors (e.g. JSON parse
                        // errors from killed tool processes) in release builds.
                        if Self.isKnownNonActionableStreamError(trimmed) { continue eventLoop }
                    #endif
                    let errorItem = AgentChatItem.error(trimmed, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(errorItem)
                    hooks.bindingObservation.updateBindings(session)
                    hooks.persistence.scheduleSave(session)
                }
            }
        }

        // If we exited because the attempt changed (cancel / new attempt)
        // or the task was cancelled, this is expected — not a stream failure.
        if exitedDueToAttemptMismatch || Task.isCancelled {
            return .cancelled
        }

        // The events stream ended without a terminal turnCompleted event while this
        // attempt was still active.  This means the stream was finished or the Claude
        // process exited unexpectedly.
        let message = "Claude events stream ended unexpectedly. The run may need to be restarted."
        return .failed(
            errorText: message,
            shouldShutdownSession: false,
            signal: .unexpectedEnd(assistantText: message)
        )
    }

    private func handleAcquireFailure(
        tabID _: UUID,
        session: AgentTabSession,
        runID: UUID,
        ownership: AgentRunOwnership,
        attachmentReservationID: UUID?
    ) async {
        hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            outcome: .cancelled(),
            source: "claudeNative.acquireFailure",
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: true,
            notifyTurnComplete: false
        ))
    }

    @discardableResult
    private func finalize(
        session: AgentTabSession,
        runID: UUID,
        ownership: AgentRunOwnership,
        attachmentReservationID: UUID?,
        outcome: DomainAgentRunTerminalOutcome,
        errorText: String?,
        notifyTurnComplete: Bool,
        shouldShutdownSession: Bool = false
    ) async -> AgentRunTerminalCommitRevision? {
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            outcome: outcome,
            source: "claudeNative.finalize",
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: true,
            notifyTurnComplete: notifyTurnComplete,
            prepareProviderState: { [claudeCoordinator] in
                session.pendingSupersedingTurnCompletions = 0
                session.claudeSupersedingProtectedTurnIDs.removeAll()
                session.claudeExpectedTurnIDs.removeAll()
                guard shouldShutdownSession else { return nil }
                let oldController = claudeCoordinator.prepareClaudeCancelSync(session)
                return {
                    claudeCoordinator.beginClaudeResumeTransferIfNeeded(
                        for: session,
                        oldController: oldController
                    )
                    await claudeCoordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                }
            }
        ))
    }

    // MARK: - Error Filtering

    /// Returns `true` when the error message is a known non-actionable abort side
    /// effect (e.g. JSON parse errors from killed tool processes, MCP AbortErrors).
    /// These are suppressed in release builds to avoid alarming users.
    private static func isKnownNonActionableStreamError(_ message: String) -> Bool {
        ClaudeAbortArtifactFilter.shouldSuppressUserFacingError(message)
    }
}
