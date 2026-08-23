//! P6-4 (`docs/architecture/rust-agent-claude-v1.md` §5.4, design §4.4): the stderr tail cap --
//! port of `appendTail(limit: 256 * 1024)` (`ClaudeNativeProcessSessionController.swift:913`,
//! generic helper `ProcessStreamFraming.swift:4-10`). Unlike stdout, stderr is not framed/decoded
//! -- it is retained only as a bounded diagnostic tail.

const STDERR_TAIL_LIMIT_BYTES: usize = 256 * 1024;

#[derive(Debug, Default)]
pub struct StderrTail {
    buf: Vec<u8>,
}

impl StderrTail {
    pub fn append(&mut self, chunk: &[u8]) {
        self.buf.extend_from_slice(chunk);
        if self.buf.len() > STDERR_TAIL_LIMIT_BYTES {
            let overflow = self.buf.len() - STDERR_TAIL_LIMIT_BYTES;
            self.buf.drain(..overflow);
        }
    }

    pub fn snapshot(&self) -> &[u8] {
        &self.buf
    }

    pub fn len(&self) -> usize {
        self.buf.len()
    }

    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retains_only_the_trailing_cap() {
        let mut tail = StderrTail::default();
        tail.append(&vec![b'a'; STDERR_TAIL_LIMIT_BYTES]);
        tail.append(b"tail-marker");
        assert_eq!(tail.len(), STDERR_TAIL_LIMIT_BYTES);
        assert!(tail.snapshot().ends_with(b"tail-marker"));
    }
}
