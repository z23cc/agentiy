//! Live `ProviderTransport` constructs and fail-closes without a provider binary.

use agentry_mcp::{
    LaunchSpec, LiveFamily, LiveProviderTransport, ProviderTransport, TransportChoice,
    UnattachedTransport, live_transport_for_missing_binary, make_provider_transport,
    make_session_executor, resolve_transport_choice, resolve_transport_choice_from,
};
use agentry_proto::agent_host::v1::{SessionSpec, SessionStatus};

fn spec(provider: &str) -> SessionSpec {
    SessionSpec {
        session_id: "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081".to_string(),
        workspace_id: "ws-1".to_string(),
        session_name: "live-io".to_string(),
        provider_id: provider.to_string(),
        model_id: "test-model".to_string(),
        ..SessionSpec::default()
    }
}

#[test]
fn live_transport_constructs_and_fail_closes_without_binary() {
    let mut transport = live_transport_for_missing_binary()
        .expect("live transport must construct without spawning");
    assert_eq!(transport.command(), "/no/such/agentry-agent-host-provider");

    let start = transport.start();
    assert!(
        start.is_err(),
        "missing binary must fail closed, got {start:?}"
    );
    let start_error = start.expect_err("start");
    assert!(
        start_error.contains("spawn")
            || start_error.contains("posix")
            || start_error.contains("No such")
            || start_error.contains("failed"),
        "{start_error}"
    );

    let request = transport.request("initialize", "{}");
    assert!(
        request.is_err(),
        "request must not echo success after a failed spawn: {request:?}"
    );
}

#[test]
fn live_claude_transport_fail_closes_without_binary() {
    let mut transport = LiveProviderTransport::new(LaunchSpec::missing_binary(LiveFamily::Claude))
        .expect("claude live transport constructs");
    assert!(transport.start().is_err());
    assert!(
        transport
            .request("user_message", r#"{"text":"hi"}"#)
            .is_err()
    );
}

#[test]
fn unattached_transport_still_fail_closes() {
    let mut transport = UnattachedTransport::because("required provider credential is unavailable");
    assert!(transport.start().is_err());
    let error = transport
        .request("turn/start", "{}")
        .expect_err("unattached request");
    assert!(error.contains("unattached"), "{error}");
    assert!(error.contains("credential"), "{error}");
}

#[test]
fn factory_stays_scripted_without_launch_env() {
    let spec = spec("claude");
    assert!(matches!(
        resolve_transport_choice(&spec),
        TransportChoice::Scripted
    ));
    let mut transport = make_provider_transport(&spec);
    assert_eq!(
        transport.request("initialize", "{}").expect("scripted"),
        "{}"
    );
    let mut executor = make_session_executor(&spec);
    let outcome = executor.start(&spec, "2026-09-03T00:00:00Z");
    assert!(
        !outcome.events.iter().any(|event| {
            matches!(
                event.body.as_ref(),
                Some(agentry_proto::agent_host::v1::agent_session_event::Body::SessionMetadataChanged(change))
                    if change.summary.as_ref().is_some_and(|summary| {
                        summary.status == SessionStatus::Failed as i32
                    })
            )
        }),
        "missing launch info must not fail-close a scripted production start"
    );
}

#[test]
fn missing_envelope_fail_closes_instead_of_scripted_echo() {
    let mut spec = spec("claude");
    spec.credential_envelope_id = "missing-envelope-id".to_string();
    let choice = resolve_transport_choice_from(&spec, |_| None, Vec::new());
    match choice {
        TransportChoice::Unattached { reason } => {
            assert!(reason.contains("envelope"), "{reason}");
        }
        other => panic!("expected unattached, got {other:?}"),
    }
    let mut transport = make_provider_transport(&spec);
    assert!(transport.start().is_err());
    assert!(
        transport
            .request("user_message", r#"{"text":"hi"}"#)
            .is_err()
    );
}

#[test]
fn live_flag_missing_required_secret_fail_closes_instead_of_echo() {
    let spec = spec("kimiCode");
    let choice = resolve_transport_choice_from(
        &spec,
        |key| (key == "AGENTRY_AGENT_HOST_LIVE").then(|| "1".to_string()),
        Vec::new(),
    );
    match choice {
        TransportChoice::Unattached { reason } => {
            assert!(
                reason.contains("credential"),
                "LIVE=1 + missing secret must fail closed, got {reason}"
            );
        }
        TransportChoice::Scripted => panic!("LIVE=1 must not fall back to ScriptedTransport echo"),
        other => panic!("expected unattached, got {other:?}"),
    }
}

#[test]
fn live_flag_official_claude_without_secret_stays_live() {
    let spec = spec("claudeCode");
    let choice = resolve_transport_choice_from(
        &spec,
        |key| (key == "AGENTRY_AGENT_HOST_LIVE").then(|| "1".to_string()),
        Vec::new(),
    );
    match choice {
        TransportChoice::Live(_) => {}
        TransportChoice::Scripted => panic!("LIVE=1 must not echo"),
        other => panic!("official Claude without API key must stay live, got {other:?}"),
    }
}

#[test]
fn envelope_redeem_from_temp_dir_zeros_and_deletes() {
    let root = std::env::temp_dir().join(format!("agentry-envelope-{}", uuid_like()));
    let envelope_id = "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f70bb";
    let dir = root.join(".agentry-domain-runtime").join("envelopes");
    std::fs::create_dir_all(&dir).expect("envelope dir");
    let path = dir.join(envelope_id);
    std::fs::write(&path, "temp-dir-secret").expect("write envelope");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).expect("0600");
    }
    let mut spec = spec("claudeCode");
    spec.credential_envelope_id = envelope_id.to_string();
    let root_path = root.clone();
    let choice = resolve_transport_choice_from(
        &spec,
        |key| match key {
            "AGENTRY_AGENT_HOST_LIVE" => Some("1".to_string()),
            "AGENTRY_APPLICATION_SUPPORT_ROOT" => Some(root_path.to_string_lossy().into_owned()),
            _ => None,
        },
        Vec::new(),
    );
    match choice {
        TransportChoice::Live(launch) => {
            assert!(
                launch
                    .environment
                    .iter()
                    .any(|(name, value)| name == "ANTHROPIC_API_KEY" && value == "temp-dir-secret"),
                "redeemed envelope must overlay the provider secret"
            );
        }
        other => panic!("expected live after redeem, got {other:?}"),
    }
    assert!(!path.exists(), "host must zero+delete after redeem");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn keychain_env_is_ignored_inherited_env_still_overlays() {
    let spec = spec("kimiCode");
    let choice = resolve_transport_choice_from(
        &spec,
        |key| match key {
            "AGENTRY_AGENT_HOST_LIVE" => Some("1".to_string()),
            "AGENTRY_AGENT_HOST_READ_KEYCHAIN" => Some("1".to_string()),
            _ => None,
        },
        vec![("ANTHROPIC_API_KEY".to_string(), "from-env".to_string())],
    );
    match choice {
        TransportChoice::Live(launch) => {
            assert!(
                launch
                    .environment
                    .iter()
                    .any(|(name, value)| name == "ANTHROPIC_API_KEY" && value == "from-env"),
                "inherited env must remain the secret path"
            );
        }
        other => panic!("expected live from inherited env, got {other:?}"),
    }
}

#[test]
fn envelope_is_accepted_on_live_path_including_release_shaped_hosts() {
    let root = std::env::temp_dir().join(format!("agentry-envelope-release-{}", uuid_like()));
    let envelope_id = "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f70cc";
    let dir = root.join(".agentry-domain-runtime").join("envelopes");
    std::fs::create_dir_all(&dir).expect("envelope dir");
    let path = dir.join(envelope_id);
    std::fs::write(&path, "portable-envelope-secret").expect("write envelope");
    let mut spec = spec("kimiCode");
    spec.credential_envelope_id = envelope_id.to_string();
    let root_path = root.clone();
    let choice = resolve_transport_choice_from(
        &spec,
        |key| match key {
            "AGENTRY_APPLICATION_SUPPORT_ROOT" => Some(root_path.to_string_lossy().into_owned()),
            _ => None,
        },
        Vec::new(),
    );
    match choice {
        TransportChoice::Live(launch) => {
            assert!(
                launch.environment.iter().any(|(name, value)| {
                    name == "ANTHROPIC_API_KEY" && value == "portable-envelope-secret"
                }),
                "release must accept envelopeID, not reject it"
            );
        }
        other => panic!("expected live after envelope redeem, got {other:?}"),
    }
    assert!(!path.exists(), "host must zero+delete after redeem");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn working_directory_env_wins_over_worktree_id() {
    let mut spec = spec("claudeCode");
    spec.worktree_id = "/from/worktree-id".to_string();
    let choice = resolve_transport_choice_from(
        &spec,
        |key| match key {
            "AGENTRY_AGENT_HOST_LIVE" => Some("1".to_string()),
            "AGENTRY_AGENT_HOST_WORKING_DIRECTORY" => Some("/from/env".to_string()),
            _ => None,
        },
        Vec::new(),
    );
    match choice {
        TransportChoice::Live(launch) => {
            assert_eq!(launch.working_directory.as_deref(), Some("/from/env"));
        }
        other => panic!("expected live, got {other:?}"),
    }
}

fn uuid_like() -> String {
    format!(
        "{:x}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0)
    )
}
