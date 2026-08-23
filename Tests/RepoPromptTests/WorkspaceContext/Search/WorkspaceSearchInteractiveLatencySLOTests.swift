#if DEBUG
    @testable import RepoPromptApp
    import XCTest

    /// P4-7b §4.7 (phase b4) -- "Interactive-search latency SLO, registered in
    /// `rust/benchmarks/slo-v1.json` alongside the mention-path target: p50/p99 for
    /// `search(_:limit:)` at 10k and 100k paths."
    ///
    /// Scope and honesty about what this discharges, matching this campaign's own convention of
    /// recording partial/imperfect measurement conditions rather than silently overclaiming
    /// (`textdecodeV1`'s DEFER decision, `p4FourResults`' per-criterion BLOCKED entries):
    ///
    /// - **10k-path tier only.** The 100k tier is not measured in this pass -- generating and
    ///   loading 100k real on-disk files through the full store/Rust pipeline in a debug-profile
    ///   XCTest run is expensive enough to risk destabilizing this gate's own runtime; deferred as
    ///   a named follow-up (`rust/benchmarks/slo-v1.json`'s `p4SevenBResults.followUpConditions`).
    /// - **Debug profile.** `performanceIterationPolicy` in `slo-v1.json` explicitly discourages
    ///   paying a release rebuild for routine iteration; this is registered as a debug-profile
    ///   number with the same caveat the `inventoryScopeV1.swiftBaseline` entry already carries
    ///   ("re-capture under release profile is expected before the... gate").
    /// - **Absolute, not comparative.** Parent §8.4's measurement-symmetry rule ("both arms doing
    ///   the same product-visible work") applied naturally during b2, when both the Swift and Rust
    ///   arms existed side by side. Post-b3 there is no live Swift arm left in production to
    ///   compare against (mirrors `e4ApplyReadContentionUnderRebuild`'s "no Swift-side equivalent
    ///   contention model exists to baseline against... absolute cap on the Rust candidate only").
    ///   This suite measures the shipped system's own absolute p50/p99, which is what a caller of
    ///   `search(_:limit:)` actually experiences today.
    ///
    /// Gated behind `RPCE_RUN_SEARCH_LATENCY_SLO=1` -- excluded from default `swift test`/
    /// `make dev-test` for the same reason as the b2 handle-lifecycle soak: a multi-thousand-file
    /// fixture build plus warmup/sample iterations is not routine-test-suite material.
    final class WorkspaceSearchInteractiveLatencySLOTests: XCTestCase {
        private static let environmentKey = "RPCE_RUN_SEARCH_LATENCY_SLO"
        private static let pathCount = 10000
        private static let warmupIterations = 20
        private static let sampleIterations = 200

        private func makeTestDirectory(name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPromptTests", isDirectory: true)
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return url
        }

        private func percentile(_ sortedNanoseconds: [UInt64], _ percentile: Double) -> UInt64 {
            guard !sortedNanoseconds.isEmpty else { return 0 }
            let rank = Int((percentile / 100.0) * Double(sortedNanoseconds.count - 1))
            return sortedNanoseconds[min(max(rank, 0), sortedNanoseconds.count - 1)]
        }

        func testInteractiveSearchLatencyAt10kPaths() async throws {
            guard ProcessInfo.processInfo.environment[Self.environmentKey] == "1" else {
                throw XCTSkip("Set \(Self.environmentKey)=1 to run the 10k-path interactive-search latency SLO measurement directly (see this file's header doc).")
            }

            let root = try makeTestDirectory(name: "SearchLatencySLO10k")
            for index in 0 ..< Self.pathCount {
                let package = "pkg\(index % 11)"
                let module = "mod\(index % 17)"
                let relativePath = "\(package)/\(module)/File-\(index).swift"
                let url = root.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("// fixture \(index)\n".utf8).write(to: url, options: [.atomic])
            }

            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let service = WorkspaceSearchService()
            let indexedGeneration = await service.rebuildIndex(from: store, rootScope: .visibleWorkspace)
            XCTAssertNotNil(indexedGeneration)

            // A representative pattern: a substring match that requires scanning a meaningful
            // fraction of the corpus (not a prefix-bound-narrowed near-instant lookup), matching
            // an interactive as-you-type search rather than a best-case exact match.
            let pattern = "File-5"

            func timedSearch() async -> UInt64 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = await service.search(pattern, limit: 300)
                return DispatchTime.now().uptimeNanoseconds - start
            }

            for _ in 0 ..< Self.warmupIterations {
                _ = await timedSearch()
            }

            var samples: [UInt64] = []
            samples.reserveCapacity(Self.sampleIterations)
            for _ in 0 ..< Self.sampleIterations {
                await samples.append(timedSearch())
            }
            samples.sort()

            let p50Nanoseconds = percentile(samples, 50)
            let p99Nanoseconds = percentile(samples, 99)
            let p50Milliseconds = Double(p50Nanoseconds) / 1_000_000
            let p99Milliseconds = Double(p99Nanoseconds) / 1_000_000

            // Reported, not gated against a pre-registered floor -- `rust/benchmarks/slo-v1.json`'s
            // `p4SevenBResults` records these exact numbers as the registered evidence; this
            // in-tree assertion only bounds against a generous sanity ceiling so a true latency
            // regression still fails a routine `make dev-test` run once this gate is un-skipped
            // for CI, without hard-coding today's number as a brittle exact-match expectation.
            print("P4-7b b4 interactive-search latency SLO (10k paths, debug profile): p50=\(p50Milliseconds)ms p99=\(p99Milliseconds)ms pattern='\(pattern)'")
            XCTAssertLessThan(p99Milliseconds, 500, "p99 search latency at 10k paths exceeded the sanity ceiling")
        }
    }
#endif
