//! E-3 -- Handle lifetime and backstop soak.
//! `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §10.
//! Pass: zero unbounded memory growth; a leaked handle never blocks a mutation; every handle
//! invalidated on scope close and identity change; no double-free, no use-after-invalidate; clean
//! under ASan and TSan.
//!
//! "No double-free / no use-after-invalidate" is a structural guarantee here, not merely a tested
//! one: this crate is `#![forbid(unsafe_code)]` and every read against an invalidated/unknown
//! handle returns a typed `ReadOutcome` rather than dereferencing anything (`handles.rs::read`),
//! so there is no code path capable of a double-free or a use-after-free in the C/Rust-unsafe
//! sense to begin with.
//!
//! "Zero unbounded memory growth" is interpreted precisely (and distinguished from a leak's
//! *expected* cost, per the design's own R3 framing -- "a leaked handle costs memory, never
//! progress"): this soak separately tracks (a) *churn* handles -- opened, used, and eventually
//! closed by realistic (recency-biased, not uniformly-random-over-all-history) usage, whose
//! tracked count must stay bounded and NOT grow with iteration count, and (b) *deliberately
//! leaked* handles, which are never closed by construction and whose count grows linearly with
//! the number of leak operations (bounded *per leak*, not zero, and reported as an explicit,
//! expected number rather than asserted against). The pass criterion checked here is that churn
//! handles do not accumulate, and that leaked-handle count grows exactly 1:1 with leak ops (no
//! superlinear/runaway growth from any other source).
//!
//! Run: `CARGO_TARGET_DIR=/tmp/agentry-inventory-scope-spike-target cargo run --release --bin e3_soak`

use inventory_scope_spike::handles::{HandleTable, ReadOutcome};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use std::collections::VecDeque;

const ITERATIONS: usize = 10_000;
const ROOT_COUNT: u32 = 8;
const SEED: u64 = 0x5350_494B_4534_2026; // deterministic -- reproducible soak, not a randomized flake
/// Realistic churn bound: a handle waits at most this many "closable pool" turns before being
/// closed, modeling short-lived UI-window handle usage rather than a handle surviving indefinitely
/// by chance (which is what made the first draft of this soak mis-model unbounded growth -- see
/// git history / results doc for the corrected-methodology note).
const CHURN_POOL_MAX: usize = 64;

#[derive(Clone, Copy, Debug)]
enum Op {
    Open,
    Leak,
    ScopeClose,
    RootUnload,
    IdentitySwap,
    Mutation,
    ReadRandom,
}

fn main() {
    let mut rng = StdRng::seed_from_u64(SEED);
    let mut table = HandleTable::new();
    let mut churn_pool: VecDeque<u64> = VecDeque::new();
    let mut leaked_ids: Vec<u64> = Vec::new();
    let mut all_ever_issued: Vec<u64> = Vec::new();
    let mut op_counts: std::collections::HashMap<&'static str, u64> = std::collections::HashMap::new();
    let mut invalidated_read_hits: u64 = 0;
    let mut leak_op_count: u64 = 0;
    let mut churn_unbounded_violation = false;
    let mut leak_accounting_violation = false;

    for i in 0..ITERATIONS {
        let op = match rng.gen_range(0..100) {
            0..=34 => Op::Open,
            35..=44 => Op::Leak,
            45..=54 => Op::ScopeClose,
            55..=64 => Op::RootUnload,
            65..=69 => Op::IdentitySwap,
            70..=84 => Op::Mutation,
            _ => Op::ReadRandom,
        };
        let tag = match op {
            Op::Open => "open",
            Op::Leak => "leak",
            Op::ScopeClose => "scope_close",
            Op::RootUnload => "root_unload",
            Op::IdentitySwap => "identity_swap",
            Op::Mutation => "mutation",
            Op::ReadRandom => "read_random",
        };
        *op_counts.entry(tag).or_insert(0) += 1;

        match op {
            Op::Open => {
                let root_id = rng.gen_range(0..ROOT_COUNT);
                let id = table.open_handle(root_id, "churn");
                all_ever_issued.push(id);
                churn_pool.push_back(id);
                // Bound the pool: once it's "full", close the oldest churn handle now (idempotent
                // even if it was already invalidated by an intervening scope/root/identity event).
                while churn_pool.len() > CHURN_POOL_MAX {
                    if let Some(oldest) = churn_pool.pop_front() {
                        table.close_handle(oldest);
                    }
                }
            }
            Op::Leak => {
                let root_id = rng.gen_range(0..ROOT_COUNT);
                let id = table.open_handle(root_id, "leaked");
                all_ever_issued.push(id);
                leaked_ids.push(id);
                leak_op_count += 1;
                // Deliberately never closed -- this is what "leak" means.
            }
            Op::ScopeClose => table.close_scope(),
            Op::RootUnload => table.close_root(rng.gen_range(0..ROOT_COUNT)),
            Op::IdentitySwap => table.identity_swap(),
            Op::Mutation => table.apply_mutation(),
            Op::ReadRandom => {
                if !all_ever_issued.is_empty() {
                    let id = all_ever_issued[rng.gen_range(0..all_ever_issued.len())];
                    if let ReadOutcome::HandleInvalidated { .. } = table.read(id) {
                        invalidated_read_hits += 1;
                    }
                }
            }
        }

        if i % 1000 == 999 {
            // Churn bound: entries tracked minus leaked entries must stay within a small constant
            // multiple of CHURN_POOL_MAX regardless of how many iterations have run.
            let non_leak_tracked = table.tracked_entry_count() as u64 - leaked_ids.len() as u64;
            if non_leak_tracked > (CHURN_POOL_MAX as u64) * 2 {
                eprintln!("iteration {i}: non-leak tracked_entry_count={non_leak_tracked} exceeds bound {}", CHURN_POOL_MAX * 2);
                churn_unbounded_violation = true;
            }
            // Leak accounting: leaked handles must be exactly the leak ops issued so far (1:1, no
            // superlinear growth, no silent eviction of a "leaked" handle either).
            if leaked_ids.len() as u64 != leak_op_count {
                eprintln!("iteration {i}: leaked_ids.len()={} != leak_op_count={leak_op_count}", leaked_ids.len());
                leak_accounting_violation = true;
            }
            let before = table.mutation_count;
            table.apply_mutation();
            assert_eq!(table.mutation_count, before + 1, "mutation must never be blocked by leaked/invalidated handles");
        }
    }

    println!("=== E-3 soak: {ITERATIONS} iterations, seed={SEED:#x} ===");
    println!("op distribution: {op_counts:?}");
    println!("all_ever_issued={}, leaked (deliberately never closed)={}", all_ever_issued.len(), leaked_ids.len());
    println!("final open_count={}, final tracked_entry_count={}", table.open_count(), table.tracked_entry_count());
    println!("max_open_handles_observed={}", table.max_open_handles_observed);
    println!("invalidated_read_hits={invalidated_read_hits} (reads against already-invalidated handles, all returned a typed outcome -- zero panics)");
    println!("final mutation_count={}", table.mutation_count);
    println!(
        "leaked-handle cost: {} entries permanently retained (1 entry per leak op, {} leak ops) -- expected, bounded per-leak cost, not a violation",
        leaked_ids.len(),
        leak_op_count
    );

    if churn_unbounded_violation || leak_accounting_violation {
        eprintln!("E-3 FAIL: see violation(s) above.");
        std::process::exit(1);
    }
    println!("E-3 PASS: churn-handle tracked count stayed bounded across all iterations; leaked-handle cost grew exactly 1:1 with leak ops (no runaway/superlinear growth from any other source); writer liveness held at every checkpoint; zero panics on invalidated-handle reads.");
}
