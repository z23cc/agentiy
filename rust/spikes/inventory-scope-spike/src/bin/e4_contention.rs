//! E-4 -- Apply/read contention under an in-flight authoritative rebuild.
//! `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §10 (new in v2, review Finding 4).
//! Pass: p99 added read latency attributable to contention < 1 ms; writer liveness never blocked;
//! clean under TSan. Also answers open question 6 (per-root vs per-scope locking) by producing the
//! per-root-lock evidence rather than a guess -- run at 8 roots, comparing `PerScopeLock` (today's
//! §5.2.1 default) against `PerRootLock`.
//!
//! Topology: 8 roots, one writer thread continuously applying deltas to root 0, one thread
//! repeatedly running the out-of-lock "expensive authoritative rebuild + lock-only-install" cycle
//! on root 1, and 4 reader threads issuing `resolve_by_ids` pages against *every* root in a round
//! robin, all concurrently for a fixed duration. Reader latency is what's compared.
//!
//! Run: `CARGO_TARGET_DIR=/tmp/agentry-inventory-scope-spike-target cargo run --release --bin e4_contention`

use inventory_scope_spike::contention::{simulate_expensive_rebuild, PerRootLock, PerScopeLock};
use inventory_scope_spike::{DeltaOp, FileRecord, RootTable};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

const ROOT_COUNT: u32 = 8;
const ROOT_FILE_COUNT: usize = 20_000;
const REBUILD_ROOT_FILE_COUNT: usize = 100_000; // the root undergoing rebuild is large, to make the rebuild genuinely expensive
const READER_THREADS: usize = 4;
const RUN_DURATION: Duration = Duration::from_secs(3);

fn build_roots() -> Vec<RootTable> {
    (0..ROOT_COUNT)
        .map(|r| {
            let n = if r == 1 { REBUILD_ROOT_FILE_COUNT } else { ROOT_FILE_COUNT };
            let files: Vec<FileRecord> = (0..n as u64).map(|i| FileRecord::synthetic(r, i)).collect();
            RootTable::build_authoritative(r, files)
        })
        .collect()
}

struct RunResult {
    read_latencies_us: Vec<f64>,
    writer_ops: u64,
    rebuild_installs: u64,
}

fn main() {
    println!("=== E-4: apply/read contention under in-flight authoritative rebuild ===");
    println!("roots={ROOT_COUNT}, reader_threads={READER_THREADS}, run_duration={:?}", RUN_DURATION);
    println!();

    println!("--- topology: PerScopeLock (one Mutex for all {ROOT_COUNT} roots -- today's §5.2.1 default) ---");
    let scope_result = run_scope_topology(RUN_DURATION);
    report(&scope_result);

    println!();
    println!("--- topology: PerRootLock (one Mutex per root) ---");
    let root_result = run_root_topology(RUN_DURATION);
    report(&root_result);

    println!();
    let scope_p99 = percentile(&scope_result.read_latencies_us, 0.99);
    let root_p99 = percentile(&root_result.read_latencies_us, 0.99);
    println!("=== E-4 summary ===");
    println!("PerScopeLock p99 added read latency: {scope_p99:.4} us (pass bound: < 1000 us)");
    println!("PerRootLock  p99 added read latency: {root_p99:.4} us (pass bound: < 1000 us)");
    println!(
        "Open question 6 evidence: per-root locking {} reduce p99 contention latency at {ROOT_COUNT} roots (per-scope={scope_p99:.4}us vs per-root={root_p99:.4}us, {:.2}x)",
        if root_p99 < scope_p99 * 0.9 { "MEASURABLY DOES" } else if root_p99 > scope_p99 * 1.1 { "does NOT (per-root was worse)" } else { "does not meaningfully" },
        scope_p99 / root_p99.max(0.0001)
    );

    let scope_pass = scope_p99 < 1000.0 && scope_result.writer_ops > 0;
    let root_pass = root_p99 < 1000.0 && root_result.writer_ops > 0;
    if !scope_pass {
        eprintln!("E-4 FAIL: PerScopeLock topology missed the p99 < 1ms bound or writer was blocked.");
        std::process::exit(1);
    }
    println!("E-4 PASS (PerScopeLock, today's default topology): p99 < 1ms and writer liveness held.");
    if !root_pass {
        println!("(informational: PerRootLock topology missed the bound in this run -- not gating, see open-question-6 evidence above)");
    }
}

fn percentile(sorted_input: &[f64], p: f64) -> f64 {
    if sorted_input.is_empty() {
        return 0.0;
    }
    let mut v = sorted_input.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let idx = ((v.len() as f64 - 1.0) * p).round() as usize;
    v[idx.min(v.len() - 1)]
}

fn report(r: &RunResult) {
    let p50 = percentile(&r.read_latencies_us, 0.50);
    let p99 = percentile(&r.read_latencies_us, 0.99);
    let max = r.read_latencies_us.iter().cloned().fold(0.0, f64::max);
    println!(
        "  reads={}, p50={:.4}us, p99={:.4}us, max={:.4}us, writer_ops={}, rebuild_installs={}",
        r.read_latencies_us.len(),
        p50,
        p99,
        max,
        r.writer_ops,
        r.rebuild_installs
    );
}

fn run_scope_topology(duration: Duration) -> RunResult {
    let lock = Arc::new(PerScopeLock::new(build_roots()));
    let stop = Arc::new(AtomicBool::new(false));
    let writer_ops = Arc::new(AtomicU64::new(0));
    let rebuild_installs = Arc::new(AtomicU64::new(0));

    let mut handles = Vec::new();

    {
        let lock = Arc::clone(&lock);
        let stop = Arc::clone(&stop);
        let writer_ops = Arc::clone(&writer_ops);
        handles.push(thread::spawn(move || {
            let mut next_id = ROOT_FILE_COUNT as u64;
            while !stop.load(Ordering::Relaxed) {
                lock.apply_delta(0, DeltaOp::Upsert(FileRecord::synthetic(0, next_id)));
                next_id += 1;
                writer_ops.fetch_add(1, Ordering::Relaxed);
            }
        }));
    }
    {
        let lock = Arc::clone(&lock);
        let stop = Arc::clone(&stop);
        let rebuild_installs = Arc::clone(&rebuild_installs);
        handles.push(thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                let rebuilt = simulate_expensive_rebuild(1, REBUILD_ROOT_FILE_COUNT); // out-of-lock, expensive
                lock.install_rebuilt(1, rebuilt); // lock held only for the swap
                rebuild_installs.fetch_add(1, Ordering::Relaxed);
            }
        }));
    }
    let mut reader_handles = Vec::new();
    for reader_idx in 0..READER_THREADS {
        let lock = Arc::clone(&lock);
        let stop = Arc::clone(&stop);
        reader_handles.push(thread::spawn(move || {
            let mut latencies = Vec::new();
            let mut root_cursor = reader_idx as u32;
            while !stop.load(Ordering::Relaxed) {
                let root = (root_cursor % ROOT_COUNT) as usize;
                root_cursor += 1;
                let ids: Vec<u64> = (0..16).collect();
                let start = Instant::now();
                let (_facts, _inner) = lock.read_resolve(root, &ids);
                latencies.push(inventory_scope_spike::duration_micros(start.elapsed()));
            }
            latencies
        }));
    }

    thread::sleep(duration);
    stop.store(true, Ordering::Relaxed);
    for h in handles {
        h.join().unwrap();
    }
    let mut all_latencies = Vec::new();
    for h in reader_handles {
        all_latencies.extend(h.join().unwrap());
    }

    RunResult {
        read_latencies_us: all_latencies,
        writer_ops: writer_ops.load(Ordering::Relaxed),
        rebuild_installs: rebuild_installs.load(Ordering::Relaxed),
    }
}

fn run_root_topology(duration: Duration) -> RunResult {
    let lock = Arc::new(PerRootLock::new(build_roots()));
    let stop = Arc::new(AtomicBool::new(false));
    let writer_ops = Arc::new(AtomicU64::new(0));
    let rebuild_installs = Arc::new(AtomicU64::new(0));

    let mut handles = Vec::new();
    {
        let lock = Arc::clone(&lock);
        let stop = Arc::clone(&stop);
        let writer_ops = Arc::clone(&writer_ops);
        handles.push(thread::spawn(move || {
            let mut next_id = ROOT_FILE_COUNT as u64;
            while !stop.load(Ordering::Relaxed) {
                lock.apply_delta(0, DeltaOp::Upsert(FileRecord::synthetic(0, next_id)));
                next_id += 1;
                writer_ops.fetch_add(1, Ordering::Relaxed);
            }
        }));
    }
    {
        let lock = Arc::clone(&lock);
        let stop = Arc::clone(&stop);
        let rebuild_installs = Arc::clone(&rebuild_installs);
        handles.push(thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                let rebuilt = simulate_expensive_rebuild(1, REBUILD_ROOT_FILE_COUNT);
                lock.install_rebuilt(1, rebuilt);
                rebuild_installs.fetch_add(1, Ordering::Relaxed);
            }
        }));
    }
    let mut reader_handles = Vec::new();
    for reader_idx in 0..READER_THREADS {
        let lock = Arc::clone(&lock);
        let stop = Arc::clone(&stop);
        reader_handles.push(thread::spawn(move || {
            let mut latencies = Vec::new();
            let mut root_cursor = reader_idx as u32;
            while !stop.load(Ordering::Relaxed) {
                let root = (root_cursor % ROOT_COUNT) as usize;
                root_cursor += 1;
                let ids: Vec<u64> = (0..16).collect();
                let start = Instant::now();
                let (_facts, _inner) = lock.read_resolve(root, &ids);
                latencies.push(inventory_scope_spike::duration_micros(start.elapsed()));
            }
            latencies
        }));
    }

    thread::sleep(duration);
    stop.store(true, Ordering::Relaxed);
    for h in handles {
        h.join().unwrap();
    }
    let mut all_latencies = Vec::new();
    for h in reader_handles {
        all_latencies.extend(h.join().unwrap());
    }

    RunResult {
        read_latencies_us: all_latencies,
        writer_ops: writer_ops.load(Ordering::Relaxed),
        rebuild_installs: rebuild_installs.load(Ordering::Relaxed),
    }
}
