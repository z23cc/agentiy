import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceRustCommandIdentityObserverTests: XCTestCase {
    func testDefaultObserverMatchesRealCorePreparedIdentity() async throws {
        let observer = DomainWorkspaceRustCommandIdentityObserver(metrics: .disabled)
        await observer.start()
        let envelope = command(origin: .appPresentation(windowID: 17))

        observer.sink.observe(
            envelope,
            swiftFingerprint: envelope.fingerprint,
            swiftLatencyNanoseconds: 1
        )

        let didComplete = await waitFor(timeoutIterations: 500) {
            await observer.snapshot().completedCount == 1
        }
        XCTAssertTrue(didComplete)
        let snapshot = await observer.snapshot()
        XCTAssertEqual(snapshot.matchedCount, 1)
        XCTAssertEqual(snapshot.failedCount, 0)
        await observer.shutdown()
    }

    func testPrecomputedRustAuthorityAvoidsASecondProjectorCall() async throws {
        let invocationCounter = CommandIdentityInvocationCounter()
        let observer = DomainWorkspaceRustCommandIdentityObserver(
            metrics: .disabled,
            projector: { _, expected in
                await invocationCounter.increment()
                return expected
            }
        )
        await observer.start()
        let envelope = command()

        observer.sink.observe(
            envelope,
            swiftFingerprint: envelope.fingerprint,
            swiftLatencyNanoseconds: 3,
            authoritativeRustFingerprint: envelope.fingerprint,
            authoritativeRustLatencyNanoseconds: 7
        )

        let didComplete = await waitFor { await observer.snapshot().completedCount == 1 }
        XCTAssertTrue(didComplete)
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(invocationCount, 0)
        let snapshot = await observer.snapshot()
        XCTAssertEqual(snapshot.matchedCount, 1)
        XCTAssertEqual(snapshot.totalSwiftLatencyNanoseconds, 3)
        XCTAssertEqual(snapshot.totalRustLatencyNanoseconds, 7)
        await observer.shutdown()
    }

    func testMatchedComparisonBuildsExplicitCutoverEvidenceAndPrivacySafeMetric() async throws {
        let metrics = CommandIdentityMetricRecorder()
        let observer = DomainWorkspaceRustCommandIdentityObserver(
            metrics: DomainRuntimeMetricsSink { metrics.record($0) },
            projector: { _, expected in expected }
        )
        await observer.start()
        let emptyEvidence = await observer.cutoverEvidence(minimumCompletedCount: 0)
        XCTAssertFalse(emptyEvidence.sampleFloorMet)
        XCTAssertFalse(emptyEvidence.behavioralParityEstablished)
        let envelope = command(origin: .appMCP(connectionID: UUID()))

        observer.sink.observe(
            envelope,
            swiftFingerprint: envelope.fingerprint,
            swiftLatencyNanoseconds: 1
        )

        let didComplete = await waitFor { await observer.snapshot().completedCount == 1 }
        XCTAssertTrue(didComplete)
        let snapshot = await observer.snapshot()
        XCTAssertEqual(snapshot.matchedCount, 1)
        XCTAssertEqual(snapshot.mismatchedCount, 0)
        XCTAssertEqual(snapshot.failedCount, 0)
        XCTAssertEqual(snapshot.droppedCount, 0)
        let evidence = await observer.cutoverEvidence(minimumCompletedCount: 1)
        XCTAssertTrue(evidence.sampleFloorMet)
        XCTAssertTrue(evidence.behavioralParityEstablished)
        XCTAssertEqual(evidence.completedCount, 1)

        let recorded = metrics.snapshot()
        XCTAssertEqual(recorded.count, 1)
        let renderedDimensions = recorded.flatMap(\.dimensions).map { "\($0.key)=\($0.value)" }.joined()
        let workspaceID: UUID
        if case let .saveWorkspaceDocument(identity) = envelope.command {
            workspaceID = identity
        } else {
            XCTFail("unexpected command")
            workspaceID = UUID()
        }
        for forbidden in [
            envelope.operationID.uuidString,
            workspaceID.uuidString,
            envelope.fingerprint,
            "/tmp/"
        ] {
            XCTAssertFalse(renderedDimensions.contains(forbidden))
        }
        await observer.shutdown()
    }

    func testMismatchAndRustFailureRemainDiagnosticsOnly() async throws {
        let observer = DomainWorkspaceRustCommandIdentityObserver(
            metrics: .disabled,
            projector: { input, expected in
                switch input.origin {
                case .standalone:
                    return String(repeating: "0", count: 64)
                case .externalReload:
                    throw CommandIdentityObserverTestError.projectorFailed
                case .appPresentation, .appMCP:
                    return expected
                }
            }
        )
        await observer.start()
        let mismatch = command(origin: .standalone)
        let failed = command(origin: .externalReload)

        observer.sink.observe(
            mismatch,
            swiftFingerprint: mismatch.fingerprint,
            swiftLatencyNanoseconds: 1
        )
        observer.sink.observe(
            failed,
            swiftFingerprint: failed.fingerprint,
            swiftLatencyNanoseconds: 1
        )

        let didComplete = await waitFor { await observer.snapshot().completedCount == 2 }
        XCTAssertTrue(didComplete)
        let snapshot = await observer.snapshot()
        XCTAssertEqual(snapshot.mismatchedCount, 1)
        XCTAssertEqual(snapshot.failedCount, 1)
        let evidence = await observer.cutoverEvidence(minimumCompletedCount: 2)
        XCTAssertTrue(evidence.sampleFloorMet)
        XCTAssertFalse(evidence.behavioralParityEstablished)
        await observer.shutdown()
    }

    func testCountAndBytePressureEvictOnlyPendingSamples() async throws {
        let countGate = CommandIdentityProjectorGate()
        let countObserver = DomainWorkspaceRustCommandIdentityObserver(
            metrics: .disabled,
            limits: .init(
                maximumPendingCommandCount: 2,
                maximumRetainedInputBytes: 16 * 1024,
                maximumCommandBytes: 4 * 1024
            ),
            projector: { input, expected in
                try await countGate.project(input, expectedFingerprint: expected)
            }
        )
        await countObserver.start()
        let first = command()
        countObserver.sink.observe(
            first,
            swiftFingerprint: first.fingerprint,
            swiftLatencyNanoseconds: 1
        )
        let countStarted = await waitFor { await countGate.hasStarted }
        XCTAssertTrue(countStarted)
        for _ in 0 ..< 3 {
            let pending = command()
            countObserver.sink.observe(
                pending,
                swiftFingerprint: pending.fingerprint,
                swiftLatencyNanoseconds: 1
            )
        }
        let countPressure = await countObserver.snapshot()
        XCTAssertTrue(countPressure.hasActiveComparison)
        XCTAssertEqual(countPressure.pendingCommandCount, 2)
        XCTAssertEqual(countPressure.droppedCount, 1)
        await countGate.release()
        let countCompleted = await waitFor { await countObserver.snapshot().completedCount == 3 }
        XCTAssertTrue(countCompleted)
        await countObserver.shutdown()

        let byteGate = CommandIdentityProjectorGate()
        let byteObserver = DomainWorkspaceRustCommandIdentityObserver(
            metrics: .disabled,
            limits: .init(
                maximumPendingCommandCount: 8,
                maximumRetainedInputBytes: 1_300,
                maximumCommandBytes: 1_000
            ),
            projector: { input, expected in
                try await byteGate.project(input, expectedFingerprint: expected)
            }
        )
        await byteObserver.start()
        let active = command()
        byteObserver.sink.observe(
            active,
            swiftFingerprint: active.fingerprint,
            swiftLatencyNanoseconds: 1
        )
        let byteStarted = await waitFor { await byteGate.hasStarted }
        XCTAssertTrue(byteStarted)
        for _ in 0 ..< 2 {
            let pending = command()
            byteObserver.sink.observe(
                pending,
                swiftFingerprint: pending.fingerprint,
                swiftLatencyNanoseconds: 1
            )
        }
        let bytePressure = await byteObserver.snapshot()
        XCTAssertTrue(bytePressure.hasActiveComparison)
        XCTAssertEqual(bytePressure.pendingCommandCount, 1)
        XCTAssertEqual(bytePressure.droppedCount, 1)
        XCTAssertLessThanOrEqual(
            bytePressure.activeInputBytes + bytePressure.pendingInputBytes,
            1_300
        )
        await byteGate.release()
        let byteCompleted = await waitFor { await byteObserver.snapshot().completedCount == 2 }
        XCTAssertTrue(byteCompleted)
        await byteObserver.shutdown()
    }

    func testOversizedCommandIsDroppedWithoutInvokingProjector() async throws {
        let invocations = CommandIdentityInvocationCounter()
        let observer = DomainWorkspaceRustCommandIdentityObserver(
            metrics: .disabled,
            limits: .init(
                maximumPendingCommandCount: 4,
                maximumRetainedInputBytes: 8 * 1024,
                maximumCommandBytes: 1_024
            ),
            projector: { _, expected in
                await invocations.increment()
                return expected
            }
        )
        await observer.start()
        let envelope = createCommand(filePathByteCount: 2_048)

        observer.sink.observe(
            envelope,
            swiftFingerprint: envelope.fingerprint,
            swiftLatencyNanoseconds: 1
        )

        let didDrop = await waitFor { await observer.snapshot().droppedCount == 1 }
        XCTAssertTrue(didDrop)
        let snapshot = await observer.snapshot()
        XCTAssertEqual(snapshot.completedCount, 0)
        XCTAssertEqual(snapshot.pendingCommandCount, 0)
        let invocationCount = await invocations.count
        XCTAssertEqual(invocationCount, 0)
        await observer.shutdown()
    }

    func testCompactIdentityInputDoesNotRetainDocumentPayload() async throws {
        let gate = CommandIdentityProjectorGate()
        let observer = DomainWorkspaceRustCommandIdentityObserver(
            metrics: .disabled,
            limits: .init(
                maximumPendingCommandCount: 2,
                maximumRetainedInputBytes: 2_048,
                maximumCommandBytes: 1_024
            ),
            projector: { input, expected in
                try await gate.project(input, expectedFingerprint: expected)
            }
        )
        await observer.start()
        let envelope = createCommand(filePathByteCount: 16, documentByteCount: 2 * 1024 * 1024)

        observer.sink.observe(
            envelope,
            swiftFingerprint: envelope.fingerprint,
            swiftLatencyNanoseconds: 1
        )

        let didStart = await waitFor { await gate.hasStarted }
        XCTAssertTrue(didStart)
        let active = await observer.snapshot()
        XCTAssertLessThan(active.activeInputBytes, 1_024)
        XCTAssertEqual(active.droppedCount, 0)
        await gate.release()
        let didComplete = await waitFor { await observer.snapshot().completedCount == 1 }
        XCTAssertTrue(didComplete)
        await observer.shutdown()
    }

    func testSuspendedProjectorDoesNotBlockObservationAndShutdownCancelsActiveWork() async throws {
        let gate = CommandIdentityProjectorGate()
        let observer = DomainWorkspaceRustCommandIdentityObserver(
            metrics: .disabled,
            projector: { input, expected in
                try await gate.project(input, expectedFingerprint: expected)
            }
        )
        await observer.start()
        let first = command()
        observer.sink.observe(
            first,
            swiftFingerprint: first.fingerprint,
            swiftLatencyNanoseconds: 1
        )
        let didStart = await waitFor { await gate.hasStarted }
        XCTAssertTrue(didStart)
        let second = command()

        let start = DispatchTime.now().uptimeNanoseconds
        observer.sink.observe(
            second,
            swiftFingerprint: second.fingerprint,
            swiftLatencyNanoseconds: 1
        )
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start

        XCTAssertLessThan(elapsed, 100_000_000)
        let pendingCount = await observer.snapshot().pendingCommandCount
        XCTAssertEqual(pendingCount, 1)
        await observer.shutdown()
        let late = command()
        observer.sink.observe(
            late,
            swiftFingerprint: late.fingerprint,
            swiftLatencyNanoseconds: 1
        )
        let stopped = await observer.snapshot()
        XCTAssertFalse(stopped.isAcceptingObservations)
        XCTAssertFalse(stopped.hasActiveComparison)
        XCTAssertEqual(stopped.pendingCommandCount, 0)
        XCTAssertEqual(stopped.completedCount, 0)
        XCTAssertEqual(stopped.droppedCount, 3)
        XCTAssertEqual(stopped.ignoredLateResultCount, 0)
        let stoppedEvidence = await observer.cutoverEvidence(minimumCompletedCount: 1)
        XCTAssertFalse(stoppedEvidence.behavioralParityEstablished)
    }

    func testPrecomputedRuntimeAuthorityBypassesSuspendedComparisonProjector() async throws {
        let directory = temporaryDirectory(name: "command-identity-nonblocking")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CommandIdentityProjectorGate()
        let runtime = MCPDomainRuntime(
            configuration: configuration(directory: directory),
            workspaceProjectionProjector: { _ in
                throw CommandIdentityObserverTestError.projectorFailed
            },
            workspaceCommandIdentityProjector: { input, expected in
                try await gate.project(input, expectedFingerprint: expected)
            }
        )
        try await runtime.start()
        let document = try workspaceDocument(directory: directory)
        let envelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(document)
        )
        let completion = CommandIdentityCommandCompletion()
        let commandTask = Task {
            let outcome = await runtime.workspaceStore.execute(envelope)
            await completion.finish(outcome)
            return outcome
        }

        let commandFinished = await waitFor(timeoutIterations: 500) { await completion.isFinished }
        XCTAssertTrue(commandFinished)
        let outcome = await commandTask.value
        XCTAssertEqual(outcome.operationID, envelope.operationID)
        let comparisonCompleted = await waitFor(timeoutIterations: 500) {
            await runtime.workspaceRustCommandIdentityObserver.snapshot().completedCount == 1
        }
        XCTAssertTrue(comparisonCompleted)
        let comparisonProjectorStarted = await gate.hasStarted
        XCTAssertFalse(comparisonProjectorStarted, "precomputed Rust authority must avoid a second Rust call")
        _ = await runtime.shutdown()
        let stopped = await runtime.workspaceRustCommandIdentityObserver.snapshot()
        XCTAssertEqual(stopped.matchedCount, 1)
        XCTAssertEqual(stopped.droppedCount, 0)
        let evidence = await runtime.workspaceRustCommandIdentityObserver.cutoverEvidence(
            minimumCompletedCount: 1
        )
        XCTAssertTrue(evidence.behavioralParityEstablished)
    }

    func testProductionDeduplicationAndCollisionUseInjectedRustIdentity() async throws {
        let directory = temporaryDirectory(name: "command-identity-authority")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = CommandIdentityResolverScript(steps: [
            .value(String(repeating: "a", count: 64)),
            .value(String(repeating: "b", count: 64))
        ])
        let runtime = MCPDomainRuntime(
            configuration: configuration(directory: directory),
            workspaceProjectionProjector: { _ in
                throw CommandIdentityObserverTestError.projectorFailed
            },
            workspaceCommandIdentityResolver: { input in
                try await resolver.resolve(input)
            }
        )
        try await runtime.start()
        let envelope = command()

        let first = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(first.disposition, .invalid)
        XCTAssertEqual(first.errorCode, .workspaceUnavailable)
        let second = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(second.disposition, .invalid)
        XCTAssertEqual(second.errorCode, .operationIDCollision)
        let invocationCount = await resolver.invocationCount
        XCTAssertEqual(invocationCount, 2)
        _ = await runtime.shutdown()
    }

    func testRustIdentityFailureDoesNotRecordOperationAndRetryCanProceed() async throws {
        let directory = temporaryDirectory(name: "command-identity-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rustFingerprint = String(repeating: "c", count: 64)
        let resolver = CommandIdentityResolverScript(steps: [
            .failure,
            .value(rustFingerprint),
            .value(rustFingerprint)
        ])
        let runtime = MCPDomainRuntime(
            configuration: configuration(directory: directory),
            workspaceProjectionProjector: { _ in
                throw CommandIdentityObserverTestError.projectorFailed
            },
            workspaceCommandIdentityResolver: { input in
                try await resolver.resolve(input)
            }
        )
        try await runtime.start()
        let envelope = command()

        let rejected = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(rejected.disposition, .readOnly)
        XCTAssertEqual(rejected.errorCode, .runtimeReadOnlyDegraded)
        XCTAssertEqual(rejected.diagnostic, "workspace_command_identity_rust_unavailable")
        let retried = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(retried.disposition, .invalid)
        XCTAssertEqual(retried.errorCode, .workspaceUnavailable)
        let deduplicated = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(deduplicated.disposition, .deduplicated)
        XCTAssertEqual(deduplicated.errorCode, .workspaceUnavailable)
        _ = await runtime.shutdown()
    }

    func testCancellationAfterResolverSuccessDoesNotRecordOperation() async throws {
        let directory = temporaryDirectory(name: "command-identity-cancelled")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = CommandIdentityCancellationResolver()
        let runtime = MCPDomainRuntime(
            configuration: configuration(directory: directory),
            workspaceProjectionProjector: { _ in
                throw CommandIdentityObserverTestError.projectorFailed
            },
            workspaceCommandIdentityResolver: { input in
                await resolver.resolve(input)
            }
        )
        try await runtime.start()
        let envelope = command()
        let cancelledTask = Task { await runtime.workspaceStore.execute(envelope) }
        let resolverStarted = await waitFor { await resolver.hasStarted }
        XCTAssertTrue(resolverStarted)

        cancelledTask.cancel()
        await resolver.release()
        let cancelled = await cancelledTask.value
        XCTAssertEqual(cancelled.disposition, .failed)
        XCTAssertEqual(cancelled.errorCode, .cancelled)
        XCTAssertEqual(cancelled.diagnostic, "workspace_command_identity_cancelled")

        let retried = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(retried.disposition, .invalid)
        XCTAssertEqual(retried.errorCode, .workspaceUnavailable)
        _ = await runtime.shutdown()
    }

    func testRuntimeLifecycleStartsAndStopsObserver() async throws {
        let directory = temporaryDirectory(name: "command-identity-lifecycle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MCPDomainRuntime(
            configuration: configuration(directory: directory),
            workspaceProjectionProjector: { _ in
                throw CommandIdentityObserverTestError.projectorFailed
            },
            workspaceCommandIdentityProjector: { _, expected in expected }
        )

        try await runtime.start()
        let running = await runtime.workspaceRustCommandIdentityObserver.snapshot()
        XCTAssertTrue(running.isAcceptingObservations)
        _ = await runtime.shutdown()
        let stopped = await runtime.workspaceRustCommandIdentityObserver.snapshot()
        XCTAssertFalse(stopped.isAcceptingObservations)
    }

    private func command(
        origin: DomainCommandOrigin = .standalone
    ) -> DomainWorkspaceCommandEnvelope {
        DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: 1,
            origin: origin,
            command: .saveWorkspaceDocument(workspaceID: UUID())
        )
    }

    private func createCommand(
        filePathByteCount: Int,
        documentByteCount: Int = 8
    ) -> DomainWorkspaceCommandEnvelope {
        let workspaceID = UUID()
        let document = DomainWorkspaceDocument(
            workspaceID: workspaceID,
            fileURL: URL(fileURLWithPath: "/tmp/\(String(repeating: "x", count: filePathByteCount)).json"),
            documentBytes: Data(repeating: 7, count: documentByteCount),
            metadata: DomainWorkspaceMetadata(
                workspaceID: workspaceID,
                schemaVersion: 1,
                name: "Workspace",
                repoPaths: [],
                customStoragePath: nil,
                isSystemWorkspace: false,
                isHiddenInMenus: false,
                isEphemeral: false,
                activeContextID: nil,
                contexts: []
            )
        )
        return DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            origin: .standalone,
            command: .createWorkspace(document)
        )
    }

    private func workspaceDocument(directory: URL) throws -> DomainWorkspaceDocument {
        let workspaceID = UUID()
        let contextID = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Command Identity",
            "repoPaths": [],
            "activeComposeTabID": contextID.uuidString,
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": "observer",
                "selectedPaths": []
            ]]
        ], options: [.sortedKeys])
        return try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: directory.appendingPathComponent("workspace.json")
        )
    }

    private func configuration(directory: URL) -> DomainRuntimeConfiguration {
        DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "command-identity-observer-\(UUID().uuidString)",
            storageDirectory: directory,
            eventDirectory: directory.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: directory.appendingPathComponent("Temp", isDirectory: true),
            externalReloadInterval: nil
        )
    }

    private func temporaryDirectory(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPrompt-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func waitFor(
        timeoutIterations: Int = 200,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< timeoutIterations {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private enum CommandIdentityObserverTestError: Error {
    case projectorFailed
}

private final class CommandIdentityMetricRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: [DomainRuntimeMetric] = []

    func record(_ metric: DomainRuntimeMetric) {
        lock.withLock {
            metrics.append(metric)
        }
    }

    func snapshot() -> [DomainRuntimeMetric] {
        lock.withLock { metrics }
    }
}

private actor CommandIdentityProjectorGate {
    private(set) var hasStarted = false
    private var isReleased = false

    func project(
        _: DomainWorkspaceCommandIdentityInput,
        expectedFingerprint: String
    ) async throws -> String {
        hasStarted = true
        while !isReleased {
            try await Task.sleep(for: .milliseconds(10))
        }
        return expectedFingerprint
    }

    func release() {
        isReleased = true
    }
}

private actor CommandIdentityCommandCompletion {
    private(set) var outcome: DomainCommandOutcome?

    var isFinished: Bool {
        outcome != nil
    }

    func finish(_ outcome: DomainCommandOutcome) {
        self.outcome = outcome
    }
}

private actor CommandIdentityInvocationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private actor CommandIdentityCancellationResolver {
    private(set) var hasStarted = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var invocationCount = 0

    func resolve(_: DomainWorkspaceCommandIdentityInput) async -> String {
        invocationCount += 1
        if invocationCount == 1 {
            hasStarted = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            return String(repeating: "d", count: 64)
        }
        return String(repeating: "e", count: 64)
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CommandIdentityResolverScript {
    enum Step: Sendable {
        case value(String)
        case failure
    }

    private var steps: [Step]
    private(set) var invocationCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func resolve(_: DomainWorkspaceCommandIdentityInput) throws -> String {
        invocationCount += 1
        guard !steps.isEmpty else {
            throw CommandIdentityObserverTestError.projectorFailed
        }
        switch steps.removeFirst() {
        case let .value(value):
            return value
        case .failure:
            throw CommandIdentityObserverTestError.projectorFailed
        }
    }
}
