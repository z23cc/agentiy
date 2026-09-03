import Foundation
@testable import RepoPromptApp
import XCTest

/// `AgentTabSession` execution-side tests: provider handles live in the
/// `InProcessAgentSessionExecutionState` parked in its opaque attachment
/// slot. These tests pin lazy creation and the controller-replacement callback.
@MainActor
final class AgentTabSessionExecutionStateTests: XCTestCase {
    func testExecutionStateIsCreatedLazilyAndParkedInAttachmentSlot() {
        let session = AgentTabSession(tabID: UUID())

        XCTAssertFalse(session.hasInProcessExecutionState)
        XCTAssertNil(session.connectionAttachment)

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
        let initialIdentity = session.inProcessExecution.providerHandleIdentity

        session.inProcessExecution.codexController = first
        session.codexRoutingObservedTurnID = "turn-1"
        let firstIdentity = session.inProcessExecution.providerHandleIdentity

        XCTAssertNotNil(session.inProcessExecution.codexController)
        XCTAssertNotEqual(firstIdentity.codexControllerGeneration, initialIdentity.codexControllerGeneration)
        XCTAssertEqual(firstIdentity.codexControllerInstanceID, ObjectIdentifier(first))
        XCTAssertEqual(session.codexRoutingObservedTurnID, "turn-1")

        // Assigning the same instance is not a replacement.
        session.inProcessExecution.codexController = first
        XCTAssertEqual(session.inProcessExecution.providerHandleIdentity, firstIdentity)
        XCTAssertEqual(session.codexRoutingObservedTurnID, "turn-1")

        session.inProcessExecution.codexController = second
        let secondIdentity = session.inProcessExecution.providerHandleIdentity

        XCTAssertNotEqual(secondIdentity.codexControllerGeneration, firstIdentity.codexControllerGeneration)
        XCTAssertEqual(secondIdentity.codexControllerInstanceID, ObjectIdentifier(second))
        XCTAssertNil(session.codexRoutingObservedTurnID, "turn identity owned by the old controller is dropped")

        session.inProcessExecution.codexController = nil
        XCTAssertNil(session.inProcessExecution.codexController)
        XCTAssertNil(session.inProcessExecution.providerHandleIdentity.codexControllerInstanceID)
        XCTAssertNotEqual(session.inProcessExecution.providerHandleIdentity.codexControllerGeneration, secondIdentity.codexControllerGeneration)
    }
}
