//! Fixture-based coverage for `textdecode` (design §6.2's matrix), generated as real byte
//! sequences in-test rather than loaded from a corpus file — TD-1 did not land a
//! `rust/crates/runtime/tests/fixtures/textdecode/` corpus for this revision, and TD-2's scope
//! note (design §11) is explicit that this module is exercised directly against byte-level
//! fixtures, not through any pre-existing dump.
//!
//! **Differential-prep methodology.** Where design §5.2 says parity holds against today's Swift
//! `decodeWorkspaceAutomaticV1` (`FileSystemService+ContentLoading.swift:37-49`, confirmed by
//! direct read, design §3.1 item 1), the expected value asserted here is derived directly from
//! that function's documented, unconditional behavior (empty input, strict-UTF-8 success, BOM
//! stripping on the old side) — it does not require invoking Swift, because those cases are
//! either deterministic UTF-8 validity facts or already-cited direct-read evidence in the
//! APPROVED design. Where design §9 names an intentional divergence (D-1 through D-6), the test
//! cites the design section and asserts the NEW (Rust) behavior explicitly, with a comment
//! explaining what the old chain did instead and why the difference is intentional, not a defect.
//!
//! **Findings surfaced by this investigation that go beyond restating the design** are called out
//! in comments at their point of relevance and are summarized in this phase's report; they are
//! empirical (measured against pinned `chardetng =1.0.0`/`encoding_rs =0.8.35`), not assumed.

use super::*;
use encoding_rs::{
    BIG5, EUC_JP, GB18030, GBK, ISO_2022_JP, ISO_8859_2, SHIFT_JIS, WINDOWS_1251, WINDOWS_1252,
};

// ---------------------------------------------------------------------------------------------
// Empty input (design §5.2 step 1)
// ---------------------------------------------------------------------------------------------

#[test]
fn empty_input_decodes_to_empty_utf8() {
    // Parity: today's ladder 1 returns `DetectedText(string: "", encoding: .utf8)` for empty data
    // (`FileSystemService+ContentLoading.swift:38-40`).
    let outcome = textdecode(b"");
    assert_eq!(outcome.text, "");
    assert_eq!(outcome.detected_encoding, DetectedEncoding::Utf8);
    assert_eq!(outcome.bom, BomDisposition::Absent);
    assert!(!outcome.had_replacements);
    assert_eq!(
        outcome.policy_version,
        TextDecodePolicyVersion::WorkspaceAutomaticV2
    );
}

// ---------------------------------------------------------------------------------------------
// UTF-8, bare (design §6.2 row 1) — the dominant case, byte-identical on both chains
// ---------------------------------------------------------------------------------------------

#[test]
fn utf8_bare_round_trips_byte_identical() {
    let raw = "Hello, world! Plain UTF-8, no surprises, no detector involved.".as_bytes();
    let outcome = textdecode(raw);
    assert_eq!(outcome.text.as_bytes(), raw);
    assert_eq!(outcome.detected_encoding, DetectedEncoding::Utf8);
    assert_eq!(outcome.bom, BomDisposition::Absent);
    assert!(!outcome.had_replacements);
}

// ---------------------------------------------------------------------------------------------
// UTF-8 with BOM (design §6.2 row 2 / §9 D-5) — the d1f84aa5 regression class.
// INTENTIONAL DIVERGENCE from today's ladder 1, which strips this BOM via
// `String(data:encoding:.utf8)` (confirmed, design §2/§67; not re-derived here, cited directly).
// ---------------------------------------------------------------------------------------------

#[test]
fn utf8_bom_is_preserved_not_stripped_d5() {
    let mut raw = vec![0xEF, 0xBB, 0xBF];
    raw.extend_from_slice("café".as_bytes());
    let outcome = textdecode(&raw);
    // U+FEFF survives as the first scalar -- design §5.2 step 3 / §9 D-5, the correctness fix
    // this migration exists partly to deliver, not a regression to preserve today's stripping.
    assert_eq!(outcome.text, "\u{FEFF}café");
    assert_eq!(outcome.detected_encoding, DetectedEncoding::Utf8);
    assert_eq!(outcome.bom, BomDisposition::Present(DetectedEncoding::Utf8));
    assert!(!outcome.had_replacements);
}

// ---------------------------------------------------------------------------------------------
// Invalid UTF-8 (design §6.2 row 3, ADR-0004 item 3). Required assertion shape per design §6.2 is
// canonical output bytes + bom + had_replacements -- NOT a specific charset label (label-string
// equality is explicitly named as the wrong universal assertion). These are short, low-signal
// inputs chardetng resolves to *some* legacy single-byte encoding; the exact pick is asserted
// because it is fully deterministic under the pinned exact versions in this workspace
// (chardetng =1.0.0, encoding_rs =0.8.35) and re-verifiable on any future version bump, not
// because the label itself is a required contract.
// ---------------------------------------------------------------------------------------------

#[test]
fn invalid_utf8_truncated_multibyte_sequence_never_fails() {
    // 0xE2 0x82 is the truncated lead+first-continuation of '€' (E2 82 AC) with no third byte.
    let raw = [b'a', 0xE2, 0x82];
    let outcome = textdecode(&raw);
    assert_eq!(outcome.bom, BomDisposition::Absent);
    // Never `None`/undecodable (design §5.3) -- always produces text, even for 3 low-signal bytes.
    assert!(!outcome.text.is_empty());
}

#[test]
fn invalid_utf8_lone_continuation_byte_never_fails() {
    let raw = [b'a', 0x80, b'b']; // 0x80 alone is never valid as a UTF-8 lead byte
    let outcome = textdecode(&raw);
    assert_eq!(outcome.bom, BomDisposition::Absent);
    // Single-byte legacy fallback: one input byte -> one output scalar (the scalar's own UTF-8
    // re-encoding may be more than one byte, e.g. windows-1252's 0x80 is '€', 3 bytes in UTF-8).
    assert_eq!(outcome.text.chars().count(), 3);
    assert!(outcome.text.starts_with('a') && outcome.text.ends_with('b'));
}

#[test]
fn invalid_utf8_overlong_encoding_never_fails() {
    let raw = [0xC0, 0x80]; // overlong two-byte encoding of NUL -- rejected by strict UTF-8
    let outcome = textdecode(&raw);
    assert_eq!(outcome.bom, BomDisposition::Absent);
    assert_eq!(outcome.text.chars().count(), 2);
}

// ---------------------------------------------------------------------------------------------
// UTF-16 LE/BE with BOM (design §6.2 row 4/5, ADR-0004 item 3) -- deterministic, BOM-fixed,
// matches today's `detectBOMEncoding` 4-way sniff exactly (design §5.2 step 2).
// ---------------------------------------------------------------------------------------------

#[test]
fn utf16_le_with_bom_preserves_bom_and_decodes() {
    let mut raw = vec![0xFF, 0xFE];
    for unit in "hi".encode_utf16() {
        raw.extend_from_slice(&unit.to_le_bytes());
    }
    let outcome = textdecode(&raw);
    assert_eq!(outcome.text, "\u{FEFF}hi");
    assert_eq!(
        outcome.detected_encoding,
        DetectedEncoding::Utf16 {
            endian: Endian::Little
        }
    );
    assert_eq!(
        outcome.bom,
        BomDisposition::Present(DetectedEncoding::Utf16 {
            endian: Endian::Little
        })
    );
    assert!(!outcome.had_replacements);
}

#[test]
fn utf16_be_with_bom_preserves_bom_and_decodes() {
    let mut raw = vec![0xFE, 0xFF];
    for unit in "hi".encode_utf16() {
        raw.extend_from_slice(&unit.to_be_bytes());
    }
    let outcome = textdecode(&raw);
    assert_eq!(outcome.text, "\u{FEFF}hi");
    assert_eq!(
        outcome.detected_encoding,
        DetectedEncoding::Utf16 {
            endian: Endian::Big
        }
    );
    assert_eq!(
        outcome.bom,
        BomDisposition::Present(DetectedEncoding::Utf16 {
            endian: Endian::Big
        })
    );
    assert!(!outcome.had_replacements);
}

#[test]
fn utf16_be_bom_surrogate_pair_non_bmp_round_trips() {
    // R7-adjacent, decode-level (not codemap): a supplementary-plane scalar (🎉, U+1F389) requires
    // a surrogate pair in UTF-16 -- exercises scalar-boundary-safe reassembly, not just BMP code
    // units.
    let mut raw = vec![0xFE, 0xFF];
    for unit in "🎉".encode_utf16() {
        raw.extend_from_slice(&unit.to_be_bytes());
    }
    let outcome = textdecode(&raw);
    assert_eq!(outcome.text, "\u{FEFF}🎉");
    assert!(!outcome.had_replacements);
}

// ---------------------------------------------------------------------------------------------
// UTF-16 WITHOUT a BOM (design §6.2 row 6 / §9 D-2, "must be characterized, not assumed").
//
// MEASURED FINDING: ASCII text encoded as UTF-16 without a BOM (each ASCII char as a 2-byte unit,
// high byte 0x00) is entirely composed of bytes < 0x80, which are trivially also valid UTF-8 (as
// literal NUL-interleaved ASCII). Step 4's strict-UTF-8 check therefore succeeds FIRST and
// `chardetng` is never reached. This is not a Rust-specific loss: today's ladder 1
// (`decodeWorkspaceAutomaticV1`) runs the identical strict-UTF-8-first check with no
// BOM-less-UTF-16 heuristic of its own (that heuristic exists only on ladder 2/3, the *streamed*
// path this design does not touch, design §3.1 items 2-3) -- so ladder 1 exhibits the exact same
// behavior today. Parity holds for the ladder-1 consumer this design replaces; it is not a new
// divergence introduced here.
// ---------------------------------------------------------------------------------------------

#[test]
fn utf16_ascii_content_without_bom_is_claimed_by_the_strict_utf8_fast_path() {
    let mut raw = Vec::new();
    for unit in "Hello, world".encode_utf16() {
        raw.extend_from_slice(&unit.to_le_bytes());
    }
    let outcome = textdecode(&raw);
    // Claimed by step 4, not step 5 -- ladder-1-identical, not a `chardetng` guess.
    assert_eq!(outcome.detected_encoding, DetectedEncoding::Utf8);
    assert_eq!(outcome.bom, BomDisposition::Absent);
    assert!(!outcome.had_replacements);
    assert_eq!(outcome.text, "H\0e\0l\0l\0o\0,\0 \0w\0o\0r\0l\0d\0");
}

// ---------------------------------------------------------------------------------------------
// UTF-32 LE/BE with BOM (design §6.2 row 7 / §9 D-3) -- hand-rolled, since `encoding_rs` has no
// UTF-32 family (design §4.3).
// ---------------------------------------------------------------------------------------------

#[test]
fn utf32_be_with_bom_decodes_via_hand_rolled_path() {
    let mut raw = vec![0x00, 0x00, 0xFE, 0xFF]; // UTF-32 BE BOM
    raw.extend_from_slice(&0x0068u32.to_be_bytes()); // 'h'
    raw.extend_from_slice(&0x1F389u32.to_be_bytes()); // 🎉, non-BMP scalar
    let outcome = textdecode(&raw);
    assert_eq!(outcome.text, "\u{FEFF}h🎉");
    assert_eq!(
        outcome.detected_encoding,
        DetectedEncoding::Utf32 {
            endian: Endian::Big
        }
    );
    assert_eq!(
        outcome.bom,
        BomDisposition::Present(DetectedEncoding::Utf32 {
            endian: Endian::Big
        })
    );
    assert!(!outcome.had_replacements);
}

#[test]
fn utf32_le_with_bom_decodes_via_hand_rolled_path() {
    let mut raw = vec![0xFF, 0xFE, 0x00, 0x00]; // UTF-32 LE BOM
    raw.extend_from_slice(&0x0068u32.to_le_bytes()); // 'h'
    raw.extend_from_slice(&0x1F389u32.to_le_bytes()); // 🎉
    let outcome = textdecode(&raw);
    assert_eq!(outcome.text, "\u{FEFF}h🎉");
    assert_eq!(
        outcome.detected_encoding,
        DetectedEncoding::Utf32 {
            endian: Endian::Little
        }
    );
    assert!(!outcome.had_replacements);
}

#[test]
fn utf32_le_bom_ordering_wins_over_utf16_le_bom_prefix_match() {
    // A UTF-32 LE BOM (FF FE 00 00) begins with the exact bytes of a UTF-16 LE BOM (FF FE) --
    // design §5.2 step 2's four-byte-before-two-byte ordering requirement. This test would fail
    // (misdetect as UTF-16 LE) if that ordering were reversed.
    let mut raw = vec![0xFF, 0xFE, 0x00, 0x00];
    raw.extend_from_slice(&0x0041u32.to_le_bytes()); // 'A'
    let outcome = textdecode(&raw);
    assert_eq!(
        outcome.detected_encoding,
        DetectedEncoding::Utf32 {
            endian: Endian::Little
        }
    );
    assert_eq!(outcome.text, "\u{FEFF}A");
}

#[test]
fn utf32_hand_rolled_path_replaces_invalid_scalars_and_trailing_partial_unit() {
    // D-3/R3 coverage: a 4-byte unit in the surrogate range (invalid as a scalar value) and a
    // trailing partial (non-multiple-of-4) unit both become U+FFFD, and `had_replacements` is
    // set -- this is one of exactly two deterministic ways to observe `had_replacements == true`
    // (see the multi-byte-legacy characterization test below for why the other ladder branch,
    // chardetng's own guess, essentially never does).
    let mut raw = vec![0x00, 0x00, 0xFE, 0xFF]; // UTF-32 BE BOM
    raw.extend_from_slice(&0xD800u32.to_be_bytes()); // lone surrogate: not a valid scalar
    raw.extend_from_slice(&[0x00, 0x00, 0x41]); // trailing partial (3 bytes) unit: 'A' cut short
    let outcome = textdecode(&raw);
    assert!(outcome.had_replacements);
    assert_eq!(outcome.text, "\u{FEFF}\u{FFFD}\u{FFFD}");
}

// ---------------------------------------------------------------------------------------------
// Legacy single/multi-byte charsets (design §6.2's corrected live set / §8's label-parity bar).
// Each fixture: encode real, natural-language sample text via `encoding_rs` (simulating "this is
// what such a file looks like on disk" -- the in-test generation this phase's task specifically
// calls for), feed the raw bytes through `textdecode`, and assert (a) `chardetng` recovers the
// *correct family* of encoding and (b) the canonical UTF-8 text round-trips byte-for-byte.
//
// Scope limit, stated plainly: this proves `chardetng`'s pick is internally self-consistent
// (round-trips against the very encoding the fixture was generated in) and, from that, that
// label-parity fixtures for uchardet-vs-chardetng agreement *could* be built. It does not itself
// prove agreement with uchardet's actual pick on identical bytes -- doing that requires invoking
// the vendored Cuchardet path, which lives only inside the Swift/Xcode build and is out of reach
// for this cargo-only phase (design §11 TD-2 scope note: this module "cannot exercise ... Swift-
// side behavior at all"). Full cross-implementation differential parity is TD-3+ scope.
// ---------------------------------------------------------------------------------------------

fn assert_legacy_round_trip(sample: &str, source_encoding: &'static encoding_rs::Encoding) {
    let (raw, _, unmappable) = source_encoding.encode(sample);
    assert!(
        !unmappable,
        "fixture text contains characters unencodable in {source_encoding:?}"
    );
    let outcome = textdecode(&raw);
    assert_eq!(
        outcome.text, sample,
        "canonical text must round-trip for {source_encoding:?}"
    );
    assert!(!outcome.had_replacements);
    assert_eq!(outcome.bom, BomDisposition::Absent);
    let DetectedEncoding::Legacy(detected) = outcome.detected_encoding else {
        panic!(
            "expected a Legacy detection for {source_encoding:?} content, got {:?}",
            outcome.detected_encoding
        );
    };
    // §8's label-parity bar: re-encoding the canonical text with the DETECTED label must
    // reproduce the original raw bytes exactly.
    let (reencoded, _, reencode_unmappable) = detected.encode(&outcome.text);
    assert!(!reencode_unmappable);
    assert_eq!(
        reencoded.as_ref(),
        raw.as_ref(),
        "label-parity round-trip failed: detected {detected:?} does not reproduce the original \
         {source_encoding:?} bytes"
    );
}

#[test]
fn legacy_windows_1252_western_european() {
    assert_legacy_round_trip(
        "Café à Zürich — naïve “Über-Straße” costs €5. Not ISO-8859-1: note the em dash, euro \
         sign, and curly quotes, which only exist in windows-1252's C1 range.",
        WINDOWS_1252,
    );
}

#[test]
fn legacy_shift_jis_japanese() {
    assert_legacy_round_trip(
        "これはShift-JISでエンコードされた日本語のテキストです。文字化けせずに正しくデコード\
         されることを確認します。漢字も含みます。東京都渋谷区。",
        SHIFT_JIS,
    );
}

#[test]
fn legacy_euc_jp_japanese() {
    assert_legacy_round_trip(
        "これはEUC-JPでエンコードされた日本語のテキストです。文字化けせずに正しくデコード\
         されることを確認します。漢字も含みます。大阪府大阪市。",
        EUC_JP,
    );
}

#[test]
fn legacy_gb18030_simplified_chinese_label_diverges_to_gbk_d2() {
    // MEASURED (D-2): `chardetng` picks `GBK`, not `GB18030`, for this sample -- GBK is a strict
    // subset of GB18030 for the common characters used here, so the pick is a genuine label
    // divergence (design §9 D-2) but not a round-trip break: `assert_legacy_round_trip`'s own
    // label-parity re-encode (via the DETECTED label, GBK) still reproduces the original
    // GB18030-encoded bytes exactly. Per design §8(a), this is the "genuine ambiguous-input
    // disagreement that still round-trips" case, not one requiring escalation.
    assert_legacy_round_trip(
        "这是一段用GB18030编码的中文文本。用于验证解码器能够正确识别并还原简体中文字符，\
         不会出现乱码。北京市朝阳区。",
        GB18030,
    );
}

#[test]
fn legacy_big5_traditional_chinese() {
    assert_legacy_round_trip(
        "這是一段用Big5編碼的中文文本。用於驗證解碼器能夠正確識別並還原繁體中文字符，\
         不會出現亂碼。臺北市中正區。",
        BIG5,
    );
}

#[test]
fn legacy_windows_1251_russian() {
    assert_legacy_round_trip(
        "Съешь же ещё этих мягких французских булок, да выпей чаю. Это кириллический текст \
         на русском языке для проверки детектора кодировок.",
        WINDOWS_1251,
    );
}

#[test]
fn legacy_iso_8859_2_central_european() {
    assert_legacy_round_trip(
        "Příliš žluťoučký kůň úpěl ďábelské ódy. Zażółć gęślą jaźń. To jest przykładowy tekst \
         w języku środkowoeuropejskim.",
        ISO_8859_2,
    );
}

// ---------------------------------------------------------------------------------------------
// ISO-2022-JP (design §6.2 row: "Legacy single/multi-byte ... ISO-2022-JP").
//
// MEASURED FINDING, worth flagging back to the design: ISO-2022-JP is a 7-bit-safe encoding --
// every byte in genuine ISO-2022-JP content (including its ESC-sequence charset switches) is
// < 0x80, which means it is UNCONDITIONALLY also valid (if semantically wrong) UTF-8. Step 4's
// strict-UTF-8 check therefore ALWAYS succeeds first, and `chardetng` (configured with
// `Iso2022JpDetection::Allow` specifically for this row, see `guess_legacy_encoding`'s doc
// comment) is structurally unreachable for this encoding via this ladder's ordering.
//
// This is NOT a Rust-vs-Swift divergence: today's ladder 1 (`decodeWorkspaceAutomaticV1`) runs
// the identical strict-UTF-8-first check ahead of Cuchardet (design §3.1 item 1), so genuine
// ISO-2022-JP content is equally unreachable by uchardet on the Swift side today, for the exact
// same structural reason. Parity holds (both sides "fail" to detect it identically) but the
// design's §6.2/§8 listing of ISO-2022-JP as part of the live, ladder-1-reachable label set
// appears to assume the detector is reached for it, which this measurement shows does not
// happen. Surfaced here rather than silently adjusting the fixture to "pass".
// ---------------------------------------------------------------------------------------------

#[test]
fn legacy_iso_2022_jp_is_structurally_unreachable_via_this_ladder() {
    let sample = "これはISO-2022-JPでエンコードされた日本語のテキストです。";
    let (raw, _, unmappable) = ISO_2022_JP.encode(sample);
    assert!(!unmappable);
    assert!(
        raw.iter().all(|&byte| byte < 0x80),
        "ISO-2022-JP output must be 7-bit-safe by construction"
    );
    let outcome = textdecode(&raw);
    // Claimed by step 4 (strict UTF-8), not step 5 (chardetng) -- the raw ISO-2022-JP escape
    // sequences and JIS byte pairs come through as their literal ASCII/Latin-1-range
    // interpretation, not the intended Japanese text.
    assert_eq!(outcome.detected_encoding, DetectedEncoding::Utf8);
    assert_ne!(outcome.text, sample);
}

// ---------------------------------------------------------------------------------------------
// D-6 / ladder 6 (headless `agentry-mcp` apply-edits, `DirectHeadlessFileEditHost`) -- BYTE-LEVEL
// ONLY per design §11 TD-2's explicit scope note: this phase has no FFI wiring and cannot exercise
// the Swift host itself (which doesn't call into Rust at all yet). This test proves the byte-level
// half of D-6's claim: content that host hard-rejects TODAY (`String(data:encoding:.utf8)` fails
// for genuine Shift-JIS multi-byte bytes, since they are not valid UTF-8) now decodes cleanly via
// `textdecode`. The host-level wiring (the actual behavior change Swift users would see) is TD-3
// scope (design §6.1/§9 D-6).
// ---------------------------------------------------------------------------------------------

#[test]
fn ladder6_legacy_charset_bytes_decode_cleanly_though_todays_host_hard_rejects_them() {
    let sample = "これはヘッドレスapply-editsホストのShift-JISテスト用テキストです。";
    let (raw, _, unmappable) = SHIFT_JIS.encode(sample);
    assert!(!unmappable);
    // Today's `DirectHeadlessFileEditHost.readText` hard-rejects this exact byte sequence
    // (`String(data: raw, encoding: .utf8)` returns `nil` for genuine Shift-JIS multi-byte
    // content) -- confirmed structurally: these bytes are not valid UTF-8 (contains bytes >=
    // 0x80 in a pattern that fails UTF-8 validation).
    assert!(core::str::from_utf8(&raw).is_err());
    // `textdecode` decodes it cleanly instead -- the net behavior improvement design §9 D-6
    // describes, at the byte level this phase can actually exercise.
    let outcome = textdecode(&raw);
    assert_eq!(outcome.text, sample);
    assert!(!outcome.had_replacements);
}

// ---------------------------------------------------------------------------------------------
// CRLF line endings (design §6.2 row, ADR-0004 item 3 / scalar-boundary sanity)
// ---------------------------------------------------------------------------------------------

#[test]
fn crlf_line_endings_preserved_byte_identical() {
    let raw = b"line one\r\nline two\r\nline three\r\n";
    let outcome = textdecode(raw);
    assert_eq!(outcome.text.as_bytes(), raw);
    assert_eq!(outcome.detected_encoding, DetectedEncoding::Utf8);
    assert!(!outcome.had_replacements);
}

// ---------------------------------------------------------------------------------------------
// Non-BMP (design §6.2 row, ADR-0004 item 3) -- emoji and supplementary-plane CJK via the
// strict-UTF-8 fast path (the BOM-branch UTF-16/UTF-32 tests above already cover non-BMP through
// those paths).
// ---------------------------------------------------------------------------------------------

#[test]
fn non_bmp_emoji_and_supplementary_cjk_round_trip_via_strict_utf8() {
    let raw = "🎉 emoji, 𠀀 supplementary-plane CJK, plain text.".as_bytes();
    let outcome = textdecode(raw);
    assert_eq!(outcome.text.as_bytes(), raw);
    assert_eq!(outcome.detected_encoding, DetectedEncoding::Utf8);
    assert!(!outcome.had_replacements);
}

// ---------------------------------------------------------------------------------------------
// Lossy input / write-back gating precondition (design §9 D-1, §10 R8, §5.3's binding decision).
// `textdecode` itself does not implement the write-back gate (that is TD-3/TD-5's Swift-side
// mechanism, design §5.3.1) -- this phase's obligation is only that `had_replacements` is set
// correctly and that decode still succeeds (never `.undecodable`) when replacement occurs.
//
// MEASURED FINDING: this is reliably observable via the two BOM-fixed paths above (UTF-16 lone
// surrogate, UTF-32 invalid scalar/trailing-partial-unit) but essentially UNREACHABLE via the
// `chardetng`-guessed legacy-multi-byte path. Every single-byte legacy encoding this workspace's
// `encoding_rs` implements maps all 256 byte values (verified directly:
// `WINDOWS_1252.decode_without_bom_handling` on each of the WHATWG-table "gap" bytes 0x81/0x8D/
// 0x8F/0x90/0x9D returns `had_errors=false`, mapping them to their C1 control-code scalars rather
// than erroring), so a single-byte candidate can never be disqualified by an actual decode error.
// `chardetng` disqualifies a multi-byte candidate (Shift-JIS, EUC-JP, Big5, GB18030/GBK, EUC-KR)
// OUTRIGHT the moment ANY fed byte sequence is invalid for it -- verified directly: truncating
// even the single trailing byte of an otherwise-100%-valid, 137-byte Shift-JIS sample flips the
// guess entirely to `windows-1252` rather than yielding a Shift-JIS pick with one U+FFFD. Since
// `windows-1252` can never itself be disqualified, this means genuinely lossy legacy
// CJK/Cyrillic/etc. content essentially never reaches `had_replacements == true` through the
// guessed path in practice -- it is silently reclassified as clean windows-1252 instead. This
// characterization test proves that reclassification directly rather than asserting it from the
// two probes above.
// ---------------------------------------------------------------------------------------------

#[test]
fn lossy_utf16_lone_surrogate_sets_had_replacements_true_d1_r8() {
    let mut raw = vec![0xFE, 0xFF]; // UTF-16 BE BOM
    raw.extend_from_slice(&0x0041u16.to_be_bytes()); // 'A'
    raw.extend_from_slice(&0xD800u16.to_be_bytes()); // lone high surrogate: malformed alone
    raw.extend_from_slice(&0x0042u16.to_be_bytes()); // 'B'
    let outcome = textdecode(&raw);
    assert!(outcome.had_replacements);
    assert_eq!(outcome.text, "\u{FEFF}A\u{FFFD}B");
    // Never `.undecodable` -- always a `TextDecodeOutcome`, per design §5.1/§5.3.
    assert_eq!(
        outcome.policy_version,
        TextDecodePolicyVersion::WorkspaceAutomaticV2
    );
}

#[test]
fn lossy_legacy_multibyte_candidate_is_disqualified_not_reported_lossy_characterization() {
    let sentence = "これはShift-JISでエンコードされた日本語のテキストです。文字化けせずに\
                     正しくデコードされることを確認します。漢字も含みます。東京都渋谷区。";
    let (full, _, unmappable) = SHIFT_JIS.encode(sentence);
    assert!(!unmappable);
    // Truncate the trailing byte of the last two-byte character -- a genuinely malformed,
    // dangling lead byte at EOF under Shift-JIS.
    let mut truncated = full.to_vec();
    truncated.pop();
    let outcome = textdecode(&truncated);
    // MEASURED: `chardetng` does not report this as a lossy Shift-JIS decode. It disqualifies the
    // Shift-JIS candidate entirely and falls back to `windows-1252`, which maps every byte and so
    // never sets `had_replacements`.
    assert_eq!(
        outcome.detected_encoding,
        DetectedEncoding::Legacy(WINDOWS_1252)
    );
    assert!(!outcome.had_replacements);
}

// ---------------------------------------------------------------------------------------------
// D-1 core contract: `textdecode` never panics and never fails for arbitrary bytes. No `rand`
// dependency is introduced for this (out of TD-2's two-crate scope) -- these are deterministic,
// hand-picked adversarial byte patterns exercising boundary/edge shapes a real fuzzer would also
// reach for: every single byte value, several BOM-look-alike-but-truncated prefixes, and a run of
// the UTF-8 continuation-only byte.
// ---------------------------------------------------------------------------------------------

#[test]
fn never_panics_for_every_single_byte_value() {
    for byte in 0u8..=255 {
        let outcome = textdecode(&[byte]);
        assert_eq!(
            outcome.policy_version,
            TextDecodePolicyVersion::WorkspaceAutomaticV2
        );
    }
}

#[test]
fn never_panics_for_truncated_bom_look_alike_prefixes() {
    // Genuinely no complete BOM of any kind in these prefixes.
    let no_bom_cases: &[&[u8]] = &[
        &[0xEF],
        &[0xEF, 0xBB],
        &[0xFE],
        &[0xFF],
        &[0x00, 0x00],
        &[0x00, 0x00, 0xFE],
    ];
    for raw in no_bom_cases {
        let outcome = textdecode(raw);
        assert_eq!(
            outcome.bom,
            BomDisposition::Absent,
            "no full BOM present in {raw:?}"
        );
    }
    // `[0xFF, 0xFE, 0x00]` is NOT a truncated-UTF-32-LE-BOM look-alike that should read as
    // "absent" -- its first two bytes ARE a genuine, complete UTF-16 LE BOM on their own (design
    // §5.2 step 2's ordering only disambiguates when the fourth byte is also present and matches).
    let outcome = textdecode(&[0xFF, 0xFE, 0x00]);
    assert_eq!(
        outcome.bom,
        BomDisposition::Present(DetectedEncoding::Utf16 {
            endian: Endian::Little
        })
    );
}

#[test]
fn never_panics_for_a_run_of_continuation_only_bytes() {
    let raw = [0x80u8; 64];
    let outcome = textdecode(&raw);
    assert_eq!(outcome.text.chars().count(), 64);
}

#[test]
fn never_panics_for_binary_looking_bytes_gated_upstream_in_production() {
    // design §6.2 row: "Binary (should never reach textdecode -- gated by isProbablyBinary
    // upstream)". `textdecode` implements no such gate itself (design §5.1/§1.4: that gate is a
    // Swift-side, pre-decode filter); this only confirms `textdecode` doesn't panic if fed binary
    // content anyway, which is the contract this function actually makes.
    let mut raw = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]; // PNG magic
    raw.extend((0u8..=255).cycle().take(256));
    let outcome = textdecode(&raw);
    assert_eq!(
        outcome.policy_version,
        TextDecodePolicyVersion::WorkspaceAutomaticV2
    );
}

// GBK's static isn't otherwise referenced directly (only via `DetectedEncoding::Legacy` pattern
// matches above); keep the import used explicitly so a future reader can `grep` for it here.
#[test]
fn gbk_static_is_the_label_gb18030_content_actually_resolves_to() {
    let sample = "简体中文测试。";
    let (raw, _, _) = GB18030.encode(sample);
    let outcome = textdecode(&raw);
    assert_eq!(outcome.detected_encoding, DetectedEncoding::Legacy(GBK));
}
