use crate::{
    AdmissionOutcome, AdmissionRequest, CancelOutcome, OperationDiagnostics, OperationId,
    OperationSnapshot, OperationState, RequestFingerprint, RuntimeIdentity, ScopeId,
    TerminalOutcome,
};
use std::collections::HashMap;
use std::fmt;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RegistryError {
    StaleRuntimeIdentity,
    OperationConflict,
    DeadlineExpired,
    InvalidDeadline,
    ShuttingDown,
}

impl fmt::Display for RegistryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::StaleRuntimeIdentity => "stale runtime identity",
            Self::OperationConflict => {
                "operation ID collides with a different fingerprint or scope"
            }
            Self::DeadlineExpired => "operation deadline expired before admission",
            Self::InvalidDeadline => "operation deadline is outside the monotonic clock range",
            Self::ShuttingDown => "runtime is shutting down",
        })
    }
}

impl std::error::Error for RegistryError {}

struct Entry {
    fingerprint: RequestFingerprint,
    scope: ScopeId,
    identity: RuntimeIdentity,
    state: OperationState,
    deadline: Option<Instant>,
}

struct CancelTombstone {
    created: Instant,
}

struct State {
    accepting: bool,
    entries: HashMap<OperationId, Entry>,
    cancel_tombstones: HashMap<OperationId, CancelTombstone>,
    diagnostics: OperationDiagnostics,
}

pub struct OperationRegistry {
    identity: RuntimeIdentity,
    tombstone_window: Duration,
    state: Mutex<State>,
}

impl OperationRegistry {
    pub fn new(identity: RuntimeIdentity, tombstone_window: Duration) -> Self {
        Self {
            identity,
            tombstone_window,
            state: Mutex::new(State {
                accepting: true,
                entries: HashMap::new(),
                cancel_tombstones: HashMap::new(),
                diagnostics: OperationDiagnostics::default(),
            }),
        }
    }

    pub fn identity(&self) -> &RuntimeIdentity {
        &self.identity
    }

    pub fn admit(&self, request: AdmissionRequest) -> Result<AdmissionOutcome, RegistryError> {
        self.admit_at(request, SystemTime::now(), Instant::now())
    }

    pub fn admit_at(
        &self,
        request: AdmissionRequest,
        wall_now: SystemTime,
        monotonic_now: Instant,
    ) -> Result<AdmissionOutcome, RegistryError> {
        self.validate_identity(&request.runtime_identity)?;
        let deadline = convert_deadline(request.deadline_unix_millis, wall_now, monotonic_now)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        prune_tombstones(&mut state, monotonic_now, self.tombstone_window);
        if !state.accepting {
            return Err(RegistryError::ShuttingDown);
        }

        if let Some(entry) = state.entries.get(&request.operation_id) {
            if entry.fingerprint != request.fingerprint || entry.scope != request.scope {
                state.diagnostics.collisions += 1;
                return Err(RegistryError::OperationConflict);
            }
            return Ok(AdmissionOutcome::Duplicate(entry.state));
        }

        let cancelled_before_admission = state
            .cancel_tombstones
            .remove(&request.operation_id)
            .is_some();
        let state_value = if cancelled_before_admission {
            OperationState::Terminal(TerminalOutcome::Cancelled)
        } else {
            OperationState::Admitted
        };
        state.entries.insert(
            request.operation_id,
            Entry {
                fingerprint: request.fingerprint,
                scope: request.scope,
                identity: request.runtime_identity,
                state: state_value,
                deadline,
            },
        );
        Ok(if cancelled_before_admission {
            AdmissionOutcome::Duplicate(state_value)
        } else {
            AdmissionOutcome::Accepted
        })
    }

    pub fn mark_running(
        &self,
        identity: &RuntimeIdentity,
        id: &OperationId,
    ) -> Result<OperationState, RegistryError> {
        self.validate_identity(identity)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(entry) = state.entries.get_mut(id) else {
            return Ok(OperationState::Terminal(TerminalOutcome::Cancelled));
        };
        if entry.state == OperationState::Admitted {
            entry.state = OperationState::Running;
        }
        Ok(entry.state)
    }

    pub fn cancel(
        &self,
        identity: &RuntimeIdentity,
        id: OperationId,
    ) -> Result<CancelOutcome, RegistryError> {
        self.cancel_at(identity, id, Instant::now())
    }

    pub fn cancel_at(
        &self,
        identity: &RuntimeIdentity,
        id: OperationId,
        now: Instant,
    ) -> Result<CancelOutcome, RegistryError> {
        self.validate_identity(identity)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        prune_tombstones(&mut state, now, self.tombstone_window);
        if let Some(entry) = state.entries.get_mut(&id) {
            return Ok(match entry.state {
                OperationState::Admitted | OperationState::Running => {
                    entry.state = OperationState::CancelRequested;
                    CancelOutcome::Requested
                }
                OperationState::CancelRequested => {
                    state.diagnostics.duplicate_cancels += 1;
                    CancelOutcome::AlreadyRequested
                }
                OperationState::Terminal(_) => {
                    state.diagnostics.duplicate_cancels += 1;
                    CancelOutcome::AlreadyTerminal
                }
            });
        }
        if state.cancel_tombstones.contains_key(&id) {
            state.diagnostics.duplicate_cancels += 1;
            return Ok(CancelOutcome::Tombstoned);
        }
        state
            .cancel_tombstones
            .insert(id, CancelTombstone { created: now });
        Ok(CancelOutcome::Tombstoned)
    }

    pub fn resolve_terminal(
        &self,
        identity: &RuntimeIdentity,
        id: &OperationId,
        outcome: TerminalOutcome,
    ) -> Result<OperationState, RegistryError> {
        self.validate_identity(identity)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(entry) = state.entries.get_mut(id) else {
            return Ok(OperationState::Terminal(outcome));
        };
        let was_terminal = entry.state.is_terminal();
        if !was_terminal {
            entry.state = OperationState::Terminal(outcome);
        }
        let terminal_state = entry.state;
        if was_terminal {
            state.diagnostics.late_terminal_results += 1;
        }
        Ok(terminal_state)
    }

    pub fn expire_deadlines(&self, now: Instant) -> usize {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut expired = 0;
        for entry in state.entries.values_mut() {
            if !entry.state.is_terminal() && entry.deadline.is_some_and(|deadline| deadline <= now)
            {
                entry.state = OperationState::Terminal(TerminalOutcome::DeadlineExceeded);
                expired += 1;
            }
        }
        expired
    }

    pub fn begin_shutdown(&self) -> usize {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.accepting = false;
        let mut cancelled = 0;
        for entry in state.entries.values_mut() {
            if !entry.state.is_terminal() {
                entry.state = OperationState::Terminal(TerminalOutcome::Cancelled);
                cancelled += 1;
            }
        }
        state.cancel_tombstones.clear();
        cancelled
    }

    pub fn snapshot(&self, id: &OperationId) -> Option<OperationSnapshot> {
        let state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let entry = state.entries.get(id)?;
        Some(OperationSnapshot {
            operation_id: id.clone(),
            fingerprint: entry.fingerprint.clone(),
            scope: entry.scope.clone(),
            runtime_identity: entry.identity.clone(),
            state: entry.state,
            deadline: entry.deadline,
        })
    }

    pub fn active_count(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .entries
            .values()
            .filter(|entry| !entry.state.is_terminal())
            .count()
    }

    pub fn tombstone_count(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .cancel_tombstones
            .len()
    }

    pub fn diagnostics(&self) -> OperationDiagnostics {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .diagnostics
    }

    fn validate_identity(&self, identity: &RuntimeIdentity) -> Result<(), RegistryError> {
        if identity == &self.identity {
            Ok(())
        } else {
            Err(RegistryError::StaleRuntimeIdentity)
        }
    }
}

fn prune_tombstones(state: &mut State, now: Instant, window: Duration) {
    let before = state.cancel_tombstones.len();
    state
        .cancel_tombstones
        .retain(|_, tombstone| now.saturating_duration_since(tombstone.created) < window);
    state.diagnostics.expired_tombstones += (before - state.cancel_tombstones.len()) as u64;
}

fn convert_deadline(
    deadline_unix_millis: Option<u64>,
    wall_now: SystemTime,
    monotonic_now: Instant,
) -> Result<Option<Instant>, RegistryError> {
    let Some(deadline_millis) = deadline_unix_millis else {
        return Ok(None);
    };
    let now_millis = wall_now
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let deadline_millis = u128::from(deadline_millis);
    if deadline_millis <= now_millis {
        return Err(RegistryError::DeadlineExpired);
    }
    let remaining = u64::try_from(deadline_millis - now_millis).unwrap_or(u64::MAX);
    monotonic_now
        .checked_add(Duration::from_millis(remaining))
        .map(Some)
        .ok_or(RegistryError::InvalidDeadline)
}
