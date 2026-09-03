//! ADR-0011 P6-a: property tests for the invariants the P14–P18 specs state about the run-lifecycle
//! reducers (`docs/spec/headless-mcp-domain-runtime-p1{4,5,6,7,8}-agent-run-*.md`), driven against
//! the Rust port in `agentry_runtime::agent_run_lifecycle`. The Swift ⇄ Rust equivalence itself
//! is proven by the differential harness in `Tests/RepoPromptDomainRuntimeTests`; these tests pin
//! the semantic laws both implementations must obey, independent of any concrete scenario.

use proptest::prelude::*;

use agentry_runtime::agent_run_lifecycle::{
    BeginAttempt, BindingIdentity, CanonicalValue as _, EpochTransitionKind, FailureReason,
    LifecycleStage, LifecycleTracker, LivenessSignalKind, MAX_PROVIDER_SUCCESSOR_TOMBSTONES,
    Ownership, ProgressAcceptance, ProgressRejection, ProgressSignal, RetryIntent, RunUuid,
    SemanticAuthority, SemanticResolution, TeardownRegistrationResult, TerminalCommitBeginResult,
    TerminalCommitState, TerminalOutcomeKind, TerminalPublicationResult,
    TerminalSettlementCoordinator, TerminationSignal, TurnEpoch,
};

fn uuid_strategy() -> impl Strategy<Value = RunUuid> {
    any::<[u8; 16]>().prop_map(RunUuid::from_bytes)
}

/// Small identity pool so collisions (same tab, same session, stale attempt) actually happen.
fn pooled_uuid() -> impl Strategy<Value = RunUuid> {
    (0u8..6).prop_map(|byte| RunUuid::from_bytes([byte; 16]))
}

fn stage_strategy() -> impl Strategy<Value = LifecycleStage> {
    proptest::sample::select(LifecycleStage::ALL.to_vec())
}

fn kind_strategy() -> impl Strategy<Value = LivenessSignalKind> {
    proptest::sample::select(LivenessSignalKind::ALL.to_vec())
}

fn retry_strategy() -> impl Strategy<Value = RetryIntent> {
    proptest::sample::select(RetryIntent::ALL.to_vec())
}

fn epoch_strategy() -> impl Strategy<Value = TurnEpoch> {
    (
        pooled_uuid(),
        0u64..3,
        pooled_uuid(),
        pooled_uuid(),
        0u64..3,
        pooled_uuid(),
        0u64..4,
        0u64..3,
        proptest::sample::select(EpochTransitionKind::ALL.to_vec()),
    )
        .prop_map(
            |(
                runtime_id,
                runtime_generation,
                session_id,
                activation_id,
                registration_generation,
                id,
                ordinal,
                continuity_generation,
                transition_kind,
            )| TurnEpoch {
                runtime_id,
                runtime_generation,
                session_id,
                activation_id,
                registration_generation,
                id,
                ordinal,
                continuity_generation,
                transition_kind,
            },
        )
}

fn ownership_strategy() -> impl Strategy<Value = Ownership> {
    (
        pooled_uuid(),
        pooled_uuid(),
        proptest::option::of(pooled_uuid()),
        proptest::option::of(pooled_uuid()),
        0u64..3,
        pooled_uuid(),
        proptest::option::of(epoch_strategy()),
    )
        .prop_map(
            |(
                attempt_id,
                tab_id,
                persistent_session_id,
                persistent_binding_generation,
                binding_transition_generation,
                generation,
                turn_epoch,
            )| Ownership {
                attempt_id,
                binding: BindingIdentity {
                    tab_id,
                    persistent_session_id,
                    persistent_binding_generation,
                    binding_transition_generation,
                    generation,
                },
                turn_epoch,
            },
        )
}

fn begin_strategy() -> impl Strategy<Value = BeginAttempt> {
    (ownership_strategy(), 0u64..1_000).prop_map(|(ownership, timestamp)| BeginAttempt {
        tab_id: ownership.binding.tab_id,
        persistent_session_id: ownership.binding.persistent_session_id,
        persistent_binding_generation: ownership.binding.persistent_binding_generation,
        binding_transition_generation: ownership.binding.binding_transition_generation,
        binding_generation: ownership.binding.generation,
        attempt_id: ownership.attempt_id,
        turn_epoch: ownership.turn_epoch,
        timestamp_uptime_nanoseconds: timestamp,
    })
}

fn signal_strategy() -> impl Strategy<Value = ProgressSignal> {
    (
        ownership_strategy(),
        0u64..8,
        0u64..1_000,
        kind_strategy(),
        stage_strategy(),
        retry_strategy(),
    )
        .prop_map(
            |(ownership, sequence, timestamp, kind, stage, retry_intent)| ProgressSignal {
                ownership,
                sequence,
                timestamp_uptime_nanoseconds: timestamp,
                kind,
                stage,
                retry_intent,
            },
        )
}

fn optional_text() -> impl Strategy<Value = Option<String>> {
    proptest::option::of("[a-z ]{0,12}")
}

fn failure_reason_strategy() -> impl Strategy<Value = FailureReason> {
    proptest::sample::select(FailureReason::ALL.to_vec())
}

fn termination_signal_strategy() -> impl Strategy<Value = TerminationSignal> {
    prop_oneof![
        optional_text().prop_map(|assistant_text| TerminationSignal::Completed { assistant_text }),
        optional_text().prop_map(|assistant_text| TerminationSignal::Cancelled { assistant_text }),
        Just(TerminationSignal::Superseded),
        optional_text()
            .prop_map(|assistant_text| TerminationSignal::StartupFailure { assistant_text }),
        (
            optional_text(),
            proptest::option::of(failure_reason_strategy())
        )
            .prop_map(
                |(assistant_text, reason)| TerminationSignal::ProviderFailure {
                    assistant_text,
                    reason
                }
            ),
        optional_text().prop_map(|assistant_text| TerminationSignal::Timeout { assistant_text }),
        optional_text()
            .prop_map(|assistant_text| TerminationSignal::ProcessExited { assistant_text }),
        optional_text()
            .prop_map(|assistant_text| TerminationSignal::TransportClosed { assistant_text }),
        optional_text()
            .prop_map(|assistant_text| TerminationSignal::UnexpectedEnd { assistant_text }),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    /// P14: accepted sequence and signal time are monotonic; a rejection never mutates liveness;
    /// only the active owner is ever accepted; a heartbeat never advances real progress.
    #[test]
    fn liveness_is_monotonic_and_rejections_are_pure(
        begin in begin_strategy(),
        signals in proptest::collection::vec(signal_strategy(), 0..24),
    ) {
        let mut tracker = LifecycleTracker::new();
        let owner = tracker.begin(begin);
        for signal in signals {
            let before = tracker.liveness().copied().expect("active attempt has liveness");
            let before_canonical = tracker.canonical();
            match tracker.accept(signal) {
                ProgressAcceptance::Accepted(after) => {
                    prop_assert_eq!(signal.ownership, owner);
                    prop_assert!(after.last_accepted_sequence > before.last_accepted_sequence);
                    prop_assert!(
                        after.last_signal_uptime_nanoseconds >= before.last_signal_uptime_nanoseconds
                    );
                    prop_assert!(
                        after.last_real_progress_uptime_nanoseconds
                            >= before.last_real_progress_uptime_nanoseconds
                    );
                    if signal.kind == LivenessSignalKind::Heartbeat {
                        prop_assert_eq!(
                            after.last_real_progress_uptime_nanoseconds,
                            before.last_real_progress_uptime_nanoseconds
                        );
                        prop_assert_eq!(
                            after.last_heartbeat_uptime_nanoseconds,
                            Some(signal.timestamp_uptime_nanoseconds)
                        );
                    } else {
                        prop_assert_eq!(
                            after.last_heartbeat_uptime_nanoseconds,
                            before.last_heartbeat_uptime_nanoseconds
                        );
                    }
                    prop_assert_eq!(tracker.liveness(), Some(&after));
                    prop_assert!(tracker.next_sequence() > signal.sequence);
                }
                ProgressAcceptance::Rejected(rejection) => {
                    prop_assert_eq!(tracker.canonical(), before_canonical, "rejection mutated state");
                    match rejection {
                        ProgressRejection::StaleOwnership => prop_assert_ne!(signal.ownership, owner),
                        ProgressRejection::DuplicateSequence => {
                            prop_assert_eq!(signal.sequence, before.last_accepted_sequence);
                        }
                        ProgressRejection::OutOfOrderSequence => {
                            prop_assert!(signal.sequence < before.last_accepted_sequence);
                        }
                        ProgressRejection::NonMonotonicTimestamp => prop_assert!(
                            signal.timestamp_uptime_nanoseconds
                                < before.last_signal_uptime_nanoseconds
                        ),
                        ProgressRejection::NoActiveOwnership => {
                            prop_assert!(false, "an active attempt cannot report no ownership");
                        }
                    }
                }
            }
        }
    }

    /// P14: `end` is absorbing for the attempt -- every later signal for that owner is rejected
    /// with `noActiveOwnership`, and `end` with a mismatched owner is a no-op.
    #[test]
    fn end_is_absorbing_until_the_next_begin(
        begin in begin_strategy(),
        other in ownership_strategy(),
        signals in proptest::collection::vec(signal_strategy(), 0..8),
    ) {
        let mut tracker = LifecycleTracker::new();
        let owner = tracker.begin(begin);
        let expect_noop = other != owner;
        let before = tracker.canonical();
        let ended = tracker.end(Some(other));
        prop_assert_eq!(ended, !expect_noop);
        if expect_noop {
            prop_assert_eq!(tracker.canonical(), before);
            prop_assert!(tracker.end(None));
        }
        prop_assert!(!tracker.end(None));
        for signal in signals {
            prop_assert_eq!(
                tracker.accept(signal),
                ProgressAcceptance::Rejected(ProgressRejection::NoActiveOwnership)
            );
        }
        prop_assert_eq!(tracker.next_sequence(), 1);
    }

    /// P14/P15/P18: `begin` resets liveness, sequence, the terminal-commit phase, and the drain
    /// generation, but intentionally keeps the installed process identity.
    #[test]
    fn begin_resets_attempt_scoped_state_but_keeps_process_identity(
        first in begin_strategy(),
        second in begin_strategy(),
        run_id in uuid_strategy(),
        bumps in 0u8..4,
        commit_id in uuid_strategy(),
    ) {
        let mut tracker = LifecycleTracker::new();
        let owner = tracker.begin(first);
        tracker.install_process_run_id(run_id);
        for _ in 0..bumps {
            tracker.bump_terminal_drain_generation();
        }
        let _ = tracker.begin_terminal_commit();
        prop_assert!(tracker.stage_terminal_commit(commit_id, owner));
        tracker.record_terminal_publication_result(TerminalPublicationResult::Stale);

        let successor = tracker.begin(second);
        prop_assert_eq!(tracker.active_ownership(), Some(&successor));
        prop_assert_eq!(tracker.liveness().map(|l| l.last_accepted_sequence), Some(0));
        prop_assert_eq!(tracker.liveness().map(|l| l.stage), Some(LifecycleStage::Starting));
        prop_assert_eq!(tracker.next_sequence(), 1);
        prop_assert!(!tracker.terminal_commit_in_progress());
        prop_assert_eq!(tracker.terminal_commit_receipt(), None);
        prop_assert_eq!(tracker.terminal_commit_publication_result(), None);
        prop_assert_eq!(tracker.terminal_drain_generation(), 0);
        prop_assert_eq!(tracker.process_run_id(), Some(run_id));
        prop_assert_eq!(tracker.begin_terminal_commit(), TerminalCommitBeginResult::Acquired);
    }

    /// P15: at most one phase is in progress; once bound, a different owner can neither acquire
    /// nor stage; staging clears any prior result; `matches` is exactly "staged for this owner".
    #[test]
    fn terminal_commit_phase_is_exclusive_and_owner_bound(
        first in ownership_strategy(),
        second in ownership_strategy(),
        commit_id in uuid_strategy(),
        pre_stage in any::<bool>(),
    ) {
        let mut state = TerminalCommitState::new();
        if pre_stage {
            prop_assert!(state.stage(commit_id, first));
            prop_assert_eq!(state.publication_result(), None);
        }
        prop_assert_eq!(state.begin(Some(first)), TerminalCommitBeginResult::Acquired);
        prop_assert_eq!(state.begin(Some(first)), TerminalCommitBeginResult::AlreadyInProgress);
        prop_assert_eq!(state.begin(Some(second)), TerminalCommitBeginResult::AlreadyInProgress);
        prop_assert_eq!(state.begin(None), TerminalCommitBeginResult::AlreadyInProgress);
        state.record(TerminalPublicationResult::Stale);
        state.complete();
        prop_assert!(!state.is_in_progress());
        let same_owner = first == second;
        prop_assert_eq!(state.stage(commit_id, second), same_owner);
        if same_owner {
            prop_assert_eq!(state.publication_result(), None, "stage clears the prior result");
            prop_assert_eq!(state.begin(Some(second)), TerminalCommitBeginResult::Acquired);
        } else {
            prop_assert_eq!(state.begin(Some(second)), TerminalCommitBeginResult::StaleOwnership);
            prop_assert_eq!(state.begin(None), TerminalCommitBeginResult::Acquired);
        }
        prop_assert_eq!(state.matches(first), state.staged_receipt().is_some());
        state.invalidate();
        prop_assert!(!state.matches(first));
        prop_assert_eq!(state.publication_result(), None);
        state.reset();
        prop_assert_eq!(state, TerminalCommitState::new());
    }

    /// P16: successor tombstones are exactly-once, bounded, FIFO-evicted, and never created by a
    /// failed delivery; the set and the order queue stay consistent.
    #[test]
    fn successor_tombstones_are_exactly_once_and_bounded(
        ids in proptest::collection::vec((any::<u16>(), any::<bool>()), 0..1_200),
    ) {
        let mut coordinator = TerminalSettlementCoordinator::new();
        let mut model: Vec<RunUuid> = Vec::new();
        for (raw, delivered) in ids {
            let mut bytes = [0u8; 16];
            bytes[14..].copy_from_slice(&raw.to_be_bytes());
            let id = RunUuid::from_bytes(bytes);
            let already = model.contains(&id);
            let recorded = coordinator.record_provider_successor_consumption(id, delivered);
            prop_assert_eq!(recorded, delivered && !already);
            if recorded {
                model.push(id);
                if model.len() > MAX_PROVIDER_SUCCESSOR_TOMBSTONES {
                    model.remove(0);
                }
            }
            prop_assert!(coordinator.consumed_provider_successor_count() <= MAX_PROVIDER_SUCCESSOR_TOMBSTONES);
        }
        prop_assert_eq!(coordinator.consumed_provider_successor_count(), model.len());
        let ordered: Vec<RunUuid> = coordinator
            .consumed_provider_successor_ids_in_order()
            .copied()
            .collect();
        prop_assert_eq!(&ordered, &model);
        for id in &model {
            prop_assert!(coordinator.has_consumed_provider_successor(*id));
        }
    }

    /// P16: teardown obligations are per-owner and token-bound; a stale token never clears a
    /// replacement; completing removes exactly that owner's obligation.
    #[test]
    fn teardown_tokens_are_owner_scoped_and_exact(
        owners in proptest::collection::vec((ownership_strategy(), uuid_strategy(), uuid_strategy()), 1..12),
    ) {
        let mut coordinator = TerminalSettlementCoordinator::new();
        let mut model: Vec<(Ownership, RunUuid)> = Vec::new();
        for (owner, token, stale) in owners {
            let existing = model.iter().find(|(o, _)| *o == owner).map(|(_, t)| *t);
            let result = coordinator.register_teardown(owner, token);
            match existing {
                Some(current) => {
                    prop_assert_eq!(result, TeardownRegistrationResult::AlreadyRegistered);
                    prop_assert_eq!(coordinator.teardown_token(owner), Some(current));
                }
                None => {
                    prop_assert_eq!(result, TeardownRegistrationResult::Registered);
                    prop_assert_eq!(coordinator.teardown_token(owner), Some(token));
                    model.push((owner, token));
                }
            }
            let current = coordinator.teardown_token(owner).expect("registered");
            if stale != current {
                prop_assert!(!coordinator.complete_teardown(owner, stale));
                prop_assert!(coordinator.has_pending_teardown(owner));
            }
        }
        prop_assert_eq!(coordinator.pending_teardowns().count(), model.len());
        for (owner, token) in model {
            prop_assert!(coordinator.complete_teardown(owner, token));
            prop_assert!(!coordinator.has_pending_teardown(owner));
            prop_assert!(!coordinator.complete_teardown(owner, token));
        }
        prop_assert_eq!(coordinator.pending_teardowns().count(), 0);
    }

    /// P17: the semantic authority is total, structural (never text-derived), and only
    /// `superseded` is non-terminal; every terminal outcome pairs kind/reason like the four
    /// Swift constructors; cancellation always carries the canonical `cancelled` reason.
    #[test]
    fn semantic_resolution_is_structural_and_total(signal in termination_signal_strategy()) {
        let resolution = SemanticAuthority::resolve(&signal);
        prop_assert_eq!(
            SemanticAuthority::is_terminal(&signal),
            !matches!(resolution, SemanticResolution::Superseded)
        );
        prop_assert_eq!(
            SemanticAuthority::outcome(&signal).is_some(),
            SemanticAuthority::is_terminal(&signal)
        );
        if let SemanticResolution::Terminal(outcome) = &resolution {
            match outcome.kind {
                TerminalOutcomeKind::Completed => prop_assert_eq!(outcome.failure_reason, None),
                TerminalOutcomeKind::Cancelled => {
                    prop_assert_eq!(outcome.failure_reason, Some(FailureReason::Cancelled));
                }
                TerminalOutcomeKind::Failed => {
                    // The reason is exactly the structural one the signal carries: an adapter's
                    // explicit `ProviderFailure { reason }` wins verbatim (even `Cancelled`, as in
                    // Swift), transport/EOF/timeout facts have fixed reasons, startup/provider
                    // failures without a typed reason defer classification (`None`).
                    let expected = match &signal {
                        TerminationSignal::ProviderFailure { reason, .. } => *reason,
                        TerminationSignal::Timeout { .. } => Some(FailureReason::Timeout),
                        TerminationSignal::ProcessExited { .. }
                        | TerminationSignal::TransportClosed { .. }
                        | TerminationSignal::UnexpectedEnd { .. } => Some(FailureReason::ProcessCrash),
                        TerminationSignal::StartupFailure { .. } => None,
                        TerminationSignal::Completed { .. }
                        | TerminationSignal::Cancelled { .. }
                        | TerminationSignal::Superseded => {
                            prop_assert!(false, "non-failure signal produced a failed outcome");
                            None
                        }
                    };
                    prop_assert_eq!(outcome.failure_reason, expected);
                }
            }
            // Assistant text passes through unchanged and never influences classification.
            let text = match &signal {
                TerminationSignal::Superseded => None,
                TerminationSignal::Completed { assistant_text }
                | TerminationSignal::Cancelled { assistant_text }
                | TerminationSignal::StartupFailure { assistant_text }
                | TerminationSignal::ProviderFailure { assistant_text, .. }
                | TerminationSignal::Timeout { assistant_text }
                | TerminationSignal::ProcessExited { assistant_text }
                | TerminationSignal::TransportClosed { assistant_text }
                | TerminationSignal::UnexpectedEnd { assistant_text } => assistant_text.clone(),
            };
            prop_assert_eq!(&outcome.assistant_text, &text);
            let mut without_text = signal.clone();
            if let TerminationSignal::Completed { assistant_text }
            | TerminationSignal::Cancelled { assistant_text }
            | TerminationSignal::StartupFailure { assistant_text }
            | TerminationSignal::ProviderFailure { assistant_text, .. }
            | TerminationSignal::Timeout { assistant_text }
            | TerminationSignal::ProcessExited { assistant_text }
            | TerminationSignal::TransportClosed { assistant_text }
            | TerminationSignal::UnexpectedEnd { assistant_text } = &mut without_text
            {
                *assistant_text = None;
            }
            let SemanticResolution::Terminal(stripped) = SemanticAuthority::resolve(&without_text)
            else {
                prop_assert!(false, "terminality changed when text was stripped");
                return Ok(());
            };
            prop_assert_eq!(stripped.kind, outcome.kind);
            prop_assert_eq!(stripped.failure_reason, outcome.failure_reason);
        }
        // Wire round trip is lossless for every producible signal (frozen schema).
        prop_assert_eq!(TerminationSignal::from_proto(&signal.to_proto()), Ok(signal));
    }

    /// P18: `clear_if_current` is an exact fence; `force_clear` ignores it; the drain generation
    /// is never touched by identity changes and only reset by a new attempt.
    #[test]
    fn process_identity_fence_is_exact(
        installs in proptest::collection::vec(pooled_uuid(), 0..8),
        probe in pooled_uuid(),
        bumps in 0u8..5,
    ) {
        let mut tracker = LifecycleTracker::new();
        for _ in 0..bumps {
            tracker.bump_terminal_drain_generation();
        }
        for run_id in &installs {
            tracker.install_process_run_id(*run_id);
            prop_assert_eq!(tracker.process_run_id(), Some(*run_id));
        }
        let current = installs.last().copied();
        let cleared = tracker.clear_process_run_id_if_current(probe);
        prop_assert_eq!(cleared, current == Some(probe));
        prop_assert_eq!(
            tracker.process_run_id(),
            if cleared { None } else { current }
        );
        prop_assert_eq!(tracker.terminal_drain_generation(), u64::from(bumps));
        tracker.force_clear_process_run_id();
        prop_assert_eq!(tracker.process_run_id(), None);
        prop_assert_eq!(tracker.terminal_drain_generation(), u64::from(bumps));
    }

    /// Canonical rendering is injective on the observable state used by the differential harness:
    /// two trackers agree canonically iff their typed observable state agrees.
    #[test]
    fn canonical_state_is_a_faithful_observable_projection(
        a in begin_strategy(),
        b in begin_strategy(),
    ) {
        let mut left = LifecycleTracker::new();
        let mut right = LifecycleTracker::new();
        let left_owner = left.begin(a);
        let right_owner = right.begin(b);
        prop_assert_eq!(left.canonical() == right.canonical(), left_owner == right_owner && a.timestamp_uptime_nanoseconds == b.timestamp_uptime_nanoseconds);
        prop_assert_eq!(left.canonical(), left.clone().canonical());
    }
}
