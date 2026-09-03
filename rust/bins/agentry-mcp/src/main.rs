//! `agentry-mcp agent-host` — Rust P7 host. Not the Swift MCP CLI.

use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

use agentry_mcp::peer;
use agentry_mcp::{Host, HostConfig, arm_process_stop_signals};

const EX_OK: u8 = 0;
const EX_USAGE: u8 = 2;
const EX_SOFTWARE: u8 = 70;
const EX_TEMPFAIL: u8 = 75;

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        return usage();
    };
    if command != "agent-host" {
        eprintln!(
            "agentry-mcp (rust): unknown command {command:?}; only `agent-host` is implemented"
        );
        return usage();
    }
    peer::become_session_leader();
    arm_process_stop_signals();

    let config = match parse_agent_host_args(args) {
        Ok(config) => config,
        Err(error) if error == "help" => return usage(),
        Err(error) => {
            eprintln!("agent-host: {error}");
            return usage();
        }
    };

    match Host::bind(config) {
        Ok(host) => {
            if let Err(error) = host.run() {
                eprintln!("agent-host: {error}");
                ExitCode::from(EX_SOFTWARE)
            } else {
                ExitCode::from(EX_OK)
            }
        }
        Err(agentry_mcp::HostError::LeaseContended { .. }) => {
            eprintln!("agent-host: lease contended");
            ExitCode::from(EX_TEMPFAIL)
        }
        Err(error) => {
            eprintln!("agent-host: {error}");
            ExitCode::from(EX_SOFTWARE)
        }
    }
}

fn parse_agent_host_args(args: impl Iterator<Item = String>) -> Result<HostConfig, String> {
    let mut config = HostConfig::from_env(None, cfg!(debug_assertions));
    let mut args = args.peekable();
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--idle-exit-seconds" => {
                let raw = args
                    .next()
                    .ok_or_else(|| "--idle-exit-seconds requires a value".to_string())?;
                config.idle_exit_seconds = parse_idle(&raw)?;
            }
            flag if flag.starts_with("--idle-exit-seconds=") => {
                config.idle_exit_seconds = parse_idle(&flag["--idle-exit-seconds=".len()..])?;
            }
            "--application-support-root" => {
                let root = args
                    .next()
                    .ok_or_else(|| "--application-support-root requires a value".to_string())?;
                config = HostConfig::from_env(Some(PathBuf::from(root)), cfg!(debug_assertions));
            }
            "--build-fingerprint" => {
                config.build_fingerprint = args
                    .next()
                    .ok_or_else(|| "--build-fingerprint requires a value".to_string())?;
            }
            "--accept-any-peer" => config.accept_any_peer = true,
            "--fail-prepare-update" => config.fail_prepare_update = true,
            "--debug-flavor" => config.paths = rebuild_paths(&config, true),
            "--release-flavor" => config.paths = rebuild_paths(&config, false),
            "--max-queued-events" => {
                config.max_queued_events = args
                    .next()
                    .and_then(|raw| raw.parse().ok())
                    .ok_or_else(|| "--max-queued-events requires a number".to_string())?;
            }
            "--max-queued-bytes" => {
                config.max_queued_bytes = args
                    .next()
                    .and_then(|raw| raw.parse().ok())
                    .ok_or_else(|| "--max-queued-bytes requires a number".to_string())?;
            }
            "--bundle-identifier" => {
                config.bundle_identifier = args.next().unwrap_or_default();
            }
            "--verbose" => {}
            "--help" | "-h" => return Err("help".to_string()),
            other => return Err(format!("unknown flag {other}")),
        }
    }
    Ok(config)
}

fn parse_idle(raw: &str) -> Result<Option<u64>, String> {
    let value: u64 = raw
        .parse()
        .map_err(|_| format!("--idle-exit-seconds expects a non-negative number, got {raw}"))?;
    Ok((value > 0).then_some(value))
}

fn rebuild_paths(config: &HostConfig, debug: bool) -> agentry_mcp::HostPaths {
    let flavor = if debug {
        agentry_mcp::BuildFlavor::Debug
    } else {
        agentry_mcp::BuildFlavor::Release
    };
    agentry_mcp::HostPaths::from_root(
        config.paths.application_support_root.clone(),
        flavor,
        config.paths.protocol_version,
        true,
        agentry_mcp::peer::current_uid(),
    )
}

fn usage() -> ExitCode {
    eprintln!(
        "Usage: agentry-mcp agent-host [--idle-exit-seconds N] [--application-support-root PATH] [--build-fingerprint HEX] [--accept-any-peer]"
    );
    ExitCode::from(EX_USAGE)
}
