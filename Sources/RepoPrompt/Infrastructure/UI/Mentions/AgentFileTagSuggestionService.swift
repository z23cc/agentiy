import AgentryCoreBridge
import Foundation

@MainActor
final class AgentFileTagSuggestionService {
    private struct FileCandidate {
        let displayName: String
        let disambiguationLabel: String?
        let commitDisplayText: String
        let matchName: String
        let tokenRelativePath: String
        let scoreRelativePath: String
        let nameLower: String
        let scorePathLower: String
        let standardizedFullPath: String
        let expandedSubtitle: String?
    }

    private nonisolated static let excludedPathComponent = "_git_data"
    private nonisolated static let fuzzyThreshold: Double = 0.85
    private nonisolated static let indexCandidateMultiplier = 8
    private nonisolated static let minimumIndexCandidateLimit = 64

    private let store: WorkspaceFileContextStore?
    private let searchService: WorkspaceSearchService?
    private weak var selectionCoordinator: WorkspaceSelectionCoordinator?
    private let lookupContextProvider: (() async -> WorkspaceLookupContext)?
    private let maxResults: Int
    private let showsFileSubtitles: Bool

    private var cachedCandidates: [FileCandidate] = []
    private var cachedLookupContext: WorkspaceLookupContext = .visibleWorkspace
    private var cachedGenerationSignature: UInt64?
    #if DEBUG
        /// P4-7a phase a3 (design §4.6-style fail-visible discipline, applied to this seam):
        /// counted rather than silently swallowed when a per-root `.suggestion` query fails --
        /// see `storeBackedCatalogResults`'s catch block.
        private(set) var storeBackedQueryFailureCountForTesting = 0
    #endif

    init(
        store: WorkspaceFileContextStore?,
        searchService: WorkspaceSearchService?,
        selectionCoordinator: WorkspaceSelectionCoordinator?,
        lookupContextProvider: (() async -> WorkspaceLookupContext)? = nil,
        maxResults: Int = 5,
        showsFileSubtitles: Bool = false
    ) {
        self.store = store
        self.searchService = searchService
        self.selectionCoordinator = selectionCoordinator
        self.lookupContextProvider = lookupContextProvider
        self.maxResults = maxResults
        self.showsFileSubtitles = showsFileSubtitles
    }

    func suggestions(for rawQuery: String) async -> [MentionSuggestion] {
        guard let store else { return [] }

        let lookupContext = await currentLookupContext()
        if cachedLookupContext != lookupContext {
            cachedCandidates.removeAll()
            cachedGenerationSignature = nil
            cachedLookupContext = lookupContext
        }
        let query = RepoSearchQueryFactory.make(rawQuery, supportsWildcards: false)
        if query.isEmpty {
            let selected = await selectedSuggestionsForEmptyQuery(store: store, lookupContext: lookupContext)
            if !selected.isEmpty {
                return Array(selected.prefix(maxResults))
            }
            let currentGeneration = await store.catalogGeneration(rootScope: lookupContext.rootScope)
            if !cachedCandidates.isEmpty,
               cachedGenerationSignature == currentGeneration
            {
                return Array(cachedCandidates.prefix(maxResults)).map { makeSuggestion(from: $0) }
            }
            cachedCandidates.removeAll()
            cachedGenerationSignature = nil
            return []
        }

        let candidateLimit = max(maxResults * Self.indexCandidateMultiplier, Self.minimumIndexCandidateLimit)
        let catalogResults = await catalogResults(for: query.raw, limit: candidateLimit, store: store, lookupContext: lookupContext)
        let candidates = await makeCandidates(from: catalogResults, store: store, lookupContext: lookupContext)
        guard !candidates.isEmpty else { return [] }
        cachedCandidates = candidates
        cachedGenerationSignature = await store.catalogGeneration(rootScope: lookupContext.rootScope)
        return scoredSuggestions(from: candidates, query: query)
    }

    private func catalogResults(
        for query: String,
        limit: Int,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) async -> [WorkspaceSearchCatalogEntry] {
        if lookupContext.bindingProjection == nil, let searchService {
            let result = await searchService.search(query, limit: limit)
            if result.isIndexReady, !result.isStale {
                let visibleRootIDs = await Set(store.rootRefs(scope: lookupContext.rootScope).map(\.id))
                let scopedResults = result.results.filter { visibleRootIDs.contains($0.rootID) }
                return Array(scopedResults.prefix(limit))
            }
        }
        return await storeBackedCatalogResults(for: query, limit: limit, store: store, lookupContext: lookupContext)
    }

    /// P4-7a phase a3 (design doc §5.3): the fallback path -- worktree-bound sessions, cold start,
    /// and stale-index windows (`catalogResults(for:limit:store:lookupContext:)`'s comment above
    /// names the same three cases; the fast path through `searchService.search` handles the
    /// steady-state common case for free after P4-7b). Issues one `inventoryQuery(.suggestion)`
    /// per visible root (mirroring `WorkspaceSearchService.nonEmptyQueryResults`'s per-root-then-
    /// merge shape for `.indexKey`, `Search/WorkspaceSearchService.swift:566-596`) via the store's
    /// `suggestionQuery` seam -- `snapshot.entries` is never read on this path, discharging parent
    /// §11's "the whole-entries walk is provably gone" and the private per-query `PathSearchIndex`
    /// this replaces (design §5.3).
    ///
    /// **Root order.** Per-root results are concatenated in `store.rootRefs(scope:)`'s order --
    /// this is a merge-free concatenation (unlike `.indexKey`'s tie-break-key-sensitive cross-root
    /// merge), because `scoredSuggestions` re-scores and truncates every candidate this method
    /// returns; only the final scored-and-truncated list is user-visible, so this method's own
    /// ordering is not independently load-bearing.
    ///
    /// **Result-set consequence of the per-root fan-out (design §14's discipline: name what
    /// changed).** The pre-cutover implementation ran one `PathSearchIndex` over every visible
    /// root's entries combined and truncated to `limit` **globally**. This method truncates each
    /// root's own candidates to `limit` and then concatenates -- a strict superset in a multi-root
    /// configuration. `scoredSuggestions`' re-scoring absorbs this (every entry that reaches it is
    /// still ranked and cut to `maxResults`), so a fallback-path candidate that the old global
    /// truncation would have discarded can now survive and appear in the final suggestion list.
    /// This is a real, intentionally-accepted behavior change on the fallback path only --
    /// `AgentFileTagSuggestionParityDifferentialTests` pins it as its own named case rather than
    /// asserting single-root-only equivalence and calling the differential complete.
    private func storeBackedCatalogResults(
        for query: String,
        limit: Int,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) async -> [WorkspaceSearchCatalogEntry] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        let roots = await store.rootRefs(scope: lookupContext.rootScope)
        guard !roots.isEmpty else { return [] }

        var seenIDs = Set<UUID>()
        var results: [WorkspaceSearchCatalogEntry] = []
        for root in roots {
            let logicalPrefix = Self.logicalPrefix(forPhysicalRoot: root, lookupContext: lookupContext)
            do {
                let result = try await store.suggestionQuery(
                    rootID: root.id,
                    pattern: query,
                    limit: UInt64(boundedLimit),
                    nonEmptyRelativePrefix: "",
                    emptyRelativePathValue: "",
                    logicalPrefix: logicalPrefix
                )
                for candidate in result.candidates where seenIDs.insert(candidate.id).inserted {
                    results.append(Self.catalogEntry(from: candidate, rootPath: root.standardizedFullPath, rootName: root.name))
                }
            } catch {
                // §4.6's fail-visible-never-fail-empty rule was written for the search facade's
                // handle-based reads; this seam opens a fresh snapshot per call and has no ready-
                // handle state to mark stale, so there is no equivalent visible-failure signal to
                // set here. Counted rather than silently swallowed -- see the DEBUG counter below.
                #if DEBUG
                    storeBackedQueryFailureCountForTesting += 1
                #endif
                continue
            }
        }
        return results
    }

    /// Per-root physical->logical binding data (design §5.1's `logicalPath` component), computed
    /// once per physical root rather than per entry: `nil` when the root has no binding projection
    /// (matching Swift's `compactMap` drop of a `nil` `logicalPath`), otherwise the bound logical
    /// root's `ClientPathFormatter.displayPrefix` pair -- the same per-root-prefix shape
    /// `WorkspacePathPolicyTests`'s logical-pair extension (P4-7a phase a1) pins against
    /// `WorkspaceRootBindingProjection.projectedLogicalDisplayPath` across all three branches plus
    /// the empty-relative-path case.
    private static func logicalPrefix(
        forPhysicalRoot root: WorkspaceRootRef,
        lookupContext: WorkspaceLookupContext
    ) -> (nonEmptyRelativePrefix: String, emptyRelativePathValue: String)? {
        guard let projection = lookupContext.bindingProjection,
              let boundRoot = projection.boundRoot(containingPhysicalAbsolutePath: root.standardizedFullPath)
        else { return nil }
        return ClientPathFormatter.displayPrefix(root: boundRoot.logicalRoot, visibleRoots: projection.visibleLogicalRootRefs)
    }

    /// Reconstructs the entry locally from the candidate's own fields plus the queried root's
    /// `rootPath`/`rootName` -- mirroring `WorkspaceSearchService.catalogEntry(from:rootPath:
    /// rootName:)` (`Search/WorkspaceSearchService.swift:639-653`) rather than trusting the wire's
    /// `displayPath` field. `WorkspaceSearchCatalogEntry.init`'s default `displayPath: nil`
    /// composition (`rootName + "/" + relativePath`) is exactly `entry.display_path`, the stored
    /// field `.suggestion`'s haystack and response both use Rust-side (design §5.1's fourth
    /// mismatch fix, `query.rs`'s module doc) -- reconstructing it here rather than decoding the
    /// wire's copy proves that byte-equality by construction instead of by trust.
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

    private func makeCandidates(
        from entries: [WorkspaceSearchCatalogEntry],
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) async -> [FileCandidate] {
        let filtered = entries.filter {
            !Self.shouldExcludeFromSuggestions(relativePath: $0.standardizedRelativePath)
        }
        guard !filtered.isEmpty else { return [] }
        let roots = await store.rootRefs(scope: lookupContext.rootScope)
        let hasMultipleRoots = roots.count > 1
        let countByFileName = Dictionary(grouping: filtered, by: { $0.name.lowercased() })
            .mapValues(\.count)
        let rootNamesByFileName = Dictionary(grouping: filtered, by: { $0.name.lowercased() })
            .mapValues { Set($0.map { $0.rootName.lowercased() }) }

        var candidates = filtered.map { entry in
            let tokenRelativePath = tokenPath(for: entry, roots: roots, lookupContext: lookupContext)
            let scoreRelativePath = tokenRelativePath
            let fileNameKey = entry.name.lowercased()
            let isDuplicateName = (countByFileName[fileNameKey] ?? 0) > 1
            let spansMultipleRoots = (rootNamesByFileName[fileNameKey]?.count ?? 0) > 1
            let rootLabel = entry.rootName.trimmingCharacters(in: .whitespacesAndNewlines)
            let disambiguationLabel: String? = if isDuplicateName {
                if spansMultipleRoots, !rootLabel.isEmpty {
                    rootLabel
                } else if let parentLabel = Self.parentDirectoryLabel(for: scoreRelativePath), !parentLabel.isEmpty {
                    parentLabel
                } else if !rootLabel.isEmpty {
                    rootLabel
                } else {
                    nil
                }
            } else {
                nil
            }

            return FileCandidate(
                displayName: entry.name,
                disambiguationLabel: disambiguationLabel,
                commitDisplayText: Self.commitDisplayText(
                    tokenRelativePath: tokenRelativePath,
                    fallbackFileName: entry.name
                ),
                matchName: entry.name,
                tokenRelativePath: tokenRelativePath,
                scoreRelativePath: scoreRelativePath,
                nameLower: entry.name.lowercased(),
                scorePathLower: scoreRelativePath.lowercased(),
                standardizedFullPath: entry.standardizedFullPath,
                expandedSubtitle: Self.expandedSubtitleLabel(
                    for: tokenRelativePath,
                    fallbackRootLabel: rootLabel
                )
            )
        }
        candidates.sort { lhs, rhs in
            if lhs.scorePathLower != rhs.scorePathLower {
                return lhs.scorePathLower < rhs.scorePathLower
            }
            return lhs.tokenRelativePath < rhs.tokenRelativePath
        }
        return candidates
    }

    private func currentLookupContext() async -> WorkspaceLookupContext {
        if let lookupContextProvider {
            return await lookupContextProvider()
        }
        return .visibleWorkspace
    }

    private func tokenPath(
        for entry: WorkspaceSearchCatalogEntry,
        roots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext
    ) -> String {
        if let projected = lookupContext.bindingProjection?.projectedLogicalPathComponents(
            forPhysicalPath: entry.standardizedFullPath
        ) {
            return ClientPathFormatter.nonAbsoluteDisplayPath(
                root: projected.root,
                relativePath: projected.relativePath,
                visibleRoots: lookupContext.bindingProjection?.visibleLogicalRootRefs ?? roots
            )
        }
        if let root = roots.first(where: { $0.id == entry.rootID }) {
            return ClientPathFormatter.nonAbsoluteDisplayPath(
                root: root,
                relativePath: entry.standardizedRelativePath,
                visibleRoots: roots
            )
        }
        return entry.standardizedRelativePath
    }

    private func tokenPath(
        for file: WorkspaceFileRecord,
        roots: [WorkspaceRootRef],
        hasMultipleRoots _: Bool,
        lookupContext: WorkspaceLookupContext
    ) -> String {
        if let projected = lookupContext.bindingProjection?.projectedLogicalPathComponents(
            forPhysicalPath: file.standardizedFullPath
        ) {
            return ClientPathFormatter.nonAbsoluteDisplayPath(
                root: projected.root,
                relativePath: projected.relativePath,
                visibleRoots: lookupContext.bindingProjection?.visibleLogicalRootRefs ?? roots
            )
        }
        if let root = roots.first(where: { $0.id == file.rootID }) {
            return ClientPathFormatter.nonAbsoluteDisplayPath(
                root: root,
                relativePath: file.standardizedRelativePath,
                visibleRoots: roots
            )
        }
        return file.standardizedRelativePath
    }

    private func scoredSuggestions(from candidates: [FileCandidate], query: RepoSearchQuery) -> [MentionSuggestion] {
        let scoringCandidates = candidates.map {
            RepoSearchBatchScorer.Candidate(
                name: $0.matchName,
                path: $0.scoreRelativePath,
                nameLower: $0.nameLower,
                pathLower: $0.scorePathLower
            )
        }
        let rawScores = RepoSearchBatchScorer.scores(
            for: scoringCandidates,
            query: query,
            fuzzyThreshold: Self.fuzzyThreshold
        )

        var scored: [(candidate: FileCandidate, score: Int32)] = []
        scored.reserveCapacity(candidates.count)
        for (index, score) in rawScores.enumerated() where score > 0 {
            guard candidates.indices.contains(index) else { continue }
            scored.append((candidates[index], score))
        }

        guard !scored.isEmpty else { return [] }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.candidate.scoreRelativePath.count != rhs.candidate.scoreRelativePath.count {
                return lhs.candidate.scoreRelativePath.count < rhs.candidate.scoreRelativePath.count
            }
            return lhs.candidate.scorePathLower < rhs.candidate.scorePathLower
        }

        return scored
            .prefix(maxResults)
            .map { makeSuggestion(from: $0.candidate) }
    }

    /// Build the suggestion list for a bare `@` from the active stored selection.
    /// This path does not refresh all workspace candidates or materialize UI VMs.
    private func selectedSuggestionsForEmptyQuery(
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) async -> [MentionSuggestion] {
        guard let selectionCoordinator else { return [] }
        let selection = lookupContext.physicalizeSelection(
            selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true).selection
        )
        guard !selection.selectedPaths.isEmpty else { return [] }
        let visibleRoots = await store.rootRefs(scope: lookupContext.rootScope)
        let hasMultipleRoots = visibleRoots.count > 1
        let candidateByPath = makeCandidateByTokenPath()
        var seenIdentities = Set<String>()
        var suggestions: [MentionSuggestion] = []
        suggestions.reserveCapacity(min(maxResults, selection.selectedPaths.count))

        for path in selection.selectedPaths {
            guard let lookup = await store.lookupPath(WorkspacePathLookupRequest(userPath: path, profile: .mcpSelection, rootScope: lookupContext.rootScope)),
                  let file = lookup.file else { continue }
            guard !Self.shouldExcludeFromSuggestions(relativePath: file.standardizedRelativePath) else { continue }
            guard seenIdentities.insert(file.standardizedFullPath).inserted else { continue }
            let tokenRelativePath = tokenPath(
                for: file,
                roots: visibleRoots,
                hasMultipleRoots: hasMultipleRoots,
                lookupContext: lookupContext
            )
            if let candidate = candidateByPath[tokenRelativePath] {
                suggestions.append(makeSuggestion(from: candidate))
            } else {
                let rootLabel = visibleRoots
                    .first(where: { $0.id == file.rootID })?
                    .name
                suggestions.append(MentionSuggestion(
                    displayName: file.name,
                    relativePath: tokenRelativePath,
                    kind: .file,
                    subtitle: expandedSubtitleLabel(for: tokenRelativePath, fallbackRootLabel: rootLabel),
                    commitDisplayText: Self.commitDisplayText(
                        tokenRelativePath: tokenRelativePath,
                        fallbackFileName: file.name
                    )
                ))
            }
            if suggestions.count >= maxResults { break }
        }
        return suggestions
    }

    /// Duplicate-tolerant lookup for cached candidates. Keep the first
    /// candidate seen for a given token path so we still pick up any
    /// precomputed disambiguation / display text when we do have a hit.
    private func makeCandidateByTokenPath() -> [String: FileCandidate] {
        Dictionary(
            cachedCandidates.map { ($0.tokenRelativePath, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    private func makeSuggestion(from candidate: FileCandidate) -> MentionSuggestion {
        MentionSuggestion(
            displayName: candidate.displayName,
            relativePath: candidate.tokenRelativePath,
            kind: .file,
            subtitle: showsFileSubtitles ? candidate.expandedSubtitle : candidate.disambiguationLabel,
            commitDisplayText: candidate.commitDisplayText
        )
    }

    private func expandedSubtitleLabel(for tokenRelativePath: String, fallbackRootLabel: String?) -> String? {
        guard showsFileSubtitles else { return nil }
        return Self.expandedSubtitleLabel(for: tokenRelativePath, fallbackRootLabel: fallbackRootLabel)
    }

    nonisolated static func commitDisplayText(
        tokenRelativePath: String,
        fallbackFileName: String
    ) -> String {
        let trimmedPath = tokenRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPath.isEmpty {
            return trimmedPath
        }
        return fallbackFileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func shouldExcludeFromSuggestions(relativePath: String) -> Bool {
        relativePath
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .contains { String($0).lowercased() == excludedPathComponent }
    }

    private nonisolated static func parentDirectoryLabel(for relativePath: String) -> String? {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nil }
        let parentComponents = components.dropLast()
        guard !parentComponents.isEmpty else { return nil }
        return parentComponents.joined(separator: "/")
    }

    private nonisolated static func expandedSubtitleLabel(
        for tokenRelativePath: String,
        fallbackRootLabel: String?
    ) -> String? {
        if let parentLabel = parentDirectoryLabel(for: tokenRelativePath), !parentLabel.isEmpty {
            return parentLabel
        }
        let rootLabel = fallbackRootLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rootLabel.isEmpty ? nil : rootLabel
    }

    #if DEBUG

        // MARK: - Testing support

        func seedCandidateCacheForTesting(tokenPaths: [String]) {
            cachedCandidates = tokenPaths.map { tokenPath in
                let basename = (tokenPath as NSString).lastPathComponent
                return FileCandidate(
                    displayName: basename,
                    disambiguationLabel: nil,
                    commitDisplayText: tokenPath,
                    matchName: basename,
                    tokenRelativePath: tokenPath,
                    scoreRelativePath: tokenPath,
                    nameLower: basename.lowercased(),
                    scorePathLower: tokenPath.lowercased(),
                    standardizedFullPath: tokenPath,
                    expandedSubtitle: Self.expandedSubtitleLabel(
                        for: tokenPath,
                        fallbackRootLabel: nil
                    )
                )
            }
        }

        var cachedCandidateCountForTesting: Int {
            cachedCandidates.count
        }

        var pathSearchIndexIsBuiltForTesting: Bool {
            false
        }

        /// P4-7a phase a3's hard-assertion differential seam (design §5.3): exposes
        /// `catalogResults(for:limit:store:lookupContext:)`'s raw result set/order -- the level
        /// the differential is mandated against -- independent of `suggestions(for:)`'s later
        /// fuzzy re-scoring and `maxResults` truncation, which is a separate transformation this
        /// slice does not touch.
        func catalogResultsForTesting(for query: String, limit: Int) async -> [WorkspaceSearchCatalogEntry] {
            guard let store else { return [] }
            let lookupContext = await currentLookupContext()
            return await catalogResults(for: query, limit: limit, store: store, lookupContext: lookupContext)
        }
    #endif
}
