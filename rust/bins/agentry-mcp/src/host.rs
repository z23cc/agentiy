//! Session router, Unix-socket server, handshake, and the nine v1 commands.

use std::collections::{BTreeMap, VecDeque};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use agentry_agent_session_log::{
    Durability, OpenOptions, SessionId, SessionLog, SnapshotLoad, events_file_name,
};
use agentry_proto::agent_host::v1::{
    self, AttachReplay, Capability, CommandRejectionReason, CommandRequest, CommandResponse,
    HandshakeRejectReason, HostMessage, InterruptOutcome, SessionStatus, StopReason,
};
use agentry_proto::agent_host::{
    MAXIMUM_FRAME_PAYLOAD_BYTES, MAXIMUM_SNAPSHOT_CHUNK_BYTES, PROTOCOL_VERSION,
    command_fingerprint, encode_snapshot, mutation_key,
};
use agentry_runtime::agent_session_transcript::SessionState;

use crate::HostError;
use crate::client::{read_client_frame, write_host_frame};
use crate::executor::{SessionExecutor, make_session_executor};
use crate::lease::{HostLease, LeaseAcquisition, LeaseOwner, ensure_directory};
use crate::paths::APPLICATION_SUPPORT_ROOT_ENV;
use crate::workspace_authority::{WorkspaceAuthorityLease, WorkspaceClaim};
use crate::paths::{BuildFlavor, HostPaths};
use crate::peer::{self, PeerVerdict, current_identity, verify_peer};
use crate::time::rfc3339_now;
use crate::util::{hex_digest, mint_generation, random_bytes, uuid_v4};

const DEFAULT_IDLE_EXIT_SECONDS: u64 = 300;
const DEFAULT_MAX_QUEUED_EVENTS: usize = 64;
const DEFAULT_MAX_QUEUED_BYTES: usize = 256 * 1024;

static PROCESS_STOP: AtomicBool = AtomicBool::new(false);

/// Install SIGTERM/SIGINT → clean exit. Only the `agent-host` binary should call this;
/// in-process tests keep using [`HostHandle::shutdown`].
pub fn arm_process_stop_signals() {
    #[allow(unsafe_code)]
    unsafe {
        libc::signal(
            libc::SIGTERM,
            process_stop as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            process_stop as *const () as libc::sighandler_t,
        );
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
    }
}

extern "C" fn process_stop(_: libc::c_int) {
    PROCESS_STOP.store(true, Ordering::SeqCst);
}

#[derive(Clone, Debug)]
pub struct HostConfig {
    pub paths: HostPaths,
    pub build_fingerprint: String,
    pub accept_any_peer: bool,
    pub idle_exit_seconds: Option<u64>,
    pub fail_prepare_update: bool,
    pub max_queued_events: usize,
    pub max_queued_bytes: usize,
    pub bundle_identifier: String,
    /// When true, `Host::bind` fence-claims the workspace-authority flock if no GUI holder exists.
    /// Production spawn leaves this false so `--backend auto` / headless remains the single writer.
    pub claim_workspace_authority: bool,
}

impl HostConfig {
    #[must_use]
    pub fn from_env(application_support_root: Option<PathBuf>, debug_flavor: bool) -> Self {
        let flavor = if debug_flavor {
            BuildFlavor::Debug
        } else {
            BuildFlavor::Release
        };
        let root = application_support_root
            .or_else(|| std::env::var_os(APPLICATION_SUPPORT_ROOT_ENV).map(PathBuf::from));
        let paths = HostPaths::resolve(root, flavor, PROTOCOL_VERSION, peer::current_uid());
        let fingerprint = std::env::var("AGENTRY_HOST_BUILD_FINGERPRINT")
            .or_else(|_| std::env::var("AGENTRY_CORE_BUILD_FINGERPRINT"))
            .unwrap_or_else(|_| "0".repeat(64));
        let accept_any = std::env::var("AGENTRY_AGENT_HOST_ACCEPT_ANY_PEER")
            .map(|value| value == "1")
            .unwrap_or(false);
        Self {
            paths,
            build_fingerprint: fingerprint,
            accept_any_peer: accept_any,
            idle_exit_seconds: Some(DEFAULT_IDLE_EXIT_SECONDS),
            fail_prepare_update: false,
            max_queued_events: DEFAULT_MAX_QUEUED_EVENTS,
            max_queued_bytes: DEFAULT_MAX_QUEUED_BYTES,
            bundle_identifier: String::new(),
            claim_workspace_authority: false,
        }
    }
}

pub struct Host {
    inner: Arc<Mutex<HostInner>>,
    lease: HostLease,
    workspace_authority: Option<WorkspaceAuthorityLease>,
    listener: UnixListener,
    shutdown: Arc<AtomicBool>,
    host_started_at: String,
}

struct HostInner {
    config: HostConfig,
    host_instance_id: String,
    host_nonce: [u8; 16],
    sessions: BTreeMap<String, SessionSlot>,
    attachments: BTreeMap<(String, String), Attachment>,
    last_activity: Instant,
    shutting_down: bool,
}

struct SessionSlot {
    workspace_id: String,
    log: SessionLog,
    state: SessionState,
    /// Locked only around executor I/O. The host mutex is released first so a
    /// live provider turn cannot stall accept/idle checks or other clients.
    executor: Arc<Mutex<Box<dyn SessionExecutor>>>,
    generation: Vec<u8>,
    leave_unsettled: bool,
}

fn wrap_executor(executor: Box<dyn SessionExecutor>) -> Arc<Mutex<Box<dyn SessionExecutor>>> {
    Arc::new(Mutex::new(executor))
}

fn session_checkpoint_ok(session: &SessionSlot) -> bool {
    session
        .executor
        .lock()
        .map(|executor| executor.checkpoint_ok())
        .unwrap_or(false)
}

enum DispatchPrep {
    Ready(Vec<HostMessage>),
    Run(ExecutorWork),
}

struct ExecutorWork {
    session_id: String,
    request_id: String,
    operation_id: String,
    command_kind: String,
    now: String,
    executor: Arc<Mutex<Box<dyn SessionExecutor>>>,
    op: ExecutorOp,
}

enum ExecutorOp {
    Start(v1::SessionSpec),
    Steer(v1::UserMessage),
    Interrupt {
        turn_id: String,
    },
    Respond {
        interaction_id: String,
        generation: Vec<u8>,
        answer: Option<v1::InteractionAnswer>,
    },
    Stop(StopReason),
}

impl ExecutorOp {
    fn run(
        self,
        executor: &mut dyn SessionExecutor,
        now: &str,
    ) -> Result<crate::executor::ExecutorOutcome, String> {
        Ok(match self {
            Self::Start(spec) => executor.start(&spec, now),
            Self::Steer(message) => executor.steer(&message, now),
            Self::Interrupt { turn_id } => executor.interrupt(&turn_id, now),
            Self::Respond {
                interaction_id,
                generation,
                answer,
            } => executor.respond(&interaction_id, &generation, answer.as_ref(), now),
            Self::Stop(reason) => executor.stop(reason, now),
        })
    }
}

struct Attachment {
    #[allow(dead_code)]
    generation: Vec<u8>,
    outbound: VecDeque<HostMessage>,
    queued_bytes: usize,
    resnapshot_required: bool,
}

pub struct HostHandle {
    join: Option<JoinHandle<Result<(), HostError>>>,
    pub paths: HostPaths,
    pub build_fingerprint: String,
    shutdown: Arc<AtomicBool>,
}

impl HostHandle {
    pub fn shutdown(&self) {
        self.shutdown.store(true, Ordering::SeqCst);
        let _ = std::os::unix::net::UnixStream::connect(&self.paths.socket_path);
    }
}

impl Drop for HostHandle {
    fn drop(&mut self) {
        self.shutdown();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

impl Host {
    pub fn bind(config: HostConfig) -> Result<Self, HostError> {
        let host_instance_id = uuid_v4();
        let owner = LeaseOwner::rust(
            host_instance_id.clone(),
            config.build_fingerprint.clone(),
            config.paths.socket_path.display().to_string(),
        );
        let lease = match HostLease::acquire(config.paths.clone(), owner) {
            LeaseAcquisition::Acquired(lease) => lease,
            LeaseAcquisition::Contended { observed_owner } => {
                return Err(HostError::LeaseContended { observed_owner });
            }
            LeaseAcquisition::Failed(reason) => return Err(HostError::LeaseFailed(reason)),
        };
        ensure_directory(&config.paths.socket_directory, 0o700)?;
        let _ = std::fs::remove_file(&config.paths.socket_path);
        let listener = UnixListener::bind(&config.paths.socket_path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(
                &config.paths.socket_path,
                std::fs::Permissions::from_mode(0o600),
            );
        }
        let host_nonce = random_bytes::<16>();
        let mut inner = HostInner {
            config: config.clone(),
            host_instance_id,
            host_nonce,
            sessions: BTreeMap::new(),
            attachments: BTreeMap::new(),
            last_activity: Instant::now(),
            shutting_down: false,
        };
        inner.recover()?;
        let workspace_authority = if config.claim_workspace_authority {
            match WorkspaceAuthorityLease::fence_claim(&config.paths) {
                WorkspaceClaim::Acquired(lease) => Some(lease),
                WorkspaceClaim::RefusedGUI { .. }
                | WorkspaceClaim::Contended { .. }
                | WorkspaceClaim::Failed(_) => None,
            }
        } else {
            None
        };
        Ok(Self {
            inner: Arc::new(Mutex::new(inner)),
            lease,
            workspace_authority,
            listener,
            shutdown: Arc::new(AtomicBool::new(false)),
            host_started_at: rfc3339_now(),
        })
    }

    pub fn start_background(config: HostConfig) -> Result<HostHandle, HostError> {
        let host = Self::bind(config)?;
        let paths = host.paths();
        let build_fingerprint = host.build_fingerprint();
        let shutdown = Arc::clone(&host.shutdown);
        let join = thread::spawn(move || host.run());
        Ok(HostHandle {
            join: Some(join),
            paths,
            build_fingerprint,
            shutdown,
        })
    }

    #[must_use]
    pub fn paths(&self) -> HostPaths {
        self.lease.paths.clone()
    }

    #[must_use]
    pub fn build_fingerprint(&self) -> String {
        self.inner
            .lock()
            .map(|inner| inner.config.build_fingerprint.clone())
            .unwrap_or_default()
    }

    pub fn run(self) -> Result<(), HostError> {
        // Accept is non-blocking. This loop only takes `HostInner` for idle /
        // shutdown snapshots — never across provider I/O. Client threads release
        // the host mutex before `SessionExecutor` start/steer/respond.
        self.listener.set_nonblocking(true)?;
        let idle = self
            .inner
            .lock()
            .ok()
            .and_then(|inner| inner.config.idle_exit_seconds)
            .filter(|seconds| *seconds > 0);
        loop {
            if self.shutdown.load(Ordering::SeqCst) || PROCESS_STOP.load(Ordering::SeqCst) {
                break;
            }
            match self.listener.accept() {
                Ok((stream, _)) => {
                    let inner = Arc::clone(&self.inner);
                    let shutdown = Arc::clone(&self.shutdown);
                    let started_at = self.host_started_at.clone();
                    thread::spawn(move || {
                        let _ = serve_client(inner, stream, started_at, shutdown);
                    });
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(50));
                }
                Err(error) => return Err(error.into()),
            }
            if let Some(seconds) = idle {
                let expired = self.inner.lock().map(|inner| {
                    !inner.shutting_down
                        && inner.attachments.is_empty()
                        && !inner.has_live_sessions()
                        && inner.last_activity.elapsed() >= Duration::from_secs(seconds)
                });
                if expired.unwrap_or(false) {
                    break;
                }
            }
            if self
                .inner
                .lock()
                .map(|inner| inner.shutting_down)
                .unwrap_or(false)
            {
                break;
            }
        }
        let socket = self.paths().socket_path;
        drop(self.workspace_authority);
        drop(self.lease);
        let _ = std::fs::remove_file(socket);
        Ok(())
    }
}

impl HostInner {
    fn recover(&mut self) -> Result<(), HostError> {
        let now = rfc3339_now();
        for directory in self.config.paths.existing_session_directories() {
            let workspace_id = directory
                .parent()
                .and_then(|parent| parent.file_name())
                .and_then(|name| name.to_str())
                .unwrap_or("")
                .to_string();
            let Ok(entries) = std::fs::read_dir(&directory) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                    continue;
                };
                let Some(session_id) = parse_events_file_name(name) else {
                    continue;
                };
                let parsed = SessionId::parse(&session_id)?;
                let (mut log, report) = SessionLog::open(
                    &path,
                    parsed,
                    OpenOptions {
                        create_if_missing: false,
                        load_snapshot: true,
                    },
                )?;
                let mut state = match &report.snapshot {
                    SnapshotLoad::Loaded(snapshot) => SessionState::from_snapshot(snapshot.clone()),
                    _ => SessionState::placeholder(session_id.clone()),
                };
                let batch = log.read_from(report.snapshot.replay_from(), usize::MAX, usize::MAX)?;
                for entry in batch.entries {
                    state.apply(&entry.event, entry.cursor);
                }
                let was_active =
                    state.has_live_run() || state.summary().status == SessionStatus::Running as i32;
                let generation = mint_generation(&self.host_nonce, 1);
                state.set_generation(generation.clone());
                let summary = if was_active {
                    state.host_owned_summary(
                        SessionStatus::WaitingForInput,
                        "interrupted: host restarted",
                        true,
                        now.clone(),
                    )
                } else {
                    let mut summary = state.summary().clone();
                    summary.generation = generation.clone();
                    summary.updated_at = now.clone();
                    summary
                };
                let event = v1::AgentSessionEvent {
                    recorded_at: now.clone(),
                    body: Some(v1::agent_session_event::Body::SessionMetadataChanged(
                        v1::SessionMetadataChanged {
                            summary: Some(summary),
                        },
                    )),
                };
                let cursor = log.append(&event, Durability::Sync)?;
                state.apply(&event, cursor);
                let spec = v1::SessionSpec {
                    session_id: session_id.clone(),
                    workspace_id: workspace_id.clone(),
                    worktree_id: state.summary().worktree_id.clone(),
                    session_name: state.summary().session_name.clone(),
                    provider_id: state.summary().provider_id.clone(),
                    agent_id: state.summary().agent_id.clone(),
                    agent_display_name: state.summary().agent_display_name.clone(),
                    model_id: state.summary().model_id.clone(),
                    reasoning_effort: state.summary().reasoning_effort.clone(),
                    parent_session_id: state.summary().parent_session_id.clone(),
                    resume_provider_session_id: state.summary().provider_session_id.clone(),
                    ..v1::SessionSpec::default()
                };
                self.sessions.insert(
                    session_id,
                    SessionSlot {
                        workspace_id: workspace_id.clone(),
                        log,
                        executor: wrap_executor(make_session_executor(&spec)),
                        generation,
                        leave_unsettled: false,
                        state,
                    },
                );
            }
        }
        Ok(())
    }

    fn has_live_sessions(&self) -> bool {
        self.sessions.values().any(|session| {
            session.state.has_live_run()
                || session.state.summary().status == SessionStatus::Running as i32
        })
    }

    fn touch(&mut self) {
        self.last_activity = Instant::now();
    }
}

fn serve_client(
    inner: Arc<Mutex<HostInner>>,
    mut stream: UnixStream,
    host_started_at: String,
    shutdown: Arc<AtomicBool>,
) -> Result<(), HostError> {
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_millis(200)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let first = loop {
        if shutdown.load(Ordering::SeqCst) {
            return Ok(());
        }
        match read_client_frame(&mut stream) {
            Ok(message) => break message,
            Err(HostError::Io(error))
                if error.kind() == std::io::ErrorKind::TimedOut
                    || error.kind() == std::io::ErrorKind::WouldBlock =>
            {
                continue;
            }
            Err(error) => return Err(error),
        }
    };
    let Some(v1::client_message::Body::Hello(hello)) = first.body else {
        write_reject(
            &mut stream,
            HandshakeRejectReason::MalformedHello,
            "first frame must be Hello",
            &inner,
        )?;
        return Ok(());
    };
    let welcome = {
        let guard = inner
            .lock()
            .map_err(|_| HostError::Protocol("poisoned".into()))?;
        handshake(&guard, &stream, &hello, &host_started_at)
    };
    match welcome {
        Ok(welcome) => {
            write_host_frame(
                &mut stream,
                &HostMessage {
                    body: Some(v1::host_message::Body::Welcome(welcome.clone())),
                },
            )?;
            let client_id = welcome.client_id;
            client_loop(inner, stream, client_id, shutdown)
        }
        Err(rejected) => {
            write_host_frame(
                &mut stream,
                &HostMessage {
                    body: Some(v1::host_message::Body::HandshakeRejected(rejected)),
                },
            )?;
            Ok(())
        }
    }
}

fn handshake(
    inner: &HostInner,
    stream: &UnixStream,
    hello: &v1::Hello,
    host_started_at: &str,
) -> Result<v1::Welcome, v1::HandshakeRejected> {
    let reject = |reason: HandshakeRejectReason, detail: String| v1::HandshakeRejected {
        reason: reason as i32,
        detail,
        host_protocol_version: PROTOCOL_VERSION,
        host_build_fingerprint: inner.config.build_fingerprint.clone(),
    };
    if hello.protocol_version != PROTOCOL_VERSION {
        return Err(reject(
            HandshakeRejectReason::ProtocolVersionMismatch,
            format!(
                "protocol {} is not {PROTOCOL_VERSION}",
                hello.protocol_version
            ),
        ));
    }
    if hello.build_fingerprint != inner.config.build_fingerprint {
        return Err(reject(
            HandshakeRejectReason::BuildFingerprintMismatch,
            "buildFingerprint mismatch".to_string(),
        ));
    }
    if !hello
        .capabilities
        .iter()
        .any(|capability| *capability == Capability::SnapshotStreaming as i32)
    {
        return Err(reject(
            HandshakeRejectReason::MissingCapability,
            "snapshotStreaming is required".to_string(),
        ));
    }
    match verify_peer(
        stream,
        hello,
        inner.config.accept_any_peer,
        &inner.config.bundle_identifier,
    ) {
        PeerVerdict::Accepted => {}
        PeerVerdict::Rejected(detail) => {
            return Err(reject(
                HandshakeRejectReason::ExecutableIdentityMismatch,
                detail,
            ));
        }
    }
    if inner.shutting_down {
        return Err(reject(
            HandshakeRejectReason::HostShuttingDown,
            "host is shutting down".to_string(),
        ));
    }
    Ok(v1::Welcome {
        protocol_version: PROTOCOL_VERSION,
        build_fingerprint: inner.config.build_fingerprint.clone(),
        executable: Some(current_identity(&inner.config.bundle_identifier)),
        capabilities: vec![
            Capability::SnapshotStreaming as i32,
            Capability::PrepareUpdate as i32,
        ],
        host_instance_id: inner.host_instance_id.clone(),
        client_id: hello.client_id.clone(),
        maximum_frame_bytes: MAXIMUM_FRAME_PAYLOAD_BYTES as u32,
        maximum_snapshot_chunk_bytes: MAXIMUM_SNAPSHOT_CHUNK_BYTES as u32,
        host_started_at: host_started_at.to_string(),
    })
}

fn write_reject(
    stream: &mut UnixStream,
    reason: HandshakeRejectReason,
    detail: &str,
    inner: &Arc<Mutex<HostInner>>,
) -> Result<(), HostError> {
    let fingerprint = inner
        .lock()
        .map(|guard| guard.config.build_fingerprint.clone())
        .unwrap_or_default();
    write_host_frame(
        stream,
        &HostMessage {
            body: Some(v1::host_message::Body::HandshakeRejected(
                v1::HandshakeRejected {
                    reason: reason as i32,
                    detail: detail.to_string(),
                    host_protocol_version: PROTOCOL_VERSION,
                    host_build_fingerprint: fingerprint,
                },
            )),
        },
    )
}

fn client_loop(
    inner: Arc<Mutex<HostInner>>,
    mut stream: UnixStream,
    client_id: String,
    shutdown: Arc<AtomicBool>,
) -> Result<(), HostError> {
    loop {
        if shutdown.load(Ordering::SeqCst) {
            break;
        }
        match read_client_frame(&mut stream) {
            Ok(message) => {
                let Some(v1::client_message::Body::Command(request)) = message.body else {
                    continue;
                };
                let outgoing = dispatch_command(&inner, &client_id, request)?;
                for message in outgoing {
                    write_host_frame(&mut stream, &message)?;
                }
            }
            Err(HostError::Io(error))
                if error.kind() == std::io::ErrorKind::TimedOut
                    || error.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(HostError::Io(error))
                if error.kind() == std::io::ErrorKind::UnexpectedEof
                    || error.kind() == std::io::ErrorKind::ConnectionReset =>
            {
                break;
            }
            Err(error) => return Err(error),
        }
        let queued = {
            let mut guard = inner
                .lock()
                .map_err(|_| HostError::Protocol("poisoned".into()))?;
            drain_client(&mut guard, &client_id)
        };
        for message in queued {
            write_host_frame(&mut stream, &message)?;
        }
    }
    if let Ok(mut guard) = inner.lock() {
        detach_client(&mut guard, &client_id);
    }
    Ok(())
}

fn drain_client(inner: &mut HostInner, client_id: &str) -> Vec<HostMessage> {
    let mut messages = Vec::new();
    for ((owner, _), attachment) in inner.attachments.iter_mut() {
        if owner == client_id {
            messages.extend(attachment.outbound.drain(..));
            attachment.queued_bytes = 0;
        }
    }
    messages
}

fn detach_client(inner: &mut HostInner, client_id: &str) {
    inner.attachments.retain(|(owner, _), _| owner != client_id);
    refresh_attached_counts(inner);
}

fn dispatch_command(
    inner: &Arc<Mutex<HostInner>>,
    client_id: &str,
    request: CommandRequest,
) -> Result<Vec<HostMessage>, HostError> {
    let prep = {
        let mut guard = inner
            .lock()
            .map_err(|_| HostError::Protocol("poisoned".into()))?;
        dispatch(&mut guard, client_id, request)?
    };
    match prep {
        DispatchPrep::Ready(messages) => Ok(messages),
        DispatchPrep::Run(work) => {
            let ExecutorWork {
                session_id,
                request_id,
                operation_id,
                command_kind,
                now,
                executor,
                op,
            } = work;
            let outcome = match executor.lock() {
                Ok(mut executor) => op.run(&mut **executor, &now),
                Err(_) => Err("poisoned executor".to_string()),
            };
            let mut guard = inner
                .lock()
                .map_err(|_| HostError::Protocol("poisoned".into()))?;
            finish_executor(
                &mut guard,
                &session_id,
                &request_id,
                &operation_id,
                &command_kind,
                &now,
                outcome,
            )
        }
    }
}

fn dispatch(
    inner: &mut HostInner,
    client_id: &str,
    request: CommandRequest,
) -> Result<DispatchPrep, HostError> {
    inner.touch();
    if inner.shutting_down
        && !matches!(
            request.command,
            Some(v1::command_request::Command::HostControl(_))
                | Some(v1::command_request::Command::ListSessions(_))
                | Some(v1::command_request::Command::Detach(_))
        )
    {
        return Ok(DispatchPrep::Ready(vec![response(
            &request.request_id,
            outcome_rejected(
                CommandRejectionReason::HostShuttingDown,
                "host shutting down",
            ),
        )]));
    }
    let Some(command) = request.command.clone() else {
        return Ok(DispatchPrep::Ready(vec![response(
            &request.request_id,
            outcome_rejected(CommandRejectionReason::InvalidArgument, "empty command"),
        )]));
    };
    match command {
        v1::command_request::Command::ListSessions(list) => {
            Ok(DispatchPrep::Ready(vec![response(
                &request.request_id,
                list_sessions(inner, &list),
            )]))
        }
        v1::command_request::Command::Attach(attach) => {
            attach_session(inner, client_id, &request, attach).map(DispatchPrep::Ready)
        }
        v1::command_request::Command::Detach(detach) => {
            inner
                .attachments
                .remove(&(client_id.to_string(), detach.session_id.clone()));
            refresh_attached_counts(inner);
            Ok(DispatchPrep::Ready(vec![response(
                &request.request_id,
                v1::command_response::Outcome::Result(v1::CommandResult {
                    result: Some(v1::command_result::Result::Detached(v1::Detached {
                        session_id: detach.session_id,
                    })),
                }),
            )]))
        }
        v1::command_request::Command::Start(_)
        | v1::command_request::Command::Steer(_)
        | v1::command_request::Command::Interrupt(_)
        | v1::command_request::Command::RespondInteraction(_)
        | v1::command_request::Command::Stop(_)
        | v1::command_request::Command::HostControl(_) => mutate(inner, client_id, request),
    }
}

fn list_sessions(inner: &HostInner, list: &v1::ListSessions) -> v1::command_response::Outcome {
    let sessions = inner
        .sessions
        .values()
        .filter(|session| {
            (list.workspace_id.is_empty() || session.workspace_id == list.workspace_id)
                && (list.include_terminal || !session.state.is_terminal())
        })
        .map(|session| {
            let mut summary = session.state.summary().clone();
            summary.generation = session.generation.clone();
            summary.last_cursor = session.state.last_cursor();
            summary
        })
        .collect();
    v1::command_response::Outcome::Result(v1::CommandResult {
        result: Some(v1::command_result::Result::SessionList(v1::SessionList {
            sessions,
        })),
    })
}

fn attach_session(
    inner: &mut HostInner,
    client_id: &str,
    request: &CommandRequest,
    attach: v1::Attach,
) -> Result<Vec<HostMessage>, HostError> {
    let Some(session) = inner.sessions.get(&attach.session_id) else {
        return Ok(vec![response(
            &request.request_id,
            outcome_rejected(CommandRejectionReason::UnknownSession, "unknown session"),
        )]);
    };
    let generation = session.generation.clone();
    let last = session.state.last_cursor();
    let snapshot = session.state.snapshot(generation.clone(), rfc3339_now());
    let snapshot_cursor = snapshot.through_cursor;
    let generation_mismatch =
        !attach.resume_generation.is_empty() && attach.resume_generation != generation;
    let unknown_cursor = attach
        .resume_cursor
        .is_some_and(|cursor| cursor == 0 || cursor > last);
    let (replay, snapshot_follows, snapshot_through, next_cursor) =
        if generation_mismatch || unknown_cursor {
            (
                AttachReplay::Unavailable,
                true,
                snapshot_cursor,
                snapshot_cursor.saturating_add(1),
            )
        } else if attach.resume_cursor.is_none() {
            // First attach (no resume): same as the Swift host — stream a snapshot
            // (design §5.4 AttachResult { snapshot(chunked) }).
            (
                AttachReplay::Complete,
                true,
                snapshot_cursor,
                snapshot_cursor.saturating_add(1),
            )
        } else if attach
            .resume_cursor
            .is_some_and(|cursor| cursor < snapshot_cursor)
        {
            (
                AttachReplay::Partial,
                true,
                snapshot_cursor,
                snapshot_cursor.saturating_add(1),
            )
        } else {
            let next = attach.resume_cursor.unwrap_or(0).saturating_add(1).max(1);
            (AttachReplay::Complete, false, 0, next.min(last + 1))
        };
    let mut summary = session.state.summary().clone();
    summary.generation = generation.clone();
    let result = v1::AttachResult {
        session_id: attach.session_id.clone(),
        generation: generation.clone(),
        replay: replay as i32,
        snapshot_follows,
        snapshot_through_cursor: snapshot_through,
        next_cursor,
        summary: Some(summary),
    };
    let mut outgoing = vec![response(
        &request.request_id,
        v1::command_response::Outcome::Result(v1::CommandResult {
            result: Some(v1::command_result::Result::Attached(result)),
        }),
    )];
    if snapshot_follows {
        outgoing.extend(snapshot_messages(
            &attach.session_id,
            &generation,
            &snapshot,
        )?);
    }
    let replay = if next_cursor > 0 && next_cursor <= last {
        session
            .log
            .read_from(next_cursor, usize::MAX, usize::MAX)?
            .entries
    } else {
        Vec::new()
    };
    for entry in replay {
        outgoing.push(HostMessage {
            body: Some(v1::host_message::Body::Event(v1::EventNotification {
                session_id: attach.session_id.clone(),
                generation: generation.clone(),
                delivery_cursor: entry.cursor,
                event: Some(entry.event),
            })),
        });
    }
    inner.attachments.insert(
        (client_id.to_string(), attach.session_id.clone()),
        Attachment {
            generation,
            outbound: VecDeque::new(),
            queued_bytes: 0,
            resnapshot_required: false,
        },
    );
    refresh_attached_counts(inner);
    Ok(outgoing)
}

fn mutate(
    inner: &mut HostInner,
    client_id: &str,
    request: CommandRequest,
) -> Result<DispatchPrep, HostError> {
    let request_id = request.request_id.clone();
    if let Some(v1::command_request::Command::HostControl(control)) = request.command.as_ref() {
        return host_control(inner, &request_id, control).map(DispatchPrep::Ready);
    }
    let Some(key) = mutation_key(&request) else {
        return Ok(DispatchPrep::Ready(vec![response(
            &request_id,
            outcome_rejected(
                CommandRejectionReason::InvalidArgument,
                "mutation key required",
            ),
        )]));
    };
    let operation_id = key.operation_id.clone();
    let fingerprint = command_fingerprint(&request);
    let session_id = session_id_of(&request);
    if let Some(session_id) = session_id.as_ref() {
        if let Some(session) = inner.sessions.get(session_id) {
            let recorded = settled_fingerprint(session, &operation_id);
            if let Some(recorded) = recorded.as_deref() {
                if recorded != fingerprint {
                    return Ok(DispatchPrep::Ready(vec![response(
                        &request_id,
                        v1::command_response::Outcome::OperationConflict(v1::OperationConflict {
                            operation_id,
                            recorded_fingerprint: recorded.to_string(),
                            submitted_fingerprint: fingerprint,
                        }),
                    )]));
                }
                if let Some(settled) = session.state.settled_operations().get(&operation_id) {
                    return Ok(DispatchPrep::Ready(vec![response(
                        &request_id,
                        settlement_outcome(settled),
                    )]));
                }
                return Ok(DispatchPrep::Ready(vec![response(
                    &request_id,
                    v1::command_response::Outcome::Uncertain(v1::OperationUncertain {
                        operation_id,
                        detail: "CommandAccepted without CommandSettled".to_string(),
                    }),
                )]));
            }
        } else if !matches!(
            request.command,
            Some(v1::command_request::Command::Start(_))
        ) {
            return Ok(DispatchPrep::Ready(vec![response(
                &request_id,
                outcome_rejected(CommandRejectionReason::UnknownSession, "unknown session"),
            )]));
        }
    }
    let now = rfc3339_now();
    match request.command.as_ref() {
        Some(v1::command_request::Command::Start(start)) => start_session(
            inner,
            client_id,
            &request_id,
            start,
            &operation_id,
            &fingerprint,
            &now,
        ),
        Some(v1::command_request::Command::Steer(steer)) => {
            let Some(message) = steer.message.clone() else {
                return Ok(DispatchPrep::Ready(vec![response(
                    &request_id,
                    outcome_rejected(
                        CommandRejectionReason::InvalidArgument,
                        "steer requires a message",
                    ),
                )]));
            };
            accept_existing(
                inner,
                &request_id,
                &steer.session_id,
                "steer",
                &operation_id,
                &fingerprint,
                &now,
                ExecutorOp::Steer(message),
            )
        }
        Some(v1::command_request::Command::Interrupt(interrupt)) => accept_existing(
            inner,
            &request_id,
            &interrupt.session_id,
            "interrupt",
            &operation_id,
            &fingerprint,
            &now,
            ExecutorOp::Interrupt {
                turn_id: interrupt.turn_id.clone(),
            },
        ),
        Some(v1::command_request::Command::RespondInteraction(respond)) => accept_existing(
            inner,
            &request_id,
            &respond.session_id,
            "respond",
            &operation_id,
            &fingerprint,
            &now,
            ExecutorOp::Respond {
                interaction_id: respond.interaction_id.clone(),
                generation: respond.interaction_generation.clone(),
                answer: respond.answer.clone(),
            },
        ),
        Some(v1::command_request::Command::Stop(stop)) => {
            let reason = StopReason::try_from(stop.reason).unwrap_or(StopReason::Unspecified);
            accept_existing(
                inner,
                &request_id,
                &stop.session_id,
                "stop",
                &operation_id,
                &fingerprint,
                &now,
                ExecutorOp::Stop(reason),
            )
        }
        _ => Ok(DispatchPrep::Ready(vec![response(
            &request_id,
            outcome_rejected(CommandRejectionReason::InvalidArgument, "unsupported"),
        )])),
    }
}

fn start_session(
    inner: &mut HostInner,
    _client_id: &str,
    request_id: &str,
    start: &v1::Start,
    operation_id: &str,
    fingerprint: &str,
    now: &str,
) -> Result<DispatchPrep, HostError> {
    let Some(spec) = start.spec.as_ref() else {
        return Ok(DispatchPrep::Ready(vec![response(
            request_id,
            outcome_rejected(
                CommandRejectionReason::InvalidArgument,
                "start requires spec",
            ),
        )]));
    };
    if inner.sessions.contains_key(&spec.session_id) {
        return Ok(DispatchPrep::Ready(vec![response(
            request_id,
            outcome_rejected(CommandRejectionReason::SessionExists, "session exists"),
        )]));
    }
    let session_id = SessionId::parse(&spec.session_id)?;
    let directory = inner.config.paths.session_directory(&spec.workspace_id)?;
    ensure_directory(&directory, 0o700)?;
    let path = directory.join(events_file_name(session_id));
    let (log, _) = SessionLog::open(&path, session_id, OpenOptions::default())?;
    let generation = mint_generation(&inner.host_nonce, 1);
    let leave_unsettled = spec.session_name == "leave-unsettled";
    inner.sessions.insert(
        spec.session_id.clone(),
        SessionSlot {
            workspace_id: spec.workspace_id.clone(),
            log,
            state: SessionState::placeholder(spec.session_id.clone()),
            executor: wrap_executor(make_session_executor(spec)),
            generation: generation.clone(),
            leave_unsettled,
        },
    );
    accept_existing(
        inner,
        request_id,
        &spec.session_id,
        "start",
        operation_id,
        fingerprint,
        now,
        ExecutorOp::Start(spec.clone()),
    )
}

fn accept_existing(
    inner: &mut HostInner,
    request_id: &str,
    session_id: &str,
    command_kind: &str,
    operation_id: &str,
    fingerprint: &str,
    now: &str,
    op: ExecutorOp,
) -> Result<DispatchPrep, HostError> {
    if !inner.sessions.contains_key(session_id) {
        return Ok(DispatchPrep::Ready(vec![response(
            request_id,
            outcome_rejected(CommandRejectionReason::UnknownSession, "unknown session"),
        )]));
    }
    let accepted = v1::AgentSessionEvent {
        recorded_at: now.to_string(),
        body: Some(v1::agent_session_event::Body::CommandAccepted(
            v1::CommandAccepted {
                operation_id: operation_id.to_string(),
                argument_fingerprint: fingerprint.to_string(),
                command_kind: command_kind.to_string(),
                accepted_at: now.to_string(),
            },
        )),
    };
    let (executor, cursor) = {
        let session = inner.sessions.get_mut(session_id).expect("session");
        let executor = Arc::clone(&session.executor);
        let cursor = session.log.append(&accepted, Durability::Sync)?;
        session.state.apply(&accepted, cursor);
        (executor, cursor)
    };
    fanout(inner, session_id, cursor, &accepted);
    Ok(DispatchPrep::Run(ExecutorWork {
        session_id: session_id.to_string(),
        request_id: request_id.to_string(),
        operation_id: operation_id.to_string(),
        command_kind: command_kind.to_string(),
        now: now.to_string(),
        executor,
        op,
    }))
}

fn finish_executor(
    inner: &mut HostInner,
    session_id: &str,
    request_id: &str,
    operation_id: &str,
    command_kind: &str,
    now: &str,
    outcome: Result<crate::executor::ExecutorOutcome, String>,
) -> Result<Vec<HostMessage>, HostError> {
    if !inner.sessions.contains_key(session_id) {
        return Ok(vec![response(
            request_id,
            outcome_rejected(CommandRejectionReason::UnknownSession, "unknown session"),
        )]);
    }
    let outcome = match outcome {
        Ok(outcome) => outcome,
        Err(detail) => {
            return finish_rejected(
                inner,
                request_id,
                session_id,
                operation_id,
                CommandRejectionReason::InvalidArgument,
                &detail,
                now,
            );
        }
    };
    let mut last_cursor = inner
        .sessions
        .get(session_id)
        .map(|session| session.state.last_cursor())
        .unwrap_or(0);
    for event in &outcome.events {
        let event_cursor = {
            let session = inner.sessions.get_mut(session_id).expect("session");
            let event_cursor = session.log.append(event, Durability::Deferred)?;
            session.state.apply(event, event_cursor);
            event_cursor
        };
        last_cursor = event_cursor;
        fanout(inner, session_id, event_cursor, event);
    }
    let command_result = command_result_for(command_kind, session_id, inner, &outcome, last_cursor);
    let leave_unsettled = inner
        .sessions
        .get(session_id)
        .is_some_and(|session| session.leave_unsettled);
    if !leave_unsettled {
        let settled = v1::AgentSessionEvent {
            recorded_at: now.to_string(),
            body: Some(v1::agent_session_event::Body::CommandSettled(
                v1::CommandSettled {
                    operation_id: operation_id.to_string(),
                    settled_at: now.to_string(),
                    settlement: Some(v1::command_settled::Settlement::Result(
                        command_result.clone(),
                    )),
                },
            )),
        };
        let settled_cursor = {
            let session = inner.sessions.get_mut(session_id).expect("session");
            let settled_cursor = session.log.append(&settled, Durability::Sync)?;
            session.state.apply(&settled, settled_cursor);
            settled_cursor
        };
        fanout(inner, session_id, settled_cursor, &settled);
        let _ = compact_session(inner, session_id);
    }
    Ok(vec![response(
        request_id,
        v1::command_response::Outcome::Result(command_result),
    )])
}

fn finish_rejected(
    inner: &mut HostInner,
    request_id: &str,
    session_id: &str,
    operation_id: &str,
    reason: CommandRejectionReason,
    detail: &str,
    now: &str,
) -> Result<Vec<HostMessage>, HostError> {
    let rejected = v1::CommandRejected {
        reason: reason as i32,
        detail: detail.to_string(),
    };
    let settled = v1::AgentSessionEvent {
        recorded_at: now.to_string(),
        body: Some(v1::agent_session_event::Body::CommandSettled(
            v1::CommandSettled {
                operation_id: operation_id.to_string(),
                settled_at: now.to_string(),
                settlement: Some(v1::command_settled::Settlement::Rejected(rejected.clone())),
            },
        )),
    };
    if inner.sessions.contains_key(session_id) {
        let cursor = {
            let session = inner.sessions.get_mut(session_id).expect("session");
            let cursor = session.log.append(&settled, Durability::Sync)?;
            session.state.apply(&settled, cursor);
            cursor
        };
        fanout(inner, session_id, cursor, &settled);
    }
    Ok(vec![response(
        request_id,
        v1::command_response::Outcome::Rejected(rejected),
    )])
}

fn host_control(
    inner: &mut HostInner,
    request_id: &str,
    control: &v1::HostControl,
) -> Result<Vec<HostMessage>, HostError> {
    match control.action {
        Some(v1::host_control::Action::PrepareUpdate(_)) => {
            let mut checkpoints = Vec::new();
            let mut all_ok = !inner.config.fail_prepare_update;
            let session_ids: Vec<String> = inner.sessions.keys().cloned().collect();
            for session_id in session_ids {
                let ok = !inner.config.fail_prepare_update
                    && inner
                        .sessions
                        .get(&session_id)
                        .is_some_and(session_checkpoint_ok)
                    && compact_session(inner, &session_id).is_ok();
                all_ok &= ok;
                let through = inner
                    .sessions
                    .get(&session_id)
                    .map(|session| session.state.last_cursor())
                    .unwrap_or(0);
                checkpoints.push(v1::SessionCheckpoint {
                    session_id,
                    succeeded: ok,
                    through_cursor: through,
                    detail: if ok {
                        String::new()
                    } else {
                        "checkpoint failed".to_string()
                    },
                });
            }
            Ok(vec![response(
                request_id,
                v1::command_response::Outcome::Result(v1::CommandResult {
                    result: Some(v1::command_result::Result::HostControl(
                        v1::HostControlResult {
                            result: Some(v1::host_control_result::Result::PrepareUpdate(
                                v1::PrepareUpdateResult {
                                    all_checkpointed: all_ok,
                                    checkpoints,
                                },
                            )),
                        },
                    )),
                }),
            )])
        }
        Some(v1::host_control::Action::Shutdown(_)) => {
            inner.shutting_down = true;
            Ok(vec![response(
                request_id,
                v1::command_response::Outcome::Result(v1::CommandResult {
                    result: Some(v1::command_result::Result::HostControl(
                        v1::HostControlResult {
                            result: Some(v1::host_control_result::Result::Shutdown(
                                v1::ShutdownAccepted {
                                    deadline_at: rfc3339_now(),
                                },
                            )),
                        },
                    )),
                }),
            )])
        }
        None => Ok(vec![response(
            request_id,
            outcome_rejected(
                CommandRejectionReason::InvalidArgument,
                "empty host control",
            ),
        )]),
    }
}

fn compact_session(inner: &mut HostInner, session_id: &str) -> Result<(), HostError> {
    let Some(session) = inner.sessions.get_mut(session_id) else {
        return Ok(());
    };
    if !session_checkpoint_ok(session) {
        return Err(HostError::Protocol("checkpoint refused".to_string()));
    }
    session.log.sync()?;
    let snapshot = session
        .state
        .snapshot(session.generation.clone(), rfc3339_now());
    session.log.compact(&snapshot)?;
    Ok(())
}

fn fanout(inner: &mut HostInner, session_id: &str, cursor: u64, event: &v1::AgentSessionEvent) {
    let generation = inner
        .sessions
        .get(session_id)
        .map(|session| session.generation.clone())
        .unwrap_or_default();
    let max_events = inner.config.max_queued_events;
    let max_bytes = inner.config.max_queued_bytes;
    let notification = HostMessage {
        body: Some(v1::host_message::Body::Event(v1::EventNotification {
            session_id: session_id.to_string(),
            generation: generation.clone(),
            delivery_cursor: cursor,
            event: Some(event.clone()),
        })),
    };
    let size = encode_host_len(&notification);
    let keys: Vec<(String, String)> = inner
        .attachments
        .keys()
        .filter(|(_, attached)| attached == session_id)
        .cloned()
        .collect();
    for key in keys {
        if let Some(attachment) = inner.attachments.get_mut(&key) {
            if attachment.resnapshot_required {
                continue;
            }
            if attachment.outbound.len() >= max_events
                || attachment.queued_bytes.saturating_add(size) > max_bytes
            {
                attachment.outbound.clear();
                attachment.queued_bytes = 0;
                attachment.resnapshot_required = true;
                attachment.outbound.push_back(HostMessage {
                    body: Some(v1::host_message::Body::ResnapshotRequired(
                        v1::ResnapshotRequired {
                            session_id: session_id.to_string(),
                            generation: generation.clone(),
                            reason: v1::ResnapshotReason::BackpressureOverflow as i32,
                            last_delivered_cursor: cursor.saturating_sub(1),
                        },
                    )),
                });
                continue;
            }
            attachment.queued_bytes += size;
            attachment.outbound.push_back(notification.clone());
        }
    }
}

fn encode_host_len(message: &HostMessage) -> usize {
    agentry_proto::agent_host::encode_host_message(message)
        .map(|frame| frame.len())
        .unwrap_or(0)
}

fn snapshot_messages(
    session_id: &str,
    generation: &[u8],
    snapshot: &v1::AgentSessionSnapshot,
) -> Result<Vec<HostMessage>, HostError> {
    let bytes = encode_snapshot(snapshot)?;
    let chunks: Vec<&[u8]> = bytes.chunks(MAXIMUM_SNAPSHOT_CHUNK_BYTES).collect();
    let mut messages = vec![HostMessage {
        body: Some(v1::host_message::Body::SnapshotBegin(v1::SnapshotBegin {
            session_id: session_id.to_string(),
            generation: generation.to_vec(),
            through_cursor: snapshot.through_cursor,
            byte_length: bytes.len() as u64,
            digest_sha256: hex_digest(&bytes),
            chunk_count: chunks.len() as u32,
        })),
    }];
    for (index, chunk) in chunks.iter().enumerate() {
        messages.push(HostMessage {
            body: Some(v1::host_message::Body::SnapshotChunk(v1::SnapshotChunk {
                session_id: session_id.to_string(),
                chunk_index: index as u32,
                offset: (index * MAXIMUM_SNAPSHOT_CHUNK_BYTES) as u64,
                data: chunk.to_vec(),
            })),
        });
    }
    messages.push(HostMessage {
        body: Some(v1::host_message::Body::SnapshotEnd(v1::SnapshotEnd {
            session_id: session_id.to_string(),
            through_cursor: snapshot.through_cursor,
            next_cursor: snapshot.through_cursor.saturating_add(1),
        })),
    });
    Ok(messages)
}

fn command_result_for(
    kind: &str,
    session_id: &str,
    inner: &HostInner,
    outcome: &crate::executor::ExecutorOutcome,
    last_cursor: u64,
) -> v1::CommandResult {
    let session = inner.sessions.get(session_id);
    let generation = session
        .map(|session| session.generation.clone())
        .unwrap_or_default();
    let summary = session.map(|session| session.state.summary().clone());
    let result = match kind {
        "start" => v1::command_result::Result::Started(v1::SessionStarted {
            session_id: session_id.to_string(),
            generation,
            next_cursor: last_cursor.saturating_add(1),
            summary,
        }),
        "steer" => v1::command_result::Result::Steered(v1::Steered {
            session_id: session_id.to_string(),
            message_id: outcome
                .events
                .iter()
                .find_map(|event| match event.body.as_ref() {
                    Some(v1::agent_session_event::Body::UserMessage(message)) => {
                        Some(message.message_id.clone())
                    }
                    _ => None,
                })
                .unwrap_or_default(),
            recorded_cursor: last_cursor,
        }),
        "interrupt" => v1::command_result::Result::Interrupted(v1::InterruptResult {
            session_id: session_id.to_string(),
            outcome: outcome.interrupt_outcome as i32,
            detail: String::new(),
        }),
        "respond" => v1::command_result::Result::InteractionResponded(v1::InteractionResponded {
            session_id: session_id.to_string(),
            interaction_id: outcome.interaction_id.clone(),
            disposition: outcome.respond_disposition as i32,
        }),
        "stop" => v1::command_result::Result::Stopped(v1::Stopped {
            session_id: session_id.to_string(),
            status: SessionStatus::Cancelled as i32,
        }),
        _ => v1::command_result::Result::Interrupted(v1::InterruptResult {
            session_id: session_id.to_string(),
            outcome: InterruptOutcome::Failed as i32,
            detail: kind.to_string(),
        }),
    };
    v1::CommandResult {
        result: Some(result),
    }
}

fn settlement_outcome(settled: &v1::CommandSettled) -> v1::command_response::Outcome {
    match settled.settlement.as_ref() {
        Some(v1::command_settled::Settlement::Result(result)) => {
            v1::command_response::Outcome::Result(result.clone())
        }
        Some(v1::command_settled::Settlement::Rejected(rejected)) => {
            v1::command_response::Outcome::Rejected(rejected.clone())
        }
        None => v1::command_response::Outcome::Uncertain(v1::OperationUncertain {
            operation_id: settled.operation_id.clone(),
            detail: "empty settlement".to_string(),
        }),
    }
}

fn settled_fingerprint(session: &SessionSlot, operation_id: &str) -> Option<String> {
    session
        .state
        .accepted_operations()
        .get(operation_id)
        .map(|accepted| accepted.argument_fingerprint.clone())
}

fn session_id_of(request: &CommandRequest) -> Option<String> {
    match request.command.as_ref()? {
        v1::command_request::Command::Start(start) => {
            start.spec.as_ref().map(|spec| spec.session_id.clone())
        }
        v1::command_request::Command::Steer(steer) => Some(steer.session_id.clone()),
        v1::command_request::Command::Interrupt(interrupt) => Some(interrupt.session_id.clone()),
        v1::command_request::Command::RespondInteraction(respond) => {
            Some(respond.session_id.clone())
        }
        v1::command_request::Command::Stop(stop) => Some(stop.session_id.clone()),
        _ => None,
    }
}

fn refresh_attached_counts(inner: &mut HostInner) {
    let mut counts: BTreeMap<String, u32> = BTreeMap::new();
    for ((_, session_id), _) in &inner.attachments {
        *counts.entry(session_id.clone()).or_insert(0) += 1;
    }
    for (session_id, session) in &mut inner.sessions {
        session
            .state
            .set_attached_client_count(*counts.get(session_id).unwrap_or(&0));
    }
}

fn response(request_id: &str, outcome: v1::command_response::Outcome) -> HostMessage {
    HostMessage {
        body: Some(v1::host_message::Body::Response(CommandResponse {
            request_id: request_id.to_string(),
            outcome: Some(outcome),
        })),
    }
}

fn outcome_rejected(reason: CommandRejectionReason, detail: &str) -> v1::command_response::Outcome {
    v1::command_response::Outcome::Rejected(v1::CommandRejected {
        reason: reason as i32,
        detail: detail.to_string(),
    })
}

fn parse_events_file_name(name: &str) -> Option<String> {
    let stem = name.strip_suffix(".events")?;
    let id = stem.strip_prefix("AgentSession-")?;
    SessionId::parse(id).ok()?;
    Some(id.to_string())
}

// Keep `HostConfig::from_env` isolated-socket logic honest when the env key is set
// after construction; the constant is the public name.
#[allow(dead_code)]
fn _env_key() -> &'static str {
    APPLICATION_SUPPORT_ROOT_ENV
}
