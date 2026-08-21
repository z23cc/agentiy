use agentry_runtime::codemap::*;

fn decoded(language: CodeMapLanguage, source: &str) -> CodeMapSubjectRequestV1 {
    CodeMapSubjectRequestV1 {
        language_id: language.id(),
        source_kind: CodeMapSourceKind::Decoded,
        source_utf8: source.as_bytes().to_vec(),
    }
}

fn build(subjects: Vec<CodeMapSubjectRequestV1>) -> CompactCodeMapBatchResultV1 {
    CodeMapService
        .build_batch(CodeMapBatchRequestV1 {
            contract_version: CODEMAP_CONTRACT_VERSION_V1,
            subjects,
        })
        .unwrap()
}

#[test]
fn compact_encoder_uses_declared_strides() {
    let result = build(vec![decoded(
        CodeMapLanguage::Swift,
        "struct A { let value: String; func f() {} }",
    )]);
    assert_eq!(result.string_range_words.len() % STRING_RANGE_STRIDE, 0);
    assert_eq!(result.string_index_words.len() % STRING_INDEX_STRIDE, 0);
    assert_eq!(result.class_words.len() % CLASS_STRIDE, 0);
    assert_eq!(result.interface_words.len() % INTERFACE_STRIDE, 0);
    assert_eq!(result.alias_words.len() % ALIAS_STRIDE, 0);
    assert_eq!(result.function_words.len() % FUNCTION_STRIDE, 0);
    assert_eq!(result.parameter_words.len() % PARAMETER_STRIDE, 0);
    assert_eq!(result.property_words.len() % PROPERTY_STRIDE, 0);
    assert_eq!(result.enum_words.len() % ENUM_STRIDE, 0);
    assert_eq!(result.variable_words.len() % VARIABLE_STRIDE, 0);
}

#[test]
fn compact_encoder_subject_cursors_are_contiguous_and_exhaustive() {
    let result = build(vec![
        decoded(
            CodeMapLanguage::C,
            "#include <x.h>\nint f(void) { return 1; }\n",
        ),
        decoded(CodeMapLanguage::Python, "def f():\n    return 1\n"),
    ]);
    let mut cursors = [0u64; 11];
    for summary in &result.subject_summaries {
        let ranges = [
            summary.blob,
            summary.strings,
            summary.string_indices,
            summary.class_pool,
            summary.interface_pool,
            summary.alias_pool,
            summary.function_pool,
            summary.parameter_pool,
            summary.property_pool,
            summary.enum_pool,
            summary.variable_pool,
        ];
        for (cursor, range) in cursors.iter_mut().zip(ranges) {
            assert_eq!(range.start, *cursor);
            *cursor += range.count;
        }
    }
    assert_eq!(
        cursors,
        [
            result.utf8_blob.len() as u64,
            (result.string_range_words.len() / 2) as u64,
            result.string_index_words.len() as u64,
            (result.class_words.len() / 5) as u64,
            (result.interface_words.len() / 5) as u64,
            (result.alias_words.len() / 2) as u64,
            (result.function_words.len() / 6) as u64,
            (result.parameter_words.len() / 3) as u64,
            (result.property_words.len() / 2) as u64,
            (result.enum_words.len() / 3) as u64,
            (result.variable_words.len() / 3) as u64
        ]
    );
}

#[test]
fn compact_encoder_string_ranges_are_utf8_boundaries() {
    let result = build(vec![decoded(
        CodeMapLanguage::Swift,
        "struct Café { let 名称: String }",
    )]);
    for row in result.string_range_words.chunks_exact(2) {
        let start = row[0] as usize;
        let end = row[1] as usize;
        assert!(start <= end && end <= result.utf8_blob.len());
        assert!(std::str::from_utf8(&result.utf8_blob[start..end]).is_ok());
    }
}

#[test]
fn compact_encoder_nested_references_are_subject_local() {
    let result = build(vec![decoded(
        CodeMapLanguage::Swift,
        "struct A { let value: String; func f(x: Int) {} }",
    )]);
    let summary = &result.subject_summaries[0];
    for row in result.class_words.chunks_exact(CLASS_STRIDE) {
        assert!(
            row[1] >= summary.function_pool.start
                && row[1] + row[2] <= summary.function_pool.start + summary.function_pool.count
        );
        assert!(
            row[3] >= summary.property_pool.start
                && row[3] + row[4] <= summary.property_pool.start + summary.property_pool.count
        );
    }
}

#[test]
fn compact_encoder_decode_failure_has_no_artifact_rows() {
    let result = build(vec![CodeMapSubjectRequestV1 {
        language_id: CodeMapLanguage::C.id(),
        source_kind: CodeMapSourceKind::DecodeFailedUndecodable,
        source_utf8: Vec::new(),
    }]);
    let summary = &result.subject_summaries[0];
    assert_eq!(
        summary.outcome_tag,
        CodeMapOutcomeTag::DecodeFailedUndecodable
    );
    assert_eq!(
        summary.strings.count + summary.class_pool.count + summary.function_pool.count,
        0
    );
}

#[test]
fn compact_encoder_ready_no_symbols_has_no_rows() {
    let result = build(vec![decoded(CodeMapLanguage::C, "/* empty */\n")]);
    assert_eq!(
        result.subject_summaries[0].outcome_tag,
        CodeMapOutcomeTag::ReadyNoSymbols
    );
    assert!(result.string_range_words.is_empty());
}

#[test]
fn compact_service_rejects_unknown_contract_and_language() {
    let bad_version = CodeMapService.build_batch(CodeMapBatchRequestV1 {
        contract_version: 99,
        subjects: Vec::new(),
    });
    assert!(matches!(bad_version, Err(CodeMapError::InvalidRequest(_))));
    let bad_language = CodeMapService.build_batch(CodeMapBatchRequestV1 {
        contract_version: 1,
        subjects: vec![CodeMapSubjectRequestV1 {
            language_id: 99,
            source_kind: CodeMapSourceKind::Decoded,
            source_utf8: Vec::new(),
        }],
    });
    assert!(matches!(bad_language, Err(CodeMapError::InvalidRequest(_))));
}

#[test]
fn compact_service_rejects_nonempty_decode_failure_and_invalid_utf8() {
    let nonempty = CodeMapService.build_batch(CodeMapBatchRequestV1 {
        contract_version: 1,
        subjects: vec![CodeMapSubjectRequestV1 {
            language_id: 1,
            source_kind: CodeMapSourceKind::DecodeFailedUndecodable,
            source_utf8: vec![1],
        }],
    });
    assert!(matches!(nonempty, Err(CodeMapError::InvalidRequest(_))));
    let invalid = CodeMapService.build_batch(CodeMapBatchRequestV1 {
        contract_version: 1,
        subjects: vec![CodeMapSubjectRequestV1 {
            language_id: 1,
            source_kind: CodeMapSourceKind::Decoded,
            source_utf8: vec![0xff],
        }],
    });
    assert!(matches!(invalid, Err(CodeMapError::InvalidRequest(_))));
}

#[test]
fn compact_service_honors_pre_cancelled_leaf() {
    let identity =
        agentry_runtime::RuntimeIdentity::new(1, "0".repeat(32), "1".repeat(64), "2".repeat(64))
            .unwrap();
    let cancellation = agentry_runtime::LeafCancellation::new(identity);
    cancellation.cancel();
    let result = CodeMapService.build_batch_with_cancellation(
        CodeMapBatchRequestV1 {
            contract_version: 1,
            subjects: vec![decoded(CodeMapLanguage::C, "int f(void) { return 1; }")],
        },
        Some(&cancellation),
    );
    assert_eq!(result, Err(CodeMapError::Cancelled));
}
