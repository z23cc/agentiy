use agentry_runtime::{
    EngineKind, LeafCancellation, MatchPolicy, RegexSearchMode, RegexSearchRequest, RepairKind,
    RuntimeIdentity, SearchError, SearchLeaf,
};

fn identity() -> RuntimeIdentity {
    RuntimeIdentity::new(1, "1".repeat(32), "2".repeat(64), "3".repeat(64)).unwrap()
}

fn request(pattern: &str, subject: &str) -> RegexSearchRequest {
    RegexSearchRequest {
        mode: RegexSearchMode::Content,
        pattern: pattern.into(),
        subject: subject.into(),
        case_insensitive: false,
        whole_word: false,
        multiline_anchors: true,
        collect_matches: true,
        max_collected_matches: None,
        context_lines: 0,
        match_policy: MatchPolicy::ContentFullBuffer,
        cancellation: LeafCancellation::new(identity()),
    }
}

#[test]
fn search_lines_line_endings_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let result = leaf
        .search_regex(&request(r"(?m)^.*$", "a\r\n\rb\n\nlast\n"))
        .unwrap();
    let ranges: Vec<_> = result.hits.iter().map(|hit| hit.line_byte_range).collect();
    assert_eq!(result.diagnostic.line_count, 5);
    assert_eq!(
        ranges
            .iter()
            .map(|range| (range.start, range.end))
            .collect::<Vec<_>>(),
        vec![(0, 1), (3, 3), (4, 5), (6, 6), (7, 11)]
    );
}

#[test]
fn search_lines_boundaries_and_context_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let mut empty = request("x", "");
    empty.context_lines = 2;
    let result = leaf.search_regex(&empty).unwrap();
    assert_eq!(result.diagnostic.line_count, 0);
    assert!(result.hits.is_empty());

    let mut contextual = request("target", "before\ntarget\nafter");
    contextual.context_lines = 1;
    let hit = &leaf.search_regex(&contextual).unwrap().hits[0];
    assert_eq!(hit.line_number, 1);
    assert_eq!(
        (hit.match_byte_range.start, hit.match_byte_range.end),
        (7, 13)
    );
    assert_eq!(hit.context_before_byte_ranges.len(), 1);
    assert_eq!(hit.context_after_byte_ranges.len(), 1);
}

#[test]
fn regex_utf8_case_word_and_byte_ranges_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let mut value = request("ångström", "zero\nÅNGSTRÖM plus\nångströms");
    value.case_insensitive = true;
    value.whole_word = true;
    let result = leaf.search_regex(&value).unwrap();
    assert_eq!(result.hits.len(), 1);
    assert_eq!(result.hits[0].line_number, 1);
    assert_eq!(
        (
            result.hits[0].match_byte_range.start,
            result.hits[0].match_byte_range.end
        ),
        (5, 15)
    );
}

#[test]
fn regex_zero_length_cross_line_and_dedup_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let zero = leaf.search_regex(&request(r"(?=a)", "aa\nnone")).unwrap();
    assert_eq!(zero.hits.len(), 1);
    assert_eq!(
        (
            zero.hits[0].match_byte_range.start,
            zero.hits[0].match_byte_range.end
        ),
        (0, 0)
    );

    let cross = leaf.search_regex(&request("a\\nb", "a\nb\nend")).unwrap();
    assert_eq!(cross.hits[0].line_number, 0);
    assert_eq!(
        (
            cross.hits[0].match_byte_range.start,
            cross.hits[0].match_byte_range.end
        ),
        (0, 3)
    );
}

#[test]
fn search_count_collection_cap_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let mut value = request("x", "x\nx\nx");
    value.max_collected_matches = Some(1);
    let result = leaf.search_regex(&value).unwrap();
    assert_eq!(result.matching_line_count, 3);
    assert_eq!(result.hits.len(), 1);

    value.collect_matches = false;
    let result = leaf.search_regex(&value).unwrap();
    assert_eq!(result.matching_line_count, 3);
    assert!(result.hits.is_empty());
}

#[test]
fn regex_repair_and_complexity_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let compressed = leaf.search_regex(&request(r"\\(", "(")).unwrap();
    assert_eq!(
        compressed.diagnostic.repair_kind,
        RepairKind::DoubleEscapeCompression
    );

    let normalized = leaf.search_regex(&request(")", ")")).unwrap();
    assert_eq!(normalized.diagnostic.repair_kind, RepairKind::Normalise);

    let too_long = "a".repeat(2_001);
    assert_eq!(
        leaf.search_regex(&request(&too_long, "a")).unwrap_err(),
        SearchError::PatternTooComplex
    );
    assert_eq!(
        leaf.search_regex(&request("^(a+)+$", "a")).unwrap_err(),
        SearchError::PatternTooComplex
    );
}

#[test]
fn regex_syntax_and_lookbehind_errors_v1() {
    let leaf = SearchLeaf::new().unwrap();
    assert_eq!(
        leaf.search_regex(&request("[", "x")).unwrap_err(),
        SearchError::UnmatchedBrackets
    );
    assert_eq!(
        leaf.search_regex(&request("(", "x")).unwrap_err(),
        SearchError::UnmatchedParentheses
    );
    assert_eq!(
        leaf.search_regex(&request("*", "x")).unwrap_err(),
        SearchError::InvalidQuantifier
    );
    assert_eq!(
        leaf.search_regex(&request("(?<=.*)x", "x")).unwrap_err(),
        SearchError::VariableLengthLookbehind
    );
    assert_eq!(
        leaf.search_regex(&request(r"\q", "x")).unwrap_err(),
        SearchError::InvalidEscape
    );
}

#[test]
fn five_fast_plans_and_general_pcre2_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let cases = [
        (
            "word",
            "a word here",
            true,
            RegexSearchMode::Content,
            EngineKind::AsciiWholeWord,
        ),
        (
            r"^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*",
            " final class Thing",
            false,
            RegexSearchMode::Content,
            EngineKind::AnchoredDeclaration,
        ),
        (
            r"\bTODO-\d{3}:\s+Search\w*",
            "TODO-123: SearchLeaf",
            false,
            RegexSearchMode::Content,
            EngineKind::AsciiMarker,
        ),
        (
            r"^import\b",
            "import Foundation",
            false,
            RegexSearchMode::Content,
            EngineKind::AnchoredLinePrefilter,
        ),
        (
            r".*\.(swift|rs)$",
            "src/main.swift",
            false,
            RegexSearchMode::Path,
            EngineKind::PathSuffix,
        ),
    ];
    for (pattern, subject, whole_word, mode, engine) in cases {
        let mut fast = request(pattern, subject);
        fast.whole_word = whole_word;
        fast.mode = mode;
        fast.match_policy = if mode == RegexSearchMode::Path {
            MatchPolicy::ShortPath
        } else {
            MatchPolicy::ContentLine
        };
        let fast_result = leaf.search_regex(&fast).unwrap();
        assert_eq!(fast_result.diagnostic.engine, engine, "pattern={pattern}");
        if engine != EngineKind::AnchoredLinePrefilter {
            assert_eq!(
                fast_result.diagnostic.jit_status,
                agentry_runtime::JitStatus::NotApplicable
            );
        }
        assert_eq!(fast_result.matching_line_count, 1, "pattern={pattern}");

        let mut general = fast.clone();
        general.pattern = format!("(?:{})", general.pattern);
        general.whole_word = false;
        general.match_policy = if mode == RegexSearchMode::Path {
            MatchPolicy::ShortPath
        } else {
            MatchPolicy::ContentFullBuffer
        };
        let general_result = leaf.search_regex(&general).unwrap();
        assert_eq!(general_result.diagnostic.engine, EngineKind::Pcre2);
        assert_eq!(fast_result.hits, general_result.hits, "pattern={pattern}");
    }
}

#[test]
fn prepared_batch_single_subject_is_byte_identical_v1() {
    let single_leaf = SearchLeaf::new().unwrap();
    let batch_leaf = SearchLeaf::new().unwrap();
    let value = request("target", "before\ntarget\nafter");
    let single = single_leaf.search_regex(&value).unwrap();
    let batch = batch_leaf
        .search_regex_batch(std::slice::from_ref(&value))
        .unwrap();
    assert_eq!(batch, vec![single]);
}

fn compact_ranges(words: &[u64]) -> Vec<(u64, u64)> {
    words
        .chunks_exact(2)
        .map(|word| (word[0], word[1]))
        .collect()
}

#[test]
fn compact_batch_layout_empty_and_sparse_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let requests = [request("target", ""), request("target", "a\ntarget\nz")];
    let result = leaf.search_regex_batch_compact(&requests).unwrap();
    assert_eq!(result.subject_summaries.len(), 2);
    assert_eq!(result.subject_summaries[0].line_range_count, 0);
    assert_eq!(result.subject_summaries[0].hit_count, 0);
    assert_eq!(result.subject_summaries[1].line_range_start, 0);
    assert_eq!(result.subject_summaries[1].line_range_count, 1);
    assert_eq!(result.subject_summaries[1].hit_start, 0);
    assert_eq!(result.subject_summaries[1].hit_count, 1);
    assert_eq!(compact_ranges(&result.line_range_words), vec![(2, 8)]);
    assert_eq!(result.hit_words, vec![1, 0, 2, 8, 0, 0]);
}

#[test]
fn compact_batch_layout_overlapping_context_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let mut value = request("hit", "a\nb\nhit\nd\nhit\nf");
    value.context_lines = 2;
    let result = leaf.search_regex_batch_compact(&[value]).unwrap();
    let summary = &result.subject_summaries[0];
    assert_eq!(summary.line_range_count, 6);
    assert_eq!(compact_ranges(&result.line_range_words).len(), 6);
    assert_eq!(result.hit_words, vec![2, 2, 4, 7, 2, 2, 4, 4, 10, 13, 2, 1]);
}

#[test]
fn compact_batch_collection_cap_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let mut value = request("x", "x\nx\nx");
    value.max_collected_matches = Some(1);
    let result = leaf.search_regex_batch_compact(&[value]).unwrap();
    let summary = &result.subject_summaries[0];
    assert_eq!(summary.matching_line_count, 3);
    assert_eq!(summary.hit_count, 1);
    assert_eq!(summary.diagnostic.matching_line_count, 3);
    assert_eq!(summary.diagnostic.hit_count, 1);
    assert_eq!(result.hit_words.len(), 6);
}

#[test]
fn compact_batch_subject_alignment_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let requests = [
        request("hit", "hit"),
        request("hit", "none"),
        request("hit", "before\nhit"),
    ];
    let result = leaf.search_regex_batch_compact(&requests).unwrap();
    assert_eq!(result.subject_summaries.len(), requests.len());
    assert_eq!(result.subject_summaries[0].hit_count, 1);
    assert_eq!(result.subject_summaries[1].hit_count, 0);
    assert_eq!(result.subject_summaries[2].hit_count, 1);
    assert_eq!(result.subject_summaries[0].hit_start, 0);
    assert_eq!(result.subject_summaries[1].hit_start, 1);
    assert_eq!(result.subject_summaries[2].hit_start, 1);
    assert_eq!(result.subject_summaries[2].line_range_start, 1);
}

#[test]
fn regex_cache_v1() {
    let leaf = SearchLeaf::new().unwrap();
    let first = leaf.search_regex(&request("cache", "cache")).unwrap();
    let second = leaf.search_regex(&request("cache", "cache")).unwrap();
    assert!(!first.diagnostic.cache_hit);
    assert!(second.diagnostic.cache_hit);

    for index in 0..300 {
        let pattern = format!("cache-{index:03}");
        leaf.search_regex(&request(&pattern, &pattern)).unwrap();
    }
    let evicted = leaf.search_regex(&request("cache", "cache")).unwrap();
    assert!(
        !evicted.diagnostic.cache_hit,
        "the 256-entry cache bound must evict the oldest entry"
    );
}
