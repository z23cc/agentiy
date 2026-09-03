import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// ADR-0011 P4: MCP `agent_run op: attach` / `detach` join a host session as a second
/// client. The uncontrolled-run fence is attach, not a permanent deny.
@MainActor
final class AgentRunMCPToolServiceAttachTests: XCTestCase {
    private var harness: AgentSessionHostTestHarness!

    override func setUpWithError() throws {
        harness = try AgentSessionHostTestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    func testAttachThenWaitThenDetach() async throws {
        try harness.startServer(script: AgentSessionScriptedExecutorScript(autoCompleteTurns: false))
        let writer = try await harness.connect()
        let started = try await harness.startSession(writer)
        let sessionID = try XCTUnwrap(UUID(uuidString: started.sessionId))

        let window = try makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let (service, viewModel) = try await makeAttachedService(
            window: window,
            sessionID: sessionID
        )

        let attached = try await service.execute(args: [
            "op": .string("attach"),
            "session_id": .string(sessionID.uuidString)
        ])
        let attachObject = try XCTUnwrap(attached.objectValue)
        XCTAssertEqual(attachObject["attached"]?.boolValue, true)
        XCTAssertNotNil(attachObject["replay"]?.stringValue)
        XCTAssertNotNil(attachObject["generation"]?.stringValue)
        XCTAssertEqual(attachObject["session_id"]?.stringValue?.lowercased(), sessionID.uuidString.lowercased())

        let polled = try await service.execute(args: [
            "op": .string("poll"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(polled.objectValue?["session_id"]?.stringValue?.lowercased(), sessionID.uuidString.lowercased())
        XCTAssertNotEqual(polled.objectValue?["status"]?.stringValue, "expired")

        let detached = try await service.execute(args: [
            "op": .string("detach"),
            "session_id": .string(sessionID.uuidString)
        ])
        XCTAssertEqual(detached.objectValue?["attached"]?.boolValue, false)
        XCTAssertNil(viewModel.mcpControlledSession(sessionID: sessionID))

        let list = try await writer.listSessions()
        XCTAssertEqual(list.sessions.first { $0.sessionId == started.sessionId }?.status, .running)
    }

    func testAttachResumeCursorIsAccepted() async throws {
        try harness.startServer()
        let writer = try await harness.connect()
        let started = try await harness.startSession(writer)
        let sessionID = try XCTUnwrap(UUID(uuidString: started.sessionId))
        _ = try await harness.waitUntilTurnSettled(
            client: writer,
            sessionID: started.sessionId,
            reader: AgentSessionHostTestHarness.EventReader(writer)
        )

        let window = try makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let (service, _) = try await makeAttachedService(window: window, sessionID: sessionID)

        let first = try await service.execute(args: [
            "op": .string("attach"),
            "session_id": .string(sessionID.uuidString)
        ])
        let generation = try XCTUnwrap(first.objectValue?["generation"]?.stringValue)
        let cursor = first.objectValue?["delivery_cursor"]?.intValue ?? 0

        let resumed = try await service.execute(args: [
            "op": .string("attach"),
            "session_id": .string(sessionID.uuidString),
            "resume_cursor": .int(cursor),
            "resume_generation": .string(generation)
        ])
        XCTAssertEqual(resumed.objectValue?["attached"]?.boolValue, true)
        XCTAssertTrue(["complete", "partial", "unavailable"].contains(resumed.objectValue?["replay"]?.stringValue ?? ""))
    }

    func testMCPAttachSharesSessionWithGUIConnection() async throws {
        try harness.startServer(script: AgentSessionScriptedExecutorScript(autoCompleteTurns: false))
        let writer = try await harness.connect()
        let started = try await harness.startSession(writer)
        let sessionID = try XCTUnwrap(UUID(uuidString: started.sessionId))

        let guiClient = try await harness.connect()
        let gui = HostAgentSessionConnection(client: guiClient)
        let guiAttach = try await gui.attach(sessionID: sessionID, resume: nil)
        XCTAssertEqual(guiAttach.snapshot.sessionID, sessionID)

        let window = try makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let (service, _) = try await makeAttachedService(window: window, sessionID: sessionID)
        _ = try await service.execute(args: [
            "op": .string("attach"),
            "session_id": .string(sessionID.uuidString)
        ])

        let listed = try await gui.listSessions(includeTerminal: false, workspaceID: nil)
        XCTAssertGreaterThanOrEqual(listed.first { $0.sessionID == sessionID }?.attachedClientCount ?? 0, 2)
    }

    func testFenceStringIsGone() async throws {
        try harness.startServer(script: AgentSessionScriptedExecutorScript(autoCompleteTurns: false))
        let writer = try await harness.connect()
        let started = try await harness.startSession(writer)
        let sessionID = try XCTUnwrap(UUID(uuidString: started.sessionId))

        let window = try makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        var (service, viewModel) = try await makeAttachedService(window: window, sessionID: sessionID)
        var dispatched = false
        service.testDispatchSteerInstruction = { _, _, _, _ in
            dispatched = true
            return .startedRun
        }
        viewModel.sessions.values.forEach { $0.runState = .running }

        _ = try await service.execute(args: [
            "op": .string("steer"),
            "session_id": .string(sessionID.uuidString),
            "message": .string("follow-up from MCP")
        ])
        XCTAssertTrue(dispatched)
        XCTAssertNotNil(viewModel.mcpControlledSession(sessionID: sessionID))
    }

    private func makeAttachedService(
        window: WindowState,
        sessionID: UUID
    ) async throws -> (AgentRunMCPToolService, AgentModeViewModel) {
        let client = try await harness.connect()
        let connection = HostAgentSessionConnection(client: client)
        let recorder = LifecycleRecorder()
        let viewModel = AgentModeViewModel(
            testWindowID: window.windowID,
            testSessionConnection: connection,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: recorder)
            }
        )
        let tab = await viewModel.ensureSessionReady(tabID: UUID())
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: tab)
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "agent-run-attach-tests",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("startRun should not be used by attach tests")
            }
        )
        service.testAgentModeViewModel = viewModel
        return (service, viewModel)
    }

    private func makeWindow() throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }
}
