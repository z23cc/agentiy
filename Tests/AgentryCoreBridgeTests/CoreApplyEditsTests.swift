@testable import AgentryCoreBridge
import Foundation
import XCTest

final class CoreApplyEditsTests: XCTestCase {
    func testRealSingleAndBatchReplaceAllRoundTrip() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let result = try await client.applyEditsBatchV1(.init(subjects: [
            .init(
                pathLabel: "Greeting.swift",
                original: "hello world\n",
                mode: .single(.init(search: "world", replacement: "Swift")),
                verbose: true
            ),
            .init(
                pathLabel: "Animals.txt",
                original: "cat cat\nx\n",
                mode: .batch([
                    .init(search: "cat", replacement: "dog", replaceAll: true),
                    .init(search: "x", replacement: "y")
                ]),
                verbose: true,
                includeToolCardUnifiedDiff: true
            )
        ]))

        XCTAssertEqual(result.subjects.map(\.updatedText), ["hello Swift\n", "dog dog\ny\n"])
        XCTAssertEqual(result.subjects.map(\.status), [.success, .success])
        XCTAssertEqual(result.subjects.map(\.editsApplied), [1, 2])
        XCTAssertNil(result.subjects[0].outcomes)
        XCTAssertEqual(result.subjects[1].outcomes?.map(\.status), [.success, .success])
        XCTAssertFalse(result.subjects[0].byteEdits.isEmpty)
        XCTAssertFalse(result.subjects[1].chunks.isEmpty)
        _ = try await bridge.close()
    }

    func testMalformedApplyReconstructionInvalidatesBridgeFailClosed() async throws {
        let transport = FakeCoreTransport()
        transport.returnApplyEditsResult(applyFixture(updated: "b"))
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.computeClient()

        await XCTAssertThrowsCoreErrorAsync {
            try await client.applyEditsBatchV1(.init(subjects: [
                .init(pathLabel: "x.txt", original: "a", mode: .single(.init(search: "a", replacement: "b")))
            ]))
        } verify: {
            XCTAssertEqual($0 as? CoreComputeError, .malformedResponse)
        }
        await XCTAssertThrowsCoreErrorAsync {
            try await bridge.computeClient()
        } verify: {
            XCTAssertEqual($0 as? CoreBridgeError, .runtimeInvalidated)
        }
    }

    func testDetachedApplyDoesNotBlockActorAndCancellationDropsLateResult() async throws {
        let transport = FakeCoreTransport()
        transport.returnApplyEditsResult(applyFixture(updated: "x"))
        transport.blockCompute()
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.computeClient()
        let task = Task {
            try await client.applyEditsBatchV1(.init(subjects: [
                .init(pathLabel: "x.txt", original: "x", mode: .single(.init(search: "x", replacement: "x")))
            ]))
        }
        XCTAssertEqual(transport.computeStarted.wait(timeout: .now() + 2), .success)
        _ = try await bridge.runtimeIdentity()
        task.cancel()
        transport.computeRelease.signal()

        do {
            _ = try await task.value
            XCTFail("cancelled apply must not publish a late preview")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(transport.actions.contains("cancel-leaf-cancellation"))
        _ = try await bridge.close()
    }

    func testMalformedModeIsRejectedBeforeTransport() async throws {
        let transport = FakeCoreTransport()
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.computeClient()

        await XCTAssertThrowsCoreErrorAsync {
            try await client.applyEditsBatchV1(.init(subjects: [
                .init(pathLabel: "x.txt", original: "x", mode: .batch([]))
            ]))
        } verify: {
            XCTAssertEqual($0 as? CoreComputeError, .invalidRequest("edits array cannot be empty"))
        }
        XCTAssertFalse(transport.actions.contains("apply-edits-compact-v1"))
        _ = try await bridge.close()
    }

    private func applyFixture(updated: String) -> CoreCompactApplyEditsBatchResultV1 {
        .init(
            subjectSummaries: [.init(
                inputByteCount: 1,
                blobStart: 0,
                blobCount: UInt64(updated.utf8.count),
                stringStart: 0,
                stringCount: 1,
                updatedTextStringIndex: 0,
                byteEditStart: 0,
                byteEditCount: 0,
                chunkStart: 0,
                chunkCount: 0,
                diffLineStart: 0,
                diffLineCount: 0,
                outcomeStart: 0,
                outcomeCount: 0,
                editsRequested: 1,
                editsApplied: 1,
                resultStatusTag: 0,
                outcomesPresent: false,
                statsPresent: false,
                linesChanged: 0,
                statsChunkCount: 0,
                noteStringIndex: UInt64.max,
                unifiedDiffStringIndex: UInt64.max,
                toolCardDiffStringIndex: UInt64.max
            )],
            utf8Blob: Data(updated.utf8),
            stringRangeWords: [0, UInt64(updated.utf8.count)],
            byteEditWords: [],
            chunkWords: [],
            diffLineWords: [],
            outcomeWords: []
        )
    }
}
