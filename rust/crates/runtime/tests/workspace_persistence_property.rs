//! ADR-0012 Workspace Persistence & Fault-Isolation Property Test Suite
//!
//! Tests the four core invariants specified in ADR-0012:
//! 1. Single-workspace corruption isolation: Corrupting one workspace's persistence artifacts
//!    quarantines ONLY that workspace, leaving all other workspaces active and writable.
//! 2. Arbitrary byte decode safety: Fuzzing arbitrary random byte payloads into workspace
//!    validation and recovery decoders never panics and respects memory bounds.
//! 3. CAS revision monotonicity: On-disk workspace revisions strictly monotonically advance;
//!    outdated or future revisions fail closed with StateConflict / InvalidRevisionState.
//! 4. Storage paths containment: Traversal attempts (`../`, escaping roots) fail containment.

use std::fs;
use std::path::{Path, PathBuf};
use proptest::prelude::*;

use agentry_runtime::workspace_disk_persistence::atomic_write;
use agentry_runtime::workspace_storage_paths::{
    default_workspace_directory_name, WorkspaceStoragePaths,
};
use agentry_runtime::workspace_context::WorkspaceProjectionHealthKind;
use agentry_runtime::workspace_persistence_journal::{
    execute_workspace_create_direct_v1,
    execute_workspace_delete_direct_v1,
    execute_workspace_mutate_working_direct_v1,
    execute_workspace_save_direct_v1,
    resolve_workspace_pending_save_v1,
    validate_workspace_catalog_v1,
    validate_workspace_deletion_tombstone_v1,
    validate_workspace_saved_revision_record_v1,
    validate_workspace_working_journal_v1,
    PreparedWorkspaceSemanticRecoveryV1,
    WorkspaceRecoveryArtifactEvidenceV1,
    WorkspaceSemanticFullRecoveryV1,
    WorkspaceSemanticRecoveryEvidenceV1,
    WorkspaceWorkingJournalError,
};

/// Helper to generate deterministic canonical UUIDs for test workspaces
fn test_workspace_uuid(index: usize) -> String {
    format!("00000000-0000-0000-0000-{:012x}", index + 1)
}

/// Helper to generate deterministic canonical UUIDs for test operations
fn test_operation_uuid(index: usize, step: usize) -> String {
    format!("11111111-1111-1111-{:04x}-{:012x}", index + 1, step + 1)
}

/// RAII Temporary Directory for Tests
struct TestTempDir(PathBuf);

impl TestTempDir {
    fn new() -> Self {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "agentry-prop-{}-{}-{}",
            std::process::id(),
            id,
            nanos
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestTempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Helper: run semantic full recovery over a storage directory
fn run_full_recovery_from_disk(
    paths: &WorkspaceStoragePaths,
    workspaces: &[(String, String)],
) -> Result<agentry_runtime::workspace_persistence_journal::PreparedWorkspaceCommandAdmissionV1, WorkspaceWorkingJournalError> {
    let catalog_bytes = fs::read(paths.catalog_path())
        .map_err(|e| WorkspaceWorkingJournalError::PersistenceIoError(e.to_string()))?;

    let mut evidences = Vec::new();
    for (ws_id, ws_name) in workspaces {
        let journal_path = paths.journal_path(ws_id);
        let journal_ev = if journal_path.exists() {
            match fs::read(&journal_path) {
                Ok(b) => WorkspaceRecoveryArtifactEvidenceV1::Present(b),
                Err(e) => WorkspaceRecoveryArtifactEvidenceV1::Unavailable(e.to_string()),
            }
        } else {
            WorkspaceRecoveryArtifactEvidenceV1::Absent
        };

        let revision_path = paths.revision_path(ws_id);
        let revision_ev = if revision_path.exists() {
            match fs::read(&revision_path) {
                Ok(b) => WorkspaceRecoveryArtifactEvidenceV1::Present(b),
                Err(e) => WorkspaceRecoveryArtifactEvidenceV1::Unavailable(e.to_string()),
            }
        } else {
            WorkspaceRecoveryArtifactEvidenceV1::Absent
        };

        // Saved document is in the workspace directory under workspace_root
        let default_dir = default_workspace_directory_name(ws_name, ws_id);
        let doc_path = paths.workspace_root.join(&default_dir).join("workspace.json");
        let doc_ev = if doc_path.exists() {
            match fs::read(&doc_path) {
                Ok(b) => WorkspaceRecoveryArtifactEvidenceV1::Present(b),
                Err(e) => WorkspaceRecoveryArtifactEvidenceV1::Unavailable(e.to_string()),
            }
        } else {
            WorkspaceRecoveryArtifactEvidenceV1::Absent
        };

        evidences.push(WorkspaceSemanticRecoveryEvidenceV1 {
            workspace_id: ws_id.clone(),
            journal: journal_ev,
            saved_document: doc_ev,
            saved_revision: revision_ev,
        });
    }

    let recovery = WorkspaceSemanticFullRecoveryV1 {
        catalog_bytes,
        workspaces: evidences,
        deletions: Vec::new(),
    };

    let prepared = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&recovery)?;
    let commit_res = prepared.commit()?;
    commit_res.admission.ok_or(WorkspaceWorkingJournalError::InvalidTransaction)
}

// ---------------------------------------------------------------------------
// Property 1: Single-Workspace Corruption Isolation
// ---------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(15))]

    #[test]
    fn test_single_workspace_corruption_isolation(
        num_workspaces in 2usize..=4,
        corrupted_index in 0usize..4,
        corrupted_bytes in prop::collection::vec(any::<u8>(), 1..64),
    ) {
        let corrupted_index = corrupted_index % num_workspaces;
        let temp_dir = TestTempDir::new();
        let storage_dir = temp_dir.path().to_path_buf();
        let storage_dir_str = storage_dir.to_str().unwrap().to_string();
        let paths = WorkspaceStoragePaths::canonical(storage_dir.clone());

        let mut workspace_list = Vec::new();
        let mut catalog_revision = 0u64;

        // Step 1: Create N workspaces with canonical UUIDs
        for i in 0..num_workspaces {
            let ws_id = test_workspace_uuid(i);
            let ws_name = format!("Workspace {}", i);
            let doc_content = serde_json::json!({
                "id": ws_id,
                "name": ws_name,
                "schemaVersion": 1,
                "repoPaths": [],
            });
            let doc_bytes = serde_json::to_vec(&doc_content).unwrap();

            let res = execute_workspace_create_direct_v1(
                &storage_dir_str,
                &ws_id,
                &ws_name,
                &doc_bytes,
                catalog_revision,
                &test_operation_uuid(i, 0),
                None,
            ).unwrap();

            catalog_revision = res.catalog_revision;
            workspace_list.push((ws_id, ws_name));
        }

        // Verify all exist before corruption
        for (ws_id, _) in &workspace_list {
            assert!(paths.journal_path(ws_id).exists());
        }

        // Step 2: Corrupt exactly one workspace's journal file
        let (corrupted_ws_id, _) = &workspace_list[corrupted_index];
        let journal_file = paths.journal_path(corrupted_ws_id);
        fs::write(&journal_file, &corrupted_bytes).unwrap();

        // Step 3: Run full semantic recovery on the directory
        let admission = run_full_recovery_from_disk(&paths, &workspace_list)
            .expect("recovery should succeed and install admission");

        // Step 4: Verify isolation invariants
        let state = admission.quarantine_state().expect("quarantine state");
        // Global health must remain Writable (not degraded to DegradedReadOnly)
        assert_eq!(state.global_health.kind, WorkspaceProjectionHealthKind::Writable);

        // Corrupted workspace must be quarantined
        assert!(admission.is_workspace_quarantined(corrupted_ws_id).unwrap());
        let quarantined = admission.quarantined_workspaces().unwrap();
        assert!(quarantined.contains(corrupted_ws_id));

        // All OTHER workspaces must NOT be quarantined
        for (idx, (ws_id, _)) in workspace_list.iter().enumerate() {
            if idx != corrupted_index {
                assert!(!admission.is_workspace_quarantined(ws_id).unwrap(),
                    "Workspace {} should NOT be quarantined", ws_id);
                assert!(!quarantined.contains(ws_id),
                    "Workspace {} should NOT appear in quarantined list", ws_id);

                // Healthy workspaces must remain writable via direct execution
                let update_doc = serde_json::json!({
                    "id": ws_id,
                    "name": format!("Updated Workspace {}", idx),
                    "schemaVersion": 1,
                    "repoPaths": [],
                });
                let update_bytes = serde_json::to_vec(&update_doc).unwrap();
                let save_res = execute_workspace_save_direct_v1(
                    &storage_dir_str,
                    ws_id,
                    &update_bytes,
                    1, // expected working revision
                    catalog_revision,
                    &test_operation_uuid(idx, 1),
                    None,
                );
                assert!(save_res.is_ok(), "Direct save on uncorrupted workspace must succeed");
            }
        }

        // Attempting to mutate the corrupted workspace must fail closed
        let fail_doc = serde_json::json!({
            "id": corrupted_ws_id,
            "name": "Should Fail",
            "schemaVersion": 1,
        });
        let fail_bytes = serde_json::to_vec(&fail_doc).unwrap();
        let mutate_res = execute_workspace_mutate_working_direct_v1(
            &storage_dir_str,
            corrupted_ws_id,
            &fail_bytes,
            1,
            &test_operation_uuid(corrupted_index, 99),
            None,
        );
        assert!(mutate_res.is_err(), "Mutating corrupted workspace must fail");
    }
}

// ---------------------------------------------------------------------------
// Property 2: Arbitrary Byte Decode Safety (Fuzzing)
// ---------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(50))]

    #[test]
    fn test_arbitrary_byte_decode_safety(
        raw_bytes in prop::collection::vec(any::<u8>(), 0..2048),
        workspace_id in "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        file_url in "file:///[a-zA-Z0-9_/-]{1,32}",
    ) {
        // Invariant: None of these decoder functions must ever panic on arbitrary inputs.
        let _ = validate_workspace_working_journal_v1(&raw_bytes);
        let _ = validate_workspace_catalog_v1(&raw_bytes);
        let _ = validate_workspace_saved_revision_record_v1(&raw_bytes);
        let _ = validate_workspace_deletion_tombstone_v1(&raw_bytes);
        let _ = resolve_workspace_pending_save_v1(&raw_bytes, &workspace_id, &file_url, None);
    }

    #[test]
    fn test_atomic_write_byte_limits(
        raw_bytes in prop::collection::vec(any::<u8>(), 0..1024),
        max_limit in 10usize..500,
    ) {
        let temp_dir = TestTempDir::new();
        let target_file = temp_dir.path().join("bounded_test.bin");

        let result = atomic_write(&target_file, &raw_bytes, max_limit);
        if raw_bytes.len() > max_limit {
            assert!(result.is_err(), "Must reject input exceeding max_limit");
            assert!(!target_file.exists(), "Target file must not be created on bound violation");
        } else {
            assert!(result.is_ok(), "Must succeed when input within limit");
            assert!(target_file.exists(), "Target file must exist after successful write");
            let read_back = fs::read(&target_file).unwrap();
            assert_eq!(read_back, raw_bytes);
        }
    }
}

// ---------------------------------------------------------------------------
// Property 3: CAS Revision Monotonicity
// ---------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(15))]

    #[test]
    fn test_cas_revision_monotonicity(
        num_saves in 2usize..=5,
        corrupted_step in 1usize..=4,
    ) {
        let temp_dir = TestTempDir::new();
        let storage_dir = temp_dir.path().to_path_buf();
        let storage_dir_str = storage_dir.to_str().unwrap().to_string();
        let ws_id = "00000000-0000-0000-0000-000000000099";
        let ws_name = "CAS Monotonicity Test";

        // Initial create -> revision 1
        let initial_doc = serde_json::json!({
            "id": ws_id,
            "name": ws_name,
            "schemaVersion": 1,
            "repoPaths": [],
        });
        let initial_bytes = serde_json::to_vec(&initial_doc).unwrap();

        let create_res = execute_workspace_create_direct_v1(
            &storage_dir_str,
            ws_id,
            ws_name,
            &initial_bytes,
            0,
            "11111111-1111-1111-0000-000000000000",
            None,
        ).unwrap();

        let mut current_working_rev = 1u64;
        let mut current_catalog_rev = create_res.catalog_revision;

        for step in 1..=num_saves {
            let next_doc = serde_json::json!({
                "id": ws_id,
                "name": ws_name,
                "schemaVersion": 1,
                "repoPaths": [],
                "step": step,
            });
            let next_bytes = serde_json::to_vec(&next_doc).unwrap();

            if step == corrupted_step {
                // Attempt mutate with stale revision (e.g. 0 or current - 1)
                let stale_rev = current_working_rev.saturating_sub(1);
                let stale_mutate = execute_workspace_mutate_working_direct_v1(
                    &storage_dir_str,
                    ws_id,
                    &next_bytes,
                    stale_rev,
                    &format!("11111111-1111-1111-dead-{:012x}", step),
                    None,
                );
                assert!(stale_mutate.is_err(), "Mutate with stale expected revision must fail");

                // Attempt mutate with future revision (current + 10)
                let future_rev = current_working_rev + 10;
                let future_mutate = execute_workspace_mutate_working_direct_v1(
                    &storage_dir_str,
                    ws_id,
                    &next_bytes,
                    future_rev,
                    &format!("11111111-1111-1111-beef-{:012x}", step),
                    None,
                );
                assert!(future_mutate.is_err(), "Mutate with future expected revision must fail");
            }

            // Step A: Valid working mutation advances working revision from current to current + 1
            let mutate_res = execute_workspace_mutate_working_direct_v1(
                &storage_dir_str,
                ws_id,
                &next_bytes,
                current_working_rev,
                &format!("11111111-1111-1111-0001-{:012x}", step),
                None,
            ).unwrap();

            let mutated_rev = mutate_res.after.expect("after mutation revision");
            assert_eq!(mutated_rev.working_revision, current_working_rev + 1, "Working revision must advance by 1");
            assert_eq!(mutated_rev.dirty_revision, Some(current_working_rev + 1), "Dirty revision must be set");
            assert_eq!(mutated_rev.saved_revision, current_working_rev, "Saved revision unchanged before save");

            if step == corrupted_step {
                // Attempt save with stale revision
                let stale_save = execute_workspace_save_direct_v1(
                    &storage_dir_str,
                    ws_id,
                    &next_bytes,
                    current_working_rev, // should be current_working_rev + 1 now
                    current_catalog_rev,
                    &format!("11111111-1111-1111-badf-{:012x}", step),
                    None,
                );
                assert!(stale_save.is_err(), "Save with stale expected revision must fail");
            }

            // Step B: Valid save commits working revision to saved revision
            let save_res = execute_workspace_save_direct_v1(
                &storage_dir_str,
                ws_id,
                &next_bytes,
                current_working_rev + 1,
                current_catalog_rev,
                &format!("11111111-1111-1111-0002-{:012x}", step),
                None,
            ).unwrap();

            let saved_rev = save_res.after.expect("after save revision");
            assert_eq!(saved_rev.working_revision, current_working_rev + 1);
            assert_eq!(saved_rev.saved_revision, current_working_rev + 1);
            assert_eq!(saved_rev.dirty_revision, None, "Dirty revision cleared after save");

            current_working_rev = saved_rev.working_revision;
            current_catalog_rev = save_res.catalog_revision;
        }

        // Finally delete the workspace
        let del_res = execute_workspace_delete_direct_v1(
            &storage_dir_str,
            ws_id,
            current_catalog_rev,
            "11111111-1111-1111-ffff-000000000000",
        );
        assert!(del_res.is_ok(), "Direct delete must succeed after sequential saves");
    }
}

// ---------------------------------------------------------------------------
// Property 4: Storage Paths Containment & Traversal Prevention
// ---------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(30))]

    #[test]
    fn test_storage_paths_containment(
        subpath in "[a-zA-Z0-9_]{1,16}/[a-zA-Z0-9_]{1,16}",
        traversal in "(\\.\\./)+[a-zA-Z0-9_]{1,8}",
    ) {
        let temp_dir = TestTempDir::new();
        let root = temp_dir.path().to_path_buf();
        let paths = WorkspaceStoragePaths::canonical(root.clone());

        // Subpath inside root must be contained
        let inside_path = root.join(&subpath);
        assert!(paths.contains_document_path(&inside_path),
            "Path {:?} inside root {:?} must pass containment", inside_path, root);

        // Path escaping outside root must be rejected
        let outside_path = root.join(&traversal);
        // If canonicalization resolves outside root, containment must return false
        if let Ok(canon) = outside_path.canonicalize() {
            let root_canon = root.canonicalize().unwrap();
            assert_eq!(paths.contains_document_path(&outside_path), canon.starts_with(&root_canon));
        } else {
            // Non-existent escaping paths are rejected
            assert!(!paths.contains_document_path(&outside_path));
        }
    }
}
