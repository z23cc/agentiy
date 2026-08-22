use crate::errors::CoreError;
use crate::generated::contract_identity::{
    ABI_EPOCH, BINDING_CHECKSUM, CORE_BUILD_FINGERPRINT, PAYLOAD_SCHEMA_VERSIONS,
};
use crate::panic_guard::PanicGuard;
use crate::types::{
    AdmissionDisposition, AdmissionReceipt, CancelReceipt, CommandEnvelope,
    CompactRegexBatchResult, CoreApplyEditsBatchRequestV1, CoreCodeMapBatchRequestV1,
    CoreCompactApplyEditsBatchResultV1, CoreCompactCodeMapBatchResultV1, CoreConfig, CoreHandshake,
    CoreInventoryComputeRequestV1, CoreInventoryComputeResultV1, CorePathMatchResolveRequestV1,
    CorePathMatchResolveResultV1, CorePathMatchScoreRequestV1, CorePathMatchScoreResultV1,
    CorePathSearchFindRequestV1, CorePathSearchFindResultV1, DrainBatch, FolderSuffixRequest,
    HostResponse, OperationState, OversizeEvent, PathFilterRequest, PathFilterResult,
    RegexSearchBatchRequest, RegexSearchRequest, RegexSearchResult, RuntimeEvent, RuntimeIdentity,
    ShutdownReceipt, SubscriptionBootstrap, SubscriptionId, SubscriptionScope,
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
    inventory_service: runtime::inventory::InventoryComputeService,
    path_match_service: runtime::pathmatch::PathMatchScoreService,
    path_resolve_service: runtime::pathmatch::PathMatchResolveService,
    path_search_service: runtime::pathsearch::PathSearchFindService,
    config: CoreConfig,
    initialized: AtomicBool,
    panic_guard: Arc<PanicGuard>,
}

#[uniffi::export]
impl CoreRuntime {
    #[uniffi::constructor]
    pub fn new(config: CoreConfig) -> Result<Arc<Self>, CoreError> {
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

    pub fn inventory_compute_v1(
        &self,
        request: CoreInventoryComputeRequestV1,
    ) -> Result<CoreInventoryComputeResultV1, CoreError> {
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
                .inventory_service
                .compute_with_cancellation(&request.into_runtime_request(), Some(&cancellation))?
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
            inventory_service: runtime::inventory::InventoryComputeService,
            path_match_service: runtime::pathmatch::PathMatchScoreService,
            path_resolve_service: runtime::pathmatch::PathMatchResolveService,
            path_search_service: runtime::pathsearch::PathSearchFindService,
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
}
