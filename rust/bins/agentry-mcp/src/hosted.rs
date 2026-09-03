//! Production `SessionExecutor`: lifecycle + provider semantics over a replaceable transport.

use agentry_proto::agent_host::v1::{
    self, ApprovalDecisionKind, ApprovalKind, ApprovalRequest, ApprovalRequestIdSource,
    InteractionResponseDisposition, InteractionSettlement, InterruptOutcome, PermissionPolicy,
    SessionSpec, SessionStatus, StopReason, ToolDisposition, UserMessage,
};
use agentry_runtime::agent_provider_semantics::acp::approval_request_from_permission;
use agentry_runtime::agent_provider_semantics::permission::approval_kind_for_method;
use agentry_runtime::agent_provider_semantics::{
    AcpPermissionOption, AcpProviderId, AcpSemanticState, CodexLifecycleState, CodexSemanticState,
    OpenCodeToolProfile, PermissionEvalRequest, ToolLifecycleEvent, build_approval_result,
    build_permissions_result, classify_server_request, evaluate_permission_policy,
    map_approval_decision, normalize_session_update, parse_approval_request,
    parse_command_execution_running_update, terminal_event,
};
use agentry_runtime::agent_run_lifecycle::{
    BeginAttempt, EpochTransitionKind, FailureReason, LifecycleStage, LifecycleTracker,
    LivenessSignalKind, ProgressAcceptance, RetryIntent, RunUuid, SemanticAuthority,
    SemanticResolution, TerminationSignal, TurnEpoch, terminated_event,
};

use crate::executor::{
    ExecutorOutcome, SessionExecutor, fail_checkpoint, flood_count, flood_user_messages,
    user_message_event,
};
use crate::transport::{ProviderInbound, ProviderTransport, ScriptedTransport};
use crate::util::uuid_v4;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Family {
    Claude,
    Codex,
    Acp,
}

#[derive(Clone, Debug)]
struct LiveTurn {
    run_id: String,
    turn_id: String,
    ownership: agentry_runtime::agent_run_lifecycle::Ownership,
    epoch: TurnEpoch,
}

struct PendingAsk {
    interaction_id: String,
    generation: Vec<u8>,
    id_json: String,
    approval: ApprovalRequest,
    permissions: bool,
    acp_options: Vec<AcpPermissionOption>,
    params_json: String,
}

/// Default production executor. Durable append and transcript fold stay in the router;
/// this type owns run reduction and Codex/ACP/permission semantics.
pub struct HostedRuntimeExecutor {
    spec: SessionSpec,
    family: Family,
    transport: Box<dyn ProviderTransport>,
    tracker: LifecycleTracker,
    live: Option<LiveTurn>,
    pending: Option<PendingAsk>,
    terminated: bool,
    started: bool,
    provider_session_id: String,
    negotiated_model: String,
    negotiated_effort: String,
    runtime_id: RunUuid,
    activation_id: RunUuid,
    session_uuid: RunUuid,
    next_ts: u64,
    epoch_ordinal: u64,
    codex: CodexSemanticState,
    acp: AcpSemanticState,
    codex_lifecycle: CodexLifecycleState,
}

impl HostedRuntimeExecutor {
    #[must_use]
    pub fn from_spec(spec: &SessionSpec) -> Self {
        Self::with_transport(spec, Box::new(ScriptedTransport::echo()))
    }

    /// Production constructor: live I/O when launch spec/env is present.
    #[must_use]
    pub fn from_production_spec(spec: &SessionSpec) -> Self {
        Self::with_transport(spec, crate::transport::make_provider_transport(spec))
    }

    #[must_use]
    pub fn with_transport(spec: &SessionSpec, transport: Box<dyn ProviderTransport>) -> Self {
        let session_uuid = parse_or_mint(&spec.session_id);
        Self {
            spec: spec.clone(),
            family: family_of(&spec.provider_id),
            transport,
            tracker: LifecycleTracker::new(),
            live: None,
            pending: None,
            terminated: false,
            started: false,
            provider_session_id: spec.resume_provider_session_id.clone(),
            negotiated_model: spec.model_id.clone(),
            negotiated_effort: spec.reasoning_effort.clone(),
            runtime_id: mint_uuid(),
            activation_id: mint_uuid(),
            session_uuid,
            next_ts: 1,
            epoch_ordinal: 0,
            codex: CodexSemanticState::new(),
            acp: AcpSemanticState::new(),
            codex_lifecycle: CodexLifecycleState::new(),
        }
    }

    fn tick(&mut self) -> u64 {
        let now = self.next_ts;
        self.next_ts = self.next_ts.saturating_add(1);
        now
    }

    fn metadata(
        &self,
        status: SessionStatus,
        status_text: &str,
        active_run_id: &str,
        now: &str,
    ) -> v1::AgentSessionEvent {
        v1::AgentSessionEvent {
            recorded_at: now.to_string(),
            body: Some(v1::agent_session_event::Body::SessionMetadataChanged(
                v1::SessionMetadataChanged {
                    summary: Some(v1::SessionSummary {
                        session_id: self.spec.session_id.clone(),
                        workspace_id: self.spec.workspace_id.clone(),
                        worktree_id: self.spec.worktree_id.clone(),
                        session_name: self.spec.session_name.clone(),
                        provider_id: self.spec.provider_id.clone(),
                        agent_id: self.spec.agent_id.clone(),
                        agent_display_name: self.spec.agent_display_name.clone(),
                        model_id: self.spec.model_id.clone(),
                        reasoning_effort: self.spec.reasoning_effort.clone(),
                        status: status as i32,
                        status_text: status_text.to_string(),
                        created_at: now.to_string(),
                        updated_at: now.to_string(),
                        parent_session_id: self.spec.parent_session_id.clone(),
                        provider_session_id: self.provider_session_id.clone(),
                        active_run_id: active_run_id.to_string(),
                        ..v1::SessionSummary::default()
                    }),
                },
            )),
        }
    }

    fn runtime_init(&self, now: &str) -> v1::AgentSessionEvent {
        runtime_event(
            now,
            String::new(),
            String::new(),
            v1::runtime_event::Kind::RuntimeInit(v1::RuntimeInitStatus {
                provider_session_id: self.provider_session_id.clone(),
                tools: Vec::new(),
                mcp_server_statuses: Vec::new(),
                initialize_response: None,
            }),
        )
    }

    fn bootstrap(&mut self) -> Result<(), String> {
        self.transport.start()?;
        match self.family {
            Family::Claude => {
                if self.provider_session_id.is_empty() {
                    self.provider_session_id = format!("hosted-{}", self.spec.session_id);
                }
                Ok(())
            }
            Family::Codex => self.bootstrap_codex(),
            Family::Acp => self.bootstrap_acp(),
        }
    }

    fn bootstrap_codex(&mut self) -> Result<(), String> {
        let _ = self.transport.request("initialize", "{}")?;
        if self.provider_session_id.is_empty() {
            let opened = self.transport.request("thread/start", "{}")?;
            self.provider_session_id = json_string_at(&opened, &["thread", "id"])
                .or_else(|| json_string_at(&opened, &["threadId"]))
                .unwrap_or_else(|| "hosted-thread".to_string());
        }
        if !self.spec.model_id.is_empty() {
            let selection = agentry_runtime::agent_provider_semantics::negotiate_selection(
                &self.spec.model_id,
                if self.spec.reasoning_effort.is_empty() {
                    None
                } else {
                    Some(self.spec.reasoning_effort.as_str())
                },
                None,
                &[],
                None,
                true,
            );
            self.negotiated_model = selection.model_raw;
            if let Some(effort) = selection.reasoning_effort {
                self.negotiated_effort = effort.as_str().to_string();
            }
        }
        Ok(())
    }

    fn bootstrap_acp(&mut self) -> Result<(), String> {
        let _ = self.transport.request("initialize", "{}")?;
        if self.provider_session_id.is_empty() {
            let opened = self.transport.request("session/new", "{}")?;
            self.provider_session_id = json_string_at(&opened, &["sessionId"])
                .unwrap_or_else(|| "hosted-session".to_string());
        }
        Ok(())
    }

    fn begin_turn(
        &mut self,
        message: &UserMessage,
        transition: EpochTransitionKind,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        let run_id = uuid_v4();
        let turn_id = uuid_v4();
        let attempt_id = mint_uuid();
        let turn_uuid = parse_or_mint(&turn_id);
        self.epoch_ordinal = self.epoch_ordinal.saturating_add(1);
        let epoch = TurnEpoch {
            runtime_id: self.runtime_id,
            runtime_generation: 1,
            session_id: self.session_uuid,
            activation_id: self.activation_id,
            registration_generation: 1,
            id: turn_uuid,
            ordinal: self.epoch_ordinal,
            continuity_generation: 0,
            transition_kind: transition,
        };
        let started_at = self.tick();
        let ownership = self.tracker.begin(BeginAttempt {
            tab_id: self.session_uuid,
            persistent_session_id: Some(self.session_uuid),
            persistent_binding_generation: None,
            binding_transition_generation: 0,
            binding_generation: mint_uuid(),
            attempt_id,
            turn_epoch: Some(epoch),
            timestamp_uptime_nanoseconds: started_at,
        });
        self.live = Some(LiveTurn {
            run_id: run_id.clone(),
            turn_id: turn_id.clone(),
            ownership,
            epoch,
        });
        let mut events = vec![
            user_message_event(&message.message_id, &message.text, now),
            lifecycle_event(
                now,
                v1::RunLifecycleEvent {
                    run_id: run_id.clone(),
                    epoch: Some(epoch.to_proto()),
                    kind: Some(v1::run_lifecycle_event::Kind::Started(v1::RunStarted {
                        attempt_id: attempt_id.to_string(),
                        message: Some(message.clone()),
                    })),
                },
            ),
        ];
        let running_at = self.tick();
        if let ProgressAcceptance::Accepted(snapshot) = self.tracker.record(
            ownership,
            LivenessSignalKind::StageTransition,
            LifecycleStage::Running,
            RetryIntent::None,
            running_at,
        ) {
            events.push(lifecycle_event(
                now,
                snapshot.to_stage_changed_event(&run_id),
            ));
        }
        events.extend(self.deliver(&message.text, now));
        events
    }

    fn deliver(&mut self, text: &str, now: &str) -> Vec<v1::AgentSessionEvent> {
        match self.family {
            Family::Claude => self.deliver_claude(text, now),
            Family::Codex => self.deliver_codex(text, now),
            Family::Acp => self.deliver_acp(text, now),
        }
    }

    fn deliver_claude(&mut self, text: &str, now: &str) -> Vec<v1::AgentSessionEvent> {
        let params = serde_json::json!({ "text": text }).to_string();
        match self.transport.request("user_message", &params) {
            Ok(body) => {
                let mut events = Vec::new();
                if let Some(live) = self.live.clone() {
                    events.extend(self.drain_inbound(&live, now));
                    if self.pending.is_some() {
                        return events;
                    }
                    let reply = json_string_at(&body, &["text"])
                        .unwrap_or_else(|| format!("hosted:{text}"));
                    let has_stream = events.iter().any(|event| {
                        matches!(
                            event.body.as_ref(),
                            Some(v1::agent_session_event::Body::RuntimeEvent(runtime))
                                if matches!(
                                    runtime.kind,
                                    Some(v1::runtime_event::Kind::Stream(_))
                                )
                        )
                    });
                    if !has_stream {
                        events.push(stream_event(
                            now,
                            &live.run_id,
                            &live.turn_id,
                            "content",
                            &reply,
                        ));
                    }
                    if self.live.is_some() {
                        events.extend(self.finish_turn(
                            TerminationSignal::Completed {
                                assistant_text: Some(reply),
                            },
                            now,
                        ));
                    }
                }
                events
            }
            Err(error) => self.fail_turn(&error, now),
        }
    }

    fn deliver_codex(&mut self, text: &str, now: &str) -> Vec<v1::AgentSessionEvent> {
        if self.codex.is_terminal() {
            self.codex.reset();
            self.codex_lifecycle.reset();
        }
        let thread_id = self.provider_session_id.clone();
        if thread_id.is_empty() {
            return self.fail_turn("codex thread is not open", now);
        }
        let mut params = serde_json::json!({
            "threadId": thread_id,
            "input": [{"type": "text", "text": text, "text_elements": []}]
        });
        if !self.spec.worktree_id.is_empty() {
            params["cwd"] = serde_json::Value::String(self.spec.worktree_id.clone());
        }
        if !self.negotiated_model.is_empty() {
            params["model"] = serde_json::Value::String(self.negotiated_model.clone());
        }
        if !self.negotiated_effort.is_empty() {
            params["effort"] = serde_json::Value::String(self.negotiated_effort.clone());
        }
        match self.transport.request("turn/start", &params.to_string()) {
            Ok(body) => {
                let mut events = Vec::new();
                if let Some(live) = self.live.clone() {
                    let params_json = wrap_turn_params(&body);
                    events.extend(self.emit_codex("turn/started", &params_json, None, now));
                    if turn_status_is_terminal(&body) {
                        events.extend(self.emit_codex("turn/completed", &params_json, None, now));
                    }
                    events.extend(self.drain_inbound(&live, now));
                }
                events
            }
            Err(error) => self.fail_turn(&error, now),
        }
    }

    fn deliver_acp(&mut self, text: &str, now: &str) -> Vec<v1::AgentSessionEvent> {
        if self.acp.is_terminal() {
            self.acp.reset();
        }
        let session_id = self.provider_session_id.clone();
        if session_id.is_empty() {
            return self.fail_turn("acp session is not open", now);
        }
        let params = serde_json::json!({
            "sessionId": session_id,
            "prompt": [{"type": "text", "text": text}]
        });
        match self
            .transport
            .request("session/prompt", &params.to_string())
        {
            Ok(body) => {
                let mut events = Vec::new();
                if let Some(live) = self.live.clone() {
                    events.extend(self.drain_inbound(&live, now));
                    let stop = json_string_at(&body, &["stopReason"]);
                    let event = terminal_event(stop.as_deref(), &live.run_id, &live.turn_id);
                    events.extend(self.emit_runtime_events(vec![event], now));
                }
                events
            }
            Err(error) => self.fail_turn(&error, now),
        }
    }

    fn drain_inbound(&mut self, live: &LiveTurn, now: &str) -> Vec<v1::AgentSessionEvent> {
        let inbound = self.transport.take_inbound();
        let mut events = Vec::new();
        for item in inbound {
            events.extend(self.handle_inbound(item, live, now));
        }
        events
    }

    fn handle_inbound(
        &mut self,
        inbound: ProviderInbound,
        live: &LiveTurn,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        match inbound {
            ProviderInbound::Notification {
                method,
                params_json,
            } => self.handle_notification(&method, &params_json, live, now),
            ProviderInbound::ServerRequest {
                id_json,
                id_display,
                method,
                params_json,
            } => {
                self.handle_server_request(&id_json, &id_display, &method, &params_json, live, now)
            }
            ProviderInbound::ProcessExited => self.fail_turn("provider process exited", now),
            ProviderInbound::ProtocolError(message) => {
                vec![stream_event(
                    now,
                    &live.run_id,
                    &live.turn_id,
                    "error",
                    &message,
                )]
            }
        }
    }

    fn handle_notification(
        &mut self,
        method: &str,
        params_json: &str,
        live: &LiveTurn,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        match self.family {
            Family::Codex => {
                let payload = unwrap_update(params_json);
                let mut events = self.emit_codex(method, &payload, None, now);
                if let Some(lifecycle) = self.codex_lifecycle.apply_file_change(method, &payload) {
                    events.push(lifecycle_stream(now, live, &lifecycle));
                }
                if let Some(update) = parse_command_execution_running_update(method, &payload) {
                    if let Some(output) = update.appended_output.as_deref() {
                        events.push(stream_event(
                            now,
                            &live.run_id,
                            &live.turn_id,
                            "tool_result",
                            output,
                        ));
                    }
                }
                events
            }
            Family::Claude if method == "assistantDelta" || method == "content" => {
                let text = json_string_at(params_json, &["text"]).unwrap_or_default();
                if text.is_empty() {
                    Vec::new()
                } else {
                    vec![stream_event(
                        now,
                        &live.run_id,
                        &live.turn_id,
                        "content",
                        &text,
                    )]
                }
            }
            Family::Acp if method == "session/update" => {
                let payload = unwrap_update(params_json);
                let normalized = normalize_session_update(
                    &payload,
                    acp_kind_of(&self.spec.provider_id),
                    &uuid_v4(),
                    &live.run_id,
                    &live.turn_id,
                    OpenCodeToolProfile::AgentMode,
                );
                self.acp.apply_events(&normalized);
                self.emit_runtime_events(normalized, now)
            }
            _ => Vec::new(),
        }
    }

    fn handle_server_request(
        &mut self,
        id_json: &str,
        id_display: &str,
        method: &str,
        params_json: &str,
        live: &LiveTurn,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        match self.family {
            Family::Codex => self.handle_codex_server_request(
                id_json,
                id_display,
                method,
                params_json,
                live,
                now,
            ),
            Family::Acp => {
                self.handle_acp_permission(id_json, id_display, method, params_json, live, now)
            }
            Family::Claude => {
                self.handle_claude_permission(id_json, id_display, method, params_json, live, now)
            }
        }
    }

    fn handle_codex_server_request(
        &mut self,
        id_json: &str,
        id_display: &str,
        method: &str,
        params_json: &str,
        live: &LiveTurn,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        let kind = classify_server_request(method);
        let mut events = self.emit_codex(method, params_json, Some(id_display), now);
        events.retain(|event| {
            !matches!(
                event.body.as_ref(),
                Some(v1::agent_session_event::Body::RuntimeEvent(runtime))
                    if matches!(runtime.kind, Some(v1::runtime_event::Kind::ApprovalRequest(_)))
            )
        });
        let params = serde_json::from_str(params_json).unwrap_or_else(|_| serde_json::json!({}));
        let params_map = params.as_object().cloned().unwrap_or_default();
        match kind {
            Some(
                agentry_runtime::agent_provider_semantics::CodexServerRequestKind::Approval
                | agentry_runtime::agent_provider_semantics::CodexServerRequestKind::Permissions,
            ) => {
                let Some(approval) = parse_approval_request(
                    id_display,
                    method,
                    &params_map,
                    (!self.provider_session_id.is_empty())
                        .then_some(self.provider_session_id.as_str()),
                    Some(live.turn_id.as_str()),
                ) else {
                    let _ = self.transport.respond(id_json, r#"{"decision":"decline"}"#);
                    return events;
                };
                events.extend(self.settle_permission(
                    id_json,
                    approval,
                    params_json,
                    matches!(
                        kind,
                        Some(agentry_runtime::agent_provider_semantics::CodexServerRequestKind::Permissions)
                    ),
                    Vec::new(),
                    live,
                    now,
                ));
                events
            }
            _ => {
                let _ = self.transport.respond_error(
                    id_json,
                    -32601,
                    &format!("Unsupported Codex client method: {method}"),
                );
                events
            }
        }
    }

    fn handle_claude_permission(
        &mut self,
        id_json: &str,
        id_display: &str,
        method: &str,
        params_json: &str,
        live: &LiveTurn,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        if method != "can_use_tool" {
            let _ = self.transport.respond(id_json, r#"{"decision":"decline"}"#);
            return Vec::new();
        }
        let params = serde_json::from_str::<serde_json::Value>(params_json)
            .unwrap_or_else(|_| serde_json::json!({}));
        let tool_name = params
            .get("tool_name")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let tool_use_id = params
            .get("tool_use_id")
            .and_then(serde_json::Value::as_str)
            .unwrap_or(id_display);
        let description = params
            .get("description")
            .or_else(|| params.get("decision_reason"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or(tool_name);
        let input = params
            .get("input")
            .cloned()
            .unwrap_or_else(|| serde_json::json!({}));
        let command = input
            .get("command")
            .and_then(serde_json::Value::as_str)
            .map(|value| vec![value.to_string()])
            .unwrap_or_default();
        let kind = approval_kind_for_claude(tool_name, !command.is_empty());
        let approval = ApprovalRequest {
            approval_id: if tool_use_id.is_empty() {
                id_display.to_string()
            } else {
                tool_use_id.to_string()
            },
            request_id: id_display.to_string(),
            request_id_source: ApprovalRequestIdSource::ClaudeControl as i32,
            method: "can_use_tool".to_string(),
            kind: kind as i32,
            thread_id: self.provider_session_id.clone(),
            turn_id: live.turn_id.clone(),
            item_id: tool_use_id.to_string(),
            reason: description.to_string(),
            command,
            cwd: self.spec.worktree_id.clone(),
            grant_root: String::new(),
            proposed_execpolicy_amendment_json: String::new(),
            details: Vec::new(),
        };
        self.settle_permission(id_json, approval, params_json, false, Vec::new(), live, now)
    }

    fn handle_acp_permission(
        &mut self,
        id_json: &str,
        id_display: &str,
        method: &str,
        params_json: &str,
        live: &LiveTurn,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        if method != "session/request_permission" {
            let _ = self.transport.respond_error(
                id_json,
                -32601,
                &format!("Unsupported ACP client method: {method}"),
            );
            return Vec::new();
        }
        let params = serde_json::from_str::<serde_json::Value>(params_json)
            .unwrap_or_else(|_| serde_json::json!({}));
        let tool_call = params
            .get("toolCall")
            .cloned()
            .unwrap_or(serde_json::json!({}));
        let tool_call_id = tool_call
            .get("toolCallId")
            .and_then(serde_json::Value::as_str)
            .unwrap_or(id_display);
        let tool_title = tool_call.get("title").and_then(serde_json::Value::as_str);
        let tool_kind = tool_call.get("kind").and_then(serde_json::Value::as_str);
        let options = params
            .get("options")
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|option| {
                Some(AcpPermissionOption {
                    option_id: option.get("optionId")?.as_str()?.to_string(),
                    kind: option.get("kind")?.as_str()?.to_string(),
                })
            })
            .collect();
        let approval = approval_request_from_permission(
            id_display,
            tool_call_id,
            tool_title,
            tool_kind,
            None,
            &self.spec.worktree_id,
            &self.provider_session_id,
        );
        self.settle_permission(id_json, approval, params_json, false, options, live, now)
    }

    #[allow(clippy::too_many_arguments)]
    fn settle_permission(
        &mut self,
        id_json: &str,
        approval: ApprovalRequest,
        params_json: &str,
        permissions: bool,
        acp_options: Vec<AcpPermissionOption>,
        live: &LiveTurn,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        let policy = self
            .spec
            .permission_policy
            .clone()
            .unwrap_or(PermissionPolicy {
                approval_policy: v1::ApprovalPolicy::DeclineUnattended as i32,
                ..PermissionPolicy::default()
            });
        let request = PermissionEvalRequest {
            tool_id: if approval.item_id.is_empty() {
                approval.approval_id.clone()
            } else {
                approval.item_id.clone()
            },
            request_tool_name: Some(if approval.reason.is_empty() {
                approval.method.clone()
            } else {
                approval.reason.clone()
            })
            .filter(|value| !value.is_empty()),
            request_payload_json: params_json.to_string(),
            provider_trusted: false,
            kind: ApprovalKind::try_from(approval.kind).unwrap_or(ApprovalKind::Unspecified),
        };
        let evaluated = evaluate_permission_policy(&policy, &request);
        match evaluated.disposition {
            ToolDisposition::Allow => {
                self.respond_permission(
                    id_json,
                    ApprovalDecisionKind::Accept,
                    &approval,
                    permissions,
                    &acp_options,
                    params_json,
                );
                Vec::new()
            }
            ToolDisposition::Deny => {
                self.respond_permission(
                    id_json,
                    ApprovalDecisionKind::Decline,
                    &approval,
                    permissions,
                    &acp_options,
                    params_json,
                );
                Vec::new()
            }
            ToolDisposition::Ask | ToolDisposition::Unspecified => self.request_ask(
                id_json,
                approval,
                permissions,
                acp_options,
                params_json,
                live,
                now,
            ),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn request_ask(
        &mut self,
        id_json: &str,
        approval: ApprovalRequest,
        permissions: bool,
        acp_options: Vec<AcpPermissionOption>,
        params_json: &str,
        live: &LiveTurn,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        let interaction_id = if approval.approval_id.is_empty() {
            uuid_v4()
        } else {
            approval.approval_id.clone()
        };
        let generation: Vec<u8> = interaction_id.as_bytes().iter().take(8).copied().collect();
        self.pending = Some(PendingAsk {
            interaction_id: interaction_id.clone(),
            generation: generation.clone(),
            id_json: id_json.to_string(),
            approval: approval.clone(),
            permissions,
            acp_options,
            params_json: params_json.to_string(),
        });
        let mut events = vec![v1::AgentSessionEvent {
            recorded_at: now.to_string(),
            body: Some(v1::agent_session_event::Body::Interaction(
                v1::InteractionEvent {
                    kind: Some(v1::interaction_event::Kind::Requested(
                        v1::InteractionRequested {
                            interaction: Some(v1::PendingInteraction {
                                interaction_id,
                                interaction_generation: generation,
                                kind: v1::InteractionKind::Approval as i32,
                                response_type: v1::InteractionResponseType::Decision as i32,
                                title: if approval.reason.is_empty() {
                                    approval.method.clone()
                                } else {
                                    approval.reason.clone()
                                },
                                prompt: if approval.reason.is_empty() {
                                    "Approve this tool call?".to_string()
                                } else {
                                    approval.reason.clone()
                                },
                                context: approval.command.join(" "),
                                approval: Some(approval),
                                requested_at: now.to_string(),
                                timeout_seconds: self
                                    .spec
                                    .permission_policy
                                    .as_ref()
                                    .map_or(0, |policy| policy.interaction_timeout_seconds),
                                run_id: live.run_id.clone(),
                                turn_id: live.turn_id.clone(),
                                ..v1::PendingInteraction::default()
                            }),
                        },
                    )),
                },
            )),
        }];
        if let Some(live) = self.live.clone() {
            let waiting_at = self.tick();
            if let ProgressAcceptance::Accepted(snapshot) = self.tracker.record(
                live.ownership,
                LivenessSignalKind::Interaction,
                LifecycleStage::WaitingForInteraction,
                RetryIntent::None,
                waiting_at,
            ) {
                events.push(lifecycle_event(
                    now,
                    snapshot.to_stage_changed_event(&live.run_id),
                ));
            }
        }
        events
    }

    fn respond_permission(
        &mut self,
        id_json: &str,
        decision: ApprovalDecisionKind,
        approval: &ApprovalRequest,
        permissions: bool,
        acp_options: &[AcpPermissionOption],
        params_json: &str,
    ) {
        self.codex.settle_approval(&approval.approval_id);
        self.acp.settle_approval(&approval.approval_id);
        if self.family == Family::Claude {
            let decision_name = match decision {
                ApprovalDecisionKind::Accept
                | ApprovalDecisionKind::AcceptForSession
                | ApprovalDecisionKind::AcceptWithExecpolicyAmendment => "accept",
                ApprovalDecisionKind::Cancel => "cancel",
                _ => "decline",
            };
            let _ = self.transport.respond(
                id_json,
                &serde_json::json!({"decision": decision_name}).to_string(),
            );
            return;
        }
        if self.family == Family::Acp {
            let mapping =
                map_approval_decision(decision, acp_options, acp_kind_of(&self.spec.provider_id));
            let mut result = serde_json::json!({"outcome": mapping.outcome});
            if let Some(option_id) = mapping.option_id {
                result["optionId"] = serde_json::Value::String(option_id);
            }
            let _ = self.transport.respond(id_json, &result.to_string());
            return;
        }
        if permissions {
            let payload = serde_json::from_str::<serde_json::Value>(params_json)
                .unwrap_or_else(|_| serde_json::json!({}));
            let permissions_json = payload
                .get("permissions")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}))
                .to_string();
            let result = build_permissions_result(decision, &permissions_json);
            let _ = self.transport.respond(id_json, &result);
            return;
        }
        let amendment = if approval.proposed_execpolicy_amendment_json.is_empty() {
            None
        } else {
            Some(approval.proposed_execpolicy_amendment_json.as_str())
        };
        let kind = ApprovalKind::try_from(approval.kind).unwrap_or(ApprovalKind::Unspecified);
        let result = build_approval_result(decision, kind, amendment);
        let _ = self.transport.respond(id_json, &result);
    }

    fn emit_codex(
        &mut self,
        method: &str,
        params_json: &str,
        request_id: Option<&str>,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        let Some(live) = self.live.clone() else {
            return Vec::new();
        };
        let events = self
            .codex
            .apply(method, params_json, &live.run_id, request_id);
        self.emit_runtime_events(events, now)
    }

    fn emit_runtime_events(
        &mut self,
        events: Vec<v1::RuntimeEvent>,
        now: &str,
    ) -> Vec<v1::AgentSessionEvent> {
        let Some(live) = self.live.clone() else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for mut event in events {
            if event.run_id.is_empty() {
                event.run_id.clone_from(&live.run_id);
            }
            if event.turn_id.is_empty() {
                event.turn_id.clone_from(&live.turn_id);
            }
            let kind = event.kind.clone();
            out.push(v1::AgentSessionEvent {
                recorded_at: now.to_string(),
                body: Some(v1::agent_session_event::Body::RuntimeEvent(event)),
            });
            match kind {
                Some(v1::runtime_event::Kind::TurnCompleted(completed)) => {
                    out.extend(self.finish_from_stop(&completed.stop_reason, now));
                }
                Some(v1::runtime_event::Kind::Error(error)) => {
                    out.extend(self.finish_turn(
                        TerminationSignal::ProviderFailure {
                            assistant_text: Some(error.message),
                            reason: Some(FailureReason::AgentError),
                        },
                        now,
                    ));
                }
                _ => {}
            }
        }
        out
    }

    fn finish_from_stop(&mut self, stop_reason: &str, now: &str) -> Vec<v1::AgentSessionEvent> {
        let signal = match stop_reason.to_ascii_lowercase().as_str() {
            "cancelled" | "interrupted" => TerminationSignal::Cancelled {
                assistant_text: None,
            },
            "failed" => TerminationSignal::ProviderFailure {
                assistant_text: None,
                reason: Some(FailureReason::AgentError),
            },
            _ => TerminationSignal::Completed {
                assistant_text: None,
            },
        };
        self.finish_turn(signal, now)
    }

    fn fail_turn(&mut self, message: &str, now: &str) -> Vec<v1::AgentSessionEvent> {
        let mut events = Vec::new();
        if let Some(live) = self.live.clone() {
            events.push(stream_event(
                now,
                &live.run_id,
                &live.turn_id,
                "error",
                message,
            ));
        }
        events.extend(self.finish_turn(
            TerminationSignal::ProviderFailure {
                assistant_text: Some(message.to_string()),
                reason: Some(FailureReason::AgentError),
            },
            now,
        ));
        events
    }

    fn finish_turn(&mut self, signal: TerminationSignal, now: &str) -> Vec<v1::AgentSessionEvent> {
        let Some(live) = self.live.take() else {
            return Vec::new();
        };
        self.pending = None;
        let mut events = Vec::new();
        match SemanticAuthority::resolve(&signal) {
            SemanticResolution::Terminal(outcome) => {
                events.push(lifecycle_event(
                    now,
                    terminated_event(&live.run_id, Some(&live.epoch), &outcome, Some(&signal)),
                ));
                let status = match outcome.kind {
                    agentry_runtime::agent_run_lifecycle::TerminalOutcomeKind::Failed => {
                        SessionStatus::Failed
                    }
                    _ => SessionStatus::WaitingForInput,
                };
                let status_text = match outcome.kind {
                    agentry_runtime::agent_run_lifecycle::TerminalOutcomeKind::Cancelled => {
                        "interrupted"
                    }
                    agentry_runtime::agent_run_lifecycle::TerminalOutcomeKind::Failed => "failed",
                    agentry_runtime::agent_run_lifecycle::TerminalOutcomeKind::Completed => {
                        "turn completed"
                    }
                };
                events.push(self.metadata(status, status_text, "", now));
            }
            SemanticResolution::Superseded => {}
        }
        let _ = self.tracker.end(Some(live.ownership));
        events
    }
}

impl SessionExecutor for HostedRuntimeExecutor {
    fn start(&mut self, spec: &SessionSpec, now: &str) -> ExecutorOutcome {
        if self.terminated {
            return ExecutorOutcome::events(Vec::new());
        }
        self.started = true;
        if let Some(count) = flood_count(&spec.session_name) {
            return ExecutorOutcome::events(flood_user_messages("flood", 'x', count, now));
        }
        let bootstrap = self.bootstrap();
        let mut events = vec![self.runtime_init(now)];
        if let Err(error) = bootstrap {
            events.push(self.metadata(SessionStatus::Failed, &error, "", now));
            return ExecutorOutcome::events(events);
        }
        if let Some(message) = spec.initial_message.as_ref() {
            events.push(self.metadata(SessionStatus::Running, "running", "pending", now));
            events.extend(self.begin_turn(message, EpochTransitionKind::Initial, now));
        } else {
            events.push(self.metadata(SessionStatus::WaitingForInput, "ready", "", now));
        }
        ExecutorOutcome::events(events)
    }

    fn steer(&mut self, message: &UserMessage, now: &str) -> ExecutorOutcome {
        if let Some(count) = flood_count(&message.text) {
            let mut events = vec![user_message_event(&message.message_id, &message.text, now)];
            events.extend(flood_user_messages(
                &format!("{}-flood", message.message_id),
                'y',
                count,
                now,
            ));
            return ExecutorOutcome::events(events);
        }
        if self.terminated || !self.started {
            return ExecutorOutcome::events(Vec::new());
        }
        ExecutorOutcome::events(self.begin_turn(message, EpochTransitionKind::RelatedFollowUp, now))
    }

    fn interrupt(&mut self, turn_id: &str, now: &str) -> ExecutorOutcome {
        let Some(live) = self.live.as_ref() else {
            return ExecutorOutcome {
                events: Vec::new(),
                interrupt_outcome: InterruptOutcome::NoTurnInFlight,
                respond_disposition: InteractionResponseDisposition::UnknownInteraction,
                interaction_id: String::new(),
            };
        };
        if !turn_id.is_empty() && turn_id != live.turn_id {
            return ExecutorOutcome {
                events: Vec::new(),
                interrupt_outcome: InterruptOutcome::NoTurnInFlight,
                respond_disposition: InteractionResponseDisposition::UnknownInteraction,
                interaction_id: String::new(),
            };
        }
        self.transport.cancel_in_flight();
        let events = self.finish_turn(
            TerminationSignal::Cancelled {
                assistant_text: None,
            },
            now,
        );
        ExecutorOutcome {
            events,
            interrupt_outcome: InterruptOutcome::Acknowledged,
            respond_disposition: InteractionResponseDisposition::UnknownInteraction,
            interaction_id: String::new(),
        }
    }

    fn respond(
        &mut self,
        interaction_id: &str,
        interaction_generation: &[u8],
        answer: Option<&v1::InteractionAnswer>,
        now: &str,
    ) -> ExecutorOutcome {
        let Some(pending) = self.pending.as_ref() else {
            return ExecutorOutcome {
                events: Vec::new(),
                interrupt_outcome: InterruptOutcome::NoTurnInFlight,
                respond_disposition: InteractionResponseDisposition::UnknownInteraction,
                interaction_id: interaction_id.to_string(),
            };
        };
        if pending.interaction_id != interaction_id {
            return ExecutorOutcome {
                events: Vec::new(),
                interrupt_outcome: InterruptOutcome::NoTurnInFlight,
                respond_disposition: InteractionResponseDisposition::UnknownInteraction,
                interaction_id: interaction_id.to_string(),
            };
        }
        if pending.generation != interaction_generation {
            return ExecutorOutcome {
                events: Vec::new(),
                interrupt_outcome: InterruptOutcome::NoTurnInFlight,
                respond_disposition: InteractionResponseDisposition::StaleGeneration,
                interaction_id: interaction_id.to_string(),
            };
        }
        let pending = self.pending.take().expect("pending just matched");
        let decision = decision_from_answer(answer);
        self.respond_permission(
            &pending.id_json,
            decision,
            &pending.approval,
            pending.permissions,
            &pending.acp_options,
            &pending.params_json,
        );
        let mut events = vec![v1::AgentSessionEvent {
            recorded_at: now.to_string(),
            body: Some(v1::agent_session_event::Body::Interaction(
                v1::InteractionEvent {
                    kind: Some(v1::interaction_event::Kind::Settled(
                        v1::InteractionSettled {
                            interaction_id: pending.interaction_id.clone(),
                            interaction_generation: pending.generation,
                            settlement: InteractionSettlement::Answered as i32,
                            answer: answer.cloned(),
                            operation_id: String::new(),
                        },
                    )),
                },
            )),
        }];
        if let Some(live) = self.live.clone() {
            let running_at = self.tick();
            if let ProgressAcceptance::Accepted(snapshot) = self.tracker.record(
                live.ownership,
                LivenessSignalKind::StageTransition,
                LifecycleStage::Running,
                RetryIntent::None,
                running_at,
            ) {
                events.push(lifecycle_event(
                    now,
                    snapshot.to_stage_changed_event(&live.run_id),
                ));
            }
        }
        ExecutorOutcome {
            events,
            interrupt_outcome: InterruptOutcome::NoTurnInFlight,
            respond_disposition: InteractionResponseDisposition::Accepted,
            interaction_id: pending.interaction_id,
        }
    }

    fn stop(&mut self, _reason: StopReason, now: &str) -> ExecutorOutcome {
        self.terminated = true;
        self.transport.cancel_in_flight();
        self.transport.shutdown();
        let mut events = if self.live.is_some() {
            self.finish_turn(
                TerminationSignal::Cancelled {
                    assistant_text: None,
                },
                now,
            )
        } else {
            Vec::new()
        };
        events.push(self.metadata(SessionStatus::Cancelled, "stopped", "", now));
        ExecutorOutcome::events(events)
    }

    fn checkpoint_ok(&self) -> bool {
        !fail_checkpoint(&self.spec.session_name)
    }
}

fn approval_kind_for_claude(tool_name: &str, command_present: bool) -> ApprovalKind {
    let normalized = tool_name.to_ascii_lowercase();
    if normalized.contains("edit")
        || normalized.contains("write")
        || normalized.contains("read")
        || normalized.contains("file")
    {
        ApprovalKind::FileChange
    } else {
        approval_kind_for_method(tool_name, command_present)
    }
}

fn family_of(provider_id: &str) -> Family {
    let id = provider_id.to_ascii_lowercase();
    if id.contains("acp") || id.contains("opencode") || id.contains("cursor") || id.contains("grok")
    {
        Family::Acp
    } else if id.contains("codex") {
        Family::Codex
    } else {
        Family::Claude
    }
}

fn acp_kind_of(provider_id: &str) -> AcpProviderId {
    let id = provider_id.to_ascii_lowercase();
    if id.contains("grok") {
        AcpProviderId::GrokBuild
    } else if id.contains("cursor") {
        AcpProviderId::Cursor
    } else {
        AcpProviderId::OpenCode
    }
}

fn mint_uuid() -> RunUuid {
    RunUuid::parse(&uuid_v4()).unwrap_or_else(|_| RunUuid::from_bytes([0; 16]))
}

fn parse_or_mint(value: &str) -> RunUuid {
    RunUuid::parse(value).unwrap_or_else(|_| mint_uuid())
}

fn decision_from_answer(answer: Option<&v1::InteractionAnswer>) -> ApprovalDecisionKind {
    let Some(answer) = answer else {
        return ApprovalDecisionKind::Decline;
    };
    if answer.skipped {
        return ApprovalDecisionKind::Cancel;
    }
    match answer.answer.as_ref() {
        Some(v1::interaction_answer::Answer::Approval(decision)) => {
            ApprovalDecisionKind::try_from(decision.kind).unwrap_or(ApprovalDecisionKind::Decline)
        }
        _ => ApprovalDecisionKind::Decline,
    }
}

fn unwrap_update(params_json: &str) -> String {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(params_json) else {
        return if params_json.is_empty() {
            "{}".to_string()
        } else {
            params_json.to_string()
        };
    };
    value.get("update").cloned().unwrap_or(value).to_string()
}

fn wrap_turn_params(body: &str) -> String {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(body) else {
        return body.to_string();
    };
    if value.get("turn").is_some() {
        return body.to_string();
    }
    serde_json::json!({"turn": value}).to_string()
}

fn turn_status_is_terminal(body: &str) -> bool {
    json_string_at(body, &["turn", "status"])
        .or_else(|| json_string_at(body, &["status"]))
        .is_some_and(|status| {
            matches!(
                status.to_ascii_lowercase().as_str(),
                "completed" | "interrupted" | "failed"
            )
        })
}

fn json_string_at(body: &str, path: &[&str]) -> Option<String> {
    let mut value = serde_json::from_str::<serde_json::Value>(body).ok()?;
    for key in path {
        value = value.get(*key)?.clone();
    }
    value.as_str().map(ToString::to_string)
}

fn lifecycle_event(now: &str, event: v1::RunLifecycleEvent) -> v1::AgentSessionEvent {
    v1::AgentSessionEvent {
        recorded_at: now.to_string(),
        body: Some(v1::agent_session_event::Body::RunLifecycle(event)),
    }
}

fn runtime_event(
    now: &str,
    run_id: impl Into<String>,
    turn_id: impl Into<String>,
    kind: v1::runtime_event::Kind,
) -> v1::AgentSessionEvent {
    v1::AgentSessionEvent {
        recorded_at: now.to_string(),
        body: Some(v1::agent_session_event::Body::RuntimeEvent(
            v1::RuntimeEvent {
                run_id: run_id.into(),
                turn_id: turn_id.into(),
                kind: Some(kind),
            },
        )),
    }
}

fn stream_event(
    now: &str,
    run_id: &str,
    turn_id: &str,
    item_type: &str,
    text: &str,
) -> v1::AgentSessionEvent {
    runtime_event(
        now,
        run_id,
        turn_id,
        v1::runtime_event::Kind::Stream(v1::StreamResult {
            item_type: item_type.to_string(),
            text: Some(text.to_string()),
            ..v1::StreamResult::default()
        }),
    )
}

fn lifecycle_stream(
    now: &str,
    live: &LiveTurn,
    event: &ToolLifecycleEvent,
) -> v1::AgentSessionEvent {
    runtime_event(
        now,
        &live.run_id,
        &live.turn_id,
        v1::runtime_event::Kind::Stream(v1::StreamResult {
            item_type: event.kind_name().to_string(),
            text: Some(event.name().to_string()),
            tool_name: Some(event.name().to_string()),
            tool_args: event.args_json().map(ToString::to_string),
            tool_output: event.result_json().map(ToString::to_string),
            tool_invocation_id: event.invocation_id().map(ToString::to_string),
            tool_result_json: event.result_json().map(ToString::to_string),
            tool_args_json: event.args_json().map(ToString::to_string),
            tool_is_error: event.is_error(),
            ..v1::StreamResult::default()
        }),
    )
}
