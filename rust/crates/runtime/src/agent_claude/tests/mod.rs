//! P6-3 corpus-driven tests (design §3.4, contract §6/§9). Reads
//! `rust/crates/runtime/tests/fixtures/claude-ndjson/v1/` directly -- the same corpus
//! `docs/architecture/rust-agent-claude-v1.md`'s MANIFEST.json documents and the Swift package's
//! `ClaudeNDJSONCorpusDifferentialTests` reads independently (design §11's two-independent-arms
//! reference-arm definition).

mod corpus;
mod rechunking;

use std::path::{Path, PathBuf};

fn corpus_synthetic_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/claude-ndjson/v1/synthetic")
}

fn read_fixture(name: &str) -> Vec<u8> {
    let path = corpus_synthetic_dir().join(name);
    std::fs::read(&path).unwrap_or_else(|e| panic!("failed to read corpus fixture {path:?}: {e}"))
}

/// Feeds a fixture's raw bytes through the real `LineFramer` (feed + flush) to obtain the
/// logical line(s) RepoPrompt's stdout reader would actually hand to the codec -- per the
/// corpus's own `MANIFEST.json` `fileFormat` note: "Files are fed to the framer/codec as-is, not
/// pre-parsed." A handful of these fixtures have framer-relevant subtlety (an unterminated JSON
/// string absorbing the file's trailing newline; CRLF stripping) that a naive raw-`\n`-split would
/// get wrong, so every corpus test in this module goes through the framer rather than around it.
fn framed_lines(name: &str) -> Vec<Vec<u8>> {
    let data = read_fixture(name);
    let mut framer = crate::agent_claude::LineFramer::default();
    let mut lines = Vec::new();
    framer.feed(&data, |_| {}, |line| lines.push(line));
    framer.flush(|line| lines.push(line));
    lines
}
