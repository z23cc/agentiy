use super::{
    ApplyResult, ApplyStatus, ByteEdit, DiffChunk, DiffLine, DiffLineType, OutcomeStatus,
    apply_byte_edits, apply_chunks,
};

pub const OPTIONAL_SENTINEL: u64 = u64::MAX;
pub const STRING_RANGE_STRIDE: usize = 2;
pub const BYTE_EDIT_STRIDE: usize = 4;
pub const CHUNK_STRIDE: usize = 8;
pub const DIFF_LINE_STRIDE: usize = 2;
pub const OUTCOME_STRIDE: usize = 3;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompactSubjectSummary {
    pub input_byte_count: u64,
    pub blob_start: u64,
    pub blob_count: u64,
    pub string_start: u64,
    pub string_count: u64,
    pub updated_text_string_index: u64,
    pub byte_edit_start: u64,
    pub byte_edit_count: u64,
    pub chunk_start: u64,
    pub chunk_count: u64,
    pub diff_line_start: u64,
    pub diff_line_count: u64,
    pub outcome_start: u64,
    pub outcome_count: u64,
    pub edits_requested: u64,
    pub edits_applied: u64,
    pub result_status_tag: u64,
    pub outcomes_present: bool,
    pub stats_present: bool,
    pub lines_changed: u64,
    pub stats_chunk_count: u64,
    pub note_string_index: u64,
    pub unified_diff_string_index: u64,
    pub tool_card_diff_string_index: u64,
    /// TD-3 §6.1: populated (a real blob string index) only for `Raw`-source subjects, where the
    /// buffer `byte_edit_words`/`chunk_words` offsets are relative to (`textdecode`'s output) is
    /// not independently reconstructible Swift-side from the request bytes alone. `OPTIONAL_SENTINEL`
    /// for `DecodedUtf8` subjects, which keep deriving "original" from the request exactly as before
    /// -- zero wire-size change for the untouched GUI apply-edits path.
    pub original_text_string_index: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CompactBatchResult {
    pub subject_summaries: Vec<CompactSubjectSummary>,
    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub byte_edit_words: Vec<u64>,
    pub chunk_words: Vec<u64>,
    pub diff_line_words: Vec<u64>,
    pub outcome_words: Vec<u64>,
}

fn word(value: usize) -> Result<u64, String> {
    u64::try_from(value).map_err(|_| "compact integer overflow".into())
}

struct SubjectEncoder<'a> {
    batch: &'a mut CompactBatchResult,
}

impl<'a> SubjectEncoder<'a> {
    fn string(&mut self, value: &str) -> Result<u64, String> {
        let start = self.batch.utf8_blob.len();
        self.batch.utf8_blob.extend_from_slice(value.as_bytes());
        let end = self.batch.utf8_blob.len();
        self.batch
            .string_range_words
            .extend([word(start)?, word(end)?]);
        word(self.batch.string_range_words.len() / STRING_RANGE_STRIDE - 1)
    }

    fn optional_string(&mut self, value: Option<&str>) -> Result<u64, String> {
        match value {
            Some(value) => self.string(value),
            None => Ok(OPTIONAL_SENTINEL),
        }
    }
}

pub fn encode_compact_batch(
    subjects: &[(&[u8], Option<&str>, &ApplyResult)],
) -> Result<CompactBatchResult, String> {
    let mut batch = CompactBatchResult::default();
    for (original, original_text_echo, result) in subjects {
        let byte_edit_start = batch.byte_edit_words.len() / BYTE_EDIT_STRIDE;
        let chunk_start = batch.chunk_words.len() / CHUNK_STRIDE;
        let diff_line_start = batch.diff_line_words.len() / DIFF_LINE_STRIDE;
        let outcome_start = batch.outcome_words.len() / OUTCOME_STRIDE;
        let blob_start = batch.utf8_blob.len();
        let string_start = batch.string_range_words.len() / STRING_RANGE_STRIDE;
        let (updated_text_index, note_index, unified_index, tool_card_index, original_text_index);
        {
            let mut encoder = SubjectEncoder { batch: &mut batch };
            updated_text_index = encoder.string(&result.updated_text)?;
            original_text_index = encoder.optional_string(*original_text_echo)?;
            for edit in &result.byte_edits {
                encoder.batch.byte_edit_words.extend([
                    word(edit.old_start)?,
                    word(edit.old_end)?,
                    word(edit.new_start)?,
                    word(edit.new_end)?,
                ]);
            }
            for chunk in &result.chunks {
                let line_start = encoder.batch.diff_line_words.len() / DIFF_LINE_STRIDE;
                for line in &chunk.lines {
                    let string_index = encoder.string(&line.content)?;
                    encoder
                        .batch
                        .diff_line_words
                        .extend([line.kind as u64, string_index]);
                }
                encoder.batch.chunk_words.extend([
                    word(chunk.start_line)?,
                    word(chunk.old_start_byte)?,
                    word(chunk.old_end_byte)?,
                    word(chunk.new_start_byte)?,
                    word(chunk.new_end_byte)?,
                    word(line_start)?,
                    word(chunk.lines.len())?,
                    0,
                ]);
            }
            if let Some(outcomes) = &result.outcomes {
                for outcome in outcomes {
                    let error_index = encoder.optional_string(outcome.error.as_deref())?;
                    encoder.batch.outcome_words.extend([
                        word(outcome.operation_index)?,
                        outcome.status as u64,
                        error_index,
                    ]);
                }
            }
            note_index = encoder.optional_string(result.note.as_deref())?;
            unified_index = encoder.optional_string(result.unified_diff.as_deref())?;
            tool_card_index = encoder.optional_string(result.tool_card_unified_diff.as_deref())?;
        }
        let blob_count = batch.utf8_blob.len() - blob_start;
        let string_count = batch.string_range_words.len() / STRING_RANGE_STRIDE - string_start;
        batch.subject_summaries.push(CompactSubjectSummary {
            input_byte_count: word(original.len())?,
            blob_start: word(blob_start)?,
            blob_count: word(blob_count)?,
            string_start: word(string_start)?,
            string_count: word(string_count)?,
            updated_text_string_index: updated_text_index,
            byte_edit_start: word(byte_edit_start)?,
            byte_edit_count: word(result.byte_edits.len())?,
            chunk_start: word(chunk_start)?,
            chunk_count: word(result.chunks.len())?,
            diff_line_start: word(diff_line_start)?,
            diff_line_count: word(
                batch.diff_line_words.len() / DIFF_LINE_STRIDE - diff_line_start,
            )?,
            outcome_start: word(outcome_start)?,
            outcome_count: word(result.outcomes.as_ref().map_or(0, Vec::len))?,
            edits_requested: word(result.edits_requested)?,
            edits_applied: word(result.edits_applied)?,
            result_status_tag: result.status as u64,
            outcomes_present: result.outcomes.is_some(),
            stats_present: result.lines_changed.is_some(),
            lines_changed: word(result.lines_changed.unwrap_or(0))?,
            stats_chunk_count: word(if result.lines_changed.is_some() {
                result.chunks.len()
            } else {
                0
            })?,
            note_string_index: note_index,
            unified_diff_string_index: unified_index,
            tool_card_diff_string_index: tool_card_index,
            original_text_string_index: original_text_index,
        });
    }
    Ok(batch)
}

fn usize_word(value: u64) -> Result<usize, String> {
    usize::try_from(value).map_err(|_| "compact word exceeds platform index".into())
}

fn checked_slice<'a, T>(items: &'a [T], start: usize, count: usize) -> Result<&'a [T], String> {
    let end = start.checked_add(count).ok_or("compact range overflow")?;
    items
        .get(start..end)
        .ok_or_else(|| "compact range out of bounds".into())
}

pub fn validate_compact_batch(
    batch: &CompactBatchResult,
    originals: &[&[u8]],
) -> Result<Vec<String>, String> {
    if batch.subject_summaries.len() != originals.len()
        || batch.string_range_words.len() % STRING_RANGE_STRIDE != 0
        || batch.byte_edit_words.len() % BYTE_EDIT_STRIDE != 0
        || batch.chunk_words.len() % CHUNK_STRIDE != 0
        || batch.diff_line_words.len() % DIFF_LINE_STRIDE != 0
        || batch.outcome_words.len() % OUTCOME_STRIDE != 0
    {
        return Err("compact table shape mismatch".into());
    }
    let mut blob_cursor = 0;
    let mut string_cursor = 0;
    let mut edit_cursor = 0;
    let mut chunk_cursor = 0;
    let mut line_cursor = 0;
    let mut outcome_cursor = 0;
    let mut decoded_results = Vec::with_capacity(originals.len());

    for (summary, original) in batch.subject_summaries.iter().zip(originals) {
        let blob_start = usize_word(summary.blob_start)?;
        let blob_count = usize_word(summary.blob_count)?;
        let string_start = usize_word(summary.string_start)?;
        let string_count = usize_word(summary.string_count)?;
        let edit_start = usize_word(summary.byte_edit_start)?;
        let edit_count = usize_word(summary.byte_edit_count)?;
        let chunk_start = usize_word(summary.chunk_start)?;
        let chunk_count = usize_word(summary.chunk_count)?;
        let diff_start = usize_word(summary.diff_line_start)?;
        let diff_count = usize_word(summary.diff_line_count)?;
        let outcome_start = usize_word(summary.outcome_start)?;
        let outcome_count = usize_word(summary.outcome_count)?;
        if blob_start != blob_cursor
            || string_start != string_cursor
            || edit_start != edit_cursor
            || chunk_start != chunk_cursor
            || diff_start != line_cursor
            || outcome_start != outcome_cursor
            || usize_word(summary.input_byte_count)? != original.len()
        {
            return Err("non-contiguous compact subject cursors".into());
        }
        let blob_end = blob_start.checked_add(blob_count).ok_or("blob overflow")?;
        checked_slice(&batch.utf8_blob, blob_start, blob_count)?;
        let ranges = checked_slice(
            &batch.string_range_words,
            string_start * 2,
            string_count * 2,
        )?;
        let mut strings = Vec::with_capacity(string_count);
        let mut local_blob_cursor = blob_start;
        for row in ranges.chunks_exact(2) {
            let start = usize_word(row[0])?;
            let end = usize_word(row[1])?;
            if start != local_blob_cursor || end < start || end > blob_end {
                return Err("invalid or non-contiguous subject string ranges".into());
            }
            let bytes = &batch.utf8_blob[start..end];
            strings.push(
                std::str::from_utf8(bytes)
                    .map_err(|_| "invalid compact UTF-8")?
                    .to_owned(),
            );
            local_blob_cursor = end;
        }
        if local_blob_cursor != blob_end {
            return Err("subject blob not exhausted".into());
        }
        let local_string = |absolute: u64| -> Result<&str, String> {
            let absolute = usize_word(absolute)?;
            if absolute < string_start || absolute >= string_start + string_count {
                return Err("cross-subject string index".into());
            }
            Ok(strings[absolute - string_start].as_str())
        };
        let updated = local_string(summary.updated_text_string_index)?.to_owned();
        let updated_bytes = updated.as_bytes();

        let edit_words = checked_slice(&batch.byte_edit_words, edit_start * 4, edit_count * 4)?;
        let mut edits = Vec::with_capacity(edit_count);
        for row in edit_words.chunks_exact(4) {
            let edit = ByteEdit {
                old_start: usize_word(row[0])?,
                old_end: usize_word(row[1])?,
                new_start: usize_word(row[2])?,
                new_end: usize_word(row[3])?,
            };
            let original_text =
                std::str::from_utf8(original).map_err(|_| "original is not UTF-8")?;
            if !original_text.is_char_boundary(edit.old_start)
                || !original_text.is_char_boundary(edit.old_end)
                || !updated.is_char_boundary(edit.new_start)
                || !updated.is_char_boundary(edit.new_end)
            {
                return Err("byte edit is not on a UTF-8 boundary".into());
            }
            edits.push(edit);
        }
        apply_byte_edits(original, updated_bytes, &edits)
            .ok_or("byte-edit reconstruction mismatch")?;

        let chunk_words = checked_slice(&batch.chunk_words, chunk_start * 8, chunk_count * 8)?;
        let mut chunks = Vec::with_capacity(chunk_count);
        for row in chunk_words.chunks_exact(8) {
            if row[7] != 0 {
                return Err("unknown v1 chunk flags".into());
            }
            let row_line_start = usize_word(row[5])?;
            let row_line_count = usize_word(row[6])?;
            if row_line_start < diff_start
                || row_line_start + row_line_count > diff_start + diff_count
            {
                return Err("chunk diff-line range is not subject-local".into());
            }
            let words = checked_slice(
                &batch.diff_line_words,
                row_line_start * 2,
                row_line_count * 2,
            )?;
            let mut lines = Vec::with_capacity(row_line_count);
            for line in words.chunks_exact(2) {
                let kind = match line[0] {
                    0 => DiffLineType::Context,
                    1 => DiffLineType::Addition,
                    2 => DiffLineType::Removal,
                    _ => return Err("invalid diff line tag".into()),
                };
                lines.push(DiffLine {
                    kind,
                    content: local_string(line[1])?.to_owned(),
                });
            }
            chunks.push(DiffChunk {
                start_line: usize_word(row[0])?,
                old_start_byte: usize_word(row[1])?,
                old_end_byte: usize_word(row[2])?,
                new_start_byte: usize_word(row[3])?,
                new_end_byte: usize_word(row[4])?,
                lines,
            });
        }
        let original_text = std::str::from_utf8(original).map_err(|_| "original is not UTF-8")?;
        if apply_chunks(original_text, &chunks).as_deref() != Some(updated.as_str()) {
            return Err("semantic chunk reconstruction mismatch".into());
        }

        let outcomes = checked_slice(&batch.outcome_words, outcome_start * 3, outcome_count * 3)?;
        if summary.outcomes_present != (outcome_count > 0 || summary.edits_requested == 0) {
            return Err("outcomes-present mismatch".into());
        }
        let mut successes = 0usize;
        for (expected, row) in outcomes.chunks_exact(3).enumerate() {
            if usize_word(row[0])? != expected {
                return Err("non-contiguous outcome indices".into());
            }
            match row[1] {
                x if x == OutcomeStatus::Success as u64 => successes += 1,
                x if x == OutcomeStatus::Failed as u64 => {
                    if row[2] == OPTIONAL_SENTINEL {
                        return Err("failed outcome lacks error".into());
                    }
                }
                _ => return Err("invalid outcome status tag".into()),
            }
            if row[2] != OPTIONAL_SENTINEL {
                local_string(row[2])?;
            }
        }
        if summary.outcomes_present
            && (successes != usize_word(summary.edits_applied)?
                || outcome_count != usize_word(summary.edits_requested)?)
        {
            return Err("outcome counts disagree with summary".into());
        }
        let expected_status = if summary.edits_applied == summary.edits_requested {
            ApplyStatus::Success as u64
        } else if summary.edits_applied == 0 {
            ApplyStatus::Failed as u64
        } else {
            ApplyStatus::Partial as u64
        };
        if summary.result_status_tag != expected_status {
            return Err("result status disagrees with counts".into());
        }
        for optional in [
            summary.note_string_index,
            summary.unified_diff_string_index,
            summary.tool_card_diff_string_index,
        ] {
            if optional != OPTIONAL_SENTINEL {
                local_string(optional)?;
            }
        }
        decoded_results.push(updated);
        blob_cursor = blob_end;
        string_cursor += string_count;
        edit_cursor += edit_count;
        chunk_cursor += chunk_count;
        line_cursor += diff_count;
        outcome_cursor += outcome_count;
    }
    if blob_cursor != batch.utf8_blob.len()
        || string_cursor != batch.string_range_words.len() / 2
        || edit_cursor != batch.byte_edit_words.len() / 4
        || chunk_cursor != batch.chunk_words.len() / 8
        || line_cursor != batch.diff_line_words.len() / 2
        || outcome_cursor != batch.outcome_words.len() / 3
    {
        return Err("compact batch tables not exhausted".into());
    }
    Ok(decoded_results)
}
