import Foundation

private enum DomainWorkspaceCommandIdentityObserverError: Error {
    case incompleteAuthoritativeResult
}

package struct DomainWorkspaceCommandIdentityObservationSink: Sendable {
    private let observeBlock: @Sendable (
        DomainWorkspaceCommandEnvelope,
        String,
        UInt64,
        String?,
        UInt64?
    ) -> Void

    package init(
        observe: @escaping @Sendable (
            DomainWorkspaceCommandEnvelope,
            String,
            UInt64,
            String?,
            UInt64?
        ) -> Void
    ) {
        observeBlock = observe
    }

    package func observe(
        _ envelope: DomainWorkspaceCommandEnvelope,
        swiftFingerprint: String,
        swiftLatencyNanoseconds: UInt64,
        authoritativeRustFingerprint: String? = nil,
        authoritativeRustLatencyNanoseconds: UInt64? = nil
    ) {
        observeBlock(
            envelope,
            swiftFingerprint,
            swiftLatencyNanoseconds,
            authoritativeRustFingerprint,
            authoritativeRustLatencyNanoseconds
        )
    }

    package static let disabled = DomainWorkspaceCommandIdentityObservationSink { _, _, _, _, _ in }
}

package actor DomainWorkspaceRustCommandIdentityObserver {
    package struct Limits: Sendable, Equatable {
        package let maximumPendingCommandCount: Int
        package let maximumRetainedInputBytes: Int
        package let maximumCommandBytes: Int

        package init(
            maximumPendingCommandCount: Int,
            maximumRetainedInputBytes: Int,
            maximumCommandBytes: Int
        ) {
            precondition(maximumPendingCommandCount >= 0)
            precondition(maximumRetainedInputBytes >= 0)
            precondition(maximumCommandBytes >= 0)
            self.maximumPendingCommandCount = maximumPendingCommandCount
            self.maximumRetainedInputBytes = maximumRetainedInputBytes
            self.maximumCommandBytes = maximumCommandBytes
        }

        package static let production = Limits(
            maximumPendingCommandCount: 64,
            maximumRetainedInputBytes: 64 * 1024 * 1024,
            maximumCommandBytes: DomainWorkspaceCommandIdentityInput.maximumRetainedBytes
        )
    }

    package struct Snapshot: Sendable, Equatable {
        package let isAcceptingObservations: Bool
        package let hasActiveComparison: Bool
        package let activeInputBytes: Int
        package let pendingCommandCount: Int
        package let pendingInputBytes: Int
        package let matchedCount: UInt64
        package let mismatchedCount: UInt64
        package let failedCount: UInt64
        package let droppedCount: UInt64
        package let droppedInputBytes: UInt64
        package let ignoredLateResultCount: UInt64
        package let totalSwiftLatencyNanoseconds: UInt64
        package let totalRustLatencyNanoseconds: UInt64
        package let maximumSwiftLatencyNanoseconds: UInt64
        package let maximumRustLatencyNanoseconds: UInt64

        package var completedCount: UInt64 {
            let matchedAndMismatched = matchedCount.addingReportingOverflow(mismatchedCount)
            guard !matchedAndMismatched.overflow else { return .max }
            let completed = matchedAndMismatched.partialValue.addingReportingOverflow(failedCount)
            return completed.overflow ? .max : completed.partialValue
        }
    }

    package struct CutoverEvidence: Sendable, Equatable {
        package let minimumCompletedCount: UInt64
        package let completedCount: UInt64
        package let sampleFloorMet: Bool
        package let behavioralParityEstablished: Bool
        package let rustToSwiftTotalLatencyRatio: Double?
    }

    package typealias Projector = @Sendable (
        DomainWorkspaceCommandIdentityInput,
        String
    ) async throws -> String

    private enum Lifecycle {
        case created
        case running
        case stopped
    }

    private enum CompletionStatus: Sendable {
        case matched
        case mismatched
        case failed
    }

    private struct WorkItem: Sendable {
        let sequence: UInt64
        let input: DomainWorkspaceCommandIdentityInput
        let swiftFingerprint: String
        let swiftLatencyNanoseconds: UInt64
        let authoritativeRustFingerprint: String?
        let authoritativeRustLatencyNanoseconds: UInt64?
        let byteCount: Int
        let commandKind: String
        let origin: String
    }

    private struct Completion: Sendable {
        let status: CompletionStatus
        let swiftLatencyNanoseconds: UInt64
        let rustLatencyNanoseconds: UInt64
    }

    private struct QueuePressure: Sendable {
        let droppedCount: UInt64
        let droppedInputBytes: UInt64
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
            var pending: [WorkItem] = []
            var pendingInputBytes = 0
            var active: WorkItem?
            var matchedCount: UInt64 = 0
            var mismatchedCount: UInt64 = 0
            var failedCount: UInt64 = 0
            var droppedCount: UInt64 = 0
            var droppedInputBytes: UInt64 = 0
            var pendingPressureDroppedCount: UInt64 = 0
            var pendingPressureDroppedInputBytes: UInt64 = 0
            var ignoredLateResultCount: UInt64 = 0
            var totalSwiftLatencyNanoseconds: UInt64 = 0
            var totalRustLatencyNanoseconds: UInt64 = 0
            var maximumSwiftLatencyNanoseconds: UInt64 = 0
            var maximumRustLatencyNanoseconds: UInt64 = 0
        }

        private let limits: Limits
        private let lock = NSLock()
        private var state = State()
        let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init(limits: Limits) {
            self.limits = limits
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
            _ envelope: DomainWorkspaceCommandEnvelope,
            swiftFingerprint: String,
            swiftLatencyNanoseconds: UInt64,
            authoritativeRustFingerprint: String?,
            authoritativeRustLatencyNanoseconds: UInt64?
        ) {
            let input = DomainWorkspaceCommandIdentityInput(envelope)
            let byteCount = input.flatMap(\.estimatedRetainedBytes)
            let shouldWake = lock.withLock { () -> Bool in
                guard state.lifecycle == .open else {
                    recordDropped(byteCount: byteCount ?? 0)
                    return false
                }
                state.nextSequence &+= 1
                guard let input, let byteCount else {
                    recordDropped(byteCount: Int.max)
                    return true
                }
                let item = WorkItem(
                    sequence: state.nextSequence,
                    input: input,
                    swiftFingerprint: swiftFingerprint,
                    swiftLatencyNanoseconds: swiftLatencyNanoseconds,
                    authoritativeRustFingerprint: authoritativeRustFingerprint,
                    authoritativeRustLatencyNanoseconds: authoritativeRustLatencyNanoseconds,
                    byteCount: byteCount,
                    commandKind: Self.commandKind(input.command),
                    origin: Self.origin(input.origin)
                )
                guard byteCount <= limits.maximumCommandBytes else {
                    recordDropped(byteCount: byteCount)
                    return true
                }
                while wouldExceedRetainedBytes(adding: byteCount) {
                    guard dropOldestPending() else {
                        recordDropped(byteCount: byteCount)
                        return true
                    }
                }
                state.pending.append(item)
                state.pendingInputBytes += byteCount
                while state.pending.count > limits.maximumPendingCommandCount {
                    guard dropOldestPending() else { break }
                }
                return state.pending.contains { $0.sequence == item.sequence }
                    || state.pendingPressureDroppedCount > 0
            }
            if shouldWake { continuation.yield(()) }
        }

        func takeNext() -> WorkItem? {
            lock.withLock {
                guard state.lifecycle == .open,
                      state.active == nil,
                      !state.pending.isEmpty
                else { return nil }
                let item = state.pending.removeFirst()
                state.pendingInputBytes -= item.byteCount
                state.active = item
                return item
            }
        }

        func complete(_ item: WorkItem, completion: Completion) -> Bool {
            lock.withLock {
                guard state.active?.sequence == item.sequence else {
                    state.ignoredLateResultCount &+= 1
                    return false
                }
                state.active = nil
                guard state.lifecycle == .open else {
                    recordDropped(byteCount: item.byteCount)
                    return false
                }
                switch completion.status {
                case .matched:
                    state.matchedCount &+= 1
                case .mismatched:
                    state.mismatchedCount &+= 1
                case .failed:
                    state.failedCount &+= 1
                }
                state.totalSwiftLatencyNanoseconds = Self.saturatingAdd(
                    state.totalSwiftLatencyNanoseconds,
                    completion.swiftLatencyNanoseconds
                )
                state.totalRustLatencyNanoseconds = Self.saturatingAdd(
                    state.totalRustLatencyNanoseconds,
                    completion.rustLatencyNanoseconds
                )
                state.maximumSwiftLatencyNanoseconds = max(
                    state.maximumSwiftLatencyNanoseconds,
                    completion.swiftLatencyNanoseconds
                )
                state.maximumRustLatencyNanoseconds = max(
                    state.maximumRustLatencyNanoseconds,
                    completion.rustLatencyNanoseconds
                )
                return true
            }
        }

        func abandonActive(_ item: WorkItem) {
            lock.withLock {
                guard state.active?.sequence == item.sequence else { return }
                state.active = nil
                if state.lifecycle == .closed {
                    recordDropped(byteCount: item.byteCount)
                } else {
                    state.ignoredLateResultCount &+= 1
                }
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
                for item in state.pending {
                    recordDropped(byteCount: item.byteCount)
                }
                state.pending.removeAll(keepingCapacity: false)
                state.pendingInputBytes = 0
            }
            continuation.finish()
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(
                    isAcceptingObservations: state.lifecycle == .open,
                    hasActiveComparison: state.active != nil,
                    activeInputBytes: state.active?.byteCount ?? 0,
                    pendingCommandCount: state.pending.count,
                    pendingInputBytes: state.pendingInputBytes,
                    matchedCount: state.matchedCount,
                    mismatchedCount: state.mismatchedCount,
                    failedCount: state.failedCount,
                    droppedCount: state.droppedCount,
                    droppedInputBytes: state.droppedInputBytes,
                    ignoredLateResultCount: state.ignoredLateResultCount,
                    totalSwiftLatencyNanoseconds: state.totalSwiftLatencyNanoseconds,
                    totalRustLatencyNanoseconds: state.totalRustLatencyNanoseconds,
                    maximumSwiftLatencyNanoseconds: state.maximumSwiftLatencyNanoseconds,
                    maximumRustLatencyNanoseconds: state.maximumRustLatencyNanoseconds
                )
            }
        }

        private func wouldExceedRetainedBytes(adding byteCount: Int) -> Bool {
            let retained = state.pendingInputBytes.addingReportingOverflow(
                state.active?.byteCount ?? 0
            )
            guard !retained.overflow else { return true }
            let next = retained.partialValue.addingReportingOverflow(byteCount)
            return next.overflow || next.partialValue > limits.maximumRetainedInputBytes
        }

        @discardableResult
        private func dropOldestPending() -> Bool {
            guard !state.pending.isEmpty else { return false }
            let dropped = state.pending.removeFirst()
            state.pendingInputBytes -= dropped.byteCount
            recordDropped(byteCount: dropped.byteCount)
            return true
        }

        private func recordDropped(byteCount: Int) {
            state.droppedCount &+= 1
            state.pendingPressureDroppedCount &+= 1
            let bytes = UInt64(clamping: byteCount)
            state.droppedInputBytes &+= bytes
            state.pendingPressureDroppedInputBytes &+= bytes
        }

        private static func commandKind(
            _ command: DomainWorkspaceCommandIdentityInput.Command
        ) -> String {
            switch command {
            case .create: "create"
            case .replace: "replace"
            case .save: "save"
            case .delete: "delete"
            case .resolveExternalConflict: "resolve_external_conflict"
            }
        }

        private static func origin(_ origin: DomainCommandOrigin) -> String {
            switch origin {
            case .appPresentation: "app_presentation"
            case .appMCP: "app_mcp"
            case .standalone: "standalone"
            case .externalReload: "external_reload"
            }
        }

        private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? .max : result.partialValue
        }
    }

    private actor DefaultProjector {
        private var prepared: DomainWorkspaceRustJournal.PreparedValidator?

        func project(_ input: DomainWorkspaceCommandIdentityInput) async throws -> String {
            let validator: DomainWorkspaceRustJournal.PreparedValidator
            if let prepared {
                validator = prepared
            } else {
                let created = try await DomainWorkspaceRustJournal.prepare()
                try Task.checkCancellation()
                prepared = created
                validator = created
            }
            do {
                return try await Task.detached(priority: nil) {
                    try validator.commandIdentity(input)
                }.value
            } catch {
                // A prepared validator is exact-runtime bound. Drop it after any failure so a later
                // observation can bind a replacement Core runtime instead of remaining poisoned.
                prepared = nil
                throw error
            }
        }
    }

    private let metrics: DomainRuntimeMetricsSink
    private let projector: Projector
    private let ingress: Ingress
    package nonisolated let sink: DomainWorkspaceCommandIdentityObservationSink
    private var lifecycle: Lifecycle = .created
    private var workerTask: Task<Void, Never>?

    package init(
        metrics: DomainRuntimeMetricsSink,
        limits: Limits = .production,
        projector: Projector? = nil
    ) {
        self.metrics = metrics
        if let projector {
            self.projector = projector
        } else {
            let defaultProjector = DefaultProjector()
            self.projector = { input, _ in
                try await defaultProjector.project(input)
            }
        }
        let ingress = Ingress(limits: limits)
        self.ingress = ingress
        sink = DomainWorkspaceCommandIdentityObservationSink {
            envelope,
            swiftFingerprint,
            swiftLatencyNanoseconds,
            authoritativeRustFingerprint,
            authoritativeRustLatencyNanoseconds in
            ingress.observe(
                envelope,
                swiftFingerprint: swiftFingerprint,
                swiftLatencyNanoseconds: swiftLatencyNanoseconds,
                authoritativeRustFingerprint: authoritativeRustFingerprint,
                authoritativeRustLatencyNanoseconds: authoritativeRustLatencyNanoseconds
            )
        }
    }

    package func start() {
        guard lifecycle == .created, ingress.open() else { return }
        lifecycle = .running
        let stream = ingress.stream
        workerTask = Task { [weak self] in
            await self?.run(stream)
        }
    }

    package func shutdown() async {
        guard lifecycle != .stopped else { return }
        lifecycle = .stopped
        ingress.close()
        let task = workerTask
        workerTask = nil
        task?.cancel()
        await task?.value
    }

    package func snapshot() -> Snapshot {
        ingress.snapshot()
    }

    package func cutoverEvidence(minimumCompletedCount: UInt64) -> CutoverEvidence {
        let snapshot = ingress.snapshot()
        let floorMet = minimumCompletedCount > 0
            && snapshot.completedCount >= minimumCompletedCount
        let ratio: Double? = if snapshot.totalSwiftLatencyNanoseconds > 0 {
            Double(snapshot.totalRustLatencyNanoseconds)
                / Double(snapshot.totalSwiftLatencyNanoseconds)
        } else {
            nil
        }
        return CutoverEvidence(
            minimumCompletedCount: minimumCompletedCount,
            completedCount: snapshot.completedCount,
            sampleFloorMet: floorMet,
            behavioralParityEstablished: floorMet
                && snapshot.mismatchedCount == 0
                && snapshot.failedCount == 0
                && snapshot.droppedCount == 0,
            rustToSwiftTotalLatencyRatio: ratio
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

    private func process(_ item: WorkItem) async {
        let rustStart = DispatchTime.now().uptimeNanoseconds
        do {
            let rustFingerprint: String
            let rustLatency: UInt64
            if let authoritativeRustFingerprint = item.authoritativeRustFingerprint,
               let authoritativeRustLatencyNanoseconds = item.authoritativeRustLatencyNanoseconds
            {
                rustFingerprint = authoritativeRustFingerprint
                rustLatency = authoritativeRustLatencyNanoseconds
            } else if item.authoritativeRustFingerprint == nil,
                      item.authoritativeRustLatencyNanoseconds == nil
            {
                rustFingerprint = try await projector(item.input, item.swiftFingerprint)
                rustLatency = DispatchTime.now().uptimeNanoseconds &- rustStart
            } else {
                throw DomainWorkspaceCommandIdentityObserverError.incompleteAuthoritativeResult
            }
            guard !Task.isCancelled else {
                ingress.abandonActive(item)
                return
            }
            commit(
                item,
                completion: Completion(
                    status: rustFingerprint == item.swiftFingerprint ? .matched : .mismatched,
                    swiftLatencyNanoseconds: item.swiftLatencyNanoseconds,
                    rustLatencyNanoseconds: rustLatency
                )
            )
        } catch {
            let rustLatency = DispatchTime.now().uptimeNanoseconds &- rustStart
            guard !Task.isCancelled else {
                ingress.abandonActive(item)
                return
            }
            commit(
                item,
                completion: Completion(
                    status: .failed,
                    swiftLatencyNanoseconds: item.swiftLatencyNanoseconds,
                    rustLatencyNanoseconds: rustLatency
                )
            )
        }
    }

    private func commit(_ item: WorkItem, completion: Completion) {
        guard ingress.complete(item, completion: completion) else { return }
        metrics.record(DomainRuntimeMetric(
            phase: .projection,
            name: "EditFlow.DomainRuntime.WorkspaceCommandIdentityComparison",
            dimensions: [
                "command": item.commandKind,
                "origin": item.origin,
                "result": resultName(completion.status),
                "input_size_bucket": inputSizeBucket(item.byteCount),
                "swift_latency_bucket": latencyBucket(completion.swiftLatencyNanoseconds),
                "rust_latency_bucket": latencyBucket(completion.rustLatencyNanoseconds)
            ]
        ))
    }

    private func recordQueuePressureIfNeeded() {
        guard let pressure = ingress.takeQueuePressure() else { return }
        metrics.record(DomainRuntimeMetric(
            phase: .projection,
            name: "EditFlow.DomainRuntime.WorkspaceCommandIdentityQueuePressure",
            dimensions: [
                "dropped_count": String(pressure.droppedCount),
                "dropped_input_size_bucket": inputSizeBucket(
                    Int(clamping: pressure.droppedInputBytes)
                )
            ]
        ))
    }

    private func resultName(_ status: CompletionStatus) -> String {
        switch status {
        case .matched: "matched"
        case .mismatched: "mismatched"
        case .failed: "error"
        }
    }

    private func inputSizeBucket(_ bytes: Int) -> String {
        switch bytes {
        case ..<1_024: "lt_1_kib"
        case ..<(64 * 1_024): "lt_64_kib"
        case ..<(1024 * 1_024): "lt_1_mib"
        case ..<(8 * 1024 * 1_024): "lt_8_mib"
        case ..<(32 * 1024 * 1_024): "lt_32_mib"
        default: "gte_32_mib"
        }
    }

    private func latencyBucket(_ nanoseconds: UInt64) -> String {
        switch nanoseconds {
        case ..<100_000: "lt_100_us"
        case ..<1_000_000: "lt_1_ms"
        case ..<10_000_000: "lt_10_ms"
        case ..<100_000_000: "lt_100_ms"
        case ..<1_000_000_000: "lt_1_s"
        default: "gte_1_s"
        }
    }
}
