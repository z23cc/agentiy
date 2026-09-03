//! ADR-0011 P6-b (B track; design §4.1.1, §7.1, §8 "P6-b"): the bounded synchronous UniFFI
//! surface over the Rust port of the Agent Session Host transcript / snapshot reducer
//! (`agentry_runtime::agent_session_transcript`, mirroring `AgentSessionHostSessionState`).
//!
//! The object owns one value-state reducer behind a mutex. Every call is a collection-bounded
//! pure state transition that returns synchronously (ADR-0001: no async exports, no callbacks)
//! and is wrapped by `PanicGuard`. Time, cursors, and identities are inputs. The host still
//! appends through `AgentSessionLog`; this object never touches a file. No `RuntimeIdentity`:
//! there is no runtime authority to fence. `canonical_state` renders the package-visible Swift
//! state so the differential harness can compare implementations as strings.

use std::sync::{Arc, Mutex, MutexGuard};

use crate::agent_host_types::{
    AgentHostAgentSessionEventV1, AgentHostAgentSessionSnapshotV1, AgentHostCommandAcceptedV1,
    AgentHostPendingInteractionV1, AgentHostSessionStatusV1, AgentHostSessionSummaryV1,
    AgentHostTranscriptEntryV1,
};
use crate::errors::CoreError;
use crate::panic_guard::PanicGuard;
use agentry_proto::agent_host::v1;
use agentry_runtime as runtime;
use agentry_runtime::agent_run_lifecycle::CanonicalValue as _;
use agentry_runtime::agent_session_transcript::SessionState;

fn lock<T>(state: &Mutex<T>) -> Result<MutexGuard<'_, T>, CoreError> {
    state.lock().map_err(|_| CoreError::RuntimePoisoned)
}

fn snapshot_from(
    value: v1::AgentSessionSnapshot,
) -> Result<AgentHostAgentSessionSnapshotV1, CoreError> {
    value.try_into()
}

fn summary_from(value: v1::SessionSummary) -> Result<AgentHostSessionSummaryV1, CoreError> {
    value.try_into()
}

fn entries_from(
    entries: &[v1::TranscriptEntry],
) -> Result<Vec<AgentHostTranscriptEntryV1>, CoreError> {
    entries.iter().cloned().map(TryInto::try_into).collect()
}

fn pending_from(
    pending: &[v1::PendingInteraction],
) -> Result<Vec<AgentHostPendingInteractionV1>, CoreError> {
    pending.iter().cloned().map(TryInto::try_into).collect()
}

fn accepted_from(
    accepted: Vec<v1::CommandAccepted>,
) -> Result<Vec<AgentHostCommandAcceptedV1>, CoreError> {
    accepted.into_iter().map(TryInto::try_into).collect()
}

/// `AgentSessionHostSessionState` in Rust: event → transcript / snapshot value-state reducer.
#[derive(uniffi::Object)]
pub struct AgentSessionTranscriptReducerV1 {
    guard: PanicGuard,
    state: Mutex<SessionState>,
}

#[uniffi::export]
impl AgentSessionTranscriptReducerV1 {
    /// Placeholder for a log whose first record has not been read yet.
    #[uniffi::constructor]
    #[must_use]
    pub fn placeholder(session_id: String) -> Arc<Self> {
        runtime::install_panic_hook();
        Arc::new(Self {
            guard: PanicGuard::new(),
            state: Mutex::new(SessionState::placeholder(session_id)),
        })
    }

    /// `AgentSessionHostSessionState(summary:)`.
    #[uniffi::constructor]
    pub fn from_summary(summary: AgentHostSessionSummaryV1) -> Result<Arc<Self>, CoreError> {
        runtime::install_panic_hook();
        Ok(Arc::new(Self {
            guard: PanicGuard::new(),
            state: Mutex::new(SessionState::from_summary(summary.into())),
        }))
    }

    /// `AgentSessionHostSessionState(snapshot:)`.
    #[uniffi::constructor]
    pub fn from_snapshot(
        snapshot: AgentHostAgentSessionSnapshotV1,
    ) -> Result<Arc<Self>, CoreError> {
        runtime::install_panic_hook();
        Ok(Arc::new(Self {
            guard: PanicGuard::new(),
            state: Mutex::new(SessionState::from_snapshot(snapshot.into())),
        }))
    }

    pub fn reset(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.reset();
            Ok(())
        })
    }

    pub fn apply(&self, event: AgentHostAgentSessionEventV1, cursor: u64) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.apply(&event.into(), cursor);
            Ok(())
        })
    }

    pub fn set_generation(&self, generation: Vec<u8>) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.set_generation(generation);
            Ok(())
        })
    }

    pub fn set_attached_client_count(&self, count: u32) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.set_attached_client_count(count);
            Ok(())
        })
    }

    pub fn snapshot(
        &self,
        generation: Vec<u8>,
        now: String,
    ) -> Result<AgentHostAgentSessionSnapshotV1, CoreError> {
        self.guard
            .call(|| snapshot_from(lock(&self.state)?.snapshot(generation, now)))
    }

    pub fn summary(&self) -> Result<AgentHostSessionSummaryV1, CoreError> {
        self.guard
            .call(|| summary_from(lock(&self.state)?.summary().clone()))
    }

    pub fn host_owned_summary(
        &self,
        status: AgentHostSessionStatusV1,
        status_text: String,
        clearing_active_run: bool,
        now: String,
    ) -> Result<AgentHostSessionSummaryV1, CoreError> {
        self.guard.call(|| {
            summary_from(lock(&self.state)?.host_owned_summary(
                status.into(),
                status_text,
                clearing_active_run,
                now,
            ))
        })
    }

    pub fn last_cursor(&self) -> Result<u64, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.last_cursor()))
    }

    pub fn has_metadata(&self) -> Result<bool, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.has_metadata()))
    }

    pub fn is_terminal(&self) -> Result<bool, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.is_terminal()))
    }

    pub fn has_live_run(&self) -> Result<bool, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.has_live_run()))
    }

    pub fn transcript(&self) -> Result<Vec<AgentHostTranscriptEntryV1>, CoreError> {
        self.guard
            .call(|| entries_from(lock(&self.state)?.transcript()))
    }

    pub fn pending_interactions(&self) -> Result<Vec<AgentHostPendingInteractionV1>, CoreError> {
        self.guard
            .call(|| pending_from(lock(&self.state)?.pending_interactions()))
    }

    pub fn unsettled_operations(&self) -> Result<Vec<AgentHostCommandAcceptedV1>, CoreError> {
        self.guard
            .call(|| accepted_from(lock(&self.state)?.unsettled_operations()))
    }

    pub fn canonical_state(&self) -> Result<String, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.canonical()))
    }
}
