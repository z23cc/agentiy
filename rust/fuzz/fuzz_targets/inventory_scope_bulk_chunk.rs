#![no_main]

use agentry_runtime::inventory_scope::decode_bulk_chunk;
use libfuzzer_sys::fuzz_target;

// P4-4: fail-closed decode of the `inventory-scope-v1` bulk-chunk wire (the interning-heaviest
// message kind, and the one Swift actually encodes for `inventoryPushBulkChunk`). Exercises the
// intern-pool index space specifically (out-of-range/overlapping/self-referential string ranges)
// in addition to the generic truncation/oversize surface every message kind shares.
fuzz_target!(|input: &[u8]| {
    let _ = decode_bulk_chunk(input);
});
