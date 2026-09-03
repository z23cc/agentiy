import Foundation

/// Execution-side state for one in-process Agent session: the provider handles that used
/// to live directly on `AgentTabSession`.
///
/// `InProcessAgentSessionConnection` owns this object conceptually and parks it in the
/// presentation cache's opaque `connectionAttachment` slot so its lifetime tracks the
/// tab. Coordinators and runners (execution side) reach it through
/// `AgentTabSession.inProcessExecution`; presentation code (Views/ViewModels) never
/// names it — `Scripts/agent_session_boundary_guardrails.sh` enforces that. P3 replaces
/// this object with host-owned state and deletes it.
@MainActor
final class InProcessAgentSessionExecutionState: AgentSessionConnectionAttachment {
    struct CodexControllerFeatureState: Equatable {
        var computerUseEnabled: Bool
        var goalSupportEnabled: Bool
        var reasoningSummariesEnabled: Bool
        var memoriesEnabled: Bool
    }

    /// Headless (non-native) provider process for the current session.
    var provider: HeadlessAgentProvider?

    var claudeController: (any NativeAgentRuntimeControlling)?

    var codexController: (any CodexSessionControlling)? {
        didSet {
            let oldIdentity = oldValue.map { ObjectIdentifier($0) }
            let newIdentity = codexController.map { ObjectIdentifier($0) }
            guard oldIdentity != newIdentity else { return }
            codexControllerGeneration = UUID()
            onCodexControllerReplaced?()
        }
    }

    private(set) var codexControllerGeneration = UUID()
    /// The permission profile the current Codex controller was created with.
    /// Used to detect when MCP control changes require controller recycling.
    var codexControllerPermissionProfile: AgentModeViewModel.AgentPermissionProfile?
    /// The task label kind the current Codex controller was created with.
    /// Used to detect when role-specific native tool overrides require controller recycling.
    var codexControllerTaskLabelKind: AgentModelCatalog.TaskLabelKind?
    /// The launch/execution directory pair the current Codex controller was created with.
    /// Controller replacement key: the provider is recycled when either directory changes,
    /// e.g. when a session worktree binding moves the execution cwd.
    var codexControllerWorkspacePaths: CodexRuntimeWorkspacePaths?
    var codexControllerFeatureState: CodexControllerFeatureState?

    var acpController: ACPAgentSessionController?

    /// Fired after `codexControllerGeneration` rotates for a replaced controller so the
    /// presentation cache can drop turn identity that the old controller owned.
    var onCodexControllerReplaced: (() -> Void)?

    init() {}

    var hasAnyLiveProviderHandle: Bool {
        provider != nil || claudeController != nil || codexController != nil || acpController != nil
    }

    /// Identity tuple of the live provider handles, used by MCP wake reconciliation to
    /// detect a controller swap between two main-actor slices.
    var providerHandleIdentity: AgentProviderHandleIdentity {
        AgentProviderHandleIdentity(
            codexControllerInstanceID: codexController.map(ObjectIdentifier.init),
            codexControllerGeneration: codexControllerGeneration,
            claudeControllerInstanceID: claudeController.map(ObjectIdentifier.init),
            acpControllerInstanceID: acpController.map(ObjectIdentifier.init)
        )
    }
}

/// Value snapshot of which provider handles a session currently holds.
struct AgentProviderHandleIdentity: Equatable {
    let codexControllerInstanceID: ObjectIdentifier?
    let codexControllerGeneration: UUID
    let claudeControllerInstanceID: ObjectIdentifier?
    let acpControllerInstanceID: ObjectIdentifier?
}

@MainActor
extension AgentTabSession {
    /// Execution-side state for this session, created on first use.
    ///
    /// Execution-side callers only (Runtime/, Connection/). Presentation code must go
    /// through `AgentSessionConnection` or the transitional helpers in
    /// `AgentTabSession+InProcessProviderHandles.swift`.
    var inProcessExecution: InProcessAgentSessionExecutionState {
        if let existing = connectionAttachment as? InProcessAgentSessionExecutionState {
            return existing
        }
        let created = InProcessAgentSessionExecutionState()
        created.onCodexControllerReplaced = { [weak self] in
            self?.handleCodexControllerReplaced()
        }
        connectionAttachment = created
        return created
    }

    /// Whether execution state has been created for this session yet. Reading
    /// `inProcessExecution` creates it; this does not.
    var hasInProcessExecutionState: Bool {
        connectionAttachment is InProcessAgentSessionExecutionState
    }
}
