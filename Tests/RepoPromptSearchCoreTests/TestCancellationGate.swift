import Foundation

final class TestCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var continuation: CheckedContinuation<Void, Error>?

    func waitUntilCancelled() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    entered = true
                    self.continuation = continuation
                }
            }
        } onCancel: {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func waitUntilEntered() async {
        while true {
            let entered = lock.withLock { self.entered }
            if entered {
                return
            }
            await Task.yield()
        }
    }
}
