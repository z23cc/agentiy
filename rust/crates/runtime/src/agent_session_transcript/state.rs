//! Value-state port of `AgentSessionHostSessionState`.

use std::collections::{BTreeMap, BTreeSet};

use agentry_proto::agent_host::v1;

use super::canonical::hex_bytes;
use crate::agent_run_lifecycle::{Canonical, CanonicalValue, json_string};

#[derive(Clone, Debug, PartialEq, Eq)]
struct AssistantDraft {
    run_id: String,
    turn_id: String,
    text: String,
    created_at: String,
}

/// Derived view of one session, folded from its event log (design §7: the log is canonical, this
/// is a cache). The same reducer runs for live events, replay on recovery, and snapshot
/// construction.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionState {
    summary: v1::SessionSummary,
    transcript: Vec<v1::TranscriptEntry>,
    pending_interactions: Vec<v1::PendingInteraction>,
    accepted_operations: BTreeMap<String, v1::CommandAccepted>,
    settled_operations: BTreeMap<String, v1::CommandSettled>,
    settled_interaction_ids: BTreeSet<String>,
    last_cursor: u64,
    has_metadata: bool,
    assistant_draft: Option<AssistantDraft>,
}

impl SessionState {
    /// Placeholder for a recovered log whose first record has not been read yet.
    #[must_use]
    pub fn placeholder(session_id: impl Into<String>) -> Self {
        Self {
            summary: v1::SessionSummary {
                session_id: session_id.into(),
                ..v1::SessionSummary::default()
            },
            transcript: Vec::new(),
            pending_interactions: Vec::new(),
            accepted_operations: BTreeMap::new(),
            settled_operations: BTreeMap::new(),
            settled_interaction_ids: BTreeSet::new(),
            last_cursor: 0,
            has_metadata: false,
            assistant_draft: None,
        }
    }

    /// `AgentSessionHostSessionState(summary:)` — `hasMetadata` is true only when status is set.
    #[must_use]
    pub fn from_summary(summary: v1::SessionSummary) -> Self {
        let has_metadata = summary.status != v1::SessionStatus::Unspecified as i32;
        Self {
            summary,
            transcript: Vec::new(),
            pending_interactions: Vec::new(),
            accepted_operations: BTreeMap::new(),
            settled_operations: BTreeMap::new(),
            settled_interaction_ids: BTreeSet::new(),
            last_cursor: 0,
            has_metadata,
            assistant_draft: None,
        }
    }

    /// `AgentSessionHostSessionState(snapshot:)` — a present summary counts as metadata even when
    /// its status is still unspecified.
    #[must_use]
    pub fn from_snapshot(snapshot: v1::AgentSessionSnapshot) -> Self {
        let (summary, has_metadata) = match snapshot.summary {
            Some(summary) => (summary, true),
            None => (
                v1::SessionSummary {
                    session_id: snapshot.session_id,
                    ..v1::SessionSummary::default()
                },
                false,
            ),
        };
        let accepted_operations = snapshot
            .unsettled_operations
            .into_iter()
            .map(|accepted| (accepted.operation_id.clone(), accepted))
            .collect();
        Self {
            summary,
            transcript: snapshot.transcript,
            pending_interactions: snapshot.pending_interactions,
            accepted_operations,
            settled_operations: BTreeMap::new(),
            settled_interaction_ids: BTreeSet::new(),
            last_cursor: snapshot.through_cursor,
            has_metadata,
            assistant_draft: None,
        }
    }

    /// Back to a freshly constructed placeholder for the same session id.
    pub fn reset(&mut self) {
        *self = Self::placeholder(self.summary.session_id.clone());
    }

    #[must_use]
    pub fn summary(&self) -> &v1::SessionSummary {
        &self.summary
    }

    #[must_use]
    pub fn transcript(&self) -> &[v1::TranscriptEntry] {
        &self.transcript
    }

    #[must_use]
    pub fn pending_interactions(&self) -> &[v1::PendingInteraction] {
        &self.pending_interactions
    }

    #[must_use]
    pub fn last_cursor(&self) -> u64 {
        self.last_cursor
    }

    #[must_use]
    pub fn has_metadata(&self) -> bool {
        self.has_metadata
    }

    #[must_use]
    pub fn is_terminal(&self) -> bool {
        matches!(
            v1::SessionStatus::try_from(self.summary.status)
                .unwrap_or(v1::SessionStatus::Unspecified),
            v1::SessionStatus::Completed
                | v1::SessionStatus::Failed
                | v1::SessionStatus::Cancelled
                | v1::SessionStatus::Expired
        )
    }

    #[must_use]
    pub fn has_live_run(&self) -> bool {
        !self.summary.active_run_id.is_empty() || !self.pending_interactions.is_empty()
    }

    #[must_use]
    pub fn unsettled_operations(&self) -> Vec<v1::CommandAccepted> {
        let mut operations: Vec<v1::CommandAccepted> = self
            .accepted_operations
            .values()
            .filter(|accepted| !self.settled_operations.contains_key(&accepted.operation_id))
            .cloned()
            .collect();
        operations.sort_by(|left, right| {
            (left.accepted_at.as_str(), left.operation_id.as_str())
                .cmp(&(right.accepted_at.as_str(), right.operation_id.as_str()))
        });
        operations
    }

    #[must_use]
    pub fn accepted_operations(&self) -> &BTreeMap<String, v1::CommandAccepted> {
        &self.accepted_operations
    }

    #[must_use]
    pub fn settled_operations(&self) -> &BTreeMap<String, v1::CommandSettled> {
        &self.settled_operations
    }

    #[must_use]
    pub fn settled_interaction_ids(&self) -> &BTreeSet<String> {
        &self.settled_interaction_ids
    }

    pub fn set_generation(&mut self, generation: Vec<u8>) {
        self.summary.generation = generation;
    }

    pub fn set_attached_client_count(&mut self, count: u32) {
        self.summary.attached_client_count = count;
    }

    /// The summary the host records when it changes status itself (stop, restart demotion).
    #[must_use]
    pub fn host_owned_summary(
        &self,
        status: v1::SessionStatus,
        status_text: impl Into<String>,
        clearing_active_run: bool,
        now: impl Into<String>,
    ) -> v1::SessionSummary {
        let mut next = self.summary.clone();
        next.status = status as i32;
        next.status_text = status_text.into();
        if clearing_active_run {
            next.active_run_id.clear();
        }
        next.updated_at = now.into();
        next
    }

    #[must_use]
    pub fn snapshot(
        &self,
        generation: Vec<u8>,
        now: impl Into<String>,
    ) -> v1::AgentSessionSnapshot {
        v1::AgentSessionSnapshot {
            session_id: self.summary.session_id.clone(),
            generation,
            through_cursor: self.last_cursor,
            summary: Some(self.summary.clone()),
            transcript: self.transcript.clone(),
            pending_interactions: self.pending_interactions.clone(),
            unsettled_operations: self.unsettled_operations(),
            written_at: now.into(),
        }
    }

    /// Fold one event-log record. Out-of-order smaller cursors still apply; `last_cursor` never
    /// decreases.
    pub fn apply(&mut self, event: &v1::AgentSessionEvent, cursor: u64) {
        self.last_cursor = self.last_cursor.max(cursor);
        self.summary.last_cursor = self.last_cursor;
        self.summary.updated_at.clone_from(&event.recorded_at);
        let Some(body) = event.body.as_ref() else {
            return;
        };
        match body {
            v1::agent_session_event::Body::SessionMetadataChanged(change) => {
                if let Some(next) = change.summary.as_ref() {
                    let attached_client_count = self.summary.attached_client_count;
                    let generation = self.summary.generation.clone();
                    let mut replacement = next.clone();
                    replacement.attached_client_count = attached_client_count;
                    replacement.generation = generation;
                    replacement.last_cursor = self.last_cursor;
                    replacement.interaction = self.pending_interactions.first().cloned();
                    replacement.transcript_item_count = u64_len(&self.transcript);
                    self.summary = replacement;
                    self.has_metadata = true;
                }
            }
            v1::agent_session_event::Body::UserMessage(message) => {
                self.append_user_message(message, cursor, &event.recorded_at);
            }
            v1::agent_session_event::Body::RunLifecycle(lifecycle) => {
                self.apply_lifecycle(lifecycle, cursor, &event.recorded_at);
            }
            v1::agent_session_event::Body::RuntimeEvent(runtime) => {
                self.apply_runtime(runtime, cursor, &event.recorded_at);
            }
            v1::agent_session_event::Body::Interaction(interaction) => {
                match interaction.kind.as_ref() {
                    Some(v1::interaction_event::Kind::Requested(requested)) => {
                        if let Some(pending) = requested.interaction.as_ref() {
                            self.pending_interactions
                                .retain(|item| item.interaction_id != pending.interaction_id);
                            self.pending_interactions.push(pending.clone());
                        }
                    }
                    Some(v1::interaction_event::Kind::Settled(settled)) => {
                        self.pending_interactions
                            .retain(|item| item.interaction_id != settled.interaction_id);
                        self.settled_interaction_ids
                            .insert(settled.interaction_id.clone());
                    }
                    None => {}
                }
                self.summary.interaction = self.pending_interactions.first().cloned();
            }
            v1::agent_session_event::Body::CommandAccepted(accepted) => {
                self.accepted_operations
                    .insert(accepted.operation_id.clone(), accepted.clone());
            }
            v1::agent_session_event::Body::CommandSettled(settled) => {
                self.settled_operations
                    .insert(settled.operation_id.clone(), settled.clone());
            }
            v1::agent_session_event::Body::Imported(_)
            | v1::agent_session_event::Body::ForkedFrom(_) => {}
        }
    }

    fn append_user_message(&mut self, message: &v1::UserMessage, cursor: u64, recorded_at: &str) {
        let entry_id = if message.message_id.is_empty() {
            format!("user-{cursor}")
        } else {
            message.message_id.clone()
        };
        let user_role = v1::TranscriptRole::User as i32;
        if self
            .transcript
            .iter()
            .any(|entry| entry.role == user_role && entry.entry_id == entry_id)
        {
            return;
        }
        let created_at = if message.created_at.is_empty() {
            recorded_at.to_owned()
        } else {
            message.created_at.clone()
        };
        self.transcript.push(v1::TranscriptEntry {
            entry_id,
            role: user_role,
            text: message.text.clone(),
            reasoning: String::new(),
            tool_name: String::new(),
            tool_invocation_id: String::new(),
            tool_args_json: String::new(),
            tool_result_json: String::new(),
            tool_is_error: false,
            attachments: message.attachments.clone(),
            created_at,
            turn_id: String::new(),
            through_cursor: cursor,
        });
        self.summary.transcript_item_count = u64_len(&self.transcript);
    }

    fn apply_lifecycle(
        &mut self,
        lifecycle: &v1::RunLifecycleEvent,
        cursor: u64,
        recorded_at: &str,
    ) {
        match lifecycle.kind.as_ref() {
            Some(v1::run_lifecycle_event::Kind::Started(started)) => {
                if let Some(message) = started.message.as_ref() {
                    self.append_user_message(message, cursor, recorded_at);
                }
                self.summary.active_run_id.clone_from(&lifecycle.run_id);
                self.summary.status = v1::SessionStatus::Running as i32;
                self.summary.status_text = String::from("running");
                self.summary.failure_reason = v1::FailureReason::Unspecified as i32;
                self.assistant_draft = None;
            }
            Some(v1::run_lifecycle_event::Kind::StageChanged(stage)) => {
                self.summary.status_text = describe_stage(stage.stage).to_owned();
            }
            Some(v1::run_lifecycle_event::Kind::Terminated(terminated)) => {
                self.flush_assistant_draft(cursor, recorded_at);
                self.summary.active_run_id.clear();
                let kind = terminated
                    .outcome
                    .as_ref()
                    .map(|outcome| {
                        v1::TerminalOutcomeKind::try_from(outcome.kind)
                            .unwrap_or(v1::TerminalOutcomeKind::Unspecified)
                    })
                    .unwrap_or(v1::TerminalOutcomeKind::Unspecified);
                match kind {
                    v1::TerminalOutcomeKind::Completed | v1::TerminalOutcomeKind::Unspecified => {
                        self.summary.status = v1::SessionStatus::WaitingForInput as i32;
                        self.summary.status_text = String::from("turn completed");
                    }
                    v1::TerminalOutcomeKind::Cancelled => {
                        self.summary.status = v1::SessionStatus::WaitingForInput as i32;
                        self.summary.status_text = String::from("interrupted");
                    }
                    v1::TerminalOutcomeKind::Failed => {
                        self.summary.status = v1::SessionStatus::Failed as i32;
                        self.summary.status_text = String::from("failed");
                        self.summary.failure_reason = terminated
                            .outcome
                            .as_ref()
                            .map_or(v1::FailureReason::Unspecified as i32, |outcome| {
                                outcome.failure_reason
                            });
                    }
                }
                for pending in &self.pending_interactions {
                    self.settled_interaction_ids
                        .insert(pending.interaction_id.clone());
                }
                self.pending_interactions.clear();
                self.summary.interaction = None;
            }
            None => {}
        }
    }

    fn apply_runtime(&mut self, runtime: &v1::RuntimeEvent, cursor: u64, recorded_at: &str) {
        match runtime.kind.as_ref() {
            Some(v1::runtime_event::Kind::Stream(stream)) => {
                match stream.item_type.as_str() {
                    "content" => {
                        let mut draft =
                            self.assistant_draft
                                .take()
                                .unwrap_or_else(|| AssistantDraft {
                                    run_id: runtime.run_id.clone(),
                                    turn_id: runtime.turn_id.clone(),
                                    text: String::new(),
                                    created_at: recorded_at.to_owned(),
                                });
                        if let Some(text) = stream.text.as_deref() {
                            draft.text.push_str(text);
                        }
                        self.assistant_draft = Some(draft);
                    }
                    "final_content" => {
                        let mut draft =
                            self.assistant_draft
                                .take()
                                .unwrap_or_else(|| AssistantDraft {
                                    run_id: runtime.run_id.clone(),
                                    turn_id: runtime.turn_id.clone(),
                                    text: String::new(),
                                    created_at: recorded_at.to_owned(),
                                });
                        if let Some(text) = stream.text.as_ref() {
                            if !text.is_empty() {
                                draft.text.clone_from(text);
                            }
                        }
                        self.assistant_draft = Some(draft);
                    }
                    _ => {}
                }
                if let Some(provider_session_id) = stream.provider_session_id.as_ref() {
                    if !provider_session_id.is_empty() {
                        self.summary
                            .provider_session_id
                            .clone_from(provider_session_id);
                    }
                }
            }
            Some(v1::runtime_event::Kind::RuntimeInit(status)) => {
                if !status.provider_session_id.is_empty() {
                    self.summary
                        .provider_session_id
                        .clone_from(&status.provider_session_id);
                }
            }
            Some(v1::runtime_event::Kind::TurnCompleted(_)) => {
                self.flush_assistant_draft(cursor, recorded_at);
            }
            Some(v1::runtime_event::Kind::Error(error)) => {
                self.summary.status_text.clone_from(&error.message);
            }
            Some(v1::runtime_event::Kind::ApprovalRequest(_))
            | Some(v1::runtime_event::Kind::ApprovalCancelled(_))
            | None => {}
        }
    }

    fn flush_assistant_draft(&mut self, cursor: u64, recorded_at: &str) {
        let Some(draft) = self.assistant_draft.take() else {
            return;
        };
        if draft.text.is_empty() {
            return;
        }
        let created_at = if draft.created_at.is_empty() {
            recorded_at.to_owned()
        } else {
            draft.created_at
        };
        self.transcript.push(v1::TranscriptEntry {
            entry_id: format!("assistant-{cursor}"),
            role: v1::TranscriptRole::Assistant as i32,
            text: draft.text.clone(),
            reasoning: String::new(),
            tool_name: String::new(),
            tool_invocation_id: String::new(),
            tool_args_json: String::new(),
            tool_result_json: String::new(),
            tool_is_error: false,
            attachments: Vec::new(),
            created_at,
            turn_id: draft.turn_id,
            through_cursor: cursor,
        });
        self.summary.transcript_item_count = u64_len(&self.transcript);
        self.summary.latest_assistant_preview = draft.text.chars().take(200).collect();
    }
}

impl CanonicalValue for SessionState {
    fn canonical(&self) -> String {
        let transcript = canonical_array(self.transcript.iter().map(canonical_transcript_entry));
        let pending = canonical_array(
            self.pending_interactions
                .iter()
                .map(canonical_pending_interaction),
        );
        let accepted = canonical_array(self.accepted_operations.values().map(canonical_accepted));
        let settled = canonical_array(self.settled_operations.values().map(canonical_settled));
        let settled_ids = canonical_array(
            self.settled_interaction_ids
                .iter()
                .map(|id| json_string(id)),
        );
        Canonical::object()
            .u64("lastCursor", self.last_cursor)
            .bool("hasMetadata", self.has_metadata)
            .bool("isTerminal", self.is_terminal())
            .bool("hasLiveRun", self.has_live_run())
            .raw("summary", &canonical_summary(&self.summary))
            .raw("transcript", &transcript)
            .raw("pendingInteractions", &pending)
            .raw("acceptedOperations", &accepted)
            .raw("settledOperations", &settled)
            .raw("settledInteractionIDs", &settled_ids)
            .finish()
    }
}

fn u64_len<T>(items: &[T]) -> u64 {
    u64::try_from(items.len()).unwrap_or(u64::MAX)
}

fn describe_stage(stage: i32) -> &'static str {
    match v1::LifecycleStage::try_from(stage).unwrap_or(v1::LifecycleStage::Unspecified) {
        v1::LifecycleStage::Unspecified => "running",
        v1::LifecycleStage::Starting => "starting",
        v1::LifecycleStage::PreparingRuntime => "preparing runtime",
        v1::LifecycleStage::Running => "running",
        v1::LifecycleStage::WaitingForInteraction => "waiting for interaction",
        v1::LifecycleStage::Retrying => "retrying",
        v1::LifecycleStage::Cancelling => "cancelling",
    }
}

fn status_name(value: i32) -> &'static str {
    match v1::SessionStatus::try_from(value).unwrap_or(v1::SessionStatus::Unspecified) {
        v1::SessionStatus::Unspecified => "unspecified",
        v1::SessionStatus::Running => "running",
        v1::SessionStatus::WaitingForInput => "waitingForInput",
        v1::SessionStatus::Completed => "completed",
        v1::SessionStatus::Failed => "failed",
        v1::SessionStatus::Cancelled => "cancelled",
        v1::SessionStatus::Expired => "expired",
    }
}

fn failure_name(value: i32) -> &'static str {
    match v1::FailureReason::try_from(value).unwrap_or(v1::FailureReason::Unspecified) {
        v1::FailureReason::Unspecified => "unspecified",
        v1::FailureReason::ProcessCrash => "processCrash",
        v1::FailureReason::Timeout => "timeout",
        v1::FailureReason::AgentError => "agentError",
        v1::FailureReason::Cancelled => "cancelled",
    }
}

fn role_name(value: i32) -> &'static str {
    match v1::TranscriptRole::try_from(value).unwrap_or(v1::TranscriptRole::Unspecified) {
        v1::TranscriptRole::Unspecified => "unspecified",
        v1::TranscriptRole::User => "user",
        v1::TranscriptRole::Assistant => "assistant",
        v1::TranscriptRole::Tool => "tool",
        v1::TranscriptRole::System => "system",
    }
}

fn interaction_kind_name(value: i32) -> &'static str {
    match v1::InteractionKind::try_from(value).unwrap_or(v1::InteractionKind::Unspecified) {
        v1::InteractionKind::Unspecified => "unspecified",
        v1::InteractionKind::Instruction => "instruction",
        v1::InteractionKind::Question => "question",
        v1::InteractionKind::UserInput => "userInput",
        v1::InteractionKind::Approval => "approval",
        v1::InteractionKind::HookApproval => "hookApproval",
        v1::InteractionKind::McpElicitation => "mcpElicitation",
    }
}

fn canonical_array(items: impl IntoIterator<Item = String>) -> String {
    let inner = items.into_iter().collect::<Vec<_>>().join(",");
    format!("[{inner}]")
}

fn canonical_summary(summary: &v1::SessionSummary) -> String {
    Canonical::object()
        .string("sessionId", &summary.session_id)
        .string("workspaceId", &summary.workspace_id)
        .string("worktreeId", &summary.worktree_id)
        .string("sessionName", &summary.session_name)
        .string("providerId", &summary.provider_id)
        .string("agentId", &summary.agent_id)
        .string("agentDisplayName", &summary.agent_display_name)
        .string("modelId", &summary.model_id)
        .string("reasoningEffort", &summary.reasoning_effort)
        .string("status", status_name(summary.status))
        .string("statusText", &summary.status_text)
        .string("latestAssistantPreview", &summary.latest_assistant_preview)
        .optional_string(
            "interactionId",
            summary
                .interaction
                .as_ref()
                .map(|interaction| interaction.interaction_id.as_str()),
        )
        .u64("transcriptItemCount", summary.transcript_item_count)
        .string("createdAt", &summary.created_at)
        .string("updatedAt", &summary.updated_at)
        .string("parentSessionId", &summary.parent_session_id)
        .string("failureReason", failure_name(summary.failure_reason))
        .string("providerSessionId", &summary.provider_session_id)
        .string("activeRunId", &summary.active_run_id)
        .u64(
            "attachedClientCount",
            u64::from(summary.attached_client_count),
        )
        .string("generation", &hex_bytes(&summary.generation))
        .u64("lastCursor", summary.last_cursor)
        .finish()
}

fn canonical_transcript_entry(entry: &v1::TranscriptEntry) -> String {
    let attachments = canonical_array(
        entry
            .attachments
            .iter()
            .map(|attachment| json_string(&attachment.artifact_id)),
    );
    Canonical::object()
        .string("entryId", &entry.entry_id)
        .string("role", role_name(entry.role))
        .string("text", &entry.text)
        .string("reasoning", &entry.reasoning)
        .string("toolName", &entry.tool_name)
        .string("toolInvocationId", &entry.tool_invocation_id)
        .string("toolArgsJson", &entry.tool_args_json)
        .string("toolResultJson", &entry.tool_result_json)
        .bool("toolIsError", entry.tool_is_error)
        .raw("attachments", &attachments)
        .string("createdAt", &entry.created_at)
        .string("turnId", &entry.turn_id)
        .u64("throughCursor", entry.through_cursor)
        .finish()
}

fn canonical_pending_interaction(pending: &v1::PendingInteraction) -> String {
    Canonical::object()
        .string("interactionId", &pending.interaction_id)
        .string("generation", &hex_bytes(&pending.interaction_generation))
        .string("kind", interaction_kind_name(pending.kind))
        .string("title", &pending.title)
        .string("prompt", &pending.prompt)
        .string("runId", &pending.run_id)
        .string("turnId", &pending.turn_id)
        .string("requestedAt", &pending.requested_at)
        .finish()
}

fn canonical_accepted(accepted: &v1::CommandAccepted) -> String {
    Canonical::object()
        .string("operationId", &accepted.operation_id)
        .string("argumentFingerprint", &accepted.argument_fingerprint)
        .string("commandKind", &accepted.command_kind)
        .string("acceptedAt", &accepted.accepted_at)
        .finish()
}

fn canonical_settled(settled: &v1::CommandSettled) -> String {
    let settlement = match settled.settlement.as_ref() {
        Some(v1::command_settled::Settlement::Result(_)) => "result",
        Some(v1::command_settled::Settlement::Rejected(_)) => "rejected",
        None => "none",
    };
    Canonical::object()
        .string("operationId", &settled.operation_id)
        .string("settledAt", &settled.settled_at)
        .string("settlement", settlement)
        .finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_run_lifecycle::CanonicalValue;

    fn event(recorded_at: &str, body: v1::agent_session_event::Body) -> v1::AgentSessionEvent {
        v1::AgentSessionEvent {
            recorded_at: recorded_at.to_owned(),
            body: Some(body),
        }
    }

    fn user_message(id: &str, text: &str, created_at: &str) -> v1::UserMessage {
        v1::UserMessage {
            message_id: id.to_owned(),
            text: text.to_owned(),
            attachments: Vec::new(),
            created_at: created_at.to_owned(),
        }
    }

    fn lifecycle(
        run_id: &str,
        kind: v1::run_lifecycle_event::Kind,
    ) -> v1::agent_session_event::Body {
        v1::agent_session_event::Body::RunLifecycle(v1::RunLifecycleEvent {
            run_id: run_id.to_owned(),
            epoch: None,
            kind: Some(kind),
        })
    }

    fn runtime(
        run_id: &str,
        turn_id: &str,
        kind: v1::runtime_event::Kind,
    ) -> v1::agent_session_event::Body {
        v1::agent_session_event::Body::RuntimeEvent(v1::RuntimeEvent {
            run_id: run_id.to_owned(),
            turn_id: turn_id.to_owned(),
            kind: Some(kind),
        })
    }

    fn stream(
        item_type: &str,
        text: Option<&str>,
        provider_session_id: Option<&str>,
    ) -> v1::StreamResult {
        v1::StreamResult {
            item_type: item_type.to_owned(),
            text: text.map(str::to_owned),
            provider_session_id: provider_session_id.map(str::to_owned),
            ..v1::StreamResult::default()
        }
    }

    fn pending(id: &str) -> v1::PendingInteraction {
        v1::PendingInteraction {
            interaction_id: id.to_owned(),
            interaction_generation: vec![1, 2],
            kind: v1::InteractionKind::Question as i32,
            title: "ask".to_owned(),
            prompt: "choose".to_owned(),
            run_id: "run-1".to_owned(),
            turn_id: "turn-1".to_owned(),
            requested_at: "t0".to_owned(),
            ..v1::PendingInteraction::default()
        }
    }

    #[test]
    fn placeholder_has_no_metadata() {
        let state = SessionState::placeholder("sess-1");
        assert!(!state.has_metadata());
        assert_eq!(state.last_cursor(), 0);
        assert!(!state.is_terminal());
        assert!(!state.has_live_run());
        assert_eq!(state.summary().session_id, "sess-1");
    }

    #[test]
    fn user_message_appends_and_dedupes_by_id() {
        let mut state = SessionState::placeholder("sess-1");
        let message = user_message("m1", "hello", "t1");
        state.apply(
            &event(
                "rec-1",
                v1::agent_session_event::Body::UserMessage(message.clone()),
            ),
            1,
        );
        state.apply(
            &event("rec-2", v1::agent_session_event::Body::UserMessage(message)),
            2,
        );
        assert_eq!(state.transcript().len(), 1);
        assert_eq!(state.transcript()[0].entry_id, "m1");
        assert_eq!(state.transcript()[0].through_cursor, 1);
        assert_eq!(state.summary().transcript_item_count, 1);
        assert_eq!(state.last_cursor(), 2);
    }

    #[test]
    fn empty_message_id_uses_user_cursor() {
        let mut state = SessionState::placeholder("sess-1");
        state.apply(
            &event(
                "rec-1",
                v1::agent_session_event::Body::UserMessage(user_message("", "hi", "")),
            ),
            7,
        );
        assert_eq!(state.transcript()[0].entry_id, "user-7");
        assert_eq!(state.transcript()[0].created_at, "rec-1");
    }

    #[test]
    fn run_started_appends_message_sets_running_and_discards_draft() {
        let mut state = SessionState::placeholder("sess-1");
        state.apply(
            &event(
                "t0",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::Stream(stream("content", Some("draft"), None)),
                ),
            ),
            1,
        );
        state.apply(
            &event(
                "t1",
                lifecycle(
                    "run-2",
                    v1::run_lifecycle_event::Kind::Started(v1::RunStarted {
                        attempt_id: "a1".to_owned(),
                        message: Some(user_message("m1", "steer", "t1")),
                    }),
                ),
            ),
            2,
        );
        assert_eq!(state.summary().active_run_id, "run-2");
        assert_eq!(state.summary().status, v1::SessionStatus::Running as i32);
        assert_eq!(state.transcript().len(), 1);
        state.apply(
            &event(
                "t2",
                runtime(
                    "run-2",
                    "turn-2",
                    v1::runtime_event::Kind::TurnCompleted(v1::TurnCompleted {
                        turn_id: "turn-2".to_owned(),
                        stop_reason: String::new(),
                    }),
                ),
            ),
            3,
        );
        assert_eq!(
            state.transcript().len(),
            1,
            "discarded draft must not flush"
        );
    }

    #[test]
    fn stream_content_accumulates_final_content_replaces_and_flush_commits() {
        let mut state = SessionState::placeholder("sess-1");
        state.apply(
            &event(
                "t0",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::Stream(stream("content", Some("Hel"), None)),
                ),
            ),
            1,
        );
        state.apply(
            &event(
                "t1",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::Stream(stream("content", Some("lo"), Some("ps-9"))),
                ),
            ),
            2,
        );
        state.apply(
            &event(
                "t2",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::Stream(stream("final_content", Some("Hello!"), None)),
                ),
            ),
            3,
        );
        state.apply(
            &event(
                "t3",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::TurnCompleted(v1::TurnCompleted {
                        turn_id: "turn-1".to_owned(),
                        stop_reason: String::new(),
                    }),
                ),
            ),
            4,
        );
        assert_eq!(state.transcript().len(), 1);
        assert_eq!(state.transcript()[0].text, "Hello!");
        assert_eq!(state.transcript()[0].entry_id, "assistant-4");
        assert_eq!(state.transcript()[0].turn_id, "turn-1");
        assert_eq!(state.summary().latest_assistant_preview, "Hello!");
        assert_eq!(state.summary().provider_session_id, "ps-9");
    }

    #[test]
    fn empty_draft_does_not_append_and_reasoning_tool_items_are_ignored() {
        let mut state = SessionState::placeholder("sess-1");
        state.apply(
            &event(
                "t0",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::Stream(stream("reasoning", Some("think"), None)),
                ),
            ),
            1,
        );
        state.apply(
            &event(
                "t1",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::Stream(stream("tool_call", None, None)),
                ),
            ),
            2,
        );
        state.apply(
            &event(
                "t2",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::TurnCompleted(v1::TurnCompleted {
                        turn_id: "turn-1".to_owned(),
                        stop_reason: String::new(),
                    }),
                ),
            ),
            3,
        );
        assert!(state.transcript().is_empty());
    }

    #[test]
    fn terminated_outcomes_and_pending_settlement() {
        let mut state = SessionState::placeholder("sess-1");
        state.apply(
            &event(
                "t0",
                v1::agent_session_event::Body::Interaction(v1::InteractionEvent {
                    kind: Some(v1::interaction_event::Kind::Requested(
                        v1::InteractionRequested {
                            interaction: Some(pending("q1")),
                        },
                    )),
                }),
            ),
            1,
        );
        assert!(state.has_live_run());
        state.apply(
            &event(
                "t1",
                lifecycle(
                    "run-1",
                    v1::run_lifecycle_event::Kind::Terminated(v1::RunTerminated {
                        outcome: Some(v1::TerminalOutcome {
                            kind: v1::TerminalOutcomeKind::Failed as i32,
                            assistant_text: None,
                            failure_reason: v1::FailureReason::Timeout as i32,
                        }),
                        signal: None,
                    }),
                ),
            ),
            2,
        );
        assert_eq!(state.summary().status, v1::SessionStatus::Failed as i32);
        assert_eq!(state.summary().status_text, "failed");
        assert_eq!(
            state.summary().failure_reason,
            v1::FailureReason::Timeout as i32
        );
        assert!(state.pending_interactions().is_empty());
        assert!(state.settled_interaction_ids().contains("q1"));
        assert!(state.is_terminal());
        assert!(!state.has_live_run());
    }

    #[test]
    fn stage_describe_and_cancelled_termination() {
        let mut state = SessionState::placeholder("sess-1");
        for (stage, expected) in [
            (v1::LifecycleStage::Unspecified, "running"),
            (v1::LifecycleStage::Starting, "starting"),
            (v1::LifecycleStage::PreparingRuntime, "preparing runtime"),
            (v1::LifecycleStage::Running, "running"),
            (
                v1::LifecycleStage::WaitingForInteraction,
                "waiting for interaction",
            ),
            (v1::LifecycleStage::Retrying, "retrying"),
            (v1::LifecycleStage::Cancelling, "cancelling"),
        ] {
            state.apply(
                &event(
                    "t",
                    lifecycle(
                        "run-1",
                        v1::run_lifecycle_event::Kind::StageChanged(v1::RunStageChanged {
                            stage: stage as i32,
                            retry_intent: v1::RetryIntent::None as i32,
                        }),
                    ),
                ),
                1,
            );
            assert_eq!(state.summary().status_text, expected);
        }
        state.apply(
            &event(
                "t2",
                lifecycle(
                    "run-1",
                    v1::run_lifecycle_event::Kind::Terminated(v1::RunTerminated {
                        outcome: Some(v1::TerminalOutcome {
                            kind: v1::TerminalOutcomeKind::Cancelled as i32,
                            assistant_text: None,
                            failure_reason: v1::FailureReason::Unspecified as i32,
                        }),
                        signal: None,
                    }),
                ),
            ),
            2,
        );
        assert_eq!(
            state.summary().status,
            v1::SessionStatus::WaitingForInput as i32
        );
        assert_eq!(state.summary().status_text, "interrupted");
        assert!(!state.is_terminal());
    }

    #[test]
    fn interaction_replace_settle_and_commands() {
        let mut state = SessionState::placeholder("sess-1");
        let first = pending("q1");
        let mut second = pending("q1");
        second.prompt = "again".to_owned();
        state.apply(
            &event(
                "t0",
                v1::agent_session_event::Body::Interaction(v1::InteractionEvent {
                    kind: Some(v1::interaction_event::Kind::Requested(
                        v1::InteractionRequested {
                            interaction: Some(first),
                        },
                    )),
                }),
            ),
            1,
        );
        state.apply(
            &event(
                "t1",
                v1::agent_session_event::Body::Interaction(v1::InteractionEvent {
                    kind: Some(v1::interaction_event::Kind::Requested(
                        v1::InteractionRequested {
                            interaction: Some(second),
                        },
                    )),
                }),
            ),
            2,
        );
        assert_eq!(state.pending_interactions().len(), 1);
        assert_eq!(state.pending_interactions()[0].prompt, "again");
        state.apply(
            &event(
                "t2",
                v1::agent_session_event::Body::Interaction(v1::InteractionEvent {
                    kind: Some(v1::interaction_event::Kind::Settled(
                        v1::InteractionSettled {
                            interaction_id: "q1".to_owned(),
                            interaction_generation: vec![1, 2],
                            settlement: v1::InteractionSettlement::Answered as i32,
                            answer: None,
                            operation_id: "op-1".to_owned(),
                        },
                    )),
                }),
            ),
            3,
        );
        assert!(state.pending_interactions().is_empty());
        state.apply(
            &event(
                "t3",
                v1::agent_session_event::Body::CommandAccepted(v1::CommandAccepted {
                    operation_id: "op-b".to_owned(),
                    argument_fingerprint: "fb".to_owned(),
                    command_kind: "steer".to_owned(),
                    accepted_at: "t3".to_owned(),
                }),
            ),
            4,
        );
        state.apply(
            &event(
                "t4",
                v1::agent_session_event::Body::CommandAccepted(v1::CommandAccepted {
                    operation_id: "op-a".to_owned(),
                    argument_fingerprint: "fa".to_owned(),
                    command_kind: "start".to_owned(),
                    accepted_at: "t2".to_owned(),
                }),
            ),
            5,
        );
        let unsettled = state.unsettled_operations();
        assert_eq!(
            unsettled
                .iter()
                .map(|item| item.operation_id.as_str())
                .collect::<Vec<_>>(),
            ["op-a", "op-b"]
        );
        state.apply(
            &event(
                "t5",
                v1::agent_session_event::Body::CommandSettled(v1::CommandSettled {
                    operation_id: "op-a".to_owned(),
                    settled_at: "t5".to_owned(),
                    settlement: None,
                }),
            ),
            6,
        );
        assert_eq!(state.unsettled_operations().len(), 1);
        assert_eq!(state.unsettled_operations()[0].operation_id, "op-b");
    }

    #[test]
    fn metadata_preserves_attached_count_and_generation() {
        let mut state = SessionState::placeholder("sess-1");
        state.set_attached_client_count(3);
        state.set_generation(vec![9, 9]);
        let incoming = v1::SessionSummary {
            session_id: "sess-1".to_owned(),
            session_name: "renamed".to_owned(),
            status: v1::SessionStatus::Running as i32,
            updated_at: "from-summary".to_owned(),
            attached_client_count: 99,
            generation: vec![1],
            transcript_item_count: 50,
            ..v1::SessionSummary::default()
        };
        state.apply(
            &event(
                "recorded",
                v1::agent_session_event::Body::SessionMetadataChanged(v1::SessionMetadataChanged {
                    summary: Some(incoming),
                }),
            ),
            4,
        );
        assert!(state.has_metadata());
        assert_eq!(state.summary().session_name, "renamed");
        assert_eq!(state.summary().attached_client_count, 3);
        assert_eq!(state.summary().generation, vec![9, 9]);
        assert_eq!(state.summary().last_cursor, 4);
        assert_eq!(state.summary().transcript_item_count, 0);
        assert_eq!(state.summary().updated_at, "from-summary");
    }

    #[test]
    fn imported_forked_and_nil_body_only_advance_cursor() {
        let mut state = SessionState::placeholder("sess-1");
        state.apply(
            &event(
                "t0",
                v1::agent_session_event::Body::Imported(v1::Imported {
                    legacy_digest: "aa".to_owned(),
                    legacy_format: "json".to_owned(),
                    imported_item_count: 2,
                    imported_at: "t0".to_owned(),
                }),
            ),
            1,
        );
        state.apply(
            &event(
                "t1",
                v1::agent_session_event::Body::ForkedFrom(v1::ForkedFrom {
                    session_id: "parent".to_owned(),
                    cursor: 3,
                    generation: vec![1],
                }),
            ),
            2,
        );
        state.apply(
            &v1::AgentSessionEvent {
                recorded_at: "t2".to_owned(),
                body: None,
            },
            1,
        );
        assert_eq!(state.last_cursor(), 2);
        assert!(state.transcript().is_empty());
        assert_eq!(state.summary().updated_at, "t2");
    }

    #[test]
    fn runtime_init_error_and_approval_are_noops_except_status_and_session() {
        let mut state = SessionState::placeholder("sess-1");
        state.apply(
            &event(
                "t0",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::RuntimeInit(v1::RuntimeInitStatus {
                        provider_session_id: "ps-init".to_owned(),
                        tools: Vec::new(),
                        mcp_server_statuses: Vec::new(),
                        initialize_response: None,
                    }),
                ),
            ),
            1,
        );
        state.apply(
            &event(
                "t1",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::Error(v1::RuntimeError {
                        code: "e".to_owned(),
                        message: "boom".to_owned(),
                        recoverable: true,
                    }),
                ),
            ),
            2,
        );
        state.apply(
            &event(
                "t2",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::ApprovalRequest(v1::ApprovalRequest::default()),
                ),
            ),
            3,
        );
        assert_eq!(state.summary().provider_session_id, "ps-init");
        assert_eq!(state.summary().status_text, "boom");
        assert!(state.transcript().is_empty());
    }

    #[test]
    fn snapshot_round_trip_and_preview_truncation() {
        let mut state = SessionState::placeholder("sess-1");
        let long: String = (0..250).map(|_| 'a').collect();
        state.apply(
            &event(
                "t0",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::Stream(stream("content", Some(&long), None)),
                ),
            ),
            1,
        );
        state.apply(
            &event(
                "t1",
                runtime(
                    "run-1",
                    "turn-1",
                    v1::runtime_event::Kind::TurnCompleted(v1::TurnCompleted {
                        turn_id: "turn-1".to_owned(),
                        stop_reason: String::new(),
                    }),
                ),
            ),
            2,
        );
        assert_eq!(state.summary().latest_assistant_preview.len(), 200);
        let snapshot = state.snapshot(vec![7], "now");
        let restored = SessionState::from_snapshot(snapshot.clone());
        assert_eq!(restored.last_cursor(), 2);
        assert!(restored.has_metadata());
        assert_eq!(restored.transcript().len(), 1);
        assert_eq!(snapshot.generation, vec![7]);
        assert_eq!(snapshot.written_at, "now");
        assert!(CanonicalValue::canonical(&state).contains("\"lastCursor\":2"));
    }

    #[test]
    fn host_owned_summary_does_not_mutate() {
        let mut state = SessionState::from_summary(v1::SessionSummary {
            session_id: "sess-1".to_owned(),
            status: v1::SessionStatus::Running as i32,
            active_run_id: "run-1".to_owned(),
            ..v1::SessionSummary::default()
        });
        let next = state.host_owned_summary(v1::SessionStatus::Cancelled, "stopped", true, "now");
        assert_eq!(next.status, v1::SessionStatus::Cancelled as i32);
        assert!(next.active_run_id.is_empty());
        assert_eq!(state.summary().active_run_id, "run-1");
        state.reset();
        assert!(!state.has_metadata());
        assert_eq!(state.summary().session_id, "sess-1");
    }
}
