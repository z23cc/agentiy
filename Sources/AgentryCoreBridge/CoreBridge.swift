import AgentryUniFFIRaw
import CryptoKit
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
    case operationCancelled
    case shutdownRequested
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
    // P6-6: agent-claude-v1 (docs/architecture/rust-agent-claude-v1.md, design §11 P6-6).
    case agentClaudeUnknownScope
    case agentClaudeScopeClosed
    case agentClaudeAlreadyRunning
    case agentClaudeNotRunning
    case agentClaudeUnknownPermissionRequest
    case agentClaudeSpawnFailed(String)
    case agentClaudeReaperFailed(String)
    case agentClaudeTransportWriteFailed(String)
    case agentClaudeInvalidRequest(String)
    /// P6-7 (§15.5): the CLI answered a session-startup handshake control request (`initialize`/
    /// `set_permission_mode`) with `subtype: "error"`.
    case agentClaudeControlResponseError(String)
    case agentProviderUnknownScope
    case agentProviderScopeClosed
    case agentProviderAlreadyRunning
    case agentProviderNotRunning
    case agentProviderSpawnFailed(String)
    case agentProviderReaperFailed(String)
    case agentProviderTransportWriteFailed(String)
    case agentProviderInvalidRequest(String)
    case agentProviderCodexProtocolMismatch
    case agentProviderCodexInvalidJson
    case agentProviderCodexTimedOut(String)
    case agentProviderCodexCancelled(String)
    case agentProviderCodexRemoteError(method: String, code: Int64, message: String, data: Data?)
    case agentProviderCodexInvalidResponse
    case agentProviderAcpProtocolMismatch
    case agentProviderAcpInvalidJson
    case agentProviderAcpTimedOut(String)
    case agentProviderAcpCancelled(String)
    case agentProviderAcpRemoteError(method: String, code: Int64, message: String, data: Data?)
    case agentProviderAcpInvalidResponse
    case watcherUnknownScope
    case watcherScopeClosed
    case watcherInvalidRequest(String)
    // ADR-0011 P2: agent-host-v1 codec (`AgentHostProtocolV1`) and event log (`AgentSessionLog`).
    // Those objects throw the raw `CoreError` directly rather than through `CoreRuntime`; the
    // mirror keeps `map` exhaustive and gives the host shell one Swift vocabulary.
    case agentHostFrameMalformed(String)
    case agentHostFrameTooLarge(actual: UInt64, maximum: UInt64)
    case agentSessionLogIo(operation: String, message: String)
    case agentSessionLogNotFound(path: String)
    case agentSessionLogInvalidFile(String)
    case agentSessionLogUnsupportedSchemaVersion(found: UInt16, supported: UInt16)
    case agentSessionLogSessionMismatch(expected: String, found: String)
    case agentSessionLogInvalidSessionId(String)
    case agentSessionLogRecordTooLarge(actual: UInt64, maximum: UInt64)
    case agentSessionLogCursorOutOfRange(cursor: UInt64, nextCursor: UInt64)
    case agentSessionLogMalformedRecord(cursor: UInt64, message: String)
    case agentSessionLogSnapshotRejected(String)
    case agentSessionLogClosed
    /// ADR-0011 P6-a: an `AgentRun*V1` reducer object refused malformed identity text.
    case agentRunLifecycleInvalidRequest(String)
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
    func textDecodeV1(
        identity: CoreRuntimeIdentity,
        rawBytes: Data
    ) throws -> CoreTextDecodeResultV1
    func workspaceDocumentProjectionV1(
        identity: CoreRuntimeIdentity,
        documentBytes: Data
    ) throws -> CoreWorkspaceDocumentProjectionV1
    func workspaceCommandIdentityV1(
        identity: CoreRuntimeIdentity,
        request: CoreWorkspaceCommandIdentityRequestV1
    ) throws -> CoreWorkspaceCommandIdentityV1
    func workspaceSemanticInitialRecoveryPrepareV1(
        identity: CoreRuntimeIdentity,
        recovery: CoreWorkspaceSemanticFullRecoveryV1
    ) throws -> CorePreparedWorkspaceSemanticRecoveryV1
    func workspaceSavedRevisionValidateV1(
        identity: CoreRuntimeIdentity,
        payloadBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1
    func workspaceDeletionTombstoneValidateV1(
        identity: CoreRuntimeIdentity,
        payloadBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1
    func workspaceCatalogValidateV1(
        identity: CoreRuntimeIdentity,
        catalogBytes: Data
    ) throws -> CoreWorkspaceCatalogValidationV1
    func workspaceCatalogSeedV1(
        identity: CoreRuntimeIdentity,
        seedRequestBytes: Data
    ) throws -> CoreWorkspaceCatalogValidationV1
    func workspaceWorkingJournalValidateV1(
        identity: CoreRuntimeIdentity,
        journalBytes: Data
    ) throws -> CoreWorkspaceWorkingJournalValidationV1
    func workspaceWorkingJournalSeedV1(
        identity: CoreRuntimeIdentity,
        seedRequestBytes: Data
    ) throws -> CoreWorkspaceWorkingJournalValidationV1

    func workspacePendingSaveResolveV1(
        identity: CoreRuntimeIdentity,
        rawJournalBytes: Data,
        expectedWorkspaceID: UUID,
        expectedFileURL: URL,
        documentBytes: Data?
    ) throws -> CoreWorkspacePendingSaveRecoveryV1
    func searchScoreBatchV1(
        identity: CoreRuntimeIdentity,
        request: CoreSearchScoreBatchRequestV1
    ) throws -> [Int32]
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
    func inventoryOpenComposedSnapshot(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        roots: [AgentryUniFFIRaw.InventoryComposedRootDescriptorV1],
        accounting: AgentryUniFFIRaw.InventoryCompositionAccountingV1
    ) throws -> AgentryUniFFIRaw.InventoryComposedSnapshotHandleV1
    func inventoryComposedSnapshotPage(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        handleID: UInt64,
        offset: UInt64,
        limit: UInt64
    ) throws -> AgentryUniFFIRaw.CompactInventoryPageV1
    func inventoryCloseComposedSnapshot(scopeID: String, handleID: UInt64) throws
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
    /// P4-6b prep-4: `inventoryResolveRecordsScopeWide`'s facade completion (id-keyed, no root
    /// known in advance -- see `InventoryScope::resolve_records_scope_wide`'s doc comment).
    func inventoryResolveRecordsScopeWide(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactRecordBlockV1
    /// P4-6b gap-closure: discoverability toggle (see `InventoryScope::set_file_managed_only`'s
    /// doc comment).
    func inventorySetFileManagedOnly(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        fileID: Data,
        managedOnly: Bool
    ) throws
    func inventorySetFolderManagedOnly(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        folderID: Data,
        managedOnly: Bool
    ) throws
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
    /// Additive sibling of the above: the visibility policy travels with the call instead of being
    /// fixed in Rust. `bytes` is a `resolveRequest` wire block whose file-id section names the
    /// managed-only files the caller wants projected as visible.
    func inventoryOpenTreeProjectionShard(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.InventorySnapshotHandleV1

    // ---- P9: Rust-owned canonical MCP/tool catalog ---------------------------------------
    func mcpToolCatalogV1(identity: CoreRuntimeIdentity) throws -> AgentryUniFFIRaw.CoreMcpToolCatalogV1
    func mcpToolOperationIdentityV1(
        identity: CoreRuntimeIdentity,
        toolName: String,
        input: AgentryUniFFIRaw.CoreMcpToolOperationInputV1
    ) throws -> AgentryUniFFIRaw.CoreMcpToolOperationIdentityV1

    // ---- P7: Rust-owned filesystem watcher ingress mailbox -------------------------------
    func fileSystemWatcherOpenScope(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreFileSystemWatcherScopeConfigV1
    ) throws -> AgentryUniFFIRaw.CoreFileSystemWatcherScopeHandleV1
    func fileSystemWatcherStartAccepting(identity: CoreRuntimeIdentity, scopeID: String) throws
    func fileSystemWatcherIngest(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        entries: [AgentryUniFFIRaw.CoreFileSystemWatcherEventV1]
    ) throws -> UInt64?
    func fileSystemWatcherCaptureWatermark(identity: CoreRuntimeIdentity, scopeID: String) throws -> UInt64
    func fileSystemWatcherTakeNext(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        through: UInt64?
    ) throws -> AgentryUniFFIRaw.CoreFileSystemWatcherPayloadV1?
    func fileSystemWatcherSnapshot(
        identity: CoreRuntimeIdentity,
        scopeID: String
    ) throws -> AgentryUniFFIRaw.CoreFileSystemWatcherSnapshotV1
    func fileSystemWatcherReset(identity: CoreRuntimeIdentity, scopeID: String) throws
    func fileSystemWatcherCloseScope(identity: CoreRuntimeIdentity, scopeID: String) throws

    // ---- P6: shared Codex/ACP provider transport authority ------------------------------
    func agentProviderOpenScope(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreAgentProviderScopeConfigV1
    ) throws -> AgentryUniFFIRaw.AgentProviderScopeHandleV1
    func agentProviderStart(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.AgentProviderStartReceiptV1
    func agentProviderStartWithStdin(identity: CoreRuntimeIdentity, scopeID: String, payload: Data) throws -> AgentryUniFFIRaw.AgentProviderStartReceiptV1
    func agentProviderSendLine(identity: CoreRuntimeIdentity, scopeID: String, payload: Data) throws -> UInt64
    func agentProviderCodexRequest(identity: CoreRuntimeIdentity, scopeID: String, method: String, params: Data?, timeoutMilliseconds: UInt64?, cancellationToken: String?) throws -> Data
    func agentProviderCodexCancel(identity: CoreRuntimeIdentity, scopeID: String, cancellationToken: String) throws -> Bool
    func agentProviderCodexNotify(identity: CoreRuntimeIdentity, scopeID: String, method: String, params: Data?) throws -> UInt64
    func agentProviderCodexRespond(identity: CoreRuntimeIdentity, scopeID: String, requestID: Data, result: Data) throws -> UInt64
    func agentProviderCodexRespondError(identity: CoreRuntimeIdentity, scopeID: String, requestID: Data, code: Int64, message: String, data: Data?) throws -> UInt64
    func agentProviderCodexState(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.CoreCodexSessionStateV1
    func agentProviderAcpRequest(identity: CoreRuntimeIdentity, scopeID: String, method: String, params: Data?, timeoutMilliseconds: UInt64?, cancellationToken: String?) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpResponseV1
    func agentProviderAcpCancel(identity: CoreRuntimeIdentity, scopeID: String, cancellationToken: String) throws -> Bool
    func agentProviderAcpNotify(identity: CoreRuntimeIdentity, scopeID: String, method: String, params: Data?, expectedSessionGeneration: UInt64?) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpControlReceiptV1
    func agentProviderAcpRespond(identity: CoreRuntimeIdentity, scopeID: String, requestID: Data, result: Data) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpControlReceiptV1
    func agentProviderAcpRespondError(identity: CoreRuntimeIdentity, scopeID: String, requestID: Data, code: Int64, message: String, data: Data?) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpControlReceiptV1
    func agentProviderAcpState(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpSessionStateV1
    func agentProviderConformanceSnapshot(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.CoreAgentProviderConformanceSnapshotV1
    func agentProviderValidateConformance(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.CoreAgentProviderConformanceValidationV1
    func agentProviderShutdown(identity: CoreRuntimeIdentity, scopeID: String) throws

    // ---- P6-6: agent-claude-v1 (docs/architecture/rust-agent-claude-v1.md) -------------------
    //
    // Same deliberate, flagged deviation as inventory-scope-v1 above: raw `AgentryUniFFIRaw`
    // request/response records pass straight through beyond identity translation and error
    // mapping. Every field is already a plain Sendable value type.
    func agentOpenScope(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreAgentClaudeScopeConfigV1
    ) throws -> AgentryUniFFIRaw.AgentClaudeScopeHandleV1
    func agentStartOrResume(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        resumeSessionID: String?,
        model: String?,
        effortLevel: String?
    ) throws -> AgentryUniFFIRaw.AgentClaudeStartReceiptV1
    func agentSendUserMessage(identity: CoreRuntimeIdentity, scopeID: String, text: String) throws -> UInt64
    func agentInterruptTurn(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        turnGeneration: UInt64,
        reason: String
    ) throws -> AgentryUniFFIRaw.AgentClaudeInterruptReceiptV1
    func agentRespondPermission(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        requestID: String,
        decision: AgentryUniFFIRaw.AgentClaudePermissionDecisionV1
    ) throws
    func agentApplyModelAndEffort(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        model: String?,
        effort: String?,
        disposition: AgentryUniFFIRaw.AgentClaudeFlagSettingsDispositionV1
    ) throws -> AgentryUniFFIRaw.AgentClaudeFlagSettingsReceiptV1
    func agentShutdown(identity: CoreRuntimeIdentity, scopeID: String) throws

    // MARK: - ADR-0012 Direct Workspace Mutation & Quarantine APIs
    func workspaceCreateDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        workspaceName: String,
        documentBytes: Data,
        expectedCatalogRevision: UInt64,
        operationID: UUID,
        fingerprint: String?
    ) throws -> CoreWorkspaceCommandResultV1

    func workspaceSaveDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        documentBytes: Data,
        expectedWorkingRevision: UInt64,
        expectedCatalogRevision: UInt64,
        operationID: UUID,
        fingerprint: String?
    ) throws -> CoreWorkspaceCommandResultV1

    func workspaceDeleteDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        expectedCatalogRevision: UInt64,
        operationID: UUID
    ) throws -> CoreWorkspaceCommandResultV1

    func workspaceMutateWorkingDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        candidateDocumentBytes: Data,
        expectedWorkingRevision: UInt64,
        operationID: UUID
    ) throws -> CoreWorkspaceCommandResultV1

    func workspaceIsQuarantinedV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID
    ) throws -> (isQuarantined: Bool, reason: String?)

    func workspaceQuarantinedWorkspacesV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String
    ) throws -> [(workspaceID: UUID, reason: String)]

    /// Forensic strings for the most recent panic(s) recorded by the Rust
    /// process-wide panic hook, most-recent last -- not scoped to this
    /// transport's runtime instance, and not limited to panics that a
    /// `PanicGuard` happened to contain. Deliberately infallible and callable
    /// after the runtime is poisoned/invalidated -- see
    /// `AgentryUniFFIRaw.CoreRuntime.panicForensics()`.
    func panicForensics() -> [String]
}

extension CoreRuntimeTransport {
    /// Test transports and legacy adapters may omit the optional catalog read until they opt in;
    /// production UniFFI transport overrides this with the Rust export.
    func mcpToolCatalogV1(identity: CoreRuntimeIdentity) throws -> AgentryUniFFIRaw.CoreMcpToolCatalogV1 {
        throw CoreTransportError.unexpected("MCP catalog projection unavailable")
    }

    func mcpToolOperationIdentityV1(
        identity: CoreRuntimeIdentity,
        toolName: String,
        input: AgentryUniFFIRaw.CoreMcpToolOperationInputV1
    ) throws -> AgentryUniFFIRaw.CoreMcpToolOperationIdentityV1 {
        throw CoreTransportError.unexpected("MCP operation identity unavailable")
    }
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

    func textDecodeV1(
        identity: CoreRuntimeIdentity,
        rawBytes: Data
    ) throws -> CoreTextDecodeResultV1 {
        let value: AgentryUniFFIRaw.CoreTextDecodeResultV1
        do {
            value = try runtime.textDecodeV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreTextDecodeResultV1.contractVersion,
                rawBytes: rawBytes
            ))
        } catch {
            throw Self.map(error)
        }
        let encoding: CoreTextEncodingV1 = switch value.encoding {
        case .utf8:
            .utf8
        case .utf16BigEndian:
            .utf16BigEndian
        case .utf16LittleEndian:
            .utf16LittleEndian
        case .utf32BigEndian:
            .utf32BigEndian
        case .utf32LittleEndian:
            .utf32LittleEndian
        case .legacy:
            if let name = value.legacyEncodingName, !name.isEmpty {
                .legacy(ianaName: name)
            } else {
                throw CoreComputeError.malformedResponse
            }
        }
        if value.encoding != .legacy, value.legacyEncodingName != nil {
            throw CoreComputeError.malformedResponse
        }
        return CoreTextDecodeResultV1(
            text: value.text,
            encoding: encoding,
            bomPresent: value.bomPresent,
            hadReplacements: value.hadReplacements,
            policyID: value.policyId
        )
    }

    func workspaceDocumentProjectionV1(
        identity: CoreRuntimeIdentity,
        documentBytes: Data
    ) throws -> CoreWorkspaceDocumentProjectionV1 {
        let value: AgentryUniFFIRaw.CoreWorkspaceDocumentProjectionV1
        do {
            value = try runtime.workspaceDocumentProjectionV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceDocumentProjectionV1.contractVersion,
                documentBytes: documentBytes
            ))
        } catch {
            throw Self.map(error)
        }

        func optionalUUID(_ raw: String?) throws -> UUID? {
            guard let raw else { return nil }
            guard let value = UUID(uuidString: raw) else {
                throw CoreComputeError.malformedResponse
            }
            return value
        }

        guard let workspaceID = UUID(uuidString: value.workspaceId),
              let schemaVersion = Int(exactly: value.schemaVersion)
        else {
            throw CoreComputeError.malformedResponse
        }
        let contexts = try value.contexts.map { context -> CoreWorkspaceContextProjectionV1 in
            guard let contextID = UUID(uuidString: context.contextId) else {
                throw CoreComputeError.malformedResponse
            }
            return try CoreWorkspaceContextProjectionV1(
                contextID: contextID,
                name: context.name,
                activeAgentSessionID: optionalUUID(context.activeAgentSessionId),
                activeChatSessionID: optionalUUID(context.activeChatSessionId),
                prompt: context.prompt,
                selection: context.selection
            )
        }
        return try CoreWorkspaceDocumentProjectionV1(
            workspaceID: workspaceID,
            schemaVersion: schemaVersion,
            name: value.name,
            repoPaths: value.repoPaths,
            activeContextID: optionalUUID(value.activeContextId),
            contexts: contexts
        )
    }

    func workspaceCommandIdentityV1(
        identity: CoreRuntimeIdentity,
        request: CoreWorkspaceCommandIdentityRequestV1
    ) throws -> CoreWorkspaceCommandIdentityV1 {
        do {
            let response = try runtime.workspaceCommandIdentityV1(
                request: Self.rawWorkspaceCommandIdentityRequest(
                    identity: identity,
                    request: request
                )
            )
            if let errorKind = response.errorKind {
                guard response.identity == nil else {
                    throw CoreTransportError.unexpected(
                        "workspace command identity response contains success and error"
                    )
                }
                throw try Self.workspaceWorkingJournalValidationError(
                    errorKind,
                    futureSchemaVersion: response.futureSchemaVersion
                )
            }
            guard response.futureSchemaVersion == nil,
                  let value = response.identity
            else {
                throw CoreTransportError.unexpected(
                    "workspace command identity receipt is invalid"
                )
            }
            return try Self.workspaceCommandIdentity(value, request: request)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func workspaceSemanticInitialRecoveryPrepareV1(
        identity: CoreRuntimeIdentity,
        recovery: CoreWorkspaceSemanticFullRecoveryV1
    ) throws -> CorePreparedWorkspaceSemanticRecoveryV1 {
        do {
            return try preparedWorkspaceSemanticRecovery(
                identity: identity,
                response: runtime.workspaceSemanticInitialRecoveryPrepareV1(request: .init(
                    runtimeIdentity: Self.rawIdentity(identity),
                    contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                    recovery: Self.rawWorkspaceSemanticFullRecovery(recovery)
                ))
            )
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    private func preparedWorkspaceSemanticRecovery(
        identity: CoreRuntimeIdentity,
        response: AgentryUniFFIRaw.CoreWorkspaceSemanticRecoveryPrepareResponseV1
    ) throws -> CorePreparedWorkspaceSemanticRecoveryV1 {
        if let errorKind = response.errorKind {
            guard response.recovery == nil else {
                throw CoreTransportError.unexpected(
                    "workspace semantic recovery prepare contains success and error"
                )
            }
            throw try Self.workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let rawRecovery = response.recovery
        else {
            throw CoreTransportError.unexpected("workspace semantic recovery prepare is invalid")
        }
        return CorePreparedWorkspaceSemanticRecoveryV1(
            rawRecovery: rawRecovery,
            preview: {
                do {
                    return try Self.workspaceSemanticRecoveryPreviewResponse(rawRecovery.preview())
                } catch let error as CoreWorkspaceWorkingJournalValidationError {
                    throw error
                } catch {
                    throw Self.map(error)
                }
            },
            commit: {
                do {
                    return try self.workspaceSemanticRecoveryCommitResponse(
                        rawRecovery.commit(),
                        identity: identity
                    )
                } catch let error as CoreWorkspaceWorkingJournalValidationError {
                    throw error
                } catch {
                    throw Self.map(error)
                }
            },
            close: { rawRecovery.close() }
        )
    }

    private func preparedWorkspaceCommandAdmission(
        identity: CoreRuntimeIdentity,
        rawAdmission: AgentryUniFFIRaw.CorePreparedWorkspaceCommandAdmissionV1
    ) -> CorePreparedWorkspaceCommandAdmissionV1 {
        CorePreparedWorkspaceCommandAdmissionV1(
            rawAdmission: rawAdmission,
            acquire: { request, deadlineUnixMilliseconds in
                do {
                    return try Self.workspaceCommandAdmissionAcquisition(
                        rawAdmission.acquire(
                            request: Self.rawWorkspaceCommandIdentityRequest(
                                identity: identity,
                                request: request
                            ),
                            deadlineUnixMillis: deadlineUnixMilliseconds
                        ),
                        request: request,
                        runtimeIdentity: identity
                    )
                } catch let error as CoreWorkspaceWorkingJournalValidationError {
                    throw error
                } catch {
                    throw Self.workspaceCommandLifecycleError(error)
                }
            },
            cancel: { operationID in
                try self.cancel(identity: identity, operationID: operationID)
            },
            prepareSemanticFullRecovery: { recovery in
                do {
                    return try self.preparedWorkspaceSemanticRecovery(
                        identity: identity,
                        response: rawAdmission.prepareSemanticFullRecovery(
                            recovery: Self.rawWorkspaceSemanticFullRecovery(recovery)
                        )
                    )
                } catch let error as CoreWorkspaceWorkingJournalValidationError {
                    throw error
                } catch {
                    throw Self.map(error)
                }
            },
            prepareSemanticTargetRecovery: { recovery in
                do {
                    return try self.preparedWorkspaceSemanticRecovery(
                        identity: identity,
                        response: rawAdmission.prepareSemanticTargetRecovery(
                            recovery: Self.rawWorkspaceSemanticTargetRecovery(recovery)
                        )
                    )
                } catch let error as CoreWorkspaceWorkingJournalValidationError {
                    throw error
                } catch {
                    throw Self.map(error)
                }
            },
            prepareExternalObservationRecovery: { request in
                do {
                    let response = try rawAdmission.prepareExternalObservationRecovery(request: .init(
                        runtimeIdentity: Self.rawIdentity(identity),
                        contractVersion: CoreWorkspaceDocumentProjectionV1.contractVersion,
                        workspaceId: request.workspaceID.uuidString.lowercased(),
                        expectedFileUrl: request.expectedFileURL.standardizedFileURL.absoluteString,
                        expectedCatalogRevision: request.expectedCatalogRevision,
                        expectedWorkspaceRevision: request.expectedWorkspaceRevision,
                        currentDocumentDigest: request.currentDocumentDigest,
                        savedDigest: request.savedDigest,
                        externalDocumentBytes: request.externalDocumentBytes,
                        updatedAt: request.updatedAt.timeIntervalSinceReferenceDate
                    ))
                    if let errorKind = response.errorKind {
                        guard response.plan == nil else {
                            throw CoreTransportError.unexpected(
                                "workspace external observation response contains success and error"
                            )
                        }
                        throw try Self.workspaceWorkingJournalValidationError(
                            errorKind,
                            futureSchemaVersion: response.futureSchemaVersion
                        )
                    }
                    guard response.futureSchemaVersion == nil, let plan = response.plan else {
                        throw CoreTransportError.unexpected(
                            "workspace external observation plan is invalid"
                        )
                    }
                    return try Self.workspaceExternalObservationPlan(plan, request: request)
                } catch let error as CoreWorkspaceWorkingJournalValidationError {
                    throw error
                } catch {
                    throw Self.map(error)
                }
            },

            diagnostics: {
                do {
                    return try Self.workspaceCommandAdmissionDiagnostics(rawAdmission.diagnostics())
                } catch let error as CoreWorkspaceWorkingJournalValidationError {
                    throw error
                } catch {
                    throw Self.map(error)
                }
            },
            publishAuthorityState: { workspaces, draft in
                do {
                    return try Self.workspaceAuthorityPublicationResponse(
                        rawAdmission.publishAuthorityState(
                            workspaces: workspaces.map(coreWorkspaceProjectionRawPublishedWorkspace),
                            draft: Self.rawWorkspaceAuthorityPublicationDraft(draft)
                        ),
                        draft: draft,
                        workspaceCount: workspaces.count
                    )
                } catch let error as CoreWorkspaceWorkingJournalValidationError {
                    throw error
                } catch {
                    throw Self.map(error)
                }
            },
            synchronizeAuthorityProjection: { workspaces in
                do {
                    return try Self.workspaceAuthorityProjectionSyncResponse(
                        rawAdmission.synchronizeAuthorityProjection(
                            workspaces: workspaces.map(coreWorkspaceProjectionRawPublishedWorkspace)
                        ),
                        workspaceCount: workspaces.count
                    )
                } catch let error as CoreWorkspaceWorkingJournalValidationError {
                    throw error
                } catch {
                    throw Self.map(error)
                }
            },
            authorityRead: { workspaceID in
                do {
                    return try Self.workspaceAuthorityReadResponse(
                        rawAdmission.authorityRead(
                            workspaceId: workspaceID.uuidString.lowercased()
                        ),
                        workspaceID: workspaceID
                    )
                } catch let error as CoreWorkspaceWorkingJournalValidationError {
                    throw error
                } catch {
                    throw Self.map(error)
                }
            },
            close: { rawAdmission.close() }
        )
    }

    private static func rawWorkspaceAuthorityPublicationDraft(
        _ draft: CoreWorkspaceAuthorityPublicationDraft
    ) -> AgentryUniFFIRaw.CoreWorkspaceAuthorityPublicationDraftV1 {
        let kind: AgentryUniFFIRaw.CoreWorkspaceProjectionPublicationKindV1 = switch draft.kind {
        case .bootstrapped: .bootstrapped
        case .workspaceCreated: .workspaceCreated
        case .workspaceDeleted: .workspaceDeleted
        case .workingStateCommitted: .workingStateCommitted
        case .savedDocumentCommitted: .savedDocumentCommitted
        case .externalReloaded: .externalReloaded
        case .externalConflict: .externalConflict
        case .degraded: .degraded
        case .routingChanged: .routingChanged
        case .operationDeduplicated: .operationDeduplicated
        }
        return .init(
            catalogRevision: draft.catalogRevision,
            kind: kind,
            workspaceId: draft.workspaceID?.uuidString.lowercased(),
            contextId: draft.contextID?.uuidString.lowercased(),
            operationId: draft.operationID?.uuidString.lowercased(),
            revisions: draft.revisions.map(coreWorkspaceProjectionRawRevisionState)
        )
    }

    private static func workspaceProjectionPublicationKind(
        _ kind: AgentryUniFFIRaw.CoreWorkspaceProjectionPublicationKindV1
    ) -> CoreWorkspaceProjectionPublicationKind {
        switch kind {
        case .bootstrapped: .bootstrapped
        case .workspaceCreated: .workspaceCreated
        case .workspaceDeleted: .workspaceDeleted
        case .workingStateCommitted: .workingStateCommitted
        case .savedDocumentCommitted: .savedDocumentCommitted
        case .externalReloaded: .externalReloaded
        case .externalConflict: .externalConflict
        case .degraded: .degraded
        case .routingChanged: .routingChanged
        case .operationDeduplicated: .operationDeduplicated
        }
    }

    private static func workspaceProjectionPublicationEvent(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceProjectionPublicationEventV1
    ) throws -> CoreWorkspaceProjectionPublicationEvent {
        func optionalUUID(_ raw: String?) throws -> UUID? {
            guard let raw else { return nil }
            guard let value = UUID(uuidString: raw) else {
                throw CoreTransportError.unexpected("workspace authority event identity is invalid")
            }
            return value
        }
        return CoreWorkspaceProjectionPublicationEvent(
            sequence: raw.sequence,
            catalogRevision: raw.catalogRevision,
            kind: workspaceProjectionPublicationKind(raw.kind),
            workspaceID: try optionalUUID(raw.workspaceId),
            contextID: try optionalUUID(raw.contextId),
            operationID: try optionalUUID(raw.operationId),
            revisions: raw.revisions.map {
                CoreWorkspaceProjectionRevisionState(
                    workingRevision: $0.workingRevision,
                    savedRevision: $0.savedRevision,
                    dirtyRevision: $0.dirtyRevision
                )
            }
        )
    }

    private static func workspaceClaimlessAuthorityPublicationResponse(
        _ response: AgentryUniFFIRaw.CoreWorkspaceClaimlessAuthorityPublicationResponseV1,
        expectedWorkspaceID: UUID?
    ) throws -> CoreWorkspaceClaimlessAuthorityPublicationReceipt {
        if let errorKind = response.errorKind {
            guard response.receipt == nil else {
                throw CoreTransportError.unexpected(
                    "workspace claimless authority publication response contains success and error"
                )
            }
            throw try workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let raw = response.receipt,
              raw.semanticGeneration == raw.previousSemanticGeneration.addingReportingOverflow(1).partialValue,
              !raw.semanticGeneration.addingReportingOverflow(1).overflow,
              raw.publicationSequence == raw.previousPublicationSequence.addingReportingOverflow(1).partialValue,
              !raw.previousPublicationSequence.addingReportingOverflow(1).overflow,
              isSHA256(raw.projectionDigest),
              raw.event.sequence == raw.publicationSequence,
              raw.event.catalogRevision == raw.catalogRevision,
              raw.event.operationId == nil,
              raw.event.contextId == nil,
              raw.event.workspaceId != nil,
              raw.event.revisions.map(workspaceRevisionStateIsValid) == true,
              raw.event.kind == .externalReloaded || raw.event.kind == .workingStateCommitted
        else {
            throw CoreTransportError.unexpected(
                "workspace claimless authority publication receipt is invalid"
            )
        }
        if let expectedWorkspaceID,
           raw.event.workspaceId.flatMap(UUID.init(uuidString:)) != expectedWorkspaceID
        {
            throw CoreTransportError.unexpected(
                "workspace claimless authority publication workspace identity is invalid"
            )
        }
        return CoreWorkspaceClaimlessAuthorityPublicationReceipt(
            previousSemanticGeneration: raw.previousSemanticGeneration,
            semanticGeneration: raw.semanticGeneration,
            previousPublicationSequence: raw.previousPublicationSequence,
            publicationSequence: raw.publicationSequence,
            catalogRevision: raw.catalogRevision,
            projectionDigest: raw.projectionDigest,
            event: try workspaceProjectionPublicationEvent(raw.event)
        )
    }

    private static func workspaceAuthorityPublicationResponse(
        _ response: AgentryUniFFIRaw.CoreWorkspaceAuthorityPublicationResponseV1,
        draft: CoreWorkspaceAuthorityPublicationDraft,
        workspaceCount: Int
    ) throws -> CoreWorkspaceAuthorityPublicationReceipt {
        if let errorKind = response.errorKind {
            guard response.receipt == nil else {
                throw CoreTransportError.unexpected(
                    "workspace authority publication response contains success and error"
                )
            }
            throw try workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let raw = response.receipt
        else {
            throw CoreTransportError.unexpected("workspace authority publication receipt is invalid")
        }
        return try workspaceAuthorityPublicationReceipt(
            raw,
            draft: draft,
            workspaceCount: workspaceCount
        )
    }

    private static func workspaceAuthorityPublicationReceipt(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceAuthorityPublicationReceiptV1,
        draft: CoreWorkspaceAuthorityPublicationDraft,
        workspaceCount: Int
    ) throws -> CoreWorkspaceAuthorityPublicationReceipt {
        let nextPublicationSequence = raw.previousPublicationSequence.addingReportingOverflow(1)
        let nextGeneration = raw.previousGeneration.addingReportingOverflow(1)
        guard !nextPublicationSequence.overflow,
              let expectedWorkspaceCount = UInt64(exactly: workspaceCount),
              raw.workspaceCount == expectedWorkspaceCount,
              raw.catalogRevision == draft.catalogRevision,
              raw.publicationSequence == nextPublicationSequence.partialValue,
              raw.event.sequence == raw.publicationSequence,
              raw.event.catalogRevision == raw.catalogRevision,
              isSHA256(raw.projectionDigest),
              raw.eventLogCount <= 256,
              raw.eventLogFloorSequence <= raw.publicationSequence
        else {
            throw CoreTransportError.unexpected("workspace authority publication receipt is invalid")
        }
        let event = try workspaceProjectionPublicationEvent(raw.event)
        guard event.kind == draft.kind,
              event.workspaceID == draft.workspaceID,
              event.contextID == draft.contextID,
              event.operationID == draft.operationID,
              event.revisions == draft.revisions,
              raw.projectionChanged
              ? !nextGeneration.overflow && raw.generation == nextGeneration.partialValue
              : raw.generation == raw.previousGeneration
        else {
            throw CoreTransportError.unexpected("workspace authority publication event is invalid")
        }
        return CoreWorkspaceAuthorityPublicationReceipt(
            previousGeneration: raw.previousGeneration,
            generation: raw.generation,
            projectionChanged: raw.projectionChanged,
            workspaceCount: raw.workspaceCount,
            retainedBytes: raw.retainedBytes,
            previousCatalogRevision: raw.previousCatalogRevision,
            previousPublicationSequence: raw.previousPublicationSequence,
            catalogRevision: raw.catalogRevision,
            publicationSequence: raw.publicationSequence,
            eventLogFloorSequence: raw.eventLogFloorSequence,
            eventLogCount: raw.eventLogCount,
            projectionDigest: raw.projectionDigest,
            event: event
        )
    }

    private static func workspaceCommandResult(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceCommandResultV1
    ) throws -> CoreWorkspaceCommandResultV1 {
        let contextID = try raw.contextId.map { value in
            guard let contextID = UUID(uuidString: value) else {
                throw CoreTransportError.unexpected("workspace command result context identity is invalid")
            }
            return contextID
        }
        guard let workspaceID = UUID(uuidString: raw.workspaceId),
              isSHA256(raw.operation.fingerprint),
              raw.resultingDigest.map(isSHA256) ?? true,
              raw.catalogRevision == raw.operation.catalogRevision,
              raw.resultingDigest == raw.operation.resultingDigest,
              raw.before == raw.operation.before,
              raw.after == raw.operation.after,
              raw.before.map(workspaceRevisionStateIsValid) ?? true,
              raw.after.map(workspaceRevisionStateIsValid) ?? true
        else {
            throw CoreTransportError.unexpected("workspace command result is invalid")
        }
        let operation = try workspaceRecordedOperation(raw.operation)
        let disposition: CoreWorkspaceCommandResultDispositionV1 = switch raw.disposition {
        case .applied: .applied
        case .unchanged: .unchanged
        case .deleted: .deleted
        }
        let publicationKind = workspaceProjectionPublicationKind(raw.publicationKind)
        let expectedOperationDisposition: String = switch disposition {
        case .applied, .deleted: "applied"
        case .unchanged: "unchanged"
        }
        let publicationSemanticsValid: Bool = switch disposition {
        case .deleted:
            publicationKind == .workspaceDeleted
        case .unchanged:
            publicationKind == .operationDeduplicated
        case .applied:
            switch publicationKind {
            case .workspaceCreated, .workingStateCommitted,
                 .savedDocumentCommitted, .externalReloaded:
                true
            case .workspaceDeleted, .operationDeduplicated, .bootstrapped,
                 .externalConflict, .degraded, .routingChanged:
                false
            }
        }
        guard operation.disposition == expectedOperationDisposition,
              operation.errorCode == nil,
              operation.diagnostic == nil,
              publicationSemanticsValid
        else {
            throw CoreTransportError.unexpected("workspace command result semantics are invalid")
        }
        return CoreWorkspaceCommandResultV1(
            workspaceID: workspaceID,
            operation: operation,
            disposition: disposition,
            before: raw.before.map(workspaceRevisionState),
            after: raw.after.map(workspaceRevisionState),
            resultingDigest: raw.resultingDigest,
            catalogRevision: raw.catalogRevision,
            publicationKind: publicationKind,
            contextID: contextID
        )
    }

    private static func workspaceAuthorityProjectionSyncResponse(
        _ response: AgentryUniFFIRaw.CoreWorkspaceAuthorityProjectionSyncResponseV1,
        workspaceCount: Int
    ) throws -> CoreWorkspaceAuthorityProjectionSyncReceipt {
        if let errorKind = response.errorKind {
            guard response.receipt == nil else {
                throw CoreTransportError.unexpected(
                    "workspace authority projection sync contains success and error"
                )
            }
            throw try workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        let nextGeneration: UInt64?
        if let raw = response.receipt {
            let next = raw.previousGeneration.addingReportingOverflow(1)
            nextGeneration = next.overflow ? nil : next.partialValue
        } else {
            nextGeneration = nil
        }
        guard response.futureSchemaVersion == nil,
              let raw = response.receipt,
              let expectedWorkspaceCount = UInt64(exactly: workspaceCount),
              raw.workspaceCount == expectedWorkspaceCount,
              isSHA256(raw.projectionDigest),
              raw.projectionChanged
              ? raw.generation == nextGeneration
              : raw.generation == raw.previousGeneration
        else {
            throw CoreTransportError.unexpected(
                "workspace authority projection sync receipt is invalid"
            )
        }
        return CoreWorkspaceAuthorityProjectionSyncReceipt(
            previousGeneration: raw.previousGeneration,
            generation: raw.generation,
            projectionChanged: raw.projectionChanged,
            workspaceCount: raw.workspaceCount,
            retainedBytes: raw.retainedBytes,
            catalogRevision: raw.catalogRevision,
            publicationSequence: raw.publicationSequence,
            projectionDigest: raw.projectionDigest
        )
    }

    private static func workspaceAuthorityReadResponse(
        _ response: AgentryUniFFIRaw.CoreWorkspaceAuthorityReadResponseV1,
        workspaceID: UUID
    ) throws -> CoreWorkspaceAuthorityRead {
        if let errorKind = response.errorKind {
            guard response.read == nil else {
                throw CoreTransportError.unexpected(
                    "workspace authority read response contains success and error"
                )
            }
            throw try workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let raw = response.read,
              isSHA256(raw.projectionDigest),
              raw.eventLogCount <= 256,
              (raw.projection == nil) == (raw.contentDigest == nil),
              raw.contentDigest.map(isSHA256) ?? true
        else {
            throw CoreTransportError.unexpected("workspace authority read receipt is invalid")
        }
        let eventLogIsValid: Bool
        if raw.eventLogCount == 0 {
            let (nextSequence, overflow) = raw.publicationSequence.addingReportingOverflow(1)
            eventLogIsValid = raw.eventLogFloorSequence == (overflow ? UInt64.max : nextSequence)
        } else if raw.eventLogFloorSequence <= raw.publicationSequence {
            let delta = raw.publicationSequence - raw.eventLogFloorSequence
            let (span, overflow) = delta.addingReportingOverflow(1)
            eventLogIsValid = !overflow && span == UInt64(raw.eventLogCount)
        } else {
            eventLogIsValid = false
        }
        guard eventLogIsValid else {
            throw CoreTransportError.unexpected("workspace authority event log is invalid")
        }
        let projection = try raw.projection.map(coreWorkspaceDocumentProjection)
        if projection == nil {
            return CoreWorkspaceAuthorityRead(
                projection: nil,
                contentDigest: nil,
                generation: raw.generation,
                catalogRevision: raw.catalogRevision,
                publicationSequence: raw.publicationSequence,
                eventLogFloorSequence: raw.eventLogFloorSequence,
                eventLogCount: raw.eventLogCount,
                projectionDigest: raw.projectionDigest
            )
        }
        guard projection?.workspaceID == workspaceID,
              projection?.authority != nil
        else {
            throw CoreTransportError.unexpected("workspace authority read identity is invalid")
        }
        return CoreWorkspaceAuthorityRead(
            projection: projection,
            contentDigest: raw.contentDigest,
            generation: raw.generation,
            catalogRevision: raw.catalogRevision,
            publicationSequence: raw.publicationSequence,
            eventLogFloorSequence: raw.eventLogFloorSequence,
            eventLogCount: raw.eventLogCount,
            projectionDigest: raw.projectionDigest
        )
    }

    func workspaceSavedRevisionValidateV1(
        identity: CoreRuntimeIdentity,
        payloadBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        try workspacePersistenceMetadata(
            identity: identity,
            payloadBytes: payloadBytes,
            operation: runtime.workspaceSavedRevisionValidateV1
        )
    }

    func workspaceDeletionTombstoneValidateV1(
        identity: CoreRuntimeIdentity,
        payloadBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        try workspacePersistenceMetadata(
            identity: identity,
            payloadBytes: payloadBytes,
            operation: runtime.workspaceDeletionTombstoneValidateV1
        )
    }

    func workspaceCatalogValidateV1(
        identity: CoreRuntimeIdentity,
        catalogBytes: Data
    ) throws -> CoreWorkspaceCatalogValidationV1 {
        do {
            let response = try runtime.workspaceCatalogValidateV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                catalogBytes: catalogBytes
            ))
            return try Self.workspaceCatalogValidation(response)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func workspaceCatalogSeedV1(
        identity: CoreRuntimeIdentity,
        seedRequestBytes: Data
    ) throws -> CoreWorkspaceCatalogValidationV1 {
        do {
            let response = try runtime.workspaceCatalogSeedV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                seedRequestBytes: seedRequestBytes
            ))
            return try Self.workspaceCatalogValidation(response)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    private func workspacePersistenceMetadata(
        identity: CoreRuntimeIdentity,
        payloadBytes: Data,
        operation: (AgentryUniFFIRaw.CoreWorkspacePersistenceMetadataRequestV1) throws
            -> AgentryUniFFIRaw.CoreWorkspacePersistenceMetadataResponseV1
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        do {
            let response = try operation(.init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                payloadBytes: payloadBytes
            ))
            return try Self.workspacePersistenceMetadataResponse(response)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    private static func workspacePersistenceMetadataResponse(
        _ response: AgentryUniFFIRaw.CoreWorkspacePersistenceMetadataResponseV1
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        if let errorKind = response.errorKind {
            guard response.validation == nil else {
                throw CoreTransportError.unexpected(
                    "workspace persistence metadata response contains success and error"
                )
            }
            throw try workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let result = response.validation
        else {
            throw CoreTransportError.unexpected(
                "workspace persistence metadata receipt is invalid"
            )
        }
        return try workspacePersistenceMetadataValidation(result)
    }

    private static func workspaceCatalogValidation(
        _ response: AgentryUniFFIRaw.CoreWorkspaceCatalogResponseV1
    ) throws -> CoreWorkspaceCatalogValidationV1 {
        if let errorKind = response.errorKind {
            guard response.validation == nil else {
                throw CoreTransportError.unexpected(
                    "workspace catalog response contains success and error"
                )
            }
            throw try workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let result = response.validation
        else {
            throw CoreTransportError.unexpected("workspace catalog receipt is invalid")
        }
        return try workspaceCatalogValidation(result)
    }

    private static func workspaceCatalogValidation(
        _ result: AgentryUniFFIRaw.CoreWorkspaceCatalogValidationV1
    ) throws -> CoreWorkspaceCatalogValidationV1 {
        let computedDigest = SHA256.hash(data: result.canonicalBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        guard result.catalogVersion <= CoreWorkspaceWorkingJournalValidationV1.contractVersion,
              result.canonicalBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              result.contentDigest == computedDigest
        else {
            throw CoreTransportError.unexpected("workspace catalog receipt is invalid")
        }
        return CoreWorkspaceCatalogValidationV1(
            catalogVersion: result.catalogVersion,
            revision: result.revision,
            entryCount: result.entryCount,
            deletionCount: result.deletionCount,
            contentDigest: result.contentDigest,
            canonicalBytes: result.canonicalBytes
        )
    }

    private static func workspacePersistenceMetadataValidation(
        _ result: AgentryUniFFIRaw.CoreWorkspacePersistenceMetadataValidationV1
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        let computedDigest = SHA256.hash(data: result.canonicalBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        guard let workspaceID = UUID(uuidString: result.workspaceId),
              let operationID = UUID(uuidString: result.operationId),
              result.schemaVersion == CoreWorkspaceWorkingJournalValidationV1.contractVersion,
              result.canonicalBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              result.contentDigest == computedDigest
        else {
            throw CoreTransportError.unexpected(
                "workspace persistence metadata receipt is invalid"
            )
        }
        return CoreWorkspacePersistenceMetadataValidationV1(
            workspaceID: workspaceID,
            operationID: operationID,
            schemaVersion: result.schemaVersion,
            contentDigest: result.contentDigest,
            canonicalBytes: result.canonicalBytes
        )
    }

    func workspaceWorkingJournalValidateV1(
        identity: CoreRuntimeIdentity,
        journalBytes: Data
    ) throws -> CoreWorkspaceWorkingJournalValidationV1 {
        do {
            let response = try runtime.workspaceWorkingJournalValidateV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                journalBytes: journalBytes
            ))
            if let errorKind = response.errorKind {
                guard response.validation == nil else {
                    throw CoreTransportError.unexpected(
                        "workspace working journal response contains success and error"
                    )
                }
                throw try Self.workspaceWorkingJournalValidationError(
                    errorKind,
                    futureSchemaVersion: response.futureSchemaVersion
                )
            }
            guard response.futureSchemaVersion == nil,
                  let result = response.validation
            else {
                throw CoreTransportError.unexpected(
                    "workspace working journal validation receipt is invalid"
                )
            }
            return try Self.workspaceWorkingJournalValidation(result)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func workspaceWorkingJournalSeedV1(
        identity: CoreRuntimeIdentity,
        seedRequestBytes: Data
    ) throws -> CoreWorkspaceWorkingJournalValidationV1 {
        do {
            let response = try runtime.workspaceWorkingJournalSeedV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                seedRequestBytes: seedRequestBytes
            ))
            if let errorKind = response.errorKind {
                guard response.validation == nil else {
                    throw CoreTransportError.unexpected(
                        "workspace working journal seed response contains success and error"
                    )
                }
                throw try Self.workspaceWorkingJournalValidationError(
                    errorKind,
                    futureSchemaVersion: response.futureSchemaVersion
                )
            }
            guard response.futureSchemaVersion == nil,
                  let result = response.validation
            else {
                throw CoreTransportError.unexpected(
                    "workspace working journal seed receipt is invalid"
                )
            }
            return try Self.workspaceWorkingJournalValidation(result)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func workspacePendingSaveResolveV1(
        identity: CoreRuntimeIdentity,
        rawJournalBytes: Data,
        expectedWorkspaceID: UUID,
        expectedFileURL: URL,
        documentBytes: Data?
    ) throws -> CoreWorkspacePendingSaveRecoveryV1 {
        do {
            let response = try runtime.workspacePendingSaveResolveV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                rawJournalBytes: rawJournalBytes,
                expectedWorkspaceId: expectedWorkspaceID.uuidString.lowercased(),
                expectedFileUrl: expectedFileURL.standardizedFileURL.absoluteString,
                documentBytes: documentBytes
            ))
            if let errorKind = response.errorKind {
                guard response.recovery == nil else {
                    throw CoreTransportError.unexpected(
                        "workspace pending save response contains success and error"
                    )
                }
                throw try Self.workspaceWorkingJournalValidationError(
                    errorKind,
                    futureSchemaVersion: response.futureSchemaVersion
                )
            }
            guard response.futureSchemaVersion == nil,
                  let recovery = response.recovery
            else {
                throw CoreTransportError.unexpected(
                    "workspace pending save recovery receipt is invalid"
                )
            }
            return try Self.workspacePendingSaveRecovery(recovery)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func workspaceCreateDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        workspaceName: String,
        documentBytes: Data,
        expectedCatalogRevision: UInt64,
        operationID: UUID,
        fingerprint: String?
    ) throws -> CoreWorkspaceCommandResultV1 {
        do {
            let response = try runtime.workspaceCreateDirectV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                storageDirectory: storageDirectory,
                workspaceId: workspaceID.uuidString.lowercased(),
                workspaceName: workspaceName,
                documentBytes: documentBytes,
                expectedCatalogRevision: expectedCatalogRevision,
                operationId: operationID.uuidString.lowercased(),
                fingerprint: fingerprint
            ))
            if let errorKind = response.errorKind {
                guard response.result == nil else {
                    throw CoreTransportError.unexpected("workspace create direct response contains result and error")
                }
                throw try Self.workspaceWorkingJournalValidationError(errorKind, futureSchemaVersion: nil)
            }
            guard let result = response.result else {
                throw CoreTransportError.unexpected("workspace create direct response missing result and error")
            }
            return try Self.workspaceCommandResult(result)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func workspaceSaveDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        documentBytes: Data,
        expectedWorkingRevision: UInt64,
        expectedCatalogRevision: UInt64,
        operationID: UUID,
        fingerprint: String?
    ) throws -> CoreWorkspaceCommandResultV1 {
        do {
            let response = try runtime.workspaceSaveDirectV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                storageDirectory: storageDirectory,
                workspaceId: workspaceID.uuidString.lowercased(),
                documentBytes: documentBytes,
                expectedWorkingRevision: expectedWorkingRevision,
                expectedCatalogRevision: expectedCatalogRevision,
                operationId: operationID.uuidString.lowercased(),
                fingerprint: fingerprint
            ))
            if let errorKind = response.errorKind {
                guard response.result == nil else {
                    throw CoreTransportError.unexpected("workspace save direct response contains result and error")
                }
                throw try Self.workspaceWorkingJournalValidationError(errorKind, futureSchemaVersion: nil)
            }
            guard let result = response.result else {
                throw CoreTransportError.unexpected("workspace save direct response missing result and error")
            }
            return try Self.workspaceCommandResult(result)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func workspaceDeleteDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        expectedCatalogRevision: UInt64,
        operationID: UUID
    ) throws -> CoreWorkspaceCommandResultV1 {
        do {
            let response = try runtime.workspaceDeleteDirectV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                storageDirectory: storageDirectory,
                workspaceId: workspaceID.uuidString.lowercased(),
                expectedCatalogRevision: expectedCatalogRevision,
                operationId: operationID.uuidString.lowercased()
            ))
            if let errorKind = response.errorKind {
                guard response.result == nil else {
                    throw CoreTransportError.unexpected("workspace delete direct response contains result and error")
                }
                throw try Self.workspaceWorkingJournalValidationError(errorKind, futureSchemaVersion: nil)
            }
            guard let result = response.result else {
                throw CoreTransportError.unexpected("workspace delete direct response missing result and error")
            }
            return try Self.workspaceCommandResult(result)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func workspaceMutateWorkingDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        candidateDocumentBytes: Data,
        expectedWorkingRevision: UInt64,
        operationID: UUID
    ) throws -> CoreWorkspaceCommandResultV1 {
        do {
            let response = try runtime.workspaceMutateWorkingDirectV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                storageDirectory: storageDirectory,
                workspaceId: workspaceID.uuidString.lowercased(),
                candidateDocumentBytes: candidateDocumentBytes,
                expectedWorkingRevision: expectedWorkingRevision,
                operationId: operationID.uuidString.lowercased()
            ))
            if let errorKind = response.errorKind {
                guard response.result == nil else {
                    throw CoreTransportError.unexpected("workspace mutate working direct response contains result and error")
                }
                throw try Self.workspaceWorkingJournalValidationError(errorKind, futureSchemaVersion: nil)
            }
            guard let result = response.result else {
                throw CoreTransportError.unexpected("workspace mutate working direct response missing result and error")
            }
            return try Self.workspaceCommandResult(result)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func workspaceIsQuarantinedV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID
    ) throws -> (isQuarantined: Bool, reason: String?) {
        do {
            let response = try runtime.workspaceIsQuarantinedV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                storageDirectory: storageDirectory,
                workspaceId: workspaceID.uuidString.lowercased()
            ))
            if let errorKind = response.errorKind {
                throw try Self.workspaceWorkingJournalValidationError(errorKind, futureSchemaVersion: nil)
            }
            return (response.isQuarantined, response.reason)
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func workspaceQuarantinedWorkspacesV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String
    ) throws -> [(workspaceID: UUID, reason: String)] {
        do {
            let response = try runtime.workspaceQuarantinedWorkspacesV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                storageDirectory: storageDirectory
            ))
            if let errorKind = response.errorKind {
                throw try Self.workspaceWorkingJournalValidationError(errorKind, futureSchemaVersion: nil)
            }
            return response.entries.compactMap { entry in
                guard let id = UUID(uuidString: entry.workspaceId) else { return nil }
                return (id, entry.reason)
            }
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    private static func workspacePendingSaveRecovery(
        _ value: AgentryUniFFIRaw.CoreWorkspacePendingSaveRecoveryV1
    ) throws -> CoreWorkspacePendingSaveRecoveryV1 {
        switch value {
        case let .noPending(journal):
            return .noPending(try workspaceWorkingJournalValidation(journal))
        case let .pendingNotCommitted(journal):
            return .pendingNotCommitted(try workspaceWorkingJournalValidation(journal))
        case let .committed(cleanJournal, documentDigest):
            guard isSHA256(documentDigest) else {
                throw CoreTransportError.unexpected("workspace pending save digest is invalid")
            }
            return .committed(
                cleanJournal: try workspaceWorkingJournalValidation(cleanJournal),
                documentDigest: documentDigest
            )
        }
    }

    private static func rawWorkspaceCommandIdentityRequest(
        identity: CoreRuntimeIdentity,
        request: CoreWorkspaceCommandIdentityRequestV1
    ) -> AgentryUniFFIRaw.CoreWorkspaceCommandIdentityRequestV1 {
        let origin: AgentryUniFFIRaw.CoreWorkspaceCommandOriginV1 = switch request.origin {
        case let .appPresentation(windowID): .appPresentation(windowId: windowID)
        case let .appMCP(connectionID): .appMcp(connectionId: connectionID?.uuidString)
        case .standalone: .standalone
        case .externalReload: .externalReload
        }
        let commandKind: AgentryUniFFIRaw.CoreWorkspaceCommandKindV1 = switch request.commandKind {
        case .create: .create
        case .replace: .replace
        case .save: .save
        case .delete: .delete
        case .resolveExternalConflict: .resolveExternalConflict
        }
        let protectedAgentIdentities = request.protectedAgentIdentities.map { protected in
            let location: AgentryUniFFIRaw.CoreWorkspaceTabLocationV1 = switch protected.location {
            case .composed: .composed
            case .stashed: .stashed
            }
            return AgentryUniFFIRaw.CoreWorkspaceProtectedAgentIdentityV1(
                tabId: protected.tabID.uuidString,
                location: location,
                activeAgentSessionId: protected.activeAgentSessionID?.uuidString,
                isPinned: protected.isPinned
            )
        }
        return .init(
            runtimeIdentity: rawIdentity(identity),
            contractVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
            operationId: request.operationID.uuidString,
            expectedCatalogRevision: request.expectedCatalogRevision,
            expectedWorkspaceRevision: request.expectedWorkspaceRevision,
            expectedContextRevision: request.expectedContextRevision,
            origin: origin,
            commandKind: commandKind,
            workspaceId: request.workspaceID.uuidString,
            fileUrl: request.fileURL?.absoluteString,
            contentDigest: request.contentDigest,
            acceptExternal: request.acceptExternal,
            protectedAgentIdentities: protectedAgentIdentities
        )
    }

    private static func workspaceCommandIdentity(
        _ value: AgentryUniFFIRaw.CoreWorkspaceCommandIdentityV1,
        request: CoreWorkspaceCommandIdentityRequestV1
    ) throws -> CoreWorkspaceCommandIdentityV1 {
        guard let workspaceID = UUID(uuidString: value.workspaceId),
              workspaceID == request.workspaceID,
              isSHA256(value.fingerprint)
        else {
            throw CoreTransportError.unexpected("workspace command identity receipt is invalid")
        }
        let commandKind: CoreWorkspaceCommandKindV1 = switch value.commandKind {
        case .create: .create
        case .replace: .replace
        case .save: .save
        case .delete: .delete
        case .resolveExternalConflict: .resolveExternalConflict
        }
        guard commandKind == request.commandKind else {
            throw CoreTransportError.unexpected(
                "workspace command identity kind does not match request"
            )
        }
        return CoreWorkspaceCommandIdentityV1(
            workspaceID: workspaceID,
            commandKind: commandKind,
            fingerprint: value.fingerprint
        )
    }

    private static func rawWorkspaceRecoveryArtifactEvidence(
        _ value: CoreWorkspaceRecoveryArtifactEvidenceV1
    ) -> AgentryUniFFIRaw.CoreWorkspaceRecoveryArtifactEvidenceV1 {
        switch value {
        case .absent:
            .absent
        case let .present(bytes):
            .present(bytes: bytes)
        case let .unavailable(reason):
            .unavailable(reason: reason)
        }
    }

    private static func rawWorkspaceSemanticFullRecovery(
        _ value: CoreWorkspaceSemanticFullRecoveryV1
    ) -> AgentryUniFFIRaw.CoreWorkspaceSemanticFullRecoveryV1 {
        .init(
            catalogBytes: value.catalogBytes,
            workspaces: value.workspaces.map {
                .init(
                    workspaceId: $0.workspaceID.uuidString,
                    journal: rawWorkspaceRecoveryArtifactEvidence($0.journal),
                    savedDocument: rawWorkspaceRecoveryArtifactEvidence($0.savedDocument),
                    savedRevision: rawWorkspaceRecoveryArtifactEvidence($0.savedRevision)
                )
            },
            deletions: value.deletions.map {
                .init(
                    workspaceId: $0.workspaceID.uuidString,
                    sidecar: rawWorkspaceRecoveryArtifactEvidence($0.sidecar)
                )
            }
        )
    }

    private static func rawWorkspaceSemanticTargetRecovery(
        _ value: CoreWorkspaceSemanticTargetRecoveryV1
    ) -> AgentryUniFFIRaw.CoreWorkspaceSemanticTargetRecoveryV1 {
        .init(
            catalogBytes: value.catalogBytes,
            workspaceId: value.workspaceID.uuidString,
            journal: rawWorkspaceRecoveryArtifactEvidence(value.journal),
            savedDocument: rawWorkspaceRecoveryArtifactEvidence(value.savedDocument),
            savedRevision: rawWorkspaceRecoveryArtifactEvidence(value.savedRevision),
            deletionSidecar: rawWorkspaceRecoveryArtifactEvidence(value.deletionSidecar)
        )
    }

    private static func rawWorkspaceRecordedOperation(
        _ value: CoreWorkspaceRecordedOperationV1
    ) -> AgentryUniFFIRaw.CoreWorkspaceRecordedOperationV1 {
        .init(
            operationId: value.operationID.uuidString,
            fingerprint: value.fingerprint,
            recordedAt: value.recordedAt,
            disposition: value.disposition,
            before: value.before.map(rawWorkspaceRevisionState),
            after: value.after.map(rawWorkspaceRevisionState),
            catalogRevision: value.catalogRevision,
            resultingDigest: value.resultingDigest,
            errorCode: value.errorCode,
            diagnostic: value.diagnostic
        )
    }

    private static func rawWorkspaceRevisionState(
        _ value: CoreWorkspaceProjectionRevisionState
    ) -> AgentryUniFFIRaw.CoreWorkspaceProjectionRevisionStateV1 {
        .init(
            workingRevision: value.workingRevision,
            savedRevision: value.savedRevision,
            dirtyRevision: value.dirtyRevision
        )
    }

    private static func workspaceCommandAdmissionAcquisition(
        _ response: AgentryUniFFIRaw.CoreWorkspaceCommandAdmissionAcquireResponseV1,
        request: CoreWorkspaceCommandIdentityRequestV1,
        runtimeIdentity: CoreRuntimeIdentity
    ) throws -> CoreWorkspaceCommandAdmissionAcquisitionV1 {
        if let errorKind = response.errorKind {
            guard response.kind == nil,
                  response.identity == nil,
                  response.claim == nil,
                  response.scope == nil,
                  response.operation == nil,
                  response.generation == nil
            else {
                throw CoreTransportError.unexpected(
                    "workspace command acquisition contains success and error"
                )
            }
            throw try workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let kind = response.kind,
              let rawIdentity = response.identity
        else {
            throw CoreTransportError.unexpected("workspace command acquisition is invalid")
        }
        let identity = try workspaceCommandIdentity(rawIdentity, request: request)
        switch kind {
        case .claimed:
            guard let rawClaim = response.claim,
                  let generation = response.generation,
                  generation > 0,
                  UUID(uuidString: rawClaim.workspaceId()) == identity.workspaceID,
                  UUID(uuidString: rawClaim.operationId()) == request.operationID,
                  rawClaim.fingerprint() == identity.fingerprint,
                  rawClaim.generation() == generation,
                  response.scope == nil,
                  response.operation == nil
            else {
                throw CoreTransportError.unexpected("workspace command claim receipt is invalid")
            }
            let claim = CoreWorkspaceCommandExecutionClaimV1(
                rawClaim: rawClaim,
                semanticPreflight: { request, candidateDocumentBytes, externalDocumentBytes in
                    do {
                        return try Self.workspaceSemanticPreflightResponse(
                            rawClaim.semanticPreflight(
                                request: Self.rawWorkspaceCommandIdentityRequest(
                                    identity: runtimeIdentity,
                                    request: request
                                ),
                                candidateDocumentBytes: candidateDocumentBytes,
                                externalDocumentBytes: externalDocumentBytes
                            ),
                            request: request
                        )
                    } catch let error as CoreWorkspaceWorkingJournalValidationError {
                        throw error
                    } catch {
                        throw workspaceCommandLifecycleError(error)
                    }
                },
                checkpoint: {
                    do {
                        return switch try rawClaim.checkpoint() {
                        case .continueExecution: .continueExecution
                        case .cancelled: .cancelled
                        case .deadlineExceeded: .deadlineExceeded
                        case .shutdownRequested: .shutdownRequested
                        }
                    } catch {
                        throw workspaceCommandLifecycleError(error)
                    }
                },
                finalizeTransient: { operation in
                    do {
                        let receipt = try rawClaim.finalizeTransient(
                            operation: rawWorkspaceRecordedOperation(operation)
                        )
                        if let errorKind = receipt.errorKind {
                            guard receipt.operation == nil else {
                                throw CoreTransportError.unexpected(
                                    "workspace command transient finalization contains success and error"
                                )
                            }
                            throw try workspaceWorkingJournalValidationError(
                                errorKind,
                                futureSchemaVersion: receipt.futureSchemaVersion
                            )
                        }
                        guard receipt.futureSchemaVersion == nil,
                              let rawOperation = receipt.operation
                        else {
                            throw CoreTransportError.unexpected(
                                "workspace command transient finalization receipt is invalid"
                            )
                        }
                        let finalized = try workspaceRecordedOperation(rawOperation)
                        guard finalized == operation else {
                            throw CoreTransportError.unexpected(
                                "workspace command transient finalization changed the operation"
                            )
                        }
                        return finalized
                    } catch let error as CoreWorkspaceWorkingJournalValidationError {
                        throw error
                    } catch {
                        throw workspaceCommandLifecycleError(error)
                    }
                },
                abandon: {
                    do {
                        return try rawClaim.abandon()
                    } catch {
                        throw map(error)
                    }
                },
                close: { rawClaim.close() }
            )
            return .claimed(identity: identity, claim: claim, generation: generation)
        case .pending:
            guard response.claim == nil,
                  response.scope == nil,
                  response.operation == nil,
                  let generation = response.generation,
                  generation > 0
            else {
                throw CoreTransportError.unexpected("workspace command pending receipt is invalid")
            }
            return .pending(identity: identity, generation: generation)
        case .collision:
            guard response.claim == nil,
                  response.operation == nil,
                  response.generation == nil
            else {
                throw CoreTransportError.unexpected("workspace command collision receipt is invalid")
            }
            return .collision(
                identity: identity,
                scope: response.scope.map(workspaceCommandAdmissionScope)
            )
        case .replay:
            guard response.claim == nil,
                  response.generation == nil,
                  let scope = response.scope,
                  let rawOperation = response.operation
            else {
                throw CoreTransportError.unexpected("workspace command replay receipt is invalid")
            }
            let operation = try workspaceRecordedOperation(rawOperation)
            guard operation.operationID == request.operationID,
                  operation.fingerprint == identity.fingerprint
            else {
                throw CoreTransportError.unexpected(
                    "workspace command replay does not match request identity"
                )
            }
            return .replay(
                identity: identity,
                scope: workspaceCommandAdmissionScope(scope),
                operation: operation
            )
        }
    }

    private static func workspaceExternalObservationPlan(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceExternalObservationRecoveryPlanV1,
        request: CoreWorkspaceExternalObservationRecoveryRequestV1
    ) throws -> CoreWorkspaceExternalObservationRecoveryPlanV1 {
        guard let workspaceID = UUID(uuidString: raw.workspaceId),
              workspaceID == request.workspaceID,
              let expectedFileURL = URL(string: raw.expectedFileUrl),
              expectedFileURL.standardizedFileURL == request.expectedFileURL.standardizedFileURL,
              raw.catalogRevision == request.expectedCatalogRevision,
              raw.workspaceRevision == request.expectedWorkspaceRevision,
              (raw.semanticGeneration > 0 || raw.publicationSequence == 0),
              isSHA256(raw.semanticProjectionDigest),
              raw.currentDocumentDigest.caseInsensitiveCompare(request.currentDocumentDigest) == .orderedSame,
              raw.savedDigest.caseInsensitiveCompare(request.savedDigest) == .orderedSame,
              isSHA256(raw.currentDocumentDigest),
              isSHA256(raw.savedDigest),
              isSHA256(raw.externalDocumentDigest),
              raw.updatedAt.isFinite,
              abs(raw.updatedAt - request.updatedAt.timeIntervalSinceReferenceDate) < 0.000_001
        else {
            throw CoreTransportError.unexpected("workspace external observation plan identity is invalid")
        }
        if let rawRevisionSidecarID = raw.revisionSidecarId {
            guard let revisionSidecarID = UUID(uuidString: rawRevisionSidecarID) else {
                throw CoreTransportError.unexpected("workspace external observation sidecar identity is invalid")
            }
            guard raw.transition == .externalReload else {
                throw CoreTransportError.unexpected("workspace external observation sidecar identity is unexpected")
            }
            _ = revisionSidecarID
        } else if raw.transition == .externalReload {
            throw CoreTransportError.unexpected("workspace external observation sidecar identity is missing")
        }
        func canonicalUUIDs(_ values: [String]) throws -> [UUID] {
            let ids = try values.map { value in
                guard let id = UUID(uuidString: value) else {
                    throw CoreTransportError.unexpected("workspace external observation context identity is invalid")
                }
                return id
            }
            let canonical = ids.map { $0.uuidString.lowercased() }
            guard canonical == canonical.sorted(), Set(canonical).count == canonical.count else {
                throw CoreTransportError.unexpected("workspace external observation context identities are not canonical")
            }
            return ids
        }
        let changed = try canonicalUUIDs(raw.changedContextIds)
        let added = try canonicalUUIDs(raw.addedContextIds)
        let removed = try canonicalUUIDs(raw.removedContextIds)
        let disposition: CoreWorkspaceExternalObservationDispositionV1 = switch raw.disposition {
        case .noChange: .noChange
        case .cleanReload: .cleanReload
        case .dirtyConflict: .dirtyConflict
        }
        let candidate: CoreWorkspaceExternalObservationCandidateV1 = switch raw.candidate {
        case .none: .none
        case .externalDocument: .externalDocument
        case .existingWorkingDocument: .existingWorkingDocument
        }
        let transition: CoreWorkspaceExternalObservationTransitionV1 = switch raw.transition {
        case .none: .none
        case .externalReload: .externalReload
        case .conflictRebase: .conflictRebase
        }
        guard (disposition, candidate, transition) == (.noChange, .none, .none)
            || (disposition, candidate, transition) == (.cleanReload, .externalDocument, .externalReload)
            || (disposition, candidate, transition) == (.dirtyConflict, .existingWorkingDocument, .conflictRebase)
        else {
            throw CoreTransportError.unexpected("workspace external observation plan transition is invalid")
        }
        let changedSet = Set(changed)
        guard Set(added).isSubset(of: changedSet),
              Set(removed).isSubset(of: changedSet),
              Set(added).isDisjoint(with: Set(removed))
        else {
            throw CoreTransportError.unexpected("workspace external observation context delta is invalid")
        }
        return CoreWorkspaceExternalObservationRecoveryPlanV1(
            workspaceID: workspaceID,
            expectedFileURL: expectedFileURL,
            catalogRevision: raw.catalogRevision,
            workspaceRevision: raw.workspaceRevision,
            aggregateGeneration: raw.aggregateGeneration,
            semanticGeneration: raw.semanticGeneration,
            publicationSequence: raw.publicationSequence,
            semanticProjectionDigest: raw.semanticProjectionDigest,
            currentDocumentDigest: raw.currentDocumentDigest,
            savedDigest: raw.savedDigest,
            externalDocumentDigest: raw.externalDocumentDigest,
            changedContextIDs: changed,
            addedContextIDs: added,
            removedContextIDs: removed,
            disposition: disposition,
            candidate: candidate,
            transition: transition,
            updatedAt: Date(timeIntervalSinceReferenceDate: raw.updatedAt),
            revisionSidecarID: raw.revisionSidecarId.flatMap(UUID.init(uuidString:)),
            diagnostic: raw.diagnostic
        )
    }

    private static func workspaceSemanticPreflightResponse(
        _ response: AgentryUniFFIRaw.CoreWorkspaceSemanticPreflightResponseV1,
        request: CoreWorkspaceCommandIdentityRequestV1
    ) throws -> CoreWorkspaceSemanticPreflightV1 {
        if let errorKind = response.errorKind {
            guard response.preflight == nil else {
                throw CoreTransportError.unexpected(
                    "workspace semantic preflight contains success and error"
                )
            }
            throw try workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let preflight = response.preflight,
              let workspaceID = UUID(uuidString: preflight.workspaceId),
              workspaceID == request.workspaceID,
              isSHA256(preflight.contentDigest ?? "") || preflight.contentDigest == nil,
              preflight.revisions.map(workspaceRevisionStateIsValid) ?? true
        else {
            throw CoreTransportError.unexpected("workspace semantic preflight is invalid")
        }
        func canonicalUUIDs(_ values: [String]) throws -> [UUID] {
            let ids = try values.map { value in
                guard let id = UUID(uuidString: value) else {
                    throw CoreTransportError.unexpected(
                        "workspace semantic preflight context identity is invalid"
                    )
                }
                return id
            }
            let canonical = ids.map { $0.uuidString.lowercased() }
            guard canonical == canonical.sorted(), Set(canonical).count == canonical.count else {
                throw CoreTransportError.unexpected(
                    "workspace semantic preflight context identities are not canonical"
                )
            }
            return ids
        }
        let changedContextIDs = try canonicalUUIDs(preflight.changedContextIds)
        let addedContextIDs = try canonicalUUIDs(preflight.addedContextIds)
        let removedContextIDs = try canonicalUUIDs(preflight.removedContextIds)
        let protectedContextIDs = try canonicalUUIDs(preflight.protectedContextIds)
        let externalDocumentDigest = preflight.externalDocumentDigest
        let externalDocumentDigestIsValid: Bool = if let externalDocumentDigest {
            request.commandKind == .resolveExternalConflict && isSHA256(externalDocumentDigest)
        } else {
            // A ResolveExternalConflict preflight may terminate before reading external bytes
            // when the workspace is missing, has no conflict, or its revision fence is stale.
            // A proceeding resolution, however, must carry the exact external-byte digest.
            request.commandKind != .resolveExternalConflict
                || preflight.disposition != .proceed
        }
        guard externalDocumentDigestIsValid,
              Set(protectedContextIDs).count == protectedContextIDs.count,
              protectedContextIDs == protectedContextIDs.sorted(by: { $0.uuidString.lowercased() < $1.uuidString.lowercased() })
        else {
            throw CoreTransportError.unexpected(
                "workspace semantic preflight protected context identities are invalid"
            )
        }
        let changedSet = Set(changedContextIDs)
        guard Set(addedContextIDs).isSubset(of: changedSet),
              Set(removedContextIDs).isSubset(of: changedSet),
              Set(addedContextIDs).isDisjoint(with: Set(removedContextIDs))
        else {
            throw CoreTransportError.unexpected(
                "workspace semantic preflight context delta is inconsistent"
            )
        }
        let commandKind: CoreWorkspaceCommandKindV1 = switch preflight.commandKind {
        case .create: .create
        case .replace: .replace
        case .save: .save
        case .delete: .delete
        case .resolveExternalConflict: .resolveExternalConflict
        }
        guard commandKind == request.commandKind else {
            throw CoreTransportError.unexpected(
                "workspace semantic preflight kind does not match request"
            )
        }
        let disposition: CoreWorkspaceSemanticPreflightDispositionV1 = switch preflight.disposition {
        case .proceed: .proceed
        case .unchanged: .unchanged
        case .conflict: .conflict
        case .missing: .missing
        case .unavailable: .unavailable
        }
        return CoreWorkspaceSemanticPreflightV1(
            workspaceID: workspaceID,
            commandKind: commandKind,
            disposition: disposition,
            catalogRevision: preflight.catalogRevision,
            revisions: preflight.revisions.map(workspaceRevisionState),
            health: try preflight.health.map(workspaceSemanticRecoveryHealth),
            contentDigest: preflight.contentDigest,
            changedContextIDs: changedContextIDs,
            addedContextIDs: addedContextIDs,
            removedContextIDs: removedContextIDs,
            externalDocumentDigest: externalDocumentDigest,
            protectedContextIDs: protectedContextIDs,
            diagnostic: preflight.diagnostic
        )
    }

    private static func workspaceSemanticRecoveryPreviewResponse(
        _ response: AgentryUniFFIRaw.CoreWorkspaceSemanticRecoveryPreviewResponseV1
    ) throws -> CoreWorkspaceSemanticRecoveryPreviewV1 {
        if let errorKind = response.errorKind {
            guard response.preview == nil else {
                throw CoreTransportError.unexpected(
                    "workspace semantic recovery preview contains success and error"
                )
            }
            throw try workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let preview = response.preview,
              isSHA256(preview.catalogDigest),
              isSHA256(preview.projectionDigest)
        else {
            throw CoreTransportError.unexpected("workspace semantic recovery preview is invalid")
        }
        let targetWorkspaceID: UUID?
        if let rawTarget = preview.targetWorkspaceId {
            guard let parsed = UUID(uuidString: rawTarget) else {
                throw CoreTransportError.unexpected(
                    "workspace semantic recovery target is invalid"
                )
            }
            targetWorkspaceID = parsed
        } else {
            targetWorkspaceID = nil
        }
        let projection = try workspaceSemanticRecoveryProjection(preview.projection)
        switch (targetWorkspaceID, projection) {
        case (nil, .full), (.some, .target):
            break
        default:
            throw CoreTransportError.unexpected(
                "workspace semantic recovery projection does not match target"
            )
        }
        let rewrites = try preview.journalRewrites.map { rewrite in
            guard let workspaceID = UUID(uuidString: rewrite.workspaceId),
                  isSHA256(rewrite.expectedArtifactDigest),
                  isSHA256(rewrite.replacementCanonicalDigest),
                  sha256(rewrite.replacementCanonicalBytes) == rewrite.replacementCanonicalDigest
            else {
                throw CoreTransportError.unexpected(
                    "workspace semantic recovery journal rewrite is invalid"
                )
            }
            return CoreWorkspaceSemanticJournalRewriteV1(
                workspaceID: workspaceID,
                expectedArtifactDigest: rewrite.expectedArtifactDigest,
                replacementCanonicalBytes: rewrite.replacementCanonicalBytes,
                replacementCanonicalDigest: rewrite.replacementCanonicalDigest
            )
        }
        guard Set(rewrites.map(\.workspaceID)).count == rewrites.count else {
            throw CoreTransportError.unexpected(
                "workspace semantic recovery contains duplicate journal rewrites"
            )
        }
        return CoreWorkspaceSemanticRecoveryPreviewV1(
            catalogRevision: preview.catalogRevision,
            catalogDigest: preview.catalogDigest,
            targetWorkspaceID: targetWorkspaceID,
            globalHealth: try workspaceSemanticRecoveryHealth(preview.globalHealth),
            admissionDisposition: workspaceSemanticRecoveryAdmissionDisposition(
                preview.admissionDisposition
            ),
            projection: projection,
            journalRewrites: rewrites,
            projectionDigest: preview.projectionDigest
        )
    }

    private func workspaceSemanticRecoveryCommitResponse(
        _ response: AgentryUniFFIRaw.CoreWorkspaceSemanticRecoveryCommitResponseV1,
        identity: CoreRuntimeIdentity
    ) throws -> CoreWorkspaceSemanticRecoveryCommitV1 {
        if let errorKind = response.errorKind {
            guard response.admission == nil,
                  response.admissionReceipt == nil,
                  response.catalogRevision == nil,
                  response.catalogDigest == nil,
                  response.targetWorkspaceId == nil,
                  response.admissionDisposition == nil,
                  response.projectionDigest == nil
            else {
                throw CoreTransportError.unexpected(
                    "workspace semantic recovery commit contains success and error"
                )
            }
            throw try Self.workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let catalogRevision = response.catalogRevision,
              let catalogDigest = response.catalogDigest,
              let rawDisposition = response.admissionDisposition,
              let projectionDigest = response.projectionDigest,
              Self.isSHA256(catalogDigest),
              Self.isSHA256(projectionDigest)
        else {
            throw CoreTransportError.unexpected("workspace semantic recovery commit is invalid")
        }
        let targetWorkspaceID: UUID?
        if let rawTarget = response.targetWorkspaceId {
            guard let parsed = UUID(uuidString: rawTarget) else {
                throw CoreTransportError.unexpected(
                    "workspace semantic recovery commit target is invalid"
                )
            }
            targetWorkspaceID = parsed
        } else {
            targetWorkspaceID = nil
        }
        let admissionReceipt = try response.admissionReceipt.map {
            try Self.workspaceCommandAdmissionRecoveryReceipt(
                $0,
                expectedTarget: targetWorkspaceID
            )
        }
        let disposition = Self.workspaceSemanticRecoveryAdmissionDisposition(rawDisposition)
        switch disposition {
        case .installed, .preserved:
            guard admissionReceipt != nil else {
                throw CoreTransportError.unexpected(
                    "authoritative semantic recovery omitted admission receipt"
                )
            }
        case .quarantined:
            guard response.admission == nil, admissionReceipt == nil else {
                throw CoreTransportError.unexpected(
                    "quarantined semantic recovery returned admission authority"
                )
            }
        }
        return CoreWorkspaceSemanticRecoveryCommitV1(
            admission: response.admission.map {
                preparedWorkspaceCommandAdmission(identity: identity, rawAdmission: $0)
            },
            admissionReceipt: admissionReceipt,
            catalogRevision: catalogRevision,
            catalogDigest: catalogDigest,
            targetWorkspaceID: targetWorkspaceID,
            admissionDisposition: disposition,
            projectionDigest: projectionDigest
        )
    }

    private static func workspaceSemanticRecoveryProjection(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceSemanticRecoveryProjectionV1
    ) throws -> CoreWorkspaceSemanticRecoveryProjectionV1 {
        switch raw {
        case let .full(rows):
            let converted = try rows.map(workspaceSemanticRecoveryRow)
            let workspaceIDs = converted.map { row in
                switch row {
                case let .active(active): active.workspaceID
                case let .unavailable(unavailable): unavailable.workspaceID
                case let .deleted(workspaceID, _): workspaceID
                }
            }
            guard Set(workspaceIDs).count == workspaceIDs.count else {
                throw CoreTransportError.unexpected(
                    "workspace semantic recovery contains duplicate rows"
                )
            }
            return .full(rows: converted)
        case let .target(directive):
            return .target(directive: try workspaceSemanticTargetDirective(directive))
        }
    }

    private static func workspaceSemanticRecoveryRow(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceSemanticRecoveryRowV1
    ) throws -> CoreWorkspaceSemanticRecoveryRowV1 {
        switch raw {
        case let .active(row):
            .active(try workspaceSemanticActiveRecovery(row))
        case let .unavailable(row):
            .unavailable(try workspaceSemanticUnavailableRecovery(row))
        case let .deleted(workspaceId, fileUrl):
            .deleted(
                workspaceID: try workspaceSemanticRecoveryWorkspaceID(workspaceId),
                fileURL: try workspaceSemanticRecoveryFileURL(fileUrl)
            )
        }
    }

    private static func workspaceSemanticTargetDirective(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceSemanticTargetDirectiveV1
    ) throws -> CoreWorkspaceSemanticTargetDirectiveV1 {
        switch raw {
        case let .upsert(row):
            .upsert(try workspaceSemanticActiveRecovery(row))
        case let .unavailable(row):
            .unavailable(try workspaceSemanticUnavailableRecovery(row))
        case let .delete(workspaceId, fileUrl):
            .delete(
                workspaceID: try workspaceSemanticRecoveryWorkspaceID(workspaceId),
                fileURL: try workspaceSemanticRecoveryFileURL(fileUrl)
            )
        case .noChange:
            .noChange
        }
    }

    private static func workspaceSemanticActiveRecovery(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceSemanticActiveRecoveryV1
    ) throws -> CoreWorkspaceSemanticActiveRecoveryV1 {
        let workspaceID = try workspaceSemanticRecoveryWorkspaceID(raw.workspaceId)
        let fileURL = try workspaceSemanticRecoveryFileURL(raw.fileUrl)
        guard isSHA256(raw.documentDigest),
              raw.documentDigest == sha256(raw.documentBytes),
              isSHA256(raw.savedDigest),
              workspaceRevisionStateIsValid(raw.revisions),
              raw.contextRevisions.count <= 4_096,
              raw.contextTombstones.count <= 4_096,
              raw.operations.count <= 4_096
        else {
            throw CoreTransportError.unexpected("workspace semantic active row is invalid")
        }
        let contextRevisions = try raw.contextRevisions.map { context in
            guard let contextID = UUID(uuidString: context.contextId),
                  workspaceRevisionStateIsValid(context.revisions)
            else {
                throw CoreTransportError.unexpected(
                    "workspace semantic context revision is invalid"
                )
            }
            return CoreWorkspaceSemanticContextRecoveryV1(
                contextID: contextID,
                revisions: workspaceRevisionState(context.revisions)
            )
        }
        guard Set(contextRevisions.map(\.contextID)).count == contextRevisions.count else {
            throw CoreTransportError.unexpected(
                "workspace semantic context revisions contain duplicates"
            )
        }
        var contextTombstones: [UUID: UInt64] = [:]
        for tombstone in raw.contextTombstones {
            guard let contextID = UUID(uuidString: tombstone.contextId),
                  contextTombstones.updateValue(tombstone.revision, forKey: contextID) == nil
            else {
                throw CoreTransportError.unexpected(
                    "workspace semantic context tombstones contain duplicates"
                )
            }
        }
        let operations = try raw.operations.map(workspaceRecordedOperation)
        guard Set(operations.map(\.operationID)).count == operations.count else {
            throw CoreTransportError.unexpected(
                "workspace semantic operations contain duplicates"
            )
        }
        return CoreWorkspaceSemanticActiveRecoveryV1(
            workspaceID: workspaceID,
            fileURL: fileURL,
            documentBytes: raw.documentBytes,
            documentDigest: raw.documentDigest,
            savedDigest: raw.savedDigest,
            revisions: workspaceRevisionState(raw.revisions),
            contextRevisions: contextRevisions,
            contextTombstones: contextTombstones,
            operations: operations,
            health: try workspaceSemanticRecoveryHealth(raw.health),
            externalDocumentBytes: raw.externalDocumentBytes
        )
    }

    private static func workspaceSemanticUnavailableRecovery(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceSemanticUnavailableRecoveryV1
    ) throws -> CoreWorkspaceSemanticUnavailableRecoveryV1 {
        guard !raw.reason.isEmpty else {
            throw CoreTransportError.unexpected("workspace semantic unavailable reason is empty")
        }
        return CoreWorkspaceSemanticUnavailableRecoveryV1(
            workspaceID: try workspaceSemanticRecoveryWorkspaceID(raw.workspaceId),
            fileURL: try workspaceSemanticRecoveryFileURL(raw.fileUrl),
            reason: raw.reason
        )
    }

    private static func workspaceSemanticRecoveryWorkspaceID(_ raw: String) throws -> UUID {
        guard let workspaceID = UUID(uuidString: raw) else {
            throw CoreTransportError.unexpected("workspace semantic recovery identity is invalid")
        }
        return workspaceID
    }

    private static func workspaceSemanticRecoveryFileURL(_ raw: String) throws -> URL {
        guard let fileURL = URL(string: raw), fileURL.isFileURL else {
            throw CoreTransportError.unexpected("workspace semantic recovery file URL is invalid")
        }
        return fileURL
    }

    private static func workspaceSemanticRecoveryHealth(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceProjectionHealthV1
    ) throws -> CoreWorkspaceProjectionHealth {
        let kind: CoreWorkspaceProjectionHealthKind = switch raw.kind {
        case .writable: .writable
        case .externalConflict: .externalConflict
        case .degradedReadOnly: .degradedReadOnly
        case .removed: .removed
        }
        switch kind {
        case .writable, .removed:
            guard raw.reason == nil else {
                throw CoreTransportError.unexpected("workspace semantic health reason is invalid")
            }
        case .externalConflict, .degradedReadOnly:
            guard let reason = raw.reason, !reason.isEmpty else {
                throw CoreTransportError.unexpected("workspace semantic health reason is missing")
            }
        }
        return CoreWorkspaceProjectionHealth(kind: kind, reason: raw.reason)
    }

    private static func workspaceSemanticRecoveryAdmissionDisposition(
        _ raw: AgentryUniFFIRaw.CoreWorkspaceSemanticRecoveryAdmissionDispositionV1
    ) -> CoreWorkspaceSemanticRecoveryAdmissionDispositionV1 {
        switch raw {
        case .installed: .installed
        case .preserved: .preserved
        case .quarantined: .quarantined
        }
    }

    private static func workspaceCommandAdmissionRecoveryReceipt(
        _ receipt: AgentryUniFFIRaw.CoreWorkspaceCommandAdmissionRecoveryReceiptV1,
        expectedTarget: UUID?
    ) throws -> CoreWorkspaceCommandAdmissionRecoveryReceiptV1 {
        let targetWorkspaceID: UUID?
        if let rawTarget = receipt.targetWorkspaceId {
            guard let parsed = UUID(uuidString: rawTarget) else {
                throw CoreTransportError.unexpected(
                    "workspace command admission recovery target is invalid"
                )
            }
            targetWorkspaceID = parsed
        } else {
            targetWorkspaceID = nil
        }
        guard targetWorkspaceID == expectedTarget,
              isSHA256(receipt.catalogDigest)
        else {
            throw CoreTransportError.unexpected(
                "workspace command admission recovery receipt does not match request"
            )
        }
        return try CoreWorkspaceCommandAdmissionRecoveryReceiptV1(
            catalogRevision: receipt.catalogRevision,
            catalogDigest: receipt.catalogDigest,
            targetWorkspaceID: targetWorkspaceID,
            diagnostics: workspaceCommandAdmissionDiagnostics(.init(
                diagnostics: receipt.diagnostics,
                errorKind: nil,
                futureSchemaVersion: nil
            ))
        )
    }

    private static func workspaceCommandAdmissionDiagnostics(
        _ response: AgentryUniFFIRaw.CoreWorkspaceCommandAdmissionMutationResponseV1
    ) throws -> CoreWorkspaceCommandAdmissionDiagnosticsV1 {
        if let errorKind = response.errorKind {
            guard response.diagnostics == nil else {
                throw CoreTransportError.unexpected(
                    "workspace command admission mutation contains success and error"
                )
            }
            throw try workspaceWorkingJournalValidationError(
                errorKind,
                futureSchemaVersion: response.futureSchemaVersion
            )
        }
        guard response.futureSchemaVersion == nil,
              let diagnostics = response.diagnostics
        else {
            throw CoreTransportError.unexpected(
                "workspace command admission diagnostics are invalid"
            )
        }
        let total = diagnostics.globalOperationCount.addingReportingOverflow(
            diagnostics.workspaceOperationCount
        )
        guard diagnostics.globalOperationCount <= 4_096,
              diagnostics.workspaceCount <= diagnostics.workspaceOperationCount,
              diagnostics.workspaceOperationCount <= 65_536,
              !total.overflow,
              total.partialValue <= 65_536
        else {
            throw CoreTransportError.unexpected(
                "workspace command admission diagnostics are invalid"
            )
        }
        return CoreWorkspaceCommandAdmissionDiagnosticsV1(
            globalOperationCount: diagnostics.globalOperationCount,
            workspaceCount: diagnostics.workspaceCount,
            workspaceOperationCount: diagnostics.workspaceOperationCount
        )
    }

    private static func workspaceCommandAdmissionScope(
        _ value: AgentryUniFFIRaw.CoreWorkspaceCommandAdmissionLookupScopeV1
    ) -> CoreWorkspaceCommandAdmissionLookupScopeV1 {
        switch value {
        case .workspace: .workspace
        case .global: .global
        }
    }

    private static func workspaceRecordedOperation(
        _ value: AgentryUniFFIRaw.CoreWorkspaceRecordedOperationV1
    ) throws -> CoreWorkspaceRecordedOperationV1 {
        let validDispositions = Set([
            "applied", "unchanged", "conflict", "readOnly", "invalid", "failed", "deduplicated",
        ])
        let validErrorCodes = Set([
            "state_conflict", "runtime_read_only_degraded", "workspace_external_conflict",
            "workspace_read_only_degraded", "protected_agent_identity_conflict",
            "operation_id_collision", "workspace_unavailable", "invalid_document",
            "persistence_failure", "lock_timed_out", "cancelled",
        ])
        guard let operationID = UUID(uuidString: value.operationId),
              isSHA256(value.fingerprint),
              value.recordedAt.isFinite,
              validDispositions.contains(value.disposition),
              value.resultingDigest.map(isSHA256) ?? true,
              value.errorCode.map(validErrorCodes.contains) ?? true,
              value.before.map(workspaceRevisionStateIsValid) ?? true,
              value.after.map(workspaceRevisionStateIsValid) ?? true
        else {
            throw CoreTransportError.unexpected(
                "workspace command admission operation receipt is invalid"
            )
        }
        return CoreWorkspaceRecordedOperationV1(
            operationID: operationID,
            fingerprint: value.fingerprint,
            recordedAt: value.recordedAt,
            disposition: value.disposition,
            before: value.before.map(workspaceRevisionState),
            after: value.after.map(workspaceRevisionState),
            catalogRevision: value.catalogRevision,
            resultingDigest: value.resultingDigest,
            errorCode: value.errorCode,
            diagnostic: value.diagnostic
        )
    }

    private static func workspaceRevisionState(
        _ value: AgentryUniFFIRaw.CoreWorkspaceProjectionRevisionStateV1
    ) -> CoreWorkspaceProjectionRevisionState {
        .init(
            workingRevision: value.workingRevision,
            savedRevision: value.savedRevision,
            dirtyRevision: value.dirtyRevision
        )
    }

    private static func workspaceRevisionStateIsValid(
        _ value: AgentryUniFFIRaw.CoreWorkspaceProjectionRevisionStateV1
    ) -> Bool {
        value.savedRevision <= value.workingRevision
            && (value.dirtyRevision == nil || value.dirtyRevision == value.workingRevision)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
            }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func workspaceWorkingJournalValidation(
        _ result: AgentryUniFFIRaw.CoreWorkspaceWorkingJournalValidationV1
    ) throws -> CoreWorkspaceWorkingJournalValidationV1 {
        let computedDigest = SHA256.hash(data: result.canonicalBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        guard let workspaceID = UUID(uuidString: result.workspaceId),
              result.journalVersion == CoreWorkspaceWorkingJournalValidationV1.contractVersion,
              result.contentDigest.count == 64,
              result.contentDigest == result.contentDigest.lowercased(),
              result.contentDigest.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              }),
              result.canonicalBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              result.contentDigest == computedDigest
        else {
            throw CoreTransportError.unexpected(
                "workspace working journal validation receipt is invalid"
            )
        }
        return CoreWorkspaceWorkingJournalValidationV1(
            workspaceID: workspaceID,
            journalVersion: result.journalVersion,
            contentDigest: result.contentDigest,
            canonicalBytes: result.canonicalBytes
        )
    }

    private static func workspaceWorkingJournalValidationError(
        _ kind: AgentryUniFFIRaw.CoreWorkspaceWorkingJournalValidationErrorKindV1,
        futureSchemaVersion: UInt16?
    ) throws -> CoreWorkspaceWorkingJournalValidationError {
        switch kind {
        case .inputTooLarge: .inputTooLarge
        case .outputTooLarge: .outputTooLarge
        case .malformed: .malformed
        case .futureSchema:
            if let futureSchemaVersion {
                .futureSchema(futureSchemaVersion)
            } else {
                throw CoreTransportError.unexpected(
                    "future workspace journal schema response has no version"
                )
            }
        case .invalidIdentity: .invalidIdentity
        case .duplicateCatalogIdentity: .duplicateCatalogIdentity
        case .invalidFileUrl: .invalidFileURL
        case .invalidRevisionState: .invalidRevisionState
        case .invalidDigest: .invalidDigest
        case .invalidWorkingDocument: .invalidWorkingDocument
        case .invalidContextTable: .invalidContextTable
        case .invalidOperationLedger: .invalidOperationLedger
        case .invalidPendingSave: .invalidPendingSave
        case .invalidTimestamp: .invalidTimestamp
        case .externalDocumentConflict: .externalDocumentConflict
        case .staleRecoverySnapshot: .staleRecoverySnapshot
        case .fullRecoveryRequired: .fullRecoveryRequired
        case .invalidTransaction: .invalidTransaction
        case .workspaceQuarantined: .workspaceQuarantined
        case .persistenceIoError: .persistenceIoError
        case .unsupportedCatalogSchemaVersion: .unsupportedCatalogSchemaVersion
        case .storageLeaseRequired: .storageLeaseRequired
        }
    }

    func searchScoreBatchV1(
        identity: CoreRuntimeIdentity,
        request: CoreSearchScoreBatchRequestV1
    ) throws -> [Int32] {
        let value: AgentryUniFFIRaw.CoreSearchScoreBatchResultV1
        do {
            value = try runtime.searchScoreBatchV1(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                contractVersion: CoreSearchScoreBatchRequestV1.contractVersion,
                candidates: request.candidates.map { candidate in
                    .init(
                        name: Data(candidate.name.utf8),
                        path: Data(candidate.path.utf8),
                        nameLower: Data(candidate.nameLower.utf8),
                        pathLower: Data(candidate.pathLower.utf8)
                    )
                },
                query: .init(
                    raw: Data(request.query.raw.utf8),
                    lowered: Data(request.query.lowered.utf8),
                    hasSlash: request.query.hasSlash,
                    isWildcard: request.query.isWildcard
                ),
                fuzzyThreshold: request.fuzzyThreshold
            ))
        } catch {
            throw Self.map(error)
        }
        return value.scores
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

    func inventoryOpenComposedSnapshot(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        roots: [AgentryUniFFIRaw.InventoryComposedRootDescriptorV1],
        accounting: AgentryUniFFIRaw.InventoryCompositionAccountingV1
    ) throws -> AgentryUniFFIRaw.InventoryComposedSnapshotHandleV1 {
        do {
            return try runtime.inventoryOpenComposedSnapshot(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: scopeID,
                roots: roots,
                accounting: accounting
            ))
        } catch {
            throw Self.map(error)
        }
    }

    func inventoryComposedSnapshotPage(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        handleID: UInt64,
        offset: UInt64,
        limit: UInt64
    ) throws -> AgentryUniFFIRaw.CompactInventoryPageV1 {
        do {
            return try runtime.inventoryComposedSnapshotPage(
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

    func inventoryCloseComposedSnapshot(scopeID: String, handleID: UInt64) throws {
        do {
            try runtime.inventoryCloseComposedSnapshot(scopeId: scopeID, handleId: handleID)
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

    func inventoryResolveRecordsScopeWide(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactRecordBlockV1 {
        do {
            return try runtime.inventoryResolveRecordsScopeWide(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                bytes: bytes
            )
        } catch {
            throw Self.map(error)
        }
    }

    func inventorySetFileManagedOnly(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        fileID: Data,
        managedOnly: Bool
    ) throws {
        do {
            try runtime.inventorySetFileManagedOnly(
                identity: Self.rawIdentity(identity), scopeId: scopeID, rootId: rootID, fileId: fileID, managedOnly: managedOnly
            )
        } catch {
            throw Self.map(error)
        }
    }

    func inventorySetFolderManagedOnly(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        folderID: Data,
        managedOnly: Bool
    ) throws {
        do {
            try runtime.inventorySetFolderManagedOnly(
                identity: Self.rawIdentity(identity), scopeId: scopeID, rootId: rootID, folderId: folderID, managedOnly: managedOnly
            )
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

    func inventoryOpenTreeProjectionShard(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.InventorySnapshotHandleV1 {
        do {
            return try runtime.inventoryOpenTreeProjectionShard(request: .init(
                runtimeIdentity: Self.rawIdentity(identity),
                scopeId: scopeID,
                rootId: rootID,
                bytes: bytes
            ))
        } catch {
            throw Self.map(error)
        }
    }

    // ---- P9: Rust-owned canonical MCP/tool catalog --------------------------------------------
    func mcpToolCatalogV1(identity: CoreRuntimeIdentity) throws -> AgentryUniFFIRaw.CoreMcpToolCatalogV1 {
        do {
            return try runtime.mcpToolCatalogV1(identity: Self.rawIdentity(identity))
        } catch {
            throw Self.map(error)
        }
    }

    func mcpToolOperationIdentityV1(
        identity: CoreRuntimeIdentity,
        toolName: String,
        input: AgentryUniFFIRaw.CoreMcpToolOperationInputV1
    ) throws -> AgentryUniFFIRaw.CoreMcpToolOperationIdentityV1 {
        do {
            return try runtime.mcpToolOperationIdentityV1(
                identity: Self.rawIdentity(identity),
                toolName: toolName,
                input: input
            )
        } catch {
            throw Self.map(error)
        }
    }

    // ---- P6-6: agent-claude-v1 ------------------------------------------------------------------

    func fileSystemWatcherOpenScope(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreFileSystemWatcherScopeConfigV1
    ) throws -> AgentryUniFFIRaw.CoreFileSystemWatcherScopeHandleV1 {
        do {
            return try runtime.fileSystemWatcherOpenScope(identity: Self.rawIdentity(identity), config: config)
        } catch { throw Self.map(error) }
    }

    func fileSystemWatcherStartAccepting(identity: CoreRuntimeIdentity, scopeID: String) throws {
        do {
            try runtime.fileSystemWatcherStartAccepting(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch { throw Self.map(error) }
    }

    func fileSystemWatcherIngest(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        entries: [AgentryUniFFIRaw.CoreFileSystemWatcherEventV1]
    ) throws -> UInt64? {
        do {
            return try runtime.fileSystemWatcherIngest(identity: Self.rawIdentity(identity), scopeId: scopeID, entries: entries)
        } catch { throw Self.map(error) }
    }

    func fileSystemWatcherCaptureWatermark(identity: CoreRuntimeIdentity, scopeID: String) throws -> UInt64 {
        do {
            return try runtime.fileSystemWatcherCaptureWatermark(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch { throw Self.map(error) }
    }

    func fileSystemWatcherTakeNext(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        through: UInt64?
    ) throws -> AgentryUniFFIRaw.CoreFileSystemWatcherPayloadV1? {
        do {
            return try runtime.fileSystemWatcherTakeNext(identity: Self.rawIdentity(identity), scopeId: scopeID, through: through)
        } catch { throw Self.map(error) }
    }

    func fileSystemWatcherSnapshot(
        identity: CoreRuntimeIdentity,
        scopeID: String
    ) throws -> AgentryUniFFIRaw.CoreFileSystemWatcherSnapshotV1 {
        do {
            return try runtime.fileSystemWatcherSnapshot(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch { throw Self.map(error) }
    }

    func fileSystemWatcherReset(identity: CoreRuntimeIdentity, scopeID: String) throws {
        do {
            try runtime.fileSystemWatcherReset(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch { throw Self.map(error) }
    }

    func fileSystemWatcherCloseScope(identity: CoreRuntimeIdentity, scopeID: String) throws {
        do {
            try runtime.fileSystemWatcherCloseScope(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch { throw Self.map(error) }
    }

    func agentProviderOpenScope(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreAgentProviderScopeConfigV1
    ) throws -> AgentryUniFFIRaw.AgentProviderScopeHandleV1 {
        do {
            return try runtime.agentProviderOpenScope(identity: Self.rawIdentity(identity), config: config)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderStart(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.AgentProviderStartReceiptV1 {
        do {
            return try runtime.agentProviderStart(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderStartWithStdin(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        payload: Data
    ) throws -> AgentryUniFFIRaw.AgentProviderStartReceiptV1 {
        do {
            return try runtime.agentProviderStartWithStdin(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                payload: payload
            )
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderSendLine(identity: CoreRuntimeIdentity, scopeID: String, payload: Data) throws -> UInt64 {
        do {
            return try runtime.agentProviderSendLine(identity: Self.rawIdentity(identity), scopeId: scopeID, payload: payload)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderCodexRequest(identity: CoreRuntimeIdentity, scopeID: String, method: String, params: Data?, timeoutMilliseconds: UInt64?, cancellationToken: String?) throws -> Data {
        do {
            return try runtime.agentProviderCodexRequest(identity: Self.rawIdentity(identity), scopeId: scopeID, method: method, params: params, timeoutMilliseconds: timeoutMilliseconds, cancellationToken: cancellationToken)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderCodexCancel(identity: CoreRuntimeIdentity, scopeID: String, cancellationToken: String) throws -> Bool {
        do {
            return try runtime.agentProviderCodexCancel(identity: Self.rawIdentity(identity), scopeId: scopeID, cancellationToken: cancellationToken)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderCodexNotify(identity: CoreRuntimeIdentity, scopeID: String, method: String, params: Data?) throws -> UInt64 {
        do {
            return try runtime.agentProviderCodexNotify(identity: Self.rawIdentity(identity), scopeId: scopeID, method: method, params: params)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderCodexRespond(identity: CoreRuntimeIdentity, scopeID: String, requestID: Data, result: Data) throws -> UInt64 {
        do {
            return try runtime.agentProviderCodexRespond(identity: Self.rawIdentity(identity), scopeId: scopeID, requestId: requestID, result: result)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderCodexRespondError(identity: CoreRuntimeIdentity, scopeID: String, requestID: Data, code: Int64, message: String, data: Data?) throws -> UInt64 {
        do {
            return try runtime.agentProviderCodexRespondError(identity: Self.rawIdentity(identity), scopeId: scopeID, requestId: requestID, code: code, message: message, data: data)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderCodexState(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.CoreCodexSessionStateV1 {
        do {
            return try runtime.agentProviderCodexState(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderAcpRequest(identity: CoreRuntimeIdentity, scopeID: String, method: String, params: Data?, timeoutMilliseconds: UInt64?, cancellationToken: String?) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpResponseV1 {
        do {
            return try runtime.agentProviderAcpRequest(identity: Self.rawIdentity(identity), scopeId: scopeID, method: method, params: params, timeoutMilliseconds: timeoutMilliseconds, cancellationToken: cancellationToken)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderAcpCancel(identity: CoreRuntimeIdentity, scopeID: String, cancellationToken: String) throws -> Bool {
        do {
            return try runtime.agentProviderAcpCancel(identity: Self.rawIdentity(identity), scopeId: scopeID, cancellationToken: cancellationToken)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderAcpNotify(identity: CoreRuntimeIdentity, scopeID: String, method: String, params: Data?, expectedSessionGeneration: UInt64?) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpControlReceiptV1 {
        do {
            return try runtime.agentProviderAcpNotify(identity: Self.rawIdentity(identity), scopeId: scopeID, method: method, params: params, expectedSessionGeneration: expectedSessionGeneration)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderAcpRespond(identity: CoreRuntimeIdentity, scopeID: String, requestID: Data, result: Data) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpControlReceiptV1 {
        do {
            return try runtime.agentProviderAcpRespond(identity: Self.rawIdentity(identity), scopeId: scopeID, requestId: requestID, result: result)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderAcpRespondError(identity: CoreRuntimeIdentity, scopeID: String, requestID: Data, code: Int64, message: String, data: Data?) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpControlReceiptV1 {
        do {
            return try runtime.agentProviderAcpRespondError(identity: Self.rawIdentity(identity), scopeId: scopeID, requestId: requestID, code: code, message: message, data: data)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderAcpState(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.CoreAgentProviderAcpSessionStateV1 {
        do {
            return try runtime.agentProviderAcpState(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderConformanceSnapshot(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.CoreAgentProviderConformanceSnapshotV1 {
        do {
            return try runtime.agentProviderConformanceSnapshot(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderValidateConformance(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.CoreAgentProviderConformanceValidationV1 {
        do {
            return try runtime.agentProviderValidateConformance(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch {
            throw Self.map(error)
        }
    }

    func agentProviderShutdown(identity: CoreRuntimeIdentity, scopeID: String) throws {
        do {
            try runtime.agentProviderShutdown(identity: Self.rawIdentity(identity), scopeId: scopeID)
        } catch {
            throw Self.map(error)
        }
    }

    func agentOpenScope(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreAgentClaudeScopeConfigV1
    ) throws -> AgentryUniFFIRaw.AgentClaudeScopeHandleV1 {
        do {
            return try runtime.agentOpenScope(identity: Self.rawIdentity(identity), config: config)
        } catch {
            throw Self.map(error)
        }
    }

    func agentStartOrResume(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        resumeSessionID: String?,
        model: String?,
        effortLevel: String?
    ) throws -> AgentryUniFFIRaw.AgentClaudeStartReceiptV1 {
        do {
            return try runtime.agentStartOrResume(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                resumeSessionId: resumeSessionID,
                model: model,
                effortLevel: effortLevel
            )
        } catch {
            throw Self.map(error)
        }
    }

    func agentSendUserMessage(identity: CoreRuntimeIdentity, scopeID: String, text: String) throws -> UInt64 {
        do {
            return try runtime.agentSendUserMessage(identity: Self.rawIdentity(identity), scopeId: scopeID, text: text)
        } catch {
            throw Self.map(error)
        }
    }

    func agentInterruptTurn(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        turnGeneration: UInt64,
        reason: String
    ) throws -> AgentryUniFFIRaw.AgentClaudeInterruptReceiptV1 {
        do {
            return try runtime.agentInterruptTurn(
                identity: Self.rawIdentity(identity), scopeId: scopeID, turnGeneration: turnGeneration, reason: reason
            )
        } catch {
            throw Self.map(error)
        }
    }

    func agentRespondPermission(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        requestID: String,
        decision: AgentryUniFFIRaw.AgentClaudePermissionDecisionV1
    ) throws {
        do {
            try runtime.agentRespondPermission(identity: Self.rawIdentity(identity), scopeId: scopeID, requestId: requestID, decision: decision)
        } catch {
            throw Self.map(error)
        }
    }

    func agentApplyModelAndEffort(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        model: String?,
        effort: String?,
        disposition: AgentryUniFFIRaw.AgentClaudeFlagSettingsDispositionV1
    ) throws -> AgentryUniFFIRaw.AgentClaudeFlagSettingsReceiptV1 {
        do {
            return try runtime.agentApplyModelAndEffort(
                identity: Self.rawIdentity(identity),
                scopeId: scopeID,
                model: model,
                effort: effort,
                disposition: disposition
            )
        } catch {
            throw Self.map(error)
        }
    }

    func agentShutdown(identity: CoreRuntimeIdentity, scopeID: String) throws {
        do {
            try runtime.agentShutdown(identity: Self.rawIdentity(identity), scopeId: scopeID)
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
        case .OperationCancelled: .operationCancelled
        case .ShutdownRequested: .shutdownRequested
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
        case .AgentClaudeUnknownScope: .agentClaudeUnknownScope
        case .AgentClaudeScopeClosed: .agentClaudeScopeClosed
        case .AgentClaudeAlreadyRunning: .agentClaudeAlreadyRunning
        case .AgentClaudeNotRunning: .agentClaudeNotRunning
        case .AgentClaudeUnknownPermissionRequest: .agentClaudeUnknownPermissionRequest
        case let .AgentClaudeSpawnFailed(message): .agentClaudeSpawnFailed(message)
        case let .AgentClaudeReaperFailed(message): .agentClaudeReaperFailed(message)
        case let .AgentClaudeTransportWriteFailed(message): .agentClaudeTransportWriteFailed(message)
        case let .AgentClaudeControlResponseError(message): .agentClaudeControlResponseError(message)
        case let .AgentClaudeInvalidRequest(message): .agentClaudeInvalidRequest(message)
        case .AgentProviderUnknownScope: .agentProviderUnknownScope
        case .AgentProviderScopeClosed: .agentProviderScopeClosed
        case .AgentProviderAlreadyRunning: .agentProviderAlreadyRunning
        case .AgentProviderNotRunning: .agentProviderNotRunning
        case let .AgentProviderSpawnFailed(message): .agentProviderSpawnFailed(message)
        case let .AgentProviderReaperFailed(message): .agentProviderReaperFailed(message)
        case let .AgentProviderTransportWriteFailed(message): .agentProviderTransportWriteFailed(message)
        case let .AgentProviderInvalidRequest(message): .agentProviderInvalidRequest(message)
        case .AgentProviderCodexProtocolMismatch: .agentProviderCodexProtocolMismatch
        case .AgentProviderCodexInvalidJson: .agentProviderCodexInvalidJson
        case let .AgentProviderCodexTimedOut(method): .agentProviderCodexTimedOut(method)
        case let .AgentProviderCodexCancelled(method): .agentProviderCodexCancelled(method)
        case let .AgentProviderCodexRemoteError(method, code, message, data): .agentProviderCodexRemoteError(method: method, code: code, message: message, data: data)
        case .AgentProviderCodexInvalidResponse: .agentProviderCodexInvalidResponse
        case .AgentProviderAcpProtocolMismatch: .agentProviderAcpProtocolMismatch
        case .AgentProviderAcpInvalidJson: .agentProviderAcpInvalidJson
        case let .AgentProviderAcpTimedOut(method): .agentProviderAcpTimedOut(method)
        case let .AgentProviderAcpCancelled(method): .agentProviderAcpCancelled(method)
        case let .AgentProviderAcpRemoteError(method, code, message, data): .agentProviderAcpRemoteError(method: method, code: code, message: message, data: data)
        case .AgentProviderAcpInvalidResponse: .agentProviderAcpInvalidResponse
        case .WatcherUnknownScope: .watcherUnknownScope
        case .WatcherScopeClosed: .watcherScopeClosed
        case let .WatcherInvalidRequest(message): .watcherInvalidRequest(message)
        case let .AgentHostFrameMalformed(message): .agentHostFrameMalformed(message)
        case let .AgentHostFrameTooLarge(actual, maximum): .agentHostFrameTooLarge(actual: actual, maximum: maximum)
        case let .AgentSessionLogIo(operation, message): .agentSessionLogIo(operation: operation, message: message)
        case let .AgentSessionLogNotFound(path): .agentSessionLogNotFound(path: path)
        case let .AgentSessionLogInvalidFile(message): .agentSessionLogInvalidFile(message)
        case let .AgentSessionLogUnsupportedSchemaVersion(found, supported): .agentSessionLogUnsupportedSchemaVersion(found: found, supported: supported)
        case let .AgentSessionLogSessionMismatch(expected, found): .agentSessionLogSessionMismatch(expected: expected, found: found)
        case let .AgentSessionLogInvalidSessionId(value): .agentSessionLogInvalidSessionId(value)
        case let .AgentSessionLogRecordTooLarge(actual, maximum): .agentSessionLogRecordTooLarge(actual: actual, maximum: maximum)
        case let .AgentSessionLogCursorOutOfRange(cursor, nextCursor): .agentSessionLogCursorOutOfRange(cursor: cursor, nextCursor: nextCursor)
        case let .AgentSessionLogMalformedRecord(cursor, message): .agentSessionLogMalformedRecord(cursor: cursor, message: message)
        case let .AgentSessionLogSnapshotRejected(message): .agentSessionLogSnapshotRejected(message)
        case .AgentSessionLogClosed: .agentSessionLogClosed
        case let .AgentRunLifecycleInvalidRequest(message): .agentRunLifecycleInvalidRequest(message)
        }
    }

    private static func workspaceCommandLifecycleError(_ error: Error) -> Error {
        let mapped = Self.map(error)
        return switch mapped {
        case .deadlineExpired: CoreBridgeError.deadlineExpired
            case .operationCancelled: CoreBridgeError.operationCancelled
            case .shutdownRequested: CoreBridgeError.shutdownRequested
        case .queueLimitExceeded: CoreBridgeError.queueLimitExceeded
        case .runtimeStopped: CoreBridgeError.runtimeStopped
        default: mapped
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
    /// A wake source may fire again while `drain(subscriptionID:)` is suspended in the async
    /// decoder. Actor isolation alone does not serialize those reentrant tasks: a later drainer can
    /// otherwise remove and yield a newer batch before the first drainer resumes, reversing the
    /// Rust hub's authority order. Keep exactly one drain owner and reduce overlapping callbacks to
    /// a pending bit; the owner performs another complete rearm/drain cycle before relinquishing.
    private var wakeDrainInProgress = false
    private var wakeDrainRequested = false
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

    /// Resolves operation identity from the Rust catalog. Alias and normalization behavior is
    /// never reconstructed by the domain runtime.
    public func mcpToolOperationIdentity(
        toolName: String,
        input: CoreMcpToolOperationInput
    ) throws -> CoreMcpToolOperationIdentity {
        let identity = try requireIdentity()
        do {
            let raw = try transport.mcpToolOperationIdentityV1(
                identity: identity,
                toolName: toolName,
                input: input.raw
            )
            return CoreMcpToolOperationIdentity(raw: raw)
        } catch {
            throw mapTransportError(error)
        }
    }

    /// Returns the Rust-owned immutable MCP/tool catalog projection. Swift callers may use this
    /// for diagnostics or composition checks, but must not synthesize a fallback catalog when the
    /// projection is unavailable or its digest/version is invalid.
    public func mcpToolCatalog() throws -> CoreMcpToolCatalogSnapshot {
        let identity = try requireIdentity()
        do {
            let raw = try transport.mcpToolCatalogV1(identity: identity)
            return try CoreMcpToolCatalogSnapshot(raw: raw)
        } catch {
            throw mapTransportError(error)
        }
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

    func prepareDirectComputeOperation() throws -> CoreDirectComputeOperationContext {
        do {
            let identity = try requireIdentity()
            return CoreDirectComputeOperationContext(
                transport: transport,
                identity: identity
            )
        } catch {
            throw mapComputeFailure(error)
        }
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
        wakeDrainRequested = true
        guard !wakeDrainInProgress else { return }
        wakeDrainInProgress = true
        defer {
            wakeDrainInProgress = false
        }

        while wakeDrainRequested {
            wakeDrainRequested = false
            guard let identity, lifecycle == .running else { return }
            do {
                while true {
                    try await drainAll(identity: identity)
                    // Guaranteed suspension per pass: if a registration-order bug ever
                    // reappears, the loop degrades to a yielding poll instead of a
                    // non-yielding actor monopoly that starves the registration path.
                    await Task.yield()
                    let hasMore = try transport.rearmWake(identity: identity)
                    if !hasMore { break }
                }
                try await drainAll(identity: identity)
            } catch {
                let mapped = mapTransportError(error)
                if mapped == .runtimeInvalidated {
                    noteInvalidationTrigger("wakeFired transport error: \(String(describing: error))")
                    invalidate()
                    wakeDrainRequested = false
                } else if lifecycle == .running {
                    // A subscription may close while `drain` is suspended in the async decoder.
                    // The batch has already been removed from Rust, so the failure is recoverable;
                    // always rearm the shared wake hub or one stale consumer can leave every later
                    // provider event queued behind a permanently-armed (but unread) pipe.
                    do {
                        let hasMore = try transport.rearmWake(identity: identity)
                        wakeDrainRequested = hasMore
                    } catch {
                        let rearmError = mapTransportError(error)
                        if rearmError == .runtimeInvalidated {
                            noteInvalidationTrigger("wakeFired rearm error: \(String(describing: error))")
                            invalidate()
                        }
                        wakeDrainRequested = false
                    }
                } else {
                    wakeDrainRequested = false
                }
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
        case .operationCancelled: return .operationCancelled
        case .shutdownRequested: return .shutdownRequested
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
        case .agentClaudeUnknownScope: return .agentClaudeUnknownScope
        case .agentClaudeScopeClosed: return .agentClaudeScopeClosed
        case .agentClaudeAlreadyRunning: return .agentClaudeAlreadyRunning
        case .agentClaudeNotRunning: return .agentClaudeNotRunning
        case .agentClaudeUnknownPermissionRequest: return .agentClaudeUnknownPermissionRequest
        case let .agentClaudeSpawnFailed(message): return .agentClaudeSpawnFailed(message)
        case let .agentClaudeReaperFailed(message): return .agentClaudeReaperFailed(message)
        case let .agentClaudeTransportWriteFailed(message): return .agentClaudeTransportWriteFailed(message)
        case let .agentClaudeControlResponseError(message): return .agentClaudeControlResponseError(message)
        case let .agentClaudeInvalidRequest(message): return .agentClaudeInvalidRequest(message)
        case .agentProviderUnknownScope: return .agentProviderUnknownScope
        case .agentProviderScopeClosed: return .agentProviderScopeClosed
        case .agentProviderAlreadyRunning: return .agentProviderAlreadyRunning
        case .agentProviderNotRunning: return .agentProviderNotRunning
        case let .agentProviderSpawnFailed(message): return .agentProviderSpawnFailed(message)
        case let .agentProviderReaperFailed(message): return .agentProviderReaperFailed(message)
        case let .agentProviderTransportWriteFailed(message): return .agentProviderTransportWriteFailed(message)
        case let .agentProviderInvalidRequest(message): return .agentProviderInvalidRequest(message)
        case .agentProviderCodexProtocolMismatch: return .agentProviderCodexProtocolMismatch
        case .agentProviderCodexInvalidJson: return .agentProviderCodexInvalidJson
        case let .agentProviderCodexTimedOut(method): return .agentProviderCodexTimedOut(method)
        case let .agentProviderCodexCancelled(method): return .agentProviderCodexCancelled(method)
        case let .agentProviderCodexRemoteError(method, code, message, data): return .agentProviderCodexRemoteError(method: method, code: code, message: message, data: data)
        case .agentProviderCodexInvalidResponse: return .agentProviderCodexInvalidResponse
        case .agentProviderAcpProtocolMismatch: return .agentProviderAcpProtocolMismatch
        case .agentProviderAcpInvalidJson: return .agentProviderAcpInvalidJson
        case let .agentProviderAcpTimedOut(method): return .agentProviderAcpTimedOut(method)
        case let .agentProviderAcpCancelled(method): return .agentProviderAcpCancelled(method)
        case let .agentProviderAcpRemoteError(method, code, message, data): return .agentProviderAcpRemoteError(method: method, code: code, message: message, data: data)
        case .agentProviderAcpInvalidResponse: return .agentProviderAcpInvalidResponse
        case .watcherUnknownScope: return .watcherUnknownScope
        case .watcherScopeClosed: return .watcherScopeClosed
        case let .watcherInvalidRequest(message): return .watcherInvalidRequest(message)
        case let .agentHostFrameMalformed(message): return .agentHostFrameMalformed(message)
        case let .agentHostFrameTooLarge(actual, maximum): return .agentHostFrameTooLarge(actual: actual, maximum: maximum)
        case let .agentSessionLogIo(operation, message): return .agentSessionLogIo(operation: operation, message: message)
        case let .agentSessionLogNotFound(path): return .agentSessionLogNotFound(path: path)
        case let .agentSessionLogInvalidFile(message): return .agentSessionLogInvalidFile(message)
        case let .agentSessionLogUnsupportedSchemaVersion(found, supported): return .agentSessionLogUnsupportedSchemaVersion(found: found, supported: supported)
        case let .agentSessionLogSessionMismatch(expected, found): return .agentSessionLogSessionMismatch(expected: expected, found: found)
        case let .agentSessionLogInvalidSessionId(value): return .agentSessionLogInvalidSessionId(value)
        case let .agentSessionLogRecordTooLarge(actual, maximum): return .agentSessionLogRecordTooLarge(actual: actual, maximum: maximum)
        case let .agentSessionLogCursorOutOfRange(cursor, nextCursor): return .agentSessionLogCursorOutOfRange(cursor: cursor, nextCursor: nextCursor)
        case let .agentSessionLogMalformedRecord(cursor, message): return .agentSessionLogMalformedRecord(cursor: cursor, message: message)
        case let .agentSessionLogSnapshotRejected(message): return .agentSessionLogSnapshotRejected(message)
        case .agentSessionLogClosed: return .agentSessionLogClosed
        case let .agentRunLifecycleInvalidRequest(message): return .agentRunLifecycleInvalidRequest(message)
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
