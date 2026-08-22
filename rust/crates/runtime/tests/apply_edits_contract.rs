use agentry_runtime::apply_edits::*;

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
        source_kind: ApplySourceKind::DecodedUtf8,
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
fn single_matcher_miss_preserves_invalid_params_message() {
    let error = apply_subject(&request(
        "present\n",
        ApplyMode::Single {
            operation: operation("missing", "replacement", false),
        },
    ))
    .unwrap_err();
    assert_eq!(
        error,
        ApplyError::InvalidParams("search block not found in file".into())
    );
}

#[test]
fn reversed_two_line_selector_returns_error_instead_of_underflowing() {
    let error = apply_subject(&request(
        "header\ntarget\n",
        ApplyMode::Single {
            operation: operation("target\nheader", "replacement", false),
        },
    ))
    .unwrap_err();
    assert!(matches!(error, ApplyError::InvalidParams(_)));
}

#[test]
fn fuzzy_selector_past_file_end_returns_invalid_params() {
    let error = apply_subject(&request(
        "hello world\n",
        ApplyMode::Single {
            operation: operation("hello worle\nmissing selector line", "replacement", false),
        },
    ))
    .unwrap_err();
    assert_eq!(
        error,
        ApplyError::InvalidParams("matched search block range exceeds file bounds".into())
    );
}

#[test]
fn empty_search_is_invalid() {
    for search in ["", "\n", " \t\r\n"] {
        let error = apply_subject(&request(
            "content\n",
            ApplyMode::Single {
                operation: operation(search, "replacement", true),
            },
        ))
        .unwrap_err();
        assert_eq!(
            error,
            ApplyError::InvalidParams("search cannot be empty for replace operations".into())
        );
    }
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
fn chained_replace_all_rejects_before_unbounded_match_allocation() {
    let original = "a".repeat(8 * 1024);
    let expansion = "a".repeat(8);
    let error = apply_subject(&request(
        &original,
        ApplyMode::Batch {
            operations: vec![
                operation("a", &expansion, true),
                operation("a", &expansion, true),
                operation("a", &expansion, true),
            ],
        },
    ))
    .unwrap_err();
    assert_eq!(
        error,
        ApplyError::InvalidParams("too many replacements (maximum 100000 per operation)".into())
    );
}

#[test]
fn replace_all_rejects_estimated_result_over_64_mib_before_materializing() {
    let original = "a".repeat(8 * 1024);
    let expansion = "a".repeat(8 * 1024 + 1);
    let error = apply_subject(&request(
        &original,
        ApplyMode::Single {
            operation: operation("a", &expansion, true),
        },
    ))
    .unwrap_err();
    assert_eq!(
        error,
        ApplyError::InvalidParams("result size limit exceeded (maximum 64 MiB)".into())
    );
}

#[test]
fn rewrite_rejects_diff_with_too_many_changed_lines() {
    let original = "old\n".repeat(100_001);
    let replacement = "new\n".repeat(100_001);
    let error = apply_subject(&request(&original, ApplyMode::Rewrite { replacement })).unwrap_err();
    assert_eq!(
        error,
        ApplyError::InvalidParams(
            "diff too large (maximum 64 MiB working/rendered data and 100000 lines per side)"
                .into()
        )
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
    assert_eq!(
        result.outcomes.as_ref().unwrap()[0].error.as_deref(),
        Some(
            "Search block matches multiple locations (lines 1, 2). Please make the block more specific or use the replace_all parameter to replace all occurrences."
        )
    );
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
fn single_literal_replacement_converts_to_file_indentation_style() {
    let result = apply_subject(&request(
        "func f() {\n\tlet a = 1\n\tlet b = 2\n}\n",
        ApplyMode::Single {
            operation: operation("\tlet a = 1", "    let a = 10", false),
        },
    ))
    .unwrap();
    assert_eq!(
        result.updated_text,
        "func f() {\n\tlet a = 10\n\tlet b = 2\n}\n"
    );

    let result = apply_subject(&request(
        "func f() {\n    let a = 1\n    let b = 2\n}\n",
        ApplyMode::Single {
            operation: operation("    let a = 1", "\tlet a = 10", false),
        },
    ))
    .unwrap();
    assert_eq!(
        result.updated_text,
        "func f() {\n    let a = 10\n    let b = 2\n}\n"
    );
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
    assert!(
        !result
            .updated_text
            .lines()
            .any(|line| line.starts_with('\t'))
    );

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
        (original_a.as_bytes(), None, &result_a),
        (original_b.as_bytes(), None, &result_b),
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
    let mut compact = encode_compact_batch(&[(original.as_bytes(), None, &result)]).unwrap();
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
    let (edits, chunks) = generate_diff(original, updated).unwrap();
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
        let (edits, chunks) = generate_diff(original, updated).unwrap();
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
    let mut compact = encode_compact_batch(&[(b"a\n", None, &a), (b"b\n", None, &b)]).unwrap();
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
    let compact = encode_compact_batch(&[(original.as_bytes(), None, &single)]).unwrap();
    assert!(!compact.subject_summaries[0].outcomes_present);
    assert!(validate_compact_batch(&compact, &[original.as_bytes()]).is_ok());
    single.outcomes = Some(Vec::new());
    assert!(encode_compact_batch(&[(original.as_bytes(), None, &single)]).is_ok());
}

// -------------------------------------------------------------------------------------------
// TD-3 (design `docs/designs/textdecode-policy-v2-2026-08-22.md` §6.1/§5.3.1 mechanism 2/D-6):
// `ApplySourceKind::Raw` -- the ladder-6 (headless `agentry-mcp` apply-edits) additive path.
// -------------------------------------------------------------------------------------------

fn raw_request(original: Vec<u8>, mode: ApplyMode) -> ApplySubjectRequest {
    ApplySubjectRequest {
        path_label: "file.txt".into(),
        original,
        source_kind: ApplySourceKind::Raw,
        mode,
        verbose: true,
        include_tool_card_unified_diff: true,
    }
}

#[test]
fn raw_legacy_shift_jis_bytes_that_todays_headless_host_hard_rejects_decode_and_edit_cleanly_d6() {
    // Mirrors the byte-level TD-2 characterization
    // (`ladder6_legacy_charset_bytes_decode_cleanly_though_todays_host_hard_rejects_them`) one
    // layer up: this proves the *host-facing* `apply_subject` entry point, not just `textdecode`
    // in isolation, accepts genuinely non-UTF-8 raw bytes and edits them successfully -- content
    // `DirectHeadlessFileEditHost.readText` hard-rejects today (`String(data:encoding:.utf8)`
    // returns nil for these exact bytes).
    let sample = "これはラダー6のShift-JISテキストです。";
    assert!(std::str::from_utf8(sample.as_bytes()).is_ok());
    let (raw, _, unmappable) = encoding_rs::SHIFT_JIS.encode(sample);
    assert!(!unmappable);
    let raw = raw.into_owned();
    assert!(
        std::str::from_utf8(&raw).is_err(),
        "fixture must be genuinely non-UTF-8 for this to prove anything"
    );
    let result = apply_subject(&raw_request(
        raw,
        ApplyMode::Single {
            operation: operation("テキスト", "テスト", false),
        },
    ))
    .expect("raw legacy-charset apply_edits must succeed, not hard-reject");
    assert_eq!(result.status, ApplyStatus::Success);
    assert!(result.updated_text.contains("テスト"));
    assert!(!result.updated_text.contains("テキスト"));
}

#[test]
fn raw_lossy_utf16_lone_surrogate_blocks_write_back_not_silently_overwrites_r8() {
    // §5.3.1 mechanism 2 / R8: a genuinely-unmappable raw source must refuse write-back rather
    // than silently substituting U+FFFD and letting a save overwrite unrecoverable bytes.
    let mut raw = vec![0xFFu8, 0xFE]; // UTF-16 LE BOM
    raw.extend_from_slice(&0xD800u16.to_le_bytes()); // lone high surrogate, no low surrogate pair
    let outcome = apply_subject(&raw_request(
        raw,
        ApplyMode::Rewrite {
            replacement: "anything".into(),
        },
    ));
    match outcome {
        Err(ApplyError::LossyDecodeBlocksWriteBack(_)) => {}
        other => panic!("expected LossyDecodeBlocksWriteBack, got {other:?}"),
    }
}

#[test]
fn raw_decoded_utf8_source_kind_is_byte_identical_to_the_pre_td3_strict_path() {
    // The default `DecodedUtf8` kind must remain provably untouched: decoding the *same* valid
    // UTF-8 bytes through either kind produces an identical result (GUI apply-edits' path is
    // not supposed to change until TD-5).
    let original = "line one\nline two\n";
    let strict = apply_subject(&request(
        original,
        ApplyMode::Single {
            operation: operation("one", "ONE", false),
        },
    ))
    .unwrap();
    let raw = apply_subject(&raw_request(
        original.as_bytes().to_vec(),
        ApplyMode::Single {
            operation: operation("one", "ONE", false),
        },
    ))
    .unwrap();
    assert_eq!(strict.updated_text, raw.updated_text);
    assert_eq!(strict.byte_edits, raw.byte_edits);
}

#[test]
fn raw_utf8_bom_source_round_trips_through_apply_subject_preserving_the_bom() {
    // The d1f84aa5 regression class (design §2): a leading UTF-8 BOM must survive apply-edits
    // end to end for a `Raw` source, not be silently stripped on decode.
    let mut raw = vec![0xEF, 0xBB, 0xBF];
    raw.extend_from_slice("hello\nworld\n".as_bytes());
    let result = apply_subject(&raw_request(
        raw,
        ApplyMode::Single {
            operation: operation("world", "WORLD", false),
        },
    ))
    .unwrap();
    assert!(result.updated_text.starts_with('\u{FEFF}'));
    assert_eq!(result.updated_text, "\u{FEFF}hello\nWORLD\n");
}

#[test]
fn raw_compact_batch_echoes_the_decoded_original_text_not_the_raw_request_bytes() {
    // TD-3 §6.1: the wire-protocol correctness gap this revision closes -- Swift's compact-
    // result validator cannot re-derive "original" from raw request bytes for `Raw` subjects
    // (the buffer `byte_edits`/`chunks` offsets are relative to is `textdecode`'s *output*,
    // which can differ in byte length from the raw input for legacy charsets). Prove the
    // service-level pipeline (`ApplyEditsService::apply_batch`, the same one the FFI handler
    // calls) actually encodes a distinct, valid `original_text_string_index` referencing the
    // decoded text -- not `OPTIONAL_SENTINEL`, and not the raw bytes reinterpreted as UTF-8.
    let sample = "こんにちは世界";
    let (raw, _, unmappable) = encoding_rs::SHIFT_JIS.encode(sample);
    assert!(!unmappable);
    let raw = raw.into_owned();
    let raw_len = raw.len();
    let request = ApplyEditsBatchRequestV1 {
        contract_version: APPLY_EDITS_CONTRACT_VERSION_V1,
        subjects: vec![raw_request(
            raw,
            ApplyMode::Rewrite {
                replacement: sample.to_owned(),
            },
        )],
    };
    let compact = ApplyEditsService.apply_batch(request).unwrap();
    let summary = &compact.subject_summaries[0];
    // Decoded Shift-JIS text is longer in UTF-8 bytes than the raw Shift-JIS input for this
    // sample -- proves the echoed index cannot be reinterpreting `input_byte_count`/raw bytes.
    assert_ne!(summary.original_text_string_index, OPTIONAL_SENTINEL);
    assert_eq!(summary.input_byte_count, raw_len as u64);
    let string_start = usize::try_from(summary.string_start).unwrap();
    let index = usize::try_from(summary.original_text_string_index).unwrap();
    assert!(index >= string_start);
    let row = &compact.string_range_words[(index - string_start) * STRING_RANGE_STRIDE
        ..(index - string_start) * STRING_RANGE_STRIDE + STRING_RANGE_STRIDE];
    let (start, end) = (row[0] as usize, row[1] as usize);
    let echoed = std::str::from_utf8(&compact.utf8_blob[start..end]).unwrap();
    assert_eq!(echoed, sample);
}
