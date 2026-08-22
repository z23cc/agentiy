import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import XCTest

// P4-6b prep slice 2, item 4 -- design doc §9's intentional-drift register (charter decision 12),
// checkpointed pre-swap the same way item 3's diagnostics-only parity suite is: this file lands
// exactly the D-1..D-10 (plus D-12) items that are testable *without* an authority flip, and
// records the rest as swap-matrix items rather than guessing at behavior only the cutover itself
// can produce. Re-verify this status table at swap time -- do not assume it is still accurate.
//
// | Item  | Status pre-swap                                    | Where                                                                 |
// |-------|-----------------------------------------------------|------------------------------------------------------------------------|
// | D-1   | PINNED here (via the parity suite)                   | `WorkspaceCatalogShardShadowDiagnosticsParityTests.testConfigLevelDiagnosticsAreCrossArmIdentical` -- N=1 today, matches Swift. |
// | D-2   | Swap-matrix. Not testable pre-swap                   | Requires Swift to stop projecting `entries` -- a swap-time read-path change, not an additive one. |
// | D-3   | ALREADY COVERED pre-swap (no new test needed here)   | `CoreInventoryScopeDiscoveryTests.testPathIdentityIsStableAcrossModifyButMintsAFreshIdAcrossRemoveThenReDiscovery` (P4-6b minting-gap closure) exercises Rust's own mint site directly via the discovery wire path -- the only pre-swap witness of *Rust's* minting behavior, since mutation routing (item 1) still forwards Swift-minted IDs today. |
// | D-4   | Swap-matrix. Not testable pre-swap                   | The claim is structural elimination of a two-map-drift class that only exists while Swift owns both the map and the shard builder; cannot regress-test an authority that hasn't moved yet. |
// | D-5   | Swap-matrix. Not testable pre-swap                   | Rust's `shadow_comparison_count` is already live today but is *not* the metric that matters post-cutover in the same way -- see the parity suite's header for why it is not comparable to Swift's counter of the same name. |
// | D-6   | Swap-matrix. Blocked on pre-check 3                  | No generation-token / cache-reuse-proof equivalent to `===` verified yet on the read facade. |
// | D-7   | PINNED here                                          | `testCanonicalTableComparisonIsInvariantToRustStringInterning` below. |
// | D-8   | OUT OF SCOPE for P4-6b                               | Design doc's own self-check: "P4-6a's work, not this document's" (§15.3 Finding 1 self-check, `:1236`). Codemap read-hoisting staleness, not an inventory-table drift item. |
// | D-9   | OUT OF SCOPE for P4-6b                               | `CoreInventoryScope.swift:568`: "`.suggestion` is reserved for P4-7's `AgentFileTagSuggestionService` cutover" -- a later phase, not this one. |
// | D-10  | Swap-matrix. Not testable pre-swap                   | No Rust-side codemap graph-index catalog shard builder exists yet (`rg GraphIndexCatalogShard rust/crates/runtime` -- zero hits as of this checkpoint); depends on P4-6a's codemap read-path work landing first. |
// | D-12  | OUT OF SCOPE for P4-6b                               | Design doc registers this as "a P4-3a done-when" (`:939`) -- an earlier phase's item, not re-verified here. |
#if DEBUG
    final class WorkspaceInventoryScopeDriftRegisterTests: XCTestCase {
        private var stores: [WorkspaceFileContextStore] = []
        private var temporaryRoots: [URL] = []

        override func tearDown() async throws {
            for store in stores {
                await store.closeInventoryScopeShadowForTesting()
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
        /// If interning ever leaked into the decoded record content (the class of bug this
        /// registration exists to rule out), the existing canonical table comparator
        /// (`compareInventoryScopeShadowForTesting`, which decodes through the same path every
        /// other shadow test already uses) would catch it as a mismatch. This test's only addition
        /// over the incidental coverage every multi-file shadow test already provides is an
        /// explicitly interning-adversarial fixture, so D-7's registration has a *named*,
        /// intentional witness rather than a merely-incidental one.
        func testCanonicalTableComparisonIsInvariantToRustStringInterning() async throws {
            let root = try makeTemporaryRoot(name: "ShadowDriftD7Interning")
            // A wide, deep tree where every leaf shares a long common ancestor-path prefix with
            // many siblings -- maximizes the chance any string-interning aliasing bug would
            // manifest as a decoded-content mismatch rather than staying hidden.
            let sharedPrefix = "src/very/deeply/nested/shared/prefix/across/many/sibling/files"
            for index in 0 ..< 40 {
                try write("content-\(index)", to: root.appendingPathComponent("\(sharedPrefix)/Sibling\(index).swift"))
            }
            // A second branch reusing a *partial* prefix of the same string, to exercise
            // interning's substring-reuse path rather than only whole-segment reuse.
            for index in 0 ..< 20 {
                try write("content-b\(index)", to: root.appendingPathComponent("src/very/deeply/nested/other/branch/Sibling\(index).swift"))
            }
            let store = makeShadowStore()
            let record = try await loadStoppedRoot(in: store, path: root.path)

            let report = try await store.compareInventoryScopeShadowForTesting(rootID: record.id)
            XCTAssertTrue(report.matched, "D-7 violated: canonical table comparison diverged under an interning-adversarial fixture: \(report)")
            XCTAssertEqual(report.swiftRecordCount, report.rustRecordCount)
            XCTAssertGreaterThan(report.swiftRecordCount, 60, "sanity: the adversarial fixture must actually be present on both sides")

            let mismatchCount = await store.inventoryScopeShadowMismatchCountForTesting
            XCTAssertEqual(mismatchCount, 0)
        }

        // MARK: - Helpers

        private func makeShadowStore() -> WorkspaceFileContextStore {
            let store = WorkspaceFileContextStore(
                enableCatalogShardShadowValidation: true,
                enableInventoryScopeShadowValidation: true
            )
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
