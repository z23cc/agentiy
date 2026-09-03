import Foundation

/// Transitional execution-side operations the presentation layer still has to trigger
/// while the in-process stack is hosted next to `AgentModeViewModel`.
///
/// These are the provider-handle manipulations the view model used to perform inline on
/// `AgentTabSession.{provider, codexController, claudeController, acpController}`. They
/// live here — execution side, inside `Connection/InProcess` — so the view model only
/// names provider-neutral operations and never a provider controller type. P3 moves each
/// one behind `AgentSessionConnection.stop`/`interrupt` or host-side lifecycle and deletes
/// this file.
@MainActor
extension AgentTabSession {
    // MARK: Queries

    var hasLiveCodexController: Bool {
        inProcessExecution.codexController != nil
    }

    var hasLiveACPController: Bool {
        inProcessExecution.acpController != nil
    }

    /// Identity tuple of the live provider handles, for MCP wake reconciliation.
    var providerHandleIdentity: AgentProviderHandleIdentity {
        inProcessExecution.providerHandleIdentity
    }

    // MARK: Provider process lifecycle

    func disposeProviderIfPresent() async {
        let execution = inProcessExecution
        let provider = execution.provider
        execution.provider = nil
        if let provider {
            await provider.dispose()
        }
    }

    func teardownACPControllerIfPresent() async {
        acpSteeringFlushTask?.cancel()
        acpSteeringFlushTask = nil
        pendingACPSteeringInstructions.removeAll()
        let execution = inProcessExecution
        guard let controller = execution.acpController else { return }
        execution.acpController = nil
        AgentModeProcessRunIdentity.clearProcessRunID(for: self)
        await controller.cancelPrompt()
        await controller.shutdown()
    }

    /// Shuts down the ACP controller without touching the ACP steering queue. Used when
    /// the execution location changes and the queue is reconciled separately.
    func shutdownACPControllerIfPresent() async {
        let execution = inProcessExecution
        guard let controller = execution.acpController else { return }
        execution.acpController = nil
        AgentModeProcessRunIdentity.clearProcessRunID(for: self)
        await controller.cancelPrompt()
        await controller.shutdown()
    }

    /// Synchronously detaches the headless provider and ACP controller so a
    /// workspace-switch background cleanup can dispose them after the session is gone.
    /// Runs in the finalize slice; no suspension point.
    func detachProviderHandlesForWorkspaceSwitch() -> InProcessDetachedProviderHandles {
        let execution = inProcessExecution
        let provider = execution.provider
        execution.provider = nil
        acpSteeringFlushTask?.cancel()
        acpSteeringFlushTask = nil
        pendingACPSteeringInstructions.removeAll()
        let acpController = execution.acpController
        execution.acpController = nil
        return InProcessDetachedProviderHandles(provider: provider, acpController: acpController)
    }

    // MARK: Interactions

    /// Routes an approval decision to the live ACP controller, if any.
    func respondToACPPermissionRequest(id: String, decision: AgentApprovalDecision) {
        Task { [controller = inProcessExecution.acpController] in
            await controller?.respondToPermissionRequest(id: id, decision: decision)
        }
    }

    // MARK: Conversation cleanup

    /// Cleans up the provider-side conversation through whichever live handle owns it,
    /// or `nil` when no live handle exists and the caller must fall back to the registry.
    func cleanupProviderConversationThroughLiveHandle(
        _ handle: ProviderConversationCleanupHandle,
        action: ProviderConversationCleanupAction
    ) async -> ProviderConversationCleanupOutcome? {
        let execution = inProcessExecution
        if let controller = execution.codexController {
            return await controller.cleanupConversation(handle, action: action)
        } else if let controller = execution.claudeController {
            return await controller.cleanupConversation(handle, action: action)
        } else if let provider = execution.provider {
            return await provider.cleanupConversation(handle, action: action)
        }
        return nil
    }
}
