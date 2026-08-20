#![no_main]

use agentry_proto::Envelope;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: &[u8]| {
    let _ = Envelope::decode(input);
});
