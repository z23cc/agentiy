mod common;

use agentry_runtime::{
    AdmissionOutcome, CoreRuntime, OperationState, RuntimeConfig, TerminalOutcome,
};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

const ITERATIONS: usize = 12_000;
const SEEDS: &str = include_str!("fixtures/random-seeds-v1.txt");

#[test]
fn admission_cancel_randomized_soak_has_no_operation_or_task_leaks() {
    let started = Instant::now();
    let identity = common::identity('a');
    let runtime = Arc::new(
        CoreRuntime::new(
            RuntimeConfig {
                data_lane_capacity: ITERATIONS + 1,
                cancel_tombstone_window: Duration::from_secs(30),
                shutdown_grace: Duration::from_secs(2),
            },
            identity.clone(),
        )
        .expect("runtime"),
    );
    let seeds: Vec<u64> = SEEDS
        .lines()
        .map(|line| line.parse().expect("seed"))
        .collect();
    assert_eq!(seeds.len(), 6);

    let mut state = seeds.iter().fold(0x9e37_79b9_7f4a_7c15, |state, seed| {
        state ^ seed.rotate_left((*seed % 63) as u32)
    });
    let mut post_admission_cancels = Vec::new();
    let mut accepted = 0_usize;
    let mut cancelled_before = 0_usize;
    for index in 0..ITERATIONS {
        state = xorshift64(state);
        let request = common::request(index as u128 + 1, &identity);
        let id = request.operation_id.clone();
        if state & 0b11 == 0 {
            runtime
                .cancel(&identity, id.clone())
                .expect("cancel before admission");
            cancelled_before += 1;
        }
        let delay = Duration::from_micros((state >> 8) % 500);
        match runtime
            .submit(request, async move {
                tokio::time::sleep(delay).await;
                TerminalOutcome::Success
            })
            .expect("submit")
        {
            AdmissionOutcome::Accepted => {
                accepted += 1;
                if state & 1 == 1 {
                    post_admission_cancels.push(id);
                }
            }
            AdmissionOutcome::Duplicate(OperationState::Terminal(TerminalOutcome::Cancelled)) => {}
            other => panic!("unexpected admission result: {other:?}"),
        }
    }

    let cancel_chunks: Vec<Vec<_>> = (0..4)
        .map(|worker| {
            post_admission_cancels
                .iter()
                .skip(worker)
                .step_by(4)
                .cloned()
                .collect()
        })
        .collect();
    let mut workers = Vec::new();
    for ids in cancel_chunks {
        let runtime = Arc::clone(&runtime);
        let identity = identity.clone();
        workers.push(thread::spawn(move || {
            for id in ids {
                runtime.cancel(&identity, id).expect("racing cancel");
            }
        }));
    }
    for worker in workers {
        worker.join().expect("cancel worker");
    }

    runtime.begin_shutdown(&identity).expect("shutdown");
    assert!(runtime.wait_for_terminal(Duration::from_secs(5)));
    assert_eq!(runtime.active_task_count(), 0);
    assert_eq!(runtime.registry().active_count(), 0);
    for index in 0..ITERATIONS {
        let snapshot = runtime
            .registry()
            .snapshot(&common::operation_id(index as u128 + 1))
            .expect("terminal tombstone");
        assert!(snapshot.state.is_terminal());
    }
    eprintln!(
        "randomized lifecycle soak: iterations={ITERATIONS} accepted={accepted} cancel_before={cancelled_before} elapsed_ms={}",
        started.elapsed().as_millis()
    );
}

fn xorshift64(mut value: u64) -> u64 {
    if value == 0 {
        value = 0x2545_f491_4f6c_dd1d;
    }
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    value
}
