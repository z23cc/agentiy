import AgentryCoreBridge
@testable import RepoPromptApp
import XCTest

final class WorkspaceInventoryScopeAuthorityTests: XCTestCase {
    func testLoadedEmptyRootDegradesNoPublishedGenerationToAnEmptyIndexOnly() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceInventoryScopeAuthorityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = WorkspaceFileContextStore()
        let root = try await store.loadRoot(path: rootURL.path)
        let files = await store.files(inRoot: root.id)
        let folders = await store.folders(inRoot: root.id)

        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(folders.map(\.standardizedRelativePath), [""])
        XCTAssertEqual(folders.first?.id, root.id)
    }

    func testReadOrderedSnapshotAggregatesEveryPageInRustPublishedOrderAndFencesLifetime() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let authority = WorkspaceInventoryScopeAuthority(bridge: bridge)
        let rootID = UUID()
        let swiftLifetimeID = UUID()
        _ = try await authority.openRootIfNeeded(
            rootID: rootID,
            swiftLifetimeID: swiftLifetimeID,
            name: "root",
            standardizedFullPath: "/repo"
        )

        let receipt = try await authority.bulkSeedDiscovery(
            rootID: rootID,
            files: ["C.swift", "A.swift", "B.swift"].map { discoveredFile(rootID: rootID, relativePath: $0) },
            folders: ["D", "B", "A", "C"].map { discoveredFolder(rootID: rootID, relativePath: $0) },
            chunkSize: 2
        )

        let read = try await authority.readOrderedSnapshot(
            rootID: rootID,
            expectedSwiftLifetimeID: swiftLifetimeID,
            pageSize: 2
        )
        XCTAssertEqual(read.generation, receipt.generation)
        XCTAssertEqual(read.rootLifetimeID, receipt.rootLifetimeID)
        XCTAssertEqual(read.files.map(\.standardizedRelativePath), ["A.swift", "B.swift", "C.swift"])
        XCTAssertEqual(read.folders.map(\.standardizedRelativePath), ["A", "B", "C", "D"])
        let diagnosticsAfterRead = try await authority.diagnostics()
        XCTAssertEqual(diagnosticsAfterRead.openHandleCount, 0)

        do {
            _ = try await authority.readOrderedSnapshot(
                rootID: rootID,
                expectedSwiftLifetimeID: UUID(),
                pageSize: 2
            )
            XCTFail("a stale Swift lifetime must not read the current Rust generation")
        } catch let error as WorkspaceInventoryScopeAuthorityError {
            XCTAssertEqual(error, .swiftLifetimeMismatch(rootID))
        }
        let diagnosticsAfterRejectedRead = try await authority.diagnostics()
        XCTAssertEqual(diagnosticsAfterRejectedRead.openHandleCount, 0)

        await authority.close()
        _ = try await bridge.close()
    }

    private func discoveredFile(rootID: UUID, relativePath: String) -> CoreDiscoveredFileRecordV1 {
        CoreDiscoveredFileRecordV1(
            rootID: rootID,
            name: relativePath,
            relativePath: relativePath,
            standardizedRelativePath: relativePath,
            fullPath: "/repo/\(relativePath)",
            standardizedFullPath: "/repo/\(relativePath)",
            parentFolderID: nil,
            modificationDate: nil
        )
    }

    private func discoveredFolder(rootID: UUID, relativePath: String) -> CoreDiscoveredFolderRecordV1 {
        CoreDiscoveredFolderRecordV1(
            rootID: rootID,
            name: relativePath,
            relativePath: relativePath,
            standardizedRelativePath: relativePath,
            fullPath: "/repo/\(relativePath)",
            standardizedFullPath: "/repo/\(relativePath)",
            parentFolderID: nil,
            modificationDate: nil
        )
    }
}
