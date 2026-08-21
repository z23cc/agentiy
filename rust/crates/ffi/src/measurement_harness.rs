use std::fs;
use std::path::PathBuf;
use std::time::Instant;

use serde_json::{Value, json};

use crate::{
    ABI_EPOCH, CompactRegexBatchResult, CoreConfig, CoreRuntime, JitStatus, MatchPolicy,
    RegexSearchBatchRequest, RegexSearchMode,
};

fn percentile(sorted: &[f64], percentile: f64) -> f64 {
    let index = ((sorted.len() as f64 * percentile).ceil() as usize)
        .saturating_sub(1)
        .min(sorted.len() - 1);
    sorted[index]
}

fn distribution(mut values: Vec<f64>) -> Value {
    values.sort_by(f64::total_cmp);
    json!({
        "p50": percentile(&values, 0.50),
        "p99": percentile(&values, 0.99),
        "unit": "milliseconds"
    })
}

fn compact_output(result: &CompactRegexBatchResult) -> Value {
    let mut checksum = 14_695_981_039_346_656_037_u64;
    for word in result.hit_words.iter().chain(&result.line_range_words) {
        for byte in word.to_le_bytes() {
            checksum = (checksum ^ u64::from(byte)).wrapping_mul(1_099_511_628_211);
        }
    }
    json!({
        "checksumFNV1a64": format!("{checksum:016x}"),
        "hitCount": result.subject_summaries.iter().map(|value| value.hit_count).sum::<u64>(),
        "materializedUTF8Bytes": 0
    })
}

fn subjects(fixture: &str, bytes: &[u8]) -> Vec<String> {
    let value: Value = serde_json::from_slice(bytes).unwrap();
    if fixture.starts_with("representative-") {
        return value["payload"]["subjects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|subject| subject.as_str().unwrap().to_owned())
            .collect();
    }
    vec![String::from_utf8(serde_json::to_vec(&value).unwrap()).unwrap()]
}

#[test]
#[ignore = "measurement harness is opt-in"]
fn measure_rust_search_ffi_frontier_v1() {
    let output = PathBuf::from(std::env::var("AGENTRY_RUST_SEARCH_FFI_FLOOR_OUTPUT").unwrap());
    let fixture_path =
        PathBuf::from(std::env::var("AGENTRY_RUST_SEARCH_FFI_FLOOR_FIXTURE_PATH").unwrap());
    let fixture = std::env::var("AGENTRY_RUST_SEARCH_FFI_FLOOR_FIXTURE").unwrap();
    let warmups = std::env::var("AGENTRY_RUST_SEARCH_FFI_FLOOR_WARMUPS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(100_usize);
    let samples = std::env::var("AGENTRY_RUST_SEARCH_FFI_FLOOR_SAMPLES")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(1_000_usize);
    let fixture_bytes = fs::read(fixture_path).unwrap();
    let subjects = subjects(&fixture, &fixture_bytes);

    let core = CoreRuntime::new(CoreConfig {
        expected_abi_epoch: ABI_EPOCH,
        expected_build_fingerprint: "0".repeat(64),
        expected_binding_checksum: "0".repeat(64),
        data_lane_capacity: 8,
        cancel_tombstone_millis: 10,
        shutdown_grace_millis: 10,
    })
    .unwrap();
    let identity = core.initialize().unwrap().runtime_identity;
    let cancellation = core.create_leaf_cancellation(identity.clone()).unwrap();
    let request = RegexSearchBatchRequest {
        runtime_identity: identity,
        cancellation,
        mode: RegexSearchMode::Content,
        pattern: "baselineNeedle".into(),
        subjects: subjects.clone(),
        case_insensitive: true,
        whole_word: false,
        multiline_anchors: false,
        collect_matches: true,
        max_collected_matches: None,
        context_lines: 2,
        match_policy: MatchPolicy::ContentFullBuffer,
    };
    let mut timings = Vec::with_capacity(samples);
    let mut expected_output = None;
    let mut jit_active = true;
    let mut cache_hits = 0_u64;

    for iteration in 0..(warmups + samples) {
        let start = Instant::now();
        let result = core.search_regex_batch_compact_v1(request.clone()).unwrap();
        let elapsed = start.elapsed().as_secs_f64() * 1_000.0;
        let output_value = compact_output(&result);
        if let Some(expected) = &expected_output {
            assert_eq!(expected, &output_value);
        } else {
            expected_output = Some(output_value);
        }
        jit_active &= result
            .subject_summaries
            .iter()
            .all(|value| value.jit_status == JitStatus::Active);
        cache_hits += result
            .subject_summaries
            .iter()
            .filter(|value| value.cache_hit)
            .count() as u64;
        if iteration >= warmups {
            timings.push(elapsed);
        }
    }

    let report = json!({
        "cacheHitObservations": cache_hits,
        "fixture": fixture,
        "jitActive": jit_active,
        "layer": "FFI-frontier",
        "sampleIterations": samples,
        "schemaVersion": 1,
        "semantics": {
            "caseInsensitive": true,
            "collectMatches": true,
            "contextLines": 2,
            "matchPolicy": "contentFullBuffer",
            "pattern": "baselineNeedle",
            "wholeWord": false
        },
        "subjectBytes": subjects.iter().map(String::len).sum::<usize>(),
        "subjectCount": subjects.len(),
        "totals": { "wall": distribution(timings) },
        "warmupIterations": warmups,
        "workloadOutput": expected_output.unwrap()
    });
    fs::write(output, serde_json::to_vec(&report).unwrap()).unwrap();
}
