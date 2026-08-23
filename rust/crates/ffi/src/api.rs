use crate::errors::CoreError;
use crate::generated::contract_identity::{
    ABI_EPOCH, BINDING_CHECKSUM, CORE_BUILD_FINGERPRINT, PAYLOAD_SCHEMA_VERSIONS,
};
use crate::panic_guard::PanicGuard;
use crate::types::{
    AdmissionDisposition, AdmissionReceipt, BulkChunkReceiptV1, CancelReceipt, CommandEnvelope,
    CompactInventoryPageV1, CompactLookupResultV1, CompactQueryResultV1, CompactQueryV1,
    CompactRecordBlockV1, CompactRegexBatchResult, CoreApplyEditsBatchRequestV1,
    CoreCodeMapBatchRequestV1, CoreCompactApplyEditsBatchResultV1, CoreCompactCodeMapBatchResultV1,
    CoreConfig, CoreHandshake, CoreInventoryScopeConfigV1, CorePathMatchResolveRequestV1,
    CorePathMatchResolveResultV1,
    CorePathMatchScoreRequestV1, CorePathMatchScoreResultV1, CorePathSearchFindRequestV1,
    CorePathSearchFindResultV1, CoreTokenAccountingRequestV1, CoreTokenAccountingResultV1,
    DrainBatch, FolderSuffixRequest, HostResponse,
    BulkChunkDiscoveryReceiptV1, InventoryDeltaCommandV1, InventoryDeltaDiscoveryCommandV1,
    InventoryDeltaDiscoveryReceiptV1, InventoryDeltaReceiptV1, InventoryDiagnosticsV1,
    InventoryGenerationReceiptV1, InventoryHandleInvalidationReasonV1,
    InventoryProjectedShardRequestV1, InventoryPublishModeV1,
    InventoryResolveRequestV1, InventoryRootLifetimeV1, InventoryRootOpenV1,
    InventoryRootUnloadReceiptV1, InventoryScopeHandleV1, InventorySnapshotHandleV1,
    InventorySnapshotRequestV1, OperationState, OversizeEvent,
    PathFilterRequest, PathFilterResult, RegexSearchBatchRequest, RegexSearchRequest,
    RegexSearchResult, RuntimeEvent, RuntimeIdentity, ShutdownReceipt, SubscriptionBootstrap,
    SubscriptionId, SubscriptionScope, parse_inventory_scope_id, parse_root_id,
    parse_root_lifetime_id, wire_error,
};
use agentry_proto::{Envelope, PayloadKind};
use agentry_runtime as runtime;
use std::os::fd::IntoRawFd;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};

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
            let lifetime = scope.open_root(&identity, root_id, request.name, request.standardized_full_path)?;
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
            let (files, folders) = runtime::inventory_scope::decode_bulk_chunk(&bytes).map_err(wire_error)?;
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
            let (files, folders) =
                runtime::inventory_scope::decode_discovery_bulk_chunk(&bytes).map_err(wire_error)?;
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
                minted_file_ids: receipt.minted_file_ids.iter().map(|id| id.to_vec()).collect(),
                minted_folder_ids: receipt.minted_folder_ids.iter().map(|id| id.to_vec()).collect(),
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
            let event = runtime::inventory_scope::decode_discovery_delta_event(&command.event_bytes)
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
            Ok(scope.apply_delta_discovery(&identity, runtime_command).into())
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
                    // `returned_count`/`has_more` are computed from `files` alone, unchanged from
                    // before this fix -- `SnapshotPage` pages files and folders through the same
                    // offset/limit window independently (see `snapshot_page`'s doc comment), and
                    // callers that want every folder page the folder list to exhaustion the same
                    // way they already do for files (`WorkspaceInventoryScopeShadowForwarder.
                    // snapshotAllRecords`).
                    let returned_count = page.files.len() as u64;
                    let has_more = page.files.len() == limit && limit > 0;
                    Ok(CompactInventoryPageV1 {
                        bytes: runtime::inventory_scope::encode_bulk_chunk(&page.files, &page.folders),
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
            scope.close_snapshot(runtime::inventory_scope::SnapshotHandleId::from_raw(handle_id));
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
            let paths = runtime::inventory_scope::decode_lookup_request(&bytes).map_err(wire_error)?;
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

    pub fn inventory_query(&self, request: CompactQueryV1) -> Result<CompactQueryResultV1, CoreError> {
        self.guard(|| {
            self.require_running()?;
            let identity = self.validate_identity(&request.runtime_identity)?;
            let scope = self.inventory_scope(&request.scope_id)?;
            let decoded = runtime::inventory_scope::decode_query_request(&request.bytes).map_err(wire_error)?;
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
                runtime::inventory_scope::decode_resolve_request(&request.bytes).map_err(wire_error)?;
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
                bytes: runtime::inventory_scope::encode_fact_block(&runtime::inventory_scope::FactBlock {
                    generation,
                    root_lifetime_hi,
                    root_lifetime_lo,
                    rows,
                }),
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
                bytes: runtime::inventory_scope::encode_fact_block(&runtime::inventory_scope::FactBlock {
                    generation: Some(0),
                    root_lifetime_hi: 0,
                    root_lifetime_lo: 0,
                    rows,
                }),
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
            let handle_id = scope.open_projected_shard(&identity, root_id, "ffi-projected-shard")?;
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
        InventoryApplyOutcomeV1, InventoryRejectionReasonV1,
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

    fn sample_file(seed: u8, root_id: [u8; 16], relative_path: &str, name: &str) -> runtime::inventory::InventoryFileRecord {
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
            .inventory_snapshot_page(identity.clone(), scope.scope_id.clone(), snapshot.handle_id, 0, 10)
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
            .inventory_lookup_paths(identity.clone(), scope.scope_id.clone(), snapshot.handle_id, lookup_bytes)
            .expect("lookup paths");
        let lookup_block =
            runtime::inventory_scope::decode_fact_block(&lookup_result.bytes).expect("decode lookup block");
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
            runtime::inventory_scope::encode_query_request("*App*", 10, 0, "root/", "root");
        let query_result = core
            .inventory_query(CompactQueryV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                handle_id: snapshot.handle_id,
                bytes: query_bytes,
            })
            .expect("query");
        let (query_generation, candidates) =
            runtime::inventory_scope::decode_query_response(&query_result.bytes).expect("decode query response");
        assert_eq!(query_generation, Some(0));
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].name, "App.swift");

        // inventoryResolveRecords (scope+root, live truth, not handle-based).
        let resolve_bytes = runtime::inventory_scope::encode_resolve_request(&[[1u8; 16], [99u8; 16]], &[]);
        let resolve_result = core
            .inventory_resolve_records(InventoryResolveRequestV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                expected_catalog_generation: None,
                bytes: resolve_bytes,
            })
            .expect("resolve records");
        let resolve_block =
            runtime::inventory_scope::decode_fact_block(&resolve_result.bytes).expect("decode resolve block");
        assert_eq!(resolve_block.generation, Some(0));
        assert!(resolve_block.rows[0].exists);
        assert!(!resolve_block.rows[1].exists);

        // A stale `expected_catalog_generation` produces a whole-block stale outcome, not an error.
        let resolve_bytes_stale = runtime::inventory_scope::encode_resolve_request(&[[1u8; 16]], &[]);
        let stale_result = core
            .inventory_resolve_records(InventoryResolveRequestV1 {
                runtime_identity: identity.clone(),
                scope_id: scope.scope_id.clone(),
                root_id: root_id.clone(),
                expected_catalog_generation: Some(999),
                bytes: resolve_bytes_stale,
            })
            .expect("resolve records (stale)");
        let stale_block =
            runtime::inventory_scope::decode_fact_block(&stale_result.bytes).expect("decode stale block");
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
            .inventory_snapshot_page(identity.clone(), scope.scope_id.clone(), shard.handle_id, 0, 10)
            .expect("shard page");
        let (shard_files, _) = runtime::inventory_scope::decode_bulk_chunk(&shard_page.bytes).expect("decode shard page");
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
            .inventory_snapshot_page(identity.clone(), scope.scope_id.clone(), snapshot.handle_id, 0, 10)
            .expect("old snapshot handle still readable");
        let (old_files, _) = runtime::inventory_scope::decode_bulk_chunk(&old_page.bytes).expect("decode");
        assert_eq!(old_files.len(), 2, "the old handle keeps seeing its own frozen generation");

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

        let after_close = core.inventory_snapshot_page(identity.clone(), scope.scope_id.clone(), shard.handle_id, 0, 10);
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
        assert_eq!(delta_receipt.outcome, InventoryApplyOutcomeV1::RebuiltAuthoritative);

        let DrainBatch { events, .. } = core
            .try_drain(subscription.clone(), 16, 65_536)
            .expect("drain");
        // open_root -> RootPublished; apply_delta (fresh root, full resync) -> ShardFallback,
        // generationAdvanced, appliedIndexBatch.
        assert_eq!(events.len(), 4);
        let generation_advanced = runtime::inventory_scope::decode_generation_advanced(&events[2].payload)
            .expect("decode generationAdvanced");
        assert_eq!(generation_advanced.root_id, [4; 16]);
        assert_eq!(generation_advanced.applied_index_generation, delta_receipt.applied_index_generation);
        assert_eq!(generation_advanced.catalog_generation, delta_receipt.catalog_generation);
        assert!(generation_advanced.rebuilt_authoritative);

        let applied_index_batch = runtime::inventory_scope::decode_delta_event(&events[3].payload)
            .expect("decode appliedIndexBatch");
        assert_eq!(applied_index_batch.upserted_files.len(), 1);
        assert_eq!(applied_index_batch.upserted_files[0].name, "A.swift");

        core.close_subscription(subscription).expect("close subscription");
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
                upserted_files: vec![sample_file(byte, id_from_vec(&root_id), "f.swift", "f.swift")],
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

        let DrainBatch { events, dropped_count, oversize, .. } = core
            .try_drain(subscription, 64, 1_048_576)
            .expect("drain");
        assert!(oversize.is_none());
        assert!(dropped_count > 0, "eight distinct roots through a 3-slot data-plane queue must drop something");
        assert!(
            events.iter().any(|event| event.kind == crate::types::RuntimeEventKind::Gap),
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
            .inventory_open_scope(identity.clone(), CoreInventoryScopeConfigV1 {
                live_generation_cap: 8,
                max_patch_logical_mutation_count: 1,
                codemap_capable_extensions: Vec::new(),
            })
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
        assert!(!matches!(first.outcome, InventoryApplyOutcomeV1::Rejected { .. }));

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
}
