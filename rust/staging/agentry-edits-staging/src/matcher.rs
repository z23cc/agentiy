use std::collections::HashMap;

pub const MAX_FUZZY_KEYS: usize = 400;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LineData {
    pub original: String,
    pub cleaned: String,
    pub loose: String,
    pub strict: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MatchError {
    InvalidSelector,
    NoMatch,
    Ambiguous(Vec<usize>),
}

fn strip_indent_tag(input: &str) -> &str {
    if (input.starts_with("<s") || input.starts_with("<t")) && input.find('>').is_some() {
        &input[input.find('>').unwrap() + 1..]
    } else {
        input
    }
}

fn collapse_separators(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let chars: Vec<_> = input.chars().collect();
    let mut index = 0;
    while index < chars.len() {
        let ch = chars[index];
        let sep = matches!(ch, '-' | '_' | '–' | '—' | '─' | '━' | '═');
        if sep {
            let start = index;
            while index < chars.len()
                && matches!(chars[index], '-' | '_' | '–' | '—' | '─' | '━' | '═')
            {
                index += 1;
            }
            if index - start >= 2 {
                out.push('-');
            } else {
                out.push(ch);
            }
        } else {
            out.push(ch);
            index += 1;
        }
    }
    out
}

fn decode_html_entities(input: &str) -> String {
    let mut output = input
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&");
    let mut cursor = 0;
    while let Some(relative) = output[cursor..].find("&#") {
        let start = cursor + relative;
        let Some(relative_end) = output[start..].find(';') else {
            break;
        };
        let end = start + relative_end;
        let body = &output[start + 2..end];
        let value = body
            .strip_prefix(['x', 'X'])
            .and_then(|hex| u32::from_str_radix(hex, 16).ok())
            .or_else(|| body.parse::<u32>().ok())
            .and_then(char::from_u32);
        if let Some(value) = value {
            output.replace_range(start..=end, &value.to_string());
            cursor = start + value.len_utf8();
        } else {
            cursor = end + 1;
        }
    }
    output
}

fn truncate_chars(input: &str, cap: usize) -> String {
    input.chars().take(cap).collect()
}

pub fn canonical_key(raw: &str) -> Option<String> {
    let mut text = decode_html_entities(raw)
        .replace('\u{00a0}', " ")
        .to_lowercase();
    text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    for qualifier in [
        "public",
        "private",
        "internal",
        "fileprivate",
        "open",
        "final",
        "static",
        "class",
        "override",
    ] {
        if let Some(rest) = text.strip_prefix(&format!("{qualifier} ")) {
            text = rest.to_owned();
            break;
        }
    }
    text = collapse_separators(&text);
    text = truncate_chars(&text, 150);
    for token in ["->", "=>", ":=", "=", ":"] {
        if let Some(rest) = text.strip_suffix(token) {
            text = rest.trim_end().to_owned();
            break;
        }
    }
    (!text.is_empty()).then_some(text)
}

pub fn process_line(raw: &str, high_precision: bool) -> LineData {
    let cleaned = canonical_key(raw).unwrap_or_default();
    let without_tag = strip_indent_tag(&cleaned);
    LineData {
        original: raw.to_owned(),
        strict: truncate_chars(without_tag, 150),
        loose: truncate_chars(without_tag, if high_precision { 150 } else { 25 }),
        cleaned,
    }
}

pub fn build_line_index(lines: &[LineData]) -> HashMap<String, Vec<usize>> {
    let mut map = HashMap::with_capacity(lines.len() * 2);
    for (index, line) in lines.iter().enumerate() {
        map.entry(line.strict.clone())
            .or_insert_with(Vec::new)
            .push(index);
        map.entry(line.loose.clone())
            .or_insert_with(Vec::new)
            .push(index);
    }
    map
}

pub fn dice_coefficient(a: &str, b: &str) -> f64 {
    if a == b {
        return 1.0;
    }
    let a: Vec<_> = a.bytes().map(|byte| byte.to_ascii_lowercase()).collect();
    let b: Vec<_> = b.bytes().map(|byte| byte.to_ascii_lowercase()).collect();
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    if a.len() == 1 || b.len() == 1 {
        return if a == b { 1.0 } else { 0.0 };
    }
    let mut counts: HashMap<(u8, u8), usize> = HashMap::new();
    for pair in a.windows(2) {
        *counts.entry((pair[0], pair[1])).or_default() += 1;
    }
    let mut intersection = 0;
    for pair in b.windows(2) {
        if let Some(count) = counts.get_mut(&(pair[0], pair[1])) {
            if *count > 0 {
                *count -= 1;
                intersection += 1;
            }
        }
    }
    2.0 * intersection as f64 / ((a.len() - 1) + (b.len() - 1)) as f64
}

fn adaptive_threshold(len: usize) -> f64 {
    match len {
        0..=4 => 0.25,
        5..=7 => 0.35,
        8..=12 => 0.50,
        13..=20 => 0.65,
        21..=40 => 0.70,
        _ => 0.80,
    }
}

fn positions(line: &LineData, index: &HashMap<String, Vec<usize>>, minimum: usize) -> Vec<usize> {
    let strict: Vec<_> = index
        .get(&line.strict)
        .into_iter()
        .flatten()
        .copied()
        .filter(|&p| p >= minimum)
        .collect();
    if !strict.is_empty() {
        strict
    } else {
        index
            .get(&line.loose)
            .into_iter()
            .flatten()
            .copied()
            .filter(|&p| p >= minimum)
            .collect()
    }
}

fn fuzzy_positions(
    selector_key: &str,
    index: &HashMap<String, Vec<usize>>,
    minimum: usize,
    threshold: f64,
) -> (Vec<usize>, HashMap<usize, u64>) {
    let mut candidates = Vec::new();
    let mut scores: HashMap<usize, u64> = HashMap::new();
    let mut seen = 0;
    // Stable order makes the 400-key budget deterministic in the Rust contract.
    let mut keys: Vec<_> = index.keys().collect();
    keys.sort();
    for key in keys {
        let eligible: Vec<_> = index[key]
            .iter()
            .copied()
            .filter(|&p| p >= minimum)
            .collect();
        if eligible.is_empty() {
            continue; // Swift fix: pre-minimum keys do not consume the budget.
        }
        if seen >= MAX_FUZZY_KEYS {
            break;
        }
        seen += 1;
        let score = dice_coefficient(selector_key, key);
        if score >= threshold {
            let scaled = (score * 1_000_000.0).round() as u64;
            for position in eligible {
                candidates.push(position);
                scores
                    .entry(position)
                    .and_modify(|v| *v = (*v).max(scaled))
                    .or_insert(scaled);
            }
        }
    }
    (candidates, scores)
}

pub fn match_selector(
    selector: &[LineData],
    content: &[LineData],
    index: &HashMap<String, Vec<usize>>,
    minimum_match_index: usize,
    reject_ambiguity: bool,
) -> Result<usize, MatchError> {
    if selector.is_empty() || content.is_empty() {
        return Err(MatchError::InvalidSelector);
    }
    let count = selector.len();
    let threshold = if count >= 6 {
        0.90
    } else if count >= 3 {
        0.855
    } else {
        adaptive_threshold(
            selector
                .iter()
                .map(|l| l.strict.chars().count())
                .min()
                .unwrap_or(0),
        )
    };
    let mut starts = positions(&selector[0], index, minimum_match_index);
    let mut fuzzy_scores = HashMap::new();
    if starts.is_empty() {
        (starts, fuzzy_scores) =
            fuzzy_positions(&selector[0].strict, index, minimum_match_index, threshold);
    }
    starts.sort_unstable();
    starts.dedup();
    if starts.is_empty() {
        return Err(MatchError::NoMatch);
    }

    if count > 1 {
        let mut second: Vec<_> = positions(&selector[1], index, minimum_match_index)
            .into_iter()
            .filter_map(|p| (p > minimum_match_index).then_some(p - 1))
            .collect();
        if second.is_empty() {
            second = fuzzy_positions(&selector[1].strict, index, minimum_match_index, threshold)
                .0
                .into_iter()
                .filter_map(|p| (p > minimum_match_index).then_some(p - 1))
                .collect();
        }
        let intersection: Vec<_> = starts
            .iter()
            .copied()
            .filter(|p| second.contains(p))
            .collect();
        if !intersection.is_empty() {
            starts = intersection;
        }
    }

    let long = count >= 6;
    let head_len = if long { 2 } else { count };
    let tail_len = if long { 2 } else { 0 };
    let required_medium = count.min(3);
    let mut valid = Vec::new();
    for start in starts {
        if start + count > content.len() {
            continue;
        }
        let head = (0..head_len)
            .filter(|&o| content[start + o].strict == selector[o].strict)
            .count();
        let tail = (0..tail_len)
            .filter(|&o| {
                let selector_index = count - tail_len + o;
                content[start + selector_index].strict == selector[selector_index].strict
            })
            .count();
        let passes = if long {
            head == head_len && tail == tail_len
        } else if count < 3 {
            head == count
        } else {
            head >= required_medium
        };
        if passes {
            valid.push((start, head + tail));
        }
    }
    if reject_ambiguity && valid.len() > 1 {
        return Err(MatchError::Ambiguous(
            valid.into_iter().map(|v| v.0).collect(),
        ));
    }
    if !valid.is_empty() {
        let mut best = valid[0];
        for candidate in valid.into_iter().skip(1) {
            if candidate.1 > best.1 {
                best = candidate;
            }
        }
        return Ok(best.0);
    }
    if count <= 2 {
        return fuzzy_scores
            .into_iter()
            .max_by_key(|(_, score)| *score)
            .map(|(position, _)| position)
            .ok_or(MatchError::NoMatch);
    }
    Err(MatchError::NoMatch)
}
