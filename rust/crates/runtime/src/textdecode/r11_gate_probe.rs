//! R11 investigation (design `docs/designs/textdecode-policy-v2-2026-08-22.md` §18.1/§18.4):
//! empirical evidence for what the TD-5 write-back gate should key on, given `had_replacements` is
//! near-unreachable via the guessed legacy-multi-byte path (measured at TD-2,
//! `tests.rs:532-551`). This module does not change `textdecode`'s behavior -- it is a read-only
//! investigation over the already-landed decoder, run as ordinary (fast, non-`#[ignore]`d) `cargo
//! test`s. Findings are written up in the design's §18.4 addendum and
//! `rust/benchmarks/results/v1/td4-td5-textdecode-r11-v1.{json,md}`.
//!
//! §18.1 names three candidates for what the gate should key on and evaluates (does not resolve)
//! them:
//! 1. BOM-pinned-only -- already free (today's actual behavior); insufficient alone for R11's
//!    legacy-multi-byte population.
//! 2. detected-encoding-changed-vs-cached -- supplementary; does nothing on first open.
//! 3. explicit "undecodable-by-elimination" heuristic -- named but not measured against
//!    `chardetng`'s actual API surface.
//!
//! This module measures a fourth candidate the task names explicitly and §18.1 does not evaluate:
//! **round-trip re-encode** (decode -> re-encode via the detected label -> compare to the original
//! bytes) as a lossiness oracle. It also measures a concrete instance of candidate 3: a high-bit-
//! byte-density heuristic, plus a narrower windows-1252-specific "C1 gap byte" signal, against both
//! the corrupted population R11 cares about and a deliberately hostile clean corpus (all-Cyrillic
//! windows-1251 text) chosen to stress the false-positive risk §18.1 candidate 3's own text
//! anticipates ("a genuine heuristic-design question, not a re-derivation of existing facts").

use super::*;
use encoding_rs::{BIG5, EUC_JP, EUC_KR, GB18030, SHIFT_JIS, WINDOWS_1251, WINDOWS_1252};
use std::time::Instant;

// -------------------------------------------------------------------------------------------
// Candidate signals under investigation
// -------------------------------------------------------------------------------------------

/// Proportion of bytes with the high bit set (`>= 0x80`) -- cheap, single-pass, O(n). A concrete,
/// measurable instance of §18.1 candidate 3's "meaningful proportion of high-bit-set bytes" idea.
fn high_bit_byte_density(raw: &[u8]) -> f64 {
    if raw.is_empty() {
        return 0.0;
    }
    let high = raw.iter().filter(|&&b| b >= 0x80).count();
    high as f64 / raw.len() as f64
}

/// The five WHATWG windows-1252 "gap" bytes the design (§10 R5, §18.1) confirms map to C1 control
/// scalars rather than erroring -- verified there directly against `encoding_rs`. Genuine
/// natural-language windows-1252 text essentially never contains these bytes (no printable glyph
/// was ever assigned to them), so their presence in `Legacy(WINDOWS_1252)`-labeled decoded text is
/// a narrow, targeted candidate discriminator: "this probably isn't real windows-1252 content."
const WINDOWS_1252_C1_GAP_BYTES: [u8; 5] = [0x81, 0x8D, 0x8F, 0x90, 0x9D];

fn contains_windows_1252_c1_gap_byte(raw: &[u8]) -> bool {
    raw.iter().any(|b| WINDOWS_1252_C1_GAP_BYTES.contains(b))
}

/// The round-trip re-encode oracle the task names explicitly: decode -> re-encode via the
/// *detected* label -> compare to the original bytes. Returns `true` if the round trip reproduces
/// the original bytes exactly (the oracle reports "clean"). Mirrors `assert_legacy_round_trip`'s
/// existing bar (`tests.rs:301-330`) but as a query rather than an assertion -- here the input is
/// deliberately corrupted and the point is to observe, not assert, the outcome.
///
/// Scoped to the guessed-legacy-label population, matching R11's scope (§18.1): the two BOM-pinned
/// cases already have a reliable `had_replacements` signal and are out of scope for this oracle.
fn round_trip_reencode_matches(raw: &[u8]) -> Option<bool> {
    let outcome = textdecode(raw);
    let DetectedEncoding::Legacy(detected) = outcome.detected_encoding else {
        return None;
    };
    let (reencoded, _, unmappable) = detected.encode(&outcome.text);
    Some(!unmappable && reencoded.as_ref() == raw)
}

// -------------------------------------------------------------------------------------------
// Corpus construction: genuinely-lossy legacy files (§18.1's population) and hostile-clean
// controls (to measure false-positive risk on each candidate signal, not just true-positive rate).
// -------------------------------------------------------------------------------------------

fn clean_shift_jis_sample() -> Vec<u8> {
    let sentence = "これはShift-JISでエンコードされた日本語のテキストです。文字化けせずに\
                     正しくデコードされることを確認します。漢字も含みます。東京都渋谷区。";
    SHIFT_JIS.encode(sentence).0.into_owned()
}

/// Identical construction to `tests.rs`'s disqualification characterization test
/// (`lossy_legacy_multibyte_candidate_is_disqualified_not_reported_lossy_characterization`,
/// `tests.rs:533-551`) -- the exact case R11/§18.1 is about: a single truncated trailing byte at
/// EOF, otherwise 100% valid Shift-JIS.
fn truncated_shift_jis_sample() -> Vec<u8> {
    let mut raw = clean_shift_jis_sample();
    raw.pop();
    raw
}

/// A different corruption shape from truncation: flip one byte mid-buffer to an invalid Shift-JIS
/// trail value, leaving the rest of the buffer (including everything after the corrupted byte)
/// intact. Tests whether `chardetng` disqualifies on ANY invalid byte regardless of position, or
/// only cares about trailing/EOF damage.
fn mid_sequence_corrupted_shift_jis_sample() -> Vec<u8> {
    let mut raw = clean_shift_jis_sample();
    let mid = raw.len() / 2;
    raw[mid] = 0xFF; // not a valid Shift-JIS trail byte for any lead byte
    raw
}

/// A plausible real-world corruption shape distinct from single-byte damage: two genuine legacy
/// encodings concatenated (e.g. a partial file recovery, or fragments merged from different
/// sources) -- first half real Shift-JIS, second half real EUC-JP.
fn mixed_encoding_splice_sample() -> Vec<u8> {
    let shift_jis_half = clean_shift_jis_sample();
    let euc_jp_sentence = "これはEUC-JPでエンコードされた日本語のテキストです。文字化けせずに\
                            正しくデコードされることを確認します。漢字も含みます。大阪府大阪市。";
    let euc_jp_half = EUC_JP.encode(euc_jp_sentence).0.into_owned();
    let mut raw = shift_jis_half;
    raw.extend_from_slice(&euc_jp_half);
    raw
}

fn truncated_big5_sample() -> Vec<u8> {
    let sentence = "這是一段使用Big5編碼的繁體中文文字，用來測試字元偵測與解碼是否正確運作。";
    let mut raw = BIG5.encode(sentence).0.into_owned();
    raw.pop();
    raw
}

fn truncated_gb18030_sample() -> Vec<u8> {
    let sentence = "这是一段使用GB18030编码的简体中文文字，用来测试字符检测与解码是否正确运行。";
    let mut raw = GB18030.encode(sentence).0.into_owned();
    raw.pop();
    raw
}

/// Deliberately ends on a Korean (2-byte EUC-KR) character, not ASCII punctuation -- an earlier
/// version of this fixture ended in a trailing `.` (ASCII, 1 byte), so `raw.pop()` removed a
/// harmless trailing byte instead of corrupting a multi-byte sequence, silently turning this into
/// a not-actually-lossy case. Caught by inspecting this exact row's measured output (round-trip
/// reported "clean" and, on investigation, genuinely was -- see `td4-td5-textdecode-r11-v1.md`).
fn truncated_euc_kr_sample() -> Vec<u8> {
    let sentence =
        "이것은 EUC-KR로 인코딩된 한국어 텍스트입니다 디코딩이 올바르게 작동하는지 확인합니다";
    let mut raw = EUC_KR.encode(sentence).0.into_owned();
    raw.pop();
    raw
}

/// Hostile-clean control 1: genuine, correctly-labeled windows-1252 content -- mostly ASCII with
/// occasional accented characters, the shape §18.1 candidate 3 implicitly assumes "normal"
/// single-byte-legacy content looks like.
fn clean_windows_1252_sample() -> Vec<u8> {
    let sentence = "Café à Zürich — naïve \u{201C}Über-Straße\u{201D} costs €5. Not ISO-8859-1: \
                     note the em dash, euro sign, and curly quotes, which only exist in \
                     windows-1252's C1 range.";
    WINDOWS_1252.encode(sentence).0.into_owned()
}

/// Additional clean windows-1252 controls, deliberately varied and deliberately dense in the
/// legitimately-assigned 0x80-0x9F printable range (curly quotes, dashes, bullet, trademark,
/// dagger, ellipsis -- everything WHATWG assigns in that byte range EXCEPT the 5 gap bytes, which
/// no real encoder ever produces). If the C1-gap-byte signal (candidate 5) is going to
/// false-positive on genuine content, dense legitimate special-character use is exactly where it
/// would show up -- a single café-style sample is not enough evidence for a "zero false positives"
/// claim used to justify a write-back gate.
/// First construction attempt used a symbol-fragment-heavy sample with too little ordinary English
/// word content for `chardetng`'s statistical model to confidently pick windows-1252 -- it landed
/// on windows-1251 instead (a real, useful finding in its own right, recorded here rather than
/// discarded: adversarially-dense special-character content isn't automatically windows-1252-
/// labeled, which is itself a mild point in the signal's favor -- content unusual enough to stress
/// the gap-byte check is also unusual enough that `chardetng` may not label it windows-1252 at
/// all). This version keeps the same character variety embedded in enough ordinary English prose
/// that `chardetng` reliably picks windows-1252.
fn clean_windows_1252_dense_special_chars_sample() -> Vec<u8> {
    let sentence = "The style guide says to use \u{201C}smart quotes\u{201D} everywhere, an \
                     \u{2014}em dash\u{2014} for asides, and an \u{2013}en dash\u{2013} for \
                     ranges like pages 12\u{2013}34. Use a \u{2022} bullet for list items, mark \
                     trademarks with \u{2122}, and footnotes with \u{2020} or \u{2021} when a \
                     second note is needed on the same page. Keep percentages plain but write \
                     \u{2030} for per-mille figures, and prefer \u{2039}nested\u{203A} angle \
                     quotes only inside already-quoted text. An \u{2026} ellipsis shows a trailing \
                     thought, and loanwords like fa\u{e7}ade or na\u{ef}ve keep their accents.";
    WINDOWS_1252.encode(sentence).0.into_owned()
}

fn clean_windows_1252_business_text_sample() -> Vec<u8> {
    let sentence = "Q3 revenue rose 12% \u{2014}driven primarily by EMEA\u{2014} to \u{20AC}4.2M. \
                     Management\u{2019}s outlook remains \u{201C}cautiously optimistic,\u{201D} \
                     per yesterday\u{2019}s call. Next steps: finalize Q4 budget, review vendor \
                     contracts (see appendix \u{2020}), and schedule the board sync.";
    WINDOWS_1252.encode(sentence).0.into_owned()
}

/// Hostile-clean control 2: genuine, correctly-labeled windows-1251 content with deliberately
/// ZERO ASCII letters (Cyrillic only, plus spaces/punctuation) -- stress-tests the high-bit-density
/// heuristic's false-positive risk against a real, clean, dense-non-Latin-script single-byte file,
/// exactly the population §18.1 candidate 3's own text flags as a risk ("a genuine heuristic-design
/// question, not a re-derivation of existing facts").
fn clean_all_cyrillic_windows_1251_sample() -> Vec<u8> {
    let sentence = "Съешь же ещё этих мягких французских булок, да выпей чаю. Широкая \
                     электрификация южных губерний даст мощный толчок подъёму сельского \
                     хозяйства.";
    WINDOWS_1251.encode(sentence).0.into_owned()
}

// -------------------------------------------------------------------------------------------
// Findings
// -------------------------------------------------------------------------------------------

/// **Core R11 finding.** The round-trip re-encode oracle the task asks this investigation to
/// evaluate is a FALSE NEGATIVE for the exact case R11 is about: windows-1252 is a total,
/// injective byte<->scalar mapping over all 256 byte values (confirmed directly at TD-2, §18.1),
/// so decoding a corrupted-Shift-JIS-reclassified-as-windows-1252 buffer and re-encoding the
/// (wrong, garbled) resulting text via the (wrong) detected windows-1252 label reproduces the
/// *original raw bytes exactly*. The oracle reports "clean" on a buffer that is garbage. This is
/// not "the oracle doesn't catch everything" -- it is a targeted failure on the specific population
/// R11 exists to protect.
#[test]
fn round_trip_oracle_false_negative_on_truncated_shift_jis_r11() {
    let raw = truncated_shift_jis_sample();
    let outcome = textdecode(&raw);
    assert_eq!(
        outcome.detected_encoding,
        DetectedEncoding::Legacy(WINDOWS_1252)
    );
    assert!(
        !outcome.had_replacements,
        "had_replacements re-confirms §18.1's finding"
    );
    assert_eq!(
        round_trip_reencode_matches(&raw),
        Some(true),
        "MEASURED (R11): round-trip re-encode wrongly reports this corrupted-Shift-JIS-as-\
         windows-1252 reclassification as clean. If this assertion now fails, the oracle's \
         behavior for R11's core case has changed upstream and §18.4's recommendation needs \
         re-checking against the new behavior."
    );
}

/// Sweep every constructed corruption scenario through both the round-trip oracle and the two
/// heuristic signals, printing a summary table (same style as `inventory_scope::wire::e2_probe`)
/// and asserting the load-bearing claims from each row rather than only the single case above.
#[test]
fn r11_signal_sweep_across_corruption_and_clean_controls() {
    struct Row {
        label: &'static str,
        raw: Vec<u8>,
        /// Ground truth this investigation constructed the sample to have: is the *content* this
        /// buffer decodes to under `textdecode`'s actual pick genuinely wrong/garbled (a write-back
        /// on this decode would corrupt the file), independent of whether any measured signal
        /// catches it?
        genuinely_lossy: bool,
    }

    let rows = vec![
        Row {
            label: "truncated-shift-jis (R11 core case)",
            raw: truncated_shift_jis_sample(),
            genuinely_lossy: true,
        },
        Row {
            label: "mid-sequence-corrupted-shift-jis",
            raw: mid_sequence_corrupted_shift_jis_sample(),
            genuinely_lossy: true,
        },
        Row {
            label: "mixed-encoding-splice (shift-jis+euc-jp)",
            raw: mixed_encoding_splice_sample(),
            genuinely_lossy: true,
        },
        Row {
            label: "truncated-big5",
            raw: truncated_big5_sample(),
            genuinely_lossy: true,
        },
        Row {
            label: "truncated-gb18030",
            raw: truncated_gb18030_sample(),
            genuinely_lossy: true,
        },
        Row {
            label: "truncated-euc-kr",
            raw: truncated_euc_kr_sample(),
            genuinely_lossy: true,
        },
        Row {
            label: "clean-windows-1252 (control)",
            raw: clean_windows_1252_sample(),
            genuinely_lossy: false,
        },
        Row {
            label: "clean-all-cyrillic-windows-1251 (hostile control)",
            raw: clean_all_cyrillic_windows_1251_sample(),
            genuinely_lossy: false,
        },
    ];

    eprintln!("R11_GATE_PROBE_BEGIN");
    eprintln!(
        "{:<48} {:<22} {:>9} {:>11} {:>10} {:>9}",
        "case", "detected", "lossy?", "round_trip", "density", "c1_gap"
    );

    let mut roundtrip_false_negatives = 0usize;
    let mut density_would_flag_clean_cyrillic = false;

    for row in &rows {
        let outcome = textdecode(&row.raw);
        let round_trip = round_trip_reencode_matches(&row.raw);
        let density = high_bit_byte_density(&row.raw);
        let c1_gap = contains_windows_1252_c1_gap_byte(&row.raw);
        eprintln!(
            "{:<48} {:<22} {:>9} {:>11} {:>10.3} {:>9}",
            row.label,
            format!("{:?}", outcome.detected_encoding),
            row.genuinely_lossy,
            round_trip.map_or("n/a".to_string(), |m| (!m).to_string()),
            density,
            c1_gap
        );

        // Round-trip MISMATCH means the oracle correctly flags lossiness (`round_trip == Some(false)`);
        // MATCH (or "n/a" for the BOM-pinned cases this oracle doesn't cover) means it misses it.
        if row.genuinely_lossy && round_trip != Some(false) {
            roundtrip_false_negatives += 1;
        }

        if !row.genuinely_lossy
            && matches!(outcome.detected_encoding, DetectedEncoding::Legacy(_))
            && density > 0.5
        {
            density_would_flag_clean_cyrillic = true;
        }
    }
    eprintln!("R11_GATE_PROBE_END");

    // MEASURED: every genuinely-lossy sample in this sweep round-trips "clean" under the oracle --
    // 0% recall for this population via round-trip re-encode alone, confirming the single-case
    // finding above generalizes across corruption shapes (truncation, mid-sequence, splice) and
    // encodings (Shift-JIS, Big5, GB18030, EUC-KR), not just the one EOF-truncation case.
    assert_eq!(
        roundtrip_false_negatives,
        rows.iter().filter(|r| r.genuinely_lossy).count(),
        "expected round-trip re-encode to miss every constructed lossy case in this sweep"
    );

    // MEASURED: a naive "high-bit-density > 0.5" rule, applied uniformly, DOES flag the genuine,
    // clean, all-Cyrillic control -- confirming §18.1 candidate 3's own stated false-positive risk
    // is real, not theoretical, for a plain density threshold used alone.
    assert!(
        density_would_flag_clean_cyrillic,
        "expected the naive density-threshold heuristic to false-positive on genuine dense-\
         non-Latin-script content, confirming candidate 3's named risk"
    );
}

/// Windows-1252 C1-gap-byte signal: narrower than density, but does it actually separate the two
/// populations in this corpus? Measures hit rate on the lossy corpus (recall) and false-positive
/// rate on the two clean controls, rather than assuming either.
#[test]
fn windows_1252_c1_gap_signal_hit_rate() {
    let lossy_cases: Vec<(&str, Vec<u8>)> = vec![
        ("truncated-shift-jis", truncated_shift_jis_sample()),
        (
            "mid-sequence-corrupted-shift-jis",
            mid_sequence_corrupted_shift_jis_sample(),
        ),
        ("mixed-encoding-splice", mixed_encoding_splice_sample()),
    ];
    // Big5/GB18030/EUC-KR truncation cases are included here too (their reclassified label may
    // not always be windows-1252 specifically, so the gap-byte signal is scoped to whichever cases
    // actually land on that label -- filtered below).
    let all_lossy: Vec<(&str, Vec<u8>)> = lossy_cases
        .into_iter()
        .chain([
            ("truncated-big5", truncated_big5_sample()),
            ("truncated-gb18030", truncated_gb18030_sample()),
            ("truncated-euc-kr", truncated_euc_kr_sample()),
        ])
        .collect();

    let mut windows_1252_lossy_cases = 0usize;
    let mut windows_1252_lossy_hits = 0usize;
    for (label, raw) in &all_lossy {
        let outcome = textdecode(raw);
        if outcome.detected_encoding == DetectedEncoding::Legacy(WINDOWS_1252) {
            windows_1252_lossy_cases += 1;
            let hit = contains_windows_1252_c1_gap_byte(raw);
            eprintln!("c1_gap_signal: {label} -> windows-1252, gap-byte present = {hit}");
            if hit {
                windows_1252_lossy_hits += 1;
            }
        } else {
            eprintln!(
                "c1_gap_signal: {label} -> {:?} (not windows-1252, signal not applicable)",
                outcome.detected_encoding
            );
        }
    }

    // False-positive check, STRENGTHENED per adversarial review of an earlier draft of this
    // investigation: an n=1 false-positive check ("the café sample doesn't contain a gap byte")
    // is not enough evidence to justify recommending this signal as any kind of write-back gate --
    // a false positive on this signal blocks a user's save, so its false-positive rate needs more
    // than one sample, and specifically needs samples DENSE in the legitimately-assigned 0x80-0x9F
    // range (where a false positive would most plausibly show up), not just occasional use.
    let clean_controls: Vec<(&str, Vec<u8>)> = vec![
        ("clean-windows-1252-cafe", clean_windows_1252_sample()),
        (
            "clean-windows-1252-dense-special-chars",
            clean_windows_1252_dense_special_chars_sample(),
        ),
        (
            "clean-windows-1252-business-text",
            clean_windows_1252_business_text_sample(),
        ),
    ];
    let mut false_positive_count = 0usize;
    for (label, raw) in &clean_controls {
        let outcome = textdecode(raw);
        assert_eq!(
            outcome.detected_encoding,
            DetectedEncoding::Legacy(WINDOWS_1252),
            "{label} fixture didn't land on the windows-1252 label this check assumes"
        );
        let hit = contains_windows_1252_c1_gap_byte(raw);
        eprintln!("c1_gap_signal_false_positive_check: {label} -> gap-byte present = {hit}");
        if hit {
            false_positive_count += 1;
        }
    }
    assert_eq!(
        false_positive_count,
        0,
        "genuine windows-1252 content unexpectedly contains a C1 gap byte on {false_positive_count}/\
         {} clean controls -- signal has a false positive on real content and must NOT be \
         recommended as a write-back gate at this evidence level",
        clean_controls.len()
    );

    eprintln!(
        "c1_gap_signal: windows-1252-labeled lossy cases = {windows_1252_lossy_cases}, gap-byte \
         hits = {windows_1252_lossy_hits}, clean controls tested = {}, false positives = {false_positive_count}",
        clean_controls.len()
    );

    // Recorded, not asserted strictly >0 on recall: the whole point of measuring is to find out
    // honestly. §18.4 reports this exact ratio rather than assuming full coverage. n=3 on the
    // false-positive side is still small -- §18.4's recommendation treats this as "no false
    // positive found in a deliberately-adversarial sample," not as a proof of zero false-positive
    // rate, and does NOT recommend this signal as a hard/binding write-back gate on that basis.
}

/// Cost of the round-trip re-encode oracle: a second full pass over the buffer (encode) on top of
/// the decode `textdecode` already performs. Cheap enough to include as an ordinary (non-`#[ignore]`
/// -d) test at this corpus size -- `RP_RUN_TEXTDECODE_CUTOVER_BENCHMARK`-gated scale-point
/// measurement for the TD-4 gate itself lives in `td4_benchmark_probe.rs`, not here.
#[test]
fn round_trip_reencode_relative_cost() {
    let raw = clean_shift_jis_sample();
    let iterations = 5_000;

    let decode_only_start = Instant::now();
    for _ in 0..iterations {
        std::hint::black_box(textdecode(&raw));
    }
    let decode_only_elapsed = decode_only_start.elapsed();

    let decode_and_reencode_start = Instant::now();
    for _ in 0..iterations {
        let outcome = textdecode(&raw);
        if let DetectedEncoding::Legacy(detected) = outcome.detected_encoding {
            std::hint::black_box(detected.encode(&outcome.text));
        }
    }
    let decode_and_reencode_elapsed = decode_and_reencode_start.elapsed();

    let decode_only_ns_per_call = decode_only_elapsed.as_nanos() as f64 / iterations as f64;
    let decode_and_reencode_ns_per_call =
        decode_and_reencode_elapsed.as_nanos() as f64 / iterations as f64;
    eprintln!(
        "round_trip_reencode_relative_cost: buffer_bytes={} decode_only_ns_per_call={:.1} \
         decode_and_reencode_ns_per_call={:.1} overhead_ratio={:.3}",
        raw.len(),
        decode_only_ns_per_call,
        decode_and_reencode_ns_per_call,
        decode_and_reencode_ns_per_call / decode_only_ns_per_call
    );

    assert!(decode_only_ns_per_call > 0.0);
    assert!(decode_and_reencode_ns_per_call > 0.0);
}
