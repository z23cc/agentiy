import AgentryCoreBridge
import Foundation

package enum SearchPathClause: Equatable {
    case exactFile(absPath: String, relPath: String, restrictedRootPath: String?)
    case exactFolder(absLower: String, relLower: String, restrictedRootPath: String?)
    case glob(pattern: String, restrictedRootPath: String?)
    case legacyPrefix(candidateLower: String)
}

package struct SearchPathFilterSpec: Equatable {
    package let caseInsensitive: Bool
    package let clauses: [SearchPathClause]

    package init(caseInsensitive: Bool, clauses: [SearchPathClause]) {
        self.caseInsensitive = caseInsensitive
        self.clauses = clauses
    }
}

package struct FileSearchPathSnapshot {
    package let standardizedFullPath: String
    package let standardizedRelativePath: String
    package let standardizedRootPath: String
    package let clientDisplayPath: String

    package init(
        standardizedFullPath: String,
        standardizedRelativePath: String,
        standardizedRootPath: String,
        clientDisplayPath: String
    ) {
        self.standardizedFullPath = standardizedFullPath
        self.standardizedRelativePath = standardizedRelativePath
        self.standardizedRootPath = standardizedRootPath
        self.clientDisplayPath = clientDisplayPath
    }
}

package struct FileSearchPathFilterResult: Equatable {
    package let matchedFullPaths: [String]
    package let visitedSnapshotCount: Int
    package let cancelled: Bool
}

/// Index-returning variant of `FileSearchPathFilterResult`. `matchedSnapshotIndices`
/// holds indices into the input `snapshots` array, in snapshot iteration order, with
/// each snapshot appearing at most once. Lets callers map matches directly back to
/// their source array without a full-path string round trip.
package struct FileSearchPathIndexFilterResult: Equatable {
    package let matchedSnapshotIndices: [Int]
    package let visitedSnapshotCount: Int
    package let cancelled: Bool
}

package func filterPaths(
    snapshots: [FileSearchPathSnapshot],
    spec: SearchPathFilterSpec,
    client: CoreSearchClient
) async throws -> [String] {
    try await filterPathsResult(snapshots: snapshots, spec: spec, client: client).matchedFullPaths
}

package func filterPathsResult(
    snapshots: [FileSearchPathSnapshot],
    spec: SearchPathFilterSpec,
    client: CoreSearchClient
) async throws -> FileSearchPathFilterResult {
    let indexResult = try await filterPathIndicesResult(snapshots: snapshots, spec: spec, client: client)
    var results: [String] = []
    results.reserveCapacity(indexResult.matchedSnapshotIndices.count)
    for index in indexResult.matchedSnapshotIndices {
        results.append(snapshots[index].standardizedFullPath)
    }
    return FileSearchPathFilterResult(
        matchedFullPaths: results,
        visitedSnapshotCount: indexResult.visitedSnapshotCount,
        cancelled: indexResult.cancelled
    )
}

/// Core scoped-path filter loop. Returns matched snapshot indices (in input order,
/// deduplicated) plus visited/cancellation metadata. Lowercase path variants are
/// computed lazily per snapshot so exact-file and glob clauses — which never need
/// them — do not pay for lowercasing.
package func filterPathIndicesResult(
    snapshots: [FileSearchPathSnapshot],
    spec: SearchPathFilterSpec,
    client: CoreSearchClient
) async throws -> FileSearchPathIndexFilterResult {
    let result = try await client.filterPaths(CorePathFilterRequest(
        snapshots: snapshots.map {
            CorePathSnapshot(
                standardizedFullPath: $0.standardizedFullPath,
                standardizedRelativePath: $0.standardizedRelativePath,
                standardizedRootPath: $0.standardizedRootPath,
                clientDisplayPath: $0.clientDisplayPath
            )
        },
        clauses: spec.clauses.map { clause in
            switch clause {
            case let .exactFile(absPath, relPath, restrictedRootPath):
                .exactFile(absPath: absPath, relPath: relPath, restrictedRootPath: restrictedRootPath)
            case let .exactFolder(absLower, relLower, restrictedRootPath):
                .exactFolder(absLower: absLower, relLower: relLower, restrictedRootPath: restrictedRootPath)
            case let .glob(pattern, restrictedRootPath):
                .glob(pattern: pattern, restrictedRootPath: restrictedRootPath)
            case let .legacyPrefix(candidateLower):
                .legacyPrefix(candidateLower: candidateLower)
            }
        },
        caseInsensitive: spec.caseInsensitive
    ))
    return FileSearchPathIndexFilterResult(
        matchedSnapshotIndices: result.matchedSnapshotIndices.map(Int.init),
        visitedSnapshotCount: Int(result.visitedSnapshotCount),
        cancelled: result.cancelled
    )
}

// MARK: - Folder fragment resolution (filter.paths)

private let folderSuffixSlashTrim = CharacterSet(charactersIn: "/")

@inline(__always)
package func normalizedFolderSuffixFragment(_ fragment: String, caseInsensitive: Bool = true) -> String? {
    let standardized = (fragment as NSString).standardizingPath as String
    let trimmed = standardized.trimmingCharacters(in: folderSuffixSlashTrim)
    guard !trimmed.isEmpty else { return nil }
    return caseInsensitive ? trimmed.lowercased() : trimmed
}

package struct SearchFolderSuffixIndexEntry<T> {
    package let folder: T
    package let normalizedRelativePath: String
}

package typealias SearchFolderSuffixIndex<T> = [String: [SearchFolderSuffixIndexEntry<T>]]

package func buildFolderSuffixIndex<T>(
    in foldersByFullPath: [String: T],
    relativePath: (T) -> String,
    caseInsensitive: Bool = true
) -> SearchFolderSuffixIndex<T> {
    var index: SearchFolderSuffixIndex<T> = [:]
    index.reserveCapacity(max(16, foldersByFullPath.count / 2))

    for (_, folder) in foldersByFullPath {
        guard let normalizedRel = normalizedFolderSuffixFragment(relativePath(folder), caseInsensitive: caseInsensitive),
              let lastComponent = normalizedRel.split(separator: "/").last.map(String.init),
              !lastComponent.isEmpty
        else {
            continue
        }
        index[lastComponent, default: []].append(SearchFolderSuffixIndexEntry(
            folder: folder,
            normalizedRelativePath: normalizedRel
        ))
    }

    return index
}

package func resolveFoldersBySuffixFragment<T>(
    _ fragment: String,
    using suffixIndex: SearchFolderSuffixIndex<T>,
    caseInsensitive: Bool = true,
    client: CoreSearchClient
) async throws -> [T] {
    let entries = suffixIndex.values.flatMap(\.self)
    let indices = try await client.folderSuffixIndices(CoreFolderSuffixRequest(
        fragment: fragment,
        relativePaths: entries.map(\.normalizedRelativePath),
        caseInsensitive: caseInsensitive
    ))
    return indices.map { entries[Int($0)].folder }
}

package func resolveFoldersBySuffixFragment<T>(
    _ fragment: String,
    in foldersByFullPath: [String: T],
    relativePath: (T) -> String,
    caseInsensitive: Bool = true,
    client: CoreSearchClient
) async throws -> [T] {
    let index = buildFolderSuffixIndex(
        in: foldersByFullPath,
        relativePath: relativePath,
        caseInsensitive: caseInsensitive
    )
    return try await resolveFoldersBySuffixFragment(
        fragment,
        using: index,
        caseInsensitive: caseInsensitive,
        client: client
    )
}
