import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainRepositoryAdmissionCoordinatorTests: XCTestCase {
    func testSameRepositoryBlocksWhileDifferentRepositoriesProceed() async throws {
        let coordinator = MCPDomainRepositoryAdmissionCoordinator(limit: 1)
        let first = try await coordinator.acquire(repositoryKeys: ["/tmp/repository-a"])

        let blocked = Task { () -> MCPDomainRepositoryAdmissionCoordinator.Lease in
            try await coordinator.acquire(repositoryKeys: ["/tmp/repository-a"])
        }
        for _ in 0 ..< 100 {
            if coordinator.snapshot().waiterCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.snapshot().waiterCount, 1)

        let independent = try await coordinator.acquire(repositoryKeys: ["/tmp/repository-b"])
        XCTAssertEqual(coordinator.activeCount(repositoryKey: "/tmp/repository-b"), 1)
        XCTAssertTrue(independent.release())
        XCTAssertTrue(first.release())
        let blockedLease = try await blocked.value
        XCTAssertEqual(coordinator.snapshot().activeLeaseCount, 1)
        XCTAssertEqual(coordinator.snapshot().activeRepositoryCount, 1)
        XCTAssertTrue(blockedLease.release())
        XCTAssertEqual(coordinator.snapshot().activeLeaseCount, 0)
    }

    func testMultiRepositoryAdmissionIsAtomicAndCanonicalizesKeys() async throws {
        let coordinator = MCPDomainRepositoryAdmissionCoordinator(limit: 1)
        let first = try await coordinator.acquire(repositoryKeys: ["/tmp/repository-a/../repository-a", "/tmp/repository-b"])
        XCTAssertEqual(first.repositoryKeys, ["/tmp/repository-a", "/tmp/repository-b"])
        XCTAssertEqual(coordinator.snapshot().activeRepositoryCount, 2)

        let blocked = Task { () -> MCPDomainRepositoryAdmissionCoordinator.Lease in
            try await coordinator.acquire(repositoryKeys: ["/tmp/repository-b", "/tmp/repository-c"])
        }
        for _ in 0 ..< 100 {
            if coordinator.snapshot().waiterCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.snapshot().waiterCount, 1)
        XCTAssertTrue(first.release())
        let second = try await blocked.value
        XCTAssertEqual(second.repositoryKeys, ["/tmp/repository-b", "/tmp/repository-c"])
        XCTAssertTrue(second.release())
    }

    func testCancellationAndCloseSettleWaitersWithoutLeakingLeases() async throws {
        let coordinator = MCPDomainRepositoryAdmissionCoordinator(limit: 1)
        let first = try await coordinator.acquire(repositoryKeys: ["/tmp/repository-a"])
        let cancelled = Task { () -> Error? in
            do {
                _ = try await coordinator.acquire(repositoryKeys: ["/tmp/repository-a"])
                return nil
            } catch {
                return error
            }
        }
        for _ in 0 ..< 100 {
            if coordinator.snapshot().waiterCount == 1 { break }
            await Task.yield()
        }
        cancelled.cancel()
        let cancelledError = await cancelled.value
        XCTAssertTrue(cancelledError is CancellationError)
        XCTAssertEqual(coordinator.snapshot().waiterCount, 0)

        let closed = Task { () -> Error? in
            do {
                _ = try await coordinator.acquire(repositoryKeys: ["/tmp/repository-a"])
                return nil
            } catch {
                return error
            }
        }
        for _ in 0 ..< 100 {
            if coordinator.snapshot().waiterCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.close(), 1)
        let closedError = await closed.value
        XCTAssertEqual(closedError as? MCPDomainRepositoryAdmissionCoordinator.AdmissionError, .closed)
        XCTAssertTrue(first.release())
        XCTAssertEqual(coordinator.snapshot().activeLeaseCount, 0)
        XCTAssertTrue(coordinator.snapshot().isClosed)
    }
}
