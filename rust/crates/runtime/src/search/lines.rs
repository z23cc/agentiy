use super::ByteRange;

#[derive(Debug)]
pub(crate) struct LineTable {
    ranges: Vec<ByteRange>,
}

impl LineTable {
    pub(crate) fn new(subject: &[u8]) -> Self {
        let mut ranges = Vec::new();
        if subject.is_empty() {
            return Self { ranges };
        }
        let mut start = 0usize;
        let mut index = 0usize;
        while index < subject.len() {
            if subject[index] == b'\r' || subject[index] == b'\n' {
                ranges.push(ByteRange::new(start, index));
                if subject[index] == b'\r' && subject.get(index + 1) == Some(&b'\n') {
                    index += 1;
                }
                index += 1;
                start = index;
            } else {
                index += 1;
            }
        }
        if start < subject.len() {
            ranges.push(ByteRange::new(start, subject.len()));
        }
        Self { ranges }
    }

    pub(crate) fn len(&self) -> usize {
        self.ranges.len()
    }

    pub(crate) fn range(&self, line: usize) -> Option<ByteRange> {
        self.ranges.get(line).copied()
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = (usize, ByteRange)> + '_ {
        self.ranges.iter().copied().enumerate()
    }

    pub(crate) fn line_for_offset(&self, offset: usize) -> Option<usize> {
        let candidate = self
            .ranges
            .partition_point(|range| usize::try_from(range.end).unwrap_or(usize::MAX) < offset);
        self.ranges.get(candidate).and_then(|range| {
            let start = usize::try_from(range.start).ok()?;
            let end = usize::try_from(range.end).ok()?;
            (start <= offset && offset <= end).then_some(candidate)
        })
    }

    pub(crate) fn context(&self, line: usize, count: usize) -> (Vec<ByteRange>, Vec<ByteRange>) {
        let before_start = line.saturating_sub(count);
        let before = self.ranges[before_start..line].to_vec();
        let after_end = self
            .ranges
            .len()
            .min(line.saturating_add(count).saturating_add(1));
        let after = self.ranges[line.saturating_add(1)..after_end].to_vec();
        (before, after)
    }
}

impl ByteRange {
    pub(crate) fn new(start: usize, end: usize) -> Self {
        Self {
            start: u64::try_from(start).expect("usize fits in u64 on supported targets"),
            end: u64::try_from(end).expect("usize fits in u64 on supported targets"),
        }
    }
}
