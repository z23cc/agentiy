mod common;

use agentry_runtime::{CoreRuntime, RuntimeConfig, SubscriptionConfig, SubscriptionError};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[test]
fn concurrent_subscription_close_and_shutdown_exit_within_bound() {
    let identity = common::identity('a');
    let runtime = Arc::new(
        CoreRuntime::new(
            RuntimeConfig {
                data_lane_capacity: 8,
                cancel_tombstone_window: Duration::from_secs(1),
                shutdown_grace: Duration::from_millis(250),
            },
            identity.clone(),
        )
        .expect("runtime"),
    );
    let mut subscriptions = Vec::new();
    for index in 0..128 {
        subscriptions.push(
            runtime
                .subscriptions()
                .open_subscription(
                    &identity,
                    common::scope_id(index),
                    SubscriptionConfig::default(),
                    Vec::new,
                )
                .expect("open")
                .subscription_id,
        );
    }

    let mut closers = Vec::new();
    for chunk in subscriptions.chunks(16) {
        let runtime = Arc::clone(&runtime);
        let identity = identity.clone();
        let ids = chunk.to_vec();
        closers.push(thread::spawn(move || {
            for id in ids {
                match runtime.subscriptions().close_subscription(&identity, id) {
                    Ok(_) | Err(SubscriptionError::RuntimeStopped) => {}
                    other => panic!("unexpected close result: {other:?}"),
                }
            }
        }));
    }
    let started = Instant::now();
    runtime.begin_shutdown(&identity).expect("shutdown");
    for closer in closers {
        closer.join().expect("closer");
    }
    assert!(runtime.wait_for_terminal(Duration::from_secs(1)));
    assert!(started.elapsed() < Duration::from_secs(1));
    assert_eq!(runtime.subscriptions().subscription_count(), 0);
    assert_eq!(runtime.active_task_count(), 0);
}
