@testable import RepoPromptApp
import XCTest

/// P4-7b §4.3/§4.5 (phase b2) done-when: "an ASan/TSan-clean soak opening and closing handles
/// across ≥10k generations with no leak and no `retentionBoundary` increase."
///
/// Sanitizer lane ruling (recorded so a future reader does not have to re-derive it): the
/// coordinated daemon (`make dev-test SANITIZE=thread`) *can* run this, but routes it through the
/// shared `build` lane for however long a TSan-instrumented 10k-cycle soak takes, which would
/// block every other coordinated build/test for the duration. This suite is run directly
/// (`swift test --sanitize thread --filter WorkspaceSearchRootQueryHandleLifecycleSoakTests`),
/// mirroring the exact invocation `Scripts/conductor.py`'s own `test` operation builds
/// (`argv.extend(["--sanitize", "thread"])`) -- sanctioned only when no other agent/daemon build is
/// concurrently active in this checkout, per this campaign's operator ruling. Every other build in
/// this campaign stays on coordinated `make dev-*` commands; this file is the sole exception.
///
/// Gated out of default `swift test`/`make dev-test` runs -- a 10k-cycle soak in the default path
/// taxes every future run for a done-when that only needs to be (re-)proven when this handle type
/// or its retention policy changes. Opt in with `RPCE_RUN_HANDLE_RETENTION_SOAK=1`.
final class WorkspaceSearchRootQueryHandleLifecycleSoakTests: XCTestCase {
    private static let soakEnvironmentKey = "RPCE_RUN_HANDLE_RETENTION_SOAK"
    private static let cycleCount = 10000

    private func makeTestDirectory(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Polls `inventoryScopeDiagnosticsForTesting()` until `openHandleCount` settles to `expected`
    /// or `timeoutNanoseconds` elapses. Necessary rather than an immediate assertion:
    /// `CoreInventorySnapshot.deinit` cannot itself `await`, so it spawns a detached `Task` to call
    /// `inventoryCloseSnapshot` -- the handle table's own count can lag the Swift-side deinit by a
    /// scheduling quantum, which is exactly the ARC-driven-close shape §4.5 chose and is not itself
    /// a leak.
    private func waitForOpenHandleCount(
        store: WorkspaceFileContextStore,
        equalTo expected: UInt64,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> UInt64 {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        var last: UInt64 = .max
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard let diagnostics = await store.inventoryScopeDiagnosticsForTesting() else { break }
            last = diagnostics.openHandleCount
            if last == expected { return last }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return last
    }

    func testTenThousandOpenCloseCyclesLeaveNoOpenHandlesAndNoRetentionBoundaryFallback() async throws {
        guard ProcessInfo.processInfo.environment[Self.soakEnvironmentKey] == "1" else {
            throw XCTSkip("Set \(Self.soakEnvironmentKey)=1 to run the \(Self.cycleCount)-cycle handle-lifecycle soak directly (see this file's header doc).")
        }

        let store = WorkspaceFileContextStore()
        let root = try makeTestDirectory(name: "HandleLifecycleSoak")
        try write("seed", to: root.appendingPathComponent("Sources/Seed.swift"))
        try write("other", to: root.appendingPathComponent("Sources/Other.swift"))
        let record = try await store.loadRoot(path: root.path)

        let baselineDiagnostics = try await waitForOpenHandleCount(store: store, equalTo: 0)
        XCTAssertEqual(baselineDiagnostics, 0, "expected no open handles before the soak begins")

        // Open-then-swap-then-close (§4.5 item 2): each cycle opens a fresh handle set, uses it,
        // and only then lets the previous cycle's set go out of scope -- never a window with zero
        // ready handles while one is expected. `handles` is reassigned, not explicitly closed;
        // ARC drops the superseded value's last reference at the reassignment itself.
        var handles = await store.searchRootQueryHandles(rootScope: .visibleWorkspace)
        XCTAssertNotNil(handles, "expected the first cycle to open successfully")

        for cycle in 0 ..< Self.cycleCount {
            let next = await store.searchRootQueryHandles(rootScope: .visibleWorkspace)
            guard let next else {
                return XCTFail("cycle \(cycle): expected searchRootQueryHandles to open against a still-loaded root")
            }
            if let handle = next.handle(rootID: record.id) {
                // Touch the handle so this is a real open-and-use cycle, not merely an allocation
                // benchmark -- a query per cycle is representative of what a search actor would do
                // with it.
                _ = try? await handle.snapshot.query(
                    pattern: "Seed",
                    limit: 10,
                    haystackVariant: .indexKey,
                    nonEmptyRelativePrefix: "",
                    emptyRelativePathValue: ""
                )
            }
            handles = next
        }
        handles = nil

        let finalOpenHandleCount = try await waitForOpenHandleCount(store: store, equalTo: 0)
        XCTAssertEqual(
            finalOpenHandleCount, 0,
            "expected every soak-opened handle to close after its holder was dropped -- a non-zero count here is a leak"
        )

        let diagnostics = await store.storeWorkDiagnosticsSnapshot()
        let shard = try XCTUnwrap(diagnostics.rootCatalogShards.roots.first { $0.rootID == record.id })
        XCTAssertEqual(
            shard.fallbackReasonCounts[.retentionBoundary] ?? 0, 0,
            "the soak's open-then-swap shape (\u{2264}2 live handle sets at any instant) must never trip retention pressure against cap=8"
        )
    }

    /// Same shape, concurrent: `withTaskGroup` fans out overlapping open/use/drop cycles so a TSan
    /// run has genuine concurrent handle table access to find a race in, not just a serial soak
    /// TSan would accept trivially.
    func testConcurrentOpenCloseCyclesAreDataRaceFree() async throws {
        guard ProcessInfo.processInfo.environment[Self.soakEnvironmentKey] == "1" else {
            throw XCTSkip("Set \(Self.soakEnvironmentKey)=1 to run the concurrent handle-lifecycle soak directly (see this file's header doc).")
        }

        let store = WorkspaceFileContextStore()
        let root = try makeTestDirectory(name: "HandleLifecycleSoakConcurrent")
        try write("seed", to: root.appendingPathComponent("Sources/Seed.swift"))
        _ = try await store.loadRoot(path: root.path)

        let concurrentCycleCount = 2000
        let taskCount = 8
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< taskCount {
                group.addTask {
                    for _ in 0 ..< (concurrentCycleCount / taskCount) {
                        guard let handles = await store.searchRootQueryHandles(rootScope: .visibleWorkspace) else { continue }
                        for handle in handles.perRoot {
                            _ = try? await handle.snapshot.query(
                                pattern: "Seed",
                                limit: 10,
                                haystackVariant: .indexKey,
                                nonEmptyRelativePrefix: "",
                                emptyRelativePathValue: ""
                            )
                        }
                    }
                }
            }
        }

        let finalOpenHandleCount = try await waitForOpenHandleCount(store: store, equalTo: 0)
        XCTAssertEqual(finalOpenHandleCount, 0, "expected every concurrently-opened handle to close once its task's local reference dropped")
    }
}
