//! P3-3 slice-1 port of the workspace path-matching scoring kernel
//! (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathMatcher.swift`).

mod contract;
mod policy;
mod score;

pub use contract::{CANDIDATE_STRIDE, PATH_MATCH_CONTRACT_VERSION_V1, SCORE_SCALE, STRING_RANGE_STRIDE};
pub use policy::{
    EmitFolded, emit_folded, is_allowed_ascii_byte, is_zero_width_or_format, to_lower_ascii,
    to_lower_ascii_char,
};
pub use score::{PathMatchScoreError, PathMatchScoreRequestV1, PathMatchScoreResultV1, PathMatchScoreService};
