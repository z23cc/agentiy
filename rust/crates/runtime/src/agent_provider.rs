//! P6 provider runtime authority for the non-Claude agent families.
//!
//! Codex app-server and ACP providers intentionally share one process/transport ownership
//! boundary. Provider-specific protocol meaning stays in Swift; this module owns the parts that
//! must not be duplicated by each provider controller: spawn attributes, line framing, bounded
//! stderr/event publication, serialized stdin writes, monotonically sequenced observations,
//! cancellation and process reaping. Payloads are preserved as JSON values when possible and as
//! UTF-8-lossy strings otherwise so malformed provider output is observable without panicking the
//! authority.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use serde_json::{Value, json};

use crate::agent_claude::framer::LineFramer;
use crate::agent_claude::process::{self, ReapOutcome, Reaper, SpawnConfig};
use crate::{EventClass, EventInput, RuntimeEventKind, RuntimeIdentity, ScopeId, SubscriptionHub};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProviderProtocol {
    CodexAppServer,
    Acp,
}

impl ProviderProtocol {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CodexAppServer => "codexAppServer",
            Self::Acp => "acp",
        }
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
    stdin: Arc<Mutex<File>>,
}

struct ScopeState {
    closed: bool,
    next_sequence: u64,
    process: Option<RunningProcess>,
}

/// One Codex or ACP provider process. The scope never interprets provider JSON; it only wraps each
/// line in a versioned event envelope and publishes it through the existing subscription hub.
pub struct AgentProviderScope {
    identity: RuntimeIdentity,
    id: AgentProviderScopeId,
    config: AgentProviderScopeConfig,
    reaper: Arc<Reaper>,
    state: Mutex<ScopeState>,
    event_sink: Mutex<Option<(Arc<SubscriptionHub>, ScopeId)>>,
    readers_remaining: Arc<(Mutex<u8>, Condvar)>,
}

impl AgentProviderScope {
    fn new(
        identity: RuntimeIdentity,
        id: AgentProviderScopeId,
        config: AgentProviderScopeConfig,
        reaper: Arc<Reaper>,
    ) -> Arc<Self> {
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
        self.validate(identity)?;
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
            stdin,
        });
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
        Ok(StartReceipt {
            pid,
            process_group_id,
        })
    }

    pub fn send_line(
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
                .map(|process| Arc::clone(&process.stdin))?;
            state.next_sequence = state.next_sequence.saturating_add(1);
            (stdin, state.next_sequence)
        };
        let mut frame = payload.to_vec();
        if frame.last().copied() != Some(b'\n') {
            frame.push(b'\n');
        }
        let result = stdin
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .write_all(&frame);
        if let Err(error) = result {
            return Err(AgentProviderScopeError::TransportWrite(error.to_string()));
        }
        self.publish_with_sequence(
            "outbound",
            Value::String(String::from_utf8_lossy(payload).into_owned()),
            sequence,
            false,
        );
        Ok(sequence)
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
        crate::agent_claude::process::thread_budget::increment();
        let result = thread::Builder::new()
            .name("agent-provider-stdout".into())
            .spawn(move || {
                let _budget =
                    crate::agent_claude::process::thread_budget::ThreadBudgetGuard::already_counted(
                    );
                let mut file = File::from(fd);
                let mut framer = LineFramer::default();
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
                            |line| {
                                let payload = serde_json::from_slice::<Value>(&line)
                                    .unwrap_or_else(|_| {
                                        Value::String(String::from_utf8_lossy(&line).into_owned())
                                    });
                                scope.publish(
                                    "providerMessage",
                                    json!({ "pid": pid, "payload": payload }),
                                    false,
                                );
                            },
                        );
                    } else {
                        break;
                    }
                }
                let Some(scope) = weak.upgrade() else { return };
                framer.flush(|line| {
                    let payload = serde_json::from_slice::<Value>(&line).unwrap_or_else(|_| {
                        Value::String(String::from_utf8_lossy(&line).into_owned())
                    });
                    scope.publish(
                        "providerMessage",
                        json!({ "pid": pid, "payload": payload }),
                        false,
                    );
                });
                // stdout EOF is the only per-scope terminal wait. Reusing this reader keeps the
                // shared reaper at one process-wide thread instead of adding an exit watcher per
                // provider process.
                let outcome =
                    reaper.wait_for_exit(pid, token, Duration::from_secs(365 * 24 * 60 * 60));
                scope.wait_for_other_reader();
                reaper.forget(pid, token);
                scope.finish_process(pid, outcome.unwrap_or(ReapOutcome::Lost));
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

    fn finish_process(&self, pid: i32, outcome: ReapOutcome) {
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
                json!({ "pid": pid, "exit_code": code, "signal": null })
            }
            ReapOutcome::Signaled(signal) => {
                json!({ "pid": pid, "exit_code": null, "signal": signal })
            }
            ReapOutcome::Lost => {
                json!({ "pid": pid, "exit_code": null, "signal": null, "ownership_lost": true })
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
                .any(|payload| payload.contains("providerMessage"))
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
}
