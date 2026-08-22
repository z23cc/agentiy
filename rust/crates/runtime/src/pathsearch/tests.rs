//! Parity fixtures for the `pathsearch` engine port.
//!
//! The primary fixture in [`recovery_fixture_matches_swift_expectations`] is transcribed
//! byte-for-byte (paths, patterns, limits, and expected index sequences) from
//! `Tests/RepoPromptTests/WorkspaceContext/Search/PathSearchIndexRecoveryTests.swift`'s
//! `testSearchMatchesFilenameSubpathTokensAndPublishesDeterministicRankMetadata`, which exercises
//! the *actual* C engine via the Swift wrapper — so a match here is direct behavioral parity
//! evidence, not just an assertion about this Rust port's own design.
//!
//! The remaining tests target specific decision-table entries from `glob.rs`/`index.rs`/
//! `engine.rs` (prefix/suffix scanning quirks, ASCII-only case folding, the 20-term space-AND
//! cap, `**` vs `*` path-separator handling, projected-search ordering/cancellation, and the
//! empty-index/zero-limit edge cases the Swift wrapper otherwise special-cases before ever
//! calling into C).

use super::engine::{PathSearchCancellation, ProjectedSearchOutcome};
use super::glob::{Mode, Token, decompose};
use super::index::PathSearchIndex;

fn indices(index: &PathSearchIndex, pattern: &str, limit: usize) -> Vec<usize> {
    index
        .find(pattern, limit)
        .into_iter()
        .map(|m| m.index)
        .collect()
}

#[test]
fn recovery_fixture_matches_swift_expectations() {
    let paths: Vec<String> = [
        "/Volumes/Repo/Sources/Zeta/Widget.swift",
        "Sources/βeta/Search/Unicode.swift",
        "Sources/App/Search/Alpha.swift",
        "Sources/App/Search/Alpha.swift",
        "Sources/App/Features/SearchPanel.swift",
        "docs/absolute-search-notes.md",
        "Worktree/Sources/CompositeCatalogTarget.rpfixture\n/Volumes/Worktree/Sources/CompositeCatalogTarget.rpfixture",
    ]
    .iter()
    .map(|s| (*s).to_string())
    .collect();

    let index = PathSearchIndex::new(&paths);
    assert_eq!(index.len(), 7);

    assert_eq!(indices(&index, "Alpha.swift", 10), vec![2, 3]);
    assert_eq!(indices(&index, "Alpha.swift", 1), vec![2]);
    assert_eq!(indices(&index, "*.swift", 3), vec![0, 4, 2]);
    assert_eq!(indices(&index, "*.swift", 20), vec![0, 4, 2, 3, 1]);
    assert_eq!(indices(&index, "App Search", 20), vec![4, 2, 3]);
    assert_eq!(indices(&index, "βeta", 20), vec![1]);
    assert_eq!(indices(&index, "Volumes Widget", 20), vec![0]);
    assert_eq!(indices(&index, "CompositeCatalogTarget", 20), vec![6]);
    assert_eq!(indices(&index, "swift", 0), Vec::<usize>::new());

    for candidate in index.find("Alpha.swift", 10) {
        assert_eq!(candidate.tie_break_key, paths[candidate.index]);
        assert_eq!(candidate.score, 1);
    }
}

#[test]
fn empty_index_returns_no_matches_without_panicking() {
    let index = PathSearchIndex::new(&[]);
    assert_eq!(index.len(), 0);
    assert!(index.is_empty());
    assert_eq!(indices(&index, "anything", 20), Vec::<usize>::new());
    assert_eq!(indices(&index, "*.swift", 20), Vec::<usize>::new());
    assert!(index.path(0).is_none());
}

#[test]
fn zero_limit_yields_no_matches_even_when_candidates_exist() {
    let paths = vec!["a.txt".to_string(), "b.txt".to_string()];
    let index = PathSearchIndex::new(&paths);
    assert_eq!(indices(&index, "txt", 0), Vec::<usize>::new());
}

#[test]
fn empty_pattern_matches_every_path() {
    let paths = vec![
        "a.txt".to_string(),
        "nested/b.rs".to_string(),
        "".to_string(),
    ];
    let index = PathSearchIndex::new(&paths);
    assert_eq!(indices(&index, "", 100), vec![2, 0, 1]);
}

#[test]
fn empty_pattern_workspace_index_keys_follow_c_lexical_order_and_limit() {
    let paths = vec![
        "ShadowIndex/src/Zeta.swift\n/tmp/ShadowIndex/src/Zeta.swift".to_string(),
        "ShadowIndex/README.md\n/tmp/ShadowIndex/README.md".to_string(),
        "ShadowIndex/src/Alpha.swift\n/tmp/ShadowIndex/src/Alpha.swift".to_string(),
        "ShadowIndex/src/Alpha.swift\n/tmp/ShadowIndex/src/Alpha.swift".to_string(),
    ];
    let index = PathSearchIndex::new(&paths);

    assert_eq!(indices(&index, "", 0), Vec::<usize>::new());
    assert_eq!(indices(&index, "", 1), vec![1]);
    assert_eq!(indices(&index, "", 3), vec![1, 2, 3]);
    assert_eq!(indices(&index, "", 50), vec![1, 2, 3, 0]);
}

#[test]
fn pattern_of_only_spaces_matches_every_path_via_zero_terms() {
    let paths = vec!["a.txt".to_string(), "b.rs".to_string()];
    let index = PathSearchIndex::new(&paths);
    let mut got = indices(&index, "   ", 100);
    got.sort_unstable();
    assert_eq!(got, vec![0, 1]);
}

#[test]
fn space_and_terms_beyond_twentieth_are_silently_dropped() {
    // 20 short terms all present as a contiguous run in the candidate path, plus a 21st term
    // that is absent. The C engine's `term_count < 20` cap means the 21st term is never even
    // parsed into the terms list, so the candidate must still match.
    let present_terms: Vec<String> = (1..=20).map(|n| format!("t{n:02}")).collect();
    let path = present_terms.join("");
    let mut pattern = present_terms.join(" ");
    pattern.push_str(" absent-term-not-in-path");

    let paths = vec![path];
    let index = PathSearchIndex::new(&paths);
    assert_eq!(indices(&index, &pattern, 10), vec![0]);
}

#[test]
fn ascii_only_case_folding_does_not_fold_non_ascii_bytes() {
    let paths = vec!["notes/café.txt".to_string()];
    let index = PathSearchIndex::new(&paths);

    // ASCII portion folds normally; the already-matching non-ASCII "é" bytes pass through as an
    // exact byte comparison, so this still matches.
    assert_eq!(indices(&index, "CAFé", 10), vec![0]);

    // "CAFÉ" (uppercase É, U+00C9, distinct UTF-8 bytes from lowercase é/U+00E9) must NOT match:
    // a Unicode-aware case fold would equate É and é, but the C engine's C-locale REG_ICASE (and
    // this port's ASCII-only fold) never does.
    assert_eq!(indices(&index, "CAFÉ", 10), Vec::<usize>::new());

    // Plain ASCII "CAFE" also doesn't match "café" (different character entirely, no accent
    // equivalence in either direction).
    assert_eq!(indices(&index, "CAFE", 10), Vec::<usize>::new());
}

#[test]
fn foo_star_prefix_bound_is_case_sensitive_even_though_match_is_case_insensitive() {
    // The forward-order prefix bound narrows candidates with a raw, un-folded `strncmp` against
    // the pattern's literal prefix, *before* the case-insensitive `[^/]*` match ever runs. So a
    // pattern's literal prefix is effectively case-sensitive even though `*`/`?` bodies are not.
    let paths = vec!["Foobar".to_string(), "foobar".to_string()];
    let index = PathSearchIndex::new(&paths);
    assert_eq!(indices(&index, "Foo*", 10), vec![0]);
    assert_eq!(indices(&index, "foo*", 10), vec![1]);
}

#[test]
fn swift_suffix_bound_is_case_sensitive_even_though_match_is_case_insensitive() {
    // Same asymmetry as the prefix case, on the reversed-order suffix bound.
    let paths = vec!["a.swift".to_string(), "b.SWIFT".to_string()];
    let index = PathSearchIndex::new(&paths);
    assert_eq!(indices(&index, "*.swift", 10), vec![0]);
    assert_eq!(indices(&index, "*.SWIFT", 10), vec![1]);
}

#[test]
fn prefix_bound_nul_pads_paths_shorter_than_the_literal_prefix() {
    // "fo" is shorter than the 3-byte literal prefix "foo" and must be excluded via the
    // `strncmp`-style NUL-pad in `strncmp_prefix`, not merely fail the later regex match.
    let paths = vec!["fo".to_string(), "foo".to_string(), "foobar".to_string()];
    let index = PathSearchIndex::new(&paths);
    let mut got = indices(&index, "foo*", 10);
    got.sort_unstable();
    assert_eq!(got, vec![1, 2]);
}

#[test]
fn suffix_bound_nul_pads_paths_shorter_than_the_literal_suffix() {
    // "t" is shorter than the 3-byte literal suffix "txt" and must be excluded via the
    // NUL-pad in `strncmp_suffix`.
    let paths = vec!["t".to_string(), "x.txt".to_string()];
    let index = PathSearchIndex::new(&paths);
    assert_eq!(indices(&index, "*.txt", 10), vec![1]);
}

#[test]
fn double_star_spans_path_separators_but_single_star_does_not() {
    let paths = vec!["src/a/b/foo.rs".to_string(), "src/a/foo.rs".to_string()];
    let index = PathSearchIndex::new(&paths);

    let mut double = indices(&index, "src/**/foo.rs", 10);
    double.sort_unstable();
    assert_eq!(double, vec![0, 1]);

    assert_eq!(indices(&index, "src/*/foo.rs", 10), vec![1]);
}

#[test]
fn decompose_prefix_and_suffix_scan_matches_c_comment_example() {
    // The C source's own comment: for "*.swift" the desired suffix is "swift", not ".swift",
    // because '.' is itself a metachar and is found scanning backward before '*' is.
    let parts = decompose("*.swift");
    assert_eq!(parts.prefix, b"".to_vec());
    assert_eq!(parts.suffix, b"swift".to_vec());
    assert!(parts.is_wildcard);
}

#[test]
fn decompose_anchored_prefix_pattern_has_non_empty_literal_prefix() {
    let parts = decompose("foo*bar");
    assert_eq!(parts.prefix, b"foo".to_vec());
    assert_eq!(parts.suffix, b"bar".to_vec());
}

#[test]
fn decompose_leading_single_star_emits_redundant_star_tokens() {
    // Documented C quirk: the leading-anchor decision and the body loop both process pattern[0]
    // when it is a single '*' (not '**'), producing StarAny followed immediately by
    // StarNonSlash. Harmless (StarAny already subsumes StarNonSlash) but intentionally ported.
    let parts = decompose("*foo");
    let Mode::Glob(tokens) = parts.mode else {
        panic!("expected glob mode")
    };
    assert_eq!(
        tokens,
        vec![
            Token::StarAny,
            Token::StarNonSlash,
            Token::Lit(b'f'),
            Token::Lit(b'o'),
            Token::Lit(b'o')
        ]
    );
}

#[test]
fn literal_pattern_is_wrapped_in_leading_and_trailing_star_any() {
    let parts = decompose("config.json");
    assert!(!parts.is_wildcard);
    let Mode::Glob(tokens) = parts.mode else {
        panic!("expected glob mode")
    };
    assert_eq!(tokens.first(), Some(&Token::StarAny));
    assert_eq!(tokens.last(), Some(&Token::StarAny));
    // '.' is escaped to a literal token, not treated as "any char", even though it's a regex
    // metachar in the C-built ERE.
    assert!(tokens.contains(&Token::Lit(b'.')));
}

#[test]
fn newline_embedded_index_keys_match_literally_and_via_glob() {
    // Mirrors the workspace's displayPath + "\n" + fullPath key shape.
    let paths = vec!["Display/Name.swift\n/abs/Display/Name.swift".to_string()];
    let index = PathSearchIndex::new(&paths);
    assert_eq!(indices(&index, "Name.swift\n/abs", 10), vec![0]);
    // Only the pattern's very first byte gets the "leading free-start" `.*` treatment; every
    // other `*` (unless doubled into `**`) translates to `[^/]*`, which cannot cross the `/`
    // bytes in "/abs/Display". `**` is required here to span the absolute-prefix segment.
    assert_eq!(indices(&index, "**.swift\n**.swift", 10), vec![0]);
    assert_eq!(indices(&index, "*.swift\n*.swift", 10), Vec::<usize>::new());
}

#[test]
fn projected_find_matches_equivalent_full_index_search_across_queries_and_limits() {
    let relative_paths: Vec<String> = vec![
        "A.swift".to_string(),
        "Sources/Space Target.swift".to_string(),
        "Sources/Ångström.swift".to_string(),
        "Sources/line\nbreak.swift".to_string(),
        "Added 文件.swift".to_string(),
    ];
    let display_prefix = "Projected Root/";
    let absolute_prefix = "/tmp/Projected Root/";

    let relative_index = PathSearchIndex::new(&relative_paths);
    let full_paths: Vec<String> = relative_paths
        .iter()
        .map(|p| format!("{display_prefix}{p}\n{absolute_prefix}{p}"))
        .collect();
    let full_index = PathSearchIndex::new(&full_paths);

    let queries = [
        "A",
        "*.swift",
        "Space Target",
        "Projected Root",
        absolute_prefix,
        "Ångström",
        "文件",
        "line\nbreak",
        "Sources *.swift",
        "",
    ];
    for query in queries {
        for &limit in &[0usize, 1, 3, 100] {
            let expected: Vec<usize> = full_index
                .find(query, limit)
                .into_iter()
                .map(|m| m.index)
                .collect();
            let ProjectedSearchOutcome::Completed(actual, stats) =
                relative_index.projected_find(query, display_prefix, absolute_prefix, limit, None)
            else {
                panic!("expected completed outcome for query={query:?}");
            };
            let actual_indices: Vec<usize> = actual.iter().map(|m| m.index).collect();
            assert_eq!(actual_indices, expected, "query={query:?} limit={limit}");
            assert!(actual.iter().all(|m| m.score == 1));
            assert!(!stats.cancelled);
            assert_eq!(stats.examined_count, relative_paths.len());
        }
    }
}

#[test]
fn projected_empty_pattern_matches_full_workspace_key_ordering() {
    let relative_paths = vec![
        "src/Zeta.swift".to_string(),
        "README.md".to_string(),
        "src/Alpha.swift".to_string(),
        "src/Alpha.swift".to_string(),
    ];
    let index = PathSearchIndex::new(&relative_paths);

    for (limit, expected) in [
        (0, vec![]),
        (1, vec![1]),
        (3, vec![1, 2, 3]),
        (50, vec![1, 2, 3, 0]),
    ] {
        let ProjectedSearchOutcome::Completed(matches, _) =
            index.projected_find("", "ShadowIndex/", "/tmp/ShadowIndex/", limit, None)
        else {
            panic!("expected completed outcome");
        };
        assert_eq!(
            matches
                .into_iter()
                .map(|matched| matched.index)
                .collect::<Vec<_>>(),
            expected
        );
    }
}

#[test]
fn projected_find_reports_bounded_heap_peak_and_scratch_bytes() {
    let relative_paths: Vec<String> = (0..500)
        .map(|n| format!("Sources/{n:05} Target.swift"))
        .collect();
    let display_prefix = "Large Root/";
    let absolute_prefix = "/tmp/Large Root/";
    let index = PathSearchIndex::new(&relative_paths);

    let ProjectedSearchOutcome::Completed(matches, stats) =
        index.projected_find("*.swift", display_prefix, absolute_prefix, 7, None)
    else {
        panic!("expected completed outcome");
    };
    assert_eq!(matches.len(), 7);
    assert_eq!(stats.examined_count, 500);
    assert_eq!(stats.matched_count, 500);
    assert_eq!(stats.heap_peak_count, 7);
    let maximum_relative_bytes = relative_paths.iter().map(String::len).max().unwrap_or(0);
    assert_eq!(
        stats.scratch_bytes,
        display_prefix.len() + absolute_prefix.len() + maximum_relative_bytes * 2 + 2
    );
}

#[test]
fn projected_find_cancelled_before_starting_examines_nothing() {
    let relative_paths: Vec<String> = (0..1000).map(|n| format!("File{n}.swift")).collect();
    let index = PathSearchIndex::new(&relative_paths);
    let cancellation = PathSearchCancellation::new();
    cancellation.cancel();

    let outcome = index.projected_find("*.swift", "Root/", "/tmp/Root/", 300, Some(&cancellation));
    let ProjectedSearchOutcome::Cancelled(stats) = outcome else {
        panic!("expected cancelled outcome");
    };
    assert!(stats.cancelled);
    assert_eq!(stats.examined_count, 0);
    assert_eq!(stats.heap_peak_count, 0);
}

#[test]
fn projected_find_not_cancelled_completes_normally() {
    let relative_paths: Vec<String> = (0..10).map(|n| format!("File{n}.swift")).collect();
    let index = PathSearchIndex::new(&relative_paths);
    let cancellation = PathSearchCancellation::new();

    let outcome = index.projected_find("*.swift", "Root/", "/tmp/Root/", 300, Some(&cancellation));
    let ProjectedSearchOutcome::Completed(matches, stats) = outcome else {
        panic!("expected completed outcome");
    };
    assert_eq!(matches.len(), 10);
    assert!(!stats.cancelled);
}

/// Regression for the phase-2 scratch-buffer hoist: a `MatchScratch` reused across calls with
/// DIFFERENT token/subject lengths (longer-then-shorter, and vice versa) must never leak a stale
/// `true` bit from a previous, longer DP row into a shorter one -- `matches_with_scratch` clears
/// and resizes both rows on every call, but this pins that behavior against regression and
/// cross-checks every call against the non-reused `matches` convenience wrapper.
#[test]
fn glob_matches_with_scratch_reuse_does_not_leak_state_across_calls() {
    use super::glob::{MatchScratch, matches, matches_with_scratch};

    let long = decompose("*.composite-target.swift");
    let Mode::Glob(long_tokens) = long.mode else {
        panic!("expected glob mode");
    };
    let short = decompose("a?");
    let Mode::Glob(short_tokens) = short.mode else {
        panic!("expected glob mode");
    };

    let mut scratch = MatchScratch::new();

    // Warm the scratch buffers with a long token sequence over a long subject.
    assert!(matches_with_scratch(
        b"a.composite-target.swift",
        &long_tokens,
        &mut scratch
    ));

    // A much shorter token/subject pair reused on the same scratch must not see stale `true`
    // bits left over from the longer previous call.
    assert!(matches_with_scratch(b"ax", &short_tokens, &mut scratch));
    assert!(!matches_with_scratch(b"b", &short_tokens, &mut scratch));
    assert!(!matches_with_scratch(b"", &short_tokens, &mut scratch));
    assert_eq!(
        matches_with_scratch(b"ax", &short_tokens, &mut scratch),
        matches(b"ax", &short_tokens)
    );

    // And back to the long pair again, reusing the now-shrunk scratch.
    assert!(matches_with_scratch(
        b"a.composite-target.swift",
        &long_tokens,
        &mut scratch
    ));
    assert!(!matches_with_scratch(
        b"a.composite-target.SWIFT-nope",
        &long_tokens,
        &mut scratch
    ));
    assert_eq!(
        matches_with_scratch(b"a.composite-target.swift", &long_tokens, &mut scratch),
        matches(b"a.composite-target.swift", &long_tokens)
    );
}
