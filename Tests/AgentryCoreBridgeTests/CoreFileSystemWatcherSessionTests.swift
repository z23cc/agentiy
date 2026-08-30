import Foundation
import XCTest
@testable import AgentryCoreBridge

final class CoreFileSystemWatcherSessionTests: XCTestCase {
    func testRustWatcherSessionOwnsWatermarkAndPressureCollapse() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let session = try await CoreFileSystemWatcherSession.open(
            bridge: bridge,
            rootPath: "/tmp/repoprompt-watcher-test",
            maxQueuedRawEntries: 2
        )
        try session.startAccepting()
        XCTAssertEqual(
            try session.ingest([
                CoreFileSystemWatcherEvent(path: "/tmp/repoprompt-watcher-test/.gitignore", flags: 1, eventID: 11)
            ]),
            1
        )
        XCTAssertEqual(
            try session.ingest([
                CoreFileSystemWatcherEvent(path: "/tmp/repoprompt-watcher-test/a.swift", flags: 1, eventID: 12)
            ]),
            2
        )
        XCTAssertEqual(
            try session.ingest([
                CoreFileSystemWatcherEvent(path: "/tmp/repoprompt-watcher-test/b.swift", flags: 1, eventID: 13)
            ]),
            3
        )
        let snapshot = try session.snapshot()
        XCTAssertEqual(snapshot.acceptedHighWatermark, 3)
        XCTAssertTrue(snapshot.hasOverflowRootRescan)
        let payload = try XCTUnwrap(session.takeNext(through: 3))
        XCTAssertEqual(payload.lowestAcceptedWatermark, 1)
        XCTAssertEqual(payload.acceptedHighWatermark, 3)
        guard case let .overflowRootRescan(highestEventID, changedIgnoreAbsolutePaths) = payload.contents else {
            return XCTFail("expected a Rust-owned overflow sentinel")
        }
        XCTAssertEqual(highestEventID, 13)
        XCTAssertEqual(changedIgnoreAbsolutePaths, Set(["/tmp/repoprompt-watcher-test/.gitignore"]))
        XCTAssertNil(try session.takeNext())
        session.close()
    }

    func testWatcherSessionResetRetainsMonotonicFence() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let session = try await CoreFileSystemWatcherSession.open(
            bridge: bridge,
            rootPath: "/tmp/repoprompt-watcher-reset",
            maxQueuedRawEntries: 8
        )
        XCTAssertEqual(
            try session.ingest([
                CoreFileSystemWatcherEvent(path: "/tmp/repoprompt-watcher-reset/a", flags: 1, eventID: 1)
            ]),
            1
        )
        try session.reset()
        XCTAssertEqual(try session.captureWatermark(), 1)
        XCTAssertNil(try session.takeNext())
        XCTAssertThrowsError(try session.ingest([
            CoreFileSystemWatcherEvent(path: "/tmp/repoprompt-watcher-reset/b", flags: 1, eventID: 2)
        ]))
        try session.startAccepting()
        XCTAssertEqual(
            try session.ingest([
                CoreFileSystemWatcherEvent(path: "/tmp/repoprompt-watcher-reset/c", flags: 1, eventID: 3)
            ]),
            2
        )
        session.close()
    }
}
