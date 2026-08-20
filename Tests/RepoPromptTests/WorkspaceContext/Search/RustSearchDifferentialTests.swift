import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import XCTest

final class RustSearchDifferentialTests: XCTestCase {
    func testBasicContentParityMatchesLinesByteRangesAndContext() async throws {
        #if DEBUG
            let pattern = "needle"
            let subject = "α first\r\n🙂 needle here\nlast"
            let legacy = try RustSearchLegacyOracle.search(
                pattern: pattern,
                subject: subject,
                contextLines: 1
            )
            let bridge = try await AgentryCoreBridge.start()
            let client = try await bridge.searchClient()
            let rust = try await client.searchRegex(.init(
                pattern: pattern,
                subject: subject,
                contextLines: 1
            ))

            assertContentParity(legacy, rust, label: "basic-content")
            XCTAssertEqual(rust.diagnostic.jitStatus, .active)
            _ = try await bridge.close()
        #else
            throw XCTSkip("The legacy differential oracle is DEBUG-only")
        #endif
    }

    func testUnicodeLineEndingZeroLengthAndCrossLineParity() async throws {
        #if DEBUG
            let cases: [(String, String, UInt16)] = [
                ("[α🙂]", "α\r🙂\r\n\nend\n", 1),
                ("(?=needle)", "before\nneedle\nafter", 1),
                ("β\\r?\\nγ", "β\r\nγ\nlast", 1),
                ("[abc]", "a\rb\r\n\nc\n", 2),
                ("needle", "", 1),
                ("needle", String(repeating: "x", count: 100_000) + "needle", 0)
            ]
            let bridge = try await AgentryCoreBridge.start()
            let client = try await bridge.searchClient()
            for (index, value) in cases.enumerated() {
                let legacy = try RustSearchLegacyOracle.search(
                    pattern: value.0,
                    subject: value.1,
                    contextLines: value.2
                )
                let rust = try await client.searchRegex(.init(
                    pattern: value.0,
                    subject: value.1,
                    contextLines: value.2
                ))
                assertContentParity(legacy, rust, label: "line-case-\(index)")
            }
            let unicodeLegacy = try RustSearchLegacyOracle.search(
                pattern: "β",
                subject: "αβ γ Β",
                caseInsensitive: true,
                wholeWord: true
            )
            let unicodeRust = try await client.searchRegex(.init(
                pattern: "β",
                subject: "αβ γ Β",
                caseInsensitive: true,
                wholeWord: true
            ))
            assertContentParity(unicodeLegacy, unicodeRust, label: "unicode-casefold-whole-word")
            _ = try await bridge.close()
        #else
            throw XCTSkip("The legacy differential oracle is DEBUG-only")
        #endif
    }

    func testRepairAndErrorClassificationParity() async throws {
        #if DEBUG
            let bridge = try await AgentryCoreBridge.start()
            let client = try await bridge.searchClient()
            for (pattern, subject) in [(#"\\("#, "("), (")", ")")] {
                let legacy = try RustSearchLegacyOracle.search(pattern: pattern, subject: subject)
                let rust = try await client.searchRegex(.init(pattern: pattern, subject: subject))
                assertContentParity(legacy, rust, label: "repair-\(pattern.utf8.count)")
            }

            let invalidPatterns = [#"\q"#, "[", "(", "*", "(?<=.*)x", String(repeating: "a", count: 2001)]
            for (index, pattern) in invalidPatterns.enumerated() {
                let legacy = captureLegacyError(pattern: pattern, subject: "x")
                let rust = await captureRustError(client: client, pattern: pattern, subject: "x")
                XCTAssertEqual(legacy, rust, "error-case-\(index)")
            }
            let limitPattern = "(*LIMIT_MATCH=1)(?:a+)+$"
            let limitSubject = String(repeating: "a", count: 128) + "!"
            let legacyLimit = captureLegacyError(pattern: limitPattern, subject: limitSubject)
            let rustLimit = await captureRustError(client: client, pattern: limitPattern, subject: limitSubject)
            XCTAssertEqual(legacyLimit, .matchLimitExceeded)
            XCTAssertEqual(legacyLimit, rustLimit, "match-limit")
            _ = try await bridge.close()
        #else
            throw XCTSkip("The legacy differential oracle is DEBUG-only")
        #endif
    }

    func testRegisteredInterpreterFallbackParity() async throws {
        #if DEBUG
            let pattern = #"\C"#
            let subject = "ba"
            let legacy = try RustSearchLegacyOracle.search(pattern: pattern, subject: subject)
            let bridge = try await AgentryCoreBridge.start()
            let client = try await bridge.searchClient()
            let rust = try await client.searchRegex(.init(pattern: pattern, subject: subject))
            assertContentParity(legacy, rust, label: "registered-interpreter-fallback")
            XCTAssertEqual(rust.diagnostic.jitStatus, .pcre2InterpreterFallback)
            _ = try await bridge.close()
        #else
            throw XCTSkip("The legacy differential oracle is DEBUG-only")
        #endif
    }

    func testFastPlansEqualLegacyAndForcedGeneralPCRE2() async throws {
        #if DEBUG
            let cases: [(pattern: String, forced: String, subject: String, wholeWord: Bool, mode: CoreRegexSearchMode, policy: CoreMatchPolicy, legacyPolicy: CoreSearchLegacyMatchPolicy, engine: CoreSearchEngine)] = [
                ("word", #"\b(?:word)\b"#, "a word here", true, .content, .contentLine, .line, .asciiWholeWord),
                (#"^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*"#, #"(?:^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*)"#, " final class Thing", false, .content, .contentLine, .line, .anchoredDeclaration),
                (#"\bTODO-\d{3}:\s+Search\w*"#, #"(?:\bTODO-\d{3}:\s+Search\w*)"#, "TODO-123: SearchLeaf", false, .content, .contentLine, .line, .asciiMarker),
                (#"^import\b"#, #"(?:^import\b)"#, "import Foundation", false, .content, .contentLine, .line, .anchoredLinePrefilter),
                (#".*\.(swift|rs)$"#, #"(?:.*\.(swift|rs)$)"#, "src/main.swift", false, .path, .shortPath, .path, .pathSuffix)
            ]
            let bridge = try await AgentryCoreBridge.start()
            let client = try await bridge.searchClient()
            for value in cases {
                let legacy = try RustSearchLegacyOracle.search(
                    pattern: value.pattern,
                    subject: value.subject,
                    wholeWord: value.wholeWord,
                    matchPolicy: value.legacyPolicy
                )
                let fast = try await client.searchRegex(.init(
                    mode: value.mode,
                    pattern: value.pattern,
                    subject: value.subject,
                    wholeWord: value.wholeWord,
                    matchPolicy: value.policy
                ))
                let general = try await client.searchRegex(.init(
                    mode: value.mode,
                    pattern: value.forced,
                    subject: value.subject,
                    matchPolicy: value.policy
                ))
                assertContentParity(legacy, fast, label: "fast-\(value.engine)")
                XCTAssertEqual(fast.hits, general.hits, "forced-general-\(value.engine)")
                XCTAssertEqual(fast.matchingLineCount, general.matchingLineCount)
                XCTAssertEqual(fast.diagnostic.engine, value.engine)
                XCTAssertEqual(general.diagnostic.engine, .pcre2)
            }
            _ = try await bridge.close()
        #else
            throw XCTSkip("The legacy differential oracle is DEBUG-only")
        #endif
    }

    func testCollectionLimitsAndCancellationParity() async throws {
        #if DEBUG
            let subject = (0 ..< 20).map { "needle-\($0)" }.joined(separator: "\n")
            let legacy = try RustSearchLegacyOracle.search(
                pattern: "needle",
                subject: subject,
                maxCollectedMatches: 3
            )
            let bridge = try await AgentryCoreBridge.start()
            let client = try await bridge.searchClient()
            let rust = try await client.searchRegex(.init(
                pattern: "needle",
                subject: subject,
                maxCollectedMatches: 3
            ))
            assertContentParity(legacy, rust, label: "collection-cap")
            XCTAssertEqual(rust.matchingLineCount, 20)
            XCTAssertEqual(rust.hits.count, 3)

            let barrier = RustSearchCancellationBarrier(expectedArrivals: 2)
            let legacyTask = Task {
                await barrier.arriveAndWait()
                return try RustSearchLegacyOracle.search(pattern: "needle", subject: subject)
            }
            let rustTask = Task {
                await barrier.arriveAndWait()
                return try await client.searchRegex(.init(pattern: "needle", subject: subject))
            }
            await barrier.waitUntilAllArrived()
            legacyTask.cancel()
            rustTask.cancel()
            await barrier.release()
            await assertCancellation(legacyTask)
            await assertCancellation(rustTask)
            _ = try await bridge.close()
        #else
            throw XCTSkip("The legacy differential oracle is DEBUG-only")
        #endif
    }

    func testPathClausesGlobFolderSuffixAndCancellationParity() async throws {
        #if DEBUG
            let snapshots = [
                FileSearchPathSnapshot(standardizedFullPath: "/root/Sources/App/View.swift", standardizedRelativePath: "Sources/App/View.swift", standardizedRootPath: "/root", clientDisplayPath: "App/Sources/App/View.swift"),
                FileSearchPathSnapshot(standardizedFullPath: "/root/Sources/Domain/Model.swift", standardizedRelativePath: "Sources/Domain/Model.swift", standardizedRootPath: "/root", clientDisplayPath: "App/Sources/Domain/Model.swift"),
                FileSearchPathSnapshot(standardizedFullPath: "/other/Tests/AppTests.swift", standardizedRelativePath: "Tests/AppTests.swift", standardizedRootPath: "/other", clientDisplayPath: "Lib/Tests/AppTests.swift"),
                FileSearchPathSnapshot(standardizedFullPath: "/root/Docs/Guide.md", standardizedRelativePath: "Docs/Guide.md", standardizedRootPath: "/root", clientDisplayPath: "App/Docs/Guide.md")
            ]
            let legacySpec = SearchPathFilterSpec(caseInsensitive: true, clauses: [
                .exactFile(absPath: "/other/Tests/AppTests.swift", relPath: "missing", restrictedRootPath: nil),
                .exactFolder(absLower: "/root/sources/app", relLower: "sources/app", restrictedRootPath: "/root"),
                .glob(pattern: "App/**/Model.swift", restrictedRootPath: "/root"),
                .legacyPrefix(candidateLower: "docs")
            ])
            let legacy = filterPathIndicesResult(snapshots: snapshots, spec: legacySpec)
            let coreSnapshots = snapshots.map {
                CorePathSnapshot(
                    standardizedFullPath: $0.standardizedFullPath,
                    standardizedRelativePath: $0.standardizedRelativePath,
                    standardizedRootPath: $0.standardizedRootPath,
                    clientDisplayPath: $0.clientDisplayPath
                )
            }
            let bridge = try await AgentryCoreBridge.start()
            let client = try await bridge.searchClient()
            let rust = try await client.filterPaths(.init(snapshots: coreSnapshots, clauses: [
                .exactFile(absPath: "/other/Tests/AppTests.swift", relPath: "missing", restrictedRootPath: nil),
                .exactFolder(absLower: "/root/sources/app", relLower: "sources/app", restrictedRootPath: "/root"),
                .glob(pattern: "App/**/Model.swift", restrictedRootPath: "/root"),
                .legacyPrefix(candidateLower: "docs")
            ], caseInsensitive: true))
            XCTAssertEqual(legacy.matchedSnapshotIndices, rust.matchedSnapshotIndices.map(Int.init))
            XCTAssertEqual(legacy.visitedSnapshotCount, Int(rust.visitedSnapshotCount))
            XCTAssertEqual(legacy.cancelled, rust.cancelled)

            for emptySnapshots in [snapshots, []] {
                let emptyLegacy = filterPathIndicesResult(
                    snapshots: emptySnapshots,
                    spec: SearchPathFilterSpec(caseInsensitive: false, clauses: [])
                )
                let emptyRust = try await client.filterPaths(.init(
                    snapshots: emptySnapshots.map {
                        CorePathSnapshot(
                            standardizedFullPath: $0.standardizedFullPath,
                            standardizedRelativePath: $0.standardizedRelativePath,
                            standardizedRootPath: $0.standardizedRootPath,
                            clientDisplayPath: $0.clientDisplayPath
                        )
                    },
                    clauses: [],
                    caseInsensitive: false
                ))
                XCTAssertEqual(emptyLegacy.matchedSnapshotIndices, emptyRust.matchedSnapshotIndices.map(Int.init))
                XCTAssertEqual(emptyLegacy.visitedSnapshotCount, Int(emptyRust.visitedSnapshotCount))
                XCTAssertEqual(emptyLegacy.cancelled, emptyRust.cancelled)
            }

            let globCases: [(String, String?, Bool)] = [
                ("App/**/Model.swift", "/root", true),
                ("Sources/*/View.swift", nil, false),
                ("**/*.SWIFT", nil, true),
                ("/root/Sources/**", nil, false)
            ]
            for (pattern, restrictedRootPath, caseInsensitive) in globCases {
                let globLegacy = filterPathIndicesResult(
                    snapshots: snapshots,
                    spec: SearchPathFilterSpec(
                        caseInsensitive: caseInsensitive,
                        clauses: [.glob(pattern: pattern, restrictedRootPath: restrictedRootPath)]
                    )
                )
                let globRust = try await client.filterPaths(.init(
                    snapshots: coreSnapshots,
                    clauses: [.glob(pattern: pattern, restrictedRootPath: restrictedRootPath)],
                    caseInsensitive: caseInsensitive
                ))
                XCTAssertEqual(globLegacy.matchedSnapshotIndices, globRust.matchedSnapshotIndices.map(Int.init), pattern)
                XCTAssertEqual(globLegacy.visitedSnapshotCount, Int(globRust.visitedSnapshotCount), pattern)
            }

            let relativePaths = ["Sources", "Nested/Sources", "SourcesExtra", "Tests"]
            let legacyFolders = Dictionary(uniqueKeysWithValues: relativePaths.indices.map { ("/folder/\($0)", $0) })
            let legacySuffix = resolveFoldersBySuffixFragment("/Sources/", in: legacyFolders) { relativePaths[$0] }.sorted()
            let rustSuffix = try await client.folderSuffixIndices(.init(fragment: "/Sources/", relativePaths: relativePaths))
            XCTAssertEqual(legacySuffix, rustSuffix.map(Int.init))

            let cancellationBarrier = RustSearchCancellationBarrier(expectedArrivals: 2)
            let legacyCancellation = Task {
                await cancellationBarrier.arriveAndWait()
                return filterPathIndicesResult(snapshots: snapshots, spec: legacySpec)
            }
            let rustCancellation = Task {
                await cancellationBarrier.arriveAndWait()
                return try await client.filterPaths(.init(
                    snapshots: coreSnapshots,
                    clauses: [.legacyPrefix(candidateLower: "sources")],
                    caseInsensitive: true
                ))
            }
            await cancellationBarrier.waitUntilAllArrived()
            legacyCancellation.cancel()
            rustCancellation.cancel()
            await cancellationBarrier.release()
            let legacyCancelled = await legacyCancellation.value
            let rustCancelled = try await rustCancellation.value
            XCTAssertTrue(legacyCancelled.cancelled)
            XCTAssertTrue(rustCancelled.cancelled)
            XCTAssertEqual(legacyCancelled.visitedSnapshotCount, Int(rustCancelled.visitedSnapshotCount))
            XCTAssertEqual(legacyCancelled.matchedSnapshotIndices, rustCancelled.matchedSnapshotIndices.map(Int.init))
            _ = try await bridge.close()
        #else
            throw XCTSkip("The legacy differential oracle is DEBUG-only")
        #endif
    }

    func testFixedSeedSyntheticPropertyCorpusParity() async throws {
        #if DEBUG
            let seed: UInt64 = 0x5EED_CAFE
            var generator = RustSearchSeededGenerator(state: seed)
            let bridge = try await AgentryCoreBridge.start()
            let client = try await bridge.searchClient()
            for caseIndex in 0 ..< 64 {
                let lineEnding = ["\n", "\r\n", "\r"][generator.nextInt(upperBound: 3)]
                let lineCount = 1 + generator.nextInt(upperBound: 12)
                var lines: [String] = []
                for line in 0 ..< lineCount {
                    let prefix = generator.nextInt(upperBound: 2) == 0 ? "α🙂" : "ascii"
                    let token = generator.nextInt(upperBound: 4) == 0 ? " needle" : ""
                    lines.append("\(prefix)-\(line)-\(generator.next())\(token)")
                }
                let subject = lines.joined(separator: lineEnding)
                let pattern = generator.nextInt(upperBound: 2) == 0 ? "needle" : "(?:α🙂|ascii)"
                let label = "seed=0x5eedcafe case=\(caseIndex) digest=\(fnv1a(subject))"
                let legacy = try RustSearchLegacyOracle.search(pattern: pattern, subject: subject, contextLines: 2)
                let rust = try await client.searchRegex(.init(pattern: pattern, subject: subject, contextLines: 2))
                assertContentParity(legacy, rust, label: label)
            }
            _ = try await bridge.close()
        #else
            throw XCTSkip("The legacy differential oracle is DEBUG-only")
        #endif
    }
}

#if DEBUG
    private func assertContentParity(
        _ legacy: RustSearchLegacyResult,
        _ rust: CoreRegexSearchResult,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(legacy.matchingLineCount, rust.matchingLineCount, label, file: file, line: line)
        XCTAssertEqual(legacy.hits.count, rust.hits.count, label, file: file, line: line)
        for (legacyHit, rustHit) in zip(legacy.hits, rust.hits) {
            XCTAssertEqual(legacyHit.lineNumber, rustHit.lineNumber, label, file: file, line: line)
            XCTAssertEqual(coreRange(legacyHit.lineByteRange), rustHit.lineByteRange, label, file: file, line: line)
            XCTAssertEqual(coreRange(legacyHit.matchByteRange), rustHit.matchByteRange, label, file: file, line: line)
            XCTAssertEqual(
                legacyHit.contextBeforeByteRanges.map(coreRange),
                rustHit.contextBeforeByteRanges,
                label,
                file: file,
                line: line
            )
            XCTAssertEqual(
                legacyHit.contextAfterByteRanges.map(coreRange),
                rustHit.contextAfterByteRanges,
                label,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(coreRepairKind(legacy.repairKind), rust.diagnostic.repairKind, label, file: file, line: line)
    }

    private func coreRange(_ range: RustSearchLegacyByteRange) -> CoreByteRange {
        CoreByteRange(start: range.start, end: range.end)
    }

    private func coreRepairKind(_ kind: RustSearchLegacyRepairKind) -> CoreRepairKind {
        switch kind {
        case .none: .none
        case .doubleEscapeCompression: .doubleEscapeCompression
        case .normalise: .normalise
        case .normaliseThenCompression: .normaliseThenCompression
        }
    }

    private enum DifferentialErrorKind: Equatable {
        case patternTooComplex
        case invalidEscape
        case unmatchedBrackets
        case unmatchedParentheses
        case invalidQuantifier
        case variableLengthLookbehind
        case invalidPattern
        case matchLimitExceeded
        case depthLimitExceeded
        case heapLimitExceeded
        case other
    }

    private func captureLegacyError(pattern: String, subject: String) -> DifferentialErrorKind {
        do {
            _ = try RustSearchLegacyOracle.search(pattern: pattern, subject: subject)
            return .other
        } catch let error as RustSearchLegacyError {
            return switch error {
            case .patternTooComplex: .patternTooComplex
            case .invalidEscape: .invalidEscape
            case .unmatchedBrackets: .unmatchedBrackets
            case .unmatchedParentheses: .unmatchedParentheses
            case .invalidQuantifier: .invalidQuantifier
            case .variableLengthLookbehind: .variableLengthLookbehind
            case .invalidPattern: .invalidPattern
            case .matchLimitExceeded: .matchLimitExceeded
            case .depthLimitExceeded: .depthLimitExceeded
            case .heapLimitExceeded: .heapLimitExceeded
            }
        } catch {
            return .other
        }
    }

    private func captureRustError(
        client: CoreSearchClient,
        pattern: String,
        subject: String
    ) async -> DifferentialErrorKind {
        do {
            _ = try await client.searchRegex(.init(pattern: pattern, subject: subject))
            return .other
        } catch let error as CoreSearchError {
            return switch error {
            case .patternTooComplex: .patternTooComplex
            case let .invalidPattern(reason): switch reason {
                case .invalidEscape: .invalidEscape
                case .unmatchedBrackets: .unmatchedBrackets
                case .unmatchedParentheses: .unmatchedParentheses
                case .invalidQuantifier: .invalidQuantifier
                case .variableLengthLookbehind: .variableLengthLookbehind
                case .other: .invalidPattern
                }
            case .matchLimitExceeded: .matchLimitExceeded
            case .depthLimitExceeded: .depthLimitExceeded
            case .heapLimitExceeded: .heapLimitExceeded
            default: .other
            }
        } catch {
            return .other
        }
    }

    private func assertCancellation(_ task: Task<some Any, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
        }
    }

    private func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
#endif

private struct RustSearchSeededGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}

private actor RustSearchCancellationBarrier {
    private let expectedArrivals: Int
    private var arrivals = 0
    private var released = false
    private var allArrivedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(expectedArrivals: Int) {
        self.expectedArrivals = expectedArrivals
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == expectedArrivals {
            let waiters = allArrivedWaiters
            allArrivedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilAllArrived() async {
        guard arrivals < expectedArrivals else { return }
        await withCheckedContinuation { allArrivedWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
