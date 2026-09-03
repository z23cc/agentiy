import AgentryCoreBridge
import RepoPromptDomainRuntime
import XCTest

/// Design §4.4 / §9: `prepare_update` checkpoints (`sync` + `compact`) every session and refuses when
/// any checkpoint fails; success stops new sessions and notifies clients.
final class AgentSessionHostUpdateTests: XCTestCase {
    private var harness: AgentSessionHostTestHarness!
    private var restorePermissions: [(URL, Int)] = []

    override func setUpWithError() throws {
        harness = try AgentSessionHostTestHarness()
    }

    override func tearDown() {
        for (url, mode) in restorePermissions {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        restorePermissions.removeAll()
        harness.tearDown()
        harness = nil
    }

    private func prepareUpdate(_ client: AgentSessionHostClient, operationID: String = UUID().uuidString.lowercased(), deadline: UInt32 = 5) async throws -> AgentHostCommandResponseOutcomeV1 {
        try await client.send(.hostControl(AgentHostHostControlV1(
            key: AgentSessionHostClient.mutationKey(operationID: operationID),
            action: .prepareUpdate(AgentHostPrepareUpdateV1(deadlineSeconds: deadline))
        )))
    }

    private func prepareUpdateResult(_ outcome: AgentHostCommandResponseOutcomeV1) throws -> AgentHostPrepareUpdateResultV1 {
        guard case let .result(result) = outcome, case let .hostControl(control) = result.result,
              case let .prepareUpdate(prepared) = control.result
        else { throw AgentSessionHostTestHarness.HarnessError.unexpectedOutcome(String(describing: outcome)) }
        return prepared
    }

    func testPrepareUpdateCheckpointsEverySessionAndStopsNewSessions() async throws {
        try harness.startServer()
        let client = try await harness.connect()
        let reader = AgentSessionHostTestHarness.EventReader(client)
        let first = try await harness.startSession(client)
        let second = try await harness.startSession(client, spec: AgentSessionHostTestHarness.spec(workspaceID: "ws-other"))

        let prepared = try await prepareUpdateResult(prepareUpdate(client))
        XCTAssertTrue(prepared.allCheckpointed)
        XCTAssertEqual(Set(prepared.checkpoints.map(\.sessionId)), [first.sessionId, second.sessionId])
        XCTAssertTrue(prepared.checkpoints.allSatisfy(\.succeeded))
        for checkpoint in prepared.checkpoints {
            let workspace = checkpoint.sessionId == first.sessionId ? "ws-test" : "ws-other"
            let names = try harness.codec.sessionLogFileNames(sessionID: checkpoint.sessionId)
            let snapshotPath = try harness.paths.sessionDirectory(workspaceID: workspace).appendingPathComponent(names.snapshot).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath), "compact must write \(names.snapshot)")
        }

        let notices = try await reader.collect { event in
            if case let .notice(notice) = event, notice.kind == .updatePending { return true }
            return false
        }
        XCTAssertFalse(notices.isEmpty)

        let refused = try await client.send(.start(AgentHostStartV1(key: AgentSessionHostClient.mutationKey(), spec: AgentSessionHostTestHarness.spec())))
        guard case let .rejected(rejected) = refused else { return XCTFail("expected rejection, got \(refused)") }
        XCTAssertEqual(rejected.reason, .hostShuttingDown)

        // Existing sessions still serve reads.
        let list = try await client.listSessions()
        XCTAssertEqual(list.sessions.count, 2)
    }

    func testPrepareUpdateIsRefusedWhenAnyCheckpointFails() async throws {
        try harness.startServer()
        let client = try await harness.connect()
        _ = try await harness.startSession(client)
        let victim = try await harness.startSession(client, spec: AgentSessionHostTestHarness.spec(workspaceID: "ws-readonly"))

        // Make the victim's directory unwritable so `compact` cannot create its snapshot file.
        let directory = try harness.paths.sessionDirectory(workspaceID: "ws-readonly")
        let names = try harness.codec.sessionLogFileNames(sessionID: victim.sessionId)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(names.snapshot))
        restorePermissions.append((directory, 0o700))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: directory.path), "running with privileges that ignore directory modes")

        let prepared = try await prepareUpdateResult(prepareUpdate(client))
        XCTAssertFalse(prepared.allCheckpointed, "one failed checkpoint refuses the update")
        XCTAssertEqual(prepared.checkpoints.count, 2)
        let failed = prepared.checkpoints.first { !$0.succeeded }
        XCTAssertEqual(failed?.sessionId, victim.sessionId)
        XCTAssertFalse(failed?.detail.isEmpty ?? true)
        XCTAssertTrue(prepared.checkpoints.contains { $0.succeeded && $0.sessionId != victim.sessionId })

        // Refusal keeps the host open for business.
        let started = try await harness.startSession(client, spec: AgentSessionHostTestHarness.spec(workspaceID: "ws-after"))
        XCTAssertFalse(started.sessionId.isEmpty)
    }

    func testHostControlIsIdempotentByOperationID() async throws {
        try harness.startServer()
        let client = try await harness.connect()
        _ = try await harness.startSession(client)
        let operationID = UUID().uuidString.lowercased()
        let first = try await prepareUpdateResult(prepareUpdate(client, operationID: operationID))
        let again = try await prepareUpdateResult(prepareUpdate(client, operationID: operationID))
        XCTAssertEqual(first, again, "same operation id + same arguments replays the recorded result")

        let conflict = try await prepareUpdate(client, operationID: operationID, deadline: 99)
        guard case let .operationConflict(details) = conflict else { return XCTFail("expected operationConflict, got \(conflict)") }
        XCTAssertEqual(details.operationId, operationID)
        XCTAssertNotEqual(details.recordedFingerprint, details.submittedFingerprint)
    }

    func testShutdownCommandStopsHostAndNotifiesClients() async throws {
        let server = try harness.startServer()
        let client = try await harness.connect()
        let reader = AgentSessionHostTestHarness.EventReader(client)
        let outcome = try await client.send(.hostControl(AgentHostHostControlV1(
            key: AgentSessionHostClient.mutationKey(),
            action: .shutdown(AgentHostShutdownV1(mode: .graceful, deadlineSeconds: 1))
        )))
        guard case let .result(result) = outcome, case let .hostControl(control) = result.result,
              case let .shutdown(accepted) = control.result
        else { return XCTFail("expected shutdown accepted, got \(outcome)") }
        XCTAssertNotNil(AgentSessionHostClock.date(rfc3339: accepted.deadlineAt))

        let deadline = Date().addingTimeInterval(10)
        while server.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let events = try await reader.collect { event in
            if case .disconnected = event { return true }
            return false
        }
        XCTAssertTrue(events.contains { if case let .notice(notice) = $0 { notice.kind == .shuttingDown } else { false } })
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.socketURL.path))
        XCTAssertNil(AgentSessionHostLease.readOwner(paths: harness.paths))
    }
}
