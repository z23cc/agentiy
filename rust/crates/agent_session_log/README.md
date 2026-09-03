# agentry-agent-session-log

The append-only event log and derived snapshot files of an Agent Session Host session
(ADR-0011 decision 6; `docs/spec/agent-session-host-v1-design.md` §7.2). This crate is the **only**
implementation of the format: the Swift host shell and Swift clients reach it through the bounded
synchronous UniFFI exports in `rust/crates/ffi` (`AgentSessionLog.open / append / readFrom /
compact / close`), and the future Rust host binary (design §8 P7) links it directly.

## Frozen at end of P2

The header and record layout below, and the `agentry.agent_host.v1` messages they carry, are
frozen. An incompatible change requires bumping `SCHEMA_VERSION` (this crate) or
`PROTOCOL_VERSION` (`agentry-proto`), and an older runtime that opens a newer file refuses to load
it (`LogError::UnsupportedSchemaVersion`, ADR-0006 fail-closed). Additive changes are made in the
proto schema only, by adding fields.

## Files

Inside the existing `AgentSessions/` directory, per session (UUID rendered uppercase to sit beside
the Swift-written `AgentSession-<UUID>.json`):

| File | Nature | Writer |
|---|---|---|
| `AgentSession-<UUID>.events` | canonical, append-only | host |
| `AgentSession-<UUID>.snapshot` | derived, deletable, atomically replaced | host, at turn boundaries |

Use `events_file_name` / `snapshot_file_name` (or the `AgentHostProtocolV1.sessionLogFileNames`
export) rather than formatting the names by hand.

## Layout

```text
file header (24 bytes)
  0..4   magic          "AGSL" (events) | "AGSS" (snapshot)
  4..6   schema_version u16 big-endian, 1
  6..8   flags          u16 big-endian, 0 (unknown bits fail closed)
  8..24  session_id     16 raw UUID bytes
record (repeated in .events; exactly one in .snapshot)
  0..4   length         u32 big-endian byte length of payload
  4..8   crc32c         CRC-32C (Castagnoli) of payload
  8..    payload        encoded AgentSessionEvent (.events) | AgentSessionSnapshot (.snapshot)
```

The 1-based record ordinal is the event's `delivery_cursor`. A record payload is capped at
`MAXIMUM_RECORD_PAYLOAD_BYTES` (1 MiB frame cap minus 4 KiB) so every record also fits one wire
frame inside an `EventNotification`.

## Behaviour

- **Open** validates the header (magic, version, flags, session id), scans every record, and
  truncates a torn tail -- anything after the last complete, CRC-valid record -- reporting the lost
  range as `TornTail`. The log is never "repaired" from a snapshot.
- **Append** frames one `AgentSessionEvent`; `Durability::Sync` runs `fdatasync` before returning,
  `Durability::Deferred` leaves the sync to the next `sync` / `compact` / `close` (turn boundary).
  Which mode stream deltas use is decided by the `agentSessionHostV1.eventLogFsyncTurnLatency`
  SLO measurement (`rust/benchmarks/slo-v1.json`), not here.
- **Read** is positional (`read_from(cursor, max_records, max_bytes)`), never moves the append
  position, and always returns at least one record when any remain.
- **Compact** syncs the log, then writes the snapshot to a temporary file and renames it over the
  `.snapshot`; a snapshot claiming a cursor the log does not hold is rejected.
- **Load path** = latest valid `.snapshot` + replay from `through_cursor + 1`. A missing, corrupt,
  foreign, or stale snapshot means full replay from cursor 1; only a newer `schema_version` is an
  error.
- **Fork / import** are first records (`ForkedFrom`, `Imported`) in the proto schema; the crate
  treats them as ordinary events.

## Safety and testing

`#![forbid(unsafe_code)]`. Dependencies: `agentry-proto` and `prost` only (CRC-32C is in-crate).
Unit tests cover the header, record framing, CRC vectors, and session ids; `tests/session_log_v1.rs`
holds the frozen fixtures under `tests/fixtures/v1/` (empty, two-record, torn-tail, unknown-version
logs; valid, corrupt, unknown-version snapshots) plus property tests. The `rust/fuzz` target
`agent_session_log_frame_v1` fuzzes header and record decoding.

```bash
make dev-cargo-test CARGO_PACKAGE=session-log
./conductor cargo-fuzz --target agent_session_log_frame_v1 --seconds 60
```
