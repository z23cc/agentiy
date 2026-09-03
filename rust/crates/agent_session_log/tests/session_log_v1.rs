//! Frozen-format and behaviour tests for the agent session log (design §7.2).
//!
//! Fixture layout (all little sessions of `0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081`):
//! * `empty.log` -- 24-byte header only.
//! * `two-records.log` -- header + two `AgentSessionEvent { recorded_at, user_message }` records.
//! * `torn-tail.log` -- `two-records.log` + a third record cut five bytes short.
//! * `unknown-version.log` -- header with `schema_version = 2`.
//! * `valid.snapshot` -- snapshot header + one `AgentSessionSnapshot { through_cursor: 2 }` record.
//! * `corrupt.snapshot` -- `valid.snapshot` with its last payload byte flipped.
//! * `unknown-version.snapshot` -- snapshot header with `schema_version = 2`.
//!
//! Fixtures are copied into a scratch directory before opening because `open` truncates torn tails.

use agentry_agent_session_log::{
    Durability, HEADER_BYTES, LogError, OpenOptions, RECORD_HEADER_BYTES, SessionId, SessionLog,
    SnapshotLoad, TornTailReason, decode_record, encode_record,
};
use agentry_proto::agent_host::v1::{
    AgentSessionEvent, AgentSessionSnapshot, SessionSummary, UserMessage, agent_session_event,
};
use proptest::prelude::*;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

const EMPTY_LOG: &[u8] = include_bytes!("fixtures/v1/empty.log");
const TWO_RECORDS_LOG: &[u8] = include_bytes!("fixtures/v1/two-records.log");
const TORN_TAIL_LOG: &[u8] = include_bytes!("fixtures/v1/torn-tail.log");
const UNKNOWN_VERSION_LOG: &[u8] = include_bytes!("fixtures/v1/unknown-version.log");
const VALID_SNAPSHOT: &[u8] = include_bytes!("fixtures/v1/valid.snapshot");
const CORRUPT_SNAPSHOT: &[u8] = include_bytes!("fixtures/v1/corrupt.snapshot");
const UNKNOWN_VERSION_SNAPSHOT: &[u8] = include_bytes!("fixtures/v1/unknown-version.snapshot");
const FIXTURE_SESSION: &str = "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081";

static NEXT_SCRATCH: AtomicU64 = AtomicU64::new(1);

struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "agentry-session-log-test-{}-{}",
            std::process::id(),
            NEXT_SCRATCH.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).unwrap();
        Self { root }
    }

    fn log_path(&self) -> PathBuf {
        self.root.join("session.log")
    }

    fn snapshot_path(&self) -> PathBuf {
        self.root.join("session.snapshot")
    }

    fn write_log(&self, bytes: &[u8]) -> PathBuf {
        let path = self.log_path();
        fs::write(&path, bytes).unwrap();
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn session() -> SessionId {
    SessionId::parse(FIXTURE_SESSION).unwrap()
}

fn event(message_id: &str, text: &str, recorded_at: &str) -> AgentSessionEvent {
    AgentSessionEvent {
        recorded_at: recorded_at.to_owned(),
        body: Some(agent_session_event::Body::UserMessage(UserMessage {
            message_id: message_id.to_owned(),
            text: text.to_owned(),
            ..UserMessage::default()
        })),
    }
}

fn open(path: &Path) -> (SessionLog, agentry_agent_session_log::OpenReport) {
    SessionLog::open(path, session(), OpenOptions::default()).unwrap()
}

#[test]
fn creates_a_header_and_round_trips_appends_across_reopen() {
    let scratch = Scratch::new();
    let path = scratch.log_path();
    let (mut log, report) = open(&path);
    assert!(report.created);
    assert_eq!(report.next_cursor, 1);
    assert_eq!(report.torn_tail, None);
    assert_eq!(report.snapshot, SnapshotLoad::Missing);
    assert_eq!(fs::read(&path).unwrap(), EMPTY_LOG);

    let first = event("m1", "hello", "2026-09-03T00:00:01Z");
    let second = event("m2", "world", "2026-09-03T00:00:02Z");
    assert_eq!(log.append(&first, Durability::Deferred).unwrap(), 1);
    assert_eq!(log.append(&second, Durability::Sync).unwrap(), 2);
    assert_eq!(log.next_cursor(), 3);
    assert_eq!(
        fs::read(&path).unwrap(),
        TWO_RECORDS_LOG,
        "frozen record encoding"
    );

    let batch = log.read_from(1, 16, 1 << 20).unwrap();
    assert_eq!(batch.entries.len(), 2);
    assert_eq!(batch.entries[0].cursor, 1);
    assert_eq!(batch.entries[0].event, first);
    assert_eq!(batch.entries[1].cursor, 2);
    assert_eq!(batch.entries[1].event, second);
    assert_eq!(batch.next_cursor, 3);
    assert!(batch.end_of_log);

    let limited = log.read_from(1, 1, 1 << 20).unwrap();
    assert_eq!(limited.entries.len(), 1);
    assert_eq!(limited.next_cursor, 2);
    assert!(!limited.end_of_log);

    let tiny_budget = log.read_from(1, 16, 1).unwrap();
    assert_eq!(tiny_budget.entries.len(), 1, "always at least one record");

    let at_end = log.read_from(3, 16, 1 << 20).unwrap();
    assert!(at_end.entries.is_empty());
    assert!(at_end.end_of_log);
    assert_eq!(
        log.read_from(0, 1, 1).unwrap_err(),
        LogError::CursorOutOfRange {
            cursor: 0,
            next_cursor: 3
        }
    );
    assert_eq!(
        log.read_from(4, 1, 1).unwrap_err(),
        LogError::CursorOutOfRange {
            cursor: 4,
            next_cursor: 3
        }
    );
    log.close().unwrap();

    let (reopened, report) = open(&path);
    assert!(!report.created);
    assert_eq!(report.next_cursor, 3);
    assert_eq!(report.torn_tail, None);
    assert_eq!(
        reopened.read_from(2, 8, 1 << 20).unwrap().entries[0].event,
        second
    );
}

#[test]
fn decodes_frozen_fixtures() {
    let scratch = Scratch::new();
    let (log, report) = open(&scratch.write_log(TWO_RECORDS_LOG));
    assert_eq!(report.next_cursor, 3);
    assert_eq!(report.torn_tail, None);
    let entries = log.read_from(1, 8, 1 << 20).unwrap().entries;
    assert_eq!(
        entries[0].event,
        event("m1", "hello", "2026-09-03T00:00:01Z")
    );
    assert_eq!(
        entries[1].event,
        event("m2", "world", "2026-09-03T00:00:02Z")
    );

    let (empty, report) = open(&scratch.write_log(EMPTY_LOG));
    assert_eq!(report.next_cursor, 1);
    assert_eq!(empty.last_cursor(), 0);
}

#[test]
fn truncates_a_torn_tail_and_reports_the_lost_range() {
    let scratch = Scratch::new();
    let path = scratch.write_log(TORN_TAIL_LOG);
    let (mut log, report) = open(&path);
    let torn = report.torn_tail.expect("torn tail must be reported");
    assert_eq!(torn.first_lost_cursor, 3);
    assert_eq!(torn.truncated_at, TWO_RECORDS_LOG.len() as u64);
    assert_eq!(
        torn.lost_bytes,
        (TORN_TAIL_LOG.len() - TWO_RECORDS_LOG.len()) as u64
    );
    assert_eq!(torn.reason, TornTailReason::PartialPayload);
    assert_eq!(report.next_cursor, 3);
    assert_eq!(fs::read(&path).unwrap(), TWO_RECORDS_LOG);

    // The truncated log keeps working and the next record takes the lost cursor.
    let third = event("m3", "again", "2026-09-03T00:00:03Z");
    assert_eq!(log.append(&third, Durability::Sync).unwrap(), 3);
    drop(log);
    let (reopened, report) = open(&path);
    assert_eq!(report.torn_tail, None);
    assert_eq!(
        reopened.read_from(3, 1, 1 << 20).unwrap().entries[0].event,
        third
    );
}

#[test]
fn checksum_corruption_truncates_to_the_last_valid_record() {
    let scratch = Scratch::new();
    let path = scratch.log_path();
    {
        let (mut log, _) = open(&path);
        for index in 1..=3 {
            log.append(
                &event(&format!("m{index}"), "x", "2026-09-03T00:00:00Z"),
                Durability::Deferred,
            )
            .unwrap();
        }
        log.close().unwrap();
    }
    let mut bytes = fs::read(&path).unwrap();
    let (_, first_frame) = decode_record(&bytes[HEADER_BYTES..], 1 << 20).unwrap();
    let second_payload_start = HEADER_BYTES + first_frame + RECORD_HEADER_BYTES;
    bytes[second_payload_start + 3] ^= 0x55;
    fs::write(&path, &bytes).unwrap();

    let (log, report) = open(&path);
    let torn = report.torn_tail.unwrap();
    assert_eq!(torn.reason, TornTailReason::ChecksumMismatch);
    assert_eq!(torn.first_lost_cursor, 2);
    assert_eq!(log.last_cursor(), 1);
    assert_eq!(fs::metadata(&path).unwrap().len(), torn.truncated_at);
}

#[test]
fn partial_file_header_is_rewritten_as_an_empty_log() {
    let scratch = Scratch::new();
    let path = scratch.write_log(&EMPTY_LOG[..10]);
    let (log, report) = open(&path);
    assert_eq!(log.last_cursor(), 0);
    let torn = report.torn_tail.unwrap();
    assert_eq!(torn.reason, TornTailReason::PartialFileHeader);
    assert_eq!(torn.lost_bytes, 10);
    assert_eq!(fs::read(&path).unwrap(), EMPTY_LOG);
}

#[test]
fn unknown_schema_versions_fail_closed() {
    let scratch = Scratch::new();
    let path = scratch.write_log(UNKNOWN_VERSION_LOG);
    let error = SessionLog::open(&path, session(), OpenOptions::default()).unwrap_err();
    assert_eq!(
        error,
        LogError::UnsupportedSchemaVersion {
            found: 2,
            supported: 1
        }
    );
    assert_eq!(
        fs::read(&path).unwrap(),
        UNKNOWN_VERSION_LOG,
        "never touched"
    );

    let path = scratch.write_log(TWO_RECORDS_LOG);
    fs::write(scratch.snapshot_path(), UNKNOWN_VERSION_SNAPSHOT).unwrap();
    let error = SessionLog::open(&path, session(), OpenOptions::default()).unwrap_err();
    assert_eq!(
        error,
        LogError::UnsupportedSchemaVersion {
            found: 2,
            supported: 1
        }
    );
}

#[test]
fn rejects_foreign_files_and_other_sessions() {
    let scratch = Scratch::new();
    let path = scratch.write_log(TWO_RECORDS_LOG);
    let other = SessionId::from_bytes([0xAB; 16]);
    assert!(matches!(
        SessionLog::open(&path, other, OpenOptions::default()),
        Err(LogError::SessionMismatch { .. })
    ));
    let mut foreign = TWO_RECORDS_LOG.to_vec();
    foreign[0..4].copy_from_slice(b"AGRY");
    let path = scratch.write_log(&foreign);
    assert_eq!(
        SessionLog::open(&path, session(), OpenOptions::default()).unwrap_err(),
        LogError::InvalidMagic { found: *b"AGRY" }
    );
    let missing = scratch.root.join("missing.log");
    assert!(matches!(
        SessionLog::open(
            &missing,
            session(),
            OpenOptions {
                create_if_missing: false,
                load_snapshot: false
            }
        ),
        Err(LogError::NotFound { .. })
    ));
}

#[test]
fn compact_writes_the_snapshot_atomically_without_rewriting_the_log() {
    let scratch = Scratch::new();
    let path = scratch.write_log(TWO_RECORDS_LOG);
    let (mut log, _) = open(&path);
    let snapshot = AgentSessionSnapshot {
        session_id: FIXTURE_SESSION.to_owned(),
        through_cursor: 2,
        summary: Some(SessionSummary {
            session_name: "fixture".to_owned(),
            ..SessionSummary::default()
        }),
        ..AgentSessionSnapshot::default()
    };
    let receipt = log.compact(&snapshot).unwrap();
    assert_eq!(receipt.through_cursor, 2);
    assert_eq!(receipt.snapshot_path, scratch.snapshot_path());
    assert_eq!(fs::read(scratch.snapshot_path()).unwrap(), VALID_SNAPSHOT);
    assert_eq!(
        fs::read(&path).unwrap(),
        TWO_RECORDS_LOG,
        "log is never rewritten"
    );
    let leftovers: Vec<_> = fs::read_dir(&scratch.root)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| name.contains("tmp"))
        .collect();
    assert!(
        leftovers.is_empty(),
        "no temporary file survives: {leftovers:?}"
    );

    assert_eq!(
        log.load_snapshot().unwrap(),
        SnapshotLoad::Loaded(snapshot.clone())
    );
    drop(log);
    let (_, report) = open(&path);
    assert_eq!(report.snapshot, SnapshotLoad::Loaded(snapshot));
    assert_eq!(report.snapshot.replay_from(), 3);
}

#[test]
fn snapshot_load_falls_back_to_full_replay_when_unusable() {
    let scratch = Scratch::new();
    let path = scratch.write_log(TWO_RECORDS_LOG);

    fs::write(scratch.snapshot_path(), CORRUPT_SNAPSHOT).unwrap();
    let (log, report) = open(&path);
    assert!(matches!(report.snapshot, SnapshotLoad::Corrupt { .. }));
    assert_eq!(report.snapshot.replay_from(), 1);
    assert_eq!(
        fs::read(scratch.snapshot_path()).unwrap(),
        CORRUPT_SNAPSHOT,
        "a corrupt snapshot is ignored, not repaired"
    );

    // A snapshot that claims more than the log holds is stale, not authoritative.
    let ahead = AgentSessionSnapshot {
        session_id: FIXTURE_SESSION.to_owned(),
        through_cursor: 5,
        ..AgentSessionSnapshot::default()
    };
    let mut log = log;
    assert_eq!(
        log.compact(&ahead).unwrap_err(),
        LogError::SnapshotAheadOfLog {
            through_cursor: 5,
            last_cursor: 2
        }
    );
    let other_session = AgentSessionSnapshot {
        session_id: "11111111-2222-3333-4444-555555555555".to_owned(),
        through_cursor: 1,
        ..AgentSessionSnapshot::default()
    };
    assert!(matches!(
        log.compact(&other_session),
        Err(LogError::SnapshotSessionMismatch { .. })
    ));

    // A valid snapshot that outruns a (now shorter) log is stale: ignored, never used to repair.
    log.compact(&AgentSessionSnapshot {
        session_id: FIXTURE_SESSION.to_owned(),
        through_cursor: 2,
        ..AgentSessionSnapshot::default()
    })
    .unwrap();
    drop(log);
    fs::write(&path, EMPTY_LOG).unwrap();
    let (_, report) = open(&path);
    assert!(matches!(report.snapshot, SnapshotLoad::Corrupt { .. }));
    assert_eq!(fs::read(&path).unwrap(), EMPTY_LOG);

    fs::remove_file(scratch.snapshot_path()).unwrap();
    let (_, report) = open(&path);
    assert_eq!(report.snapshot, SnapshotLoad::Missing);
    let (_, report) = SessionLog::open(
        &path,
        session(),
        OpenOptions {
            create_if_missing: false,
            load_snapshot: false,
        },
    )
    .unwrap();
    assert_eq!(report.snapshot, SnapshotLoad::NotRequested);
}

#[test]
fn rejects_records_above_the_payload_cap() {
    let scratch = Scratch::new();
    let (mut log, _) = open(&scratch.log_path());
    let oversize = event(
        "big",
        &"x".repeat(agentry_agent_session_log::MAXIMUM_RECORD_PAYLOAD_BYTES),
        "2026-09-03T00:00:00Z",
    );
    assert!(matches!(
        log.append(&oversize, Durability::Deferred),
        Err(LogError::RecordTooLarge { .. })
    ));
    assert_eq!(log.next_cursor(), 1, "nothing was appended");
    assert_eq!(fs::read(scratch.log_path()).unwrap(), EMPTY_LOG);
}

#[test]
fn record_framing_is_frozen() {
    let frame = encode_record(b"payload", 64).unwrap();
    assert_eq!(&frame[..4], &7u32.to_be_bytes());
    assert_eq!(
        &frame[4..8],
        &agentry_agent_session_log::crc32c(b"payload").to_be_bytes()
    );
    assert_eq!(&frame[8..], b"payload");
    assert_eq!(&EMPTY_LOG[..4], b"AGSL");
    assert_eq!(&VALID_SNAPSHOT[..4], b"AGSS");
    assert_eq!(EMPTY_LOG[4..8], [0, 1, 0, 0]);
    assert_eq!(&EMPTY_LOG[8..], session().as_bytes());
}

proptest! {
    #[test]
    fn record_decoder_never_panics(bytes in proptest::collection::vec(any::<u8>(), 0..512)) {
        let _ = decode_record(&bytes, 1 << 20);
    }

    #[test]
    fn session_ids_round_trip(bytes in any::<[u8; 16]>()) {
        let id = SessionId::from_bytes(bytes);
        prop_assert_eq!(SessionId::parse(&id.to_string()).unwrap(), id);
    }

    #[test]
    fn arbitrary_file_bytes_never_panic_on_open(bytes in proptest::collection::vec(any::<u8>(), 0..256)) {
        let scratch = Scratch::new();
        let path = scratch.write_log(&bytes);
        let _ = SessionLog::open(&path, session(), OpenOptions::default());
    }
}
