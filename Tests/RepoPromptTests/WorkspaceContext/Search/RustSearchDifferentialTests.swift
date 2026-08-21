import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import XCTest

final class RustSearchDifferentialTests: XCTestCase {
    func testBasicContentGoldenMatchesLinesByteRangesAndContext() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()
        let result = try await client.searchRegex(.init(
            pattern: "needle",
            subject: "α first\r\n🙂 needle here\nlast",
            contextLines: 1
        ))

        XCTAssertEqual(result.matchingLineCount, 1)
        XCTAssertEqual(result.hits, [
            .init(
                lineNumber: 1,
                lineByteRange: .init(start: 10, end: 26),
                matchByteRange: .init(start: 15, end: 21),
                contextBeforeByteRanges: [.init(start: 0, end: 8)],
                contextAfterByteRanges: [.init(start: 27, end: 31)]
            )
        ])
        XCTAssertEqual(result.diagnostic.repairKind, .none)
        XCTAssertEqual(result.diagnostic.jitStatus, .active)
        _ = try await bridge.close()
    }

    func testUnicodeLineEndingZeroLengthAndCrossLineGoldens() async throws {
        let cases: [(pattern: String, subject: String, context: UInt16, lines: [UInt32], count: UInt64)] = [
            ("[α🙂]", "α\r🙂\r\n\nend\n", 1, [0, 1], 2),
            ("(?=needle)", "before\nneedle\nafter", 1, [1], 1),
            ("β\\r?\\nγ", "β\r\nγ\nlast", 1, [0], 1),
            ("[abc]", "a\rb\r\n\nc\n", 2, [0, 1, 3], 3),
            ("needle", "", 1, [], 0),
            ("needle", String(repeating: "x", count: 100_000) + "needle", 0, [0], 1)
        ]
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()
        for (index, value) in cases.enumerated() {
            let result = try await client.searchRegex(.init(
                pattern: value.pattern,
                subject: value.subject,
                contextLines: value.context
            ))
            XCTAssertEqual(result.hits.map(\.lineNumber), value.lines, "line-case-\(index)")
            XCTAssertEqual(result.matchingLineCount, value.count, "line-case-\(index)")
        }

        let unicode = try await client.searchRegex(.init(
            pattern: "β",
            subject: "αβ γ Β",
            caseInsensitive: true,
            wholeWord: true
        ))
        XCTAssertEqual(unicode.hits.map(\.lineNumber), [0])
        XCTAssertEqual(unicode.matchingLineCount, 1)
        _ = try await bridge.close()
    }

    func testRepairAndErrorClassificationGoldens() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()

        let compressed = try await client.searchRegex(.init(pattern: #"\\("#, subject: "("))
        XCTAssertEqual(compressed.matchingLineCount, 1)
        XCTAssertEqual(compressed.diagnostic.repairKind, .doubleEscapeCompression)

        let normalised = try await client.searchRegex(.init(pattern: ")", subject: ")"))
        XCTAssertEqual(normalised.matchingLineCount, 1)
        XCTAssertEqual(normalised.diagnostic.repairKind, .normalise)

        let invalidPatterns: [(String, DifferentialErrorKind)] = [
            (#"\q"#, .invalidEscape),
            ("[", .unmatchedBrackets),
            ("(", .unmatchedParentheses),
            ("*", .invalidQuantifier),
            ("(?<=.*)x", .variableLengthLookbehind),
            (String(repeating: "a", count: 2001), .patternTooComplex)
        ]
        for (index, value) in invalidPatterns.enumerated() {
            let error = await captureRustError(client: client, pattern: value.0, subject: "x")
            XCTAssertEqual(error, value.1, "error-case-\(index)")
        }

        let normalizeOnly = try await client.searchRegex(.init(
            pattern: #"\\\\{)"#,
            subject: #"\\{)"#
        ))
        XCTAssertEqual(normalizeOnly.diagnostic.repairKind, .normalise)
        XCTAssertEqual(normalizeOnly.matchingLineCount, 1)
        XCTAssertEqual(normalizeOnly.hits.map(\.lineNumber), [0])
        XCTAssertEqual(normalizeOnly.hits.map(\.matchByteRange), [.init(start: 0, end: 4)])

        let matchLimit = await captureRustError(
            client: client,
            pattern: "(*LIMIT_MATCH=1)(?:a+)+$",
            subject: String(repeating: "a", count: 128) + "!"
        )
        XCTAssertEqual(matchLimit, .matchLimitExceeded)

        let policyTiers: [(CoreMatchPolicy, CoreRegexSearchMode, String)] = [
            (.contentFullBuffer, .content, "full-buffer"),
            (.contentLine, .content, "line"),
            (.shortPath, .path, "path")
        ]
        for (policy, mode, label) in policyTiers {
            let depth = await captureRustError(
                client: client,
                mode: mode,
                pattern: #"(*LIMIT_DEPTH=1)(?:\C)?^(a(?1)?b)$"#,
                subject: "aaaabbbb",
                matchPolicy: policy
            )
            XCTAssertEqual(depth, .depthLimitExceeded, "depth-\(label)")

            let heap = await captureRustError(
                client: client,
                mode: mode,
                pattern: #"(*LIMIT_HEAP=1)(?:\C)?^(?:(a+)+)+$"#,
                subject: String(repeating: "a", count: 4096) + "!",
                matchPolicy: policy
            )
            XCTAssertEqual(heap, .heapLimitExceeded, "heap-\(label)")
        }
        _ = try await bridge.close()
    }

    func testRegisteredInterpreterFallbackGolden() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()
        let result = try await client.searchRegex(.init(pattern: #"\C"#, subject: "ba"))
        XCTAssertEqual(result.matchingLineCount, 1)
        XCTAssertEqual(result.hits.map(\.matchByteRange), [.init(start: 0, end: 1)])
        XCTAssertEqual(result.diagnostic.jitStatus, .pcre2InterpreterFallback)
        _ = try await bridge.close()
    }

    func testFastPlanGoldensAndForcedGeneralEngine() async throws {
        let cases: [(pattern: String, forced: String, subject: String, wholeWord: Bool, mode: CoreRegexSearchMode, policy: CoreMatchPolicy, engine: CoreSearchEngine)] = [
            ("word", #"\b(?:word)\b"#, "a word here", true, .content, .contentLine, .asciiWholeWord),
            (#"^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*"#, #"(?:^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*)"#, " final class Thing", false, .content, .contentLine, .anchoredDeclaration),
            (#"\bTODO-\d{3}:\s+Search\w*"#, #"(?:\bTODO-\d{3}:\s+Search\w*)"#, "TODO-123: SearchLeaf", false, .content, .contentLine, .asciiMarker),
            (#"^import\b"#, #"(?:^import\b)"#, "import Foundation", false, .content, .contentLine, .anchoredLinePrefilter),
            (#".*\.(swift|rs)$"#, #"(?:.*\.(swift|rs)$)"#, "src/main.swift", false, .path, .shortPath, .pathSuffix)
        ]
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()
        for value in cases {
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
            XCTAssertEqual(fast.matchingLineCount, 1, "\(value.engine)")
            XCTAssertEqual(fast.hits.map(\.lineNumber), [0], "\(value.engine)")
            XCTAssertEqual(fast.hits, general.hits, "forced-general-\(value.engine)")
            XCTAssertEqual(fast.diagnostic.engine, value.engine)
            XCTAssertEqual(general.diagnostic.engine, .pcre2)
        }
        _ = try await bridge.close()
    }

    func testCollectionLimitAndCancellationGoldens() async throws {
        let subject = (0 ..< 20).map { "needle-\($0)" }.joined(separator: "\n")
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()
        let result = try await client.searchRegex(.init(
            pattern: "needle",
            subject: subject,
            maxCollectedMatches: 3
        ))
        XCTAssertEqual(result.matchingLineCount, 20)
        XCTAssertEqual(result.hits.map(\.lineNumber), [0, 1, 2])

        let barrier = RustSearchCancellationBarrier(expectedArrivals: 1)
        let task = Task {
            await barrier.arriveAndWait()
            return try await client.searchRegex(.init(pattern: "needle", subject: subject))
        }
        await barrier.waitUntilAllArrived()
        task.cancel()
        await barrier.release()
        await assertCancellation(task)
        _ = try await bridge.close()
    }

    func testPathClausesGlobFolderSuffixAndCancellationGoldens() async throws {
        let snapshots = [
            FileSearchPathSnapshot(standardizedFullPath: "/root/Sources/App/View.swift", standardizedRelativePath: "Sources/App/View.swift", standardizedRootPath: "/root", clientDisplayPath: "App/Sources/App/View.swift"),
            FileSearchPathSnapshot(standardizedFullPath: "/root/Sources/Domain/Model.swift", standardizedRelativePath: "Sources/Domain/Model.swift", standardizedRootPath: "/root", clientDisplayPath: "App/Sources/Domain/Model.swift"),
            FileSearchPathSnapshot(standardizedFullPath: "/other/Tests/AppTests.swift", standardizedRelativePath: "Tests/AppTests.swift", standardizedRootPath: "/other", clientDisplayPath: "Lib/Tests/AppTests.swift"),
            FileSearchPathSnapshot(standardizedFullPath: "/root/Docs/Guide.md", standardizedRelativePath: "Docs/Guide.md", standardizedRootPath: "/root", clientDisplayPath: "App/Docs/Guide.md")
        ]
        let coreSnapshots = snapshots.map(CorePathSnapshot.init)
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()
        let result = try await client.filterPaths(.init(snapshots: coreSnapshots, clauses: [
            .exactFile(absPath: "/other/Tests/AppTests.swift", relPath: "missing", restrictedRootPath: nil),
            .exactFolder(absLower: "/root/sources/app", relLower: "sources/app", restrictedRootPath: "/root"),
            .glob(pattern: "App/**/Model.swift", restrictedRootPath: "/root"),
            .legacyPrefix(candidateLower: "docs")
        ], caseInsensitive: true))
        XCTAssertEqual(result.matchedSnapshotIndices.map(Int.init), [0, 1, 2, 3])
        XCTAssertEqual(result.visitedSnapshotCount, 4)
        XCTAssertFalse(result.cancelled)

        let empty = try await client.filterPaths(.init(snapshots: coreSnapshots, clauses: [], caseInsensitive: false))
        XCTAssertEqual(empty.matchedSnapshotIndices, [])
        // rust-search-leaf-v1 counts each snapshot whose evaluation began; no clauses means no matches, not no visits.
        XCTAssertEqual(empty.visitedSnapshotCount, 4)
        XCTAssertFalse(empty.cancelled)

        let globCases: [(String, String?, Bool, [Int])] = [
            ("App/**/Model.swift", "/root", true, [1]),
            ("Sources/*/View.swift", nil, false, [0]),
            ("**/*.SWIFT", nil, true, [0, 1, 2]),
            ("/root/Sources/**", nil, false, [0, 1])
        ]
        for (pattern, restrictedRootPath, caseInsensitive, expected) in globCases {
            let glob = try await client.filterPaths(.init(
                snapshots: coreSnapshots,
                clauses: [.glob(pattern: pattern, restrictedRootPath: restrictedRootPath)],
                caseInsensitive: caseInsensitive
            ))
            XCTAssertEqual(glob.matchedSnapshotIndices.map(Int.init), expected, pattern)
            XCTAssertEqual(glob.visitedSnapshotCount, 4, pattern)
        }

        let suffix = try await client.folderSuffixIndices(.init(
            fragment: "/Sources/",
            relativePaths: ["Sources", "Nested/Sources", "SourcesExtra", "Tests"]
        ))
        XCTAssertEqual(suffix.map(Int.init), [0, 1])
        _ = try await bridge.close()
    }

    func testFixedSeedSyntheticPropertyCorpusGoldens() async throws {
        let seed: UInt64 = 0x5EED_CAFE
        var generator = RustSearchSeededGenerator(state: seed)
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()
        for caseIndex in 0 ..< 64 {
            let lineEnding = ["\n", "\r\n", "\r"][generator.nextInt(upperBound: 3)]
            let lineCount = 1 + generator.nextInt(upperBound: 12)
            var lines: [String] = []
            var needleLines: [UInt32] = []
            for line in 0 ..< lineCount {
                let prefix = generator.nextInt(upperBound: 2) == 0 ? "α🙂" : "ascii"
                let hasNeedle = generator.nextInt(upperBound: 4) == 0
                if hasNeedle {
                    needleLines.append(UInt32(line))
                }
                lines.append("\(prefix)-\(line)-\(generator.next())\(hasNeedle ? " needle" : "")")
            }
            let subject = lines.joined(separator: lineEnding)
            let usesNeedle = generator.nextInt(upperBound: 2) == 0
            let pattern = usesNeedle ? "needle" : "(?:α🙂|ascii)"
            let expectedLines = usesNeedle ? needleLines : lines.indices.map(UInt32.init)
            let result = try await client.searchRegex(.init(pattern: pattern, subject: subject, contextLines: 2))
            let label = "seed=0x5eedcafe case=\(caseIndex) digest=\(fnv1a(subject))"
            XCTAssertEqual(result.hits.map(\.lineNumber), expectedLines, label)
            XCTAssertEqual(result.matchingLineCount, UInt64(expectedLines.count), label)
        }
        _ = try await bridge.close()
    }
}

private extension CorePathSnapshot {
    init(_ snapshot: FileSearchPathSnapshot) {
        self.init(
            standardizedFullPath: snapshot.standardizedFullPath,
            standardizedRelativePath: snapshot.standardizedRelativePath,
            standardizedRootPath: snapshot.standardizedRootPath,
            clientDisplayPath: snapshot.clientDisplayPath
        )
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

private func captureRustError(
    client: CoreSearchClient,
    mode: CoreRegexSearchMode = .content,
    pattern: String,
    subject: String,
    matchPolicy: CoreMatchPolicy = .contentFullBuffer
) async -> DifferentialErrorKind {
    do {
        _ = try await client.searchRegex(.init(
            mode: mode,
            pattern: pattern,
            subject: subject,
            matchPolicy: matchPolicy
        ))
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

private func assertCancellation(
    _ task: Task<some Any, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
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
