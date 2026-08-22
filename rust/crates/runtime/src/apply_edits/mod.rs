mod compact;
mod diff;
mod engine;
mod matcher;

use crate::LeafCancellation;

pub use compact::{
    BYTE_EDIT_STRIDE, CHUNK_STRIDE, CompactBatchResult, CompactSubjectSummary, DIFF_LINE_STRIDE,
    OPTIONAL_SENTINEL, OUTCOME_STRIDE, STRING_RANGE_STRIDE, encode_compact_batch,
    validate_compact_batch,
};
pub use diff::{
    ByteEdit, DiffChunk, DiffError, DiffLine, DiffLineType, apply_byte_edits, apply_chunks,
    generate_diff, render_unified, split_lines_preserving_endings,
};
pub use engine::{
    ApplyError, ApplyMode, ApplyOperation, ApplyResult, ApplySourceKind, ApplyStatus,
    ApplySubjectRequest, OperationOutcome, OutcomeStatus, apply_subject, effective_original_text,
};
pub use matcher::{
    LineData, MAX_FUZZY_KEYS, MatchError, build_line_index, canonical_key, dice_coefficient,
    match_selector, process_line,
};

pub const APPLY_EDITS_CONTRACT_VERSION_V1: u16 = 1;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApplyEditsBatchRequestV1 {
    pub contract_version: u16,
    pub subjects: Vec<ApplySubjectRequest>,
}

#[derive(Default)]
pub struct ApplyEditsService;

impl ApplyEditsService {
    pub fn apply_batch(
        &self,
        request: ApplyEditsBatchRequestV1,
    ) -> Result<CompactBatchResult, ApplyError> {
        self.apply_batch_with_cancellation(request, None)
    }

    pub fn apply_batch_with_cancellation(
        &self,
        request: ApplyEditsBatchRequestV1,
        cancellation: Option<&LeafCancellation>,
    ) -> Result<CompactBatchResult, ApplyError> {
        if request.contract_version != APPLY_EDITS_CONTRACT_VERSION_V1 {
            return Err(ApplyError::InvalidParams(format!(
                "unknown contract version {}",
                request.contract_version
            )));
        }
        let mut results = Vec::with_capacity(request.subjects.len());
        // Swift's compact-result validator reconstructs byte-edits/chunks against a local
        // "original" string to independently verify offsets. For `DecodedUtf8` subjects it
        // re-derives that from the request bytes it already sent (untouched, §6.1). For `Raw`
        // subjects the buffer `apply_subject` actually diffed against is `textdecode`'s output,
        // which Swift cannot re-derive locally -- so it must be echoed back via
        // `original_text_string_index` (TD-3 §6.1). `effective_original_text` recomputes the
        // same (pure, cheap) decode `apply_subject` already ran, once per subject.
        let mut effective_originals = Vec::with_capacity(request.subjects.len());
        for subject in &request.subjects {
            if cancellation.is_some_and(LeafCancellation::is_cancelled) {
                return Err(ApplyError::Cancelled);
            }
            results.push(apply_subject(subject)?);
            effective_originals.push(effective_original_text(subject)?);
        }
        if cancellation.is_some_and(LeafCancellation::is_cancelled) {
            return Err(ApplyError::Cancelled);
        }
        let compact_subjects = request
            .subjects
            .iter()
            .zip(&effective_originals)
            .zip(&results)
            .map(|((subject, effective_original), result)| {
                let echo = match subject.source_kind {
                    ApplySourceKind::DecodedUtf8 => None,
                    ApplySourceKind::Raw => Some(effective_original.as_str()),
                };
                (subject.original.as_slice(), echo, result)
            })
            .collect::<Vec<_>>();
        encode_compact_batch(&compact_subjects).map_err(ApplyError::Internal)
    }
}
