use super::wildmatch;
use super::{LeafCancellation, RegexDiagnostic};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PathSnapshot {
    pub standardized_full_path: String,
    pub standardized_relative_path: String,
    pub standardized_root_path: String,
    pub client_display_path: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PathClause {
    ExactFile {
        abs_path: String,
        rel_path: String,
        restricted_root_path: Option<String>,
    },
    ExactFolder {
        abs_lower: String,
        rel_lower: String,
        restricted_root_path: Option<String>,
    },
    Glob {
        pattern: String,
        restricted_root_path: Option<String>,
    },
    LegacyPrefix {
        candidate_lower: String,
    },
}

#[derive(Clone, Debug)]
pub struct PathFilterRequest {
    pub snapshots: Vec<PathSnapshot>,
    pub clauses: Vec<PathClause>,
    pub case_insensitive: bool,
    pub cancellation: LeafCancellation,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PathFilterResult {
    pub matched_snapshot_indices: Vec<u32>,
    pub visited_snapshot_count: u64,
    pub cancelled: bool,
    pub diagnostic: PathDiagnostic,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PathDiagnostic {
    pub visited_snapshot_count: u64,
    pub matched_snapshot_count: u64,
    pub cancelled: bool,
}

#[derive(Clone, Debug)]
pub struct FolderSuffixRequest {
    pub fragment: String,
    pub relative_paths: Vec<String>,
    pub case_insensitive: bool,
    pub cancellation: LeafCancellation,
}

impl super::SearchLeaf {
    pub fn filter_paths(&self, request: &PathFilterRequest) -> PathFilterResult {
        let mut matched_snapshot_indices = Vec::new();
        let mut visited_snapshot_count = 0u64;
        let mut cancelled = false;
        for (index, snapshot) in request.snapshots.iter().enumerate() {
            if request.cancellation.is_cancelled() {
                cancelled = true;
                break;
            }
            visited_snapshot_count = visited_snapshot_count.saturating_add(1);
            if request
                .clauses
                .iter()
                .any(|clause| clause_matches(clause, snapshot, request.case_insensitive))
            {
                if let Ok(index) = u32::try_from(index) {
                    matched_snapshot_indices.push(index);
                }
            }
        }
        if request.cancellation.is_cancelled() {
            cancelled = true;
        }
        let diagnostic = PathDiagnostic {
            visited_snapshot_count,
            matched_snapshot_count: u64::try_from(matched_snapshot_indices.len())
                .unwrap_or(u64::MAX),
            cancelled,
        };
        PathFilterResult {
            matched_snapshot_indices,
            visited_snapshot_count,
            cancelled,
            diagnostic,
        }
    }

    pub fn folder_suffix_indices(&self, request: &FolderSuffixRequest) -> Vec<u32> {
        let Some(candidate) = normalize_suffix(&request.fragment, request.case_insensitive) else {
            return Vec::new();
        };
        let boundary = format!("/{candidate}");
        request
            .relative_paths
            .iter()
            .enumerate()
            .take_while(|_| !request.cancellation.is_cancelled())
            .filter_map(|(index, path)| {
                let normalized = normalize_suffix(path, request.case_insensitive)?;
                (normalized == candidate || normalized.ends_with(&boundary))
                    .then(|| u32::try_from(index).ok())
                    .flatten()
            })
            .collect()
    }
}

fn clause_matches(clause: &PathClause, snapshot: &PathSnapshot, case_insensitive: bool) -> bool {
    match clause {
        PathClause::ExactFile {
            abs_path,
            rel_path,
            restricted_root_path,
        } => {
            snapshot.standardized_full_path == *abs_path
                || (snapshot.standardized_relative_path == *rel_path
                    && root_matches(restricted_root_path.as_deref(), snapshot))
        }
        PathClause::ExactFolder {
            abs_lower,
            rel_lower,
            restricted_root_path,
        } => {
            root_matches(restricted_root_path.as_deref(), snapshot)
                && (exact_or_descendant(abs_lower, &snapshot.standardized_full_path.to_lowercase())
                    || exact_or_descendant(
                        rel_lower,
                        &snapshot.standardized_relative_path.to_lowercase(),
                    ))
        }
        PathClause::Glob {
            pattern,
            restricted_root_path,
        } => {
            root_matches(restricted_root_path.as_deref(), snapshot)
                && (wildmatch::matches(pattern, &snapshot.client_display_path, case_insensitive)
                    || wildmatch::matches(
                        pattern,
                        &snapshot.standardized_relative_path,
                        case_insensitive,
                    )
                    || wildmatch::matches(
                        pattern,
                        &snapshot.standardized_full_path,
                        case_insensitive,
                    ))
        }
        PathClause::LegacyPrefix { candidate_lower } => {
            !candidate_lower.is_empty()
                && [
                    snapshot.standardized_relative_path.to_lowercase(),
                    snapshot.client_display_path.to_lowercase(),
                    snapshot.standardized_full_path.to_lowercase(),
                ]
                .iter()
                .any(|path| exact_or_descendant(candidate_lower, path))
        }
    }
}

fn root_matches(restricted: Option<&str>, snapshot: &PathSnapshot) -> bool {
    restricted.is_none_or(|root| root == snapshot.standardized_root_path)
}

fn exact_or_descendant(prefix: &str, path: &str) -> bool {
    path == prefix
        || path
            .strip_prefix(prefix)
            .is_some_and(|remainder| prefix.ends_with('/') || remainder.starts_with('/'))
}

fn normalize_suffix(value: &str, case_insensitive: bool) -> Option<String> {
    let mut components: Vec<&str> = Vec::new();
    for component in value.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                components.pop();
            }
            other => components.push(other),
        }
    }
    let normalized = components.join("/");
    if normalized.is_empty() {
        None
    } else if case_insensitive {
        Some(normalized.to_lowercase())
    } else {
        Some(normalized)
    }
}

#[allow(dead_code)]
fn _diagnostic_privacy_shape(_: &RegexDiagnostic) {}
