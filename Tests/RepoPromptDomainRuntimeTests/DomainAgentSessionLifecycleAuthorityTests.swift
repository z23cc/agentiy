import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainAgentSessionLifecycleAuthorityTests: XCTestCase {
    func testProtectionFactsAreUIIndependentAndBoundToIdentity() {
        let identity = makeIdentity()
        let facts = DomainAgentSessionProtectionFacts(
            identity: identity,
            isLive: false,
            isActive: true,
            isPinned: true,
            hasActiveRun: false
        )

        XCTAssertTrue(facts.isProtected)
        XCTAssertEqual(facts.identity, identity)
        XCTAssertFalse(DomainAgentSessionProtectionFacts(
            identity: identity,
            isLive: false,
            isActive: true,
            isPinned: false,
            hasActiveRun: true
        ).isProtected)
    }

    func testMutationTargetValidationRejectsEveryIdentityFence() {
        let authority = DomainAgentSessionLifecycleDecisionAuthority()
        let expected = makeIdentity()
        let matching = DomainAgentSessionProtectionFacts(
            identity: expected,
            isLive: true,
            isActive: true,
            isPinned: false,
            hasActiveRun: true
        )

        XCTAssertEqual(
            authority.validateMutationTarget(expected: expected, current: matching),
            .success(DomainAgentSessionMutationTarget(tabID: expected.tabID, identity: expected))
        )
        XCTAssertEqual(
            authority.validateMutationTarget(expected: expected, current: nil),
            .failure(.tabMissing)
        )

        let workspaceMismatch = facts(
            identity: .init(
                workspaceID: UUID(),
                tabID: expected.tabID,
                sessionID: expected.sessionID,
                persistentBindingGeneration: expected.persistentBindingGeneration,
                bindingTransitionGeneration: expected.bindingTransitionGeneration
            )
        )
        XCTAssertEqual(
            authority.validateMutationTarget(expected: expected, current: workspaceMismatch),
            .failure(.workspaceChanged)
        )

        let tabMismatch = DomainAgentSessionProtectionFacts(
            identity: .init(
                workspaceID: expected.workspaceID,
                tabID: UUID(),
                sessionID: expected.sessionID,
                persistentBindingGeneration: expected.persistentBindingGeneration,
                bindingTransitionGeneration: expected.bindingTransitionGeneration
            ),
            isLive: true,
            isActive: true,
            isPinned: false,
            hasActiveRun: true
        )
        XCTAssertEqual(
            authority.validateMutationTarget(expected: expected, current: tabMismatch),
            .failure(.tabMissing)
        )

        let sessionMismatch = facts(identity: expected, sessionID: UUID())
        XCTAssertEqual(
            authority.validateMutationTarget(expected: expected, current: sessionMismatch),
            .failure(.sessionIdentityChanged)
        )

        let bindingMismatch = facts(
            identity: .init(
                workspaceID: expected.workspaceID,
                tabID: expected.tabID,
                sessionID: expected.sessionID,
                persistentBindingGeneration: UUID(),
                bindingTransitionGeneration: expected.bindingTransitionGeneration
            )
        )
        XCTAssertEqual(
            authority.validateMutationTarget(expected: expected, current: bindingMismatch),
            .failure(.bindingGenerationChanged)
        )

        let transitionMismatch = facts(
            identity: .init(
                workspaceID: expected.workspaceID,
                tabID: expected.tabID,
                sessionID: expected.sessionID,
                persistentBindingGeneration: expected.persistentBindingGeneration,
                bindingTransitionGeneration: expected.bindingTransitionGeneration + 1
            )
        )
        XCTAssertEqual(
            authority.validateMutationTarget(expected: expected, current: transitionMismatch),
            .failure(.transitionGenerationChanged)
        )
    }

    func testAdmissionPrioritizesPersistenceWorkspaceAndBindingFences() {
        let authority = DomainAgentSessionLifecycleDecisionAuthority()
        let workspaceID = UUID()
        let accepted = DomainAgentSessionPersistenceFact(
            workspaceID: workspaceID,
            acceptedForLifecycleAdmission: true
        )

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: accepted,
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .commit
        )
        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .init(workspaceID: workspaceID, acceptedForLifecycleAdmission: false),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .rollback(.workspacePersistenceRejected)
        )
        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .init(workspaceID: UUID(), acceptedForLifecycleAdmission: true),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .rollback(.workspaceChanged)
        )
        XCTAssertEqual(
            authority.decideAdmission(
                persistence: accepted,
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: false
            ),
            .rollback(.sessionIdentityChanged)
        )
    }

    private func makeIdentity() -> DomainAgentSessionLifecycleIdentity {
        DomainAgentSessionLifecycleIdentity(
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 4
        )
    }

    private func facts(
        identity: DomainAgentSessionLifecycleIdentity,
        sessionID: UUID? = nil
    ) -> DomainAgentSessionProtectionFacts {
        let effectiveIdentity = sessionID.map {
            DomainAgentSessionLifecycleIdentity(
                workspaceID: identity.workspaceID,
                tabID: identity.tabID,
                sessionID: $0,
                persistentBindingGeneration: identity.persistentBindingGeneration,
                bindingTransitionGeneration: identity.bindingTransitionGeneration
            )
        } ?? identity
        return DomainAgentSessionProtectionFacts(
            identity: effectiveIdentity,
            isLive: true,
            isActive: true,
            isPinned: false,
            hasActiveRun: true
        )
    }
}
