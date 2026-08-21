import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentryCoreServiceTests: XCTestCase {
    func testConcurrentFirstRequestsShareOneStartupTaskAndRuntimeInstance() async throws {
        let runtime = AgentryCoreServiceTestRuntime()
        let gate = AgentryCoreServiceTestGate()
        let probe = AgentryCoreServiceTestProbe()
        let service = AgentryCoreService(
            startOperation: {
                await probe.recordStart()
                await gate.arriveAndWait()
                return runtime
            },
            shutdownOperation: { runtime in
                await probe.recordShutdown()
                try await runtime.shutdownCoreRuntime()
            }
        )

        let requests = (0 ..< 32).map { _ in
            Task { try await service.runtime() }
        }
        await gate.waitUntilArrived()
        let startsWhileBlocked = await probe.startCount
        XCTAssertEqual(startsWhileBlocked, 1)

        await gate.release()
        var identities: [ObjectIdentifier] = []
        for request in requests {
            try await identities.append(ObjectIdentifier(request.value))
        }
        XCTAssertEqual(Set(identities).count, 1)
        let finalStartCount = await probe.startCount
        XCTAssertEqual(finalStartCount, 1)

        await service.shutdown()
        let shutdownCount = await probe.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertTrue(runtime.isStopped)
    }

    func testStartupFailureIsCachedAsInfrastructureErrorWithoutRetry() async {
        let probe = AgentryCoreServiceTestProbe()
        let service = AgentryCoreService(startOperation: {
            await probe.recordStart()
            throw AgentryCoreServiceTestFailure.startup
        })

        for _ in 0 ..< 2 {
            do {
                _ = try await service.searchClient()
                XCTFail("Expected cached search infrastructure failure")
            } catch let error as AgentryCoreService.ServiceError {
                guard case let .searchInfrastructureUnavailable(description) = error else {
                    return XCTFail("Expected infrastructure-unavailable error, got \(error)")
                }
                XCTAssertTrue(description.contains("AgentryCoreServiceTestFailure.startup"))
            } catch {
                XCTFail("Expected service error, got \(error)")
            }
        }

        let startCount = await probe.startCount
        XCTAssertEqual(startCount, 1)
        await service.shutdown()
        let startCountAfterShutdown = await probe.startCount
        XCTAssertEqual(startCountAfterShutdown, 1, "Shutdown must not retry failed startup")
    }

    func testShutdownIsIdempotentAndStopsFutureAccess() async throws {
        let runtime = AgentryCoreServiceTestRuntime()
        let probe = AgentryCoreServiceTestProbe()
        let service = AgentryCoreService(
            startOperation: { runtime },
            shutdownOperation: { runtime in
                await probe.recordShutdown()
                try await runtime.shutdownCoreRuntime()
            }
        )

        _ = try await service.runtime()
        await service.shutdown()
        await service.shutdown()

        let shutdownCount = await probe.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
        do {
            _ = try await service.runtime()
            XCTFail("Stopped service must fail closed")
        } catch let error as AgentryCoreService.ServiceError {
            XCTAssertEqual(error, .stopped)
        } catch {
            XCTFail("Expected stopped service error, got \(error)")
        }
    }

    func testTerminationHookReturnsAtDeadlineWhileShutdownIsStillPending() async {
        let startupGate = AgentryCoreServiceTestGate()
        let service = AgentryCoreService(startOperation: {
            await startupGate.arriveAndWait()
            throw AgentryCoreServiceTestFailure.startup
        })
        let startupRequest = Task { try await service.runtime() }
        await startupGate.waitUntilArrived()

        let appDelegate = AppDelegate()
        appDelegate.agentryCoreService = service
        appDelegate.setAgentryCoreShutdownDeadlineForTesting(.milliseconds(25))
        let clock = ContinuousClock()
        let startedAt = clock.now

        await appDelegate.shutdownAgentryCoreForTerminationForTesting()

        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(1))
        let releasedBeforeCleanup = await startupGate.isReleased
        XCTAssertFalse(releasedBeforeCleanup)

        await startupGate.release()
        do {
            _ = try await startupRequest.value
            XCTFail("Expected the gated startup to fail")
        } catch {
            // The startup failure is expected after the deadline has already returned.
        }
    }
}

private enum AgentryCoreServiceTestFailure: Error {
    case startup
}

private final class AgentryCoreServiceTestRuntime: AgentryCoreRuntimeOwner, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func coreSearchClient() async throws -> CoreSearchClient {
        throw AgentryCoreServiceTestFailure.startup
    }

    func coreComputeClient() async throws -> CoreComputeClient {
        throw AgentryCoreServiceTestFailure.startup
    }

    func shutdownCoreRuntime() async throws {
        lock.withLock { stopped = true }
    }

    var isStopped: Bool {
        lock.withLock { stopped }
    }
}

private actor AgentryCoreServiceTestProbe {
    private(set) var startCount = 0
    private(set) var shutdownCount = 0

    func recordStart() {
        startCount += 1
    }

    func recordShutdown() {
        shutdownCount += 1
    }
}

private actor AgentryCoreServiceTestGate {
    private var arrived = false
    private(set) var isReleased = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
