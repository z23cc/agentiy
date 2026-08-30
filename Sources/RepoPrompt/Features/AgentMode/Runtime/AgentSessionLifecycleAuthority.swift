import CryptoKit
import Foundation
import OSLog
import RepoPromptDomainRuntime

/// App compatibility facade for Agent compose-tab/session identity transitions.
///
/// Pure identity/protection/admission decisions are owned by
/// `DomainAgentSessionLifecycleDecisionAuthority`; this MainActor facade retains only
/// `WorkspaceModel` projection reconciliation and App diagnostics. Callers may own presentation,
/// persistence, provider, or MCP mechanics, but none may independently retarget a live operation.
@MainActor
final class AgentSessionLifecycleAuthority {
    // Compatibility vocabulary for App callers; the decision types and identity are owned by
    // RepoPromptDomainRuntime and remain usable by headless adapters without MainActor state.
    typealias Identity = DomainAgentSessionLifecycleIdentity
    typealias MutationTarget = DomainAgentSessionMutationTarget
    typealias CallerCategory = DomainAgentSessionCallerCategory
    typealias Intent = DomainAgentSessionIntent
    typealias Phase = DomainAgentSessionPhase
    typealias Decision = DomainAgentSessionDecision
    typealias RejectionReason = DomainAgentSessionRejectionReason
    typealias AdmissionDecision = DomainAgentSessionAdmissionDecision

    struct ProtectionClaim: Equatable {
        let identity: Identity
        let tab: ComposeTabState
        let isLive: Bool
        let isActive: Bool
        let isPinned: Bool
        let hasActiveRun: Bool

        var domainFacts: DomainAgentSessionProtectionFacts {
            DomainAgentSessionProtectionFacts(
                identity: identity,
                isLive: isLive,
                isActive: isActive,
                isPinned: isPinned,
                hasActiveRun: hasActiveRun
            )
        }

        var isProtected: Bool {
            domainFacts.isProtected
        }
    }

    struct Event: Equatable {
        let caller: CallerCategory
        let intent: Intent
        let phase: Phase
        let decision: Decision
        let identity: Identity?
        let previousSessionID: UUID?
        let currentSessionID: UUID?
        let isPinned: Bool
        let isLive: Bool
        let isActive: Bool
        let isProtected: Bool
        let workspaceSaveResult: String
        let reason: String
    }

    struct ProjectionOutcome: Equatable {
        let workspaces: [WorkspaceModel]
        let protectedWorkspaceIDs: Set<UUID>
        let protectedClaimCount: Int
    }

    private let decisionAuthority = DomainAgentSessionLifecycleDecisionAuthority()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RepoPrompt",
        category: "AgentSessionLifecycle"
    )

    #if DEBUG
        private static var eventObserver: ((Event) -> Void)?

        static func setEventObserverForTesting(_ observer: ((Event) -> Void)?) {
            eventObserver = observer
        }
    #endif

    func validateMutationTarget(
        expected: Identity,
        current: ProtectionClaim?
    ) -> Result<MutationTarget, RejectionReason> {
        decisionAuthority.validateMutationTarget(
            expected: expected,
            current: current?.domainFacts
        )
    }

    /// Compatibility adapter for the Domain-owned commit/rollback decision for every
    /// create-or-continue admission. Presentation and persistence layers provide facts but do not
    /// independently decide whether provider-visible identity may be published.
    func decideAdmission(
        persistence: WorkspacePersistenceOutcome,
        targetWorkspaceID: UUID,
        bindingStillCurrent: Bool
    ) -> AdmissionDecision {
        decisionAuthority.decideAdmission(
            persistence: DomainAgentSessionPersistenceFact(
                workspaceID: persistence.workspaceID,
                acceptedForLifecycleAdmission: persistence.acceptedForLifecycleAdmission
            ),
            targetWorkspaceID: targetWorkspaceID,
            bindingStillCurrent: bindingStillCurrent
        )
    }

    func reconcileProjection(
        projectedWorkspaces: [WorkspaceModel],
        currentWorkspaces: [WorkspaceModel],
        claims: [ProtectionClaim]
    ) -> ProjectionOutcome {
        let protectedClaims = claims.filter(\.isProtected)
        guard !protectedClaims.isEmpty else {
            return ProjectionOutcome(
                workspaces: projectedWorkspaces,
                protectedWorkspaceIDs: [],
                protectedClaimCount: 0
            )
        }

        let claimsByWorkspace = Dictionary(grouping: protectedClaims, by: { $0.identity.workspaceID })
        let currentByID = Dictionary(
            currentWorkspaces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var reconciled = projectedWorkspaces
        var protectedWorkspaceIDs = Set<UUID>()
        var protectedClaimCount = 0

        for (workspaceID, workspaceClaims) in claimsByWorkspace {
            guard let currentWorkspace = currentByID[workspaceID] else { continue }
            let projectedIndex: Int
            if let existingIndex = reconciled.firstIndex(where: { $0.id == workspaceID }) {
                projectedIndex = existingIndex
            } else {
                reconciled.append(currentWorkspace)
                projectedIndex = reconciled.index(before: reconciled.endIndex)
                protectedWorkspaceIDs.insert(workspaceID)
                protectedClaimCount += workspaceClaims.count
                recordProjectionProtection(
                    claims: workspaceClaims,
                    previousTabs: [],
                    reason: "workspace_missing_from_projection"
                )
                continue
            }

            let previous = reconciled[projectedIndex]
            var next = previous
            let protectedTabIDs = Set(workspaceClaims.map(\.identity.tabID))
            next.stashedTabs.removeAll { protectedTabIDs.contains($0.tab.id) }

            for claim in workspaceClaims {
                let tabID = claim.identity.tabID
                if let sessionID = claim.identity.sessionID {
                    for tabIndex in next.composeTabs.indices
                        where next.composeTabs[tabIndex].id != tabID
                        && next.composeTabs[tabIndex].activeAgentSessionID == sessionID
                    {
                        next.composeTabs[tabIndex].activeAgentSessionID = nil
                    }
                }
                if let index = next.composeTabs.firstIndex(where: { $0.id == tabID }) {
                    next.composeTabs[index] = claim.tab
                } else if let localIndex = currentWorkspace.composeTabs.firstIndex(where: { $0.id == tabID }) {
                    next.composeTabs.insert(claim.tab, at: min(localIndex, next.composeTabs.count))
                } else {
                    next.composeTabs.append(claim.tab)
                }
            }

            if let activeTabID = currentWorkspace.activeComposeTabID,
               protectedTabIDs.contains(activeTabID)
            {
                next.activeComposeTabID = activeTabID
            }

            guard next != previous else { continue }
            reconciled[projectedIndex] = next
            protectedWorkspaceIDs.insert(workspaceID)
            let changedClaims = workspaceClaims.filter { claim in
                let previousTab = previous.composeTabs.first(where: { $0.id == claim.identity.tabID })
                return previousTab != claim.tab
                    || previous.stashedTabs.contains(where: { $0.tab.id == claim.identity.tabID })
                    || (claim.isActive && previous.activeComposeTabID != claim.identity.tabID)
            }
            protectedClaimCount += changedClaims.count
            recordProjectionProtection(
                claims: changedClaims,
                previousTabs: previous.composeTabs,
                reason: "stale_projection_reconciled"
            )
        }

        return ProjectionOutcome(
            workspaces: reconciled,
            protectedWorkspaceIDs: protectedWorkspaceIDs,
            protectedClaimCount: protectedClaimCount
        )
    }

    func record(_ event: Event) {
        let identity = event.identity
        let line = [
            "caller=\(event.caller.rawValue)",
            "intent=\(event.intent.rawValue)",
            "phase=\(event.phase.rawValue)",
            "decision=\(event.decision.rawValue)",
            "workspace=\(Self.hashedID(identity?.workspaceID))",
            "tab=\(Self.hashedID(identity?.tabID))",
            "session=\(Self.hashedID(identity?.sessionID))",
            "previousSession=\(Self.hashedID(event.previousSessionID))",
            "currentSession=\(Self.hashedID(event.currentSessionID))",
            "binding=\(Self.hashedID(identity?.persistentBindingGeneration))",
            "transition=\(identity.map { String($0.bindingTransitionGeneration) } ?? "nil")",
            "pinned=\(event.isPinned)",
            "live=\(event.isLive)",
            "active=\(event.isActive)",
            "protected=\(event.isProtected)",
            "workspaceSave=\(Self.sanitizedCategory(event.workspaceSaveResult))",
            "reason=\(Self.sanitizedCategory(event.reason))"
        ].joined(separator: " ")
        Self.logger.notice("\(line, privacy: .public)")
        #if DEBUG
            Self.eventObserver?(event)
        #endif
    }

    private func recordProjectionProtection(
        claims: [ProtectionClaim],
        previousTabs: [ComposeTabState],
        reason: String
    ) {
        // One event per affected identity, capped to keep a damaged projection bounded.
        for claim in claims.prefix(8) {
            let previousSessionID = previousTabs
                .first(where: { $0.id == claim.identity.tabID })?
                .activeAgentSessionID
            record(Event(
                caller: .domainProjection,
                intent: .applyProjection,
                phase: .projectionReconciliation,
                decision: .protected,
                identity: claim.identity,
                previousSessionID: previousSessionID,
                currentSessionID: claim.identity.sessionID,
                isPinned: claim.isPinned,
                isLive: claim.isLive,
                isActive: claim.isActive,
                isProtected: true,
                workspaceSaveResult: "pending_recovery",
                reason: reason
            ))
        }
    }

    private static func hashedID(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        let digest = SHA256.hash(data: Data(id.uuidString.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedCategory(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalars = raw.unicodeScalars.prefix(64).map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(scalars)
    }
}
