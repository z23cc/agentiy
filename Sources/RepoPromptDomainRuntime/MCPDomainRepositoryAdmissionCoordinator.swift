import Foundation

/// Catalog-bound per-repository admission. Keys are supplied by an authoritative
/// repository resolver; this coordinator never interprets caller paths.
package final class MCPDomainRepositoryAdmissionCoordinator: @unchecked Sendable {
    package enum AdmissionError: Error, Equatable, Sendable {
        case closed
        case invalidKey
    }

    package struct Snapshot: Equatable, Sendable {
        package let activeLeaseCount: Int
        package let waiterCount: Int
        package let activeRepositoryCount: Int
        package let isClosed: Bool
    }

    package final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseAction: (() -> Void)?
        package let repositoryKeys: [String]
        package let catalogDigest: String?

        fileprivate init(
            repositoryKeys: [String],
            catalogDigest: String?,
            releaseAction: @escaping () -> Void
        ) {
            self.repositoryKeys = repositoryKeys
            self.catalogDigest = catalogDigest
            self.releaseAction = releaseAction
        }

        @discardableResult
        package func release() -> Bool {
            let action: (() -> Void)? = lock.withLock {
                defer { releaseAction = nil }
                return releaseAction
            }
            action?()
            return action != nil
        }

        deinit {
            release()
        }
    }

    private struct Waiter {
        let id: UUID
        let repositoryKeys: [String]
        let continuation: CheckedContinuation<Lease, Error>
    }

    package let limit: Int
    package let catalogDigest: String?
    private let lock = NSLock()
    private var activeByRepository: [String: Int] = [:]
    private var activeLeaseIDs: Set<UUID> = []
    private var waiters: [Waiter] = []
    private var isClosed = false

    package init(limit: Int, catalogDigest: String? = nil) {
        precondition(limit > 0)
        self.limit = limit
        self.catalogDigest = catalogDigest
    }

    package func acquire(repositoryKeys rawKeys: [String]) async throws -> Lease {
        let repositoryKeys = Array(Set(rawKeys.map(Self.canonicalKey))).sorted()
        guard !repositoryKeys.isEmpty, repositoryKeys.allSatisfy({ !$0.isEmpty }) else {
            throw AdmissionError.invalidKey
        }
        try Task.checkCancellation()

        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Lease, Error>? = lock.withLock {
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard !isClosed else {
                        return .failure(AdmissionError.closed)
                    }
                    guard canAcquire(repositoryKeys),
                          !waiters.contains(where: { Self.overlaps($0.repositoryKeys, repositoryKeys) })
                    else {
                        waiters.append(Waiter(
                            id: waiterID,
                            repositoryKeys: repositoryKeys,
                            continuation: continuation
                        ))
                        return nil
                    }
                    return .success(activate(repositoryKeys))
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            self.cancelWaiter(waiterID)
        }

        do {
            try Task.checkCancellation()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    @discardableResult
    package func close() -> Int {
        let pending: [Waiter] = lock.withLock {
            guard !isClosed else { return [] }
            isClosed = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.continuation.resume(throwing: AdmissionError.closed)
        }
        return pending.count
    }

    package func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                activeLeaseCount: activeLeaseIDs.count,
                waiterCount: waiters.count,
                activeRepositoryCount: activeByRepository.count,
                isClosed: isClosed
            )
        }
    }

    package func activeCount(repositoryKey: String) -> Int {
        lock.withLock { activeByRepository[Self.canonicalKey(repositoryKey)] ?? 0 }
    }

    package nonisolated static func canonicalKey(_ rawKey: String) -> String {
        URL(fileURLWithPath: rawKey)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
            .lowercased()
    }

    private func canAcquire(_ repositoryKeys: [String]) -> Bool {
        repositoryKeys.allSatisfy { (activeByRepository[$0] ?? 0) < limit }
    }

    private nonisolated static func overlaps(_ lhs: [String], _ rhs: [String]) -> Bool {
        !Set(lhs).isDisjoint(with: rhs)
    }

    private func activate(_ repositoryKeys: [String]) -> Lease {
        let id = UUID()
        for key in repositoryKeys {
            activeByRepository[key, default: 0] += 1
        }
        activeLeaseIDs.insert(id)
        return Lease(
            repositoryKeys: repositoryKeys,
            catalogDigest: catalogDigest,
            releaseAction: { [weak self] in
                self?.release(id: id, repositoryKeys: repositoryKeys)
            }
        )
    }

    private func release(id: UUID, repositoryKeys: [String]) {
        let nextWaiters: [(CheckedContinuation<Lease, Error>, Lease)] = lock.withLock {
            guard activeLeaseIDs.remove(id) != nil else { return [] }
            for key in repositoryKeys {
                let next = max(0, (activeByRepository[key] ?? 0) - 1)
                if next == 0 {
                    activeByRepository.removeValue(forKey: key)
                } else {
                    activeByRepository[key] = next
                }
            }
            var handoffs: [(CheckedContinuation<Lease, Error>, Lease)] = []
            while !isClosed,
                  let index = waiters.firstIndex(where: { canAcquire($0.repositoryKeys) })
            {
                let waiter = waiters.remove(at: index)
                handoffs.append((waiter.continuation, activate(waiter.repositoryKeys)))
            }
            return handoffs
        }
        for (continuation, lease) in nextWaiters {
            continuation.resume(returning: lease)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        let continuation: CheckedContinuation<Lease, Error>? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
                return nil
            }
            return waiters.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
