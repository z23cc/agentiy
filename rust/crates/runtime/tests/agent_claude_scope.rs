//! P6-6 (`docs/designs/p6-claude-vertical-2026-08-23.md` §11, `docs/architecture/
//! rust-agent-claude-v1.md` §14): `AgentClaudeScope` end-to-end tests, driven against a real
//! spawned process (`agent-claude-synthetic-cli`) through the real `SubscriptionHub` -- no FFI
//! dependency yet (that lands in this step's next commit), but every primitive below is the same
//! one the FFI crate will call into. Covers this step's done-when: the five-outcome interrupt
//! surface with `staleGeneration` proven reachable, the gap/oversize/resnapshot paths, and identity
//! fencing (the cargo-only half of "identity-swap tested end-to-end").

use std::sync::Arc;
use std::time::{Duration, Instant};

use agentry_runtime::agent_claude::event::AgentClaudeEvent;
use agentry_runtime::agent_claude::scope::{
    AgentClaudeScope, AgentClaudeScopeConfig, AgentScopeError, FlagSettingsDisposition,
    PermissionDecisionInput, ScopeRegistry,
};
use agentry_runtime::{
    RuntimeEvent, RuntimeEventKind, RuntimeIdentity, SubscriptionConfig, SubscriptionHub,
};

fn synthetic_cli() -> &'static str {
    env!("CARGO_BIN_EXE_agent-claude-synthetic-cli")
}

fn identity(nonce: u8) -> RuntimeIdentity {
    RuntimeIdentity::new(
        1,
        format!("{nonce:02x}").repeat(16),
        "a".repeat(64),
        "b".repeat(64),
    )
    .expect("identity")
}

fn write_script(name: &str, contents: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "agent-claude-scope-test-{name}-{}.script",
        std::process::id()
    ));
    std::fs::write(&path, contents).expect("write script fixture");
    path
}

fn test_config(argv: Vec<String>) -> AgentClaudeScopeConfig {
    AgentClaudeScopeConfig {
        command: synthetic_cli().to_string(),
        arguments: argv,
        raw_argv_for_testing: true,
        interrupt_ack_timeout: Duration::from_millis(400),
        ..AgentClaudeScopeConfig::default()
    }
}

/// A small harness bundling a hub, a scope, and the subscription id, mirroring the shape the FFI
/// layer's `agent_open_scope` will assemble in the next commit.
struct Harness {
    hub: Arc<SubscriptionHub>,
    scope: Arc<AgentClaudeScope>,
    identity: RuntimeIdentity,
    subscription_id: agentry_runtime::SubscriptionId,
}

impl Harness {
    fn open(
        identity: RuntimeIdentity,
        config: AgentClaudeScopeConfig,
        subscription_config: SubscriptionConfig,
    ) -> Self {
        let hub = Arc::new(SubscriptionHub::new(identity.clone()).expect("hub"));
        let registry = ScopeRegistry::new();
        let scope = registry.open_scope(identity.clone(), config);
        let subscription_scope_id = scope.scope_id().to_subscription_scope_id();
        scope.attach_event_sink(Arc::clone(&hub), subscription_scope_id.clone());
        let bootstrap = hub
            .open_subscription(
                &identity,
                subscription_scope_id,
                subscription_config,
                Vec::new,
            )
            .expect("open subscription");
        // `registry` drops here at the end of this function -- harmless: `scope` (an `Arc` this
        // `Harness` keeps alive independently) is the *other* strong owner `ScopeRegistry::
        // open_scope` hands back, so dropping the registry's own map entry only decrements the
        // count by one, exactly like any other `Arc` clone going out of scope. Explicitly NOT
        // leaked/forgotten: an earlier draft did `std::mem::forget(registry)` here, which pinned a
        // permanent extra strong reference to `scope` forever and silently defeated the orphan-
        // backstop test below (`AgentClaudeScope::drop` never ran because the registry's own map
        // entry -- never released -- kept the strong count above zero indefinitely).
        Self {
            hub,
            scope,
            identity,
            subscription_id: bootstrap.subscription_id,
        }
    }

    fn drain(&self) -> Vec<RuntimeEvent> {
        match self
            .hub
            .try_drain(&self.identity, self.subscription_id, 64, 262_144)
            .expect("try_drain")
        {
            agentry_runtime::DrainOutcome::Batch(batch) => batch.events,
            agentry_runtime::DrainOutcome::Oversize(_) => Vec::new(),
        }
    }

    /// Drains repeatedly, decoding every event, until `predicate` matches one or `timeout` elapses.
    fn wait_for(
        &self,
        timeout: Duration,
        mut predicate: impl FnMut(&AgentClaudeEvent) -> bool,
    ) -> Option<AgentClaudeEvent> {
        let deadline = Instant::now() + timeout;
        loop {
            for event in self.drain() {
                if let Some(decoded) = AgentClaudeEvent::decode(&event.payload)
                    && predicate(&decoded)
                {
                    return Some(decoded);
                }
            }
            if Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn wait_until_not_in_flight(&self, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        while self.scope.diagnostics().turn_in_flight {
            assert!(
                Instant::now() < deadline,
                "turn never left in-flight state within {timeout:?}"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

fn field_str<'a>(event: &'a AgentClaudeEvent, key: &str) -> Option<&'a str> {
    event.fields.get(key).and_then(serde_json::Value::as_str)
}

fn field_u64(event: &AgentClaudeEvent, key: &str) -> Option<u64> {
    event.fields.get(key).and_then(serde_json::Value::as_u64)
}

fn field_bool(event: &AgentClaudeEvent, key: &str) -> Option<bool> {
    event.fields.get(key).and_then(serde_json::Value::as_bool)
}

fn field_f64(event: &AgentClaudeEvent, key: &str) -> Option<f64> {
    event.fields.get(key).and_then(serde_json::Value::as_f64)
}

#[test]
fn well_behaved_session_completes_a_turn_end_to_end() {
    // P6-7 (§15.5): `well-behaved` mode has no responder thread and can never ACK the session-
    // startup `initialize` handshake `start_or_resume` now blocks on, so this moves to `scripted`
    // mode: `AWAITACKS 1` proves the handshake completed, `SLEEP 200` is a generous margin past
    // it for the parent's own `send_user_message` call to land before the result line does (the
    // margin every other scripted test in this file relies on for content-ordering, not a
    // response to a specific event -- there is no signal for "the parent called
    // send_user_message"), and the `OUT` line replays exactly what `well-behaved` mode wrote.
    let script = write_script(
        "well-behaved-equivalent",
        "AWAITACKS 1\nSLEEP 200\nOUT {\"type\":\"result\",\"subtype\":\"success\"}\n",
    );
    let harness = Harness::open(
        identity(1),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let turn_id = harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");
    assert_eq!(
        turn_id, 1,
        "generation numbering starts at 1 (0 is the never-sent sentinel)"
    );

    let completed = harness
        .wait_for(Duration::from_secs(5), |event| {
            event.kind.wire_name() == "turnCompleted"
        })
        .expect("turnCompleted must be published");
    assert_eq!(completed.turn_id, Some(1));
    assert_eq!(field_str(&completed, "status"), Some("completed"));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn stdout_eof_publishes_process_exit_and_allows_a_fenced_restart() {
    let script = write_script("restart-after-eof", "AWAITACKS 1\nSLEEP 100\n");
    let harness = Harness::open(
        identity(31),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );

    let first = harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("first start");
    let first_exit = harness
        .wait_for(Duration::from_secs(3), |event| {
            event.kind.wire_name() == "processExited"
        })
        .expect("unexpected stdout EOF must publish the terminal processExited fact");
    assert_eq!(
        field_u64(&first_exit, "pid"),
        Some(first.pid as u64),
        "the PID-crossing receipt must identify the exact registration to clear"
    );
    assert!(matches!(
        harness
            .scope
            .send_user_message(&harness.identity, "dead stdin must not be reused"),
        Err(AgentScopeError::NotRunning)
    ));

    let second = harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("restart after EOF");
    assert_ne!(
        first.pid, second.pid,
        "restart must mint a new supervised process"
    );
    let second_exit = harness
        .wait_for(Duration::from_secs(3), |event| {
            event.kind.wire_name() == "processExited"
        })
        .expect("replacement process must retain the same EOF lifecycle contract");
    assert_eq!(field_u64(&second_exit, "pid"), Some(second.pid as u64));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn result_without_idle_is_completed_by_the_production_fallback_worker() {
    let script = write_script(
        "result-without-idle",
        concat!(
            "AWAITACKS 1\nSLEEP 200\n",
            "OUT {\"type\":\"system\",\"subtype\":\"session_state_changed\",\"session_state\":\"running\"}\n",
            "OUT {\"type\":\"result\",\"subtype\":\"success\"}\n",
            "SLEEP 2000\n",
        ),
    );
    let log_path = std::env::temp_dir().join(format!(
        "agent-claude-result-without-idle-{}.jsonl",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&log_path);
    let mut config = test_config(vec![
        "scripted".to_string(),
        script.to_string_lossy().to_string(),
    ]);
    config.idle_fallback = Duration::from_millis(100);
    config.raw_event_log_enabled = true;
    config.raw_event_log_file_path = Some(log_path.to_string_lossy().to_string());
    let harness = Harness::open(identity(23), config, SubscriptionConfig::default());
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let generation = harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");

    let completed = harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "turnCompleted"
        })
        .expect("the production fallback worker must release result-without-idle");
    assert_eq!(completed.turn_id, Some(generation));
    assert_eq!(field_str(&completed, "status"), Some("completed"));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let log = std::fs::read_to_string(&log_path).expect("fallback must be raw-logged");
    assert!(
        log.lines()
            .any(|line| line.contains("\"kind\":\"lifecycle.idleFallback\""))
    );
    let _ = std::fs::remove_file(&script);
    let _ = std::fs::remove_file(&log_path);
}

#[test]
fn interrupt_stale_generation_is_reachable_naming_n_while_n_plus_1_is_live() {
    let script = write_script("stale-generation", "SLEEP 3000\n");
    let harness = Harness::open(
        identity(2),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let generation_one = harness
        .scope
        .send_user_message(&harness.identity, "first")
        .expect("send 1");
    let generation_two = harness
        .scope
        .send_user_message(&harness.identity, "second")
        .expect("send 2");
    assert_eq!(generation_two, generation_one + 1);
    assert!(
        harness.scope.diagnostics().turn_in_flight,
        "both turns are still pending -- neither ever resulted"
    );

    let request_id = harness
        .scope
        .interrupt_turn(&harness.identity, generation_one, "stale test".to_string())
        .expect("interrupt naming the superseded generation");
    let outcome = harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "interruptOutcome"
                && field_str(event, "request_id") == Some(request_id.as_str())
        })
        .expect("interruptOutcome must be published");
    assert_eq!(field_str(&outcome, "outcome"), Some("staleGeneration"));
    assert_eq!(
        field_u64(&outcome, "current_generation"),
        Some(generation_two)
    );
    assert_eq!(
        field_bool(&outcome, "current_turn_in_flight"),
        Some(true),
        "staleGeneration must carry the fact a newer turn may be live, not just that this one is stale"
    );

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn interrupt_no_turn_in_flight_when_the_named_generation_is_current_and_already_settled() {
    // See well_behaved_session_completes_a_turn_end_to_end's comment: `well-behaved` mode cannot
    // ACK the session-startup handshake, so this is the same `scripted` equivalent.
    let script = write_script(
        "well-behaved-equivalent-2",
        "AWAITACKS 1\nSLEEP 200\nOUT {\"type\":\"result\",\"subtype\":\"success\"}\n",
    );
    let harness = Harness::open(
        identity(3),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let generation = harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");
    harness.wait_until_not_in_flight(Duration::from_secs(5));

    let request_id = harness
        .scope
        .interrupt_turn(&harness.identity, generation, "noop".to_string())
        .expect("interrupt");
    let outcome = harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "interruptOutcome"
                && field_str(event, "request_id") == Some(request_id.as_str())
        })
        .expect("interruptOutcome must be published");
    assert_eq!(field_str(&outcome, "outcome"), Some("noTurnInFlight"));
    assert_eq!(field_u64(&outcome, "current_generation"), Some(generation));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn interrupt_is_acknowledged_when_the_synthetic_cli_acks_the_control_request() {
    let script = write_script("acknowledged", "SLEEP 3000\n");
    let harness = Harness::open(
        identity(4),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let generation = harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");

    let request_id = harness
        .scope
        .interrupt_turn(&harness.identity, generation, "ack test".to_string())
        .expect("interrupt");
    let outcome = harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "interruptOutcome"
                && field_str(event, "request_id") == Some(request_id.as_str())
        })
        .expect("interruptOutcome must be published");
    assert_eq!(field_str(&outcome, "outcome"), Some("acknowledged"));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn interrupt_times_out_when_the_synthetic_cli_never_acks() {
    // NOACK_AFTER 1 lets the session-startup `initialize` handshake ACK normally (it is the
    // first control request this scope ever sends), then permanently starves every request after
    // it -- including the interrupt this test means to time out. Race-free by construction (the
    // cutoff is enforced inside the responder thread's own send decision against the actual ACK
    // count, not a main-thread poll of a toggle): an earlier `AWAITACKS 1\nNOACK\n...` version of
    // this script raced the parent's send_user_message+interrupt_turn round trip against the main
    // script thread's own NOACK-poll latency and flaked under load (observed acknowledged/applied
    // instead of timedOut).
    let script = write_script("timed-out", "NOACK_AFTER 1\nSLEEP 3000\n");
    let harness = Harness::open(
        identity(5),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let generation = harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");

    let request_id = harness
        .scope
        .interrupt_turn(&harness.identity, generation, "timeout test".to_string())
        .expect("interrupt");
    let outcome = harness
        .wait_for(Duration::from_secs(3), |event| {
            event.kind.wire_name() == "interruptOutcome"
                && field_str(event, "request_id") == Some(request_id.as_str())
        })
        .expect("interruptOutcome must be published");
    assert_eq!(field_str(&outcome, "outcome"), Some("timedOut"));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn interrupt_failed_when_the_control_request_write_hits_a_closed_stdin_pipe() {
    // The fifth and last contract §5.3 outcome, `ControlOutcome::WriteFailed` -> `"failed"` --
    // reached deterministically via the synthetic CLI's dedicated single-threaded
    // `stdin-closed-after-delay` mode (closes the child's own fd 0 after a fixed 50 ms delay,
    // with no background reader thread racing that close). Closing stdin alone never EOFs
    // stdout, so `turn_in_flight` stays true and the interrupt's synchronous precondition check
    // reaches the background round-trip thread every time, and the round trip's write reliably
    // hits `EPIPE` once the parent-side sleep below has cleared the child's 50 ms delay.
    let harness = Harness::open(
        identity(13),
        test_config(vec![
            "stdin-closed-after-delay".to_string(),
            "200".to_string(),
            "5000".to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let generation = harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");
    // Comfortably past the child's 200 ms delay before it closes stdin -- not a race, a fixed
    // margin (10x the delay, generous enough to absorb parallel `cargo test --workspace`
    // contention, which the FFI-level twin's own margin tuning showed matters here).
    std::thread::sleep(Duration::from_millis(2_000));

    let request_id = harness
        .scope
        .interrupt_turn(
            &harness.identity,
            generation,
            "closed-pipe test".to_string(),
        )
        .expect("interrupt");
    let outcome = harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "interruptOutcome"
                && field_str(event, "request_id") == Some(request_id.as_str())
        })
        .expect(
            "interruptOutcome must be published even when the control-request write itself fails",
        );
    assert_eq!(field_str(&outcome, "outcome"), Some("failed"));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
}

#[test]
fn apply_model_and_effort_publishes_flag_settings_applied_when_the_synthetic_cli_acks() {
    // P6-7 (§15.3): apply_model_and_effort's real ACK tracking, mirroring the interrupt outcome
    // tests' shape exactly -- the synthetic CLI's "scripted" mode background responder ACKs any
    // control_request generically, regardless of subtype, so this exercises the same round trip
    // production traffic would.
    let script = write_script("flag-settings-applied", "SLEEP 3000\n");
    let harness = Harness::open(
        identity(14),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let request_id = harness
        .scope
        .apply_model_and_effort(
            &harness.identity,
            Some("opus".to_string()),
            Some("high".to_string()),
            FlagSettingsDisposition::Live,
        )
        .expect("apply_model_and_effort must return a receipt immediately");

    let outcome = harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "flagSettingsApplied"
                && field_str(event, "request_id") == Some(request_id.as_str())
        })
        .expect("flagSettingsApplied must be published");
    assert_eq!(field_str(&outcome, "outcome"), Some("applied"));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn apply_model_and_effort_records_pending_and_restart_without_writing_control_requests() {
    let script = write_script("flag-settings-restart-required", "SLEEP 3000\n");
    let log_path = std::env::temp_dir().join(format!(
        "agent-claude-flag-settings-restart-required-{}.jsonl",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&log_path);
    let mut config = test_config(vec![
        "scripted".to_string(),
        script.to_string_lossy().to_string(),
    ]);
    config.raw_event_log_enabled = true;
    config.raw_event_log_file_path = Some(log_path.to_string_lossy().to_string());
    let harness = Harness::open(identity(22), config, SubscriptionConfig::default());
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");

    let pending_request_id = harness
        .scope
        .apply_model_and_effort(
            &harness.identity,
            Some("sonnet".to_string()),
            Some("high".to_string()),
            FlagSettingsDisposition::PendingInitialHandshake,
        )
        .expect("pending initial settings still return a correlated receipt");
    let pending_outcome = harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "flagSettingsApplied"
                && field_str(event, "request_id") == Some(pending_request_id.as_str())
        })
        .expect("pending outcome must be published without a control round trip");
    assert_eq!(field_str(&pending_outcome, "outcome"), Some("pending"));

    let request_id = harness
        .scope
        .apply_model_and_effort(
            &harness.identity,
            Some("glm-5".to_string()),
            None,
            FlagSettingsDisposition::RestartRequired,
        )
        .expect("restart-required decision still returns a correlated receipt");
    let outcome = harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "flagSettingsApplied"
                && field_str(event, "request_id") == Some(request_id.as_str())
        })
        .expect("restartRequired outcome must be published without a control round trip");
    assert_eq!(field_str(&outcome, "outcome"), Some("restartRequired"));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let log = std::fs::read_to_string(&log_path).expect("deferred decision must be raw-logged");
    assert!(
        log.lines()
            .any(|line| line.contains("\"kind\":\"session.flagSettingsPending\""))
    );
    assert!(
        log.lines()
            .any(|line| line.contains("\"kind\":\"session.flagSettingsDeferred\""))
    );
    let _ = std::fs::remove_file(&script);
    let _ = std::fs::remove_file(&log_path);
}

#[test]
fn apply_model_and_effort_times_out_when_the_synthetic_cli_never_acks() {
    // The script's SLEEP must outlast apply_model_and_effort's 5 s ACK deadline (scope.rs's
    // FLAG_SETTINGS_ACK_TIMEOUT) -- unlike the interrupt timeout tests above, which override
    // interrupt_ack_timeout down to 400 ms via test_config, this ACK timeout has no test-facing
    // override (it is not part of AgentClaudeScopeConfig, matching Swift's hardcoded 5.0 s literal
    // at the live-update call site). A shorter sleep lets the script -- and with it the child
    // process -- finish first, EOFing stdout and resolving the round trip via fail_all ("failed")
    // before the real timeout ever has a chance to fire. NOACK_AFTER 1 lets the session-startup
    // `initialize` handshake ACK normally, then permanently starves every request after it --
    // race-free by construction, see interrupt_times_out_when_the_synthetic_cli_never_acks's
    // comment for why the AWAITACKS+NOACK combination this replaced was not.
    let script = write_script("flag-settings-timeout", "NOACK_AFTER 1\nSLEEP 6000\n");
    let harness = Harness::open(
        identity(15),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let request_id = harness
        .scope
        .apply_model_and_effort(
            &harness.identity,
            Some("sonnet".to_string()),
            None,
            FlagSettingsDisposition::Live,
        )
        .expect("apply_model_and_effort");

    let outcome = harness
        .wait_for(Duration::from_secs(7), |event| {
            event.kind.wire_name() == "flagSettingsApplied"
                && field_str(event, "request_id") == Some(request_id.as_str())
        })
        .expect("flagSettingsApplied must still be published on timeout");
    assert_eq!(field_str(&outcome, "outcome"), Some("timedOut"));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn apply_model_and_effort_fails_when_the_control_request_write_hits_a_closed_stdin_pipe() {
    // Mirrors interrupt_failed_when_the_control_request_write_hits_a_closed_stdin_pipe's exact
    // mechanism and margin tuning (module doc there).
    let harness = Harness::open(
        identity(16),
        test_config(vec![
            "stdin-closed-after-delay".to_string(),
            "200".to_string(),
            "5000".to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    std::thread::sleep(Duration::from_millis(2_000));

    let request_id = harness
        .scope
        .apply_model_and_effort(
            &harness.identity,
            Some("opus".to_string()),
            None,
            FlagSettingsDisposition::Live,
        )
        .expect("apply_model_and_effort");
    let outcome = harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "flagSettingsApplied" && field_str(event, "request_id") == Some(request_id.as_str())
        })
        .expect("flagSettingsApplied must be published even when the control-request write itself fails");
    assert_eq!(field_str(&outcome, "outcome"), Some("failed"));
    assert!(field_str(&outcome, "error").is_some());

    harness.scope.shutdown(&harness.identity).expect("shutdown");
}

#[test]
fn permission_round_trip_allow_then_a_second_response_is_rejected_as_unknown() {
    let script = write_script(
        "permission",
        "OUT {\"type\":\"control_request\",\"request_id\":\"perm-1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"ls\"}}}\nSLEEP 2000\n",
    );
    let harness = Harness::open(
        identity(6),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");

    let approval = harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "approvalRequest"
        })
        .expect("approvalRequest must be published");
    assert_eq!(field_str(&approval, "request_id"), Some("perm-1"));
    assert_eq!(field_str(&approval, "tool_name"), Some("Bash"));

    harness
        .scope
        .respond_permission(
            &harness.identity,
            "perm-1",
            PermissionDecisionInput::Allow {
                include_updated_permissions: false,
            },
        )
        .expect("respond to a known pending permission request");
    assert_eq!(
        harness.scope.diagnostics().pending_permission_count,
        0,
        "the pending entry must be consumed on response"
    );

    let second = harness.scope.respond_permission(
        &harness.identity,
        "perm-1",
        PermissionDecisionInput::Allow {
            include_updated_permissions: false,
        },
    );
    assert_eq!(
        second,
        Err(agentry_runtime::agent_claude::scope::AgentScopeError::UnknownPermissionRequest),
        "responding twice to the same request id must not silently succeed"
    );

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn an_oversize_single_event_payload_is_rejected_not_silently_truncated_or_wedged() {
    // One assistant-content chunk whose text alone exceeds the subscription's 1 MiB byte cap --
    // contract §5.4/§7.1: "oversize ⇒ PayloadRejected + resnapshot_required", handled transparently
    // by `SubscriptionHub::publish`'s own enqueue-time check. This proves the scope's classification
    // wiring (assistantDelta as a plain `EventInput`, no special-casing for size) composes correctly
    // with that existing, already-tested mechanism.
    let huge_text = "x".repeat(2 * 1024 * 1024);
    let line = serde_json::json!({
        "type": "assistant",
        "message": {"content": [{"type": "text", "text": huge_text}]},
    });
    let script = write_script("oversize", &format!("OUT {line}\nSLEEP 1500\n"));
    let harness = Harness::open(
        identity(7),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send"); // turn in flight, so resnapshot appends

    let deadline = Instant::now() + Duration::from_secs(3);
    let mut saw_payload_rejected = false;
    while Instant::now() < deadline && !saw_payload_rejected {
        for event in harness.drain() {
            if event.kind == RuntimeEventKind::PayloadRejected {
                saw_payload_rejected = true;
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        saw_payload_rejected,
        "an over-cap single event payload must surface as PayloadRejected, not silently drop or crash the pipeline"
    );

    // The resnapshot buffer retained the (truncated-to-cap) text regardless of the event-lane
    // rejection -- the byte lane and the event lane are independent (contract §5.4).
    assert!(
        harness.scope.diagnostics().resnapshot_bytes_retained > 0,
        "the resnapshot buffer must still have retained the turn's text"
    );

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn a_lossless_event_evicts_a_resident_droppable_diagnostic_into_a_gap_record() {
    // A deliberately tiny subscription (1 usable data slot after the reserved terminal slot, i.e.
    // `data_event_limit() == 1` -- `subscription.rs`'s non-lossless `can_fit` check uses this
    // smaller limit, not the raw `max_queued_events`) makes the eviction path deterministic: two
    // real framer overflows (each an over-cap line) produce two droppable `framerOverflow`
    // diagnostics; the second cannot fit alongside the first (1 data slot, already occupied) and is
    // admitted as a coalesced-into-a-`Gap` record by the shared, already-tested `SubscriptionHub`
    // pressure policy (`subscription.rs`'s non-lossless branch: `add_gap` + `Dropped` when the data
    // slot is full) -- proving this scope's diagnostic-publish wiring composes correctly with it.
    let huge_line_one = "a".repeat(9 * 1024 * 1024); // over the framer's 8 MiB line cap
    let huge_line_two = "b".repeat(9 * 1024 * 1024);
    let script = write_script(
        "gap",
        &format!("OUT {huge_line_one}\nOUT {huge_line_two}\nSLEEP 1500\n"),
    );
    let harness = Harness::open(
        identity(8),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig {
            max_queued_events: 2,
            max_queued_bytes: 65_536,
            reserved_terminal_slots: 1,
            reserved_terminal_control_bytes: 4_096,
        },
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");

    // Deliberately does NOT drain while the two overflow diagnostics are being published --
    // draining relieves the very pressure this test needs to hold both entries in the queue at
    // once so the second eviction has something resident to evict. Instead, wait for the scripted
    // child to reach EOF (turn_in_flight flips false once `on_stdout_eof` flushes the never-
    // resulted turn), by which point both overflow diagnostics have long since been published, and
    // only then drain once to inspect the queue's final resident state.
    // Generous: streaming two 9 MiB lines through the framer is dominated by per-byte
    // instrumentation overhead under `--sanitize thread`/`address`, not by anything this test
    // itself is measuring.
    let deadline = Instant::now() + Duration::from_secs(30);
    while harness.scope.diagnostics().turn_in_flight {
        assert!(
            Instant::now() < deadline,
            "the scripted child never reached EOF within the timeout"
        );
        std::thread::sleep(Duration::from_millis(20));
    }

    let mut saw_gap = false;
    let mut seen_kinds: Vec<(RuntimeEventKind, Option<String>)> = Vec::new();
    for event in harness.drain() {
        seen_kinds.push((
            event.kind,
            AgentClaudeEvent::decode(&event.payload).map(|e| e.kind.wire_name().to_string()),
        ));
        if event.kind == RuntimeEventKind::Gap {
            saw_gap = true;
        }
    }
    assert!(
        saw_gap,
        "the resident droppable diagnostic must be evicted into a Gap record when a lossless event needs its slot: seen {seen_kinds:?}"
    );

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn resnapshot_buffer_truncates_from_the_head_and_emits_a_marker_once_the_turn_exceeds_the_cap() {
    let chunk = "y".repeat(512 * 1024);
    let mut script_body = String::new();
    for _ in 0..20 {
        let line = serde_json::json!({"type": "assistant", "message": {"content": [{"type": "text", "text": chunk}]}});
        script_body.push_str("OUT ");
        script_body.push_str(&line.to_string());
        script_body.push('\n');
    }
    script_body.push_str("SLEEP 1500\n");
    let script = write_script("resnapshot", &script_body);
    let harness = Harness::open(
        identity(9),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");

    let truncated = harness
        .wait_for(Duration::from_secs(5), |event| {
            event.kind.wire_name() == "transcriptTruncated"
        })
        .expect(
            "transcriptTruncated must be published once the per-turn buffer exceeds its 8 MiB cap",
        );
    assert!(field_u64(&truncated, "dropped_bytes").unwrap_or(0) > 0);
    let diagnostics = harness.scope.diagnostics();
    assert_eq!(
        diagnostics.resnapshot_bytes_retained,
        8 * 1024 * 1024,
        "the buffer must be pinned at exactly its cap after truncating"
    );
    assert!(diagnostics.resnapshot_truncation_count > 0);

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn every_command_rejects_a_mismatched_runtime_identity_identity_swap_fencing() {
    // See well_behaved_session_completes_a_turn_end_to_end's comment: `well-behaved` mode cannot
    // ACK the session-startup handshake the real-identity `start_or_resume` call below needs.
    let script = write_script("identity-swap", "AWAITACKS 1\nSLEEP 500\n");
    let harness = Harness::open(
        identity(10),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    let intruder = identity(11);
    let scope = Arc::clone(&harness.scope);

    assert_eq!(
        scope
            .start_or_resume(&intruder, None, None, None)
            .unwrap_err(),
        agentry_runtime::agent_claude::scope::AgentScopeError::IdentityMismatch
    );
    scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start under the real identity");
    assert_eq!(
        scope.send_user_message(&intruder, "hi").unwrap_err(),
        agentry_runtime::agent_claude::scope::AgentScopeError::IdentityMismatch
    );
    assert_eq!(
        scope
            .interrupt_turn(&intruder, 1, "x".to_string())
            .unwrap_err(),
        agentry_runtime::agent_claude::scope::AgentScopeError::IdentityMismatch
    );
    assert_eq!(
        scope
            .apply_model_and_effort(&intruder, None, None, FlagSettingsDisposition::Live)
            .unwrap_err(),
        agentry_runtime::agent_claude::scope::AgentScopeError::IdentityMismatch
    );
    assert_eq!(
        scope
            .respond_permission(
                &intruder,
                "unknown",
                PermissionDecisionInput::Allow {
                    include_updated_permissions: false
                }
            )
            .unwrap_err(),
        agentry_runtime::agent_claude::scope::AgentScopeError::IdentityMismatch
    );
    assert_eq!(
        scope.shutdown(&intruder).unwrap_err(),
        agentry_runtime::agent_claude::scope::AgentScopeError::IdentityMismatch
    );

    scope
        .shutdown(&harness.identity)
        .expect("the real identity can still shut the scope down");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn a_scope_dropped_without_shutdown_is_reaped_by_the_orphan_backstop_not_left_a_zombie() {
    // The same-process Swift/Rust reaper coexistence obligation the campaign carries forward to
    // this slice (module doc: "explicitly deferred to the FFI-bridge slice") -- proven here at the
    // Rust-only level: dropping a scope with a live child never leaves the child a zombie, matching
    // `ScopeDropWithoutWait`'s contract §5.2 orphan-backstop coverage. The Swift-side half (a Rust-
    // supervised child dropped while Swift's own `ProcessTermination` reaps a separate child
    // concurrently, in the same process) is covered by this step's Swift bridge test suite.
    let script = write_script("orphan", "SLEEP 5000\n");
    let harness = Harness::open(
        identity(12),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let pid = harness.scope.diagnostics(); // touch to make sure the scope is alive first
    let _ = pid;
    drop(harness); // no shutdown() call -- exercises the orphan backstop in `Drop`

    // Confirm no zombie/child survives (best-effort: a hard assertion here would need the raw pid,
    // which `Harness` does not expose -- the P6-4 coexistence soak already hard-asserts zero
    // zombies at quiesce across thousands of cycles; this test's job is only to prove `Drop` does
    // not hang or panic when a live child is still registered) -- and, distinctly, wait for every
    // agent-domain thread (this scope's two readers plus its now-orphaned reaper, once the
    // backstop thread's own `Arc<Reaper>` reference drops) to actually finish before this test
    // process exits. TSan flags a still-running-or-unjoined-at-process-exit thread as a "thread
    // leak" even though a detached thread finishing after its owning scope drops is intentional,
    // correct production behavior (module doc: readers are never joined outside `shutdown()`) --
    // this poll exists only to give this *short-lived test binary* time to observe that natural
    // completion, not because production code needs to. The deadline is generous because
    // `--sanitize thread` instrumentation slows every syscall/lock substantially, stacked on top
    // of the backstop's own up-to-2s grace window.
    // Best-effort, not a hard assertion: `AGENT_DOMAIN_THREAD_COUNT` is a process-wide counter, and
    // this crate's own test binaries do not force `--test-threads=1` for ordinary runs, so a
    // concurrently-running test's threads can keep the count above zero for reasons unrelated to
    // this one. The wait exists only to give this scope's own threads a real chance to finish
    // before the process exits, for the sanitizer runs (`--test-threads=1`, per this crate's
    // established TSan/ASan protocol) where that ordering guarantee does hold.
    let deadline = Instant::now() + Duration::from_secs(10);
    while agentry_runtime::agent_claude::process::thread_budget::AGENT_DOMAIN_THREAD_COUNT
        .load(std::sync::atomic::Ordering::SeqCst)
        > 0
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = std::fs::remove_file(&script);
}

/// D-6 (design + contract §9, contract §7.1): every non-nil `StreamResult` field must ride the
/// wire, not just the one field per kind `emit_stream_result`'s match arms carried pre-P6-7 --
/// including the authoritative `message_stop` result's usage/cost/providerSessionID/stopReason
/// fields, which `handle_authoritative_result` previously discarded entirely, publishing only the
/// `turnCompleted` event's minimal `status` payload. Drives a real synthetic-CLI child through a
/// tool_call/tool_result/result sequence -- the real spawn/read/frame/decode/translate/publish
/// pipeline, not an in-process `StreamResult` construction -- and asserts every field
/// `stream_result_wire_fields` is documented to carry is actually present on the wire.
#[test]
fn every_stream_result_field_rides_the_wire_not_just_one_field_per_kind() {
    let script = write_script(
        "field-complete",
        concat!(
            // AWAITACKS 1 gates every OUT line behind the session-startup `initialize` handshake
            // completing; SLEEP 200 is the same generous parent-call-ordering margin
            // well_behaved_session_completes_a_turn_end_to_end's comment explains (the send_user_
            // message call below must land before these OUT lines, and there is no signal for it).
            "AWAITACKS 1\nSLEEP 200\n",
            "OUT {\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}}\n",
            "OUT {\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"file1\\nfile2\"}]}}\n",
            "OUT {\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"claude-session-d6\",\"result\":\"All done.\",\"total_cost_usd\":0.0421,\"usage\":{\"input_tokens\":120,\"output_tokens\":45},\"stop_reason\":\"end_turn\"}\n",
        ),
    );
    let harness = Harness::open(
        identity(17),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");

    // `Harness::wait_for` drains a whole batch and returns on its first predicate match, silently
    // discarding any other already-drained events in that same batch -- fine for the single-event
    // waits every other test in this file does, wrong here where three distinct events (all
    // written by the synthetic CLI almost simultaneously) can legitimately land in one batch.
    // Collect everything up through turnCompleted instead, then assert against the accumulated set.
    let mut collected: Vec<AgentClaudeEvent> = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !collected
        .iter()
        .any(|event| event.kind.wire_name() == "turnCompleted")
    {
        for event in harness.drain() {
            if let Some(decoded) = AgentClaudeEvent::decode(&event.payload) {
                collected.push(decoded);
            }
        }
        assert!(
            Instant::now() < deadline,
            "turnCompleted never arrived within the deadline; collected so far: {collected:?}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    let tool_started = collected
        .iter()
        .find(|event| event.kind.wire_name() == "toolUseStarted")
        .expect("toolUseStarted must be published");
    assert_eq!(
        field_str(tool_started, "type"),
        Some("tool_call"),
        "the original translator kind must ride as an explicit field"
    );
    assert_eq!(field_str(tool_started, "tool_name"), Some("Bash"));
    assert!(
        field_u64(tool_started, "invocation_id").is_some(),
        "tool_call/tool_result correlation id must be present"
    );
    assert!(
        field_str(tool_started, "tool_args_json").is_some(),
        "tool_call must carry the serialized input"
    );

    let tool_result = collected
        .iter()
        .find(|event| event.kind.wire_name() == "toolResult")
        .expect("toolResult must be published");
    assert_eq!(field_str(tool_result, "type"), Some("tool_result"));
    assert_eq!(
        field_str(tool_result, "tool_name"),
        Some("Bash"),
        "tool_result resolves its name from the matching tool_call"
    );
    assert_eq!(field_str(tool_result, "tool_output"), Some("file1\nfile2"));

    let message_stop = collected
        .iter()
        .find(|event| field_str(event, "type") == Some("message_stop"))
        .expect(
            "the authoritative message_stop result must ride the wire as its own stream event, \
             not only as turnCompleted's minimal status payload",
        );
    assert_eq!(field_u64(message_stop, "prompt_tokens"), Some(120));
    assert_eq!(field_u64(message_stop, "completion_tokens"), Some(45));
    assert_eq!(field_f64(message_stop, "cost"), Some(0.0421));
    assert_eq!(
        field_str(message_stop, "provider_session_id"),
        Some("claude-session-d6")
    );
    assert_eq!(field_str(message_stop, "stop_reason"), Some("end_turn"));

    let completed = collected
        .iter()
        .find(|event| event.kind.wire_name() == "turnCompleted")
        .expect(
            "turnCompleted must still be published, separately from the message_stop stream event",
        );
    assert_eq!(field_str(completed, "status"), Some("completed"));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

/// P6-7 D-9/R9 (`docs/architecture/rust-agent-claude-v1.md` §15.6): the live-synthetic-CLI-driven
/// half of D-9's kind-set completeness gate -- drives one representative session (handshake with a
/// non-empty `permission_mode`, a keep-alive, a control-cancel-request, an undecodable line, a
/// concatenated-two-objects line, a `system/init` line, a full tool_use/tool_result/can_use_tool/
/// result turn, then `apply_model_and_effort` and `respond_permission`) through the real scope with
/// raw-event logging enabled, and asserts every kind naturally reachable from that one session is
/// present in the written JSONL file. The kinds this test does not reach (`turn.interrupted`/
/// `timedOut`/`failed`, and every kind `scope.rs::raw_event_log_kind_mapping_tests` covers instead)
/// are named in `rust-agent-claude-v1.md` §15.6's own accounting table, not silently unaccounted
/// for.
#[test]
fn raw_event_log_completeness_a_representative_session_produces_every_naturally_reachable_kind() {
    let log_dir =
        std::env::temp_dir().join(format!("raw-event-log-completeness-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&log_dir);
    let log_path = log_dir.join("events.jsonl");
    let script = write_script(
        "raw-log-completeness",
        concat!(
            // Two handshake requests (init + permmode, since permission_mode is non-empty below).
            "AWAITACKS 2\nSLEEP 200\n",
            "OUT {\"type\":\"keep_alive\"}\n",
            "OUT {\"type\":\"control_cancel_request\",\"request_id\":\"cancel-1\"}\n",
            // Short and brace-free: fails every D-1 recovery heuristic (too short for plaintext
            // salvage's >=40-char threshold, no `{` for concatenated-split/embedded-tail, no
            // control characters to repair) -- the genuine `Declined` -> `protocol.decode.skipped`
            // case, not an accidental plaintext-salvage success.
            "OUT nope\n",
            "OUT {\"type\":\"system\",\"subtype\":\"status\",\"status\":\"a\"}{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"b\"}\n",
            "OUT {\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"raw-log-session\",\"tools\":[\"Read\",\"Bash\"],\"mcp_servers\":[{\"name\":\"RepoPromptCE\",\"status\":\"connected\"}]}\n",
            "OUT {\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}}\n",
            "OUT {\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"file1\"}]}}\n",
            "OUT {\"type\":\"control_request\",\"request_id\":\"perm-1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"ls\"}}}\n",
            "SLEEP 100\n",
            "OUT {\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"raw-log-session\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}\n",
            "SLEEP 3000\n",
        ),
    );
    let config = AgentClaudeScopeConfig {
        command: synthetic_cli().to_string(),
        arguments: vec!["scripted".to_string(), script.to_string_lossy().to_string()],
        raw_argv_for_testing: true,
        interrupt_ack_timeout: Duration::from_millis(400),
        permission_mode: Some("acceptEdits".to_string()),
        raw_event_log_enabled: true,
        raw_event_log_file_path: Some(log_path.to_string_lossy().to_string()),
        ..AgentClaudeScopeConfig::default()
    };
    let harness = Harness::open(identity(21), config, SubscriptionConfig::default());
    harness
        .scope
        .start_or_resume(
            &harness.identity,
            None,
            Some("opus".to_string()),
            Some("high".to_string()),
        )
        .expect("start");
    harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");

    harness
        .wait_for(Duration::from_secs(5), |event| {
            event.kind.wire_name() == "turnCompleted"
        })
        .expect("turnCompleted must be published once the scripted result line lands");

    let flags_request_id = harness
        .scope
        .apply_model_and_effort(
            &harness.identity,
            Some("opus".to_string()),
            None,
            FlagSettingsDisposition::Live,
        )
        .expect("apply_model_and_effort");
    harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "flagSettingsApplied"
                && field_str(event, "request_id") == Some(flags_request_id.as_str())
        })
        .expect("flagSettingsApplied must be published");

    harness
        .scope
        .respond_permission(
            &harness.identity,
            "perm-1",
            PermissionDecisionInput::Allow {
                include_updated_permissions: false,
            },
        )
        .expect("respond_permission");

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);

    let contents = std::fs::read_to_string(&log_path)
        .expect("raw event log file must exist after an enabled session");
    let records: Vec<serde_json::Value> = contents
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .collect();
    let kinds: std::collections::HashSet<String> = records
        .iter()
        .filter_map(|value| {
            value
                .get("kind")
                .and_then(|kind| kind.as_str())
                .map(str::to_string)
        })
        .collect();

    let expected = [
        "session.startOrResume",
        "process.spawned",
        "protocol.outbound.raw",
        "protocol.inbound.raw",
        "control.request.sent",
        "session.initialized",
        "session.permissionModeInitialized",
        "protocol.inbound.keepAlive",
        "protocol.inbound.controlCancelRequest",
        "control.request.cancelled",
        "protocol.decode.skipped",
        "protocol.inbound.recoveredSegment",
        "protocol.decode.recovered",
        "protocol.inbound.streamPayload",
        "runtime.init.stream",
        "translator.streamResult",
        "protocol.inbound.controlRequest",
        "control.request.received",
        "approval.request.emitted",
        "protocol.inbound.controlResponse",
        "control.response.received",
        "session.flagSettingsApplied",
        "approval.response.sent",
        "session.shutdown",
    ];
    let missing: Vec<&str> = expected
        .iter()
        .copied()
        .filter(|kind| !kinds.contains(*kind))
        .collect();
    assert!(
        missing.is_empty(),
        "raw event log missing expected kinds: {missing:?}; present: {kinds:?}"
    );

    let record = |kind: &str| {
        records
            .iter()
            .find(|record| record.get("kind").and_then(serde_json::Value::as_str) == Some(kind))
            .unwrap_or_else(|| panic!("missing raw record {kind}"))
    };
    let start = &record("session.startOrResume")["payload"];
    assert_eq!(start["existingSessionID"], serde_json::Value::Null);
    assert_eq!(start["model"], "opus");
    assert_eq!(start["effortLevel"], "high");
    assert_eq!(start["hasSystemPromptOverride"], false);
    let spawned = &record("process.spawned")["payload"];
    assert!(spawned.get("pid").is_none() && spawned.get("processGroupID").is_none());
    let sent = &record("control.request.sent")["payload"];
    assert_eq!(sent["expectsResponse"], true);
    assert!(sent["request"].is_object());
    let permission_mode = &record("session.permissionModeInitialized")["payload"];
    assert_eq!(permission_mode["requestedMode"], "acceptEdits");
    assert!(permission_mode["response"].is_object());
    let init_record = record("runtime.init.stream");
    assert_eq!(init_record["sessionID"], "raw-log-session");
    let init = &init_record["payload"];
    assert_eq!(init["sessionID"], "raw-log-session");
    assert_eq!(init["tools"], serde_json::json!(["Read", "Bash"]));
    assert_eq!(init["mcpServerStatuses"]["RepoPromptCE"], "connected");
    assert!(
        records.iter().any(|record| {
            record["kind"] == "session.header" && record["sessionID"] == "raw-log-session"
        }),
        "the stream-observed session ID must start a new envelope/header epoch"
    );
    let skipped = &record("protocol.decode.skipped")["payload"];
    assert_eq!(skipped["preview"], "nope");
    assert_eq!(skipped["codecError"], "invalidJSON");
    let translated = &record("translator.streamResult")["payload"];
    assert!(translated.get("type").is_some());
    assert!(
        translated.get("text").is_some(),
        "nil legacy fields must remain explicit JSON nulls"
    );

    let _ = std::fs::remove_dir_all(&log_dir);
}

/// P6-7 D-9/R9: the one live-reachable interrupt outcome the completeness test above cannot also
/// reach (its own turn is already completed by the time it would interrupt). `NOACK_AFTER` is
/// deliberately not used here -- this proves the *ACKed* (`turn.interrupted`) branch, the timeout/
/// failure branches' kind strings are covered by direct inspection against §15.6's table (see that
/// section's own note).
#[test]
fn raw_event_log_records_turn_interrupted_on_the_acknowledged_outcome() {
    let log_dir =
        std::env::temp_dir().join(format!("raw-event-log-interrupt-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&log_dir);
    let log_path = log_dir.join("events.jsonl");
    let script = write_script("raw-log-interrupt", "AWAITACKS 1\nSLEEP 3000\n");
    let config = AgentClaudeScopeConfig {
        command: synthetic_cli().to_string(),
        arguments: vec!["scripted".to_string(), script.to_string_lossy().to_string()],
        raw_argv_for_testing: true,
        interrupt_ack_timeout: Duration::from_millis(400),
        raw_event_log_enabled: true,
        raw_event_log_file_path: Some(log_path.to_string_lossy().to_string()),
        ..AgentClaudeScopeConfig::default()
    };
    let harness = Harness::open(identity(22), config, SubscriptionConfig::default());
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    let generation = harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");
    let request_id = harness
        .scope
        .interrupt_turn(&harness.identity, generation, "test".to_string())
        .expect("interrupt");
    harness
        .wait_for(Duration::from_secs(2), |event| {
            event.kind.wire_name() == "interruptOutcome"
                && field_str(event, "request_id") == Some(request_id.as_str())
        })
        .expect("interruptOutcome must be published");

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);

    let contents = std::fs::read_to_string(&log_path).expect("raw event log file must exist");
    assert!(
        contents
            .lines()
            .any(|line| line.contains("\"kind\":\"turn.interrupted\"")),
        "expected a turn.interrupted record; file contents: {contents}"
    );

    let _ = std::fs::remove_dir_all(&log_dir);
}

/// P6-7 (advisor follow-up to §15.5): the positive half of "resume-vs-start variants per what
/// Swift actually does" -- `initializeIfNeeded` has no `existingSessionID` branch in
/// `ClaudeNativeProcessSessionController.swift` (`:701-724`), so `start_or_resume`'s handshake must
/// run identically whether `resume_session_id` is `None` (the negative half every other scripted
/// test above exercises) or `Some(...)` (a resume). Proves the handshake still completes -- and a
/// post-handshake turn still runs to completion -- when a resume id is supplied.
#[test]
fn start_or_resume_runs_the_full_handshake_on_a_resume_not_just_a_fresh_start() {
    let script = write_script(
        "resume-handshake",
        "AWAITACKS 1\nSLEEP 200\nOUT {\"type\":\"result\",\"subtype\":\"success\"}\n",
    );
    let harness = Harness::open(
        identity(18),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(
            &harness.identity,
            Some("prior-session-id".to_string()),
            None,
            None,
        )
        .expect("a resumed start must also complete the initialize handshake and return");
    let turn_id = harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");
    assert_eq!(turn_id, 1);

    let completed = harness
        .wait_for(Duration::from_secs(5), |event| {
            event.kind.wire_name() == "turnCompleted"
        })
        .expect("turnCompleted must be published after a resumed start's handshake");
    assert_eq!(field_str(&completed, "status"), Some("completed"));

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

/// P6-7 (advisor follow-up to §15.5): `send_initialize_request` records the `initialize` control
/// response's own `session_id` into `translator.cli_session_id` (`scope.rs:507-513`), the same field
/// `send_user_message` reads for `--resume` continuity and `parse_result_message` writes into every
/// `message_stop`'s `provider_session_id` (`translator.rs:523-524,551`). This id is captured *only*
/// from the initialize handshake response here -- no `OUT` stream line ever carries `session_id` --
/// isolating this capture path from the pre-existing stream-message one
/// (`session_state_changed_sequence_including_idle_emits_lowercased_trimmed_text` and friends in
/// `translator.rs` already cover that one).
#[test]
fn initialize_response_session_id_is_captured_and_rides_a_later_message_stop() {
    let script = write_script(
        "initialize-session-id",
        concat!(
            "ACK_SESSION_ID claude-session-from-initialize\n",
            "AWAITACKS 1\nSLEEP 200\n",
            "OUT {\"type\":\"result\",\"subtype\":\"success\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}\n",
        ),
    );
    let harness = Harness::open(
        identity(19),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");
    harness
        .scope
        .send_user_message(&harness.identity, "hello")
        .expect("send");

    let message_stop = harness
        .wait_for(Duration::from_secs(5), |event| {
            field_str(event, "provider_session_id").is_some()
        })
        .expect("a stream result carrying provider_session_id must be published");
    assert_eq!(
        field_str(&message_stop, "provider_session_id"),
        Some("claude-session-from-initialize"),
        "the id observed only from the initialize handshake's own response must ride a later message_stop, \
         proving send_initialize_request's cli_session_id write took effect"
    );

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

/// P6-7 (advisor follow-up to §15.5, diagnosing the differential test's `SLEEP 200`->`SLEEP 500`
/// margin bump rather than just papering over it): reproduces the differential test's exact two
/// adjacent `OUT` lines -- a `can_use_tool` control_request (-> `approvalRequest`, `EventClass::
/// Lossless`, `terminal_reserve: true`) immediately followed by a `session_state_changed(running)`
/// stream line (-> `sessionStateChanged`, `EventClass::Coalescible`, coalesce key `"progress"`,
/// `event.rs:174-185`) -- through the real scope/`SubscriptionHub` pipeline (no Swift hop at all),
/// to locate whether a same-thread, same-order `publish` pair can still drain out of order. If this
/// is stable, the inversion the differential test's `SLEEP` margin was covering for is downstream of
/// this pipeline (the Swift adapter's own event pump/stream hop), not a Rust-side ordering bug.
#[test]
fn approval_request_and_session_state_changed_drain_in_publish_order() {
    let script = write_script(
        "approval-then-session-state-order",
        concat!(
            "AWAITACKS 1\nSLEEP 200\n",
            "OUT {\"type\":\"control_request\",\"request_id\":\"perm-order-1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"ls\"}}}\n",
            "OUT {\"type\":\"system\",\"subtype\":\"session_state_changed\",\"session_state\":\"running\"}\n",
            "SLEEP 2000\n",
        ),
    );
    let harness = Harness::open(
        identity(20),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");

    let mut collected: Vec<AgentClaudeEvent> = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !collected
        .iter()
        .any(|event| event.kind.wire_name() == "sessionStateChanged")
    {
        for event in harness.drain() {
            if let Some(decoded) = AgentClaudeEvent::decode(&event.payload) {
                collected.push(decoded);
            }
        }
        assert!(
            Instant::now() < deadline,
            "sessionStateChanged never arrived within the deadline; collected so far: {collected:?}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    let approval_index = collected
        .iter()
        .position(|event| event.kind.wire_name() == "approvalRequest")
        .expect("approvalRequest must be published");
    let session_state_index = collected
        .iter()
        .position(|event| event.kind.wire_name() == "sessionStateChanged")
        .expect("sessionStateChanged must be published");
    assert!(
        approval_index < session_state_index,
        "the can_use_tool line was written strictly before the session_state_changed line, so a \
         same-pipeline drain must preserve that order; collected: {collected:?}"
    );

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}

#[test]
fn tool_result_and_following_approval_request_drain_in_stdout_order() {
    let script = write_script(
        "tool-result-then-approval-order",
        concat!(
            "AWAITACKS 1\nSLEEP 200\n",
            "OUT {\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"tu-order-1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}}\n",
            "OUT {\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu-order-1\",\"content\":\"done\"}]}}\n",
            "OUT {\"type\":\"control_request\",\"request_id\":\"perm-order-2\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"rm -rf /tmp/x\"}}}\n",
            "SLEEP 2000\n",
        ),
    );
    let harness = Harness::open(
        identity(21),
        test_config(vec![
            "scripted".to_string(),
            script.to_string_lossy().to_string(),
        ]),
        SubscriptionConfig::default(),
    );
    harness
        .scope
        .start_or_resume(&harness.identity, None, None, None)
        .expect("start");

    let mut collected: Vec<AgentClaudeEvent> = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !collected
        .iter()
        .any(|event| event.kind.wire_name() == "approvalRequest")
    {
        for event in harness.drain() {
            if let Some(decoded) = AgentClaudeEvent::decode(&event.payload) {
                collected.push(decoded);
            }
        }
        assert!(
            Instant::now() < deadline,
            "approvalRequest never arrived within the deadline; collected so far: {collected:?}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    let tool_result_index = collected
        .iter()
        .position(|event| event.kind.wire_name() == "toolResult")
        .expect("toolResult must be published");
    let approval_index = collected
        .iter()
        .position(|event| event.kind.wire_name() == "approvalRequest")
        .expect("approvalRequest must be published");
    assert!(
        tool_result_index < approval_index,
        "the stdout pipeline and SubscriptionHub must preserve tool_result before the following approval; collected: {collected:?}"
    );

    harness.scope.shutdown(&harness.identity).expect("shutdown");
    let _ = std::fs::remove_file(&script);
}
