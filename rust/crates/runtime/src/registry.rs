use crate::{
    AdmissionOutcome, AdmissionRequest, CancelOutcome, ManagedOperationDirective,
    ManagedOperationStopReason, OperationDiagnostics, OperationId, OperationSnapshot,
    OperationState, RequestFingerprint, RuntimeIdentity, ScopeId, TerminalOutcome,
};
use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex};
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
                "operation ID collides with a different fingerprint, scope, or execution authority"
            }
            Self::DeadlineExpired => "operation deadline expired before admission",
            Self::InvalidDeadline => "operation deadline is outside the monotonic clock range",
            Self::ShuttingDown => "runtime is shutting down",
        })
    }
}

impl std::error::Error for RegistryError {}

#[derive(Clone, Copy)]
enum EntryKind {
    RuntimeTask,
    Managed {
        generation: u64,
        stop_reason: Option<ManagedOperationStopReason>,
        authority_started: bool,
    },
}

struct Entry {
    fingerprint: RequestFingerprint,
    scope: ScopeId,
    identity: RuntimeIdentity,
    state: OperationState,
    deadline: Option<Instant>,
    kind: EntryKind,
}

struct CancelTombstone {
    created: Instant,
}

struct State {
    accepting: bool,
    entries: HashMap<OperationId, Entry>,
    cancel_tombstones: HashMap<OperationId, CancelTombstone>,
    next_managed_generation: u64,
    diagnostics: OperationDiagnostics,
}

pub struct OperationRegistry {
    identity: RuntimeIdentity,
    tombstone_window: Duration,
    state: Mutex<State>,
}

/// Exact runtime-lifetime attachment for work driven outside Tokio. The separate generation keeps
/// stale lifecycle handles from detaching or resolving a later workspace execution claim.
#[derive(Clone)]
pub struct ManagedOperationClaim {
    registry: Arc<OperationRegistry>,
    operation_id: OperationId,
    fingerprint: RequestFingerprint,
    scope: ScopeId,
    identity: RuntimeIdentity,
    generation: u64,
}

impl fmt::Debug for ManagedOperationClaim {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ManagedOperationClaim")
            .field("operation_id", &self.operation_id)
            .field("generation", &self.generation)
            .finish_non_exhaustive()
    }
}

impl ManagedOperationClaim {
    pub fn operation_id(&self) -> &OperationId {
        &self.operation_id
    }

    pub fn fingerprint(&self) -> &RequestFingerprint {
        &self.fingerprint
    }

    pub fn scope(&self) -> &ScopeId {
        &self.scope
    }

    pub fn identity(&self) -> &RuntimeIdentity {
        &self.identity
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn checkpoint(&self) -> Result<ManagedOperationDirective, RegistryError> {
        self.checkpoint_at(Instant::now())
    }

    pub fn checkpoint_at(&self, now: Instant) -> Result<ManagedOperationDirective, RegistryError> {
        self.registry.checkpoint_managed(self, now)
    }

    pub fn begin_authority(&self) -> Result<ManagedOperationDirective, RegistryError> {
        self.begin_authority_at(Instant::now())
    }

    pub fn begin_authority_at(
        &self,
        now: Instant,
    ) -> Result<ManagedOperationDirective, RegistryError> {
        self.registry.begin_managed_authority(self, now)
    }

    pub fn resolve_terminal(
        &self,
        outcome: TerminalOutcome,
    ) -> Result<OperationState, RegistryError> {
        self.registry.resolve_managed_terminal(self, outcome)
    }

    pub fn abandon(&self) -> Result<bool, RegistryError> {
        self.abandon_at(Instant::now())
    }

    pub fn abandon_at(&self, now: Instant) -> Result<bool, RegistryError> {
        self.registry.abandon_managed(self, now)
    }
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
                next_managed_generation: 0,
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
                kind: EntryKind::RuntimeTask,
            },
        );
        Ok(if cancelled_before_admission {
            AdmissionOutcome::Duplicate(state_value)
        } else {
            AdmissionOutcome::Accepted
        })
    }

    pub fn attach_managed(
        self: &Arc<Self>,
        request: AdmissionRequest,
    ) -> Result<(ManagedOperationClaim, ManagedOperationDirective), RegistryError> {
        self.attach_managed_at(request, SystemTime::now(), Instant::now())
    }

    pub fn attach_managed_at(
        self: &Arc<Self>,
        request: AdmissionRequest,
        wall_now: SystemTime,
        monotonic_now: Instant,
    ) -> Result<(ManagedOperationClaim, ManagedOperationDirective), RegistryError> {
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
            if let EntryKind::Managed { generation, .. } = entry.kind
                && matches!(
                    entry.state,
                    OperationState::Terminal(
                        TerminalOutcome::Cancelled | TerminalOutcome::DeadlineExceeded
                    )
                )
            {
                let claim = ManagedOperationClaim {
                    registry: Arc::clone(self),
                    operation_id: request.operation_id,
                    fingerprint: request.fingerprint,
                    scope: request.scope,
                    identity: request.runtime_identity,
                    generation,
                };
                return Ok((claim, directive_for_entry(entry)));
            }
            state.diagnostics.collisions += 1;
            return Err(RegistryError::OperationConflict);
        }

        state.next_managed_generation = state
            .next_managed_generation
            .checked_add(1)
            .ok_or(RegistryError::OperationConflict)?;
        let generation = state.next_managed_generation;
        let cancelled_before_admission = state
            .cancel_tombstones
            .remove(&request.operation_id)
            .is_some();
        let stop_reason =
            cancelled_before_admission.then_some(ManagedOperationStopReason::Cancelled);
        let state_value = if cancelled_before_admission {
            OperationState::CancelRequested
        } else {
            OperationState::Running
        };
        let claim = ManagedOperationClaim {
            registry: Arc::clone(self),
            operation_id: request.operation_id.clone(),
            fingerprint: request.fingerprint.clone(),
            scope: request.scope.clone(),
            identity: request.runtime_identity.clone(),
            generation,
        };
        state.entries.insert(
            request.operation_id,
            Entry {
                fingerprint: request.fingerprint,
                scope: request.scope,
                identity: request.runtime_identity,
                state: state_value,
                deadline,
                kind: EntryKind::Managed {
                    generation,
                    stop_reason,
                    authority_started: false,
                },
            },
        );
        let directive = state
            .entries
            .get(&claim.operation_id)
            .map(directive_for_entry)
            .ok_or(RegistryError::OperationConflict)?;
        Ok((claim, directive))
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
            return Ok(match &mut entry.kind {
                EntryKind::Managed {
                    stop_reason,
                    authority_started,
                    ..
                } => {
                    if entry.state.is_terminal() || *authority_started {
                        state.diagnostics.duplicate_cancels += 1;
                        CancelOutcome::AlreadyTerminal
                    } else if stop_reason.is_some() {
                        state.diagnostics.duplicate_cancels += 1;
                        CancelOutcome::AlreadyRequested
                    } else {
                        *stop_reason = Some(ManagedOperationStopReason::Cancelled);
                        entry.state = OperationState::CancelRequested;
                        CancelOutcome::Requested
                    }
                }
                EntryKind::RuntimeTask => match entry.state {
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
                },
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
            if entry.state.is_terminal() || !entry.deadline.is_some_and(|deadline| deadline <= now)
            {
                continue;
            }
            match &mut entry.kind {
                EntryKind::Managed {
                    stop_reason,
                    authority_started,
                    ..
                } if !*authority_started => {
                    if stop_reason.is_none() {
                        *stop_reason = Some(ManagedOperationStopReason::DeadlineExceeded);
                        entry.state = OperationState::CancelRequested;
                        expired += 1;
                    }
                }
                EntryKind::Managed { .. } => {}
                EntryKind::RuntimeTask => {
                    entry.state = OperationState::Terminal(TerminalOutcome::DeadlineExceeded);
                    expired += 1;
                }
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
            if entry.state.is_terminal() {
                continue;
            }
            match &mut entry.kind {
                EntryKind::Managed {
                    stop_reason,
                    authority_started,
                    ..
                } if !*authority_started => {
                    if stop_reason.is_none() {
                        *stop_reason = Some(ManagedOperationStopReason::ShutdownRequested);
                        entry.state = OperationState::CancelRequested;
                        cancelled += 1;
                    }
                }
                EntryKind::Managed { .. } => {}
                EntryKind::RuntimeTask => {
                    entry.state = OperationState::Terminal(TerminalOutcome::Cancelled);
                    cancelled += 1;
                }
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

    fn checkpoint_managed(
        &self,
        claim: &ManagedOperationClaim,
        now: Instant,
    ) -> Result<ManagedOperationDirective, RegistryError> {
        self.validate_identity(&claim.identity)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let entry = exact_managed_entry_mut(&mut state, claim)?;
        apply_managed_deadline(entry, now);
        Ok(directive_for_entry(entry))
    }

    fn begin_managed_authority(
        &self,
        claim: &ManagedOperationClaim,
        now: Instant,
    ) -> Result<ManagedOperationDirective, RegistryError> {
        self.validate_identity(&claim.identity)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let entry = exact_managed_entry_mut(&mut state, claim)?;
        apply_managed_deadline(entry, now);
        let directive = directive_for_entry(entry);
        if directive != ManagedOperationDirective::ContinueExecution {
            return Ok(directive);
        }
        let EntryKind::Managed {
            authority_started, ..
        } = &mut entry.kind
        else {
            return Err(RegistryError::OperationConflict);
        };
        *authority_started = true;
        Ok(ManagedOperationDirective::ContinueExecution)
    }

    fn resolve_managed_terminal(
        &self,
        claim: &ManagedOperationClaim,
        outcome: TerminalOutcome,
    ) -> Result<OperationState, RegistryError> {
        self.validate_identity(&claim.identity)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (terminal_state, was_terminal) = {
            let entry = exact_managed_entry_mut(&mut state, claim)?;
            let was_terminal = entry.state.is_terminal();
            if !was_terminal {
                entry.state = OperationState::Terminal(outcome);
            }
            (entry.state, was_terminal)
        };
        if was_terminal {
            state.diagnostics.late_terminal_results += 1;
        }
        Ok(terminal_state)
    }

    fn abandon_managed(
        &self,
        claim: &ManagedOperationClaim,
        now: Instant,
    ) -> Result<bool, RegistryError> {
        self.validate_identity(&claim.identity)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (stop_reason, terminal) = {
            let entry = exact_managed_entry_mut(&mut state, claim)?;
            let EntryKind::Managed { stop_reason, .. } = entry.kind else {
                return Err(RegistryError::OperationConflict);
            };
            (stop_reason, entry.state.is_terminal())
        };
        if terminal {
            return Ok(false);
        }
        state.entries.remove(&claim.operation_id);
        if stop_reason == Some(ManagedOperationStopReason::Cancelled) {
            state
                .cancel_tombstones
                .insert(claim.operation_id.clone(), CancelTombstone { created: now });
        }
        Ok(true)
    }

    fn validate_identity(&self, identity: &RuntimeIdentity) -> Result<(), RegistryError> {
        if identity == &self.identity {
            Ok(())
        } else {
            Err(RegistryError::StaleRuntimeIdentity)
        }
    }
}

fn exact_managed_entry_mut<'a>(
    state: &'a mut State,
    claim: &ManagedOperationClaim,
) -> Result<&'a mut Entry, RegistryError> {
    let entry = state
        .entries
        .get_mut(&claim.operation_id)
        .ok_or(RegistryError::OperationConflict)?;
    let generation = match entry.kind {
        EntryKind::Managed { generation, .. } => generation,
        EntryKind::RuntimeTask => return Err(RegistryError::OperationConflict),
    };
    if generation != claim.generation
        || entry.fingerprint != claim.fingerprint
        || entry.scope != claim.scope
        || entry.identity != claim.identity
    {
        return Err(RegistryError::OperationConflict);
    }
    Ok(entry)
}

fn apply_managed_deadline(entry: &mut Entry, now: Instant) {
    if entry.state.is_terminal() || !entry.deadline.is_some_and(|deadline| deadline <= now) {
        return;
    }
    if let EntryKind::Managed {
        stop_reason,
        authority_started,
        ..
    } = &mut entry.kind
        && !*authority_started
        && stop_reason.is_none()
    {
        *stop_reason = Some(ManagedOperationStopReason::DeadlineExceeded);
        entry.state = OperationState::CancelRequested;
    }
}

fn directive_for_entry(entry: &Entry) -> ManagedOperationDirective {
    if let OperationState::Terminal(outcome) = entry.state {
        return ManagedOperationDirective::Terminal(outcome);
    }
    match entry.kind {
        EntryKind::Managed {
            stop_reason: Some(reason),
            ..
        } => ManagedOperationDirective::Stop(reason),
        _ => ManagedOperationDirective::ContinueExecution,
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
