//! `inventoryQuery` domain logic (contract doc §5.3/§6, design §5.3/§6.1). Pure functions over
//! `&RootState`; `scope.rs` supplies the lock acquisition around them.
//!
//! Two haystack variants (contract doc §6):
//!
//! - [`QueryHaystackVariant::IndexKey`] (the default): reuses the per-root
//!   [`super::path_index::RootPathIndex`] built by P4-3b, whose subject text is
//!   `path_search_index_key` (`displayPath` + `\n` + `standardizedFullPath`). O(log n)-ish via the
//!   already-built index; no per-query index construction.
//! - [`QueryHaystackVariant::Suggestion`]: the `AgentFileTagSuggestionService` seam (P4-7a,
//!   design doc §5.1). Composes, per entry, exactly Swift's `searchHaystack(for:lookupContext:)`
//!   (`AgentFileTagSuggestionService.swift:129-141`): `[logicalPath, entry.displayPath, name,
//!   standardizedRelativePath, standardizedFullPath]`, each component trimmed
//!   (ASCII/Unicode-whitespace, matching Swift's `.whitespacesAndNewlines` closely enough that no
//!   reachable path component distinguishes them -- see `run_suggestion_query`'s doc comment) and
//!   dropped if empty after trimming, then joined with `\n` -- never an unconditional fixed-arity
//!   join. `entry.display_path` is the entry's own *stored* default composition
//!   (`InventorySearchCatalogEntry::new`, byte-exact port of `WorkspaceSearchCatalogEntry`'s
//!   default init), not `request.prefix.display_path(...)` -- every catalog-entry construction
//!   site in Swift passes `displayPath: nil`, so the two are equal in every reachable case, and
//!   using the stored field removes any dependency on the caller supplying a `prefix` that
//!   happens to reduce to the same composition. `logicalPath` comes from
//!   `request.logical_prefix: Option<QueryPrefix>` -- `None` when the caller has no worktree
//!   binding projection (matching Swift's `compactMap` drop of a `nil` `logicalPath`), `Some` when
//!   it does; the Rust side never re-derives physical->logical binding policy, it only
//!   concatenates the Swift-computed prefix (parent §4.2's rule, restated for the logical pair).
//!   `request.prefix` is `.IndexKey`-only for this variant -- see the module's tests for an
//!   executable pin. This variant matches with an ad hoc `PathSearchIndex` built over the composed
//!   haystacks for this call: the whole computation stays server-side (no per-row payload crosses
//!   the FFI for a query that doesn't match, the win §6.3 of the design credits to this call), but
//!   it does not yet reuse a persistent per-root haystack-variant index the way `.IndexKey` does --
//!   design §5.2 decides against building one at P4-7a and names the escalation branch if the
//!   mention-path SLO requires it.

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
            format!(
                "{}{}",
                self.non_empty_relative_prefix, standardized_relative_path
            )
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct InventoryQueryRequest {
    pub pattern: String,
    pub limit: usize,
    pub haystack_variant: QueryHaystackVariant,
    pub prefix: QueryPrefix,
    /// The `.Suggestion` variant's logical-path prefix pair (design §5.1's `logicalPath`
    /// component), `None` when the caller has no worktree binding projection. `.IndexKey` never
    /// reads this field. Not yet threaded onto the wire (P4-7a phase a1 is domain-logic-only, per
    /// design §3's slice split) -- `api.rs`'s decode passes `None` until phase a3.
    pub logical_prefix: Option<QueryPrefix>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct InventoryQueryCandidate {
    pub entry: InventorySearchCatalogEntry,
    pub display_path: String,
    /// The matched subject string (P4-7b §4.2): `.IndexKey` carries
    /// `PathIndexCandidate::tie_break_key` unchanged (the index's own `path_search_index_key`
    /// composition); `.Suggestion` carries `PathSearchMatch::tie_break_key` (the composed
    /// suggestion haystack). Not derivable from `display_path` client-side -- see the wire's
    /// `QueryCandidateRow::tie_break_key` doc comment.
    pub tie_break_key: String,
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
pub fn run_query(
    generation: &RootGeneration,
    request: &InventoryQueryRequest,
) -> InventoryQueryResult {
    let candidates = match request.haystack_variant {
        QueryHaystackVariant::IndexKey => generation
            .path_index
            .search(&request.pattern, request.limit)
            .into_iter()
            .map(|candidate| {
                let display_path = request
                    .prefix
                    .display_path(&candidate.entry.standardized_relative_path);
                InventoryQueryCandidate {
                    entry: candidate.entry,
                    display_path,
                    tie_break_key: candidate.tie_break_key,
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

/// Byte-exact port of Swift's `searchHaystack(for:lookupContext:)`
/// (`AgentFileTagSuggestionService.swift:129-141`): `logicalPath` first (absent when there is no
/// binding projection, exactly mirroring Swift's `compactMap` drop of a `nil` optional -- never
/// coerced to an empty string, which would wrongly survive the trim step and emit a spurious
/// leading `\n`), then `entry.display_path` (the stored default composition -- see the module doc
/// comment for why this, not `request.prefix.display_path(...)`, is the byte-exact match), then
/// `name`, `standardized_relative_path`, `standardized_full_path`. Each present component is
/// trimmed and dropped if it becomes empty, then the survivors are joined with `\n` -- Rust's
/// `str::trim()` trims Unicode `White_Space`, a strict superset-agreeing-on-ASCII of Swift's
/// `.whitespacesAndNewlines` (Zs + tab/newline/CR); no path component this crate ever sees
/// reaches the codepoints where they'd disagree, so this is deliberately not re-derived as a
/// custom trimmer (parent §4.2: no ICU/Unicode-policy work moves Rust-side).
fn suggestion_haystack(logical_path: Option<&str>, entry: &InventorySearchCatalogEntry) -> String {
    [
        logical_path,
        Some(entry.display_path.as_str()),
        Some(entry.name.as_str()),
        Some(entry.standardized_relative_path.as_str()),
        Some(entry.standardized_full_path.as_str()),
    ]
    .into_iter()
    .flatten()
    .map(str::trim)
    .filter(|component| !component.is_empty())
    .collect::<Vec<_>>()
    .join("\n")
}

/// `request.prefix` is deliberately unread here -- it is `.IndexKey`-only (see the module doc
/// comment); `suggestion_query_ignores_the_indexkey_prefix_field` below pins that as an
/// executable contract rather than a comment a future edit can silently invalidate.
fn run_suggestion_query(
    entries: &[InventorySearchCatalogEntry],
    request: &InventoryQueryRequest,
) -> Vec<InventoryQueryCandidate> {
    let display_paths: Vec<String> = entries
        .iter()
        .map(|entry| entry.display_path.clone())
        .collect();
    let haystacks: Vec<String> = entries
        .iter()
        .map(|entry| {
            let logical_path = request
                .logical_prefix
                .as_ref()
                .map(|prefix| prefix.display_path(&entry.standardized_relative_path));
            suggestion_haystack(logical_path.as_deref(), entry)
        })
        .collect();
    let index = crate::pathsearch::PathSearchIndex::new(&haystacks);
    index
        .find(&request.pattern, request.limit)
        .into_iter()
        .map(|matched| InventoryQueryCandidate {
            entry: entries[matched.index].clone(),
            display_path: display_paths[matched.index].clone(),
            tie_break_key: matched.tie_break_key,
            score: i64::from(matched.score),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inventory::{InventoryFileRecord, InventoryRootRecord, InventoryUuid};

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
        assert_eq!(
            QueryHaystackVariant::from_wire(0),
            Some(QueryHaystackVariant::IndexKey)
        );
        assert_eq!(
            QueryHaystackVariant::from_wire(1),
            Some(QueryHaystackVariant::Suggestion)
        );
        assert_eq!(QueryHaystackVariant::from_wire(2), None);
        assert_eq!(QueryHaystackVariant::IndexKey.to_wire(), 0);
        assert_eq!(QueryHaystackVariant::Suggestion.to_wire(), 1);
    }

    #[test]
    fn index_key_query_reports_the_generation_it_ran_against() {
        let lifetime =
            super::super::ids::RootLifetimeId::mint(&super::super::ids::UuidMinter::seeded(1));
        let mut generation = RootGeneration::empty([0; 16], lifetime);
        generation.generation = 7;
        let result = run_query(
            &generation,
            &InventoryQueryRequest {
                pattern: "App".to_owned(),
                limit: 10,
                haystack_variant: QueryHaystackVariant::IndexKey,
                prefix: prefix(),
                logical_prefix: None,
            },
        );
        assert_eq!(result.generation, 7);
        assert!(result.candidates.is_empty());
    }

    /// P4-7b §4.2 done-when: for `.IndexKey`, every returned candidate's `tie_break_key` is
    /// byte-identical to `path_search_index_key(entry)` -- the index's own subject-text
    /// composition -- over an adversarial entry corpus (the P3-2 corpus shape: CJK, emoji, a
    /// combining-mark row, and a root-level entry with an empty relative path). This is what
    /// makes the wire's `tie_break_key` field trustworthy as the cross-root merge's sole ordering
    /// input (§1.5 Check A) rather than something a caller could get away with reconstructing.
    #[test]
    fn index_key_query_tie_break_key_matches_the_indexs_own_subject_text_over_adversarial_entries()
    {
        use super::super::ids::{RootLifetimeId, UuidMinter};
        use super::super::path_index::{RootPathIndex, path_search_index_key};
        use crate::inventory::{InventoryFileRecord, InventoryRootRecord};
        use std::sync::Arc;

        let root = InventoryRootRecord {
            id: [0xAA; 16],
            name: "Root".to_owned(),
            standardized_full_path: "/root".to_owned(),
        };
        let files = [
            ("swift", "App.swift"),
            ("emoji", "\u{1F600}-Face.swift"),
            ("cjk", "\u{4E2D}\u{6587}.swift"),
            // A combining-mark row: "e" + COMBINING ACUTE ACCENT (U+0301), decomposed rather
            // than precomposed -- the exact shape `ordering.rs`'s canonical-equivalence
            // divergence note (§1.5 evidence index) is about.
            ("combining", "e\u{0301}-Decomposed.swift"),
            // Root-level entry: empty relative path, the branch §4.2.1's empty-pattern recon
            // and §1.5 Check A both call out by name.
            ("root-level", ""),
        ];
        let entries: Vec<InventorySearchCatalogEntry> = files
            .into_iter()
            .enumerate()
            .map(|(index, (marker, relative_path))| {
                let mut id = [0u8; 16];
                id[0] = index as u8;
                let name = if relative_path.is_empty() {
                    "Root"
                } else {
                    relative_path
                };
                let file = InventoryFileRecord {
                    id,
                    root_id: root.id,
                    name: name.to_owned(),
                    relative_path: relative_path.to_owned(),
                    standardized_relative_path: relative_path.to_owned(),
                    full_path: format!("/root/{relative_path}"),
                    standardized_full_path: format!("/root/{relative_path}"),
                    parent_folder_id: None,
                    modification_date: None,
                };
                let _ = marker;
                InventorySearchCatalogEntry::new(&file, &root)
            })
            .collect();

        let lifetime = RootLifetimeId::mint(&UuidMinter::seeded(2));
        let mut generation = RootGeneration::empty(root.id, lifetime);
        generation.generation = 1;
        generation.entries = entries.clone();
        generation.path_index = Arc::new(RootPathIndex::full(&entries));

        // A broad match-everything glob so every adversarial row is a candidate -- this test
        // pins the tie-break-key equality, not the matching engine (already parity-proven,
        // P3-3).
        let result = run_query(
            &generation,
            &InventoryQueryRequest {
                pattern: "*".to_owned(),
                limit: entries.len(),
                haystack_variant: QueryHaystackVariant::IndexKey,
                prefix: prefix(),
                logical_prefix: None,
            },
        );

        assert_eq!(
            result.candidates.len(),
            entries.len(),
            "every adversarial row must match the broad glob"
        );
        for candidate in &result.candidates {
            let expected = path_search_index_key(&candidate.entry);
            assert_eq!(
                candidate.tie_break_key, expected,
                "tie_break_key must be the index's own subject text for entry {:?}, never a \
                 caller-reconstructible approximation",
                candidate.entry.standardized_full_path
            );
        }
    }

    // ---------------------------------------------------------------------------------------
    // P4-7a phase a1 (design doc §5.1): the suggestion haystack is now a byte-exact port of
    // Swift's `searchHaystack(for:lookupContext:)`. These tests pin that against hand-computed
    // literal expected strings (not derived expressions -- an expression mirroring the
    // implementation would prove nothing) over the design's named adversarial cases: a nested
    // entry, a root-level entry (empty relative path -- mismatch #3, the `\n\n` run the old
    // unconditional `format!` produced), CJK/emoji/combining-mark rows, a worktree-bound
    // `logicalPath` (including its interaction with the root-level case), and a whitespace-only
    // component (mismatch #3's trim-then-drop half). `candidate.tie_break_key` is asserted rather
    // than a private helper's return value: for `.Suggestion`,
    // `PathSearchMatch::tie_break_key` is an owned clone of the exact haystack string that
    // matched (`pathsearch/index.rs:159`, pinned by `pathsearch::tests`), so a broad
    // match-everything glob recovers every composed haystack unmodified, exactly mirroring how
    // `index_key_query_tie_break_key_matches_the_indexs_own_subject_text_over_adversarial_entries`
    // above uses the same field for `.IndexKey`.

    fn physical_root() -> InventoryRootRecord {
        InventoryRootRecord {
            id: [0xBB; 16],
            name: "PhysRoot".to_owned(),
            standardized_full_path: "/physroot".to_owned(),
        }
    }

    /// `id_marker` distinguishes rows; `relative_path`/`name` follow the real
    /// `WorkspaceFileRecord` shape (name is the basename, not the whole relative path) so the
    /// nested-vs-root-level distinction in `InventorySearchCatalogEntry::new`'s
    /// `default_display_path` branch is actually exercised.
    fn suggestion_entry(
        id_marker: u8,
        relative_path: &str,
        name: &str,
    ) -> InventorySearchCatalogEntry {
        let root = physical_root();
        let mut id = [0u8; 16];
        id[0] = id_marker;
        let full_path = format!("/physroot/{relative_path}");
        let file = InventoryFileRecord {
            id,
            root_id: root.id,
            name: name.to_owned(),
            relative_path: relative_path.to_owned(),
            standardized_relative_path: relative_path.to_owned(),
            full_path: full_path.clone(),
            standardized_full_path: full_path,
            parent_folder_id: None,
            modification_date: None,
        };
        InventorySearchCatalogEntry::new(&file, &root)
    }

    fn suggestion_haystacks_by_id(
        entries: &[InventorySearchCatalogEntry],
        logical_prefix: Option<QueryPrefix>,
    ) -> std::collections::HashMap<InventoryUuid, String> {
        let lifetime =
            super::super::ids::RootLifetimeId::mint(&super::super::ids::UuidMinter::seeded(3));
        let mut generation = RootGeneration::empty(physical_root().id, lifetime);
        generation.generation = 1;
        generation.entries = entries.to_vec();
        let result = run_query(
            &generation,
            &InventoryQueryRequest {
                pattern: "*".to_owned(),
                limit: entries.len(),
                haystack_variant: QueryHaystackVariant::Suggestion,
                // Deliberately not the composition Swift would actually pass for `.Suggestion` --
                // proving `run_suggestion_query` never reads this field is
                // `suggestion_query_ignores_the_indexkey_prefix_field` below; every haystack test
                // uses this same garbage value so a regression that starts reading it fails *all*
                // of them, not just the dedicated one.
                prefix: QueryPrefix {
                    non_empty_relative_prefix: "GARBAGE/".to_owned(),
                    empty_relative_path_value: "GARBAGE".to_owned(),
                },
                logical_prefix,
            },
        );
        assert_eq!(
            result.candidates.len(),
            entries.len(),
            "the broad glob must match every row"
        );
        result
            .candidates
            .into_iter()
            .map(|c| (c.entry.id, c.tie_break_key))
            .collect()
    }

    #[test]
    fn suggestion_haystack_matches_swift_composition_with_no_binding_projection() {
        let nested = suggestion_entry(1, "src/App.swift", "App.swift");
        let root_level = suggestion_entry(2, "", "Root");
        // CJK / emoji / combining-mark rows (P3-2 adversarial corpus shape): none of these
        // codepoints are ASCII/Unicode whitespace, so trimming must leave them byte-identical --
        // this proves the join doesn't corrupt multi-byte UTF-8 or normalize anything.
        let emoji = suggestion_entry(3, "\u{1F600}-Face.swift", "\u{1F600}-Face.swift");
        let cjk = suggestion_entry(4, "\u{4E2D}\u{6587}.swift", "\u{4E2D}\u{6587}.swift");
        let combining = suggestion_entry(
            5,
            "e\u{0301}-Decomposed.swift",
            "e\u{0301}-Decomposed.swift",
        );
        let entries = vec![
            nested.clone(),
            root_level.clone(),
            emoji.clone(),
            cjk.clone(),
            combining.clone(),
        ];

        let haystacks = suggestion_haystacks_by_id(&entries, None);

        assert_eq!(
            haystacks[&nested.id],
            "PhysRoot/src/App.swift\nApp.swift\nsrc/App.swift\n/physroot/src/App.swift"
        );
        // Mismatch #3, closed: no `\n\n` run for the empty relative path -- the dropped-empty
        // `standardized_relative_path` component simply isn't there, not present-but-blank.
        assert_eq!(haystacks[&root_level.id], "PhysRoot\nRoot\n/physroot/");
        assert_eq!(
            haystacks[&emoji.id],
            "PhysRoot/\u{1F600}-Face.swift\n\u{1F600}-Face.swift\n\u{1F600}-Face.swift\n/physroot/\u{1F600}-Face.swift"
        );
        assert_eq!(
            haystacks[&cjk.id],
            "PhysRoot/\u{4E2D}\u{6587}.swift\n\u{4E2D}\u{6587}.swift\n\u{4E2D}\u{6587}.swift\n/physroot/\u{4E2D}\u{6587}.swift"
        );
        assert_eq!(
            haystacks[&combining.id],
            "PhysRoot/e\u{0301}-Decomposed.swift\ne\u{0301}-Decomposed.swift\ne\u{0301}-Decomposed.swift\n\
             /physroot/e\u{0301}-Decomposed.swift"
        );
    }

    /// A worktree-bound `logicalPath`, branch 1 of `ClientPathFormatter.displayPath` (solo
    /// visible logical root named "App": no prefix, empty-relative override is the root name --
    /// design §5.1's `WorkspacePathPolicyTests` extension pins that this is what
    /// `WorkspaceRootBindingProjection.projectedLogicalDisplayPath` actually produces in that
    /// configuration). Includes the root-level entry inside the bound configuration too (design
    /// §14's self-review flags exactly this intersection as the easy miss).
    #[test]
    fn suggestion_haystack_matches_swift_composition_with_worktree_bound_projection() {
        let nested = suggestion_entry(1, "src/App.swift", "App.swift");
        let root_level = suggestion_entry(2, "", "Root");
        let entries = vec![nested.clone(), root_level.clone()];
        let logical_prefix = QueryPrefix {
            non_empty_relative_prefix: String::new(),
            empty_relative_path_value: "App".to_owned(),
        };

        let haystacks = suggestion_haystacks_by_id(&entries, Some(logical_prefix));

        // `logicalPath` ends up byte-identical to `standardizedRelativePath` in this branch --
        // Swift does not dedupe (only `filter { !$0.isEmpty }`), so neither must Rust. Position-
        // sensitive matching means this duplication is load-bearing, not redundant.
        assert_eq!(
            haystacks[&nested.id],
            "src/App.swift\nPhysRoot/src/App.swift\nApp.swift\nsrc/App.swift\n/physroot/src/App.swift"
        );
        assert_eq!(haystacks[&root_level.id], "App\nPhysRoot\nRoot\n/physroot/");
    }

    /// Isolated fixture (a direct struct literal, not `InventorySearchCatalogEntry::new`) so the
    /// trim-then-drop behavior is provable independent of realistic path construction: two
    /// components are whitespace-only and must vanish entirely (not survive as an empty string),
    /// while the two components with real content plus surrounding whitespace must survive
    /// trimmed.
    #[test]
    fn suggestion_haystack_trims_and_drops_whitespace_only_components() {
        let entry = InventorySearchCatalogEntry {
            id: [0xCC; 16],
            root_id: [0xBB; 16],
            root_path: "/physroot".to_owned(),
            root_name: "PhysRoot".to_owned(),
            name: "  ".to_owned(),
            relative_path: "  ".to_owned(),
            standardized_relative_path: "  ".to_owned(),
            full_path: "/physroot/  ".to_owned(),
            standardized_full_path: "/physroot/  ".to_owned(),
            display_path: "Root/  ".to_owned(),
        };
        let entries = vec![entry.clone()];

        let haystacks = suggestion_haystacks_by_id(&entries, None);

        assert_eq!(haystacks[&entry.id], "Root/\n/physroot/");
    }

    /// `request.prefix` is `.IndexKey`-only (module doc comment); this pins that as an executable
    /// contract so a future edit that starts reading it in `run_suggestion_query` fails a test
    /// instead of silently reintroducing the ambiguous-root-composition mismatch §1.5 Check A
    /// describes for the *response* `display_path`.
    #[test]
    fn suggestion_query_ignores_the_indexkey_prefix_field() {
        let entries = vec![suggestion_entry(1, "src/App.swift", "App.swift")];
        let lifetime =
            super::super::ids::RootLifetimeId::mint(&super::super::ids::UuidMinter::seeded(4));
        let mut generation = RootGeneration::empty(physical_root().id, lifetime);
        generation.generation = 1;
        generation.entries = entries;

        let request_for = |prefix: QueryPrefix| InventoryQueryRequest {
            pattern: "*".to_owned(),
            limit: 10,
            haystack_variant: QueryHaystackVariant::Suggestion,
            prefix,
            logical_prefix: None,
        };
        let with_empty_prefix = run_query(&generation, &request_for(QueryPrefix::default()));
        let with_garbage_prefix = run_query(
            &generation,
            &request_for(QueryPrefix {
                non_empty_relative_prefix: "GARBAGE/".to_owned(),
                empty_relative_path_value: "GARBAGE".to_owned(),
            }),
        );

        assert_eq!(with_empty_prefix, with_garbage_prefix);
    }
}

/// P4-7a phase a2 (design doc §5.2): the per-root suggestion-index decision. The design's ruling
/// is to *not* build a second persistent per-root index at a2 -- `.Suggestion` keeps composing an
/// ad hoc `PathSearchIndex` per call -- and to make that decision falsifiable by measuring the
/// mention-path p50/p99 at 10k/100k paths, worktree-bound, cold, with a pre-agreed escalation (a
/// lazy per-root suggestion-variant index) if the registered SLO is missed.
///
/// **What this measures, and what it does not (see the module's `#[ignore]` doc comment for the
/// honesty rule this follows).** `rust/benchmarks/slo-v1.json`'s
/// `inventoryScopeV1.experiments.e2ReadEconomicsAndPayloadTruth.relativeCaps.
/// mentionSuggestionQueryAt100kMaximumReferenceRatio` is a **product-level Swift-vs-Rust ratio**
/// through the real `AgentFileTagSuggestionService` caller -- that caller does not exist yet
/// (phase a3 is the cutover) and no release-profile Swift reference capture exists for this query
/// shape. This probe is therefore a narrower, honest substitute: an **absolute, Rust-only**
/// measurement of `run_query(.Suggestion)`'s cost (ad hoc haystack composition + `PathSearchIndex`
/// build + search, the exact cost a2 is deciding whether to keep paying per call), over a
/// synthetic corpus, worktree-bound (a populated `logical_prefix`, the haystack's more expensive
/// shape). It answers "is the per-call rebuild cheap enough to keep" on its own terms; it does not
/// discharge the registered product-level criterion, which stays BLOCKED pending phase a3's real
/// caller and a release-profile Swift capture -- recorded as such in `slo-v1.json`, not silently
/// promoted to a pass.
#[cfg(test)]
mod a2_probe {
    use super::*;
    use crate::inventory::{InventoryFileRecord, InventoryRootRecord};
    use std::time::Instant;

    fn synth_entry(i: u32, root: &InventoryRootRecord) -> InventorySearchCatalogEntry {
        let mut id = [0u8; 16];
        id[0..4].copy_from_slice(&i.to_be_bytes());
        let rel = format!("src/module_{}/File_{}.swift", i % 500, i);
        let file = InventoryFileRecord {
            id,
            root_id: root.id,
            name: format!("File_{i}.swift"),
            relative_path: rel.clone(),
            standardized_relative_path: rel.clone(),
            full_path: format!("/repo/{rel}"),
            standardized_full_path: format!("/repo/{rel}"),
            parent_folder_id: None,
            modification_date: Some(1_700_000_000.0 + f64::from(i)),
        };
        InventorySearchCatalogEntry::new(&file, root)
    }

    fn percentile(sorted_micros: &[u128], percentile: usize) -> u128 {
        let rank = (sorted_micros.len() * percentile)
            .div_ceil(100)
            .saturating_sub(1);
        sorted_micros[rank.min(sorted_micros.len() - 1)]
    }

    /// Cold, worktree-bound `.Suggestion` query latency at `path_count` entries. `warmup_iterations`
    /// runs are discarded (JIT/allocator/cache warmup, matching `slo-v1.json`'s
    /// `environment.warmupIterations` convention at a scale a per-call full-index-rebuild can
    /// actually afford); `sample_iterations` runs are timed. Each sampled call still pays the full
    /// ad hoc index build -- there is no persistent index for `.Suggestion` to warm into, which is
    /// exactly the cost this probe exists to quantify.
    fn measure(
        path_count: u32,
        warmup_iterations: usize,
        sample_iterations: usize,
    ) -> (u128, u128) {
        let root = InventoryRootRecord {
            id: [7u8; 16],
            name: "PhysWorktree".to_owned(),
            standardized_full_path: "/repo".to_owned(),
        };
        let entries: Vec<_> = (0..path_count).map(|i| synth_entry(i, &root)).collect();
        let lifetime =
            super::super::ids::RootLifetimeId::mint(&super::super::ids::UuidMinter::seeded(5));
        let mut generation = RootGeneration::empty(root.id, lifetime);
        generation.generation = 1;
        generation.entries = entries;
        // Worktree-bound: branch 1 (solo visible logical root) -- design §5.1's cheapest logical
        // prefix to compute but still exercises the full five-component haystack every `.Suggestion`
        // caller composes when there IS a binding projection (the a2 done-when's named
        // configuration; a3's fallback callers are exactly those with one).
        let logical_prefix = Some(QueryPrefix {
            non_empty_relative_prefix: String::new(),
            empty_relative_path_value: "App".to_owned(),
        });
        let request = InventoryQueryRequest {
            // Matches a large, representative fraction of the synthetic corpus (any name
            // containing digit '5') rather than a best-case exact/prefix match -- same
            // representativeness rationale `WorkspaceSearchInteractiveLatencySLOTests`' "File-5"
            // pattern documents for the sibling b4 SLO.
            pattern: "5".to_owned(),
            // `AgentFileTagSuggestionService`'s own candidate-limit formula
            // (`max(maxResults * indexCandidateMultiplier, minimumIndexCandidateLimit)` with the
            // service's default `maxResults: 5`).
            limit: 64,
            haystack_variant: QueryHaystackVariant::Suggestion,
            prefix: QueryPrefix::default(),
            logical_prefix,
        };

        for _ in 0..warmup_iterations {
            std::hint::black_box(run_query(&generation, &request));
        }
        let mut micros: Vec<u128> = Vec::with_capacity(sample_iterations);
        for _ in 0..sample_iterations {
            let start = Instant::now();
            std::hint::black_box(run_query(&generation, &request));
            micros.push(Instant::now().duration_since(start).as_micros());
        }
        micros.sort_unstable();
        (percentile(&micros, 50), percentile(&micros, 99))
    }

    /// Run explicitly (release profile, this is a synthetic-corpus timing probe, not a
    /// `cargo test` default): `cargo test -p agentry-runtime --release -- --ignored --nocapture
    /// a2_mention_suggestion_query_latency_10k_and_100k_worktree_bound`.
    #[test]
    #[ignore = "synthetic-corpus timing probe; run explicitly, see module doc comment"]
    fn a2_mention_suggestion_query_latency_10k_and_100k_worktree_bound() {
        for path_count in [10_000u32, 100_000u32] {
            let (warmup, samples) = if path_count >= 100_000 {
                (5, 20)
            } else {
                (10, 50)
            };
            let (p50, p99) = measure(path_count, warmup, samples);
            eprintln!(
                "a2_mention_suggestion_query_latency: path_count={path_count} p50_us={p50} p99_us={p99} \
                 p50_ms={:.2} p99_ms={:.2}",
                p50 as f64 / 1000.0,
                p99 as f64 / 1000.0
            );
        }
    }
}
