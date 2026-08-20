use crate::{RuntimeIdentity, ScopeId, WakePipe, WakePipeError};
use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::os::fd::OwnedFd;
use std::sync::{Arc, Mutex};

const EVENT_OVERHEAD_BYTES: usize = 64;
pub const DEFAULT_MAX_QUEUED_EVENTS: usize = 256;
pub const DEFAULT_MAX_QUEUED_BYTES: usize = 1_048_576;
pub const RESERVED_TERMINAL_SLOTS: usize = 1;
pub const RESERVED_TERMINAL_CONTROL_BYTES: usize = 4_096;
pub const DEFAULT_DRAIN_MAX_EVENTS: usize = 64;
pub const DEFAULT_DRAIN_MAX_BYTES: usize = 262_144;
pub const HARD_DRAIN_MAX_EVENTS: usize = 256;
pub const HARD_DRAIN_MAX_BYTES: usize = 1_048_576;
pub const MINIMUM_DRAIN_MAX_BYTES: usize = 4_096;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct SubscriptionId(u64);
impl SubscriptionId {
    pub const fn from_value(value: u64) -> Option<Self> {
        if value == 0 { None } else { Some(Self(value)) }
    }

    pub const fn value(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct StreamId(u64);
impl StreamId {
    pub const fn value(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SubscriptionConfig {
    pub max_queued_events: usize,
    pub max_queued_bytes: usize,
    pub reserved_terminal_slots: usize,
    pub reserved_terminal_control_bytes: usize,
}

impl Default for SubscriptionConfig {
    fn default() -> Self {
        Self {
            max_queued_events: DEFAULT_MAX_QUEUED_EVENTS,
            max_queued_bytes: DEFAULT_MAX_QUEUED_BYTES,
            reserved_terminal_slots: RESERVED_TERMINAL_SLOTS,
            reserved_terminal_control_bytes: RESERVED_TERMINAL_CONTROL_BYTES,
        }
    }
}

impl SubscriptionConfig {
    fn validate(&self) -> Result<(), SubscriptionError> {
        if self.max_queued_events <= self.reserved_terminal_slots
            || self.max_queued_bytes <= self.reserved_terminal_control_bytes
            || self.reserved_terminal_slots == 0
        {
            return Err(SubscriptionError::InvalidLimits);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EventClass {
    Lossless,
    Coalescible,
    Droppable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeEventKind {
    Admitted,
    Progress,
    Data,
    Gap,
    HostRequest,
    PayloadRejected,
    Terminal,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EventDetail {
    Payload,
    Gap {
        first_sequence: u64,
        last_sequence: u64,
        dropped_count: u64,
    },
    PayloadRejected {
        actual_bytes: usize,
        maximum_bytes: usize,
        resnapshot_required: bool,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EventInput {
    pub kind: RuntimeEventKind,
    pub class: EventClass,
    pub payload: Vec<u8>,
    pub coalesce_key: Option<String>,
}

impl EventInput {
    pub fn data(payload: impl Into<Vec<u8>>) -> Self {
        Self {
            kind: RuntimeEventKind::Data,
            class: EventClass::Droppable,
            payload: payload.into(),
            coalesce_key: None,
        }
    }

    pub fn terminal(payload: impl Into<Vec<u8>>) -> Self {
        Self {
            kind: RuntimeEventKind::Terminal,
            class: EventClass::Lossless,
            payload: payload.into(),
            coalesce_key: None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeEvent {
    pub kind: RuntimeEventKind,
    pub class: EventClass,
    pub authority_sequence: u64,
    pub delivery_cursor: u64,
    pub payload: Vec<u8>,
    pub detail: EventDetail,
    pub payload_omitted: bool,
    coalesce_key: Option<String>,
    counted: bool,
}

impl RuntimeEvent {
    fn wire_size(&self) -> usize {
        EVENT_OVERHEAD_BYTES.saturating_add(self.payload.len())
    }
    fn counted_size(&self) -> usize {
        if self.counted { self.wire_size() } else { 0 }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SubscriptionBootstrap {
    pub subscription_id: SubscriptionId,
    pub stream_id: StreamId,
    pub runtime_identity: RuntimeIdentity,
    pub initial_snapshot: Vec<u8>,
    pub next_delivery_cursor: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct PublishSummary {
    pub enqueued: usize,
    pub dropped: usize,
    pub payload_rejected: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DrainBatch {
    pub events: Vec<RuntimeEvent>,
    pub has_more: bool,
    pub next_delivery_cursor: u64,
    pub dropped_count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OversizeDrain {
    pub kind: RuntimeEventKind,
    pub actual_bytes: usize,
    pub maximum_bytes: usize,
    pub resnapshot_required: bool,
    pub has_more: bool,
    pub next_delivery_cursor: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DrainOutcome {
    Batch(DrainBatch),
    Oversize(OversizeDrain),
}

#[derive(Debug)]
pub enum SubscriptionError {
    StaleRuntimeIdentity,
    SubscriptionNotFound,
    InvalidLimits,
    QueueLimitExceeded,
    RuntimeStopped,
    Wake(WakePipeError),
}

impl fmt::Display for SubscriptionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::StaleRuntimeIdentity => "stale runtime identity",
            Self::SubscriptionNotFound => "subscription not found",
            Self::InvalidLimits => "invalid subscription or drain limits",
            Self::QueueLimitExceeded => "lossless event cannot fit in the reserved queue",
            Self::RuntimeStopped => "runtime is stopped",
            Self::Wake(_) => "wake pipe operation failed",
        })
    }
}

impl std::error::Error for SubscriptionError {}
impl From<WakePipeError> for SubscriptionError {
    fn from(value: WakePipeError) -> Self {
        Self::Wake(value)
    }
}

#[derive(Clone)]
struct Queue {
    scope: ScopeId,
    config: SubscriptionConfig,
    events: VecDeque<RuntimeEvent>,
    queued_bytes: usize,
    next_cursor: u64,
    dropped_total: u64,
}

impl Queue {
    fn is_empty(&self) -> bool {
        self.events.is_empty()
    }
    fn data_event_limit(&self) -> usize {
        self.config.max_queued_events - self.config.reserved_terminal_slots
    }
    fn data_byte_limit(&self) -> usize {
        self.config.max_queued_bytes - self.config.reserved_terminal_control_bytes
    }

    fn next_cursor(&mut self) -> u64 {
        let cursor = self.next_cursor;
        self.next_cursor = self.next_cursor.saturating_add(1);
        cursor
    }

    fn add_gap(&mut self, sequence: u64) {
        self.dropped_total = self.dropped_total.saturating_add(1);
        if let Some(gap) = self
            .events
            .iter_mut()
            .rev()
            .find(|event| matches!(event.detail, EventDetail::Gap { .. }))
            && let EventDetail::Gap {
                last_sequence,
                dropped_count,
                ..
            } = &mut gap.detail
        {
            *last_sequence = sequence;
            *dropped_count = dropped_count.saturating_add(1);
            return;
        }
        let cursor = self.next_cursor();
        self.events.push_back(RuntimeEvent {
            kind: RuntimeEventKind::Gap,
            class: EventClass::Lossless,
            authority_sequence: sequence,
            delivery_cursor: cursor,
            payload: Vec::new(),
            detail: EventDetail::Gap {
                first_sequence: sequence,
                last_sequence: sequence,
                dropped_count: 1,
            },
            payload_omitted: false,
            coalesce_key: None,
            counted: false,
        });
    }

    fn can_fit(&self, bytes: usize, lossless: bool) -> bool {
        let count_limit = if lossless {
            self.config.max_queued_events
        } else {
            self.data_event_limit()
        };
        let byte_limit = if lossless {
            self.config.max_queued_bytes
        } else {
            self.data_byte_limit()
        };
        self.events.iter().filter(|event| event.counted).count() < count_limit
            && self.queued_bytes.saturating_add(bytes) <= byte_limit
    }

    fn evict_one_lossy(&mut self) -> Option<u64> {
        let index = self
            .events
            .iter()
            .position(|event| event.counted && event.class != EventClass::Lossless)?;
        let removed = self.events.remove(index)?;
        self.queued_bytes = self.queued_bytes.saturating_sub(removed.counted_size());
        Some(removed.authority_sequence)
    }

    fn enqueue(
        &mut self,
        sequence: u64,
        mut input: EventInput,
    ) -> Result<EnqueueResult, SubscriptionError> {
        let maximum_payload = self.data_byte_limit().saturating_sub(EVENT_OVERHEAD_BYTES);
        if input.payload.len() > maximum_payload && input.kind != RuntimeEventKind::Terminal {
            let actual = input.payload.len();
            input = EventInput {
                kind: RuntimeEventKind::PayloadRejected,
                class: EventClass::Lossless,
                payload: Vec::new(),
                coalesce_key: None,
            };
            return self
                .enqueue_prepared(
                    sequence,
                    input,
                    EventDetail::PayloadRejected {
                        actual_bytes: actual,
                        maximum_bytes: maximum_payload,
                        resnapshot_required: true,
                    },
                    false,
                )
                .map(|_| EnqueueResult::PayloadRejected);
        }

        let mut payload_omitted = false;
        if input.kind == RuntimeEventKind::Terminal && input.payload.len() > maximum_payload {
            input.payload.clear();
            payload_omitted = true;
        }
        self.enqueue_prepared(sequence, input, EventDetail::Payload, payload_omitted)
    }

    fn enqueue_prepared(
        &mut self,
        sequence: u64,
        input: EventInput,
        detail: EventDetail,
        payload_omitted: bool,
    ) -> Result<EnqueueResult, SubscriptionError> {
        let bytes = EVENT_OVERHEAD_BYTES.saturating_add(input.payload.len());
        if input.class == EventClass::Coalescible
            && let Some(key) = input.coalesce_key.as_ref()
            && let Some(index) = self
                .events
                .iter()
                .position(|event| event.coalesce_key.as_ref() == Some(key))
        {
            let old_size = self.events[index].counted_size();
            let new_total = self
                .queued_bytes
                .saturating_sub(old_size)
                .saturating_add(bytes);
            if new_total <= self.data_byte_limit() {
                let event = &mut self.events[index];
                event.authority_sequence = sequence;
                event.payload = input.payload;
                event.detail = detail;
                event.payload_omitted = payload_omitted;
                self.queued_bytes = new_total;
                return Ok(EnqueueResult::Coalesced);
            }
        }

        let lossless = input.class == EventClass::Lossless;
        if lossless {
            let mut evicted = Vec::new();
            while !self.can_fit(bytes, true) {
                let Some(sequence) = self.evict_one_lossy() else {
                    return Err(SubscriptionError::QueueLimitExceeded);
                };
                evicted.push(sequence);
            }
            for sequence in evicted {
                self.add_gap(sequence);
            }
        } else if !self.can_fit(bytes, false) {
            self.add_gap(sequence);
            return Ok(EnqueueResult::Dropped);
        }

        let cursor = self.next_cursor();
        let event = RuntimeEvent {
            kind: input.kind,
            class: input.class,
            authority_sequence: sequence,
            delivery_cursor: cursor,
            payload: input.payload,
            detail,
            payload_omitted,
            coalesce_key: input.coalesce_key,
            counted: true,
        };
        self.queued_bytes = self.queued_bytes.saturating_add(event.counted_size());
        self.events.push_back(event);
        Ok(EnqueueResult::Enqueued)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EnqueueResult {
    Enqueued,
    Coalesced,
    Dropped,
    PayloadRejected,
}

struct HubState {
    identity: RuntimeIdentity,
    stopped: bool,
    next_subscription_id: u64,
    next_stream_id: u64,
    publication_sequence: u64,
    wake_armed: bool,
    wake: Arc<WakePipe>,
    queues: HashMap<SubscriptionId, Queue>,
}

pub struct SubscriptionHub {
    state: Mutex<HubState>,
}

impl SubscriptionHub {
    pub fn new(identity: RuntimeIdentity) -> Result<Self, SubscriptionError> {
        Ok(Self {
            state: Mutex::new(HubState {
                identity,
                stopped: false,
                next_subscription_id: 1,
                next_stream_id: 1,
                publication_sequence: 0,
                wake_armed: false,
                wake: Arc::new(WakePipe::new()?),
                queues: HashMap::new(),
            }),
        })
    }

    pub fn open_subscription<F>(
        &self,
        identity: &RuntimeIdentity,
        scope: ScopeId,
        config: SubscriptionConfig,
        snapshot: F,
    ) -> Result<SubscriptionBootstrap, SubscriptionError>
    where
        F: FnOnce() -> Vec<u8>,
    {
        config.validate()?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        validate_state(&state, identity)?;
        // The provider runs while the same mutex that serializes publication is
        // held, so the bytes and next delivery cursor describe one atomic point.
        let initial_snapshot = snapshot();
        if initial_snapshot.len() > config.max_queued_bytes {
            return Err(SubscriptionError::QueueLimitExceeded);
        }
        let subscription_id = SubscriptionId(state.next_subscription_id);
        state.next_subscription_id = state.next_subscription_id.saturating_add(1);
        let stream_id = StreamId(state.next_stream_id);
        state.next_stream_id = state.next_stream_id.saturating_add(1);
        state.queues.insert(
            subscription_id,
            Queue {
                scope,
                config,
                events: VecDeque::new(),
                queued_bytes: 0,
                next_cursor: 1,
                dropped_total: 0,
            },
        );
        Ok(SubscriptionBootstrap {
            subscription_id,
            stream_id,
            runtime_identity: state.identity.clone(),
            initial_snapshot,
            next_delivery_cursor: 1,
        })
    }

    pub fn publish(
        &self,
        identity: &RuntimeIdentity,
        scope: &ScopeId,
        input: EventInput,
    ) -> Result<PublishSummary, SubscriptionError> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        validate_state(&state, identity)?;
        let sequence = state.publication_sequence.saturating_add(1);
        let mut summary = PublishSummary::default();
        let mut staged = Vec::new();
        for (subscription_id, queue) in state
            .queues
            .iter()
            .filter(|(_, queue)| &queue.scope == scope)
        {
            let mut staged_queue = queue.clone();
            match staged_queue.enqueue(sequence, input.clone())? {
                EnqueueResult::Enqueued | EnqueueResult::Coalesced => summary.enqueued += 1,
                EnqueueResult::Dropped => summary.dropped += 1,
                EnqueueResult::PayloadRejected => summary.payload_rejected += 1,
            }
            staged.push((*subscription_id, staged_queue));
        }
        state.publication_sequence = sequence;
        for (subscription_id, queue) in staged {
            state.queues.insert(subscription_id, queue);
        }
        let is_nonempty = state.queues.values().any(|queue| !queue.is_empty());
        if is_nonempty && !state.wake_armed {
            match state.wake.signal() {
                Ok(_) => state.wake_armed = true,
                Err(error) => {
                    state.wake_armed = false;
                    return Err(error.into());
                }
            }
        }
        Ok(summary)
    }

    pub fn try_drain(
        &self,
        identity: &RuntimeIdentity,
        subscription_id: SubscriptionId,
        max_events: usize,
        max_bytes: usize,
    ) -> Result<DrainOutcome, SubscriptionError> {
        if max_events == 0
            || max_events > HARD_DRAIN_MAX_EVENTS
            || !(MINIMUM_DRAIN_MAX_BYTES..=HARD_DRAIN_MAX_BYTES).contains(&max_bytes)
        {
            return Err(SubscriptionError::InvalidLimits);
        }
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        validate_state(&state, identity)?;
        let queue = state
            .queues
            .get_mut(&subscription_id)
            .ok_or(SubscriptionError::SubscriptionNotFound)?;

        if let Some(first) = queue.events.front()
            && first.wire_size() > max_bytes
        {
            let event = queue.events.pop_front().expect("front existed");
            queue.queued_bytes = queue.queued_bytes.saturating_sub(event.counted_size());
            return Ok(DrainOutcome::Oversize(OversizeDrain {
                kind: event.kind,
                actual_bytes: event.wire_size(),
                maximum_bytes: max_bytes,
                resnapshot_required: true,
                has_more: !queue.events.is_empty(),
                next_delivery_cursor: queue
                    .events
                    .front()
                    .map_or(queue.next_cursor, |event| event.delivery_cursor),
            }));
        }

        let mut events = Vec::new();
        let mut bytes = 0_usize;
        while events.len() < max_events {
            let Some(front) = queue.events.front() else {
                break;
            };
            let event_bytes = front.wire_size();
            if bytes.saturating_add(event_bytes) > max_bytes {
                break;
            }
            let event = queue.events.pop_front().expect("front existed");
            queue.queued_bytes = queue.queued_bytes.saturating_sub(event.counted_size());
            bytes += event_bytes;
            events.push(event);
        }
        Ok(DrainOutcome::Batch(DrainBatch {
            events,
            has_more: !queue.events.is_empty(),
            next_delivery_cursor: queue
                .events
                .front()
                .map_or(queue.next_cursor, |event| event.delivery_cursor),
            dropped_count: queue.dropped_total,
        }))
    }

    pub fn duplicate_wake_read_fd(
        &self,
        identity: &RuntimeIdentity,
    ) -> Result<OwnedFd, SubscriptionError> {
        let state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        validate_state(&state, identity)?;
        Ok(state.wake.duplicate_read_fd()?)
    }

    pub fn rearm_and_recheck(&self, identity: &RuntimeIdentity) -> Result<bool, SubscriptionError> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        validate_state(&state, identity)?;
        let has_events = state.queues.values().any(|queue| !queue.is_empty());
        if has_events {
            match state.wake.signal() {
                Ok(_) => state.wake_armed = true,
                Err(error) => {
                    state.wake_armed = false;
                    return Err(error.into());
                }
            }
        } else {
            state.wake_armed = false;
        }
        Ok(has_events)
    }

    pub fn close_subscription(
        &self,
        identity: &RuntimeIdentity,
        id: SubscriptionId,
    ) -> Result<bool, SubscriptionError> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        validate_state(&state, identity)?;
        Ok(state.queues.remove(&id).is_some())
    }

    pub fn replace_identity(
        &self,
        old: &RuntimeIdentity,
        new: RuntimeIdentity,
    ) -> Result<(), SubscriptionError> {
        let replacement_wake = Arc::new(WakePipe::new()?);
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        validate_state(&state, old)?;
        let old_wake = Arc::clone(&state.wake);
        state.identity = new;
        state.queues.clear();
        state.wake_armed = false;
        state.wake = replacement_wake;
        old_wake.close();
        Ok(())
    }

    pub fn shutdown(&self, identity: &RuntimeIdentity) -> Result<usize, SubscriptionError> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        validate_state(&state, identity)?;
        if state.stopped {
            return Ok(0);
        }
        state.stopped = true;
        let count = state.queues.len();
        state.queues.clear();
        state.wake_armed = false;
        state.wake.close();
        Ok(count)
    }

    pub fn subscription_count(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .queues
            .len()
    }
}

fn validate_state(state: &HubState, identity: &RuntimeIdentity) -> Result<(), SubscriptionError> {
    if &state.identity != identity {
        return Err(SubscriptionError::StaleRuntimeIdentity);
    }
    if state.stopped {
        return Err(SubscriptionError::RuntimeStopped);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_wake_signal_leaves_hub_disarmed() {
        let identity = RuntimeIdentity::new(1, "a".repeat(32), "b".repeat(64), "c".repeat(64))
            .expect("identity");
        let scope = ScopeId::from_u128(1);
        let hub = SubscriptionHub::new(identity.clone()).expect("hub");
        hub.open_subscription(
            &identity,
            scope.clone(),
            SubscriptionConfig::default(),
            Vec::new,
        )
        .expect("subscription");
        {
            let state = hub
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state.wake.close();
        }

        assert!(matches!(
            hub.publish(&identity, &scope, EventInput::data(b"event".to_vec())),
            Err(SubscriptionError::Wake(WakePipeError::Closed))
        ));
        {
            let mut state = hub
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            assert!(!state.wake_armed);
            assert!(state.queues.values().any(|queue| !queue.is_empty()));
            state.wake = Arc::new(WakePipe::new().expect("replacement wake"));
        }

        hub.publish(&identity, &scope, EventInput::data(b"retry".to_vec()))
            .expect("retry publication");
        let state = hub
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        assert!(state.wake_armed);
    }
}
