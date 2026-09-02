import Foundation
@testable import RepoPromptApp

enum WorkspaceCodemapProvenanceTestSupportError: Error {
    case capabilityUnavailable
}

enum WorkspaceCodemapValidatedSnapshotTestSupport {
    static func cleanSource(
        bytes: Data,
        objectFormat: GitObjectFormat,
        namespaceScope: String = "shared"
    ) async throws -> CodeMapSourceSnapshot {
        let capability = try await WorkspaceCodemapCapabilityTestPool.capability(
            objectFormat: objectFormat,
            namespaceScope: namespaceScope
        )
        let blobOID = GitBlobOID.blob(bytes: bytes, objectFormat: objectFormat)
        let materializer = GitBlobSourceMaterializationService(
            client: GitBlobSourceMaterializationClient(
                size: { _, _ in UInt64(bytes.count) },
                bytes: { _, _, _ in bytes }
            )
        )
        let validated = try await materializer.materialize(
            capability: capability,
            blobOID: blobOID
        )
        return CodeMapSourceSnapshot(validatedGitBlob: validated)
    }
}

private enum WorkspaceCodemapCapabilityTestPool {
    private final class Context: @unchecked Sendable {
        let repositoryFixture: ReviewGitRepositoryFixture
        let capability: GitCodemapRootCapability

        init(
            repositoryFixture: ReviewGitRepositoryFixture,
            capability: GitCodemapRootCapability
        ) {
            self.repositoryFixture = repositoryFixture
            self.capability = capability
        }
    }

    private actor Cache {
        private var contexts: [String: Context] = [:]
        private var inFlight: [String: Task<Context, Error>] = [:]

        func capability(
            objectFormat: GitObjectFormat,
            namespaceScope: String
        ) async throws -> GitCodemapRootCapability {
            let key = objectFormat.rawValue + "|" + namespaceScope
            if let context = contexts[key] {
                return context.capability
            }
            if let task = inFlight[key] {
                return try await task.value.capability
            }

            let task = Task<Context, Error> {
                try await WorkspaceCodemapCapabilityTestPool.makeContext(objectFormat: objectFormat)
            }
            inFlight[key] = task
            do {
                let context = try await task.value
                contexts[key] = context
                inFlight[key] = nil
                return context.capability
            } catch {
                inFlight[key] = nil
                throw error
            }
        }
    }

    private static let cache = Cache()

    static func capability(
        objectFormat: GitObjectFormat,
        namespaceScope: String
    ) async throws -> GitCodemapRootCapability {
        try await cache.capability(
            objectFormat: objectFormat,
            namespaceScope: namespaceScope
        )
    }

    private static func makeContext(objectFormat: GitObjectFormat) async throws -> Context {
        let fixture = try ReviewGitRepositoryFixture(
            name: "WorkspaceCodemapCapabilityTestPool-\(objectFormat.rawValue)-\(UUID().uuidString)"
        )
        let root = try fixture.makeRepository(
            named: "repository",
            files: ["Sources/Fixture.swift": SwiftFixtureSource.emptyStruct("Fixture")],
            objectFormat: objectFormat
        )
        let service = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: Data(
                repeating: 0x6B,
                count: GitBlobRepositoryNamespace.saltByteCount
            )
        )
        let state = await service.resolve(
            root: WorkspaceCodemapGitCapabilityRequest(
                rootID: UUID(),
                rootLifetimeID: UUID(),
                loadedRootURL: root
            )
        )
        guard case let .eligible(capability) = state else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        return Context(
            repositoryFixture: fixture,
            capability: capability
        )
    }
}
