import Foundation

public struct CoreHostRequest: Hashable, Sendable {
    public let requestID: String
    public let runtimeIdentity: CoreRuntimeIdentity
    public let payload: Data

    public init(requestID: String, runtimeIdentity: CoreRuntimeIdentity, payload: Data) {
        self.requestID = requestID
        self.runtimeIdentity = runtimeIdentity
        self.payload = payload
    }
}

public struct CoreHostResponse: Hashable, Sendable {
    public let requestID: String
    public let runtimeIdentity: CoreRuntimeIdentity
    public let payload: Data

    public init(requestID: String, runtimeIdentity: CoreRuntimeIdentity, payload: Data) {
        self.requestID = requestID
        self.runtimeIdentity = runtimeIdentity
        self.payload = payload
    }
}

public protocol CoreHostBroker: Sendable {
    func handle(_ request: CoreHostRequest) async throws -> CoreHostResponse
}

public struct RejectingCoreHostBroker: CoreHostBroker {
    public init() {}

    public func handle(_ request: CoreHostRequest) async throws -> CoreHostResponse {
        throw CoreBridgeError.transportFailure("host capability \(request.requestID) is not registered")
    }
}
