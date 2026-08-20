use std::collections::HashSet;

use super::cache::CachedRegex;
use super::fast_plans::FastPlan;
use super::{EngineKind, JitStatus, LimitPolicy, RepairKind, SearchError};

pub(crate) struct PreparedSearch {
    pub(crate) policy: LimitPolicy,
    pub(crate) fast_plan: Option<FastPlan>,
    pub(crate) engine: EngineKind,
    pub(crate) compiled: Option<CachedRegex>,
    pub(crate) jit_status: JitStatus,
    pub(crate) cache_hit: bool,
    pub(crate) repair_kind: RepairKind,
}

const MAX_PATTERN_CHARS: usize = 2_000;
const MAX_CAPTURE_GROUPS: usize = 250;

pub(crate) fn validate_complexity(pattern: &str) -> Result<(), SearchError> {
    if pattern.chars().count() > MAX_PATTERN_CHARS || is_high_risk(pattern) {
        return Err(SearchError::PatternTooComplex);
    }
    let mut groups = 0usize;
    let mut escaped = false;
    for character in pattern.chars() {
        if escaped {
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else if character == '(' {
            groups += 1;
            if groups > MAX_CAPTURE_GROUPS {
                return Err(SearchError::PatternTooComplex);
            }
        }
    }
    Ok(())
}

fn is_high_risk(pattern: &str) -> bool {
    pattern.starts_with('^')
        && pattern.ends_with('$')
        && !pattern.contains('\n')
        && [")+", ")*", ")?", "){"]
            .iter()
            .any(|token| pattern.contains(token))
}

pub(crate) fn repair_candidates(pattern: &str) -> Vec<(String, RepairKind)> {
    let compressed = compress_double_escapes(pattern);
    let normalized = normalize(pattern);
    let normalized_compressed = compress_double_escapes(&normalized);
    let candidates = [
        (pattern.to_owned(), RepairKind::None),
        (compressed, RepairKind::DoubleEscapeCompression),
        (normalized, RepairKind::Normalise),
        (normalized_compressed, RepairKind::NormaliseThenCompression),
    ];
    let mut seen = HashSet::new();
    candidates
        .into_iter()
        .filter(|(candidate, _)| seen.insert(candidate.clone()))
        .collect()
}

fn compress_double_escapes(pattern: &str) -> String {
    let chars: Vec<char> = pattern.chars().collect();
    let mut out = String::with_capacity(pattern.len());
    let mut index = 0usize;
    while index < chars.len() {
        if index + 2 < chars.len()
            && chars[index] == '\\'
            && chars[index + 1] == '\\'
            && "()[]{}.*+?|^$".contains(chars[index + 2])
        {
            out.push('\\');
            out.push(chars[index + 2]);
            index += 3;
        } else {
            out.push(chars[index]);
            index += 1;
        }
    }
    out
}

fn normalize(pattern: &str) -> String {
    let mut normalized = pattern.trim_matches('|').to_owned();
    while normalized.contains("||") {
        normalized = normalized.replace("||", "|");
    }
    let chars: Vec<char> = normalized.chars().collect();
    let mut out = Vec::with_capacity(chars.len());
    let mut opens = Vec::new();
    let mut escaped = false;
    let mut in_class = false;
    for character in chars {
        if escaped {
            out.push(character);
            escaped = false;
        } else if character == '\\' {
            out.push(character);
            escaped = true;
        } else if character == '[' && !in_class {
            in_class = true;
            out.push(character);
        } else if character == ']' && in_class {
            in_class = false;
            out.push(character);
        } else if !in_class && character == '(' {
            opens.push(out.len());
            out.push(character);
        } else if !in_class && character == ')' {
            if opens.pop().is_some() {
                out.push(character);
            } else {
                out.extend(['\\', ')']);
            }
        } else {
            out.push(character);
        }
    }
    for index in opens.into_iter().rev() {
        out.insert(index, '\\');
    }
    if out.is_empty() {
        "(?!.*)".to_owned()
    } else {
        out.into_iter().collect()
    }
}
