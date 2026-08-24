//! P4-4b done-when: Rust unit coverage for the event plane itself -- emission ordering (each
//! mutation's events land in the hub in the order `publish_events` submits them, with the field
//! content the mutation actually produced) and a genuine bounded overflow -> gap marker, driven
//! entirely through `InventoryScope`'s public API against a real `SubscriptionHub`. The
//! no-publish-under-lock proof lives in `inventory_scope_event_lock_ordering.rs`; the true
//! end-to-end gap -> resnapshot-recovery proof through the FFI + Swift bridge lives in
//! `rust/crates/ffi/src/api.rs`'s tests and `Tests/AgentryCoreBridgeTests`.

use std::sync::Arc;

use agentry_runtime::inventory::{InventoryAppliedIndexBatchEvent, InventoryFileRecord};
use agentry_runtime::inventory_scope::{
    self, InventoryApplyOutcome, InventoryDeltaCommand, InventoryScope, InventoryScopeConfig,
    InventoryScopeId, RootId,
};
use agentry_runtime::{
    DrainOutcome, EventDetail, RuntimeIdentity, SubscriptionConfig, SubscriptionHub,
};

fn identity() -> RuntimeIdentity {
    RuntimeIdentity::new(1, "d".repeat(32), "a".repeat(64), "b".repeat(64)).expect("identity")
}

fn root(byte: u8) -> RootId {
    let mut id = [0u8; 16];
    id[15] = byte;
    id
}

fn file(byte: u8, root_id: RootId, rel: &str) -> InventoryFileRecord {
    let mut id = [0u8; 16];
    id[0] = 0xCC;
    id[15] = byte;
    InventoryFileRecord {
        id,
        root_id,
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
    root_id: RootId,
    lifetime: inventory_scope::RootLifetimeId,
    file_record: InventoryFileRecord,
) -> InventoryDeltaCommand {
    InventoryDeltaCommand {
        scope_id: scope.scope_id(),
        root_id,
        root_lifetime_id: lifetime,
        watcher_accepted_watermark: None,
        requires_full_resync: true,
        expected_applied_index_generation: None,
        source: "test".to_owned(),
        event: InventoryAppliedIndexBatchEvent {
            root_id,
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

fn patch_command(
    scope: &InventoryScope,
    root_id: RootId,
    lifetime: inventory_scope::RootLifetimeId,
    file_record: InventoryFileRecord,
) -> InventoryDeltaCommand {
    InventoryDeltaCommand {
        requires_full_resync: false,
        ..full_resync_command(scope, root_id, lifetime, file_record)
    }
}

fn wired_scope(scope_id_byte: u8) -> (InventoryScope, Arc<SubscriptionHub>, RuntimeIdentity) {
    let identity = identity();
    let scope = InventoryScope::new(
        identity.clone(),
        InventoryScopeId::from_bytes([scope_id_byte; 16]),
        InventoryScopeConfig::default(),
    );
    let hub = Arc::new(SubscriptionHub::new(identity.clone()).expect("hub"));
    scope.attach_event_sink(
        Arc::clone(&hub),
        scope.scope_id().to_subscription_scope_id(),
    );
    (scope, hub, identity)
}

#[test]
fn emission_ordering_matches_the_sequence_of_mutations() {
    let (scope, hub, identity) = wired_scope(1);
    let hub_scope_id = scope.scope_id().to_subscription_scope_id();
    let bootstrap = hub
        .open_subscription(
            &identity,
            hub_scope_id.clone(),
            SubscriptionConfig::default(),
            Vec::new,
        )
        .expect("open subscription before any mutation, so nothing is missed");

    let drain_kinds = |hub: &SubscriptionHub, identity: &RuntimeIdentity| -> Vec<u16> {
        let DrainOutcome::Batch(batch) = hub
            .try_drain(identity, bootstrap.subscription_id, 16, 65_536)
            .expect("drain")
        else {
            panic!("expected a batch, not oversize");
        };
        batch
            .events
            .iter()
            .map(|event| {
                // The first two bytes after the shared header's version word are the message
                // kind (`wire.rs`'s `MessageKind`, little-endian u16) -- peek it without a full
                // typed decode, purely to assert ordering here; field-level correctness is
                // asserted below via the real typed decoders.
                u16::from_le_bytes([event.payload[2], event.payload[3]])
            })
            .collect()
    };

    let root_a = root(1);
    let lifetime = scope
        .open_root(&identity, root_a, "RootA".into(), "/roota".into())
        .expect("open_root");
    assert_eq!(drain_kinds(&hub, &identity), vec![9 /* RootPublished */]);

    let receipt = scope.apply_delta(
        &identity,
        full_resync_command(&scope, root_a, lifetime, file(1, root_a, "a.swift")),
    );
    assert_eq!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative);
    // FullResync fallback fires before the rebuild; generationAdvanced (8) then
    // appliedIndexBatch (the pre-existing DeltaEvent kind, 2) follow it, in that order --
    // `delta_success_events`'s push order.
    assert_eq!(
        drain_kinds(&hub, &identity),
        vec![11 /* ShardFallback */, 8, 2]
    );

    let receipt = scope.apply_delta(
        &identity,
        patch_command(&scope, root_a, lifetime, file(2, root_a, "b.swift")),
    );
    assert_eq!(receipt.outcome, InventoryApplyOutcome::Patched);
    assert_eq!(drain_kinds(&hub, &identity), vec![8, 2]);

    let unload = scope
        .close_root(&identity, root_a, lifetime)
        .expect("close_root");
    assert_eq!(unload.root_id, root_a);
    assert_eq!(drain_kinds(&hub, &identity), vec![10 /* RootUnloaded */]);

    // Field-level correctness, not just kind ordering: re-open and apply once more, then decode
    // for real.
    let lifetime2 = scope
        .open_root(&identity, root_a, "RootA".into(), "/roota".into())
        .expect("reopen");
    let _ = drain_kinds(&hub, &identity); // discard the RootPublished for this reopen
    let receipt = scope.apply_delta(
        &identity,
        full_resync_command(&scope, root_a, lifetime2, file(3, root_a, "c.swift")),
    );
    let DrainOutcome::Batch(batch) = hub
        .try_drain(&identity, bootstrap.subscription_id, 16, 65_536)
        .expect("drain")
    else {
        panic!("expected batch");
    };
    assert_eq!(batch.events.len(), 3); // fallback, generationAdvanced, appliedIndexBatch
    let generation_advanced_bytes = &batch.events[1].payload;
    let decoded =
        agentry_runtime::inventory_scope::decode_generation_advanced(generation_advanced_bytes)
            .expect("decode generationAdvanced");
    assert_eq!(decoded.root_id, root_a);
    assert_eq!(decoded.root_lifetime_id, *lifetime2.as_bytes());
    assert_eq!(decoded.catalog_generation, receipt.catalog_generation);
    assert!(decoded.rebuilt_authoritative);
    assert_eq!(decoded.upserted_count, 1);

    let applied_index_batch_bytes = &batch.events[2].payload;
    let decoded_event =
        agentry_runtime::inventory_scope::decode_delta_event(applied_index_batch_bytes)
            .expect("decode appliedIndexBatch");
    assert_eq!(decoded_event.root_id, root_a);
    assert_eq!(decoded_event.upserted_files.len(), 1);
    assert_eq!(decoded_event.upserted_files[0].name, "c.swift");
}

#[test]
fn bounded_overflow_produces_a_gap_marker_and_a_fresh_snapshot_still_recovers() {
    let (scope, hub, identity) = wired_scope(2);
    let hub_scope_id = scope.scope_id().to_subscription_scope_id();
    // A deliberately tiny queue: `reserved_terminal_slots` defaults to 1, so at most 3 non-
    // lossless (data-plane) events are ever queued before eviction/gapping kicks in.
    let config = SubscriptionConfig {
        max_queued_events: 4,
        max_queued_bytes: 1_048_576,
        reserved_terminal_slots: 1,
        reserved_terminal_control_bytes: 4_096,
    };
    let bootstrap = hub
        .open_subscription(&identity, hub_scope_id, config, Vec::new)
        .expect("open subscription");

    // Eight distinct roots, each a fresh full-resync apply_delta: per advisor guidance, distinct
    // roots (rather than repeated mutations on one root) are required to defeat this scope's
    // per-(kind, root) coalescing and actually pressure the queue into eviction. Each call
    // produces a ShardFallback (Droppable) plus two Coalescible events, all under distinct
    // per-root coalesce keys, so nothing here silently coalesces away -- eviction/gapping is the
    // only way the queue can stay bounded.
    let mut last_root = root(0);
    let mut last_lifetime = None;
    for byte in 1..=8u8 {
        let root_id = root(byte);
        let lifetime = scope
            .open_root(
                &identity,
                root_id,
                format!("Root{byte}"),
                format!("/root{byte}"),
            )
            .expect("open_root");
        let receipt = scope.apply_delta(
            &identity,
            full_resync_command(&scope, root_id, lifetime, file(byte, root_id, "f.swift")),
        );
        assert_eq!(receipt.outcome, InventoryApplyOutcome::RebuiltAuthoritative);
        last_root = root_id;
        last_lifetime = Some(lifetime);
    }
    // `open_root`'s `inventoryRootPublished` events are Lossless: they never gap by themselves,
    // but do compete for the same queue slots by evicting droppable/coalescible entries -- so by
    // the time all eight roots have been opened and applied, the queue has seen far more than
    // its `max_queued_events` capacity worth of activity without ever being drained.

    let DrainOutcome::Batch(batch) = hub
        .try_drain(&identity, bootstrap.subscription_id, 64, 1_048_576)
        .expect("drain")
    else {
        panic!("expected a batch, not oversize");
    };
    assert!(
        batch.dropped_count > 0,
        "queue pressure across 8 distinct roots must have dropped something"
    );
    let gap = batch
        .events
        .iter()
        .find_map(|event| match &event.detail {
            EventDetail::Gap { dropped_count, .. } if *dropped_count > 0 => Some(*dropped_count),
            _ => None,
        })
        .expect("at least one gap marker with dropped_count > 0 must be present");
    assert!(gap > 0);

    // Resnapshot recovery (contract doc §5b: "consumers that hit a gap discard their projection
    // and re-bootstrap from a fresh snapshot handle"): open a brand new snapshot handle over the
    // last root touched and confirm it still serves current, correct data -- the gap does not
    // poison the scope itself, only the stale event-stream projection.
    let lifetime = last_lifetime.expect("at least one root opened");
    let handle = scope
        .open_snapshot(&identity, last_root, "post-gap-resnapshot")
        .expect("fresh snapshot handle must still open after a gap");
    let page = scope
        .snapshot_page(handle, 0, 10)
        .expect("fresh page must still read");
    assert_eq!(page.files.len(), 1);
    assert_eq!(page.files[0].name, "f.swift");
    scope.close_snapshot(handle);
    let _ = lifetime; // kept for readability of the setup above; not needed post-recovery
}
