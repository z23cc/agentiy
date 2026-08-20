mod common;

use agentry_runtime::{
    DrainOutcome, EventInput, SubscriptionConfig, SubscriptionError, SubscriptionHub, WakePipe,
    WakeSignal,
};
use std::sync::Arc;
use std::thread;

#[test]
fn pipe_is_nonblocking_coalesces_eagain_and_closes_idempotently() {
    let pipe = WakePipe::new().expect("pipe");
    let read = pipe.duplicate_read_fd().expect("dup");
    let mut saw_eagain = false;
    for _ in 0..1_000_000 {
        if pipe.signal().expect("signal") == WakeSignal::AlreadyPending {
            saw_eagain = true;
            break;
        }
    }
    assert!(
        saw_eagain,
        "nonblocking pipe should eventually coalesce on EAGAIN"
    );
    let (_read, count) = WakePipe::drain_duplicate(read).expect("drain");
    assert!(count > 0);
    assert!(pipe.close());
    assert!(!pipe.close());
    assert!(pipe.is_closed());
}

#[test]
fn empty_to_nonempty_writes_one_signal_and_rearm_rechecks_under_queue_lock() {
    let identity = common::identity('a');
    let scope = common::scope_id(1);
    let hub = SubscriptionHub::new(identity.clone()).expect("hub");
    let bootstrap = hub
        .open_subscription(
            &identity,
            scope.clone(),
            SubscriptionConfig::default(),
            Vec::new,
        )
        .expect("open");
    let read = hub.duplicate_wake_read_fd(&identity).expect("dup");

    for _ in 0..10 {
        hub.publish(&identity, &scope, EventInput::data(vec![1]))
            .expect("publish");
    }
    let (read, count) = WakePipe::drain_duplicate(read).expect("drain wake");
    assert_eq!(
        count, 1,
        "armed transition must coalesce duplicate publishes"
    );
    let DrainOutcome::Batch(batch) = hub
        .try_drain(&identity, bootstrap.subscription_id, 10, 4_096)
        .expect("drain events")
    else {
        panic!("batch");
    };
    assert_eq!(batch.events.len(), 10);

    // Producer lands after the last drain but before rearm. It sees armed=true and
    // writes nothing; rearm-and-recheck must observe the queued event and write.
    hub.publish(&identity, &scope, EventInput::data(vec![2]))
        .expect("racing publish");
    assert!(hub.rearm_and_recheck(&identity).expect("rearm"));
    let (_read, count) = WakePipe::drain_duplicate(read).expect("drain rearm wake");
    assert_eq!(count, 1);
}

#[test]
fn concurrent_close_has_one_owner_and_is_idempotent() {
    let identity = common::identity('a');
    let hub = Arc::new(SubscriptionHub::new(identity.clone()).expect("hub"));
    let subscription = hub
        .open_subscription(
            &identity,
            common::scope_id(1),
            SubscriptionConfig::default(),
            Vec::new,
        )
        .expect("open")
        .subscription_id;
    let mut threads = Vec::new();
    for _ in 0..16 {
        let hub = Arc::clone(&hub);
        let identity = identity.clone();
        threads.push(thread::spawn(move || {
            hub.close_subscription(&identity, subscription)
                .expect("close")
        }));
    }
    let owners = threads
        .into_iter()
        .map(|thread| thread.join().expect("join"))
        .filter(|closed| *closed)
        .count();
    assert_eq!(owners, 1);
    assert_eq!(hub.subscription_count(), 0);
}

#[test]
fn identity_replacement_invalidates_old_handles_and_closes_old_pipe() {
    let old = common::identity('a');
    let new = common::identity('d');
    let hub = SubscriptionHub::new(old.clone()).expect("hub");
    hub.open_subscription(
        &old,
        common::scope_id(1),
        SubscriptionConfig::default(),
        Vec::new,
    )
    .expect("open");
    let old_read = hub.duplicate_wake_read_fd(&old).expect("dup");
    hub.replace_identity(&old, new.clone()).expect("replace");
    assert_eq!(hub.subscription_count(), 0);
    assert!(matches!(
        hub.duplicate_wake_read_fd(&old),
        Err(SubscriptionError::StaleRuntimeIdentity)
    ));
    let (_old_read, count) = WakePipe::drain_duplicate(old_read).expect("old read reaches EOF");
    assert_eq!(count, 0);
    let _new_read = hub.duplicate_wake_read_fd(&new).expect("new wake pipe");
}
