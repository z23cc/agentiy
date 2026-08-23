import Foundation

/// Port of P4-7 design doc §6.4 ("port the verdict, not the object"): a pure-Swift
/// reconciliation check of a seeded root's replayed diff (a `WorkspaceRootTargetSeedPlanHandle`
/// record stream) against a cached base snapshot (`WorkspaceRootReusableSnapshot.searchBase`) and
/// the freshly-derived authoritative entries.
///
/// This reproduces the verdict half of what `WorkspaceProjectedPathSearchIndex.init`
/// (`Search/PathSearchIndex.swift`, pre-P4-7c) used to compute as a side effect of constructing a
/// live C-engine-backed search index that was never actually searched in production -- the
/// constructed object was discarded (see the P4-6b reroute comment at
/// `WorkspaceFileContextStore.preparePendingSeededRoot`). The verdict computation itself never
/// touched the C engine: every `guard ... else { return nil }` in the ported initializer ran
/// before the object's only `PathSearchIndex` construction (the overlay segment, built purely to
/// back a search capability the discarded object's caller never used). This type carries that
/// guard chain forward, unchanged in order and condition, with no `PathSearchIndex` dependency,
/// so the self-check survives `PathSearchIndex.swift`'s P4-7c deletion.
///
/// **Why this stays Swift rather than moving to Rust, contra the design doc's literal §6.4 text.**
/// The design doc's stated rationale -- "Rust already has the projected shape" -- refers to
/// `rust/crates/runtime/src/inventory_scope/path_index/projected.rs`, whose own module doc states
/// plainly that it ports only the *query/patch* behavior of the Swift type via the `#if DEBUG`
/// convenience initializer, and explicitly defers the seed-plan-driven initializer this type
/// replaces: "the seed-plan-driven construction path is deferred -- it needs a real seed-plan
/// reader, which belongs beside the rest of the Swift ingress layer." `rg
/// 'TargetSeedPlan|plan_handle'` over `rust/` returns exactly that one comment -- zero decode
/// plumbing exists. The verdict below is fundamentally a validation *of the seed-plan record
/// stream while decoding it* (the `baseOrdinal` -> `stableOrdinals` binary search -> exact
/// relative-path match at `.baseOrdinalMismatch` below is the sharpest example -- it can only be
/// checked while walking individual plan records). Decoding that Swift-ingress-owned spill format
/// in Swift and handing Rust only the already-resolved changed/tombstoned path sets (the shape
/// Rust's `ProjectedPathIndex::new` accepts) would make Rust's participation decorative: Swift
/// would have already decided pass/fail before Rust saw anything, and the ordinal-consistency
/// check -- the one case explicitly required to survive a "deliberately corrupted replay" per
/// design §6.4 -- would be silently lost. Porting the *raw reader* to Rust instead would violate
/// design §4.2's own rule ("filesystem I/O and seeded-root planning stay Swift"). Keeping the
/// verdict in Swift is therefore not a deviation from the architecture's grain -- it is what the
/// architecture's own Swift/Rust split already requires once the C-engine dependency is the only
/// thing actually being removed. See `docs/architecture/rust-inventory-scope-v1.md` §13's P4-7c
/// amendment for the recorded decision.
enum WorkspaceSeededRootReplayDisagreementReason: Equatable {
    /// The base snapshot and the seed-plan handle were not built from the same content-addressed
    /// snapshot identity.
    case snapshotIdentityMismatch
    /// An authoritative entry's `displayPath`/`standardizedFullPath` was not exactly the root's
    /// display/absolute prefix concatenated with its `standardizedRelativePath`.
    case authoritativeEntriesPrefixMismatch
    /// The authoritative entries were not in strictly ascending `standardizedRelativePath` order.
    case authoritativeEntriesNotSorted
    /// The base snapshot's `stableOrdinals` were not in strictly ascending order.
    case baseOrdinalsNotSorted
    /// A plan record's `relativePathBytes` did not decode as UTF-8.
    case invalidRelativePathBytes
    /// An authoritative entry was skipped over while advancing to the current plan record's path,
    /// but it was not present in the caller-supplied changed-path set.
    case unexplainedAuthoritativeAddition
    /// A `.reuse` base-action plan record's `baseOrdinal` did not resolve (via binary search over
    /// the base snapshot's `stableOrdinals`) to a base index whose relative path matches the
    /// record's own path -- the plan and the base snapshot disagree about which base record this
    /// is. This is the check a corrupted-ordinal replay must trip.
    case baseOrdinalMismatch
    /// An `.overlay`/no-base-action plan record had no matching authoritative entry, and its path
    /// was not in the caller-supplied changed-path set.
    case overlayEntryMissingAndUnexplained
    /// An ordinary-file plan record's base action was `.tombstone`, which the plan format does
    /// not allow for a still-present file.
    case unexpectedTombstoneBaseAction
    /// A `.baseTombstone` plan record's path was not in the changed-path set, yet an
    /// authoritative entry still exists for it.
    case tombstoneStillHasEntry
    /// A non-file plan record (`.ordinaryDirectory`/`.policyIgnoredTrackedFile`) had a matching
    /// authoritative entry, but its path was not in the changed-path set.
    case nonFileEntryUnexplained
    /// The plan handle's reader failed to open or a record read threw.
    case planReadFailure
    /// After the plan record stream was exhausted, authoritative entries remained that were never
    /// visited and were not in the changed-path set.
    case unexplainedTrailingAuthoritativeAddition
    /// The resolved base-entry count plus overlay-entry count did not equal the authoritative
    /// entry count -- the replay's accounting does not close.
    case entryCountMismatch
}

struct WorkspaceSeededRootReplayStatistics: Equatable {
    let baseEntryCount: Int
    let overlayEntryCount: Int
    let tombstoneCount: Int
}

enum WorkspaceSeededRootReplayVerdict: Equatable {
    case agrees(WorkspaceSeededRootReplayStatistics)
    case disagrees(WorkspaceSeededRootReplayDisagreementReason)

    var statistics: WorkspaceSeededRootReplayStatistics? {
        if case let .agrees(stats) = self { return stats }
        return nil
    }

    var isAgreement: Bool {
        statistics != nil
    }
}

enum WorkspaceSeededRootReplayValidator {
    /// Faithful port of `WorkspaceProjectedPathSearchIndex.init(snapshot:planHandle:
    /// additionalChangedRelativePaths:root:authoritativeEntries:)`'s guard chain
    /// (pre-P4-7c `Search/PathSearchIndex.swift:955-1097`), minus the success-path
    /// `PathSearchIndex`/`WorkspacePathSearchOverlayHistory` construction the two call sites never
    /// read (the object was discarded by design -- see this type's doc comment).
    static func evaluate(
        snapshot: WorkspaceRootReusableSnapshot,
        planHandle: WorkspaceRootTargetSeedPlanHandle,
        additionalChangedRelativePaths: FileSystemSeededInventoryChangedPaths,
        root: WorkspaceRootRecord,
        authoritativeEntries: [WorkspaceSearchCatalogEntry]
    ) -> WorkspaceSeededRootReplayVerdict {
        guard snapshot.identity == planHandle.snapshotIdentity,
              snapshot.identity == planHandle.snapshot.identity
        else { return .disagrees(.snapshotIdentityMismatch) }

        let projectedDisplayPrefix = root.name + "/"
        let projectedAbsolutePrefix = root.standardizedFullPath + "/"

        guard authoritativeEntries.allSatisfy({ entry in
            entry.displayPath == projectedDisplayPrefix + entry.standardizedRelativePath
                && entry.standardizedFullPath == projectedAbsolutePrefix + entry.standardizedRelativePath
        }) else { return .disagrees(.authoritativeEntriesPrefixMismatch) }

        guard zip(authoritativeEntries, authoritativeEntries.dropFirst()).allSatisfy({ previous, next in
            WorkspaceInventoryOrdering.compareUTF8Binary(
                previous.standardizedRelativePath,
                next.standardizedRelativePath
            ) == .orderedAscending
        }) else { return .disagrees(.authoritativeEntriesNotSorted) }

        guard zip(snapshot.searchBase.stableOrdinals, snapshot.searchBase.stableOrdinals.dropFirst())
            .allSatisfy({ previous, next in previous < next })
        else { return .disagrees(.baseOrdinalsNotSorted) }

        let additionalChanged = additionalChangedRelativePaths
        var targets = [WorkspaceSearchCatalogEntry?](
            repeating: nil,
            count: snapshot.searchBase.relativePaths.count
        )
        var overlayEntries: [WorkspaceSearchCatalogEntry] = []
        var authoritativeIndex = 0

        do {
            let reader = try planHandle.makeReader()
            while let record = try reader.next() {
                guard let relativePath = String(data: record.relativePathBytes, encoding: .utf8) else {
                    return .disagrees(.invalidRelativePathBytes)
                }
                let standardizedRelativePath = StandardizedPath.relative(relativePath)
                while authoritativeIndex < authoritativeEntries.count,
                      WorkspaceInventoryOrdering.compareUTF8Binary(
                          authoritativeEntries[authoritativeIndex].standardizedRelativePath,
                          standardizedRelativePath
                      ) == .orderedAscending
                {
                    let addition = authoritativeEntries[authoritativeIndex]
                    guard try additionalChanged.contains(addition.standardizedRelativePath) else {
                        return .disagrees(.unexplainedAuthoritativeAddition)
                    }
                    overlayEntries.append(addition)
                    authoritativeIndex += 1
                }

                let matchedEntry: WorkspaceSearchCatalogEntry? = if authoritativeIndex < authoritativeEntries.count,
                                                                    WorkspaceInventoryOrdering.compareUTF8Binary(
                                                                        authoritativeEntries[authoritativeIndex]
                                                                            .standardizedRelativePath,
                                                                        standardizedRelativePath
                                                                    ) == .orderedSame
                {
                    authoritativeEntries[authoritativeIndex]
                } else {
                    nil
                }

                switch record.disposition {
                case .ordinaryFile:
                    switch record.baseAction {
                    case .reuse:
                        if try additionalChanged.contains(standardizedRelativePath) {
                            if let matchedEntry { overlayEntries.append(matchedEntry) }
                        } else {
                            guard let matchedEntry,
                                  let baseOrdinal = record.baseOrdinal,
                                  let baseIndex = baseSearchIndex(
                                      for: baseOrdinal,
                                      stableOrdinals: snapshot.searchBase.stableOrdinals
                                  ),
                                  snapshot.searchBase.relativePaths[baseIndex] == standardizedRelativePath
                            else { return .disagrees(.baseOrdinalMismatch) }
                            targets[baseIndex] = matchedEntry
                        }
                    case .overlay, .none:
                        guard let matchedEntry else {
                            guard try additionalChanged.contains(standardizedRelativePath) else {
                                return .disagrees(.overlayEntryMissingAndUnexplained)
                            }
                            break
                        }
                        overlayEntries.append(matchedEntry)
                    case .tombstone:
                        return .disagrees(.unexpectedTombstoneBaseAction)
                    }
                case .baseTombstone:
                    if try additionalChanged.contains(standardizedRelativePath) {
                        if let matchedEntry { overlayEntries.append(matchedEntry) }
                    } else if matchedEntry != nil {
                        return .disagrees(.tombstoneStillHasEntry)
                    }
                case .ordinaryDirectory, .policyIgnoredTrackedFile:
                    if let matchedEntry {
                        guard try additionalChanged.contains(standardizedRelativePath) else {
                            return .disagrees(.nonFileEntryUnexplained)
                        }
                        overlayEntries.append(matchedEntry)
                    }
                }
                if matchedEntry != nil { authoritativeIndex += 1 }
            }
        } catch {
            return .disagrees(.planReadFailure)
        }

        while authoritativeIndex < authoritativeEntries.count {
            let addition = authoritativeEntries[authoritativeIndex]
            guard (try? additionalChanged.contains(addition.standardizedRelativePath)) == true else {
                return .disagrees(.unexplainedTrailingAuthoritativeAddition)
            }
            overlayEntries.append(addition)
            authoritativeIndex += 1
        }

        let resolvedBaseEntryCount = targets.compactMap(\.self).count
        guard resolvedBaseEntryCount + overlayEntries.count == authoritativeEntries.count else {
            return .disagrees(.entryCountMismatch)
        }

        return .agrees(WorkspaceSeededRootReplayStatistics(
            baseEntryCount: resolvedBaseEntryCount,
            overlayEntryCount: overlayEntries.count,
            tombstoneCount: targets.count - resolvedBaseEntryCount
        ))
    }

    /// Port of `WorkspaceProjectedPathSearchIndex.baseSearchIndex(for:stableOrdinals:)`
    /// (pre-P4-7c `Search/PathSearchIndex.swift:1113-1126`): binary search over the (ascending)
    /// base snapshot's stable ordinals for an exact match.
    private static func baseSearchIndex(for ordinal: UInt64, stableOrdinals: [Int]) -> Int? {
        guard let target = Int(exactly: ordinal) else { return nil }
        var lowerBound = 0
        var upperBound = stableOrdinals.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if stableOrdinals[middle] < target {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound < stableOrdinals.count, stableOrdinals[lowerBound] == target else { return nil }
        return lowerBound
    }
}
