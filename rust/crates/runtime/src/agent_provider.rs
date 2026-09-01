//! P7 provider runtime authority for Codex app-server, ACP, and Claude headless.
//!
//! ACP and Codex share the provider-neutral JSON-RPC reducer in `provider_json_rpc`.

//! Codex app-server and ACP providers intentionally share one process/transport ownership
//! boundary. Rust owns JSON-RPC correlation, pending requests, timeout/error classification,
//! notification and server request classification, and lifecycle projection for both protocols;
//! Swift receives typed notifications and server requests rather than reparsing opaque provider
//! lines, while Claude headless retains its Rust stream translator. All variants share spawn attributes,
//! line framing, bounded stderr/event publication, serialized stdin writes, monotonically
//! sequenced observations, cancellation, and process reaping. Malformed provider output remains
//! observable without panicking the authority.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{Read, Write};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use serde_json::{Value, json};

use crate::agent_claude::framer::LineFramer;
use crate::agent_claude::process::{self, ReapOutcome, Reaper, SpawnConfig};
use crate::agent_claude::translator::{
    Translator, should_suppress_user_facing_stream_result, stream_result_wire_fields,
};
use crate::{EventClass, EventInput, RuntimeEventKind, RuntimeIdentity, ScopeId, SubscriptionHub};

#[path = "provider_json_rpc.rs"]
mod provider_json_rpc;
use provider_json_rpc::{JsonRpcCompletion, JsonRpcId, JsonRpcState, settle_pending};

/// Preserve the legacy headless provider's bounded one-shot lifetime while keeping the timeout
/// decision in the Rust process authority. Codex/ACP scopes remain effectively unbounded here;
/// their protocol controllers own their existing request deadlines.
const CLAUDE_HEADLESS_TIMEOUT: Duration = Duration::from_secs(6_000);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProviderProtocol {
    CodexAppServer,
    Acp,
    /// Claude Code's headless `-p --output-format stream-json` mode. Unlike the
    /// generic protocols, Rust owns NDJSON translation for this variant so the
    /// Swift headless adapter never reparses provider bytes.
    ClaudeHeadless,
}

impl ProviderProtocol {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CodexAppServer => "codexAppServer",
            Self::Acp => "acp",
            Self::ClaudeHeadless => "claudeHeadless",
        }
    }
}

/// Version of the offline provider conformance report. This is deliberately separate from the
/// transport/event payload schemas: changing it is an additive diagnostic contract decision.
pub const AGENT_PROVIDER_CONFORMANCE_SCHEMA_VERSION: u16 = 1;

/// Stable, provider-neutral capability profile used by P7-4 certification. The profile describes
/// existing production ownership boundaries; creating or validating one never starts a process,
/// allocates a request, publishes an event, or consults credentials/network state.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AgentProviderConformanceSnapshot {
    pub schema_version: u16,
    pub protocol: ProviderProtocol,
    pub owns_process_lifetime: bool,
    pub owns_line_framing: bool,
    pub serializes_stdin_writes: bool,
    pub emits_ordered_events: bool,
    pub bounds_stderr: bool,
    pub emits_process_exit_terminal_event: bool,
    pub supports_semantic_requests: bool,
    pub supports_typed_notifications: bool,
    pub supports_typed_server_requests: bool,
    pub supports_typed_state: bool,
    pub supports_token_cancellation: bool,
    pub supports_typed_control_receipts: bool,
    pub preserves_json_rpc_id_type: bool,
    pub supports_generic_send_line: bool,
    pub supports_start_with_stdin: bool,
    pub translates_stream_results: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentProviderConformanceViolation {
    SchemaVersionMismatch,
    ProtocolProfileMismatch,
    ProcessLifetimeMismatch,
    FramingMismatch,
    SerializedWritesMismatch,
    OrderedEventsMismatch,
    StderrBoundMismatch,
    ProcessExitEventMismatch,
    SemanticRequestsMismatch,
    TypedNotificationsMismatch,
    TypedServerRequestsMismatch,
    TypedStateMismatch,
    TokenCancellationMismatch,
    TypedControlReceiptsMismatch,
    JsonRpcIdTypePreservationMismatch,
    GenericSendLineMismatch,
    StartWithStdinMismatch,
    StreamResultTranslationMismatch,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProviderConformanceValidation {
    pub schema_version: u16,
    pub protocol: ProviderProtocol,
    pub valid: bool,
    pub violations: Vec<AgentProviderConformanceViolation>,
}

/// Return the canonical P7-4 ownership profile for one provider protocol.
pub fn agent_provider_conformance_snapshot(
    protocol: ProviderProtocol,
) -> AgentProviderConformanceSnapshot {
    let common = (
        true, // owns_process_lifetime
        true, // owns_line_framing
        true, // serializes_stdin_writes
        true, // emits_ordered_events
        true, // bounds_stderr
        true, // emits_process_exit_terminal_event
    );
    match protocol {
        ProviderProtocol::CodexAppServer => AgentProviderConformanceSnapshot {
            schema_version: AGENT_PROVIDER_CONFORMANCE_SCHEMA_VERSION,
            protocol,
            owns_process_lifetime: common.0,
            owns_line_framing: common.1,
            serializes_stdin_writes: common.2,
            emits_ordered_events: common.3,
            bounds_stderr: common.4,
            emits_process_exit_terminal_event: common.5,
            supports_semantic_requests: true,
            supports_typed_notifications: true,
            supports_typed_server_requests: true,
            supports_typed_state: true,
            supports_token_cancellation: true,
            supports_typed_control_receipts: false,
            preserves_json_rpc_id_type: true,
            supports_generic_send_line: false,
            supports_start_with_stdin: false,
            translates_stream_results: false,
        },
        ProviderProtocol::Acp => AgentProviderConformanceSnapshot {
            schema_version: AGENT_PROVIDER_CONFORMANCE_SCHEMA_VERSION,
            protocol,
            owns_process_lifetime: common.0,
            owns_line_framing: common.1,
            serializes_stdin_writes: common.2,
            emits_ordered_events: common.3,
            bounds_stderr: common.4,
            emits_process_exit_terminal_event: common.5,
            supports_semantic_requests: true,
            supports_typed_notifications: true,
            supports_typed_server_requests: true,
            supports_typed_state: true,
            supports_token_cancellation: true,
            supports_typed_control_receipts: true,
            preserves_json_rpc_id_type: true,
            supports_generic_send_line: false,
            supports_start_with_stdin: false,
            translates_stream_results: false,
        },
        ProviderProtocol::ClaudeHeadless => AgentProviderConformanceSnapshot {
            schema_version: AGENT_PROVIDER_CONFORMANCE_SCHEMA_VERSION,
            protocol,
            owns_process_lifetime: common.0,
            owns_line_framing: common.1,
            serializes_stdin_writes: common.2,
            emits_ordered_events: common.3,
            bounds_stderr: common.4,
            emits_process_exit_terminal_event: common.5,
            supports_semantic_requests: false,
            supports_typed_notifications: false,
            supports_typed_server_requests: false,
            supports_typed_state: false,
            supports_token_cancellation: false,
            supports_typed_control_receipts: false,
            preserves_json_rpc_id_type: false,
            supports_generic_send_line: true,
            supports_start_with_stdin: true,
            translates_stream_results: true,
        },
    }
}

/// Validate a report against the canonical profile in deterministic field order.
pub fn validate_agent_provider_conformance(
    snapshot: &AgentProviderConformanceSnapshot,
) -> AgentProviderConformanceValidation {
    let expected = agent_provider_conformance_snapshot(snapshot.protocol);
    let mut violations = Vec::new();
    if snapshot.schema_version != AGENT_PROVIDER_CONFORMANCE_SCHEMA_VERSION {
        violations.push(AgentProviderConformanceViolation::SchemaVersionMismatch);
    }
    if snapshot.protocol != expected.protocol {
        violations.push(AgentProviderConformanceViolation::ProtocolProfileMismatch);
    }
    if snapshot.owns_process_lifetime != expected.owns_process_lifetime {
        violations.push(AgentProviderConformanceViolation::ProcessLifetimeMismatch);
    }
    if snapshot.owns_line_framing != expected.owns_line_framing {
        violations.push(AgentProviderConformanceViolation::FramingMismatch);
    }
    if snapshot.serializes_stdin_writes != expected.serializes_stdin_writes {
        violations.push(AgentProviderConformanceViolation::SerializedWritesMismatch);
    }
    if snapshot.emits_ordered_events != expected.emits_ordered_events {
        violations.push(AgentProviderConformanceViolation::OrderedEventsMismatch);
    }
    if snapshot.bounds_stderr != expected.bounds_stderr {
        violations.push(AgentProviderConformanceViolation::StderrBoundMismatch);
    }
    if snapshot.emits_process_exit_terminal_event != expected.emits_process_exit_terminal_event {
        violations.push(AgentProviderConformanceViolation::ProcessExitEventMismatch);
    }
    if snapshot.supports_semantic_requests != expected.supports_semantic_requests {
        violations.push(AgentProviderConformanceViolation::SemanticRequestsMismatch);
    }
    if snapshot.supports_typed_notifications != expected.supports_typed_notifications {
        violations.push(AgentProviderConformanceViolation::TypedNotificationsMismatch);
    }
    if snapshot.supports_typed_server_requests != expected.supports_typed_server_requests {
        violations.push(AgentProviderConformanceViolation::TypedServerRequestsMismatch);
    }
    if snapshot.supports_typed_state != expected.supports_typed_state {
        violations.push(AgentProviderConformanceViolation::TypedStateMismatch);
    }
    if snapshot.supports_token_cancellation != expected.supports_token_cancellation {
        violations.push(AgentProviderConformanceViolation::TokenCancellationMismatch);
    }
    if snapshot.supports_typed_control_receipts != expected.supports_typed_control_receipts {
        violations.push(AgentProviderConformanceViolation::TypedControlReceiptsMismatch);
    }
    if snapshot.preserves_json_rpc_id_type != expected.preserves_json_rpc_id_type {
        violations.push(AgentProviderConformanceViolation::JsonRpcIdTypePreservationMismatch);
    }
    if snapshot.supports_generic_send_line != expected.supports_generic_send_line {
        violations.push(AgentProviderConformanceViolation::GenericSendLineMismatch);
    }
    if snapshot.supports_start_with_stdin != expected.supports_start_with_stdin {
        violations.push(AgentProviderConformanceViolation::StartWithStdinMismatch);
    }
    if snapshot.translates_stream_results != expected.translates_stream_results {
        violations.push(AgentProviderConformanceViolation::StreamResultTranslationMismatch);
    }
    AgentProviderConformanceValidation {
        schema_version: snapshot.schema_version,
        protocol: snapshot.protocol,
        valid: violations.is_empty(),
        violations,
    }
}

#[derive(Clone, Debug)]
pub struct AgentProviderScopeConfig {
    pub command: String,
    pub arguments: Vec<String>,
    pub environment: Vec<(String, String)>,
    pub working_directory: Option<String>,
    pub protocol: ProviderProtocol,
    pub max_stderr_bytes: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StartReceipt {
    pub pid: i32,
    pub process_group_id: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentProviderScopeError {
    IdentityMismatch,
    ScopeClosed,
    AlreadyRunning,
    NotRunning,
    Spawn(String),
    Reaper(String),
    TransportWrite(String),
    CodexProtocolMismatch,
    CodexInvalidJSON,
    CodexTimedOut(String),
    CodexCancelled(String),
    CodexRemoteError {
        method: String,
        code: i64,
        message: String,
        data: Option<Vec<u8>>,
    },
    CodexInvalidResponse,
    AcpProtocolMismatch,
    AcpInvalidJSON,
    AcpTimedOut(String),
    AcpCancelled(String),
    AcpRemoteError {
        method: String,
        code: i64,
        message: String,
        data: Option<Vec<u8>>,
    },
    AcpInvalidResponse,
    InvalidArgument(&'static str),
}

impl std::fmt::Display for AgentProviderScopeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::IdentityMismatch => f.write_str("runtime identity mismatch"),
            Self::ScopeClosed => f.write_str("agent provider scope is closed"),
            Self::AlreadyRunning => {
                f.write_str("agent provider scope already has a running process")
            }
            Self::NotRunning => f.write_str("agent provider scope has no running process"),
            Self::Spawn(message) => write!(f, "agent provider spawn failed: {message}"),
            Self::Reaper(message) => {
                write!(f, "agent provider reaper registration failed: {message}")
            }
            Self::TransportWrite(message) => {
                write!(f, "agent provider transport write failed: {message}")
            }
            Self::CodexProtocolMismatch => {
                f.write_str("codex app-server protocol is unavailable for this scope")
            }
            Self::CodexInvalidJSON => f.write_str("codex app-server returned invalid JSON"),
            Self::CodexTimedOut(method) => {
                write!(f, "codex app-server request timed out: {method}")
            }
            Self::CodexCancelled(method) => {
                write!(f, "codex app-server request cancelled: {method}")
            }
            Self::CodexRemoteError {
                method,
                code,
                message,
                ..
            } => {
                write!(
                    f,
                    "codex app-server request failed ({method}, {code}): {message}"
                )
            }
            Self::CodexInvalidResponse => {
                f.write_str("codex app-server returned an invalid response")
            }
            Self::AcpProtocolMismatch => f.write_str("acp protocol is unavailable for this scope"),
            Self::AcpInvalidJSON => f.write_str("acp returned invalid JSON"),
            Self::AcpTimedOut(method) => write!(f, "acp request timed out: {method}"),
            Self::AcpCancelled(method) => write!(f, "acp request cancelled: {method}"),
            Self::AcpRemoteError {
                method,
                code,
                message,
                ..
            } => {
                write!(f, "acp request failed ({method}, {code}): {message}")
            }
            Self::AcpInvalidResponse => f.write_str("acp returned an invalid response"),
            Self::InvalidArgument(what) => write!(f, "invalid agent provider argument: {what}"),
        }
    }
}

impl std::error::Error for AgentProviderScopeError {}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum ScopeRegistryError {
    IdentityMismatch,
    UnknownScope,
}

struct RunningProcess {
    pid: i32,
    reaper_token: u64,
    stdin: Option<Arc<Mutex<File>>>,
}

struct ScopeState {
    closed: bool,
    next_sequence: u64,
    process: Option<RunningProcess>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexSessionState {
    pub lifecycle: String,
    pub initialized: bool,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub pending_request_count: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcpSessionState {
    pub lifecycle: String,
    pub initialized: bool,
    pub authenticated: bool,
    pub session_id: Option<String>,
    pub session_generation: u64,
    pub prompt_generation: u64,
    pub active_prompt_generation: Option<u64>,
    pub pending_request_count: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcpControlReceipt {
    pub outbound_sequence: u64,
    pub lifecycle: String,
    pub session_generation: u64,
    pub prompt_generation: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcpResponse {
    pub result: Vec<u8>,
    pub inbound_sequence: u64,
    pub outbound_sequence: u64,
    pub lifecycle: String,
    pub session_generation: u64,
    pub prompt_generation: Option<u64>,
}

struct CodexPending {
    method: String,
    cancellation_token: Option<String>,
    result: Arc<(
        Mutex<Option<Result<Value, AgentProviderScopeError>>>,
        Condvar,
    )>,
}

struct CodexState {
    next_request_id: u64,
    initialized: bool,
    lifecycle: String,
    thread_id: Option<String>,
    turn_id: Option<String>,
    pending: HashMap<String, CodexPending>,
    cancelled_tokens: HashSet<String>,
}

struct AcpState {
    rpc: JsonRpcState,
    initialized: bool,
    authenticated: bool,
    lifecycle: String,
    session_id: Option<String>,
    session_generation: u64,
    prompt_generation: u64,
    active_prompt_generation: Option<u64>,
}

/// One Codex or ACP provider process. Codex and ACP lines are interpreted by the Rust JSON-RPC
/// reducer; Claude headless retains its translator. Every observation is wrapped in a versioned
/// event envelope and published through the existing subscription hub.
pub struct AgentProviderScope {
    identity: RuntimeIdentity,
    id: AgentProviderScopeId,
    config: AgentProviderScopeConfig,
    reaper: Arc<Reaper>,
    state: Mutex<ScopeState>,
    event_sink: Mutex<Option<(Arc<SubscriptionHub>, ScopeId)>>,
    readers_remaining: Arc<(Mutex<u8>, Condvar)>,
    codex: Option<Mutex<CodexState>>,
    acp: Option<Mutex<AcpState>>,
}

impl AgentProviderScope {
    fn new(
        identity: RuntimeIdentity,
        id: AgentProviderScopeId,
        config: AgentProviderScopeConfig,
        reaper: Arc<Reaper>,
    ) -> Arc<Self> {
        let is_codex = config.protocol == ProviderProtocol::CodexAppServer;
        let is_acp = config.protocol == ProviderProtocol::Acp;
        Arc::new(Self {
            identity,
            id,
            config,
            reaper,
            state: Mutex::new(ScopeState {
                closed: false,
                next_sequence: 0,
                process: None,
            }),
            event_sink: Mutex::new(None),
            readers_remaining: Arc::new((Mutex::new(0), Condvar::new())),
            codex: is_codex.then(|| {
                Mutex::new(CodexState {
                    next_request_id: 1,
                    initialized: false,
                    lifecycle: "created".to_owned(),
                    thread_id: None,
                    turn_id: None,
                    pending: HashMap::new(),
                    cancelled_tokens: HashSet::new(),
                })
            }),
            acp: is_acp.then(|| {
                Mutex::new(AcpState {
                    rpc: JsonRpcState::new(),
                    initialized: false,
                    authenticated: false,
                    lifecycle: "created".to_owned(),
                    session_id: None,
                    session_generation: 0,
                    prompt_generation: 0,
                    active_prompt_generation: None,
                })
            }),
        })
    }

    pub fn id(&self) -> AgentProviderScopeId {
        self.id
    }

    pub fn attach_event_sink(&self, hub: Arc<SubscriptionHub>, scope: ScopeId) {
        *self
            .event_sink
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some((hub, scope));
    }

    fn validate(&self, identity: &RuntimeIdentity) -> Result<(), AgentProviderScopeError> {
        if &self.identity == identity {
            Ok(())
        } else {
            Err(AgentProviderScopeError::IdentityMismatch)
        }
    }

    pub fn start(
        self: &Arc<Self>,
        identity: &RuntimeIdentity,
    ) -> Result<StartReceipt, AgentProviderScopeError> {
        self.start_with_stdin(identity, None)
    }

    pub fn start_with_stdin(
        self: &Arc<Self>,
        identity: &RuntimeIdentity,
        initial_stdin: Option<&[u8]>,
    ) -> Result<StartReceipt, AgentProviderScopeError> {
        self.validate(identity)?;
        if initial_stdin.is_some() && self.config.protocol != ProviderProtocol::ClaudeHeadless {
            return Err(AgentProviderScopeError::InvalidArgument(
                "initial_stdin requires claudeHeadless",
            ));
        }
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.closed {
            return Err(AgentProviderScopeError::ScopeClosed);
        }
        if state.process.is_some() {
            return Err(AgentProviderScopeError::AlreadyRunning);
        }
        {
            let (remaining, _) = &*self.readers_remaining;
            *remaining
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = 2;
        }
        let spawned = process::spawn(&SpawnConfig {
            command: &self.config.command,
            arguments: &self.config.arguments,
            environment: &self.config.environment,
            working_directory: self.config.working_directory.as_deref(),
        })
        .map_err(|error| AgentProviderScopeError::Spawn(error.to_string()))?;
        let token = self
            .reaper
            .register(spawned.pid)
            .map_err(|error| AgentProviderScopeError::Reaper(format!("{error:?}")))?;
        let pid = spawned.pid;
        let process_group_id = spawned.process_group_id;
        let stdin = Arc::new(Mutex::new(File::from(spawned.stdin_write)));
        state.process = Some(RunningProcess {
            pid,
            reaper_token: token,
            stdin: Some(stdin),
        });
        if let Some(acp) = self.acp.as_ref() {
            let mut acp = acp
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            acp.lifecycle = "running".to_owned();
        }
        drop(state);

        // Publish the lifecycle head before readers can observe a very short-lived child. This
        // makes processStarted the first authority event even when the provider exits immediately.
        self.publish(
            "processStarted",
            json!({ "pid": pid, "process_group_id": process_group_id }),
            false,
        );
        self.spawn_stdout_reader(spawned.stdout_read, pid, token);
        self.spawn_stderr_reader(spawned.stderr_read, pid);
        if let Some(payload) = initial_stdin {
            let stdin = {
                let mut state = self
                    .state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                state
                    .process
                    .as_mut()
                    .and_then(|process| process.stdin.take())
            };
            let Some(stdin) = stdin else {
                let error = AgentProviderScopeError::NotRunning;
                let _ = self.shutdown(identity);
                return Err(error);
            };
            let result = stdin
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .write_all(payload);
            if let Err(error) = result {
                // The initial prompt is part of start's atomic one-shot handoff. If the child
                // closes stdin before accepting it, terminate the scope so a failed start cannot
                // leak a process or leave a reader pair behind.
                let mapped = AgentProviderScopeError::TransportWrite(error.to_string());
                let _ = self.shutdown(identity);
                return Err(mapped);
            }
            // Dropping the last file handle is part of the one-shot contract:
            // Claude starts processing a prompt only after stdin reaches EOF.
            drop(stdin);
        }
        Ok(StartReceipt {
            pid,
            process_group_id,
        })
    }

    fn send_line_internal(
        &self,
        identity: &RuntimeIdentity,
        payload: &[u8],
    ) -> Result<u64, AgentProviderScopeError> {
        self.validate(identity)?;
        if payload.is_empty() {
            return Err(AgentProviderScopeError::InvalidArgument("payload"));
        }
        let (stdin, sequence) = {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.closed {
                return Err(AgentProviderScopeError::ScopeClosed);
            }
            let stdin = state
                .process
                .as_ref()
                .ok_or(AgentProviderScopeError::NotRunning)
                .and_then(|process| {
                    process
                        .stdin
                        .as_ref()
                        .map(Arc::clone)
                        .ok_or(AgentProviderScopeError::NotRunning)
                })?;
            state.next_sequence = state.next_sequence.saturating_add(1);
            (stdin, state.next_sequence)
        };
        let mut frame = payload.to_vec();
        if frame.last().copied() != Some(b'\n') {
            frame.push(b'\n');
        }
        stdin
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .write_all(&frame)
            .map_err(|error| AgentProviderScopeError::TransportWrite(error.to_string()))?;
        self.publish_with_sequence(
            "outbound",
            Value::String(String::from_utf8_lossy(payload).into_owned()),
            sequence,
            false,
        );
        Ok(sequence)
    }

    fn require_codex(&self) -> Result<&Mutex<CodexState>, AgentProviderScopeError> {
        self.codex
            .as_ref()
            .ok_or(AgentProviderScopeError::CodexProtocolMismatch)
    }

    fn require_acp(&self) -> Result<&Mutex<AcpState>, AgentProviderScopeError> {
        self.acp
            .as_ref()
            .ok_or(AgentProviderScopeError::AcpProtocolMismatch)
    }

    /// Return the immutable protocol capability profile for this scope. The scope identity is
    /// checked, but process state is intentionally not read or mutated so certification can run
    /// before startup and remain side-effect free.
    pub fn conformance_snapshot(
        &self,
        identity: &RuntimeIdentity,
    ) -> Result<AgentProviderConformanceSnapshot, AgentProviderScopeError> {
        self.validate(identity)?;
        Ok(agent_provider_conformance_snapshot(self.config.protocol))
    }

    pub fn validate_conformance(
        &self,
        identity: &RuntimeIdentity,
    ) -> Result<AgentProviderConformanceValidation, AgentProviderScopeError> {
        let snapshot = self.conformance_snapshot(identity)?;
        Ok(validate_agent_provider_conformance(&snapshot))
    }

    pub fn acp_state(
        &self,
        identity: &RuntimeIdentity,
    ) -> Result<AcpSessionState, AgentProviderScopeError> {
        self.validate(identity)?;
        let state = self
            .require_acp()?
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Ok(AcpSessionState {
            lifecycle: state.lifecycle.clone(),
            initialized: state.initialized,
            authenticated: state.authenticated,
            session_id: state.session_id.clone(),
            session_generation: state.session_generation,
            prompt_generation: state.prompt_generation,
            active_prompt_generation: state.active_prompt_generation,
            pending_request_count: state.rpc.pending_count(),
        })
    }

    pub fn acp_request(
        &self,
        identity: &RuntimeIdentity,
        method: &str,
        params: Option<&[u8]>,
        timeout: Option<Duration>,
        cancellation_token: Option<&str>,
    ) -> Result<AcpResponse, AgentProviderScopeError> {
        self.validate(identity)?;
        if method.trim().is_empty() {
            return Err(AgentProviderScopeError::InvalidArgument("method"));
        }
        let acp = self.require_acp()?;
        let params_value = match params {
            Some(bytes) => Some(
                serde_json::from_slice::<Value>(bytes)
                    .map_err(|_| AgentProviderScopeError::AcpInvalidJSON)?,
            ),
            None => None,
        };
        let (request_id, waiter) = {
            let mut state = acp
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.rpc.allocate_request(
                method,
                cancellation_token,
                AgentProviderScopeError::AcpCancelled,
            )?
        };
        let key = request_id.key();
        let mut request = json!({
            "jsonrpc": "2.0",
            "id": request_id.value(),
            "method": method
        });
        if let Some(params) = params_value {
            request["params"] = params;
        }
        let bytes =
            serde_json::to_vec(&request).map_err(|_| AgentProviderScopeError::AcpInvalidJSON)?;
        let outbound_sequence = match self.send_line_internal(identity, &bytes) {
            Ok(sequence) => sequence,
            Err(error) => {
                let mut state = acp
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                state.rpc.remove_pending_by_key(&key);
                return Err(error);
            }
        };
        {
            let mut state = acp
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            apply_acp_request_started(&mut state, method);
        }
        let (result_lock, result_wake) = &*waiter;
        let mut result = result_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let deadline = timeout.map(|timeout| std::time::Instant::now() + timeout);
        loop {
            if let Some(completion) = result.take() {
                let completion = completion?;
                let result_json = serde_json::to_vec(&completion.result)
                    .map_err(|_| AgentProviderScopeError::AcpInvalidResponse)?;
                let (lifecycle, session_generation, prompt_generation) = {
                    let mut state = acp
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    apply_acp_request_succeeded(&mut state, method, &completion.result);
                    (
                        state.lifecycle.clone(),
                        state.session_generation,
                        if method == "session/prompt" {
                            Some(state.prompt_generation)
                        } else {
                            state.active_prompt_generation
                        },
                    )
                };
                return Ok(AcpResponse {
                    result: result_json,
                    inbound_sequence: completion.inbound_sequence,
                    outbound_sequence,
                    lifecycle,
                    session_generation,
                    prompt_generation,
                });
            }
            if let Some(deadline) = deadline {
                let now = std::time::Instant::now();
                if now >= deadline {
                    let mut state = acp
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    state.rpc.remove_pending_by_key(&key);
                    apply_acp_request_failed(&mut state, method);
                    return Err(AgentProviderScopeError::AcpTimedOut(method.to_owned()));
                }
                let (next, _) = result_wake
                    .wait_timeout(result, deadline.saturating_duration_since(now))
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                result = next;
            } else {
                result = result_wake
                    .wait(result)
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
            }
        }
    }

    pub fn acp_cancel(
        &self,
        identity: &RuntimeIdentity,
        cancellation_token: &str,
    ) -> Result<bool, AgentProviderScopeError> {
        self.validate(identity)?;
        if cancellation_token.is_empty() {
            return Err(AgentProviderScopeError::InvalidArgument(
                "cancellation token",
            ));
        }
        let acp = self.require_acp()?;
        let pending = {
            let mut state = acp
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.rpc.cancel_token(cancellation_token)
        };
        let Some(pending) = pending else {
            return Ok(false);
        };
        let method = pending.method.clone();
        if let Ok(mut state) = acp.lock() {
            apply_acp_request_failed(&mut state, &method);
        }
        settle_pending(pending, Err(AgentProviderScopeError::AcpCancelled(method)));
        Ok(true)
    }

    pub fn acp_notify(
        &self,
        identity: &RuntimeIdentity,
        method: &str,
        params: Option<&[u8]>,
        expected_session_generation: Option<u64>,
    ) -> Result<AcpControlReceipt, AgentProviderScopeError> {
        self.validate(identity)?;
        let acp_state = self.require_acp()?;
        if method == "session/cancel"
            && expected_session_generation.is_some_and(|expected| {
                let state = acp_state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                expected != state.session_generation
            })
        {
            return Err(AgentProviderScopeError::InvalidArgument(
                "stale ACP session generation",
            ));
        }
        self.require_acp()?;
        if method.trim().is_empty() {
            return Err(AgentProviderScopeError::InvalidArgument("method"));
        }
        let mut payload = json!({ "jsonrpc": "2.0", "method": method });
        if let Some(params) = params {
            payload["params"] = serde_json::from_slice(params)
                .map_err(|_| AgentProviderScopeError::AcpInvalidJSON)?;
        }
        let bytes =
            serde_json::to_vec(&payload).map_err(|_| AgentProviderScopeError::AcpInvalidJSON)?;
        let outbound_sequence = self.send_line_internal(identity, &bytes)?;
        let (lifecycle, session_generation, prompt_generation) = {
            let mut state = self
                .require_acp()?
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            apply_acp_notification(&mut state, method, &payload);
            (
                state.lifecycle.clone(),
                state.session_generation,
                state.active_prompt_generation,
            )
        };
        Ok(AcpControlReceipt {
            outbound_sequence,
            lifecycle,
            session_generation,
            prompt_generation,
        })
    }

    pub fn acp_respond(
        &self,
        identity: &RuntimeIdentity,
        request_id: &[u8],
        result: &[u8],
    ) -> Result<AcpControlReceipt, AgentProviderScopeError> {
        self.acp_respond_inner(identity, request_id, Some(result), None)
    }

    pub fn acp_respond_error(
        &self,
        identity: &RuntimeIdentity,
        request_id: &[u8],
        code: i64,
        message: &str,
        data: Option<&[u8]>,
    ) -> Result<AcpControlReceipt, AgentProviderScopeError> {
        self.acp_respond_inner(identity, request_id, None, Some((code, message, data)))
    }

    fn acp_respond_inner(
        &self,
        identity: &RuntimeIdentity,
        request_id: &[u8],
        result: Option<&[u8]>,
        error: Option<(i64, &str, Option<&[u8]>)>,
    ) -> Result<AcpControlReceipt, AgentProviderScopeError> {
        self.validate(identity)?;
        self.require_acp()?;
        let id: Value = serde_json::from_slice(request_id)
            .map_err(|_| AgentProviderScopeError::AcpInvalidJSON)?;
        if JsonRpcId::from_value(&id).is_none() {
            return Err(AgentProviderScopeError::InvalidArgument("request id"));
        }
        let mut payload = json!({ "jsonrpc": "2.0", "id": id });
        if let Some(result) = result {
            payload["result"] = serde_json::from_slice(result)
                .map_err(|_| AgentProviderScopeError::AcpInvalidJSON)?;
        } else if let Some((code, message, data)) = error {
            let mut value = json!({ "code": code, "message": message });
            if let Some(data) = data {
                value["data"] = serde_json::from_slice(data)
                    .map_err(|_| AgentProviderScopeError::AcpInvalidJSON)?;
            }
            payload["error"] = value;
        }
        let bytes =
            serde_json::to_vec(&payload).map_err(|_| AgentProviderScopeError::AcpInvalidJSON)?;
        let outbound_sequence = self.send_line_internal(identity, &bytes)?;
        let state = self
            .require_acp()?
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Ok(AcpControlReceipt {
            outbound_sequence,
            lifecycle: state.lifecycle.clone(),
            session_generation: state.session_generation,
            prompt_generation: state.active_prompt_generation,
        })
    }

    pub fn codex_state(
        &self,
        identity: &RuntimeIdentity,
    ) -> Result<CodexSessionState, AgentProviderScopeError> {
        self.validate(identity)?;
        let state = self
            .require_codex()?
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Ok(CodexSessionState {
            lifecycle: state.lifecycle.clone(),
            initialized: state.initialized,
            thread_id: state.thread_id.clone(),
            turn_id: state.turn_id.clone(),
            pending_request_count: state.pending.len(),
        })
    }

    pub fn codex_request(
        &self,
        identity: &RuntimeIdentity,
        method: &str,
        params: Option<&[u8]>,
        timeout: Option<Duration>,
        cancellation_token: Option<&str>,
    ) -> Result<Vec<u8>, AgentProviderScopeError> {
        self.validate(identity)?;
        if method.trim().is_empty() {
            return Err(AgentProviderScopeError::InvalidArgument("method"));
        }
        let codex = self.require_codex()?;
        let params_value = match params {
            Some(bytes) => Some(
                serde_json::from_slice::<Value>(bytes)
                    .map_err(|_| AgentProviderScopeError::CodexInvalidJSON)?,
            ),
            None => None,
        };
        let cancellation_token = cancellation_token
            .filter(|token| !token.is_empty())
            .map(ToOwned::to_owned);
        let (request_id, waiter) = {
            let mut state = codex
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(token) = cancellation_token.as_ref()
                && state.cancelled_tokens.remove(token)
            {
                return Err(AgentProviderScopeError::CodexCancelled(method.to_owned()));
            }
            if state.pending.len() >= 256 {
                return Err(AgentProviderScopeError::InvalidArgument(
                    "too many pending codex requests",
                ));
            }
            let request_id = state.next_request_id;
            state.next_request_id = state.next_request_id.saturating_add(1);
            let waiter = Arc::new((Mutex::new(None), Condvar::new()));
            state.pending.insert(
                codex_numeric_id_key(request_id),
                CodexPending {
                    method: method.to_owned(),
                    cancellation_token,
                    result: Arc::clone(&waiter),
                },
            );
            (request_id, waiter)
        };
        let mut request = json!({ "jsonrpc": "2.0", "id": request_id, "method": method });
        if let Some(params) = params_value {
            request["params"] = params;
        }
        let bytes =
            serde_json::to_vec(&request).map_err(|_| AgentProviderScopeError::CodexInvalidJSON)?;
        if let Err(error) = self.send_line_internal(identity, &bytes) {
            let mut state = codex
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.pending.remove(&codex_numeric_id_key(request_id));
            return Err(error);
        }
        let (result_lock, result_wake) = &*waiter;
        let mut result = result_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let deadline = timeout.map(|timeout| std::time::Instant::now() + timeout);
        loop {
            if let Some(result_value) = result.take() {
                return result_value.and_then(|value| {
                    serde_json::to_vec(&value)
                        .map_err(|_| AgentProviderScopeError::CodexInvalidResponse)
                });
            }
            if let Some(deadline) = deadline {
                let now = std::time::Instant::now();
                if now >= deadline {
                    let mut state = codex
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    state.pending.remove(&codex_numeric_id_key(request_id));
                    return Err(AgentProviderScopeError::CodexTimedOut(method.to_owned()));
                }
                let (next, _) = result_wake
                    .wait_timeout(result, deadline.saturating_duration_since(now))
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                result = next;
            } else {
                result = result_wake
                    .wait(result)
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
            }
        }
    }

    pub fn codex_cancel(
        &self,
        identity: &RuntimeIdentity,
        cancellation_token: &str,
    ) -> Result<bool, AgentProviderScopeError> {
        self.validate(identity)?;
        self.require_codex()?;
        if cancellation_token.is_empty() {
            return Err(AgentProviderScopeError::InvalidArgument(
                "cancellation token",
            ));
        }
        let pending = {
            let codex = self.require_codex()?;
            let mut state = codex
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let request_id = state.pending.iter().find_map(|(request_id, pending)| {
                (pending.cancellation_token.as_deref() == Some(cancellation_token))
                    .then(|| request_id.clone())
            });
            if let Some(request_id) = request_id {
                state.pending.remove(&request_id)
            } else {
                if state.cancelled_tokens.len() >= 256 {
                    if let Some(oldest) = state.cancelled_tokens.iter().next().cloned() {
                        state.cancelled_tokens.remove(&oldest);
                    }
                }
                state.cancelled_tokens.insert(cancellation_token.to_owned());
                None
            }
        };
        let Some(pending) = pending else {
            return Ok(false);
        };
        let method = pending.method.clone();
        let (lock, wake) = &*pending.result;
        *lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some(Err(AgentProviderScopeError::CodexCancelled(method)));
        wake.notify_all();
        Ok(true)
    }

    pub fn codex_notify(
        &self,
        identity: &RuntimeIdentity,
        method: &str,
        params: Option<&[u8]>,
    ) -> Result<u64, AgentProviderScopeError> {
        self.validate(identity)?;
        self.require_codex()?;
        if method.trim().is_empty() {
            return Err(AgentProviderScopeError::InvalidArgument("method"));
        }
        let mut payload = json!({ "jsonrpc": "2.0", "method": method });
        if let Some(params) = params {
            payload["params"] = serde_json::from_slice(params)
                .map_err(|_| AgentProviderScopeError::CodexInvalidJSON)?;
        }
        let bytes =
            serde_json::to_vec(&payload).map_err(|_| AgentProviderScopeError::CodexInvalidJSON)?;
        self.send_line_internal(identity, &bytes)
    }

    pub fn codex_respond(
        &self,
        identity: &RuntimeIdentity,
        request_id: &[u8],
        result: &[u8],
    ) -> Result<u64, AgentProviderScopeError> {
        self.codex_respond_inner(identity, request_id, Some(result), None)
    }

    pub fn codex_respond_error(
        &self,
        identity: &RuntimeIdentity,
        request_id: &[u8],
        code: i64,
        message: &str,
        data: Option<&[u8]>,
    ) -> Result<u64, AgentProviderScopeError> {
        self.codex_respond_inner(identity, request_id, None, Some((code, message, data)))
    }

    fn codex_respond_inner(
        &self,
        identity: &RuntimeIdentity,
        request_id: &[u8],
        result: Option<&[u8]>,
        error: Option<(i64, &str, Option<&[u8]>)>,
    ) -> Result<u64, AgentProviderScopeError> {
        self.validate(identity)?;
        self.require_codex()?;
        let id: Value = serde_json::from_slice(request_id)
            .map_err(|_| AgentProviderScopeError::CodexInvalidJSON)?;
        if codex_id_key(&id).is_none() {
            return Err(AgentProviderScopeError::InvalidArgument("request id"));
        }
        let mut payload = json!({ "jsonrpc": "2.0", "id": id });
        if let Some(result) = result {
            payload["result"] = serde_json::from_slice(result)
                .map_err(|_| AgentProviderScopeError::CodexInvalidJSON)?;
        } else if let Some((code, message, data)) = error {
            let mut value = json!({ "code": code, "message": message });
            if let Some(data) = data {
                value["data"] = serde_json::from_slice(data)
                    .map_err(|_| AgentProviderScopeError::CodexInvalidJSON)?;
            }
            payload["error"] = value;
        }
        let bytes =
            serde_json::to_vec(&payload).map_err(|_| AgentProviderScopeError::CodexInvalidJSON)?;
        self.send_line_internal(identity, &bytes)
    }

    fn ingest_codex_line(&self, pid: i32, line: &[u8]) {
        let value = match serde_json::from_slice::<Value>(line) {
            Ok(value) => value,
            Err(_) => {
                self.publish(
                    "protocolError",
                    json!({ "pid": pid, "message": "invalid JSON" }),
                    false,
                );
                return;
            }
        };
        let Some(object) = value.as_object() else {
            self.publish(
                "protocolError",
                json!({ "pid": pid, "message": "JSON-RPC message must be an object" }),
                false,
            );
            return;
        };
        if let Some(method) = object.get("method").and_then(Value::as_str) {
            let params = object.get("params").cloned().unwrap_or(Value::Null);
            if let Some(id) = object.get("id") {
                self.publish(
                    "serverRequest",
                    json!({ "pid": pid, "id": id, "method": method, "params": params }),
                    false,
                );
            } else {
                self.publish(
                    "notification",
                    json!({ "pid": pid, "method": method, "params": params }),
                    false,
                );
            }
            return;
        }
        let Some(id) = object.get("id").and_then(codex_id_key) else {
            self.publish(
                "protocolError",
                json!({ "pid": pid, "message": "response is missing id" }),
                false,
            );
            return;
        };
        let (pending, response) = {
            let Some(codex) = self.codex.as_ref() else {
                return;
            };
            let mut state = codex
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(pending) = state.pending.remove(&id) else {
                return;
            };
            if let Some(error) = object.get("error").and_then(Value::as_object) {
                let method = pending.method.clone();
                let code = error.get("code").and_then(Value::as_i64).unwrap_or(-32000);
                let message = error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("remote error")
                    .to_owned();
                (
                    pending,
                    Err(AgentProviderScopeError::CodexRemoteError {
                        method,
                        code,
                        message,
                        data: error
                            .get("data")
                            .and_then(|value| serde_json::to_vec(value).ok()),
                    }),
                )
            } else if let Some(result) = object.get("result") {
                update_codex_lifecycle(&mut state, &pending.method, result);
                (pending, Ok(result.clone()))
            } else {
                (pending, Err(AgentProviderScopeError::CodexInvalidResponse))
            }
        };
        let (lock, wake) = &*pending.result;
        *lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(response);
        wake.notify_all();
    }

    fn ingest_acp_line(&self, pid: i32, line: &[u8]) {
        let value = match serde_json::from_slice::<Value>(line) {
            Ok(value) => value,
            Err(_) => {
                self.publish(
                    "protocolError",
                    json!({
                        "pid": pid,
                        "category": "invalidJson",
                        "message": "invalid JSON",
                        "raw_preview": bounded_provider_preview(line),
                    }),
                    false,
                );
                return;
            }
        };
        let Some(object) = value.as_object() else {
            self.publish(
                "protocolError",
                json!({
                    "pid": pid,
                    "category": "invalidMessage",
                    "message": "JSON-RPC message must be an object",
                    "raw_preview": bounded_provider_preview(line),
                }),
                false,
            );
            return;
        };
        let (acp, inbound_sequence) = match self.acp.as_ref() {
            Some(acp) => {
                let mut state = acp
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                (acp, state.rpc.next_inbound_sequence())
            }
            None => return,
        };
        if let Some(method) = object.get("method").and_then(Value::as_str) {
            let params = object
                .get("params")
                .cloned()
                .unwrap_or(Value::Object(serde_json::Map::new()));
            if let Some(id) = object.get("id") {
                let Some(rpc_id) = JsonRpcId::from_value(id) else {
                    self.publish(
                        "protocolError",
                        json!({
                            "pid": pid,
                            "category": "invalidRequestId",
                            "message": "server request id is not a valid JSON-RPC id",
                            "raw_preview": bounded_provider_preview(line),
                        }),
                        false,
                    );
                    return;
                };
                self.publish(
                    "serverRequest",
                    json!({
                        "pid": pid,
                        "id": rpc_id.value(),
                        "id_json": String::from_utf8_lossy(&rpc_id.encoded()),
                        "method": method,
                        "params": params,
                        "inbound_sequence": inbound_sequence,
                    }),
                    false,
                );
            } else {
                self.publish(
                    "notification",
                    json!({
                        "pid": pid,
                        "method": method,
                        "params": params,
                        "inbound_sequence": inbound_sequence,
                    }),
                    false,
                );
            }
            return;
        }
        let Some(id_value) = object.get("id") else {
            self.publish(
                "protocolError",
                json!({
                    "pid": pid,
                    "category": "missingId",
                    "message": "response is missing id",
                    "raw_preview": bounded_provider_preview(line),
                }),
                false,
            );
            return;
        };
        let Some(id) = JsonRpcId::from_value(id_value) else {
            self.publish(
                "protocolError",
                json!({
                    "pid": pid,
                    "category": "invalidResponseId",
                    "message": "response id is not a valid JSON-RPC id",
                    "raw_preview": bounded_provider_preview(line),
                }),
                false,
            );
            return;
        };
        let pending = {
            let mut state = acp
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.rpc.take_pending(&id)
        };
        let Some(pending) = pending else {
            self.publish(
                "protocolError",
                json!({
                    "pid": pid,
                    "category": "unmatchedResponse",
                    "message": format!("received unmatched ACP response id {}", String::from_utf8_lossy(&id.encoded())),
                    "raw_preview": bounded_provider_preview(line),
                    "inbound_sequence": inbound_sequence,
                }),
                false,
            );
            return;
        };
        if let Some(error) = object.get("error").and_then(Value::as_object) {
            let code = error.get("code").and_then(Value::as_i64).unwrap_or(-32000);
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("remote error")
                .to_owned();
            let method = pending.method.clone();
            let data = error
                .get("data")
                .and_then(|value| serde_json::to_vec(value).ok());
            if let Ok(mut state) = acp.lock() {
                apply_acp_request_failed(&mut state, &method);
            }
            settle_pending(
                pending,
                Err(AgentProviderScopeError::AcpRemoteError {
                    method,
                    code,
                    message,
                    data,
                }),
            );
            return;
        }
        let Some(result) = object.get("result") else {
            self.publish(
                "protocolError",
                json!({
                    "pid": pid,
                    "category": "missingResultOrError",
                    "message": "response is missing result/error",
                    "raw_preview": bounded_provider_preview(line),
                    "inbound_sequence": inbound_sequence,
                }),
                false,
            );
            settle_pending(pending, Err(AgentProviderScopeError::AcpInvalidResponse));
            return;
        };
        if let Ok(mut state) = acp.lock() {
            apply_acp_request_succeeded(&mut state, &pending.method, result);
        }
        settle_pending(
            pending,
            Ok(JsonRpcCompletion {
                result: result.clone(),
                inbound_sequence,
            }),
        );
    }

    fn fail_acp_pending(&self, error: AgentProviderScopeError, mark_closed: bool) {
        let Some(acp) = self.acp.as_ref() else {
            return;
        };
        let pending = {
            let mut state = acp
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if mark_closed {
                state.lifecycle = "closed".to_owned();
            }
            state.rpc.drain_pending()
        };
        for pending in pending {
            settle_pending(pending, Err(error.clone()));
        }
    }

    fn fail_codex_pending(&self, error: AgentProviderScopeError, mark_closed: bool) {
        let Some(codex) = self.codex.as_ref() else {
            return;
        };
        let pending = {
            let mut state = codex
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if mark_closed {
                state.lifecycle = "closed".to_owned();
            }
            state
                .pending
                .drain()
                .map(|(_, pending)| pending)
                .collect::<Vec<_>>()
        };
        for pending in pending {
            let (lock, wake) = &*pending.result;
            *lock
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Err(error.clone()));
            wake.notify_all();
        }
    }

    fn close_codex_pending(&self) {
        self.fail_codex_pending(AgentProviderScopeError::ScopeClosed, true);
    }

    pub fn send_line(
        &self,
        identity: &RuntimeIdentity,
        payload: &[u8],
    ) -> Result<u64, AgentProviderScopeError> {
        if self.config.protocol == ProviderProtocol::CodexAppServer {
            return Err(AgentProviderScopeError::InvalidArgument(
                "codex scopes require codex request/notify/respond APIs",
            ));
        }
        if self.config.protocol == ProviderProtocol::Acp {
            return Err(AgentProviderScopeError::InvalidArgument(
                "acp scopes require acp request/notify/respond APIs",
            ));
        }
        self.send_line_internal(identity, payload)
    }

    pub fn shutdown(&self, identity: &RuntimeIdentity) -> Result<(), AgentProviderScopeError> {
        self.validate(identity)?;
        let process = {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.closed {
                return Ok(());
            }
            state.closed = true;
            state.process.take()
        };
        // Transition scope admission before draining waiters so no concurrent request can insert
        // a new pending entry between the lifecycle fence and the terminal settlement.
        self.close_codex_pending();
        self.fail_acp_pending(AgentProviderScopeError::ScopeClosed, true);
        if let Some(process) = process {
            let _ = process::terminate_and_reap(
                &self.reaper,
                process.pid,
                process.reaper_token,
                Duration::from_secs(1),
            );
        }
        self.wait_for_readers();
        self.publish("scopeClosed", json!({}), true);
        Ok(())
    }

    fn spawn_stdout_reader(self: &Arc<Self>, fd: std::os::fd::OwnedFd, pid: i32, token: u64) {
        let weak = Arc::downgrade(self);
        let reaper = Arc::clone(&self.reaper);
        let is_claude_headless = self.config.protocol == ProviderProtocol::ClaudeHeadless;
        crate::agent_claude::process::thread_budget::increment();
        let result = thread::Builder::new()
            .name("agent-provider-stdout".into())
            .spawn(move || {
                let _budget =
                    crate::agent_claude::process::thread_budget::ThreadBudgetGuard::already_counted(
                    );
                let mut file = File::from(fd);
                let mut framer = LineFramer::default();
                let mut translator = is_claude_headless.then(|| {
                    Translator::new(Box::new(
                        crate::agent_claude::tool_owned::is_repoprompt_tool_name,
                    ))
                });
                let mut buffer = [0u8; 64 * 1024];
                loop {
                    let count = match file.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(n) => n,
                        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    };
                    if let Some(scope) = weak.upgrade() {
                        framer.feed(
                            &buffer[..count],
                            |_diagnostic| {},
                            |line| publish_provider_line(&scope, pid, &mut translator, &line),
                        );
                    } else {
                        break;
                    }
                }
                let Some(scope) = weak.upgrade() else { return };
                framer.flush(|line| publish_provider_line(&scope, pid, &mut translator, &line));
                // stdout EOF is the only per-scope terminal wait. Reusing this reader keeps the
                // shared reaper at one process-wide thread instead of adding an exit watcher per
                // provider process.
                let wait_timeout = if is_claude_headless {
                    CLAUDE_HEADLESS_TIMEOUT
                } else {
                    Duration::from_secs(365 * 24 * 60 * 60)
                };
                let (outcome, timed_out) = match reaper.wait_for_exit(pid, token, wait_timeout) {
                    Some(outcome) => (outcome, false),
                    None if is_claude_headless => {
                        // A timeout is a Rust-owned terminal fact. Reuse the same bounded
                        // process-group termination path as explicit scope shutdown, then expose
                        // the timeout bit alongside the final exit outcome.
                        let outcome = process::terminate_and_reap(
                            &reaper,
                            pid,
                            token,
                            Duration::from_secs(1),
                        )
                        .unwrap_or(ReapOutcome::Lost);
                        (outcome, true)
                    }
                    None => (ReapOutcome::Lost, false),
                };
                scope.wait_for_other_reader();
                reaper.forget(pid, token);
                scope.finish_process(pid, outcome, timed_out);
                // Keep processExited ahead of scopeClosed when shutdown is racing the reader.
                scope.reader_finished();
            });
        if result.is_err() {
            crate::agent_claude::process::thread_budget::AGENT_DOMAIN_THREAD_COUNT
                .fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        }
        result.expect("agent provider stdout reader must start");
    }

    fn spawn_stderr_reader(self: &Arc<Self>, fd: std::os::fd::OwnedFd, pid: i32) {
        let weak = Arc::downgrade(self);
        let limit = self.config.max_stderr_bytes.max(1024);
        crate::agent_claude::process::thread_budget::increment();
        let result = thread::Builder::new()
            .name("agent-provider-stderr".into())
            .spawn(move || {
                let _budget = crate::agent_claude::process::thread_budget::ThreadBudgetGuard::already_counted();
                let mut file = File::from(fd);
                let mut buffer = [0u8; 16 * 1024];
                let mut retained = Vec::new();
                let mut truncated = false;
                loop {
                    let count = match file.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(n) => n,
                        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    };
                    retained.extend_from_slice(&buffer[..count]);
                    if retained.len() > limit {
                        let excess = retained.len() - limit;
                        retained.drain(..excess);
                        truncated = true;
                    }
                    if let Some(scope) = weak.upgrade() {
                        scope.publish(
                            "stderr",
                            json!({ "pid": pid, "text": String::from_utf8_lossy(&buffer[..count]) }),
                            false,
                        );
                    } else {
                        break;
                    }
                }
                if let Some(scope) = weak.upgrade() {
                    scope.publish(
                        "stderrTail",
                        json!({ "pid": pid, "text": String::from_utf8_lossy(&retained), "truncated": truncated }),
                        false,
                    );
                    scope.reader_finished();
                }
            });
        if result.is_err() {
            crate::agent_claude::process::thread_budget::AGENT_DOMAIN_THREAD_COUNT
                .fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        }
        result.expect("agent provider stderr reader must start");
    }

    fn finish_process(&self, pid: i32, outcome: ReapOutcome, timed_out: bool) {
        // Natural process exit is terminal for semantic provider requests too; do not leave
        // callers waiting for their individual deadlines after the child has already gone away.
        self.fail_codex_pending(AgentProviderScopeError::NotRunning, true);
        self.fail_acp_pending(AgentProviderScopeError::NotRunning, true);
        {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state
                .process
                .as_ref()
                .is_some_and(|process| process.pid == pid)
            {
                state.process = None;
            }
        }
        let payload = match outcome {
            ReapOutcome::Exited(code) => {
                json!({ "pid": pid, "exit_code": code, "signal": null, "timed_out": timed_out })
            }
            ReapOutcome::Signaled(signal) => {
                json!({ "pid": pid, "exit_code": null, "signal": signal, "timed_out": timed_out })
            }
            ReapOutcome::Lost => {
                json!({ "pid": pid, "exit_code": null, "signal": null, "timed_out": timed_out, "ownership_lost": true })
            }
        };
        self.publish("processExited", payload, true);
    }

    fn reader_finished(&self) {
        let (remaining, wake) = &*self.readers_remaining;
        let mut value = remaining
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        *value = value.saturating_sub(1);
        wake.notify_all();
    }

    fn wait_for_other_reader(&self) {
        let (remaining, wake) = &*self.readers_remaining;
        let mut value = remaining
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while *value > 1 {
            let now = std::time::Instant::now();
            if now >= deadline {
                break;
            }
            let timeout = deadline.saturating_duration_since(now);
            let (next, _) = wake
                .wait_timeout(value, timeout)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            value = next;
        }
    }

    fn wait_for_readers(&self) {
        let (remaining, wake) = &*self.readers_remaining;
        let mut value = remaining
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while *value > 0 {
            let now = std::time::Instant::now();
            if now >= deadline {
                break;
            }
            let timeout = deadline.saturating_duration_since(now);
            let (next, _) = wake
                .wait_timeout(value, timeout)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            value = next;
        }
    }

    fn publish(&self, kind: &str, payload: Value, terminal: bool) {
        let sequence = {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.next_sequence = state.next_sequence.saturating_add(1);
            state.next_sequence
        };
        self.publish_with_sequence(kind, payload, sequence, terminal);
    }

    fn publish_with_sequence(&self, kind: &str, payload: Value, sequence: u64, terminal: bool) {
        let envelope = json!({
            "v": 1,
            "provider": self.config.protocol.as_str(),
            "scope_id": self.id.to_string(),
            "sequence": sequence,
            "kind": kind,
            "payload": payload,
        });
        let Ok(bytes) = serde_json::to_vec(&envelope) else {
            return;
        };
        let Some((hub, scope)) = self
            .event_sink
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
        else {
            return;
        };
        let input = if terminal {
            EventInput {
                kind: RuntimeEventKind::Terminal,
                class: EventClass::Lossless,
                payload: bytes,
                coalesce_key: None,
            }
        } else {
            EventInput {
                kind: RuntimeEventKind::Data,
                class: EventClass::Lossless,
                payload: bytes,
                coalesce_key: None,
            }
        };
        let _ = hub.publish(&self.identity, &scope, input);
    }
}

fn bounded_provider_preview(line: &[u8]) -> String {
    let bytes = &line[..line.len().min(300)];
    String::from_utf8_lossy(bytes).into_owned()
}

fn codex_numeric_id_key(value: u64) -> String {
    format!("n:{value}")
}

fn codex_id_key(value: &Value) -> Option<String> {
    match value {
        Value::Number(number) => number.as_u64().map(codex_numeric_id_key),
        Value::String(value) if !value.is_empty() => Some(format!("s:{value}")),
        _ => None,
    }
}

fn apply_acp_request_started(state: &mut AcpState, method: &str) {
    if method == "session/prompt" {
        state.prompt_generation = state.prompt_generation.saturating_add(1);
        state.active_prompt_generation = Some(state.prompt_generation);
        state.lifecycle = "promptRunning".to_owned();
    }
}

fn apply_acp_request_succeeded(state: &mut AcpState, method: &str, result: &Value) {
    match method {
        "initialize" => {
            state.initialized = true;
            state.lifecycle = "initialized".to_owned();
        }
        "authenticate" => {
            state.authenticated = true;
            state.lifecycle = "authenticated".to_owned();
        }
        "session/new" | "session/load" => {
            if let Some(session_id) = result.get("sessionId").and_then(Value::as_str) {
                if state.session_id.as_deref() != Some(session_id) {
                    state.session_generation = state.session_generation.saturating_add(1);
                }
                state.session_id = Some(session_id.to_owned());
                state.lifecycle = "sessionOpen".to_owned();
            }
        }
        "session/prompt" => {
            state.active_prompt_generation = None;
            state.lifecycle = "sessionOpen".to_owned();
        }
        "session/cancel" => {
            state.active_prompt_generation = None;
            if state.session_id.is_some() {
                state.lifecycle = "sessionOpen".to_owned();
            }
        }
        _ => {}
    }
}

fn apply_acp_request_failed(state: &mut AcpState, method: &str) {
    if method == "session/prompt" {
        state.active_prompt_generation = None;
        if state.session_id.is_some() {
            state.lifecycle = "sessionOpen".to_owned();
        }
    }
}

fn apply_acp_notification(state: &mut AcpState, method: &str, payload: &Value) {
    if method != "session/cancel" {
        return;
    }
    let requested_session = payload
        .get("params")
        .and_then(|params| params.get("sessionId"))
        .and_then(Value::as_str);
    if requested_session.is_none() || state.session_id.as_deref() == requested_session {
        state.active_prompt_generation = None;
        if state.session_id.is_some() {
            state.lifecycle = "sessionOpen".to_owned();
        }
    }
}

fn update_codex_lifecycle(state: &mut CodexState, method: &str, result: &Value) {
    match method {
        "initialize" => {
            state.initialized = true;
            state.lifecycle = "initialized".to_owned();
        }
        "thread/start" | "thread/resume" => {
            state.lifecycle = "threadReady".to_owned();
            state.thread_id = result
                .get("thread")
                .and_then(|thread| thread.get("id"))
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
                .or_else(|| {
                    result
                        .get("threadId")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                });
        }
        "turn/start" => {
            state.lifecycle = "turnStarted".to_owned();
            state.turn_id = result
                .get("turn")
                .and_then(|turn| turn.get("id"))
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
                .or_else(|| {
                    result
                        .get("turnId")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                });
        }
        _ => {}
    }
}

/// Converts one framed stdout line into either a Rust-owned Codex/ACP semantic event or
/// Rust-owned Claude headless stream results. The translator is
/// kept on the single stdout reader thread, preserving FIFO and tool-use correlation without
/// introducing a second semantic consumer or an unbounded intermediate queue.
fn publish_provider_line(
    scope: &Arc<AgentProviderScope>,
    pid: i32,
    translator: &mut Option<Translator>,
    line: &[u8],
) {
    if scope.config.protocol == ProviderProtocol::CodexAppServer {
        scope.ingest_codex_line(pid, line);
        return;
    }
    if scope.config.protocol == ProviderProtocol::Acp {
        scope.ingest_acp_line(pid, line);
        return;
    }
    if let Some(translator) = translator {
        for result in translator.parse_ndjson_line(line) {
            if should_suppress_user_facing_stream_result(&result) {
                continue;
            }
            scope.publish(
                "streamResult",
                json!({
                    "pid": pid,
                    "result": stream_result_wire_fields(&result),
                }),
                false,
            );
        }
        return;
    }
    let payload = serde_json::from_slice::<Value>(line)
        .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(line).into_owned()));
    scope.publish(
        "providerMessage",
        json!({ "pid": pid, "payload": payload }),
        false,
    );
}

impl Drop for AgentProviderScope {
    /// Best-effort orphan backstop when a runtime or registry is dropped without an explicit
    /// shutdown. The owned reaper token proves this scope was the sole process owner; converting
    /// it to orphan provenance lets the shared reaper reclaim the entry without a per-process
    /// cleanup thread or a stale PID signal race.
    fn drop(&mut self) {
        let process = self
            .state
            .get_mut()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .process
            .take();
        if let Some(handle) = process {
            let reaper = Arc::clone(&self.reaper);
            let _ = thread::Builder::new()
                .name("agent-provider-orphan-backstop".into())
                .spawn(move || {
                    let _ = process::reaper::terminate_and_orphan(
                        &reaper,
                        handle.pid,
                        handle.reaper_token,
                        Duration::from_millis(50),
                        Duration::from_secs(2),
                    );
                });
        }
    }
}

macro_rules! uuid_id {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
        pub struct $name([u8; 16]);
        impl $name {
            pub fn mint() -> Self {
                Self(crate::inventory_scope::UuidMinter::fresh().next_bytes())
            }
            pub const fn from_bytes(bytes: [u8; 16]) -> Self {
                Self(bytes)
            }
            pub const fn as_bytes(&self) -> &[u8; 16] {
                &self.0
            }
            pub fn to_subscription_scope_id(&self) -> ScopeId {
                ScopeId::from_u128(u128::from_be_bytes(self.0))
            }
        }
        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                for byte in &self.0 {
                    write!(f, "{byte:02x}")?;
                }
                Ok(())
            }
        }
        impl std::str::FromStr for $name {
            type Err = ();
            fn from_str(value: &str) -> Result<Self, Self::Err> {
                if value.len() != 32 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                    return Err(());
                }
                let mut bytes = [0u8; 16];
                for (index, chunk) in value.as_bytes().chunks_exact(2).enumerate() {
                    bytes[index] =
                        u8::from_str_radix(std::str::from_utf8(chunk).map_err(|_| ())?, 16)
                            .map_err(|_| ())?;
                }
                Ok(Self(bytes))
            }
        }
    };
}

uuid_id!(AgentProviderScopeId);

pub struct ScopeRegistry {
    scopes: Mutex<HashMap<AgentProviderScopeId, Arc<AgentProviderScope>>>,
    reaper: Arc<Reaper>,
}

impl ScopeRegistry {
    pub fn new() -> Self {
        Self {
            scopes: Mutex::new(HashMap::new()),
            reaper: Reaper::new(),
        }
    }

    pub fn open_scope(
        &self,
        identity: RuntimeIdentity,
        config: AgentProviderScopeConfig,
    ) -> Arc<AgentProviderScope> {
        let id = AgentProviderScopeId::mint();
        let scope = AgentProviderScope::new(identity, id, config, Arc::clone(&self.reaper));
        self.scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(id, Arc::clone(&scope));
        scope
    }

    pub fn scope(&self, id: AgentProviderScopeId) -> Option<Arc<AgentProviderScope>> {
        self.scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&id)
            .cloned()
    }

    pub fn close_scope(
        &self,
        identity: &RuntimeIdentity,
        id: AgentProviderScopeId,
    ) -> Result<(), ScopeRegistryError> {
        let scope = self
            .scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&id);
        let Some(scope) = scope else {
            return Ok(());
        };
        if &scope.identity != identity {
            self.scopes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(id, scope);
            return Err(ScopeRegistryError::IdentityMismatch);
        }
        let _ = scope.shutdown(identity);
        Ok(())
    }

    pub fn scope_count(&self) -> usize {
        self.scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .len()
    }
}

impl Default for ScopeRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{RuntimeIdentity, SubscriptionConfig, SubscriptionHub};

    fn identity() -> RuntimeIdentity {
        RuntimeIdentity::new(
            1,
            "0123456789abcdef0123456789abcdef",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
        )
        .unwrap()
    }

    #[test]
    fn protocol_names_are_stable() {
        assert_eq!(ProviderProtocol::CodexAppServer.as_str(), "codexAppServer");
        assert_eq!(ProviderProtocol::Acp.as_str(), "acp");
        assert_eq!(ProviderProtocol::ClaudeHeadless.as_str(), "claudeHeadless");
    }

    #[test]
    fn conformance_profiles_match_exact_provider_matrix() {
        let codex = agent_provider_conformance_snapshot(ProviderProtocol::CodexAppServer);
        assert_eq!(
            codex.schema_version,
            AGENT_PROVIDER_CONFORMANCE_SCHEMA_VERSION
        );
        assert!(codex.owns_process_lifetime);
        assert!(codex.owns_line_framing);
        assert!(codex.serializes_stdin_writes);
        assert!(codex.emits_ordered_events);
        assert!(codex.bounds_stderr);
        assert!(codex.emits_process_exit_terminal_event);
        assert!(codex.supports_semantic_requests);
        assert!(codex.supports_typed_notifications);
        assert!(codex.supports_typed_server_requests);
        assert!(codex.supports_typed_state);
        assert!(codex.supports_token_cancellation);
        assert!(!codex.supports_typed_control_receipts);
        assert!(codex.preserves_json_rpc_id_type);
        assert!(!codex.supports_generic_send_line);
        assert!(!codex.supports_start_with_stdin);
        assert!(!codex.translates_stream_results);

        let acp = agent_provider_conformance_snapshot(ProviderProtocol::Acp);
        assert_eq!(acp.protocol, ProviderProtocol::Acp);
        assert!(acp.supports_semantic_requests);
        assert!(acp.supports_typed_notifications);
        assert!(acp.supports_typed_server_requests);
        assert!(acp.supports_typed_state);
        assert!(acp.supports_token_cancellation);
        assert!(acp.supports_typed_control_receipts);
        assert!(acp.preserves_json_rpc_id_type);
        assert!(!acp.supports_generic_send_line);
        assert!(!acp.supports_start_with_stdin);
        assert!(!acp.translates_stream_results);

        let claude = agent_provider_conformance_snapshot(ProviderProtocol::ClaudeHeadless);
        assert_eq!(claude.protocol, ProviderProtocol::ClaudeHeadless);
        assert!(claude.owns_process_lifetime);
        assert!(claude.owns_line_framing);
        assert!(claude.serializes_stdin_writes);
        assert!(claude.emits_ordered_events);
        assert!(claude.bounds_stderr);
        assert!(claude.emits_process_exit_terminal_event);
        assert!(!claude.supports_semantic_requests);
        assert!(!claude.supports_typed_notifications);
        assert!(!claude.supports_typed_server_requests);
        assert!(!claude.supports_typed_state);
        assert!(!claude.supports_token_cancellation);
        assert!(!claude.supports_typed_control_receipts);
        assert!(!claude.preserves_json_rpc_id_type);
        assert!(claude.supports_generic_send_line);
        assert!(claude.supports_start_with_stdin);
        assert!(claude.translates_stream_results);
    }

    #[test]
    fn conformance_validator_accepts_profiles_and_reports_deterministic_mutations() {
        let protocols = [
            ProviderProtocol::CodexAppServer,
            ProviderProtocol::Acp,
            ProviderProtocol::ClaudeHeadless,
        ];
        for protocol in protocols {
            let snapshot = agent_provider_conformance_snapshot(protocol);
            let validation = validate_agent_provider_conformance(&snapshot);
            assert!(validation.valid);
            assert!(validation.violations.is_empty());
            assert_eq!(
                validation.schema_version,
                AGENT_PROVIDER_CONFORMANCE_SCHEMA_VERSION
            );
            assert_eq!(validation.protocol, protocol);
        }

        let mut snapshot = agent_provider_conformance_snapshot(ProviderProtocol::Acp);
        snapshot.schema_version = 99;
        snapshot.owns_process_lifetime = false;
        snapshot.owns_line_framing = false;
        snapshot.serializes_stdin_writes = false;
        snapshot.emits_ordered_events = false;
        snapshot.bounds_stderr = false;
        snapshot.emits_process_exit_terminal_event = false;
        snapshot.supports_semantic_requests = false;
        snapshot.supports_typed_notifications = false;
        snapshot.supports_typed_server_requests = false;
        snapshot.supports_typed_state = false;
        snapshot.supports_token_cancellation = false;
        snapshot.supports_typed_control_receipts = false;
        snapshot.preserves_json_rpc_id_type = false;
        snapshot.supports_generic_send_line = true;
        snapshot.supports_start_with_stdin = true;
        snapshot.translates_stream_results = true;
        let validation = validate_agent_provider_conformance(&snapshot);
        assert!(!validation.valid);
        assert_eq!(
            validation.violations,
            vec![
                AgentProviderConformanceViolation::SchemaVersionMismatch,
                AgentProviderConformanceViolation::ProcessLifetimeMismatch,
                AgentProviderConformanceViolation::FramingMismatch,
                AgentProviderConformanceViolation::SerializedWritesMismatch,
                AgentProviderConformanceViolation::OrderedEventsMismatch,
                AgentProviderConformanceViolation::StderrBoundMismatch,
                AgentProviderConformanceViolation::ProcessExitEventMismatch,
                AgentProviderConformanceViolation::SemanticRequestsMismatch,
                AgentProviderConformanceViolation::TypedNotificationsMismatch,
                AgentProviderConformanceViolation::TypedServerRequestsMismatch,
                AgentProviderConformanceViolation::TypedStateMismatch,
                AgentProviderConformanceViolation::TokenCancellationMismatch,
                AgentProviderConformanceViolation::TypedControlReceiptsMismatch,
                AgentProviderConformanceViolation::JsonRpcIdTypePreservationMismatch,
                AgentProviderConformanceViolation::GenericSendLineMismatch,
                AgentProviderConformanceViolation::StartWithStdinMismatch,
                AgentProviderConformanceViolation::StreamResultTranslationMismatch,
            ]
        );
    }

    #[test]
    fn conformance_queries_are_identity_bound_and_side_effect_free() {
        let runtime_identity = identity();
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            runtime_identity.clone(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec!["-c".into(), "sleep 1".into()],
                environment: Vec::new(),
                working_directory: None,
                protocol: ProviderProtocol::CodexAppServer,
                max_stderr_bytes: 1024,
            },
        );
        let before = scope
            .conformance_snapshot(&runtime_identity)
            .expect("snapshot before start");
        assert_eq!(
            before,
            agent_provider_conformance_snapshot(ProviderProtocol::CodexAppServer)
        );
        assert_eq!(
            scope
                .validate_conformance(&runtime_identity)
                .expect("validation")
                .valid,
            true
        );
        assert_eq!(
            scope.conformance_snapshot(
                &RuntimeIdentity::new(
                    1,
                    "0123456789abcdef0123456789abcdef",
                    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde0",
                    "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
                )
                .unwrap()
            ),
            Err(AgentProviderScopeError::IdentityMismatch)
        );
        scope.start(&runtime_identity).expect("start");
        let after = scope
            .conformance_snapshot(&runtime_identity)
            .expect("snapshot after start");
        assert_eq!(after, before);
        scope.shutdown(&runtime_identity).expect("shutdown");
    }

    #[test]
    fn acp_scope_rejects_opaque_send_line() {
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec![],
                environment: vec![],
                working_directory: None,
                protocol: ProviderProtocol::Acp,
                max_stderr_bytes: 1024,
            },
        );
        assert_eq!(
            scope.send_line(&identity(), br#"{"method":"legacy"}"#),
            Err(AgentProviderScopeError::InvalidArgument(
                "acp scopes require acp request/notify/respond APIs",
            ))
        );
    }

    #[test]
    fn codex_scope_rejects_opaque_send_line() {
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec![],
                environment: vec![],
                working_directory: None,
                protocol: ProviderProtocol::CodexAppServer,
                max_stderr_bytes: 1024,
            },
        );
        assert_eq!(
            scope.send_line(&identity(), br#"{"method":"legacy"}"#),
            Err(AgentProviderScopeError::InvalidArgument(
                "codex scopes require codex request/notify/respond APIs",
            ))
        );
    }

    #[test]
    fn codex_request_is_resolved_by_rust_and_tracks_lifecycle() {
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec![
                    "-c".into(),
                    "IFS= read -r line; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}'".into(),
                ],
                environment: Vec::new(),
                working_directory: None,
                protocol: ProviderProtocol::CodexAppServer,
                max_stderr_bytes: 1024,
            },
        );
        scope
            .start(&identity())
            .expect("codex process should start");
        let response = scope
            .codex_request(
                &identity(),
                "initialize",
                None,
                Some(Duration::from_secs(2)),
                None,
            )
            .expect("codex response should resolve");
        let value: Value = serde_json::from_slice(&response).expect("response JSON");
        assert_eq!(value["ok"], true);
        let state = scope.codex_state(&identity()).expect("codex state");
        assert!(state.pending_request_count == 0);
        assert!(state.initialized);
        assert_eq!(state.lifecycle, "initialized");
        scope.shutdown(&identity()).expect("codex shutdown");
    }

    #[test]
    fn codex_remote_error_and_timeout_are_typed_and_fail_closed() {
        let registry = ScopeRegistry::new();
        let error_scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec![
                    "-c".into(),
                    "IFS= read -r line; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"missing\",\"data\":{\"hint\":\"missing method\"}}}'".into(),
                ],
                environment: Vec::new(),
                working_directory: None,
                protocol: ProviderProtocol::CodexAppServer,
                max_stderr_bytes: 1024,
            },
        );
        error_scope
            .start(&identity())
            .expect("codex error process should start");
        assert_eq!(
            error_scope.codex_request(
                &identity(),
                "models/list",
                None,
                Some(Duration::from_secs(2)),
                None
            ),
            Err(AgentProviderScopeError::CodexRemoteError {
                method: "models/list".into(),
                code: -32601,
                message: "missing".into(),
                data: Some(br#"{"hint":"missing method"}"#.to_vec()),
            })
        );
        error_scope.shutdown(&identity()).expect("error shutdown");

        let timeout_scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec!["-c".into(), "IFS= read -r line; sleep 1".into()],
                environment: Vec::new(),
                working_directory: None,
                protocol: ProviderProtocol::CodexAppServer,
                max_stderr_bytes: 1024,
            },
        );
        timeout_scope
            .start(&identity())
            .expect("codex timeout process should start");
        assert_eq!(
            timeout_scope.codex_request(
                &identity(),
                "initialize",
                None,
                Some(Duration::from_millis(20)),
                None
            ),
            Err(AgentProviderScopeError::CodexTimedOut("initialize".into()))
        );
        timeout_scope
            .shutdown(&identity())
            .expect("timeout shutdown");
    }

    #[test]
    fn acp_request_tracks_typed_response_and_lifecycle() {
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec![
                    "-c".into(),
                    "IFS= read -r line; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"s-1\"}}'".into(),
                ],
                environment: Vec::new(),
                working_directory: None,
                protocol: ProviderProtocol::Acp,
                max_stderr_bytes: 1024,
            },
        );
        scope.start(&identity()).expect("acp process should start");
        let response = scope
            .acp_request(
                &identity(),
                "session/new",
                Some(br#"{"cwd":"/tmp"}"#),
                Some(Duration::from_secs(2)),
                Some("acp-request-test"),
            )
            .expect("acp response should resolve");
        let value: Value = serde_json::from_slice(&response.result).expect("response JSON");
        assert_eq!(value["sessionId"], "s-1");
        assert!(response.inbound_sequence > 0);
        let state = scope.acp_state(&identity()).expect("acp state");
        assert!(!state.initialized);
        assert!(!state.authenticated);
        assert_eq!(state.pending_request_count, 0);
        assert_eq!(state.session_id.as_deref(), Some("s-1"));
        assert_eq!(state.session_generation, 1);
        assert_eq!(state.prompt_generation, 0);
        assert_eq!(state.active_prompt_generation, None);
        assert_eq!(state.lifecycle, "sessionOpen");
        scope.shutdown(&identity()).expect("acp shutdown");
    }

    #[test]
    fn acp_lifecycle_transitions_are_generation_fenced() {
        let mut state = AcpState {
            rpc: JsonRpcState::new(),
            initialized: false,
            authenticated: false,
            lifecycle: "running".to_owned(),
            session_id: None,
            session_generation: 0,
            prompt_generation: 0,
            active_prompt_generation: None,
        };
        apply_acp_request_succeeded(&mut state, "initialize", &json!({}));
        assert!(state.initialized);
        assert_eq!(state.lifecycle, "initialized");
        apply_acp_request_succeeded(&mut state, "authenticate", &json!({}));
        assert!(state.authenticated);
        assert_eq!(state.lifecycle, "authenticated");
        apply_acp_request_succeeded(&mut state, "session/new", &json!({ "sessionId": "s-1" }));
        assert_eq!(state.session_generation, 1);
        assert_eq!(state.session_id.as_deref(), Some("s-1"));
        apply_acp_request_started(&mut state, "session/prompt");
        assert_eq!(state.prompt_generation, 1);
        assert_eq!(state.active_prompt_generation, Some(1));
        assert_eq!(state.lifecycle, "promptRunning");
        apply_acp_request_succeeded(&mut state, "session/prompt", &json!({}));
        assert_eq!(state.active_prompt_generation, None);
        assert_eq!(state.lifecycle, "sessionOpen");
        apply_acp_notification(
            &mut state,
            "session/cancel",
            &json!({ "params": { "sessionId": "s-1" } }),
        );
        assert_eq!(state.session_generation, 1);
        assert_eq!(state.prompt_generation, 1);
    }

    #[test]
    fn acp_remote_error_and_timeout_are_typed() {
        let registry = ScopeRegistry::new();
        let error_scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec![
                    "-c".into(),
                    "IFS= read -r line; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"missing\",\"data\":{\"hint\":\"nope\"}}}'".into(),
                ],
                environment: Vec::new(),
                working_directory: None,
                protocol: ProviderProtocol::Acp,
                max_stderr_bytes: 1024,
            },
        );
        error_scope
            .start(&identity())
            .expect("acp error process should start");
        assert_eq!(
            error_scope.acp_request(
                &identity(),
                "session/new",
                None,
                Some(Duration::from_secs(2)),
                None
            ),
            Err(AgentProviderScopeError::AcpRemoteError {
                method: "session/new".into(),
                code: -32601,
                message: "missing".into(),
                data: Some(br#"{"hint":"nope"}"#.to_vec()),
            })
        );
        error_scope
            .shutdown(&identity())
            .expect("acp error shutdown");

        let timeout_scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec!["-c".into(), "IFS= read -r line; sleep 1".into()],
                environment: Vec::new(),
                working_directory: None,
                protocol: ProviderProtocol::Acp,
                max_stderr_bytes: 1024,
            },
        );
        timeout_scope
            .start(&identity())
            .expect("acp timeout process should start");
        assert_eq!(
            timeout_scope.acp_request(
                &identity(),
                "initialize",
                None,
                Some(Duration::from_millis(20)),
                None
            ),
            Err(AgentProviderScopeError::AcpTimedOut("initialize".into()))
        );
        timeout_scope
            .shutdown(&identity())
            .expect("acp timeout shutdown");
    }

    #[test]
    fn acp_cancel_notification_rejects_stale_session_generation() {
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec![
                    "-c".into(),
                    "IFS= read -r line; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"s-1\"}}'; IFS= read -r line; sleep 1".into(),
                ],
                environment: Vec::new(),
                working_directory: None,
                protocol: ProviderProtocol::Acp,
                max_stderr_bytes: 1024,
            },
        );
        scope.start(&identity()).expect("acp process should start");
        let response = scope
            .acp_request(
                &identity(),
                "session/new",
                None,
                Some(Duration::from_secs(2)),
                None,
            )
            .expect("session should open");
        assert_eq!(response.session_generation, 1);
        assert_eq!(
            scope.acp_notify(&identity(), "session/cancel", None, Some(0)),
            Err(AgentProviderScopeError::InvalidArgument(
                "stale ACP session generation",
            ))
        );
        let receipt = scope
            .acp_notify(
                &identity(),
                "session/cancel",
                Some(br#"{"sessionId":"s-1"}"#),
                Some(1),
            )
            .expect("current session cancellation should write");
        assert_eq!(receipt.session_generation, 1);
        scope.shutdown(&identity()).expect("acp shutdown");
    }

    #[test]
    fn acp_events_are_typed_and_protocol_failures_are_observable() {
        let runtime_identity = identity();
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            runtime_identity.clone(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec![
                    "-c".into(),
                    "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"ok\":true}}' '{\"jsonrpc\":\"2.0\",\"id\":\"server-1\",\"method\":\"session/request_permission\",\"params\":{}}' 'not-json'".into(),
                ],
                environment: Vec::new(),
                working_directory: None,
                protocol: ProviderProtocol::Acp,
                max_stderr_bytes: 1024,
            },
        );
        let subscription_scope = scope.id().to_subscription_scope_id();
        let hub = Arc::new(SubscriptionHub::new(runtime_identity.clone()).expect("hub"));
        let bootstrap = hub
            .open_subscription(
                &runtime_identity,
                subscription_scope.clone(),
                SubscriptionConfig::default(),
                Vec::new,
            )
            .expect("subscription");
        scope.attach_event_sink(Arc::clone(&hub), subscription_scope);
        scope
            .start(&runtime_identity)
            .expect("acp process should start");
        std::thread::sleep(Duration::from_millis(100));
        let drained = hub
            .try_drain(
                &runtime_identity,
                bootstrap.subscription_id,
                64,
                SubscriptionConfig::default().max_queued_bytes,
            )
            .expect("events should drain");
        let batch = match drained {
            crate::DrainOutcome::Batch(batch) => batch,
            crate::DrainOutcome::Oversize(_) => panic!("acp events should fit in the queue"),
        };
        let payloads: Vec<String> = batch
            .events
            .iter()
            .map(|event| String::from_utf8_lossy(&event.payload).into_owned())
            .collect();
        assert!(
            payloads
                .iter()
                .any(|payload| payload.contains("\"kind\":\"notification\""))
        );
        assert!(payloads.iter().any(|payload| payload.contains("server-1")));
        assert!(
            payloads
                .iter()
                .any(|payload| payload.contains("invalidJson"))
        );
        assert!(
            !payloads
                .iter()
                .any(|payload| payload.contains("providerMessage"))
        );
        assert!(
            batch
                .events
                .iter()
                .map(|event| event.authority_sequence)
                .collect::<Vec<_>>()
                .windows(2)
                .all(|pair| pair[0] < pair[1])
        );
        scope.shutdown(&runtime_identity).expect("acp shutdown");
    }

    #[test]
    fn acp_request_ids_preserve_json_type_and_wire_encoding() {
        let decimal: Value = serde_json::from_str("1.0").expect("decimal id");
        let numeric = JsonRpcId::from_value(&decimal).expect("numeric id");
        let string = JsonRpcId::from_value(&json!("1")).expect("string id");
        assert_eq!(numeric.encoded(), b"1.0");
        assert_ne!(numeric.key(), string.key());
        assert_eq!(string.encoded(), vec![b'\"', b'1', b'\"']);
    }

    #[test]
    fn codex_request_id_keys_preserve_json_type() {
        assert_ne!(codex_id_key(&json!(1)), codex_id_key(&json!("1")));
        assert_eq!(codex_id_key(&json!(1)), Some("n:1".to_owned()));
        assert_eq!(codex_id_key(&json!("1")), Some("s:1".to_owned()));
    }

    #[test]
    fn initial_stdin_is_exclusive_to_claude_headless() {
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: Vec::new(),
                environment: Vec::new(),
                working_directory: None,
                protocol: ProviderProtocol::Acp,
                max_stderr_bytes: 1024,
            },
        );
        assert_eq!(
            scope.start_with_stdin(&identity(), Some(b"prompt")),
            Err(AgentProviderScopeError::InvalidArgument(
                "initial_stdin requires claudeHeadless",
            ))
        );
    }

    #[test]
    fn scope_ids_are_lower_hex_and_round_trip() {
        let id = AgentProviderScopeId::mint();
        let parsed: AgentProviderScopeId = id.to_string().parse().unwrap();
        assert_eq!(parsed, id);
        assert!(
            id.to_string()
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        );
    }

    #[test]
    fn registry_rejects_identity_mismatch_without_losing_scope() {
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec![],
                environment: vec![],
                working_directory: None,
                protocol: ProviderProtocol::Acp,
                max_stderr_bytes: 8192,
            },
        );
        let other = RuntimeIdentity::new(
            1,
            "abcdefabcdefabcdefabcdefabcdefab",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
        )
        .unwrap();
        assert_eq!(
            registry.close_scope(&other, scope.id()),
            Err(ScopeRegistryError::IdentityMismatch)
        );
        assert_eq!(registry.scope_count(), 1);
    }

    #[test]
    fn scope_start_and_shutdown_are_process_owned() {
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            identity(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec!["-c".into(), "printf '{\"jsonrpc\":\"2.0\"}\\n'".into()],
                environment: vec![("P6_PROVIDER_TEST".into(), "1".into())],
                working_directory: None,
                protocol: ProviderProtocol::CodexAppServer,
                max_stderr_bytes: 1024,
            },
        );
        let receipt = scope
            .start(&identity())
            .expect("provider process should start");
        assert!(receipt.pid > 0);
        assert!(receipt.process_group_id > 0);
        scope
            .shutdown(&identity())
            .expect("provider process should shut down");
        assert_eq!(registry.close_scope(&identity(), scope.id()), Ok(()));
    }

    #[test]
    fn scope_publishes_ordered_provider_and_terminal_events() {
        let runtime_identity = identity();
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            runtime_identity.clone(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec!["-c".into(), "printf '{\"method\":\"ready\"}\\n'".into()],
                environment: vec![],
                working_directory: None,
                protocol: ProviderProtocol::Acp,
                max_stderr_bytes: 1024,
            },
        );
        let subscription_scope = scope.id().to_subscription_scope_id();
        let hub = Arc::new(SubscriptionHub::new(runtime_identity.clone()).expect("hub"));
        let bootstrap = hub
            .open_subscription(
                &runtime_identity,
                subscription_scope.clone(),
                SubscriptionConfig::default(),
                Vec::new,
            )
            .expect("subscription");
        scope.attach_event_sink(Arc::clone(&hub), subscription_scope);
        scope
            .start(&runtime_identity)
            .expect("provider process should start");
        std::thread::sleep(Duration::from_millis(100));
        let drained = hub
            .try_drain(
                &runtime_identity,
                bootstrap.subscription_id,
                64,
                SubscriptionConfig::default().max_queued_bytes,
            )
            .expect("events should drain");
        let batch = match drained {
            crate::DrainOutcome::Batch(batch) => batch,
            crate::DrainOutcome::Oversize(_) => panic!("provider events should fit in the queue"),
        };
        let sequences: Vec<u64> = batch
            .events
            .iter()
            .map(|event| event.authority_sequence)
            .collect();
        assert!(sequences.windows(2).all(|pair| pair[0] < pair[1]));
        let payloads: Vec<String> = batch
            .events
            .iter()
            .map(|event| String::from_utf8_lossy(&event.payload).into_owned())
            .collect();
        assert!(
            payloads
                .iter()
                .any(|payload| payload.contains("processStarted"))
        );
        assert!(
            payloads
                .iter()
                .any(|payload| payload.contains("\"kind\":\"notification\""))
        );
        assert!(
            payloads
                .iter()
                .any(|payload| payload.contains("processExited"))
        );
        scope
            .shutdown(&runtime_identity)
            .expect("provider process should shut down");
    }

    #[test]
    fn claude_headless_scope_translates_stream_json_and_closes_stdin() {
        let runtime_identity = identity();
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(
            runtime_identity.clone(),
            AgentProviderScopeConfig {
                command: "/bin/sh".into(),
                arguments: vec![
                    "-c".into(),
                    "cat >/dev/null; printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}' '{\"type\":\"result\",\"result\":\"hello\",\"session_id\":\"session-1\"}'".into(),
                ],
                environment: vec![],
                working_directory: None,
                protocol: ProviderProtocol::ClaudeHeadless,
                max_stderr_bytes: 1024,
            },
        );
        let subscription_scope = scope.id().to_subscription_scope_id();
        let hub = Arc::new(SubscriptionHub::new(runtime_identity.clone()).expect("hub"));
        let bootstrap = hub
            .open_subscription(
                &runtime_identity,
                subscription_scope.clone(),
                SubscriptionConfig::default(),
                Vec::new,
            )
            .expect("subscription");
        scope.attach_event_sink(Arc::clone(&hub), subscription_scope);
        scope
            .start_with_stdin(&runtime_identity, Some(b"prompt"))
            .expect("headless provider process should start");
        std::thread::sleep(Duration::from_millis(100));
        let drained = hub
            .try_drain(
                &runtime_identity,
                bootstrap.subscription_id,
                64,
                SubscriptionConfig::default().max_queued_bytes,
            )
            .expect("events should drain");
        let batch = match drained {
            crate::DrainOutcome::Batch(batch) => batch,
            crate::DrainOutcome::Oversize(_) => panic!("provider events should fit in the queue"),
        };
        let payloads: Vec<String> = batch
            .events
            .iter()
            .map(|event| String::from_utf8_lossy(&event.payload).into_owned())
            .collect();
        assert!(
            payloads
                .iter()
                .any(|payload| payload.contains("streamResult"))
        );
        assert!(payloads.iter().any(|payload| payload.contains("hello")));
        assert!(
            payloads
                .iter()
                .any(|payload| payload.contains("message_stop"))
        );
        assert!(payloads.iter().any(|payload| payload.contains("session-1")));
        assert!(
            payloads
                .iter()
                .any(|payload| payload.contains("processExited"))
        );
        assert!(
            !payloads
                .iter()
                .any(|payload| payload.contains("providerMessage"))
        );
        scope
            .shutdown(&runtime_identity)
            .expect("headless provider process should shut down");
    }
}
