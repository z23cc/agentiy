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

/// Default implementations mirroring the pattern the now-retired `inventoryComputeV1` used
/// (`CoreInventory.swift`, P4-8): a `CoreRuntimeTransport` conformer (e.g. `FakeCoreTransport` in
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

    func inventoryPushBulkChunkDiscovery(
        identity: CoreRuntimeIdentity, scopeID: String, bulkLoadID: UInt64, rootID: Data, bytes: Data
    ) throws -> AgentryUniFFIRaw.BulkChunkDiscoveryReceiptV1 {
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

    func inventoryQuery(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        handleID: UInt64,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactQueryResultV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryResolveRecords(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        expectedCatalogGeneration: UInt64?,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactRecordBlockV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    /// P4-6b prep-4: `inventoryResolveRecordsScopeWide`'s facade completion -- same
    /// already-landed-FFI-export pattern as the others in this extension.
    func inventoryResolveRecordsScopeWide(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactRecordBlockV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    /// P4-6b gap-closure: production promotion of the discoverability-toggle FFI export -- see
    /// `InventoryScope::set_file_managed_only`'s doc comment.
    func inventorySetFileManagedOnly(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        fileID: Data,
        managedOnly: Bool
    ) throws {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventorySetFolderManagedOnly(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data,
        folderID: Data,
        managedOnly: Bool
    ) throws {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryLookupPaths(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        handleID: UInt64,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactLookupResultV1 {
        throw CoreTransportError.unexpected("inventory-scope-v1 transport is unavailable")
    }

    func inventoryOpenProjectedShard(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        rootID: Data
    ) throws -> AgentryUniFFIRaw.InventorySnapshotHandleV1 {
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

    func inventoryPushBulkChunkDiscovery(
        scopeID: String,
        bulkLoadID: UInt64,
        rootID: UUID,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.BulkChunkDiscoveryReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryPushBulkChunkDiscovery(
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

    func inventoryApplyDeltaDiscoveryV1(
        scopeID: String,
        rootID: UUID,
        rootLifetimeID: String,
        watcherAcceptedWatermark: UInt64?,
        requiresFullResync: Bool,
        expectedAppliedIndexGeneration: UInt64?,
        source: String,
        eventBytes: Data
    ) throws -> AgentryUniFFIRaw.InventoryDeltaDiscoveryReceiptV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryApplyDeltaDiscoveryV1(
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

    func inventoryQuery(scopeID: String, handleID: UInt64, bytes: Data) throws -> AgentryUniFFIRaw.CompactQueryResultV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryQuery(identity: identity, scopeID: scopeID, handleID: handleID, bytes: bytes)
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryResolveRecords(
        scopeID: String,
        rootID: UUID,
        expectedCatalogGeneration: UInt64?,
        bytes: Data
    ) throws -> AgentryUniFFIRaw.CompactRecordBlockV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryResolveRecords(
                identity: identity,
                scopeID: scopeID,
                rootID: coreInventoryUUIDData(rootID),
                expectedCatalogGeneration: expectedCatalogGeneration,
                bytes: bytes
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryResolveRecordsScopeWide(scopeID: String, bytes: Data) throws -> AgentryUniFFIRaw.CompactRecordBlockV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryResolveRecordsScopeWide(identity: identity, scopeID: scopeID, bytes: bytes)
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventorySetFileManagedOnly(scopeID: String, rootID: UUID, fileID: UUID, managedOnly: Bool) throws {
        let identity = try requireIdentity()
        do {
            try transport.inventorySetFileManagedOnly(
                identity: identity, scopeID: scopeID, rootID: coreInventoryUUIDData(rootID),
                fileID: coreInventoryUUIDData(fileID), managedOnly: managedOnly
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventorySetFolderManagedOnly(scopeID: String, rootID: UUID, folderID: UUID, managedOnly: Bool) throws {
        let identity = try requireIdentity()
        do {
            try transport.inventorySetFolderManagedOnly(
                identity: identity, scopeID: scopeID, rootID: coreInventoryUUIDData(rootID),
                folderID: coreInventoryUUIDData(folderID), managedOnly: managedOnly
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryLookupPaths(scopeID: String, handleID: UInt64, bytes: Data) throws -> AgentryUniFFIRaw.CompactLookupResultV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryLookupPaths(identity: identity, scopeID: scopeID, handleID: handleID, bytes: bytes)
        } catch {
            throw mapTransportError(error)
        }
    }

    func inventoryOpenProjectedShard(scopeID: String, rootID: UUID) throws -> AgentryUniFFIRaw.InventorySnapshotHandleV1 {
        let identity = try requireIdentity()
        do {
            return try transport.inventoryOpenProjectedShard(identity: identity, scopeID: scopeID, rootID: coreInventoryUUIDData(rootID))
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

/// A `RootLifetimeId` is NOT a dashed UUID string on the Rust side: `ids.rs`'s `uuid_id!` macro
/// gives it a plain 32-character lowercase-hex `Display` (matching `InventoryRootLifetimeV1.
/// rootLifetimeId` and every other `rootLifetimeId` string this bridge already threads through
/// opaquely). P4-4b's event payloads carry the same 16 bytes as two big-endian `u64` words
/// (`uuid_to_words`'s convention); this reconstructs the identical hex string from those words so
/// a decoded event's `rootLifetimeID` round-trips byte-for-byte against every other
/// `rootLifetimeId` this bridge already vends.
private func coreInventoryHexLifetimeID(hi: UInt64, lo: UInt64) -> String {
    var bytes = [UInt8]()
    bytes.reserveCapacity(16)
    for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((hi >> shift) & 0xFF)) }
    for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((lo >> shift) & 0xFF)) }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Which `RootLifecycleEvent` message kind (`rootPublished` vs `rootUnloaded`) a
/// `decodeRootLifecycle` call expects -- both share the identical 4-word payload shape and
/// differ only by header tag (see `wire.rs`'s `decode_root_lifecycle`, this decoder's Rust twin).
enum CoreInventoryScopeRootLifecycleKind {
    case rootPublished
    case rootUnloaded

    fileprivate var messageKind: CoreInventoryScopeMessageKind {
        switch self {
        case .rootPublished: .rootPublished
        case .rootUnloaded: .rootUnloaded
        }
    }
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

/// §4.1.1 discovery mint site: `CoreInventoryDeltaCommand`'s discovery counterpart -- `event`
/// carries id-less upserts.
public struct CoreInventoryDeltaDiscoveryCommand: Sendable {
    public var rootID: UUID
    public var rootLifetimeID: String
    public var watcherAcceptedWatermark: UInt64?
    public var requiresFullResync: Bool
    public var expectedAppliedIndexGeneration: UInt64?
    public var source: String
    public var event: CoreInventoryDiscoveryAppliedIndexBatchEventV1

    public init(
        rootID: UUID,
        rootLifetimeID: String,
        watcherAcceptedWatermark: UInt64? = nil,
        requiresFullResync: Bool = false,
        expectedAppliedIndexGeneration: UInt64? = nil,
        source: String,
        event: CoreInventoryDiscoveryAppliedIndexBatchEventV1
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

/// §4.1.1 discovery mint site: `CoreInventoryDeltaReceipt`'s discovery counterpart -- carries the
/// Rust-minted ids, in the same order as the command's `event.upsertedFiles`/`upsertedFolders`.
/// Populated even on a `.rejected` outcome (minting happens before the gate runs) -- see
/// `runtime::inventory_scope::InventoryDeltaDiscoveryReceipt`'s doc comment.
public struct CoreInventoryDeltaDiscoveryReceipt: Sendable, Equatable {
    public let appliedIndexGeneration: UInt64
    public let catalogGeneration: UInt64?
    public let outcome: CoreInventoryDeltaReceipt.Outcome
    public let mintedFileIDs: [UUID]
    public let mintedFolderIDs: [UUID]
}

/// Mirrors Rust's `QueryHaystackVariant` (`rust/crates/runtime/src/inventory_scope/query.rs`) --
/// `from_wire`'s two cases, in wire-value order. P4-5's index comparison arm always uses
/// `.indexKey` (the ordered candidate list from `WorkspaceSearchRootPathIndex`'s C-engine-backed
/// counterpart); `.suggestion` is reserved for P4-7's `AgentFileTagSuggestionService` cutover.
public enum CoreInventoryQueryHaystackVariant: UInt64, Sendable, Equatable, CaseIterable {
    case indexKey = 0
    case suggestion = 1
}

/// One row of `QueryCandidateRow` (`wire.rs`): the fields needed to compare ordered identity/path
/// sequence against the Swift index (design doc §8.2's index comparison arm compares the
/// **sequence**, not `score` -- Rust's own comment on `InventoryQueryCandidate.score` notes scores
/// are always `1` in this crate today, so score equality would be vacuous).
public struct CoreInventoryQueryCandidateV1: Sendable, Equatable {
    public let id: UUID
    public let rootID: UUID
    public let name: String
    public let relativePath: String
    public let standardizedRelativePath: String
    public let fullPath: String
    public let standardizedFullPath: String
    public let displayPath: String
    /// The matched subject string (P4-7b §4.2): Rust's `PathIndexCandidate.tie_break_key` /
    /// `PathSearchMatch.tie_break_key`, i.e. the index's own subject-text composition for
    /// `.indexKey`. `displayPath` above is the caller-prefix-composed value and is NOT
    /// byte-identical to this in multi-root configurations with ambiguous root names -- do not
    /// reconstruct one from the other; both must be consumed as sent.
    public let tieBreakKey: String
    public let score: Int64
}

public struct CoreInventoryQueryResult: Sendable, Equatable {
    public let generation: UInt64?
    public let candidates: [CoreInventoryQueryCandidateV1]
}

/// One row of `FactBlock`'s `rows` (`wire.rs`'s `FactRow`, 18-word `FACT_ROW_STRIDE`; contract doc
/// §5.3: "the API returns facts; each call site composes its own predicate"). `keyHi`/`keyLo` are
/// deliberately not decoded into a typed key here -- for `resolveRecords` they are the requested
/// id's own words (redundant with request-order positional correlation); for `lookupPaths`
/// `keyHi` is always `0` and `keyLo` is a positional ordinal, not a lookup key any decoder needs
/// (`resolve.rs`'s `lookup_by_paths` doc comment: "result order already matches request order
/// 1:1"). Both facade methods below correlate rows to their request by position, not by decoding
/// this field, so it is omitted entirely rather than exposed as a value nothing should read.
public struct CoreInventoryFactRowV1: Sendable, Equatable {
    public let exists: Bool
    public let fileID: UUID?
    public let folderID: UUID?
    public let rootID: UUID?
    public let isDiscoverable: Bool
    public let pathRoundTripsToSelf: Bool
    public let standardizedRelativePath: String?
    public let standardizedFullPath: String?
    public let name: String?
    public let recordFingerprint: UInt64
    /// P4-6b gap-closure: the projected fields §4.3.1 named but P4-4 never wired -- see
    /// `FACT_ROW_STRIDE`'s Rust doc comment. `nil` for a non-existent row.
    public let parentFolderID: UUID?
    public let modificationDate: Date?
}

/// `wire.rs`'s `FactBlock`: `generation == nil` is the whole-block-stale case (contract doc §5.3),
/// carried as data rather than thrown.
public struct CoreInventoryFactBlockV1: Sendable, Equatable {
    public let generation: UInt64?
    public let rootLifetimeID: String
    public let rows: [CoreInventoryFactRowV1]
}

/// One id's (or path's) resolved fact -- the friendly, per-key-dictionary shape `resolveRecords`/
/// `lookupPaths` return, built by zipping `CoreInventoryFactBlockV1.rows` against the request
/// array's own order (see `CoreInventoryFactRowV1`'s doc comment on why the raw key words are
/// never decoded).
public struct CoreInventoryRecordFact: Sendable, Equatable {
    public let exists: Bool
    public let fileID: UUID?
    public let folderID: UUID?
    public let rootID: UUID?
    public let isDiscoverable: Bool
    public let pathRoundTripsToSelf: Bool
    public let standardizedRelativePath: String?
    public let standardizedFullPath: String?
    public let name: String?
    public let recordFingerprint: UInt64
    public let parentFolderID: UUID?
    public let modificationDate: Date?

    fileprivate init(_ row: CoreInventoryFactRowV1) {
        exists = row.exists
        fileID = row.fileID
        folderID = row.folderID
        rootID = row.rootID
        isDiscoverable = row.isDiscoverable
        pathRoundTripsToSelf = row.pathRoundTripsToSelf
        standardizedRelativePath = row.standardizedRelativePath
        standardizedFullPath = row.standardizedFullPath
        name = row.name
        recordFingerprint = row.recordFingerprint
        parentFolderID = row.parentFolderID
        modificationDate = row.modificationDate
    }
}

/// `inventoryResolveRecords`'s typed result (contract doc §5.3's `CompactRecordBlockV1`).
/// `generation == nil` means the whole block is stale against `expectedCatalogGeneration` --
/// `filesByID`/`foldersByID` are empty in that case, matching `resolve_records`'s early return.
public struct CoreInventoryRecordBlock: Sendable, Equatable {
    public let generation: UInt64?
    public let rootLifetimeID: String
    public let filesByID: [UUID: CoreInventoryRecordFact]
    public let foldersByID: [UUID: CoreInventoryRecordFact]
}

/// `inventoryLookupPaths`'s typed result: the identical fact shape, keyed by the requested path.
public struct CoreInventoryPathLookupResult: Sendable, Equatable {
    public let generation: UInt64?
    public let rootLifetimeID: String
    public let factsByPath: [String: CoreInventoryRecordFact]
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
/// Transparent re-export of the raw UniFFI diagnostics record: `Sources/RepoPrompt` app-layer
/// sources must not import `AgentryUniFFIRaw`/`CAgentryRustCore` directly
/// (`Scripts/source_layout_guardrails.sh`'s layering guardrail) -- `AgentryCoreBridge` is the one
/// crossing point permitted to see the raw type, so callers like
/// `WorkspaceFileContextStore`/`WorkspaceInventoryScopeShadowForwarder` (P4-6b prep slice 2's
/// diagnostics-only parity suite) name this alias instead. A plain `typealias` is sufficient here
/// (no wrapper needed) -- `InventoryDiagnosticsV1` is a value-only data record with no
/// bridge/transport internals to hide.
public typealias CoreInventoryDiagnosticsV1 = AgentryUniFFIRaw.InventoryDiagnosticsV1

public final class CoreInventoryScope: @unchecked Sendable {
    private let bridge: AgentryCoreBridge
    public let scopeID: String
    /// P4-4b: the `ScopeId` this scope's event-plane notifications publish into --
    /// `InventoryScopeHandleV1.subscriptionScopeId`, computed once Rust-side
    /// (`InventoryScopeId::to_subscription_scope_id`) and carried here verbatim. Never
    /// re-derived on the Swift side -- see `events()`'s doc comment.
    public let subscriptionScopeID: String
    private let closedFlag = OSAllocatedUnfairLock(initialState: false)

    private init(bridge: AgentryCoreBridge, scopeID: String, subscriptionScopeID: String) {
        self.bridge = bridge
        self.scopeID = scopeID
        self.subscriptionScopeID = subscriptionScopeID
    }

    public static func open(bridge: AgentryCoreBridge, config: CoreInventoryScopeConfig = .init()) async throws -> CoreInventoryScope {
        let handle = try await bridge.inventoryOpenScope(config: .init(
            liveGenerationCap: config.liveGenerationCap,
            maxPatchLogicalMutationCount: config.maxPatchLogicalMutationCount,
            codemapCapableExtensions: config.codemapCapableExtensions
        ))
        return CoreInventoryScope(bridge: bridge, scopeID: handle.scopeId, subscriptionScopeID: handle.subscriptionScopeId)
    }

    /// P4-4b: the inventory-scope event stream (contract doc §5b), reusing `AgentryCoreBridge`'s
    /// fixed `openSubscription` path verbatim -- the 83f848b2 lesson this step was told to honor:
    /// register-before-suspend is already correct there (`CoreBridge.swift`'s doc comment on that
    /// method), so this facade does not re-derive a second register/await sequence. This scope's
    /// events publish under `subscriptionScopeID`, computed Rust-side and carried on this
    /// instance since `open()` -- never re-derived here.
    public func events(
        maxQueuedEvents: UInt64 = 256,
        maxQueuedBytes: UInt64 = 1_048_576
    ) async throws -> CoreInventoryScopeEventStream {
        let scopeID = try CoreScopeID(rawValue: subscriptionScopeID)
        let subscription = try await bridge.openSubscription(
            scopeID: scopeID, maxQueuedEvents: maxQueuedEvents, maxQueuedBytes: maxQueuedBytes
        )
        return CoreInventoryScopeEventStream(bridge: bridge, subscription: subscription)
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

    /// §4.1.1 discovery mint site: `files`/`folders` carry no caller-supplied `id` -- Rust mints
    /// one for each and this returns them in the same order as the input arrays.
    public func pushBulkChunkDiscovery(
        bulkLoadID: UInt64,
        rootID: UUID,
        files: [CoreDiscoveredFileRecordV1],
        folders: [CoreDiscoveredFolderRecordV1]
    ) async throws -> (filesStaged: UInt64, foldersStaged: UInt64, mintedFileIDs: [UUID], mintedFolderIDs: [UUID]) {
        let bytes = CoreInventoryScopeWire.encodeDiscoveryBulkChunk(files: files, folders: folders)
        let receipt = try await bridge.inventoryPushBulkChunkDiscovery(scopeID: scopeID, bulkLoadID: bulkLoadID, rootID: rootID, bytes: bytes)
        return (
            receipt.filesStaged,
            receipt.foldersStaged,
            try receipt.mintedFileIds.map(coreInventoryUUID(fromData:)),
            try receipt.mintedFolderIds.map(coreInventoryUUID(fromData:))
        )
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

    /// §4.1.1 discovery mint site: `command.event`'s upserts carry no caller-supplied `id` --
    /// Rust mints one for each; the receipt's `mintedFileIDs`/`mintedFolderIDs` echo them in
    /// `event.upsertedFiles`/`upsertedFolders` order.
    public func applyDeltaDiscovery(_ command: CoreInventoryDeltaDiscoveryCommand) async throws -> CoreInventoryDeltaDiscoveryReceipt {
        let eventBytes = CoreInventoryScopeWire.encodeDiscoveryDeltaEvent(command.event)
        let receipt = try await bridge.inventoryApplyDeltaDiscoveryV1(
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
        return CoreInventoryDeltaDiscoveryReceipt(
            appliedIndexGeneration: receipt.appliedIndexGeneration,
            catalogGeneration: receipt.catalogGeneration,
            outcome: outcome,
            mintedFileIDs: try receipt.mintedFileIds.map(coreInventoryUUID(fromData:)),
            mintedFolderIDs: try receipt.mintedFolderIds.map(coreInventoryUUID(fromData:))
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

    /// `inventoryOpenProjectedShard` (contract doc §6, B2: the codemap graph-index catalog shard,
    /// built authority-side under a caller-supplied codemap-capable extension set -- configured at
    /// `open(bridge:config:)` time, not per-call). Returns a normal `CoreInventorySnapshot`: the
    /// projected shard is consumed the same way any other snapshot is, via `page`/`query`.
    public func openProjectedShard(rootID: UUID) async throws -> CoreInventorySnapshot {
        let handle = try await bridge.inventoryOpenProjectedShard(scopeID: scopeID, rootID: rootID)
        return CoreInventorySnapshot(
            bridge: bridge,
            scopeID: scopeID,
            handleID: handle.handleId,
            generation: handle.generation,
            rootLifetimeID: handle.rootLifetimeId
        )
    }

    /// `inventoryResolveRecords` (contract doc §5.3): facts, not a verdict, atomically against one
    /// generation. `expectedCatalogGeneration`, when supplied, pins the read to that generation --
    /// a mismatch returns a whole-block-stale result (`generation == nil`, both dictionaries
    /// empty) rather than silently reading a different generation than the caller expected (the
    /// per-site D-8 staleness check §4.3.1's async B1 sites need). Root-based, not handle-based --
    /// no snapshot needs to be open first, matching `applyDelta`/`pushBulkChunk`'s shape.
    public func resolveRecords(
        rootID: UUID,
        expectedCatalogGeneration: UInt64? = nil,
        fileIDs: [UUID],
        folderIDs: [UUID]
    ) async throws -> CoreInventoryRecordBlock {
        let bytes = CoreInventoryScopeWire.encodeResolveRequest(fileIDs: fileIDs, folderIDs: folderIDs)
        let response = try await bridge.inventoryResolveRecords(
            scopeID: scopeID, rootID: rootID, expectedCatalogGeneration: expectedCatalogGeneration, bytes: bytes
        )
        let block = try CoreInventoryScopeWire.decodeFactBlock(response.bytes)
        guard block.generation != nil else {
            return CoreInventoryRecordBlock(
                generation: nil, rootLifetimeID: block.rootLifetimeID, filesByID: [:], foldersByID: [:]
            )
        }
        // Rows are in request order: every fileIDs row first, then every folderIDs row -- see
        // `resolve_by_ids`'s doc comment (`rust/crates/runtime/src/inventory_scope/resolve.rs`).
        // Correlated by position, not by decoding the row's own key words -- see
        // `CoreInventoryFactRowV1`'s doc comment.
        var filesByID: [UUID: CoreInventoryRecordFact] = [:]
        filesByID.reserveCapacity(fileIDs.count)
        for (index, id) in fileIDs.enumerated() where index < block.rows.count {
            filesByID[id] = CoreInventoryRecordFact(block.rows[index])
        }
        var foldersByID: [UUID: CoreInventoryRecordFact] = [:]
        foldersByID.reserveCapacity(folderIDs.count)
        for (index, id) in folderIDs.enumerated() {
            let rowIndex = fileIDs.count + index
            guard rowIndex < block.rows.count else { continue }
            foldersByID[id] = CoreInventoryRecordFact(block.rows[rowIndex])
        }
        return CoreInventoryRecordBlock(
            generation: block.generation, rootLifetimeID: block.rootLifetimeID,
            filesByID: filesByID, foldersByID: foldersByID
        )
    }

    /// P4-6b prep-4 gap-closure: id-keyed, root-less resolve (contract doc §12 amendment) --
    /// see `InventoryScope::resolve_records_scope_wide`'s doc comment for why this exists
    /// alongside `resolveRecords` rather than replacing it. Each returned fact's own `rootID`
    /// (already part of `CoreInventoryRecordFact`) tells the caller which root it came from;
    /// there is no single block-level generation to stale-check against across roots, so unlike
    /// `resolveRecords` this never returns a whole-block-stale result -- absent ids are absent
    /// facts, not staleness.
    public func resolveRecordsScopeWide(
        fileIDs: [UUID],
        folderIDs: [UUID]
    ) async throws -> CoreInventoryRecordBlock {
        let bytes = CoreInventoryScopeWire.encodeResolveRequest(fileIDs: fileIDs, folderIDs: folderIDs)
        let response = try await bridge.inventoryResolveRecordsScopeWide(scopeID: scopeID, bytes: bytes)
        let block = try CoreInventoryScopeWire.decodeFactBlock(response.bytes)
        var filesByID: [UUID: CoreInventoryRecordFact] = [:]
        filesByID.reserveCapacity(fileIDs.count)
        for (index, id) in fileIDs.enumerated() where index < block.rows.count {
            filesByID[id] = CoreInventoryRecordFact(block.rows[index])
        }
        var foldersByID: [UUID: CoreInventoryRecordFact] = [:]
        foldersByID.reserveCapacity(folderIDs.count)
        for (index, id) in folderIDs.enumerated() {
            let rowIndex = fileIDs.count + index
            guard rowIndex < block.rows.count else { continue }
            foldersByID[id] = CoreInventoryRecordFact(block.rows[rowIndex])
        }
        return CoreInventoryRecordBlock(
            generation: block.generation, rootLifetimeID: block.rootLifetimeID,
            filesByID: filesByID, foldersByID: foldersByID
        )
    }

    /// P4-6b gap-closure: discoverability toggle -- the production promotion of the P4-3a
    /// testing-only hook (`InventoryScope::set_file_managed_only`'s doc comment).
    public func setFileManagedOnly(rootID: UUID, fileID: UUID, managedOnly: Bool) async throws {
        try await bridge.inventorySetFileManagedOnly(scopeID: scopeID, rootID: rootID, fileID: fileID, managedOnly: managedOnly)
    }

    public func setFolderManagedOnly(rootID: UUID, folderID: UUID, managedOnly: Bool) async throws {
        try await bridge.inventorySetFolderManagedOnly(scopeID: scopeID, rootID: rootID, folderID: folderID, managedOnly: managedOnly)
    }

    public func diagnostics() async throws -> CoreInventoryDiagnosticsV1 {
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

    public func page(
        offset: UInt64,
        limit: UInt64
    ) async throws -> (files: [CoreInventoryFileRecordV1], folders: [CoreInventoryFolderRecordV1], returnedCount: UInt64, hasMore: Bool) {
        let page = try await bridge.inventorySnapshotPage(scopeID: scopeID, handleID: handleID, offset: offset, limit: limit)
        let (files, folders) = try CoreInventoryScopeWire.decodeBulkChunk(page.bytes)
        return (files, folders, page.returnedCount, page.hasMore)
    }

    /// P4-5: the handle-based read-plane query (design doc §8.2's index comparison arm; contract
    /// doc §6). `prefix` mirrors `QueryPrefix` (`rust/crates/runtime/src/inventory_scope/query.rs`)
    /// -- the per-root display-prefix contract already frozen for `CompactQueryV1` (`WorkspacePathPolicyTests`
    /// pins it across all three `ClientPathFormatter` branches).
    public func query(
        pattern: String,
        limit: UInt64,
        haystackVariant: CoreInventoryQueryHaystackVariant,
        nonEmptyRelativePrefix: String,
        emptyRelativePathValue: String
    ) async throws -> CoreInventoryQueryResult {
        let bytes = CoreInventoryScopeWire.encodeQueryRequest(
            pattern: pattern,
            limit: limit,
            haystackVariant: haystackVariant,
            nonEmptyRelativePrefix: nonEmptyRelativePrefix,
            emptyRelativePathValue: emptyRelativePathValue
        )
        let response = try await bridge.inventoryQuery(scopeID: scopeID, handleID: handleID, bytes: bytes)
        let (generation, candidates) = try CoreInventoryScopeWire.decodeQueryResponse(response.bytes)
        return CoreInventoryQueryResult(generation: generation, candidates: candidates)
    }

    /// `inventoryLookupPaths` (contract doc §5.3): the identical fact shape `resolveRecords`
    /// returns, keyed by path instead of id. Handle-based: the `SnapshotHandleId` selects which
    /// root's live maps to read but does not pin the read to that handle's captured generation
    /// (`scope.rs`'s `lookup_paths` doc comment) -- `factsByPath`'s `generation` is the *live*
    /// generation at read time, which a caller comparing against its own captured generation must
    /// account for.
    public func lookupPaths(relativePaths: [String]) async throws -> CoreInventoryPathLookupResult {
        let bytes = CoreInventoryScopeWire.encodeLookupRequest(paths: relativePaths)
        let response = try await bridge.inventoryLookupPaths(scopeID: scopeID, handleID: handleID, bytes: bytes)
        let block = try CoreInventoryScopeWire.decodeFactBlock(response.bytes)
        // Rows are in request order, 1:1 with `relativePaths` -- see `lookup_by_paths`'s doc
        // comment (`rust/crates/runtime/src/inventory_scope/resolve.rs`).
        var factsByPath: [String: CoreInventoryRecordFact] = [:]
        factsByPath.reserveCapacity(relativePaths.count)
        for (index, path) in relativePaths.enumerated() where index < block.rows.count {
            factsByPath[path] = CoreInventoryRecordFact(block.rows[index])
        }
        return CoreInventoryPathLookupResult(
            generation: block.generation, rootLifetimeID: block.rootLifetimeID, factsByPath: factsByPath
        )
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

// ---- CoreInventoryScopeEventStream: ARC-driven facade over one inventory-scope subscription ---

/// One decoded inventory-scope notification (contract doc §5b's event catalog). `gap` is not a
/// catalogued inventory event -- it is the generic P0 subscription hub's own synthetic marker
/// (`RuntimeEventKind.gap`, `CoreDecodedPayload.gap`), surfaced here so a consumer can react to it
/// (contract doc §5b: "discard their projection and re-bootstrap from a fresh snapshot handle")
/// without reaching into `CoreEvent` itself.
public enum CoreInventoryScopeEvent: Sendable, Equatable {
    case generationAdvanced(CoreInventoryGenerationAdvancedEventV1)
    case appliedIndexBatch(CoreInventoryAppliedIndexBatchEventV1)
    case rootPublished(CoreInventoryRootLifecycleEventV1)
    case rootUnloaded(CoreInventoryRootLifecycleEventV1)
    case shardFallback(CoreInventoryShardFallbackEventV1)
    case resnapshotRequired(CoreInventoryResnapshotRequiredEventV1)
    /// The hub's own gap marker (a dropped-event count, not a scope-authored payload).
    case gap(droppedCount: UInt64)
    /// Fail-open, not fail-closed: an event kind this Swift mirror does not (yet) recognize
    /// decodes to `.unknown` rather than throwing and killing the whole stream -- the same
    /// forward-compatibility posture `DefaultCoreEventDecoder` already takes for the generic
    /// subscription surface.
    case unknown
}

public struct CoreInventoryGenerationAdvancedEventV1: Sendable, Equatable {
    public let rootID: UUID
    public let rootLifetimeID: String
    public let appliedIndexGeneration: UInt64
    public let catalogGeneration: UInt64?
    public let rebuiltAuthoritative: Bool
    public let upsertedCount: UInt64
    public let removedCount: UInt64
    public let modifiedCount: UInt64
}

public struct CoreInventoryRootLifecycleEventV1: Sendable, Equatable {
    public let rootID: UUID
    public let rootLifetimeID: String
}

/// Fixed order matching Rust's `RootCatalogShardFallbackReason::ALL` (contract doc §5c's 8-case
/// table) -- the same "fixed order, never reordered" convention `InventoryDiagnosticsV1.
/// fallbackReasonCounts` already uses on the Swift side for this same enum.
public enum CoreInventoryShardFallbackReasonV1: UInt64, Sendable, Equatable, CaseIterable {
    case missingReusableShard = 0
    case generationGap = 1
    case fullResync = 2
    case unsafeOrAmbiguousBatch = 3
    case retentionBoundary = 4
    case patchThresholdExceeded = 5
    case patchApplicationBackstop = 6
    case shadowValidationMismatch = 7
}

public struct CoreInventoryShardFallbackEventV1: Sendable, Equatable {
    public let rootID: UUID
    public let reason: CoreInventoryShardFallbackReasonV1
}

/// Fixed order matching Rust's `ResnapshotReason::ALL`.
public enum CoreInventoryResnapshotReasonV1: UInt64, Sendable, Equatable, CaseIterable {
    case gap = 0
    case overflow = 1
    case backstop = 2
    case identityChanged = 3
}

public struct CoreInventoryResnapshotRequiredEventV1: Sendable, Equatable {
    public let rootID: UUID?
    public let reason: CoreInventoryResnapshotReasonV1
}

public struct CoreInventoryScopeEventStream: AsyncSequence, Sendable {
    public typealias Element = CoreInventoryScopeEvent

    private let events: CoreEventStream

    init(bridge: AgentryCoreBridge, subscription: CoreSubscription) {
        events = subscription.events
        self.subscription = subscription
        self.bridge = bridge
    }

    private let bridge: AgentryCoreBridge
    let subscription: CoreSubscription

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(inner: events.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var inner: AsyncThrowingStream<CoreEvent, Error>.Iterator

        public mutating func next() async throws -> CoreInventoryScopeEvent? {
            guard let event = try await inner.next() else { return nil }
            return CoreInventoryScopeEventDecoder.decode(event)
        }
    }

    /// Idempotent, product-facing close over the underlying generic subscription -- mirrors
    /// `CoreInventoryScope.close()`/`CoreInventorySnapshot.close()`'s convention. Unlike those two
    /// ARC wrappers this type has no `deinit` backstop (an `AsyncSequence` value type cannot run
    /// cleanup on last-reference-drop the way a `final class` can); callers are expected to close
    /// explicitly once done draining, the same discipline `AgentryCoreBridge`'s other
    /// `openSubscription` consumers already follow.
    public func close() async throws {
        try await bridge.closeSubscription(subscription)
    }
}

enum CoreInventoryScopeEventDecoder {
    static func decode(_ event: CoreEvent) -> CoreInventoryScopeEvent {
        if case let .gap(droppedCount) = event.payload {
            return .gap(droppedCount: droppedCount)
        }
        guard case let .bytes(payload) = event.payload, payload.count >= 4 else {
            return .unknown
        }
        let kind = UInt16(payload[payload.startIndex + 2]) | (UInt16(payload[payload.startIndex + 3]) << 8)
        do {
            switch kind {
            case CoreInventoryScopeMessageKind.generationAdvanced.rawValue:
                return .generationAdvanced(try CoreInventoryScopeWire.decodeGenerationAdvanced(payload))
            case CoreInventoryScopeMessageKind.deltaEvent.rawValue:
                return .appliedIndexBatch(try CoreInventoryScopeWire.decodeDeltaEvent(payload))
            case CoreInventoryScopeMessageKind.rootPublished.rawValue:
                return .rootPublished(try CoreInventoryScopeWire.decodeRootLifecycle(payload, expected: .rootPublished))
            case CoreInventoryScopeMessageKind.rootUnloaded.rawValue:
                return .rootUnloaded(try CoreInventoryScopeWire.decodeRootLifecycle(payload, expected: .rootUnloaded))
            case CoreInventoryScopeMessageKind.shardFallback.rawValue:
                return .shardFallback(try CoreInventoryScopeWire.decodeShardFallback(payload))
            case CoreInventoryScopeMessageKind.resnapshotRequired.rawValue:
                return .resnapshotRequired(try CoreInventoryScopeWire.decodeResnapshotRequired(payload))
            default:
                return .unknown
            }
        } catch {
            return .unknown
        }
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
    // ---- P4-4b: event-plane payloads (contract doc §5b), mirroring `wire.rs`'s `MessageKind`
    // additions verbatim. `deltaEvent` above doubles as `inventoryAppliedIndexBatch`'s payload --
    // no new kind for it.
    case generationAdvanced = 8
    case rootPublished = 9
    case rootUnloaded = 10
    case shardFallback = 11
    case resnapshotRequired = 12
    // ---- discovery mint site (§4.1.1): additive, parallel to bulkChunk/deltaEvent.
    case discoveryBulkChunk = 13
    case discoveryDeltaEvent = 14
}

private let coreInventoryScopeContractVersionV1: UInt16 = 1
private let coreInventoryScopeStringRangeStride = 2
private let coreInventoryScopeOptionalWord = UInt64.max
private let coreInventoryScopeRecordStride = 14
private let coreInventoryScopeDiscoveryRecordStride = 12
private let coreInventoryScopeCandidateRowStride = 12
private let coreInventoryScopeFactRowStride = 23
private let coreInventoryScopeMaxWordsPerSection = 8 * 1024 * 1024
private let coreInventoryScopeMaxRowsPerCall = 200_000
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

    /// P4-4b: the receive-side counterpart to `encodeDeltaEvent`, needed now that
    /// `inventoryAppliedIndexBatch` (contract doc §5b) delivers this exact payload shape
    /// Rust -> Swift over the event stream (previously this codec only ever sent Swift -> Rust).
    static func decodeDeltaEvent(_ data: Data) throws -> CoreInventoryAppliedIndexBatchEventV1 {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: .deltaEvent)
        let rootIDWords = try reader.readWords(maxWords: 2)
        guard rootIDWords.count == 2 else { throw CoreInventoryScopeWireError.malformed }
        let upsertedFileWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let upsertedFolderWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let removedFileIDWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let removedFolderIDWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let removedFilePathWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let removedFolderPathWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let modifiedFileIDWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let modifiedFolderIDWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let rangeWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let blob = try reader.readBlob()
        try reader.finish()
        let pool = CoreInventoryScopePoolReader(blob: blob, rangeWords: rangeWords)

        let upsertedFiles = try decodeRecordRows(upsertedFileWords, pool: pool).map { row in
            CoreInventoryFileRecordV1(
                id: row.id, rootID: row.rootID, name: row.name, relativePath: row.relativePath,
                standardizedRelativePath: row.standardizedRelativePath, fullPath: row.fullPath,
                standardizedFullPath: row.standardizedFullPath, parentFolderID: row.parentFolderID,
                modificationDate: row.modificationDate
            )
        }
        let upsertedFolders = try decodeRecordRows(upsertedFolderWords, pool: pool).map { row in
            CoreInventoryFolderRecordV1(
                id: row.id, rootID: row.rootID, name: row.name, relativePath: row.relativePath,
                standardizedRelativePath: row.standardizedRelativePath, fullPath: row.fullPath,
                standardizedFullPath: row.standardizedFullPath, parentFolderID: row.parentFolderID,
                modificationDate: row.modificationDate
            )
        }
        return CoreInventoryAppliedIndexBatchEventV1(
            rootID: coreInventoryUUID(fromHi: rootIDWords[0], lo: rootIDWords[1]),
            upsertedFiles: upsertedFiles,
            upsertedFolders: upsertedFolders,
            removedFileIDs: try decodeUUIDWordList(removedFileIDWords),
            removedFolderIDs: try decodeUUIDWordList(removedFolderIDWords),
            removedFilePaths: try removedFilePathWords.map { try pool.resolve($0) },
            removedFolderPaths: try removedFolderPathWords.map { try pool.resolve($0) },
            modifiedFileIDs: try decodeUUIDWordList(modifiedFileIDWords),
            modifiedFolderIDs: try decodeUUIDWordList(modifiedFolderIDWords)
        )
    }

    // ---- read facade (contract doc §5.3): resolve-by-id / lookup-by-path request encoders and
    // the shared fact-block decoder both responses use.

    /// Mirrors `agentry_runtime::inventory_scope::wire::encode_resolve_request` byte-for-byte.
    static func encodeResolveRequest(fileIDs: [UUID], folderIDs: [UUID]) -> Data {
        var fileWords: [UInt64] = []
        fileWords.reserveCapacity(fileIDs.count * 2)
        for id in fileIDs { let (hi, lo) = coreInventoryUUIDWords(id); fileWords.append(hi); fileWords.append(lo) }
        var folderWords: [UInt64] = []
        folderWords.reserveCapacity(folderIDs.count * 2)
        for id in folderIDs { let (hi, lo) = coreInventoryUUIDWords(id); folderWords.append(hi); folderWords.append(lo) }

        var writer = CoreInventoryScopeWriter()
        writer.writeHeader(kind: .resolveRequest)
        writer.writeWords(fileWords)
        writer.writeWords(folderWords)
        return writer.buffer
    }

    /// Mirrors `agentry_runtime::inventory_scope::wire::encode_lookup_request` byte-for-byte.
    static func encodeLookupRequest(paths: [String]) -> Data {
        var pool = CoreInventoryScopeInternPool()
        var pathWords: [UInt64] = []
        pathWords.reserveCapacity(paths.count)
        for path in paths { pathWords.append(pool.intern(path)) }
        let (blob, rangeWords) = (pool.blob, pool.rangeWords)

        var writer = CoreInventoryScopeWriter()
        writer.writeHeader(kind: .lookupRequest)
        writer.writeWords(pathWords)
        writer.writeWords(rangeWords)
        writer.writeBlob(blob)
        return writer.buffer
    }

    /// Mirrors `agentry_runtime::inventory_scope::wire::decode_fact_block` byte-for-byte -- the
    /// shared response shape both `inventoryResolveRecords` and `inventoryLookupPaths` return.
    static func decodeFactBlock(_ data: Data) throws -> CoreInventoryFactBlockV1 {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: .factBlock)
        let header = try reader.readWords(maxWords: 4)
        guard header.count == 4 else { throw CoreInventoryScopeWireError.malformed }
        let generation: UInt64? = switch header[0] {
        case 0: nil
        case 1: header[1]
        default: throw CoreInventoryScopeWireError.malformed
        }
        let rootLifetimeID = coreInventoryHexLifetimeID(hi: header[2], lo: header[3])
        let rowsWords = try reader.readWords(maxWords: coreInventoryScopeMaxRowsPerCall * coreInventoryScopeFactRowStride)
        let rangeWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let blob = try reader.readBlob()
        try reader.finish()
        guard rowsWords.count % coreInventoryScopeFactRowStride == 0 else { throw CoreInventoryScopeWireError.malformed }
        guard rowsWords.count / coreInventoryScopeFactRowStride <= coreInventoryScopeMaxRowsPerCall else {
            throw CoreInventoryScopeWireError.oversize
        }
        let pool = CoreInventoryScopePoolReader(blob: blob, rangeWords: rangeWords)
        var rows: [CoreInventoryFactRowV1] = []
        rows.reserveCapacity(rowsWords.count / coreInventoryScopeFactRowStride)
        var index = 0
        while index < rowsWords.count {
            let row = rowsWords[index ..< index + coreInventoryScopeFactRowStride]
            var cursor = row.startIndex
            func nextWord() -> UInt64 { defer { cursor += 1 }; return row[cursor] }
            _ = nextWord() // key_hi -- never decoded, see CoreInventoryFactRowV1's doc comment
            _ = nextWord() // key_lo
            let exists = nextWord() != 0
            let filePresent = nextWord(); let fileHi = nextWord(); let fileLo = nextWord()
            let folderPresent = nextWord(); let folderHi = nextWord(); let folderLo = nextWord()
            let rootPresent = nextWord(); let rootHi = nextWord(); let rootLo = nextWord()
            let isDiscoverable = nextWord() != 0
            let pathRoundTripsToSelf = nextWord() != 0
            let stdRelIdx = nextWord()
            let stdFullIdx = nextWord()
            let nameIdx = nextWord()
            let recordFingerprint = nextWord()
            let fileID: UUID? = filePresent == 1 ? coreInventoryUUID(fromHi: fileHi, lo: fileLo) : nil
            let folderID: UUID? = folderPresent == 1 ? coreInventoryUUID(fromHi: folderHi, lo: folderLo) : nil
            let rootID: UUID? = rootPresent == 1 ? coreInventoryUUID(fromHi: rootHi, lo: rootLo) : nil
            let parentPresent = nextWord(); let parentHi = nextWord(); let parentLo = nextWord()
            let modPresent = nextWord(); let modBits = nextWord()
            let parentFolderID: UUID? = parentPresent == 1 ? coreInventoryUUID(fromHi: parentHi, lo: parentLo) : nil
               let modificationDate: Date? = modPresent == 1 ? Date(timeIntervalSinceReferenceDate: Double(bitPattern: modBits)) : nil
            rows.append(CoreInventoryFactRowV1(
                exists: exists,
                fileID: fileID,
                folderID: folderID,
                rootID: rootID,
                isDiscoverable: isDiscoverable,
                pathRoundTripsToSelf: pathRoundTripsToSelf,
                standardizedRelativePath: try pool.resolveOptional(stdRelIdx),
                standardizedFullPath: try pool.resolveOptional(stdFullIdx),
                name: try pool.resolveOptional(nameIdx),
                recordFingerprint: recordFingerprint,
                parentFolderID: parentFolderID,
                modificationDate: modificationDate
            ))
            index += coreInventoryScopeFactRowStride
        }
        return CoreInventoryFactBlockV1(generation: generation, rootLifetimeID: rootLifetimeID, rows: rows)
    }

    // ---- discovery mint site (§4.1.1): additive parallel to encodeBulkChunk/decodeBulkChunk and
    // encodeDeltaEvent/decodeDeltaEvent above, which are unchanged.

    static func encodeDiscoveryBulkChunk(files: [CoreDiscoveredFileRecordV1], folders: [CoreDiscoveredFolderRecordV1]) -> Data {
        var pool = CoreInventoryScopeInternPool()
        var fileWords: [UInt64] = []
        fileWords.reserveCapacity(files.count * coreInventoryScopeDiscoveryRecordStride)
        for file in files { pushDiscoveryRecordRow(&fileWords, &pool, file: file) }
        var folderWords: [UInt64] = []
        folderWords.reserveCapacity(folders.count * coreInventoryScopeDiscoveryRecordStride)
        for folder in folders { pushDiscoveryRecordRow(&folderWords, &pool, folder: folder) }

        var writer = CoreInventoryScopeWriter()
        writer.writeHeader(kind: .discoveryBulkChunk)
        writer.writeWords(fileWords)
        writer.writeWords(folderWords)
        writer.writeWords(pool.rangeWords)
        writer.writeBlob(pool.blob)
        return writer.buffer
    }

    static func decodeDiscoveryBulkChunk(_ data: Data) throws -> ([CoreDiscoveredFileRecordV1], [CoreDiscoveredFolderRecordV1]) {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: .discoveryBulkChunk)
        let fileWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let folderWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let rangeWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let blob = try reader.readBlob()
        try reader.finish()
        let pool = CoreInventoryScopePoolReader(blob: blob, rangeWords: rangeWords)
        let files = try decodeDiscoveryRecordRows(fileWords, pool: pool).map { row in
            CoreDiscoveredFileRecordV1(
                rootID: row.rootID, name: row.name, relativePath: row.relativePath,
                standardizedRelativePath: row.standardizedRelativePath, fullPath: row.fullPath,
                standardizedFullPath: row.standardizedFullPath, parentFolderID: row.parentFolderID,
                modificationDate: row.modificationDate
            )
        }
        let folders = try decodeDiscoveryRecordRows(folderWords, pool: pool).map { row in
            CoreDiscoveredFolderRecordV1(
                rootID: row.rootID, name: row.name, relativePath: row.relativePath,
                standardizedRelativePath: row.standardizedRelativePath, fullPath: row.fullPath,
                standardizedFullPath: row.standardizedFullPath, parentFolderID: row.parentFolderID,
                modificationDate: row.modificationDate
            )
        }
        return (files, folders)
    }

    static func encodeDiscoveryDeltaEvent(_ event: CoreInventoryDiscoveryAppliedIndexBatchEventV1) -> Data {
        var pool = CoreInventoryScopeInternPool()
        var upsertedFileWords: [UInt64] = []
        for file in event.upsertedFiles { pushDiscoveryRecordRow(&upsertedFileWords, &pool, file: file) }
        var upsertedFolderWords: [UInt64] = []
        for folder in event.upsertedFolders { pushDiscoveryRecordRow(&upsertedFolderWords, &pool, folder: folder) }
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
        writer.writeHeader(kind: .discoveryDeltaEvent)
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

    static func decodeDiscoveryDeltaEvent(_ data: Data) throws -> CoreInventoryDiscoveryAppliedIndexBatchEventV1 {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: .discoveryDeltaEvent)
        let rootIDWords = try reader.readWords(maxWords: 2)
        guard rootIDWords.count == 2 else { throw CoreInventoryScopeWireError.malformed }
        let upsertedFileWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let upsertedFolderWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let removedFileIDWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let removedFolderIDWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let removedFilePathWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let removedFolderPathWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let modifiedFileIDWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let modifiedFolderIDWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let rangeWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let blob = try reader.readBlob()
        try reader.finish()
        let pool = CoreInventoryScopePoolReader(blob: blob, rangeWords: rangeWords)

        let upsertedFiles = try decodeDiscoveryRecordRows(upsertedFileWords, pool: pool).map { row in
            CoreDiscoveredFileRecordV1(
                rootID: row.rootID, name: row.name, relativePath: row.relativePath,
                standardizedRelativePath: row.standardizedRelativePath, fullPath: row.fullPath,
                standardizedFullPath: row.standardizedFullPath, parentFolderID: row.parentFolderID,
                modificationDate: row.modificationDate
            )
        }
        let upsertedFolders = try decodeDiscoveryRecordRows(upsertedFolderWords, pool: pool).map { row in
            CoreDiscoveredFolderRecordV1(
                rootID: row.rootID, name: row.name, relativePath: row.relativePath,
                standardizedRelativePath: row.standardizedRelativePath, fullPath: row.fullPath,
                standardizedFullPath: row.standardizedFullPath, parentFolderID: row.parentFolderID,
                modificationDate: row.modificationDate
            )
        }
        return CoreInventoryDiscoveryAppliedIndexBatchEventV1(
            rootID: coreInventoryUUID(fromHi: rootIDWords[0], lo: rootIDWords[1]),
            upsertedFiles: upsertedFiles,
            upsertedFolders: upsertedFolders,
            removedFileIDs: try decodeUUIDWordList(removedFileIDWords),
            removedFolderIDs: try decodeUUIDWordList(removedFolderIDWords),
            removedFilePaths: try removedFilePathWords.map { try pool.resolve($0) },
            removedFolderPaths: try removedFolderPathWords.map { try pool.resolve($0) },
            modifiedFileIDs: try decodeUUIDWordList(modifiedFileIDWords),
            modifiedFolderIDs: try decodeUUIDWordList(modifiedFolderIDWords)
        )
    }

    /// P4-5: mirrors `agentry_runtime::inventory_scope::wire::encode_query_request` byte-for-byte
    /// (`sections.queryRequest=header(patternIdx,limit,haystackVariant,prefixIdx,emptyOverrideIdx),
    /// stringRangeWords,blob` in `fingerprint()` below -- already frozen by the contract, not
    /// re-derived here).
    static func encodeQueryRequest(
        pattern: String,
        limit: UInt64,
        haystackVariant: CoreInventoryQueryHaystackVariant,
        nonEmptyRelativePrefix: String,
        emptyRelativePathValue: String
    ) -> Data {
        var pool = CoreInventoryScopeInternPool()
        let patternIdx = pool.intern(pattern)
        let prefixIdx = pool.intern(nonEmptyRelativePrefix)
        let emptyOverrideIdx = pool.intern(emptyRelativePathValue)

        var writer = CoreInventoryScopeWriter()
        writer.writeHeader(kind: .queryRequest)
        writer.writeWords([patternIdx, limit, haystackVariant.rawValue, prefixIdx, emptyOverrideIdx])
        writer.writeWords(pool.rangeWords)
        writer.writeBlob(pool.blob)
        return writer.buffer
    }

    /// The receive-side counterpart, for completeness / future Rust-side host-shaped tooling; not
    /// on the shadow-arm hot path (Swift only ever encodes requests and decodes responses) but
    /// kept symmetric with `decodeDeltaEvent` above.
    static func decodeQueryRequest(_ data: Data) throws -> (
        pattern: String, limit: UInt64, haystackVariant: UInt64, nonEmptyRelativePrefix: String, emptyRelativePathValue: String
    ) {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: .queryRequest)
        let header = try reader.readWords(maxWords: 5)
        guard header.count == 5 else { throw CoreInventoryScopeWireError.malformed }
        let rangeWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let blob = try reader.readBlob()
        try reader.finish()
        let pool = CoreInventoryScopePoolReader(blob: blob, rangeWords: rangeWords)
        return (
            pattern: try pool.resolve(header[0]),
            limit: header[1],
            haystackVariant: header[2],
            nonEmptyRelativePrefix: try pool.resolve(header[3]),
            emptyRelativePathValue: try pool.resolve(header[4])
        )
    }

    /// Mirrors `agentry_runtime::inventory_scope::wire::decode_query_response` byte-for-byte.
    /// `score` unpacks with the same sign-preserving two's-complement convention the Rust encoder
    /// documents (`candidate.score as u64` / here, `UInt64(bitPattern: Int64(...))` reversed).
    static func decodeQueryResponse(_ data: Data) throws -> (generation: UInt64?, candidates: [CoreInventoryQueryCandidateV1]) {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: .queryResponse)
        let header = try reader.readWords(maxWords: 2)
        guard header.count == 2 else { throw CoreInventoryScopeWireError.malformed }
        let generation: UInt64? = switch header[0] {
        case 0: nil
        case 1: header[1]
        default: throw CoreInventoryScopeWireError.malformed
        }
        let rowsWords = try reader.readWords(maxWords: coreInventoryScopeMaxRowsPerCall * coreInventoryScopeCandidateRowStride)
        let rangeWords = try reader.readWords(maxWords: coreInventoryScopeMaxWordsPerSection)
        let blob = try reader.readBlob()
        try reader.finish()
        guard rowsWords.count % coreInventoryScopeCandidateRowStride == 0 else { throw CoreInventoryScopeWireError.malformed }
        guard rowsWords.count / coreInventoryScopeCandidateRowStride <= coreInventoryScopeMaxRowsPerCall else {
            throw CoreInventoryScopeWireError.oversize
        }
        let pool = CoreInventoryScopePoolReader(blob: blob, rangeWords: rangeWords)
        var candidates: [CoreInventoryQueryCandidateV1] = []
        candidates.reserveCapacity(rowsWords.count / coreInventoryScopeCandidateRowStride)
        var index = 0
        while index < rowsWords.count {
            let row = rowsWords[index ..< index + coreInventoryScopeCandidateRowStride]
            let base = row.startIndex
            candidates.append(CoreInventoryQueryCandidateV1(
                id: coreInventoryUUID(fromHi: row[base], lo: row[base + 1]),
                rootID: coreInventoryUUID(fromHi: row[base + 2], lo: row[base + 3]),
                name: try pool.resolve(row[base + 4]),
                relativePath: try pool.resolve(row[base + 5]),
                standardizedRelativePath: try pool.resolve(row[base + 6]),
                fullPath: try pool.resolve(row[base + 7]),
                standardizedFullPath: try pool.resolve(row[base + 8]),
                displayPath: try pool.resolve(row[base + 9]),
                tieBreakKey: try pool.resolve(row[base + 10]),
                score: Int64(bitPattern: row[base + 11])
            ))
            index += coreInventoryScopeCandidateRowStride
        }
        return (generation, candidates)
    }

    private static func decodeUUIDWordList(_ words: [UInt64]) throws -> [UUID] {
        guard words.count % 2 == 0 else { throw CoreInventoryScopeWireError.malformed }
        var ids: [UUID] = []
        ids.reserveCapacity(words.count / 2)
        var index = 0
        while index < words.count {
            ids.append(coreInventoryUUID(fromHi: words[index], lo: words[index + 1]))
            index += 2
        }
        return ids
    }

    // ---- P4-4b: event-plane decode (contract doc §5b). Fixed-width word sections only -- no
    // interned strings ("events are notifications, never tables") -- mirroring `wire.rs`'s
    // `decode_generation_advanced`/`decode_root_published`/`decode_root_unloaded`/
    // `decode_shard_fallback`/`decode_resnapshot_required` verbatim, byte-for-byte.

    static func decodeGenerationAdvanced(_ data: Data) throws -> CoreInventoryGenerationAdvancedEventV1 {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: .generationAdvanced)
        let words = try reader.readWords(maxWords: 11)
        try reader.finish()
        guard words.count == 11 else { throw CoreInventoryScopeWireError.malformed }
        let (rootHi, rootLo, lifetimeHi, lifetimeLo, appliedIndexGeneration, generationPresent, generationValue, rebuiltFlag, upsertedCount, removedCount, modifiedCount) =
            (words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7], words[8], words[9], words[10])
        let catalogGeneration: UInt64? = switch generationPresent {
        case 0: nil
        case 1: generationValue
        default: throw CoreInventoryScopeWireError.malformed
        }
        let rebuiltAuthoritative: Bool = switch rebuiltFlag {
        case 0: false
        case 1: true
        default: throw CoreInventoryScopeWireError.malformed
        }
        return CoreInventoryGenerationAdvancedEventV1(
            rootID: coreInventoryUUID(fromHi: rootHi, lo: rootLo),
            rootLifetimeID: coreInventoryHexLifetimeID(hi: lifetimeHi, lo: lifetimeLo),
            appliedIndexGeneration: appliedIndexGeneration,
            catalogGeneration: catalogGeneration,
            rebuiltAuthoritative: rebuiltAuthoritative,
            upsertedCount: upsertedCount,
            removedCount: removedCount,
            modifiedCount: modifiedCount
        )
    }

    static func decodeRootLifecycle(_ data: Data, expected: CoreInventoryScopeRootLifecycleKind) throws -> CoreInventoryRootLifecycleEventV1 {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: expected.messageKind)
        let words = try reader.readWords(maxWords: 4)
        try reader.finish()
        guard words.count == 4 else { throw CoreInventoryScopeWireError.malformed }
        return CoreInventoryRootLifecycleEventV1(
            rootID: coreInventoryUUID(fromHi: words[0], lo: words[1]),
            rootLifetimeID: coreInventoryHexLifetimeID(hi: words[2], lo: words[3])
        )
    }

    static func decodeShardFallback(_ data: Data) throws -> CoreInventoryShardFallbackEventV1 {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: .shardFallback)
        let words = try reader.readWords(maxWords: 3)
        try reader.finish()
        guard words.count == 3 else { throw CoreInventoryScopeWireError.malformed }
        guard let reason = CoreInventoryShardFallbackReasonV1(rawValue: words[2]) else {
            throw CoreInventoryScopeWireError.outOfRange
        }
        return CoreInventoryShardFallbackEventV1(rootID: coreInventoryUUID(fromHi: words[0], lo: words[1]), reason: reason)
    }

    static func decodeResnapshotRequired(_ data: Data) throws -> CoreInventoryResnapshotRequiredEventV1 {
        var reader = CoreInventoryScopeReader(data)
        try reader.readHeader(expected: .resnapshotRequired)
        let words = try reader.readWords(maxWords: 4)
        try reader.finish()
        guard words.count == 4 else { throw CoreInventoryScopeWireError.malformed }
        let (rootPresent, rootHi, rootLo, reasonTag) = (words[0], words[1], words[2], words[3])
        let rootID: UUID? = switch rootPresent {
        case 0: nil
        case 1: coreInventoryUUID(fromHi: rootHi, lo: rootLo)
        default: throw CoreInventoryScopeWireError.malformed
        }
        guard let reason = CoreInventoryResnapshotReasonV1(rawValue: reasonTag) else {
            throw CoreInventoryScopeWireError.outOfRange
        }
        return CoreInventoryResnapshotRequiredEventV1(rootID: rootID, reason: reason)
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

    private struct DecodedDiscoveryRecordRow {
        let rootID: UUID
        let name: String
        let relativePath: String
        let standardizedRelativePath: String
        let fullPath: String
        let standardizedFullPath: String
        let parentFolderID: UUID?
        let modificationDate: Date?
    }

    private static func pushDiscoveryRecordRow(_ words: inout [UInt64], _ pool: inout CoreInventoryScopeInternPool, file: CoreDiscoveredFileRecordV1) {
        pushDiscoveryRecordRow(
            &words, &pool, rootID: file.rootID, name: file.name, relativePath: file.relativePath,
            standardizedRelativePath: file.standardizedRelativePath, fullPath: file.fullPath,
            standardizedFullPath: file.standardizedFullPath, parentFolderID: file.parentFolderID,
            modificationDate: file.modificationDate
        )
    }

    private static func pushDiscoveryRecordRow(_ words: inout [UInt64], _ pool: inout CoreInventoryScopeInternPool, folder: CoreDiscoveredFolderRecordV1) {
        pushDiscoveryRecordRow(
            &words, &pool, rootID: folder.rootID, name: folder.name, relativePath: folder.relativePath,
            standardizedRelativePath: folder.standardizedRelativePath, fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath, parentFolderID: folder.parentFolderID,
            modificationDate: folder.modificationDate
        )
    }

    private static func pushDiscoveryRecordRow(
        _ words: inout [UInt64],
        _ pool: inout CoreInventoryScopeInternPool,
        rootID: UUID,
        name: String,
        relativePath: String,
        standardizedRelativePath: String,
        fullPath: String,
        standardizedFullPath: String,
        parentFolderID: UUID?,
        modificationDate: Date?
    ) {
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
            rootHi, rootLo,
            pool.intern(name), pool.intern(relativePath), pool.intern(standardizedRelativePath),
            pool.intern(fullPath), pool.intern(standardizedFullPath),
            parentPresent, parentHi, parentLo, modPresent, modBits,
        ])
    }

    private static func decodeDiscoveryRecordRows(_ words: [UInt64], pool: CoreInventoryScopePoolReader) throws -> [DecodedDiscoveryRecordRow] {
        guard words.count % coreInventoryScopeDiscoveryRecordStride == 0 else { throw CoreInventoryScopeWireError.malformed }
        var rows: [DecodedDiscoveryRecordRow] = []
        rows.reserveCapacity(words.count / coreInventoryScopeDiscoveryRecordStride)
        var index = 0
        while index < words.count {
            let row = words[index ..< index + coreInventoryScopeDiscoveryRecordStride]
            let rootHi = row[row.startIndex], rootLo = row[row.startIndex + 1]
            let nameIdx = row[row.startIndex + 2], relIdx = row[row.startIndex + 3]
            let stdRelIdx = row[row.startIndex + 4], fullIdx = row[row.startIndex + 5]
            let stdFullIdx = row[row.startIndex + 6]
            let parentPresent = row[row.startIndex + 7]
            let parentHi = row[row.startIndex + 8], parentLo = row[row.startIndex + 9]
            let modPresent = row[row.startIndex + 10]
            let modBits = row[row.startIndex + 11]
            let parentFolderID: UUID? = parentPresent == 1 ? coreInventoryUUID(fromHi: parentHi, lo: parentLo) : nil
            let modificationDate: Date? = modPresent == 1 ? Date(timeIntervalSinceReferenceDate: Double(bitPattern: modBits)) : nil
            rows.append(DecodedDiscoveryRecordRow(
                rootID: coreInventoryUUID(fromHi: rootHi, lo: rootLo),
                name: try pool.resolve(nameIdx),
                relativePath: try pool.resolve(relIdx),
                standardizedRelativePath: try pool.resolve(stdRelIdx),
                fullPath: try pool.resolve(fullIdx),
                standardizedFullPath: try pool.resolve(stdFullIdx),
                parentFolderID: parentFolderID,
                modificationDate: modificationDate
            ))
            index += coreInventoryScopeDiscoveryRecordStride
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
        kinds=bulkChunk:1,deltaEvent:2,resolveRequest:3,lookupRequest:4,factBlock:5,queryRequest:6,queryResponse:7,generationAdvanced:8,rootPublished:9,rootUnloaded:10,shardFallback:11,resnapshotRequired:12,discoveryBulkChunk:13,discoveryDeltaEvent:14
        strides=stringRange:2,record:14,discoveryRecord:12,factRow:23,candidate:12
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
        sections.generationAdvanced=rootId,rootLifetimeId,appliedIndexGeneration,catalogGenerationPresent,catalogGeneration,rebuiltAuthoritative,upsertedCount,removedCount,modifiedCount
        sections.rootPublished=rootId,rootLifetimeId
        sections.rootUnloaded=rootId,rootLifetimeId
        sections.shardFallback=rootId,reasonTag
        sections.resnapshotRequired=rootPresent,rootId,reasonTag
        sections.discoveryBulkChunk=discoveredFileWords,discoveredFolderWords,stringRangeWords,blob
        sections.discoveryDeltaEvent=rootId,upsertedDiscoveredFileWords,upsertedDiscoveredFolderWords,removedFileIds,removedFolderIds,removedFilePaths,removedFolderPaths,modifiedFileIds,modifiedFolderIds,stringRangeWords,blob
        fallbackReasonOrder=missingReusableShard:0,generationGap:1,fullResync:2,unsafeOrAmbiguousBatch:3,retentionBoundary:4,patchThresholdExceeded:5,patchApplicationBackstop:6,shadowValidationMismatch:7
        resnapshotReasonOrder=gap:0,overflow:1,backstop:2,identityChanged:3

        """
        let digest = SHA256.hash(data: Data(descriptor.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
