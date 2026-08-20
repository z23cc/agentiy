use std::sync::Arc;

use pcre2::ErrorKind;
use pcre2::bytes::RegexBuilder;

use super::cache::{CacheKey, CachedRegex, PatternCache};
use super::fast_plans;
use super::lines::LineTable;
use super::pattern::{self, PreparedSearch};
use super::{
    ByteRange, CompactRegexBatchResult, CompactRegexSubjectSummary, EngineKind, JitStatus,
    LimitFailure, LimitPolicy, MatchPolicy, RegexDiagnostic, RegexLineHit, RegexSearchMode,
    RegexSearchRequest, RegexSearchResult, RepairKind, SearchError, COMPACT_HIT_STRIDE,
    COMPACT_LINE_RANGE_STRIDE,
};

const DIRECT_LINE_CANCELLATION_STRIDE: usize = 64;

#[derive(Default)]
struct SearchScratch {
    raw_matches: Vec<(usize, usize)>,
    line_matches: Vec<(usize, usize, usize)>,
}

impl SearchScratch {
    fn reset(&mut self) {
        self.raw_matches.clear();
        self.line_matches.clear();
    }
}

struct CanonicalHit {
    line: usize,
    start: usize,
    end: usize,
}

struct CanonicalRegexResult {
    line_ranges: Vec<ByteRange>,
    hits: Vec<CanonicalHit>,
    matching_line_count: u64,
    cancelled: bool,
    diagnostic: RegexDiagnostic,
}

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
        let mut prepared = self.prepare_search(request)?;
        let mut scratch = SearchScratch::default();
        self.execute_prepared(request, &mut prepared, &mut scratch)?
            .into_structured(request.context_lines)
    }

    pub fn search_regex_batch(
        &self,
        requests: &[RegexSearchRequest],
    ) -> Result<Vec<RegexSearchResult>, SearchError> {
        let Some(first) = requests.first() else {
            return Ok(Vec::new());
        };
        let mut prepared = self.prepare_search(first)?;
        let mut scratch = SearchScratch::default();
        let mut results = Vec::with_capacity(requests.len());
        for request in requests {
            if !same_prepared_options(first, request) {
                return Err(SearchError::InternalInvariant(
                    "batch search options differ between subjects".into(),
                ));
            }
            if request.cancellation.is_cancelled() {
                return Err(SearchError::Cancelled);
            }
            results.push(
                self.execute_prepared(request, &mut prepared, &mut scratch)?
                    .into_structured(request.context_lines)?,
            );
        }
        Ok(results)
    }

    pub fn search_regex_batch_compact(
        &self,
        requests: &[RegexSearchRequest],
    ) -> Result<CompactRegexBatchResult, SearchError> {
        let Some(first) = requests.first() else {
            return Ok(CompactRegexBatchResult {
                subject_summaries: Vec::new(),
                line_range_words: Vec::new(),
                hit_words: Vec::new(),
            });
        };
        let mut prepared = self.prepare_search(first)?;
        let mut scratch = SearchScratch::default();
        let mut result = CompactRegexBatchResult {
            subject_summaries: Vec::with_capacity(requests.len()),
            line_range_words: Vec::new(),
            hit_words: Vec::new(),
        };
        for request in requests {
            if !same_prepared_options(first, request) {
                return Err(SearchError::InternalInvariant(
                    "batch search options differ between subjects".into(),
                ));
            }
            if request.cancellation.is_cancelled() {
                return Err(SearchError::Cancelled);
            }
            self.execute_prepared(request, &mut prepared, &mut scratch)?
                .append_compact(request.context_lines, &mut result)?;
        }
        debug_assert_eq!(result.line_range_words.len() % COMPACT_LINE_RANGE_STRIDE, 0);
        debug_assert_eq!(result.hit_words.len() % COMPACT_HIT_STRIDE, 0);
        Ok(result)
    }

    fn prepare_search(&self, request: &RegexSearchRequest) -> Result<PreparedSearch, SearchError> {
        if request.cancellation.is_cancelled() {
            return Err(SearchError::Cancelled);
        }
        pattern::validate_complexity(&request.pattern)?;
        let policy = limit_policy(request.match_policy);
        let fast_plan = fast_plans::select(request.mode, &request.pattern, request.whole_word);
        let engine = fast_plan
            .as_ref()
            .map_or(EngineKind::Pcre2, |plan| plan.engine);
        let direct_capable = fast_plan.as_ref().is_some_and(|plan| {
            matches!(
                plan.engine,
                EngineKind::AsciiWholeWord
                    | EngineKind::AnchoredDeclaration
                    | EngineKind::AsciiMarker
                    | EngineKind::PathSuffix
            )
        });
        let compiled = if direct_capable {
            None
        } else {
            Some(self.compile_with_repairs(request, policy)?)
        };
        let (compiled, repair_kind) = compiled.unzip();
        let (jit_status, cache_hit) = compiled
            .as_ref()
            .map_or((JitStatus::NotApplicable, false), |value| {
                (value.jit_status, value.cache_hit)
            });
        Ok(PreparedSearch {
            policy,
            fast_plan,
            engine,
            compiled,
            jit_status,
            cache_hit,
            repair_kind: repair_kind.unwrap_or(RepairKind::None),
        })
    }

    fn execute_prepared(
        &self,
        request: &RegexSearchRequest,
        prepared: &mut PreparedSearch,
        scratch: &mut SearchScratch,
    ) -> Result<CanonicalRegexResult, SearchError> {
        scratch.reset();
        let lines = LineTable::new(request.subject.as_bytes());
        let mut cancelled = false;
        let mut direct = false;
        if request.mode == RegexSearchMode::Content {
            if let Some(plan) = &prepared.fast_plan {
                direct = true;
                for (line_index, (_, range)) in lines.iter().enumerate() {
                    if line_index % DIRECT_LINE_CANCELLATION_STRIDE == 0
                        && request.cancellation.is_cancelled()
                    {
                        cancelled = true;
                        break;
                    }
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
                        Some(Some((match_start, match_end))) => scratch
                            .raw_matches
                            .push((start + match_start, start + match_end)),
                        Some(None) => {}
                        None => {
                            direct = false;
                            scratch.raw_matches.clear();
                            break;
                        }
                    }
                }
            }
        } else if let Some(plan) = &prepared.fast_plan {
            if let Some(found) = fast_plans::direct_path_match(
                plan,
                &request.pattern,
                request.subject.as_bytes(),
                request.case_insensitive,
            ) {
                direct = true;
                if let Some(found) = found {
                    scratch.raw_matches.push(found);
                }
            }
        }

        let (jit_status, cache_hit, repair_kind) = if direct {
            (JitStatus::NotApplicable, false, RepairKind::None)
        } else {
            if prepared.compiled.is_none() {
                let (compiled, repair_kind) =
                    self.compile_with_repairs(request, prepared.policy)?;
                prepared.jit_status = compiled.jit_status;
                prepared.cache_hit = compiled.cache_hit;
                prepared.repair_kind = repair_kind;
                prepared.compiled = Some(compiled);
            }
            let compiled = prepared.compiled.as_ref().ok_or_else(|| {
                SearchError::InternalInvariant("prepared regex is missing".into())
            })?;
            let line_scanning =
                request.match_policy == MatchPolicy::ContentLine || prepared.fast_plan.is_some();
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
                    if let Some(plan) = &prepared.fast_plan {
                        if !fast_plans::prefilter(plan, bytes, request.case_insensitive) {
                            continue;
                        }
                    }
                    if let Some(found) = compiled.regex.find(bytes).map_err(map_match_error)? {
                        scratch
                            .raw_matches
                            .push((start + found.start(), start + found.end()));
                    }
                }
            } else {
                for found in compiled.regex.find_iter(request.subject.as_bytes()) {
                    if request.cancellation.is_cancelled() {
                        cancelled = true;
                        break;
                    }
                    let found = found.map_err(map_match_error)?;
                    scratch.raw_matches.push((found.start(), found.end()));
                }
            }
            (
                prepared.jit_status,
                prepared.cache_hit,
                prepared.repair_kind,
            )
        };
        if request.cancellation.is_cancelled() {
            cancelled = true;
        }

        for &(start, end) in &scratch.raw_matches {
            let Some(line) = lines.line_for_offset(start) else {
                continue;
            };
            if scratch
                .line_matches
                .last()
                .is_some_and(|last| last.0 == line)
            {
                continue;
            }
            scratch.line_matches.push((line, start, end));
        }
        scratch.line_matches.sort_unstable();
        scratch.line_matches.dedup_by_key(|match_| match_.0);
        let matching_line_count = u64::try_from(scratch.line_matches.len()).unwrap_or(u64::MAX);
        let collection_cap = if request.collect_matches {
            request
                .max_collected_matches
                .map_or(usize::MAX, |value| value as usize)
        } else {
            0
        };
        let hits = scratch
            .line_matches
            .iter()
            .take(collection_cap)
            .map(|&(line, start, end)| CanonicalHit { line, start, end })
            .collect::<Vec<_>>();
        let diagnostic = RegexDiagnostic {
            engine: prepared.engine,
            jit_status,
            cache_hit,
            repair_kind,
            limit_policy: prepared.policy,
            subject_byte_count: u64::try_from(request.subject.len()).unwrap_or(u64::MAX),
            line_count: u64::try_from(lines.len()).unwrap_or(u64::MAX),
            hit_count: u64::try_from(hits.len()).unwrap_or(u64::MAX),
            matching_line_count,
            cancelled,
            limit_failure: None,
        };
        Ok(CanonicalRegexResult {
            line_ranges: lines.into_ranges(),
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

impl CanonicalRegexResult {
    fn into_structured(self, context_lines: u16) -> Result<RegexSearchResult, SearchError> {
        let context = usize::from(context_lines);
        let mut hits = Vec::with_capacity(self.hits.len());
        for hit in self.hits {
            let line_byte_range = self
                .line_ranges
                .get(hit.line)
                .copied()
                .ok_or_else(|| SearchError::InternalInvariant("missing hit line".into()))?;
            let before_start = hit.line.saturating_sub(context);
            let after_end = self
                .line_ranges
                .len()
                .min(hit.line.saturating_add(context).saturating_add(1));
            hits.push(RegexLineHit {
                line_number: u32::try_from(hit.line)
                    .map_err(|_| SearchError::InternalInvariant("line number overflow".into()))?,
                line_byte_range,
                match_byte_range: ByteRange::new(hit.start, hit.end),
                context_before_byte_ranges: self.line_ranges[before_start..hit.line].to_vec(),
                context_after_byte_ranges: self.line_ranges[hit.line.saturating_add(1)..after_end]
                    .to_vec(),
            });
        }
        Ok(RegexSearchResult {
            hits,
            matching_line_count: self.matching_line_count,
            cancelled: self.cancelled,
            diagnostic: self.diagnostic,
        })
    }

    fn append_compact(
        self,
        context_lines: u16,
        batch: &mut CompactRegexBatchResult,
    ) -> Result<(), SearchError> {
        let line_range_start = batch.line_range_words.len() / COMPACT_LINE_RANGE_STRIDE;
        let hit_start = batch.hit_words.len() / COMPACT_HIT_STRIDE;
        let context = usize::from(context_lines);
        let mut intervals: Vec<(usize, usize)> = Vec::new();
        for hit in &self.hits {
            if hit.line >= self.line_ranges.len() {
                return Err(SearchError::InternalInvariant("missing hit line".into()));
            }
            let start = hit.line.saturating_sub(context);
            let end = self
                .line_ranges
                .len()
                .min(hit.line.saturating_add(context).saturating_add(1));
            if let Some(last) = intervals.last_mut()
                && start <= last.1
            {
                last.1 = last.1.max(end);
            } else {
                intervals.push((start, end));
            }
        }

        let selected_count = intervals
            .iter()
            .try_fold(0usize, |count, (start, end)| count.checked_add(end - start))
            .ok_or_else(|| SearchError::InternalInvariant("selected line count overflow".into()))?;
        batch
            .line_range_words
            .reserve(selected_count.saturating_mul(COMPACT_LINE_RANGE_STRIDE));
        for &(start, end) in &intervals {
            for range in &self.line_ranges[start..end] {
                batch.line_range_words.extend([range.start, range.end]);
            }
        }

        batch
            .hit_words
            .reserve(self.hits.len().saturating_mul(COMPACT_HIT_STRIDE));
        let mut interval_index = 0usize;
        let mut interval_base = 0usize;
        for hit in &self.hits {
            while intervals
                .get(interval_index)
                .is_some_and(|(_, end)| hit.line >= *end)
            {
                let (start, end) = intervals[interval_index];
                interval_base = interval_base
                    .checked_add(end - start)
                    .ok_or_else(|| SearchError::InternalInvariant("selected line index overflow".into()))?;
                interval_index += 1;
            }
            let (interval_start, interval_end) = intervals
                .get(interval_index)
                .copied()
                .ok_or_else(|| SearchError::InternalInvariant("missing selected hit line".into()))?;
            if hit.line < interval_start || hit.line >= interval_end {
                return Err(SearchError::InternalInvariant(
                    "hit line outside selected interval".into(),
                ));
            }
            let selected_line_index = interval_base
                .checked_add(hit.line - interval_start)
                .ok_or_else(|| SearchError::InternalInvariant("selected line index overflow".into()))?;
            let before_count = hit.line.min(context);
            let after_count = context.min(self.line_ranges.len() - hit.line - 1);
            batch.hit_words.extend([
                u64::try_from(hit.line)
                    .map_err(|_| SearchError::InternalInvariant("line number overflow".into()))?,
                u64::try_from(selected_line_index).map_err(|_| {
                    SearchError::InternalInvariant("selected line index overflow".into())
                })?,
                u64::try_from(hit.start)
                    .map_err(|_| SearchError::InternalInvariant("match start overflow".into()))?,
                u64::try_from(hit.end)
                    .map_err(|_| SearchError::InternalInvariant("match end overflow".into()))?,
                u64::try_from(before_count)
                    .map_err(|_| SearchError::InternalInvariant("context count overflow".into()))?,
                u64::try_from(after_count)
                    .map_err(|_| SearchError::InternalInvariant("context count overflow".into()))?,
            ]);
        }

        batch.subject_summaries.push(CompactRegexSubjectSummary {
            line_range_start: u64::try_from(line_range_start)
                .map_err(|_| SearchError::InternalInvariant("line slice overflow".into()))?,
            line_range_count: u64::try_from(selected_count)
                .map_err(|_| SearchError::InternalInvariant("line slice overflow".into()))?,
            hit_start: u64::try_from(hit_start)
                .map_err(|_| SearchError::InternalInvariant("hit slice overflow".into()))?,
            hit_count: u64::try_from(self.hits.len())
                .map_err(|_| SearchError::InternalInvariant("hit slice overflow".into()))?,
            matching_line_count: self.matching_line_count,
            cancelled: self.cancelled,
            diagnostic: self.diagnostic,
        });
        Ok(())
    }
}

fn same_prepared_options(first: &RegexSearchRequest, other: &RegexSearchRequest) -> bool {
    first.mode == other.mode
        && first.pattern == other.pattern
        && first.case_insensitive == other.case_insensitive
        && first.whole_word == other.whole_word
        && first.multiline_anchors == other.multiline_anchors
        && first.collect_matches == other.collect_matches
        && first.max_collected_matches == other.max_collected_matches
        && first.context_lines == other.context_lines
        && first.match_policy == other.match_policy
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
