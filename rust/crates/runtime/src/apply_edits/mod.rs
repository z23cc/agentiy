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
    ByteEdit, DiffChunk, DiffLine, DiffLineType, apply_byte_edits, apply_chunks, generate_diff,
    render_unified, split_lines_preserving_endings,
};
pub use engine::{
    ApplyError, ApplyMode, ApplyOperation, ApplyResult, ApplyStatus, ApplySubjectRequest,
    OperationOutcome, OutcomeStatus, apply_subject,
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
        for subject in &request.subjects {
            if cancellation.is_some_and(LeafCancellation::is_cancelled) {
                return Err(ApplyError::Cancelled);
            }
            results.push(apply_subject(subject)?);
        }
        if cancellation.is_some_and(LeafCancellation::is_cancelled) {
            return Err(ApplyError::Cancelled);
        }
        let compact_subjects = request
            .subjects
            .iter()
            .zip(&results)
            .map(|(subject, result)| (subject.original.as_slice(), result))
            .collect::<Vec<_>>();
        encode_compact_batch(&compact_subjects).map_err(ApplyError::Internal)
    }
}
