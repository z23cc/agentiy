mod common;

use agentry_runtime::{
    AdmissionOutcome, CancelOutcome, CoreRuntime, LifecycleState, ManagedOperationDirective,
    ManagedOperationStopReason, OperationState, RuntimeConfig, RuntimeError, TerminalOutcome,
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
fn shutdown_waits_for_synchronous_authority_permit_and_closes_admission() {
    let identity = common::identity('a');
    let runtime = CoreRuntime::new(config(1), identity.clone()).expect("runtime");
    let permit = runtime
        .begin_authority_operation()
        .expect("authority permit");
    assert_eq!(runtime.active_authority_operation_count(), 1);

    runtime.begin_shutdown(&identity).expect("shutdown");
    assert!(matches!(
        runtime.begin_authority_operation(),
        Err(RuntimeError::ShuttingDown)
    ));
    assert!(!runtime.wait_for_terminal(Duration::from_millis(25)));

    drop(permit);
    assert!(runtime.wait_for_terminal(Duration::from_secs(1)));
    assert_eq!(runtime.active_authority_operation_count(), 0);
}

#[test]
fn managed_operations_share_capacity_without_spawning_tokio_tasks() {
    let identity = common::identity('a');
    let runtime = CoreRuntime::new(config(1), identity.clone()).expect("runtime");
    let first_request = common::request(40, &identity);
    let first_id = first_request.operation_id.clone();
    let (first, directive) = runtime
        .attach_managed_operation(first_request)
        .expect("managed attachment");
    assert_eq!(directive, ManagedOperationDirective::ContinueExecution);
    assert_eq!(runtime.active_managed_operation_count(), 1);
    assert_eq!(runtime.active_task_count(), 0);

    let saturated = common::request(41, &identity);
    let saturated_id = saturated.operation_id.clone();
    assert!(matches!(
        runtime.attach_managed_operation(saturated),
        Err(RuntimeError::DataLaneSaturated)
    ));
    assert!(runtime.registry().snapshot(&saturated_id).is_none());
    assert_eq!(runtime.active_managed_operation_count(), 1);

    assert_eq!(
        runtime.cancel(&identity, first_id).expect("cancel managed"),
        CancelOutcome::Requested
    );
    assert_eq!(
        first.checkpoint().expect("cancel checkpoint"),
        ManagedOperationDirective::Stop(ManagedOperationStopReason::Cancelled)
    );
    assert_eq!(
        first
            .resolve_terminal(TerminalOutcome::Cancelled)
            .expect("cancel terminal"),
        OperationState::Terminal(TerminalOutcome::Cancelled)
    );
    assert_eq!(runtime.active_managed_operation_count(), 0);
    runtime.begin_shutdown(&identity).expect("shutdown");
    assert!(runtime.wait_for_terminal(Duration::from_secs(1)));
}

#[test]
fn managed_authority_wins_late_cancel_and_shutdown_waits_for_permit() {
    let identity = common::identity('a');
    let runtime = CoreRuntime::new(config(1), identity.clone()).expect("runtime");
    let request = common::request(42, &identity);
    let operation_id = request.operation_id.clone();
    let (lease, directive) = runtime
        .attach_managed_operation(request)
        .expect("managed attachment");
    assert_eq!(directive, ManagedOperationDirective::ContinueExecution);
    let (authority_directive, permit) = runtime
        .begin_managed_authority_operation(&lease)
        .expect("managed authority");
    assert_eq!(
        authority_directive,
        ManagedOperationDirective::ContinueExecution
    );
    let permit = permit.expect("authority permit");
    assert_eq!(runtime.active_authority_operation_count(), 1);
    assert_eq!(
        runtime
            .cancel(&identity, operation_id)
            .expect("late managed cancel"),
        CancelOutcome::AlreadyTerminal
    );
    assert_eq!(
        lease.checkpoint().expect("late cancel checkpoint"),
        ManagedOperationDirective::ContinueExecution
    );
    assert_eq!(
        lease
            .resolve_terminal(TerminalOutcome::Success)
            .expect("success terminal"),
        OperationState::Terminal(TerminalOutcome::Success)
    );

    runtime.begin_shutdown(&identity).expect("shutdown");
    assert!(!runtime.wait_for_terminal(Duration::from_millis(25)));
    drop(permit);
    assert!(runtime.wait_for_terminal(Duration::from_secs(1)));
    assert_eq!(runtime.active_managed_operation_count(), 0);
    assert_eq!(runtime.active_authority_operation_count(), 0);
}

#[test]
fn managed_shutdown_stop_remains_attached_until_terminalized() {
    let identity = common::identity('a');
    let runtime = CoreRuntime::new(config(1), identity.clone()).expect("runtime");
    let (lease, directive) = runtime
        .attach_managed_operation(common::request(43, &identity))
        .expect("managed attachment");
    assert_eq!(directive, ManagedOperationDirective::ContinueExecution);
    runtime.begin_shutdown(&identity).expect("shutdown");
    assert_eq!(
        lease.checkpoint().expect("shutdown checkpoint"),
        ManagedOperationDirective::Stop(ManagedOperationStopReason::ShutdownRequested)
    );
    assert!(!runtime.wait_for_terminal(Duration::from_millis(25)));
    assert_eq!(
        lease
            .resolve_terminal(TerminalOutcome::Cancelled)
            .expect("shutdown terminal"),
        OperationState::Terminal(TerminalOutcome::Cancelled)
    );
    assert!(runtime.wait_for_terminal(Duration::from_secs(1)));
}

#[test]
fn shutdown_grace_detaches_a_leaked_pre_authority_managed_lease() {
    let identity = common::identity('a');
    let mut short = config(1);
    short.shutdown_grace = Duration::from_millis(25);
    let runtime = CoreRuntime::new(short, identity.clone()).expect("runtime");
    let (lease, directive) = runtime
        .attach_managed_operation(common::request(44, &identity))
        .expect("managed attachment");
    assert_eq!(directive, ManagedOperationDirective::ContinueExecution);

    runtime.begin_shutdown(&identity).expect("shutdown");
    assert!(runtime.wait_for_terminal(Duration::from_secs(1)));
    assert_eq!(runtime.active_managed_operation_count(), 0);
    assert_eq!(
        lease.checkpoint().expect("forced terminal checkpoint"),
        ManagedOperationDirective::Terminal(TerminalOutcome::Cancelled)
    );
}

#[test]
fn shutdown_grace_preserves_authority_then_detaches_an_unmirrored_lease() {
    let identity = common::identity('a');
    let mut short = config(1);
    short.shutdown_grace = Duration::from_millis(25);
    let runtime = CoreRuntime::new(short, identity.clone()).expect("runtime");
    let (lease, directive) = runtime
        .attach_managed_operation(common::request(45, &identity))
        .expect("managed attachment");
    assert_eq!(directive, ManagedOperationDirective::ContinueExecution);
    let (_, permit) = runtime
        .begin_managed_authority_operation(&lease)
        .expect("managed authority");
    let permit = permit.expect("authority permit");

    runtime.begin_shutdown(&identity).expect("shutdown");
    assert!(!runtime.wait_for_terminal(Duration::from_millis(75)));
    drop(permit);
    assert!(runtime.wait_for_terminal(Duration::from_secs(1)));
    assert_eq!(runtime.active_authority_operation_count(), 0);
    assert_eq!(runtime.active_managed_operation_count(), 0);
    assert_eq!(
        lease.checkpoint().expect("detached authority checkpoint"),
        ManagedOperationDirective::Terminal(TerminalOutcome::Failed)
    );
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
