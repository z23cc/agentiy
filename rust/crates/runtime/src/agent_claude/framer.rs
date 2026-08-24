//! Port of `Sources/RepoPrompt/Infrastructure/Process/ProcessStreamFraming.swift`'s `LineFramer`
//! and `repairJSONStringControlCharacters` (design §3.4/§4.4, contract §5.3/§5.4/§6). Byte-exact,
//! not paraphrased: this is the transport-plane instrument the design's re-chunking pass (P6-3
//! done-when) depends on to prove chunk-boundary independence, so every quote/escape/candidacy
//! decision below must match the Swift source line for line.
//!
//! Kept as `Vec<u8>`/`&[u8]` end to end, never `String` -- a `String` boundary anywhere would make
//! the mid-UTF-8-scalar-split re-chunking case (design §3.4) unpassable, since an arbitrary byte
//! split can land inside a multi-byte UTF-8 sequence and `String::from_utf8` would reject it.

#[inline]
pub fn is_ascii_whitespace(byte: u8) -> bool {
    matches!(byte, 0x09 | 0x0A | 0x0B | 0x0C | 0x0D | 0x20)
}

/// Port of `trimmedASCIIWhitespace(_:)`. Returns `None` for an all-whitespace or empty slice
/// (mirrors the Swift function returning `nil`, which callers treat as "no message").
pub fn trimmed_ascii_whitespace(data: &[u8]) -> Option<&[u8]> {
    let mut start = 0usize;
    let mut end = data.len();
    while start < end && is_ascii_whitespace(data[start]) {
        start += 1;
    }
    while end > start && is_ascii_whitespace(data[end - 1]) {
        end -= 1;
    }
    if start == end {
        None
    } else {
        Some(&data[start..end])
    }
}

#[derive(Debug, Clone, Copy)]
pub struct FramerLimits {
    /// Maximum bytes allowed in a single logical line before overflow handling.
    pub max_line_bytes: usize,
    /// Maximum bytes the carry buffer may accumulate across chunks before overflow.
    pub max_carry_bytes: usize,
    /// When overflow occurs, retain this many trailing bytes so downstream tail-recovery can
    /// still find embedded JSON.
    pub tail_retain_bytes: usize,
}

impl Default for FramerLimits {
    fn default() -> Self {
        Self {
            max_line_bytes: 8 * 1024 * 1024,
            max_carry_bytes: 16 * 1024 * 1024,
            tail_retain_bytes: 128 * 1024,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FramerDiagnostic {
    /// Carry buffer exceeded limits; prefix was discarded, tail retained, quote state reset.
    Overflow {
        dropped_bytes: usize,
        retained_bytes: usize,
    },
    /// Quote-tracking state was force-reset because the line is not a JSON candidate.
    NonJsonCandidateQuoteStateReset,
}

/// Splits a raw byte stream into NDJSON lines, tracking JSON string quote/escape state so a
/// literal newline embedded inside a JSON string value does not prematurely split a record.
/// Quote/escape tracking is only active when the current line begins with `{` or `[` (a "JSON
/// candidate"); every other line splits on every `\n` unconditionally -- port of
/// `LineFramer` (`ProcessStreamFraming.swift:44-213`).
#[derive(Debug, Clone)]
pub struct LineFramer {
    limits: FramerLimits,
    carry: Vec<u8>,
    in_json_string: bool,
    is_escaping_json_string_character: bool,
    is_json_candidate: bool,
    has_seen_line_start: bool,
}

impl Default for LineFramer {
    fn default() -> Self {
        Self::new(FramerLimits::default())
    }
}

impl LineFramer {
    pub fn new(limits: FramerLimits) -> Self {
        Self {
            limits,
            carry: Vec::new(),
            in_json_string: false,
            is_escaping_json_string_character: false,
            is_json_candidate: false,
            has_seen_line_start: false,
        }
    }

    pub fn limits(&self) -> FramerLimits {
        self.limits
    }

    /// Feeds one chunk of raw bytes (an arbitrary OS-level `read()` result -- may split mid-line,
    /// mid-escape, or mid-UTF-8-scalar; the framer must be correct regardless of the split point).
    pub fn feed(
        &mut self,
        chunk: &[u8],
        mut on_diagnostic: impl FnMut(FramerDiagnostic),
        mut on_line: impl FnMut(Vec<u8>),
    ) {
        if chunk.is_empty() {
            return;
        }

        let mut pending: Vec<Vec<u8>> = Vec::new();
        let mut diagnostics: Vec<FramerDiagnostic> = Vec::new();
        let mut slice_start = 0usize;

        for i in 0..chunk.len() {
            let byte = chunk[i];

            if !self.has_seen_line_start && !is_ascii_whitespace(byte) {
                self.has_seen_line_start = true;
                self.is_json_candidate = byte == 0x7B || byte == 0x5B;
                if !self.is_json_candidate
                    && (self.in_json_string || self.is_escaping_json_string_character)
                {
                    self.in_json_string = false;
                    self.is_escaping_json_string_character = false;
                    diagnostics.push(FramerDiagnostic::NonJsonCandidateQuoteStateReset);
                }
            }

            if self.is_json_candidate {
                match byte {
                    0x22 => {
                        if self.in_json_string {
                            if self.is_escaping_json_string_character {
                                self.is_escaping_json_string_character = false;
                            } else {
                                self.in_json_string = false;
                            }
                        } else {
                            self.in_json_string = true;
                        }
                    }
                    0x5C => {
                        if self.in_json_string {
                            if self.is_escaping_json_string_character {
                                self.is_escaping_json_string_character = false;
                            } else {
                                self.is_escaping_json_string_character = true;
                            }
                        }
                    }
                    0x0A => {
                        if self.in_json_string {
                            self.is_escaping_json_string_character = false;
                        } else {
                            self.carry.extend_from_slice(&chunk[slice_start..=i]);
                            slice_start = i + 1;
                            self.emit_line(&mut pending);
                        }
                    }
                    _ => {
                        if self.in_json_string && self.is_escaping_json_string_character {
                            self.is_escaping_json_string_character = false;
                        }
                    }
                }
            } else if byte == 0x0A {
                self.carry.extend_from_slice(&chunk[slice_start..=i]);
                slice_start = i + 1;
                self.emit_line(&mut pending);
            }
        }

        if slice_start < chunk.len() {
            self.carry.extend_from_slice(&chunk[slice_start..]);
        }

        if self.carry.len() > self.limits.max_carry_bytes
            || self.carry.len() > self.limits.max_line_bytes
        {
            let retained = self.limits.tail_retain_bytes.min(self.carry.len());
            let dropped = self.carry.len() - retained;
            if retained > 0 {
                let tail_start = self.carry.len() - retained;
                self.carry.drain(..tail_start);
            } else {
                self.carry.clear();
            }
            self.in_json_string = false;
            self.is_escaping_json_string_character = false;
            self.has_seen_line_start = false;
            self.is_json_candidate = false;
            diagnostics.push(FramerDiagnostic::Overflow {
                dropped_bytes: dropped,
                retained_bytes: retained,
            });
        }

        for line in pending {
            on_line(line);
        }
        for diagnostic in diagnostics {
            on_diagnostic(diagnostic);
        }
    }

    /// Flushes any partial trailing line (EOF with no final newline) -- port of `flush(_:)`.
    pub fn flush(&mut self, mut on_line: impl FnMut(Vec<u8>)) {
        if !self.carry.is_empty() {
            on_line(std::mem::take(&mut self.carry));
        }
        self.in_json_string = false;
        self.is_escaping_json_string_character = false;
        self.has_seen_line_start = false;
        self.is_json_candidate = false;
    }

    /// Extracts the completed line from `carry` (stripping the trailing `\n` and optional `\r`),
    /// appends it to `pending`, and resets per-line state -- port of `emitLine(_:)`.
    fn emit_line(&mut self, pending: &mut Vec<Vec<u8>>) {
        let mut line = std::mem::take(&mut self.carry);
        line.pop(); // remove the \n
        if line.last() == Some(&0x0D) {
            line.pop(); // remove optional \r
        }
        pending.push(line);
        self.in_json_string = false;
        self.is_escaping_json_string_character = false;
        self.has_seen_line_start = false;
        self.is_json_candidate = false;
    }
}

/// Repairs raw control characters that appear inside JSON strings (for example unescaped LF/CR
/// bytes) so a JSON parser can decode the payload. Returns `None` when no repair is needed or the
/// payload is not a JSON candidate (`{...}` / `[...]`) -- port of `repairJSONStringControlCharacters`
/// (`ProcessStreamFraming.swift:246-304`). Operates purely on bytes; unlike the codec's own inline
/// sanitize pass (`codec::sanitize_json_control_characters_in_strings`), this never requires the
/// input to already be valid UTF-8 -- see `agent_claude::recovery`'s doc comment for the closed
/// control-char-repair open question this asymmetry was checked against.
pub fn repair_json_string_control_characters(data: &[u8]) -> Option<Vec<u8>> {
    if data.is_empty() {
        return None;
    }
    if !data.contains(&0x0A) && !data.contains(&0x0D) {
        return None;
    }

    let mut first_index = 0usize;
    while first_index < data.len() && is_ascii_whitespace(data[first_index]) {
        first_index += 1;
    }
    if first_index >= data.len() {
        return None;
    }
    let first_byte = data[first_index];
    if first_byte != 0x7B && first_byte != 0x5B {
        return None;
    }

    let mut repaired = Vec::with_capacity(data.len() + 64);
    let mut in_string = false;
    let mut escaping = false;

    for &byte in data {
        if in_string {
            if escaping {
                escaping = false;
                repaired.push(byte);
                continue;
            }
            if byte == 0x5C {
                escaping = true;
                repaired.push(byte);
                continue;
            }
            if byte == 0x22 {
                in_string = false;
                repaired.push(byte);
                continue;
            }
            match byte {
                0x0A => {
                    repaired.extend_from_slice(b"\\n");
                    continue;
                }
                0x0D => {
                    repaired.extend_from_slice(b"\\r");
                    continue;
                }
                _ => {
                    if byte < 0x20 {
                        repaired.extend_from_slice(format!("\\u00{byte:02X}").as_bytes());
                        continue;
                    }
                    repaired.push(byte);
                    continue;
                }
            }
        }
        if byte == 0x22 {
            in_string = true;
        }
        repaired.push(byte);
    }

    if repaired == data {
        None
    } else {
        Some(repaired)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collect(mut framer: LineFramer, chunks: &[&[u8]]) -> (Vec<Vec<u8>>, Vec<FramerDiagnostic>) {
        let mut lines = Vec::new();
        let mut diagnostics = Vec::new();
        for chunk in chunks {
            framer.feed(chunk, |d| diagnostics.push(d), |l| lines.push(l));
        }
        framer.flush(|l| lines.push(l));
        (lines, diagnostics)
    }

    #[test]
    fn splits_plain_lines_on_newline() {
        let (lines, diags) = collect(LineFramer::default(), &[b"one\ntwo\nthree"]);
        assert_eq!(
            lines,
            vec![b"one".to_vec(), b"two".to_vec(), b"three".to_vec()]
        );
        assert!(diags.is_empty());
    }

    #[test]
    fn strips_optional_trailing_cr() {
        let (lines, _) = collect(LineFramer::default(), &[b"one\r\ntwo\r\n"]);
        assert_eq!(lines, vec![b"one".to_vec(), b"two".to_vec()]);
    }

    #[test]
    fn json_candidate_keeps_embedded_newline_inside_string() {
        let (lines, _) = collect(
            LineFramer::default(),
            &[b"{\"a\":\"line\none\"}\n{\"b\":1}\n"],
        );
        assert_eq!(
            lines,
            vec![b"{\"a\":\"line\none\"}".to_vec(), b"{\"b\":1}".to_vec()]
        );
    }

    #[test]
    fn non_json_candidate_splits_on_every_newline_even_with_quotes() {
        let (lines, _) = collect(LineFramer::default(), &[b"garbage \"unterminated\nmore\n"]);
        assert_eq!(
            lines,
            vec![b"garbage \"unterminated".to_vec(), b"more".to_vec()]
        );
    }

    #[test]
    fn escaped_quote_does_not_toggle_string_state() {
        let (lines, _) = collect(
            LineFramer::default(),
            &[b"{\"a\":\"esc\\\"aped\nstill inside\"}\n"],
        );
        assert_eq!(
            lines,
            vec![b"{\"a\":\"esc\\\"aped\nstill inside\"}".to_vec()]
        );
    }

    #[test]
    fn overflow_drops_prefix_and_retains_tail() {
        let limits = FramerLimits {
            max_line_bytes: 16,
            max_carry_bytes: 16,
            tail_retain_bytes: 4,
        };
        let chunk = vec![b'a'; 32];
        let (lines, diags) = collect(LineFramer::new(limits), &[&chunk]);
        // No newline was ever seen, so nothing is emitted via `feed`; `collect`'s trailing
        // `flush()` then emits whatever overflow left behind -- the retained 4-byte tail.
        assert_eq!(lines, vec![vec![b'a'; 4]]);
        assert_eq!(
            diags,
            vec![FramerDiagnostic::Overflow {
                dropped_bytes: 28,
                retained_bytes: 4
            }]
        );
    }

    #[test]
    fn feed_is_correct_regardless_of_chunk_boundary_placement() {
        let whole = b"{\"a\":\"line\none\"}\ngarbage\nmore\n".to_vec();
        let (whole_lines, _) = collect(LineFramer::default(), &[whole.as_slice()]);

        for stride in [1usize, 3, 7] {
            let chunks: Vec<&[u8]> = whole.chunks(stride).collect();
            let (chunked_lines, _) = collect(LineFramer::default(), &chunks);
            assert_eq!(chunked_lines, whole_lines, "stride={stride}");
        }
    }

    #[test]
    fn repair_json_string_control_characters_requires_json_candidate_prefix() {
        assert_eq!(
            repair_json_string_control_characters(b"not-json-at-all\nwith-newline"),
            None
        );
    }

    #[test]
    fn repair_json_string_control_characters_escapes_lf_cr_and_other_control_bytes() {
        let repaired = repair_json_string_control_characters(b"{\"a\":\"x\ny\rz\x01w\"}").unwrap();
        assert_eq!(repaired, b"{\"a\":\"x\\ny\\rz\\u0001w\"}".to_vec());
    }

    #[test]
    fn repair_json_string_control_characters_returns_none_when_nothing_to_repair() {
        assert_eq!(
            repair_json_string_control_characters(b"{\"a\":\"clean\"}"),
            None
        );
    }
}
