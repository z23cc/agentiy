import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// ADR-0011 P3: `HostAgentSessionConnection` maps proto attach/replay/uncertain/resnapshot
/// and quit=detach onto the P1.5 seam. Uses the in-process host + scripted executor.
final class HostAgentSessionConnectionTests: XCTestCase {
    private var harness: AgentSessionHostTestHarness!

    override func setUpWithError() throws {
        harness = try AgentSessionHostTestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    private func makeConnection(
        script: AgentSessionScriptedExecutorScript = AgentSessionScriptedExecutorScript()
    ) async throws -> (HostAgentSessionConnection, AgentSessionHostClient) {
        try harness.startServer(script: script)
        let client = try await harness.connect()
        return (HostAgentSessionConnection(client: client), client)
    }

    private func startSpec(sessionID: UUID? = nil, text: String = "hello") -> AgentSessionStartSpec {
        AgentSessionStartSpec(
            tabID: UUID(),
            resumeSessionID: sessionID,
            message: AgentSessionUserMessage(text: text),
            provider: .claudeCode,
            modelRaw: "sonnet",
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-00000000aa01")
        )
    }

    private func collectEvents(
        _ connection: HostAgentSessionConnection,
        timeout: TimeInterval = 10,
        until stop: (AgentSessionConnectionEvent) -> Bool
    ) async throws -> [AgentSessionConnectionEvent] {
        var batch: [AgentSessionConnectionEvent] = []
        let stream = await connection.events
        var iterator = stream.makeAsyncIterator()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = max(0.05, deadline.timeIntervalSinceNow)
            let event: AgentSessionConnectionEvent? = await withTaskGroup(of: AgentSessionConnectionEvent?.self) { group in
                group.addTask { await iterator.next() }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? nil
            }
            guard let event else { break }
            batch.append(event)
            if stop(event) { return batch }
        }
        throw AgentSessionHostTestHarness.HarnessError.timeout("condition not met; saw \(batch.count) events")
    }

    func testAttachReplayCompletePartialUnavailable() async throws {
        try harness.startServer()
        let writer = try await harness.connect()
        let started = try await harness.startSession(writer)
        let sessionID = try XCTUnwrap(UUID(uuidString: started.sessionId))

        let client = try await harness.connect()
        let connection = HostAgentSessionConnection(client: client)
        let fresh = try await connection.attach(sessionID: sessionID, resume: nil)
        XCTAssertEqual(fresh.replay, .complete)
        XCTAssertEqual(fresh.snapshot.sessionID, sessionID)
        XCTAssertFalse(fresh.cursor.generation.isEmpty)

        // Attach result cursor is `nextCursor` (one past the last log entry). Resume from the
        // last applied delivery cursor so the host can declare a complete replay.
        let lastApplied = AgentSessionCursor(
            generation: fresh.cursor.generation,
            deliveryCursor: fresh.cursor.deliveryCursor == 0 ? 0 : fresh.cursor.deliveryCursor - 1
        )
        let caughtUp = try await connection.attach(sessionID: sessionID, resume: lastApplied)
        XCTAssertEqual(caughtUp.replay, .complete)

        let ahead = AgentSessionCursor(generation: fresh.cursor.generation, deliveryCursor: fresh.cursor.deliveryCursor + 50)
        let partial = try await connection.attach(sessionID: sessionID, resume: ahead)
        XCTAssertEqual(partial.replay, .partial)

        let otherGeneration = AgentSessionCursor(generation: Data([1, 2, 3, 4]), deliveryCursor: 1)
        let unavailable = try await connection.attach(sessionID: sessionID, resume: otherGeneration)
        XCTAssertEqual(unavailable.replay, .unavailable)
    }

    func testStartThenSteerOnExistingSession() async throws {
        let (connection, _) = try await makeConnection()
        async let settled = collectEvents(connection, timeout: 5) { event in
            if case .commandSettled = event { return true }
            return false
        }
        let started = try await connection.start(startSpec(), operationID: UUID())
        XCTAssertEqual(started.sendOutcome, .accepted)
        XCTAssertFalse(started.cursor.generation.isEmpty)

        let again = try await connection.start(
            startSpec(sessionID: started.sessionID, text: "follow-up"),
            operationID: UUID()
        )
        XCTAssertEqual(again.sessionID, started.sessionID)
        _ = try await settled
    }

    func testSteerAfterHostDropReportsUncertain() async throws {
        let (connection, _) = try await makeConnection()
        let started = try await connection.start(startSpec(), operationID: UUID())
        harness.stopServers()
        do {
            _ = try await connection.steer(
                sessionID: started.sessionID,
                message: AgentSessionUserMessage(text: "after drop"),
                operationID: UUID()
            )
            XCTFail("expected uncertain")
        } catch let error as AgentSessionConnectionError {
            guard case .uncertain = error else {
                return XCTFail("expected uncertain, got \(error)")
            }
        }
    }

    func testResnapshotRequiredAfterRecoveredSteer() async throws {
        try harness.startServer(script: AgentSessionScriptedExecutorScript(autoCompleteTurns: true))
        let writer = try await harness.connect()
        let started = try await harness.startSession(writer)
        let sessionID = try XCTUnwrap(UUID(uuidString: started.sessionId))
        let staleCursor = AgentSessionCursor(generation: started.generation, deliveryCursor: 1)
        _ = try await harness.waitUntilTurnSettled(
            client: writer,
            sessionID: started.sessionId,
            reader: AgentSessionHostTestHarness.EventReader(writer)
        )
        writer.close()
        harness.stopServers()
        try harness.startServer()

        let client = try await harness.connect()
        let connection = HostAgentSessionConnection(client: client)
        let unavailable = try await connection.attach(sessionID: sessionID, resume: staleCursor)
        XCTAssertEqual(unavailable.replay, .unavailable)

        async let resnapshot = collectEvents(connection, timeout: 5) { event in
            if case let .resnapshotRequired(id) = event, id == sessionID { return true }
            return false
        }
        _ = try await connection.steer(
            sessionID: sessionID,
            message: AgentSessionUserMessage(text: "resume"),
            operationID: UUID()
        )
        _ = try await resnapshot
    }

    func testQuitDetachLeavesProviderRunning() async throws {
        let (connection, _) = try await makeConnection(
            script: AgentSessionScriptedExecutorScript(streamChunksPerTurn: 1, autoCompleteTurns: false)
        )
        let started = try await connection.start(startSpec(), operationID: UUID())
        _ = try await connection.attach(sessionID: started.sessionID, resume: nil)
        await connection.detachAll()

        let observer = try await harness.connect()
        let list = try await observer.listSessions()
        let summary = list.sessions.first { $0.sessionId == started.sessionID.uuidString.lowercased() }
        XCTAssertEqual(summary?.status, .running, "detach must not stop the hosted run")
        XCTAssertEqual(summary?.attachedClientCount, 0)
    }

    func testPrepareUpdateRefuseWhenCheckpointFails() async throws {
        try harness.startServer()
        let writer = try await harness.connect()
        _ = try await harness.startSession(writer)
        let victim = try await harness.startSession(writer, spec: AgentSessionHostTestHarness.spec(workspaceID: "ws-readonly"))
        let directory = try harness.paths.sessionDirectory(workspaceID: "ws-readonly")
        let names = try harness.codec.sessionLogFileNames(sessionID: victim.sessionId)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(names.snapshot))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: directory.path), "running with privileges that ignore directory modes")

        let client = try await harness.connect()
        let connection = HostAgentSessionConnection(client: client)
        let prepared = try await connection.prepareHostUpdate()
        XCTAssertFalse(prepared.allCheckpointed)

        let after = try await harness.startSession(writer, spec: AgentSessionHostTestHarness.spec(workspaceID: "ws-after-refuse"))
        XCTAssertFalse(after.sessionId.isEmpty, "refused prepare_update must leave the host running")
    }

    func testLegacyJSONImportWritesEventLogAndAttachSeesTranscript() async throws {
        let workspaceID = UUID()
        let sessionID = UUID()
        let folder = DomainWorkspaceStoragePath.directoryName(name: "Demo", id: workspaceID)
        let directory = harness.paths.workspacesRoot
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(AgentSessionHostPaths.agentSessionsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "id": sessionID.uuidString,
            "name": "Imported demo",
            "workspaceID": workspaceID.uuidString,
            "agentKind": "claudeCode",
            "agentModel": "sonnet",
            "lastRunState": "completed",
            "items": [
                ["id": UUID().uuidString, "kind": "user", "text": "hello from json"],
                ["id": UUID().uuidString, "kind": "assistant", "text": "imported reply"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: directory.appendingPathComponent("AgentSession-\(sessionID.uuidString).json"))

        try harness.startServer()
        XCTAssertTrue(
            harness.servers.first?.recoveryReport.importedSessionIDs.contains(sessionID.uuidString.lowercased()) == true,
            "recover() must import AgentSession JSON that has no event log"
        )

        let client = try await harness.connect()
        let connection = HostAgentSessionConnection(client: client)
        let attached = try await connection.attach(sessionID: sessionID, resume: nil)
        XCTAssertEqual(attached.replay, .complete)
        XCTAssertEqual(attached.snapshot.sessionID, sessionID)
        XCTAssertTrue(
            attached.snapshot.items.contains { $0.text.contains("hello from json") },
            "imported log must surface the legacy user message"
        )
        XCTAssertTrue(
            attached.snapshot.items.contains { $0.text.contains("imported reply") }
                || attached.snapshot.modelRaw == "sonnet",
            "imported log must surface the assistant reply or model metadata"
        )

        let names = try harness.codec.sessionLogFileNames(sessionID: sessionID.uuidString.lowercased())
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(names.events).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("AgentSession-\(sessionID.uuidString).json").path))
    }

    func testTwoConnectionsAttachSameSession() async throws {
        try harness.startServer()
        let writer = try await harness.connect()
        let started = try await harness.startSession(writer)
        let sessionID = try XCTUnwrap(UUID(uuidString: started.sessionId))

        let firstClient = try await harness.connect()
        let first = HostAgentSessionConnection(client: firstClient)
        let firstAttach = try await first.attach(sessionID: sessionID, resume: nil)
        XCTAssertEqual(firstAttach.snapshot.sessionID, sessionID)

        let secondClient = try await harness.connect()
        let second = HostAgentSessionConnection(client: secondClient)
        let secondAttach = try await second.attach(sessionID: sessionID, resume: nil)
        XCTAssertEqual(secondAttach.snapshot.sessionID, sessionID)
        XCTAssertEqual(secondAttach.snapshot.runState, firstAttach.snapshot.runState)

        let listed = try await first.listSessions(includeTerminal: false, workspaceID: nil)
        XCTAssertEqual(listed.first { $0.sessionID == sessionID }?.attachedClientCount, 2)
    }

    func testProductionConfigurationSpawnsRustHostNotSwiftMCP() throws {
        let configuration = HostAgentSessionConnection.Configuration.makeProductionConfiguration()
        guard case let .spawnIfAbsent(executable, extraArguments, spawnedEnvironment, _) = configuration.client.spawn else {
            throw XCTSkip("Rust agent-host binary is not on the spawn path")
        }
        XCTAssertTrue(
            AgentSessionHostExecutable.isRustAgentHost(executable),
            "production spawn must be the Rust host (\(executable.path))"
        )
        XCTAssertFalse(
            AgentSessionHostExecutable.looksLikeSwiftMCPCLI(executable),
            "production must not spawn the Swift RepoPromptMCP CLI (\(executable.path))"
        )
        XCTAssertEqual(extraArguments, [])
        let environment = try XCTUnwrap(spawnedEnvironment)
        XCTAssertEqual(environment[AgentSessionHostLaunchEnvironment.liveFlagKey], "1")
        XCTAssertEqual(
            environment[AgentSessionHostLaunchEnvironment.fingerprintKey],
            CoreBuildIdentity.buildFingerprint
        )
        XCTAssertNil(environment[AgentSessionHostLaunchEnvironment.acceptAnyPeerKey])
        XCTAssertNil(environment["AGENTRY_AGENT_HOST_READ_KEYCHAIN"])
        XCTAssertEqual(environment[AgentSessionHostLaunchEnvironment.mcpBackendKey], "auto")
    }

    func testStartDoesNotWriteCompatibilityJSON() async throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000aa01"))
        let (connection, _) = try await makeConnection()
        let started = try await connection.start(startSpec(sessionID: nil), operationID: UUID())
        let directory = try harness.paths.resolvedSessionDirectory(workspaceID: workspaceID.uuidString.lowercased())
        let names = try harness.codec.sessionLogFileNames(sessionID: started.sessionID.uuidString.lowercased())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(names.events).path),
            "host must write .events"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("AgentSession-\(started.sessionID.uuidString).json").path
            ),
            "P4 must not write AgentSession-*.json on a new turn"
        )
    }
}
