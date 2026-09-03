import Foundation
@testable import RepoPromptApp
import XCTest

/// `AgentTabSession` is a presentation cache after P1: provider handles live in the
/// connection-owned `InProcessAgentSessionExecutionState` parked in its opaque attachment
/// slot. These tests pin the lazy creation, the handle queries presentation code is allowed
/// to use, and the controller-replacement callback that used to be a `didSet` on the tab.
@MainActor
final class AgentTabSessionExecutionStateTests: XCTestCase {
    func testExecutionStateIsCreatedLazilyAndParkedInAttachmentSlot() {
        let session = AgentTabSession(tabID: UUID())

        XCTAssertFalse(session.hasInProcessExecutionState)
        XCTAssertNil(session.connectionAttachment)
        XCTAssertFalse(session.hasLiveCodexController)
        XCTAssertFalse(session.hasLiveACPController)

        let state = session.inProcessExecution

        XCTAssertTrue(session.hasInProcessExecutionState)
        XCTAssertTrue(session.connectionAttachment === state)
        XCTAssertTrue(session.inProcessExecution === state, "repeated reads return the same execution state")
        XCTAssertFalse(state.hasAnyLiveProviderHandle)
    }

    func testCodexControllerReplacementRotatesGenerationAndResetsPresentationTurnState() {
        let session = AgentTabSession(tabID: UUID())
        let recorder = LifecycleRecorder()
        let first = LifecycleNoopCodexController(recorder: recorder)
        let second = LifecycleNoopCodexController(recorder: recorder)
        let initialIdentity = session.providerHandleIdentity

        session.inProcessExecution.codexController = first
        session.codexRoutingObservedTurnID = "turn-1"
        let firstIdentity = session.providerHandleIdentity

        XCTAssertTrue(session.hasLiveCodexController)
        XCTAssertNotEqual(firstIdentity.codexControllerGeneration, initialIdentity.codexControllerGeneration)
        XCTAssertEqual(firstIdentity.codexControllerInstanceID, ObjectIdentifier(first))
        XCTAssertEqual(session.codexRoutingObservedTurnID, "turn-1")

        // Assigning the same instance is not a replacement.
        session.inProcessExecution.codexController = first
        XCTAssertEqual(session.providerHandleIdentity, firstIdentity)
        XCTAssertEqual(session.codexRoutingObservedTurnID, "turn-1")

        session.inProcessExecution.codexController = second
        let secondIdentity = session.providerHandleIdentity

        XCTAssertNotEqual(secondIdentity.codexControllerGeneration, firstIdentity.codexControllerGeneration)
        XCTAssertEqual(secondIdentity.codexControllerInstanceID, ObjectIdentifier(second))
        XCTAssertNil(session.codexRoutingObservedTurnID, "turn identity owned by the old controller is dropped")

        session.inProcessExecution.codexController = nil
        XCTAssertFalse(session.hasLiveCodexController)
        XCTAssertNil(session.providerHandleIdentity.codexControllerInstanceID)
        XCTAssertNotEqual(session.providerHandleIdentity.codexControllerGeneration, secondIdentity.codexControllerGeneration)
    }

    func testDetachingProviderHandlesForWorkspaceSwitchClearsExecutionState() {
        let session = AgentTabSession(tabID: UUID())
        let provider = NoopHeadlessProvider()
        session.inProcessExecution.provider = provider

        let detached = session.detachProviderHandlesForWorkspaceSwitch()

        XCTAssertTrue((detached.provider as? NoopHeadlessProvider) === provider)
        XCTAssertNil(detached.acpController)
        XCTAssertNil(session.inProcessExecution.provider)
        XCTAssertFalse(session.inProcessExecution.hasAnyLiveProviderHandle)
    }
}

private final class NoopHeadlessProvider: HeadlessAgentProvider {
    func streamAgentMessage(_: AgentMessage, runID _: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func dispose() async {}
}
