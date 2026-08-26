//! P5-5a workspace working-journal compatibility and validation boundary.
//!
//! The physical file and lease remain Swift-owned. This module is deliberately stateless: it
//! validates the complete V1 artifact with bounded input and emits deterministic JSON for bridge
//! compatibility. Embedded document semantics remain a later recovery/degradation policy boundary.

use crate::workspace_context::{
    MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1, WorkspaceProjectionRevisionState,
    canonical_uuid, is_valid_revision_state,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::fmt;

pub const WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1: u16 = 1;
pub const MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1: usize = 128 * 1024 * 1024;
pub const MAXIMUM_WORKSPACE_WORKING_JOURNAL_OPERATION_COUNT_V1: usize = 256;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceWorkingJournalValidationV1 {
    pub workspace_id: String,
    pub journal_version: u16,
    pub content_digest: String,
    pub canonical_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceWorkingJournalError {
    InputTooLarge { actual: usize, maximum: usize },
    OutputTooLarge { actual: usize, maximum: usize },
    Malformed,
    FutureSchema(u16),
    InvalidIdentity,
    InvalidFileUrl,
    InvalidRevisionState,
    InvalidDigest,
    InvalidWorkingDocument,
    InvalidContextTable,
    InvalidOperationLedger,
    InvalidPendingSave,
    InvalidTimestamp,
}

impl fmt::Display for WorkspaceWorkingJournalError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InputTooLarge { actual, maximum } => {
                write!(
                    formatter,
                    "workspace journal has {actual} bytes; maximum is {maximum}"
                )
            }
            Self::OutputTooLarge { actual, maximum } => write!(
                formatter,
                "canonical workspace journal has {actual} bytes; maximum is {maximum}"
            ),
            Self::Malformed => formatter.write_str("workspace journal is malformed"),
            Self::FutureSchema(version) => {
                write!(
                    formatter,
                    "workspace journal schema {version} is unsupported"
                )
            }
            Self::InvalidIdentity => formatter.write_str("workspace journal identity is invalid"),
            Self::InvalidFileUrl => formatter.write_str("workspace journal file URL is invalid"),
            Self::InvalidRevisionState => {
                formatter.write_str("workspace journal revision state is invalid")
            }
            Self::InvalidDigest => formatter.write_str("workspace journal digest is invalid"),
            Self::InvalidWorkingDocument => {
                formatter.write_str("workspace journal working document is invalid")
            }
            Self::InvalidContextTable => {
                formatter.write_str("workspace journal context table is invalid")
            }
            Self::InvalidOperationLedger => {
                formatter.write_str("workspace journal operation ledger is invalid")
            }
            Self::InvalidPendingSave => {
                formatter.write_str("workspace journal pending save is invalid")
            }
            Self::InvalidTimestamp => formatter.write_str("workspace journal timestamp is invalid"),
        }
    }
}

impl std::error::Error for WorkspaceWorkingJournalError {}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceWorkingJournalV1 {
    version: u16,
    #[serde(rename = "workspaceID")]
    workspace_id: String,
    #[serde(rename = "fileURL")]
    file_url: String,
    revisions: WorkspaceProjectionRevisionState,
    saved_digest: String,
    working_document: Option<String>,
    context_revisions: Value,
    context_digests: Value,
    context_tombstones: Value,
    operations: Vec<WorkspaceRecordedOperationV1>,
    pending_save: Option<WorkspacePendingSaveV1>,
    updated_at: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspacePendingSaveV1 {
    #[serde(rename = "operationID")]
    operation_id: String,
    document_digest: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceRecordedOperationV1 {
    #[serde(rename = "operationID")]
    operation_id: String,
    fingerprint: String,
    recorded_at: f64,
    disposition: String,
    before: Option<WorkspaceProjectionRevisionState>,
    after: Option<WorkspaceProjectionRevisionState>,
    catalog_revision: u64,
    resulting_digest: Option<String>,
    error_code: Option<String>,
    diagnostic: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceWorkingJournalTransitionPlanV1 {
    pub primary: WorkspaceWorkingJournalValidationV1,
    pub committed: Option<WorkspaceWorkingJournalValidationV1>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum WorkspaceWorkingJournalTransitionRequestV1 {
    Seed {
        #[serde(rename = "workspaceID")]
        workspace_id: String,
        #[serde(rename = "fileURL")]
        file_url: String,
        revisions: WorkspaceProjectionRevisionState,
        saved_digest: String,
        context_digests: Value,
        updated_at: Value,
    },
    RecoverPending {
        #[serde(rename = "expectedWorkspaceID")]
        expected_workspace_id: String,
    },
    Create {
        #[serde(rename = "workspaceID")]
        workspace_id: String,
        #[serde(rename = "fileURL")]
        file_url: String,
        context_revisions: Value,
        context_digests: Value,
        operation: WorkspaceRecordedOperationV1,
        #[serde(rename = "operationID")]
        operation_id: String,
        updated_at: Value,
    },
    Unchanged {
        expected_working_revision: u64,
        operation: WorkspaceRecordedOperationV1,
        updated_at: Value,
    },
    Working {
        expected_working_revision: u64,
        new_revisions: WorkspaceProjectionRevisionState,
        context_revisions: Value,
        context_digests: Value,
        context_tombstones: Value,
        operations: Vec<WorkspaceRecordedOperationV1>,
        updated_at: Value,
    },
    Save {
        expected_working_revision: u64,
        #[serde(rename = "operationID")]
        operation_id: String,
        context_revisions: Value,
        context_digests: Value,
        context_tombstones: Value,
        operations: Vec<WorkspaceRecordedOperationV1>,
        updated_at: Value,
    },
    ExternalReload {
        expected_working_revision: u64,
        new_revision: u64,
        context_revisions: Value,
        context_digests: Value,
        context_tombstones: Value,
        operations: Vec<WorkspaceRecordedOperationV1>,
        updated_at: Value,
    },
    ConflictRebase {
        expected_revisions: WorkspaceProjectionRevisionState,
        new_revisions: WorkspaceProjectionRevisionState,
        external_saved_digest: String,
        context_revisions: Value,
        context_digests: Value,
        context_tombstones: Value,
        operations: Vec<WorkspaceRecordedOperationV1>,
        updated_at: Value,
    },
}

pub fn plan_workspace_working_journal_transition_v1(
    current_journal_bytes: Option<&[u8]>,
    transition_bytes: &[u8],
    document_bytes: Option<&[u8]>,
) -> Result<WorkspaceWorkingJournalTransitionPlanV1, WorkspaceWorkingJournalError> {
    if transition_bytes.len() > MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: transition_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1,
        });
    }
    if let Some(document_bytes) = document_bytes
        && document_bytes.len() > MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1
    {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: document_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
        });
    }
    let request: WorkspaceWorkingJournalTransitionRequestV1 =
        serde_json::from_slice(transition_bytes)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let current = match current_journal_bytes {
        Some(bytes) => Some(parse_validated_journal(bytes)?),
        None => None,
    };
    let document_digest = document_bytes.map(|bytes| format!("{:x}", Sha256::digest(bytes)));
    let working_document = document_bytes.map(base64_encode);

    let (primary, committed) = match request {
        WorkspaceWorkingJournalTransitionRequestV1::Seed {
            workspace_id,
            file_url,
            revisions,
            saved_digest,
            context_digests,
            updated_at,
        } => {
            require_no_current(current.as_ref())?;
            let context_revisions = context_revisions_from_digests(&context_digests, revisions)?;
            (
                WorkspaceWorkingJournalV1 {
                    version: WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
                    workspace_id,
                    file_url,
                    revisions,
                    saved_digest,
                    working_document: None,
                    context_revisions,
                    context_digests,
                    context_tombstones: Value::Array(Vec::new()),
                    operations: Vec::new(),
                    pending_save: None,
                    updated_at,
                },
                None,
            )
        }
        WorkspaceWorkingJournalTransitionRequestV1::RecoverPending {
            expected_workspace_id,
        } => {
            let current = require_current(current)?;
            let pending = current
                .pending_save
                .as_ref()
                .ok_or(WorkspaceWorkingJournalError::InvalidPendingSave)?;
            let expected_workspace_id = canonical_uuid(&expected_workspace_id)
                .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
            if current.workspace_id != expected_workspace_id {
                return Err(WorkspaceWorkingJournalError::InvalidIdentity);
            }
            let revisions = clean_revision_state(current.revisions);
            (
                WorkspaceWorkingJournalV1 {
                    revisions,
                    saved_digest: pending.document_digest.clone(),
                    working_document: None,
                    context_revisions: clean_context_revisions(&current.context_revisions)?,
                    pending_save: None,
                    ..current
                },
                None,
            )
        }
        WorkspaceWorkingJournalTransitionRequestV1::Create {
            workspace_id,
            file_url,
            context_revisions,
            context_digests,
            operation,
            operation_id,
            updated_at,
        } => {
            require_no_current(current.as_ref())?;
            let document_digest =
                document_digest.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let working_document =
                working_document.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let pending_revisions = WorkspaceProjectionRevisionState {
                working_revision: 1,
                saved_revision: 0,
                dirty_revision: Some(1),
            };
            let pending = WorkspaceWorkingJournalV1 {
                version: WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
                workspace_id,
                file_url,
                revisions: pending_revisions,
                saved_digest: format!("{:x}", Sha256::digest([])),
                working_document: Some(working_document),
                context_revisions: context_revisions.clone(),
                context_digests: context_digests.clone(),
                context_tombstones: Value::Array(Vec::new()),
                operations: vec![operation.clone()],
                pending_save: Some(WorkspacePendingSaveV1 {
                    operation_id,
                    document_digest: document_digest.clone(),
                }),
                updated_at: updated_at.clone(),
            };
            let committed = WorkspaceWorkingJournalV1 {
                revisions: clean_revision_state(pending_revisions),
                saved_digest: document_digest,
                working_document: None,
                context_revisions: clean_context_revisions(&context_revisions)?,
                pending_save: None,
                ..pending.clone()
            };
            (pending, Some(committed))
        }
        WorkspaceWorkingJournalTransitionRequestV1::Unchanged {
            expected_working_revision,
            operation,
            updated_at,
        } => {
            let mut current = require_current(current)?;
            require_working_revision(&current, expected_working_revision)?;
            current.operations.push(operation);
            current.operations = trimmed_operations(current.operations, &updated_at)?;
            current.updated_at = updated_at;
            (current, None)
        }
        WorkspaceWorkingJournalTransitionRequestV1::Working {
            expected_working_revision,
            new_revisions,
            context_revisions,
            context_digests,
            context_tombstones,
            operations,
            updated_at,
        } => {
            let current = require_current(current)?;
            require_working_revision(&current, expected_working_revision)?;
            let working_document = if new_revisions.dirty_revision.is_some() {
                Some(working_document.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?)
            } else {
                None
            };
            (
                WorkspaceWorkingJournalV1 {
                    version: current.version,
                    workspace_id: current.workspace_id,
                    file_url: current.file_url,
                    revisions: new_revisions,
                    saved_digest: current.saved_digest,
                    working_document,
                    context_revisions,
                    context_digests,
                    context_tombstones,
                    operations: trimmed_operations(operations, &updated_at)?,
                    pending_save: None,
                    updated_at,
                },
                None,
            )
        }
        WorkspaceWorkingJournalTransitionRequestV1::Save {
            expected_working_revision,
            operation_id,
            context_revisions,
            context_digests,
            context_tombstones,
            operations,
            updated_at,
        } => {
            let current = require_current(current)?;
            require_working_revision(&current, expected_working_revision)?;
            let document_digest =
                document_digest.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let working_document = if current.revisions.dirty_revision.is_some() {
                Some(working_document.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?)
            } else {
                None
            };
            let operations = trimmed_operations(operations, &updated_at)?;
            let pending = WorkspaceWorkingJournalV1 {
                version: current.version,
                workspace_id: current.workspace_id,
                file_url: current.file_url,
                revisions: current.revisions,
                saved_digest: current.saved_digest,
                working_document,
                context_revisions: context_revisions.clone(),
                context_digests: context_digests.clone(),
                context_tombstones: context_tombstones.clone(),
                operations: operations.clone(),
                pending_save: Some(WorkspacePendingSaveV1 {
                    operation_id,
                    document_digest: document_digest.clone(),
                }),
                updated_at: updated_at.clone(),
            };
            let committed = WorkspaceWorkingJournalV1 {
                revisions: clean_revision_state(current.revisions),
                saved_digest: document_digest,
                working_document: None,
                context_revisions: clean_context_revisions(&context_revisions)?,
                pending_save: None,
                ..pending.clone()
            };
            (pending, Some(committed))
        }
        WorkspaceWorkingJournalTransitionRequestV1::ExternalReload {
            expected_working_revision,
            new_revision,
            context_revisions,
            context_digests,
            context_tombstones,
            operations,
            updated_at,
        } => {
            let current = require_current(current)?;
            require_working_revision(&current, expected_working_revision)?;
            let document_digest =
                document_digest.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let revisions = WorkspaceProjectionRevisionState {
                working_revision: new_revision,
                saved_revision: new_revision,
                dirty_revision: None,
            };
            (
                WorkspaceWorkingJournalV1 {
                    version: current.version,
                    workspace_id: current.workspace_id,
                    file_url: current.file_url,
                    revisions,
                    saved_digest: document_digest,
                    working_document: None,
                    context_revisions: clean_context_revisions(&context_revisions)?,
                    context_digests,
                    context_tombstones,
                    operations: trimmed_operations(operations, &updated_at)?,
                    pending_save: None,
                    updated_at,
                },
                None,
            )
        }
        WorkspaceWorkingJournalTransitionRequestV1::ConflictRebase {
            expected_revisions,
            new_revisions,
            external_saved_digest,
            context_revisions,
            context_digests,
            context_tombstones,
            operations,
            updated_at,
        } => {
            let current = require_current(current)?;
            if current.revisions != expected_revisions {
                return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
            }
            let keeps_revision = new_revisions == current.revisions;
            let advances_revision = new_revisions.working_revision
                == current.revisions.working_revision.wrapping_add(1)
                && new_revisions.saved_revision == current.revisions.saved_revision
                && new_revisions.dirty_revision == Some(new_revisions.working_revision);
            if !keeps_revision && !advances_revision {
                return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
            }
            let working_document = if new_revisions.dirty_revision.is_some() {
                Some(working_document.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?)
            } else {
                None
            };
            (
                WorkspaceWorkingJournalV1 {
                    version: current.version,
                    workspace_id: current.workspace_id,
                    file_url: current.file_url,
                    revisions: new_revisions,
                    saved_digest: external_saved_digest,
                    working_document,
                    context_revisions,
                    context_digests,
                    context_tombstones,
                    operations: trimmed_operations(operations, &updated_at)?,
                    pending_save: None,
                    updated_at,
                },
                None,
            )
        }
    };

    Ok(WorkspaceWorkingJournalTransitionPlanV1 {
        primary: canonicalize_constructed_journal(primary)?,
        committed: committed
            .map(canonicalize_constructed_journal)
            .transpose()?,
    })
}

fn require_current(
    current: Option<WorkspaceWorkingJournalV1>,
) -> Result<WorkspaceWorkingJournalV1, WorkspaceWorkingJournalError> {
    current.ok_or(WorkspaceWorkingJournalError::Malformed)
}

fn require_no_current(
    current: Option<&WorkspaceWorkingJournalV1>,
) -> Result<(), WorkspaceWorkingJournalError> {
    if current.is_some() {
        Err(WorkspaceWorkingJournalError::Malformed)
    } else {
        Ok(())
    }
}

fn require_working_revision(
    current: &WorkspaceWorkingJournalV1,
    expected: u64,
) -> Result<(), WorkspaceWorkingJournalError> {
    if current.revisions.working_revision == expected {
        Ok(())
    } else {
        Err(WorkspaceWorkingJournalError::InvalidRevisionState)
    }
}

fn parse_validated_journal(
    bytes: &[u8],
) -> Result<WorkspaceWorkingJournalV1, WorkspaceWorkingJournalError> {
    let validated = validate_workspace_working_journal_v1(bytes)?;
    serde_json::from_slice(&validated.canonical_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)
}

fn canonicalize_constructed_journal(
    journal: WorkspaceWorkingJournalV1,
) -> Result<WorkspaceWorkingJournalValidationV1, WorkspaceWorkingJournalError> {
    let bytes =
        serde_json::to_vec(&journal).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    validate_workspace_working_journal_v1(&bytes)
}

fn clean_revision_state(
    revisions: WorkspaceProjectionRevisionState,
) -> WorkspaceProjectionRevisionState {
    WorkspaceProjectionRevisionState {
        working_revision: revisions.working_revision,
        saved_revision: revisions.working_revision,
        dirty_revision: None,
    }
}

fn clean_context_revisions(value: &Value) -> Result<Value, WorkspaceWorkingJournalError> {
    let (_, canonical) = normalize_uuid_dictionary(value, |value| {
        serde_json::from_value::<WorkspaceProjectionRevisionState>(value.clone())
            .is_ok_and(is_valid_revision_state)
    })?;
    let Value::Array(items) = canonical else {
        return Err(WorkspaceWorkingJournalError::InvalidContextTable);
    };
    let mut output = Vec::with_capacity(items.len());
    for pair in items.chunks_exact(2) {
        let revisions = serde_json::from_value::<WorkspaceProjectionRevisionState>(pair[1].clone())
            .map_err(|_| WorkspaceWorkingJournalError::InvalidContextTable)?;
        output.push(pair[0].clone());
        output.push(
            serde_json::to_value(clean_revision_state(revisions))
                .map_err(|_| WorkspaceWorkingJournalError::InvalidContextTable)?,
        );
    }
    Ok(Value::Array(output))
}

fn context_revisions_from_digests(
    context_digests: &Value,
    revisions: WorkspaceProjectionRevisionState,
) -> Result<Value, WorkspaceWorkingJournalError> {
    let (_, canonical) = normalize_uuid_dictionary(context_digests, |value| {
        value.as_str().is_some_and(is_sha256_digest)
    })?;
    let Value::Array(items) = canonical else {
        return Err(WorkspaceWorkingJournalError::InvalidContextTable);
    };
    let encoded = serde_json::to_value(revisions)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidContextTable)?;
    let mut output = Vec::with_capacity(items.len());
    for pair in items.chunks_exact(2) {
        output.push(pair[0].clone());
        output.push(encoded.clone());
    }
    Ok(Value::Array(output))
}

fn trimmed_operations(
    operations: Vec<WorkspaceRecordedOperationV1>,
    updated_at: &Value,
) -> Result<Vec<WorkspaceRecordedOperationV1>, WorkspaceWorkingJournalError> {
    let now = updated_at
        .as_f64()
        .filter(|value| value.is_finite())
        .ok_or(WorkspaceWorkingJournalError::InvalidTimestamp)?;
    let cutoff = now - 7.0 * 24.0 * 60.0 * 60.0;
    let mut retained: Vec<_> = operations
        .into_iter()
        .filter(|operation| operation.recorded_at >= cutoff)
        .collect();
    if retained.len() > MAXIMUM_WORKSPACE_WORKING_JOURNAL_OPERATION_COUNT_V1 {
        retained.drain(..retained.len() - MAXIMUM_WORKSPACE_WORKING_JOURNAL_OPERATION_COUNT_V1);
    }
    Ok(retained)
}

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let a = chunk[0];
        let b = *chunk.get(1).unwrap_or(&0);
        let c = *chunk.get(2).unwrap_or(&0);
        output.push(TABLE[(a >> 2) as usize] as char);
        output.push(TABLE[(((a & 0x03) << 4) | (b >> 4)) as usize] as char);
        output.push(if chunk.len() > 1 {
            TABLE[(((b & 0x0f) << 2) | (c >> 6)) as usize] as char
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            TABLE[(c & 0x3f) as usize] as char
        } else {
            '='
        });
    }
    output
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspacePersistenceMetadataValidationV1 {
    pub workspace_id: String,
    pub operation_id: String,
    pub schema_version: u16,
    pub content_digest: String,
    pub canonical_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceSavedRevisionPlanRequestV1 {
    #[serde(rename = "workspaceID")]
    workspace_id: String,
    saved_revision: u64,
    document_digest: String,
    #[serde(rename = "operationID")]
    operation_id: String,
    updated_at: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceSavedRevisionRecordV1 {
    version: u16,
    #[serde(rename = "workspaceID")]
    workspace_id: String,
    saved_revision: u64,
    document_digest: String,
    #[serde(rename = "operationID")]
    operation_id: String,
    updated_at: Value,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceDeletionTombstonePlanRequestV1 {
    #[serde(rename = "workspaceID")]
    workspace_id: String,
    #[serde(rename = "fileURL")]
    file_url: String,
    operation: WorkspaceRecordedOperationV1,
    deleted_at: Value,
    #[serde(default)]
    cleanup_warnings: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceDeletionTombstoneV1 {
    version: u16,
    #[serde(rename = "workspaceID")]
    workspace_id: String,
    #[serde(rename = "fileURL")]
    file_url: String,
    operation: WorkspaceRecordedOperationV1,
    deleted_at: Value,
}

pub fn plan_workspace_saved_revision_record_v1(
    request_bytes: &[u8],
) -> Result<WorkspacePersistenceMetadataValidationV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(request_bytes)?;
    let request: WorkspaceSavedRevisionPlanRequestV1 = serde_json::from_slice(request_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    canonicalize_saved_revision_record(WorkspaceSavedRevisionRecordV1 {
        version: WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
        workspace_id: request.workspace_id,
        saved_revision: request.saved_revision,
        document_digest: request.document_digest,
        operation_id: request.operation_id,
        updated_at: request.updated_at,
    })
}

pub fn validate_workspace_saved_revision_record_v1(
    bytes: &[u8],
) -> Result<WorkspacePersistenceMetadataValidationV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(bytes)?;
    let record: WorkspaceSavedRevisionRecordV1 =
        serde_json::from_slice(bytes).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    canonicalize_saved_revision_record(record)
}

pub fn plan_workspace_deletion_tombstone_v1(
    request_bytes: &[u8],
) -> Result<WorkspacePersistenceMetadataValidationV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(request_bytes)?;
    let mut request: WorkspaceDeletionTombstonePlanRequestV1 =
        serde_json::from_slice(request_bytes)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if !request.cleanup_warnings.is_empty() {
        request.operation.diagnostic = Some(format!(
            "artifact_cleanup_incomplete: {}",
            request.cleanup_warnings.join("; ")
        ));
    }
    canonicalize_deletion_tombstone(WorkspaceDeletionTombstoneV1 {
        version: WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
        workspace_id: request.workspace_id,
        file_url: request.file_url,
        operation: request.operation,
        deleted_at: request.deleted_at,
    })
}

fn canonicalize_saved_revision_record(
    mut record: WorkspaceSavedRevisionRecordV1,
) -> Result<WorkspacePersistenceMetadataValidationV1, WorkspaceWorkingJournalError> {
    validate_metadata_schema(record.version)?;
    record.workspace_id = canonical_uuid(&record.workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    record.operation_id = canonical_uuid(&record.operation_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidOperationLedger)?;
    if !is_sha256_digest(&record.document_digest) {
        return Err(WorkspaceWorkingJournalError::InvalidDigest);
    }
    if !valid_foundation_date(&record.updated_at) {
        return Err(WorkspaceWorkingJournalError::InvalidTimestamp);
    }
    metadata_validation(
        record.workspace_id.clone(),
        record.operation_id.clone(),
        record.version,
        &record,
    )
}

fn canonicalize_deletion_tombstone(
    mut tombstone: WorkspaceDeletionTombstoneV1,
) -> Result<WorkspacePersistenceMetadataValidationV1, WorkspaceWorkingJournalError> {
    validate_metadata_schema(tombstone.version)?;
    tombstone.workspace_id = canonical_uuid(&tombstone.workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    if !valid_file_url(&tombstone.file_url) {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    if !valid_foundation_date(&tombstone.deleted_at) {
        return Err(WorkspaceWorkingJournalError::InvalidTimestamp);
    }
    let operation_id = validate_and_canonicalize_recorded_operation(&mut tombstone.operation)?;
    metadata_validation(
        tombstone.workspace_id.clone(),
        operation_id,
        tombstone.version,
        &tombstone,
    )
}

fn require_metadata_input_bound(bytes: &[u8]) -> Result<(), WorkspaceWorkingJournalError> {
    if bytes.len() > MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: bytes.len(),
            maximum: MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1,
        });
    }
    Ok(())
}

fn validate_metadata_schema(version: u16) -> Result<(), WorkspaceWorkingJournalError> {
    if version > WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1 {
        return Err(WorkspaceWorkingJournalError::FutureSchema(version));
    }
    if version != WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1 {
        return Err(WorkspaceWorkingJournalError::Malformed);
    }
    Ok(())
}

fn metadata_validation(
    workspace_id: String,
    operation_id: String,
    schema_version: u16,
    value: &impl Serialize,
) -> Result<WorkspacePersistenceMetadataValidationV1, WorkspaceWorkingJournalError> {
    let canonical_bytes =
        serde_json::to_vec(value).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if canonical_bytes.len() > MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::OutputTooLarge {
            actual: canonical_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1,
        });
    }
    let content_digest = format!("{:x}", Sha256::digest(&canonical_bytes));
    Ok(WorkspacePersistenceMetadataValidationV1 {
        workspace_id,
        operation_id,
        schema_version,
        content_digest,
        canonical_bytes,
    })
}

fn validate_and_canonicalize_recorded_operation(
    operation: &mut WorkspaceRecordedOperationV1,
) -> Result<String, WorkspaceWorkingJournalError> {
    let operation_id = canonical_uuid(&operation.operation_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidOperationLedger)?;
    if !is_sha256_digest(&operation.fingerprint)
        || !operation.recorded_at.is_finite()
        || !valid_disposition(&operation.disposition)
        || operation
            .before
            .is_some_and(|state| !is_valid_revision_state(state))
        || operation
            .after
            .is_some_and(|state| !is_valid_revision_state(state))
        || operation
            .resulting_digest
            .as_deref()
            .is_some_and(|digest| !is_sha256_digest(digest))
        || operation
            .error_code
            .as_deref()
            .is_some_and(|code| !valid_error_code(code))
    {
        return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
    }
    operation.operation_id = operation_id.clone();
    Ok(operation_id)
}

pub fn validate_workspace_working_journal_v1(
    bytes: &[u8],
) -> Result<WorkspaceWorkingJournalValidationV1, WorkspaceWorkingJournalError> {
    if bytes.len() > MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: bytes.len(),
            maximum: MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1,
        });
    }
    let mut journal: WorkspaceWorkingJournalV1 =
        serde_json::from_slice(bytes).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if journal.version > WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1 {
        return Err(WorkspaceWorkingJournalError::FutureSchema(journal.version));
    }
    if journal.version != WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1 {
        return Err(WorkspaceWorkingJournalError::Malformed);
    }
    let workspace_id = canonical_uuid(&journal.workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    if !valid_file_url(&journal.file_url) {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    if !is_valid_revision_state(journal.revisions) {
        return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
    }
    if !is_sha256_digest(&journal.saved_digest) {
        return Err(WorkspaceWorkingJournalError::InvalidDigest);
    }

    let (context_revision_ids, canonical_context_revisions) =
        normalize_uuid_dictionary(&journal.context_revisions, |value| {
            serde_json::from_value::<WorkspaceProjectionRevisionState>(value.clone())
                .is_ok_and(is_valid_revision_state)
        })?;
    let (context_digest_ids, canonical_context_digests) =
        normalize_uuid_dictionary(&journal.context_digests, |value| {
            value.as_str().is_some_and(is_sha256_digest)
        })?;
    let (context_tombstone_ids, canonical_context_tombstones) =
        normalize_uuid_dictionary(&journal.context_tombstones, |value| {
            value.as_u64().is_some()
        })?;
    if context_revision_ids != context_digest_ids
        || !context_tombstone_ids.is_disjoint(&context_revision_ids)
    {
        return Err(WorkspaceWorkingJournalError::InvalidContextTable);
    }

    let mut operation_ids = BTreeSet::new();
    if journal.operations.len() > MAXIMUM_WORKSPACE_WORKING_JOURNAL_OPERATION_COUNT_V1 {
        return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
    }
    for operation in &mut journal.operations {
        let operation_id = validate_and_canonicalize_recorded_operation(operation)?;
        if !operation_ids.insert(operation_id) {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }
    }

    if !valid_foundation_date(&journal.updated_at) {
        return Err(WorkspaceWorkingJournalError::InvalidTimestamp);
    }
    if let Some(pending) = &journal.pending_save {
        if canonical_uuid(&pending.operation_id).is_none()
            || !is_sha256_digest(&pending.document_digest)
        {
            return Err(WorkspaceWorkingJournalError::InvalidPendingSave);
        }
    }

    if let Some(encoded) = &journal.working_document {
        decode_base64(encoded).ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
        let expects_dirty =
            journal.revisions.dirty_revision == Some(journal.revisions.working_revision);
        if !expects_dirty {
            return Err(WorkspaceWorkingJournalError::InvalidWorkingDocument);
        }
    } else if journal.revisions.dirty_revision.is_some() {
        return Err(WorkspaceWorkingJournalError::InvalidWorkingDocument);
    }

    journal.workspace_id = workspace_id.clone();
    journal.context_revisions = canonical_context_revisions;
    journal.context_digests = canonical_context_digests;
    journal.context_tombstones = canonical_context_tombstones;
    if let Some(pending) = &mut journal.pending_save {
        pending.operation_id = canonical_uuid(&pending.operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidPendingSave)?;
    }
    let canonical_bytes =
        serde_json::to_vec(&journal).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if canonical_bytes.len() > MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::OutputTooLarge {
            actual: canonical_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1,
        });
    }
    let content_digest = format!("{:x}", Sha256::digest(&canonical_bytes));
    Ok(WorkspaceWorkingJournalValidationV1 {
        workspace_id,
        journal_version: journal.version,
        content_digest,
        canonical_bytes,
    })
}

fn valid_file_url(value: &str) -> bool {
    value.starts_with("file://") && !value.as_bytes().contains(&0)
}

fn is_sha256_digest(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_foundation_date(value: &Value) -> bool {
    value.as_f64().is_some_and(f64::is_finite)
}

fn normalize_uuid_dictionary(
    value: &Value,
    validate_value: impl Fn(&Value) -> bool,
) -> Result<(BTreeSet<String>, Value), WorkspaceWorkingJournalError> {
    let mut entries = Vec::new();
    let mut identities = BTreeSet::new();
    match value {
        Value::Object(object) => {
            for (key, value) in object {
                let identity =
                    canonical_uuid(key).ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?;
                if !identities.insert(identity.clone()) || !validate_value(value) {
                    return Err(WorkspaceWorkingJournalError::InvalidContextTable);
                }
                entries.push((identity, value.clone()));
            }
        }
        Value::Array(items) if items.len() % 2 == 0 => {
            for pair in items.chunks_exact(2) {
                let identity = pair[0]
                    .as_str()
                    .and_then(canonical_uuid)
                    .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?;
                if !identities.insert(identity.clone()) || !validate_value(&pair[1]) {
                    return Err(WorkspaceWorkingJournalError::InvalidContextTable);
                }
                entries.push((identity, pair[1].clone()));
            }
        }
        _ => return Err(WorkspaceWorkingJournalError::InvalidContextTable),
    }
    entries.sort_by(|left, right| left.0.cmp(&right.0));
    let mut canonical = Vec::with_capacity(entries.len() * 2);
    for (identity, value) in entries {
        canonical.push(Value::String(identity));
        canonical.push(value);
    }
    Ok((identities, Value::Array(canonical)))
}

fn valid_disposition(value: &str) -> bool {
    matches!(
        value,
        "applied" | "unchanged" | "conflict" | "readOnly" | "invalid" | "failed" | "deduplicated"
    )
}

fn valid_error_code(value: &str) -> bool {
    matches!(
        value,
        "state_conflict"
            | "runtime_read_only_degraded"
            | "workspace_external_conflict"
            | "workspace_read_only_degraded"
            | "protected_agent_identity_conflict"
            | "operation_id_collision"
            | "workspace_unavailable"
            | "invalid_document"
            | "persistence_failure"
            | "lock_timed_out"
            | "cancelled"
    )
}

fn decode_base64(value: &str) -> Option<Vec<u8>> {
    if value.len() % 4 != 0 {
        return None;
    }
    let mut output = Vec::with_capacity(value.len() / 4 * 3);
    for (chunk_index, chunk) in value.as_bytes().chunks_exact(4).enumerate() {
        let is_last = chunk_index + 1 == value.len() / 4;
        let a = base64_value(chunk[0])?;
        let b = base64_value(chunk[1])?;
        let c = if chunk[2] == b'=' {
            0
        } else {
            base64_value(chunk[2])?
        };
        let d = if chunk[3] == b'=' {
            0
        } else {
            base64_value(chunk[3])?
        };
        if chunk[2] == b'=' && (!is_last || chunk[3] != b'=') || chunk[3] == b'=' && !is_last {
            return None;
        }
        output.push((a << 2) | (b >> 4));
        if chunk[2] != b'=' {
            output.push((b << 4) | (c >> 2));
        }
        if chunk[3] != b'=' {
            output.push((c << 6) | d);
        }
    }
    Some(output)
}

fn base64_value(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORKSPACE_ID: &str = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const CONTEXT_ID: &str = "11111111-2222-3333-4444-555555555555";
    const OPERATION_ID: &str = "66666666-7777-8888-9999-aaaaaaaaaaaa";

    fn document(prompt: &str) -> Vec<u8> {
        format!(
            r#"{{"id":"{WORKSPACE_ID}","schemaVersion":1,"name":"Workspace","composeTabs":[{{"id":"{CONTEXT_ID}","name":"Context","prompt":"{prompt}","selectedPaths":[]}}]}}"#
        )
        .into_bytes()
    }

    fn base64_encode(bytes: &[u8]) -> String {
        const TABLE: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
        for chunk in bytes.chunks(3) {
            let a = chunk[0];
            let b = *chunk.get(1).unwrap_or(&0);
            let c = *chunk.get(2).unwrap_or(&0);
            output.push(TABLE[(a >> 2) as usize] as char);
            output.push(TABLE[(((a & 0x03) << 4) | (b >> 4)) as usize] as char);
            output.push(if chunk.len() > 1 {
                TABLE[(((b & 0x0f) << 2) | (c >> 6)) as usize] as char
            } else {
                '='
            });
            output.push(if chunk.len() > 2 {
                TABLE[(c & 0x3f) as usize] as char
            } else {
                '='
            });
        }
        output
    }

    fn journal_bytes(working_document: Option<&[u8]>) -> Vec<u8> {
        let saved_digest = format!("{:x}", Sha256::digest(document("saved")));
        let working = working_document.map(base64_encode);
        let revisions = if working.is_some() {
            serde_json::json!({"workingRevision": 1, "savedRevision": 0, "dirtyRevision": 1})
        } else {
            serde_json::json!({"workingRevision": 0, "savedRevision": 0})
        };
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "workspaceID": WORKSPACE_ID,
            "fileURL": "file:///tmp/Workspace.json",
            "revisions": revisions,
            "savedDigest": saved_digest,
            "workingDocument": working,
            "contextRevisions": [CONTEXT_ID, revisions],
            "contextDigests": [CONTEXT_ID, format!("{:x}", Sha256::digest(b"context"))],
            "contextTombstones": [],
            "operations": [{
                "operationID": OPERATION_ID,
                "fingerprint": format!("{:x}", Sha256::digest(b"operation")),
                "recordedAt": 1.5,
                "disposition": "applied",
                "catalogRevision": 1
            }],
            "updatedAt": 2.5
        }))
        .expect("journal")
    }

    fn revision(working: u64, saved: u64, dirty: Option<u64>) -> Value {
        let mut value = serde_json::json!({
            "workingRevision": working,
            "savedRevision": saved
        });
        if let Some(dirty) = dirty {
            value["dirtyRevision"] = Value::from(dirty);
        }
        value
    }

    fn operation(operation_id: &str, recorded_at: f64, catalog_revision: u64) -> Value {
        serde_json::json!({
            "operationID": operation_id,
            "fingerprint": format!("{:x}", Sha256::digest(operation_id.as_bytes())),
            "recordedAt": recorded_at,
            "disposition": "applied",
            "catalogRevision": catalog_revision
        })
    }

    fn transition(
        request: Value,
        current: Option<&[u8]>,
        document: Option<&[u8]>,
    ) -> WorkspaceWorkingJournalTransitionPlanV1 {
        plan_workspace_working_journal_transition_v1(
            current,
            &serde_json::to_vec(&request).expect("transition bytes"),
            document,
        )
        .expect("transition")
    }

    fn decoded(validation: &WorkspaceWorkingJournalValidationV1) -> WorkspaceWorkingJournalV1 {
        serde_json::from_slice(&validation.canonical_bytes).expect("canonical journal")
    }

    #[test]
    fn plans_all_working_journal_transition_kinds_with_rust_owned_candidates() {
        let saved = document("saved");
        let working = document("working");
        let reloaded = document("reloaded");
        let rebased = document("rebased");
        let saved_digest = format!("{:x}", Sha256::digest(&saved));
        let context_digest = format!("{:x}", Sha256::digest(b"context"));
        let file_url = "file:///tmp/Workspace.json";
        let second_operation_id = "77777777-8888-9999-aaaa-bbbbbbbbbbbb";
        let third_operation_id = "88888888-9999-aaaa-bbbb-cccccccccccc";

        let seed = transition(
            serde_json::json!({
                "kind": "seed",
                "workspaceID": WORKSPACE_ID,
                "fileURL": file_url,
                "revisions": revision(0, 0, None),
                "savedDigest": saved_digest,
                "contextDigests": [CONTEXT_ID, context_digest],
                "updatedAt": 10.0
            }),
            None,
            None,
        );
        assert!(seed.committed.is_none());
        let seeded = decoded(&seed.primary);
        assert_eq!(seeded.revisions.working_revision, 0);
        assert_eq!(
            seeded.context_revisions[0],
            Value::String(CONTEXT_ID.into())
        );
        assert_eq!(
            serde_json::from_value::<WorkspaceProjectionRevisionState>(
                seeded.context_revisions[1].clone()
            )
            .expect("seeded context revision"),
            WorkspaceProjectionRevisionState {
                working_revision: 0,
                saved_revision: 0,
                dirty_revision: None,
            }
        );

        let clean_save = transition(
            serde_json::json!({
                "kind": "save",
                "expectedWorkingRevision": 0,
                "operationID": OPERATION_ID,
                "contextRevisions": [CONTEXT_ID, revision(0, 0, None)],
                "contextDigests": [CONTEXT_ID, context_digest],
                "contextTombstones": {},
                "operations": [operation(OPERATION_ID, 10.5, 1)],
                "updatedAt": 10.5
            }),
            Some(&seed.primary.canonical_bytes),
            Some(&saved),
        );
        let clean_pending = decoded(&clean_save.primary);
        assert!(clean_pending.pending_save.is_some());
        assert!(clean_pending.working_document.is_none());
        assert!(clean_save.committed.is_some());

        let unchanged = transition(
            serde_json::json!({
                "kind": "unchanged",
                "expectedWorkingRevision": 0,
                "operation": operation(OPERATION_ID, 11.0, 1),
                "updatedAt": 11.0
            }),
            Some(&seed.primary.canonical_bytes),
            None,
        );
        assert_eq!(decoded(&unchanged.primary).operations.len(), 1);
        assert!(unchanged.committed.is_none());

        let create = transition(
            serde_json::json!({
                "kind": "create",
                "workspaceID": WORKSPACE_ID,
                "fileURL": file_url,
                "contextRevisions": [CONTEXT_ID, revision(1, 0, Some(1))],
                "contextDigests": [CONTEXT_ID, context_digest],
                "operation": operation(OPERATION_ID, 12.0, 1),
                "operationID": OPERATION_ID,
                "updatedAt": 12.0
            }),
            None,
            Some(&saved),
        );
        let create_pending = decoded(&create.primary);
        let create_committed = create.committed.as_ref().expect("create committed");
        assert_eq!(create_pending.revisions.working_revision, 1);
        assert_eq!(create_pending.revisions.saved_revision, 0);
        assert_eq!(create_pending.revisions.dirty_revision, Some(1));
        assert!(create_pending.pending_save.is_some());
        let create_clean = decoded(create_committed);
        assert_eq!(create_clean.revisions.saved_revision, 1);
        assert!(create_clean.pending_save.is_none());
        assert!(create_clean.working_document.is_none());

        let working_plan = transition(
            serde_json::json!({
                "kind": "working",
                "expectedWorkingRevision": 1,
                "newRevisions": revision(2, 1, Some(2)),
                "contextRevisions": [CONTEXT_ID, revision(2, 1, Some(2))],
                "contextDigests": [CONTEXT_ID, context_digest],
                "contextTombstones": {},
                "operations": [operation(second_operation_id, 13.0, 2)],
                "updatedAt": 13.0
            }),
            Some(&create_committed.canonical_bytes),
            Some(&working),
        );
        let dirty = decoded(&working_plan.primary);
        assert_eq!(dirty.revisions.dirty_revision, Some(2));
        assert_eq!(dirty.working_document, Some(base64_encode(&working)));

        let save = transition(
            serde_json::json!({
                "kind": "save",
                "expectedWorkingRevision": 2,
                "operationID": third_operation_id,
                "contextRevisions": [CONTEXT_ID, revision(2, 1, Some(2))],
                "contextDigests": [CONTEXT_ID, context_digest],
                "contextTombstones": {},
                "operations": [operation(third_operation_id, 14.0, 3)],
                "updatedAt": 14.0
            }),
            Some(&working_plan.primary.canonical_bytes),
            Some(&working),
        );
        let save_pending = decoded(&save.primary);
        let save_committed = save.committed.as_ref().expect("save committed");
        assert!(save_pending.pending_save.is_some());
        let saved_clean = decoded(save_committed);
        assert_eq!(saved_clean.revisions.saved_revision, 2);
        assert!(saved_clean.working_document.is_none());

        let recovered = transition(
            serde_json::json!({
                "kind": "recoverPending",
                "expectedWorkspaceID": WORKSPACE_ID
            }),
            Some(&save.primary.canonical_bytes),
            None,
        );
        assert_eq!(
            recovered.primary.canonical_bytes,
            save_committed.canonical_bytes
        );
        assert!(recovered.committed.is_none());

        let reload = transition(
            serde_json::json!({
                "kind": "externalReload",
                "expectedWorkingRevision": 2,
                "newRevision": 3,
                "contextRevisions": [CONTEXT_ID, revision(3, 2, Some(3))],
                "contextDigests": [CONTEXT_ID, context_digest],
                "contextTombstones": {},
                "operations": [operation(OPERATION_ID, 15.0, 4)],
                "updatedAt": 15.0
            }),
            Some(&save_committed.canonical_bytes),
            Some(&reloaded),
        );
        let reloaded_journal = decoded(&reload.primary);
        assert_eq!(
            reloaded_journal.revisions,
            WorkspaceProjectionRevisionState {
                working_revision: 3,
                saved_revision: 3,
                dirty_revision: None,
            }
        );
        assert_eq!(
            reloaded_journal.saved_digest,
            format!("{:x}", Sha256::digest(&reloaded))
        );

        let rebase = transition(
            serde_json::json!({
                "kind": "conflictRebase",
                "expectedRevisions": revision(3, 3, None),
                "newRevisions": revision(4, 3, Some(4)),
                "externalSavedDigest": format!("{:x}", Sha256::digest(&reloaded)),
                "contextRevisions": [CONTEXT_ID, revision(4, 3, Some(4))],
                "contextDigests": [CONTEXT_ID, context_digest],
                "contextTombstones": {},
                "operations": [operation(second_operation_id, 16.0, 5)],
                "updatedAt": 16.0
            }),
            Some(&reload.primary.canonical_bytes),
            Some(&rebased),
        );
        let rebased_journal = decoded(&rebase.primary);
        assert_eq!(rebased_journal.revisions.working_revision, 4);
        assert_eq!(rebased_journal.revisions.saved_revision, 3);
        assert_eq!(
            rebased_journal.working_document,
            Some(base64_encode(&rebased))
        );
        assert!(rebase.committed.is_none());
    }

    #[test]
    fn transition_planner_rejects_missing_documents_and_stale_revision_fences() {
        let current = journal_bytes(None);
        let request = serde_json::json!({
            "kind": "working",
            "expectedWorkingRevision": 7,
            "newRevisions": revision(8, 0, Some(8)),
            "contextRevisions": [CONTEXT_ID, revision(8, 0, Some(8))],
            "contextDigests": [CONTEXT_ID, format!("{:x}", Sha256::digest(b"context"))],
            "contextTombstones": {},
            "operations": [],
            "updatedAt": 20.0
        });
        assert_eq!(
            plan_workspace_working_journal_transition_v1(
                Some(&current),
                &serde_json::to_vec(&request).expect("request"),
                Some(&document("working")),
            ),
            Err(WorkspaceWorkingJournalError::InvalidRevisionState)
        );

        let mut missing_document = request;
        missing_document["expectedWorkingRevision"] = Value::from(0);
        missing_document["newRevisions"] = revision(1, 0, Some(1));
        assert_eq!(
            plan_workspace_working_journal_transition_v1(
                Some(&current),
                &serde_json::to_vec(&missing_document).expect("request"),
                None,
            ),
            Err(WorkspaceWorkingJournalError::InvalidWorkingDocument)
        );
    }

    #[test]
    fn plans_and_validates_saved_revision_and_deletion_metadata() {
        let document_digest = format!("{:x}", Sha256::digest(b"saved document"));
        let saved_request = serde_json::json!({
            "workspaceID": WORKSPACE_ID.to_ascii_uppercase(),
            "savedRevision": 9,
            "documentDigest": document_digest,
            "operationID": OPERATION_ID.to_ascii_uppercase(),
            "updatedAt": 21.5
        });
        let saved = plan_workspace_saved_revision_record_v1(
            &serde_json::to_vec(&saved_request).expect("saved request"),
        )
        .expect("saved revision plan");
        assert_eq!(saved.workspace_id, WORKSPACE_ID);
        assert_eq!(saved.operation_id, OPERATION_ID);
        assert_eq!(saved.schema_version, 1);
        assert_eq!(
            validate_workspace_saved_revision_record_v1(&saved.canonical_bytes)
                .expect("saved revision validation"),
            saved
        );

        let tombstone_request = serde_json::json!({
            "workspaceID": WORKSPACE_ID,
            "fileURL": "file:///tmp/Workspace.json",
            "operation": operation(OPERATION_ID, 22.0, 7),
            "deletedAt": 22.5,
            "cleanupWarnings": ["revision sidecar: denied", "workspace document: busy"]
        });
        let tombstone = plan_workspace_deletion_tombstone_v1(
            &serde_json::to_vec(&tombstone_request).expect("tombstone request"),
        )
        .expect("tombstone plan");
        assert_eq!(tombstone.workspace_id, WORKSPACE_ID);
        assert_eq!(tombstone.operation_id, OPERATION_ID);
        let value: Value =
            serde_json::from_slice(&tombstone.canonical_bytes).expect("tombstone json");
        assert_eq!(
            value["operation"]["diagnostic"],
            "artifact_cleanup_incomplete: revision sidecar: denied; workspace document: busy"
        );

        let mut invalid_saved = saved_request;
        invalid_saved["documentDigest"] = Value::String("invalid".into());
        assert_eq!(
            plan_workspace_saved_revision_record_v1(
                &serde_json::to_vec(&invalid_saved).expect("invalid saved request")
            ),
            Err(WorkspaceWorkingJournalError::InvalidDigest)
        );
    }

    #[test]
    fn validates_and_deterministically_canonicalizes_swift_v1_shape() {
        let working = document("working");
        let first = validate_workspace_working_journal_v1(&journal_bytes(Some(&working)))
            .expect("valid journal");
        let second = validate_workspace_working_journal_v1(&first.canonical_bytes)
            .expect("canonical journal");
        assert_eq!(first.workspace_id, WORKSPACE_ID);
        assert_eq!(first.canonical_bytes, second.canonical_bytes);
        assert_eq!(first.content_digest, second.content_digest);
    }

    #[test]
    fn rejects_future_schema_invalid_context_and_dirty_without_working_bytes() {
        let future = journal_bytes(None);
        let mut value: Value = serde_json::from_slice(&future).expect("json");
        value["version"] = Value::from(2);
        assert_eq!(
            validate_workspace_working_journal_v1(&serde_json::to_vec(&value).expect("bytes")),
            Err(WorkspaceWorkingJournalError::FutureSchema(2))
        );

        value["version"] = Value::from(1);
        value["revisions"] = serde_json::json!({
            "workingRevision": 1,
            "savedRevision": 0,
            "dirtyRevision": 1
        });
        assert_eq!(
            validate_workspace_working_journal_v1(&serde_json::to_vec(&value).expect("bytes")),
            Err(WorkspaceWorkingJournalError::InvalidWorkingDocument)
        );
    }

    #[test]
    fn canonicalizes_permuted_uuid_tables_and_accepts_dirty_bytes_equal_to_saved_digest() {
        let working = document("working");
        let mut equal_dirty: Value =
            serde_json::from_slice(&journal_bytes(Some(&working))).expect("json");
        equal_dirty["savedDigest"] = Value::String(format!("{:x}", Sha256::digest(&working)));
        validate_workspace_working_journal_v1(&serde_json::to_vec(&equal_dirty).expect("bytes"))
            .expect("dirty bytes may equal the saved digest");

        let second_context = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";
        let revision = serde_json::json!({"workingRevision": 0, "savedRevision": 0});
        let digest = format!("{:x}", Sha256::digest(b"second"));
        let mut first: Value = serde_json::from_slice(&journal_bytes(None)).expect("json");
        first["contextRevisions"] = serde_json::json!([
            CONTEXT_ID.to_ascii_uppercase(),
            revision,
            second_context,
            revision
        ]);
        first["contextDigests"] = serde_json::json!([
            CONTEXT_ID.to_ascii_uppercase(),
            format!("{:x}", Sha256::digest(b"context")),
            second_context,
            digest
        ]);
        let mut second = first.clone();
        second["contextRevisions"] =
            serde_json::json!([second_context, revision, CONTEXT_ID, revision]);
        second["contextDigests"] = serde_json::json!([
            second_context,
            format!("{:x}", Sha256::digest(b"second")),
            CONTEXT_ID,
            format!("{:x}", Sha256::digest(b"context"))
        ]);
        let canonical_first =
            validate_workspace_working_journal_v1(&serde_json::to_vec(&first).expect("bytes"))
                .expect("first ordering");
        let canonical_second =
            validate_workspace_working_journal_v1(&serde_json::to_vec(&second).expect("bytes"))
                .expect("second ordering");
        assert_eq!(
            canonical_first.canonical_bytes,
            canonical_second.canonical_bytes
        );
        assert_eq!(
            canonical_first.content_digest,
            canonical_second.content_digest
        );
    }

    #[test]
    fn rejects_duplicate_operations_and_invalid_pending_save_identity() {
        let mut duplicate: Value = serde_json::from_slice(&journal_bytes(None)).expect("json");
        let operation = duplicate["operations"][0].clone();
        duplicate["operations"] = Value::Array(vec![operation.clone(), operation]);
        assert_eq!(
            validate_workspace_working_journal_v1(&serde_json::to_vec(&duplicate).expect("bytes")),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        );

        let mut value: Value = serde_json::from_slice(&journal_bytes(None)).expect("json");
        value["pendingSave"] = serde_json::json!({
            "operationID": "not-a-uuid",
            "documentDigest": format!("{:x}", Sha256::digest(b"document"))
        });
        assert_eq!(
            validate_workspace_working_journal_v1(&serde_json::to_vec(&value).expect("bytes")),
            Err(WorkspaceWorkingJournalError::InvalidPendingSave)
        );
    }
}
