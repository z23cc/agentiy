//! Versioned Agentry payload contract ownership.

#![forbid(unsafe_code)]

mod envelope;
mod error;

pub use envelope::{
    DEFAULT_MAXIMUM_COLLECTION_ITEMS, DEFAULT_MAXIMUM_STRING_BYTES, DecodeLimits, Envelope,
    HEADER_BYTES, MAGIC, MAXIMUM_ENVELOPE_BYTES, MAXIMUM_PAYLOAD_BYTES, PayloadKind,
};
pub use error::DecodeError;

/// Frozen Phase 0 envelope schema version.
pub const ENVELOPE_SCHEMA_VERSION: u16 = 1;
