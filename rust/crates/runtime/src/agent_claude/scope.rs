//! P6-6 (`docs/designs/p6-claude-vertical-2026-08-23.md` §3.4/§11, `docs/architecture/
//! rust-agent-claude-v1.md`): `AgentClaudeScope` -- the stateful integration object that wires
//! every cargo-only P6-3/P6-4/P6-5 primitive (framer, codec, recovery, translator, spawn, reaper,
//! control correlation, permission protocol, turn-lifecycle authority, the resnapshot buffer) into
//! one live Claude session, publishing through the same `SubscriptionHub` every other domain uses
//! (design §5.1). Mirrors `inventory_scope::scope`/`inventory_scope::registry`'s shape --
//! `ScopeRegistry` is the ID-addressed holder, `AgentClaudeScope` is the one stateful tenant --
//! but differs from it in one structural way the design calls out explicitly (§5.1): this scope
//! owns its own supervisor threads (the stdout/stderr readers, the interrupt round-trip thread),
//! while `InventoryScope`'s FFI is purely synchronous. Commands (`send_user_message`,
//! `interrupt_turn`, `respond_permission`, `apply_model_and_effort`, `shutdown`) stay fast,
//! identity-checked, and synchronous themselves (charter §8.2) -- only `interrupt_turn`'s actual
//! 1.5 s ACK wait is pushed onto a background thread, per contract §4.
//!
//! ## INV-P6-2 compliance: why this module does not reuse `process::reader::spawn_stdout_reader`
//!
//! P6-4's `spawn_stdout_reader` frames raw bytes into `process::queue::BoundedEventQueue` and
//! stops there ("framing only, not decode/translate", that module's own doc comment). INV-P6-2
//! requires "one reader per stream performs `read()` -> frame -> decode -> translate ->
//! non-blocking publish, **inline**" -- in the *same* thread, with no second hop. Draining
//! `BoundedEventQueue` from a second consumer thread would satisfy the queue's own non-blocking
//! contract but would add a third thread per session, silently breaking the frozen `2N + 1` budget
//! (contract §5.2, E-P6-2 Part B's pass criterion) that P6-4's synthetic-CLI matrix already
//! measured and locked in. This module therefore writes its own stdout pipeline
//! ([`spawn_stdout_pipeline`]) that performs every step -- `read()`, [`LineFramer::feed`], decode,
//! recovery, translate, turn-state update, resnapshot append, and [`SubscriptionHub::publish`] --
//! on one thread, reusing `LineFramer` directly rather than going through the queue-based reader.
//! `process::reader`/`process::queue` remain valid, independently tested P6-4 primitives; they are
//! simply not this scope's production stdout path. The stderr side has no decode step, so
//! `process::reader::spawn_stderr_reader` plus `process::stderr_tail::StderrTail` are reused
//! unmodified -- no thread-budget risk there, since that pairing already **is** the one thread the
//! stderr side needs.
//!
//! ## Scope reductions, named rather than silently taken
//!
//! - **`apply_model_and_effort`'s wire subtype is a placeholder.** The real Swift controller's
//!   flag-settings handshake (`session.flagSettingsDeferred`/`Pending`/`Applied`,
//!   `ClaudeNativeProcessSessionController.swift:425-443,717`) has launch-restart and pending-ack
//!   states this slice does not reproduce; P6-6's job is the FFI/bridge surface, not the full
//!   flag-settings state machine. This method sends a fire-and-forget `control_request` with
//!   subtype `"set_model_and_effort"` and no ACK tracking. Full parity is P6-7's job, where the
//!   turn-level differential is what actually needs live handshake state.
//! - **No dedicated resnapshot-fetch export.** The seven exports this step's done-when names do
//!   not include one; [`AgentClaudeScope::diagnostics`] exposes the resnapshot buffer's retained
//!   byte count and truncation counter so the machinery is testable end-to-end now, without
//!   inventing an eighth export a later step (P6-7, which actually needs to consume it for gap
//!   recovery) would own the real shape of.
//! - **`open_subscription`'s bootstrap snapshot is empty**, matching `inventory_scope`'s own
//!   existing precedent at this same generic FFI call site (`api.rs`'s `open_subscription` always
//!   passes `Vec::new`) -- no per-domain snapshot-provider hook exists yet in the generic
//!   subscription surface. A reattaching subscriber can read [`AgentClaudeScope::diagnostics`] for
//!   the terminal facts it needs today.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::{EventInput, RuntimeEventKind, RuntimeIdentity, ScopeId, SubscriptionHub};

use super::codec::{self, CodecError, ControlRequest, InboundMessage};
use super::control::{self, ControlCorrelator, ControlOutcome};
use super::event::{self, AgentClaudeEvent, AgentClaudeEventKind};
use super::framer::LineFramer;
use super::permission::{self, CanUseToolRequest, PermissionDecision};
use super::process::{self, reaper::Reaper, spawn::SpawnConfig, timer::SystemClock};
use super::recovery::{self, RecoveryOutcome};
use super::resnapshot::ResnapshotBuffer;
use super::translator::{StreamResult, Translator, should_suppress_user_facing_stream_result};
use super::tool_owned::is_repoprompt_tool_name;
use super::turn_state::{TurnEvent, TurnState};

macro_rules! uuid_id {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
        pub struct $name([u8; 16]);

        impl $name {
            /// Reuses `inventory_scope`'s process-entropy `UuidMinter` (already proven, already in
            /// this crate) rather than re-deriving a second minting scheme for one more sibling
            /// domain's opaque scope-id type.
            #[must_use]
            pub fn mint() -> Self {
                Self(crate::inventory_scope::UuidMinter::fresh().next_bytes())
            }

            #[must_use]
            pub const fn from_bytes(bytes: [u8; 16]) -> Self {
                Self(bytes)
            }

            #[must_use]
            pub const fn as_bytes(&self) -> &[u8; 16] {
                &self.0
            }

            #[must_use]
            pub fn to_subscription_scope_id(&self) -> ScopeId {
                ScopeId::from_u128(u128::from_be_bytes(self.0))
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                for byte in &self.0 {
                    write!(formatter, "{byte:02x}")?;
                }
                Ok(())
            }
        }
    };
}

uuid_id!(AgentClaudeScopeId);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentClaudeScopeIdParseError {
    WrongLength,
    InvalidHex,
}

impl std::str::FromStr for AgentClaudeScopeId {
    type Err = AgentClaudeScopeIdParseError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        if value.len() != 32 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(AgentClaudeScopeIdParseError::WrongLength);
        }
        let mut bytes = [0u8; 16];
        for (index, chunk) in value.as_bytes().chunks_exact(2).enumerate() {
            let text = std::str::from_utf8(chunk).map_err(|_| AgentClaudeScopeIdParseError::InvalidHex)?;
            bytes[index] = u8::from_str_radix(text, 16).map_err(|_| AgentClaudeScopeIdParseError::InvalidHex)?;
        }
        Ok(Self::from_bytes(bytes))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentScopeError {
    IdentityMismatch,
    ScopeClosed,
    AlreadyRunning,
    NotRunning,
    UnknownScope,
    UnknownPermissionRequest,
    Spawn(String),
    Reaper(String),
    TransportWrite(String),
    InvalidArgument(&'static str),
}

impl std::fmt::Display for AgentScopeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::IdentityMismatch => write!(f, "stale runtime identity"),
            Self::ScopeClosed => write!(f, "agent scope is closed"),
            Self::AlreadyRunning => write!(f, "agent scope already has a running process"),
            Self::NotRunning => write!(f, "agent scope has no running process"),
            Self::UnknownScope => write!(f, "unknown agent scope"),
            Self::UnknownPermissionRequest => write!(f, "unknown permission request id"),
            Self::Spawn(message) => write!(f, "spawn failed: {message}"),
            Self::Reaper(message) => write!(f, "reaper registration failed: {message}"),
            Self::TransportWrite(message) => write!(f, "transport write failed: {message}"),
            Self::InvalidArgument(what) => write!(f, "invalid argument: {what}"),
        }
    }
}

impl std::error::Error for AgentScopeError {}

/// A caller-facing permission decision -- the FFI-facing counterpart of
/// [`super::permission::PermissionDecision`], collapsing `include_updated_permissions` /
/// `message`+`interrupt` into the same two-case shape the protocol module already defines. Kept
/// as a distinct type at this layer only so the FFI crate (P6-6's next commit) has a stable,
/// scope-owned name to build its own wire record against, rather than re-exporting the protocol
/// module's type directly into the FFI surface.
#[derive(Debug, Clone, PartialEq)]
pub enum PermissionDecisionInput {
    Allow { include_updated_permissions: bool },
    Deny { message: String, interrupt: bool },
}

impl From<PermissionDecisionInput> for PermissionDecision {
    fn from(value: PermissionDecisionInput) -> Self {
        match value {
            PermissionDecisionInput::Allow { include_updated_permissions } => {
                PermissionDecision::Allow { include_updated_permissions }
            }
            PermissionDecisionInput::Deny { message, interrupt } => PermissionDecision::Deny { message, interrupt },
        }
    }
}

#[derive(Debug, Clone)]
pub struct AgentClaudeScopeConfig {
    pub command: String,
    /// Extra trailing argv appended after every contract §2.5 flag this module injects. Also
    /// doubles as the *entire* argv when [`Self::raw_argv_for_testing`] is set (this module's own
    /// tests point `command`/`arguments` at `agent-claude-synthetic-cli`, which does not
    /// understand the real CLI's flag grammar).
    pub arguments: Vec<String>,
    /// The already-resolved environment map (design §5.1: Swift keeps resolving Keychain/
    /// sanitizer/carrier merge; this is the final map). Never logged (R8) -- callers must not
    /// attach this to any diagnostic sink, including this crate's own `RuntimeEvent` stream.
    pub environment: Vec<(String, String)>,
    pub working_directory: Option<String>,
    pub permission_mode: Option<String>,
    pub mcp_config_path: Option<String>,
    pub mcp_strict_mode: bool,
    pub disallowed_built_in_tools: Vec<String>,
    /// GLM's `--append-system-prompt` workaround (contract §2.5 item 1) -- carried but inert for
    /// `claudeCode` (`None` in every production `claudeCode` configuration).
    pub append_system_prompt: Option<String>,
    pub idle_fallback: Duration,
    pub interrupt_ack_timeout: Duration,
    /// Test-only escape hatch: see this module's doc comment. Never set outside a test scope.
    pub raw_argv_for_testing: bool,
}

impl Default for AgentClaudeScopeConfig {
    fn default() -> Self {
        Self {
            command: String::new(),
            arguments: Vec::new(),
            environment: Vec::new(),
            working_directory: None,
            permission_mode: None,
            mcp_config_path: None,
            mcp_strict_mode: false,
            disallowed_built_in_tools: Vec::new(),
            append_system_prompt: None,
            idle_fallback: super::turn_state::DEFAULT_IDLE_FALLBACK,
            interrupt_ack_timeout: Duration::from_millis(1500),
            raw_argv_for_testing: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StartReceipt {
    pub pid: i32,
    pub process_group_id: i32,
}

struct ProcessHandle {
    pid: i32,
    reaper_token: u64,
}

#[derive(Clone)]
struct EventSink {
    hub: Arc<SubscriptionHub>,
    scope_id: ScopeId,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct AgentClaudeScopeDiagnostics {
    pub turn_generation: u64,
    pub turn_in_flight: bool,
    pub resnapshot_bytes_retained: u64,
    pub resnapshot_truncation_count: u64,
    pub framer_overflow_count: u64,
    pub protocol_drift_count: u64,
    pub pending_permission_count: u64,
    pub publish_failure_count: u64,
}

struct Inner {
    closed: bool,
    process: Option<ProcessHandle>,
    turns: TurnState<SystemClock>,
    translator: Translator,
    resnapshot: ResnapshotBuffer,
    pending_permissions: HashMap<String, CanUseToolRequest>,
    last_turn_generation: u64,
    resnapshot_truncation_count: u64,
    framer_overflow_count: u64,
    protocol_drift_count: u64,
}

/// One live Claude session. Constructed only by [`ScopeRegistry::open_scope`]; addressed by
/// [`AgentClaudeScopeId`], never by a proxy object (mirrors `InventoryScope`'s contract).
pub struct AgentClaudeScope {
    identity: RuntimeIdentity,
    scope_id: AgentClaudeScopeId,
    config: AgentClaudeScopeConfig,
    reaper: Arc<Reaper>,
    control: ControlCorrelator,
    state: Mutex<Inner>,
    stdin: Mutex<Option<File>>,
    reader_threads: Mutex<Vec<JoinHandle<()>>>,
    event_sink: Mutex<Option<EventSink>>,
    next_request_id: AtomicU64,
    publish_failure_count: AtomicU64,
}

impl AgentClaudeScope {
    fn new(identity: RuntimeIdentity, scope_id: AgentClaudeScopeId, config: AgentClaudeScopeConfig, reaper: Arc<Reaper>) -> Self {
        let idle_fallback = config.idle_fallback;
        Self {
            identity,
            scope_id,
            config,
            reaper,
            control: ControlCorrelator::new(),
            state: Mutex::new(Inner {
                closed: false,
                process: None,
                turns: TurnState::with_idle_fallback(Arc::new(SystemClock), idle_fallback),
                translator: Translator::new(Box::new(is_repoprompt_tool_name)),
                resnapshot: ResnapshotBuffer::new(),
                pending_permissions: HashMap::new(),
                last_turn_generation: 0,
                resnapshot_truncation_count: 0,
                framer_overflow_count: 0,
                protocol_drift_count: 0,
            }),
            stdin: Mutex::new(None),
            reader_threads: Mutex::new(Vec::new()),
            event_sink: Mutex::new(None),
            next_request_id: AtomicU64::new(1),
            publish_failure_count: AtomicU64::new(0),
        }
    }

    #[must_use]
    pub const fn scope_id(&self) -> AgentClaudeScopeId {
        self.scope_id
    }

    #[must_use]
    pub const fn identity(&self) -> &RuntimeIdentity {
        &self.identity
    }

    /// Wires this scope's event-plane publication into the shared `SubscriptionHub`, mirroring
    /// `InventoryScope::attach_event_sink` exactly (same doc rationale: called once by the FFI
    /// layer immediately after minting the scope; idempotent).
    pub fn attach_event_sink(&self, hub: Arc<SubscriptionHub>, scope_id: ScopeId) {
        *self.event_sink.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(EventSink { hub, scope_id });
    }

    fn check_identity(&self, identity: &RuntimeIdentity) -> Result<(), AgentScopeError> {
        if &self.identity == identity { Ok(()) } else { Err(AgentScopeError::IdentityMismatch) }
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    #[must_use]
    pub fn diagnostics(&self) -> AgentClaudeScopeDiagnostics {
        let state = self.lock_state();
        AgentClaudeScopeDiagnostics {
            turn_generation: state.last_turn_generation,
            turn_in_flight: state.turns.has_pending_turn_ids(),
            resnapshot_bytes_retained: state.resnapshot.len() as u64,
            resnapshot_truncation_count: state.resnapshot_truncation_count,
            framer_overflow_count: state.framer_overflow_count,
            protocol_drift_count: state.protocol_drift_count,
            pending_permission_count: state.pending_permissions.len() as u64,
            publish_failure_count: self.publish_failure_count.load(Ordering::Relaxed),
        }
    }

    // ---- Commands (charter §8.2: fast, synchronous, identity-checked, handle-based) ----------

    /// Contract §5.1: spawns the child, registers it with the shared reaper, and starts the
    /// per-stream reader threads. Returns `pid`/`process_group_id` synchronously so the caller's
    /// expected-agent-PID fence (design §4.6) can register immediately on return.
    pub fn start_or_resume(self: &Arc<Self>, identity: &RuntimeIdentity, resume_session_id: Option<String>) -> Result<StartReceipt, AgentScopeError> {
        self.check_identity(identity)?;
        {
            let state = self.lock_state();
            if state.closed {
                return Err(AgentScopeError::ScopeClosed);
            }
            if state.process.is_some() {
                return Err(AgentScopeError::AlreadyRunning);
            }
        }
        let arguments = self.build_arguments(resume_session_id.as_deref());
        let spawn_config = SpawnConfig {
            command: &self.config.command,
            arguments: &arguments,
            environment: &self.config.environment,
            working_directory: self.config.working_directory.as_deref(),
        };
        let spawned = process::spawn::spawn(&spawn_config).map_err(|error| AgentScopeError::Spawn(error.to_string()))?;
        let token = match self.reaper.register(spawned.pid) {
            Ok(token) => token,
            Err(error) => return Err(AgentScopeError::Reaper(format!("{error:?}"))),
        };
        *self.stdin.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(File::from(spawned.stdin_write));
        {
            let mut state = self.lock_state();
            state.process = Some(ProcessHandle { pid: spawned.pid, reaper_token: token });
        }
        let stdout_handle = spawn_stdout_pipeline(Arc::clone(self), spawned.stdout_read);
        // Stderr has no decode step (module doc): reused unmodified from P6-4, no thread-budget
        // risk since this pairing already *is* the one thread the stderr side needs. The tail's
        // `Arc<Mutex<StderrTail>>` lives only as long as this reader thread needs it -- this slice
        // does not surface a live `stderrTail` event (contract §7.1's droppable-diagnostic row is
        // satisfied by the tail simply existing for a future diagnostics read, not by streaming it).
        let (stderr_handle, _stderr_stats) =
            process::reader::spawn_stderr_reader(spawned.stderr_read, Arc::new(Mutex::new(process::stderr_tail::StderrTail::default())));
        let mut threads = self.reader_threads.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        threads.push(stdout_handle);
        threads.push(stderr_handle);
        drop(threads);
        Ok(StartReceipt { pid: spawned.pid, process_group_id: spawned.process_group_id })
    }

    fn build_arguments(&self, resume_session_id: Option<&str>) -> Vec<String> {
        if self.config.raw_argv_for_testing {
            return self.config.arguments.clone();
        }
        let mut args = vec![
            "-p".to_string(),
            "--verbose".to_string(),
            "--output-format".to_string(),
            "stream-json".to_string(),
            "--input-format".to_string(),
            "stream-json".to_string(),
            "--permission-prompt-tool".to_string(),
            "stdio".to_string(),
        ];
        if let Some(prompt) = &self.config.append_system_prompt {
            args.push("--append-system-prompt".to_string());
            args.push(prompt.clone());
        }
        if let Some(id) = resume_session_id {
            if !id.is_empty() {
                args.push("--resume".to_string());
                args.push(id.to_string());
            }
        }
        if self.config.permission_mode.as_deref().is_some_and(|mode| mode.eq_ignore_ascii_case("bypasspermissions")) {
            args.push("--allow-dangerously-skip-permissions".to_string());
        }
        if let Some(path) = &self.config.mcp_config_path {
            args.push("--mcp-config".to_string());
            args.push(path.clone());
            if self.config.mcp_strict_mode {
                args.push("--strict-mcp-config".to_string());
            }
        }
        if !self.config.disallowed_built_in_tools.is_empty() {
            args.push("--disallowedTools".to_string());
            args.push(self.config.disallowed_built_in_tools.join(","));
        }
        args.extend(self.config.arguments.iter().cloned());
        args
    }

    pub fn send_user_message(&self, identity: &RuntimeIdentity, text: &str) -> Result<u64, AgentScopeError> {
        self.check_identity(identity)?;
        let session_id = {
            let mut state = self.lock_state();
            if state.closed {
                return Err(AgentScopeError::ScopeClosed);
            }
            if state.process.is_none() {
                return Err(AgentScopeError::NotRunning);
            }
            let turn_id = state.turns.send_user_message();
            state.last_turn_generation = turn_id;
            state.resnapshot.reset();
            state.translator.cli_session_id.clone()
        };
        let line = codec::encode_user_message(text, session_id.as_deref());
        self.write_line(line).map_err(AgentScopeError::TransportWrite)?;
        Ok(self.lock_state().last_turn_generation)
    }

    /// Contract §4: fenced by `turn_generation`, no pre-check (design §5.3 -- the pre-check is
    /// *removed*, not made remote). The generation/in-flight classification below runs
    /// synchronously (no I/O) so `noTurnInFlight`/`staleGeneration` resolve and publish before this
    /// call returns; only the genuine ACK round trip is pushed onto a background thread.
    pub fn interrupt_turn(self: &Arc<Self>, identity: &RuntimeIdentity, turn_generation: u64, reason: String) -> Result<String, AgentScopeError> {
        self.check_identity(identity)?;
        let request_id = format!("interrupt-{}", self.next_request_id.fetch_add(1, Ordering::SeqCst));
        let (current_generation, current_turn_in_flight) = {
            let state = self.lock_state();
            if state.closed {
                return Err(AgentScopeError::ScopeClosed);
            }
            (state.last_turn_generation, state.turns.has_pending_turn_ids())
        };
        if turn_generation != current_generation {
            self.publish(event::interrupt_outcome(&request_id, "staleGeneration", current_generation, Some(current_turn_in_flight)));
            return Ok(request_id);
        }
        if !current_turn_in_flight {
            self.publish(event::interrupt_outcome(&request_id, "noTurnInFlight", current_generation, None));
            return Ok(request_id);
        }
        let scope = Arc::clone(self);
        let thread_request_id = request_id.clone();
        let spawn_result = thread::Builder::new()
            .name("agent-claude-interrupt".to_string())
            .spawn(move || scope.run_interrupt_roundtrip(thread_request_id, current_generation, reason));
        if spawn_result.is_err() {
            // Thread-spawn failure is treated the same as a transport failure -- the caller still
            // gets a receipt (charter §8.2's fast-enqueue contract), and the outcome is reported
            // as `failed` rather than left forever unresolved.
            self.publish(event::interrupt_outcome(&request_id, "failed", current_generation, None));
        }
        Ok(request_id)
    }

    fn run_interrupt_roundtrip(&self, request_id: String, current_generation: u64, reason: String) {
        let mut request = Map::new();
        request.insert("subtype".to_string(), json!("interrupt"));
        request.insert("reason".to_string(), json!(reason));
        let write_request_id = request_id.clone();
        let outcome = control::send_control_request(&self.control, &request_id, self.config.interrupt_ack_timeout, || {
            let line = codec::encode_control_request(&write_request_id, &request);
            self.write_line(line)
        });
        let outcome_name = match outcome {
            ControlOutcome::Response(_) => {
                self.lock_state().turns.mark_interrupted();
                "acknowledged"
            }
            ControlOutcome::Timeout => "timedOut",
            ControlOutcome::WriteFailed(_) => "failed",
        };
        self.publish(event::interrupt_outcome(&request_id, outcome_name, current_generation, None));
    }

    pub fn respond_permission(&self, identity: &RuntimeIdentity, request_id: &str, decision: PermissionDecisionInput) -> Result<(), AgentScopeError> {
        self.check_identity(identity)?;
        let pending = {
            let mut state = self.lock_state();
            if state.closed {
                return Err(AgentScopeError::ScopeClosed);
            }
            state.pending_permissions.remove(request_id)
        };
        let Some(pending) = pending else { return Err(AgentScopeError::UnknownPermissionRequest) };
        let decision: PermissionDecision = decision.into();
        let line = permission::encode_permission_decision(request_id, &decision, &pending.input, None, pending.tool_use_id.as_deref());
        control::send_control_request_without_response(|| self.write_line(line)).map_err(AgentScopeError::TransportWrite)?;
        if matches!(decision, PermissionDecision::Deny { interrupt: true, .. }) {
            self.publish(
                AgentClaudeEvent::new(AgentClaudeEventKind::ApprovalCancelled).with_field("request_id", request_id.to_string()),
            );
        }
        Ok(())
    }

    /// See this module's doc comment: a scope-reduced, fire-and-forget placeholder. `model`/
    /// `effort` are sent verbatim; there is no ACK tracking or deferred/pending state at this
    /// slice.
    pub fn apply_model_and_effort(&self, identity: &RuntimeIdentity, model: Option<String>, effort: Option<String>) -> Result<(), AgentScopeError> {
        self.check_identity(identity)?;
        {
            let state = self.lock_state();
            if state.closed {
                return Err(AgentScopeError::ScopeClosed);
            }
        }
        let mut request = Map::new();
        request.insert("subtype".to_string(), json!("set_model_and_effort"));
        if let Some(model) = &model {
            request.insert("model".to_string(), json!(model));
        }
        if let Some(effort) = &effort {
            request.insert("effort".to_string(), json!(effort));
        }
        let request_id = format!("flags-{}", self.next_request_id.fetch_add(1, Ordering::SeqCst));
        let line = codec::encode_control_request(&request_id, &request);
        control::send_control_request_without_response(|| self.write_line(line)).map_err(AgentScopeError::TransportWrite)
    }

    /// Idempotent. Flushes deferred turn completions with their original status (turn_state's
    /// `on_shutdown`, contract §3), fails every pending control request, closes stdin, then
    /// escalates SIGTERM -> grace -> SIGKILL against the process group via the shared reaper
    /// (contract §5.2).
    pub fn shutdown(&self, identity: &RuntimeIdentity) -> Result<(), AgentScopeError> {
        self.check_identity(identity)?;
        let (events, process) = {
            let mut state = self.lock_state();
            if state.closed {
                return Ok(());
            }
            state.closed = true;
            let events = state.turns.on_shutdown();
            let process = state.process.take();
            (events, process)
        };
        for turn_event in events {
            if let TurnEvent::TurnCompleted { turn_id, status } = turn_event {
                self.publish(event::turn_completed(turn_id, status).with_turn_id(turn_id));
            }
        }
        self.control.fail_all("shutdown");
        *self.stdin.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
        if let Some(handle) = process {
            process::reaper::terminate_and_reap(&self.reaper, handle.pid, handle.reaper_token, Duration::from_secs(2));
        }
        for thread in self.reader_threads.lock().unwrap_or_else(std::sync::PoisonError::into_inner).drain(..) {
            let _ = thread.join();
        }
        Ok(())
    }

    fn write_line(&self, mut bytes: Vec<u8>) -> Result<(), String> {
        bytes.push(b'\n');
        let mut guard = self.stdin.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(file) = guard.as_mut() else { return Err("stdin is not open".to_string()) };
        file.write_all(&bytes).map_err(|error| error.to_string())
    }

    // ---- Inline stdout pipeline (INV-P6-2): read -> frame -> decode -> translate -> publish ---

    fn on_framer_overflow(&self, dropped_bytes: usize, retained_bytes: usize) {
        self.lock_state().framer_overflow_count += 1;
        self.publish(
            AgentClaudeEvent::new(AgentClaudeEventKind::FramerOverflow)
                .with_field("dropped_bytes", dropped_bytes as u64)
                .with_field("retained_bytes", retained_bytes as u64),
        );
    }

    fn on_protocol_drift(&self, site: &'static str) {
        self.lock_state().protocol_drift_count += 1;
        self.publish(AgentClaudeEvent::new(AgentClaudeEventKind::ProtocolDrift).with_field("site", site));
    }

    fn handle_line(&self, line: &[u8]) {
        match codec::decode_line(line) {
            Ok(Some(message)) => self.route_message(message),
            Ok(None) => {}
            Err(CodecError::InvalidJson) => {
                let turn_in_flight = self.lock_state().turns.has_pending_turn_ids();
                match recovery::recover_invalid_json_line(line, turn_in_flight, |_diag| {}) {
                    RecoveryOutcome::Recovered(messages) => {
                        for message in messages {
                            self.route_message(message);
                        }
                    }
                    RecoveryOutcome::PlaintextSalvage(text) => {
                        let result = StreamResult { kind: "content".to_string(), text: Some(text), ..Default::default() };
                        self.emit_stream_result(result);
                    }
                    RecoveryOutcome::Declined => {}
                }
            }
            Err(CodecError::UnsupportedPayload) => self.on_protocol_drift("codec.unsupportedPayload"),
        }
    }

    fn route_message(&self, message: InboundMessage) {
        match message {
            InboundMessage::StreamPayload(payload) => self.handle_stream_payload(&payload),
            InboundMessage::ControlRequest(request) => self.handle_control_request(&request),
            InboundMessage::ControlResponse(response) => {
                let request_id = response.request_id.clone();
                self.control.resolve(&request_id, response);
            }
            InboundMessage::ControlCancelRequest { .. } | InboundMessage::KeepAlive => {}
        }
    }

    fn handle_control_request(&self, request: &ControlRequest) {
        if let Some(parsed) = permission::parse_can_use_tool_request(request) {
            let request_id = parsed.request_id.clone();
            let approval_event = event::approval_request(&parsed);
            self.lock_state().pending_permissions.insert(request_id, parsed);
            self.publish(approval_event);
            return;
        }
        let line = permission::encode_unsupported_subtype_response(&request.request_id, &request.subtype);
        let _ = self.write_line(line);
    }

    fn handle_stream_payload(&self, payload: &Map<String, Value>) {
        let is_result_payload = payload.get("type").and_then(Value::as_str) == Some("result");
        let results = self.lock_state().translator.parse_stream_payload(payload);
        for result in results {
            if is_result_payload && result.kind == "message_stop" {
                self.handle_authoritative_result(payload, &result);
                continue;
            }
            self.emit_stream_result(result);
        }
    }

    /// Contract §3: a turn completes only when the *envelope's* `type == "result"` and the
    /// translated kind is `"message_stop"` -- the caller (`handle_stream_payload`) already checked
    /// both. `is_error`/`subtype`/`stop_reason`/`errors[]` are the raw envelope's own fields,
    /// re-extracted here independently of the translator: `StreamResult` does not carry them (it is
    /// a neutral, provider-shape-agnostic DTO), and the contract's `determine_status` signature
    /// deliberately keeps `stop_reason_hint` (the translator's own derived hint,
    /// `result.stop_reason`) separate from the envelope's top-level/nested fields.
    fn handle_authoritative_result(&self, payload: &Map<String, Value>, result: &StreamResult) {
        let is_error = payload.get("is_error").or_else(|| payload.get("isError")).and_then(Value::as_bool).unwrap_or(false);
        let subtype = payload.get("subtype").and_then(Value::as_str).unwrap_or("").to_string();
        let stop_reason = payload.get("stop_reason").or_else(|| payload.get("stopReason")).and_then(Value::as_str).unwrap_or("").to_string();
        let nested_stop_reason = payload
            .get("event")
            .and_then(Value::as_object)
            .and_then(|event| event.get("delta"))
            .and_then(Value::as_object)
            .and_then(|delta| delta.get("stop_reason").or_else(|| delta.get("stopReason")))
            .and_then(Value::as_str)
            .map(str::to_string);
        let result_errors = extract_result_errors(payload);

        let mut diagnostics = 0usize;
        let turn_event = {
            let mut state = self.lock_state();
            let status = state.turns.determine_status(
                is_error,
                &subtype,
                &stop_reason,
                result.stop_reason.as_deref(),
                nested_stop_reason.as_deref(),
                &result_errors,
            );
            state.turns.on_authoritative_result(status, |_diag| diagnostics += 1)
        };
        if diagnostics > 0 {
            self.on_protocol_drift("turnState.authoritativeResult");
        }
        if let Some(TurnEvent::TurnCompleted { turn_id, status }) = turn_event {
            self.publish(event::turn_completed(turn_id, status).with_turn_id(turn_id));
        }
    }

    fn emit_stream_result(&self, result: StreamResult) {
        if should_suppress_user_facing_stream_result(&result) {
            return;
        }
        // Resnapshot append happens under the state lock; the truncation event (if any) is
        // published only after the lock is released -- "publish outside the scope-state lock"
        // (design §5.1's lock-order rule, ported verbatim from `inventory_scope::scope`).
        let truncation = {
            let mut state = self.lock_state();
            if state.turns.has_pending_turn_ids() {
                let chunk = result.text.as_deref().or(result.reasoning.as_deref()).unwrap_or("");
                if chunk.is_empty() {
                    None
                } else if let Some(truncated) = state.resnapshot.append(chunk.as_bytes()) {
                    state.resnapshot_truncation_count += 1;
                    Some(truncated)
                } else {
                    None
                }
            } else {
                None
            }
        };
        if let Some(truncated) = truncation {
            self.publish(
                AgentClaudeEvent::new(AgentClaudeEventKind::TranscriptTruncated)
                    .with_field("dropped_bytes", truncated.dropped_bytes as u64)
                    .with_field("retained_bytes", truncated.retained_bytes as u64),
            );
        }

        match result.kind.as_str() {
            "session_state_changed" => {
                self.handle_session_state_changed(&result);
                return;
            }
            "content" => {
                self.publish_field_event(AgentClaudeEventKind::AssistantDelta, "text", result.text.as_deref().unwrap_or(""));
            }
            "reasoning" => {
                self.publish_field_event(AgentClaudeEventKind::ReasoningDelta, "text", result.reasoning.as_deref().unwrap_or(""));
            }
            "tool_call" => {
                let mut ev = AgentClaudeEvent::new(AgentClaudeEventKind::ToolUseStarted)
                    .with_field("tool_name", result.tool_name.clone().unwrap_or_default());
                if let Some(id) = result.tool_invocation_id {
                    ev = ev.with_field("invocation_id", id.0);
                }
                if let Some(args) = &result.tool_args_json {
                    ev = ev.with_field("args_json", args.as_str());
                }
                self.publish(ev);
            }
            "tool_result" => {
                let mut ev = AgentClaudeEvent::new(AgentClaudeEventKind::ToolResult)
                    .with_field("tool_name", result.tool_name.clone().unwrap_or_default())
                    .with_field("output", result.tool_output.clone().unwrap_or_default());
                if let Some(id) = result.tool_invocation_id {
                    ev = ev.with_field("invocation_id", id.0);
                }
                if let Some(is_error) = result.tool_is_error {
                    ev = ev.with_field("is_error", is_error);
                }
                self.publish(ev);
            }
            "error" => {
                self.publish_field_event(AgentClaudeEventKind::Error, "message", result.text.as_deref().unwrap_or(""));
            }
            "lifecycle" => {
                self.publish(AgentClaudeEvent::new(AgentClaudeEventKind::RuntimeInit));
            }
            _ => {
                // "usage", "task_progress", "system", "status", "final_content", "auth_status" and
                // any other non-authoritative kind: a routine progress fact, coalescible (contract
                // §7.1's `taskProgress` row). Full per-kind fidelity is P6-7's turn-level
                // differential's job; this slice's event catalog focuses on the lossless/terminal
                // rows the done-when's gap/oversize/resnapshot paths actually exercise.
                self.publish_field_event(AgentClaudeEventKind::TaskProgress, "text", result.text.as_deref().unwrap_or(&result.kind));
            }
        }
    }

    fn publish_field_event(&self, kind: AgentClaudeEventKind, field: &str, value: &str) {
        if value.is_empty() {
            return;
        }
        self.publish(AgentClaudeEvent::new(kind).with_field(field, value));
    }

    fn handle_session_state_changed(&self, result: &StreamResult) {
        let text = result.text.clone().unwrap_or_default();
        let is_idle = text.trim().eq_ignore_ascii_case("idle");
        self.publish(
            AgentClaudeEvent::new(AgentClaudeEventKind::SessionStateChanged)
                .with_field("text", text.clone())
                .with_field("is_idle", is_idle),
        );
        let mut diagnostics = 0usize;
        let turn_event = {
            let mut state = self.lock_state();
            state.turns.on_session_state_changed(&text, |_diag| diagnostics += 1)
        };
        if diagnostics > 0 {
            self.on_protocol_drift("turnState.sessionStateChanged");
        }
        if let Some(TurnEvent::TurnCompleted { turn_id, status }) = turn_event {
            self.publish(event::turn_completed(turn_id, status).with_turn_id(turn_id));
        }
    }

    fn on_stdout_eof(&self) {
        let events = self.lock_state().turns.on_stdout_eof();
        for turn_event in events {
            match turn_event {
                TurnEvent::TurnCompleted { turn_id, status } => {
                    self.publish(event::turn_completed(turn_id, status).with_turn_id(turn_id));
                }
                TurnEvent::Error(message) => {
                    self.publish_field_event(AgentClaudeEventKind::Error, "message", &message);
                }
            }
        }
        self.control.fail_all("stdout EOF");
    }

    fn publish(&self, event: AgentClaudeEvent) {
        let sink = { self.event_sink.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone() };
        let Some(sink) = sink else { return };
        let (class, coalesce_key, terminal_reserve) = event.classification();
        let kind = if terminal_reserve { RuntimeEventKind::Terminal } else { RuntimeEventKind::Data };
        let input = EventInput { kind, class, payload: event.encode(), coalesce_key };
        if sink.hub.publish(&self.identity, &sink.scope_id, input).is_err() {
            self.publish_failure_count.fetch_add(1, Ordering::Relaxed);
        }
    }
}

impl Drop for AgentClaudeScope {
    /// Orphan backstop (design §4.2/§4.7): a scope dropped without `shutdown` hands its process to
    /// the shared reaper's orphan path on a fire-and-forget thread rather than blocking the drop,
    /// exactly mirroring the Swift controller's best-effort `deinit` cleanup.
    fn drop(&mut self) {
        let process = self.state.get_mut().unwrap_or_else(std::sync::PoisonError::into_inner).process.take();
        if let Some(handle) = process {
            let reaper = Arc::clone(&self.reaper);
            let _ = thread::Builder::new().name("agent-claude-orphan-backstop".to_string()).spawn(move || {
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

/// The inline stdout pipeline INV-P6-2 requires: one thread, `read()` -> [`LineFramer::feed`] ->
/// [`AgentClaudeScope::handle_line`] -> ... -> non-blocking publish, with no intermediate queue.
fn spawn_stdout_pipeline(scope: Arc<AgentClaudeScope>, fd: std::os::fd::OwnedFd) -> JoinHandle<()> {
    process::thread_budget::increment();
    thread::Builder::new()
        .name("agent-claude-stdout".to_string())
        .spawn(move || {
            let _budget = process::thread_budget::ThreadBudgetGuard::already_counted();
            let mut stream = File::from(fd);
            let mut framer = LineFramer::default();
            let mut buf = [0u8; 64 * 1024];
            loop {
                let n = match stream.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(ref error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                framer.feed(
                    &buf[..n],
                    |diagnostic| {
                        if let super::framer::FramerDiagnostic::Overflow { dropped_bytes, retained_bytes } = diagnostic {
                            scope.on_framer_overflow(dropped_bytes, retained_bytes);
                        }
                    },
                    |line| scope.handle_line(&line),
                );
            }
            framer.flush(|line| scope.handle_line(&line));
            scope.on_stdout_eof();
        })
        .expect("spawning the agent-claude stdout pipeline thread must succeed")
}

/// Port of `extractResultErrorMessages` (contract §2.3): an `errors` array of strings or
/// `{message|error}` objects, plus a fallback single top-level `error`/`message` field consulted
/// only when `errors` yielded nothing.
fn extract_result_errors(payload: &Map<String, Value>) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(Value::Array(items)) = payload.get("errors") {
        for item in items {
            match item {
                Value::String(text) => out.push(text.clone()),
                Value::Object(object) => {
                    if let Some(text) = object.get("message").and_then(Value::as_str) {
                        out.push(text.to_string());
                    } else if let Some(text) = object.get("error").and_then(Value::as_str) {
                        out.push(text.to_string());
                    }
                }
                _ => {}
            }
        }
    }
    if out.is_empty() {
        if let Some(text) = payload.get("error").and_then(Value::as_str) {
            out.push(text.to_string());
        } else if let Some(text) = payload.get("message").and_then(Value::as_str) {
            out.push(text.to_string());
        }
    }
    out
}

// ================================================================================================
// ScopeRegistry -- the ID-addressed holder, mirroring `inventory_scope::registry::ScopeRegistry`.
// One process-wide `Reaper` is shared by every scope this registry mints (contract §5.2's `2N + 1`
// budget is a *process*-wide quantity, not per scope).
// ================================================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScopeRegistryError {
    IdentityMismatch,
    UnknownScope,
}

impl From<ScopeRegistryError> for AgentScopeError {
    fn from(value: ScopeRegistryError) -> Self {
        match value {
            ScopeRegistryError::IdentityMismatch => Self::IdentityMismatch,
            ScopeRegistryError::UnknownScope => Self::UnknownScope,
        }
    }
}

pub struct ScopeRegistry {
    scopes: Mutex<HashMap<AgentClaudeScopeId, Arc<AgentClaudeScope>>>,
    reaper: Arc<Reaper>,
}

impl Default for ScopeRegistry {
    fn default() -> Self {
        Self { scopes: Mutex::new(HashMap::new()), reaper: Reaper::new() }
    }
}

impl ScopeRegistry {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn open_scope(&self, identity: RuntimeIdentity, config: AgentClaudeScopeConfig) -> Arc<AgentClaudeScope> {
        let scope_id = AgentClaudeScopeId::mint();
        let scope = Arc::new(AgentClaudeScope::new(identity, scope_id, config, Arc::clone(&self.reaper)));
        self.scopes.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(scope_id, Arc::clone(&scope));
        scope
    }

    #[must_use]
    pub fn get(&self, scope_id: AgentClaudeScopeId) -> Option<Arc<AgentClaudeScope>> {
        self.scopes.lock().unwrap_or_else(std::sync::PoisonError::into_inner).get(&scope_id).cloned()
    }

    /// Idempotent, matching `InventoryScope`'s `ScopeRegistry::close_scope` precedent.
    pub fn close_scope(&self, identity: &RuntimeIdentity, scope_id: AgentClaudeScopeId) -> Result<(), ScopeRegistryError> {
        let scope = self.scopes.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&scope_id);
        let Some(scope) = scope else { return Ok(()) };
        if scope.identity() != identity {
            self.scopes.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(scope_id, Arc::clone(&scope));
            return Err(ScopeRegistryError::IdentityMismatch);
        }
        let _ = scope.shutdown(identity);
        Ok(())
    }

    #[must_use]
    pub fn scope_count(&self) -> usize {
        self.scopes.lock().unwrap_or_else(std::sync::PoisonError::into_inner).len()
    }
}
