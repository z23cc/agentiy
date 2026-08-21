#![no_main]

use std::sync::OnceLock;

use agentry_runtime::{
    LeafCancellation, MatchPolicy, RegexSearchMode, RegexSearchRequest, RuntimeIdentity, SearchLeaf,
};
use libfuzzer_sys::fuzz_target;

const MAX_PATTERN_BYTES: usize = 256;
const MAX_SUBJECT_BYTES: usize = 16 * 1024;
const MAX_COLLECTED_MATCHES: u32 = 256;
const MAX_CONTEXT_LINES: u16 = 8;

fn cancellation() -> LeafCancellation {
    let identity = RuntimeIdentity::new(1, "1".repeat(32), "2".repeat(64), "3".repeat(64))
        .expect("static fuzz identity must be valid");
    LeafCancellation::new(identity)
}

fn bounded_text(input: &[u8], limit: usize) -> String {
    String::from_utf8_lossy(&input[..input.len().min(limit)]).into_owned()
}

fuzz_target!(|input: &[u8]| {
    if input.len() < 4 {
        return;
    }

    let options = input[0];
    let pattern_len = usize::from(input[1]).min(MAX_PATTERN_BYTES);
    let pattern_end = 2usize.saturating_add(pattern_len).min(input.len());
    let pattern = bounded_text(&input[2..pattern_end], MAX_PATTERN_BYTES);
    let subject = bounded_text(&input[pattern_end..], MAX_SUBJECT_BYTES);
    let requested_limit = u32::from(input[2]) + 1;

    static LEAF: OnceLock<Option<SearchLeaf>> = OnceLock::new();
    let Some(leaf) = LEAF.get_or_init(|| SearchLeaf::new().ok()) else {
        return;
    };
    let request = RegexSearchRequest {
        mode: if options & 1 == 0 {
            RegexSearchMode::Content
        } else {
            RegexSearchMode::Path
        },
        pattern,
        subject,
        case_insensitive: options & 2 != 0,
        whole_word: options & 4 != 0,
        multiline_anchors: options & 8 != 0,
        collect_matches: options & 16 != 0,
        max_collected_matches: Some(requested_limit.min(MAX_COLLECTED_MATCHES)),
        context_lines: u16::from(input[3]).min(MAX_CONTEXT_LINES),
        match_policy: match (options >> 5) % 3 {
            0 => MatchPolicy::ContentFullBuffer,
            1 => MatchPolicy::ContentLine,
            _ => MatchPolicy::ShortPath,
        },
        cancellation: cancellation(),
    };
    let _ = leaf.search_regex(&request);
});
