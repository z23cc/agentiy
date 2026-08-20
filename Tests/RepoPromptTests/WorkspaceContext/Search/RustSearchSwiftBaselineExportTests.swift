import Darwin
import Foundation
import os.signpost
@testable import RepoPromptApp
import RepoPromptRegexCore
import XCTest

final class RustSearchSwiftBaselineExportTests: XCTestCase {
    private static let exportDirectoryEnvironment = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_EXPORT_DIR"
    private static let fixtureDirectoryEnvironment = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_FIXTURE_DIR"
    private static let measurementOutputEnvironment = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_MEASURE_OUTPUT"
    private static let fixtureNames = [
        "file-tree-batch",
        "codemap",
        "search-results",
        "transcript"
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

    func testMeasureCurrentSwiftPayloadsWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtureDirectory = environment[Self.fixtureDirectoryEnvironment],
              let outputPath = environment[Self.measurementOutputEnvironment]
        else {
            throw XCTSkip("Swift baseline measurement is opt-in")
        }

        let warmupIterations = 1000
        let measuredIterations = 10000
        let fixtureRoot = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
        let regex = try PCRE2Regex(
            "baselineNeedle",
            options: [.utf, .unicodeProperties, .caseless],
            jit: .auto
        )
        let signpostLog = OSLog(subsystem: "com.repoprompt.agentry.tests", category: "RustSearchSwiftBaseline")
        var payloadReports: [String: Any] = [:]

        for name in Self.fixtureNames {
            let data = try Data(contentsOf: fixtureRoot.appendingPathComponent("\(name).json"))
            for _ in 0 ..< warmupIterations {
                _ = try measureOne(data: data, regex: regex, log: signpostLog)
            }

            var samples: [MeasurementSample] = []
            samples.reserveCapacity(measuredIterations)
            for _ in 0 ..< measuredIterations {
                try samples.append(measureOne(data: data, regex: regex, log: signpostLog))
            }
            payloadReports[name] = aggregate(samples: samples, canonicalBytes: data.count)
        }

        let report: [String: Any] = [
            "implementation": "swift-search-pre-p1",
            "jit": jitReport(regex.jitStatus),
            "payloads": payloadReports,
            "sampleIterations": measuredIterations,
            "schemaVersion": 1,
            "warmupIterations": warmupIterations
        ]
        let reportData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) + Data("\n".utf8)
        try reportData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

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
        let searchResults = try await StoreBackedWorkspaceSearch.search(
            pattern: #"baselineNeedle\s*\("#,
            mode: .content,
            isRegex: true,
            caseInsensitive: true,
            maxMatches: 20,
            contextLines: 1,
            rootScope: .visibleWorkspace,
            store: store,
            workspaceManager: nil
        )
        XCTAssertEqual(searchResults.matches?.count, 3)

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
            "transcript": productJSONObject(transcript, redactingRoot: root.path)
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

    private func measureOne(data: Data, regex: PCRE2Regex, log: OSLog) throws -> MeasurementSample {
        try autoreleasepool {
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
            _ = try regex.firstMatch(in: String(decoding: canonical, as: UTF8.self))
            let applyEnd = DispatchTime.now().uptimeNanoseconds
            os_signpost(.end, log: log, name: "apply", signpostID: applyID)

            var statistics = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &statistics)
            let cpuEnd = processCPUNanoseconds()
            let wallEnd = DispatchTime.now().uptimeNanoseconds

            return MeasurementSample(
                wallMilliseconds: milliseconds(wallEnd - wallStart),
                cpuMilliseconds: milliseconds(cpuEnd - cpuStart),
                decodeMilliseconds: milliseconds(decodeEnd - decodeStart),
                applyMilliseconds: milliseconds(applyEnd - applyStart),
                allocationsCount: UInt64(statistics.blocks_in_use),
                mallocBytes: UInt64(statistics.size_in_use),
                peakRSSBytes: peakRSSBytes()
            )
        }
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

    private func jitReport(_ status: PCRE2JITStatus) -> [String: Any] {
        switch status {
        case .disabled:
            ["active": false, "eligible": true, "status": "disabled"]
        case .unavailable:
            ["active": false, "eligible": true, "status": "unavailable"]
        case let .compiled(sizeBytes):
            ["active": true, "codeSizeBytes": sizeBytes, "eligible": true, "status": "compiled"]
        case let .fallback(errorCode, _):
            ["active": false, "eligible": true, "errorCode": errorCode, "status": "fallback"]
        }
    }
}
