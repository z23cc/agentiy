//! Port of `DomainAgentRunLifecycleTracker` (P14): the provider-neutral ownership and liveness
//! reducer that embeds the terminal-commit phase (P15) and process identity (P18) for one run
//! host. It never touches transcript, persistence, UI, provider state, or tasks.

use super::process_identity::ProcessIdentityState;
use super::terminal_commit::{
    TerminalCommitBeginResult, TerminalCommitReceipt, TerminalCommitState,
};
use super::types::{
    BindingIdentity, LifecycleStage, LivenessSignalKind, LivenessSnapshot, Ownership,
    ProgressAcceptance, ProgressRejection, ProgressSignal, RetryIntent, TerminalPublicationResult,
    TurnEpoch,
};
use super::uuid::RunUuid;

/// Inputs to [`LifecycleTracker::begin`]. Swift mints `attempt_id` and `binding_generation`
/// with `UUID()` when the caller omits them; the reducer here never mints, so both are required.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct BeginAttempt {
    pub tab_id: RunUuid,
    pub persistent_session_id: Option<RunUuid>,
    pub persistent_binding_generation: Option<RunUuid>,
    pub binding_transition_generation: u64,
    pub binding_generation: RunUuid,
    pub attempt_id: RunUuid,
    pub turn_epoch: Option<TurnEpoch>,
    pub timestamp_uptime_nanoseconds: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LifecycleTracker {
    active_ownership: Option<Ownership>,
    liveness: Option<LivenessSnapshot>,
    next_sequence: u64,
    terminal_commit: TerminalCommitState,
    process_identity: ProcessIdentityState,
}

impl Default for LifecycleTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl LifecycleTracker {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            active_ownership: None,
            liveness: None,
            next_sequence: 1,
            terminal_commit: TerminalCommitState::new(),
            process_identity: ProcessIdentityState::new(),
        }
    }

    #[must_use]
    pub const fn active_ownership(&self) -> Option<&Ownership> {
        self.active_ownership.as_ref()
    }

    #[must_use]
    pub const fn liveness(&self) -> Option<&LivenessSnapshot> {
        self.liveness.as_ref()
    }

    /// Swift keeps this private; exposed read-only so canonical state can include it.
    #[must_use]
    pub const fn next_sequence(&self) -> u64 {
        self.next_sequence
    }

    #[must_use]
    pub const fn terminal_commit(&self) -> &TerminalCommitState {
        &self.terminal_commit
    }

    #[must_use]
    pub const fn process_identity(&self) -> &ProcessIdentityState {
        &self.process_identity
    }

    // MARK: Process identity (P18)

    #[must_use]
    pub const fn process_run_id(&self) -> Option<RunUuid> {
        self.process_identity.run_id()
    }

    #[must_use]
    pub const fn terminal_drain_generation(&self) -> u64 {
        self.process_identity.terminal_drain_generation()
    }

    pub const fn install_process_run_id(&mut self, run_id: RunUuid) {
        self.process_identity.install(run_id);
    }

    pub fn clear_process_run_id_if_current(&mut self, run_id: RunUuid) -> bool {
        self.process_identity.clear_if_current(run_id)
    }

    pub const fn force_clear_process_run_id(&mut self) {
        self.process_identity.force_clear();
    }

    pub const fn bump_terminal_drain_generation(&mut self) {
        self.process_identity.bump_terminal_drain_generation();
    }

    // MARK: Ownership and liveness (P14)

    pub fn begin(&mut self, attempt: BeginAttempt) -> Ownership {
        let ownership = Ownership {
            attempt_id: attempt.attempt_id,
            binding: BindingIdentity {
                tab_id: attempt.tab_id,
                persistent_session_id: attempt.persistent_session_id,
                persistent_binding_generation: attempt.persistent_binding_generation,
                binding_transition_generation: attempt.binding_transition_generation,
                generation: attempt.binding_generation,
            },
            turn_epoch: attempt.turn_epoch,
        };
        self.active_ownership = Some(ownership);
        self.liveness = Some(LivenessSnapshot {
            ownership,
            stage: LifecycleStage::Starting,
            retry_intent: RetryIntent::None,
            last_accepted_sequence: 0,
            last_signal_uptime_nanoseconds: attempt.timestamp_uptime_nanoseconds,
            last_real_progress_uptime_nanoseconds: attempt.timestamp_uptime_nanoseconds,
            last_heartbeat_uptime_nanoseconds: None,
        });
        self.next_sequence = 1;
        self.terminal_commit.reset();
        self.process_identity.reset_for_new_attempt();
        ownership
    }

    /// Mints the next sequence and accepts the resulting signal.
    pub fn record(
        &mut self,
        ownership: Ownership,
        kind: LivenessSignalKind,
        stage: LifecycleStage,
        retry_intent: RetryIntent,
        timestamp_uptime_nanoseconds: u64,
    ) -> ProgressAcceptance {
        let signal = ProgressSignal {
            ownership,
            sequence: self.next_sequence,
            timestamp_uptime_nanoseconds,
            kind,
            stage,
            retry_intent,
        };
        self.next_sequence = self.next_sequence.wrapping_add(1);
        self.accept(signal)
    }

    pub fn accept(&mut self, signal: ProgressSignal) -> ProgressAcceptance {
        let (Some(active_ownership), Some(mut snapshot)) = (self.active_ownership, self.liveness)
        else {
            return ProgressAcceptance::Rejected(ProgressRejection::NoActiveOwnership);
        };
        if signal.ownership != active_ownership {
            return ProgressAcceptance::Rejected(ProgressRejection::StaleOwnership);
        }
        if signal.sequence == snapshot.last_accepted_sequence {
            return ProgressAcceptance::Rejected(ProgressRejection::DuplicateSequence);
        }
        if signal.sequence <= snapshot.last_accepted_sequence {
            return ProgressAcceptance::Rejected(ProgressRejection::OutOfOrderSequence);
        }
        if signal.timestamp_uptime_nanoseconds < snapshot.last_signal_uptime_nanoseconds {
            return ProgressAcceptance::Rejected(ProgressRejection::NonMonotonicTimestamp);
        }

        snapshot.stage = signal.stage;
        snapshot.retry_intent = signal.retry_intent;
        snapshot.last_accepted_sequence = signal.sequence;
        snapshot.last_signal_uptime_nanoseconds = signal.timestamp_uptime_nanoseconds;
        if signal.kind == LivenessSignalKind::Heartbeat {
            snapshot.last_heartbeat_uptime_nanoseconds = Some(signal.timestamp_uptime_nanoseconds);
        } else {
            snapshot.last_real_progress_uptime_nanoseconds = signal.timestamp_uptime_nanoseconds;
        }
        self.liveness = Some(snapshot);
        self.next_sequence = self.next_sequence.max(signal.sequence.wrapping_add(1));
        ProgressAcceptance::Accepted(snapshot)
    }

    /// Ends the active attempt; with `expected_ownership`, only if it is still the owner.
    pub fn end(&mut self, expected_ownership: Option<Ownership>) -> bool {
        let Some(active_ownership) = self.active_ownership else {
            return false;
        };
        if let Some(expected) = expected_ownership
            && expected != active_ownership
        {
            return false;
        }
        self.active_ownership = None;
        self.liveness = None;
        self.next_sequence = 1;
        true
    }

    // MARK: Terminal commit (P15)

    #[must_use]
    pub const fn terminal_commit_in_progress(&self) -> bool {
        self.terminal_commit.is_in_progress()
    }

    #[must_use]
    pub const fn terminal_commit_publication_result(&self) -> Option<&TerminalPublicationResult> {
        self.terminal_commit.publication_result()
    }

    #[must_use]
    pub const fn terminal_commit_receipt(&self) -> Option<&TerminalCommitReceipt> {
        self.terminal_commit.staged_receipt()
    }

    #[must_use]
    pub fn has_terminal_commit(&self, ownership: Ownership) -> bool {
        self.terminal_commit.matches(ownership)
    }

    pub fn begin_terminal_commit(&mut self) -> TerminalCommitBeginResult {
        self.terminal_commit.begin(self.active_ownership)
    }

    pub fn stage_terminal_commit(&mut self, commit_id: RunUuid, ownership: Ownership) -> bool {
        self.terminal_commit.stage(commit_id, ownership)
    }

    pub fn record_terminal_publication_result(&mut self, result: TerminalPublicationResult) {
        self.terminal_commit.record(result);
    }

    pub const fn abort_terminal_commit(&mut self) {
        self.terminal_commit.abort();
    }

    pub const fn complete_terminal_commit(&mut self) {
        self.terminal_commit.complete();
    }

    pub fn invalidate_terminal_commit(&mut self) {
        self.terminal_commit.invalidate();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_run_lifecycle::types::EpochTransitionKind;

    fn uuid(byte: u8) -> RunUuid {
        RunUuid::from_bytes([byte; 16])
    }

    fn attempt(seed: u8, timestamp: u64) -> BeginAttempt {
        BeginAttempt {
            tab_id: uuid(10),
            persistent_session_id: Some(uuid(11)),
            persistent_binding_generation: None,
            binding_transition_generation: 0,
            binding_generation: uuid(seed.wrapping_add(100)),
            attempt_id: uuid(seed),
            turn_epoch: None,
            timestamp_uptime_nanoseconds: timestamp,
        }
    }

    fn epoch(ordinal: u64) -> TurnEpoch {
        TurnEpoch {
            runtime_id: uuid(20),
            runtime_generation: 1,
            session_id: uuid(11),
            activation_id: uuid(21),
            registration_generation: 1,
            id: uuid(30 + u8::try_from(ordinal).unwrap()),
            ordinal,
            continuity_generation: 0,
            transition_kind: EpochTransitionKind::Initial,
        }
    }

    fn accepted(acceptance: ProgressAcceptance) -> LivenessSnapshot {
        match acceptance {
            ProgressAcceptance::Accepted(snapshot) => snapshot,
            ProgressAcceptance::Rejected(rejection) => panic!("rejected: {rejection:?}"),
        }
    }

    /// Mirrors `testBeginRecordsOwnershipAndInitialLiveness`.
    #[test]
    fn begin_records_ownership_and_initial_liveness() {
        let mut tracker = LifecycleTracker::new();
        let ownership = tracker.begin(attempt(1, 100));
        assert_eq!(tracker.active_ownership(), Some(&ownership));
        let liveness = tracker.liveness().copied().unwrap();
        assert_eq!(liveness.ownership, ownership);
        assert_eq!(liveness.stage, LifecycleStage::Starting);
        assert_eq!(liveness.retry_intent, RetryIntent::None);
        assert_eq!(liveness.last_accepted_sequence, 0);
        assert_eq!(liveness.last_signal_uptime_nanoseconds, 100);
        assert_eq!(liveness.last_real_progress_uptime_nanoseconds, 100);
        assert_eq!(liveness.last_heartbeat_uptime_nanoseconds, None);
        assert_eq!(ownership.binding.tab_id, uuid(10));
        assert_eq!(ownership.binding.persistent_session_id, Some(uuid(11)));
    }

    /// Mirrors `testStaleOwnershipSignalsAreRejected`.
    #[test]
    fn stale_ownership_signals_are_rejected() {
        let mut tracker = LifecycleTracker::new();
        let first = tracker.begin(attempt(1, 100));
        let second = tracker.begin(attempt(2, 200));
        assert_ne!(first, second);
        assert_eq!(
            tracker.record(
                first,
                LivenessSignalKind::ProviderEvent,
                LifecycleStage::Running,
                RetryIntent::None,
                300
            ),
            ProgressAcceptance::Rejected(ProgressRejection::StaleOwnership)
        );
        let snapshot = accepted(tracker.record(
            second,
            LivenessSignalKind::ProviderEvent,
            LifecycleStage::Running,
            RetryIntent::None,
            300,
        ));
        assert_eq!(snapshot.stage, LifecycleStage::Running);
        assert_eq!(
            snapshot.last_accepted_sequence, 2,
            "stale record still consumed a sequence"
        );
    }

    /// Mirrors `testSequenceAndTimestampViolationsAreRejected`.
    #[test]
    fn sequence_and_timestamp_violations_are_rejected() {
        let mut tracker = LifecycleTracker::new();
        let ownership = tracker.begin(attempt(1, 100));
        let signal = |sequence: u64, timestamp: u64| ProgressSignal {
            ownership,
            sequence,
            timestamp_uptime_nanoseconds: timestamp,
            kind: LivenessSignalKind::ProviderEvent,
            stage: LifecycleStage::Running,
            retry_intent: RetryIntent::None,
        };
        accepted(tracker.accept(signal(1, 200)));
        assert_eq!(
            tracker.accept(signal(1, 300)),
            ProgressAcceptance::Rejected(ProgressRejection::DuplicateSequence)
        );
        assert_eq!(
            tracker.accept(signal(0, 300)),
            ProgressAcceptance::Rejected(ProgressRejection::OutOfOrderSequence)
        );
        assert_eq!(
            tracker.accept(signal(2, 150)),
            ProgressAcceptance::Rejected(ProgressRejection::NonMonotonicTimestamp)
        );
        let snapshot = accepted(tracker.accept(signal(5, 200)));
        assert_eq!(snapshot.last_accepted_sequence, 5);
        assert_eq!(tracker.next_sequence(), 6);
    }

    /// Mirrors `testHeartbeatUpdatesSignalTimeButNotRealProgress`.
    #[test]
    fn heartbeat_updates_signal_time_but_not_real_progress() {
        let mut tracker = LifecycleTracker::new();
        let ownership = tracker.begin(attempt(1, 100));
        accepted(tracker.record(
            ownership,
            LivenessSignalKind::ToolActivity,
            LifecycleStage::Running,
            RetryIntent::None,
            200,
        ));
        let snapshot = accepted(tracker.record(
            ownership,
            LivenessSignalKind::Heartbeat,
            LifecycleStage::Running,
            RetryIntent::None,
            300,
        ));
        assert_eq!(snapshot.last_signal_uptime_nanoseconds, 300);
        assert_eq!(snapshot.last_real_progress_uptime_nanoseconds, 200);
        assert_eq!(snapshot.last_heartbeat_uptime_nanoseconds, Some(300));
        assert!(!LivenessSignalKind::Heartbeat.is_real_progress());
    }

    /// Mirrors `testRetryIntentIsCarriedByLiveness`.
    #[test]
    fn retry_intent_is_carried_by_liveness() {
        let mut tracker = LifecycleTracker::new();
        let ownership = tracker.begin(attempt(1, 100));
        let snapshot = accepted(tracker.record(
            ownership,
            LivenessSignalKind::StageTransition,
            LifecycleStage::Retrying,
            RetryIntent::ProviderManaged,
            200,
        ));
        assert_eq!(snapshot.stage, LifecycleStage::Retrying);
        assert_eq!(snapshot.retry_intent, RetryIntent::ProviderManaged);
    }

    /// Mirrors `testEndClearsActiveOwnershipAndRejectsLateSignals`.
    #[test]
    fn end_clears_active_ownership_and_rejects_late_signals() {
        let mut tracker = LifecycleTracker::new();
        let ownership = tracker.begin(attempt(1, 100));
        assert!(!tracker.end(Some(Ownership {
            attempt_id: uuid(99),
            ..ownership
        })));
        assert!(tracker.end(Some(ownership)));
        assert_eq!(tracker.active_ownership(), None);
        assert_eq!(tracker.liveness(), None);
        assert_eq!(
            tracker.record(
                ownership,
                LivenessSignalKind::ProviderEvent,
                LifecycleStage::Running,
                RetryIntent::None,
                200
            ),
            ProgressAcceptance::Rejected(ProgressRejection::NoActiveOwnership)
        );
        assert!(!tracker.end(None));
    }

    /// Mirrors `testTurnEpochParticipatesInOwnershipFence`.
    #[test]
    fn turn_epoch_participates_in_ownership_fence() {
        let mut tracker = LifecycleTracker::new();
        let ownership = tracker.begin(BeginAttempt {
            turn_epoch: Some(epoch(1)),
            ..attempt(1, 100)
        });
        let successor = Ownership {
            turn_epoch: Some(epoch(2)),
            ..ownership
        };
        assert_eq!(
            tracker.record(
                successor,
                LivenessSignalKind::ProviderEvent,
                LifecycleStage::Running,
                RetryIntent::None,
                200
            ),
            ProgressAcceptance::Rejected(ProgressRejection::StaleOwnership)
        );
        accepted(tracker.record(
            ownership,
            LivenessSignalKind::ProviderEvent,
            LifecycleStage::Running,
            RetryIntent::None,
            200,
        ));
    }

    /// Mirrors `testTerminalCommitPhaseIsBoundToActiveOwnership`.
    #[test]
    fn terminal_commit_phase_is_bound_to_active_ownership() {
        let mut tracker = LifecycleTracker::new();
        let first = tracker.begin(attempt(1, 100));
        assert_eq!(
            tracker.begin_terminal_commit(),
            TerminalCommitBeginResult::Acquired
        );
        assert!(tracker.terminal_commit_in_progress());
        assert!(tracker.stage_terminal_commit(uuid(7), first));
        assert!(tracker.has_terminal_commit(first));
        tracker.record_terminal_publication_result(TerminalPublicationResult::Accepted {
            successor_epoch: None,
        });
        assert_eq!(
            tracker.terminal_commit_publication_result(),
            Some(&TerminalPublicationResult::Accepted {
                successor_epoch: None
            })
        );
        tracker.complete_terminal_commit();
        assert!(!tracker.terminal_commit_in_progress());

        // A new attempt resets the phase, so a fresh acquisition succeeds and binds to it.
        let second = tracker.begin(attempt(2, 200));
        assert!(!tracker.has_terminal_commit(first));
        assert_eq!(tracker.terminal_commit_receipt(), None);
        assert_eq!(
            tracker.begin_terminal_commit(),
            TerminalCommitBeginResult::Acquired
        );
        assert!(!tracker.stage_terminal_commit(uuid(8), first));
        assert!(tracker.stage_terminal_commit(uuid(8), second));
        tracker.abort_terminal_commit();
        tracker.invalidate_terminal_commit();
        assert_eq!(tracker.terminal_commit_receipt(), None);
        assert!(!tracker.has_terminal_commit(second));
    }

    /// Mirrors `testProcessIdentityIsResetForNewAttemptButKeepsRunID`.
    #[test]
    fn process_identity_drain_generation_resets_per_attempt_but_keeps_run_id() {
        let mut tracker = LifecycleTracker::new();
        let run_id = uuid(5);
        tracker.begin(attempt(1, 100));
        tracker.install_process_run_id(run_id);
        tracker.bump_terminal_drain_generation();
        tracker.bump_terminal_drain_generation();
        assert_eq!(tracker.terminal_drain_generation(), 2);
        tracker.begin(attempt(2, 200));
        assert_eq!(tracker.process_run_id(), Some(run_id));
        assert_eq!(tracker.terminal_drain_generation(), 0);
        assert!(!tracker.clear_process_run_id_if_current(uuid(6)));
        assert!(tracker.clear_process_run_id_if_current(run_id));
        tracker.install_process_run_id(run_id);
        tracker.force_clear_process_run_id();
        assert_eq!(tracker.process_run_id(), None);
    }

    #[test]
    fn begin_after_end_restarts_sequence_at_one() {
        let mut tracker = LifecycleTracker::new();
        let ownership = tracker.begin(attempt(1, 100));
        accepted(tracker.record(
            ownership,
            LivenessSignalKind::ProviderEvent,
            LifecycleStage::Running,
            RetryIntent::None,
            100,
        ));
        assert!(tracker.end(None));
        assert_eq!(tracker.next_sequence(), 1);
        let ownership = tracker.begin(attempt(2, 100));
        let snapshot = accepted(tracker.record(
            ownership,
            LivenessSignalKind::ProviderEvent,
            LifecycleStage::Running,
            RetryIntent::None,
            100,
        ));
        assert_eq!(snapshot.last_accepted_sequence, 1);
    }
}
