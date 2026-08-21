use crate::{
    build_line_index, generate_diff, match_selector, process_line, render_unified, ByteEdit,
    DiffChunk, MatchError,
};
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApplyMode {
    Rewrite { replacement: String },
    Single { operation: ApplyOperation },
    Batch { operations: Vec<ApplyOperation> },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApplyOperation {
    pub search: String,
    pub replace: String,
    pub replace_all: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApplySubjectRequest {
    pub path_label: String,
    pub original: Vec<u8>,
    pub mode: ApplyMode,
    pub verbose: bool,
    pub include_tool_card_unified_diff: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u64)]
pub enum ApplyStatus {
    Success = 0,
    Partial = 1,
    Failed = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u64)]
pub enum OutcomeStatus {
    Success = 0,
    Failed = 1,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OperationOutcome {
    pub operation_index: usize,
    pub status: OutcomeStatus,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApplyResult {
    pub updated_text: String,
    pub byte_edits: Vec<ByteEdit>,
    /// Unfiltered semantic chunks. Presentation filtering must not break reconstruction.
    pub chunks: Vec<DiffChunk>,
    pub unified_diff: Option<String>,
    pub tool_card_unified_diff: Option<String>,
    pub lines_changed: Option<usize>,
    pub note: Option<String>,
    pub edits_requested: usize,
    pub edits_applied: usize,
    pub status: ApplyStatus,
    pub outcomes: Option<Vec<OperationOutcome>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApplyError {
    InvalidParams(String),
    Internal(String),
}

fn decode_c_style(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            output.push(ch);
            continue;
        }
        match chars.next() {
            Some('n') => output.push('\n'),
            Some('r') => output.push('\r'),
            Some('t') => output.push('\t'),
            Some('\\') => output.push('\\'),
            Some('"') => output.push('"'),
            Some(other) => {
                output.push('\\');
                output.push(other);
            }
            None => output.push('\\'),
        }
    }
    output
}

fn non_overlapping_ranges(text: &str, needle: &str) -> Vec<(usize, usize)> {
    if needle.is_empty() {
        return Vec::new();
    }
    let mut ranges = Vec::new();
    let mut cursor = 0;
    while let Some(local) = text[cursor..].find(needle) {
        let start = cursor + local;
        let end = start + needle.len();
        ranges.push((start, end));
        cursor = end;
    }
    ranges
}

fn resolve_escape(operation: &ApplyOperation, original: &str) -> ApplyOperation {
    if operation.search.is_empty()
        || original.contains(&operation.search)
        || !operation.search.contains('\\')
    {
        return operation.clone();
    }
    let decoded_search = decode_c_style(&operation.search);
    if decoded_search == operation.search || !original.contains(&decoded_search) {
        return operation.clone();
    }
    ApplyOperation {
        search: decoded_search,
        replace: decode_c_style(&operation.replace),
        replace_all: operation.replace_all,
    }
}

fn line_number_at(text: &str, byte: usize) -> usize {
    text[..byte].bytes().filter(|&b| b == b'\n').count() + 1
}

fn apply_literal(text: &str, operation: &ApplyOperation) -> Result<Option<String>, ApplyError> {
    let matches = non_overlapping_ranges(text, &operation.search);
    if matches.is_empty() {
        if operation.replace_all {
            return Err(ApplyError::InvalidParams(
                "search text not found in file (no literal matches for replace_all)".into(),
            ));
        }
        return Ok(None);
    }
    if !operation.replace_all && matches.len() > 1 {
        let lines = matches
            .iter()
            .map(|(start, _)| line_number_at(text, *start).to_string())
            .collect::<Vec<_>>()
            .join(", ");
        return Err(ApplyError::InvalidParams(format!(
            "Search text matches multiple locations (lines {lines}). Please make the search more specific or use replace_all=true."
        )));
    }
    if operation.replace_all {
        Ok(Some(text.replace(&operation.search, &operation.replace)))
    } else {
        let (start, end) = matches[0];
        let mut result = text.to_owned();
        result.replace_range(start..end, &operation.replace);
        Ok(Some(result))
    }
}

fn plain_lines(text: &str) -> Vec<String> {
    crate::split_lines_preserving_endings(text)
        .into_iter()
        .map(|line| line.trim_end_matches(['\r', '\n']).to_owned())
        .collect()
}

fn dominant_ending(text: &str) -> &'static str {
    let mut lf = 0;
    let mut crlf = 0;
    let mut cr = 0;
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\r' {
            if i + 1 < bytes.len() && bytes[i + 1] == b'\n' {
                crlf += 1;
                i += 2;
            } else {
                cr += 1;
                i += 1;
            }
        } else if bytes[i] == b'\n' {
            lf += 1;
            i += 1;
        } else {
            i += 1;
        }
    }
    if crlf >= lf && crlf >= cr && crlf > 0 {
        "\r\n"
    } else if cr >= lf && cr > 0 {
        "\r"
    } else {
        "\n"
    }
}

fn leading_width(line: &str) -> usize {
    line.chars()
        .take_while(|c| *c == ' ' || *c == '\t')
        .map(|c| if c == '\t' { 4 } else { 1 })
        .sum()
}

fn is_tab_file(lines: &[String]) -> bool {
    lines.iter().any(|line| {
        !line.trim().is_empty()
            && line
                .chars()
                .take_while(|c| c.is_whitespace())
                .any(|c| c == '\t')
    })
}

fn tab_promotion_enabled(path: &str, search: &str, replace: &str) -> bool {
    let extension = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    if ["tex", "ltx", "sty", "cls", "bib", "dtx", "ins"].contains(&extension.as_str()) {
        return false;
    }
    !["\\documentclass", "\\usepackage", "\\begin{", "\\end{"]
        .iter()
        .any(|marker| search.contains(marker) || replace.contains(marker))
}

fn promote_escaped_indent(mut line: String, unit: usize, enabled: bool) -> (usize, String) {
    let mut promoted = 0;
    if enabled {
        loop {
            if line.starts_with("\\t") {
                line.drain(..2);
                promoted += unit;
            } else if line.starts_with("\\u0009") {
                line.drain(..6);
                promoted += unit;
            } else {
                break;
            }
        }
    }
    (promoted, line)
}

fn corrected_replacement(
    old: &[String],
    search: &[String],
    replacement: &[String],
    path: &str,
) -> Vec<String> {
    if replacement.is_empty() {
        return Vec::new();
    }
    let tabs = is_tab_file(old);
    let unit = if tabs { 1 } else { 4 };
    let delta = old.first().map(|s| leading_width(s)).unwrap_or(0) as isize
        - search.first().map(|s| leading_width(s)).unwrap_or(0) as isize;
    let enabled = tab_promotion_enabled(path, &search.join("\n"), &replacement.join("\n"));
    replacement
        .iter()
        .map(|line| {
            let existing = leading_width(line);
            let content = line.trim_start_matches([' ', '\t']).to_owned();
            let (promoted, content) = promote_escaped_indent(content, unit, enabled);
            let width = (existing as isize + delta).max(0) as usize + promoted;
            if tabs {
                format!("{}{}", "\t".repeat((width + 3) / 4), content)
            } else {
                format!("{}{}", " ".repeat(width), content)
            }
        })
        .collect()
}

#[derive(Clone)]
struct LinePatch {
    start: usize,
    old_count: usize,
    replacement: Vec<String>,
}

fn apply_line_patches(original: &[String], patches: &[LinePatch]) -> Option<Vec<String>> {
    let mut lines = original.to_vec();
    let mut adjusted: Vec<_> = patches.iter().map(|p| p.start).collect();
    for (index, patch) in patches.iter().enumerate() {
        let start = adjusted[index];
        if start + patch.old_count > lines.len() {
            return None;
        }
        lines.splice(start..start + patch.old_count, patch.replacement.clone());
        let delta = patch.replacement.len() as isize - patch.old_count as isize;
        for later in index + 1..patches.len() {
            if adjusted[later] > start {
                adjusted[later] =
                    (adjusted[later] as isize + delta).clamp(0, lines.len() as isize) as usize;
            }
        }
    }
    Some(lines)
}

fn matcher_error(error: MatchError) -> String {
    match error {
        MatchError::InvalidSelector => {
            "search block is empty or invalid; provide non-empty search text".into()
        }
        MatchError::NoMatch => {
            "search block not found in file (matches are exact, including whitespace/indentation)"
                .into()
        }
        MatchError::Ambiguous(mut lines) => {
            lines.sort_unstable();
            let lines = lines
                .into_iter()
                .map(|v| (v + 1).to_string())
                .collect::<Vec<_>>()
                .join(", ");
            format!("Search block matches multiple locations (lines {lines}). Please make the block more specific or use the replace_all parameter to replace all occurrences.")
        }
    }
}

fn finish(
    request: &ApplySubjectRequest,
    original: &str,
    updated: String,
    note: Option<String>,
    requested: usize,
    applied: usize,
    status: ApplyStatus,
    outcomes: Option<Vec<OperationOutcome>>,
) -> Result<ApplyResult, ApplyError> {
    let (byte_edits, chunks) = generate_diff(original, &updated);
    if original != updated && chunks.is_empty() {
        return Err(ApplyError::Internal(
            "diff generation produced no changes.".into(),
        ));
    }
    let rendered = render_unified(&request.path_label, &chunks);
    let lines_changed = (!chunks.is_empty()).then(|| {
        chunks
            .iter()
            .map(|chunk| {
                let adds = chunk
                    .lines
                    .iter()
                    .filter(|l| l.kind == crate::DiffLineType::Addition)
                    .count();
                let removes = chunk
                    .lines
                    .iter()
                    .filter(|l| l.kind == crate::DiffLineType::Removal)
                    .count();
                adds.max(removes)
            })
            .sum()
    });
    Ok(ApplyResult {
        updated_text: updated,
        byte_edits,
        chunks,
        unified_diff: request.verbose.then(|| rendered.clone()).flatten(),
        tool_card_unified_diff: request
            .include_tool_card_unified_diff
            .then_some(rendered)
            .flatten(),
        lines_changed,
        note,
        edits_requested: requested,
        edits_applied: applied,
        status,
        outcomes,
    })
}

fn apply_single(
    request: &ApplySubjectRequest,
    original: &str,
    operation: &ApplyOperation,
) -> Result<ApplyResult, ApplyError> {
    let operation = resolve_escape(operation, original);
    if let Some(updated) = apply_literal(original, &operation)? {
        return finish(
            request,
            original,
            updated,
            None,
            1,
            1,
            ApplyStatus::Success,
            None,
        );
    }
    let file = plain_lines(original);
    let selector = plain_lines(&operation.search);
    if selector.is_empty() {
        return Err(ApplyError::InvalidParams(
            "search block is empty or invalid; provide non-empty search text".into(),
        ));
    }
    let processed: Vec<_> = file.iter().map(|line| process_line(line, true)).collect();
    let processed_selector: Vec<_> = selector
        .iter()
        .map(|line| process_line(line, true))
        .collect();
    let index = build_line_index(&processed);
    let start = match match_selector(
        &processed_selector,
        &processed,
        &index,
        0,
        !operation.replace_all,
    ) {
        Ok(start) => start,
        Err(MatchError::NoMatch) => {
            return Err(ApplyError::InvalidParams(
                "search block not found in file".into(),
            ))
        }
        Err(error) => return Err(ApplyError::InvalidParams(matcher_error(error))),
    };
    let replacement = corrected_replacement(
        &file[start..start + selector.len()],
        &selector,
        &plain_lines(&operation.replace),
        &request.path_label,
    );
    let updated_lines = apply_line_patches(
        &file,
        &[LinePatch {
            start,
            old_count: selector.len(),
            replacement,
        }],
    )
    .ok_or_else(|| ApplyError::Internal("diff application failed".into()))?;
    let ending = dominant_ending(original);
    let trailing = original.ends_with(ending);
    let mut updated = updated_lines.join(ending);
    if trailing {
        updated.push_str(ending);
    }
    finish(
        request,
        original,
        updated,
        None,
        1,
        1,
        ApplyStatus::Success,
        None,
    )
}

fn try_literal_batch(operations: &[ApplyOperation], original: &str) -> Option<String> {
    let mut text = original.to_owned();
    for operation in operations {
        let matches = non_overlapping_ranges(&text, &operation.search);
        if operation.replace_all {
            if matches.is_empty() {
                return None;
            }
            text = text.replace(&operation.search, &operation.replace);
        } else {
            if matches.len() != 1 {
                return None;
            }
            text.replace_range(matches[0].0..matches[0].1, &operation.replace);
        }
    }
    Some(text)
}

fn apply_batch(
    request: &ApplySubjectRequest,
    original: &str,
    operations: &[ApplyOperation],
) -> Result<ApplyResult, ApplyError> {
    if operations.is_empty() {
        return Err(ApplyError::InvalidParams(
            "edits array cannot be empty".into(),
        ));
    }
    let resolved: Vec<_> = operations
        .iter()
        .map(|op| resolve_escape(op, original))
        .collect();
    if let Some(updated) = try_literal_batch(&resolved, original) {
        let outcomes = request.verbose.then(|| {
            resolved
                .iter()
                .enumerate()
                .map(|(index, _)| OperationOutcome {
                    operation_index: index,
                    status: OutcomeStatus::Success,
                    error: None,
                })
                .collect()
        });
        return finish(
            request,
            original,
            updated,
            Some("Applied via exact literal replacement".into()),
            resolved.len(),
            resolved.len(),
            ApplyStatus::Success,
            outcomes,
        );
    }

    let file = plain_lines(original);
    let processed: Vec<_> = file.iter().map(|line| process_line(line, true)).collect();
    let full_index = build_line_index(&processed);
    let mut frequencies = HashMap::new();
    for operation in &resolved {
        let key = plain_lines(&operation.search)
            .iter()
            .map(|s| process_line(s, true).strict)
            .collect::<Vec<_>>()
            .join("\n");
        *frequencies.entry(key).or_insert(0usize) += 1;
    }
    let reject_ambiguity = !frequencies.values().any(|&count| count > 1);
    let mut cursors: HashMap<String, usize> = HashMap::new();
    let mut patches = Vec::new();
    let mut outcomes = Vec::with_capacity(resolved.len());
    for (operation_index, operation) in resolved.iter().enumerate() {
        let selector = plain_lines(&operation.search);
        let processed_selector: Vec<_> = selector
            .iter()
            .map(|line| process_line(line, true))
            .collect();
        let key = processed_selector
            .iter()
            .map(|line| line.strict.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        let minimum = *cursors.get(&key).unwrap_or(&0);
        let mut matches = Vec::new();
        let outcome = if operation.replace_all {
            let mut next = minimum;
            let mut failure = None;
            loop {
                match match_selector(&processed_selector, &processed, &full_index, next, false) {
                    Ok(start) => {
                        if start + selector.len() > file.len() {
                            break;
                        }
                        matches.push(start);
                        next = start + selector.len();
                    }
                    Err(MatchError::NoMatch) => break,
                    Err(error) => {
                        matches.clear();
                        failure = Some(matcher_error(error));
                        break;
                    }
                }
            }
            if matches.is_empty() {
                OperationOutcome { operation_index, status: OutcomeStatus::Failed, error: Some(failure.unwrap_or_else(|| "search block not found in file (matches are exact, including whitespace/indentation)".into())) }
            } else {
                OperationOutcome {
                    operation_index,
                    status: OutcomeStatus::Success,
                    error: None,
                }
            }
        } else {
            match match_selector(
                &processed_selector,
                &processed,
                &full_index,
                minimum,
                reject_ambiguity,
            ) {
                Ok(start) => {
                    matches.push(start);
                    OperationOutcome {
                        operation_index,
                        status: OutcomeStatus::Success,
                        error: None,
                    }
                }
                Err(error) => OperationOutcome {
                    operation_index,
                    status: OutcomeStatus::Failed,
                    error: Some(matcher_error(error)),
                },
            }
        };
        if outcome.status == OutcomeStatus::Success {
            for start in &matches {
                let replacement = corrected_replacement(
                    &file[*start..*start + selector.len()],
                    &selector,
                    &plain_lines(&operation.replace),
                    &request.path_label,
                );
                patches.push(LinePatch {
                    start: *start,
                    old_count: selector.len(),
                    replacement,
                });
            }
            if let Some(first) = matches.first() {
                cursors.insert(key, minimum.max(first + selector.len()));
            }
        }
        outcomes.push(outcome);
    }
    let applied = outcomes
        .iter()
        .filter(|o| o.status == OutcomeStatus::Success)
        .count();
    if applied == 0 {
        return finish(
            request,
            original,
            original.to_owned(),
            None,
            resolved.len(),
            0,
            ApplyStatus::Failed,
            Some(outcomes),
        );
    }
    let updated_lines = apply_line_patches(&file, &patches)
        .ok_or_else(|| ApplyError::Internal("diff application failed".into()))?;
    let ending = dominant_ending(original);
    let trailing = original.ends_with(ending);
    let mut updated = updated_lines.join(ending);
    if trailing {
        updated.push_str(ending);
    }
    let status = if applied == resolved.len() {
        ApplyStatus::Success
    } else {
        ApplyStatus::Partial
    };
    finish(
        request,
        original,
        updated,
        None,
        resolved.len(),
        applied,
        status,
        Some(outcomes),
    )
}

pub fn apply_subject(request: &ApplySubjectRequest) -> Result<ApplyResult, ApplyError> {
    let original = std::str::from_utf8(&request.original)
        .map_err(|_| ApplyError::InvalidParams("originalUTF8 is not valid UTF-8".into()))?;
    match &request.mode {
        ApplyMode::Rewrite { replacement } => finish(
            request,
            original,
            replacement.clone(),
            None,
            1,
            1,
            ApplyStatus::Success,
            None,
        ),
        ApplyMode::Single { operation } => apply_single(request, original, operation),
        ApplyMode::Batch { operations } => apply_batch(request, original, operations),
    }
}
