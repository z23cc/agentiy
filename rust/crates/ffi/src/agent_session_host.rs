//! ADR-0011 P2 (design §11 rows 3-4, "编解码归属"): the bounded synchronous UniFFI surface over
//! the agent-host-v1 codec (`agentry_proto::agent_host`) and the session event log
//! (`agentry_agent_session_log`).
//!
//! Swift never parses protobuf or log bytes. Frames and records cross this boundary as the typed
//! `AgentHost…V1` mirrors in `agent_host_types`; the only byte payloads are complete wire frames,
//! snapshot bodies, and the 4-byte length prefix. Every call is bounded by the codec and log caps
//! (1 MiB frame, 512 KiB snapshot chunk, 64 MiB snapshot, `max_records`/`max_bytes` on reads) and
//! returns synchronously (ADR-0001: no async exports, no callbacks). UniFFI is an in-process bridge
//! only; the frames it returns are the project-owned wire format (charter §14.2).
//!
//! Neither object takes a `RuntimeIdentity`: the codec is a pure function of bytes and the log is a
//! file handle, so there is no runtime authority to fence. Build-identity checking for the host
//! protocol happens in the handshake itself (`Hello`/`Welcome.build_fingerprint`).

use crate::agent_host_types::{
    AgentHostAgentSessionEventV1, AgentHostAgentSessionSnapshotV1, AgentHostClientMessageV1,
    AgentHostCommandRequestV1, AgentHostHostMessageV1, AgentHostMutationKeyV1,
};
use crate::errors::CoreError;
use crate::panic_guard::PanicGuard;
use agentry_agent_session_log::{
    Durability, LogError, OpenOptions, OpenReport, SessionId, SessionLog, SnapshotLoad, TornTail,
    TornTailReason,
};
use agentry_proto::agent_host::{self as codec, FrameError, v1};
use agentry_runtime as runtime;
use std::sync::{Arc, Mutex};

/// Frozen framing and log limits of agent-host-v1 (design §5.2, §7.2). A record because UniFFI
/// exports no constants; clients read these instead of hard-coding them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AgentHostProtocolLimitsV1 {
    /// `PROTOCOL_VERSION` carried in `Hello`/`Welcome`.
    pub protocol_version: u32,
    /// Bytes of the big-endian length prefix in front of every frame (4).
    pub frame_length_prefix_bytes: u32,
    /// Largest frame payload (1 MiB).
    pub maximum_frame_payload_bytes: u32,
    /// Largest complete frame, prefix included.
    pub maximum_frame_bytes: u32,
    /// Largest `SnapshotChunk.data` (512 KiB).
    pub maximum_snapshot_chunk_bytes: u32,
    /// Largest encoded `AgentSessionSnapshot` (64 MiB).
    pub maximum_snapshot_bytes: u64,
    /// Largest encoded `AgentSessionEvent` the log accepts as one record.
    pub maximum_log_record_payload_bytes: u32,
    /// `.events`/`.snapshot` header schema version written by this build.
    pub log_schema_version: u16,
}

/// Canonical file names of one session's log and snapshot inside `AgentSessions/` (design §7.2).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AgentSessionLogFileNamesV1 {
    /// `AgentSession-<UUID>.events`, the canonical append-only log.
    pub events: String,
    /// `AgentSession-<UUID>.snapshot`, the derived cache beside it.
    pub snapshot: String,
}

/// Stateless agent-host-v1 codec. Cheap to construct; one per process is plenty.
#[derive(uniffi::Object)]
pub struct AgentHostProtocolV1 {
    guard: PanicGuard,
}

impl Default for AgentHostProtocolV1 {
    fn default() -> Self {
        Self {
            guard: PanicGuard::new(),
        }
    }
}

#[uniffi::export]
impl AgentHostProtocolV1 {
    #[uniffi::constructor]
    #[must_use]
    pub fn new() -> Arc<Self> {
        runtime::install_panic_hook();
        Arc::new(Self::default())
    }

    /// The frozen v1 limits.
    pub fn limits(&self) -> Result<AgentHostProtocolLimitsV1, CoreError> {
        self.guard.call(|| Ok(protocol_limits()))
    }

    /// Canonical file names for `session_id` (any-case RFC 4122 text). The UUID is rendered
    /// uppercase to sit beside the existing `AgentSession-<UUID>.json` files.
    pub fn session_log_file_names(
        &self,
        session_id: String,
    ) -> Result<AgentSessionLogFileNamesV1, CoreError> {
        self.guard.call(|| {
            let parsed = SessionId::parse(&session_id).map_err(CoreError::from)?;
            Ok(AgentSessionLogFileNamesV1 {
                events: agentry_agent_session_log::events_file_name(parsed),
                snapshot: agentry_agent_session_log::snapshot_file_name(parsed),
            })
        })
    }

    /// Parses the 4-byte length prefix a streaming reader has just read and enforces the payload
    /// cap, so the reader never allocates for an oversized declaration.
    pub fn frame_payload_length(&self, prefix: Vec<u8>) -> Result<u32, CoreError> {
        self.guard.call(|| {
            let length = codec::frame_payload_length(&prefix)?;
            u32::try_from(length).map_err(|_| CoreError::AgentHostFrameTooLarge {
                actual: length as u64,
                maximum: codec::MAXIMUM_FRAME_PAYLOAD_BYTES as u64,
            })
        })
    }

    /// Encodes one client -> host message as a complete frame (prefix + payload).
    pub fn encode_client_message(
        &self,
        message: AgentHostClientMessageV1,
    ) -> Result<Vec<u8>, CoreError> {
        self.guard.call(|| {
            Ok(codec::encode_client_message(&v1::ClientMessage::from(
                message,
            ))?)
        })
    }

    /// Decodes exactly one complete client -> host frame.
    pub fn decode_client_message(
        &self,
        frame: Vec<u8>,
    ) -> Result<AgentHostClientMessageV1, CoreError> {
        self.guard
            .call(|| codec::decode_client_message(&frame)?.try_into())
    }

    /// Encodes one host -> client message as a complete frame (prefix + payload).
    pub fn encode_host_message(
        &self,
        message: AgentHostHostMessageV1,
    ) -> Result<Vec<u8>, CoreError> {
        self.guard
            .call(|| Ok(codec::encode_host_message(&v1::HostMessage::from(message))?))
    }

    /// Decodes exactly one complete host -> client frame.
    pub fn decode_host_message(&self, frame: Vec<u8>) -> Result<AgentHostHostMessageV1, CoreError> {
        self.guard
            .call(|| codec::decode_host_message(&frame)?.try_into())
    }

    /// Encodes a snapshot body: what `SnapshotChunk.data` chunks concatenate to.
    pub fn encode_snapshot(
        &self,
        snapshot: AgentHostAgentSessionSnapshotV1,
    ) -> Result<Vec<u8>, CoreError> {
        self.guard.call(|| {
            Ok(codec::encode_snapshot(&v1::AgentSessionSnapshot::from(
                snapshot,
            ))?)
        })
    }

    /// Decodes a reassembled snapshot body.
    pub fn decode_snapshot(
        &self,
        bytes: Vec<u8>,
    ) -> Result<AgentHostAgentSessionSnapshotV1, CoreError> {
        self.guard
            .call(|| codec::decode_snapshot(&bytes)?.try_into())
    }

    /// `MutationKey.argument_fingerprint` for a command (design §5.4): SHA-256 over the request
    /// with `request_id` and `key` cleared, so equal arguments fingerprint identically everywhere.
    pub fn command_fingerprint(
        &self,
        command: AgentHostCommandRequestV1,
    ) -> Result<String, CoreError> {
        self.guard.call(|| {
            Ok(codec::command_fingerprint(&v1::CommandRequest::from(
                command,
            )))
        })
    }

    /// The idempotency key of a mutating command; `None` for read-only commands.
    pub fn mutation_key(
        &self,
        command: AgentHostCommandRequestV1,
    ) -> Result<Option<AgentHostMutationKeyV1>, CoreError> {
        self.guard.call(|| {
            let request = v1::CommandRequest::from(command);
            codec::mutation_key(&request)
                .cloned()
                .map(TryInto::try_into)
                .transpose()
        })
    }
}

fn protocol_limits() -> AgentHostProtocolLimitsV1 {
    AgentHostProtocolLimitsV1 {
        protocol_version: codec::PROTOCOL_VERSION,
        frame_length_prefix_bytes: codec::FRAME_LENGTH_PREFIX_BYTES as u32,
        maximum_frame_payload_bytes: codec::MAXIMUM_FRAME_PAYLOAD_BYTES as u32,
        maximum_frame_bytes: codec::MAXIMUM_FRAME_BYTES as u32,
        maximum_snapshot_chunk_bytes: codec::MAXIMUM_SNAPSHOT_CHUNK_BYTES as u32,
        maximum_snapshot_bytes: codec::MAXIMUM_SNAPSHOT_BYTES as u64,
        maximum_log_record_payload_bytes: agentry_agent_session_log::MAXIMUM_RECORD_PAYLOAD_BYTES
            as u32,
        log_schema_version: agentry_agent_session_log::SCHEMA_VERSION,
    }
}

/// When `append` must reach stable storage (design §7.2 write path).
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum AgentSessionLogDurabilityV1 {
    /// `fdatasync` before returning.
    Sync,
    /// Write only; the caller syncs at the next turn boundary via `sync`, `compact`, or `close`.
    Deferred,
}

/// `AgentSessionLog.open` options.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AgentSessionLogOpenOptionsV1 {
    /// Create the file (and write the header) when it does not exist.
    pub create_if_missing: bool,
    /// Also load the latest valid `.snapshot` into the open report.
    pub load_snapshot: bool,
}

/// Why bytes at the end of the log were discarded at open.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum AgentSessionLogTornTailReasonV1 {
    PartialHeader,
    PartialPayload,
    ChecksumMismatch,
    LengthOutOfRange,
    /// The file was shorter than a header; it was rewritten as an empty log.
    PartialFileHeader,
}

/// Bytes discarded at open because they were not a complete, CRC-valid record. Reported to the
/// user as the lost range (design §7.2 read path); never repaired from a snapshot.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AgentSessionLogTornTailV1 {
    /// Cursor the first lost record would have had (equals `next_cursor` after open).
    pub first_lost_cursor: u64,
    /// File offset the log was truncated to.
    pub truncated_at: u64,
    pub lost_bytes: u64,
    pub reason: AgentSessionLogTornTailReasonV1,
}

/// Outcome of loading the derived `.snapshot`.
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum AgentSessionLogSnapshotLoadV1 {
    /// A valid snapshot for this session; replay from `snapshot.through_cursor + 1`.
    Loaded {
        snapshot: AgentHostAgentSessionSnapshotV1,
    },
    /// No snapshot file; replay from cursor 1.
    Missing,
    /// The snapshot exists but is unusable; it is ignored (never used to repair the log) and the
    /// caller replays from cursor 1. The next `compact` overwrites it.
    Corrupt { reason: String },
    /// `open` was asked not to load it.
    NotRequested,
}

/// What `AgentSessionLog.open` learned about the file.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentSessionLogOpenReportV1 {
    /// True when the file did not exist and was created.
    pub created: bool,
    /// Cursor the next appended record receives (`last_cursor + 1`).
    pub next_cursor: u64,
    pub torn_tail: Option<AgentSessionLogTornTailV1>,
    pub snapshot: AgentSessionLogSnapshotLoadV1,
    /// First cursor to replay after applying `snapshot` (1 when none applies).
    pub replay_from: u64,
}

/// One decoded record.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentSessionLogEntryV1 {
    /// 1-based record ordinal; equals the event's `delivery_cursor`.
    pub cursor: u64,
    pub event: AgentHostAgentSessionEventV1,
}

/// A bounded `read_from` result.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct AgentSessionLogReadBatchV1 {
    pub entries: Vec<AgentSessionLogEntryV1>,
    /// Cursor to pass to the next `read_from`.
    pub next_cursor: u64,
    /// True when `next_cursor` is the log's own next cursor (nothing more to read right now).
    pub end_of_log: bool,
}

/// Receipt of a written snapshot.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AgentSessionLogCompactReceiptV1 {
    pub through_cursor: u64,
    pub snapshot_payload_bytes: u64,
    pub snapshot_path: String,
}

/// Current state of an open log handle.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct AgentSessionLogStatusV1 {
    pub path: String,
    pub snapshot_path: String,
    /// Canonical lowercase RFC 4122 text.
    pub session_id: String,
    pub next_cursor: u64,
    /// Bytes on disk (header + records) as of the last append.
    pub byte_length: u64,
}

/// An open session event log (design §7.2). Single writer per file: the host holds it; clients
/// read through the host, never through their own handle. Drop without `close` still syncs
/// deferred appends on a best-effort basis, but only `close` reports the outcome.
#[derive(uniffi::Object)]
pub struct AgentSessionLog {
    guard: PanicGuard,
    inner: Mutex<Option<SessionLog>>,
    report: AgentSessionLogOpenReportV1,
}

#[uniffi::export]
impl AgentSessionLog {
    /// Opens (or creates) the log at `path` for `session_id`, validates the header, scans every
    /// record, truncates a torn tail, and loads the snapshot when asked. Fails closed on a newer
    /// schema version (`AgentSessionLogUnsupportedSchemaVersion`, ADR-0006).
    #[uniffi::constructor]
    pub fn open(
        path: String,
        session_id: String,
        options: AgentSessionLogOpenOptionsV1,
    ) -> Result<Arc<Self>, CoreError> {
        runtime::install_panic_hook();
        let guard = PanicGuard::new();
        let (log, report) = guard.call(|| {
            let session = SessionId::parse(&session_id)?;
            let (log, report) = SessionLog::open(
                &path,
                session,
                OpenOptions {
                    create_if_missing: options.create_if_missing,
                    load_snapshot: options.load_snapshot,
                },
            )?;
            let report = open_report(report)?;
            Ok((log, report))
        })?;
        Ok(Arc::new(Self {
            guard,
            inner: Mutex::new(Some(log)),
            report,
        }))
    }

    /// The report produced by `open`.
    pub fn open_report(&self) -> Result<AgentSessionLogOpenReportV1, CoreError> {
        self.guard.call(|| Ok(self.report.clone()))
    }

    /// Path, session, and cursor state of the handle.
    pub fn status(&self) -> Result<AgentSessionLogStatusV1, CoreError> {
        self.guard.call(|| {
            self.with_log(|log| {
                Ok(AgentSessionLogStatusV1 {
                    path: log.path().display().to_string(),
                    snapshot_path: log.snapshot_path().display().to_string(),
                    session_id: log.session_id().to_string(),
                    next_cursor: log.next_cursor(),
                    byte_length: log.byte_length(),
                })
            })
        })
    }

    /// Appends one event and returns its cursor (`delivery_cursor`).
    pub fn append(
        &self,
        event: AgentHostAgentSessionEventV1,
        durability: AgentSessionLogDurabilityV1,
    ) -> Result<u64, CoreError> {
        self.guard.call(|| {
            let event = v1::AgentSessionEvent::from(event);
            let durability = match durability {
                AgentSessionLogDurabilityV1::Sync => Durability::Sync,
                AgentSessionLogDurabilityV1::Deferred => Durability::Deferred,
            };
            self.with_log(|log| Ok(log.append(&event, durability)?))
        })
    }

    /// `fdatasync` of every deferred append (turn boundary).
    pub fn sync(&self) -> Result<(), CoreError> {
        self.guard.call(|| self.with_log(|log| Ok(log.sync()?)))
    }

    /// Reads records from `cursor` (1-based), at most `max_records` entries whose encoded payloads
    /// total at most `max_bytes` (always at least one when any remain). `cursor == next_cursor`
    /// returns an empty batch with `end_of_log == true`.
    pub fn read_from(
        &self,
        cursor: u64,
        max_records: u32,
        max_bytes: u32,
    ) -> Result<AgentSessionLogReadBatchV1, CoreError> {
        self.guard.call(|| {
            if max_records == 0 || max_bytes == 0 {
                return Err(CoreError::InvalidArgument);
            }
            self.with_log(|log| {
                let batch = log.read_from(cursor, max_records as usize, max_bytes as usize)?;
                let entries = batch
                    .entries
                    .into_iter()
                    .map(|entry| {
                        Ok(AgentSessionLogEntryV1 {
                            cursor: entry.cursor,
                            event: entry.event.try_into()?,
                        })
                    })
                    .collect::<Result<Vec<_>, CoreError>>()?;
                Ok(AgentSessionLogReadBatchV1 {
                    entries,
                    next_cursor: batch.next_cursor,
                    end_of_log: batch.end_of_log,
                })
            })
        })
    }

    /// Writes `snapshot` to the `.snapshot` beside the log by atomic replace, after syncing the
    /// log so the snapshot never claims a cursor that is not durable. Never rewrites the log.
    pub fn compact(
        &self,
        snapshot: AgentHostAgentSessionSnapshotV1,
    ) -> Result<AgentSessionLogCompactReceiptV1, CoreError> {
        self.guard.call(|| {
            let snapshot = v1::AgentSessionSnapshot::from(snapshot);
            self.with_log(|log| {
                let receipt = log.compact(&snapshot)?;
                Ok(AgentSessionLogCompactReceiptV1 {
                    through_cursor: receipt.through_cursor,
                    snapshot_payload_bytes: receipt.snapshot_payload_bytes,
                    snapshot_path: receipt.snapshot_path.display().to_string(),
                })
            })
        })
    }

    /// Re-reads the `.snapshot` beside the log (for example after another compaction).
    pub fn load_snapshot(&self) -> Result<AgentSessionLogSnapshotLoadV1, CoreError> {
        self.guard
            .call(|| self.with_log(|log| snapshot_load(log.load_snapshot()?)))
    }

    /// Syncs deferred appends and releases the file. Every later call fails with
    /// `AgentSessionLogClosed`.
    pub fn close(&self) -> Result<(), CoreError> {
        self.guard.call(|| {
            let log = self
                .inner
                .lock()
                .map_err(|_| CoreError::AgentSessionLogClosed)?
                .take()
                .ok_or(CoreError::AgentSessionLogClosed)?;
            Ok(log.close()?)
        })
    }
}

impl AgentSessionLog {
    fn with_log<T>(
        &self,
        operation: impl FnOnce(&mut SessionLog) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        let mut slot = self
            .inner
            .lock()
            .map_err(|_| CoreError::AgentSessionLogClosed)?;
        let log = slot.as_mut().ok_or(CoreError::AgentSessionLogClosed)?;
        operation(log)
    }
}

impl Drop for AgentSessionLog {
    fn drop(&mut self) {
        if let Ok(mut slot) = self.inner.lock()
            && let Some(log) = slot.take()
        {
            // Best effort: a caller that wants the outcome calls `close` first.
            let _ = log.close();
        }
    }
}

fn open_report(report: OpenReport) -> Result<AgentSessionLogOpenReportV1, CoreError> {
    let replay_from = report.snapshot.replay_from();
    Ok(AgentSessionLogOpenReportV1 {
        created: report.created,
        next_cursor: report.next_cursor,
        torn_tail: report.torn_tail.map(torn_tail),
        snapshot: snapshot_load(report.snapshot)?,
        replay_from,
    })
}

fn torn_tail(tail: TornTail) -> AgentSessionLogTornTailV1 {
    AgentSessionLogTornTailV1 {
        first_lost_cursor: tail.first_lost_cursor,
        truncated_at: tail.truncated_at,
        lost_bytes: tail.lost_bytes,
        reason: match tail.reason {
            TornTailReason::PartialHeader => AgentSessionLogTornTailReasonV1::PartialHeader,
            TornTailReason::PartialPayload => AgentSessionLogTornTailReasonV1::PartialPayload,
            TornTailReason::ChecksumMismatch => AgentSessionLogTornTailReasonV1::ChecksumMismatch,
            TornTailReason::LengthOutOfRange => AgentSessionLogTornTailReasonV1::LengthOutOfRange,
            TornTailReason::PartialFileHeader => AgentSessionLogTornTailReasonV1::PartialFileHeader,
        },
    }
}

fn snapshot_load(load: SnapshotLoad) -> Result<AgentSessionLogSnapshotLoadV1, CoreError> {
    Ok(match load {
        SnapshotLoad::Loaded(snapshot) => AgentSessionLogSnapshotLoadV1::Loaded {
            snapshot: snapshot.try_into()?,
        },
        SnapshotLoad::Missing => AgentSessionLogSnapshotLoadV1::Missing,
        SnapshotLoad::Corrupt { reason } => AgentSessionLogSnapshotLoadV1::Corrupt { reason },
        SnapshotLoad::NotRequested => AgentSessionLogSnapshotLoadV1::NotRequested,
    })
}

impl From<FrameError> for CoreError {
    fn from(value: FrameError) -> Self {
        match value {
            FrameError::PayloadTooLarge { declared, maximum } => Self::AgentHostFrameTooLarge {
                actual: declared as u64,
                maximum: maximum as u64,
            },
            FrameError::SnapshotChunkTooLarge { actual, maximum }
            | FrameError::SnapshotTooLarge { actual, maximum }
            | FrameError::EncodedTooLarge { actual, maximum } => Self::AgentHostFrameTooLarge {
                actual: actual as u64,
                maximum: maximum as u64,
            },
            FrameError::PrefixTooShort { .. }
            | FrameError::TruncatedPayload { .. }
            | FrameError::TrailingBytes { .. }
            | FrameError::Malformed { .. }
            | FrameError::EmptyBody => Self::AgentHostFrameMalformed {
                message: value.to_string(),
            },
        }
    }
}

impl From<LogError> for CoreError {
    fn from(value: LogError) -> Self {
        match value {
            LogError::Io { operation, source } => Self::AgentSessionLogIo {
                operation: operation.to_owned(),
                message: source.to_string(),
            },
            LogError::UnsupportedSchemaVersion { found, supported } => {
                Self::AgentSessionLogUnsupportedSchemaVersion { found, supported }
            }
            LogError::SessionMismatch { expected, found } => Self::AgentSessionLogSessionMismatch {
                expected: expected.to_string(),
                found: found.to_string(),
            },
            LogError::InvalidSessionId { value } => Self::AgentSessionLogInvalidSessionId { value },
            LogError::NotFound { path } => Self::AgentSessionLogNotFound { path },
            LogError::RecordTooLarge { actual, maximum } => Self::AgentSessionLogRecordTooLarge {
                actual: actual as u64,
                maximum: maximum as u64,
            },
            LogError::CursorOutOfRange {
                cursor,
                next_cursor,
            } => Self::AgentSessionLogCursorOutOfRange {
                cursor,
                next_cursor,
            },
            LogError::Malformed { cursor, detail } => Self::AgentSessionLogMalformedRecord {
                cursor,
                message: detail,
            },
            LogError::Codec(error) => error.into(),
            LogError::Closed => Self::AgentSessionLogClosed,
            LogError::InvalidMagic { .. }
            | LogError::WrongFileKind { .. }
            | LogError::UnsupportedFlags { .. }
            | LogError::HeaderTooShort { .. } => Self::AgentSessionLogInvalidFile {
                message: value.to_string(),
            },
            LogError::SnapshotAheadOfLog { .. } | LogError::SnapshotSessionMismatch { .. } => {
                Self::AgentSessionLogSnapshotRejected {
                    message: value.to_string(),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_host_types::{
        AgentHostAgentSessionEventBodyV1, AgentHostAttachV1, AgentHostCapabilityV1,
        AgentHostClientKindV1, AgentHostClientMessageBodyV1, AgentHostCommandRequestCommandV1,
        AgentHostExecutableIdentityV1, AgentHostHelloV1, AgentHostSessionSpecV1, AgentHostStartV1,
        AgentHostUserMessageV1,
    };
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_SCRATCH: AtomicU64 = AtomicU64::new(1);

    fn scratch_dir() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "agentry-ffi-session-log-{}-{}",
            std::process::id(),
            NEXT_SCRATCH.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    fn hello() -> AgentHostClientMessageV1 {
        AgentHostClientMessageV1 {
            body: Some(AgentHostClientMessageBodyV1::Hello(AgentHostHelloV1 {
                protocol_version: 1,
                build_fingerprint: "fp".to_owned(),
                executable: Some(AgentHostExecutableIdentityV1 {
                    bundle_identifier: "com.agentry".to_owned(),
                    executable_name: "agentry-mcp".to_owned(),
                    version: String::new(),
                    build_number: String::new(),
                    pid: 42,
                    code_signing_team_identifier: String::new(),
                }),
                capabilities: vec![
                    AgentHostCapabilityV1::CanPresent,
                    AgentHostCapabilityV1::SnapshotStreaming,
                ],
                client_id: "client-id".to_owned(),
                client_kind: AgentHostClientKindV1::Gui,
            })),
        }
    }

    fn user_event(text: &str) -> AgentHostAgentSessionEventV1 {
        AgentHostAgentSessionEventV1 {
            recorded_at: "2026-09-03T00:00:00Z".to_owned(),
            body: Some(AgentHostAgentSessionEventBodyV1::UserMessage(
                AgentHostUserMessageV1 {
                    message_id: "m".to_owned(),
                    text: text.to_owned(),
                    attachments: vec![],
                    created_at: String::new(),
                },
            )),
        }
    }

    #[test]
    fn typed_frames_round_trip_through_the_codec_object() {
        let protocol = AgentHostProtocolV1::new();
        let frame = protocol.encode_client_message(hello()).unwrap();
        assert_eq!(
            protocol.frame_payload_length(frame[..4].to_vec()).unwrap() as usize,
            frame.len() - 4
        );
        assert_eq!(protocol.decode_client_message(frame).unwrap(), hello());
        let limits = protocol.limits().unwrap();
        assert_eq!(limits.protocol_version, 1);
        assert_eq!(limits.maximum_frame_payload_bytes, 1_048_576);
        assert_eq!(limits.maximum_snapshot_chunk_bytes, 512 * 1024);
        assert_eq!(limits.log_schema_version, 1);
    }

    #[test]
    fn codec_failures_map_to_explicit_errors() {
        let protocol = AgentHostProtocolV1::new();
        assert!(matches!(
            protocol.decode_client_message(vec![0, 0, 0, 5, 1]),
            Err(CoreError::AgentHostFrameMalformed { .. })
        ));
        assert!(matches!(
            protocol.frame_payload_length(vec![0xFF, 0xFF, 0xFF, 0xFF]),
            Err(CoreError::AgentHostFrameTooLarge { .. })
        ));
        assert!(matches!(
            protocol.encode_client_message(AgentHostClientMessageV1 { body: None }),
            Err(CoreError::AgentHostFrameMalformed { .. })
        ));
        // An enum value this build does not know is refused, not aliased to Unspecified.
        let mut raw = v1::Hello::default();
        raw.client_kind = 99;
        let frame = codec::encode_frame(&v1::ClientMessage {
            body: Some(v1::client_message::Body::Hello(raw)),
        })
        .unwrap();
        assert!(matches!(
            protocol.decode_client_message(frame),
            Err(CoreError::AgentHostFrameMalformed { message }) if message.contains("ClientKind")
        ));
    }

    #[test]
    fn mutation_key_and_fingerprint_follow_the_codec() {
        let protocol = AgentHostProtocolV1::new();
        let start = AgentHostCommandRequestV1 {
            request_id: "r".to_owned(),
            command: Some(AgentHostCommandRequestCommandV1::Start(AgentHostStartV1 {
                key: Some(AgentHostMutationKeyV1 {
                    operation_id: "op".to_owned(),
                    argument_fingerprint: String::new(),
                }),
                spec: Some(AgentHostSessionSpecV1 {
                    session_id: "s".to_owned(),
                    workspace_id: "w".to_owned(),
                    worktree_id: String::new(),
                    session_name: String::new(),
                    provider_id: String::new(),
                    agent_id: String::new(),
                    agent_display_name: String::new(),
                    model_id: String::new(),
                    reasoning_effort: String::new(),
                    parent_session_id: String::new(),
                    parent_fork_cursor: 0,
                    initial_message: None,
                    permission_policy: None,
                    credential_envelope_id: String::new(),
                    resume_provider_session_id: String::new(),
                }),
            })),
        };
        let key = protocol.mutation_key(start.clone()).unwrap().unwrap();
        assert_eq!(key.operation_id, "op");
        let fingerprint = protocol.command_fingerprint(start).unwrap();
        assert_eq!(fingerprint.len(), 64);
        let attach = AgentHostCommandRequestV1 {
            request_id: "r".to_owned(),
            command: Some(AgentHostCommandRequestCommandV1::Attach(
                AgentHostAttachV1 {
                    session_id: "s".to_owned(),
                    resume_cursor: None,
                    resume_generation: vec![],
                },
            )),
        };
        assert_eq!(protocol.mutation_key(attach).unwrap(), None);
    }

    #[test]
    fn session_log_object_round_trips_records_and_reports_closure() {
        let root = scratch_dir();
        let protocol = AgentHostProtocolV1::new();
        let names = protocol
            .session_log_file_names("0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081".to_owned())
            .unwrap();
        assert_eq!(
            names.events,
            "AgentSession-0193A4B2-7C3E-7F10-8A2B-9C4D5E6F7081.events"
        );
        assert_eq!(
            names.snapshot,
            "AgentSession-0193A4B2-7C3E-7F10-8A2B-9C4D5E6F7081.snapshot"
        );
        let path = root.join(&names.events).display().to_string();
        let options = AgentSessionLogOpenOptionsV1 {
            create_if_missing: true,
            load_snapshot: true,
        };
        let log = AgentSessionLog::open(
            path.clone(),
            "0193A4B2-7C3E-7F10-8A2B-9C4D5E6F7081".to_owned(),
            options,
        )
        .unwrap();
        let report = log.open_report().unwrap();
        assert!(report.created);
        assert_eq!(report.next_cursor, 1);
        assert_eq!(report.replay_from, 1);
        assert_eq!(report.snapshot, AgentSessionLogSnapshotLoadV1::Missing);

        assert_eq!(
            log.append(user_event("hello"), AgentSessionLogDurabilityV1::Deferred)
                .unwrap(),
            1
        );
        assert_eq!(
            log.append(user_event("world"), AgentSessionLogDurabilityV1::Sync)
                .unwrap(),
            2
        );
        let batch = log.read_from(1, 16, 1 << 20).unwrap();
        assert_eq!(batch.entries.len(), 2);
        assert_eq!(batch.entries[1].event, user_event("world"));
        assert!(batch.end_of_log);
        assert!(matches!(
            log.read_from(9, 1, 1),
            Err(CoreError::AgentSessionLogCursorOutOfRange {
                cursor: 9,
                next_cursor: 3
            })
        ));
        assert_eq!(log.read_from(1, 0, 1), Err(CoreError::InvalidArgument));

        let snapshot = AgentHostAgentSessionSnapshotV1 {
            session_id: "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081".to_owned(),
            generation: vec![],
            through_cursor: 2,
            summary: None,
            transcript: vec![],
            pending_interactions: vec![],
            unsettled_operations: vec![],
            written_at: String::new(),
        };
        let receipt = log.compact(snapshot.clone()).unwrap();
        assert_eq!(receipt.through_cursor, 2);
        assert_eq!(
            log.load_snapshot().unwrap(),
            AgentSessionLogSnapshotLoadV1::Loaded {
                snapshot: snapshot.clone()
            }
        );
        let status = log.status().unwrap();
        assert_eq!(status.next_cursor, 3);
        assert_eq!(status.session_id, "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081");
        log.close().unwrap();
        assert_eq!(log.close(), Err(CoreError::AgentSessionLogClosed));
        assert_eq!(log.sync(), Err(CoreError::AgentSessionLogClosed));

        let reopened = AgentSessionLog::open(
            path.clone(),
            "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081".to_owned(),
            options,
        )
        .unwrap();
        let report = reopened.open_report().unwrap();
        assert_eq!(report.next_cursor, 3);
        assert_eq!(report.replay_from, 3);
        assert_eq!(
            report.snapshot,
            AgentSessionLogSnapshotLoadV1::Loaded { snapshot }
        );

        assert!(matches!(
            AgentSessionLog::open(
                path,
                "11111111-2222-3333-4444-555555555555".to_owned(),
                options
            ),
            Err(CoreError::AgentSessionLogSessionMismatch { .. })
        ));
        assert!(matches!(
            AgentSessionLog::open(
                root.join("missing.events").display().to_string(),
                "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081".to_owned(),
                AgentSessionLogOpenOptionsV1 {
                    create_if_missing: false,
                    load_snapshot: false,
                },
            ),
            Err(CoreError::AgentSessionLogNotFound { .. })
        ));
        assert!(matches!(
            AgentSessionLog::open(
                root.join("x.events").display().to_string(),
                "not-a-uuid".to_owned(),
                options
            ),
            Err(CoreError::AgentSessionLogInvalidSessionId { .. })
        ));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn newer_log_schema_fails_closed_through_the_ffi() {
        let root = scratch_dir();
        let path = root.join("AgentSession-X.events");
        let mut header = agentry_agent_session_log::FileHeader::new(
            agentry_agent_session_log::FileKind::Log,
            SessionId::from_bytes([1u8; 16]),
        )
        .encode()
        .to_vec();
        header[5] = 2;
        std::fs::write(&path, &header).unwrap();
        let result = AgentSessionLog::open(
            path.display().to_string(),
            SessionId::from_bytes([1u8; 16]).to_string(),
            AgentSessionLogOpenOptionsV1 {
                create_if_missing: true,
                load_snapshot: true,
            },
        );
        assert!(matches!(
            result,
            Err(CoreError::AgentSessionLogUnsupportedSchemaVersion {
                found: 2,
                supported: 1
            })
        ));
        assert_eq!(std::fs::read(&path).unwrap(), header, "never touched");
        let _ = std::fs::remove_dir_all(root);
    }
}
