//! The re-chunking pass (design §3.4's P6-3 done-when addition, closing finding F5 / the corpus's
//! post-framing-capture gap): replays each corpus fixture's byte stream through the Rust
//! `LineFramer` at adversarial split boundaries and asserts the emitted line sequence is identical
//! to the whole-buffer-at-once baseline. This is what converts "the framer is chunk-boundary
//! independent" from an assumption (E-P6-1's corpus is captured post-framing, at line granularity
//! -- design §3.4) into a standing test, without needing a chunk-granularity capture instrument
//! that does not exist today.

use std::fs;

use crate::agent_claude::{FramerDiagnostic, LineFramer};

fn framer_output(data: &[u8], chunks: &[&[u8]]) -> (Vec<Vec<u8>>, Vec<FramerDiagnostic>) {
    let mut framer = LineFramer::default();
    let mut lines = Vec::new();
    let mut diagnostics = Vec::new();
    for chunk in chunks {
        framer.feed(chunk, |d| diagnostics.push(d), |l| lines.push(l));
    }
    framer.flush(|l| lines.push(l));
    debug_assert_eq!(chunks.iter().map(|c| c.len()).sum::<usize>(), data.len());
    (lines, diagnostics)
}

fn assert_chunking_independent(name: &str, data: &[u8], split_points: &[usize]) {
    let (baseline_lines, _) = framer_output(data, &[data]);

    // Uniform strides -- "1-byte reads, prime-sized reads" (design §3.4). Byte-granularity
    // strides are O(data.len()) `feed()` calls; skip them for the multi-megabyte fixture (the
    // dedicated escape-sequence/oversized tests below already cover it at meaningful strides)
    // so this sweep stays fast across the whole corpus.
    let strides: &[usize] = if data.len() > 64 * 1024 {
        &[4096, 65537]
    } else {
        &[1, 2, 3, 7, 13, 31, 4096]
    };
    for &stride in strides {
        let chunks: Vec<&[u8]> = data.chunks(stride.max(1)).collect();
        let (lines, _) = framer_output(data, &chunks);
        assert_eq!(lines, baseline_lines, "{name}: stride={stride}");
    }

    // Explicit split points -- "splits placed inside a JSON string escape and inside a
    // multi-byte UTF-8 scalar" (design §3.4).
    for &split_at in split_points {
        assert!(
            split_at <= data.len(),
            "{name}: split point {split_at} out of range ({} bytes)",
            data.len()
        );
        let chunks: Vec<&[u8]> = vec![&data[..split_at], &data[split_at..]];
        let (lines, _) = framer_output(data, &chunks);
        assert_eq!(lines, baseline_lines, "{name}: split_at={split_at}");
    }
}

#[test]
fn all_synthetic_corpus_fixtures_are_chunk_boundary_independent() {
    let dir = super::corpus_synthetic_dir();
    let mut checked = 0usize;
    for entry in fs::read_dir(&dir).unwrap_or_else(|e| panic!("failed to read {dir:?}: {e}")) {
        let entry = entry.unwrap();
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("ndjson") {
            continue;
        }
        let data = fs::read(&path).unwrap();
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        assert_chunking_independent(&name, &data, &[]);
        checked += 1;
    }
    assert!(
        checked >= 10,
        "expected to have checked at least the original 10 synthetic fixtures, checked {checked}"
    );
}

/// Splits placed inside a multi-byte UTF-8 scalar -- `café 🙂 strët` inside a JSON string value.
/// The framer must reassemble byte-identically regardless of where mid-scalar the chunk boundary
/// falls, since it tracks JSON structure via single-byte ASCII markers (`{`, `"`, `\`, `\n`) only
/// and never interprets partial multi-byte sequences.
#[test]
fn multibyte_utf8_scalar_split_at_every_byte_offset() {
    let data = super::read_fixture("rechunking-multibyte-utf8-scalar.ndjson");
    // Sanity: the fixture really does contain multi-byte UTF-8 (café = 0xC3 0xA9, emoji = 4 bytes).
    assert!(
        data.iter().any(|&b| b >= 0x80),
        "fixture must contain real multi-byte UTF-8 bytes, not \\u escapes"
    );
    let all_offsets: Vec<usize> = (1..data.len()).collect();
    assert_chunking_independent(
        "rechunking-multibyte-utf8-scalar.ndjson",
        &data,
        &all_offsets,
    );
}

/// A split placed inside a JSON string escape sequence (`\\\"` -- an escaped quote) in the
/// oversized fixture, which was deliberately authored with real escape sequences for this purpose
/// (MANIFEST.json). Splitting between the `\` and the following `"` must not cause the framer to
/// misread the escaped quote as a real string terminator.
#[test]
fn split_inside_a_json_string_escape_sequence() {
    let data = super::read_fixture("oversized-line-over-1mb.ndjson");
    let backslash_quote = data
        .windows(2)
        .position(|w| w == b"\\\"")
        .expect("fixture must contain an escaped-quote sequence to split inside of");
    // Split points at, before, and after the two-byte escape sequence.
    let split_points = vec![backslash_quote, backslash_quote + 1, backslash_quote + 2];
    assert_chunking_independent(
        "oversized-line-over-1mb.ndjson (escape split)",
        &data,
        &split_points,
    );
}
