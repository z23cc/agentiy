//! Port of `WorkspaceProjectedPathSearchIndex`'s query/patch behavior
//! (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift:823-1470`).
//!
//! **Scope deviation, flagged (see the P4-3b report):** the Swift type has two constructors. The
//! primary one (`:959-1111`) streams a `WorkspaceRootTargetSeedPlanHandle` reader plus a
//! `FileSystemSeededInventoryChangedPaths` set -- both spill-file-backed, Swift-ingress-owned
//! artifact formats (§4.2: filesystem I/O and seeded-root planning stay Swift) with no
//! representation anywhere in this cargo-only crate. The `#if DEBUG` convenience constructor
//! (`:1172-1231`) is the one this module ports instead: it takes an already-resolved
//! `changed_relative_file_paths` / `tombstoned_base_relative_file_paths` pair plus the
//! authoritative entries directly, with no seed-plan reader involved at all. **The
//! seed-plan-driven construction path is deferred** (it needs a real seed-plan reader, which
//! belongs beside the rest of the Swift ingress layer); **the query and patch behavior --
//! `applying_patch`, `search`, and the merge/tie-break ordering, which is what P4-5's shadow arm
//! actually needs to validate -- is ported in full** via this direct constructor, and is exercised
//! by this step's `BuildKind::ProjectedReuse` coverage.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::inventory::{
    InventorySearchCatalogEntry as Entry, compare_utf8_binary, standardized_relative_path,
};
use crate::pathsearch::{PathSearchIndex, ProjectedSearchOutcome};

use super::overlay_history::{OverlayHistory, OverlayHistoryMetrics};
use super::{PathIndexCandidate, merge_candidate_lists, path_search_index_key};

/// Port of `WorkspaceSearchRelativePathBase`: a `PathSearchIndex` built directly over relative
/// paths (not `pathSearchIndexKey`), consumed via `PathSearchIndex::projected_find`, which
/// composes the display/absolute-prefixed subject at scan time (`engine.rs`).
#[derive(Debug)]
pub struct RelativePathBase {
    pub relative_paths: Vec<String>,
    /// Carried for structural fidelity with the Swift type (`stableOrdinals`, used by the
    /// seed-plan-driven constructor this module defers -- see the module doc comment). Unused by
    /// the ported query/patch behavior.
    #[allow(dead_code)]
    pub stable_ordinals: Vec<u64>,
    pub index: PathSearchIndex,
}

impl RelativePathBase {
    #[must_use]
    pub fn new(relative_paths: Vec<String>, stable_ordinals: Vec<u64>) -> Self {
        debug_assert_eq!(relative_paths.len(), stable_ordinals.len());
        let relative_paths: Vec<String> = relative_paths
            .iter()
            .map(|path| standardized_relative_path(path))
            .collect();
        let index = PathSearchIndex::new(&relative_paths);
        Self {
            relative_paths,
            stable_ordinals,
            index,
        }
    }
}

#[derive(Debug, Clone)]
struct ProjectedOverlaySegment {
    entries: Vec<Entry>,
    index: Option<PathSearchIndex>,
    affected_relative_paths: HashSet<String>,
}

impl ProjectedOverlaySegment {
    fn new(entries: Vec<Entry>, affected_relative_paths: HashSet<String>) -> Self {
        let index = if entries.is_empty() {
            None
        } else {
            let keys: Vec<String> = entries.iter().map(path_search_index_key).collect();
            Some(PathSearchIndex::new(&keys))
        };
        Self {
            entries,
            index,
            affected_relative_paths,
        }
    }
}

/// Port of `WorkspaceProjectedPathSearchIndex`.
#[derive(Debug)]
pub struct ProjectedPathIndex {
    relative_base: Arc<RelativePathBase>,
    target_entries_by_base_index: Vec<Option<Entry>>,
    overlay_history: OverlayHistory<ProjectedOverlaySegment>,
    display_prefix: String,
    absolute_prefix: String,
    /// Port of the Swift type's own `entries` field: the authoritative entries as of the last
    /// construction or patch (used by `RootPathIndex::applying_patch` to resolve changed file IDs
    /// to relative paths -- see `:638-664`).
    pub(super) entries: Vec<Entry>,
    unsegmented_changed_path_count: usize,
    pub base_entry_count: usize,
    pub overlay_entry_count: usize,
    pub tombstone_count: usize,
    pub accumulated_changed_relative_path_count: usize,
}

impl ProjectedPathIndex {
    /// Port of the `#if DEBUG` convenience initializer (`:1172-1231`). See the module doc comment
    /// for why this -- not the seed-plan-driven primary initializer -- is what P4-3b ports.
    #[must_use]
    pub fn new(
        relative_base: Arc<RelativePathBase>,
        changed_relative_file_paths: &HashSet<String>,
        tombstoned_base_relative_file_paths: &HashSet<String>,
        display_prefix: String,
        absolute_prefix: String,
        authoritative_entries: &[Entry],
    ) -> Option<Self> {
        let changed: HashSet<String> = changed_relative_file_paths
            .union(tombstoned_base_relative_file_paths)
            .map(|path| standardized_relative_path(path))
            .collect();

        if !matches_prefixes(authoritative_entries, &display_prefix, &absolute_prefix) {
            return None;
        }

        let mut entries_by_relative_path: HashMap<&str, &Entry> = HashMap::new();
        for entry in authoritative_entries {
            entries_by_relative_path
                .entry(entry.standardized_relative_path.as_str())
                .or_insert(entry);
        }

        let mut targets: Vec<Option<Entry>> =
            Vec::with_capacity(relative_base.relative_paths.len());
        let mut base_relative_paths: HashSet<String> = HashSet::new();
        for relative_path in &relative_base.relative_paths {
            let standardized = standardized_relative_path(relative_path);
            base_relative_paths.insert(standardized.clone());
            if changed.contains(&standardized) {
                targets.push(None);
            } else {
                let entry = entries_by_relative_path.get(standardized.as_str())?;
                targets.push(Some((*entry).clone()));
            }
        }

        let overlay_entries: Vec<Entry> = authoritative_entries
            .iter()
            .filter(|entry| {
                changed.contains(&entry.standardized_relative_path)
                    || !base_relative_paths.contains(&entry.standardized_relative_path)
            })
            .cloned()
            .collect();
        let affected_relative_paths: HashSet<String> = changed
            .iter()
            .cloned()
            .chain(
                overlay_entries
                    .iter()
                    .map(|entry| entry.standardized_relative_path.clone()),
            )
            .collect();

        let overlay_history = if affected_relative_paths.is_empty() {
            OverlayHistory::new()
        } else {
            OverlayHistory::new().appending(ProjectedOverlaySegment::new(
                overlay_entries.clone(),
                affected_relative_paths.clone(),
            ))
        };

        let base_entry_count = targets.iter().filter(|target| target.is_some()).count();
        let overlay_entry_count = overlay_entries.len();
        let tombstone_count = targets.len() - base_entry_count;
        let accumulated_changed_relative_path_count = affected_relative_paths.len();

        Some(Self {
            relative_base,
            target_entries_by_base_index: targets,
            overlay_history,
            display_prefix,
            absolute_prefix,
            entries: authoritative_entries.to_vec(),
            unsegmented_changed_path_count: 0,
            base_entry_count,
            overlay_entry_count,
            tombstone_count,
            accumulated_changed_relative_path_count,
        })
    }

    /// Port of the private patch initializer (`:1233-1282`), reached via
    /// `WorkspaceProjectedPathSearchIndex.applyingPatch(entries:changedRelativePaths:)`.
    #[must_use]
    pub(super) fn applying_patch(
        &self,
        entries: &[Entry],
        changed_relative_paths: &HashSet<String>,
    ) -> Option<Self> {
        let changed: HashSet<String> = changed_relative_paths
            .iter()
            .map(|path| standardized_relative_path(path))
            .collect();

        if !matches_prefixes(entries, &self.display_prefix, &self.absolute_prefix) {
            return None;
        }

        let previously_segmented_paths = affected_paths_newest_first(&self.overlay_history);
        let mut next_unsegmented_changed_path_count = self.unsegmented_changed_path_count;
        for path in &changed {
            if contains_path(path, &previously_segmented_paths) {
                continue;
            }
            if let Some(base_index) =
                base_search_index_for_relative_path(path, &self.relative_base.relative_paths)
                && self.target_entries_by_base_index[base_index].is_none()
            {
                next_unsegmented_changed_path_count =
                    next_unsegmented_changed_path_count.saturating_sub(1);
            }
        }

        let segment_entries: Vec<Entry> = entries
            .iter()
            .filter(|entry| changed.contains(&entry.standardized_relative_path))
            .cloned()
            .collect();
        let next_overlay_history = self
            .overlay_history
            .appending(ProjectedOverlaySegment::new(segment_entries, changed));

        let all_affected_relative_paths = affected_paths_newest_first(&next_overlay_history);
        let base_entry_count = self
            .target_entries_by_base_index
            .iter()
            .filter_map(|target| target.as_ref())
            .filter(|entry| {
                !contains_path(
                    &entry.standardized_relative_path,
                    &all_affected_relative_paths,
                )
            })
            .count();
        let overlay_entry_count = entries.len() - base_entry_count;
        let tombstone_count = self.target_entries_by_base_index.len() - base_entry_count;
        let accumulated_changed_relative_path_count =
            next_unsegmented_changed_path_count + unique_path_count(&all_affected_relative_paths);

        Some(Self {
            relative_base: Arc::clone(&self.relative_base),
            target_entries_by_base_index: self.target_entries_by_base_index.clone(),
            overlay_history: next_overlay_history,
            display_prefix: self.display_prefix.clone(),
            absolute_prefix: self.absolute_prefix.clone(),
            entries: entries.to_vec(),
            unsegmented_changed_path_count: next_unsegmented_changed_path_count,
            base_entry_count,
            overlay_entry_count,
            tombstone_count,
            accumulated_changed_relative_path_count,
        })
    }

    /// Port of `WorkspaceProjectedPathSearchIndex.search(_:limit:)`.
    pub(super) fn search(&self, query: &str, limit: usize) -> Vec<PathIndexCandidate> {
        if limit == 0 {
            return Vec::new();
        }
        let (mut candidate_lists, suppressed_relative_paths) =
            self.overlay_candidate_lists(query, limit);

        let bounded_base_limit = self.target_entries_by_base_index.len().min(limit);
        // NOTE: overfetch here is bounded by `tombstone_count`, NOT the suppressed-path count --
        // this deliberately differs from `MaterializedPathIndex::search`'s formula (Swift
        // `:1334-1337` vs `:717-718`); do not unify the two.
        let base_overfetch = self.tombstone_count.min(
            self.target_entries_by_base_index
                .len()
                .saturating_sub(bounded_base_limit),
        );

        let outcome = self.relative_base.index.projected_find(
            query,
            &self.display_prefix,
            &self.absolute_prefix,
            bounded_base_limit + base_overfetch,
            None,
        );
        if let ProjectedSearchOutcome::Completed(matches, _) = outcome {
            let base_candidates: Vec<PathIndexCandidate> = matches
                .into_iter()
                .filter_map(|candidate_match| {
                    let entry = self
                        .target_entries_by_base_index
                        .get(candidate_match.index)?
                        .clone()?;
                    if contains_path(
                        &entry.standardized_relative_path,
                        &suppressed_relative_paths,
                    ) {
                        return None;
                    }
                    let relative_path = self
                        .relative_base
                        .relative_paths
                        .get(candidate_match.index)?;
                    let tie_break_key = format!(
                        "{}{relative_path}\n{}{relative_path}",
                        self.display_prefix, self.absolute_prefix
                    );
                    Some(PathIndexCandidate {
                        entry,
                        score: candidate_match.score,
                        tie_break_key,
                    })
                })
                .collect();
            if !base_candidates.is_empty() {
                candidate_lists.push(base_candidates);
            }
        }

        merge_candidate_lists(candidate_lists, limit)
    }

    fn overlay_candidate_lists(
        &self,
        query: &str,
        limit: usize,
    ) -> (Vec<Vec<PathIndexCandidate>>, Vec<HashSet<String>>) {
        let mut candidate_lists: Vec<Vec<PathIndexCandidate>> = Vec::new();
        let mut suppressed_relative_paths: Vec<HashSet<String>> = Vec::new();
        self.overlay_history.visit_newest_first(|segment| {
            let bounded_segment_limit = limit.min(segment.entries.len());
            // NOTE: overfetch here sums the per-segment suppressed-path counts (matching Swift
            // `:1412` exactly, including its double-counting of a path suppressed by two
            // segments) -- deliberately not the same formula as the materialized/base branches.
            let already_suppressed_count: usize =
                suppressed_relative_paths.iter().map(HashSet::len).sum();
            let segment_overfetch = already_suppressed_count
                .min(segment.entries.len().saturating_sub(bounded_segment_limit));
            let candidates: Vec<PathIndexCandidate> = segment
                .index
                .as_ref()
                .map(|index| {
                    index
                        .find(query, bounded_segment_limit + segment_overfetch)
                        .into_iter()
                        .filter_map(|candidate_match| {
                            let entry = segment.entries.get(candidate_match.index)?;
                            if contains_path(
                                &entry.standardized_relative_path,
                                &suppressed_relative_paths,
                            ) {
                                return None;
                            }
                            Some(PathIndexCandidate {
                                entry: entry.clone(),
                                score: candidate_match.score,
                                tie_break_key: candidate_match.tie_break_key,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            if !candidates.is_empty() {
                candidate_lists.push(candidates);
            }
            suppressed_relative_paths.push(segment.affected_relative_paths.clone());
        });
        (candidate_lists, suppressed_relative_paths)
    }

    pub(super) fn overlay_history_metrics_for_testing(&self) -> OverlayHistoryMetrics {
        self.overlay_history.metrics_for_testing()
    }
}

fn matches_prefixes(entries: &[Entry], display_prefix: &str, absolute_prefix: &str) -> bool {
    entries.iter().all(|entry| {
        entry.display_path == format!("{display_prefix}{}", entry.standardized_relative_path)
            && entry.standardized_full_path
                == format!("{absolute_prefix}{}", entry.standardized_relative_path)
    })
}

fn affected_paths_newest_first(
    history: &OverlayHistory<ProjectedOverlaySegment>,
) -> Vec<HashSet<String>> {
    let mut result = Vec::new();
    history.visit_newest_first(|segment| result.push(segment.affected_relative_paths.clone()));
    result
}

fn contains_path(relative_path: &str, affected_paths: &[HashSet<String>]) -> bool {
    affected_paths
        .iter()
        .any(|paths| paths.contains(relative_path))
}

/// Port of `WorkspaceProjectedPathSearchIndex.uniquePathCount(_:)` (`:1299-1312`): counts each
/// path once, attributed to its newest (smallest-index) occurrence across the newest-first segment
/// list.
fn unique_path_count(affected_paths: &[HashSet<String>]) -> usize {
    let mut result = 0usize;
    for (index, paths) in affected_paths.iter().enumerate() {
        for path in paths {
            let is_shadowed = affected_paths[..index]
                .iter()
                .any(|newer| newer.contains(path));
            if !is_shadowed {
                result += 1;
            }
        }
    }
    result
}

/// Port of `WorkspaceProjectedPathSearchIndex.baseSearchIndex(forRelativePath:relativePaths:)`
/// (`:1129-1144`): binary search over the (ascending, `compareUTF8Binary`-ordered) relative-path
/// base for an exact match.
fn base_search_index_for_relative_path(path: &str, relative_paths: &[String]) -> Option<usize> {
    let mut lower = 0usize;
    let mut upper = relative_paths.len();
    while lower < upper {
        let mid = lower + (upper - lower) / 2;
        if compare_utf8_binary(&relative_paths[mid], path) == Ordering::Less {
            lower = mid + 1;
        } else {
            upper = mid;
        }
    }
    if lower < relative_paths.len()
        && compare_utf8_binary(&relative_paths[lower], path) == Ordering::Equal
    {
        Some(lower)
    } else {
        None
    }
}
