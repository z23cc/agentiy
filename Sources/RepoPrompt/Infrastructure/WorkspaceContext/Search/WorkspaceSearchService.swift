import AgentryCoreBridge
import Foundation

/// Actor-owned workspace path-search facade.
///
/// P4-7b b3 (design doc `docs/designs/p4-7-pathsearch-production-cutover-v2-2026-08-23.md` §4.4):
/// the flip. This actor no longer builds or holds a Swift C `PathSearchIndex` over Rust-owned
/// tables -- searches issue `inventoryQuery(.indexKey)` against Rust snapshot handles the store
/// vends (`WorkspaceFileContextStore.searchRootQueryHandles(rootScope:)`), and the empty query
/// pages `generation.files` directly (`inventorySnapshotPage`, §4.2.1). The cross-root merge stays
/// in Swift, unchanged: `WorkspaceInventoryOrdering.compareUTF8Binary(tieBreakKey)` -- score is
/// always `1` on both engines, so the tie-break key alone carries the ordering (§1.5 Check A) --
/// then `WorkspaceInventoryOrdering.searchCatalogEntryPrecedes` as the final tiebreak.
///
/// `readyHandles` retains `WorkspaceSearchRootQueryHandles`, not per-root index objects.
/// Hold-per-generation is the chosen retention policy (§4.5): at most one *ready* handle set plus
/// at most one *in-flight* set during a rebuild are ever retained, and `commit(_:)` always
/// open-then-swaps -- the replacement set is fully built before the superseded set's last
/// reference is dropped, so there is never a window where a concurrent `search(...)` finds no
/// handle. Closing is ARC-driven (`CoreInventorySnapshot`'s own `deinit`); there is no explicit
/// close call anywhere in this actor.
///
/// `currentIndexedGeneration`/`currentSnapshotGeneration` remain keyed off the Swift scope
/// generation the store computes (`scopedSnapshotGeneration`), never off any Rust generation
/// (§1.5 Check B) -- this actor never reads a Rust generation for staleness purposes.
actor WorkspaceSearchService {
    private struct PreparedIndex {
        let generation: UInt64
        let diagnostics: WorkspaceCatalogDiagnostics
        let handles: WorkspaceSearchRootQueryHandles
        #if DEBUG
            let totalMicroseconds: UInt64
        #endif
    }

    /// One reconstructed candidate: the entry plus the subject text that ordered it, so the merge
    /// comparator below is byte-identical in shape to the pre-flip `WorkspaceSearchRootPathIndex
    /// .Candidate`-based merge (`candidatePrecedes`/`entryPrecedes`).
    private struct RankedCandidate {
        let entry: WorkspaceSearchCatalogEntry
        let tieBreakKey: String
    }

    private struct RankedCandidateCursor {
        let rootIndex: Int
        let candidateIndex: Int
    }

    private struct EntryCursor {
        let rootIndex: Int
        let entryIndex: Int
    }

    private var readyHandles = WorkspaceSearchRootQueryHandles(scopeGeneration: 0, perRoot: [])
    private var currentSnapshotGeneration: UInt64?
    private var currentIndexedGeneration: UInt64?
    private var currentDiagnostics: WorkspaceCatalogDiagnostics?
    private var latestObservedCatalogGeneration: UInt64?
    private var pendingRebuildGeneration: UInt64?
    private var activeRebuildGeneration: UInt64?
    private var rebuildSerial: UInt64 = 0
    private var appliedIndexListenerTask: Task<Void, Never>?
    private var pendingRebuildTask: Task<Void, Never>?
    private var automaticIndexBuildDelayNanoseconds: UInt64
    private var discardedAutomaticRebuildCompletions = 0
    private var isReadyIndexUsable = true
    /// §4.6: retained so a query-time failure inside `search(...)` can self-trigger a rebuild
    /// without every caller threading a store reference through `search(...)` itself. Matches the
    /// strong retention `appliedIndexListenerTask`'s own closure already performs for the
    /// lifetime of `startKeepingFresh`/`stopKeepingFresh` -- this does not add a new retention
    /// shape, it makes an existing one available to one more method.
    private var retainedStore: WorkspaceFileContextStore?
    private var retainedRootScope: WorkspaceLookupRootScope = .visibleWorkspace
    #if DEBUG
        struct RebuildWorkDiagnosticsSnapshot: Equatable {
            let rebuildCount: Int
            let orderMicroseconds: UInt64
            let materializationMicroseconds: UInt64
            let cIndexBuildMicroseconds: UInt64
            let totalMicroseconds: UInt64
            let debounceCancellationCount: Int
            let staleDiscardedCount: Int
            let lastEntryCount: Int
        }

        private var debugRebuildCount = 0
        private var debugTotalMicroseconds: UInt64 = 0
        private var debugDebounceCancellationCount = 0
        private var debugLastEntryCount = 0
        /// §4.6: queries that failed with a handle-invalidation or transport/decode error, counted
        /// so a caller-side diagnostic can distinguish "no matches" from "search degraded."
        private(set) var discardedQueryErrorCount = 0
        private var searchDidCaptureGenerationHandler: (@Sendable (UInt64?) async -> Void)?
        private var automaticRebuildDidStartHandler: (@Sendable (UInt64) async -> Void)?
    #endif

    init(automaticIndexBuildDelayNanoseconds: UInt64 = 0) {
        self.automaticIndexBuildDelayNanoseconds = automaticIndexBuildDelayNanoseconds
    }

    deinit {
        appliedIndexListenerTask?.cancel()
        pendingRebuildTask?.cancel()
    }

    var indexedGeneration: UInt64? {
        currentIndexedGeneration
    }

    var snapshotGeneration: UInt64? {
        currentSnapshotGeneration
    }

    var diagnostics: WorkspaceCatalogDiagnostics? {
        currentDiagnostics
    }

    var indexedPathCount: Int {
        currentDiagnostics?.fileCount ?? 0
    }

    var pendingGeneration: UInt64? {
        pendingRebuildGeneration ?? activeRebuildGeneration
    }

    var observedCatalogGeneration: UInt64? {
        latestObservedCatalogGeneration
    }

    var discardedStaleRebuildCount: Int {
        discardedAutomaticRebuildCompletions
    }

    #if DEBUG
        func workDiagnosticsSnapshot() -> RebuildWorkDiagnosticsSnapshot {
            RebuildWorkDiagnosticsSnapshot(
                rebuildCount: debugRebuildCount,
                orderMicroseconds: 0,
                materializationMicroseconds: 0,
                cIndexBuildMicroseconds: 0,
                totalMicroseconds: debugTotalMicroseconds,
                debounceCancellationCount: debugDebounceCancellationCount,
                staleDiscardedCount: discardedAutomaticRebuildCompletions,
                lastEntryCount: debugLastEntryCount
            )
        }

        func setSearchDidCaptureGenerationHandler(
            _ handler: (@Sendable (UInt64?) async -> Void)?
        ) {
            searchDidCaptureGenerationHandler = handler
        }

        func setAutomaticRebuildDidStartHandler(
            _ handler: (@Sendable (UInt64) async -> Void)?
        ) {
            automaticRebuildDidStartHandler = handler
        }

        // P4-7c c3: `authoritativeGlobalResultsForTesting` deleted -- it was the last Swift
        // `PathSearchIndex` construction site reachable through this file (design doc §6.1's
        // zero-reference-proof named it as this slice's deletion target). No replacement seam was
        // added: its only callers (`WorkspacePerRootPathSearchIndexTests`,
        // `WorkspaceSearchRustIndexKeyDifferentialTests`) are deleted in the same commit, and no
        // production caller ever used it. `orderEntries` (its sole helper) is deleted alongside it,
        // below.
    #endif

    func startKeepingFresh(
        with store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        debounceNanoseconds: UInt64 = 50_000_000
    ) async {
        appliedIndexListenerTask?.cancel()
        retainedStore = store
        retainedRootScope = rootScope
        let stream = await store.appliedIndexEvents()
        appliedIndexListenerTask = Task { [weak self, store] in
            for await event in stream {
                await self?.handleAppliedIndexEvent(
                    event,
                    store: store,
                    rootScope: rootScope,
                    debounceNanoseconds: debounceNanoseconds
                )
            }
        }

        let catalogGeneration = await store.catalogGeneration(rootScope: rootScope)
        latestObservedCatalogGeneration = catalogGeneration
        if catalogGeneration != currentIndexedGeneration,
           catalogGeneration != pendingRebuildGeneration,
           catalogGeneration != activeRebuildGeneration
        {
            scheduleRebuild(
                from: store,
                rootScope: rootScope,
                targetGeneration: catalogGeneration,
                debounceNanoseconds: 0
            )
        }
    }

    func stopKeepingFresh() {
        appliedIndexListenerTask?.cancel()
        appliedIndexListenerTask = nil
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = nil
    }

    /// P4-7b b3: `handles` is optional because `WorkspaceFileContextStore.searchRootQueryHandles`
    /// can fail to open (scope unavailable, or any one root's handle open failing) -- §4.6's
    /// fail-visible rule: a failed vend must never silently commit an empty, "ready" index. `nil`
    /// marks the index unusable and returns the *previous* indexed generation unchanged (matching
    /// the existing cancelled-rebuild return shape below), rather than advancing to a generation
    /// that was never actually indexed.
    @discardableResult
    func rebuildIndex(
        from handles: WorkspaceSearchRootQueryHandles?,
        diagnostics: WorkspaceCatalogDiagnostics
    ) async -> UInt64 {
        rebuildSerial &+= 1
        let serial = rebuildSerial
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = diagnostics.generation
        latestObservedCatalogGeneration = diagnostics.generation

        guard let handles else {
            isReadyIndexUsable = false
            #if DEBUG
                discardedQueryErrorCount += 1
            #endif
            activeRebuildGeneration = nil
            return currentIndexedGeneration ?? diagnostics.generation
        }
        let prepared = Self.prepareIndex(handles: handles, diagnostics: diagnostics)
        #if DEBUG
            recordPreparedIndexWork(prepared)
        #endif
        guard serial == rebuildSerial, !Task.isCancelled else {
            activeRebuildGeneration = nil
            return currentIndexedGeneration ?? diagnostics.generation
        }
        commit(prepared)
        activeRebuildGeneration = nil
        return diagnostics.generation
    }

    /// Convenience over `rebuildIndex(from:diagnostics:)`: fetches both from `store` for callers
    /// that do not already have them in hand (mirrors the pre-flip pattern where a caller fetched
    /// one `WorkspaceSearchCatalogSnapshot` and passed it through). `store.catalogDiagnostics`
    /// pages the root for accurate counts -- an explicitly out-of-scope-to-retire page-through
    /// (design doc §1.2.1: `catalogDiagnostics` is one of the store's own surviving Tier-1 read
    /// sites), paid once per rebuild, not per search.
    @discardableResult
    func rebuildIndex(
        from store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope
    ) async -> UInt64 {
        retainedStore = store
        retainedRootScope = rootScope
        async let handles = store.searchRootQueryHandles(rootScope: rootScope)
        async let diagnostics = store.catalogDiagnostics(rootScope: rootScope)
        return await rebuildIndex(from: handles, diagnostics: diagnostics)
    }

    @discardableResult
    func prepareIndex(
        from handles: WorkspaceSearchRootQueryHandles?,
        diagnostics: WorkspaceCatalogDiagnostics
    ) async -> UInt64 {
        await rebuildIndex(from: handles, diagnostics: diagnostics)
    }

    @discardableResult
    func prepareIndex(
        from store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope
    ) async -> UInt64 {
        await rebuildIndex(from: store, rootScope: rootScope)
    }

    func reset() async {
        rebuildSerial &+= 1
        appliedIndexListenerTask?.cancel()
        appliedIndexListenerTask = nil
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        readyHandles = WorkspaceSearchRootQueryHandles(scopeGeneration: 0, perRoot: [])
        currentSnapshotGeneration = nil
        currentIndexedGeneration = nil
        currentDiagnostics = nil
        latestObservedCatalogGeneration = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = nil
        isReadyIndexUsable = true
        retainedStore = nil
    }

    func search(_ query: String, limit: Int = 300) async -> WorkspaceSearchQueryResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedLimit = max(0, limit)
        let stale = isSearchStale
        let pendingGenerationAtSearchStart = pendingGeneration
        let observedGenerationAtSearchStart = latestObservedCatalogGeneration
        let isReadyIndexUsableAtSearchStart = isReadyIndexUsable
        guard boundedLimit > 0 else {
            return queryResult(query: query, results: [], isStale: stale)
        }

        guard isReadyIndexUsableAtSearchStart, currentIndexedGeneration != nil else {
            return queryResult(query: query, results: [], isStale: stale)
        }

        let handlesAtSearchStart = readyHandles
        let generationAtSearchStart = currentIndexedGeneration
        let snapshotGenerationAtSearchStart = currentSnapshotGeneration
        #if DEBUG
            if let searchDidCaptureGenerationHandler {
                await searchDidCaptureGenerationHandler(generationAtSearchStart)
            }
        #endif

        let results: [WorkspaceSearchCatalogEntry] = if trimmed.isEmpty {
            await emptyQueryResults(handlesAtSearchStart, limit: boundedLimit)
        } else {
            await withTaskGroup(of: [WorkspaceSearchCatalogEntry].self) { group in
                group.addTask {
                    await self.nonEmptyQueryResults(handlesAtSearchStart, query: trimmed, limit: boundedLimit)
                }
                let value = await group.next() ?? []
                group.cancelAll()
                return value
            }
        }
        return WorkspaceSearchQueryResult(
            query: query,
            indexedGeneration: generationAtSearchStart,
            snapshotGeneration: snapshotGenerationAtSearchStart,
            pendingGeneration: pendingGenerationAtSearchStart,
            observedGeneration: observedGenerationAtSearchStart,
            results: results,
            isIndexReady: generationAtSearchStart != nil && isReadyIndexUsableAtSearchStart,
            isStale: stale
        )
    }

    private var isSearchStale: Bool {
        guard let currentIndexedGeneration else {
            return pendingRebuildGeneration != nil || activeRebuildGeneration != nil || latestObservedCatalogGeneration != nil
        }
        if let latestObservedCatalogGeneration, latestObservedCatalogGeneration != currentIndexedGeneration {
            return true
        }
        if let pendingRebuildGeneration, pendingRebuildGeneration != currentIndexedGeneration {
            return true
        }
        if let activeRebuildGeneration, activeRebuildGeneration != currentIndexedGeneration {
            return true
        }
        return !isReadyIndexUsable
    }

    private func queryResult(
        query: String,
        results: [WorkspaceSearchCatalogEntry],
        isStale: Bool
    ) -> WorkspaceSearchQueryResult {
        WorkspaceSearchQueryResult(
            query: query,
            indexedGeneration: currentIndexedGeneration,
            snapshotGeneration: currentSnapshotGeneration,
            pendingGeneration: pendingGeneration,
            observedGeneration: latestObservedCatalogGeneration,
            results: results,
            isIndexReady: currentIndexedGeneration != nil && isReadyIndexUsable,
            isStale: isStale
        )
    }

    private func handleAppliedIndexEvent(
        _ event: WorkspaceAppliedIndexBatchEvent,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        debounceNanoseconds: UInt64
    ) async {
        if event.isRootUnload {
            dropReadyRootHandle(rootID: event.rootID)
        }

        let catalogGeneration = await store.catalogGeneration(rootScope: rootScope)
        latestObservedCatalogGeneration = catalogGeneration
        if catalogGeneration == currentIndexedGeneration,
           pendingRebuildGeneration == nil,
           activeRebuildGeneration == nil
        {
            return
        }
        if catalogGeneration == pendingRebuildGeneration || catalogGeneration == activeRebuildGeneration {
            return
        }
        scheduleRebuild(
            from: store,
            rootScope: rootScope,
            targetGeneration: catalogGeneration,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    private func scheduleRebuild(
        from store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        targetGeneration: UInt64,
        debounceNanoseconds: UInt64
    ) {
        pendingRebuildGeneration = targetGeneration
        #if DEBUG
            if pendingRebuildTask != nil {
                debugDebounceCancellationCount += 1
            }
        #endif
        pendingRebuildTask?.cancel()
        pendingRebuildTask = Task { [weak self, store] in
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }
            await self?.rebuildFromStoreIfCurrent(
                store: store,
                rootScope: rootScope,
                targetGeneration: targetGeneration,
                debounceNanoseconds: debounceNanoseconds
            )
        }
    }

    private func rebuildFromStoreIfCurrent(
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        targetGeneration: UInt64,
        debounceNanoseconds: UInt64
    ) async {
        guard pendingRebuildGeneration == targetGeneration || activeRebuildGeneration == targetGeneration else { return }
        pendingRebuildGeneration = nil
        activeRebuildGeneration = targetGeneration
        let diagnostics = await store.catalogDiagnostics(rootScope: rootScope)
        latestObservedCatalogGeneration = diagnostics.generation
        guard diagnostics.generation == targetGeneration else {
            activeRebuildGeneration = nil
            scheduleRebuild(
                from: store,
                rootScope: rootScope,
                targetGeneration: diagnostics.generation,
                debounceNanoseconds: 0
            )
            return
        }

        #if DEBUG
            await automaticRebuildDidStartHandler?(targetGeneration)
        #endif
        if automaticIndexBuildDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: automaticIndexBuildDelayNanoseconds)
        }
        let handles = await store.searchRootQueryHandles(rootScope: rootScope)
        let prepared = handles.map { Self.prepareIndex(handles: $0, diagnostics: diagnostics) }
        #if DEBUG
            if let prepared { recordPreparedIndexWork(prepared) }
        #endif
        guard let prepared,
              !Task.isCancelled,
              latestObservedCatalogGeneration == prepared.generation,
              pendingRebuildGeneration == nil || pendingRebuildGeneration == prepared.generation,
              activeRebuildGeneration == prepared.generation
        else {
            discardedAutomaticRebuildCompletions += 1
            if activeRebuildGeneration == targetGeneration {
                activeRebuildGeneration = nil
            }
            if handles == nil {
                isReadyIndexUsable = false
                #if DEBUG
                    discardedQueryErrorCount += 1
                #endif
            }
            return
        }
        commit(prepared)
        activeRebuildGeneration = nil
        pendingRebuildTask = nil
    }

    private func dropReadyRootHandle(rootID: UUID) {
        readyHandles = WorkspaceSearchRootQueryHandles(
            scopeGeneration: readyHandles.scopeGeneration,
            perRoot: readyHandles.perRoot.filter { $0.identity.rootID != rootID }
        )
    }

    private func commit(_ prepared: PreparedIndex) {
        readyHandles = prepared.handles
        currentSnapshotGeneration = prepared.generation
        currentDiagnostics = prepared.diagnostics
        currentIndexedGeneration = prepared.generation
        isReadyIndexUsable = true
    }

    private static func prepareIndex(
        handles: WorkspaceSearchRootQueryHandles,
        diagnostics: WorkspaceCatalogDiagnostics
    ) -> PreparedIndex {
        #if DEBUG
            let totalStart = DispatchTime.now().uptimeNanoseconds
            let end = DispatchTime.now().uptimeNanoseconds
            return PreparedIndex(
                generation: diagnostics.generation,
                diagnostics: diagnostics,
                handles: handles,
                totalMicroseconds: elapsedMicroseconds(since: totalStart, through: end)
            )
        #else
            return PreparedIndex(
                generation: diagnostics.generation,
                diagnostics: diagnostics,
                handles: handles
            )
        #endif
    }

    // MARK: - Query execution (§4.4: per-root `inventoryQuery(.indexKey)`, merged in Swift)

    private func nonEmptyQueryResults(
        _ handles: WorkspaceSearchRootQueryHandles,
        query: String,
        limit: Int
    ) async -> [WorkspaceSearchCatalogEntry] {
        var candidateBatches: [[RankedCandidate]] = []
        candidateBatches.reserveCapacity(handles.perRoot.count)
        for handle in handles.perRoot {
            if Task.isCancelled { return [] }
            do {
                let result = try await handle.snapshot.query(
                    pattern: query,
                    limit: UInt64(limit),
                    haystackVariant: .indexKey,
                    nonEmptyRelativePrefix: "",
                    emptyRelativePathValue: ""
                )
                let batch = result.candidates.map { candidate in
                    RankedCandidate(
                        entry: Self.catalogEntry(from: candidate, rootPath: handle.rootPath, rootName: handle.rootName),
                        tieBreakKey: candidate.tieBreakKey
                    )
                }
                candidateBatches.append(batch)
            } catch let CoreBridgeError.inventoryHandleInvalidated(reason) {
                await handleQueryInvalidation(reason: reason, rootID: handle.identity.rootID)
                candidateBatches.append([])
            } catch {
                await handleQueryTransportFailure()
                candidateBatches.append([])
            }
        }
        return Self.mergeCandidateBatches(candidateBatches, limit: limit)
    }

    /// §4.2.1: the empty query is not a query -- it is a catalog-order (not tie-break-order)
    /// k-way merge of retained per-root entry arrays. Each root's own first page (offset 0, limit
    /// `limit`) already IS that root's local top-`limit` in catalog order (`generation.files`,
    /// sorted -- `rebuild_generation`'s doc comment); merging each root's local top-`limit` and
    /// truncating to the global top-`limit` is exactly as correct as the non-empty path's identical
    /// per-root-then-merge shape (a global top-N element must be a member of its own root's local
    /// top-N). This is bounded per root at `limit`, not a whole-root page-through.
    private func emptyQueryResults(
        _ handles: WorkspaceSearchRootQueryHandles,
        limit: Int
    ) async -> [WorkspaceSearchCatalogEntry] {
        var perRootEntries: [[WorkspaceSearchCatalogEntry]] = []
        perRootEntries.reserveCapacity(handles.perRoot.count)
        for handle in handles.perRoot {
            if Task.isCancelled { return [] }
            do {
                var collected: [WorkspaceSearchCatalogEntry] = []
                var offset: UInt64 = 0
                while collected.count < limit {
                    let page = try await handle.snapshot.page(offset: offset, limit: UInt64(limit))
                    for file in page.files {
                        collected.append(Self.catalogEntry(from: file, rootPath: handle.rootPath, rootName: handle.rootName))
                    }
                    offset += page.returnedCount
                    if !page.hasMore || page.returnedCount == 0 { break }
                }
                perRootEntries.append(collected)
            } catch let CoreBridgeError.inventoryHandleInvalidated(reason) {
                await handleQueryInvalidation(reason: reason, rootID: handle.identity.rootID)
                perRootEntries.append([])
            } catch {
                await handleQueryTransportFailure()
                perRootEntries.append([])
            }
        }
        return Self.mergeEntryBatches(perRootEntries, limit: limit)
    }

    private static func catalogEntry(
        from candidate: CoreInventoryQueryCandidateV1,
        rootPath: String,
        rootName: String
    ) -> WorkspaceSearchCatalogEntry {
        let file = WorkspaceFileRecord(
            id: candidate.id,
            rootID: candidate.rootID,
            name: candidate.name,
            relativePath: candidate.standardizedRelativePath,
            fullPath: candidate.standardizedFullPath,
            parentFolderID: nil
        )
        let root = WorkspaceRootRecord(id: candidate.rootID, name: rootName, fullPath: rootPath)
        return WorkspaceSearchCatalogEntry(file: file, root: root)
    }

    private static func catalogEntry(
        from file: CoreInventoryFileRecordV1,
        rootPath: String,
        rootName: String
    ) -> WorkspaceSearchCatalogEntry {
        let record = WorkspaceFileRecord(
            id: file.id,
            rootID: file.rootID,
            name: file.name,
            relativePath: file.standardizedRelativePath,
            fullPath: file.standardizedFullPath,
            parentFolderID: nil
        )
        let root = WorkspaceRootRecord(id: file.rootID, name: rootName, fullPath: rootPath)
        return WorkspaceSearchCatalogEntry(file: record, root: root)
    }

    // MARK: - §4.6 fallback policy (fail visible, never fail empty)

    /// `.rootClosed`: drop that root's handle from the *ready* set (so the next search no longer
    /// queries it) and schedule a rebuild -- other roots still answer this and future searches.
    /// `.scopeClosed`/`.identityChanged`: the whole index is untrustworthy; mark it unusable (a
    /// full re-bootstrap from a fresh snapshot) and schedule a rebuild. Neither path degrades this
    /// call's own in-flight results to empty -- the caller already appended `[]` for this root's
    /// batch and other roots' batches are unaffected.
    private func handleQueryInvalidation(reason: CoreInventoryHandleInvalidationReason, rootID: UUID) async {
        switch reason {
        case .rootClosed:
            dropReadyRootHandle(rootID: rootID)
        case .scopeClosed, .identityChanged:
            isReadyIndexUsable = false
        }
        #if DEBUG
            discardedQueryErrorCount += 1
        #endif
        await triggerReactiveRebuildIfPossible()
    }

    /// Any other query error (transport/decode failure): §4.6's explicit "must not degrade to
    /// empty results silently" case -- mark the index unusable, count it, and schedule a rebuild.
    private func handleQueryTransportFailure() async {
        isReadyIndexUsable = false
        #if DEBUG
            discardedQueryErrorCount += 1
        #endif
        await triggerReactiveRebuildIfPossible()
    }

    /// Self-heals a query-time failure. Necessary because this actor is event-driven
    /// (`store.appliedIndexEvents()`), not polling -- without an explicit trigger here, a
    /// transient handle/transport failure with no *further* catalog mutation would leave
    /// `isReadyIndexUsable == false` forever, since no new applied-index event would ever arrive
    /// to naturally prompt a retry.
    private func triggerReactiveRebuildIfPossible() async {
        guard let store = retainedStore else { return }
        let rootScope = retainedRootScope
        let freshGeneration = await store.catalogGeneration(rootScope: rootScope)
        guard pendingRebuildGeneration != freshGeneration, activeRebuildGeneration != freshGeneration else { return }
        scheduleRebuild(from: store, rootScope: rootScope, targetGeneration: freshGeneration, debounceNanoseconds: 0)
    }

    // MARK: - Merge (unchanged comparator; only the candidate source changed)

    private static func mergeCandidateBatches(
        _ candidateBatches: [[RankedCandidate]],
        limit: Int
    ) -> [WorkspaceSearchCatalogEntry] {
        var heap: [RankedCandidateCursor] = []
        heap.reserveCapacity(candidateBatches.count)

        func cursorPrecedes(_ lhs: RankedCandidateCursor, _ rhs: RankedCandidateCursor) -> Bool {
            candidatePrecedes(
                candidateBatches[lhs.rootIndex][lhs.candidateIndex],
                candidateBatches[rhs.rootIndex][rhs.candidateIndex]
            )
        }

        func push(_ cursor: RankedCandidateCursor) {
            heap.append(cursor)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard cursorPrecedes(heap[index], heap[parent]) else { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }

        func pop() -> RankedCandidateCursor? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let first = heap[0]
            heap[0] = heap.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                let next = right < heap.count && cursorPrecedes(heap[right], heap[left]) ? right : left
                guard cursorPrecedes(heap[next], heap[index]) else { break }
                heap.swapAt(index, next)
                index = next
            }
            return first
        }

        for rootIndex in candidateBatches.indices where !candidateBatches[rootIndex].isEmpty {
            push(RankedCandidateCursor(rootIndex: rootIndex, candidateIndex: 0))
        }

        var seenIDs = Set<UUID>()
        var results: [WorkspaceSearchCatalogEntry] = []
        results.reserveCapacity(limit)
        while results.count < limit, let cursor = pop() {
            let candidate = candidateBatches[cursor.rootIndex][cursor.candidateIndex]
            if seenIDs.insert(candidate.entry.id).inserted {
                results.append(candidate.entry)
            }
            let nextCandidateIndex = cursor.candidateIndex + 1
            if nextCandidateIndex < candidateBatches[cursor.rootIndex].count {
                push(RankedCandidateCursor(rootIndex: cursor.rootIndex, candidateIndex: nextCandidateIndex))
            }
        }
        return results
    }

    private static func mergeEntryBatches(
        _ perRootEntries: [[WorkspaceSearchCatalogEntry]],
        limit: Int
    ) -> [WorkspaceSearchCatalogEntry] {
        var heap: [EntryCursor] = []
        heap.reserveCapacity(perRootEntries.count)

        func cursorPrecedes(_ lhs: EntryCursor, _ rhs: EntryCursor) -> Bool {
            entryPrecedes(
                perRootEntries[lhs.rootIndex][lhs.entryIndex],
                perRootEntries[rhs.rootIndex][rhs.entryIndex]
            )
        }

        func push(_ cursor: EntryCursor) {
            heap.append(cursor)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard cursorPrecedes(heap[index], heap[parent]) else { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }

        func pop() -> EntryCursor? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let first = heap[0]
            heap[0] = heap.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                let next = right < heap.count && cursorPrecedes(heap[right], heap[left]) ? right : left
                guard cursorPrecedes(heap[next], heap[index]) else { break }
                heap.swapAt(index, next)
                index = next
            }
            return first
        }

        for rootIndex in perRootEntries.indices where !perRootEntries[rootIndex].isEmpty {
            push(EntryCursor(rootIndex: rootIndex, entryIndex: 0))
        }

        var results: [WorkspaceSearchCatalogEntry] = []
        results.reserveCapacity(limit)
        while results.count < limit, let cursor = pop() {
            results.append(perRootEntries[cursor.rootIndex][cursor.entryIndex])
            let nextEntryIndex = cursor.entryIndex + 1
            if nextEntryIndex < perRootEntries[cursor.rootIndex].count {
                push(EntryCursor(rootIndex: cursor.rootIndex, entryIndex: nextEntryIndex))
            }
        }
        return results
    }

    private static func candidatePrecedes(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
        // Score is always `1` on both engines (design doc §1.5 Check A), so the tie-break key
        // alone carries the ordering -- unchanged from the pre-flip comparator's shape.
        switch WorkspaceInventoryOrdering.compareUTF8Binary(lhs.tieBreakKey, rhs.tieBreakKey) {
        case .orderedAscending:
            true
        case .orderedDescending:
            false
        case .orderedSame:
            entryPrecedes(lhs.entry, rhs.entry)
        }
    }

    private static func entryPrecedes(
        _ lhs: WorkspaceSearchCatalogEntry,
        _ rhs: WorkspaceSearchCatalogEntry
    ) -> Bool {
        WorkspaceInventoryOrdering.searchCatalogEntryPrecedes(lhs, rhs)
    }

    #if DEBUG
        private func recordPreparedIndexWork(_ prepared: PreparedIndex) {
            debugRebuildCount += 1
            debugTotalMicroseconds &+= prepared.totalMicroseconds
            debugLastEntryCount = prepared.diagnostics.fileCount
        }

        private static func elapsedMicroseconds(since start: UInt64, through end: UInt64) -> UInt64 {
            end >= start ? (end - start) / 1000 : 0
        }
    #endif
}
