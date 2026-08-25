//! P4-8e-a cargo contract: exact-generation multi-root capture, aligned ordered paging,
//! lifecycle invalidation, diagnostics accounting, and capture/revalidation atomicity.

use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant};

use agentry_runtime::RuntimeIdentity;
use agentry_runtime::inventory::{InventoryAppliedIndexBatchEvent, InventoryFileRecord};
use agentry_runtime::inventory_scope::{
    ComposedRootDescriptor, CompositionAccounting, InvalidationReason, InventoryDeltaCommand,
    InventoryScope, InventoryScopeConfig, InventoryScopeId, RootId, RootLifetimeId, ScopeError,
};

fn test_identity() -> RuntimeIdentity {
    RuntimeIdentity::new(1, "a".repeat(32), "b".repeat(64), "c".repeat(64)).expect("identity")
}

fn root_id(byte: u8) -> RootId {
    [byte; 16]
}

fn file(byte: u8, root_id: RootId, root_path: &str, relative_path: &str) -> InventoryFileRecord {
    InventoryFileRecord {
        id: [byte; 16],
        root_id,
        name: relative_path.to_owned(),
        relative_path: relative_path.to_owned(),
        standardized_relative_path: relative_path.to_owned(),
        full_path: format!("{root_path}/{relative_path}"),
        standardized_full_path: format!("{root_path}/{relative_path}"),
        parent_folder_id: None,
        modification_date: None,
    }
}

fn empty_event(root_id: RootId) -> InventoryAppliedIndexBatchEvent {
    InventoryAppliedIndexBatchEvent {
        root_id,
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

fn publish_files(
    scope: &InventoryScope,
    identity: &RuntimeIdentity,
    root_id: RootId,
    lifetime: RootLifetimeId,
    files: Vec<InventoryFileRecord>,
) -> u64 {
    let mut event = empty_event(root_id);
    event.upserted_files = files;
    scope
        .apply_delta(
            identity,
            InventoryDeltaCommand {
                scope_id: scope.scope_id(),
                root_id,
                root_lifetime_id: lifetime,
                watcher_accepted_watermark: None,
                requires_full_resync: false,
                expected_applied_index_generation: None,
                source: "composition-test".to_owned(),
                event,
            },
        )
        .catalog_generation
        .expect("published catalog generation")
}

fn seeded_scope(seed: u64) -> (InventoryScope, RuntimeIdentity) {
    let identity = test_identity();
    let scope = InventoryScope::new_seeded_for_testing(
        identity.clone(),
        InventoryScopeId::from_bytes([9; 16]),
        InventoryScopeConfig::default(),
        seed,
    );
    (scope, identity)
}

fn descriptor(
    root_id: RootId,
    lifetime: RootLifetimeId,
    generation: Option<u64>,
) -> ComposedRootDescriptor {
    ComposedRootDescriptor {
        root_id,
        expected_root_lifetime: lifetime,
        expected_generation: generation,
    }
}

#[test]
fn empty_and_strict_unpublished_compositions_do_not_treat_nil_as_a_wildcard() {
    let (scope, identity) = seeded_scope(1);
    let empty = scope
        .open_composed_snapshot(
            &identity,
            vec![],
            CompositionAccounting::NormalPresentation,
            "empty",
        )
        .expect("zero-root composition");
    assert!(
        scope
            .composed_snapshot_page(empty, 0, 32)
            .expect("empty page")
            .files
            .is_empty()
    );
    scope.close_composed_snapshot(empty);

    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "A".to_owned(), "/a".to_owned())
        .expect("open root");
    let unpublished = scope
        .open_composed_snapshot(
            &identity,
            vec![descriptor(root, lifetime, None)],
            CompositionAccounting::NormalPresentation,
            "unpublished",
        )
        .expect("strict unpublished root");
    assert!(
        scope
            .composed_snapshot_page(unpublished, 0, 32)
            .expect("unpublished page")
            .files
            .is_empty()
    );
    assert_eq!(
        scope
            .diagnostics(&identity)
            .expect("diagnostics")
            .single_shard_composition_reuse_count,
        1,
        "one logical empty shard preserves the historical single-shard counter"
    );
    scope.close_composed_snapshot(unpublished);

    let generation = publish_files(
        &scope,
        &identity,
        root,
        lifetime,
        vec![file(1, root, "/a", "a.swift")],
    );
    assert_eq!(
        scope.open_composed_snapshot(
            &identity,
            vec![descriptor(root, lifetime, None)],
            CompositionAccounting::NormalPresentation,
            "stale-nil",
        ),
        Err(ScopeError::GenerationMismatch)
    );
    assert_eq!(
        scope.open_composed_snapshot(
            &identity,
            vec![descriptor(root, lifetime, Some(generation + 1))],
            CompositionAccounting::NormalPresentation,
            "wrong-generation",
        ),
        Err(ScopeError::GenerationMismatch)
    );
}

#[test]
fn multi_root_composition_is_stably_sorted_aligned_and_bounded() {
    let (scope, identity) = seeded_scope(2);
    let root_b = root_id(2);
    let root_a = root_id(1);
    let lifetime_b = scope
        .open_root(&identity, root_b, "B".to_owned(), "/b".to_owned())
        .expect("open b");
    let lifetime_a = scope
        .open_root(&identity, root_a, "A".to_owned(), "/a".to_owned())
        .expect("open a");
    let generation_b = publish_files(
        &scope,
        &identity,
        root_b,
        lifetime_b,
        vec![file(2, root_b, "/b", "a.swift")],
    );
    let generation_a = publish_files(
        &scope,
        &identity,
        root_a,
        lifetime_a,
        vec![
            file(3, root_a, "/a", "z.swift"),
            file(4, root_a, "/a", "same.swift"),
        ],
    );

    let handle = scope
        .open_composed_snapshot(
            &identity,
            vec![
                descriptor(root_b, lifetime_b, Some(generation_b)),
                descriptor(root_a, lifetime_a, Some(generation_a)),
            ],
            CompositionAccounting::NormalPresentation,
            "multi-root",
        )
        .expect("compose");
    let first = scope
        .composed_snapshot_page(handle, 0, 2)
        .expect("first page");
    let second = scope
        .composed_snapshot_page(handle, 2, 2)
        .expect("second page");
    let paths: Vec<_> = first
        .files
        .iter()
        .chain(&second.files)
        .map(|file| file.standardized_full_path.as_str())
        .collect();
    assert_eq!(paths, vec!["/a/same.swift", "/a/z.swift", "/b/a.swift"]);
    assert!(
        first
            .files
            .iter()
            .zip(&first.entries)
            .chain(second.files.iter().zip(&second.entries))
            .all(|(file, entry)| {
                file.id == entry.id
                    && file.root_id == entry.root_id
                    && file.standardized_full_path == entry.standardized_full_path
            })
    );
    assert!(
        scope
            .composed_snapshot_page(handle, 3, 2)
            .expect("terminal page")
            .files
            .is_empty()
    );

    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    assert_eq!(diagnostics.generic_merge_element_visit_count, 3);
    assert_eq!(diagnostics.single_shard_composition_reuse_count, 0);
    assert_eq!(diagnostics.handles.open_count, 1);
    assert_eq!(diagnostics.handles.origin_histogram["multi-root"], 1);

    let fallback = scope
        .open_composed_snapshot(
            &identity,
            vec![
                descriptor(root_b, lifetime_b, Some(generation_b)),
                descriptor(root_a, lifetime_a, Some(generation_a)),
            ],
            CompositionAccounting::UncachedFallback,
            "multi-root-fallback",
        )
        .expect("fallback composition");
    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    assert_eq!(diagnostics.generic_merge_element_visit_count, 3);
    assert_eq!(diagnostics.single_shard_composition_reuse_count, 0);
    scope.close_composed_snapshot(fallback);
    scope.close_composed_snapshot(handle);
}

#[test]
fn duplicate_full_paths_use_uuid_then_source_order_tiebreaks() {
    let (scope, identity) = seeded_scope(22);
    let roots = [root_id(1), root_id(2), root_id(3), root_id(4)];
    let lifetimes: Vec<_> = roots
        .iter()
        .map(|root| {
            scope
                .open_root(&identity, *root, "Same".to_owned(), "/same".to_owned())
                .expect("open root")
        })
        .collect();
    let rows = [
        (9, "x.swift"),
        (1, "x.swift"),
        (7, "y.swift"),
        (7, "y.swift"),
    ];
    let generations: Vec<_> = roots
        .iter()
        .zip(&lifetimes)
        .zip(rows)
        .map(|((root, lifetime), (id_byte, relative_path))| {
            publish_files(
                &scope,
                &identity,
                *root,
                *lifetime,
                vec![file(id_byte, *root, "/same", relative_path)],
            )
        })
        .collect();

    let source_order = [0usize, 1, 3, 2];
    let handle = scope
        .open_composed_snapshot(
            &identity,
            source_order
                .iter()
                .map(|index| {
                    descriptor(roots[*index], lifetimes[*index], Some(generations[*index]))
                })
                .collect(),
            CompositionAccounting::NormalPresentation,
            "tie-order",
        )
        .expect("composition");
    let page = scope.composed_snapshot_page(handle, 0, 8).expect("page");
    assert_eq!(
        page.files.iter().map(|row| row.id[0]).collect::<Vec<_>>(),
        vec![1, 9, 7, 7],
        "UUID orders duplicate paths before source order is consulted"
    );
    assert_eq!(
        page.files.iter().map(|row| row.root_id).collect::<Vec<_>>(),
        vec![roots[1], roots[0], roots[3], roots[2]],
        "identical path and UUID rows remain stable in descriptor source order"
    );
    scope.close_composed_snapshot(handle);
}

#[test]
fn single_root_reuse_retains_the_outgoing_generation_and_fallback_is_not_counted() {
    let (scope, identity) = seeded_scope(3);
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "A".to_owned(), "/a".to_owned())
        .expect("open root");
    let generation_one = publish_files(
        &scope,
        &identity,
        root,
        lifetime,
        vec![file(1, root, "/a", "a.swift")],
    );
    let handle = scope
        .open_composed_snapshot(
            &identity,
            vec![descriptor(root, lifetime, Some(generation_one))],
            CompositionAccounting::NormalPresentation,
            "single-root",
        )
        .expect("single-root composition");
    assert_eq!(
        scope
            .composed_snapshot_page(handle, 0, 1)
            .expect("page")
            .files[0]
            .standardized_full_path,
        "/a/a.swift"
    );

    let generation_two = publish_files(
        &scope,
        &identity,
        root,
        lifetime,
        vec![file(2, root, "/a", "b.swift")],
    );
    assert_eq!(generation_two, generation_one + 1);
    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    assert_eq!(diagnostics.single_shard_composition_reuse_count, 1);
    assert_eq!(diagnostics.generic_merge_element_visit_count, 0);
    assert_eq!(
        diagnostics.roots[0].retained_topology_generations,
        vec![generation_one]
    );

    let fallback = scope
        .open_composed_snapshot(
            &identity,
            vec![descriptor(root, lifetime, Some(generation_two))],
            CompositionAccounting::UncachedFallback,
            "fallback",
        )
        .expect("fallback composition");
    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    assert_eq!(diagnostics.single_shard_composition_reuse_count, 1);
    scope.close_composed_snapshot(fallback);
    scope.close_composed_snapshot(handle);
    assert!(
        scope.diagnostics(&identity).expect("diagnostics").roots[0]
            .retained_topology_generations
            .is_empty()
    );
}

#[test]
fn duplicate_lifetime_and_lifecycle_failures_are_typed_and_handles_invalidate() {
    let (scope, identity) = seeded_scope(4);
    let root_a = root_id(1);
    let root_b = root_id(2);
    let lifetime_a = scope
        .open_root(&identity, root_a, "A".to_owned(), "/a".to_owned())
        .expect("open a");
    let lifetime_b = scope
        .open_root(&identity, root_b, "B".to_owned(), "/b".to_owned())
        .expect("open b");
    let generation_a = publish_files(
        &scope,
        &identity,
        root_a,
        lifetime_a,
        vec![file(1, root_a, "/a", "a.swift")],
    );
    let generation_b = publish_files(
        &scope,
        &identity,
        root_b,
        lifetime_b,
        vec![file(2, root_b, "/b", "b.swift")],
    );
    let descriptor_a = descriptor(root_a, lifetime_a, Some(generation_a));
    assert_eq!(
        scope.open_composed_snapshot(
            &identity,
            vec![descriptor_a, descriptor_a],
            CompositionAccounting::NormalPresentation,
            "duplicate",
        ),
        Err(ScopeError::DuplicateRoot)
    );
    assert_eq!(
        scope.open_composed_snapshot(
            &identity,
            vec![descriptor(root_a, lifetime_b, Some(generation_a))],
            CompositionAccounting::NormalPresentation,
            "wrong-lifetime",
        ),
        Err(ScopeError::LifetimeMismatch)
    );

    let handle = scope
        .open_composed_snapshot(
            &identity,
            vec![
                descriptor_a,
                descriptor(root_b, lifetime_b, Some(generation_b)),
            ],
            CompositionAccounting::NormalPresentation,
            "invalidate-root",
        )
        .expect("composition");
    scope
        .close_root(&identity, root_a, lifetime_a)
        .expect("close source root");
    assert_eq!(
        scope.composed_snapshot_page(handle, 0, 8),
        Err(InvalidationReason::RootClosed)
    );
    scope.close_composed_snapshot(handle);
    scope.close_composed_snapshot(handle);
    assert_eq!(
        scope.composed_snapshot_page(handle, 0, 8),
        Err(InvalidationReason::ScopeClosed),
        "a fully forgotten handle remains a total typed read outcome"
    );

    let handle = scope
        .open_composed_snapshot(
            &identity,
            vec![descriptor(root_b, lifetime_b, Some(generation_b))],
            CompositionAccounting::NormalPresentation,
            "invalidate-scope",
        )
        .expect("composition");
    scope.close(&identity).expect("close scope");
    assert_eq!(
        scope.composed_snapshot_page(handle, 0, 8),
        Err(InvalidationReason::ScopeClosed)
    );
}

#[test]
fn identity_invalidation_invalidates_open_handles_and_rejects_in_flight_registration() {
    let (scope, identity) = seeded_scope(40);
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "A".to_owned(), "/a".to_owned())
        .expect("open root");
    let generation = publish_files(
        &scope,
        &identity,
        root,
        lifetime,
        vec![file(1, root, "/a", "a.swift")],
    );
    let handle = scope
        .open_composed_snapshot(
            &identity,
            vec![descriptor(root, lifetime, Some(generation))],
            CompositionAccounting::NormalPresentation,
            "identity-open",
        )
        .expect("composition");
    let generation_two = publish_files(
        &scope,
        &identity,
        root,
        lifetime,
        vec![file(2, root, "/a", "b.swift")],
    );
    assert_eq!(generation_two, generation + 1);
    assert_eq!(
        scope.diagnostics(&identity).expect("diagnostics").roots[0].retained_topology_generations,
        vec![generation]
    );

    scope.invalidate_all_for_identity_change();
    assert_eq!(
        scope.composed_snapshot_page(handle, 0, 8),
        Err(InvalidationReason::IdentityChanged)
    );
    assert!(
        scope.diagnostics(&identity).expect("diagnostics").roots[0]
            .retained_topology_generations
            .is_empty(),
        "identity invalidation must release drained composed-handle retention bookkeeping"
    );

    let (race_scope, race_identity) = seeded_scope(41);
    let race_scope = Arc::new(race_scope);
    let race_root = root_id(2);
    let race_lifetime = race_scope
        .open_root(&race_identity, race_root, "B".to_owned(), "/b".to_owned())
        .expect("open root");
    let race_generation = publish_files(
        &race_scope,
        &race_identity,
        race_root,
        race_lifetime,
        vec![file(2, race_root, "/b", "b.swift")],
    );
    let barrier = Arc::new(Barrier::new(2));
    race_scope.testing_install_composition_barrier(Arc::clone(&barrier));

    let opener_scope = Arc::clone(&race_scope);
    let opener_identity = race_identity.clone();
    let opener = std::thread::spawn(move || {
        opener_scope.open_composed_snapshot(
            &opener_identity,
            vec![descriptor(race_root, race_lifetime, Some(race_generation))],
            CompositionAccounting::NormalPresentation,
            "identity-race",
        )
    });
    let deadline = Instant::now() + Duration::from_secs(2);
    while !race_scope.testing_is_parked_on_composition_barrier() {
        assert!(
            Instant::now() < deadline,
            "composition did not reach barrier"
        );
        std::thread::yield_now();
    }
    race_scope.invalidate_all_for_identity_change();
    barrier.wait();
    assert_eq!(
        opener.join().expect("opener thread"),
        Err(ScopeError::IdentityMismatch)
    );
    let diagnostics = race_scope.diagnostics(&race_identity).expect("diagnostics");
    assert_eq!(diagnostics.handles.open_count, 0);
    assert_eq!(diagnostics.single_shard_composition_reuse_count, 0);
}

#[test]
fn generation_change_between_capture_and_registration_is_rejected_without_holding_the_lock() {
    let (scope, identity) = seeded_scope(5);
    let scope = Arc::new(scope);
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "A".to_owned(), "/a".to_owned())
        .expect("open root");
    let generation = publish_files(
        &scope,
        &identity,
        root,
        lifetime,
        vec![file(1, root, "/a", "a.swift")],
    );
    let barrier = Arc::new(Barrier::new(2));
    scope.testing_install_composition_barrier(Arc::clone(&barrier));

    let opener_scope = Arc::clone(&scope);
    let opener_identity = identity.clone();
    let opener = std::thread::spawn(move || {
        opener_scope.open_composed_snapshot(
            &opener_identity,
            vec![descriptor(root, lifetime, Some(generation))],
            CompositionAccounting::NormalPresentation,
            "stale-capture",
        )
    });

    let deadline = Instant::now() + Duration::from_secs(2);
    while !scope.testing_is_parked_on_composition_barrier() {
        assert!(
            Instant::now() < deadline,
            "composition did not reach barrier"
        );
        std::thread::yield_now();
    }
    let next_generation = publish_files(
        &scope,
        &identity,
        root,
        lifetime,
        vec![file(2, root, "/a", "b.swift")],
    );
    assert_eq!(next_generation, generation + 1);
    barrier.wait();
    assert_eq!(
        opener.join().expect("opener thread"),
        Err(ScopeError::GenerationMismatch)
    );
    assert_eq!(
        scope
            .diagnostics(&identity)
            .expect("diagnostics")
            .handles
            .open_count,
        0
    );
}
