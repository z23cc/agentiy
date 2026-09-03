//! agent-host-v1: the Agent Session Host wire protocol and event-log record schema
//! (docs/architecture/adr-0011-agent-session-host.md; docs/spec/agent-session-host-v1-design.md
//! §5, §7.2).
//!
//! `v1` is rendered from `schema/agent_host_v1.proto` by `cargo run -p xtask -- generate` and is
//! committed; `codec` owns framing, size limits, and the command idempotency fingerprint. Both are
//! frozen at the end of P2: incompatible changes need a `PROTOCOL_VERSION` bump.

/// Generated prost types for package `agentry.agent_host.v1`.
#[allow(clippy::all, clippy::pedantic, missing_docs)]
#[rustfmt::skip]
#[path = "../generated/agent_host_v1.rs"]
pub mod v1;

pub mod codec;

pub use codec::{
    FRAME_LENGTH_PREFIX_BYTES, FrameError, MAXIMUM_FRAME_BYTES, MAXIMUM_FRAME_PAYLOAD_BYTES,
    MAXIMUM_SNAPSHOT_BYTES, MAXIMUM_SNAPSHOT_CHUNK_BYTES, PROTOCOL_VERSION, command_fingerprint,
    decode_client_message, decode_frame, decode_host_message, decode_snapshot,
    encode_client_message, encode_frame, encode_host_message, encode_snapshot,
    frame_payload_length, mutation_key,
};
