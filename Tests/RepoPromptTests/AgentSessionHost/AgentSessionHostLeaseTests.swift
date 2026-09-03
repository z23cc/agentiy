import AgentryCoreBridge
import Darwin
import RepoPromptDomainRuntime
import XCTest

/// Design §4.1 / §9: exactly one host per user. The `flock` lease is released by the kernel when the
/// holder dies, so a SIGKILLed host never leaves a stale lock behind.
final class AgentSessionHostLeaseTests: XCTestCase {
    private var harness: AgentSessionHostTestHarness!
    private var children: [Process] = []
    private var spawnedHostPIDs: [pid_t] = []

    override func setUpWithError() throws {
        harness = try AgentSessionHostTestHarness()
    }

    override func tearDown() {
        for child in children where child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
        for child in children {
            _ = AgentSessionHostTestHarness.waitForExit(child, timeout: 5)
        }
        children.removeAll()
        for pid in spawnedHostPIDs {
            kill(pid, SIGKILL)
        }
        spawnedHostPIDs.removeAll()
        harness.tearDown()
        harness = nil
    }

    func testSecondAcquisitionInSameProcessIsContended() {
        let owner = AgentSessionHostLeaseOwner(hostInstanceID: "a", buildFingerprint: "fp", socketPath: harness.paths.socketURL.path)
        guard case let .acquired(first) = AgentSessionHostLease.acquire(paths: harness.paths, owner: owner) else {
            return XCTFail("first acquisition must succeed")
        }
        XCTAssertTrue(first.isHeld)
        XCTAssertEqual(AgentSessionHostLease.readOwner(paths: harness.paths)?.hostInstanceID, "a")

        let second = AgentSessionHostLeaseOwner(hostInstanceID: "b", buildFingerprint: "fp", socketPath: harness.paths.socketURL.path)
        guard case let .contended(observed) = AgentSessionHostLease.acquire(paths: harness.paths, owner: second) else {
            return XCTFail("second acquisition must be contended while the first is held")
        }
        XCTAssertEqual(observed?.hostInstanceID, "a")

        first.release()
        XCTAssertFalse(first.isHeld)
        XCTAssertNil(AgentSessionHostLease.readOwner(paths: harness.paths))
        guard case let .acquired(third) = AgentSessionHostLease.acquire(paths: harness.paths, owner: second) else {
            return XCTFail("acquisition after release must succeed")
        }
        third.release()
    }

    func testSecondInProcessServerFailsWithLeaseContended() throws {
        try harness.startServer()
        XCTAssertThrowsError(try harness.startServer()) { error in
            guard case AgentSessionHostServerError.leaseContended = error else {
                return XCTFail("expected leaseContended, got \(error)")
            }
        }
    }

    /// Two real `agentry-mcp agent-host` processes: the second exits 75 while the first lives; after
    /// SIGKILL of the holder a third process acquires the lease and serves the socket.
    func testSecondHostProcessExitsContendedAndSuccessorAcquiresAfterSIGKILL() throws {
        let first = try harness.launchHostProcess()
        children.append(first)
        XCTAssertTrue(harness.waitForSocket(), "first host never published its socket")
        XCTAssertEqual(AgentSessionHostLease.readOwner(paths: harness.paths)?.processID, first.processIdentifier)

        let second = try harness.launchHostProcess()
        children.append(second)
        XCTAssertEqual(AgentSessionHostTestHarness.waitForExit(second), AgentSessionHostExitCode.leaseContended.rawValue)
        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.paths.socketURL.path), "loser must not unlink the winner's socket")

        kill(first.processIdentifier, SIGKILL)
        XCTAssertNotNil(AgentSessionHostTestHarness.waitForExit(first))

        let third = try harness.launchHostProcess()
        children.append(third)
        let deadline = Date().addingTimeInterval(15)
        var acquired = false
        while Date() < deadline {
            if AgentSessionHostLease.readOwner(paths: harness.paths)?.processID == third.processIdentifier,
               FileManager.default.fileExists(atPath: harness.paths.socketURL.path)
            {
                acquired = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(acquired, "successor never acquired the lease after SIGKILL of the holder")
        XCTAssertTrue(third.isRunning)

        // Its socket must be a live host: complete a handshake against it.
        let expectation = expectation(description: "handshake with successor")
        Task {
            defer { expectation.fulfill() }
            do {
                let client = try await AgentSessionHostClient.connect(configuration: harness.clientConfiguration())
                XCTAssertTrue(client.isConnected)
                client.close()
            } catch {
                XCTFail("handshake with successor failed: \(error)")
            }
        }
        wait(for: [expectation], timeout: 15)

        kill(third.processIdentifier, SIGTERM)
        XCTAssertEqual(AgentSessionHostTestHarness.waitForExit(third), AgentSessionHostExitCode.success.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.socketURL.path), "clean exit must unlink the socket")
    }

    func testIdleExitReleasesLeaseAndSocket() throws {
        let host = try harness.launchHostProcess(extraArguments: ["--idle-exit-seconds", "1"])
        children.append(host)
        XCTAssertTrue(harness.waitForSocket())
        XCTAssertEqual(AgentSessionHostTestHarness.waitForExit(host, timeout: 20), AgentSessionHostExitCode.success.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.socketURL.path))
        XCTAssertNil(AgentSessionHostLease.readOwner(paths: harness.paths))
    }

    func testClientSpawnsHostIfAbsentThenReconnectsWithResumeCursor() async throws {
        let executable = try AgentSessionHostTestHarness.agentryMCPExecutableURL()
        let environment = AgentSessionHostLaunchEnvironment.testProcess(from: harness.environment)
        let client = try await AgentSessionHostClient.connect(configuration: harness.clientConfiguration {
            $0.spawn = .spawnIfAbsent(
                executable: executable,
                extraArguments: ["--idle-exit-seconds", "0"],
                environment: environment,
                leaseWait: 15
            )
        })
        harness.track(client)
        XCTAssertTrue(client.isConnected)
        XCTAssertTrue(harness.waitForSocket())
        let ownerPID = try XCTUnwrap(AgentSessionHostLease.readOwner(paths: harness.paths)?.processID)
        spawnedHostPIDs.append(ownerPID)

        let reader = AgentSessionHostTestHarness.EventReader(client)
        let started = try await harness.startSession(client)
        _ = try await client.attach(sessionID: started.sessionId)
        _ = try await reader.readSnapshot(codec: harness.codec)
        let end = try await harness.waitUntilTurnSettled(client: client, sessionID: started.sessionId, reader: reader)

        let (reconnected, attached) = try await client.reconnectAndAttach(
            sessionID: started.sessionId,
            resumeCursor: end,
            resumeGeneration: started.generation
        )
        harness.track(reconnected)
        XCTAssertEqual(attached.replay, .complete)
        XCTAssertFalse(attached.snapshotFollows)
        XCTAssertEqual(attached.nextCursor, end + 1)
        XCTAssertTrue(reconnected.isConnected)
        reconnected.close()
    }

    func testUsageErrorsExitTwo() throws {
        for arguments in [["--idle-exit-seconds"], ["--idle-exit-seconds", "abc"], ["--bogus"]] {
            let process = try harness.launchHostProcess(extraArguments: arguments)
            children.append(process)
            XCTAssertEqual(AgentSessionHostTestHarness.waitForExit(process), AgentSessionHostExitCode.usage.rawValue, "arguments=\(arguments)")
        }
    }
}
