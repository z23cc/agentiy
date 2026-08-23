import Foundation
@testable import RepoPromptApp
import XCTest

/// P4-1 contract freeze (docs/architecture/rust-inventory-scope-v1.md §8): captures the Swift
/// reference-arm baseline for de-risking experiment E-1 ("delta-path viability, kill criterion for
/// the whole design", `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §10) *before*
/// any Rust `InventoryScope` candidate exists, per that design's binding requirement to register
/// absolute/relative SLOs ahead of seeing candidate numbers (charter §15.3 item 3).
///
/// This intentionally follows the now-retired `InventoryCutoverBenchmarkTests`' env-gated
/// conventions (same `DispatchTime`-based measurement, same warmup/sample shape, same size points;
/// that harness benchmarked the same production entry points against the P3-2
/// `RustInventoryComputer` seam, retired at P4-8) but measures only the Swift side: there is no
/// P4 Rust candidate yet, so there is nothing to pair it against. The reference arm reuses the
/// exact same production entry points
/// (`WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents` /
/// `.buildRootCatalogShardPatch`), so this harness adds a size point (100 files, per E-1's
/// requirement that small roots are measured, not skipped) rather than a new code path.
///
/// Scope note (reported alongside the P4-1 deliverable): this harness captures E-1's reference
/// numbers only. E-1d (batch point-lookup cost curve), E-2 (read economics incl. the mention-path
/// suggestion query and B2 projected-shard page), and E-4 (contention) do not yet have a captured
/// Swift baseline number here -- `rust/benchmarks/slo-v1.json`'s `inventoryScopeV1` section
/// registers their absolute/relative targets and marks the still-missing baselines as pending
/// rather than fabricating a number.
final class InventoryScopeSwiftBaselineTests: XCTestCase {
    private static let baselineEnvironmentKey = "RP_RUN_INVENTORY_SCOPE_SWIFT_BASELINE"
    private static let measuredIterationCount = 5

    private struct Distribution {
        let p50Milliseconds: Double
        let p99Milliseconds: Double
    }

    private struct ResultRow {
        let operation: String
        let size: String
        let swift: Distribution
    }

    private struct AuthoritativeFixture {
        let roots: [WorkspaceRootRecord]
        let filesByID: [UUID: WorkspaceFileRecord]
        let foldersByID: [UUID: WorkspaceFolderRecord]
    }

    private struct PatchFixture {
        let event: WorkspaceAppliedIndexBatchEvent
        let previousFiles: [WorkspaceFileRecord]
        let filesByID: [UUID: WorkspaceFileRecord]
    }

    /// E-1's pass criteria (`p4-workspace-inventory-authority-v2-2026-08-22.md` §10):
    /// - large roots (10k/100k): single-delta apply <= 1.10x this Swift reference.
    /// - small roots (100/1k): absolute single-delta apply < 50 microseconds, p99 < 200 microseconds
    ///   -- a bound on the *candidate*, not the Swift reference, but this harness reports the Swift
    ///   reference at the same sizes so the two numbers are read side by side.
    func testSwiftInventoryScopeE1DeltaApplyBaseline() throws {
        guard ProcessInfo.processInfo.environment[Self.baselineEnvironmentKey] == "1" else {
            throw XCTSkip("Set \(Self.baselineEnvironmentKey)=1 to run the P4-1 Swift SLO baseline capture.")
        }

        var rows: [ResultRow] = []

        for fileCount in [100, 1000, 10000, 100_000] {
            let fixture = Self.makeAuthoritativeFixture(fileCount: fileCount)
            let distribution = measure {
                let result = WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents(
                    roots: fixture.roots,
                    filesByID: fixture.filesByID,
                    foldersByID: fixture.foldersByID,
                    managedOnlyFileIDs: [],
                    managedOnlyFolderIDs: []
                )
                return result.files.count + result.folders.count + result.entries.count
            }
            rows.append(ResultRow(operation: "authoritative", size: Self.abbreviatedCount(fileCount), swift: distribution))
        }

        for previousFileCount in [100, 1000, 10000, 100_000] {
            let fixture = Self.makePatchFixture(previousFileCount: previousFileCount, batchSize: 1)
            let distribution = measure {
                let result = WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch(
                    event: fixture.event,
                    previousFiles: fixture.previousFiles,
                    previousFolders: [],
                    filesByID: fixture.filesByID,
                    foldersByID: [:],
                    maxLogicalMutationCount: 1
                )
                return (result?.files.count ?? -1) + (result?.logicalMutationCount ?? -1)
            }
            rows.append(ResultRow(
                operation: "single-delta-apply (E-1 kill criterion)",
                size: Self.abbreviatedCount(previousFileCount),
                swift: distribution
            ))
        }

        let report = Self.report(rows: rows)
        print(report)

        // Absolute floor: every reported distribution must be a real, non-degenerate measurement
        // (not a 0ms artifact of an empty/optimized-away operation), so a broken fixture cannot
        // silently freeze a zero baseline.
        for row in rows {
            XCTAssertGreaterThan(row.swift.p50Milliseconds, 0, "\(row.operation) @ \(row.size) produced a zero-time sample")
        }
    }

    /// P4-2 addition: E-1d's Swift reference arm ("Batch point-lookup cost curve",
    /// `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §10). Measures the same
    /// two operations E-1d's Rust candidate is measured against:
    /// - id-keyed: the per-id dictionary-lookup-plus-checks shape `appliedIndexRecordLookup`
    ///   performs (`WorkspaceFileContextStore.swift:6684-6725`) at N = 1/10/100/1000 ids, reproduced
    ///   directly over local dictionaries (not the full actor) for the same reason the existing E-1
    ///   fixtures above call `WorkspaceInventoryCatalogBuilders` directly rather than driving
    ///   `WorkspaceFileContextStore`: it isolates the lookup cost curve from actor/async dispatch
    ///   overhead, which is a real but separate tax from what E-1d is measuring.
    /// - path-keyed: a loop of `[String: UUID]` dictionary lookups at N = 1/100/1000/10000 paths,
    ///   the same underlying structure `RootCatalogShardState.fileIDsByRelativePath` uses and that
    ///   `prepareSessionWorktreeOwnership`'s manifest walk (`WorkspaceFileContextStore.swift:4593`,
    ///   contract doc §4.3.1.2) would resolve against per record today.
    func testSwiftInventoryScopeE1dBatchLookupBaseline() throws {
        guard ProcessInfo.processInfo.environment[Self.baselineEnvironmentKey] == "1" else {
            throw XCTSkip("Set \(Self.baselineEnvironmentKey)=1 to run the P4-2 Swift E-1d baseline capture.")
        }

        let fileCount = 100_000
        let fixture = Self.makeLookupFixture(fileCount: fileCount)

        var idRows: [ResultRow] = []
        for n in [1, 10, 100, 1000] {
            let queryIDs = Self.sampledIndices(count: n, of: fileCount).map { fixture.orderedIDs[$0] }
            let distribution = measure {
                var matchCount = 0
                for fileID in queryIDs {
                    guard let record = fixture.filesByID[fileID],
                          fixture.fileIDsByRelativePath[record.standardizedRelativePath] == fileID
                    else { continue }
                    matchCount += 1
                }
                return matchCount
            }
            idRows.append(ResultRow(operation: "e1d-id-keyed-batch-lookup", size: "\(n)", swift: distribution))
        }

        var pathRows: [ResultRow] = []
        for n in [1, 100, 1000, 10000] {
            let queryPaths = Self.sampledIndices(count: n, of: fileCount).map { fixture.orderedPaths[$0] }
            let distribution = measure {
                var matchCount = 0
                for path in queryPaths {
                    guard fixture.fileIDsByRelativePath[path] != nil else { continue }
                    matchCount += 1
                }
                return matchCount
            }
            pathRows.append(ResultRow(operation: "e1d-path-keyed-batch-lookup", size: "\(n)", swift: distribution))
        }

        let report = Self.report(rows: idRows + pathRows)
        print(report)

        for row in idRows + pathRows {
            XCTAssertGreaterThanOrEqual(row.swift.p50Milliseconds, 0, "\(row.operation) @ \(row.size) produced a negative sample")
        }
    }

    private struct LookupFixture {
        let filesByID: [UUID: WorkspaceFileRecord]
        let fileIDsByRelativePath: [String: UUID]
        let orderedIDs: [UUID]
        let orderedPaths: [String]
    }

    private static func makeLookupFixture(fileCount: Int) -> LookupFixture {
        let root = WorkspaceRootRecord(
            id: deterministicUUID(namespace: 0x96, index: fileCount),
            name: "BaselineLookupRoot",
            fullPath: "/workspace/baseline/lookup-root"
        )
        let files = (0 ..< fileCount).map { fileIndex in
            makeFile(
                id: deterministicUUID(namespace: 0x97, index: fileIndex),
                root: root,
                relativePath: String(
                    format: "Modules/Feature-%03d/Sources/Layer-%02d/LookupComponent-%06d.swift",
                    fileIndex / 100,
                    fileIndex % 8,
                    fileIndex
                )
            )
        }
        return LookupFixture(
            filesByID: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) }),
            fileIDsByRelativePath: Dictionary(uniqueKeysWithValues: files.map { ($0.standardizedRelativePath, $0.id) }),
            orderedIDs: files.map(\.id),
            orderedPaths: files.map(\.standardizedRelativePath)
        )
    }

    /// Evenly-strided sample of `count` indices across `[0, total)` -- avoids biasing the lookup
    /// benchmark toward low-index cache locality when `count < total`.
    private static func sampledIndices(count: Int, of total: Int) -> [Int] {
        guard count < total else { return Array(0 ..< total) }
        let stride = max(1, total / count)
        return (0 ..< count).map { ($0 * stride) % total }
    }

    private func measure(_ operation: () -> Int) -> Distribution {
        let warmup = operation()
        var samples: [Double] = []
        var checksum = warmup
        for _ in 0 ..< Self.measuredIterationCount {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = operation()
            let end = DispatchTime.now().uptimeNanoseconds
            checksum ^= value
            samples.append(Double(end - start) / 1_000_000)
        }
        XCTAssertGreaterThanOrEqual(checksum, Int.min)
        let sorted = samples.sorted()
        let midpoint = sorted.count / 2
        let p50 = sorted.count.isMultiple(of: 2)
            ? (sorted[midpoint - 1] + sorted[midpoint]) / 2
            : sorted[midpoint]
        let p99Rank = max(1, Int(ceil(Double(sorted.count) * 0.99)))
        return Distribution(p50Milliseconds: p50, p99Milliseconds: sorted[min(sorted.count - 1, p99Rank - 1)])
    }

    private static func makeAuthoritativeFixture(fileCount: Int) -> AuthoritativeFixture {
        let rootCount = 4
        let roots = (0 ..< rootCount).map { rootIndex in
            WorkspaceRootRecord(
                id: deterministicUUID(namespace: 0x90, index: rootIndex),
                name: String(format: "BaselineWorkspace-%02d", rootIndex),
                fullPath: String(format: "/workspace/baseline/workspace-%02d", rootIndex)
            )
        }
        var files: [WorkspaceFileRecord] = []
        var folders: [WorkspaceFolderRecord] = []
        for (rootIndex, root) in roots.enumerated() {
            let lowerBound = fileCount * rootIndex / rootCount
            let upperBound = fileCount * (rootIndex + 1) / rootCount
            let localCount = upperBound - lowerBound
            let groupCount = max(1, (localCount + 99) / 100)
            var layerFolderIDs: [UUID] = []
            for groupIndex in 0 ..< groupCount {
                let folderBaseIndex = rootIndex * 1_000_000 + groupIndex * 3
                let moduleID = deterministicUUID(namespace: 0x91, index: folderBaseIndex)
                let sourcesID = deterministicUUID(namespace: 0x91, index: folderBaseIndex + 1)
                let layerID = deterministicUUID(namespace: 0x91, index: folderBaseIndex + 2)
                let modulePath = String(format: "Modules/Feature-%03d", groupIndex)
                let sourcesPath = modulePath + "/Sources"
                let layerPath = sourcesPath + String(format: "/Layer-%02d", groupIndex % 8)
                folders.append(makeFolder(id: moduleID, root: root, relativePath: modulePath, parentFolderID: nil))
                folders.append(makeFolder(id: sourcesID, root: root, relativePath: sourcesPath, parentFolderID: moduleID))
                folders.append(makeFolder(id: layerID, root: root, relativePath: layerPath, parentFolderID: sourcesID))
                layerFolderIDs.append(layerID)
            }
            for localIndex in 0 ..< localCount {
                let globalIndex = lowerBound + localIndex
                let groupIndex = localIndex / 100
                let relativePath = String(
                    format: "Modules/Feature-%03d/Sources/Layer-%02d/Component-%06dCoordinator.swift",
                    groupIndex,
                    groupIndex % 8,
                    globalIndex
                )
                files.append(makeFile(
                    id: deterministicUUID(namespace: 0x92, index: globalIndex),
                    root: root,
                    relativePath: relativePath,
                    parentFolderID: layerFolderIDs[groupIndex]
                ))
            }
        }
        return AuthoritativeFixture(
            roots: roots,
            filesByID: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) }),
            foldersByID: Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        )
    }

    private static func makePatchFixture(previousFileCount: Int, batchSize: Int) -> PatchFixture {
        let root = WorkspaceRootRecord(
            id: deterministicUUID(namespace: 0x93, index: previousFileCount),
            name: "BaselinePatchRoot",
            fullPath: "/workspace/baseline/patch-root"
        )
        let previousFiles = (0 ..< previousFileCount).map { fileIndex in
            makeFile(
                id: deterministicUUID(namespace: 0x94, index: fileIndex),
                root: root,
                relativePath: String(
                    format: "Modules/Feature-%03d/Sources/Layer-%02d/ExistingComponent-%06d.swift",
                    fileIndex / 100,
                    fileIndex % 8,
                    fileIndex
                )
            )
        }
        let upsertedFiles = (0 ..< batchSize).map { batchIndex in
            makeFile(
                id: deterministicUUID(namespace: 0x95, index: previousFileCount + batchIndex),
                root: root,
                relativePath: String(
                    format: "Modules/NewFeature/Sources/Layer-00/NewComponent-%06d.swift",
                    previousFileCount + batchIndex
                )
            )
        }
        var filesByID = Dictionary(uniqueKeysWithValues: previousFiles.map { ($0.id, $0) })
        for file in upsertedFiles {
            filesByID[file.id] = file
        }
        let event = WorkspaceAppliedIndexBatchEvent(
            rootID: root.id,
            rootPath: root.fullPath,
            generation: 1,
            upsertedFiles: upsertedFiles
        )
        return PatchFixture(event: event, previousFiles: previousFiles, filesByID: filesByID)
    }

    private static func makeFile(
        id: UUID,
        root: WorkspaceRootRecord,
        relativePath: String,
        parentFolderID: UUID? = nil
    ) -> WorkspaceFileRecord {
        WorkspaceFileRecord(
            id: id,
            rootID: root.id,
            name: (relativePath as NSString).lastPathComponent,
            relativePath: relativePath,
            fullPath: root.fullPath + "/" + relativePath,
            parentFolderID: parentFolderID,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func makeFolder(
        id: UUID,
        root: WorkspaceRootRecord,
        relativePath: String,
        parentFolderID: UUID?
    ) -> WorkspaceFolderRecord {
        WorkspaceFolderRecord(
            id: id,
            rootID: root.id,
            name: (relativePath as NSString).lastPathComponent,
            relativePath: relativePath,
            fullPath: root.fullPath + "/" + relativePath,
            parentFolderID: parentFolderID,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func deterministicUUID(namespace: UInt8, index: Int) -> UUID {
        let value = UInt64(index)
        return UUID(uuid: (
            namespace, 0, 0, 0, 0, 0, 0, 0,
            UInt8(truncatingIfNeeded: value >> 56),
            UInt8(truncatingIfNeeded: value >> 48),
            UInt8(truncatingIfNeeded: value >> 40),
            UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ))
    }

    private static func abbreviatedCount(_ count: Int) -> String {
        count >= 1000 ? "\(count / 1000)k" : "\(count)"
    }

    private static func report(rows: [ResultRow]) -> String {
        var lines = [
            "REPOPROMPT_CE_INVENTORY_SCOPE_SWIFT_BASELINE_BEGIN",
            "Warmup/discarded iterations: 1; retained iterations: \(measuredIterationCount).",
            "No Rust InventoryScope candidate exists yet (P4-1) -- Swift reference arm only.",
            "| Operation | Size | Swift p50 ms | Swift p99 ms |",
            "| --- | --- | ---: | ---: |"
        ]
        lines.append(contentsOf: rows.map { row in
            String(
                format: "| %@ | %@ | %.4f | %.4f |",
                row.operation,
                row.size,
                row.swift.p50Milliseconds,
                row.swift.p99Milliseconds
            )
        })
        lines.append("REPOPROMPT_CE_INVENTORY_SCOPE_SWIFT_BASELINE_END")
        return lines.joined(separator: "\n")
    }
}
