use std::sync::Arc;
use std::thread;

use agentry_runtime::{
    LeafCancellation, MatchPolicy, PathClause, PathFilterRequest, PathSnapshot, RegexSearchMode,
    RegexSearchRequest, RuntimeIdentity, SearchLeaf,
};
use proptest::prelude::*;

const PROPERTY_SEED: &str = "search-leaf-v1-seed-0x5eedcafe";

fn identity() -> RuntimeIdentity {
    RuntimeIdentity::new(1, "d".repeat(32), "e".repeat(64), "f".repeat(64)).unwrap()
}

#[test]
fn cancellation_idempotent_and_concurrent_v1() {
    let cancellation = Arc::new(LeafCancellation::new(identity()));
    let threads: Vec<_> = (0..16)
        .map(|_| {
            let cancellation = Arc::clone(&cancellation);
            thread::spawn(move || {
                for _ in 0..1_000 {
                    cancellation.cancel();
                    cancellation.close();
                }
            })
        })
        .collect();
    for handle in threads {
        handle.join().unwrap();
    }
    assert!(cancellation.is_cancelled());
    assert!(cancellation.is_closed());
}

#[test]
fn path_cancelled_prefix_has_exact_visited_count_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let cancellation = LeafCancellation::new(identity());
    cancellation.cancel();
    let result = leaf.filter_paths(&PathFilterRequest {
        snapshots: vec![PathSnapshot {
            standardized_full_path: "/a".into(),
            standardized_relative_path: "a".into(),
            standardized_root_path: "/".into(),
            client_display_path: "a".into(),
        }],
        clauses: vec![PathClause::LegacyPrefix {
            candidate_lower: "a".into(),
        }],
        case_insensitive: true,
        cancellation,
    });
    assert!(result.cancelled);
    assert_eq!(result.visited_snapshot_count, 0);
    assert!(result.matched_snapshot_indices.is_empty());
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, failure_persistence: None, ..ProptestConfig::default() })]

    #[test]
    fn randomized_hits_are_ordered_unique_and_in_bounds_v1(
        lines in prop::collection::vec("[A-Za-z0-9_ ]{0,32}", 0..32),
        needle in "[A-Za-z0-9_]{1,8}",
    ) {
        let seed = PROPERTY_SEED;
        let subject = lines.join("\n");
        let leaf = SearchLeaf::new().unwrap();
        let result = leaf.search_regex(&RegexSearchRequest {
            mode: RegexSearchMode::Content,
            pattern: needle,
            subject: subject.clone(),
            case_insensitive: true,
            whole_word: false,
            multiline_anchors: true,
            collect_matches: true,
            max_collected_matches: None,
            context_lines: 3,
            match_policy: MatchPolicy::ContentFullBuffer,
            cancellation: LeafCancellation::new(identity()),
        }).unwrap_or_else(|error| panic!("seed={seed} subject={subject:?} error={error}"));
        let mut previous = None;
        for hit in result.hits {
            prop_assert!(hit.match_byte_range.start <= hit.match_byte_range.end, "seed={seed}");
            prop_assert!(hit.match_byte_range.end <= subject.len() as u64, "seed={seed}");
            prop_assert!(previous.is_none_or(|line| line < hit.line_number), "seed={seed}");
            previous = Some(hit.line_number);
        }
    }
}
