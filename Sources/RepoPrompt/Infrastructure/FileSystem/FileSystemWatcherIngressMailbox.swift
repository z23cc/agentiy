import AgentryCoreBridge
import CoreServices
import Foundation
import RepoPromptDomainRuntime

/// Compatibility facade for the file-system actor's existing ingress contract.
///
/// The facade owns only callback scheduling and diagnostic correlation. Accepted payload lifetime,
/// monotonic watermarks, FIFO ordering, pressure collapse, and reset semantics live in the Rust
/// watcher scope. CoreServices remains the platform host adapter; it never owns a second mailbox.
final class FileSystemWatcherIngressMailbox: @unchecked Sendable {
    struct Watermark: Hashable, Comparable {
        let rawValue: UInt64

        static let zero = Watermark(rawValue: 0)

        static func < (lhs: Watermark, rhs: Watermark) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct AcceptedPayload: @unchecked Sendable {
        enum Contents: @unchecked Sendable {
            case entries([FSEventCallbackEntry])
            case overflowRootRescan(
                highestEventID: FSEventStreamEventId,
                changedIgnoreAbsolutePaths: Set<String>
            )
        }

        let lowestAcceptedWatermark: Watermark
        let acceptedHighWatermark: Watermark
        let contents: Contents
        let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?

        var rawEntryCount: Int {
            switch contents {
            case let .entries(entries): entries.count
            case .overflowRootRescan: 1
            }
        }
    }

    #if DEBUG
        struct Snapshot: Equatable {
            let acceptedHighWatermark: Watermark
            let queuedAcceptedWatermarkRange: ClosedRange<Watermark>?
            let queuedPayloadCount: Int
            let queuedRawEntryCount: Int
            let hasOverflowRootRescan: Bool
            let isAutomaticDrainPaused: Bool
        }
    #endif

    private let session: CoreFileSystemWatcherSession
    private let lock = NSLock()
    private var isAutomaticDrainPaused = false
    private var nextDrainToken: UInt64 = 0
    private var activeDrainToken: UInt64?
    private var drainTask: Task<Void, Never>?
    /// Correlation is observability metadata only; Rust remains authoritative for all payload shape
    /// and watermark state. Entries are removed through the corresponding accepted cut.
    private var correlationsByWatermark: [UInt64: EditFlowPerf.LifecycleCorrelation] = [:]

    private init(session: CoreFileSystemWatcherSession) {
        self.session = session
    }

    deinit {
        session.close()
    }

    static func open(rootPath: String, maxQueuedRawEntries: Int) async throws -> FileSystemWatcherIngressMailbox {
        let runtime = try await AgentryCoreService.shared.runtime()
        guard let bridge = runtime as? AgentryCoreBridge else {
            throw CoreBridgeError.transportFailure("file-system-watcher-v1 requires the AgentryCoreBridge runtime")
        }
        let session = try await CoreFileSystemWatcherSession.open(
            bridge: bridge,
            rootPath: rootPath,
            maxQueuedRawEntries: UInt64(max(1, maxQueuedRawEntries))
        )
        return FileSystemWatcherIngressMailbox(session: session)
    }

    func startAccepting() {
        try? session.startAccepting()
    }

    /// Stops callback acceptance and discards pending Rust-owned evidence. The monotonic watermark
    /// is intentionally retained by the Rust scope so a restart cannot pass an ABA cut.
    func pauseAutomaticDraining() {
        lock.lock()
        isAutomaticDrainPaused = true
        lock.unlock()
    }

    func resumeAutomaticDraining(
        scheduleDrain: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        isAutomaticDrainPaused = false
        scheduleDrainIfNeeded(scheduleDrain)
        lock.unlock()
    }

    func stopAcceptingAndDiscardPending() {
        try? session.reset()
        lock.lock()
        isAutomaticDrainPaused = false
        activeDrainToken = nil
        let task = drainTask
        drainTask = nil
        correlationsByWatermark.removeAll(keepingCapacity: false)
        lock.unlock()
        task?.cancel()
    }

    func captureAcceptedWatermark() -> Watermark {
        (try? session.captureWatermark()).map(Watermark.init(rawValue:)) ?? .zero
    }

    @discardableResult
    func accept(
        _ payload: FSEventCallbackPayload,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?,
        scheduleDrain: (@Sendable () async -> Void)?
    ) -> Watermark? {
        guard !payload.entries.isEmpty else { return nil }
        let events = payload.entries.map {
            CoreFileSystemWatcherEvent(path: $0.path, flags: UInt64($0.flags), eventID: UInt64($0.id))
        }
        guard let rawWatermark = try? session.ingest(events) else { return nil }
        if let lifecycleCorrelation {
            lock.lock()
            correlationsByWatermark[rawWatermark] = lifecycleCorrelation
            lock.unlock()
        }
        if let scheduleDrain {
            lock.lock()
            scheduleDrainIfNeeded(scheduleDrain)
            lock.unlock()
        }
        return Watermark(rawValue: rawWatermark)
    }

    func takeNextAcceptedPayload(through target: Watermark? = nil) -> AcceptedPayload? {
        guard let payload = try? session.takeNext(through: target?.rawValue) else { return nil }
        let correlation: EditFlowPerf.LifecycleCorrelation? = lock.withLock {
            let value = correlationsByWatermark[payload.acceptedHighWatermark]
            correlationsByWatermark = correlationsByWatermark.filter { $0.key > payload.acceptedHighWatermark }
            return value
        }
        let contents: AcceptedPayload.Contents = switch payload.contents {
        case let .entries(entries):
            .entries(entries.map {
                FSEventCallbackEntry(
                    path: $0.path,
                    flags: FSEventStreamEventFlags($0.flags),
                    id: FSEventStreamEventId($0.eventID)
                )
            })
        case let .overflowRootRescan(highestEventID, changedIgnoreAbsolutePaths):
            .overflowRootRescan(
                highestEventID: FSEventStreamEventId(highestEventID),
                changedIgnoreAbsolutePaths: changedIgnoreAbsolutePaths
            )
        }
        return AcceptedPayload(
            lowestAcceptedWatermark: Watermark(rawValue: payload.lowestAcceptedWatermark),
            acceptedHighWatermark: Watermark(rawValue: payload.acceptedHighWatermark),
            contents: contents,
            lifecycleCorrelation: correlation
        )
    }

    #if DEBUG
        func snapshotForTesting() -> Snapshot {
            let snapshot = try? session.snapshot()
            let paused = lock.withLock { isAutomaticDrainPaused }
            return Snapshot(
                acceptedHighWatermark: Watermark(rawValue: snapshot?.acceptedHighWatermark ?? 0),
                queuedAcceptedWatermarkRange: snapshot?.queuedAcceptedWatermarkRange.map {
                    Watermark(rawValue: $0.lowerBound) ... Watermark(rawValue: $0.upperBound)
                },
                queuedPayloadCount: snapshot?.queuedPayloadCount ?? 0,
                queuedRawEntryCount: snapshot?.queuedRawEntryCount ?? 0,
                hasOverflowRootRescan: snapshot?.hasOverflowRootRescan ?? false,
                isAutomaticDrainPaused: paused
            )
        }
    #endif

    private func scheduleDrainIfNeeded(_ scheduleDrain: @escaping @Sendable () async -> Void) {
        guard !isAutomaticDrainPaused, activeDrainToken == nil else { return }
        guard ((try? session.snapshot())?.queuedPayloadCount ?? 0) > 0 else { return }
        nextDrainToken &+= 1
        let token = nextDrainToken
        activeDrainToken = token
        drainTask = Task { [weak self] in
            await scheduleDrain()
            self?.drainTaskDidFinish(token: token, scheduleDrain: scheduleDrain)
        }
    }

    private func drainTaskDidFinish(
        token: UInt64,
        scheduleDrain: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        guard activeDrainToken == token else {
            lock.unlock()
            return
        }
        activeDrainToken = nil
        drainTask = nil
        scheduleDrainIfNeeded(scheduleDrain)
        lock.unlock()
    }
}
