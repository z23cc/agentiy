import Foundation
import os
import XCTest
@testable import AgentryCoreBridge

final class CoreSearchTests: XCTestCase {
    func testRealContentAndPathSearchEndToEnd() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()

        let subject = "α\n🙂needle\n尾"
        let content = try await client.searchRegex(.init(
            pattern: "needle",
            subject: subject,
            contextLines: 1
        ))
        XCTAssertEqual(content.matchingLineCount, 1)
        XCTAssertEqual(content.hits.count, 1)
        XCTAssertEqual(content.hits[0].lineNumber, 1)
        XCTAssertEqual(content.hits[0].lineByteRange, .init(start: 3, end: 13))
        XCTAssertEqual(content.hits[0].matchByteRange, .init(start: 7, end: 13))
        XCTAssertEqual(content.hits[0].contextBeforeByteRanges, [.init(start: 0, end: 2)])
        XCTAssertEqual(content.hits[0].contextAfterByteRanges, [.init(start: 14, end: 17)])

        let batch = try await client.searchRegexBatch(.init(
            pattern: "needle",
            subjects: ["first needle", "absent", "third needle"]
        ))
        XCTAssertEqual(batch.map(\.matchingLineCount), [1, 0, 1])
        XCTAssertEqual(batch.map { $0.hits.first?.matchByteRange }, [
            .init(start: 6, end: 12),
            nil,
            .init(start: 6, end: 12)
        ])

        let path = try await client.filterPaths(.init(
            snapshots: [
                .init(
                    standardizedFullPath: "/root/Sources/App.swift",
                    standardizedRelativePath: "Sources/App.swift",
                    standardizedRootPath: "/root",
                    clientDisplayPath: "Sources/App.swift"
                ),
                .init(
                    standardizedFullPath: "/root/Tests/AppTests.swift",
                    standardizedRelativePath: "Tests/AppTests.swift",
                    standardizedRootPath: "/root",
                    clientDisplayPath: "Tests/AppTests.swift"
                )
            ],
            clauses: [.glob(pattern: "Sources/**", restrictedRootPath: "/root")]
        ))
        XCTAssertEqual(path.matchedSnapshotIndices, [0])
        XCTAssertEqual(path.visitedSnapshotCount, 2)
        XCTAssertFalse(path.cancelled)

        let suffix = try await client.folderSuffixIndices(.init(
            fragment: "Sources",
            relativePaths: ["Sources", "Nested/Sources", "Tests"]
        ))
        XCTAssertEqual(suffix, [0, 1])
        _ = try await bridge.close()
    }

    func testRealInvalidPatternComplexityAndMatchLimitErrorsMap() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()

        await XCTAssertThrowsErrorAsync(try await client.searchRegex(.init(pattern: "[", subject: "x"))) {
            XCTAssertEqual($0 as? CoreSearchError, .invalidPattern(.unmatchedBrackets))
        }
        await XCTAssertThrowsErrorAsync(try await client.searchRegex(.init(
            pattern: String(repeating: "a", count: 2_001),
            subject: "a"
        ))) {
            XCTAssertEqual($0 as? CoreSearchError, .patternTooComplex)
        }
        await XCTAssertThrowsErrorAsync(try await client.searchRegex(.init(
            pattern: "(?:a+)+$",
            subject: String(repeating: "a", count: 32_768) + "!"
        ))) {
            XCTAssertEqual($0 as? CoreSearchError, .matchLimitExceeded)
        }
        _ = try await bridge.close()
    }

    func testRealCancelBeforeStartAndConcurrentCancelCloseAreIdempotent() throws {
        let (transport, identity) = try realTransport()
        let cancellation = try transport.createLeafCancellation(identity: identity)
        try transport.cancelLeafCancellation(cancellation, identity: identity)
        XCTAssertThrowsError(try transport.searchRegex(
            identity: identity,
            cancellation: cancellation,
            request: .init(pattern: "needle", subject: "needle")
        )) {
            XCTAssertEqual($0 as? CoreTransportError, .searchCancelled)
        }

        let errors = OSAllocatedUnfairLock(initialState: [String]())
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            do {
                if index.isMultiple(of: 2) {
                    try transport.cancelLeafCancellation(cancellation, identity: identity)
                } else {
                    try transport.closeLeafCancellation(cancellation, identity: identity)
                }
            } catch {
                errors.withLock { $0.append(String(describing: error)) }
            }
        }
        XCTAssertEqual(errors.withLock { $0 }, [])
        _ = try transport.beginShutdown(identity: identity)
    }

    func testRealIdentityMismatchIsRejected() throws {
        let (transport, identity) = try realTransport()
        let cancellation = try transport.createLeafCancellation(identity: identity)
        let stale = CoreRuntimeIdentity(
            abiEpoch: identity.abiEpoch,
            instanceNonce: "ffffffffffffffffffffffffffffffff",
            buildFingerprint: identity.buildFingerprint,
            bindingChecksum: identity.bindingChecksum
        )
        XCTAssertThrowsError(try transport.searchRegex(
            identity: stale,
            cancellation: cancellation,
            request: .init(pattern: "x", subject: "x")
        )) {
            XCTAssertEqual($0 as? CoreTransportError, .staleRuntimeIdentity)
        }
        try transport.closeLeafCancellation(cancellation, identity: identity)
        _ = try transport.beginShutdown(identity: identity)
        XCTAssertThrowsError(try transport.cancelLeafCancellation(cancellation, identity: identity)) {
            XCTAssertEqual($0 as? CoreTransportError, .runtimeStopped)
        }
    }

    func testSynchronousSearchDoesNotBlockBridgeActorAndCancellationDropsResult() async throws {
        let transport = FakeCoreTransport()
        transport.blockSearch()
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.searchClient()
        let task = Task {
            try await client.searchRegex(.init(pattern: "x", subject: "x"))
        }
        XCTAssertEqual(transport.searchStarted.wait(timeout: .now() + 2), .success)
        defer { transport.searchRelease.signal() }

        _ = try await bridge.runtimeIdentity()
        task.cancel()
        transport.searchRelease.signal()
        do {
            _ = try await task.value
            XCTFail("cancelled content search must not publish a late result")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(transport.actions.contains("cancel-leaf-cancellation"))
        _ = try await bridge.close()
    }

    func testPoisonInvalidatesBridgeWhileMalformedRangeStaysRequestScoped() async throws {
        let poisonTransport = FakeCoreTransport()
        poisonTransport.failSearch(with: .runtimePoisoned)
        let poisoned = AgentryCoreBridge(transport: poisonTransport)
        try await poisoned.initialize()
        let poisonedClient = try await poisoned.searchClient()
        await XCTAssertThrowsErrorAsync(try await poisonedClient.searchRegex(.init(pattern: "x", subject: "x"))) {
            XCTAssertEqual($0 as? CoreSearchError, .runtimePoisoned)
        }
        await XCTAssertThrowsErrorAsync(try await poisoned.searchClient()) {
            XCTAssertEqual($0 as? CoreBridgeError, .runtimeInvalidated)
        }

        let rangeTransport = FakeCoreTransport()
        rangeTransport.returnSearchResult(.init(
            hits: [.init(
                lineNumber: 0,
                lineByteRange: .init(start: 0, end: 4),
                matchByteRange: .init(start: 1, end: 2),
                contextBeforeByteRanges: [],
                contextAfterByteRanges: []
            )],
            matchingLineCount: 1,
            cancelled: false,
            diagnostic: .init(
                engine: .pcre2,
                jitStatus: .active,
                cacheHit: false,
                repairKind: .none,
                limitPolicy: .fileSearchFullBuffer,
                subjectByteCount: 4,
                lineCount: 1,
                hitCount: 1,
                matchingLineCount: 1,
                cancelled: false,
                limitFailure: nil
            )
        ))
        let ranged = AgentryCoreBridge(transport: rangeTransport)
        try await ranged.initialize()
        let rangeClient = try await ranged.searchClient()
        await XCTAssertThrowsErrorAsync(try await rangeClient.searchRegex(.init(pattern: ".", subject: "🙂"))) {
            XCTAssertEqual($0 as? CoreSearchError, .malformedRange)
        }
        // Policy (hang postmortem 2026-08-22): malformed ranges are
        // request-scoped — the request fails loudly, the runtime stays
        // serviceable. Sticky invalidation is reserved for poison/panic/
        // identity failures (poisoned bridge above).
        _ = try await ranged.searchClient()
        _ = try await ranged.close()
    }

    func testCompactBatchPreservesSubjectAlignmentAndContextArithmetic() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.searchClient()
        let result = try await client.searchRegexBatchCompactV1(.init(
            pattern: "hit",
            subjects: ["a\nhit\nc", "none", "hit\nz"],
            contextLines: 1
        ))
        XCTAssertEqual(result.subjectSummaries.map(\.hitCount), [1, 0, 1])
        XCTAssertEqual(result.subjectSummaries.map(\.lineRangeStart), [0, 3, 3])
        XCTAssertEqual(result.subjectSummaries.map(\.lineRangeCount), [3, 0, 2])
        XCTAssertEqual(result.subjectSummaries.map(\.hitStart), [0, 1, 1])
        XCTAssertEqual(Array(result.hitWords[0 ..< 6]), [1, 1, 2, 5, 1, 1])
        XCTAssertEqual(Array(result.hitWords[6 ..< 12]), [0, 0, 0, 3, 0, 1])
        _ = try await bridge.close()
    }

    func testCompactBatchRejectsMalformedTableStrides() async throws {
        let transport = FakeCoreTransport()
        transport.returnCompactSearchResult(.init(
            subjectSummaries: [compactSummary(subjectByteCount: 1)],
            lineRangeWords: [0],
            hitWords: []
        ))
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.searchClient()
        await XCTAssertThrowsErrorAsync(try await client.searchRegexBatchCompactV1(.init(
            pattern: "x",
            subjects: ["x"]
        ))) {
            XCTAssertEqual($0 as? CoreSearchError, .malformedRange)
        }
        // Request-scoped (hang postmortem 2026-08-22): the runtime survives.
        _ = try await bridge.searchClient()
        _ = try await bridge.close()
    }

    func testCompactBatchRejectsOutOfBoundsSubjectSlices() async throws {
        let transport = FakeCoreTransport()
        transport.returnCompactSearchResult(.init(
            subjectSummaries: [compactSummary(subjectByteCount: 1, lineRangeCount: 1)],
            lineRangeWords: [],
            hitWords: []
        ))
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.searchClient()
        await XCTAssertThrowsErrorAsync(try await client.searchRegexBatchCompactV1(.init(
            pattern: "x",
            subjects: ["x"]
        ))) {
            XCTAssertEqual($0 as? CoreSearchError, .malformedRange)
        }
    }

    func testCompactBatchRejectsInvalidUTF8Boundaries() async throws {
        let transport = FakeCoreTransport()
        transport.returnCompactSearchResult(.init(
            subjectSummaries: [compactSummary(subjectByteCount: 4, lineRangeCount: 1)],
            lineRangeWords: [1, 4],
            hitWords: []
        ))
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.searchClient()
        await XCTAssertThrowsErrorAsync(try await client.searchRegexBatchCompactV1(.init(
            pattern: ".",
            subjects: ["🙂"]
        ))) {
            XCTAssertEqual($0 as? CoreSearchError, .malformedRange)
        }
    }

    func testLateResultAfterShutdownIsDiscarded() async throws {
        let transport = FakeCoreTransport()
        transport.blockSearch()
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.searchClient()
        let task = Task { try await client.searchRegex(.init(pattern: "x", subject: "x")) }
        XCTAssertEqual(transport.searchStarted.wait(timeout: .now() + 2), .success)
        _ = try await bridge.close()
        transport.searchRelease.signal()
        await XCTAssertThrowsErrorAsync(try await task.value) {
            XCTAssertEqual($0 as? CoreSearchError, .runtimeStopped)
        }
    }

    private func compactSummary(
        subjectByteCount: UInt64,
        lineRangeStart: UInt64 = 0,
        lineRangeCount: UInt64 = 0,
        hitStart: UInt64 = 0,
        hitCount: UInt64 = 0,
        matchingLineCount: UInt64 = 0
    ) -> CoreCompactRegexSubjectSummary {
        .init(
            lineRangeStart: lineRangeStart,
            lineRangeCount: lineRangeCount,
            hitStart: hitStart,
            hitCount: hitCount,
            matchingLineCount: matchingLineCount,
            cancelled: false,
            diagnostic: .init(
                engine: .pcre2,
                jitStatus: .active,
                cacheHit: false,
                repairKind: .none,
                limitPolicy: .fileSearchFullBuffer,
                subjectByteCount: subjectByteCount,
                lineCount: lineRangeCount,
                hitCount: hitCount,
                matchingLineCount: matchingLineCount,
                cancelled: false,
                limitFailure: nil
            )
        )
    }

    private func realTransport() throws -> (UniFFICoreRuntimeTransport, CoreRuntimeIdentity) {
        let transport = try UniFFICoreRuntimeTransport(
            configuration: .init(),
            expected: .generated
        )
        return (transport, try transport.initialize().runtimeIdentity)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
