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

enum CoreTransportError: Error, Sendable, Equatable {
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
    case patternTooComplex
    case invalidEscape
    case unmatchedBrackets
    case unmatchedParentheses
    case invalidQuantifier
    case variableLengthLookbehind
    case invalidPattern
    case matchLimitExceeded
    case depthLimitExceeded
    case heapLimitExceeded
    case jitUnavailable
    case searchCancelled
    case searchInvariant
    case codeMapInvalidRequest
    case codeMapServiceUnavailable
    case codeMapCancelled
    case codeMapInvariant
    case applyEditsInvalidParams(String)
    case applyEditsCancelled
    case applyEditsInvariant
    case applyEditsLossyDecodeBlocksWriteBack(String)
    case inventoryInvalidRequest(String)
    case inventoryCancelled
    case inventoryInvariant
    case pathMatchInvalidRequest(String)
    case pathMatchCancelled
    case pathResolveInvalidRequest(String)
    case pathResolveCancelled
    case pathSearchInvalidRequest(String)
    case pathSearchCancelled
    case tokenAccountingInvalidRequest(String)
    case tokenAccountingCancelled
    case inventoryScopeUnknownScope
    case inventoryScopeUnknownRoot
    case inventoryScopeLifetimeMismatch
    case inventoryScopeNoPublishedGeneration
    case inventoryScopeBulkLoadUnknown
    case inventoryScopeBulkLoadAlreadyTerminal
    case inventoryScopeBulkLoadRootMismatch
    case inventoryHandleInvalidated(CoreInventoryHandleInvalidationReason)
    case inventoryScopeInvalidRequest(String)
    case unexpected(String)
}

/// Mirrors `AgentryUniFFIRaw.InventoryHandleInvalidationReasonV1` (contract doc §4 layer 3).
public enum CoreInventoryHandleInvalidationReason: Sendable, Equatable {
    case rootClosed
    case scopeClosed
    case identityChanged
}

protocol CoreRuntimeTransport: Sendable {
    func initialize() throws -> CoreTransportHandshake
    func execute(identity: CoreRuntimeIdentity, operationID: OperationID, command: CoreCommand) throws -> CoreAdmission
    func cancel(identity: CoreRuntimeIdentity, operationID: OperationID) throws -> CoreCancellation
    func openSubscription(
        identity: CoreRuntimeIdentity, scopeID: CoreScopeID, maxQueuedEvents: UInt64, maxQueuedBytes: UInt64
    ) throws -> CoreTransportBootstrap
    func tryDrain(subscriptionID: UInt64, identity: CoreRuntimeIdentity) throws -> CoreTransportDrainBatch
    func duplicateWakeReadFD(identity: CoreRuntimeIdentity) throws -> Int32
    func rearmWake(identity: CoreRuntimeIdentity) throws -> Bool
    func closeSubscription(subscriptionID: UInt64, identity: CoreRuntimeIdentity) throws
    func respondHostRequest(_ response: CoreHostResponse) throws
    func createLeafCancellation(identity: CoreRuntimeIdentity) throws -> any CoreLeafCancellationHandle
    func cancelLeafCancellation(_ cancellation: any CoreLeafCancellationHandle, identity: CoreRuntimeIdentity) throws
    func closeLeafCancellation(_ cancellation: any CoreLeafCancellationHandle, identity: CoreRuntimeIdentity) throws
    func searchRegex(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreRegexSearchRequest
    ) throws -> CoreRegexSearchResult
    func searchRegexBatch(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreRegexSearchBatchRequest
    ) throws -> [CoreRegexSearchResult]
    func searchRegexBatchCompactV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreRegexSearchBatchRequest
    ) throws -> CoreCompactRegexBatchResult
    func codeMapExtractBatchCompactV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCodeMapBatchRequestV1
    ) throws -> CoreCompactCodeMapBatchResultV1
    func applyEditsBatchCompactV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreApplyEditsBatchRequestV1
    ) throws -> CoreCompactApplyEditsBatchResultV1
    func inventoryComputeV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactInventoryRequestV1
    ) throws -> CoreCompactInventoryResultV1
    func pathMatchScoreBatchV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactPathMatchRequestV1
    ) throws -> CoreCompactPathMatchResultV1
    func pathMatchLocateManyBatchV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactPathMatchResolveRequestV1
    ) throws -> CoreCompactPathMatchResolveResultV1
    func pathSearchFindV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactPathSearchFindRequestV1
    ) throws -> CoreCompactPathSearchFindResultV1
    func tokenAccountingV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactTokenAccountingRequestV1
    ) throws -> CoreCompactTokenAccountingResultV1
    func filterPaths(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CorePathFilterRequest
    ) throws -> CorePathFilterResult
    func folderSuffixIndices(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreFolderSuffixRequest
    ) throws -> [UInt32]
    func beginShutdown(identity: CoreRuntimeIdentity) throws -> CoreShutdownReceipt

    // ---- P4-4: inventory-scope-v1 (docs/architecture/rust-inventory-scope-v1.md §5) ----------
    //
    // Deliberate, flagged deviation from this protocol's usual full-insulation convention: these
    // methods pass the raw `AgentryUniFFIRaw` request/response records straight through (beyond
    // translating `identity` and mapping errors) rather than defining a parallel Swift-only
    // mirror struct for every one of them. Every field on these records is already a plain
    // Sendable value type (`String`/`Data`/`UInt64`/enum) -- no Rust-object handle crosses this
    // boundary -- so the insulation a full mirror would buy is smaller here than for the
    // one-shot compute requests above, and P4-4's remaining scope (Swift mirror wire codec,
    // fingerprint test, bridge tests) is large enough that this is the pragmatic cut.
    func inventoryOpenScope(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreInventoryScopeConfigV1
    ) throws -> AgentryUniFFIRaw.InventoryScopeHandleV1
    func inventoryCloseScope(identity: CoreRuntimeIdentity, scopeID: String) throws
    func inventoryOpenRoot(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        name: String,
        standardizedFullPath: String
    ) throws -> AgentryUniFFIRaw.InventoryRootLifetimeV1
    func inventoryCloseRoot(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        rootLifetimeID: String
    ) throws -> AgentryUniFFIRaw.InventoryRootUnloadReceiptV1
    func inventoryScopeDiagnostics(
        identity: CoreRuntimeIdentity,
        scopeID: String
    ) throws -> AgentryUniFFIRaw.InventoryDiagnosticsV1
    func inventoryBeginBulkLoad(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        rootLifetimeID: String
    ) throws -> UInt64
    func inventoryPushBulkChunk(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        bulkLoadID: UInt64,
        rootID: Data,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.BulkChunkReceiptV1
    /// §4.1.1 discovery mint site: `bytes` is the compact **discovery** bulk-chunk blob
    /// (id-less records); the receipt carries the Rust-minted ids in input order.
    func inventoryPushBulkChunkDiscovery(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        bulkLoadID: UInt64,
        rootID: Data,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.BulkChunkDiscoveryReceiptV1
    func inventoryCommitBulkLoad(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        bulkLoadID: UInt64
    ) throws -> AgentryUniFFIRaw.InventoryGenerationReceiptV1
    func inventoryAbortBulkLoad(identity: CoreRuntimeIdentity, scopeID: String, bulkLoadID: UInt64) throws
    func inventoryApplyDeltaV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        rootLifetimeID: String,
        watcherAcceptedWatermark: UInt64?,
        requiresFullResync: Bool,
        expectedAppliedIndexGeneration: UInt64?,
        source: String,
        eventBytes: Data
    ) throws -> AgentryUniFFIRaw.InventoryDeltaReceiptV1
    /// §4.1.1 discovery mint site: `eventBytes` is the compact **discovery** delta blob
    /// (id-less upserts); the receipt carries the Rust-minted ids in
    /// `upserted_files`/`upserted_folders` order.
    func inventoryApplyDeltaDiscoveryV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        rootLifetimeID: String,
        watcherAcceptedWatermark: UInt64?,
        requiresFullResync: Bool,
        expectedAppliedIndexGeneration: UInt64?,
        source: String,
        eventBytes: Data
    ) throws -> AgentryUniFFIRaw.InventoryDeltaDiscoveryReceiptV1
    func inventoryOpenSnapshot(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data
    ) throws -> AgentryUniFFIRaw.InventorySnapshotHandleV1
    func inventorySnapshotPage(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        handleID: UInt64,
        offset: UInt64,
        limit: UInt64
    ) throws -> AgentryUniFFIRaw.CompactInventoryPageV1
    func inventoryCloseSnapshot(scopeID: String, handleID: UInt64) throws
    /// P4-5: the handle-based read-plane query used by the shadow arm's index comparison arm
    /// (design doc §8.2) -- Swift-only facade completion over the already-landed FFI export
    /// (`rust/crates/ffi/src/api.rs::inventory_query`), matching `inventoryOpenScope`'s pattern.
    func inventoryQuery(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        handleID: UInt64,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactQueryResultV1
    /// P4-6b prep slice 1: `inventoryResolveRecords`'s facade completion (contract doc §5.3) --
    /// same "already-landed FFI export, missing Swift facade" pattern as `inventoryQuery` above.
    func inventoryResolveRecords(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        expectedCatalogGeneration: UInt64?,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactRecordBlockV1
    /// P4-6b prep slice 1: `inventoryLookupPaths`'s facade completion.
    func inventoryLookupPaths(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        handleID: UInt64,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactLookupResultV1
    /// P4-6b prep slice 1: `inventoryOpenProjectedShard`'s facade completion (contract doc §6, B2).
    func inventoryOpenProjectedShard(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data
    ) throws -> AgentryUniFFIRaw.InventorySnapshotHandleV1

    /// Forensic strings for the most recent panic(s) recorded by the Rust
    /// process-wide panic hook, most-recent last -- not scoped to this
    /// transport's runtime instance, and not limited to panics that a
    /// `PanicGuard` happened to contain. Deliberately infallible and callable
    /// after the runtime is poisoned/invalidated -- see
    /// `AgentryUniFFIRaw.CoreRuntime.panicForensics()`.
    func panicForensics() -> [String]
}

final class UniFFILeafCancellationHandle: CoreLeafCancellationHandle, @unchecked Sendable {
    let raw: AgentryUniFFIRaw.LeafCancellation

    init(raw: AgentryUniFFIRaw.LeafCancellation) {
        self.raw = raw
    }
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

    func openSubscription(
        identity: CoreRuntimeIdentity, scopeID: CoreScopeID, maxQueuedEvents: UInt64, maxQueuedBytes: UInt64
    ) throws -> CoreTransportBootstrap {
        do {
            let value = try runtime.openSubscription(scope: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: .init(value: scopeID.rawValue),
                maxQueuedEvents: maxQueuedEvents,
                maxQueuedBytes: maxQueuedBytes
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

    func createLeafCancellation(identity: CoreRuntimeIdentity) throws -> any CoreLeafCancellationHandle {
        do {
            return try UniFFILeafCancellationHandle(
                raw: runtime.createLeafCancellation(identity: Self.rawIdentity(identity))
            )
        } catch {
            throw Self.map(error)
        }
    }

    func cancelLeafCancellation(
        _ cancellation: any CoreLeafCancellationHandle,
        identity: CoreRuntimeIdentity
    ) throws {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        do {
            try cancellation.raw.cancel(identity: Self.rawIdentity(identity))
        } catch {
            throw Self.map(error)
        }
    }

    func closeLeafCancellation(
        _ cancellation: any CoreLeafCancellationHandle,
        identity: CoreRuntimeIdentity
    ) throws {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        do {
            try cancellation.raw.close(identity: Self.rawIdentity(identity))
        } catch {
            throw Self.map(error)
        }
    }

    func searchRegex(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreRegexSearchRequest
    ) throws -> CoreRegexSearchResult {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        do {
            let value = try runtime.searchRegex(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                mode: request.mode == .content ? .content : .path,
                pattern: request.pattern,
                subject: request.subject,
                caseInsensitive: request.caseInsensitive,
                wholeWord: request.wholeWord,
                multilineAnchors: request.multilineAnchors,
                collectMatches: request.collectMatches,
                maxCollectedMatches: request.maxCollectedMatches,
                contextLines: request.contextLines,
                matchPolicy: Self.rawMatchPolicy(request.matchPolicy)
            ))
            return CoreRegexSearchResult(
                hits: value.hits.map(Self.regexHit),
                matchingLineCount: value.matchingLineCount,
                cancelled: value.cancelled,
                diagnostic: Self.regexDiagnostic(value.diagnostic)
            )
        } catch {
            throw Self.map(error)
        }
    }

    func searchRegexBatch(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreRegexSearchBatchRequest
    ) throws -> [CoreRegexSearchResult] {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        do {
            return try runtime.searchRegexBatch(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                mode: request.mode == .content ? .content : .path,
                pattern: request.pattern,
                subjects: request.subjects,
                caseInsensitive: request.caseInsensitive,
                wholeWord: request.wholeWord,
                multilineAnchors: request.multilineAnchors,
                collectMatches: request.collectMatches,
                maxCollectedMatches: request.maxCollectedMatches,
                contextLines: request.contextLines,
                matchPolicy: Self.rawMatchPolicy(request.matchPolicy)
            )).map {
                CoreRegexSearchResult(
                    hits: $0.hits.map(Self.regexHit),
                    matchingLineCount: $0.matchingLineCount,
                    cancelled: $0.cancelled,
                    diagnostic: Self.regexDiagnostic($0.diagnostic)
                )
            }
        } catch {
            throw Self.map(error)
        }
    }

    func searchRegexBatchCompactV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreRegexSearchBatchRequest
    ) throws -> CoreCompactRegexBatchResult {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        do {
            let value = try runtime.searchRegexBatchCompactV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                mode: request.mode == .content ? .content : .path,
                pattern: request.pattern,
                subjects: request.subjects,
                caseInsensitive: request.caseInsensitive,
                wholeWord: request.wholeWord,
                multilineAnchors: request.multilineAnchors,
                collectMatches: request.collectMatches,
                maxCollectedMatches: request.maxCollectedMatches,
                contextLines: request.contextLines,
                matchPolicy: Self.rawMatchPolicy(request.matchPolicy)
            ))
            return CoreCompactRegexBatchResult(
                subjectSummaries: value.subjectSummaries.map(Self.compactRegexSummary),
                lineRangeWords: value.lineRangeWords,
                hitWords: value.hitWords
            )
        } catch {
            throw Self.map(error)
        }
    }

    func codeMapExtractBatchCompactV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCodeMapBatchRequestV1
    ) throws -> CoreCompactCodeMapBatchResultV1 {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        let value: AgentryUniFFIRaw.CoreCompactCodeMapBatchResultV1
        do {
            value = try runtime.codeMapExtractBatchCompactV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                contractVersion: request.contractVersion,
                    subjects: request.subjects.map { subject in
                        let sourceKind: AgentryUniFFIRaw.CoreCodeMapSourceKindV1 = switch subject.sourceKind {
                        case .decoded: .decoded
                        case .decodeFailedUndecodable: .decodeFailedUndecodable
                        case .raw: .raw
                        }
                        return .init(
                            languageId: subject.languageID,
                            sourceKind: sourceKind,
                            sourceUtf8: subject.sourceUTF8
                        )
                    }
            ))
        } catch {
            throw Self.map(error)
        }
        let summaries = try value.subjectSummaries.map { summary in
            guard let rawTag = UInt8(exactly: summary.outcomeTag),
                  let outcomeTag = CoreCompactCodeMapOutcomeTag(rawValue: rawTag)
            else { throw CoreComputeError.malformedResponse }
            return CoreCompactCodeMapSubjectSummaryV1(
                languageID: summary.languageId,
                sourceByteCount: summary.sourceByteCount,
                outcomeTag: outcomeTag,
                outcomeActual: summary.outcomeActual,
                outcomeLimit: summary.outcomeLimit,
                blob: Self.compactRange(summary.blob),
                strings: Self.compactRange(summary.strings),
                stringIndices: Self.compactRange(summary.stringIndices),
                classPool: Self.compactRange(summary.classPool),
                interfacePool: Self.compactRange(summary.interfacePool),
                aliasPool: Self.compactRange(summary.aliasPool),
                functionPool: Self.compactRange(summary.functionPool),
                parameterPool: Self.compactRange(summary.parameterPool),
                propertyPool: Self.compactRange(summary.propertyPool),
                enumPool: Self.compactRange(summary.enumPool),
                variablePool: Self.compactRange(summary.variablePool),
                imports: Self.compactRange(summary.imports),
                exports: Self.compactRange(summary.exports),
                classes: Self.compactRange(summary.classes),
                interfaces: Self.compactRange(summary.interfaces),
                aliases: Self.compactRange(summary.aliases),
                literalUnions: Self.compactRange(summary.literalUnions),
                functions: Self.compactRange(summary.functions),
                enums: Self.compactRange(summary.enums),
                globalVariables: Self.compactRange(summary.globalVars),
                macros: Self.compactRange(summary.macros),
                referencedTypes: Self.compactRange(summary.referencedTypes)
            )
        }
        return .init(
            subjectSummaries: summaries,
            utf8Blob: value.utf8Blob,
            stringRangeWords: value.stringRangeWords,
            stringIndexWords: value.stringIndexWords,
            classWords: value.classWords,
            interfaceWords: value.interfaceWords,
            aliasWords: value.aliasWords,
            functionWords: value.functionWords,
            parameterWords: value.parameterWords,
            propertyWords: value.propertyWords,
            enumWords: value.enumWords,
            variableWords: value.variableWords
        )
    }

    func applyEditsBatchCompactV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreApplyEditsBatchRequestV1
    ) throws -> CoreCompactApplyEditsBatchResultV1 {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        let subjects: [AgentryUniFFIRaw.CoreApplyEditsSubjectRequestV1] = request.subjects.map { subject in
            let modeTag: UInt64
            let rewriteReplacement: String?
            let operations: [CoreApplyEditsOperationV1]
            switch subject.mode {
            case let .rewrite(replacement):
                modeTag = 0
                rewriteReplacement = replacement
                operations = []
            case let .single(operation):
                modeTag = 1
                rewriteReplacement = nil
                operations = [operation]
            case let .batch(batch):
                modeTag = 2
                rewriteReplacement = nil
                operations = batch
            }
            return .init(
                pathLabel: subject.pathLabel,
                originalUtf8: subject.originalUTF8,
                sourceKind: subject.sourceKind == .raw ? .raw : .decodedUtf8,
                modeTag: modeTag,
                rewriteReplacement: rewriteReplacement,
                operations: operations.map {
                    .init(search: $0.search, replace: $0.replacement, replaceAll: $0.replaceAll)
                },
                verbose: subject.verbose,
                includeToolCardUnifiedDiff: subject.includeToolCardUnifiedDiff
            )
        }
        let value: AgentryUniFFIRaw.CoreCompactApplyEditsBatchResultV1
        do {
            value = try runtime.applyEditsBatchCompactV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                contractVersion: request.contractVersion,
                subjects: subjects
            ))
        } catch {
            throw Self.map(error)
        }
        return .init(
            subjectSummaries: value.subjectSummaries.map {
                .init(
                    inputByteCount: $0.inputByteCount,
                    blobStart: $0.blobStart,
                    blobCount: $0.blobCount,
                    stringStart: $0.stringStart,
                    stringCount: $0.stringCount,
                    updatedTextStringIndex: $0.updatedTextStringIndex,
                    byteEditStart: $0.byteEditStart,
                    byteEditCount: $0.byteEditCount,
                    chunkStart: $0.chunkStart,
                    chunkCount: $0.chunkCount,
                    diffLineStart: $0.diffLineStart,
                    diffLineCount: $0.diffLineCount,
                    outcomeStart: $0.outcomeStart,
                    outcomeCount: $0.outcomeCount,
                    editsRequested: $0.editsRequested,
                    editsApplied: $0.editsApplied,
                    resultStatusTag: $0.resultStatusTag,
                    outcomesPresent: $0.outcomesPresent,
                    statsPresent: $0.statsPresent,
                    linesChanged: $0.linesChanged,
                    statsChunkCount: $0.statsChunkCount,
                    noteStringIndex: $0.noteStringIndex,
                    unifiedDiffStringIndex: $0.unifiedDiffStringIndex,
                    toolCardDiffStringIndex: $0.toolCardDiffStringIndex,
                    originalTextStringIndex: $0.originalTextStringIndex
                )
            },
            utf8Blob: value.utf8Blob,
            stringRangeWords: value.stringRangeWords,
            byteEditWords: value.byteEditWords,
            chunkWords: value.chunkWords,
            diffLineWords: value.diffLineWords,
            outcomeWords: value.outcomeWords
        )
    }

    func inventoryComputeV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactInventoryRequestV1
    ) throws -> CoreCompactInventoryResultV1 {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        let value: AgentryUniFFIRaw.CoreInventoryComputeResultV1
        do {
            value = try runtime.inventoryComputeV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                contractVersion: request.contractVersion,
                operation: request.operation,
                utf8Blob: request.utf8Blob,
                stringRangeWords: request.stringRangeWords,
                stringIndexWords: request.stringIndexWords,
                uuidWords: request.uuidWords,
                rootWords: request.rootWords,
                fileWords: request.fileWords,
                folderWords: request.folderWords,
                entryWords: request.entryWords,
                shardWords: request.shardWords,
                roots: Self.rawInventoryRange(request.roots),
                filesById: Self.rawInventoryRange(request.filesByID),
                foldersById: Self.rawInventoryRange(request.foldersByID),
                managedOnlyFileIds: Self.rawInventoryRange(request.managedOnlyFileIDs),
                managedOnlyFolderIds: Self.rawInventoryRange(request.managedOnlyFolderIDs),
                previousFiles: Self.rawInventoryRange(request.previousFiles),
                previousFolders: Self.rawInventoryRange(request.previousFolders),
                eventRootIdHi: request.eventRootIDHi,
                eventRootIdLo: request.eventRootIDLo,
                eventUpsertedFiles: Self.rawInventoryRange(request.eventUpsertedFiles),
                eventUpsertedFolders: Self.rawInventoryRange(request.eventUpsertedFolders),
                eventRemovedFileIds: Self.rawInventoryRange(request.eventRemovedFileIDs),
                eventRemovedFolderIds: Self.rawInventoryRange(request.eventRemovedFolderIDs),
                eventRemovedFilePaths: Self.rawInventoryRange(request.eventRemovedFilePaths),
                eventRemovedFolderPaths: Self.rawInventoryRange(request.eventRemovedFolderPaths),
                eventModifiedFileIds: Self.rawInventoryRange(request.eventModifiedFileIDs),
                eventModifiedFolderIds: Self.rawInventoryRange(request.eventModifiedFolderIDs),
                maxLogicalMutationCount: request.maxLogicalMutationCount,
                shards: Self.rawInventoryRange(request.shards)
            ))
        } catch {
            throw Self.map(error)
        }
        return CoreCompactInventoryResultV1(
            operation: value.operation,
            utf8Blob: value.utf8Blob,
            stringRangeWords: value.stringRangeWords,
            uuidWords: value.uuidWords,
            fileWords: value.fileWords,
            folderWords: value.folderWords,
            entryWords: value.entryWords,
            componentsFiles: Self.inventoryRange(value.componentsFiles),
            componentsFolders: Self.inventoryRange(value.componentsFolders),
            componentsEntries: Self.inventoryRange(value.componentsEntries),
            shardPatchOutcome: value.shardPatchOutcome,
            shardPatchFiles: Self.inventoryRange(value.shardPatchFiles),
            shardPatchFolders: Self.inventoryRange(value.shardPatchFolders),
            shardPatchLogicalMutationCount: value.shardPatchLogicalMutationCount,
            shardPatchChangedFileIDs: Self.inventoryRange(value.shardPatchChangedFileIds),
            mergedFiles: Self.inventoryRange(value.mergedFiles),
            mergedEntries: Self.inventoryRange(value.mergedEntries)
        )
    }

    func pathMatchScoreBatchV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactPathMatchRequestV1
    ) throws -> CoreCompactPathMatchResultV1 {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        let value: AgentryUniFFIRaw.CorePathMatchScoreResultV1
        do {
            value = try runtime.pathMatchScoreV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                contractVersion: request.contractVersion,
                threshold: request.threshold,
                utf8Blob: request.utf8Blob,
                stringRangeWords: request.stringRangeWords,
                charCountWords: request.charCountWords,
                cleanedByteLenWords: request.cleanedByteLenWords,
                queryIndices: request.queryIndices,
                candidateWords: request.candidateWords,
                candidateTailIndices: request.candidateTailIndices,
                selectedRootOrdinals: request.selectedRootOrdinals
            ))
        } catch {
            throw Self.map(error)
        }
        return CoreCompactPathMatchResultV1(
            matchedOrdinals: value.matchedOrdinals,
            matchedScoresScaled: value.matchedScoresScaled,
            matchedScoresBits: value.matchedScoresBits
        )
    }

    func pathMatchLocateManyBatchV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactPathMatchResolveRequestV1
    ) throws -> CoreCompactPathMatchResolveResultV1 {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        let value: AgentryUniFFIRaw.CorePathMatchResolveResultV1
        do {
            value = try runtime.pathMatchLocateManyV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                contractVersion: request.contractVersion,
                caseSensitive: request.caseSensitive,
                exactMatchOnly: request.exactMatchOnly,
                allowLeadingRootAliasTrim: request.allowLeadingRootAliasTrim,
                allowHeadTrimAliases: request.allowHeadTrimAliases,
                allowAbsoluteSuffixFallback: request.allowAbsoluteSuffixFallback,
                utf8Blob: request.utf8Blob,
                stringRangeWords: request.stringRangeWords,
                charCountWords: request.charCountWords,
                cleanedByteLenWords: request.cleanedByteLenWords,
                rootWords: request.rootWords,
                fileWords: request.fileWords,
                folderWords: request.folderWords,
                componentIndices: request.componentIndices,
                selectedFileFullPathIndices: request.selectedFileFullPathIndices,
                queryWords: request.queryWords,
                queryCanonicalComponentIndices: request.queryCanonicalComponentIndices,
                queryCleanedLowerComponentIndices: request.queryCleanedLowerComponentIndices
            ))
        } catch {
            throw Self.map(error)
        }
        return CoreCompactPathMatchResolveResultV1(
            locations: value.locations.map { location in
                location.map { CorePathMatchResolveLocationV1(rootOrdinal: $0.rootOrdinal, correctedPath: $0.correctedPath) }
            }
        )
    }

    func pathSearchFindV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactPathSearchFindRequestV1
    ) throws -> CoreCompactPathSearchFindResultV1 {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        let value: AgentryUniFFIRaw.CorePathSearchFindResultV1
        do {
            value = try runtime.pathSearchFindV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                contractVersion: request.contractVersion,
                utf8Blob: request.utf8Blob,
                stringRangeWords: request.stringRangeWords,
                corpusPathIndices: request.corpusPathIndices,
                queryWords: request.queryWords
            ))
        } catch {
            throw Self.map(error)
        }
        return CoreCompactPathSearchFindResultV1(
            resultOrdinals: value.resultOrdinals,
            resultRangeWords: value.resultRangeWords,
            statsWords: value.statsWords
        )
    }

    func tokenAccountingV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactTokenAccountingRequestV1
    ) throws -> CoreCompactTokenAccountingResultV1 {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        let value: AgentryUniFFIRaw.CoreTokenAccountingResultV1
        do {
            value = try runtime.tokenAccountingV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                contractVersion: request.contractVersion,
                utf8Blob: request.utf8Blob,
                stringRangeWords: request.stringRangeWords,
                entryWords: request.entryWords,
                componentWords: request.componentWords
            ))
        } catch {
            throw Self.map(error)
        }
        return CoreCompactTokenAccountingResultV1(
            entryResultWords: value.entryResultWords,
            entryFormatted: value.entryFormatted,
            entryPercentage: value.entryPercentage,
            aggregateWords: value.aggregateWords,
            combinedDisplayTokens: value.combinedDisplayTokens,
            totalDisplayTokens: value.totalDisplayTokens,
            codeMapContent: value.codeMapContent,
            codeMapFileCount: value.codeMapFileCount,
            codeMapTokenCount: value.codeMapTokenCount,
            folderNames: value.folderNames,
            folderTokenCounts: value.folderTokenCounts,
            folderFormatted: value.folderFormatted,
            folderPercentage: value.folderPercentage,
            componentResultWords: value.componentResultWords
        )
    }

    func filterPaths(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CorePathFilterRequest
    ) throws -> CorePathFilterResult {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        do {
            let value = try runtime.filterPaths(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                snapshots: request.snapshots.map {
                    .init(
                        standardizedFullPath: $0.standardizedFullPath,
                        standardizedRelativePath: $0.standardizedRelativePath,
                        standardizedRootPath: $0.standardizedRootPath,
                        clientDisplayPath: $0.clientDisplayPath
                    )
                },
                clauses: request.clauses.map(Self.rawPathClause),
                caseInsensitive: request.caseInsensitive
            ))
            return CorePathFilterResult(
                matchedSnapshotIndices: value.matchedSnapshotIndices,
                visitedSnapshotCount: value.visitedSnapshotCount,
                cancelled: value.cancelled,
                diagnostic: .init(
                    visitedSnapshotCount: value.diagnostic.visitedSnapshotCount,
                    matchedSnapshotCount: value.diagnostic.matchedSnapshotCount,
                    cancelled: value.diagnostic.cancelled
                )
            )
        } catch {
            throw Self.map(error)
        }
    }

    func folderSuffixIndices(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreFolderSuffixRequest
    ) throws -> [UInt32] {
        guard let cancellation = cancellation as? UniFFILeafCancellationHandle else {
            throw CoreTransportError.invalidArgument
        }
        do {
            return try runtime.folderSuffixIndices(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                cancellation: cancellation.raw,
                fragment: request.fragment,
                relativePaths: request.relativePaths,
                caseInsensitive: request.caseInsensitive
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

    /// Infallible on the Rust side (see `CoreRuntime::panic_forensics`), so
    /// there is nothing to catch/map here.
    func panicForensics() -> [String] {
        runtime.panicForensics()
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

    private static func rawMatchPolicy(_ value: CoreMatchPolicy) -> AgentryUniFFIRaw.MatchPolicy {
        switch value {
        case .contentFullBuffer: .contentFullBuffer
        case .contentLine: .contentLine
        case .shortPath: .shortPath
        }
    }

    private static func rawPathClause(_ value: CorePathClause) -> AgentryUniFFIRaw.PathClause {
        switch value {
        case let .exactFile(absPath, relPath, restrictedRootPath):
            .exactFile(absPath: absPath, relPath: relPath, restrictedRootPath: restrictedRootPath)
        case let .exactFolder(absLower, relLower, restrictedRootPath):
            .exactFolder(absLower: absLower, relLower: relLower, restrictedRootPath: restrictedRootPath)
        case let .glob(pattern, restrictedRootPath):
            .glob(pattern: pattern, restrictedRootPath: restrictedRootPath)
        case let .legacyPrefix(candidateLower):
            .legacyPrefix(candidateLower: candidateLower)
        }
    }

    private static func byteRange(_ value: AgentryUniFFIRaw.ByteRange) -> CoreByteRange {
        .init(start: value.start, end: value.end)
    }

    private static func compactRange(
        _ value: AgentryUniFFIRaw.CoreCompactTableRangeV1
    ) -> CoreCompactTableRange {
        .init(start: value.start, count: value.count)
    }

    private static func inventoryRange(
        _ value: AgentryUniFFIRaw.CoreInventoryTableRangeV1
    ) -> CoreCompactTableRange {
        .init(start: value.start, count: value.count)
    }

    private static func rawInventoryRange(
        _ value: CoreCompactTableRange
    ) -> AgentryUniFFIRaw.CoreInventoryTableRangeV1 {
        .init(start: value.start, count: value.count)
    }

    private static func regexHit(_ value: AgentryUniFFIRaw.RegexLineHit) -> CoreRegexLineHit {
        .init(
            lineNumber: value.lineNumber,
            lineByteRange: byteRange(value.lineByteRange),
            matchByteRange: byteRange(value.matchByteRange),
            contextBeforeByteRanges: value.contextBeforeByteRanges.map(byteRange),
            contextAfterByteRanges: value.contextAfterByteRanges.map(byteRange)
        )
    }

    private static func compactRegexSummary(
        _ value: AgentryUniFFIRaw.CompactRegexSubjectSummary
    ) -> CoreCompactRegexSubjectSummary {
        .init(
            lineRangeStart: value.lineRangeStart,
            lineRangeCount: value.lineRangeCount,
            hitStart: value.hitStart,
            hitCount: value.hitCount,
            matchingLineCount: value.matchingLineCount,
            cancelled: value.cancelled,
            diagnostic: regexDiagnostic(.init(
                engine: value.engine,
                jitStatus: value.jitStatus,
                cacheHit: value.cacheHit,
                repairKind: value.repairKind,
                limitPolicy: value.limitPolicy,
                subjectByteCount: value.subjectByteCount,
                lineCount: value.lineCount,
                hitCount: value.diagnosticHitCount,
                matchingLineCount: value.diagnosticMatchingLineCount,
                cancelled: value.diagnosticCancelled,
                limitFailure: value.limitFailure
            ))
        )
    }

    private static func regexDiagnostic(_ value: AgentryUniFFIRaw.RegexDiagnostic) -> CoreRegexDiagnostic {
        let engine: CoreSearchEngine = switch value.engine {
        case .asciiWholeWord: .asciiWholeWord
        case .anchoredDeclaration: .anchoredDeclaration
        case .asciiMarker: .asciiMarker
        case .pathSuffix: .pathSuffix
        case .anchoredLinePrefilter: .anchoredLinePrefilter
        case .pcre2: .pcre2
        }
        let jitStatus: CoreJITStatus = switch value.jitStatus {
        case .notApplicable: .notApplicable
        case .active: .active
        case .pcre2InterpreterFallback: .pcre2InterpreterFallback
        }
        let repairKind: CoreRepairKind = switch value.repairKind {
        case .none: .none
        case .doubleEscapeCompression: .doubleEscapeCompression
        case .normalise: .normalise
        case .normaliseThenCompression: .normaliseThenCompression
        }
        let limitPolicy: CoreLimitPolicy = switch value.limitPolicy {
        case .fileSearchFullBuffer: .fileSearchFullBuffer
        case .fileSearchLine: .fileSearchLine
        case .pathSearchShortSubject: .pathSearchShortSubject
        }
        let limitFailure: CoreLimitFailure? = value.limitFailure.map {
            switch $0 {
            case .match: .match
            case .depth: .depth
            case .heap: .heap
            }
        }
        return .init(
            engine: engine,
            jitStatus: jitStatus,
            cacheHit: value.cacheHit,
            repairKind: repairKind,
            limitPolicy: limitPolicy,
            subjectByteCount: value.subjectByteCount,
            lineCount: value.lineCount,
            hitCount: value.hitCount,
            matchingLineCount: value.matchingLineCount,
            cancelled: value.cancelled,
            limitFailure: limitFailure
        )
    }

    // ---- P4-4: inventory-scope-v1 -------------------------------------------------------------

    func inventoryOpenScope(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreInventoryScopeConfigV1
    ) throws -> AgentryUniFFIRaw.InventoryScopeHandleV1 {
        do {
            return try runtime.inventoryOpenScope(identity: Self.rawIdentity(identity), config: config)
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryCloseScope(identity: CoreRuntimeIdentity, scopeID: String) throws {
        do {
            try runtime.inventoryCloseScope(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryOpenRoot(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        name: String,
        standardizedFullPath: String
    ) throws -> AgentryUniFFIRaw.InventoryRootLifetimeV1 {
        do {
            return try runtime.inventoryOpenRoot(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: scopeID,
                rootId: rootID,
                name: name,
                standardizedFullPath: standardizedFullPath
            ))
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryCloseRoot(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        rootLifetimeID: String
    ) throws -> AgentryUniFFIRaw.InventoryRootUnloadReceiptV1 {
        do {
            return try runtime.inventoryCloseRoot(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                rootId: rootID,
                rootLifetimeId: rootLifetimeID
            )
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryScopeDiagnostics(
        identity: CoreRuntimeIdentity,
        scopeID: String
    ) throws -> AgentryUniFFIRaw.InventoryDiagnosticsV1 {
        do {
            return try runtime.inventoryScopeDiagnostics(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryBeginBulkLoad(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        rootLifetimeID: String
    ) throws -> UInt64 {
        do {
            return try runtime.inventoryBeginBulkLoad(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                rootId: rootID,
                rootLifetimeId: rootLifetimeID
            )
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryPushBulkChunk(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        bulkLoadID: UInt64,
        rootID: Data,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.BulkChunkReceiptV1 {
        do {
            return try runtime.inventoryPushBulkChunk(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                bulkLoadId: bulkLoadID,
                rootId: rootID,
                bytes: bytes
            )
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryPushBulkChunkDiscovery(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        bulkLoadID: UInt64,
        rootID: Data,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.BulkChunkDiscoveryReceiptV1 {
        do {
            return try runtime.inventoryPushBulkChunkDiscovery(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                bulkLoadId: bulkLoadID,
                rootId: rootID,
                bytes: bytes
            )
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryCommitBulkLoad(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        bulkLoadID: UInt64
    ) throws -> AgentryUniFFIRaw.InventoryGenerationReceiptV1 {
        do {
            return try runtime.inventoryCommitBulkLoad(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                bulkLoadId: bulkLoadID,
                publishMode: .atomicPublish
            )
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryAbortBulkLoad(identity: CoreRuntimeIdentity, scopeID: String, bulkLoadID: UInt64) throws {
        do {
            try runtime.inventoryAbortBulkLoad(identity: Self.rawIdentity(identity), scopeId: scopeID, bulkLoadId: bulkLoadID)
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryApplyDeltaV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        rootLifetimeID: String,
        watcherAcceptedWatermark: UInt64?,
        requiresFullResync: Bool,
        expectedAppliedIndexGeneration: UInt64?,
        source: String,
        eventBytes: Data
    ) throws -> AgentryUniFFIRaw.InventoryDeltaReceiptV1 {
        do {
            return try runtime.inventoryApplyDeltaV1(command: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: scopeID,
                rootId: rootID,
                rootLifetimeId: rootLifetimeID,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                requiresFullResync: requiresFullResync,
                expectedAppliedIndexGeneration: expectedAppliedIndexGeneration,
                source: source,
                eventBytes: eventBytes
            ))
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryApplyDeltaDiscoveryV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        rootLifetimeID: String,
        watcherAcceptedWatermark: UInt64?,
        requiresFullResync: Bool,
        expectedAppliedIndexGeneration: UInt64?,
        source: String,
        eventBytes: Data
    ) throws -> AgentryUniFFIRaw.InventoryDeltaDiscoveryReceiptV1 {
        do {
            return try runtime.inventoryApplyDeltaDiscoveryV1(command: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: scopeID,
                rootId: rootID,
                rootLifetimeId: rootLifetimeID,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                requiresFullResync: requiresFullResync,
                expectedAppliedIndexGeneration: expectedAppliedIndexGeneration,
                source: source,
                eventBytes: eventBytes
            ))
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryOpenSnapshot(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data
    ) throws -> AgentryUniFFIRaw.InventorySnapshotHandleV1 {
        do {
            return try runtime.inventoryOpenSnapshot(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: scopeID,
                rootId: rootID
            ))
        } catch {
            throw Self.map(error)
        }
    }

    func inventorySnapshotPage(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        handleID: UInt64,
        offset: UInt64,
        limit: UInt64
    ) throws -> AgentryUniFFIRaw.CompactInventoryPageV1 {
        do {
            return try runtime.inventorySnapshotPage(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                handleId: handleID,
                offset: offset,
                limit: limit
            )
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryCloseSnapshot(scopeID: String, handleID: UInt64) throws {
        do {
            try runtime.inventoryCloseSnapshot(scopeId: scopeID, handleId: handleID)
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryQuery(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        handleID: UInt64,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactQueryResultV1 {
        do {
            return try runtime.inventoryQuery(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: scopeID,
                handleId: handleID,
                bytes: bytes
            ))
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryResolveRecords(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        expectedCatalogGeneration: UInt64?,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactRecordBlockV1 {
        do {
            return try runtime.inventoryResolveRecords(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: scopeID,
                rootId: rootID,
                expectedCatalogGeneration: expectedCatalogGeneration,
                bytes: bytes
            ))
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryLookupPaths(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        handleID: UInt64,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactLookupResultV1 {
        do {
            return try runtime.inventoryLookupPaths(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                handleId: handleID,
                bytes: bytes
            )
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryOpenProjectedShard(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data
    ) throws -> AgentryUniFFIRaw.InventorySnapshotHandleV1 {
        do {
            return try runtime.inventoryOpenProjectedShard(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: scopeID,
                rootId: rootID
            ))
        } catch {
            throw Self.map(error)
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
        case .PatternTooComplex: .patternTooComplex
        case .InvalidEscape: .invalidEscape
        case let .InventoryInvalidRequest(message): .inventoryInvalidRequest(message)
        case .InventoryCancelled: .inventoryCancelled
        case .InventoryInvariant: .inventoryInvariant
        case let .PathMatchInvalidRequest(message): .pathMatchInvalidRequest(message)
        case .PathMatchCancelled: .pathMatchCancelled
        case let .PathResolveInvalidRequest(message): .pathResolveInvalidRequest(message)
        case .PathResolveCancelled: .pathResolveCancelled
        case let .PathSearchInvalidRequest(message): .pathSearchInvalidRequest(message)
        case .PathSearchCancelled: .pathSearchCancelled
        case let .TokenAccountingInvalidRequest(message): .tokenAccountingInvalidRequest(message)
        case .TokenAccountingCancelled: .tokenAccountingCancelled
        case .UnmatchedBrackets: .unmatchedBrackets
        case .UnmatchedParentheses: .unmatchedParentheses
        case .InvalidQuantifier: .invalidQuantifier
        case .VariableLengthLookbehind: .variableLengthLookbehind
        case .InvalidPattern: .invalidPattern
        case .MatchLimitExceeded: .matchLimitExceeded
        case .DepthLimitExceeded: .depthLimitExceeded
        case .HeapLimitExceeded: .heapLimitExceeded
        case .JitUnavailable: .jitUnavailable
        case .SearchCancelled: .searchCancelled
        case .SearchInvariant: .searchInvariant
        case .CodeMapInvalidRequest: .codeMapInvalidRequest
        case .CodeMapServiceUnavailable: .codeMapServiceUnavailable
        case .CodeMapCancelled: .codeMapCancelled
        case .CodeMapInvariant: .codeMapInvariant
        case let .ApplyEditsInvalidParams(message): .applyEditsInvalidParams(message)
        case .ApplyEditsCancelled: .applyEditsCancelled
        case .ApplyEditsInvariant: .applyEditsInvariant
        case let .ApplyEditsLossyDecodeBlocksWriteBack(message): .applyEditsLossyDecodeBlocksWriteBack(message)
        case .InventoryScopeUnknownScope: .inventoryScopeUnknownScope
        case .InventoryScopeUnknownRoot: .inventoryScopeUnknownRoot
        case .InventoryScopeLifetimeMismatch: .inventoryScopeLifetimeMismatch
        case .InventoryScopeNoPublishedGeneration: .inventoryScopeNoPublishedGeneration
        case .InventoryScopeBulkLoadUnknown: .inventoryScopeBulkLoadUnknown
        case .InventoryScopeBulkLoadAlreadyTerminal: .inventoryScopeBulkLoadAlreadyTerminal
        case .InventoryScopeBulkLoadRootMismatch: .inventoryScopeBulkLoadRootMismatch
        case let .InventoryHandleInvalidated(reason): .inventoryHandleInvalidated(Self.handleInvalidationReason(reason))
        case let .InventoryScopeInvalidRequest(message): .inventoryScopeInvalidRequest(message)
        }
    }

    private static func handleInvalidationReason(
        _ reason: AgentryUniFFIRaw.InventoryHandleInvalidationReasonV1
    ) -> CoreInventoryHandleInvalidationReason {
        switch reason {
        case .rootClosed: .rootClosed
        case .scopeClosed: .scopeClosed
        case .identityChanged: .identityChanged
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

    let transport: any CoreRuntimeTransport
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

    /// Process-wide Rust panic forensics, callable with no live bridge/
    /// transport instance at all. `AgentryCoreBridge.start()` itself can
    /// throw before any `AgentryCoreBridge` exists to read
    /// `panicForensicsSuffix` from -- e.g. `UniFFICoreRuntimeTransport.init`
    /// panics inside the Rust `CoreRuntime` constructor, before that
    /// constructor has returned an object. This is the recovery path for
    /// exactly that case: call it after a failed `start()` to learn why.
    public static func corePanicForensics() -> [String] {
        AgentryUniFFIRaw.corePanicForensics()
    }

    /// Process-wide WARN/ERROR diagnostics drain, callable with no live
    /// bridge/transport instance -- same shape as `corePanicForensics()`
    /// above, backing `agentry_runtime::observability` (rewrite charter
    /// §11.7's tracing/os_log bridge). Destructive: each call removes the
    /// drained events, so callers should own their own drain cadence (e.g.
    /// a periodic app-observability tick) rather than calling this
    /// speculatively from multiple places.
    public static func coreDiagnosticsDrain() -> [String] {
        AgentryUniFFIRaw.coreDiagnosticsDrain()
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
                noteInvalidationTrigger("handshake identity mismatch (incompatibleBindings)")
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

    /// `maxQueuedEvents`/`maxQueuedBytes` default to this bridge's long-standing hardcoded queue
    /// shape (256 events / 1 MiB) so every existing call site is unaffected; a caller that needs a
    /// deliberately tighter queue (e.g. deterministically forcing overflow in a test, or a
    /// consumer that wants aggressive backpressure) can override either.
    public func openSubscription(
        scopeID: CoreScopeID,
        maxQueuedEvents: UInt64 = 256,
        maxQueuedBytes: UInt64 = 1_048_576
    ) async throws -> CoreSubscription {
        let identity = try requireIdentity()
        do {
            let bootstrap = try transport.openSubscription(
                identity: identity, scopeID: scopeID, maxQueuedEvents: maxQueuedEvents, maxQueuedBytes: maxQueuedBytes
            )
            try validate(bootstrap.runtimeIdentity)
            let pair = AsyncThrowingStream<CoreEvent, Error>.makeStream(
                bufferingPolicy: .bufferingNewest(256)
            )
            // Register before the decode await below: `transport.openSubscription`
            // already made this subscription live on the Rust side (eligible for
            // publish()/wake), so `subscriptions` must know about it before any
            // suspension point, or a concurrent wakeFired() drain pass can silently
            // skip its queue and starve rearm_and_recheck forever.
            subscriptions[bootstrap.subscriptionID] = CoreSubscriptionState(
                runtimeIdentity: identity,
                continuation: pair.continuation
            )
            let initialSnapshot: CoreDecodedPayload
            do {
                initialSnapshot = try await decoder.decode(bootstrap.initialSnapshot)
                try validate(identity)
            } catch {
                subscriptions.removeValue(forKey: bootstrap.subscriptionID)
                pair.continuation.finish(throwing: error)
                try? transport.closeSubscription(subscriptionID: bootstrap.subscriptionID, identity: identity)
                throw error
            }
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

    public func searchClient() throws -> CoreSearchClient {
        _ = try requireIdentity()
        return CoreSearchClient(bridge: self)
    }

    public func computeClient() throws -> CoreComputeClient {
        _ = try requireIdentity()
        return CoreComputeClient(bridge: self)
    }

    func prepareComputeOperation() throws -> CoreComputeOperationContext {
        do {
            let identity = try requireIdentity()
            return try CoreComputeOperationContext(
                transport: transport,
                identity: identity,
                cancellation: transport.createLeafCancellation(identity: identity)
            )
        } catch {
            throw mapComputeFailure(error)
        }
    }

    func validateComputeCompletion(identity: CoreRuntimeIdentity) throws {
        do {
            try validate(identity)
        } catch {
            throw mapComputeFailure(error)
        }
    }

    func mapComputeFailure(_ error: Error) -> any Error {
        if let error = error as? CoreComputeError {
            if error == .malformedResponse {
                // Per-request contract violation (e.g. a wire bug for one payload
                // shape): fail this request loudly but do NOT stickily invalidate
                // the process-wide runtime — that converts one bad response into
                // a cascade failure for every later caller in the process.
                noteInvalidationTrigger("compute malformedResponse (request-scoped, runtime kept)")
            }
            return error
        }
        if error is CancellationError {
            return CancellationError()
        }
        if let error = error as? CoreBridgeError {
            let mapped: CoreComputeError = switch error {
            case .runtimeInvalidated, .staleRuntimeIdentity, .incompatibleBindings: .runtimeInvalidated
            case .runtimeStopped, .alreadyClosed: .runtimeStopped
            case .invalidArgument: .invalidRequest("invalid argument")
            default: .transportFailure(error.localizedDescription)
            }
            if mapped == .runtimeInvalidated || mapped == .runtimeStopped {
                noteInvalidationTrigger("compute mapped failure: \(String(describing: error))")
                invalidate()
            }
            return mapped
        }
        guard let error = error as? CoreTransportError else {
            return CoreComputeError.transportFailure(String(describing: error))
        }
        if error == .codeMapCancelled || error == .applyEditsCancelled || error == .inventoryCancelled
            || error == .pathMatchCancelled || error == .pathResolveCancelled || error == .pathSearchCancelled
            || error == .tokenAccountingCancelled
        {
            return CancellationError()
        }
        let mapped: CoreComputeError = switch error {
        case .invalidArgument, .codeMapInvalidRequest:
            .invalidRequest("invalid compute request")
        case let .applyEditsInvalidParams(message):
            .invalidRequest(message)
        case let .inventoryInvalidRequest(message):
            .invalidRequest(message)
        case let .pathMatchInvalidRequest(message):
            .invalidRequest(message)
        case let .pathResolveInvalidRequest(message):
            .invalidRequest(message)
        case let .pathSearchInvalidRequest(message):
            .invalidRequest(message)
        case let .tokenAccountingInvalidRequest(message):
            .invalidRequest(message)
        case .runtimePoisoned: .runtimePoisoned
        case .runtimeStopped: .runtimeStopped
        case .staleRuntimeIdentity, .incompatibleAbi, .internalPanic: .runtimeInvalidated
        case .codeMapServiceUnavailable: .transportFailure("codemap service unavailable")
        case .codeMapInvariant: .transportFailure("codemap invariant failure")
        case .applyEditsInvariant: .transportFailure("apply-edits invariant failure")
        case .inventoryInvariant: .transportFailure("inventory invariant failure")
        case let .unexpected(message): .transportFailure(message)
        default: .transportFailure(String(describing: error))
        }
        switch mapped {
        case .runtimeInvalidated, .runtimeStopped, .runtimePoisoned:
            let panicForensics = panicForensicsRecords(for: error)
            noteInvalidationTrigger(
                "compute transport error: \(String(describing: error))\(panicForensicsSuffix(panicForensics))"
            )
            invalidate(panicForensics: panicForensics)
        default:
            break
        }
        return mapped
    }

    func prepareSearchOperation() throws -> CoreSearchOperationContext {
        do {
            let identity = try requireIdentity()
            return CoreSearchOperationContext(
                transport: transport,
                identity: identity,
                cancellation: try transport.createLeafCancellation(identity: identity)
            )
        } catch {
            throw mapSearchFailure(error)
        }
    }

    func validateSearchCompletion(identity: CoreRuntimeIdentity) throws {
        do {
            try validate(identity)
        } catch {
            throw mapSearchFailure(error)
        }
    }

    func mapSearchFailure(_ error: Error) -> CoreSearchError {
        if let error = error as? CoreSearchError {
            if error == .malformedRange {
                // Request-scoped decode violation: see the compute malformedResponse
                // note — do not poison the shared runtime for one bad response.
                noteInvalidationTrigger("search malformedRange (request-scoped, runtime kept)")
            }
            return error
        }
        if error is CancellationError {
            return .cancelled
        }
        if let error = error as? CoreBridgeError {
            let mapped: CoreSearchError = switch error {
            case .runtimeInvalidated: .runtimeInvalidated
            case .runtimeStopped, .alreadyClosed: .runtimeStopped
            case .staleRuntimeIdentity: .runtimeInvalidated
            case .incompatibleBindings: .runtimeInvalidated
            default: .transportFailure(error.localizedDescription)
            }
            if mapped == .runtimeInvalidated || mapped == .runtimeStopped {
                noteInvalidationTrigger("search mapped failure: \(String(describing: error))")
                invalidate()
            }
            return mapped
        }
        guard let error = error as? CoreTransportError else {
            return .transportFailure(String(describing: error))
        }
        let mapped: CoreSearchError = switch error {
        case .patternTooComplex: .patternTooComplex
        case .invalidEscape: .invalidPattern(.invalidEscape)
        case .unmatchedBrackets: .invalidPattern(.unmatchedBrackets)
        case .unmatchedParentheses: .invalidPattern(.unmatchedParentheses)
        case .invalidQuantifier: .invalidPattern(.invalidQuantifier)
        case .variableLengthLookbehind: .invalidPattern(.variableLengthLookbehind)
        case .invalidPattern, .invalidArgument: .invalidPattern(.other)
        case .matchLimitExceeded: .matchLimitExceeded
        case .depthLimitExceeded: .depthLimitExceeded
        case .heapLimitExceeded: .heapLimitExceeded
        case .jitUnavailable: .jitUnavailable
        case .searchCancelled: .cancelled
        case .searchInvariant: .malformedRange
        case .runtimePoisoned: .runtimePoisoned
        case .runtimeStopped: .runtimeStopped
        case .staleRuntimeIdentity, .incompatibleAbi, .internalPanic: .runtimeInvalidated
        case let .unexpected(message): .transportFailure(message)
        default: .transportFailure(String(describing: error))
        }
        switch mapped {
        case .runtimeInvalidated, .runtimeStopped, .runtimePoisoned:
            let panicForensics = panicForensicsRecords(for: error)
            noteInvalidationTrigger(
                "search transport error: \(String(describing: error))\(panicForensicsSuffix(panicForensics))"
            )
            invalidate(panicForensics: panicForensics)
        default:
            break
        }
        return mapped
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
                // Guaranteed suspension per pass: if a registration-order bug ever
                // reappears, the loop degrades to a yielding poll instead of a
                // non-yielding actor monopoly that starves the registration path.
                await Task.yield()
            } while try transport.rearmWake(identity: identity)
            try await drainAll(identity: identity)
        } catch {
            let mapped = mapTransportError(error)
            if mapped == .runtimeInvalidated {
                noteInvalidationTrigger("wakeFired transport error: \(String(describing: error))")
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

    func requireIdentity() throws -> CoreRuntimeIdentity {
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

    func mapTransportError(_ error: Error) -> CoreBridgeError {
        if let error = error as? CoreBridgeError {
            return error
        }
        guard let error = error as? CoreTransportError else {
            return .transportFailure(String(describing: error))
        }
        switch error {
        case .internalPanic, .runtimePoisoned:
            let panicForensics = panicForensicsRecords(for: error)
            noteInvalidationTrigger(
                "bridge transport error: \(String(describing: error))\(panicForensicsSuffix(panicForensics))"
            )
            invalidate(panicForensics: panicForensics)
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
        case .patternTooComplex, .invalidEscape, .unmatchedBrackets, .unmatchedParentheses,
             .invalidQuantifier, .variableLengthLookbehind, .invalidPattern, .matchLimitExceeded,
             .depthLimitExceeded, .heapLimitExceeded, .jitUnavailable, .searchCancelled,
             .searchInvariant, .codeMapInvalidRequest, .codeMapServiceUnavailable, .codeMapCancelled,
             .codeMapInvariant, .applyEditsInvalidParams, .applyEditsCancelled, .applyEditsInvariant,
             .applyEditsLossyDecodeBlocksWriteBack,
             .inventoryInvalidRequest, .inventoryCancelled, .inventoryInvariant,
             .pathMatchInvalidRequest, .pathMatchCancelled,
             .pathResolveInvalidRequest, .pathResolveCancelled,
             .pathSearchInvalidRequest, .pathSearchCancelled,
             .tokenAccountingInvalidRequest, .tokenAccountingCancelled:
            return .invalidArgument
        case .inventoryScopeUnknownScope: return .inventoryScopeUnknownScope
        case .inventoryScopeUnknownRoot: return .inventoryScopeUnknownRoot
        case .inventoryScopeLifetimeMismatch: return .inventoryScopeLifetimeMismatch
        case .inventoryScopeNoPublishedGeneration: return .inventoryScopeNoPublishedGeneration
        case .inventoryScopeBulkLoadUnknown: return .inventoryScopeBulkLoadUnknown
        case .inventoryScopeBulkLoadAlreadyTerminal: return .inventoryScopeBulkLoadAlreadyTerminal
        case .inventoryScopeBulkLoadRootMismatch: return .inventoryScopeBulkLoadRootMismatch
        case let .inventoryHandleInvalidated(reason): return .inventoryHandleInvalidated(reason)
        case let .inventoryScopeInvalidRequest(message): return .inventoryScopeInvalidRequest(message)
        case let .unexpected(message): return .transportFailure(message)
        }
    }

    private var firstInvalidationTrigger: String?

    #if DEBUG
    /// Test-only window onto the recorded trigger; `firstInvalidationTrigger`
    /// itself stays `private` for everyone else.
    var invalidationTriggerForTesting: String? { firstInvalidationTrigger }
    #endif

    /// Debug forensics for the full-suite mid-run invalidation investigation:
    /// records the first raw trigger so the suite log names the poisoner.
    private func noteInvalidationTrigger(_ description: String) {
        guard firstInvalidationTrigger == nil else { return }
        firstInvalidationTrigger = description
    }

    /// Rust panic ring-buffer records relevant to `error`, or empty when
    /// `error` is not the panic-driven poisoning case -- `internalPanic`
    /// (first call after the unwind) or `runtimePoisoned` (every call after
    /// that). Any other transport error is unrelated to a panic, so forensics
    /// would be noise there. Fetches through `transport.panicForensics()`
    /// directly, not through any guarded path, since it must keep working
    /// exactly when the runtime it is explaining has just been poisoned.
    private func panicForensicsRecords(for error: CoreTransportError) -> [String] {
        guard error == .internalPanic || error == .runtimePoisoned else { return [] }
        return transport.panicForensics()
    }

    private func panicForensicsSuffix(_ records: [String]) -> String {
        guard !records.isEmpty else { return "" }
        return " panicForensics=\(records)"
    }

    /// - Parameter panicForensics: Non-empty only when this invalidation was
    ///   caused by an `.internalPanic` / `.runtimePoisoned` transport error --
    ///   see the three call sites above. Drives the single production
    ///   diagnostics channel (`CorePanicForensicsBridge`); ordinary
    ///   invalidations (handshake mismatch, stale identity, shutdown) never
    ///   populate it and never notify.
    private func invalidate(panicForensics: [String] = []) {
        guard lifecycle != .invalidated, lifecycle != .closed else { return }
        #if DEBUG
        let trigger = firstInvalidationTrigger ?? "unrecorded (see stack)"
        print("[AgentryCoreBridge] INVALIDATED lifecycle=\(lifecycle) trigger=\(trigger)")
        for frame in Thread.callStackSymbols.prefix(14) {
            print("[AgentryCoreBridge]   \(frame)")
        }
        #endif
        if !panicForensics.isEmpty {
            CorePanicForensicsBridge.notify(
                CorePanicForensicsEvent(
                    trigger: firstInvalidationTrigger ?? "unrecorded (see stack)",
                    panicRecords: panicForensics
                )
            )
        }
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
