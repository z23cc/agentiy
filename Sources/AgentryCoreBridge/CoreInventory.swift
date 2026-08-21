import Foundation

// ---- Public friendly domain types (P3-2 inventory seam) --------------------------------------
//
// These mirror `WorkspaceRootRecord` / `WorkspaceFileRecord` / `WorkspaceFolderRecord` /
// `WorkspaceSearchCatalogEntry` / `WorkspaceAppliedIndexBatchEvent` restricted to the fields the
// catalog builders read (see `rust/crates/runtime/src/inventory/builders.rs` doc comments), using
// only Foundation types so `AgentryCoreBridge` stays free of any `RepoPromptApp`/domain-runtime
// dependency. Callers (e.g. `RustInventoryComputer`) translate to/from their own app-level model
// types; this module owns no such translation.

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
/// `rust/crates/runtime/src/inventory/contract.rs`).
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

public struct CoreInventoryCatalogComponentsV1: Sendable, Equatable {
    public let files: [CoreInventoryFileRecordV1]
    public let folders: [CoreInventoryFolderRecordV1]
    public let entries: [CoreInventorySearchCatalogEntryV1]

    public init(
        files: [CoreInventoryFileRecordV1],
        folders: [CoreInventoryFolderRecordV1],
        entries: [CoreInventorySearchCatalogEntryV1]
    ) {
        self.files = files
        self.folders = folders
        self.entries = entries
    }
}

public struct CoreInventoryCatalogShardPatchV1: Sendable, Equatable {
    public let files: [CoreInventoryFileRecordV1]
    public let folders: [CoreInventoryFolderRecordV1]
    public let logicalMutationCount: Int
    public let pathIndexChangedFileIDs: Set<UUID>

    public init(
        files: [CoreInventoryFileRecordV1],
        folders: [CoreInventoryFolderRecordV1],
        logicalMutationCount: Int,
        pathIndexChangedFileIDs: Set<UUID>
    ) {
        self.files = files
        self.folders = folders
        self.logicalMutationCount = logicalMutationCount
        self.pathIndexChangedFileIDs = pathIndexChangedFileIDs
    }
}

// ---- CoreComputeClient surface ----------------------------------------------------------------

extension CoreComputeClient {
    /// Rust port of `WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents`.
    public func inventoryBuildAuthoritativeCatalogComponents(
        roots: [CoreInventoryRootRecordV1],
        filesByID: [UUID: CoreInventoryFileRecordV1],
        foldersByID: [UUID: CoreInventoryFolderRecordV1],
        managedOnlyFileIDs: Set<UUID>,
        managedOnlyFolderIDs: Set<UUID>
    ) async throws -> CoreInventoryCatalogComponentsV1 {
        try Self.requireKeyMatchesID(filesByID, kind: "filesByID")
        try Self.requireKeyMatchesID(foldersByID, kind: "foldersByID")
        var builder = CoreInventoryRequestBuilder()
        var request = CoreCompactInventoryRequestV1(operation: .authoritativeCatalog)
        request.roots = try builder.pushRoots(roots)
        request.filesByID = try builder.pushFiles(Array(filesByID.values))
        request.foldersByID = try builder.pushFolders(Array(foldersByID.values))
        request.managedOnlyFileIDs = builder.pushUUIDList(Array(managedOnlyFileIDs))
        request.managedOnlyFolderIDs = builder.pushUUIDList(Array(managedOnlyFolderIDs))
        builder.fill(into: &request)
        return try await perform(request) { compact in
            try CoreInventoryCompactValidator.decodeComponents(compact, expectedOperation: .authoritativeCatalog)
        }
    }

    /// Rust port of `WorkspaceInventoryCatalogBuilders.buildPendingCatalogComponents`.
    public func inventoryBuildPendingCatalogComponents(
        root: CoreInventoryRootRecordV1,
        filesByID: [UUID: CoreInventoryFileRecordV1],
        foldersByID: [UUID: CoreInventoryFolderRecordV1]
    ) async throws -> CoreInventoryCatalogComponentsV1 {
        try Self.requireKeyMatchesID(filesByID, kind: "filesByID")
        try Self.requireKeyMatchesID(foldersByID, kind: "foldersByID")
        var builder = CoreInventoryRequestBuilder()
        var request = CoreCompactInventoryRequestV1(operation: .pendingCatalog)
        request.roots = try builder.pushRoots([root])
        request.filesByID = try builder.pushFiles(Array(filesByID.values))
        request.foldersByID = try builder.pushFolders(Array(foldersByID.values))
        builder.fill(into: &request)
        return try await perform(request) { compact in
            try CoreInventoryCompactValidator.decodeComponents(compact, expectedOperation: .pendingCatalog)
        }
    }

    /// Rust port of `WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch`. Returns `nil`
    /// for the `NotPatchable` business outcome (fall back to authoritative rebuild).
    public func inventoryBuildRootCatalogShardPatch(
        event: CoreInventoryAppliedIndexBatchEventV1,
        previousFiles: [CoreInventoryFileRecordV1],
        previousFolders: [CoreInventoryFolderRecordV1],
        filesByID: [UUID: CoreInventoryFileRecordV1],
        foldersByID: [UUID: CoreInventoryFolderRecordV1],
        maxLogicalMutationCount: Int
    ) async throws -> CoreInventoryCatalogShardPatchV1? {
        guard let maxLogicalMutationCountWord = UInt64(exactly: maxLogicalMutationCount), maxLogicalMutationCount >= 0 else {
            throw CoreComputeError.invalidRequest("maxLogicalMutationCount must be a non-negative integer")
        }
        try Self.requireKeyMatchesID(filesByID, kind: "filesByID")
        try Self.requireKeyMatchesID(foldersByID, kind: "foldersByID")
        var builder = CoreInventoryRequestBuilder()
        var request = CoreCompactInventoryRequestV1(operation: .shardPatch)
        request.filesByID = try builder.pushFiles(Array(filesByID.values))
        request.foldersByID = try builder.pushFolders(Array(foldersByID.values))
        request.previousFiles = try builder.pushFiles(previousFiles)
        request.previousFolders = try builder.pushFolders(previousFolders)
        let (eventRootHi, eventRootLo) = coreInventoryUUIDWords(event.rootID)
        request.eventRootIDHi = eventRootHi
        request.eventRootIDLo = eventRootLo
        request.eventUpsertedFiles = try builder.pushFiles(event.upsertedFiles)
        request.eventUpsertedFolders = try builder.pushFolders(event.upsertedFolders)
        request.eventRemovedFileIDs = builder.pushUUIDList(event.removedFileIDs)
        request.eventRemovedFolderIDs = builder.pushUUIDList(event.removedFolderIDs)
        request.eventRemovedFilePaths = try builder.pushStringPaths(event.removedFilePaths)
        request.eventRemovedFolderPaths = try builder.pushStringPaths(event.removedFolderPaths)
        request.eventModifiedFileIDs = builder.pushUUIDList(event.modifiedFileIDs)
        request.eventModifiedFolderIDs = builder.pushUUIDList(event.modifiedFolderIDs)
        request.maxLogicalMutationCount = maxLogicalMutationCountWord
        builder.fill(into: &request)
        return try await perform(request) { compact in
            try CoreInventoryCompactValidator.decodeShardPatch(compact)
        }
    }

    /// Rust port of `WorkspaceInventoryCatalogBuilders.mergeRootCatalogShardFileEntryLists`.
    public func inventoryMergeRootCatalogShardFileEntryLists(
        _ shards: [(files: [CoreInventoryFileRecordV1], entries: [CoreInventorySearchCatalogEntryV1])]
    ) async throws -> (files: [CoreInventoryFileRecordV1], entries: [CoreInventorySearchCatalogEntryV1]) {
        var builder = CoreInventoryRequestBuilder()
        var request = CoreCompactInventoryRequestV1(operation: .mergeShards)
        request.shards = try builder.pushShards(shards)
        builder.fill(into: &request)
        return try await perform(request) { compact in
            try CoreInventoryCompactValidator.decodeMerge(compact)
        }
    }

    /// The compact wire has no separate key channel for `filesByID`/`foldersByID`: Rust
    /// reconstructs its map from each row's OWN `id` field (`to_file_map` / `to_folder_map` in
    /// `compact.rs`), not from an externally supplied key. A dictionary whose key disagrees with
    /// its value's `id` would silently round-trip into a Rust-side map keyed differently than the
    /// caller intended -- reject that here instead of producing a wrong (but not obviously wrong)
    /// result.
    private static func requireKeyMatchesID(_ dictionary: [UUID: CoreInventoryFileRecordV1], kind: String) throws {
        for (key, value) in dictionary where key != value.id {
            throw CoreComputeError.invalidRequest("\(kind) entry key \(key) does not match record id \(value.id)")
        }
    }

    private static func requireKeyMatchesID(_ dictionary: [UUID: CoreInventoryFolderRecordV1], kind: String) throws {
        for (key, value) in dictionary where key != value.id {
            throw CoreComputeError.invalidRequest("\(kind) entry key \(key) does not match record id \(value.id)")
        }
    }

    /// Shared control-flow template (see `extractCodeMapBatchV1` / `applyEditsBatchV1`):
    /// `prepareComputeOperation()` -> detached transport call with cooperative cancellation ->
    /// fail-closed decode -> `validateComputeCompletion` -> return the decoded, typed result.
    private func perform<Result>(
        _ request: CoreCompactInventoryRequestV1,
        decode: @Sendable (CoreCompactInventoryResultV1) throws -> Result
    ) async throws -> Result {
        let context = try await bridge.prepareComputeOperation()
        defer { try? context.transport.closeLeafCancellation(context.cancellation, identity: context.identity) }
        do {
            let compact = try await withTaskCancellationHandler {
                if Task.isCancelled {
                    try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
                    throw CancellationError()
                }
                return try await Task.detached(priority: nil) {
                    try context.transport.inventoryComputeV1(
                        identity: context.identity,
                        cancellation: context.cancellation,
                        request: request
                    )
                }.value
            } onCancel: {
                try? context.transport.cancelLeafCancellation(context.cancellation, identity: context.identity)
            }
            if Task.isCancelled { throw CancellationError() }
            let decoded = try decode(compact)
            try context.transport.closeLeafCancellation(context.cancellation, identity: context.identity)
            try await bridge.validateComputeCompletion(identity: context.identity)
            return decoded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await bridge.mapComputeFailure(error)
        }
    }
}

extension CoreRuntimeTransport {
    func inventoryComputeV1(
        identity: CoreRuntimeIdentity,
        cancellation: any CoreLeafCancellationHandle,
        request: CoreCompactInventoryRequestV1
    ) throws -> CoreCompactInventoryResultV1 {
        throw CoreTransportError.unexpected("inventory compact transport is unavailable")
    }
}

// ---- Compact wire mirrors (bridge-internal) ---------------------------------------------------
//
// Mirrors `rust/crates/runtime/src/inventory/contract.rs` / `compact.rs` exactly: word-table
// strides, operation tag, and the request/response pool-plus-ranges shape. DO NOT change any
// stride, field order, or presence-flag encoding here without a matching Rust-side change --
// these two sides are validated by `InventoryRustSwiftDifferentialTests`, not by the type system.

enum CoreInventoryOperation: UInt16 {
    case authoritativeCatalog = 0
    case pendingCatalog = 1
    case shardPatch = 2
    case mergeShards = 3
}

private enum CoreInventoryShardPatchOutcomeTag: UInt16 {
    case patched = 0
    case notPatchable = 1
}

private let coreInventoryContractVersionV1: UInt16 = 1
private let coreInventoryOptionalWord = UInt64.max
private let coreInventoryUUIDStride = 2
private let coreInventoryStringRangeStride = 2
private let coreInventoryRecordStride = 14
private let coreInventoryRootStride = 4
private let coreInventoryEntryStride = 12
private let coreInventoryShardStride = 4

struct CoreCompactInventoryRequestV1 {
    var contractVersion: UInt16 = coreInventoryContractVersionV1
    var operation: UInt16

    var utf8Blob = Data()
    var stringRangeWords: [UInt64] = []
    var stringIndexWords: [UInt64] = []
    var uuidWords: [UInt64] = []

    var rootWords: [UInt64] = []
    var fileWords: [UInt64] = []
    var folderWords: [UInt64] = []
    var entryWords: [UInt64] = []
    var shardWords: [UInt64] = []

    var roots = CoreCompactTableRange(start: 0, count: 0)
    var filesByID = CoreCompactTableRange(start: 0, count: 0)
    var foldersByID = CoreCompactTableRange(start: 0, count: 0)
    var managedOnlyFileIDs = CoreCompactTableRange(start: 0, count: 0)
    var managedOnlyFolderIDs = CoreCompactTableRange(start: 0, count: 0)

    var previousFiles = CoreCompactTableRange(start: 0, count: 0)
    var previousFolders = CoreCompactTableRange(start: 0, count: 0)
    var eventRootIDHi: UInt64 = 0
    var eventRootIDLo: UInt64 = 0
    var eventUpsertedFiles = CoreCompactTableRange(start: 0, count: 0)
    var eventUpsertedFolders = CoreCompactTableRange(start: 0, count: 0)
    var eventRemovedFileIDs = CoreCompactTableRange(start: 0, count: 0)
    var eventRemovedFolderIDs = CoreCompactTableRange(start: 0, count: 0)
    var eventRemovedFilePaths = CoreCompactTableRange(start: 0, count: 0)
    var eventRemovedFolderPaths = CoreCompactTableRange(start: 0, count: 0)
    var eventModifiedFileIDs = CoreCompactTableRange(start: 0, count: 0)
    var eventModifiedFolderIDs = CoreCompactTableRange(start: 0, count: 0)
    var maxLogicalMutationCount: UInt64 = 0

    var shards = CoreCompactTableRange(start: 0, count: 0)

    init(operation: CoreInventoryOperation) {
        self.operation = operation.rawValue
    }
}

struct CoreCompactInventoryResultV1: Equatable {
    let operation: UInt16

    let utf8Blob: Data
    let stringRangeWords: [UInt64]
    let uuidWords: [UInt64]
    let fileWords: [UInt64]
    let folderWords: [UInt64]
    let entryWords: [UInt64]

    let componentsFiles: CoreCompactTableRange
    let componentsFolders: CoreCompactTableRange
    let componentsEntries: CoreCompactTableRange

    let shardPatchOutcome: UInt16
    let shardPatchFiles: CoreCompactTableRange
    let shardPatchFolders: CoreCompactTableRange
    let shardPatchLogicalMutationCount: UInt64
    let shardPatchChangedFileIDs: CoreCompactTableRange

    let mergedFiles: CoreCompactTableRange
    let mergedEntries: CoreCompactTableRange
}

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

// ---- encode --------------------------------------------------------------------------------

/// Accumulates the shared word pools for one compact inventory request, mirroring the Rust
/// `WordPools` trait + `push_*` free functions in `compact.rs`. Field/row order below MUST match
/// `push_record_row` / `push_entry_row` / `push_roots` / `push_shards` exactly.
private struct CoreInventoryRequestBuilder {
    var utf8Blob = Data()
    var stringRangeWords: [UInt64] = []
    var stringIndexWords: [UInt64] = []
    var uuidWords: [UInt64] = []
    var rootWords: [UInt64] = []
    var fileWords: [UInt64] = []
    var folderWords: [UInt64] = []
    var entryWords: [UInt64] = []
    var shardWords: [UInt64] = []

    mutating func pushString(_ value: String) -> UInt64 {
        let start = UInt64(utf8Blob.count)
        utf8Blob.append(contentsOf: Array(value.utf8))
        let end = UInt64(utf8Blob.count)
        let index = UInt64(stringRangeWords.count / coreInventoryStringRangeStride)
        stringRangeWords.append(start)
        stringRangeWords.append(end)
        return index
    }

    mutating func pushUUID(_ id: UUID) {
        let (hi, lo) = coreInventoryUUIDWords(id)
        uuidWords.append(hi)
        uuidWords.append(lo)
    }

    mutating func pushUUIDList(_ ids: [UUID]) -> CoreCompactTableRange {
        let start = UInt64(uuidWords.count / coreInventoryUUIDStride)
        for id in ids { pushUUID(id) }
        let end = UInt64(uuidWords.count / coreInventoryUUIDStride)
        return CoreCompactTableRange(start: start, count: end - start)
    }

    private mutating func pushRecordRow(
        isFolder: Bool,
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
        let nameIndex = pushString(name)
        let relativeIndex = pushString(relativePath)
        let standardizedRelativeIndex = pushString(standardizedRelativePath)
        let fullIndex = pushString(fullPath)
        let standardizedFullIndex = pushString(standardizedFullPath)
        let (parentPresent, parentHi, parentLo): (UInt64, UInt64, UInt64)
        if let parentFolderID {
            let (hi, lo) = coreInventoryUUIDWords(parentFolderID)
            (parentPresent, parentHi, parentLo) = (1, hi, lo)
        } else {
            (parentPresent, parentHi, parentLo) = (0, 0, 0)
        }
        let (modPresent, modBits): (UInt64, UInt64)
        if let modificationDate {
            (modPresent, modBits) = (1, modificationDate.timeIntervalSinceReferenceDate.bitPattern)
        } else {
            (modPresent, modBits) = (0, 0)
        }
        let row: [UInt64] = [
            idHi, idLo, rootHi, rootLo,
            nameIndex, relativeIndex, standardizedRelativeIndex, fullIndex, standardizedFullIndex,
            parentPresent, parentHi, parentLo,
            modPresent, modBits,
        ]
        if isFolder {
            folderWords.append(contentsOf: row)
        } else {
            fileWords.append(contentsOf: row)
        }
    }

    private mutating func pushFileRow(_ file: CoreInventoryFileRecordV1) {
        pushRecordRow(
            isFolder: false,
            id: file.id,
            rootID: file.rootID,
            name: file.name,
            relativePath: file.relativePath,
            standardizedRelativePath: file.standardizedRelativePath,
            fullPath: file.fullPath,
            standardizedFullPath: file.standardizedFullPath,
            parentFolderID: file.parentFolderID,
            modificationDate: file.modificationDate
        )
    }

    private mutating func pushFolderRow(_ folder: CoreInventoryFolderRecordV1) {
        pushRecordRow(
            isFolder: true,
            id: folder.id,
            rootID: folder.rootID,
            name: folder.name,
            relativePath: folder.relativePath,
            standardizedRelativePath: folder.standardizedRelativePath,
            fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath,
            parentFolderID: folder.parentFolderID,
            modificationDate: folder.modificationDate
        )
    }

    mutating func pushFiles(_ files: [CoreInventoryFileRecordV1]) throws -> CoreCompactTableRange {
        let start = try requireExactWordCount(fileWords.count, stride: coreInventoryRecordStride)
        for file in files { pushFileRow(file) }
        let end = try requireExactWordCount(fileWords.count, stride: coreInventoryRecordStride)
        return CoreCompactTableRange(start: start, count: end - start)
    }

    mutating func pushFolders(_ folders: [CoreInventoryFolderRecordV1]) throws -> CoreCompactTableRange {
        let start = try requireExactWordCount(folderWords.count, stride: coreInventoryRecordStride)
        for folder in folders { pushFolderRow(folder) }
        let end = try requireExactWordCount(folderWords.count, stride: coreInventoryRecordStride)
        return CoreCompactTableRange(start: start, count: end - start)
    }

    private mutating func pushEntryRow(_ entry: CoreInventorySearchCatalogEntryV1) {
        let (idHi, idLo) = coreInventoryUUIDWords(entry.id)
        let (rootHi, rootLo) = coreInventoryUUIDWords(entry.rootID)
        let rootPath = pushString(entry.rootPath)
        let rootName = pushString(entry.rootName)
        let name = pushString(entry.name)
        let relativePath = pushString(entry.relativePath)
        let standardizedRelativePath = pushString(entry.standardizedRelativePath)
        let fullPath = pushString(entry.fullPath)
        let standardizedFullPath = pushString(entry.standardizedFullPath)
        let displayPath = pushString(entry.displayPath)
        entryWords.append(contentsOf: [
            idHi, idLo, rootHi, rootLo,
            rootPath, rootName, name, relativePath, standardizedRelativePath, fullPath,
            standardizedFullPath, displayPath,
        ])
    }

    mutating func pushEntries(_ entries: [CoreInventorySearchCatalogEntryV1]) throws -> CoreCompactTableRange {
        let start = try requireExactWordCount(entryWords.count, stride: coreInventoryEntryStride)
        for entry in entries { pushEntryRow(entry) }
        let end = try requireExactWordCount(entryWords.count, stride: coreInventoryEntryStride)
        return CoreCompactTableRange(start: start, count: end - start)
    }

    mutating func pushRoots(_ roots: [CoreInventoryRootRecordV1]) throws -> CoreCompactTableRange {
        let start = try requireExactWordCount(rootWords.count, stride: coreInventoryRootStride)
        for root in roots {
            let (hi, lo) = coreInventoryUUIDWords(root.id)
            let name = pushString(root.name)
            let path = pushString(root.standardizedFullPath)
            rootWords.append(contentsOf: [hi, lo, name, path])
        }
        let end = try requireExactWordCount(rootWords.count, stride: coreInventoryRootStride)
        return CoreCompactTableRange(start: start, count: end - start)
    }

    mutating func pushStringPaths(_ values: [String]) throws -> CoreCompactTableRange {
        let start = UInt64(stringIndexWords.count)
        for value in values { stringIndexWords.append(pushString(value)) }
        let end = UInt64(stringIndexWords.count)
        return CoreCompactTableRange(start: start, count: end - start)
    }

    mutating func pushShards(
        _ shards: [(files: [CoreInventoryFileRecordV1], entries: [CoreInventorySearchCatalogEntryV1])]
    ) throws -> CoreCompactTableRange {
        let start = try requireExactWordCount(shardWords.count, stride: coreInventoryShardStride)
        for shard in shards {
            let filesRange = try pushFiles(shard.files)
            let entriesRange = try pushEntries(shard.entries)
            shardWords.append(contentsOf: [
                filesRange.start, filesRange.count, entriesRange.start, entriesRange.count,
            ])
        }
        let end = try requireExactWordCount(shardWords.count, stride: coreInventoryShardStride)
        return CoreCompactTableRange(start: start, count: end - start)
    }

    /// Copies every accumulated pool into `request`, leaving operation-specific ranges/scalars
    /// (already assigned by the caller) untouched.
    func fill(into request: inout CoreCompactInventoryRequestV1) {
        request.utf8Blob = utf8Blob
        request.stringRangeWords = stringRangeWords
        request.stringIndexWords = stringIndexWords
        request.uuidWords = uuidWords
        request.rootWords = rootWords
        request.fileWords = fileWords
        request.folderWords = folderWords
        request.entryWords = entryWords
        request.shardWords = shardWords
    }
}

private func requireExactWordCount(_ wordCount: Int, stride: Int) throws -> UInt64 {
    guard wordCount % stride == 0, let value = UInt64(exactly: wordCount / stride) else {
        throw CoreComputeError.invalidRequest("compact table shape mismatch")
    }
    return value
}

// ---- decode + fail-closed validation ---------------------------------------------------------
//
// Mirrors the Rust `decode_*` helpers in `compact.rs`: bounds-checked cursor arithmetic, no
// panics on malformed data, and non-stripping UTF-8 decode (`String(decoding:as:)`) so a
// legitimate leading U+FEFF stays byte-aligned with the Rust engine (see the BOM note in
// `CoreApplyEdits.swift`).
enum CoreInventoryCompactValidator {
    static func decodeComponents(
        _ value: CoreCompactInventoryResultV1,
        expectedOperation: CoreInventoryOperation
    ) throws -> CoreInventoryCatalogComponentsV1 {
        try validateEnvelope(value, expectedOperation: expectedOperation)
        let files = try decodeFileRecords(value, range: value.componentsFiles)
        let folders = try decodeFolderRecords(value, range: value.componentsFolders)
        let entries = try decodeEntries(value, range: value.componentsEntries)
        return CoreInventoryCatalogComponentsV1(files: files, folders: folders, entries: entries)
    }

    static func decodeShardPatch(_ value: CoreCompactInventoryResultV1) throws -> CoreInventoryCatalogShardPatchV1? {
        try validateEnvelope(value, expectedOperation: .shardPatch)
        guard let tag = CoreInventoryShardPatchOutcomeTag(rawValue: value.shardPatchOutcome) else {
            throw CoreComputeError.malformedResponse
        }
        switch tag {
        case .notPatchable:
            guard value.shardPatchFiles.isEmptyRange, value.shardPatchFolders.isEmptyRange,
                  value.shardPatchChangedFileIDs.isEmptyRange, value.shardPatchLogicalMutationCount == 0
            else { throw CoreComputeError.malformedResponse }
            return nil
        case .patched:
            let files = try decodeFileRecords(value, range: value.shardPatchFiles)
            let folders = try decodeFolderRecords(value, range: value.shardPatchFolders)
            guard let logicalMutationCount = Int(exactly: value.shardPatchLogicalMutationCount) else {
                throw CoreComputeError.malformedResponse
            }
            let changedFileIDs = try decodeUUIDSet(value, range: value.shardPatchChangedFileIDs)
            return CoreInventoryCatalogShardPatchV1(
                files: files,
                folders: folders,
                logicalMutationCount: logicalMutationCount,
                pathIndexChangedFileIDs: changedFileIDs
            )
        }
    }

    static func decodeMerge(
        _ value: CoreCompactInventoryResultV1
    ) throws -> (files: [CoreInventoryFileRecordV1], entries: [CoreInventorySearchCatalogEntryV1]) {
        try validateEnvelope(value, expectedOperation: .mergeShards)
        let files = try decodeFileRecords(value, range: value.mergedFiles)
        let entries = try decodeEntries(value, range: value.mergedEntries)
        guard files.count == entries.count else { throw CoreComputeError.malformedResponse }
        return (files, entries)
    }

    // ---- response envelope (operation tag + inactive-field canonicalization) --------------

    /// Fail-closed guard mirroring the request-side `validate_operation_fields` in `compact.rs`,
    /// but for the response: `compute_*` always builds `InventoryComputeResultV1 { operation,
    /// ..Default::default() }` and only populates the fields its own operation uses, so a
    /// response whose `operation` tag disagrees with what this call requested, or whose
    /// not-this-operation fields are non-default, indicates a transport/decode bug and must be
    /// rejected rather than silently decoded as if it were the expected shape.
    private static func validateEnvelope(
        _ value: CoreCompactInventoryResultV1,
        expectedOperation: CoreInventoryOperation
    ) throws {
        guard value.operation == expectedOperation.rawValue else { throw CoreComputeError.malformedResponse }
        guard value.stringRangeWords.count % coreInventoryStringRangeStride == 0,
              value.uuidWords.count % coreInventoryUUIDStride == 0,
              value.fileWords.count % coreInventoryRecordStride == 0,
              value.folderWords.count % coreInventoryRecordStride == 0,
              value.entryWords.count % coreInventoryEntryStride == 0
        else { throw CoreComputeError.malformedResponse }
        switch expectedOperation {
        case .authoritativeCatalog, .pendingCatalog:
            guard value.shardPatchOutcome == 0, value.shardPatchLogicalMutationCount == 0,
                  value.shardPatchFiles.isEmptyRange, value.shardPatchFolders.isEmptyRange,
                  value.shardPatchChangedFileIDs.isEmptyRange,
                  value.mergedFiles.isEmptyRange, value.mergedEntries.isEmptyRange
            else { throw CoreComputeError.malformedResponse }
        case .shardPatch:
            guard value.componentsFiles.isEmptyRange, value.componentsFolders.isEmptyRange,
                  value.componentsEntries.isEmptyRange,
                  value.mergedFiles.isEmptyRange, value.mergedEntries.isEmptyRange
            else { throw CoreComputeError.malformedResponse }
        case .mergeShards:
            guard value.componentsFiles.isEmptyRange, value.componentsFolders.isEmptyRange,
                  value.componentsEntries.isEmptyRange,
                  value.shardPatchOutcome == 0, value.shardPatchLogicalMutationCount == 0,
                  value.shardPatchFiles.isEmptyRange, value.shardPatchFolders.isEmptyRange,
                  value.shardPatchChangedFileIDs.isEmptyRange
            else { throw CoreComputeError.malformedResponse }
        }
    }

    // ---- shared row decode -----------------------------------------------------------------

    private static func decodeString(_ index: UInt64, value: CoreCompactInventoryResultV1) throws -> String {
        guard let idx = Int(exactly: index) else { throw CoreComputeError.malformedResponse }
        let (rowStart, startOverflow) = idx.multipliedReportingOverflow(by: coreInventoryStringRangeStride)
        let (rowEnd, endOverflow) = rowStart.addingReportingOverflow(coreInventoryStringRangeStride)
        guard !startOverflow, !endOverflow, rowStart >= 0, rowEnd <= value.stringRangeWords.count else {
            throw CoreComputeError.malformedResponse
        }
        let row = value.stringRangeWords[rowStart ..< rowEnd]
        guard let start = Int(exactly: row[row.startIndex]), let end = Int(exactly: row[row.startIndex + 1]) else {
            throw CoreComputeError.malformedResponse
        }
        guard end >= start, end <= value.utf8Blob.count,
              isUTF8Boundary(start, in: value.utf8Blob), isUTF8Boundary(end, in: value.utf8Blob),
              String(data: value.utf8Blob[start ..< end], encoding: .utf8) != nil
        else { throw CoreComputeError.malformedResponse }
        // Non-stripping decode (see the BOM note in `CoreApplyEdits.swift`): keep a legitimate
        // leading U+FEFF byte-aligned with the Rust engine's offsets.
        return String(decoding: value.utf8Blob[start ..< end], as: UTF8.self)
    }

    private static func decodeUUIDAt(_ value: CoreCompactInventoryResultV1, rowIndex: Int) throws -> UUID {
        let (base, baseOverflow) = rowIndex.multipliedReportingOverflow(by: coreInventoryUUIDStride)
        let (end, endOverflow) = base.addingReportingOverflow(coreInventoryUUIDStride)
        guard !baseOverflow, !endOverflow, base >= 0, end <= value.uuidWords.count else {
            throw CoreComputeError.malformedResponse
        }
        return coreInventoryUUID(fromHi: value.uuidWords[base], lo: value.uuidWords[base + 1])
    }

    private static func decodeUUIDList(_ value: CoreCompactInventoryResultV1, range: CoreCompactTableRange) throws -> [UUID] {
        let (start, end) = try checkedRange(poolCount: value.uuidWords.count / coreInventoryUUIDStride, range: range)
        return try (start ..< end).map { try decodeUUIDAt(value, rowIndex: $0) }
    }

    private static func decodeUUIDSet(_ value: CoreCompactInventoryResultV1, range: CoreCompactTableRange) throws -> Set<UUID> {
        Set(try decodeUUIDList(value, range: range))
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

    private static func decodeRecordRow(_ value: CoreCompactInventoryResultV1, row: ArraySlice<UInt64>) throws -> DecodedRecordRow {
        let base = row.startIndex
        let id = coreInventoryUUID(fromHi: row[base], lo: row[base + 1])
        let rootID = coreInventoryUUID(fromHi: row[base + 2], lo: row[base + 3])
        let name = try decodeString(row[base + 4], value: value)
        let relativePath = try decodeString(row[base + 5], value: value)
        let standardizedRelativePath = try decodeString(row[base + 6], value: value)
        let fullPath = try decodeString(row[base + 7], value: value)
        let standardizedFullPath = try decodeString(row[base + 8], value: value)
        let parentFolderID: UUID?
        switch row[base + 9] {
        case 0:
            guard row[base + 10] == 0, row[base + 11] == 0 else { throw CoreComputeError.malformedResponse }
            parentFolderID = nil
        case 1:
            parentFolderID = coreInventoryUUID(fromHi: row[base + 10], lo: row[base + 11])
        default:
            throw CoreComputeError.malformedResponse
        }
        let modificationDate: Date?
        switch row[base + 12] {
        case 0:
            guard row[base + 13] == 0 else { throw CoreComputeError.malformedResponse }
            modificationDate = nil
        case 1:
            let seconds = Double(bitPattern: row[base + 13])
            guard !seconds.isNaN else { throw CoreComputeError.malformedResponse }
            modificationDate = Date(timeIntervalSinceReferenceDate: seconds)
        default:
            throw CoreComputeError.malformedResponse
        }
        return DecodedRecordRow(
            id: id,
            rootID: rootID,
            name: name,
            relativePath: relativePath,
            standardizedRelativePath: standardizedRelativePath,
            fullPath: fullPath,
            standardizedFullPath: standardizedFullPath,
            parentFolderID: parentFolderID,
            modificationDate: modificationDate
        )
    }

    private static func decodeFileRecords(
        _ value: CoreCompactInventoryResultV1,
        range: CoreCompactTableRange
    ) throws -> [CoreInventoryFileRecordV1] {
        let rows = try wordRows(value.fileWords, range: range, stride: coreInventoryRecordStride)
        return try rows.map { row in
            let decoded = try decodeRecordRow(value, row: row[row.startIndex ..< row.endIndex])
            return CoreInventoryFileRecordV1(
                id: decoded.id,
                rootID: decoded.rootID,
                name: decoded.name,
                relativePath: decoded.relativePath,
                standardizedRelativePath: decoded.standardizedRelativePath,
                fullPath: decoded.fullPath,
                standardizedFullPath: decoded.standardizedFullPath,
                parentFolderID: decoded.parentFolderID,
                modificationDate: decoded.modificationDate
            )
        }
    }

    private static func decodeFolderRecords(
        _ value: CoreCompactInventoryResultV1,
        range: CoreCompactTableRange
    ) throws -> [CoreInventoryFolderRecordV1] {
        let rows = try wordRows(value.folderWords, range: range, stride: coreInventoryRecordStride)
        return try rows.map { row in
            let decoded = try decodeRecordRow(value, row: row[row.startIndex ..< row.endIndex])
            return CoreInventoryFolderRecordV1(
                id: decoded.id,
                rootID: decoded.rootID,
                name: decoded.name,
                relativePath: decoded.relativePath,
                standardizedRelativePath: decoded.standardizedRelativePath,
                fullPath: decoded.fullPath,
                standardizedFullPath: decoded.standardizedFullPath,
                parentFolderID: decoded.parentFolderID,
                modificationDate: decoded.modificationDate
            )
        }
    }

    private static func decodeEntries(
        _ value: CoreCompactInventoryResultV1,
        range: CoreCompactTableRange
    ) throws -> [CoreInventorySearchCatalogEntryV1] {
        let rows = try wordRows(value.entryWords, range: range, stride: coreInventoryEntryStride)
        return try rows.map { row in
            let base = row.startIndex
            let id = coreInventoryUUID(fromHi: row[base], lo: row[base + 1])
            let rootID = coreInventoryUUID(fromHi: row[base + 2], lo: row[base + 3])
            let rootPath = try decodeString(row[base + 4], value: value)
            let rootName = try decodeString(row[base + 5], value: value)
            let name = try decodeString(row[base + 6], value: value)
            let relativePath = try decodeString(row[base + 7], value: value)
            let standardizedRelativePath = try decodeString(row[base + 8], value: value)
            let fullPath = try decodeString(row[base + 9], value: value)
            let standardizedFullPath = try decodeString(row[base + 10], value: value)
            let displayPath = try decodeString(row[base + 11], value: value)
            return CoreInventorySearchCatalogEntryV1(
                id: id,
                rootID: rootID,
                rootPath: rootPath,
                rootName: rootName,
                name: name,
                relativePath: relativePath,
                standardizedRelativePath: standardizedRelativePath,
                fullPath: fullPath,
                standardizedFullPath: standardizedFullPath,
                displayPath: displayPath
            )
        }
    }
}

/// Local mirrors of `CoreCodeMap.swift`'s identically-named helpers: those are file-private, so
/// this file (which shares the same `CoreCompactTableRange` type) needs its own copies rather than
/// widening their access.
private func compactBounds(_ range: CoreCompactTableRange) throws -> Range<Int> {
    guard let start = Int(exactly: range.start), let count = Int(exactly: range.count) else {
        throw CoreComputeError.malformedResponse
    }
    let (end, overflow) = start.addingReportingOverflow(count)
    guard !overflow else { throw CoreComputeError.malformedResponse }
    return start ..< end
}

private func wordRows(
    _ values: [UInt64],
    range: CoreCompactTableRange,
    stride: Int
) throws -> [[UInt64]] {
    let rowRange = try compactBounds(range)
    let (start, startOverflow) = rowRange.lowerBound.multipliedReportingOverflow(by: stride)
    let (end, endOverflow) = rowRange.upperBound.multipliedReportingOverflow(by: stride)
    guard !startOverflow, !endOverflow, start >= 0, end <= values.count else {
        throw CoreComputeError.malformedResponse
    }
    var rows: [[UInt64]] = []
    rows.reserveCapacity(rowRange.count)
    var cursor = start
    while cursor < end {
        rows.append(Array(values[cursor ..< cursor + stride]))
        cursor += stride
    }
    return rows
}

private func isUTF8Boundary(_ offset: Int, in data: Data) -> Bool {
    offset == 0 || offset == data.count || (offset > 0 && offset < data.count && data[offset] & 0xC0 != 0x80)
}

private func checkedRange(poolCount: Int, range: CoreCompactTableRange) throws -> (Int, Int) {
    let bounds = try compactBounds(range)
    guard bounds.lowerBound >= 0, bounds.upperBound <= poolCount else { throw CoreComputeError.malformedResponse }
    return (bounds.lowerBound, bounds.upperBound)
}

private extension CoreCompactTableRange {
    var isEmptyRange: Bool { start == 0 && count == 0 }
}
