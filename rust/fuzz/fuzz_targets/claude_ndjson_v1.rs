#![no_main]

//! `claude-ndjson-v1` (design §3.4/§9, contract §6): joins the existing corpus fuzz set. Drives
//! the full P6-3 pipeline -- framer -> codec -> D-1 recovery dispatch -> translator -- over
//! arbitrary bytes. The property under test is crash/panic-freedom (INV-P6-2's transport-plane
//! reasoning depends on the framer/codec never panicking on adversarial input, since a panic on
//! the stdout reader thread would be worse than the deadlock hazard §4.3 is designed around); this
//! target asserts no such input exists, and it runs no `unwrap`/`expect` in the loop below that
//! isn't itself the point (the frozen corpus in `agent_claude::tests::corpus` covers documented
//! semantics; this target covers "arbitrary bytes must never crash").

use agentry_runtime::agent_claude::{InboundMessage, LineFramer, Translator, decode_line, recover_invalid_json_line};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: &[u8]| {
    let Some((&flag_byte, rest)) = input.split_first() else {
        return;
    };
    let turn_in_flight = flag_byte & 1 != 0;

    let mut framer = LineFramer::default();
    let mut lines: Vec<Vec<u8>> = Vec::new();
    framer.feed(rest, |_diagnostic| {}, |line| lines.push(line));
    framer.flush(|line| lines.push(line));

    let mut translator = Translator::default();
    for line in &lines {
        match decode_line(line) {
            Ok(Some(InboundMessage::StreamPayload(payload))) => {
                let _ = translator.parse_stream_payload(&payload);
            }
            Ok(Some(_)) | Ok(None) => {}
            Err(_) => {
                let _ = recover_invalid_json_line(line, turn_in_flight, |_diagnostic| {});
            }
        }
    }
});
