import AgentryCoreBridge
import Foundation

protocol AgentryCoreRuntimeOwner: AnyObject, Sendable {
    func coreSearchClient() async throws -> CoreSearchClient
    func coreComputeClient() async throws -> CoreComputeClient
    func shutdownCoreRuntime() async throws
}

extension AgentryCoreBridge: AgentryCoreRuntimeOwner {
    func coreSearchClient() async throws -> CoreSearchClient {
        try searchClient()
    }

    func coreComputeClient() async throws -> CoreComputeClient {
        try computeClient()
    }

    func shutdownCoreRuntime() async throws {
        _ = try close()
    }
}

/// Process-owned entry point for the Rust core runtime.
///
/// The service caches the first startup task, including failure, so concurrent and
/// later callers observe one runtime attempt. Search infrastructure failures never
/// fall back to the legacy Swift/C search implementation.
actor AgentryCoreService {
    typealias StartOperation = @Sendable () async throws -> any AgentryCoreRuntimeOwner
    typealias ShutdownOperation = @Sendable (any AgentryCoreRuntimeOwner) async throws -> Void

    enum ServiceError: Error, Equatable, LocalizedError {
        case searchInfrastructureUnavailable(String)
        case stopped

        var errorDescription: String? {
            switch self {
            case let .searchInfrastructureUnavailable(description):
                "Rust search infrastructure is unavailable: \(description)"
            case .stopped:
                "Rust search infrastructure has stopped."
            }
        }
    }

    static let shared = AgentryCoreService()

    private let startOperation: StartOperation
    private let shutdownOperation: ShutdownOperation
    private var startupTask: Task<any AgentryCoreRuntimeOwner, Error>?
    private var isStopped = false
    private var shutdownStarted = false

    init(
        startOperation: @escaping StartOperation = { try await AgentryCoreBridge.start() },
        shutdownOperation: @escaping ShutdownOperation = { try await $0.shutdownCoreRuntime() }
    ) {
        self.startOperation = startOperation
        self.shutdownOperation = shutdownOperation
    }

    func searchClient() async throws -> CoreSearchClient {
        do {
            return try await runtime().coreSearchClient()
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.searchInfrastructureUnavailable(String(reflecting: error))
        }
    }

    func computeClient() async throws -> CoreComputeClient {
        do {
            return try await runtime().coreComputeClient()
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.searchInfrastructureUnavailable(String(reflecting: error))
        }
    }

    func runtime() async throws -> any AgentryCoreRuntimeOwner {
        guard !isStopped else { throw ServiceError.stopped }
        let task: Task<any AgentryCoreRuntimeOwner, Error>
        if let startupTask {
            task = startupTask
        } else {
            let operation = startOperation
            let created = Task { try await operation() }
            startupTask = created
            task = created
        }

        do {
            let runtime = try await task.value
            guard !isStopped else { throw ServiceError.stopped }
            return runtime
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.searchInfrastructureUnavailable(String(reflecting: error))
        }
    }

    /// Idempotently begins runtime shutdown. A failed cached startup is not retried.
    func shutdown() async {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        isStopped = true
        guard let startupTask else { return }

        do {
            let runtime = try await startupTask.value
            try await shutdownOperation(runtime)
        } catch {
            // Startup failure is already cached and surfaced to search callers. Shutdown
            // remains best-effort because process termination must continue.
        }
    }
}
