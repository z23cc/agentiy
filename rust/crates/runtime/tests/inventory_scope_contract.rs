//! P4-3a done-when coverage: all eight `RootCatalogShardFallbackReason` cases,
//! watermark/lifetime/generation rejections, handle lifecycle including invalidation, and
//! bulk-load atomicity + abort, exercised end-to-end through `InventoryScope`'s public API.

use agentry_runtime::RuntimeIdentity;
use agentry_runtime::inventory::{
    InventoryAppliedIndexBatchEvent, InventoryFileRecord, InventoryFolderRecord,
};
use agentry_runtime::inventory_scope::{
    HandleReadOutcome, InvalidationReason, InventoryApplyOutcome, InventoryDeltaCommand,
    InventoryPublishMode, InventoryRejectionReason, InventoryScope, InventoryScopeConfig,
    InventoryScopeId, RootCatalogShardFallbackReason, RootId, ScopeError,
};

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

fn file(byte: u8, root: RootId, rel: &str) -> InventoryFileRecord {
    let mut id = [0u8; 16];
    id[0] = 0xF0;
    id[15] = byte;
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

#[allow(dead_code)]
fn folder(byte: u8, root: RootId, rel: &str) -> InventoryFolderRecord {
    let mut id = [0u8; 16];
    id[1] = 0xE0;
    id[15] = byte;
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

fn upsert_files_command(
    scope: &InventoryScope,
    root: RootId,
    lifetime: agentry_runtime::inventory_scope::RootLifetimeId,
    files: Vec<InventoryFileRecord>,
    requires_full_resync: bool,
) -> InventoryDeltaCommand {
    let mut event = empty_event(root);
    event.upserted_files = files;
    InventoryDeltaCommand {
        scope_id: scope.scope_id(),
        root_id: root,
        root_lifetime_id: lifetime,
        watcher_accepted_watermark: None,
        requires_full_resync,
        expected_applied_index_generation: None,
        source: "test".to_owned(),
        event,
    }
}

fn seeded_scope(seed: u64, config: InventoryScopeConfig) -> (InventoryScope, RuntimeIdentity) {
    let identity = test_identity('a');
    let scope = InventoryScope::new_seeded_for_testing(
        identity.clone(),
        InventoryScopeId::from_bytes([1; 16]),
        config,
        seed,
    );
    (scope, identity)
}

// ---------------------------------------------------------------------------------------------
// Fallback reason 1/8: missingReusableShard -- first delta against a root with no published
// generation must rebuild, not patch.
#[test]
fn missing_reusable_shard_triggers_rebuild_on_first_delta() {
    let (scope, identity) = seeded_scope(1, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");

    let command = upsert_files_command(
        &scope,
        root,
        lifetime,
        vec![file(1, root, "a.swift")],
        false,
    );
    let receipt = scope.apply_delta(&identity, command);
    assert_eq!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative);

    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    let root_diag = &diagnostics.roots[0];
    assert_eq!(
        root_diag.fallback_reason_counts[&RootCatalogShardFallbackReason::MissingReusableShard],
        1
    );
    assert_eq!(root_diag.authoritative_rebuild_count, 1);
}

// ---------------------------------------------------------------------------------------------
// Fallback reason 2/8: generationGap -- promoted to a rejection per §5c, never counted as a
// fallback (see `RootCatalogShardFallbackReason::GenerationGap`'s doc comment). "Covering" this
// reason means exercising the promoted rejection path end-to-end.
#[test]
fn generation_gap_is_promoted_to_a_rejection_not_a_silent_rebuild() {
    let (scope, identity) = seeded_scope(2, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(1, root, "a.swift")],
            false,
        ),
    );

    let mut command = upsert_files_command(
        &scope,
        root,
        lifetime,
        vec![file(2, root, "b.swift")],
        false,
    );
    command.expected_applied_index_generation = Some(999); // wrong -- actual is 1
    let receipt = scope.apply_delta(&identity, command);
    assert_eq!(
        receipt.outcome,
        InventoryApplyOutcome::Rejected(InventoryRejectionReason::GenerationGap {
            expected: 1,
            actual: 999
        })
    );
}

// ---------------------------------------------------------------------------------------------
// Fallback reason 3/8: fullResync.
#[test]
fn requires_full_resync_always_rebuilds() {
    let (scope, identity) = seeded_scope(3, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(1, root, "a.swift")],
            false,
        ),
    );

    let command =
        upsert_files_command(&scope, root, lifetime, vec![file(2, root, "b.swift")], true);
    let receipt = scope.apply_delta(&identity, command);
    assert_eq!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative);
    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    assert_eq!(
        diagnostics.roots[0].fallback_reason_counts[&RootCatalogShardFallbackReason::FullResync],
        1
    );
}

// ---------------------------------------------------------------------------------------------
// Fallback reason 4/8: unsafeOrAmbiguousBatch, two independent triggers.
#[test]
fn unsafe_or_ambiguous_batch_via_removing_an_id_absent_from_the_published_shard() {
    let (scope, identity) = seeded_scope(4, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(1, root, "a.swift")],
            false,
        ),
    );

    let mut event = empty_event(root);
    event.removed_file_ids = vec![file(99, root, "never-seen.swift").id]; // not in the published shard
    let command = InventoryDeltaCommand {
        scope_id: scope.scope_id(),
        root_id: root,
        root_lifetime_id: lifetime,
        watcher_accepted_watermark: None,
        requires_full_resync: false,
        expected_applied_index_generation: None,
        source: "test".to_owned(),
        event,
    };
    let receipt = scope.apply_delta(&identity, command);
    assert_eq!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative);
    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    assert_eq!(
        diagnostics.roots[0].fallback_reason_counts
            [&RootCatalogShardFallbackReason::UnsafeOrAmbiguousBatch],
        1
    );
}

#[test]
fn unsafe_or_ambiguous_batch_via_managed_only_touch() {
    let (scope, identity) = seeded_scope(5, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    let target = file(1, root, "a.swift");
    scope.apply_delta(
        &identity,
        upsert_files_command(&scope, root, lifetime, vec![target.clone()], false),
    );
    scope.testing_set_file_managed_only(root, target.id, true);

    // A steady-state upsert touching the now-managed-only file must not silently reintroduce it
    // into the discoverable shard via a patch -- it must fall back to a filtered rebuild.
    let mut modified = target.clone();
    modified.full_path = "/root/a-renamed.swift".into();
    let command = upsert_files_command(&scope, root, lifetime, vec![modified], false);
    let receipt = scope.apply_delta(&identity, command);
    assert_eq!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative);
    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    assert_eq!(
        diagnostics.roots[0].fallback_reason_counts
            [&RootCatalogShardFallbackReason::UnsafeOrAmbiguousBatch],
        1
    );
}

// ---------------------------------------------------------------------------------------------
// Fallback reason 5/8: retentionBoundary -- proceeds (installs) rather than rejecting.
#[test]
fn retention_boundary_lets_the_mutation_proceed_and_clears_published_topology_generation() {
    let (scope, identity) = seeded_scope(
        6,
        InventoryScopeConfig {
            live_generation_cap: 1,
            max_patch_logical_mutation_count: 1,
        },
    );
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");

    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(1, root, "a.swift")],
            false,
        ),
    ); // gen 0
    let handle0 = scope
        .open_snapshot(&identity, root, "test")
        .expect("open_snapshot gen0");

    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(2, root, "b.swift")],
            false,
        ),
    ); // gen 1, gen0 retained (handle0 open)
    let handle1 = scope
        .open_snapshot(&identity, root, "test")
        .expect("open_snapshot gen1");

    let receipt = scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(3, root, "c.swift")],
            false,
        ),
    ); // gen 2: gen0+gen1 both retained -> cap(1) exceeded
    assert_eq!(receipt.outcome, InventoryApplyOutcome::Patched); // the mutation proceeds

    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    let root_diag = &diagnostics.roots[0];
    assert_eq!(
        root_diag.fallback_reason_counts[&RootCatalogShardFallbackReason::RetentionBoundary],
        1
    );
    assert_eq!(root_diag.backstop_count, 1);
    assert!(root_diag.delta_state_dirty);
    assert_eq!(root_diag.published_topology_generation, None); // cleared, per §4 layer 2

    // Old handles remain valid regardless -- a retained generation costs memory, never progress.
    assert!(matches!(
        scope.read_snapshot(handle0),
        HandleReadOutcome::Open { .. }
    ));
    assert!(matches!(
        scope.read_snapshot(handle1),
        HandleReadOutcome::Open { .. }
    ));
}

// ---------------------------------------------------------------------------------------------
// Fallback reason 6/8: patchThresholdExceeded.
#[test]
fn patch_threshold_exceeded_falls_back_to_rebuild() {
    let (scope, identity) = seeded_scope(
        7,
        InventoryScopeConfig {
            live_generation_cap: 8,
            max_patch_logical_mutation_count: 1,
        },
    );
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(1, root, "a.swift")],
            false,
        ),
    );

    // Two upserted files in one delta -> logical_mutation_count == 2 > max(1).
    let command = upsert_files_command(
        &scope,
        root,
        lifetime,
        vec![file(2, root, "b.swift"), file(3, root, "c.swift")],
        false,
    );
    let receipt = scope.apply_delta(&identity, command);
    assert_eq!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative);
    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    assert_eq!(
        diagnostics.roots[0].fallback_reason_counts
            [&RootCatalogShardFallbackReason::PatchThresholdExceeded],
        1
    );
    // The rebuild must still reflect all three files.
    let handle = scope
        .open_snapshot(&identity, root, "test")
        .expect("open_snapshot");
    let page = scope.snapshot_page(handle, 0, 100).expect("page");
    assert_eq!(page.len(), 3);
}

// ---------------------------------------------------------------------------------------------
// Fallback reason 7/8: patchApplicationBackstop -- the defensive stale-base retry path.
#[test]
fn patch_application_backstop_is_reachable_via_the_forced_stale_base_test_hook() {
    let (scope, identity) = seeded_scope(8, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(1, root, "a.swift")],
            false,
        ),
    );

    scope.testing_force_stale_base_once();
    let command =
        upsert_files_command(&scope, root, lifetime, vec![file(2, root, "b.swift")], true); // force a rebuild path
    let receipt = scope.apply_delta(&identity, command);
    assert_eq!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative); // eventually succeeds

    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    assert_eq!(
        diagnostics.roots[0].fallback_reason_counts
            [&RootCatalogShardFallbackReason::PatchApplicationBackstop],
        1
    );
}

// ---------------------------------------------------------------------------------------------
// Fallback reason 8/8: shadowValidationMismatch -- via the explicit self-check testing hook (no
// shadow arm exists at P4-3a; see that reason's doc comment).
#[test]
fn shadow_validation_mismatch_is_reachable_via_the_self_check_testing_hook() {
    let (scope, identity) = seeded_scope(9, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    let target = file(1, root, "a.swift");
    scope.apply_delta(
        &identity,
        upsert_files_command(&scope, root, lifetime, vec![target.clone()], false),
    );

    // Desync the published shard from the maps without going through publish: mark the already
    // -published file managed-only directly.
    scope.testing_set_file_managed_only(root, target.id, true);
    let mismatch = scope.testing_self_check_patch_against_rebuild(root);
    assert!(mismatch);

    let diagnostics = scope.diagnostics(&identity).expect("diagnostics");
    assert_eq!(
        diagnostics.roots[0].fallback_reason_counts
            [&RootCatalogShardFallbackReason::ShadowValidationMismatch],
        1
    );
}

// ---------------------------------------------------------------------------------------------
// Rejection: staleWatermark.
#[test]
fn stale_watermark_is_rejected() {
    let (scope, identity) = seeded_scope(10, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");

    let mut first = upsert_files_command(
        &scope,
        root,
        lifetime,
        vec![file(1, root, "a.swift")],
        false,
    );
    first.watcher_accepted_watermark = Some(10);
    scope.apply_delta(&identity, first);

    let mut stale = upsert_files_command(
        &scope,
        root,
        lifetime,
        vec![file(2, root, "b.swift")],
        false,
    );
    stale.watcher_accepted_watermark = Some(9);
    let receipt = scope.apply_delta(&identity, stale);
    assert_eq!(
        receipt.outcome,
        InventoryApplyOutcome::Rejected(InventoryRejectionReason::StaleWatermark {
            expected: 10,
            actual: 9
        })
    );
}

// ---------------------------------------------------------------------------------------------
// Rejection: lifetimeMismatch -- close-root -> reopen mints a new lifetime; a delta bearing the
// old one is rejected, not silently applied.
#[test]
fn lifetime_mismatch_after_reopen_is_rejected() {
    let (scope, identity) = seeded_scope(11, InventoryScopeConfig::default());
    let root = root_id(1);
    let old_lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    let new_lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("reopen_root");
    assert_ne!(old_lifetime, new_lifetime);

    let command = upsert_files_command(
        &scope,
        root,
        old_lifetime,
        vec![file(1, root, "a.swift")],
        false,
    );
    let receipt = scope.apply_delta(&identity, command);
    assert_eq!(
        receipt.outcome,
        InventoryApplyOutcome::Rejected(InventoryRejectionReason::LifetimeMismatch)
    );
}

// ---------------------------------------------------------------------------------------------
// Rejection: unknownRoot, scopeClosed, identityMismatch.
#[test]
fn unknown_root_scope_closed_and_identity_mismatch_are_rejected() {
    let (scope, identity) = seeded_scope(12, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");

    let unknown_root_command = upsert_files_command(
        &scope,
        root_id(2),
        lifetime,
        vec![file(1, root_id(2), "a.swift")],
        false,
    );
    assert_eq!(
        scope.apply_delta(&identity, unknown_root_command).outcome,
        InventoryApplyOutcome::Rejected(InventoryRejectionReason::UnknownRoot)
    );

    let other = test_identity('b');
    let wrong_identity_command = upsert_files_command(
        &scope,
        root,
        lifetime,
        vec![file(1, root, "a.swift")],
        false,
    );
    assert_eq!(
        scope.apply_delta(&other, wrong_identity_command).outcome,
        InventoryApplyOutcome::Rejected(InventoryRejectionReason::IdentityMismatch)
    );

    scope.close(&identity).expect("close");
    let after_close_command = upsert_files_command(
        &scope,
        root,
        lifetime,
        vec![file(1, root, "a.swift")],
        false,
    );
    assert_eq!(
        scope.apply_delta(&identity, after_close_command).outcome,
        InventoryApplyOutcome::Rejected(InventoryRejectionReason::ScopeClosed)
    );
}

// ---------------------------------------------------------------------------------------------
// Handle lifecycle: open/read, close(idempotent), root-close invalidation, scope-close
// invalidation, identity-change invalidation, and the generationToken port anchor.
#[test]
fn handle_lifecycle_open_read_close_and_invalidation() {
    let (scope, identity) = seeded_scope(13, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(1, root, "a.swift")],
            false,
        ),
    );

    let handle = scope
        .open_snapshot(&identity, root, "test")
        .expect("open_snapshot");
    assert!(matches!(
        scope.read_snapshot(handle),
        HandleReadOutcome::Open { .. }
    ));
    scope.close_snapshot(handle);
    scope.close_snapshot(handle); // idempotent
    assert_eq!(
        scope.read_snapshot(handle),
        HandleReadOutcome::HandleInvalidated {
            reason: InvalidationReason::ScopeClosed // never-issued/forgotten-id fallback outcome
        }
    );
}

#[test]
fn same_generation_yields_equal_token_via_public_api() {
    let (scope, identity) = seeded_scope(14, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(1, root, "a.swift")],
            false,
        ),
    );

    let handle_a = scope
        .open_snapshot(&identity, root, "test")
        .expect("open_snapshot a");
    let handle_b = scope
        .open_snapshot(&identity, root, "test")
        .expect("open_snapshot b");
    let (
        HandleReadOutcome::Open { generation: gen_a },
        HandleReadOutcome::Open { generation: gen_b },
    ) = (scope.read_snapshot(handle_a), scope.read_snapshot(handle_b))
    else {
        panic!("expected both handles open");
    };
    assert_eq!(gen_a.token, gen_b.token); // same generation -> same generationToken

    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(2, root, "b.swift")],
            false,
        ),
    );
    let handle_c = scope
        .open_snapshot(&identity, root, "test")
        .expect("open_snapshot c");
    let HandleReadOutcome::Open { generation: gen_c } = scope.read_snapshot(handle_c) else {
        panic!("expected open");
    };
    assert_ne!(gen_a.token, gen_c.token); // different generation -> different token
}

#[test]
fn root_close_invalidates_its_handles_but_not_other_roots() {
    let (scope, identity) = seeded_scope(15, InventoryScopeConfig::default());
    let root_a = root_id(1);
    let root_b = root_id(2);
    let lifetime_a = scope
        .open_root(&identity, root_a, "A".into(), "/a".into())
        .expect("open a");
    let lifetime_b = scope
        .open_root(&identity, root_b, "B".into(), "/b".into())
        .expect("open b");
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root_a,
            lifetime_a,
            vec![file(1, root_a, "a.swift")],
            false,
        ),
    );
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root_b,
            lifetime_b,
            vec![file(2, root_b, "b.swift")],
            false,
        ),
    );
    let handle_a = scope
        .open_snapshot(&identity, root_a, "test")
        .expect("open_snapshot a");
    let handle_b = scope
        .open_snapshot(&identity, root_b, "test")
        .expect("open_snapshot b");

    scope
        .close_root(&identity, root_a, lifetime_a)
        .expect("close_root a");
    assert_eq!(
        scope.read_snapshot(handle_a),
        HandleReadOutcome::HandleInvalidated {
            reason: InvalidationReason::RootClosed
        }
    );
    assert!(matches!(
        scope.read_snapshot(handle_b),
        HandleReadOutcome::Open { .. }
    ));
}

#[test]
fn scope_close_invalidates_every_handle() {
    let (scope, identity) = seeded_scope(16, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(1, root, "a.swift")],
            false,
        ),
    );
    let handle = scope
        .open_snapshot(&identity, root, "test")
        .expect("open_snapshot");
    scope.close(&identity).expect("close");
    assert_eq!(
        scope.read_snapshot(handle),
        HandleReadOutcome::HandleInvalidated {
            reason: InvalidationReason::ScopeClosed
        }
    );
}

#[test]
fn identity_change_invalidates_every_handle() {
    let (scope, identity) = seeded_scope(17, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    scope.apply_delta(
        &identity,
        upsert_files_command(
            &scope,
            root,
            lifetime,
            vec![file(1, root, "a.swift")],
            false,
        ),
    );
    let handle = scope
        .open_snapshot(&identity, root, "test")
        .expect("open_snapshot");
    scope.invalidate_all_for_identity_change();
    assert_eq!(
        scope.read_snapshot(handle),
        HandleReadOutcome::HandleInvalidated {
            reason: InvalidationReason::IdentityChanged
        }
    );
}

// ---------------------------------------------------------------------------------------------
// Bulk-load atomicity and abort.
#[test]
fn staged_bulk_load_content_is_invisible_until_commit_then_atomically_published() {
    let (scope, identity) = seeded_scope(18, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");

    let bulk_load = scope
        .begin_bulk_load(&identity, root, lifetime)
        .expect("begin_bulk_load");
    scope
        .push_bulk_chunk(
            &identity,
            bulk_load,
            root,
            vec![file(1, root, "a.swift")],
            vec![],
        )
        .expect("push chunk 1");
    scope
        .push_bulk_chunk(
            &identity,
            bulk_load,
            root,
            vec![file(2, root, "b.swift")],
            vec![],
        )
        .expect("push chunk 2");

    // Invisible before commit: no published generation yet.
    assert_eq!(
        scope.open_snapshot(&identity, root, "test"),
        Err(ScopeError::NoPublishedGeneration)
    );

    let receipt = scope
        .commit_bulk_load(&identity, bulk_load, InventoryPublishMode::AtomicPublish)
        .expect("commit_bulk_load");
    assert_eq!(receipt.root_id, root);

    let handle = scope
        .open_snapshot(&identity, root, "test")
        .expect("open_snapshot after commit");
    let page = scope.snapshot_page(handle, 0, 100).expect("page");
    assert_eq!(page.len(), 2);
}

#[test]
fn bulk_load_abort_discards_staged_content_and_tombstones_the_id() {
    let (scope, identity) = seeded_scope(19, InventoryScopeConfig::default());
    let root = root_id(1);
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");

    let bulk_load = scope
        .begin_bulk_load(&identity, root, lifetime)
        .expect("begin_bulk_load");
    scope
        .push_bulk_chunk(
            &identity,
            bulk_load,
            root,
            vec![file(1, root, "a.swift")],
            vec![],
        )
        .expect("push chunk");
    scope.abort_bulk_load(&identity, bulk_load).expect("abort");

    // Push/commit/abort after abort are all rejected -- no "push after abort" path.
    assert!(
        scope
            .push_bulk_chunk(
                &identity,
                bulk_load,
                root,
                vec![file(2, root, "b.swift")],
                vec![]
            )
            .is_err()
    );
    assert!(
        scope
            .commit_bulk_load(&identity, bulk_load, InventoryPublishMode::AtomicPublish)
            .is_err()
    );
    assert!(scope.abort_bulk_load(&identity, bulk_load).is_err());

    assert_eq!(
        scope.open_snapshot(&identity, root, "test"),
        Err(ScopeError::NoPublishedGeneration)
    );
}
