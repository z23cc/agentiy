#![no_main]

use agentry_runtime::apply_edits::{
    APPLY_EDITS_CONTRACT_VERSION_V1, ApplyEditsBatchRequestV1, ApplyEditsService, ApplyMode,
    ApplyOperation, ApplySubjectRequest,
};
use libfuzzer_sys::fuzz_target;

const MAX_ORIGINAL_BYTES: usize = 8 * 1024;
const MAX_OPERATIONS: usize = 8;
const MAX_SEARCH_BYTES: usize = 256;
const MAX_REPLACEMENT_BYTES: usize = 256;

fn text(input: &[u8], limit: usize) -> String {
    String::from_utf8_lossy(&input[..input.len().min(limit)]).into_owned()
}

fuzz_target!(|input: &[u8]| {
    if input.len() < 4 {
        return;
    }
    let options = input[0];
    let search_len = usize::from(input[1]).min(MAX_SEARCH_BYTES);
    let replacement_len = usize::from(input[2]).min(MAX_REPLACEMENT_BYTES);
    let search_end = 4usize.saturating_add(search_len).min(input.len());
    let replacement_end = search_end
        .saturating_add(replacement_len)
        .min(input.len());
    let search = text(&input[4..search_end], MAX_SEARCH_BYTES);
    let replacement = text(&input[search_end..replacement_end], MAX_REPLACEMENT_BYTES);
    let original = input[replacement_end..]
        .iter()
        .copied()
        .take(MAX_ORIGINAL_BYTES)
        .collect::<Vec<_>>();

    let operation_count = (usize::from(input[3]) % MAX_OPERATIONS).saturating_add(1);
    let operations = (0..operation_count)
        .map(|index| ApplyOperation {
            search: search.clone(),
            replace: if index & 1 == 0 {
                replacement.clone()
            } else {
                search.clone()
            },
            replace_all: options & 4 != 0,
        })
        .collect::<Vec<_>>();
    let mode = match options & 3 {
        0 => ApplyMode::Rewrite {
            replacement: replacement.clone(),
        },
        1 => ApplyMode::Single {
            operation: operations[0].clone(),
        },
        _ => ApplyMode::Batch { operations },
    };
    let request = ApplyEditsBatchRequestV1 {
        contract_version: if options & 8 == 0 {
            APPLY_EDITS_CONTRACT_VERSION_V1
        } else {
            u16::from(input[3])
        },
        subjects: vec![ApplySubjectRequest {
            path_label: "fuzz.txt".to_owned(),
            original,
            mode,
            verbose: options & 16 != 0,
            include_tool_card_unified_diff: options & 32 != 0,
        }],
    };
    let _ = ApplyEditsService.apply_batch(request);
});
