#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u64)]
pub enum DiffLineType {
    Context = 0,
    Addition = 1,
    Removal = 2,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffLine {
    pub kind: DiffLineType,
    /// Includes its original line ending. This is intentionally byte-preserving.
    pub content: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffChunk {
    pub start_line: usize,
    pub old_start_byte: usize,
    pub old_end_byte: usize,
    pub new_start_byte: usize,
    pub new_end_byte: usize,
    pub lines: Vec<DiffLine>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ByteEdit {
    pub old_start: usize,
    pub old_end: usize,
    pub new_start: usize,
    pub new_end: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Op {
    Equal(String),
    Add(String),
    Delete(String),
}

/// Splits without normalizing CRLF/CR/LF and keeps every ending on its line.
pub fn split_lines_preserving_endings(text: &str) -> Vec<String> {
    if text.is_empty() {
        return Vec::new();
    }
    let bytes = text.as_bytes();
    let mut lines = Vec::new();
    let mut start = 0;
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\r' {
            index += 1;
            if index < bytes.len() && bytes[index] == b'\n' {
                index += 1;
            }
            lines.push(text[start..index].to_owned());
            start = index;
        } else if bytes[index] == b'\n' {
            index += 1;
            lines.push(text[start..index].to_owned());
            start = index;
        } else {
            index += 1;
        }
    }
    if start < text.len() {
        lines.push(text[start..].to_owned());
    }
    lines
}

fn line_offsets(lines: &[String]) -> Vec<usize> {
    let mut result = Vec::with_capacity(lines.len() + 1);
    result.push(0);
    for line in lines {
        result.push(result.last().copied().unwrap() + line.len());
    }
    result
}

/// Myers O((N+M)D) shortest edit script over byte-preserving lines.
fn myers_ops(old: &[String], new: &[String]) -> Vec<Op> {
    let n = old.len() as isize;
    let m = new.len() as isize;
    let max = (n + m) as usize;
    let offset = max as isize + 1;
    let mut v = vec![0isize; max * 2 + 3];
    v[(offset + 1) as usize] = 0;
    let mut trace = Vec::new();
    let mut final_d = 0;

    'outer: for d in 0..=max {
        trace.push(v.clone());
        for k in (-(d as isize)..=d as isize).step_by(2) {
            let slot = (offset + k) as usize;
            let mut x = if k == -(d as isize) || (k != d as isize && v[slot - 1] < v[slot + 1]) {
                v[slot + 1]
            } else {
                v[slot - 1] + 1
            };
            let mut y = x - k;
            while x < n && y < m && old[x as usize] == new[y as usize] {
                x += 1;
                y += 1;
            }
            v[slot] = x;
            if x >= n && y >= m {
                final_d = d;
                break 'outer;
            }
        }
    }

    let mut x = n;
    let mut y = m;
    let mut reversed = Vec::new();
    for d in (0..=final_d).rev() {
        let previous = &trace[d];
        let k = x - y;
        let slot = (offset + k) as usize;
        let previous_k =
            if k == -(d as isize) || (k != d as isize && previous[slot - 1] < previous[slot + 1]) {
                k + 1
            } else {
                k - 1
            };
        let previous_x = previous[(offset + previous_k) as usize];
        let previous_y = previous_x - previous_k;
        while x > previous_x && y > previous_y {
            reversed.push(Op::Equal(old[(x - 1) as usize].clone()));
            x -= 1;
            y -= 1;
        }
        if d == 0 {
            break;
        }
        if x == previous_x {
            reversed.push(Op::Add(new[(y - 1) as usize].clone()));
            y -= 1;
        } else {
            reversed.push(Op::Delete(old[(x - 1) as usize].clone()));
            x -= 1;
        }
    }
    reversed.reverse();
    reversed
}

pub fn generate_diff(original: &str, updated: &str) -> (Vec<ByteEdit>, Vec<DiffChunk>) {
    if original == updated {
        return (Vec::new(), Vec::new());
    }
    let old_lines = split_lines_preserving_endings(original);
    let new_lines = split_lines_preserving_endings(updated);
    let old_offsets = line_offsets(&old_lines);
    let new_offsets = line_offsets(&new_lines);
    let ops = myers_ops(&old_lines, &new_lines);

    let mut byte_edits = Vec::new();
    let mut chunks = Vec::new();
    let mut old_line = 0;
    let mut new_line = 0;
    let mut index = 0;
    while index < ops.len() {
        if matches!(ops[index], Op::Equal(_)) {
            old_line += 1;
            new_line += 1;
            index += 1;
            continue;
        }
        let start_old = old_line;
        let start_new = new_line;
        let mut diff_lines = Vec::new();
        while index < ops.len() && !matches!(ops[index], Op::Equal(_)) {
            match &ops[index] {
                Op::Delete(line) => {
                    diff_lines.push(DiffLine {
                        kind: DiffLineType::Removal,
                        content: line.clone(),
                    });
                    old_line += 1;
                }
                Op::Add(line) => {
                    diff_lines.push(DiffLine {
                        kind: DiffLineType::Addition,
                        content: line.clone(),
                    });
                    new_line += 1;
                }
                Op::Equal(_) => unreachable!(),
            }
            index += 1;
        }
        let edit = ByteEdit {
            old_start: old_offsets[start_old],
            old_end: old_offsets[old_line],
            new_start: new_offsets[start_new],
            new_end: new_offsets[new_line],
        };
        chunks.push(DiffChunk {
            start_line: start_old,
            old_start_byte: edit.old_start,
            old_end_byte: edit.old_end,
            new_start_byte: edit.new_start,
            new_end_byte: edit.new_end,
            lines: diff_lines,
        });
        byte_edits.push(edit);
    }
    (byte_edits, chunks)
}

pub fn apply_byte_edits(original: &[u8], updated: &[u8], edits: &[ByteEdit]) -> Option<Vec<u8>> {
    let mut result = Vec::with_capacity(updated.len());
    let mut old_cursor = 0;
    let mut new_cursor = 0;
    for edit in edits {
        if edit.old_start < old_cursor
            || edit.new_start < new_cursor
            || edit.old_start > edit.old_end
            || edit.new_start > edit.new_end
            || edit.old_end > original.len()
            || edit.new_end > updated.len()
        {
            return None;
        }
        result.extend_from_slice(&original[old_cursor..edit.old_start]);
        result.extend_from_slice(&updated[edit.new_start..edit.new_end]);
        old_cursor = edit.old_end;
        new_cursor = edit.new_end;
    }
    result.extend_from_slice(&original[old_cursor..]);
    (result == updated).then_some(result)
}

pub fn apply_chunks(original: &str, chunks: &[DiffChunk]) -> Option<String> {
    let mut lines = split_lines_preserving_endings(original);
    let mut adjusted: Vec<_> = chunks.iter().map(|c| c.start_line).collect();
    for (index, chunk) in chunks.iter().enumerate() {
        let start = adjusted[index];
        if start > lines.len() {
            return None;
        }
        let old_count = chunk
            .lines
            .iter()
            .filter(|l| l.kind != DiffLineType::Addition)
            .count();
        let replacement: Vec<_> = chunk
            .lines
            .iter()
            .filter(|l| l.kind != DiffLineType::Removal)
            .map(|l| l.content.clone())
            .collect();
        if start + old_count > lines.len() {
            return None;
        }
        let expected: Vec<_> = chunk
            .lines
            .iter()
            .filter(|l| l.kind != DiffLineType::Addition)
            .map(|l| l.content.as_str())
            .collect();
        if !expected
            .iter()
            .zip(&lines[start..start + old_count])
            .all(|(a, b)| *a == b)
        {
            return None;
        }
        lines.splice(start..start + old_count, replacement);
        let delta = chunk
            .lines
            .iter()
            .filter(|l| l.kind == DiffLineType::Addition)
            .count() as isize
            - chunk
                .lines
                .iter()
                .filter(|l| l.kind == DiffLineType::Removal)
                .count() as isize;
        if delta != 0 {
            for later in index + 1..adjusted.len() {
                if adjusted[later] > start {
                    adjusted[later] =
                        (adjusted[later] as isize + delta).clamp(0, lines.len() as isize) as usize;
                }
            }
        }
    }
    Some(lines.concat())
}

pub fn render_unified(path: &str, chunks: &[DiffChunk]) -> Option<String> {
    if chunks.is_empty() {
        return None;
    }
    let path = path.strip_prefix('/').unwrap_or(path);
    let mut output = format!("--- a/{path}\n+++ b/{path}\n");
    let mut delta = 0isize;
    for chunk in chunks {
        let old_count = chunk
            .lines
            .iter()
            .filter(|l| l.kind != DiffLineType::Addition)
            .count();
        let new_count = chunk
            .lines
            .iter()
            .filter(|l| l.kind != DiffLineType::Removal)
            .count();
        let old_start = chunk.start_line + 1;
        let new_start = (old_start as isize + delta).max(1) as usize;
        output.push_str(&format!(
            "@@ -{old_start},{old_count} +{new_start},{new_count} @@\n"
        ));
        for line in &chunk.lines {
            output.push(match line.kind {
                DiffLineType::Context => ' ',
                DiffLineType::Addition => '+',
                DiffLineType::Removal => '-',
            });
            output.push_str(line.content.trim_end_matches(['\r', '\n']));
            output.push('\n');
        }
        delta += new_count as isize - old_count as isize;
    }
    Some(output)
}
