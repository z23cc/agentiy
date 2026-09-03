//! P7 host: handshake reject, attach replay, backpressure, idempotency,
//! prepare_update refuse, and lease SIGKILL.

use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use agentry_mcp::{
    AgentHostClient, BuildFlavor, HandshakeOutcome, Host, HostConfig, HostHandle, HostLease,
    HostPaths, LeaseAcquisition, LeaseOwner, WorkspaceAuthorityLease, WorkspaceAuthorityObservation,
    WorkspaceClaim,
};
use agentry_proto::agent_host::v1::{
    self, AttachReplay, Capability, ClientKind, CommandRejectionReason, HandshakeRejectReason,
    MutationKey, SessionSpec,
};
use agentry_proto::agent_host::{PROTOCOL_VERSION, command_fingerprint};

fn scratch_root() -> std::path::PathBuf {
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "agentry-mcp-host-{}-{nanos}-{seq}",
        std::process::id()
    ))
}

fn test_config() -> HostConfig {
    let root = scratch_root();
    let paths = HostPaths::from_root(
        root,
        BuildFlavor::Debug,
        PROTOCOL_VERSION,
        true,
        agentry_mcp::peer::current_uid(),
    );
    HostConfig {
        paths,
        build_fingerprint: "test-fingerprint".to_string(),
        accept_any_peer: true,
        idle_exit_seconds: None,
        fail_prepare_update: false,
        max_queued_events: 64,
        max_queued_bytes: 256 * 1024,
        bundle_identifier: String::new(),
        claim_workspace_authority: false,
    }
}

fn start_host(config: HostConfig) -> HostHandle {
    Host::start_background(config).expect("bind host")
}

fn connect(handle: &HostHandle) -> AgentHostClient {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match AgentHostClient::connect(&handle.paths.socket_path) {
            Ok(client) => return client,
            Err(error) if Instant::now() < deadline => {
                let _ = error;
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(error) => panic!("connect: {error}"),
        }
    }
}

fn hello(fingerprint: &str) -> v1::Hello {
    v1::Hello {
        protocol_version: PROTOCOL_VERSION,
        build_fingerprint: fingerprint.to_string(),
        capabilities: vec![Capability::SnapshotStreaming as i32],
        client_id: "test-client".to_string(),
        client_kind: ClientKind::Test as i32,
        executable: None,
    }
}

fn welcome_client(handle: &HostHandle) -> AgentHostClient {
    welcome_client_as(handle, "test-client")
}

fn welcome_client_as(handle: &HostHandle, client_id: &str) -> AgentHostClient {
    let mut client = connect(handle);
    let mut hello = hello(&handle.build_fingerprint);
    hello.client_id = client_id.to_string();
    match client.hello(hello).expect("hello") {
        HandshakeOutcome::Welcome(_) => client,
        HandshakeOutcome::Rejected(rejected) => panic!("unexpected reject: {rejected:?}"),
    }
}

fn key(operation_id: &str) -> MutationKey {
    MutationKey {
        operation_id: operation_id.to_string(),
        argument_fingerprint: String::new(),
    }
}

fn util_uuid_fallback() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock")
        .as_nanos();
    format!(
        "0193a4b2-7c3e-7f10-8a2b-{:012x}",
        nanos % 0x0001_0000_0000_0000
    )
}

fn start_request(session: &str, name: &str, operation: &str) -> v1::CommandRequest {
    let mut request = v1::CommandRequest {
        request_id: format!("req-{operation}"),
        command: Some(v1::command_request::Command::Start(v1::Start {
            key: Some(key(operation)),
            spec: Some(SessionSpec {
                session_id: session.to_string(),
                workspace_id: "ws-1".to_string(),
                session_name: name.to_string(),
                provider_id: "stub".to_string(),
                ..SessionSpec::default()
            }),
        })),
    };
    let fingerprint = command_fingerprint(&request);
    if let Some(v1::command_request::Command::Start(start)) = request.command.as_mut() {
        if let Some(key) = start.key.as_mut() {
            key.argument_fingerprint = fingerprint;
        }
    }
    request
}

fn attach_request(
    session: &str,
    resume_cursor: Option<u64>,
    resume_generation: Vec<u8>,
) -> v1::CommandRequest {
    v1::CommandRequest {
        request_id: "req-attach".to_string(),
        command: Some(v1::command_request::Command::Attach(v1::Attach {
            session_id: session.to_string(),
            resume_cursor,
            resume_generation,
        })),
    }
}

fn steer_request(session: &str, text: &str, operation: &str) -> v1::CommandRequest {
    let mut request = v1::CommandRequest {
        request_id: format!("req-{operation}"),
        command: Some(v1::command_request::Command::Steer(v1::Steer {
            key: Some(key(operation)),
            session_id: session.to_string(),
            message: Some(v1::UserMessage {
                message_id: operation.to_string(),
                text: text.to_string(),
                created_at: "2026-09-03T00:00:00Z".to_string(),
                ..v1::UserMessage::default()
            }),
            delivery: 0,
        })),
    };
    let fingerprint = command_fingerprint(&request);
    if let Some(v1::command_request::Command::Steer(steer)) = request.command.as_mut() {
        if let Some(key) = steer.key.as_mut() {
            key.argument_fingerprint = fingerprint;
        }
    }
    request
}

fn host_control_prepare() -> v1::CommandRequest {
    v1::CommandRequest {
        request_id: "req-prepare".to_string(),
        command: Some(v1::command_request::Command::HostControl(v1::HostControl {
            key: Some(key("prepare")),
            action: Some(v1::host_control::Action::PrepareUpdate(v1::PrepareUpdate {
                deadline_seconds: 5,
            })),
        })),
    }
}

fn attached_replay(trip: &agentry_mcp::CommandRoundtrip) -> AttachReplay {
    match trip
        .response
        .as_ref()
        .and_then(|response| response.outcome.as_ref())
    {
        Some(v1::command_response::Outcome::Result(result)) => match result.result.as_ref() {
            Some(v1::command_result::Result::Attached(attached)) => {
                AttachReplay::try_from(attached.replay).unwrap_or(AttachReplay::Unspecified)
            }
            _ => AttachReplay::Unspecified,
        },
        _ => AttachReplay::Unspecified,
    }
}

#[test]
fn handshake_rejects_version_and_fingerprint() {
    let handle = start_host(test_config());
    let mut client = connect(&handle);
    let mut bad = hello(&handle.build_fingerprint);
    bad.protocol_version = 99;
    match client.hello(bad).expect("hello") {
        HandshakeOutcome::Rejected(rejected) => {
            assert_eq!(
                rejected.reason,
                HandshakeRejectReason::ProtocolVersionMismatch as i32
            );
        }
        HandshakeOutcome::Welcome(_) => panic!("expected version reject"),
    }

    let mut client = connect(&handle);
    match client.hello(hello("wrong-fingerprint")).expect("hello") {
        HandshakeOutcome::Rejected(rejected) => {
            assert_eq!(
                rejected.reason,
                HandshakeRejectReason::BuildFingerprintMismatch as i32
            );
        }
        HandshakeOutcome::Welcome(_) => panic!("expected fingerprint reject"),
    }

    let mut client = connect(&handle);
    let mut missing = hello(&handle.build_fingerprint);
    missing.capabilities.clear();
    match client.hello(missing).expect("hello") {
        HandshakeOutcome::Rejected(rejected) => {
            assert_eq!(
                rejected.reason,
                HandshakeRejectReason::MissingCapability as i32
            );
        }
        HandshakeOutcome::Welcome(_) => panic!("expected capability reject"),
    }
}

#[test]
fn attach_replay_complete_partial_unavailable() {
    let handle = start_host(test_config());
    let mut client = welcome_client(&handle);
    let session = util_uuid_fallback();
    let started = client
        .command(start_request(&session, "demo", "op-start"))
        .expect("start");
    let generation = match started
        .response
        .as_ref()
        .and_then(|response| response.outcome.as_ref())
    {
        Some(v1::command_response::Outcome::Result(result)) => match result.result.as_ref() {
            Some(v1::command_result::Result::Started(started)) => started.generation.clone(),
            other => panic!("expected started, got {other:?}"),
        },
        other => panic!("expected result, got {other:?}"),
    };

    let complete = client
        .command(attach_request(&session, None, generation.clone()))
        .expect("complete attach");
    assert_eq!(attached_replay(&complete), AttachReplay::Complete);
    assert!(
        !complete.snapshots.is_empty(),
        "first attach with no resume cursor must stream a snapshot"
    );

    let partial = client
        .command(attach_request(&session, Some(1), generation.clone()))
        .expect("partial attach");
    assert_eq!(attached_replay(&partial), AttachReplay::Partial);
    assert!(!partial.snapshots.is_empty());

    let unavailable = client
        .command(attach_request(&session, Some(1), vec![0; 24]))
        .expect("unavailable attach");
    assert_eq!(attached_replay(&unavailable), AttachReplay::Unavailable);
    assert!(!unavailable.snapshots.is_empty());
}

#[test]
fn backpressure_sets_resnapshot_required() {
    let mut config = test_config();
    config.max_queued_events = 2;
    config.max_queued_bytes = 64;
    let handle = start_host(config);
    let mut client = welcome_client(&handle);
    let session = util_uuid_fallback();
    client
        .command(start_request(&session, "demo", "op-start"))
        .expect("start");
    client
        .command(attach_request(&session, None, Vec::new()))
        .expect("attach");
    let trip = client
        .command(steer_request(&session, "flood:20", "op-steer"))
        .expect("steer");
    assert!(
        !trip.resnapshots.is_empty()
            || client
                .wait_message(Duration::from_secs(1))
                .ok()
                .flatten()
                .is_some_and(|message| {
                    matches!(
                        message.body,
                        Some(v1::host_message::Body::ResnapshotRequired(_))
                    )
                }),
        "expected resnapshotRequired under a 2-event fanout cap"
    );
}

#[test]
fn idempotency_replay_conflict_and_uncertain() {
    let handle = start_host(test_config());
    let mut client = welcome_client(&handle);
    let session = util_uuid_fallback();
    let first = start_request(&session, "demo", "op-start");
    let again = client.command(first.clone()).expect("start");
    assert!(matches!(
        again
            .response
            .as_ref()
            .and_then(|response| response.outcome.as_ref()),
        Some(v1::command_response::Outcome::Result(_))
    ));
    let replay = client.command(first).expect("replay");
    assert!(matches!(
        replay
            .response
            .as_ref()
            .and_then(|response| response.outcome.as_ref()),
        Some(v1::command_response::Outcome::Result(_))
    ));

    let mut conflict = start_request(&session, "other-name", "op-start");
    if let Some(v1::command_request::Command::Start(start)) = conflict.command.as_mut() {
        if let Some(key) = start.key.as_mut() {
            key.argument_fingerprint = "0".repeat(64);
        }
    }
    // Force a different fingerprint by changing arguments but keeping operation id.
    let conflict = client.command(conflict).expect("conflict");
    let outcome = conflict
        .response
        .as_ref()
        .and_then(|response| response.outcome.as_ref());
    let ok = matches!(
        outcome,
        Some(v1::command_response::Outcome::OperationConflict(_))
    ) || matches!(
        outcome,
        Some(v1::command_response::Outcome::Rejected(rejected))
            if rejected.reason == CommandRejectionReason::SessionExists as i32
    );
    assert!(
        ok,
        "same operation id with different args must conflict or hit session-exists after settle, got {outcome:?}"
    );

    let unsettled_session = util_uuid_fallback();
    let leave = start_request(&unsettled_session, "leave-unsettled", "op-leave");
    client.command(leave.clone()).expect("leave start");
    let uncertain = client.command(leave).expect("uncertain retry");
    assert!(
        matches!(
            uncertain
                .response
                .as_ref()
                .and_then(|response| response.outcome.as_ref()),
            Some(v1::command_response::Outcome::Uncertain(_))
        ),
        "accepted-but-unsettled retry must be uncertain, got {:?}",
        uncertain.response
    );
}

#[test]
fn prepare_update_refuses_when_checkpoint_fails() {
    let mut config = test_config();
    config.fail_prepare_update = true;
    let handle = start_host(config);
    let mut client = welcome_client(&handle);
    let session = util_uuid_fallback();
    client
        .command(start_request(&session, "fail-checkpoint", "op-start"))
        .expect("start");
    let trip = client.command(host_control_prepare()).expect("prepare");
    match trip
        .response
        .as_ref()
        .and_then(|response| response.outcome.as_ref())
    {
        Some(v1::command_response::Outcome::Result(result)) => match result.result.as_ref() {
            Some(v1::command_result::Result::HostControl(control)) => match control.result.as_ref()
            {
                Some(v1::host_control_result::Result::PrepareUpdate(prepared)) => {
                    assert!(!prepared.all_checkpointed);
                }
                other => panic!("expected prepare result, got {other:?}"),
            },
            other => panic!("expected host control, got {other:?}"),
        },
        other => panic!("expected result, got {other:?}"),
    }
    // Host stays up: a second command still works.
    let list = client
        .command(v1::CommandRequest {
            request_id: "req-list".to_string(),
            command: Some(v1::command_request::Command::ListSessions(
                v1::ListSessions {
                    include_terminal: true,
                    workspace_id: String::new(),
                },
            )),
        })
        .expect("list after refused update");
    assert!(list.response.is_some());
}

#[test]
fn lease_survives_sigkill_of_holder() {
    let root = scratch_root();
    let paths = HostPaths::from_root(
        root.clone(),
        BuildFlavor::Debug,
        PROTOCOL_VERSION,
        true,
        agentry_mcp::peer::current_uid(),
    );
    let bin = env!("CARGO_BIN_EXE_agentry-mcp");
    let mut child = Command::new(bin)
        .arg("agent-host")
        .arg("--application-support-root")
        .arg(&root)
        .arg("--build-fingerprint")
        .arg("sigkill-test")
        .arg("--accept-any-peer")
        .arg("--idle-exit-seconds")
        .arg("0")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn agent-host");

    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && !paths.socket_path.exists() {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(paths.socket_path.exists(), "host never created its socket");

    let owner = LeaseOwner::rust(
        "challenger",
        "sigkill-test",
        paths.socket_path.display().to_string(),
    );
    match HostLease::acquire(paths.clone(), owner.clone()) {
        LeaseAcquisition::Contended { .. } => {}
        other => {
            let _ = child.kill();
            panic!("expected contended while child lives, got {other:?}");
        }
    }

    child.kill().expect("SIGKILL");
    let _ = child.wait();

    let deadline = Instant::now() + Duration::from_secs(2);
    let acquired = loop {
        match HostLease::acquire(paths.clone(), owner.clone()) {
            LeaseAcquisition::Acquired(lease) => break lease,
            LeaseAcquisition::Contended { .. } if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(20));
            }
            other => panic!("expected acquire after SIGKILL, got {other:?}"),
        }
    };
    drop(acquired);
}

#[test]
fn start_releases_host_mutex_before_executor_io() {
    let handle = start_host(test_config());
    let mut starter = welcome_client_as(&handle, "starter");
    let mut lister = welcome_client_as(&handle, "lister");
    let session = util_uuid_fallback();
    let start = start_request(&session, "block-io", "op-block");
    let join = std::thread::spawn(move || starter.command(start));
    std::thread::sleep(Duration::from_millis(40));
    let listed_at = Instant::now();
    let listed = lister
        .command(v1::CommandRequest {
            request_id: "req-list".to_string(),
            command: Some(v1::command_request::Command::ListSessions(
                v1::ListSessions {
                    workspace_id: "ws-1".to_string(),
                    include_terminal: true,
                },
            )),
        })
        .expect("list during blocked start");
    let elapsed = listed_at.elapsed();
    assert!(
        elapsed < Duration::from_millis(200),
        "list_sessions waited on executor I/O ({elapsed:?})"
    );
    assert!(
        listed.response.is_some(),
        "list_sessions must complete while start is in executor I/O"
    );
    join.join()
        .expect("start thread")
        .expect("blocked start should settle");
}

#[test]
fn agent_host_cli_usage_exits_two() {
    let bin = env!("CARGO_BIN_EXE_agentry-mcp");
    for args in [
        vec!["agent-host", "--bogus"],
        vec!["agent-host", "--idle-exit-seconds"],
    ] {
        let output = Command::new(bin)
            .args(&args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .expect("run agent-host");
        assert_eq!(output.status.code(), Some(2), "args={args:?}");
    }
}

#[test]
fn host_claims_workspace_lease_when_unused_and_releases_on_shutdown() {
    let mut config = test_config();
    config.claim_workspace_authority = true;
    let paths = config.paths.clone();
    assert!(matches!(
        WorkspaceAuthorityLease::observe(&paths),
        WorkspaceAuthorityObservation::Unused
    ));
    let handle = start_host(config);
    match WorkspaceAuthorityLease::observe(&paths) {
        WorkspaceAuthorityObservation::Held(Some(owner)) => {
            assert!(
                !owner.is_gui_shaped(),
                "host fence-claim must be standalone, got {owner:?}"
            );
        }
        other => panic!("host must hold unused workspace lease, got {other:?}"),
    }
    drop(handle);
    assert!(
        matches!(
            WorkspaceAuthorityLease::observe(&paths),
            WorkspaceAuthorityObservation::Unused
        ),
        "idle-exit/shutdown must drop the workspace flock"
    );
    let _ = std::fs::remove_dir_all(&paths.application_support_root);
}

#[test]
fn host_bind_does_not_steal_gui_workspace_holder() {
    let mut config = test_config();
    config.claim_workspace_authority = true;
    let paths = config.paths.clone();
    let gui = match WorkspaceAuthorityLease::hold_gui_shaped_fixture(&paths) {
        WorkspaceClaim::Acquired(lease) => lease,
        other => panic!("gui fixture must acquire, got {other:?}"),
    };
    assert!(WorkspaceAuthorityLease::observe(&paths).has_live_gui_holder());
    let handle = start_host(config);
    match WorkspaceAuthorityLease::observe(&paths) {
        WorkspaceAuthorityObservation::Held(Some(owner)) => {
            assert!(
                owner.is_gui_shaped(),
                "host must leave the GUI holder in place, got {owner:?}"
            );
        }
        other => panic!("GUI holder must remain, got {other:?}"),
    }
    drop(handle);
    assert!(
        WorkspaceAuthorityLease::observe(&paths).has_live_gui_holder(),
        "host shutdown must not release a GUI flock it does not own"
    );
    drop(gui);
    let _ = std::fs::remove_dir_all(&paths.application_support_root);
}
