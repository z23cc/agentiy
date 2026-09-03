//! ADR-0011 P6-a (B track; design §4.1.1 layer table, §7.1, §8 row "P6-a"): the Agent Mode run
//! lifecycle reducers, ported one-for-one from `Sources/RepoPromptDomainRuntime/DomainAgentRun*`
//! (P14–P18 specs under `docs/spec/headless-mcp-domain-runtime-p1*-agent-run-*.md`).
//!
//! Everything here is a pure value-state reducer: no I/O, no clocks, no identity generation.
//! Time (`timestamp_uptime_nanoseconds`) and identities (attempt, tab, session, commit, token,
//! process run UUIDs) are inputs. Determinism is what makes the Swift ⇄ Rust differential harness
//! (`Tests/RepoPromptDomainRuntimeTests/DomainAgentRunRustDifferentialTests.swift`) meaningful and
//! what lets the host record reducer output straight into the `agent_host_v1` event log without a
//! translation layer (`proto` module: `RunLifecycleEvent` projections).
//!
//! Inventory (Swift type → Rust type):
//!
//! | Swift (`RepoPromptDomainRuntime`)                  | Rust                                  |
//! |----------------------------------------------------|---------------------------------------|
//! | `DomainAgentRunLifecycleTracker`                   | [`LifecycleTracker`]                  |
//! | `DomainAgentRunProcessIdentityState`               | [`ProcessIdentityState`]              |
//! | `DomainAgentRunTerminalCommitState`                | [`TerminalCommitState`]               |
//! | `DomainAgentRunTerminalSettlementCoordinator`      | [`TerminalSettlementCoordinator`]     |
//! | `DomainAgentRunProviderSemanticAuthority`          | [`SemanticAuthority`]                 |
//! | `DomainAgentRunExecutionCore` (classification only)| [`SemanticAuthority::classify_execution`] |
//!
//! The Swift originals stay in place until the GUI cutover (ADR-0011 decision 11); this module is
//! the future single owner, proven equivalent first.

#![allow(clippy::module_name_repetitions)]

mod canonical;
mod process_identity;
mod proto;
mod semantic;
mod settlement;
mod terminal_commit;
mod tracker;
mod types;
mod uuid;

pub use canonical::{Canonical, CanonicalValue, json_string};
pub use process_identity::ProcessIdentityState;
pub use proto::{ProtoConversionError, terminated_event};
pub use semantic::{
    ExecutionOperationResult, ExecutionReport, ExecutionResult, ExecutionTraceEvent,
    OperationEnding, ProviderExecutionResult, SemanticAuthority, SemanticResolution,
};
pub use settlement::{
    MAX_PROVIDER_SUCCESSOR_TOMBSTONES, TeardownRegistrationResult, TerminalSettlementCoordinator,
};
pub use terminal_commit::{TerminalCommitBeginResult, TerminalCommitReceipt, TerminalCommitState};
pub use tracker::{BeginAttempt, LifecycleTracker};
pub use types::{
    BindingIdentity, EpochTransitionKind, FailureReason, LifecycleStage, LivenessSignalKind,
    LivenessSnapshot, Ownership, ProgressAcceptance, ProgressRejection, ProgressSignal,
    RetryIntent, TerminalOutcome, TerminalOutcomeKind, TerminalPublicationResult,
    TerminationSignal, TurnEpoch,
};
pub use uuid::{RunUuid, RunUuidParseError};
