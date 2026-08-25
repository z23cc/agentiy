import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import XCTest

// P4-6b design doc §9's intentional-drift register (charter decision 12). The authority swap
// (table deletion, shadow-apparatus deletion, republication arming) has landed as of this
// commit -- this table records each D-item's *actual, verified* implementation status at the
// cutover commit, not a pre-swap forecast. Re-verify at the next phase's start -- do not assume
// it is still accurate.
//
// The shadow arm (`WorkspaceInventoryScopeShadowForwarder`, the Swift-vs-Rust dual-read
// comparators, and `WorkspaceCatalogShardShadowDiagnosticsParityTests`) is deleted as of this
// cutover -- Rust is now the sole authority for the inventory tables, so there is no second arm
// left to compare against for D-items that depended on cross-arm comparison.
//
// | Item  | Status at cutover commit                             | Where                                                                 |
// |-------|-------------------------------------------------------|------------------------------------------------------------------------|
// | D-1   | SUPERSEDED by P4-8b                                    | The production Swift patch path and its threshold are retired rather than raised to N. `maxPatchLogicalMutationCount` remains an externally visible zero-valued compatibility tombstone; accepted events rebuild from the ordered Rust generation. |
// | D-2   | NOT IMPLEMENTED                                        | `RootCatalogShard.entries` are still materialized Swift-side by the direct-read adapter (including P4-8c's uncached Rust ordered-snapshot fallback), not projected on read. |
// | D-3   | VERIFIED                                               | `CoreInventoryScopeDiscoveryTests.testPathIdentityIsStableAcrossModifyButMintsAFreshIdAcrossRemoveThenReDiscovery` (P4-6b minting-gap closure) exercises Rust's own mint site directly via the discovery wire path. |
// | D-4   | NOT MEASURED                                           | The claim (`unsafeOrAmbiguousBatch` rate drops) is a rate claim across real production traffic, not a single-scenario regression test; no measurement taken this pass. |
// | D-5   | PARTIALLY RESOLVED at P4-8c                            | The `RootCatalogShard` Swift full-rebuild/JSON-byte shadow is retired. Its public diagnostic fields and `.shadowValidationMismatch` spelling remain zero/absent compatibility tombstones; the design's independent Rust-internal self-check is not yet implemented and remains P4-8 closure work. |
// | D-6   | VERIFIED at P4-6b cutover; superseded by P4-7b          | `WorkspaceCatalogShardTests.swift`'s four `===` snapshot-instance-identity assertions were converted to `WorkspaceSearchRootPathIndexIdentity` equality at P4-6b. P4-7b b3 (`docs/designs/p4-7-pathsearch-production-cutover-v2-2026-08-23.md` §4.4) deletes `makeRootPathSearchIndex`, so no caller can populate `rootPathIndexes` to compare identities across anymore -- those assertions are removed, not re-verified; D-6's generation-token identity contract is moot for a holder that no longer exists on the search path. |
// | D-7   | VERIFIED                                               | `testInterningAdversarialFixtureRoundTripsThroughTheProductionReadPath` below -- with the shadow comparator gone, D-7's witness is that the interning-adversarial fixture round-trips correctly (full discoverability, exact path set, per-path point lookups) through the production read path, rather than matching a second Swift-side arm. |
// | D-8   | OUT OF SCOPE for P4-6b                                 | Design doc's own self-check: "P4-6a's work, not this document's" (§15.3 Finding 1 self-check, `:1236`). Codemap read-hoisting staleness, not an inventory-table drift item. |
// | D-9   | VERIFIED at P4-7a phase a3                             | `AgentFileTagSuggestionService.storeBackedCatalogResults` now queries `inventoryQuery(.suggestion)` per root via the store-vended `suggestionQuery` seam instead of building a private per-query `PathSearchIndex` -- design doc `p4-7-pathsearch-production-cutover-v2-2026-08-23.md` §5.3. Pinned by `AgentFileTagSuggestionParityDifferentialTests`: result-set-**and**-order parity over a fixed query corpus, element-by-element, in both binding configurations (including the worktree-bound `logicalPath` haystack variant D-9 names explicitly), plus limit-boundary and dedup coverage. The one accepted, named ordering drift is the multi-root per-root-vs-global truncation shape change (`testMultiRootFanOutIsASupersetOfThePreCutoverGlobalTruncation`) -- absorbed by `scoredSuggestions`' downstream re-ranking, not a silent regression. |
// | D-10  | NOT IMPLEMENTED                                        | No Rust-side codemap graph-index catalog shard builder exists yet (`rg GraphIndexCatalogShard rust/crates/runtime` -- zero hits as of this checkpoint); depends on P4-6a's codemap read-path work landing first. |
// | D-12  | OUT OF SCOPE for P4-6b                                 | Design doc registers this as "a P4-3a done-when" (`:939`) -- an earlier phase's item, not re-verified here. |
//
// **Open item found during the P4-6b cutover, resolved in a follow-on commit (contract doc
// §12.3's amendment):** the patch path (`WorkspaceFileContextStore.buildRootCatalogShardPatch` /
// `WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch`) was falling back to
// `.patchApplicationBackstop` (a full authoritative rebuild) on every top-level-file/-folder
// upsert. Root cause (confirmed by direct field-level instrumentation, not the
// `modificationDate`-precision hypothesis originally recorded here): `WorkspaceFileContextStore
// .file(rootID:relativePath:)`/`.folder(rootID:relativePath:)` passed Rust's raw
// `fact.parentFolderID` straight through instead of denormalizing it back through
// `WorkspaceInventoryScopeRepublicationAdapter.denormalizedParentFolderID` -- Rust's convention
// (root marker excluded, top-level parent is `nil`) leaked into records that Swift's other
// reconstruction paths correctly represent with the root-self-referencing-marker convention
// (`parentFolderID == rootID`), so `buildRootCatalogShardPatch`'s upserted-record equality guard
// against a Rust-round-tripped re-fetch failed on every top-level record. A second, previously
// latent bug in the same function's ancestor-folder walk (requiring a `foldersByID` lookup for
// the root marker itself, which is never populated -- the root folder is never sent to Rust) was
// uncovered once the first fix let the walk actually run, and fixed alongside it. All four
// quarantined `WorkspaceCatalogShardTests` are un-skipped and green. P4-8b later retires that
// patch path from product execution; the pure builder remains only as a historical benchmark arm.
#if DEBUG
    final class WorkspaceInventoryScopeDriftRegisterTests: XCTestCase {
        private var stores: [WorkspaceFileContextStore] = []
        private var temporaryRoots: [URL] = []

        override func tearDown() async throws {
            for store in stores {
                let rootIDs = await store.roots().map(\.id)
                await store.unloadRoots(ids: rootIDs)
            }
            stores.removeAll()
            for root in temporaryRoots {
                try? FileManager.default.removeItem(at: root)
            }
            temporaryRoots.removeAll()
            try await super.tearDown()
        }

        /// D-7: "Wire strings interned; payload-only; byte-level shard comparison uses a canonical
        /// encoding that is invariant to interning." Rust's wire encoding interns repeated
        /// substrings (`InternPoolBuilder`) -- deep, wide, sibling-heavy trees with long shared
        /// relative-path prefixes are exactly the shape that maximizes interning reuse internally.
        /// Post-cutover, Rust is the sole authority (the Swift-side shadow comparator this test
        /// used to drive is deleted), so D-7's witness is now that this interning-adversarial
        /// fixture round-trips correctly through the production read path: every written file is
        /// discovered, the discovered path set is exact, and a point lookup on every one of those
        /// paths returns the matching record. If interning ever leaked into decoded record content
        /// (the class of bug this registration exists to rule out), a point lookup on an aliased
        /// path would return the wrong record, or the whole-root listing would miss/duplicate one.
        func testInterningAdversarialFixtureRoundTripsThroughTheProductionReadPath() async throws {
            let root = try makeTemporaryRoot(name: "ShadowDriftD7Interning")
            // A wide, deep tree where every leaf shares a long common ancestor-path prefix with
            // many siblings -- maximizes the chance any string-interning aliasing bug would
            // manifest as a decoded-content mismatch rather than staying hidden.
            let sharedPrefix = "src/very/deeply/nested/shared/prefix/across/many/sibling/files"
            var expectedRelativePaths: [String] = []
            for index in 0 ..< 40 {
                let relativePath = "\(sharedPrefix)/Sibling\(index).swift"
                try write("content-\(index)", to: root.appendingPathComponent(relativePath))
                expectedRelativePaths.append(relativePath)
            }
            // A second branch reusing a *partial* prefix of the same string, to exercise
            // interning's substring-reuse path rather than only whole-segment reuse.
            for index in 0 ..< 20 {
                let relativePath = "src/very/deeply/nested/other/branch/Sibling\(index).swift"
                try write("content-b\(index)", to: root.appendingPathComponent(relativePath))
                expectedRelativePaths.append(relativePath)
            }
            let store = makeStore()
            let record = try await loadStoppedRoot(in: store, path: root.path)

            let files = await store.files(inRoot: record.id)
            XCTAssertEqual(
                files.count, expectedRelativePaths.count,
                "D-7 violated: production read path did not discover every file in an interning-adversarial fixture"
            )
            XCTAssertGreaterThanOrEqual(files.count, 60, "sanity: the adversarial fixture must actually be present")

            let discoveredRelativePaths = Set(files.map(\.standardizedRelativePath))
            XCTAssertEqual(
                discoveredRelativePaths, Set(expectedRelativePaths),
                "D-7 violated: discovered path set diverged from the interning-adversarial fixture"
            )

            for relativePath in expectedRelativePaths {
                let fileRecord = await store.file(rootID: record.id, relativePath: relativePath)
                XCTAssertEqual(
                    fileRecord?.standardizedRelativePath,
                    relativePath,
                    "D-7 violated: point lookup for \(relativePath) diverged under an interning-adversarial fixture"
                )
            }
        }

        // MARK: - Helpers

        private func makeStore() -> WorkspaceFileContextStore {
            let store = WorkspaceFileContextStore()
            stores.append(store)
            return store
        }

        private func loadStoppedRoot(
            in store: WorkspaceFileContextStore,
            path: String,
            kind: WorkspaceRootKind? = nil
        ) async throws -> WorkspaceRootRecord {
            let root = try await store.loadRoot(path: path, kind: kind)
            await store.stopWatchingRoot(id: root.id)
            return root
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPrompt-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            temporaryRoots.append(url)
            return url
        }

        private func write(_ content: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
#endif
