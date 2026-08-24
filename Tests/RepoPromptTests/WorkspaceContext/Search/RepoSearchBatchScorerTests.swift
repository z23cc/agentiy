import AgentryCoreBridge
@testable import RepoPromptApp
import XCTest

final class RepoSearchBatchScorerTests: XCTestCase {
    private func candidate(
        name: String,
        path: String,
        nameLower: String? = nil,
        pathLower: String? = nil
    ) -> RepoSearchBatchScorer.Candidate {
        RepoSearchBatchScorer.Candidate(
            name: name,
            path: path,
            nameLower: nameLower ?? name.lowercased(),
            pathLower: pathLower ?? path.lowercased()
        )
    }

    private func query(
        _ raw: String,
        lowered: String? = nil,
        hasSlash: Bool? = nil,
        isWildcard: Bool = false
    ) -> RepoSearchQuery {
        RepoSearchQuery(
            raw: raw,
            lowered: lowered ?? raw.lowercased(),
            hasSlash: hasSlash ?? raw.contains("/"),
            isWildcard: isWildcard
        )
    }

    private func assertScore(
        _ expected: Int32,
        candidate: RepoSearchBatchScorer.Candidate,
        query: RepoSearchQuery,
        threshold: Double = 0.8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let scores = await RepoSearchBatchScorer.scores(
            for: [candidate],
            query: query,
            fuzzyThreshold: threshold
        )
        XCTAssertEqual(scores, [expected], file: file, line: line)
    }

    func testPinsEveryLiveCScoreTier() async {
        await assertScore(1000, candidate: candidate(name: "readme.md", path: "docs/readme.md"), query: query("readme.md"))
        await assertScore(950, candidate: candidate(name: "other", path: "docs/readme.md"), query: query("docs/readme.md"))
        await assertScore(1000, candidate: candidate(name: "readme.md", path: "docs/readme.md"), query: query("readme"))
        await assertScore(900, candidate: candidate(name: "reader.txt", path: "docs/reader.txt"), query: query("read"))
        await assertScore(875, candidate: candidate(name: "other", path: "src/apple/file"), query: query("src/app"))
        await assertScore(850, candidate: candidate(name: "other", path: "src/utility/file"), query: query("util"))
        await assertScore(750, candidate: candidate(name: "readme.md", path: "docs/readme.md"), query: query("adme"))
        await assertScore(700, candidate: candidate(name: "other", path: "src/app/service.swift"), query: query("app/ser"))
        await assertScore(650, candidate: candidate(name: "main.swift", path: "src/main.swift"), query: query("*.swift", isWildcard: true))
        await assertScore(500, candidate: candidate(name: "readme", path: "docs/readme"), query: query("reedme"))
        await assertScore(450, candidate: candidate(name: "other", path: "src/utility/file"), query: query("utxlity"), threshold: 0.85)
        await assertScore(0, candidate: candidate(name: "other", path: "src/utility/file"), query: query("zzzz"))
    }

    func testPreservesCandidateCountOrderAndLegacyWildcardFlags() async {
        let ordered = await RepoSearchBatchScorer.scores(
            for: [
                candidate(name: "zeta.txt", path: "long/path/zeta.txt"),
                candidate(name: "zed.txt", path: "z/zed.txt"),
                candidate(name: "other.txt", path: "other.txt")
            ],
            query: query("ze"),
            fuzzyThreshold: 0.8
        )
        XCTAssertEqual(ordered, [900, 900, 0])

        await assertScore(
            0,
            candidate: candidate(name: "Widget.SWIFT", path: "src/Widget.SWIFT"),
            query: query("*.swift", isWildcard: true)
        )
        await assertScore(
            650,
            candidate: candidate(name: "main.swift", path: "deep/src/main.swift"),
            query: query("**/*.swift", isWildcard: true)
        )
        await assertScore(
            650,
            candidate: candidate(name: "main.swift", path: "src/deep/main.swift"),
            query: query("src/**/*.swift", isWildcard: true)
        )
        await assertScore(
            0,
            candidate: candidate(name: "main.swift", path: "src/deep/more/main.swift"),
            query: query("src/**/*.swift", isWildcard: true)
        )
    }

    func testPinsCStringLowercaseThresholdAndBufferEdges() async {
        await assertScore(
            900,
            candidate: candidate(name: "readme", path: "docs/readme"),
            query: query("read\0ignored", lowered: "read\0ignored")
        )
        await assertScore(
            1000,
            candidate: candidate(
                name: "Ä.swift",
                path: "src/Ä.swift",
                nameLower: "ä.swift",
                pathLower: "src/ä.swift"
            ),
            query: query("Ä.SWIFT", lowered: "ä.swift")
        )
        await assertScore(0, candidate: candidate(name: "abcdef", path: "dir/other"), query: query("abcxef"), threshold: .nan)
        await assertScore(0, candidate: candidate(name: "abcdef", path: "dir/other"), query: query("abcxef"), threshold: .infinity)
        await assertScore(500, candidate: candidate(name: "abcdef", path: "dir/other"), query: query("zzzzzz"), threshold: -.infinity)

        let longName = String(repeating: "a", count: 1024) + ".txt"
        await assertScore(
            900,
            candidate: candidate(name: longName, path: "docs/long"),
            query: query(String(repeating: "a", count: 1024))
        )
        let longPath = String(repeating: "a", count: 2047) + "/target"
        await assertScore(
            0,
            candidate: candidate(name: "other", path: longPath),
            query: query("targot")
        )
    }

    func testReturnsCountPreservingZerosForBridgeRuntimeAndProtocolFailures() async {
        let candidates = [
            candidate(name: "first.swift", path: "Sources/first.swift"),
            candidate(name: "second.swift", path: "Sources/second.swift"),
            candidate(name: "third.swift", path: "Sources/third.swift")
        ]
        let failures: [CoreComputeError] = [
            .transportFailure("bridge unavailable"),
            .runtimeStopped,
            .malformedResponse
        ]

        for failure in failures {
            let scores = await RepoSearchBatchScorer.scores(
                for: candidates,
                query: query("swift"),
                fuzzyThreshold: 0.8,
                scoreBatch: { request in
                    XCTAssertEqual(request.candidates.count, 3)
                    throw failure
                }
            )
            XCTAssertEqual(scores, [0, 0, 0])
        }
    }

    func testEmptyInputsRemainEmpty() async {
        let nonemptyQuery = query("x")
        let noCandidates = await RepoSearchBatchScorer.scores(
            for: [],
            query: nonemptyQuery,
            fuzzyThreshold: 0.8
        )
        XCTAssertEqual(noCandidates, [])

        let emptyQuery = RepoSearchQuery(raw: "", lowered: "", hasSlash: false, isWildcard: false)
        let noQuery = await RepoSearchBatchScorer.scores(
            for: [candidate(name: "x", path: "x")],
            query: emptyQuery,
            fuzzyThreshold: 0.8
        )
        XCTAssertEqual(noQuery, [])
    }
}
