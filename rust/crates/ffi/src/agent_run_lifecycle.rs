//! ADR-0011 P6-a (B track; design §4.1.1, §7.1, §8 "P6-a"): the bounded synchronous UniFFI surface
//! over the Rust port of the Agent Mode run-lifecycle reducers
//! (`agentry_runtime::agent_run_lifecycle`, mirroring `DomainAgentRun*`).
//!
//! Each object owns one value-state reducer behind a mutex. Every call is a constant-time or
//! collection-bounded (512 tombstones) pure state transition that returns synchronously
//! (ADR-0001: no async exports, no callbacks) and is wrapped by `PanicGuard`. Time and identities
//! are inputs: nothing here reads a clock or mints a UUID, which is what makes the Swift ⇄ Rust
//! differential harness (`Tests/RepoPromptDomainRuntimeTests/DomainAgentRunRustDifferentialTests.swift`)
//! deterministic. No object takes a `RuntimeIdentity`: there is no runtime authority to fence, the
//! reducers are pure values the host embeds. `canonical_state` renders the observable state in the
//! fixed JSON form documented in `agent_run_lifecycle::canonical` so two implementations can be
//! compared as strings.

use std::sync::{Arc, Mutex, MutexGuard};

use crate::agent_run_lifecycle_types::{
    AgentRunBeginAttemptV1, AgentRunExecutionOperationEndingV1, AgentRunExecutionReportV1,
    AgentRunFailureReasonV1, AgentRunLifecycleStageV1, AgentRunLifecycleTrackerSnapshotV1,
    AgentRunLivenessSignalKindV1, AgentRunOwnershipV1, AgentRunProcessIdentitySnapshotV1,
    AgentRunProgressAcceptanceV1, AgentRunProgressSignalV1, AgentRunProviderOperationEndingV1,
    AgentRunRetryIntentV1, AgentRunSemanticResolutionV1, AgentRunTeardownRegistrationResultV1,
    AgentRunTerminalCommitBeginResultV1, AgentRunTerminalCommitSnapshotV1,
    AgentRunTerminalOutcomeV1, AgentRunTerminalPublicationResultV1,
    AgentRunTerminalSettlementSnapshotV1, AgentRunTerminationSignalV1, optional_ownership,
    parse_uuid,
};
use crate::errors::CoreError;
use crate::panic_guard::PanicGuard;
use agentry_runtime as runtime;
use agentry_runtime::agent_run_lifecycle::{
    CanonicalValue as _, LifecycleTracker, ProcessIdentityState, SemanticAuthority,
    TerminalCommitState, TerminalSettlementCoordinator,
};

fn lock<T>(state: &Mutex<T>) -> Result<MutexGuard<'_, T>, CoreError> {
    state.lock().map_err(|_| CoreError::RuntimePoisoned)
}

/// `DomainAgentRunLifecycleTracker`: ownership + liveness reducer embedding the terminal-commit
/// phase and process identity for one run host.
#[derive(uniffi::Object)]
pub struct AgentRunLifecycleTrackerV1 {
    guard: PanicGuard,
    state: Mutex<LifecycleTracker>,
}

#[uniffi::export]
impl AgentRunLifecycleTrackerV1 {
    #[uniffi::constructor]
    #[must_use]
    pub fn new() -> Arc<Self> {
        runtime::install_panic_hook();
        Arc::new(Self {
            guard: PanicGuard::new(),
            state: Mutex::new(LifecycleTracker::new()),
        })
    }

    /// Back to the freshly constructed value (Swift: `= DomainAgentRunLifecycleTracker()`).
    pub fn reset(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            *lock(&self.state)? = LifecycleTracker::new();
            Ok(())
        })
    }

    pub fn begin(&self, attempt: AgentRunBeginAttemptV1) -> Result<AgentRunOwnershipV1, CoreError> {
        self.guard.call(|| {
            let attempt = attempt.try_into()?;
            Ok(lock(&self.state)?.begin(attempt).into())
        })
    }

    /// Mints the next sequence and accepts the resulting signal (Swift `record(...)`).
    pub fn record(
        &self,
        ownership: AgentRunOwnershipV1,
        kind: AgentRunLivenessSignalKindV1,
        stage: AgentRunLifecycleStageV1,
        retry_intent: AgentRunRetryIntentV1,
        timestamp_uptime_nanoseconds: u64,
    ) -> Result<AgentRunProgressAcceptanceV1, CoreError> {
        self.guard.call(|| {
            let ownership = ownership.try_into()?;
            Ok(lock(&self.state)?
                .record(
                    ownership,
                    kind.into(),
                    stage.into(),
                    retry_intent.into(),
                    timestamp_uptime_nanoseconds,
                )
                .into())
        })
    }

    /// Accepts a caller-sequenced signal (Swift `accept(_:)`).
    pub fn accept(
        &self,
        signal: AgentRunProgressSignalV1,
    ) -> Result<AgentRunProgressAcceptanceV1, CoreError> {
        self.guard.call(|| {
            let signal = signal.try_into()?;
            Ok(lock(&self.state)?.accept(signal).into())
        })
    }

    /// Ends the active attempt; with `expected_ownership`, only if it is still the owner.
    pub fn end(&self, expected_ownership: Option<AgentRunOwnershipV1>) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let expected = optional_ownership(expected_ownership)?;
            Ok(lock(&self.state)?.end(expected))
        })
    }

    pub fn install_process_run_id(&self, run_id: String) -> Result<(), CoreError> {
        self.guard.call(|| {
            let run_id = parse_uuid("runId", &run_id)?;
            lock(&self.state)?.install_process_run_id(run_id);
            Ok(())
        })
    }

    pub fn clear_process_run_id_if_current(&self, run_id: String) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let run_id = parse_uuid("runId", &run_id)?;
            Ok(lock(&self.state)?.clear_process_run_id_if_current(run_id))
        })
    }

    pub fn force_clear_process_run_id(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.force_clear_process_run_id();
            Ok(())
        })
    }

    pub fn bump_terminal_drain_generation(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.bump_terminal_drain_generation();
            Ok(())
        })
    }

    pub fn begin_terminal_commit(&self) -> Result<AgentRunTerminalCommitBeginResultV1, CoreError> {
        self.guard
            .call(|| Ok(lock(&self.state)?.begin_terminal_commit().into()))
    }

    pub fn stage_terminal_commit(
        &self,
        commit_id: String,
        ownership: AgentRunOwnershipV1,
    ) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let commit_id = parse_uuid("commitId", &commit_id)?;
            let ownership = ownership.try_into()?;
            Ok(lock(&self.state)?.stage_terminal_commit(commit_id, ownership))
        })
    }

    pub fn record_terminal_publication_result(
        &self,
        result: AgentRunTerminalPublicationResultV1,
    ) -> Result<(), CoreError> {
        self.guard.call(|| {
            let result = result.try_into()?;
            lock(&self.state)?.record_terminal_publication_result(result);
            Ok(())
        })
    }

    pub fn abort_terminal_commit(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.abort_terminal_commit();
            Ok(())
        })
    }

    pub fn complete_terminal_commit(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.complete_terminal_commit();
            Ok(())
        })
    }

    pub fn invalidate_terminal_commit(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.invalidate_terminal_commit();
            Ok(())
        })
    }

    pub fn has_terminal_commit(&self, ownership: AgentRunOwnershipV1) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let ownership = ownership.try_into()?;
            Ok(lock(&self.state)?.has_terminal_commit(ownership))
        })
    }

    /// Every `package`-visible property of the Swift tracker, typed.
    pub fn state(&self) -> Result<AgentRunLifecycleTrackerSnapshotV1, CoreError> {
        self.guard.call(|| Ok((&*lock(&self.state)?).into()))
    }

    /// Fixed-format JSON of `state()` for string comparison across implementations.
    pub fn canonical_state(&self) -> Result<String, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.canonical()))
    }
}

/// `DomainAgentRunProcessIdentityState`: provider process UUID and terminal-drain generation.
#[derive(uniffi::Object)]
pub struct AgentRunProcessIdentityStateV1 {
    guard: PanicGuard,
    state: Mutex<ProcessIdentityState>,
}

#[uniffi::export]
impl AgentRunProcessIdentityStateV1 {
    /// Swift `init(runID:terminalDrainGeneration:)`.
    #[uniffi::constructor]
    pub fn new(
        run_id: Option<String>,
        terminal_drain_generation: u64,
    ) -> Result<Arc<Self>, CoreError> {
        runtime::install_panic_hook();
        let run_id = run_id
            .as_deref()
            .map(|value| parse_uuid("runId", value))
            .transpose()?;
        Ok(Arc::new(Self {
            guard: PanicGuard::new(),
            state: Mutex::new(ProcessIdentityState::with(
                run_id,
                terminal_drain_generation,
            )),
        }))
    }

    pub fn install(&self, run_id: String) -> Result<(), CoreError> {
        self.guard.call(|| {
            let run_id = parse_uuid("runId", &run_id)?;
            lock(&self.state)?.install(run_id);
            Ok(())
        })
    }

    pub fn clear_if_current(&self, run_id: String) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let run_id = parse_uuid("runId", &run_id)?;
            Ok(lock(&self.state)?.clear_if_current(run_id))
        })
    }

    pub fn force_clear(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.force_clear();
            Ok(())
        })
    }

    pub fn bump_terminal_drain_generation(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.bump_terminal_drain_generation();
            Ok(())
        })
    }

    pub fn reset_for_new_attempt(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.reset_for_new_attempt();
            Ok(())
        })
    }

    pub fn state(&self) -> Result<AgentRunProcessIdentitySnapshotV1, CoreError> {
        self.guard.call(|| Ok((&*lock(&self.state)?).into()))
    }

    pub fn canonical_state(&self) -> Result<String, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.canonical()))
    }
}

/// `DomainAgentRunTerminalCommitState`: the exclusive terminal-commit phase and its receipts.
#[derive(uniffi::Object)]
pub struct AgentRunTerminalCommitStateV1 {
    guard: PanicGuard,
    state: Mutex<TerminalCommitState>,
}

#[uniffi::export]
impl AgentRunTerminalCommitStateV1 {
    #[uniffi::constructor]
    #[must_use]
    pub fn new() -> Arc<Self> {
        runtime::install_panic_hook();
        Arc::new(Self {
            guard: PanicGuard::new(),
            state: Mutex::new(TerminalCommitState::new()),
        })
    }

    pub fn begin(
        &self,
        ownership: Option<AgentRunOwnershipV1>,
    ) -> Result<AgentRunTerminalCommitBeginResultV1, CoreError> {
        self.guard.call(|| {
            let ownership = optional_ownership(ownership)?;
            Ok(lock(&self.state)?.begin(ownership).into())
        })
    }

    pub fn stage(
        &self,
        commit_id: String,
        ownership: AgentRunOwnershipV1,
    ) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let commit_id = parse_uuid("commitId", &commit_id)?;
            let ownership = ownership.try_into()?;
            Ok(lock(&self.state)?.stage(commit_id, ownership))
        })
    }

    pub fn record(&self, result: AgentRunTerminalPublicationResultV1) -> Result<(), CoreError> {
        self.guard.call(|| {
            let result = result.try_into()?;
            lock(&self.state)?.record(result);
            Ok(())
        })
    }

    pub fn abort(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.abort();
            Ok(())
        })
    }

    pub fn complete(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.complete();
            Ok(())
        })
    }

    pub fn invalidate(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.invalidate();
            Ok(())
        })
    }

    pub fn reset(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.reset();
            Ok(())
        })
    }

    pub fn matches(&self, ownership: AgentRunOwnershipV1) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let ownership = ownership.try_into()?;
            Ok(lock(&self.state)?.matches(ownership))
        })
    }

    pub fn state(&self) -> Result<AgentRunTerminalCommitSnapshotV1, CoreError> {
        self.guard.call(|| Ok((&*lock(&self.state)?).into()))
    }

    pub fn canonical_state(&self) -> Result<String, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.canonical()))
    }
}

/// `DomainAgentRunTerminalSettlementCoordinator`: bounded successor tombstones and
/// ownership-bound teardown tokens.
#[derive(uniffi::Object)]
pub struct AgentRunTerminalSettlementCoordinatorV1 {
    guard: PanicGuard,
    state: Mutex<TerminalSettlementCoordinator>,
}

#[uniffi::export]
impl AgentRunTerminalSettlementCoordinatorV1 {
    #[uniffi::constructor]
    #[must_use]
    pub fn new() -> Arc<Self> {
        runtime::install_panic_hook();
        Arc::new(Self {
            guard: PanicGuard::new(),
            state: Mutex::new(TerminalSettlementCoordinator::new()),
        })
    }

    pub fn has_consumed_provider_successor(&self, id: String) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let id = parse_uuid("successorId", &id)?;
            Ok(lock(&self.state)?.has_consumed_provider_successor(id))
        })
    }

    /// Returns whether a new tombstone was recorded.
    pub fn record_provider_successor_consumption(
        &self,
        id: String,
        delivery_succeeded: bool,
    ) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let id = parse_uuid("successorId", &id)?;
            Ok(lock(&self.state)?.record_provider_successor_consumption(id, delivery_succeeded))
        })
    }

    pub fn register_teardown(
        &self,
        ownership: AgentRunOwnershipV1,
        token: String,
    ) -> Result<AgentRunTeardownRegistrationResultV1, CoreError> {
        self.guard.call(|| {
            let ownership = ownership.try_into()?;
            let token = parse_uuid("token", &token)?;
            Ok(lock(&self.state)?
                .register_teardown(ownership, token)
                .into())
        })
    }

    pub fn has_pending_teardown(&self, ownership: AgentRunOwnershipV1) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let ownership = ownership.try_into()?;
            Ok(lock(&self.state)?.has_pending_teardown(ownership))
        })
    }

    /// Lowercase UUID text of the registered token, if any.
    pub fn teardown_token(
        &self,
        ownership: AgentRunOwnershipV1,
    ) -> Result<Option<String>, CoreError> {
        self.guard.call(|| {
            let ownership = ownership.try_into()?;
            Ok(lock(&self.state)?
                .teardown_token(ownership)
                .map(|token| token.to_string()))
        })
    }

    pub fn complete_teardown(
        &self,
        ownership: AgentRunOwnershipV1,
        token: String,
    ) -> Result<bool, CoreError> {
        self.guard.call(|| {
            let ownership = ownership.try_into()?;
            let token = parse_uuid("token", &token)?;
            Ok(lock(&self.state)?.complete_teardown(ownership, token))
        })
    }

    pub fn reset(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            lock(&self.state)?.reset();
            Ok(())
        })
    }

    pub fn state(&self) -> Result<AgentRunTerminalSettlementSnapshotV1, CoreError> {
        self.guard.call(|| Ok((&*lock(&self.state)?).into()))
    }

    pub fn canonical_state(&self) -> Result<String, CoreError> {
        self.guard.call(|| Ok(lock(&self.state)?.canonical()))
    }
}

/// `DomainAgentRunProviderSemanticAuthority` plus the pure classification half of
/// `DomainAgentRunExecutionCore`. Stateless; one per process is plenty.
#[derive(uniffi::Object)]
pub struct AgentRunSemanticAuthorityV1 {
    guard: PanicGuard,
}

#[uniffi::export]
impl AgentRunSemanticAuthorityV1 {
    #[uniffi::constructor]
    #[must_use]
    pub fn new() -> Arc<Self> {
        runtime::install_panic_hook();
        Arc::new(Self {
            guard: PanicGuard::new(),
        })
    }

    pub fn resolve(
        &self,
        signal: AgentRunTerminationSignalV1,
    ) -> Result<AgentRunSemanticResolutionV1, CoreError> {
        self.guard
            .call(|| Ok(SemanticAuthority::resolve(&signal.into()).into()))
    }

    pub fn outcome(
        &self,
        signal: AgentRunTerminationSignalV1,
    ) -> Result<Option<AgentRunTerminalOutcomeV1>, CoreError> {
        self.guard
            .call(|| Ok(SemanticAuthority::outcome(&signal.into()).map(Into::into)))
    }

    pub fn is_terminal(&self, signal: AgentRunTerminationSignalV1) -> Result<bool, CoreError> {
        self.guard
            .call(|| Ok(SemanticAuthority::is_terminal(&signal.into())))
    }

    /// Classification of `DomainAgentRunExecutionCore.execute(failureReason:deferFailureClassification:)`
    /// given how the operation ended.
    pub fn classify_execution(
        &self,
        ending: AgentRunExecutionOperationEndingV1,
        failure_reason: AgentRunFailureReasonV1,
        defer_failure_classification: bool,
    ) -> Result<AgentRunExecutionReportV1, CoreError> {
        self.guard.call(|| {
            Ok(SemanticAuthority::classify_execution(
                ending.into(),
                failure_reason.into(),
                defer_failure_classification,
            )
            .into())
        })
    }

    /// Classification of `DomainAgentRunExecutionCore.executeProvider` given how the operation ended.
    pub fn classify_provider_execution(
        &self,
        ending: AgentRunProviderOperationEndingV1,
    ) -> Result<AgentRunExecutionReportV1, CoreError> {
        self.guard
            .call(|| Ok(SemanticAuthority::classify_provider_execution(ending.into()).into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_run_lifecycle_types::{
        AgentRunBindingIdentityV1, AgentRunProgressRejectionV1, AgentRunTerminalOutcomeKindV1,
    };

    const TAB: &str = "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081";
    const SESSION: &str = "11111111-2222-3333-4444-555555555555";
    const ATTEMPT: &str = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const GENERATION: &str = "ffffffff-0000-1111-2222-333333333333";

    fn attempt(timestamp: u64) -> AgentRunBeginAttemptV1 {
        AgentRunBeginAttemptV1 {
            tab_id: TAB.to_owned(),
            persistent_session_id: Some(SESSION.to_owned()),
            persistent_binding_generation: None,
            binding_transition_generation: 0,
            binding_generation: GENERATION.to_owned(),
            attempt_id: ATTEMPT.to_owned(),
            turn_epoch: None,
            timestamp_uptime_nanoseconds: timestamp,
        }
    }

    #[test]
    fn tracker_object_round_trips_typed_mirrors_and_canonical_state() {
        let tracker = AgentRunLifecycleTrackerV1::new();
        let ownership = tracker.begin(attempt(100)).unwrap();
        assert_eq!(
            ownership,
            AgentRunOwnershipV1 {
                attempt_id: ATTEMPT.to_owned(),
                binding: AgentRunBindingIdentityV1 {
                    tab_id: TAB.to_owned(),
                    persistent_session_id: Some(SESSION.to_owned()),
                    persistent_binding_generation: None,
                    binding_transition_generation: 0,
                    generation: GENERATION.to_owned(),
                },
                turn_epoch: None,
            }
        );
        // Uppercase UUID text is accepted and canonicalized.
        let uppercase = AgentRunOwnershipV1 {
            attempt_id: ATTEMPT.to_uppercase(),
            ..ownership.clone()
        };
        let accepted = tracker
            .record(
                uppercase,
                AgentRunLivenessSignalKindV1::ProviderEvent,
                AgentRunLifecycleStageV1::Running,
                AgentRunRetryIntentV1::None,
                200,
            )
            .unwrap();
        let AgentRunProgressAcceptanceV1::Accepted { snapshot } = accepted else {
            panic!("expected acceptance");
        };
        assert_eq!(snapshot.last_accepted_sequence, 1);
        assert_eq!(snapshot.stage, AgentRunLifecycleStageV1::Running);

        let state = tracker.state().unwrap();
        assert_eq!(state.active_ownership, Some(ownership.clone()));
        assert_eq!(state.liveness, Some(snapshot));
        assert!(!state.terminal_commit_in_progress);
        let canonical = tracker.canonical_state().unwrap();
        assert!(canonical.starts_with("{\"activeOwnership\":{\"attemptID\":"));

        assert!(tracker.end(Some(ownership.clone())).unwrap());
        assert_eq!(
            tracker
                .record(
                    ownership,
                    AgentRunLivenessSignalKindV1::Heartbeat,
                    AgentRunLifecycleStageV1::Running,
                    AgentRunRetryIntentV1::None,
                    300,
                )
                .unwrap(),
            AgentRunProgressAcceptanceV1::Rejected {
                rejection: AgentRunProgressRejectionV1::NoActiveOwnership
            }
        );
        tracker.reset().unwrap();
        assert_eq!(
            tracker.canonical_state().unwrap(),
            AgentRunLifecycleTrackerV1::new().canonical_state().unwrap()
        );
    }

    #[test]
    fn invalid_uuid_text_fails_closed() {
        let tracker = AgentRunLifecycleTrackerV1::new();
        assert!(matches!(
            tracker.install_process_run_id("not-a-uuid".to_owned()),
            Err(CoreError::AgentRunLifecycleInvalidRequest { message }) if message.starts_with("runId:")
        ));
        assert!(matches!(
            tracker.begin(AgentRunBeginAttemptV1 {
                tab_id: "nope".to_owned(),
                ..attempt(1)
            }),
            Err(CoreError::AgentRunLifecycleInvalidRequest { .. })
        ));
        assert!(matches!(
            AgentRunProcessIdentityStateV1::new(Some("bad".to_owned()), 0),
            Err(CoreError::AgentRunLifecycleInvalidRequest { .. })
        ));
    }

    #[test]
    fn settlement_and_semantic_objects_expose_swift_observable_surface() {
        let coordinator = AgentRunTerminalSettlementCoordinatorV1::new();
        assert!(
            coordinator
                .record_provider_successor_consumption(TAB.to_owned(), true)
                .unwrap()
        );
        assert!(
            coordinator
                .has_consumed_provider_successor(TAB.to_uppercase())
                .unwrap()
        );
        let state = coordinator.state().unwrap();
        assert_eq!(state.consumed_provider_successor_count, 1);
        assert_eq!(state.max_provider_successor_tombstones, 512);

        let authority = AgentRunSemanticAuthorityV1::new();
        let report = authority
            .classify_provider_execution(AgentRunProviderOperationEndingV1::ThrewError {
                failure_text: "boom".to_owned(),
            })
            .unwrap();
        assert_eq!(
            report.result,
            crate::agent_run_lifecycle_types::AgentRunExecutionResultV1::Terminal {
                outcome: AgentRunTerminalOutcomeV1 {
                    kind: AgentRunTerminalOutcomeKindV1::Failed,
                    assistant_text: Some("boom".to_owned()),
                    failure_reason: None,
                }
            }
        );
        assert!(
            !authority
                .is_terminal(AgentRunTerminationSignalV1::Superseded)
                .unwrap()
        );
    }
}
