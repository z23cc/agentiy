#![no_main]

use agentry_proto::agent_host::v1::{ClientMessage, HostMessage};
use agentry_proto::agent_host::{
    decode_client_message, decode_frame, decode_host_message, decode_snapshot,
    frame_payload_length,
};
use libfuzzer_sys::fuzz_target;

// ADR-0011 P2 (docs/spec/agent-session-host-v1-design.md §5.2): the agent-host-v1 Unix-socket
// frame -- `u32 big-endian length || protobuf payload` -- is decoded by the host and by every
// client from bytes written by another process. The length prefix, the payload cap, the trailing
// bytes rule, the top-level `oneof` presence check, and the snapshot chunk cap must all fail closed
// and never panic; the same functions are the only decode path behind the FFI exports.
fuzz_target!(|input: &[u8]| {
    let _ = frame_payload_length(input);
    let _ = decode_client_message(input);
    let _ = decode_host_message(input);
    let _: Result<ClientMessage, _> = decode_frame(input);
    let _: Result<HostMessage, _> = decode_frame(input);
    let _ = decode_snapshot(input);
});
