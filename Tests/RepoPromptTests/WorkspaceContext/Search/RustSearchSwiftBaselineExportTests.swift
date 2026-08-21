import AgentryCoreBridge
import Darwin
import Foundation
import os.signpost
@testable import RepoPromptApp
import XCTest

final class RustSearchSwiftBaselineExportTests: XCTestCase {
    private static let exportDirectoryEnvironment = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_EXPORT_DIR"
    private static let fixtureDirectoryEnvironment = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_FIXTURE_DIR"
    private static let measurementOutputEnvironment = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_MEASURE_OUTPUT"
    private static let measurementImplementationEnvironment = "AGENTRY_RUST_SEARCH_MEASUREMENT_IMPLEMENTATION"
    private static let floorOutputEnvironment = "AGENTRY_RUST_SEARCH_FLOOR_OUTPUT"
    private static let floorFixtureEnvironment = "AGENTRY_RUST_SEARCH_FLOOR_FIXTURE"
    private static let floorLayerEnvironment = "AGENTRY_RUST_SEARCH_FLOOR_LAYER"
    private static let workloadPattern = "baselineNeedle"
    private static let workloadContextLines: UInt16 = 2
    #if AGENTRY_CORE_PHASE_PROFILE
        private static let phaseProfileOutputEnvironment = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_OUTPUT"
        private static let phaseProfileFixtureEnvironment = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_FIXTURE"
        private static let phaseProfileEngineEnvironment = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_ENGINE"
        private static let phaseProfileCollectionEnvironment = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_COLLECTION"
        private static let phaseProfileBatchSizeEnvironment = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_BATCH_SIZE"
        private static let phaseProfileNoMatchEnvironment = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_NO_MATCH"
    #endif
    private static let fixtureNames = [
        "file-tree-batch",
        "codemap",
        "search-results",
        "transcript",
        "representative-large-subject",
        "representative-multi-file-batch",
        "representative-match-density"
    ]

    func testExportCurrentSwiftPayloadsWhenRequested() async throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment[Self.exportDirectoryEnvironment] else {
            throw XCTSkip("Swift baseline export is opt-in")
        }

        let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let payloads = try await makeCurrentProductPayloads()
        XCTAssertEqual(Set(payloads.keys), Set(Self.fixtureNames))

        for name in Self.fixtureNames {
            let payload = try XCTUnwrap(payloads[name])
            let fixture: [String: Any] = [
                "fixtureKind": name,
                "payload": payload,
                "redacted": true,
                "schemaVersion": 1
            ]
            let data = try JSONSerialization.data(
                withJSONObject: fixture,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) + Data("\n".utf8)
            try data.write(to: outputURL.appendingPathComponent("\(name).json"), options: .atomic)
        }
    }

    func testMeasureCurrentSwiftPayloadsWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtureDirectory = environment[Self.fixtureDirectoryEnvironment],
              let outputPath = environment[Self.measurementOutputEnvironment]
        else {
            throw XCTSkip("Swift baseline measurement is opt-in")
        }

        let warmupIterations = 1000
        let measuredIterations = 10000
        let fixtureRoot = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
        guard environment[Self.measurementImplementationEnvironment] == "rust-search-candidate" else {
            throw XCTSkip("The pre-P1 Swift reference measurement is retained in Git history")
        }
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()
        let signpostLog = OSLog(subsystem: "com.repoprompt.agentry.tests", category: "RustSearchSwiftBaseline")
        var payloadReports: [String: Any] = [:]
        var candidateJITActive = true

        for name in Self.fixtureNames {
            let data = try Data(contentsOf: fixtureRoot.appendingPathComponent("\(name).json"))
            var expectedOutput: WorkloadOutput?
            for _ in 0 ..< warmupIterations {
                let measured = try await measureComparableOne(
                    fixtureName: name,
                    data: data,
                    client: client,
                    log: signpostLog
                )
                try validate(measured.output, against: &expectedOutput, fixtureName: name)
                candidateJITActive = candidateJITActive && measured.jitActive
            }

            var samples: [MeasurementSample] = []
            samples.reserveCapacity(measuredIterations)
            for _ in 0 ..< measuredIterations {
                let measured = try await measureComparableOne(
                    fixtureName: name,
                    data: data,
                    client: client,
                    log: signpostLog
                )
                try validate(measured.output, against: &expectedOutput, fixtureName: name)
                samples.append(measured.sample)
                candidateJITActive = candidateJITActive && measured.jitActive
            }
            var aggregate = aggregate(samples: samples, canonicalBytes: data.count)
            aggregate["workloadOutput"] = try XCTUnwrap(expectedOutput).jsonObject
            payloadReports[name] = aggregate
        }
        _ = try await bridge.close()

        let report: [String: Any] = try [
            "implementation": "rust-search-candidate-v2",
            "jit": ["active": candidateJITActive, "eligible": true, "status": candidateJITActive ? "compiled" : "inactive"],
            "payloads": payloadReports,
            "sampleIterations": measuredIterations,
            "schemaVersion": 2,
            "semantics": [
                "caseInsensitive": true,
                "collectMatches": true,
                "contextLines": Self.workloadContextLines,
                "matchPolicy": "contentFullBuffer",
                "materialization": "SearchMatch line and context strings",
                "pattern": Self.workloadPattern,
                "wholeWord": false
            ],
            "warmupIterations": warmupIterations
        ]
        let reportData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) + Data("\n".utf8)
        try reportData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    func testMeasureRustSearchThreeLayerFloorWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment[Self.floorOutputEnvironment],
              let fixtureDirectory = environment[Self.fixtureDirectoryEnvironment],
              let fixtureName = environment[Self.floorFixtureEnvironment],
              let layer = environment[Self.floorLayerEnvironment],
              layer == "B" || layer == "C"
        else {
            throw XCTSkip("Rust search three-layer floor measurement is opt-in")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
            .appendingPathComponent("\(fixtureName).json"))
        let object = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let subjects = measurementSubjects(fixtureName: fixtureName, object: object, canonical: canonical)
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()
        let warmupIterations = 100
        let sampleIterations = 1000
        var samples: [[String: Double]] = []
        var expectedOutput: WorkloadOutput?
        var jitActive = true
        var cacheHits = 0

        for iteration in 0 ..< (warmupIterations + sampleIterations) {
            var before = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &before)
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let cpuStart = processCPUNanoseconds()
            let result = try await client.searchRegexBatchCompactV1(comparableBatchRequest(subjects: subjects))
            let matches = layer == "C" ? try materialize(result: result, subjects: subjects) : nil
            let cpuEnd = processCPUNanoseconds()
            let wallEnd = DispatchTime.now().uptimeNanoseconds
            var after = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &after)
            let output = layer == "C"
                ? workloadOutput(matches ?? [])
                : compactWorkloadOutput(result)
            try validate(output, against: &expectedOutput, fixtureName: fixtureName)
            jitActive = jitActive && result.subjectSummaries.allSatisfy { $0.diagnostic.jitStatus == .active }
            cacheHits += result.subjectSummaries.filter { $0.diagnostic.cacheHit }.count
            if iteration >= warmupIterations {
                samples.append([
                    "cpuMilliseconds": milliseconds(cpuEnd - cpuStart),
                    "liveBlockDelta": Double(after.blocks_in_use) - Double(before.blocks_in_use),
                    "liveByteDelta": Double(after.size_in_use) - Double(before.size_in_use),
                    "wallMilliseconds": milliseconds(wallEnd - wallStart)
                ])
            }
            withExtendedLifetime(matches) {}
            withExtendedLifetime(result) {}
        }
        _ = try await bridge.close()

        func measuredDistribution(_ key: String) -> [String: Any] {
            distribution(samples.compactMap { $0[key] }, unit: key.contains("Milliseconds") ? "milliseconds" : "delta")
        }
        let report: [String: Any] = try [
            "cacheHitObservations": cacheHits,
            "fixture": fixtureName,
            "jitActive": jitActive,
            "layer": layer,
            "sampleIterations": sampleIterations,
            "schemaVersion": 1,
            "semantics": comparableSemantics,
            "subjectBytes": subjects.reduce(0) { $0 + $1.utf8.count },
            "subjectCount": subjects.count,
            "totals": [
                "cpu": measuredDistribution("cpuMilliseconds"),
                "liveBlocks": measuredDistribution("liveBlockDelta"),
                "liveBytes": measuredDistribution("liveByteDelta"),
                "wall": measuredDistribution("wallMilliseconds")
            ],
            "warmupIterations": warmupIterations,
            "workloadOutput": XCTUnwrap(expectedOutput).jsonObject
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data("\n".utf8)
        try reportData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    #if AGENTRY_CORE_PHASE_PROFILE
        func testMeasureRustSearchPhaseProfileWhenRequested() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard let outputPath = environment[Self.phaseProfileOutputEnvironment],
                  let fixtureDirectory = environment[Self.fixtureDirectoryEnvironment],
                  let fixtureName = environment[Self.phaseProfileFixtureEnvironment],
                  let engineVariant = environment[Self.phaseProfileEngineEnvironment],
                  let collectionVariant = environment[Self.phaseProfileCollectionEnvironment],
                  let batchSizeText = environment[Self.phaseProfileBatchSizeEnvironment],
                  let requestedBatchSize = Int(batchSizeText)
            else {
                throw XCTSkip("Rust search phase profile is opt-in")
            }
            let fixtureURL = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
                .appendingPathComponent("\(fixtureName).json")
            let data = try Data(contentsOf: fixtureURL)
            let object = try JSONSerialization.jsonObject(with: data)
            let canonical = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            var subjects = measurementSubjects(fixtureName: fixtureName, object: object, canonical: canonical)
            subjects = rebatch(subjects, count: requestedBatchSize)
            if environment[Self.phaseProfileNoMatchEnvironment] == "1" {
                subjects = subjects.map { $0.replacingOccurrences(of: "baselineNeedle", with: "baselineAbsent") }
            }

            let collectMatches = collectionVariant != "count-only"
            let contextLines: UInt16 = collectionVariant == "hits-and-context" ? 2 : 0
            let forcedPCRE2 = engineVariant == "forced-pcre2"
            let pattern = forcedPCRE2 ? "(?:baselineNeedle)" : "baselineNeedle"
            let bridge = try await AgentryCoreBridge.start()
            let client = try await bridge.searchClient()

            let warmupIterations = 5
            let sampleIterations = 20
            var samples: [[String: Double]] = []
            var engineCounts: [String: Int] = [:]
            var jitCounts: [String: Int] = [:]
            var cacheCounts: [String: Int] = [:]
            for iteration in 0 ..< (warmupIterations + sampleIterations) {
                var before = malloc_statistics_t()
                malloc_zone_statistics(malloc_default_zone(), &before)
                let wallStart = DispatchTime.now().uptimeNanoseconds
                let cpuStart = processCPUNanoseconds()
                let results = try await client.searchRegexBatch(CoreRegexSearchBatchRequest(
                    pattern: pattern,
                    subjects: subjects,
                    caseInsensitive: true,
                    collectMatches: collectMatches,
                    contextLines: contextLines,
                    matchPolicy: .contentFullBuffer
                ))
                let cpuEnd = processCPUNanoseconds()
                let wallEnd = DispatchTime.now().uptimeNanoseconds
                var after = malloc_statistics_t()
                malloc_zone_statistics(malloc_default_zone(), &after)
                for result in results {
                    engineCounts[String(describing: result.diagnostic.engine), default: 0] += 1
                    jitCounts[String(describing: result.diagnostic.jitStatus), default: 0] += 1
                    cacheCounts[result.diagnostic.cacheHit ? "hit" : "miss", default: 0] += 1
                }
                if iteration >= warmupIterations {
                    samples.append([
                        "wallMilliseconds": milliseconds(wallEnd - wallStart),
                        "cpuMilliseconds": milliseconds(cpuEnd - cpuStart),
                        "liveBlockDelta": Double(after.blocks_in_use) - Double(before.blocks_in_use),
                        "liveByteDelta": Double(after.size_in_use) - Double(before.size_in_use)
                    ])
                }
            }
            _ = try await bridge.close()

            func profileDistribution(_ key: String) -> [String: Any] {
                distribution(samples.compactMap { $0[key] }, unit: key.contains("Milliseconds") ? "milliseconds" : "delta")
            }
            let report: [String: Any] = [
                "batchSize": subjects.count,
                "cacheCounts": cacheCounts,
                "collectionVariant": collectionVariant,
                "engineCounts": engineCounts,
                "engineVariant": engineVariant,
                "fixture": fixtureName,
                "jitCounts": jitCounts,
                "noMatch": environment[Self.phaseProfileNoMatchEnvironment] == "1",
                "sampleIterations": sampleIterations,
                "subjectBytes": subjects.reduce(0) { $0 + $1.utf8.count },
                "totals": [
                    "cpu": profileDistribution("cpuMilliseconds"),
                    "liveBlocks": profileDistribution("liveBlockDelta"),
                    "liveBytes": profileDistribution("liveByteDelta"),
                    "wall": profileDistribution("wallMilliseconds")
                ],
                "warmupIterations": warmupIterations
            ]
            let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data("\n".utf8)
            try reportData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }

        private func rebatch(_ subjects: [String], count: Int) -> [String] {
            guard count > 0, count != subjects.count else { return subjects }
            let lines = subjects.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            return (0 ..< min(count, max(1, lines.count))).map { bucket in
                let start = lines.count * bucket / count
                let end = lines.count * (bucket + 1) / count
                return lines[start ..< end].joined(separator: "\n")
            }
        }

    #endif

    private func makeCurrentProductPayloads() async throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RustSearchSwiftBaselineFixture", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tests", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = """
        struct BaselineSearchFixture {
            func baselineNeedle(value: String) -> String {
                "result-\\(value)"
            }
        }
        """
        let tests = """
        func testBaselineNeedle() {
            _ = BaselineSearchFixture().baselineNeedle(value: "fixture")
        }
        """
        try source.write(
            to: root.appendingPathComponent("Sources/BaselineSearchFixture.swift"),
            atomically: true,
            encoding: .utf8
        )
        try tests.write(
            to: root.appendingPathComponent("Tests/BaselineSearchFixtureTests.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let sourcePath = root.appendingPathComponent("Sources/BaselineSearchFixture.swift").path
        let testsPath = root.appendingPathComponent("Tests/BaselineSearchFixtureTests.swift").path
        let searchResults = SearchResults(
            matches: [
                SearchMatch(
                    filePath: sourcePath,
                    lineNumber: 1,
                    lineText: "    func baselineNeedle(value: String) -> String {",
                    contextBefore: ["struct BaselineSearchFixture {"],
                    contextAfter: ["        \"result-\\(value)\""]
                ),
                SearchMatch(
                    filePath: testsPath,
                    lineNumber: 0,
                    lineText: "func testBaselineNeedle() {",
                    contextAfter: ["    _ = BaselineSearchFixture().baselineNeedle(value: \"fixture\")"]
                ),
                SearchMatch(
                    filePath: testsPath,
                    lineNumber: 1,
                    lineText: "    _ = BaselineSearchFixture().baselineNeedle(value: \"fixture\")",
                    contextBefore: ["func testBaselineNeedle() {"],
                    contextAfter: ["}"]
                )
            ],
            contentFileCount: 2,
            totalCount: 3,
            searchedFileCount: 2,
            scopedFileCount: 2
        )

        let paths = snapshot.entries.map(\.standardizedRelativePath).sorted()
        let tree = (["fixture-root"] + paths.map { "  \($0)" }).joined(separator: "\n")
        let fileTreeDTO = ToolResultDTOs.FileTreeDTO(
            rootsCount: 1,
            usesLegend: false,
            tree: tree,
            wasTruncated: false
        )
        let codemapDTO = ToolResultDTOs.SelectedCodeStructureDTO(
            fileCount: 1,
            content: """
            File: fixture-root/Sources/BaselineSearchFixture.swift
            struct BaselineSearchFixture
              func baselineNeedle(value: String) -> String
            """
        )
        let transcript = makeTranscript()

        return try [
            "file-tree-batch": productJSONObject(fileTreeDTO, redactingRoot: root.path),
            "codemap": productJSONObject(codemapDTO, redactingRoot: root.path),
            "search-results": productJSONObject(searchResults, redactingRoot: root.path),
            "transcript": productJSONObject(transcript, redactingRoot: root.path),
            "representative-large-subject": representativeLargeSubject(),
            "representative-multi-file-batch": representativeMultiFileBatch(),
            "representative-match-density": representativeMatchDensity()
        ]
    }

    private func representativeLargeSubject() -> [String: Any] {
        let lines = (0 ..< 2400).map { index in
            index.isMultiple(of: 37)
                ? "    func baselineNeedleFeature\(index)() { baselineNeedle(value: \"fixture-\(index)\") }"
                : "    func renderFeature\(index)() -> String { \"fixture-root/Sources/Feature\(index).swift\" }"
        }
        return [
            "profile": "single-source-file-over-100kb",
            "subjects": ["struct RepresentativeFeature {\n\(lines.joined(separator: "\n"))\n}"]
        ]
    }

    private func representativeMultiFileBatch() -> [String: Any] {
        let subjects = (0 ..< 64).map { fileIndex in
            let lines = (0 ..< 32).map { lineIndex in
                lineIndex.isMultiple(of: 11)
                    ? "    func baselineNeedle\(lineIndex)() { baselineNeedle(value: \"file-\(fileIndex)\") }"
                    : "    let fixtureValue\(lineIndex) = \"fixture-root/Sources/Feature\(fileIndex).swift\""
            }
            return "struct Feature\(fileIndex) {\n\(lines.joined(separator: "\n"))\n}"
        }
        return ["profile": "64-source-file-batch", "subjects": subjects]
    }

    private func representativeMatchDensity() -> [String: Any] {
        let lines = (0 ..< 2048).map { index in
            index.isMultiple(of: 8)
                ? "baselineNeedle(value: \"dense-fixture-\(index)\")"
                : "let denseFixture\(index) = \"search result row \(index)\""
        }
        return [
            "profile": "12.5-percent-matching-lines",
            "subjects": [lines.joined(separator: "\n")]
        ]
    }

    private func makeTranscript() -> AgentTranscript {
        let fixedDate = Date(timeIntervalSinceReferenceDate: 0)
        let activity = AgentTranscriptActivity(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            timestamp: fixedDate,
            sequenceIndex: 0,
            role: .assistant,
            itemKind: .assistant,
            text: "Verified baselineNeedle payloads from fixture-root.",
            isSubstantiveAssistant: true,
            sealsAssistantBoundary: true
        )
        let span = AgentTranscriptProviderResponseSpan(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            providerTurnID: "fixture-provider-turn",
            lifecycle: .completed,
            startedAt: fixedDate,
            completedAt: fixedDate,
            activities: [activity]
        )
        let turn = AgentTranscriptTurn(
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            responseSpans: [span],
            conclusionActivityID: activity.id,
            retentionTier: .full,
            startedAt: fixedDate,
            completedAt: fixedDate
        )
        return AgentTranscript(turns: [turn], nextSequenceIndex: 1)
    }

    private func productJSONObject(_ value: some Encodable, redactingRoot root: String) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return redact(object, root: root)
    }

    private func redact(_ value: Any, root: String) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                if entry.key == "timestamp" {
                    return
                }
                result[entry.key] = redact(entry.value, root: root)
            }
        }
        if let values = value as? [Any] {
            return values.map { redact($0, root: root) }
        }
        guard let string = value as? String else { return value }
        let relative = string.replacingOccurrences(of: root, with: "fixture-root")
        let uuidPattern = #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b"#
        return relative.replacingOccurrences(of: uuidPattern, with: "fixture-id", options: .regularExpression)
    }

    private struct MeasurementSample {
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
        let decodeMilliseconds: Double
        let applyMilliseconds: Double
        let allocationsCount: UInt64
        let mallocBytes: UInt64
        let peakRSSBytes: UInt64
    }

    private struct WorkloadOutput: Equatable {
        let hitCount: Int
        let materializedUTF8Bytes: Int
        let checksum: UInt64

        var jsonObject: [String: Any] {
            [
                "checksumFNV1a64": String(format: "%016llx", checksum),
                "hitCount": hitCount,
                "materializedUTF8Bytes": materializedUTF8Bytes
            ]
        }
    }

    private struct ComparableMeasurement {
        let sample: MeasurementSample
        let output: WorkloadOutput
        let jitActive: Bool
    }

    private enum MeasurementHarnessError: Error {
        case outputChanged(String)
        case subjectAlignment
    }

    private var comparableSemantics: [String: Any] {
        [
            "caseInsensitive": true,
            "collectMatches": true,
            "contextLines": Self.workloadContextLines,
            "matchPolicy": "contentFullBuffer",
            "pattern": Self.workloadPattern,
            "wholeWord": false
        ]
    }

    private func comparableBatchRequest(subjects: [String]) -> CoreRegexSearchBatchRequest {
        CoreRegexSearchBatchRequest(
            pattern: Self.workloadPattern,
            subjects: subjects,
            caseInsensitive: true,
            collectMatches: true,
            contextLines: Self.workloadContextLines,
            matchPolicy: .contentFullBuffer
        )
    }

    private func measureComparableOne(
        fixtureName: String,
        data: Data,
        client: CoreSearchClient,
        log: OSLog
    ) async throws -> ComparableMeasurement {
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let cpuStart = processCPUNanoseconds()

        let decodeID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "decode", signpostID: decodeID)
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        let object = try JSONSerialization.jsonObject(with: data)
        let decodeEnd = DispatchTime.now().uptimeNanoseconds
        os_signpost(.end, log: log, name: "decode", signpostID: decodeID)

        let applyID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "apply", signpostID: applyID)
        let applyStart = DispatchTime.now().uptimeNanoseconds
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let subjects = measurementSubjects(fixtureName: fixtureName, object: object, canonical: canonical)
        let matches: [SearchMatch]
        let jitActive: Bool
        let result = try await client.searchRegexBatchCompactV1(comparableBatchRequest(subjects: subjects))
        matches = try materialize(result: result, subjects: subjects)
        jitActive = result.subjectSummaries.allSatisfy { $0.diagnostic.jitStatus == .active }
        let applyEnd = DispatchTime.now().uptimeNanoseconds
        os_signpost(.end, log: log, name: "apply", signpostID: applyID)

        var statistics = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &statistics)
        let cpuEnd = processCPUNanoseconds()
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        let measured = ComparableMeasurement(
            sample: MeasurementSample(
                wallMilliseconds: milliseconds(wallEnd - wallStart),
                cpuMilliseconds: milliseconds(cpuEnd - cpuStart),
                decodeMilliseconds: milliseconds(decodeEnd - decodeStart),
                applyMilliseconds: milliseconds(applyEnd - applyStart),
                allocationsCount: UInt64(statistics.blocks_in_use),
                mallocBytes: UInt64(statistics.size_in_use),
                peakRSSBytes: peakRSSBytes()
            ),
            output: workloadOutput(matches),
            jitActive: jitActive
        )
        withExtendedLifetime(matches) {}
        return measured
    }

    private func materialize(
        result: CoreCompactRegexBatchResult,
        subjects: [String]
    ) throws -> [SearchMatch] {
        guard result.subjectSummaries.count == subjects.count else {
            throw MeasurementHarnessError.subjectAlignment
        }
        return try zip(result.subjectSummaries, subjects).enumerated().flatMap { index, pair in
            try FileSearchActor.materializeRustMatchesForBenchmark(
                summary: pair.0,
                batchResult: result,
                text: pair.1,
                filePath: "subject-\(index)",
                contextLines: Int(Self.workloadContextLines)
            )
        }
    }

    private func workloadOutput(_ matches: [SearchMatch]) -> WorkloadOutput {
        var checksum: UInt64 = 14_695_981_039_346_656_037
        var bytes = 0
        func consume(_ value: String) {
            for byte in value.utf8 {
                checksum = (checksum ^ UInt64(byte)) &* 1_099_511_628_211
                bytes += 1
            }
            checksum = (checksum ^ 0xFF) &* 1_099_511_628_211
        }
        for match in matches {
            consume(match.filePath)
            consume(String(match.lineNumber))
            consume(match.lineText)
            match.contextBefore?.forEach(consume)
            match.contextAfter?.forEach(consume)
        }
        return WorkloadOutput(hitCount: matches.count, materializedUTF8Bytes: bytes, checksum: checksum)
    }

    private func compactWorkloadOutput(_ result: CoreCompactRegexBatchResult) -> WorkloadOutput {
        var checksum: UInt64 = 14_695_981_039_346_656_037
        for word in result.hitWords + result.lineRangeWords {
            var value = word
            for _ in 0 ..< 8 {
                checksum = (checksum ^ (value & 0xFF)) &* 1_099_511_628_211
                value >>= 8
            }
        }
        return WorkloadOutput(
            hitCount: result.subjectSummaries.reduce(0) { $0 + Int($1.hitCount) },
            materializedUTF8Bytes: 0,
            checksum: checksum
        )
    }

    private func validate(
        _ output: WorkloadOutput,
        against expected: inout WorkloadOutput?,
        fixtureName: String
    ) throws {
        if let expected, expected != output {
            throw MeasurementHarnessError.outputChanged(fixtureName)
        }
        expected = output
    }

    private func measurementSubjects(fixtureName: String, object: Any, canonical: Data) -> [String] {
        guard fixtureName.hasPrefix("representative-"),
              let root = object as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let subjects = payload["subjects"] as? [String],
              !subjects.isEmpty
        else {
            return [String(decoding: canonical, as: UTF8.self)]
        }
        return subjects
    }

    private func aggregate(samples: [MeasurementSample], canonicalBytes: Int) -> [String: Any] {
        [
            "allocationsCount": distribution(samples.map { Double($0.allocationsCount) }, unit: "live-blocks"),
            "canonicalBytes": canonicalBytes,
            "cpuTimeMilliseconds": distribution(samples.map(\.cpuMilliseconds), unit: "milliseconds"),
            "decodeApplySignpost": [
                "applyMilliseconds": distribution(samples.map(\.applyMilliseconds), unit: "milliseconds"),
                "decodeMilliseconds": distribution(samples.map(\.decodeMilliseconds), unit: "milliseconds"),
                "intervals": ["decode", "apply"]
            ],
            "mallocBytes": distribution(samples.map { Double($0.mallocBytes) }, unit: "bytes"),
            "peakRSSBytes": samples.map(\.peakRSSBytes).max() ?? 0,
            "wallTimeMilliseconds": distribution(samples.map(\.wallMilliseconds), unit: "milliseconds")
        ]
    }

    private func distribution(_ values: [Double], unit: String) -> [String: Any] {
        let sorted = values.sorted()
        return [
            "p50": percentile(sorted, percentile: 0.50),
            "p99": percentile(sorted, percentile: 0.99),
            "unit": unit
        ]
    }

    private func percentile(_ sorted: [Double], percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * percentile)) - 1))
        return sorted[index]
    }

    private func processCPUNanoseconds() -> UInt64 {
        var value = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private func peakRSSBytes() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return UInt64(max(0, usage.ru_maxrss))
    }

    private func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }
}
