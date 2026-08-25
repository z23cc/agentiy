import AgentryCoreBridge
import Foundation

// ================================================================================================
// P4-6b prep slice 2: the republication adapter (design doc
// `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §4.3). After the cutover, Rust
// owns the inventory tables, but two existing Swift consumers still subscribe to
// `store.appliedIndexEvents()` expecting the pre-cutover `WorkspaceAppliedIndexBatchEvent` shape:
//
//   - `Search/WorkspaceSearchService.swift:157` -- reads only `rootID` / `isRootUnload`.
//   - `Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift:1520` -- reads `rootID`,
//     `generation`, `rootLifetimeID`, `isRootUnload`, `requiresFullResync`, `modifiedFileIDs`,
//     `upsertedFolders`, `upsertedFiles`, and `modifiedFileSourceSnapshotsByID`.
//
// This adapter translates Rust's `CoreInventoryScopeEvent` stream into that exact shape.
//
// P4-6b authority-swap update: the DEBUG shadow-arm differential harness that used to verify
// this adapter pre-cutover (§8.4's pattern, comparing its output against the same mutation's
// real Swift-published event) is deleted along with the rest of the shadow apparatus -- Rust is
// now the sole authority, so there is no second arm left to compare against.
//
// **P5-5 production source.** `WorkspaceFileContextStore` constructs this adapter, subscribes it to
// `WorkspaceInventoryScopeAuthority.events()` (one hub-wide subscription per store), validates
// exact transaction-scoped presentation plans, and feeds the canonical result to production
// `appliedIndexEvents()`. `republishedInventoryScopeEvents()` remains as a differential/test mirror.
// Activation floors, root-local publication permits, lifetime checks, logical-generation rebasing,
// hidden-generation suppression, and Swift-seamed unload plans preserve the pre-flip consumer shape.
// ================================================================================================

/// Fills in the two fields Rust's event stream does not carry -- `rootPath` and Swift's own
/// UUID-shaped `rootLifetimeID` (distinct from Rust's opaque `RootLifetimeId` string; see
/// `WorkspaceInventoryScopeShadowForwarder`'s doc comment on why the two are never the same
/// value) -- both root binding/topology facts that stay Swift-owned per design doc §4.2 both
/// before and after the cutover.
struct WorkspaceInventoryScopeRepublicationRootInfo: Equatable {
    let standardizedFullPath: String
    let lifetimeID: UUID
}

struct WorkspaceInventoryScopeRepublicationCandidate: Equatable {
    let rustRootLifetimeID: String?
    /// Exact generation carried by the paired Rust notification. Zero remains the explicit
    /// missing-correlation sentinel; root-unload candidates also have no delta generation.
    let rustGeneration: UInt64
    /// Exact id-bearing Rust payload before any Swift presentation mapping. P5-4's canonical
    /// presentation plan validates this whole value rather than trusting FIFO position or counts.
    /// Root-unload candidates have no applied-index batch and therefore carry `nil`.
    let rawBatch: CoreInventoryAppliedIndexBatchEventV1?
    /// Transport/correlation integrity only: hub gaps, resnapshot obligations, FIFO loss, or a
    /// missing generation pair. Rust choosing an authoritative rebuild is deliberately separate.
    let correlationIntegrityRequiresResync: Bool
    let rebuiltAuthoritative: Bool
    let event: WorkspaceAppliedIndexBatchEvent
}

/// Stateful, per-scope event-stream translator (design doc §4.3). Not an actor: every consumer of
/// a `CoreInventoryScopeEventStream` already owns a single sequential drain loop (see
/// `CoreInventoryScopeEventCollector` in `CoreInventoryScopeEventsTests.swift` for the established
/// pattern), so this type's state only needs to be safe under that same one-writer-at-a-time
/// discipline -- ordinary reference-type mutation, no actor isolation needed beyond whatever
/// isolates its single caller.
final class WorkspaceInventoryScopeRepublicationAdapter {
    static let maxPendingGenerationsPerRoot = 64
    static let maxPendingGenerationCount = 512

    private struct PendingGenerationQueue {
        private var values: [CoreInventoryGenerationAdvancedEventV1] = []
        private var headIndex = 0

        var count: Int {
            values.count - headIndex
        }

        var isEmpty: Bool {
            count == 0
        }

        mutating func append(_ value: CoreInventoryGenerationAdvancedEventV1) {
            values.append(value)
        }

        mutating func popFirst() -> CoreInventoryGenerationAdvancedEventV1? {
            guard headIndex < values.count else { return nil }
            defer {
                headIndex += 1
                compactIfNeeded()
            }
            return values[headIndex]
        }

        private mutating func compactIfNeeded() {
            guard headIndex > 32, headIndex * 2 >= values.count else { return }
            values.removeFirst(headIndex)
            headIndex = 0
        }
    }

    private let rootInfo: (UUID) async -> WorkspaceInventoryScopeRepublicationRootInfo?
    private var pendingGenerationsByRootID: [UUID: PendingGenerationQueue] = [:]
    private var pendingGenerationCount = 0
    private var rustLifetimeIDByRootID: [UUID: String] = [:]
    private var forceResyncOnNextDeliveryRootIDs: Set<UUID> = []
    private var globalResyncEpoch: UInt64 = 0
    private var observedGlobalResyncEpochByRootID: [UUID: UInt64] = [:]

    /// - Parameter rootInfo: resolves a root's current Swift-owned path/lifetime facts (an
    ///   `async` closure because the production source, `WorkspaceFileContextStore`, is an actor).
    ///   Returns `nil` for a root this adapter's caller no longer tracks (e.g. already unloaded);
    ///   `ingest` republishes a best-effort event rather than silently dropping it in that case.
    init(rootInfo: @escaping (UUID) async -> WorkspaceInventoryScopeRepublicationRootInfo?) {
        self.rootInfo = rootInfo
    }

    /// Feeds one Rust event into the adapter. Returns a republished `WorkspaceAppliedIndexBatchEvent`
    /// when this event completed a correlatable batch or was itself a root-lifecycle event this
    /// adapter republishes; returns `nil` when the event was buffered awaiting correlation
    /// (`generationAdvanced`), changes correlation/resync state without a consumer-visible payload
    /// (`resnapshotRequired`/`rootPublished`), or is a kind neither consumer needs republished
    /// (`shardFallback`/`unknown`). `rootPublished` carries no upsert/removal payload and the
    /// consumers' resync guards only fire off a *content* event's generation, never root-open itself.
    ///
    /// `modifiedFileSourceSnapshotsByID` is never populated here -- design doc §4.3 point 3: it is
    /// Swift-only, non-inventory state produced at a single site
    /// (`WorkspaceFileContextStore.swift`'s synthetic-modification/edit path) that never crosses
    /// the FFI. The caller merges it afterward through P5-3's bounded local join, keyed by the
    /// exact Rust receipt generation and the file IDs this adapter's republished
    /// `modifiedFileIDs` names -- still not this adapter's concern.
    func ingest(_ event: CoreInventoryScopeEvent) async -> WorkspaceAppliedIndexBatchEvent? {
        await ingestCandidate(event)?.event
    }

    func ingestCandidate(_ event: CoreInventoryScopeEvent) async -> WorkspaceInventoryScopeRepublicationCandidate? {
        switch event {
        case .gap:
            // Hub-wide, not per-root (§4.3): discard any half-correlated pairs and advance an
            // epoch that every root consumes independently on its next delivery. One active root
            // must never clear another root's resync obligation.
            markGlobalResyncRequired()
            return nil

        case let .generationAdvanced(advanced):
            if let currentLifetimeID = rustLifetimeIDByRootID[advanced.rootID],
               currentLifetimeID != advanced.rootLifetimeID
            {
                // A delayed event from a previous Rust root lifetime cannot participate in the
                // current lifetime's FIFO. Drop its correlation and make the next visible batch
                // resync instead of assigning it a cross-lifetime generation.
                discardPendingGenerations(for: advanced.rootID)
                forceResyncOnNextDeliveryRootIDs.insert(advanced.rootID)
                return nil
            }
            rustLifetimeIDByRootID[advanced.rootID] = advanced.rootLifetimeID

            // Bulk commits publish generation metadata without a companion applied-index batch.
            // Their event currently carries the zero-based catalog generation in both generation
            // fields; a real delta always carries the one-based applied-index generation and its
            // zero-based catalog generation, so the values differ by one. Never enqueue the
            // generation-only bulk marker into the delta FIFO or it will be paired with the next
            // mutation's payload and force a false resync.
            if advanced.rebuiltAuthoritative,
               advanced.catalogGeneration == advanced.appliedIndexGeneration
            {
                return nil
            }

            var queue = pendingGenerationsByRootID[advanced.rootID] ?? PendingGenerationQueue()
            guard queue.count < Self.maxPendingGenerationsPerRoot else {
                discardPendingGenerations(for: advanced.rootID)
                forceResyncOnNextDeliveryRootIDs.insert(advanced.rootID)
                return nil
            }
            guard pendingGenerationCount < Self.maxPendingGenerationCount else {
                markGlobalResyncRequired()
                return nil
            }
            queue.append(advanced)
            pendingGenerationsByRootID[advanced.rootID] = queue
            pendingGenerationCount += 1
            return nil

        case let .appliedIndexBatch(batch):
            let advanced = popPendingGeneration(for: batch.rootID)
            let globalResyncRequired = observedGlobalResyncEpochByRootID[batch.rootID, default: 0] < globalResyncEpoch
            observedGlobalResyncEpochByRootID[batch.rootID] = globalResyncEpoch
            let rootResyncRequired = forceResyncOnNextDeliveryRootIDs.remove(batch.rootID) != nil
            let correlationIntegrityRequiresResync = rootResyncRequired
                || globalResyncRequired
                || advanced == nil
            let rebuiltAuthoritative = advanced?.rebuiltAuthoritative == true
            let requiresFullResync = correlationIntegrityRequiresResync || rebuiltAuthoritative
            let rustGeneration = advanced?.appliedIndexGeneration ?? 0

            // Missing correlation means this batch's `generationAdvanced` was dropped (or the
            // adapter started mid-pair). Republish with generation zero and force a resync rather
            // than assign the batch a stale or later generation. `ingest(_:)` retains the existing
            // combined compatibility flag; P5-4's store path consumes the two causes separately.
            let republished = await republish(
                batch: batch,
                generation: rustGeneration,
                requiresFullResync: requiresFullResync
            )
            return WorkspaceInventoryScopeRepublicationCandidate(
                rustRootLifetimeID: advanced?.rootLifetimeID ?? rustLifetimeIDByRootID[batch.rootID],
                rustGeneration: rustGeneration,
                rawBatch: batch,
                correlationIntegrityRequiresResync: correlationIntegrityRequiresResync,
                rebuiltAuthoritative: rebuiltAuthoritative,
                event: republished
            )

        case let .rootPublished(published):
            // A root UUID can be rebound to a new Rust lifetime. Never let correlation or resync
            // state from the previous lifetime leak into the new one.
            clearRootState(published.rootID)
            rustLifetimeIDByRootID[published.rootID] = published.rootLifetimeID
            observedGlobalResyncEpochByRootID[published.rootID] = globalResyncEpoch
            return nil

        case let .rootUnloaded(unload):
            guard rustLifetimeIDByRootID[unload.rootID].map({ $0 == unload.rootLifetimeID }) ?? true else {
                // A late close for a retired lifetime must not clear or unload the root currently
                // bound to the same UUID.
                return nil
            }
            // Rust's root-close does not itself publish an `appliedIndexBatch` (nothing to
            // correlate); this is its own lifecycle event. Consumers only read `rootID` /
            // `isRootUnload` for the unload case (design doc §4.3's consumer table) -- no
            // itemized removal list is needed, matching what an unload republication has ever
            // needed to carry.
            let info = await rootInfo(unload.rootID)
            clearRootState(unload.rootID)
            return WorkspaceInventoryScopeRepublicationCandidate(
                rustRootLifetimeID: unload.rootLifetimeID,
                rustGeneration: 0,
                rawBatch: nil,
                correlationIntegrityRequiresResync: false,
                rebuiltAuthoritative: false,
                event: WorkspaceAppliedIndexBatchEvent(
                    rootID: unload.rootID,
                    rootPath: info?.standardizedFullPath ?? "",
                    generation: 0,
                    rootLifetimeID: info?.lifetimeID,
                    requiresFullResync: true,
                    isRootUnload: true
                )
            )

        case let .resnapshotRequired(resnapshot):
            if let rootID = resnapshot.rootID {
                discardPendingGenerations(for: rootID)
                forceResyncOnNextDeliveryRootIDs.insert(rootID)
            } else {
                markGlobalResyncRequired()
            }
            return nil

        case .shardFallback, .unknown:
            return nil
        }
    }

    private func popPendingGeneration(for rootID: UUID) -> CoreInventoryGenerationAdvancedEventV1? {
        guard var queue = pendingGenerationsByRootID[rootID] else { return nil }
        let advanced = queue.popFirst()
        if advanced != nil { pendingGenerationCount -= 1 }
        if queue.isEmpty {
            pendingGenerationsByRootID.removeValue(forKey: rootID)
        } else {
            pendingGenerationsByRootID[rootID] = queue
        }
        return advanced
    }

    private func discardPendingGenerations(for rootID: UUID) {
        guard let queue = pendingGenerationsByRootID.removeValue(forKey: rootID) else { return }
        pendingGenerationCount -= queue.count
    }

    private func clearRootState(_ rootID: UUID) {
        discardPendingGenerations(for: rootID)
        rustLifetimeIDByRootID.removeValue(forKey: rootID)
        forceResyncOnNextDeliveryRootIDs.remove(rootID)
        observedGlobalResyncEpochByRootID.removeValue(forKey: rootID)
    }

    private func markGlobalResyncRequired() {
        pendingGenerationsByRootID.removeAll(keepingCapacity: true)
        pendingGenerationCount = 0
        if globalResyncEpoch == .max {
            globalResyncEpoch = 1
            observedGlobalResyncEpochByRootID.removeAll(keepingCapacity: true)
        } else {
            globalResyncEpoch += 1
        }
    }

    private func republish(
        batch: CoreInventoryAppliedIndexBatchEventV1,
        generation: UInt64,
        requiresFullResync: Bool
    ) async -> WorkspaceAppliedIndexBatchEvent {
        let info = await rootInfo(batch.rootID)
        return WorkspaceAppliedIndexBatchEvent(
            rootID: batch.rootID,
            rootPath: info?.standardizedFullPath ?? "",
            generation: generation,
            rootLifetimeID: info?.lifetimeID,
            upsertedFiles: batch.upsertedFiles.map(Self.workspaceFileRecord),
            upsertedFolders: batch.upsertedFolders.map(Self.workspaceFolderRecord),
            removedFileIDs: batch.removedFileIDs,
            removedFolderIDs: batch.removedFolderIDs,
            removedFilePaths: batch.removedFilePaths,
            removedFolderPaths: batch.removedFolderPaths,
            modifiedFileIDs: batch.modifiedFileIDs,
            modifiedFolderIDs: batch.modifiedFolderIDs,
            requiresFullResync: requiresFullResync,
            isRootUnload: false
        )
    }

    /// The reverse direction of `WorkspaceInventoryScopeShadowForwarder.coreFileRecord`: Rust ->
    /// Swift, preserving the id verbatim (never re-minted -- this is a translation, not a new
    /// discovery). `WorkspaceFileRecord`'s `standardizedRelativePath` / `standardizedFullPath` are
    /// always recomputed from `relativePath` / `fullPath` by its own initializer, never settable
    /// directly, so this only ever supplies the five source-of-truth fields plus id/parent/mtime;
    /// Rust and Swift are independently verified to standardize paths identically (P3-3's parity
    /// differentials), so this recomputation reproduces Rust's own values byte-for-byte.
    ///
    /// `parentFolderID` needs the reverse of `WorkspaceInventoryScopeShadowForwarder
    /// .normalizedParentFolderID`: the forwarder normalizes Swift's root-self-referencing marker
    /// (`parentFolderID == rootID`, the synthetic top-level-parent convention) to `nil` before
    /// sending to Rust, since Rust never sees that synthetic record at all. A top-level file/
    /// folder's Rust-published `parentFolderID` is therefore genuinely `nil`, and reconstructing
    /// it as `nil` here (rather than back to `rootID`) would silently diverge from the real
    /// Swift-published record's convention -- caught live by
    /// `testRepublicationAdapterMatchesRealSwiftPublishedEventForIncrementalAdd`'s dual-read
    /// comparison, not by inspection.
    static func denormalizedParentFolderID(_ parentFolderID: UUID?, rootID: UUID) -> UUID? {
        parentFolderID ?? rootID
    }

    static func workspaceFileRecord(_ file: CoreInventoryFileRecordV1) -> WorkspaceFileRecord {
        WorkspaceFileRecord(
            id: file.id,
            rootID: file.rootID,
            name: file.name,
            relativePath: file.relativePath,
            fullPath: file.fullPath,
            parentFolderID: denormalizedParentFolderID(file.parentFolderID, rootID: file.rootID),
            modificationDate: file.modificationDate
        )
    }

    static func workspaceFolderRecord(_ folder: CoreInventoryFolderRecordV1) -> WorkspaceFolderRecord {
        WorkspaceFolderRecord(
            id: folder.id,
            rootID: folder.rootID,
            name: folder.name,
            relativePath: folder.relativePath,
            fullPath: folder.fullPath,
            parentFolderID: denormalizedParentFolderID(folder.parentFolderID, rootID: folder.rootID),
            modificationDate: folder.modificationDate
        )
    }

    /// P4-6b table-deletion conversion ledger: reconstructs a full record from an
    /// id-keyed/path-keyed fact (`CoreInventoryRecordFact`, `resolveRecordsScopeWide`/
    /// `lookupPaths`) rather than from a bulk/discovery wire record. `standardizedRelativePath`/
    /// `standardizedFullPath` are passed as the raw `relativePath`/`fullPath` constructor
    /// arguments -- verified safe (D-13): `WorkspaceFileRecord`/`WorkspaceFolderRecord`
    /// standardize those fields internally and idempotently, and no call site of a
    /// fact-reconstructed record reads its raw (non-standardized) fields. `nil` when the fact
    /// reports the id/path as absent, or is missing a field a live record always carries.
    static func workspaceFileRecord(id: UUID, fact: CoreInventoryRecordFact) -> WorkspaceFileRecord? {
        guard fact.exists,
              let rootID = fact.rootID,
              let relativePath = fact.standardizedRelativePath,
              let fullPath = fact.standardizedFullPath,
              let name = fact.name
        else { return nil }
        return WorkspaceFileRecord(
            id: id,
            rootID: rootID,
            name: name,
            relativePath: relativePath,
            fullPath: fullPath,
            parentFolderID: denormalizedParentFolderID(fact.parentFolderID, rootID: rootID),
            modificationDate: fact.modificationDate
        )
    }

    static func workspaceFolderRecord(id: UUID, fact: CoreInventoryRecordFact) -> WorkspaceFolderRecord? {
        guard fact.exists,
              let rootID = fact.rootID,
              let relativePath = fact.standardizedRelativePath,
              let fullPath = fact.standardizedFullPath,
              let name = fact.name
        else { return nil }
        return WorkspaceFolderRecord(
            id: id,
            rootID: rootID,
            name: name,
            relativePath: relativePath,
            fullPath: fullPath,
            parentFolderID: denormalizedParentFolderID(fact.parentFolderID, rootID: rootID),
            modificationDate: fact.modificationDate
        )
    }
}
