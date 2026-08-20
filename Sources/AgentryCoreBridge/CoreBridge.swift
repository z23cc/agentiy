import AgentryUniFFIRaw
import Darwin
import Dispatch
import Foundation

struct CoreExpectedIdentity: Sendable {
    let abiEpoch: UInt32
    let buildFingerprint: String
    let bindingChecksum: String

    static let generated = CoreExpectedIdentity(
        abiEpoch: AgentryCoreBindingIdentity.abiEpoch,
        buildFingerprint: AgentryCoreBindingIdentity.buildFingerprint,
        bindingChecksum: AgentryCoreBindingIdentity.bindingChecksum
    )
}

struct CoreTransportHandshake: Sendable {
    let runtimeIdentity: CoreRuntimeIdentity
    let abiEpoch: UInt32
    let payloadSchemaVersions: [UInt16]
    let buildFingerprint: String
    let bindingChecksum: String
}

enum CoreTransportError: Error, Sendable {
    case invalidArgument
    case incompatibleAbi
    case staleRuntimeIdentity
    case runtimePoisoned
    case runtimeStopped
    case operationConflict
    case deadlineExpired
    case subscriptionNotFound
    case queueLimitExceeded
    case payloadTooLarge
    case shutdownTimedOut
    case internalPanic
    case unexpected(String)
}

protocol CoreRuntimeTransport: Sendable {
    func initialize() throws -> CoreTransportHandshake
    func execute(identity: CoreRuntimeIdentity, operationID: OperationID, command: CoreCommand) throws -> CoreAdmission
    func cancel(identity: CoreRuntimeIdentity, operationID: OperationID) throws -> CoreCancellation
    func openSubscription(identity: CoreRuntimeIdentity, scopeID: CoreScopeID) throws -> CoreTransportBootstrap
    func tryDrain(subscriptionID: UInt64, identity: CoreRuntimeIdentity) throws -> CoreTransportDrainBatch
    func duplicateWakeReadFD(identity: CoreRuntimeIdentity) throws -> Int32
    func rearmWake(identity: CoreRuntimeIdentity) throws -> Bool
    func closeSubscription(subscriptionID: UInt64, identity: CoreRuntimeIdentity) throws
    func respondHostRequest(_ response: CoreHostResponse) throws
    func beginShutdown(identity: CoreRuntimeIdentity) throws -> CoreShutdownReceipt
}

final class UniFFICoreRuntimeTransport: CoreRuntimeTransport, @unchecked Sendable {
    private let runtime: AgentryUniFFIRaw.CoreRuntime

    init(configuration: CoreConfiguration, expected: CoreExpectedIdentity) throws {
        do {
            runtime = try AgentryUniFFIRaw.CoreRuntime(config: .init(
                expectedAbiEpoch: expected.abiEpoch,
                expectedBuildFingerprint: expected.buildFingerprint,
                expectedBindingChecksum: expected.bindingChecksum,
                dataLaneCapacity: configuration.dataLaneCapacity,
                cancelTombstoneMillis: configuration.cancelTombstoneMilliseconds,
                shutdownGraceMillis: configuration.shutdownGraceMilliseconds
            ))
        } catch {
            throw Self.map(error)
        }
    }

    func initialize() throws -> CoreTransportHandshake {
        do {
            let value = try runtime.initialize()
            return CoreTransportHandshake(
                runtimeIdentity: Self.identity(value.runtimeIdentity),
                abiEpoch: value.abiEpoch,
                payloadSchemaVersions: value.payloadSchemaVersions,
                buildFingerprint: value.buildFingerprint,
                bindingChecksum: value.bindingChecksum
            )
        } catch {
            throw Self.map(error)
        }
    }

    func execute(identity: CoreRuntimeIdentity, operationID: OperationID, command: CoreCommand) throws -> CoreAdmission {
        do {
            let value = try runtime.execute(command: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                operationId: .init(value: operationID.rawValue),
                requestFingerprint: .init(value: command.requestFingerprint.rawValue),
                scopeId: .init(value: command.scopeID.rawValue),
                deadlineUnixMillis: command.deadlineUnixMilliseconds,
                payload: command.payload
            ))
            return CoreAdmission(
                runtimeIdentity: Self.identity(value.runtimeIdentity),
                operationID: try OperationID(rawValue: value.operationId.value),
                disposition: value.disposition == .accepted ? .accepted : .duplicate,
                state: Self.operationState(value.state)
            )
        } catch {
            throw Self.map(error)
        }
    }

    func cancel(identity: CoreRuntimeIdentity, operationID: OperationID) throws -> CoreCancellation {
        do {
            let value = try runtime.cancelOperation(
                identity: Self.rawIdentity(identity),
                operationId: .init(value: operationID.rawValue)
            )
            let disposition: CoreCancellationDisposition = switch value.disposition {
            case .requested: .requested
            case .tombstoned: .tombstoned
            case .alreadyRequested: .alreadyRequested
            case .alreadyTerminal: .alreadyTerminal
            }
            return CoreCancellation(
                operationID: try OperationID(rawValue: value.operationId.value),
                disposition: disposition
            )
        } catch {
            throw Self.map(error)
        }
    }

    func openSubscription(identity: CoreRuntimeIdentity, scopeID: CoreScopeID) throws -> CoreTransportBootstrap {
        do {
            let value = try runtime.openSubscription(scope: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: .init(value: scopeID.rawValue),
                maxQueuedEvents: 256,
                maxQueuedBytes: 1_048_576
            ))
            return CoreTransportBootstrap(
                subscriptionID: value.subscriptionId.value,
                runtimeIdentity: Self.identity(value.subscriptionId.runtimeIdentity),
                streamID: value.streamId,
                initialSnapshot: value.initialSnapshot,
                nextDeliveryCursor: value.nextDeliveryCursor
            )
        } catch {
            throw Self.map(error)
        }
    }

    func tryDrain(subscriptionID: UInt64, identity: CoreRuntimeIdentity) throws -> CoreTransportDrainBatch {
        do {
            let batch = try runtime.tryDrain(
                subscriptionId: .init(value: subscriptionID, runtimeIdentity: Self.rawIdentity(identity)),
                maxEvents: 64,
                maxBytes: 262_144
            )
            return CoreTransportDrainBatch(
                events: batch.events.map {
                    CoreTransportEvent(
                        kind: Self.eventKind($0.kind),
                        authoritySequence: $0.authoritySequence,
                        deliveryCursor: $0.deliveryCursor,
                        payload: $0.payload,
                        payloadOmitted: $0.payloadOmitted
                    )
                },
                hasMore: batch.hasMore,
                nextDeliveryCursor: batch.nextDeliveryCursor,
                droppedCount: batch.droppedCount,
                oversize: batch.oversize.map {
                    CoreTransportOversize(
                        actualBytes: $0.actualBytes,
                        maximumBytes: $0.maximumBytes,
                        resnapshotRequired: $0.resnapshotRequired
                    )
                }
            )
        } catch {
            throw Self.map(error)
        }
    }

    func duplicateWakeReadFD(identity: CoreRuntimeIdentity) throws -> Int32 {
        do {
            return try runtime.duplicateWakeReadFd(identity: Self.rawIdentity(identity))
        } catch {
            throw Self.map(error)
        }
    }

    func rearmWake(identity: CoreRuntimeIdentity) throws -> Bool {
        do {
            return try runtime.rearmWake(identity: Self.rawIdentity(identity))
        } catch {
            throw Self.map(error)
        }
    }

    func closeSubscription(subscriptionID: UInt64, identity: CoreRuntimeIdentity) throws {
        do {
            try runtime.closeSubscription(subscriptionId: .init(
                value: subscriptionID,
                runtimeIdentity: Self.rawIdentity(identity)
            ))
        } catch {
            throw Self.map(error)
        }
    }

    func respondHostRequest(_ response: CoreHostResponse) throws {
        do {
            try runtime.respondHostRequest(response: .init(
                runtimeIdentity: Self.rawIdentity(response.runtimeIdentity),
                requestId: response.requestID,
                payload: response.payload
            ))
        } catch {
            throw Self.map(error)
        }
    }

    func beginShutdown(identity: CoreRuntimeIdentity) throws -> CoreShutdownReceipt {
        do {
            let value = try runtime.beginShutdown(identity: Self.rawIdentity(identity))
            return CoreShutdownReceipt(
                alreadyStarted: value.alreadyStarted,
                cancelledOperations: value.cancelledOperations
            )
        } catch {
            throw Self.map(error)
        }
    }

    private static func identity(_ value: AgentryUniFFIRaw.RuntimeIdentity) -> CoreRuntimeIdentity {
        CoreRuntimeIdentity(
            abiEpoch: value.abiEpoch,
            instanceNonce: value.instanceNonce,
            buildFingerprint: value.buildFingerprint,
            bindingChecksum: value.bindingChecksum
        )
    }

    private static func rawIdentity(_ value: CoreRuntimeIdentity) -> AgentryUniFFIRaw.RuntimeIdentity {
        .init(
            abiEpoch: value.abiEpoch,
            instanceNonce: value.instanceNonce,
            buildFingerprint: value.buildFingerprint,
            bindingChecksum: value.bindingChecksum
        )
    }

    private static func operationState(_ value: AgentryUniFFIRaw.OperationState) -> CoreOperationState {
        switch value {
        case .admitted: .admitted
        case .running: .running
        case .cancelRequested: .cancelRequested
        case .succeeded: .succeeded
        case .cancelled: .cancelled
        case .deadlineExceeded: .deadlineExceeded
        case .failed: .failed
        }
    }

    private static func eventKind(_ value: AgentryUniFFIRaw.RuntimeEventKind) -> CoreEventKind {
        switch value {
        case .admitted: .admitted
        case .progress: .progress
        case .data: .data
        case .gap: .gap
        case .hostRequest: .hostRequest
        case .payloadRejected: .payloadRejected
        case .terminal: .terminal
        }
    }

    private static func map(_ error: Error) -> CoreTransportError {
        guard let error = error as? AgentryUniFFIRaw.CoreError else {
            return .unexpected(String(describing: error))
        }
        return switch error {
        case .InvalidArgument: .invalidArgument
        case .IncompatibleAbi: .incompatibleAbi
        case .StaleRuntimeIdentity: .staleRuntimeIdentity
        case .RuntimePoisoned: .runtimePoisoned
        case .RuntimeStopped: .runtimeStopped
        case .OperationConflict: .operationConflict
        case .DeadlineExpired: .deadlineExpired
        case .SubscriptionNotFound: .subscriptionNotFound
        case .QueueLimitExceeded: .queueLimitExceeded
        case .PayloadTooLarge: .payloadTooLarge
        case .ShutdownTimedOut: .shutdownTimedOut
        case .InternalPanic: .internalPanic
        }
    }
}

public actor AgentryCoreBridge {
    private enum Lifecycle {
        case created
        case running
        case invalidated
        case closed
    }

    private let transport: any CoreRuntimeTransport
    private let expectedIdentity: CoreExpectedIdentity
    private let decoder: any CoreEventDecoding
    private var identity: CoreRuntimeIdentity?
    private var lifecycle = Lifecycle.created
    private var wakeSource: DispatchSourceRead?
    private var subscriptions: [UInt64: CoreSubscriptionState] = [:]

    public static func start(
        configuration: CoreConfiguration = .init(),
        decoder: any CoreEventDecoding = DefaultCoreEventDecoder()
    ) async throws -> AgentryCoreBridge {
        let expected = CoreExpectedIdentity.generated
        let transport: UniFFICoreRuntimeTransport
        do {
            transport = try UniFFICoreRuntimeTransport(configuration: configuration, expected: expected)
        } catch let error as CoreTransportError {
            throw Self.publicError(error)
        } catch {
            throw CoreBridgeError.transportFailure(String(describing: error))
        }
        let bridge = AgentryCoreBridge(transport: transport, expectedIdentity: expected, decoder: decoder)
        try await bridge.initialize()
        return bridge
    }

    init(
        transport: any CoreRuntimeTransport,
        expectedIdentity: CoreExpectedIdentity = .generated,
        decoder: any CoreEventDecoding = DefaultCoreEventDecoder()
    ) {
        self.transport = transport
        self.expectedIdentity = expectedIdentity
        self.decoder = decoder
    }

    @discardableResult
    func initialize() throws -> CoreRuntimeIdentity {
        if lifecycle == .running, let identity {
            return identity
        }
        guard lifecycle == .created else {
            throw lifecycle == .invalidated ? CoreBridgeError.runtimeInvalidated : .alreadyClosed
        }
        do {
            let handshake = try transport.initialize()
            guard handshake.abiEpoch == expectedIdentity.abiEpoch,
                  handshake.buildFingerprint == expectedIdentity.buildFingerprint,
                  handshake.bindingChecksum == expectedIdentity.bindingChecksum,
                  handshake.runtimeIdentity.abiEpoch == expectedIdentity.abiEpoch,
                  handshake.runtimeIdentity.buildFingerprint == expectedIdentity.buildFingerprint,
                  handshake.runtimeIdentity.bindingChecksum == expectedIdentity.bindingChecksum
            else {
                invalidate()
                throw CoreBridgeError.incompatibleBindings
            }
            identity = handshake.runtimeIdentity
            lifecycle = .running
            try installWakeSource(identity: handshake.runtimeIdentity)
            return handshake.runtimeIdentity
        } catch let error as CoreBridgeError {
            throw error
        } catch {
            throw mapTransportError(error)
        }
    }

    public func runtimeIdentity() throws -> CoreRuntimeIdentity {
        try requireIdentity()
    }

    public nonisolated func execute(_ command: CoreCommand) async throws -> CoreAdmission {
        let operationID = OperationID()
        let cancellation = CoreCancellationIntent()
        return try await withTaskCancellationHandler {
            try await admit(command, operationID: operationID, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
            Task { [weak self] in
                await self?.forwardCancellation(operationID)
            }
        }
    }

    public func cancelOperation(_ operationID: OperationID) throws -> CoreCancellation {
        let identity = try requireIdentity()
        do {
            return try transport.cancel(identity: identity, operationID: operationID)
        } catch {
            throw mapTransportError(error)
        }
    }

    public func openSubscription(scopeID: CoreScopeID) async throws -> CoreSubscription {
        let identity = try requireIdentity()
        do {
            let bootstrap = try transport.openSubscription(identity: identity, scopeID: scopeID)
            try validate(bootstrap.runtimeIdentity)
            let initialSnapshot = try await decoder.decode(bootstrap.initialSnapshot)
            try validate(identity)
            let pair = AsyncThrowingStream<CoreEvent, Error>.makeStream(
                bufferingPolicy: .bufferingNewest(256)
            )
            subscriptions[bootstrap.subscriptionID] = CoreSubscriptionState(
                runtimeIdentity: identity,
                continuation: pair.continuation
            )
            return CoreSubscription(
                streamID: bootstrap.streamID,
                initialSnapshot: initialSnapshot,
                nextDeliveryCursor: bootstrap.nextDeliveryCursor,
                events: CoreEventStream(pair.stream),
                subscriptionID: bootstrap.subscriptionID,
                runtimeIdentity: identity
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    public func closeSubscription(_ subscription: CoreSubscription) throws {
        try validate(subscription.runtimeIdentity)
        guard let state = subscriptions.removeValue(forKey: subscription.subscriptionID) else {
            return
        }
        state.continuation.finish()
        do {
            try transport.closeSubscription(
                subscriptionID: subscription.subscriptionID,
                identity: subscription.runtimeIdentity
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    public func respondHostRequest(_ response: CoreHostResponse) throws {
        try validate(response.runtimeIdentity)
        do {
            try transport.respondHostRequest(response)
        } catch {
            throw mapTransportError(error)
        }
    }

    @discardableResult
    public func close() throws -> CoreShutdownReceipt {
        if lifecycle == .closed {
            return CoreShutdownReceipt(alreadyStarted: true, cancelledOperations: 0)
        }
        if lifecycle == .invalidated {
            finishResources(error: CoreBridgeError.runtimeInvalidated)
            lifecycle = .closed
            return CoreShutdownReceipt(alreadyStarted: true, cancelledOperations: 0)
        }
        let identity = try requireIdentity()
        for subscriptionID in subscriptions.keys {
            try? transport.closeSubscription(subscriptionID: subscriptionID, identity: identity)
        }
        finishResources(error: nil)
        do {
            let receipt = try transport.beginShutdown(identity: identity)
            self.identity = nil
            lifecycle = .closed
            return receipt
        } catch {
            throw mapTransportError(error)
        }
    }

    private func admit(
        _ command: CoreCommand,
        operationID: OperationID,
        cancellation: CoreCancellationIntent
    ) throws -> CoreAdmission {
        let identity = try requireIdentity()
        if cancellation.isCancelled || Task.isCancelled {
            _ = try? transport.cancel(identity: identity, operationID: operationID)
            throw CancellationError()
        }
        do {
            let receipt = try transport.execute(identity: identity, operationID: operationID, command: command)
            try validate(receipt.runtimeIdentity)
            if cancellation.isCancelled || Task.isCancelled {
                _ = try? transport.cancel(identity: identity, operationID: operationID)
                throw CancellationError()
            }
            return receipt
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapTransportError(error)
        }
    }

    private func forwardCancellation(_ operationID: OperationID) {
        guard let identity, lifecycle == .running else { return }
        do {
            _ = try transport.cancel(identity: identity, operationID: operationID)
        } catch {
            _ = mapTransportError(error)
        }
    }

    private func installWakeSource(identity: CoreRuntimeIdentity) throws {
        let descriptor: Int32
        do {
            descriptor = try transport.duplicateWakeReadFD(identity: identity)
        } catch {
            throw mapTransportError(error)
        }
        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
        else {
            Darwin.close(descriptor)
            throw CoreBridgeError.transportFailure("could not mark wake descriptor close-on-exec")
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "com.repoprompt.agentry-core.wake", qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            Self.consumeWakeBytes(descriptor)
            Task { [weak self] in
                await self?.wakeFired()
            }
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        wakeSource = source
        source.resume()
    }

    private nonisolated static func consumeWakeBytes(_ descriptor: Int32) {
        var bytes = [UInt8](repeating: 0, count: 128)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count <= 0 { return }
        }
    }

    private func wakeFired() async {
        guard let identity, lifecycle == .running else { return }
        do {
            repeat {
                try await drainAll(identity: identity)
            } while try transport.rearmWake(identity: identity)
            try await drainAll(identity: identity)
        } catch {
            let mapped = mapTransportError(error)
            if mapped == .runtimeInvalidated {
                invalidate()
            }
        }
    }

    private func drainAll(identity: CoreRuntimeIdentity) async throws {
        for subscriptionID in Array(subscriptions.keys) {
            try await drain(subscriptionID: subscriptionID, identity: identity)
        }
    }

    private func drain(subscriptionID: UInt64, identity: CoreRuntimeIdentity) async throws {
        var hasMore = true
        while hasMore {
            guard let state = subscriptions[subscriptionID] else { return }
            try validate(state.runtimeIdentity)
            let batch = try transport.tryDrain(subscriptionID: subscriptionID, identity: identity)
            for rawEvent in batch.events {
                let payload = try await decoder.decode(rawEvent.payload)
                try validate(identity)
                guard let current = subscriptions[subscriptionID], current.runtimeIdentity == identity else {
                    throw CoreBridgeError.staleRuntimeIdentity
                }
                current.continuation.yield(CoreEvent(
                    kind: rawEvent.kind,
                    authoritySequence: rawEvent.authoritySequence,
                    deliveryCursor: rawEvent.deliveryCursor,
                    payload: payload,
                    payloadOmitted: rawEvent.payloadOmitted
                ))
            }
            if batch.droppedCount > 0, !batch.events.contains(where: { $0.kind == .gap }) {
                state.continuation.yield(CoreEvent(
                    kind: .gap,
                    authoritySequence: 0,
                    deliveryCursor: batch.nextDeliveryCursor,
                    payload: .gap(droppedCount: batch.droppedCount),
                    payloadOmitted: false
                ))
            }
            if let oversize = batch.oversize {
                state.continuation.yield(CoreEvent(
                    kind: .payloadRejected,
                    authoritySequence: 0,
                    deliveryCursor: batch.nextDeliveryCursor,
                    payload: .rejected(
                        actualBytes: oversize.actualBytes,
                        maximumBytes: oversize.maximumBytes,
                        resnapshotRequired: oversize.resnapshotRequired
                    ),
                    payloadOmitted: true
                ))
            }
            hasMore = batch.hasMore
        }
    }

    private func requireIdentity() throws -> CoreRuntimeIdentity {
        switch lifecycle {
        case .running:
            guard let identity else { throw CoreBridgeError.notInitialized }
            return identity
        case .created:
            throw CoreBridgeError.notInitialized
        case .invalidated:
            throw CoreBridgeError.runtimeInvalidated
        case .closed:
            throw CoreBridgeError.alreadyClosed
        }
    }

    private func validate(_ candidate: CoreRuntimeIdentity) throws {
        guard let identity, lifecycle == .running else {
            throw lifecycle == .invalidated ? CoreBridgeError.runtimeInvalidated : .alreadyClosed
        }
        guard candidate == identity else {
            throw CoreBridgeError.staleRuntimeIdentity
        }
    }

    private func mapTransportError(_ error: Error) -> CoreBridgeError {
        if let error = error as? CoreBridgeError {
            return error
        }
        guard let error = error as? CoreTransportError else {
            return .transportFailure(String(describing: error))
        }
        switch error {
        case .internalPanic, .runtimePoisoned:
            invalidate()
        default:
            break
        }
        return Self.publicError(error)
    }

    private nonisolated static func publicError(_ error: CoreTransportError) -> CoreBridgeError {
        switch error {
        case .internalPanic, .runtimePoisoned: return .runtimeInvalidated
        case .invalidArgument: return .invalidArgument
        case .incompatibleAbi: return .incompatibleBindings
        case .staleRuntimeIdentity: return .staleRuntimeIdentity
        case .runtimeStopped: return .runtimeStopped
        case .operationConflict: return .operationConflict
        case .deadlineExpired: return .deadlineExpired
        case .subscriptionNotFound: return .subscriptionNotFound
        case .queueLimitExceeded: return .queueLimitExceeded
        case .payloadTooLarge: return .payloadTooLarge
        case .shutdownTimedOut: return .shutdownTimedOut
        case let .unexpected(message): return .transportFailure(message)
        }
    }

    private func invalidate() {
        guard lifecycle != .invalidated, lifecycle != .closed else { return }
        lifecycle = .invalidated
        identity = nil
        finishResources(error: CoreBridgeError.runtimeInvalidated)
    }

    private func finishResources(error: CoreBridgeError?) {
        wakeSource?.setEventHandler {}
        wakeSource?.cancel()
        wakeSource = nil
        for state in subscriptions.values {
            if let error {
                state.continuation.finish(throwing: error)
            } else {
                state.continuation.finish()
            }
        }
        subscriptions.removeAll()
    }
}
