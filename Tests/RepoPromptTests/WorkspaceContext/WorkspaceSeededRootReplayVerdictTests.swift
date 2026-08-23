import Foundation
@testable import RepoPromptApp
import XCTest

/// P4-7c c1 (design doc §6.4): direct unit coverage of
/// `WorkspaceSeededRootReplayValidator.evaluate`, the pure-Swift port of
/// `WorkspaceProjectedPathSearchIndex`'s seed-plan-driven failable initializer. Exercises the
/// same fixture shape as `WorkspaceRootSeedPlannerTests
/// .testStreamingReconciliationPreservesEmptyDirectoriesAndAllPlanDispositions` (reused verbatim:
/// a base of `Deleted.swift`/`Ignored/Tracked.swift`/`Keep.swift` reconciled against a target of
/// `Keep.swift`/`New.swift` plus three empty directories), so one fixture exercises `.reuse`,
/// `.overlay`, `.baseTombstone`, `.ordinaryDirectory`, and `.policyIgnoredTrackedFile` dispositions
/// in a single agreeing replay -- then a deliberately corrupted copy of the same fixture's base
/// snapshot (§6.4's explicit requirement, RK-8's mitigation) to pin the one check that can only be
/// made while decoding the plan record stream: the `baseOrdinal` -> `stableOrdinals` binary search
/// -> exact relative-path match.
final class WorkspaceSeededRootReplayVerdictTests: XCTestCase {
    private typealias FixtureSupport = WorkspaceRootTargetSeedPlanTestSupport
    private typealias SeedSupport = WorkspaceRootSeedTestSupport
    private var roots = FileSystemTemporaryRoots()

    override func tearDownWithError() throws {
        roots.removeAll()
        try super.tearDownWithError()
    }

    private func makeReconciledFixture() async throws -> (
        snapshot: WorkspaceRootReusableSnapshot,
        handle: WorkspaceRootTargetSeedPlanHandle
    ) {
        let root = try roots.makeRoot(suiteName: "WorkspaceSeededRootReplayVerdict-root")
        let storeRoot = try roots.makeRoot(suiteName: "WorkspaceSeededRootReplayVerdict-store")
        let snapshot = try await SeedSupport.snapshot(
            paths: [
                ("Deleted.swift", "100644"),
                ("Ignored/Tracked.swift", "100644"),
                ("Keep.swift", "100644")
            ],
            policyIgnoredPaths: ["Ignored/Tracked.swift"]
        )
        let ignored = snapshot.inventory.entries[1]
        let keep = snapshot.inventory.entries[2]

        let fixture = try await FixtureSupport.makeFixture(
            root: root,
            storeRoot: storeRoot,
            snapshot: snapshot,
            namespaceRecords: [
                .init(relativePath: "Empty", kind: .directory, isSymbolicLink: false, fileSystemMode: 0o040755),
                .init(relativePath: "Empty/Deep", kind: .directory, isSymbolicLink: false, fileSystemMode: 0o040755),
                .init(relativePath: "Empty/Deep/Leaf", kind: .directory, isSymbolicLink: false, fileSystemMode: 0o040755),
                .init(relativePath: "Keep.swift", kind: .file, isSymbolicLink: false, fileSystemMode: 0o100644),
                .init(relativePath: "New.swift", kind: .file, isSymbolicLink: false, fileSystemMode: 0o100644)
            ],
            indexRecords: [
                FixtureSupport.indexRecord(path: ignored.relativePath, objectID: ignored.objectID),
                FixtureSupport.indexRecord(path: keep.relativePath, objectID: keep.objectID)
            ],
            statusRecords: [FixtureSupport.statusRecord(kind: .untracked, path: "New.swift")]
        )
        return (snapshot, fixture.handle)
    }

    /// The target catalog `preparePendingSeededRoot` would derive: searchable, non-policy-ignored
    /// files only -- `Keep.swift` (reused) and `New.swift` (overlay-added). `Deleted.swift`
    /// (tombstoned), `Ignored/Tracked.swift` (policy-ignored), and the three empty directories are
    /// absent, exactly as they would be from `components.entries`.
    private func makeTargetEntries(root: WorkspaceRootRecord) -> [WorkspaceSearchCatalogEntry] {
        ["Keep.swift", "New.swift"].map { relativePath in
            let file = WorkspaceFileRecord(
                id: UUID(),
                rootID: root.id,
                name: (relativePath as NSString).lastPathComponent,
                relativePath: relativePath,
                fullPath: root.standardizedFullPath + "/" + relativePath,
                parentFolderID: nil
            )
            return WorkspaceSearchCatalogEntry(file: file, root: root)
        }.sorted(by: WorkspaceInventoryOrdering.searchCatalogEntryPrecedes)
    }

    func testAgreeingReplayAcrossEveryDispositionProducesMatchingStatistics() async throws {
        let (snapshot, handle) = try await makeReconciledFixture()
        let root = WorkspaceRootRecord(name: "VerdictRoot", fullPath: "/tmp/VerdictRoot")
        let authoritativeEntries = makeTargetEntries(root: root)

        let verdict = WorkspaceSeededRootReplayValidator.evaluate(
            snapshot: snapshot,
            planHandle: handle,
            additionalChangedRelativePaths: .empty,
            root: root,
            authoritativeEntries: authoritativeEntries
        )

        guard case let .agrees(statistics) = verdict else {
            return XCTFail("Expected agreement, got \(verdict)")
        }
        // Base: `Keep.swift` reused from the base snapshot. Overlay: `New.swift`, newly added.
        XCTAssertEqual(statistics.baseEntryCount, 1)
        XCTAssertEqual(statistics.overlayEntryCount, 1)
        // `Deleted.swift` is the base snapshot's only unresolved base slot (its base-index target
        // stays nil): `searchBase` holds only searchable files (`Deleted.swift`, `Keep.swift`;
        // `Ignored/Tracked.swift` is excluded as policy-ignored), so exactly one of its two base
        // slots resolves.
        XCTAssertEqual(statistics.tombstoneCount, 1)
        XCTAssertTrue(verdict.isAgreement)
    }

    func testCorruptedBaseOrdinalMappingDisagreesRatherThanSilentlyAccepting() async throws {
        let (snapshot, handle) = try await makeReconciledFixture()
        let root = WorkspaceRootRecord(name: "VerdictRoot", fullPath: "/tmp/VerdictRoot")
        let authoritativeEntries = makeTargetEntries(root: root)

        // Corrupt the base snapshot's relative-path/ordinal mapping: `stableOrdinals` stays sorted
        // (so the earlier `.baseOrdinalsNotSorted` guard does not fire first), but the base index
        // the `Keep.swift` plan record's `baseOrdinal` resolves to now names a different path. This
        // is exactly the corruption class RK-8 names -- a mismatch only detectable while decoding
        // individual plan records against the base's stable-ordinal index, not by comparing
        // already-resolved changed-path sets (the shape Rust's `ProjectedPathIndex::new` accepts).
        XCTAssertEqual(snapshot.searchBase.relativePaths, ["Deleted.swift", "Keep.swift"])
        XCTAssertEqual(snapshot.searchBase.stableOrdinals, [0, 2])
        let corruptedBase = WorkspaceSearchRelativePathBase(
            relativePaths: ["Deleted.swift", "Wrong.swift"],
            stableOrdinals: snapshot.searchBase.stableOrdinals
        )
        let corruptedSnapshot = WorkspaceRootReusableSnapshot(
            compatibilityKey: snapshot.compatibilityKey,
            inventoryManifest: snapshot.inventoryManifest,
            searchBase: corruptedBase,
            catalogPolicyIdentity: snapshot.catalogPolicyIdentity,
            estimatedByteCount: snapshot.estimatedByteCount
        )
        XCTAssertEqual(corruptedSnapshot.identity, snapshot.identity, "identity must not depend on searchBase")

        let verdict = WorkspaceSeededRootReplayValidator.evaluate(
            snapshot: corruptedSnapshot,
            planHandle: handle,
            additionalChangedRelativePaths: .empty,
            root: root,
            authoritativeEntries: authoritativeEntries
        )

        XCTAssertEqual(verdict, .disagrees(.baseOrdinalMismatch))
        XCTAssertFalse(verdict.isAgreement)
    }

    func testSnapshotIdentityMismatchDisagreesBeforeReadingAnyPlanRecord() async throws {
        let (snapshot, handle) = try await makeReconciledFixture()
        let unrelatedSnapshot = try await SeedSupport.snapshot(paths: [("Other.swift", "100644")])
        let root = WorkspaceRootRecord(name: "VerdictRoot", fullPath: "/tmp/VerdictRoot")

        let verdict = WorkspaceSeededRootReplayValidator.evaluate(
            snapshot: unrelatedSnapshot,
            planHandle: handle,
            additionalChangedRelativePaths: .empty,
            root: root,
            authoritativeEntries: []
        )

        XCTAssertEqual(verdict, .disagrees(.snapshotIdentityMismatch))
        XCTAssertNotEqual(unrelatedSnapshot.identity, snapshot.identity)
    }
}
