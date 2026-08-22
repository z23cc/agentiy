//! E-1 -- Delta-path viability (kill criterion for the whole P4 design).
//! `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §10.
//!
//! Measures single-delta apply (a) in-process table-only cost and (b) that cost plus a minimal
//! encode/decode round trip standing in for the FFI boundary, at sizes 100/1k/10k/100k, and a
//! N-delta batch sweep (N = 1/2/5/10/25/50/100) at each size to surface D-1's batching crossover.
//!
//! Measurement methodology: each size point starts from one `build_authoritative` table (built
//! once, untimed) and then applies warmup + sample deltas **sequentially against that same live
//! table**, timing only each individual `apply_single_upsert`/`apply_batch` call. This avoids
//! re-cloning or re-sorting the whole table per sample (which would time an O(n log n) rebuild,
//! not the O(delta) marginal-apply cost E-1 asks about) at the cost of the table growing by a few
//! hundred records across warmup+samples -- negligible relative to `n` at every size point (at
//! worst 1 + 5 = 6 extra records at n=100, a 6% base-size drift, reported as-is rather than hidden).
//!
//! **Insert-position correction (post-review):** an earlier draft generated every new delta's path
//! from a monotonically increasing id, which under `searchRootCatalogFilePrecedes`'s lexicographic
//! ordering always sorts to the *end* of the table -- every insert was a zero-cost `Vec` append,
//! never a mid-vector insert/memmove. That measured "appending is cheap", not "single-delta apply
//! is cheap" in general, and silently made the N-delta batch sweep's "flat per-delta cost" finding
//! an artifact of the same bias rather than evidence about batching. `scrambled_record` below
//! derives each new record's path from a multiplicative-hash scramble of its id so new records
//! land at pseudo-random positions across the table's existing sorted range, forcing a real
//! mid-vector `Vec::insert`/memmove (and, for removals during re-upsert collisions, a real linear
//! scan) on every timed operation. All numbers in this file reflect the corrected, position-neutral
//! measurement; see the results doc's methodology note for the before/after comparison.
//!
//! Run: `CARGO_TARGET_DIR=/tmp/agentry-inventory-scope-spike-target cargo run --release --bin e1_delta_apply`

use inventory_scope_spike::{measure, wire, DeltaOp, FileRecord, RootTable};

const SIZES: [usize; 4] = [100, 1_000, 10_000, 100_000];
const BATCH_NS: [usize; 7] = [1, 2, 5, 10, 25, 50, 100];
const WARMUP: usize = 1;
const SAMPLES: usize = 5;

fn build_table(root_id: u32, n: usize) -> RootTable {
    let files: Vec<FileRecord> = (0..n as u64).map(|i| FileRecord::synthetic(root_id, i)).collect();
    RootTable::build_authoritative(root_id, files)
}

/// A new record whose path scrambles its id via a multiplicative hash (Fibonacci hashing), so its
/// sort position is pseudo-uniform across `[0, universe)` rather than always sorting last. `id`
/// stays globally unique (included in the path too) so no two generated records collide.
fn scrambled_record(root_id: u32, id: u64, universe: u64) -> FileRecord {
    let scrambled = id.wrapping_mul(0x9E37_79B9_7F4A_7C15) % universe.max(1);
    FileRecord {
        id,
        root_id,
        standardized_relative_path: format!("src/module_{scrambled:08}/file_{id:08}.swift"),
        is_discoverable: true,
    }
}

fn main() {
    println!("=== E-1: single-delta apply (table-only, no wire round trip), position-scrambled inserts ===");
    println!("size,p50_us,p99_us,final_table_len");
    for &n in &SIZES {
        let mut table = build_table(1, n);
        let mut next_id = n as u64;
        let dist = measure(WARMUP, SAMPLES, || {
            table.apply_single_upsert(scrambled_record(1, next_id, n as u64));
            next_id += 1;
        });
        println!("{n},{:.4},{:.4},{}", dist.p50_micros, dist.p99_micros, table.len());
    }

    println!();
    println!("=== E-1: single-delta apply + minimal encode/decode round trip, position-scrambled inserts ===");
    println!("size,p50_us,p99_us,final_table_len");
    for &n in &SIZES {
        let mut table = build_table(1, n);
        let mut next_id = n as u64;
        let dist = measure(WARMUP, SAMPLES, || {
            let record = scrambled_record(1, next_id, n as u64);
            next_id += 1;
            let encoded = wire::encode_upsert(&record);
            let decoded = wire::decode_upsert(&encoded);
            match decoded {
                DeltaOp::Upsert(r) => table.apply_single_upsert(r),
                DeltaOp::Remove(_) => unreachable!(),
            }
        });
        println!("{n},{:.4},{:.4},{}", dist.p50_micros, dist.p99_micros, table.len());
    }

    println!();
    println!("=== E-1: N-delta batch apply, table-only, position-scrambled inserts (per-delta amortized cost) ===");
    println!("size,batch_n,total_p50_us,per_delta_p50_us");
    for &n in &SIZES {
        for &batch_n in &BATCH_NS {
            let mut table = build_table(1, n);
            let mut next_id = n as u64;
            let dist = measure(WARMUP, SAMPLES, || {
                let ops: Vec<DeltaOp> = (0..batch_n)
                    .map(|_| {
                        let r = scrambled_record(1, next_id, n as u64);
                        next_id += 1;
                        DeltaOp::Upsert(r)
                    })
                    .collect();
                table.apply_batch(ops);
            });
            println!("{n},{batch_n},{:.4},{:.4}", dist.p50_micros, dist.p50_micros / batch_n as f64);
        }
    }
}
