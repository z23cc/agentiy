use crate::errors::CoreError;
use crate::generated::contract_identity::{
    ABI_EPOCH, BINDING_CHECKSUM, CORE_BUILD_FINGERPRINT, PAYLOAD_SCHEMA_VERSIONS,
};
use crate::panic_guard::PanicGuard;
use crate::types::{
    AdmissionDisposition, AdmissionReceipt, BulkChunkDiscoveryReceiptV1, BulkChunkReceiptV1,
    CancelReceipt, CommandEnvelope, CompactInventoryPageV1, CompactLookupResultV1,
    CompactQueryResultV1, CompactQueryV1, CompactRecordBlockV1, CompactRegexBatchResult,
    CoreApplyEditsBatchRequestV1, CoreCodeMapBatchRequestV1, CoreCompactApplyEditsBatchResultV1,
    CoreCompactCodeMapBatchResultV1, CoreConfig, CoreHandshake, CoreInventoryScopeConfigV1,
    CorePathMatchResolveRequestV1, CorePathMatchResolveResultV1, CorePathMatchScoreRequestV1,
    CorePathMatchScoreResultV1, CorePathSearchFindRequestV1, CorePathSearchFindResultV1,
    CoreSearchScoreBatchRequestV1, CoreSearchScoreBatchResultV1, CoreTextDecodeRequestV1,
    CoreTextDecodeResultV1, CoreTokenAccountingRequestV1, CoreTokenAccountingResultV1,
    CoreWorkspaceCatalogResponseV1, CoreWorkspaceCatalogSeedRequestV1,
    CoreWorkspaceCatalogValidationRequestV1, CoreWorkspaceCommandAdmissionAcquireKindV1,
    CoreWorkspaceCommandAdmissionDiagnosticsV1, CoreWorkspaceCommandAdmissionLookupScopeV1,
    CoreWorkspaceCommandAdmissionRecoveryReceiptV1, CoreWorkspaceCommandIdentityRequestV1,
    CoreWorkspaceCommandIdentityResponseV1, CoreWorkspaceCommandIdentityV1,
    CoreWorkspaceCommandLifecycleDirectiveV1, CoreWorkspaceCommandResultV1,
    CoreWorkspaceCreateDirectiveV1, CoreWorkspaceCreateTransactionRequestV1,
    CoreWorkspaceDeleteDirectiveV1, CoreWorkspaceDeleteTransactionRequestV1,
    CoreWorkspaceDocumentProjectionRequestV1, CoreWorkspaceDocumentProjectionV1,
    CoreWorkspaceExternalObservationRecoveryPlanV1,
    CoreWorkspaceExternalObservationRecoveryRequestV1,
    CoreWorkspaceExternalObservationRecoveryTransactionRequestV1,
    CoreWorkspaceJournalMutationDirectiveV1, CoreWorkspaceJournalMutationTransactionRequestV1,
    CoreWorkspacePendingSaveRecoveryRequestV1, CoreWorkspacePendingSaveRecoveryV1,
    CoreWorkspacePersistenceMetadataRequestV1, CoreWorkspacePersistenceMetadataResponseV1,
    CoreWorkspacePersistenceMetadataValidationV1, CoreWorkspaceRecordedOperationV1,
    CoreWorkspaceSaveActionReportV1, CoreWorkspaceSaveDirectiveV1,
    CoreWorkspaceSaveTransactionRequestV1, CoreWorkspaceSemanticFullRecoveryV1,
    CoreWorkspaceSemanticInitialRecoveryRequestV1, CoreWorkspaceSemanticPreflightV1,
    CoreWorkspaceSemanticRecoveryAdmissionDispositionV1, CoreWorkspaceSemanticRecoveryPreviewV1,
    CoreWorkspaceSemanticTargetRecoveryV1, CoreWorkspaceWorkingJournalSeedRequestV1,
    CoreWorkspaceWorkingJournalValidationErrorKindV1,
    CoreWorkspaceWorkingJournalValidationRequestV1,
    CoreWorkspaceWorkingJournalValidationResponseV1, DrainBatch, FolderSuffixRequest, HostResponse,
    InventoryComposedSnapshotHandleV1, InventoryComposedSnapshotRequestV1, InventoryDeltaCommandV1,
    InventoryDeltaDiscoveryCommandV1, InventoryDeltaDiscoveryReceiptV1, InventoryDeltaReceiptV1,
    InventoryDiagnosticsV1, InventoryGenerationReceiptV1, InventoryHandleInvalidationReasonV1,
    InventoryProjectedShardRequestV1, InventoryPublishModeV1, InventoryResolveRequestV1,
    InventoryRootLifetimeV1, InventoryRootOpenV1, InventoryRootUnloadReceiptV1,
    InventoryScopeHandleV1, InventorySnapshotHandleV1, InventorySnapshotRequestV1, OperationState,
    OversizeEvent, PathFilterRequest, PathFilterResult, RegexSearchBatchRequest,
    RegexSearchRequest, RegexSearchResult, RuntimeEvent, RuntimeIdentity, ShutdownReceipt,
    SubscriptionBootstrap, SubscriptionId, SubscriptionScope, parse_inventory_scope_id,
    parse_root_id, parse_root_lifetime_id, wire_error,
};
use crate::types::{
    AgentClaudeFlagSettingsDispositionV1, AgentClaudeFlagSettingsReceiptV1,
    AgentClaudeInterruptReceiptV1, AgentClaudePermissionDecisionV1, AgentClaudeScopeHandleV1,
    AgentClaudeStartReceiptV1, CoreAgentClaudeScopeConfigV1,
};
use crate::types::{
    CoreWorkspaceAuthorityProjectionSyncReceiptV1, CoreWorkspaceAuthorityPublicationDraftV1,
    CoreWorkspaceAuthorityPublicationReceiptV1, CoreWorkspaceAuthorityReadV1,
    CoreWorkspaceProjectionPublishedWorkspaceV1,
};
use agentry_proto::{Envelope, PayloadKind};
use agentry_runtime as runtime;
use std::os::fd::IntoRawFd;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};

#[derive(uniffi::Object)]
pub struct LeafCancellation {
    inner: runtime::LeafCancellation,
    runtime: Weak<runtime::CoreRuntime>,
    panic_guard: Arc<PanicGuard>,
}

impl std::fmt::Debug for LeafCancellation {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LeafCancellation")
            .finish_non_exhaustive()
    }
}

impl LeafCancellation {
    pub(crate) fn runtime_handle(&self) -> &runtime::LeafCancellation {
        &self.inner
    }

    fn validate_identity(
        &self,
        identity: &RuntimeIdentity,
    ) -> Result<Arc<runtime::CoreRuntime>, CoreError> {
        let identity = identity.parse()?;
        let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
        if &identity == runtime.identity() && &identity == self.inner.identity() {
            Ok(runtime)
        } else {
            Err(CoreError::StaleRuntimeIdentity)
        }
    }
}

#[uniffi::export]
impl LeafCancellation {
    pub fn cancel(&self, identity: RuntimeIdentity) -> Result<(), CoreError> {
        self.panic_guard.call(|| {
            let runtime = self.validate_identity(&identity)?;
            self.inner.cancel();
            if runtime.lifecycle() == runtime::LifecycleState::Running {
                Ok(())
            } else {
                Err(CoreError::RuntimeStopped)
            }
        })
    }

    pub fn close(&self, identity: RuntimeIdentity) -> Result<(), CoreError> {
        self.panic_guard.call(|| {
            let runtime = self.validate_identity(&identity)?;
            self.inner.close();
            if runtime.lifecycle() == runtime::LifecycleState::Running {
                Ok(())
            } else {
                Err(CoreError::RuntimeStopped)
            }
        })
    }
}

#[derive(Debug, uniffi::Record)]
pub struct CoreWorkspaceSemanticRecoveryPrepareResponseV1 {
    pub recovery: Option<Arc<CorePreparedWorkspaceSemanticRecoveryV1>>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceExternalObservationRecoveryResponseV1 {
    pub plan: Option<CoreWorkspaceExternalObservationRecoveryPlanV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticRecoveryPreviewResponseV1 {
    pub preview: Option<CoreWorkspaceSemanticRecoveryPreviewV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Debug, uniffi::Record)]
pub struct CoreWorkspaceSemanticRecoveryCommitResponseV1 {
    pub admission: Option<Arc<CorePreparedWorkspaceCommandAdmissionV1>>,
    pub admission_receipt: Option<CoreWorkspaceCommandAdmissionRecoveryReceiptV1>,
    pub catalog_revision: Option<u64>,
    pub catalog_digest: Option<String>,
    pub target_workspace_id: Option<String>,
    pub admission_disposition: Option<CoreWorkspaceSemanticRecoveryAdmissionDispositionV1>,
    pub projection_digest: Option<String>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCommandAdmissionMutationResponseV1 {
    pub diagnostics: Option<CoreWorkspaceCommandAdmissionDiagnosticsV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Debug, uniffi::Record)]
pub struct CoreWorkspaceCommandAdmissionAcquireResponseV1 {
    pub kind: Option<CoreWorkspaceCommandAdmissionAcquireKindV1>,
    pub identity: Option<CoreWorkspaceCommandIdentityV1>,
    pub claim: Option<Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    pub scope: Option<CoreWorkspaceCommandAdmissionLookupScopeV1>,
    pub operation: Option<CoreWorkspaceRecordedOperationV1>,
    pub generation: Option<u64>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSemanticPreflightResponseV1 {
    pub preflight: Option<CoreWorkspaceSemanticPreflightV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCommandTransientFinalizationResponseV1 {
    pub operation: Option<CoreWorkspaceRecordedOperationV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(uniffi::Object)]
pub struct CoreWorkspaceCommandExecutionClaimV1 {
    inner: Arc<runtime::workspace_persistence_journal::WorkspaceCommandExecutionClaimV1>,
    admission: Arc<runtime::workspace_persistence_journal::PreparedWorkspaceCommandAdmissionV1>,
    lifecycle: Arc<runtime::ManagedOperationLease>,
    runtime: Weak<runtime::CoreRuntime>,
    identity: runtime::RuntimeIdentity,
    panic_guard: Arc<PanicGuard>,
}

impl std::fmt::Debug for CoreWorkspaceCommandExecutionClaimV1 {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CoreWorkspaceCommandExecutionClaimV1")
            .field("operation_id", &self.inner.operation_id())
            .field("generation", &self.inner.generation())
            .field("lifecycle_generation", &self.lifecycle.generation())
            .finish_non_exhaustive()
    }
}

impl CoreWorkspaceCommandExecutionClaimV1 {
    fn reconcile_terminal_lifecycle(&self) -> bool {
        match self.inner.reconciled_terminal() {
            Ok(Some(operation)) => {
                let terminal = workspace_command_terminal_outcome_from_runtime(&operation);
                matches!(
                    self.lifecycle.resolve_terminal(terminal),
                    Ok(runtime::OperationState::Terminal(actual)) if actual == terminal
                )
            }
            Ok(None) | Err(_) => false,
        }
    }

    fn require_live_runtime(&self) -> Result<(), CoreError> {
        let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
        if runtime.identity() != &self.identity {
            return Err(CoreError::StaleRuntimeIdentity);
        }
        if matches!(
            runtime.lifecycle(),
            runtime::LifecycleState::Running | runtime::LifecycleState::ShuttingDown
        ) {
            Ok(())
        } else {
            Err(CoreError::RuntimeStopped)
        }
    }
}

#[uniffi::export]
impl CoreWorkspaceCommandExecutionClaimV1 {
    pub fn workspace_id(&self) -> String {
        self.inner.workspace_id().to_owned()
    }

    pub fn operation_id(&self) -> String {
        self.inner.operation_id().to_owned()
    }

    pub fn fingerprint(&self) -> String {
        self.inner.fingerprint().to_owned()
    }

    pub fn generation(&self) -> u64 {
        self.inner.generation()
    }

    pub fn semantic_preflight(
        &self,
        request: CoreWorkspaceCommandIdentityRequestV1,
        candidate_document_bytes: Option<Vec<u8>>,
        external_document_bytes: Option<Vec<u8>>,
    ) -> Result<CoreWorkspaceSemanticPreflightResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            if request.runtime_identity.parse()? != self.identity {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            require_workspace_persistence_contract(request.contract_version)?;
            Ok(workspace_command_semantic_preflight_response(
                self.admission.semantic_preflight(
                    self.inner.as_ref(),
                    &workspace_command_identity_request(request),
                    candidate_document_bytes.as_deref(),
                    external_document_bytes.as_deref(),
                ),
            ))
        })
    }

    pub fn checkpoint(&self) -> Result<CoreWorkspaceCommandLifecycleDirectiveV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            workspace_command_lifecycle_directive(self.lifecycle.checkpoint()?)
        })
    }

    pub fn finalize_transient(
        &self,
        operation: CoreWorkspaceRecordedOperationV1,
    ) -> Result<CoreWorkspaceCommandTransientFinalizationResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            let terminal = workspace_command_terminal_outcome(&operation);
            let operation = match self.inner.validate_transient(operation.into()) {
                Ok(operation) => operation,
                Err(error) => {
                    return Ok(workspace_command_transient_finalization_response(Err(
                        error,
                    )));
                }
            };
            let _authority = begin_workspace_command_terminal_finalization(self, terminal)?;
            match self.inner.finalize_transient(operation) {
                Ok(finalized) => {
                    self.lifecycle.resolve_terminal(terminal)?;
                    Ok(workspace_command_transient_finalization_response(Ok(
                        finalized,
                    )))
                }
                Err(error) => Ok(workspace_command_transient_finalization_response(Err(
                    error,
                ))),
            }
        })
    }

    pub fn abandon(&self) -> Result<bool, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            let abandoned = self
                .inner
                .abandon()
                .map_err(|_| CoreError::InvalidArgument)?;
            if abandoned {
                self.lifecycle.abandon()?;
            } else {
                self.reconcile_terminal_lifecycle();
            }
            Ok(abandoned)
        })
    }

    pub fn close(&self) {
        let _ = self.panic_guard.call(|| {
            if self.inner.abandon().unwrap_or(false) {
                let _ = self.lifecycle.abandon();
            } else {
                self.reconcile_terminal_lifecycle();
            }
            Ok::<(), CoreError>(())
        });
    }
}

impl Drop for CoreWorkspaceCommandExecutionClaimV1 {
    fn drop(&mut self) {
        if self.inner.abandon().unwrap_or(false) {
            let _ = self.lifecycle.abandon();
        } else {
            self.reconcile_terminal_lifecycle();
        }
    }
}

#[derive(uniffi::Object)]
pub struct CorePreparedWorkspaceSemanticRecoveryV1 {
    inner: Arc<runtime::workspace_persistence_journal::PreparedWorkspaceSemanticRecoveryV1>,
    runtime: Weak<runtime::CoreRuntime>,
    identity: runtime::RuntimeIdentity,
    panic_guard: Arc<PanicGuard>,
}

impl std::fmt::Debug for CorePreparedWorkspaceSemanticRecoveryV1 {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CorePreparedWorkspaceSemanticRecoveryV1")
            .finish_non_exhaustive()
    }
}

impl CorePreparedWorkspaceSemanticRecoveryV1 {
    fn require_live_runtime(&self) -> Result<(), CoreError> {
        let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
        if runtime.identity() != &self.identity {
            return Err(CoreError::StaleRuntimeIdentity);
        }
        if runtime.lifecycle() == runtime::LifecycleState::Running {
            Ok(())
        } else {
            Err(CoreError::RuntimeStopped)
        }
    }
}

#[uniffi::export]
impl CorePreparedWorkspaceSemanticRecoveryV1 {
    pub fn preview(&self) -> Result<CoreWorkspaceSemanticRecoveryPreviewResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            Ok(match self.inner.preview() {
                Ok(preview) => CoreWorkspaceSemanticRecoveryPreviewResponseV1 {
                    preview: Some(preview.into()),
                    error_kind: None,
                    future_schema_version: None,
                },
                Err(error) => {
                    let (error_kind, future_schema_version) = workspace_journal_error(error);
                    CoreWorkspaceSemanticRecoveryPreviewResponseV1 {
                        preview: None,
                        error_kind: Some(error_kind),
                        future_schema_version,
                    }
                }
            })
        })
    }

    pub fn commit(&self) -> Result<CoreWorkspaceSemanticRecoveryCommitResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            Ok(match self.inner.commit() {
                Ok(commit) => CoreWorkspaceSemanticRecoveryCommitResponseV1 {
                    admission: commit.admission.map(|admission| {
                        Arc::new(CorePreparedWorkspaceCommandAdmissionV1 {
                            inner: Arc::new(admission),
                            runtime: self.runtime.clone(),
                            identity: self.identity.clone(),
                            panic_guard: Arc::clone(&self.panic_guard),
                        })
                    }),
                    admission_receipt: commit.admission_receipt.map(Into::into),
                    catalog_revision: Some(commit.catalog_revision),
                    catalog_digest: Some(commit.catalog_digest),
                    target_workspace_id: commit.target_workspace_id,
                    admission_disposition: Some(commit.admission_disposition.into()),
                    projection_digest: Some(commit.projection_digest),
                    error_kind: None,
                    future_schema_version: None,
                },
                Err(error) => {
                    let (error_kind, future_schema_version) = workspace_journal_error(error);
                    CoreWorkspaceSemanticRecoveryCommitResponseV1 {
                        admission: None,
                        admission_receipt: None,
                        catalog_revision: None,
                        catalog_digest: None,
                        target_workspace_id: None,
                        admission_disposition: None,
                        projection_digest: None,
                        error_kind: Some(error_kind),
                        future_schema_version,
                    }
                }
            })
        })
    }

    pub fn close(&self) -> bool {
        self.inner.close()
    }
}

#[derive(uniffi::Object)]
pub struct CorePreparedWorkspaceCommandAdmissionV1 {
    inner: Arc<runtime::workspace_persistence_journal::PreparedWorkspaceCommandAdmissionV1>,
    runtime: Weak<runtime::CoreRuntime>,
    identity: runtime::RuntimeIdentity,
    panic_guard: Arc<PanicGuard>,
}

impl std::fmt::Debug for CorePreparedWorkspaceCommandAdmissionV1 {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CorePreparedWorkspaceCommandAdmissionV1")
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceAuthorityPublicationResponseV1 {
    pub receipt: Option<CoreWorkspaceAuthorityPublicationReceiptV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceAuthorityProjectionSyncResponseV1 {
    pub receipt: Option<CoreWorkspaceAuthorityProjectionSyncReceiptV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceAuthorityReadResponseV1 {
    pub read: Option<CoreWorkspaceAuthorityReadV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

impl CorePreparedWorkspaceCommandAdmissionV1 {
    fn require_live_runtime(&self) -> Result<(), CoreError> {
        let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
        if runtime.identity() != &self.identity {
            return Err(CoreError::StaleRuntimeIdentity);
        }
        if runtime.lifecycle() == runtime::LifecycleState::Running {
            Ok(())
        } else {
            Err(CoreError::RuntimeStopped)
        }
    }
}

#[uniffi::export]
impl CorePreparedWorkspaceCommandAdmissionV1 {
    pub fn acquire(
        &self,
        request: CoreWorkspaceCommandIdentityRequestV1,
        deadline_unix_millis: Option<u64>,
    ) -> Result<CoreWorkspaceCommandAdmissionAcquireResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            if request.runtime_identity.parse()? != self.identity {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            require_workspace_persistence_contract(request.contract_version)?;
            workspace_command_admission_acquire_response(
                self.inner
                    .acquire(workspace_command_identity_request(request)),
                self,
                deadline_unix_millis,
            )
        })
    }

    pub fn prepare_semantic_full_recovery(
        &self,
        recovery: CoreWorkspaceSemanticFullRecoveryV1,
    ) -> Result<CoreWorkspaceSemanticRecoveryPrepareResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            let identity = self.identity.clone();
            Ok(
                match self.inner.prepare_semantic_full_recovery(&recovery.into()) {
                    Ok(recovery) => CoreWorkspaceSemanticRecoveryPrepareResponseV1 {
                        recovery: Some(Arc::new(CorePreparedWorkspaceSemanticRecoveryV1 {
                            inner: Arc::new(recovery),
                            runtime: self.runtime.clone(),
                            identity,
                            panic_guard: Arc::clone(&self.panic_guard),
                        })),
                        error_kind: None,
                        future_schema_version: None,
                    },
                    Err(error) => {
                        let (error_kind, future_schema_version) = workspace_journal_error(error);
                        CoreWorkspaceSemanticRecoveryPrepareResponseV1 {
                            recovery: None,
                            error_kind: Some(error_kind),
                            future_schema_version,
                        }
                    }
                },
            )
        })
    }

    pub fn prepare_semantic_target_recovery(
        &self,
        recovery: CoreWorkspaceSemanticTargetRecoveryV1,
    ) -> Result<CoreWorkspaceSemanticRecoveryPrepareResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            let identity = self.identity.clone();
            Ok(
                match self
                    .inner
                    .prepare_semantic_target_recovery(&recovery.into())
                {
                    Ok(recovery) => CoreWorkspaceSemanticRecoveryPrepareResponseV1 {
                        recovery: Some(Arc::new(CorePreparedWorkspaceSemanticRecoveryV1 {
                            inner: Arc::new(recovery),
                            runtime: self.runtime.clone(),
                            identity,
                            panic_guard: Arc::clone(&self.panic_guard),
                        })),
                        error_kind: None,
                        future_schema_version: None,
                    },
                    Err(error) => {
                        let (error_kind, future_schema_version) = workspace_journal_error(error);
                        CoreWorkspaceSemanticRecoveryPrepareResponseV1 {
                            recovery: None,
                            error_kind: Some(error_kind),
                            future_schema_version,
                        }
                    }
                },
            )
        })
    }

    pub fn prepare_external_observation_recovery(
        &self,
        request: CoreWorkspaceExternalObservationRecoveryRequestV1,
    ) -> Result<CoreWorkspaceExternalObservationRecoveryResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            if request.runtime_identity.parse()? != self.identity {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            if request.contract_version
                != runtime::workspace_persistence_journal::WORKSPACE_EXTERNAL_OBSERVATION_CONTRACT_VERSION_V1
            {
                return Err(CoreError::InvalidArgument);
            }
            Ok(match self
                .inner
                .prepare_external_observation_recovery(request.into())
            {
                Ok(plan) => CoreWorkspaceExternalObservationRecoveryResponseV1 {
                    plan: Some(plan.into()),
                    error_kind: None,
                    future_schema_version: None,
                },
                Err(error) => {
                    let (error_kind, future_schema_version) = workspace_journal_error(error);
                    CoreWorkspaceExternalObservationRecoveryResponseV1 {
                        plan: None,
                        error_kind: Some(error_kind),
                        future_schema_version,
                    }
                }
            })
        })
    }

    pub fn begin_external_observation_recovery_transaction(
        &self,
        request: CoreWorkspaceExternalObservationRecoveryTransactionRequestV1,
    ) -> Result<CoreWorkspaceJournalMutationTransactionBeginResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            if request.runtime_identity.parse()? != self.identity {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            if request.contract_version
                != runtime::workspace_persistence_journal::WORKSPACE_EXTERNAL_OBSERVATION_CONTRACT_VERSION_V1
            {
                return Err(CoreError::InvalidArgument);
            }
            if request.effective_journal_bytes.len()
                > runtime::workspace_persistence_journal::MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1
                || request.raw_journal_bytes.as_ref().is_some_and(|bytes| {
                    bytes.len()
                        > runtime::workspace_persistence_journal::MAXIMUM_WORKSPACE_WORKING_JOURNAL_BYTES_V1
                })
            {
                return Err(CoreError::InvalidArgument);
            }
            let plan = request.plan.into();
            Ok(match self.inner.begin_external_observation_recovery_transaction(
                plan,
                request.raw_journal_bytes.as_deref(),
                &request.effective_journal_bytes,
                &request.external_document_bytes,
            ) {
                Ok(transaction) => CoreWorkspaceJournalMutationTransactionBeginResponseV1 {
                    transaction: Some(Arc::new(
                        CorePreparedWorkspaceJournalMutationTransactionV1 {
                            inner: transaction,
                            terminal_gate: Mutex::new(()),
                            runtime: self.runtime.clone(),
                            command_claim: None,
                            identity: self.identity.clone(),
                            authority_permit_issued: AtomicBool::new(false),
                            authority_permit: Mutex::new(None),
                            admission_reservation: Mutex::new(None),
                            authority_publication: Mutex::new(None),
                            authority_publication_receipt: Mutex::new(None),
                            panic_guard: Arc::clone(&self.panic_guard),
                        },
                    )),
                    error_kind: None,
                    future_schema_version: None,
                },
                Err(error) => {
                    let (error_kind, future_schema_version) = workspace_journal_error(error);
                    CoreWorkspaceJournalMutationTransactionBeginResponseV1 {
                        transaction: None,
                        error_kind: Some(error_kind),
                        future_schema_version,
                    }
                }
            })
        })
    }

    pub fn publish_authority_state(
        &self,
        workspaces: Vec<CoreWorkspaceProjectionPublishedWorkspaceV1>,
        draft: CoreWorkspaceAuthorityPublicationDraftV1,
    ) -> Result<CoreWorkspaceAuthorityPublicationResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            let workspaces = workspaces.into_iter().map(Into::into).collect::<Vec<_>>();
            Ok(
                match self
                    .inner
                    .publish_authority_state(&workspaces, draft.into())
                {
                    Ok(receipt) => CoreWorkspaceAuthorityPublicationResponseV1 {
                        receipt: Some(receipt.into()),
                        error_kind: None,
                        future_schema_version: None,
                    },
                    Err(error) => {
                        let (error_kind, future_schema_version) = workspace_journal_error(error);
                        CoreWorkspaceAuthorityPublicationResponseV1 {
                            receipt: None,
                            error_kind: Some(error_kind),
                            future_schema_version,
                        }
                    }
                },
            )
        })
    }

    pub fn synchronize_authority_projection(
        &self,
        workspaces: Vec<CoreWorkspaceProjectionPublishedWorkspaceV1>,
    ) -> Result<CoreWorkspaceAuthorityProjectionSyncResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            let workspaces = workspaces.into_iter().map(Into::into).collect::<Vec<_>>();
            Ok(
                match self.inner.synchronize_authority_projection(&workspaces) {
                    Ok(receipt) => CoreWorkspaceAuthorityProjectionSyncResponseV1 {
                        receipt: Some(receipt.into()),
                        error_kind: None,
                        future_schema_version: None,
                    },
                    Err(error) => {
                        let (error_kind, future_schema_version) = workspace_journal_error(error);
                        CoreWorkspaceAuthorityProjectionSyncResponseV1 {
                            receipt: None,
                            error_kind: Some(error_kind),
                            future_schema_version,
                        }
                    }
                },
            )
        })
    }

    pub fn authority_read(
        &self,
        workspace_id: String,
    ) -> Result<CoreWorkspaceAuthorityReadResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            Ok(match self.inner.authority_read(&workspace_id) {
                Ok(read) => CoreWorkspaceAuthorityReadResponseV1 {
                    read: Some(read.into()),
                    error_kind: None,
                    future_schema_version: None,
                },
                Err(error) => {
                    let (error_kind, future_schema_version) = workspace_journal_error(error);
                    CoreWorkspaceAuthorityReadResponseV1 {
                        read: None,
                        error_kind: Some(error_kind),
                        future_schema_version,
                    }
                }
            })
        })
    }

    pub fn diagnostics(
        &self,
    ) -> Result<CoreWorkspaceCommandAdmissionMutationResponseV1, CoreError> {
        self.panic_guard.call(|| {
            self.require_live_runtime()?;
            Ok(workspace_command_admission_mutation_response(
                self.inner.diagnostics(),
            ))
        })
    }

    pub fn close(&self) {
        let _ = self.panic_guard.call(|| {
            self.inner.close();
            Ok::<(), CoreError>(())
        });
    }
}

#[derive(Debug, uniffi::Record)]
pub struct CoreWorkspaceJournalMutationTransactionBeginResponseV1 {
    pub transaction: Option<Arc<CorePreparedWorkspaceJournalMutationTransactionV1>>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceJournalMutationDirectiveResponseV1 {
    pub directive: Option<CoreWorkspaceJournalMutationDirectiveV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Debug, uniffi::Record)]
pub struct CoreWorkspaceSaveTransactionBeginResponseV1 {
    pub transaction: Option<Arc<CorePreparedWorkspaceSaveTransactionV1>>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceSaveDirectiveResponseV1 {
    pub directive: Option<CoreWorkspaceSaveDirectiveV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Debug, uniffi::Record)]
pub struct CoreWorkspaceCreateTransactionBeginResponseV1 {
    pub transaction: Option<Arc<CorePreparedWorkspaceCreateTransactionV1>>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCreateDirectiveResponseV1 {
    pub directive: Option<CoreWorkspaceCreateDirectiveV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Debug, uniffi::Record)]
pub struct CoreWorkspaceDeleteTransactionBeginResponseV1 {
    pub transaction: Option<Arc<CorePreparedWorkspaceDeleteTransactionV1>>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CoreWorkspaceCommandFinalizationV1 {
    NotApplicable,
    Reconciled,
    Unreconciled,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceCommandAuthorityFinalizationV1 {
    pub command_finalization: CoreWorkspaceCommandFinalizationV1,
    pub command_result: Option<CoreWorkspaceCommandResultV1>,
    pub authority_publication: Option<CoreWorkspaceAuthorityPublicationReceiptV1>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceDeleteDirectiveResponseV1 {
    pub directive: Option<CoreWorkspaceDeleteDirectiveV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspaceDeleteCleanupFinalizationResponseV1 {
    pub tombstone: Option<CoreWorkspacePersistenceMetadataValidationV1>,
    pub authority_finalization: CoreWorkspaceCommandAuthorityFinalizationV1,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreWorkspacePendingSaveRecoveryResponseV1 {
    pub recovery: Option<CoreWorkspacePendingSaveRecoveryV1>,
    pub error_kind: Option<CoreWorkspaceWorkingJournalValidationErrorKindV1>,
    pub future_schema_version: Option<u16>,
}

fn finish_workspace_command_authorities(
    reservation: &Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionReservationV1>,
    >,
    authority_publication: &Mutex<
        Option<runtime::workspace_persistence_journal::PreparedWorkspaceAuthorityPublicationV1>,
    >,
    authority_publication_receipt: &Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceAuthorityPublicationReceiptV1>,
    >,
    command_claim: Option<&Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    command_result: Option<runtime::workspace_persistence_journal::WorkspaceCommandResultV1>,
) -> CoreWorkspaceCommandAuthorityFinalizationV1 {
    let Some(command_claim) = command_claim else {
        return CoreWorkspaceCommandAuthorityFinalizationV1 {
            command_finalization: CoreWorkspaceCommandFinalizationV1::NotApplicable,
            command_result: None,
            authority_publication: None,
        };
    };
    let Some(command_result) = command_result else {
        return CoreWorkspaceCommandAuthorityFinalizationV1 {
            command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
            command_result: None,
            authority_publication: None,
        };
    };

    let authority_receipt = {
        let mut committed = match authority_publication_receipt.lock() {
            Ok(committed) => committed,
            Err(_) => {
                return CoreWorkspaceCommandAuthorityFinalizationV1 {
                    command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                    command_result: None,
                    authority_publication: None,
                };
            }
        };
        if committed.is_none() {
            let mut reservation = match reservation.lock() {
                Ok(reservation) => reservation,
                Err(_) => {
                    return CoreWorkspaceCommandAuthorityFinalizationV1 {
                        command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                        command_result: None,
                        authority_publication: None,
                    };
                }
            };
            let mut publication = match authority_publication.lock() {
                Ok(publication) => publication,
                Err(_) => {
                    return CoreWorkspaceCommandAuthorityFinalizationV1 {
                        command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                        command_result: None,
                        authority_publication: None,
                    };
                }
            };
            let Some(pending) = reservation.as_mut() else {
                return CoreWorkspaceCommandAuthorityFinalizationV1 {
                    command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                    command_result: None,
                    authority_publication: None,
                };
            };
            let Some(prepared_publication) = publication.as_ref() else {
                return CoreWorkspaceCommandAuthorityFinalizationV1 {
                    command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                    command_result: None,
                    authority_publication: None,
                };
            };
            let Ok((_, receipt)) = pending.finalize_with_authority(prepared_publication) else {
                return CoreWorkspaceCommandAuthorityFinalizationV1 {
                    command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                    command_result: None,
                    authority_publication: None,
                };
            };
            reservation.take();
            publication.take();
            *committed = Some(receipt);
        }
        committed.clone()
    };

    let command_finalization = if matches!(
        command_claim
            .lifecycle
            .resolve_terminal(runtime::TerminalOutcome::Success),
        Ok(runtime::OperationState::Terminal(
            runtime::TerminalOutcome::Success
        ))
    ) {
        CoreWorkspaceCommandFinalizationV1::Reconciled
    } else {
        CoreWorkspaceCommandFinalizationV1::Unreconciled
    };
    CoreWorkspaceCommandAuthorityFinalizationV1 {
        command_finalization,
        command_result: (command_finalization == CoreWorkspaceCommandFinalizationV1::Reconciled)
            .then_some(command_result.into()),
        authority_publication: authority_receipt.map(Into::into),
    }
}

fn finish_workspace_delete_command_authorities(
    reservation: &Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionReservationV1>,
    >,
    authority_publication: &Mutex<
        Option<runtime::workspace_persistence_journal::PreparedWorkspaceAuthorityPublicationV1>,
    >,
    authority_publication_receipt: &Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceAuthorityPublicationReceiptV1>,
    >,
    command_claim: Option<&Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    command_result: Option<runtime::workspace_persistence_journal::WorkspaceCommandResultV1>,
    replacement_operation: runtime::workspace_persistence_journal::WorkspaceRecordedOperationV1,
) -> CoreWorkspaceCommandAuthorityFinalizationV1 {
    let Some(command_claim) = command_claim else {
        return CoreWorkspaceCommandAuthorityFinalizationV1 {
            command_finalization: CoreWorkspaceCommandFinalizationV1::NotApplicable,
            command_result: None,
            authority_publication: None,
        };
    };
    let Some(command_result) = command_result else {
        return CoreWorkspaceCommandAuthorityFinalizationV1 {
            command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
            command_result: None,
            authority_publication: None,
        };
    };

    let authority_receipt = {
        let mut committed = match authority_publication_receipt.lock() {
            Ok(committed) => committed,
            Err(_) => {
                return CoreWorkspaceCommandAuthorityFinalizationV1 {
                    command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                    command_result: None,
                    authority_publication: None,
                };
            }
        };
        if committed.is_none() {
            let mut reservation = match reservation.lock() {
                Ok(reservation) => reservation,
                Err(_) => {
                    return CoreWorkspaceCommandAuthorityFinalizationV1 {
                        command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                        command_result: None,
                        authority_publication: None,
                    };
                }
            };
            let mut publication = match authority_publication.lock() {
                Ok(publication) => publication,
                Err(_) => {
                    return CoreWorkspaceCommandAuthorityFinalizationV1 {
                        command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                        command_result: None,
                        authority_publication: None,
                    };
                }
            };
            let Some(pending) = reservation.as_mut() else {
                return CoreWorkspaceCommandAuthorityFinalizationV1 {
                    command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                    command_result: None,
                    authority_publication: None,
                };
            };
            let Some(prepared_publication) = publication.as_ref() else {
                return CoreWorkspaceCommandAuthorityFinalizationV1 {
                    command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                    command_result: None,
                    authority_publication: None,
                };
            };
            let receipt = match pending
                .finalize_delete_with_authority(prepared_publication, replacement_operation)
            {
                Ok((_, receipt)) => receipt,
                Err(_error) => {
                    return CoreWorkspaceCommandAuthorityFinalizationV1 {
                        command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                        command_result: None,
                        authority_publication: None,
                    };
                }
            };
            reservation.take();
            publication.take();
            *committed = Some(receipt);
        }
        committed.clone()
    };

    let command_finalization = if matches!(
        command_claim
            .lifecycle
            .resolve_terminal(runtime::TerminalOutcome::Success),
        Ok(runtime::OperationState::Terminal(
            runtime::TerminalOutcome::Success
        ))
    ) {
        CoreWorkspaceCommandFinalizationV1::Reconciled
    } else {
        CoreWorkspaceCommandFinalizationV1::Unreconciled
    };
    CoreWorkspaceCommandAuthorityFinalizationV1 {
        command_finalization,
        command_result: (command_finalization == CoreWorkspaceCommandFinalizationV1::Reconciled)
            .then_some(command_result.into()),
        authority_publication: authority_receipt.map(Into::into),
    }
}

fn begin_workspace_command_terminal_finalization(
    command_claim: &CoreWorkspaceCommandExecutionClaimV1,
    requested_terminal: runtime::TerminalOutcome,
) -> Result<Option<runtime::AuthorityOperationPermit>, CoreError> {
    let runtime = command_claim
        .runtime
        .upgrade()
        .ok_or(CoreError::RuntimeStopped)?;
    let (directive, permit) = runtime
        .begin_managed_authority_operation(&command_claim.lifecycle)
        .map_err(CoreError::from)?;
    match directive {
        runtime::ManagedOperationDirective::ContinueExecution => {
            permit.map(Some).ok_or(CoreError::InvalidArgument)
        }
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::Cancelled,
        ) if requested_terminal == runtime::TerminalOutcome::Cancelled => Ok(None),
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::DeadlineExceeded,
        ) if requested_terminal == runtime::TerminalOutcome::DeadlineExceeded => Ok(None),
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::DeadlineExceeded,
        ) => Err(CoreError::DeadlineExpired),
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::Cancelled,
        ) => Err(CoreError::OperationCancelled),
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::ShutdownRequested,
        ) => Err(CoreError::ShutdownRequested),
        runtime::ManagedOperationDirective::Terminal(_) => Err(CoreError::OperationConflict),
    }
}

fn acquire_workspace_command_authority_permit(
    runtime: &runtime::CoreRuntime,
    command_claim: Option<&Arc<CoreWorkspaceCommandExecutionClaimV1>>,
) -> Result<runtime::AuthorityOperationPermit, CoreError> {
    let Some(command_claim) = command_claim else {
        return runtime.begin_authority_operation().map_err(CoreError::from);
    };
    let (directive, permit) = runtime
        .begin_managed_authority_operation(&command_claim.lifecycle)
        .map_err(CoreError::from)?;
    match directive {
        runtime::ManagedOperationDirective::ContinueExecution => {
            permit.ok_or(CoreError::InvalidArgument)
        }
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::DeadlineExceeded,
        )
        | runtime::ManagedOperationDirective::Terminal(
            runtime::TerminalOutcome::DeadlineExceeded,
        ) => Err(CoreError::DeadlineExpired),
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::Cancelled,
        )
        | runtime::ManagedOperationDirective::Terminal(runtime::TerminalOutcome::Cancelled) => {
            Err(CoreError::OperationCancelled)
        }
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::ShutdownRequested,
        ) => Err(CoreError::ShutdownRequested),
        runtime::ManagedOperationDirective::Terminal(
            runtime::TerminalOutcome::Success | runtime::TerminalOutcome::Failed,
        ) => Err(CoreError::OperationConflict),
    }
}

fn cancel_workspace_command_authorities(
    reservation: &Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionReservationV1>,
    >,
    authority_publication: &Mutex<
        Option<runtime::workspace_persistence_journal::PreparedWorkspaceAuthorityPublicationV1>,
    >,
) {
    if let Ok(mut reservation) = reservation.lock() {
        reservation.take();
    }
    if let Ok(mut publication) = authority_publication.lock() {
        publication.take();
    }
}

/// Binds the prepared transaction to its exact claim. A claimless transaction is
/// valid only when Rust classified the request as an explicit recovery/non-command
/// path and therefore produced no admission finalization. Conversely, a supplied
/// claim cannot attach to a recovery transaction.
fn bind_workspace_command_admission_finalization(
    claim: Option<&Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    finalization: Option<
        runtime::workspace_persistence_journal::WorkspaceCommandAdmissionFinalizationV1,
    >,
) -> Result<
    Option<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionReservationV1>,
    runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
> {
    match (claim, finalization) {
        (Some(claim), Some(finalization)) => claim
            .admission
            .bind_claim(&claim.inner, finalization)
            .map(Some),
        (None, Some(_)) | (Some(_), None) => Err(
            runtime::workspace_persistence_journal::WorkspaceWorkingJournalError::InvalidTransaction,
        ),
        (None, None) => Ok(None),
    }
}

#[derive(uniffi::Object)]
pub struct CorePreparedWorkspaceJournalMutationTransactionV1 {
    inner: runtime::workspace_persistence_journal::PreparedWorkspaceJournalMutationTransactionV1,
    terminal_gate: Mutex<()>,
    runtime: Weak<runtime::CoreRuntime>,
    command_claim: Option<Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    identity: runtime::RuntimeIdentity,
    authority_permit_issued: AtomicBool,
    authority_permit: Mutex<Option<Arc<Mutex<Option<runtime::AuthorityOperationPermit>>>>>,
    admission_reservation: Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionReservationV1>,
    >,
    authority_publication: Mutex<
        Option<runtime::workspace_persistence_journal::PreparedWorkspaceAuthorityPublicationV1>,
    >,
    authority_publication_receipt: Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceAuthorityPublicationReceiptV1>,
    >,
    panic_guard: Arc<PanicGuard>,
}

impl std::fmt::Debug for CorePreparedWorkspaceJournalMutationTransactionV1 {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CorePreparedWorkspaceJournalMutationTransactionV1")
            .field("authoritative", &self.inner.is_authoritative())
            .finish_non_exhaustive()
    }
}

impl CorePreparedWorkspaceJournalMutationTransactionV1 {
    fn require_live_runtime(&self) -> Result<(), CoreError> {
        let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
        if runtime.identity() != &self.identity {
            return Err(CoreError::StaleRuntimeIdentity);
        }
        if runtime.lifecycle() == runtime::LifecycleState::Running {
            Ok(())
        } else {
            Err(CoreError::RuntimeStopped)
        }
    }
}

#[uniffi::export]
impl CorePreparedWorkspaceJournalMutationTransactionV1 {
    pub fn acquire_authority_permit(
        &self,
    ) -> Result<Arc<CoreWorkspaceCreateAuthorityPermitV1>, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !self.inner.is_ready_for_authority()
                || self
                    .authority_permit_issued
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
            {
                return Err(CoreError::InvalidArgument);
            }
            let permit = (|| {
                let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
                if runtime.identity() != &self.identity {
                    return Err(CoreError::StaleRuntimeIdentity);
                }
                acquire_workspace_command_authority_permit(&runtime, self.command_claim.as_ref())
            })();
            match permit {
                Ok(permit) => {
                    let inner = Arc::new(Mutex::new(Some(permit)));
                    *self
                        .authority_permit
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner()) =
                        Some(Arc::clone(&inner));
                    Ok(Arc::new(CoreWorkspaceCreateAuthorityPermitV1 {
                        inner,
                        panic_guard: Arc::clone(&self.panic_guard),
                    }))
                }
                Err(error) => {
                    self.authority_permit_issued.store(false, Ordering::Release);
                    Err(error)
                }
            }
        })
    }

    pub fn next_directive(
        &self,
    ) -> Result<CoreWorkspaceJournalMutationDirectiveResponseV1, CoreError> {
        self.panic_guard.call(|| {
            if !self.inner.is_authoritative() {
                self.require_live_runtime()?;
            }
            Ok(workspace_journal_mutation_directive_response(
                self.inner.next_directive(),
            ))
        })
    }

    pub fn report_action(
        &self,
        report: CoreWorkspaceSaveActionReportV1,
    ) -> Result<CoreWorkspaceJournalMutationDirectiveResponseV1, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if self.inner.is_ready_for_authority() {
                let authority_slot = self
                    .authority_permit
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                let authority_permit = authority_slot.as_ref().ok_or(CoreError::InvalidArgument)?;
                let mut authority_guard = authority_permit
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if authority_guard.is_none() {
                    return Err(CoreError::InvalidArgument);
                }
                let result = self.inner.report_action(report.into());
                let did_advance = result.is_ok();
                if did_advance && self.inner.is_authoritative() {
                    let _ = finish_workspace_command_authorities(
                        &self.admission_reservation,
                        &self.authority_publication,
                        &self.authority_publication_receipt,
                        self.command_claim.as_ref(),
self.inner.command_result().ok().flatten(),
                    );
                } else if matches!(
                    result,
                    Ok(runtime::workspace_persistence_journal::WorkspaceJournalMutationDirectiveV1::Failed { .. })
                ) {
                    cancel_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                );
                }
                let response = workspace_journal_mutation_directive_response(result);
                if did_advance {
                    authority_guard.take();
                }
                return Ok(response);
            }

            let result = self.inner.report_action(report.into());
            if result.is_ok() && self.inner.is_authoritative() {
                let _ = finish_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                    &self.authority_publication_receipt,
                    self.command_claim.as_ref(),
self.inner.command_result().ok().flatten(),
                );
            } else if matches!(
                result,
                Ok(runtime::workspace_persistence_journal::WorkspaceJournalMutationDirectiveV1::Failed { .. })
            ) {
                cancel_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                );
            }
            if !self.inner.is_authoritative() {
                self.require_live_runtime()?;
            }
            Ok(workspace_journal_mutation_directive_response(result))
        })
    }

    pub fn finish_command_authority(
        &self,
    ) -> Result<CoreWorkspaceCommandAuthorityFinalizationV1, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !self.inner.is_authoritative() {
                return Err(CoreError::InvalidArgument);
            }
            Ok(finish_workspace_command_authorities(
                &self.admission_reservation,
                &self.authority_publication,
                &self.authority_publication_receipt,
                self.command_claim.as_ref(),
                self.inner.command_result().ok().flatten(),
            ))
        })
    }

    pub fn close(&self) {
        let _ = self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if self.inner.is_authoritative() {
                let _ = finish_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                    &self.authority_publication_receipt,
                    self.command_claim.as_ref(),
                    self.inner.command_result().ok().flatten(),
                );
            } else {
                cancel_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                );
            }
            self.inner.close();
            if let Some(permit) = self
                .authority_permit
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .take()
            {
                permit
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .take();
            }
            Ok::<(), CoreError>(())
        });
    }
}

#[derive(uniffi::Object)]
pub struct CorePreparedWorkspaceSaveTransactionV1 {
    inner: runtime::workspace_persistence_journal::PreparedWorkspaceSaveTransactionV1,
    terminal_gate: Mutex<()>,
    runtime: Weak<runtime::CoreRuntime>,
    command_claim: Option<Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    admission_reservation: Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionReservationV1>,
    >,
    authority_publication: Mutex<
        Option<runtime::workspace_persistence_journal::PreparedWorkspaceAuthorityPublicationV1>,
    >,
    authority_publication_receipt: Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceAuthorityPublicationReceiptV1>,
    >,
    identity: runtime::RuntimeIdentity,
    authority_permit_issued: AtomicBool,
    authority_permit: Mutex<Option<Arc<Mutex<Option<runtime::AuthorityOperationPermit>>>>>,
    panic_guard: Arc<PanicGuard>,
}

impl std::fmt::Debug for CorePreparedWorkspaceSaveTransactionV1 {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CorePreparedWorkspaceSaveTransactionV1")
            .field("authoritative", &self.inner.is_authoritative())
            .finish_non_exhaustive()
    }
}

impl CorePreparedWorkspaceSaveTransactionV1 {
    fn require_live_runtime(&self) -> Result<(), CoreError> {
        let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
        if runtime.identity() != &self.identity {
            return Err(CoreError::StaleRuntimeIdentity);
        }
        if runtime.lifecycle() == runtime::LifecycleState::Running {
            Ok(())
        } else {
            Err(CoreError::RuntimeStopped)
        }
    }
}

#[uniffi::export]
impl CorePreparedWorkspaceSaveTransactionV1 {
    pub fn acquire_authority_permit(
        &self,
    ) -> Result<Arc<CoreWorkspaceCreateAuthorityPermitV1>, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !self.inner.is_ready_for_authority()
                || self
                    .authority_permit_issued
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
            {
                return Err(CoreError::InvalidArgument);
            }
            let permit = (|| {
                let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
                if runtime.identity() != &self.identity {
                    return Err(CoreError::StaleRuntimeIdentity);
                }
                acquire_workspace_command_authority_permit(&runtime, self.command_claim.as_ref())
            })();
            match permit {
                Ok(permit) => {
                    let inner = Arc::new(Mutex::new(Some(permit)));
                    *self
                        .authority_permit
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner()) =
                        Some(Arc::clone(&inner));
                    Ok(Arc::new(CoreWorkspaceCreateAuthorityPermitV1 {
                        inner,
                        panic_guard: Arc::clone(&self.panic_guard),
                    }))
                }
                Err(error) => {
                    self.authority_permit_issued.store(false, Ordering::Release);
                    Err(error)
                }
            }
        })
    }

    pub fn next_directive(&self) -> Result<CoreWorkspaceSaveDirectiveResponseV1, CoreError> {
        self.panic_guard.call(|| {
            if !self.inner.is_authoritative() {
                self.require_live_runtime()?;
            }
            Ok(workspace_save_directive_response(
                self.inner.next_directive(),
            ))
        })
    }

    pub fn report_action(
        &self,
        report: CoreWorkspaceSaveActionReportV1,
    ) -> Result<CoreWorkspaceSaveDirectiveResponseV1, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let authority_slot = self
                .authority_permit
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let mut authority_guard = if self.inner.is_ready_for_authority() {
                let authority_permit = authority_slot.as_ref().ok_or(CoreError::InvalidArgument)?;
                let authority_guard = authority_permit
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if authority_guard.is_none() {
                    return Err(CoreError::InvalidArgument);
                }
                Some(authority_guard)
            } else {
                None
            };
            let result = self.inner.report_action(report.into());
            if result.is_ok() && self.inner.is_authoritative() {
                let _ = finish_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                    &self.authority_publication_receipt,
                    self.command_claim.as_ref(),
                    self.inner.command_result().ok().flatten(),
                );
            } else if matches!(
                result,
                Ok(runtime::workspace_persistence_journal::WorkspaceSaveDirectiveV1::Failed { .. })
            ) {
                cancel_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                );
            }
            if !self.inner.is_authoritative() {
                self.require_live_runtime()?;
            }
            if let Some(authority_guard) = authority_guard.as_mut() {
                authority_guard.take();
            }
            Ok(workspace_save_directive_response(result))
        })
    }

    pub fn finish_command_authority(
        &self,
    ) -> Result<CoreWorkspaceCommandAuthorityFinalizationV1, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !self.inner.is_authoritative() {
                return Err(CoreError::InvalidArgument);
            }
            Ok(finish_workspace_command_authorities(
                &self.admission_reservation,
                &self.authority_publication,
                &self.authority_publication_receipt,
                self.command_claim.as_ref(),
                self.inner.command_result().ok().flatten(),
            ))
        })
    }

    pub fn close(&self) {
        let _ = self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if self.inner.is_authoritative() {
                let _ = finish_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                    &self.authority_publication_receipt,
                    self.command_claim.as_ref(),
                    self.inner.command_result().ok().flatten(),
                );
            } else {
                cancel_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                );
            }
            self.inner.close();
            if let Some(permit) = self
                .authority_permit
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .take()
            {
                permit
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .take();
            }
            Ok::<(), CoreError>(())
        });
    }
}

#[derive(uniffi::Object)]
pub struct CorePreparedWorkspaceCreateTransactionV1 {
    inner: runtime::workspace_persistence_journal::PreparedWorkspaceCreateTransactionV1,
    terminal_gate: Mutex<()>,
    runtime: Weak<runtime::CoreRuntime>,
    command_claim: Option<Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    admission_reservation: Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionReservationV1>,
    >,
    authority_publication: Mutex<
        Option<runtime::workspace_persistence_journal::PreparedWorkspaceAuthorityPublicationV1>,
    >,
    authority_publication_receipt: Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceAuthorityPublicationReceiptV1>,
    >,
    identity: runtime::RuntimeIdentity,
    authority_permit_issued: AtomicBool,
    authority_permit: Mutex<Option<Arc<Mutex<Option<runtime::AuthorityOperationPermit>>>>>,
    panic_guard: Arc<PanicGuard>,
}

#[derive(uniffi::Object)]
pub struct CoreWorkspaceCreateAuthorityPermitV1 {
    inner: Arc<Mutex<Option<runtime::AuthorityOperationPermit>>>,
    panic_guard: Arc<PanicGuard>,
}

impl std::fmt::Debug for CoreWorkspaceCreateAuthorityPermitV1 {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CoreWorkspaceCreateAuthorityPermitV1")
            .finish_non_exhaustive()
    }
}

#[uniffi::export]
impl CoreWorkspaceCreateAuthorityPermitV1 {
    pub fn close(&self) {
        let _ = self.panic_guard.call(|| {
            self.inner
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .take();
            Ok::<(), CoreError>(())
        });
    }
}

impl std::fmt::Debug for CorePreparedWorkspaceCreateTransactionV1 {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CorePreparedWorkspaceCreateTransactionV1")
            .field("authoritative", &self.inner.is_authoritative())
            .finish_non_exhaustive()
    }
}

impl CorePreparedWorkspaceCreateTransactionV1 {
    fn require_live_runtime(&self) -> Result<(), CoreError> {
        let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
        if runtime.identity() != &self.identity {
            return Err(CoreError::StaleRuntimeIdentity);
        }
        if runtime.lifecycle() == runtime::LifecycleState::Running {
            Ok(())
        } else {
            Err(CoreError::RuntimeStopped)
        }
    }
}

#[uniffi::export]
impl CorePreparedWorkspaceCreateTransactionV1 {
    pub fn acquire_authority_permit(
        &self,
    ) -> Result<Arc<CoreWorkspaceCreateAuthorityPermitV1>, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !self.inner.is_ready_for_authority()
                || self
                    .authority_permit_issued
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
            {
                return Err(CoreError::InvalidArgument);
            }
            let permit = (|| {
                let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
                if runtime.identity() != &self.identity {
                    return Err(CoreError::StaleRuntimeIdentity);
                }
                acquire_workspace_command_authority_permit(&runtime, self.command_claim.as_ref())
            })();
            match permit {
                Ok(permit) => {
                    let inner = Arc::new(Mutex::new(Some(permit)));
                    *self
                        .authority_permit
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner()) =
                        Some(Arc::clone(&inner));
                    Ok(Arc::new(CoreWorkspaceCreateAuthorityPermitV1 {
                        inner,
                        panic_guard: Arc::clone(&self.panic_guard),
                    }))
                }
                Err(error) => {
                    self.authority_permit_issued.store(false, Ordering::Release);
                    Err(error)
                }
            }
        })
    }

    pub fn next_directive(&self) -> Result<CoreWorkspaceCreateDirectiveResponseV1, CoreError> {
        self.panic_guard.call(|| {
            if !self.inner.is_authoritative() {
                self.require_live_runtime()?;
            }
            Ok(workspace_create_directive_response(
                self.inner.next_directive(),
            ))
        })
    }

    pub fn report_action(
        &self,
        report: CoreWorkspaceSaveActionReportV1,
    ) -> Result<CoreWorkspaceCreateDirectiveResponseV1, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let authority_slot = self
                .authority_permit
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let mut authority_guard = if self.inner.is_ready_for_authority() {
                let authority_permit = authority_slot
                    .as_ref()
                    .ok_or(CoreError::InvalidArgument)?;
                let authority_guard = authority_permit
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if authority_guard.is_none() {
                    return Err(CoreError::InvalidArgument);
                }
                Some(authority_guard)
            } else {
                if !self.inner.is_authoritative() {
                    self.require_live_runtime()?;
                }
                None
            };
            let result = self.inner.report_action(report.into());
            if result.is_ok() && self.inner.is_authoritative() {
                let _ = finish_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                    &self.authority_publication_receipt,
                    self.command_claim.as_ref(),
self.inner.command_result().ok().flatten(),
                );
            } else if matches!(
                result,
                Ok(runtime::workspace_persistence_journal::WorkspaceCreateDirectiveV1::Failed { .. })
            ) {
                cancel_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                );
            }
            if let Some(authority_guard) = authority_guard.as_mut() {
                authority_guard.take();
            }
            Ok(workspace_create_directive_response(result))
        })
    }

    pub fn finish_command_authority(
        &self,
    ) -> Result<CoreWorkspaceCommandAuthorityFinalizationV1, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !self.inner.is_authoritative() {
                return Err(CoreError::InvalidArgument);
            }
            Ok(finish_workspace_command_authorities(
                &self.admission_reservation,
                &self.authority_publication,
                &self.authority_publication_receipt,
                self.command_claim.as_ref(),
                self.inner.command_result().ok().flatten(),
            ))
        })
    }

    pub fn close(&self) {
        let _ = self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if self.inner.is_authoritative() {
                let _ = finish_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                    &self.authority_publication_receipt,
                    self.command_claim.as_ref(),
                    self.inner.command_result().ok().flatten(),
                );
            } else {
                cancel_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                );
            }
            self.inner.close();
            if let Some(permit) = self
                .authority_permit
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .take()
            {
                permit
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .take();
            }
            Ok::<(), CoreError>(())
        });
    }
}

#[derive(uniffi::Object)]
pub struct CorePreparedWorkspaceDeleteTransactionV1 {
    inner: runtime::workspace_persistence_journal::PreparedWorkspaceDeleteTransactionV1,
    terminal_gate: Mutex<()>,
    cleanup_finalization: Mutex<Option<CoreWorkspaceDeleteCleanupFinalizationResponseV1>>,
    runtime: Weak<runtime::CoreRuntime>,
    command_claim: Option<Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    admission_reservation: Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceCommandAdmissionReservationV1>,
    >,
    authority_publication: Mutex<
        Option<runtime::workspace_persistence_journal::PreparedWorkspaceAuthorityPublicationV1>,
    >,
    authority_publication_receipt: Mutex<
        Option<runtime::workspace_persistence_journal::WorkspaceAuthorityPublicationReceiptV1>,
    >,
    identity: runtime::RuntimeIdentity,
    authority_permit_issued: AtomicBool,
    authority_permit: Mutex<Option<Arc<Mutex<Option<runtime::AuthorityOperationPermit>>>>>,
    panic_guard: Arc<PanicGuard>,
}

impl std::fmt::Debug for CorePreparedWorkspaceDeleteTransactionV1 {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CorePreparedWorkspaceDeleteTransactionV1")
            .field("authoritative", &self.inner.is_authoritative())
            .finish_non_exhaustive()
    }
}

impl CorePreparedWorkspaceDeleteTransactionV1 {
    fn require_live_runtime(&self) -> Result<(), CoreError> {
        let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
        if runtime.identity() != &self.identity {
            return Err(CoreError::StaleRuntimeIdentity);
        }
        if runtime.lifecycle() == runtime::LifecycleState::Running {
            Ok(())
        } else {
            Err(CoreError::RuntimeStopped)
        }
    }

    fn finish_delete_cleanup_locked(
        &self,
        cleanup_warnings_bytes: Option<&[u8]>,
    ) -> Result<CoreWorkspaceDeleteCleanupFinalizationResponseV1, CoreError> {
        let mut cached = self
            .cleanup_finalization
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(cached) = cached.as_ref() {
            return Ok(cached.clone());
        }
        if !self.inner.is_authoritative() {
            return Err(CoreError::InvalidArgument);
        }
        let response = match self.inner.cleanup_plan(cleanup_warnings_bytes) {
            Ok(plan) => {
                let authority_finalization = finish_workspace_delete_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                    &self.authority_publication_receipt,
                    self.command_claim.as_ref(),
                    self.inner.command_result().ok().flatten(),
                    plan.operation,
                );
                CoreWorkspaceDeleteCleanupFinalizationResponseV1 {
                    tombstone: Some(plan.validation.into()),
                    authority_finalization,
                    error_kind: None,
                    future_schema_version: None,
                }
            }
            Err(error) => {
                let (error_kind, future_schema_version) = workspace_journal_error(error);
                CoreWorkspaceDeleteCleanupFinalizationResponseV1 {
                    tombstone: None,
                    authority_finalization: CoreWorkspaceCommandAuthorityFinalizationV1 {
                        command_finalization: CoreWorkspaceCommandFinalizationV1::Unreconciled,
                        command_result: None,
                        authority_publication: self
                            .authority_publication_receipt
                            .lock()
                            .ok()
                            .and_then(|receipt| receipt.clone())
                            .map(Into::into),
                    },
                    error_kind: Some(error_kind),
                    future_schema_version,
                }
            }
        };
        if response.authority_finalization.command_finalization
            != CoreWorkspaceCommandFinalizationV1::Unreconciled
        {
            *cached = Some(response.clone());
        }
        Ok(response)
    }
}

#[uniffi::export]
impl CorePreparedWorkspaceDeleteTransactionV1 {
    pub fn acquire_authority_permit(
        &self,
    ) -> Result<Arc<CoreWorkspaceCreateAuthorityPermitV1>, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !self.inner.is_ready_for_authority()
                || self
                    .authority_permit_issued
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
            {
                return Err(CoreError::InvalidArgument);
            }
            let permit = (|| {
                let runtime = self.runtime.upgrade().ok_or(CoreError::RuntimeStopped)?;
                if runtime.identity() != &self.identity {
                    return Err(CoreError::StaleRuntimeIdentity);
                }
                acquire_workspace_command_authority_permit(&runtime, self.command_claim.as_ref())
            })();
            match permit {
                Ok(permit) => {
                    let inner = Arc::new(Mutex::new(Some(permit)));
                    *self
                        .authority_permit
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner()) =
                        Some(Arc::clone(&inner));
                    Ok(Arc::new(CoreWorkspaceCreateAuthorityPermitV1 {
                        inner,
                        panic_guard: Arc::clone(&self.panic_guard),
                    }))
                }
                Err(error) => {
                    self.authority_permit_issued.store(false, Ordering::Release);
                    Err(error)
                }
            }
        })
    }

    pub fn next_directive(&self) -> Result<CoreWorkspaceDeleteDirectiveResponseV1, CoreError> {
        self.panic_guard.call(|| {
            if !self.inner.is_authoritative() {
                self.require_live_runtime()?;
            }
            Ok(workspace_delete_directive_response(
                self.inner.next_directive(),
            ))
        })
    }

    pub fn report_action(
        &self,
        report: CoreWorkspaceSaveActionReportV1,
    ) -> Result<CoreWorkspaceDeleteDirectiveResponseV1, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let authority_slot = self
                .authority_permit
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let mut authority_guard = if self.inner.is_ready_for_authority() {
                let authority_permit = authority_slot
                    .as_ref()
                    .ok_or(CoreError::InvalidArgument)?;
                let authority_guard = authority_permit
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if authority_guard.is_none() {
                    return Err(CoreError::InvalidArgument);
                }
                Some(authority_guard)
            } else {
                if !self.inner.is_authoritative() {
                    self.require_live_runtime()?;
                }
                None
            };
            let result = self.inner.report_action(report.into());
            if matches!(
                result,
                Ok(runtime::workspace_persistence_journal::WorkspaceDeleteDirectiveV1::Failed { .. })
            ) {
                cancel_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                );
            }
            if let Some(authority_guard) = authority_guard.as_mut() {
                authority_guard.take();
            }
            Ok(workspace_delete_directive_response(result))
        })
    }

    pub fn plan_cleanup(
        &self,
        cleanup_warnings_bytes: Vec<u8>,
    ) -> Result<CoreWorkspacePersistenceMetadataResponseV1, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            Ok(workspace_metadata_response(
                self.inner
                    .cleanup_plan(Some(&cleanup_warnings_bytes))
                    .map(|plan| plan.validation),
            ))
        })
    }

    pub fn finish_command_authority(
        &self,
        cleanup_warnings_bytes: Option<Vec<u8>>,
    ) -> Result<CoreWorkspaceDeleteCleanupFinalizationResponseV1, CoreError> {
        self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            self.finish_delete_cleanup_locked(cleanup_warnings_bytes.as_deref())
        })
    }

    pub fn close(&self) {
        let _ = self.panic_guard.call(|| {
            let _terminal_guard = self
                .terminal_gate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if self.inner.is_authoritative() {
                let _ = self.finish_delete_cleanup_locked(None);
            } else {
                cancel_workspace_command_authorities(
                    &self.admission_reservation,
                    &self.authority_publication,
                );
            }
            self.inner.close();
            if let Some(permit) = self
                .authority_permit
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .take()
            {
                permit
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .take();
            }
            Ok::<(), CoreError>(())
        });
    }
}

#[derive(uniffi::Object)]
pub struct CoreRuntime {
    inner: Arc<runtime::CoreRuntime>,
    search_leaf: runtime::SearchLeaf,
    code_map_service: runtime::codemap::CodeMapService,
    apply_edits_service: runtime::apply_edits::ApplyEditsService,
    path_match_service: runtime::pathmatch::PathMatchScoreService,
    path_resolve_service: runtime::pathmatch::PathMatchResolveService,
    path_search_service: runtime::pathsearch::PathSearchFindService,
    token_accounting_service: runtime::tokenacct::TokenAccountingService,
    inventory_scope_registry: runtime::inventory_scope::ScopeRegistry,
    agent_claude_scope_registry: runtime::agent_claude::ScopeRegistry,
    config: CoreConfig,
    initialized: AtomicBool,
    panic_guard: Arc<PanicGuard>,
}

#[uniffi::export]
impl CoreRuntime {
    #[uniffi::constructor]
    pub fn new(config: CoreConfig) -> Result<Arc<Self>, CoreError> {
        // Belt-and-suspenders alongside `agentry_runtime::CoreRuntime::new`'s
        // own install call: that one covers every `PanicGuard`-wrapped export
        // on an already-constructed instance, but `Self::create` below still
        // does identity/config work (e.g. `RuntimeIdentity::fresh`) *before*
        // reaching the runtime crate's constructor. Installing here first
        // closes that narrow pre-construction window too. Idempotent (`Once`),
        // so calling it from both sites is free.
        runtime::install_panic_hook();
        match catch_unwind(AssertUnwindSafe(|| Self::create(config))) {
            Ok(result) => result.map(Arc::new),
            Err(_) => Err(CoreError::InternalPanic),
        }
    }

    pub fn initialize(&self) -> Result<CoreHandshake, CoreError> {
        self.guard(|| {
            if self.config.expected_abi_epoch != ABI_EPOCH
                || self.config.expected_build_fingerprint != CORE_BUILD_FINGERPRINT
                || self.config.expected_binding_checksum != BINDING_CHECKSUM
            {
                return Err(CoreError::IncompatibleAbi);
            }
            self.initialized.store(true, Ordering::Release);
            let identity = RuntimeIdentity::from(self.inner.identity());
            Ok(CoreHandshake {
                runtime_identity: identity,
                abi_epoch: ABI_EPOCH,
                payload_schema_versions: PAYLOAD_SCHEMA_VERSIONS.to_vec(),
                build_fingerprint: CORE_BUILD_FINGERPRINT.to_owned(),
                binding_checksum: BINDING_CHECKSUM.to_owned(),
            })
        })
    }

    pub fn execute(&self, command: CommandEnvelope) -> Result<AdmissionReceipt, CoreError> {
        self.guard(|| {
            self.require_initialized()?;
            let identity = self.validate_identity(&command.runtime_identity)?;
            Envelope::decode(&command.payload)?;
            let operation_id = command.operation_id.parse()?;
            let request = runtime::AdmissionRequest {
                operation_id: operation_id.clone(),
                fingerprint: command.request_fingerprint.parse()?,
                scope: command.scope_id.parse()?,
                deadline_unix_millis: command.deadline_unix_millis,
                runtime_identity: identity,
            };
            let outcome = self
                .inner
                .submit(request, async { runtime::TerminalOutcome::Success })?;
            let (disposition, state) = match outcome {
                runtime::AdmissionOutcome::Accepted => {
                    (AdmissionDisposition::Accepted, OperationState::Admitted)
                }
                runtime::AdmissionOutcome::Duplicate(state) => {
                    (AdmissionDisposition::Duplicate, state.into())
                }
            };
            Ok(AdmissionReceipt {
                runtime_identity: RuntimeIdentity::from(self.inner.identity()),
                operation_id: command.operation_id,
                disposition,
                state,
            })
        })
    }

    pub fn cancel_operation(
        &self,
        identity: RuntimeIdentity,
        operation_id: crate::types::OperationId,
    ) -> Result<CancelReceipt, CoreError> {
        self.guard(|| {
            self.require_initialized()?;
            let identity = self.validate_identity(&identity)?;
            let parsed_id = operation_id.parse()?;
            let disposition = self.inner.cancel(&identity, parsed_id)?.into();
            Ok(CancelReceipt {
                operation_id,
                disposition,
            })
        })
    }

    pub fn open_subscription(
        &self,
        scope: SubscriptionScope,
    ) -> Result<SubscriptionBootstrap, CoreError> {
        self.guard(|| {
            self.require_initialized()?;
            let identity = self.validate_identity(&scope.runtime_identity)?;
            let max_queued_events = if scope.max_queued_events == 0 {
                runtime::DEFAULT_MAX_QUEUED_EVENTS
            } else {
                usize::try_from(scope.max_queued_events).map_err(|_| CoreError::InvalidArgument)?
            };
            let max_queued_bytes = if scope.max_queued_bytes == 0 {
                runtime::DEFAULT_MAX_QUEUED_BYTES
            } else {
                usize::try_from(scope.max_queued_bytes).map_err(|_| CoreError::InvalidArgument)?
            };
            let bootstrap = self.inner.subscriptions().open_subscription(
                &identity,
                scope.scope_id.parse()?,
                runtime::SubscriptionConfig {
                    max_queued_events,
                    max_queued_bytes,
                    reserved_terminal_slots: runtime::RESERVED_TERMINAL_SLOTS,
                    reserved_terminal_control_bytes: runtime::RESERVED_TERMINAL_CONTROL_BYTES,
                },
                Vec::new,
            )?;
            Ok(SubscriptionBootstrap {
                subscription_id: SubscriptionId {
                    value: bootstrap.subscription_id.value(),
                    runtime_identity: RuntimeIdentity::from(&bootstrap.runtime_identity),
                },
                stream_id: bootstrap.stream_id.value(),
                initial_snapshot: bootstrap.initial_snapshot,
                next_delivery_cursor: bootstrap.next_delivery_cursor,
            })
        })
    }

    pub fn try_drain(
        &self,
        subscription_id: SubscriptionId,
        max_events: u32,
        max_bytes: u64,
    ) -> Result<DrainBatch, CoreError> {
        self.guard(|| {
            self.require_initialized()?;
            let identity = self.validate_identity(&subscription_id.runtime_identity)?;
            let id = runtime::SubscriptionId::from_value(subscription_id.value)
                .ok_or(CoreError::InvalidArgument)?;
            let max_events = usize::try_from(max_events).map_err(|_| CoreError::InvalidArgument)?;
            let max_bytes = usize::try_from(max_bytes).map_err(|_| CoreError::InvalidArgument)?;
            match self
                .inner
                .subscriptions()
                .try_drain(&identity, id, max_events, max_bytes)?
            {
                runtime::DrainOutcome::Batch(batch) => Ok(DrainBatch {
                    events: batch.events.into_iter().map(RuntimeEvent::from).collect(),
                    has_more: batch.has_more,
                    next_delivery_cursor: batch.next_delivery_cursor,
                    dropped_count: batch.dropped_count,
                    oversize: None,
                }),
                runtime::DrainOutcome::Oversize(oversize) => Ok(DrainBatch {
                    events: Vec::new(),
                    has_more: oversize.has_more,
                    next_delivery_cursor: oversize.next_delivery_cursor,
                    dropped_count: 0,
                    oversize: Some(OversizeEvent {
                        kind: oversize.kind.into(),
                        actual_bytes: u64::try_from(oversize.actual_bytes)
                            .map_err(|_| CoreError::InvalidArgument)?,
                        maximum_bytes: u64::try_from(oversize.maximum_bytes)
                            .map_err(|_| CoreError::InvalidArgument)?,
                        resnapshot_required: oversize.resnapshot_required,
                    }),
                }),
            }
        })
    }

    pub fn duplicate_wake_read_fd(&self, identity: RuntimeIdentity) -> Result<i32, CoreError> {
        self.guard(|| {
            self.require_initialized()?;
            let identity = self.validate_identity(&identity)?;
            let fd = self
                .inner
                .subscriptions()
                .duplicate_wake_read_fd(&identity)?;
            Ok(fd.into_raw_fd())
        })
    }

    pub fn rearm_wake(&self, identity: RuntimeIdentity) -> Result<bool, CoreError> {
        self.guard(|| {
            self.require_initialized()?;
            let identity = self.validate_identity(&identity)?;
            Ok(self.inner.subscriptions().rearm_and_recheck(&identity)?)
        })
    }

    pub fn respond_host_request(&self, response: HostResponse) -> Result<(), CoreError> {
        self.guard(|| {
            self.require_initialized()?;
            self.validate_identity(&response.runtime_identity)?;
            if response.request_id.is_empty() {
                return Err(CoreError::InvalidArgument);
            }
            let envelope = Envelope::decode(&response.payload)?;
            if envelope.payload_kind != PayloadKind::HostResponse {
                return Err(CoreError::InvalidArgument);
            }
            if self.inner.lifecycle() != runtime::LifecycleState::Running {
                return Err(CoreError::RuntimeStopped);
            }
            Ok(())
        })
    }

    pub fn close_subscription(&self, subscription_id: SubscriptionId) -> Result<(), CoreError> {
        self.guard(|| {
            self.require_initialized()?;
            let identity = self.validate_identity(&subscription_id.runtime_identity)?;
            if self.inner.lifecycle() != runtime::LifecycleState::Running {
                return Ok(());
            }
            let id = runtime::SubscriptionId::from_value(subscription_id.value)
                .ok_or(CoreError::InvalidArgument)?;
            let _ = self
                .inner
                .subscriptions()
                .close_subscription(&identity, id)?;
            Ok(())
        })
    }

    pub fn create_leaf_cancellation(
        &self,
        identity: RuntimeIdentity,
    ) -> Result<Arc<LeafCancellation>, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            Ok(Arc::new(LeafCancellation {
                inner: runtime::LeafCancellation::new(identity),
                runtime: Arc::downgrade(&self.inner),
                panic_guard: Arc::clone(&self.panic_guard),
            }))
        })
    }

    pub fn search_regex(
        &self,
        request: RegexSearchRequest,
    ) -> Result<RegexSearchResult, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            Ok(self
                .search_leaf
                .search_regex(&request.into_runtime_request())?
                .into())
        })
    }

    pub fn search_regex_batch(
        &self,
        request: RegexSearchBatchRequest,
    ) -> Result<Vec<RegexSearchResult>, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            let requests = request.into_runtime_requests();
            Ok(self
                .search_leaf
                .search_regex_batch(&requests)?
                .into_iter()
                .map(Into::into)
                .collect())
        })
    }

    pub fn search_regex_batch_compact_v1(
        &self,
        request: RegexSearchBatchRequest,
    ) -> Result<CompactRegexBatchResult, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            let requests = request.into_runtime_requests();
            Ok(self
                .search_leaf
                .search_regex_batch_compact(&requests)?
                .into())
        })
    }

    pub fn search_score_batch_v1(
        &self,
        request: CoreSearchScoreBatchRequestV1,
    ) -> Result<CoreSearchScoreBatchResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            if request.contract_version != runtime::searchscore::SEARCH_SCORE_CONTRACT_VERSION_V1 {
                return Err(CoreError::InvalidArgument);
            }

            let candidates: Vec<_> = request
                .candidates
                .iter()
                .map(|candidate| runtime::searchscore::Candidate {
                    name: &candidate.name,
                    path: &candidate.path,
                    name_lower: &candidate.name_lower,
                    path_lower: &candidate.path_lower,
                })
                .collect();
            let query = runtime::searchscore::Query {
                raw: &request.query.raw,
                lowered: &request.query.lowered,
                has_slash: request.query.has_slash,
                is_wildcard: request.query.is_wildcard,
            };
            let scores = runtime::searchscore::score_matches_batch(
                &candidates,
                query,
                request.fuzzy_threshold,
            );
            Ok(CoreSearchScoreBatchResultV1 { scores })
        })
    }

    pub fn text_decode_v1(
        &self,
        request: CoreTextDecodeRequestV1,
    ) -> Result<CoreTextDecodeResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            if request.contract_version != runtime::textdecode::TEXT_DECODE_CONTRACT_VERSION_V1 {
                return Err(CoreError::InvalidArgument);
            }
            Ok(runtime::textdecode::textdecode(&request.raw_bytes).into())
        })
    }

    pub fn workspace_document_projection_v1(
        &self,
        request: CoreWorkspaceDocumentProjectionRequestV1,
    ) -> Result<CoreWorkspaceDocumentProjectionV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            if request.contract_version
                != runtime::workspace_context::WORKSPACE_DOCUMENT_PROJECTION_CONTRACT_VERSION_V1
            {
                return Err(CoreError::InvalidArgument);
            }
            runtime::workspace_context::project_workspace_document_v1(&request.document_bytes)
                .map(Into::into)
                .map_err(|_| CoreError::InvalidArgument)
        })
    }

    pub fn workspace_command_identity_v1(
        &self,
        request: CoreWorkspaceCommandIdentityRequestV1,
    ) -> Result<CoreWorkspaceCommandIdentityResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            let result = runtime::workspace_persistence_journal::workspace_command_identity_v1(
                workspace_command_identity_request(request),
            );
            Ok(match result {
                Ok(identity) => CoreWorkspaceCommandIdentityResponseV1 {
                    identity: Some(identity.into()),
                    error_kind: None,
                    future_schema_version: None,
                },
                Err(error) => {
                    let (error_kind, future_schema_version) = workspace_journal_error(error);
                    CoreWorkspaceCommandIdentityResponseV1 {
                        identity: None,
                        error_kind: Some(error_kind),
                        future_schema_version,
                    }
                }
            })
        })
    }

    pub fn workspace_semantic_initial_recovery_prepare_v1(
        &self,
        request: CoreWorkspaceSemanticInitialRecoveryRequestV1,
    ) -> Result<CoreWorkspaceSemanticRecoveryPrepareResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            Ok(match runtime::workspace_persistence_journal::PreparedWorkspaceSemanticRecoveryV1::prepare_initial(
                &request.recovery.into(),
            ) {
                Ok(recovery) => CoreWorkspaceSemanticRecoveryPrepareResponseV1 {
                    recovery: Some(Arc::new(CorePreparedWorkspaceSemanticRecoveryV1 {
                        inner: Arc::new(recovery),
                        runtime: Arc::downgrade(&self.inner),
                        identity,
                        panic_guard: Arc::clone(&self.panic_guard),
                    })),
                    error_kind: None,
                    future_schema_version: None,
                },
                Err(error) => {
                    let (error_kind, future_schema_version) = workspace_journal_error(error);
                    CoreWorkspaceSemanticRecoveryPrepareResponseV1 {
                        recovery: None,
                        error_kind: Some(error_kind),
                        future_schema_version,
                    }
                }
            })
        })
    }

    pub fn workspace_working_journal_validate_v1(
        &self,
        request: CoreWorkspaceWorkingJournalValidationRequestV1,
    ) -> Result<CoreWorkspaceWorkingJournalValidationResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            if request.contract_version
                != runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1
            {
                return Err(CoreError::InvalidArgument);
            }
            use runtime::workspace_persistence_journal::WorkspaceWorkingJournalError as JournalError;
            Ok(match runtime::workspace_persistence_journal::validate_workspace_working_journal_v1(
                &request.journal_bytes,
            ) {
                Ok(validation) => CoreWorkspaceWorkingJournalValidationResponseV1 {
                    validation: Some(validation.into()),
                    error_kind: None,
                    future_schema_version: None,
                },
                Err(error) => {
                    let (error_kind, future_schema_version) = match error {
                        JournalError::InputTooLarge { .. } => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InputTooLarge,
                            None,
                        ),
                        JournalError::OutputTooLarge { .. } => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::OutputTooLarge,
                            None,
                        ),
                        JournalError::Malformed => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::Malformed,
                            None,
                        ),
                        JournalError::FutureSchema(version) => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::FutureSchema,
                            Some(version),
                        ),
                        JournalError::InvalidIdentity => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidIdentity,
                            None,
                        ),
                        JournalError::DuplicateCatalogIdentity => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::DuplicateCatalogIdentity,
                            None,
                        ),
                        JournalError::InvalidFileUrl => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidFileUrl,
                            None,
                        ),
                        JournalError::InvalidRevisionState => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidRevisionState,
                            None,
                        ),
                        JournalError::InvalidDigest => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidDigest,
                            None,
                        ),
                        JournalError::InvalidWorkingDocument => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidWorkingDocument,
                            None,
                        ),
                        JournalError::InvalidContextTable => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidContextTable,
                            None,
                        ),
                        JournalError::InvalidOperationLedger => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidOperationLedger,
                            None,
                        ),
                        JournalError::InvalidPendingSave => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidPendingSave,
                            None,
                        ),
                        JournalError::InvalidTimestamp => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidTimestamp,
                            None,
                        ),
                        JournalError::ExternalDocumentConflict => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::ExternalDocumentConflict,
                            None,
                        ),
                        JournalError::StaleRecoverySnapshot => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::StaleRecoverySnapshot,
                            None,
                        ),
                        JournalError::FullRecoveryRequired => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::FullRecoveryRequired,
                            None,
                        ),
                        JournalError::InvalidTransaction => (
                            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidTransaction,
                            None,
                        ),
                    };
                    CoreWorkspaceWorkingJournalValidationResponseV1 {
                        validation: None,
                        error_kind: Some(error_kind),
                        future_schema_version,
                    }
                }
            })
        })
    }

    pub fn workspace_working_journal_seed_v1(
        &self,
        request: CoreWorkspaceWorkingJournalSeedRequestV1,
    ) -> Result<CoreWorkspaceWorkingJournalValidationResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            if request.contract_version
                != runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1
            {
                return Err(CoreError::InvalidArgument);
            }
            Ok(match runtime::workspace_persistence_journal::seed_workspace_working_journal_v1(
                &request.seed_request_bytes,
            ) {
                Ok(validation) => CoreWorkspaceWorkingJournalValidationResponseV1 {
                    validation: Some(validation.into()),
                    error_kind: None,
                    future_schema_version: None,
                },
                Err(error) => {
                    let (error_kind, future_schema_version) = workspace_journal_error(error);
                    CoreWorkspaceWorkingJournalValidationResponseV1 {
                        validation: None,
                        error_kind: Some(error_kind),
                        future_schema_version,
                    }
                }
            })
        })
    }

    pub fn workspace_create_transaction_begin_v1(
        &self,
        request: CoreWorkspaceCreateTransactionRequestV1,
        command_claim: Option<Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    ) -> Result<CoreWorkspaceCreateTransactionBeginResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            if let Some(command_claim) = command_claim.as_ref() {
                command_claim.require_live_runtime()?;
                if command_claim.identity != identity {
                    return Err(CoreError::StaleRuntimeIdentity);
                }
            }
            Ok(
                match runtime::workspace_persistence_journal::prepare_workspace_create_transaction_v1(
                    request.raw_catalog_bytes.as_deref(),
                    &request.effective_catalog_bytes,
                    request.raw_journal_bytes.as_deref(),
                    request.effective_journal_bytes.as_deref(),
                    &request.request_bytes,
                    &request.document_bytes,
                )
                .and_then(|transaction| {
                    let reservation = bind_workspace_command_admission_finalization(
                        command_claim.as_ref(),
                        transaction.command_admission_finalization()?,
                    )?;
                    let authority_publication = command_claim
                        .as_ref()
                        .map(|claim| {
                            transaction.prepare_claimed_authority_publication(
                                &claim.admission,
                                &claim.inner,
                            )
                        })
                        .transpose()?;
                    Ok((transaction, reservation, authority_publication))
                }) {
                    Ok((transaction, reservation, authority_publication)) => CoreWorkspaceCreateTransactionBeginResponseV1 {
                        transaction: Some(Arc::new(CorePreparedWorkspaceCreateTransactionV1 {
                            inner: transaction,
                            terminal_gate: Mutex::new(()),
                            runtime: Arc::downgrade(&self.inner),
                            command_claim: command_claim.clone(),
                            admission_reservation: Mutex::new(reservation),
                            authority_publication: Mutex::new(authority_publication),
                            authority_publication_receipt: Mutex::new(None),
                            identity,
                            authority_permit_issued: AtomicBool::new(false),
                            authority_permit: Mutex::new(None),
                            panic_guard: Arc::clone(&self.panic_guard),
                        })),
                        error_kind: None,
                        future_schema_version: None,
                    },
                    Err(error) => {
                        let (error_kind, future_schema_version) = workspace_journal_error(error);
                        CoreWorkspaceCreateTransactionBeginResponseV1 {
                            transaction: None,
                            error_kind: Some(error_kind),
                            future_schema_version,
                        }
                    }
                },
            )
        })
    }

    pub fn workspace_delete_transaction_begin_v1(
        &self,
        request: CoreWorkspaceDeleteTransactionRequestV1,
        command_claim: Option<Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    ) -> Result<CoreWorkspaceDeleteTransactionBeginResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            if let Some(command_claim) = command_claim.as_ref() {
                command_claim.require_live_runtime()?;
                if command_claim.identity != identity {
                    return Err(CoreError::StaleRuntimeIdentity);
                }
            }
            Ok(
                match runtime::workspace_persistence_journal::prepare_workspace_delete_transaction_v1(
                    request.raw_catalog_bytes.as_deref(),
                    &request.effective_catalog_bytes,
                    &request.effective_journal_bytes,
                    &request.request_bytes,
                )
                .and_then(|transaction| {
                    let reservation = bind_workspace_command_admission_finalization(
                        command_claim.as_ref(),
                        Some(transaction.command_admission_finalization()?),
                    )?;
                    let authority_publication = command_claim
                        .as_ref()
                        .map(|claim| {
                            transaction.prepare_claimed_authority_publication(
                                &claim.admission,
                                &claim.inner,
                            )
                        })
                        .transpose()?;
                    Ok((transaction, reservation, authority_publication))
                }) {
                    Ok((transaction, reservation, authority_publication)) => CoreWorkspaceDeleteTransactionBeginResponseV1 {
                        transaction: Some(Arc::new(CorePreparedWorkspaceDeleteTransactionV1 {
                            inner: transaction,
                            terminal_gate: Mutex::new(()),
                            cleanup_finalization: Mutex::new(None),
                            runtime: Arc::downgrade(&self.inner),
                            command_claim: command_claim.clone(),
                            admission_reservation: Mutex::new(reservation),
                            authority_publication: Mutex::new(authority_publication),
                            authority_publication_receipt: Mutex::new(None),
                            identity,
                            authority_permit_issued: AtomicBool::new(false),
                            authority_permit: Mutex::new(None),
                            panic_guard: Arc::clone(&self.panic_guard),
                        })),
                        error_kind: None,
                        future_schema_version: None,
                    },
                    Err(error) => {
                        let (error_kind, future_schema_version) = workspace_journal_error(error);
                        CoreWorkspaceDeleteTransactionBeginResponseV1 {
                            transaction: None,
                            error_kind: Some(error_kind),
                            future_schema_version,
                        }
                    }
                },
            )
        })
    }

    pub fn workspace_journal_mutation_transaction_begin_v1(
        &self,
        request: CoreWorkspaceJournalMutationTransactionRequestV1,
        command_claim: Option<Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    ) -> Result<CoreWorkspaceJournalMutationTransactionBeginResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            if let Some(command_claim) = command_claim.as_ref() {
                command_claim.require_live_runtime()?;
                if command_claim.identity != identity {
                    return Err(CoreError::StaleRuntimeIdentity);
                }
            }
            Ok(match runtime::workspace_persistence_journal::prepare_workspace_journal_mutation_transaction_v1(
                request.raw_journal_bytes.as_deref(),
                &request.effective_journal_bytes,
                &request.request_bytes,
                &request.candidate_document_bytes,
                request.disk_document_bytes.as_deref(),
            )
            .and_then(|transaction| {
                let reservation = bind_workspace_command_admission_finalization(
                    command_claim.as_ref(),
                    transaction.command_admission_finalization()?,
                )?;
                let authority_publication = command_claim
                    .as_ref()
                    .map(|claim| {
                        transaction.prepare_claimed_authority_publication(
                            &claim.admission,
                            &claim.inner,
                        )
                    })
                    .transpose()?;
                Ok((transaction, reservation, authority_publication))
            }) {
                Ok((transaction, reservation, authority_publication)) => CoreWorkspaceJournalMutationTransactionBeginResponseV1 {
                    transaction: Some(Arc::new(
                        CorePreparedWorkspaceJournalMutationTransactionV1 {
                            inner: transaction,
                            terminal_gate: Mutex::new(()),
                            runtime: Arc::downgrade(&self.inner),
                            command_claim: command_claim.clone(),
                            identity,
                            authority_permit_issued: AtomicBool::new(false),
                            authority_permit: Mutex::new(None),
                            admission_reservation: Mutex::new(reservation),
                            authority_publication: Mutex::new(authority_publication),
                            authority_publication_receipt: Mutex::new(None),
                            panic_guard: Arc::clone(&self.panic_guard),
                        },
                    )),
                    error_kind: None,
                    future_schema_version: None,
                },
                Err(error) => {
                    let (error_kind, future_schema_version) = workspace_journal_error(error);
                    CoreWorkspaceJournalMutationTransactionBeginResponseV1 {
                        transaction: None,
                        error_kind: Some(error_kind),
                        future_schema_version,
                    }
                }
            })
        })
    }

    pub fn workspace_save_transaction_begin_v1(
        &self,
        request: CoreWorkspaceSaveTransactionRequestV1,
        command_claim: Option<Arc<CoreWorkspaceCommandExecutionClaimV1>>,
    ) -> Result<CoreWorkspaceSaveTransactionBeginResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            if let Some(command_claim) = command_claim.as_ref() {
                command_claim.require_live_runtime()?;
                if command_claim.identity != identity {
                    return Err(CoreError::StaleRuntimeIdentity);
                }
            }
            Ok(
                match runtime::workspace_persistence_journal::prepare_workspace_save_transaction_v1(
                    request.raw_journal_bytes.as_deref(),
                    &request.effective_journal_bytes,
                    &request.request_bytes,
                    &request.candidate_document_bytes,
                    request.disk_document_bytes.as_deref(),
                )
                .and_then(|transaction| {
                    let reservation = bind_workspace_command_admission_finalization(
                        command_claim.as_ref(),
                        Some(transaction.command_admission_finalization()?),
                    )?;
                    let authority_publication = command_claim
                        .as_ref()
                        .map(|claim| {
                            transaction.prepare_claimed_authority_publication(
                                &claim.admission,
                                &claim.inner,
                            )
                        })
                        .transpose()?;
                    Ok((transaction, reservation, authority_publication))
                }) {
                    Ok((transaction, reservation, authority_publication)) => {
                        CoreWorkspaceSaveTransactionBeginResponseV1 {
                            transaction: Some(Arc::new(CorePreparedWorkspaceSaveTransactionV1 {
                                inner: transaction,
                                terminal_gate: Mutex::new(()),
                                runtime: Arc::downgrade(&self.inner),
                                command_claim: command_claim.clone(),
                                admission_reservation: Mutex::new(reservation),
                                authority_publication: Mutex::new(authority_publication),
                                authority_publication_receipt: Mutex::new(None),
                                identity,
                                authority_permit_issued: AtomicBool::new(false),
                                authority_permit: Mutex::new(None),
                                panic_guard: Arc::clone(&self.panic_guard),
                            })),
                            error_kind: None,
                            future_schema_version: None,
                        }
                    }
                    Err(error) => {
                        let (error_kind, future_schema_version) = workspace_journal_error(error);
                        CoreWorkspaceSaveTransactionBeginResponseV1 {
                            transaction: None,
                            error_kind: Some(error_kind),
                            future_schema_version,
                        }
                    }
                },
            )
        })
    }

    pub fn workspace_pending_save_resolve_v1(
        &self,
        request: CoreWorkspacePendingSaveRecoveryRequestV1,
    ) -> Result<CoreWorkspacePendingSaveRecoveryResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            Ok(
                match runtime::workspace_persistence_journal::resolve_workspace_pending_save_v1(
                    &request.raw_journal_bytes,
                    &request.expected_workspace_id,
                    &request.expected_file_url,
                    request.document_bytes.as_deref(),
                ) {
                    Ok(recovery) => CoreWorkspacePendingSaveRecoveryResponseV1 {
                        recovery: Some(recovery.into()),
                        error_kind: None,
                        future_schema_version: None,
                    },
                    Err(error) => {
                        let (error_kind, future_schema_version) = workspace_journal_error(error);
                        CoreWorkspacePendingSaveRecoveryResponseV1 {
                            recovery: None,
                            error_kind: Some(error_kind),
                            future_schema_version,
                        }
                    }
                },
            )
        })
    }

    pub fn workspace_saved_revision_validate_v1(
        &self,
        request: CoreWorkspacePersistenceMetadataRequestV1,
    ) -> Result<CoreWorkspacePersistenceMetadataResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            Ok(workspace_metadata_response(
                runtime::workspace_persistence_journal::validate_workspace_saved_revision_record_v1(
                    &request.payload_bytes,
                ),
            ))
        })
    }

    pub fn workspace_deletion_tombstone_validate_v1(
        &self,
        request: CoreWorkspacePersistenceMetadataRequestV1,
    ) -> Result<CoreWorkspacePersistenceMetadataResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            Ok(workspace_metadata_response(
                runtime::workspace_persistence_journal::validate_workspace_deletion_tombstone_v1(
                    &request.payload_bytes,
                ),
            ))
        })
    }

    pub fn workspace_catalog_validate_v1(
        &self,
        request: CoreWorkspaceCatalogValidationRequestV1,
    ) -> Result<CoreWorkspaceCatalogResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            Ok(workspace_catalog_response(
                runtime::workspace_persistence_journal::validate_workspace_catalog_v1(
                    &request.catalog_bytes,
                ),
            ))
        })
    }

    pub fn workspace_catalog_seed_v1(
        &self,
        request: CoreWorkspaceCatalogSeedRequestV1,
    ) -> Result<CoreWorkspaceCatalogResponseV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            self.validate_identity(&request.runtime_identity)?;
            require_workspace_persistence_contract(request.contract_version)?;
            Ok(workspace_catalog_response(
                runtime::workspace_persistence_journal::seed_workspace_catalog_v1(
                    &request.seed_request_bytes,
                ),
            ))
        })
    }

    pub fn code_map_extract_batch_compact_v1(
        &self,
        request: CoreCodeMapBatchRequestV1,
    ) -> Result<CoreCompactCodeMapBatchResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            let cancellation = request.cancellation.runtime_handle().clone();
            Ok(self
                .code_map_service
                .build_batch_with_cancellation(request.into_runtime_request(), Some(&cancellation))?
                .into())
        })
    }

    pub fn apply_edits_batch_compact_v1(
        &self,
        request: CoreApplyEditsBatchRequestV1,
    ) -> Result<CoreCompactApplyEditsBatchResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            let cancellation = request.cancellation.runtime_handle().clone();
            Ok(self
                .apply_edits_service
                .apply_batch_with_cancellation(
                    request.into_runtime_request()?,
                    Some(&cancellation),
                )?
                .into())
        })
    }

    pub fn path_match_score_v1(
        &self,
        request: CorePathMatchScoreRequestV1,
    ) -> Result<CorePathMatchScoreResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            let cancellation = request.cancellation.runtime_handle().clone();
            Ok(self
                .path_match_service
                .compute_with_cancellation(&request.into_runtime_request(), Some(&cancellation))?
                .into())
        })
    }

    /// P3-3 slice-2a: batch entry for the full `PathMatcher.locate` resolution ladder
    /// (`PathMatchWorker.locateMany`'s serial loop over one shared, immutable snapshot).
    pub fn path_match_locate_many_v1(
        &self,
        request: CorePathMatchResolveRequestV1,
    ) -> Result<CorePathMatchResolveResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            let cancellation = request.cancellation.runtime_handle().clone();
            Ok(self
                .path_resolve_service
                .compute_with_cancellation(&request.into_runtime_request(), Some(&cancellation))?
                .into())
        })
    }

    /// P3-3 slice-2b phase 2: DIFFERENTIAL-ONLY batch entry driving `PathSearchFindService`
    /// (`agentry_runtime::pathsearch`) -- a whole corpus plus a batch of queries in ONE call,
    /// existing solely to drive a byte-exact Rust-vs-Swift(-vs-C) differential test. See
    /// `rust/crates/runtime/src/pathsearch/wire.rs`'s module doc: this is explicitly NOT the
    /// eventual production shape (which needs the P4 stateful scope-registry handle primitive).
    pub fn path_search_find_v1(
        &self,
        request: CorePathSearchFindRequestV1,
    ) -> Result<CorePathSearchFindResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            let cancellation = request.cancellation.runtime_handle().clone();
            Ok(self
                .path_search_service
                .compute_with_cancellation(&request.into_runtime_request(), Some(&cancellation))?
                .into())
        })
    }

    /// P3-4: DIFFERENTIAL-ONLY batch entry driving `TokenAccountingService`
    /// (`agentry_runtime::tokenacct`) -- a batch of entry rows plus a batch of
    /// component-breakdown rows in ONE call. See
    /// `rust/crates/runtime/src/tokenacct/wire.rs`'s module doc: this is explicitly NOT the
    /// eventual production shape.
    pub fn token_accounting_v1(
        &self,
        request: CoreTokenAccountingRequestV1,
    ) -> Result<CoreTokenAccountingResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            let cancellation = request.cancellation.runtime_handle().clone();
            Ok(self
                .token_accounting_service
                .compute_with_cancellation(&request.into_runtime_request(), Some(&cancellation))?
                .into())
        })
    }

    pub fn filter_paths(&self, request: PathFilterRequest) -> Result<PathFilterResult, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            Ok(self
                .search_leaf
                .filter_paths(&request.runtime_request())
                .into())
        })
    }

    pub fn folder_suffix_indices(
        &self,
        request: FolderSuffixRequest,
    ) -> Result<Vec<u32>, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            request
                .cancellation
                .validate_identity(&request.runtime_identity)?;
            if request.cancellation.runtime_handle().identity() != &identity
                || request.cancellation.runtime_handle().is_closed()
            {
                return Err(CoreError::StaleRuntimeIdentity);
            }
            Ok(self
                .search_leaf
                .folder_suffix_indices(&request.runtime_request()))
        })
    }

    // ============================================================================================
    // P4-4: `inventory-scope-v1` FFI surface (contract doc §5.3; design §11 P4-4). All calls are
    // synchronous and fast (control/bulk/ingest/read planes), matching every other export in this
    // file -- none traverse the P0 operation registry.
    // ============================================================================================

    pub fn inventory_open_scope(
        &self,
        identity: RuntimeIdentity,
        config: CoreInventoryScopeConfigV1,
    ) -> Result<InventoryScopeHandleV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self
                .inventory_scope_registry
                .open_scope(identity, config.runtime_config()?);
            // P4-4b: wire this scope's event-plane publication (contract doc §5b) into the same
            // `SubscriptionHub` every other P0 consumer already publishes into/subscribes from --
            // reused verbatim, not re-derived (see `InventoryScope`'s "event plane" section doc
            // comment for the lock-ordering rule this depends on, and `InventoryScopeHandleV1`'s
            // doc comment for why Swift receives the derived `ScopeId` here rather than computing
            // it itself).
            scope.attach_event_sink(
                std::sync::Arc::clone(self.inner.subscriptions()),
                scope.scope_id().to_subscription_scope_id(),
            );
            Ok(InventoryScopeHandleV1 {
                scope_id: scope.scope_id().to_string(),
                subscription_scope_id: scope.scope_id().to_subscription_scope_id().to_string(),
            })
        })
    }

    pub fn inventory_close_scope(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
    ) -> Result<(), CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope_id = parse_inventory_scope_id(&scope_id)?;
            self.inventory_scope_registry
                .close_scope(&identity, scope_id)?;
            Ok(())
        })
    }

    pub fn inventory_open_root(
        &self,
        request: InventoryRootOpenV1,
    ) -> Result<InventoryRootLifetimeV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            let scope = self.inventory_scope(&request.scope_id)?;
            let root_id = parse_root_id(&request.root_id)?;
            let lifetime = scope.open_root(
                &identity,
                root_id,
                request.name,
                request.standardized_full_path,
            )?;
            Ok(InventoryRootLifetimeV1 {
                root_id: request.root_id,
                root_lifetime_id: lifetime.to_string(),
            })
        })
    }

    pub fn inventory_close_root(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        root_id: Vec<u8>,
        root_lifetime_id: String,
    ) -> Result<InventoryRootUnloadReceiptV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let parsed_root_id = parse_root_id(&root_id)?;
            let lifetime = parse_root_lifetime_id(&root_lifetime_id)?;
            let receipt = scope.close_root(&identity, parsed_root_id, lifetime)?;
            Ok(InventoryRootUnloadReceiptV1 {
                root_id,
                root_lifetime_id,
                final_generation: receipt.final_generation,
            })
        })
    }

    /// P4-6b gap-closure: production promotion of `InventoryScope::set_file_managed_only` --
    /// see that method's doc comment. Loose params (matches `inventory_lookup_paths`'s shape);
    /// `file_id`/`root_id` reuse `parse_root_id`'s generic 16-byte parser.
    pub fn inventory_set_file_managed_only(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        root_id: Vec<u8>,
        file_id: Vec<u8>,
        managed_only: bool,
    ) -> Result<(), CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let root_id = parse_root_id(&root_id)?;
            let file_id = parse_root_id(&file_id)?;
            scope.set_file_managed_only(&identity, root_id, file_id, managed_only)?;
            Ok(())
        })
    }

    /// See `inventory_set_file_managed_only`'s doc comment; the folder counterpart.
    pub fn inventory_set_folder_managed_only(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        root_id: Vec<u8>,
        folder_id: Vec<u8>,
        managed_only: bool,
    ) -> Result<(), CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let root_id = parse_root_id(&root_id)?;
            let folder_id = parse_root_id(&folder_id)?;
            scope.set_folder_managed_only(&identity, root_id, folder_id, managed_only)?;
            Ok(())
        })
    }

    pub fn inventory_scope_diagnostics(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
    ) -> Result<InventoryDiagnosticsV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            Ok(scope.diagnostics(&identity)?.into())
        })
    }

    pub fn inventory_begin_bulk_load(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        root_id: Vec<u8>,
        root_lifetime_id: String,
    ) -> Result<u64, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let root_id = parse_root_id(&root_id)?;
            let lifetime = parse_root_lifetime_id(&root_lifetime_id)?;
            let bulk_load_id = scope.begin_bulk_load(&identity, root_id, lifetime)?;
            Ok(bulk_load_id.raw())
        })
    }

    pub fn inventory_push_bulk_chunk(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        bulk_load_id: u64,
        root_id: Vec<u8>,
        bytes: Vec<u8>,
    ) -> Result<BulkChunkReceiptV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let root_id = parse_root_id(&root_id)?;
            let (files, folders) =
                runtime::inventory_scope::decode_bulk_chunk(&bytes).map_err(wire_error)?;
            let files_staged = files.len() as u64;
            let folders_staged = folders.len() as u64;
            scope.push_bulk_chunk(
                &identity,
                runtime::inventory_scope::BulkLoadId::from_raw(bulk_load_id),
                root_id,
                files,
                folders,
            )?;
            Ok(BulkChunkReceiptV1 {
                files_staged,
                folders_staged,
            })
        })
    }

    /// Discovery-path counterpart to [`Self::inventory_push_bulk_chunk`] (§4.1.1): `bytes` is the
    /// compact discovery bulk-chunk blob (id-less records) --
    /// `runtime::inventory_scope::decode_discovery_bulk_chunk`. Mints an id for each decoded
    /// record and stages it through the *exact same* `InventoryScope::push_bulk_chunk` the
    /// id-supplied path uses; the receipt echoes the minted ids in input order.
    pub fn inventory_push_bulk_chunk_discovery(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        bulk_load_id: u64,
        root_id: Vec<u8>,
        bytes: Vec<u8>,
    ) -> Result<BulkChunkDiscoveryReceiptV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let root_id = parse_root_id(&root_id)?;
            let (files, folders) = runtime::inventory_scope::decode_discovery_bulk_chunk(&bytes)
                .map_err(wire_error)?;
            let files_staged = files.len() as u64;
            let folders_staged = folders.len() as u64;
            let receipt = scope.push_bulk_chunk_discovery(
                &identity,
                runtime::inventory_scope::BulkLoadId::from_raw(bulk_load_id),
                root_id,
                files,
                folders,
            )?;
            Ok(BulkChunkDiscoveryReceiptV1 {
                files_staged,
                folders_staged,
                minted_file_ids: receipt
                    .minted_file_ids
                    .iter()
                    .map(|id| id.to_vec())
                    .collect(),
                minted_folder_ids: receipt
                    .minted_folder_ids
                    .iter()
                    .map(|id| id.to_vec())
                    .collect(),
            })
        })
    }

    pub fn inventory_commit_bulk_load(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        bulk_load_id: u64,
        _publish_mode: InventoryPublishModeV1,
    ) -> Result<InventoryGenerationReceiptV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let receipt = scope.commit_bulk_load(
                &identity,
                runtime::inventory_scope::BulkLoadId::from_raw(bulk_load_id),
                runtime::inventory_scope::InventoryPublishMode::AtomicPublish,
            )?;
            Ok(InventoryGenerationReceiptV1 {
                root_id: receipt.root_id.to_vec(),
                generation: receipt.generation,
                root_lifetime_id: receipt.token.root_lifetime().to_string(),
            })
        })
    }

    pub fn inventory_abort_bulk_load(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        bulk_load_id: u64,
    ) -> Result<(), CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            scope.abort_bulk_load(
                &identity,
                runtime::inventory_scope::BulkLoadId::from_raw(bulk_load_id),
            )?;
            Ok(())
        })
    }

    pub fn inventory_apply_delta_v1(
        &self,
        command: InventoryDeltaCommandV1,
    ) -> Result<InventoryDeltaReceiptV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&command.runtime_identity)?;
            let scope = self.inventory_scope(&command.scope_id)?;
            let root_id = parse_root_id(&command.root_id)?;
            let root_lifetime_id = parse_root_lifetime_id(&command.root_lifetime_id)?;
            let event = runtime::inventory_scope::decode_delta_event(&command.event_bytes)
                .map_err(wire_error)?;
            let runtime_command = runtime::inventory_scope::InventoryDeltaCommand {
                scope_id: scope.scope_id(),
                root_id,
                root_lifetime_id,
                watcher_accepted_watermark: command.watcher_accepted_watermark,
                requires_full_resync: command.requires_full_resync,
                expected_applied_index_generation: command.expected_applied_index_generation,
                source: command.source,
                event,
            };
            Ok(scope.apply_delta(&identity, runtime_command).into())
        })
    }

    /// Discovery-path counterpart to [`Self::inventory_apply_delta_v1`] (§4.1.1):
    /// `command.event_bytes` is the compact discovery delta blob (id-less upserts) --
    /// `runtime::inventory_scope::decode_discovery_delta_event`. Mints an id for each upserted
    /// record and applies the equivalent fully-formed delta through the *exact same* gate/patch/
    /// rebuild path `inventory_apply_delta_v1` uses; the receipt echoes the minted ids in
    /// `upserted_files`/`upserted_folders` order.
    pub fn inventory_apply_delta_discovery_v1(
        &self,
        command: InventoryDeltaDiscoveryCommandV1,
    ) -> Result<InventoryDeltaDiscoveryReceiptV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&command.runtime_identity)?;
            let scope = self.inventory_scope(&command.scope_id)?;
            let root_id = parse_root_id(&command.root_id)?;
            let root_lifetime_id = parse_root_lifetime_id(&command.root_lifetime_id)?;
            let event =
                runtime::inventory_scope::decode_discovery_delta_event(&command.event_bytes)
                    .map_err(wire_error)?;
            let runtime_command = runtime::inventory_scope::InventoryDeltaDiscoveryCommand {
                scope_id: scope.scope_id(),
                root_id,
                root_lifetime_id,
                watcher_accepted_watermark: command.watcher_accepted_watermark,
                requires_full_resync: command.requires_full_resync,
                expected_applied_index_generation: command.expected_applied_index_generation,
                source: command.source,
                event,
            };
            Ok(scope
                .apply_delta_discovery(&identity, runtime_command)
                .into())
        })
    }

    pub fn inventory_open_snapshot(
        &self,
        request: InventorySnapshotRequestV1,
    ) -> Result<InventorySnapshotHandleV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            let scope = self.inventory_scope(&request.scope_id)?;
            let root_id = parse_root_id(&request.root_id)?;
            let handle_id = scope.open_snapshot(&identity, root_id, "ffi")?;
            match scope.read_snapshot(handle_id) {
                runtime::inventory_scope::HandleReadOutcome::Open { generation } => {
                    Ok(InventorySnapshotHandleV1 {
                        handle_id: handle_id.raw(),
                        generation: generation.generation,
                        root_lifetime_id: generation.root_lifetime.to_string(),
                    })
                }
                runtime::inventory_scope::HandleReadOutcome::HandleInvalidated { reason } => {
                    Err(handle_invalidated(reason))
                }
            }
        })
    }

    pub fn inventory_snapshot_page(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        handle_id: u64,
        offset: u64,
        limit: u64,
    ) -> Result<CompactInventoryPageV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let offset = usize::try_from(offset).map_err(|_| CoreError::InvalidArgument)?;
            let limit = usize::try_from(limit).map_err(|_| CoreError::InvalidArgument)?;
            let handle_id = runtime::inventory_scope::SnapshotHandleId::from_raw(handle_id);
            // `snapshot_page` implicitly validates identity via the handle's owning scope having
            // already been identity-checked at open time; no separate per-call identity token is
            // threaded through the handle itself (matches the read plane's existing shape).
            let _ = &identity;
            match scope.snapshot_page(handle_id, offset, limit) {
                Ok(page) => {
                    // `SnapshotPage` applies one offset/limit window independently to files and
                    // folders. Advance by the larger returned list and keep paging while either
                    // list fills the window; computing this from files alone truncates a root
                    // whose folder table is longer than its file table.
                    let returned_count = page.files.len().max(page.folders.len()) as u64;
                    let has_more = returned_count == limit as u64 && limit > 0;
                    Ok(CompactInventoryPageV1 {
                        bytes: runtime::inventory_scope::encode_bulk_chunk(
                            &page.files,
                            &page.folders,
                        ),
                        returned_count,
                        has_more,
                    })
                }
                Err(reason) => Err(handle_invalidated(reason)),
            }
        })
    }

    pub fn inventory_close_snapshot(
        &self,
        scope_id: String,
        handle_id: u64,
    ) -> Result<(), CoreError> {
        self.guard(|| {
            self.require_running()?;
            let scope = self.inventory_scope(&scope_id)?;
            scope.close_snapshot(runtime::inventory_scope::SnapshotHandleId::from_raw(
                handle_id,
            ));
            Ok(())
        })
    }

    /// Opens one immutable stateful composition from exact root lifetime/generation descriptors.
    /// No file, folder, entry, or shard table crosses back into Rust on this control call.
    pub fn inventory_open_composed_snapshot(
        &self,
        request: InventoryComposedSnapshotRequestV1,
    ) -> Result<InventoryComposedSnapshotHandleV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            let scope = self.inventory_scope(&request.scope_id)?;
            let descriptors = request
                .roots
                .into_iter()
                .map(|descriptor| {
                    Ok(runtime::inventory_scope::ComposedRootDescriptor {
                        root_id: parse_root_id(&descriptor.root_id)?,
                        expected_root_lifetime: parse_root_lifetime_id(
                            &descriptor.root_lifetime_id,
                        )?,
                        expected_generation: descriptor.expected_generation,
                    })
                })
                .collect::<Result<Vec<_>, CoreError>>()?;
            let (handle_id, row_count) = scope.open_composed_snapshot_with_row_count(
                &identity,
                descriptors,
                request.accounting.into(),
                "ffi-composed",
            )?;
            Ok(InventoryComposedSnapshotHandleV1 {
                handle_id: handle_id.raw(),
                row_count: u64::try_from(row_count).unwrap_or(u64::MAX),
            })
        })
    }

    /// Pages one aligned composed artifact. The compact bulk-chunk carrier is reused with an empty
    /// folder section; Swift derives presentation entries from these bounded file rows plus its
    /// small root dictionary.
    pub fn inventory_composed_snapshot_page(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        handle_id: u64,
        offset: u64,
        limit: u64,
    ) -> Result<CompactInventoryPageV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let _ = &identity;
            let offset = usize::try_from(offset).map_err(|_| CoreError::InvalidArgument)?;
            let limit = usize::try_from(limit).map_err(|_| CoreError::InvalidArgument)?;
            let handle_id = runtime::inventory_scope::ComposedSnapshotHandleId::from_raw(handle_id);
            match scope.read_composed_snapshot(handle_id) {
                runtime::inventory_scope::ComposedHandleReadOutcome::Open { artifact } => {
                    let page = artifact.page(offset, limit);
                    if page.files.len() != page.entries.len() {
                        return Err(CoreError::InventoryScopeInvalidRequest {
                            message: "inventory composed page violated row alignment".to_owned(),
                        });
                    }
                    let returned_count = u64::try_from(page.files.len()).unwrap_or(u64::MAX);
                    let has_more = offset.saturating_add(page.files.len()) < artifact.len();
                    Ok(CompactInventoryPageV1 {
                        bytes: runtime::inventory_scope::encode_bulk_chunk(&page.files, &[]),
                        returned_count,
                        has_more,
                    })
                }
                runtime::inventory_scope::ComposedHandleReadOutcome::HandleInvalidated {
                    reason,
                } => Err(handle_invalidated(reason)),
            }
        })
    }

    pub fn inventory_close_composed_snapshot(
        &self,
        scope_id: String,
        handle_id: u64,
    ) -> Result<(), CoreError> {
        self.guard(|| {
            self.require_running()?;
            let scope = self.inventory_scope(&scope_id)?;
            scope.close_composed_snapshot(
                runtime::inventory_scope::ComposedSnapshotHandleId::from_raw(handle_id),
            );
            Ok(())
        })
    }

    pub fn inventory_lookup_paths(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        handle_id: u64,
        bytes: Vec<u8>,
    ) -> Result<CompactLookupResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let paths =
                runtime::inventory_scope::decode_lookup_request(&bytes).map_err(wire_error)?;
            let handle_id = runtime::inventory_scope::SnapshotHandleId::from_raw(handle_id);
            match scope.lookup_paths(&identity, handle_id, &paths)? {
                runtime::inventory_scope::LookupPathsOutcome::Facts {
                    generation,
                    root_lifetime,
                    rows,
                } => {
                    let (root_lifetime_hi, root_lifetime_lo) =
                        runtime::inventory_scope::uuid_to_words(root_lifetime.as_bytes());
                    Ok(CompactLookupResultV1 {
                        bytes: runtime::inventory_scope::encode_fact_block(
                            &runtime::inventory_scope::FactBlock {
                                generation,
                                root_lifetime_hi,
                                root_lifetime_lo,
                                rows,
                            },
                        ),
                    })
                }
                runtime::inventory_scope::LookupPathsOutcome::HandleInvalidated { reason } => {
                    Err(handle_invalidated(reason))
                }
            }
        })
    }

    pub fn inventory_query(
        &self,
        request: CompactQueryV1,
    ) -> Result<CompactQueryResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            let scope = self.inventory_scope(&request.scope_id)?;
            let decoded = runtime::inventory_scope::decode_query_request(&request.bytes)
                .map_err(wire_error)?;
            let haystack_variant =
                runtime::inventory_scope::QueryHaystackVariant::from_wire(decoded.haystack_variant)
                    .ok_or_else(|| CoreError::InventoryScopeInvalidRequest {
                        message: "unknown haystack variant".to_owned(),
                    })?;
            let query_request = runtime::inventory_scope::InventoryQueryRequest {
                pattern: decoded.pattern,
                limit: usize::try_from(decoded.limit).map_err(|_| CoreError::InvalidArgument)?,
                haystack_variant,
                prefix: runtime::inventory_scope::QueryPrefix {
                    non_empty_relative_prefix: decoded.non_empty_relative_prefix,
                    empty_relative_path_value: decoded.empty_relative_path_value,
                },
                // P4-7a phase a3: the wire's `logical_prefix` presence flag disambiguates "no
                // binding projection" from "a projection whose non-empty-relative prefix is
                // legitimately empty" -- see wire.rs's decode doc comment.
                logical_prefix: decoded.logical_prefix.map(
                    |(non_empty_relative_prefix, empty_relative_path_value)| {
                        runtime::inventory_scope::QueryPrefix {
                            non_empty_relative_prefix,
                            empty_relative_path_value,
                        }
                    },
                ),
            };
            let handle_id = runtime::inventory_scope::SnapshotHandleId::from_raw(request.handle_id);
            match scope.query(&identity, handle_id, query_request)? {
                runtime::inventory_scope::QueryReadOutcome::Open(result) => {
                    let candidates: Vec<runtime::inventory_scope::QueryCandidateRow> = result
                        .candidates
                        .into_iter()
                        .map(|candidate| runtime::inventory_scope::QueryCandidateRow {
                            id: candidate.entry.id,
                            root_id: candidate.entry.root_id,
                            name: candidate.entry.name,
                            relative_path: candidate.entry.relative_path,
                            standardized_relative_path: candidate.entry.standardized_relative_path,
                            full_path: candidate.entry.full_path,
                            standardized_full_path: candidate.entry.standardized_full_path,
                            display_path: candidate.display_path,
                            tie_break_key: candidate.tie_break_key,
                            score: candidate.score,
                        })
                        .collect();
                    Ok(CompactQueryResultV1 {
                        bytes: runtime::inventory_scope::encode_query_response(
                            Some(result.generation),
                            &candidates,
                        ),
                    })
                }
                runtime::inventory_scope::QueryReadOutcome::HandleInvalidated { reason } => {
                    Err(handle_invalidated(reason))
                }
            }
        })
    }

    pub fn inventory_resolve_records(
        &self,
        request: InventoryResolveRequestV1,
    ) -> Result<CompactRecordBlockV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            let scope = self.inventory_scope(&request.scope_id)?;
            let root_id = parse_root_id(&request.root_id)?;
            let (file_ids, folder_ids) =
                runtime::inventory_scope::decode_resolve_request(&request.bytes)
                    .map_err(wire_error)?;
            let (generation, root_lifetime, rows) = scope.resolve_records(
                &identity,
                root_id,
                request.expected_catalog_generation,
                &file_ids,
                &folder_ids,
            )?;
            let (root_lifetime_hi, root_lifetime_lo) =
                runtime::inventory_scope::uuid_to_words(root_lifetime.as_bytes());
            Ok(CompactRecordBlockV1 {
                bytes: runtime::inventory_scope::encode_fact_block(
                    &runtime::inventory_scope::FactBlock {
                        generation,
                        root_lifetime_hi,
                        root_lifetime_lo,
                        rows,
                    },
                ),
            })
        })
    }

    /// P4-6b prep-4 gap-closure: `InventoryScope::resolve_records_scope_wide`'s FFI export --
    /// see that method's doc comment for why an id-keyed, root-less resolve exists at all. Reuses
    /// `decode_resolve_request`/`encode_fact_block` byte-for-byte (the request/response shapes
    /// never carried root_id in their own bytes -- it was always a separate FFI parameter, which
    /// this export simply omits). Block-level `generation`/`root_lifetime` are meaningless across
    /// roots and are `Some(0)`/zeroed rather than `None`, so decoders must not mistake this for
    /// the single-root "whole-block stale" signal -- callers use only each row's own `root_id`.
    pub fn inventory_resolve_records_scope_wide(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        bytes: Vec<u8>,
    ) -> Result<CompactRecordBlockV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.inventory_scope(&scope_id)?;
            let (file_ids, folder_ids) =
                runtime::inventory_scope::decode_resolve_request(&bytes).map_err(wire_error)?;
            let rows = scope.resolve_records_scope_wide(&identity, &file_ids, &folder_ids)?;
            Ok(CompactRecordBlockV1 {
                bytes: runtime::inventory_scope::encode_fact_block(
                    &runtime::inventory_scope::FactBlock {
                        generation: Some(0),
                        root_lifetime_hi: 0,
                        root_lifetime_lo: 0,
                        rows,
                    },
                ),
            })
        })
    }

    pub fn inventory_open_projected_shard(
        &self,
        request: InventoryProjectedShardRequestV1,
    ) -> Result<InventorySnapshotHandleV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            let scope = self.inventory_scope(&request.scope_id)?;
            let root_id = parse_root_id(&request.root_id)?;
            let handle_id =
                scope.open_projected_shard(&identity, root_id, "ffi-projected-shard")?;
            match scope.read_snapshot(handle_id) {
                runtime::inventory_scope::HandleReadOutcome::Open { generation } => {
                    Ok(InventorySnapshotHandleV1 {
                        handle_id: handle_id.raw(),
                        generation: generation.generation,
                        root_lifetime_id: generation.root_lifetime.to_string(),
                    })
                }
                runtime::inventory_scope::HandleReadOutcome::HandleInvalidated { reason } => {
                    Err(handle_invalidated(reason))
                }
            }
        })
    }

    pub fn begin_shutdown(&self, identity: RuntimeIdentity) -> Result<ShutdownReceipt, CoreError> {
        self.guard(|| {
            self.require_initialized()?;
            let identity = self.validate_identity(&identity)?;
            let receipt = self.inner.begin_shutdown(&identity)?;
            Ok(ShutdownReceipt {
                already_started: receipt.already_started,
                cancelled_operations: u64::try_from(receipt.cancelled_operations)
                    .map_err(|_| CoreError::InvalidArgument)?,
            })
        })
    }

    /// Instance-scoped sibling of the module-level `core_panic_forensics`,
    /// kept for callers that already hold a `CoreRuntime` and would rather
    /// not thread a second top-level import through. Same data, same "not
    /// routed through `self.guard()`" reasoning -- see `core_panic_forensics`
    /// for the full explanation.
    pub fn panic_forensics(&self) -> Vec<String> {
        core_panic_forensics()
    }

    // ============================================================================================
    // P6-6: agent-claude-v1 FFI surface (`docs/architecture/rust-agent-claude-v1.md`,
    // `docs/designs/p6-claude-vertical-2026-08-23.md` §11 P6-6). Synchronous and fast throughout
    // (charter §8.2): commands admit work and return a receipt; results (including the five-
    // outcome interrupt contract, §5.3) arrive as events on the reused generic subscription surface
    // (`openSubscription`/`tryDrain`, unchanged) -- no per-domain subscribe export, same precedent
    // as `inventory-scope-v1`.
    // ============================================================================================

    pub fn agent_open_scope(
        &self,
        identity: RuntimeIdentity,
        config: CoreAgentClaudeScopeConfigV1,
    ) -> Result<AgentClaudeScopeHandleV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self
                .agent_claude_scope_registry
                .open_scope(identity, config.runtime_config());
            // Wires this scope's event-plane publication into the same `SubscriptionHub` every
            // other P0/P4 consumer already publishes into -- reused verbatim, not re-derived (see
            // `AgentClaudeScope::attach_event_sink`'s doc comment, mirroring
            // `InventoryScope::attach_event_sink` exactly).
            scope.attach_event_sink(
                std::sync::Arc::clone(self.inner.subscriptions()),
                scope.scope_id().to_subscription_scope_id(),
            );
            Ok(AgentClaudeScopeHandleV1 {
                scope_id: scope.scope_id().to_string(),
                subscription_scope_id: scope.scope_id().to_subscription_scope_id().to_string(),
            })
        })
    }

    /// Contract §5.1: spawns the child, registers it with the shared reaper, and starts the
    /// per-stream reader threads. Returns `pid`/`process_group_id` synchronously so the caller's
    /// expected-agent-PID fence (design §4.6) can register immediately on return.
    pub fn agent_start_or_resume(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        resume_session_id: Option<String>,
        model: Option<String>,
        effort_level: Option<String>,
    ) -> Result<AgentClaudeStartReceiptV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.agent_claude_scope(&scope_id)?;
            let receipt =
                scope.start_or_resume(&identity, resume_session_id, model, effort_level)?;
            Ok(AgentClaudeStartReceiptV1 {
                pid: receipt.pid,
                process_group_id: receipt.process_group_id,
            })
        })
    }

    /// Returns the newly minted `turn_generation` (contract §4's interrupt-fencing token).
    pub fn agent_send_user_message(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        text: String,
    ) -> Result<u64, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.agent_claude_scope(&scope_id)?;
            Ok(scope.send_user_message(&identity, &text)?)
        })
    }

    /// Contract §4: fenced by `turn_generation`, no pre-check (design §5.3 -- the pre-check is
    /// *removed*, not made remote). Fast: the generation/in-flight classification runs
    /// synchronously; only a genuine ACK round trip (when the named generation is current and a
    /// turn is in flight) is pushed onto a background thread inside the scope.
    pub fn agent_interrupt_turn(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        turn_generation: u64,
        reason: String,
    ) -> Result<AgentClaudeInterruptReceiptV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.agent_claude_scope(&scope_id)?;
            let request_id = scope.interrupt_turn(&identity, turn_generation, reason)?;
            Ok(AgentClaudeInterruptReceiptV1 { request_id })
        })
    }

    /// Contract §7.1's permission **protocol** half only -- policy (auto-approval matching,
    /// secure-store decisions) stays Swift/core-owned; this call only encodes and writes the
    /// caller's already-decided outcome back to the CLI.
    pub fn agent_respond_permission(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        request_id: String,
        decision: AgentClaudePermissionDecisionV1,
    ) -> Result<(), CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.agent_claude_scope(&scope_id)?;
            scope.respond_permission(&identity, &request_id, decision.into())?;
            Ok(())
        })
    }

    /// P6-7: real ACK tracking, replacing the P6-6 fire-and-forget placeholder. Fast: identity/
    /// closed checks and request construction run synchronously; only the genuine ACK round trip
    /// is pushed onto a background thread inside the scope. The outcome arrives later as a
    /// `flagSettingsApplied` terminal-class event on the subscription, correlated by this same
    /// `request_id` -- charter §8.2's command+event shape, mirroring `agent_interrupt_turn` exactly.
    pub fn agent_apply_model_and_effort(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
        model: Option<String>,
        effort: Option<String>,
        disposition: AgentClaudeFlagSettingsDispositionV1,
    ) -> Result<AgentClaudeFlagSettingsReceiptV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let scope = self.agent_claude_scope(&scope_id)?;
            let request_id =
                scope.apply_model_and_effort(&identity, model, effort, disposition.into())?;
            Ok(AgentClaudeFlagSettingsReceiptV1 { request_id })
        })
    }

    /// Idempotent: flushes deferred turn completions, escalates SIGTERM -> grace -> SIGKILL against
    /// the process group via the shared reaper, then removes the scope from the registry. There is
    /// no separate `agent_close_scope` export -- shutdown and close are one terminal operation for
    /// this domain (design's seven-export enumeration), unlike `inventory-scope-v1`'s separate
    /// open/close pair.
    pub fn agent_shutdown(
        &self,
        identity: RuntimeIdentity,
        scope_id: String,
    ) -> Result<(), CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&identity)?;
            let parsed_scope_id = crate::types::parse_agent_claude_scope_id(&scope_id)?;
            self.agent_claude_scope_registry
                .close_scope(&identity, parsed_scope_id)?;
            Ok(())
        })
    }
}

/// Module-level (not tied to any `CoreRuntime` instance) panic forensics for
/// the last (up to a few) panics recorded anywhere in this process, most-
/// recent last. This is the primary forensics entry point: `CoreRuntime::new`
/// (the `#[uniffi::constructor]` above) can itself panic during
/// `Self::create` -- before any `CoreRuntime` object exists for a caller to
/// call an instance method on -- so a free function is what makes *that*
/// failure recoverable too, not just a poisoned-after-construction instance.
/// Deliberately NOT routed through any `PanicGuard`: once poisoned,
/// `PanicGuard::call` short-circuits every other export with
/// `RuntimePoisoned` before running the operation, so a guarded forensics
/// accessor could never be read after the exact failure it exists to
/// explain. The backing ring buffer (`agentry_runtime::recent_panics`) is
/// process-wide, filled by the panic hook installed once per process (see
/// both call sites of `install_panic_hook`).
#[uniffi::export]
pub fn core_panic_forensics() -> Vec<String> {
    runtime::recent_panics()
        .iter()
        .map(runtime::PanicRecord::describe)
        .collect()
}

/// Module-level (not tied to any `CoreRuntime` instance) drain of the
/// process-wide WARN/ERROR diagnostics ring buffer -- see
/// `agentry_runtime::observability` for the full rationale (rewrite charter
/// §11.7's tracing/os_log bridge, deliberately callback-free and not built
/// on the `tracing` crate). Mirrors `core_panic_forensics` in every
/// structural respect: a free function so it is readable with no live
/// `CoreRuntime` object, and deliberately NOT routed through `PanicGuard`,
/// since diagnostics recorded on the way to a poisoning are exactly the
/// ones a poisoned runtime must still be able to answer.
///
/// Destructive: each call drains (removes) the buffered events, so the
/// Swift caller decides its own drain cadence and never sees the same event
/// twice -- charter §9.5's pull-based, no-payload-callback drain shape,
/// applied to this smaller diagnostics ring rather than the main
/// subscription event queue.
#[uniffi::export]
pub fn core_diagnostics_drain() -> Vec<String> {
    runtime::drain_diagnostics()
        .iter()
        .map(runtime::DiagnosticRecord::describe)
        .collect()
}

/// Maps a P4-4 handle-based read's business-outcome invalidation into the thrown `CoreError`
/// channel (contract doc §4 layer 3): the contract's own pseudocode declares these reads
/// `throws`, and UniFFI's typed-error mechanism is exactly the "business outcome, not a panic"
/// modeling this reason wants -- see `InventoryHandleInvalidationReasonV1`'s doc comment in
/// `types.rs`.
fn require_workspace_persistence_contract(contract_version: u16) -> Result<(), CoreError> {
    if contract_version
        == runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1
    {
        Ok(())
    } else {
        Err(CoreError::InvalidArgument)
    }
}

fn workspace_catalog_response(
    result: Result<
        runtime::workspace_persistence_journal::WorkspaceCatalogValidationV1,
        runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
    >,
) -> CoreWorkspaceCatalogResponseV1 {
    match result {
        Ok(validation) => CoreWorkspaceCatalogResponseV1 {
            validation: Some(validation.into()),
            error_kind: None,
            future_schema_version: None,
        },
        Err(error) => {
            let (error_kind, future_schema_version) = workspace_journal_error(error);
            CoreWorkspaceCatalogResponseV1 {
                validation: None,
                error_kind: Some(error_kind),
                future_schema_version,
            }
        }
    }
}

fn workspace_metadata_response(
    result: Result<
        runtime::workspace_persistence_journal::WorkspacePersistenceMetadataValidationV1,
        runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
    >,
) -> CoreWorkspacePersistenceMetadataResponseV1 {
    match result {
        Ok(validation) => CoreWorkspacePersistenceMetadataResponseV1 {
            validation: Some(validation.into()),
            error_kind: None,
            future_schema_version: None,
        },
        Err(error) => {
            let (error_kind, future_schema_version) = workspace_journal_error(error);
            CoreWorkspacePersistenceMetadataResponseV1 {
                validation: None,
                error_kind: Some(error_kind),
                future_schema_version,
            }
        }
    }
}

fn workspace_command_identity_request(
    request: CoreWorkspaceCommandIdentityRequestV1,
) -> runtime::workspace_persistence_journal::WorkspaceCommandIdentityRequestV1 {
    runtime::workspace_persistence_journal::WorkspaceCommandIdentityRequestV1 {
        operation_id: request.operation_id,
        expected_catalog_revision: request.expected_catalog_revision,
        expected_workspace_revision: request.expected_workspace_revision,
        expected_context_revision: request.expected_context_revision,
        origin: request.origin.into(),
        command_kind: request.command_kind.into(),
        workspace_id: request.workspace_id,
        file_url: request.file_url,
        content_digest: request.content_digest,
        accept_external: request.accept_external,
        protected_agent_identities: request
            .protected_agent_identities
            .into_iter()
            .map(Into::into)
            .collect(),
    }
}

fn workspace_command_admission_acquire_response(
    result: Result<
        runtime::workspace_persistence_journal::WorkspaceCommandAdmissionAcquireV1,
        runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
    >,
    admission: &CorePreparedWorkspaceCommandAdmissionV1,
    deadline_unix_millis: Option<u64>,
) -> Result<CoreWorkspaceCommandAdmissionAcquireResponseV1, CoreError> {
    let success = |kind,
                   identity: runtime::workspace_persistence_journal::WorkspaceCommandIdentityV1,
                   claim,
                   scope,
                   operation,
                   generation| CoreWorkspaceCommandAdmissionAcquireResponseV1 {
        kind: Some(kind),
        identity: Some(identity.into()),
        claim,
        scope,
        operation,
        generation,
        error_kind: None,
        future_schema_version: None,
    };
    Ok(match result {
        Ok(
            runtime::workspace_persistence_journal::WorkspaceCommandAdmissionAcquireV1::Claimed {
                identity,
                claim,
            },
        ) => {
            let generation = claim.generation();
            let managed_request = runtime::AdmissionRequest {
                operation_id: runtime::OperationId::parse(claim.operation_id().to_owned())
                    .map_err(CoreError::from)?,
                fingerprint: runtime::RequestFingerprint::parse(claim.fingerprint().to_owned())
                    .map_err(CoreError::from)?,
                scope: runtime::ScopeId::parse(claim.workspace_id().to_owned())
                    .map_err(CoreError::from)?,
                deadline_unix_millis,
                runtime_identity: admission.identity.clone(),
            };
            let runtime = admission
                .runtime
                .upgrade()
                .ok_or(CoreError::RuntimeStopped)?;
            let lifecycle = match runtime.attach_managed_operation(managed_request) {
                Ok((lifecycle, _)) => lifecycle,
                Err(error) => {
                    let _ = claim.abandon();
                    return Err(error.into());
                }
            };
            success(
                CoreWorkspaceCommandAdmissionAcquireKindV1::Claimed,
                identity,
                Some(Arc::new(CoreWorkspaceCommandExecutionClaimV1 {
                    inner: Arc::new(claim),
                    admission: Arc::clone(&admission.inner),
                    lifecycle,
                    runtime: Weak::clone(&admission.runtime),
                    identity: admission.identity.clone(),
                    panic_guard: Arc::clone(&admission.panic_guard),
                })),
                None,
                None,
                Some(generation),
            )
        }
        Ok(
            runtime::workspace_persistence_journal::WorkspaceCommandAdmissionAcquireV1::Pending {
                identity,
                generation,
            },
        ) => success(
            CoreWorkspaceCommandAdmissionAcquireKindV1::Pending,
            identity,
            None,
            None,
            None,
            Some(generation),
        ),
        Ok(
            runtime::workspace_persistence_journal::WorkspaceCommandAdmissionAcquireV1::Collision {
                identity,
                scope,
            },
        ) => success(
            CoreWorkspaceCommandAdmissionAcquireKindV1::Collision,
            identity,
            None,
            scope.map(Into::into),
            None,
            None,
        ),
        Ok(
            runtime::workspace_persistence_journal::WorkspaceCommandAdmissionAcquireV1::Replay {
                identity,
                scope,
                operation,
            },
        ) => success(
            CoreWorkspaceCommandAdmissionAcquireKindV1::Replay,
            identity,
            None,
            Some(scope.into()),
            Some(operation.into()),
            None,
        ),
        Err(error) => {
            let (error_kind, future_schema_version) = workspace_journal_error(error);
            CoreWorkspaceCommandAdmissionAcquireResponseV1 {
                kind: None,
                identity: None,
                claim: None,
                scope: None,
                operation: None,
                generation: None,
                error_kind: Some(error_kind),
                future_schema_version,
            }
        }
    })
}

fn workspace_command_semantic_preflight_response(
    result: Result<
        runtime::workspace_persistence_journal::WorkspaceCommandSemanticPreflightV1,
        runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
    >,
) -> CoreWorkspaceSemanticPreflightResponseV1 {
    match result {
        Ok(preflight) => CoreWorkspaceSemanticPreflightResponseV1 {
            preflight: Some(preflight.into()),
            error_kind: None,
            future_schema_version: None,
        },
        Err(error) => {
            let (error_kind, future_schema_version) = workspace_journal_error(error);
            CoreWorkspaceSemanticPreflightResponseV1 {
                preflight: None,
                error_kind: Some(error_kind),
                future_schema_version,
            }
        }
    }
}

fn workspace_command_lifecycle_directive(
    directive: runtime::ManagedOperationDirective,
) -> Result<CoreWorkspaceCommandLifecycleDirectiveV1, CoreError> {
    Ok(match directive {
        runtime::ManagedOperationDirective::ContinueExecution => {
            CoreWorkspaceCommandLifecycleDirectiveV1::ContinueExecution
        }
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::Cancelled,
        )
        | runtime::ManagedOperationDirective::Terminal(runtime::TerminalOutcome::Cancelled) => {
            CoreWorkspaceCommandLifecycleDirectiveV1::Cancelled
        }
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::DeadlineExceeded,
        )
        | runtime::ManagedOperationDirective::Terminal(
            runtime::TerminalOutcome::DeadlineExceeded,
        ) => CoreWorkspaceCommandLifecycleDirectiveV1::DeadlineExceeded,
        runtime::ManagedOperationDirective::Stop(
            runtime::ManagedOperationStopReason::ShutdownRequested,
        ) => CoreWorkspaceCommandLifecycleDirectiveV1::ShutdownRequested,
        runtime::ManagedOperationDirective::Terminal(
            runtime::TerminalOutcome::Success | runtime::TerminalOutcome::Failed,
        ) => return Err(CoreError::OperationConflict),
    })
}

fn workspace_command_terminal_outcome_from_fields(
    diagnostic: Option<&str>,
    error_code: Option<&str>,
    disposition: &str,
) -> runtime::TerminalOutcome {
    if diagnostic == Some("workspace_command_deadline_exceeded") {
        runtime::TerminalOutcome::DeadlineExceeded
    } else if error_code == Some("cancelled") {
        runtime::TerminalOutcome::Cancelled
    } else if disposition == "failed" {
        runtime::TerminalOutcome::Failed
    } else {
        runtime::TerminalOutcome::Success
    }
}

fn workspace_command_terminal_outcome_from_runtime(
    operation: &runtime::workspace_persistence_journal::WorkspaceRecordedOperationV1,
) -> runtime::TerminalOutcome {
    workspace_command_terminal_outcome_from_fields(
        operation.diagnostic.as_deref(),
        operation.error_code.as_deref(),
        &operation.disposition,
    )
}

fn workspace_command_terminal_outcome(
    operation: &CoreWorkspaceRecordedOperationV1,
) -> runtime::TerminalOutcome {
    workspace_command_terminal_outcome_from_fields(
        operation.diagnostic.as_deref(),
        operation.error_code.as_deref(),
        &operation.disposition,
    )
}

fn workspace_command_transient_finalization_response(
    result: Result<
        runtime::workspace_persistence_journal::WorkspaceRecordedOperationV1,
        runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
    >,
) -> CoreWorkspaceCommandTransientFinalizationResponseV1 {
    match result {
        Ok(operation) => CoreWorkspaceCommandTransientFinalizationResponseV1 {
            operation: Some(operation.into()),
            error_kind: None,
            future_schema_version: None,
        },
        Err(error) => {
            let (error_kind, future_schema_version) = workspace_journal_error(error);
            CoreWorkspaceCommandTransientFinalizationResponseV1 {
                operation: None,
                error_kind: Some(error_kind),
                future_schema_version,
            }
        }
    }
}

fn workspace_command_admission_mutation_response(
    result: Result<
        runtime::workspace_persistence_journal::WorkspaceCommandAdmissionDiagnosticsV1,
        runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
    >,
) -> CoreWorkspaceCommandAdmissionMutationResponseV1 {
    match result {
        Ok(diagnostics) => CoreWorkspaceCommandAdmissionMutationResponseV1 {
            diagnostics: Some(diagnostics.into()),
            error_kind: None,
            future_schema_version: None,
        },
        Err(error) => {
            let (error_kind, future_schema_version) = workspace_journal_error(error);
            CoreWorkspaceCommandAdmissionMutationResponseV1 {
                diagnostics: None,
                error_kind: Some(error_kind),
                future_schema_version,
            }
        }
    }
}

fn workspace_journal_mutation_directive_response(
    result: Result<
        runtime::workspace_persistence_journal::WorkspaceJournalMutationDirectiveV1,
        runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
    >,
) -> CoreWorkspaceJournalMutationDirectiveResponseV1 {
    match result {
        Ok(directive) => CoreWorkspaceJournalMutationDirectiveResponseV1 {
            directive: Some(directive.into()),
            error_kind: None,
            future_schema_version: None,
        },
        Err(error) => {
            let (error_kind, future_schema_version) = workspace_journal_error(error);
            CoreWorkspaceJournalMutationDirectiveResponseV1 {
                directive: None,
                error_kind: Some(error_kind),
                future_schema_version,
            }
        }
    }
}

fn workspace_save_directive_response(
    result: Result<
        runtime::workspace_persistence_journal::WorkspaceSaveDirectiveV1,
        runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
    >,
) -> CoreWorkspaceSaveDirectiveResponseV1 {
    match result {
        Ok(directive) => CoreWorkspaceSaveDirectiveResponseV1 {
            directive: Some(directive.into()),
            error_kind: None,
            future_schema_version: None,
        },
        Err(error) => {
            let (error_kind, future_schema_version) = workspace_journal_error(error);
            CoreWorkspaceSaveDirectiveResponseV1 {
                directive: None,
                error_kind: Some(error_kind),
                future_schema_version,
            }
        }
    }
}

fn workspace_create_directive_response(
    result: Result<
        runtime::workspace_persistence_journal::WorkspaceCreateDirectiveV1,
        runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
    >,
) -> CoreWorkspaceCreateDirectiveResponseV1 {
    match result {
        Ok(directive) => CoreWorkspaceCreateDirectiveResponseV1 {
            directive: Some(directive.into()),
            error_kind: None,
            future_schema_version: None,
        },
        Err(error) => {
            let (error_kind, future_schema_version) = workspace_journal_error(error);
            CoreWorkspaceCreateDirectiveResponseV1 {
                directive: None,
                error_kind: Some(error_kind),
                future_schema_version,
            }
        }
    }
}

fn workspace_delete_directive_response(
    result: Result<
        runtime::workspace_persistence_journal::WorkspaceDeleteDirectiveV1,
        runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
    >,
) -> CoreWorkspaceDeleteDirectiveResponseV1 {
    match result {
        Ok(directive) => CoreWorkspaceDeleteDirectiveResponseV1 {
            directive: Some(directive.into()),
            error_kind: None,
            future_schema_version: None,
        },
        Err(error) => {
            let (error_kind, future_schema_version) = workspace_journal_error(error);
            CoreWorkspaceDeleteDirectiveResponseV1 {
                directive: None,
                error_kind: Some(error_kind),
                future_schema_version,
            }
        }
    }
}

fn workspace_journal_error(
    error: runtime::workspace_persistence_journal::WorkspaceWorkingJournalError,
) -> (
    CoreWorkspaceWorkingJournalValidationErrorKindV1,
    Option<u16>,
) {
    use runtime::workspace_persistence_journal::WorkspaceWorkingJournalError as JournalError;
    match error {
        JournalError::InputTooLarge { .. } => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InputTooLarge,
            None,
        ),
        JournalError::OutputTooLarge { .. } => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::OutputTooLarge,
            None,
        ),
        JournalError::Malformed => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::Malformed,
            None,
        ),
        JournalError::FutureSchema(version) => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::FutureSchema,
            Some(version),
        ),
        JournalError::InvalidIdentity => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidIdentity,
            None,
        ),
        JournalError::DuplicateCatalogIdentity => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::DuplicateCatalogIdentity,
            None,
        ),
        JournalError::InvalidFileUrl => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidFileUrl,
            None,
        ),
        JournalError::InvalidRevisionState => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidRevisionState,
            None,
        ),
        JournalError::InvalidDigest => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidDigest,
            None,
        ),
        JournalError::InvalidWorkingDocument => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidWorkingDocument,
            None,
        ),
        JournalError::InvalidContextTable => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidContextTable,
            None,
        ),
        JournalError::InvalidOperationLedger => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidOperationLedger,
            None,
        ),
        JournalError::InvalidPendingSave => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidPendingSave,
            None,
        ),
        JournalError::InvalidTimestamp => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidTimestamp,
            None,
        ),
        JournalError::ExternalDocumentConflict => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::ExternalDocumentConflict,
            None,
        ),
        JournalError::StaleRecoverySnapshot => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::StaleRecoverySnapshot,
            None,
        ),
        JournalError::FullRecoveryRequired => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::FullRecoveryRequired,
            None,
        ),
        JournalError::InvalidTransaction => (
            CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidTransaction,
            None,
        ),
    }
}

fn handle_invalidated(reason: runtime::inventory_scope::InvalidationReason) -> CoreError {
    CoreError::InventoryHandleInvalidated {
        reason: InventoryHandleInvalidationReasonV1::from(reason),
    }
}

impl CoreRuntime {
    fn create(config: CoreConfig) -> Result<Self, CoreError> {
        let identity = runtime::RuntimeIdentity::fresh(CORE_BUILD_FINGERPRINT, BINDING_CHECKSUM)?;
        let inner = Arc::new(runtime::CoreRuntime::new(
            config.runtime_config()?,
            identity,
        )?);
        let search_leaf = runtime::SearchLeaf::new()?;
        Ok(Self {
            inner,
            search_leaf,
            code_map_service: runtime::codemap::CodeMapService,
            apply_edits_service: runtime::apply_edits::ApplyEditsService,
            path_match_service: runtime::pathmatch::PathMatchScoreService,
            path_resolve_service: runtime::pathmatch::PathMatchResolveService,
            path_search_service: runtime::pathsearch::PathSearchFindService,
            token_accounting_service: runtime::tokenacct::TokenAccountingService,
            inventory_scope_registry: runtime::inventory_scope::ScopeRegistry::new(),
            agent_claude_scope_registry: runtime::agent_claude::ScopeRegistry::new(),
            config,
            initialized: AtomicBool::new(false),
            panic_guard: Arc::new(PanicGuard::new()),
        })
    }

    fn guard<T>(&self, operation: impl FnOnce() -> Result<T, CoreError>) -> Result<T, CoreError> {
        self.panic_guard.call(operation)
    }

    fn require_initialized(&self) -> Result<(), CoreError> {
        if self.initialized.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(CoreError::IncompatibleAbi)
        }
    }

    fn require_running(&self) -> Result<(), CoreError> {
        self.require_initialized()?;
        if self.inner.lifecycle() == runtime::LifecycleState::Running {
            Ok(())
        } else {
            Err(CoreError::RuntimeStopped)
        }
    }

    fn validate_identity(
        &self,
        identity: &RuntimeIdentity,
    ) -> Result<runtime::RuntimeIdentity, CoreError> {
        let identity = identity.parse()?;
        if &identity == self.inner.identity() {
            Ok(identity)
        } else {
            Err(CoreError::StaleRuntimeIdentity)
        }
    }

    /// Routes a `scope_id` string to its `InventoryScope` (see `types.rs`'s P4-4 section doc
    /// comment for why every handle-based inventory-scope export takes an explicit `scope_id`
    /// rather than relying on the contract's implicit-scope pseudocode).
    fn inventory_scope(
        &self,
        scope_id: &str,
    ) -> Result<std::sync::Arc<runtime::inventory_scope::InventoryScope>, CoreError> {
        let scope_id = parse_inventory_scope_id(scope_id)?;
        self.inventory_scope_registry
            .get(scope_id)
            .ok_or(CoreError::InventoryScopeUnknownScope)
    }

    /// P6-6: the agent-claude-v1 counterpart of `inventory_scope` above.
    fn agent_claude_scope(
        &self,
        scope_id: &str,
    ) -> Result<std::sync::Arc<runtime::agent_claude::AgentClaudeScope>, CoreError> {
        let scope_id = crate::types::parse_agent_claude_scope_id(scope_id)?;
        self.agent_claude_scope_registry
            .get(scope_id)
            .ok_or(CoreError::AgentClaudeUnknownScope)
    }

    #[cfg(test)]
    fn panic_for_test(&self) -> Result<(), CoreError> {
        self.guard(|| panic!("test-only panic injection"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{
        CoreApplyEditsSubjectRequestV1, CoreCodeMapSourceKindV1, CoreCodeMapSubjectRequestV1,
        CoreWorkspaceCommandKindV1, CoreWorkspaceCommandOriginV1, InventoryApplyOutcomeV1,
        InventoryRejectionReasonV1,
    };

    fn config() -> CoreConfig {
        CoreConfig {
            expected_abi_epoch: ABI_EPOCH,
            expected_build_fingerprint: CORE_BUILD_FINGERPRINT.to_owned(),
            expected_binding_checksum: BINDING_CHECKSUM.to_owned(),
            data_lane_capacity: 8,
            cancel_tombstone_millis: 10,
            shutdown_grace_millis: 10,
        }
    }

    #[test]
    fn initialization_rejects_build_fingerprint_mismatch() {
        let mut wrong = config();
        wrong.expected_build_fingerprint = "f".repeat(64);
        let core = CoreRuntime::new(wrong).expect("runtime creation");
        assert_eq!(core.initialize(), Err(CoreError::IncompatibleAbi));
    }

    #[test]
    fn caught_panic_poison_rejects_later_exports() {
        let core = CoreRuntime::new(config()).expect("runtime creation");
        core.initialize().expect("initialize");
        assert_eq!(core.panic_for_test(), Err(CoreError::InternalPanic));
        assert!(core.panic_guard.is_poisoned());
        assert_eq!(core.initialize(), Err(CoreError::RuntimePoisoned));
    }

    #[test]
    fn panic_forensics_survives_poisoning_and_names_the_panic_site() {
        let core = CoreRuntime::new(config()).expect("runtime creation");
        core.initialize().expect("initialize");
        assert_eq!(core.panic_for_test(), Err(CoreError::InternalPanic));
        assert!(core.panic_guard.is_poisoned());

        // The poisoned runtime rejects every other guarded export...
        assert_eq!(core.initialize(), Err(CoreError::RuntimePoisoned));
        // ...but forensics, deliberately unguarded, still answers: this is
        // the whole point of not routing panic_forensics through `guard()`.
        // `.last()` is safe here specifically because every panic-injecting
        // test in this crate calls the same `panic_for_test` (identical
        // message/location) -- the ring is process-wide and `cargo test`
        // runs tests concurrently, so a *different* message here would be
        // racy against other threads' panics landing in between.
        let forensics = core.panic_forensics();
        let last = forensics
            .last()
            .expect("panic hook should have recorded an entry");
        assert!(last.contains("test-only panic injection"));
        assert!(last.contains("api.rs"));
    }

    #[test]
    fn close_and_shutdown_are_idempotent() {
        let core = CoreRuntime::new(config()).expect("runtime creation");
        let identity = core.initialize().expect("initialize").runtime_identity;
        let subscription = core
            .open_subscription(SubscriptionScope {
                runtime_identity: identity.clone(),
                scope_id: crate::types::ScopeId {
                    value: "00000000-0000-0000-0000-000000000001".to_owned(),
                },
                max_queued_events: 0,
                max_queued_bytes: 0,
            })
            .expect("open subscription")
            .subscription_id;
        core.close_subscription(subscription.clone())
            .expect("first close");
        core.close_subscription(subscription).expect("second close");
        let first = core.begin_shutdown(identity.clone()).expect("shutdown");
        let second = core.begin_shutdown(identity).expect("duplicate shutdown");
        assert!(!first.already_started);
        assert!(second.already_started);
    }

    fn initialized_core() -> (Arc<CoreRuntime>, RuntimeIdentity, Arc<LeafCancellation>) {
        let core = CoreRuntime::new(config()).expect("runtime creation");
        let identity = core.initialize().expect("initialize").runtime_identity;
        let cancellation = core
            .create_leaf_cancellation(identity.clone())
            .expect("leaf cancellation");
        (core, identity, cancellation)
    }

    #[test]
    fn text_decode_export_preserves_bom_and_encoding_identity() {
        let (core, identity, _) = initialized_core();
        let result = core
            .text_decode_v1(CoreTextDecodeRequestV1 {
                runtime_identity: identity,
                contract_version: runtime::textdecode::TEXT_DECODE_CONTRACT_VERSION_V1,
                raw_bytes: vec![0xFF, 0xFE, b'a', 0x00],
            })
            .expect("text decode export");
        assert_eq!(result.text, "\u{FEFF}a");
        assert_eq!(
            result.encoding,
            crate::types::CoreTextEncodingV1::Utf16LittleEndian
        );
        assert!(result.bom_present);
        assert!(!result.had_replacements);
        assert_eq!(result.policy_id, "workspace-automatic-v2");
        assert_eq!(result.legacy_encoding_name, None);
    }

    #[test]
    fn workspace_document_projection_export_validates_identity_contract_and_payload() {
        let (core, identity, _) = initialized_core();
        let document = br#"{
            "id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "composeTabs":[{
                "id":"11111111-2222-3333-4444-555555555555",
                "prompt":"Review",
                "selectedPaths":["Sources/App.swift"]
            }]
        }"#;
        let result = core
            .workspace_document_projection_v1(CoreWorkspaceDocumentProjectionRequestV1 {
                runtime_identity: identity.clone(),
                contract_version:
                    runtime::workspace_context::WORKSPACE_DOCUMENT_PROJECTION_CONTRACT_VERSION_V1,
                document_bytes: document.to_vec(),
            })
            .expect("workspace projection export");
        assert_eq!(result.workspace_id, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
        assert_eq!(result.contexts.len(), 1);
        assert_eq!(result.contexts[0].prompt, "Review");
        assert_eq!(result.contexts[0].selection, ["Sources/App.swift"]);

        let wrong_contract =
            core.workspace_document_projection_v1(CoreWorkspaceDocumentProjectionRequestV1 {
                runtime_identity: identity.clone(),
                contract_version: 99,
                document_bytes: document.to_vec(),
            });
        assert_eq!(wrong_contract, Err(CoreError::InvalidArgument));

        let invalid_document =
            core.workspace_document_projection_v1(CoreWorkspaceDocumentProjectionRequestV1 {
                runtime_identity: identity,
                contract_version:
                    runtime::workspace_context::WORKSPACE_DOCUMENT_PROJECTION_CONTRACT_VERSION_V1,
                document_bytes: b"[]".to_vec(),
            });
        assert_eq!(invalid_document, Err(CoreError::InvalidArgument));
    }

    #[test]
    fn workspace_command_identity_export_is_exact_runtime_fenced_and_typed() {
        let (core, identity, _) = initialized_core();
        let request = CoreWorkspaceCommandIdentityRequestV1 {
            runtime_identity: identity.clone(),
            contract_version: runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
            operation_id: "66666666-7777-8888-9999-aaaaaaaaaaaa".to_owned(),
            expected_catalog_revision: None,
            expected_workspace_revision: None,
            expected_context_revision: None,
            origin: CoreWorkspaceCommandOriginV1::AppPresentation { window_id: 42 },
            command_kind: CoreWorkspaceCommandKindV1::Create,
            workspace_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_owned(),
            file_url: Some("file:///tmp/Workspace.json".to_owned()),
            content_digest: Some("f".repeat(64)),
            accept_external: None,
            protected_agent_identities: Vec::new(),
        };
        let response = core
            .workspace_command_identity_v1(request.clone())
            .expect("command identity");
        assert_eq!(response.error_kind, None);
        let command = response.identity.expect("identity receipt");
        assert_eq!(command.command_kind, CoreWorkspaceCommandKindV1::Create);
        assert_eq!(command.workspace_id, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
        assert_eq!(
            command.fingerprint,
            "4a06f1cb575766d8be224014ef503c41ccd40d82a94521be142f4746cbd4b9f0"
        );

        let mut contradictory = request.clone();
        contradictory.accept_external = Some(false);
        let invalid = core
            .workspace_command_identity_v1(contradictory)
            .expect("semantic error response");
        assert_eq!(invalid.identity, None);
        assert_eq!(
            invalid.error_kind,
            Some(CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidTransaction)
        );

        let mut wrong_contract = request;
        wrong_contract.contract_version = 99;
        assert_eq!(
            core.workspace_command_identity_v1(wrong_contract),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn workspace_command_admission_export_is_typed_bounded_and_runtime_fenced() {
        let (core, identity, _) = initialized_core();
        let operation = CoreWorkspaceRecordedOperationV1 {
            operation_id: "66666666-7777-8888-9999-aaaaaaaaaaaa".to_owned(),
            fingerprint: "4a06f1cb575766d8be224014ef503c41ccd40d82a94521be142f4746cbd4b9f0"
                .to_owned(),
            recorded_at: 42.5,
            disposition: "applied".to_owned(),
            before: None,
            after: None,
            catalog_revision: 7,
            resulting_digest: Some("a".repeat(64)),
            error_code: None,
            diagnostic: None,
        };
        let catalog_bytes = serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "revision": 7,
            "entries": [{
                "workspaceID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "fileURL": "file:///tmp/Workspace.json"
            }],
            "deletions": [],
            "updatedAt": 42.5
        }))
        .expect("catalog bytes");
        let journal_bytes = |operations: &[CoreWorkspaceRecordedOperationV1]| {
            let operations = operations
                .iter()
                .cloned()
                .map(runtime::workspace_persistence_journal::WorkspaceRecordedOperationV1::from)
                .map(|operation| serde_json::to_value(operation).expect("operation json"))
                .collect::<Vec<_>>();
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "workspaceID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "fileURL": "file:///tmp/Workspace.json",
                "revisions": {"workingRevision": 0, "savedRevision": 0},
                "savedDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "contextRevisions": [],
                "contextDigests": [],
                "contextTombstones": [],
                "operations": operations,
                "updatedAt": 42.5
            }))
            .expect("journal bytes")
        };
        let recovery =
            |operations: &[CoreWorkspaceRecordedOperationV1]| CoreWorkspaceSemanticFullRecoveryV1 {
                catalog_bytes: catalog_bytes.clone(),
                workspaces: vec![crate::types::CoreWorkspaceSemanticRecoveryEvidenceV1 {
                    workspace_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_owned(),
                    journal: crate::types::CoreWorkspaceRecoveryArtifactEvidenceV1::Present {
                        bytes: journal_bytes(operations),
                    },
                    saved_document: crate::types::CoreWorkspaceRecoveryArtifactEvidenceV1::Absent,
                    saved_revision: crate::types::CoreWorkspaceRecoveryArtifactEvidenceV1::Absent,
                }],
                deletions: Vec::new(),
            };
        let prepared_recovery = core
            .workspace_semantic_initial_recovery_prepare_v1(
                CoreWorkspaceSemanticInitialRecoveryRequestV1 {
                    runtime_identity: identity.clone(),
                    contract_version: runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
                    recovery: recovery(std::slice::from_ref(&operation)),
                },
            )
            .expect("semantic command admission prepare")
            .recovery
            .expect("prepared semantic recovery");
        let preview = prepared_recovery
            .preview()
            .expect("semantic recovery preview")
            .preview
            .expect("semantic preview");
        let commit = prepared_recovery
            .commit()
            .expect("semantic recovery commit");
        assert_eq!(commit.error_kind, None);
        assert_eq!(commit.catalog_revision, Some(7));
        assert_eq!(commit.projection_digest, Some(preview.projection_digest));
        let admission = commit.admission.expect("prepared admission");

        let preflight_request = CoreWorkspaceCommandIdentityRequestV1 {
            runtime_identity: identity.clone(),
            contract_version: runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
            operation_id: operation.operation_id.clone(),
            expected_catalog_revision: None,
            expected_workspace_revision: None,
            expected_context_revision: None,
            origin: CoreWorkspaceCommandOriginV1::AppPresentation { window_id: 42 },
            command_kind: CoreWorkspaceCommandKindV1::Create,
            workspace_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_owned(),
            file_url: Some("file:///tmp/Workspace.json".to_owned()),
            content_digest: Some("f".repeat(64)),
            accept_external: None,
            protected_agent_identities: Vec::new(),
        };
        let replay = admission
            .acquire(preflight_request.clone(), None)
            .expect("typed replay acquire");
        assert_eq!(
            replay.kind,
            Some(CoreWorkspaceCommandAdmissionAcquireKindV1::Replay)
        );
        assert_eq!(
            replay.scope,
            Some(CoreWorkspaceCommandAdmissionLookupScopeV1::Workspace)
        );
        assert_eq!(replay.operation, Some(operation.clone()));
        assert!(replay.claim.is_none());
        let mut invalid_acquire = preflight_request.clone();
        invalid_acquire.content_digest = Some("invalid".to_owned());
        let rejected_acquire = admission
            .acquire(invalid_acquire, None)
            .expect("typed semantic failure");
        assert_eq!(rejected_acquire.kind, None);
        assert_eq!(
            rejected_acquire.error_kind,
            Some(CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidDigest)
        );

        let mut collision_request = preflight_request.clone();
        collision_request.content_digest = Some("e".repeat(64));
        let collision = admission
            .acquire(collision_request, None)
            .expect("typed collision acquire");
        assert_eq!(
            collision.kind,
            Some(CoreWorkspaceCommandAdmissionAcquireKindV1::Collision)
        );
        assert_eq!(
            collision.scope,
            Some(CoreWorkspaceCommandAdmissionLookupScopeV1::Workspace)
        );

        let mut transient_request = preflight_request.clone();
        transient_request.operation_id = "77777777-8888-9999-aaaa-bbbbbbbbbbbb".to_owned();
        let acquired = admission
            .acquire(transient_request.clone(), None)
            .expect("transient claim acquire");
        assert_eq!(
            acquired.kind,
            Some(CoreWorkspaceCommandAdmissionAcquireKindV1::Claimed)
        );
        let transient = CoreWorkspaceRecordedOperationV1 {
            operation_id: transient_request.operation_id.clone(),
            fingerprint: acquired
                .identity
                .as_ref()
                .expect("claim identity")
                .fingerprint
                .clone(),
            ..operation.clone()
        };
        let claim = acquired.claim.expect("execution claim");
        assert_eq!(
            claim.checkpoint().expect("lifecycle checkpoint"),
            CoreWorkspaceCommandLifecycleDirectiveV1::ContinueExecution
        );
        let finalized = claim
            .finalize_transient(transient.clone())
            .expect("transient finalization");
        assert_eq!(finalized.operation, Some(transient.clone()));
        let mut durable_request = preflight_request.clone();
        durable_request.operation_id = "88888888-9999-aaaa-bbbb-cccccccccccc".to_owned();
        let durable_acquired = admission
            .acquire(durable_request, None)
            .expect("durable claim acquire");
        let durable_claim = durable_acquired.claim.expect("durable execution claim");
        let durable = CoreWorkspaceRecordedOperationV1 {
            operation_id: "88888888-9999-aaaa-bbbb-cccccccccccc".to_owned(),
            fingerprint: durable_acquired
                .identity
                .expect("durable identity")
                .fingerprint,
            ..operation.clone()
        };
        let active_managed_before_reconcile = core.inner.active_managed_operation_count();
        let full_recovery = admission
            .prepare_semantic_full_recovery(recovery(std::slice::from_ref(&durable)))
            .expect("durable semantic recovery prepare")
            .recovery
            .expect("prepared durable semantic recovery");
        let _ = full_recovery
            .preview()
            .expect("durable semantic recovery preview")
            .preview
            .expect("durable semantic preview");
        let reconciled = full_recovery
            .commit()
            .expect("durable semantic recovery commit")
            .admission_receipt
            .expect("recovery receipt")
            .diagnostics;
        assert!(!durable_claim.abandon().expect("reconciled claim cleanup"));
        assert_eq!(
            core.inner.active_managed_operation_count(),
            active_managed_before_reconcile - 1
        );
        assert_eq!(reconciled.global_operation_count, 3);
        assert_eq!(reconciled.workspace_operation_count, 1);
        let retained = admission
            .acquire(transient_request, None)
            .expect("retained global acquire");
        assert_eq!(
            retained.kind,
            Some(CoreWorkspaceCommandAdmissionAcquireKindV1::Replay)
        );
        assert_eq!(
            retained.scope,
            Some(CoreWorkspaceCommandAdmissionLookupScopeV1::Global)
        );
        assert_eq!(retained.operation, Some(transient));

        let mut cancelled_request = preflight_request.clone();
        cancelled_request.operation_id = "aaaaaaaa-bbbb-cccc-dddd-ffffffffffff".to_owned();
        core.cancel_operation(
            identity.clone(),
            crate::types::OperationId {
                value: cancelled_request.operation_id.clone(),
            },
        )
        .expect("cancel before workspace acquire");
        let cancelled = admission
            .acquire(cancelled_request.clone(), None)
            .expect("cancelled claim acquire");
        assert_eq!(
            cancelled.kind,
            Some(CoreWorkspaceCommandAdmissionAcquireKindV1::Claimed)
        );
        let cancelled_identity = cancelled.identity.expect("cancelled identity");
        let cancelled_claim = cancelled.claim.expect("cancelled claim");
        assert_eq!(
            cancelled_claim.checkpoint().expect("cancelled checkpoint"),
            CoreWorkspaceCommandLifecycleDirectiveV1::Cancelled
        );
        let cancelled_operation = CoreWorkspaceRecordedOperationV1 {
            operation_id: cancelled_request.operation_id.clone(),
            fingerprint: cancelled_identity.fingerprint,
            disposition: "failed".to_owned(),
            error_code: Some("cancelled".to_owned()),
            diagnostic: Some("workspace_command_identity_cancelled".to_owned()),
            ..operation.clone()
        };
        let cancelled_receipt = cancelled_claim
            .finalize_transient(cancelled_operation.clone())
            .expect("cancelled finalization");
        assert_eq!(
            cancelled_receipt.operation,
            Some(cancelled_operation.clone())
        );
        let cancelled_replay = admission
            .acquire(cancelled_request, None)
            .expect("cancelled replay");
        assert_eq!(
            cancelled_replay.kind,
            Some(CoreWorkspaceCommandAdmissionAcquireKindV1::Replay)
        );
        assert_eq!(cancelled_replay.operation, Some(cancelled_operation));

        let mut raced_request = preflight_request.clone();
        raced_request.operation_id = "cccccccc-dddd-eeee-ffff-aaaaaaaaaaaa".to_owned();
        let raced = admission
            .acquire(raced_request.clone(), None)
            .expect("race claim acquire");
        let raced_identity = raced.identity.expect("race identity");
        let raced_claim = raced.claim.expect("race claim");
        core.cancel_operation(
            identity.clone(),
            crate::types::OperationId {
                value: raced_request.operation_id.clone(),
            },
        )
        .expect("cancel claimed operation");
        let raced_semantic = CoreWorkspaceRecordedOperationV1 {
            operation_id: raced_request.operation_id.clone(),
            fingerprint: raced_identity.fingerprint.clone(),
            disposition: "conflict".to_owned(),
            error_code: Some("state_conflict".to_owned()),
            diagnostic: Some("semantic_result_lost_race".to_owned()),
            ..operation.clone()
        };
        assert!(matches!(
            raced_claim.finalize_transient(raced_semantic),
            Err(CoreError::OperationCancelled)
        ));
        let raced_cancelled = CoreWorkspaceRecordedOperationV1 {
            operation_id: raced_request.operation_id.clone(),
            fingerprint: raced_identity.fingerprint,
            disposition: "failed".to_owned(),
            error_code: Some("cancelled".to_owned()),
            diagnostic: Some("workspace_command_identity_cancelled".to_owned()),
            ..operation.clone()
        };
        assert_eq!(
            raced_claim
                .finalize_transient(raced_cancelled.clone())
                .expect("race cancellation finalization")
                .operation,
            Some(raced_cancelled.clone())
        );
        assert_eq!(
            admission
                .acquire(raced_request, None)
                .expect("race cancellation replay")
                .operation,
            Some(raced_cancelled)
        );

        let mut deadline_request = preflight_request.clone();
        deadline_request.operation_id = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff".to_owned();
        assert!(matches!(
            admission.acquire(deadline_request.clone(), Some(1)),
            Err(CoreError::DeadlineExpired)
        ));
        let retry_after_deadline = admission
            .acquire(deadline_request, None)
            .expect("deadline rollback retry");
        assert_eq!(
            retry_after_deadline.kind,
            Some(CoreWorkspaceCommandAdmissionAcquireKindV1::Claimed)
        );
        assert!(
            retry_after_deadline
                .claim
                .expect("deadline retry claim")
                .abandon()
                .expect("deadline retry abandon")
        );

        let tombstone = CoreWorkspaceRecordedOperationV1 {
            operation_id: "99999999-aaaa-bbbb-cccc-dddddddddddd".to_owned(),
            fingerprint: "b".repeat(64),
            ..operation.clone()
        };
        let target_recovery = admission
            .prepare_semantic_target_recovery(CoreWorkspaceSemanticTargetRecoveryV1 {
                catalog_bytes: catalog_bytes.clone(),
                workspace_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_owned(),
                journal: crate::types::CoreWorkspaceRecoveryArtifactEvidenceV1::Present {
                    bytes: journal_bytes(std::slice::from_ref(&tombstone)),
                },
                saved_document: crate::types::CoreWorkspaceRecoveryArtifactEvidenceV1::Absent,
                saved_revision: crate::types::CoreWorkspaceRecoveryArtifactEvidenceV1::Absent,
                deletion_sidecar: crate::types::CoreWorkspaceRecoveryArtifactEvidenceV1::Absent,
            })
            .expect("targeted semantic recovery prepare")
            .recovery
            .expect("prepared target semantic recovery");
        let _ = target_recovery
            .preview()
            .expect("targeted semantic recovery preview")
            .preview
            .expect("target semantic preview");
        let reconciled = target_recovery
            .commit()
            .expect("targeted semantic recovery commit")
            .admission_receipt
            .expect("target recovery receipt")
            .diagnostics;
        assert_eq!(reconciled.workspace_operation_count, 1);
        assert_eq!(reconciled.global_operation_count, 6);

        let mut malformed_request = preflight_request.clone();
        malformed_request.operation_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_owned();
        let malformed_claim = admission
            .acquire(malformed_request, None)
            .expect("malformed claim acquire")
            .claim
            .expect("malformed execution claim");
        let malformed = CoreWorkspaceRecordedOperationV1 {
            operation_id: "not-a-uuid".to_owned(),
            ..operation.clone()
        };
        let rejected = malformed_claim
            .finalize_transient(malformed)
            .expect("semantic error response");
        assert_eq!(rejected.operation, None);
        assert_eq!(
            rejected.error_kind,
            Some(CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidOperationLedger)
        );
        malformed_claim.abandon().expect("abandon malformed claim");
        let diagnostics = admission.diagnostics().expect("unchanged diagnostics");
        assert_eq!(diagnostics.diagnostics, Some(reconciled));

        let mut mirror_request = preflight_request.clone();
        mirror_request.operation_id = "dddddddd-eeee-ffff-aaaa-bbbbbbbbbbbb".to_owned();
        let mirror_acquired = admission
            .acquire(mirror_request.clone(), None)
            .expect("mirror claim acquire");
        let mirror_claim = mirror_acquired.claim.expect("mirror execution claim");
        let mirror_operation = CoreWorkspaceRecordedOperationV1 {
            operation_id: mirror_request.operation_id.clone(),
            fingerprint: mirror_acquired
                .identity
                .expect("mirror identity")
                .fingerprint,
            before: Some(crate::types::CoreWorkspaceProjectionRevisionStateV1 {
                working_revision: 1,
                saved_revision: 1,
                dirty_revision: None,
            }),
            after: None,
            resulting_digest: None,
            ..operation
        };
        let reservation = mirror_claim
            .admission
            .bind_claim(
                &mirror_claim.inner,
                runtime::workspace_persistence_journal::WorkspaceCommandAdmissionFinalizationV1::Delete {
                    workspace_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_owned(),
                    operation: mirror_operation.clone().into(),
                },
            )
            .expect("mirror reservation");
        let (authority_directive, authority_permit) = core
            .inner
            .begin_managed_authority_operation(&mirror_claim.lifecycle)
            .expect("mirror authority");
        assert_eq!(
            authority_directive,
            runtime::ManagedOperationDirective::ContinueExecution
        );
        let authority_permit = authority_permit.expect("mirror authority permit");
        let publication = mirror_claim
            .admission
            .prepare_claimed_authority_publication(
                &mirror_claim.inner,
                runtime::workspace_context::WorkspaceProjectionPublicationKind::WorkspaceDeleted,
                &[],
                runtime::workspace_persistence_journal::WorkspaceAuthorityPublicationDraftV1 {
                    catalog_revision: 7,
                    kind: runtime::workspace_context::WorkspaceProjectionPublicationKind::WorkspaceDeleted,
                    workspace_id: Some("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_owned()),
                    context_id: None,
                    operation_id: Some(mirror_request.operation_id.clone()),
                    revisions: None,
                },
            )
            .expect("mirror publication");
        let command_result = runtime::workspace_persistence_journal::WorkspaceCommandResultV1 {
            workspace_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_owned(),
            operation: mirror_operation.clone().into(),
            disposition:
                runtime::workspace_persistence_journal::WorkspaceCommandResultDispositionV1::Deleted,
            before: mirror_operation.before.map(Into::into),
            after: mirror_operation.after.map(Into::into),
            resulting_digest: mirror_operation.resulting_digest.clone(),
            catalog_revision: mirror_operation.catalog_revision,
            publication_kind:
                runtime::workspace_context::WorkspaceProjectionPublicationKind::WorkspaceDeleted,
            context_id: None,
        };
        mirror_claim
            .lifecycle
            .resolve_terminal(runtime::TerminalOutcome::Failed)
            .expect("inject mirror terminal failure");
        assert_eq!(
            finish_workspace_command_authorities(
                &Mutex::new(None),
                &Mutex::new(None),
                &Mutex::new(None),
                None,
                None,
            ),
            CoreWorkspaceCommandAuthorityFinalizationV1 {
                command_finalization: CoreWorkspaceCommandFinalizationV1::NotApplicable,
                command_result: None,
                authority_publication: None,
            }
        );
        let reservation = Mutex::new(Some(reservation));
        let publication = Mutex::new(Some(publication));
        let publication_receipt = Mutex::new(None);
        let missing_result = finish_workspace_command_authorities(
            &reservation,
            &publication,
            &publication_receipt,
            Some(&mirror_claim),
            None,
        );
        assert_eq!(
            missing_result.command_finalization,
            CoreWorkspaceCommandFinalizationV1::Unreconciled
        );
        assert!(missing_result.command_result.is_none());
        assert!(missing_result.authority_publication.is_none());
        let finalization = finish_workspace_command_authorities(
            &reservation,
            &publication,
            &publication_receipt,
            Some(&mirror_claim),
            Some(command_result),
        );
        assert_eq!(
            finalization.command_finalization,
            CoreWorkspaceCommandFinalizationV1::Unreconciled,
            "a lifecycle mirror failure after the P5 receipt must not replace authority success"
        );
        assert!(finalization.command_result.is_none());
        assert!(finalization.authority_publication.is_some());
        drop(authority_permit);
        assert_eq!(
            admission
                .acquire(mirror_request, None)
                .expect("mirror receipt replay")
                .operation,
            Some(mirror_operation)
        );

        core.begin_shutdown(identity).expect("shutdown");
        assert!(matches!(
            admission.acquire(preflight_request, None),
            Err(CoreError::RuntimeStopped)
        ));
    }

    #[test]
    fn workspace_working_journal_validation_export_preserves_canonical_bytes_and_identity() {
        let (core, identity, _) = initialized_core();
        let journal = br#"{
            "version":1,
            "workspaceID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "fileURL":"file:///tmp/Workspace.json",
            "revisions":{"workingRevision":0,"savedRevision":0},
            "savedDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "contextRevisions":["11111111-2222-3333-4444-555555555555",{"workingRevision":0,"savedRevision":0}],
            "contextDigests":["11111111-2222-3333-4444-555555555555","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
            "contextTombstones":[],
            "operations":[],
            "updatedAt":42.5
        }"#;
        let response = core
            .workspace_working_journal_validate_v1(
                CoreWorkspaceWorkingJournalValidationRequestV1 {
                    runtime_identity: identity.clone(),
                    contract_version: runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
                    journal_bytes: journal.to_vec(),
                },
            )
            .expect("working journal validation");
        let result = response.validation.expect("valid response");
        assert_eq!(response.error_kind, None);
        assert_eq!(result.workspace_id, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
        assert_eq!(result.journal_version, 1);
        assert_eq!(result.content_digest.len(), 64);
        assert_eq!(
            core.workspace_working_journal_validate_v1(
                CoreWorkspaceWorkingJournalValidationRequestV1 {
                    runtime_identity: identity.clone(),
                    contract_version: 99,
                    journal_bytes: journal.to_vec(),
                },
            ),
            Err(CoreError::InvalidArgument)
        );
        let invalid = core
            .workspace_working_journal_validate_v1(
                CoreWorkspaceWorkingJournalValidationRequestV1 {
                    runtime_identity: identity,
                    contract_version: runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
                    journal_bytes: b"[]".to_vec(),
                },
            )
            .expect("semantic error response");
        assert_eq!(invalid.validation, None);
        assert_eq!(
            invalid.error_kind,
            Some(CoreWorkspaceWorkingJournalValidationErrorKindV1::Malformed)
        );
    }

    #[test]
    fn workspace_working_journal_seed_export_returns_one_canonical_validation() {
        let (core, identity, _) = initialized_core();
        let seed = br#"{
            "kind":"seed",
            "workspaceID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "fileURL":"file:///tmp/Workspace.json",
            "revisions":{"workingRevision":0,"savedRevision":0},
            "savedDigest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "contextDigests":[],
            "updatedAt":42.0
        }"#;
        let response = core
            .workspace_working_journal_seed_v1(CoreWorkspaceWorkingJournalSeedRequestV1 {
                runtime_identity: identity.clone(),
                contract_version: runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
                seed_request_bytes: seed.to_vec(),
            })
            .expect("working journal seed");
        assert_eq!(response.error_kind, None);
        let validation = response.validation.expect("seed validation");
        assert_eq!(
            validation.workspace_id,
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        );
        assert_eq!(validation.content_digest.len(), 64);

        let non_seed = br#"{
            "kind":"recoverPending",
            "expectedWorkspaceID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        }"#;
        let invalid = core
            .workspace_working_journal_seed_v1(CoreWorkspaceWorkingJournalSeedRequestV1 {
                runtime_identity: identity,
                contract_version: runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1,
                seed_request_bytes: non_seed.to_vec(),
            })
            .expect("semantic seed error");
        assert_eq!(invalid.validation, None);
        assert_eq!(
            invalid.error_kind,
            Some(CoreWorkspaceWorkingJournalValidationErrorKindV1::InvalidTransaction)
        );
    }

    #[test]
    fn workspace_persistence_metadata_exports_validate_and_cleanup_amendment() {
        let (core, identity, _) = initialized_core();
        let contract =
            runtime::workspace_persistence_journal::WORKSPACE_WORKING_JOURNAL_CONTRACT_VERSION_V1;
        let saved_record = br#"{
            "version":1,
            "workspaceID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "savedRevision":4,
            "documentDigest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "operationID":"66666666-7777-8888-9999-aaaaaaaaaaaa",
            "updatedAt":44.0
        }"#;
        let saved = core
            .workspace_saved_revision_validate_v1(CoreWorkspacePersistenceMetadataRequestV1 {
                runtime_identity: identity.clone(),
                contract_version: contract,
                payload_bytes: saved_record.to_vec(),
            })
            .expect("saved revision validation")
            .validation
            .expect("validated saved revision");
        assert_eq!(saved.schema_version, 1);
        assert_eq!(saved.content_digest.len(), 64);

        let tombstone_bytes = br#"{
            "version":1,
            "workspaceID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "fileURL":"file:///tmp/Workspace.json",
            "operation":{
                "operationID":"66666666-7777-8888-9999-aaaaaaaaaaaa",
                "fingerprint":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                "recordedAt":45.0,
                "disposition":"applied",
                "catalogRevision":5
            },
            "deletedAt":45.5
        }"#;
        let tombstone = core
            .workspace_deletion_tombstone_validate_v1(CoreWorkspacePersistenceMetadataRequestV1 {
                runtime_identity: identity.clone(),
                contract_version: contract,
                payload_bytes: tombstone_bytes.to_vec(),
            })
            .expect("deletion tombstone validation")
            .validation
            .expect("validated tombstone");
        assert_eq!(tombstone.schema_version, 1);
        assert_eq!(tombstone.content_digest.len(), 64);

        let seed_transition = br#"{
            "kind":"seed",
            "entries":[{
                "workspaceID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "fileURL":"file:///tmp/Workspace.json"
            }],
            "updatedAt":46.0
        }"#;
        let catalog = core
            .workspace_catalog_seed_v1(CoreWorkspaceCatalogSeedRequestV1 {
                runtime_identity: identity.clone(),
                contract_version: contract,
                seed_request_bytes: seed_transition.to_vec(),
            })
            .expect("catalog seed")
            .validation
            .expect("catalog validation");
        assert_eq!(catalog.revision, 0);
        assert_eq!(catalog.entry_count, 1);
        let validated_catalog = core
            .workspace_catalog_validate_v1(CoreWorkspaceCatalogValidationRequestV1 {
                runtime_identity: identity,
                contract_version: contract,
                catalog_bytes: catalog.canonical_bytes.clone(),
            })
            .expect("catalog validate")
            .validation
            .expect("validated catalog");
        assert_eq!(catalog, validated_catalog);
    }

    fn search_score_request(
        identity: RuntimeIdentity,
        contract_version: u16,
    ) -> CoreSearchScoreBatchRequestV1 {
        CoreSearchScoreBatchRequestV1 {
            runtime_identity: identity,
            contract_version,
            candidates: vec![
                crate::types::CoreSearchScoreCandidateV1 {
                    name: b"readme.md".to_vec(),
                    path: b"docs/readme.md".to_vec(),
                    name_lower: b"readme.md".to_vec(),
                    path_lower: b"docs/readme.md".to_vec(),
                },
                crate::types::CoreSearchScoreCandidateV1 {
                    name: b"reader.txt".to_vec(),
                    path: b"docs/reader.txt".to_vec(),
                    name_lower: b"reader.txt".to_vec(),
                    path_lower: b"docs/reader.txt".to_vec(),
                },
            ],
            query: crate::types::CoreSearchScoreQueryV1 {
                raw: b"readme".to_vec(),
                lowered: b"readme".to_vec(),
                has_slash: false,
                is_wildcard: false,
            },
            fuzzy_threshold: 0.8,
        }
    }

    #[test]
    fn search_score_batch_v1_preserves_count_order_and_embedded_nul() {
        let (core, identity, _) = initialized_core();
        let result = core
            .search_score_batch_v1(search_score_request(
                identity.clone(),
                runtime::searchscore::SEARCH_SCORE_CONTRACT_VERSION_V1,
            ))
            .expect("search-score export");
        assert_eq!(result.scores, vec![1000, 0]);

        let mut nul_request = search_score_request(
            identity,
            runtime::searchscore::SEARCH_SCORE_CONTRACT_VERSION_V1,
        );
        nul_request.query.raw = b"read\0ignored".to_vec();
        nul_request.query.lowered = b"read\0ignored".to_vec();
        assert_eq!(
            core.search_score_batch_v1(nul_request)
                .expect("embedded-NUL search-score export")
                .scores,
            vec![900, 900]
        );
    }

    #[test]
    fn search_score_batch_v1_rejects_invalid_contract_and_stale_identity() {
        let (core, identity, _) = initialized_core();
        assert_eq!(
            core.search_score_batch_v1(search_score_request(identity.clone(), 2)),
            Err(CoreError::InvalidArgument)
        );

        let stale_runtime_identity = runtime::RuntimeIdentity::fresh(
            &identity.build_fingerprint,
            &identity.binding_checksum,
        )
        .expect("fresh stale identity");
        let stale_identity = RuntimeIdentity::from(&stale_runtime_identity);
        assert_eq!(
            core.search_score_batch_v1(search_score_request(
                stale_identity,
                runtime::searchscore::SEARCH_SCORE_CONTRACT_VERSION_V1,
            )),
            Err(CoreError::StaleRuntimeIdentity)
        );
    }

    #[test]
    fn compact_compute_exports_round_trip() {
        let (core, identity, cancellation) = initialized_core();
        let codemap = core
            .code_map_extract_batch_compact_v1(CoreCodeMapBatchRequestV1 {
                runtime_identity: identity.clone(),
                cancellation: Arc::clone(&cancellation),
                contract_version: runtime::codemap::CODEMAP_CONTRACT_VERSION_V1,
                subjects: vec![CoreCodeMapSubjectRequestV1 {
                    language_id: runtime::codemap::CodeMapLanguage::Swift.id(),
                    source_kind: CoreCodeMapSourceKindV1::Decoded,
                    source_utf8: b"struct Example { let value: Int }".to_vec(),
                }],
            })
            .expect("codemap compact export");
        assert_eq!(codemap.subject_summaries.len(), 1);
        assert!(!codemap.string_range_words.is_empty());

        let apply = core
            .apply_edits_batch_compact_v1(CoreApplyEditsBatchRequestV1 {
                runtime_identity: identity,
                cancellation,
                contract_version: runtime::apply_edits::APPLY_EDITS_CONTRACT_VERSION_V1,
                subjects: vec![CoreApplyEditsSubjectRequestV1 {
                    path_label: "Example.swift".to_owned(),
                    original_utf8: b"old\n".to_vec(),
                    source_kind: crate::types::CoreApplyEditsSourceKindV1::DecodedUtf8,
                    mode_tag: 0,
                    rewrite_replacement: Some("new\n".to_owned()),
                    operations: Vec::new(),
                    verbose: true,
                    include_tool_card_unified_diff: true,
                }],
            })
            .expect("apply-edits compact export");
        assert_eq!(apply.subject_summaries.len(), 1);
        assert_eq!(apply.subject_summaries[0].edits_applied, 1);
        assert!(!apply.byte_edit_words.is_empty());
    }

    #[test]
    fn compact_compute_exports_classify_cancellation() {
        let (core, identity, cancellation) = initialized_core();
        cancellation
            .cancel(identity.clone())
            .expect("cancel leaf computation");
        let codemap = core.code_map_extract_batch_compact_v1(CoreCodeMapBatchRequestV1 {
            runtime_identity: identity.clone(),
            cancellation: Arc::clone(&cancellation),
            contract_version: runtime::codemap::CODEMAP_CONTRACT_VERSION_V1,
            subjects: vec![CoreCodeMapSubjectRequestV1 {
                language_id: runtime::codemap::CodeMapLanguage::Swift.id(),
                source_kind: CoreCodeMapSourceKindV1::Decoded,
                source_utf8: b"struct Example {}".to_vec(),
            }],
        });
        assert_eq!(codemap, Err(CoreError::CodeMapCancelled));

        let apply = core.apply_edits_batch_compact_v1(CoreApplyEditsBatchRequestV1 {
            runtime_identity: identity,
            cancellation,
            contract_version: runtime::apply_edits::APPLY_EDITS_CONTRACT_VERSION_V1,
            subjects: vec![CoreApplyEditsSubjectRequestV1 {
                path_label: "Example.swift".to_owned(),
                original_utf8: b"old\n".to_vec(),
                source_kind: crate::types::CoreApplyEditsSourceKindV1::DecodedUtf8,
                mode_tag: 0,
                rewrite_replacement: Some("new\n".to_owned()),
                operations: Vec::new(),
                verbose: false,
                include_tool_card_unified_diff: false,
            }],
        });
        assert_eq!(apply, Err(CoreError::ApplyEditsCancelled));
    }

    #[test]
    fn compact_compute_exports_classify_invalid_requests() {
        let (core, identity, cancellation) = initialized_core();
        let codemap = core.code_map_extract_batch_compact_v1(CoreCodeMapBatchRequestV1 {
            runtime_identity: identity.clone(),
            cancellation: Arc::clone(&cancellation),
            contract_version: 2,
            subjects: Vec::new(),
        });
        assert_eq!(codemap, Err(CoreError::CodeMapInvalidRequest));

        let apply = core.apply_edits_batch_compact_v1(CoreApplyEditsBatchRequestV1 {
            runtime_identity: identity,
            cancellation,
            contract_version: runtime::apply_edits::APPLY_EDITS_CONTRACT_VERSION_V1,
            subjects: vec![CoreApplyEditsSubjectRequestV1 {
                path_label: "Example.swift".to_owned(),
                original_utf8: b"old\n".to_vec(),
                source_kind: crate::types::CoreApplyEditsSourceKindV1::DecodedUtf8,
                mode_tag: 2,
                rewrite_replacement: None,
                operations: Vec::new(),
                verbose: false,
                include_tool_card_unified_diff: false,
            }],
        });
        assert_eq!(
            apply,
            Err(CoreError::ApplyEditsInvalidParams {
                message: "invalid apply-edits request".into(),
            })
        );
    }

    #[test]
    fn apply_edits_invalid_params_preserves_runtime_message() {
        let (core, identity, cancellation) = initialized_core();
        let apply = core.apply_edits_batch_compact_v1(CoreApplyEditsBatchRequestV1 {
            runtime_identity: identity,
            cancellation,
            contract_version: runtime::apply_edits::APPLY_EDITS_CONTRACT_VERSION_V1,
            subjects: vec![CoreApplyEditsSubjectRequestV1 {
                path_label: "Example.swift".to_owned(),
                original_utf8: b"present\n".to_vec(),
                source_kind: crate::types::CoreApplyEditsSourceKindV1::DecodedUtf8,
                mode_tag: 1,
                rewrite_replacement: None,
                operations: vec![crate::types::CoreApplyEditsOperationV1 {
                    search: "missing".into(),
                    replace: "replacement".into(),
                    replace_all: false,
                }],
                verbose: false,
                include_tool_card_unified_diff: false,
            }],
        });
        assert_eq!(
            apply,
            Err(CoreError::ApplyEditsInvalidParams {
                message: "search block not found in file".into(),
            })
        );
    }

    #[test]
    fn path_search_find_v1_round_trips_find_and_projected_queries() {
        let (core, identity, cancellation) = initialized_core();
        let mut request = crate::types::CorePathSearchFindRequestV1 {
            runtime_identity: identity,
            cancellation,
            contract_version: runtime::pathsearch::PATH_SEARCH_CONTRACT_VERSION_V1,
            utf8_blob: Vec::new(),
            string_range_words: Vec::new(),
            corpus_path_indices: Vec::new(),
            query_words: Vec::new(),
        };
        let mut runtime_request = runtime::pathsearch::PathSearchFindRequestV1::default();
        runtime_request.push_corpus_path("a/App.swift");
        runtime_request.push_corpus_path("b/App.swift");
        runtime_request.push_find_query("App.swift", 10);
        request.utf8_blob = runtime_request.utf8_blob;
        request.string_range_words = runtime_request.string_range_words;
        request.corpus_path_indices = runtime_request.corpus_path_indices;
        request.query_words = runtime_request.query_words;

        let result = core
            .path_search_find_v1(request)
            .expect("path-search compact export");
        assert_eq!(result.result_ordinals, vec![0, 1]);
        assert_eq!(result.result_range_words, vec![0, 2]);
        assert_eq!(result.stats_words, vec![0; 5]);
    }

    #[test]
    fn path_search_find_v1_classifies_cancellation_and_invalid_requests() {
        let (core, identity, cancellation) = initialized_core();
        cancellation
            .cancel(identity.clone())
            .expect("cancel leaf computation");
        let cancelled = core.path_search_find_v1(crate::types::CorePathSearchFindRequestV1 {
            runtime_identity: identity.clone(),
            cancellation: Arc::clone(&cancellation),
            contract_version: runtime::pathsearch::PATH_SEARCH_CONTRACT_VERSION_V1,
            utf8_blob: Vec::new(),
            string_range_words: Vec::new(),
            corpus_path_indices: Vec::new(),
            query_words: Vec::new(),
        });
        assert_eq!(cancelled, Err(CoreError::PathSearchCancelled));

        let (core, identity, cancellation) = initialized_core();
        let invalid = core.path_search_find_v1(crate::types::CorePathSearchFindRequestV1 {
            runtime_identity: identity,
            cancellation,
            contract_version: 2,
            utf8_blob: Vec::new(),
            string_range_words: Vec::new(),
            corpus_path_indices: Vec::new(),
            query_words: Vec::new(),
        });
        assert_eq!(
            invalid,
            Err(CoreError::PathSearchInvalidRequest {
                message: "unknown contract version 2".into(),
            })
        );
    }

    #[test]
    fn token_accounting_v1_round_trips_one_entry_and_one_component_row() {
        let (core, identity, cancellation) = initialized_core();
        let mut runtime_request = runtime::tokenacct::TokenAccountingRequestV1::default();
        runtime_request.contract_version = runtime::tokenacct::TOKEN_ACCOUNTING_CONTRACT_VERSION_V1;
        runtime_request.push_content_entry(0, None, Some(("hello world", 11)), None, "src/a.swift");
        runtime_request.push_component("prompt text", "", "", "", "", false);

        let request = crate::types::CoreTokenAccountingRequestV1 {
            runtime_identity: identity,
            cancellation,
            contract_version: runtime_request.contract_version,
            utf8_blob: runtime_request.utf8_blob,
            string_range_words: runtime_request.string_range_words,
            entry_words: runtime_request.entry_words,
            component_words: runtime_request.component_words,
        };

        let result = core
            .token_accounting_v1(request)
            .expect("token-accounting compact export");
        assert_eq!(result.entry_result_words[0], 0, "render_mode full");
        assert!(result.component_result_words[0] > 0, "prompt tokens");
        assert_eq!(result.folder_names, vec!["src".to_owned()]);
    }

    #[test]
    fn token_accounting_v1_classifies_cancellation_and_invalid_requests() {
        let (core, identity, cancellation) = initialized_core();
        cancellation
            .cancel(identity.clone())
            .expect("cancel leaf computation");
        let cancelled = core.token_accounting_v1(crate::types::CoreTokenAccountingRequestV1 {
            runtime_identity: identity.clone(),
            cancellation: Arc::clone(&cancellation),
            contract_version: runtime::tokenacct::TOKEN_ACCOUNTING_CONTRACT_VERSION_V1,
            utf8_blob: Vec::new(),
            string_range_words: Vec::new(),
            entry_words: Vec::new(),
            component_words: Vec::new(),
        });
        assert_eq!(cancelled, Err(CoreError::TokenAccountingCancelled));

        let (core, identity, cancellation) = initialized_core();
        let invalid = core.token_accounting_v1(crate::types::CoreTokenAccountingRequestV1 {
            runtime_identity: identity,
            cancellation,
            contract_version: 2,
            utf8_blob: Vec::new(),
            string_range_words: Vec::new(),
            entry_words: Vec::new(),
            component_words: Vec::new(),
        });
        assert_eq!(
            invalid,
            Err(CoreError::TokenAccountingInvalidRequest {
                message: "unknown contract version 2".into(),
            })
        );
    }

    // ============================================================================================
    // P4-4: end-to-end inventory-scope-v1 FFI surface tests. Exercises every export added in this
    // step through the real UniFFI-facing `CoreRuntime` methods (not the underlying
    // `agentry_runtime::inventory_scope` API directly), so a wire-encoding or FFI-glue bug here is
    // caught before the Swift bridge exists to catch it a second time.
    // ============================================================================================

    fn sample_file(
        seed: u8,
        root_id: [u8; 16],
        relative_path: &str,
        name: &str,
    ) -> runtime::inventory::InventoryFileRecord {
        runtime::inventory::InventoryFileRecord {
            id: [seed; 16],
            root_id,
            name: name.to_owned(),
            relative_path: relative_path.to_owned(),
            standardized_relative_path: relative_path.to_owned(),
            full_path: format!("/repo/{relative_path}"),
            standardized_full_path: format!("/repo/{relative_path}"),
            parent_folder_id: None,
            modification_date: None,
        }
    }

    fn sample_folder(
        seed: u8,
        root_id: [u8; 16],
        relative_path: &str,
    ) -> runtime::inventory::InventoryFolderRecord {
        runtime::inventory::InventoryFolderRecord {
            id: [seed; 16],
            root_id,
            name: relative_path.to_owned(),
            relative_path: relative_path.to_owned(),
            standardized_relative_path: relative_path.to_owned(),
            full_path: format!("/repo/{relative_path}"),
            standardized_full_path: format!("/repo/{relative_path}"),
            parent_folder_id: None,
            modification_date: None,
        }
    }

    #[test]
    fn inventory_snapshot_page_continues_through_a_folder_only_exact_multiple() {
        let (core, identity, _cancellation) = initialized_core();
        let root_id = vec![9u8; 16];
        let scope = core
            .inventory_open_scope(
                identity.clone(),
                CoreInventoryScopeConfigV1 {
                    live_generation_cap: 8,
                    max_patch_logical_mutation_count: 1,
                    codemap_capable_extensions: Vec::new(),
                },
            )
            .expect("open scope");
        let lifetime = core
            .inventory_open_root(InventoryRootOpenV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                name: "root".to_owned(),
                standardized_full_path: "/repo".to_owned(),
            })
            .expect("open root");
        let bulk_load_id = core
            .inventory_begin_bulk_load(
                identity.clone(),
                scope.scope_id.clone(),
                root_id.clone(),
                lifetime.root_lifetime_id,
            )
            .expect("begin bulk load");
        let files = Vec::new();
        let folders = vec![
            sample_folder(1, [9; 16], "A"),
            sample_folder(2, [9; 16], "B"),
            sample_folder(3, [9; 16], "C"),
            sample_folder(4, [9; 16], "D"),
        ];
        core.inventory_push_bulk_chunk(
            identity.clone(),
            scope.scope_id.clone(),
            bulk_load_id,
            root_id.clone(),
            runtime::inventory_scope::encode_bulk_chunk(&files, &folders),
        )
        .expect("push bulk chunk");
        core.inventory_commit_bulk_load(
            identity.clone(),
            scope.scope_id.clone(),
            bulk_load_id,
            InventoryPublishModeV1::AtomicPublish,
        )
        .expect("commit bulk load");
        let snapshot = core
            .inventory_open_snapshot(InventorySnapshotRequestV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id,
            })
            .expect("open snapshot");

        let first = core
            .inventory_snapshot_page(
                identity.clone(),
                scope.scope_id.clone(),
                snapshot.handle_id,
                0,
                2,
            )
            .expect("first snapshot page");
        let (first_files, first_folders) =
            runtime::inventory_scope::decode_bulk_chunk(&first.bytes).expect("decode first page");
        assert!(first_files.is_empty());
        assert_eq!(first_folders.len(), 2);
        assert_eq!(first.returned_count, 2);
        assert!(first.has_more);

        let second = core
            .inventory_snapshot_page(
                identity.clone(),
                scope.scope_id.clone(),
                snapshot.handle_id,
                first.returned_count,
                2,
            )
            .expect("second snapshot page");
        let (second_files, second_folders) =
            runtime::inventory_scope::decode_bulk_chunk(&second.bytes).expect("decode second page");
        assert!(second_files.is_empty());
        assert_eq!(second_folders.len(), 2);
        assert_eq!(second.returned_count, 2);
        assert!(
            second.has_more,
            "an exact multiple requires one final empty probe"
        );

        let third = core
            .inventory_snapshot_page(
                identity,
                scope.scope_id,
                snapshot.handle_id,
                first.returned_count + second.returned_count,
                2,
            )
            .expect("final empty snapshot page");
        let (third_files, third_folders) =
            runtime::inventory_scope::decode_bulk_chunk(&third.bytes).expect("decode final page");
        assert!(third_files.is_empty());
        assert!(third_folders.is_empty());
        assert_eq!(third.returned_count, 0);
        assert!(!third.has_more);
    }

    #[test]
    fn inventory_composed_snapshot_round_trips_bounded_pages_and_idempotent_close() {
        let (core, identity, _cancellation) = initialized_core();
        let scope = core
            .inventory_open_scope(
                identity.clone(),
                CoreInventoryScopeConfigV1 {
                    live_generation_cap: 8,
                    max_patch_logical_mutation_count: 1,
                    codemap_capable_extensions: Vec::new(),
                },
            )
            .expect("open scope");

        let ordinary_root_id = vec![7u8; 16];
        let mut descriptors = Vec::new();
        for (root_seed, relative_path) in [(7u8, "B.swift"), (8u8, "A.swift")] {
            let root_id = vec![root_seed; 16];
            let lifetime = core
                .inventory_open_root(InventoryRootOpenV1 {
                    runtime_identity: identity.clone(),
                    scope_id: scope.scope_id.clone(),
                    root_id: root_id.clone(),
                    name: format!("root-{root_seed}"),
                    standardized_full_path: format!("/repo-{root_seed}"),
                })
                .expect("open root");
            let bulk_load_id = core
                .inventory_begin_bulk_load(
                    identity.clone(),
                    scope.scope_id.clone(),
                    root_id.clone(),
                    lifetime.root_lifetime_id.clone(),
                )
                .expect("begin bulk load");
            core.inventory_push_bulk_chunk(
                identity.clone(),
                scope.scope_id.clone(),
                bulk_load_id,
                root_id.clone(),
                runtime::inventory_scope::encode_bulk_chunk(
                    &[sample_file(
                        root_seed.wrapping_add(20),
                        [root_seed; 16],
                        relative_path,
                        relative_path,
                    )],
                    &[],
                ),
            )
            .expect("push bulk chunk");
            let generation = core
                .inventory_commit_bulk_load(
                    identity.clone(),
                    scope.scope_id.clone(),
                    bulk_load_id,
                    InventoryPublishModeV1::AtomicPublish,
                )
                .expect("commit bulk load");
            descriptors.push(crate::types::InventoryComposedRootDescriptorV1 {
                root_id,
                root_lifetime_id: lifetime.root_lifetime_id,
                expected_generation: Some(generation.generation),
            });
        }

        let composed = core
            .inventory_open_composed_snapshot(InventoryComposedSnapshotRequestV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                roots: descriptors,
                accounting: crate::types::InventoryCompositionAccountingV1::NormalPresentation,
            })
            .expect("open composed snapshot");
        assert_eq!(composed.row_count, 2);

        let ordinary = core
            .inventory_open_snapshot(InventorySnapshotRequestV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: ordinary_root_id,
            })
            .expect("open ordinary snapshot");
        assert_ne!(
            ordinary.handle_id, composed.handle_id,
            "ordinary and composed handles must occupy disjoint raw-ID namespaces"
        );
        core.inventory_composed_snapshot_page(
            identity.clone(),
            scope.scope_id.clone(),
            ordinary.handle_id,
            0,
            1,
        )
        .expect_err("ordinary handle must fail closed at composed page API");
        core.inventory_snapshot_page(
            identity.clone(),
            scope.scope_id.clone(),
            composed.handle_id,
            0,
            1,
        )
        .expect_err("composed handle must fail closed at ordinary page API");

        let first = core
            .inventory_composed_snapshot_page(
                identity.clone(),
                scope.scope_id.clone(),
                composed.handle_id,
                0,
                1,
            )
            .expect("first composed page");
        let (first_files, first_folders) =
            runtime::inventory_scope::decode_bulk_chunk(&first.bytes).expect("decode first page");
        assert_eq!(first_files[0].standardized_relative_path, "A.swift");
        assert!(first_folders.is_empty());
        assert_eq!(first.returned_count, 1);
        assert!(first.has_more);

        let second = core
            .inventory_composed_snapshot_page(
                identity,
                scope.scope_id.clone(),
                composed.handle_id,
                1,
                1,
            )
            .expect("second composed page");
        let (second_files, second_folders) =
            runtime::inventory_scope::decode_bulk_chunk(&second.bytes).expect("decode second page");
        assert_eq!(second_files[0].standardized_relative_path, "B.swift");
        assert!(second_folders.is_empty());
        assert_eq!(second.returned_count, 1);
        assert!(
            !second.has_more,
            "composed pages know the exact artifact length"
        );

        core.inventory_close_snapshot(scope.scope_id.clone(), ordinary.handle_id)
            .expect("close ordinary snapshot");
        core.inventory_close_composed_snapshot(scope.scope_id.clone(), composed.handle_id)
            .expect("close composed snapshot");
        core.inventory_close_composed_snapshot(scope.scope_id, composed.handle_id)
            .expect("closing composed snapshot twice is idempotent");
    }

    #[test]
    fn inventory_scope_full_lifecycle_round_trips_through_the_ffi_surface() {
        let (core, identity, _cancellation) = initialized_core();
        let root_id = vec![9u8; 16];

        let scope = core
            .inventory_open_scope(
                identity.clone(),
                CoreInventoryScopeConfigV1 {
                    live_generation_cap: 8,
                    max_patch_logical_mutation_count: 1,
                    codemap_capable_extensions: vec!["swift".to_owned()],
                },
            )
            .expect("open scope");

        let lifetime = core
            .inventory_open_root(InventoryRootOpenV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                name: "root".to_owned(),
                standardized_full_path: "/repo".to_owned(),
            })
            .expect("open root");

        // Bulk load two files, one of which is codemap-capable (`.swift`).
        let bulk_load_id = core
            .inventory_begin_bulk_load(
                identity.clone(),
                scope.scope_id.clone(),
                root_id.clone(),
                lifetime.root_lifetime_id.clone(),
            )
            .expect("begin bulk load");
        let files = vec![
            sample_file(1, [9; 16], "App.swift", "App.swift"),
            sample_file(2, [9; 16], "README.md", "README.md"),
        ];
        let chunk_bytes = runtime::inventory_scope::encode_bulk_chunk(&files, &[]);
        let chunk_receipt = core
            .inventory_push_bulk_chunk(
                identity.clone(),
                scope.scope_id.clone(),
                bulk_load_id,
                root_id.clone(),
                chunk_bytes,
            )
            .expect("push bulk chunk");
        assert_eq!(chunk_receipt.files_staged, 2);
        assert_eq!(chunk_receipt.folders_staged, 0);

        let generation_receipt = core
            .inventory_commit_bulk_load(
                identity.clone(),
                scope.scope_id.clone(),
                bulk_load_id,
                InventoryPublishModeV1::AtomicPublish,
            )
            .expect("commit bulk load");
        assert_eq!(generation_receipt.generation, 0);

        // Read plane: open a snapshot, page it, and see both files.
        let snapshot = core
            .inventory_open_snapshot(InventorySnapshotRequestV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
            })
            .expect("open snapshot");
        assert_eq!(snapshot.generation, 0);

        let page = core
            .inventory_snapshot_page(
                identity.clone(),
                scope.scope_id.clone(),
                snapshot.handle_id,
                0,
                10,
            )
            .expect("snapshot page");
        let (paged_files, paged_folders) =
            runtime::inventory_scope::decode_bulk_chunk(&page.bytes).expect("decode page");
        assert_eq!(paged_files.len(), 2);
        assert!(paged_folders.is_empty());
        assert_eq!(page.returned_count, 2);
        assert!(!page.has_more);

        // inventoryLookupPaths via the open handle.
        let lookup_bytes = runtime::inventory_scope::encode_lookup_request(&[
            "App.swift".to_owned(),
            "missing.swift".to_owned(),
        ]);
        let lookup_result = core
            .inventory_lookup_paths(
                identity.clone(),
                scope.scope_id.clone(),
                snapshot.handle_id,
                lookup_bytes,
            )
            .expect("lookup paths");
        let lookup_block = runtime::inventory_scope::decode_fact_block(&lookup_result.bytes)
            .expect("decode lookup block");
        assert_eq!(lookup_block.generation, Some(0));
        assert!(lookup_block.rows[0].exists);
        assert_eq!(lookup_block.rows[0].name.as_deref(), Some("App.swift"));
        assert!(!lookup_block.rows[1].exists);

        // inventoryQuery (IndexKey variant) via the same handle.
        // Leading+trailing star: the index key is `displayPath + "\n" + standardizedFullPath`
        // (`path_search_index_key`), so a bare "App" prefix would only match a key that starts
        // with it -- our display path is prefixed with the root name ("root/App.swift..."). An
        // explicit `*App*` matches anywhere in the composed key regardless of anchoring.
        let query_bytes =
            runtime::inventory_scope::encode_query_request("*App*", 10, 0, "root/", "root", None);
        let query_result = core
            .inventory_query(CompactQueryV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                handle_id: snapshot.handle_id,
                bytes: query_bytes,
            })
            .expect("query");
        let (query_generation, candidates) =
            runtime::inventory_scope::decode_query_response(&query_result.bytes)
                .expect("decode query response");
        assert_eq!(query_generation, Some(0));
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].name, "App.swift");

        // inventoryResolveRecords (scope+root, live truth, not handle-based).
        let resolve_bytes =
            runtime::inventory_scope::encode_resolve_request(&[[1u8; 16], [99u8; 16]], &[]);
        let resolve_result = core
            .inventory_resolve_records(InventoryResolveRequestV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                expected_catalog_generation: None,
                bytes: resolve_bytes,
            })
            .expect("resolve records");
        let resolve_block = runtime::inventory_scope::decode_fact_block(&resolve_result.bytes)
            .expect("decode resolve block");
        assert_eq!(resolve_block.generation, Some(0));
        assert!(resolve_block.rows[0].exists);
        assert!(!resolve_block.rows[1].exists);

        // A stale `expected_catalog_generation` produces a whole-block stale outcome, not an error.
        let resolve_bytes_stale =
            runtime::inventory_scope::encode_resolve_request(&[[1u8; 16]], &[]);
        let stale_result = core
            .inventory_resolve_records(InventoryResolveRequestV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                expected_catalog_generation: Some(999),
                bytes: resolve_bytes_stale,
            })
            .expect("resolve records (stale)");
        let stale_block = runtime::inventory_scope::decode_fact_block(&stale_result.bytes)
            .expect("decode stale block");
        assert_eq!(stale_block.generation, None);
        assert!(stale_block.rows.is_empty());

        // inventoryOpenProjectedShard (B2): only the `.swift` file is codemap-capable.
        let shard = core
            .inventory_open_projected_shard(InventoryProjectedShardRequestV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
            })
            .expect("open projected shard");
        let shard_page = core
            .inventory_snapshot_page(
                identity.clone(),
                scope.scope_id.clone(),
                shard.handle_id,
                0,
                10,
            )
            .expect("shard page");
        let (shard_files, _) = runtime::inventory_scope::decode_bulk_chunk(&shard_page.bytes)
            .expect("decode shard page");
        assert_eq!(shard_files.len(), 1);
        assert_eq!(shard_files[0].name, "App.swift");

        // Ingest: apply a delta adding a third file, then diagnostics reflect it.
        let event = runtime::inventory::InventoryAppliedIndexBatchEvent {
            root_id: [9; 16],
            upserted_files: vec![sample_file(3, [9; 16], "Extra.swift", "Extra.swift")],
            upserted_folders: Vec::new(),
            removed_file_ids: Vec::new(),
            removed_folder_ids: Vec::new(),
            removed_file_paths: Vec::new(),
            removed_folder_paths: Vec::new(),
            modified_file_ids: Vec::new(),
            modified_folder_ids: Vec::new(),
        };
        let delta_receipt = core
            .inventory_apply_delta_v1(InventoryDeltaCommandV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                root_lifetime_id: lifetime.root_lifetime_id.clone(),
                watcher_accepted_watermark: None,
                requires_full_resync: false,
                // `commit_bulk_load` already advanced `last_applied_index_generation` to 1
                // (contract §5.1's D-4 "one owner mutates maps and tables in one critical
                // section"); `None` bypasses the optional generation-gap check entirely rather
                // than asserting a value this test doesn't otherwise need to pin.
                expected_applied_index_generation: None,
                source: "test".to_owned(),
                event_bytes: runtime::inventory_scope::encode_delta_event(&event),
            })
            .expect("apply delta");
        assert!(matches!(
            delta_receipt.outcome,
            InventoryApplyOutcomeV1::Patched | InventoryApplyOutcomeV1::RebuiltAuthoritative
        ));
        // 1 (bulk-load commit) + 1 (this delta) = 2.
        assert_eq!(delta_receipt.applied_index_generation, 2);

        let diagnostics = core
            .inventory_scope_diagnostics(identity.clone(), scope.scope_id.clone())
            .expect("diagnostics");
        assert_eq!(diagnostics.roots.len(), 1);
        assert!(diagnostics.roots[0].build_count >= 2);

        // A read against the (now-closed-by-a-later-generation) old snapshot handle must still
        // resolve -- open handles are never invalidated by a mutation, only by root/scope
        // close or identity change (§4 layer 2/3).
        let old_page = core
            .inventory_snapshot_page(
                identity.clone(),
                scope.scope_id.clone(),
                snapshot.handle_id,
                0,
                10,
            )
            .expect("old snapshot handle still readable");
        let (old_files, _) =
            runtime::inventory_scope::decode_bulk_chunk(&old_page.bytes).expect("decode");
        assert_eq!(
            old_files.len(),
            2,
            "the old handle keeps seeing its own frozen generation"
        );

        // Close everything; every close is idempotent, and closing the root invalidates the
        // remaining open handles (a subsequent page read is a typed `HandleInvalidated` error,
        // not a panic).
        core.inventory_close_snapshot(scope.scope_id.clone(), snapshot.handle_id)
            .expect("close snapshot");
        core.inventory_close_snapshot(scope.scope_id.clone(), snapshot.handle_id)
            .expect("closing twice is idempotent");

        let unload_receipt = core
            .inventory_close_root(
                identity.clone(),
                scope.scope_id.clone(),
                root_id.clone(),
                lifetime.root_lifetime_id.clone(),
            )
            .expect("close root");
        assert_eq!(unload_receipt.final_generation, Some(1));

        let after_close = core.inventory_snapshot_page(
            identity.clone(),
            scope.scope_id.clone(),
            shard.handle_id,
            0,
            10,
        );
        assert_eq!(
            after_close,
            Err(CoreError::InventoryHandleInvalidated {
                reason: InventoryHandleInvalidationReasonV1::RootClosed,
            })
        );

        core.inventory_close_scope(identity.clone(), scope.scope_id.clone())
            .expect("close scope");
        core.inventory_close_scope(identity, scope.scope_id)
            .expect("closing twice is idempotent");
    }

    #[test]
    fn inventory_scope_events_flow_through_the_generic_subscription_surface() {
        // P4-4b done-when: "ffi round-trip (subscribe -> mutate -> drain -> events match
        // mutations)". Deliberately reuses the exact same `open_subscription`/`try_drain`
        // exports every other P0 consumer uses (`close_and_shutdown_are_idempotent` above) --
        // the whole point of P4-4b's FFI surface is that no new subscribe/drain export exists;
        // only `InventoryScopeHandleV1.subscription_scope_id` is new.
        let (core, identity, _cancellation) = initialized_core();
        let scope = core
            .inventory_open_scope(
                identity.clone(),
                CoreInventoryScopeConfigV1 {
                    live_generation_cap: 8,
                    max_patch_logical_mutation_count: 1,
                    codemap_capable_extensions: Vec::new(),
                },
            )
            .expect("open scope");

        // Subscribe before any mutation so nothing publishes before the queue exists.
        let subscription = core
            .open_subscription(SubscriptionScope {
                runtime_identity: identity.clone(),
                scope_id: crate::types::ScopeId {
                    value: scope.subscription_scope_id.clone(),
                },
                max_queued_events: 0,
                max_queued_bytes: 0,
            })
            .expect("open subscription against the derived subscription_scope_id")
            .subscription_id;

        let root_id = vec![4u8; 16];
        let lifetime = core
            .inventory_open_root(InventoryRootOpenV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                name: "root".to_owned(),
                standardized_full_path: "/repo".to_owned(),
            })
            .expect("open root");

        let event = runtime::inventory::InventoryAppliedIndexBatchEvent {
            root_id: [4; 16],
            upserted_files: vec![sample_file(1, [4; 16], "A.swift", "A.swift")],
            upserted_folders: Vec::new(),
            removed_file_ids: Vec::new(),
            removed_folder_ids: Vec::new(),
            removed_file_paths: Vec::new(),
            removed_folder_paths: Vec::new(),
            modified_file_ids: Vec::new(),
            modified_folder_ids: Vec::new(),
        };
        let delta_receipt = core
            .inventory_apply_delta_v1(InventoryDeltaCommandV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                root_lifetime_id: lifetime.root_lifetime_id.clone(),
                watcher_accepted_watermark: None,
                requires_full_resync: true,
                expected_applied_index_generation: None,
                source: "test".to_owned(),
                event_bytes: runtime::inventory_scope::encode_delta_event(&event),
            })
            .expect("apply delta");
        assert_eq!(
            delta_receipt.outcome,
            InventoryApplyOutcomeV1::RebuiltAuthoritative
        );

        let DrainBatch { events, .. } = core
            .try_drain(subscription.clone(), 16, 65_536)
            .expect("drain");
        // open_root -> RootPublished; apply_delta (fresh root, full resync) -> ShardFallback,
        // generationAdvanced, appliedIndexBatch.
        assert_eq!(events.len(), 4);
        let generation_advanced =
            runtime::inventory_scope::decode_generation_advanced(&events[2].payload)
                .expect("decode generationAdvanced");
        assert_eq!(generation_advanced.root_id, [4; 16]);
        assert_eq!(
            generation_advanced.applied_index_generation,
            delta_receipt.applied_index_generation
        );
        assert_eq!(
            generation_advanced.catalog_generation,
            delta_receipt.catalog_generation
        );
        assert!(generation_advanced.rebuilt_authoritative);

        let applied_index_batch = runtime::inventory_scope::decode_delta_event(&events[3].payload)
            .expect("decode appliedIndexBatch");
        assert_eq!(applied_index_batch.upserted_files.len(), 1);
        assert_eq!(applied_index_batch.upserted_files[0].name, "A.swift");

        core.close_subscription(subscription)
            .expect("close subscription");
    }

    #[test]
    fn inventory_scope_overflow_produces_a_gap_then_a_fresh_snapshot_still_recovers() {
        // P4-4b done-when: end-to-end "drive a real overflow -> gap marker -> resnapshot
        // recovery through the FFI" proof (the Swift-layer half of this same proof lives in
        // `Tests/AgentryCoreBridgeTests`).
        let (core, identity, _cancellation) = initialized_core();
        let scope = core
            .inventory_open_scope(
                identity.clone(),
                CoreInventoryScopeConfigV1 {
                    live_generation_cap: 8,
                    max_patch_logical_mutation_count: 1,
                    codemap_capable_extensions: Vec::new(),
                },
            )
            .expect("open scope");
        let subscription = core
            .open_subscription(SubscriptionScope {
                runtime_identity: identity.clone(),
                scope_id: crate::types::ScopeId {
                    value: scope.subscription_scope_id.clone(),
                },
                max_queued_events: 4, // tiny: 3 usable data-plane slots after the reserved terminal slot
                max_queued_bytes: 0,
            })
            .expect("open subscription")
            .subscription_id;

        let mut last_root_id = Vec::new();
        for byte in 1..=8u8 {
            let root_id = vec![byte; 16];
            let lifetime = core
                .inventory_open_root(InventoryRootOpenV1 {
                    runtime_identity: identity.clone(),
                    scope_id: scope.scope_id.clone(),
                    root_id: root_id.clone(),
                    name: format!("root{byte}"),
                    standardized_full_path: format!("/root{byte}"),
                })
                .expect("open root");
            let event = runtime::inventory::InventoryAppliedIndexBatchEvent {
                root_id: id_from_vec(&root_id),
                upserted_files: vec![sample_file(
                    byte,
                    id_from_vec(&root_id),
                    "f.swift",
                    "f.swift",
                )],
                upserted_folders: Vec::new(),
                removed_file_ids: Vec::new(),
                removed_folder_ids: Vec::new(),
                removed_file_paths: Vec::new(),
                removed_folder_paths: Vec::new(),
                modified_file_ids: Vec::new(),
                modified_folder_ids: Vec::new(),
            };
            core.inventory_apply_delta_v1(InventoryDeltaCommandV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                root_lifetime_id: lifetime.root_lifetime_id.clone(),
                watcher_accepted_watermark: None,
                requires_full_resync: true,
                expected_applied_index_generation: None,
                source: "test".to_owned(),
                event_bytes: runtime::inventory_scope::encode_delta_event(&event),
            })
            .expect("apply delta");
            last_root_id = root_id;
        }

        let DrainBatch {
            events,
            dropped_count,
            oversize,
            ..
        } = core.try_drain(subscription, 64, 1_048_576).expect("drain");
        assert!(oversize.is_none());
        assert!(
            dropped_count > 0,
            "eight distinct roots through a 3-slot data-plane queue must drop something"
        );
        assert!(
            events
                .iter()
                .any(|event| event.kind == crate::types::RuntimeEventKind::Gap),
            "a Gap-kind event with the dropped_count marker must be present"
        );

        // Resnapshot recovery: a fresh `inventoryOpenSnapshot` against the last root touched must
        // still serve current, correct data through the ordinary FFI read plane -- the event gap
        // does not poison the scope, only the stale event-stream projection.
        let snapshot = core
            .inventory_open_snapshot(InventorySnapshotRequestV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: last_root_id.clone(),
            })
            .expect("fresh snapshot handle must still open after a gap");
        let page = core
            .inventory_snapshot_page(identity, scope.scope_id, snapshot.handle_id, 0, 10)
            .expect("fresh page must still read");
        let (files, _) = runtime::inventory_scope::decode_bulk_chunk(&page.bytes).expect("decode");
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].name, "f.swift");
    }

    fn id_from_vec(bytes: &[u8]) -> [u8; 16] {
        let mut id = [0u8; 16];
        id.copy_from_slice(bytes);
        id
    }

    #[test]
    fn inventory_scope_open_root_rejects_unknown_scope_and_wrong_lifetime() {
        let (core, identity, _cancellation) = initialized_core();
        let bogus_scope_id = "0".repeat(32);
        let result = core.inventory_open_root(InventoryRootOpenV1 {
            runtime_identity: identity,
            scope_id: bogus_scope_id,
            root_id: vec![1u8; 16],
            name: "root".to_owned(),
            standardized_full_path: "/repo".to_owned(),
        });
        assert_eq!(result, Err(CoreError::InventoryScopeUnknownScope));
    }

    #[test]
    fn inventory_apply_delta_rejects_a_stale_watermark_as_a_business_outcome_not_an_error() {
        let (core, identity, _cancellation) = initialized_core();
        let scope = core
            .inventory_open_scope(
                identity.clone(),
                CoreInventoryScopeConfigV1 {
                    live_generation_cap: 8,
                    max_patch_logical_mutation_count: 1,
                    codemap_capable_extensions: Vec::new(),
                },
            )
            .expect("open scope");
        let root_id = vec![5u8; 16];
        let lifetime = core
            .inventory_open_root(InventoryRootOpenV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                name: "root".to_owned(),
                standardized_full_path: "/repo".to_owned(),
            })
            .expect("open root");

        let make_event = |seed: u8| runtime::inventory::InventoryAppliedIndexBatchEvent {
            root_id: [5; 16],
            upserted_files: vec![sample_file(seed, [5; 16], "A.swift", "A.swift")],
            upserted_folders: Vec::new(),
            removed_file_ids: Vec::new(),
            removed_folder_ids: Vec::new(),
            removed_file_paths: Vec::new(),
            removed_folder_paths: Vec::new(),
            modified_file_ids: Vec::new(),
            modified_folder_ids: Vec::new(),
        };

        let first = core
            .inventory_apply_delta_v1(InventoryDeltaCommandV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                root_lifetime_id: lifetime.root_lifetime_id.clone(),
                watcher_accepted_watermark: Some(100),
                requires_full_resync: false,
                expected_applied_index_generation: None,
                source: "watcher".to_owned(),
                event_bytes: runtime::inventory_scope::encode_delta_event(&make_event(1)),
            })
            .expect("first delta admitted");
        assert!(!matches!(
            first.outcome,
            InventoryApplyOutcomeV1::Rejected { .. }
        ));

        let stale = core
            .inventory_apply_delta_v1(InventoryDeltaCommandV1 {
                runtime_identity: identity,
                scope_id: scope.scope_id,
                root_id,
                root_lifetime_id: lifetime.root_lifetime_id,
                watcher_accepted_watermark: Some(50),
                requires_full_resync: false,
                expected_applied_index_generation: None,
                source: "watcher".to_owned(),
                event_bytes: runtime::inventory_scope::encode_delta_event(&make_event(2)),
            })
            .expect("stale delta is a business outcome, not a thrown error");
        assert_eq!(
            stale.outcome,
            InventoryApplyOutcomeV1::Rejected {
                reason: InventoryRejectionReasonV1::StaleWatermark {
                    expected: 100,
                    actual: 50,
                },
            }
        );
    }

    // ============================================================================================
    // P6-6: agent-claude-v1 FFI surface tests -- "the real bridge" the design's done-when names.
    // ============================================================================================

    /// Cross-package binary lookup: `agent-claude-synthetic-cli` is a `[[bin]]` target owned by
    /// `agentry-runtime` (`rust/crates/runtime/tests/support/synthetic_cli.rs`), so
    /// `CARGO_BIN_EXE_...` (only set for a package's own test targets) is not available here.
    /// `cargo test --workspace` (this crate's official validation path, `make dev-cargo-test
    /// CARGO_PACKAGE=all`) builds every workspace binary target before running any test, so by the
    /// time this runs the binary is a sibling of this test binary's own executable directory. A
    /// narrow `-p agentry-ffi`-only invocation does not build sibling-package binaries -- run
    /// `cargo build -p agentry-runtime --bin agent-claude-synthetic-cli` first if using one.
    fn agent_claude_synthetic_cli_path() -> std::path::PathBuf {
        let mut path = std::env::current_exe().expect("current test executable");
        path.pop();
        if path.ends_with("deps") {
            path.pop();
        }
        path.push("agent-claude-synthetic-cli");
        assert!(
            path.is_file(),
            "expected {path:?} to exist -- run via `cargo test --workspace` / `make dev-cargo-test \
             CARGO_PACKAGE=all`, or build the sibling binary explicitly first"
        );
        path
    }

    fn agent_claude_config(command: &str, arguments: Vec<String>) -> CoreAgentClaudeScopeConfigV1 {
        CoreAgentClaudeScopeConfigV1 {
            command: command.to_owned(),
            arguments,
            environment: Vec::new(),
            working_directory: None,
            permission_mode: None,
            mcp_config_path: None,
            mcp_strict_mode: false,
            disallowed_built_in_tools: Vec::new(),
            append_system_prompt: None,
            system_prompt: None,
            idle_fallback_millis: 1_000,
            interrupt_ack_timeout_millis: 400,
            raw_event_log_enabled: false,
            raw_event_log_file_path: None,
            raw_event_log_run_id: String::new(),
            raw_event_log_tab_id: String::new(),
            raw_event_log_window_id: 0,
            raw_event_log_initial_session_id: String::new(),
        }
    }

    fn agent_claude_open_subscription(
        core: &CoreRuntime,
        identity: &RuntimeIdentity,
        subscription_scope_id: &str,
    ) -> SubscriptionId {
        core.open_subscription(SubscriptionScope {
            runtime_identity: identity.clone(),
            scope_id: crate::types::ScopeId {
                value: subscription_scope_id.to_owned(),
            },
            max_queued_events: 0,
            max_queued_bytes: 0,
        })
        .expect("open subscription against the derived subscription_scope_id")
        .subscription_id
    }

    #[test]
    fn agent_claude_full_lifecycle_round_trips_through_the_ffi_surface() {
        let (core, identity, _cancellation) = initialized_core();
        let cli = agent_claude_synthetic_cli_path();
        // P6-7 (§15.5): `well-behaved` mode has no responder and cannot ACK the session-startup
        // `initialize` handshake `agent_start_or_resume` now blocks on (contract §2.5), so this
        // moves to `scripted` mode's equivalent -- see the cargo-only twin
        // (`agent_claude_scope.rs::well_behaved_session_completes_a_turn_end_to_end`)'s comment for
        // why `AWAITACKS 1`/`SLEEP 200` are load-bearing, not decorative.
        let script = write_ffi_script(
            "well-behaved-equivalent",
            "AWAITACKS 1\nSLEEP 200\nOUT {\"type\":\"result\",\"subtype\":\"success\"}\n",
        );
        let scope = core
            .agent_open_scope(
                identity.clone(),
                agent_claude_config_with_synthetic_mode(
                    cli.to_str().expect("utf8 path"),
                    &["scripted", &script.to_string_lossy()],
                ),
            )
            .expect("open scope");
        let subscription =
            agent_claude_open_subscription(&core, &identity, &scope.subscription_scope_id);

        let receipt = core
            .agent_start_or_resume(identity.clone(), scope.scope_id.clone(), None, None, None)
            .expect("start");
        assert!(receipt.pid > 0);
        assert_eq!(
            receipt.pid, receipt.process_group_id,
            "the child is the leader of its own new process group"
        );

        let generation = core
            .agent_send_user_message(identity.clone(), scope.scope_id.clone(), "hello".to_owned())
            .expect("send");
        assert_eq!(
            generation, 1,
            "generation numbering starts at 1 (0 is the never-sent sentinel)"
        );

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut saw_turn_completed = false;
        while std::time::Instant::now() < deadline && !saw_turn_completed {
            let batch = core
                .try_drain(subscription.clone(), 16, 65_536)
                .expect("drain");
            for event in batch.events {
                if let Some(decoded) =
                    runtime::agent_claude::event::AgentClaudeEvent::decode(&event.payload)
                    && decoded.kind.wire_name() == "turnCompleted"
                {
                    saw_turn_completed = true;
                }
            }
            if !saw_turn_completed {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
        assert!(
            saw_turn_completed,
            "turnCompleted must flow through the real FFI subscription surface, decoded from the real batched event envelope"
        );

        core.close_subscription(subscription)
            .expect("close subscription");
        core.agent_shutdown(identity.clone(), scope.scope_id.clone())
            .expect("shutdown");
        core.agent_shutdown(identity, scope.scope_id)
            .expect("shutdown is idempotent");
        let _ = std::fs::remove_file(&script);
    }

    #[test]
    fn agent_claude_interrupt_stale_generation_is_reachable_through_the_ffi_surface() {
        // P6-6 done-when: "a test proving staleGeneration is reachable" -- through the real bridge,
        // not just the runtime crate directly (see `agent_claude_scope.rs`'s cargo-only twin).
        let (core, identity, _cancellation) = initialized_core();
        // P6-7 (§15.5): `/bin/sleep` cannot ACK the session-startup `initialize` handshake
        // `agent_start_or_resume` now blocks on -- this needs the real synthetic CLI in `scripted`
        // mode instead, matching the cargo-only twin's `interrupt_stale_generation_is_reachable_
        // naming_n_while_n_plus_1_is_live`.
        let cli = agent_claude_synthetic_cli_path();
        let script = write_ffi_script("stale-generation", "SLEEP 3000\n");
        let scope = core
            .agent_open_scope(
                identity.clone(),
                agent_claude_config_with_synthetic_mode(
                    cli.to_str().expect("utf8 path"),
                    &["scripted", &script.to_string_lossy()],
                ),
            )
            .expect("open scope");
        let subscription =
            agent_claude_open_subscription(&core, &identity, &scope.subscription_scope_id);
        core.agent_start_or_resume(identity.clone(), scope.scope_id.clone(), None, None, None)
            .expect("start");

        let generation_one = core
            .agent_send_user_message(identity.clone(), scope.scope_id.clone(), "one".to_owned())
            .expect("send 1");
        let generation_two = core
            .agent_send_user_message(identity.clone(), scope.scope_id.clone(), "two".to_owned())
            .expect("send 2");
        assert_eq!(generation_two, generation_one + 1);

        let receipt = core
            .agent_interrupt_turn(
                identity.clone(),
                scope.scope_id.clone(),
                generation_one,
                "stale test".to_owned(),
            )
            .expect("interrupt naming the superseded generation");

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let mut outcome = None;
        while std::time::Instant::now() < deadline && outcome.is_none() {
            let batch = core
                .try_drain(subscription.clone(), 16, 65_536)
                .expect("drain");
            for event in batch.events {
                if let Some(decoded) =
                    runtime::agent_claude::event::AgentClaudeEvent::decode(&event.payload)
                    && decoded.kind.wire_name() == "interruptOutcome"
                    && decoded
                        .fields
                        .get("request_id")
                        .and_then(|value| value.as_str())
                        == Some(receipt.request_id.as_str())
                {
                    outcome = Some(decoded);
                }
            }
            if outcome.is_none() {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
        let outcome = outcome
            .expect("interruptOutcome must be published through the real FFI subscription surface");
        assert_eq!(
            outcome
                .fields
                .get("outcome")
                .and_then(|value| value.as_str()),
            Some("staleGeneration")
        );
        assert_eq!(
            outcome
                .fields
                .get("current_generation")
                .and_then(serde_json::Value::as_u64),
            Some(generation_two)
        );
        assert_eq!(
            outcome
                .fields
                .get("current_turn_in_flight")
                .and_then(serde_json::Value::as_bool),
            Some(true)
        );

        core.close_subscription(subscription)
            .expect("close subscription");
        core.agent_shutdown(identity, scope.scope_id)
            .expect("shutdown");
        let _ = std::fs::remove_file(&script);
    }

    #[test]
    fn agent_claude_every_command_rejects_a_mismatched_runtime_identity() {
        let (core, identity, _cancellation) = initialized_core();
        let intruder_core = CoreRuntime::new(config()).expect("second runtime");
        let intruder = intruder_core
            .initialize()
            .expect("initialize intruder")
            .runtime_identity;

        // P6-7 (§15.5): `/bin/sleep` cannot ACK the session-startup handshake the real-identity
        // `agent_start_or_resume` call below needs -- see the previous test's comment.
        let cli = agent_claude_synthetic_cli_path();
        let script = write_ffi_script("identity-swap", "AWAITACKS 1\nSLEEP 500\n");
        let scope = core
            .agent_open_scope(
                identity.clone(),
                agent_claude_config_with_synthetic_mode(
                    cli.to_str().expect("utf8 path"),
                    &["scripted", &script.to_string_lossy()],
                ),
            )
            .expect("open scope");

        assert_eq!(
            core.agent_start_or_resume(intruder.clone(), scope.scope_id.clone(), None, None, None)
                .unwrap_err(),
            CoreError::StaleRuntimeIdentity
        );
        core.agent_start_or_resume(identity.clone(), scope.scope_id.clone(), None, None, None)
            .expect("start under the real identity");
        assert_eq!(
            core.agent_send_user_message(intruder.clone(), scope.scope_id.clone(), "hi".to_owned())
                .unwrap_err(),
            CoreError::StaleRuntimeIdentity
        );
        assert_eq!(
            core.agent_interrupt_turn(intruder.clone(), scope.scope_id.clone(), 1, "x".to_owned())
                .unwrap_err(),
            CoreError::StaleRuntimeIdentity
        );
        assert_eq!(
            core.agent_apply_model_and_effort(
                intruder.clone(),
                scope.scope_id.clone(),
                None,
                None,
                AgentClaudeFlagSettingsDispositionV1::Live,
            )
            .unwrap_err(),
            CoreError::StaleRuntimeIdentity
        );
        assert_eq!(
            core.agent_respond_permission(
                intruder.clone(),
                scope.scope_id.clone(),
                "unknown".to_owned(),
                AgentClaudePermissionDecisionV1::Allow {
                    include_updated_permissions: false
                }
            )
            .unwrap_err(),
            CoreError::StaleRuntimeIdentity
        );
        assert_eq!(
            core.agent_shutdown(intruder, scope.scope_id.clone())
                .unwrap_err(),
            CoreError::StaleRuntimeIdentity
        );

        core.agent_shutdown(identity, scope.scope_id)
            .expect("the real identity can still shut the scope down");
        let _ = std::fs::remove_file(&script);
    }

    #[test]
    fn agent_claude_unknown_scope_id_is_a_typed_error_not_a_panic() {
        let (core, identity, _cancellation) = initialized_core();
        let bogus_scope_id = runtime::agent_claude::AgentClaudeScopeId::mint().to_string();
        assert_eq!(
            core.agent_start_or_resume(identity, bogus_scope_id, None, None, None)
                .unwrap_err(),
            CoreError::AgentClaudeUnknownScope
        );
    }

    /// `CoreAgentClaudeScopeConfigV1` (the FFI-crossing config) has no `raw_argv_for_testing`
    /// escape hatch -- `runtime_config()` always hardcodes it `false`, so contract §2.5's real flag
    /// injection is unconditional here and would permanently occupy the synthetic CLI's `args[1]`
    /// mode slot with `"-p"`. Driving the synthetic CLI's `scripted`/other test-only modes through
    /// the real FFI surface therefore goes through `AGENT_CLAUDE_SYNTHETIC_CLI_ARGS` instead of
    /// positional argv (see `synthetic_cli.rs`'s own doc comment) -- a real per-KV-pair `environment`
    /// entry, the same mechanism contract §5.1 uses in production, not a protocol-line crossing
    /// (INV-P6-1 is about FFI exports, not test-only child-process environment).
    fn agent_claude_config_with_synthetic_mode(
        cli: &str,
        mode_args: &[&str],
    ) -> CoreAgentClaudeScopeConfigV1 {
        let mut config = agent_claude_config(cli, Vec::new());
        config
            .environment
            .push(crate::types::CoreAgentClaudeEnvironmentEntryV1 {
                key: "AGENT_CLAUDE_SYNTHETIC_CLI_ARGS".to_owned(),
                value: mode_args.join("\n"),
            });
        config
    }

    fn write_ffi_script(name: &str, contents: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "agent-claude-ffi-test-{name}-{}.script",
            std::process::id()
        ));
        std::fs::write(&path, contents).expect("write script fixture");
        path
    }

    #[test]
    fn agent_claude_oversize_single_event_payload_is_rejected_through_the_ffi_drain_surface() {
        // P6-6 done-when: the oversize path "tested end-to-end through the real bridge" -- the
        // cargo-only twin (`agent_claude_scope.rs`'s `an_oversize_single_event_payload_is_rejected_
        // not_silently_truncated_or_wedged`) drives `SubscriptionHub` directly; this drives the same
        // scenario through `CoreRuntime::agent_open_scope`/`try_drain`, the actual UniFFI-crossing
        // surface.
        let (core, identity, _cancellation) = initialized_core();
        let cli = agent_claude_synthetic_cli_path();
        let huge_text = "x".repeat(2 * 1024 * 1024);
        let line = serde_json::json!({
            "type": "assistant",
            "message": {"content": [{"type": "text", "text": huge_text}]},
        });
        let script = write_ffi_script("oversize", &format!("OUT {line}\nSLEEP 1500\n"));
        let scope = core
            .agent_open_scope(
                identity.clone(),
                agent_claude_config_with_synthetic_mode(
                    cli.to_str().expect("utf8 path"),
                    &["scripted", &script.to_string_lossy()],
                ),
            )
            .expect("open scope");
        let subscription =
            agent_claude_open_subscription(&core, &identity, &scope.subscription_scope_id);
        core.agent_start_or_resume(identity.clone(), scope.scope_id.clone(), None, None, None)
            .expect("start");
        core.agent_send_user_message(identity.clone(), scope.scope_id.clone(), "hello".to_owned())
            .expect("send"); // turn in flight, so resnapshot appends

        // `PayloadRejected` (a regular event kind published into a normal `DrainOutcome::Batch` at
        // *publish* time, once a single event's encoded payload exceeds the subscription's byte
        // cap) is the mechanism this drives -- distinct from `DrainBatch::oversize`, which reports
        // a *drain-call*-level constraint (an already-queued event too large for this call's own
        // `max_bytes`), not exercised here. Mirrors the cargo-only twin's own `RuntimeEventKind::
        // PayloadRejected` check exactly.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
        let mut saw_payload_rejected = false;
        while std::time::Instant::now() < deadline && !saw_payload_rejected {
            let batch = core
                .try_drain(subscription.clone(), 16, 65_536)
                .expect("drain");
            saw_payload_rejected = batch
                .events
                .iter()
                .any(|event| event.kind == crate::types::RuntimeEventKind::PayloadRejected);
            if !saw_payload_rejected {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
        assert!(
            saw_payload_rejected,
            "an over-cap single event payload must surface as a PayloadRejected event through the real FFI drain surface"
        );

        core.close_subscription(subscription)
            .expect("close subscription");
        core.agent_shutdown(identity, scope.scope_id)
            .expect("shutdown");
        let _ = std::fs::remove_file(&script);
    }

    #[test]
    fn agent_claude_gap_pressure_and_recovery_surfaces_through_the_ffi_drain_surface() {
        // P6-6 done-when: gap/resnapshot "tested end-to-end through the real bridge" -- mirrors
        // `agent_claude_scope.rs`'s `a_lossless_event_evicts_a_resident_droppable_diagnostic_into_
        // a_gap_record` (two over-cap lines against a 1-usable-data-slot subscription), but through
        // the real FFI `open_subscription`/`try_drain` surface, and proves the subscription
        // recovers (a further drain still succeeds, not wedged) once the pressure clears.
        let (core, identity, _cancellation) = initialized_core();
        let cli = agent_claude_synthetic_cli_path();
        let huge_line_one = "a".repeat(9 * 1024 * 1024);
        let huge_line_two = "b".repeat(9 * 1024 * 1024);
        let script = write_ffi_script(
            "gap",
            &format!("OUT {huge_line_one}\nOUT {huge_line_two}\nSLEEP 1500\n"),
        );
        let scope = core
            .agent_open_scope(
                identity.clone(),
                agent_claude_config_with_synthetic_mode(
                    cli.to_str().expect("utf8 path"),
                    &["scripted", &script.to_string_lossy()],
                ),
            )
            .expect("open scope");
        let subscription = core
            .open_subscription(SubscriptionScope {
                runtime_identity: identity.clone(),
                scope_id: crate::types::ScopeId {
                    value: scope.subscription_scope_id.clone(),
                },
                max_queued_events: 2,
                max_queued_bytes: 65_536,
            })
            .expect("open subscription against the derived subscription_scope_id")
            .subscription_id;
        core.agent_start_or_resume(identity.clone(), scope.scope_id.clone(), None, None, None)
            .expect("start");
        core.agent_send_user_message(identity.clone(), scope.scope_id.clone(), "hello".to_owned())
            .expect("send");

        // Deliberately not draining while the two huge lines stream through -- draining would
        // relieve the very pressure this test needs to hold both diagnostics resident at once so
        // the second eviction has something to evict (same reasoning as the cargo-only twin).
        // Generous fixed margin, not a poll on a diagnostics field the FFI surface does not expose.
        std::thread::sleep(std::time::Duration::from_secs(2));

        let batch = core
            .try_drain(subscription.clone(), 64, 262_144)
            .expect("drain");
        let saw_gap = batch
            .events
            .iter()
            .any(|event| event.kind == crate::types::RuntimeEventKind::Gap)
            || batch.dropped_count > 0;
        assert!(
            saw_gap,
            "the resident droppable diagnostic must be evicted into a Gap record when a lossless event needs its slot"
        );

        // Recovery: the subscription is not wedged by the gap -- a further drain still succeeds.
        core.try_drain(subscription.clone(), 64, 262_144)
            .expect("drain must still succeed after a gap");

        core.close_subscription(subscription)
            .expect("close subscription");
        core.agent_shutdown(identity, scope.scope_id)
            .expect("shutdown");
        let _ = std::fs::remove_file(&script);
    }

    #[test]
    fn agent_claude_interrupt_failed_is_reachable_through_the_ffi_surface() {
        // P6-6 done-when: the interrupt outcome enum's fifth variant, `failed`
        // (`ControlOutcome::WriteFailed`), reachable through the real FFI surface -- the cargo-only
        // twin is `agent_claude_scope.rs`'s `interrupt_failed_when_the_control_request_write_hits_
        // a_closed_stdin_pipe`, using the same deterministic single-threaded `stdin-closed-after-
        // delay` synthetic CLI mode (no background reader thread racing the close, so no need to
        // race `on_stdout_eof`'s own turn-flush against the parent's write).
        let (core, identity, _cancellation) = initialized_core();
        let cli = agent_claude_synthetic_cli_path();
        let scope = core
            .agent_open_scope(
                identity.clone(),
                agent_claude_config_with_synthetic_mode(
                    cli.to_str().expect("utf8 path"),
                    &["stdin-closed-after-delay", "200", "5000"],
                ),
            )
            .expect("open scope");
        core.agent_start_or_resume(identity.clone(), scope.scope_id.clone(), None, None, None)
            .expect("start");
        let generation = core
            .agent_send_user_message(identity.clone(), scope.scope_id.clone(), "hello".to_owned())
            .expect("send");
        // Comfortably past the child's 200 ms delay before it closes stdin -- a fixed margin (10x
        // the delay), generous enough to absorb parallel `cargo test --workspace` contention.
        std::thread::sleep(std::time::Duration::from_millis(2_000));

        let subscription =
            agent_claude_open_subscription(&core, &identity, &scope.subscription_scope_id);
        let receipt = core
            .agent_interrupt_turn(
                identity.clone(),
                scope.scope_id.clone(),
                generation,
                "closed-pipe test".to_owned(),
            )
            .expect("interrupt");

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        let mut outcome = None;
        while std::time::Instant::now() < deadline && outcome.is_none() {
            let batch = core
                .try_drain(subscription.clone(), 16, 65_536)
                .expect("drain");
            for event in batch.events {
                if let Some(decoded) =
                    runtime::agent_claude::event::AgentClaudeEvent::decode(&event.payload)
                    && decoded.kind.wire_name() == "interruptOutcome"
                    && decoded
                        .fields
                        .get("request_id")
                        .and_then(|value| value.as_str())
                        == Some(receipt.request_id.as_str())
                {
                    outcome = Some(decoded);
                }
            }
            if outcome.is_none() {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
        let outcome = outcome.expect(
            "interruptOutcome must be published even when the control-request write itself fails",
        );
        assert_eq!(
            outcome
                .fields
                .get("outcome")
                .and_then(|value| value.as_str()),
            Some("failed")
        );

        core.close_subscription(subscription)
            .expect("close subscription");
        core.agent_shutdown(identity, scope.scope_id)
            .expect("shutdown");
    }
}
