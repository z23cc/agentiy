import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceProjectionAuthorityTests: XCTestCase {
    func testAggregateReconstructsProjectionAcrossRestartWithoutCompatibilityState() async throws {
        let directory = temporaryDirectory(name: "ProjectionAggregateRestart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = configuration(directory: directory)
        let workspaceID = UUID()
        let workspaceFileURL = configuration.workspaceStorageDirectory
            .appendingPathComponent("Restarted-\(workspaceID.uuidString)", isDirectory: true)
            .appendingPathComponent("workspace.json")
        let value = try document(
            workspaceID: workspaceID,
            name: "Restarted",
            prompt: "durable / projection",
            selectedPaths: ["Zeta/Feature.swift", "Alpha/App.swift"],
            fileURL: workspaceFileURL
        )
        let contextMetadata = try XCTUnwrap(value.metadata.contexts.first)
        let canonicalContext = try XCTUnwrap(String(data: contextMetadata.documentBytes, encoding: .utf8))
        XCTAssertTrue(canonicalContext.contains("Alpha/App.swift"))
        XCTAssertFalse(canonicalContext.contains("\\/"))
        XCTAssertEqual(
            contextMetadata.contentDigest,
            DomainContentDigest.sha256(contextMetadata.documentBytes)
        )

        let first = MCPDomainRuntime(configuration: configuration)
        try await first.start()
        let initial = await first.workspaceStore.snapshot()
        let created = await first.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: initial.catalogRevision,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(value)
        ))
        XCTAssertEqual(created.disposition, .applied)
        let firstRead = await first.contextStore.workspaceAuthoritativeReadFence(workspaceID)
        XCTAssertEqual(firstRead?.projection.contexts.first?.prompt, "durable / projection")
        _ = await first.shutdown()

        let second = MCPDomainRuntime(configuration: configuration)
        try await second.start()
        let secondRead = await second.contextStore.workspaceAuthoritativeReadFence(workspaceID)
        XCTAssertEqual(secondRead?.workspace.document.contentDigest, value.contentDigest)
        XCTAssertEqual(secondRead?.projection.contexts.first?.prompt, "durable / projection")
        XCTAssertEqual(secondRead?.projectionDigest.count, 64)
        _ = await second.shutdown()
    }

    func testContendingRuntimeReadsAggregateButCannotMutateUntilLeaseHandoff() async throws {
        let directory = temporaryDirectory(name: "ProjectionAggregateContention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = configuration(directory: directory)
        let holder = MCPDomainRuntime(configuration: configuration)
        try await holder.start()
        let workspaceID = UUID()
        let workspaceFileURL = configuration.workspaceStorageDirectory
            .appendingPathComponent("Takeover-\(workspaceID.uuidString)", isDirectory: true)
            .appendingPathComponent("workspace.json")
        let initial = await holder.workspaceStore.snapshot()
        let created = await holder.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: initial.catalogRevision,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(try document(
                workspaceID: workspaceID,
                name: "Takeover",
                fileURL: workspaceFileURL
            ))
        ))
        XCTAssertEqual(created.disposition, .applied)

        let contender = MCPDomainRuntime(configuration: configuration)
        try await contender.start()
        let contendedSnapshot = await contender.snapshot()
        let contendedRead = await contender.contextStore.workspaceAuthoritativeReadFence(workspaceID)
        XCTAssertEqual(contendedSnapshot.lifecycle, .degraded)
        XCTAssertEqual(contendedRead?.workspace.document.workspaceID, workspaceID)

        _ = await holder.shutdown()
        let tookOver = await waitFor(timeoutIterations: 500) {
            await contender.snapshot().lifecycle == .ready
        }
        XCTAssertTrue(tookOver)
        let takeoverRead = await contender.contextStore.workspaceAuthoritativeReadFence(workspaceID)
        XCTAssertEqual(takeoverRead?.workspace.document.workspaceID, workspaceID)
        _ = await contender.shutdown()
    }

    func testLegacyProjectionArtifactsAreIgnoredAndRemainUnchanged() async throws {
        let directory = temporaryDirectory(name: "ProjectionLegacyArtifact")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = configuration(directory: directory)
        let workspaceID = UUID()
        let workspaceFileURL = configuration.workspaceStorageDirectory
            .appendingPathComponent("Legacy-\(workspaceID.uuidString)", isDirectory: true)
            .appendingPathComponent("workspace.json")
        let value = try document(
            workspaceID: workspaceID,
            name: "Durable Authority",
            prompt: "artifact ignored",
            fileURL: workspaceFileURL
        )

        let writer = MCPDomainRuntime(configuration: configuration)
        try await writer.start()
        let initial = await writer.workspaceStore.snapshot()
        let created = await writer.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: initial.catalogRevision,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(value)
        ))
        XCTAssertEqual(created.disposition, .applied)
        _ = await writer.shutdown()

        let artifactURL = configuration.workspaceStorageDirectory
            .appendingPathComponent(".agentry-domain-runtime/workspace-projection", isDirectory: true)
            .appendingPathComponent("checkpoint-v1.json")
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let variants: [LegacyArtifactVariant] = [
            .bytes(Data("{\"version\":1,\"scopeId\":\"00000000-0000-0000-0000-000000000001\",\"generation\":0,\"catalogRevision\":0,\"publicationSequence\":0,\"eventLogFloorSequence\":1,\"entries\":[],\"events\":[]}".utf8)),
            .bytes(Data("not-json".utf8)),
            .oversizedSparse
        ]

        for variant in variants {
            try seed(variant, at: artifactURL)
            let before = try fingerprint(artifactURL)
            if case .bytes = variant {
                XCTAssertNotNil(before.completeDigest)
            }
            let runtime = MCPDomainRuntime(configuration: configuration)
            try await runtime.start()
            let read = await runtime.contextStore.workspaceAuthoritativeReadFence(workspaceID)
            XCTAssertEqual(read?.workspace.document.contentDigest, value.contentDigest)
            XCTAssertEqual(read?.projection.contexts.first?.prompt, "artifact ignored")
            _ = await runtime.shutdown()
            XCTAssertEqual(try fingerprint(artifactURL), before)
        }
    }

    private enum LegacyArtifactVariant {
        case bytes(Data)
        case oversizedSparse
    }

    private struct ArtifactFingerprint: Equatable {
        let fileNumber: UInt64
        let size: UInt64
        let modificationDate: Date
        let permissions: Int
        let completeDigest: String?
        let prefix: Data
        let suffix: Data
    }

    private func seed(_ variant: LegacyArtifactVariant, at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        switch variant {
        case let .bytes(data):
            try data.write(to: url)
        case .oversizedSparse:
            _ = FileManager.default.createFile(atPath: url.path, contents: Data("legacy-prefix".utf8))
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: UInt64(128 * 1024 * 1024 + 1 - 13))
            try handle.write(contentsOf: Data("legacy-suffix".utf8))
            try handle.close()
        }
    }

    private func fingerprint(_ url: URL) throws -> ArtifactFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let handle = try FileHandle(forReadingFrom: url)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let completeDigest: String? = if size <= 1024 * 1024 {
            DomainContentDigest.sha256(try Data(contentsOf: url))
        } else {
            nil
        }
        let prefix = try handle.read(upToCount: 32) ?? Data()
        try handle.seek(toOffset: size > 32 ? size - 32 : 0)
        let suffix = try handle.read(upToCount: 32) ?? Data()
        try handle.close()
        return ArtifactFingerprint(
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: size,
            modificationDate: try XCTUnwrap(attributes[.modificationDate] as? Date),
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
            completeDigest: completeDigest,
            prefix: prefix,
            suffix: suffix
        )
    }

    private func document(
        workspaceID: UUID = UUID(),
        name: String,
        prompt: String = "prompt",
        selectedPaths: [String] = ["Sources/App.swift"],
        fileURL: URL? = nil
    ) throws -> DomainWorkspaceDocument {
        let contextID = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": name,
            "repoPaths": ["/repo/\(name)"],
            "activeComposeTabID": contextID.uuidString,
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": prompt,
                "selectedPaths": selectedPaths
            ]]
        ], options: [.sortedKeys])
        return try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: fileURL ?? URL(fileURLWithPath: "/tmp/\(workspaceID.uuidString).json")
        )
    }

    private func configuration(directory: URL) -> DomainRuntimeConfiguration {
        DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "projection-authority-tests-\(UUID().uuidString)",
            storageDirectory: directory,
            eventDirectory: directory.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: directory.appendingPathComponent("Temp", isDirectory: true),
            externalReloadInterval: nil
        )
    }

    private func temporaryDirectory(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPrompt-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func waitFor(
        timeoutIterations: Int = 200,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< timeoutIterations {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
