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
//! - **Launch-environment comparison remains a Swift input fact.** Swift still resolves Keychain,
//!   backend selection, and the launch environment. When that comparison says a live change needs
//!   a restart, `apply_model_and_effort` receives the fact, records `session.flagSettingsDeferred`,
//!   and publishes `restartRequired` without writing a control request. Rust still owns the command
//!   state transition and raw record; Swift owns only the platform-specific comparison input.
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
//! - **The interrupt round-trip thread (`interrupt_turn`'s background thread) and the orphan-
//!   backstop thread (`Drop`'s detached `terminate_and_orphan` call) do not call
//!   `process::thread_budget::increment()`.** The frozen `2N + 1` steady-state budget (contract
//!   §5.2, this module's own top-of-file doc comment) is a *steady-state* measurement across the
//!   two permanent per-session reader threads plus the one process-wide reaper thread; both of
//!   these are transient and bounded (the round trip resolves within `interrupt_ack_timeout`, the
//!   backstop thread exits once `terminate_and_orphan` returns), so leaving them uncounted does not
//!   break that existing assertion. Named explicitly rather than left for the next reader to
//!   discover by grep: an uncounted-but-unbounded thread class is exactly the blind spot R2b exists
//!   to catch, and these two are deliberately in the "transient and bounded" exception, not an
//!   oversight.
//! - **The five contract §5.3 interrupt outcomes (`acknowledged`/`noTurnInFlight`/`staleGeneration`/
//!   `timedOut`/`failed`) cross the wire as a plain string field inside the batched event envelope
//!   (see [`event::interrupt_outcome`]), not a typed enum on either side of the FFI boundary.** This
//!   slice freezes that string-field shape rather than adding a typed Swift enum: all five string
//!   literals are exhaustively produced here, listed in `abi-v1.json`'s `agentClaudeV1` section, and
//!   each is reachable by a dedicated test at every layer (`agent_claude_scope.rs`, `api.rs`'s FFI
//!   twins, and -- for `staleGeneration` -- `CoreAgentSessionTests` through the real Swift bridge).
//!   A typed `CoreAgentInterruptOutcome` Swift enum (exhaustive-switch safety for a real UI
//!   consumer) is deferred until a consumer actually needs it; adding one speculatively now would
//!   be shape churn against a surface this step's own done-when says should freeze.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::{EventInput, RuntimeEventKind, RuntimeIdentity, ScopeId, SubscriptionHub};

use super::codec::{self, CodecError, ControlRequest, ControlResponse, InboundMessage};
use super::control::{self, ControlCorrelator, ControlOutcome};
use super::event::{self, AgentClaudeEvent, AgentClaudeEventKind};
use super::framer::LineFramer;
use super::permission::{self, CanUseToolRequest, PermissionDecision};
use super::process::{self, reaper::Reaper, spawn::SpawnConfig, timer::SystemClock};
use super::recovery::{self, RecoveryOutcome};
use super::resnapshot::ResnapshotBuffer;
use super::tool_owned::is_repoprompt_tool_name;
use super::translator::{StreamResult, Translator, should_suppress_user_facing_stream_result};
use super::turn_state::{TurnEvent, TurnState, TurnStatus};

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
            let text =
                std::str::from_utf8(chunk).map_err(|_| AgentClaudeScopeIdParseError::InvalidHex)?;
            bytes[index] = u8::from_str_radix(text, 16)
                .map_err(|_| AgentClaudeScopeIdParseError::InvalidHex)?;
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
    /// Port of `ControllerError.invalidControlResponse` (`ClaudeNativeProcessSessionController.
    /// swift:1962-1963`): the CLI answered a control request with `subtype: "error"` (or any
    /// subtype other than `"success"`), carrying its own error message.
    ControlResponseError(String),
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
            Self::ControlResponseError(message) => write!(f, "control response error: {message}"),
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
    Allow {
        include_updated_permissions: bool,
    },
    /// Swift/core policy matched a RepoPrompt-owned MCP tool and chose the legacy automatic allow
    /// path. Rust still owns the protocol write; the extra fields exist only so the Rust-owned raw
    /// event log can preserve the legacy `approval.autoApprove.repoPrompt` record.
    AutoAllowRepoPrompt {
        match_source: String,
        normalized_tool_name: Option<String>,
        server_identifier: Option<String>,
    },
    /// The legacy controller's defensive fallback automatic allow path. Kept as a distinct policy
    /// result even though current request modeling makes it unreachable, preserving the frozen raw
    /// event kind without moving the policy decision into Rust.
    AutoAllowFallback,
    Deny {
        message: String,
        interrupt: bool,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlagSettingsDisposition {
    Initial,
    Live,
    PendingInitialHandshake,
    RestartRequired,
}

impl From<PermissionDecisionInput> for PermissionDecision {
    fn from(value: PermissionDecisionInput) -> Self {
        match value {
            PermissionDecisionInput::Allow {
                include_updated_permissions,
            } => PermissionDecision::Allow {
                include_updated_permissions,
            },
            PermissionDecisionInput::AutoAllowRepoPrompt { .. }
            | PermissionDecisionInput::AutoAllowFallback => PermissionDecision::Allow {
                include_updated_permissions: false,
            },
            PermissionDecisionInput::Deny { message, interrupt } => {
                PermissionDecision::Deny { message, interrupt }
            }
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
    /// P6-7 (§15.5): the `initialize` control request's `systemPrompt` override (contract §2.5,
    /// `buildInitializeRequest(systemPromptOverride:)`) -- a *protocol-level* field sent once at
    /// session start, distinct from `append_system_prompt`'s CLI-argv `--append-system-prompt`
    /// mechanism. `None` omits the `systemPrompt` key entirely, matching Swift's `if let
    /// systemPromptOverride { request["systemPrompt"] = ... }`.
    pub system_prompt: Option<String>,
    pub idle_fallback: Duration,
    pub interrupt_ack_timeout: Duration,
    /// P6-7 (D-9/R9, `docs/architecture/rust-agent-claude-v1.md` §15.6): whether the raw-event
    /// JSONL log is active for this session -- resolved by Swift from the SAME `app_settings` key
    /// (`agent_mode.claude_raw_event_logging_enabled`) its own writer reads, never decided here.
    pub raw_event_log_enabled: bool,
    /// The already-resolved absolute log-file path (Swift's `makeRawEventLogFileURL`, widened for
    /// this reuse) -- `None` means "no path could be resolved," which disables logging regardless
    /// of [`Self::raw_event_log_enabled`] (`RawEventLogWriter::new`'s own guard).
    pub raw_event_log_file_path: Option<String>,
    pub raw_event_log_run_id: String,
    pub raw_event_log_tab_id: String,
    pub raw_event_log_window_id: i64,
    pub raw_event_log_initial_session_id: String,
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
            system_prompt: None,
            idle_fallback: super::turn_state::DEFAULT_IDLE_FALLBACK,
            interrupt_ack_timeout: Duration::from_millis(1500),
            raw_event_log_enabled: false,
            raw_event_log_file_path: None,
            raw_event_log_run_id: String::new(),
            raw_event_log_tab_id: String::new(),
            raw_event_log_window_id: 0,
            raw_event_log_initial_session_id: String::new(),
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
    // PID-owned so a late EOF from an old reader can never clear a replacement process's stdin.
    stdin: Mutex<Option<(libc::pid_t, File)>>,
    reader_threads: Mutex<Vec<JoinHandle<()>>>,
    event_sink: Mutex<Option<EventSink>>,
    next_request_id: AtomicU64,
    publish_failure_count: AtomicU64,
    scheduled_fallback_generation: AtomicU64,
    /// P6-7 (D-9/R9, §15.6). Constructed once from `config.raw_event_log_enabled`/
    /// `raw_event_log_file_path` and never reconfigured afterwards -- matching the fact that
    /// Swift's own equivalent flags are read once per session too (`isRawEventFileLoggingEnabled()`
    /// is consulted at session start, not polled continuously).
    raw_log: super::raw_event_log::RawEventLogWriter,
}

impl AgentClaudeScope {
    fn new(
        identity: RuntimeIdentity,
        scope_id: AgentClaudeScopeId,
        config: AgentClaudeScopeConfig,
        reaper: Arc<Reaper>,
    ) -> Self {
        let idle_fallback = config.idle_fallback;
        let raw_log = super::raw_event_log::RawEventLogWriter::new(
            config.raw_event_log_enabled,
            config.raw_event_log_file_path.clone(),
            super::raw_event_log::RawEventLogContext {
                run_id: config.raw_event_log_run_id.clone(),
                tab_id: config.raw_event_log_tab_id.clone(),
                window_id: config.raw_event_log_window_id,
                workspace_path: config.working_directory.clone().unwrap_or_default(),
                initial_session_id: config.raw_event_log_initial_session_id.clone(),
            },
        );
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
            scheduled_fallback_generation: AtomicU64::new(0),
            raw_log,
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
        *self
            .event_sink
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(EventSink { hub, scope_id });
    }

    fn check_identity(&self, identity: &RuntimeIdentity) -> Result<(), AgentScopeError> {
        if &self.identity == identity {
            Ok(())
        } else {
            Err(AgentScopeError::IdentityMismatch)
        }
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
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
    pub fn start_or_resume(
        self: &Arc<Self>,
        identity: &RuntimeIdentity,
        resume_session_id: Option<String>,
        model: Option<String>,
        effort_level: Option<String>,
    ) -> Result<StartReceipt, AgentScopeError> {
        self.check_identity(identity)?;
        self.raw_log.write(
            "session.startOrResume",
            Some(json!({
                "existingSessionID": resume_session_id,
                "model": model,
                "effortLevel": effort_level,
                "hasSystemPromptOverride": self.config.system_prompt.is_some(),
            })),
        );
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
        let spawned = process::spawn::spawn(&spawn_config)
            .map_err(|error| AgentScopeError::Spawn(error.to_string()))?;
        // R8: command/arguments/working_directory only, never `self.config.environment` (module
        // doc, `raw_event_log`'s own doc comment).
        self.raw_log.write(
            "process.spawned",
            Some(json!({
                "command": self.config.command,
                "arguments": arguments,
                "workingDirectory": self.config.working_directory,
            })),
        );
        let token = match self.reaper.register(spawned.pid) {
            Ok(token) => token,
            Err(error) => return Err(AgentScopeError::Reaper(format!("{error:?}"))),
        };
        *self
            .stdin
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some((spawned.pid, File::from(spawned.stdin_write)));
        {
            let mut state = self.lock_state();
            state.process = Some(ProcessHandle {
                pid: spawned.pid,
                reaper_token: token,
            });
        }
        let stdout_handle =
            spawn_stdout_pipeline(Arc::downgrade(self), spawned.stdout_read, spawned.pid);
        // Stderr has no decode step (module doc): reused unmodified from P6-4, no thread-budget
        // risk since this pairing already *is* the one thread the stderr side needs. The tail's
        // `Arc<Mutex<StderrTail>>` lives only as long as this reader thread needs it -- this slice
        // does not surface a live `stderrTail` event (contract §7.1's droppable-diagnostic row is
        // satisfied by the tail simply existing for a future diagnostics read, not by streaming it).
        let stderr_scope = Arc::downgrade(self);
        let stderr_observer: process::reader::StderrChunkObserver = Arc::new(move |chunk| {
            if let Some(scope) = stderr_scope.upgrade() {
                scope
                    .raw_log
                    .write("process.stderr", Some(raw_line_payload(chunk)));
            }
        });
        let (stderr_handle, _stderr_stats) = process::reader::spawn_stderr_reader_with_observer(
            spawned.stderr_read,
            Arc::new(Mutex::new(process::stderr_tail::StderrTail::default())),
            Some(stderr_observer),
        );
        let mut threads = self
            .reader_threads
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        threads.push(stdout_handle);
        threads.push(stderr_handle);
        drop(threads);
        // P6-7 (§15.5): the session-startup control-request handshake -- `initialize` then
        // (if configured) `set_permission_mode` -- runs synchronously here, blocking this call
        // until both ACK or the transport dies, exactly mirroring Swift's `startOrResume` awaiting
        // `initializeIfNeeded` before returning a `SessionRef` (`:445-447`). `--resume` does not
        // skip or reorder this: Swift's `initializeIfNeeded` never branches on
        // `existingSessionID`, and neither does this call. On failure, tear the process down the
        // same way Swift's `startOrResume` does on any post-spawn throw (`:450-453`: `if process
        // != nil ... { await shutdown() }; throw error`) rather than leaving a half-initialized
        // scope the caller believes is running.
        if let Err(handshake_error) = self.perform_startup_handshake() {
            let _ = self.shutdown(identity);
            return Err(handshake_error);
        }
        Ok(StartReceipt {
            pid: spawned.pid,
            process_group_id: spawned.process_group_id,
        })
    }

    /// Contract §2.5/design §4.5 gap closure (P6-7 §15.4/§15.5, `docs/architecture/
    /// rust-agent-claude-v1.md` §15.5): ports `initializeIfNeeded`/`buildInitializeRequest`
    /// (`ClaudeNativeProcessSessionController.swift:701-720`, `:795-800`) and
    /// `applyInitialPermissionModeIfNeeded`/`buildSetPermissionModeRequest` (`:730-736`,
    /// `:812-819`) verbatim in sequence: `initialize` (optionally carrying `systemPrompt`), then
    /// `set_permission_mode` (only if `config.permission_mode` is non-empty after trim) -- both
    /// with **no** bounded timeout, matching Swift's `sendControlRequest(request:)` default
    /// (`timeoutSeconds: TimeInterval? = nil`, `:838`). The only thing that ever unblocks a stuck
    /// handshake is `on_stdout_eof`'s `control.fail_all("stdout EOF")`, exactly as Swift's
    /// `failPendingControlRequests(with: .processNotRunning)` does from `handleStdoutEOF` (`:1994,
    /// 2010`).
    ///
    /// **Deliberately out of scope here, named rather than silently absorbed:** the third leg of
    /// Swift's `initializeIfNeeded`, `applyInitialFlagSettingsIfNeeded` (`:775-789`, the initial
    /// `apply_flag_settings` control request for model/effort), is not ported into this handshake.
    /// On the Rust arm that role is already filled by a *different* call site --
    /// `ClaudeRustBackedNativeSessionAdapter.startOrResume`'s post-`startOrResume` best-effort
    /// `applyModelAndEffort` call (P6-7, landed at `dcc09247`) -- which fires the equivalent
    /// `set_model_and_effort` request without blocking session start-up on its ACK. Porting a
    /// second, blocking copy into this handshake would race that adapter call and double-send the
    /// settings request; the adapter's non-blocking placement is the documented intentional design
    /// (its own doc comment: "mirrors the fast-enqueue contract"), not an oversight this closes.
    fn perform_startup_handshake(&self) -> Result<(), AgentScopeError> {
        self.send_initialize_request()?;
        self.send_set_permission_mode_request_if_configured()?;
        Ok(())
    }

    fn next_control_request_id(&self, prefix: &str) -> String {
        format!(
            "{prefix}-{}",
            self.next_request_id.fetch_add(1, Ordering::SeqCst)
        )
    }

    /// Port of `initializeIfNeeded`/`buildInitializeRequest` (`:701-720`, `:795-800`). On success,
    /// records an observed `session_id` from the response exactly as `recordObservedSessionID`
    /// does (`:706-709`) -- the same `cli_session_id` field `send_user_message` already reads for
    /// `--resume` continuity.
    fn send_initialize_request(&self) -> Result<(), AgentScopeError> {
        let mut request = Map::new();
        request.insert("subtype".to_string(), json!("initialize"));
        if let Some(system_prompt) = &self.config.system_prompt {
            request.insert("systemPrompt".to_string(), json!(system_prompt));
        }
        let response = self.send_startup_control_request("init", &request)?;
        if let Some(session_id) = response.get("session_id").and_then(Value::as_str) {
            let trimmed = session_id.trim();
            if !trimmed.is_empty() {
                self.lock_state().translator.cli_session_id = Some(trimmed.to_string());
                self.raw_log.set_session_id(trimmed);
            }
        }
        self.raw_log
            .write("session.initialized", Some(Value::Object(response)));
        Ok(())
    }

    /// Port of `applyInitialPermissionModeIfNeeded`/`buildSetPermissionModeRequest` (`:730-736`,
    /// `:812-819`): sent whenever `config.permission_mode` is non-empty after trimming, regardless
    /// of value -- this is independent of, and in addition to, the `--allow-
    /// dangerously-skip-permissions` argv flag `build_arguments` already injects for the specific
    /// `"bypassPermissions"` value (contract §2.5 item 3).
    fn send_set_permission_mode_request_if_configured(&self) -> Result<(), AgentScopeError> {
        let Some(mode) = self.config.permission_mode.as_deref() else {
            return Ok(());
        };
        let trimmed = mode.trim();
        if trimmed.is_empty() {
            return Ok(());
        }
        let mut request = Map::new();
        request.insert("subtype".to_string(), json!("set_permission_mode"));
        request.insert("mode".to_string(), json!(trimmed));
        let response = self.send_startup_control_request("permmode", &request)?;
        self.raw_log.write(
            "session.permissionModeInitialized",
            Some(json!({"requestedMode": trimmed, "response": response})),
        );
        Ok(())
    }

    /// Port of `sendControlRequest(request:)`'s no-timeout default plus `handleControlResponse`'s
    /// subtype dispatch (`:1959-1963`): `"success"` resolves with the response body, anything else
    /// (`"error"` in practice) fails with the CLI's own error message, matching Swift's
    /// `ControllerError.invalidControlResponse`. Used only by the two session-startup handshake
    /// requests above. Interrupt preserves Swift's ACK-on-any-response behavior; flag settings
    /// validates the success subtype because its correlated outcome must not report a failed
    /// control response as applied.
    fn send_startup_control_request(
        &self,
        request_id_prefix: &str,
        request: &Map<String, Value>,
    ) -> Result<Map<String, Value>, AgentScopeError> {
        let request_id = self.next_control_request_id(request_id_prefix);
        self.raw_log.write(
            "control.request.sent",
            Some(json!({
                "requestID": request_id,
                "request": request,
                "expectsResponse": true,
            })),
        );
        let write_request_id = request_id.clone();
        let outcome = control::send_control_request_blocking(&self.control, &request_id, || {
            let line = codec::encode_control_request(&write_request_id, request);
            self.write_line(line)
        });
        match outcome {
            ControlOutcome::Response(response) if response.subtype == "success" => {
                Ok(response.response.unwrap_or_default())
            }
            ControlOutcome::Response(response) => {
                let message = response
                    .error
                    .unwrap_or_else(|| "Unknown Claude control error".to_string());
                Err(AgentScopeError::ControlResponseError(message))
            }
            ControlOutcome::WriteFailed(reason) => Err(AgentScopeError::TransportWrite(reason)),
            ControlOutcome::Timeout => {
                // `send_control_request_blocking` never produces this variant (module doc); treated
                // as a control-response error rather than `unreachable!()` per charter §14.1's
                // panic-avoidance policy for authority code.
                Err(AgentScopeError::ControlResponseError(
                    "unexpected timeout outcome from a blocking control request".to_string(),
                ))
            }
        }
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
        if self
            .config
            .permission_mode
            .as_deref()
            .is_some_and(|mode| mode.eq_ignore_ascii_case("bypasspermissions"))
        {
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

    pub fn send_user_message(
        &self,
        identity: &RuntimeIdentity,
        text: &str,
    ) -> Result<u64, AgentScopeError> {
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
        self.write_line(line)
            .map_err(AgentScopeError::TransportWrite)?;
        Ok(self.lock_state().last_turn_generation)
    }

    /// Contract §4: fenced by `turn_generation`, no pre-check (design §5.3 -- the pre-check is
    /// *removed*, not made remote). The generation/in-flight classification below runs
    /// synchronously (no I/O) so `noTurnInFlight`/`staleGeneration` resolve and publish before this
    /// call returns; only the genuine ACK round trip is pushed onto a background thread.
    pub fn interrupt_turn(
        self: &Arc<Self>,
        identity: &RuntimeIdentity,
        turn_generation: u64,
        reason: String,
    ) -> Result<String, AgentScopeError> {
        self.check_identity(identity)?;
        let request_id = format!(
            "interrupt-{}",
            self.next_request_id.fetch_add(1, Ordering::SeqCst)
        );
        let (current_generation, current_turn_in_flight) = {
            let state = self.lock_state();
            if state.closed {
                return Err(AgentScopeError::ScopeClosed);
            }
            (
                state.last_turn_generation,
                state.turns.has_pending_turn_ids(),
            )
        };
        if turn_generation != current_generation {
            self.publish(event::interrupt_outcome(
                &request_id,
                "staleGeneration",
                current_generation,
                Some(current_turn_in_flight),
            ));
            return Ok(request_id);
        }
        if !current_turn_in_flight {
            self.publish(event::interrupt_outcome(
                &request_id,
                "noTurnInFlight",
                current_generation,
                None,
            ));
            return Ok(request_id);
        }
        let scope = Arc::clone(self);
        let thread_request_id = request_id.clone();
        let spawn_result = thread::Builder::new()
            .name("agent-claude-interrupt".to_string())
            .spawn(move || {
                scope.run_interrupt_roundtrip(thread_request_id, current_generation, reason)
            });
        if spawn_result.is_err() {
            // Thread-spawn failure is treated the same as a transport failure -- the caller still
            // gets a receipt (charter §8.2's fast-enqueue contract), and the outcome is reported
            // as `failed` rather than left forever unresolved.
            self.publish(event::interrupt_outcome(
                &request_id,
                "failed",
                current_generation,
                None,
            ));
        }
        Ok(request_id)
    }

    fn run_interrupt_roundtrip(&self, request_id: String, current_generation: u64, reason: String) {
        let mut request = Map::new();
        request.insert("subtype".to_string(), json!("interrupt"));
        request.insert("reason".to_string(), json!(reason));
        self.raw_log.write(
            "control.request.sent",
            Some(json!({
                "requestID": request_id,
                "request": request,
                "expectsResponse": true,
            })),
        );
        let write_request_id = request_id.clone();
        let outcome = control::send_control_request(
            &self.control,
            &request_id,
            self.config.interrupt_ack_timeout,
            || {
                let line = codec::encode_control_request(&write_request_id, &request);
                self.write_line(line)
            },
        );
        let (outcome_name, raw_kind, raw_payload) = match outcome {
            ControlOutcome::Response(_) => {
                self.lock_state().turns.mark_interrupted();
                (
                    "acknowledged",
                    "turn.interrupted",
                    json!({"reason": reason}),
                )
            }
            ControlOutcome::Timeout => (
                "timedOut",
                "turn.interrupt.timedOut",
                json!({"reason": reason}),
            ),
            ControlOutcome::WriteFailed(error) => (
                "failed",
                "turn.interrupt.failed",
                json!({"reason": reason, "error": error}),
            ),
        };
        self.raw_log.write(raw_kind, Some(raw_payload));
        self.publish(event::interrupt_outcome(
            &request_id,
            outcome_name,
            current_generation,
            None,
        ));
    }

    pub fn respond_permission(
        &self,
        identity: &RuntimeIdentity,
        request_id: &str,
        decision: PermissionDecisionInput,
    ) -> Result<(), AgentScopeError> {
        self.check_identity(identity)?;
        let pending = {
            let mut state = self.lock_state();
            if state.closed {
                return Err(AgentScopeError::ScopeClosed);
            }
            state.pending_permissions.remove(request_id)
        };
        let Some(pending) = pending else {
            return Err(AgentScopeError::UnknownPermissionRequest);
        };
        let automatic_log = match &decision {
            PermissionDecisionInput::AutoAllowRepoPrompt {
                match_source,
                normalized_tool_name,
                server_identifier,
            } => Some((
                "approval.autoApprove.repoPrompt",
                json!({
                    "requestID": request_id,
                    "toolName": pending.tool_name,
                    "matchSource": match_source,
                    "normalizedToolName": normalized_tool_name,
                    "serverIdentifier": server_identifier,
                }),
            )),
            PermissionDecisionInput::AutoAllowFallback => Some((
                "approval.autoApprove.fallback",
                json!({"requestID": request_id, "toolName": pending.tool_name}),
            )),
            PermissionDecisionInput::Allow { .. } | PermissionDecisionInput::Deny { .. } => None,
        };
        let decision: PermissionDecision = decision.into();
        let suggestions = (!pending.permission_suggestions.is_empty())
            .then_some(pending.permission_suggestions.as_slice());
        let response = permission::permission_response_payload(
            &decision,
            &pending.input,
            suggestions,
            pending.tool_use_id.as_deref(),
        );
        let line = codec::encode_control_response_success(request_id, Some(&response));
        if let Err(reason) =
            control::send_control_request_without_response(|| self.write_line(line))
        {
            // Keep the request retryable/surfaceable when the automatic response did not leave the
            // process. The adapter falls back to the normal UI request in this case; removing it
            // permanently before a failed write would strand the CLI waiting on an unanswerable ID.
            self.lock_state()
                .pending_permissions
                .insert(request_id.to_string(), pending);
            // Mirrors Swift's `respondToPermission` catch block calling `failProtocolAndShutdown`
            // (§15.6) -- raw-log observability only, not a forced shutdown; see the identical note on
            // `handle_control_request`'s unsupported-subtype write-failure path.
            self.raw_log.write(
                "session.failProtocol",
                Some(json!({"message": format!("Failed to submit Claude approval decision: {reason}")})),
            );
            return Err(AgentScopeError::TransportWrite(reason));
        }
        if let Some((kind, mut payload)) = automatic_log {
            if let Some(object) = payload.as_object_mut() {
                object.insert("response".to_string(), Value::Object(response));
            }
            self.raw_log.write(kind, Some(payload));
        } else {
            self.raw_log.write(
                "approval.response.sent",
                Some(json!({
                    "requestID": request_id,
                    "decision": match &decision {
                        PermissionDecision::Allow { include_updated_permissions: false } => "accept",
                        PermissionDecision::Allow { include_updated_permissions: true } => "acceptForSession",
                        PermissionDecision::Deny { interrupt: false, .. } => "decline",
                        PermissionDecision::Deny { interrupt: true, .. } => "cancel",
                    },
                    "response": response,
                })),
            );
        }
        if matches!(
            decision,
            PermissionDecision::Deny {
                interrupt: true,
                ..
            }
        ) {
            self.publish(
                AgentClaudeEvent::new(AgentClaudeEventKind::ApprovalCancelled)
                    .with_field("request_id", request_id.to_string()),
            );
        }
        Ok(())
    }

    /// P6-7 (design D-6/D-9, `docs/architecture/rust-agent-claude-v1.md` §2.2): real ACK
    /// tracking, closing the gap the P6-6 placeholder's doc comment named as "P6-7's job". Ports
    /// the live-update half of `applyModelAndEffort(model:effortLevel:)`
    /// (`ClaudeNativeProcessSessionController.swift:460-491`), which `await`s
    /// `sendControlRequest(request:timeoutSeconds: 5.0)` and throws on timeout/failure --
    /// mirroring `interrupt_turn`'s shape exactly: the fast, synchronous half (identity/closed
    /// checks, request construction) runs inline and returns a receipt immediately (charter
    /// §8.2's fast-enqueue contract); only the genuine ACK round trip is pushed onto a
    /// background thread, with the outcome published later as a `flagSettingsApplied` terminal-
    /// class event correlated by this same `request_id`.
    pub fn apply_model_and_effort(
        self: &Arc<Self>,
        identity: &RuntimeIdentity,
        model: Option<String>,
        effort: Option<String>,
        disposition: FlagSettingsDisposition,
    ) -> Result<String, AgentScopeError> {
        self.check_identity(identity)?;
        {
            let state = self.lock_state();
            if state.closed {
                return Err(AgentScopeError::ScopeClosed);
            }
        }
        let request_id = format!(
            "flags-{}",
            self.next_request_id.fetch_add(1, Ordering::SeqCst)
        );
        let settings = flag_settings(model.as_deref(), effort.as_deref());
        match disposition {
            FlagSettingsDisposition::RestartRequired => {
                self.raw_log.write(
                    "session.flagSettingsDeferred",
                    Some(json!({
                        "reason": "launch_environment_changed",
                        "model": model.as_deref(),
                    })),
                );
                self.publish(
                    AgentClaudeEvent::new(AgentClaudeEventKind::FlagSettingsApplied)
                        .with_field("request_id", request_id.as_str())
                        .with_field("outcome", "restartRequired"),
                );
                return Ok(request_id);
            }
            FlagSettingsDisposition::PendingInitialHandshake => {
                self.raw_log.write(
                    "session.flagSettingsPending",
                    Some(json!({"settings": settings.as_ref().cloned().map(Value::Object)})),
                );
                self.publish(
                    AgentClaudeEvent::new(AgentClaudeEventKind::FlagSettingsApplied)
                        .with_field("request_id", request_id.as_str())
                        .with_field("outcome", "pending"),
                );
                return Ok(request_id);
            }
            FlagSettingsDisposition::Initial | FlagSettingsDisposition::Live => {}
        }
        let Some(settings) = settings else {
            self.publish(
                AgentClaudeEvent::new(AgentClaudeEventKind::FlagSettingsApplied)
                    .with_field("request_id", request_id.as_str())
                    .with_field("outcome", "applied"),
            );
            return Ok(request_id);
        };
        let scope = Arc::clone(self);
        let thread_request_id = request_id.clone();
        let spawn_result = thread::Builder::new()
            .name("agent-claude-flag-settings".to_string())
            .spawn(move || {
                scope.run_flag_settings_roundtrip(thread_request_id, settings, disposition)
            });
        if spawn_result.is_err() {
            // Thread-spawn failure is treated the same as a transport failure -- the caller
            // still gets a receipt (charter §8.2's fast-enqueue contract), and the outcome is
            // reported as `failed` rather than left forever unresolved, mirroring
            // `interrupt_turn`'s identical fallback.
            self.publish(
                AgentClaudeEvent::new(AgentClaudeEventKind::FlagSettingsApplied)
                    .with_field("request_id", request_id.as_str())
                    .with_field("outcome", "failed"),
            );
        }
        Ok(request_id)
    }

    /// Contract-anchor: Swift's live-update timeout (`:485`, `timeoutSeconds: 5.0`). The initial-
    /// handshake call site (`:774`) uses `sendControlRequest(request:)`'s own default instead --
    /// out of scope here, since that path has no Rust FFI-crossing counterpart at all (it runs
    /// entirely inside `start_or_resume`, contract §2.5).
    const FLAG_SETTINGS_ACK_TIMEOUT: Duration = Duration::from_secs(5);

    fn run_flag_settings_roundtrip(
        &self,
        request_id: String,
        settings: Map<String, Value>,
        disposition: FlagSettingsDisposition,
    ) {
        let request = apply_flag_settings_request(&settings);
        self.raw_log.write(
            "control.request.sent",
            Some(json!({
                "requestID": request_id.as_str(),
                "request": Value::Object(request.clone()),
                "expectsResponse": true,
            })),
        );
        let write_request_id = request_id.clone();
        let outcome = control::send_control_request(
            &self.control,
            &request_id,
            Self::FLAG_SETTINGS_ACK_TIMEOUT,
            || {
                let line = codec::encode_control_request(&write_request_id, &request);
                self.write_line(line)
            },
        );
        let mut event = AgentClaudeEvent::new(AgentClaudeEventKind::FlagSettingsApplied)
            .with_field("request_id", request_id.as_str());
        event = match outcome {
            ControlOutcome::Response(response) if response.subtype == "success" => {
                let response_payload = response.response.unwrap_or_default();
                let mut raw_payload = json!({
                    "settings": Value::Object(settings.clone()),
                    "response": Value::Object(response_payload.clone()),
                });
                if disposition == FlagSettingsDisposition::Live {
                    raw_payload["source"] = json!("live_update");
                }
                self.raw_log
                    .write("session.flagSettingsApplied", Some(raw_payload));
                event = event.with_field("outcome", "applied");
                event
                    .fields
                    .insert("response".to_string(), Value::Object(response_payload));
                event
            }
            ControlOutcome::Response(response) => event.with_field("outcome", "failed").with_field(
                "error",
                response.error.unwrap_or_else(|| {
                    format!("Unexpected control response subtype: {}", response.subtype)
                }),
            ),
            ControlOutcome::Timeout => event.with_field("outcome", "timedOut"),
            ControlOutcome::WriteFailed(reason) => event
                .with_field("outcome", "failed")
                .with_field("error", reason),
        };
        self.publish(event);
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
            self.raw_log.write("session.shutdown", None);
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
        *self
            .stdin
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
        if let Some(handle) = process {
            process::reaper::terminate_and_reap(
                &self.reaper,
                handle.pid,
                handle.reaper_token,
                Duration::from_secs(2),
            );
        }
        for thread in self
            .reader_threads
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .drain(..)
        {
            let _ = thread.join();
        }
        Ok(())
    }

    fn write_line(&self, mut bytes: Vec<u8>) -> Result<(), String> {
        if self.raw_log.is_enabled() {
            self.raw_log
                .write("protocol.outbound.raw", Some(raw_line_payload(&bytes)));
        }
        bytes.push(b'\n');
        let mut guard = self
            .stdin
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some((_owner_pid, file)) = guard.as_mut() else {
            return Err("stdin is not open".to_string());
        };
        file.write_all(&bytes).map_err(|error| error.to_string())
    }

    // ---- Inline stdout pipeline (INV-P6-2): read -> frame -> decode -> translate -> publish ---

    fn on_framer_overflow(&self, dropped_bytes: usize, retained_bytes: usize) {
        self.lock_state().framer_overflow_count += 1;
        self.raw_log.write(
            "framer.overflow",
            Some(json!({"droppedBytes": dropped_bytes, "retainedBytes": retained_bytes})),
        );
        self.publish(
            AgentClaudeEvent::new(AgentClaudeEventKind::FramerOverflow)
                .with_field("dropped_bytes", dropped_bytes as u64)
                .with_field("retained_bytes", retained_bytes as u64),
        );
    }

    /// P6-7 (D-9/R9): `framer.nonJSONCandidateReset` -- the framer's own diagnostic hook
    /// (`FramerDiagnostic::NonJsonCandidateQuoteStateReset`) has no counter/event twin (unlike
    /// `Overflow`'s), so this is a raw-log-only observation, matching Swift's own treatment of the
    /// equivalent kind (a raw-log record, no separate lossless/coalescible event).
    fn on_framer_non_json_candidate_reset(&self) {
        self.raw_log.write("framer.nonJSONCandidateReset", None);
    }

    fn on_protocol_drift(&self, site: &'static str) {
        self.lock_state().protocol_drift_count += 1;
        self.publish(
            AgentClaudeEvent::new(AgentClaudeEventKind::ProtocolDrift).with_field("site", site),
        );
    }

    fn handle_line(self: &Arc<Self>, line: &[u8]) {
        self.raw_log
            .write("protocol.inbound.raw", Some(raw_line_payload(line)));
        match codec::decode_line(line) {
            Ok(Some(message)) => self.route_message(message),
            Ok(None) => {}
            Err(CodecError::InvalidJson) => {
                let turn_in_flight = self.lock_state().turns.has_pending_turn_ids();
                let raw_log = &self.raw_log;
                let outcome = recovery::recover_invalid_json_line(line, turn_in_flight, |diag| {
                    raw_log_recovery_diagnostic(raw_log, &diag)
                });
                match outcome {
                    RecoveryOutcome::Recovered(messages) => {
                        for message in messages {
                            self.route_message(message);
                        }
                    }
                    RecoveryOutcome::PlaintextSalvage(text) => {
                        let result = StreamResult {
                            kind: "content".to_string(),
                            text: Some(text),
                            ..Default::default()
                        };
                        self.emit_stream_result(result);
                    }
                    RecoveryOutcome::Declined => self.raw_log.write(
                        "protocol.decode.skipped",
                        Some(json!({
                            "preview": utf8_preview(line, 512),
                            "codecError": CodecError::InvalidJson.to_string(),
                        })),
                    ),
                }
            }
            // `protocol.decode.failed` ('a non-`CodecError` decode failure') has no Rust equivalent:
            // this codec's decode surface is total via two typed `CodecError` variants, so there is
            // no third "unexpected exception" case to log (§15.6's named exclusion #5). This branch
            // is `UnsupportedPayload`, an already-classified, non-fatal case with its own
            // `protocolDrift` event -- not the kind this raw-log kind names.
            Err(CodecError::UnsupportedPayload) => {
                self.on_protocol_drift("codec.unsupportedPayload")
            }
        }
    }

    fn route_message(self: &Arc<Self>, message: InboundMessage) {
        match &message {
            InboundMessage::StreamPayload(payload) => {
                self.raw_log.write(
                    "protocol.inbound.streamPayload",
                    Some(Value::Object(payload.clone())),
                );
            }
            InboundMessage::ControlRequest(request) => {
                self.raw_log.write(
                    "protocol.inbound.controlRequest",
                    Some(json!({
                        "requestID": request.request_id,
                        "subtype": request.subtype,
                        "request": request.request,
                    })),
                );
            }
            InboundMessage::ControlResponse(response) => {
                self.raw_log.write(
                    "protocol.inbound.controlResponse",
                    Some(control_response_inbound_log_payload(response)),
                );
            }
            InboundMessage::ControlCancelRequest { request_id } => {
                self.raw_log.write(
                    "protocol.inbound.controlCancelRequest",
                    Some(json!({"requestID": request_id})),
                );
            }
            InboundMessage::KeepAlive => self.raw_log.write("protocol.inbound.keepAlive", None),
        }
        match message {
            InboundMessage::StreamPayload(payload) => self.handle_stream_payload(&payload),
            InboundMessage::ControlRequest(request) => self.handle_control_request(&request),
            InboundMessage::ControlResponse(response) => {
                self.raw_log.write(
                    "control.response.received",
                    Some(control_response_received_log_payload(&response)),
                );
                let request_id = response.request_id.clone();
                self.control.resolve(&request_id, response);
            }
            InboundMessage::ControlCancelRequest { request_id } => {
                self.raw_log.write(
                    "control.request.cancelled",
                    Some(json!({"requestID": request_id})),
                );
            }
            InboundMessage::KeepAlive => {}
        }
    }

    fn handle_control_request(&self, request: &ControlRequest) {
        self.raw_log.write(
            "control.request.received",
            Some(json!({
                "requestID": request.request_id,
                "subtype": request.subtype,
                "request": request.request,
            })),
        );
        if let Some(parsed) = permission::parse_can_use_tool_request(request) {
            let request_id = parsed.request_id.clone();
            self.raw_log.write(
                "approval.request.emitted",
                Some(json!({"requestID": request_id, "toolName": parsed.tool_name})),
            );
            let approval_event = event::approval_request(&parsed);
            self.lock_state()
                .pending_permissions
                .insert(request_id, parsed);
            self.publish(approval_event);
            return;
        }
        let line =
            permission::encode_unsupported_subtype_response(&request.request_id, &request.subtype);
        if self.write_line(line).is_err() {
            // Mirrors Swift's `default:` branch in `handleControlRequest` catching a failed
            // `sendLine` and calling `failProtocolAndShutdownSoon` (§15.6). The Rust port reproduces
            // the raw-log observability only, not the forced shutdown -- D-4's own established
            // pattern of downgrading a Swift crash/forced-teardown path to a counted diagnostic
            // rather than adding a new forced-shutdown behavior this slice did not otherwise need.
            self.raw_log.write(
                "session.failProtocol",
                Some(json!({"message": format!("Failed replying to unsupported Claude control request ({})", request.subtype)})),
            );
        }
    }

    fn handle_stream_payload(self: &Arc<Self>, payload: &Map<String, Value>) {
        let is_result_payload = payload.get("type").and_then(Value::as_str) == Some("result");
        let (results, observed_session_id) = {
            let mut state = self.lock_state();
            let results = state.translator.parse_stream_payload(payload);
            (results, state.translator.cli_session_id.clone())
        };
        if let Some(observed_session_id) = observed_session_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            self.raw_log.set_session_id(observed_session_id);
        }
        if let Some(runtime_init_payload) =
            runtime_init_stream_log_payload(payload, observed_session_id.as_deref())
        {
            self.raw_log
                .write("runtime.init.stream", Some(runtime_init_payload));
        }
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
    fn handle_authoritative_result(
        self: &Arc<Self>,
        payload: &Map<String, Value>,
        result: &StreamResult,
    ) {
        // Swift's `handleStreamPayload` always emits `.stream(result)` for the authoritative
        // message_stop result BEFORE its own turn-completion bookkeeping
        // (`ClaudeNativeProcessSessionController.swift:1358` precedes the `isResultPayload &&
        // message_stop` branch at `:1370`) -- the result's usage/cost/providerSessionID/
        // stopReason/modelContextWindow fields are real `AIStreamResult` payload the P6-7
        // differential must see, distinct from the `turnCompleted` event's own minimal `status`
        // payload published below. Routed through the same `emit_stream_result` every other
        // translated kind uses (falls to the "message_stop" isn't its own match arm -> `_`
        // TaskProgress bucket, §7.1's coalescible catch-all -- it is not itself a turn boundary;
        // `turnCompleted` is), so suppression and resnapshot-append stay uniform with every other
        // kind rather than duplicated here.
        self.emit_stream_result(result.clone());

        let is_error = payload
            .get("is_error")
            .or_else(|| payload.get("isError"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let subtype = payload
            .get("subtype")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let stop_reason = payload
            .get("stop_reason")
            .or_else(|| payload.get("stopReason"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
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
        let (turn_event, fallback_ticket) = {
            let mut state = self.lock_state();
            let status = state.turns.determine_status(
                is_error,
                &subtype,
                &stop_reason,
                result.stop_reason.as_deref(),
                nested_stop_reason.as_deref(),
                &result_errors,
            );
            let event = state
                .turns
                .on_authoritative_result(status, |_diag| diagnostics += 1);
            (event, state.turns.fallback_poll_ticket())
        };
        if diagnostics > 0 {
            self.on_protocol_drift("turnState.authoritativeResult");
        }
        if let Some(TurnEvent::TurnCompleted { turn_id, status }) = turn_event {
            self.publish(event::turn_completed(turn_id, status).with_turn_id(turn_id));
        }
        self.schedule_idle_fallback(fallback_ticket);
    }

    fn emit_stream_result(self: &Arc<Self>, result: StreamResult) {
        let raw_payload = Value::Object(stream_result_log_payload(&result));
        if should_suppress_user_facing_stream_result(&result) {
            self.raw_log
                .write("translator.streamResultSuppressed", Some(raw_payload));
            return;
        }
        self.raw_log
            .write("translator.streamResult", Some(raw_payload));
        // Resnapshot append happens under the state lock; the truncation event (if any) is
        // published only after the lock is released -- "publish outside the scope-state lock"
        // (design §5.1's lock-order rule, ported verbatim from `inventory_scope::scope`).
        let truncation = {
            let mut state = self.lock_state();
            if state.turns.has_pending_turn_ids() {
                let chunk = result
                    .text
                    .as_deref()
                    .or(result.reasoning.as_deref())
                    .unwrap_or("");
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
                self.publish_stream_result_event(AgentClaudeEventKind::AssistantDelta, &result)
            }
            "reasoning" => {
                self.publish_stream_result_event(AgentClaudeEventKind::ReasoningDelta, &result)
            }
            "tool_call" => {
                self.publish_stream_result_event(AgentClaudeEventKind::ToolUseStarted, &result)
            }
            "tool_result" => {
                self.publish_stream_result_event(AgentClaudeEventKind::ToolResult, &result)
            }
            "error" => self.publish_stream_result_event(AgentClaudeEventKind::Error, &result),
            "lifecycle" => {
                self.publish_stream_result_event(AgentClaudeEventKind::RuntimeInit, &result)
            }
            _ => {
                // Every other translated kind ("usage", "task_progress", "system", "status",
                // "final_content", "auth_status", a forwarded non-authoritative "message_stop", and
                // any future kind) is contract §7.1's `taskProgress` row: a routine, coalescible
                // progress fact, never a turn boundary. That classification only governs pressure
                // policy -- `stream_result_wire_fields` still carries the full field set (including
                // `type`, so the true translator kind survives the coarse wire `kind`) so the P6-7
                // turn-level differential can reconstruct an equivalent `AIStreamResult` regardless
                // of which wire kind carried it. This closes the fidelity gap this branch
                // previously (pre-P6-7) left as a single `text`-only field.
                self.publish_stream_result_event(AgentClaudeEventKind::TaskProgress, &result);
            }
        }
    }

    /// D-6 (design + contract §9): lowers `result` into `AgentClaudeEvent`'s wire fields via
    /// `stream_result_wire_fields` and publishes under `kind`. `kind` selects only the coarse
    /// pressure-policy classification (§7.1); the payload itself is always the full field set, not
    /// a single field -- see `stream_result_wire_fields`'s doc comment for the field list's
    /// provenance and the two structural exclusions.
    fn publish_stream_result_event(&self, kind: AgentClaudeEventKind, result: &StreamResult) {
        let mut event = AgentClaudeEvent::new(kind);
        event.fields = stream_result_wire_fields(result);
        self.publish(event);
    }

    fn handle_session_state_changed(self: &Arc<Self>, result: &StreamResult) {
        let text = result.text.clone().unwrap_or_default();
        let is_idle = text.trim().eq_ignore_ascii_case("idle");
        self.publish(
            AgentClaudeEvent::new(AgentClaudeEventKind::SessionStateChanged)
                .with_field("text", text.clone())
                .with_field("is_idle", is_idle),
        );
        let mut diagnostics = 0usize;
        let (turn_event, fallback_ticket) = {
            let mut state = self.lock_state();
            let event = state
                .turns
                .on_session_state_changed(&text, |_diag| diagnostics += 1);
            (event, state.turns.fallback_poll_ticket())
        };
        if diagnostics > 0 {
            self.on_protocol_drift("turnState.sessionStateChanged");
        }
        if let Some(TurnEvent::TurnCompleted { turn_id, status }) = turn_event {
            self.publish(event::turn_completed(turn_id, status).with_turn_id(turn_id));
        }
        self.schedule_idle_fallback(fallback_ticket);
    }

    fn schedule_idle_fallback(self: &Arc<Self>, ticket: Option<(u64, Duration)>) {
        let Some((generation, delay)) = ticket else {
            return;
        };
        if self
            .scheduled_fallback_generation
            .swap(generation, Ordering::SeqCst)
            == generation
        {
            return;
        }
        let scope = Arc::downgrade(self);
        let spawn_result = thread::Builder::new()
            .name("agent-claude-idle-fallback".to_string())
            .spawn(move || {
                thread::sleep(delay);
                if let Some(scope) = scope.upgrade() {
                    scope.poll_idle_fallback(generation);
                }
            });
        if spawn_result.is_err() {
            let _ = self.scheduled_fallback_generation.compare_exchange(
                generation,
                0,
                Ordering::SeqCst,
                Ordering::SeqCst,
            );
            self.on_protocol_drift("turnState.idleFallbackThreadSpawn");
        }
    }

    fn poll_idle_fallback(self: &Arc<Self>, generation: u64) {
        let mut diagnostics = 0usize;
        let (turn_event, next_ticket) = {
            let mut state = self.lock_state();
            let event = state
                .turns
                .poll_fallback_for_generation(generation, |_diag| diagnostics += 1);
            (event, state.turns.fallback_poll_ticket())
        };
        // Release only this worker's reservation before rescheduling. An early monotonic wake can
        // return the same generation ticket; leaving the reservation set would suppress its
        // replacement forever. A newer worker's generation is never cleared.
        let _ = self.scheduled_fallback_generation.compare_exchange(
            generation,
            0,
            Ordering::SeqCst,
            Ordering::SeqCst,
        );
        if diagnostics > 0 {
            self.on_protocol_drift("turnState.idleFallback");
        }
        if let Some(TurnEvent::TurnCompleted { turn_id, status }) = turn_event {
            self.raw_log.write(
                "lifecycle.idleFallback",
                Some(json!({"turnID": turn_id.to_string(), "status": turn_status_name(status)})),
            );
            self.publish(event::turn_completed(turn_id, status).with_turn_id(turn_id));
        }
        self.schedule_idle_fallback(next_ticket);
    }

    fn on_stdout_eof(&self, pid: libc::pid_t) {
        // The PID fence prevents a late EOF from an older child from clearing a replacement
        // process's stdin/authority. Explicit shutdown takes `state.process` before closing the
        // pipe, so its expected EOF is ignored here just like Swift's `guard !isShuttingDown`.
        let (events, unexpected_exit) = {
            let mut state = self.lock_state();
            let is_current = state
                .process
                .as_ref()
                .is_some_and(|handle| handle.pid == pid);
            if !is_current {
                return;
            }
            state.process = None;
            (state.turns.on_stdout_eof(), !state.closed)
        };
        clear_stdin_if_owned(&self.stdin, pid);
        self.raw_log.write("process.stdoutEOF", None);
        for turn_event in events {
            match turn_event {
                TurnEvent::TurnCompleted { turn_id, status } => {
                    self.publish(event::turn_completed(turn_id, status).with_turn_id(turn_id));
                }
                TurnEvent::Error(message) => {
                    // The adapter reconstructs `.error` from the same `text` field as the ordinary
                    // `error` kind (`stream_result_wire_fields`) -- one consistent field for every
                    // `AgentClaudeEventKind::Error` event, regardless of whether it originated from
                    // a translated `StreamResult` or, as here, from the EOF-drain synthesized
                    // "Claude process exited unexpectedly." message (contract §3's "EOF beyond the
                    // deferred queue" rule).
                    self.publish(
                        AgentClaudeEvent::new(AgentClaudeEventKind::Error)
                            .with_field("text", message.as_str()),
                    );
                }
            }
        }
        self.control.fail_all("stdout EOF");
        if unexpected_exit {
            self.publish(
                AgentClaudeEvent::new(AgentClaudeEventKind::ProcessExited)
                    .with_field("pid", i64::from(pid)),
            );
        }
    }

    fn publish(&self, event: AgentClaudeEvent) {
        let sink = {
            self.event_sink
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone()
        };
        let Some(sink) = sink else { return };
        let (class, coalesce_key, terminal_reserve) = event.classification();
        let kind = if terminal_reserve {
            RuntimeEventKind::Terminal
        } else {
            RuntimeEventKind::Data
        };
        let input = EventInput {
            kind,
            class,
            payload: event.encode(),
            coalesce_key,
        };
        if sink
            .hub
            .publish(&self.identity, &sink.scope_id, input)
            .is_err()
        {
            self.publish_failure_count.fetch_add(1, Ordering::Relaxed);
        }
    }
}

impl Drop for AgentClaudeScope {
    /// Orphan backstop (design §4.2/§4.7): a scope dropped without `shutdown` hands its process to
    /// the shared reaper's orphan path on a fire-and-forget thread rather than blocking the drop,
    /// exactly mirroring the Swift controller's best-effort `deinit` cleanup.
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
                .name("agent-claude-orphan-backstop".to_string())
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

fn turn_status_name(status: TurnStatus) -> &'static str {
    match status {
        TurnStatus::Completed => "completed",
        TurnStatus::Cancelled => "cancelled",
        TurnStatus::Failed => "failed",
    }
}

/// Byte-for-byte port of Swift's `lineRecordPayload`: cap verbatim bytes at 64 KiB, preserve the
/// original byte count, use UTF-8 only when the retained prefix is valid, otherwise base64-encode
/// it, and mark truncation. Keeping this exact matters because D-9's corpus capture consumes these
/// records as fixtures rather than treating them as presentation-only text.
fn raw_line_payload(bytes: &[u8]) -> Value {
    const MAX_LOG_RECORD_TEXT_BYTES: usize = 64 * 1024;
    let retained = &bytes[..bytes.len().min(MAX_LOG_RECORD_TEXT_BYTES)];
    let truncated = bytes.len() > MAX_LOG_RECORD_TEXT_BYTES;
    let mut payload = Map::new();
    payload.insert("byteCount".to_string(), json!(bytes.len()));
    match std::str::from_utf8(retained) {
        Ok(text) => {
            payload.insert("encoding".to_string(), json!("utf8"));
            payload.insert("text".to_string(), json!(text));
            if truncated {
                payload.insert("truncated".to_string(), Value::Bool(true));
            }
        }
        Err(_) => {
            payload.insert("encoding".to_string(), json!("base64"));
            payload.insert("base64".to_string(), json!(base64_encode(retained)));
            payload.insert("truncated".to_string(), Value::Bool(truncated));
        }
    }
    Value::Object(payload)
}

fn control_response_inbound_log_payload(response: &ControlResponse) -> Value {
    json!({
        "requestID": response.request_id,
        "subtype": response.subtype,
        "response": response.response,
        "error": response.error,
        "pendingPermissionRequestsCount": response.pending_permission_requests.len(),
    })
}

fn control_response_received_log_payload(response: &ControlResponse) -> Value {
    json!({
        "requestID": response.request_id,
        "subtype": response.subtype,
        "error": response.error,
        "pendingPermissionRequestsCount": response.pending_permission_requests.len(),
    })
}

fn runtime_init_stream_log_payload(
    payload: &Map<String, Value>,
    observed_session_id: Option<&str>,
) -> Option<Value> {
    if payload.get("type").and_then(Value::as_str) != Some("system")
        || !payload
            .get("subtype")
            .and_then(Value::as_str)
            .is_some_and(|subtype| subtype.eq_ignore_ascii_case("init"))
    {
        return None;
    }
    let tools: Vec<String> = payload
        .get("tools")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let mut mcp_server_statuses = Map::new();
    if let Some(servers) = payload.get("mcp_servers").and_then(Value::as_array) {
        for server in servers.iter().filter_map(Value::as_object) {
            let Some(name) = server.get("name").and_then(Value::as_str) else {
                continue;
            };
            if name.trim().is_empty() {
                continue;
            }
            mcp_server_statuses.insert(
                name.to_string(),
                json!(server.get("status").and_then(Value::as_str).unwrap_or("")),
            );
        }
    }
    Some(json!({
        "sessionID": observed_session_id.unwrap_or(""),
        "tools": tools,
        "mcpServerStatuses": mcp_server_statuses,
    }))
}

fn clear_stdin_if_owned(stdin: &Mutex<Option<(libc::pid_t, File)>>, pid: libc::pid_t) {
    let mut stdin = stdin
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if matches!(stdin.as_ref(), Some((owner_pid, _)) if *owner_pid == pid) {
        *stdin = None;
    }
}

fn stream_result_log_payload(result: &StreamResult) -> Map<String, Value> {
    let mut payload = Map::new();
    payload.insert("type".to_string(), json!(result.kind));
    payload.insert("text".to_string(), json!(result.text));
    payload.insert("reasoning".to_string(), json!(result.reasoning));
    payload.insert("toolName".to_string(), json!(result.tool_name));
    payload.insert(
        "toolInvocationID".to_string(),
        json!(
            result
                .tool_invocation_id
                .map(|identifier| identifier.0.to_string())
        ),
    );
    payload.insert("toolIsError".to_string(), json!(result.tool_is_error));
    payload.insert("promptTokens".to_string(), json!(result.prompt_tokens));
    payload.insert(
        "completionTokens".to_string(),
        json!(result.completion_tokens),
    );
    payload.insert(
        "contextUsedTokens".to_string(),
        json!(result.context_used_tokens),
    );
    payload.insert(
        "providerSessionID".to_string(),
        json!(result.provider_session_id),
    );
    payload.insert("stopReason".to_string(), json!(result.stop_reason));
    if let Some(tool_args_json) = &result.tool_args_json {
        payload.insert("toolArgsJSON".to_string(), json!(tool_args_json));
    }
    if let Some(tool_result_json) = &result.tool_result_json {
        payload.insert("toolResultJSON".to_string(), json!(tool_result_json));
    }
    payload
}

fn apply_flag_settings_request(settings: &Map<String, Value>) -> Map<String, Value> {
    let mut request = Map::new();
    request.insert("subtype".to_string(), json!("apply_flag_settings"));
    request.insert("settings".to_string(), Value::Object(settings.clone()));
    request
}

fn flag_settings(model: Option<&str>, effort: Option<&str>) -> Option<Map<String, Value>> {
    let mut settings = Map::new();
    let model = model.map(str::trim).filter(|value| !value.is_empty());
    if let Some(model) = model.filter(|value| !value.eq_ignore_ascii_case("default")) {
        settings.insert("model".to_string(), json!(model));
    }
    if let Some(effort) = effort {
        settings.insert("effortLevel".to_string(), json!(effort));
    }
    (!settings.is_empty()).then_some(settings)
}

fn utf8_preview(bytes: &[u8], limit: usize) -> String {
    String::from_utf8(bytes.iter().copied().take(limit).collect())
        .unwrap_or_else(|_| "<non-utf8>".to_string())
}

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let a = chunk[0];
        let b = chunk.get(1).copied().unwrap_or(0);
        let c = chunk.get(2).copied().unwrap_or(0);
        output.push(TABLE[(a >> 2) as usize] as char);
        output.push(TABLE[(((a & 0x03) << 4) | (b >> 4)) as usize] as char);
        if chunk.len() > 1 {
            output.push(TABLE[(((b & 0x0f) << 2) | (c >> 6)) as usize] as char);
        } else {
            output.push('=');
        }
        if chunk.len() > 2 {
            output.push(TABLE[(c & 0x3f) as usize] as char);
        } else {
            output.push('=');
        }
    }
    output
}

/// P6-7 (D-9/R9): maps each [`RecoveryDiagnostic`] variant to its named raw-log kind
/// (`recovery.rs`'s own doc comment on each variant is the authoritative mapping; this function
/// only translates that mapping into an actual write call).
fn raw_log_recovery_diagnostic(
    raw_log: &super::raw_event_log::RawEventLogWriter,
    diagnostic: &recovery::RecoveryDiagnostic,
) {
    use recovery::RecoveryDiagnostic;
    match diagnostic {
        RecoveryDiagnostic::ConcatenatedRecoverySkipped {
            byte_count,
            threshold,
        } => {
            raw_log.write(
                "protocol.decode.concatenatedRecoverySkipped",
                Some(json!({"byteCount": byte_count, "threshold": threshold})),
            );
        }
        RecoveryDiagnostic::RecoveredSegmentSkipped { preview, error } => {
            raw_log.write(
                "protocol.decode.recoveredSegmentSkipped",
                Some(json!({"preview": preview, "error": error})),
            );
        }
        RecoveryDiagnostic::RecoveredSegment { bytes } => {
            raw_log.write(
                "protocol.inbound.recoveredSegment",
                Some(raw_line_payload(bytes)),
            );
        }
        RecoveryDiagnostic::Recovered {
            segments,
            recovered_segments,
        } => {
            raw_log.write(
                "protocol.decode.recovered",
                Some(json!({"segments": segments, "recoveredSegments": recovered_segments})),
            );
        }
        RecoveryDiagnostic::RecoveredTail {
            start_offset,
            byte_count,
            preview,
        } => {
            raw_log.write(
                "protocol.inbound.recoveredTail",
                Some(json!({"startOffset": start_offset, "byteCount": byte_count, "preview": preview})),
            );
        }
        RecoveryDiagnostic::RecoveredJsonStringControlChars { repaired } => {
            raw_log.write(
                "protocol.decode.recoveredJSONStringControlChars",
                Some(raw_line_payload(repaired)),
            );
        }
        RecoveryDiagnostic::RecoveredPlaintext { preview, length } => {
            raw_log.write(
                "protocol.decode.recoveredPlaintext",
                Some(json!({"preview": preview, "length": length})),
            );
        }
    }
}

/// The inline stdout pipeline INV-P6-2 requires: one thread, `read()` -> [`LineFramer::feed`] ->
/// [`AgentClaudeScope::handle_line`] -> ... -> non-blocking publish, with no intermediate queue.
///
/// Takes a **`Weak`** reference, not `Arc` -- deliberately, to avoid a retain cycle a first version
/// of this function had: `start_or_resume` spawns this thread from inside a method whose receiver
/// is `Arc<Self>`, so an `Arc` capture here would keep the scope's strong count above zero for as
/// long as this thread is blocked in `read()`, which is exactly the orphan-backstop's own trigger
/// condition (design §4.2/§4.7, contract §5.2's "backstop signals the group and hands the PID to
/// the shared reaper") -- `AgentClaudeScope::drop` would never run while its own reader thread
/// still held a strong reference to it, so a scope dropped without an explicit `shutdown()` would
/// never actually terminate its child process. Each iteration re-upgrades; a failed upgrade (every
/// other strong reference is gone) stops the thread immediately rather than waiting for the
/// process to exit on its own, since nothing is left to consume further events.
fn spawn_stdout_pipeline(
    scope: std::sync::Weak<AgentClaudeScope>,
    fd: std::os::fd::OwnedFd,
    pid: libc::pid_t,
) -> JoinHandle<()> {
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
                let Some(strong_scope) = scope.upgrade() else {
                    return;
                };
                framer.feed(
                    &buf[..n],
                    |diagnostic| match diagnostic {
                        super::framer::FramerDiagnostic::Overflow {
                            dropped_bytes,
                            retained_bytes,
                        } => {
                            strong_scope.on_framer_overflow(dropped_bytes, retained_bytes);
                        }
                        super::framer::FramerDiagnostic::NonJsonCandidateQuoteStateReset => {
                            strong_scope.on_framer_non_json_candidate_reset();
                        }
                    },
                    |line| strong_scope.handle_line(&line),
                );
            }
            let Some(strong_scope) = scope.upgrade() else {
                return;
            };
            framer.flush(|line| strong_scope.handle_line(&line));
            strong_scope.on_stdout_eof(pid);
        })
        .expect("spawning the agent-claude stdout pipeline thread must succeed")
}

/// D-6 (design + contract §9, contract §7.1): lowers a translated `StreamResult` into the full
/// wire field set every published stream event carries, independent of which coarse
/// `AgentClaudeEventKind` classifies it for pressure-policy purposes (§7.1's sixteen kinds are
/// deliberately coarse -- a backpressure classification, not a payload shape). Field set and names
/// preserve P6-5's reviewed exhaustive stream-result inventory (tightened by follow-up `e0d4d290`)
/// minus the same two structural exclusions frozen by that contract:
/// `toolInvocationID` (a synthetic `InvocationId(u64)` can never structurally match Swift's
/// `UUID` -- carried here as `invocation_id` for *within-arm* tool_call/tool_result correlation
/// only, never compared cross-arm by value) and `cleanupHandle` (a Swift-only runtime handle with
/// no wire representation at all). `type` carries the original translator kind string
/// (`StreamResult.kind`) since the coarse `AgentClaudeEventKind` alone cannot reconstruct it --
/// this is what lets the P6-7 turn-level differential rebuild an equivalent `AIStreamResult`
/// regardless of which wire `kind` a given translated result was published under.
fn stream_result_wire_fields(result: &StreamResult) -> Map<String, Value> {
    let mut fields = Map::new();
    fields.insert("type".to_string(), json!(result.kind));
    if let Some(v) = &result.text {
        fields.insert("text".to_string(), json!(v));
    }
    if let Some(v) = &result.reasoning {
        fields.insert("reasoning".to_string(), json!(v));
    }
    if let Some(v) = result.prompt_tokens {
        fields.insert("prompt_tokens".to_string(), json!(v));
    }
    if let Some(v) = result.completion_tokens {
        fields.insert("completion_tokens".to_string(), json!(v));
    }
    if let Some(v) = result.cost {
        fields.insert("cost".to_string(), json!(v));
    }
    if let Some(v) = &result.tool_name {
        fields.insert("tool_name".to_string(), json!(v));
    }
    if let Some(v) = &result.tool_args {
        fields.insert("tool_args".to_string(), json!(v));
    }
    if let Some(v) = &result.tool_output {
        fields.insert("tool_output".to_string(), json!(v));
    }
    if let Some(id) = result.tool_invocation_id {
        fields.insert("invocation_id".to_string(), json!(id.0));
    }
    if let Some(v) = &result.tool_result_json {
        fields.insert("tool_result_json".to_string(), json!(v));
    }
    if let Some(v) = &result.tool_args_json {
        fields.insert("tool_args_json".to_string(), json!(v));
    }
    if let Some(v) = result.tool_is_error {
        fields.insert("tool_is_error".to_string(), json!(v));
    }
    if let Some(v) = &result.provider_session_id {
        fields.insert("provider_session_id".to_string(), json!(v));
    }
    if let Some(v) = &result.stop_reason {
        fields.insert("stop_reason".to_string(), json!(v));
    }
    if let Some(v) = result.model_context_window {
        fields.insert("model_context_window".to_string(), json!(v));
    }
    if let Some(v) = result.context_used_tokens {
        fields.insert("context_used_tokens".to_string(), json!(v));
    }
    if let Some(v) = &result.content_message_id {
        fields.insert("content_message_id".to_string(), json!(v));
    }
    fields
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
        Self {
            scopes: Mutex::new(HashMap::new()),
            reaper: Reaper::new(),
        }
    }
}

impl ScopeRegistry {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn open_scope(
        &self,
        identity: RuntimeIdentity,
        config: AgentClaudeScopeConfig,
    ) -> Arc<AgentClaudeScope> {
        let scope_id = AgentClaudeScopeId::mint();
        let scope = Arc::new(AgentClaudeScope::new(
            identity,
            scope_id,
            config,
            Arc::clone(&self.reaper),
        ));
        self.scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(scope_id, Arc::clone(&scope));
        scope
    }

    #[must_use]
    pub fn get(&self, scope_id: AgentClaudeScopeId) -> Option<Arc<AgentClaudeScope>> {
        self.scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&scope_id)
            .cloned()
    }

    /// Idempotent, matching `InventoryScope`'s `ScopeRegistry::close_scope` precedent.
    pub fn close_scope(
        &self,
        identity: &RuntimeIdentity,
        scope_id: AgentClaudeScopeId,
    ) -> Result<(), ScopeRegistryError> {
        let scope = self
            .scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&scope_id);
        let Some(scope) = scope else { return Ok(()) };
        if scope.identity() != identity {
            self.scopes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(scope_id, Arc::clone(&scope));
            return Err(ScopeRegistryError::IdentityMismatch);
        }
        let _ = scope.shutdown(identity);
        Ok(())
    }

    #[must_use]
    pub fn scope_count(&self) -> usize {
        self.scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .len()
    }
}

/// P6-7 (D-9/R9, `docs/architecture/rust-agent-claude-v1.md` §15.6): module-internal unit tests for
/// the raw-log kind-mapping wiring on the handful of kinds `tests/agent_claude_scope.rs`'s
/// live-pipeline completeness test cannot reach: `raw_log_recovery_diagnostic`/
/// `on_framer_non_json_candidate_reset` are module-private (not re-exported, unlike
/// `RecoveryDiagnostic`/`FramerDiagnostic` themselves), so only a same-module test can call them
/// directly; and `RecoveredJsonStringControlChars` is -- per `recovery.rs`'s own closed-open-
/// question analysis -- unreachable through the real `handle_line` dispatch at all (whenever the
/// repair would succeed, the codec's own inline sanitize already succeeded first), so no live
/// script can ever trigger it regardless of module boundaries. Each test below proves the *mapping*
/// (diagnostic variant -> exact kind string -> written record) is correct in isolation, mirroring
/// `recovery.rs::tests::try_control_char_repair_succeeds_in_isolation_when_called_directly`'s own
/// precedent for testing this specific heuristic outside its unreachable real dispatch path.
#[cfg(test)]
mod raw_event_log_kind_mapping_tests {
    use super::{
        AgentClaudeScope, AgentClaudeScopeConfig, AgentClaudeScopeId, AgentScopeError,
        ControlRequest, PermissionDecisionInput, RuntimeIdentity, StreamResult, TurnStatus,
        apply_flag_settings_request, clear_stdin_if_owned, flag_settings, permission,
        raw_log_recovery_diagnostic, recovery, stream_result_log_payload,
    };
    use crate::agent_claude::process::reaper::Reaper;
    use crate::agent_claude::raw_event_log::RawEventLogWriter;
    use crate::agent_claude::translator::InvocationId;
    use serde_json::json;
    use std::sync::atomic::Ordering;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    fn writer_at(dir_name: &str) -> (std::path::PathBuf, RawEventLogWriter) {
        let dir = std::env::temp_dir().join(format!("{dir_name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("events.jsonl");
        let writer = RawEventLogWriter::new(
            true,
            Some(path.to_string_lossy().to_string()),
            crate::agent_claude::raw_event_log::RawEventLogContext::default(),
        );
        (path, writer)
    }

    fn kinds_in(path: &std::path::Path) -> Vec<String> {
        std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter_map(|value| {
                value
                    .get("kind")
                    .and_then(|k| k.as_str())
                    .map(str::to_string)
            })
            .collect()
    }

    #[test]
    fn late_eof_cannot_clear_a_replacement_process_stdin() {
        let path = std::env::temp_dir().join(format!("owned-stdin-{}", std::process::id()));
        let replacement_pid = 202;
        let stdin = Mutex::new(Some((
            replacement_pid,
            std::fs::File::create(&path).expect("temporary stdin stand-in"),
        )));

        clear_stdin_if_owned(&stdin, 101);
        assert_eq!(
            stdin
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .as_ref()
                .map(|(pid, _)| *pid),
            Some(replacement_pid),
            "an older stdout EOF must not clear the replacement process's stdin authority"
        );
        clear_stdin_if_owned(&stdin, replacement_pid);
        assert!(
            stdin
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .is_none(),
            "the owning process EOF must still close its own stdin"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn translator_log_payload_preserves_the_exact_legacy_key_contract() {
        let complete = StreamResult {
            kind: "tool_call".to_string(),
            text: Some("text".to_string()),
            reasoning: Some("reasoning".to_string()),
            prompt_tokens: Some(11),
            completion_tokens: Some(22),
            cost: Some(0.25),
            tool_name: Some("Bash".to_string()),
            tool_args: Some("legacy args".to_string()),
            tool_output: Some("legacy output".to_string()),
            tool_invocation_id: Some(InvocationId(7)),
            tool_result_json: Some(r#"{"result":"ok"}"#.to_string()),
            tool_args_json: Some(r#"{"command":"ls"}"#.to_string()),
            tool_is_error: Some(false),
            provider_session_id: Some("session-1".to_string()),
            stop_reason: Some("end_turn".to_string()),
            model_context_window: Some(200_000),
            context_used_tokens: Some(33),
            content_message_id: Some("message-1".to_string()),
        };
        let payload = stream_result_log_payload(&complete);
        let mut keys = payload.keys().map(String::as_str).collect::<Vec<_>>();
        keys.sort_unstable();
        assert_eq!(
            keys,
            vec![
                "completionTokens",
                "contextUsedTokens",
                "promptTokens",
                "providerSessionID",
                "reasoning",
                "stopReason",
                "text",
                "toolArgsJSON",
                "toolInvocationID",
                "toolIsError",
                "toolName",
                "toolResultJSON",
                "type",
            ]
        );
        assert_eq!(payload["toolInvocationID"], "7");
        for nonlegacy_key in [
            "cost",
            "toolArgs",
            "toolOutput",
            "modelContextWindow",
            "contentMessageID",
        ] {
            assert!(
                payload.get(nonlegacy_key).is_none(),
                "{nonlegacy_key} was never part of the legacy raw-log payload"
            );
        }

        let sparse = stream_result_log_payload(&StreamResult {
            kind: "text_delta".to_string(),
            ..Default::default()
        });
        let mut sparse_keys = sparse.keys().map(String::as_str).collect::<Vec<_>>();
        sparse_keys.sort_unstable();
        assert_eq!(
            sparse_keys,
            vec![
                "completionTokens",
                "contextUsedTokens",
                "promptTokens",
                "providerSessionID",
                "reasoning",
                "stopReason",
                "text",
                "toolInvocationID",
                "toolIsError",
                "toolName",
                "type",
            ],
            "the eleven fixed legacy keys stay present even when their values are JSON null"
        );
        assert!(sparse.get("toolArgsJSON").is_none());
        assert!(sparse.get("toolResultJSON").is_none());
        for nullable_key in [
            "text",
            "reasoning",
            "toolName",
            "toolInvocationID",
            "toolIsError",
            "promptTokens",
            "completionTokens",
            "contextUsedTokens",
            "providerSessionID",
            "stopReason",
        ] {
            assert_eq!(sparse.get(nullable_key), Some(&serde_json::Value::Null));
        }
    }

    #[test]
    fn flag_settings_request_matches_the_legacy_apply_flag_settings_wire_shape() {
        assert_eq!(flag_settings(None, None), None);
        assert_eq!(flag_settings(Some(" default "), None), None);
        let settings = flag_settings(Some(" opus "), Some("high")).expect("non-empty settings");
        assert_eq!(settings["model"], "opus");
        assert_eq!(settings["effortLevel"], "high");
        let request = apply_flag_settings_request(&settings);
        assert_eq!(request["subtype"], "apply_flag_settings");
        assert_eq!(request["settings"], serde_json::Value::Object(settings));
        assert!(
            request.get("model").is_none(),
            "model belongs inside settings, never at top level"
        );
        assert!(
            request.get("effort").is_none(),
            "the legacy field is settings.effortLevel"
        );
    }

    #[test]
    fn every_recovery_diagnostic_variant_maps_to_its_named_kind() {
        let (path, writer) = writer_at("raw-log-recovery-diagnostic-mapping");
        raw_log_recovery_diagnostic(
            &writer,
            &recovery::RecoveryDiagnostic::ConcatenatedRecoverySkipped {
                byte_count: 1,
                threshold: 1,
            },
        );
        raw_log_recovery_diagnostic(
            &writer,
            &recovery::RecoveryDiagnostic::RecoveredSegmentSkipped {
                preview: "bad".to_string(),
                error: "invalidJSON".to_string(),
            },
        );
        raw_log_recovery_diagnostic(
            &writer,
            &recovery::RecoveryDiagnostic::RecoveredSegment {
                bytes: b"{}".to_vec(),
            },
        );
        raw_log_recovery_diagnostic(
            &writer,
            &recovery::RecoveryDiagnostic::Recovered {
                segments: 2,
                recovered_segments: 2,
            },
        );
        raw_log_recovery_diagnostic(
            &writer,
            &recovery::RecoveryDiagnostic::RecoveredTail {
                start_offset: 3,
                byte_count: 10,
                preview: "tail".to_string(),
            },
        );
        raw_log_recovery_diagnostic(
            &writer,
            &recovery::RecoveryDiagnostic::RecoveredJsonStringControlChars {
                repaired: b"{}".to_vec(),
            },
        );
        raw_log_recovery_diagnostic(
            &writer,
            &recovery::RecoveryDiagnostic::RecoveredPlaintext {
                preview: "plain".to_string(),
                length: 40,
            },
        );

        assert_eq!(
            kinds_in(&path),
            vec![
                "session.header",
                "protocol.decode.concatenatedRecoverySkipped",
                "protocol.decode.recoveredSegmentSkipped",
                "protocol.inbound.recoveredSegment",
                "protocol.decode.recovered",
                "protocol.inbound.recoveredTail",
                "protocol.decode.recoveredJSONStringControlChars",
                "protocol.decode.recoveredPlaintext",
            ]
        );
    }

    #[test]
    fn an_early_idle_fallback_poll_releases_its_reservation_and_reschedules_the_same_generation() {
        let identity = RuntimeIdentity::new(1, "dd".repeat(16), "a".repeat(64), "b".repeat(64))
            .expect("identity");
        let config = AgentClaudeScopeConfig {
            idle_fallback: Duration::from_millis(250),
            ..AgentClaudeScopeConfig::default()
        };
        let scope = Arc::new(AgentClaudeScope::new(
            identity,
            AgentClaudeScopeId::mint(),
            config,
            Reaper::new(),
        ));
        let generation = {
            let mut state = scope.lock_state();
            state.turns.on_session_state_changed("running", |_| {});
            let turn_id = state.turns.send_user_message();
            state.last_turn_generation = turn_id;
            assert_eq!(
                state
                    .turns
                    .on_authoritative_result(TurnStatus::Completed, |_| {}),
                None
            );
            state
                .turns
                .fallback_poll_ticket()
                .expect("armed fallback")
                .0
        };

        // Simulate this generation's worker waking before its monotonic deadline. The same ticket
        // must be admitted again rather than being suppressed by its own stale reservation.
        scope
            .scheduled_fallback_generation
            .store(generation, Ordering::SeqCst);
        scope.poll_idle_fallback(generation);
        assert_eq!(
            scope.scheduled_fallback_generation.load(Ordering::SeqCst),
            generation,
            "the same-generation replacement worker must be scheduled"
        );
        std::thread::sleep(Duration::from_millis(500));
        assert!(
            !scope.lock_state().turns.has_pending_turn_ids(),
            "the replacement worker must eventually release the deferred turn"
        );
    }

    #[test]
    fn failed_permission_write_reinserts_the_request_for_ui_or_retry() {
        let identity = RuntimeIdentity::new(1, "ee".repeat(16), "a".repeat(64), "b".repeat(64))
            .expect("identity");
        let scope = AgentClaudeScope::new(
            identity.clone(),
            AgentClaudeScopeId::mint(),
            AgentClaudeScopeConfig::default(),
            Reaper::new(),
        );
        let request = ControlRequest {
            request_id: "perm-retry".to_string(),
            subtype: "can_use_tool".to_string(),
            request: serde_json::from_value(json!({
                "subtype": "can_use_tool",
                "tool_name": "mcp__RepoPrompt__read_file",
                "input": {"path": "README.md"},
            }))
            .expect("object"),
        };
        let pending = permission::parse_can_use_tool_request(&request).expect("permission request");
        scope
            .lock_state()
            .pending_permissions
            .insert(request.request_id.clone(), pending);

        assert!(matches!(
            scope.respond_permission(
                &identity,
                &request.request_id,
                PermissionDecisionInput::AutoAllowRepoPrompt {
                    match_source: "canonicalToolName".to_string(),
                    normalized_tool_name: Some("read_file".to_string()),
                    server_identifier: Some("RepoPromptCE".to_string()),
                },
            ),
            Err(AgentScopeError::TransportWrite(_))
        ));
        assert_eq!(scope.diagnostics().pending_permission_count, 1);
    }

    #[test]
    fn framer_diagnostics_map_to_their_named_kinds_through_the_real_scope_methods() {
        let (path, _writer) = writer_at("raw-log-framer-diagnostic-mapping");
        let config = AgentClaudeScopeConfig {
            raw_event_log_enabled: true,
            raw_event_log_file_path: Some(path.to_string_lossy().to_string()),
            ..AgentClaudeScopeConfig::default()
        };
        let identity = RuntimeIdentity::new(1, "cc".repeat(16), "a".repeat(64), "b".repeat(64))
            .expect("identity");
        let scope =
            AgentClaudeScope::new(identity, AgentClaudeScopeId::mint(), config, Reaper::new());
        scope.on_framer_overflow(10, 5);
        scope.on_framer_non_json_candidate_reset();

        assert_eq!(
            kinds_in(&path),
            vec![
                "session.header",
                "framer.overflow",
                "framer.nonJSONCandidateReset"
            ]
        );
    }
}
