//! `SessionExecutor` (design §4.2): provider + run ownership.
//!
//! Production default is [`HostedRuntimeExecutor`]. [`StubExecutor`] remains a
//! test hook for `leave-unsettled` / `fail-checkpoint` / `flood:N`.

use agentry_proto::agent_host::v1::{
    self, InteractionResponseDisposition, InterruptOutcome, SessionSpec, SessionStatus, StopReason,
    UserMessage,
};

use crate::hosted::HostedRuntimeExecutor;

/// Commands the router forwards after it has recorded `CommandAccepted`.
pub trait SessionExecutor: Send {
    fn start(&mut self, spec: &SessionSpec, now: &str) -> ExecutorOutcome;
    fn steer(&mut self, message: &UserMessage, now: &str) -> ExecutorOutcome;
    fn interrupt(&mut self, turn_id: &str, now: &str) -> ExecutorOutcome;
    fn respond(
        &mut self,
        interaction_id: &str,
        interaction_generation: &[u8],
        answer: Option<&v1::InteractionAnswer>,
        now: &str,
    ) -> ExecutorOutcome;
    fn stop(&mut self, reason: StopReason, now: &str) -> ExecutorOutcome;
    fn checkpoint_ok(&self) -> bool;
}

#[derive(Clone, Debug)]
pub struct ExecutorOutcome {
    pub events: Vec<v1::AgentSessionEvent>,
    pub interrupt_outcome: InterruptOutcome,
    pub respond_disposition: InteractionResponseDisposition,
    pub interaction_id: String,
}

impl ExecutorOutcome {
    pub(crate) fn events(events: Vec<v1::AgentSessionEvent>) -> Self {
        Self {
            events,
            interrupt_outcome: InterruptOutcome::NoTurnInFlight,
            respond_disposition: InteractionResponseDisposition::UnknownInteraction,
            interaction_id: String::new(),
        }
    }
}

/// Production factory. Test-hook session names keep [`StubExecutor`].
#[must_use]
pub fn make_session_executor(spec: &SessionSpec) -> Box<dyn SessionExecutor> {
    if uses_stub_hook(spec) {
        Box::new(StubExecutor::new(spec))
    } else {
        Box::new(HostedRuntimeExecutor::from_production_spec(spec))
    }
}

#[must_use]
pub(crate) fn uses_stub_hook(spec: &SessionSpec) -> bool {
    spec.session_name == "leave-unsettled"
        || spec.session_name == "block-io"
        || fail_checkpoint(&spec.session_name)
        || flood_count(&spec.session_name).is_some()
}

#[must_use]
pub(crate) fn fail_checkpoint(session_name: &str) -> bool {
    session_name == "fail-checkpoint" || session_name.starts_with("fail-checkpoint")
}

/// Records commands and emits metadata / user-message events. No provider.
pub struct StubExecutor {
    pub session_id: String,
    pub fail_checkpoint: bool,
    pub live: bool,
    block_io: bool,
}

impl StubExecutor {
    #[must_use]
    pub fn new(spec: &SessionSpec) -> Self {
        Self {
            session_id: spec.session_id.clone(),
            fail_checkpoint: fail_checkpoint(&spec.session_name),
            live: spec.initial_message.is_some(),
            block_io: spec.session_name == "block-io",
        }
    }

    fn metadata(
        &self,
        spec: &SessionSpec,
        status: SessionStatus,
        status_text: &str,
        now: &str,
    ) -> v1::AgentSessionEvent {
        v1::AgentSessionEvent {
            recorded_at: now.to_string(),
            body: Some(v1::agent_session_event::Body::SessionMetadataChanged(
                v1::SessionMetadataChanged {
                    summary: Some(v1::SessionSummary {
                        session_id: spec.session_id.clone(),
                        workspace_id: spec.workspace_id.clone(),
                        worktree_id: spec.worktree_id.clone(),
                        session_name: spec.session_name.clone(),
                        provider_id: spec.provider_id.clone(),
                        agent_id: spec.agent_id.clone(),
                        agent_display_name: spec.agent_display_name.clone(),
                        model_id: spec.model_id.clone(),
                        reasoning_effort: spec.reasoning_effort.clone(),
                        status: status as i32,
                        status_text: status_text.to_string(),
                        created_at: now.to_string(),
                        updated_at: now.to_string(),
                        parent_session_id: spec.parent_session_id.clone(),
                        provider_session_id: spec.resume_provider_session_id.clone(),
                        active_run_id: if status == SessionStatus::Running {
                            "stub-run".to_string()
                        } else {
                            String::new()
                        },
                        ..v1::SessionSummary::default()
                    }),
                },
            )),
        }
    }
}

impl SessionExecutor for StubExecutor {
    fn start(&mut self, spec: &SessionSpec, now: &str) -> ExecutorOutcome {
        if self.block_io {
            std::thread::sleep(std::time::Duration::from_millis(250));
        }
        let running = spec.initial_message.is_some();
        self.live = running;
        let status = if running {
            SessionStatus::Running
        } else {
            SessionStatus::WaitingForInput
        };
        let status_text = if running { "running" } else { "ready" };
        let mut events = vec![self.metadata(spec, status, status_text, now)];
        if let Some(message) = spec.initial_message.as_ref() {
            events.push(user_message_event(&message.message_id, &message.text, now));
        }
        if let Some(count) = flood_count(&spec.session_name) {
            events.extend(flood_user_messages("flood", 'x', count, now));
        }
        ExecutorOutcome::events(events)
    }

    fn steer(&mut self, message: &UserMessage, now: &str) -> ExecutorOutcome {
        self.live = true;
        let mut events = vec![user_message_event(&message.message_id, &message.text, now)];
        if let Some(count) = flood_count(&message.text) {
            events.extend(flood_user_messages(
                &format!("{}-flood", message.message_id),
                'y',
                count,
                now,
            ));
        }
        ExecutorOutcome::events(events)
    }

    fn interrupt(&mut self, _turn_id: &str, now: &str) -> ExecutorOutcome {
        if !self.live {
            return ExecutorOutcome {
                events: Vec::new(),
                interrupt_outcome: InterruptOutcome::NoTurnInFlight,
                respond_disposition: InteractionResponseDisposition::UnknownInteraction,
                interaction_id: String::new(),
            };
        }
        self.live = false;
        ExecutorOutcome {
            events: vec![v1::AgentSessionEvent {
                recorded_at: now.to_string(),
                body: Some(v1::agent_session_event::Body::SessionMetadataChanged(
                    v1::SessionMetadataChanged {
                        summary: Some(v1::SessionSummary {
                            session_id: self.session_id.clone(),
                            status: SessionStatus::WaitingForInput as i32,
                            status_text: "interrupted".to_string(),
                            updated_at: now.to_string(),
                            ..v1::SessionSummary::default()
                        }),
                    },
                )),
            }],
            interrupt_outcome: InterruptOutcome::Acknowledged,
            respond_disposition: InteractionResponseDisposition::UnknownInteraction,
            interaction_id: String::new(),
        }
    }

    fn respond(
        &mut self,
        _interaction_id: &str,
        _interaction_generation: &[u8],
        _answer: Option<&v1::InteractionAnswer>,
        _now: &str,
    ) -> ExecutorOutcome {
        ExecutorOutcome {
            events: Vec::new(),
            interrupt_outcome: InterruptOutcome::NoTurnInFlight,
            respond_disposition: InteractionResponseDisposition::UnknownInteraction,
            interaction_id: String::new(),
        }
    }

    fn stop(&mut self, _reason: StopReason, now: &str) -> ExecutorOutcome {
        self.live = false;
        ExecutorOutcome::events(vec![v1::AgentSessionEvent {
            recorded_at: now.to_string(),
            body: Some(v1::agent_session_event::Body::SessionMetadataChanged(
                v1::SessionMetadataChanged {
                    summary: Some(v1::SessionSummary {
                        session_id: self.session_id.clone(),
                        status: SessionStatus::Cancelled as i32,
                        status_text: "stopped".to_string(),
                        updated_at: now.to_string(),
                        ..v1::SessionSummary::default()
                    }),
                },
            )),
        }])
    }

    fn checkpoint_ok(&self) -> bool {
        !self.fail_checkpoint
    }
}

pub(crate) fn flood_count(label: &str) -> Option<usize> {
    label
        .strip_prefix("flood:")
        .and_then(|rest| rest.parse::<usize>().ok())
        .filter(|count| *count > 0 && *count <= 256)
}

pub(crate) fn flood_user_messages(
    prefix: &str,
    fill: char,
    count: usize,
    now: &str,
) -> Vec<v1::AgentSessionEvent> {
    let text = fill.to_string().repeat(if fill == 'x' { 32 } else { 64 });
    (0..count)
        .map(|index| user_message_event(&format!("{prefix}-{index}"), &text, now))
        .collect()
}

pub(crate) fn user_message_event(id: &str, text: &str, now: &str) -> v1::AgentSessionEvent {
    v1::AgentSessionEvent {
        recorded_at: now.to_string(),
        body: Some(v1::agent_session_event::Body::UserMessage(
            v1::UserMessage {
                message_id: id.to_string(),
                text: text.to_string(),
                created_at: now.to_string(),
                ..v1::UserMessage::default()
            },
        )),
    }
}
