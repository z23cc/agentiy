//! E-1d -- Batch point-lookup cost curve.
//! `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §10 (new in v2, review Finding D).
//!
//! Measures `resolve_by_ids` (id-keyed) at N = 1/10/100/1000 and `lookup_by_paths` (path-keyed) at
//! N = 1/100/1000/10000, over a 100k-file single-root table -- the same size and N values as the
//! Swift reference captured in
//! `Tests/RepoPromptTests/WorkspaceContext/InventoryScopeSwiftBaselineTests.swift
//! .testSwiftInventoryScopeE1dBatchLookupBaseline`, and the same evenly-strided sampling shape
//! (avoids favoring low-index cache locality when N < total).
//!
//! Run: `CARGO_TARGET_DIR=/tmp/agentry-inventory-scope-spike-target cargo run --release --bin e1d_lookup`

use inventory_scope_spike::{measure, FileRecord, RootTable};

const FILE_COUNT: usize = 100_000;
const ID_NS: [usize; 4] = [1, 10, 100, 1000];
const PATH_NS: [usize; 4] = [1, 100, 1000, 10_000];
const WARMUP: usize = 1;
const SAMPLES: usize = 5;

fn sampled_indices(count: usize, total: usize) -> Vec<usize> {
    if count >= total {
        return (0..total).collect();
    }
    let stride = (total / count).max(1);
    (0..count).map(|i| (i * stride) % total).collect()
}

fn main() {
    let files: Vec<FileRecord> = (0..FILE_COUNT as u64).map(|i| FileRecord::synthetic(1, i)).collect();
    let table = RootTable::build_authoritative(1, files);
    let ordered_ids: Vec<u64> = (0..FILE_COUNT as u64).collect();
    let ordered_paths: Vec<String> = ordered_ids.iter().map(|&id| FileRecord::synthetic(1, id).standardized_relative_path).collect();

    println!("=== E-1d: id-keyed batch lookup (resolve_by_ids) ===");
    println!("n,p50_us,p99_us");
    for &n in &ID_NS {
        let idxs = sampled_indices(n, FILE_COUNT);
        let ids: Vec<u64> = idxs.iter().map(|&i| ordered_ids[i]).collect();
        let dist = measure(WARMUP, SAMPLES, || {
            let result = table.resolve_by_ids(&ids);
            std::hint::black_box(&result);
        });
        println!("{n},{:.4},{:.4}", dist.p50_micros, dist.p99_micros);
    }

    println!();
    println!("=== E-1d: path-keyed batch lookup (lookup_by_paths) ===");
    println!("n,p50_us,p99_us");
    for &n in &PATH_NS {
        let idxs = sampled_indices(n, FILE_COUNT);
        let paths: Vec<String> = idxs.iter().map(|&i| ordered_paths[i].clone()).collect();
        let dist = measure(WARMUP, SAMPLES, || {
            let result = table.lookup_by_paths(&paths);
            std::hint::black_box(&result);
        });
        println!("{n},{:.4},{:.4}", dist.p50_micros, dist.p99_micros);
    }

    println!();
    println!("=== E-1d: degenerate per-item loop (id-keyed, one resolve_by_ids([id]) call per item) ===");
    println!("n,total_p50_us,per_item_p50_us");
    for &n in &ID_NS {
        let idxs = sampled_indices(n, FILE_COUNT);
        let ids: Vec<u64> = idxs.iter().map(|&i| ordered_ids[i]).collect();
        let dist = measure(WARMUP, SAMPLES, || {
            for &id in &ids {
                let result = table.resolve_by_ids(&[id]);
                std::hint::black_box(&result);
            }
        });
        println!("{n},{:.4},{:.4}", dist.p50_micros, dist.p50_micros / n as f64);
    }

    println!();
    println!("=== E-1d: degenerate per-item loop (path-keyed, one lookup_by_paths([path]) call per item) ===");
    println!("n,total_p50_us,per_item_p50_us");
    for &n in &PATH_NS {
        let idxs = sampled_indices(n, FILE_COUNT);
        let paths: Vec<String> = idxs.iter().map(|&i| ordered_paths[i].clone()).collect();
        let dist = measure(WARMUP, SAMPLES, || {
            for path in &paths {
                let result = table.lookup_by_paths(std::slice::from_ref(path));
                std::hint::black_box(&result);
            }
        });
        println!("{n},{:.4},{:.4}", dist.p50_micros, dist.p50_micros / n as f64);
    }
}
