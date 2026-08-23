import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// TD-4 (design `docs/designs/textdecode-policy-v2-2026-08-22.md` §10 X-3 / §11 TD-4): the
/// pre-registered slice-2 economics GO/NO-GO benchmark (ADR-0008), following the now-retired
/// `InventoryCutoverBenchmarkTests`'/the still-live `InventoryScopeSwiftBaselineTests`' env-gated
/// conventions (same `DispatchTime`-based measurement, same warmup/sample shape).
///
/// **Seam note (honest labeling, task-authorized "differential-shaped, not production-shape"
/// fallback).** No standalone Rust decode FFI export exists yet -- `textdecode()` is reachable
/// only embedded inside the codemap and apply-edits FFI handlers (TD-3, design §6.1). This harness
/// measures the candidate through `RustApplyEditsComputer`'s production `.raw` source-kind path
/// (`CoreApplyEditsSubjectRequestV1(sourceKind: .raw, ...)` -> real `AgentryCoreService` FFI ->
/// Rust's apply-edits handler, which calls `textdecode()` internally as its first step per §6.1's
/// design). **The measured Rust number therefore includes decode + one `.rewrite(replacement: "")`
/// apply-edits operation (full-file diff-to-empty; `.single` search/replace was tried first but a
/// guaranteed-absent search string fails the whole request server-side rather than a benign
/// zero-match success, so `.rewrite` is used instead) + the apply-edits response envelope
/// (diff/stats construction) + the FFI round trip -- not decode alone.** This is the same "differential-shaped pattern from earlier
/// slices" the task's own scope authorizes when no dedicated FFI entry exists, called out here
/// rather than silently presented as an isolated decode number. The reference (Swift) arm measures
/// `decodeWorkspaceAutomaticV1` alone (today's live ladder-1 entry point, design §3.1 item 1) with
/// no equivalent envelope, so the measured ratio is biased AGAINST the Rust candidate (it is
/// carrying strictly more work) -- a GO verdict under this bias is conservative; a DEFER verdict
/// would need re-checking against an apples-to-apples decode-only number before being trusted.
final class TextDecodeCutoverBenchmarkTests: XCTestCase {
    private static let benchmarkEnvironmentKey = "RP_RUN_TEXTDECODE_CUTOVER_BENCHMARK"
    /// Reduced from other benchmarks' usual 5 (the now-retired InventoryCutoverBenchmarkTests/
    /// InventoryScopeSwiftBaselineTests) to 3: the 100k-file scale point repeats a real FFI batch
    /// round trip with ~100k-subject payload construction on both sides per sample, and a first
    /// attempt at 5 iterations coincided with the coordinated daemon's socket becoming briefly
    /// unresponsive (machine-light discipline, not a correctness requirement -- p50/p99 are still
    /// meaningful at n=3).
    private static let measuredIterationCount = 3

    private struct Distribution {
        let p50Milliseconds: Double
        let p99Milliseconds: Double
    }

    private struct ThroughputRow {
        let category: String
        let fileCount: Int
        let swiftTotal: Distribution
        let rustTotal: Distribution

        var swiftPerFileMicroseconds: Double {
            swiftTotal.p50Milliseconds * 1000 / Double(fileCount)
        }

        var rustPerFileMicroseconds: Double {
            rustTotal.p50Milliseconds * 1000 / Double(fileCount)
        }

        var p50Ratio: Double {
            rustTotal.p50Milliseconds / swiftTotal.p50Milliseconds
        }

        var p99Ratio: Double {
            rustTotal.p99Milliseconds / swiftTotal.p99Milliseconds
        }
    }

    private enum Category: CaseIterable {
        case utf8Dominant
        case bomPrefixed
        case legacyFallback

        var label: String {
            switch self {
            case .utf8Dominant: "utf8-dominant"
            case .bomPrefixed: "utf8-bom"
            case .legacyFallback: "legacy-shift-jis"
            }
        }
    }

    /// Deterministic, source-code-shaped payload per category, ~700-900 bytes -- representative of
    /// a small-to-medium source file, not a stress-size outlier (this benchmark's job is per-file
    /// economics at scale, not large-single-file cost, which is a different, already-covered
    /// question, design §6.2).
    private static func makePayload(_ category: Category, index: Int) -> Data {
        switch category {
        case .utf8Dominant:
            let body = (0 ..< 18).map { line in
                "    let component\(index)Line\(line) = ComponentValue(index: \(index), line: \(line))"
            }.joined(separator: "\n")
            return Data("struct BenchComponent\(index) {\n\(body)\n}\n".utf8)
        case .bomPrefixed:
            let body = (0 ..< 18).map { line in
                "    let component\(index)Line\(line) = ComponentValue(index: \(index), line: \(line))"
            }.joined(separator: "\n")
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(Data("struct BenchComponent\(index) {\n\(body)\n}\n".utf8))
            return data
        case .legacyFallback:
            let sentence = "これはベンチマーク用のコメントです。ファイル番号\(index)。文字化けせずに" +
                "正しくデコードされることを確認するための日本語テキストです。東京都渋谷区の" +
                "サンプルコンポーネントです。処理速度の測定に使用します。"
            return SHIFT_JIS_encode(sentence)
        }
    }

    /// `encoding_rs`'s Shift-JIS table is not exposed to Swift; Foundation's
    /// `.shiftJIS`/`CFStringEncodings.shiftJIS` is the closest available encoder for constructing
    /// a *clean* (non-corrupted -- corruption is Part B's R11 investigation, not this benchmark's
    /// concern) legacy-fallback-category fixture from Swift. Falls back to UTF-8 bytes (still a
    /// valid, if uninteresting, fixture) if unavailable in this environment, rather than failing
    /// the whole benchmark on an encoder gap unrelated to what TD-4 measures.
    private static func SHIFT_JIS_encode(_ string: String) -> Data {
        string.data(using: .shiftJIS) ?? Data(string.utf8)
    }

    private static func makeCorpus(fileCount: Int) -> [(category: Category, data: Data)] {
        (0 ..< fileCount).map { index in
            let category = Category.allCases[index % Category.allCases.count]
            return (category, makePayload(category, index: index))
        }
    }

    /// A `.single` search-based mode with a guaranteed-absent search string fails the whole
    /// request server-side ("search block not found in file") rather than returning a benign
    /// zero-match success -- discovered empirically while building this harness. `.rewrite` avoids
    /// that failure mode entirely (no search to not-find) at the cost of measuring a full-file
    /// diff-to-empty instead of a true no-op; still decode + one apply-edits operation + envelope
    /// construction + FFI round trip, which is what this benchmark's doc comment already discloses.
    private static func neverMatchingMode() -> CoreApplyEditsModeV1 {
        .rewrite(replacement: "")
    }

    /// X-3's primary measurement (design §10): batched decode throughput at 100/1k/10k/100k-file
    /// scale, Rust candidate vs today's Swift chain. One Rust FFI call per scale point carries the
    /// whole batch (`CoreApplyEditsBatchRequestV1.subjects`), matching "the existing chunked-read
    /// loop already groups work" (design TD-5 step, §11) rather than N sequential round trips.
    func testTextDecodeCutoverBatchedThroughput() async throws {
        guard ProcessInfo.processInfo.environment[Self.benchmarkEnvironmentKey] == "1" else {
            throw XCTSkip("Set \(Self.benchmarkEnvironmentKey)=1 to run the TD-4 X-3 batched-throughput benchmark.")
        }

        var rows: [ThroughputRow] = []
        for fileCount in [100, 1000, 10000, 100_000] {
            let corpus = Self.makeCorpus(fileCount: fileCount)

            let swiftWarmup = corpus.reduce(0) { count, entry in
                count + (decodeWorkspaceAutomaticV1(entry.data)?.string.count ?? 0)
            }
            let rustWarmupResult = try await Self.runRustBatch(corpus)
            XCTAssertEqual(rustWarmupResult.subjects.count, fileCount)
            XCTAssertGreaterThan(swiftWarmup, 0)

            var swiftSamples: [Double] = []
            var rustSamples: [Double] = []
            for iteration in 0 ..< Self.measuredIterationCount {
                if iteration.isMultiple(of: 2) {
                    swiftSamples.append(Self.measureSwiftBatch(corpus))
                    try await rustSamples.append(Self.measureRustBatch(corpus))
                } else {
                    try await rustSamples.append(Self.measureRustBatch(corpus))
                    swiftSamples.append(Self.measureSwiftBatch(corpus))
                }
            }

            rows.append(ThroughputRow(
                category: "mixed(utf8/bom/legacy)",
                fileCount: fileCount,
                swiftTotal: Self.distribution(swiftSamples),
                rustTotal: Self.distribution(rustSamples)
            ))
        }

        let report = Self.throughputReport(rows: rows)
        print(report)

        for row in rows {
            XCTAssertGreaterThan(row.swiftTotal.p50Milliseconds, 0, "\(row.fileCount) produced a zero-time Swift sample")
            XCTAssertGreaterThan(row.rustTotal.p50Milliseconds, 0, "\(row.fileCount) produced a zero-time Rust sample")
        }
    }

    /// X-3's absolute-latency-floor side (design §10): single-file (unbatched) FFI round-trip
    /// latency, representative of the small-root "one file opened at a time" case. **Recorded as
    /// evidence, explicitly UNSCORED** -- design §11 TD-1 was supposed to freeze a microsecond
    /// floor for this before any candidate existed (ADR-0008's ordering requirement) and did not
    /// (TD-1 landed deletion-only, `3cc2d098`); inventing a floor now, after seeing this number,
    /// would invert that ordering. See TD-4 results doc for the honest accounting.
    func testTextDecodeCutoverPerCallLatencyEvidenceOnly() async throws {
        guard ProcessInfo.processInfo.environment[Self.benchmarkEnvironmentKey] == "1" else {
            throw XCTSkip("Set \(Self.benchmarkEnvironmentKey)=1 to run the TD-4 X-3 per-call latency probe.")
        }

        let sampleCount = 30
        let corpus = (0 ..< sampleCount).map { index -> (category: Category, data: Data) in
            let category = Category.allCases[index % Category.allCases.count]
            return (category, Self.makePayload(category, index: index))
        }

        _ = try await Self.runRustBatch(Array(corpus.prefix(1))) // warmup: pays one-time runtime startup cost

        var samplesMicroseconds: [Double] = []
        for entry in corpus {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await Self.runRustBatch([entry])
            let end = DispatchTime.now().uptimeNanoseconds
            samplesMicroseconds.append(Double(end - start) / 1000)
        }

        let sorted = samplesMicroseconds.sorted()
        let midpoint = sorted.count / 2
        let p50 = sorted.count.isMultiple(of: 2) ? (sorted[midpoint - 1] + sorted[midpoint]) / 2 : sorted[midpoint]
        let p99Rank = max(1, Int(ceil(Double(sorted.count) * 0.99)))
        let p99 = sorted[min(sorted.count - 1, p99Rank - 1)]

        print(
            """
            REPOPROMPT_CE_TEXTDECODE_PERCALL_BEGIN
            Single-file (unbatched) Rust FFI round trip, decode+apply-edits-envelope (see class doc
            comment for exactly what's included). n=\(sampleCount). UNSCORED -- no TD-1 floor exists.
            p50_us=\(String(format: "%.1f", p50)) p99_us=\(String(format: "%.1f", p99))
            REPOPROMPT_CE_TEXTDECODE_PERCALL_END
            """
        )
        XCTAssertGreaterThan(p50, 0)
    }

    private static func measureSwiftBatch(_ corpus: [(category: Category, data: Data)]) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for entry in corpus {
            _ = decodeWorkspaceAutomaticV1(entry.data)
        }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }

    private static func measureRustBatch(_ corpus: [(category: Category, data: Data)]) async throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await runRustBatch(corpus)
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }

    private static func runRustBatch(_ corpus: [(category: Category, data: Data)]) async throws -> CoreApplyEditsBatchResultV1 {
        let subjects = corpus.enumerated().map { index, entry in
            CoreApplyEditsSubjectRequestV1(
                pathLabel: "bench/\(entry.category.label)/file-\(index).txt",
                rawBytes: entry.data,
                mode: Self.neverMatchingMode(),
                verbose: false,
                includeToolCardUnifiedDiff: false
            )
        }
        let client = try await AgentryCoreService.shared.computeClient()
        return try await client.applyEditsBatchV1(CoreApplyEditsBatchRequestV1(subjects: subjects))
    }

    private static func distribution(_ samples: [Double]) -> Distribution {
        let sorted = samples.sorted()
        let midpoint = sorted.count / 2
        let p50 = sorted.count.isMultiple(of: 2)
            ? (sorted[midpoint - 1] + sorted[midpoint]) / 2
            : sorted[midpoint]
        let p99Rank = max(1, Int(ceil(Double(sorted.count) * 0.99)))
        return Distribution(p50Milliseconds: p50, p99Milliseconds: sorted[min(sorted.count - 1, p99Rank - 1)])
    }

    private static func throughputReport(rows: [ThroughputRow]) -> String {
        var lines = [
            "REPOPROMPT_CE_TEXTDECODE_CUTOVER_BENCHMARK_BEGIN",
            "Warmup/discarded iterations: 1; retained iterations: \(measuredIterationCount).",
            "Rust column = decode + rewrite-to-empty apply-edits op + envelope + FFI round trip (see class doc comment).",
            "| Files | Swift p50 ms | Rust p50 ms | Swift/file us | Rust/file us | p50 ratio (rust/swift) | p99 ratio |",
            "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
        ]
        lines.append(contentsOf: rows.map { row in
            String(
                format: "| %d | %.4f | %.4f | %.3f | %.3f | %.3f | %.3f |",
                row.fileCount,
                row.swiftTotal.p50Milliseconds,
                row.rustTotal.p50Milliseconds,
                row.swiftPerFileMicroseconds,
                row.rustPerFileMicroseconds,
                row.p50Ratio,
                row.p99Ratio
            )
        })
        lines.append("REPOPROMPT_CE_TEXTDECODE_CUTOVER_BENCHMARK_END")
        return lines.joined(separator: "\n")
    }
}
