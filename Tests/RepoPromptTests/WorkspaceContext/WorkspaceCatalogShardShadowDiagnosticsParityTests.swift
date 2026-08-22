import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import XCTest

// P4-6b prep slice 2, item 3 -- CHECKPOINTED, not the swap suite (design doc
// `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §8.4's line "Ported
// `WorkspaceCatalogShardTests` -- all eight tests, with `===` assertions converted to
// generation-token assertions and drift-affected expectations updated per §9" is the
// AUTHORITY-SWAP COMMIT's done-when, not this file's. This file is the diagnostics-only
// down-payment the ruling that created it asked for: assert exactly the fields Rust's
// `InventoryDiagnosticsV1`/`InventoryRootDiagnosticsV1` and Swift's
// `RootCatalogShardDebugSnapshot`/`RootCatalogShardGenerationDebugSnapshot` already guarantee to
// agree on today, over the same driven mutation history, via the P4-5 shadow scope -- and
// document (not assert) the rest, per the same monotonicity-only reasoning
// `WorkspaceInventoryScopeShadowTests`'s republication-adapter test already established for
// `generation`/`requiresFullResync`.
//
// ── The swap's TODO contract (verbatim from the prep-2 checkpoint report; re-verify at swap
//    time, do not assume these are still accurate) ──────────────────────────────────────────
//
// 1. D-1's N. RESOLVED during this checkpoint: `max_patch_logical_mutation_count` is `1` in Rust
//    today (`rust/crates/runtime/src/inventory_scope/scope.rs:66`), matching Swift's
//    `maxRootCatalogShardPatchLogicalMutationCount` (`WorkspaceFileContextStore.swift:2777`) --
//    no drift-adjustment needed yet. Pinned below by
//    `testConfigLevelDiagnosticsAreCrossArmIdentical`. Re-check this value at swap time: if
//    E-1's tuning has landed a larger N by then, `testPatchThresholdRebuildsAffectedRootAnd...`
//    and this file's own pin both need the drift-adjusted number (D-1's registered expectation).
// 2. Handle close. PARTIALLY RESOLVED: `CoreInventoryScope.close()` exists at the API level
//    (`Sources/AgentryCoreBridge/CoreInventoryScope.swift:911`) and is idempotent. NOT verified:
//    whether closing/dropping a snapshot handle deterministically drives the same
//    `open_handle_count` / retention-backstop-recovery behavior the ported
//    `testRetainedSnapshotsKeepOldGenerationsAliveAndBackstopRecoversAfterRelease` and
//    `testRetentionBackstopMarksDirtyAndNextCanonicalBatchRecoversAuthoritatively` pin on the
//    Swift side via plain ARC release. Swap-matrix work.
// 3. Generation-token equivalent for the `===` → D-6 conversion. NOT resolved: does
//    `inventoryOpenProjectedShard` (or any read-facade call) return anything that proves cache
//    reuse the way `WorkspaceCatalogShardTests`'s `===` snapshot-identity assertions
//    (`:95`, `:111-112`, `:585`) do today? Swap-matrix work -- D-6 cannot be pinned without it.
// 4. Injection hooks. NOT resolved: no Rust-side equivalent found yet for
//    `applyAppliedIndexEventToRootCatalogShardForTesting` / `advanceRootCatalogTopologyGenerationForTesting`
//    / `recordRootCatalogShardFallbackForTesting`, which `testCanonicalBatchFallbacksCover...`
//    drives directly into the Swift state machine to exercise generation-gap / overflow /
//    unsafe-ambiguity paths without a live delta. `staleWatermark` (§5.3.1) may be the Rust-side
//    analogue but this was not verified. Swap-matrix work.
//
// ── What this file asserts (cross-arm-guaranteed today) ────────────────────────────────────
//
// - Config-level fields (`liveGenerationCapPerRoot`, `maxPatchLogicalMutationCount`): these are
//   compile-time constants on both sides, not driven by mutation history, so they are the one
//   class of diagnostics field genuinely comparable for equality pre-swap.
// - Root membership: after driving the same mutation history through both arms (the shadow
//   forwarder's drain opens/bulk-seeds every currently-loaded root the first time it's observed,
//   §8.2), the *set* of root IDs each side's diagnostics snapshot reports should match. This is a
//   structural invariant, not a counter-value invariant.
// - The fallback-reason vocabulary's fixed-order decode: Rust's `fallback_reason_counts: Vec<u64>`
//   is positional against `RootCatalogShardFallbackReason::ALL` (`fallback.rs`), which is
//   documented as a byte-for-byte port of the same 8-case Swift enum in the same declaration
//   order -- asserted here by decoding through `CoreInventoryShardFallbackReasonV1` (the existing
//   fixed-order mirror `CoreInventoryScope.swift:1077` already vends for event decoding) and
//   checking the count/order round-trips, not that the per-reason *values* match (see below).
//
// ── What this file deliberately does NOT assert, and why ───────────────────────────────────
//
// - `buildCount` / `patchCount` / `authoritativeRebuildCount` / `pathIndexBuildCount` /
//   `overlayPathIndexBuildCount` / `publishedTopologyGeneration` / `lastAppliedIndexGeneration` /
//   `backstopCount` / `liveTopologyGenerations` / `retainedTopologyGenerations`: each arm runs its
//   own independent build/patch/generation-sequencing state machine (Swift's lazy shard
//   publication vs. Rust's bulk-chunk-seeded scope) -- these are driven by *when* each arm was
//   asked to materialize a shard or path index, not just by the mutation history, so they are not
//   expected to be numerically equal. This is the same "generation is monotonic, not cross-arm
//   equal" rule `WorkspaceInventoryScopeShadowTests`'s
//   `testRepublicationAdapterMatchesRealSwiftPublishedEventForIncrementalAdd` already established
//   and documented for exactly this reason.
// - `fallbackReasonCounts`'s per-reason *values*: same reasoning -- sequencing differs, and D-4
//   registers `unsafeOrAmbiguousBatch`'s rate as *expected* to drop post-cutover (it partly fires
//   today because Swift's map and shard builder are updated on separate paths, a class the
//   single-owner cutover structurally eliminates). Comparing counts pre-swap would pin a
//   relationship the design doc itself says should change at swap.
// - `shadowComparisonCount` / `shadowMismatchCount` / `lastShadowByteCount`: same field *names* on
//   both sides, different *metrics*. Swift's is this very test harness's own cross-arm comparison
//   counter (`inventoryScopeShadowComparisonCountForTesting`, incremented by
//   `compareInventoryScopeShadowForTesting`). Rust's is D-5's registered repurposing: an optional,
//   config-gated, Rust-*internal* patch-vs-rebuild self-check that has nothing to do with the
//   Swift↔Rust shadow arm. Comparing them would compare two unrelated counters that happen to
//   share a name -- explicitly called out so nobody "fixes" this file to assert their equality.
#if DEBUG
    final class WorkspaceCatalogShardShadowDiagnosticsParityTests: XCTestCase {
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

        /// D-1's pin (pre-check 1, resolved): the two config constants that are NOT driven by
        /// mutation history are asserted equal across arms. No mutation driving needed beyond
        /// opening one root, since these are compile-time constants on both sides.
        func testConfigLevelDiagnosticsAreCrossArmIdentical() async throws {
            let root = try makeTemporaryRoot(name: "ShadowDiagnosticsConfig")
            try write("a", to: root.appendingPathComponent("A.swift"))
            let store = makeShadowStore()
            _ = try await loadStoppedRoot(in: store, path: root.path)

            let swiftDiagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let fetchedRustDiagnostics = try await store.inventoryScopeShadowDiagnosticsForTesting()
            let rustDiagnostics = try XCTUnwrap(
                fetchedRustDiagnostics,
                "shadow arm must be enabled by makeShadowStore()"
            )

            XCTAssertEqual(
                UInt64(swiftDiagnostics.liveGenerationCapPerRoot),
                rustDiagnostics.liveGenerationCapPerRoot,
                "liveGenerationCapPerRoot is a compile-time constant on both sides and must agree"
            )
            XCTAssertEqual(
                UInt64(swiftDiagnostics.maxPatchLogicalMutationCount),
                rustDiagnostics.maxPatchLogicalMutationCount,
                "D-1's N: max_patch_logical_mutation_count must still be 1 on the Rust side " +
                    "(pre-check 1's resolution) -- if this now fails, E-1's tuning has landed a " +
                    "drift-adjusted N and both this assertion and the design's D-1 registration " +
                    "need updating together"
            )
            // Pin today's actual values too, not just cross-arm equality, so a future change that
            // moves both sides in lockstep (and would otherwise pass the equality check above)
            // still gets flagged for a deliberate look.
            XCTAssertEqual(swiftDiagnostics.liveGenerationCapPerRoot, 8)
            XCTAssertEqual(swiftDiagnostics.maxPatchLogicalMutationCount, 1)
        }

        /// Root-membership parity: drives a representative mutation history (bulk load, add,
        /// modify, remove, second root) through both arms via the shadow forwarder's drain, then
        /// asserts the *set* of root IDs each side's diagnostics snapshot reports is identical.
        /// Deliberately does not exercise unload here -- root-set parity across close/tombstone is
        /// unverified (not one of the four resolved pre-checks) and left to the swap matrix.
        func testRootMembershipParityAfterDrivenMutations() async throws {
            let rootA = try makeTemporaryRoot(name: "ShadowDiagnosticsRootsA")
            let rootB = try makeTemporaryRoot(name: "ShadowDiagnosticsRootsB")
            try write("a", to: rootA.appendingPathComponent("A.swift"))
            try write("b", to: rootB.appendingPathComponent("B.swift"))
            let store = makeShadowStore()
            let recordA = try await store.loadRoot(path: rootA.path)
            try await store.startWatchingRoot(id: recordA.id)
            let recordB = try await loadStoppedRoot(in: store, path: rootB.path)

            let addedURL = rootA.appendingPathComponent("Added.swift")
            try write("added", to: addedURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: recordA.id, deltas: [.fileAdded("Added.swift")])
            _ = await store.flushPendingServiceEventsForAllRoots()
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: recordA.id, deltas: [.fileModified("A.swift", nil)])
            _ = await store.flushPendingServiceEventsForAllRoots()

            let swiftDiagnostics = await store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            let fetchedRustDiagnostics = try await store.inventoryScopeShadowDiagnosticsForTesting()
            let rustDiagnostics = try XCTUnwrap(fetchedRustDiagnostics)

            let swiftRootIDs = Set(swiftDiagnostics.roots.map(\.rootID))
            let rustRootIDs = try Set(rustDiagnostics.roots.map { try Self.uuid(fromRootID: $0.rootId) })

            XCTAssertEqual(swiftRootIDs, rustRootIDs)
            XCTAssertTrue(swiftRootIDs.contains(recordA.id))
            XCTAssertTrue(swiftRootIDs.contains(recordB.id))

            let mismatchCount = await store.inventoryScopeShadowMismatchCountForTesting
            XCTAssertEqual(mismatchCount, 0)
        }

        /// The fallback-reason vocabulary's fixed-order decode: asserts the positional
        /// `fallback_reason_counts: Vec<u64>` round-trips through `CoreInventoryShardFallbackReasonV1`
        /// (the same fixed-order mirror already used for event decoding) to exactly the 8 cases in
        /// the same order Swift's `RootCatalogShardFallbackReason.allCases` declares them --
        /// structural, not a per-reason value comparison (see header).
        func testFallbackReasonVocabularyDecodesInFixedOrder() async throws {
            let root = try makeTemporaryRoot(name: "ShadowDiagnosticsFallbackVocabulary")
            try write("a", to: root.appendingPathComponent("A.swift"))
            let store = makeShadowStore()
            let record = try await loadStoppedRoot(in: store, path: root.path)

            let fetchedRustDiagnostics = try await store.inventoryScopeShadowDiagnosticsForTesting()
            let rustDiagnostics = try XCTUnwrap(fetchedRustDiagnostics)
            let rootDiagnostics = try XCTUnwrap(rustDiagnostics.roots.first {
                try Self.uuid(fromRootID: $0.rootId) == record.id
            })

            XCTAssertEqual(rootDiagnostics.fallbackReasonCounts.count, 8)
            let decoded = rootDiagnostics.fallbackReasonCounts.enumerated().map { index, count in
                (CoreInventoryShardFallbackReasonV1(rawValue: UInt64(index)), count)
            }
            XCTAssertTrue(decoded.allSatisfy { $0.0 != nil }, "every positional index 0..<8 must decode to a known case")
            XCTAssertEqual(
                Set(decoded.compactMap(\.0)),
                Set(CoreInventoryShardFallbackReasonV1.allCases),
                "the 8 positions must cover exactly the 8 known cases with no gaps or duplicates"
            )
            let swiftOrder = Self.swiftFallbackReasonOrder
            XCTAssertEqual(swiftOrder.count, 8, "Swift's RootCatalogShardFallbackReason must still declare exactly 8 cases")
        }

        // MARK: - Helpers

        /// Mirrors `RootCatalogShardFallbackReason.allCases`'s declaration order
        /// (`WorkspaceFileContextStore.swift:221-230`) without importing the private type --
        /// duplicated intentionally so a future reordering on the Swift side (which
        /// `CoreInventoryShardFallbackReasonV1`'s own doc comment says must not happen without
        /// re-checking the Rust anchor) has an independent witness here too.
        private static let swiftFallbackReasonOrder: [String] = [
            "missingReusableShard", "generationGap", "fullResync", "unsafeOrAmbiguousBatch",
            "retentionBoundary", "patchThresholdExceeded", "patchApplicationBackstop", "shadowValidationMismatch"
        ]

        private static func uuid(fromRootID data: Data) throws -> UUID {
            guard data.count == 16 else {
                throw WorkspaceCatalogShardShadowDiagnosticsParityTestsError.malformedRootID(byteCount: data.count)
            }
            let bytes = [UInt8](data)
            let tuple = (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            )
            return UUID(uuid: tuple)
        }

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

    private enum WorkspaceCatalogShardShadowDiagnosticsParityTestsError: Error {
        case malformedRootID(byteCount: Int)
    }
#endif
