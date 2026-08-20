use std::sync::Arc;

use pcre2::ErrorKind;
use pcre2::bytes::RegexBuilder;

use super::cache::{CacheKey, CachedRegex, PatternCache};
use super::fast_plans;
use super::lines::LineTable;
use super::pattern;
use super::{
    ByteRange, EngineKind, JitStatus, LimitFailure, LimitPolicy, MatchPolicy, RegexDiagnostic,
    RegexLineHit, RegexSearchMode, RegexSearchRequest, RegexSearchResult, RepairKind, SearchError,
};

#[derive(Default)]
pub struct SearchLeaf {
    cache: PatternCache,
}

impl SearchLeaf {
    pub fn new() -> Result<Self, SearchError> {
        let mut builder = configured_builder(false, false, true);
        builder.jit(true);
        builder
            .build(r"\bAgentryJitProbe\b")
            .map_err(|error| SearchError::JitUnavailable(error.to_string()))?;
        Ok(Self::default())
    }

    pub fn search_regex(
        &self,
        request: &RegexSearchRequest,
    ) -> Result<RegexSearchResult, SearchError> {
        if request.cancellation.is_cancelled() {
            return Err(SearchError::Cancelled);
        }
        pattern::validate_complexity(&request.pattern)?;
        let policy = limit_policy(request.match_policy);
        let lines = LineTable::new(request.subject.as_bytes());
        let fast_plan = fast_plans::select(request.mode, &request.pattern, request.whole_word);
        let engine = fast_plan
            .as_ref()
            .map_or(EngineKind::Pcre2, |plan| plan.engine);
        let mut raw_matches = Vec::new();
        let mut cancelled = false;
        let mut direct = false;
        if request.mode == RegexSearchMode::Content {
            if let Some(plan) = &fast_plan {
                direct = true;
                for (_, range) in lines.iter() {
                    let start = usize::try_from(range.start).map_err(|_| {
                        SearchError::InternalInvariant("line start overflow".into())
                    })?;
                    let end = usize::try_from(range.end)
                        .map_err(|_| SearchError::InternalInvariant("line end overflow".into()))?;
                    match fast_plans::direct_line_match(
                        plan,
                        &request.pattern,
                        &request.subject.as_bytes()[start..end],
                        request.case_insensitive,
                    ) {
                        Some(Some((match_start, match_end))) => {
                            raw_matches.push((start + match_start, start + match_end))
                        }
                        Some(None) => {}
                        None => {
                            direct = false;
                            raw_matches.clear();
                            break;
                        }
                    }
                }
            }
        } else if let Some(plan) = &fast_plan {
            if let Some(found) = fast_plans::direct_path_match(
                plan,
                &request.pattern,
                request.subject.as_bytes(),
                request.case_insensitive,
            ) {
                direct = true;
                if let Some(found) = found {
                    raw_matches.push(found);
                }
            }
        }

        let (jit_status, cache_hit, repair_kind) = if direct {
            (JitStatus::NotApplicable, false, RepairKind::None)
        } else {
            let (compiled, repair_kind) = self.compile_with_repairs(request, policy)?;
            let line_scanning =
                request.match_policy == MatchPolicy::ContentLine || fast_plan.is_some();
            if line_scanning && request.mode == RegexSearchMode::Content {
                for (_, range) in lines.iter() {
                    if request.cancellation.is_cancelled() {
                        cancelled = true;
                        break;
                    }
                    let start = usize::try_from(range.start).map_err(|_| {
                        SearchError::InternalInvariant("line start overflow".into())
                    })?;
                    let end = usize::try_from(range.end)
                        .map_err(|_| SearchError::InternalInvariant("line end overflow".into()))?;
                    let bytes = &request.subject.as_bytes()[start..end];
                    if let Some(plan) = &fast_plan {
                        if !fast_plans::prefilter(plan, bytes, request.case_insensitive) {
                            continue;
                        }
                    }
                    if let Some(found) = compiled.regex.find(bytes).map_err(map_match_error)? {
                        raw_matches.push((start + found.start(), start + found.end()));
                    }
                }
            } else {
                for found in compiled.regex.find_iter(request.subject.as_bytes()) {
                    if request.cancellation.is_cancelled() {
                        cancelled = true;
                        break;
                    }
                    let found = found.map_err(map_match_error)?;
                    raw_matches.push((found.start(), found.end()));
                }
            }
            (compiled.jit_status, compiled.cache_hit, repair_kind)
        };
        if request.cancellation.is_cancelled() {
            cancelled = true;
        }

        let mut line_matches: Vec<(usize, usize, usize)> = Vec::new();
        for (start, end) in raw_matches {
            let Some(line) = lines.line_for_offset(start) else {
                continue;
            };
            if line_matches.last().is_some_and(|last| last.0 == line) {
                continue;
            }
            line_matches.push((line, start, end));
        }
        line_matches.sort_unstable();
        line_matches.dedup_by_key(|match_| match_.0);
        let matching_line_count = u64::try_from(line_matches.len()).unwrap_or(u64::MAX);
        let collection_cap = if request.collect_matches {
            request
                .max_collected_matches
                .map_or(usize::MAX, |value| value as usize)
        } else {
            0
        };
        let mut hits = Vec::with_capacity(line_matches.len().min(collection_cap));
        for (line, start, end) in line_matches.into_iter().take(collection_cap) {
            let line_range = lines
                .range(line)
                .ok_or_else(|| SearchError::InternalInvariant("missing hit line".into()))?;
            let (before, after) = lines.context(line, usize::from(request.context_lines));
            hits.push(RegexLineHit {
                line_number: u32::try_from(line)
                    .map_err(|_| SearchError::InternalInvariant("line number overflow".into()))?,
                line_byte_range: line_range,
                match_byte_range: ByteRange::new(start, end),
                context_before_byte_ranges: before,
                context_after_byte_ranges: after,
            });
        }
        let diagnostic = RegexDiagnostic {
            engine,
            jit_status,
            cache_hit,
            repair_kind,
            limit_policy: policy,
            subject_byte_count: u64::try_from(request.subject.len()).unwrap_or(u64::MAX),
            line_count: u64::try_from(lines.len()).unwrap_or(u64::MAX),
            hit_count: u64::try_from(hits.len()).unwrap_or(u64::MAX),
            matching_line_count,
            cancelled,
            limit_failure: None,
        };
        Ok(RegexSearchResult {
            hits,
            matching_line_count,
            cancelled,
            diagnostic,
        })
    }

    fn compile_with_repairs(
        &self,
        request: &RegexSearchRequest,
        policy: LimitPolicy,
    ) -> Result<(CachedRegex, RepairKind), SearchError> {
        let mut last_error = None;
        for (candidate, repair_kind) in pattern::repair_candidates(&request.pattern) {
            let effective = if request.whole_word {
                format!(r"\b(?:{candidate})\b")
            } else {
                candidate
            };
            match self.compile(
                &effective,
                request.case_insensitive,
                request.multiline_anchors || effective.contains(['^', '$']),
                policy,
            ) {
                Ok(regex) => return Ok((regex, repair_kind)),
                Err(error) => last_error = Some(error),
            }
        }
        Err(last_error.unwrap_or_else(|| SearchError::InvalidPattern {
            offset: None,
            message: "no compile candidate".into(),
        }))
    }

    fn compile(
        &self,
        pattern: &str,
        case_insensitive: bool,
        multiline: bool,
        policy: LimitPolicy,
    ) -> Result<CachedRegex, SearchError> {
        let limited_pattern = limited_pattern(pattern, policy);
        let key = CacheKey {
            pattern: limited_pattern.clone(),
            case_insensitive,
            multiline,
            policy,
        };
        if let Some(cached) = self.cache.get(&key) {
            return Ok(cached);
        }
        let mut strict = configured_builder(case_insensitive, multiline, true);
        strict.jit(true);
        let (regex, jit_status) = match strict.build(&limited_pattern) {
            Ok(regex) => (regex, JitStatus::Active),
            Err(error) if matches!(error.kind(), ErrorKind::JIT) => {
                let regex = configured_builder(case_insensitive, multiline, false)
                    .build(&limited_pattern)
                    .map_err(map_compile_error)?;
                (regex, JitStatus::Pcre2InterpreterFallback)
            }
            Err(error) => return Err(map_compile_error(error)),
        };
        Ok(self.cache.insert(key, Arc::new(regex), jit_status))
    }
}

fn configured_builder(case_insensitive: bool, multiline: bool, crlf: bool) -> RegexBuilder {
    let mut builder = RegexBuilder::new();
    builder
        .utf(true)
        .ucp(true)
        .caseless(case_insensitive)
        .multi_line(multiline)
        .crlf(crlf)
        .max_jit_stack_size(Some(512 * 1024));
    builder
}

fn limited_pattern(pattern: &str, policy: LimitPolicy) -> String {
    let (match_limit, depth_limit, heap_limit) = policy.limits();
    format!(
        "(*LIMIT_MATCH={match_limit})(*LIMIT_DEPTH={depth_limit})(*LIMIT_HEAP={heap_limit}){pattern}"
    )
}

const fn limit_policy(policy: MatchPolicy) -> LimitPolicy {
    match policy {
        MatchPolicy::ContentFullBuffer => LimitPolicy::FileSearchFullBuffer,
        MatchPolicy::ContentLine => LimitPolicy::FileSearchLine,
        MatchPolicy::ShortPath => LimitPolicy::PathSearchShortSubject,
    }
}

fn map_compile_error(error: pcre2::Error) -> SearchError {
    let message = error.to_string();
    let normalized = message.to_ascii_lowercase();
    if normalized.contains("lookbehind")
        && (normalized.contains("not fixed")
            || normalized.contains("variable")
            || normalized.contains("bounded")
            || normalized.contains("not limited")
            || normalized.contains("maximum length"))
    {
        SearchError::VariableLengthLookbehind
    } else if normalized.contains("missing terminating ]")
        || normalized.contains("character class") && normalized.contains("missing")
    {
        SearchError::UnmatchedBrackets
    } else if normalized.contains("parenthes") {
        SearchError::UnmatchedParentheses
    } else if normalized.contains("quantifier") || normalized.contains("nothing to repeat") {
        SearchError::InvalidQuantifier
    } else if normalized.contains("escape")
        || normalized.contains("unrecognized character follows \\")
    {
        SearchError::InvalidEscape
    } else {
        SearchError::InvalidPattern {
            offset: error.offset(),
            message,
        }
    }
}

fn map_match_error(error: pcre2::Error) -> SearchError {
    let message = error.to_string().to_ascii_lowercase();
    if message.contains("match limit") {
        SearchError::MatchLimitExceeded
    } else if message.contains("depth limit") || message.contains("recursion limit") {
        SearchError::DepthLimitExceeded
    } else if message.contains("heap limit") {
        SearchError::HeapLimitExceeded
    } else {
        SearchError::InternalInvariant(error.to_string())
    }
}

#[allow(dead_code)]
const fn diagnostic_limit_failure(error: &SearchError) -> Option<LimitFailure> {
    match error {
        SearchError::MatchLimitExceeded => Some(LimitFailure::Match),
        SearchError::DepthLimitExceeded => Some(LimitFailure::Depth),
        SearchError::HeapLimitExceeded => Some(LimitFailure::Heap),
        _ => None,
    }
}
