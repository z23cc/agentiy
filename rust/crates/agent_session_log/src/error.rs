use crate::format::FileKind;
use crate::session_id::SessionId;
use std::fmt;
use std::io;

/// Every failure this crate reports. I/O failures carry the operation that failed so callers can
/// tell a checkpoint fsync from a torn-tail truncation.
#[derive(Debug)]
pub enum LogError {
    Io {
        operation: &'static str,
        source: io::Error,
    },
    /// The file exists but does not start with a known magic; it is not touched.
    InvalidMagic {
        found: [u8; 4],
    },
    /// A `.snapshot` was offered where a `.log` was expected or vice versa.
    WrongFileKind {
        expected: FileKind,
        found: FileKind,
    },
    /// Written by a newer runtime (ADR-0006: refuse rather than guess).
    UnsupportedSchemaVersion {
        found: u16,
        supported: u16,
    },
    UnsupportedFlags {
        found: u16,
    },
    SessionMismatch {
        expected: SessionId,
        found: SessionId,
    },
    HeaderTooShort {
        actual: usize,
    },
    InvalidSessionId {
        value: String,
    },
    /// `open` without `create_if_missing` and the file does not exist.
    NotFound {
        path: String,
    },
    RecordTooLarge {
        actual: usize,
        maximum: usize,
    },
    /// `read_from` asked for a cursor that is 0 or past the end of the log.
    CursorOutOfRange {
        cursor: u64,
        next_cursor: u64,
    },
    /// A CRC-valid record does not decode as the expected message; the log is left untouched.
    Malformed {
        cursor: u64,
        detail: String,
    },
    /// `compact` was given a snapshot claiming records the log does not hold.
    SnapshotAheadOfLog {
        through_cursor: u64,
        last_cursor: u64,
    },
    SnapshotSessionMismatch {
        expected: SessionId,
        found: String,
    },
    Codec(agentry_proto::agent_host::FrameError),
    /// The handle was closed; every later call fails.
    Closed,
}

impl PartialEq for LogError {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (
                Self::Io {
                    operation: left_operation,
                    source: left,
                },
                Self::Io {
                    operation: right_operation,
                    source: right,
                },
            ) => left_operation == right_operation && left.kind() == right.kind(),
            (Self::InvalidMagic { found: left }, Self::InvalidMagic { found: right }) => {
                left == right
            }
            (
                Self::WrongFileKind {
                    expected: left_expected,
                    found: left_found,
                },
                Self::WrongFileKind {
                    expected: right_expected,
                    found: right_found,
                },
            ) => left_expected == right_expected && left_found == right_found,
            (
                Self::UnsupportedSchemaVersion {
                    found: left_found,
                    supported: left_supported,
                },
                Self::UnsupportedSchemaVersion {
                    found: right_found,
                    supported: right_supported,
                },
            ) => left_found == right_found && left_supported == right_supported,
            (Self::UnsupportedFlags { found: left }, Self::UnsupportedFlags { found: right }) => {
                left == right
            }
            (
                Self::SessionMismatch {
                    expected: left_expected,
                    found: left_found,
                },
                Self::SessionMismatch {
                    expected: right_expected,
                    found: right_found,
                },
            ) => left_expected == right_expected && left_found == right_found,
            (Self::HeaderTooShort { actual: left }, Self::HeaderTooShort { actual: right }) => {
                left == right
            }
            (Self::InvalidSessionId { value: left }, Self::InvalidSessionId { value: right }) => {
                left == right
            }
            (Self::NotFound { path: left }, Self::NotFound { path: right }) => left == right,
            (
                Self::RecordTooLarge {
                    actual: left_actual,
                    maximum: left_maximum,
                },
                Self::RecordTooLarge {
                    actual: right_actual,
                    maximum: right_maximum,
                },
            ) => left_actual == right_actual && left_maximum == right_maximum,
            (
                Self::CursorOutOfRange {
                    cursor: left_cursor,
                    next_cursor: left_next,
                },
                Self::CursorOutOfRange {
                    cursor: right_cursor,
                    next_cursor: right_next,
                },
            ) => left_cursor == right_cursor && left_next == right_next,
            (
                Self::Malformed {
                    cursor: left_cursor,
                    detail: left_detail,
                },
                Self::Malformed {
                    cursor: right_cursor,
                    detail: right_detail,
                },
            ) => left_cursor == right_cursor && left_detail == right_detail,
            (
                Self::SnapshotAheadOfLog {
                    through_cursor: left_through,
                    last_cursor: left_last,
                },
                Self::SnapshotAheadOfLog {
                    through_cursor: right_through,
                    last_cursor: right_last,
                },
            ) => left_through == right_through && left_last == right_last,
            (
                Self::SnapshotSessionMismatch {
                    expected: left_expected,
                    found: left_found,
                },
                Self::SnapshotSessionMismatch {
                    expected: right_expected,
                    found: right_found,
                },
            ) => left_expected == right_expected && left_found == right_found,
            (Self::Codec(left), Self::Codec(right)) => left == right,
            (Self::Closed, Self::Closed) => true,
            _ => false,
        }
    }
}

impl fmt::Display for LogError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { operation, source } => write!(formatter, "{operation}: {source}"),
            Self::InvalidMagic { found } => {
                write!(
                    formatter,
                    "not an agent session log file (magic {found:02x?})"
                )
            }
            Self::WrongFileKind { expected, found } => {
                write!(
                    formatter,
                    "expected a {expected:?} file, found a {found:?} file"
                )
            }
            Self::UnsupportedSchemaVersion { found, supported } => write!(
                formatter,
                "log schema version {found} is newer than the supported version {supported}; refusing to load"
            ),
            Self::UnsupportedFlags { found } => {
                write!(formatter, "unsupported header flags {found:#06x}")
            }
            Self::SessionMismatch { expected, found } => {
                write!(
                    formatter,
                    "file belongs to session {found}, expected {expected}"
                )
            }
            Self::HeaderTooShort { actual } => {
                write!(formatter, "file header needs 24 bytes, found {actual}")
            }
            Self::InvalidSessionId { value } => write!(formatter, "invalid session id {value:?}"),
            Self::NotFound { path } => write!(formatter, "log file not found: {path}"),
            Self::RecordTooLarge { actual, maximum } => write!(
                formatter,
                "record payload of {actual} bytes exceeds the {maximum}-byte cap"
            ),
            Self::CursorOutOfRange {
                cursor,
                next_cursor,
            } => write!(
                formatter,
                "cursor {cursor} is outside 1..={next_cursor} (next cursor)"
            ),
            Self::Malformed { cursor, detail } => {
                write!(formatter, "record {cursor} does not decode: {detail}")
            }
            Self::SnapshotAheadOfLog {
                through_cursor,
                last_cursor,
            } => write!(
                formatter,
                "snapshot claims cursor {through_cursor} but the log ends at {last_cursor}"
            ),
            Self::SnapshotSessionMismatch { expected, found } => write!(
                formatter,
                "snapshot session id {found:?} does not match log session {expected}"
            ),
            Self::Codec(error) => write!(formatter, "{error}"),
            Self::Closed => write!(formatter, "log handle is closed"),
        }
    }
}

impl std::error::Error for LogError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Codec(error) => Some(error),
            _ => None,
        }
    }
}

impl From<agentry_proto::agent_host::FrameError> for LogError {
    fn from(value: agentry_proto::agent_host::FrameError) -> Self {
        Self::Codec(value)
    }
}

pub(crate) fn io_error(operation: &'static str) -> impl FnOnce(io::Error) -> LogError {
    move |source| LogError::Io { operation, source }
}
