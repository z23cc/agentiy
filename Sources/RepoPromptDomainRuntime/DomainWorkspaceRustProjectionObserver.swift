import Foundation

package enum DomainWorkspaceProjectionObservationSource: String, Sendable {
    case bootstrap
    case catalogSnapshot = "catalog_snapshot"
    case workspaceRead = "workspace_read"
    case canonicalWorkspaceRead = "canonical_workspace_read"
    case readRegistration = "read_registration"
    case commandOutcome = "command_outcome"
    case leaseReconciliation = "lease_reconciliation"
    case externalReload = "external_reload"
}

package struct DomainWorkspaceProjectionObservationSink: Sendable {
    private let observeBlock: @Sendable (
        DomainWorkspaceDocument,
        DomainWorkspaceProjectionObservationSource
    ) -> Void
    private let observePublicationBlock: @Sendable (
        DomainWorkspaceEvent,
        [DomainWorkspaceSnapshot]
    ) -> Void

    package init(
        observe: @escaping @Sendable (
            DomainWorkspaceDocument,
            DomainWorkspaceProjectionObservationSource
        ) -> Void,
        observePublication: @escaping @Sendable (
            DomainWorkspaceEvent,
            [DomainWorkspaceSnapshot]
        ) -> Void = { _, _ in }
    ) {
        observeBlock = observe
        observePublicationBlock = observePublication
    }

    package func observe(
        _ document: DomainWorkspaceDocument,
        source: DomainWorkspaceProjectionObservationSource
    ) {
        observeBlock(document, source)
    }

    package func observe(
        _ documents: some Sequence<DomainWorkspaceDocument>,
        source: DomainWorkspaceProjectionObservationSource
    ) {
        for document in documents {
            observeBlock(document, source)
        }
    }

    package func observePublication(
        _ event: DomainWorkspaceEvent,
        workspaces: [DomainWorkspaceSnapshot]
    ) {
        observePublicationBlock(event, workspaces)
    }

    /// Comparison-only compatibility entry point. Production authority publications use the full
    /// `workspaces:` overload so revision/health rows cannot be inferred from event tails.
    package func observePublication(
        _ event: DomainWorkspaceEvent,
        documents: [DomainWorkspaceDocument]
    ) {
        let revisions = event.revisions ?? .initial
        observePublicationBlock(event, documents.map { document in
            DomainWorkspaceSnapshot(
                document: document,
                revisions: revisions,
                health: .writable,
                contexts: document.metadata.contexts.map { metadata in
                    DomainContextSnapshot(
                        metadata: metadata,
                        revisions: revisions,
                        health: .writable
                    )
                }
            )
        })
    }

    package static let disabled = DomainWorkspaceProjectionObservationSink { _, _ in }
}

package actor DomainWorkspaceRustProjectionObserver {
    package struct Limits: Sendable, Equatable {
        package let maximumPendingDocumentCount: Int
        package let maximumRetainedInputBytes: Int
        package let maximumDocumentBytes: Int
        package let maximumCompletedWorkspaceCount: Int
        package let maximumPendingPublicationCount: Int

        package init(
            maximumPendingDocumentCount: Int,
            maximumRetainedInputBytes: Int,
            maximumDocumentBytes: Int,
            maximumCompletedWorkspaceCount: Int,
            maximumPendingPublicationCount: Int = 16
        ) {
            precondition(maximumPendingDocumentCount >= 0)
            precondition(maximumRetainedInputBytes >= 0)
            precondition(maximumDocumentBytes >= 0)
            precondition(maximumCompletedWorkspaceCount >= 0)
            precondition(maximumPendingPublicationCount >= 0)
            self.maximumPendingDocumentCount = maximumPendingDocumentCount
            self.maximumRetainedInputBytes = maximumRetainedInputBytes
            self.maximumDocumentBytes = maximumDocumentBytes
            self.maximumCompletedWorkspaceCount = maximumCompletedWorkspaceCount
            self.maximumPendingPublicationCount = maximumPendingPublicationCount
        }

        package static let production = Limits(
            maximumPendingDocumentCount: 32,
            maximumRetainedInputBytes: 64 * 1024 * 1024,
            maximumDocumentBytes: 32 * 1024 * 1024,
            maximumCompletedWorkspaceCount: 256,
            maximumPendingPublicationCount: 16
        )
    }

    package struct Snapshot: Sendable, Equatable {
        package let isAcceptingObservations: Bool
        package let hasActiveProjection: Bool
        package let activeInputBytes: Int
        package let pendingDocumentCount: Int
        package let pendingInputBytes: Int
        package let completedWorkspaceCount: Int
        package let matchedCount: UInt64
        package let mismatchedCount: UInt64
        package let failedCount: UInt64
        package let recoveredCount: UInt64
        package let droppedCount: UInt64
        package let droppedInputBytes: UInt64
        package let deduplicatedCount: UInt64
        package let ignoredLateResultCount: UInt64
        package let pendingPublicationCount: Int
        package let pendingPublicationInputBytes: Int
        package let publicationMatchedCount: UInt64
        package let publicationFailedCount: UInt64
        package let publicationRebasedCount: UInt64
        package let publicationDroppedCount: UInt64
        package let publicationDroppedInputBytes: UInt64
        package let checkpointRecoveredCount: UInt64
        package let checkpointRecoveryFailedCount: UInt64
        package let checkpointPersistedCount: UInt64
        package let checkpointPersistenceFailedCount: UInt64
    }

    package typealias Projector = @Sendable (Data) async throws -> DomainWorkspaceDocumentReadProjection
    package typealias PublicationProjector = @Sendable (
        [DomainWorkspaceDocument],
        DomainWorkspaceEvent
    ) async throws -> Bool
    package typealias CheckpointLoader = @Sendable () async throws -> Data?
    package typealias CheckpointWriter = @Sendable (Data) async throws -> Void

    private enum Lifecycle {
        case created
        case running
        case stopped
    }

    private enum CompletionStatus: Sendable {
        case matched
        case mismatched(Set<DomainWorkspaceProjectionMismatchField>)
        case failed(ErrorReason)

        var isQuarantined: Bool {
            switch self {
            case .matched:
                false
            case .mismatched, .failed:
                true
            }
        }
    }

    private enum ErrorReason: String, Sendable {
        case inputTooLarge = "input_too_large"
        case invalidSwiftProjection = "invalid_swift_projection"
        case cancelled
        case projectionFailure = "projection_failure"
    }

    private struct WorkItem: Sendable {
        let workspaceID: UUID
        let contentDigest: String
        let byteCount: Int
        let source: DomainWorkspaceProjectionObservationSource
        let sequence: UInt64
        let document: DomainWorkspaceDocument?

        var chargedInputBytes: Int {
            document == nil ? 0 : byteCount
        }
    }

    private struct CompletedState: Sendable {
        let contentDigest: String
        let status: CompletionStatus
        let completionSequence: UInt64
    }

    private struct LatestObservation: Sendable {
        let contentDigest: String
        let sequence: UInt64
    }

    private struct QueuePressure: Sendable {
        let droppedCount: UInt64
        let droppedInputBytes: UInt64
    }

    private final class RetainedInputBudget: @unchecked Sendable {
        private let maximumBytes: Int
        private let lock = NSLock()
        private var retainedBytes = 0

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        func tryCharge(_ bytes: Int) -> Bool {
            guard bytes > 0 else { return true }
            return lock.withLock {
                let next = retainedBytes.addingReportingOverflow(bytes)
                guard !next.overflow, next.partialValue <= maximumBytes else { return false }
                retainedBytes = next.partialValue
                return true
            }
        }

        func release(_ bytes: Int) {
            guard bytes > 0 else { return }
            lock.withLock {
                retainedBytes = retainedBytes >= bytes ? retainedBytes - bytes : 0
            }
        }
    }

    private final class Ingress: @unchecked Sendable {
        private enum Lifecycle {
            case created
            case open
            case closed
        }

        private struct State {
            var lifecycle: Lifecycle = .created
            var nextSequence: UInt64 = 0
            var pendingByWorkspaceID: [UUID: WorkItem] = [:]
            var pendingOrder: [UUID] = []
            var pendingInputBytes = 0
            var active: WorkItem?
            var completedByWorkspaceID: [UUID: CompletedState] = [:]
            var latestObservationByWorkspaceID: [UUID: LatestObservation] = [:]
            var matchedCount: UInt64 = 0
            var mismatchedCount: UInt64 = 0
            var failedCount: UInt64 = 0
            var recoveredCount: UInt64 = 0
            var droppedCount: UInt64 = 0
            var droppedInputBytes: UInt64 = 0
            var pendingPressureDroppedCount: UInt64 = 0
            var pendingPressureDroppedInputBytes: UInt64 = 0
            var deduplicatedCount: UInt64 = 0
            var ignoredLateResultCount: UInt64 = 0
        }

        private let limits: Limits
        private let budget: RetainedInputBudget
        private let lock = NSLock()
        private var state = State()
        let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init(limits: Limits, budget: RetainedInputBudget) {
            self.limits = limits
            self.budget = budget
            var capturedContinuation: AsyncStream<Void>.Continuation?
            stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                capturedContinuation = continuation
            }
            continuation = capturedContinuation!
        }

        func open() -> Bool {
            lock.withLock {
                guard state.lifecycle == .created else { return false }
                state.lifecycle = .open
                return true
            }
        }

        func observe(
            _ document: DomainWorkspaceDocument,
            source: DomainWorkspaceProjectionObservationSource
        ) {
            let shouldWake = lock.withLock { () -> Bool in
                guard state.lifecycle == .open else { return false }
                state.nextSequence &+= 1
                let sequence = state.nextSequence
                let workspaceID = document.workspaceID
                let digest = document.contentDigest
                state.latestObservationByWorkspaceID[workspaceID] = LatestObservation(
                    contentDigest: digest,
                    sequence: sequence
                )

                if state.active?.workspaceID == workspaceID,
                   state.active?.contentDigest == digest
                {
                    removePending(workspaceID: workspaceID)
                    state.deduplicatedCount &+= 1
                    return false
                }
                if let completed = state.completedByWorkspaceID[workspaceID],
                   completed.contentDigest == digest
                {
                    removePending(workspaceID: workspaceID)
                    state.completedByWorkspaceID[workspaceID] = CompletedState(
                        contentDigest: completed.contentDigest,
                        status: completed.status,
                        completionSequence: sequence
                    )
                    state.deduplicatedCount &+= 1
                    return false
                }
                if let pending = state.pendingByWorkspaceID[workspaceID],
                   pending.contentDigest == digest
                {
                    let refreshed = WorkItem(
                        workspaceID: workspaceID,
                        contentDigest: digest,
                        byteCount: pending.byteCount,
                        source: source,
                        sequence: sequence,
                        document: pending.document
                    )
                    state.pendingByWorkspaceID[workspaceID] = refreshed
                    state.pendingOrder.removeAll { $0 == workspaceID }
                    state.pendingOrder.append(workspaceID)
                    state.deduplicatedCount &+= 1
                    return false
                }

                removePending(workspaceID: workspaceID)
                let byteCount = document.documentBytes.count
                let oversized = byteCount > limits.maximumDocumentBytes
                let item = WorkItem(
                    workspaceID: workspaceID,
                    contentDigest: digest,
                    byteCount: byteCount,
                    source: source,
                    sequence: sequence,
                    document: oversized ? nil : document
                )
                guard chargeOrMakeRoom(for: item) else {
                    recordDropped(item)
                    refreshLatestTracking(workspaceID: workspaceID)
                    return true
                }
                state.pendingByWorkspaceID[workspaceID] = item
                state.pendingOrder.append(workspaceID)
                state.pendingInputBytes += item.chargedInputBytes
                enforceBounds()
                return state.pendingByWorkspaceID[workspaceID]?.sequence == sequence
                    || state.pendingPressureDroppedCount > 0
            }
            if shouldWake { continuation.yield(()) }
        }

        func takeNext() -> WorkItem? {
            lock.withLock {
                guard state.lifecycle == .open, state.active == nil else { return nil }
                while let workspaceID = state.pendingOrder.first {
                    state.pendingOrder.removeFirst()
                    guard let item = state.pendingByWorkspaceID.removeValue(forKey: workspaceID) else {
                        continue
                    }
                    state.pendingInputBytes -= item.chargedInputBytes
                    state.active = item
                    return item
                }
                return nil
            }
        }

        func complete(_ item: WorkItem, status: CompletionStatus) -> (committed: Bool, recovered: Bool) {
            lock.withLock {
                guard state.active?.sequence == item.sequence else {
                    state.ignoredLateResultCount &+= 1
                    return (false, false)
                }
                state.active = nil
                budget.release(item.chargedInputBytes)
                guard state.lifecycle == .open else {
                    state.ignoredLateResultCount &+= 1
                    return (false, false)
                }
                if let latest = state.latestObservationByWorkspaceID[item.workspaceID],
                   latest.contentDigest != item.contentDigest
                {
                    state.ignoredLateResultCount &+= 1
                    refreshLatestTracking(workspaceID: item.workspaceID)
                    return (false, false)
                }
                let previousWasQuarantined = state.completedByWorkspaceID[item.workspaceID]
                    .map { $0.contentDigest != item.contentDigest && $0.status.isQuarantined }
                    ?? false
                switch status {
                case .matched:
                    state.matchedCount &+= 1
                    if previousWasQuarantined { state.recoveredCount &+= 1 }
                case .mismatched:
                    state.mismatchedCount &+= 1
                case .failed:
                    state.failedCount &+= 1
                }
                state.nextSequence &+= 1
                state.completedByWorkspaceID[item.workspaceID] = CompletedState(
                    contentDigest: item.contentDigest,
                    status: status,
                    completionSequence: state.nextSequence
                )
                evictCompletedStateIfNeeded()
                refreshLatestTracking(workspaceID: item.workspaceID)
                return (true, previousWasQuarantined && !status.isQuarantined)
            }
        }

        func abandonActive(_ item: WorkItem) {
            lock.withLock {
                guard state.active?.sequence == item.sequence else { return }
                state.active = nil
                budget.release(item.chargedInputBytes)
                state.ignoredLateResultCount &+= 1
                refreshLatestTracking(workspaceID: item.workspaceID)
            }
        }

        func takeQueuePressure() -> QueuePressure? {
            lock.withLock {
                guard state.pendingPressureDroppedCount > 0 else { return nil }
                let pressure = QueuePressure(
                    droppedCount: state.pendingPressureDroppedCount,
                    droppedInputBytes: state.pendingPressureDroppedInputBytes
                )
                state.pendingPressureDroppedCount = 0
                state.pendingPressureDroppedInputBytes = 0
                return pressure
            }
        }

        func close() {
            lock.withLock {
                guard state.lifecycle != .closed else { return }
                state.lifecycle = .closed
                budget.release(state.pendingInputBytes)
                state.pendingByWorkspaceID.removeAll(keepingCapacity: false)
                state.pendingOrder.removeAll(keepingCapacity: false)
                state.pendingInputBytes = 0
                state.latestObservationByWorkspaceID.removeAll(keepingCapacity: false)
            }
            continuation.finish()
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(
                    isAcceptingObservations: state.lifecycle == .open,
                    hasActiveProjection: state.active != nil,
                    activeInputBytes: state.active?.chargedInputBytes ?? 0,
                    pendingDocumentCount: state.pendingByWorkspaceID.count,
                    pendingInputBytes: state.pendingInputBytes,
                    completedWorkspaceCount: state.completedByWorkspaceID.count,
                    matchedCount: state.matchedCount,
                    mismatchedCount: state.mismatchedCount,
                    failedCount: state.failedCount,
                    recoveredCount: state.recoveredCount,
                    droppedCount: state.droppedCount,
                    droppedInputBytes: state.droppedInputBytes,
                    deduplicatedCount: state.deduplicatedCount,
                    ignoredLateResultCount: state.ignoredLateResultCount,
                    pendingPublicationCount: 0,
                    pendingPublicationInputBytes: 0,
                    publicationMatchedCount: 0,
                    publicationFailedCount: 0,
                    publicationRebasedCount: 0,
                    publicationDroppedCount: 0,
                    publicationDroppedInputBytes: 0,
                    checkpointRecoveredCount: 0,
                    checkpointRecoveryFailedCount: 0,
                    checkpointPersistedCount: 0,
                    checkpointPersistenceFailedCount: 0
                )
            }
        }

        private func removePending(workspaceID: UUID) {
            if let removed = state.pendingByWorkspaceID.removeValue(forKey: workspaceID) {
                state.pendingInputBytes -= removed.chargedInputBytes
                budget.release(removed.chargedInputBytes)
            }
            state.pendingOrder.removeAll { $0 == workspaceID }
        }

        private func chargeOrMakeRoom(for item: WorkItem) -> Bool {
            while !budget.tryCharge(item.chargedInputBytes) {
                guard dropOldestPending() else { return false }
            }
            return true
        }

        private func enforceBounds() {
            while state.pendingByWorkspaceID.count > limits.maximumPendingDocumentCount {
                guard dropOldestPending() else { return }
            }
        }

        @discardableResult
        private func dropOldestPending() -> Bool {
            while let oldestWorkspaceID = state.pendingOrder.first {
                state.pendingOrder.removeFirst()
                guard let removed = state.pendingByWorkspaceID.removeValue(forKey: oldestWorkspaceID) else {
                    continue
                }
                state.pendingInputBytes -= removed.chargedInputBytes
                budget.release(removed.chargedInputBytes)
                recordDropped(removed)
                refreshLatestTracking(workspaceID: oldestWorkspaceID)
                return true
            }
            return false
        }

        private func recordDropped(_ item: WorkItem) {
            state.droppedCount &+= 1
            state.pendingPressureDroppedCount &+= 1
            let droppedBytes = UInt64(clamping: item.byteCount)
            state.droppedInputBytes &+= droppedBytes
            state.pendingPressureDroppedInputBytes &+= droppedBytes
        }

        private func refreshLatestTracking(workspaceID: UUID) {
            if let pending = state.pendingByWorkspaceID[workspaceID] {
                state.latestObservationByWorkspaceID[workspaceID] = LatestObservation(
                    contentDigest: pending.contentDigest,
                    sequence: pending.sequence
                )
            } else if let active = state.active, active.workspaceID == workspaceID {
                state.latestObservationByWorkspaceID[workspaceID] = LatestObservation(
                    contentDigest: active.contentDigest,
                    sequence: active.sequence
                )
            } else {
                state.latestObservationByWorkspaceID.removeValue(forKey: workspaceID)
            }
        }

        private func evictCompletedStateIfNeeded() {
            while state.completedByWorkspaceID.count > limits.maximumCompletedWorkspaceCount,
                  let eviction = state.completedByWorkspaceID.min(by: {
                      $0.value.completionSequence < $1.value.completionSequence
                  })
            {
                state.completedByWorkspaceID.removeValue(forKey: eviction.key)
            }
        }
    }

    private struct PublicationWorkItem: Sendable {
        let event: DomainWorkspaceEvent
        let workspaces: [DomainWorkspaceSnapshot]?
        let byteCount: Int

        var chargedInputBytes: Int {
            workspaces == nil ? 0 : byteCount
        }
    }

    private final class PublicationIngress: @unchecked Sendable {
        private enum Lifecycle {
            case created
            case open
            case closed
        }

        struct SnapshotInfo: Sendable {
            let isAccepting: Bool
            let hasActive: Bool
            let activeInputBytes: Int
            let pendingCount: Int
            let pendingInputBytes: Int
            let matchedCount: UInt64
            let failedCount: UInt64
            let rebasedCount: UInt64
            let droppedCount: UInt64
            let droppedInputBytes: UInt64
        }

        private struct State {
            var lifecycle: Lifecycle = .created
            var pending: [PublicationWorkItem] = []
            var pendingInputBytes = 0
            var active: PublicationWorkItem?
            var matchedCount: UInt64 = 0
            var failedCount: UInt64 = 0
            var rebasedCount: UInt64 = 0
            var droppedCount: UInt64 = 0
            var droppedInputBytes: UInt64 = 0
        }

        private let limits: Limits
        private let budget: RetainedInputBudget
        private let lock = NSLock()
        private var state = State()
        let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init(limits: Limits, budget: RetainedInputBudget) {
            self.limits = limits
            self.budget = budget
            var capturedContinuation: AsyncStream<Void>.Continuation?
            stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                capturedContinuation = continuation
            }
            continuation = capturedContinuation!
        }

        func open() -> Bool {
            lock.withLock {
                guard state.lifecycle == .created else { return false }
                state.lifecycle = .open
                return true
            }
        }

        func observe(_ event: DomainWorkspaceEvent, workspaces: [DomainWorkspaceSnapshot]) {
            let shouldWake = lock.withLock { () -> Bool in
                guard state.lifecycle == .open else { return false }
                let byteCount = workspaces.reduce(into: 0) { total, workspace in
                    let next = total.addingReportingOverflow(workspace.document.documentBytes.count)
                    total = next.overflow ? .max : next.partialValue
                }
                let hasOversizedDocument = workspaces.contains {
                    $0.document.documentBytes.count > limits.maximumDocumentBytes
                }
                let oversized = hasOversizedDocument || byteCount > limits.maximumRetainedInputBytes
                let item = PublicationWorkItem(
                    event: event,
                    workspaces: oversized ? nil : workspaces,
                    byteCount: byteCount
                )
                guard chargeOrMakeRoom(for: item) else {
                    recordDropped(item)
                    return false
                }
                state.pending.append(item)
                state.pendingInputBytes += item.chargedInputBytes
                enforceBounds()
                return state.pending.contains { $0.event.sequence == event.sequence }
            }
            if shouldWake { continuation.yield(()) }
        }

        func takeNext() -> PublicationWorkItem? {
            lock.withLock {
                guard state.lifecycle == .open, state.active == nil, !state.pending.isEmpty else { return nil }
                let item = state.pending.removeFirst()
                state.pendingInputBytes -= item.chargedInputBytes
                state.active = item
                return item
            }
        }

        func complete(_ item: PublicationWorkItem, succeeded: Bool, rebased: Bool) {
            lock.withLock {
                guard state.active?.event.sequence == item.event.sequence else { return }
                state.active = nil
                budget.release(item.chargedInputBytes)
                if succeeded {
                    state.matchedCount &+= 1
                    if rebased { state.rebasedCount &+= 1 }
                } else {
                    state.failedCount &+= 1
                }
            }
        }

        func abandon(_ item: PublicationWorkItem) {
            lock.withLock {
                guard state.active?.event.sequence == item.event.sequence else { return }
                state.active = nil
                budget.release(item.chargedInputBytes)
            }
        }

        func close() {
            lock.withLock {
                guard state.lifecycle != .closed else { return }
                state.lifecycle = .closed
                budget.release(state.pendingInputBytes)
                state.pending.removeAll(keepingCapacity: false)
                state.pendingInputBytes = 0
            }
            continuation.finish()
        }

        func snapshot() -> SnapshotInfo {
            lock.withLock {
                SnapshotInfo(
                    isAccepting: state.lifecycle == .open,
                    hasActive: state.active != nil,
                    activeInputBytes: state.active?.chargedInputBytes ?? 0,
                    pendingCount: state.pending.count,
                    pendingInputBytes: state.pendingInputBytes,
                    matchedCount: state.matchedCount,
                    failedCount: state.failedCount,
                    rebasedCount: state.rebasedCount,
                    droppedCount: state.droppedCount,
                    droppedInputBytes: state.droppedInputBytes
                )
            }
        }

        private func chargeOrMakeRoom(for item: PublicationWorkItem) -> Bool {
            while !budget.tryCharge(item.chargedInputBytes) {
                guard dropOldestPending() else { return false }
            }
            return true
        }

        private func enforceBounds() {
            while state.pending.count > limits.maximumPendingPublicationCount {
                guard dropOldestPending() else { return }
            }
        }

        @discardableResult
        private func dropOldestPending() -> Bool {
            guard !state.pending.isEmpty else { return false }
            let removed = state.pending.removeFirst()
            state.pendingInputBytes -= removed.chargedInputBytes
            budget.release(removed.chargedInputBytes)
            recordDropped(removed)
            return true
        }

        private func recordDropped(_ item: PublicationWorkItem) {
            state.droppedCount &+= 1
            state.droppedInputBytes &+= UInt64(clamping: item.byteCount)
        }
    }

    private let identity: DomainRuntimeIdentity
    private let metrics: DomainRuntimeMetricsSink
    private let projector: Projector
    private let statefulProjector: DomainWorkspaceStatefulRustProjector?
    private let statefulStorageScopeDigest: String?
    private let statefulMutationAccess: DomainWorkspaceMutationAccess?
    private let publicationProjector: PublicationProjector?
    private let checkpointLoader: CheckpointLoader?
    private let checkpointWriter: CheckpointWriter?
    private let ingress: Ingress
    private let publicationIngress: PublicationIngress
    package nonisolated let sink: DomainWorkspaceProjectionObservationSink
    private var lifecycle: Lifecycle = .created
    private var workerTask: Task<Void, Never>?
    private var publicationWorkerTask: Task<Void, Never>?
    private var checkpointRecoveredCount: UInt64 = 0
    private var checkpointRecoveryFailedCount: UInt64 = 0
    private var checkpointPersistedCount: UInt64 = 0
    private var checkpointPersistenceFailedCount: UInt64 = 0
    private var activationLeaseToken: DomainWorkspaceMutationLeaseToken?

    package init(
        identity: DomainRuntimeIdentity,
        metrics: DomainRuntimeMetricsSink,
        limits: Limits = .production,
        statefulScopeID: UUID? = nil,
        statefulStorageScopeDigest: String? = nil,
        statefulMutationAccess: DomainWorkspaceMutationAccess? = nil,
        checkpointLoader: CheckpointLoader? = nil,
        checkpointWriter: CheckpointWriter? = nil,
        projector: Projector? = nil,
        publicationProjector: PublicationProjector? = nil
    ) {
        self.identity = identity
        self.metrics = metrics
        let resolvedStatefulProjector: DomainWorkspaceStatefulRustProjector?
        if let projector {
            self.projector = projector
            resolvedStatefulProjector = nil
        } else {
            let statefulProjector = DomainWorkspaceStatefulRustProjector(
                scopeID: statefulScopeID ?? identity.runtimeID
            )
            resolvedStatefulProjector = statefulProjector
            self.projector = { documentBytes in
                try await statefulProjector.project(documentBytes: documentBytes)
            }
        }
        statefulProjector = resolvedStatefulProjector
        self.statefulStorageScopeDigest = statefulStorageScopeDigest
        self.statefulMutationAccess = statefulMutationAccess
        self.publicationProjector = publicationProjector
        self.checkpointLoader = checkpointLoader
        self.checkpointWriter = checkpointWriter
        let retainedInputBudget = RetainedInputBudget(maximumBytes: limits.maximumRetainedInputBytes)
        let ingress = Ingress(limits: limits, budget: retainedInputBudget)
        self.ingress = ingress
        let publicationIngress = PublicationIngress(limits: limits, budget: retainedInputBudget)
        self.publicationIngress = publicationIngress
        let publicationObservation: @Sendable (
            DomainWorkspaceEvent,
            [DomainWorkspaceSnapshot]
        ) -> Void
        if publicationProjector == nil, resolvedStatefulProjector == nil {
            publicationObservation = { _, _ in }
        } else {
            publicationObservation = { event, workspaces in
                publicationIngress.observe(event, workspaces: workspaces)
            }
        }
        sink = DomainWorkspaceProjectionObservationSink(
            observe: { document, source in
                ingress.observe(document, source: source)
            },
            observePublication: publicationObservation
        )
    }

    package func start(paused: Bool = false) {
        guard lifecycle == .created, ingress.open(), publicationIngress.open() else { return }
        lifecycle = .running
        if !paused { startWorkers() }
    }

    package func activateStatefulProjection(
        leaseToken: DomainWorkspaceMutationLeaseToken
    ) async -> Bool {
        guard lifecycle == .running,
              workerTask == nil,
              publicationWorkerTask == nil
        else { return activationLeaseToken != nil || statefulProjector == nil }
        guard let statefulProjector else {
            startWorkers()
            return true
        }
        guard let statefulStorageScopeDigest else { return false }

        do {
            try await leaseToken.validate(expectedStorageScopeDigest: statefulStorageScopeDigest)
            let checkpoint: Data?
            do {
                checkpoint = try await checkpointLoader?()
            } catch {
                recordCheckpointRecoveryFailure()
                checkpoint = nil
            }
            guard lifecycle == .running, !Task.isCancelled else { return false }
            try await leaseToken.validate(expectedStorageScopeDigest: statefulStorageScopeDigest)
            if let checkpoint {
                do {
                    _ = try await statefulProjector.restoreCheckpointForNewPublicationEpoch(checkpoint)
                    checkpointRecoveredCount &+= 1
                    recordCheckpointResult(operation: "recovery", result: "recovered")
                } catch {
                    recordCheckpointRecoveryFailure()
                    try await statefulProjector.prepare()
                }
            } else {
                try await statefulProjector.prepare()
            }
            guard lifecycle == .running, !Task.isCancelled else { return false }
            try await leaseToken.validate(expectedStorageScopeDigest: statefulStorageScopeDigest)
            activationLeaseToken = leaseToken
            startWorkers()
            return true
        } catch {
            if lifecycle == .running, !Task.isCancelled {
                recordCheckpointRecoveryFailure()
            }
            return false
        }
    }

    private func recordCheckpointRecoveryFailure() {
        checkpointRecoveryFailedCount &+= 1
        recordCheckpointResult(operation: "recovery", result: "error")
    }

    private func startWorkers() {
        guard workerTask == nil, publicationWorkerTask == nil else { return }
        let stream = ingress.stream
        workerTask = Task { [weak self] in
            await self?.run(stream)
        }
        if publicationProjector != nil || statefulProjector != nil {
            let publicationStream = publicationIngress.stream
            publicationWorkerTask = Task { [weak self] in
                await self?.runPublications(publicationStream)
            }
        }
    }

    package func shutdown() async {
        guard lifecycle != .stopped else { return }
        lifecycle = .stopped
        ingress.close()
        publicationIngress.close()
        let task = workerTask
        let publicationTask = publicationWorkerTask
        workerTask = nil
        publicationWorkerTask = nil
        task?.cancel()
        publicationTask?.cancel()
        await task?.value
        await publicationTask?.value
        activationLeaseToken = nil
        await statefulProjector?.shutdown()
    }

    /// Returns the Rust-owned projection at one immutable committed generation. An injected
    /// comparison projector has no stateful read authority and fails closed here; it can never
    /// silently reactivate Swift canonical values in production. Lease validation brackets the
    /// suspending snapshot read so a retired storage owner cannot serve canonical values.
    package func authoritativeWorkspaceProjection(
        workspaceID: UUID
    ) async throws -> DomainWorkspaceAuthoritativeProjectionRead {
        guard lifecycle == .running else {
            throw DomainWorkspaceStatefulRustProjectionError.stopped
        }
        guard let statefulProjector else {
            throw DomainWorkspaceStatefulRustProjectionError.authoritativeReadUnavailable
        }
        try await validateActiveStatefulProjectionLease()
        let read = try await statefulProjector.readWorkspace(workspaceID: workspaceID)
        try Task.checkCancellation()
        try await validateActiveStatefulProjectionLease()
        guard lifecycle == .running else {
            throw DomainWorkspaceStatefulRustProjectionError.stopped
        }
        return read
    }

    /// Repairs a missing or stale read projection only while the exact generation, publication
    /// cursor, and storage-lease epoch observed by the caller remain current. The projector keeps
    /// one operation permit across validation, conditional upsert, and the resulting snapshot read;
    /// every success and error path revalidates the captured lease before returning.
    package func reconcileAuthoritativeWorkspaceProjection(
        workspace: DomainWorkspaceSnapshot,
        expectedGeneration: UInt64,
        expectedCatalogRevision: UInt64,
        expectedPublicationSequence: UInt64
    ) async throws -> DomainWorkspaceAuthoritativeProjectionRead {
        guard lifecycle == .running else {
            throw DomainWorkspaceStatefulRustProjectionError.stopped
        }
        guard let statefulProjector,
              let statefulMutationAccess,
              let statefulStorageScopeDigest
        else {
            throw DomainWorkspaceStatefulRustProjectionError.authoritativeReadUnavailable
        }
        let read = try await statefulMutationAccess.withReconciliationPermit { permit in
            let validatePermit: @Sendable () async throws -> Void = {
                try await permit.validate(
                    expectedStorageScopeDigest: statefulStorageScopeDigest
                )
            }
            return try await statefulProjector.reconcileWorkspace(
                workspace: workspace,
                expectedGeneration: expectedGeneration,
                expectedCatalogRevision: expectedCatalogRevision,
                expectedPublicationSequence: expectedPublicationSequence,
                validateLease: validatePermit
            )
        }
        try Task.checkCancellation()
        try await validateActiveStatefulProjectionLease()
        guard lifecycle == .running else {
            throw DomainWorkspaceStatefulRustProjectionError.stopped
        }
        return read
    }

    package func snapshot() -> Snapshot {
        let document = ingress.snapshot()
        let publication = publicationIngress.snapshot()
        return Snapshot(
            isAcceptingObservations: document.isAcceptingObservations && publication.isAccepting,
            hasActiveProjection: document.hasActiveProjection || publication.hasActive,
            activeInputBytes: document.activeInputBytes + publication.activeInputBytes,
            pendingDocumentCount: document.pendingDocumentCount,
            pendingInputBytes: document.pendingInputBytes,
            completedWorkspaceCount: document.completedWorkspaceCount,
            matchedCount: document.matchedCount,
            mismatchedCount: document.mismatchedCount,
            failedCount: document.failedCount,
            recoveredCount: document.recoveredCount,
            droppedCount: document.droppedCount,
            droppedInputBytes: document.droppedInputBytes,
            deduplicatedCount: document.deduplicatedCount,
            ignoredLateResultCount: document.ignoredLateResultCount,
            pendingPublicationCount: publication.pendingCount,
            pendingPublicationInputBytes: publication.pendingInputBytes,
            publicationMatchedCount: publication.matchedCount,
            publicationFailedCount: publication.failedCount,
            publicationRebasedCount: publication.rebasedCount,
            publicationDroppedCount: publication.droppedCount,
            publicationDroppedInputBytes: publication.droppedInputBytes,
            checkpointRecoveredCount: checkpointRecoveredCount,
            checkpointRecoveryFailedCount: checkpointRecoveryFailedCount,
            checkpointPersistedCount: checkpointPersistedCount,
            checkpointPersistenceFailedCount: checkpointPersistenceFailedCount
        )
    }

    private func run(_ stream: AsyncStream<Void>) async {
        for await _ in stream {
            recordQueuePressureIfNeeded()
            while !Task.isCancelled, let item = ingress.takeNext() {
                await process(item)
                recordQueuePressureIfNeeded()
            }
        }
    }

    private func runPublications(_ stream: AsyncStream<Void>) async {
        for await _ in stream {
            while !Task.isCancelled, let item = publicationIngress.takeNext() {
                await processPublication(item)
            }
        }
    }

    private func processPublication(_ item: PublicationWorkItem) async {
        guard let workspaces = item.workspaces else {
            publicationIngress.complete(item, succeeded: false, rebased: false)
            recordPublicationResult(item, result: "error", rebased: false)
            return
        }
        do {
            let rebased: Bool
            let checkpoint: Data?
            let checkpointExpected: Bool
            if let publicationProjector {
                rebased = try await publicationProjector(workspaces.map(\.document), item.event)
                checkpoint = nil
                checkpointExpected = false
            } else if let statefulProjector {
                try await validateActiveStatefulProjectionLease()
                let publication = try await statefulProjector.publish(
                    workspaces: workspaces,
                    event: item.event
                )
                rebased = publication.receipt.rebased
                checkpoint = publication.checkpoint
                checkpointExpected = checkpointWriter != nil
            } else {
                throw CancellationError()
            }
            guard !Task.isCancelled else {
                publicationIngress.abandon(item)
                return
            }
            publicationIngress.complete(item, succeeded: true, rebased: rebased)
            recordPublicationResult(item, result: "matched", rebased: rebased)
            await persistCheckpointIfNeeded(checkpoint, expected: checkpointExpected)
        } catch {
            guard !Task.isCancelled else {
                publicationIngress.abandon(item)
                return
            }
            publicationIngress.complete(item, succeeded: false, rebased: false)
            recordPublicationResult(item, result: "error", rebased: false)
        }
    }

    private func persistCheckpointIfNeeded(_ checkpoint: Data?, expected: Bool) async {
        guard expected, let checkpointWriter else { return }
        guard let checkpoint else {
            checkpointPersistenceFailedCount &+= 1
            recordCheckpointResult(operation: "persistence", result: "error")
            return
        }
        do {
            try await checkpointWriter(checkpoint)
            checkpointPersistedCount &+= 1
            recordCheckpointResult(operation: "persistence", result: "persisted")
        } catch {
            checkpointPersistenceFailedCount &+= 1
            recordCheckpointResult(operation: "persistence", result: "error")
        }
    }

    private func recordCheckpointResult(operation: String, result: String) {
        var dimensions = baseDimensions(source: nil)
        dimensions["operation"] = operation
        dimensions["result"] = result
        metrics.record(DomainRuntimeMetric(
            phase: .projection,
            name: "EditFlow.DomainRuntime.WorkspaceProjectionCheckpoint",
            dimensions: dimensions
        ))
    }

    private func recordPublicationResult(
        _ item: PublicationWorkItem,
        result: String,
        rebased: Bool
    ) {
        var dimensions = baseDimensions(source: nil)
        dimensions["result"] = result
        dimensions["event_kind"] = item.event.kind.rawValue
        dimensions["publication_sequence"] = String(item.event.sequence)
        dimensions["catalog_revision"] = String(item.event.catalogRevision)
        dimensions["workspace_count"] = String(item.workspaces?.count ?? 0)
        dimensions["input_bytes"] = String(item.byteCount)
        dimensions["rebased"] = String(rebased)
        metrics.record(DomainRuntimeMetric(
            phase: .projection,
            name: "EditFlow.DomainRuntime.WorkspacePublicationComparison",
            dimensions: dimensions
        ))
    }

    private func process(_ item: WorkItem) async {
        guard let document = item.document else {
            commit(item, status: .failed(.inputTooLarge))
            return
        }
        let expected: DomainWorkspaceDocumentReadProjection
        do {
            expected = try DomainWorkspaceRustProjection.swiftProjection(document)
        } catch {
            commit(item, status: .failed(.invalidSwiftProjection))
            return
        }

        do {
            try await validateActiveStatefulProjectionLease()
            let actual = try await projector(document.documentBytes)
            guard !Task.isCancelled else {
                ingress.abandonActive(item)
                return
            }
            let mismatchFields = DomainWorkspaceRustProjection.mismatchFields(
                expected: expected,
                actual: actual
            )
            commit(
                item,
                status: mismatchFields.isEmpty ? .matched : .mismatched(mismatchFields)
            )
        } catch is CancellationError {
            guard !Task.isCancelled else {
                ingress.abandonActive(item)
                return
            }
            commit(item, status: .failed(.cancelled))
        } catch {
            guard !Task.isCancelled else {
                ingress.abandonActive(item)
                return
            }
            commit(item, status: .failed(.projectionFailure))
        }
    }

    private func commit(_ item: WorkItem, status: CompletionStatus) {
        let result = ingress.complete(item, status: status)
        guard result.committed else { return }
        var dimensions = baseDimensions(source: item.source)
        dimensions["workspace_id"] = item.workspaceID.uuidString
        dimensions["input_bytes"] = String(item.byteCount)
        dimensions["result"] = result.recovered ? "recovered" : resultName(status)
        switch status {
        case .matched:
            break
        case let .mismatched(fields):
            dimensions["mismatch_fields"] = fields.map(\.rawValue).sorted().joined(separator: ",")
        case let .failed(reason):
            dimensions["error_reason"] = reason.rawValue
        }
        metrics.record(DomainRuntimeMetric(
            phase: .projection,
            name: "EditFlow.DomainRuntime.WorkspaceProjectionComparison",
            dimensions: dimensions
        ))
    }

    private func recordQueuePressureIfNeeded() {
        guard let pressure = ingress.takeQueuePressure() else { return }
        var dimensions = baseDimensions(source: nil)
        dimensions["dropped_count"] = String(pressure.droppedCount)
        dimensions["dropped_input_bytes"] = String(pressure.droppedInputBytes)
        metrics.record(DomainRuntimeMetric(
            phase: .projection,
            name: "EditFlow.DomainRuntime.WorkspaceProjectionQueuePressure",
            dimensions: dimensions
        ))
    }

    private func resultName(_ status: CompletionStatus) -> String {
        switch status {
        case .matched:
            "matched"
        case .mismatched:
            "mismatched"
        case .failed:
            "error"
        }
    }

    private func validateActiveStatefulProjectionLease() async throws {
        guard statefulProjector != nil else { return }
        let validate = try activeStatefulProjectionLeaseValidator()
        try await validate()
    }

    private func activeStatefulProjectionLeaseValidator() throws -> @Sendable () async throws -> Void {
        guard let activationLeaseToken, let statefulStorageScopeDigest else {
            throw DomainWorkspaceMutationAccessError.invalidPermit
        }
        return {
            try await activationLeaseToken.validate(
                expectedStorageScopeDigest: statefulStorageScopeDigest
            )
        }
    }

    private func baseDimensions(
        source: DomainWorkspaceProjectionObservationSource?
    ) -> [String: String] {
        var dimensions = [
            "runtime_id": identity.runtimeID.uuidString,
            "lifecycle_generation": String(identity.lifecycleGeneration),
            "runtime_mode": identity.mode.rawValue,
        ]
        if let source { dimensions["source"] = source.rawValue }
        return dimensions
    }
}
