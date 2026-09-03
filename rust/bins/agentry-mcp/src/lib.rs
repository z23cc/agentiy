//! Rust `agentry-mcp agent-host` (ADR-0011 P7). Speaks the frozen agent-host-v1
//! wire and `agent_session_log` on disk. Not the full MCP CLI.

#![deny(unsafe_code)]
#![allow(clippy::module_name_repetitions)]

pub mod client;
pub mod executor;
pub mod host;
pub mod hosted;
pub mod launch;
pub mod lease;
pub mod workspace_authority;
mod live;
pub mod paths;
pub mod peer;
mod time;
pub mod transport;
mod util;

pub use client::{AgentHostClient, CommandRoundtrip, HandshakeOutcome};
pub use executor::{SessionExecutor, StubExecutor, make_session_executor};
pub use host::{Host, HostConfig, HostHandle, arm_process_stop_signals};
pub use hosted::HostedRuntimeExecutor;
pub use launch::{
    LaunchSpec, LiveFamily, TransportChoice, resolve_transport_choice, resolve_transport_choice_from,
};
pub use lease::{HostLease, LeaseAcquisition, LeaseOwner};
pub use workspace_authority::{
    WorkspaceAuthorityLease, WorkspaceAuthorityObservation, WorkspaceClaim,
};
pub use live::LiveProviderTransport;
pub use paths::{APPLICATION_SUPPORT_ROOT_ENV, BuildFlavor, HostPaths};
pub use transport::{
    ProviderInbound, ProviderTransport, ScriptedTransport, UnattachedTransport,
    live_transport_for_missing_binary, make_provider_transport,
};

use agentry_proto::agent_host::FrameError;

#[derive(Debug, thiserror::Error)]
pub enum HostError {
    #[error("lease contended")]
    LeaseContended { observed_owner: Option<LeaseOwner> },
    #[error("lease failed: {0}")]
    LeaseFailed(String),
    #[error(transparent)]
    Path(#[from] paths::PathError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Frame(#[from] FrameError),
    #[error(transparent)]
    Log(#[from] agentry_agent_session_log::LogError),
    #[error("{0}")]
    Protocol(String),
}
