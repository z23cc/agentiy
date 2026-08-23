import Foundation
@testable import RepoPromptApp
import XCTest

// P4-6b republication arming (design doc §4.3). `WorkspaceFileContextStore` constructs
// `WorkspaceInventoryScopeRepublicationAdapter`, subscribes it to
// `WorkspaceInventoryScopeAuthority.events()`, and merges its output onto
// `republishedInventoryScopeEvents()` -- a stream separate from the production
// `appliedIndexEvents()` two real consumers subscribe to (see
// `WorkspaceFileContextStore.startInventoryScopeRepublicationTaskIfNeeded`'s header comment for
// why the source flip itself is a follow-on, not part of this commit). This file's only job is
// to prove the armed wiring actually runs end-to-end against a live mutation, not just compiles.
#if DEBUG
    final class WorkspaceInventoryScopeRepublicationArmingTests: XCTestCase {
        private var stores: [WorkspaceFileContextStore] = []
        private var temporaryRoots: [URL] = []

        override func tearDown() async throws {
            for store in stores {
                let rootIDs = await store.roots().map(\.id)
                await store.unloadRoots(ids: rootIDs)
            }
            stores.removeAll()
            for root in temporaryRoots {
                try? FileManager.default.removeItem(at: root)
            }
            temporaryRoots.removeAll()
            try await super.tearDown()
        }

        /// Drives a real file-add mutation through the normal watcher/synthetic-delta path (the
        /// same production path `publishAppliedIndexEvent`'s callers use), and asserts the armed
        /// republication path independently observes it: a matching root ID, an upserted file
        /// naming the new path, a non-degenerate (> 0) Rust-sourced generation, and -- documenting
        /// the known, deliberate gap rather than silently relying on it --
        /// `modifiedFileSourceSnapshotsByID` empty even though this is an add, not a modify (the
        /// merge that would populate it for a genuine modify is not wired yet; see this file's
        /// header comment).
        func testArmedRepublicationPathObservesARealFileAddIndependentlyOfTheProductionStream() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationArmingAdd")
            try write("a", to: root.appendingPathComponent("App.swift"))
            let store = makeStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)

            let republishedStream = await store.republishedInventoryScopeEvents()
            let collector = RepublishedEventCollector()
            let collectorTask = Task { await collector.run(republishedStream) }

            let addedURL = root.appendingPathComponent("Added.swift")
            try write("added", to: addedURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: record.id, deltas: [.fileAdded("Added.swift")])
            _ = await store.flushPendingServiceEventsForAllRoots()

            let events = await collector.waitForAtLeast(1, timeoutSeconds: 10)
            collectorTask.cancel()

            let addedEvent = try XCTUnwrap(
                events.last { $0.upsertedFiles.contains { $0.name == "Added.swift" } },
                "the armed republication path never observed a republished event naming Added.swift among \(events)"
            )
            XCTAssertEqual(addedEvent.rootID, record.id)
            XCTAssertFalse(addedEvent.isRootUnload)
            XCTAssertGreaterThan(addedEvent.generation, 0, "a real delta's republished generation must be a genuine, non-degenerate value")
            XCTAssertTrue(
                addedEvent.modifiedFileSourceSnapshotsByID.isEmpty,
                "documents the known gap: this path never populates modifiedFileSourceSnapshotsByID (see this file's header comment)"
            )
        }

        // MARK: - Helpers

        private func makeStore() -> WorkspaceFileContextStore {
            let store = WorkspaceFileContextStore()
            stores.append(store)
            return store
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPrompt-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            temporaryRoots.append(url)
            return url
        }

        private func write(_ content: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Minimal single-writer collector over `republishedInventoryScopeEvents()`. Deliberately
    /// polls with a bounded deadline rather than waiting on a continuation/task-group -- matching
    /// `CoreInventoryScopeEventCollector` (`CoreInventoryScopeEventsTests.swift`)'s own doc
    /// comment on why: a genuine delivery problem on this event-stream surface (wake-pipe race,
    /// actor deadlock) must fail the test fast and legibly via the deadline, not hang the whole
    /// run indefinitely the way an unresolved continuation would.
    private actor RepublishedEventCollector {
        private var events: [WorkspaceAppliedIndexBatchEvent] = []

        func run(_ stream: AsyncStream<WorkspaceAppliedIndexBatchEvent>) async {
            for await event in stream {
                events.append(event)
            }
        }

        func waitForAtLeast(_ count: Int, timeoutSeconds: Double) async -> [WorkspaceAppliedIndexBatchEvent] {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while events.count < count, Date() < deadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return events
        }
    }
#endif
