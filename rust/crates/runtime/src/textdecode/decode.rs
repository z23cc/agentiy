//! The detection ladder itself (design §5.2): BOM sniff -> strict-UTF-8 fast path -> `chardetng`
//! fallback decoded via `encoding_rs`. See `mod.rs` for this module's cargo-only scope.

use super::contract::{
    BomDisposition, DetectedEncoding, Endian, TextDecodeOutcome, TextDecodePolicyVersion,
};
use chardetng::{EncodingDetector, Iso2022JpDetection, Utf8Detection};
use encoding_rs::{Encoding, UTF_8, UTF_16BE, UTF_16LE};

/// Decode one complete byte buffer to canonical UTF-8. Never fails — see `TextDecodeOutcome`'s
/// doc comment. `raw` is assumed to already have passed the caller's binary pre-filter (design
/// §5.1/§1.4: `isProbablyBinary` stays a Swift-side, pre-decode gate this function does not
/// implement).
#[must_use]
pub fn textdecode(raw: &[u8]) -> TextDecodeOutcome {
    // Step 1 (design §5.2): empty input.
    if raw.is_empty() {
        return TextDecodeOutcome {
            text: String::new(),
            detected_encoding: DetectedEncoding::Utf8,
            bom: BomDisposition::Absent,
            had_replacements: false,
            policy_version: TextDecodePolicyVersion::WorkspaceAutomaticV2,
        };
    }

    // Step 2/3 (design §5.2): BOM sniff wins outright, and its bytes are included in what gets
    // decoded (design §9 D-5) -- `bom` is `Present` unconditionally once one is found, even if
    // the decode under that encoding itself needs replacements.
    if let Some(bom_encoding) = sniff_bom(raw) {
        let detected_encoding = bom_encoding.into_detected();
        let (text, had_replacements) = decode_with_bom(raw, bom_encoding);
        return TextDecodeOutcome {
            text,
            detected_encoding,
            bom: BomDisposition::Present(detected_encoding),
            had_replacements,
            policy_version: TextDecodePolicyVersion::WorkspaceAutomaticV2,
        };
    }

    // Step 4 (design §5.2): strict UTF-8 validity, deterministic, no detector involved.
    if let Ok(text) = core::str::from_utf8(raw) {
        return TextDecodeOutcome {
            text: text.to_owned(),
            detected_encoding: DetectedEncoding::Utf8,
            bom: BomDisposition::Absent,
            had_replacements: false,
            policy_version: TextDecodePolicyVersion::WorkspaceAutomaticV2,
        };
    }

    // Step 5 (design §5.2): not valid UTF-8 -- chardetng fallback, decoded via encoding_rs's
    // total, replacement-decoding constructor.
    let legacy = guess_legacy_encoding(raw);
    let (cow, had_replacements) = legacy.decode_without_bom_handling(raw);
    TextDecodeOutcome {
        text: cow.into_owned(),
        detected_encoding: DetectedEncoding::Legacy(legacy),
        bom: BomDisposition::Absent,
        had_replacements,
        policy_version: TextDecodePolicyVersion::WorkspaceAutomaticV2,
    }
}

/// Four-way BOM sniff (design §5.2 step 2), same byte patterns as today's Swift
/// `detectBOMEncoding` (`FileSystemService+ContentLoading.swift:2268-2273`): UTF-8 `EF BB BF`;
/// UTF-16 BE/LE `FE FF`/`FF FE`; UTF-32 BE/LE `00 00 FE FF`/`FF FE 00 00`.
///
/// The two four-byte UTF-32 patterns are checked **before** the two-byte UTF-16 patterns: a
/// UTF-32 LE BOM (`FF FE 00 00`) starts with the exact bytes of a UTF-16 LE BOM (`FF FE`), so
/// checking UTF-16 first would misclassify every UTF-32 LE BOM as UTF-16 LE. `encoding_rs`'s own
/// `Encoding::for_bom` only covers the UTF-8/UTF-16 cases (it has no UTF-32 concept at all, design
/// §4.3), so the four-byte checks are hand-rolled here rather than delegated.
fn sniff_bom(raw: &[u8]) -> Option<BomEncoding> {
    if raw.starts_with(&[0x00, 0x00, 0xFE, 0xFF]) {
        return Some(BomEncoding::Utf32(Endian::Big));
    }
    if raw.starts_with(&[0xFF, 0xFE, 0x00, 0x00]) {
        return Some(BomEncoding::Utf32(Endian::Little));
    }
    if raw.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return Some(BomEncoding::Utf8);
    }
    if raw.starts_with(&[0xFE, 0xFF]) {
        return Some(BomEncoding::Utf16(Endian::Big));
    }
    if raw.starts_with(&[0xFF, 0xFE]) {
        return Some(BomEncoding::Utf16(Endian::Little));
    }
    None
}

/// The narrow subset of `DetectedEncoding` a BOM can actually name -- deliberately excludes
/// `Legacy`, so `decode_with_bom` (which only ever receives a `BomEncoding`) has no
/// `DetectedEncoding::Legacy` arm to (mis)handle at all, rather than relying on an `unreachable!()`
/// to rule it out at runtime. `textdecode`'s "never fails" contract (design §5.1/§5.3) extends to
/// "never panics"; this makes the impossible case unrepresentable instead of merely unreached.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BomEncoding {
    Utf8,
    Utf16(Endian),
    Utf32(Endian),
}

impl BomEncoding {
    const fn into_detected(self) -> DetectedEncoding {
        match self {
            Self::Utf8 => DetectedEncoding::Utf8,
            Self::Utf16(endian) => DetectedEncoding::Utf16 { endian },
            Self::Utf32(endian) => DetectedEncoding::Utf32 { endian },
        }
    }
}

/// Decode the complete buffer -- BOM bytes included, per design §9 D-5 -- under a
/// BOM-sniffed encoding. UTF-8/UTF-16 go through `encoding_rs`'s one-shot
/// `decode_without_bom_handling`, which design §5.2 step 3 names via the `Decoder` constructor it
/// is built on (`new_decoder_without_bom_handling`, verified directly against `encoding_rs`
/// 0.8.35's source: the one-shot function is a thin wrapper over that exact constructor for
/// complete-buffer input). UTF-32 has no `encoding_rs` counterpart at all (design §9 D-3) and is
/// hand-rolled in `decode_utf32`.
fn decode_with_bom(raw: &[u8], encoding: BomEncoding) -> (String, bool) {
    match encoding {
        BomEncoding::Utf8 => {
            let (cow, had_replacements) = UTF_8.decode_without_bom_handling(raw);
            (cow.into_owned(), had_replacements)
        }
        BomEncoding::Utf16(Endian::Big) => {
            let (cow, had_replacements) = UTF_16BE.decode_without_bom_handling(raw);
            (cow.into_owned(), had_replacements)
        }
        BomEncoding::Utf16(Endian::Little) => {
            let (cow, had_replacements) = UTF_16LE.decode_without_bom_handling(raw);
            (cow.into_owned(), had_replacements)
        }
        BomEncoding::Utf32(endian) => decode_utf32(raw, endian),
    }
}

/// Design §9 D-3's hand-rolled UTF-32 decode: 4-byte-unit iteration, U+FFFD substitution for any
/// unit outside the valid scalar range (surrogates `D800..=DFFF`, or > `0x10FFFF`) and for a
/// trailing partial unit. BOM-triggered only (`sniff_bom` is the only caller) -- never reached via
/// the statistical `chardetng` fallback (design §10 R3).
fn decode_utf32(raw: &[u8], endian: Endian) -> (String, bool) {
    let mut text = String::with_capacity(raw.len());
    let mut had_replacements = false;
    let mut chunks = raw.chunks_exact(4);
    for chunk in &mut chunks {
        let word = match endian {
            Endian::Big => u32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]),
            Endian::Little => u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]),
        };
        if let Some(scalar) = char::from_u32(word) {
            text.push(scalar);
        } else {
            had_replacements = true;
            text.push('\u{FFFD}');
        }
    }
    if !chunks.remainder().is_empty() {
        had_replacements = true;
        text.push('\u{FFFD}');
    }
    (text, had_replacements)
}

/// `chardetng` configuration (design §5.2 step 5 / §4.2, no configuration named explicitly beyond
/// "run chardetng over the bytes" -- decided here, against `chardetng` 1.0.0's own documented
/// semantics, verified directly against its source rather than recalled):
///
/// - `Utf8Detection::Deny` — this call site is only reached once the strict-UTF-8 fast path has
///   already failed (step 4), so the input is known not to be valid UTF-8; `chardetng` itself
///   documents that it is "explicitly scoped to legacy (non-UTF-8) content" (design §4.3) and does
///   not claim UTF-8 detection, so denying it here matches both facts and cannot change the
///   outcome for a genuinely-invalid-UTF-8 input.
/// - `Iso2022JpDetection::Allow` — **non-load-bearing in practice, kept for a documented reason.**
///   `legacy_iso_2022_jp_is_structurally_unreachable_via_this_ladder` (`tests.rs`) proves this
///   call site can never actually see ISO-2022-JP content: that encoding is 7-bit-safe by
///   construction, so any genuine ISO-2022-JP byte stream is also trivially valid (if semantically
///   wrong) UTF-8 and is claimed by step 4 before `chardetng` ever runs. An earlier version of
///   this comment justified `Allow` by design §8's ISO-2022-JP label-parity requirement; that
///   requirement cannot be met by this ladder at all (same finding), so it does not actually
///   justify the choice. `Allow` is kept anyway, on the narrower grounds `chardetng`'s own docs
///   give: `Deny` exists as the script-execution-safety default for Web browsers rendering
///   untrusted HTML, and local file content read for editing has no such script-execution
///   concern (closer to the docs' email example) -- but since this arm of `guess()` is dead code
///   for ISO-2022-JP either way, this is a defensible default, not a load-bearing decision.
/// - `tld: None` — no top-level-domain context exists for local file bytes. `chardetng`'s own docs
///   say `None` is "equivalent to passing `Some(b"com")`", i.e. a generic domain with no
///   script-specific bias -- the correct default absent any real TLD.
fn guess_legacy_encoding(raw: &[u8]) -> &'static Encoding {
    let mut detector = EncodingDetector::new(Iso2022JpDetection::Allow);
    detector.feed(raw, true);
    detector.guess(None, Utf8Detection::Deny)
}
