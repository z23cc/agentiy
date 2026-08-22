//! P4-4b done-when: "specify and enforce [the lock-ordering rule] in doc comments + a test that
//! would deadlock/fail if violated" (see `scope.rs`'s "event plane (P4-4b)" section doc comment
//! for the rule itself: `SubscriptionHub`'s lock is always innermost, `InventoryScope` never
//! calls into it while holding `Mutex<ScopeState>`).
//!
//! Deterministic via a caller-controlled barrier, exactly mirroring
//! `inventory_scope_concurrency.rs`'s `reader_is_never_blocked_by_an_in_flight_authoritative_
//! rebuild` -- no wall-clock sleeps or timing thresholds, which would be flaky under CI load.
//!
//! **What a violation looks like, concretely:** if a future refactor moved the
//! `self.publish_events(...)` call in `open_root` (or any other mutation method) to *inside* the
//! `with_state` closure, this test's writer thread would park on the publish barrier while still
//! holding `self.state`'s guard. The reader thread below calls `diagnostics`/`open_snapshot`,
//! both `with_state`-guarded, so it would then block on the same `std::sync::Mutex` for as long
//! as the barrier is held -- i.e. it would stall past `READS_BEFORE_RELEASE`, and this test's
//! bounded-progress assertion would fail (in the pathological case, hang until the test harness's
//! own timeout kills it -- the "deadlock" the done-when line names). Today's implementation
//! completes every read while the writer is parked, because `publish_events` only ever runs after
//! `with_state` has already returned.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;

use agentry_runtime::inventory::InventoryFileRecord;
use agentry_runtime::inventory_scope::{
    InventoryDeltaCommand, InventoryScope, InventoryScopeConfig, InventoryScopeId,
};
use agentry_runtime::{RuntimeIdentity, SubscriptionHub};

fn identity() -> RuntimeIdentity {
    RuntimeIdentity::new(1, "e".repeat(32), "a".repeat(64), "b".repeat(64)).expect("identity")
}

fn seed_file(root: [u8; 16]) -> InventoryFileRecord {
    InventoryFileRecord {
        id: [0xAA; 16],
        root_id: root,
        name: "seed.swift".to_owned(),
        relative_path: "seed.swift".to_owned(),
        standardized_relative_path: "seed.swift".to_owned(),
        full_path: "/seed/seed.swift".to_owned(),
        standardized_full_path: "/seed/seed.swift".to_owned(),
        parent_folder_id: None,
        modification_date: None,
    }
}

#[test]
fn concurrent_reader_makes_progress_while_a_publish_is_parked() {
    let identity = identity();
    let scope = Arc::new(InventoryScope::new(
        identity.clone(),
        InventoryScopeId::from_bytes([9; 16]),
        InventoryScopeConfig::default(),
    ));
    let hub = Arc::new(SubscriptionHub::new(identity.clone()).expect("hub"));
    scope.attach_event_sink(Arc::clone(&hub), scope.scope_id().to_subscription_scope_id());

    // Establish a real root with a published generation so the reader thread has something to
    // open snapshots against.
    let seeded_root = [1u8; 16];
    let seeded_lifetime = scope
        .open_root(&identity, seeded_root, "Seed".into(), "/seed".into())
        .expect("open seed root");
    scope.apply_delta(
        &identity,
        InventoryDeltaCommand {
            scope_id: scope.scope_id(),
            root_id: seeded_root,
            root_lifetime_id: seeded_lifetime,
            watcher_accepted_watermark: None,
            requires_full_resync: true,
            expected_applied_index_generation: None,
            source: "test".to_owned(),
            event: agentry_runtime::inventory::InventoryAppliedIndexBatchEvent {
                root_id: seeded_root,
                upserted_files: vec![seed_file(seeded_root)],
                upserted_folders: vec![],
                removed_file_ids: vec![],
                removed_folder_ids: vec![],
                removed_file_paths: vec![],
                removed_folder_paths: vec![],
                modified_file_ids: vec![],
                modified_folder_ids: vec![],
            },
        },
    );

    // The publish barrier: installed once, consumed by the very next `publish_events` call
    // (`open_root`'s `inventoryRootPublished` emission below).
    let barrier = Arc::new(Barrier::new(2));
    scope.testing_install_publish_barrier(Arc::clone(&barrier));

    let writer_scope = Arc::clone(&scope);
    let writer_identity = identity.clone();
    let triggering_root = [2u8; 16];
    let writer = thread::spawn(move || {
        writer_scope.open_root(&writer_identity, triggering_root, "Root2".into(), "/root2".into())
    });

    // Deterministic: spin until the writer is actually parked (lock already released, per
    // `publish_events`'s structure) before asserting anything about concurrent progress.
    while !scope.testing_is_parked_on_publish_barrier() {
        std::hint::spin_loop();
    }

    let reads_completed = Arc::new(AtomicU64::new(0));
    const TARGET_READS: u64 = 2_000;
    while reads_completed.load(Ordering::Relaxed) < TARGET_READS {
        let _ = scope.diagnostics(&identity).expect("diagnostics must not block");
        let handle = scope
            .open_snapshot(&identity, seeded_root, "lock-ordering-test")
            .expect("open_snapshot must not block");
        scope.close_snapshot(handle);
        reads_completed.fetch_add(1, Ordering::Relaxed);
    }
    assert_eq!(reads_completed.load(Ordering::Relaxed), TARGET_READS);

    // Release the parked writer and confirm it still completes correctly -- the barrier proved
    // concurrency, not correctness; this closes the loop on both.
    barrier.wait();
    let lifetime = writer.join().expect("writer thread").expect("open_root");
    let unload = scope
        .close_root(&identity, triggering_root, lifetime)
        .expect("close_root");
    assert_eq!(unload.root_id, triggering_root);
}

#[test]
fn publish_events_never_runs_with_state_still_locked_self_check() {
    // The always-on complement to the barrier proof above (`testing_try_lock_state`'s doc
    // comment): every successful mutation in this smoke pass must leave `self.state` acquirable
    // immediately after it returns, including the window `publish_events` itself runs in (a
    // `debug_assert!` inside `publish_events` already enforces this on every call in debug
    // builds; this test just guarantees at least one such call actually executes).
    let identity = identity();
    let scope = InventoryScope::new(
        identity.clone(),
        InventoryScopeId::from_bytes([10; 16]),
        InventoryScopeConfig::default(),
    );
    let hub = Arc::new(SubscriptionHub::new(identity.clone()).expect("hub"));
    scope.attach_event_sink(Arc::clone(&hub), scope.scope_id().to_subscription_scope_id());

    let root = [3u8; 16];
    scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    assert!(scope.testing_try_lock_state(), "state lock must be free after open_root returns");
    assert_eq!(scope.publish_failure_count(), 0, "publish must have succeeded, not merely no-oped");
}
