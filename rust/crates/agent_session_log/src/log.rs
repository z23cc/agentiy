//! The append-only session log and its derived snapshot file (design §7.2).

use crate::error::{LogError, io_error};
use crate::format::{
    FileHeader, FileKind, HEADER_BYTES, MAXIMUM_RECORD_PAYLOAD_BYTES,
    MAXIMUM_SNAPSHOT_PAYLOAD_BYTES, RECORD_HEADER_BYTES, RecordDefect, decode_record,
    encode_record,
};
use crate::session_id::SessionId;
use agentry_proto::agent_host::v1::{AgentSessionEvent, AgentSessionSnapshot};
use agentry_proto::agent_host::{decode_snapshot, encode_snapshot};
use prost::Message;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};

/// When `append` must reach stable storage.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Durability {
    /// `fdatasync` before returning (default for records that settle a command or end a turn).
    Sync,
    /// Write only; the caller syncs at the next turn boundary via [`SessionLog::sync`],
    /// [`SessionLog::compact`], or [`SessionLog::close`].
    Deferred,
}

/// `open` options.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OpenOptions {
    /// Create the file (and write the header) when it does not exist.
    pub create_if_missing: bool,
    /// Also load the latest valid `.snapshot` into the report.
    pub load_snapshot: bool,
}

impl Default for OpenOptions {
    fn default() -> Self {
        Self {
            create_if_missing: true,
            load_snapshot: true,
        }
    }
}

/// Why the tail of a log was discarded at `open`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TornTailReason {
    PartialHeader,
    PartialPayload,
    ChecksumMismatch,
    LengthOutOfRange,
    /// The file was shorter than a header; it was rewritten as an empty log.
    PartialFileHeader,
}

/// Bytes discarded at `open` because they were not a complete, CRC-valid record.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TornTail {
    /// Cursor the first lost record would have had (equals the log's `next_cursor` after open).
    pub first_lost_cursor: u64,
    /// File offset the log was truncated to.
    pub truncated_at: u64,
    /// Number of bytes discarded.
    pub lost_bytes: u64,
    pub reason: TornTailReason,
}

/// Outcome of loading the derived `.snapshot`.
#[derive(Clone, Debug, PartialEq)]
pub enum SnapshotLoad {
    /// A CRC-valid snapshot for this session whose `through_cursor` the log still covers.
    Loaded(AgentSessionSnapshot),
    /// No snapshot file; replay from cursor 1.
    Missing,
    /// The snapshot exists but is unusable; it is ignored (never used to repair the log) and the
    /// caller replays from cursor 1. `compact` overwrites it.
    Corrupt { reason: String },
    /// `open` was asked not to load it.
    NotRequested,
}

impl SnapshotLoad {
    /// First cursor the caller must replay after applying the snapshot (1 when none applies).
    #[must_use]
    pub fn replay_from(&self) -> u64 {
        match self {
            Self::Loaded(snapshot) => snapshot.through_cursor + 1,
            Self::Missing | Self::Corrupt { .. } | Self::NotRequested => 1,
        }
    }
}

/// What `open` learned about the file.
#[derive(Clone, Debug, PartialEq)]
pub struct OpenReport {
    /// True when the file did not exist and was created.
    pub created: bool,
    /// Cursor the next appended record will receive (`last_cursor + 1`).
    pub next_cursor: u64,
    /// Present when a torn tail was truncated.
    pub torn_tail: Option<TornTail>,
    pub snapshot: SnapshotLoad,
}

/// One decoded record.
#[derive(Clone, Debug, PartialEq)]
pub struct LogEntry {
    pub cursor: u64,
    pub event: AgentSessionEvent,
}

/// A bounded `read_from` result.
#[derive(Clone, Debug, PartialEq)]
pub struct ReadBatch {
    pub entries: Vec<LogEntry>,
    /// Cursor to pass to the next `read_from`.
    pub next_cursor: u64,
    /// True when `next_cursor` is the log's own next cursor (nothing more to read right now).
    pub end_of_log: bool,
}

/// Receipt of a written snapshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompactReceipt {
    pub through_cursor: u64,
    pub snapshot_payload_bytes: u64,
    pub snapshot_path: PathBuf,
}

/// An open session log. Single writer per file (ADR-0006 single-writer lease is the host's job);
/// reads are positional and never disturb the append position.
#[derive(Debug)]
pub struct SessionLog {
    file: File,
    path: PathBuf,
    session_id: SessionId,
    /// Byte offset of record `i + 1`; `offsets.len()` is the last cursor.
    offsets: Vec<u64>,
    end_offset: u64,
    dirty: bool,
}

impl SessionLog {
    /// Opens (or creates) the log at `path` for `session_id`, validates the header, scans every
    /// record, truncates a torn tail, and loads the snapshot when asked.
    pub fn open(
        path: impl AsRef<Path>,
        session_id: SessionId,
        options: OpenOptions,
    ) -> Result<(Self, OpenReport), LogError> {
        let path = path.as_ref().to_path_buf();
        let exists = path.is_file();
        if !exists && !options.create_if_missing {
            return Err(LogError::NotFound {
                path: path.display().to_string(),
            });
        }
        let mut file = fs::OpenOptions::new()
            .read(true)
            .append(true)
            .create(options.create_if_missing)
            .open(&path)
            .map_err(io_error("open log"))?;

        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).map_err(io_error("read log"))?;

        let mut torn_tail = None;
        let header = FileHeader::new(FileKind::Log, session_id);
        if bytes.is_empty() {
            file.write_all(&header.encode())
                .map_err(io_error("write log header"))?;
            file.sync_data().map_err(io_error("sync log header"))?;
            bytes.extend_from_slice(&header.encode());
        } else if bytes.len() < HEADER_BYTES {
            // A crash between `create` and the header write: nothing after the header can exist,
            // so rewriting it loses no record.
            file.set_len(0).map_err(io_error("truncate torn header"))?;
            file.write_all(&header.encode())
                .map_err(io_error("write log header"))?;
            file.sync_data().map_err(io_error("sync log header"))?;
            torn_tail = Some(TornTail {
                first_lost_cursor: 1,
                truncated_at: 0,
                lost_bytes: bytes.len() as u64,
                reason: TornTailReason::PartialFileHeader,
            });
            bytes.clear();
            bytes.extend_from_slice(&header.encode());
        } else {
            FileHeader::decode(&bytes[..HEADER_BYTES], FileKind::Log, session_id)?;
        }

        let mut offsets = Vec::new();
        let mut offset = HEADER_BYTES;
        loop {
            if offset == bytes.len() {
                break;
            }
            match decode_record(&bytes[offset..], MAXIMUM_RECORD_PAYLOAD_BYTES) {
                Ok((_, consumed)) => {
                    offsets.push(offset as u64);
                    offset += consumed;
                }
                Err(defect) => {
                    let reason = match defect {
                        RecordDefect::PartialHeader { .. } => TornTailReason::PartialHeader,
                        RecordDefect::PartialPayload { .. } => TornTailReason::PartialPayload,
                        RecordDefect::ChecksumMismatch { .. } => TornTailReason::ChecksumMismatch,
                        RecordDefect::LengthOutOfRange { .. } => TornTailReason::LengthOutOfRange,
                    };
                    file.set_len(offset as u64)
                        .map_err(io_error("truncate torn tail"))?;
                    file.sync_data().map_err(io_error("sync truncated log"))?;
                    torn_tail = Some(TornTail {
                        first_lost_cursor: offsets.len() as u64 + 1,
                        truncated_at: offset as u64,
                        lost_bytes: (bytes.len() - offset) as u64,
                        reason,
                    });
                    bytes.truncate(offset);
                    break;
                }
            }
        }

        let log = Self {
            file,
            path,
            session_id,
            offsets,
            end_offset: bytes.len() as u64,
            dirty: false,
        };
        let snapshot = if options.load_snapshot {
            log.load_snapshot()?
        } else {
            SnapshotLoad::NotRequested
        };
        let report = OpenReport {
            created: !exists,
            next_cursor: log.next_cursor(),
            torn_tail,
            snapshot,
        };
        Ok((log, report))
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    #[must_use]
    pub fn session_id(&self) -> SessionId {
        self.session_id
    }

    /// Cursor the next appended record receives; `last_cursor() + 1`.
    #[must_use]
    pub fn next_cursor(&self) -> u64 {
        self.offsets.len() as u64 + 1
    }

    /// Cursor of the last record, 0 for an empty log.
    #[must_use]
    pub fn last_cursor(&self) -> u64 {
        self.offsets.len() as u64
    }

    /// Path of the derived snapshot (`<stem>.snapshot` beside the log).
    #[must_use]
    pub fn snapshot_path(&self) -> PathBuf {
        self.path.with_extension("snapshot")
    }

    /// Appends one event and returns its cursor.
    pub fn append(
        &mut self,
        event: &AgentSessionEvent,
        durability: Durability,
    ) -> Result<u64, LogError> {
        let payload = event.encode_to_vec();
        self.append_payload(&payload, durability)
    }

    fn append_payload(&mut self, payload: &[u8], durability: Durability) -> Result<u64, LogError> {
        let frame = encode_record(payload, MAXIMUM_RECORD_PAYLOAD_BYTES)?;
        // Append mode positions every write at the current end; `write_all` of one frame keeps a
        // torn write confined to the tail, which `open` detects and truncates.
        self.file
            .write_all(&frame)
            .map_err(io_error("append record"))?;
        let cursor = self.next_cursor();
        self.offsets.push(self.end_offset);
        self.end_offset += frame.len() as u64;
        self.dirty = true;
        if durability == Durability::Sync {
            self.sync()?;
        }
        Ok(cursor)
    }

    /// `fdatasync` of every deferred append.
    pub fn sync(&mut self) -> Result<(), LogError> {
        if self.dirty {
            self.file.sync_data().map_err(io_error("sync log"))?;
            self.dirty = false;
        }
        Ok(())
    }

    /// Reads records starting at `cursor` (1-based), returning at most `max_records` entries whose
    /// encoded payloads total at most `max_bytes` (always at least one when any remain).
    pub fn read_from(
        &self,
        cursor: u64,
        max_records: usize,
        max_bytes: usize,
    ) -> Result<ReadBatch, LogError> {
        let next_cursor = self.next_cursor();
        if cursor == 0 || cursor > next_cursor {
            return Err(LogError::CursorOutOfRange {
                cursor,
                next_cursor,
            });
        }
        let mut entries = Vec::new();
        let mut consumed_bytes = 0usize;
        let mut current = cursor;
        while current < next_cursor && entries.len() < max_records.max(1) {
            let payload = self.read_payload(current)?;
            if !entries.is_empty() && consumed_bytes + payload.len() > max_bytes {
                break;
            }
            consumed_bytes += payload.len();
            let event = AgentSessionEvent::decode(payload.as_slice()).map_err(|error| {
                LogError::Malformed {
                    cursor: current,
                    detail: error.to_string(),
                }
            })?;
            entries.push(LogEntry {
                cursor: current,
                event,
            });
            current += 1;
        }
        Ok(ReadBatch {
            entries,
            next_cursor: current,
            end_of_log: current == next_cursor,
        })
    }

    fn read_payload(&self, cursor: u64) -> Result<Vec<u8>, LogError> {
        let index = usize::try_from(cursor - 1).map_err(|_| LogError::CursorOutOfRange {
            cursor,
            next_cursor: self.next_cursor(),
        })?;
        let start = self.offsets[index];
        let end = self
            .offsets
            .get(index + 1)
            .copied()
            .unwrap_or(self.end_offset);
        let length = usize::try_from(end - start).map_err(|_| LogError::Malformed {
            cursor,
            detail: "record length overflow".to_owned(),
        })?;
        let mut frame = vec![0u8; length];
        self.file
            .read_exact_at(&mut frame, start)
            .map_err(io_error("read record"))?;
        match decode_record(&frame, MAXIMUM_RECORD_PAYLOAD_BYTES) {
            Ok((payload, consumed)) if consumed == frame.len() => Ok(payload.to_vec()),
            Ok(_) => Err(LogError::Malformed {
                cursor,
                detail: "record length does not match the index".to_owned(),
            }),
            Err(defect) => Err(LogError::Malformed {
                cursor,
                detail: format!("{defect:?}"),
            }),
        }
    }

    /// Writes `snapshot` to `<stem>.snapshot` by atomic replace after syncing the log so the
    /// snapshot never claims a cursor that is not durable. The log itself is never rewritten.
    pub fn compact(&mut self, snapshot: &AgentSessionSnapshot) -> Result<CompactReceipt, LogError> {
        if !snapshot.session_id.is_empty() {
            let declared = SessionId::parse(&snapshot.session_id).map_err(|_| {
                LogError::SnapshotSessionMismatch {
                    expected: self.session_id,
                    found: snapshot.session_id.clone(),
                }
            })?;
            if declared != self.session_id {
                return Err(LogError::SnapshotSessionMismatch {
                    expected: self.session_id,
                    found: snapshot.session_id.clone(),
                });
            }
        }
        let last_cursor = self.last_cursor();
        if snapshot.through_cursor > last_cursor {
            return Err(LogError::SnapshotAheadOfLog {
                through_cursor: snapshot.through_cursor,
                last_cursor,
            });
        }
        self.sync()?;

        let payload = encode_snapshot(snapshot)?;
        let mut bytes = FileHeader::new(FileKind::Snapshot, self.session_id)
            .encode()
            .to_vec();
        bytes.extend_from_slice(&encode_record(&payload, MAXIMUM_SNAPSHOT_PAYLOAD_BYTES)?);

        let destination = self.snapshot_path();
        let temporary = destination.with_extension(format!("snapshot.tmp-{}", std::process::id()));
        {
            let mut file = File::create(&temporary).map_err(io_error("create snapshot"))?;
            file.write_all(&bytes).map_err(io_error("write snapshot"))?;
            file.sync_all().map_err(io_error("sync snapshot"))?;
        }
        fs::rename(&temporary, &destination).map_err(io_error("publish snapshot"))?;
        if let Some(parent) = destination.parent()
            && let Ok(directory) = File::open(parent)
        {
            // Best effort: directory fsync is not available on every filesystem.
            let _ = directory.sync_all();
        }
        Ok(CompactReceipt {
            through_cursor: snapshot.through_cursor,
            snapshot_payload_bytes: payload.len() as u64,
            snapshot_path: destination,
        })
    }

    /// Loads the latest `.snapshot`. Missing or corrupt snapshots are reported, never repaired;
    /// a snapshot written by a newer schema fails closed.
    pub fn load_snapshot(&self) -> Result<SnapshotLoad, LogError> {
        let path = self.snapshot_path();
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(SnapshotLoad::Missing);
            }
            Err(error) => return Err(io_error("read snapshot")(error)),
        };
        if bytes.len() < HEADER_BYTES {
            return Ok(SnapshotLoad::Corrupt {
                reason: format!(
                    "snapshot header needs {HEADER_BYTES} bytes, found {}",
                    bytes.len()
                ),
            });
        }
        match FileHeader::decode(&bytes[..HEADER_BYTES], FileKind::Snapshot, self.session_id) {
            Ok(_) => {}
            Err(error @ LogError::UnsupportedSchemaVersion { .. }) => return Err(error),
            Err(error) => {
                return Ok(SnapshotLoad::Corrupt {
                    reason: error.to_string(),
                });
            }
        }
        let body = &bytes[HEADER_BYTES..];
        let (payload, consumed) = match decode_record(body, MAXIMUM_SNAPSHOT_PAYLOAD_BYTES) {
            Ok(record) => record,
            Err(defect) => {
                return Ok(SnapshotLoad::Corrupt {
                    reason: format!("{defect:?}"),
                });
            }
        };
        if consumed != body.len() {
            return Ok(SnapshotLoad::Corrupt {
                reason: format!(
                    "{} trailing bytes after the snapshot record",
                    body.len() - consumed
                ),
            });
        }
        let snapshot = match decode_snapshot(payload) {
            Ok(snapshot) => snapshot,
            Err(error) => {
                return Ok(SnapshotLoad::Corrupt {
                    reason: error.to_string(),
                });
            }
        };
        if snapshot.through_cursor > self.last_cursor() {
            return Ok(SnapshotLoad::Corrupt {
                reason: format!(
                    "snapshot claims cursor {} but the log ends at {}",
                    snapshot.through_cursor,
                    self.last_cursor()
                ),
            });
        }
        if !snapshot.session_id.is_empty()
            && SessionId::parse(&snapshot.session_id).ok() != Some(self.session_id)
        {
            return Ok(SnapshotLoad::Corrupt {
                reason: format!("snapshot body names session {:?}", snapshot.session_id),
            });
        }
        Ok(SnapshotLoad::Loaded(snapshot))
    }

    /// Syncs deferred appends and releases the file.
    pub fn close(mut self) -> Result<(), LogError> {
        self.sync()
    }

    /// Byte length of the file (header + records).
    #[must_use]
    pub fn byte_length(&self) -> u64 {
        self.end_offset
    }

    /// Byte length of one record frame with the given payload length.
    #[must_use]
    pub const fn record_frame_length(payload_length: usize) -> usize {
        RECORD_HEADER_BYTES + payload_length
    }
}
