import Foundation

/// Deterministic, side-effect-free ordering helpers for the workspace file/folder inventory.
///
/// These functions define the sort order used to build catalog shards, search catalog entries,
/// and path indexes. They intentionally take only value types (`WorkspaceFileRecord`,
/// `WorkspaceFolderRecord`, `WorkspaceSearchCatalogEntry`, `String`) so they can be ported to
/// Rust 1:1 as part of the P3-2 catalog-shard/index-construction port.
///
/// Extracted from `WorkspaceFileContextStore` (P3-1). DO NOT change comparison semantics or sort
/// order here — any ordering-policy change (e.g. to Rust natural sort) is explicitly out of scope
/// for this extraction and belongs to P3-2.
enum WorkspaceInventoryOrdering {
    /// Byte-for-byte UTF-8 ordering, independent of locale/Unicode canonicalization.
    static func compareUTF8Binary(_ lhs: String, _ rhs: String) -> ComparisonResult {
        var lhsIterator = lhs.utf8.makeIterator()
        var rhsIterator = rhs.utf8.makeIterator()
        while true {
            switch (lhsIterator.next(), rhsIterator.next()) {
            case let (lhsByte?, rhsByte?):
                if lhsByte < rhsByte { return .orderedAscending }
                if lhsByte > rhsByte { return .orderedDescending }
            case (nil, nil):
                return .orderedSame
            case (nil, _?):
                return .orderedAscending
            case (_?, nil):
                return .orderedDescending
            }
        }
    }

    /// Multi-root file ordering, keyed on each file's standardized full (root-qualified) path.
    static func searchCatalogFilePrecedes(_ lhs: WorkspaceFileRecord, _ rhs: WorkspaceFileRecord) -> Bool {
        searchCatalogFilePrecedes(
            lhsPath: lhs.standardizedFullPath,
            lhsID: lhs.id,
            rhsPath: rhs.standardizedFullPath,
            rhsID: rhs.id
        )
    }

    /// Single-root file ordering, keyed on each file's standardized root-relative path.
    static func searchRootCatalogFilePrecedes(
        _ lhs: WorkspaceFileRecord,
        _ rhs: WorkspaceFileRecord
    ) -> Bool {
        searchCatalogFilePrecedes(
            lhsPath: lhs.standardizedRelativePath,
            lhsID: lhs.id,
            rhsPath: rhs.standardizedRelativePath,
            rhsID: rhs.id
        )
    }

    /// Search catalog entry ordering, keyed on each entry's standardized full (root-qualified) path.
    static func searchCatalogEntryPrecedes(
        _ lhs: WorkspaceSearchCatalogEntry,
        _ rhs: WorkspaceSearchCatalogEntry
    ) -> Bool {
        searchCatalogFilePrecedes(
            lhsPath: lhs.standardizedFullPath,
            lhsID: lhs.id,
            rhsPath: rhs.standardizedFullPath,
            rhsID: rhs.id
        )
    }

    private static func searchCatalogFilePrecedes(
        lhsPath: String,
        lhsID: UUID,
        rhsPath: String,
        rhsID: UUID
    ) -> Bool {
        switch compareUTF8Binary(lhsPath, rhsPath) {
        case .orderedAscending:
            true
        case .orderedDescending:
            false
        case .orderedSame:
            compareUTF8Binary(lhsID.uuidString, rhsID.uuidString) == .orderedAscending
        }
    }

    /// Folder ordering. NOTE: unlike the file/entry comparators above, this uses Swift's native
    /// `String` `<`/`==` (Unicode canonical ordering), not `compareUTF8Binary`. This is existing
    /// behavior, preserved verbatim by this extraction — do not unify it with the byte-order
    /// comparators.
    static func searchCatalogFolderPrecedes(_ lhs: WorkspaceFolderRecord, _ rhs: WorkspaceFolderRecord) -> Bool {
        if lhs.standardizedFullPath == rhs.standardizedFullPath {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.standardizedFullPath < rhs.standardizedFullPath
    }
}
