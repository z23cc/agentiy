import AgentryCoreBridge
@testable import RepoPromptSearchCore
import XCTest

final class SearchPathFilteringTests: XCTestCase {
    private let rootA = "/tmp/RepoPromptSearchRootA"
    private let rootB = "/tmp/RepoPromptSearchRootB"

    private func snapshot(root: String, relativePath: String, displayPath: String? = nil) -> FileSearchPathSnapshot {
        FileSearchPathSnapshot(
            standardizedFullPath: "\(root)/\(relativePath)",
            standardizedRelativePath: relativePath,
            standardizedRootPath: root,
            clientDisplayPath: displayPath ?? relativePath
        )
    }

    func testExactFileAndFolderMatchesRespectRestrictedRoots() async throws {
        let bridge = try await AgentryCoreBridge.start()
        defer { Task { _ = try? await bridge.close() } }
        let client = try await bridge.searchClient()
        let snapshots = [
            snapshot(root: rootA, relativePath: "Sources/App/View.swift"),
            snapshot(root: rootA, relativePath: "Sources/App/Model.swift"),
            snapshot(root: rootB, relativePath: "Sources/App/View.swift")
        ]

        let exactFile = SearchPathFilterSpec(
            caseInsensitive: true,
            clauses: [
                .exactFile(
                    absPath: "\(rootB)/Sources/App/View.swift",
                    relPath: "Sources/App/Model.swift",
                    restrictedRootPath: rootA
                )
            ]
        )
        let exactFileResult = try await filterPathIndicesResult(snapshots: snapshots, spec: exactFile, client: client)
        XCTAssertEqual(exactFileResult.matchedSnapshotIndices, [1, 2])

        let exactFolder = SearchPathFilterSpec(
            caseInsensitive: true,
            clauses: [
                .exactFolder(
                    absLower: "\(rootA)/sources/app",
                    relLower: "sources/app",
                    restrictedRootPath: rootA
                )
            ]
        )
        let exactFolderResult = try await filterPathIndicesResult(snapshots: snapshots, spec: exactFolder, client: client)
        XCTAssertEqual(exactFolderResult.matchedSnapshotIndices, [0, 1])
    }

    func testGlobMatchesDisplayRelativeAndFullPaths() async throws {
        let bridge = try await AgentryCoreBridge.start()
        defer { Task { _ = try? await bridge.close() } }
        let client = try await bridge.searchClient()
        let snapshots = [
            snapshot(root: rootA, relativePath: "Sources/App/View.swift", displayPath: "App/Sources/App/View.swift"),
            snapshot(root: rootA, relativePath: "Sources/Domain/Model.swift", displayPath: "App/Sources/Domain/Model.swift"),
            snapshot(root: rootB, relativePath: "Docs/Notes.md", displayPath: "Lib/Docs/Notes.md")
        ]

        let spec = SearchPathFilterSpec(
            caseInsensitive: true,
            clauses: [
                .glob(pattern: "App/**/View.swift", restrictedRootPath: rootA),
                .glob(pattern: "Sources/**/Model.swift", restrictedRootPath: rootA),
                .glob(pattern: "\(rootB)/**/Notes.md", restrictedRootPath: rootB)
            ]
        )

        let result = try await filterPathIndicesResult(snapshots: snapshots, spec: spec, client: client)
        XCTAssertEqual(result.matchedSnapshotIndices, [0, 1, 2])
        XCTAssertEqual(result.visitedSnapshotCount, 3)
        XCTAssertFalse(result.cancelled)
    }

    func testLegacyPrefixMatchesDisplayPathAndDeduplicatesInInputOrder() async throws {
        let bridge = try await AgentryCoreBridge.start()
        defer { Task { _ = try? await bridge.close() } }
        let client = try await bridge.searchClient()
        let snapshots = [
            snapshot(root: rootA, relativePath: "Sources/App/View.swift", displayPath: "App/Sources/App/View.swift"),
            snapshot(root: rootA, relativePath: "Sources/App/Model.swift", displayPath: "App/Sources/App/Model.swift"),
            snapshot(root: rootA, relativePath: "Tests/AppTests.swift", displayPath: "App/Tests/AppTests.swift")
        ]

        let spec = SearchPathFilterSpec(
            caseInsensitive: true,
            clauses: [
                .legacyPrefix(candidateLower: "app/sources/app"),
                .exactFile(absPath: "\(rootA)/Sources/App/View.swift", relPath: "Sources/App/View.swift", restrictedRootPath: rootA)
            ]
        )

        let result = try await filterPathIndicesResult(snapshots: snapshots, spec: spec, client: client)
        XCTAssertEqual(result.matchedSnapshotIndices, [0, 1])
        let fullPaths = try await filterPaths(snapshots: snapshots, spec: spec, client: client)
        XCTAssertEqual(fullPaths, [
            "\(rootA)/Sources/App/View.swift",
            "\(rootA)/Sources/App/Model.swift"
        ])
    }

    func testCancelledTaskReportsCancellationMetadata() async throws {
        let bridge = try await AgentryCoreBridge.start()
        defer { Task { _ = try? await bridge.close() } }
        let client = try await bridge.searchClient()
        let snapshots = (0 ..< 50000).map { index in
            snapshot(root: rootA, relativePath: "Sources/File\(index).swift")
        }
        let spec = SearchPathFilterSpec(
            caseInsensitive: true,
            clauses: [.legacyPrefix(candidateLower: "sources")]
        )

        let cancellationGate = SearchPathFilteringCancellationGate()
        let task = Task.detached(priority: .background) {
            // Shared cancellation gate resumes with CancellationError; continue into filter.
            try? await cancellationGate.waitUntilCancelled()
            return try await filterPathIndicesResult(snapshots: snapshots, spec: spec, client: client)
        }
        await cancellationGate.waitUntilEntered()
        task.cancel()
        let result = try await task.value

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.visitedSnapshotCount, 0)
    }
}

/// Search path filter cancel handshake (shared `TestCancellationGate`).
///
/// Note: resumes with `CancellationError` on cancel (stricter than the old Never-continuation
/// version, which treated cancel as a non-throwing resume). Call sites only assert cancellation.
private typealias SearchPathFilteringCancellationGate = TestCancellationGate
