//! P4-3a done-when: "a concurrency test asserting a reader is never blocked by an in-flight
//! authoritative rebuild" (`docs/architecture/rust-inventory-scope-v1.md` §2,
//! design §11 P4-3a). Deterministic via a caller-controlled barrier, per the advisor consult
//! during this step -- no wall-clock sleeps or timing thresholds, which would be flaky under CI
//! load.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;

use agentry_runtime::RuntimeIdentity;
use agentry_runtime::inventory::InventoryFileRecord;
use agentry_runtime::inventory_scope::{
    InventoryApplyOutcome, InventoryDeltaCommand, InventoryScope, InventoryScopeConfig,
    InventoryScopeId,
};

fn identity() -> RuntimeIdentity {
    RuntimeIdentity::new(1, "a".repeat(32), "a".repeat(64), "b".repeat(64)).expect("identity")
}

fn root_id() -> [u8; 16] {
    [7u8; 16]
}

fn file(byte: u8, root: [u8; 16], rel: &str) -> InventoryFileRecord {
    let mut id = [0u8; 16];
    id[0] = 0xAB;
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

fn full_resync_command(
    scope: &InventoryScope,
    root: [u8; 16],
    lifetime: agentry_runtime::inventory_scope::RootLifetimeId,
    file_record: InventoryFileRecord,
) -> InventoryDeltaCommand {
    InventoryDeltaCommand {
        scope_id: scope.scope_id(),
        root_id: root,
        root_lifetime_id: lifetime,
        watcher_accepted_watermark: None,
        requires_full_resync: true, // guarantees the rebuild path, never the patch path
        expected_applied_index_generation: None,
        source: "test".to_owned(),
        event: agentry_runtime::inventory::InventoryAppliedIndexBatchEvent {
            root_id: root,
            upserted_files: vec![file_record],
            upserted_folders: vec![],
            removed_file_ids: vec![],
            removed_folder_ids: vec![],
            removed_file_paths: vec![],
            removed_folder_paths: vec![],
            modified_file_ids: vec![],
            modified_folder_ids: vec![],
        },
    }
}

#[test]
fn reader_is_never_blocked_by_an_in_flight_authoritative_rebuild() {
    let identity = identity();
    let root = root_id();
    let scope = Arc::new(InventoryScope::new(
        identity.clone(),
        InventoryScopeId::from_bytes([2; 16]),
        InventoryScopeConfig::default(),
    ));
    let lifetime = scope
        .open_root(&identity, root, "Root".into(), "/root".into())
        .expect("open_root");
    // Establish an initial published generation so the writer thread's rebuild below has a real
    // base to (not) race against, and so reads have something to read.
    scope.apply_delta(
        &identity,
        full_resync_command(&scope, root, lifetime, file(0, root, "seed.swift")),
    );

    // Two parties: the writer thread (parked mid-rebuild) and this test thread (releases it).
    let barrier = Arc::new(Barrier::new(2));
    scope.testing_install_rebuild_barrier(Arc::clone(&barrier));

    let reads_completed = Arc::new(AtomicU64::new(0));

    let writer_scope = Arc::clone(&scope);
    let writer_identity = identity.clone();
    let writer = thread::spawn(move || {
        let command = full_resync_command(&writer_scope, root, lifetime, file(1, root, "b.swift"));
        writer_scope.apply_delta(&writer_identity, command)
    });

    // Deterministically wait for the writer to actually be parked (lock already released) before
    // asserting anything -- a plain "spawn then immediately start reading" risks a vacuous test
    // if the read loop finishes before the writer even starts. This is a spin on an atomic flag,
    // not a wall-clock sleep: it resolves as soon as the writer makes progress, with no timing
    // threshold to go flaky under CI load.
    while !scope.testing_is_parked_on_rebuild_barrier() {
        std::hint::spin_loop();
    }

    // The writer thread has released the state lock (it snapshots inputs under a brief lock,
    // then parks on the barrier *outside* the lock -- see `rebuild_and_install`). Reads below
    // must all complete without ever blocking on the writer.
    const TARGET_READS: u64 = 2_000;
    while reads_completed.load(Ordering::Relaxed) < TARGET_READS {
        let handle = scope
            .open_snapshot(&identity, root, "reader")
            .expect("open_snapshot must not block");
        let _ = scope
            .diagnostics(&identity)
            .expect("diagnostics must not block");
        scope.close_snapshot(handle);
        reads_completed.fetch_add(1, Ordering::Relaxed);
    }
    assert_eq!(reads_completed.load(Ordering::Relaxed), TARGET_READS);

    // Now release the parked writer and confirm it completes correctly.
    barrier.wait();
    let receipt = writer.join().expect("writer thread");
    assert_eq!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative);

    let handle = scope
        .open_snapshot(&identity, root, "final")
        .expect("final open_snapshot");
    let page = scope.snapshot_page(handle, 0, 100).expect("final page");
    assert_eq!(page.len(), 2); // seed.swift + b.swift
}
