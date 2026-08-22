use super::{Candidate, Query, score_matches_batch};

fn candidate<'a>(name: &'a [u8], path: &'a [u8]) -> Candidate<'a> {
    Candidate {
        name,
        path,
        name_lower: name,
        path_lower: path,
    }
}

fn query(raw: &[u8], has_slash: bool, is_wildcard: bool) -> Query<'_> {
    Query {
        raw,
        lowered: raw,
        has_slash,
        is_wildcard,
    }
}

fn score(candidate: Candidate<'_>, query: Query<'_>, threshold: f64) -> i32 {
    score_matches_batch(&[candidate], query, threshold)[0]
}

#[test]
fn pins_exact_and_extension_exact_tiers() {
    assert_eq!(
        score(
            candidate(b"readme.md", b"docs/readme.md"),
            query(b"readme.md", false, false),
            0.8
        ),
        1000
    );
    assert_eq!(
        score(
            candidate(b"other", b"docs/readme.md"),
            query(b"docs/readme.md", true, false),
            0.8
        ),
        950
    );
    assert_eq!(
        score(
            candidate(b"readme.md", b"docs/readme.md"),
            query(b"readme", false, false),
            0.8
        ),
        1000
    );
}

#[test]
fn pins_prefix_tiers() {
    assert_eq!(
        score(
            candidate(b"reader.txt", b"docs/reader.txt"),
            query(b"read", false, false),
            0.8
        ),
        900
    );
    assert_eq!(
        score(
            candidate(b"other", b"src/apple/file"),
            query(b"src/app", true, false),
            0.8
        ),
        875
    );
    assert_eq!(
        score(
            candidate(b"other", b"src/utility/file"),
            query(b"util", false, false),
            0.8
        ),
        850
    );
}

#[test]
fn pins_contains_tiers_and_backslash_exception() {
    assert_eq!(
        score(
            candidate(b"readme.md", b"docs/readme.md"),
            query(b"adme", false, false),
            0.8
        ),
        750
    );
    assert_eq!(
        score(
            candidate(b"other", b"src/app/service.swift"),
            query(b"app/ser", true, false),
            0.8
        ),
        700
    );
    assert_eq!(
        score(
            candidate(b"other", b"dir/xneedle/file"),
            query(b"needle", false, false),
            0.8
        ),
        750
    );
    assert_eq!(
        score(
            candidate(b"other", b"dir\\xneedle\\file"),
            query(b"needle", false, false),
            0.8
        ),
        750
    );
}

#[test]
fn pins_wildcard_tier_and_pathname_rules() {
    assert_eq!(
        score(
            candidate(b"Widget.SWIFT", b"src/Widget.SWIFT"),
            query(b"*.swift", false, true),
            0.8
        ),
        650
    );
    assert_eq!(
        score(
            candidate(b"main.c", b"src/main.c"),
            query(b"src/?ain.[ch]", true, true),
            0.8
        ),
        650
    );
    assert_eq!(
        score(
            candidate(b"main.swift", b"deep/src/main.swift"),
            query(b"**/*.swift", true, true),
            0.8
        ),
        650
    );
    assert_eq!(
        score(
            candidate(b"other", b"src/deep/main.swift"),
            query(b"src/*.swift", true, true),
            0.8
        ),
        0
    );
}

#[test]
fn pins_wildcard_escapes_and_ascii_classes() {
    assert_eq!(
        score(
            candidate(b"file*.txt", b"file*.txt"),
            query(br"file\*.txt", false, true),
            0.8
        ),
        650
    );
    assert_eq!(
        score(
            candidate(b"A7x.txt", b"A7x.txt"),
            query(b"[[:upper:]][[:digit:]]?.txt", false, true),
            0.8
        ),
        650
    );
}

#[test]
fn pins_fuzzy_filename_and_component_tiers() {
    assert_eq!(
        score(
            candidate(b"readme", b"docs/readme"),
            query(b"reedme", false, false),
            0.8
        ),
        500
    );
    assert_eq!(
        score(
            candidate(b"other", b"src/utility/file"),
            query(b"utxlity", false, false),
            0.85
        ),
        450
    );
    assert_eq!(
        score(
            candidate(b"other", b"src/utility/file"),
            query(b"zzzz", false, false),
            0.8
        ),
        0
    );
}

#[test]
fn pins_fuzzy_threshold_edges_and_minimum_query_length() {
    let edge = 5.0 / 6.0;
    assert_eq!(
        score(
            candidate(b"abcdef", b"dir/other"),
            query(b"abcxef", false, false),
            edge
        ),
        500
    );
    assert_eq!(
        score(
            candidate(b"abcdef", b"dir/other"),
            query(b"abcxef", false, false),
            edge + f64::EPSILON
        ),
        0
    );
    assert_eq!(
        score(
            candidate(b"ax", b"dir/other"),
            query(b"ab", false, false),
            0.0
        ),
        0
    );
}

#[test]
fn preserves_batch_order_and_does_not_resolve_ties() {
    let candidates = [
        candidate(b"zeta.txt", b"long/path/zeta.txt"),
        candidate(b"zed.txt", b"z/zed.txt"),
        candidate(b"other.txt", b"other.txt"),
    ];
    assert_eq!(
        score_matches_batch(&candidates, query(b"ze", false, false), 0.8),
        vec![900, 900, 0]
    );
}

#[test]
fn pins_empty_and_degenerate_inputs() {
    assert!(score_matches_batch(&[], query(b"x", false, false), 0.8).is_empty());
    assert!(
        score_matches_batch(&[candidate(b"x", b"x")], query(b"", false, false), 0.8).is_empty()
    );
    assert_eq!(
        score_matches_batch(&[candidate(b"", b"")], query(b"x", false, false), 0.8),
        vec![0]
    );
    assert_eq!(
        score_matches_batch(
            &[candidate(b"x", b"x")],
            query(b"\0ignored", false, false),
            0.8
        ),
        vec![0]
    );
}

#[test]
fn uses_supplied_lowercase_bytes_as_authoritative() {
    let candidate = Candidate {
        name: "Ä.swift".as_bytes(),
        path: "src/Ä.swift".as_bytes(),
        name_lower: "ä.swift".as_bytes(),
        path_lower: "src/ä.swift".as_bytes(),
    };
    let query = Query {
        raw: "Ä.SWIFT".as_bytes(),
        lowered: "ä.swift".as_bytes(),
        has_slash: false,
        is_wildcard: false,
    };
    assert_eq!(score(candidate, query, 0.8), 1000);
}

#[test]
fn pins_non_ascii_c_locale_wildcard_and_utf8_fuzzy_behavior() {
    let wildcard_query = Query {
        raw: "ä.*".as_bytes(),
        lowered: "ä.*".as_bytes(),
        has_slash: false,
        is_wildcard: true,
    };
    assert_eq!(
        score(
            Candidate {
                name: "Ä.swift".as_bytes(),
                path: "src/Ä.swift".as_bytes(),
                name_lower: "Ä.swift".as_bytes(),
                path_lower: "src/Ä.swift".as_bytes(),
            },
            wildcard_query,
            0.8
        ),
        0
    );
    assert_eq!(
        score(
            candidate("café".as_bytes(), b"docs/other"),
            query(b"cafe", false, false),
            0.8
        ),
        500
    );
}

#[test]
fn pins_long_filename_extension_buffer_boundary() {
    let name = format!("{}.txt", "a".repeat(1024));
    let raw_query = "a".repeat(1024);
    assert_eq!(
        score(
            candidate(name.as_bytes(), b"docs/long"),
            query(raw_query.as_bytes(), false, false),
            0.8
        ),
        900
    );
}

#[test]
fn pins_long_path_component_buffer_boundary() {
    let path = format!("{}/target", "a".repeat(2047));
    assert_eq!(
        score(
            candidate(b"other", path.as_bytes()),
            query(b"targot", false, false),
            0.8
        ),
        0
    );
}

#[test]
fn pins_long_input_dice_fuzzy_path() {
    let name = format!("{}x", "a".repeat(64));
    let raw_query = format!("{}y", "a".repeat(64));
    assert_eq!(
        score(
            candidate(name.as_bytes(), b"docs/other"),
            query(raw_query.as_bytes(), false, false),
            0.95
        ),
        500
    );
}
