//! Framing, size limits, and the command idempotency fingerprint for agent-host-v1
//! (design §5.2 framing + wire-field rules, §5.4 `operationID` + argument fingerprint).
//!
//! A frame is `u32 big-endian payload length || payload`; the payload is exactly one encoded
//! [`ClientMessage`] or [`HostMessage`]. Decoding is fail-closed: a prefix above the cap, a
//! truncated payload, trailing bytes, a malformed message, or an empty top-level `oneof` all reject
//! the frame. Only this crate (and the FFI exports over it) ever encode or decode these bytes.

use super::v1::{
    self, AgentSessionSnapshot, ClientMessage, CommandRequest, HostMessage, MutationKey,
};
use prost::Message;
use sha2::{Digest, Sha256};
use std::fmt;

/// Wire protocol version carried in `Hello`/`Welcome`. Bumped only for incompatible changes.
pub const PROTOCOL_VERSION: u32 = 1;
/// Bytes of the big-endian length prefix in front of every frame payload.
pub const FRAME_LENGTH_PREFIX_BYTES: usize = 4;
/// Largest payload a frame may carry (design §5.2: 1 MiB). Larger objects travel as artifacts or
/// snapshot chunks.
pub const MAXIMUM_FRAME_PAYLOAD_BYTES: usize = 1_048_576;
/// Largest complete frame (prefix + payload).
pub const MAXIMUM_FRAME_BYTES: usize = FRAME_LENGTH_PREFIX_BYTES + MAXIMUM_FRAME_PAYLOAD_BYTES;
/// Largest `SnapshotChunk.data` (design §5.5: 512 KiB).
pub const MAXIMUM_SNAPSHOT_CHUNK_BYTES: usize = 512 * 1024;
/// Largest encoded `AgentSessionSnapshot` accepted by the codec and the FFI (64 MiB). Hosts must
/// compact transcripts that would exceed it.
pub const MAXIMUM_SNAPSHOT_BYTES: usize = 64 * 1024 * 1024;

/// Fail-closed framing and codec failures.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FrameError {
    /// Fewer than four bytes were offered as a length prefix.
    PrefixTooShort { actual: usize },
    /// The prefix declares more than [`MAXIMUM_FRAME_PAYLOAD_BYTES`].
    PayloadTooLarge { declared: usize, maximum: usize },
    /// The buffer ends before the declared payload does.
    TruncatedPayload { declared: usize, actual: usize },
    /// Bytes follow the declared payload.
    TrailingBytes { extra: usize },
    /// The payload is not a valid encoding of the expected message.
    Malformed { detail: String },
    /// The top-level `oneof` is unset, or a required nested message is missing.
    EmptyBody,
    /// `SnapshotChunk.data` exceeds [`MAXIMUM_SNAPSHOT_CHUNK_BYTES`].
    SnapshotChunkTooLarge { actual: usize, maximum: usize },
    /// An encoded snapshot exceeds [`MAXIMUM_SNAPSHOT_BYTES`].
    SnapshotTooLarge { actual: usize, maximum: usize },
    /// A message would encode to more than the frame payload cap.
    EncodedTooLarge { actual: usize, maximum: usize },
}

impl fmt::Display for FrameError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PrefixTooShort { actual } => {
                write!(formatter, "frame prefix needs 4 bytes, got {actual}")
            }
            Self::PayloadTooLarge { declared, maximum } => write!(
                formatter,
                "frame payload of {declared} bytes exceeds the {maximum}-byte cap"
            ),
            Self::TruncatedPayload { declared, actual } => write!(
                formatter,
                "frame declares {declared} payload bytes but only {actual} are present"
            ),
            Self::TrailingBytes { extra } => {
                write!(formatter, "{extra} bytes follow the frame payload")
            }
            Self::Malformed { detail } => write!(formatter, "malformed message: {detail}"),
            Self::EmptyBody => write!(formatter, "message body is empty"),
            Self::SnapshotChunkTooLarge { actual, maximum } => write!(
                formatter,
                "snapshot chunk of {actual} bytes exceeds the {maximum}-byte cap"
            ),
            Self::SnapshotTooLarge { actual, maximum } => write!(
                formatter,
                "snapshot of {actual} bytes exceeds the {maximum}-byte cap"
            ),
            Self::EncodedTooLarge { actual, maximum } => write!(
                formatter,
                "encoded message of {actual} bytes exceeds the {maximum}-byte cap"
            ),
        }
    }
}

impl std::error::Error for FrameError {}

impl From<prost::DecodeError> for FrameError {
    fn from(value: prost::DecodeError) -> Self {
        Self::Malformed {
            detail: value.to_string(),
        }
    }
}

/// Parses a length prefix and enforces the payload cap. Streaming readers call this after reading
/// exactly four bytes so they never allocate for an oversized declaration.
pub fn frame_payload_length(prefix: &[u8]) -> Result<usize, FrameError> {
    if prefix.len() < FRAME_LENGTH_PREFIX_BYTES {
        return Err(FrameError::PrefixTooShort {
            actual: prefix.len(),
        });
    }
    let declared = u32::from_be_bytes([prefix[0], prefix[1], prefix[2], prefix[3]]) as usize;
    if declared > MAXIMUM_FRAME_PAYLOAD_BYTES {
        return Err(FrameError::PayloadTooLarge {
            declared,
            maximum: MAXIMUM_FRAME_PAYLOAD_BYTES,
        });
    }
    Ok(declared)
}

/// Encodes one message as a complete frame (prefix + payload).
pub fn encode_frame<M: Message>(message: &M) -> Result<Vec<u8>, FrameError> {
    let payload_length = message.encoded_len();
    if payload_length > MAXIMUM_FRAME_PAYLOAD_BYTES {
        return Err(FrameError::EncodedTooLarge {
            actual: payload_length,
            maximum: MAXIMUM_FRAME_PAYLOAD_BYTES,
        });
    }
    let declared = u32::try_from(payload_length).map_err(|_| FrameError::EncodedTooLarge {
        actual: payload_length,
        maximum: MAXIMUM_FRAME_PAYLOAD_BYTES,
    })?;
    let mut frame = Vec::with_capacity(FRAME_LENGTH_PREFIX_BYTES + payload_length);
    frame.extend_from_slice(&declared.to_be_bytes());
    message
        .encode(&mut frame)
        .map_err(|error| FrameError::Malformed {
            detail: error.to_string(),
        })?;
    Ok(frame)
}

/// Decodes exactly one complete frame (prefix + payload, nothing else).
pub fn decode_frame<M: Message + Default>(frame: &[u8]) -> Result<M, FrameError> {
    let declared = frame_payload_length(frame)?;
    let payload = &frame[FRAME_LENGTH_PREFIX_BYTES..];
    if payload.len() < declared {
        return Err(FrameError::TruncatedPayload {
            declared,
            actual: payload.len(),
        });
    }
    if payload.len() > declared {
        return Err(FrameError::TrailingBytes {
            extra: payload.len() - declared,
        });
    }
    Ok(M::decode(payload)?)
}

/// Encodes a client -> host frame after validating its shape.
pub fn encode_client_message(message: &ClientMessage) -> Result<Vec<u8>, FrameError> {
    validate_client_message(message)?;
    encode_frame(message)
}

/// Decodes a client -> host frame and validates its shape.
pub fn decode_client_message(frame: &[u8]) -> Result<ClientMessage, FrameError> {
    let message: ClientMessage = decode_frame(frame)?;
    validate_client_message(&message)?;
    Ok(message)
}

/// Encodes a host -> client frame after validating its shape.
pub fn encode_host_message(message: &HostMessage) -> Result<Vec<u8>, FrameError> {
    validate_host_message(message)?;
    encode_frame(message)
}

/// Decodes a host -> client frame and validates its shape.
pub fn decode_host_message(frame: &[u8]) -> Result<HostMessage, FrameError> {
    let message: HostMessage = decode_frame(frame)?;
    validate_host_message(&message)?;
    Ok(message)
}

/// Encodes a snapshot body (what `SnapshotChunk.data` bytes concatenate to and what the
/// `.snapshot` file stores) under the snapshot cap.
pub fn encode_snapshot(snapshot: &AgentSessionSnapshot) -> Result<Vec<u8>, FrameError> {
    let length = snapshot.encoded_len();
    if length > MAXIMUM_SNAPSHOT_BYTES {
        return Err(FrameError::SnapshotTooLarge {
            actual: length,
            maximum: MAXIMUM_SNAPSHOT_BYTES,
        });
    }
    Ok(snapshot.encode_to_vec())
}

/// Decodes a snapshot body under the snapshot cap.
pub fn decode_snapshot(bytes: &[u8]) -> Result<AgentSessionSnapshot, FrameError> {
    if bytes.len() > MAXIMUM_SNAPSHOT_BYTES {
        return Err(FrameError::SnapshotTooLarge {
            actual: bytes.len(),
            maximum: MAXIMUM_SNAPSHOT_BYTES,
        });
    }
    Ok(AgentSessionSnapshot::decode(bytes)?)
}

/// Returns the idempotency key of a mutating command; `None` for read-only commands
/// (`list_sessions`, `attach`, `detach`) and for an empty request.
#[must_use]
pub fn mutation_key(command: &CommandRequest) -> Option<&MutationKey> {
    use v1::command_request::Command;
    match command.command.as_ref()? {
        Command::Start(start) => start.key.as_ref(),
        Command::Steer(steer) => steer.key.as_ref(),
        Command::Interrupt(interrupt) => interrupt.key.as_ref(),
        Command::RespondInteraction(respond) => respond.key.as_ref(),
        Command::Stop(stop) => stop.key.as_ref(),
        Command::HostControl(control) => control.key.as_ref(),
        Command::ListSessions(_) | Command::Attach(_) | Command::Detach(_) => None,
    }
}

/// Computes `MutationKey.argument_fingerprint`: lowercase hex SHA-256 over the deterministic
/// encoding of the request with `request_id` and every `key` cleared, so two submissions of the
/// same arguments (from any client, any connection) fingerprint identically and a different
/// argument set under a reused `operation_id` is detectable as an `OperationConflict`.
#[must_use]
pub fn command_fingerprint(command: &CommandRequest) -> String {
    use v1::command_request::Command;
    let mut canonical = command.clone();
    canonical.request_id.clear();
    match canonical.command.as_mut() {
        Some(Command::Start(start)) => start.key = None,
        Some(Command::Steer(steer)) => steer.key = None,
        Some(Command::Interrupt(interrupt)) => interrupt.key = None,
        Some(Command::RespondInteraction(respond)) => respond.key = None,
        Some(Command::Stop(stop)) => stop.key = None,
        Some(Command::HostControl(control)) => control.key = None,
        Some(Command::ListSessions(_) | Command::Attach(_) | Command::Detach(_)) | None => {}
    }
    let digest = Sha256::digest(canonical.encode_to_vec());
    let mut output = String::with_capacity(64);
    for byte in digest {
        use std::fmt::Write;
        write!(&mut output, "{byte:02x}").expect("writing to String cannot fail");
    }
    output
}

fn validate_client_message(message: &ClientMessage) -> Result<(), FrameError> {
    use v1::client_message::Body;
    match message.body.as_ref().ok_or(FrameError::EmptyBody)? {
        Body::Hello(_) => Ok(()),
        Body::Command(request) => {
            if request.command.is_none() {
                return Err(FrameError::EmptyBody);
            }
            Ok(())
        }
    }
}

fn validate_host_message(message: &HostMessage) -> Result<(), FrameError> {
    use v1::host_message::Body;
    match message.body.as_ref().ok_or(FrameError::EmptyBody)? {
        Body::SnapshotChunk(chunk) if chunk.data.len() > MAXIMUM_SNAPSHOT_CHUNK_BYTES => {
            Err(FrameError::SnapshotChunkTooLarge {
                actual: chunk.data.len(),
                maximum: MAXIMUM_SNAPSHOT_CHUNK_BYTES,
            })
        }
        Body::Response(response) if response.outcome.is_none() => Err(FrameError::EmptyBody),
        Body::Event(notification) if notification.event.is_none() => Err(FrameError::EmptyBody),
        Body::Welcome(_)
        | Body::HandshakeRejected(_)
        | Body::Response(_)
        | Body::Event(_)
        | Body::SnapshotBegin(_)
        | Body::SnapshotChunk(_)
        | Body::SnapshotEnd(_)
        | Body::ResnapshotRequired(_)
        | Body::Notice(_) => Ok(()),
    }
}
