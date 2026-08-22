//! P4-3a done-when: "property tests for watermark and generation monotonicity" and "the two
//! per-root discoverable-count aggregates ... covered by a counter-equals-traversal differential"
//! (`docs/architecture/rust-inventory-scope-v1.md`, design §11 P4-3a, §4.3.1.2/D-12).

use proptest::prelude::*;

use agentry_runtime::RuntimeIdentity;
use agentry_runtime::inventory::{
    InventoryAppliedIndexBatchEvent, InventoryFileRecord, InventoryFolderRecord,
};
use agentry_runtime::inventory_scope::ingress_gate::IngressGateState;
use agentry_runtime::inventory_scope::{
    IdentityMaps, InventoryApplyOutcome, InventoryDeltaCommand, InventoryScope,
    InventoryScopeConfig, InventoryScopeId,
};

fn identity() -> RuntimeIdentity {
    RuntimeIdentity::new(1, "c".repeat(32), "d".repeat(64), "e".repeat(64)).expect("identity")
}

fn file(byte: u8, root: [u8; 16], rel: &str) -> InventoryFileRecord {
    let mut id = [0u8; 16];
    id[0] = 0x11;
    id[15] = byte;
    InventoryFileRecord {
        id,
        root_id: root,
        name: rel.to_owned(),
        relative_path: rel.to_owned(),
        standardized_relative_path: rel.to_owned(),
        full_path: format!("/root/{rel}"),
        standardized_full_path: format!("/root/{rel}"),
        parent_folder_id: None,
        modification_date: None,
    }
}

fn event_with_upserts(
    root: [u8; 16],
    files: Vec<InventoryFileRecord>,
) -> InventoryAppliedIndexBatchEvent {
    InventoryAppliedIndexBatchEvent {
        root_id: root,
        upserted_files: files,
        upserted_folders: vec![],
        removed_file_ids: vec![],
        removed_folder_ids: vec![],
        removed_file_paths: vec![],
        removed_folder_paths: vec![],
        modified_file_ids: vec![],
        modified_folder_ids: vec![],
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

    /// Watermark baseline monotonicity (§5.1's three constraints), independent of re-deriving
    /// the gate's own algorithm: the tracked baseline never decreases; a rejection never mutates
    /// it; an accepted non-nil watermark always folds in via `max`.
    #[test]
    fn watermark_baseline_is_monotonically_non_decreasing(
        steps in prop::collection::vec((prop::option::of(0u64..1000), any::<bool>()), 1..80)
    ) {
        let mut gate = IngressGateState::new();
        for (watermark, requires_full_resync) in steps {
            let before = gate.last_applied_watermark();
            let result = gate.admit_watermark(watermark, requires_full_resync);
            let after = gate.last_applied_watermark();

            if let (Some(b), Some(a)) = (before, after) {
                prop_assert!(a >= b, "baseline must never decrease: {b} -> {a}");
            }

            match result {
                Ok(()) => {
                    let expected = match watermark {
                        Some(w) => Some(before.map_or(w, |b| b.max(w))),
                        None => before,
                    };
                    prop_assert_eq!(after, expected);
                }
                Err(_) => {
                    prop_assert_eq!(after, before, "a rejection must never mutate the baseline");
                    prop_assert!(!requires_full_resync, "a full-resync publication must never be rejected");
                    if let (Some(w), Some(b)) = (watermark, before) {
                        prop_assert!(w < b, "rejection must only occur when strictly stale");
                    }
                }
            }
        }
    }

    /// `applied_index_generation` / `catalog_generation` monotonicity across a delta sequence
    /// against one root: every successful (non-rejected) outcome strictly advances both; every
    /// rejection leaves both unchanged.
    #[test]
    fn applied_index_and_catalog_generation_are_monotonic_across_a_delta_sequence(
        steps in prop::collection::vec((1u8..=3, any::<bool>(), prop::option::of(0u64..50)), 1..40)
    ) {
        let identity = identity();
        let root = [3u8; 16];
        let scope = InventoryScope::new_seeded_for_testing(
            identity.clone(),
            InventoryScopeId::from_bytes([3; 16]),
            InventoryScopeConfig::default(),
            0x5eed,
        );
        let lifetime = scope.open_root(&identity, root, "Root".into(), "/root".into()).expect("open_root");

        let mut previous_applied: u64 = 0;
        let mut previous_catalog: Option<u64> = None;
        let mut next_file_byte: u8 = 1;

        for (file_count, requires_full_resync, watermark) in steps {
            let mut files = Vec::new();
            for _ in 0..file_count {
                files.push(file(next_file_byte, root, &format!("f{next_file_byte}.swift")));
                next_file_byte = next_file_byte.wrapping_add(1);
            }
            let command = InventoryDeltaCommand {
                scope_id: scope.scope_id(),
                root_id: root,
                root_lifetime_id: lifetime,
                watcher_accepted_watermark: watermark,
                requires_full_resync,
                expected_applied_index_generation: None,
                source: "prop".into(),
                event: event_with_upserts(root, files),
            };
            let receipt = scope.apply_delta(&identity, command);
            match receipt.outcome {
                InventoryApplyOutcome::Rejected(_) => {
                    prop_assert_eq!(receipt.applied_index_generation, previous_applied);
                    prop_assert_eq!(receipt.catalog_generation, previous_catalog);
                }
                InventoryApplyOutcome::Patched | InventoryApplyOutcome::RebuiltAuthoritative => {
                    prop_assert!(receipt.applied_index_generation > previous_applied);
                    let catalog = receipt.catalog_generation.expect("a successful outcome always publishes");
                    if let Some(prev_catalog) = previous_catalog {
                        prop_assert!(catalog > prev_catalog);
                    }
                    previous_applied = receipt.applied_index_generation;
                    previous_catalog = Some(catalog);
                }
            }
        }
    }
}

#[derive(Clone, Debug)]
enum MapOp {
    UpsertFile { id_index: u8, path_index: u8 },
    RemoveFile { id_index: u8 },
    SetFileManagedOnly { id_index: u8, managed: bool },
    UpsertFolder { id_index: u8, path_index: u8 },
    RemoveFolder { id_index: u8 },
    SetFolderManagedOnly { id_index: u8, managed: bool },
}

fn map_op_strategy() -> impl Strategy<Value = MapOp> {
    prop_oneof![
        (0u8..5, 0u8..5).prop_map(|(id_index, path_index)| MapOp::UpsertFile {
            id_index,
            path_index
        }),
        (0u8..5).prop_map(|id_index| MapOp::RemoveFile { id_index }),
        (0u8..5, any::<bool>())
            .prop_map(|(id_index, managed)| MapOp::SetFileManagedOnly { id_index, managed }),
        (0u8..5, 0u8..5).prop_map(|(id_index, path_index)| MapOp::UpsertFolder {
            id_index,
            path_index
        }),
        (0u8..5).prop_map(|id_index| MapOp::RemoveFolder { id_index }),
        (0u8..5, any::<bool>())
            .prop_map(|(id_index, managed)| MapOp::SetFolderManagedOnly { id_index, managed }),
    ]
}

fn uuid_for(tag: u8, index: u8) -> [u8; 16] {
    let mut id = [0u8; 16];
    id[0] = tag;
    id[15] = index;
    id
}

/// Small path space (including the empty relative path, the root-folder exclusion case) so
/// repeated ops force real path collisions, not just distinct fresh paths.
fn path_for(index: u8) -> String {
    if index == 0 {
        String::new()
    } else {
        format!("path{index}")
    }
}

fn file_record(id_index: u8, path_index: u8) -> InventoryFileRecord {
    let path = path_for(path_index);
    InventoryFileRecord {
        id: uuid_for(0xF0, id_index),
        root_id: [0; 16],
        name: path.clone(),
        relative_path: path.clone(),
        standardized_relative_path: path.clone(),
        full_path: format!("/root/{path}"),
        standardized_full_path: format!("/root/{path}"),
        parent_folder_id: None,
        modification_date: None,
    }
}

fn folder_record(id_index: u8, path_index: u8) -> InventoryFolderRecord {
    let path = path_for(path_index);
    InventoryFolderRecord {
        id: uuid_for(0xE0, id_index),
        root_id: [0; 16],
        name: path.clone(),
        relative_path: path.clone(),
        standardized_relative_path: path.clone(),
        full_path: format!("/root/{path}"),
        standardized_full_path: format!("/root/{path}"),
        parent_folder_id: None,
        modification_date: None,
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    /// D-12's counter-equals-traversal differential: the two O(1) maintained discoverable-count
    /// aggregates must agree with a from-scratch traversal after *every* mutation in an
    /// adversarial sequence -- including path-collision upserts (two ids racing for the same
    /// path) and remove-then-re-add, which are exactly where an incremental counter drifts if the
    /// before/after discoverability delta is computed wrong.
    #[test]
    fn discoverable_aggregates_agree_with_traversal_after_every_mutation(
        ops in prop::collection::vec(map_op_strategy(), 1..200)
    ) {
        let mut maps = IdentityMaps::default();
        for op in ops {
            match op {
                MapOp::UpsertFile { id_index, path_index } => maps.upsert_file(file_record(id_index, path_index)),
                MapOp::RemoveFile { id_index } => { maps.remove_file(uuid_for(0xF0, id_index)); }
                MapOp::SetFileManagedOnly { id_index, managed } => maps.set_file_managed_only(uuid_for(0xF0, id_index), managed),
                MapOp::UpsertFolder { id_index, path_index } => maps.upsert_folder(folder_record(id_index, path_index)),
                MapOp::RemoveFolder { id_index } => { maps.remove_folder(uuid_for(0xE0, id_index)); }
                MapOp::SetFolderManagedOnly { id_index, managed } => maps.set_folder_managed_only(uuid_for(0xE0, id_index), managed),
            }
            let (files_by_traversal, folders_by_traversal) = maps.recount_by_traversal();
            prop_assert_eq!(files_by_traversal, maps.discoverable_file_count());
            prop_assert_eq!(folders_by_traversal, maps.discoverable_folder_count());
        }
    }
}
