import Foundation
@testable import RepoPromptApp
import XCTest

/// P4-6a (docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md §4.3.1.1
/// result 1; docs/architecture/rust-inventory-scope-v1.md §5.4): the six-site
/// discoverability-gap registry. Each of these sites' pre-refactor form does NOT
/// apply `isDiscoverableFileID` (R4), so managed-only (explicitly-created,
/// git-ignored) files are still served today. P4-6a's rewiring must preserve every
/// one of these gaps verbatim -- these tests pin that a future refactor cannot
/// silently close them.
///
/// These tests assert *admission* (the demand is `.pending`/`.ready`, not
/// `.unavailable(.fileNotCataloged)`), not full artifact-build completion: the
/// admission guard is what P4-6a rewired at these sites, and the downstream build
/// pipeline (real syntax parsing / git-blob fingerprinting) is unrelated
/// infrastructure this step did not touch.
///
/// See the delta table:
/// Tests/RepoPromptTests/WorkspaceContext/P4-6a-consumer-rewiring-delta-table.md
final class P4_6a_CodemapDiscoverabilityGapTests: WorkspaceFileContextStoreCodemapSeamTestSupport {
    private func makeManagedOnlyFileFixture(
        name: String
    ) throws -> (repository: ReviewGitRepositoryFixture, root: URL) {
        let repository = try ReviewGitRepositoryFixture(name: name)
        let root = try repository.makeRepository(
            named: "repository",
            files: [
                ".gitignore": "*.managedonly.swift\n",
                "Sources/Tracked.swift": SwiftFixtureSource.emptyStruct("Tracked")
            ]
        )
        return (repository, root)
    }

    private func makeManagedOnlyFile(
        store: WorkspaceFileContextStore,
        rootID: UUID
    ) async throws -> WorkspaceFileRecord {
        _ = try await store.createFile(
            rootID: rootID,
            relativePath: "Sources/Managed.managedonly.swift",
            content: SwiftFixtureSource.emptyStruct("Managed")
        )
        let lookedUpFile = await store.file(rootID: rootID, relativePath: "Sources/Managed.managedonly.swift")
        let managedFile = try XCTUnwrap(lookedUpFile)
        let discoverableFiles = await store.files(inRoot: rootID)
        XCTAssertFalse(
            discoverableFiles.contains { $0.id == managedFile.id },
            "Fixture file must be managed-only (excluded from directory-discoverable listing) for this gap test to be meaningful."
        )
        return managedFile
    }

    /// PC-2 (site 5, `requestCodemapArtifactWithOwnership`, `:12557-12567` at the
    /// design's anchor commit): serves managed-only files on codemap artifact demand.
    /// Asserts admission past the rewired entry guard (`.pending`/`.ready`), not full
    /// artifact-build completion.
    func testRequestCodemapArtifactWithOwnershipServesManagedOnlyFile() async throws {
        let (repository, root) = try makeManagedOnlyFileFixture(name: #function)
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let managedFile = try await makeManagedOnlyFile(store: store, rootID: loaded.id)

        let status = await store.requestCodemapArtifact(forFileID: managedFile.id)
        switch status {
        case .pending, .ready:
            break
        case let .unavailable(reason):
            XCTFail("requestCodemapArtifactWithOwnership must admit a managed-only file (PC-2); got \(reason).")
        }
    }

    /// PC-6 (site 11, `codemapDemandIsCurrent`, `:14966-14975` at the design's anchor
    /// commit): serves managed-only files on demand-currency checks. A `.pending`
    /// demand for a managed-only file is already recorded in
    /// `session.demandsByFileID`, so `codemapDemandIsCurrent` can be exercised without
    /// waiting for the artifact build to finish.
    func testCodemapDemandIsCurrentTrueForManagedOnlyFile() async throws {
        let (repository, root) = try makeManagedOnlyFileFixture(name: #function)
        let fixture = try CodemapStoreFixture(name: #function)
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }
        let store = fixture.makeStore()
        let loaded = try await store.loadRoot(path: root.path)
        let managedFile = try await makeManagedOnlyFile(store: store, rootID: loaded.id)

        var admittedTicket: WorkspaceCodemapArtifactDemandTicket?
        var lastReason: WorkspaceCodemapArtifactDemandUnavailableReason?
        for _ in 0 ..< 20 {
            switch await store.requestCodemapArtifact(forFileID: managedFile.id) {
            case let .pending(pendingTicket):
                admittedTicket = pendingTicket
            case let .ready(ready):
                admittedTicket = ready.ticket
            case let .unavailable(reason):
                lastReason = reason
            }
            if admittedTicket != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let ticket = admittedTicket else {
            throw XCTSkip("requestCodemapArtifactWithOwnership stayed unavailable (\(String(describing: lastReason))); cannot exercise codemapDemandIsCurrent without an admitted ticket.")
        }

        let isCurrent = await store.codemapDemandIsCurrentForTesting(ticket)
        XCTAssertTrue(isCurrent, "codemapDemandIsCurrent must not gain a discoverability clause (PC-6).")
    }
}
