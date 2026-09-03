//! P7 hosted executor: scripted Codex/ACP turns, permission ask, and stub hooks.

use agentry_mcp::{
    HostedRuntimeExecutor, ProviderInbound, ScriptedTransport, SessionExecutor, StubExecutor,
    make_session_executor,
};
use agentry_proto::agent_host::v1::{
    self, ApprovalDecisionKind, ApprovalPolicy, InteractionResponseDisposition, PermissionPolicy,
    SessionSpec, SessionStatus, StopReason, UserMessage,
};

fn spec(provider: &str, name: &str, message: Option<&str>) -> SessionSpec {
    SessionSpec {
        session_id: "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081".to_string(),
        workspace_id: "ws-1".to_string(),
        session_name: name.to_string(),
        provider_id: provider.to_string(),
        model_id: "test-model".to_string(),
        initial_message: message.map(|text| UserMessage {
            message_id: "msg-1".to_string(),
            text: text.to_string(),
            created_at: "2026-09-03T00:00:00Z".to_string(),
            ..UserMessage::default()
        }),
        ..SessionSpec::default()
    }
}

fn lifecycle_kinds(events: &[v1::AgentSessionEvent]) -> Vec<&'static str> {
    events
        .iter()
        .filter_map(|event| match event.body.as_ref() {
            Some(v1::agent_session_event::Body::RunLifecycle(lifecycle)) => {
                match lifecycle.kind.as_ref() {
                    Some(v1::run_lifecycle_event::Kind::Started(_)) => Some("started"),
                    Some(v1::run_lifecycle_event::Kind::StageChanged(_)) => Some("stage"),
                    Some(v1::run_lifecycle_event::Kind::Terminated(_)) => Some("terminated"),
                    None => None,
                }
            }
            _ => None,
        })
        .collect()
}

fn stream_texts(events: &[v1::AgentSessionEvent]) -> Vec<String> {
    events
        .iter()
        .filter_map(|event| match event.body.as_ref() {
            Some(v1::agent_session_event::Body::RuntimeEvent(runtime)) => {
                match runtime.kind.as_ref() {
                    Some(v1::runtime_event::Kind::Stream(stream)) => stream.text.clone(),
                    _ => None,
                }
            }
            _ => None,
        })
        .collect()
}

fn has_interaction_requested(events: &[v1::AgentSessionEvent]) -> bool {
    events.iter().any(|event| {
        matches!(
            event.body.as_ref(),
            Some(v1::agent_session_event::Body::Interaction(interaction))
                if matches!(
                    interaction.kind.as_ref(),
                    Some(v1::interaction_event::Kind::Requested(_))
                )
        )
    })
}

#[test]
fn factory_keeps_stub_for_test_hooks() {
    for name in ["leave-unsettled", "fail-checkpoint", "flood:3"] {
        let spec = spec("stub", name, None);
        let mut executor = make_session_executor(&spec);
        if name == "fail-checkpoint" {
            assert!(!executor.checkpoint_ok(), "{name} must refuse checkpoint");
        }
        if name.starts_with("flood:") {
            let outcome = executor.start(&spec, "2026-09-03T00:00:00Z");
            let floods = outcome
                .events
                .iter()
                .filter(|event| {
                    matches!(
                        event.body.as_ref(),
                        Some(v1::agent_session_event::Body::UserMessage(message))
                            if message.message_id.starts_with("flood-")
                    )
                })
                .count();
            assert_eq!(floods, 3, "session-name flood hook must stay on the stub");
        }
    }
    let production = spec("stub", "demo", None);
    assert!(make_session_executor(&production).checkpoint_ok());
}

#[test]
fn hosted_claude_echo_applies_lifecycle() {
    let spec = spec("claude", "demo", Some("hello"));
    let mut executor = HostedRuntimeExecutor::from_spec(&spec);
    let outcome = executor.start(&spec, "2026-09-03T00:00:00Z");
    let kinds = lifecycle_kinds(&outcome.events);
    assert!(kinds.contains(&"started"), "{kinds:?}");
    assert!(kinds.contains(&"terminated"), "{kinds:?}");
    assert!(
        stream_texts(&outcome.events)
            .iter()
            .any(|text| text.contains("hosted:hello")),
        "{:?}",
        stream_texts(&outcome.events)
    );
}

#[test]
fn hosted_codex_turn_classifies_stream_and_completes() {
    let mut transport = ScriptedTransport::new();
    transport.set_json("initialize", "{}");
    transport.set_json("thread/start", r#"{"thread":{"id":"thread-1"}}"#);
    transport.set_handler("turn/start", |_| {
        Ok((
            r#"{"turn":{"id":"turn-1"}}"#.to_string(),
            vec![
                ProviderInbound::Notification {
                    method: "item/agentMessage/delta".to_string(),
                    params_json: r#"{"delta":"hello-host"}"#.to_string(),
                },
                ProviderInbound::Notification {
                    method: "turn/completed".to_string(),
                    params_json: r#"{"turn":{"id":"turn-1","status":"completed"}}"#.to_string(),
                },
            ],
        ))
    });
    let spec = spec("codexExec", "demo", Some("hello host"));
    let mut executor = HostedRuntimeExecutor::with_transport(&spec, Box::new(transport));
    let outcome = executor.start(&spec, "2026-09-03T00:00:00Z");
    assert!(
        stream_texts(&outcome.events)
            .iter()
            .any(|text| text == "hello-host"),
        "{:?}",
        stream_texts(&outcome.events)
    );
    assert!(lifecycle_kinds(&outcome.events).contains(&"terminated"));
}

#[test]
fn hosted_acp_turn_normalizes_and_completes() {
    let mut transport = ScriptedTransport::new();
    transport.set_json("initialize", "{}");
    transport.set_json("session/new", r#"{"sessionId":"s-1"}"#);
    transport.set_handler("session/prompt", |_| {
        Ok((
            r#"{"stopReason":"end_turn"}"#.to_string(),
            vec![ProviderInbound::Notification {
                method: "session/update".to_string(),
                params_json: r#"{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"acp-hello"}}}"#.to_string(),
            }],
        ))
    });
    let spec = spec("openCode", "demo", Some("hello acp"));
    let mut executor = HostedRuntimeExecutor::with_transport(&spec, Box::new(transport));
    let outcome = executor.start(&spec, "2026-09-03T00:00:00Z");
    assert!(
        stream_texts(&outcome.events)
            .iter()
            .any(|text| text == "acp-hello"),
        "{:?}",
        stream_texts(&outcome.events)
    );
    assert!(lifecycle_kinds(&outcome.events).contains(&"terminated"));
}

#[test]
fn hosted_decline_unattended_asks_and_waits() {
    let mut transport = ScriptedTransport::new();
    transport.set_json("initialize", "{}");
    transport.set_json("thread/start", r#"{"thread":{"id":"thread-wait"}}"#);
    transport.set_handler("turn/start", |_| {
        Ok((
            r#"{"turn":{"id":"turn-wait"}}"#.to_string(),
            vec![ProviderInbound::ServerRequest {
                id_json: r#""req-1""#.to_string(),
                id_display: "req-1".to_string(),
                method: "item/commandExecution/requestApproval".to_string(),
                params_json: r#"{"threadId":"thread-wait","reason":"run ls","command":"ls"}"#
                    .to_string(),
            }],
        ))
    });
    let mut spec = spec("codexExec", "demo", Some("needs approval"));
    spec.permission_policy = Some(PermissionPolicy {
        approval_policy: ApprovalPolicy::DeclineUnattended as i32,
        ..PermissionPolicy::default()
    });
    let mut executor = HostedRuntimeExecutor::with_transport(&spec, Box::new(transport));
    let started = executor.start(&spec, "2026-09-03T00:00:00Z");
    assert!(has_interaction_requested(&started.events));
    assert!(
        !lifecycle_kinds(&started.events).contains(&"terminated"),
        "DECLINE_UNATTENDED must wait, not deny"
    );

    let interaction_id = started
        .events
        .iter()
        .find_map(|event| match event.body.as_ref() {
            Some(v1::agent_session_event::Body::Interaction(interaction)) => {
                match interaction.kind.as_ref() {
                    Some(v1::interaction_event::Kind::Requested(requested)) => requested
                        .interaction
                        .as_ref()
                        .map(|pending| pending.interaction_id.clone()),
                    _ => None,
                }
            }
            _ => None,
        })
        .expect("interaction id");
    let generation = interaction_id
        .as_bytes()
        .iter()
        .take(8)
        .copied()
        .collect::<Vec<_>>();
    let answered = executor.respond(
        &interaction_id,
        &generation,
        Some(&v1::InteractionAnswer {
            skipped: false,
            answer: Some(v1::interaction_answer::Answer::Approval(
                v1::ApprovalDecision {
                    kind: ApprovalDecisionKind::Accept as i32,
                    execpolicy_amendment_json: String::new(),
                },
            )),
        }),
        "2026-09-03T00:00:01Z",
    );
    assert_eq!(
        answered.respond_disposition,
        InteractionResponseDisposition::Accepted
    );
}

#[test]
fn hosted_claude_permission_ask_waits() {
    let mut transport = ScriptedTransport::new();
    transport.set_handler("user_message", |_| {
        Ok((
            r#"{"text":"waiting"}"#.to_string(),
            vec![ProviderInbound::ServerRequest {
                id_json: r#""perm-1""#.to_string(),
                id_display: "perm-1".to_string(),
                method: "can_use_tool".to_string(),
                params_json: r#"{"kind":"approvalRequest","request_id":"perm-1","tool_name":"Bash","input":{"command":"ls"},"description":"run ls"}"#
                    .to_string(),
            }],
        ))
    });
    let mut spec = spec("claude", "demo", Some("needs approval"));
    spec.permission_policy = Some(PermissionPolicy {
        approval_policy: ApprovalPolicy::DeclineUnattended as i32,
        ..PermissionPolicy::default()
    });
    let mut executor = HostedRuntimeExecutor::with_transport(&spec, Box::new(transport));
    let started = executor.start(&spec, "2026-09-03T00:00:00Z");
    assert!(has_interaction_requested(&started.events));
    assert!(
        !lifecycle_kinds(&started.events).contains(&"terminated"),
        "Claude can_use_tool ask must wait, not finish the turn"
    );

    let interaction_id = started
        .events
        .iter()
        .find_map(|event| match event.body.as_ref() {
            Some(v1::agent_session_event::Body::Interaction(interaction)) => {
                match interaction.kind.as_ref() {
                    Some(v1::interaction_event::Kind::Requested(requested)) => requested
                        .interaction
                        .as_ref()
                        .map(|pending| pending.interaction_id.clone()),
                    _ => None,
                }
            }
            _ => None,
        })
        .expect("interaction id");
    let generation = interaction_id
        .as_bytes()
        .iter()
        .take(8)
        .copied()
        .collect::<Vec<_>>();
    let answered = executor.respond(
        &interaction_id,
        &generation,
        Some(&v1::InteractionAnswer {
            skipped: false,
            answer: Some(v1::interaction_answer::Answer::Approval(
                v1::ApprovalDecision {
                    kind: ApprovalDecisionKind::Accept as i32,
                    execpolicy_amendment_json: String::new(),
                },
            )),
        }),
        "2026-09-03T00:00:01Z",
    );
    assert_eq!(
        answered.respond_disposition,
        InteractionResponseDisposition::Accepted
    );
}

#[test]
fn hosted_steer_honors_flood_hook() {
    let spec = spec("claude", "demo", None);
    let mut executor = HostedRuntimeExecutor::from_spec(&spec);
    executor.start(&spec, "2026-09-03T00:00:00Z");
    let outcome = executor.steer(
        &UserMessage {
            message_id: "op-steer".to_string(),
            text: "flood:4".to_string(),
            created_at: "2026-09-03T00:00:00Z".to_string(),
            ..UserMessage::default()
        },
        "2026-09-03T00:00:00Z",
    );
    let floods = outcome
        .events
        .iter()
        .filter(|event| {
            matches!(
                event.body.as_ref(),
                Some(v1::agent_session_event::Body::UserMessage(message))
                    if message.message_id.contains("flood")
            )
        })
        .count();
    assert!(floods >= 4, "steer flood:N must still expand, got {floods}");
}

#[test]
fn stub_stop_still_cancels() {
    let spec = spec("stub", "fail-checkpoint", None);
    let mut executor = StubExecutor::new(&spec);
    executor.start(&spec, "2026-09-03T00:00:00Z");
    let stopped = executor.stop(StopReason::UserRequested, "2026-09-03T00:00:00Z");
    assert!(stopped.events.iter().any(|event| {
        matches!(
            event.body.as_ref(),
            Some(v1::agent_session_event::Body::SessionMetadataChanged(change))
                if change.summary.as_ref().is_some_and(|summary| {
                    summary.status == SessionStatus::Cancelled as i32
                })
        )
    }));
}
