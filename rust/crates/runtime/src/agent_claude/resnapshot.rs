//! P6-5 (design §4.4 D-8, `docs/architecture/rust-agent-claude-v1.md` §5.4): the per-turn
//! resnapshot buffer -- new machinery (not a port; there is no Swift analogue) that retains enough
//! of the live turn's text to answer a resnapshot request after an event-queue gap (design §4.4:
//! "because events may be dropped under pressure, Rust must retain enough of the live turn to
//! answer a resnapshot"). Cap **8 MiB** (a
//! stated placeholder, not yet derived from real traffic -- see [`RESNAPSHOT_BUFFER_CAP_BYTES`]'s
//! own doc), overflow policy **truncate head**, with a lossless `transcriptTruncated` marker and a
//! diagnostic counter -- "if it ever truncates, a user could lose transcript text that today would
//! have arrived... it ships with an explicit marker event, a diagnostic counter, and a cap chosen
//! from E-P6-3's observed maximum with a wide margin."
//!
//! Deliberately structured like [`super::process::stderr_tail::StderrTail`] (same cap-and-drain
//! shape) rather than invented fresh -- this crate has exactly one established idiom for "bounded
//! byte accumulator, drop from the head on overflow" and D-8 reuses it rather than adding a second.
//! The one addition beyond that shared shape is what D-8 requires and stderr's tail does not carry:
//! a per-truncation diagnostic (contract: "increment a diagnostic counter") and an explicit
//! `reset()` for the turn boundary (stderr's tail is process-lifetime; this buffer is turn-lifetime,
//! reset by the caller -- the future P6-6 scope wiring -- at every `TurnInFlight` transition).

/// The D-8 cap: 8 MiB. Design §4.4 calls for this to be "tuned by E-P6-3's observed maximum with a
/// wide margin (>= 4x)" -- **that measurement is user-blocked**, same root cause as E-P6-1(a)/(b)
/// (`rust/benchmarks/results/v1/p6-2-claude-derisking-v1.md` §7: a synthetic flood rate has no
/// relationship to a real Claude Code turn's size distribution, so deriving a cap from one would be
/// manufactured confidence). The contract doc's own placeholder -- 8 MiB, matching the framer's line
/// cap -- is carried here unchanged: "a reasonable placeholder pending real data, not a
/// derived-and-confirmed number" (same source, same section). Revisit when the real-traffic corpus
/// unblocks E-P6-3(e).
pub const RESNAPSHOT_BUFFER_CAP_BYTES: usize = 8 * 1024 * 1024;

/// Emitted the instant an append would exceed the cap and bytes are dropped from the head.
/// Mirrors [`super::process::queue::QueueEvent`]/[`super::recovery::RecoveryDiagnostic`]'s
/// callback-diagnostic convention: the caller decides what to do with it (increment a counter,
/// publish a lossless `transcriptTruncated` event, or both -- P6-6's job once this is wired to a
/// live scope).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResnapshotTruncated {
    pub dropped_bytes: usize,
    pub retained_bytes: usize,
}

/// The per-turn resnapshot buffer. One instance per live turn (or one instance `reset()` at every
/// turn boundary -- either is equivalent; the scope wiring at P6-6 picks whichever fits its own
/// turn-lifecycle bookkeeping).
#[derive(Debug, Default)]
pub struct ResnapshotBuffer {
    buf: Vec<u8>,
}

impl ResnapshotBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends `chunk` (the caller's serialized representation of one turn-scoped event -- text
    /// delta bytes, a compact event encoding, whatever P6-6's scope decides to retain; this module
    /// is agnostic to the payload shape, matching D-8's "generic helper" framing). Truncates from
    /// the **head** on overflow (never the tail -- the tail is the most recent, most relevant-for-
    /// resnapshot content) and returns `Some(ResnapshotTruncated)` exactly when truncation occurred
    /// on this call, so the caller can emit exactly one diagnostic per truncating append rather than
    /// inferring it from a before/after length comparison.
    pub fn append(&mut self, chunk: &[u8]) -> Option<ResnapshotTruncated> {
        self.buf.extend_from_slice(chunk);
        if self.buf.len() > RESNAPSHOT_BUFFER_CAP_BYTES {
            let dropped_bytes = self.buf.len() - RESNAPSHOT_BUFFER_CAP_BYTES;
            self.buf.drain(..dropped_bytes);
            Some(ResnapshotTruncated { dropped_bytes, retained_bytes: self.buf.len() })
        } else {
            None
        }
    }

    /// The retained bytes, oldest-truncated / newest-retained, for answering a resnapshot request.
    pub fn snapshot(&self) -> &[u8] {
        &self.buf
    }

    pub fn len(&self) -> usize {
        self.buf.len()
    }

    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    /// Clears retained content for a new turn. D-8's buffer is explicitly per-turn (design §4.4);
    /// nothing survives across a turn boundary because a resnapshot always answers for the *current*
    /// live turn, never a completed one (completed turns are already durably persisted Swift-side,
    /// design §6).
    pub fn reset(&mut self) {
        self.buf.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retains_only_the_trailing_cap_and_reports_the_drop() {
        let mut buffer = ResnapshotBuffer::new();
        assert_eq!(buffer.append(&vec![b'a'; RESNAPSHOT_BUFFER_CAP_BYTES]), None, "filling exactly to the cap must not truncate");
        let truncated = buffer.append(b"tail-marker").expect("appending past the cap must report truncation");
        assert_eq!(truncated.dropped_bytes, b"tail-marker".len());
        assert_eq!(truncated.retained_bytes, RESNAPSHOT_BUFFER_CAP_BYTES);
        assert_eq!(buffer.len(), RESNAPSHOT_BUFFER_CAP_BYTES);
        assert!(buffer.snapshot().ends_with(b"tail-marker"), "overflow must drop from the head, retaining the most recent bytes");
    }

    #[test]
    fn a_single_append_that_alone_exceeds_the_cap_still_retains_only_its_own_tail() {
        let mut buffer = ResnapshotBuffer::new();
        let oversized = vec![b'x'; RESNAPSHOT_BUFFER_CAP_BYTES + 1024];
        let truncated = buffer.append(&oversized).expect("must truncate");
        assert_eq!(truncated.dropped_bytes, 1024);
        assert_eq!(buffer.len(), RESNAPSHOT_BUFFER_CAP_BYTES);
    }

    #[test]
    fn reset_clears_retained_content_for_the_next_turn() {
        let mut buffer = ResnapshotBuffer::new();
        buffer.append(b"turn one content");
        assert!(!buffer.is_empty());
        buffer.reset();
        assert!(buffer.is_empty());
        assert_eq!(buffer.snapshot(), b"");
    }

    #[test]
    fn no_fifth_structure_the_cap_is_named_and_matches_the_contract() {
        assert_eq!(RESNAPSHOT_BUFFER_CAP_BYTES, 8 * 1024 * 1024, "D-8's cap is a named constant, not a magic number restated ad hoc");
    }
}
