import Foundation

public enum CoreEventKind: Hashable, Sendable {
    case admitted
    case progress
    case data
    case gap
    case hostRequest
    case payloadRejected
    case terminal
}

public enum CoreDecodedPayload: Hashable, Sendable {
    case bytes(Data)
    case utf8(String)
    case gap(droppedCount: UInt64)
    case rejected(actualBytes: UInt64, maximumBytes: UInt64, resnapshotRequired: Bool)
}

public struct CoreEvent: Hashable, Sendable {
    public let kind: CoreEventKind
    public let authoritySequence: UInt64
    public let deliveryCursor: UInt64
    public let payload: CoreDecodedPayload
    public let payloadOmitted: Bool
}

public protocol CoreEventDecoding: Sendable {
    func decode(_ payload: Data) async throws -> CoreDecodedPayload
}

public struct DefaultCoreEventDecoder: CoreEventDecoding {
    public init() {}

    public func decode(_ payload: Data) async throws -> CoreDecodedPayload {
        await Task.detached(priority: .utility) {
            if let string = String(data: payload, encoding: .utf8) {
                return .utf8(string)
            }
            return .bytes(payload)
        }.value
    }
}

public struct CoreEventStream: AsyncSequence, Sendable {
    public typealias Element = CoreEvent

    private let stream: AsyncThrowingStream<CoreEvent, Error>

    init(_ stream: AsyncThrowingStream<CoreEvent, Error>) {
        self.stream = stream
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<CoreEvent, Error>.Iterator {
        stream.makeAsyncIterator()
    }
}

public struct CoreSubscription: Sendable {
    public let streamID: UInt64
    public let initialSnapshot: CoreDecodedPayload
    public let nextDeliveryCursor: UInt64
    public let events: CoreEventStream

    let subscriptionID: UInt64
    let runtimeIdentity: CoreRuntimeIdentity
}

struct CoreTransportEvent: Sendable {
    let kind: CoreEventKind
    let authoritySequence: UInt64
    let deliveryCursor: UInt64
    let payload: Data
    let payloadOmitted: Bool
}

struct CoreTransportOversize: Sendable {
    let actualBytes: UInt64
    let maximumBytes: UInt64
    let resnapshotRequired: Bool
}

struct CoreTransportDrainBatch: Sendable {
    let events: [CoreTransportEvent]
    let hasMore: Bool
    let nextDeliveryCursor: UInt64
    let droppedCount: UInt64
    let oversize: CoreTransportOversize?
}

struct CoreTransportBootstrap: Sendable {
    let subscriptionID: UInt64
    let runtimeIdentity: CoreRuntimeIdentity
    let streamID: UInt64
    let initialSnapshot: Data
    let nextDeliveryCursor: UInt64
}

struct CoreSubscriptionState {
    let runtimeIdentity: CoreRuntimeIdentity
    let continuation: AsyncThrowingStream<CoreEvent, Error>.Continuation
}
