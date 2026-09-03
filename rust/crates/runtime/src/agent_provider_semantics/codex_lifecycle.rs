//! Codex bash / file-change lifecycle synthesis (ADR-0011 P6 leftover).
//!
//! Value-state port of the leftover Swift reducers in `CodexNativeSessionController`:
//! `FileChangeStreamState` + `parseFileChangeLifecycleEvent` / `parseFileChangeOutputDeltaEvent`,
//! and `applyCommandExecutionRunningUpdate` + `CommandExecutionPayloadHelper` + output sanitizer.
//! No I/O, no clocks. JSON payloads are compared as parsed objects (Swift `jsonString` is
//! pretty-printed; this module emits compact JSON).

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value, json};

use super::json::{first_string, int_value, parse_object, serialize_json};
use crate::agent_run_lifecycle::Canonical;

pub const MAX_RUNNING_AGGREGATED_OUTPUT_CHARACTERS: usize = 24_000;
pub const RUNNING_OUTPUT_TRUNCATION_MARKER: &str = "\n...(output truncated)...\n";

const COMMAND_EXECUTION_OUTPUT_KEYS: &[&str] = &[
    "formattedOutput",
    "formatted_output",
    "aggregatedOutput",
    "aggregated_output",
    "output",
    "stdout",
    "stderr",
    "combinedOutput",
    "combined_output",
    "recentOutput",
    "recent_output",
    "text",
    "message",
    "content",
    "result",
    "log",
    "logs",
];

const RUNNING_STATUS_WORDS: &[&str] = &["running", "in_progress", "inprogress", "in-progress", "pending"];
const TERMINAL_STATUS_WORDS: &[&str] = &[
    "completed", "complete", "success", "succeeded", "ok", "failed", "failure", "error",
    "cancelled", "canceled", "terminated", "stopped", "done", "exited", "finished", "timeout",
    "timed_out", "killed",
];

/// `CodexNativeSessionController.ToolLifecycleEvent`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolLifecycleEvent {
    Call {
        name: String,
        invocation_id: Option<String>,
        args_json: Option<String>,
        dedup_key: String,
    },
    Result {
        name: String,
        invocation_id: Option<String>,
        args_json: Option<String>,
        result_json: String,
        is_error: Option<bool>,
        dedup_key: String,
    },
}

impl ToolLifecycleEvent {
    #[must_use]
    pub fn kind_name(&self) -> &'static str {
        match self {
            Self::Call { .. } => "call",
            Self::Result { .. } => "result",
        }
    }

    #[must_use]
    pub fn name(&self) -> &str {
        match self {
            Self::Call { name, .. } | Self::Result { name, .. } => name,
        }
    }

    #[must_use]
    pub fn invocation_id(&self) -> Option<&str> {
        match self {
            Self::Call { invocation_id, .. } | Self::Result { invocation_id, .. } => {
                invocation_id.as_deref()
            }
        }
    }

    #[must_use]
    pub fn args_json(&self) -> Option<&str> {
        match self {
            Self::Call { args_json, .. } | Self::Result { args_json, .. } => args_json.as_deref(),
        }
    }

    #[must_use]
    pub fn result_json(&self) -> Option<&str> {
        match self {
            Self::Result { result_json, .. } => Some(result_json.as_str()),
            Self::Call { .. } => None,
        }
    }

    #[must_use]
    pub fn is_error(&self) -> Option<bool> {
        match self {
            Self::Result { is_error, .. } => *is_error,
            Self::Call { .. } => None,
        }
    }

    #[must_use]
    pub fn dedup_key(&self) -> &str {
        match self {
            Self::Call { dedup_key, .. } | Self::Result { dedup_key, .. } => dedup_key,
        }
    }

    #[must_use]
    pub fn canonical(&self) -> String {
        Canonical::object()
            .string("kind", self.kind_name())
            .string("name", self.name())
            .optional_string("invocationId", self.invocation_id())
            .optional_string("args", self.args_json())
            .optional_string("result", self.result_json())
            .raw(
                "isError",
                &self
                    .is_error()
                    .map(|value| if value { "true" } else { "false" }.to_string())
                    .unwrap_or_else(|| "null".to_string()),
            )
            .string("dedupKey", self.dedup_key())
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileChangeStreamState {
    pub item_id: String,
    pub invocation_id: Option<String>,
    pub args_json: Option<String>,
    pub latest_result_json: Option<String>,
    pub accumulated_output: String,
    pub status: String,
}

/// `fileChangeStateByItemID` + `terminalFileChangeItemIDs`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FileChangeLifecycleState {
    pub by_item: BTreeMap<String, FileChangeStreamState>,
    pub terminal_item_ids: BTreeSet<String>,
}

impl FileChangeLifecycleState {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    pub fn apply_lifecycle(&mut self, method: &str, params_json: &str) -> Option<ToolLifecycleEvent> {
        let lower = method.to_ascii_lowercase();
        let is_started = lower == "item/started";
        let is_completed = lower == "item/completed";
        if !is_started && !is_completed {
            return None;
        }
        let params = parse_object(params_json)?;
        let candidate = tool_item_candidates(&params)
            .into_iter()
            .find(|item| candidate_looks_like_file_change(item))?;
        let item_id = string_value(&candidate, &["id", "itemId", "item_id"])?;
        let invocation_id = stable_invocation_id(Some(&item_id));
        let existing = self.by_item.get(&item_id);
        let args_json = apply_patch_args_json(&candidate).or_else(|| existing.and_then(|s| s.args_json.clone()));
        let status_info = normalized_apply_patch_status(
            string_value(&candidate, &["status"]).as_deref(),
            is_completed,
        );
        let accumulated = existing.map(|s| s.accumulated_output.clone());
        let result_json = apply_patch_result_json(&candidate, accumulated.as_deref());

        if is_started {
            self.terminal_item_ids.remove(&item_id);
            self.by_item.insert(
                item_id.clone(),
                FileChangeStreamState {
                    item_id: item_id.clone(),
                    invocation_id: invocation_id.clone(),
                    args_json: args_json.clone(),
                    latest_result_json: Some(result_json),
                    accumulated_output: existing.map(|s| s.accumulated_output.clone()).unwrap_or_default(),
                    status: status_info.status,
                },
            );
            let dedup_key = tool_dedup_key(Some(&item_id), "apply_patch", args_json.as_deref(), None);
            return Some(ToolLifecycleEvent::Call {
                name: "apply_patch".to_string(),
                invocation_id,
                args_json,
                dedup_key,
            });
        }

        self.by_item.remove(&item_id);
        self.terminal_item_ids.insert(item_id.clone());
        let dedup_key = tool_dedup_key(
            Some(&item_id),
            "apply_patch",
            args_json.as_deref(),
            Some(&result_json),
        );
        Some(ToolLifecycleEvent::Result {
            name: "apply_patch".to_string(),
            invocation_id,
            args_json,
            result_json,
            is_error: status_info.is_error,
            dedup_key,
        })
    }

    pub fn apply_output_delta(&mut self, params_json: &str) -> Option<ToolLifecycleEvent> {
        let params = parse_object(params_json)?;
        let message = params
            .get("msg")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or(params);
        let item_id = string_value(&message, &["itemId", "item_id", "id"])?;
        if self.terminal_item_ids.contains(&item_id) {
            return None;
        }
        let invocation_id = stable_invocation_id(Some(&item_id));
        let raw_output = raw_string_value(&message, &["delta", "output", "text", "message", "content"]);
        let sanitized_output = raw_output.map(|output| {
            let sanitized = sanitize_command_output(&output);
            if sanitized.is_empty()
                && !output.is_empty()
                && output.trim().is_empty()
            {
                output
            } else {
                sanitized
            }
        });

        let mut state = self.by_item.get(&item_id).cloned().unwrap_or(FileChangeStreamState {
            item_id: item_id.clone(),
            invocation_id: invocation_id.clone(),
            args_json: None,
            latest_result_json: None,
            accumulated_output: String::new(),
            status: "running".to_string(),
        });
        if let Some(sanitized) = sanitized_output {
            state.accumulated_output =
                capped_running_output(&(state.accumulated_output.clone() + &sanitized));
        }
        state.status = "running".to_string();
        let result_json = apply_patch_running_result_json(
            state.latest_result_json.as_deref(),
            &state.accumulated_output,
            &state.status,
        );
        state.latest_result_json = Some(result_json.clone());
        let args_json = state.args_json.clone();
        let invocation = state.invocation_id.clone();
        self.by_item.insert(item_id.clone(), state);
        let dedup_key = tool_dedup_key(
            Some(&item_id),
            "apply_patch",
            args_json.as_deref(),
            Some(&result_json),
        );
        Some(ToolLifecycleEvent::Result {
            name: "apply_patch".to_string(),
            invocation_id: invocation,
            args_json,
            result_json,
            is_error: Some(false),
            dedup_key,
        })
    }
}

/// Combined leftover reducer: file-change stream + last running-update apply.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CodexLifecycleState {
    pub file_change: FileChangeLifecycleState,
}

impl CodexLifecycleState {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        self.file_change.reset();
    }

    pub fn apply_file_change(&mut self, method: &str, params_json: &str) -> Option<ToolLifecycleEvent> {
        let lower = method.to_ascii_lowercase();
        if looks_like_file_change_delta(&lower) {
            return self.file_change.apply_output_delta(params_json);
        }
        self.file_change.apply_lifecycle(method, params_json)
    }

    #[must_use]
    pub fn canonical(&self) -> String {
        let mut items = String::from("[");
        for (index, (id, state)) in self.file_change.by_item.iter().enumerate() {
            if index > 0 {
                items.push(',');
            }
            items.push_str(
                &Canonical::object()
                    .string("itemId", id)
                    .optional_string("invocationId", state.invocation_id.as_deref())
                    .optional_string("args", state.args_json.as_deref())
                    .string("status", &state.status)
                    .u64("accumulatedChars", state.accumulated_output.chars().count() as u64)
                    .finish(),
            );
        }
        items.push(']');
        let mut terminal = String::from("[");
        for (index, id) in self.file_change.terminal_item_ids.iter().enumerate() {
            if index > 0 {
                terminal.push(',');
            }
            terminal.push_str(&json_quoted(id));
        }
        terminal.push(']');
        Canonical::object()
            .raw("fileChangeItems", &items)
            .raw("terminalItemIds", &terminal)
            .finish()
    }
}

fn json_quoted(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandExecutionRunningUpdate {
    pub invocation_id: Option<String>,
    pub process_id: Option<String>,
    pub appended_output: Option<String>,
    pub seals_assistant_boundary: bool,
}

/// One bash transcript row for the running-update apply (Swift `AgentChatItem` subset).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BashItem {
    pub kind: String,
    pub tool_name: Option<String>,
    pub invocation_id: Option<String>,
    pub args_json: Option<String>,
    pub result_json: Option<String>,
    pub tool_is_error: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RunningIndex {
    invocation: BTreeMap<String, usize>,
    process: BTreeMap<String, usize>,
}

impl RunningIndex {
    fn build(items: &[BashItem]) -> Self {
        let mut invocation = BTreeMap::new();
        let mut process = BTreeMap::new();
        for (index, item) in items.iter().enumerate() {
            if normalized_external_tool_name(item.tool_name.as_deref()).as_deref() != Some("bash") {
                continue;
            }
            if let Some(id) = item.invocation_id.as_deref() {
                invocation.insert(id.to_string(), index);
            }
            if let Some(pid) = command_execution_process_id(item.result_json.as_deref()) {
                process.insert(pid, index);
            }
        }
        Self { invocation, process }
    }
}

/// `CodexNativeSessionController.applyCommandExecutionRunningUpdate`.
#[must_use]
pub fn apply_command_execution_running_update(
    update: &CommandExecutionRunningUpdate,
    items: &mut [BashItem],
) -> bool {
    let index = RunningIndex::build(items);
    let Some(target) = running_target(update, items, &index) else {
        return false;
    };
    let item = &mut items[target];
    if item.tool_is_error != Some(true) && command_execution_result_indicates_terminal(item.result_json.as_deref())
    {
        return false;
    }
    let mut did_change = false;
    if item.kind == "toolCall" {
        item.kind = "toolResult".to_string();
        did_change = true;
    }
    if item.tool_is_error != Some(false) {
        item.tool_is_error = Some(false);
        did_change = true;
    }
    if should_patch_running_payload(
        item.result_json.as_deref(),
        update.process_id.as_deref(),
        update.appended_output.as_deref(),
    ) {
        let patched = with_command_execution_running_status(
            item.result_json.as_deref(),
            update.process_id.as_deref(),
            update.appended_output.as_deref(),
        );
        if Some(patched.as_str()) != item.result_json.as_deref() {
            item.result_json = Some(patched);
            did_change = true;
        }
    }
    did_change
}

#[must_use]
pub fn parse_command_execution_running_update(
    method: &str,
    params_json: &str,
) -> Option<CommandExecutionRunningUpdate> {
    let params = parse_object(params_json)?;
    let lower = method.to_ascii_lowercase();
    if lower.contains("exec_command_output_delta")
        || lower.contains("commandexecution/outputdelta")
        || lower.contains("command_execution/output_delta")
    {
        return parse_exec_command_output_delta(&params);
    }
    parse_running_update_from_notification(&params, COMMAND_EXECUTION_OUTPUT_KEYS)
}

fn parse_exec_command_output_delta(params: &Map<String, Value>) -> Option<CommandExecutionRunningUpdate> {
    let message = params
        .get("msg")
        .and_then(Value::as_object)
        .unwrap_or(params);
    let call_id = string_value(message, &["call_id", "callId", "itemId", "item_id", "id"])?;
    let chunk = string_value(message, &["chunk"]);
    let output = decode_exec_chunk(chunk.as_deref())
        .or_else(|| string_value(message, &["delta", "output", "text", "message", "content"]));
    let sanitized = output.as_deref().map(sanitize_command_output);
    let trimmed = sanitized.as_deref().map(str::trim);
    Some(CommandExecutionRunningUpdate {
        invocation_id: stable_invocation_id(Some(&call_id)),
        process_id: string_value(message, &["process_id", "processId"]),
        appended_output: if trimmed.is_some_and(|value| !value.is_empty()) {
            sanitized
        } else {
            None
        },
        seals_assistant_boundary: false,
    })
}

fn parse_running_update_from_notification(
    params: &Map<String, Value>,
    output_keys: &[&str],
) -> Option<CommandExecutionRunningUpdate> {
    let mut invocation_id = None;
    let mut process_id = None;
    let mut output = None;
    let mut seals = false;
    for candidate in tool_item_candidates(params) {
        if invocation_id.is_none() {
            invocation_id = stable_invocation_id(string_value(
                &candidate,
                &[
                    "itemId",
                    "item_id",
                    "callId",
                    "call_id",
                    "id",
                    "invocationId",
                    "invocation_id",
                ],
            ).as_deref());
        }
        if process_id.is_none() {
            process_id = string_value(&candidate, &["processId", "process_id"]);
        }
        if output.is_none() {
            for key in output_keys {
                if let Some(raw) = string_value(&candidate, &[key]) {
                    let sanitized = sanitize_command_output(&raw);
                    if !sanitized.trim().is_empty() {
                        output = Some(sanitized);
                        break;
                    }
                }
            }
        }
        if let Some(stdin) = raw_string_value(&candidate, &["stdin"])
            && stdin.is_empty()
        {
            seals = true;
        }
    }
    if invocation_id.is_none() && process_id.as_ref().is_none_or(String::is_empty) {
        return None;
    }
    Some(CommandExecutionRunningUpdate {
        invocation_id,
        process_id,
        appended_output: output,
        seals_assistant_boundary: seals,
    })
}

fn decode_exec_chunk(chunk: Option<&str>) -> Option<String> {
    let chunk = chunk.filter(|value| !value.is_empty())?;
    let Ok(data) = decode_base64(chunk) else {
        return Some(chunk.to_string());
    };
    match String::from_utf8(data) {
        Ok(text) if !text.is_empty() => Some(text),
        _ => Some(chunk.to_string()),
    }
}

fn decode_base64(input: &str) -> Result<Vec<u8>, ()> {
    fn value(byte: u8) -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let filtered: Vec<u8> = input
        .bytes()
        .filter(|byte| !byte.is_ascii_whitespace() && *byte != b'=')
        .collect();
    if filtered.is_empty() || !filtered.iter().all(|byte| value(*byte).is_some()) {
        return Err(());
    }
    let mut output = Vec::new();
    for chunk in filtered.chunks(4) {
        let a = value(chunk[0]).ok_or(())?;
        let b = value(*chunk.get(1).unwrap_or(&b'A')).unwrap_or(0);
        output.push((a << 2) | (b >> 4));
        if chunk.len() > 2 {
            let c = value(chunk[2]).ok_or(())?;
            output.push(((b & 0x0F) << 4) | (c >> 2));
            if chunk.len() > 3 {
                let d = value(chunk[3]).ok_or(())?;
                output.push(((c & 0x03) << 6) | d);
            }
        }
    }
    Ok(output)
}

#[must_use]
pub fn with_command_execution_running_status(
    raw: Option<&str>,
    process_id: Option<&str>,
    append_output: Option<&str>,
) -> String {
    let mut object = parse_object(raw.unwrap_or("")).unwrap_or_default();
    seed_aggregated_output_if_needed(&mut object, raw);
    mark_running(&mut object, process_id);
    merge_aggregated_output(&mut object, append_output);
    serde_json::to_string(&Value::Object(object)).unwrap_or_else(|_| {
        raw.unwrap_or("{\"type\":\"commandExecution\",\"status\":\"running\"}")
            .to_string()
    })
}

fn seed_aggregated_output_if_needed(object: &mut Map<String, Value>, raw: Option<&str>) {
    if !object.is_empty() {
        return;
    }
    let Some(raw) = raw.map(str::trim).filter(|value| !value.is_empty()) else {
        return;
    };
    let sanitized = sanitize_command_output(raw);
    if sanitized.is_empty() {
        return;
    }
    object.insert("aggregatedOutput".to_string(), Value::String(sanitized));
}

fn mark_running(object: &mut Map<String, Value>, process_id: Option<&str>) {
    let type_value = dict_string(object, "type").filter(|value| !value.is_empty());
    object.insert(
        "type".to_string(),
        Value::String(type_value.unwrap_or_else(|| "commandExecution".to_string())),
    );
    object.insert("status".to_string(), Value::String("running".to_string()));
    object.remove("exitCode");
    object.remove("exit_code");
    object.remove("code");
    let existing = dict_string(object, "processId").or_else(|| dict_string(object, "process_id"));
    if let Some(pid) = process_id.map(str::trim).filter(|value| !value.is_empty()) {
        object.insert("processId".to_string(), Value::String(pid.to_string()));
    } else if let Some(existing) = existing.filter(|value| !value.is_empty()) {
        object.insert("processId".to_string(), Value::String(existing));
    }
    object.remove("process_id");
}

fn merge_aggregated_output(object: &mut Map<String, Value>, append_output: Option<&str>) {
    let mut aggregated = dict_string(object, "aggregatedOutput")
        .or_else(|| dict_string(object, "aggregated_output"))
        .or_else(|| output_text(object))
        .unwrap_or_default();
    if !aggregated.is_empty() && contains_control_or_escape(&aggregated) {
        aggregated = sanitize_command_output(&aggregated);
    }
    if let Some(append) = append_output.filter(|value| !value.is_empty()) {
        let sanitized = sanitize_command_output(append);
        if !sanitized.is_empty() {
            aggregated.push_str(&sanitized);
        }
    }
    if !aggregated.is_empty() {
        object.insert(
            "aggregatedOutput".to_string(),
            Value::String(capped_running_output(&aggregated)),
        );
    }
    object.remove("aggregated_output");
}

fn output_text(object: &Map<String, Value>) -> Option<String> {
    for key in COMMAND_EXECUTION_OUTPUT_KEYS {
        if let Some(value) = dict_string(object, key) {
            let sanitized = sanitize_command_output(&value);
            if !sanitized.trim().is_empty() {
                return Some(sanitized);
            }
        }
    }
    None
}

fn contains_control_or_escape(text: &str) -> bool {
    text.contains('\u{001B}') || text.contains('\u{009B}') || text.contains('\u{0008}') || text.contains('\r')
}

#[must_use]
pub fn sanitize_command_output(raw: &str) -> String {
    if raw.is_empty() || !requires_sanitization(raw) {
        return raw.to_string();
    }
    let mut text = raw.replace("\r\n", "\n");
    text = strip_escape_sequences(&text);
    text = apply_backspaces(&text);
    text = apply_carriage_return_overwrite(&text);
    strip_unwanted_control_scalars(&text)
}

fn requires_sanitization(input: &str) -> bool {
    input.chars().any(|ch| match ch as u32 {
        0x1B | 0x9B | 0x08 | 0x0D => true,
        0x00..=0x1F if ch != '\t' && ch != '\n' => true,
        _ => false,
    })
}

fn strip_escape_sequences(input: &str) -> String {
    if !input.contains('\u{001B}') && !input.contains('\u{009B}') {
        return input.to_string();
    }
    let bytes = input.as_bytes();
    let mut output = String::new();
    let mut i = 0;
    while i < bytes.len() {
        let byte = bytes[i];
        if byte == 0x9B {
            i = skip_csi_params(bytes, i + 1);
            continue;
        }
        if byte == 0x1B {
            if i + 1 < bytes.len() && bytes[i + 1] == b'[' {
                i = skip_csi_params(bytes, i + 2);
                continue;
            }
            if i + 1 < bytes.len() && bytes[i + 1] == b']' {
                i = skip_until_bel_or_st(bytes, i + 2);
                continue;
            }
            if i + 1 < bytes.len() && matches!(bytes[i + 1], b'P' | b'^' | b'_' | b'X') {
                i = skip_until_st(bytes, i + 2);
                continue;
            }
            if i + 1 < bytes.len() && matches!(bytes[i + 1], b'@'..=b'Z' | b'\\' | b'-' | b'_') {
                i += 2;
                continue;
            }
        }
        let ch = input[i..].chars().next().unwrap_or('\u{FFFD}');
        output.push(ch);
        i += ch.len_utf8();
    }
    output
}

fn skip_csi_params(bytes: &[u8], mut i: usize) -> usize {
    while i < bytes.len() && (0x30..=0x3F).contains(&bytes[i]) {
        i += 1;
    }
    while i < bytes.len() && (0x20..=0x2F).contains(&bytes[i]) {
        i += 1;
    }
    if i < bytes.len() && (0x40..=0x7E).contains(&bytes[i]) {
        i += 1;
    }
    i
}

fn skip_until_bel_or_st(bytes: &[u8], mut i: usize) -> usize {
    while i < bytes.len() {
        if bytes[i] == 0x07 {
            return i + 1;
        }
        if bytes[i] == 0x1B && i + 1 < bytes.len() && bytes[i + 1] == b'\\' {
            return i + 2;
        }
        i += 1;
    }
    i
}

fn skip_until_st(bytes: &[u8], mut i: usize) -> usize {
    while i < bytes.len() {
        if bytes[i] == 0x1B && i + 1 < bytes.len() && bytes[i + 1] == b'\\' {
            return i + 2;
        }
        i += 1;
    }
    i
}

fn apply_backspaces(input: &str) -> String {
    if !input.contains('\u{0008}') {
        return input.to_string();
    }
    let mut output = String::new();
    for ch in input.chars() {
        if ch == '\u{0008}' {
            output.pop();
        } else {
            output.push(ch);
        }
    }
    output
}

fn apply_carriage_return_overwrite(input: &str) -> String {
    if !input.contains('\r') {
        return input.to_string();
    }
    input
        .split('\n')
        .map(|line| line.rsplit('\r').next().unwrap_or("").to_string())
        .collect::<Vec<_>>()
        .join("\n")
}

fn strip_unwanted_control_scalars(input: &str) -> String {
    input
        .chars()
        .filter(|ch| matches!(*ch as u32, 0x09 | 0x0A | 0x20..=0x10_FFFF))
        .collect()
}

fn capped_running_output(raw: &str) -> String {
    let count = raw.chars().count();
    if count <= MAX_RUNNING_AGGREGATED_OUTPUT_CHARACTERS {
        return raw.to_string();
    }
    let skip = count - MAX_RUNNING_AGGREGATED_OUTPUT_CHARACTERS;
    let suffix: String = raw.chars().skip(skip).collect();
    if suffix.starts_with(RUNNING_OUTPUT_TRUNCATION_MARKER) {
        suffix
    } else {
        format!("{RUNNING_OUTPUT_TRUNCATION_MARKER}{suffix}")
    }
}

fn running_target(
    update: &CommandExecutionRunningUpdate,
    items: &[BashItem],
    index: &RunningIndex,
) -> Option<usize> {
    if let Some(id) = update.invocation_id.as_deref()
        && let Some(&at) = index.invocation.get(id)
        && is_bash_item(items, at)
    {
        return Some(at);
    }
    if let Some(pid) = update.process_id.as_deref()
        && let Some(&at) = index.process.get(pid)
        && is_bash_item(items, at)
    {
        return Some(at);
    }
    let requires_correlation = update.invocation_id.is_some()
        || update.process_id.as_ref().is_some_and(|value| !value.is_empty());
    if let Some(at) = unique_fallback(items, requires_correlation) {
        return Some(at);
    }
    if let Some(id) = update.invocation_id.as_deref() {
        if let Some(at) = items.iter().rposition(|item| {
            item.invocation_id.as_deref() == Some(id)
                && normalized_external_tool_name(item.tool_name.as_deref()).as_deref() == Some("bash")
        }) {
            return Some(at);
        }
    }
    if let Some(pid) = update.process_id.as_deref() {
        if let Some(at) = items.iter().rposition(|item| {
            normalized_external_tool_name(item.tool_name.as_deref()).as_deref() == Some("bash")
                && command_execution_process_id(item.result_json.as_deref()).as_deref() == Some(pid)
        }) {
            return Some(at);
        }
    }
    unique_fallback(items, requires_correlation)
}

fn is_bash_item(items: &[BashItem], index: usize) -> bool {
    items
        .get(index)
        .is_some_and(|item| normalized_external_tool_name(item.tool_name.as_deref()).as_deref() == Some("bash"))
}

fn unique_fallback(items: &[BashItem], require_correlation_for_error: bool) -> Option<usize> {
    let mut resolved = None;
    for (index, item) in items.iter().enumerate() {
        if !is_fallback_eligible(item, require_correlation_for_error) {
            continue;
        }
        if resolved.is_some() {
            return None;
        }
        resolved = Some(index);
    }
    resolved
}

fn is_fallback_eligible(item: &BashItem, require_correlation_for_error: bool) -> bool {
    if normalized_external_tool_name(item.tool_name.as_deref()).as_deref() != Some("bash") {
        return false;
    }
    if item.tool_is_error == Some(true) {
        return require_correlation_for_error;
    }
    !command_execution_result_indicates_terminal(item.result_json.as_deref())
}

fn should_patch_running_payload(raw: Option<&str>, process_id: Option<&str>, append: Option<&str>) -> bool {
    if append.is_some_and(|value| !value.is_empty()) {
        return true;
    }
    let Some(object) = parse_object(raw.unwrap_or("")) else {
        return true;
    };
    if !command_execution_object_is_command_like(&object) {
        return true;
    }
    if object.contains_key("process_id")
        || object.contains_key("aggregated_output")
        || object.contains_key("exit_code")
        || object.contains_key("code")
    {
        return true;
    }
    if command_execution_exit_code(&object).is_some() {
        return true;
    }
    let existing = dict_string(&object, "processId").or_else(|| dict_string(&object, "process_id"));
    if let Some(pid) = process_id.map(str::trim).filter(|value| !value.is_empty())
        && existing.as_deref() != Some(pid)
    {
        return true;
    }
    match command_execution_status_word(&object) {
        None => true,
        Some(status) => !RUNNING_STATUS_WORDS.contains(&status.as_str()),
    }
}

fn command_execution_result_indicates_terminal(raw: Option<&str>) -> bool {
    let Some(object) = parse_object(raw.unwrap_or("")) else {
        return false;
    };
    let exit = command_execution_exit_code(&object);
    let process_id = command_execution_process_id(raw);
    if let Some(code) = exit {
        if code >= 0 {
            return true;
        }
        return process_id.is_none();
    }
    if let Some(status) = command_execution_status_word(&object) {
        if RUNNING_STATUS_WORDS.contains(&status.as_str()) {
            return false;
        }
        if TERMINAL_STATUS_WORDS.contains(&status.as_str()) {
            return true;
        }
    }
    if dict_bool(&object, "success") == Some(true) || dict_bool(&object, "ok") == Some(true) {
        return true;
    }
    dict_string(&object, "error")
        .is_some_and(|value| !value.trim().is_empty())
}

fn command_execution_object_is_command_like(object: &Map<String, Value>) -> bool {
    dict_string(object, "type")
        .unwrap_or_default()
        .to_ascii_lowercase()
        .contains("command")
}

fn command_execution_exit_code(object: &Map<String, Value>) -> Option<i64> {
    object
        .get("exitCode")
        .or_else(|| object.get("exit_code"))
        .or_else(|| object.get("code"))
        .and_then(int_value)
}

fn command_execution_status_word(object: &Map<String, Value>) -> Option<String> {
    dict_string(object, "status").map(|value| value.trim().to_ascii_lowercase())
}

fn command_execution_process_id(raw: Option<&str>) -> Option<String> {
    let object = parse_object(raw?)?;
    for key in ["processId", "process_id"] {
        if let Some(value) = dict_string(&object, key).filter(|value| !value.is_empty()) {
            return Some(value);
        }
        if let Some(number) = object.get(key).and_then(int_value) {
            return Some(number.to_string());
        }
    }
    None
}

fn apply_patch_args_json(candidate: &Map<String, Value>) -> Option<String> {
    let changes = apply_patch_change_payloads(candidate);
    let mut seen = BTreeSet::new();
    let paths: Vec<String> = changes
        .iter()
        .filter_map(|change| change.get("path").and_then(Value::as_str))
        .filter(|path| !path.is_empty() && seen.insert((*path).to_string()))
        .map(ToString::to_string)
        .collect();
    if paths.is_empty() && changes.is_empty() {
        return None;
    }
    let mut payload = Map::new();
    payload.insert(
        "change_count".to_string(),
        json!(changes.len().max(paths.len())),
    );
    if let Some(first) = paths.first() {
        payload.insert("path".to_string(), json!(first));
    }
    if paths.len() > 1 {
        payload.insert("paths".to_string(), json!(paths));
    }
    serialize_json(&Value::Object(payload))
}

fn apply_patch_result_json(candidate: &Map<String, Value>, accumulated: Option<&str>) -> String {
    let changes = apply_patch_change_payloads(candidate);
    let status = normalized_apply_patch_status(string_value(candidate, &["status"]).as_deref(), false);
    let mut payload = Map::new();
    payload.insert("status".to_string(), json!(status.status));
    payload.insert("changes".to_string(), Value::Array(changes.clone()));
    payload.insert("change_count".to_string(), json!(changes.len()));
    payload.insert("summary_only".to_string(), json!(false));
    if let Some(output) = accumulated.filter(|value| !value.is_empty()) {
        payload.insert("output".to_string(), json!(output));
    }
    serialize_json(&Value::Object(payload)).unwrap_or_else(|| {
        format!(
            "{{\"status\":\"{}\",\"changes\":[],\"change_count\":0}}",
            status.status
        )
    })
}

fn apply_patch_running_result_json(raw: Option<&str>, accumulated: &str, status: &str) -> String {
    let mut object = parse_object(raw.unwrap_or("")).unwrap_or_default();
    object.insert("status".to_string(), json!(status));
    object.insert("summary_only".to_string(), json!(false));
    if !object.contains_key("changes") {
        object.insert("changes".to_string(), json!([]));
    }
    if !object.contains_key("change_count") {
        let count = object
            .get("changes")
            .and_then(Value::as_array)
            .map(Vec::len)
            .unwrap_or(0);
        object.insert("change_count".to_string(), json!(count));
    }
    if !accumulated.is_empty() {
        object.insert("output".to_string(), json!(accumulated));
    }
    serialize_json(&Value::Object(object))
        .unwrap_or_else(|| "{\"status\":\"running\",\"changes\":[],\"change_count\":0}".to_string())
}

fn apply_patch_change_payloads(candidate: &Map<String, Value>) -> Vec<Value> {
    let Some(raw) = candidate.get("changes").and_then(Value::as_array) else {
        return Vec::new();
    };
    raw.iter()
        .filter_map(|change| {
            let change = change.as_object()?;
            let path = string_value(change, &["path"])?;
            let diff = raw_string_value(change, &["diff"])?;
            let (kind, move_path) = normalized_apply_patch_kind(change.get("kind"));
            let mut payload = Map::new();
            payload.insert("path".to_string(), json!(path));
            payload.insert("kind".to_string(), json!(kind));
            payload.insert("diff".to_string(), json!(diff));
            if let Some(move_path) = move_path.filter(|value| !value.is_empty()) {
                payload.insert("move_path".to_string(), json!(move_path));
            }
            Some(Value::Object(payload))
        })
        .collect()
}

fn normalized_apply_patch_kind(raw: Option<&Value>) -> (String, Option<String>) {
    match raw {
        Some(Value::String(text)) => (text.trim().to_ascii_lowercase(), None),
        Some(Value::Object(object)) => {
            let kind = first_string(object, &["type"])
                .map(|value| value.to_ascii_lowercase())
                .unwrap_or_else(|| "update".to_string());
            let move_path = first_string(object, &["movePath", "move_path"]);
            (kind, move_path)
        }
        _ => ("update".to_string(), None),
    }
}

struct StatusInfo {
    status: String,
    is_error: Option<bool>,
}

fn normalized_apply_patch_status(raw: Option<&str>, is_completed: bool) -> StatusInfo {
    let normalized = raw.unwrap_or("").trim().to_ascii_lowercase();
    match normalized.as_str() {
        "inprogress" | "in_progress" | "running" | "pending" => {
            if is_completed {
                StatusInfo {
                    status: "success".to_string(),
                    is_error: Some(false),
                }
            } else {
                StatusInfo {
                    status: "running".to_string(),
                    is_error: Some(false),
                }
            }
        }
        "completed" | "success" | "succeeded" | "ok" => StatusInfo {
            status: "success".to_string(),
            is_error: Some(false),
        },
        "declined" | "rejected" => StatusInfo {
            status: "declined".to_string(),
            is_error: Some(true),
        },
        "cancelled" | "canceled" | "interrupted" | "stopped" | "terminated" => StatusInfo {
            status: "cancelled".to_string(),
            is_error: Some(true),
        },
        "failed" | "failure" | "error" => StatusInfo {
            status: "failed".to_string(),
            is_error: Some(true),
        },
        "" if is_completed => StatusInfo {
            status: "success".to_string(),
            is_error: Some(false),
        },
        "" => StatusInfo {
            status: "running".to_string(),
            is_error: None,
        },
        other => StatusInfo {
            status: other.to_string(),
            is_error: None,
        },
    }
}

fn tool_item_candidates(params: &Map<String, Value>) -> Vec<Map<String, Value>> {
    let mut candidates = Vec::new();
    if let Some(item) = params.get("item").and_then(Value::as_object) {
        candidates.push(item.clone());
    }
    for key in ["msg", "payload", "event"] {
        if let Some(envelope) = params.get(key).and_then(Value::as_object) {
            if let Some(item) = envelope.get("item").and_then(Value::as_object) {
                candidates.push(item.clone());
            }
            candidates.push(envelope.clone());
        }
    }
    candidates.push(params.clone());
    candidates
}

fn candidate_looks_like_file_change(candidate: &Map<String, Value>) -> bool {
    let type_raw = string_value(candidate, &["type", "itemType", "item_type"])
        .unwrap_or_default()
        .to_ascii_lowercase();
    type_raw.contains("filechange") || type_raw.contains("file_change")
}

fn looks_like_file_change_delta(method: &str) -> bool {
    method.contains("file_change/output")
        || method.contains("filechange/output")
        || method.contains("item_file_change_output")
        || method.contains("file_change_output")
}

fn normalized_external_tool_name(raw: Option<&str>) -> Option<String> {
    let trimmed = raw?.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lowered = trimmed.to_ascii_lowercase();
    let suffix = lowered.rsplit('.').next().unwrap_or(&lowered);
    Some(match suffix {
        "local_shell" | "shell" | "unified_exec" | "exec_command" | "run_shell_command" | "bash" => {
            "bash".to_string()
        }
        "filechange" | "file_change" | "apply_patch" => "apply_patch".to_string(),
        other => other.to_string(),
    })
}

fn tool_dedup_key(
    item_id: Option<&str>,
    tool_name: &str,
    args_json: Option<&str>,
    result_json: Option<&str>,
) -> String {
    if let Some(item_id) = item_id.map(str::trim).filter(|value| !value.is_empty()) {
        return item_id.to_string();
    }
    format!(
        "{}|{}|{}",
        tool_name,
        args_json.unwrap_or(""),
        result_json.unwrap_or("")
    )
}

#[must_use]
pub fn stable_invocation_id(raw_item_id: Option<&str>) -> Option<String> {
    let raw = raw_item_id.map(str::trim).filter(|value| !value.is_empty())?;
    if is_hyphenated_uuid(raw) {
        return Some(raw.to_ascii_uppercase());
    }
    let mut hash_a: u64 = 0xCBF2_9CE4_8422_2325;
    let mut hash_b: u64 = 0x9E37_79B9_7F4A_7C15;
    for (index, byte) in raw.as_bytes().iter().copied().enumerate() {
        hash_a ^= u64::from(byte);
        hash_a = hash_a.wrapping_mul(0x100_0000_01B3);
        hash_b ^= u64::from(byte).wrapping_add(u64::from((index & 0xFF) as u8));
        hash_b = hash_b.wrapping_mul(0x100_0000_01B3);
        hash_b = hash_b.rotate_left(13);
    }
    let mut bytes = [0u8; 16];
    bytes[..8].copy_from_slice(&hash_a.to_be_bytes());
    bytes[8..].copy_from_slice(&hash_b.to_be_bytes());
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    Some(format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

fn is_hyphenated_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 36 {
        return false;
    }
    for (index, byte) in bytes.iter().enumerate() {
        if matches!(index, 8 | 13 | 18 | 23) {
            if *byte != b'-' {
                return false;
            }
        } else if !byte.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

fn string_value(object: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(Value::String(text)) = object.get(*key)
            && !text.is_empty()
        {
            return Some(text.clone());
        }
    }
    None
}

fn raw_string_value(object: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(Value::String(text)) = object.get(*key) {
            return Some(text.clone());
        }
    }
    None
}

fn dict_string(object: &Map<String, Value>, key: &str) -> Option<String> {
    match object.get(key) {
        Some(Value::String(text)) => Some(text.clone()),
        Some(Value::Number(number)) => Some(number.to_string()),
        _ => None,
    }
}

fn dict_bool(object: &Map<String, Value>, key: &str) -> Option<bool> {
    match object.get(key) {
        Some(Value::Bool(value)) => Some(*value),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_change_started_then_delta_then_completed() {
        let mut state = FileChangeLifecycleState::new();
        let started = state
            .apply_lifecycle(
                "item/started",
                r#"{"item":{"id":"fc-1","type":"fileChange","status":"in_progress","changes":[{"path":"a.rs","diff":"+x","kind":"update"}]}}"#,
            )
            .expect("started");
        assert_eq!(started.name(), "apply_patch");
        assert!(matches!(started, ToolLifecycleEvent::Call { .. }));
        let delta = state
            .apply_output_delta(r#"{"itemId":"fc-1","delta":"chunk"}"#)
            .expect("delta");
        assert!(delta.result_json().unwrap().contains("chunk"));
        let done = state
            .apply_lifecycle(
                "item/completed",
                r#"{"item":{"id":"fc-1","type":"fileChange","status":"completed","changes":[{"path":"a.rs","diff":"+x","kind":"update"}]}}"#,
            )
            .expect("completed");
        assert_eq!(done.is_error(), Some(false));
        assert!(state.apply_output_delta(r#"{"itemId":"fc-1","delta":"late"}"#).is_none());
    }

    #[test]
    fn running_update_patches_unique_bash_item() {
        let mut items = [BashItem {
            kind: "toolCall".to_string(),
            tool_name: Some("bash".to_string()),
            invocation_id: Some("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA".to_string()),
            args_json: Some(r#"{"command":"ls"}"#.to_string()),
            result_json: None,
            tool_is_error: None,
        }];
        let update = CommandExecutionRunningUpdate {
            invocation_id: items[0].invocation_id.clone(),
            process_id: Some("12".to_string()),
            appended_output: Some("hello".to_string()),
            seals_assistant_boundary: false,
        };
        assert!(apply_command_execution_running_update(&update, &mut items));
        assert_eq!(items[0].kind, "toolResult");
        let body = items[0].result_json.as_deref().unwrap();
        assert!(body.contains("\"status\":\"running\""));
        assert!(body.contains("hello"));
    }

    #[test]
    fn sanitize_strips_csi_and_applies_backspace() {
        assert_eq!(sanitize_command_output("ab\u{0008}c"), "ac");
        assert_eq!(sanitize_command_output("\u{001B}[31mred\u{001B}[0m"), "red");
    }

    #[test]
    fn stable_invocation_id_parses_uuid_and_hashes_call_ids() {
        assert_eq!(
            stable_invocation_id(Some("0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081")).as_deref(),
            Some("0193A4B2-7C3E-7F10-8A2B-9C4D5E6F7081")
        );
        let hashed = stable_invocation_id(Some("call_abc")).unwrap();
        assert_eq!(hashed.len(), 36);
        assert_eq!(&hashed[14..15], "5");
    }
}
