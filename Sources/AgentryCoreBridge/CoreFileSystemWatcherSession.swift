import AgentryUniFFIRaw
import Foundation

// P7 watcher authority facade. CoreServices/FSEventStream stays in the host target; Rust owns
// accepted payload lifetime, watermarks, FIFO, bounded collapse, and scope lifecycle.

extension CoreRuntimeTransport {
    func fileSystemWatcherOpenScope(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreFileSystemWatcherScopeConfigV1
    ) throws -> AgentryUniFFIRaw.CoreFileSystemWatcherScopeHandleV1 {
        throw CoreTransportError.unexpected("file-system-watcher-v1 transport is unavailable")
    }

    func fileSystemWatcherStartAccepting(identity: CoreRuntimeIdentity, scopeID: String) throws {
        throw CoreTransportError.unexpected("file-system-watcher-v1 transport is unavailable")
    }

    func fileSystemWatcherIngest(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        entries: [AgentryUniFFIRaw.CoreFileSystemWatcherEventV1]
    ) throws -> UInt64? {
        throw CoreTransportError.unexpected("file-system-watcher-v1 transport is unavailable")
    }

    func fileSystemWatcherCaptureWatermark(identity: CoreRuntimeIdentity, scopeID: String) throws -> UInt64 {
        throw CoreTransportError.unexpected("file-system-watcher-v1 transport is unavailable")
    }

    func fileSystemWatcherTakeNext(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        through: UInt64?
    ) throws -> AgentryUniFFIRaw.CoreFileSystemWatcherPayloadV1? {
        throw CoreTransportError.unexpected("file-system-watcher-v1 transport is unavailable")
    }

    func fileSystemWatcherSnapshot(
        identity: CoreRuntimeIdentity,
        scopeID: String
    ) throws -> AgentryUniFFIRaw.CoreFileSystemWatcherSnapshotV1 {
        throw CoreTransportError.unexpected("file-system-watcher-v1 transport is unavailable")
    }

    func fileSystemWatcherReset(identity: CoreRuntimeIdentity, scopeID: String) throws {
        throw CoreTransportError.unexpected("file-system-watcher-v1 transport is unavailable")
    }

    func fileSystemWatcherCloseScope(identity: CoreRuntimeIdentity, scopeID: String) throws {
        throw CoreTransportError.unexpected("file-system-watcher-v1 transport is unavailable")
    }
}

public struct CoreFileSystemWatcherEvent: Sendable, Equatable {
    public let path: String
    public let flags: UInt64
    public let eventID: UInt64

    public init(path: String, flags: UInt64, eventID: UInt64) {
        self.path = path
        self.flags = flags
        self.eventID = eventID
    }
}

public enum CoreFileSystemWatcherPayloadContents: Sendable, Equatable {
    case entries([CoreFileSystemWatcherEvent])
    case overflowRootRescan(highestEventID: UInt64, changedIgnoreAbsolutePaths: Set<String>)
}

public struct CoreFileSystemWatcherPayload: Sendable, Equatable {
    public let lowestAcceptedWatermark: UInt64
    public let acceptedHighWatermark: UInt64
    public let contents: CoreFileSystemWatcherPayloadContents

    public var rawEntryCount: Int {
        switch contents {
        case let .entries(entries): entries.count
        case .overflowRootRescan: 1
        }
    }
}

public struct CoreFileSystemWatcherSnapshot: Sendable, Equatable {
    public let acceptedHighWatermark: UInt64
    public let queuedAcceptedWatermarkRange: ClosedRange<UInt64>?
    public let queuedPayloadCount: Int
    public let queuedRawEntryCount: Int
    public let hasOverflowRootRescan: Bool
    public let isAccepting: Bool
}

public final class CoreFileSystemWatcherSession: @unchecked Sendable {
    private let context: CoreDirectComputeOperationContext
    public let scopeID: String

    private init(context: CoreDirectComputeOperationContext, scopeID: String) {
        self.context = context
        self.scopeID = scopeID
    }

    public static func open(
        bridge: AgentryCoreBridge,
        rootPath: String,
        maxQueuedRawEntries: UInt64
    ) async throws -> CoreFileSystemWatcherSession {
        let context = try await bridge.prepareWatcherOperation()
        let handle = try context.transport.fileSystemWatcherOpenScope(
            identity: context.identity,
            config: .init(rootPath: rootPath, maxQueuedRawEntries: maxQueuedRawEntries)
        )
        return CoreFileSystemWatcherSession(context: context, scopeID: handle.scopeId)
    }

    public func startAccepting() throws {
        try context.transport.fileSystemWatcherStartAccepting(identity: context.identity, scopeID: scopeID)
    }

    @discardableResult
    public func ingest(_ entries: [CoreFileSystemWatcherEvent]) throws -> UInt64? {
        try context.transport.fileSystemWatcherIngest(
            identity: context.identity,
            scopeID: scopeID,
            entries: entries.map { .init(path: $0.path, flags: $0.flags, eventId: $0.eventID) }
        )
    }

    public func captureWatermark() throws -> UInt64 {
        try context.transport.fileSystemWatcherCaptureWatermark(identity: context.identity, scopeID: scopeID)
    }

    public func takeNext(through: UInt64? = nil) throws -> CoreFileSystemWatcherPayload? {
        guard let payload = try context.transport.fileSystemWatcherTakeNext(
            identity: context.identity,
            scopeID: scopeID,
            through: through
        ) else { return nil }
        let contents: CoreFileSystemWatcherPayloadContents = switch payload.contents {
        case let .entries(entries):
            .entries(entries.map { CoreFileSystemWatcherEvent(path: $0.path, flags: $0.flags, eventID: $0.eventId) })
        case let .overflowRootRescan(highestEventId, changedIgnoreAbsolutePaths):
            .overflowRootRescan(
                highestEventID: highestEventId,
                changedIgnoreAbsolutePaths: Set(changedIgnoreAbsolutePaths)
            )
        }
        return CoreFileSystemWatcherPayload(
            lowestAcceptedWatermark: payload.lowestAcceptedWatermark,
            acceptedHighWatermark: payload.acceptedHighWatermark,
            contents: contents
        )
    }

    public func snapshot() throws -> CoreFileSystemWatcherSnapshot {
        let snapshot = try context.transport.fileSystemWatcherSnapshot(identity: context.identity, scopeID: scopeID)
        let range: ClosedRange<UInt64>? = if let low = snapshot.queuedLowWatermark,
                                            let high = snapshot.queuedHighWatermark {
            low ... high
        } else {
            nil
        }
        return CoreFileSystemWatcherSnapshot(
            acceptedHighWatermark: snapshot.acceptedHighWatermark,
            queuedAcceptedWatermarkRange: range,
            queuedPayloadCount: Int(snapshot.queuedPayloadCount),
            queuedRawEntryCount: Int(snapshot.queuedRawEntryCount),
            hasOverflowRootRescan: snapshot.hasOverflowRootRescan,
            isAccepting: snapshot.isAccepting
        )
    }

    public func reset() throws {
        try context.transport.fileSystemWatcherReset(identity: context.identity, scopeID: scopeID)
    }

    public func close() {
        try? context.transport.fileSystemWatcherCloseScope(identity: context.identity, scopeID: scopeID)
    }
}

extension AgentryCoreBridge {
    func prepareWatcherOperation() throws -> CoreDirectComputeOperationContext {
        try prepareDirectComputeOperation()
    }
}
