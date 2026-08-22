//! P4-3b done-when coverage: `cargo test` over each `BuildKind` and the reuse/overlay decision
//! boundaries, wired through `InventoryScope`'s real patch/rebuild state machine; an
//! ordered-candidate differential over the adversarial query corpus (empty query, 20-term cap,
//! leading star, `**` vs `*`, duplicates, 5k-path ordering stability).
//!
//! **On the differential's shape (see the P4-3b report for why):** this phase is cargo-only, so
//! there is no live Swift process to diff against here -- that comes with P4-4/P4-5. The oracle
//! used below is `RootPathIndex::full(current_logical_entries)`, i.e. a fresh authoritative
//! rebuild over exactly the same entries the scope-driven (possibly `.overlay`/`.reused`/
//! `.projectedReuse`) index was built from. This is the property that actually matters: that the
//! incremental orchestration produces byte-identical ordered results to what a full rebuild over
//! the same logical content would produce, over the already-parity-proven engine (`pathsearch`,
//! P3-3 slice 2b phase 2, 20/20 against the live C engine). It is not a substitute for the
//! Swift-driven differential; it is the strongest form of "matches the documented contract" this
//! step can produce without one.

use std::collections::HashSet;
use std::sync::Arc;

use agentry_runtime::RuntimeIdentity;
use agentry_runtime::inventory::{
    InventoryAppliedIndexBatchEvent, InventoryFileRecord, InventoryFolderRecord,
    InventoryRootRecord, InventorySearchCatalogEntry as Entry,
};
use agentry_runtime::inventory_scope::{
    BuildKind, InventoryDeltaCommand, InventoryScope, InventoryScopeConfig, InventoryScopeId,
    PathIndexCandidate, ProjectedPathIndex, RelativePathBase, RootId, RootPathIndex,
};

// -------------------------------------------------------------------------------------------
// Fixture helpers (self-contained, matching `inventory_scope_contract.rs`'s own convention).

fn test_identity(nonce: char) -> RuntimeIdentity {
    RuntimeIdentity::new(
        1,
        nonce.to_string().repeat(32),
        "a".repeat(64),
        "b".repeat(64),
    )
    .expect("identity")
}

fn root_id(byte: u8) -> RootId {
    let mut id = [0u8; 16];
    id[15] = byte;
    id
}

fn uuid(marker: u8, byte: u16) -> [u8; 16] {
    let mut id = [0u8; 16];
    id[0] = marker;
    id[14] = (byte >> 8) as u8;
    id[15] = (byte & 0xff) as u8;
    id
}

fn root_record(root: RootId) -> InventoryRootRecord {
    InventoryRootRecord {
        id: root,
        name: "Root".to_owned(),
        standardized_full_path: "/root".to_owned(),
    }
}

fn file(id: [u8; 16], root: RootId, rel: &str) -> InventoryFileRecord {
    InventoryFileRecord {
        id,
        root_id: root,
        name: rel.to_owned(),
        relative_path: rel.to_owned(),
        standardized_relative_path: rel.to_owned(),
        full_path: format!("/root/{rel}"),
        standardized_full_path: format!("/root/{rel}"),
        parent_folder_id: None,
        modification_date: None,
    }
}

fn folder(id: [u8; 16], root: RootId, rel: &str) -> InventoryFolderRecord {
    InventoryFolderRecord {
        id,
        root_id: root,
        name: rel.to_owned(),
        relative_path: rel.to_owned(),
        standardized_relative_path: rel.to_owned(),
        full_path: format!("/root/{rel}"),
        standardized_full_path: format!("/root/{rel}"),
        parent_folder_id: None,
        modification_date: None,
    }
}

fn entry_for(file: &InventoryFileRecord, root: &InventoryRootRecord) -> Entry {
    Entry::new(file, root)
}

fn empty_event(root: RootId) -> InventoryAppliedIndexBatchEvent {
    InventoryAppliedIndexBatchEvent {
        root_id: root,
        upserted_files: vec![],
        upserted_folders: vec![],
        removed_file_ids: vec![],
        removed_folder_ids: vec![],
        removed_file_paths: vec![],
        removed_folder_paths: vec![],
        modified_file_ids: vec![],
        modified_folder_ids: vec![],
    }
}

fn seeded_scope(seed: u64) -> (InventoryScope, RuntimeIdentity) {
    seeded_scope_with_config(seed, InventoryScopeConfig::default())
}

fn seeded_scope_with_config(
    seed: u64,
    config: InventoryScopeConfig,
) -> (InventoryScope, RuntimeIdentity) {
    let identity = test_identity('a');
    let scope = InventoryScope::new_seeded_for_testing(
        identity.clone(),
        InventoryScopeId::from_bytes([1; 16]),
        config,
        seed,
    );
    (scope, identity)
}

/// Oracle for the ordered-candidate differential: a fresh `.full` rebuild over exactly the given
/// entries. See the module doc comment.
fn oracle(entries: &[Entry]) -> RootPathIndex {
    RootPathIndex::full(entries)
}

fn assert_search_matches_oracle(
    actual: &RootPathIndex,
    expected_entries: &[Entry],
    query: &str,
    limit: usize,
) {
    let expected = oracle(expected_entries).search(query, limit);
    let got = actual.search(query, limit);
    assert_eq!(
        candidate_keys(&got),
        candidate_keys(&expected),
        "query {query:?} (limit {limit}): actual != full-rebuild oracle"
    );
}

/// A space-separated AND query with exactly 21 terms: 20 real terms every fixture's entries are
/// guaranteed to match (`"root"`/`"swift"`, case-insensitively -- true of both `Root/<name>.swift`
/// display paths and `/root/<name>.swift` full paths in every fixture below), plus a 21st
/// (`"nomatchxyz"`) that is guaranteed absent. If the engine's `MAX_SPACE_TERMS = 20` cap is
/// honored, every entry still matches (term 21 is silently dropped); if it were not, nothing would
/// match. Comparing against the full-rebuild oracle alone cannot distinguish these cases -- both
/// arms call the same engine, so a broken cap would break identically on both sides and the
/// differential would pass vacuously (`[] == []`). Callers that use this in `adversarial_corpus`
/// MUST additionally assert non-vacuousness directly (see `TWENTY_TERM_AND_QUERY_LIMIT`'s
/// consumers below) -- comparing to the oracle is necessary but not sufficient for this entry.
fn twenty_term_and_query() -> String {
    let mut terms = Vec::with_capacity(21);
    for _ in 0..10 {
        terms.push("root");
        terms.push("swift");
    }
    terms.push("nomatchxyz");
    terms.join(" ")
}

fn candidate_keys(candidates: &[PathIndexCandidate]) -> Vec<([u8; 16], i32, String)> {
    candidates
        .iter()
        .map(|c| (c.entry.id, c.score, c.tie_break_key.clone()))
        .collect()
}

/// The corpus named by P4-3b's done-when: empty query, a >20-term AND query (the engine's own
/// cap), a leading-star wildcard, and a broad match-everything wildcard. (`**` vs `*` and
/// duplicates get their own dedicated tests below, since they assert *content*, not just
/// oracle-agreement.) The AND-query entry needs its own non-vacuousness assertion in every
/// consumer -- see `twenty_term_and_query`'s doc comment for why the oracle-diff alone can't prove
/// it.
fn adversarial_corpus() -> Vec<(String, usize)> {
    vec![
        (String::new(), 100),
        ("swift".to_owned(), 100),
        ("*.swift".to_owned(), 100),
        (twenty_term_and_query(), 100),
    ]
}

// -------------------------------------------------------------------------------------------
// Build-kind wiring: Swift `BuildKind` -> Rust scope trigger (see `path_index/mod.rs`'s table).

#[test]
fn build_kind_sequence_follows_the_state_machines_patch_rebuild_decisions() {
    let (scope, identity) = seeded_scope(1);
    let root = root_id(1);
    let record = root_record(root);
    let lifetime = scope
        .open_root(
            &identity,
            root,
            record.name.clone(),
            record.standardized_full_path.clone(),
        )
        .expect("open_root");

    // 1) Cold start -> MissingReusableShard fallback -> `.full`.
    let mut event = empty_event(root);
    event.upserted_files = vec![file(uuid(0xF0, 1), root, "a.swift")];
    scope.apply_delta(
        &identity,
        InventoryDeltaCommand {
            scope_id: scope.scope_id(),
            root_id: root,
            root_lifetime_id: lifetime,
            watcher_accepted_watermark: None,
            requires_full_resync: false,
            expected_applied_index_generation: None,
            source: "test".to_owned(),
            event,
        },
    );
    let index = scope
        .testing_published_path_index(root)
        .expect("published index");
    assert_eq!(index.build_kind(), BuildKind::Full);

    // 2) A single-file upsert patches cleanly with a non-empty changed-id set -> `.overlay`.
    let mut event = empty_event(root);
    event.upserted_files = vec![file(uuid(0xF0, 2), root, "b.swift")];
    scope.apply_delta(
        &identity,
        InventoryDeltaCommand {
            scope_id: scope.scope_id(),
            root_id: root,
            root_lifetime_id: lifetime,
            watcher_accepted_watermark: None,
            requires_full_resync: false,
            expected_applied_index_generation: None,
            source: "test".to_owned(),
            event,
        },
    );
    let index = scope
        .testing_published_path_index(root)
        .expect("published index");
    assert_eq!(index.build_kind(), BuildKind::Overlay);
    let overlay_metrics_after_first_overlay = index.overlay_history_metrics_for_testing();
    assert_eq!(overlay_metrics_after_first_overlay.total_payload_count(), 1);

    // 3) A folder-only upsert touches zero files -> `path_index_changed_file_ids` is empty ->
    //    `.reused`, sharing the SAME base + overlay history as step 2 (no new segment).
    let mut event = empty_event(root);
    event.upserted_folders = vec![folder(uuid(0xE0, 1), root, "dir")];
    scope.apply_delta(
        &identity,
        InventoryDeltaCommand {
            scope_id: scope.scope_id(),
            root_id: root,
            root_lifetime_id: lifetime,
            watcher_accepted_watermark: None,
            requires_full_resync: false,
            expected_applied_index_generation: None,
            source: "test".to_owned(),
            event,
        },
    );
    let index = scope
        .testing_published_path_index(root)
        .expect("published index");
    assert_eq!(index.build_kind(), BuildKind::Reused);
    assert_eq!(
        index.overlay_history_metrics_for_testing(),
        overlay_metrics_after_first_overlay,
        "reused build kind must share the previous generation's overlay history unchanged"
    );

    // 4) Another single-file upsert -> a SECOND `.overlay` segment appended over the same base.
    let mut event = empty_event(root);
    event.upserted_files = vec![file(uuid(0xF0, 3), root, "c.swift")];
    scope.apply_delta(
        &identity,
        InventoryDeltaCommand {
            scope_id: scope.scope_id(),
            root_id: root,
            root_lifetime_id: lifetime,
            watcher_accepted_watermark: None,
            requires_full_resync: false,
            expected_applied_index_generation: None,
            source: "test".to_owned(),
            event,
        },
    );
    let index = scope
        .testing_published_path_index(root)
        .expect("published index");
    assert_eq!(index.build_kind(), BuildKind::Overlay);
    assert_eq!(
        index
            .overlay_history_metrics_for_testing()
            .total_payload_count(),
        2
    );

    // 5) `requires_full_resync` forces an authoritative rebuild -> back to `.full`, history reset.
    let mut event = empty_event(root);
    event.upserted_files = vec![file(uuid(0xF0, 4), root, "d.swift")];
    scope.apply_delta(
        &identity,
        InventoryDeltaCommand {
            scope_id: scope.scope_id(),
            root_id: root,
            root_lifetime_id: lifetime,
            watcher_accepted_watermark: None,
            requires_full_resync: true,
            expected_applied_index_generation: None,
            source: "test".to_owned(),
            event,
        },
    );
    let index = scope
        .testing_published_path_index(root)
        .expect("published index");
    assert_eq!(index.build_kind(), BuildKind::Full);
    assert_eq!(
        index
            .overlay_history_metrics_for_testing()
            .total_payload_count(),
        0
    );

    // Diagnostics counters: `.full` at steps 1 and 5 -> path_index_build_count == 2; `.overlay` at
    // steps 2 and 4 -> overlay_path_index_build_count == 2; `.reused` at step 3 increments
    // neither. Mirrors Swift's `registerPublishedRootCatalogShard` switch (`:7608-7616`).
    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    let root_diagnostics = &diagnostics.roots[0];
    assert_eq!(root_diagnostics.path_index_build_count, 2);
    assert_eq!(root_diagnostics.overlay_path_index_build_count, 2);
}

// -------------------------------------------------------------------------------------------
// Ordered-candidate differential over the adversarial corpus, driven through the real scope.

#[test]
fn ordered_candidate_differential_over_adversarial_corpus_through_scope_driven_overlays() {
    let (scope, identity) = seeded_scope(2);
    let root = root_id(1);
    let record = root_record(root);
    let lifetime = scope
        .open_root(
            &identity,
            root,
            record.name.clone(),
            record.standardized_full_path.clone(),
        )
        .expect("open_root");

    let mut expected_entries: Vec<Entry> = Vec::new();
    let apply = |scope: &InventoryScope,
                 files: Vec<InventoryFileRecord>,
                 expected_entries: &mut Vec<Entry>| {
        for f in &files {
            expected_entries.retain(|e| e.id != f.id);
            expected_entries.push(entry_for(f, &record));
        }
        let mut event = empty_event(root);
        event.upserted_files = files;
        scope.apply_delta(
            &identity,
            InventoryDeltaCommand {
                scope_id: scope.scope_id(),
                root_id: root,
                root_lifetime_id: lifetime,
                watcher_accepted_watermark: None,
                requires_full_resync: false,
                expected_applied_index_generation: None,
                source: "test".to_owned(),
                event,
            },
        );
    };

    // Cold-start `.full` build over 30 files.
    let initial: Vec<InventoryFileRecord> = (0..30)
        .map(|i| file(uuid(0xF0, i), root, &format!("file{i:03}.swift")))
        .collect();
    apply(&scope, initial, &mut expected_entries);

    // Four `.overlay` patches, one file each -- exercises overlay-over-overlay merging.
    for i in 30..34 {
        apply(
            &scope,
            vec![file(uuid(0xF0, i), root, &format!("file{i:03}.swift"))],
            &mut expected_entries,
        );
    }

    let index = scope
        .testing_published_path_index(root)
        .expect("published index");
    assert_eq!(index.build_kind(), BuildKind::Overlay);

    for (query, limit) in adversarial_corpus() {
        assert_search_matches_oracle(&index, &expected_entries, &query, limit);
    }

    // Non-vacuousness check for the 20-term-cap entry (see `twenty_term_and_query`'s doc
    // comment): every entry's key contains "root" and "swift", so if the cap is honored the AND
    // query matches every entry -- a silent regression to "cap not applied" would make this zero,
    // which the oracle-diff loop above cannot distinguish from "cap applied correctly" on its own.
    let and_query_results = index.search(&twenty_term_and_query(), expected_entries.len() + 10);
    assert_eq!(and_query_results.len(), expected_entries.len());
}

// -------------------------------------------------------------------------------------------
// `**` vs `*`: crossing a `/` boundary.

#[test]
fn double_star_crosses_path_separators_single_star_does_not() {
    let root = root_id(1);
    let record = root_record(root);
    let no_slash = file(uuid(0xF0, 1), root, "aXbc.swift"); // "a", then no '/', then "bc.swift"
    let with_slash = file(uuid(0xF0, 2), root, "a/bc.swift"); // "a", then '/', then "bc.swift"
    let entries = vec![
        entry_for(&no_slash, &record),
        entry_for(&with_slash, &record),
    ];
    let index = RootPathIndex::full(&entries);

    let single_star = index.search("*a*bc.swift", 10);
    assert_eq!(
        candidate_keys(&single_star)
            .into_iter()
            .map(|(id, _, _)| id)
            .collect::<Vec<_>>(),
        vec![no_slash.id],
        "`[^/]*` between 'a' and 'bc.swift' must not cross the '/' in a/bc.swift"
    );

    let double_star = index.search("*a**bc.swift", 10);
    let mut double_star_ids: Vec<_> = candidate_keys(&double_star)
        .into_iter()
        .map(|(id, _, _)| id)
        .collect();
    double_star_ids.sort();
    let mut expected = vec![no_slash.id, with_slash.id];
    expected.sort();
    assert_eq!(
        double_star_ids, expected,
        "`.*` between 'a' and 'bc.swift' must match across the '/' too"
    );
}

// -------------------------------------------------------------------------------------------
// Duplicates: a file renamed across two overlay generations must appear exactly once, at its
// current path -- never a stale copy from a suppressed older segment.

#[test]
fn a_file_renamed_across_two_overlay_generations_appears_exactly_once_at_its_current_path() {
    let (scope, identity) = seeded_scope(3);
    let root = root_id(1);
    let record = root_record(root);
    let lifetime = scope
        .open_root(
            &identity,
            root,
            record.name.clone(),
            record.standardized_full_path.clone(),
        )
        .expect("open_root");
    let id = uuid(0xF0, 1);

    let apply_upsert = |scope: &InventoryScope, f: InventoryFileRecord| {
        let mut event = empty_event(root);
        event.upserted_files = vec![f];
        scope.apply_delta(
            &identity,
            InventoryDeltaCommand {
                scope_id: scope.scope_id(),
                root_id: root,
                root_lifetime_id: lifetime,
                watcher_accepted_watermark: None,
                requires_full_resync: false,
                expected_applied_index_generation: None,
                source: "test".to_owned(),
                event,
            },
        );
    };

    apply_upsert(&scope, file(id, root, "dup.swift")); // `.full` (cold start)
    apply_upsert(&scope, file(id, root, "dup2.swift")); // `.overlay` #1 (rename, same id)
    apply_upsert(&scope, file(id, root, "dup3.swift")); // `.overlay` #2 (rename again, same id)

    let index = scope
        .testing_published_path_index(root)
        .expect("published index");
    assert_eq!(index.build_kind(), BuildKind::Overlay);
    assert_eq!(
        index
            .overlay_history_metrics_for_testing()
            .total_payload_count(),
        2
    );

    let results = index.search("dup", 10);
    assert_eq!(
        results.len(),
        1,
        "exactly one candidate, not one per generation"
    );
    assert_eq!(results[0].entry.id, id);
    assert_eq!(results[0].entry.standardized_relative_path, "dup3.swift");
}

// -------------------------------------------------------------------------------------------
// 5k-path ordering stability: a one-shot `.full` build and a scope-driven build assembled through
// many small overlays (crossing the overlay-history compaction boundary at 17 payloads) must
// agree on order byte-for-byte.

#[test]
fn five_thousand_path_ordering_is_stable_across_full_and_incrementally_overlaid_construction() {
    const TOTAL: u16 = 5000;

    // One file per delta -- `build_root_catalog_shard_patch` only ever applies the FIRST of
    // `touchedFileIDs` per call (`builders.rs`'s own doc comment: "preserved verbatim; callers
    // must keep max_logical_mutation_count == 1 for the `.first` pick to be deterministic"), so a
    // multi-file batch with a raised threshold would silently patch only one file per batch while
    // reporting the whole batch as touched -- not a real `.overlay` shape. One file per delta is
    // the only valid way to drive many genuine `.overlay` segments, and 5000 of them crosses the
    // 17-payload compacted-page boundary ~294 times over.
    let (scope, identity) = seeded_scope(4);
    let root = root_id(1);
    let record = root_record(root);
    let lifetime = scope
        .open_root(
            &identity,
            root,
            record.name.clone(),
            record.standardized_full_path.clone(),
        )
        .expect("open_root");

    let mut expected_entries: Vec<Entry> = Vec::with_capacity(TOTAL as usize);
    for i in 0..TOTAL {
        // Deliberately non-sorted-by-insertion relative-path naming (reverse interleave) so
        // ascending-order correctness cannot be an accident of insertion order.
        let scrambled = TOTAL - 1 - i;
        let f = file(uuid(0xF0, i), root, &format!("f{scrambled:05}.swift"));
        expected_entries.push(entry_for(&f, &record));
        let mut event = empty_event(root);
        event.upserted_files = vec![f];
        scope.apply_delta(
            &identity,
            InventoryDeltaCommand {
                scope_id: scope.scope_id(),
                root_id: root,
                root_lifetime_id: lifetime,
                watcher_accepted_watermark: None,
                requires_full_resync: false,
                expected_applied_index_generation: None,
                source: "test".to_owned(),
                event,
            },
        );
    }

    let incremental_index = scope
        .testing_published_path_index(root)
        .expect("published index");
    assert_eq!(incremental_index.build_kind(), BuildKind::Overlay);

    let one_shot_index = RootPathIndex::full(&expected_entries);

    let incremental_results = incremental_index.search("swift", TOTAL as usize);
    let one_shot_results = one_shot_index.search("swift", TOTAL as usize);
    assert_eq!(incremental_results.len(), TOTAL as usize);
    assert_eq!(
        candidate_keys(&incremental_results),
        candidate_keys(&one_shot_results),
        "order must depend only on content, not on full-vs-overlaid construction history"
    );

    // Re-run against a THIRD, freshly-`.full`-built index over the same entries in a different
    // (randomized-ish, unsorted) input order, to pin that ordering never depends on insertion
    // order at all -- only on the sorted key.
    let mut reordered_entries = expected_entries.clone();
    reordered_entries.reverse();
    let reordered_index = RootPathIndex::full(&reordered_entries);
    let reordered_results = reordered_index.search("swift", TOTAL as usize);
    assert_eq!(
        candidate_keys(&reordered_results),
        candidate_keys(&one_shot_results)
    );
}

// -------------------------------------------------------------------------------------------
// `.projectedReuse`: constructed directly (see `projected.rs`'s module doc comment for the
// deferred seed-plan-reader deviation), then driven through `RootPathIndex::applying_patch`'s
// dispatch boundary -- the reuse/overlay/fallback-to-full decisions P4-3b's done-when names.

fn projected_fixture() -> (
    RootId,
    InventoryRootRecord,
    Arc<RelativePathBase>,
    Vec<Entry>,
) {
    let root = root_id(1);
    let record = root_record(root);
    let relative_paths = vec![
        "a.swift".to_owned(),
        "b.swift".to_owned(),
        "c.swift".to_owned(),
    ];
    let stable_ordinals = vec![0u64, 1u64, 2u64];
    let relative_base = Arc::new(RelativePathBase::new(relative_paths, stable_ordinals));
    let entries: Vec<Entry> = ["a.swift", "b.swift", "c.swift"]
        .iter()
        .enumerate()
        .map(|(i, rel)| entry_for(&file(uuid(0xF0, i as u16 + 1), root, rel), &record))
        .collect();
    (root, record, relative_base, entries)
}

#[test]
fn projected_reuse_search_matches_the_full_rebuild_oracle() {
    let (_, _, relative_base, entries) = projected_fixture();
    let projected = ProjectedPathIndex::new(
        relative_base,
        &HashSet::new(),
        &HashSet::new(),
        "Root/".to_owned(),
        "/root/".to_owned(),
        &entries,
    )
    .expect("projected index constructs over a consistent fixture");
    let index = RootPathIndex::projected(projected);
    assert_eq!(index.build_kind(), BuildKind::ProjectedReuse);

    for (query, limit) in adversarial_corpus() {
        assert_search_matches_oracle(&index, &entries, &query, limit);
    }

    // Non-vacuousness check for the 20-term-cap entry, same rationale as the materialized test.
    let and_query_results = index.search(&twenty_term_and_query(), entries.len() + 10);
    assert_eq!(and_query_results.len(), entries.len());
}

#[test]
fn projected_reuse_applying_patch_with_empty_changed_ids_reuses_the_same_index() {
    let (_, _, relative_base, entries) = projected_fixture();
    let projected = ProjectedPathIndex::new(
        relative_base,
        &HashSet::new(),
        &HashSet::new(),
        "Root/".to_owned(),
        "/root/".to_owned(),
        &entries,
    )
    .expect("projected index constructs");
    let index = RootPathIndex::projected(projected);

    let patched = index.applying_patch(&entries, &HashSet::new());
    assert_eq!(patched.build_kind(), BuildKind::ProjectedReuse);
    let (RootPathIndex::Projected(before), RootPathIndex::Projected(after)) = (&index, &patched)
    else {
        panic!("expected both sides to be Projected");
    };
    assert!(
        Arc::ptr_eq(before, after),
        "an empty changed-id set must reuse the SAME projected index (no rebuild)"
    );
}

#[test]
fn projected_reuse_applying_patch_with_unresolvable_changed_ids_falls_back_to_full() {
    let (root, record, relative_base, entries) = projected_fixture();
    let projected = ProjectedPathIndex::new(
        relative_base,
        &HashSet::new(),
        &HashSet::new(),
        "Root/".to_owned(),
        "/root/".to_owned(),
        &entries,
    )
    .expect("projected index constructs");
    let index = RootPathIndex::projected(projected);

    // An id present in neither the previous nor the new entries cannot be resolved to a relative
    // path -- per the dispatcher's port of Swift `:650-652`, this must fall back to `.full` rather
    // than risk an inconsistent projected patch.
    let mut unresolvable = HashSet::new();
    unresolvable.insert(uuid(0xF0, 99));
    let patched = index.applying_patch(&entries, &unresolvable);
    assert_eq!(patched.build_kind(), BuildKind::Full);
    assert_search_matches_oracle(&patched, &entries, "swift", 10);

    // A resolvable id (an entry actually present in `entries`) drives a normal patched update and
    // must stay `.projectedReuse`, not fall back.
    let mut resolvable = HashSet::new();
    resolvable.insert(entries[0].id);
    let mut updated_entries = entries.clone();
    updated_entries[0] = entry_for(&file(entries[0].id, root, "a-renamed.swift"), &record);
    let patched = index.applying_patch(&updated_entries, &resolvable);
    assert_eq!(patched.build_kind(), BuildKind::ProjectedReuse);
    assert_search_matches_oracle(&patched, &updated_entries, "renamed", 10);
    assert_search_matches_oracle(&patched, &updated_entries, "swift", 10);
}

// -------------------------------------------------------------------------------------------
// `accumulated_changed_relative_path_count`: the one piece of ported arithmetic
// (`unique_path_count`'s shadowing loop, Swift `:1299-1312`) with no other coverage above. A path
// touched by two successive patches must be counted once, attributed to its NEWEST occurrence --
// not once per patch. Hand-derived expected values (see the P4-3b report for the full trace):
// construction (no changes) -> 0; patch #1 touches {a.swift} -> 1; patch #2 touches
// {a.swift, b.swift}, where "a.swift" is already counted by patch #1 -> 2, not 3.

#[test]
fn accumulated_changed_relative_path_count_deduplicates_a_path_touched_by_two_patches() {
    let (root, record, relative_base, entries) = projected_fixture();
    let projected = ProjectedPathIndex::new(
        relative_base,
        &HashSet::new(),
        &HashSet::new(),
        "Root/".to_owned(),
        "/root/".to_owned(),
        &entries,
    )
    .expect("projected index constructs");
    let index = RootPathIndex::projected(projected);
    assert_eq!(index.projected_accumulated_changed_path_count(), Some(0));

    // Patch #1: touch only "a.swift" (same id, content changed, path unchanged so the dispatcher's
    // id->relative-path resolution is unambiguous).
    let mut changed_a = HashSet::new();
    changed_a.insert(entries[0].id);
    let mut entries_after_patch1 = entries.clone();
    entries_after_patch1[0] = entry_for(&file(entries[0].id, root, "a.swift"), &record);
    let after_patch1 = index.applying_patch(&entries_after_patch1, &changed_a);
    assert_eq!(after_patch1.build_kind(), BuildKind::ProjectedReuse);
    assert_eq!(
        after_patch1.projected_accumulated_changed_path_count(),
        Some(1)
    );

    // Patch #2: touch both "a.swift" (again -- already counted by patch #1) and "b.swift" (new).
    let mut changed_a_and_b = HashSet::new();
    changed_a_and_b.insert(entries[0].id);
    changed_a_and_b.insert(entries[1].id);
    let mut entries_after_patch2 = entries_after_patch1.clone();
    entries_after_patch2[1] = entry_for(&file(entries[1].id, root, "b.swift"), &record);
    let after_patch2 = after_patch1.applying_patch(&entries_after_patch2, &changed_a_and_b);
    assert_eq!(after_patch2.build_kind(), BuildKind::ProjectedReuse);
    assert_eq!(
        after_patch2.projected_accumulated_changed_path_count(),
        Some(2),
        "'a.swift' is touched by both patches but must be counted once, not twice"
    );
}
