//! P4-3b: the per-root path search index, constructed *inside* `InventoryScope` from the scope's
//! own published generation state -- the index orchestration above the already-ported engine
//! (`pathsearch::{PathSearchIndex, projected_find}`, reused unchanged).
//!
//! Port of `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift`'s
//! orchestration layer (`:320-1478`; the C-engine wrapper and its Rust port at `:10-266` already
//! landed as `pathsearch::index`/`engine`/`glob` in P3-3 slice 2b phase 2, per §4.4.1 of
//! `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md`):
//!
//! - `overlay_history`: `WorkspacePathSearchOverlayHistory<Payload>`.
//! - `materialized`: `WorkspaceSearchRootPathIndex`'s `.full` / `.overlay` / `.reused` shape.
//! - `projected`: `WorkspaceProjectedPathSearchIndex` (the `.projectedReuse` shape) -- ported with
//!   one flagged, documented deviation; see that module's doc comment.
//!
//! **The structural invariant (design §4.1.0 / §4.4.1, P4-3b's done-when):** the index is
//! constructed from a generation's own already-computed entries plus the *previous* generation's
//! published index (both scope-internal), never from a caller-supplied table. `RootPathIndex::full`
//! and `RootPathIndex::applying_patch` are the only two builders, and both take an entries slice
//! (a list, the generation's own output) -- never a `HashMap`/files-by-id-shaped parameter. The
//! `path_index_builders_take_no_table_shaped_parameter` test below pins the exact signatures at
//! compile time so a future change that adds one fails to build.
//!
//! **Wiring to the P4-3a state machine (build-kind -> scope trigger):**
//!
//! | Swift `BuildKind` | Rust trigger |
//! |---|---|
//! | `.full` | `state_machine::rebuild_generation` (authoritative rebuild: cold start, `FullResync`, `UnsafeOrAmbiguousBatch`, `PatchThresholdExceeded`, `PatchApplicationBackstop` retry) |
//! | `.overlay` | `state_machine::attempt_patch` succeeds with a non-empty `patch.path_index_changed_file_ids` |
//! | `.reused` | `state_machine::attempt_patch` succeeds with an empty `patch.path_index_changed_file_ids` (the patch touched nothing search-relevant, e.g. a folder-only mutation) |
//! | `.projectedReuse` | preserved by `attempt_patch` whenever the *previous* generation's index is already `.projectedReuse` **and** the delta's changed file ids resolve exactly to a set of relative paths (mirrors `WorkspaceSearchRootPathIndex.applyingPatch`'s `if let projectedIndex` branch); the *construction* trigger is out of scope here -- see `projected`'s module doc comment |

mod materialized;
mod overlay_history;
mod projected;

use std::cmp::Ordering;
use std::collections::HashSet;
use std::sync::Arc;

use crate::inventory::{
    InventorySearchCatalogEntry as Entry, InventoryUuid, compare_utf8_binary,
    search_catalog_entry_precedes,
};

pub use overlay_history::OverlayHistoryMetrics;
pub use projected::{ProjectedPathIndex, RelativePathBase};

use materialized::{MaterializedBuildKind, MaterializedPathIndex};

/// Port of `WorkspaceSearchRootPathIndex.BuildKind`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BuildKind {
    Full,
    Overlay,
    Reused,
    ProjectedReuse,
}

/// Port of `WorkspaceSearchRootPathIndex.Candidate`.
#[derive(Clone, Debug, PartialEq)]
pub struct PathIndexCandidate {
    pub entry: Entry,
    pub score: i32,
    pub tie_break_key: String,
}

/// The per-root path search index. See the module doc comment for the structural invariant and
/// the build-kind -> scope-trigger table.
#[derive(Debug)]
pub enum RootPathIndex {
    Materialized(MaterializedPathIndex),
    /// `Arc`-wrapped so the common "nothing search-relevant changed" reuse path (an empty
    /// `changed_file_ids` while the previous generation was already projected) is a pointer clone
    /// rather than a deep copy of `target_entries_by_base_index`/`entries`.
    Projected(Arc<ProjectedPathIndex>),
}

impl RootPathIndex {
    /// The `.full` build kind: a fresh index over every entry, sourced from nothing but the
    /// generation's own entries list. See the module doc comment's structural invariant.
    #[must_use]
    pub fn full(entries: &[Entry]) -> Self {
        Self::Materialized(MaterializedPathIndex::full(entries))
    }

    /// Constructs a `.projectedReuse` index directly (the deferred-construction-path deviation
    /// documented in `projected`'s module doc comment). Exposed for tests and for a future caller
    /// that wires a real seed-plan reader.
    #[must_use]
    pub fn projected(projected_index: ProjectedPathIndex) -> Self {
        Self::Projected(Arc::new(projected_index))
    }

    #[must_use]
    pub fn build_kind(&self) -> BuildKind {
        match self {
            Self::Materialized(materialized) => match materialized.build_kind {
                MaterializedBuildKind::Full => BuildKind::Full,
                MaterializedBuildKind::Overlay => BuildKind::Overlay,
                MaterializedBuildKind::Reused => BuildKind::Reused,
            },
            Self::Projected(_) => BuildKind::ProjectedReuse,
        }
    }

    /// Port of `WorkspaceSearchRootPathIndex.applyingPatch(identity:entries:changedFileIDs:)`.
    /// `entries` is the new generation's already-computed entries list; `changed_file_ids` is
    /// `InventoryCatalogShardPatch::path_index_changed_file_ids` from the same patch attempt that
    /// produced `entries` -- both scope-internal, never a caller-supplied table (see the module
    /// doc comment's structural invariant).
    ///
    /// The identity-mismatch guard the Swift method opens with (`:609-613`, "reopened root ->
    /// fresh full index") is not reproduced: `InventoryScope::attempt_patch` (`state_machine.rs`)
    /// is only ever called with `root.published` from the *same* `RootState`, whose
    /// `root_lifetime` is fixed for the state's whole life (a reopen always mints a fresh
    /// `RootState` with no `published` generation at all, per `scope.rs::open_root`) -- so that
    /// branch is unreachable from this crate's only call site and is omitted rather than ported
    /// as dead code.
    #[must_use]
    pub fn applying_patch(
        &self,
        entries: &[Entry],
        changed_file_ids: &HashSet<InventoryUuid>,
    ) -> Self {
        match self {
            Self::Materialized(materialized) => {
                Self::Materialized(materialized.applying_patch(entries, changed_file_ids))
            }
            Self::Projected(projected) => {
                if changed_file_ids.is_empty() {
                    return Self::Projected(Arc::clone(projected));
                }
                // Port of `:638-652`: resolve the touched file ids to relative paths using both
                // the previous generation's entries and the new ones; if the ids don't resolve
                // exactly (some id present in neither), fall back to a full rebuild rather than
                // risk an inconsistent projected patch.
                let mut changed_relative_paths: HashSet<String> = HashSet::new();
                let mut resolved_file_ids: HashSet<InventoryUuid> = HashSet::new();
                for previous in &projected.entries {
                    if changed_file_ids.contains(&previous.id) {
                        changed_relative_paths.insert(previous.standardized_relative_path.clone());
                        resolved_file_ids.insert(previous.id);
                    }
                }
                for current in entries {
                    if changed_file_ids.contains(&current.id) {
                        changed_relative_paths.insert(current.standardized_relative_path.clone());
                        resolved_file_ids.insert(current.id);
                    }
                }
                if &resolved_file_ids != changed_file_ids {
                    return Self::full(entries);
                }
                match projected.applying_patch(entries, &changed_relative_paths) {
                    Some(next) => Self::Projected(Arc::new(next)),
                    None => Self::full(entries),
                }
            }
        }
    }

    #[must_use]
    pub fn search(&self, query: &str, limit: usize) -> Vec<PathIndexCandidate> {
        match self {
            Self::Materialized(materialized) => materialized.search(query, limit),
            Self::Projected(projected) => projected.search(query, limit),
        }
    }

    #[must_use]
    pub fn overlay_history_metrics_for_testing(&self) -> OverlayHistoryMetrics {
        match self {
            Self::Materialized(materialized) => materialized.overlay_history.metrics_for_testing(),
            Self::Projected(projected) => projected.overlay_history_metrics_for_testing(),
        }
    }

    #[must_use]
    pub fn projected_accumulated_changed_path_count(&self) -> Option<usize> {
        match self {
            Self::Materialized(_) => None,
            Self::Projected(projected) => Some(projected.accumulated_changed_relative_path_count),
        }
    }
}

/// Port of `WorkspaceSearchCatalogEntry.pathSearchIndexKey` (`:1472-1478`, verbatim): pure
/// concatenation of two already-Swift/Rust-produced strings with a literal `\n` separator -- no
/// path standardization happens here (§4.2's constraint; see the design's §4.4.1 "index key does
/// not collide" subsection).
pub(super) fn path_search_index_key(entry: &Entry) -> String {
    format!("{}\n{}", entry.display_path, entry.standardized_full_path)
}

/// Shared k-way merge by `candidate_precedes`, used by both `MaterializedPathIndex::search` and
/// `ProjectedPathIndex::search` (Swift ports the identical algorithm twice -- inline in
/// `WorkspaceSearchRootPathIndex.search` at `:733-756` and factored out as
/// `WorkspaceProjectedPathSearchIndex.merge` at `:1432-1457` -- this is the one piece safe to
/// share, since it operates only on already-produced candidate lists and does not touch either
/// type's own suppression/overfetch bookkeeping, which do differ and are NOT shared).
pub(super) fn merge_candidate_lists(
    candidate_lists: Vec<Vec<PathIndexCandidate>>,
    limit: usize,
) -> Vec<PathIndexCandidate> {
    let mut offsets = vec![0usize; candidate_lists.len()];
    let mut results = Vec::with_capacity(limit);
    while results.len() < limit {
        let mut best_list_index: Option<usize> = None;
        for (list_index, list) in candidate_lists.iter().enumerate() {
            if offsets[list_index] >= list.len() {
                continue;
            }
            match best_list_index {
                None => best_list_index = Some(list_index),
                Some(current_best) => {
                    if candidate_precedes(
                        &candidate_lists[list_index][offsets[list_index]],
                        &candidate_lists[current_best][offsets[current_best]],
                    ) {
                        best_list_index = Some(list_index);
                    }
                }
            }
        }
        let Some(best_list_index) = best_list_index else {
            break;
        };
        results.push(candidate_lists[best_list_index][offsets[best_list_index]].clone());
        offsets[best_list_index] += 1;
    }
    results
}

/// Verified-equivalent port of both `WorkspaceSearchRootPathIndex.candidatePrecedes` (`:809-820`)
/// and `WorkspaceProjectedPathSearchIndex.candidatePrecedes` (`:1459-1469`): descending score, then
/// ascending `compareUTF8Binary` tie-break key, then `WorkspaceInventoryOrdering
/// .searchCatalogEntryPrecedes` on the entry itself. The two Swift methods are spelled slightly
/// differently (one falls out of a `switch`'s `.orderedSame` case via `break`, the other returns
/// from inside it) but compute the identical result, so this single function serves both search
/// paths -- unlike the overfetch/suppression math in `materialized.rs`/`projected.rs`, which is
/// deliberately NOT shared (see those modules' comments).
fn candidate_precedes(lhs: &PathIndexCandidate, rhs: &PathIndexCandidate) -> bool {
    if lhs.score != rhs.score {
        return lhs.score > rhs.score;
    }
    match compare_utf8_binary(&lhs.tie_break_key, &rhs.tie_break_key) {
        Ordering::Less => true,
        Ordering::Greater => false,
        Ordering::Equal => search_catalog_entry_precedes(&lhs.entry, &rhs.entry),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Structural pin (P4-3b done-when): the index builders take no table-shaped input parameter.
    /// If `RootPathIndex::full` or `RootPathIndex::applying_patch` ever grow a
    /// `HashMap`/files-by-id-shaped parameter, this coercion stops compiling -- a compile-time,
    /// not runtime, enforcement of the design §4.1.0 invariant.
    #[test]
    fn path_index_builders_take_no_table_shaped_parameter() {
        let _full: fn(&[Entry]) -> RootPathIndex = RootPathIndex::full;
        let _applying_patch: fn(
            &RootPathIndex,
            &[Entry],
            &HashSet<InventoryUuid>,
        ) -> RootPathIndex = RootPathIndex::applying_patch;
    }
}
