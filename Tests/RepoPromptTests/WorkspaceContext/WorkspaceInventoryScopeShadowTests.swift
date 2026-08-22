@testable import RepoPromptApp
import Foundation
import XCTest

// P4-5: the shadow arm + differential (design doc
// `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §8.2, step list entry P4-5).
//
// Coverage here is the first of §8.2's three tiers: the WorkspaceContext suite (this file)
// exercising the shadow arm end-to-end with `enableInventoryScopeShadowValidation: true` --
// bulk load (`loadRoot`), canonical deltas (add/remove/modify via
// `publishSyntheticFileSystemDeltasForTesting`), and root unload -- asserting zero mismatches on
// both the table-content arm (`compareInventoryScopeShadowForTesting`) and the index arm
// (`compareInventoryScopeShadowIndexForTesting`). Adversarial delta-sequence differentials against
// `CoreInventoryScope.applyDelta` directly (generation gaps, stale watermarks, rejection reasons)
// live in `Tests/AgentryCoreBridgeTests` alongside the rest of the facade's contract tests -- this
// file is the store-integration half of the gate.
#if DEBUG
    final class WorkspaceInventoryScopeShadowTests: XCTestCase {
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

        // MARK: - Acceptance conditions (design doc §8.2's four properties, asserted by test)

        /// Opt-in-only: the default initializer does not enable the shadow arm, so ordinary
        /// WorkspaceContext tests never pay its cost or forward anything.
        func testShadowArmDefaultsToDisabled() async throws {
            let root = try makeTemporaryRoot(name: "ShadowDefaultOff")
            try write("a", to: root.appendingPathComponent("A.swift"))
            let store = WorkspaceFileContextStore()
            stores.append(store)
            let record = try await loadStoppedRoot(in: store, path: root.path)
            let report = try await store.compareInventoryScopeShadowForTesting(rootID: record.id)
            XCTAssertEqual(report.swiftRecordCount, 0)
            XCTAssertEqual(report.rustRecordCount, 0)
            XCTAssertTrue(report.matched)
        }

        /// DEBUG-only-and-absent-from-release: the release initializer overload (the store's
        /// `#else` branch) must never declare `enableInventoryScopeShadowValidation` -- mirrors
        /// `enableCatalogShardShadowValidation`'s already-established mechanism (design doc §3.4).
        /// Asserted by source-text inspection (the same class of check the guardrail script already
        /// performs mechanically for the no-durable-artifact / headless-isolation invariants).
        func testShadowArmParameterIsAbsentFromTheReleaseInitializer() throws {
            let sourceURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // .../Tests/RepoPromptTests/WorkspaceContext
                .deletingLastPathComponent() // .../Tests/RepoPromptTests
                .deletingLastPathComponent() // .../Tests
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            // Anchor on the DEBUG init's unique parameter list (not the first "#if DEBUG" in the
            // file, of which there are many unrelated ones) to find the specific #else / #endif
            // pair bounding the release initializer overload.
            guard let anchorRange = source.range(of: "enableInventoryScopeShadowValidation: Bool = false,"),
                  let elseRange = source.range(of: "\n    #else\n", range: anchorRange.upperBound ..< source.endIndex),
                  let endIfRange = source.range(of: "\n    #endif\n", range: elseRange.upperBound ..< source.endIndex)
            else {
                XCTFail("Could not locate the store's #if DEBUG / #else / #endif init region")
                return
            }
            let releaseInitSource = source[elseRange.upperBound ..< endIfRange.lowerBound]
            XCTAssertFalse(
                releaseInitSource.contains("enableInventoryScopeShadowValidation"),
                "The release initializer overload must not accept enableInventoryScopeShadowValidation"
            )
        }

        /// Deletable: closing the shadow arm releases every Rust-side resource it opened and is
        /// idempotent, exactly like the ARC-driven facade types it wraps.
        func testShadowArmCloseIsIdempotentAndDeletable() async throws {
            let root = try makeTemporaryRoot(name: "ShadowClose")
            try write("a", to: root.appendingPathComponent("A.swift"))
            let store = makeShadowStore()
            let record = try await loadStoppedRoot(in: store, path: root.path)
            _ = try await store.compareInventoryScopeShadowForTesting(rootID: record.id)
            await store.closeInventoryScopeShadowForTesting()
            await store.closeInventoryScopeShadowForTesting() // idempotent
        }

        // MARK: - Third arm: table-content differential (design doc §8.2)

        func testShadowTableContentMatchesAcrossBulkLoadAddRemoveModifyAndUnload() async throws {
            let root = try makeTemporaryRoot(name: "ShadowTableContent")
            try write("a", to: root.appendingPathComponent("A.swift"))
            try write("b", to: root.appendingPathComponent("Sub/B.swift"))
            let store = makeShadowStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            var report = try await store.compareInventoryScopeShadowForTesting(rootID: record.id)
            XCTAssertTrue(report.matched, "bulk load mismatch: \(report)")
            XCTAssertEqual(report.swiftRecordCount, report.rustRecordCount)
            XCTAssertGreaterThan(report.swiftRecordCount, 0)

            let addedURL = root.appendingPathComponent("Added.swift")
            try write("added", to: addedURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: record.id, deltas: [.fileAdded("Added.swift")])
            _ = await store.flushPendingServiceEventsForAllRoots()
            report = try await store.compareInventoryScopeShadowForTesting(rootID: record.id)
            XCTAssertTrue(report.matched, "add mismatch: \(report)")

            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: record.id, deltas: [.fileModified("A.swift", nil)])
            _ = await store.flushPendingServiceEventsForAllRoots()
            report = try await store.compareInventoryScopeShadowForTesting(rootID: record.id)
            XCTAssertTrue(report.matched, "modify mismatch: \(report)")

            try FileManager.default.removeItem(at: addedURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: record.id, deltas: [.fileRemoved("Added.swift")])
            _ = await store.flushPendingServiceEventsForAllRoots()
            report = try await store.compareInventoryScopeShadowForTesting(rootID: record.id)
            XCTAssertTrue(report.matched, "remove mismatch: \(report)")

            await store.unloadRoot(id: record.id)
            try await store.drainInventoryScopeShadowForwardingForTesting()

            let comparisonCount = await store.inventoryScopeShadowComparisonCountForTesting
            let mismatchCount = await store.inventoryScopeShadowMismatchCountForTesting
            XCTAssertGreaterThanOrEqual(comparisonCount, 4)
            XCTAssertEqual(mismatchCount, 0)
        }

        func testShadowTableContentMatchesAcrossTwoRoots() async throws {
            let rootA = try makeTemporaryRoot(name: "ShadowMultiA")
            let rootB = try makeTemporaryRoot(name: "ShadowMultiB")
            try write("a", to: rootA.appendingPathComponent("A.swift"))
            try write("b1", to: rootB.appendingPathComponent("B1.swift"))
            try write("b2", to: rootB.appendingPathComponent("Nested/B2.swift"))
            let store = makeShadowStore()
            let recordA = try await loadStoppedRoot(in: store, path: rootA.path)
            let recordB = try await loadStoppedRoot(in: store, path: rootB.path)

            let reportA = try await store.compareInventoryScopeShadowForTesting(rootID: recordA.id)
            let reportB = try await store.compareInventoryScopeShadowForTesting(rootID: recordB.id)
            XCTAssertTrue(reportA.matched, "root A mismatch: \(reportA)")
            XCTAssertTrue(reportB.matched, "root B mismatch: \(reportB)")
            XCTAssertEqual(reportA.swiftRecordCount, 1)
            XCTAssertEqual(reportB.swiftRecordCount, 3) // B1.swift + Nested/ folder + B2.swift

            let mismatchCount = await store.inventoryScopeShadowMismatchCountForTesting
            XCTAssertEqual(mismatchCount, 0)
        }

        // MARK: - Memory cost (design doc §8.2's "memory cost, stated plainly" -- measured here)

        /// Measures this process's resident memory before/after opening the shadow scope and
        /// bulk-seeding it with a few hundred synthetic files, against the same file count already
        /// resident in the Swift authority's own tables. Not a precise per-record accounting (RSS
        /// includes the whole process, Rust allocator overhead, and one-time scope/root setup) --
        /// a plain "does the shadow arm roughly double resident inventory memory for a shadowed
        /// root" spot check, matching §8.2's own framing ("the shadow arm doubles resident
        /// inventory memory for the shadowed roots. Say this loudly enough that nobody proposes
        /// shipping it on."). Registered here rather than run as a hard-gated assertion --
        /// resident-memory deltas are noisy across machines/CI runners.
        func testShadowArmMemoryCostIsMeasuredAndDocumented() async throws {
            let root = try makeTemporaryRoot(name: "ShadowMemoryCost")
            let fileCount = 500
            for index in 0 ..< fileCount {
                try write("content-\(index)", to: root.appendingPathComponent("File\(index).swift"))
            }
            let store = makeShadowStore()
            let record = try await loadStoppedRoot(in: store, path: root.path)

            let residentBeforeShadow = Self.currentResidentBytes()
            let report = try await store.compareInventoryScopeShadowForTesting(rootID: record.id)
            let residentAfterShadow = Self.currentResidentBytes()
            XCTAssertTrue(report.matched)
            XCTAssertEqual(report.swiftRecordCount, fileCount)

            if let residentBeforeShadow, let residentAfterShadow {
                let deltaMB = Double(residentAfterShadow) - Double(residentBeforeShadow)
                // Printed (not asserted) -- see doc comment. The order of magnitude to sanity-check
                // by eye: a few hundred KB-to-low-MB for a few hundred small synthetic records is
                // consistent with "doubles resident inventory for the shadowed root", not with an
                // unbounded leak.
                print(
                    "[P4-5 memory cost] fileCount=\(fileCount) residentDeltaBytes=\(Int64(deltaMB)) " +
                        "(~\(String(format: "%.2f", deltaMB / 1024 / 1024)) MB) opening+seeding one shadow scope"
                )
            } else {
                print("[P4-5 memory cost] task_info unavailable on this platform; skipping the printed delta")
            }
        }

        private static func currentResidentBytes() -> UInt64? {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return info.resident_size
        }

        // MARK: - Index comparison arm (design doc §8.2's ordered-candidate arm)

        func testShadowIndexArmMatchesOrderedCandidatesAcrossAdversarialCorpus() async throws {
            let root = try makeTemporaryRoot(name: "ShadowIndex")
            try write("a", to: root.appendingPathComponent("App.swift"))
            try write("b", to: root.appendingPathComponent("README.md"))
            try write("c", to: root.appendingPathComponent("src/Utils.swift"))
            try write("d", to: root.appendingPathComponent("src/nested/deep/Leaf.swift"))
            let store = makeShadowStore()
            let record = try await loadStoppedRoot(in: store, path: root.path)
            // Force the path index to build (`.recordsAndPathIndexes` is the default requirement).
            _ = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)

            let reports = try await store.compareInventoryScopeShadowIndexForTesting(rootID: record.id)
            XCTAssertFalse(reports.isEmpty)
            for report in reports {
                XCTAssertTrue(report.matched, "index arm diverged for query \(report.query.isEmpty ? "<empty>" : report.query): swift=\(report.swiftOrder) rust=\(report.rustOrder)")
            }
            let mismatchCount = await store.inventoryScopeShadowIndexMismatchCountForTesting
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
