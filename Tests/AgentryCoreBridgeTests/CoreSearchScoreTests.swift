@testable import AgentryCoreBridge
import XCTest

final class CoreSearchScoreTests: XCTestCase {
    func testRealBatchPreservesCountOrderEmbeddedNULAndLiveWildcardFlags() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()

        let candidates = [
            CoreSearchScoreCandidateV1(
                name: "readme.md",
                path: "docs/readme.md",
                nameLower: "readme.md",
                pathLower: "docs/readme.md"
            ),
            CoreSearchScoreCandidateV1(
                name: "other",
                path: "docs/readable/file",
                nameLower: "other",
                pathLower: "docs/readable/file"
            ),
            CoreSearchScoreCandidateV1(
                name: "read",
                path: "read",
                nameLower: "read",
                pathLower: "read"
            )
        ]
        let query = CoreSearchScoreQueryV1(
            raw: "read\0ignored",
            lowered: "read\0ignored",
            hasSlash: false,
            isWildcard: false
        )
        let scores = try await client.scoreSearchMatchesV1(.init(
            candidates: candidates,
            query: query,
            fuzzyThreshold: 0.8
        ))
        XCTAssertEqual(scores, [900, 850, 1000])

        let wildcardScores = try await client.scoreSearchMatchesV1(.init(
            candidates: [
                .init(
                    name: "Widget.SWIFT",
                    path: "src/Widget.SWIFT",
                    nameLower: "widget.swift",
                    pathLower: "src/widget.swift"
                ),
                .init(
                    name: "Widget.swift",
                    path: "src/Widget.swift",
                    nameLower: "widget.swift",
                    pathLower: "src/widget.swift"
                )
            ],
            query: .init(
                raw: "*.swift",
                lowered: "*.swift",
                hasSlash: false,
                isWildcard: true
            ),
            fuzzyThreshold: 0.8
        ))
        XCTAssertEqual(wildcardScores, [0, 650])
        _ = try await bridge.close()
    }

    func testEmptyInputsReturnWithoutCallingTransport() async throws {
        let bridge = AgentryCoreBridge(transport: FakeCoreTransport())
        _ = try await bridge.initialize()
        let client = try await bridge.computeClient()
        let query = CoreSearchScoreQueryV1(
            raw: "query",
            lowered: "query",
            hasSlash: false,
            isWildcard: false
        )

        let emptyCandidates = try await client.scoreSearchMatchesV1(.init(
            candidates: [],
            query: query,
            fuzzyThreshold: 0.8
        ))
        XCTAssertEqual(emptyCandidates, [])

        let emptyQuery = try await client.scoreSearchMatchesV1(.init(
            candidates: [.init(name: "a", path: "a", nameLower: "a", pathLower: "a")],
            query: .init(raw: "", lowered: "", hasSlash: false, isWildcard: false),
            fuzzyThreshold: 0.8
        ))
        XCTAssertEqual(emptyQuery, [])
    }

    func testUnavailableTransportPropagatesAndMalformedCountFailsClosed() async throws {
        let bridge = AgentryCoreBridge(transport: FakeCoreTransport())
        _ = try await bridge.initialize()
        let client = try await bridge.computeClient()
        do {
            _ = try await client.scoreSearchMatchesV1(.init(
                candidates: [.init(name: "a", path: "a", nameLower: "a", pathLower: "a")],
                query: .init(raw: "a", lowered: "a", hasSlash: false, isWildcard: false),
                fuzzyThreshold: 0.8
            ))
            XCTFail("expected unavailable transport")
        } catch {
            XCTAssertEqual(
                error as? CoreComputeError,
                .transportFailure("search-score transport is unavailable")
            )
        }

        XCTAssertThrowsError(try CoreSearchScoreResponseValidator.validate([], candidateCount: 1)) {
            XCTAssertEqual($0 as? CoreComputeError, .malformedResponse)
        }
        XCTAssertNoThrow(try CoreSearchScoreResponseValidator.validate([1000, 0], candidateCount: 2))
    }
}
