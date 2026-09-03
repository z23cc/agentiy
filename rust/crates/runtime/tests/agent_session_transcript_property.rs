//! ADR-0011 P6-b: property tests for the transcript / snapshot reducer invariants.
//! Swift ⇄ Rust equivalence is proven by the differential harness; these tests pin the laws
//! both implementations must obey.

use proptest::prelude::*;

use agentry_proto::agent_host::v1;
use agentry_runtime::agent_run_lifecycle::CanonicalValue as _;
use agentry_runtime::agent_session_transcript::SessionState;

fn user_message(id: &str, text: &str) -> v1::UserMessage {
    v1::UserMessage {
        message_id: id.to_owned(),
        text: text.to_owned(),
        attachments: Vec::new(),
        created_at: String::new(),
    }
}

fn event(body: v1::agent_session_event::Body) -> v1::AgentSessionEvent {
    v1::AgentSessionEvent {
        recorded_at: "t".to_owned(),
        body: Some(body),
    }
}

#[derive(Clone, Debug)]
enum Action {
    User { id: u8, text: u8 },
    Start { with_message: bool, id: u8 },
    Content { text: u8 },
    OtherStream,
    TurnCompleted,
    Terminate { kind: u8 },
    Stage { stage: i32 },
    Metadata,
    Command { id: u8, settle: bool },
    Interaction { id: u8, settle: bool },
    Imported,
    EmptyBody,
    SmallerCursor,
}

fn action_strategy() -> impl Strategy<Value = Action> {
    prop_oneof![
        (0u8..4, 0u8..6).prop_map(|(id, text)| Action::User { id, text }),
        (any::<bool>(), 0u8..3).prop_map(|(with_message, id)| Action::Start { with_message, id }),
        (0u8..8).prop_map(|text| Action::Content { text }),
        Just(Action::OtherStream),
        Just(Action::TurnCompleted),
        (0u8..4).prop_map(|kind| Action::Terminate { kind }),
        (0i32..7).prop_map(|stage| Action::Stage { stage }),
        Just(Action::Metadata),
        (0u8..4, any::<bool>()).prop_map(|(id, settle)| Action::Command { id, settle }),
        (0u8..3, any::<bool>()).prop_map(|(id, settle)| Action::Interaction { id, settle }),
        Just(Action::Imported),
        Just(Action::EmptyBody),
        Just(Action::SmallerCursor),
    ]
}

fn apply_action(state: &mut SessionState, action: &Action, cursor: u64) {
    match action {
        Action::User { id, text } => {
            state.apply(
                &event(v1::agent_session_event::Body::UserMessage(user_message(
                    &format!("m{id}"),
                    &format!("t{text}"),
                ))),
                cursor,
            );
        }
        Action::Start { with_message, id } => {
            state.apply(
                &event(v1::agent_session_event::Body::RunLifecycle(
                    v1::RunLifecycleEvent {
                        run_id: format!("run-{id}"),
                        epoch: None,
                        kind: Some(v1::run_lifecycle_event::Kind::Started(v1::RunStarted {
                            attempt_id: format!("a{id}"),
                            message: with_message.then(|| user_message(&format!("m{id}"), "start")),
                        })),
                    },
                )),
                cursor,
            );
        }
        Action::Content { text } => {
            state.apply(
                &event(v1::agent_session_event::Body::RuntimeEvent(
                    v1::RuntimeEvent {
                        run_id: "run-1".to_owned(),
                        turn_id: "turn-1".to_owned(),
                        kind: Some(v1::runtime_event::Kind::Stream(v1::StreamResult {
                            item_type: "content".to_owned(),
                            text: Some(format!("c{text}")),
                            ..v1::StreamResult::default()
                        })),
                    },
                )),
                cursor,
            );
        }
        Action::OtherStream => {
            state.apply(
                &event(v1::agent_session_event::Body::RuntimeEvent(
                    v1::RuntimeEvent {
                        run_id: "run-1".to_owned(),
                        turn_id: "turn-1".to_owned(),
                        kind: Some(v1::runtime_event::Kind::Stream(v1::StreamResult {
                            item_type: "reasoning".to_owned(),
                            text: Some("ignored".to_owned()),
                            ..v1::StreamResult::default()
                        })),
                    },
                )),
                cursor,
            );
        }
        Action::TurnCompleted => {
            state.apply(
                &event(v1::agent_session_event::Body::RuntimeEvent(
                    v1::RuntimeEvent {
                        run_id: "run-1".to_owned(),
                        turn_id: "turn-1".to_owned(),
                        kind: Some(v1::runtime_event::Kind::TurnCompleted(v1::TurnCompleted {
                            turn_id: "turn-1".to_owned(),
                            stop_reason: String::new(),
                        })),
                    },
                )),
                cursor,
            );
        }
        Action::Terminate { kind } => {
            let outcome_kind = match kind {
                0 => v1::TerminalOutcomeKind::Completed,
                1 => v1::TerminalOutcomeKind::Cancelled,
                2 => v1::TerminalOutcomeKind::Failed,
                _ => v1::TerminalOutcomeKind::Unspecified,
            };
            state.apply(
                &event(v1::agent_session_event::Body::RunLifecycle(
                    v1::RunLifecycleEvent {
                        run_id: "run-1".to_owned(),
                        epoch: None,
                        kind: Some(v1::run_lifecycle_event::Kind::Terminated(
                            v1::RunTerminated {
                                outcome: Some(v1::TerminalOutcome {
                                    kind: outcome_kind as i32,
                                    assistant_text: None,
                                    failure_reason: v1::FailureReason::Timeout as i32,
                                }),
                                signal: None,
                            },
                        )),
                    },
                )),
                cursor,
            );
        }
        Action::Stage { stage } => {
            state.apply(
                &event(v1::agent_session_event::Body::RunLifecycle(
                    v1::RunLifecycleEvent {
                        run_id: "run-1".to_owned(),
                        epoch: None,
                        kind: Some(v1::run_lifecycle_event::Kind::StageChanged(
                            v1::RunStageChanged {
                                stage: *stage,
                                retry_intent: v1::RetryIntent::None as i32,
                            },
                        )),
                    },
                )),
                cursor,
            );
        }
        Action::Metadata => {
            state.apply(
                &event(v1::agent_session_event::Body::SessionMetadataChanged(
                    v1::SessionMetadataChanged {
                        summary: Some(v1::SessionSummary {
                            session_id: "sess".to_owned(),
                            status: v1::SessionStatus::Running as i32,
                            session_name: "meta".to_owned(),
                            ..v1::SessionSummary::default()
                        }),
                    },
                )),
                cursor,
            );
        }
        Action::Command { id, settle } => {
            let operation_id = format!("op{id}");
            state.apply(
                &event(v1::agent_session_event::Body::CommandAccepted(
                    v1::CommandAccepted {
                        operation_id: operation_id.clone(),
                        argument_fingerprint: format!("f{id}"),
                        command_kind: "steer".to_owned(),
                        accepted_at: format!("t{id}"),
                    },
                )),
                cursor,
            );
            if *settle {
                state.apply(
                    &event(v1::agent_session_event::Body::CommandSettled(
                        v1::CommandSettled {
                            operation_id,
                            settled_at: "ts".to_owned(),
                            settlement: None,
                        },
                    )),
                    cursor,
                );
            }
        }
        Action::Interaction { id, settle } => {
            let interaction_id = format!("q{id}");
            state.apply(
                &event(v1::agent_session_event::Body::Interaction(
                    v1::InteractionEvent {
                        kind: Some(v1::interaction_event::Kind::Requested(
                            v1::InteractionRequested {
                                interaction: Some(v1::PendingInteraction {
                                    interaction_id: interaction_id.clone(),
                                    ..v1::PendingInteraction::default()
                                }),
                            },
                        )),
                    },
                )),
                cursor,
            );
            if *settle {
                state.apply(
                    &event(v1::agent_session_event::Body::Interaction(
                        v1::InteractionEvent {
                            kind: Some(v1::interaction_event::Kind::Settled(
                                v1::InteractionSettled {
                                    interaction_id,
                                    interaction_generation: Vec::new(),
                                    settlement: v1::InteractionSettlement::Answered as i32,
                                    answer: None,
                                    operation_id: String::new(),
                                },
                            )),
                        },
                    )),
                    cursor,
                );
            }
        }
        Action::Imported => {
            state.apply(
                &event(v1::agent_session_event::Body::Imported(v1::Imported {
                    legacy_digest: "00".to_owned(),
                    legacy_format: "json".to_owned(),
                    imported_item_count: 0,
                    imported_at: "t".to_owned(),
                })),
                cursor,
            );
        }
        Action::EmptyBody => {
            state.apply(
                &v1::AgentSessionEvent {
                    recorded_at: "t".to_owned(),
                    body: None,
                },
                cursor,
            );
        }
        Action::SmallerCursor => {
            state.apply(
                &event(v1::agent_session_event::Body::UserMessage(user_message(
                    "late", "x",
                ))),
                cursor.saturating_sub(3),
            );
        }
    }
}

fn assert_invariants(state: &SessionState) {
    assert_eq!(
        state.summary().transcript_item_count,
        u64::try_from(state.transcript().len()).unwrap_or(u64::MAX)
    );
    assert_eq!(state.summary().last_cursor, state.last_cursor());
    if state.summary().interaction.is_some() {
        assert_eq!(
            state
                .summary()
                .interaction
                .as_ref()
                .map(|item| item.interaction_id.as_str()),
            state
                .pending_interactions()
                .first()
                .map(|item| item.interaction_id.as_str())
        );
    }
    let user_ids: Vec<&str> = state
        .transcript()
        .iter()
        .filter(|entry| entry.role == v1::TranscriptRole::User as i32)
        .map(|entry| entry.entry_id.as_str())
        .collect();
    let mut unique = user_ids.clone();
    unique.sort_unstable();
    unique.dedup();
    assert_eq!(
        user_ids.len(),
        unique.len(),
        "user entry ids must be unique"
    );
    for entry in state.transcript() {
        assert!(
            entry.role == v1::TranscriptRole::User as i32
                || entry.role == v1::TranscriptRole::Assistant as i32
        );
        assert!(entry.reasoning.is_empty());
        assert!(entry.tool_name.is_empty());
    }
    let snapshot = state.snapshot(vec![1], "now");
    assert_eq!(snapshot.through_cursor, state.last_cursor());
    assert_eq!(snapshot.transcript.len(), state.transcript().len());
    assert_eq!(
        snapshot.unsettled_operations.len(),
        state.unsettled_operations().len()
    );
    let _ = state.canonical();
}

proptest! {
    #[test]
    fn random_actions_preserve_invariants(actions in prop::collection::vec(action_strategy(), 1..40)) {
        let mut state = SessionState::placeholder("sess");
        let mut cursor = 1_u64;
        for action in &actions {
            apply_action(&mut state, action, cursor);
            cursor += 1;
            assert_invariants(&state);
        }
    }

    #[test]
    fn last_cursor_never_decreases(cursors in prop::collection::vec(0u64..20, 1..20)) {
        let mut state = SessionState::placeholder("sess");
        let mut previous = 0;
        for cursor in cursors {
            state.apply(
                &event(v1::agent_session_event::Body::UserMessage(user_message(
                    &format!("m{cursor}"),
                    "x",
                ))),
                cursor,
            );
            prop_assert!(state.last_cursor() >= previous);
            previous = state.last_cursor();
        }
    }
}
