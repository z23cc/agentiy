//! `inventoryQuery` domain logic (contract doc §5.3/§6, design §5.3/§6.1). Pure functions over
//! `&RootState`; `scope.rs` supplies the lock acquisition around them.
//!
//! Two haystack variants (contract doc §6):
//!
//! - [`QueryHaystackVariant::IndexKey`] (the default): reuses the per-root
//!   [`super::path_index::RootPathIndex`] built by P4-3b, whose subject text is
//!   `path_search_index_key` (`displayPath` + `\n` + `standardizedFullPath`). O(log n)-ish via the
//!   already-built index; no per-query index construction.
//! - [`QueryHaystackVariant::Suggestion`]: the `AgentFileTagSuggestionService` seam. Joins
//!   `[name, standardizedRelativePath, standardizedFullPath, displayPath]` per entry and matches
//!   with an ad hoc `PathSearchIndex` built over the composed haystacks for this call. **Flagged
//!   deviation:** the design's full haystack additionally joins a `logicalPath`
//!   (`WorkspaceRootBindingProjection.projectedLogicalDisplayPath`), which needs per-root
//!   physical->logical binding data this crate does not model at P4-4; P4-7 (the real caller
//!   cutover) is where that field and the hard-assertion result-set-and-order parity differential
//!   land, per the design's own step list. This variant still keeps the whole computation
//!   server-side -- no per-row payload crosses the FFI for a query that doesn't match, which is
//!   the win §6.3 of the design credits to this call -- but does not yet reuse a persistent
//!   per-root haystack-variant index the way `.IndexKey` does; that is a P4-7 optimization
//!   opportunity, not a P4-4 contract requirement.

use crate::inventory::InventorySearchCatalogEntry;

use super::generation::RootGeneration;
use super::handles::InvalidationReason;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QueryHaystackVariant {
    IndexKey,
    Suggestion,
}

impl QueryHaystackVariant {
    #[must_use]
    pub fn from_wire(value: u64) -> Option<Self> {
        match value {
            0 => Some(Self::IndexKey),
            1 => Some(Self::Suggestion),
            _ => None,
        }
    }

    #[must_use]
    pub const fn to_wire(self) -> u64 {
        match self {
            Self::IndexKey => 0,
            Self::Suggestion => 1,
        }
    }
}

/// The per-root display prefix contract (contract doc §6, pinned by
/// `WorkspacePathPolicyTests.testInventoryQueryDisplayPrefixCompositionMatchesClientPathFormatterAcrossAllBranchesAndEmptyRelativePath`):
/// Swift computes both the non-empty-relative-path prefix and the distinct empty-relative-path
/// override value per root; Rust never re-derives branch selection and never applies the prefix
/// unconditionally to an empty relative path.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct QueryPrefix {
    pub non_empty_relative_prefix: String,
    pub empty_relative_path_value: String,
}

impl QueryPrefix {
    #[must_use]
    pub fn display_path(&self, standardized_relative_path: &str) -> String {
        if standardized_relative_path.is_empty() {
            self.empty_relative_path_value.clone()
        } else {
            format!("{}{}", self.non_empty_relative_prefix, standardized_relative_path)
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct InventoryQueryRequest {
    pub pattern: String,
    pub limit: usize,
    pub haystack_variant: QueryHaystackVariant,
    pub prefix: QueryPrefix,
}

#[derive(Clone, Debug, PartialEq)]
pub struct InventoryQueryCandidate {
    pub entry: InventorySearchCatalogEntry,
    pub display_path: String,
    pub score: i64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct InventoryQueryResult {
    pub generation: u64,
    pub candidates: Vec<InventoryQueryCandidate>,
}

/// `inventoryQuery` is handle-based (contract doc §5.3's read plane): the caller already holds a
/// `SnapshotHandleId` opened via `inventoryOpenSnapshot`, so "no generation yet" is not a case
/// `run_query` itself models -- a handle can only ever be open against a published generation
/// (`InventoryScope::open_snapshot` rejects `NoPublishedGeneration` at open time). What `run_query`
/// cannot see is whether that handle has since been invalidated (root closed, scope closed,
/// identity changed) -- `scope.rs::query` checks that via `HandleTable::read` before calling here
/// and reports `QueryReadOutcome::HandleInvalidated` as the business outcome for that case.
#[derive(Clone, Debug, PartialEq)]
pub enum QueryReadOutcome {
    Open(InventoryQueryResult),
    HandleInvalidated { reason: InvalidationReason },
}

#[must_use]
pub fn run_query(generation: &RootGeneration, request: &InventoryQueryRequest) -> InventoryQueryResult {
    let candidates = match request.haystack_variant {
        QueryHaystackVariant::IndexKey => generation
            .path_index
            .search(&request.pattern, request.limit)
            .into_iter()
            .map(|candidate| {
                let display_path = request.prefix.display_path(&candidate.entry.standardized_relative_path);
                InventoryQueryCandidate {
                    entry: candidate.entry,
                    display_path,
                    score: i64::from(candidate.score),
                }
            })
            .collect(),
        QueryHaystackVariant::Suggestion => run_suggestion_query(&generation.entries, request),
    };
    InventoryQueryResult {
        generation: generation.generation,
        candidates,
    }
}

fn run_suggestion_query(
    entries: &[InventorySearchCatalogEntry],
    request: &InventoryQueryRequest,
) -> Vec<InventoryQueryCandidate> {
    let display_paths: Vec<String> = entries
        .iter()
        .map(|entry| request.prefix.display_path(&entry.standardized_relative_path))
        .collect();
    let haystacks: Vec<String> = entries
        .iter()
        .zip(&display_paths)
        .map(|(entry, display_path)| {
            format!(
                "{}\n{}\n{}\n{}",
                entry.name, entry.standardized_relative_path, entry.standardized_full_path, display_path
            )
        })
        .collect();
    let index = crate::pathsearch::PathSearchIndex::new(&haystacks);
    index
        .find(&request.pattern, request.limit)
        .into_iter()
        .map(|matched| InventoryQueryCandidate {
            entry: entries[matched.index].clone(),
            display_path: display_paths[matched.index].clone(),
            score: i64::from(matched.score),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prefix() -> QueryPrefix {
        QueryPrefix {
            non_empty_relative_prefix: "root/".to_owned(),
            empty_relative_path_value: "root".to_owned(),
        }
    }

    #[test]
    fn prefix_special_cases_the_empty_relative_path() {
        let prefix = prefix();
        assert_eq!(prefix.display_path(""), "root");
        assert_eq!(prefix.display_path("src/App.swift"), "root/src/App.swift");
    }

    #[test]
    fn haystack_variant_wire_round_trips() {
        assert_eq!(QueryHaystackVariant::from_wire(0), Some(QueryHaystackVariant::IndexKey));
        assert_eq!(QueryHaystackVariant::from_wire(1), Some(QueryHaystackVariant::Suggestion));
        assert_eq!(QueryHaystackVariant::from_wire(2), None);
        assert_eq!(QueryHaystackVariant::IndexKey.to_wire(), 0);
        assert_eq!(QueryHaystackVariant::Suggestion.to_wire(), 1);
    }

    #[test]
    fn index_key_query_reports_the_generation_it_ran_against() {
        let lifetime = super::super::ids::RootLifetimeId::mint(&super::super::ids::UuidMinter::seeded(1));
        let mut generation = RootGeneration::empty([0; 16], lifetime);
        generation.generation = 7;
        let result = run_query(
            &generation,
            &InventoryQueryRequest {
                pattern: "App".to_owned(),
                limit: 10,
                haystack_variant: QueryHaystackVariant::IndexKey,
                prefix: prefix(),
            },
        );
        assert_eq!(result.generation, 7);
        assert!(result.candidates.is_empty());
    }
}
