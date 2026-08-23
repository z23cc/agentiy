import Foundation

// ---- Public friendly domain types (shared by `inventory-scope-v1`) ---------------------------
//
// These mirror `WorkspaceRootRecord` / `WorkspaceFileRecord` / `WorkspaceFolderRecord` /
// `WorkspaceSearchCatalogEntry` / `WorkspaceAppliedIndexBatchEvent` restricted to the fields
// `CoreInventoryScope.swift`'s inventory-scope-v1 wire reads, using only Foundation types so
// `AgentryCoreBridge` stays free of any `RepoPromptApp`/domain-runtime dependency. Callers
// translate to/from their own app-level model types; this module owns no such translation.

public struct CoreInventoryRootRecordV1: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let standardizedFullPath: String

    public init(id: UUID, name: String, standardizedFullPath: String) {
        self.id = id
        self.name = name
        self.standardizedFullPath = standardizedFullPath
    }
}

/// Shared nine-field shape for both file and folder records (see `RECORD_STRIDE` in
/// `rust/crates/runtime/src/inventory_scope/wire.rs`).
public struct CoreInventoryFileRecordV1: Sendable, Equatable {
    public let id: UUID
    public let rootID: UUID
    public let name: String
    public let relativePath: String
    public let standardizedRelativePath: String
    public let fullPath: String
    public let standardizedFullPath: String
    public let parentFolderID: UUID?
    public let modificationDate: Date?

    public init(
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
        self.id = id
        self.rootID = rootID
        self.name = name
        self.relativePath = relativePath
        self.standardizedRelativePath = standardizedRelativePath
        self.fullPath = fullPath
        self.standardizedFullPath = standardizedFullPath
        self.parentFolderID = parentFolderID
        self.modificationDate = modificationDate
    }
}

/// See `CoreInventoryFileRecordV1` doc comment: identical shape, ported for
/// `WorkspaceFolderRecord`.
public struct CoreInventoryFolderRecordV1: Sendable, Equatable {
    public let id: UUID
    public let rootID: UUID
    public let name: String
    public let relativePath: String
    public let standardizedRelativePath: String
    public let fullPath: String
    public let standardizedFullPath: String
    public let parentFolderID: UUID?
    public let modificationDate: Date?

    public init(
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
        self.id = id
        self.rootID = rootID
        self.name = name
        self.relativePath = relativePath
        self.standardizedRelativePath = standardizedRelativePath
        self.fullPath = fullPath
        self.standardizedFullPath = standardizedFullPath
        self.parentFolderID = parentFolderID
        self.modificationDate = modificationDate
    }
}

/// §4.1.1 discovery mint site: the same nine-field shape as `CoreInventoryFileRecordV1` minus
/// `id` -- Rust mints a v4-shaped UUID for each of these when staged via
/// `CoreInventoryScope.pushBulkChunkDiscovery` / `applyDeltaDiscovery`.
public struct CoreDiscoveredFileRecordV1: Sendable, Equatable {
    public let rootID: UUID
    public let name: String
    public let relativePath: String
    public let standardizedRelativePath: String
    public let fullPath: String
    public let standardizedFullPath: String
    public let parentFolderID: UUID?
    public let modificationDate: Date?

    public init(
        rootID: UUID,
        name: String,
        relativePath: String,
        standardizedRelativePath: String,
        fullPath: String,
        standardizedFullPath: String,
        parentFolderID: UUID?,
        modificationDate: Date?
    ) {
        self.rootID = rootID
        self.name = name
        self.relativePath = relativePath
        self.standardizedRelativePath = standardizedRelativePath
        self.fullPath = fullPath
        self.standardizedFullPath = standardizedFullPath
        self.parentFolderID = parentFolderID
        self.modificationDate = modificationDate
    }
}

/// See `CoreDiscoveredFileRecordV1` doc comment: identical shape, for folder identity.
public struct CoreDiscoveredFolderRecordV1: Sendable, Equatable {
    public let rootID: UUID
    public let name: String
    public let relativePath: String
    public let standardizedRelativePath: String
    public let fullPath: String
    public let standardizedFullPath: String
    public let parentFolderID: UUID?
    public let modificationDate: Date?

    public init(
        rootID: UUID,
        name: String,
        relativePath: String,
        standardizedRelativePath: String,
        fullPath: String,
        standardizedFullPath: String,
        parentFolderID: UUID?,
        modificationDate: Date?
    ) {
        self.rootID = rootID
        self.name = name
        self.relativePath = relativePath
        self.standardizedRelativePath = standardizedRelativePath
        self.fullPath = fullPath
        self.standardizedFullPath = standardizedFullPath
        self.parentFolderID = parentFolderID
        self.modificationDate = modificationDate
    }
}

/// `CoreInventoryAppliedIndexBatchEventV1`'s discovery counterpart: `upsertedFiles`/
/// `upsertedFolders` carry id-less records; everything else is identical.
public struct CoreInventoryDiscoveryAppliedIndexBatchEventV1: Sendable, Equatable {
    public let rootID: UUID
    public let upsertedFiles: [CoreDiscoveredFileRecordV1]
    public let upsertedFolders: [CoreDiscoveredFolderRecordV1]
    public let removedFileIDs: [UUID]
    public let removedFolderIDs: [UUID]
    public let removedFilePaths: [String]
    public let removedFolderPaths: [String]
    public let modifiedFileIDs: [UUID]
    public let modifiedFolderIDs: [UUID]

    public init(
        rootID: UUID,
        upsertedFiles: [CoreDiscoveredFileRecordV1],
        upsertedFolders: [CoreDiscoveredFolderRecordV1],
        removedFileIDs: [UUID],
        removedFolderIDs: [UUID],
        removedFilePaths: [String],
        removedFolderPaths: [String],
        modifiedFileIDs: [UUID],
        modifiedFolderIDs: [UUID]
    ) {
        self.rootID = rootID
        self.upsertedFiles = upsertedFiles
        self.upsertedFolders = upsertedFolders
        self.removedFileIDs = removedFileIDs
        self.removedFolderIDs = removedFolderIDs
        self.removedFilePaths = removedFilePaths
        self.removedFolderPaths = removedFolderPaths
        self.modifiedFileIDs = modifiedFileIDs
        self.modifiedFolderIDs = modifiedFolderIDs
    }
}

public struct CoreInventorySearchCatalogEntryV1: Sendable, Equatable {
    public let id: UUID
    public let rootID: UUID
    public let rootPath: String
    public let rootName: String
    public let name: String
    public let relativePath: String
    public let standardizedRelativePath: String
    public let fullPath: String
    public let standardizedFullPath: String
    public let displayPath: String

    public init(
        id: UUID,
        rootID: UUID,
        rootPath: String,
        rootName: String,
        name: String,
        relativePath: String,
        standardizedRelativePath: String,
        fullPath: String,
        standardizedFullPath: String,
        displayPath: String
    ) {
        self.id = id
        self.rootID = rootID
        self.rootPath = rootPath
        self.rootName = rootName
        self.name = name
        self.relativePath = relativePath
        self.standardizedRelativePath = standardizedRelativePath
        self.fullPath = fullPath
        self.standardizedFullPath = standardizedFullPath
        self.displayPath = displayPath
    }
}

public struct CoreInventoryAppliedIndexBatchEventV1: Sendable, Equatable {
    public let rootID: UUID
    public let upsertedFiles: [CoreInventoryFileRecordV1]
    public let upsertedFolders: [CoreInventoryFolderRecordV1]
    public let removedFileIDs: [UUID]
    public let removedFolderIDs: [UUID]
    public let removedFilePaths: [String]
    public let removedFolderPaths: [String]
    public let modifiedFileIDs: [UUID]
    public let modifiedFolderIDs: [UUID]

    public init(
        rootID: UUID,
        upsertedFiles: [CoreInventoryFileRecordV1],
        upsertedFolders: [CoreInventoryFolderRecordV1],
        removedFileIDs: [UUID],
        removedFolderIDs: [UUID],
        removedFilePaths: [String],
        removedFolderPaths: [String],
        modifiedFileIDs: [UUID],
        modifiedFolderIDs: [UUID]
    ) {
        self.rootID = rootID
        self.upsertedFiles = upsertedFiles
        self.upsertedFolders = upsertedFolders
        self.removedFileIDs = removedFileIDs
        self.removedFolderIDs = removedFolderIDs
        self.removedFilePaths = removedFilePaths
        self.removedFolderPaths = removedFolderPaths
        self.modifiedFileIDs = modifiedFileIDs
        self.modifiedFolderIDs = modifiedFolderIDs
    }
}

// ---- CoreComputeClient surface: RETIRED at P4-8 -------------------------------------------
//
// `CoreInventoryCatalogComponentsV1`/`CoreInventoryCatalogShardPatchV1`, the `CoreComputeClient`
// extension (`inventoryBuildAuthoritativeCatalogComponents` and its three siblings), the
// `CoreRuntimeTransport.inventoryComputeV1` default, the `inventory-compute-v1` compact wire
// mirrors (`CoreInventoryOperation`, `CoreCompactInventoryRequestV1`/`ResultV1`,
// `CoreInventoryRequestBuilder`, `CoreInventoryCompactValidator`), and their private row-decode
// helpers were deleted here: the whole-table `inventory-compute-v1` seam they implemented is
// superseded by the stateful `inventory-scope-v1` surface (`CoreInventoryScope.swift`), and its
// only caller, `RustInventoryComputer`, was deleted from `RepoPromptDomainRuntime` in the same
// step. `coreInventoryUUIDWords`/`coreInventoryUUID` below remain: `inventory-scope-v1` uses them
// directly.

// ---- UUID <-> word conversion -------------------------------------------------------------
//
// `Foundation.UUID.uuid` is `uuid_t`, a 16-byte tuple in RFC-4122 field order -- matching the
// Rust side's documented assumption (`InventoryUuid = [u8; 16]`, "matching Swift UUID.uuid: uuid_t
// byte layout"). hi/lo are big-endian halves of those 16 bytes, matching Rust's `uuid_to_words` /
// `uuid_from_words` exactly.

func coreInventoryUUIDWords(_ id: UUID) -> (hi: UInt64, lo: UInt64) {
    let u = id.uuid
    let bytes: [UInt8] = [
        u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
        u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
    ]
    var hi: UInt64 = 0
    for byte in bytes[0 ..< 8] { hi = (hi << 8) | UInt64(byte) }
    var lo: UInt64 = 0
    for byte in bytes[8 ..< 16] { lo = (lo << 8) | UInt64(byte) }
    return (hi, lo)
}

func coreInventoryUUID(fromHi hi: UInt64, lo: UInt64) -> UUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in 0 ..< 8 { bytes[index] = UInt8((hi >> (8 * (7 - index))) & 0xFF) }
    for index in 0 ..< 8 { bytes[8 + index] = UInt8((lo >> (8 * (7 - index))) & 0xFF) }
    let tuple = (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
    return UUID(uuid: tuple)
}
