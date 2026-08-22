use std::collections::HashMap;

const NAME_BUFFER_LIMIT: usize = 1023;
const PATH_BUFFER_LIMIT: usize = 2047;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Candidate<'a> {
    pub name: &'a [u8],
    pub path: &'a [u8],
    pub name_lower: &'a [u8],
    pub path_lower: &'a [u8],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Query<'a> {
    pub raw: &'a [u8],
    pub lowered: &'a [u8],
    pub has_slash: bool,
    pub is_wildcard: bool,
}

#[must_use]
pub fn score_matches_batch(
    candidates: &[Candidate<'_>],
    query: Query<'_>,
    fuzzy_threshold: f64,
) -> Vec<i32> {
    if candidates.is_empty() || query.raw.is_empty() {
        return Vec::new();
    }

    candidates
        .iter()
        .map(|candidate| score_match(*candidate, query, fuzzy_threshold))
        .collect()
}

fn score_match(candidate: Candidate<'_>, query: Query<'_>, fuzzy_threshold: f64) -> i32 {
    let name = c_string(candidate.name);
    let path = c_string(candidate.path);
    let name_lower = c_string(candidate.name_lower);
    let path_lower = c_string(candidate.path_lower);
    let query_raw = c_string(query.raw);
    let query_lower = c_string(query.lowered);

    if query_raw.is_empty() {
        return 0;
    }

    if name_lower == query_lower {
        return 1000;
    }
    if path_lower == query_lower {
        return 950;
    }

    let bounded_name = &name_lower[..name_lower.len().min(NAME_BUFFER_LIMIT)];
    if let Some(dot) = bounded_name.iter().rposition(|byte| *byte == b'.')
        && dot != 0
        && &bounded_name[..dot] == query_lower
    {
        return 1000;
    }

    if name_lower.starts_with(query_lower) {
        return 900;
    }
    if query.has_slash && path_lower.starts_with(query_lower) {
        return 875;
    }

    if path_components(path_lower).any(|component| component.starts_with(query_lower)) {
        return 850;
    }

    if contains(name_lower, query_lower) {
        return 750;
    }
    if query.has_slash && contains(path_lower, query_lower) {
        return 700;
    }
    if !query.has_slash && contains(path_lower, query_lower) {
        return 750;
    }

    if query.is_wildcard && wildcard_score_match(query_raw, name, path) {
        return 650;
    }

    if query_lower.len() >= 3 && !query.is_wildcard {
        if similarity_score(name_lower, query_lower) >= fuzzy_threshold {
            return 500;
        }
        if path_components(path_lower)
            .any(|component| similarity_score(component, query_lower) >= fuzzy_threshold)
        {
            return 450;
        }
    }

    0
}

fn c_string(bytes: &[u8]) -> &[u8] {
    &bytes[..bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len())]
}

fn path_components(path: &[u8]) -> impl Iterator<Item = &[u8]> {
    path[..path.len().min(PATH_BUFFER_LIMIT)]
        .split(|byte| *byte == b'/')
        .filter(|component| !component.is_empty())
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    needle.is_empty()
        || (needle.len() <= haystack.len()
            && haystack
                .windows(needle.len())
                .any(|window| window == needle))
}

fn wildcard_score_match(pattern: &[u8], name: &[u8], path: &[u8]) -> bool {
    if let Some(pattern_after_star) = pattern.strip_prefix(b"**/") {
        if wildmatch(pattern_after_star, name) {
            return true;
        }
        let mut suffix = path;
        while !suffix.is_empty() {
            if wildmatch(pattern_after_star, suffix) {
                return true;
            }
            let Some(slash) = suffix.iter().position(|byte| *byte == b'/') else {
                break;
            };
            suffix = &suffix[slash + 1..];
        }
    }

    wildmatch(pattern, name) || wildmatch(pattern, path)
}

fn wildmatch(pattern: &[u8], text: &[u8]) -> bool {
    let mut memo = HashMap::new();
    wildmatch_from(pattern, text, 0, 0, &mut memo)
}

fn wildmatch_from(
    pattern: &[u8],
    text: &[u8],
    pattern_index: usize,
    text_index: usize,
    memo: &mut HashMap<(usize, usize), bool>,
) -> bool {
    if let Some(result) = memo.get(&(pattern_index, text_index)) {
        return *result;
    }

    let result = if pattern_index == pattern.len() {
        text_index == text.len()
    } else {
        match pattern[pattern_index] {
            b'?' => {
                text_index < text.len()
                    && text[text_index] != b'/'
                    && wildmatch_from(pattern, text, pattern_index + 1, text_index + 1, memo)
            }
            b'*' => match_star(pattern, text, pattern_index, text_index, memo),
            b'[' => {
                match character_class(pattern, pattern_index + 1, text.get(text_index).copied()) {
                    Some((matched, next_pattern)) => {
                        matched && wildmatch_from(pattern, text, next_pattern, text_index + 1, memo)
                    }
                    None => {
                        text.get(text_index)
                            .is_some_and(|byte| byte_eq(b'[', *byte))
                            && wildmatch_from(
                                pattern,
                                text,
                                pattern_index + 1,
                                text_index + 1,
                                memo,
                            )
                    }
                }
            }
            b'\\' => {
                let (literal, next_pattern) = pattern
                    .get(pattern_index + 1)
                    .map_or((b'\\', pattern_index + 1), |byte| {
                        (*byte, pattern_index + 2)
                    });
                text.get(text_index)
                    .is_some_and(|byte| byte_eq(literal, *byte))
                    && wildmatch_from(pattern, text, next_pattern, text_index + 1, memo)
            }
            literal => {
                text.get(text_index)
                    .is_some_and(|byte| byte_eq(literal, *byte))
                    && wildmatch_from(pattern, text, pattern_index + 1, text_index + 1, memo)
            }
        }
    };

    memo.insert((pattern_index, text_index), result);
    result
}

fn match_star(
    pattern: &[u8],
    text: &[u8],
    pattern_index: usize,
    text_index: usize,
    memo: &mut HashMap<(usize, usize), bool>,
) -> bool {
    let mut next_pattern = pattern_index;
    while pattern.get(next_pattern) == Some(&b'*') {
        next_pattern += 1;
    }
    let wildstar = next_pattern - pattern_index >= 2;

    if wildstar {
        if pattern.get(next_pattern) == Some(&b'/') {
            if wildmatch_from(pattern, text, next_pattern + 1, text_index, memo) {
                return true;
            }
            for cursor in text_index..text.len() {
                if text[cursor] == b'/'
                    && wildmatch_from(pattern, text, next_pattern + 1, cursor + 1, memo)
                {
                    return true;
                }
            }
            return false;
        }
        if next_pattern == pattern.len() {
            let preceded_by_slash = pattern_index > 0 && pattern[pattern_index - 1] == b'/';
            return preceded_by_slash || !text[text_index..].contains(&b'/');
        }
        return false;
    }

    let mut cursor = text_index;
    loop {
        if wildmatch_from(pattern, text, next_pattern, cursor, memo) {
            return true;
        }
        if cursor == text.len() || text[cursor] == b'/' {
            return false;
        }
        cursor += 1;
    }
}

fn character_class(pattern: &[u8], mut index: usize, value: Option<u8>) -> Option<(bool, usize)> {
    let value = value?;
    if value == b'/' {
        return Some((false, pattern.len()));
    }
    let negated = matches!(pattern.get(index), Some(b'!' | b'^'));
    if negated {
        index += 1;
    }

    let mut matched = false;
    let mut had_item = false;
    if pattern.get(index) == Some(&b']') {
        matched = value == b']';
        had_item = true;
        index += 1;
    }

    while index < pattern.len() && pattern[index] != b']' {
        had_item = true;
        let start = class_byte(pattern, &mut index)?;
        if pattern.get(index) == Some(&b'-')
            && pattern.get(index + 1).is_some_and(|byte| *byte != b']')
        {
            index += 1;
            let end = class_byte(pattern, &mut index)?;
            let (lower, upper) = if ascii_fold(start) <= ascii_fold(end) {
                (ascii_fold(start), ascii_fold(end))
            } else {
                (ascii_fold(end), ascii_fold(start))
            };
            matched |= (lower..=upper).contains(&ascii_fold(value));
        } else if start == b'[' && pattern.get(index) == Some(&b':') {
            if let Some((class_match, next)) = posix_class(pattern, index + 1, value) {
                matched |= class_match;
                index = next;
            } else {
                matched |= byte_eq(start, value);
            }
        } else {
            matched |= byte_eq(start, value);
        }
    }

    if !had_item || pattern.get(index) != Some(&b']') {
        None
    } else {
        Some((matched != negated, index + 1))
    }
}

fn class_byte(pattern: &[u8], index: &mut usize) -> Option<u8> {
    let byte = *pattern.get(*index)?;
    *index += 1;
    if byte == b'\\' {
        let escaped = *pattern.get(*index)?;
        *index += 1;
        Some(escaped)
    } else {
        Some(byte)
    }
}

fn posix_class(pattern: &[u8], name_start: usize, value: u8) -> Option<(bool, usize)> {
    let end = pattern[name_start..]
        .windows(2)
        .position(|window| window == b":]")?
        + name_start;
    let name = &pattern[name_start..end];
    let value = ascii_fold(value);
    let matched = match name {
        b"alnum" => value.is_ascii_alphanumeric(),
        b"alpha" => value.is_ascii_alphabetic(),
        b"blank" => matches!(value, b' ' | b'\t'),
        b"cntrl" => value.is_ascii_control(),
        b"digit" => value.is_ascii_digit(),
        b"graph" => value.is_ascii_graphic(),
        b"lower" => value.is_ascii_lowercase(),
        b"print" => value.is_ascii_graphic() || value == b' ',
        b"punct" => value.is_ascii_punctuation(),
        b"space" => value.is_ascii_whitespace(),
        b"upper" => value.is_ascii_alphabetic(),
        b"xdigit" => value.is_ascii_hexdigit(),
        _ => return None,
    };
    Some((matched, end + 2))
}

fn byte_eq(left: u8, right: u8) -> bool {
    ascii_fold(left) == ascii_fold(right)
}

fn ascii_fold(byte: u8) -> u8 {
    byte.to_ascii_lowercase()
}

fn similarity_score(left: &[u8], right: &[u8]) -> f64 {
    if left == right {
        return 1.0;
    }
    if left.len() > 64 || right.len() > 64 {
        return dice_coefficient(left, right);
    }

    let max_len = left.len().max(right.len());
    if max_len == 0 {
        return 1.0;
    }
    let max_allowed_distance = ((max_len as f64) * 0.15).ceil() as usize;
    let distance = levenshtein_distance(left, right);
    if distance > max_allowed_distance {
        dice_coefficient(left, right)
    } else {
        1.0 - (distance as f64 / max_len as f64)
    }
}

fn levenshtein_distance(left: &[u8], right: &[u8]) -> usize {
    let mut left_units = utf8_units(left);
    let mut right_units = utf8_units(right);
    if right_units.len() < left_units.len() {
        std::mem::swap(&mut left_units, &mut right_units);
    }
    if left_units.is_empty() {
        return right_units.len();
    }
    if right_units.is_empty() {
        return left_units.len();
    }

    let mut previous: Vec<usize> = (0..=right_units.len()).collect();
    let mut current = vec![0; right_units.len() + 1];
    for (left_index, left_unit) in left_units.iter().enumerate() {
        current[0] = left_index + 1;
        for (right_index, right_unit) in right_units.iter().enumerate() {
            let insertion = current[right_index] + 1;
            let deletion = previous[right_index + 1] + 1;
            let substitution = previous[right_index] + usize::from(left_unit != right_unit);
            current[right_index + 1] = insertion.min(deletion).min(substitution);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[right_units.len()]
}

fn utf8_units(bytes: &[u8]) -> Vec<&[u8]> {
    let starts: Vec<usize> = bytes
        .iter()
        .enumerate()
        .filter_map(|(index, byte)| (byte & 0xc0 != 0x80).then_some(index))
        .collect();
    starts
        .iter()
        .enumerate()
        .map(|(index, start)| {
            let end = starts.get(index + 1).copied().unwrap_or(bytes.len());
            &bytes[*start..end]
        })
        .collect()
}

fn dice_coefficient(left: &[u8], right: &[u8]) -> f64 {
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    if left == right {
        return 1.0;
    }
    if left.len() == 1 || right.len() == 1 {
        return f64::from(left[0] == right[0]);
    }

    let mut left_bigrams: HashMap<u16, usize> = HashMap::new();
    let mut right_bigrams: HashMap<u16, usize> = HashMap::new();
    for pair in left.windows(2) {
        *left_bigrams
            .entry(u16::from_be_bytes([
                ascii_fold(pair[0]),
                ascii_fold(pair[1]),
            ]))
            .or_default() += 1;
    }
    for pair in right.windows(2) {
        *right_bigrams
            .entry(u16::from_be_bytes([
                ascii_fold(pair[0]),
                ascii_fold(pair[1]),
            ]))
            .or_default() += 1;
    }

    let intersection: usize = left_bigrams
        .iter()
        .map(|(bigram, left_count)| left_count.min(right_bigrams.get(bigram).unwrap_or(&0)))
        .sum();
    (2 * intersection) as f64 / (left.len() + right.len() - 2) as f64
}
