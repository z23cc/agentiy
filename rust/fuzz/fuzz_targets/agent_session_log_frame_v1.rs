#![no_main]

use agentry_agent_session_log::{
    FileHeader, FileKind, HEADER_BYTES, MAXIMUM_RECORD_PAYLOAD_BYTES,
    MAXIMUM_SNAPSHOT_PAYLOAD_BYTES, SessionId, decode_record,
};
use libfuzzer_sys::fuzz_target;

// ADR-0011 P2 (docs/spec/agent-session-host-v1-design.md §7.2): the session event log is the
// canonical persistence of a session and is read back after crashes, so its 24-byte file header
// and `length || crc32c || payload` record framing are decoded from bytes nobody trusts. Unknown
// schema versions and flags must be refused (ADR-0006), torn or corrupt records must be reported
// as defects, and nothing here may panic or over-read.
fuzz_target!(|input: &[u8]| {
    let session = SessionId::from_bytes([0x5A; 16]);
    let _ = FileHeader::decode(input, FileKind::Log, session);
    let _ = FileHeader::decode(input, FileKind::Snapshot, session);
    let _ = decode_record(input, MAXIMUM_RECORD_PAYLOAD_BYTES);
    let _ = decode_record(input, MAXIMUM_SNAPSHOT_PAYLOAD_BYTES);
    if input.len() >= HEADER_BYTES {
        // Walk a whole file body the way `SessionLog::open` does: stop at the first defect.
        let mut offset = HEADER_BYTES;
        while offset < input.len() {
            match decode_record(&input[offset..], MAXIMUM_RECORD_PAYLOAD_BYTES) {
                Ok((_, consumed)) => offset += consumed,
                Err(_) => break,
            }
        }
    }
    if let Ok(text) = std::str::from_utf8(input) {
        let _ = SessionId::parse(text);
    }
});
