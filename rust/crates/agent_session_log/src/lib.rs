//! Agent Session Host event log (ADR-0011 decision 6; docs/spec/agent-session-host-v1-design.md
//! §7.2). The append-only `AgentSession-<UUID>.events` file is the canonical persistence of a
//! session; the `AgentSession-<UUID>.snapshot` beside it is a derived cache that is rebuilt by
//! replay whenever it is missing, corrupt, or stale.
//!
//! This crate is the only implementation of the format. Swift reaches it through the bounded
//! synchronous UniFFI exports in `agentry-ffi` (`AgentSessionLog.open` / `append` / `readFrom` /
//! `compact` / `close`). The record payloads are the `agentry-proto` agent-host-v1 messages, so
//! every log record is also a wire event and `delivery_cursor == record ordinal`.
//!
//! FROZEN at end of P2: the header and record layout in [`format`] change only with a
//! `SCHEMA_VERSION` bump, and an unknown version is refused (ADR-0006 fail-closed).

#![forbid(unsafe_code)]

mod crc32c;
mod error;
pub mod format;
mod log;
mod session_id;

pub use crc32c::crc32c;
pub use error::LogError;
pub use format::{
    EVENTS_FILE_EXTENSION, FileHeader, FileKind, HEADER_BYTES, LOG_MAGIC,
    MAXIMUM_RECORD_PAYLOAD_BYTES, MAXIMUM_SNAPSHOT_PAYLOAD_BYTES, RECORD_HEADER_BYTES,
    RecordDefect, SCHEMA_VERSION, SNAPSHOT_FILE_EXTENSION, SNAPSHOT_MAGIC, decode_record,
    encode_record, events_file_name, snapshot_file_name,
};
pub use log::{
    CompactReceipt, Durability, LogEntry, OpenOptions, OpenReport, ReadBatch, SessionLog,
    SnapshotLoad, TornTail, TornTailReason,
};
pub use session_id::SessionId;
