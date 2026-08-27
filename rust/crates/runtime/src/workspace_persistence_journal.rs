//! P5-5a workspace working-journal compatibility and validation boundary.
//!
//! The physical file and lease remain Swift-owned. This module is deliberately stateless: it
//! validates the complete V1 artifact with bounded input and emits deterministic JSON for bridge
//! compatibility. Embedded document semantics remain a later recovery/degradation policy boundary.

use crate::workspace_context::{
    MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1, WorkspaceProjectionRevisionState,
    canonical_uuid, is_valid_revision_state, project_workspace_document_v1,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fmt;
use std::sync::Mutex;

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
    ExternalDocumentConflict,
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
            Self::InvalidTransaction => {
                formatter.write_str("workspace save transaction is invalid")
            }
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

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceSaveTransactionRequestV1 {
    #[serde(rename = "expectedWorkspaceID")]
    expected_workspace_id: String,
    #[serde(rename = "expectedFileURL")]
    expected_file_url: String,
    expected_working_revision: u64,
    #[serde(rename = "operationID")]
    operation_id: String,
    context_revisions: Value,
    context_digests: Value,
    context_tombstones: Value,
    operations: Vec<WorkspaceRecordedOperationV1>,
    updated_at: Value,
    catalog_revision: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceJournalMutationTransactionRequestV1 {
    #[serde(rename = "expectedWorkspaceID")]
    expected_workspace_id: String,
    #[serde(rename = "expectedFileURL")]
    expected_file_url: String,
    catalog_revision: u64,
    #[serde(rename = "revisionOperationID")]
    revision_operation_id: Option<String>,
    transition: WorkspaceWorkingJournalTransitionRequestV1,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceDeleteTransactionRequestV1 {
    #[serde(rename = "expectedWorkspaceID")]
    expected_workspace_id: String,
    #[serde(rename = "expectedFileURL")]
    expected_file_url: String,
    expected_working_revision: u64,
    expected_catalog_revision: u64,
    operation: WorkspaceRecordedOperationV1,
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
        #[serde(rename = "expectedWorkspaceID")]
        expected_workspace_id: String,
        #[serde(rename = "expectedFileURL")]
        expected_file_url: String,
        expected_catalog_revision: u64,
        #[serde(rename = "operationID")]
        operation_id: String,
        context_revisions: Value,
        context_digests: Value,
        operation: WorkspaceRecordedOperationV1,
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
    committed: WorkspaceWorkingJournalValidationV1,
    saved_revision: Option<WorkspacePersistenceMetadataValidationV1>,
    receipt: WorkspaceJournalMutationCommitReceiptV1,
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
        WorkspaceSaveDirectiveV1::Action {
            action_id,
            request_digest: self.request_digest.clone(),
            kind,
            expected_raw_journal_digest,
            canonical_bytes,
            content_digest,
            logical_expected_revision,
            authority_receipt,
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
            expected_workspace_id,
            expected_file_url,
            expected_catalog_revision,
            operation_id,
            context_revisions,
            context_digests,
            mut operation,
            updated_at,
        } => {
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
            require_create_context_tables(
                document_bytes,
                &projection,
                &context_revisions,
                &context_digests,
            )?;
            let expected_revision = WorkspaceProjectionRevisionState {
                working_revision: 1,
                saved_revision: 1,
                dirty_revision: None,
            };
            let expected_resulting_catalog_revision = expected_catalog_revision
                .checked_add(1)
                .ok_or(WorkspaceWorkingJournalError::InvalidRevisionState)?;
            let canonical_operation_id =
                validate_and_canonicalize_recorded_operation(&mut operation)?;
            if canonical_operation_id != operation_id
                || operation.disposition != "applied"
                || operation.before.is_some()
                || operation.after != Some(expected_revision)
                || operation.catalog_revision != expected_resulting_catalog_revision
                || operation.resulting_digest.as_deref() != Some(document_digest.as_str())
                || operation.error_code.is_some()
                || operation.diagnostic.is_some()
            {
                return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
            }
            let transition = WorkspaceWorkingJournalTransitionRequestV1::Create {
                workspace_id: expected_workspace_id.clone(),
                file_url: expected_file_url.clone(),
                context_revisions,
                context_digests,
                operation,
                operation_id: operation_id.clone(),
                updated_at: updated_at.clone(),
            };
            let plan = plan_workspace_working_journal_transition_v1(
                None,
                &serde_json::to_vec(&transition)
                    .map_err(|_| WorkspaceWorkingJournalError::Malformed)?,
                Some(document_bytes),
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

    let expected_working_revision = match &request.transition {
        WorkspaceWorkingJournalTransitionRequestV1::Unchanged {
            expected_working_revision,
            ..
        }
        | WorkspaceWorkingJournalTransitionRequestV1::Working {
            expected_working_revision,
            ..
        }
        | WorkspaceWorkingJournalTransitionRequestV1::ExternalReload {
            expected_working_revision,
            ..
        } => *expected_working_revision,
        WorkspaceWorkingJournalTransitionRequestV1::ConflictRebase {
            expected_revisions, ..
        } => expected_revisions.working_revision,
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
    let (saved_revision_number, saved_revision_updated_at) = match &request.transition {
        WorkspaceWorkingJournalTransitionRequestV1::ExternalReload {
            new_revision,
            updated_at,
            ..
        } => {
            if disk_digest.as_deref() != Some(document_digest.as_str())
                || request.revision_operation_id.is_none()
            {
                return Err(WorkspaceWorkingJournalError::ExternalDocumentConflict);
            }
            (Some(*new_revision), Some(updated_at.clone()))
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
            (None, None)
        }
        WorkspaceWorkingJournalTransitionRequestV1::Unchanged { .. }
        | WorkspaceWorkingJournalTransitionRequestV1::Working { .. } => {
            if request.revision_operation_id.is_some() {
                return Err(WorkspaceWorkingJournalError::InvalidTransaction);
            }
            (None, None)
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
    )?;
    if plan.committed.is_some() {
        return Err(WorkspaceWorkingJournalError::InvalidTransaction);
    }
    let committed = plan.primary;
    let committed_journal = parse_validated_journal(&committed.canonical_bytes)?;
    let saved_revision = match (
        saved_revision_number,
        saved_revision_updated_at,
        request.revision_operation_id.as_ref(),
    ) {
        (Some(saved_revision), Some(updated_at), Some(operation_id)) => {
            let revision_request = WorkspaceSavedRevisionPlanRequestV1 {
                workspace_id: request.expected_workspace_id.clone(),
                saved_revision,
                document_digest: document_digest.clone(),
                operation_id: operation_id.clone(),
                updated_at,
            };
            Some(plan_workspace_saved_revision_record_v1(
                &serde_json::to_vec(&revision_request)
                    .map_err(|_| WorkspaceWorkingJournalError::Malformed)?,
            )?)
        }
        (None, None, None) => None,
        _ => return Err(WorkspaceWorkingJournalError::InvalidTransaction),
    };
    if saved_revision.is_some()
        && (committed_journal.revisions.saved_revision != saved_revision_number.unwrap_or_default()
            || committed_journal.saved_digest != document_digest)
    {
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
            committed,
            saved_revision,
            receipt,
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
        context_revisions: request.context_revisions.clone(),
        context_digests: request.context_digests.clone(),
        context_tombstones: request.context_tombstones.clone(),
        operations: request.operations.clone(),
        updated_at: request.updated_at.clone(),
    };
    let transition_bytes = serde_json::to_vec(&save_transition)
        .map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
    let plan = plan_workspace_working_journal_transition_v1(
        Some(&effective_validation.canonical_bytes),
        &transition_bytes,
        Some(candidate_document_bytes),
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
    request.expected_workspace_id = canonical_uuid(&request.expected_workspace_id)
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
    if request.operation.disposition != "applied"
        || request.operation.before != Some(journal.revisions)
        || request.operation.after.is_some()
        || request.operation.catalog_revision != expected_resulting_catalog_revision
        || request.operation.resulting_digest.is_some()
        || request.operation.error_code.is_some()
        || request.operation.diagnostic.is_some()
    {
        return Err(WorkspaceWorkingJournalError::InvalidOperationLedger);
    }

    let tombstone_request = WorkspaceDeletionTombstonePlanRequestV1 {
        workspace_id: request.expected_workspace_id.clone(),
        file_url: request.expected_file_url.clone(),
        operation: request.operation.clone(),
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

pub fn validate_workspace_deletion_tombstone_v1(
    bytes: &[u8],
) -> Result<WorkspacePersistenceMetadataValidationV1, WorkspaceWorkingJournalError> {
    require_metadata_input_bound(bytes)?;
    let tombstone: WorkspaceDeletionTombstoneV1 =
        serde_json::from_slice(bytes).map_err(|_| WorkspaceWorkingJournalError::Malformed)?;
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

pub fn plan_workspace_catalog_transition_v1(
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
            return Err(WorkspaceWorkingJournalError::InvalidIdentity);
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
        document_for_workspace(WORKSPACE_ID, prompt)
    }

    fn document_for_workspace(workspace_id: &str, prompt: &str) -> Vec<u8> {
        format!(
            r#"{{"id":"{workspace_id}","schemaVersion":1,"name":"Workspace","composeTabs":[{{"id":"{CONTEXT_ID}","name":"Context","prompt":"{prompt}","selectedPaths":[]}}]}}"#
        )
        .into_bytes()
    }

    fn first_context_digest(document_bytes: &[u8]) -> String {
        let document: Value = serde_json::from_slice(document_bytes).expect("document json");
        let context = document["composeTabs"]
            .as_array()
            .and_then(|contexts| contexts.first())
            .expect("first context");
        let canonical = serde_json::to_vec(context).expect("canonical context");
        format!("{:x}", Sha256::digest(canonical))
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

    fn save_request(expected_revision: u64, catalog_revision: u64) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "expectedWorkspaceID": WORKSPACE_ID,
            "expectedFileURL": "file:///tmp/Workspace.json",
            "expectedWorkingRevision": expected_revision,
            "operationID": OPERATION_ID,
            "contextRevisions": [CONTEXT_ID, revision(expected_revision, 0, None)],
            "contextDigests": [CONTEXT_ID, format!("{:x}", Sha256::digest(b"context"))],
            "contextTombstones": {},
            "operations": [operation(OPERATION_ID, 3.0, catalog_revision)],
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

    fn delete_request(working_revision: u64, catalog_revision: u64) -> Vec<u8> {
        let mut delete_operation = operation(OPERATION_ID, 3.0, catalog_revision + 1);
        delete_operation["before"] = revision(working_revision, 0, None);
        serde_json::to_vec(&serde_json::json!({
            "expectedWorkspaceID": WORKSPACE_ID,
            "expectedFileURL": "file:///tmp/Workspace.json",
            "expectedWorkingRevision": working_revision,
            "expectedCatalogRevision": catalog_revision,
            "operation": delete_operation,
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

    fn create_request(catalog_revision: u64, document_bytes: &[u8]) -> Vec<u8> {
        let mut create_operation = operation(OPERATION_ID, 2.0, catalog_revision + 1);
        create_operation["after"] = revision(1, 1, None);
        create_operation["resultingDigest"] =
            Value::String(format!("{:x}", Sha256::digest(document_bytes)));
        serde_json::to_vec(&serde_json::json!({
            "kind": "create",
            "expectedWorkspaceID": WORKSPACE_ID,
            "expectedFileURL": "file:///tmp/Workspace.json",
            "expectedCatalogRevision": catalog_revision,
            "operationID": OPERATION_ID,
            "contextRevisions": [CONTEXT_ID, revision(1, 1, None)],
            "contextDigests": [CONTEXT_ID, first_context_digest(document_bytes)],
            "operation": create_operation,
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
        serde_json::to_vec(&serde_json::json!({
            "expectedWorkspaceID": WORKSPACE_ID,
            "expectedFileURL": "file:///tmp/Workspace.json",
            "catalogRevision": catalog_revision,
            "revisionOperationID": revision_operation_id,
            "transition": transition
        }))
        .expect("journal mutation request")
    }

    #[test]
    fn journal_mutation_transaction_commits_working_state_at_journal_authority() {
        let raw = journal_bytes(None);
        let effective = validate_workspace_working_journal_v1(&raw).expect("effective journal");
        let candidate = document("working");
        let transition = serde_json::json!({
            "kind": "working",
            "expectedWorkingRevision": 0,
            "newRevisions": revision(1, 0, Some(1)),
            "contextRevisions": [CONTEXT_ID, revision(1, 0, Some(1))],
            "contextDigests": [CONTEXT_ID, first_context_digest(&candidate)],
            "contextTombstones": [],
            "operations": [],
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
            "newRevision": 1,
            "contextRevisions": [CONTEXT_ID, revision(1, 0, Some(1))],
            "contextDigests": [CONTEXT_ID, first_context_digest(&external)],
            "contextTombstones": [],
            "operations": [],
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
        let (journal_action, journal_digest, receipt) =
            match transaction.next_directive().expect("journal action") {
                WorkspaceJournalMutationDirectiveV1::Action {
                    action_id,
                    kind: WorkspaceJournalMutationActionKindV1::WriteJournal,
                    content_digest,
                    authority_receipt: Some(receipt),
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
                        "newRevision": 1,
                        "contextRevisions": [CONTEXT_ID, revision(1, 1, None)],
                        "contextDigests": [CONTEXT_ID, first_context_digest(&external)],
                        "contextTombstones": [],
                        "operations": [],
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
        let unchanged_operation = operation(unchanged_operation_id, 3.0, 9);
        let unchanged = prepare_workspace_journal_mutation_transaction_v1(
            Some(&raw_clean),
            &effective_clean.canonical_bytes,
            &journal_mutation_request(
                serde_json::json!({
                    "kind": "unchanged",
                    "expectedWorkingRevision": 0,
                    "operation": unchanged_operation,
                    "updatedAt": 3.0
                }),
                9,
                None,
            ),
            &document("saved"),
            Some(&document("saved")),
        )
        .expect("unchanged transaction");
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
        let external = document("external saved");
        let external_digest = format!("{:x}", Sha256::digest(&external));
        let rebased = prepare_workspace_journal_mutation_transaction_v1(
            Some(&raw_dirty),
            &effective_dirty.canonical_bytes,
            &journal_mutation_request(
                serde_json::json!({
                    "kind": "conflictRebase",
                    "expectedRevisions": revision(1, 0, Some(1)),
                    "newRevisions": revision(2, 0, Some(2)),
                    "externalSavedDigest": external_digest.clone(),
                    "contextRevisions": [CONTEXT_ID, revision(2, 0, Some(2))],
                    "contextDigests": [CONTEXT_ID, first_context_digest(&local)],
                    "contextTombstones": [],
                    "operations": [],
                    "updatedAt": 4.0
                }),
                10,
                None,
            ),
            &local,
            Some(&external),
        )
        .expect("conflict rebase transaction");
        let receipt = match rebased.next_directive().expect("rebase action") {
            WorkspaceJournalMutationDirectiveV1::Action {
                kind: WorkspaceJournalMutationActionKindV1::WriteJournal,
                authority_receipt: Some(receipt),
                ..
            } => receipt,
            other => panic!("unexpected rebase directive: {other:?}"),
        };
        let committed = decoded(&receipt.committed_journal);
        assert_eq!(committed.revisions.working_revision, 2);
        assert_eq!(committed.revisions.saved_revision, 0);
        assert_eq!(committed.revisions.dirty_revision, Some(2));
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
        bad_context_request["contextDigests"][1] =
            Value::String(format!("{:x}", Sha256::digest(b"wrong context")));
        assert!(matches!(
            prepare_workspace_create_transaction_v1(
                Some(&raw_catalog),
                &effective_catalog.canonical_bytes,
                None,
                None,
                &serde_json::to_vec(&bad_context_request).expect("bad context request"),
                &document,
            ),
            Err(WorkspaceWorkingJournalError::InvalidDigest)
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
        let transaction = prepare_workspace_delete_transaction_v1(
            Some(&raw_catalog),
            &effective_catalog.canonical_bytes,
            &effective_journal.canonical_bytes,
            &delete_request(0, 9),
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
        mismatched_revision_request["operation"]["catalogRevision"] = serde_json::json!(9);
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
                ..
            } => {
                assert_eq!(
                    expected_raw_journal_digest,
                    Some(format!("{:x}", Sha256::digest(&raw)))
                );
                assert!(authority_receipt.is_none());
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
                "contextRevisions": [CONTEXT_ID, revision(0, 0, None)],
                "contextDigests": [CONTEXT_ID, format!("{:x}", Sha256::digest(b"context"))],
                "contextTombstones": {},
                "operations": [operation(OPERATION_ID, 4.0, 1)],
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
        let malformed_save = transition(
            serde_json::json!({
                "kind": "save",
                "expectedWorkingRevision": 0,
                "operationID": OPERATION_ID,
                "contextRevisions": [CONTEXT_ID, revision(0, 0, None)],
                "contextDigests": [CONTEXT_ID, format!("{:x}", Sha256::digest(b"context"))],
                "contextTombstones": {},
                "operations": [operation(OPERATION_ID, 5.0, 1)],
                "updatedAt": 5.0
            }),
            Some(&raw),
            Some(malformed),
        );
        assert_eq!(
            resolve_workspace_pending_save_v1(
                &malformed_save.primary.canonical_bytes,
                WORKSPACE_ID,
                "file:///tmp/Workspace.json",
                Some(malformed),
            ),
            Err(WorkspaceWorkingJournalError::InvalidWorkingDocument)
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
        let seed = plan_workspace_catalog_transition_v1(
            None,
            &serde_json::to_vec(&seed_request).expect("seed request"),
        )
        .expect("seed catalog");
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
        let upsert = plan_workspace_catalog_transition_v1(
            Some(&seed.canonical_bytes),
            &serde_json::to_vec(&upsert_request).expect("upsert request"),
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
            Err(WorkspaceWorkingJournalError::InvalidIdentity)
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
