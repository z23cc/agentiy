import Foundation

@MainActor
extension AgentModeViewModel {
    /// Answers the pending approval through the session connection. The answer is applied on
    /// the next main-actor turn; a stale or already-answered request settles as a rejected
    /// command and is ignored, exactly like the inline guard this method used to perform.
    func submitApprovalDecision(tabID: UUID, decision: AgentApprovalDecision) {
        guard let session = sessions[tabID],
              let request = session.pendingApproval
        else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            try? await respondThroughConnection(
                session: session,
                interactionID: request.id,
                answer: .approval(decision)
            )
        }
    }

    func submitCodexHookReviewDecision(
        tabID: UUID,
        requestID: UUID,
        decision: AgentCodexHookReviewDecision
    ) async throws {
        guard let session = sessions[tabID],
              let currentRequest = session.pendingCodexHookReview
        else {
            throw AgentCodexHookReviewResolutionError.noPendingReview
        }
        guard currentRequest.id == requestID else {
            throw AgentCodexHookReviewResolutionError.staleRequest(currentID: currentRequest.id)
        }
        // Execution-side resolution errors (`AgentCodexHookReviewResolutionError`) propagate
        // unchanged: the in-process connection rethrows the executor's original error.
        try await respondThroughConnection(
            session: session,
            interactionID: requestID,
            answer: .codexHookReview(decision)
        )
    }

    func isCodexHookApprovalStrictModeEnabled() -> Bool {
        codexCoordinator.isCodexHookApprovalStrictModeEnabled()
    }

    func submitMCPElicitationResponse(
        tabID: UUID,
        requestID: UUID,
        response: AgentMCPElicitationResponse
    ) {
        guard let session = sessions[tabID],
              let request = session.pendingMCPElicitationRequest,
              request.id == requestID
        else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            try? await respondThroughConnection(
                session: session,
                interactionID: request.id,
                answer: .mcpElicitation(response)
            )
        }
    }

    func submitApplyEditsReviewDecision(
        tabID: UUID,
        reviewID: UUID,
        decision: ApplyEditsReviewDecision
    ) {
        let scope = applyEditsScope(for: tabID)
        Task { [applyEditsApprovalStore] in
            await applyEditsApprovalStore.resolveReview(
                scope: scope,
                reviewID: reviewID,
                decision: decision
            )
        }
    }
}
