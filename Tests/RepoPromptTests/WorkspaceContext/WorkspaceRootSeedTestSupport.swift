import Foundation
@testable import RepoPromptApp

enum WorkspaceRootSeedTestSupport {
    static func oid(_ scalar: Character = "1") -> GitObjectID {
        try! GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: scalar, count: 40))
    }

    static func compatibilityKey(
        treeOID: GitObjectID = oid(),
        prefix: GitRepositoryRelativeRootPrefix = try! GitRepositoryRelativeRootPrefix(""),
        committedIgnoreDigest: String = "ignore",
        canonicalizationDiagnostics: GitWorkspacePolicyCanonicalizationDiagnostics? = nil
    ) -> WorkspaceRootSeedCompatibilityKey {
        let root = URL(fileURLWithPath: "/tmp/workspace-root-seed-tests")
        let git = root.appendingPathComponent(".git", isDirectory: true)
        let layout = GitRepositoryLayout(
            workTreeRoot: root,
            dotGitPath: git,
            gitDir: git,
            commonDir: git,
            isWorktree: false
        )
        let policy = GitWorkspacePolicyIdentity(
            mandatoryIgnorePolicyIdentity: canonicalizationDiagnostics?.canonicalizationPolicyVersion
                ?? WorkspaceGitignorePolicyIdentity.current.rawValue,
            committedIgnoreControlDigest: canonicalizationDiagnostics?.canonicalIgnoreFooter.digest
                ?? committedIgnoreDigest,
            configuredIgnoreAuthorityDigest: canonicalizationDiagnostics?.configuredIgnorePolicyDigest
                ?? "configured-ignore",
            attributePolicyDigest: canonicalizationDiagnostics?.attributePolicyDigest ?? "attributes",
            sparsePolicyDigest: canonicalizationDiagnostics?.sparsePolicyDigest ?? "sparse-disabled",
            searchABI: .current,
            resolvedExcludesFileIdentity: nil,
            resolvedAttributesFileIdentity: nil,
            canonicalizationDiagnostics: canonicalizationDiagnostics
        )
        let authority = GitWorkspaceAuthoritySnapshot(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey(layout: layout),
            repositoryNamespace: try! GitBlobRepositoryNamespace(rawValue: String(repeating: "a", count: 64)),
            objectFormat: .sha1,
            headCommitOID: oid("b"),
            treeOID: treeOID,
            repositoryRelativeRootPrefix: prefix,
            repositoryBindingEpoch: "repository",
            worktreeBindingEpoch: "worktree",
            layoutGeneration: "layout",
            indexGeneration: "index",
            checkoutConfigurationGeneration: "checkout",
            metadataGeneration: "metadata",
            policyIdentity: policy
        )
        return WorkspaceRootSeedCompatibilityKey(authority: authority)
    }

    static func snapshot(
        paths: [(String, String)],
        treeOID: GitObjectID = oid(),
        prefix: GitRepositoryRelativeRootPrefix = try! GitRepositoryRelativeRootPrefix(""),
        policyIgnoredPaths: Set<String> = [],
        catalogPolicyIdentity: WorkspaceRootCatalogPolicyIdentity = .canonicalDefaults
    ) async throws -> WorkspaceRootReusableSnapshot {
        let compatibility = compatibilityKey(treeOID: treeOID, prefix: prefix)
        let store = try WorkspaceRootReusableInventoryManifestStore()
        let writer = try store.makeWriter(header: WorkspaceRootReusableInventoryManifestHeader(
            compatibilityDomain: WorkspaceRootReusableSnapshot.manifestCompatibilityDomain,
            compatibilityDigest: WorkspaceRootReusableSnapshot.compatibilityDigest(compatibility),
            treeOID: treeOID,
            objectFormat: treeOID.objectFormat,
            repositoryRelativeRootPrefix: prefix,
            commandFormat: "test-fixture-v1",
            rawStandardOutputDigest: Data(repeating: 0, count: 32),
            catalogPolicyDigest: WorkspaceRootReusableSnapshot.catalogPolicyDigest(catalogPolicyIdentity)
        ))
        for (ordinal, value) in paths.enumerated() {
            try await writer.append(WorkspaceRootReusableInventoryManifestRecord(
                rootRelativePath: value.0,
                mode: value.1,
                kind: .blob,
                objectID: oid(Character(String((ordinal % 8) + 1))),
                catalogProjection: policyIgnoredPaths.contains(value.0)
                    ? .policyIgnoredRegularFile
                    : .searchableRegularFile
            ))
        }
        let manifest = try await writer.finish()
        let reader = try manifest.makeReader()
        var searchablePaths: [String] = []
        var ordinals: [Int] = []
        while let entry = try reader.next() {
            if entry.isSearchableFile {
                searchablePaths.append(entry.relativePath)
                ordinals.append(entry.ordinal)
            }
        }
        return WorkspaceRootReusableSnapshot(
            compatibilityKey: compatibility,
            inventoryManifest: manifest,
            searchBase: WorkspaceSearchRelativePathBase(
                relativePaths: searchablePaths,
                stableOrdinals: ordinals
            ),
            catalogPolicyIdentity: catalogPolicyIdentity,
            estimatedByteCount: searchablePaths.reduce(0) { $0 + $1.utf8.count + 96 }
        )
    }
}
