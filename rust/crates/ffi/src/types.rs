use crate::errors::CoreError;
use agentry_runtime as runtime;

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct RuntimeIdentity {
    pub abi_epoch: u32,
    pub instance_nonce: String,
    pub build_fingerprint: String,
    pub binding_checksum: String,
}

impl RuntimeIdentity {
    pub(crate) fn parse(&self) -> Result<runtime::RuntimeIdentity, CoreError> {
        Ok(runtime::RuntimeIdentity::new(
            self.abi_epoch,
            self.instance_nonce.clone(),
            self.build_fingerprint.clone(),
            self.binding_checksum.clone(),
        )?)
    }
}

impl From<&runtime::RuntimeIdentity> for RuntimeIdentity {
    fn from(value: &runtime::RuntimeIdentity) -> Self {
        Self {
            abi_epoch: value.abi_epoch(),
            instance_nonce: value.instance_nonce().to_owned(),
            build_fingerprint: value.build_fingerprint().to_owned(),
            binding_checksum: value.binding_checksum().to_owned(),
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CoreConfig {
    pub expected_abi_epoch: u32,
    pub expected_build_fingerprint: String,
    pub expected_binding_checksum: String,
    pub data_lane_capacity: u64,
    pub cancel_tombstone_millis: u64,
    pub shutdown_grace_millis: u64,
}

impl CoreConfig {
    pub(crate) fn runtime_config(&self) -> Result<runtime::RuntimeConfig, CoreError> {
        let data_lane_capacity =
            usize::try_from(self.data_lane_capacity).map_err(|_| CoreError::InvalidArgument)?;
        if data_lane_capacity == 0
            || self.cancel_tombstone_millis == 0
            || self.shutdown_grace_millis == 0
        {
            return Err(CoreError::InvalidArgument);
        }
        Ok(runtime::RuntimeConfig {
            data_lane_capacity,
            cancel_tombstone_window: std::time::Duration::from_millis(self.cancel_tombstone_millis),
            shutdown_grace: std::time::Duration::from_millis(self.shutdown_grace_millis),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CoreHandshake {
    pub runtime_identity: RuntimeIdentity,
    pub abi_epoch: u32,
    pub payload_schema_versions: Vec<u16>,
    pub build_fingerprint: String,
    pub binding_checksum: String,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct OperationId {
    pub value: String,
}

impl OperationId {
    pub(crate) fn parse(&self) -> Result<runtime::OperationId, CoreError> {
        Ok(runtime::OperationId::parse(self.value.clone())?)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct ScopeId {
    pub value: String,
}

impl ScopeId {
    pub(crate) fn parse(&self) -> Result<runtime::ScopeId, CoreError> {
        Ok(runtime::ScopeId::parse(self.value.clone())?)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct RequestFingerprint {
    pub value: String,
}

impl RequestFingerprint {
    pub(crate) fn parse(&self) -> Result<runtime::RequestFingerprint, CoreError> {
        Ok(runtime::RequestFingerprint::parse(self.value.clone())?)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CommandEnvelope {
    pub runtime_identity: RuntimeIdentity,
    pub operation_id: OperationId,
    pub request_fingerprint: RequestFingerprint,
    pub scope_id: ScopeId,
    pub deadline_unix_millis: Option<u64>,
    pub payload: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum AdmissionDisposition {
    Accepted,
    Duplicate,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum OperationState {
    Admitted,
    Running,
    CancelRequested,
    Succeeded,
    Cancelled,
    DeadlineExceeded,
    Failed,
}

impl From<runtime::OperationState> for OperationState {
    fn from(value: runtime::OperationState) -> Self {
        match value {
            runtime::OperationState::Admitted => Self::Admitted,
            runtime::OperationState::Running => Self::Running,
            runtime::OperationState::CancelRequested => Self::CancelRequested,
            runtime::OperationState::Terminal(runtime::TerminalOutcome::Success) => Self::Succeeded,
            runtime::OperationState::Terminal(runtime::TerminalOutcome::Cancelled) => {
                Self::Cancelled
            }
            runtime::OperationState::Terminal(runtime::TerminalOutcome::DeadlineExceeded) => {
                Self::DeadlineExceeded
            }
            runtime::OperationState::Terminal(runtime::TerminalOutcome::Failed) => Self::Failed,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct AdmissionReceipt {
    pub runtime_identity: RuntimeIdentity,
    pub operation_id: OperationId,
    pub disposition: AdmissionDisposition,
    pub state: OperationState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum CancelDisposition {
    Requested,
    Tombstoned,
    AlreadyRequested,
    AlreadyTerminal,
}

impl From<runtime::CancelOutcome> for CancelDisposition {
    fn from(value: runtime::CancelOutcome) -> Self {
        match value {
            runtime::CancelOutcome::Requested => Self::Requested,
            runtime::CancelOutcome::Tombstoned => Self::Tombstoned,
            runtime::CancelOutcome::AlreadyRequested => Self::AlreadyRequested,
            runtime::CancelOutcome::AlreadyTerminal => Self::AlreadyTerminal,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct CancelReceipt {
    pub operation_id: OperationId,
    pub disposition: CancelDisposition,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct SubscriptionScope {
    pub runtime_identity: RuntimeIdentity,
    pub scope_id: ScopeId,
    pub max_queued_events: u64,
    pub max_queued_bytes: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct SubscriptionId {
    pub value: u64,
    pub runtime_identity: RuntimeIdentity,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct SubscriptionBootstrap {
    pub subscription_id: SubscriptionId,
    pub stream_id: u64,
    pub initial_snapshot: Vec<u8>,
    pub next_delivery_cursor: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, uniffi::Enum)]
pub enum RuntimeEventKind {
    Admitted,
    Progress,
    Data,
    Gap,
    HostRequest,
    PayloadRejected,
    Terminal,
}

impl From<runtime::RuntimeEventKind> for RuntimeEventKind {
    fn from(value: runtime::RuntimeEventKind) -> Self {
        match value {
            runtime::RuntimeEventKind::Admitted => Self::Admitted,
            runtime::RuntimeEventKind::Progress => Self::Progress,
            runtime::RuntimeEventKind::Data => Self::Data,
            runtime::RuntimeEventKind::Gap => Self::Gap,
            runtime::RuntimeEventKind::HostRequest => Self::HostRequest,
            runtime::RuntimeEventKind::PayloadRejected => Self::PayloadRejected,
            runtime::RuntimeEventKind::Terminal => Self::Terminal,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct RuntimeEvent {
    pub kind: RuntimeEventKind,
    pub authority_sequence: u64,
    pub delivery_cursor: u64,
    pub payload: Vec<u8>,
    pub payload_omitted: bool,
}

impl From<runtime::RuntimeEvent> for RuntimeEvent {
    fn from(value: runtime::RuntimeEvent) -> Self {
        Self {
            kind: value.kind.into(),
            authority_sequence: value.authority_sequence,
            delivery_cursor: value.delivery_cursor,
            payload: value.payload,
            payload_omitted: value.payload_omitted,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct OversizeEvent {
    pub kind: RuntimeEventKind,
    pub actual_bytes: u64,
    pub maximum_bytes: u64,
    pub resnapshot_required: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct DrainBatch {
    pub events: Vec<RuntimeEvent>,
    pub has_more: bool,
    pub next_delivery_cursor: u64,
    pub dropped_count: u64,
    pub oversize: Option<OversizeEvent>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct HostResponse {
    pub runtime_identity: RuntimeIdentity,
    pub request_id: String,
    pub payload: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct ShutdownReceipt {
    pub already_started: bool,
    pub cancelled_operations: u64,
}
