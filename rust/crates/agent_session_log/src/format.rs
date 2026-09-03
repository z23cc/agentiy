//! On-disk layout shared by `.log` and `.snapshot` files (design §7.2). FROZEN at end of P2.
//!
//! ```text
//! file header (24 bytes)
//!   0..4   magic          b"AGSL" (event log) or b"AGSS" (snapshot)
//!   4..6   schema_version u16 big-endian, currently 1
//!   6..8   flags          u16 big-endian, must be 0 (unknown bits fail closed)
//!   8..24  session_id     16 bytes, the session UUID
//! record (repeated in a log; exactly one in a snapshot)
//!   0..4   length         u32 big-endian byte length of `payload`
//!   4..8   crc32c         CRC-32C of `payload`
//!   8..    payload        encoded `AgentSessionEvent` (log) / `AgentSessionSnapshot` (snapshot)
//! ```
//!
//! Records are not self-delimiting beyond `length`, so a torn or corrupt record hides everything
//! after it; the log opener therefore truncates to the last valid record (see `SessionLog::open`).

use crate::crc32c::crc32c;
use crate::error::LogError;
use crate::session_id::SessionId;

/// Magic bytes of an event-log file.
pub const LOG_MAGIC: [u8; 4] = *b"AGSL";
/// Magic bytes of a snapshot file.
pub const SNAPSHOT_MAGIC: [u8; 4] = *b"AGSS";
/// Header and record schema version written by this crate.
pub const SCHEMA_VERSION: u16 = 1;
/// Fixed header length.
pub const HEADER_BYTES: usize = 24;
/// Fixed record-header length (`length || crc32c`).
pub const RECORD_HEADER_BYTES: usize = 8;
/// Largest record payload. Every record must also travel as one `EventNotification` inside one
/// 1 MiB wire frame, so the cap leaves 4 KiB of headroom for the notification's own fields.
pub const MAXIMUM_RECORD_PAYLOAD_BYTES: usize =
    agentry_proto::agent_host::MAXIMUM_FRAME_PAYLOAD_BYTES - 4096;
/// Largest snapshot payload (mirrors the codec cap).
pub const MAXIMUM_SNAPSHOT_PAYLOAD_BYTES: usize = agentry_proto::agent_host::MAXIMUM_SNAPSHOT_BYTES;

/// Extension of the canonical append-only log (`AgentSession-<UUID>.events`, design §7.2).
pub const EVENTS_FILE_EXTENSION: &str = "events";
/// Extension of the derived snapshot beside it (`AgentSession-<UUID>.snapshot`).
pub const SNAPSHOT_FILE_EXTENSION: &str = "snapshot";

/// `AgentSession-<UUID>.events`. The UUID is rendered uppercase so the file sorts beside the
/// existing Swift-written `AgentSession-<UUID>.json` (which uses `UUID.uuidString`).
#[must_use]
pub fn events_file_name(session_id: SessionId) -> String {
    format!(
        "AgentSession-{}.{EVENTS_FILE_EXTENSION}",
        session_id.to_string().to_uppercase()
    )
}

/// `AgentSession-<UUID>.snapshot`, the derived cache beside [`events_file_name`].
#[must_use]
pub fn snapshot_file_name(session_id: SessionId) -> String {
    format!(
        "AgentSession-{}.{SNAPSHOT_FILE_EXTENSION}",
        session_id.to_string().to_uppercase()
    )
}

/// Which file a header belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileKind {
    Log,
    Snapshot,
}

impl FileKind {
    #[must_use]
    pub const fn magic(self) -> [u8; 4] {
        match self {
            Self::Log => LOG_MAGIC,
            Self::Snapshot => SNAPSHOT_MAGIC,
        }
    }
}

/// Decoded file header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileHeader {
    pub kind: FileKind,
    pub schema_version: u16,
    pub flags: u16,
    pub session_id: SessionId,
}

impl FileHeader {
    #[must_use]
    pub const fn new(kind: FileKind, session_id: SessionId) -> Self {
        Self {
            kind,
            schema_version: SCHEMA_VERSION,
            flags: 0,
            session_id,
        }
    }

    #[must_use]
    pub fn encode(&self) -> [u8; HEADER_BYTES] {
        let mut bytes = [0u8; HEADER_BYTES];
        bytes[0..4].copy_from_slice(&self.kind.magic());
        bytes[4..6].copy_from_slice(&self.schema_version.to_be_bytes());
        bytes[6..8].copy_from_slice(&self.flags.to_be_bytes());
        bytes[8..24].copy_from_slice(self.session_id.as_bytes());
        bytes
    }

    /// Decodes and validates a header of the expected kind. Fails closed on a foreign magic, a
    /// schema version this crate does not implement (ADR-0006), unknown flags, or a session id
    /// other than `expected_session`.
    pub fn decode(
        bytes: &[u8],
        expected_kind: FileKind,
        expected_session: SessionId,
    ) -> Result<Self, LogError> {
        if bytes.len() < HEADER_BYTES {
            return Err(LogError::HeaderTooShort {
                actual: bytes.len(),
            });
        }
        let mut magic = [0u8; 4];
        magic.copy_from_slice(&bytes[0..4]);
        let kind = if magic == LOG_MAGIC {
            FileKind::Log
        } else if magic == SNAPSHOT_MAGIC {
            FileKind::Snapshot
        } else {
            return Err(LogError::InvalidMagic { found: magic });
        };
        if kind != expected_kind {
            return Err(LogError::WrongFileKind {
                expected: expected_kind,
                found: kind,
            });
        }
        let schema_version = u16::from_be_bytes([bytes[4], bytes[5]]);
        if schema_version != SCHEMA_VERSION {
            return Err(LogError::UnsupportedSchemaVersion {
                found: schema_version,
                supported: SCHEMA_VERSION,
            });
        }
        let flags = u16::from_be_bytes([bytes[6], bytes[7]]);
        if flags != 0 {
            return Err(LogError::UnsupportedFlags { found: flags });
        }
        let mut session = [0u8; 16];
        session.copy_from_slice(&bytes[8..24]);
        let session_id = SessionId::from_bytes(session);
        if session_id != expected_session {
            return Err(LogError::SessionMismatch {
                expected: expected_session,
                found: session_id,
            });
        }
        Ok(Self {
            kind,
            schema_version,
            flags,
            session_id,
        })
    }
}

/// Why a record could not be read at a given offset.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordDefect {
    /// Fewer than eight bytes remain: a torn record header.
    PartialHeader { available: usize },
    /// The declared length exceeds the cap; the bytes are not a record header.
    LengthOutOfRange { declared: usize, maximum: usize },
    /// The declared payload runs past the end of the data.
    PartialPayload { declared: usize, available: usize },
    /// The payload does not match its checksum.
    ChecksumMismatch { expected: u32, actual: u32 },
}

/// Frames one payload as `length || crc32c || payload`.
pub fn encode_record(payload: &[u8], maximum_payload: usize) -> Result<Vec<u8>, LogError> {
    if payload.len() > maximum_payload {
        return Err(LogError::RecordTooLarge {
            actual: payload.len(),
            maximum: maximum_payload,
        });
    }
    let length = u32::try_from(payload.len()).map_err(|_| LogError::RecordTooLarge {
        actual: payload.len(),
        maximum: maximum_payload,
    })?;
    let mut frame = Vec::with_capacity(RECORD_HEADER_BYTES + payload.len());
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(&crc32c(payload).to_be_bytes());
    frame.extend_from_slice(payload);
    Ok(frame)
}

/// Parses the record starting at `bytes[0]`, returning `(payload, consumed_bytes)`.
pub fn decode_record(bytes: &[u8], maximum_payload: usize) -> Result<(&[u8], usize), RecordDefect> {
    if bytes.len() < RECORD_HEADER_BYTES {
        return Err(RecordDefect::PartialHeader {
            available: bytes.len(),
        });
    }
    let declared = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize;
    if declared > maximum_payload {
        return Err(RecordDefect::LengthOutOfRange {
            declared,
            maximum: maximum_payload,
        });
    }
    let expected = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
    let body = &bytes[RECORD_HEADER_BYTES..];
    if body.len() < declared {
        return Err(RecordDefect::PartialPayload {
            declared,
            available: body.len(),
        });
    }
    let payload = &body[..declared];
    let actual = crc32c(payload);
    if actual != expected {
        return Err(RecordDefect::ChecksumMismatch { expected, actual });
    }
    Ok((payload, RECORD_HEADER_BYTES + declared))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> SessionId {
        SessionId::from_bytes([7u8; 16])
    }

    #[test]
    fn header_round_trips() {
        let header = FileHeader::new(FileKind::Log, session());
        let bytes = header.encode();
        assert_eq!(&bytes[0..4], b"AGSL");
        assert_eq!(bytes[4..6], [0, 1]);
        assert_eq!(
            FileHeader::decode(&bytes, FileKind::Log, session()).unwrap(),
            header
        );
    }

    #[test]
    fn header_fails_closed_on_newer_schema() {
        let mut bytes = FileHeader::new(FileKind::Log, session()).encode();
        bytes[5] = 2;
        assert_eq!(
            FileHeader::decode(&bytes, FileKind::Log, session()),
            Err(LogError::UnsupportedSchemaVersion {
                found: 2,
                supported: 1
            })
        );
    }

    #[test]
    fn header_rejects_flags_kind_and_session_mismatches() {
        let mut flagged = FileHeader::new(FileKind::Log, session()).encode();
        flagged[7] = 1;
        assert_eq!(
            FileHeader::decode(&flagged, FileKind::Log, session()),
            Err(LogError::UnsupportedFlags { found: 1 })
        );
        let snapshot = FileHeader::new(FileKind::Snapshot, session()).encode();
        assert_eq!(
            FileHeader::decode(&snapshot, FileKind::Log, session()),
            Err(LogError::WrongFileKind {
                expected: FileKind::Log,
                found: FileKind::Snapshot
            })
        );
        let other = SessionId::from_bytes([9u8; 16]);
        assert!(matches!(
            FileHeader::decode(&snapshot, FileKind::Snapshot, other),
            Err(LogError::SessionMismatch { .. })
        ));
        assert_eq!(
            FileHeader::decode(b"NOPE", FileKind::Log, session()),
            Err(LogError::HeaderTooShort { actual: 4 })
        );
        let mut foreign = FileHeader::new(FileKind::Log, session()).encode();
        foreign[0..4].copy_from_slice(b"AGRY");
        assert_eq!(
            FileHeader::decode(&foreign, FileKind::Log, session()),
            Err(LogError::InvalidMagic { found: *b"AGRY" })
        );
    }

    #[test]
    fn record_round_trips_and_detects_defects() {
        let frame = encode_record(b"payload", 64).unwrap();
        assert_eq!(frame.len(), RECORD_HEADER_BYTES + 7);
        assert_eq!(
            decode_record(&frame, 64).unwrap(),
            (&b"payload"[..], frame.len())
        );

        assert_eq!(
            decode_record(&frame[..5], 64),
            Err(RecordDefect::PartialHeader { available: 5 })
        );
        assert_eq!(
            decode_record(&frame[..10], 64),
            Err(RecordDefect::PartialPayload {
                declared: 7,
                available: 2
            })
        );
        let mut corrupt = frame.clone();
        corrupt[9] ^= 0xFF;
        assert!(matches!(
            decode_record(&corrupt, 64),
            Err(RecordDefect::ChecksumMismatch { .. })
        ));
        let mut oversize = frame;
        oversize[0..4].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(matches!(
            decode_record(&oversize, 64),
            Err(RecordDefect::LengthOutOfRange { maximum: 64, .. })
        ));
        assert!(matches!(
            encode_record(&[0u8; 65], 64),
            Err(LogError::RecordTooLarge {
                actual: 65,
                maximum: 64
            })
        ));
    }
}
