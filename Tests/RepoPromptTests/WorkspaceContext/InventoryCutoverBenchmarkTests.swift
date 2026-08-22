import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import XCTest

final class InventoryCutoverBenchmarkTests: XCTestCase {
    private static let benchmarkEnvironmentKey = "RP_RUN_INVENTORY_CUTOVER_BENCHMARK"
    private static let measuredIterationCount = 5

    private struct Distribution {
        let p50Milliseconds: Double
        let p95Milliseconds: Double
    }

    private struct ResultRow {
        let operation: String
        let size: String
        let swift: Distribution
        let rust: Distribution

        var p50Ratio: Double {
            rust.p50Milliseconds / swift.p50Milliseconds
        }

        var p95Ratio: Double {
            rust.p95Milliseconds / swift.p95Milliseconds
        }
    }

    private struct AuthoritativeFixture {
        let roots: [WorkspaceRootRecord]
        let filesByID: [UUID: WorkspaceFileRecord]
        let foldersByID: [UUID: WorkspaceFolderRecord]
        let coreRoots: [CoreInventoryRootRecordV1]
        let coreFilesByID: [UUID: CoreInventoryFileRecordV1]
        let coreFoldersByID: [UUID: CoreInventoryFolderRecordV1]
    }

    private struct PatchFixture {
        let event: WorkspaceAppliedIndexBatchEvent
        let previousFiles: [WorkspaceFileRecord]
        let filesByID: [UUID: WorkspaceFileRecord]
        let coreEvent: CoreInventoryAppliedIndexBatchEventV1
        let corePreviousFiles: [CoreInventoryFileRecordV1]
        let coreFilesByID: [UUID: CoreInventoryFileRecordV1]
    }

    func testSwiftVersusRustInventoryCutoverBenchmark() async throws {
        guard ProcessInfo.processInfo.environment[Self.benchmarkEnvironmentKey] == "1" else {
            XCTAssertNotNil(ProcessInfo.processInfo.environment)
            return
        }

        let rustComputer = RustInventoryComputer()
        var rows: [ResultRow] = []

        for fileCount in [1000, 10000, 100_000] {
            let fixture = Self.makeAuthoritativeFixture(fileCount: fileCount)
            let measurements = try await measurePair(
                swift: {
                    let result = WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents(
                        roots: fixture.roots,
                        filesByID: fixture.filesByID,
                        foldersByID: fixture.foldersByID,
                        managedOnlyFileIDs: [],
                        managedOnlyFolderIDs: []
                    )
                    return result.files.count + result.folders.count + result.entries.count
                },
                rust: {
                    let result = try await rustComputer.buildAuthoritativeCatalogComponents(
                        roots: fixture.coreRoots,
                        filesByID: fixture.coreFilesByID,
                        foldersByID: fixture.coreFoldersByID,
                        managedOnlyFileIDs: [],
                        managedOnlyFolderIDs: []
                    )
                    return result.files.count + result.folders.count + result.entries.count
                }
            )
            rows.append(ResultRow(
                operation: "authoritative",
                size: Self.abbreviatedCount(fileCount),
                swift: measurements.swift,
                rust: measurements.rust
            ))
        }

        for previousFileCount in [10000, 100_000] {
            for batchSize in [1, 100] {
                let fixture = Self.makePatchFixture(
                    previousFileCount: previousFileCount,
                    batchSize: batchSize
                )
                let measurements = try await measurePair(
                    swift: {
                        let result = WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch(
                            event: fixture.event,
                            previousFiles: fixture.previousFiles,
                            previousFolders: [],
                            filesByID: fixture.filesByID,
                            foldersByID: [:],
                            maxLogicalMutationCount: 1
                        )
                        return (result?.files.count ?? -1) + (result?.logicalMutationCount ?? -1)
                    },
                    rust: {
                        let result = try await rustComputer.buildRootCatalogShardPatch(
                            event: fixture.coreEvent,
                            previousFiles: fixture.corePreviousFiles,
                            previousFolders: [],
                            filesByID: fixture.coreFilesByID,
                            foldersByID: [:],
                            maxLogicalMutationCount: 1
                        )
                        return (result?.files.count ?? -1) + (result?.logicalMutationCount ?? -1)
                    }
                )
                rows.append(ResultRow(
                    operation: batchSize == 1 ? "patch-add-1" : "patch-add-100-over-budget",
                    size: Self.abbreviatedCount(previousFileCount),
                    swift: measurements.swift,
                    rust: measurements.rust
                ))
            }
        }

        do {
            let roots = (0 ..< 4).map { rootIndex in
                WorkspaceRootRecord(
                    id: Self.deterministicUUID(namespace: 0x70, index: rootIndex),
                    name: String(format: "MergeRoot-%02d", rootIndex),
                    fullPath: String(format: "/workspace/clients/merge-root-%02d", rootIndex)
                )
            }
            let swiftShards = roots.enumerated().map { rootIndex, root in
                let files = (0 ..< 25000).map { fileIndex in
                    Self.makeFile(
                        id: Self.deterministicUUID(namespace: UInt8(0x71 + rootIndex), index: fileIndex),
                        root: root,
                        relativePath: String(
                            format: "Modules/Feature-%03d/Sources/Layer-%02d/Component-%06dCoordinator.swift",
                            fileIndex / 100,
                            fileIndex % 8,
                            fileIndex
                        )
                    )
                }
                return (files: files, entries: files.map { WorkspaceSearchCatalogEntry(file: $0, root: root) })
            }
            let coreShards = swiftShards.map { shard in
                (files: shard.files.map(Self.core), entries: shard.entries.map(Self.core))
            }
            let measurements = try await measurePair(
                swift: {
                    let result = WorkspaceInventoryCatalogBuilders.mergeRootCatalogShardFileEntryLists(swiftShards)
                    return result.files.count + result.entries.count
                },
                rust: {
                    let result = try await rustComputer.mergeRootCatalogShardFileEntryLists(coreShards)
                    return result.files.count + result.entries.count
                }
            )
            rows.append(ResultRow(
                operation: "merge-4x25k",
                size: "100k total",
                swift: measurements.swift,
                rust: measurements.rust
            ))
        }

        print(Self.report(rows: rows))
    }

    private func measurePair(
        swift swiftOperation: () -> Int,
        rust rustOperation: () async throws -> Int
    ) async throws -> (swift: Distribution, rust: Distribution) {
        let swiftWarmup = swiftOperation()
        let rustWarmup = try await rustOperation()
        XCTAssertEqual(swiftWarmup, rustWarmup)

        var swiftSamples: [Double] = []
        var rustSamples: [Double] = []
        var checksum = swiftWarmup ^ rustWarmup
        for iteration in 0 ..< Self.measuredIterationCount {
            if iteration.isMultiple(of: 2) {
                let swiftSample = measure(swiftOperation)
                swiftSamples.append(swiftSample.milliseconds)
                checksum ^= swiftSample.value
                let rustSample = try await measure(rustOperation)
                rustSamples.append(rustSample.milliseconds)
                checksum ^= rustSample.value
            } else {
                let rustSample = try await measure(rustOperation)
                rustSamples.append(rustSample.milliseconds)
                checksum ^= rustSample.value
                let swiftSample = measure(swiftOperation)
                swiftSamples.append(swiftSample.milliseconds)
                checksum ^= swiftSample.value
            }
        }
        XCTAssertGreaterThanOrEqual(checksum, 0)
        return (distribution(swiftSamples), distribution(rustSamples))
    }

    private func measure(_ operation: () -> Int) -> (value: Int, milliseconds: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return (value, Double(end - start) / 1_000_000)
    }

    private func measure(_ operation: () async throws -> Int) async throws -> (value: Int, milliseconds: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try await operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return (value, Double(end - start) / 1_000_000)
    }

    private func distribution(_ samples: [Double]) -> Distribution {
        XCTAssertEqual(samples.count, Self.measuredIterationCount)
        let sorted = samples.sorted()
        let midpoint = sorted.count / 2
        let p50 = sorted.count.isMultiple(of: 2)
            ? (sorted[midpoint - 1] + sorted[midpoint]) / 2
            : sorted[midpoint]
        let p95Rank = max(1, Int(ceil(Double(sorted.count) * 0.95)))
        return Distribution(
            p50Milliseconds: p50,
            p95Milliseconds: sorted[min(sorted.count - 1, p95Rank - 1)]
        )
    }

    private static func makeAuthoritativeFixture(fileCount: Int) -> AuthoritativeFixture {
        let rootCount = 4
        let roots = (0 ..< rootCount).map { rootIndex in
            WorkspaceRootRecord(
                id: deterministicUUID(namespace: 0x10, index: rootIndex),
                name: String(format: "ClientWorkspace-%02d", rootIndex),
                fullPath: String(format: "/workspace/clients/client-workspace-%02d", rootIndex)
            )
        }
        var files: [WorkspaceFileRecord] = []
        var folders: [WorkspaceFolderRecord] = []
        files.reserveCapacity(fileCount)
        folders.reserveCapacity((fileCount / 100 + rootCount) * 3)

        for (rootIndex, root) in roots.enumerated() {
            let lowerBound = fileCount * rootIndex / rootCount
            let upperBound = fileCount * (rootIndex + 1) / rootCount
            let localCount = upperBound - lowerBound
            let groupCount = (localCount + 99) / 100
            var layerFolderIDs: [UUID] = []
            layerFolderIDs.reserveCapacity(groupCount)
            for groupIndex in 0 ..< groupCount {
                let folderBaseIndex = rootIndex * 1_000_000 + groupIndex * 3
                let moduleID = deterministicUUID(namespace: 0x20, index: folderBaseIndex)
                let sourcesID = deterministicUUID(namespace: 0x20, index: folderBaseIndex + 1)
                let layerID = deterministicUUID(namespace: 0x20, index: folderBaseIndex + 2)
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
                    id: deterministicUUID(namespace: 0x30, index: globalIndex),
                    root: root,
                    relativePath: relativePath,
                    parentFolderID: layerFolderIDs[groupIndex]
                ))
            }
        }

        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        return AuthoritativeFixture(
            roots: roots,
            filesByID: filesByID,
            foldersByID: foldersByID,
            coreRoots: roots.map(core),
            coreFilesByID: filesByID.mapValues(core),
            coreFoldersByID: foldersByID.mapValues(core)
        )
    }

    private static func makePatchFixture(previousFileCount: Int, batchSize: Int) -> PatchFixture {
        let root = WorkspaceRootRecord(
            id: deterministicUUID(namespace: 0x40, index: previousFileCount),
            name: "CanonicalPatchRoot",
            fullPath: "/workspace/clients/canonical-patch-root"
        )
        let previousFiles = (0 ..< previousFileCount).map { fileIndex in
            makeFile(
                id: deterministicUUID(namespace: 0x50, index: fileIndex),
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
                id: deterministicUUID(namespace: 0x51, index: previousFileCount + batchIndex),
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
        return PatchFixture(
            event: event,
            previousFiles: previousFiles,
            filesByID: filesByID,
            coreEvent: core(event),
            corePreviousFiles: previousFiles.map(core),
            coreFilesByID: filesByID.mapValues(core)
        )
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

    private static func core(_ root: WorkspaceRootRecord) -> CoreInventoryRootRecordV1 {
        CoreInventoryRootRecordV1(id: root.id, name: root.name, standardizedFullPath: root.standardizedFullPath)
    }

    private static func core(_ file: WorkspaceFileRecord) -> CoreInventoryFileRecordV1 {
        CoreInventoryFileRecordV1(
            id: file.id,
            rootID: file.rootID,
            name: file.name,
            relativePath: file.relativePath,
            standardizedRelativePath: file.standardizedRelativePath,
            fullPath: file.fullPath,
            standardizedFullPath: file.standardizedFullPath,
            parentFolderID: file.parentFolderID,
            modificationDate: file.modificationDate
        )
    }

    private static func core(_ folder: WorkspaceFolderRecord) -> CoreInventoryFolderRecordV1 {
        CoreInventoryFolderRecordV1(
            id: folder.id,
            rootID: folder.rootID,
            name: folder.name,
            relativePath: folder.relativePath,
            standardizedRelativePath: folder.standardizedRelativePath,
            fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath,
            parentFolderID: folder.parentFolderID,
            modificationDate: folder.modificationDate
        )
    }

    private static func core(_ entry: WorkspaceSearchCatalogEntry) -> CoreInventorySearchCatalogEntryV1 {
        CoreInventorySearchCatalogEntryV1(
            id: entry.id,
            rootID: entry.rootID,
            rootPath: entry.rootPath,
            rootName: entry.rootName,
            name: entry.name,
            relativePath: entry.relativePath,
            standardizedRelativePath: entry.standardizedRelativePath,
            fullPath: entry.fullPath,
            standardizedFullPath: entry.standardizedFullPath,
            displayPath: entry.displayPath
        )
    }

    private static func core(_ event: WorkspaceAppliedIndexBatchEvent) -> CoreInventoryAppliedIndexBatchEventV1 {
        CoreInventoryAppliedIndexBatchEventV1(
            rootID: event.rootID,
            upsertedFiles: event.upsertedFiles.map(core),
            upsertedFolders: event.upsertedFolders.map(core),
            removedFileIDs: event.removedFileIDs,
            removedFolderIDs: event.removedFolderIDs,
            removedFilePaths: event.removedFilePaths,
            removedFolderPaths: event.removedFolderPaths,
            modifiedFileIDs: event.modifiedFileIDs,
            modifiedFolderIDs: event.modifiedFolderIDs
        )
    }

    private static func abbreviatedCount(_ count: Int) -> String {
        count >= 1000 ? "\(count / 1000)k" : "\(count)"
    }

    private static func report(rows: [ResultRow]) -> String {
        var lines = [
            "REPOPROMPT_CE_INVENTORY_CUTOVER_BENCHMARK_BEGIN",
            "Warmup/discarded iterations: 1; retained iterations per implementation: \(measuredIterationCount)",
            "Patch budget: 1 logical mutation; the 100-file batch is the production over-budget outcome.",
            "| Operation | Size | Swift p50 ms | Swift p95 ms | Rust p50 ms | Rust p95 ms | Rust/Swift p50 | Rust/Swift p95 |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"
        ]
        lines.append(contentsOf: rows.map { row in
            String(
                format: "| %@ | %@ | %.3f | %.3f | %.3f | %.3f | %.2fx | %.2fx |",
                row.operation,
                row.size,
                row.swift.p50Milliseconds,
                row.swift.p95Milliseconds,
                row.rust.p50Milliseconds,
                row.rust.p95Milliseconds,
                row.p50Ratio,
                row.p95Ratio
            )
        })
        lines.append(
            "Rust encode/decode share: unavailable without adding a production timing seam; request construction, FFI, and response decoding are intentionally fused behind CoreComputeClient's private perform path."
        )
        lines.append("REPOPROMPT_CE_INVENTORY_CUTOVER_BENCHMARK_END")
        return lines.joined(separator: "\n")
    }
}
