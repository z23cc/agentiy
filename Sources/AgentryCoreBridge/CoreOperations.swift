import Foundation
import os

public struct OperationID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init() {
        rawValue = UUID().uuidString.lowercased()
    }

    public init(rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue), uuid.uuidString.lowercased() == rawValue else {
            throw CoreBridgeError.invalidIdentifier("operationID")
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct CoreScopeID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init() {
        rawValue = UUID().uuidString.lowercased()
    }

    public init(rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue), uuid.uuidString.lowercased() == rawValue else {
            throw CoreBridgeError.invalidIdentifier("scopeID")
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct CoreRequestFingerprint: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard rawValue.utf8.count == 64,
              rawValue.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw CoreBridgeError.invalidFingerprint
        }
        self.rawValue = rawValue
    }
}

public struct CoreRuntimeIdentity: Hashable, Sendable {
    public let abiEpoch: UInt32
    public let instanceNonce: String
    public let buildFingerprint: String
    public let bindingChecksum: String
}

public struct CoreConfiguration: Hashable, Sendable {
    public var dataLaneCapacity: UInt64
    public var cancelTombstoneMilliseconds: UInt64
    public var shutdownGraceMilliseconds: UInt64

    public init(
        dataLaneCapacity: UInt64 = 1_024,
        cancelTombstoneMilliseconds: UInt64 = 30_000,
        shutdownGraceMilliseconds: UInt64 = 5_000
    ) {
        self.dataLaneCapacity = dataLaneCapacity
        self.cancelTombstoneMilliseconds = cancelTombstoneMilliseconds
        self.shutdownGraceMilliseconds = shutdownGraceMilliseconds
    }
}

public struct CoreCommand: Hashable, Sendable {
    public let scopeID: CoreScopeID
    public let requestFingerprint: CoreRequestFingerprint
    public let deadlineUnixMilliseconds: UInt64?
    public let payload: Data

    public init(
        scopeID: CoreScopeID,
        requestFingerprint: CoreRequestFingerprint,
        deadlineUnixMilliseconds: UInt64? = nil,
        payload: Data
    ) {
        self.scopeID = scopeID
        self.requestFingerprint = requestFingerprint
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.payload = payload
    }
}

public enum CoreOperationState: Hashable, Sendable {
    case admitted
    case running
    case cancelRequested
    case succeeded
    case cancelled
    case deadlineExceeded
    case failed
}

public enum CoreAdmissionDisposition: Hashable, Sendable {
    case accepted
    case duplicate
}

public struct CoreAdmission: Hashable, Sendable {
    public let runtimeIdentity: CoreRuntimeIdentity
    public let operationID: OperationID
    public let disposition: CoreAdmissionDisposition
    public let state: CoreOperationState
}

public enum CoreCancellationDisposition: Hashable, Sendable {
    case requested
    case tombstoned
    case alreadyRequested
    case alreadyTerminal
}

public struct CoreCancellation: Hashable, Sendable {
    public let operationID: OperationID
    public let disposition: CoreCancellationDisposition
}

public struct CoreShutdownReceipt: Hashable, Sendable {
    public let alreadyStarted: Bool
    public let cancelledOperations: UInt64
}

public enum CoreBridgeError: Error, Equatable, Sendable {
    case notInitialized
    case alreadyClosed
    case invalidIdentifier(String)
    case invalidFingerprint
    case incompatibleBindings
    case staleRuntimeIdentity
    case runtimeInvalidated
    case runtimeStopped
    case operationConflict
    case deadlineExpired
    case operationCancelled
    case shutdownRequested
    case subscriptionNotFound
    case queueLimitExceeded
    case payloadTooLarge
    case shutdownTimedOut
    case invalidArgument
    case inventoryScopeUnknownScope
    case inventoryScopeUnknownRoot
    case inventoryScopeLifetimeMismatch
    case inventoryScopeNoPublishedGeneration
    case inventoryScopeBulkLoadUnknown
    case inventoryScopeBulkLoadAlreadyTerminal
    case inventoryScopeBulkLoadRootMismatch
    case inventoryHandleInvalidated(CoreInventoryHandleInvalidationReason)
    case inventoryScopeInvalidRequest(String)
    // P6-6: agent-claude-v1 (docs/architecture/rust-agent-claude-v1.md, design §11 P6-6).
    case agentClaudeUnknownScope
    case agentClaudeScopeClosed
    case agentClaudeAlreadyRunning
    case agentClaudeNotRunning
    case agentClaudeUnknownPermissionRequest
    case agentClaudeSpawnFailed(String)
    case agentClaudeReaperFailed(String)
    case agentClaudeTransportWriteFailed(String)
    case agentClaudeInvalidRequest(String)
    /// P6-7 (§15.5): the CLI answered a session-startup handshake control request (`initialize`/
    /// `set_permission_mode`) with `subtype: "error"`.
    case agentClaudeControlResponseError(String)
    // P6 provider-runtime authority shared by Codex app-server and ACP.
    case agentProviderUnknownScope
    case agentProviderScopeClosed
    case agentProviderAlreadyRunning
    case agentProviderNotRunning
    case agentProviderSpawnFailed(String)
    case agentProviderReaperFailed(String)
    case agentProviderTransportWriteFailed(String)
    case agentProviderInvalidRequest(String)
    case agentProviderCodexProtocolMismatch
    case agentProviderCodexInvalidJson
    case agentProviderCodexTimedOut(String)
    case agentProviderCodexCancelled(String)
    case agentProviderCodexRemoteError(method: String, code: Int64, message: String, data: Data?)
    case agentProviderCodexInvalidResponse
    case agentProviderAcpProtocolMismatch
    case agentProviderAcpInvalidJson
    case agentProviderAcpTimedOut(String)
    case agentProviderAcpCancelled(String)
    case agentProviderAcpRemoteError(method: String, code: Int64, message: String, data: Data?)
    case agentProviderAcpInvalidResponse
    case watcherUnknownScope
    case watcherScopeClosed
    case watcherInvalidRequest(String)
    case transportFailure(String)
}

extension CoreBridgeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notInitialized: "The Agentry core has not been initialized."
        case .alreadyClosed: "The Agentry core is closed."
        case let .invalidIdentifier(name): "The \(name) is not a canonical lowercase UUID."
        case .invalidFingerprint: "The request fingerprint is not lowercase SHA-256 hex."
        case .incompatibleBindings: "The generated Swift bindings do not match the Rust core archive."
        case .staleRuntimeIdentity: "The object belongs to an earlier Rust runtime instance."
        case .runtimeInvalidated: "The Rust runtime was invalidated after an internal failure."
        case .runtimeStopped: "The Rust runtime has stopped."
        case .operationConflict: "The operation identifier conflicts with an existing request."
        case .deadlineExpired: "The operation deadline expired before admission."
        case .operationCancelled: "Operation cancellation won before physical authority."
        case .shutdownRequested: "Runtime shutdown won before physical authority."
        case .subscriptionNotFound: "The subscription no longer exists."
        case .queueLimitExceeded: "The bounded core queue rejected the request."
        case .payloadTooLarge: "The payload exceeds the core boundary limit."
        case .shutdownTimedOut: "The core shutdown deadline elapsed."
        case .invalidArgument: "The core rejected an invalid argument."
        case .inventoryScopeUnknownScope: "The inventory scope is unknown or already closed."
        case .inventoryScopeUnknownRoot: "The inventory root is unknown."
        case .inventoryScopeLifetimeMismatch: "The inventory root lifetime no longer matches."
        case .inventoryScopeNoPublishedGeneration: "The inventory root has no published generation yet."
        case .inventoryScopeBulkLoadUnknown: "The inventory bulk load is unknown."
        case .inventoryScopeBulkLoadAlreadyTerminal: "The inventory bulk load already committed or aborted."
        case .inventoryScopeBulkLoadRootMismatch: "The inventory bulk load does not match the given root."
        case let .inventoryHandleInvalidated(reason): "The inventory snapshot handle was invalidated: \(reason)."
        case let .inventoryScopeInvalidRequest(message): "Invalid inventory-scope-v1 request: \(message)"
        case .agentClaudeUnknownScope: "The agent-claude scope is unknown or already closed."
        case .agentClaudeScopeClosed: "The agent-claude scope is closed."
        case .agentClaudeAlreadyRunning: "The agent-claude scope already has a running process."
        case .agentClaudeNotRunning: "The agent-claude scope has no running process."
        case .agentClaudeUnknownPermissionRequest: "The agent-claude permission request id is unknown."
        case let .agentClaudeSpawnFailed(message): "Agent-claude spawn failed: \(message)"
        case let .agentClaudeReaperFailed(message): "Agent-claude reaper registration failed: \(message)"
        case let .agentClaudeTransportWriteFailed(message): "Agent-claude transport write failed: \(message)"
        case let .agentClaudeInvalidRequest(message): "Invalid agent-claude request: \(message)"
        case let .agentClaudeControlResponseError(message): "Agent-claude control response error: \(message)"
        case .agentProviderUnknownScope: "The agent provider scope is unknown or already closed."
        case .agentProviderScopeClosed: "The agent provider scope is closed."
        case .agentProviderAlreadyRunning: "The agent provider scope already has a running process."
        case .agentProviderNotRunning: "The agent provider scope has no running process."
        case let .agentProviderSpawnFailed(message): "Agent provider spawn failed: \(message)"
        case let .agentProviderReaperFailed(message): "Agent provider reaper registration failed: \(message)"
        case let .agentProviderTransportWriteFailed(message): "Agent provider transport write failed: \(message)"
        case let .agentProviderInvalidRequest(message): "Invalid agent provider request: \(message)"
        case .agentProviderCodexProtocolMismatch: "Codex app-server semantic transport is unavailable for this scope."
        case .agentProviderCodexInvalidJson: "Codex app-server returned invalid JSON."
        case let .agentProviderCodexTimedOut(method): "Codex app-server request timed out: \(method)"
        case let .agentProviderCodexCancelled(method): "Codex app-server request cancelled: \(method)"
        case let .agentProviderCodexRemoteError(method, code, message, _): "Codex app-server request failed (\(method), \(code)): \(message)"
        case .agentProviderCodexInvalidResponse: "Codex app-server returned an invalid response."
        case .agentProviderAcpProtocolMismatch: "ACP semantic transport is unavailable for this scope."
        case .agentProviderAcpInvalidJson: "ACP provider returned invalid JSON."
        case let .agentProviderAcpTimedOut(method): "ACP provider request timed out: \(method)"
        case let .agentProviderAcpCancelled(method): "ACP provider request cancelled: \(method)"
        case let .agentProviderAcpRemoteError(method, code, message, _): "ACP provider request failed (\(method), \(code)): \(message)"
        case .agentProviderAcpInvalidResponse: "ACP provider returned an invalid response."
        case .watcherUnknownScope: "The file-system watcher scope is unknown or already closed."
        case .watcherScopeClosed: "The file-system watcher scope is closed."
        case let .watcherInvalidRequest(message): "The file-system watcher request is invalid: \(message)"
        case let .transportFailure(message): "Rust FFI transport failure: \(message)"
        }
    }
}

final class CoreCancellationIntent: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        state.withLock { $0 = true }
    }

    var isCancelled: Bool {
        state.withLock { $0 }
    }
}
