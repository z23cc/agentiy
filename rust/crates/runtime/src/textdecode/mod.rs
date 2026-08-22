//! `textdecode` — TD-2 of the APPROVED textdecode-policy-v2 design
//! (`docs/designs/textdecode-policy-v2-2026-08-22.md`): the hybrid strict-UTF-8-fast-path +
//! `chardetng`-fallback decoder that closes the ADR-0004 "Rust is the sole decoder" gap (§1.1).
//!
//! **Scope note (design §11 TD-2):** cargo-only in this phase. No FFI wiring lives here — that is
//! TD-3's (`rust/crates/ffi` + the Swift mirror). This module is exercised directly by its own
//! `cargo test` fixture corpus (`tests.rs`) against raw bytes; it is not yet reachable from any
//! UniFFI-generated binding, and no Swift or Rust code outside this module and the workspace
//! manifests is touched by this phase.

mod contract;
mod decode;
#[cfg(test)]
mod tests;

pub use contract::{
    BomDisposition, DetectedEncoding, Endian, TextDecodeOutcome, TextDecodePolicyVersion,
};
pub use decode::textdecode;
