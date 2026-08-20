mod common;

use agentry_runtime::{
    AdmissionOutcome, CancelOutcome, CoreRuntime, LifecycleState, OperationState, RuntimeConfig,
    RuntimeError, TerminalOutcome,
};
use std::future;
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

fn config(capacity: usize) -> RuntimeConfig {
    RuntimeConfig {
        data_lane_capacity: capacity,
        cancel_tombstone_window: Duration::from_secs(1),
        shutdown_grace: Duration::from_millis(250),
    }
}

#[test]
fn owns_runtime_and_begin_shutdown_is_nonblocking() {
    let identity = common::identity('a');
    let runtime = CoreRuntime::new(config(4), identity.clone()).expect("runtime");
    assert_eq!(runtime.lifecycle(), LifecycleState::Running);
    let started = Instant::now();
    let receipt = runtime.begin_shutdown(&identity).expect("shutdown");
    assert!(!receipt.already_started);
    assert!(started.elapsed() < Duration::from_millis(50));
    assert!(runtime.wait_for_terminal(Duration::from_secs(1)));
    runtime.join();
    assert_eq!(runtime.lifecycle(), LifecycleState::Stopped);
}

#[test]
fn control_path_remains_available_when_data_lane_is_saturated() {
    let identity = common::identity('a');
    let runtime = CoreRuntime::new(config(1), identity.clone()).expect("runtime");
    let first = common::request(1, &identity);
    let first_id = first.operation_id.clone();
    assert!(matches!(
        runtime.submit(first, future::pending()),
        Ok(AdmissionOutcome::Accepted)
    ));
    assert!(matches!(
        runtime.submit(common::request(2, &identity), async {
            TerminalOutcome::Success
        }),
        Err(RuntimeError::DataLaneSaturated)
    ));
    assert!(matches!(
        runtime.cancel(&identity, first_id),
        Ok(CancelOutcome::Requested)
    ));
    assert!(
        !runtime
            .begin_shutdown(&identity)
            .expect("shutdown")
            .already_started
    );
    assert!(runtime.wait_for_terminal(Duration::from_secs(1)));
    assert_eq!(runtime.active_task_count(), 0);
    assert_eq!(runtime.registry().active_count(), 0);
}

#[test]
fn concurrent_submit_and_shutdown_resolve_every_accepted_operation() {
    const SUBMITTERS: usize = 32;

    let identity = common::identity('a');
    let runtime =
        Arc::new(CoreRuntime::new(config(SUBMITTERS), identity.clone()).expect("runtime"));
    let barrier = Arc::new(Barrier::new(SUBMITTERS + 1));
    let mut submitters = Vec::new();
    for value in 0..SUBMITTERS {
        let runtime = Arc::clone(&runtime);
        let barrier = Arc::clone(&barrier);
        let identity = identity.clone();
        submitters.push(thread::spawn(move || {
            let request = common::request(value as u128, &identity);
            let operation_id = request.operation_id.clone();
            barrier.wait();
            let result = runtime.submit(request, future::pending());
            (operation_id, result)
        }));
    }

    barrier.wait();
    runtime.begin_shutdown(&identity).expect("shutdown");

    let mut accepted = Vec::new();
    for submitter in submitters {
        let (operation_id, result) = submitter.join().expect("submitter");
        match result {
            Ok(AdmissionOutcome::Accepted) => accepted.push(operation_id),
            Err(RuntimeError::ShuttingDown)
            | Err(RuntimeError::Registry(agentry_runtime::RegistryError::ShuttingDown)) => {}
            other => panic!("unexpected submit result: {other:?}"),
        }
    }

    assert!(runtime.wait_for_terminal(Duration::from_secs(2)));
    for operation_id in accepted {
        assert!(matches!(
            runtime.registry().snapshot(&operation_id),
            Some(snapshot) if matches!(snapshot.state, OperationState::Terminal(_))
        ));
    }
    assert_eq!(runtime.active_task_count(), 0);
    assert_eq!(runtime.registry().active_count(), 0);
}

#[test]
fn repeated_shutdown_is_idempotent() {
    let identity = common::identity('a');
    let runtime = CoreRuntime::new(config(1), identity.clone()).expect("runtime");
    assert!(
        !runtime
            .begin_shutdown(&identity)
            .expect("first")
            .already_started
    );
    assert!(
        runtime
            .begin_shutdown(&identity)
            .expect("second")
            .already_started
    );
    assert!(runtime.wait_for_terminal(Duration::from_secs(1)));
}
