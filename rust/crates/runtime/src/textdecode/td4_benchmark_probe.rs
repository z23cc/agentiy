//! TD-4 (design `docs/designs/textdecode-policy-v2-2026-08-22.md` §10 X-3 / §11 TD-4): the
//! cargo-side half of the pre-registered slice-2 economics GO/NO-GO benchmark. Per
//! `rust/benchmarks/slo-v1.json`'s `performanceIterationPolicy`, the default instrument is
//! "cargo release A-layer core and Rust FFI-frontier harnesses" -- this module IS that instrument
//! for `textdecode`: pure-Rust throughput/latency at X-3's pre-registered 100/1k/10k/100k-file
//! scale, across the three corpus categories the task specifies (UTF-8-dominant, BOM'd, legacy
//! fallback), with NO FFI crossing at all.
//!
//! **What this measures and what it doesn't.** This is `textdecode()` alone -- no FFI, no
//! apply-edits envelope, no Swift comparison. It answers "is the Rust decode function itself cheap
//! enough that a GO verdict is even plausible" (the policy's stated purpose: avoid paying a ~15
//! minute Swift release rebuild before knowing that). It does NOT by itself close X-3's pass
//! criterion, which is explicitly a Rust-candidate-vs-Swift-chain RATIO -- that half lives in
//! `Tests/RepoPromptTests/WorkspaceContext/TextDecodeCutoverBenchmarkTests.swift` (Swift baseline +
//! the real FFI seam via `RustApplyEditsComputer`'s `.raw` path, see that file's doc comment for
//! why the FFI number necessarily includes more than decode alone).
//!
//! Env-gated (`RP_RUN_TEXTDECODE_CUTOVER_BENCHMARK=1`), same variable name as the Swift harness,
//! matching `InventoryCutoverBenchmarkTests`' env-gate convention ported to Rust: skip (not
//! `#[ignore]`) when unset, so `cargo test` stays green env-off without needing `--ignored`.

use super::*;
use std::time::Instant;

fn utf8_dominant_payload(index: usize) -> Vec<u8> {
    let mut body = String::new();
    for line in 0..18 {
        body.push_str(&format!(
            "    let component{index}Line{line} = ComponentValue(index: {index}, line: {line})\n"
        ));
    }
    format!("struct BenchComponent{index} {{\n{body}}}\n").into_bytes()
}

fn bom_prefixed_payload(index: usize) -> Vec<u8> {
    let mut raw = vec![0xEF, 0xBB, 0xBF];
    raw.extend_from_slice(&utf8_dominant_payload(index));
    raw
}

fn legacy_fallback_payload(index: usize) -> Vec<u8> {
    use encoding_rs::SHIFT_JIS;
    let sentence = format!(
        "これはベンチマーク用のコメントです。ファイル番号{index}。文字化けせずに正しく\
         デコードされることを確認するための日本語テキストです。東京都渋谷区の\
         サンプルコンポーネントです。処理速度の測定に使用します。"
    );
    SHIFT_JIS.encode(&sentence).0.into_owned()
}

fn corpus(file_count: usize) -> Vec<Vec<u8>> {
    (0..file_count)
        .map(|i| match i % 3 {
            0 => utf8_dominant_payload(i),
            1 => bom_prefixed_payload(i),
            _ => legacy_fallback_payload(i),
        })
        .collect()
}

#[test]
fn td4_x3_cargo_side_batched_throughput() {
    let Ok(flag) = std::env::var("RP_RUN_TEXTDECODE_CUTOVER_BENCHMARK") else {
        eprintln!(
            "td4_x3_cargo_side_batched_throughput: skipped (set \
             RP_RUN_TEXTDECODE_CUTOVER_BENCHMARK=1 to run)"
        );
        return;
    };
    if flag != "1" {
        eprintln!(
            "td4_x3_cargo_side_batched_throughput: skipped (RP_RUN_TEXTDECODE_CUTOVER_BENCHMARK != 1)"
        );
        return;
    }

    eprintln!("TD4_X3_CARGO_SIDE_BEGIN");
    eprintln!(
        "{:>8} {:>16} {:>18} {:>16}",
        "files", "total_ms", "per_file_us_p50", "per_file_us_p99"
    );
    let iterations = 7usize;
    for file_count in [100usize, 1_000, 10_000, 100_000] {
        let payloads = corpus(file_count);
        // Warmup (pays allocator/branch-predictor warmup, discarded).
        let mut checksum: usize = 0;
        for p in &payloads {
            checksum ^= textdecode(p).text.len();
        }
        std::hint::black_box(checksum);

        let mut samples_ms: Vec<f64> = Vec::with_capacity(iterations);
        for _ in 0..iterations {
            let start = Instant::now();
            let mut local_checksum: usize = 0;
            for p in &payloads {
                local_checksum ^= textdecode(p).text.len();
            }
            std::hint::black_box(local_checksum);
            samples_ms.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        samples_ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let mid = samples_ms.len() / 2;
        let p50_total_ms = if samples_ms.len().is_multiple_of(2) {
            (samples_ms[mid - 1] + samples_ms[mid]) / 2.0
        } else {
            samples_ms[mid]
        };
        let p99_rank = ((samples_ms.len() as f64) * 0.99).ceil().max(1.0) as usize;
        let p99_total_ms = samples_ms[p99_rank.min(samples_ms.len()) - 1];

        eprintln!(
            "{:>8} {:>16.4} {:>18.4} {:>16.4}",
            file_count,
            p50_total_ms,
            (p50_total_ms * 1000.0) / file_count as f64,
            (p99_total_ms * 1000.0) / file_count as f64
        );
    }
    eprintln!("TD4_X3_CARGO_SIDE_END");
}
