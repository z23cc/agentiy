//! Workspace persistence, command admission, and process-lifetime authority boundary.
//!
//! Physical files and leases remain Swift-owned. Rust validates and plans bounded durable artifacts,
//! reconstructs replay admission from those artifacts, and retains the immutable semantic/revision/
//! publication aggregate used by direct reads. Document-schema projection remains in `workspace_context`.

use crate::workspace_context::{
    MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
    MAXIMUM_WORKSPACE_PROJECTION_PUBLICATION_EVENT_COUNT, WorkspaceContextAuthorityState,
    WorkspaceDocumentProjection, WorkspaceDocumentProjectionError,
    WorkspaceProjectionAuthorityState, WorkspaceProjectionCatalog, WorkspaceProjectionCatalogError,
    WorkspaceProjectionCatalogLimits, WorkspaceProjectionEntry, WorkspaceProjectionHealth,
    WorkspaceProjectionHealthKind, WorkspaceProjectionPublicationEvent,
    WorkspaceProjectionPublicationKind, WorkspaceProjectionPublicationState,
    WorkspaceProjectionPublishedWorkspace, WorkspaceProjectionRevisionState,
    WorkspaceProjectionSnapshot, canonical_uuid, is_valid_revision_state,
    project_workspace_document_v1,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub const WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1: u16 = 1;
pub const WORKSPACE_SEMANTIC_PLANNER_VERSION_V1: u16 = 1;
pub const MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1: usize = 128 * 1024 * 1024;
pub const MAXIMUM_WORKSPACE_WORKING_JOURNAL_OPERATION_COUNT_V1: usize = 256;
pub const MAXIMUM_WORKSPACE_COMMAND_PROTECTED_IDENTITY_COUNT_V1: usize = 256;
pub const MAXIMUM_WORKSPACE_COMMAND_ADMISSION_GLOBAL_OPERATION_COUNT_V1: usize = 4096;
pub const MAXIMUM_WORKSPACE_COMMAND_ADMISSION_WORKSPACE_OPERATION_COUNT_V1: usize = 256;
pub const MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1: usize = 65_536;
pub const MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_BYTES_V1: usize = 256 * 1024 * 1024;
pub const MAXIMUM_WORKSPACE_COMMAND_ADMISSION_CLAIM_COUNT_V1: usize = 4_096;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceCommandOriginV1 {
    AppPresentation { window_id: i64 },
    AppMcp { connection_id: Option<String> },
    Standalone,
    ExternalReload,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkspaceCommandKindV1 {
    Create,
    Replace,
    Save,
    Delete,
    ResolveExternalConflict,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum WorkspaceTabLocationV1 {
    Composed,
    Stashed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceProtectedAgentIdentityV1 {
    pub tab_id: String,
    pub location: WorkspaceTabLocationV1,
    pub active_agent_session_id: Option<String>,
    pub is_pinned: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCommandIdentityRequestV1 {
    pub operation_id: String,
    pub expected_catalog_revision: Option<u64>,
    pub expected_workspace_revision: Option<u64>,
    pub expected_context_revision: Option<u64>,
    pub origin: WorkspaceCommandOriginV1,
    pub command_kind: WorkspaceCommandKindV1,
    pub workspace_id: String,
    pub file_url: Option<String>,
    pub content_digest: Option<String>,
    pub accept_external: Option<bool>,
    pub protected_agent_identities: Vec<WorkspaceProtectedAgentIdentityV1>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCommandIdentityV1 {
    pub workspace_id: String,
    pub command_kind: WorkspaceCommandKindV1,
    pub fingerprint: String,
}

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
    DuplicateCatalogIdentity,
    InvalidFileUrl,
    InvalidRevisionState,
    InvalidDigest,
    InvalidWorkingDocument,
    InvalidContextTable,
    InvalidOperationLedger,
    InvalidPendingSave,
    InvalidTimestamp,
    ExternalDocumentConflict,
    StaleRecoverySnapshot,
    FullRecoveryRequired,
    InvalidTransaction,
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
            Self::DuplicateCatalogIdentity => {
                formatter.write_str("workspace catalog contains a duplicate identity")
            }
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
            Self::ExternalDocumentConflict => {
                formatter.write_str("workspace document changed outside the transaction")
            }
            Self::StaleRecoverySnapshot => {
                formatter.write_str("workspace admission recovery snapshot is stale")
            }
            Self::FullRecoveryRequired => {
                formatter.write_str("workspace admission full recovery is required")
            }
            Self::InvalidTransaction => {
                formatter.write_str("workspace save transaction is invalid")
            }
        }
    }
}

impl std::error::Error for WorkspaceWorkingJournalError {}

pub fn workspace_command_identity_v1(
    request: WorkspaceCommandIdentityRequestV1,
) -> Result<WorkspaceCommandIdentityV1, WorkspaceWorkingJournalError> {
    fn foundation_uuid(value: &str) -> Result<String, WorkspaceWorkingJournalError> {
        canonical_uuid(value)
            .map(|canonical| canonical.to_ascii_uppercase())
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)
    }

    fn optional_revision(value: Option<u64>) -> String {
        value.map_or_else(|| "nil".to_owned(), |revision| revision.to_string())
    }

    let operation_id = foundation_uuid(&request.operation_id)?;
    let workspace_id = canonical_uuid(&request.workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    let workspace_component = workspace_id.to_ascii_uppercase();
    let origin = match request.origin {
        WorkspaceCommandOriginV1::AppPresentation { window_id } => {
            format!("presentation:{window_id}")
        }
        WorkspaceCommandOriginV1::AppMcp { connection_id } => format!(
            "app-mcp:{}",
            connection_id
                .as_deref()
                .map(foundation_uuid)
                .transpose()?
                .unwrap_or_else(|| "nil".to_owned())
        ),
        WorkspaceCommandOriginV1::Standalone => "standalone".to_owned(),
        WorkspaceCommandOriginV1::ExternalReload => "external-reload".to_owned(),
    };

    let mut components = vec![
        operation_id,
        optional_revision(request.expected_catalog_revision),
        optional_revision(request.expected_workspace_revision),
        optional_revision(request.expected_context_revision),
        origin,
    ];

    match request.command_kind {
        WorkspaceCommandKindV1::Create | WorkspaceCommandKindV1::Replace => {
            let file_url = request
                .file_url
                .filter(|value| valid_file_url(value))
                .ok_or(WorkspaceWorkingJournalError::InvalidFileUrl)?;
            let content_digest = request
                .content_digest
                .filter(|value| is_sha256_digest(value))
                .ok_or(WorkspaceWorkingJournalError::InvalidDigest)?;
            if request.accept_external.is_some() || !request.protected_agent_identities.is_empty() {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            components.extend([
                match request.command_kind {
                    WorkspaceCommandKindV1::Create => "create".to_owned(),
                    WorkspaceCommandKindV1::Replace => "replace".to_owned(),
                    _ => unreachable!(),
                },
                workspace_component,
                file_url,
                content_digest,
            ]);
        }
        WorkspaceCommandKindV1::Save | WorkspaceCommandKindV1::Delete => {
            if request.file_url.is_some()
                || request.content_digest.is_some()
                || request.accept_external.is_some()
                || !request.protected_agent_identities.is_empty()
            {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            components.extend([
                match request.command_kind {
                    WorkspaceCommandKindV1::Save => "save".to_owned(),
                    WorkspaceCommandKindV1::Delete => "delete".to_owned(),
                    _ => unreachable!(),
                },
                workspace_component,
            ]);
        }
        WorkspaceCommandKindV1::ResolveExternalConflict => {
            if request.file_url.is_some() || request.content_digest.is_some() {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            let accept_external = request
                .accept_external
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
            if request.protected_agent_identities.len()
                > MAXIMUM_WORKSPACE_COMMAND_PROTECTED_IDENTITY_COUNT_V1
            {
                return Err(WorkspaceWorkingJournalError::InputTooLarge {
                    actual: request.protected_agent_identities.len(),
                    maximum: MAXIMUM_WORKSPACE_COMMAND_PROTECTED_IDENTITY_COUNT_V1,
                });
            }
            let mut protected = request
                .protected_agent_identities
                .into_iter()
                .map(|identity| {
                    Ok((
                        identity.location,
                        foundation_uuid(&identity.tab_id)?,
                        identity
                            .active_agent_session_id
                            .as_deref()
                            .map(foundation_uuid)
                            .transpose()?,
                        identity.is_pinned,
                    ))
                })
                .collect::<Result<Vec<_>, WorkspaceWorkingJournalError>>()?;
            protected
                .sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1)));
            components.extend([
                "resolve".to_owned(),
                workspace_component,
                if accept_external { "external" } else { "local" }.to_owned(),
            ]);
            for (location, tab_id, session_id, is_pinned) in protected {
                components.extend([
                    match location {
                        WorkspaceTabLocationV1::Composed => "composed".to_owned(),
                        WorkspaceTabLocationV1::Stashed => "stashed".to_owned(),
                    },
                    tab_id,
                    session_id.unwrap_or_else(|| "nil".to_owned()),
                    if is_pinned { "pinned" } else { "unpinned" }.to_owned(),
                ]);
            }
        }
    }

    let canonical = components
        .into_iter()
        .map(|component| format!("{}:{component}", component.len()))
        .collect::<Vec<_>>()
        .join("|");
    Ok(WorkspaceCommandIdentityV1 {
        workspace_id,
        command_kind: request.command_kind,
        fingerprint: format!("{:x}", Sha256::digest(canonical.as_bytes())),
    })
}

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

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceRecordedOperationV1 {
    #[serde(rename = "operationID")]
    pub operation_id: String,
    pub fingerprint: String,
    pub recorded_at: f64,
    pub disposition: String,
    pub before: Option<WorkspaceProjectionRevisionState>,
    pub after: Option<WorkspaceProjectionRevisionState>,
    pub catalog_revision: u64,
    pub resulting_digest: Option<String>,
    pub error_code: Option<String>,
    pub diagnostic: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkspaceCommandAdmissionLookupScopeV1 {
    Workspace,
    Global,
}

#[derive(Clone, Debug, PartialEq)]
enum WorkspaceCommandAdmissionDecisionV1 {
    Unseen,
    Collision {
        scope: WorkspaceCommandAdmissionLookupScopeV1,
    },
    Replay {
        scope: WorkspaceCommandAdmissionLookupScopeV1,
        operation: WorkspaceRecordedOperationV1,
    },
}

#[cfg(test)]
#[derive(Clone, Debug, PartialEq)]
struct WorkspaceCommandAdmissionInspectionV1 {
    identity: WorkspaceCommandIdentityV1,
    decision: WorkspaceCommandAdmissionDecisionV1,
}

#[derive(Debug)]
pub enum WorkspaceCommandAdmissionAcquireV1 {
    Claimed {
        identity: WorkspaceCommandIdentityV1,
        claim: WorkspaceCommandExecutionClaimV1,
    },
    Pending {
        identity: WorkspaceCommandIdentityV1,
        generation: u64,
    },
    Collision {
        identity: WorkspaceCommandIdentityV1,
        scope: Option<WorkspaceCommandAdmissionLookupScopeV1>,
    },
    Replay {
        identity: WorkspaceCommandIdentityV1,
        scope: WorkspaceCommandAdmissionLookupScopeV1,
        operation: WorkspaceRecordedOperationV1,
    },
}

impl WorkspaceCommandAdmissionAcquireV1 {
    pub fn identity(&self) -> &WorkspaceCommandIdentityV1 {
        match self {
            Self::Claimed { identity, .. }
            | Self::Pending { identity, .. }
            | Self::Collision { identity, .. }
            | Self::Replay { identity, .. } => identity,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCommandAdmissionJournalRecoveryV1 {
    pub workspace_id: String,
    /// `None` is the existing absent-journal empty ledger, not a failed read.
    pub canonical_bytes: Option<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCommandAdmissionDeletionRecoveryV1 {
    pub workspace_id: String,
    /// `None` selects the authoritative catalog tombstone unchanged.
    pub canonical_bytes: Option<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCommandAdmissionRecoveryV1 {
    pub catalog_bytes: Vec<u8>,
    pub journals: Vec<WorkspaceCommandAdmissionJournalRecoveryV1>,
    pub deletion_sidecars: Vec<WorkspaceCommandAdmissionDeletionRecoveryV1>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCommandAdmissionTargetRecoveryV1 {
    pub catalog_bytes: Vec<u8>,
    pub workspace_id: String,
    pub journal_bytes: Option<Vec<u8>>,
    pub deletion_sidecar_bytes: Option<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceRecoveryArtifactEvidenceV1 {
    Absent,
    Present(Vec<u8>),
    Unavailable(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceSemanticRecoveryEvidenceV1 {
    pub workspace_id: String,
    pub journal: WorkspaceRecoveryArtifactEvidenceV1,
    pub saved_document: WorkspaceRecoveryArtifactEvidenceV1,
    pub saved_revision: WorkspaceRecoveryArtifactEvidenceV1,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceSemanticDeletionRecoveryEvidenceV1 {
    pub workspace_id: String,
    pub sidecar: WorkspaceRecoveryArtifactEvidenceV1,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceSemanticFullRecoveryV1 {
    pub catalog_bytes: Vec<u8>,
    pub workspaces: Vec<WorkspaceSemanticRecoveryEvidenceV1>,
    pub deletions: Vec<WorkspaceSemanticDeletionRecoveryEvidenceV1>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceSemanticTargetRecoveryV1 {
    pub catalog_bytes: Vec<u8>,
    pub workspace_id: String,
    pub journal: WorkspaceRecoveryArtifactEvidenceV1,
    pub saved_document: WorkspaceRecoveryArtifactEvidenceV1,
    pub saved_revision: WorkspaceRecoveryArtifactEvidenceV1,
    pub deletion_sidecar: WorkspaceRecoveryArtifactEvidenceV1,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WorkspaceSemanticRecoveryAdmissionDispositionV1 {
    Installed,
    Preserved,
    Quarantined,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSemanticContextRecoveryV1 {
    pub context_id: String,
    pub revisions: WorkspaceProjectionRevisionState,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSemanticActiveRecoveryV1 {
    pub workspace_id: String,
    pub file_url: String,
    pub document_bytes: Vec<u8>,
    pub document_digest: String,
    pub saved_digest: String,
    pub revisions: WorkspaceProjectionRevisionState,
    pub context_revisions: Vec<WorkspaceSemanticContextRecoveryV1>,
    pub context_tombstones: Vec<(String, u64)>,
    pub operations: Vec<WorkspaceRecordedOperationV1>,
    pub health: WorkspaceProjectionHealth,
    pub external_document_bytes: Option<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSemanticUnavailableRecoveryV1 {
    pub workspace_id: String,
    pub file_url: String,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum WorkspaceSemanticRecoveryRowV1 {
    Active {
        row: WorkspaceSemanticActiveRecoveryV1,
    },
    Unavailable {
        row: WorkspaceSemanticUnavailableRecoveryV1,
    },
    Deleted {
        workspace_id: String,
        file_url: String,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum WorkspaceSemanticTargetDirectiveV1 {
    Upsert {
        row: WorkspaceSemanticActiveRecoveryV1,
    },
    Unavailable {
        row: WorkspaceSemanticUnavailableRecoveryV1,
    },
    Delete {
        workspace_id: String,
        file_url: String,
    },
    NoChange,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSemanticJournalRewriteV1 {
    pub workspace_id: String,
    pub expected_artifact_digest: String,
    pub replacement_canonical_bytes: Vec<u8>,
    pub replacement_canonical_digest: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum WorkspaceSemanticRecoveryProjectionV1 {
    Full {
        rows: Vec<WorkspaceSemanticRecoveryRowV1>,
    },
    Target {
        directive: WorkspaceSemanticTargetDirectiveV1,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceSemanticRecoveryPreviewV1 {
    pub catalog_revision: u64,
    pub catalog_digest: String,
    pub target_workspace_id: Option<String>,
    pub global_health: WorkspaceProjectionHealth,
    pub admission_disposition: WorkspaceSemanticRecoveryAdmissionDispositionV1,
    pub projection: WorkspaceSemanticRecoveryProjectionV1,
    pub journal_rewrites: Vec<WorkspaceSemanticJournalRewriteV1>,
    pub projection_digest: String,
}

#[derive(Debug)]
pub struct WorkspaceSemanticRecoveryCommitV1 {
    pub admission: Option<PreparedWorkspaceCommandAdmissionV1>,
    pub admission_receipt: Option<WorkspaceCommandAdmissionRecoveryReceiptV1>,
    pub catalog_revision: u64,
    pub catalog_digest: String,
    pub target_workspace_id: Option<String>,
    pub admission_disposition: WorkspaceSemanticRecoveryAdmissionDispositionV1,
    pub projection_digest: String,
}

/// P5-7h event input. Rust assigns the next publication sequence under the same capability lock
/// that owns command admission and the complete authoritative workspace projection.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceAuthorityPublicationDraftV1 {
    pub catalog_revision: u64,
    pub kind: WorkspaceProjectionPublicationKind,
    pub workspace_id: Option<String>,
    pub context_id: Option<String>,
    pub operation_id: Option<String>,
    pub revisions: Option<WorkspaceProjectionRevisionState>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceAuthorityPublicationReceiptV1 {
    pub previous_generation: u64,
    pub generation: u64,
    pub projection_changed: bool,
    pub workspace_count: usize,
    pub retained_bytes: usize,
    pub previous_catalog_revision: u64,
    pub previous_publication_sequence: u64,
    pub catalog_revision: u64,
    pub publication_sequence: u64,
    pub event_log_floor_sequence: u64,
    pub event_log_count: usize,
    pub projection_digest: String,
    pub event: WorkspaceProjectionPublicationEvent,
}

#[derive(Clone, Debug)]
struct WorkspaceAuthorityPublicationCandidateV1 {
    retained_bytes: usize,
    entries: Vec<Arc<WorkspaceProjectionEntry>>,
    projection_digest: String,
    draft: WorkspaceAuthorityPublicationDraftV1,
    workspace_id: Option<String>,
    context_id: Option<String>,
    operation_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WorkspaceAuthorityPublicationHeadV1 {
    generation: u64,
    catalog_revision: u64,
    publication_sequence: u64,
    projection_digest: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WorkspaceAuthorityPublicationReservationV1 {
    reservation_id: u64,
    workspace_id: String,
    operation_id: String,
    fingerprint: String,
    claim_generation: u64,
    head: WorkspaceAuthorityPublicationHeadV1,
}

/// Single-use command publication preparation. It reserves the exact aggregate head and is bound
/// to the claim's admission reservation so it cannot be attached to another transaction.
#[derive(Debug)]
pub struct PreparedWorkspaceAuthorityPublicationV1 {
    inner: Arc<Mutex<WorkspaceCommandAdmissionInnerV1>>,
    candidate: WorkspaceAuthorityPublicationCandidateV1,
    reservation: WorkspaceAuthorityPublicationReservationV1,
    active: AtomicBool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceAuthorityProjectionSyncReceiptV1 {
    pub previous_generation: u64,
    pub generation: u64,
    pub projection_changed: bool,
    pub workspace_count: usize,
    pub retained_bytes: usize,
    pub catalog_revision: u64,
    pub publication_sequence: u64,
    pub projection_digest: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceAuthorityReadV1 {
    pub projection: Option<WorkspaceDocumentProjection>,
    pub authority: Option<WorkspaceProjectionAuthorityState>,
    pub content_digest: Option<String>,
    pub generation: u64,
    pub catalog_revision: u64,
    pub publication_sequence: u64,
    pub event_log_floor_sequence: u64,
    pub event_log_count: usize,
    pub projection_digest: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCommandAdmissionRecoveryReceiptV1 {
    pub catalog_revision: u64,
    pub catalog_digest: String,
    pub target_workspace_id: Option<String>,
    pub diagnostics: WorkspaceCommandAdmissionDiagnosticsV1,
}

#[derive(Clone, Debug, PartialEq)]
struct WorkspaceCommandAdmissionRecoveredRecordV1 {
    workspace_id: Option<String>,
    operation: WorkspaceRecordedOperationV1,
}

#[cfg(test)]
type WorkspaceCommandAdmissionSeedRecordV1 = WorkspaceCommandAdmissionRecoveredRecordV1;

#[derive(Clone, Debug, PartialEq)]
pub enum WorkspaceCommandAdmissionFinalizationV1 {
    Workspace {
        workspace_id: String,
        operation: WorkspaceRecordedOperationV1,
    },
    Delete {
        workspace_id: String,
        operation: WorkspaceRecordedOperationV1,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WorkspaceCommandAdmissionDiagnosticsV1 {
    pub global_operation_count: usize,
    pub workspace_count: usize,
    pub workspace_operation_count: usize,
}

#[derive(Clone, Debug)]
struct BoundedWorkspaceCommandOperationIndexV1 {
    capacity: usize,
    values: BTreeMap<String, WorkspaceRecordedOperationV1>,
    order: VecDeque<String>,
}

impl BoundedWorkspaceCommandOperationIndexV1 {
    fn empty(capacity: usize) -> Self {
        Self {
            capacity,
            values: BTreeMap::new(),
            order: VecDeque::new(),
        }
    }

    fn from_records(
        capacity: usize,
        records: Vec<WorkspaceRecordedOperationV1>,
    ) -> Result<Self, WorkspaceWorkingJournalError> {
        let mut distinct = BTreeMap::<String, WorkspaceRecordedOperationV1>::new();
        for mut operation in records {
            validate_and_canonicalize_recorded_operation(&mut operation)?;
            match distinct.get(&operation.operation_id) {
                Some(existing) if existing == &operation => continue,
                Some(existing)
                    if existing
                        .recorded_at
                        .total_cmp(&operation.recorded_at)
                        .is_eq() =>
                {
                    return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
                }
                Some(existing) if existing.recorded_at > operation.recorded_at => continue,
                _ => {}
            }
            distinct.insert(operation.operation_id.clone(), operation);
        }
        let mut records = distinct.into_values().collect::<Vec<_>>();
        records.sort_by(|left, right| {
            left.recorded_at
                .total_cmp(&right.recorded_at)
                .then_with(|| left.operation_id.cmp(&right.operation_id))
        });
        let retained_from = records.len().saturating_sub(capacity);
        let mut index = Self::empty(capacity);
        for operation in records.into_iter().skip(retained_from) {
            index.insert(operation);
        }
        Ok(index)
    }

    fn insert(&mut self, operation: WorkspaceRecordedOperationV1) {
        let operation_id = operation.operation_id.clone();
        if let Some(existing) = self.values.get_mut(&operation_id) {
            *existing = operation;
            return;
        }
        self.values.insert(operation_id.clone(), operation);
        self.order.push_back(operation_id);
        while self.values.len() > self.capacity {
            if let Some(evicted) = self.order.pop_front() {
                self.values.remove(&evicted);
            } else {
                break;
            }
        }
    }

    fn replace_exact(
        &mut self,
        expected: &WorkspaceRecordedOperationV1,
        replacement: WorkspaceRecordedOperationV1,
    ) -> Result<(), WorkspaceWorkingJournalError> {
        if expected.operation_id != replacement.operation_id {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }
        let current = self
            .values
            .get_mut(&expected.operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidOperationLedger)?;
        if current == &replacement {
            return Ok(());
        }
        if current != expected {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }
        *current = replacement;
        Ok(())
    }

    fn get(&self, operation_id: &str) -> Option<&WorkspaceRecordedOperationV1> {
        self.values.get(operation_id)
    }

    fn len(&self) -> usize {
        self.values.len()
    }

    fn records(&self) -> Vec<WorkspaceRecordedOperationV1> {
        self.values.values().cloned().collect()
    }
}

#[derive(Clone, Debug)]
struct WorkspaceCommandAdmissionStateV1 {
    global: BoundedWorkspaceCommandOperationIndexV1,
    workspaces: BTreeMap<String, BoundedWorkspaceCommandOperationIndexV1>,
}

impl WorkspaceCommandAdmissionStateV1 {
    fn from_records(
        records: &[WorkspaceCommandAdmissionRecoveredRecordV1],
    ) -> Result<Self, WorkspaceWorkingJournalError> {
        if records.len() > MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1 {
            return Err(WorkspaceWorkingJournalError::InputTooLarge {
                actual: records.len(),
                maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1,
            });
        }
        let mut global = Vec::with_capacity(records.len());
        let mut workspace_records = BTreeMap::<String, Vec<WorkspaceRecordedOperationV1>>::new();
        for record in records {
            let mut operation = record.operation.clone();
            validate_and_canonicalize_recorded_operation(&mut operation)?;
            global.push(operation.clone());
            if let Some(workspace_id) = &record.workspace_id {
                let workspace_id = canonical_uuid(workspace_id)
                    .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
                workspace_records
                    .entry(workspace_id)
                    .or_default()
                    .push(operation);
            }
        }
        let global = BoundedWorkspaceCommandOperationIndexV1::from_records(
            MAXIMUM_WORKSPACE_COMMAND_ADMISSION_GLOBAL_OPERATION_COUNT_V1,
            global,
        )?;
        let workspaces = workspace_records
            .into_iter()
            .map(|(workspace_id, records)| {
                Ok((
                    workspace_id,
                    BoundedWorkspaceCommandOperationIndexV1::from_records(
                        MAXIMUM_WORKSPACE_COMMAND_ADMISSION_WORKSPACE_OPERATION_COUNT_V1,
                        records,
                    )?,
                ))
            })
            .collect::<Result<BTreeMap<_, _>, WorkspaceWorkingJournalError>>()?;
        let state = Self { global, workspaces };
        state.require_reconstructible_size()?;
        Ok(state)
    }

    fn decision(
        &self,
        workspace_id: &str,
        operation_id: &str,
        fingerprint: &str,
    ) -> WorkspaceCommandAdmissionDecisionV1 {
        fn classify(
            operation: &WorkspaceRecordedOperationV1,
            fingerprint: &str,
            scope: WorkspaceCommandAdmissionLookupScopeV1,
        ) -> WorkspaceCommandAdmissionDecisionV1 {
            if operation.fingerprint == fingerprint {
                WorkspaceCommandAdmissionDecisionV1::Replay {
                    scope,
                    operation: operation.clone(),
                }
            } else {
                WorkspaceCommandAdmissionDecisionV1::Collision { scope }
            }
        }

        if let Some(operation) = self
            .workspaces
            .get(workspace_id)
            .and_then(|index| index.get(operation_id))
        {
            return classify(
                operation,
                fingerprint,
                WorkspaceCommandAdmissionLookupScopeV1::Workspace,
            );
        }
        if let Some(operation) = self.global.get(operation_id) {
            return classify(
                operation,
                fingerprint,
                WorkspaceCommandAdmissionLookupScopeV1::Global,
            );
        }
        WorkspaceCommandAdmissionDecisionV1::Unseen
    }

    fn insert(
        &mut self,
        workspace_id: Option<String>,
        mut operation: WorkspaceRecordedOperationV1,
    ) -> Result<(), WorkspaceWorkingJournalError> {
        validate_and_canonicalize_recorded_operation(&mut operation)?;
        let workspace_id = workspace_id
            .map(|workspace_id| {
                canonical_uuid(&workspace_id).ok_or(WorkspaceWorkingJournalError::InvalidIdentity)
            })
            .transpose()?;
        let operation_id = &operation.operation_id;
        if self
            .global
            .get(operation_id)
            .is_some_and(|existing| existing != &operation)
            || workspace_id.as_ref().is_some_and(|workspace_id| {
                self.workspaces
                    .get(workspace_id)
                    .and_then(|index| index.get(operation_id))
                    .is_some_and(|existing| existing != &operation)
            })
        {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }
        let global_growth = usize::from(
            self.global.get(operation_id).is_none() && self.global.len() < self.global.capacity,
        );
        let workspace_growth = workspace_id
            .as_ref()
            .map(|workspace_id| {
                self.workspaces.get(workspace_id).map_or(1, |index| {
                    usize::from(index.get(operation_id).is_none() && index.len() < index.capacity)
                })
            })
            .unwrap_or(0);
        let projected_count = self
            .stored_operation_count()
            .checked_add(global_growth)
            .and_then(|count| count.checked_add(workspace_growth))
            .ok_or(WorkspaceWorkingJournalError::InputTooLarge {
                actual: usize::MAX,
                maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1,
            })?;
        if projected_count > MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1 {
            return Err(WorkspaceWorkingJournalError::InputTooLarge {
                actual: projected_count,
                maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1,
            });
        }
        self.global.insert(operation.clone());
        if let Some(workspace_id) = workspace_id {
            self.workspaces
                .entry(workspace_id)
                .or_insert_with(|| {
                    BoundedWorkspaceCommandOperationIndexV1::empty(
                        MAXIMUM_WORKSPACE_COMMAND_ADMISSION_WORKSPACE_OPERATION_COUNT_V1,
                    )
                })
                .insert(operation);
        }
        Ok(())
    }

    fn stored_operation_count(&self) -> usize {
        self.global.len()
            + self
                .workspaces
                .values()
                .map(BoundedWorkspaceCommandOperationIndexV1::len)
                .sum::<usize>()
    }

    fn require_reconstructible_size(&self) -> Result<(), WorkspaceWorkingJournalError> {
        let actual = self.stored_operation_count();
        if actual > MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1 {
            return Err(WorkspaceWorkingJournalError::InputTooLarge {
                actual,
                maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1,
            });
        }
        Ok(())
    }

    fn diagnostics(&self) -> WorkspaceCommandAdmissionDiagnosticsV1 {
        WorkspaceCommandAdmissionDiagnosticsV1 {
            global_operation_count: self.global.len(),
            workspace_count: self.workspaces.len(),
            workspace_operation_count: self
                .workspaces
                .values()
                .map(BoundedWorkspaceCommandOperationIndexV1::len)
                .sum(),
        }
    }
}

impl WorkspaceCommandAdmissionFinalizationV1 {
    fn workspace_id(&self) -> &str {
        match self {
            Self::Workspace { workspace_id, .. } | Self::Delete { workspace_id, .. } => {
                workspace_id
            }
        }
    }

    fn conflicts_with(&self, other: &Self) -> bool {
        canonical_uuid(self.workspace_id()) == canonical_uuid(other.workspace_id())
            && matches!(
                (self, other),
                (Self::Workspace { .. }, Self::Delete { .. })
                    | (Self::Delete { .. }, Self::Workspace { .. })
            )
    }

    /// Projects reserved growth without allowing an invisible delete to release workspace
    /// capacity. This makes reservation validity independent of later physical completion order.
    fn apply_reservation_projection(
        &self,
        state: &mut WorkspaceCommandAdmissionStateV1,
    ) -> Result<(), WorkspaceWorkingJournalError> {
        match self {
            Self::Workspace {
                workspace_id,
                operation,
            } => state.insert(Some(workspace_id.clone()), operation.clone()),
            Self::Delete { operation, .. } => state.insert(None, operation.clone()),
        }
    }

    fn apply(
        &self,
        state: &mut WorkspaceCommandAdmissionStateV1,
    ) -> Result<(), WorkspaceWorkingJournalError> {
        match self {
            Self::Workspace {
                workspace_id,
                operation,
            } => state.insert(Some(workspace_id.clone()), operation.clone()),
            Self::Delete {
                workspace_id,
                operation,
            } => {
                let workspace_id = canonical_uuid(workspace_id)
                    .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
                state.insert(None, operation.clone())?;
                state.workspaces.remove(&workspace_id);
                Ok(())
            }
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WorkspaceCommandExecutionClaimStateV1 {
    workspace_id: String,
    fingerprint: String,
    generation: u64,
    reservation_id: Option<u64>,
}

fn workspace_authority_projection_digest_v1(
    entries: &[Arc<WorkspaceProjectionEntry>],
) -> Result<String, WorkspaceWorkingJournalError> {
    let canonical = entries
        .iter()
        .map(|entry| {
            (
                entry.content_digest.as_str(),
                &entry.projection,
                &entry.authority,
            )
        })
        .collect::<Vec<_>>();
    let bytes = serde_json::to_vec(&canonical)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

fn empty_workspace_authority_snapshot_v1()
-> Result<(Arc<WorkspaceProjectionSnapshot>, String), WorkspaceWorkingJournalError> {
    let snapshot = Arc::new(WorkspaceProjectionSnapshot {
        generation: 0,
        retained_bytes: 0,
        entries: Vec::new(),
    });
    let digest = workspace_authority_projection_digest_v1(&snapshot.entries)?;
    Ok((snapshot, digest))
}

fn workspace_authority_catalog_error_v1(
    error: WorkspaceProjectionCatalogError,
) -> WorkspaceWorkingJournalError {
    match error {
        WorkspaceProjectionCatalogError::WorkspaceCapacityExceeded { actual, maximum }
        | WorkspaceProjectionCatalogError::RetainedBytesExceeded { actual, maximum } => {
            WorkspaceWorkingJournalError::InputTooLarge { actual, maximum }
        }
        WorkspaceProjectionCatalogError::DuplicateWorkspaceId(_) => {
            WorkspaceWorkingJournalError::DuplicateCatalogIdentity
        }
        WorkspaceProjectionCatalogError::Projection(error) => match error {
            WorkspaceDocumentProjectionError::InputTooLarge {
                actual_bytes,
                maximum_bytes,
            } => WorkspaceWorkingJournalError::InputTooLarge {
                actual: actual_bytes,
                maximum: maximum_bytes,
            },
            WorkspaceDocumentProjectionError::InvalidTopLevel => {
                WorkspaceWorkingJournalError::Malformed
            }
            WorkspaceDocumentProjectionError::MissingWorkspaceId => {
                WorkspaceWorkingJournalError::InvalidIdentity
            }
            WorkspaceDocumentProjectionError::FutureSchema(version) => u16::try_from(version)
                .map(WorkspaceWorkingJournalError::FutureSchema)
                .unwrap_or(WorkspaceWorkingJournalError::Malformed),
            WorkspaceDocumentProjectionError::InvalidContext(_) => {
                WorkspaceWorkingJournalError::InvalidContextTable
            }
        },
        _ => WorkspaceWorkingJournalError::InvalidTransaction,
    }
}

fn prepare_workspace_authority_snapshot_v1(
    workspaces: &[WorkspaceProjectionPublishedWorkspace],
) -> Result<(usize, Vec<Arc<WorkspaceProjectionEntry>>, String), WorkspaceWorkingJournalError> {
    let catalog = WorkspaceProjectionCatalog::new(WorkspaceProjectionCatalogLimits::default());
    let prepared = catalog
        .replace_published_workspaces(0, workspaces)
        .map_err(workspace_authority_catalog_error_v1)?
        .snapshot;
    let digest = workspace_authority_projection_digest_v1(&prepared.entries)?;
    Ok((prepared.retained_bytes, prepared.entries.clone(), digest))
}

fn prepare_workspace_authority_publication_candidate_v1(
    workspaces: &[WorkspaceProjectionPublishedWorkspace],
    draft: WorkspaceAuthorityPublicationDraftV1,
) -> Result<WorkspaceAuthorityPublicationCandidateV1, WorkspaceWorkingJournalError> {
    let (retained_bytes, entries, projection_digest) =
        prepare_workspace_authority_snapshot_v1(workspaces)?;
    let workspace_id = draft
        .workspace_id
        .as_deref()
        .map(|value| canonical_uuid(value).ok_or(WorkspaceWorkingJournalError::InvalidIdentity))
        .transpose()?;
    let context_id = draft
        .context_id
        .as_deref()
        .map(|value| canonical_uuid(value).ok_or(WorkspaceWorkingJournalError::InvalidIdentity))
        .transpose()?;
    let operation_id = draft
        .operation_id
        .as_deref()
        .map(|value| canonical_uuid(value).ok_or(WorkspaceWorkingJournalError::InvalidIdentity))
        .transpose()?;
    if draft
        .revisions
        .as_ref()
        .is_some_and(|revisions| !is_valid_revision_state(*revisions))
    {
        return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
    }
    validate_workspace_authority_publication_draft_v1(
        &entries,
        &draft,
        workspace_id.as_deref(),
        context_id.as_deref(),
    )?;
    Ok(WorkspaceAuthorityPublicationCandidateV1 {
        retained_bytes,
        entries,
        projection_digest,
        draft,
        workspace_id,
        context_id,
        operation_id,
    })
}

fn validate_workspace_authority_publication_draft_v1(
    entries: &[Arc<WorkspaceProjectionEntry>],
    draft: &WorkspaceAuthorityPublicationDraftV1,
    workspace_id: Option<&str>,
    context_id: Option<&str>,
) -> Result<(), WorkspaceWorkingJournalError> {
    if workspace_id.is_none() && (context_id.is_some() || draft.revisions.is_some()) {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    let entry = workspace_id.and_then(|workspace_id| {
        entries
            .iter()
            .find(|entry| entry.projection.workspace_id == workspace_id)
    });
    if let Some(context_id) = context_id {
        let entry = entry.ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?;
        let projection_contains_context = entry
            .projection
            .contexts
            .iter()
            .any(|context| context.context_id == context_id);
        let authority_contains_context = entry.authority.as_ref().is_some_and(|authority| {
            authority
                .contexts
                .iter()
                .any(|context| context.context_id == context_id)
        });
        if !projection_contains_context || !authority_contains_context {
            return Err(WorkspaceWorkingJournalError::InvalidContextTable);
        }
    }
    if let Some(revisions) = draft.revisions {
        let authoritative_revisions = entry
            .and_then(|entry| entry.authority.as_ref())
            .map(|authority| authority.revisions)
            .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
        if authoritative_revisions != revisions {
            return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
        }
    }
    match draft.kind {
        WorkspaceProjectionPublicationKind::Bootstrapped => {
            if workspace_id.is_some()
                || context_id.is_some()
                || draft.operation_id.is_some()
                || draft.revisions.is_some()
            {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        }
        WorkspaceProjectionPublicationKind::WorkspaceCreated => {
            if entry.is_none() || draft.revisions.is_none() {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        }
        WorkspaceProjectionPublicationKind::WorkspaceDeleted => {
            if entry.is_some() || context_id.is_some() || draft.revisions.is_some() {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        }
        WorkspaceProjectionPublicationKind::WorkingStateCommitted
        | WorkspaceProjectionPublicationKind::SavedDocumentCommitted
        | WorkspaceProjectionPublicationKind::OperationDeduplicated => {
            if entry.is_none() || draft.revisions.is_none() {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        }
        WorkspaceProjectionPublicationKind::ExternalReloaded
        | WorkspaceProjectionPublicationKind::ExternalConflict
        | WorkspaceProjectionPublicationKind::Degraded
        | WorkspaceProjectionPublicationKind::RoutingChanged => {}
    }
    Ok(())
}

fn workspace_authority_publication_head_v1(
    inner: &WorkspaceCommandAdmissionInnerV1,
) -> WorkspaceAuthorityPublicationHeadV1 {
    WorkspaceAuthorityPublicationHeadV1 {
        generation: inner.authority_snapshot.generation,
        catalog_revision: inner.authority_publication.catalog_revision,
        publication_sequence: inner.authority_publication.publication_sequence,
        projection_digest: inner.authority_projection_digest.clone(),
    }
}

fn validate_workspace_authority_publication_head_v1(
    inner: &WorkspaceCommandAdmissionInnerV1,
    candidate: &WorkspaceAuthorityPublicationCandidateV1,
) -> Result<(), WorkspaceWorkingJournalError> {
    if candidate.draft.catalog_revision < inner.authority_publication.catalog_revision {
        return Err(WorkspaceWorkingJournalError::StaleRecoverySnapshot);
    }
    inner
        .authority_publication
        .publication_sequence
        .checked_add(1)
        .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
    if inner.authority_snapshot.entries != candidate.entries {
        inner
            .authority_snapshot
            .generation
            .checked_add(1)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
    }
    Ok(())
}

fn validate_claimed_authority_publication_candidate_v1(
    inner: &WorkspaceCommandAdmissionInnerV1,
    effect: &WorkspaceCommandAdmissionFinalizationV1,
    expected_kind: WorkspaceProjectionPublicationKind,
    claim: &WorkspaceCommandExecutionClaimV1,
    candidate: &WorkspaceAuthorityPublicationCandidateV1,
) -> Result<(), WorkspaceWorkingJournalError> {
    let (workspace_id, operation, is_delete) = match effect {
        WorkspaceCommandAdmissionFinalizationV1::Workspace {
            workspace_id,
            operation,
        } => (workspace_id.as_str(), operation, false),
        WorkspaceCommandAdmissionFinalizationV1::Delete {
            workspace_id,
            operation,
        } => (workspace_id.as_str(), operation, true),
    };
    if candidate.draft.kind != expected_kind {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    if candidate.workspace_id.as_deref() != Some(workspace_id) {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    if candidate.operation_id.as_deref() != Some(operation.operation_id.as_str()) {
        return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
    }
    if operation.operation_id != claim.operation_id || operation.fingerprint != claim.fingerprint {
        return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
    }
    if candidate.draft.catalog_revision != operation.catalog_revision
        || candidate.draft.revisions != operation.after
    {
        return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
    }

    let candidate_entry = candidate
        .entries
        .iter()
        .find(|entry| entry.projection.workspace_id == workspace_id);
    let candidate_revisions = candidate_entry
        .and_then(|entry| entry.authority.as_ref())
        .map(|authority| authority.revisions);
    if candidate_revisions != operation.after {
        return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
    }
    if let Some(resulting_digest) = operation.resulting_digest.as_deref()
        && candidate_entry.map(|entry| entry.content_digest.as_str()) != Some(resulting_digest)
    {
        return Err(WorkspaceWorkingJournalError::InvalidDigest);
    }

    let current_non_target = inner
        .authority_snapshot
        .entries
        .iter()
        .filter(|entry| entry.projection.workspace_id != workspace_id)
        .collect::<Vec<_>>();
    let candidate_non_target = candidate
        .entries
        .iter()
        .filter(|entry| entry.projection.workspace_id != workspace_id)
        .collect::<Vec<_>>();
    if current_non_target != candidate_non_target {
        return Err(WorkspaceWorkingJournalError::StaleRecoverySnapshot);
    }

    let shape_is_valid = match expected_kind {
        WorkspaceProjectionPublicationKind::WorkspaceCreated => {
            !is_delete
                && operation.disposition == "applied"
                && operation.before.is_none()
                && operation.after.is_some()
                && candidate_entry.is_some()
        }
        WorkspaceProjectionPublicationKind::WorkspaceDeleted => {
            is_delete
                && operation.disposition == "applied"
                && operation.before.is_some()
                && operation.after.is_none()
                && candidate_entry.is_none()
        }
        WorkspaceProjectionPublicationKind::OperationDeduplicated => {
            !is_delete
                && operation.disposition == "unchanged"
                && operation.before.is_some()
                && operation.before == operation.after
                && candidate_entry.is_some()
        }
        WorkspaceProjectionPublicationKind::WorkingStateCommitted
        | WorkspaceProjectionPublicationKind::SavedDocumentCommitted
        | WorkspaceProjectionPublicationKind::ExternalReloaded => {
            !is_delete
                && operation.disposition == "applied"
                && operation.before.is_some()
                && operation.after.is_some()
                && candidate_entry.is_some()
        }
        WorkspaceProjectionPublicationKind::Bootstrapped
        | WorkspaceProjectionPublicationKind::ExternalConflict
        | WorkspaceProjectionPublicationKind::Degraded
        | WorkspaceProjectionPublicationKind::RoutingChanged => false,
    };
    if !shape_is_valid {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    validate_workspace_authority_publication_head_v1(inner, candidate)
}

#[derive(Debug)]
struct WorkspaceCommandAdmissionInnerV1 {
    state: Option<WorkspaceCommandAdmissionStateV1>,
    catalog_binding: Option<WorkspaceCommandAdmissionCatalogBindingV1>,
    claims: BTreeMap<String, WorkspaceCommandExecutionClaimStateV1>,
    reservations: BTreeMap<u64, WorkspaceCommandAdmissionFinalizationV1>,
    next_claim_generation: u64,
    next_reservation_id: u64,
    authority_publication_reservation: Option<WorkspaceAuthorityPublicationReservationV1>,
    authority_snapshot: Arc<WorkspaceProjectionSnapshot>,
    authority_publication: WorkspaceProjectionPublicationState,
    authority_projection_digest: String,
    quarantined: bool,
    closed: bool,
}

fn apply_workspace_authority_publication_candidate_v1(
    inner: &mut WorkspaceCommandAdmissionInnerV1,
    admission: &WorkspaceCommandAdmissionStateV1,
    candidate: &WorkspaceAuthorityPublicationCandidateV1,
    expected_head: Option<&WorkspaceAuthorityPublicationHeadV1>,
) -> Result<WorkspaceAuthorityPublicationReceiptV1, WorkspaceWorkingJournalError> {
    if inner.closed || inner.quarantined {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    match expected_head {
        Some(expected) if workspace_authority_publication_head_v1(inner) != *expected => {
            return Err(WorkspaceWorkingJournalError::StaleRecoverySnapshot);
        }
        None if inner.authority_publication_reservation.is_some() => {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        Some(_) | None => {}
    }
    validate_workspace_authority_publication_head_v1(inner, candidate)?;
    if let Some(operation_id) = &candidate.operation_id {
        admission
            .global
            .get(operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidOperationLedger)?;
    }
    let previous_generation = inner.authority_snapshot.generation;
    let previous_catalog_revision = inner.authority_publication.catalog_revision;
    let previous_publication_sequence = inner.authority_publication.publication_sequence;
    if candidate.draft.catalog_revision < previous_catalog_revision {
        return Err(WorkspaceWorkingJournalError::StaleRecoverySnapshot);
    }
    let publication_sequence = previous_publication_sequence
        .checked_add(1)
        .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
    let projection_changed = inner.authority_snapshot.entries != candidate.entries;
    let generation = if projection_changed {
        previous_generation
            .checked_add(1)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?
    } else {
        previous_generation
    };
    let snapshot = Arc::new(WorkspaceProjectionSnapshot {
        generation,
        retained_bytes: candidate.retained_bytes,
        entries: candidate.entries.clone(),
    });
    let event = WorkspaceProjectionPublicationEvent {
        sequence: publication_sequence,
        catalog_revision: candidate.draft.catalog_revision,
        kind: candidate.draft.kind,
        workspace_id: candidate.workspace_id.clone(),
        context_id: candidate.context_id.clone(),
        operation_id: candidate.operation_id.clone(),
        revisions: candidate.draft.revisions,
    };
    let mut publication = inner.authority_publication.clone();
    publication.catalog_revision = event.catalog_revision;
    publication.publication_sequence = event.sequence;
    publication.events.push_back(event.clone());
    while publication.events.len() > MAXIMUM_WORKSPACE_PROJECTION_PUBLICATION_EVENT_COUNT {
        publication.events.pop_front();
    }
    publication.event_log_floor_sequence = publication
        .events
        .front()
        .map(|event| event.sequence)
        .unwrap_or_else(|| publication.publication_sequence.saturating_add(1));

    inner.authority_snapshot = snapshot;
    inner.authority_publication = publication;
    inner.authority_projection_digest = candidate.projection_digest.clone();
    Ok(WorkspaceAuthorityPublicationReceiptV1 {
        previous_generation,
        generation,
        projection_changed,
        workspace_count: inner.authority_snapshot.entries.len(),
        retained_bytes: inner.authority_snapshot.retained_bytes,
        previous_catalog_revision,
        previous_publication_sequence,
        catalog_revision: inner.authority_publication.catalog_revision,
        publication_sequence: inner.authority_publication.publication_sequence,
        event_log_floor_sequence: inner.authority_publication.event_log_floor_sequence,
        event_log_count: inner.authority_publication.events.len(),
        projection_digest: candidate.projection_digest.clone(),
        event,
    })
}

#[derive(Debug)]
pub struct WorkspaceCommandExecutionClaimV1 {
    inner: Arc<Mutex<WorkspaceCommandAdmissionInnerV1>>,
    workspace_id: String,
    operation_id: String,
    fingerprint: String,
    generation: u64,
}

impl WorkspaceCommandExecutionClaimV1 {
    pub fn workspace_id(&self) -> &str {
        &self.workspace_id
    }

    pub fn operation_id(&self) -> &str {
        &self.operation_id
    }

    pub fn fingerprint(&self) -> &str {
        &self.fingerprint
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn validate_transient(
        &self,
        mut operation: WorkspaceRecordedOperationV1,
    ) -> Result<WorkspaceRecordedOperationV1, WorkspaceWorkingJournalError> {
        validate_and_canonicalize_recorded_operation(&mut operation)?;
        if operation.operation_id != self.operation_id || operation.fingerprint != self.fingerprint
        {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }
        let inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let current = inner
            .claims
            .get(&self.operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        if current.workspace_id != self.workspace_id
            || current.fingerprint != self.fingerprint
            || current.generation != self.generation
            || current.reservation_id.is_some()
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut projected = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        for effect in inner.reservations.values() {
            effect.apply_reservation_projection(&mut projected)?;
        }
        projected.insert(None, operation.clone())?;
        Ok(operation)
    }

    pub fn finalize_transient(
        &self,
        operation: WorkspaceRecordedOperationV1,
    ) -> Result<WorkspaceRecordedOperationV1, WorkspaceWorkingJournalError> {
        let operation = self.validate_transient(operation)?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let current = inner
            .claims
            .get(&self.operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        if current.workspace_id != self.workspace_id
            || current.fingerprint != self.fingerprint
            || current.generation != self.generation
            || current.reservation_id.is_some()
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut projected = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        for effect in inner.reservations.values() {
            effect.apply_reservation_projection(&mut projected)?;
        }
        projected.insert(None, operation.clone())?;
        let state = inner
            .state
            .as_mut()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        state.insert(None, operation.clone())?;
        inner.claims.remove(&self.operation_id);
        Ok(operation)
    }

    pub fn reconciled_terminal(
        &self,
    ) -> Result<Option<WorkspaceRecordedOperationV1>, WorkspaceWorkingJournalError> {
        let inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.claims.get(&self.operation_id).is_some_and(|current| {
            current.workspace_id == self.workspace_id
                && current.fingerprint == self.fingerprint
                && current.generation == self.generation
        }) {
            return Ok(None);
        }
        let state = inner
            .state
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        match state.decision(&self.workspace_id, &self.operation_id, &self.fingerprint) {
            WorkspaceCommandAdmissionDecisionV1::Replay { operation, .. } => Ok(Some(operation)),
            WorkspaceCommandAdmissionDecisionV1::Collision { .. } => {
                Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
            }
            WorkspaceCommandAdmissionDecisionV1::Unseen => Ok(None),
        }
    }

    pub fn abandon(&self) -> Result<bool, WorkspaceWorkingJournalError> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        let Some(current) = inner.claims.get(&self.operation_id) else {
            return Ok(false);
        };
        if current.workspace_id != self.workspace_id
            || current.fingerprint != self.fingerprint
            || current.generation != self.generation
        {
            return Ok(false);
        }
        if current.reservation_id.is_some() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        inner.claims.remove(&self.operation_id);
        if inner.closed && inner.claims.is_empty() && inner.reservations.is_empty() {
            inner.state.take();
        }
        Ok(true)
    }
}

#[derive(Debug)]
pub struct WorkspaceCommandAdmissionReservationV1 {
    inner: Arc<Mutex<WorkspaceCommandAdmissionInnerV1>>,
    reservation_id: u64,
    claim: Option<(String, u64)>,
    active: bool,
}

impl WorkspaceCommandAdmissionReservationV1 {
    pub fn finalize(
        &mut self,
    ) -> Result<WorkspaceCommandAdmissionDiagnosticsV1, WorkspaceWorkingJournalError> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        let effect = inner
            .reservations
            .get(&self.reservation_id)
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner
            .authority_publication_reservation
            .as_ref()
            .is_some_and(|reservation| reservation.reservation_id == self.reservation_id)
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        if let Some((operation_id, generation)) = &self.claim {
            let current = inner
                .claims
                .get(operation_id)
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
            if current.generation != *generation
                || current.reservation_id != Some(self.reservation_id)
            {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        }
        let mut replacement = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        effect.apply(&mut replacement)?;
        let diagnostics = replacement.diagnostics();
        inner.state = Some(replacement);
        inner.reservations.remove(&self.reservation_id);
        if let Some((operation_id, _)) = &self.claim {
            inner.claims.remove(operation_id);
        }
        self.active = false;
        if inner.closed && inner.claims.is_empty() && inner.reservations.is_empty() {
            inner.state.take();
        }
        Ok(diagnostics)
    }

    pub fn finalize_with_authority(
        &mut self,
        publication: &PreparedWorkspaceAuthorityPublicationV1,
    ) -> Result<
        (
            WorkspaceCommandAdmissionDiagnosticsV1,
            WorkspaceAuthorityPublicationReceiptV1,
        ),
        WorkspaceWorkingJournalError,
    > {
        self.finalize_with_authority_effect(publication, None)
    }

    pub fn finalize_delete_with_authority(
        &mut self,
        publication: &PreparedWorkspaceAuthorityPublicationV1,
        replacement_operation: WorkspaceRecordedOperationV1,
    ) -> Result<
        (
            WorkspaceCommandAdmissionDiagnosticsV1,
            WorkspaceAuthorityPublicationReceiptV1,
        ),
        WorkspaceWorkingJournalError,
    > {
        self.finalize_with_authority_effect(publication, Some(replacement_operation))
    }

    fn finalize_with_authority_effect(
        &mut self,
        publication: &PreparedWorkspaceAuthorityPublicationV1,
        replacement_delete_operation: Option<WorkspaceRecordedOperationV1>,
    ) -> Result<
        (
            WorkspaceCommandAdmissionDiagnosticsV1,
            WorkspaceAuthorityPublicationReceiptV1,
        ),
        WorkspaceWorkingJournalError,
    > {
        if !Arc::ptr_eq(&self.inner, &publication.inner) {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        let effect = inner
            .reservations
            .get(&self.reservation_id)
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        let effect = match (effect, replacement_delete_operation) {
            (
                WorkspaceCommandAdmissionFinalizationV1::Delete {
                    workspace_id,
                    operation: mut expected_operation,
                },
                Some(mut replacement_operation),
            ) => {
                validate_and_canonicalize_recorded_operation(&mut expected_operation)?;
                validate_and_canonicalize_recorded_operation(&mut replacement_operation)?;
                let replacement_diagnostic = replacement_operation.diagnostic.clone();
                let mut normalized_replacement = replacement_operation.clone();
                normalized_replacement.diagnostic = expected_operation.diagnostic.clone();
                if normalized_replacement != expected_operation
                    || !deletion_diagnostic_matches(
                        &replacement_diagnostic,
                        &expected_operation.diagnostic,
                    )
                {
                    return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
                }
                WorkspaceCommandAdmissionFinalizationV1::Delete {
                    workspace_id,
                    operation: replacement_operation,
                }
            }
            (effect, None) => effect,
            (_, Some(_)) => return Err(WorkspaceWorkingJournalError::InvalidTransaction),
        };
        let (operation_id, generation) = self
            .claim
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        let current = inner
            .claims
            .get(operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        if !publication.active.load(Ordering::Acquire)
            || current.generation != *generation
            || current.reservation_id != Some(self.reservation_id)
            || publication.reservation.reservation_id != self.reservation_id
            || publication.reservation.operation_id != *operation_id
            || publication.reservation.workspace_id != current.workspace_id
            || publication.reservation.fingerprint != current.fingerprint
            || publication.reservation.claim_generation != current.generation
            || inner.authority_publication_reservation.as_ref() != Some(&publication.reservation)
            || publication.candidate.operation_id.as_deref() != Some(operation_id.as_str())
            || publication.candidate.workspace_id.as_deref() != Some(current.workspace_id.as_str())
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut replacement = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        effect.apply(&mut replacement)?;
        let diagnostics = replacement.diagnostics();
        let receipt = apply_workspace_authority_publication_candidate_v1(
            &mut inner,
            &replacement,
            &publication.candidate,
            Some(&publication.reservation.head),
        )?;
        inner.state = Some(replacement);
        inner.reservations.remove(&self.reservation_id);
        inner.claims.remove(operation_id);
        inner.authority_publication_reservation = None;
        publication.active.store(false, Ordering::Release);
        self.active = false;
        if inner.closed && inner.claims.is_empty() && inner.reservations.is_empty() {
            inner.state.take();
        }
        Ok((diagnostics, receipt))
    }

    pub fn cancel(mut self) {
        self.cancel_inner();
    }

    fn cancel_inner(&mut self) {
        if !self.active {
            return;
        }
        if let Ok(mut inner) = self.inner.lock() {
            inner.reservations.remove(&self.reservation_id);
            if let Some((operation_id, generation)) = &self.claim {
                if let Some(current) = inner.claims.get_mut(operation_id) {
                    if current.generation == *generation
                        && current.reservation_id == Some(self.reservation_id)
                    {
                        current.reservation_id = None;
                    }
                }
            }
            if inner.closed && inner.claims.is_empty() && inner.reservations.is_empty() {
                inner.state.take();
            }
        }
        self.active = false;
    }
}

impl Drop for WorkspaceCommandAdmissionReservationV1 {
    fn drop(&mut self) {
        self.cancel_inner();
    }
}

impl Drop for PreparedWorkspaceAuthorityPublicationV1 {
    fn drop(&mut self) {
        if !self.active.swap(false, Ordering::AcqRel) {
            return;
        }
        if let Ok(mut inner) = self.inner.lock()
            && inner.authority_publication_reservation.as_ref() == Some(&self.reservation)
        {
            inner.authority_publication_reservation = None;
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WorkspaceCommandAdmissionCatalogBindingV1 {
    revision: u64,
    digest: String,
    entries: BTreeMap<String, String>,
    deletions: BTreeMap<String, Vec<u8>>,
}

impl WorkspaceCommandAdmissionCatalogBindingV1 {
    fn relationships_match_except(&self, other: &Self, target_workspace_id: &str) -> bool {
        let mut current_entries = self.entries.clone();
        let mut next_entries = other.entries.clone();
        let mut current_deletions = self.deletions.clone();
        let mut next_deletions = other.deletions.clone();
        current_entries.remove(target_workspace_id);
        next_entries.remove(target_workspace_id);
        current_deletions.remove(target_workspace_id);
        next_deletions.remove(target_workspace_id);
        current_entries == next_entries && current_deletions == next_deletions
    }
}

fn checked_recovery_bytes<'a>(
    catalog_bytes: &'a [u8],
    artifacts: impl Iterator<Item = Option<&'a [u8]>>,
) -> Result<(), WorkspaceWorkingJournalError> {
    let mut total = catalog_bytes.len();
    for bytes in artifacts.flatten() {
        total =
            total
                .checked_add(bytes.len())
                .ok_or(WorkspaceWorkingJournalError::InputTooLarge {
                    actual: usize::MAX,
                    maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_BYTES_V1,
                })?;
        if total > MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_BYTES_V1 {
            return Err(WorkspaceWorkingJournalError::InputTooLarge {
                actual: total,
                maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_BYTES_V1,
            });
        }
    }
    Ok(())
}

fn validated_recovery_catalog(
    bytes: &[u8],
) -> Result<
    (
        WorkspaceCatalogValidationV1,
        WorkspaceCatalogV1,
        WorkspaceCommandAdmissionCatalogBindingV1,
    ),
    WorkspaceWorkingJournalError,
> {
    let validation = validate_workspace_catalog_v1(bytes)?;
    let catalog: WorkspaceCatalogV1 = serde_json::from_slice(&validation.canonical_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let entries = catalog
        .entries
        .iter()
        .map(|entry| (entry.workspace_id.clone(), entry.file_url.clone()))
        .collect::<BTreeMap<_, _>>();
    let deletions = catalog
        .deletions
        .as_deref()
        .unwrap_or_default()
        .iter()
        .map(|tombstone| {
            serde_json::to_vec(tombstone)
                .map(|identity| (tombstone.workspace_id.clone(), identity))
                .map_err(|_| WorkspaceWorkingJournalError::Malformed)
        })
        .collect::<Result<BTreeMap<_, _>, _>>()?;
    let binding = WorkspaceCommandAdmissionCatalogBindingV1 {
        revision: validation.revision,
        digest: validation.content_digest.clone(),
        entries,
        deletions,
    };
    Ok((validation, catalog, binding))
}

fn recovered_journal_records(
    workspace_id: &str,
    expected_file_url: &str,
    bytes: Option<&[u8]>,
) -> Result<Vec<WorkspaceCommandAdmissionRecoveredRecordV1>, WorkspaceWorkingJournalError> {
    let Some(bytes) = bytes else {
        return Ok(Vec::new());
    };
    let validation = validate_workspace_working_journal_v1(bytes)?;
    let journal: WorkspaceWorkingJournalV1 = serde_json::from_slice(&validation.canonical_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if journal.workspace_id != workspace_id {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    if journal.file_url != expected_file_url {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    Ok(journal
        .operations
        .into_iter()
        .map(|operation| WorkspaceCommandAdmissionRecoveredRecordV1 {
            workspace_id: Some(workspace_id.to_owned()),
            operation,
        })
        .collect())
}

fn deletion_diagnostic_matches(candidate: &Option<String>, authoritative: &Option<String>) -> bool {
    if candidate == authoritative {
        return true;
    }
    candidate.as_deref().is_some_and(|value| {
        const PREFIX: &str = "artifact_cleanup_incomplete: ";
        value.starts_with(PREFIX) && value.len() > PREFIX.len()
    })
}

fn recovered_deletion_record(
    authoritative: &WorkspaceDeletionTombstoneV1,
    sidecar_bytes: Option<&[u8]>,
) -> Result<WorkspaceCommandAdmissionRecoveredRecordV1, WorkspaceWorkingJournalError> {
    let operation = if let Some(sidecar_bytes) = sidecar_bytes {
        let validation = validate_workspace_deletion_tombstone_v1(sidecar_bytes)?;
        let sidecar: WorkspaceDeletionTombstoneV1 =
            serde_json::from_slice(&validation.canonical_bytes)
                .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
        let mut normalized_sidecar = sidecar.clone();
        let diagnostic = normalized_sidecar.operation.diagnostic.clone();
        normalized_sidecar.operation.diagnostic = authoritative.operation.diagnostic.clone();
        if normalized_sidecar.version != authoritative.version
            || normalized_sidecar.workspace_id != authoritative.workspace_id
            || normalized_sidecar.file_url != authoritative.file_url
            || normalized_sidecar.deleted_at != authoritative.deleted_at
            || normalized_sidecar.operation != authoritative.operation
            || !deletion_diagnostic_matches(&diagnostic, &authoritative.operation.diagnostic)
        {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }
        sidecar.operation
    } else {
        authoritative.operation.clone()
    };
    Ok(WorkspaceCommandAdmissionRecoveredRecordV1 {
        workspace_id: None,
        operation,
    })
}

fn derive_full_recovery(
    recovery: &WorkspaceCommandAdmissionRecoveryV1,
) -> Result<
    (
        WorkspaceCommandAdmissionStateV1,
        WorkspaceCommandAdmissionCatalogBindingV1,
    ),
    WorkspaceWorkingJournalError,
> {
    if recovery.journals.len() > MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1
        || recovery.deletion_sidecars.len()
            > MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1
    {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: recovery
                .journals
                .len()
                .max(recovery.deletion_sidecars.len()),
            maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1,
        });
    }
    checked_recovery_bytes(
        &recovery.catalog_bytes,
        recovery
            .journals
            .iter()
            .map(|artifact| artifact.canonical_bytes.as_deref())
            .chain(
                recovery
                    .deletion_sidecars
                    .iter()
                    .map(|artifact| artifact.canonical_bytes.as_deref()),
            ),
    )?;
    let (_, catalog, binding) = validated_recovery_catalog(&recovery.catalog_bytes)?;
    let mut journals = BTreeMap::new();
    for artifact in &recovery.journals {
        let workspace_id = canonical_uuid(&artifact.workspace_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        if journals
            .insert(workspace_id, artifact.canonical_bytes.as_deref())
            .is_some()
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
    }
    let mut sidecars = BTreeMap::new();
    for artifact in &recovery.deletion_sidecars {
        let workspace_id = canonical_uuid(&artifact.workspace_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        if sidecars
            .insert(workspace_id, artifact.canonical_bytes.as_deref())
            .is_some()
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
    }
    if journals.keys().ne(binding.entries.keys()) || sidecars.keys().ne(binding.deletions.keys()) {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    let mut records = Vec::new();
    for entry in &catalog.entries {
        records.extend(recovered_journal_records(
            &entry.workspace_id,
            &entry.file_url,
            journals.get(&entry.workspace_id).copied().flatten(),
        )?);
    }
    for deletion in catalog.deletions.as_deref().unwrap_or_default() {
        records.push(recovered_deletion_record(
            deletion,
            sidecars.get(&deletion.workspace_id).copied().flatten(),
        )?);
    }
    Ok((
        WorkspaceCommandAdmissionStateV1::from_records(&records)?,
        binding,
    ))
}

fn derive_target_recovery(
    recovery: &WorkspaceCommandAdmissionTargetRecoveryV1,
) -> Result<
    (
        Vec<WorkspaceCommandAdmissionRecoveredRecordV1>,
        WorkspaceCommandAdmissionCatalogBindingV1,
        String,
        bool,
    ),
    WorkspaceWorkingJournalError,
> {
    checked_recovery_bytes(
        &recovery.catalog_bytes,
        [
            recovery.journal_bytes.as_deref(),
            recovery.deletion_sidecar_bytes.as_deref(),
        ]
        .into_iter(),
    )?;
    let (_, catalog, binding) = validated_recovery_catalog(&recovery.catalog_bytes)?;
    let workspace_id = canonical_uuid(&recovery.workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    if let Some(entry) = catalog
        .entries
        .iter()
        .find(|entry| entry.workspace_id == workspace_id)
    {
        if recovery.deletion_sidecar_bytes.is_some() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        return Ok((
            recovered_journal_records(
                &workspace_id,
                &entry.file_url,
                recovery.journal_bytes.as_deref(),
            )?,
            binding,
            workspace_id,
            false,
        ));
    }
    if let Some(deletion) = catalog
        .deletions
        .as_deref()
        .unwrap_or_default()
        .iter()
        .find(|deletion| deletion.workspace_id == workspace_id)
    {
        if recovery.journal_bytes.is_some() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        return Ok((
            vec![recovered_deletion_record(
                deletion,
                recovery.deletion_sidecar_bytes.as_deref(),
            )?],
            binding,
            workspace_id,
            true,
        ));
    }
    Err(WorkspaceWorkingJournalError::FullRecoveryRequired)
}

#[derive(Clone, Debug)]
struct WorkspaceRecoveredDocumentV1 {
    bytes: Vec<u8>,
    digest: String,
    projection: WorkspaceDocumentProjection,
}

fn workspace_recovery_document_v1(
    evidence: &WorkspaceRecoveryArtifactEvidenceV1,
    expected_workspace_id: &str,
) -> Result<Result<WorkspaceRecoveredDocumentV1, String>, WorkspaceWorkingJournalError> {
    match evidence {
        WorkspaceRecoveryArtifactEvidenceV1::Absent => {
            Ok(Err("workspace_document_unavailable".to_owned()))
        }
        WorkspaceRecoveryArtifactEvidenceV1::Unavailable(reason) => Ok(Err(if reason.is_empty() {
            "workspace_document_unavailable".to_owned()
        } else {
            reason.clone()
        })),
        WorkspaceRecoveryArtifactEvidenceV1::Present(bytes) => {
            if bytes.len() > MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1 {
                return Err(WorkspaceWorkingJournalError::InputTooLarge {
                    actual: bytes.len(),
                    maximum: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
                });
            }
            let projection = match project_workspace_document_v1(bytes) {
                Ok(projection) if projection.workspace_id == expected_workspace_id => projection,
                Ok(_) => return Ok(Err("workspace_document_identity_mismatch".to_owned())),
                Err(_) => return Ok(Err("workspace_document_decode_failed".to_owned())),
            };
            Ok(Ok(WorkspaceRecoveredDocumentV1 {
                bytes: bytes.clone(),
                digest: format!("{:x}", Sha256::digest(bytes)),
                projection,
            }))
        }
    }
}

fn workspace_recovery_health_v1(
    kind: WorkspaceProjectionHealthKind,
    reason: Option<String>,
) -> WorkspaceProjectionHealth {
    WorkspaceProjectionHealth { kind, reason }
}

fn workspace_recovery_context_revisions_v1(
    value: &Value,
) -> Result<Vec<WorkspaceSemanticContextRecoveryV1>, WorkspaceWorkingJournalError> {
    let Value::Array(items) = value else {
        return Err(WorkspaceWorkingJournalError::InvalidContextTable);
    };
    if items.len() % 2 != 0 {
        return Err(WorkspaceWorkingJournalError::InvalidContextTable);
    }
    items
        .chunks_exact(2)
        .map(|pair| {
            let context_id = pair[0]
                .as_str()
                .and_then(canonical_uuid)
                .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?;
            let revisions =
                serde_json::from_value::<WorkspaceProjectionRevisionState>(pair[1].clone())
                    .map_err(|_| WorkspaceWorkingJournalError::InvalidContextTable)?;
            if !is_valid_revision_state(revisions) {
                return Err(WorkspaceWorkingJournalError::InvalidContextTable);
            }
            Ok(WorkspaceSemanticContextRecoveryV1 {
                context_id,
                revisions,
            })
        })
        .collect()
}

fn workspace_recovery_context_tombstones_v1(
    value: &Value,
) -> Result<Vec<(String, u64)>, WorkspaceWorkingJournalError> {
    let Value::Array(items) = value else {
        return Err(WorkspaceWorkingJournalError::InvalidContextTable);
    };
    if items.len() % 2 != 0 {
        return Err(WorkspaceWorkingJournalError::InvalidContextTable);
    }
    items
        .chunks_exact(2)
        .map(|pair| {
            Ok((
                pair[0]
                    .as_str()
                    .and_then(canonical_uuid)
                    .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?,
                pair[1]
                    .as_u64()
                    .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?,
            ))
        })
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum WorkspaceRecoverySavedRevisionV1 {
    Confirmed(u64),
    Degraded(String),
}

fn workspace_recovery_saved_revision_v1(
    evidence: &WorkspaceRecoveryArtifactEvidenceV1,
    workspace_id: &str,
    document_digest: &str,
) -> WorkspaceRecoverySavedRevisionV1 {
    let bytes = match evidence {
        WorkspaceRecoveryArtifactEvidenceV1::Absent => {
            return WorkspaceRecoverySavedRevisionV1::Confirmed(0);
        }
        WorkspaceRecoveryArtifactEvidenceV1::Unavailable(reason) => {
            return WorkspaceRecoverySavedRevisionV1::Degraded(if reason.is_empty() {
                "saved_revision_read_failed".to_owned()
            } else {
                reason.clone()
            });
        }
        WorkspaceRecoveryArtifactEvidenceV1::Present(bytes) => bytes,
    };
    let Ok(validation) = validate_workspace_saved_revision_record_v1(bytes) else {
        return WorkspaceRecoverySavedRevisionV1::Degraded(
            "saved_revision_decode_failed".to_owned(),
        );
    };
    let Ok(record) =
        serde_json::from_slice::<WorkspaceSavedRevisionRecordV1>(&validation.canonical_bytes)
    else {
        return WorkspaceRecoverySavedRevisionV1::Degraded(
            "saved_revision_decode_failed".to_owned(),
        );
    };
    if record.workspace_id != workspace_id {
        WorkspaceRecoverySavedRevisionV1::Degraded("saved_revision_identity_mismatch".to_owned())
    } else if record.document_digest != document_digest {
        WorkspaceRecoverySavedRevisionV1::Degraded("saved_revision_digest_mismatch".to_owned())
    } else {
        WorkspaceRecoverySavedRevisionV1::Confirmed(record.saved_revision)
    }
}

fn workspace_recovery_initial_contexts_v1(
    projection: &WorkspaceDocumentProjection,
    revisions: WorkspaceProjectionRevisionState,
) -> Vec<WorkspaceSemanticContextRecoveryV1> {
    projection
        .contexts
        .iter()
        .map(|context| WorkspaceSemanticContextRecoveryV1 {
            context_id: context.context_id.clone(),
            revisions,
        })
        .collect()
}

fn workspace_recovery_active_row_v1(
    workspace_id: &str,
    file_url: &str,
    document: WorkspaceRecoveredDocumentV1,
    saved_digest: String,
    revisions: WorkspaceProjectionRevisionState,
    context_revisions: Vec<WorkspaceSemanticContextRecoveryV1>,
    context_tombstones: Vec<(String, u64)>,
    operations: Vec<WorkspaceRecordedOperationV1>,
    health: WorkspaceProjectionHealth,
    external_document_bytes: Option<Vec<u8>>,
) -> WorkspaceSemanticActiveRecoveryV1 {
    WorkspaceSemanticActiveRecoveryV1 {
        workspace_id: workspace_id.to_owned(),
        file_url: file_url.to_owned(),
        document_bytes: document.bytes,
        document_digest: document.digest,
        saved_digest,
        revisions,
        context_revisions,
        context_tombstones,
        operations,
        health,
        external_document_bytes,
    }
}

fn workspace_recovery_journal_reason_v1(error: &WorkspaceWorkingJournalError) -> String {
    match error {
        WorkspaceWorkingJournalError::FutureSchema(_) => "future_working_journal".to_owned(),
        WorkspaceWorkingJournalError::InputTooLarge { .. }
        | WorkspaceWorkingJournalError::OutputTooLarge { .. } => {
            "working_journal_too_large".to_owned()
        }
        WorkspaceWorkingJournalError::InvalidIdentity
        | WorkspaceWorkingJournalError::InvalidFileUrl => {
            "working_journal_identity_mismatch".to_owned()
        }
        _ => "working_journal_decode_failed".to_owned(),
    }
}

fn workspace_recovery_fallback_row_v1(
    workspace_id: &str,
    file_url: &str,
    saved_document: Result<WorkspaceRecoveredDocumentV1, String>,
    reason: String,
    journal: Option<&WorkspaceWorkingJournalV1>,
) -> WorkspaceSemanticRecoveryRowV1 {
    match saved_document {
        Ok(document) => {
            let saved_digest = journal
                .map(|journal| journal.saved_digest.clone())
                .unwrap_or_else(|| document.digest.clone());
            let saved_revision = journal
                .map(|journal| journal.revisions.saved_revision)
                .unwrap_or(0);
            let revisions = WorkspaceProjectionRevisionState {
                working_revision: saved_revision,
                saved_revision,
                dirty_revision: None,
            };
            let context_revisions =
                workspace_recovery_initial_contexts_v1(&document.projection, revisions);
            WorkspaceSemanticRecoveryRowV1::Active {
                row: workspace_recovery_active_row_v1(
                    workspace_id,
                    file_url,
                    document,
                    saved_digest,
                    revisions,
                    context_revisions,
                    journal
                        .and_then(|journal| {
                            workspace_recovery_context_tombstones_v1(&journal.context_tombstones)
                                .ok()
                        })
                        .unwrap_or_default(),
                    journal
                        .map(|journal| journal.operations.clone())
                        .unwrap_or_default(),
                    workspace_recovery_health_v1(
                        WorkspaceProjectionHealthKind::DegradedReadOnly,
                        Some(reason),
                    ),
                    None,
                ),
            }
        }
        Err(document_reason) => WorkspaceSemanticRecoveryRowV1::Unavailable {
            row: WorkspaceSemanticUnavailableRecoveryV1 {
                workspace_id: workspace_id.to_owned(),
                file_url: file_url.to_owned(),
                reason: if document_reason.is_empty() {
                    reason
                } else {
                    document_reason
                },
            },
        },
    }
}

fn workspace_recovery_document_context_digests_v1(
    document: &WorkspaceRecoveredDocumentV1,
) -> Result<BTreeMap<String, String>, WorkspaceWorkingJournalError> {
    let value: Value = serde_json::from_slice(&document.bytes)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
    let raw_contexts = value
        .as_object()
        .and_then(|object| object.get("composeTabs"))
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let mut digests = BTreeMap::new();
    for raw_context in raw_contexts {
        let context_id = raw_context
            .as_object()
            .and_then(|context| context.get("id"))
            .and_then(Value::as_str)
            .and_then(canonical_uuid)
            .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?;
        let canonical_bytes =
            serde_json::to_vec(raw_context).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
        if digests
            .insert(context_id, format!("{:x}", Sha256::digest(canonical_bytes)))
            .is_some()
        {
            return Err(WorkspaceWorkingJournalError::InvalidContextTable);
        }
    }
    Ok(digests)
}

fn workspace_recovery_context_digest_table_v1(
    value: &Value,
) -> Result<BTreeMap<String, String>, WorkspaceWorkingJournalError> {
    let (_, canonical) = normalize_uuid_dictionary(value, |candidate| {
        candidate.as_str().is_some_and(is_sha256_digest)
    })?;
    let pairs = canonical
        .as_array()
        .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?;
    pairs
        .chunks_exact(2)
        .map(|pair| {
            Ok((
                pair[0]
                    .as_str()
                    .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?
                    .to_owned(),
                pair[1]
                    .as_str()
                    .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?
                    .to_owned(),
            ))
        })
        .collect()
}

fn workspace_recovery_context_revisions_value_v1(
    revisions: &BTreeMap<String, WorkspaceProjectionRevisionState>,
) -> Result<Value, WorkspaceWorkingJournalError> {
    let mut pairs = Vec::with_capacity(revisions.len() * 2);
    for (context_id, revision) in revisions {
        pairs.push(Value::String(context_id.clone()));
        pairs.push(
            serde_json::to_value(revision).map_err(|_| WorkspaceWorkingJournalError::Malformed)?,
        );
    }
    Ok(Value::Array(pairs))
}

fn workspace_recovery_context_digests_value_v1(digests: &BTreeMap<String, String>) -> Value {
    let mut pairs = Vec::with_capacity(digests.len() * 2);
    for (context_id, digest) in digests {
        pairs.push(Value::String(context_id.clone()));
        pairs.push(Value::String(digest.clone()));
    }
    Value::Array(pairs)
}

fn workspace_recovery_context_tombstones_value_v1(tombstones: &BTreeMap<String, u64>) -> Value {
    let mut pairs = Vec::with_capacity(tombstones.len() * 2);
    for (context_id, revision) in tombstones {
        pairs.push(Value::String(context_id.clone()));
        pairs.push(Value::from(*revision));
    }
    Value::Array(pairs)
}

fn workspace_recovery_clean_external_reload_v1(
    raw_journal_bytes: &[u8],
    canonical_journal_bytes: &[u8],
    journal: &WorkspaceWorkingJournalV1,
    saved_document: &WorkspaceRecoveredDocumentV1,
) -> Result<
    (
        WorkspaceWorkingJournalV1,
        Vec<u8>,
        WorkspaceSemanticJournalRewriteV1,
    ),
    WorkspaceWorkingJournalError,
> {
    let request = WorkspaceWorkingJournalTransitionRequestV1::ExternalReload {
        expected_working_revision: journal.revisions.working_revision,
        operation_id: None,
        fingerprint: None,
        updated_at: journal.updated_at.clone(),
    };
    let request_bytes =
        serde_json::to_vec(&request).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let plan = plan_workspace_working_journal_transition_v1(
        Some(canonical_journal_bytes),
        &request_bytes,
        Some(&saved_document.bytes),
        None,
    )?;
    let replacement_bytes = plan.primary.canonical_bytes.clone();
    let replacement = parse_validated_journal(&replacement_bytes)?;
    Ok((
        replacement,
        replacement_bytes.clone(),
        WorkspaceSemanticJournalRewriteV1 {
            workspace_id: journal.workspace_id.clone(),
            expected_artifact_digest: format!("{:x}", Sha256::digest(raw_journal_bytes)),
            replacement_canonical_bytes: replacement_bytes,
            replacement_canonical_digest: plan.primary.content_digest,
        },
    ))
}

fn derive_workspace_semantic_recovery_row_v1(
    workspace_id: &str,
    file_url: &str,
    evidence: &WorkspaceSemanticRecoveryEvidenceV1,
) -> Result<
    (
        WorkspaceSemanticRecoveryRowV1,
        Option<Vec<u8>>,
        Option<WorkspaceSemanticJournalRewriteV1>,
        bool,
    ),
    WorkspaceWorkingJournalError,
> {
    let saved_document = workspace_recovery_document_v1(&evidence.saved_document, workspace_id)?;
    match &evidence.journal {
        WorkspaceRecoveryArtifactEvidenceV1::Absent => match saved_document {
            Ok(document) => {
                let saved_revision = workspace_recovery_saved_revision_v1(
                    &evidence.saved_revision,
                    workspace_id,
                    &document.digest,
                );
                let (saved_revision, health) = match saved_revision {
                    WorkspaceRecoverySavedRevisionV1::Confirmed(revision) => (
                        revision,
                        workspace_recovery_health_v1(WorkspaceProjectionHealthKind::Writable, None),
                    ),
                    WorkspaceRecoverySavedRevisionV1::Degraded(reason) => (
                        0,
                        workspace_recovery_health_v1(
                            WorkspaceProjectionHealthKind::DegradedReadOnly,
                            Some(reason),
                        ),
                    ),
                };
                let revisions = WorkspaceProjectionRevisionState {
                    working_revision: saved_revision,
                    saved_revision,
                    dirty_revision: None,
                };
                let context_revisions =
                    workspace_recovery_initial_contexts_v1(&document.projection, revisions);
                let saved_digest = document.digest.clone();
                Ok((
                    WorkspaceSemanticRecoveryRowV1::Active {
                        row: workspace_recovery_active_row_v1(
                            workspace_id,
                            file_url,
                            document,
                            saved_digest,
                            revisions,
                            context_revisions,
                            Vec::new(),
                            Vec::new(),
                            health,
                            None,
                        ),
                    },
                    None,
                    None,
                    true,
                ))
            }
            Err(reason) => Ok((
                WorkspaceSemanticRecoveryRowV1::Unavailable {
                    row: WorkspaceSemanticUnavailableRecoveryV1 {
                        workspace_id: workspace_id.to_owned(),
                        file_url: file_url.to_owned(),
                        reason,
                    },
                },
                None,
                None,
                true,
            )),
        },
        WorkspaceRecoveryArtifactEvidenceV1::Unavailable(reason) => Ok((
            workspace_recovery_fallback_row_v1(
                workspace_id,
                file_url,
                saved_document,
                if reason.is_empty() {
                    "working_journal_decode_failed".to_owned()
                } else {
                    reason.clone()
                },
                None,
            ),
            None,
            None,
            false,
        )),
        WorkspaceRecoveryArtifactEvidenceV1::Present(raw_bytes) => {
            let validation = match validate_workspace_working_journal_v1(raw_bytes) {
                Ok(validation) => validation,
                Err(error) => {
                    return Ok((
                        workspace_recovery_fallback_row_v1(
                            workspace_id,
                            file_url,
                            saved_document,
                            workspace_recovery_journal_reason_v1(&error),
                            None,
                        ),
                        None,
                        None,
                        false,
                    ));
                }
            };
            let mut journal = parse_validated_journal(&validation.canonical_bytes)?;
            if journal.workspace_id != workspace_id || journal.file_url != file_url {
                return Ok((
                    workspace_recovery_fallback_row_v1(
                        workspace_id,
                        file_url,
                        saved_document,
                        "working_journal_identity_mismatch".to_owned(),
                        None,
                    ),
                    None,
                    None,
                    false,
                ));
            }
            let mut journal_bytes = validation.canonical_bytes.clone();
            let mut rewrite = None;
            let working_document = if let Some(encoded) = &journal.working_document {
                match decode_base64(encoded).and_then(|bytes| {
                    project_workspace_document_v1(&bytes)
                        .ok()
                        .filter(|projection| projection.workspace_id == workspace_id)
                        .map(|projection| WorkspaceRecoveredDocumentV1 {
                            digest: format!("{:x}", Sha256::digest(&bytes)),
                            bytes,
                            projection,
                        })
                }) {
                    Some(document) => Some(document),
                    None => {
                        return Ok((
                            workspace_recovery_fallback_row_v1(
                                workspace_id,
                                file_url,
                                saved_document,
                                "working_document_decode_failed".to_owned(),
                                Some(&journal),
                            ),
                            Some(journal_bytes),
                            rewrite,
                            true,
                        ));
                    }
                }
            } else {
                None
            };

            let mut health =
                workspace_recovery_health_v1(WorkspaceProjectionHealthKind::Writable, None);
            let mut external_document_bytes = None;
            let selected_document: WorkspaceRecoveredDocumentV1;

            if let Some(pending) = journal.pending_save.clone() {
                if let Ok(saved) = saved_document.clone()
                    && saved.digest == pending.document_digest
                {
                    match resolve_workspace_pending_save_v1(
                        &validation.canonical_bytes,
                        workspace_id,
                        file_url,
                        Some(&saved.bytes),
                    )? {
                        WorkspacePendingSaveRecoveryV1::Committed { clean_journal, .. } => {
                            rewrite = Some(WorkspaceSemanticJournalRewriteV1 {
                                workspace_id: workspace_id.to_owned(),
                                expected_artifact_digest: format!(
                                    "{:x}",
                                    Sha256::digest(raw_bytes)
                                ),
                                replacement_canonical_bytes: clean_journal.canonical_bytes.clone(),
                                replacement_canonical_digest: clean_journal.content_digest.clone(),
                            });
                            journal_bytes = clean_journal.canonical_bytes;
                            journal = parse_validated_journal(&journal_bytes)?;
                            selected_document = saved;
                        }
                        WorkspacePendingSaveRecoveryV1::NoPending { .. }
                        | WorkspacePendingSaveRecoveryV1::PendingNotCommitted { .. } => {
                            return Err(WorkspaceWorkingJournalError::InvalidPendingSave);
                        }
                    }
                } else {
                    let Some(local_document) = working_document.clone() else {
                        return Ok((
                            workspace_recovery_fallback_row_v1(
                                workspace_id,
                                file_url,
                                saved_document,
                                "working_journal_recovery_failed".to_owned(),
                                Some(&journal),
                            ),
                            Some(journal_bytes),
                            rewrite,
                            true,
                        ));
                    };
                    if local_document.digest != pending.document_digest {
                        health = workspace_recovery_health_v1(
                            WorkspaceProjectionHealthKind::DegradedReadOnly,
                            Some("working_journal_recovery_failed".to_owned()),
                        );
                        selected_document = local_document;
                    } else {
                        match saved_document.clone() {
                            Ok(saved) if saved.digest == pending.document_digest => {
                                match resolve_workspace_pending_save_v1(
                                    &validation.canonical_bytes,
                                    workspace_id,
                                    file_url,
                                    Some(&saved.bytes),
                                )? {
                                    WorkspacePendingSaveRecoveryV1::Committed {
                                        clean_journal,
                                        ..
                                    } => {
                                        rewrite = Some(WorkspaceSemanticJournalRewriteV1 {
                                            workspace_id: workspace_id.to_owned(),
                                            expected_artifact_digest: format!(
                                                "{:x}",
                                                Sha256::digest(raw_bytes)
                                            ),
                                            replacement_canonical_bytes: clean_journal
                                                .canonical_bytes
                                                .clone(),
                                            replacement_canonical_digest: clean_journal
                                                .content_digest
                                                .clone(),
                                        });
                                        journal_bytes = clean_journal.canonical_bytes;
                                        journal = parse_validated_journal(&journal_bytes)?;
                                        selected_document = saved;
                                    }
                                    WorkspacePendingSaveRecoveryV1::NoPending { .. }
                                    | WorkspacePendingSaveRecoveryV1::PendingNotCommitted {
                                        ..
                                    } => {
                                        return Err(
                                            WorkspaceWorkingJournalError::InvalidPendingSave,
                                        );
                                    }
                                }
                            }
                            Ok(saved) if saved.digest == journal.saved_digest => {
                                selected_document = local_document;
                            }
                            Ok(saved) => {
                                journal.saved_digest = saved.digest.clone();
                                health = workspace_recovery_health_v1(
                                    WorkspaceProjectionHealthKind::ExternalConflict,
                                    Some("external_workspace_changed".to_owned()),
                                );
                                external_document_bytes = Some(saved.bytes);
                                selected_document = local_document;
                            }
                            Err(reason) => {
                                health = workspace_recovery_health_v1(
                                    WorkspaceProjectionHealthKind::DegradedReadOnly,
                                    Some(reason),
                                );
                                selected_document = local_document;
                            }
                        }
                    }
                }
            } else if let Some(local_document) = working_document {
                match saved_document.clone() {
                    Ok(saved) if saved.digest != journal.saved_digest => {
                        journal.saved_digest = saved.digest.clone();
                        health = workspace_recovery_health_v1(
                            WorkspaceProjectionHealthKind::ExternalConflict,
                            Some("external_workspace_changed".to_owned()),
                        );
                        external_document_bytes = Some(saved.bytes);
                    }
                    Err(_)
                        if matches!(
                            &evidence.saved_document,
                            WorkspaceRecoveryArtifactEvidenceV1::Absent
                        ) => {}
                    Err(reason) => {
                        health = workspace_recovery_health_v1(
                            WorkspaceProjectionHealthKind::DegradedReadOnly,
                            Some(reason),
                        );
                    }
                    Ok(_) => {}
                }
                selected_document = local_document;
            } else {
                match saved_document.clone() {
                    Ok(saved) if saved.digest == journal.saved_digest => {
                        selected_document = saved;
                    }
                    Ok(saved) => {
                        let (replacement, replacement_bytes, journal_rewrite) =
                            workspace_recovery_clean_external_reload_v1(
                                raw_bytes,
                                &validation.canonical_bytes,
                                &journal,
                                &saved,
                            )?;
                        journal = replacement;
                        journal_bytes = replacement_bytes;
                        rewrite = Some(journal_rewrite);
                        selected_document = saved;
                    }
                    Err(reason) => {
                        return Ok((
                            WorkspaceSemanticRecoveryRowV1::Unavailable {
                                row: WorkspaceSemanticUnavailableRecoveryV1 {
                                    workspace_id: workspace_id.to_owned(),
                                    file_url: file_url.to_owned(),
                                    reason,
                                },
                            },
                            Some(journal_bytes),
                            rewrite,
                            true,
                        ));
                    }
                }
            }
            let document = selected_document;
            let context_revisions =
                workspace_recovery_context_revisions_v1(&journal.context_revisions)?;
            let context_tombstones =
                workspace_recovery_context_tombstones_v1(&journal.context_tombstones)?;
            Ok((
                WorkspaceSemanticRecoveryRowV1::Active {
                    row: workspace_recovery_active_row_v1(
                        workspace_id,
                        file_url,
                        document,
                        journal.saved_digest,
                        journal.revisions,
                        context_revisions,
                        context_tombstones,
                        journal.operations,
                        health,
                        external_document_bytes,
                    ),
                },
                Some(journal_bytes),
                rewrite,
                true,
            ))
        }
    }
}

fn checked_semantic_recovery_bytes_v1<'a>(
    catalog_bytes: &'a [u8],
    evidence: impl Iterator<Item = &'a WorkspaceRecoveryArtifactEvidenceV1>,
) -> Result<(), WorkspaceWorkingJournalError> {
    let mut total = catalog_bytes.len();
    for artifact in evidence {
        if let WorkspaceRecoveryArtifactEvidenceV1::Present(bytes) = artifact {
            total = total.checked_add(bytes.len()).ok_or(
                WorkspaceWorkingJournalError::InputTooLarge {
                    actual: usize::MAX,
                    maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_BYTES_V1,
                },
            )?;
            if total > MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_BYTES_V1 {
                return Err(WorkspaceWorkingJournalError::InputTooLarge {
                    actual: total,
                    maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_BYTES_V1,
                });
            }
        } else if let WorkspaceRecoveryArtifactEvidenceV1::Unavailable(reason) = artifact {
            if reason.is_empty() || reason.len() > 64 * 1024 {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        }
    }
    Ok(())
}

fn semantic_recovery_projection_digest_v1(
    catalog_revision: u64,
    catalog_digest: &str,
    target_workspace_id: Option<&str>,
    global_health: &WorkspaceProjectionHealth,
    admission_disposition: WorkspaceSemanticRecoveryAdmissionDispositionV1,
    projection: &WorkspaceSemanticRecoveryProjectionV1,
    rewrites: &[WorkspaceSemanticJournalRewriteV1],
) -> Result<String, WorkspaceWorkingJournalError> {
    let canonical = serde_json::to_vec(&(
        WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
        catalog_revision,
        catalog_digest,
        target_workspace_id,
        global_health,
        admission_disposition,
        projection,
        rewrites,
    ))
    .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    Ok(format!("{:x}", Sha256::digest(canonical)))
}

fn derive_semantic_full_recovery_v1(
    recovery: &WorkspaceSemanticFullRecoveryV1,
) -> Result<
    (
        WorkspaceSemanticRecoveryPreviewV1,
        Option<WorkspaceCommandAdmissionRecoveryV1>,
    ),
    WorkspaceWorkingJournalError,
> {
    if recovery.workspaces.len() > MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1
        || recovery.deletions.len() > MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1
    {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: recovery.workspaces.len().max(recovery.deletions.len()),
            maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1,
        });
    }
    checked_semantic_recovery_bytes_v1(
        &recovery.catalog_bytes,
        recovery
            .workspaces
            .iter()
            .flat_map(|workspace| {
                [
                    &workspace.journal,
                    &workspace.saved_document,
                    &workspace.saved_revision,
                ]
            })
            .chain(recovery.deletions.iter().map(|deletion| &deletion.sidecar)),
    )?;
    let (_, catalog, binding) = validated_recovery_catalog(&recovery.catalog_bytes)?;
    let mut workspaces = BTreeMap::new();
    for evidence in &recovery.workspaces {
        let workspace_id = canonical_uuid(&evidence.workspace_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        if workspaces.insert(workspace_id, evidence).is_some() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
    }
    let mut deletions = BTreeMap::new();
    for evidence in &recovery.deletions {
        let workspace_id = canonical_uuid(&evidence.workspace_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        if deletions.insert(workspace_id, evidence).is_some() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
    }
    if workspaces.keys().ne(binding.entries.keys()) || deletions.keys().ne(binding.deletions.keys())
    {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }

    let mut rows = Vec::with_capacity(catalog.entries.len() + binding.deletions.len());
    let mut journals = Vec::with_capacity(catalog.entries.len());
    let mut deletion_sidecars = Vec::with_capacity(binding.deletions.len());
    let mut rewrites = Vec::new();
    let mut admission_authoritative = true;
    for entry in &catalog.entries {
        let evidence = workspaces
            .get(&entry.workspace_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        let (row, journal_bytes, rewrite, authoritative) =
            derive_workspace_semantic_recovery_row_v1(
                &entry.workspace_id,
                &entry.file_url,
                evidence,
            )?;
        rows.push(row);
        journals.push(WorkspaceCommandAdmissionJournalRecoveryV1 {
            workspace_id: entry.workspace_id.clone(),
            canonical_bytes: journal_bytes,
        });
        if let Some(rewrite) = rewrite {
            rewrites.push(rewrite);
        }
        admission_authoritative &= authoritative;
    }
    for deletion in catalog.deletions.as_deref().unwrap_or_default() {
        let evidence = deletions
            .get(&deletion.workspace_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        let sidecar = match &evidence.sidecar {
            WorkspaceRecoveryArtifactEvidenceV1::Present(bytes)
                if recovered_deletion_record(deletion, Some(bytes)).is_ok() =>
            {
                Some(bytes.clone())
            }
            WorkspaceRecoveryArtifactEvidenceV1::Present(_)
            | WorkspaceRecoveryArtifactEvidenceV1::Absent
            | WorkspaceRecoveryArtifactEvidenceV1::Unavailable(_) => None,
        };
        deletion_sidecars.push(WorkspaceCommandAdmissionDeletionRecoveryV1 {
            workspace_id: deletion.workspace_id.clone(),
            canonical_bytes: sidecar,
        });
        rows.push(WorkspaceSemanticRecoveryRowV1::Deleted {
            workspace_id: deletion.workspace_id.clone(),
            file_url: deletion.file_url.clone(),
        });
    }
    rows.sort_by(|left, right| {
        let left_id = match left {
            WorkspaceSemanticRecoveryRowV1::Active { row } => &row.workspace_id,
            WorkspaceSemanticRecoveryRowV1::Unavailable { row } => &row.workspace_id,
            WorkspaceSemanticRecoveryRowV1::Deleted { workspace_id, .. } => workspace_id,
        };
        let right_id = match right {
            WorkspaceSemanticRecoveryRowV1::Active { row } => &row.workspace_id,
            WorkspaceSemanticRecoveryRowV1::Unavailable { row } => &row.workspace_id,
            WorkspaceSemanticRecoveryRowV1::Deleted { workspace_id, .. } => workspace_id,
        };
        left_id.cmp(right_id)
    });
    let admission_disposition = if admission_authoritative {
        WorkspaceSemanticRecoveryAdmissionDispositionV1::Installed
    } else {
        WorkspaceSemanticRecoveryAdmissionDispositionV1::Quarantined
    };
    let global_health = if admission_authoritative {
        workspace_recovery_health_v1(WorkspaceProjectionHealthKind::Writable, None)
    } else {
        workspace_recovery_health_v1(
            WorkspaceProjectionHealthKind::DegradedReadOnly,
            Some("working_journal_recovery_unavailable".to_owned()),
        )
    };
    let projection = WorkspaceSemanticRecoveryProjectionV1::Full { rows };
    let projection_digest = semantic_recovery_projection_digest_v1(
        binding.revision,
        &binding.digest,
        None,
        &global_health,
        admission_disposition,
        &projection,
        &rewrites,
    )?;
    Ok((
        WorkspaceSemanticRecoveryPreviewV1 {
            catalog_revision: binding.revision,
            catalog_digest: binding.digest.clone(),
            target_workspace_id: None,
            global_health,
            admission_disposition,
            projection,
            journal_rewrites: rewrites,
            projection_digest,
        },
        admission_authoritative.then_some(WorkspaceCommandAdmissionRecoveryV1 {
            catalog_bytes: recovery.catalog_bytes.clone(),
            journals,
            deletion_sidecars,
        }),
    ))
}

fn derive_semantic_target_recovery_v1(
    recovery: &WorkspaceSemanticTargetRecoveryV1,
) -> Result<
    (
        WorkspaceSemanticRecoveryPreviewV1,
        Option<WorkspaceCommandAdmissionTargetRecoveryV1>,
    ),
    WorkspaceWorkingJournalError,
> {
    checked_semantic_recovery_bytes_v1(
        &recovery.catalog_bytes,
        [
            &recovery.journal,
            &recovery.saved_document,
            &recovery.saved_revision,
            &recovery.deletion_sidecar,
        ]
        .into_iter(),
    )?;
    let (_, catalog, binding) = validated_recovery_catalog(&recovery.catalog_bytes)?;
    let workspace_id = canonical_uuid(&recovery.workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    let mut rewrites = Vec::new();
    let (directive, journal_bytes, deletion_sidecar_bytes, authoritative) = if let Some(entry) =
        catalog
            .entries
            .iter()
            .find(|entry| entry.workspace_id == workspace_id)
    {
        if !matches!(
            recovery.deletion_sidecar,
            WorkspaceRecoveryArtifactEvidenceV1::Absent
        ) {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let evidence = WorkspaceSemanticRecoveryEvidenceV1 {
            workspace_id: workspace_id.clone(),
            journal: recovery.journal.clone(),
            saved_document: recovery.saved_document.clone(),
            saved_revision: recovery.saved_revision.clone(),
        };
        let (row, journal_bytes, rewrite, authoritative) =
            derive_workspace_semantic_recovery_row_v1(&workspace_id, &entry.file_url, &evidence)?;
        if let Some(rewrite) = rewrite {
            rewrites.push(rewrite);
        }
        let directive = match row {
            WorkspaceSemanticRecoveryRowV1::Active { row } => {
                WorkspaceSemanticTargetDirectiveV1::Upsert { row }
            }
            WorkspaceSemanticRecoveryRowV1::Unavailable { row } => {
                WorkspaceSemanticTargetDirectiveV1::Unavailable { row }
            }
            WorkspaceSemanticRecoveryRowV1::Deleted { .. } => {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        };
        (directive, journal_bytes, None, authoritative)
    } else if let Some(deletion) = catalog
        .deletions
        .as_deref()
        .unwrap_or_default()
        .iter()
        .find(|deletion| deletion.workspace_id == workspace_id)
    {
        if !matches!(
            recovery.journal,
            WorkspaceRecoveryArtifactEvidenceV1::Absent
        ) || !matches!(
            recovery.saved_document,
            WorkspaceRecoveryArtifactEvidenceV1::Absent
        ) || !matches!(
            recovery.saved_revision,
            WorkspaceRecoveryArtifactEvidenceV1::Absent
        ) {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let sidecar = match &recovery.deletion_sidecar {
            WorkspaceRecoveryArtifactEvidenceV1::Present(bytes)
                if recovered_deletion_record(deletion, Some(bytes)).is_ok() =>
            {
                Some(bytes.clone())
            }
            WorkspaceRecoveryArtifactEvidenceV1::Present(_)
            | WorkspaceRecoveryArtifactEvidenceV1::Absent
            | WorkspaceRecoveryArtifactEvidenceV1::Unavailable(_) => None,
        };
        (
            WorkspaceSemanticTargetDirectiveV1::Delete {
                workspace_id: workspace_id.clone(),
                file_url: deletion.file_url.clone(),
            },
            None,
            sidecar,
            true,
        )
    } else {
        return Err(WorkspaceWorkingJournalError::FullRecoveryRequired);
    };
    let admission_disposition = if authoritative {
        WorkspaceSemanticRecoveryAdmissionDispositionV1::Installed
    } else {
        WorkspaceSemanticRecoveryAdmissionDispositionV1::Quarantined
    };
    let global_health = if authoritative {
        workspace_recovery_health_v1(WorkspaceProjectionHealthKind::Writable, None)
    } else {
        workspace_recovery_health_v1(
            WorkspaceProjectionHealthKind::DegradedReadOnly,
            Some("working_journal_recovery_unavailable".to_owned()),
        )
    };
    let projection = WorkspaceSemanticRecoveryProjectionV1::Target { directive };
    let projection_digest = semantic_recovery_projection_digest_v1(
        binding.revision,
        &binding.digest,
        Some(&workspace_id),
        &global_health,
        admission_disposition,
        &projection,
        &rewrites,
    )?;
    Ok((
        WorkspaceSemanticRecoveryPreviewV1 {
            catalog_revision: binding.revision,
            catalog_digest: binding.digest.clone(),
            target_workspace_id: Some(workspace_id.clone()),
            global_health,
            admission_disposition,
            projection,
            journal_rewrites: rewrites,
            projection_digest,
        },
        authoritative.then_some(WorkspaceCommandAdmissionTargetRecoveryV1 {
            catalog_bytes: recovery.catalog_bytes.clone(),
            workspace_id,
            journal_bytes,
            deletion_sidecar_bytes,
        }),
    ))
}

#[derive(Clone, Debug)]
enum PreparedWorkspaceSemanticRecoveryModeV1 {
    Initial {
        admission_recovery: Option<WorkspaceCommandAdmissionRecoveryV1>,
    },
    Full {
        admission: PreparedWorkspaceCommandAdmissionV1,
        catalog_bytes: Vec<u8>,
        admission_recovery: Option<WorkspaceCommandAdmissionRecoveryV1>,
    },
    Target {
        admission: PreparedWorkspaceCommandAdmissionV1,
        catalog_bytes: Vec<u8>,
        admission_recovery: Option<WorkspaceCommandAdmissionTargetRecoveryV1>,
    },
}

#[derive(Clone, Debug)]
struct PreparedWorkspaceSemanticRecoveryStateV1 {
    mode: Option<PreparedWorkspaceSemanticRecoveryModeV1>,
    preview: WorkspaceSemanticRecoveryPreviewV1,
}

#[derive(Debug)]
pub struct PreparedWorkspaceSemanticRecoveryV1 {
    inner: Mutex<PreparedWorkspaceSemanticRecoveryStateV1>,
}

impl PreparedWorkspaceSemanticRecoveryV1 {
    pub fn prepare_initial(
        recovery: &WorkspaceSemanticFullRecoveryV1,
    ) -> Result<Self, WorkspaceWorkingJournalError> {
        let (preview, admission_recovery) = derive_semantic_full_recovery_v1(recovery)?;
        Ok(Self {
            inner: Mutex::new(PreparedWorkspaceSemanticRecoveryStateV1 {
                mode: Some(PreparedWorkspaceSemanticRecoveryModeV1::Initial { admission_recovery }),
                preview,
            }),
        })
    }

    pub fn preview(
        &self,
    ) -> Result<WorkspaceSemanticRecoveryPreviewV1, WorkspaceWorkingJournalError> {
        let inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.mode.is_none() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        Ok(inner.preview.clone())
    }

    pub fn commit(
        &self,
    ) -> Result<WorkspaceSemanticRecoveryCommitV1, WorkspaceWorkingJournalError> {
        // Retain the candidate lock through the admission mutation so close and competing commits
        // cannot consume or supersede the prepared digest while its effect is being installed.
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        let mode = inner
            .mode
            .clone()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        let preview = inner.preview.clone();
        let (admission, admission_receipt) = match mode {
            PreparedWorkspaceSemanticRecoveryModeV1::Initial { admission_recovery } => {
                if let Some(recovery) = admission_recovery {
                    let (admission, receipt) =
                        PreparedWorkspaceCommandAdmissionV1::prepare_from_recovery(&recovery)?;
                    (Some(admission), Some(receipt))
                } else {
                    (None, None)
                }
            }
            PreparedWorkspaceSemanticRecoveryModeV1::Full {
                admission,
                catalog_bytes,
                admission_recovery,
            } => {
                let receipt = if let Some(recovery) = &admission_recovery {
                    Some(admission.apply_full_recovery(recovery)?)
                } else {
                    admission.quarantine_full_recovery(&catalog_bytes)?;
                    None
                };
                (None, receipt)
            }
            PreparedWorkspaceSemanticRecoveryModeV1::Target {
                admission,
                catalog_bytes,
                admission_recovery,
            } => {
                let receipt = if let Some(recovery) = &admission_recovery {
                    Some(admission.apply_target_recovery(recovery)?)
                } else {
                    let target_workspace_id = preview
                        .target_workspace_id
                        .as_deref()
                        .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
                    admission.quarantine_target_recovery(&catalog_bytes, target_workspace_id)?;
                    None
                };
                (None, receipt)
            }
        };
        inner.mode = None;
        Ok(WorkspaceSemanticRecoveryCommitV1 {
            admission,
            admission_receipt,
            catalog_revision: preview.catalog_revision,
            catalog_digest: preview.catalog_digest,
            target_workspace_id: preview.target_workspace_id,
            admission_disposition: preview.admission_disposition,
            projection_digest: preview.projection_digest,
        })
    }

    pub fn close(&self) -> bool {
        self.inner
            .lock()
            .map(|mut inner| inner.mode.take().is_some())
            .unwrap_or(false)
    }
}

#[derive(Clone, Debug)]
pub struct PreparedWorkspaceCommandAdmissionV1 {
    inner: Arc<Mutex<WorkspaceCommandAdmissionInnerV1>>,
}

fn reconcile_workspace_command_execution_claims_v1(
    claims: &BTreeMap<String, WorkspaceCommandExecutionClaimStateV1>,
    replacement: &WorkspaceCommandAdmissionStateV1,
) -> Result<Vec<String>, WorkspaceWorkingJournalError> {
    let mut terminalized_claims = Vec::new();
    for (operation_id, claim) in claims {
        match replacement.decision(&claim.workspace_id, operation_id, &claim.fingerprint) {
            WorkspaceCommandAdmissionDecisionV1::Unseen => {}
            WorkspaceCommandAdmissionDecisionV1::Collision { .. } => {
                return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
            }
            WorkspaceCommandAdmissionDecisionV1::Replay { .. } => {
                if claim.reservation_id.is_none() {
                    terminalized_claims.push(operation_id.clone());
                }
            }
        }
    }
    Ok(terminalized_claims)
}

impl PreparedWorkspaceCommandAdmissionV1 {
    pub fn prepare_from_recovery(
        recovery: &WorkspaceCommandAdmissionRecoveryV1,
    ) -> Result<(Self, WorkspaceCommandAdmissionRecoveryReceiptV1), WorkspaceWorkingJournalError>
    {
        let (state, catalog_binding) = derive_full_recovery(recovery)?;
        let diagnostics = state.diagnostics();
        let (authority_snapshot, authority_projection_digest) =
            empty_workspace_authority_snapshot_v1()?;
        let receipt = WorkspaceCommandAdmissionRecoveryReceiptV1 {
            catalog_revision: catalog_binding.revision,
            catalog_digest: catalog_binding.digest.clone(),
            target_workspace_id: None,
            diagnostics,
        };
        Ok((
            Self {
                inner: Arc::new(Mutex::new(WorkspaceCommandAdmissionInnerV1 {
                    state: Some(state),
                    catalog_binding: Some(catalog_binding),
                    claims: BTreeMap::new(),
                    reservations: BTreeMap::new(),
                    next_claim_generation: 1,
                    next_reservation_id: 1,
                    authority_publication_reservation: None,
                    authority_snapshot,
                    authority_publication: WorkspaceProjectionPublicationState::default(),
                    authority_projection_digest,
                    quarantined: false,
                    closed: false,
                })),
            },
            receipt,
        ))
    }

    #[cfg(test)]
    fn prepare(
        seed: &[WorkspaceCommandAdmissionSeedRecordV1],
    ) -> Result<Self, WorkspaceWorkingJournalError> {
        let (authority_snapshot, authority_projection_digest) =
            empty_workspace_authority_snapshot_v1()?;
        Ok(Self {
            inner: Arc::new(Mutex::new(WorkspaceCommandAdmissionInnerV1 {
                state: Some(WorkspaceCommandAdmissionStateV1::from_records(seed)?),
                catalog_binding: None,
                claims: BTreeMap::new(),
                reservations: BTreeMap::new(),
                next_claim_generation: 1,
                next_reservation_id: 1,
                authority_publication_reservation: None,
                authority_snapshot,
                authority_publication: WorkspaceProjectionPublicationState::default(),
                authority_projection_digest,
                quarantined: false,
                closed: false,
            })),
        })
    }

    pub fn prepare_semantic_full_recovery(
        &self,
        recovery: &WorkspaceSemanticFullRecoveryV1,
    ) -> Result<PreparedWorkspaceSemanticRecoveryV1, WorkspaceWorkingJournalError> {
        let (preview, admission_recovery) = derive_semantic_full_recovery_v1(recovery)?;
        Ok(PreparedWorkspaceSemanticRecoveryV1 {
            inner: Mutex::new(PreparedWorkspaceSemanticRecoveryStateV1 {
                mode: Some(PreparedWorkspaceSemanticRecoveryModeV1::Full {
                    admission: self.clone(),
                    catalog_bytes: recovery.catalog_bytes.clone(),
                    admission_recovery,
                }),
                preview,
            }),
        })
    }

    pub fn prepare_semantic_target_recovery(
        &self,
        recovery: &WorkspaceSemanticTargetRecoveryV1,
    ) -> Result<PreparedWorkspaceSemanticRecoveryV1, WorkspaceWorkingJournalError> {
        let (preview, admission_recovery) = derive_semantic_target_recovery_v1(recovery)?;
        Ok(PreparedWorkspaceSemanticRecoveryV1 {
            inner: Mutex::new(PreparedWorkspaceSemanticRecoveryStateV1 {
                mode: Some(PreparedWorkspaceSemanticRecoveryModeV1::Target {
                    admission: self.clone(),
                    catalog_bytes: recovery.catalog_bytes.clone(),
                    admission_recovery,
                }),
                preview,
            }),
        })
    }

    /// Atomically replaces durable workspace indexes while retaining process-lifetime global
    /// command receipts, exact claims, and bound reservations.
    pub fn apply_full_recovery(
        &self,
        recovery: &WorkspaceCommandAdmissionRecoveryV1,
    ) -> Result<WorkspaceCommandAdmissionRecoveryReceiptV1, WorkspaceWorkingJournalError> {
        let (mut replacement, catalog_binding) = derive_full_recovery(recovery)?;
        let mut state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if state.closed || state.authority_publication_reservation.is_some() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        if let Some(current_binding) = &state.catalog_binding {
            if catalog_binding.revision < current_binding.revision
                || (catalog_binding.revision == current_binding.revision
                    && catalog_binding.digest != current_binding.digest)
            {
                return Err(WorkspaceWorkingJournalError::StaleRecoverySnapshot);
            }
        }
        let current = state
            .state
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;

        let mut durable_operations = replacement.global.records();
        durable_operations.extend(
            replacement
                .workspaces
                .values()
                .flat_map(BoundedWorkspaceCommandOperationIndexV1::records),
        );
        for operation in &durable_operations {
            if current
                .global
                .get(&operation.operation_id)
                .is_some_and(|existing| existing != operation)
            {
                return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
            }
        }
        let mut merged_global = replacement.global.records();
        merged_global.extend(current.global.records());
        replacement.global = BoundedWorkspaceCommandOperationIndexV1::from_records(
            MAXIMUM_WORKSPACE_COMMAND_ADMISSION_GLOBAL_OPERATION_COUNT_V1,
            merged_global,
        )?;
        replacement.require_reconstructible_size()?;
        let diagnostics = replacement.diagnostics();
        let terminalized_claims =
            reconcile_workspace_command_execution_claims_v1(&state.claims, &replacement)?;
        let mut projected = replacement.clone();
        for effect in state.reservations.values() {
            effect.apply_reservation_projection(&mut projected)?;
        }
        state.state = Some(replacement);
        state.catalog_binding = Some(catalog_binding.clone());
        state.quarantined = false;
        for operation_id in terminalized_claims {
            state.claims.remove(&operation_id);
        }
        Ok(WorkspaceCommandAdmissionRecoveryReceiptV1 {
            catalog_revision: catalog_binding.revision,
            catalog_digest: catalog_binding.digest,
            target_workspace_id: None,
            diagnostics,
        })
    }

    fn quarantine_full_recovery(
        &self,
        catalog_bytes: &[u8],
    ) -> Result<(), WorkspaceWorkingJournalError> {
        let (_, _, catalog_binding) = validated_recovery_catalog(catalog_bytes)?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed || inner.authority_publication_reservation.is_some() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        if let Some(current_binding) = &inner.catalog_binding {
            if catalog_binding.revision < current_binding.revision
                || (catalog_binding.revision == current_binding.revision
                    && catalog_binding.digest != current_binding.digest)
            {
                return Err(WorkspaceWorkingJournalError::StaleRecoverySnapshot);
            }
        }
        inner
            .state
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        inner.catalog_binding = Some(catalog_binding);
        inner.quarantined = true;
        Ok(())
    }

    #[cfg(test)]
    fn reconcile_durable(
        &self,
        seed: &[WorkspaceCommandAdmissionSeedRecordV1],
    ) -> Result<WorkspaceCommandAdmissionDiagnosticsV1, WorkspaceWorkingJournalError> {
        let mut replacement = WorkspaceCommandAdmissionStateV1::from_records(seed)?;
        let mut state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if state.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let current = state
            .state
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        let mut durable_operations = replacement.global.records();
        durable_operations.extend(
            replacement
                .workspaces
                .values()
                .flat_map(BoundedWorkspaceCommandOperationIndexV1::records),
        );
        for operation in &durable_operations {
            if current
                .global
                .get(&operation.operation_id)
                .is_some_and(|existing| existing != operation)
            {
                return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
            }
        }
        let mut merged_global = replacement.global.records();
        merged_global.extend(current.global.records());
        replacement.global = BoundedWorkspaceCommandOperationIndexV1::from_records(
            MAXIMUM_WORKSPACE_COMMAND_ADMISSION_GLOBAL_OPERATION_COUNT_V1,
            merged_global,
        )?;
        replacement.require_reconstructible_size()?;
        let diagnostics = replacement.diagnostics();
        let terminalized_claims =
            reconcile_workspace_command_execution_claims_v1(&state.claims, &replacement)?;
        let mut projected = replacement.clone();
        for effect in state.reservations.values() {
            effect.apply_reservation_projection(&mut projected)?;
        }
        state.state = Some(replacement);
        for operation_id in terminalized_claims {
            state.claims.remove(&operation_id);
        }
        Ok(diagnostics)
    }

    pub fn acquire(
        &self,
        request: WorkspaceCommandIdentityRequestV1,
    ) -> Result<WorkspaceCommandAdmissionAcquireV1, WorkspaceWorkingJournalError> {
        let operation_id = canonical_uuid(&request.operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        let identity = workspace_command_identity_v1(request)?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed || inner.quarantined {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let admission = inner
            .state
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        match admission.decision(&identity.workspace_id, &operation_id, &identity.fingerprint) {
            WorkspaceCommandAdmissionDecisionV1::Replay { scope, operation } => {
                return Ok(WorkspaceCommandAdmissionAcquireV1::Replay {
                    identity,
                    scope,
                    operation,
                });
            }
            WorkspaceCommandAdmissionDecisionV1::Collision { scope } => {
                return Ok(WorkspaceCommandAdmissionAcquireV1::Collision {
                    identity,
                    scope: Some(scope),
                });
            }
            WorkspaceCommandAdmissionDecisionV1::Unseen => {}
        }
        if let Some(claim) = inner.claims.get(&operation_id) {
            if claim.workspace_id == identity.workspace_id
                && claim.fingerprint == identity.fingerprint
            {
                return Ok(WorkspaceCommandAdmissionAcquireV1::Pending {
                    identity,
                    generation: claim.generation,
                });
            }
            return Ok(WorkspaceCommandAdmissionAcquireV1::Collision {
                identity,
                scope: None,
            });
        }
        if inner.claims.len() >= MAXIMUM_WORKSPACE_COMMAND_ADMISSION_CLAIM_COUNT_V1 {
            return Err(WorkspaceWorkingJournalError::InputTooLarge {
                actual: inner.claims.len() + 1,
                maximum: MAXIMUM_WORKSPACE_COMMAND_ADMISSION_CLAIM_COUNT_V1,
            });
        }
        let generation = inner.next_claim_generation;
        inner.next_claim_generation = generation
            .checked_add(1)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        inner.claims.insert(
            operation_id.clone(),
            WorkspaceCommandExecutionClaimStateV1 {
                workspace_id: identity.workspace_id.clone(),
                fingerprint: identity.fingerprint.clone(),
                generation,
                reservation_id: None,
            },
        );
        Ok(WorkspaceCommandAdmissionAcquireV1::Claimed {
            claim: WorkspaceCommandExecutionClaimV1 {
                inner: Arc::clone(&self.inner),
                workspace_id: identity.workspace_id.clone(),
                operation_id,
                fingerprint: identity.fingerprint.clone(),
                generation,
            },
            identity,
        })
    }

    pub fn apply_target_recovery(
        &self,
        recovery: &WorkspaceCommandAdmissionTargetRecoveryV1,
    ) -> Result<WorkspaceCommandAdmissionRecoveryReceiptV1, WorkspaceWorkingJournalError> {
        let (records, catalog_binding, workspace_id, _) = derive_target_recovery(recovery)?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed || inner.authority_publication_reservation.is_some() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let current_binding = inner
            .catalog_binding
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::FullRecoveryRequired)?;
        if catalog_binding.revision < current_binding.revision
            || (catalog_binding.revision == current_binding.revision
                && catalog_binding.digest != current_binding.digest)
        {
            return Err(WorkspaceWorkingJournalError::StaleRecoverySnapshot);
        }
        if catalog_binding.revision > current_binding.revision
            && !current_binding.relationships_match_except(&catalog_binding, &workspace_id)
        {
            return Err(WorkspaceWorkingJournalError::FullRecoveryRequired);
        }
        let mut replacement = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        replacement.workspaces.remove(&workspace_id);
        for record in records {
            replacement.insert(record.workspace_id, record.operation)?;
        }
        let diagnostics = replacement.diagnostics();
        let terminalized_claims =
            reconcile_workspace_command_execution_claims_v1(&inner.claims, &replacement)?;
        let mut projected = replacement.clone();
        for effect in inner.reservations.values() {
            effect.apply_reservation_projection(&mut projected)?;
        }
        inner.state = Some(replacement);
        inner.catalog_binding = Some(catalog_binding.clone());
        inner.quarantined = false;
        for operation_id in terminalized_claims {
            inner.claims.remove(&operation_id);
        }
        Ok(WorkspaceCommandAdmissionRecoveryReceiptV1 {
            catalog_revision: catalog_binding.revision,
            catalog_digest: catalog_binding.digest,
            target_workspace_id: Some(workspace_id),
            diagnostics,
        })
    }

    fn quarantine_target_recovery(
        &self,
        catalog_bytes: &[u8],
        target_workspace_id: &str,
    ) -> Result<(), WorkspaceWorkingJournalError> {
        let (_, _, catalog_binding) = validated_recovery_catalog(catalog_bytes)?;
        let workspace_id = canonical_uuid(target_workspace_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        if !catalog_binding.entries.contains_key(&workspace_id)
            && !catalog_binding.deletions.contains_key(&workspace_id)
        {
            return Err(WorkspaceWorkingJournalError::FullRecoveryRequired);
        }
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed || inner.authority_publication_reservation.is_some() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let current_binding = inner
            .catalog_binding
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::FullRecoveryRequired)?;
        if catalog_binding.revision < current_binding.revision
            || (catalog_binding.revision == current_binding.revision
                && catalog_binding.digest != current_binding.digest)
        {
            return Err(WorkspaceWorkingJournalError::StaleRecoverySnapshot);
        }
        if catalog_binding.revision > current_binding.revision
            && !current_binding.relationships_match_except(&catalog_binding, &workspace_id)
        {
            return Err(WorkspaceWorkingJournalError::FullRecoveryRequired);
        }
        inner
            .state
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        inner.catalog_binding = Some(catalog_binding);
        inner.quarantined = true;
        Ok(())
    }

    #[cfg(test)]
    fn reconcile_workspace(
        &self,
        workspace_id: &str,
        operations: &[WorkspaceRecordedOperationV1],
        deleted_operation: Option<WorkspaceRecordedOperationV1>,
    ) -> Result<WorkspaceCommandAdmissionDiagnosticsV1, WorkspaceWorkingJournalError> {
        let workspace_id =
            canonical_uuid(workspace_id).ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        if deleted_operation.is_some() && !operations.is_empty() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut replacement = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        replacement.workspaces.remove(&workspace_id);
        if let Some(operation) = deleted_operation {
            replacement.insert(None, operation)?;
        } else {
            for operation in operations {
                replacement.insert(Some(workspace_id.clone()), operation.clone())?;
            }
        }
        let diagnostics = replacement.diagnostics();
        let terminalized_claims =
            reconcile_workspace_command_execution_claims_v1(&inner.claims, &replacement)?;
        let mut projected = replacement.clone();
        for effect in inner.reservations.values() {
            effect.apply_reservation_projection(&mut projected)?;
        }
        inner.state = Some(replacement);
        for operation_id in terminalized_claims {
            inner.claims.remove(&operation_id);
        }
        Ok(diagnostics)
    }

    pub fn reconcile_finalized_delete(
        &self,
        workspace_id: &str,
        mut expected_operation: WorkspaceRecordedOperationV1,
        mut replacement_operation: WorkspaceRecordedOperationV1,
    ) -> Result<WorkspaceCommandAdmissionDiagnosticsV1, WorkspaceWorkingJournalError> {
        let workspace_id =
            canonical_uuid(workspace_id).ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        validate_and_canonicalize_recorded_operation(&mut expected_operation)?;
        validate_and_canonicalize_recorded_operation(&mut replacement_operation)?;
        let replacement_diagnostic = replacement_operation.diagnostic.clone();
        let mut normalized_replacement = replacement_operation.clone();
        normalized_replacement.diagnostic = expected_operation.diagnostic.clone();
        if normalized_replacement != expected_operation
            || !deletion_diagnostic_matches(&replacement_diagnostic, &expected_operation.diagnostic)
        {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }

        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut replacement = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        if replacement.workspaces.contains_key(&workspace_id) {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }
        replacement
            .global
            .replace_exact(&expected_operation, replacement_operation)?;
        let diagnostics = replacement.diagnostics();
        let mut projected = replacement.clone();
        for effect in inner.reservations.values() {
            effect.apply_reservation_projection(&mut projected)?;
        }
        inner.state = Some(replacement);
        Ok(diagnostics)
    }

    /// Derives a command publication from the transaction's canonical result and the current
    /// immutable aggregate. Swift supplies no speculative snapshot here: Rust retains non-target
    /// document bytes, replaces the target row (or removes it for delete), and validates the exact
    /// claim/effect before reserving the aggregate head.
    pub fn prepare_claimed_authority_publication_from_transaction(
        &self,
        claim: &WorkspaceCommandExecutionClaimV1,
        expected_kind: WorkspaceProjectionPublicationKind,
        target: Option<WorkspaceProjectionPublishedWorkspace>,
        mut operation: WorkspaceRecordedOperationV1,
        context_id: Option<String>,
    ) -> Result<PreparedWorkspaceAuthorityPublicationV1, WorkspaceWorkingJournalError> {
        validate_and_canonicalize_recorded_operation(&mut operation)?;
        if operation.operation_id != claim.operation_id
            || operation.fingerprint != claim.fingerprint
        {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }
        let workspace_id = canonical_uuid(&claim.workspace_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        let mut workspaces = {
            let inner = self
                .inner
                .lock()
                .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
            inner
                .authority_snapshot
                .entries
                .iter()
                .filter(|entry| entry.projection.workspace_id != workspace_id)
                .map(|entry| {
                    Ok(WorkspaceProjectionPublishedWorkspace {
                        document_bytes: entry.document_bytes.clone(),
                        authority: entry
                            .authority
                            .clone()
                            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?,
                    })
                })
                .collect::<Result<Vec<_>, WorkspaceWorkingJournalError>>()?
        };
        if let Some(target) = target {
            if project_workspace_document_v1(&target.document_bytes)
                .map_err(|_| WorkspaceWorkingJournalError::InvalidWorkingDocument)?
                .workspace_id
                != workspace_id
            {
                return Err(WorkspaceWorkingJournalError::InvalidIdentity);
            }
            workspaces.push(target);
        }
        workspaces.sort_by(|left, right| {
            let left_id = project_workspace_document_v1(&left.document_bytes)
                .map(|projection| projection.workspace_id)
                .unwrap_or_default();
            let right_id = project_workspace_document_v1(&right.document_bytes)
                .map(|projection| projection.workspace_id)
                .unwrap_or_default();
            left_id.cmp(&right_id)
        });
        let draft = WorkspaceAuthorityPublicationDraftV1 {
            catalog_revision: operation.catalog_revision,
            kind: expected_kind,
            workspace_id: Some(workspace_id),
            context_id,
            operation_id: Some(operation.operation_id.clone()),
            revisions: operation.after,
        };
        self.prepare_claimed_authority_publication(claim, expected_kind, &workspaces, draft)
    }

    pub fn prepare_claimed_authority_publication(
        &self,
        claim: &WorkspaceCommandExecutionClaimV1,
        expected_kind: WorkspaceProjectionPublicationKind,
        workspaces: &[WorkspaceProjectionPublishedWorkspace],
        draft: WorkspaceAuthorityPublicationDraftV1,
    ) -> Result<PreparedWorkspaceAuthorityPublicationV1, WorkspaceWorkingJournalError> {
        if !Arc::ptr_eq(&self.inner, &claim.inner) {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let candidate = prepare_workspace_authority_publication_candidate_v1(workspaces, draft)?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed
            || inner.quarantined
            || inner.state.is_none()
            || inner.authority_publication_reservation.is_some()
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let current = inner
            .claims
            .get(&claim.operation_id)
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        let reservation_id = current
            .reservation_id
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        if current.workspace_id != claim.workspace_id
            || current.fingerprint != claim.fingerprint
            || current.generation != claim.generation
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let effect = inner
            .reservations
            .get(&reservation_id)
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        validate_claimed_authority_publication_candidate_v1(
            &inner,
            &effect,
            expected_kind,
            claim,
            &candidate,
        )?;
        let reservation = WorkspaceAuthorityPublicationReservationV1 {
            reservation_id,
            workspace_id: claim.workspace_id.clone(),
            operation_id: claim.operation_id.clone(),
            fingerprint: claim.fingerprint.clone(),
            claim_generation: claim.generation,
            head: workspace_authority_publication_head_v1(&inner),
        };
        inner.authority_publication_reservation = Some(reservation.clone());
        drop(inner);
        Ok(PreparedWorkspaceAuthorityPublicationV1 {
            inner: Arc::clone(&self.inner),
            candidate,
            reservation,
            active: AtomicBool::new(true),
        })
    }

    /// Atomically replaces the complete direct-headless semantic/revision/health projection and
    /// advances the Rust-owned publication cursor. The complete proposed snapshot is fully parsed
    /// and capacity-checked before acquiring the capability lock; commit performs only bounded
    /// comparisons, generation arithmetic, and prepared-state swaps.
    pub fn publish_authority_state(
        &self,
        workspaces: &[WorkspaceProjectionPublishedWorkspace],
        draft: WorkspaceAuthorityPublicationDraftV1,
    ) -> Result<WorkspaceAuthorityPublicationReceiptV1, WorkspaceWorkingJournalError> {
        let candidate = prepare_workspace_authority_publication_candidate_v1(workspaces, draft)?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        let admission = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        apply_workspace_authority_publication_candidate_v1(&mut inner, &admission, &candidate, None)
    }

    /// Synchronizes a Swift-owned routing overlay into the same immutable Rust projection without
    /// inventing a durable catalog event or advancing the subscriber publication cursor. This is
    /// the only non-event projection mutation and remains fenced by the exact admission capability.
    pub fn synchronize_authority_projection(
        &self,
        workspaces: &[WorkspaceProjectionPublishedWorkspace],
    ) -> Result<WorkspaceAuthorityProjectionSyncReceiptV1, WorkspaceWorkingJournalError> {
        let (retained_bytes, entries, projection_digest) =
            prepare_workspace_authority_snapshot_v1(workspaces)?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed
            || inner.quarantined
            || inner.state.is_none()
            || inner.authority_publication_reservation.is_some()
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let previous_generation = inner.authority_snapshot.generation;
        let projection_changed = inner.authority_snapshot.entries != entries;
        let generation = if projection_changed {
            previous_generation
                .checked_add(1)
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?
        } else {
            previous_generation
        };
        inner.authority_snapshot = Arc::new(WorkspaceProjectionSnapshot {
            generation,
            retained_bytes,
            entries,
        });
        inner.authority_projection_digest = projection_digest.clone();
        Ok(WorkspaceAuthorityProjectionSyncReceiptV1 {
            previous_generation,
            generation,
            projection_changed,
            workspace_count: inner.authority_snapshot.entries.len(),
            retained_bytes: inner.authority_snapshot.retained_bytes,
            catalog_revision: inner.authority_publication.catalog_revision,
            publication_sequence: inner.authority_publication.publication_sequence,
            projection_digest,
        })
    }

    /// Reads one immutable row and the publication cursor captured under the same capability lock.
    /// Missing rows are authoritative absence; this method never repairs, reprojects, or mutates
    /// access order.
    pub fn authority_read(
        &self,
        workspace_id: &str,
    ) -> Result<WorkspaceAuthorityReadV1, WorkspaceWorkingJournalError> {
        let workspace_id =
            canonical_uuid(workspace_id).ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        let inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed || inner.state.is_none() {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let entry = inner
            .authority_snapshot
            .entries
            .iter()
            .find(|entry| entry.projection.workspace_id == workspace_id);
        Ok(WorkspaceAuthorityReadV1 {
            projection: entry.map(|entry| entry.projection.clone()),
            authority: entry.and_then(|entry| entry.authority.clone()),
            content_digest: entry.map(|entry| entry.content_digest.clone()),
            generation: inner.authority_snapshot.generation,
            catalog_revision: inner.authority_publication.catalog_revision,
            publication_sequence: inner.authority_publication.publication_sequence,
            event_log_floor_sequence: inner.authority_publication.event_log_floor_sequence,
            event_log_count: inner.authority_publication.events.len(),
            projection_digest: inner.authority_projection_digest.clone(),
        })
    }

    pub fn diagnostics(
        &self,
    ) -> Result<WorkspaceCommandAdmissionDiagnosticsV1, WorkspaceWorkingJournalError> {
        let state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if state.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        state
            .state
            .as_ref()
            .map(WorkspaceCommandAdmissionStateV1::diagnostics)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)
    }

    pub fn bind_claim(
        &self,
        claim: &WorkspaceCommandExecutionClaimV1,
        effect: WorkspaceCommandAdmissionFinalizationV1,
    ) -> Result<WorkspaceCommandAdmissionReservationV1, WorkspaceWorkingJournalError> {
        if !Arc::ptr_eq(&self.inner, &claim.inner) {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let (effect_workspace_id, effect_operation) = match &effect {
            WorkspaceCommandAdmissionFinalizationV1::Workspace {
                workspace_id,
                operation,
            }
            | WorkspaceCommandAdmissionFinalizationV1::Delete {
                workspace_id,
                operation,
            } => (workspace_id, operation),
        };
        let effect_workspace_id = canonical_uuid(effect_workspace_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        let effect_operation_id = canonical_uuid(&effect_operation.operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        if effect_workspace_id != claim.workspace_id
            || effect_operation_id != claim.operation_id
            || effect_operation.fingerprint != claim.fingerprint
        {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let current = inner
            .claims
            .get(&claim.operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        if current.workspace_id != claim.workspace_id
            || current.fingerprint != claim.fingerprint
            || current.generation != claim.generation
            || current.reservation_id.is_some()
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut projected = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        for pending in inner.reservations.values() {
            if pending.conflicts_with(&effect) {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            pending.apply_reservation_projection(&mut projected)?;
        }
        effect.apply_reservation_projection(&mut projected)?;
        let reservation_id = inner.next_reservation_id;
        inner.next_reservation_id = reservation_id
            .checked_add(1)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        inner.reservations.insert(reservation_id, effect);
        inner
            .claims
            .get_mut(&claim.operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?
            .reservation_id = Some(reservation_id);
        Ok(WorkspaceCommandAdmissionReservationV1 {
            inner: Arc::clone(&self.inner),
            reservation_id,
            claim: Some((claim.operation_id.clone(), claim.generation)),
            active: true,
        })
    }

    pub fn reserve(
        &self,
        effect: WorkspaceCommandAdmissionFinalizationV1,
    ) -> Result<WorkspaceCommandAdmissionReservationV1, WorkspaceWorkingJournalError> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed || inner.quarantined {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut projected = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        for pending in inner.reservations.values() {
            if pending.conflicts_with(&effect) {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            pending.apply_reservation_projection(&mut projected)?;
        }
        effect.apply_reservation_projection(&mut projected)?;
        let reservation_id = inner.next_reservation_id;
        inner.next_reservation_id = inner
            .next_reservation_id
            .checked_add(1)
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        inner.reservations.insert(reservation_id, effect);
        Ok(WorkspaceCommandAdmissionReservationV1 {
            inner: Arc::clone(&self.inner),
            reservation_id,
            claim: None,
            active: true,
        })
    }

    pub fn close(&self) {
        if let Ok(mut inner) = self.inner.lock() {
            inner.closed = true;
            if inner.claims.is_empty() && inner.reservations.is_empty() {
                inner.state.take();
            }
        }
    }
}

#[cfg(test)]
impl PreparedWorkspaceCommandAdmissionV1 {
    fn inspect_for_test(
        &self,
        request: WorkspaceCommandIdentityRequestV1,
    ) -> Result<WorkspaceCommandAdmissionInspectionV1, WorkspaceWorkingJournalError> {
        let operation_id = canonical_uuid(&request.operation_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        let identity = workspace_command_identity_v1(request)?;
        let inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let admission = inner
            .state
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        let decision =
            admission.decision(&identity.workspace_id, &operation_id, &identity.fingerprint);
        Ok(WorkspaceCommandAdmissionInspectionV1 { identity, decision })
    }

    fn decision_for_test(
        &self,
        workspace_id: &str,
        operation_id: &str,
        fingerprint: &str,
    ) -> Result<WorkspaceCommandAdmissionDecisionV1, WorkspaceWorkingJournalError> {
        let workspace_id =
            canonical_uuid(workspace_id).ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        let operation_id =
            canonical_uuid(operation_id).ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        if !is_sha256_digest(fingerprint) {
            return Err(WorkspaceWorkingJournalError::InvalidDigest);
        }
        let inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let admission = inner
            .state
            .as_ref()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        Ok(admission.decision(&workspace_id, &operation_id, fingerprint))
    }

    fn insert_for_test(
        &self,
        workspace_id: Option<String>,
        operation: WorkspaceRecordedOperationV1,
    ) -> Result<WorkspaceCommandAdmissionDiagnosticsV1, WorkspaceWorkingJournalError> {
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut projected = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        for effect in inner.reservations.values() {
            effect.apply_reservation_projection(&mut projected)?;
        }
        projected.insert(workspace_id.clone(), operation.clone())?;
        let admission = inner
            .state
            .as_mut()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        admission.insert(workspace_id, operation)?;
        Ok(admission.diagnostics())
    }

    fn replace_for_test(
        &self,
        seed: &[WorkspaceCommandAdmissionSeedRecordV1],
    ) -> Result<WorkspaceCommandAdmissionDiagnosticsV1, WorkspaceWorkingJournalError> {
        let replacement = WorkspaceCommandAdmissionStateV1::from_records(seed)?;
        let diagnostics = replacement.diagnostics();
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let terminalized_claims =
            reconcile_workspace_command_execution_claims_v1(&inner.claims, &replacement)?;
        let mut projected = replacement.clone();
        for effect in inner.reservations.values() {
            effect.apply_reservation_projection(&mut projected)?;
        }
        inner.state = Some(replacement);
        for operation_id in terminalized_claims {
            inner.claims.remove(&operation_id);
        }
        Ok(diagnostics)
    }

    fn remove_workspace_for_test(
        &self,
        workspace_id: &str,
    ) -> Result<WorkspaceCommandAdmissionDiagnosticsV1, WorkspaceWorkingJournalError> {
        let workspace_id =
            canonical_uuid(workspace_id).ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        let mut inner = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if inner.closed {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let mut projected = inner
            .state
            .as_ref()
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        projected.workspaces.remove(&workspace_id);
        for effect in inner.reservations.values() {
            effect.apply_reservation_projection(&mut projected)?;
        }
        let admission = inner
            .state
            .as_mut()
            .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
        admission.workspaces.remove(&workspace_id);
        Ok(admission.diagnostics())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct WorkspaceWorkingJournalTransitionPlanV1 {
    primary: WorkspaceWorkingJournalValidationV1,
    committed: Option<WorkspaceWorkingJournalValidationV1>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceSaveTransactionRequestV1 {
    semantic_planner_version: u16,
    #[serde(rename = "expectedWorkspaceID")]
    expected_workspace_id: String,
    #[serde(rename = "expectedFileURL")]
    expected_file_url: String,
    expected_working_revision: u64,
    #[serde(rename = "operationID")]
    operation_id: String,
    fingerprint: String,
    updated_at: Value,
    catalog_revision: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceJournalMutationTransactionRequestV1 {
    semantic_planner_version: u16,
    #[serde(rename = "expectedWorkspaceID")]
    expected_workspace_id: String,
    #[serde(rename = "expectedFileURL")]
    expected_file_url: String,
    catalog_revision: u64,
    #[serde(rename = "revisionOperationID")]
    revision_operation_id: Option<String>,
    #[serde(rename = "recoveryMode")]
    recovery_mode: bool,
    transition: WorkspaceWorkingJournalTransitionRequestV1,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceDeleteTransactionRequestV1 {
    semantic_planner_version: u16,
    #[serde(rename = "expectedWorkspaceID")]
    expected_workspace_id: String,
    #[serde(rename = "expectedFileURL")]
    expected_file_url: String,
    expected_working_revision: u64,
    expected_catalog_revision: u64,
    #[serde(rename = "operationID")]
    operation_id: String,
    fingerprint: String,
    deleted_at: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum WorkspaceCreateTransactionRequestV1 {
    Create {
        semantic_planner_version: u16,
        #[serde(rename = "expectedWorkspaceID")]
        expected_workspace_id: String,
        #[serde(rename = "expectedFileURL")]
        expected_file_url: String,
        expected_catalog_revision: u64,
        #[serde(rename = "operationID")]
        operation_id: String,
        fingerprint: String,
        updated_at: Value,
    },
    Recover {
        #[serde(rename = "expectedWorkspaceID")]
        expected_workspace_id: String,
        #[serde(rename = "expectedFileURL")]
        expected_file_url: String,
        expected_catalog_revision: u64,
        updated_at: Value,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkspaceCreateActionKindV1 {
    WritePendingJournal,
    PublishWorkspaceDocument,
    WriteCommittedJournal,
    WriteSavedRevision,
    RemoveDeletionSidecar,
    PublishCatalog,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceCreateFailureV1 {
    Cancelled,
    StateConflict { expected: u64, actual: u64 },
    WriteFailed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCreateCommitReceiptV1 {
    pub workspace_id: String,
    pub operation_id: String,
    pub request_digest: String,
    pub document_digest: String,
    pub catalog: WorkspaceCatalogValidationV1,
    pub committed_journal: WorkspaceWorkingJournalValidationV1,
    pub saved_revision: Option<WorkspacePersistenceMetadataValidationV1>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceCreateDirectiveV1 {
    Action {
        action_id: u64,
        request_digest: String,
        kind: WorkspaceCreateActionKindV1,
        expected_raw_digest: Option<String>,
        canonical_bytes: Vec<u8>,
        content_digest: String,
        logical_expected_revision: Option<u64>,
        authority_receipt: Option<WorkspaceCreateCommitReceiptV1>,
    },
    Committed {
        receipt: WorkspaceCreateCommitReceiptV1,
    },
    Failed {
        failure: WorkspaceCreateFailureV1,
    },
}

pub type WorkspaceCreateActionReportV1 = WorkspaceSaveActionReportV1;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkspaceJournalMutationActionKindV1 {
    WriteJournal,
    WriteSavedRevision,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkspaceJournalMutationFinalizationV1 {
    Finalized,
    RevisionSidecarMissing,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceJournalMutationCommitReceiptV1 {
    pub workspace_id: String,
    pub request_digest: String,
    pub catalog_revision: u64,
    pub committed_journal: WorkspaceWorkingJournalValidationV1,
    pub saved_revision: Option<WorkspacePersistenceMetadataValidationV1>,
    pub resulting_working_revision: u64,
    pub resulting_saved_revision: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceJournalMutationDirectiveV1 {
    Action {
        action_id: u64,
        request_digest: String,
        kind: WorkspaceJournalMutationActionKindV1,
        expected_raw_journal_digest: Option<String>,
        canonical_bytes: Vec<u8>,
        content_digest: String,
        logical_expected_revision: Option<u64>,
        authority_receipt: Option<WorkspaceJournalMutationCommitReceiptV1>,
        post_authority_success_finalization: Option<WorkspaceJournalMutationFinalizationV1>,
        post_authority_failure_finalization: Option<WorkspaceJournalMutationFinalizationV1>,
    },
    Committed {
        receipt: WorkspaceJournalMutationCommitReceiptV1,
        finalization: WorkspaceJournalMutationFinalizationV1,
    },
    Failed {
        failure: WorkspaceSaveFailureV1,
    },
}

pub type WorkspaceJournalMutationActionReportV1 = WorkspaceSaveActionReportV1;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkspaceSaveActionKindV1 {
    WritePendingJournal,
    PublishWorkspaceDocument,
    WriteCommittedJournal,
    WriteSavedRevision,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkspaceSaveFinalizationV1 {
    Finalized,
    PendingJournalRetained,
    RevisionSidecarMissing,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceSaveFailureV1 {
    Cancelled,
    StateConflict { expected: u64, actual: u64 },
    WriteFailed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceSaveCommitReceiptV1 {
    pub workspace_id: String,
    pub operation_id: String,
    pub request_digest: String,
    pub catalog_revision: u64,
    pub document_digest: String,
    pub committed_journal: WorkspaceWorkingJournalValidationV1,
    pub saved_revision: WorkspacePersistenceMetadataValidationV1,
    pub resulting_working_revision: u64,
    pub resulting_saved_revision: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceSaveDirectiveV1 {
    Action {
        action_id: u64,
        request_digest: String,
        kind: WorkspaceSaveActionKindV1,
        expected_raw_journal_digest: Option<String>,
        canonical_bytes: Vec<u8>,
        content_digest: String,
        logical_expected_revision: Option<u64>,
        authority_receipt: Option<WorkspaceSaveCommitReceiptV1>,
        post_authority_success_finalization: Option<WorkspaceSaveFinalizationV1>,
        post_authority_failure_finalization: Option<WorkspaceSaveFinalizationV1>,
    },
    Committed {
        receipt: WorkspaceSaveCommitReceiptV1,
        finalization: WorkspaceSaveFinalizationV1,
    },
    Failed {
        failure: WorkspaceSaveFailureV1,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceSaveActionReportV1 {
    Success {
        action_id: u64,
        written_digest: String,
    },
    Cancelled {
        action_id: u64,
    },
    StateConflict {
        action_id: u64,
        expected: u64,
        actual: u64,
    },
    WriteFailed {
        action_id: u64,
    },
}

impl WorkspaceSaveActionReportV1 {
    fn action_id(&self) -> u64 {
        match self {
            Self::Success { action_id, .. }
            | Self::Cancelled { action_id }
            | Self::StateConflict { action_id, .. }
            | Self::WriteFailed { action_id } => *action_id,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkspaceDeleteActionKindV1 {
    PublishCatalog,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceDeleteFailureV1 {
    Cancelled,
    StateConflict { expected: u64, actual: u64 },
    WriteFailed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceDeleteCommitReceiptV1 {
    pub workspace_id: String,
    pub operation_id: String,
    pub request_digest: String,
    pub catalog: WorkspaceCatalogValidationV1,
    pub tombstone: WorkspacePersistenceMetadataValidationV1,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceDeleteDirectiveV1 {
    Action {
        action_id: u64,
        request_digest: String,
        kind: WorkspaceDeleteActionKindV1,
        expected_raw_catalog_digest: Option<String>,
        canonical_bytes: Vec<u8>,
        content_digest: String,
        logical_expected_revision: u64,
        authority_receipt: WorkspaceDeleteCommitReceiptV1,
    },
    Committed {
        receipt: WorkspaceDeleteCommitReceiptV1,
    },
    Failed {
        failure: WorkspaceDeleteFailureV1,
    },
}

pub type WorkspaceDeleteActionReportV1 = WorkspaceSaveActionReportV1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspacePendingSaveRecoveryV1 {
    NoPending {
        journal: WorkspaceWorkingJournalValidationV1,
    },
    PendingNotCommitted {
        journal: WorkspaceWorkingJournalValidationV1,
    },
    Committed {
        clean_journal: WorkspaceWorkingJournalValidationV1,
        document_digest: String,
    },
}

#[derive(Debug)]
pub struct PreparedWorkspaceJournalMutationTransactionV1 {
    inner: Mutex<WorkspaceJournalMutationTransactionStateV1>,
}

#[derive(Debug)]
pub struct PreparedWorkspaceSaveTransactionV1 {
    inner: Mutex<WorkspaceSaveTransactionStateV1>,
}

#[derive(Debug)]
pub struct PreparedWorkspaceDeleteTransactionV1 {
    inner: Mutex<WorkspaceDeleteTransactionStateV1>,
}

#[derive(Debug)]
pub struct PreparedWorkspaceCreateTransactionV1 {
    inner: Mutex<WorkspaceCreateTransactionStateV1>,
}

#[derive(Clone, Debug)]
struct WorkspaceCreateTransactionStateV1 {
    request_digest: String,
    expected_raw_catalog_digest: Option<String>,
    expected_catalog_revision: u64,
    raw_journal_digest: Option<String>,
    pending: Option<WorkspaceWorkingJournalValidationV1>,
    document_bytes: Vec<u8>,
    document_digest: String,
    committed_journal: WorkspaceWorkingJournalValidationV1,
    saved_revision: Option<WorkspacePersistenceMetadataValidationV1>,
    catalog: WorkspaceCatalogValidationV1,
    receipt: WorkspaceCreateCommitReceiptV1,
    admission_finalization: Option<WorkspaceCommandAdmissionFinalizationV1>,
    stage: WorkspaceCreateStageV1,
    last_report: Option<WorkspaceCreateActionReportV1>,
    last_result: Option<WorkspaceCreateDirectiveV1>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkspaceCreateStageV1 {
    PendingJournal,
    Document,
    CommittedJournal,
    SavedRevision,
    RemoveDeletionSidecar,
    Catalog { action_id: u64 },
    Terminal,
    Closed,
}

#[derive(Clone, Debug)]
struct WorkspaceDeleteTransactionStateV1 {
    request_digest: String,
    expected_raw_catalog_digest: Option<String>,
    expected_catalog_revision: u64,
    catalog: WorkspaceCatalogValidationV1,
    receipt: WorkspaceDeleteCommitReceiptV1,
    admission_finalization: WorkspaceCommandAdmissionFinalizationV1,
    stage: WorkspaceDeleteStageV1,
    last_report: Option<WorkspaceDeleteActionReportV1>,
    last_result: Option<WorkspaceDeleteDirectiveV1>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkspaceDeleteStageV1 {
    Publication,
    Terminal,
    Closed,
}

#[derive(Clone, Debug)]
struct WorkspaceJournalMutationTransactionStateV1 {
    request_digest: String,
    raw_journal_digest: Option<String>,
    expected_working_revision: u64,
    context_id: Option<String>,
    document_bytes: Vec<u8>,
    committed: WorkspaceWorkingJournalValidationV1,
    saved_revision: Option<WorkspacePersistenceMetadataValidationV1>,
    receipt: WorkspaceJournalMutationCommitReceiptV1,
    admission_finalization: Option<WorkspaceCommandAdmissionFinalizationV1>,
    authority_publication_kind: WorkspaceProjectionPublicationKind,
    stage: WorkspaceJournalMutationStageV1,
    last_report: Option<WorkspaceJournalMutationActionReportV1>,
    last_result: Option<WorkspaceJournalMutationDirectiveV1>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkspaceJournalMutationStageV1 {
    Journal,
    SavedRevision,
    Terminal,
    Closed,
}

#[derive(Clone, Debug)]
struct WorkspaceSaveTransactionStateV1 {
    request_digest: String,
    raw_journal_digest: Option<String>,
    expected_working_revision: u64,
    pending: WorkspaceWorkingJournalValidationV1,
    document_bytes: Vec<u8>,
    document_digest: String,
    committed: WorkspaceWorkingJournalValidationV1,
    saved_revision: WorkspacePersistenceMetadataValidationV1,
    receipt: WorkspaceSaveCommitReceiptV1,
    admission_finalization: WorkspaceCommandAdmissionFinalizationV1,
    stage: WorkspaceSaveStageV1,
    last_report: Option<WorkspaceSaveActionReportV1>,
    last_result: Option<WorkspaceSaveDirectiveV1>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkspaceSaveStageV1 {
    Pending,
    Document,
    CommittedJournal,
    SavedRevision,
    Terminal,
    Closed,
}

fn workspace_authority_from_journal_v1(
    document_bytes: &[u8],
    journal: &WorkspaceWorkingJournalValidationV1,
) -> Result<WorkspaceProjectionPublishedWorkspace, WorkspaceWorkingJournalError> {
    let parsed = parse_validated_journal(&journal.canonical_bytes)?;
    let projection = project_workspace_document_v1(document_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
    if projection.workspace_id != parsed.workspace_id {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    let context_revisions = workspace_recovery_context_revisions_v1(&parsed.context_revisions)?;
    let contexts = context_revisions
        .into_iter()
        .map(|context| WorkspaceContextAuthorityState {
            context_id: context.context_id,
            revisions: context.revisions,
            health: WorkspaceProjectionHealth {
                kind: WorkspaceProjectionHealthKind::Writable,
                reason: None,
            },
        })
        .collect();
    Ok(WorkspaceProjectionPublishedWorkspace {
        document_bytes: document_bytes.to_vec(),
        authority: WorkspaceProjectionAuthorityState {
            revisions: parsed.revisions,
            health: WorkspaceProjectionHealth {
                kind: WorkspaceProjectionHealthKind::Writable,
                reason: None,
            },
            contexts,
        },
    })
}

fn transaction_operation_v1(
    finalization: Option<WorkspaceCommandAdmissionFinalizationV1>,
) -> Result<(String, WorkspaceRecordedOperationV1), WorkspaceWorkingJournalError> {
    match finalization {
        Some(WorkspaceCommandAdmissionFinalizationV1::Workspace {
            workspace_id,
            operation,
        })
        | Some(WorkspaceCommandAdmissionFinalizationV1::Delete {
            workspace_id,
            operation,
        }) => Ok((workspace_id, operation)),
        None => Err(WorkspaceWorkingJournalError::InvalidTransaction),
    }
}

impl PreparedWorkspaceJournalMutationTransactionV1 {
    pub fn next_directive(
        &self,
    ) -> Result<WorkspaceJournalMutationDirectiveV1, WorkspaceWorkingJournalError> {
        let state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        state.directive()
    }

    pub fn report_action(
        &self,
        report: WorkspaceJournalMutationActionReportV1,
    ) -> Result<WorkspaceJournalMutationDirectiveV1, WorkspaceWorkingJournalError> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if matches!(state.stage, WorkspaceJournalMutationStageV1::Closed) {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        if state.last_report.as_ref() == Some(&report) {
            return state
                .last_result
                .clone()
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        if matches!(state.stage, WorkspaceJournalMutationStageV1::Terminal)
            || report.action_id() != state.action_id()?
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let result = state.advance(&report)?;
        state.last_report = Some(report);
        state.last_result = Some(result.clone());
        Ok(result)
    }

    pub fn close(&self) {
        if let Ok(mut state) = self.inner.lock() {
            state.stage = WorkspaceJournalMutationStageV1::Closed;
        }
    }

    pub fn is_ready_for_authority(&self) -> bool {
        self.inner
            .lock()
            .is_ok_and(|state| matches!(state.stage, WorkspaceJournalMutationStageV1::Journal))
    }

    pub fn command_admission_finalization(
        &self,
    ) -> Result<Option<WorkspaceCommandAdmissionFinalizationV1>, WorkspaceWorkingJournalError> {
        self.inner
            .lock()
            .map(|state| state.admission_finalization.clone())
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)
    }

    pub fn command_authority_publication_kind(
        &self,
    ) -> Result<WorkspaceProjectionPublicationKind, WorkspaceWorkingJournalError> {
        self.inner
            .lock()
            .map(|state| state.authority_publication_kind)
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)
    }

    pub fn prepare_claimed_authority_publication(
        &self,
        admission: &PreparedWorkspaceCommandAdmissionV1,
        claim: &WorkspaceCommandExecutionClaimV1,
    ) -> Result<PreparedWorkspaceAuthorityPublicationV1, WorkspaceWorkingJournalError> {
        let (target, operation, kind, context_id) = {
            let state = self
                .inner
                .lock()
                .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
            let target =
                workspace_authority_from_journal_v1(&state.document_bytes, &state.committed)?;
            let (_, operation) = transaction_operation_v1(state.admission_finalization.clone())?;
            (
                target,
                operation,
                state.authority_publication_kind,
                state.context_id.clone(),
            )
        };
        admission.prepare_claimed_authority_publication_from_transaction(
            claim,
            kind,
            Some(target),
            operation,
            context_id,
        )
    }

    pub fn is_authoritative(&self) -> bool {
        self.inner.lock().is_ok_and(|state| {
            matches!(
                state.stage,
                WorkspaceJournalMutationStageV1::SavedRevision
                    | WorkspaceJournalMutationStageV1::Terminal
            ) && matches!(
                state.last_result,
                Some(WorkspaceJournalMutationDirectiveV1::Action {
                    kind: WorkspaceJournalMutationActionKindV1::WriteSavedRevision,
                    ..
                }) | Some(WorkspaceJournalMutationDirectiveV1::Committed { .. })
            )
        })
    }
}

impl PreparedWorkspaceSaveTransactionV1 {
    pub fn next_directive(&self) -> Result<WorkspaceSaveDirectiveV1, WorkspaceWorkingJournalError> {
        let state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        state.directive()
    }

    pub fn report_action(
        &self,
        report: WorkspaceSaveActionReportV1,
    ) -> Result<WorkspaceSaveDirectiveV1, WorkspaceWorkingJournalError> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if state.last_report.as_ref() == Some(&report) {
            return state
                .last_result
                .clone()
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        if matches!(
            state.stage,
            WorkspaceSaveStageV1::Terminal | WorkspaceSaveStageV1::Closed
        ) {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let expected_action_id = state.action_id()?;
        if report.action_id() != expected_action_id {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let result = state.advance(&report)?;
        state.last_report = Some(report);
        state.last_result = Some(result.clone());
        Ok(result)
    }

    pub fn close(&self) {
        if let Ok(mut state) = self.inner.lock() {
            state.stage = WorkspaceSaveStageV1::Closed;
        }
    }

    pub fn is_authoritative(&self) -> bool {
        self.inner.lock().is_ok_and(|state| {
            matches!(
                state.stage,
                WorkspaceSaveStageV1::CommittedJournal
                    | WorkspaceSaveStageV1::SavedRevision
                    | WorkspaceSaveStageV1::Terminal
            ) && matches!(
                state.last_result,
                Some(WorkspaceSaveDirectiveV1::Action {
                    kind: WorkspaceSaveActionKindV1::WriteCommittedJournal
                        | WorkspaceSaveActionKindV1::WriteSavedRevision,
                    ..
                }) | Some(WorkspaceSaveDirectiveV1::Committed { .. })
            )
        })
    }

    pub fn is_ready_for_authority(&self) -> bool {
        self.inner
            .lock()
            .is_ok_and(|state| matches!(state.stage, WorkspaceSaveStageV1::Document))
    }

    pub fn command_admission_finalization(
        &self,
    ) -> Result<WorkspaceCommandAdmissionFinalizationV1, WorkspaceWorkingJournalError> {
        self.inner
            .lock()
            .map(|state| state.admission_finalization.clone())
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)
    }

    pub fn command_authority_publication_kind(&self) -> WorkspaceProjectionPublicationKind {
        WorkspaceProjectionPublicationKind::SavedDocumentCommitted
    }

    pub fn prepare_claimed_authority_publication(
        &self,
        admission: &PreparedWorkspaceCommandAdmissionV1,
        claim: &WorkspaceCommandExecutionClaimV1,
    ) -> Result<PreparedWorkspaceAuthorityPublicationV1, WorkspaceWorkingJournalError> {
        let (target, operation) = {
            let state = self
                .inner
                .lock()
                .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
            let target =
                workspace_authority_from_journal_v1(&state.document_bytes, &state.committed)?;
            let (_, operation) =
                transaction_operation_v1(Some(state.admission_finalization.clone()))?;
            (target, operation)
        };
        admission.prepare_claimed_authority_publication_from_transaction(
            claim,
            WorkspaceProjectionPublicationKind::SavedDocumentCommitted,
            Some(target),
            operation,
            None,
        )
    }
}

impl PreparedWorkspaceDeleteTransactionV1 {
    pub fn next_directive(
        &self,
    ) -> Result<WorkspaceDeleteDirectiveV1, WorkspaceWorkingJournalError> {
        let state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        state.directive()
    }

    pub fn report_action(
        &self,
        report: WorkspaceDeleteActionReportV1,
    ) -> Result<WorkspaceDeleteDirectiveV1, WorkspaceWorkingJournalError> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if matches!(state.stage, WorkspaceDeleteStageV1::Closed) {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        if state.last_report.as_ref() == Some(&report) {
            return state
                .last_result
                .clone()
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        if !matches!(state.stage, WorkspaceDeleteStageV1::Publication) || report.action_id() != 1 {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let result = state.advance(&report)?;
        state.last_report = Some(report);
        state.last_result = Some(result.clone());
        Ok(result)
    }

    pub fn close(&self) {
        if let Ok(mut state) = self.inner.lock() {
            state.stage = WorkspaceDeleteStageV1::Closed;
        }
    }

    pub fn is_authoritative(&self) -> bool {
        self.inner.lock().is_ok_and(|state| {
            matches!(state.stage, WorkspaceDeleteStageV1::Terminal)
                && matches!(
                    state.last_result,
                    Some(WorkspaceDeleteDirectiveV1::Committed { .. })
                )
        })
    }

    pub fn is_ready_for_authority(&self) -> bool {
        self.inner
            .lock()
            .is_ok_and(|state| matches!(state.stage, WorkspaceDeleteStageV1::Publication))
    }

    pub fn command_admission_finalization(
        &self,
    ) -> Result<WorkspaceCommandAdmissionFinalizationV1, WorkspaceWorkingJournalError> {
        self.inner
            .lock()
            .map(|state| state.admission_finalization.clone())
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)
    }

    pub fn command_authority_publication_kind(&self) -> WorkspaceProjectionPublicationKind {
        WorkspaceProjectionPublicationKind::WorkspaceDeleted
    }

    pub fn prepare_claimed_authority_publication(
        &self,
        admission: &PreparedWorkspaceCommandAdmissionV1,
        claim: &WorkspaceCommandExecutionClaimV1,
    ) -> Result<PreparedWorkspaceAuthorityPublicationV1, WorkspaceWorkingJournalError> {
        let operation = {
            let state = self
                .inner
                .lock()
                .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
            let (_, operation) =
                transaction_operation_v1(Some(state.admission_finalization.clone()))?;
            operation
        };
        admission.prepare_claimed_authority_publication_from_transaction(
            claim,
            WorkspaceProjectionPublicationKind::WorkspaceDeleted,
            None,
            operation,
            None,
        )
    }

    pub fn cleanup_plan(
        &self,
        cleanup_warnings_bytes: Option<&[u8]>,
    ) -> Result<WorkspaceDeleteCleanupPlanV1, WorkspaceWorkingJournalError> {
        let (authoritative_tombstone, authoritative_operation) = {
            let state = self
                .inner
                .lock()
                .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
            if !matches!(state.stage, WorkspaceDeleteStageV1::Terminal)
                || !matches!(
                    state.last_result,
                    Some(WorkspaceDeleteDirectiveV1::Committed { .. })
                )
            {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            let operation = match &state.admission_finalization {
                WorkspaceCommandAdmissionFinalizationV1::Delete { operation, .. } => {
                    operation.clone()
                }
                WorkspaceCommandAdmissionFinalizationV1::Workspace { .. } => {
                    return Err(WorkspaceWorkingJournalError::InvalidTransaction);
                }
            };
            (state.receipt.tombstone.clone(), operation)
        };
        let Some(cleanup_warnings_bytes) = cleanup_warnings_bytes else {
            return Ok(WorkspaceDeleteCleanupPlanV1 {
                validation: authoritative_tombstone,
                operation: authoritative_operation,
            });
        };
        let validation = amend_workspace_deletion_tombstone_cleanup_v1(
            &authoritative_tombstone.canonical_bytes,
            cleanup_warnings_bytes,
        )?;
        let tombstone: WorkspaceDeletionTombstoneV1 =
            serde_json::from_slice(&validation.canonical_bytes)
                .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        Ok(WorkspaceDeleteCleanupPlanV1 {
            validation,
            operation: tombstone.operation,
        })
    }
}

impl PreparedWorkspaceCreateTransactionV1 {
    pub fn next_directive(
        &self,
    ) -> Result<WorkspaceCreateDirectiveV1, WorkspaceWorkingJournalError> {
        let state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        state.directive()
    }

    pub fn report_action(
        &self,
        report: WorkspaceCreateActionReportV1,
    ) -> Result<WorkspaceCreateDirectiveV1, WorkspaceWorkingJournalError> {
        let mut state = self
            .inner
            .lock()
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
        if matches!(state.stage, WorkspaceCreateStageV1::Closed) {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        if state.last_report.as_ref() == Some(&report) {
            return state
                .last_result
                .clone()
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        if matches!(state.stage, WorkspaceCreateStageV1::Terminal)
            || report.action_id() != state.action_id()?
        {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
        let result = state.advance(&report)?;
        state.last_report = Some(report);
        state.last_result = Some(result.clone());
        Ok(result)
    }

    pub fn close(&self) {
        if let Ok(mut state) = self.inner.lock() {
            state.stage = WorkspaceCreateStageV1::Closed;
        }
    }

    pub fn is_authoritative(&self) -> bool {
        self.inner.lock().is_ok_and(|state| {
            matches!(state.stage, WorkspaceCreateStageV1::Terminal)
                && matches!(
                    state.last_result,
                    Some(WorkspaceCreateDirectiveV1::Committed { .. })
                )
        })
    }

    pub fn is_ready_for_authority(&self) -> bool {
        self.inner
            .lock()
            .is_ok_and(|state| matches!(state.stage, WorkspaceCreateStageV1::Catalog { .. }))
    }

    pub fn command_admission_finalization(
        &self,
    ) -> Result<Option<WorkspaceCommandAdmissionFinalizationV1>, WorkspaceWorkingJournalError> {
        self.inner
            .lock()
            .map(|state| state.admission_finalization.clone())
            .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)
    }

    pub fn command_authority_publication_kind(&self) -> WorkspaceProjectionPublicationKind {
        WorkspaceProjectionPublicationKind::WorkspaceCreated
    }

    pub fn prepare_claimed_authority_publication(
        &self,
        admission: &PreparedWorkspaceCommandAdmissionV1,
        claim: &WorkspaceCommandExecutionClaimV1,
    ) -> Result<PreparedWorkspaceAuthorityPublicationV1, WorkspaceWorkingJournalError> {
        let (target, operation) = {
            let state = self
                .inner
                .lock()
                .map_err(|_| WorkspaceWorkingJournalError::InvalidTransaction)?;
            let target = workspace_authority_from_journal_v1(
                &state.document_bytes,
                &state.committed_journal,
            )?;
            let (_, operation) = transaction_operation_v1(state.admission_finalization.clone())?;
            (target, operation)
        };
        admission.prepare_claimed_authority_publication_from_transaction(
            claim,
            WorkspaceProjectionPublicationKind::WorkspaceCreated,
            Some(target),
            operation,
            None,
        )
    }
}

impl WorkspaceCreateTransactionStateV1 {
    fn action_id(&self) -> Result<u64, WorkspaceWorkingJournalError> {
        match self.stage {
            WorkspaceCreateStageV1::PendingJournal => Ok(1),
            WorkspaceCreateStageV1::Document => Ok(2),
            WorkspaceCreateStageV1::CommittedJournal => Ok(3),
            WorkspaceCreateStageV1::SavedRevision => Ok(4),
            WorkspaceCreateStageV1::RemoveDeletionSidecar => Ok(5),
            WorkspaceCreateStageV1::Catalog { action_id } => Ok(action_id),
            WorkspaceCreateStageV1::Terminal | WorkspaceCreateStageV1::Closed => {
                Err(WorkspaceWorkingJournalError::InvalidTransaction)
            }
        }
    }

    fn directive(&self) -> Result<WorkspaceCreateDirectiveV1, WorkspaceWorkingJournalError> {
        let empty_digest = format!("{:x}", Sha256::digest([]));
        let directive = match self.stage {
            WorkspaceCreateStageV1::PendingJournal => {
                let pending = self
                    .pending
                    .as_ref()
                    .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
                self.action(
                    1,
                    WorkspaceCreateActionKindV1::WritePendingJournal,
                    self.raw_journal_digest.clone(),
                    pending.canonical_bytes.clone(),
                    pending.content_digest.clone(),
                    Some(0),
                    None,
                )
            }
            WorkspaceCreateStageV1::Document => self.action(
                2,
                WorkspaceCreateActionKindV1::PublishWorkspaceDocument,
                None,
                self.document_bytes.clone(),
                self.document_digest.clone(),
                None,
                None,
            ),
            WorkspaceCreateStageV1::CommittedJournal => {
                let pending = self
                    .pending
                    .as_ref()
                    .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
                self.action(
                    3,
                    WorkspaceCreateActionKindV1::WriteCommittedJournal,
                    Some(pending.content_digest.clone()),
                    self.committed_journal.canonical_bytes.clone(),
                    self.committed_journal.content_digest.clone(),
                    Some(1),
                    None,
                )
            }
            WorkspaceCreateStageV1::SavedRevision => {
                let saved_revision = self
                    .saved_revision
                    .as_ref()
                    .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
                self.action(
                    4,
                    WorkspaceCreateActionKindV1::WriteSavedRevision,
                    None,
                    saved_revision.canonical_bytes.clone(),
                    saved_revision.content_digest.clone(),
                    None,
                    None,
                )
            }
            WorkspaceCreateStageV1::RemoveDeletionSidecar => self.action(
                5,
                WorkspaceCreateActionKindV1::RemoveDeletionSidecar,
                None,
                Vec::new(),
                empty_digest,
                None,
                None,
            ),
            WorkspaceCreateStageV1::Catalog { action_id } => self.action(
                action_id,
                WorkspaceCreateActionKindV1::PublishCatalog,
                self.expected_raw_catalog_digest.clone(),
                self.catalog.canonical_bytes.clone(),
                self.catalog.content_digest.clone(),
                Some(self.expected_catalog_revision),
                Some(self.receipt.clone()),
            ),
            WorkspaceCreateStageV1::Terminal => {
                return self
                    .last_result
                    .clone()
                    .ok_or(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            WorkspaceCreateStageV1::Closed => {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        };
        Ok(directive)
    }

    #[allow(clippy::too_many_arguments)]
    fn action(
        &self,
        action_id: u64,
        kind: WorkspaceCreateActionKindV1,
        expected_raw_digest: Option<String>,
        canonical_bytes: Vec<u8>,
        content_digest: String,
        logical_expected_revision: Option<u64>,
        authority_receipt: Option<WorkspaceCreateCommitReceiptV1>,
    ) -> WorkspaceCreateDirectiveV1 {
        WorkspaceCreateDirectiveV1::Action {
            action_id,
            request_digest: self.request_digest.clone(),
            kind,
            expected_raw_digest,
            canonical_bytes,
            content_digest,
            logical_expected_revision,
            authority_receipt,
        }
    }

    fn expected_written_digest(&self) -> Result<String, WorkspaceWorkingJournalError> {
        match self.stage {
            WorkspaceCreateStageV1::PendingJournal => self
                .pending
                .as_ref()
                .map(|value| value.content_digest.clone())
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction),
            WorkspaceCreateStageV1::Document => Ok(self.document_digest.clone()),
            WorkspaceCreateStageV1::CommittedJournal => {
                Ok(self.committed_journal.content_digest.clone())
            }
            WorkspaceCreateStageV1::SavedRevision => self
                .saved_revision
                .as_ref()
                .map(|value| value.content_digest.clone())
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction),
            WorkspaceCreateStageV1::RemoveDeletionSidecar => {
                Ok(format!("{:x}", Sha256::digest([])))
            }
            WorkspaceCreateStageV1::Catalog { .. } => Ok(self.catalog.content_digest.clone()),
            WorkspaceCreateStageV1::Terminal | WorkspaceCreateStageV1::Closed => {
                Err(WorkspaceWorkingJournalError::InvalidTransaction)
            }
        }
    }

    fn advance(
        &mut self,
        report: &WorkspaceCreateActionReportV1,
    ) -> Result<WorkspaceCreateDirectiveV1, WorkspaceWorkingJournalError> {
        if let WorkspaceCreateActionReportV1::Success { written_digest, .. } = report {
            if written_digest != &self.expected_written_digest()? {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            self.stage = match self.stage {
                WorkspaceCreateStageV1::PendingJournal => WorkspaceCreateStageV1::Document,
                WorkspaceCreateStageV1::Document => WorkspaceCreateStageV1::CommittedJournal,
                WorkspaceCreateStageV1::CommittedJournal => WorkspaceCreateStageV1::SavedRevision,
                WorkspaceCreateStageV1::SavedRevision => {
                    WorkspaceCreateStageV1::RemoveDeletionSidecar
                }
                WorkspaceCreateStageV1::RemoveDeletionSidecar => {
                    WorkspaceCreateStageV1::Catalog { action_id: 6 }
                }
                WorkspaceCreateStageV1::Catalog { .. } => WorkspaceCreateStageV1::Terminal,
                WorkspaceCreateStageV1::Terminal | WorkspaceCreateStageV1::Closed => unreachable!(),
            };
            let result = if matches!(self.stage, WorkspaceCreateStageV1::Terminal) {
                WorkspaceCreateDirectiveV1::Committed {
                    receipt: self.receipt.clone(),
                }
            } else {
                self.directive()?
            };
            return Ok(result);
        }

        let failure = match report {
            WorkspaceCreateActionReportV1::Cancelled { .. } => WorkspaceCreateFailureV1::Cancelled,
            WorkspaceCreateActionReportV1::StateConflict {
                expected, actual, ..
            } => WorkspaceCreateFailureV1::StateConflict {
                expected: *expected,
                actual: *actual,
            },
            WorkspaceCreateActionReportV1::WriteFailed { .. } => {
                WorkspaceCreateFailureV1::WriteFailed
            }
            WorkspaceCreateActionReportV1::Success { .. } => unreachable!(),
        };
        self.stage = WorkspaceCreateStageV1::Terminal;
        Ok(WorkspaceCreateDirectiveV1::Failed { failure })
    }
}

impl WorkspaceDeleteTransactionStateV1 {
    fn directive(&self) -> Result<WorkspaceDeleteDirectiveV1, WorkspaceWorkingJournalError> {
        match self.stage {
            WorkspaceDeleteStageV1::Publication => Ok(WorkspaceDeleteDirectiveV1::Action {
                action_id: 1,
                request_digest: self.request_digest.clone(),
                kind: WorkspaceDeleteActionKindV1::PublishCatalog,
                expected_raw_catalog_digest: self.expected_raw_catalog_digest.clone(),
                canonical_bytes: self.catalog.canonical_bytes.clone(),
                content_digest: self.catalog.content_digest.clone(),
                logical_expected_revision: self.expected_catalog_revision,
                authority_receipt: self.receipt.clone(),
            }),
            WorkspaceDeleteStageV1::Terminal => self
                .last_result
                .clone()
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction),
            WorkspaceDeleteStageV1::Closed => Err(WorkspaceWorkingJournalError::InvalidTransaction),
        }
    }

    fn advance(
        &mut self,
        report: &WorkspaceDeleteActionReportV1,
    ) -> Result<WorkspaceDeleteDirectiveV1, WorkspaceWorkingJournalError> {
        let result = match report {
            WorkspaceDeleteActionReportV1::Success { written_digest, .. } => {
                if written_digest != &self.catalog.content_digest {
                    return Err(WorkspaceWorkingJournalError::InvalidTransaction);
                }
                WorkspaceDeleteDirectiveV1::Committed {
                    receipt: self.receipt.clone(),
                }
            }
            WorkspaceDeleteActionReportV1::Cancelled { .. } => WorkspaceDeleteDirectiveV1::Failed {
                failure: WorkspaceDeleteFailureV1::Cancelled,
            },
            WorkspaceDeleteActionReportV1::StateConflict {
                expected, actual, ..
            } => WorkspaceDeleteDirectiveV1::Failed {
                failure: WorkspaceDeleteFailureV1::StateConflict {
                    expected: *expected,
                    actual: *actual,
                },
            },
            WorkspaceDeleteActionReportV1::WriteFailed { .. } => {
                WorkspaceDeleteDirectiveV1::Failed {
                    failure: WorkspaceDeleteFailureV1::WriteFailed,
                }
            }
        };
        self.stage = WorkspaceDeleteStageV1::Terminal;
        Ok(result)
    }
}

impl WorkspaceJournalMutationTransactionStateV1 {
    fn action_id(&self) -> Result<u64, WorkspaceWorkingJournalError> {
        match self.stage {
            WorkspaceJournalMutationStageV1::Journal => Ok(1),
            WorkspaceJournalMutationStageV1::SavedRevision => Ok(2),
            WorkspaceJournalMutationStageV1::Terminal | WorkspaceJournalMutationStageV1::Closed => {
                Err(WorkspaceWorkingJournalError::InvalidTransaction)
            }
        }
    }

    fn directive(
        &self,
    ) -> Result<WorkspaceJournalMutationDirectiveV1, WorkspaceWorkingJournalError> {
        match self.stage {
            WorkspaceJournalMutationStageV1::Journal => {
                Ok(WorkspaceJournalMutationDirectiveV1::Action {
                    action_id: 1,
                    request_digest: self.request_digest.clone(),
                    kind: WorkspaceJournalMutationActionKindV1::WriteJournal,
                    expected_raw_journal_digest: self.raw_journal_digest.clone(),
                    canonical_bytes: self.committed.canonical_bytes.clone(),
                    content_digest: self.committed.content_digest.clone(),
                    logical_expected_revision: Some(self.expected_working_revision),
                    authority_receipt: Some(self.receipt.clone()),
                    post_authority_success_finalization: Some(if self.saved_revision.is_some() {
                        WorkspaceJournalMutationFinalizationV1::RevisionSidecarMissing
                    } else {
                        WorkspaceJournalMutationFinalizationV1::Finalized
                    }),
                    post_authority_failure_finalization: None,
                })
            }
            WorkspaceJournalMutationStageV1::SavedRevision => {
                let saved_revision = self
                    .saved_revision
                    .as_ref()
                    .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
                Ok(WorkspaceJournalMutationDirectiveV1::Action {
                    action_id: 2,
                    request_digest: self.request_digest.clone(),
                    kind: WorkspaceJournalMutationActionKindV1::WriteSavedRevision,
                    expected_raw_journal_digest: None,
                    canonical_bytes: saved_revision.canonical_bytes.clone(),
                    content_digest: saved_revision.content_digest.clone(),
                    logical_expected_revision: None,
                    authority_receipt: None,
                    post_authority_success_finalization: Some(
                        WorkspaceJournalMutationFinalizationV1::Finalized,
                    ),
                    post_authority_failure_finalization: Some(
                        WorkspaceJournalMutationFinalizationV1::RevisionSidecarMissing,
                    ),
                })
            }
            WorkspaceJournalMutationStageV1::Terminal => self
                .last_result
                .clone()
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction),
            WorkspaceJournalMutationStageV1::Closed => {
                Err(WorkspaceWorkingJournalError::InvalidTransaction)
            }
        }
    }

    fn advance(
        &mut self,
        report: &WorkspaceJournalMutationActionReportV1,
    ) -> Result<WorkspaceJournalMutationDirectiveV1, WorkspaceWorkingJournalError> {
        if let WorkspaceJournalMutationActionReportV1::Success { written_digest, .. } = report {
            let expected = match self.stage {
                WorkspaceJournalMutationStageV1::Journal => &self.committed.content_digest,
                WorkspaceJournalMutationStageV1::SavedRevision => {
                    &self
                        .saved_revision
                        .as_ref()
                        .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?
                        .content_digest
                }
                WorkspaceJournalMutationStageV1::Terminal
                | WorkspaceJournalMutationStageV1::Closed => {
                    return Err(WorkspaceWorkingJournalError::InvalidTransaction);
                }
            };
            if written_digest != expected {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            self.stage = match self.stage {
                WorkspaceJournalMutationStageV1::Journal if self.saved_revision.is_some() => {
                    WorkspaceJournalMutationStageV1::SavedRevision
                }
                WorkspaceJournalMutationStageV1::Journal
                | WorkspaceJournalMutationStageV1::SavedRevision => {
                    WorkspaceJournalMutationStageV1::Terminal
                }
                WorkspaceJournalMutationStageV1::Terminal
                | WorkspaceJournalMutationStageV1::Closed => unreachable!(),
            };
            let result = if matches!(self.stage, WorkspaceJournalMutationStageV1::Terminal) {
                WorkspaceJournalMutationDirectiveV1::Committed {
                    receipt: self.receipt.clone(),
                    finalization: WorkspaceJournalMutationFinalizationV1::Finalized,
                }
            } else {
                self.directive()?
            };
            if matches!(self.stage, WorkspaceJournalMutationStageV1::Terminal) {
                self.last_result = Some(result.clone());
            }
            return Ok(result);
        }

        let failure = match report {
            WorkspaceJournalMutationActionReportV1::Cancelled { .. } => {
                WorkspaceSaveFailureV1::Cancelled
            }
            WorkspaceJournalMutationActionReportV1::StateConflict {
                expected, actual, ..
            } => WorkspaceSaveFailureV1::StateConflict {
                expected: *expected,
                actual: *actual,
            },
            WorkspaceJournalMutationActionReportV1::WriteFailed { .. } => {
                WorkspaceSaveFailureV1::WriteFailed
            }
            WorkspaceJournalMutationActionReportV1::Success { .. } => unreachable!(),
        };
        let result = match self.stage {
            WorkspaceJournalMutationStageV1::Journal => {
                WorkspaceJournalMutationDirectiveV1::Failed { failure }
            }
            WorkspaceJournalMutationStageV1::SavedRevision => {
                WorkspaceJournalMutationDirectiveV1::Committed {
                    receipt: self.receipt.clone(),
                    finalization: WorkspaceJournalMutationFinalizationV1::RevisionSidecarMissing,
                }
            }
            WorkspaceJournalMutationStageV1::Terminal | WorkspaceJournalMutationStageV1::Closed => {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        };
        self.stage = WorkspaceJournalMutationStageV1::Terminal;
        self.last_result = Some(result.clone());
        Ok(result)
    }
}

impl WorkspaceSaveTransactionStateV1 {
    fn action_id(&self) -> Result<u64, WorkspaceWorkingJournalError> {
        match self.stage {
            WorkspaceSaveStageV1::Pending => Ok(1),
            WorkspaceSaveStageV1::Document => Ok(2),
            WorkspaceSaveStageV1::CommittedJournal => Ok(3),
            WorkspaceSaveStageV1::SavedRevision => Ok(4),
            WorkspaceSaveStageV1::Terminal | WorkspaceSaveStageV1::Closed => {
                Err(WorkspaceWorkingJournalError::InvalidTransaction)
            }
        }
    }

    fn directive(&self) -> Result<WorkspaceSaveDirectiveV1, WorkspaceWorkingJournalError> {
        match self.stage {
            WorkspaceSaveStageV1::Pending => Ok(self.action(
                1,
                WorkspaceSaveActionKindV1::WritePendingJournal,
                self.raw_journal_digest.clone(),
                self.pending.canonical_bytes.clone(),
                self.pending.content_digest.clone(),
                Some(self.expected_working_revision),
                None,
            )),
            WorkspaceSaveStageV1::Document => Ok(self.action(
                2,
                WorkspaceSaveActionKindV1::PublishWorkspaceDocument,
                None,
                self.document_bytes.clone(),
                self.document_digest.clone(),
                None,
                Some(self.receipt.clone()),
            )),
            WorkspaceSaveStageV1::CommittedJournal => Ok(self.action(
                3,
                WorkspaceSaveActionKindV1::WriteCommittedJournal,
                Some(self.pending.content_digest.clone()),
                self.committed.canonical_bytes.clone(),
                self.committed.content_digest.clone(),
                Some(self.expected_working_revision),
                None,
            )),
            WorkspaceSaveStageV1::SavedRevision => Ok(self.action(
                4,
                WorkspaceSaveActionKindV1::WriteSavedRevision,
                None,
                self.saved_revision.canonical_bytes.clone(),
                self.saved_revision.content_digest.clone(),
                None,
                None,
            )),
            WorkspaceSaveStageV1::Terminal => self
                .last_result
                .clone()
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction),
            WorkspaceSaveStageV1::Closed => Err(WorkspaceWorkingJournalError::InvalidTransaction),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn action(
        &self,
        action_id: u64,
        kind: WorkspaceSaveActionKindV1,
        expected_raw_journal_digest: Option<String>,
        canonical_bytes: Vec<u8>,
        content_digest: String,
        logical_expected_revision: Option<u64>,
        authority_receipt: Option<WorkspaceSaveCommitReceiptV1>,
    ) -> WorkspaceSaveDirectiveV1 {
        let (post_authority_success_finalization, post_authority_failure_finalization) = match kind
        {
            WorkspaceSaveActionKindV1::WritePendingJournal => (None, None),
            WorkspaceSaveActionKindV1::PublishWorkspaceDocument => (
                Some(WorkspaceSaveFinalizationV1::PendingJournalRetained),
                None,
            ),
            WorkspaceSaveActionKindV1::WriteCommittedJournal => (
                Some(WorkspaceSaveFinalizationV1::RevisionSidecarMissing),
                Some(WorkspaceSaveFinalizationV1::PendingJournalRetained),
            ),
            WorkspaceSaveActionKindV1::WriteSavedRevision => (
                Some(WorkspaceSaveFinalizationV1::Finalized),
                Some(WorkspaceSaveFinalizationV1::RevisionSidecarMissing),
            ),
        };
        WorkspaceSaveDirectiveV1::Action {
            action_id,
            request_digest: self.request_digest.clone(),
            kind,
            expected_raw_journal_digest,
            canonical_bytes,
            content_digest,
            logical_expected_revision,
            authority_receipt,
            post_authority_success_finalization,
            post_authority_failure_finalization,
        }
    }

    fn advance(
        &mut self,
        report: &WorkspaceSaveActionReportV1,
    ) -> Result<WorkspaceSaveDirectiveV1, WorkspaceWorkingJournalError> {
        if let WorkspaceSaveActionReportV1::Success { written_digest, .. } = report {
            let expected = match self.stage {
                WorkspaceSaveStageV1::Pending => &self.pending.content_digest,
                WorkspaceSaveStageV1::Document => &self.document_digest,
                WorkspaceSaveStageV1::CommittedJournal => &self.committed.content_digest,
                WorkspaceSaveStageV1::SavedRevision => &self.saved_revision.content_digest,
                WorkspaceSaveStageV1::Terminal | WorkspaceSaveStageV1::Closed => {
                    return Err(WorkspaceWorkingJournalError::InvalidTransaction);
                }
            };
            if written_digest != expected {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            self.stage = match self.stage {
                WorkspaceSaveStageV1::Pending => WorkspaceSaveStageV1::Document,
                WorkspaceSaveStageV1::Document => WorkspaceSaveStageV1::CommittedJournal,
                WorkspaceSaveStageV1::CommittedJournal => WorkspaceSaveStageV1::SavedRevision,
                WorkspaceSaveStageV1::SavedRevision => WorkspaceSaveStageV1::Terminal,
                WorkspaceSaveStageV1::Terminal | WorkspaceSaveStageV1::Closed => unreachable!(),
            };
            let result = if matches!(self.stage, WorkspaceSaveStageV1::Terminal) {
                WorkspaceSaveDirectiveV1::Committed {
                    receipt: self.receipt.clone(),
                    finalization: WorkspaceSaveFinalizationV1::Finalized,
                }
            } else {
                self.directive()?
            };
            if matches!(self.stage, WorkspaceSaveStageV1::Terminal) {
                self.last_result = Some(result.clone());
            }
            return Ok(result);
        }

        let failure = match report {
            WorkspaceSaveActionReportV1::Cancelled { .. } => WorkspaceSaveFailureV1::Cancelled,
            WorkspaceSaveActionReportV1::StateConflict {
                expected, actual, ..
            } => WorkspaceSaveFailureV1::StateConflict {
                expected: *expected,
                actual: *actual,
            },
            WorkspaceSaveActionReportV1::WriteFailed { .. } => WorkspaceSaveFailureV1::WriteFailed,
            WorkspaceSaveActionReportV1::Success { .. } => unreachable!(),
        };
        let result = match self.stage {
            WorkspaceSaveStageV1::Pending | WorkspaceSaveStageV1::Document => {
                WorkspaceSaveDirectiveV1::Failed { failure }
            }
            WorkspaceSaveStageV1::CommittedJournal => WorkspaceSaveDirectiveV1::Committed {
                receipt: self.receipt.clone(),
                finalization: WorkspaceSaveFinalizationV1::PendingJournalRetained,
            },
            WorkspaceSaveStageV1::SavedRevision => WorkspaceSaveDirectiveV1::Committed {
                receipt: self.receipt.clone(),
                finalization: WorkspaceSaveFinalizationV1::RevisionSidecarMissing,
            },
            WorkspaceSaveStageV1::Terminal | WorkspaceSaveStageV1::Closed => {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        };
        self.stage = WorkspaceSaveStageV1::Terminal;
        self.last_result = Some(result.clone());
        Ok(result)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
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
        #[serde(rename = "operationID")]
        operation_id: String,
        fingerprint: String,
        updated_at: Value,
    },
    Unchanged {
        expected_working_revision: u64,
        #[serde(rename = "operationID")]
        operation_id: String,
        fingerprint: String,
        updated_at: Value,
    },
    Working {
        expected_working_revision: u64,
        #[serde(rename = "operationID")]
        operation_id: Option<String>,
        fingerprint: Option<String>,
        updated_at: Value,
    },
    Save {
        expected_working_revision: u64,
        #[serde(rename = "operationID")]
        operation_id: String,
        fingerprint: String,
        updated_at: Value,
    },
    ExternalReload {
        expected_working_revision: u64,
        #[serde(rename = "operationID")]
        operation_id: Option<String>,
        fingerprint: Option<String>,
        updated_at: Value,
    },
    ConflictRebase {
        expected_revisions: WorkspaceProjectionRevisionState,
        external_saved_digest: String,
        #[serde(rename = "operationID")]
        operation_id: Option<String>,
        fingerprint: Option<String>,
        updated_at: Value,
    },
}

#[allow(clippy::too_many_arguments)]
pub fn prepare_workspace_create_transaction_v1(
    raw_catalog_bytes: Option<&[u8]>,
    effective_catalog_bytes: &[u8],
    raw_journal_bytes: Option<&[u8]>,
    effective_journal_bytes: Option<&[u8]>,
    request_bytes: &[u8],
    document_bytes: &[u8],
) -> Result<PreparedWorkspaceCreateTransactionV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(request_bytes)?;
    require_metadata_input_bound(effective_catalog_bytes)?;
    if document_bytes.len() > MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: document_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
        });
    }

    let request: WorkspaceCreateTransactionRequestV1 = serde_json::from_slice(request_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let effective_catalog = validate_workspace_catalog_v1(effective_catalog_bytes)?;
    let expected_raw_catalog_digest =
        exact_raw_catalog_digest(raw_catalog_bytes, &effective_catalog)?;
    let catalog_document: WorkspaceCatalogV1 =
        serde_json::from_slice(&effective_catalog.canonical_bytes)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let projection = project_workspace_document_v1(document_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
    let document_digest = format!("{:x}", Sha256::digest(document_bytes));

    let (
        expected_workspace_id,
        expected_file_url,
        expected_catalog_revision,
        operation_id,
        committed_journal,
        pending,
        saved_revision,
        raw_journal_digest,
        updated_at,
        recovery,
    ) = match request.clone() {
        WorkspaceCreateTransactionRequestV1::Create {
            semantic_planner_version,
            expected_workspace_id,
            expected_file_url,
            expected_catalog_revision,
            operation_id,
            fingerprint,
            updated_at,
        } => {
            if semantic_planner_version != WORKSPACE_SEMANTIC_PLANNER_VERSION_V1 {
                return Err(WorkspaceWorkingJournalError::Malformed);
            }
            if raw_journal_bytes.is_some() || effective_journal_bytes.is_some() {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            let expected_workspace_id = canonical_uuid(&expected_workspace_id)
                .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
            let operation_id = canonical_uuid(&operation_id)
                .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
            if !valid_file_url(&expected_file_url) {
                return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
            }
            if effective_catalog.revision != expected_catalog_revision {
                return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
            }
            require_create_catalog_identity_absent(
                &catalog_document,
                &expected_workspace_id,
                &expected_file_url,
            )?;
            if projection.workspace_id != expected_workspace_id {
                return Err(WorkspaceWorkingJournalError::InvalidIdentity);
            }
            let expected_revision = WorkspaceProjectionRevisionState {
                working_revision: 1,
                saved_revision: 1,
                dirty_revision: None,
            };
            let expected_resulting_catalog_revision = expected_catalog_revision
                .checked_add(1)
                .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
            let transition = WorkspaceWorkingJournalTransitionRequestV1::Create {
                workspace_id: expected_workspace_id.clone(),
                file_url: expected_file_url.clone(),
                operation_id: operation_id.clone(),
                fingerprint,
                updated_at: updated_at.clone(),
            };
            let plan = plan_workspace_working_journal_transition_v1(
                None,
                &serde_json::to_vec(&transition)
                    .map_err(|_| WorkspaceWorkingJournalError::Malformed)?,
                Some(document_bytes),
                Some(expected_resulting_catalog_revision),
            )?;
            let committed = plan
                .committed
                .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
            let committed_document = parse_validated_journal(&committed.canonical_bytes)?;
            if committed_document.revisions != expected_revision
                || committed_document.saved_digest != document_digest
            {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            let saved_revision_request = WorkspaceSavedRevisionPlanRequestV1 {
                workspace_id: expected_workspace_id.clone(),
                saved_revision: 1,
                document_digest: document_digest.clone(),
                operation_id: operation_id.clone(),
                updated_at: updated_at.clone(),
            };
            let saved_revision = plan_workspace_saved_revision_record_v1(
                &serde_json::to_vec(&saved_revision_request)
                    .map_err(|_| WorkspaceWorkingJournalError::Malformed)?,
            )?;
            (
                expected_workspace_id,
                expected_file_url,
                expected_catalog_revision,
                operation_id,
                committed,
                Some(plan.primary),
                Some(saved_revision),
                None,
                updated_at,
                false,
            )
        }
        WorkspaceCreateTransactionRequestV1::Recover {
            expected_workspace_id,
            expected_file_url,
            expected_catalog_revision,
            updated_at,
        } => {
            let expected_workspace_id = canonical_uuid(&expected_workspace_id)
                .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
            if !valid_file_url(&expected_file_url) {
                return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
            }
            if effective_catalog.revision != expected_catalog_revision {
                return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
            }
            require_create_catalog_identity_absent(
                &catalog_document,
                &expected_workspace_id,
                &expected_file_url,
            )?;
            if projection.workspace_id != expected_workspace_id {
                return Err(WorkspaceWorkingJournalError::InvalidIdentity);
            }
            let raw_journal_bytes =
                raw_journal_bytes.ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
            let effective_journal_bytes =
                effective_journal_bytes.ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
            let raw_validation = validate_workspace_working_journal_v1(raw_journal_bytes)?;
            let effective_validation =
                validate_workspace_working_journal_v1(effective_journal_bytes)?;
            let effective = parse_validated_journal(&effective_validation.canonical_bytes)?;
            if effective.workspace_id != expected_workspace_id {
                return Err(WorkspaceWorkingJournalError::InvalidIdentity);
            }
            if effective.file_url != expected_file_url {
                return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
            }
            let recovered_pending_operation_id =
                if raw_validation.canonical_bytes != effective_validation.canonical_bytes {
                    let raw = parse_validated_journal(&raw_validation.canonical_bytes)?;
                    let pending_operation_id = raw
                        .pending_save
                        .as_ref()
                        .and_then(|pending| canonical_uuid(&pending.operation_id))
                        .ok_or(WorkspaceWorkingJournalError::InvalidPendingSave)?;
                    match resolve_workspace_pending_save_v1(
                        raw_journal_bytes,
                        &expected_workspace_id,
                        &expected_file_url,
                        Some(document_bytes),
                    )? {
                        WorkspacePendingSaveRecoveryV1::Committed { clean_journal, .. }
                            if clean_journal.canonical_bytes
                                == effective_validation.canonical_bytes => {}
                        _ => return Err(WorkspaceWorkingJournalError::InvalidTransaction),
                    }
                    Some(pending_operation_id)
                } else {
                    None
                };
            let initial_revisions = WorkspaceProjectionRevisionState {
                working_revision: 1,
                saved_revision: 1,
                dirty_revision: None,
            };
            if effective.pending_save.is_some()
                || effective.working_document.is_some()
                || effective.revisions != initial_revisions
                || effective.saved_digest != document_digest
                || effective.operations.len() != 1
            {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            require_create_context_tables(
                document_bytes,
                &projection,
                &effective.context_revisions,
                &effective.context_digests,
            )?;
            let expected_resulting_catalog_revision = expected_catalog_revision
                .checked_add(1)
                .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
            let marker = effective
                .operations
                .iter()
                .find(|operation| {
                    operation.disposition == "applied"
                        && operation.before.is_none()
                        && operation.after == Some(effective.revisions)
                        && operation.catalog_revision == expected_resulting_catalog_revision
                        && operation.resulting_digest.as_deref() == Some(document_digest.as_str())
                        && operation.error_code.is_none()
                        && operation.diagnostic.is_none()
                })
                .ok_or(WorkspaceWorkingJournalError::InvalidOperationLedger)?;
            let operation_id = canonical_uuid(&marker.operation_id)
                .ok_or(WorkspaceWorkingJournalError::InvalidOperationLedger)?;
            if recovered_pending_operation_id
                .is_some_and(|pending_operation_id| pending_operation_id != operation_id)
            {
                return Err(WorkspaceWorkingJournalError::InvalidPendingSave);
            }
            (
                expected_workspace_id,
                expected_file_url,
                expected_catalog_revision,
                operation_id,
                effective_validation,
                None,
                None,
                Some(format!("{:x}", Sha256::digest(raw_journal_bytes))),
                updated_at,
                true,
            )
        }
    };

    let transition = WorkspaceCatalogTransitionRequestV1::Upsert {
        expected_catalog_revision,
        workspace_id: expected_workspace_id.clone(),
        file_url: expected_file_url.clone(),
        updated_at,
    };
    let catalog = plan_workspace_catalog_transition_v1(
        Some(&effective_catalog.canonical_bytes),
        &serde_json::to_vec(&transition).map_err(|_| WorkspaceWorkingJournalError::Malformed)?,
    )?;
    let canonical_request =
        serde_json::to_vec(&request).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let request_digest = create_transaction_request_digest(
        &canonical_request,
        raw_catalog_bytes,
        &effective_catalog.canonical_bytes,
        raw_journal_bytes,
        effective_journal_bytes,
        document_bytes,
    );
    let admission_finalization = if recovery {
        None
    } else {
        let committed = parse_validated_journal(&committed_journal.canonical_bytes)?;
        let operation = committed
            .operations
            .iter()
            .find(|operation| operation.operation_id == operation_id)
            .cloned()
            .ok_or(WorkspaceWorkingJournalError::InvalidOperationLedger)?;
        Some(WorkspaceCommandAdmissionFinalizationV1::Workspace {
            workspace_id: expected_workspace_id.clone(),
            operation,
        })
    };
    let receipt = WorkspaceCreateCommitReceiptV1 {
        workspace_id: expected_workspace_id,
        operation_id,
        request_digest: request_digest.clone(),
        document_digest: document_digest.clone(),
        catalog: catalog.clone(),
        committed_journal: committed_journal.clone(),
        saved_revision: saved_revision.clone(),
    };
    Ok(PreparedWorkspaceCreateTransactionV1 {
        inner: Mutex::new(WorkspaceCreateTransactionStateV1 {
            request_digest,
            expected_raw_catalog_digest,
            expected_catalog_revision,
            raw_journal_digest,
            pending,
            document_bytes: document_bytes.to_vec(),
            document_digest,
            committed_journal,
            saved_revision,
            catalog,
            receipt,
            admission_finalization,
            stage: if recovery {
                WorkspaceCreateStageV1::Catalog { action_id: 1 }
            } else {
                WorkspaceCreateStageV1::PendingJournal
            },
            last_report: None,
            last_result: None,
        }),
    })
}

fn exact_raw_catalog_digest(
    raw_catalog_bytes: Option<&[u8]>,
    effective_catalog: &WorkspaceCatalogValidationV1,
) -> Result<Option<String>, WorkspaceWorkingJournalError> {
    match raw_catalog_bytes {
        Some(bytes) => {
            require_metadata_input_bound(bytes)?;
            let raw_catalog = validate_workspace_catalog_v1(bytes)?;
            if raw_catalog.canonical_bytes != effective_catalog.canonical_bytes {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            Ok(Some(format!("{:x}", Sha256::digest(bytes))))
        }
        None if effective_catalog.revision == 0 => Ok(None),
        None => Err(WorkspaceWorkingJournalError::InvalidTransaction),
    }
}

fn require_create_catalog_identity_absent(
    catalog: &WorkspaceCatalogV1,
    workspace_id: &str,
    file_url: &str,
) -> Result<(), WorkspaceWorkingJournalError> {
    if catalog
        .entries
        .iter()
        .any(|entry| entry.workspace_id == workspace_id)
    {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    if let Some(tombstone) = catalog.deletions.as_ref().and_then(|deletions| {
        deletions
            .iter()
            .find(|value| value.workspace_id == workspace_id)
    }) {
        if tombstone.file_url != file_url {
            return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
        }
        let operation = &tombstone.operation;
        if operation.disposition != "applied"
            || operation.before.is_none()
            || operation.after.is_some()
            || operation.catalog_revision != catalog.revision
            || operation.resulting_digest.is_some()
            || operation.error_code.is_some()
            || operation
                .diagnostic
                .as_ref()
                .is_some_and(|diagnostic| !diagnostic.starts_with("artifact_cleanup_incomplete: "))
        {
            return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
        }
    }
    Ok(())
}

fn require_create_context_tables(
    document_bytes: &[u8],
    projection: &crate::workspace_context::WorkspaceDocumentProjection,
    context_revisions: &Value,
    context_digests: &Value,
) -> Result<(), WorkspaceWorkingJournalError> {
    let (revision_ids, _) = normalize_uuid_dictionary(context_revisions, |value| {
        serde_json::from_value::<WorkspaceProjectionRevisionState>(value.clone()).is_ok_and(
            |revisions| {
                revisions
                    == WorkspaceProjectionRevisionState {
                        working_revision: 1,
                        saved_revision: 1,
                        dirty_revision: None,
                    }
            },
        )
    })?;
    let (digest_ids, canonical_digests) = normalize_uuid_dictionary(context_digests, |value| {
        value.as_str().is_some_and(is_sha256_digest)
    })?;
    let projection_ids: BTreeSet<String> = projection
        .contexts
        .iter()
        .map(|context| context.context_id.clone())
        .collect();
    if revision_ids != digest_ids || revision_ids != projection_ids {
        return Err(WorkspaceWorkingJournalError::InvalidContextTable);
    }

    let document: Value = serde_json::from_slice(document_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
    let raw_contexts = document
        .as_object()
        .and_then(|object| object.get("composeTabs"))
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let mut computed_digests = BTreeMap::new();
    for raw_context in raw_contexts {
        let context_id = raw_context
            .as_object()
            .and_then(|context| context.get("id"))
            .and_then(Value::as_str)
            .and_then(canonical_uuid)
            .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?;
        let canonical_bytes =
            serde_json::to_vec(raw_context).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
        if computed_digests
            .insert(context_id, format!("{:x}", Sha256::digest(canonical_bytes)))
            .is_some()
        {
            return Err(WorkspaceWorkingJournalError::InvalidContextTable);
        }
    }
    let supplied_pairs = canonical_digests
        .as_array()
        .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)?;
    let supplied_digests: BTreeMap<&str, &str> = supplied_pairs
        .chunks_exact(2)
        .map(|pair| {
            pair[0]
                .as_str()
                .zip(pair[1].as_str())
                .ok_or(WorkspaceWorkingJournalError::InvalidContextTable)
        })
        .collect::<Result<_, _>>()?;
    if computed_digests.len() != supplied_digests.len()
        || computed_digests.iter().any(|(context_id, digest)| {
            supplied_digests.get(context_id.as_str()).copied() != Some(digest.as_str())
        })
    {
        return Err(WorkspaceWorkingJournalError::InvalidDigest);
    }
    Ok(())
}

fn context_digest_map_v1(value: &Value) -> Option<BTreeMap<String, String>> {
    let pairs = value.as_array()?;
    let mut map = BTreeMap::new();
    for pair in pairs.chunks_exact(2) {
        let context_id = canonical_uuid(pair.first()?.as_str()?)?;
        let digest = pair.get(1)?.as_str()?.to_owned();
        map.insert(context_id, digest);
    }
    (pairs.len() % 2 == 0).then_some(map)
}

fn changed_context_id_v1(
    before: &WorkspaceWorkingJournalV1,
    after: &WorkspaceWorkingJournalV1,
) -> Option<String> {
    let before = context_digest_map_v1(&before.context_digests)?;
    let after = context_digest_map_v1(&after.context_digests)?;
    let changed = before
        .keys()
        .chain(after.keys())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .filter(|context_id| before.get(*context_id) != after.get(*context_id))
        .cloned()
        .collect::<Vec<_>>();
    (changed.len() == 1).then(|| changed[0].clone())
}

fn added_command_admission_operation(
    effective: &WorkspaceWorkingJournalV1,
    committed: &WorkspaceWorkingJournalV1,
) -> Result<Option<WorkspaceRecordedOperationV1>, WorkspaceWorkingJournalError> {
    let existing = effective
        .operations
        .iter()
        .map(|operation| operation.operation_id.as_str())
        .collect::<BTreeSet<_>>();
    let mut added = committed
        .operations
        .iter()
        .filter(|operation| !existing.contains(operation.operation_id.as_str()))
        .cloned();
    let operation = added.next();
    if added.next().is_some() {
        return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
    }
    Ok(operation)
}

pub fn prepare_workspace_journal_mutation_transaction_v1(
    raw_journal_bytes: Option<&[u8]>,
    effective_journal_bytes: &[u8],
    request_bytes: &[u8],
    candidate_document_bytes: &[u8],
    disk_document_bytes: Option<&[u8]>,
) -> Result<PreparedWorkspaceJournalMutationTransactionV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(request_bytes)?;
    require_metadata_input_bound(effective_journal_bytes)?;
    if candidate_document_bytes.len() > MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: candidate_document_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
        });
    }
    if let Some(bytes) = disk_document_bytes
        && bytes.len() > MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1
    {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: bytes.len(),
            maximum: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
        });
    }

    let mut request: WorkspaceJournalMutationTransactionRequestV1 =
        serde_json::from_slice(request_bytes)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if request.semantic_planner_version != WORKSPACE_SEMANTIC_PLANNER_VERSION_V1 {
        return Err(WorkspaceWorkingJournalError::Malformed);
    }
    let operation_facts_present = match &request.transition {
        WorkspaceWorkingJournalTransitionRequestV1::Working {
            operation_id,
            fingerprint,
            ..
        }
        | WorkspaceWorkingJournalTransitionRequestV1::ExternalReload {
            operation_id,
            fingerprint,
            ..
        }
        | WorkspaceWorkingJournalTransitionRequestV1::ConflictRebase {
            operation_id,
            fingerprint,
            ..
        } => match (operation_id, fingerprint) {
            (None, None) => false,
            (Some(_), Some(_)) => true,
            _ => return Err(WorkspaceWorkingJournalError::InvalidOperationLedger),
        },
        WorkspaceWorkingJournalTransitionRequestV1::Unchanged { .. } => true,
        WorkspaceWorkingJournalTransitionRequestV1::Seed { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::RecoverPending { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::Create { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::Save { .. } => false,
    };
    if request.recovery_mode == operation_facts_present {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    request.expected_workspace_id = canonical_uuid(&request.expected_workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    if !valid_file_url(&request.expected_file_url) {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    request.revision_operation_id = request
        .revision_operation_id
        .map(|value| canonical_uuid(&value).ok_or(WorkspaceWorkingJournalError::InvalidIdentity))
        .transpose()?;

    let effective_validation = validate_workspace_working_journal_v1(effective_journal_bytes)?;
    let effective = parse_validated_journal(&effective_validation.canonical_bytes)?;
    if effective.workspace_id != request.expected_workspace_id {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    if effective.file_url != request.expected_file_url {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }

    let (expected_working_revision, authority_publication_kind) = match &request.transition {
        WorkspaceWorkingJournalTransitionRequestV1::Unchanged {
            expected_working_revision,
            ..
        } => (
            *expected_working_revision,
            WorkspaceProjectionPublicationKind::OperationDeduplicated,
        ),
        WorkspaceWorkingJournalTransitionRequestV1::Working {
            expected_working_revision,
            ..
        } => (
            *expected_working_revision,
            WorkspaceProjectionPublicationKind::WorkingStateCommitted,
        ),
        WorkspaceWorkingJournalTransitionRequestV1::ExternalReload {
            expected_working_revision,
            ..
        } => (
            *expected_working_revision,
            WorkspaceProjectionPublicationKind::ExternalReloaded,
        ),
        WorkspaceWorkingJournalTransitionRequestV1::ConflictRebase {
            expected_revisions, ..
        } => (
            expected_revisions.working_revision,
            WorkspaceProjectionPublicationKind::WorkingStateCommitted,
        ),
        WorkspaceWorkingJournalTransitionRequestV1::Seed { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::RecoverPending { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::Create { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::Save { .. } => {
            return Err(WorkspaceWorkingJournalError::InvalidTransaction);
        }
    };
    require_working_revision(&effective, expected_working_revision)?;

    let raw_journal_digest = match raw_journal_bytes {
        Some(bytes) => {
            let raw_validation = validate_workspace_working_journal_v1(bytes)?;
            let raw = parse_validated_journal(&raw_validation.canonical_bytes)?;
            if raw.workspace_id != request.expected_workspace_id {
                return Err(WorkspaceWorkingJournalError::InvalidIdentity);
            }
            if raw.file_url != request.expected_file_url {
                return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
            }
            if raw_validation.canonical_bytes != effective_validation.canonical_bytes {
                match resolve_workspace_pending_save_v1(
                    bytes,
                    &request.expected_workspace_id,
                    &request.expected_file_url,
                    disk_document_bytes,
                )? {
                    WorkspacePendingSaveRecoveryV1::Committed { clean_journal, .. }
                        if clean_journal.canonical_bytes
                            == effective_validation.canonical_bytes => {}
                    WorkspacePendingSaveRecoveryV1::NoPending { .. }
                    | WorkspacePendingSaveRecoveryV1::PendingNotCommitted { .. }
                    | WorkspacePendingSaveRecoveryV1::Committed { .. } => {
                        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
                    }
                }
            }
            Some(format!("{:x}", Sha256::digest(bytes)))
        }
        None => None,
    };

    let projection = project_workspace_document_v1(candidate_document_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
    if projection.workspace_id != request.expected_workspace_id {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    let document_digest = format!("{:x}", Sha256::digest(candidate_document_bytes));
    let disk_digest = disk_document_bytes.map(|bytes| format!("{:x}", Sha256::digest(bytes)));
    let saved_revision_updated_at = match &request.transition {
        WorkspaceWorkingJournalTransitionRequestV1::ExternalReload { updated_at, .. } => {
            if disk_digest.as_deref() != Some(document_digest.as_str())
                || request.revision_operation_id.is_none()
            {
                return Err(WorkspaceWorkingJournalError::ExternalDocumentConflict);
            }
            Some(updated_at.clone())
        }
        WorkspaceWorkingJournalTransitionRequestV1::ConflictRebase {
            external_saved_digest,
            ..
        } => {
            if disk_digest.as_deref() != Some(external_saved_digest.as_str())
                || request.revision_operation_id.is_some()
            {
                return Err(WorkspaceWorkingJournalError::ExternalDocumentConflict);
            }
            None
        }
        WorkspaceWorkingJournalTransitionRequestV1::Unchanged { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::Working { .. } => {
            if request.revision_operation_id.is_some() {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            None
        }
        WorkspaceWorkingJournalTransitionRequestV1::Seed { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::RecoverPending { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::Create { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::Save { .. } => unreachable!(),
    };

    let transition_bytes = serde_json::to_vec(&request.transition)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let plan = plan_workspace_working_journal_transition_v1(
        Some(&effective_validation.canonical_bytes),
        &transition_bytes,
        Some(candidate_document_bytes),
        Some(request.catalog_revision),
    )?;
    if plan.committed.is_some() {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    let committed = plan.primary;
    let committed_journal = parse_validated_journal(&committed.canonical_bytes)?;
    let context_id = match &request.transition {
        WorkspaceWorkingJournalTransitionRequestV1::Working { .. } => {
            changed_context_id_v1(&effective, &committed_journal)
        }
        _ => None,
    };
    let saved_revision = match (
        saved_revision_updated_at,
        request.revision_operation_id.as_ref(),
    ) {
        (Some(updated_at), Some(operation_id)) => {
            let revision_request = WorkspaceSavedRevisionPlanRequestV1 {
                workspace_id: request.expected_workspace_id.clone(),
                saved_revision: committed_journal.revisions.saved_revision,
                document_digest: document_digest.clone(),
                operation_id: operation_id.clone(),
                updated_at,
            };
            Some(plan_workspace_saved_revision_record_v1(
                &serde_json::to_vec(&revision_request)
                    .map_err(|_| WorkspaceWorkingJournalError::Malformed)?,
            )?)
        }
        (None, None) => None,
        _ => return Err(WorkspaceWorkingJournalError::InvalidTransaction),
    };
    if saved_revision.is_some() && committed_journal.saved_digest != document_digest {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }

    let canonical_request =
        serde_json::to_vec(&request).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let request_digest = save_transaction_request_digest(
        &canonical_request,
        raw_journal_bytes,
        &effective_validation.canonical_bytes,
        candidate_document_bytes,
        disk_document_bytes,
    );
    let admission_finalization = added_command_admission_operation(&effective, &committed_journal)?
        .map(
            |operation| WorkspaceCommandAdmissionFinalizationV1::Workspace {
                workspace_id: request.expected_workspace_id.clone(),
                operation,
            },
        );
    let receipt = WorkspaceJournalMutationCommitReceiptV1 {
        workspace_id: request.expected_workspace_id,
        request_digest: request_digest.clone(),
        catalog_revision: request.catalog_revision,
        committed_journal: committed.clone(),
        saved_revision: saved_revision.clone(),
        resulting_working_revision: committed_journal.revisions.working_revision,
        resulting_saved_revision: committed_journal.revisions.saved_revision,
    };
    Ok(PreparedWorkspaceJournalMutationTransactionV1 {
        inner: Mutex::new(WorkspaceJournalMutationTransactionStateV1 {
            request_digest,
            raw_journal_digest,
            expected_working_revision,
            context_id,
            document_bytes: candidate_document_bytes.to_vec(),
            committed,
            saved_revision,
            receipt,
            admission_finalization,
            authority_publication_kind,
            stage: WorkspaceJournalMutationStageV1::Journal,
            last_report: None,
            last_result: None,
        }),
    })
}

pub fn prepare_workspace_save_transaction_v1(
    raw_journal_bytes: Option<&[u8]>,
    effective_journal_bytes: &[u8],
    request_bytes: &[u8],
    candidate_document_bytes: &[u8],
    disk_document_bytes: Option<&[u8]>,
) -> Result<PreparedWorkspaceSaveTransactionV1, WorkspaceWorkingJournalError> {
    if request_bytes.len() > MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: request_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1,
        });
    }
    if candidate_document_bytes.len() > MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: candidate_document_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
        });
    }
    if let Some(bytes) = disk_document_bytes
        && bytes.len() > MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1
    {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: bytes.len(),
            maximum: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
        });
    }

    let mut request: WorkspaceSaveTransactionRequestV1 = serde_json::from_slice(request_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if request.semantic_planner_version != WORKSPACE_SEMANTIC_PLANNER_VERSION_V1 {
        return Err(WorkspaceWorkingJournalError::Malformed);
    }
    request.expected_workspace_id = canonical_uuid(&request.expected_workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    request.operation_id = canonical_uuid(&request.operation_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    if !valid_file_url(&request.expected_file_url) {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }

    let effective_validation = validate_workspace_working_journal_v1(effective_journal_bytes)?;
    let effective = parse_validated_journal(&effective_validation.canonical_bytes)?;
    if effective.workspace_id != request.expected_workspace_id {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    if effective.file_url != request.expected_file_url {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    require_working_revision(&effective, request.expected_working_revision)?;

    let raw_journal_bytes =
        raw_journal_bytes.ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
    let raw_validation = validate_workspace_working_journal_v1(raw_journal_bytes)?;
    let raw = parse_validated_journal(&raw_validation.canonical_bytes)?;
    if raw.workspace_id != request.expected_workspace_id {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    if raw.file_url != request.expected_file_url {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    if raw_validation.canonical_bytes != effective_validation.canonical_bytes {
        match resolve_workspace_pending_save_v1(
            raw_journal_bytes,
            &request.expected_workspace_id,
            &request.expected_file_url,
            disk_document_bytes,
        )? {
            WorkspacePendingSaveRecoveryV1::Committed { clean_journal, .. }
                if clean_journal.canonical_bytes == effective_validation.canonical_bytes => {}
            WorkspacePendingSaveRecoveryV1::NoPending { .. }
            | WorkspacePendingSaveRecoveryV1::PendingNotCommitted { .. }
            | WorkspacePendingSaveRecoveryV1::Committed { .. } => {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
        }
    }
    let raw_journal_digest = Some(format!("{:x}", Sha256::digest(raw_journal_bytes)));

    let candidate_projection = project_workspace_document_v1(candidate_document_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
    if candidate_projection.workspace_id != request.expected_workspace_id {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    let document_digest = format!("{:x}", Sha256::digest(candidate_document_bytes));
    if let Some(disk_bytes) = disk_document_bytes {
        let disk_digest = format!("{:x}", Sha256::digest(disk_bytes));
        if disk_digest != effective.saved_digest && disk_digest != document_digest {
            return Err(WorkspaceWorkingJournalError::ExternalDocumentConflict);
        }
    }

    let save_transition = WorkspaceWorkingJournalTransitionRequestV1::Save {
        expected_working_revision: request.expected_working_revision,
        operation_id: request.operation_id.clone(),
        fingerprint: request.fingerprint.clone(),
        updated_at: request.updated_at.clone(),
    };
    let transition_bytes = serde_json::to_vec(&save_transition)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let plan = plan_workspace_working_journal_transition_v1(
        Some(&effective_validation.canonical_bytes),
        &transition_bytes,
        Some(candidate_document_bytes),
        Some(request.catalog_revision),
    )?;
    let committed = plan
        .committed
        .ok_or(WorkspaceWorkingJournalError::InvalidTransaction)?;
    let committed_journal = parse_validated_journal(&committed.canonical_bytes)?;
    let saved_revision_request = WorkspaceSavedRevisionPlanRequestV1 {
        workspace_id: request.expected_workspace_id.clone(),
        saved_revision: committed_journal.revisions.saved_revision,
        document_digest: document_digest.clone(),
        operation_id: request.operation_id.clone(),
        updated_at: request.updated_at.clone(),
    };
    let saved_revision = plan_workspace_saved_revision_record_v1(
        &serde_json::to_vec(&saved_revision_request)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?,
    )?;
    let canonical_request =
        serde_json::to_vec(&request).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let request_digest = save_transaction_request_digest(
        &canonical_request,
        Some(raw_journal_bytes),
        &effective_validation.canonical_bytes,
        candidate_document_bytes,
        disk_document_bytes,
    );
    let operation = committed_journal
        .operations
        .iter()
        .find(|operation| operation.operation_id == request.operation_id)
        .cloned()
        .ok_or(WorkspaceWorkingJournalError::InvalidOperationLedger)?;
    let admission_finalization = WorkspaceCommandAdmissionFinalizationV1::Workspace {
        workspace_id: request.expected_workspace_id.clone(),
        operation,
    };
    let receipt = WorkspaceSaveCommitReceiptV1 {
        workspace_id: request.expected_workspace_id,
        operation_id: request.operation_id,
        request_digest: request_digest.clone(),
        catalog_revision: request.catalog_revision,
        document_digest: document_digest.clone(),
        committed_journal: committed.clone(),
        saved_revision: saved_revision.clone(),
        resulting_working_revision: committed_journal.revisions.working_revision,
        resulting_saved_revision: committed_journal.revisions.saved_revision,
    };
    Ok(PreparedWorkspaceSaveTransactionV1 {
        inner: Mutex::new(WorkspaceSaveTransactionStateV1 {
            request_digest,
            raw_journal_digest,
            expected_working_revision: request.expected_working_revision,
            pending: plan.primary,
            document_bytes: candidate_document_bytes.to_vec(),
            document_digest,
            committed,
            saved_revision,
            receipt,
            admission_finalization,
            stage: WorkspaceSaveStageV1::Pending,
            last_report: None,
            last_result: None,
        }),
    })
}

pub fn prepare_workspace_delete_transaction_v1(
    raw_catalog_bytes: Option<&[u8]>,
    effective_catalog_bytes: &[u8],
    effective_journal_bytes: &[u8],
    request_bytes: &[u8],
) -> Result<PreparedWorkspaceDeleteTransactionV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(request_bytes)?;
    require_metadata_input_bound(effective_catalog_bytes)?;
    let mut request: WorkspaceDeleteTransactionRequestV1 = serde_json::from_slice(request_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if request.semantic_planner_version != WORKSPACE_SEMANTIC_PLANNER_VERSION_V1 {
        return Err(WorkspaceWorkingJournalError::Malformed);
    }
    request.expected_workspace_id = canonical_uuid(&request.expected_workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    request.operation_id = canonical_uuid(&request.operation_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    if !valid_file_url(&request.expected_file_url) {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }

    let effective_catalog = validate_workspace_catalog_v1(effective_catalog_bytes)?;
    if effective_catalog.revision != request.expected_catalog_revision {
        return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
    }
    let catalog_document: WorkspaceCatalogV1 =
        serde_json::from_slice(&effective_catalog.canonical_bytes)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let live_entry = catalog_document
        .entries
        .iter()
        .find(|entry| entry.workspace_id == request.expected_workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    if live_entry.file_url != request.expected_file_url {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    let expected_resulting_catalog_revision = request
        .expected_catalog_revision
        .checked_add(1)
        .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
    let expected_raw_catalog_digest = match raw_catalog_bytes {
        Some(bytes) => {
            require_metadata_input_bound(bytes)?;
            let raw_catalog = validate_workspace_catalog_v1(bytes)?;
            if raw_catalog.canonical_bytes != effective_catalog.canonical_bytes {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            Some(format!("{:x}", Sha256::digest(bytes)))
        }
        None => {
            if effective_catalog.revision != 0 {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            None
        }
    };

    let effective_journal = validate_workspace_working_journal_v1(effective_journal_bytes)?;
    let journal = parse_validated_journal(&effective_journal.canonical_bytes)?;
    if journal.workspace_id != request.expected_workspace_id {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    if journal.file_url != request.expected_file_url {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    require_working_revision(&journal, request.expected_working_revision)?;
    let operation = planned_operation_v1(
        request.operation_id.clone(),
        request.fingerprint.clone(),
        request.deleted_at.clone(),
        "applied",
        Some(journal.revisions),
        None,
        expected_resulting_catalog_revision,
        None,
    )?;

    let tombstone_request = WorkspaceDeletionTombstonePlanRequestV1 {
        workspace_id: request.expected_workspace_id.clone(),
        file_url: request.expected_file_url.clone(),
        operation: operation.clone(),
        deleted_at: request.deleted_at.clone(),
        cleanup_warnings: Vec::new(),
    };
    let tombstone = plan_workspace_deletion_tombstone_v1(
        &serde_json::to_vec(&tombstone_request)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?,
    )?;
    let parsed_tombstone: WorkspaceDeletionTombstoneV1 =
        serde_json::from_slice(&tombstone.canonical_bytes)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let transition = WorkspaceCatalogTransitionRequestV1::Delete {
        expected_catalog_revision: request.expected_catalog_revision,
        tombstone: parsed_tombstone,
        updated_at: request.deleted_at.clone(),
    };
    let catalog = plan_workspace_catalog_transition_v1(
        Some(&effective_catalog.canonical_bytes),
        &serde_json::to_vec(&transition).map_err(|_| WorkspaceWorkingJournalError::Malformed)?,
    )?;
    let canonical_request =
        serde_json::to_vec(&request).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let request_digest = delete_transaction_request_digest(
        &canonical_request,
        raw_catalog_bytes,
        &effective_catalog.canonical_bytes,
        &effective_journal.canonical_bytes,
    );
    let admission_finalization = WorkspaceCommandAdmissionFinalizationV1::Delete {
        workspace_id: request.expected_workspace_id.clone(),
        operation: operation.clone(),
    };
    let receipt = WorkspaceDeleteCommitReceiptV1 {
        workspace_id: request.expected_workspace_id,
        operation_id: tombstone.operation_id.clone(),
        request_digest: request_digest.clone(),
        catalog: catalog.clone(),
        tombstone,
    };
    Ok(PreparedWorkspaceDeleteTransactionV1 {
        inner: Mutex::new(WorkspaceDeleteTransactionStateV1 {
            request_digest,
            expected_raw_catalog_digest,
            expected_catalog_revision: request.expected_catalog_revision,
            catalog,
            receipt,
            admission_finalization,
            stage: WorkspaceDeleteStageV1::Publication,
            last_report: None,
            last_result: None,
        }),
    })
}

pub fn resolve_workspace_pending_save_v1(
    raw_journal_bytes: &[u8],
    expected_workspace_id: &str,
    expected_file_url: &str,
    document_bytes: Option<&[u8]>,
) -> Result<WorkspacePendingSaveRecoveryV1, WorkspaceWorkingJournalError> {
    let expected_workspace_id = canonical_uuid(expected_workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    if !valid_file_url(expected_file_url) {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    let journal = validate_workspace_working_journal_v1(raw_journal_bytes)?;
    let parsed = parse_validated_journal(&journal.canonical_bytes)?;
    if parsed.workspace_id != expected_workspace_id {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    if parsed.file_url != expected_file_url {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    let Some(pending) = parsed.pending_save.as_ref() else {
        return Ok(WorkspacePendingSaveRecoveryV1::NoPending { journal });
    };
    let Some(document_bytes) = document_bytes else {
        return Ok(WorkspacePendingSaveRecoveryV1::PendingNotCommitted { journal });
    };
    if document_bytes.len() > MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: document_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
        });
    }
    let document_digest = format!("{:x}", Sha256::digest(document_bytes));
    if document_digest != pending.document_digest {
        return Ok(WorkspacePendingSaveRecoveryV1::PendingNotCommitted { journal });
    }
    let projection = project_workspace_document_v1(document_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
    if projection.workspace_id != expected_workspace_id {
        return Err(WorkspaceWorkingJournalError::InvalidIdentity);
    }
    let transition = WorkspaceWorkingJournalTransitionRequestV1::RecoverPending {
        expected_workspace_id,
    };
    let transition_bytes =
        serde_json::to_vec(&transition).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let plan = plan_workspace_working_journal_transition_v1(
        Some(&journal.canonical_bytes),
        &transition_bytes,
        None,
        None,
    )?;
    if plan.committed.is_some() {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    Ok(WorkspacePendingSaveRecoveryV1::Committed {
        clean_journal: plan.primary,
        document_digest,
    })
}

fn create_transaction_request_digest(
    request_bytes: &[u8],
    raw_catalog_bytes: Option<&[u8]>,
    effective_catalog_bytes: &[u8],
    raw_journal_bytes: Option<&[u8]>,
    effective_journal_bytes: Option<&[u8]>,
    document_bytes: &[u8],
) -> String {
    fn append(hasher: &mut Sha256, bytes: Option<&[u8]>) {
        match bytes {
            Some(bytes) => {
                hasher.update([1]);
                hasher.update((bytes.len() as u64).to_be_bytes());
                hasher.update(bytes);
            }
            None => hasher.update([0]),
        }
    }
    let mut hasher = Sha256::new();
    append(&mut hasher, Some(request_bytes));
    append(&mut hasher, raw_catalog_bytes);
    append(&mut hasher, Some(effective_catalog_bytes));
    append(&mut hasher, raw_journal_bytes);
    append(&mut hasher, effective_journal_bytes);
    append(&mut hasher, Some(document_bytes));
    format!("{:x}", hasher.finalize())
}

fn save_transaction_request_digest(
    request_bytes: &[u8],
    raw_journal_bytes: Option<&[u8]>,
    effective_journal_bytes: &[u8],
    candidate_document_bytes: &[u8],
    disk_document_bytes: Option<&[u8]>,
) -> String {
    fn append(hasher: &mut Sha256, bytes: Option<&[u8]>) {
        match bytes {
            Some(bytes) => {
                hasher.update([1]);
                hasher.update((bytes.len() as u64).to_be_bytes());
                hasher.update(bytes);
            }
            None => hasher.update([0]),
        }
    }
    let mut hasher = Sha256::new();
    append(&mut hasher, Some(request_bytes));
    append(&mut hasher, raw_journal_bytes);
    append(&mut hasher, Some(effective_journal_bytes));
    append(&mut hasher, Some(candidate_document_bytes));
    append(&mut hasher, disk_document_bytes);
    format!("{:x}", hasher.finalize())
}

fn delete_transaction_request_digest(
    request_bytes: &[u8],
    raw_catalog_bytes: Option<&[u8]>,
    effective_catalog_bytes: &[u8],
    effective_journal_bytes: &[u8],
) -> String {
    fn append(hasher: &mut Sha256, bytes: Option<&[u8]>) {
        match bytes {
            Some(bytes) => {
                hasher.update([1]);
                hasher.update((bytes.len() as u64).to_be_bytes());
                hasher.update(bytes);
            }
            None => hasher.update([0]),
        }
    }
    let mut hasher = Sha256::new();
    append(&mut hasher, Some(request_bytes));
    append(&mut hasher, raw_catalog_bytes);
    append(&mut hasher, Some(effective_catalog_bytes));
    append(&mut hasher, Some(effective_journal_bytes));
    format!("{:x}", hasher.finalize())
}

pub fn seed_workspace_working_journal_v1(
    seed_request_bytes: &[u8],
) -> Result<WorkspaceWorkingJournalValidationV1, WorkspaceWorkingJournalError> {
    if seed_request_bytes.len() > MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: seed_request_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1,
        });
    }
    let request: WorkspaceWorkingJournalTransitionRequestV1 =
        serde_json::from_slice(seed_request_bytes)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if !matches!(
        request,
        WorkspaceWorkingJournalTransitionRequestV1::Seed { .. }
    ) {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    let plan = plan_workspace_working_journal_transition_v1(None, seed_request_bytes, None, None)?;
    if plan.committed.is_some() {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    Ok(plan.primary)
}

fn workspace_document_context_digests_from_bytes_v1(
    document_bytes: &[u8],
) -> Result<BTreeMap<String, String>, WorkspaceWorkingJournalError> {
    let projection = project_workspace_document_v1(document_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
    let document = WorkspaceRecoveredDocumentV1 {
        bytes: document_bytes.to_vec(),
        digest: format!("{:x}", Sha256::digest(document_bytes)),
        projection,
    };
    workspace_recovery_document_context_digests_v1(&document)
}

fn context_revision_map_v1(
    value: &Value,
) -> Result<BTreeMap<String, WorkspaceProjectionRevisionState>, WorkspaceWorkingJournalError> {
    Ok(workspace_recovery_context_revisions_v1(value)?
        .into_iter()
        .map(|entry| (entry.context_id, entry.revisions))
        .collect())
}

fn context_tombstone_map_v1(
    value: &Value,
) -> Result<BTreeMap<String, u64>, WorkspaceWorkingJournalError> {
    Ok(workspace_recovery_context_tombstones_v1(value)?
        .into_iter()
        .collect())
}

fn semantic_context_tables_v1(
    current: Option<&WorkspaceWorkingJournalV1>,
    document_bytes: &[u8],
    workspace_revisions: WorkspaceProjectionRevisionState,
    mode: WorkspaceSemanticContextPlanningModeV1,
) -> Result<(Value, Value, Value), WorkspaceWorkingJournalError> {
    let next_digests = workspace_document_context_digests_from_bytes_v1(document_bytes)?;
    let Some(current) = current else {
        let revisions = next_digests
            .keys()
            .map(|context_id| {
                (
                    context_id.clone(),
                    WorkspaceProjectionRevisionState {
                        working_revision: 1,
                        saved_revision: 1,
                        dirty_revision: None,
                    },
                )
            })
            .collect::<BTreeMap<_, _>>();
        return Ok((
            workspace_recovery_context_revisions_value_v1(&revisions)?,
            workspace_recovery_context_digests_value_v1(&next_digests),
            Value::Array(Vec::new()),
        ));
    };

    if matches!(mode, WorkspaceSemanticContextPlanningModeV1::Preserve) {
        return Ok((
            current.context_revisions.clone(),
            current.context_digests.clone(),
            current.context_tombstones.clone(),
        ));
    }

    let previous_revisions = context_revision_map_v1(&current.context_revisions)?;
    let previous_digests = workspace_recovery_context_digest_table_v1(&current.context_digests)?;
    let mut next_revisions = BTreeMap::new();
    let mut tombstones = context_tombstone_map_v1(&current.context_tombstones)?;
    for (context_id, digest) in &next_digests {
        let unchanged = previous_digests.get(context_id) == Some(digest);
        let previous = previous_revisions.get(context_id).copied();
        let revision = match mode {
            WorkspaceSemanticContextPlanningModeV1::Preserve => unreachable!(),
            WorkspaceSemanticContextPlanningModeV1::AdvanceWorkspace => {
                if unchanged {
                    previous.unwrap_or(WorkspaceProjectionRevisionState {
                        working_revision: workspace_revisions.working_revision,
                        saved_revision: workspace_revisions.saved_revision,
                        dirty_revision: None,
                    })
                } else {
                    let next_working = previous
                        .map(|revision| revision.working_revision)
                        .unwrap_or(0)
                        .checked_add(1)
                        .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
                    WorkspaceProjectionRevisionState {
                        working_revision: next_working,
                        saved_revision: previous
                            .map(|revision| revision.saved_revision)
                            .unwrap_or(0),
                        dirty_revision: Some(next_working),
                    }
                }
            }
            WorkspaceSemanticContextPlanningModeV1::CleanAtWorkingRevision => {
                clean_revision_state(previous.unwrap_or(workspace_revisions))
            }
            WorkspaceSemanticContextPlanningModeV1::CleanAtWorkspaceRevision => {
                if unchanged {
                    previous.unwrap_or_else(|| clean_revision_state(workspace_revisions))
                } else {
                    clean_revision_state(workspace_revisions)
                }
            }
        };
        next_revisions.insert(context_id.clone(), revision);
        tombstones.remove(context_id);
    }
    for context_id in previous_digests.keys() {
        if !next_digests.contains_key(context_id) {
            tombstones.insert(context_id.clone(), workspace_revisions.working_revision);
        }
    }
    Ok((
        workspace_recovery_context_revisions_value_v1(&next_revisions)?,
        workspace_recovery_context_digests_value_v1(&next_digests),
        workspace_recovery_context_tombstones_value_v1(&tombstones),
    ))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkspaceSemanticContextPlanningModeV1 {
    Preserve,
    AdvanceWorkspace,
    CleanAtWorkingRevision,
    CleanAtWorkspaceRevision,
}

fn planned_operation_v1(
    operation_id: String,
    fingerprint: String,
    updated_at: Value,
    disposition: &str,
    before: Option<WorkspaceProjectionRevisionState>,
    after: Option<WorkspaceProjectionRevisionState>,
    catalog_revision: u64,
    resulting_digest: Option<String>,
) -> Result<WorkspaceRecordedOperationV1, WorkspaceWorkingJournalError> {
    let recorded_at = updated_at
        .as_f64()
        .filter(|value| value.is_finite())
        .ok_or(WorkspaceWorkingJournalError::InvalidTimestamp)?;
    let mut operation = WorkspaceRecordedOperationV1 {
        operation_id,
        fingerprint,
        recorded_at,
        disposition: disposition.to_owned(),
        before,
        after,
        catalog_revision,
        resulting_digest,
        error_code: None,
        diagnostic: None,
    };
    validate_and_canonicalize_recorded_operation(&mut operation)?;
    Ok(operation)
}

fn append_planned_operation_v1(
    current: &WorkspaceWorkingJournalV1,
    operation: Option<WorkspaceRecordedOperationV1>,
    updated_at: &Value,
) -> Result<Vec<WorkspaceRecordedOperationV1>, WorkspaceWorkingJournalError> {
    let mut operations = current.operations.clone();
    if let Some(operation) = operation {
        if let Some(existing) = operations
            .iter()
            .find(|existing| existing.operation_id == operation.operation_id)
        {
            let same_semantics = existing.fingerprint == operation.fingerprint
                && existing.disposition == operation.disposition
                && existing.before == operation.before
                && existing.after == operation.after
                && existing.catalog_revision == operation.catalog_revision
                && existing.resulting_digest == operation.resulting_digest
                && existing.error_code == operation.error_code
                && existing.diagnostic == operation.diagnostic;
            if !same_semantics {
                return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
            }
        } else {
            operations.push(operation);
        }
    }
    trimmed_operations(operations, updated_at)
}

fn plan_workspace_working_journal_transition_v1(
    current_journal_bytes: Option<&[u8]>,
    transition_bytes: &[u8],
    document_bytes: Option<&[u8]>,
    catalog_revision: Option<u64>,
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
            operation_id,
            fingerprint,
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
            let clean_revisions = clean_revision_state(pending_revisions);
            let (context_revisions, context_digests, context_tombstones) =
                semantic_context_tables_v1(
                    None,
                    &decode_base64(&working_document)
                        .ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?,
                    clean_revisions,
                    WorkspaceSemanticContextPlanningModeV1::CleanAtWorkingRevision,
                )?;
            let operation = planned_operation_v1(
                operation_id.clone(),
                fingerprint,
                updated_at.clone(),
                "applied",
                None,
                Some(clean_revisions),
                catalog_revision.unwrap_or(0),
                Some(document_digest.clone()),
            )?;
            let pending = WorkspaceWorkingJournalV1 {
                version: WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
                workspace_id,
                file_url,
                revisions: pending_revisions,
                saved_digest: format!("{:x}", Sha256::digest([])),
                working_document: Some(working_document),
                context_revisions: context_revisions.clone(),
                context_digests: context_digests.clone(),
                context_tombstones,
                operations: vec![operation],
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
            operation_id,
            fingerprint,
            updated_at,
        } => {
            let mut current = require_current(current)?;
            require_working_revision(&current, expected_working_revision)?;
            let document_digest =
                document_digest.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let expected_document_digest = if current.revisions.dirty_revision.is_some() {
                let working_document = current
                    .working_document
                    .as_ref()
                    .and_then(|value| decode_base64(value))
                    .ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
                format!("{:x}", Sha256::digest(working_document))
            } else {
                current.saved_digest.clone()
            };
            if document_digest != expected_document_digest {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            let operation = planned_operation_v1(
                operation_id,
                fingerprint,
                updated_at.clone(),
                "unchanged",
                Some(current.revisions),
                Some(current.revisions),
                catalog_revision.unwrap_or(0),
                Some(document_digest),
            )?;
            current.operations =
                append_planned_operation_v1(&current, Some(operation), &updated_at)?;
            current.updated_at = updated_at;
            (current, None)
        }
        WorkspaceWorkingJournalTransitionRequestV1::Working {
            expected_working_revision,
            operation_id,
            fingerprint,
            updated_at,
        } => {
            let current = require_current(current)?;
            require_working_revision(&current, expected_working_revision)?;
            let working_document =
                working_document.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let next_revision = current
                .revisions
                .working_revision
                .checked_add(1)
                .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
            let new_revisions = WorkspaceProjectionRevisionState {
                working_revision: next_revision,
                saved_revision: current.revisions.saved_revision,
                dirty_revision: Some(next_revision),
            };
            let document_bytes = decode_base64(&working_document)
                .ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let (context_revisions, context_digests, context_tombstones) =
                semantic_context_tables_v1(
                    Some(&current),
                    &document_bytes,
                    new_revisions,
                    WorkspaceSemanticContextPlanningModeV1::AdvanceWorkspace,
                )?;
            let operation = match (operation_id, fingerprint) {
                (None, None) => None,
                (Some(operation_id), Some(fingerprint)) => Some(planned_operation_v1(
                    operation_id,
                    fingerprint,
                    updated_at.clone(),
                    "applied",
                    Some(current.revisions),
                    Some(new_revisions),
                    catalog_revision.unwrap_or(0),
                    document_digest.clone(),
                )?),
                _ => return Err(WorkspaceWorkingJournalError::InvalidOperationLedger),
            };
            let operations = append_planned_operation_v1(&current, operation, &updated_at)?;
            (
                WorkspaceWorkingJournalV1 {
                    version: current.version,
                    workspace_id: current.workspace_id,
                    file_url: current.file_url,
                    revisions: new_revisions,
                    saved_digest: current.saved_digest,
                    working_document: Some(working_document),
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
            fingerprint,
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
            let new_revisions = clean_revision_state(current.revisions);
            let (
                committed_context_revisions,
                committed_context_digests,
                committed_context_tombstones,
            ) = semantic_context_tables_v1(
                Some(&current),
                document_bytes.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?,
                new_revisions,
                WorkspaceSemanticContextPlanningModeV1::CleanAtWorkingRevision,
            )?;
            let operation = planned_operation_v1(
                operation_id.clone(),
                fingerprint,
                updated_at.clone(),
                "applied",
                Some(current.revisions),
                Some(new_revisions),
                catalog_revision.unwrap_or(0),
                Some(document_digest.clone()),
            )?;
            let operations = append_planned_operation_v1(&current, Some(operation), &updated_at)?;
            let pending = WorkspaceWorkingJournalV1 {
                version: current.version,
                workspace_id: current.workspace_id,
                file_url: current.file_url,
                revisions: current.revisions,
                saved_digest: current.saved_digest,
                working_document,
                context_revisions: current.context_revisions.clone(),
                context_digests: committed_context_digests.clone(),
                context_tombstones: current.context_tombstones.clone(),
                operations: operations.clone(),
                pending_save: Some(WorkspacePendingSaveV1 {
                    operation_id,
                    document_digest: document_digest.clone(),
                }),
                updated_at: updated_at.clone(),
            };
            let committed = WorkspaceWorkingJournalV1 {
                revisions: new_revisions,
                saved_digest: document_digest,
                working_document: None,
                context_revisions: committed_context_revisions,
                context_digests: committed_context_digests,
                context_tombstones: committed_context_tombstones,
                pending_save: None,
                ..pending.clone()
            };
            (pending, Some(committed))
        }
        WorkspaceWorkingJournalTransitionRequestV1::ExternalReload {
            expected_working_revision,
            operation_id,
            fingerprint,
            updated_at,
        } => {
            let current = require_current(current)?;
            require_working_revision(&current, expected_working_revision)?;
            let document_digest =
                document_digest.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let new_revision = current
                .revisions
                .working_revision
                .checked_add(1)
                .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
            let revisions = WorkspaceProjectionRevisionState {
                working_revision: new_revision,
                saved_revision: new_revision,
                dirty_revision: None,
            };
            let document_bytes =
                document_bytes.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let (context_revisions, context_digests, context_tombstones) =
                semantic_context_tables_v1(
                    Some(&current),
                    document_bytes,
                    revisions,
                    WorkspaceSemanticContextPlanningModeV1::CleanAtWorkspaceRevision,
                )?;
            let operation = match (operation_id, fingerprint) {
                (None, None) => None,
                (Some(operation_id), Some(fingerprint)) => Some(planned_operation_v1(
                    operation_id,
                    fingerprint,
                    updated_at.clone(),
                    "applied",
                    Some(current.revisions),
                    Some(revisions),
                    catalog_revision.unwrap_or(0),
                    Some(document_digest.clone()),
                )?),
                _ => return Err(WorkspaceWorkingJournalError::InvalidOperationLedger),
            };
            let operations = append_planned_operation_v1(&current, operation, &updated_at)?;
            (
                WorkspaceWorkingJournalV1 {
                    version: current.version,
                    workspace_id: current.workspace_id,
                    file_url: current.file_url,
                    revisions,
                    saved_digest: document_digest,
                    working_document: None,
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
        WorkspaceWorkingJournalTransitionRequestV1::ConflictRebase {
            expected_revisions,
            external_saved_digest,
            operation_id,
            fingerprint,
            updated_at,
        } => {
            let current = require_current(current)?;
            if current.revisions != expected_revisions {
                return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
            }
            let working_document =
                working_document.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let document_bytes = decode_base64(&working_document)
                .ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?;
            let candidate_digest = format!("{:x}", Sha256::digest(&document_bytes));
            let current_document_digest = current
                .working_document
                .as_deref()
                .and_then(decode_base64)
                .map(|bytes| format!("{:x}", Sha256::digest(bytes)));
            let advances = current_document_digest
                .as_deref()
                .map(|digest| digest != candidate_digest)
                .unwrap_or_else(|| current.saved_digest != candidate_digest);
            let new_revisions = if advances {
                let next_revision = current
                    .revisions
                    .working_revision
                    .checked_add(1)
                    .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
                WorkspaceProjectionRevisionState {
                    working_revision: next_revision,
                    saved_revision: current.revisions.saved_revision,
                    dirty_revision: Some(next_revision),
                }
            } else {
                current.revisions
            };
            let (context_revisions, context_digests, context_tombstones) =
                semantic_context_tables_v1(
                    Some(&current),
                    &document_bytes,
                    new_revisions,
                    if advances {
                        WorkspaceSemanticContextPlanningModeV1::AdvanceWorkspace
                    } else {
                        WorkspaceSemanticContextPlanningModeV1::Preserve
                    },
                )?;
            let operation = match (operation_id, fingerprint) {
                (None, None) => None,
                (Some(operation_id), Some(fingerprint)) => Some(planned_operation_v1(
                    operation_id,
                    fingerprint,
                    updated_at.clone(),
                    "applied",
                    Some(current.revisions),
                    Some(new_revisions),
                    catalog_revision.unwrap_or(0),
                    Some(candidate_digest),
                )?),
                _ => return Err(WorkspaceWorkingJournalError::InvalidOperationLedger),
            };
            let operations = append_planned_operation_v1(&current, operation, &updated_at)?;
            (
                WorkspaceWorkingJournalV1 {
                    version: current.version,
                    workspace_id: current.workspace_id,
                    file_url: current.file_url,
                    revisions: new_revisions,
                    saved_digest: external_saved_digest,
                    working_document: if new_revisions.dirty_revision.is_some() {
                        Some(working_document)
                    } else {
                        None
                    },
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

#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceDeleteCleanupPlanV1 {
    pub validation: WorkspacePersistenceMetadataValidationV1,
    pub operation: WorkspaceRecordedOperationV1,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
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

#[derive(Clone, Debug, Deserialize, Serialize)]
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

fn plan_workspace_saved_revision_record_v1(
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

fn plan_workspace_deletion_tombstone_v1(
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

pub fn validate_workspace_deletion_tombstone_v1(
    bytes: &[u8],
) -> Result<WorkspacePersistenceMetadataValidationV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(bytes)?;
    let tombstone: WorkspaceDeletionTombstoneV1 =
        serde_json::from_slice(bytes).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    canonicalize_deletion_tombstone(tombstone)
}

pub fn amend_workspace_deletion_tombstone_cleanup_v1(
    authoritative_tombstone_bytes: &[u8],
    cleanup_warnings_bytes: &[u8],
) -> Result<WorkspacePersistenceMetadataValidationV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(authoritative_tombstone_bytes)?;
    require_metadata_input_bound(cleanup_warnings_bytes)?;
    let total_input_bytes = authoritative_tombstone_bytes
        .len()
        .checked_add(cleanup_warnings_bytes.len())
        .unwrap_or(usize::MAX);
    if total_input_bytes > MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: total_input_bytes,
            maximum: MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1,
        });
    }
    let authoritative = validate_workspace_deletion_tombstone_v1(authoritative_tombstone_bytes)?;
    if authoritative.canonical_bytes.as_slice() != authoritative_tombstone_bytes {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    let mut tombstone: WorkspaceDeletionTombstoneV1 =
        serde_json::from_slice(&authoritative.canonical_bytes)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let cleanup_warnings: Vec<String> = serde_json::from_slice(cleanup_warnings_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if cleanup_warnings.is_empty() || cleanup_warnings.iter().any(String::is_empty) {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    tombstone.operation.diagnostic = Some(format!(
        "artifact_cleanup_incomplete: {}",
        cleanup_warnings.join("; ")
    ));
    canonicalize_deletion_tombstone(tombstone)
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
    let operation_id = normalize_deletion_tombstone(&mut tombstone)?;
    metadata_validation(
        tombstone.workspace_id.clone(),
        operation_id,
        tombstone.version,
        &tombstone,
    )
}

fn normalize_deletion_tombstone(
    tombstone: &mut WorkspaceDeletionTombstoneV1,
) -> Result<String, WorkspaceWorkingJournalError> {
    validate_metadata_schema(tombstone.version)?;
    tombstone.workspace_id = canonical_uuid(&tombstone.workspace_id)
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    if !valid_file_url(&tombstone.file_url) {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    if !valid_foundation_date(&tombstone.deleted_at) {
        return Err(WorkspaceWorkingJournalError::InvalidTimestamp);
    }
    validate_and_canonicalize_recorded_operation(&mut tombstone.operation)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceCatalogValidationV1 {
    pub catalog_version: u16,
    pub revision: u64,
    pub entry_count: usize,
    pub deletion_count: usize,
    pub content_digest: String,
    pub canonical_bytes: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceCatalogEntryV1 {
    #[serde(rename = "workspaceID")]
    workspace_id: String,
    #[serde(rename = "fileURL")]
    file_url: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceCatalogV1 {
    version: u16,
    revision: u64,
    entries: Vec<WorkspaceCatalogEntryV1>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    deletions: Option<Vec<WorkspaceDeletionTombstoneV1>>,
    updated_at: Value,
}

#[derive(Deserialize)]
struct WorkspaceCatalogVersionEnvelope {
    version: u16,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum WorkspaceCatalogTransitionRequestV1 {
    Seed {
        entries: Vec<WorkspaceCatalogEntryV1>,
        updated_at: Value,
    },
    Upsert {
        expected_catalog_revision: u64,
        #[serde(rename = "workspaceID")]
        workspace_id: String,
        #[serde(rename = "fileURL")]
        file_url: String,
        updated_at: Value,
    },
    Delete {
        expected_catalog_revision: u64,
        tombstone: WorkspaceDeletionTombstoneV1,
        updated_at: Value,
    },
    RecoverCreate {
        expected_catalog_revision: u64,
        #[serde(rename = "workspaceID")]
        workspace_id: String,
        #[serde(rename = "fileURL")]
        file_url: String,
        updated_at: Value,
    },
}

pub fn validate_workspace_catalog_v1(
    bytes: &[u8],
) -> Result<WorkspaceCatalogValidationV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(bytes)?;
    let catalog = decode_workspace_catalog(bytes)?;
    canonicalize_catalog(catalog)
}

pub fn seed_workspace_catalog_v1(
    seed_request_bytes: &[u8],
) -> Result<WorkspaceCatalogValidationV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(seed_request_bytes)?;
    let request: WorkspaceCatalogTransitionRequestV1 =
        serde_json::from_slice(seed_request_bytes)
            .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if !matches!(request, WorkspaceCatalogTransitionRequestV1::Seed { .. }) {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    plan_workspace_catalog_transition_v1(None, seed_request_bytes)
}

fn plan_workspace_catalog_transition_v1(
    current_catalog_bytes: Option<&[u8]>,
    transition_bytes: &[u8],
) -> Result<WorkspaceCatalogValidationV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(transition_bytes)?;
    let transition: WorkspaceCatalogTransitionRequestV1 = serde_json::from_slice(transition_bytes)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let mut current = match current_catalog_bytes {
        Some(bytes) => {
            require_metadata_input_bound(bytes)?;
            let catalog = decode_workspace_catalog(bytes)?;
            Some(normalize_catalog(catalog)?)
        }
        None => None,
    };

    let candidate = match transition {
        WorkspaceCatalogTransitionRequestV1::Seed {
            entries,
            updated_at,
        } => {
            if current.is_some() {
                return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
            }
            WorkspaceCatalogV1 {
                version: WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
                revision: 0,
                entries,
                deletions: Some(Vec::new()),
                updated_at,
            }
        }
        WorkspaceCatalogTransitionRequestV1::Upsert {
            expected_catalog_revision,
            workspace_id,
            file_url,
            updated_at,
        } => {
            let mut catalog = require_catalog_revision(&mut current, expected_catalog_revision)?;
            let workspace_id = canonical_uuid(&workspace_id)
                .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
            if !valid_file_url(&file_url) {
                return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
            }
            catalog
                .entries
                .retain(|entry| entry.workspace_id != workspace_id);
            catalog.entries.push(WorkspaceCatalogEntryV1 {
                workspace_id: workspace_id.clone(),
                file_url,
            });
            catalog
                .entries
                .sort_by(|left, right| left.workspace_id.cmp(&right.workspace_id));
            let mut deletions = catalog.deletions.take().unwrap_or_default();
            deletions.retain(|tombstone| tombstone.workspace_id != workspace_id);
            catalog.deletions = Some(deletions);
            advance_catalog(&mut catalog, updated_at)?;
            catalog
        }
        WorkspaceCatalogTransitionRequestV1::Delete {
            expected_catalog_revision,
            mut tombstone,
            updated_at,
        } => {
            let mut catalog = require_catalog_revision(&mut current, expected_catalog_revision)?;
            normalize_deletion_tombstone(&mut tombstone)?;
            catalog
                .entries
                .retain(|entry| entry.workspace_id != tombstone.workspace_id);
            let mut deletions = catalog.deletions.take().unwrap_or_default();
            deletions.retain(|existing| existing.workspace_id != tombstone.workspace_id);
            deletions.push(tombstone);
            catalog.deletions = Some(deletions);
            advance_catalog(&mut catalog, updated_at)?;
            catalog
        }
        WorkspaceCatalogTransitionRequestV1::RecoverCreate {
            expected_catalog_revision,
            workspace_id,
            file_url,
            updated_at,
        } => {
            let mut catalog = require_catalog_revision(&mut current, expected_catalog_revision)?;
            let workspace_id = canonical_uuid(&workspace_id)
                .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
            if !valid_file_url(&file_url) {
                return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
            }
            if catalog
                .entries
                .iter()
                .any(|entry| entry.workspace_id == workspace_id)
                || catalog.deletions.as_ref().is_some_and(|deletions| {
                    deletions
                        .iter()
                        .any(|tombstone| tombstone.workspace_id == workspace_id)
                })
            {
                return Err(WorkspaceWorkingJournalError::InvalidIdentity);
            }
            catalog.entries.push(WorkspaceCatalogEntryV1 {
                workspace_id,
                file_url,
            });
            catalog
                .entries
                .sort_by(|left, right| left.workspace_id.cmp(&right.workspace_id));
            advance_catalog(&mut catalog, updated_at)?;
            catalog
        }
    };
    canonicalize_catalog(candidate)
}

fn require_catalog_revision(
    current: &mut Option<WorkspaceCatalogV1>,
    expected_revision: u64,
) -> Result<WorkspaceCatalogV1, WorkspaceWorkingJournalError> {
    let catalog = current
        .take()
        .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
    if catalog.revision != expected_revision {
        return Err(WorkspaceWorkingJournalError::InvalidRevisionState);
    }
    Ok(catalog)
}

fn advance_catalog(
    catalog: &mut WorkspaceCatalogV1,
    updated_at: Value,
) -> Result<(), WorkspaceWorkingJournalError> {
    catalog.version = WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1;
    catalog.revision = catalog
        .revision
        .checked_add(1)
        .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
    catalog.updated_at = updated_at;
    Ok(())
}

fn canonicalize_catalog(
    catalog: WorkspaceCatalogV1,
) -> Result<WorkspaceCatalogValidationV1, WorkspaceWorkingJournalError> {
    let catalog = normalize_catalog(catalog)?;
    let entry_count = catalog.entries.len();
    let deletion_count = catalog.deletions.as_ref().map_or(0, Vec::len);
    let canonical_bytes =
        serde_json::to_vec(&catalog).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if canonical_bytes.len() > MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1 {
        return Err(WorkspaceWorkingJournalError::OutputTooLarge {
            actual: canonical_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1,
        });
    }
    Ok(WorkspaceCatalogValidationV1 {
        catalog_version: catalog.version,
        revision: catalog.revision,
        entry_count,
        deletion_count,
        content_digest: format!("{:x}", Sha256::digest(&canonical_bytes)),
        canonical_bytes,
    })
}

fn decode_workspace_catalog(
    bytes: &[u8],
) -> Result<WorkspaceCatalogV1, WorkspaceWorkingJournalError> {
    let envelope: WorkspaceCatalogVersionEnvelope =
        serde_json::from_slice(bytes).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    if envelope.version > WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1 {
        return Err(WorkspaceWorkingJournalError::FutureSchema(envelope.version));
    }
    serde_json::from_slice(bytes).map_err(|_| WorkspaceWorkingJournalError::Malformed)
}

fn normalize_catalog(
    mut catalog: WorkspaceCatalogV1,
) -> Result<WorkspaceCatalogV1, WorkspaceWorkingJournalError> {
    if catalog.version > WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1 {
        return Err(WorkspaceWorkingJournalError::FutureSchema(catalog.version));
    }
    let mut seen = HashSet::with_capacity(catalog.entries.len());
    for entry in &mut catalog.entries {
        entry.workspace_id = canonical_uuid(&entry.workspace_id)
            .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
        if !seen.insert(entry.workspace_id.clone()) {
            return Err(WorkspaceWorkingJournalError::DuplicateCatalogIdentity);
        }
        if !valid_file_url(&entry.file_url) {
            return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
        }
    }
    if let Some(deletions) = &mut catalog.deletions {
        let mut deleted = HashSet::with_capacity(deletions.len());
        for tombstone in deletions {
            normalize_deletion_tombstone(tombstone)?;
            if !deleted.insert(tombstone.workspace_id.clone())
                || seen.contains(&tombstone.workspace_id)
            {
                return Err(WorkspaceWorkingJournalError::InvalidIdentity);
            }
        }
    }
    if !valid_foundation_date(&catalog.updated_at) {
        return Err(WorkspaceWorkingJournalError::InvalidTimestamp);
    }
    Ok(catalog)
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
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
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
    use crate::workspace_context::WorkspaceContextAuthorityState;

    const WORKSPACE_ID: &str = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const CONTEXT_ID: &str = "11111111-2222-3333-4444-555555555555";
    const CONTEXT_ID_TWO: &str = "22222222-3333-4444-5555-666666666666";
    const OPERATION_ID: &str = "66666666-7777-8888-9999-aaaaaaaaaaaa";
    const BASE_OPERATION_ID: &str = "eeeeeeee-ffff-aaaa-bbbb-cccccccccccc";
    const OTHER_WORKSPACE_ID: &str = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";

    fn authority_workspace(
        workspace_id: &str,
        prompt: &str,
        working_revision: u64,
    ) -> WorkspaceProjectionPublishedWorkspace {
        let revisions = WorkspaceProjectionRevisionState {
            working_revision,
            saved_revision: 0,
            dirty_revision: (working_revision > 0).then_some(working_revision),
        };
        let health = WorkspaceProjectionHealth {
            kind: WorkspaceProjectionHealthKind::Writable,
            reason: None,
        };
        WorkspaceProjectionPublishedWorkspace {
            document_bytes: document_for_workspace(workspace_id, prompt),
            authority: WorkspaceProjectionAuthorityState {
                revisions,
                health: health.clone(),
                contexts: vec![WorkspaceContextAuthorityState {
                    context_id: CONTEXT_ID.to_owned(),
                    revisions,
                    health,
                }],
            },
        }
    }

    fn authority_draft(
        catalog_revision: u64,
        kind: WorkspaceProjectionPublicationKind,
    ) -> WorkspaceAuthorityPublicationDraftV1 {
        WorkspaceAuthorityPublicationDraftV1 {
            catalog_revision,
            kind,
            workspace_id: Some(WORKSPACE_ID.to_owned()),
            context_id: Some(CONTEXT_ID.to_owned()),
            operation_id: Some(OPERATION_ID.to_owned()),
            revisions: Some(WorkspaceProjectionRevisionState {
                working_revision: 1,
                saved_revision: 0,
                dirty_revision: Some(1),
            }),
        }
    }

    fn command_identity_request(
        command_kind: WorkspaceCommandKindV1,
    ) -> WorkspaceCommandIdentityRequestV1 {
        let (file_url, content_digest, accept_external) = match command_kind {
            WorkspaceCommandKindV1::Create | WorkspaceCommandKindV1::Replace => (
                Some("file:///tmp/Workspace.json".to_owned()),
                Some("f".repeat(64)),
                None,
            ),
            WorkspaceCommandKindV1::ResolveExternalConflict => (None, None, Some(true)),
            WorkspaceCommandKindV1::Save | WorkspaceCommandKindV1::Delete => (None, None, None),
        };
        WorkspaceCommandIdentityRequestV1 {
            operation_id: OPERATION_ID.to_owned(),
            expected_catalog_revision: None,
            expected_workspace_revision: None,
            expected_context_revision: None,
            origin: WorkspaceCommandOriginV1::AppPresentation { window_id: 42 },
            command_kind,
            workspace_id: WORKSPACE_ID.to_owned(),
            file_url,
            content_digest,
            accept_external,
            protected_agent_identities: Vec::new(),
        }
    }

    fn admission_operation(
        operation_id: String,
        fingerprint: char,
        recorded_at: f64,
    ) -> WorkspaceRecordedOperationV1 {
        WorkspaceRecordedOperationV1 {
            operation_id,
            fingerprint: fingerprint.to_string().repeat(64),
            recorded_at,
            disposition: "applied".to_owned(),
            before: None,
            after: None,
            catalog_revision: recorded_at as u64,
            resulting_digest: None,
            error_code: None,
            diagnostic: None,
        }
    }

    fn indexed_operation(index: usize, fingerprint: char) -> WorkspaceRecordedOperationV1 {
        admission_operation(
            format!("00000000-0000-0000-0000-{index:012x}"),
            fingerprint,
            index as f64,
        )
    }

    fn authority_admission() -> PreparedWorkspaceCommandAdmissionV1 {
        PreparedWorkspaceCommandAdmissionV1::prepare(&[WorkspaceCommandAdmissionSeedRecordV1 {
            workspace_id: Some(WORKSPACE_ID.to_owned()),
            operation: admission_operation(OPERATION_ID.to_owned(), 'a', 1.0),
        }])
        .expect("authority admission")
    }

    fn global_authority_draft(
        catalog_revision: u64,
        kind: WorkspaceProjectionPublicationKind,
    ) -> WorkspaceAuthorityPublicationDraftV1 {
        WorkspaceAuthorityPublicationDraftV1 {
            catalog_revision,
            kind,
            workspace_id: None,
            context_id: None,
            operation_id: None,
            revisions: None,
        }
    }

    #[test]
    fn command_admission_authority_publication_and_read_are_one_atomic_cursor() {
        let admission = authority_admission();
        let workspace = authority_workspace(WORKSPACE_ID, "aggregate", 1);
        let first = admission
            .publish_authority_state(
                std::slice::from_ref(&workspace),
                authority_draft(7, WorkspaceProjectionPublicationKind::WorkspaceCreated),
            )
            .expect("first publication");
        assert_eq!(first.previous_generation, 0);
        assert_eq!(first.generation, 1);
        assert!(first.projection_changed);
        assert_eq!(first.previous_publication_sequence, 0);
        assert_eq!(first.publication_sequence, 1);
        assert_eq!(first.catalog_revision, 7);
        assert_eq!(first.event_log_floor_sequence, 1);
        assert_eq!(first.event_log_count, 1);

        let read = admission
            .authority_read(WORKSPACE_ID)
            .expect("authority read");
        assert_eq!(read.generation, first.generation);
        assert_eq!(read.catalog_revision, first.catalog_revision);
        assert_eq!(read.publication_sequence, first.publication_sequence);
        assert_eq!(read.projection_digest, first.projection_digest);
        assert_eq!(
            read.projection
                .as_ref()
                .map(|value| value.workspace_id.as_str()),
            Some(WORKSPACE_ID)
        );
        assert_eq!(
            read.authority
                .as_ref()
                .map(|value| value.revisions.working_revision),
            Some(1)
        );
        assert_eq!(
            read.content_digest,
            Some(format!("{:x}", Sha256::digest(&workspace.document_bytes)))
        );

        let second = admission
            .publish_authority_state(
                std::slice::from_ref(&workspace),
                authority_draft(7, WorkspaceProjectionPublicationKind::OperationDeduplicated),
            )
            .expect("cursor-only publication");
        assert!(!second.projection_changed);
        assert_eq!(second.generation, first.generation);
        assert_eq!(
            second.previous_publication_sequence,
            first.publication_sequence
        );
        assert_eq!(second.publication_sequence, 2);
        assert_eq!(second.event_log_count, 2);

        let overlay = authority_workspace(WORKSPACE_ID, "routing overlay", 1);
        let synchronized = admission
            .synchronize_authority_projection(std::slice::from_ref(&overlay))
            .expect("routing overlay synchronization");
        assert!(synchronized.projection_changed);
        assert_eq!(synchronized.previous_generation, second.generation);
        assert_eq!(synchronized.generation, second.generation + 1);
        assert_eq!(synchronized.catalog_revision, second.catalog_revision);
        assert_eq!(
            synchronized.publication_sequence, second.publication_sequence,
            "routing overlays must not invent subscriber events"
        );
        let overlay_read = admission
            .authority_read(WORKSPACE_ID)
            .expect("overlay read");
        assert_eq!(
            overlay_read
                .projection
                .as_ref()
                .and_then(|projection| projection.contexts.first())
                .map(|context| context.prompt.as_str()),
            Some("routing overlay")
        );
        assert_eq!(
            overlay_read.publication_sequence,
            second.publication_sequence
        );
    }

    #[test]
    fn claimed_reservation_and_authority_publication_finalize_as_one_retryable_commit() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let baseline_workspace = authority_workspace(WORKSPACE_ID, "baseline", 0);
        let baseline = admission
            .publish_authority_state(
                std::slice::from_ref(&baseline_workspace),
                global_authority_draft(2, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("install baseline authority");
        let request = command_identity_request(WorkspaceCommandKindV1::Replace);
        let (identity, claim) = match admission.acquire(request.clone()).expect("acquire claim") {
            WorkspaceCommandAdmissionAcquireV1::Claimed { identity, claim } => (identity, claim),
            other => panic!("expected claimed acquisition, got {other:?}"),
        };
        let before = WorkspaceProjectionRevisionState {
            working_revision: 0,
            saved_revision: 0,
            dirty_revision: None,
        };
        let after = WorkspaceProjectionRevisionState {
            working_revision: 1,
            saved_revision: 0,
            dirty_revision: Some(1),
        };
        let operation = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: identity.fingerprint.clone(),
            recorded_at: 1.0,
            disposition: "applied".to_owned(),
            before: Some(before),
            after: Some(after),
            catalog_revision: 3,
            resulting_digest: None,
            error_code: None,
            diagnostic: None,
        };
        let mut reservation = admission
            .bind_claim(
                &claim,
                WorkspaceCommandAdmissionFinalizationV1::Workspace {
                    workspace_id: WORKSPACE_ID.to_owned(),
                    operation: operation.clone(),
                },
            )
            .expect("bind exact claim");
        let workspace = authority_workspace(WORKSPACE_ID, "transaction-owned", 1);
        assert!(matches!(
            admission.prepare_claimed_authority_publication(
                &claim,
                WorkspaceProjectionPublicationKind::SavedDocumentCommitted,
                std::slice::from_ref(&workspace),
                authority_draft(3, WorkspaceProjectionPublicationKind::WorkingStateCommitted),
            ),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        ));
        let publication = admission
            .prepare_claimed_authority_publication(
                &claim,
                WorkspaceProjectionPublicationKind::WorkingStateCommitted,
                std::slice::from_ref(&workspace),
                authority_draft(3, WorkspaceProjectionPublicationKind::WorkingStateCommitted),
            )
            .expect("prepare exact transaction candidate");
        assert_eq!(
            admission.publish_authority_state(
                std::slice::from_ref(&baseline_workspace),
                global_authority_draft(3, WorkspaceProjectionPublicationKind::Bootstrapped),
            ),
            Err(WorkspaceWorkingJournalError::InvalidTransaction),
            "standalone publication cannot overtake a claimed aggregate head"
        );
        assert_eq!(
            admission.synchronize_authority_projection(std::slice::from_ref(&baseline_workspace)),
            Err(WorkspaceWorkingJournalError::InvalidTransaction),
            "routing overlay cannot overtake a claimed aggregate head"
        );
        assert_eq!(
            reservation.finalize(),
            Err(WorkspaceWorkingJournalError::InvalidTransaction),
            "the ledger cannot commit without its reserved publication"
        );

        let (diagnostics, receipt) = reservation
            .finalize_with_authority(&publication)
            .expect("finalize ledger and authority together");
        assert_eq!(diagnostics.global_operation_count, 1);
        assert_eq!(diagnostics.workspace_operation_count, 1);
        assert_eq!(
            receipt.previous_publication_sequence,
            baseline.publication_sequence
        );
        assert_eq!(
            receipt.publication_sequence,
            baseline.publication_sequence + 1
        );
        assert_eq!(receipt.catalog_revision, 3);
        assert_eq!(receipt.event.operation_id.as_deref(), Some(OPERATION_ID));
        assert!(matches!(
            admission.acquire(request).expect("terminal replay"),
            WorkspaceCommandAdmissionAcquireV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Workspace,
                operation: replayed,
                ..
            } if replayed == operation
        ));
        let committed = admission
            .authority_read(WORKSPACE_ID)
            .expect("committed authority read");
        assert_eq!(committed.publication_sequence, receipt.publication_sequence);
        assert_eq!(committed.generation, receipt.generation);
        assert_eq!(committed.projection_digest, receipt.projection_digest);
        assert!(committed.projection.is_some());
    }

    #[test]
    fn delete_cleanup_amendment_commits_with_authority_as_first_terminal_receipt() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let baseline_workspace = authority_workspace(WORKSPACE_ID, "baseline", 0);
        admission
            .publish_authority_state(
                std::slice::from_ref(&baseline_workspace),
                global_authority_draft(2, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("install baseline authority");
        let request = command_identity_request(WorkspaceCommandKindV1::Delete);
        let (identity, claim) = match admission.acquire(request.clone()).expect("acquire delete") {
            WorkspaceCommandAdmissionAcquireV1::Claimed { identity, claim } => (identity, claim),
            other => panic!("expected claimed delete, got {other:?}"),
        };
        let operation = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: identity.fingerprint,
            recorded_at: 1.0,
            disposition: "applied".to_owned(),
            before: Some(WorkspaceProjectionRevisionState {
                working_revision: 0,
                saved_revision: 0,
                dirty_revision: None,
            }),
            after: None,
            catalog_revision: 3,
            resulting_digest: None,
            error_code: None,
            diagnostic: None,
        };
        let mut reservation = admission
            .bind_claim(
                &claim,
                WorkspaceCommandAdmissionFinalizationV1::Delete {
                    workspace_id: WORKSPACE_ID.to_owned(),
                    operation: operation.clone(),
                },
            )
            .expect("bind delete claim");
        let publication = admission
            .prepare_claimed_authority_publication(
                &claim,
                WorkspaceProjectionPublicationKind::WorkspaceDeleted,
                &[],
                WorkspaceAuthorityPublicationDraftV1 {
                    catalog_revision: 3,
                    kind: WorkspaceProjectionPublicationKind::WorkspaceDeleted,
                    workspace_id: Some(WORKSPACE_ID.to_owned()),
                    context_id: None,
                    operation_id: Some(OPERATION_ID.to_owned()),
                    revisions: None,
                },
            )
            .expect("reserve delete publication");
        let mut invalid = operation.clone();
        invalid.catalog_revision = 4;
        assert_eq!(
            reservation.finalize_delete_with_authority(&publication, invalid),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger),
            "invalid cleanup amendments must not consume the reserved head"
        );
        let mut amended = operation.clone();
        amended.diagnostic =
            Some("artifact_cleanup_incomplete: workspace document: permission denied".to_owned());
        let (_, receipt) = reservation
            .finalize_delete_with_authority(&publication, amended.clone())
            .expect("commit amended delete and publication together");
        assert_eq!(receipt.catalog_revision, 3);
        assert_eq!(receipt.workspace_count, 0);
        assert!(matches!(
            admission.acquire(request).expect("replay amended delete"),
            WorkspaceCommandAdmissionAcquireV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: replayed,
                ..
            } if replayed == amended
        ));
        let read = admission
            .authority_read(WORKSPACE_ID)
            .expect("deleted workspace authority read");
        assert!(read.projection.is_none());
        assert_eq!(read.publication_sequence, receipt.publication_sequence);
    }

    #[test]
    fn dropping_claimed_authority_publication_releases_head_without_committing() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let baseline_workspace = authority_workspace(WORKSPACE_ID, "baseline", 0);
        let baseline = admission
            .publish_authority_state(
                std::slice::from_ref(&baseline_workspace),
                global_authority_draft(2, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("install baseline authority");
        let request = command_identity_request(WorkspaceCommandKindV1::Replace);
        let (identity, claim) = match admission.acquire(request).expect("acquire claim") {
            WorkspaceCommandAdmissionAcquireV1::Claimed { identity, claim } => (identity, claim),
            other => panic!("expected claimed acquisition, got {other:?}"),
        };
        let operation = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: identity.fingerprint,
            recorded_at: 1.0,
            disposition: "applied".to_owned(),
            before: Some(WorkspaceProjectionRevisionState {
                working_revision: 0,
                saved_revision: 0,
                dirty_revision: None,
            }),
            after: Some(WorkspaceProjectionRevisionState {
                working_revision: 1,
                saved_revision: 0,
                dirty_revision: Some(1),
            }),
            catalog_revision: 3,
            resulting_digest: None,
            error_code: None,
            diagnostic: None,
        };
        let reservation = admission
            .bind_claim(
                &claim,
                WorkspaceCommandAdmissionFinalizationV1::Workspace {
                    workspace_id: WORKSPACE_ID.to_owned(),
                    operation,
                },
            )
            .expect("bind claim");
        let candidate = admission
            .prepare_claimed_authority_publication(
                &claim,
                WorkspaceProjectionPublicationKind::WorkingStateCommitted,
                &[authority_workspace(WORKSPACE_ID, "candidate", 1)],
                authority_draft(3, WorkspaceProjectionPublicationKind::WorkingStateCommitted),
            )
            .expect("reserve aggregate head");
        drop(candidate);
        let standalone = admission
            .publish_authority_state(
                std::slice::from_ref(&baseline_workspace),
                global_authority_draft(3, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("released head accepts standalone publication");
        assert_eq!(
            standalone.previous_publication_sequence,
            baseline.publication_sequence
        );
        assert_eq!(
            admission.diagnostics().expect("ledger remains unchanged"),
            WorkspaceCommandAdmissionDiagnosticsV1 {
                global_operation_count: 0,
                workspace_count: 0,
                workspace_operation_count: 0,
            }
        );
        reservation.cancel();
        assert!(claim.abandon().expect("abandon released claim"));
    }

    #[test]
    fn command_admission_authority_publication_failure_is_atomic_and_close_fenced() {
        let admission = PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("admission");
        let workspace = authority_workspace(WORKSPACE_ID, "aggregate", 1);
        let committed = admission
            .publish_authority_state(
                std::slice::from_ref(&workspace),
                global_authority_draft(3, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("initial publication");
        let mut invalid = workspace.clone();
        invalid.authority.revisions = WorkspaceProjectionRevisionState {
            working_revision: 0,
            saved_revision: 1,
            dirty_revision: None,
        };
        assert!(matches!(
            admission.publish_authority_state(
                &[invalid],
                authority_draft(4, WorkspaceProjectionPublicationKind::ExternalReloaded),
            ),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
                | Err(WorkspaceWorkingJournalError::InvalidRevisionState)
        ));
        let unchanged = admission
            .authority_read(WORKSPACE_ID)
            .expect("unchanged read");
        assert_eq!(unchanged.generation, committed.generation);
        assert_eq!(unchanged.catalog_revision, committed.catalog_revision);
        assert_eq!(
            unchanged.publication_sequence,
            committed.publication_sequence
        );
        assert_eq!(unchanged.projection_digest, committed.projection_digest);

        let mut mismatched_revision =
            authority_draft(4, WorkspaceProjectionPublicationKind::ExternalReloaded);
        mismatched_revision.operation_id = None;
        mismatched_revision.revisions = Some(WorkspaceProjectionRevisionState {
            working_revision: 0,
            saved_revision: 0,
            dirty_revision: None,
        });
        assert_eq!(
            admission
                .publish_authority_state(std::slice::from_ref(&workspace), mismatched_revision,),
            Err(WorkspaceWorkingJournalError::InvalidRevisionState)
        );
        let mut mismatched_context =
            authority_draft(4, WorkspaceProjectionPublicationKind::ExternalReloaded);
        mismatched_context.operation_id = None;
        mismatched_context.context_id = Some(OTHER_WORKSPACE_ID.to_owned());
        assert_eq!(
            admission
                .publish_authority_state(std::slice::from_ref(&workspace), mismatched_context,),
            Err(WorkspaceWorkingJournalError::InvalidContextTable)
        );
        assert_eq!(
            admission.publish_authority_state(
                std::slice::from_ref(&workspace),
                authority_draft(4, WorkspaceProjectionPublicationKind::WorkspaceCreated),
            ),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        );
        let mut future = workspace.clone();
        future.document_bytes =
            format!(r#"{{"id":"{WORKSPACE_ID}","schemaVersion":2,"composeTabs":[]}}"#).into_bytes();
        assert_eq!(
            admission.publish_authority_state(
                &[future],
                global_authority_draft(4, WorkspaceProjectionPublicationKind::Bootstrapped),
            ),
            Err(WorkspaceWorkingJournalError::FutureSchema(2))
        );

        admission.inner.lock().expect("admission lock").quarantined = true;
        let mut valid_reload =
            authority_draft(4, WorkspaceProjectionPublicationKind::ExternalReloaded);
        valid_reload.operation_id = None;
        assert_eq!(
            admission.publish_authority_state(std::slice::from_ref(&workspace), valid_reload),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        assert_eq!(
            admission.synchronize_authority_projection(std::slice::from_ref(&workspace)),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        let quarantined_read = admission
            .authority_read(WORKSPACE_ID)
            .expect("quarantine preserves the last committed authority read");
        assert_eq!(quarantined_read.generation, committed.generation);
        assert_eq!(
            quarantined_read.publication_sequence,
            committed.publication_sequence
        );

        admission.close();
        assert!(matches!(
            admission.authority_read(WORKSPACE_ID),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        ));
    }

    #[test]
    fn command_admission_artifact_recovery_binds_catalog_and_preserves_global_replay() {
        let initial_catalog = catalog_bytes(0);
        let initial = WorkspaceCommandAdmissionRecoveryV1 {
            catalog_bytes: initial_catalog.clone(),
            journals: vec![WorkspaceCommandAdmissionJournalRecoveryV1 {
                workspace_id: WORKSPACE_ID.to_owned(),
                canonical_bytes: Some(journal_bytes(None)),
            }],
            deletion_sidecars: Vec::new(),
        };
        let (admission, receipt) =
            PreparedWorkspaceCommandAdmissionV1::prepare_from_recovery(&initial)
                .expect("artifact recovery prepares admission");
        assert_eq!(receipt.catalog_revision, 0);
        assert_eq!(receipt.target_workspace_id, None);
        assert_eq!(receipt.diagnostics.global_operation_count, 1);
        assert_eq!(receipt.diagnostics.workspace_operation_count, 1);

        let empty_target = WorkspaceCommandAdmissionTargetRecoveryV1 {
            catalog_bytes: initial_catalog,
            workspace_id: WORKSPACE_ID.to_owned(),
            journal_bytes: None,
            deletion_sidecar_bytes: None,
        };
        let target_receipt = admission
            .apply_target_recovery(&empty_target)
            .expect("target recovery");
        assert_eq!(
            target_receipt.target_workspace_id.as_deref(),
            Some(WORKSPACE_ID)
        );
        assert_eq!(target_receipt.diagnostics.global_operation_count, 1);
        assert_eq!(target_receipt.diagnostics.workspace_operation_count, 0);

        let advanced = WorkspaceCommandAdmissionTargetRecoveryV1 {
            catalog_bytes: catalog_bytes(1),
            workspace_id: WORKSPACE_ID.to_owned(),
            journal_bytes: Some(journal_bytes(None)),
            deletion_sidecar_bytes: None,
        };
        admission
            .apply_target_recovery(&advanced)
            .expect("higher catalog revision with the same relationship");
        assert!(matches!(
            admission.apply_target_recovery(&empty_target),
            Err(WorkspaceWorkingJournalError::StaleRecoverySnapshot)
        ));

        let removed_target = WorkspaceCommandAdmissionTargetRecoveryV1 {
            catalog_bytes: serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "revision": 2,
                "entries": [],
                "deletions": [],
                "updatedAt": 3.0
            }))
            .expect("removed catalog"),
            workspace_id: WORKSPACE_ID.to_owned(),
            journal_bytes: None,
            deletion_sidecar_bytes: None,
        };
        assert!(matches!(
            admission.apply_target_recovery(&removed_target),
            Err(WorkspaceWorkingJournalError::FullRecoveryRequired)
        ));
        assert_eq!(
            admission
                .diagnostics()
                .expect("unchanged diagnostics")
                .workspace_operation_count,
            1,
            "failed target recovery must be atomic"
        );
    }

    #[test]
    fn command_admission_target_recovery_rejects_non_target_tombstone_change() {
        let initial_catalog =
            catalog_with_non_target_deletion(1, "77777777-8888-9999-aaaa-bbbbbbbbbbbb");
        let initial = WorkspaceCommandAdmissionRecoveryV1 {
            catalog_bytes: initial_catalog,
            journals: vec![WorkspaceCommandAdmissionJournalRecoveryV1 {
                workspace_id: WORKSPACE_ID.to_owned(),
                canonical_bytes: Some(journal_bytes(None)),
            }],
            deletion_sidecars: vec![WorkspaceCommandAdmissionDeletionRecoveryV1 {
                workspace_id: OTHER_WORKSPACE_ID.to_owned(),
                canonical_bytes: None,
            }],
        };
        let (admission, _) = PreparedWorkspaceCommandAdmissionV1::prepare_from_recovery(&initial)
            .expect("initial artifact recovery");
        let before = admission.diagnostics().expect("initial diagnostics");

        let changed_non_target = WorkspaceCommandAdmissionTargetRecoveryV1 {
            catalog_bytes: catalog_with_non_target_deletion(
                2,
                "88888888-9999-aaaa-bbbb-cccccccccccc",
            ),
            workspace_id: WORKSPACE_ID.to_owned(),
            journal_bytes: Some(journal_bytes(None)),
            deletion_sidecar_bytes: None,
        };
        assert!(matches!(
            admission.apply_target_recovery(&changed_non_target),
            Err(WorkspaceWorkingJournalError::FullRecoveryRequired)
        ));
        assert_eq!(
            admission.diagnostics().expect("unchanged diagnostics"),
            before,
            "non-target relationship rejection must be atomic"
        );
    }

    #[test]
    fn command_admission_deletion_sidecar_requires_exact_or_cleanup_diagnostic() {
        let catalog: WorkspaceCatalogV1 =
            serde_json::from_slice(&create_catalog_bytes(1, true)).expect("catalog");
        let mut authoritative = catalog
            .deletions
            .expect("deletions")
            .into_iter()
            .next()
            .expect("tombstone");
        authoritative.operation.diagnostic = Some("catalog-authoritative".to_owned());

        let exact = serde_json::to_vec(&authoritative).expect("exact sidecar");
        assert_eq!(
            recovered_deletion_record(&authoritative, Some(&exact))
                .expect("exact authoritative diagnostic")
                .operation
                .diagnostic
                .as_deref(),
            Some("catalog-authoritative")
        );

        let mut missing = authoritative.clone();
        missing.operation.diagnostic = None;
        let missing = serde_json::to_vec(&missing).expect("missing diagnostic sidecar");
        assert!(matches!(
            recovered_deletion_record(&authoritative, Some(&missing)),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        ));

        let mut cleanup = authoritative.clone();
        cleanup.operation.diagnostic =
            Some("artifact_cleanup_incomplete: workspace document: denied".to_owned());
        let cleanup = serde_json::to_vec(&cleanup).expect("cleanup sidecar");
        assert_eq!(
            recovered_deletion_record(&authoritative, Some(&cleanup))
                .expect("cleanup diagnostic override")
                .operation
                .diagnostic
                .as_deref(),
            Some("artifact_cleanup_incomplete: workspace document: denied")
        );
    }

    #[test]
    fn semantic_recovery_initial_commit_binds_projection_and_admission_once() {
        let recovery = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Absent,
            WorkspaceRecoveryArtifactEvidenceV1::Present(document("saved")),
        );
        let candidate = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&recovery)
            .expect("semantic recovery candidate");
        let preview = candidate.preview().expect("semantic preview");
        assert_eq!(
            preview.admission_disposition,
            WorkspaceSemanticRecoveryAdmissionDispositionV1::Installed
        );
        assert!(is_sha256_digest(&preview.projection_digest));
        let WorkspaceSemanticRecoveryProjectionV1::Full { rows } = preview.projection else {
            panic!("expected full semantic projection");
        };
        let WorkspaceSemanticRecoveryRowV1::Active { row } = &rows[0] else {
            panic!("expected active semantic row");
        };
        assert_eq!(row.document_bytes, document("saved"));
        assert_eq!(row.revisions.working_revision, 0);
        assert_eq!(row.health.kind, WorkspaceProjectionHealthKind::Writable);

        let commit = candidate.commit().expect("initial semantic commit");
        assert_eq!(commit.projection_digest, preview.projection_digest);
        let admission = commit.admission.expect("prepared admission");
        assert_eq!(
            admission
                .diagnostics()
                .expect("admission diagnostics")
                .workspace_operation_count,
            0
        );
        assert!(matches!(
            candidate.commit(),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        ));
    }

    #[test]
    fn semantic_recovery_unavailable_journal_quarantines_without_empty_ledger() {
        let recovery = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Present(b"{\"version\":1".to_vec()),
            WorkspaceRecoveryArtifactEvidenceV1::Present(document("saved")),
        );
        let candidate = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&recovery)
            .expect("degraded semantic recovery candidate");
        let preview = candidate.preview().expect("degraded semantic preview");
        assert_eq!(
            preview.admission_disposition,
            WorkspaceSemanticRecoveryAdmissionDispositionV1::Quarantined
        );
        assert_eq!(
            preview.global_health.kind,
            WorkspaceProjectionHealthKind::DegradedReadOnly
        );
        let WorkspaceSemanticRecoveryProjectionV1::Full { rows } = preview.projection else {
            panic!("expected full semantic projection");
        };
        let WorkspaceSemanticRecoveryRowV1::Active { row } = &rows[0] else {
            panic!("expected degraded saved fallback");
        };
        assert_eq!(
            row.health.reason.as_deref(),
            Some("working_journal_decode_failed")
        );
        let commit = candidate.commit().expect("quarantined semantic commit");
        assert!(commit.admission.is_none());
        assert!(commit.admission_receipt.is_none());
    }

    #[test]
    fn semantic_recovery_pending_save_returns_exact_rewrite_and_clean_row() {
        let raw = journal_bytes(None);
        let saved = document("pending saved");
        let save = transition(
            serde_json::json!({
                "kind": "save",
                "expectedWorkingRevision": 0,
                "operationID": OPERATION_ID,
                "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
                "updatedAt": 4.0
            }),
            Some(&raw),
            Some(&saved),
        );
        let recovery = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Present(save.primary.canonical_bytes.clone()),
            WorkspaceRecoveryArtifactEvidenceV1::Present(saved.clone()),
        );
        let candidate = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&recovery)
            .expect("pending semantic recovery");
        let preview = candidate.preview().expect("pending semantic preview");
        assert_eq!(preview.journal_rewrites.len(), 1);
        assert_eq!(
            preview.journal_rewrites[0].replacement_canonical_bytes,
            save.committed.expect("committed journal").canonical_bytes
        );
        let WorkspaceSemanticRecoveryProjectionV1::Full { rows } = preview.projection else {
            panic!("expected full semantic projection");
        };
        let WorkspaceSemanticRecoveryRowV1::Active { row } = &rows[0] else {
            panic!("expected active pending-save row");
        };
        assert_eq!(row.document_bytes, saved);
        assert!(row.revisions.dirty_revision.is_none());
        assert!(
            candidate
                .commit()
                .expect("pending commit")
                .admission
                .is_some()
        );
    }

    #[test]
    fn semantic_target_recovery_commits_only_the_bound_target_projection() {
        let initial = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Present(journal_bytes(None)),
            WorkspaceRecoveryArtifactEvidenceV1::Present(document("saved")),
        );
        let initial_candidate = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&initial)
            .expect("initial semantic recovery");
        let admission = initial_candidate
            .commit()
            .expect("initial semantic commit")
            .admission
            .expect("prepared admission");
        let target = WorkspaceSemanticTargetRecoveryV1 {
            catalog_bytes: catalog_bytes(1),
            workspace_id: WORKSPACE_ID.to_owned(),
            journal: WorkspaceRecoveryArtifactEvidenceV1::Absent,
            saved_document: WorkspaceRecoveryArtifactEvidenceV1::Present(document("target")),
            saved_revision: WorkspaceRecoveryArtifactEvidenceV1::Absent,
            deletion_sidecar: WorkspaceRecoveryArtifactEvidenceV1::Absent,
        };
        let candidate = admission
            .prepare_semantic_target_recovery(&target)
            .expect("target semantic recovery");
        let preview = candidate.preview().expect("target semantic preview");
        let WorkspaceSemanticRecoveryProjectionV1::Target { directive } = preview.projection else {
            panic!("expected target semantic projection");
        };
        let WorkspaceSemanticTargetDirectiveV1::Upsert { row } = directive else {
            panic!("expected target upsert");
        };
        assert_eq!(row.document_bytes, document("target"));
        let commit = candidate.commit().expect("target semantic commit");
        assert_eq!(commit.target_workspace_id.as_deref(), Some(WORKSPACE_ID));
        assert!(commit.admission.is_none());
        assert!(commit.admission_receipt.is_some());
    }

    #[test]
    fn semantic_recovery_clean_external_change_advances_and_rewrites() {
        let external = document("external");
        let recovery = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Present(journal_bytes(None)),
            WorkspaceRecoveryArtifactEvidenceV1::Present(external.clone()),
        );
        let candidate = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&recovery)
            .expect("clean external recovery");
        let preview = candidate.preview().expect("clean external preview");
        assert_eq!(preview.journal_rewrites.len(), 1);
        let WorkspaceSemanticRecoveryProjectionV1::Full { rows } = preview.projection else {
            panic!("expected full projection");
        };
        let WorkspaceSemanticRecoveryRowV1::Active { row } = &rows[0] else {
            panic!("expected active row");
        };
        assert_eq!(row.document_bytes, external);
        assert_eq!(row.revisions.working_revision, 1);
        assert_eq!(row.revisions.saved_revision, 1);
        assert_eq!(row.revisions.dirty_revision, None);
        assert_eq!(row.health.kind, WorkspaceProjectionHealthKind::Writable);
    }

    #[test]
    fn semantic_recovery_dirty_external_change_preserves_local_conflict() {
        let local = document("local working");
        let external = document("external saved");
        let recovery = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Present(journal_bytes(Some(&local))),
            WorkspaceRecoveryArtifactEvidenceV1::Present(external.clone()),
        );
        let preview = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&recovery)
            .expect("dirty external recovery")
            .preview()
            .expect("dirty external preview");
        let WorkspaceSemanticRecoveryProjectionV1::Full { rows } = preview.projection else {
            panic!("expected full projection");
        };
        let WorkspaceSemanticRecoveryRowV1::Active { row } = &rows[0] else {
            panic!("expected active conflict row");
        };
        assert_eq!(row.document_bytes, local);
        assert_eq!(
            row.external_document_bytes.as_deref(),
            Some(external.as_slice())
        );
        assert_eq!(
            row.health.kind,
            WorkspaceProjectionHealthKind::ExternalConflict
        );
        assert_eq!(row.saved_digest, format!("{:x}", Sha256::digest(&external)));
    }

    #[test]
    fn semantic_recovery_unavailable_saved_revision_degrades_only_the_row() {
        let mut recovery = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Absent,
            WorkspaceRecoveryArtifactEvidenceV1::Present(document("saved")),
        );
        recovery.workspaces[0].saved_revision = WorkspaceRecoveryArtifactEvidenceV1::Unavailable(
            "saved_revision_read_failed".to_owned(),
        );
        let candidate = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&recovery)
            .expect("saved revision recovery");
        let preview = candidate.preview().expect("saved revision preview");
        assert_eq!(
            preview.admission_disposition,
            WorkspaceSemanticRecoveryAdmissionDispositionV1::Installed
        );
        let WorkspaceSemanticRecoveryProjectionV1::Full { rows } = preview.projection else {
            panic!("expected full projection");
        };
        let WorkspaceSemanticRecoveryRowV1::Active { row } = &rows[0] else {
            panic!("expected active degraded row");
        };
        assert_eq!(row.revisions.working_revision, 0);
        assert_eq!(
            row.health.kind,
            WorkspaceProjectionHealthKind::DegradedReadOnly
        );
        assert_eq!(
            row.health.reason.as_deref(),
            Some("saved_revision_read_failed")
        );
        assert!(candidate.commit().expect("commit").admission.is_some());
    }

    #[test]
    fn semantic_recovery_invalid_deletion_sidecar_defers_to_catalog_authority() {
        let recovery = WorkspaceSemanticFullRecoveryV1 {
            catalog_bytes: create_catalog_bytes(1, true),
            workspaces: Vec::new(),
            deletions: vec![WorkspaceSemanticDeletionRecoveryEvidenceV1 {
                workspace_id: WORKSPACE_ID.to_owned(),
                sidecar: WorkspaceRecoveryArtifactEvidenceV1::Present(b"{}".to_vec()),
            }],
        };
        let candidate = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&recovery)
            .expect("catalog-authoritative deletion recovery");
        let preview = candidate.preview().expect("deletion preview");
        assert_eq!(
            preview.admission_disposition,
            WorkspaceSemanticRecoveryAdmissionDispositionV1::Installed
        );
        let WorkspaceSemanticRecoveryProjectionV1::Full { rows } = preview.projection else {
            panic!("expected full projection");
        };
        assert!(matches!(
            rows[0],
            WorkspaceSemanticRecoveryRowV1::Deleted { .. }
        ));
        let commit = candidate.commit().expect("deletion commit");
        assert!(commit.admission.is_some());
        assert_eq!(
            commit
                .admission_receipt
                .expect("admission receipt")
                .diagnostics
                .global_operation_count,
            1
        );
    }

    #[test]
    fn semantic_recovery_pending_save_distinguishes_uncommitted_and_conflict() {
        let local = document("local pending");
        let raw = journal_bytes(Some(&local));
        let save = transition(
            serde_json::json!({
                "kind": "save",
                "expectedWorkingRevision": 1,
                "operationID": OPERATION_ID,
                "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
                "updatedAt": 4.0
            }),
            Some(&raw),
            Some(&local),
        );
        let uncommitted = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Present(save.primary.canonical_bytes.clone()),
            WorkspaceRecoveryArtifactEvidenceV1::Present(document("saved")),
        );
        let preview = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&uncommitted)
            .expect("uncommitted pending recovery")
            .preview()
            .expect("uncommitted pending preview");
        assert!(preview.journal_rewrites.is_empty());
        let WorkspaceSemanticRecoveryProjectionV1::Full { rows } = preview.projection else {
            panic!("expected full projection");
        };
        let WorkspaceSemanticRecoveryRowV1::Active { row } = &rows[0] else {
            panic!("expected active pending row");
        };
        assert_eq!(row.document_bytes, local);
        assert_eq!(row.health.kind, WorkspaceProjectionHealthKind::Writable);

        let external = document("third party");
        let conflict = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Present(save.primary.canonical_bytes),
            WorkspaceRecoveryArtifactEvidenceV1::Present(external.clone()),
        );
        let preview = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&conflict)
            .expect("conflict pending recovery")
            .preview()
            .expect("conflict pending preview");
        let WorkspaceSemanticRecoveryProjectionV1::Full { rows } = preview.projection else {
            panic!("expected full projection");
        };
        let WorkspaceSemanticRecoveryRowV1::Active { row } = &rows[0] else {
            panic!("expected active conflict row");
        };
        assert_eq!(
            row.health.kind,
            WorkspaceProjectionHealthKind::ExternalConflict
        );
        assert_eq!(
            row.external_document_bytes.as_deref(),
            Some(external.as_slice())
        );
    }

    #[test]
    fn semantic_recovery_identity_mismatch_never_imports_foreign_journal_state() {
        let mut foreign: Value =
            serde_json::from_slice(&journal_bytes(None)).expect("foreign journal json");
        foreign["workspaceID"] = Value::String(OTHER_WORKSPACE_ID.to_owned());
        let foreign = serde_json::to_vec(&foreign).expect("foreign journal bytes");
        let recovery = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Present(foreign),
            WorkspaceRecoveryArtifactEvidenceV1::Present(document("saved")),
        );
        let preview = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&recovery)
            .expect("identity mismatch recovery")
            .preview()
            .expect("identity mismatch preview");
        assert_eq!(
            preview.admission_disposition,
            WorkspaceSemanticRecoveryAdmissionDispositionV1::Quarantined
        );
        let WorkspaceSemanticRecoveryProjectionV1::Full { rows } = preview.projection else {
            panic!("expected full projection");
        };
        let WorkspaceSemanticRecoveryRowV1::Active { row } = &rows[0] else {
            panic!("expected degraded fallback row");
        };
        assert_eq!(row.revisions.working_revision, 0);
        assert!(row.operations.is_empty());
        assert_eq!(
            row.health.reason.as_deref(),
            Some("working_journal_identity_mismatch")
        );
    }

    #[test]
    fn semantic_recovery_candidate_commit_is_single_use_under_concurrency() {
        let recovery = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Absent,
            WorkspaceRecoveryArtifactEvidenceV1::Present(document("saved")),
        );
        let candidate = Arc::new(
            PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&recovery)
                .expect("semantic candidate"),
        );
        let results = std::thread::scope(|scope| {
            let first = Arc::clone(&candidate);
            let second = Arc::clone(&candidate);
            let first = scope.spawn(move || first.commit());
            let second = scope.spawn(move || second.commit());
            [
                first.join().expect("first thread"),
                second.join().expect("second thread"),
            ]
        });
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(
                    result,
                    Err(WorkspaceWorkingJournalError::InvalidTransaction)
                ))
                .count(),
            1
        );
    }

    #[test]
    fn semantic_recovery_quarantine_preserves_admission_and_later_unquarantines() {
        let initial = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Present(journal_bytes(None)),
            WorkspaceRecoveryArtifactEvidenceV1::Present(document("saved")),
        );
        let admission = PreparedWorkspaceSemanticRecoveryV1::prepare_initial(&initial)
            .expect("initial candidate")
            .commit()
            .expect("initial commit")
            .admission
            .expect("initial admission");
        let before = admission.diagnostics().expect("initial diagnostics");
        let mut request = command_identity_request(WorkspaceCommandKindV1::Save);
        request.operation_id = "99999999-aaaa-bbbb-cccc-dddddddddddd".to_owned();
        let first_generation = match admission.acquire(request.clone()).expect("first acquire") {
            WorkspaceCommandAdmissionAcquireV1::Claimed { claim, .. } => {
                let generation = claim.generation();
                assert!(claim.abandon().expect("abandon first claim"));
                generation
            }
            other => panic!("expected first claim, got {other:?}"),
        };

        let target = WorkspaceSemanticTargetRecoveryV1 {
            catalog_bytes: catalog_bytes(1),
            workspace_id: WORKSPACE_ID.to_owned(),
            journal: WorkspaceRecoveryArtifactEvidenceV1::Unavailable(
                "working_journal_read_failed".to_owned(),
            ),
            saved_document: WorkspaceRecoveryArtifactEvidenceV1::Present(document("saved")),
            saved_revision: WorkspaceRecoveryArtifactEvidenceV1::Absent,
            deletion_sidecar: WorkspaceRecoveryArtifactEvidenceV1::Absent,
        };
        let target_commit = admission
            .prepare_semantic_target_recovery(&target)
            .expect("quarantine candidate")
            .commit()
            .expect("quarantine commit");
        assert_eq!(
            target_commit.admission_disposition,
            WorkspaceSemanticRecoveryAdmissionDispositionV1::Quarantined
        );
        assert_eq!(
            admission.diagnostics().expect("quarantined diagnostics"),
            before
        );
        assert!(matches!(
            admission.acquire(request.clone()),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        ));

        let mut healed = semantic_full_recovery(
            WorkspaceRecoveryArtifactEvidenceV1::Present(journal_bytes(None)),
            WorkspaceRecoveryArtifactEvidenceV1::Present(document("saved")),
        );
        healed.catalog_bytes = catalog_bytes(1);
        let healed_commit = admission
            .prepare_semantic_full_recovery(&healed)
            .expect("healed candidate")
            .commit()
            .expect("healed commit");
        assert!(healed_commit.admission_receipt.is_some());
        match admission.acquire(request).expect("acquire after healing") {
            WorkspaceCommandAdmissionAcquireV1::Claimed { claim, .. } => {
                assert!(claim.generation() > first_generation);
            }
            other => panic!("expected healed claim, got {other:?}"),
        }
    }

    #[test]
    fn command_admission_preflight_binds_identity_and_current_decision() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let request = command_identity_request(WorkspaceCommandKindV1::Save);
        let unseen = admission
            .inspect_for_test(request.clone())
            .expect("unseen preflight");
        assert_eq!(unseen.identity.workspace_id, WORKSPACE_ID);
        assert_eq!(unseen.identity.command_kind, WorkspaceCommandKindV1::Save);
        assert!(matches!(
            unseen.decision,
            WorkspaceCommandAdmissionDecisionV1::Unseen
        ));

        let operation = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: unseen.identity.fingerprint.clone(),
            recorded_at: 1.0,
            disposition: "invalid".to_owned(),
            before: None,
            after: None,
            catalog_revision: 0,
            resulting_digest: None,
            error_code: Some("workspace_unavailable".to_owned()),
            diagnostic: Some("workspace_not_found".to_owned()),
        };
        admission
            .insert_for_test(Some(WORKSPACE_ID.to_owned()), operation.clone())
            .expect("insert receipt");
        assert_eq!(
            admission
                .inspect_for_test(request.clone())
                .expect("replay preflight"),
            WorkspaceCommandAdmissionInspectionV1 {
                identity: unseen.identity.clone(),
                decision: WorkspaceCommandAdmissionDecisionV1::Replay {
                    scope: WorkspaceCommandAdmissionLookupScopeV1::Workspace,
                    operation,
                },
            }
        );

        let mut collision_request = request;
        collision_request.origin = WorkspaceCommandOriginV1::Standalone;
        let collision = admission
            .inspect_for_test(collision_request)
            .expect("collision preflight");
        assert_ne!(collision.identity.fingerprint, unseen.identity.fingerprint);
        assert!(matches!(
            collision.decision,
            WorkspaceCommandAdmissionDecisionV1::Collision {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Workspace
            }
        ));

        let mut invalid = command_identity_request(WorkspaceCommandKindV1::Create);
        invalid.content_digest = Some("invalid".to_owned());
        assert_eq!(
            admission.inspect_for_test(invalid),
            Err(WorkspaceWorkingJournalError::InvalidDigest)
        );
        assert_eq!(
            admission.diagnostics().expect("unchanged diagnostics"),
            WorkspaceCommandAdmissionDiagnosticsV1 {
                global_operation_count: 1,
                workspace_count: 1,
                workspace_operation_count: 1,
            }
        );

        admission.close();
        assert_eq!(
            admission.inspect_for_test(command_identity_request(WorkspaceCommandKindV1::Save)),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
    }

    #[test]
    fn command_admission_acquire_is_atomic_for_pending_collision_and_transient_replay() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let request = command_identity_request(WorkspaceCommandKindV1::Save);
        let (identity, claim) = match admission.acquire(request.clone()).expect("initial acquire") {
            WorkspaceCommandAdmissionAcquireV1::Claimed { identity, claim } => (identity, claim),
            other => panic!("expected claimed acquisition, got {other:?}"),
        };
        assert_eq!(claim.operation_id(), OPERATION_ID);
        assert_eq!(claim.fingerprint(), identity.fingerprint);
        assert!(matches!(
            admission.acquire(request.clone()).expect("matching acquire"),
            WorkspaceCommandAdmissionAcquireV1::Pending {
                generation,
                ..
            } if generation == claim.generation()
        ));

        let mut collision_request = request.clone();
        collision_request.origin = WorkspaceCommandOriginV1::Standalone;
        assert!(matches!(
            admission
                .acquire(collision_request)
                .expect("collision acquire"),
            WorkspaceCommandAdmissionAcquireV1::Collision { scope: None, .. }
        ));

        let operation = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: identity.fingerprint,
            recorded_at: 1.0,
            disposition: "invalid".to_owned(),
            before: None,
            after: None,
            catalog_revision: 0,
            resulting_digest: None,
            error_code: Some("workspace_unavailable".to_owned()),
            diagnostic: Some("workspace_not_found".to_owned()),
        };
        assert_eq!(
            claim
                .finalize_transient(operation.clone())
                .expect("finalize transient claim"),
            operation
        );
        assert!(!claim.abandon().expect("terminal claim is already absent"));
        assert!(matches!(
            admission.acquire(request).expect("replay acquire"),
            WorkspaceCommandAdmissionAcquireV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: replayed,
                ..
            } if replayed == operation
        ));
    }

    #[test]
    fn command_admission_close_fences_transient_but_allows_bound_finalization() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let request = command_identity_request(WorkspaceCommandKindV1::Save);
        let (identity, claim) = match admission.acquire(request).expect("acquire transient claim") {
            WorkspaceCommandAdmissionAcquireV1::Claimed { identity, claim } => (identity, claim),
            other => panic!("expected claim, got {other:?}"),
        };
        let transient = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: identity.fingerprint,
            recorded_at: 1.5,
            disposition: "conflict".to_owned(),
            before: None,
            after: None,
            catalog_revision: 0,
            resulting_digest: None,
            error_code: Some("state_conflict".to_owned()),
            diagnostic: Some("catalog_revision_mismatch".to_owned()),
        };
        admission.close();
        assert_eq!(
            claim.finalize_transient(transient),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        assert!(claim.abandon().expect("closed transient claim cleanup"));

        let durable_admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("durable admission");
        let (durable_identity, durable_claim) = match durable_admission
            .acquire(command_identity_request(WorkspaceCommandKindV1::Save))
            .expect("acquire durable claim")
        {
            WorkspaceCommandAdmissionAcquireV1::Claimed { identity, claim } => (identity, claim),
            other => panic!("expected durable claim, got {other:?}"),
        };
        let durable_operation = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: durable_identity.fingerprint,
            recorded_at: 1.75,
            disposition: "applied".to_owned(),
            before: None,
            after: None,
            catalog_revision: 1,
            resulting_digest: None,
            error_code: None,
            diagnostic: None,
        };
        let mut reservation = durable_admission
            .bind_claim(
                &durable_claim,
                WorkspaceCommandAdmissionFinalizationV1::Workspace {
                    workspace_id: WORKSPACE_ID.to_owned(),
                    operation: durable_operation,
                },
            )
            .expect("bind durable claim");
        durable_admission.close();
        reservation
            .finalize()
            .expect("bound finalization survives admission close");
        assert!(
            !durable_claim
                .abandon()
                .expect("bound finalization terminalized claim")
        );
    }

    #[test]
    fn command_admission_rejects_noncanonical_uppercase_digests() {
        let mut seeded = admission_operation(OPERATION_ID.to_owned(), 'a', 1.0);
        seeded.fingerprint = seeded.fingerprint.to_ascii_uppercase();
        assert!(matches!(
            PreparedWorkspaceCommandAdmissionV1::prepare(&[
                WorkspaceCommandAdmissionSeedRecordV1 {
                    workspace_id: Some(WORKSPACE_ID.to_owned()),
                    operation: seeded,
                },
            ]),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        ));

        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let request = command_identity_request(WorkspaceCommandKindV1::Save);
        let (identity, claim) = match admission.acquire(request.clone()).expect("acquire claim") {
            WorkspaceCommandAdmissionAcquireV1::Claimed { identity, claim } => (identity, claim),
            other => panic!("expected claim, got {other:?}"),
        };
        let generation = claim.generation();
        let uppercase = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: identity.fingerprint.to_ascii_uppercase(),
            recorded_at: 1.5,
            disposition: "invalid".to_owned(),
            before: None,
            after: None,
            catalog_revision: 0,
            resulting_digest: None,
            error_code: Some("workspace_unavailable".to_owned()),
            diagnostic: Some("workspace_not_found".to_owned()),
        };
        assert_eq!(
            claim.finalize_transient(uppercase),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        );
        assert!(matches!(
            admission.acquire(request).expect("claim remains active"),
            WorkspaceCommandAdmissionAcquireV1::Pending {
                generation: pending_generation,
                ..
            } if pending_generation == generation
        ));
        assert!(claim.abandon().expect("cleanup claim"));
    }

    #[test]
    fn command_admission_claim_generation_fences_aba_and_binds_exactly_once() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let request = command_identity_request(WorkspaceCommandKindV1::Save);
        let (identity, stale_claim) = match admission
            .acquire(request.clone())
            .expect("first acquire")
        {
            WorkspaceCommandAdmissionAcquireV1::Claimed { identity, claim } => (identity, claim),
            other => panic!("expected first claim, got {other:?}"),
        };
        let stale_generation = stale_claim.generation();
        assert!(stale_claim.abandon().expect("abandon first claim"));
        let current_claim = match admission.acquire(request).expect("second acquire") {
            WorkspaceCommandAdmissionAcquireV1::Claimed { claim, .. } => claim,
            other => panic!("expected replacement claim, got {other:?}"),
        };
        assert!(current_claim.generation() > stale_generation);

        let operation = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: identity.fingerprint,
            recorded_at: 2.0,
            disposition: "applied".to_owned(),
            before: None,
            after: None,
            catalog_revision: 2,
            resulting_digest: None,
            error_code: None,
            diagnostic: None,
        };
        assert_eq!(
            stale_claim.finalize_transient(operation.clone()),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        let mut effect_operation = operation.clone();
        effect_operation.operation_id = OPERATION_ID.to_uppercase();
        let effect = WorkspaceCommandAdmissionFinalizationV1::Workspace {
            workspace_id: WORKSPACE_ID.to_uppercase(),
            operation: effect_operation,
        };
        assert!(matches!(
            admission.bind_claim(&stale_claim, effect.clone()),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        ));
        let reservation = admission
            .bind_claim(&current_claim, effect.clone())
            .expect("bind current claim");
        assert!(matches!(
            admission.bind_claim(&current_claim, effect.clone()),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        ));
        reservation.cancel();

        let mut rebound = admission
            .bind_claim(&current_claim, effect)
            .expect("rebind after cancellation");
        rebound.finalize().expect("finalize rebound claim");
        assert!(
            !current_claim
                .abandon()
                .expect("finalized claim is already absent")
        );
        assert!(matches!(
            admission
                .decision_for_test(WORKSPACE_ID, OPERATION_ID, &operation.fingerprint)
                .expect("finalized decision"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Workspace,
                operation: replayed,
            } if replayed == operation
        ));
    }

    #[test]
    fn command_admission_reconcile_terminalizes_unbound_claim_and_rejects_collision_atomically() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let request = command_identity_request(WorkspaceCommandKindV1::Save);
        let (identity, claim) = match admission.acquire(request.clone()).expect("acquire claim") {
            WorkspaceCommandAdmissionAcquireV1::Claimed { identity, claim } => (identity, claim),
            other => panic!("expected claim, got {other:?}"),
        };
        let operation = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: identity.fingerprint,
            recorded_at: 3.0,
            disposition: "applied".to_owned(),
            before: None,
            after: None,
            catalog_revision: 3,
            resulting_digest: None,
            error_code: None,
            diagnostic: None,
        };
        admission
            .reconcile_durable(&[WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: Some(WORKSPACE_ID.to_owned()),
                operation: operation.clone(),
            }])
            .expect("reconcile exact durable receipt");
        assert!(
            !claim
                .abandon()
                .expect("reconcile terminalized the unbound claim")
        );
        assert!(matches!(
            admission.acquire(request).expect("reconciled replay"),
            WorkspaceCommandAdmissionAcquireV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Workspace,
                operation: replayed,
                ..
            } if replayed == operation
        ));

        let collision_admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("collision admission");
        let collision_request = command_identity_request(WorkspaceCommandKindV1::Save);
        let collision_claim = match collision_admission
            .acquire(collision_request.clone())
            .expect("collision claim")
        {
            WorkspaceCommandAdmissionAcquireV1::Claimed { claim, .. } => claim,
            other => panic!("expected collision claim, got {other:?}"),
        };
        let mut conflicting = operation;
        conflicting.fingerprint = "f".repeat(64);
        assert_eq!(
            collision_admission.reconcile_workspace(
                WORKSPACE_ID,
                std::slice::from_ref(&conflicting),
                None
            ),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        );
        assert!(matches!(
            collision_admission
                .acquire(collision_request)
                .expect("claim remains after failed reconcile"),
            WorkspaceCommandAdmissionAcquireV1::Pending {
                generation,
                ..
            } if generation == collision_claim.generation()
        ));
        assert!(collision_claim.abandon().expect("cleanup collision claim"));
    }

    #[test]
    fn command_admission_claim_validation_precedes_finalization_mutation() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let (identity, claim) = match admission
            .acquire(command_identity_request(WorkspaceCommandKindV1::Save))
            .expect("acquire claim")
        {
            WorkspaceCommandAdmissionAcquireV1::Claimed { identity, claim } => (identity, claim),
            other => panic!("expected claim, got {other:?}"),
        };
        let operation = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: identity.fingerprint,
            recorded_at: 4.0,
            disposition: "applied".to_owned(),
            before: None,
            after: None,
            catalog_revision: 4,
            resulting_digest: None,
            error_code: None,
            diagnostic: None,
        };
        let mut reservation = admission
            .bind_claim(
                &claim,
                WorkspaceCommandAdmissionFinalizationV1::Workspace {
                    workspace_id: WORKSPACE_ID.to_owned(),
                    operation: operation.clone(),
                },
            )
            .expect("bind claim");
        {
            let mut inner = claim.inner.lock().expect("claim state lock");
            inner
                .claims
                .get_mut(OPERATION_ID)
                .expect("claim state")
                .generation += 1;
        }
        assert_eq!(
            reservation.finalize(),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        assert!(matches!(
            admission
                .decision_for_test(WORKSPACE_ID, OPERATION_ID, &operation.fingerprint)
                .expect("failed finalization stayed invisible"),
            WorkspaceCommandAdmissionDecisionV1::Unseen
        ));
    }

    #[test]
    fn command_admission_prefers_workspace_then_global_and_retains_global_after_remove() {
        let local = admission_operation(OPERATION_ID.to_owned(), 'a', 1.0);
        let global_only = indexed_operation(2, 'b');
        let admission = PreparedWorkspaceCommandAdmissionV1::prepare(&[
            WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: Some(WORKSPACE_ID.to_owned()),
                operation: local.clone(),
            },
            WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: None,
                operation: global_only.clone(),
            },
        ])
        .expect("prepared admission");

        assert_eq!(
            admission
                .decision_for_test(WORKSPACE_ID, OPERATION_ID, &"a".repeat(64))
                .expect("local replay"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Workspace,
                operation: local.clone(),
            }
        );
        assert_eq!(
            admission
                .decision_for_test(WORKSPACE_ID, OPERATION_ID, &"c".repeat(64))
                .expect("local collision"),
            WorkspaceCommandAdmissionDecisionV1::Collision {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Workspace,
            }
        );
        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &global_only.operation_id,
                    &global_only.fingerprint,
                )
                .expect("global replay"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: global_only,
            }
        );
        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &indexed_operation(3, 'd').operation_id,
                    &"d".repeat(64)
                )
                .expect("unseen"),
            WorkspaceCommandAdmissionDecisionV1::Unseen
        );

        let removed = admission
            .remove_workspace_for_test(WORKSPACE_ID)
            .expect("remove local index");
        assert_eq!(removed.workspace_count, 0);
        assert_eq!(
            admission
                .decision_for_test(WORKSPACE_ID, OPERATION_ID, &"a".repeat(64))
                .expect("global retained replay"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: local,
            }
        );
    }

    #[test]
    fn command_admission_seed_is_deterministic_and_enforces_both_capacities() {
        let global_seed = (0..=MAXIMUM_WORKSPACE_COMMAND_ADMISSION_GLOBAL_OPERATION_COUNT_V1)
            .rev()
            .map(|index| WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: None,
                operation: indexed_operation(index, 'a'),
            })
            .collect::<Vec<_>>();
        let admission = PreparedWorkspaceCommandAdmissionV1::prepare(&global_seed)
            .expect("global capacity seed");
        assert_eq!(
            admission
                .diagnostics()
                .expect("diagnostics")
                .global_operation_count,
            MAXIMUM_WORKSPACE_COMMAND_ADMISSION_GLOBAL_OPERATION_COUNT_V1
        );
        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &indexed_operation(0, 'a').operation_id,
                    &"a".repeat(64)
                )
                .expect("evicted oldest"),
            WorkspaceCommandAdmissionDecisionV1::Unseen
        );

        let local_seed = (0..=MAXIMUM_WORKSPACE_COMMAND_ADMISSION_WORKSPACE_OPERATION_COUNT_V1)
            .map(|index| WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: Some(WORKSPACE_ID.to_owned()),
                operation: indexed_operation(index, 'b'),
            })
            .collect::<Vec<_>>();
        let local = PreparedWorkspaceCommandAdmissionV1::prepare(&local_seed)
            .expect("workspace capacity seed");
        let diagnostics = local.diagnostics().expect("local diagnostics");
        assert_eq!(diagnostics.workspace_count, 1);
        assert_eq!(
            diagnostics.workspace_operation_count,
            MAXIMUM_WORKSPACE_COMMAND_ADMISSION_WORKSPACE_OPERATION_COUNT_V1
        );
        let evicted_local = indexed_operation(0, 'b');
        assert_eq!(
            local
                .decision_for_test(
                    WORKSPACE_ID,
                    &evicted_local.operation_id,
                    &evicted_local.fingerprint,
                )
                .expect("evicted local falls back globally"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: evicted_local,
            }
        );

        let duplicate_id = indexed_operation(9_999, 'c').operation_id;
        let older = admission_operation(duplicate_id.clone(), 'c', 1.0);
        let newer = admission_operation(duplicate_id.clone(), 'd', 2.0);
        let duplicate = PreparedWorkspaceCommandAdmissionV1::prepare(&[
            WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: None,
                operation: newer.clone(),
            },
            WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: None,
                operation: older,
            },
        ])
        .expect("duplicate deterministic seed");
        assert_eq!(
            duplicate
                .decision_for_test(WORKSPACE_ID, &duplicate_id, &newer.fingerprint)
                .expect("newest duplicate"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: newer,
            }
        );
    }

    #[test]
    fn command_admission_collapses_duplicates_before_capacity_and_rejects_ambiguous_ties() {
        let duplicated_seed = (0..MAXIMUM_WORKSPACE_COMMAND_ADMISSION_GLOBAL_OPERATION_COUNT_V1)
            .flat_map(|index| {
                let operation = indexed_operation(index, 'e');
                [
                    WorkspaceCommandAdmissionSeedRecordV1 {
                        workspace_id: None,
                        operation: operation.clone(),
                    },
                    WorkspaceCommandAdmissionSeedRecordV1 {
                        workspace_id: None,
                        operation,
                    },
                ]
            })
            .collect::<Vec<_>>();
        let admission = PreparedWorkspaceCommandAdmissionV1::prepare(&duplicated_seed)
            .expect("duplicates collapse before capacity");
        assert_eq!(
            admission
                .diagnostics()
                .expect("diagnostics")
                .global_operation_count,
            MAXIMUM_WORKSPACE_COMMAND_ADMISSION_GLOBAL_OPERATION_COUNT_V1
        );
        let oldest = indexed_operation(0, 'e');
        assert!(matches!(
            admission
                .decision_for_test(WORKSPACE_ID, &oldest.operation_id, &oldest.fingerprint)
                .expect("oldest retained"),
            WorkspaceCommandAdmissionDecisionV1::Replay { .. }
        ));

        let first = admission_operation(indexed_operation(9_998, 'f').operation_id, 'f', 7.0);
        let mut conflicting = first.clone();
        conflicting.fingerprint = "0".repeat(64);
        for seed in [
            vec![first.clone(), conflicting.clone()],
            vec![conflicting.clone(), first.clone()],
        ] {
            assert!(matches!(
                PreparedWorkspaceCommandAdmissionV1::prepare(
                    &seed
                        .into_iter()
                        .map(|operation| WorkspaceCommandAdmissionSeedRecordV1 {
                            workspace_id: None,
                            operation,
                        })
                        .collect::<Vec<_>>()
                ),
                Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
            ));
        }
    }

    #[test]
    fn command_admission_live_insert_respects_reconstructible_total_atomically() {
        let seed = (0..240usize)
            .flat_map(|workspace| {
                let workspace_id = format!("00000000-0000-0000-0000-{workspace:012x}");
                (0..MAXIMUM_WORKSPACE_COMMAND_ADMISSION_WORKSPACE_OPERATION_COUNT_V1).map(
                    move |offset| WorkspaceCommandAdmissionSeedRecordV1 {
                        workspace_id: Some(workspace_id.clone()),
                        operation: indexed_operation(
                            workspace
                                * MAXIMUM_WORKSPACE_COMMAND_ADMISSION_WORKSPACE_OPERATION_COUNT_V1
                                + offset,
                            'a',
                        ),
                    },
                )
            })
            .collect::<Vec<_>>();
        let admission = PreparedWorkspaceCommandAdmissionV1::prepare(&seed)
            .expect("maximum reconstructible admission");
        let before = admission.diagnostics().expect("before diagnostics");
        assert_eq!(
            before.global_operation_count + before.workspace_operation_count,
            MAXIMUM_WORKSPACE_COMMAND_ADMISSION_RECOVERY_RECORD_COUNT_V1
        );
        let overflow = indexed_operation(seed.len() + 1, 'b');
        assert!(matches!(
            admission.insert_for_test(
                Some("ffffffff-ffff-ffff-ffff-ffffffffffff".to_owned()),
                overflow
            ),
            Err(WorkspaceWorkingJournalError::InputTooLarge { .. })
        ));
        assert_eq!(admission.diagnostics().expect("after diagnostics"), before);
        let pending_delete = admission
            .reserve(WorkspaceCommandAdmissionFinalizationV1::Delete {
                workspace_id: "00000000-0000-0000-0000-000000000000".to_owned(),
                operation: indexed_operation(seed.len() + 2, 'c'),
            })
            .expect("pending delete uses bounded global capacity");
        assert!(matches!(
            admission.reserve(WorkspaceCommandAdmissionFinalizationV1::Workspace {
                workspace_id: "ffffffff-ffff-ffff-ffff-ffffffffffff".to_owned(),
                operation: indexed_operation(seed.len() + 3, 'd'),
            }),
            Err(WorkspaceWorkingJournalError::InputTooLarge { .. })
        ));
        pending_delete.cancel();
        assert_eq!(
            admission.diagnostics().expect("after reservation overflow"),
            before
        );
    }

    #[test]
    fn command_admission_replace_insert_failure_and_close_are_atomic() {
        let original = indexed_operation(1, 'a');
        let replacement = indexed_operation(2, 'b');
        let admission = PreparedWorkspaceCommandAdmissionV1::prepare(&[
            WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: Some(WORKSPACE_ID.to_owned()),
                operation: original.clone(),
            },
        ])
        .expect("prepared admission");
        let before = admission.diagnostics().expect("before diagnostics");
        assert_eq!(
            admission.insert_for_test(Some("not-a-uuid".to_owned()), replacement.clone()),
            Err(WorkspaceWorkingJournalError::InvalidIdentity)
        );
        assert_eq!(
            admission.diagnostics().expect("after invalid insert"),
            before
        );

        let mut malformed = replacement.clone();
        malformed.fingerprint = "bad".to_owned();
        assert_eq!(
            admission.insert_for_test(None, malformed),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        );
        assert_eq!(
            admission.diagnostics().expect("after malformed insert"),
            before
        );

        let mut conflicting = original.clone();
        conflicting.fingerprint = "f".repeat(64);
        assert_eq!(
            admission.insert_for_test(Some(WORKSPACE_ID.to_owned()), conflicting),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        );
        assert_eq!(
            admission.diagnostics().expect("after conflicting insert"),
            before
        );

        let replacement_seed = [WorkspaceCommandAdmissionSeedRecordV1 {
            workspace_id: None,
            operation: replacement.clone(),
        }];
        assert_eq!(
            admission
                .replace_for_test(&replacement_seed)
                .expect("replace"),
            WorkspaceCommandAdmissionDiagnosticsV1 {
                global_operation_count: 1,
                workspace_count: 0,
                workspace_operation_count: 0,
            }
        );
        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &replacement.operation_id,
                    &replacement.fingerprint
                )
                .expect("replacement replay"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: replacement,
            }
        );

        admission.close();
        admission.close();
        assert_eq!(
            admission.diagnostics(),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        assert_eq!(
            admission.replace_for_test(&replacement_seed),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
    }

    #[test]
    fn command_admission_durable_reconcile_preserves_global_and_replaces_workspaces_atomically() {
        let retained_global = indexed_operation(1, 'a');
        let removed_workspace = indexed_operation(2, 'b');
        let replacement_workspace = indexed_operation(3, 'c');
        let admission = PreparedWorkspaceCommandAdmissionV1::prepare(&[
            WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: None,
                operation: retained_global.clone(),
            },
            WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: Some(WORKSPACE_ID.to_owned()),
                operation: removed_workspace.clone(),
            },
        ])
        .expect("prepared admission");
        admission
            .reconcile_durable(&[WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: Some(WORKSPACE_ID.to_owned()),
                operation: replacement_workspace.clone(),
            }])
            .expect("durable reconcile");

        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &retained_global.operation_id,
                    &retained_global.fingerprint
                )
                .expect("retained global decision"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: retained_global.clone(),
            }
        );
        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &removed_workspace.operation_id,
                    &removed_workspace.fingerprint
                )
                .expect("removed workspace decision"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: removed_workspace,
            }
        );
        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &replacement_workspace.operation_id,
                    &replacement_workspace.fingerprint
                )
                .expect("replacement workspace decision"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Workspace,
                operation: replacement_workspace,
            }
        );

        let mut conflicting = retained_global;
        conflicting.fingerprint = "f".repeat(64);
        let before = admission.diagnostics().expect("before conflict");
        assert_eq!(
            admission.reconcile_durable(&[WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: None,
                operation: conflicting,
            }]),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        );
        assert_eq!(admission.diagnostics().expect("after conflict"), before);
    }

    #[test]
    fn command_admission_reservation_is_invisible_until_finalize_and_cancel_is_clean() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let request = command_identity_request(WorkspaceCommandKindV1::Save);
        let identity = admission
            .inspect_for_test(request.clone())
            .expect("initial preflight")
            .identity;
        let operation = WorkspaceRecordedOperationV1 {
            operation_id: OPERATION_ID.to_owned(),
            fingerprint: identity.fingerprint.clone(),
            recorded_at: 1.0,
            disposition: "applied".to_owned(),
            before: None,
            after: None,
            catalog_revision: 1,
            resulting_digest: None,
            error_code: None,
            diagnostic: None,
        };
        let mut reservation = admission
            .reserve(WorkspaceCommandAdmissionFinalizationV1::Workspace {
                workspace_id: WORKSPACE_ID.to_owned(),
                operation: operation.clone(),
            })
            .expect("reserve operation");
        assert!(matches!(
            admission
                .inspect_for_test(request.clone())
                .expect("reservation remains invisible")
                .decision,
            WorkspaceCommandAdmissionDecisionV1::Unseen
        ));
        assert_eq!(
            admission.diagnostics().expect("visible diagnostics"),
            WorkspaceCommandAdmissionDiagnosticsV1 {
                global_operation_count: 0,
                workspace_count: 0,
                workspace_operation_count: 0,
            }
        );

        let mut conflicting = operation.clone();
        conflicting.fingerprint = "f".repeat(64);
        assert!(matches!(
            admission.reserve(WorkspaceCommandAdmissionFinalizationV1::Workspace {
                workspace_id: WORKSPACE_ID.to_owned(),
                operation: conflicting,
            }),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        ));
        reservation.finalize().expect("finalize operation");
        assert_eq!(
            admission
                .inspect_for_test(request)
                .expect("finalized replay")
                .decision,
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Workspace,
                operation,
            }
        );

        let cancelled = indexed_operation(99, 'c');
        admission
            .reserve(WorkspaceCommandAdmissionFinalizationV1::Workspace {
                workspace_id: WORKSPACE_ID.to_owned(),
                operation: cancelled.clone(),
            })
            .expect("reserve cancelled operation")
            .cancel();
        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &cancelled.operation_id,
                    &cancelled.fingerprint
                )
                .expect("cancelled decision"),
            WorkspaceCommandAdmissionDecisionV1::Unseen
        );
    }

    #[test]
    fn command_admission_reservations_fence_delete_workspace_reordering() {
        let admission =
            PreparedWorkspaceCommandAdmissionV1::prepare(&[]).expect("prepared admission");
        let workspace_operation = indexed_operation(1, 'a');
        let tombstone = indexed_operation(2, 'b');

        let pending_workspace = admission
            .reserve(WorkspaceCommandAdmissionFinalizationV1::Workspace {
                workspace_id: WORKSPACE_ID.to_owned(),
                operation: workspace_operation.clone(),
            })
            .expect("reserve workspace operation");
        assert!(matches!(
            admission.reserve(WorkspaceCommandAdmissionFinalizationV1::Delete {
                workspace_id: WORKSPACE_ID.to_owned(),
                operation: tombstone.clone(),
            }),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        ));
        pending_workspace.cancel();

        let pending_delete = admission
            .reserve(WorkspaceCommandAdmissionFinalizationV1::Delete {
                workspace_id: WORKSPACE_ID.to_owned(),
                operation: tombstone,
            })
            .expect("reserve delete");
        assert!(matches!(
            admission.reserve(WorkspaceCommandAdmissionFinalizationV1::Workspace {
                workspace_id: WORKSPACE_ID.to_owned(),
                operation: workspace_operation,
            }),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        ));
        pending_delete.cancel();
        assert_eq!(
            admission
                .diagnostics()
                .expect("reservations stay invisible"),
            WorkspaceCommandAdmissionDiagnosticsV1 {
                global_operation_count: 0,
                workspace_count: 0,
                workspace_operation_count: 0,
            }
        );
    }

    #[test]
    fn command_admission_delete_finalization_and_targeted_reconcile_are_atomic() {
        let local = indexed_operation(1, 'a');
        let tombstone = indexed_operation(2, 'b');
        let admission = PreparedWorkspaceCommandAdmissionV1::prepare(&[
            WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: Some(WORKSPACE_ID.to_owned()),
                operation: local.clone(),
            },
        ])
        .expect("prepared admission");
        let mut reservation = admission
            .reserve(WorkspaceCommandAdmissionFinalizationV1::Delete {
                workspace_id: WORKSPACE_ID.to_owned(),
                operation: tombstone.clone(),
            })
            .expect("reserve delete");
        assert!(matches!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &tombstone.operation_id,
                    &tombstone.fingerprint
                )
                .expect("tombstone remains invisible"),
            WorkspaceCommandAdmissionDecisionV1::Unseen
        ));
        let finalized = reservation.finalize().expect("finalize delete");
        assert_eq!(finalized.workspace_count, 0);
        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &tombstone.operation_id,
                    &tombstone.fingerprint
                )
                .expect("tombstone replay"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: tombstone.clone(),
            }
        );
        let mut amended_tombstone = tombstone.clone();
        amended_tombstone.diagnostic =
            Some("artifact_cleanup_incomplete: workspace document: denied".to_owned());
        admission
            .reconcile_finalized_delete(WORKSPACE_ID, tombstone.clone(), amended_tombstone.clone())
            .expect("reconcile finalized delete");
        admission
            .reconcile_finalized_delete(WORKSPACE_ID, tombstone.clone(), amended_tombstone.clone())
            .expect("idempotent finalized delete retry");
        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &tombstone.operation_id,
                    &tombstone.fingerprint
                )
                .expect("amended tombstone replay"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: amended_tombstone,
            }
        );
        assert_eq!(
            admission
                .decision_for_test(WORKSPACE_ID, &local.operation_id, &local.fingerprint)
                .expect("prior receipt retained globally"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Global,
                operation: local.clone(),
            }
        );

        let replacement = indexed_operation(3, 'c');
        admission
            .reconcile_workspace(WORKSPACE_ID, std::slice::from_ref(&replacement), None)
            .expect("targeted workspace reconcile");
        assert_eq!(
            admission
                .decision_for_test(
                    WORKSPACE_ID,
                    &replacement.operation_id,
                    &replacement.fingerprint
                )
                .expect("replacement replay"),
            WorkspaceCommandAdmissionDecisionV1::Replay {
                scope: WorkspaceCommandAdmissionLookupScopeV1::Workspace,
                operation: replacement,
            }
        );

        let pending = indexed_operation(4, 'd');
        let _pending_reservation = admission
            .reserve(WorkspaceCommandAdmissionFinalizationV1::Workspace {
                workspace_id: WORKSPACE_ID.to_owned(),
                operation: pending.clone(),
            })
            .expect("reserve pending operation");
        let mut conflicting = pending;
        conflicting.fingerprint = "e".repeat(64);
        let before = admission.diagnostics().expect("before failed reconcile");
        assert_eq!(
            admission.reconcile_workspace(WORKSPACE_ID, &[conflicting], None),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        );
        assert_eq!(
            admission.diagnostics().expect("failed reconcile is atomic"),
            before
        );
    }

    #[test]
    fn command_admission_restart_reconstruction_is_equivalent() {
        let seed = [
            WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: Some(WORKSPACE_ID.to_owned()),
                operation: indexed_operation(1, 'a'),
            },
            WorkspaceCommandAdmissionSeedRecordV1 {
                workspace_id: None,
                operation: indexed_operation(2, 'b'),
            },
        ];
        let first = PreparedWorkspaceCommandAdmissionV1::prepare(&seed).expect("first runtime");
        let restarted =
            PreparedWorkspaceCommandAdmissionV1::prepare(&seed).expect("restarted runtime");
        for operation in [&seed[0].operation, &seed[1].operation] {
            assert_eq!(
                first
                    .decision_for_test(
                        WORKSPACE_ID,
                        &operation.operation_id,
                        &operation.fingerprint
                    )
                    .expect("first decision"),
                restarted
                    .decision_for_test(
                        WORKSPACE_ID,
                        &operation.operation_id,
                        &operation.fingerprint
                    )
                    .expect("restarted decision")
            );
        }
        assert_eq!(
            first.diagnostics().expect("first diagnostics"),
            restarted.diagnostics().expect("restart diagnostics")
        );
    }

    #[test]
    fn command_identity_matches_frozen_swift_encoding() {
        let identity =
            workspace_command_identity_v1(command_identity_request(WorkspaceCommandKindV1::Create))
                .expect("command identity");
        assert_eq!(identity.workspace_id, WORKSPACE_ID);
        assert_eq!(identity.command_kind, WorkspaceCommandKindV1::Create);
        assert_eq!(
            identity.fingerprint,
            "4a06f1cb575766d8be224014ef503c41ccd40d82a94521be142f4746cbd4b9f0"
        );
    }

    #[test]
    fn command_identity_covers_all_shapes_and_stable_protected_order() {
        let kinds = [
            WorkspaceCommandKindV1::Create,
            WorkspaceCommandKindV1::Replace,
            WorkspaceCommandKindV1::Save,
            WorkspaceCommandKindV1::Delete,
        ];
        let fingerprints = kinds
            .into_iter()
            .map(|kind| {
                let mut request = command_identity_request(kind);
                request.origin = match kind {
                    WorkspaceCommandKindV1::Create => WorkspaceCommandOriginV1::AppMcp {
                        connection_id: Some("12345678-1234-1234-1234-123456789abc".to_owned()),
                    },
                    WorkspaceCommandKindV1::Replace => WorkspaceCommandOriginV1::AppMcp {
                        connection_id: None,
                    },
                    WorkspaceCommandKindV1::Save => WorkspaceCommandOriginV1::Standalone,
                    WorkspaceCommandKindV1::Delete => WorkspaceCommandOriginV1::ExternalReload,
                    WorkspaceCommandKindV1::ResolveExternalConflict => unreachable!(),
                };
                request.expected_catalog_revision = Some(7);
                request.expected_workspace_revision = Some(8);
                request.expected_context_revision = Some(9);
                workspace_command_identity_v1(request)
                    .expect("valid command")
                    .fingerprint
            })
            .collect::<BTreeSet<_>>();
        assert_eq!(fingerprints.len(), kinds.len());

        let first = WorkspaceProtectedAgentIdentityV1 {
            tab_id: "ffffffff-ffff-ffff-ffff-ffffffffffff".to_owned(),
            location: WorkspaceTabLocationV1::Stashed,
            active_agent_session_id: None,
            is_pinned: false,
        };
        let second = WorkspaceProtectedAgentIdentityV1 {
            tab_id: "00000000-0000-0000-0000-000000000001".to_owned(),
            location: WorkspaceTabLocationV1::Composed,
            active_agent_session_id: Some("abcdefab-cdef-abcd-efab-cdefabcdefab".to_owned()),
            is_pinned: true,
        };
        let mut forward = command_identity_request(WorkspaceCommandKindV1::ResolveExternalConflict);
        forward.protected_agent_identities = vec![first.clone(), second.clone()];
        let mut reversed =
            command_identity_request(WorkspaceCommandKindV1::ResolveExternalConflict);
        reversed.protected_agent_identities = vec![second, first];
        assert_eq!(
            workspace_command_identity_v1(forward)
                .expect("forward")
                .fingerprint,
            workspace_command_identity_v1(reversed)
                .expect("reversed")
                .fingerprint
        );
    }

    #[test]
    fn command_identity_rejects_invalid_or_contradictory_shape() {
        let mut invalid_identity = command_identity_request(WorkspaceCommandKindV1::Save);
        invalid_identity.operation_id = "not-a-uuid".to_owned();
        assert_eq!(
            workspace_command_identity_v1(invalid_identity),
            Err(WorkspaceWorkingJournalError::InvalidIdentity)
        );

        let mut invalid_digest = command_identity_request(WorkspaceCommandKindV1::Create);
        invalid_digest.content_digest = Some("not-a-digest".to_owned());
        assert_eq!(
            workspace_command_identity_v1(invalid_digest),
            Err(WorkspaceWorkingJournalError::InvalidDigest)
        );

        let mut contradictory = command_identity_request(WorkspaceCommandKindV1::Delete);
        contradictory.accept_external = Some(false);
        assert_eq!(
            workspace_command_identity_v1(contradictory),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );

        let mut oversized =
            command_identity_request(WorkspaceCommandKindV1::ResolveExternalConflict);
        oversized.protected_agent_identities = vec![
            WorkspaceProtectedAgentIdentityV1 {
                tab_id: "00000000-0000-0000-0000-000000000001".to_owned(),
                location: WorkspaceTabLocationV1::Composed,
                active_agent_session_id: None,
                is_pinned: false,
            };
            MAXIMUM_WORKSPACE_COMMAND_PROTECTED_IDENTITY_COUNT_V1
                + 1
        ];
        assert_eq!(
            workspace_command_identity_v1(oversized),
            Err(WorkspaceWorkingJournalError::InputTooLarge {
                actual: MAXIMUM_WORKSPACE_COMMAND_PROTECTED_IDENTITY_COUNT_V1 + 1,
                maximum: MAXIMUM_WORKSPACE_COMMAND_PROTECTED_IDENTITY_COUNT_V1,
            })
        );
    }

    fn document(prompt: &str) -> Vec<u8> {
        document_for_workspace(WORKSPACE_ID, prompt)
    }

    fn document_for_workspace(workspace_id: &str, prompt: &str) -> Vec<u8> {
        format!(
            r#"{{"id":"{workspace_id}","schemaVersion":1,"name":"Workspace","composeTabs":[{{"id":"{CONTEXT_ID}","name":"Context","prompt":"{prompt}","selectedPaths":[]}}]}}"#
        )
        .into_bytes()
    }

    fn document_with_context_prompts(first: &str, second: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "id": WORKSPACE_ID,
            "schemaVersion": 1,
            "name": "Workspace",
            "composeTabs": [
                {
                    "id": CONTEXT_ID,
                    "name": "Context A",
                    "prompt": first,
                    "selectedPaths": []
                },
                {
                    "id": CONTEXT_ID_TWO,
                    "name": "Context B",
                    "prompt": second,
                    "selectedPaths": []
                }
            ]
        }))
        .expect("two-context document")
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
                "operationID": BASE_OPERATION_ID,
                "fingerprint": format!("{:x}", Sha256::digest(b"operation")),
                "recordedAt": 1.5,
                "disposition": "applied",
                "catalogRevision": 1
            }],
            "updatedAt": 2.5
        }))
        .expect("journal")
    }

    fn semantic_full_recovery(
        journal: WorkspaceRecoveryArtifactEvidenceV1,
        saved_document: WorkspaceRecoveryArtifactEvidenceV1,
    ) -> WorkspaceSemanticFullRecoveryV1 {
        WorkspaceSemanticFullRecoveryV1 {
            catalog_bytes: catalog_bytes(0),
            workspaces: vec![WorkspaceSemanticRecoveryEvidenceV1 {
                workspace_id: WORKSPACE_ID.to_owned(),
                journal,
                saved_document,
                saved_revision: WorkspaceRecoveryArtifactEvidenceV1::Absent,
            }],
            deletions: Vec::new(),
        }
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
        let kind = request["kind"].clone();
        plan_workspace_working_journal_transition_v1(
            current,
            &serde_json::to_vec(&request).expect("transition bytes"),
            document,
            None,
        )
        .unwrap_or_else(|error| panic!("transition {kind}: {error:?}"))
    }

    fn decoded(validation: &WorkspaceWorkingJournalValidationV1) -> WorkspaceWorkingJournalV1 {
        serde_json::from_slice(&validation.canonical_bytes).expect("canonical journal")
    }

    fn save_request(expected_revision: u64, catalog_revision: u64) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "semanticPlannerVersion": WORKSPACE_SEMANTIC_PLANNER_VERSION_V1,
            "expectedWorkspaceID": WORKSPACE_ID,
            "expectedFileURL": "file:///tmp/Workspace.json",
            "expectedWorkingRevision": expected_revision,
            "operationID": OPERATION_ID,
            "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
            "updatedAt": 3.0,
            "catalogRevision": catalog_revision
        }))
        .expect("save request")
    }

    fn catalog_bytes(revision: u64) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "revision": revision,
            "entries": [{
                "workspaceID": WORKSPACE_ID,
                "fileURL": "file:///tmp/Workspace.json"
            }],
            "deletions": [],
            "updatedAt": 2.75
        }))
        .expect("catalog")
    }

    fn catalog_with_non_target_deletion(catalog_revision: u64, operation_id: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "revision": catalog_revision,
            "entries": [{
                "workspaceID": WORKSPACE_ID,
                "fileURL": "file:///tmp/Workspace.json"
            }],
            "deletions": [{
                "version": 1,
                "workspaceID": OTHER_WORKSPACE_ID,
                "fileURL": "file:///tmp/OtherWorkspace.json",
                "operation": {
                    "operationID": operation_id,
                    "fingerprint": format!("{:x}", Sha256::digest(operation_id.as_bytes())),
                    "recordedAt": 1.0,
                    "disposition": "applied",
                    "before": revision(1, 1, None),
                    "catalogRevision": 1
                },
                "deletedAt": 1.0
            }],
            "updatedAt": 2.75
        }))
        .expect("catalog with non-target deletion")
    }

    fn delete_request(working_revision: u64, catalog_revision: u64) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "semanticPlannerVersion": WORKSPACE_SEMANTIC_PLANNER_VERSION_V1,
            "expectedWorkspaceID": WORKSPACE_ID,
            "expectedFileURL": "file:///tmp/Workspace.json",
            "expectedWorkingRevision": working_revision,
            "expectedCatalogRevision": catalog_revision,
            "operationID": OPERATION_ID,
            "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
            "deletedAt": 3.0
        }))
        .expect("delete request")
    }

    fn create_catalog_bytes(catalog_revision: u64, tombstoned: bool) -> Vec<u8> {
        let deletions = if tombstoned {
            vec![serde_json::json!({
                "version": 1,
                "workspaceID": WORKSPACE_ID,
                "fileURL": "file:///tmp/Workspace.json",
                "operation": {
                    "operationID": "77777777-8888-9999-aaaa-bbbbbbbbbbbb",
                    "fingerprint": format!("{:x}", Sha256::digest(b"delete")),
                    "recordedAt": 1.0,
                    "disposition": "applied",
                    "before": revision(1, 1, None),
                    "catalogRevision": catalog_revision,
                },
                "deletedAt": 1.0
            })]
        } else {
            Vec::new()
        };
        serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "revision": catalog_revision,
            "entries": [],
            "deletions": deletions,
            "updatedAt": 1.0
        }))
        .expect("create catalog")
    }

    fn create_request(catalog_revision: u64, _document_bytes: &[u8]) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "kind": "create",
            "semanticPlannerVersion": WORKSPACE_SEMANTIC_PLANNER_VERSION_V1,
            "expectedWorkspaceID": WORKSPACE_ID,
            "expectedFileURL": "file:///tmp/Workspace.json",
            "expectedCatalogRevision": catalog_revision,
            "operationID": OPERATION_ID,
            "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
            "updatedAt": 2.0
        }))
        .expect("create request")
    }

    fn recover_create_request(catalog_revision: u64) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "kind": "recover",
            "expectedWorkspaceID": WORKSPACE_ID,
            "expectedFileURL": "file:///tmp/Workspace.json",
            "expectedCatalogRevision": catalog_revision,
            "updatedAt": 3.0
        }))
        .expect("recover create request")
    }

    fn journal_mutation_request(
        transition: Value,
        catalog_revision: u64,
        revision_operation_id: Option<&str>,
    ) -> Vec<u8> {
        let recovery_mode =
            transition["operationID"].is_null() && transition["fingerprint"].is_null();
        serde_json::to_vec(&serde_json::json!({
            "semanticPlannerVersion": WORKSPACE_SEMANTIC_PLANNER_VERSION_V1,
            "expectedWorkspaceID": WORKSPACE_ID,
            "expectedFileURL": "file:///tmp/Workspace.json",
            "catalogRevision": catalog_revision,
            "revisionOperationID": revision_operation_id,
            "recoveryMode": recovery_mode,
            "transition": transition
        }))
        .expect("journal mutation request")
    }

    #[test]
    fn semantic_planner_version_is_required_for_every_command_transaction() {
        let raw_catalog = catalog_bytes(9);
        let effective_catalog =
            validate_workspace_catalog_v1(&raw_catalog).expect("effective catalog");
        let raw_journal = journal_bytes(None);
        let effective_journal =
            validate_workspace_working_journal_v1(&raw_journal).expect("effective journal");
        let candidate = document("saved");

        let mut create: Value =
            serde_json::from_slice(&create_request(9, &candidate)).expect("create request");
        create["semanticPlannerVersion"] = Value::from(0);
        assert_eq!(
            prepare_workspace_create_transaction_v1(
                Some(&raw_catalog),
                &effective_catalog.canonical_bytes,
                None,
                None,
                &serde_json::to_vec(&create).expect("create bytes"),
                &candidate,
            )
            .expect_err("create must reject an unknown planner"),
            WorkspaceWorkingJournalError::Malformed
        );

        let mut journal: Value = serde_json::from_slice(&journal_mutation_request(
            serde_json::json!({
                "kind": "working",
                "expectedWorkingRevision": 0,
                "updatedAt": 3.0
            }),
            9,
            None,
        ))
        .expect("journal request");
        journal["semanticPlannerVersion"] = Value::from(0);
        assert_eq!(
            prepare_workspace_journal_mutation_transaction_v1(
                Some(&raw_journal),
                &effective_journal.canonical_bytes,
                &serde_json::to_vec(&journal).expect("journal bytes"),
                &candidate,
                Some(&document("saved")),
            )
            .expect_err("journal must reject an unknown planner"),
            WorkspaceWorkingJournalError::Malformed
        );

        let mut claimless_command: Value = serde_json::from_slice(&journal_mutation_request(
            serde_json::json!({
                "kind": "working",
                "expectedWorkingRevision": 0,
                "updatedAt": 3.0
            }),
            9,
            None,
        ))
        .expect("claimless recovery request");
        claimless_command["recoveryMode"] = Value::from(false);
        assert_eq!(
            prepare_workspace_journal_mutation_transaction_v1(
                Some(&raw_journal),
                &effective_journal.canonical_bytes,
                &serde_json::to_vec(&claimless_command).expect("claimless command bytes"),
                &candidate,
                Some(&document("saved")),
            )
            .expect_err("claimless command mode must be rejected"),
            WorkspaceWorkingJournalError::InvalidTransaction
        );

        let mut claimed_recovery: Value = serde_json::from_slice(&journal_mutation_request(
            serde_json::json!({
                "kind": "working",
                "expectedWorkingRevision": 0,
                "operationID": OPERATION_ID,
                "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
                "updatedAt": 3.0
            }),
            9,
            None,
        ))
        .expect("claimed command request");
        claimed_recovery["recoveryMode"] = Value::from(true);
        assert_eq!(
            prepare_workspace_journal_mutation_transaction_v1(
                Some(&raw_journal),
                &effective_journal.canonical_bytes,
                &serde_json::to_vec(&claimed_recovery).expect("claimed recovery bytes"),
                &candidate,
                Some(&document("saved")),
            )
            .expect_err("claimed recovery mode must be rejected"),
            WorkspaceWorkingJournalError::InvalidTransaction
        );

        let mut save: Value = serde_json::from_slice(&save_request(0, 9)).expect("save request");
        save["semanticPlannerVersion"] = Value::from(0);
        assert_eq!(
            prepare_workspace_save_transaction_v1(
                Some(&raw_journal),
                &effective_journal.canonical_bytes,
                &serde_json::to_vec(&save).expect("save bytes"),
                &candidate,
                Some(&candidate),
            )
            .expect_err("save must reject an unknown planner"),
            WorkspaceWorkingJournalError::Malformed
        );

        let mut delete: Value =
            serde_json::from_slice(&delete_request(0, 9)).expect("delete request");
        delete["semanticPlannerVersion"] = Value::from(0);
        assert_eq!(
            prepare_workspace_delete_transaction_v1(
                Some(&raw_catalog),
                &effective_catalog.canonical_bytes,
                &effective_journal.canonical_bytes,
                &serde_json::to_vec(&delete).expect("delete bytes"),
            )
            .expect_err("delete must reject an unknown planner"),
            WorkspaceWorkingJournalError::Malformed
        );
    }

    #[test]
    fn operation_append_is_idempotent_and_rejects_semantic_collisions() {
        let current = decoded(
            &validate_workspace_working_journal_v1(&journal_bytes(None))
                .expect("effective journal"),
        );
        let revisions = WorkspaceProjectionRevisionState {
            working_revision: 0,
            saved_revision: 0,
            dirty_revision: None,
        };
        let resulting_digest = format!("{:x}", Sha256::digest(document("saved")));
        let operation = planned_operation_v1(
            OPERATION_ID.to_owned(),
            format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
            Value::from(3.0),
            "unchanged",
            Some(revisions),
            Some(revisions),
            9,
            Some(resulting_digest.clone()),
        )
        .expect("planned operation");
        let mut with_operation = current.clone();
        with_operation.operations.push(operation.clone());

        let replay = planned_operation_v1(
            OPERATION_ID.to_owned(),
            format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
            Value::from(4.0),
            "unchanged",
            Some(revisions),
            Some(revisions),
            9,
            Some(resulting_digest),
        )
        .expect("replayed operation");
        let retained =
            append_planned_operation_v1(&with_operation, Some(replay), &Value::from(4.0))
                .expect("exact replay is idempotent");
        assert_eq!(retained.len(), with_operation.operations.len());
        assert_eq!(retained.last(), Some(&operation));

        let mut collision = operation;
        collision.fingerprint = format!("{:x}", Sha256::digest(b"different"));
        assert_eq!(
            append_planned_operation_v1(&with_operation, Some(collision), &Value::from(4.0)),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        );
    }

    #[test]
    fn clean_transitions_preserve_unchanged_context_revisions() {
        let current_document = document_with_context_prompts("stable", "same");
        let context_digests = workspace_document_context_digests_from_bytes_v1(&current_document)
            .expect("current context digests");
        let mut current_value: Value =
            serde_json::from_slice(&journal_bytes(None)).expect("current journal");
        current_value["revisions"] = revision(4, 4, None);
        current_value["savedDigest"] =
            Value::String(format!("{:x}", Sha256::digest(&current_document)));
        current_value["contextRevisions"] = serde_json::json!([
            CONTEXT_ID,
            revision(2, 2, None),
            CONTEXT_ID_TWO,
            revision(7, 7, None)
        ]);
        current_value["contextDigests"] =
            workspace_recovery_context_digests_value_v1(&context_digests);
        current_value["operations"] = Value::Array(Vec::new());
        let current = serde_json::to_vec(&current_value).expect("current bytes");

        let save_plan = transition(
            serde_json::json!({
                "kind": "save",
                "expectedWorkingRevision": 4,
                "operationID": OPERATION_ID,
                "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
                "updatedAt": 5.0
            }),
            Some(&current),
            Some(&current_document),
        );
        let save_committed = decoded(save_plan.committed.as_ref().expect("save committed"));
        let save_contexts =
            context_revision_map_v1(&save_committed.context_revisions).expect("save contexts");
        assert_eq!(
            save_contexts.get(CONTEXT_ID),
            Some(&WorkspaceProjectionRevisionState {
                working_revision: 2,
                saved_revision: 2,
                dirty_revision: None
            })
        );
        assert_eq!(
            save_contexts.get(CONTEXT_ID_TWO),
            Some(&WorkspaceProjectionRevisionState {
                working_revision: 7,
                saved_revision: 7,
                dirty_revision: None
            })
        );

        let external_document = document_with_context_prompts("changed", "same");
        let external_plan = transition(
            serde_json::json!({
                "kind": "externalReload",
                "expectedWorkingRevision": 4,
                "updatedAt": 6.0
            }),
            Some(&current),
            Some(&external_document),
        );
        let external = decoded(&external_plan.primary);
        assert_eq!(external.revisions.working_revision, 5);
        let external_contexts =
            context_revision_map_v1(&external.context_revisions).expect("external contexts");
        assert_eq!(
            external_contexts.get(CONTEXT_ID),
            Some(&WorkspaceProjectionRevisionState {
                working_revision: 5,
                saved_revision: 5,
                dirty_revision: None
            })
        );
        assert_eq!(
            external_contexts.get(CONTEXT_ID_TWO),
            Some(&WorkspaceProjectionRevisionState {
                working_revision: 7,
                saved_revision: 7,
                dirty_revision: None
            })
        );
    }

    #[test]
    fn journal_mutation_transaction_commits_working_state_at_journal_authority() {
        let raw = journal_bytes(None);
        let effective = validate_workspace_working_journal_v1(&raw).expect("effective journal");
        let candidate = document("working");
        let transition = serde_json::json!({
            "kind": "working",
            "expectedWorkingRevision": 0,
            "updatedAt": 3.0
        });
        let transaction = prepare_workspace_journal_mutation_transaction_v1(
            Some(&raw),
            &effective.canonical_bytes,
            &journal_mutation_request(transition, 7, None),
            &candidate,
            Some(&document("saved")),
        )
        .expect("working transaction");
        assert_eq!(
            transaction
                .command_authority_publication_kind()
                .expect("working publication kind"),
            WorkspaceProjectionPublicationKind::WorkingStateCommitted
        );
        assert!(transaction.is_ready_for_authority());
        assert!(!transaction.is_authoritative());
        let (action_id, digest, receipt) =
            match transaction.next_directive().expect("journal action") {
                WorkspaceJournalMutationDirectiveV1::Action {
                    action_id,
                    kind: WorkspaceJournalMutationActionKindV1::WriteJournal,
                    content_digest,
                    authority_receipt: Some(receipt),
                    logical_expected_revision: Some(0),
                    post_authority_success_finalization:
                        Some(WorkspaceJournalMutationFinalizationV1::Finalized),
                    post_authority_failure_finalization: None,
                    ..
                } => (action_id, content_digest, receipt),
                other => panic!("unexpected working directive: {other:?}"),
            };
        let committed = decoded(&receipt.committed_journal);
        assert_eq!(committed.revisions.working_revision, 1);
        assert_eq!(committed.revisions.saved_revision, 0);
        assert_eq!(committed.revisions.dirty_revision, Some(1));
        assert_eq!(receipt.catalog_revision, 7);
        assert_eq!(
            transaction
                .report_action(WorkspaceJournalMutationActionReportV1::Success {
                    action_id,
                    written_digest: digest,
                })
                .expect("commit working journal"),
            WorkspaceJournalMutationDirectiveV1::Committed {
                receipt,
                finalization: WorkspaceJournalMutationFinalizationV1::Finalized,
            }
        );
        assert!(transaction.is_authoritative());
    }

    #[test]
    fn external_reload_transaction_cleans_contexts_and_commits_without_revision_sidecar() {
        let raw = journal_bytes(None);
        let effective = validate_workspace_working_journal_v1(&raw).expect("effective journal");
        let external = document("external");
        let transition = serde_json::json!({
            "kind": "externalReload",
            "expectedWorkingRevision": 0,
            "updatedAt": 4.0
        });
        let transaction = prepare_workspace_journal_mutation_transaction_v1(
            Some(&raw),
            &effective.canonical_bytes,
            &journal_mutation_request(transition, 8, Some(OPERATION_ID)),
            &external,
            Some(&external),
        )
        .expect("external reload transaction");
        assert_eq!(
            transaction
                .command_authority_publication_kind()
                .expect("external publication kind"),
            WorkspaceProjectionPublicationKind::ExternalReloaded
        );
        let (journal_action, journal_digest, receipt) =
            match transaction.next_directive().expect("journal action") {
                WorkspaceJournalMutationDirectiveV1::Action {
                    action_id,
                    kind: WorkspaceJournalMutationActionKindV1::WriteJournal,
                    content_digest,
                    authority_receipt: Some(receipt),
                    post_authority_success_finalization:
                        Some(WorkspaceJournalMutationFinalizationV1::RevisionSidecarMissing),
                    post_authority_failure_finalization: None,
                    ..
                } => (action_id, content_digest, receipt),
                other => panic!("unexpected external directive: {other:?}"),
            };
        let committed = decoded(&receipt.committed_journal);
        assert_eq!(
            committed.context_revisions,
            serde_json::json!([
                CONTEXT_ID,
                {"workingRevision": 1, "savedRevision": 1, "dirtyRevision": null}
            ])
        );
        assert_eq!(
            committed.saved_digest,
            format!("{:x}", Sha256::digest(&external))
        );
        let revision_action = transaction
            .report_action(WorkspaceJournalMutationActionReportV1::Success {
                action_id: journal_action,
                written_digest: journal_digest,
            })
            .expect("advance to saved revision");
        assert!(transaction.is_authoritative());
        let revision_action_id = match revision_action {
            WorkspaceJournalMutationDirectiveV1::Action {
                action_id,
                kind: WorkspaceJournalMutationActionKindV1::WriteSavedRevision,
                authority_receipt: None,
                post_authority_success_finalization:
                    Some(WorkspaceJournalMutationFinalizationV1::Finalized),
                post_authority_failure_finalization:
                    Some(WorkspaceJournalMutationFinalizationV1::RevisionSidecarMissing),
                ..
            } => action_id,
            other => panic!("unexpected revision directive: {other:?}"),
        };
        assert_eq!(
            transaction
                .report_action(WorkspaceJournalMutationActionReportV1::WriteFailed {
                    action_id: revision_action_id,
                })
                .expect("commit missing sidecar"),
            WorkspaceJournalMutationDirectiveV1::Committed {
                receipt,
                finalization: WorkspaceJournalMutationFinalizationV1::RevisionSidecarMissing,
            }
        );

        assert_eq!(
            prepare_workspace_journal_mutation_transaction_v1(
                Some(&raw),
                &effective.canonical_bytes,
                &journal_mutation_request(
                    serde_json::json!({
                        "kind": "externalReload",
                        "expectedWorkingRevision": 0,
                        "updatedAt": 4.0
                    }),
                    8,
                    Some(OPERATION_ID)
                ),
                &external,
                Some(&document("different")),
            )
            .expect_err("divergent disk must fail"),
            WorkspaceWorkingJournalError::ExternalDocumentConflict
        );
    }

    #[test]
    fn journal_mutation_transaction_accepts_unchanged_and_conflict_rebase() {
        let raw_clean = journal_bytes(None);
        let effective_clean =
            validate_workspace_working_journal_v1(&raw_clean).expect("effective clean journal");
        let unchanged_operation_id = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";
        let unchanged = prepare_workspace_journal_mutation_transaction_v1(
            Some(&raw_clean),
            &effective_clean.canonical_bytes,
            &journal_mutation_request(
                serde_json::json!({
                    "kind": "unchanged",
                    "expectedWorkingRevision": 0,
                    "operationID": unchanged_operation_id,
                    "fingerprint": format!("{:x}", Sha256::digest(unchanged_operation_id.as_bytes())),
                    "updatedAt": 3.0
                }),
                9,
                None,
            ),
            &document("saved"),
            Some(&document("saved")),
        )
        .expect("unchanged transaction");
        assert_eq!(
            unchanged
                .command_authority_publication_kind()
                .expect("unchanged publication kind"),
            WorkspaceProjectionPublicationKind::OperationDeduplicated
        );
        let (action_id, digest, receipt) =
            match unchanged.next_directive().expect("unchanged action") {
                WorkspaceJournalMutationDirectiveV1::Action {
                    action_id,
                    kind: WorkspaceJournalMutationActionKindV1::WriteJournal,
                    content_digest,
                    authority_receipt: Some(receipt),
                    ..
                } => (action_id, content_digest, receipt),
                other => panic!("unexpected unchanged directive: {other:?}"),
            };
        assert!(
            decoded(&receipt.committed_journal)
                .operations
                .iter()
                .any(|operation| operation.operation_id == unchanged_operation_id)
        );
        assert!(matches!(
            unchanged
                .report_action(WorkspaceJournalMutationActionReportV1::Success {
                    action_id,
                    written_digest: digest,
                })
                .expect("commit unchanged"),
            WorkspaceJournalMutationDirectiveV1::Committed {
                finalization: WorkspaceJournalMutationFinalizationV1::Finalized,
                ..
            }
        ));

        let local = document("local dirty");
        let raw_dirty = journal_bytes(Some(&local));
        let effective_dirty =
            validate_workspace_working_journal_v1(&raw_dirty).expect("effective dirty journal");
        let dirty_unchanged_operation_id = "cccccccc-dddd-eeee-ffff-000000000001";
        let dirty_unchanged = prepare_workspace_journal_mutation_transaction_v1(
            Some(&raw_dirty),
            &effective_dirty.canonical_bytes,
            &journal_mutation_request(
                serde_json::json!({
                    "kind": "unchanged",
                    "expectedWorkingRevision": 1,
                    "operationID": dirty_unchanged_operation_id,
                    "fingerprint": format!("{:x}", Sha256::digest(dirty_unchanged_operation_id.as_bytes())),
                    "updatedAt": 3.0
                }),
                9,
                None,
            ),
            &local,
            Some(&local),
        )
        .expect("dirty unchanged transaction");
        let dirty_unchanged_receipt = match dirty_unchanged
            .next_directive()
            .expect("dirty unchanged action")
        {
            WorkspaceJournalMutationDirectiveV1::Action {
                action_id,
                kind: WorkspaceJournalMutationActionKindV1::WriteJournal,
                content_digest,
                authority_receipt: Some(receipt),
                ..
            } => {
                dirty_unchanged
                    .report_action(WorkspaceJournalMutationActionReportV1::Success {
                        action_id,
                        written_digest: content_digest,
                    })
                    .expect("dirty unchanged commit");
                receipt
            }
            other => panic!("unexpected dirty unchanged directive: {other:?}"),
        };
        let dirty_operation = decoded(&dirty_unchanged_receipt.committed_journal)
            .operations
            .into_iter()
            .find(|operation| operation.operation_id == dirty_unchanged_operation_id)
            .expect("dirty unchanged operation");
        assert_eq!(
            dirty_operation.resulting_digest,
            Some(format!("{:x}", Sha256::digest(&local)))
        );
        assert_eq!(
            prepare_workspace_journal_mutation_transaction_v1(
                Some(&raw_dirty),
                &effective_dirty.canonical_bytes,
                &journal_mutation_request(
                    serde_json::json!({
                        "kind": "unchanged",
                        "expectedWorkingRevision": 1,
                        "operationID": dirty_unchanged_operation_id,
                        "fingerprint": format!(
                            "{:x}",
                            Sha256::digest(dirty_unchanged_operation_id.as_bytes())
                        ),
                        "updatedAt": 3.0
                    }),
                    9,
                    None,
                ),
                &document("different"),
                Some(&local),
            )
            .expect_err("unchanged must reject a candidate different from dirty bytes"),
            WorkspaceWorkingJournalError::InvalidTransaction
        );

        let external = document("external saved");
        let external_digest = format!("{:x}", Sha256::digest(&external));
        let rebased = prepare_workspace_journal_mutation_transaction_v1(
            Some(&raw_dirty),
            &effective_dirty.canonical_bytes,
            &journal_mutation_request(
                serde_json::json!({
                    "kind": "conflictRebase",
                    "expectedRevisions": revision(1, 0, Some(1)),
                    "externalSavedDigest": external_digest.clone(),
                    "updatedAt": 4.0
                }),
                10,
                None,
            ),
            &local,
            Some(&external),
        )
        .expect("conflict rebase transaction");
        assert_eq!(
            rebased
                .command_authority_publication_kind()
                .expect("rebase publication kind"),
            WorkspaceProjectionPublicationKind::WorkingStateCommitted
        );
        let receipt = match rebased.next_directive().expect("rebase action") {
            WorkspaceJournalMutationDirectiveV1::Action {
                kind: WorkspaceJournalMutationActionKindV1::WriteJournal,
                authority_receipt: Some(receipt),
                ..
            } => receipt,
            other => panic!("unexpected rebase directive: {other:?}"),
        };
        let committed = decoded(&receipt.committed_journal);
        assert_eq!(committed.revisions.working_revision, 1);
        assert_eq!(committed.revisions.saved_revision, 0);
        assert_eq!(committed.revisions.dirty_revision, Some(1));
        assert_eq!(committed.saved_digest, external_digest);
        assert_eq!(committed.working_document, Some(base64_encode(&local)));
    }

    #[test]
    fn create_transaction_owns_full_recreate_sequence_and_catalog_authority() {
        let raw_catalog = create_catalog_bytes(9, true);
        let effective_catalog =
            validate_workspace_catalog_v1(&raw_catalog).expect("effective catalog");
        let document = document("created");
        let transaction = prepare_workspace_create_transaction_v1(
            Some(&raw_catalog),
            &effective_catalog.canonical_bytes,
            None,
            None,
            &create_request(9, &document),
            &document,
        )
        .expect("create transaction");
        let expected_kinds = [
            WorkspaceCreateActionKindV1::WritePendingJournal,
            WorkspaceCreateActionKindV1::PublishWorkspaceDocument,
            WorkspaceCreateActionKindV1::WriteCommittedJournal,
            WorkspaceCreateActionKindV1::WriteSavedRevision,
            WorkspaceCreateActionKindV1::RemoveDeletionSidecar,
            WorkspaceCreateActionKindV1::PublishCatalog,
        ];
        let mut final_receipt = None;
        for (index, expected_kind) in expected_kinds.into_iter().enumerate() {
            let directive = transaction.next_directive().expect("create action");
            let (action_id, content_digest, authority_receipt) = match directive {
                WorkspaceCreateDirectiveV1::Action {
                    action_id,
                    kind,
                    content_digest,
                    authority_receipt,
                    ..
                } => {
                    assert_eq!(kind, expected_kind);
                    assert_eq!(action_id, index as u64 + 1);
                    (action_id, content_digest, authority_receipt)
                }
                other => panic!("unexpected create directive: {other:?}"),
            };
            if index < 5 {
                assert!(authority_receipt.is_none());
                assert!(!transaction.is_ready_for_authority());
            } else {
                assert!(transaction.is_ready_for_authority());
                let receipt = authority_receipt.expect("catalog authority receipt");
                assert_eq!(receipt.catalog.revision, 10);
                assert_eq!(receipt.catalog.deletion_count, 0);
                assert_eq!(
                    receipt.document_digest,
                    format!("{:x}", Sha256::digest(&document))
                );
                final_receipt = Some(receipt);
            }
            let result = transaction
                .report_action(WorkspaceCreateActionReportV1::Success {
                    action_id,
                    written_digest: content_digest,
                })
                .expect("advance create");
            if index == 5 {
                assert_eq!(
                    result,
                    WorkspaceCreateDirectiveV1::Committed {
                        receipt: final_receipt.clone().expect("receipt")
                    }
                );
            }
        }
        assert!(transaction.is_authoritative());
        assert!(!transaction.is_ready_for_authority());
        transaction.close();
        assert_eq!(
            transaction.next_directive(),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
    }

    #[test]
    fn create_recovery_requires_exact_marker_and_publishes_only_catalog() {
        let raw_catalog = create_catalog_bytes(4, true);
        let effective_catalog =
            validate_workspace_catalog_v1(&raw_catalog).expect("effective catalog");
        let document = document("recovered");
        let prepared = prepare_workspace_create_transaction_v1(
            Some(&raw_catalog),
            &effective_catalog.canonical_bytes,
            None,
            None,
            &create_request(4, &document),
            &document,
        )
        .expect("prepared create");
        let committed_journal = match prepared.inner.lock().expect("state").receipt.clone() {
            WorkspaceCreateCommitReceiptV1 {
                committed_journal, ..
            } => committed_journal,
        };
        let recovery = prepare_workspace_create_transaction_v1(
            Some(&raw_catalog),
            &effective_catalog.canonical_bytes,
            Some(&committed_journal.canonical_bytes),
            Some(&committed_journal.canonical_bytes),
            &recover_create_request(4),
            &document,
        )
        .expect("recovery transaction");
        let (action_id, digest, receipt) = match recovery.next_directive().expect("catalog action")
        {
            WorkspaceCreateDirectiveV1::Action {
                action_id,
                kind: WorkspaceCreateActionKindV1::PublishCatalog,
                content_digest,
                authority_receipt: Some(receipt),
                ..
            } => (action_id, content_digest, receipt),
            other => panic!("unexpected recovery directive: {other:?}"),
        };
        assert_eq!(action_id, 1);
        assert!(receipt.saved_revision.is_none());
        assert_eq!(receipt.catalog.deletion_count, 0);
        assert_eq!(receipt.catalog.entry_count, 1);
        assert_eq!(
            recovery
                .report_action(WorkspaceCreateActionReportV1::Success {
                    action_id,
                    written_digest: digest,
                })
                .expect("commit recovery"),
            WorkspaceCreateDirectiveV1::Committed { receipt }
        );
        assert!(recovery.is_authoritative());

        let mut bad_context_request: Value =
            serde_json::from_slice(&create_request(4, &document)).expect("create request value");
        bad_context_request["fingerprint"] = Value::String("not-a-digest".to_owned());
        assert!(matches!(
            prepare_workspace_create_transaction_v1(
                Some(&raw_catalog),
                &effective_catalog.canonical_bytes,
                None,
                None,
                &serde_json::to_vec(&bad_context_request).expect("bad context request"),
                &document,
            ),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        ));

        let mut bad_catalog: Value = serde_json::from_slice(&raw_catalog).expect("catalog value");
        bad_catalog["deletions"][0]["operation"]["after"] = revision(1, 1, None);
        let bad_catalog = serde_json::to_vec(&bad_catalog).expect("bad catalog bytes");
        let bad_catalog_validation =
            validate_workspace_catalog_v1(&bad_catalog).expect("structurally valid catalog");
        assert!(matches!(
            prepare_workspace_create_transaction_v1(
                Some(&bad_catalog),
                &bad_catalog_validation.canonical_bytes,
                None,
                None,
                &create_request(4, &document),
                &document,
            ),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        ));

        let mut bad_journal: Value =
            serde_json::from_slice(&committed_journal.canonical_bytes).expect("journal value");
        bad_journal["operations"][0]["catalogRevision"] = Value::from(99);
        let bad_journal = serde_json::to_vec(&bad_journal).expect("bad journal");
        assert!(matches!(
            prepare_workspace_create_transaction_v1(
                Some(&raw_catalog),
                &effective_catalog.canonical_bytes,
                Some(&bad_journal),
                Some(&bad_journal),
                &recover_create_request(4),
                &document,
            ),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        ));
    }

    #[test]
    fn delete_transaction_binds_catalog_authority_and_commits_exactly_once() {
        let raw_catalog = catalog_bytes(9);
        let effective_catalog =
            validate_workspace_catalog_v1(&raw_catalog).expect("effective catalog");
        let journal = journal_bytes(None);
        let effective_journal =
            validate_workspace_working_journal_v1(&journal).expect("effective journal");
        let mut request: Value =
            serde_json::from_slice(&delete_request(0, 9)).expect("delete request value");
        request["operationID"] = Value::String(OPERATION_ID.to_uppercase());
        let request = serde_json::to_vec(&request).expect("uppercase delete request");
        let transaction = prepare_workspace_delete_transaction_v1(
            Some(&raw_catalog),
            &effective_catalog.canonical_bytes,
            &effective_journal.canonical_bytes,
            &request,
        )
        .expect("delete transaction");

        let action = transaction.next_directive().expect("catalog action");
        let (action_id, digest, receipt) = match action {
            WorkspaceDeleteDirectiveV1::Action {
                action_id,
                kind: WorkspaceDeleteActionKindV1::PublishCatalog,
                expected_raw_catalog_digest,
                content_digest,
                logical_expected_revision,
                authority_receipt,
                ..
            } => {
                assert_eq!(logical_expected_revision, 9);
                assert_eq!(
                    expected_raw_catalog_digest,
                    Some(format!("{:x}", Sha256::digest(&raw_catalog)))
                );
                (action_id, content_digest, authority_receipt)
            }
            other => panic!("unexpected delete directive: {other:?}"),
        };
        assert_eq!(receipt.catalog.revision, 10);
        assert_eq!(receipt.workspace_id, WORKSPACE_ID);
        assert_eq!(receipt.operation_id, OPERATION_ID);
        assert_eq!(receipt.catalog.content_digest, digest);
        assert!(!transaction.is_authoritative());

        let committed = transaction
            .report_action(WorkspaceDeleteActionReportV1::Success {
                action_id,
                written_digest: digest,
            })
            .expect("committed delete");
        assert_eq!(
            committed,
            WorkspaceDeleteDirectiveV1::Committed {
                receipt: receipt.clone()
            }
        );
        assert!(transaction.is_authoritative());
        let exact_cleanup = transaction
            .cleanup_plan(None)
            .expect("exact tombstone cleanup");
        assert_eq!(exact_cleanup.validation, receipt.tombstone);
        let cleanup_warnings = serde_json::to_vec(&vec![
            "revision sidecar: denied",
            "workspace document: busy",
        ])
        .expect("cleanup warnings");
        let amended_cleanup = transaction
            .cleanup_plan(Some(&cleanup_warnings))
            .expect("amended tombstone cleanup");
        assert_eq!(
            amended_cleanup.operation.diagnostic.as_deref(),
            Some("artifact_cleanup_incomplete: revision sidecar: denied; workspace document: busy")
        );
        assert_eq!(
            transaction
                .cleanup_plan(Some(&cleanup_warnings))
                .expect("deterministic amended tombstone cleanup"),
            amended_cleanup
        );
        assert_eq!(
            transaction.cleanup_plan(Some(b"[]")),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        assert_eq!(
            transaction
                .report_action(WorkspaceDeleteActionReportV1::Success {
                    action_id,
                    written_digest: receipt.catalog.content_digest.clone(),
                })
                .expect("idempotent success"),
            committed
        );
        assert_eq!(
            transaction.report_action(WorkspaceDeleteActionReportV1::Cancelled { action_id }),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        transaction.close();
        assert_eq!(
            transaction.next_directive(),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        assert_eq!(
            transaction.report_action(WorkspaceDeleteActionReportV1::Success {
                action_id,
                written_digest: receipt.catalog.content_digest,
            }),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
    }

    #[test]
    fn delete_transaction_rejects_unbound_inputs_and_classifies_failures() {
        let raw_catalog = catalog_bytes(9);
        let effective_catalog =
            validate_workspace_catalog_v1(&raw_catalog).expect("effective catalog");
        let journal = journal_bytes(None);
        let effective_journal =
            validate_workspace_working_journal_v1(&journal).expect("effective journal");
        let prepare = || {
            prepare_workspace_delete_transaction_v1(
                Some(&raw_catalog),
                &effective_catalog.canonical_bytes,
                &effective_journal.canonical_bytes,
                &delete_request(0, 9),
            )
            .expect("delete transaction")
        };

        for (report, expected) in [
            (
                WorkspaceDeleteActionReportV1::Cancelled { action_id: 1 },
                WorkspaceDeleteFailureV1::Cancelled,
            ),
            (
                WorkspaceDeleteActionReportV1::StateConflict {
                    action_id: 1,
                    expected: 9,
                    actual: 10,
                },
                WorkspaceDeleteFailureV1::StateConflict {
                    expected: 9,
                    actual: 10,
                },
            ),
            (
                WorkspaceDeleteActionReportV1::WriteFailed { action_id: 1 },
                WorkspaceDeleteFailureV1::WriteFailed,
            ),
        ] {
            let transaction = prepare();
            assert_eq!(
                transaction
                    .report_action(report)
                    .expect("failure directive"),
                WorkspaceDeleteDirectiveV1::Failed { failure: expected }
            );
            assert!(!transaction.is_authoritative());
        }

        assert_eq!(
            prepare().report_action(WorkspaceDeleteActionReportV1::Success {
                action_id: 2,
                written_digest: effective_catalog.content_digest.clone(),
            }),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        assert_eq!(
            prepare().report_action(WorkspaceDeleteActionReportV1::Success {
                action_id: 1,
                written_digest: format!("{:x}", Sha256::digest(b"wrong")),
            }),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        assert!(matches!(
            prepare_workspace_delete_transaction_v1(
                Some(&catalog_bytes(8)),
                &effective_catalog.canonical_bytes,
                &effective_journal.canonical_bytes,
                &delete_request(0, 9),
            ),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        ));
        assert!(matches!(
            prepare_workspace_delete_transaction_v1(
                Some(&raw_catalog),
                &effective_catalog.canonical_bytes,
                &effective_journal.canonical_bytes,
                &delete_request(1, 9),
            ),
            Err(WorkspaceWorkingJournalError::InvalidRevisionState)
        ));

        let absent_catalog = serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "revision": 9,
            "entries": [],
            "deletions": [],
            "updatedAt": 2.75
        }))
        .expect("absent catalog");
        assert!(matches!(
            prepare_workspace_delete_transaction_v1(
                Some(&absent_catalog),
                &absent_catalog,
                &effective_journal.canonical_bytes,
                &delete_request(0, 9),
            ),
            Err(WorkspaceWorkingJournalError::InvalidIdentity)
        ));

        let mismatched_url_catalog = serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "revision": 9,
            "entries": [{
                "workspaceID": WORKSPACE_ID,
                "fileURL": "file:///tmp/Other.json"
            }],
            "deletions": [],
            "updatedAt": 2.75
        }))
        .expect("mismatched URL catalog");
        assert!(matches!(
            prepare_workspace_delete_transaction_v1(
                Some(&mismatched_url_catalog),
                &mismatched_url_catalog,
                &effective_journal.canonical_bytes,
                &delete_request(0, 9),
            ),
            Err(WorkspaceWorkingJournalError::InvalidFileUrl)
        ));

        let mut mismatched_revision_request: serde_json::Value =
            serde_json::from_slice(&delete_request(0, 9)).expect("delete request value");
        mismatched_revision_request["fingerprint"] = serde_json::json!("not-a-digest");
        let mismatched_revision_request =
            serde_json::to_vec(&mismatched_revision_request).expect("mismatched request");
        assert!(matches!(
            prepare_workspace_delete_transaction_v1(
                Some(&raw_catalog),
                &effective_catalog.canonical_bytes,
                &effective_journal.canonical_bytes,
                &mismatched_revision_request,
            ),
            Err(WorkspaceWorkingJournalError::InvalidOperationLedger)
        ));

        let failed = prepare();
        let failure_report = WorkspaceDeleteActionReportV1::WriteFailed { action_id: 1 };
        assert!(matches!(
            failed.report_action(failure_report.clone()),
            Ok(WorkspaceDeleteDirectiveV1::Failed {
                failure: WorkspaceDeleteFailureV1::WriteFailed
            })
        ));
        failed.close();
        assert_eq!(
            failed.report_action(failure_report),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
    }

    #[test]
    fn save_transaction_owns_authority_point_and_post_commit_failure_policy() {
        let raw = journal_bytes(None);
        let effective = validate_workspace_working_journal_v1(&raw).expect("effective");
        let candidate = document("saved");
        let disk = document("saved");
        let transaction = prepare_workspace_save_transaction_v1(
            Some(&raw),
            &effective.canonical_bytes,
            &save_request(0, 9),
            &candidate,
            Some(&disk),
        )
        .expect("transaction");

        let pending = transaction.next_directive().expect("pending directive");
        let (pending_id, pending_digest) = match pending {
            WorkspaceSaveDirectiveV1::Action {
                action_id,
                kind: WorkspaceSaveActionKindV1::WritePendingJournal,
                expected_raw_journal_digest,
                content_digest,
                authority_receipt,
                post_authority_success_finalization,
                post_authority_failure_finalization,
                ..
            } => {
                assert_eq!(
                    expected_raw_journal_digest,
                    Some(format!("{:x}", Sha256::digest(&raw)))
                );
                assert!(authority_receipt.is_none());
                assert_eq!(post_authority_success_finalization, None);
                assert_eq!(post_authority_failure_finalization, None);
                (action_id, content_digest)
            }
            other => panic!("unexpected pending directive: {other:?}"),
        };
        let document_directive = transaction
            .report_action(WorkspaceSaveActionReportV1::Success {
                action_id: pending_id,
                written_digest: pending_digest,
            })
            .expect("document directive");
        let (document_id, document_digest, receipt) = match document_directive {
            WorkspaceSaveDirectiveV1::Action {
                action_id,
                kind: WorkspaceSaveActionKindV1::PublishWorkspaceDocument,
                content_digest,
                authority_receipt: Some(receipt),
                post_authority_success_finalization:
                    Some(WorkspaceSaveFinalizationV1::PendingJournalRetained),
                post_authority_failure_finalization: None,
                ..
            } => (action_id, content_digest, receipt),
            other => panic!("unexpected document directive: {other:?}"),
        };
        assert_eq!(receipt.catalog_revision, 9);
        assert_eq!(receipt.document_digest, document_digest);
        assert!(!transaction.is_authoritative());

        let committed_journal = transaction
            .report_action(WorkspaceSaveActionReportV1::Success {
                action_id: document_id,
                written_digest: document_digest,
            })
            .expect("committed journal directive");
        assert!(transaction.is_authoritative());
        let committed_id = match committed_journal {
            WorkspaceSaveDirectiveV1::Action {
                action_id,
                kind: WorkspaceSaveActionKindV1::WriteCommittedJournal,
                post_authority_success_finalization:
                    Some(WorkspaceSaveFinalizationV1::RevisionSidecarMissing),
                post_authority_failure_finalization:
                    Some(WorkspaceSaveFinalizationV1::PendingJournalRetained),
                ..
            } => action_id,
            other => panic!("unexpected committed journal directive: {other:?}"),
        };
        let terminal = transaction
            .report_action(WorkspaceSaveActionReportV1::WriteFailed {
                action_id: committed_id,
            })
            .expect("post-authority failure");
        assert_eq!(
            terminal,
            WorkspaceSaveDirectiveV1::Committed {
                receipt,
                finalization: WorkspaceSaveFinalizationV1::PendingJournalRetained,
            }
        );
        assert_eq!(
            transaction
                .report_action(WorkspaceSaveActionReportV1::WriteFailed {
                    action_id: committed_id,
                })
                .expect("idempotent report"),
            terminal
        );
        assert_eq!(
            transaction.report_action(WorkspaceSaveActionReportV1::Cancelled {
                action_id: committed_id,
            }),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        transaction.close();
        transaction.close();
        assert_eq!(
            transaction.next_directive(),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
    }

    #[test]
    fn save_transaction_classifies_every_pre_and_post_authority_failure() {
        let raw = journal_bytes(None);
        let effective = validate_workspace_working_journal_v1(&raw).expect("effective");
        let candidate = document("saved");
        let prepare = || {
            prepare_workspace_save_transaction_v1(
                Some(&raw),
                &effective.canonical_bytes,
                &save_request(0, 4),
                &candidate,
                Some(&candidate),
            )
            .expect("transaction")
        };

        let cancelled = prepare();
        assert_eq!(
            cancelled
                .report_action(WorkspaceSaveActionReportV1::Cancelled { action_id: 1 })
                .expect("cancelled"),
            WorkspaceSaveDirectiveV1::Failed {
                failure: WorkspaceSaveFailureV1::Cancelled,
            }
        );

        let document_failed = prepare();
        let pending_digest = match document_failed.next_directive().expect("pending") {
            WorkspaceSaveDirectiveV1::Action { content_digest, .. } => content_digest,
            _ => unreachable!(),
        };
        document_failed
            .report_action(WorkspaceSaveActionReportV1::Success {
                action_id: 1,
                written_digest: pending_digest,
            })
            .expect("document");
        assert_eq!(
            document_failed
                .report_action(WorkspaceSaveActionReportV1::StateConflict {
                    action_id: 2,
                    expected: 0,
                    actual: 1,
                })
                .expect("document conflict"),
            WorkspaceSaveDirectiveV1::Failed {
                failure: WorkspaceSaveFailureV1::StateConflict {
                    expected: 0,
                    actual: 1,
                },
            }
        );

        let revision_failed = prepare();
        let mut directive = revision_failed.next_directive().expect("pending");
        for action_id in 1..=3 {
            let digest = match directive {
                WorkspaceSaveDirectiveV1::Action { content_digest, .. } => content_digest,
                _ => unreachable!(),
            };
            directive = revision_failed
                .report_action(WorkspaceSaveActionReportV1::Success {
                    action_id,
                    written_digest: digest,
                })
                .expect("advance");
        }
        assert!(matches!(
            directive,
            WorkspaceSaveDirectiveV1::Action {
                kind: WorkspaceSaveActionKindV1::WriteSavedRevision,
                post_authority_success_finalization: Some(WorkspaceSaveFinalizationV1::Finalized),
                post_authority_failure_finalization: Some(
                    WorkspaceSaveFinalizationV1::RevisionSidecarMissing
                ),
                ..
            }
        ));
        assert!(matches!(
            revision_failed
                .report_action(WorkspaceSaveActionReportV1::WriteFailed { action_id: 4 })
                .expect("revision failure"),
            WorkspaceSaveDirectiveV1::Committed {
                finalization: WorkspaceSaveFinalizationV1::RevisionSidecarMissing,
                ..
            }
        ));

        assert_eq!(
            prepare_workspace_save_transaction_v1(
                Some(&raw),
                &effective.canonical_bytes,
                &save_request(0, 4),
                &candidate,
                Some(&document("external")),
            )
            .expect_err("external conflict"),
            WorkspaceWorkingJournalError::ExternalDocumentConflict
        );
    }

    #[test]
    fn save_transaction_rejects_unbound_state_and_document_inputs() {
        let raw = journal_bytes(None);
        let effective = validate_workspace_working_journal_v1(&raw).expect("effective");
        let candidate = document("saved");
        assert_eq!(
            prepare_workspace_save_transaction_v1(
                None,
                &effective.canonical_bytes,
                &save_request(0, 4),
                &candidate,
                Some(&candidate),
            )
            .expect_err("missing raw snapshot"),
            WorkspaceWorkingJournalError::InvalidTransaction
        );

        let mut divergent: Value = serde_json::from_slice(&raw).expect("journal json");
        divergent["savedDigest"] = Value::String(format!("{:x}", Sha256::digest(b"other")));
        let divergent_bytes = serde_json::to_vec(&divergent).expect("divergent journal");
        let divergent_validation =
            validate_workspace_working_journal_v1(&divergent_bytes).expect("divergent validation");
        assert_eq!(
            prepare_workspace_save_transaction_v1(
                Some(&raw),
                &divergent_validation.canonical_bytes,
                &save_request(0, 4),
                &candidate,
                Some(&candidate),
            )
            .expect_err("unbound effective journal"),
            WorkspaceWorkingJournalError::InvalidTransaction
        );
        assert_eq!(
            prepare_workspace_save_transaction_v1(
                Some(&raw),
                &effective.canonical_bytes,
                &save_request(0, 4),
                b"not-json",
                Some(&candidate),
            )
            .expect_err("malformed candidate"),
            WorkspaceWorkingJournalError::InvalidWorkingDocument
        );
        assert_eq!(
            prepare_workspace_save_transaction_v1(
                Some(&raw),
                &effective.canonical_bytes,
                &save_request(0, 4),
                &document_for_workspace("bbbbbbbb-cccc-dddd-eeee-ffffffffffff", "saved"),
                Some(&candidate),
            )
            .expect_err("wrong candidate identity"),
            WorkspaceWorkingJournalError::InvalidIdentity
        );
    }

    #[test]
    fn pending_save_recovery_requires_matching_valid_workspace_document() {
        let raw = journal_bytes(None);
        let candidate = document("candidate");
        let save = transition(
            serde_json::json!({
                "kind": "save",
                "expectedWorkingRevision": 0,
                "operationID": OPERATION_ID,
                "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
                "updatedAt": 4.0
            }),
            Some(&raw),
            Some(&candidate),
        );
        assert!(matches!(
            resolve_workspace_pending_save_v1(
                &save.primary.canonical_bytes,
                WORKSPACE_ID,
                "file:///tmp/Workspace.json",
                None,
            )
            .expect("missing document"),
            WorkspacePendingSaveRecoveryV1::PendingNotCommitted { .. }
        ));
        assert!(matches!(
            resolve_workspace_pending_save_v1(
                &save.primary.canonical_bytes,
                WORKSPACE_ID,
                "file:///tmp/Workspace.json",
                Some(&document("different")),
            )
            .expect("digest mismatch"),
            WorkspacePendingSaveRecoveryV1::PendingNotCommitted { .. }
        ));
        let recovered = resolve_workspace_pending_save_v1(
            &save.primary.canonical_bytes,
            WORKSPACE_ID,
            "file:///tmp/Workspace.json",
            Some(&candidate),
        )
        .expect("committed recovery");
        match recovered {
            WorkspacePendingSaveRecoveryV1::Committed {
                clean_journal,
                document_digest,
            } => {
                assert_eq!(document_digest, format!("{:x}", Sha256::digest(&candidate)));
                assert_eq!(
                    clean_journal.canonical_bytes,
                    save.committed.expect("committed candidate").canonical_bytes
                );
            }
            other => panic!("unexpected recovery: {other:?}"),
        }

        let malformed = b"not-json";
        let mut malformed_save: Value =
            serde_json::from_slice(&save.primary.canonical_bytes).expect("pending journal json");
        malformed_save["workingDocument"] = Value::String("not-base64".to_owned());
        let malformed_save = serde_json::to_vec(&malformed_save).expect("malformed pending save");
        assert_eq!(
            resolve_workspace_pending_save_v1(
                &malformed_save,
                WORKSPACE_ID,
                "file:///tmp/Workspace.json",
                Some(malformed),
            ),
            Err(WorkspaceWorkingJournalError::InvalidWorkingDocument)
        );
    }

    #[test]
    fn dedicated_seed_matches_generic_plan_and_rejects_non_seed_requests() {
        let seed_request = serde_json::json!({
            "kind": "seed",
            "workspaceID": WORKSPACE_ID,
            "fileURL": "file:///tmp/Workspace.json",
            "revisions": revision(0, 0, None),
            "savedDigest": format!("{:x}", Sha256::digest(document("saved"))),
            "contextDigests": [CONTEXT_ID, format!("{:x}", Sha256::digest(b"context"))],
            "updatedAt": 10.0
        });
        let seed_bytes = serde_json::to_vec(&seed_request).expect("seed request");
        let dedicated = seed_workspace_working_journal_v1(&seed_bytes).expect("dedicated seed");
        let generic = plan_workspace_working_journal_transition_v1(None, &seed_bytes, None, None)
            .expect("generic seed plan");
        assert_eq!(dedicated, generic.primary);
        assert!(generic.committed.is_none());
        assert_eq!(
            seed_workspace_working_journal_v1(&seed_bytes).expect("repeat seed"),
            dedicated
        );

        let non_seed = serde_json::to_vec(&serde_json::json!({
            "kind": "recoverPending",
            "expectedWorkspaceID": WORKSPACE_ID
        }))
        .expect("non-seed request");
        assert_eq!(
            seed_workspace_working_journal_v1(&non_seed),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        assert_eq!(
            seed_workspace_working_journal_v1(b"not-json"),
            Err(WorkspaceWorkingJournalError::Malformed)
        );
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
                "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
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
                "operationID": OPERATION_ID,
                "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
                "updatedAt": 11.0
            }),
            Some(&seed.primary.canonical_bytes),
            Some(&saved),
        );
        assert_eq!(decoded(&unchanged.primary).operations.len(), 1);
        assert!(unchanged.committed.is_none());

        let create = transition(
            serde_json::json!({
                "kind": "create",
                "workspaceID": WORKSPACE_ID,
                "fileURL": file_url,
                "operationID": OPERATION_ID,
                "fingerprint": format!("{:x}", Sha256::digest(OPERATION_ID.as_bytes())),
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
                "operationID": second_operation_id,
                "fingerprint": format!("{:x}", Sha256::digest(second_operation_id.as_bytes())),
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
                "fingerprint": format!("{:x}", Sha256::digest(third_operation_id.as_bytes())),
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
                "externalSavedDigest": format!("{:x}", Sha256::digest(&reloaded)),
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
            "updatedAt": 20.0
        });
        assert_eq!(
            plan_workspace_working_journal_transition_v1(
                Some(&current),
                &serde_json::to_vec(&request).expect("request"),
                Some(&document("working")),
                None,
            ),
            Err(WorkspaceWorkingJournalError::InvalidRevisionState)
        );

        let mut missing_document = request;
        missing_document["expectedWorkingRevision"] = Value::from(0);
        assert_eq!(
            plan_workspace_working_journal_transition_v1(
                Some(&current),
                &serde_json::to_vec(&missing_document).expect("request"),
                None,
                None,
            ),
            Err(WorkspaceWorkingJournalError::InvalidWorkingDocument)
        );
    }

    #[test]
    fn plans_validates_and_fences_workspace_catalog_transitions() {
        let second_workspace_id = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";
        let third_workspace_id = "cccccccc-dddd-eeee-ffff-aaaaaaaaaaaa";
        let seed_request = serde_json::json!({
            "kind": "seed",
            "entries": [
                {"workspaceID": second_workspace_id, "fileURL": "file:///tmp/B.json"},
                {"workspaceID": WORKSPACE_ID, "fileURL": "file:///tmp/A.json"}
            ],
            "updatedAt": 10.0
        });
        let seed_request_bytes = serde_json::to_vec(&seed_request).expect("seed request");
        let seed = seed_workspace_catalog_v1(&seed_request_bytes).expect("seed catalog");
        assert_eq!(
            seed,
            plan_workspace_catalog_transition_v1(None, &seed_request_bytes)
                .expect("internal generic seed")
        );
        assert_eq!(seed.revision, 0);
        assert_eq!(seed.entry_count, 2);
        assert_eq!(seed.deletion_count, 0);
        assert_eq!(
            validate_workspace_catalog_v1(&seed.canonical_bytes).expect("validate seed"),
            seed
        );
        let seeded: WorkspaceCatalogV1 =
            serde_json::from_slice(&seed.canonical_bytes).expect("seeded catalog");
        assert_eq!(seeded.entries[0].workspace_id, second_workspace_id);
        assert_eq!(seeded.entries[1].workspace_id, WORKSPACE_ID);

        let upsert_request = serde_json::json!({
            "kind": "upsert",
            "expectedCatalogRevision": 0,
            "workspaceID": WORKSPACE_ID,
            "fileURL": "file:///tmp/A-recreated.json",
            "updatedAt": 11.0
        });
        let upsert_request_bytes = serde_json::to_vec(&upsert_request).expect("upsert request");
        assert_eq!(
            seed_workspace_catalog_v1(&upsert_request_bytes),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        let upsert = plan_workspace_catalog_transition_v1(
            Some(&seed.canonical_bytes),
            &upsert_request_bytes,
        )
        .expect("upsert catalog");
        let upserted: WorkspaceCatalogV1 =
            serde_json::from_slice(&upsert.canonical_bytes).expect("upserted catalog");
        assert_eq!(upsert.revision, 1);
        assert_eq!(upserted.entries[0].workspace_id, WORKSPACE_ID);
        assert_eq!(upserted.entries[0].file_url, "file:///tmp/A-recreated.json");
        assert_eq!(upserted.entries[1].workspace_id, second_workspace_id);

        let tombstone = serde_json::json!({
            "version": 1,
            "workspaceID": second_workspace_id,
            "fileURL": "file:///tmp/B.json",
            "operation": operation(OPERATION_ID, 12.0, 2),
            "deletedAt": 12.5
        });
        let delete_request = serde_json::json!({
            "kind": "delete",
            "expectedCatalogRevision": 1,
            "tombstone": tombstone,
            "updatedAt": 13.0
        });
        let deleted = plan_workspace_catalog_transition_v1(
            Some(&upsert.canonical_bytes),
            &serde_json::to_vec(&delete_request).expect("delete request"),
        )
        .expect("delete catalog");
        let deleted_catalog: WorkspaceCatalogV1 =
            serde_json::from_slice(&deleted.canonical_bytes).expect("deleted catalog");
        assert_eq!(deleted.revision, 2);
        assert_eq!(deleted.entry_count, 1);
        assert_eq!(deleted.deletion_count, 1);
        assert_eq!(
            deleted_catalog.deletions.as_ref().expect("deletions")[0].workspace_id,
            second_workspace_id
        );

        let recover_request = serde_json::json!({
            "kind": "recoverCreate",
            "expectedCatalogRevision": 2,
            "workspaceID": third_workspace_id,
            "fileURL": "file:///tmp/C.json",
            "updatedAt": 14.0
        });
        let recovered = plan_workspace_catalog_transition_v1(
            Some(&deleted.canonical_bytes),
            &serde_json::to_vec(&recover_request).expect("recover request"),
        )
        .expect("recover catalog");
        let recovered_catalog: WorkspaceCatalogV1 =
            serde_json::from_slice(&recovered.canonical_bytes).expect("recovered catalog");
        assert_eq!(recovered.revision, 3);
        assert_eq!(recovered.deletion_count, 1);
        assert_eq!(recovered_catalog.entries[0].workspace_id, WORKSPACE_ID);
        assert_eq!(
            recovered_catalog.entries[1].workspace_id,
            third_workspace_id
        );

        let stale_request = serde_json::json!({
            "kind": "upsert",
            "expectedCatalogRevision": 1,
            "workspaceID": WORKSPACE_ID,
            "fileURL": "file:///tmp/A.json",
            "updatedAt": 15.0
        });
        assert_eq!(
            plan_workspace_catalog_transition_v1(
                Some(&recovered.canonical_bytes),
                &serde_json::to_vec(&stale_request).expect("stale request")
            ),
            Err(WorkspaceWorkingJournalError::InvalidRevisionState)
        );

        let duplicate_seed = serde_json::json!({
            "kind": "seed",
            "entries": [
                {"workspaceID": WORKSPACE_ID, "fileURL": "file:///tmp/A.json"},
                {"workspaceID": WORKSPACE_ID, "fileURL": "file:///tmp/B.json"}
            ],
            "updatedAt": 16.0
        });
        assert_eq!(
            plan_workspace_catalog_transition_v1(
                None,
                &serde_json::to_vec(&duplicate_seed).expect("duplicate seed")
            ),
            Err(WorkspaceWorkingJournalError::DuplicateCatalogIdentity)
        );

        let tombstone_bytes = serde_json::to_vec(&tombstone).expect("tombstone bytes");
        let validated_tombstone =
            validate_workspace_deletion_tombstone_v1(&tombstone_bytes).expect("tombstone");
        assert_eq!(validated_tombstone.workspace_id, second_workspace_id);

        let mut future_catalog: Value =
            serde_json::from_slice(&seed.canonical_bytes).expect("future catalog value");
        future_catalog["version"] = Value::from(2);
        future_catalog["futureField"] = Value::Bool(true);
        assert_eq!(
            validate_workspace_catalog_v1(
                &serde_json::to_vec(&future_catalog).expect("future catalog")
            ),
            Err(WorkspaceWorkingJournalError::FutureSchema(2))
        );

        let invalid_url_seed = serde_json::json!({
            "kind": "seed",
            "entries": [{"workspaceID": WORKSPACE_ID, "fileURL": "relative.json"}],
            "updatedAt": 16.5
        });
        assert_eq!(
            plan_workspace_catalog_transition_v1(
                None,
                &serde_json::to_vec(&invalid_url_seed).expect("invalid URL seed")
            ),
            Err(WorkspaceWorkingJournalError::InvalidFileUrl)
        );
        let invalid_timestamp_seed = serde_json::json!({
            "kind": "seed",
            "entries": [],
            "updatedAt": "not-a-foundation-date"
        });
        assert_eq!(
            plan_workspace_catalog_transition_v1(
                None,
                &serde_json::to_vec(&invalid_timestamp_seed).expect("invalid timestamp seed")
            ),
            Err(WorkspaceWorkingJournalError::InvalidTimestamp)
        );

        let ambiguous_catalog = serde_json::json!({
            "version": 1,
            "revision": 9,
            "entries": [{"workspaceID": second_workspace_id, "fileURL": "file:///tmp/B.json"}],
            "deletions": [tombstone.clone()],
            "updatedAt": 17.0
        });
        assert_eq!(
            validate_workspace_catalog_v1(
                &serde_json::to_vec(&ambiguous_catalog).expect("ambiguous catalog")
            ),
            Err(WorkspaceWorkingJournalError::InvalidIdentity)
        );
        let duplicate_deletion_catalog = serde_json::json!({
            "version": 1,
            "revision": 9,
            "entries": [],
            "deletions": [tombstone.clone(), tombstone.clone()],
            "updatedAt": 17.5
        });
        assert_eq!(
            validate_workspace_catalog_v1(
                &serde_json::to_vec(&duplicate_deletion_catalog)
                    .expect("duplicate deletion catalog")
            ),
            Err(WorkspaceWorkingJournalError::InvalidIdentity)
        );

        let maximum_revision_catalog = serde_json::json!({
            "version": 1,
            "revision": u64::MAX,
            "entries": [],
            "deletions": [],
            "updatedAt": 18.0
        });
        let maximum_revision_upsert = serde_json::json!({
            "kind": "upsert",
            "expectedCatalogRevision": u64::MAX,
            "workspaceID": WORKSPACE_ID,
            "fileURL": "file:///tmp/A.json",
            "updatedAt": 19.0
        });
        assert_eq!(
            plan_workspace_catalog_transition_v1(
                Some(
                    &serde_json::to_vec(&maximum_revision_catalog)
                        .expect("maximum revision catalog")
                ),
                &serde_json::to_vec(&maximum_revision_upsert).expect("maximum revision upsert")
            ),
            Err(WorkspaceWorkingJournalError::InvalidRevisionState)
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
            "cleanupWarnings": []
        });
        let tombstone = plan_workspace_deletion_tombstone_v1(
            &serde_json::to_vec(&tombstone_request).expect("tombstone request"),
        )
        .expect("tombstone plan");
        assert_eq!(tombstone.workspace_id, WORKSPACE_ID);
        assert_eq!(tombstone.operation_id, OPERATION_ID);
        let cleanup_warnings = serde_json::to_vec(&vec![
            "revision sidecar: denied",
            "workspace document: busy",
        ])
        .expect("cleanup warnings");
        let amended = amend_workspace_deletion_tombstone_cleanup_v1(
            &tombstone.canonical_bytes,
            &cleanup_warnings,
        )
        .expect("cleanup amendment");
        assert_eq!(amended.workspace_id, tombstone.workspace_id);
        assert_eq!(amended.operation_id, tombstone.operation_id);
        let original_value: Value =
            serde_json::from_slice(&tombstone.canonical_bytes).expect("original tombstone json");
        let mut amended_value: Value =
            serde_json::from_slice(&amended.canonical_bytes).expect("amended tombstone json");
        assert_eq!(
            amended_value["operation"]["diagnostic"],
            "artifact_cleanup_incomplete: revision sidecar: denied; workspace document: busy"
        );
        amended_value["operation"]["diagnostic"] =
            original_value["operation"]["diagnostic"].clone();
        assert_eq!(amended_value, original_value);
        assert_eq!(
            amend_workspace_deletion_tombstone_cleanup_v1(&tombstone.canonical_bytes, b"[]"),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
        );
        assert_eq!(
            amend_workspace_deletion_tombstone_cleanup_v1(&tombstone.canonical_bytes, br#"[""]"#),
            Err(WorkspaceWorkingJournalError::InvalidTransaction)
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
