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
// **Armed, not flipped, as of this commit.** `WorkspaceFileContextStore` constructs this
// adapter, subscribes it to `WorkspaceInventoryScopeAuthority.events()` (a hub-wide
// subscription, started once per store), and merges its output onto
// `republishedInventoryScopeEvents()` -- but that is a *separate* stream from
// `appliedIndexEvents()`, the one `Search/WorkspaceSearchService.swift:157` and
// `Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift:1520` actually subscribe to
// via `publishAppliedIndexEvent`. See `WorkspaceFileContextStore.startInventoryScopeRepublicationTaskIfNeeded`'s
// header comment for the two open gaps (generation-counter provenance across the Swift/Rust
// boundary; `modifiedFileSourceSnapshotsByID`'s synchronous-take lifetime under an asynchronous
// consumer) that keep the actual source flip -- "point the two consumers here, delete
// `publishAppliedIndexEvent`" -- a follow-on rather than part of this commit.
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

/// Stateful, per-scope event-stream translator (design doc §4.3). Not an actor: every consumer of
/// a `CoreInventoryScopeEventStream` already owns a single sequential drain loop (see
/// `CoreInventoryScopeEventCollector` in `CoreInventoryScopeEventsTests.swift` for the established
/// pattern), so this type's state only needs to be safe under that same one-writer-at-a-time
/// discipline -- ordinary reference-type mutation, no actor isolation needed beyond whatever
/// isolates its single caller.
final class WorkspaceInventoryScopeRepublicationAdapter {
    private let rootInfo: (UUID) async -> WorkspaceInventoryScopeRepublicationRootInfo?
    private var pendingGenerationAdvancedByRootID: [UUID: CoreInventoryGenerationAdvancedEventV1] = [:]
    private var forceResyncOnNextDeliveryByRootID: [UUID: Bool] = [:]
    private var globalGapPending = false

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
    /// (`generationAdvanced`), or is a kind neither consumer needs republished
    /// (`shardFallback`/`resnapshotRequired`/`rootPublished`/`unknown` -- `rootPublished` carries
    /// no upsert/removal payload and the consumers' resync guards only fire off a *content*
    /// event's generation, never off root-open itself).
    ///
    /// `modifiedFileSourceSnapshotsByID` is never populated here -- design doc §4.3 point 3: it is
    /// Swift-only, non-inventory state produced at a single site
    /// (`WorkspaceFileContextStore.swift`'s synthetic-modification/edit path) that never crosses
    /// the FFI. The caller merges it in afterward, keyed by the file IDs this adapter's
    /// republished `modifiedFileIDs` names -- a local join, not this adapter's concern.
    func ingest(_ event: CoreInventoryScopeEvent) async -> WorkspaceAppliedIndexBatchEvent? {
        switch event {
        case .gap:
            // Hub-wide, not per-root (§4.3: "a gap on the Rust subscription is republished as
            // requiresFullResync"): the next event delivered for *any* root cannot be trusted to
            // be gap-free, so every root's next delivery is force-resynced, not just whichever
            // root happens to publish next.
            globalGapPending = true
            return nil

        case let .generationAdvanced(advanced):
            pendingGenerationAdvancedByRootID[advanced.rootID] = advanced
            return nil

        case let .appliedIndexBatch(batch):
            let gapForcesResync = globalGapPending || (forceResyncOnNextDeliveryByRootID[batch.rootID] ?? false)
            forceResyncOnNextDeliveryByRootID[batch.rootID] = false

            guard let advanced = pendingGenerationAdvancedByRootID.removeValue(forKey: batch.rootID) else {
                // Correlation broken: this batch's own `generationAdvanced` was itself dropped
                // (or arrived before this adapter started listening). Republish anyway rather
                // than silently discard a real mutation, but force a resync -- this adapter
                // cannot vouch for a generation number it never received, and a stale/wrong
                // generation is worse than an extra resync (§4.3's own bias: the existing
                // consumer guard treats `requiresFullResync` as safe-by-construction).
                forceResyncOnNextDeliveryByRootID[batch.rootID] = false
                return await republish(
                    batch: batch, generation: 0, requiresFullResync: true,
                    globalGapPendingConsumed: false
                )
            }
            if globalGapPending { globalGapPending = false }
            return await republish(
                batch: batch,
                generation: advanced.appliedIndexGeneration,
                requiresFullResync: advanced.rebuiltAuthoritative || gapForcesResync,
                globalGapPendingConsumed: true
            )

        case let .rootUnloaded(unload):
            // Rust's root-close does not itself publish an `appliedIndexBatch` (nothing to
            // correlate); this is its own lifecycle event. Consumers only read `rootID` /
            // `isRootUnload` for the unload case (design doc §4.3's consumer table) -- no
            // itemized removal list is needed, matching what an unload republication has ever
            // needed to carry.
            let info = await rootInfo(unload.rootID)
            return WorkspaceAppliedIndexBatchEvent(
                rootID: unload.rootID,
                rootPath: info?.standardizedFullPath ?? "",
                generation: 0,
                rootLifetimeID: info?.lifetimeID,
                requiresFullResync: true,
                isRootUnload: true
            )

        case .rootPublished, .shardFallback, .resnapshotRequired, .unknown:
            return nil
        }
    }

    private func republish(
        batch: CoreInventoryAppliedIndexBatchEventV1,
        generation: UInt64,
        requiresFullResync: Bool,
        globalGapPendingConsumed: Bool
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
