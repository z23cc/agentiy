import AgentryUniFFIRaw
import CryptoKit
import Foundation
import os

// ============================================================================================
// P4-4: `CoreInventoryScope` / `CoreInventorySnapshot` -- the bridge-owned, ARC-driven facade
// over the Rust `InventoryScope`/`ScopeRegistry` primitives (contract doc §1/§4;
// `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §11 P4-4). The raw
// `SnapshotHandleId` is never exposed above this file: `CoreInventorySnapshot`'s `deinit` calls
// `inventoryCloseSnapshot`; `close()` is idempotent and the product-facing lifecycle mechanism,
// `deinit` is the backstop only (contract doc §4 layer 1).
//
// Scope note: this facade covers the control/bulk-load/ingest/read-page path (open/close scope,
// open/close root, begin/push/commit/abort bulk load, apply delta, open/page/close snapshot,
// diagnostics). `inventoryResolveRecords` / `inventoryLookupPaths` / `inventoryQuery` /
// `inventoryOpenProjectedShard` are implemented and tested on the Rust FFI side
// (`rust/crates/ffi/src/api.rs`) but do not yet have Swift facade methods -- a follow-up, not a
// silent gap (see the P4-4 report for the reasoning).
// ============================================================================================

/// Default implementations mirroring the existing `inventoryComputeV1` pattern
/// (`CoreInventory.swift`): a `CoreRuntimeTransport` conformer (e.g. `FakeCoreTransport` in
/// tests) that doesn't override these gets a clear "unavailable" transport error instead of a
/// compile-time obligation to implement all twelve.
extension CoreRuntimeTransport {
    func inventoryOpenScope(identity: CoreRuntimeIdentity, config: AgentryUniFFIRaw.CoreInventoryScopeConfigV1) throws -> AgentryUniFFIRaw.InventoryScopeHandleV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryCloseScope(identity: CoreRuntimeIdentity, scopeID: String) throws {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryOpenRoot(
        identity: CoreRuntimeIdentity, scopeID: String, rootID: Data, name: String, standardizedFullPath: String
    ) throws -> AgentryUniFFIRaw.InventoryRootLifetimeV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryCloseRoot(
        identity: CoreRuntimeIdentity, scopeID: String, rootID: Data, rootLifetimeID: String
    ) throws -> AgentryUniFFIRaw.InventoryRootUnloadReceiptV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryScopeDiagnostics(identity: CoreRuntimeIdentity, scopeID: String) throws -> AgentryUniFFIRaw.InventoryDiagnosticsV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryBeginBulkLoad(
        identity: CoreRuntimeIdentity, scopeID: String, rootID: Data, rootLifetimeID: String
    ) throws -> UInt64 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryPushBulkChunk(
        identity: CoreRuntimeIdentity, scopeID: String, bulkLoadID: UInt64, rootID: Data, bytes: Data
    ) throws -> AgentryUniFFIRaw.BulkChunkReceiptV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryCommitBulkLoad(
        identity: CoreRuntimeIdentity, scopeID: String, bulkLoadID: UInt64
    ) throws -> AgentryUniFFIRaw.InventoryGenerationReceiptV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryAbortBulkLoad(identity: CoreRuntimeIdentity, scopeID: String, bulkLoadID: UInt64) throws {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
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
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryOpenSnapshot(identity: CoreRuntimeIdentity, scopeID: String, rootID: Data) throws -> AgentryUniFFIRaw.InventorySnapshotHandleV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventorySnapshotPage(
        identity: CoreRuntimeIdentity, scopeID: String, handleID: UInt64, offset: UInt64, limit: UInt64
    ) throws -> AgentryUniFFIRaw.CompactInventoryPageV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryCloseSnapshot(scopeID: String, handleID: UInt64) throws {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }
}

extension AgentryCoreBridge {
    func inventoryOpenScope(config: AgentryUniFFIRaw.CoreInventoryScopeConfigV1) throws -> AgentryUniFFIRaw.InventoryScopeHandleV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryOpenScope(identity: identity, config: config)
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryCloseScope(scopeID: String) throws {
        let identity = try requireIdentity()
        do {
            try transport.inventoryCloseScope(identity: identity, scopeID: scopeID)
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryOpenRoot(
        scopeID: String,
        rootID: UUID,
        name: String,
        standardizedFullPath: String
    ) throws -> AgentryUniFFIRaw.InventoryRootLifetimeV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryOpenRoot(
                identity: identity,
                scopeID: scopeID,
                rootID: coreInventoryUUIDData(rootID),
                name: name,
                standardizedFullPath: standardizedFullPath
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryCloseRoot(
        scopeID: String,
        rootID: UUID,
        rootLifetimeID: String
    ) throws -> AgentryUniFFIRaw.InventoryRootUnloadReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryCloseRoot(
                identity: identity,
                scopeID: scopeID,
                rootID: coreInventoryUUIDData(rootID),
                rootLifetimeID: rootLifetimeID
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryScopeDiagnostics(scopeID: String) throws -> AgentryUniFFIRaw.InventoryDiagnosticsV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryScopeDiagnostics(identity: identity, scopeID: scopeID)
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryBeginBulkLoad(scopeID: String, rootID: UUID, rootLifetimeID: String) throws -> UInt64 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryBeginBulkLoad(
                identity: identity,
                scopeID: scopeID,
                rootID: coreInventoryUUIDData(rootID),
                rootLifetimeID: rootLifetimeID
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryPushBulkChunk(
        scopeID: String,
        bulkLoadID: UInt64,
        rootID: UUID,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.BulkChunkReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryPushBulkChunk(
                identity: identity,
                scopeID: scopeID,
                bulkLoadID: bulkLoadID,
                rootID: coreInventoryUUIDData(rootID),
                bytes: bytes
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryCommitBulkLoad(scopeID: String, bulkLoadID: UInt64) throws -> AgentryUniFFIRaw.InventoryGenerationReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryCommitBulkLoad(identity: identity, scopeID: scopeID, bulkLoadID: bulkLoadID)
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryAbortBulkLoad(scopeID: String, bulkLoadID: UInt64) throws {
        let identity = try requireIdentity()
        do {
            try transport.inventoryAbortBulkLoad(identity: identity, scopeID: scopeID, bulkLoadID: bulkLoadID)
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryApplyDeltaV1(
        scopeID: String,
        rootID: UUID,
        rootLifetimeID: String,
        watcherAcceptedWatermark: UInt64?,
        requiresFullResync: Bool,
        expectedAppliedIndexGeneration: UInt64?,
        source: String,
        eventBytes: Data
    ) throws -> AgentryUniFFIRaw.InventoryDeltaReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryApplyDeltaV1(
                identity: identity,
                scopeID: scopeID,
                rootID: coreInventoryUUIDData(rootID),
                rootLifetimeID: rootLifetimeID,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                requiresFullResync: requiresFullResync,
                expectedAppliedIndexGeneration: expectedAppliedIndexGeneration,
                source: source,
                eventBytes: eventBytes
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryOpenSnapshot(scopeID: String, rootID: UUID) throws -> AgentryUniFFIRaw.InventorySnapshotHandleV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryOpenSnapshot(identity: identity, scopeID: scopeID, rootID: coreInventoryUUIDData(rootID))
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventorySnapshotPage(
        scopeID: String,
        handleID: UInt64,
        offset: UInt64,
        limit: UInt64
    ) throws -> AgentryUniFFIRaw.CompactInventoryPageV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventorySnapshotPage(identity: identity, scopeID: scopeID, handleID: handleID, offset: offset, limit: limit)
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryCloseSnapshot(scopeID: String, handleID: UInt64) throws {
        do {
            try transport.inventoryCloseSnapshot(scopeID: scopeID, handleID: handleID)
        } catch {
            throw mapTransportError(error)
        }
    }
}

private func coreInventoryUUIDData(_ id: UUID) -> Data {
    let u = id.uuid
    return Data([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
}

private func coreInventoryUUID(fromData data: Data) throws -> UUID {
    guard data.count == 16 else { throw CoreBridgeError.invalidArgument }
    let bytes = [UInt8](data)
    let tuple = (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
    return UUID(uuid: tuple)
}

// ---- CoreInventoryScope: ARC-driven facade over one InventoryScope ---------------------------

public struct CoreInventoryScopeConfig: Sendable {
    public var liveGenerationCap: UInt64
    public var maxPatchLogicalMutationCount: UInt64
    public var codemapCapableExtensions: [String]

    public init(liveGenerationCap: UInt64 = 8, maxPatchLogicalMutationCount: UInt64 = 1, codemapCapableExtensions: [String] = []) {
        self.liveGenerationCap = liveGenerationCap
        self.maxPatchLogicalMutationCount = maxPatchLogicalMutationCount
        self.codemapCapableExtensions = codemapCapableExtensions
    }
}

public struct CoreInventoryGenerationReceipt: Sendable, Equatable {
    public let generation: UInt64
    public let rootLifetimeID: String
}

public struct CoreInventoryDeltaCommand: Sendable {
    public var rootID: UUID
    public var rootLifetimeID: String
    public var watcherAcceptedWatermark: UInt64?
    public var requiresFullResync: Bool
    public var expectedAppliedIndexGeneration: UInt64?
    public var source: String
    public var event: CoreInventoryAppliedIndexBatchEventV1

    public init(
        rootID: UUID,
        rootLifetimeID: String,
        watcherAcceptedWatermark: UInt64? = nil,
        requiresFullResync: Bool = false,
        expectedAppliedIndexGeneration: UInt64? = nil,
        source: String,
        event: CoreInventoryAppliedIndexBatchEventV1
    ) {
        self.rootID = rootID
        self.rootLifetimeID = rootLifetimeID
        self.watcherAcceptedWatermark = watcherAcceptedWatermark
        self.requiresFullResync = requiresFullResync
        self.expectedAppliedIndexGeneration = expectedAppliedIndexGeneration
        self.source = source
        self.event = event
    }
}

public struct CoreInventoryDeltaReceipt: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case patched
        case rebuiltAuthoritative
        case rejected(reason: String)
    }

    public let appliedIndexGeneration: UInt64
    public let catalogGeneration: UInt64?
    public let outcome: Outcome
}

/// Bridge-owned ARC wrapper over one Rust `InventoryScope` (contract doc §1/§4). The raw
/// `InventoryScopeId` is never exposed above this type.
public final class CoreInventoryScope: @unchecked Sendable {
    private let bridge: AgentryCoreBridge
    public let scopeID: String
    private let closedFlag = OSAllocatedUnfairLock(initialState: false)

    private init(bridge: AgentryCoreBridge, scopeID: String) {
        self.bridge = bridge
        self.scopeID = scopeID
    }

    public static func open(bridge: AgentryCoreBridge, config: CoreInventoryScopeConfig = .init()) async throws -> CoreInventoryScope {
        let handle = try await bridge.inventoryOpenScope(config: .init(
            liveGenerationCap: config.liveGenerationCap,
            maxPatchLogicalMutationCount: config.maxPatchLogicalMutationCount,
            codemapCapableExtensions: config.codemapCapableExtensions
        ))
        return CoreInventoryScope(bridge: bridge, scopeID: handle.scopeId)
    }

    public func openRoot(rootID: UUID, name: String, standardizedFullPath: String) async throws -> String {
        let lifetime = try await bridge.inventoryOpenRoot(
            scopeID: scopeID, rootID: rootID, name: name, standardizedFullPath: standardizedFullPath
        )
        return lifetime.rootLifetimeId
    }

    @discardableResult
    public func closeRoot(rootID: UUID, rootLifetimeID: String) async throws -> UInt64? {
        try await bridge.inventoryCloseRoot(scopeID: scopeID, rootID: rootID, rootLifetimeID: rootLifetimeID)
            .finalGeneration
    }

    public func beginBulkLoad(rootID: UUID, rootLifetimeID: String) async throws -> UInt64 {
        try await bridge.inventoryBeginBulkLoad(scopeID: scopeID, rootID: rootID, rootLifetimeID: rootLifetimeID)
    }

    public func pushBulkChunk(
        bulkLoadID: UInt64,
        rootID: UUID,
        files: [CoreInventoryFileRecordV1],
        folders: [CoreInventoryFolderRecordV1]
    ) async throws -> (filesStaged: UInt64, foldersStaged: UInt64) {
        let bytes = CoreInventoryScopeWire.encodeBulkChunk(files: files, folders: folders)
        let receipt = try await bridge.inventoryPushBulkChunk(scopeID: scopeID, bulkLoadID: bulkLoadID, rootID: rootID, bytes: bytes)
        return (receipt.filesStaged, receipt.foldersStaged)
    }

    public func commitBulkLoad(bulkLoadID: UInt64) async throws -> CoreInventoryGenerationReceipt {
        let receipt = try await bridge.inventoryCommitBulkLoad(scopeID: scopeID, bulkLoadID: bulkLoadID)
        return CoreInventoryGenerationReceipt(generation: receipt.generation, rootLifetimeID: receipt.rootLifetimeId)
    }

    public func abortBulkLoad(bulkLoadID: UInt64) async throws {
        try await bridge.inventoryAbortBulkLoad(scopeID: scopeID, bulkLoadID: bulkLoadID)
    }

    public func applyDelta(_ command: CoreInventoryDeltaCommand) async throws -> CoreInventoryDeltaReceipt {
        let eventBytes = CoreInventoryScopeWire.encodeDeltaEvent(command.event)
        let receipt = try await bridge.inventoryApplyDeltaV1(
            scopeID: scopeID,
            rootID: command.rootID,
            rootLifetimeID: command.rootLifetimeID,
            watcherAcceptedWatermark: command.watcherAcceptedWatermark,
            requiresFullResync: command.requiresFullResync,
            expectedAppliedIndexGeneration: command.expectedAppliedIndexGeneration,
            source: command.source,
            eventBytes: eventBytes
        )
        let outcome: CoreInventoryDeltaReceipt.Outcome = switch receipt.outcome {
        case .patched: .patched
        case .rebuiltAuthoritative: .rebuiltAuthoritative
        case let .rejected(reason): .rejected(reason: String(describing: reason))
        }
        return CoreInventoryDeltaReceipt(
            appliedIndexGeneration: receipt.appliedIndexGeneration,
            catalogGeneration: receipt.catalogGeneration,
            outcome: outcome
        )
    }

    public func openSnapshot(rootID: UUID) async throws -> CoreInventorySnapshot {
        let handle = try await bridge.inventoryOpenSnapshot(scopeID: scopeID, rootID: rootID)
        return CoreInventorySnapshot(
            bridge: bridge,
            scopeID: scopeID,
            handleID: handle.handleId,
            generation: handle.generation,
            rootLifetimeID: handle.rootLifetimeId
        )
    }

    public func diagnostics() async throws -> AgentryUniFFIRaw.InventoryDiagnosticsV1 {
        try await bridge.inventoryScopeDiagnostics(scopeID: scopeID)
    }

    /// Idempotent, product-facing close. `deinit` is a backstop only -- see this type's doc
    /// comment.
    public func close() async {
        let alreadyClosed = closedFlag.withLock { flag -> Bool in
            let was = flag
            flag = true
            return was
        }
        guard !alreadyClosed else { return }
        try? await bridge.inventoryCloseScope(scopeID: scopeID)
    }

    deinit {
        let alreadyClosed = closedFlag.withLock { flag -> Bool in
            let was = flag
            flag = true
            return was
        }
        guard !alreadyClosed else { return }
        let bridge = self.bridge
        let scopeID = self.scopeID
        Task { try? await bridge.inventoryCloseScope(scopeID: scopeID) }
    }
}

// ---- CoreInventorySnapshot: ARC-driven facade over one open snapshot handle -------------------

/// Bridge-owned ARC wrapper over one `SnapshotHandleId` (contract doc §4 layer 1). The raw
/// handle id is never exposed above this type; `deinit` calls `inventoryCloseSnapshot`, `close()`
/// is idempotent and the product-facing lifecycle mechanism, `deinit` is the backstop only.
public final class CoreInventorySnapshot: @unchecked Sendable {
    private let bridge: AgentryCoreBridge
    private let scopeID: String
    private let handleID: UInt64
    public let generation: UInt64
    public let rootLifetimeID: String
    private let closedFlag = OSAllocatedUnfairLock(initialState: false)

    init(bridge: AgentryCoreBridge, scopeID: String, handleID: UInt64, generation: UInt64, rootLifetimeID: String) {
        self.bridge = bridge
        self.scopeID = scopeID
        self.handleID = handleID
        self.generation = generation
        self.rootLifetimeID = rootLifetimeID
    }

    public func page(offset: UInt64, limit: UInt64) async throws -> (files: [CoreInventoryFileRecordV1], returnedCount: UInt64, hasMore: Bool) {
        let page = try await bridge.inventorySnapshotPage(scopeID: scopeID, handleID: handleID, offset: offset, limit: limit)
        let (files, _) = try CoreInventoryScopeWire.decodeBulkChunk(page.bytes)
        return (files, page.returnedCount, page.hasMore)
    }

    /// Idempotent, product-facing close. `deinit` is a backstop only -- see this type's doc
    /// comment.
    public func close() async {
        let alreadyClosed = closedFlag.withLock { flag -> Bool in
            let was = flag
            flag = true
            return was
        }
        guard !alreadyClosed else { return }
        try? await bridge.inventoryCloseSnapshot(scopeID: scopeID, handleID: handleID)
    }

    deinit {
        let alreadyClosed = closedFlag.withLock { flag -> Bool in
            let was = flag
            flag = true
            return was
        }
        guard !alreadyClosed else { return }
        let bridge = self.bridge
        let scopeID = self.scopeID
        let handleID = self.handleID
        Task { try? await bridge.inventoryCloseSnapshot(scopeID: scopeID, handleID: handleID) }
    }
}

// ================================================================================================
// Swift mirror of `agentry_runtime::inventory_scope::wire` (`rust/crates/runtime/src/
// inventory_scope/wire.rs`). Charter §15.3 item 6: Rust is the canonical schema source; this
// mirror is fingerprint-locked to it (see `CoreInventoryScopeWire.fingerprint()` and
// `Tests/AgentryCoreBridgeTests/InventoryScopeWireFingerprintTests.swift`), not independently
// authoritative. DO NOT change any stride, section order, or limit here without a matching
// Rust-side change and a re-derived fingerprint.
// ================================================================================================

enum CoreInventoryScopeWireError: Error, Equatable {
    case unknownContractVersion
    case messageKindMismatch
    case truncated
    case oversize
    case malformed
    case outOfRange
    case invalidUTF8
}

private enum CoreInventoryScopeMessageKind: UInt16 {
    case bulkChunk = 1
    case deltaEvent = 2
    case resolveRequest = 3
    case lookupRequest = 4
    case factBlock = 5
    case queryRequest = 6
    case queryResponse = 7
}

private let coreInventoryScopeContractVersionV1: UInt16 = 1
private let coreInventoryScopeStringRangeStride = 2
private let coreInventoryScopeOptionalWord = UInt64.max
private let coreInventoryScopeRecordStride = 14
private let coreInventoryScopeMaxWordsPerSection = 8 * 1024 * 1024
private let coreInventoryScopeMaxBlobBytes = 64 * 1024 * 1024

private struct CoreInventoryScopeWriter {
    private(set) var buffer = Data()

    mutating func writeHeader(kind: CoreInventoryScopeMessageKind) {
        writeU16(coreInventoryScopeContractVersionV1)
        writeU16(kind.rawValue)
    }

    mutating func writeU16(_ value: UInt16) {
        buffer.append(UInt8(value & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
    }

    mutating func writeU32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            buffer.append(UInt8((value >> shift) & 0xFF))
        }
    }

    mutating func writeU64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            buffer.append(UInt8((value >> shift) & 0xFF))
        }
    }

    mutating func writeWords(_ words: [UInt64]) {
        writeU32(UInt32(words.count))
        for word in words { writeU64(word) }
    }

    mutating func writeBlob(_ data: Data) {
        writeU32(UInt32(data.count))
        buffer.append(data)
    }
}

private struct CoreInventoryScopeReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard offset + count <= bytes.count else { throw CoreInventoryScopeWireError.truncated }
        defer { offset += count }
        return bytes[offset ..< offset + count]
    }

    mutating func readU16() throws -> UInt16 {
        let slice = try take(2)
        return UInt16(slice[slice.startIndex]) | (UInt16(slice[slice.startIndex + 1]) << 8)
    }

    mutating func readU32() throws -> UInt32 {
        let slice = try take(4)
        var value: UInt32 = 0
        for (index, byte) in slice.enumerated() { value |= UInt32(byte) << (8 * index) }
        return value
    }

    mutating func readU64() throws -> UInt64 {
        let slice = try take(8)
        var value: UInt64 = 0
        for (index, byte) in slice.enumerated() { value |= UInt64(byte) << (8 * index) }
        return value
    }

    mutating func readHeader(expected: CoreInventoryScopeMessageKind) throws {
        let version = try readU16()
        guard version == coreInventoryScopeContractVersionV1 else { throw CoreInventoryScopeWireError.unknownContractVersion }
        let kind = try readU16()
        guard kind == expected.rawValue else { throw CoreInventoryScopeWireError.messageKindMismatch }
    }

    mutating func readWords(maxWords: Int) throws -> [UInt64] {
        let count = try readU32()
        guard count <= maxWords else { throw CoreInventoryScopeWireError.oversize }
        var words: [UInt64] = []
        words.reserveCapacity(Int(count))
        for _ in 0 ..< count { words.append(try readU64()) }
        return words
    }

    mutating func readBlob() throws -> Data {
        let count = try readU32()
        let slice = try take(Int(count))
        return Data(slice)
    }

    func finish() throws {
        guard offset == bytes.count else { throw CoreInventoryScopeWireError.malformed }
    }
}

private struct CoreInventoryScopeInternPool {
    private(set) var blob = Data()
    private(set) var rangeWords: [UInt64] = []
    private var indexByValue: [String: UInt64] = [:]

    mutating func intern(_ value: String) -> UInt64 {
        if let existing = indexByValue[value] { return existing }
        let start = UInt64(blob.count)
        blob.append(contentsOf: Array(value.utf8))
        let end = UInt64(blob.count)
        let index = UInt64(rangeWords.count / coreInventoryScopeStringRangeStride)
        rangeWords.append(start)
        rangeWords.append(end)
        indexByValue[value] = index
        return index
    }

    mutating func internOptional(_ value: String?) -> UInt64 {
        guard let value else { return coreInventoryScopeOptionalWord }
        return intern(value)
    }
}

private struct CoreInventoryScopePoolReader {
    let blob: Data
    let rangeWords: [UInt64]

    func resolve(_ index: UInt64) throws -> String {
        let i = Int(index) * coreInventoryScopeStringRangeStride
        guard i + 1 < rangeWords.count else { throw CoreInventoryScopeWireError.outOfRange }
        let start = Int(rangeWords[i])
        let end = Int(rangeWords[i + 1])
        guard end >= start, end <= blob.count else { throw CoreInventoryScopeWireError.malformed }
        let sliceStart = blob.index(blob.startIndex, offsetBy: start)
        let sliceEnd = blob.index(blob.startIndex, offsetBy: end)
        guard let string = String(data: blob[sliceStart ..< sliceEnd], encoding: .utf8) else {
            throw CoreInventoryScopeWireError.invalidUTF8
        }
        return string
    }

    func resolveOptional(_ index: UInt64) throws -> String? {
        guard index != coreInventoryScopeOptionalWord else { return nil }
        return try resolve(index)
    }
}

enum CoreInventoryScopeWire {
    static func encodeBulkChunk(files: [CoreInventoryFileRecordV1], folders: [CoreInventoryFolderRecordV1]) -> Data {
        var pool = CoreInventoryScopeInternPool()
        var fileWords: [UInt64] = []
        fileWords.reserveCapacity(files.count * coreInventoryScopeRecordStride)
        for file in files { pushRecordRow(&fileWords, &pool, file: file) }
        var folderWords: [UInt64] = []
        folderWords.reserveCapacity(folders.count * coreInventoryScopeRecordStride)
        for folder in folders { pushRecordRow(&folderWords, &pool, folder: folder) }

        var writer = CoreInventoryScopeWriter()
        writer.writeHeader(kind: .bulkChunk)
        writer.writeWords(fileWords)
        writer.writeWords(folderWords)
        writer.writeWords(pool.rangeWords)
        writer.writeBlob(pool.blob)
        return writer.buffer
    }

    static func decodeBulkChunk(_ data: Data) throws -> ([CoreInventoryFileRecordV1], [CoreInventoryFolderRecordV1]) {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: .bulkChunk)
        let fileWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let folderWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let rangeWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let blob = try reader.readBlob()
        try reader.finish()
        let pool = CoreInventoryScopePoolReader(blob: blob, rangeWords: rangeWords)
        let files = try decodeRecordRows(fileWords, pool: pool).map { row in
            CoreInventoryFileRecordV1(
                id: row.id, rootID: row.rootID, name: row.name, relativePath: row.relativePath,
                standardizedRelativePath: row.standardizedRelativePath, fullPath: row.fullPath,
                standardizedFullPath: row.standardizedFullPath, parentFolderID: row.parentFolderID,
                modificationDate: row.modificationDate
            )
        }
        let folders = try decodeRecordRows(folderWords, pool: pool).map { row in
            CoreInventoryFolderRecordV1(
                id: row.id, rootID: row.rootID, name: row.name, relativePath: row.relativePath,
                standardizedRelativePath: row.standardizedRelativePath, fullPath: row.fullPath,
                standardizedFullPath: row.standardizedFullPath, parentFolderID: row.parentFolderID,
                modificationDate: row.modificationDate
            )
        }
        return (files, folders)
    }

    static func encodeDeltaEvent(_ event: CoreInventoryAppliedIndexBatchEventV1) -> Data {
        var pool = CoreInventoryScopeInternPool()
        var upsertedFileWords: [UInt64] = []
        for file in event.upsertedFiles { pushRecordRow(&upsertedFileWords, &pool, file: file) }
        var upsertedFolderWords: [UInt64] = []
        for folder in event.upsertedFolders { pushRecordRow(&upsertedFolderWords, &pool, folder: folder) }
        var removedFileIDWords: [UInt64] = []
        for id in event.removedFileIDs { let (hi, lo) = coreInventoryUUIDWords(id); removedFileIDWords.append(hi); removedFileIDWords.append(lo) }
        var removedFolderIDWords: [UInt64] = []
        for id in event.removedFolderIDs { let (hi, lo) = coreInventoryUUIDWords(id); removedFolderIDWords.append(hi); removedFolderIDWords.append(lo) }
        var removedFilePathWords: [UInt64] = []
        for path in event.removedFilePaths { removedFilePathWords.append(pool.intern(path)) }
        var removedFolderPathWords: [UInt64] = []
        for path in event.removedFolderPaths { removedFolderPathWords.append(pool.intern(path)) }
        var modifiedFileIDWords: [UInt64] = []
        for id in event.modifiedFileIDs { let (hi, lo) = coreInventoryUUIDWords(id); modifiedFileIDWords.append(hi); modifiedFileIDWords.append(lo) }
        var modifiedFolderIDWords: [UInt64] = []
        for id in event.modifiedFolderIDs { let (hi, lo) = coreInventoryUUIDWords(id); modifiedFolderIDWords.append(hi); modifiedFolderIDWords.append(lo) }
        let (rootHi, rootLo) = coreInventoryUUIDWords(event.rootID)

        var writer = CoreInventoryScopeWriter()
        writer.writeHeader(kind: .deltaEvent)
        writer.writeWords([rootHi, rootLo])
        writer.writeWords(upsertedFileWords)
        writer.writeWords(upsertedFolderWords)
        writer.writeWords(removedFileIDWords)
        writer.writeWords(removedFolderIDWords)
        writer.writeWords(removedFilePathWords)
        writer.writeWords(removedFolderPathWords)
        writer.writeWords(modifiedFileIDWords)
        writer.writeWords(modifiedFolderIDWords)
        writer.writeWords(pool.rangeWords)
        writer.writeBlob(pool.blob)
        return writer.buffer
    }

    private struct DecodedRecordRow {
        let id: UUID
        let rootID: UUID
        let name: String
        let relativePath: String
        let standardizedRelativePath: String
        let fullPath: String
        let standardizedFullPath: String
        let parentFolderID: UUID?
        let modificationDate: Date?
    }

    private static func pushRecordRow(_ words: inout [UInt64], _ pool: inout CoreInventoryScopeInternPool, file: CoreInventoryFileRecordV1) {
        pushRecordRow(
            &words, &pool, id: file.id, rootID: file.rootID, name: file.name, relativePath: file.relativePath,
            standardizedRelativePath: file.standardizedRelativePath, fullPath: file.fullPath,
            standardizedFullPath: file.standardizedFullPath, parentFolderID: file.parentFolderID,
            modificationDate: file.modificationDate
        )
    }

    private static func pushRecordRow(_ words: inout [UInt64], _ pool: inout CoreInventoryScopeInternPool, folder: CoreInventoryFolderRecordV1) {
        pushRecordRow(
            &words, &pool, id: folder.id, rootID: folder.rootID, name: folder.name, relativePath: folder.relativePath,
            standardizedRelativePath: folder.standardizedRelativePath, fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath, parentFolderID: folder.parentFolderID,
            modificationDate: folder.modificationDate
        )
    }

    private static func pushRecordRow(
        _ words: inout [UInt64],
        _ pool: inout CoreInventoryScopeInternPool,
        id: UUID,
        rootID: UUID,
        name: String,
        relativePath: String,
        standardizedRelativePath: String,
        fullPath: String,
        standardizedFullPath: String,
        parentFolderID: UUID?,
        modificationDate: Date?
    ) {
        let (idHi, idLo) = coreInventoryUUIDWords(id)
        let (rootHi, rootLo) = coreInventoryUUIDWords(rootID)
        var parentPresent: UInt64 = 0
        var parentHi: UInt64 = 0
        var parentLo: UInt64 = 0
        if let parentFolderID {
            let (hi, lo) = coreInventoryUUIDWords(parentFolderID)
            parentPresent = 1
            parentHi = hi
            parentLo = lo
        }
        var modPresent: UInt64 = 0
        var modBits: UInt64 = 0
        if let modificationDate {
            modPresent = 1
            modBits = modificationDate.timeIntervalSinceReferenceDate.bitPattern
        }
        words.append(contentsOf: [
            idHi, idLo, rootHi, rootLo,
            pool.intern(name), pool.intern(relativePath), pool.intern(standardizedRelativePath),
            pool.intern(fullPath), pool.intern(standardizedFullPath),
            parentPresent, parentHi, parentLo, modPresent, modBits,
        ])
    }

    private static func decodeRecordRows(_ words: [UInt64], pool: CoreInventoryScopePoolReader) throws -> [DecodedRecordRow] {
        guard words.count % coreInventoryScopeRecordStride == 0 else { throw CoreInventoryScopeWireError.malformed }
        var rows: [DecodedRecordRow] = []
        rows.reserveCapacity(words.count / coreInventoryScopeRecordStride)
        var index = 0
        while index < words.count {
            let row = words[index ..< index + coreInventoryScopeRecordStride]
            let idHi = row[row.startIndex], idLo = row[row.startIndex + 1]
            let rootHi = row[row.startIndex + 2], rootLo = row[row.startIndex + 3]
            let nameIdx = row[row.startIndex + 4], relIdx = row[row.startIndex + 5]
            let stdRelIdx = row[row.startIndex + 6], fullIdx = row[row.startIndex + 7]
            let stdFullIdx = row[row.startIndex + 8]
            let parentPresent = row[row.startIndex + 9]
            let parentHi = row[row.startIndex + 10], parentLo = row[row.startIndex + 11]
            let modPresent = row[row.startIndex + 12]
            let modBits = row[row.startIndex + 13]
            let parentFolderID: UUID? = parentPresent == 1 ? coreInventoryUUID(fromHi: parentHi, lo: parentLo) : nil
            let modificationDate: Date? = modPresent == 1 ? Date(timeIntervalSinceReferenceDate: Double(bitPattern: modBits)) : nil
            rows.append(DecodedRecordRow(
                id: coreInventoryUUID(fromHi: idHi, lo: idLo),
                rootID: coreInventoryUUID(fromHi: rootHi, lo: rootLo),
                name: try pool.resolve(nameIdx),
                relativePath: try pool.resolve(relIdx),
                standardizedRelativePath: try pool.resolve(stdRelIdx),
                fullPath: try pool.resolve(fullIdx),
                standardizedFullPath: try pool.resolve(stdFullIdx),
                parentFolderID: parentFolderID,
                modificationDate: modificationDate
            ))
            index += coreInventoryScopeRecordStride
        }
        return rows
    }

    /// Structural fingerprint lock (charter §15.3 item 6): SHA-256 of the same canonical ASCII
    /// descriptor `agentry_runtime::inventory_scope::wire::descriptor()` builds on the Rust side.
    /// Deliberately NOT a Swift `Hashable`-derived hash for the same reason the Rust side isn't
    /// `DefaultHasher` -- see that function's doc comment. Must be updated in lockstep with any
    /// change to message kinds, strides, limits, or section order on either side.
    static func fingerprint() -> String {
        let descriptor = """
        inventory-scope-v1
        version=1
        kinds=bulkChunk:1,deltaEvent:2,resolveRequest:3,lookupRequest:4,factBlock:5,queryRequest:6,queryResponse:7
        strides=stringRange:2,record:14,factRow:18,candidate:11
        optionalWord=18446744073709551615
        limits=blob:67108864,string:65536,words:8388608,rows:200000,ids:50000,paths:50000
        endianness=words:little-endian,uuidHalves:big-endian
        sections.bulkChunk=fileWords,folderWords,stringRangeWords,blob
        sections.deltaEvent=rootId,upsertedFileWords,upsertedFolderWords,removedFileIds,removedFolderIds,removedFilePaths,removedFolderPaths,modifiedFileIds,modifiedFolderIds,stringRangeWords,blob
        sections.resolveRequest=fileIdWords,folderIdWords
        sections.lookupRequest=pathWords,stringRangeWords,blob
        sections.factBlock=header(present,generation,rootLifetimeHi,rootLifetimeLo),factRowWords,stringRangeWords,blob
        sections.queryRequest=header(patternIdx,limit,haystackVariant,prefixIdx,emptyOverrideIdx),stringRangeWords,blob
        sections.queryResponse=header(present,generation),candidateRowWords,stringRangeWords,blob

        """
        let digest = SHA256.hash(data: Data(descriptor.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
