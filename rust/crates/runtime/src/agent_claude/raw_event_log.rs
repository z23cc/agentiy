//! P6-7 D-9/R9 (`docs/architecture/rust-agent-claude-v1.md` §10, §15.6): the Rust-side reproduction
//! of `ClaudeNativeProcessSessionController.writeRawEventLogRecord`'s DEBUG-only raw-event JSONL
//! log, gated by the SAME `app_settings` keys as Swift (`agent_mode.claude_raw_event_logging_enabled`
//! / `agent_mode.claude_raw_event_log_file_path` -- charter §11.7's "no second switch system" rule).
//! Swift resolves both the enabled flag and the absolute log-file path itself (its own
//! `isRawEventFileLoggingEnabled`/`makeRawEventLogFileURL`, widened from `private` to `internal` so
//! `ClaudeRustBackedNativeSessionAdapter` can reuse them) and hands the resolved values to Rust as
//! plain `CoreAgentClaudeScopeConfigV1` fields -- Rust never reads `UserDefaults`/`app_settings`
//! itself, and never decides the file path.
//!
//! **Record shape**: `{"kind","timestamp","runID","tabID","windowID","sessionID","payload"?}`
//! exactly mirrors Swift's envelope. A `session.header` carrying the same identity/workspace fields
//! is emitted before the first record for each observed session ID, and `set_session_id` serializes
//! the header transition with concurrent stdout/stderr/command writes. One named file-system-level
//! difference remains: this writer never rotates its file once opened. The path is resolved once,
//! by Swift, before `start_or_resume`; Swift's own rotation (a new file once a real session id
//! replaces an initial tab-id-keyed name) is not reproduced, so the Rust file stays at the initial
//! resolved path while subsequent records and headers carry the newly observed `sessionID`
//! (§15.6).
//!
//! **Kind-set completeness.** Rust contains 43 of the 44 frozen §10 kind literals and maps them to
//! equivalent lifecycle/protocol call sites. The sole absent literal is
//! `protocol.decode.failed`: Swift reaches it only from a generic `catch` after its exhaustive
//! typed `CodecError` catch, while Rust's decoder has a total `Result<_, CodecError>` surface and
//! therefore no third error class to emit honestly. §15.6 records that named replacement and the
//! few present-but-currently-unreachable legacy branches (`approval.autoApprove.fallback`, control-
//! character recovery) rather than fabricating synthetic production events to make a count pass.
//!
//! **R8 still holds here**: this writer must never be handed [`super::scope::AgentClaudeScopeConfig::environment`]
//! or any other secret-bearing value -- every call site in this crate that writes a
//! `process.spawned` record passes `command`/`arguments`/`working_directory` only, mirroring
//! Swift's own omission at its equivalent call site (contract R8).

use serde_json::{Map, Value};
use std::io::Write;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Owns the resolved enabled flag and file path; cheap to construct disabled (the common case --
/// disabled in every release build, since Swift's `isRawEventFileLoggingEnabled()` always resolves
/// `false` outside DEBUG).
#[derive(Debug, Clone, Default)]
pub struct RawEventLogContext {
    pub run_id: String,
    pub tab_id: String,
    pub window_id: i64,
    pub workspace_path: String,
    pub initial_session_id: String,
}

pub struct RawEventLogWriter {
    enabled: bool,
    file_path: Option<String>,
    context: RawEventLogContext,
    session_id: Mutex<String>,
    header_session_id: Mutex<Option<String>>,
    /// A scope can log concurrently from stdout/stderr readers and command round-trip threads.
    /// Serialize complete JSONL record construction+append so two writes can never interleave.
    write_lock: Mutex<()>,
}

impl RawEventLogWriter {
    /// `enabled` is only ever actually honored when `file_path` is also present -- matching
    /// Swift's own `ensureRawEventLogFileReadyIfNeeded` guard (`rawEventFileLoggingEnabled` AND a
    /// successfully resolved `fileURL`).
    #[must_use]
    pub fn new(enabled: bool, file_path: Option<String>, context: RawEventLogContext) -> Self {
        let enabled = enabled && file_path.is_some();
        let initial_session_id = context.initial_session_id.clone();
        Self {
            enabled,
            file_path,
            context,
            session_id: Mutex::new(initial_session_id),
            header_session_id: Mutex::new(None),
            write_lock: Mutex::new(()),
        }
    }

    #[must_use]
    pub fn disabled() -> Self {
        Self::new(false, None, RawEventLogContext::default())
    }

    #[must_use]
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// Updates the `sessionID` field every subsequent record carries -- the observability-only
    /// half of Swift's `recordObservedSessionID`, minus its file-rotation side effect (module doc).
    pub fn set_session_id(&self, session_id: impl Into<String>) {
        if !self.enabled {
            return;
        }
        let _write_guard = self
            .write_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        *self
            .session_id
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = session_id.into();
    }

    /// Appends one JSONL record. Never panics (charter §14.1): any I/O failure, or a `payload` that
    /// somehow fails to serialize, is silently dropped -- matching Swift's own
    /// `guard let handle = try? FileHandle(forWritingTo:) else { return }` catch-all.
    pub fn write(&self, kind: &'static str, payload: Option<Value>) {
        if !self.enabled {
            return;
        }
        let Some(path) = &self.file_path else { return };
        let _write_guard = self
            .write_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let session_id = self
            .session_id
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        {
            let mut header_session_id = self
                .header_session_id
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if header_session_id.as_deref() != Some(session_id.as_str()) {
                let mut header = self.record_envelope("session.header", &session_id);
                header.insert(
                    "workspacePath".to_string(),
                    Value::String(self.context.workspace_path.clone()),
                );
                append_record(path, header);
                *header_session_id = Some(session_id.clone());
            }
        }
        let mut record = self.record_envelope(kind, &session_id);
        if let Some(payload) = payload {
            record.insert("payload".to_string(), payload);
        }
        append_record(path, record);
    }

    fn record_envelope(&self, kind: &str, session_id: &str) -> Map<String, Value> {
        let mut record = Map::new();
        record.insert("kind".to_string(), Value::String(kind.to_string()));
        record.insert("timestamp".to_string(), Value::String(iso8601_now()));
        record.insert(
            "runID".to_string(),
            Value::String(self.context.run_id.clone()),
        );
        record.insert(
            "tabID".to_string(),
            Value::String(self.context.tab_id.clone()),
        );
        record.insert(
            "windowID".to_string(),
            Value::Number(self.context.window_id.into()),
        );
        record.insert(
            "sessionID".to_string(),
            Value::String(session_id.to_string()),
        );
        record
    }
}

/// Lazily creates the parent directory and the file itself, then appends -- mirroring Swift's
/// `appendRawEventLogRecord` (create-if-missing, open-seek-write-close per call, no held-open file
/// handle across writes).
fn append_record(path: &str, record: Map<String, Value>) {
    let Ok(mut line) = serde_json::to_string(&Value::Object(record)) else {
        return;
    };
    line.push('\n');
    if let Some(parent) = std::path::Path::new(path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    else {
        return;
    };
    let _ = file.write_all(line.as_bytes());
}

/// A dependency-free ISO 8601 UTC timestamp with millisecond precision
/// (`YYYY-MM-DDTHH:MM:SS.sssZ`), matching the general shape of Swift's `ISO8601DateFormatter`
/// (`.withInternetDateTime`, `.withFractionalSeconds`) without adding a `chrono`/`time` dependency
/// (§12's dependency-surface discipline) -- byte-exact timestamp equality between two
/// independently-clocked arms is not meaningful anyway (see this module's doc comment on "record
/// shape").
fn iso8601_now() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let millis = now.subsec_millis();
    let (year, month, day, hour, minute, second) = civil_from_unix_seconds(now.as_secs());
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millis:03}Z")
}

/// Howard Hinnant's `civil_from_days` algorithm (public domain,
/// <http://howardhinnant.github.io/date_algorithms.html>), specialized to whole seconds since the
/// Unix epoch. No dependency, no allocation, correct for the entire proleptic-Gregorian range this
/// process will ever observe a wall-clock timestamp in.
fn civil_from_unix_seconds(total_seconds: u64) -> (i64, u32, u32, u32, u32, u32) {
    let days = (total_seconds / 86_400) as i64;
    let time_of_day = total_seconds % 86_400;
    let hour = (time_of_day / 3600) as u32;
    let minute = ((time_of_day % 3600) / 60) as u32;
    let second = (time_of_day % 60) as u32;

    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    let year = if m <= 2 { y + 1 } else { y };

    (year, m, d, hour, minute, second)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_from_unix_seconds_matches_known_epoch_instants() {
        assert_eq!(
            civil_from_unix_seconds(0),
            (1970, 1, 1, 0, 0, 0),
            "the epoch itself"
        );
        assert_eq!(
            civil_from_unix_seconds(951_868_800),
            (2000, 3, 1, 0, 0, 0),
            "a leap-year-adjacent boundary"
        );
        assert_eq!(
            civil_from_unix_seconds(1_700_000_000),
            (2023, 11, 14, 22, 13, 20),
            "an arbitrary cross-check instant"
        );
    }

    #[test]
    fn disabled_writer_never_touches_the_filesystem() {
        let dir = std::env::temp_dir().join(format!(
            "raw-event-log-disabled-test-{}",
            std::process::id()
        ));
        let path = dir.join("should-not-exist.jsonl");
        let writer = RawEventLogWriter::new(
            false,
            Some(path.to_string_lossy().to_string()),
            RawEventLogContext::default(),
        );
        writer.set_session_id("irrelevant");
        writer.write("session.startOrResume", Some(serde_json::json!({"x": 1})));
        assert!(
            !path.exists(),
            "a disabled writer must never create its file"
        );
    }

    #[test]
    fn enabled_writer_with_no_path_never_touches_the_filesystem() {
        let writer = RawEventLogWriter::new(true, None, RawEventLogContext::default());
        assert!(
            !writer.is_enabled(),
            "enabled without a resolved path must not actually be enabled"
        );
    }

    #[test]
    fn enabled_writer_appends_one_jsonl_record_per_write_kind_sessionid_and_payload_survive() {
        let dir =
            std::env::temp_dir().join(format!("raw-event-log-enabled-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("events.jsonl");
        let writer = RawEventLogWriter::new(
            true,
            Some(path.to_string_lossy().to_string()),
            RawEventLogContext {
                run_id: "run-1".to_string(),
                tab_id: "tab-1".to_string(),
                window_id: 7,
                workspace_path: "/tmp/workspace".to_string(),
                initial_session_id: "tab-1".to_string(),
            },
        );
        writer.write("session.startOrResume", None);
        writer.set_session_id("session-123");
        writer.write("process.spawned", Some(serde_json::json!({"pid": 42})));

        let contents =
            std::fs::read_to_string(&path).expect("log file must exist after an enabled write");
        let lines: Vec<&str> = contents.lines().collect();
        assert_eq!(
            lines.len(),
            4,
            "each new session id gets one header before its first record"
        );

        let first: Value = serde_json::from_str(lines[0]).expect("line 1 must be valid JSON");
        assert_eq!(first["kind"], "session.header");
        assert_eq!(first["runID"], "run-1");
        assert_eq!(first["tabID"], "tab-1");
        assert_eq!(first["windowID"], 7);
        assert_eq!(first["workspacePath"], "/tmp/workspace");
        assert_eq!(first["sessionID"], "tab-1");

        let second: Value = serde_json::from_str(lines[1]).expect("line 2 must be valid JSON");
        assert_eq!(second["kind"], "session.startOrResume");
        assert_eq!(second["sessionID"], "tab-1");
        assert!(
            second.get("payload").is_none(),
            "a None payload must not add a payload key at all"
        );

        let third: Value = serde_json::from_str(lines[2]).expect("line 3 must be valid JSON");
        assert_eq!(third["kind"], "session.header");
        assert_eq!(third["sessionID"], "session-123");

        let fourth: Value = serde_json::from_str(lines[3]).expect("line 4 must be valid JSON");
        assert_eq!(fourth["kind"], "process.spawned");
        assert_eq!(fourth["sessionID"], "session-123");
        assert_eq!(fourth["payload"]["pid"], 42);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
