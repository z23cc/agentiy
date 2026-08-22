//! Throwaway de-risking spike for **P4-2** (`docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md`
//! §10/§11's P4-2 entry). This is explicitly permitted by that design ("Prototype `InventoryScope`
//! in Rust with in-place sorted tables; measure single-delta and N-delta apply in a `cargo`
//! harness plus a minimal FFI round-trip") and is **not** the P4-3a production `InventoryScope`:
//! no `ScopeRegistry`, no eight fallback reasons, no `InventoryDiagnosticsV1` surface, no
//! production FFI wire format, no O(log n) critical-section discipline (`rust-inventory-scope-v1.md`
//! §2 -- that discipline is a P4-3a done-when line, mechanically enforced there, not here). This
//! crate exists only to produce real wall-clock/behavioral numbers for E-1, E-1c, E-1d, E-3, and
//! E-4 against the pre-registered criteria in `rust/benchmarks/slo-v1.json`'s `inventoryScopeV1`
//! key. Delete at or before P4-3a lands; nothing here is reused as production code.
//!
//! Ordering fidelity: Rust `String`/`str` `Ord` is already UTF-8 byte-value order, which is
//! exactly `WorkspaceInventoryOrdering.compareUTF8Binary`
//! (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Inventory/WorkspaceInventoryOrdering.swift:15-30`),
//! so no custom comparator is needed to reproduce
//! `searchRootCatalogFilePrecedes`/`searchCatalogFolderPrecedes`'s path-then-id single-root
//! ordering (`WorkspaceInventoryOrdering.swift:41-49`). ID tie-breaks compare as `u64` numeric
//! order rather than UUID-string order -- a documented simplification, immaterial to the
//! wall-clock numbers under measurement since ties are synthetic-corpus noise, not the operation
//! being timed.
//!
//! Patch-apply fidelity: `apply_single_upsert`/`apply_single_removal` mirror
//! `WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch`'s shape exactly
//! (`WorkspaceInventoryCatalogBuilders.swift:141-303`): remove-then-binary-search-insert against a
//! `Vec` kept sorted in place (an O(n) shift on insert, same as Swift's `Array.insert(at:)` --
//! this spike measures wall-clock parity against that real cost, not a smaller synthetic one).

#![forbid(unsafe_code)]

use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};

pub type FileId = u64;
pub type RootId = u32;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileRecord {
    pub id: FileId,
    pub root_id: RootId,
    pub standardized_relative_path: String,
    pub is_discoverable: bool,
}

impl FileRecord {
    pub fn synthetic(root_id: RootId, id: FileId) -> Self {
        FileRecord {
            id,
            root_id,
            standardized_relative_path: format!("src/module_{id:08}/file_{id:08}.swift"),
            is_discoverable: true,
        }
    }
}

/// One delta operation against a single root's table. Mirrors the touched-file shape of
/// `WorkspaceAppliedIndexBatchEvent` reduced to the single-logical-mutation case
/// (`maxLogicalMutationCount` at its only current call site), which is exactly what
/// `buildRootCatalogShardPatch` applies today.
#[derive(Clone, Debug)]
pub enum DeltaOp {
    Upsert(FileRecord),
    Remove(FileId),
}

/// Facts returned by a point lookup -- deliberately a fact bag, not a verdict, per the contract
/// doc's §5.3 ("the API returns facts; each call site composes its own predicate").
#[derive(Clone, Debug)]
pub struct FactRecord {
    pub exists: bool,
    pub id: Option<FileId>,
    pub root_id: Option<RootId>,
    pub is_discoverable: bool,
    pub standardized_relative_path: Option<String>,
}

impl FactRecord {
    fn missing() -> Self {
        FactRecord { exists: false, id: None, root_id: None, is_discoverable: false, standardized_relative_path: None }
    }
    fn from_record(r: &FileRecord) -> Self {
        FactRecord {
            exists: true,
            id: Some(r.id),
            root_id: Some(r.root_id),
            is_discoverable: r.is_discoverable,
            standardized_relative_path: Some(r.standardized_relative_path.clone()),
        }
    }
}

/// A single-root sorted table plus id/path indexes -- the "in-place sorted tables" E-1 asks for.
pub struct RootTable {
    pub root_id: RootId,
    /// Sorted by (standardized_relative_path, id) -- `searchRootCatalogFilePrecedes` order.
    sorted_ids: Vec<FileId>,
    records: HashMap<FileId, FileRecord>,
    path_to_id: BTreeMap<String, FileId>,
    pub generation: u64,
}

fn precedes(a_path: &str, a_id: FileId, b_path: &str, b_id: FileId) -> bool {
    match a_path.cmp(b_path) {
        std::cmp::Ordering::Less => true,
        std::cmp::Ordering::Greater => false,
        std::cmp::Ordering::Equal => a_id < b_id,
    }
}

impl RootTable {
    pub fn empty(root_id: RootId) -> Self {
        RootTable { root_id, sorted_ids: Vec::new(), records: HashMap::new(), path_to_id: BTreeMap::new(), generation: 0 }
    }

    /// Builds an authoritative (whole-table) shard from an unsorted record list -- mirrors
    /// `buildAuthoritativeCatalogComponents`'s filter+sort, single-root branch.
    pub fn build_authoritative(root_id: RootId, mut files: Vec<FileRecord>) -> Self {
        files.retain(|f| f.is_discoverable && f.root_id == root_id);
        files.sort_by(|a, b| {
            if precedes(&a.standardized_relative_path, a.id, &b.standardized_relative_path, b.id) {
                std::cmp::Ordering::Less
            } else if a.id == b.id && a.standardized_relative_path == b.standardized_relative_path {
                std::cmp::Ordering::Equal
            } else {
                std::cmp::Ordering::Greater
            }
        });
        let mut sorted_ids = Vec::with_capacity(files.len());
        let mut records = HashMap::with_capacity(files.len());
        let mut path_to_id = BTreeMap::new();
        for f in files {
            sorted_ids.push(f.id);
            path_to_id.insert(f.standardized_relative_path.clone(), f.id);
            records.insert(f.id, f);
        }
        RootTable { root_id, sorted_ids, records, path_to_id, generation: 0 }
    }

    pub fn len(&self) -> usize {
        self.sorted_ids.len()
    }

    fn binary_search_insert_pos(&self, path: &str, id: FileId) -> usize {
        let mut lo = 0usize;
        let mut hi = self.sorted_ids.len();
        while lo < hi {
            let mid = (lo + hi) / 2;
            let mid_id = self.sorted_ids[mid];
            let mid_rec = &self.records[&mid_id];
            if precedes(&mid_rec.standardized_relative_path, mid_id, path, id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    fn remove_id_from_sorted(&mut self, id: FileId) {
        if let Some(pos) = self.sorted_ids.iter().position(|&x| x == id) {
            self.sorted_ids.remove(pos);
        }
    }

    /// Applies one upsert: remove the prior record for this id (if any) and any record occupying
    /// the same path (path collision -- e.g. a remove+re-add of the same path), then binary-search
    /// insert the new record. Bumps `generation` (mirrors the atomic single-critical-section
    /// publication the design's bulk-load/patch model requires).
    pub fn apply_single_upsert(&mut self, record: FileRecord) {
        if let Some(prior) = self.records.remove(&record.id) {
            self.path_to_id.remove(&prior.standardized_relative_path);
            self.remove_id_from_sorted(record.id);
        }
        if let Some(colliding_id) = self.path_to_id.remove(&record.standardized_relative_path) {
            self.records.remove(&colliding_id);
            self.remove_id_from_sorted(colliding_id);
        }
        let pos = self.binary_search_insert_pos(&record.standardized_relative_path, record.id);
        self.sorted_ids.insert(pos, record.id);
        self.path_to_id.insert(record.standardized_relative_path.clone(), record.id);
        self.records.insert(record.id, record);
        self.generation += 1;
    }

    pub fn apply_single_removal(&mut self, id: FileId) {
        if let Some(rec) = self.records.remove(&id) {
            self.path_to_id.remove(&rec.standardized_relative_path);
            self.remove_id_from_sorted(id);
            self.generation += 1;
        }
    }

    pub fn apply_op(&mut self, op: DeltaOp) {
        match op {
            DeltaOp::Upsert(r) => self.apply_single_upsert(r),
            DeltaOp::Remove(id) => self.apply_single_removal(id),
        }
    }

    /// Applies a batch of ops as N sequential single-logical-mutation applications, one generation
    /// bump per op (matching today's `maxLogicalMutationCount=1` semantics N times over) -- this
    /// is the reference shape E-1's N-delta sweep measures against, to find D-1's batching
    /// crossover (a higher `maxLogicalMutationCount` would fold these into fewer generation bumps;
    /// out of scope for this spike, which measures the N-single-ops-per-call cost curve).
    pub fn apply_batch(&mut self, ops: Vec<DeltaOp>) {
        for op in ops {
            self.apply_op(op);
        }
    }

    pub fn resolve_by_ids(&self, ids: &[FileId]) -> Vec<FactRecord> {
        ids.iter()
            .map(|id| self.records.get(id).map(FactRecord::from_record).unwrap_or_else(FactRecord::missing))
            .collect()
    }

    pub fn lookup_by_paths(&self, paths: &[String]) -> Vec<FactRecord> {
        paths
            .iter()
            .map(|p| {
                self.path_to_id
                    .get(p)
                    .and_then(|id| self.records.get(id))
                    .map(FactRecord::from_record)
                    .unwrap_or_else(FactRecord::missing)
            })
            .collect()
    }
}

/// A minimal, representative single-delta encode/decode round trip -- the "minimal FFI round-trip"
/// E-1 explicitly asks the prototype to include, standing in for `inventory-scope-v1`'s string
/// interning + delta framing (`rust-inventory-scope-v1.md` §3) without implementing the full wire
/// format (out of scope for a throwaway spike; P4-4 owns the real codec).
pub mod wire {
    use super::{DeltaOp, FileRecord};

    /// Encodes one upsert delta as: [op:u8][id:u64][root_id:u32][discoverable:u8][path_len:u32][path bytes].
    pub fn encode_upsert(record: &FileRecord) -> Vec<u8> {
        let path_bytes = record.standardized_relative_path.as_bytes();
        let mut buf = Vec::with_capacity(1 + 8 + 4 + 1 + 4 + path_bytes.len());
        buf.push(1u8);
        buf.extend_from_slice(&record.id.to_le_bytes());
        buf.extend_from_slice(&record.root_id.to_le_bytes());
        buf.push(record.is_discoverable as u8);
        buf.extend_from_slice(&(path_bytes.len() as u32).to_le_bytes());
        buf.extend_from_slice(path_bytes);
        buf
    }

    pub fn decode_upsert(buf: &[u8]) -> DeltaOp {
        assert_eq!(buf[0], 1u8, "spike wire format only encodes upserts");
        let id = u64::from_le_bytes(buf[1..9].try_into().unwrap());
        let root_id = u32::from_le_bytes(buf[9..13].try_into().unwrap());
        let is_discoverable = buf[13] != 0;
        let path_len = u32::from_le_bytes(buf[14..18].try_into().unwrap()) as usize;
        let path = String::from_utf8(buf[18..18 + path_len].to_vec()).expect("valid utf8");
        DeltaOp::Upsert(FileRecord { id, root_id, standardized_relative_path: path, is_discoverable })
    }
}

/// Shared measurement harness: mirrors the Swift baseline's warmup/sample convention
/// (`Tests/RepoPromptTests/WorkspaceContext/InventoryScopeSwiftBaselineTests.swift`) so numbers
/// are directly comparable rather than an artifact of a different sampling shape.
pub struct Distribution {
    pub p50_micros: f64,
    pub p99_micros: f64,
    pub samples_micros: Vec<f64>,
}

pub fn measure<F: FnMut()>(warmup: usize, samples: usize, mut body: F) -> Distribution {
    for _ in 0..warmup {
        body();
    }
    let mut durations: Vec<f64> = Vec::with_capacity(samples);
    for _ in 0..samples {
        let start = Instant::now();
        body();
        durations.push(start.elapsed().as_secs_f64() * 1_000_000.0);
    }
    let mut sorted = durations.clone();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let p50 = percentile(&sorted, 0.50);
    let p99 = percentile(&sorted, 0.99);
    Distribution { p50_micros: p50, p99_micros: p99, samples_micros: durations }
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

pub fn duration_micros(d: Duration) -> f64 {
    d.as_secs_f64() * 1_000_000.0
}

pub mod watermark;
pub mod handles;
pub mod contention;
