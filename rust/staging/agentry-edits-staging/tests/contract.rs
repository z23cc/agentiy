use agentry_edits_staging::*;

fn operation(search: &str, replace: &str, replace_all: bool) -> ApplyOperation {
    ApplyOperation {
        search: search.into(),
        replace: replace.into(),
        replace_all,
    }
}

fn request(original: &str, mode: ApplyMode) -> ApplySubjectRequest {
    ApplySubjectRequest {
        path_label: "file.swift".into(),
        original: original.as_bytes().to_vec(),
        mode,
        verbose: true,
        include_tool_card_unified_diff: true,
    }
}

#[test]
fn rewrite_verbose_result_and_diff() {
    let result = apply_subject(&request(
        "old\n",
        ApplyMode::Rewrite {
            replacement: "new\n".into(),
        },
    ))
    .unwrap();
    assert_eq!(result.updated_text, "new\n");
    assert_eq!(result.status, ApplyStatus::Success);
    let diff = result.unified_diff.unwrap();
    assert!(diff.contains("--- a/file.swift") && diff.contains("-old") && diff.contains("+new"));
}

#[test]
fn escaped_search_fallback_is_c_style_and_conditional() {
    let result = apply_subject(&request(
        "let value = \"old\"\n",
        ApplyMode::Single {
            operation: operation(
                "let value = \\\"old\\\"\\n",
                "let value = \\\"new\\\"\\n",
                false,
            ),
        },
    ))
    .unwrap();
    assert_eq!(result.updated_text, "let value = \"new\"\n");

    let raw = apply_subject(&request(
        r#"literal\n stays"#,
        ApplyMode::Single {
            operation: operation(r#"literal\n"#, r#"raw\t"#, false),
        },
    ))
    .unwrap();
    assert_eq!(raw.updated_text, r#"raw\t stays"#);
}

#[test]
fn c_style_unknown_and_trailing_escape_are_preserved() {
    let result = apply_subject(&request(
        "x\\q\\\n",
        ApplyMode::Single {
            operation: operation("x\\q\\", "ok", false),
        },
    ))
    .unwrap();
    assert_eq!(result.updated_text, "ok\n");
}

#[test]
fn literal_ambiguity_and_replace_all_miss_messages() {
    let error = apply_subject(&request(
        "same\nsame\n",
        ApplyMode::Single {
            operation: operation("same", "new", false),
        },
    ))
    .unwrap_err();
    assert_eq!(error, ApplyError::InvalidParams("Search text matches multiple locations (lines 1, 2). Please make the search more specific or use replace_all=true.".into()));
    let error = apply_subject(&request(
        "present\n",
        ApplyMode::Single {
            operation: operation("missing", "new", true),
        },
    ))
    .unwrap_err();
    assert_eq!(
        error,
        ApplyError::InvalidParams(
            "search text not found in file (no literal matches for replace_all)".into()
        )
    );
}

#[test]
fn empty_batch_is_invalid() {
    let error =
        apply_subject(&request("x\n", ApplyMode::Batch { operations: vec![] })).unwrap_err();
    assert_eq!(
        error,
        ApplyError::InvalidParams("edits array cannot be empty".into())
    );
}

#[test]
fn batch_literal_fast_path_note_and_verbose_outcomes() {
    let result = apply_subject(&request(
        "let value = old\n",
        ApplyMode::Batch {
            operations: vec![operation("old", "new", false)],
        },
    ))
    .unwrap();
    assert_eq!(result.updated_text, "let value = new\n");
    assert_eq!(
        result.note.as_deref(),
        Some("Applied via exact literal replacement")
    );
    assert_eq!(result.outcomes.unwrap()[0].status, OutcomeStatus::Success);
}

#[test]
fn batch_escape_resolution_uses_original_text() {
    let result = apply_subject(&request(
        "a\nb\n",
        ApplyMode::Batch {
            operations: vec![
                operation("a\\n", "x\\n", false),
                operation("b\\n", "y\\n", false),
            ],
        },
    ))
    .unwrap();
    assert_eq!(result.updated_text, "x\ny\n");
}

#[test]
fn duplicate_search_blocks_advance_sequential_cursor() {
    let result = apply_subject(&request(
        "same\nsame\n",
        ApplyMode::Batch {
            operations: vec![
                operation("same", "first", false),
                operation("same", "second", false),
            ],
        },
    ))
    .unwrap();
    assert_eq!(result.updated_text, "first\nsecond\n");
    assert_eq!(result.status, ApplyStatus::Success);
    assert_eq!(result.outcomes.unwrap().len(), 2);
}

#[test]
fn batch_ambiguity_is_partial_and_later_edit_succeeds() {
    let result = apply_subject(&request(
        "same\nsame\ntail\n",
        ApplyMode::Batch {
            operations: vec![
                operation("same", "replacement", false),
                operation("tail", "done", false),
            ],
        },
    ))
    .unwrap();
    assert_eq!(result.updated_text, "same\nsame\ndone\n");
    assert_eq!(result.status, ApplyStatus::Partial);
    assert_eq!(result.edits_applied, 1);
    assert_eq!(result.outcomes.as_ref().unwrap()[0].error.as_deref(), Some(
        "Search block matches multiple locations (lines 1, 2). Please make the block more specific or use the replace_all parameter to replace all occurrences."
    ));
}

#[test]
fn batch_all_failed_preserves_original() {
    let result = apply_subject(&request(
        "present\n",
        ApplyMode::Batch {
            operations: vec![operation("missing", "replacement", false)],
        },
    ))
    .unwrap();
    assert_eq!(result.updated_text, "present\n");
    assert_eq!(result.status, ApplyStatus::Failed);
    assert_eq!(
        result.outcomes.unwrap()[0].error.as_deref(),
        Some(
            "search block not found in file (matches are exact, including whitespace/indentation)"
        )
    );
}

#[test]
fn replace_all_reuses_full_file_index_coordinates() {
    let original =
        "header\npadding\nTARGET\nremove\ngap one\ngap two\ngap three\nTARGET\nremove\nfooter\n";
    let result = apply_subject(&request(
        original,
        ApplyMode::Batch {
            operations: vec![operation("target\nremove", "replacement", true)],
        },
    ))
    .unwrap();
    assert_eq!(
        result.updated_text,
        "header\npadding\nreplacement\ngap one\ngap two\ngap three\nreplacement\nfooter\n"
    );
}

#[test]
fn replace_all_handles_positive_and_negative_line_deltas() {
    let positive = apply_subject(&request(
        "before\nsame\nmiddle\nsame\nafter\n",
        ApplyMode::Batch {
            operations: vec![operation("same", "replacement\nextra", true)],
        },
    ))
    .unwrap();
    assert_eq!(
        positive.updated_text,
        "before\nreplacement\nextra\nmiddle\nreplacement\nextra\nafter\n"
    );

    let negative = apply_subject(&request(
        "before\nsame\nremove\nmiddle\nsame\nremove\nafter\n",
        ApplyMode::Batch {
            operations: vec![operation("same\nremove", "replacement", true)],
        },
    ))
    .unwrap();
    assert_eq!(
        negative.updated_text,
        "before\nreplacement\nmiddle\nreplacement\nafter\n"
    );
}

#[test]
fn selector_size_gates_and_ambiguity() {
    let content: Vec<_> = ["a", "b", "c", "x", "y", "z", "a", "b", "c", "x", "y", "z"]
        .into_iter()
        .map(|line| process_line(line, true))
        .collect();
    let index = build_line_index(&content);
    let medium: Vec<_> = ["a", "b", "c", "different"]
        .into_iter()
        .map(|line| process_line(line, true))
        .collect();
    assert!(matches!(
        match_selector(&medium, &content, &index, 0, true),
        Err(MatchError::Ambiguous(_))
    ));
    let long: Vec<_> = ["a", "b", "wrong1", "wrong2", "y", "z"]
        .into_iter()
        .map(|line| process_line(line, true))
        .collect();
    assert_eq!(match_selector(&long, &content, &index, 0, false), Ok(0));
}

#[test]
fn fuzzy_budget_ignores_keys_before_minimum_match_index() {
    let mut content = Vec::new();
    for index in 0..401 {
        content.push(process_line(&format!("prefix unique {index}"), true));
    }
    content.push(process_line(
        "calculate totals for selected invoice line items",
        true,
    ));
    let index = build_line_index(&content);
    let selector = vec![process_line(
        "calculate total for selected invoice line items",
        true,
    )];
    assert_eq!(
        match_selector(&selector, &content, &index, 401, false),
        Ok(401)
    );
}

#[test]
fn leading_escaped_tab_promotion_and_tex_exemption() {
    let promoted = apply_subject(&request(
        "func f() {\n    old\n}\n",
        ApplyMode::Batch {
            operations: vec![operation("OLD", "\\tnew", false)],
        },
    ))
    .unwrap();
    assert!(promoted.updated_text.contains("        new"));

    let mut tex_request = request(
        "old\n",
        ApplyMode::Batch {
            operations: vec![operation("OLD", "\\tnew", false)],
        },
    );
    tex_request.path_label = "file.tex".into();
    let tex = apply_subject(&tex_request).unwrap();
    assert!(tex.updated_text.contains("\\tnew"));
}

#[test]
fn indentation_converts_tabs_spaces_and_absorbs_leaked_tab() {
    let spaces = "    if ready {\n        work()\n    }\n";
    let result = apply_subject(&request(
        spaces,
        ApplyMode::Batch {
            operations: vec![operation(
                "    IF READY {\n        WORK()\n    }",
                "\tif ready {\n\t\t\twork2()\n\t}",
                false,
            )],
        },
    ))
    .unwrap();
    assert_eq!(
        result.updated_text,
        "    if ready {\n            work2()\n    }\n"
    );
    assert!(!result
        .updated_text
        .lines()
        .any(|line| line.starts_with('\t')));

    let tabs = "\tswitch value {\n\t\tcase 1: break\n\t}\n";
    let result = apply_subject(&request(
        tabs,
        ApplyMode::Batch {
            operations: vec![operation(
                "\tSWITCH VALUE {\n\t\tCASE 1: BREAK\n\t}",
                "    switch value {\n        case 2: break\n    }",
                false,
            )],
        },
    ))
    .unwrap();
    assert_eq!(
        result.updated_text,
        "\tswitch value {\n\t\tcase 2: break\n\t}\n"
    );
}

#[test]
fn crlf_and_unicode_are_byte_exact() {
    let original = "é😀e\u{301}\r\nold\r\ntail";
    let result = apply_subject(&request(
        original,
        ApplyMode::Single {
            operation: operation("old", "新値", false),
        },
    ))
    .unwrap();
    assert_eq!(result.updated_text, "é😀e\u{301}\r\n新値\r\ntail");
    assert_eq!(
        apply_byte_edits(
            original.as_bytes(),
            result.updated_text.as_bytes(),
            &result.byte_edits
        )
        .unwrap(),
        result.updated_text.as_bytes()
    );
    assert_eq!(
        apply_chunks(original, &result.chunks).unwrap(),
        result.updated_text
    );
}

#[test]
fn compact_tables_reconstruct_bytes_and_chunks() {
    let original_a = "é😀e\u{301}\r\nold\r\ntail";
    let result_a = apply_subject(&request(
        original_a,
        ApplyMode::Single {
            operation: operation("old", "新値", false),
        },
    ))
    .unwrap();
    let original_b = "same\nsame\ntail\n";
    let result_b = apply_subject(&request(
        original_b,
        ApplyMode::Batch {
            operations: vec![
                operation("same", "replacement", false),
                operation("tail", "done", false),
            ],
        },
    ))
    .unwrap();
    let compact = encode_compact_batch(&[
        (original_a.as_bytes(), &result_a),
        (original_b.as_bytes(), &result_b),
    ])
    .unwrap();
    let rebuilt =
        validate_compact_batch(&compact, &[original_a.as_bytes(), original_b.as_bytes()]).unwrap();
    assert_eq!(rebuilt, vec![result_a.updated_text, result_b.updated_text]);
}

#[test]
fn compact_validator_rejects_malformed_ranges_and_flags() {
    let original = "old\n";
    let result = apply_subject(&request(
        original,
        ApplyMode::Rewrite {
            replacement: "new\n".into(),
        },
    ))
    .unwrap();
    let mut compact = encode_compact_batch(&[(original.as_bytes(), &result)]).unwrap();
    compact.chunk_words[7] = 1;
    assert_eq!(
        validate_compact_batch(&compact, &[original.as_bytes()]).unwrap_err(),
        "unknown v1 chunk flags"
    );
}

#[test]
fn myers_diff_and_chunk_apply_cover_disjoint_changes() {
    let original = "a\nb\nc\nd\n";
    let updated = "A\nb\nc\nD\n";
    let (edits, chunks) = generate_diff(original, updated);
    assert_eq!(edits.len(), 2);
    assert_eq!(chunks.len(), 2);
    assert_eq!(apply_chunks(original, &chunks).unwrap(), updated);
    assert_eq!(
        apply_byte_edits(original.as_bytes(), updated.as_bytes(), &edits).unwrap(),
        updated.as_bytes()
    );
}

#[test]
fn myers_handles_empty_create_delete_and_property_matrix() {
    for (original, updated) in [
        ("", "created\n"),
        ("deleted\n", ""),
        ("a\n", "a\nb\n"),
        ("a\nb\n", "b\n"),
        ("😀\r\nx", "😀\r\ny"),
        ("no final newline", "different final newline"),
    ] {
        let (edits, chunks) = generate_diff(original, updated);
        assert_eq!(apply_chunks(original, &chunks).as_deref(), Some(updated));
        assert_eq!(
            apply_byte_edits(original.as_bytes(), updated.as_bytes(), &edits).as_deref(),
            Some(updated.as_bytes())
        );
    }
}

#[test]
fn canonicalization_decodes_html_and_preserves_single_separator() {
    assert_eq!(
        canonical_key("public &quot;Value&quot; =").as_deref(),
        Some("\"value\"")
    );
    assert_eq!(canonical_key("name_value").as_deref(), Some("name_value"));
    assert_eq!(canonical_key("name___value").as_deref(), Some("name-value"));
}

#[test]
fn compact_validator_rejects_cross_subject_string_reference() {
    let a = apply_subject(&request(
        "a\n",
        ApplyMode::Rewrite {
            replacement: "A\n".into(),
        },
    ))
    .unwrap();
    let b = apply_subject(&request(
        "b\n",
        ApplyMode::Rewrite {
            replacement: "B\n".into(),
        },
    ))
    .unwrap();
    let mut compact = encode_compact_batch(&[(b"a\n", &a), (b"b\n", &b)]).unwrap();
    compact.subject_summaries[0].updated_text_string_index =
        compact.subject_summaries[1].string_start;
    assert_eq!(
        validate_compact_batch(&compact, &[b"a\n", b"b\n"]).unwrap_err(),
        "cross-subject string index"
    );
}

#[test]
fn compact_outcomes_present_distinguishes_nil() {
    let original = "old\n";
    let mut single = apply_subject(&request(
        original,
        ApplyMode::Single {
            operation: operation("old", "new", false),
        },
    ))
    .unwrap();
    assert!(single.outcomes.is_none());
    let compact = encode_compact_batch(&[(original.as_bytes(), &single)]).unwrap();
    assert!(!compact.subject_summaries[0].outcomes_present);
    assert!(validate_compact_batch(&compact, &[original.as_bytes()]).is_ok());
    single.outcomes = Some(Vec::new());
    assert!(encode_compact_batch(&[(original.as_bytes(), &single)]).is_ok());
}
