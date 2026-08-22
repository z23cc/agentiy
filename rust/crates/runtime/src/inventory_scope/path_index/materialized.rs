//! Port of `WorkspaceSearchRootPathIndex`'s materialized (non-projected) shape
//! (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift:439-821`,
//! excluding the `.projectedReuse` branches -- see `projected.rs`).
//!
//! Covers three of the four `BuildKind`s: `.full` (fresh `MaterializedBase` over every entry),
//! `.overlay` (a new immutable overlay segment appended over a shared base + history), and
//! `.reused` (share base + history unchanged; the patch touched nothing search-relevant).

use std::collections::HashSet;
use std::sync::Arc;

use crate::inventory::{InventorySearchCatalogEntry as Entry, InventoryUuid};
use crate::pathsearch::PathSearchIndex;

use super::overlay_history::OverlayHistory;
use super::{PathIndexCandidate, merge_candidate_lists, path_search_index_key};

/// Port of `WorkspaceSearchRootPathIndex.MaterializedBase`: the full entry list plus a
/// `PathSearchIndex` over `pathSearchIndexKey` for every entry.
#[derive(Debug)]
pub(super) struct MaterializedBase {
    pub entries: Vec<Entry>,
    pub index: PathSearchIndex,
}

impl MaterializedBase {
    fn new(entries: &[Entry]) -> Self {
        let keys: Vec<String> = entries.iter().map(path_search_index_key).collect();
        Self {
            entries: entries.to_vec(),
            index: PathSearchIndex::new(&keys),
        }
    }
}

/// Port of `WorkspaceSearchRootPathIndex.OverlaySegment`.
#[derive(Debug, Clone)]
pub(super) struct MaterializedOverlaySegment {
    entries: Vec<Entry>,
    index: Option<PathSearchIndex>,
    affected_entry_ids: HashSet<InventoryUuid>,
}

impl MaterializedOverlaySegment {
    fn new(entries: Vec<Entry>, affected_entry_ids: HashSet<InventoryUuid>) -> Self {
        let index = if entries.is_empty() {
            None
        } else {
            let keys: Vec<String> = entries.iter().map(path_search_index_key).collect();
            Some(PathSearchIndex::new(&keys))
        };
        Self {
            entries,
            index,
            affected_entry_ids,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum MaterializedBuildKind {
    Full,
    Overlay,
    Reused,
}

/// Port of `WorkspaceSearchRootPathIndex` restricted to the materialized (non-projected) shape.
#[derive(Debug)]
pub struct MaterializedPathIndex {
    pub(super) build_kind: MaterializedBuildKind,
    base: Arc<MaterializedBase>,
    pub(super) overlay_history: OverlayHistory<MaterializedOverlaySegment>,
}

impl MaterializedPathIndex {
    /// Port of `WorkspaceSearchRootPathIndex.init(identity:rootPath:entries:)` -- the `.full`
    /// build kind, used both for an authoritative rebuild and as the fallback whenever a patch
    /// cannot be represented as an overlay.
    pub(super) fn full(entries: &[Entry]) -> Self {
        Self {
            build_kind: MaterializedBuildKind::Full,
            base: Arc::new(MaterializedBase::new(entries)),
            overlay_history: OverlayHistory::new(),
        }
    }

    /// Port of `WorkspaceSearchRootPathIndex.applyingPatch(identity:entries:changedFileIDs:)`'s
    /// base/overlay branch (the `projectedIndex == nil` half; the projected half lives in
    /// `RootPathIndex::applying_patch`, which dispatches here only once it knows `self` is not
    /// `.projectedReuse`).
    pub(super) fn applying_patch(
        &self,
        entries: &[Entry],
        changed_file_ids: &HashSet<InventoryUuid>,
    ) -> Self {
        if changed_file_ids.is_empty() {
            return Self {
                build_kind: MaterializedBuildKind::Reused,
                base: Arc::clone(&self.base),
                overlay_history: self.overlay_history.clone(),
            };
        }
        let segment_entries: Vec<Entry> = entries
            .iter()
            .filter(|entry| changed_file_ids.contains(&entry.id))
            .cloned()
            .collect();
        let next_history = self
            .overlay_history
            .appending(MaterializedOverlaySegment::new(
                segment_entries,
                changed_file_ids.clone(),
            ));
        Self {
            build_kind: MaterializedBuildKind::Overlay,
            base: Arc::clone(&self.base),
            overlay_history: next_history,
        }
    }

    /// Port of `WorkspaceSearchRootPathIndex.search(_:limit:)`'s base/overlay branch.
    pub(super) fn search(&self, query: &str, limit: usize) -> Vec<PathIndexCandidate> {
        if limit == 0 {
            return Vec::new();
        }

        let mut candidate_lists: Vec<Vec<PathIndexCandidate>> = Vec::new();
        let mut suppressed_entry_ids: HashSet<InventoryUuid> = HashSet::new();
        self.overlay_history.visit_newest_first(|segment| {
            let bounded_segment_limit = limit.min(segment.entries.len());
            let segment_overfetch = suppressed_entry_ids
                .len()
                .min(segment.entries.len().saturating_sub(bounded_segment_limit));
            let candidates: Vec<PathIndexCandidate> = segment
                .index
                .as_ref()
                .map(|index| {
                    index
                        .find(query, bounded_segment_limit + segment_overfetch)
                        .into_iter()
                        .filter_map(|candidate| {
                            let entry = segment.entries.get(candidate.index)?;
                            if suppressed_entry_ids.contains(&entry.id) {
                                return None;
                            }
                            Some(PathIndexCandidate {
                                entry: entry.clone(),
                                score: candidate.score,
                                tie_break_key: candidate.tie_break_key,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            if !candidates.is_empty() {
                candidate_lists.push(candidates);
            }
            suppressed_entry_ids.extend(segment.affected_entry_ids.iter().copied());
        });

        let bounded_base_limit = self.base.entries.len().min(limit);
        let base_overfetch = suppressed_entry_ids
            .len()
            .min(self.base.entries.len().saturating_sub(bounded_base_limit));
        let base_candidates: Vec<PathIndexCandidate> = self
            .base
            .index
            .find(query, bounded_base_limit + base_overfetch)
            .into_iter()
            .filter_map(|candidate| {
                let entry = self.base.entries.get(candidate.index)?;
                if suppressed_entry_ids.contains(&entry.id) {
                    return None;
                }
                Some(PathIndexCandidate {
                    entry: entry.clone(),
                    score: candidate.score,
                    tie_break_key: candidate.tie_break_key,
                })
            })
            .collect();
        if !base_candidates.is_empty() {
            candidate_lists.push(base_candidates);
        }

        merge_candidate_lists(candidate_lists, limit)
    }
}
