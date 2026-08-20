import Darwin
import Foundation
import os
@testable import AgentryCoreBridge

final class FakeLeafCancellationHandle: CoreLeafCancellationHandle, Sendable {}

final class FakeCoreTransport: CoreRuntimeTransport, Sendable {
    struct State {
        var identity: CoreRuntimeIdentity
        var handshakeOverride: CoreTransportHandshake?
        var executeError: CoreTransportError?
        var searchError: CoreTransportError?
        var searchResult: CoreRegexSearchResult?
        var compactSearchResult: CoreCompactRegexBatchResult?
        var blocksSearch = false
        var actions: [String] = []
        var drains: [CoreTransportDrainBatch] = []
        var rearmResults: [Bool] = []
        var duplicatedWakeFD: Int32?
        var closeCount = 0
        var shutdownCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    let searchStarted = DispatchSemaphore(value: 0)
    let searchRelease = DispatchSemaphore(value: 0)
    private let readFD: Int32
    private let writeFD: Int32

    init(identity: CoreRuntimeIdentity = .fixture) {
        var descriptors: [Int32] = [0, 0]
        precondition(Darwin.pipe(&descriptors) == 0)
        readFD = descriptors[0]
        writeFD = descriptors[1]
        _ = Darwin.fcntl(readFD, F_SETFL, O_NONBLOCK)
        state = OSAllocatedUnfairLock(initialState: State(identity: identity))
    }

    deinit {
        Darwin.close(readFD)
        Darwin.close(writeFD)
    }

    func initialize() throws -> CoreTransportHandshake {
        state.withLock { value in
            value.actions.append("initialize")
            return value.handshakeOverride ?? CoreTransportHandshake(
                runtimeIdentity: value.identity,
                abiEpoch: value.identity.abiEpoch,
                payloadSchemaVersions: [1],
                buildFingerprint: value.identity.buildFingerprint,
                bindingChecksum: value.identity.bindingChecksum
            )
        }
    }

    func execute(identity: CoreRuntimeIdentity, operationID: OperationID, command: CoreCommand) throws -> CoreAdmission {
        try state.withLock { value in
            value.actions.append("execute:\(operationID.rawValue)")
            if let error = value.executeError { throw error }
            return CoreAdmission(
                runtimeIdentity: value.identity,
                operationID: operationID,
                disposition: .accepted,
                state: .admitted
            )
        }
    }

    func cancel(identity: CoreRuntimeIdentity, operationID: OperationID) throws -> CoreCancellation {
        state.withLock { value in
            value.actions.append("cancel:\(operationID.rawValue)")
        }
        return CoreCancellation(operationID: operationID, disposition: .tombstoned)
    }

    func openSubscription(identity: CoreRuntimeIdentity, scopeID: CoreScopeID) throws -> CoreTransportBootstrap {
        state.withLock { $0.actions.append("subscribe") }
        return CoreTransportBootstrap(
            subscriptionID: 7,
            runtimeIdentity: identity,
            streamID: 11,
            initialSnapshot: Data("snapshot".utf8),
            nextDeliveryCursor: 1
        )
    }

    func tryDrain(subscriptionID: UInt64, identity: CoreRuntimeIdentity) throws -> CoreTransportDrainBatch {
        state.withLock { value in
            value.actions.append("drain")
            if value.drains.isEmpty {
                return CoreTransportDrainBatch(
                    events: [],
                    hasMore: false,
                    nextDeliveryCursor: 1,
                    droppedCount: 0,
                    oversize: nil
                )
            }
            return value.drains.removeFirst()
        }
    }

    func duplicateWakeReadFD(identity: CoreRuntimeIdentity) throws -> Int32 {
        let descriptor = Darwin.dup(readFD)
        guard descriptor >= 0 else { throw CoreTransportError.unexpected("dup failed") }
        _ = Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK)
        state.withLock { $0.duplicatedWakeFD = descriptor }
        return descriptor
    }

    func rearmWake(identity: CoreRuntimeIdentity) throws -> Bool {
        state.withLock { value in
            value.actions.append("rearm")
            return value.rearmResults.isEmpty ? false : value.rearmResults.removeFirst()
        }
    }

    func closeSubscription(subscriptionID: UInt64, identity: CoreRuntimeIdentity) throws {
        state.withLock { value in
            value.closeCount += 1
            value.actions.append("close-subscription")
        }
    }

    func respondHostRequest(_ response: CoreHostResponse) throws {
        state.withLock { $0.actions.append("host-response") }
    }

    func createLeafCancellation(identity: CoreRuntimeIdentity) throws -> any CoreLeafCancellationHandle {
        state.withLock { $0.actions.append("create-leaf-cancellation") }
        return FakeLeafCancellationHandle()
    }

    func cancelLeafCancellation(
        _ cancellation: any CoreLeafCancellationHandle,
        identity: CoreRuntimeIdentity
    ) throws {
        state.withLock { $0.actions.append("cancel-leaf-cancellation") }
    }

    func closeLeafCancellation(
        _ cancellation: any CoreLeafCancellationHandle,
        identity: CoreRuntimeIdentity
    ) throws {
        state.withLock { $0.actions.append("close-leaf-cancellation") }
    }

    func searchRegex(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreRegexSearchRequest
    ) throws -> CoreRegexSearchResult {
        let outcome = state.withLock { value in
            value.actions.append("search-regex")
            return (value.blocksSearch, value.searchError, value.searchResult)
        }
        if outcome.0 {
            searchStarted.signal()
            searchRelease.wait()
        }
        if let error = outcome.1 { throw error }
        if let result = outcome.2 { return result }
        return CoreRegexSearchResult(
            hits: [],
            matchingLineCount: 0,
            cancelled: false,
            diagnostic: CoreRegexDiagnostic(
                engine: .pcre2,
                jitStatus: .active,
                cacheHit: false,
                repairKind: .none,
                limitPolicy: .fileSearchFullBuffer,
                subjectByteCount: UInt64(request.subject.utf8.count),
                lineCount: 0,
                hitCount: 0,
                matchingLineCount: 0,
                cancelled: false,
                limitFailure: nil
            )
        )
    }

    func searchRegexBatch(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreRegexSearchBatchRequest
    ) throws -> [CoreRegexSearchResult] {
        state.withLock { $0.actions.append("search-regex-batch") }
        return try request.subjects.map { subject in
            try searchRegex(
                identity: identity,
                cancellation: cancellation,
                request: CoreRegexSearchRequest(
                    mode: request.mode,
                    pattern: request.pattern,
                    subject: subject,
                    caseInsensitive: request.caseInsensitive,
                    wholeWord: request.wholeWord,
                    multilineAnchors: request.multilineAnchors,
                    collectMatches: request.collectMatches,
                    maxCollectedMatches: request.maxCollectedMatches,
                    contextLines: request.contextLines,
                    matchPolicy: request.matchPolicy
                )
            )
        }
    }

    func searchRegexBatchCompactV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreRegexSearchBatchRequest
    ) throws -> CoreCompactRegexBatchResult {
        try state.withLock { value in
            value.actions.append("search-regex-batch-compact-v1")
            if let error = value.searchError { throw error }
            if let result = value.compactSearchResult { return result }
            return CoreCompactRegexBatchResult(
                subjectSummaries: request.subjects.map { subject in
                    CoreCompactRegexSubjectSummary(
                        lineRangeStart: 0,
                        lineRangeCount: 0,
                        hitStart: 0,
                        hitCount: 0,
                        matchingLineCount: 0,
                        cancelled: false,
                        diagnostic: CoreRegexDiagnostic(
                            engine: .pcre2,
                            jitStatus: .active,
                            cacheHit: false,
                            repairKind: .none,
                            limitPolicy: .fileSearchFullBuffer,
                            subjectByteCount: UInt64(subject.utf8.count),
                            lineCount: 0,
                            hitCount: 0,
                            matchingLineCount: 0,
                            cancelled: false,
                            limitFailure: nil
                        )
                    )
                },
                lineRangeWords: [],
                hitWords: []
            )
        }
    }

    func filterPaths(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CorePathFilterRequest
    ) throws -> CorePathFilterResult {
        state.withLock { $0.actions.append("filter-paths") }
        return CorePathFilterResult(
            matchedSnapshotIndices: [],
            visitedSnapshotCount: UInt64(request.snapshots.count),
            cancelled: false,
            diagnostic: .init(
                visitedSnapshotCount: UInt64(request.snapshots.count),
                matchedSnapshotCount: 0,
                cancelled: false
            )
        )
    }

    func folderSuffixIndices(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreFolderSuffixRequest
    ) throws -> [UInt32] {
        state.withLock { $0.actions.append("folder-suffix") }
        return []
    }

    func beginShutdown(identity: CoreRuntimeIdentity) throws -> CoreShutdownReceipt {
        state.withLock { value in
            value.shutdownCount += 1
            value.actions.append("shutdown")
        }
        return CoreShutdownReceipt(alreadyStarted: false, cancelledOperations: 0)
    }

    func overrideHandshake(_ handshake: CoreTransportHandshake) {
        state.withLock { $0.handshakeOverride = handshake }
    }

    func failExecute(with error: CoreTransportError) {
        state.withLock { $0.executeError = error }
    }

    func failSearch(with error: CoreTransportError) {
        state.withLock { $0.searchError = error }
    }

    func returnSearchResult(_ result: CoreRegexSearchResult) {
        state.withLock { $0.searchResult = result }
    }

    func returnCompactSearchResult(_ result: CoreCompactRegexBatchResult) {
        state.withLock { $0.compactSearchResult = result }
    }

    func blockSearch() {
        state.withLock { $0.blocksSearch = true }
    }

    func enqueue(_ batches: [CoreTransportDrainBatch], rearm: [Bool] = []) {
        state.withLock { value in
            value.drains.append(contentsOf: batches)
            value.rearmResults.append(contentsOf: rearm)
        }
    }

    func wake() {
        var byte: UInt8 = 1
        _ = withUnsafePointer(to: &byte) { Darwin.write(writeFD, $0, 1) }
    }

    var actions: [String] { state.withLock { $0.actions } }
    var duplicatedWakeFDFlags: Int32 {
        state.withLock { value in
            guard let descriptor = value.duplicatedWakeFD else { return -1 }
            return Darwin.fcntl(descriptor, F_GETFD)
        }
    }
    var closeCount: Int { state.withLock { $0.closeCount } }
    var shutdownCount: Int { state.withLock { $0.shutdownCount } }
}

extension CoreRuntimeIdentity {
    static let fixture = CoreRuntimeIdentity(
        abiEpoch: CoreExpectedIdentity.generated.abiEpoch,
        instanceNonce: "0123456789abcdef0123456789abcdef",
        buildFingerprint: CoreExpectedIdentity.generated.buildFingerprint,
        bindingChecksum: CoreExpectedIdentity.generated.bindingChecksum
    )
}

func fixtureCommand() throws -> CoreCommand {
    CoreCommand(
        scopeID: CoreScopeID(),
        requestFingerprint: try CoreRequestFingerprint(String(repeating: "a", count: 64)),
        payload: Data("command".utf8)
    )
}
