#![no_main]

use agentry_runtime::inventory_scope::decode_delta_event;
use libfuzzer_sys::fuzz_target;

// P4-4: fail-closed decode of the `inventory-scope-v1` delta-event wire -- the hot-path ingest
// blob (`InventoryDeltaCommandV1.event_bytes`). Broadest section-count surface of any message
// kind (9 sections before the shared string pool), so it's the target most likely to catch a
// section-ordering or stride bug via mutation.
fuzz_target!(|input: &[u8]| {
    let _ = decode_delta_event(input);
});
