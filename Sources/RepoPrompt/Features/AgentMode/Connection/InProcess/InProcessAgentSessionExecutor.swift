import Foundation
import RepoPromptDomainRuntime

/// What the executor hands back for `start`: the session the run is bound to and the
/// provider send outcome. The connection adds the settlement cursor.
struct InProcessAgentSessionStartOutcome: Equatable {
    let sessionID: UUID
    let sendOutcome: AgentSessionSendOutcome
}

/// Main-actor execution entry points that `InProcessAgentSessionConnection` drives.
///
/// The in-process stack (run service, provider coordinators, persistence writer) is still
/// hosted next to `AgentModeViewModel` in P1; this protocol is the narrow surface the
/// connection needs from it, and the seam tests substitute a fake for it. P3 replaces the
/// production conformer with the host process and deletes this protocol.
@MainActor
protocol InProcessAgentSessionExecuting: AnyObject {
    /// Presentation cache for a tab, or `nil` when the tab is not open.
    func session(forTab tabID: UUID) -> AgentTabSession?
    /// Presentation cache uniquely bound to a persistent session. Throws when the binding
    /// is ambiguous.
    func session(forSessionID sessionID: UUID) throws -> AgentTabSession?
    /// Starts a run. Throws `commandRejected` when the run could not be bound to a session;
    /// provider-level refusals are reported through the returned `sendOutcome`.
    func startRun(_ spec: AgentSessionStartSpec) async throws -> InProcessAgentSessionStartOutcome
    func steer(session: AgentTabSession, message: AgentSessionUserMessage) async throws -> AgentSessionSendOutcome
    func interrupt(session: AgentTabSession, reason: AgentSessionInterruptReason) async -> AgentSessionInterruptOutcome
    func respond(session: AgentTabSession, interactionID: UUID, answer: AgentInteractionAnswer) async throws -> AgentInteractionResponseDisposition
    /// Cancels any run and releases every provider handle. The persisted session survives.
    /// Returns the run state after the stop settled.
    func stop(session: AgentTabSession, reason: AgentSessionStopReason) async -> AgentSessionRunState
    func snapshot(of session: AgentTabSession) -> AgentSessionSnapshot
}

/// The Codex fallback-queue submission context is the one execution-side value the client
/// threads back through `start` today (design §6: execution owns durable queueing).
extension AgentTabSession.CodexFallbackSubmissionContext: AgentSessionStartExecutionContext {}

/// Production executor: the execution side of the in-process seam.
///
/// Only the composition root constructs this (`WindowStateComposition`). It holds the
/// view model weakly; the view model owns the connection, which owns this executor. The
/// view model is attached after construction because it needs the connection to exist
/// first. The run service and provider coordinators are still instantiated by the view
/// model (they are wired with its presentation hooks), but every command that changes
/// agent execution or durable session state enters them from here, not from the view
/// model.
@MainActor
final class InProcessAgentSessionExecutor: InProcessAgentSessionExecuting {
    private weak var viewModel: AgentModeViewModel?
    private weak var connection: InProcessAgentSessionConnection?

    init() {}

    /// Wires the executor to the view-model-hosted stack and starts mirroring execution
    /// events (Claude native runtime events, terminal commits) onto the connection.
    func attach(viewModel: AgentModeViewModel, connection: InProcessAgentSessionConnection? = nil) {
        self.viewModel = viewModel
        self.connection = connection
        guard connection != nil else { return }
        // The run service is created lazily by the view model; it installs this observer
        // when it is built so construction timing stays exactly as before.
        viewModel.executionEventObserver = self
    }

    func session(forTab tabID: UUID) -> AgentTabSession? {
        viewModel?.sessions[tabID]
    }

    func session(forSessionID sessionID: UUID) throws -> AgentTabSession? {
        try viewModel?.authoritativeLiveSession(for: sessionID)
    }

    // MARK: - start

    func startRun(_ spec: AgentSessionStartSpec) async throws -> InProcessAgentSessionStartOutcome {
        guard let viewModel else { throw AgentSessionConnectionError.executorUnavailable }
        let session = viewModel.session(for: spec.tabID)
        if let resumeSessionID = spec.resumeSessionID, session.activeAgentSessionID != resumeSessionID {
            // Rebinding a tab to another persisted session is a presentation-side navigation
            // today (sidebar selection); the in-process executor does not perform it.
            throw AgentSessionConnectionError.commandRejected(
                "Tab \(spec.tabID.uuidString) is not bound to session \(resumeSessionID.uuidString)."
            )
        }
        guard viewModel.isAgentAvailableForRunStart(session.selectedAgent) else {
            if session.mcpFollowUpRunPending {
                session.mcpFollowUpRunPending = false
                viewModel.handleObservedMCPStateChange(for: session)
            }
            throw AgentSessionConnectionError.commandRejected(viewModel.unavailableAgentMessage(for: session.selectedAgent))
        }
        defer {
            if session.mcpFollowUpRunPending {
                session.mcpFollowUpRunPending = false
                viewModel.handleObservedMCPStateChange(for: session)
            }
        }
        guard let sessionID = viewModel.ensureSessionBoundToTab(session) else {
            throw AgentSessionConnectionError.commandRejected("The tab could not be bound to an agent session.")
        }
        await viewModel.prepareSessionForRunStart(tabID: spec.tabID, session: session)
        await viewModel.prepareMCPWaitTrackingForRunStart(session: session)
        let augmentedInitialMessage = await viewModel.augmentUserMessageForProviderSend(
            spec.message.text,
            attachments: spec.message.attachments,
            taggedFileAttachments: spec.message.taggedFileAttachments,
            agent: session.selectedAgent,
            session: session
        )

        let initialMessageForRun = await viewModel.buildInitialThreadMessageIfNeeded(
            tabID: spec.tabID,
            session: session,
            initialMessage: augmentedInitialMessage
        )
        let codexFallbackContext = spec.executionContext as? AgentTabSession.CodexFallbackSubmissionContext
        let preparedCodexFallbackContext = codexFallbackContext.map { context in
            AgentTabSession.CodexFallbackSubmissionContext(
                queueID: context.queueID,
                providerText: initialMessageForRun,
                images: context.images,
                taggedFileAttachments: context.taggedFileAttachments,
                draftText: context.draftText,
                optimisticUserItemID: context.optimisticUserItemID,
                origin: context.origin,
                dispatchTicket: context.dispatchTicket
            )
        }

        let nativeOutcome = await viewModel.runService.startRun(
            tabID: spec.tabID,
            session: session,
            initialUserMessage: augmentedInitialMessage,
            initialMessageForRun: initialMessageForRun,
            attachments: spec.message.attachments,
            codexFallbackContext: preparedCodexFallbackContext
        )
        return InProcessAgentSessionStartOutcome(
            sessionID: session.activeAgentSessionID ?? sessionID,
            sendOutcome: Self.sendOutcome(from: nativeOutcome)
        )
    }

    /// Lossless mapping of the Codex coordinator's native send outcome onto the seam
    /// vocabulary. `nil` (providers without a synchronous acknowledgement) is `.accepted`.
    static func sendOutcome(from outcome: CodexAgentModeCoordinator.NativeSendOutcome?) -> AgentSessionSendOutcome {
        switch outcome {
        case nil:
            .accepted
        case .sent?:
            .sent
        case let .queuedFallback(queueID, _)?:
            .queuedForNextTurn(queueID: queueID)
        case let .preDispatchRejected(message)?:
            .rejectedBeforeDispatch(reason: message)
        case let .stale(reason)?:
            .staleTarget(reason: reason)
        case .cancelled?:
            .cancelled
        case let .failed(message)?:
            .failed(reason: message)
        }
    }

    // MARK: - steer

    func steer(session: AgentTabSession, message: AgentSessionUserMessage) async throws -> AgentSessionSendOutcome {
        guard let viewModel else { throw AgentSessionConnectionError.executorUnavailable }
        if !message.attachments.isEmpty {
            session.pendingImageAttachments.append(contentsOf: message.attachments)
        }
        if !message.taggedFileAttachments.isEmpty {
            session.pendingTaggedFileAttachments.append(contentsOf: message.taggedFileAttachments)
        }
        switch viewModel.submitUserTurn(
            text: message.text,
            tabID: session.tabID,
            codexAttemptID: message.codexAttemptID
        ) {
        case .submitted:
            return .accepted
        case let .blocked(reason):
            throw AgentSessionConnectionError.commandRejected(reason)
        }
    }

    // MARK: - interrupt

    func interrupt(session: AgentTabSession, reason: AgentSessionInterruptReason) async -> AgentSessionInterruptOutcome {
        guard let viewModel else { return .failed }
        let hadTurnInFlight = session.runState.isActive
        viewModel.cancelPendingInstruction(for: session)
        let (intent, completion) = Self.cancellation(for: reason)
        await viewModel.runService.cancelRun(
            tabID: session.tabID,
            session: session,
            intent: intent,
            completion: completion
        )
        return hadTurnInFlight ? .acknowledged : .noTurnInFlight
    }

    /// Maps a seam interrupt reason onto the wrapped stack's cancellation intent and
    /// settlement point (see `AgentSessionInterruptReason` documentation).
    static func cancellation(
        for reason: AgentSessionInterruptReason
    ) -> (intent: DomainAgentRunCancellationIntent, completion: DomainAgentRunCancellationCompletion) {
        switch reason {
        case .userRequested, .supersededBySteer:
            (.userStop, .terminalPublished)
        case .executionLocationChange:
            (.executionLocationChange, .terminalPublished)
        case .runtimeShutdown:
            (.runtimeShutdown, .terminalTeardownCompleted)
        case .clientTeardown:
            (.userStop, .terminalTeardownCompleted)
        }
    }

    // MARK: - respond

    func respond(session: AgentTabSession, interactionID: UUID, answer: AgentInteractionAnswer) async throws -> AgentInteractionResponseDisposition {
        guard let viewModel else { throw AgentSessionConnectionError.executorUnavailable }
        switch answer {
        case let .approval(decision):
            guard let request = session.pendingApproval, request.id == interactionID else {
                throw AgentSessionConnectionError.interactionNotPending(interactionID)
            }
            switch request.requestID {
            case .codex:
                viewModel.codexCoordinator.submitApprovalDecision(session: session, decision: decision)
            case .claudeControl:
                viewModel.claudeCoordinator.submitApprovalDecision(session: session, decision: decision)
            case let .acp(requestID):
                session.pendingApproval = nil
                if session.runState == .waitingForApproval {
                    session.runState = .running
                }
                viewModel.requestUIRefresh(tabID: session.tabID, urgent: true)
                session.respondToACPPermissionRequest(id: requestID, decision: decision)
            }
        case let .askUser(draftsByQuestionID):
            try viewModel.applyAskUserResponse(
                tabID: session.tabID,
                interactionID: interactionID,
                draftsByQuestionID: draftsByQuestionID
            )
        case .skipAskUser:
            try viewModel.applyAskUserResponse(
                tabID: session.tabID,
                interactionID: interactionID,
                skipAll: true
            )
        case let .userInput(response):
            guard let request = session.pendingUserInputRequest, request.id == interactionID else {
                throw AgentSessionConnectionError.interactionNotPending(interactionID)
            }
            viewModel.applyUserInputResponse(tabID: session.tabID, requestID: request.requestID, response: response)
        case let .permissions(decision):
            guard let request = session.pendingPermissionsRequest, request.id == interactionID else {
                throw AgentSessionConnectionError.interactionNotPending(interactionID)
            }
            viewModel.codexCoordinator.submitPermissionsDecision(session: session, request: request, decision: decision)
        case let .mcpElicitation(response):
            guard let request = session.pendingMCPElicitationRequest, request.id == interactionID else {
                throw AgentSessionConnectionError.interactionNotPending(interactionID)
            }
            viewModel.codexCoordinator.submitMCPElicitationResponse(session: session, request: request, response: response)
        case let .codexHookReview(decision):
            guard let currentRequest = session.pendingCodexHookReview else {
                throw AgentCodexHookReviewResolutionError.noPendingReview
            }
            guard currentRequest.id == interactionID else {
                throw AgentCodexHookReviewResolutionError.staleRequest(currentID: currentRequest.id)
            }
            try await viewModel.codexCoordinator.resolveCodexHookReview(
                session: session,
                requestID: interactionID,
                decision: decision
            )
        }
        return .accepted
    }

    // MARK: - stop

    func stop(session: AgentTabSession, reason _: AgentSessionStopReason) async -> AgentSessionRunState {
        guard let viewModel else { return session.runState }
        if session.runState.isActive {
            viewModel.cancelPendingInstruction(for: session)
            await viewModel.runService.cancelRun(tabID: session.tabID, session: session)
        }
        // Release retained ACP runtimes before the controller handle can become unreachable.
        await session.teardownACPControllerIfPresent()
        await session.disposeProviderIfPresent()
        await viewModel.codexCoordinator.shutdownCodexSession(session)
        await viewModel.claudeCoordinator.shutdownClaudeSession(session)
        return session.runState
    }

    // MARK: - snapshot

    func snapshot(of session: AgentTabSession) -> AgentSessionSnapshot {
        Self.makeSnapshot(of: session)
    }

    static func makeSnapshot(of session: AgentTabSession) -> AgentSessionSnapshot {
        let pendingInteraction: AgentSessionSnapshot.PendingInteraction? = if let approval = session.pendingApproval {
            .approval(approval.id)
        } else if let review = session.pendingCodexHookReview {
            .codexHookReview(review.id)
        } else if let askUser = session.pendingAskUser {
            .askUser(askUser.id)
        } else if let userInput = session.pendingUserInputRequest {
            .userInput(userInput.id)
        } else if let elicitation = session.pendingMCPElicitationRequest {
            .mcpElicitation(elicitation.id)
        } else if let permissions = session.pendingPermissionsRequest {
            .permissions(permissions.id)
        } else {
            nil
        }
        return AgentSessionSnapshot(
            tabID: session.tabID,
            sessionID: session.activeAgentSessionID,
            provider: session.selectedAgent,
            modelRaw: session.selectedModelRaw,
            runState: session.runState,
            runID: session.runID,
            providerSessionID: session.providerSessionID,
            items: session.items,
            pendingInteraction: pendingInteraction
        )
    }
}

// MARK: - Execution event mirroring

extension InProcessAgentSessionExecutor: AgentModeExecutionEventObserving {
    func executionDidObserveRuntimeEvent(_ event: NativeAgentRuntimeEvent, session: AgentTabSession) {
        guard let connection, let sessionID = session.activeAgentSessionID else { return }
        // Same executor (main); the hop never suspends, it only satisfies isolation checking.
        Task { await connection.publishRuntimeEvent(event, sessionID: sessionID) }
    }

    func executionDidCommitTerminalOutcome(_ outcome: DomainAgentRunTerminalOutcome, tabID: UUID) {
        guard let connection,
              let sessionID = viewModel?.sessions[tabID]?.activeAgentSessionID
        else { return }
        Task { await connection.publishRunTermination(outcome, sessionID: sessionID) }
    }
}
