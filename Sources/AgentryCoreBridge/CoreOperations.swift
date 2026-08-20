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
    case subscriptionNotFound
    case queueLimitExceeded
    case payloadTooLarge
    case shutdownTimedOut
    case invalidArgument
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
        case .subscriptionNotFound: "The subscription no longer exists."
        case .queueLimitExceeded: "The bounded core queue rejected the request."
        case .payloadTooLarge: "The payload exceeds the core boundary limit."
        case .shutdownTimedOut: "The core shutdown deadline elapsed."
        case .invalidArgument: "The core rejected an invalid argument."
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
