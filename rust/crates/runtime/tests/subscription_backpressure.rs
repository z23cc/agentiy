mod common;

use agentry_runtime::{
    DrainOutcome, EventClass, EventDetail, EventInput, RuntimeEventKind, SubscriptionConfig,
    SubscriptionError, SubscriptionHub,
};

fn small_config() -> SubscriptionConfig {
    SubscriptionConfig {
        max_queued_events: 4,
        max_queued_bytes: 16_384,
        reserved_terminal_slots: 1,
        reserved_terminal_control_bytes: 4_096,
    }
}

#[test]
fn overload_coalesces_gap_and_preserves_terminal_capacity() {
    let identity = common::identity('a');
    let scope = common::scope_id(1);
    let hub = SubscriptionHub::new(identity.clone()).expect("hub");
    let bootstrap = hub
        .open_subscription(&identity, scope.clone(), small_config(), || {
            b"snapshot".to_vec()
        })
        .expect("open");
    assert_eq!(bootstrap.next_delivery_cursor, 1);

    for value in 0..8 {
        hub.publish(&identity, &scope, EventInput::data(vec![value; 32]))
            .expect("publish");
    }
    hub.publish(&identity, &scope, EventInput::terminal(b"done".to_vec()))
        .expect("terminal");
    let DrainOutcome::Batch(batch) = hub
        .try_drain(&identity, bootstrap.subscription_id, 32, 16_384)
        .expect("drain")
    else {
        panic!("expected batch");
    };
    assert!(batch.events.iter().any(
        |event| matches!(event.detail, EventDetail::Gap { dropped_count, .. } if dropped_count > 0)
    ));
    assert!(
        batch
            .events
            .iter()
            .any(|event| event.kind == RuntimeEventKind::Terminal)
    );
    assert!(batch.dropped_count > 0);
}

#[test]
fn oversize_enqueue_becomes_compact_rejection() {
    let identity = common::identity('a');
    let scope = common::scope_id(1);
    let hub = SubscriptionHub::new(identity.clone()).expect("hub");
    let bootstrap = hub
        .open_subscription(&identity, scope.clone(), small_config(), Vec::new)
        .expect("open");
    let summary = hub
        .publish(&identity, &scope, EventInput::data(vec![0; 20_000]))
        .expect("publish");
    assert_eq!(summary.payload_rejected, 1);
    let DrainOutcome::Batch(batch) = hub
        .try_drain(&identity, bootstrap.subscription_id, 4, 4_096)
        .expect("drain")
    else {
        panic!("expected batch");
    };
    assert_eq!(batch.events.len(), 1);
    assert!(matches!(
        batch.events[0].detail,
        EventDetail::PayloadRejected {
            resnapshot_required: true,
            ..
        }
    ));
}

#[test]
fn drain_reports_has_more_and_oversize_without_livelock() {
    let identity = common::identity('a');
    let scope = common::scope_id(1);
    let hub = SubscriptionHub::new(identity.clone()).expect("hub");
    let config = SubscriptionConfig {
        max_queued_events: 8,
        max_queued_bytes: 64_000,
        ..small_config()
    };
    let bootstrap = hub
        .open_subscription(&identity, scope.clone(), config, Vec::new)
        .expect("open");
    for _ in 0..3 {
        hub.publish(&identity, &scope, EventInput::data(vec![0; 128]))
            .expect("publish");
    }
    let DrainOutcome::Batch(first) = hub
        .try_drain(&identity, bootstrap.subscription_id, 2, 4_096)
        .expect("drain")
    else {
        panic!("batch");
    };
    assert_eq!(first.events.len(), 2);
    assert!(first.has_more);
    assert_eq!(first.next_delivery_cursor, 3);
    let DrainOutcome::Batch(second) = hub
        .try_drain(&identity, bootstrap.subscription_id, 2, 4_096)
        .expect("drain")
    else {
        panic!("batch");
    };
    assert_eq!(second.events.len(), 1);
    assert!(!second.has_more);

    hub.publish(
        &identity,
        &scope,
        EventInput {
            kind: RuntimeEventKind::HostRequest,
            class: EventClass::Lossless,
            payload: vec![0; 8_000],
            coalesce_key: None,
        },
    )
    .expect("publish");
    hub.publish(
        &identity,
        &scope,
        EventInput::data(b"after-oversize".to_vec()),
    )
    .expect("publish continuation");
    let DrainOutcome::Oversize(oversize) = hub
        .try_drain(&identity, bootstrap.subscription_id, 4, 4_096)
        .expect("oversize")
    else {
        panic!("oversize result");
    };
    assert!(oversize.resnapshot_required);
    assert!(oversize.has_more);
    assert_eq!(oversize.next_delivery_cursor, 5);
    let DrainOutcome::Batch(continuation) = hub
        .try_drain(&identity, bootstrap.subscription_id, 4, 4_096)
        .expect("continuation")
    else {
        panic!("batch");
    };
    assert_eq!(continuation.events.len(), 1);
    assert_eq!(
        continuation.events[0].delivery_cursor,
        oversize.next_delivery_cursor
    );
    assert!(!continuation.has_more);
}

#[test]
fn failed_publication_does_not_partially_commit_matching_queues() {
    let identity = common::identity('a');
    let scope = common::scope_id(1);
    let hub = SubscriptionHub::new(identity.clone()).expect("hub");
    let roomy = hub
        .open_subscription(&identity, scope.clone(), small_config(), Vec::new)
        .expect("roomy subscription");
    let constrained = hub
        .open_subscription(
            &identity,
            scope.clone(),
            SubscriptionConfig {
                max_queued_events: 2,
                ..small_config()
            },
            Vec::new,
        )
        .expect("constrained subscription");

    for value in [b"one".to_vec(), b"two".to_vec()] {
        hub.publish(&identity, &scope, EventInput::terminal(value))
            .expect("fill queues");
    }
    assert!(matches!(
        hub.publish(&identity, &scope, EventInput::terminal(b"three".to_vec())),
        Err(SubscriptionError::QueueLimitExceeded)
    ));

    for subscription_id in [roomy.subscription_id, constrained.subscription_id] {
        let DrainOutcome::Batch(batch) = hub
            .try_drain(&identity, subscription_id, 4, 16_384)
            .expect("drain")
        else {
            panic!("batch");
        };
        assert_eq!(batch.events.len(), 2);
        assert!(batch.events.iter().all(|event| event.payload != b"three"));
    }
}

#[test]
fn coalescible_events_replace_previous_value() {
    let identity = common::identity('a');
    let scope = common::scope_id(1);
    let hub = SubscriptionHub::new(identity.clone()).expect("hub");
    let bootstrap = hub
        .open_subscription(&identity, scope.clone(), small_config(), Vec::new)
        .expect("open");
    for payload in [b"one".to_vec(), b"two".to_vec()] {
        hub.publish(
            &identity,
            &scope,
            EventInput {
                kind: RuntimeEventKind::Progress,
                class: EventClass::Coalescible,
                payload,
                coalesce_key: Some("progress".to_owned()),
            },
        )
        .expect("publish");
    }
    let DrainOutcome::Batch(batch) = hub
        .try_drain(&identity, bootstrap.subscription_id, 4, 4_096)
        .expect("drain")
    else {
        panic!("batch");
    };
    assert_eq!(batch.events.len(), 1);
    assert_eq!(batch.events[0].payload, b"two");
}

#[test]
fn invalid_drain_limits_fail_closed() {
    let identity = common::identity('a');
    let scope = common::scope_id(1);
    let hub = SubscriptionHub::new(identity.clone()).expect("hub");
    let bootstrap = hub
        .open_subscription(&identity, scope, small_config(), Vec::new)
        .expect("open");
    assert!(matches!(
        hub.try_drain(&identity, bootstrap.subscription_id, 0, 4_096),
        Err(SubscriptionError::InvalidLimits)
    ));
    assert!(matches!(
        hub.try_drain(&identity, bootstrap.subscription_id, 1, 1),
        Err(SubscriptionError::InvalidLimits)
    ));
}

#[test]
fn bootstrap_snapshot_and_first_delivery_cursor_share_publication_lock() {
    let identity = common::identity('a');
    let scope = common::scope_id(1);
    let hub = SubscriptionHub::new(identity.clone()).expect("hub");
    let bootstrap = hub
        .open_subscription(&identity, scope.clone(), small_config(), || {
            b"snapshot-at-cursor-zero".to_vec()
        })
        .expect("open");
    hub.publish(&identity, &scope, EventInput::data(b"first-delta".to_vec()))
        .expect("publish");
    let DrainOutcome::Batch(batch) = hub
        .try_drain(&identity, bootstrap.subscription_id, 1, 4_096)
        .expect("drain")
    else {
        panic!("batch");
    };
    assert_eq!(bootstrap.next_delivery_cursor, 1);
    assert_eq!(
        batch.events[0].delivery_cursor,
        bootstrap.next_delivery_cursor
    );
}

#[test]
fn oversize_terminal_preserves_terminal_metadata_without_payload() {
    let identity = common::identity('a');
    let scope = common::scope_id(1);
    let hub = SubscriptionHub::new(identity.clone()).expect("hub");
    let bootstrap = hub
        .open_subscription(&identity, scope.clone(), small_config(), Vec::new)
        .expect("open");
    hub.publish(&identity, &scope, EventInput::terminal(vec![0; 20_000]))
        .expect("terminal");
    let DrainOutcome::Batch(batch) = hub
        .try_drain(&identity, bootstrap.subscription_id, 1, 4_096)
        .expect("drain")
    else {
        panic!("batch");
    };
    assert_eq!(batch.events[0].kind, RuntimeEventKind::Terminal);
    assert!(batch.events[0].payload.is_empty());
    assert!(batch.events[0].payload_omitted);
}
