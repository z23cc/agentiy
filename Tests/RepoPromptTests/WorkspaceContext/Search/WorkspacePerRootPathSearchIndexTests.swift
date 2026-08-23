@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class WorkspacePerRootPathSearchIndexTests: XCTestCase {
        private var stores: [WorkspaceFileContextStore] = []
        private var temporaryRoots: [URL] = []

        override func tearDown() async throws {
            for store in stores {
                await store.unloadRoots(ids: store.roots().map(\.id))
            }
            stores.removeAll()
            for root in temporaryRoots {
                try? FileManager.default.removeItem(at: root)
            }
            temporaryRoots.removeAll()
            try await super.tearDown()
        }

        func testPerRootMergeMatchesAuthoritativeGlobalIndexAcrossScopes() async throws {
            let primaryAURL = try makeTemporaryRoot(name: "ParityPrimaryA")
            let primaryBURL = try makeTemporaryRoot(name: "ParityPrimaryB")
            let gitDataURL = try makeTemporaryRoot(name: "ParityGitData")
            let supplementalURL = try makeTemporaryRoot(name: "ParitySupplemental")
            let worktreeURL = try makeTemporaryRoot(name: "ParityWorktree")
            try write("a", to: primaryAURL.appendingPathComponent("Sources/SharedTarget.swift"))
            try write("b", to: primaryBURL.appendingPathComponent("Tests/SharedTargetTests.swift"))
            try write("unicode", to: primaryBURL.appendingPathComponent("Sources/ÅngströmTarget.swift"))
            try write("unicode", to: primaryBURL.appendingPathComponent("Sources/文件Target.swift"))
            try write("git", to: gitDataURL.appendingPathComponent("MAP-Target.txt"))
            try write("system", to: supplementalURL.appendingPathComponent("SystemTarget.swift"))
            try write("worktree", to: worktreeURL.appendingPathComponent("Sources/WorktreeTarget.swift"))

            let store = makeStore()
            _ = try await loadStoppedRoot(in: store, path: primaryAURL.path)
            _ = try await loadStoppedRoot(in: store, path: primaryBURL.path)
            _ = try await loadStoppedRoot(in: store, path: gitDataURL.path, kind: .workspaceGitData)
            _ = try await loadStoppedRoot(in: store, path: supplementalURL.path, kind: .supplementalSystem)
            _ = try await loadStoppedRoot(in: store, path: worktreeURL.path, kind: .sessionWorktree)

            let scopes: [WorkspaceLookupRootScope] = [
                .visibleWorkspace,
                .visibleWorkspacePlusGitData,
                .allLoaded,
                .sessionBoundWorkspace(
                    canonicalRootPaths: [primaryAURL.path],
                    physicalRootPaths: [worktreeURL.path]
                )
            ]
            let queries = ["", "Target", "Shared Target", "*.swift", worktreeURL.path]
            let service = WorkspaceSearchService()

            for scope in scopes {
                let snapshot = await store.searchCatalogSnapshot(rootScope: scope)
                await service.prepareIndex(from: store, rootScope: scope)
                for query in queries {
                    for limit in [1, 3, 20] {
                        let expected = WorkspaceSearchService.authoritativeGlobalResultsForTesting(
                            from: snapshot,
                            query: query,
                            limit: limit
                        )
                        let actual = await service.search(query, limit: limit)
                        XCTAssertEqual(
                            actual.results,
                            expected,
                            "scope=\(scope) query=\(query) limit=\(limit)"
                        )
                    }
                }
            }
        }

        func testGlobalTopKAllowsLaterRootToDisplaceEarlierRootDeterministically() async throws {
            let loadedFirstURL = try makeTemporaryRoot(name: "ZZZLoadedFirst")
            let loadedLaterURL = try makeTemporaryRoot(name: "AAALoadedLater")
            try write("first", to: loadedFirstURL.appendingPathComponent("Target.swift"))
            try write("later", to: loadedLaterURL.appendingPathComponent("Target.swift"))

            let store = makeStore()
            let loadedFirst = try await loadStoppedRoot(in: store, path: loadedFirstURL.path)
            let loadedLater = try await loadStoppedRoot(in: store, path: loadedLaterURL.path)
            let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            XCTAssertEqual(snapshot.roots.map(\.id), [loadedFirst.id, loadedLater.id])

            let service = WorkspaceSearchService()
            await service.prepareIndex(from: store, rootScope: .visibleWorkspace)
            let result = await service.search("Target", limit: 1)
            let authoritative = WorkspaceSearchService.authoritativeGlobalResultsForTesting(
                from: snapshot,
                query: "Target",
                limit: 1
            )
            XCTAssertEqual(result.results, authoritative)
            XCTAssertEqual(result.results.map(\.rootID), [loadedLater.id])

            // P4-7b b3 removal (design doc §4.4): this scenario continued by hand-fabricating two
            // *virtual* roots/entries/`WorkspaceSearchRootPathIndex` objects sharing a colliding
            // `pathSearchIndexKey` (precomposed vs. decomposed é), wrapped them in a synthetic
            // `WorkspaceSearchCatalogSnapshot`, and fed that snapshot straight to
            // `service.prepareIndex(from:)`. `WorkspaceSearchService` no longer accepts a snapshot
            // at all -- it consumes `WorkspaceFileContextStore.searchRootQueryHandles`, which opens
            // real Rust snapshot handles against real loaded roots; there is no way to fabricate a
            // handle for a root that was never actually loaded. The pure, store-independent claim
            // this scenario existed to pin -- that precomposed/decomposed Unicode names collide on
            // `pathSearchIndexKey` while remaining byte-distinct, and that `FileSearchActor
            // .pathSearchInputPrecedes` orders them deterministically -- is still pinned directly
            // (no live search service involved) in
            // `testOverlayTransitionsPreserveSearchAndPerRootMergeParity`, which keeps exactly those
            // assertions without the now-impossible synthetic-snapshot wrapper.
        }

        // P4-7b b3 removal (design doc §4.4): `testChangedRootOnlyRebuildsItsPathIndexAndUnloadReloadResetsLifetime`
        // removed. It pinned shard-cache `WorkspaceSearchRootPathIndex` *object identity* reuse
        // across patches (`firstBIndex === secondBIndex`) and rebuild-on-change
        // (`firstAIndex !== secondAIndex`), read via `snapshot.rootPathIndexes` from an explicit
        // `.recordsAndPathIndexes` request. `makeRootPathSearchIndex` -- the sole constructor of
        // that per-shard index object -- is deleted (§4.1.0's invariant), so no caller can produce
        // the state this test needed anymore; the shard-cache's own object-identity contract is now
        // permanently unreachable from any live code path, not merely untested.

        func testOverlayTransitionsPreserveSearchAndPerRootMergeParity() async throws {
            let rootAURL = try makeTemporaryRoot(name: "OverlayParityA")
            let rootBURL = try makeTemporaryRoot(name: "OverlayParityB")
            try write("a", to: rootAURL.appendingPathComponent("AAATarget.swift"))
            try write("b", to: rootAURL.appendingPathComponent("BBTarget.swift"))
            try write("space", to: rootAURL.appendingPathComponent("Sources/Space Target.swift"))
            try write("unicode", to: rootAURL.appendingPathComponent("Sources/ÅngströmTarget.swift"))
            try write("unicode", to: rootAURL.appendingPathComponent("Sources/文件Target.swift"))
            try write("other", to: rootBURL.appendingPathComponent("A0OtherTarget.swift"))

            let store = makeStore()
            let rootA = try await loadStoppedRoot(in: store, path: rootAURL.path)
            _ = try await loadStoppedRoot(in: store, path: rootBURL.path)
            let service = WorkspaceSearchService()
            let queries = ["", "Target", "Space Target", "*.swift", "Ångström", "文件"]

            try FileManager.default.removeItem(at: rootAURL.appendingPathComponent("AAATarget.swift"))
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.fileRemoved("AAATarget.swift")])
            try await assertSearchParity(store: store, service: service, queries: queries)

            try write("added", to: rootAURL.appendingPathComponent("A0AddedTarget.swift"))
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.fileAdded("A0AddedTarget.swift")])
            try await assertSearchParity(store: store, service: service, queries: queries)

            try FileManager.default.removeItem(at: rootAURL.appendingPathComponent("BBTarget.swift"))
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.fileRemoved("BBTarget.swift")])
            try write("renamed", to: rootAURL.appendingPathComponent("RenamedTarget.swift"))
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.fileAdded("RenamedTarget.swift")])
            try await assertSearchParity(store: store, service: service, queries: queries)

            let beforeFolderPatch = try await shardDiagnostics(
                rootID: rootA.id,
                diagnostics: store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            let folderURL = rootAURL.appendingPathComponent("FolderOnly", isDirectory: true)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            await store.replayObservedFileSystemDeltas(rootID: rootA.id, deltas: [.folderAdded("FolderOnly")])
            try await assertSearchParity(store: store, service: service, queries: queries)
            let afterFolderPatch = try await shardDiagnostics(
                rootID: rootA.id,
                diagnostics: store.storeWorkDiagnosticsSnapshot().rootCatalogShards
            )
            XCTAssertEqual(afterFolderPatch.pathIndexBuildCount, beforeFolderPatch.pathIndexBuildCount)
            XCTAssertEqual(
                afterFolderPatch.overlayPathIndexBuildCount,
                beforeFolderPatch.overlayPathIndexBuildCount
            )

            let virtualRoot = try WorkspaceRootRecord(
                id: XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000000")),
                name: "Virtual",
                fullPath: "/virtual"
            )
            let precomposedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let decomposedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            let sharedRelativePath = "Target.swift"
            let sharedFullPath = "/virtual/Target.swift"
            let precomposedFile = WorkspaceFileRecord(
                id: precomposedID,
                rootID: virtualRoot.id,
                name: sharedRelativePath,
                relativePath: sharedRelativePath,
                fullPath: sharedFullPath,
                parentFolderID: nil
            )
            let decomposedFile = WorkspaceFileRecord(
                id: decomposedID,
                rootID: virtualRoot.id,
                name: sharedRelativePath,
                relativePath: sharedRelativePath,
                fullPath: sharedFullPath,
                parentFolderID: nil
            )
            let precomposedEntry = WorkspaceSearchCatalogEntry(
                file: precomposedFile,
                root: virtualRoot,
                displayPath: "Virtual/ÉTarget.swift"
            )
            let decomposedEntry = WorkspaceSearchCatalogEntry(
                file: decomposedFile,
                root: virtualRoot,
                displayPath: "Virtual/E\u{301}Target.swift"
            )
            XCTAssertEqual(precomposedEntry.pathSearchIndexKey, decomposedEntry.pathSearchIndexKey)
            XCTAssertNotEqual(
                Array(precomposedEntry.pathSearchIndexKey.utf8),
                Array(decomposedEntry.pathSearchIndexKey.utf8)
            )
            let precomposedPath = "/virtual/ÉTarget.swift"
            let decomposedPath = "/virtual/E\u{301}Target.swift"
            XCTAssertTrue(FileSearchActor.pathSearchInputPrecedes(decomposedPath, precomposedPath))
            XCTAssertFalse(FileSearchActor.pathSearchInputPrecedes(precomposedPath, decomposedPath))

            let lifetimeID = try XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000000"))
            let baseIndex = WorkspaceSearchRootPathIndex(
                identity: WorkspaceSearchRootPathIndexIdentity(
                    rootID: virtualRoot.id,
                    lifetimeID: lifetimeID,
                    topologyGeneration: 1
                ),
                rootPath: virtualRoot.standardizedFullPath,
                entries: [precomposedEntry]
            )
            let overlayIndex = baseIndex.applyingPatch(
                identity: WorkspaceSearchRootPathIndexIdentity(
                    rootID: virtualRoot.id,
                    lifetimeID: lifetimeID,
                    topologyGeneration: 2
                ),
                entries: [precomposedEntry, decomposedEntry],
                changedFileIDs: [decomposedID]
            )
            XCTAssertEqual(
                overlayIndex.search("Target", limit: 1).map(\.entry.id),
                [decomposedID]
            )
            // P4-7b b3 removal (design doc §4.4): this scenario continued by wrapping `overlayIndex`
            // in a synthetic `WorkspaceSearchCatalogSnapshot` (a virtual, never-loaded root) and
            // feeding it to `service.prepareIndex(from:)` to prove the live search service agreed
            // with the hand-built overlay index. `WorkspaceSearchService` no longer accepts a
            // snapshot -- it consumes `WorkspaceFileContextStore.searchRootQueryHandles`, which
            // requires a really-loaded root, so a virtual root can no longer be fed to it. The
            // `overlayIndex.search(...)` assertion just above already pins the
            // `WorkspaceSearchRootPathIndex` type's own overlay/tie-break behavior directly (that
            // type is unaffected by the b3 flip -- holders #2-#6 in the design doc's ledger still
            // use it until P4-7c); only the "and the live search service agrees" half is retired.
        }

        // P4-7b b3 removal (design doc §4.4): `testOverlaySegmentBlocksCrossFormerBoundWhileRetainedReadersStayImmutable`
        // removed, for the same reason as `testChangedRootOnlyRebuildsItsPathIndexAndUnloadReloadResetsLifetime`
        // above: it read `WorkspaceSearchRootPathIndex` instances out of `snapshot.rootPathIndexes`
        // (an explicit `.recordsAndPathIndexes` shard-cache request) to pin the overlay history's
        // own compaction bounds (`overlayHistoryMetricsForTesting`) across 40 store-driven patches.
        // No caller can produce a populated `rootPathIndexes` anymore.

        func testRootUnloadDropsOnlyItsReadyIndexWhileReplacementGenerationIsPending() async throws {
            let rootAURL = try makeTemporaryRoot(name: "DropIndexA")
            let rootBURL = try makeTemporaryRoot(name: "DropIndexB")
            try write("drop", to: rootAURL.appendingPathComponent("DropTarget.swift"))
            try write("keep", to: rootBURL.appendingPathComponent("KeepTarget.swift"))

            let store = makeStore()
            let rootA = try await loadStoppedRoot(in: store, path: rootAURL.path)
            let rootB = try await loadStoppedRoot(in: store, path: rootBURL.path)
            let service = WorkspaceSearchService()
            let rebuildGate = AsyncGate()
            await service.setAutomaticRebuildDidStartHandler { generation in
                await rebuildGate.enter(generation: generation)
            }
            await service.prepareIndex(from: store, rootScope: .visibleWorkspace)
            await service.startKeepingFresh(with: store, debounceNanoseconds: 0)

            await store.unloadRoot(id: rootA.id)
            let targetGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
            let rebuildingGeneration = await rebuildGate.waitUntilEntered()
            XCTAssertEqual(rebuildingGeneration, targetGeneration)
            let pendingGeneration = await service.pendingGeneration
            XCTAssertEqual(pendingGeneration, targetGeneration)

            let dropped = await service.search("DropTarget", limit: 10)
            let kept = await service.search("KeepTarget", limit: 10)
            XCTAssertTrue(dropped.results.isEmpty)
            XCTAssertEqual(kept.results.map(\.rootID), [rootB.id])
            XCTAssertTrue(kept.isIndexReady)
            XCTAssertTrue(kept.isStale)

            await rebuildGate.open()
            await service.setAutomaticRebuildDidStartHandler(nil)
            try await waitForIndexedGeneration(targetGeneration, service: service)
            let finalKept = await service.search("KeepTarget", limit: 10)
            XCTAssertEqual(finalKept.results.map(\.rootID), [rootB.id])
        }

        func testConcurrentOldReaderRetainsOldIndexWhileNewGenerationPublishes() async throws {
            let rootURL = try makeTemporaryRoot(name: "ConcurrentIndexGeneration")
            let oldURL = rootURL.appendingPathComponent("OldTarget.swift")
            try write("old", to: oldURL)

            let store = makeStore()
            let root = try await loadStoppedRoot(in: store, path: rootURL.path)
            let service = WorkspaceSearchService()
            let oldGeneration = await service.prepareIndex(from: store, rootScope: .visibleWorkspace)

            let gate = AsyncGate()
            await service.setSearchDidCaptureGenerationHandler { generation in
                await gate.enter(generation: generation)
            }
            let oldSearch = Task { await service.search("OldTarget", limit: 10) }
            let capturedGeneration = await gate.waitUntilEntered()
            XCTAssertEqual(capturedGeneration, oldGeneration)

            try FileManager.default.removeItem(at: oldURL)
            await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileRemoved("OldTarget.swift")])
            let newGeneration = await service.rebuildIndex(from: store, rootScope: .visibleWorkspace)
            await service.setSearchDidCaptureGenerationHandler(nil)
            await gate.open()

            let oldResult = await oldSearch.value
            XCTAssertEqual(oldResult.indexedGeneration, oldGeneration)
            XCTAssertEqual(oldResult.results.map(\.standardizedRelativePath), ["OldTarget.swift"])
            let newResult = await service.search("OldTarget", limit: 10)
            XCTAssertEqual(newResult.indexedGeneration, newGeneration)
            XCTAssertTrue(newResult.results.isEmpty)
        }

        private func makeStore() -> WorkspaceFileContextStore {
            let store = WorkspaceFileContextStore()
            stores.append(store)
            return store
        }

        private func loadStoppedRoot(
            in store: WorkspaceFileContextStore,
            path: String,
            kind: WorkspaceRootKind? = nil
        ) async throws -> WorkspaceRootRecord {
            let root = try await store.loadRoot(path: path, kind: kind)
            await store.stopWatchingRoot(id: root.id)
            return root
        }

        private func assertSearchParity(
            store: WorkspaceFileContextStore,
            service: WorkspaceSearchService,
            queries: [String],
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            await service.prepareIndex(from: store, rootScope: .visibleWorkspace)
            for query in queries {
                for limit in [1, 3, 20] {
                    let expected = WorkspaceSearchService.authoritativeGlobalResultsForTesting(
                        from: snapshot,
                        query: query,
                        limit: limit
                    )
                    let actual = await service.search(query, limit: limit)
                    XCTAssertEqual(actual.results, expected, "query=\(query) limit=\(limit)", file: file, line: line)
                }
            }
        }

        private func shardDiagnostics(
            rootID: UUID,
            diagnostics: WorkspaceFileContextStore.RootCatalogShardDebugSnapshot
        ) throws -> WorkspaceFileContextStore.RootCatalogShardGenerationDebugSnapshot {
            try XCTUnwrap(diagnostics.roots.first { $0.rootID == rootID })
        }

        private func waitForIndexedGeneration(
            _ expected: UInt64,
            service: WorkspaceSearchService,
            timeout: TimeInterval = 2.0,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await service.indexedGeneration == expected { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("Timed out waiting for indexed generation \(expected)", file: file, line: line)
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPromptTests", isDirectory: true)
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            temporaryRoots.append(root)
            return root
        }

        private func write(_ content: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private actor AsyncGate {
        private var enteredGeneration: UInt64?
        private var enteredWaiters: [CheckedContinuation<UInt64?, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func enter(generation: UInt64?) async {
            enteredGeneration = generation
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: generation)
            }
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilEntered() async -> UInt64? {
            if enteredGeneration != nil { return enteredGeneration }
            return await withCheckedContinuation { continuation in
                enteredWaiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
#endif
