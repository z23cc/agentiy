//! P3-3 slice-1 port of the workspace path-matching scoring kernel
//! (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathMatcher.swift`), extended
//! in slice-2a with the full resolution ladder (`resolve.rs`) and its candidate-bucket snapshot
//! (`indexes.rs`), driven over one immutable snapshot exactly like `PathMatchWorker.locateMany`.

mod contract;
mod indexes;
mod policy;
mod resolve;
mod score;

pub use contract::{
    CANDIDATE_STRIDE, PATH_MATCH_CONTRACT_VERSION_V1, SCORE_SCALE, STRING_RANGE_STRIDE,
};
pub use indexes::{
    PathMatchResolveError, PathMatchResolveLocation, PathMatchResolveRequestV1,
    PathMatchResolveResultV1,
};
pub use policy::{
    EmitFolded, emit_folded, is_allowed_ascii_byte, is_zero_width_or_format, to_lower_ascii,
    to_lower_ascii_char,
};
pub use resolve::PathMatchResolveService;
pub use score::{
    PathMatchScoreError, PathMatchScoreRequestV1, PathMatchScoreResultV1, PathMatchScoreService,
};
