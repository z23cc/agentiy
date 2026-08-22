@testable import AgentryCoreBridge
import Foundation
import XCTest

/// §4.1.1's discovery mint site -- the file/folder UUID-minting capability the P4-6b cutover
/// requires (`docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §4.1 item 3, D-3)
/// and which P4-1 through P4-6a never actually built: the Rust runtime only minted
/// `InventoryScopeId`/`RootLifetimeId` (`ids.rs`'s `UuidMinter`), and every mutation entry point
/// (`pushBulkChunk`/`applyDelta`) required the caller to supply `id` on every record. This file
/// exercises the closure: `CoreInventoryScope.pushBulkChunkDiscovery` / `applyDeltaDiscovery`
/// through the real bridge/FFI round trip, driving the wire's new, purely additive
/// `discoveryBulkChunk`/`discoveryDeltaEvent` message kinds (the existing id-supplied
/// `bulkChunk`/`deltaEvent` shapes are untouched -- see `CoreInventoryScopeTests`/
/// `CoreInventoryScopeShadowDifferentialTests` for those).
///
/// Seeded deterministic minting itself (§4.1.1's "test-only deterministic seed") is proven at the
/// cargo level, closer to the primitive: `rust/crates/runtime/src/inventory_scope/ids.rs`'s
/// `v4_bytes_are_deterministic_under_a_seeded_minter` / `v4_bytes_are_shaped_as_rfc4122_version_4`
/// drive `InventoryScope::new_seeded_for_testing` directly. The FFI layer has no seeded-scope
/// constructor (production always opens a fresh-entropy scope), so there is nothing additional to
/// prove about seeding through this bridge.
final class CoreInventoryScopeDiscoveryTests: XCTestCase {
    private func discoveredFile(
        rootID: UUID,
        name: String,
        relativePath: String,
        parentFolderID: UUID? = nil,
        modificationDate: Date? = nil
    ) -> CoreDiscoveredFileRecordV1 {
        CoreDiscoveredFileRecordV1(
            rootID: rootID,
            name: name,
            relativePath: relativePath,
            standardizedRelativePath: relativePath,
            fullPath: "/repo/\(relativePath)",
            standardizedFullPath: "/repo/\(relativePath)",
            parentFolderID: parentFolderID,
            modificationDate: modificationDate
        )
    }

    private func sampleFile(
        id: UUID,
        rootID: UUID,
        name: String,
        relativePath: String,
        parentFolderID: UUID? = nil,
        modificationDate: Date? = nil
    ) -> CoreInventoryFileRecordV1 {
        CoreInventoryFileRecordV1(
            id: id,
            rootID: rootID,
            name: name,
            relativePath: relativePath,
            standardizedRelativePath: relativePath,
            fullPath: "/repo/\(relativePath)",
            standardizedFullPath: "/repo/\(relativePath)",
            parentFolderID: parentFolderID,
            modificationDate: modificationDate
        )
    }

    // MARK: - Receipt round-trip through the FFI

    func testDiscoveryBulkChunkMintsFreshIdsAndTheReceiptRoundTripsThroughTheBridge() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")
        let bulkLoadID = try await scope.beginBulkLoad(rootID: rootID, rootLifetimeID: rootLifetimeID)

        let discovered = [
            discoveredFile(rootID: rootID, name: "App.swift", relativePath: "App.swift"),
            discoveredFile(rootID: rootID, name: "README.md", relativePath: "README.md"),
        ]
        let receipt = try await scope.pushBulkChunkDiscovery(bulkLoadID: bulkLoadID, rootID: rootID, files: discovered, folders: [])
        XCTAssertEqual(receipt.filesStaged, 2)
        XCTAssertEqual(receipt.foldersStaged, 0)
        XCTAssertEqual(receipt.mintedFileIDs.count, 2)
        XCTAssertEqual(Set(receipt.mintedFileIDs).count, 2, "minted ids must not collide")

        _ = try await scope.commitBulkLoad(bulkLoadID: bulkLoadID)

        // The receipt's minted ids are exactly the ids now staged: querying the snapshot must
        // show the same ids paired with the same paths, in the same order the discovery input
        // supplied them (§4.1.1's "the receipt echoes the minted ids in input order").
        let snapshot = try await scope.openSnapshot(rootID: rootID)
        let page = try await snapshot.page(offset: 0, limit: 10)
        XCTAssertEqual(Set(page.files.map(\.id)), Set(receipt.mintedFileIDs))
        let idByPath = Dictionary(uniqueKeysWithValues: page.files.map { ($0.standardizedRelativePath, $0.id) })
        XCTAssertEqual(idByPath["App.swift"], receipt.mintedFileIDs[0])
        XCTAssertEqual(idByPath["README.md"], receipt.mintedFileIDs[1])

        await snapshot.close()
        await scope.close()
        _ = try await bridge.close()
    }

    func testDiscoveryDeltaAppliesThroughTheSameGateAsTheIdSuppliedPathAndTheReceiptRoundTrips() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")

        let event = CoreInventoryDiscoveryAppliedIndexBatchEventV1(
            rootID: rootID,
            upsertedFiles: [discoveredFile(rootID: rootID, name: "New.swift", relativePath: "New.swift")],
            upsertedFolders: [],
            removedFileIDs: [], removedFolderIDs: [],
            removedFilePaths: [], removedFolderPaths: [],
            modifiedFileIDs: [], modifiedFolderIDs: []
        )
        let receipt = try await scope.applyDeltaDiscovery(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID, source: "test", event: event
        ))
        guard case .rejected = receipt.outcome else {
            XCTAssertEqual(receipt.mintedFileIDs.count, 1)
            XCTAssertEqual(receipt.appliedIndexGeneration, 1, "the same generation/patch machinery the id-supplied path drives")

            let snapshot = try await scope.openSnapshot(rootID: rootID)
            let page = try await snapshot.page(offset: 0, limit: 10)
            XCTAssertEqual(page.files.map(\.id), receipt.mintedFileIDs)
            XCTAssertEqual(page.files.first?.standardizedRelativePath, "New.swift")
            await snapshot.close()
            await scope.close()
            _ = try await bridge.close()
            return
        }
        XCTFail("a fresh discovery delta on a newly-opened root should be admitted, not rejected")
        await scope.close()
        _ = try await bridge.close()
    }

    // MARK: - Path→ID stability within a root lifetime (§4.1.1's two pinned invariants)

    /// "A `fileModified` on a known path reuses the existing ID; a `fileRemoved` followed by
    /// `fileAdded` on the same path mints a **new** ID." Proven here using the actual minting
    /// primitive: discover a path (mint id X), reuse X through the ordinary id-supplied
    /// `applyDelta` path (the modify case), then remove X and re-discover the same path (mint a
    /// fresh id Y != X, the remove+re-add case).
    func testPathIdentityIsStableAcrossModifyButMintsAFreshIdAcrossRemoveThenReDiscovery() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let rootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let rootLifetimeID = try await scope.openRoot(rootID: rootID, name: "root", standardizedFullPath: "/repo")

        // Discover "A.swift" -- mints id X.
        let discoverReceipt = try await scope.applyDeltaDiscovery(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID, source: "test",
            event: CoreInventoryDiscoveryAppliedIndexBatchEventV1(
                rootID: rootID,
                upsertedFiles: [discoveredFile(rootID: rootID, name: "A.swift", relativePath: "A.swift")],
                upsertedFolders: [], removedFileIDs: [], removedFolderIDs: [],
                removedFilePaths: [], removedFolderPaths: [], modifiedFileIDs: [], modifiedFolderIDs: []
            )
        ))
        let idX = try XCTUnwrap(discoverReceipt.mintedFileIDs.first)

        // "Modified": reuse X through the ordinary id-supplied path, exactly as a real
        // `fileModified` delta would (the id is already known, so this never goes through
        // discovery). The generation-token identity contract's own gate (watermark/lifetime)
        // just needs the same root/lifetime.
        let modifyReceipt = try await scope.applyDelta(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID, source: "test",
            event: CoreInventoryAppliedIndexBatchEventV1(
                rootID: rootID,
                upsertedFiles: [sampleFile(id: idX, rootID: rootID, name: "A.swift", relativePath: "A.swift")],
                upsertedFolders: [], removedFileIDs: [], removedFolderIDs: [],
                removedFilePaths: [], removedFolderPaths: [], modifiedFileIDs: [idX], modifiedFolderIDs: []
            )
        ))
        if case let .rejected(reason) = modifyReceipt.outcome { XCTFail("modify-by-reused-id should be admitted, got: \(reason)") }

        let afterModify = try await scope.openSnapshot(rootID: rootID)
        let afterModifyPage = try await afterModify.page(offset: 0, limit: 10)
        XCTAssertEqual(afterModifyPage.files.map(\.id), [idX], "a modify on a known path must reuse the existing id, not mint a new one")
        await afterModify.close()

        // Remove X, then re-discover the SAME path -- this must mint a genuinely new id Y != X.
        let removeThenReDiscoverReceipt = try await scope.applyDeltaDiscovery(.init(
            rootID: rootID, rootLifetimeID: rootLifetimeID, source: "test",
            event: CoreInventoryDiscoveryAppliedIndexBatchEventV1(
                rootID: rootID,
                upsertedFiles: [discoveredFile(rootID: rootID, name: "A.swift", relativePath: "A.swift")],
                upsertedFolders: [],
                removedFileIDs: [idX], removedFolderIDs: [],
                removedFilePaths: [], removedFolderPaths: [],
                modifiedFileIDs: [], modifiedFolderIDs: []
            )
        ))
        let idY = try XCTUnwrap(removeThenReDiscoverReceipt.mintedFileIDs.first)
        XCTAssertNotEqual(idY, idX, "remove followed by re-add on the same path must mint a NEW id")

        let afterReDiscovery = try await scope.openSnapshot(rootID: rootID)
        let afterReDiscoveryPage = try await afterReDiscovery.page(offset: 0, limit: 10)
        XCTAssertEqual(afterReDiscoveryPage.files.map(\.id), [idY], "exactly one surviving record, addressed by the new id")
        await afterReDiscovery.close()

        await scope.close()
        _ = try await bridge.close()
    }

    // MARK: - Discovery-vs-supplied path equivalence

    /// A discovery-minted record and an id-supplied record built from the same field values must
    /// be field-for-field identical once staged and read back (minus `id` itself, which is by
    /// definition different) -- proving the discovery decode path doesn't lose or alter any field
    /// relative to the id-supplied path it wraps.
    func testDiscoveryAndIdSuppliedPathsProduceFieldEquivalentRecords() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let discoveryRootID = UUID()
        let suppliedRootID = UUID()
        let scope = try await CoreInventoryScope.open(bridge: bridge)
        let modificationDate = Date(timeIntervalSinceReferenceDate: 12345.5)

        let discoveryLifetimeID = try await scope.openRoot(rootID: discoveryRootID, name: "root", standardizedFullPath: "/repo")
        let discoveryBulkLoadID = try await scope.beginBulkLoad(rootID: discoveryRootID, rootLifetimeID: discoveryLifetimeID)
        let discoveryReceipt = try await scope.pushBulkChunkDiscovery(
            bulkLoadID: discoveryBulkLoadID, rootID: discoveryRootID,
            files: [discoveredFile(
                rootID: discoveryRootID, name: "Nested.swift", relativePath: "src/Nested.swift",
                modificationDate: modificationDate
            )],
            folders: []
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: discoveryBulkLoadID)
        let discoveryMintedID = try XCTUnwrap(discoveryReceipt.mintedFileIDs.first)

        let suppliedLifetimeID = try await scope.openRoot(rootID: suppliedRootID, name: "root", standardizedFullPath: "/repo")
        let suppliedBulkLoadID = try await scope.beginBulkLoad(rootID: suppliedRootID, rootLifetimeID: suppliedLifetimeID)
        let suppliedID = UUID()
        _ = try await scope.pushBulkChunk(
            bulkLoadID: suppliedBulkLoadID, rootID: suppliedRootID,
            files: [sampleFile(
                id: suppliedID, rootID: suppliedRootID, name: "Nested.swift", relativePath: "src/Nested.swift",
                modificationDate: modificationDate
            )],
            folders: []
        )
        _ = try await scope.commitBulkLoad(bulkLoadID: suppliedBulkLoadID)

        let discoverySnapshot = try await scope.openSnapshot(rootID: discoveryRootID)
        let discoveredRecord = try await discoverySnapshot.page(offset: 0, limit: 10).files.first
        let suppliedSnapshot = try await scope.openSnapshot(rootID: suppliedRootID)
        let suppliedRecord = try await suppliedSnapshot.page(offset: 0, limit: 10).files.first

        let discovered = try XCTUnwrap(discoveredRecord)
        let supplied = try XCTUnwrap(suppliedRecord)
        XCTAssertEqual(discovered.id, discoveryMintedID)
        XCTAssertEqual(supplied.id, suppliedID)
        XCTAssertEqual(discovered.name, supplied.name)
        XCTAssertEqual(discovered.relativePath, supplied.relativePath)
        XCTAssertEqual(discovered.standardizedRelativePath, supplied.standardizedRelativePath)
        XCTAssertEqual(discovered.fullPath, supplied.fullPath)
        XCTAssertEqual(discovered.standardizedFullPath, supplied.standardizedFullPath)
        XCTAssertEqual(discovered.parentFolderID, supplied.parentFolderID)
        XCTAssertEqual(discovered.modificationDate, supplied.modificationDate)

        await discoverySnapshot.close()
        await suppliedSnapshot.close()
        await scope.close()
        _ = try await bridge.close()
    }
}
