//! Synchronous, typed UniFFI boundary over the Agentry-owned runtime.

#![forbid(unsafe_code)]

mod agent_host_types;
mod agent_provider_semantics;
mod agent_run_lifecycle;
mod agent_run_lifecycle_types;
mod agent_session_host;
mod agent_session_transcript;
mod api;
mod errors;
mod panic_guard;
mod types;

#[cfg(test)]
mod measurement_harness;

mod generated {
    pub(crate) mod contract_identity;
}

pub use agent_host_types::*;
pub use agent_provider_semantics::*;
pub use agent_run_lifecycle::*;
pub use agent_run_lifecycle_types::*;
pub use agent_session_host::*;
pub use agent_session_transcript::*;
pub use api::{CoreRuntime, LeafCancellation};
pub use errors::CoreError;
pub use types::*;

pub const ABI_EPOCH: u32 = generated::contract_identity::ABI_EPOCH;

#[must_use]
pub const fn linked_contract_versions() -> (u32, u16, u16) {
    (
        ABI_EPOCH,
        agentry_proto::ENVELOPE_SCHEMA_VERSION,
        agentry_runtime::EXPECTED_ENVELOPE_SCHEMA_VERSION,
    )
}

uniffi::setup_scaffolding!("agentry_core");
