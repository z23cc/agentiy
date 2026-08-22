//! E-2 -- Read economics and payload truth (partial; see results doc for the full
//! measurable-vs-blocked breakdown).
//! `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §10.
//!
//! This spike has no bridge (P4-4), no `@MainActor` integration (P4-6b), and no suggestion-service
//! haystack/ranking logic (P4-7) -- the criteria that need those (`@MainActor` apply cost, actual
//! wire bytes, time-to-first-paint, the mention/suggestion query, the B2 projected-shard page) are
//! **not measured here** and are reported BLOCKED in the results doc, not silently passed. What
//! *is* measurable pre-bridge: allocation count and malloc-byte cost of the Rust-side Tier-1
//! operations already exercised by E-1/E-1d (build + batch read), using a counting global
//! allocator. Wall/CPU time for the same operations is already captured by E-1/E-1d and is not
//! re-measured here to avoid duplicate numbers drifting apart.
//!
//! Run: `CARGO_TARGET_DIR=/tmp/agentry-inventory-scope-spike-target cargo run --release --bin e2_read_economics`

use inventory_scope_spike::{FileRecord, RootTable};
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicU64, Ordering};

struct CountingAllocator;

static ALLOC_COUNT: AtomicU64 = AtomicU64::new(0);
static ALLOC_BYTES: AtomicU64 = AtomicU64::new(0);

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOC_COUNT.fetch_add(1, Ordering::Relaxed);
        ALLOC_BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

fn reset_counters() -> (u64, u64) {
    (ALLOC_COUNT.swap(0, Ordering::Relaxed), ALLOC_BYTES.swap(0, Ordering::Relaxed))
}

fn read_counters() -> (u64, u64) {
    (ALLOC_COUNT.load(Ordering::Relaxed), ALLOC_BYTES.load(Ordering::Relaxed))
}

fn main() {
    println!("=== E-2 (partial): allocation-count / malloc-bytes for Rust Tier-1 operations ===");
    println!("NOTE: wall/CPU time for these same operations is reported by E-1/E-1d, not duplicated here.");
    println!("NOTE: MainActor apply cost, wire bytes, time-to-first-paint, mention-query, and B2 shard page are NOT measured -- see results doc (BLOCKED, no bridge/MainActor/suggestion-service integration exists pre-P4-4/P4-6b/P4-7).");
    println!();

    let _ = reset_counters();
    let files: Vec<FileRecord> = (0..100_000u64).map(|i| FileRecord::synthetic(1, i)).collect();
    let (_, _) = read_counters();
    let _ = reset_counters();
    let table = RootTable::build_authoritative(1, files);
    let (build_allocs, build_bytes) = read_counters();
    println!("build_authoritative(100k files): allocations={build_allocs}, malloc_bytes={build_bytes} ({:.2} MiB)", build_bytes as f64 / 1_048_576.0);

    let ids: Vec<u64> = (0..1000).collect();
    let _ = reset_counters();
    let result = table.resolve_by_ids(&ids);
    let (read_allocs, read_bytes) = read_counters();
    std::hint::black_box(&result);
    println!("resolve_by_ids(N=1000): allocations={read_allocs}, malloc_bytes={read_bytes}");

    let paths: Vec<String> = (0..1000u64).map(|i| FileRecord::synthetic(1, i).standardized_relative_path).collect();
    let _ = reset_counters();
    let result = table.lookup_by_paths(&paths);
    let (path_allocs, path_bytes) = read_counters();
    std::hint::black_box(&result);
    println!("lookup_by_paths(N=1000, path Vec<String> pre-built, not counted): allocations={path_allocs}, malloc_bytes={path_bytes}");

    println!();
    println!(
        "approximate resident size of the 100k-file table's own structures (sorted_ids Vec<u64> + records HashMap + path_to_id BTreeMap, rough lower bound, ignores allocator overhead/fragmentation): {:.2} MiB",
        approx_table_bytes(table.len()) as f64 / 1_048_576.0
    );
}

fn approx_table_bytes(n: usize) -> usize {
    // sorted_ids: Vec<u64>
    let sorted_ids = n * std::mem::size_of::<u64>();
    // records: HashMap<u64, FileRecord> -- FileRecord has a String (path, ~48 bytes avg content
    // assumed here) plus fixed fields; HashMap entry overhead approximated at 1.15x load factor.
    let file_record_fixed = std::mem::size_of::<u64>() + std::mem::size_of::<u32>() + std::mem::size_of::<bool>() + std::mem::size_of::<String>();
    let avg_path_len = 48;
    let records = ((n * (file_record_fixed + avg_path_len)) as f64 * 1.15) as usize;
    // path_to_id: BTreeMap<String, u64> -- string content duplicated as the key.
    let path_index = ((n * (avg_path_len + std::mem::size_of::<u64>())) as f64 * 1.3) as usize; // btree node overhead approximation
    sorted_ids + records + path_index
}
