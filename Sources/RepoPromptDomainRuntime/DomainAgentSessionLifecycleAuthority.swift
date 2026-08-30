import Foundation

/// UI-neutral identity and admission authority for Agent session mutations.
///
/// This value type is intentionally independent of presentation, persistence, and provider
/// implementations. App and headless adapters provide immutable facts and consume the typed
/// decision; they must not duplicate identity or workspace admission predicates.
package struct DomainAgentSessionLifecycleIdentity: Equatable, Hashable, Sendable {
    package let workspaceID: UUID
    package let tabID: UUID
    package let sessionID: UUID?
    package let persistentBindingGeneration: UUID?
    package let bindingTransitionGeneration: UInt64

    package init(
        workspaceID: UUID,
        tabID: UUID,
        sessionID: UUID?,
        persistentBindingGeneration: UUID?,
        bindingTransitionGeneration: UInt64
    ) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.sessionID = sessionID
        self.persistentBindingGeneration = persistentBindingGeneration
        self.bindingTransitionGeneration = bindingTransitionGeneration
    }
}

/// Immutable protection facts projected from a compose tab by an app adapter.
package struct DomainAgentSessionProtectionFacts: Equatable, Sendable {
    package let identity: DomainAgentSessionLifecycleIdentity
    package let isLive: Bool
    package let isActive: Bool
    package let isPinned: Bool
    package let hasActiveRun: Bool

    package init(
        identity: DomainAgentSessionLifecycleIdentity,
        isLive: Bool,
        isActive: Bool,
        isPinned: Bool,
        hasActiveRun: Bool
    ) {
        self.identity = identity
        self.isLive = isLive
        self.isActive = isActive
        self.isPinned = isPinned
        self.hasActiveRun = hasActiveRun
    }

    /// A live or pinned tab is protected from projection replacement.
    package var isProtected: Bool {
        isLive || isPinned
    }
}

package struct DomainAgentSessionMutationTarget: Equatable, Sendable {
    package let tabID: UUID
    package let identity: DomainAgentSessionLifecycleIdentity?

    package init(tabID: UUID, identity: DomainAgentSessionLifecycleIdentity?) {
        self.tabID = tabID
        self.identity = identity
    }
}

package enum DomainAgentSessionCallerCategory: String, Equatable, Hashable, Sendable {
    case agentRunStart = "agent_run_start"
    case agentSessionControl = "agent_session_control"
    case domainProjection = "domain_projection"
    case providerLifecycle = "provider_lifecycle"
}

package enum DomainAgentSessionIntent: String, Equatable, Hashable, Sendable {
    case createOrContinue = "create_or_continue"
    case applyProjection = "apply_projection"
    case setStatus = "set_status"
    case shareThoughts = "share_thoughts"
    case waitForInstruction = "wait_for_instruction"
    case askUser = "ask_user"
    case providerStart = "provider_start"
}

package enum DomainAgentSessionPhase: String, Equatable, Hashable, Sendable {
    case beforeBinding = "before_binding"
    case bindingPersisted = "binding_persisted"
    case beforeProviderStart = "before_provider_start"
    case afterProviderStart = "after_provider_start"
    case mutationValidation = "mutation_validation"
    case projectionReconciliation = "projection_reconciliation"
}

package enum DomainAgentSessionDecision: String, Equatable, Hashable, Sendable {
    case admitted
    case protected
    case rejected
    case unchanged
}

package enum DomainAgentSessionRejectionReason: String, Error, Equatable, Sendable {
    case workspacePersistenceRejected = "workspace_persistence_rejected"
    case workspaceChanged = "workspace_changed"
    case tabMissing = "tab_missing"
    case sessionMissing = "session_missing"
    case sessionIdentityChanged = "session_identity_changed"
    case bindingGenerationChanged = "binding_generation_changed"
    case transitionGenerationChanged = "transition_generation_changed"
}

package enum DomainAgentSessionAdmissionDecision: Equatable, Sendable {
    case commit
    case rollback(DomainAgentSessionRejectionReason)
}

/// Persistence facts crossing into the lifecycle authority. The authority intentionally does not
/// know the app's persistence enum or error payloads.
package struct DomainAgentSessionPersistenceFact: Equatable, Sendable {
    package let workspaceID: UUID?
    package let acceptedForLifecycleAdmission: Bool

    package init(workspaceID: UUID?, acceptedForLifecycleAdmission: Bool) {
        self.workspaceID = workspaceID
        self.acceptedForLifecycleAdmission = acceptedForLifecycleAdmission
    }
}

/// Pure decision surface for Agent session identity and admission.
package struct DomainAgentSessionLifecycleDecisionAuthority: Sendable {
    package init() {}

    package func validateMutationTarget(
        expected: DomainAgentSessionLifecycleIdentity,
        current: DomainAgentSessionProtectionFacts?
    ) -> Result<DomainAgentSessionMutationTarget, DomainAgentSessionRejectionReason> {
        guard let current else { return .failure(.tabMissing) }
        guard current.identity.workspaceID == expected.workspaceID else {
            return .failure(.workspaceChanged)
        }
        guard current.identity.tabID == expected.tabID else { return .failure(.tabMissing) }
        guard current.identity.sessionID == expected.sessionID else {
            return .failure(.sessionIdentityChanged)
        }
        guard current.identity.persistentBindingGeneration == expected.persistentBindingGeneration else {
            return .failure(.bindingGenerationChanged)
        }
        guard current.identity.bindingTransitionGeneration == expected.bindingTransitionGeneration else {
            return .failure(.transitionGenerationChanged)
        }
        return .success(DomainAgentSessionMutationTarget(tabID: expected.tabID, identity: expected))
    }

    /// Owns the commit/rollback decision for every create-or-continue admission.
    package func decideAdmission(
        persistence: DomainAgentSessionPersistenceFact,
        targetWorkspaceID: UUID,
        bindingStillCurrent: Bool
    ) -> DomainAgentSessionAdmissionDecision {
        guard persistence.acceptedForLifecycleAdmission else {
            return .rollback(.workspacePersistenceRejected)
        }
        guard persistence.workspaceID == targetWorkspaceID else {
            return .rollback(.workspaceChanged)
        }
        guard bindingStillCurrent else {
            return .rollback(.sessionIdentityChanged)
        }
        return .commit
    }
}
