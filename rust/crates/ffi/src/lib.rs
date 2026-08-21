//! Synchronous, typed UniFFI boundary over the Agentry-owned runtime.

#![forbid(unsafe_code)]

mod api;
mod errors;
mod panic_guard;
mod types;

#[cfg(test)]
mod measurement_harness;

mod generated {
    pub(crate) mod contract_identity;
}

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
