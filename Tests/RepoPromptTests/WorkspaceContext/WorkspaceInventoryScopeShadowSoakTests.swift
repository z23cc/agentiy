import Foundation
@testable import RepoPromptApp
import XCTest

// P4-6b prerequisite: the >=100k-file shadow soak (design doc
// `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §8.2, coverage requirement 2:
// "a real-repository soak (this repo, plus one >=100k-file tree) exercising load, edit storms,
// ... root add/unload/re-add ..., asserting zero mismatches"). This file is scoped to that
// >=100k-file synthetic tree half of the requirement -- it does not re-run this checkout itself
// (that is covered separately, e.g. by `WorkspaceInventoryScopeShadowTests`, which this file does
// not edit per the concurrent P4-6b workstream split).
//
// Coverage exercised here: bulk load across four roots (one large ~99k-file "realistic module
// tree" root that also carries the randomized delta storm; one deep-nesting root; one
// unicode-name root incl. deliberate NFC/NFD precomposed-vs-decomposed pairs; one managed-only
// root), a several-thousand-event randomized add/remove/modify/rename delta sequence on the large
// root with periodic table-arm + index-arm checkpoints, and root unload/re-add (the unicode root).
// Not covered by this file (reported, not silently assumed): FSEvents overflow/rescan replay,
// session-worktree seeding, and retention-boundary backstop soak -- these are distinct §8.2
// coverage items left for a follow-up harness; see this file's companion report for the explicit
// gap note.
//
// Scale discipline: corpus/event sizes are overridable via environment variables so this harness
// can be smoke-tested at trivial scale before the real >=100k run (this avoids discovering a
// logic bug only after a multi-minute real-scale run). The committed defaults already clear the
// >=100k gate with no overrides required.
#if DEBUG
    final class WorkspaceInventoryScopeShadowSoakTests: XCTestCase {
        private static let soakEnvironmentKey = "RP_RUN_INVENTORY_SHADOW_SOAK"

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

        // MARK: - The soak

        func testInventoryScopeShadowSoakAtRealScaleWhenEnabled() async throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment[Self.soakEnvironmentKey] == "1",
                "P4-6b prerequisite: the >=100k-file inventory-scope shadow soak is opt-in "
                    + "(multi-minute real-filesystem run). Set \(Self.soakEnvironmentKey)=1."
            )

            let config = SoakConfiguration.fromEnvironment()
            var generator = SoakSeededGenerator(state: config.seed)
            var metrics = SoakMetrics()
            let residentAtStart = Self.residentMemorySample()

            let wallStart = DispatchTime.now()

            // --- corpus generation -------------------------------------------------------
            let mainRootURL = try makeTemporaryRoot(name: "ShadowSoakMain")
            let deepRootURL = try makeTemporaryRoot(name: "ShadowSoakDeep")
            let unicodeRootURL = try makeTemporaryRoot(name: "ShadowSoakUnicode")
            let managedOnlyRootURL = try makeTemporaryRoot(name: "ShadowSoakManagedOnly")

            let mainPaths = try generateMainRootCorpus(rootURL: mainRootURL, fileCount: config.mainFileCount)
            let deepWritten = try generateDeepNestingCorpus(
                rootURL: deepRootURL,
                fileCount: config.deepNestingFileCount,
                levelCount: config.deepNestingLevelCount
            )
            let unicodeWritten = try generateUnicodeCorpus(rootURL: unicodeRootURL, fileCount: config.unicodeFileCount)
            let managedOnly = try generateManagedOnlyCorpus(
                rootURL: managedOnlyRootURL,
                discoverableCount: config.managedOnlyDiscoverableFileCount,
                ignoredCount: config.managedOnlyIgnoredFileCount
            )

            let totalCorpusFileCount = mainPaths.count + deepWritten + unicodeWritten
                + managedOnly.discoverable.count + managedOnly.ignored.count
            let corpusGeneratedAt = DispatchTime.now()

            // --- store + bulk load ---------------------------------------------------------
            let store = WorkspaceFileContextStore(
                enableCatalogShardShadowValidation: true,
                enableInventoryScopeShadowValidation: true
            )
            stores.append(store)

            // The main root gets store-level watch demand (not `loadStoppedRoot`) because the
            // storm below relies on `publishSyntheticFileSystemDeltasForTesting` actually landing
            // in the store's authoritative tables -- confirmed via this file's own predicted-count
            // cross-check that `stopWatchingRoot` tears down the store's subscription to the
            // service's delta publisher, silently no-op'ing every synthetic publish afterward
            // (exactly the vacuous-green trap this harness's checkpoints exist to catch). Matches
            // `WorkspaceInventoryScopeShadowTests.testShadowTableContentMatchesAcrossBulkLoadAddRemoveModifyAndUnload`'s
            // convention, the one sibling test that also publishes synthetic deltas post-load.
            let mainRecord = try await store.loadRoot(path: mainRootURL.path)
            try await store.startWatchingRoot(id: mainRecord.id)
            try await checkpoint(
                store: store, rootID: mainRecord.id, expectedFileCount: mainPaths.count,
                label: "main-bulk-load", metrics: &metrics
            )

            let deepRecord = try await loadStoppedRoot(in: store, path: deepRootURL.path)
            try await checkpoint(
                store: store, rootID: deepRecord.id, expectedFileCount: deepWritten,
                label: "deep-nesting-bulk-load", metrics: &metrics
            )

            let unicodeRecord = try await loadStoppedRoot(in: store, path: unicodeRootURL.path)
            try await checkpoint(
                store: store, rootID: unicodeRecord.id, expectedFileCount: unicodeWritten,
                label: "unicode-bulk-load", metrics: &metrics
            )

            let managedOnlyRecord = try await loadStoppedRoot(in: store, path: managedOnlyRootURL.path)
            // +1: the `.gitignore` file itself is a plain, non-ignored, discoverable top-level
            // file (a real .gitignore in a real repo is ordinarily tracked too) -- it is not part
            // of `managedOnly.discoverable` (that array only names the files under `Managed/`), but
            // the store legitimately counts it.
            let managedOnlyBaselineCount = managedOnly.discoverable.count + 1
            try await checkpoint(
                store: store, rootID: managedOnlyRecord.id, expectedFileCount: managedOnlyBaselineCount,
                label: "managed-only-bulk-load", metrics: &metrics
            )
            for ignoredPath in managedOnly.ignored {
                _ = try await store.materializeCatalogFileAfterDiskWrite(rootID: managedOnlyRecord.id, relativePath: ignoredPath)
            }
            // Managed-only files are explicitly ignored-path materializations: both shadow arms
            // filter on `isDiscoverableFileID`/its Rust-side equivalent, so the record count this
            // checkpoint observes must be unchanged from the pre-materialize checkpoint above --
            // the assertion that actually distinguishes "correctly excluded" from "silently never
            // wired up".
            try await checkpoint(
                store: store, rootID: managedOnlyRecord.id, expectedFileCount: managedOnlyBaselineCount,
                label: "managed-only-after-materialize", metrics: &metrics
            )

            let bulkLoadCompletedAt = DispatchTime.now()

            // --- randomized delta storm on the main root ------------------------------------
            var live = LiveFileSet()
            for path in mainPaths {
                live.insert(path)
            }
            try await runMainRootStorm(
                store: store, rootID: mainRecord.id, rootURL: mainRootURL,
                live: &live, config: config, generator: &generator, metrics: &metrics
            )

            let stormCompletedAt = DispatchTime.now()

            // --- root unload / re-add coverage (unicode root) -------------------------------
            await store.unloadRoot(id: unicodeRecord.id)
            let reloadedUnicodeRecord = try await loadStoppedRoot(in: store, path: unicodeRootURL.path)
            XCTAssertNotEqual(
                reloadedUnicodeRecord.id, unicodeRecord.id,
                "a re-added root is expected to mint a fresh root identity, not reuse the unloaded one"
            )
            try await checkpoint(
                store: store, rootID: reloadedUnicodeRecord.id, expectedFileCount: unicodeWritten,
                label: "unicode-reload", metrics: &metrics
            )

            // --- final checkpoint ------------------------------------------------------------
            try await checkpoint(
                store: store, rootID: mainRecord.id, expectedFileCount: live.count,
                label: "final", metrics: &metrics
            )

            let wallEnd = DispatchTime.now()
            let residentAtEnd = Self.residentMemorySample()

            let finalComparisonCount = await store.inventoryScopeShadowComparisonCountForTesting
            let finalMismatchCount = await store.inventoryScopeShadowMismatchCountForTesting
            let finalIndexComparisonCount = await store.inventoryScopeShadowIndexComparisonCountForTesting
            let finalIndexMismatchCount = await store.inventoryScopeShadowIndexMismatchCountForTesting

            XCTAssertEqual(finalMismatchCount, 0, "P4-6b gate requires zero table-arm shadow mismatches over the soak")
            XCTAssertEqual(finalIndexMismatchCount, 0, "P4-6b gate requires zero index-arm shadow mismatches over the soak")
            XCTAssertGreaterThanOrEqual(
                finalComparisonCount, metrics.checkpointCount,
                "shadow comparison counter did not advance as expected -- possible silent no-op"
            )
            XCTAssertGreaterThan(finalIndexComparisonCount, 0, "index-arm comparisons never ran")
            XCTAssertGreaterThanOrEqual(
                totalCorpusFileCount, 100_000,
                "P4-6b gate requires a >=100k-file corpus (this run used environment overrides that shrank it below the gate)"
            )

            let report = Self.formatReport(
                config: config,
                metrics: metrics,
                totalCorpusFileCount: totalCorpusFileCount,
                mainCorpusFileCount: mainPaths.count,
                deepCorpusFileCount: deepWritten,
                unicodeCorpusFileCount: unicodeWritten,
                managedOnlyDiscoverableCount: managedOnly.discoverable.count,
                managedOnlyIgnoredCount: managedOnly.ignored.count,
                finalLiveMainFileCount: live.count,
                wallMillisecondsCorpusGeneration: Self.elapsedMilliseconds(from: wallStart, to: corpusGeneratedAt),
                wallMillisecondsBulkLoad: Self.elapsedMilliseconds(from: corpusGeneratedAt, to: bulkLoadCompletedAt),
                wallMillisecondsStorm: Self.elapsedMilliseconds(from: bulkLoadCompletedAt, to: stormCompletedAt),
                wallMillisecondsTotal: Self.elapsedMilliseconds(from: wallStart, to: wallEnd),
                residentAtStart: residentAtStart,
                residentAtEnd: residentAtEnd,
                finalComparisonCount: finalComparisonCount,
                finalMismatchCount: finalMismatchCount,
                finalIndexComparisonCount: finalIndexComparisonCount,
                finalIndexMismatchCount: finalIndexMismatchCount
            )
            print(report)
        }

        // MARK: - Checkpoint (table arm + index arm + predicted-count cross-check)

        /// A checkpoint does three things every time, deliberately in this order, per the design
        /// doc §8.2 coverage requirement: (1) cross-checks the soak's own tracked live-file count
        /// against the store's authoritative snapshot -- this is what would catch a delta silently
        /// no-op'ing (both shadow arms would trivially "match" on an unchanged, untouched root);
        /// (2) the table-arm byte compare; (3) the index-arm ordered-candidate compare, first
        /// forcing `searchCatalogSnapshot` so the path index is actually built (its absence would
        /// otherwise make the index arm silently return zero reports, which is not a pass).
        @discardableResult
        private func checkpoint(
            store: WorkspaceFileContextStore,
            rootID: UUID,
            expectedFileCount: Int,
            label: String,
            metrics: inout SoakMetrics
        ) async throws -> WorkspaceFileContextStore.WorkspaceInventoryScopeShadowComparisonReport {
            let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            let observedFileCount = snapshot.files.count(where: { $0.rootID == rootID })
            XCTAssertEqual(
                observedFileCount, expectedFileCount,
                "[\(label)] Swift file count diverged from the soak's tracked live set -- possible silent delta no-op"
            )

            let tableReport = try await store.compareInventoryScopeShadowForTesting(rootID: rootID)
            XCTAssertTrue(tableReport.matched, "[\(label)] table-arm mismatch: \(tableReport)")

            let indexReports = try await store.compareInventoryScopeShadowIndexForTesting(rootID: rootID)
            XCTAssertFalse(indexReports.isEmpty, "[\(label)] index-arm returned no reports -- path index likely not built")
            for report in indexReports {
                XCTAssertTrue(
                    report.matched,
                    "[\(label)] index-arm mismatch for query \(report.query.isEmpty ? "<empty>" : report.query): "
                        + "swift=\(report.swiftOrder) rust=\(report.rustOrder)"
                )
            }

            metrics.checkpointCount += 1
            if let sample = Self.residentMemorySample() {
                metrics.lastObservedResidentBytes = sample.current
            }
            print(
                "[P4-6b shadow soak] checkpoint=\(label) files=\(observedFileCount) "
                    + "tableMatched=\(tableReport.matched) indexReportCount=\(indexReports.count) "
                    + "swiftRecordCount=\(tableReport.swiftRecordCount) rustRecordCount=\(tableReport.rustRecordCount)"
            )
            return tableReport
        }

        // MARK: - Randomized delta storm

        private enum SoakEventKind {
            case add
            case remove
            case modify
            case rename
        }

        /// Several-thousand-event randomized add/remove/modify/rename sequence against the large
        /// main root, deliberately mixing single-delta publications with larger "edit storm"
        /// batches (a randomly chosen ~15% of batches are sized 10-30 rather than 1-3), and
        /// checkpointing every `config.checkpointInterval` operations. Renames are represented as
        /// `[.fileRemoved(old), .fileAdded(new)]` in one publish call (there is no dedicated
        /// rename delta in `FileSystemDelta` -- this matches how the production watcher/replay
        /// path itself represents a rename).
        private func runMainRootStorm(
            store: WorkspaceFileContextStore,
            rootID: UUID,
            rootURL: URL,
            live: inout LiveFileSet,
            config: SoakConfiguration,
            generator: inout SoakSeededGenerator,
            metrics: inout SoakMetrics
        ) async throws {
            var createdChurnDirectories = Set<String>()
            var pendingDeltas: [FileSystemDelta] = []
            var currentBatchTarget = 1
            var opsSinceCheckpoint = 0

            for eventIndex in 0 ..< config.eventCount {
                if pendingDeltas.isEmpty {
                    currentBatchTarget = generator.nextInt(100) < 15
                        ? (10 + generator.nextInt(21))
                        : (1 + generator.nextInt(3))
                }

                let roll = generator.nextInt(100)
                let kind: SoakEventKind = if live.count == 0 {
                    .add
                } else if roll < 35 {
                    .add
                } else if roll < 55 {
                    .remove
                } else if roll < 85 {
                    .modify
                } else {
                    .rename
                }

                switch kind {
                case .add:
                    let moduleIndex = generator.nextInt(400)
                    let relativePath = String(
                        format: "Modules/Feature-%03d/Churn/Added-%07d-%08d.swift",
                        moduleIndex, eventIndex, generator.nextInt(99_999_999)
                    )
                    try writeFile(
                        "// soak churn add \(eventIndex)\n", relativePath: relativePath,
                        under: rootURL, createdDirectories: &createdChurnDirectories
                    )
                    pendingDeltas.append(.fileAdded(relativePath))
                    live.insert(relativePath)
                    metrics.addCount += 1

                case .remove:
                    guard let path = live.randomPath(using: &generator) else { continue }
                    try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(path))
                    pendingDeltas.append(.fileRemoved(path))
                    live.remove(path)
                    metrics.removeCount += 1

                case .modify:
                    guard let path = live.randomPath(using: &generator) else { continue }
                    try writeFile(
                        "// soak churn modify \(eventIndex)\n", relativePath: path,
                        under: rootURL, createdDirectories: &createdChurnDirectories
                    )
                    pendingDeltas.append(.fileModified(path, nil))
                    metrics.modifyCount += 1

                case .rename:
                    guard let oldPath = live.randomPath(using: &generator) else { continue }
                    let moduleIndex = generator.nextInt(400)
                    let newPath = String(
                        format: "Modules/Feature-%03d/Churn/Renamed-%07d-%08d.swift",
                        moduleIndex, eventIndex, generator.nextInt(99_999_999)
                    )
                    try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(oldPath))
                    try writeFile(
                        "// soak churn rename \(eventIndex)\n", relativePath: newPath,
                        under: rootURL, createdDirectories: &createdChurnDirectories
                    )
                    pendingDeltas.append(contentsOf: [.fileRemoved(oldPath), .fileAdded(newPath)])
                    live.remove(oldPath)
                    live.insert(newPath)
                    metrics.renameCount += 1
                }

                opsSinceCheckpoint += 1

                if pendingDeltas.count >= currentBatchTarget {
                    try await store.publishSyntheticFileSystemDeltasForTesting(rootID: rootID, deltas: pendingDeltas)
                    pendingDeltas.removeAll(keepingCapacity: true)
                    _ = await store.flushPendingServiceEventsForAllRoots()
                }

                if opsSinceCheckpoint >= config.checkpointInterval {
                    if !pendingDeltas.isEmpty {
                        try await store.publishSyntheticFileSystemDeltasForTesting(rootID: rootID, deltas: pendingDeltas)
                        pendingDeltas.removeAll(keepingCapacity: true)
                        _ = await store.flushPendingServiceEventsForAllRoots()
                    }
                    try await checkpoint(
                        store: store, rootID: rootID, expectedFileCount: live.count,
                        label: "main-storm@\(eventIndex + 1)", metrics: &metrics
                    )
                    opsSinceCheckpoint = 0
                }
            }

            if !pendingDeltas.isEmpty {
                try await store.publishSyntheticFileSystemDeltasForTesting(rootID: rootID, deltas: pendingDeltas)
                _ = await store.flushPendingServiceEventsForAllRoots()
            }
        }

        // MARK: - Corpus generation

        /// Mirrors `InventoryScopeSwiftBaselineTests`' grouping convention (~100 files per
        /// module/layer group) with added realism: a minority of files land under `Tests/` or
        /// `Resources/` siblings with different extensions, rather than every file being an
        /// identically-shaped `.swift` leaf.
        private static func mainRootRelativePath(fileIndex: Int) -> String {
            let groupIndex = fileIndex / 100
            let moduleIndex = groupIndex % 400
            let layerIndex = groupIndex % 8
            switch fileIndex % 10 {
            case 0 ... 6:
                return String(
                    format: "Modules/Feature-%03d/Sources/Layer-%02d/Component-%06d.swift",
                    moduleIndex, layerIndex, fileIndex
                )
            case 7:
                return String(format: "Modules/Feature-%03d/Tests/ComponentTests-%06d.swift", moduleIndex, fileIndex)
            case 8:
                return String(format: "Modules/Feature-%03d/Resources/manifest-%06d.json", moduleIndex, fileIndex)
            default:
                return String(format: "Modules/Feature-%03d/README-%06d.md", moduleIndex, fileIndex)
            }
        }

        private func generateMainRootCorpus(rootURL: URL, fileCount: Int) throws -> [String] {
            var createdDirectories = Set<String>()
            var paths: [String] = []
            paths.reserveCapacity(fileCount)
            for fileIndex in 0 ..< fileCount {
                let relativePath = Self.mainRootRelativePath(fileIndex: fileIndex)
                try writeFile(
                    "// soak seed component \(fileIndex)\n", relativePath: relativePath,
                    under: rootURL, createdDirectories: &createdDirectories
                )
                paths.append(relativePath)
            }
            return paths
        }

        /// Builds a single deep chain (`Level-00/Level-01/.../Level-<levelCount>`) and places
        /// files only in its deeper half, so every placed file sits behind a long parent-folder
        /// chain -- the "deep nesting" corpus attribute.
        private func generateDeepNestingCorpus(rootURL: URL, fileCount: Int, levelCount: Int) throws -> Int {
            var createdDirectories = Set<String>()
            var written = 0
            var fileIndex = 0
            let startLevel = max(1, levelCount - 14)
            let usableLevels = max(1, levelCount - startLevel + 1)
            let perLevel = max(1, (fileCount + usableLevels - 1) / usableLevels)
            for level in startLevel ... levelCount {
                let chain = (0 ... level).map { String(format: "Level-%02d", $0) }.joined(separator: "/")
                for _ in 0 ..< perLevel {
                    guard written < fileCount else { return written }
                    let relativePath = chain + String(format: "/Deep-%06d.swift", fileIndex)
                    try writeFile(
                        "// soak deep nested file \(fileIndex)\n", relativePath: relativePath,
                        under: rootURL, createdDirectories: &createdDirectories
                    )
                    fileIndex += 1
                    written += 1
                }
            }
            return written
        }

        /// Deliberately includes an NFC/NFD precomposed-vs-decomposed pair ("Café" via U+00E9 vs
        /// "Cafe" + U+0301) -- the likeliest real divergence point between Swift's
        /// `standardizedRelativePath` normalization and Rust's index-key handling (advisor
        /// guidance: this is a genuine gate finding to *report*, not to soften the comparator
        /// around, if it traps).
        private static let unicodeFolderNames = [
            "Café", "Cafe\u{0301}", "文件夹", "フォルダ", "Папка", "مجلد", "📁Emoji", "Ångström", "Straße", "Naïve-Résumé"
        ]
        private static let unicodeFileBaseNames = [
            "měřidlo", "🔥flame", "north-étoile", "north-e\u{0301}toile", "Ω-omega", "Δ-delta", "한글파일", "テスト", "אבג", "Zürich"
        ]

        private func generateUnicodeCorpus(rootURL: URL, fileCount: Int) throws -> Int {
            var createdDirectories = Set<String>()
            var written = 0
            var fileIndex = 0
            let filesPerFolder = 20
            let folderCount = max(1, (fileCount + filesPerFolder - 1) / filesPerFolder)
            outer: for folderIndex in 0 ..< folderCount {
                let folderName = "\(Self.unicodeFolderNames[folderIndex % Self.unicodeFolderNames.count])-\(folderIndex)"
                for _ in 0 ..< filesPerFolder {
                    guard written < fileCount else { break outer }
                    let baseName = Self.unicodeFileBaseNames[fileIndex % Self.unicodeFileBaseNames.count]
                    let relativePath = "\(folderName)/\(baseName)-\(fileIndex).swift"
                    try writeFile(
                        "// soak unicode file \(fileIndex)\n", relativePath: relativePath,
                        under: rootURL, createdDirectories: &createdDirectories
                    )
                    fileIndex += 1
                    written += 1
                }
            }
            return written
        }

        /// Writes a plain discoverable set plus a `.gitignore`'d `IgnoredChurn/` subtree. The
        /// ignored files are intentionally *not* materialized here -- the caller materializes them
        /// explicitly via `materializeCatalogFileAfterDiskWrite` after bulk load, matching the
        /// production "explicit app/MCP write to an otherwise-ignored path" flow the managed-only
        /// mechanism exists for.
        private func generateManagedOnlyCorpus(
            rootURL: URL,
            discoverableCount: Int,
            ignoredCount: Int
        ) throws -> (discoverable: [String], ignored: [String]) {
            var createdDirectories = Set<String>()
            try writeFile("IgnoredChurn/\n", relativePath: ".gitignore", under: rootURL, createdDirectories: &createdDirectories)

            var discoverable: [String] = []
            discoverable.reserveCapacity(discoverableCount)
            for fileIndex in 0 ..< discoverableCount {
                let groupIndex = fileIndex / 50
                let relativePath = String(format: "Managed/Group-%03d/Visible-%06d.swift", groupIndex, fileIndex)
                try writeFile(
                    "// soak managed-visible file \(fileIndex)\n", relativePath: relativePath,
                    under: rootURL, createdDirectories: &createdDirectories
                )
                discoverable.append(relativePath)
            }

            var ignored: [String] = []
            ignored.reserveCapacity(ignoredCount)
            for fileIndex in 0 ..< ignoredCount {
                let relativePath = String(format: "IgnoredChurn/managed-%06d.swift", fileIndex)
                try writeFile(
                    "// soak managed-only ignored file \(fileIndex)\n", relativePath: relativePath,
                    under: rootURL, createdDirectories: &createdDirectories
                )
                ignored.append(relativePath)
            }
            return (discoverable, ignored)
        }

        // MARK: - Disk / store helpers

        private func writeFile(
            _ content: String,
            relativePath: String,
            under rootURL: URL,
            createdDirectories: inout Set<String>
        ) throws {
            let url = rootURL.appendingPathComponent(relativePath)
            let directoryURL = url.deletingLastPathComponent()
            let directoryPath = directoryURL.path
            if !createdDirectories.contains(directoryPath) {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                createdDirectories.insert(directoryPath)
            }
            FileManager.default.createFile(atPath: url.path, contents: Data(content.utf8))
        }

        private func loadStoppedRoot(in store: WorkspaceFileContextStore, path: String) async throws -> WorkspaceRootRecord {
            let root = try await store.loadRoot(path: path)
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

        // MARK: - Live-set bookkeeping (predicted-count cross-check)

        /// O(1) insert/remove-by-swap tracking of the main root's currently-live relative paths,
        /// used purely so the soak can predict the Swift-side file count independently of the
        /// store and catch a delta that silently no-op'd (advisor guidance: the trap where zero
        /// mismatches means nothing moved rather than everything matched).
        private struct LiveFileSet {
            private(set) var paths: [String] = []
            private var indexByPath: [String: Int] = [:]

            mutating func insert(_ path: String) {
                guard indexByPath[path] == nil else { return }
                indexByPath[path] = paths.count
                paths.append(path)
            }

            mutating func remove(_ path: String) {
                guard let index = indexByPath.removeValue(forKey: path) else { return }
                let last = paths.removeLast()
                if index < paths.count {
                    paths[index] = last
                    indexByPath[last] = index
                }
            }

            func randomPath(using generator: inout SoakSeededGenerator) -> String? {
                guard !paths.isEmpty else { return nil }
                return paths[generator.nextInt(paths.count)]
            }

            var count: Int {
                paths.count
            }
        }

        // MARK: - Configuration, metrics, RNG

        private struct SoakConfiguration {
            let mainFileCount: Int
            let deepNestingFileCount: Int
            let deepNestingLevelCount: Int
            let unicodeFileCount: Int
            let managedOnlyDiscoverableFileCount: Int
            let managedOnlyIgnoredFileCount: Int
            let eventCount: Int
            let checkpointInterval: Int
            let seed: UInt64

            static func fromEnvironment() -> SoakConfiguration {
                func intEnv(_ key: String, default defaultValue: Int) -> Int {
                    guard let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value > 0 else {
                        return defaultValue
                    }
                    return value
                }
                return SoakConfiguration(
                    mainFileCount: intEnv("RP_CE_INVENTORY_SHADOW_SOAK_MAIN_FILE_COUNT", default: 99000),
                    deepNestingFileCount: intEnv("RP_CE_INVENTORY_SHADOW_SOAK_DEEP_FILE_COUNT", default: 500),
                    deepNestingLevelCount: intEnv("RP_CE_INVENTORY_SHADOW_SOAK_DEEP_LEVEL_COUNT", default: 24),
                    unicodeFileCount: intEnv("RP_CE_INVENTORY_SHADOW_SOAK_UNICODE_FILE_COUNT", default: 500),
                    managedOnlyDiscoverableFileCount: intEnv("RP_CE_INVENTORY_SHADOW_SOAK_MANAGED_ONLY_FILE_COUNT", default: 500),
                    managedOnlyIgnoredFileCount: intEnv("RP_CE_INVENTORY_SHADOW_SOAK_MANAGED_ONLY_IGNORED_COUNT", default: 40),
                    eventCount: intEnv("RP_CE_INVENTORY_SHADOW_SOAK_EVENT_COUNT", default: 4000),
                    checkpointInterval: intEnv("RP_CE_INVENTORY_SHADOW_SOAK_CHECKPOINT_INTERVAL", default: 400),
                    // Fixed seed (not overridable) so a failing run is exactly reproducible,
                    // matching the E-3 Rust soak's documented-seed convention
                    // (rust/benchmarks/results/v1/p4-2-inventory-scope-derisking-v1.md section 6).
                    seed: 0x5350_494B_4534_2036
                )
            }
        }

        private struct SoakMetrics {
            var addCount = 0
            var removeCount = 0
            var modifyCount = 0
            var renameCount = 0
            var checkpointCount = 0
            var lastObservedResidentBytes: UInt64 = 0
        }

        /// Simple splitmix-style LCG, deliberately not `SystemRandomNumberGenerator` (which is
        /// non-deterministic) and not derived from `Set`/`Dictionary` iteration order (which is
        /// per-run hash-seeded) -- matches `RustSearchSeededGenerator`'s convention
        /// (`Tests/RepoPromptSearchCoreTests/RustSearchDifferentialTests.swift`).
        private struct SoakSeededGenerator {
            var state: UInt64

            mutating func nextUInt64() -> UInt64 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return state
            }

            mutating func nextInt(_ upperBound: Int) -> Int {
                guard upperBound > 0 else { return 0 }
                return Int(nextUInt64() % UInt64(upperBound))
            }
        }

        // MARK: - Memory sampling + reporting

        private static func residentMemorySample() -> (current: UInt64, peakMax: UInt64)? {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return (info.resident_size, info.resident_size_max)
        }

        private static func elapsedMilliseconds(from start: DispatchTime, to end: DispatchTime) -> Double {
            Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        }

        private static func formatReport(
            config: SoakConfiguration,
            metrics: SoakMetrics,
            totalCorpusFileCount: Int,
            mainCorpusFileCount: Int,
            deepCorpusFileCount: Int,
            unicodeCorpusFileCount: Int,
            managedOnlyDiscoverableCount: Int,
            managedOnlyIgnoredCount: Int,
            finalLiveMainFileCount: Int,
            wallMillisecondsCorpusGeneration: Double,
            wallMillisecondsBulkLoad: Double,
            wallMillisecondsStorm: Double,
            wallMillisecondsTotal: Double,
            residentAtStart: (current: UInt64, peakMax: UInt64)?,
            residentAtEnd: (current: UInt64, peakMax: UInt64)?,
            finalComparisonCount: Int,
            finalMismatchCount: Int,
            finalIndexComparisonCount: Int,
            finalIndexMismatchCount: Int
        ) -> String {
            func mb(_ bytes: UInt64?) -> String {
                guard let bytes else { return "unavailable" }
                return String(format: "%.2f MB", Double(bytes) / 1024 / 1024)
            }
            var lines = [
                "REPOPROMPT_CE_INVENTORY_SHADOW_SOAK_BEGIN",
                "seed=0x\(String(config.seed, radix: 16))",
                "corpus: main=\(mainCorpusFileCount) deepNesting=\(deepCorpusFileCount) unicode=\(unicodeCorpusFileCount) "
                    + "managedOnlyDiscoverable=\(managedOnlyDiscoverableCount) managedOnlyIgnored=\(managedOnlyIgnoredCount) "
                    + "total=\(totalCorpusFileCount) (gate: >=100000)",
                "events: add=\(metrics.addCount) remove=\(metrics.removeCount) modify=\(metrics.modifyCount) "
                    + "rename=\(metrics.renameCount) total=\(metrics.addCount + metrics.removeCount + metrics.modifyCount + metrics.renameCount) "
                    + "checkpoints=\(metrics.checkpointCount) finalLiveMainFileCount=\(finalLiveMainFileCount)",
                "wall (ms): corpusGeneration=\(String(format: "%.1f", wallMillisecondsCorpusGeneration)) "
                    + "bulkLoad=\(String(format: "%.1f", wallMillisecondsBulkLoad)) "
                    + "storm=\(String(format: "%.1f", wallMillisecondsStorm)) "
                    + "total=\(String(format: "%.1f", wallMillisecondsTotal))",
                "memory: residentAtStart=\(mb(residentAtStart?.current)) residentAtEnd=\(mb(residentAtEnd?.current)) "
                    + "peakResidentSizeMax=\(mb(residentAtEnd?.peakMax))",
                "shadow: tableComparisons=\(finalComparisonCount) tableMismatches=\(finalMismatchCount) "
                    + "indexComparisons=\(finalIndexComparisonCount) indexMismatches=\(finalIndexMismatchCount)",
                "verdict: \(finalMismatchCount == 0 && finalIndexMismatchCount == 0 ? "PASS -- zero shadow mismatches" : "FAIL -- see mismatch counts above")",
                "not covered by this harness: FSEvents overflow/rescan replay, session-worktree seeding, "
                    + "retention-boundary backstop soak (distinct \u{00a7}8.2 coverage items; see file header)",
                "REPOPROMPT_CE_INVENTORY_SHADOW_SOAK_END"
            ]
            if config.mainFileCount != 99000 || config.eventCount != 4000 {
                lines.insert(
                    "NOTE: run with non-default environment overrides (mainFileCount=\(config.mainFileCount), "
                        + "eventCount=\(config.eventCount)) -- not necessarily a P4-6b gate-qualifying run.",
                    at: 1
                )
            }
            return lines.joined(separator: "\n")
        }
    }
#endif
