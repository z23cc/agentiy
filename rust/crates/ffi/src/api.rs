use crate::errors::CoreError;
use crate::generated::contract_identity::{
    ABI_EPOCH, BINDING_CHECKSUM, CORE_BUILD_FINGERPRINT, PAYLOAD_SCHEMA_VERSIONS,
};
use crate::panic_guard::PanicGuard;
use crate::types::{
    AdmissionDisposition, AdmissionReceipt, CancelReceipt, CommandEnvelope, CompactRegexBatchResult,
    CoreConfig, CoreHandshake, DrainBatch, FolderSuffixRequest, HostResponse, OperationState,
    OversizeEvent,
    PathFilterRequest, PathFilterResult, RegexSearchBatchRequest, RegexSearchRequest,
    RegexSearchResult, RuntimeEvent, RuntimeIdentity, ShutdownReceipt, SubscriptionBootstrap,
    SubscriptionId, SubscriptionScope,
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
}
