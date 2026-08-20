use super::{EngineKind, RegexSearchMode};

pub(crate) const DECLARATION_PATTERN: &str =
    r"^\s*(?:final\s+)?(?:class|struct|func)\s+[A-Za-z_][A-Za-z0-9_]*";
pub(crate) const MARKER_PATTERN: &str = r"\bTODO-\d{3}:\s+Search\w*";

#[derive(Clone, Debug)]
pub(crate) struct FastPlan {
    pub(crate) engine: EngineKind,
    pub(crate) required_needles: Vec<&'static [u8]>,
}

pub(crate) fn select(mode: RegexSearchMode, pattern: &str, whole_word: bool) -> Option<FastPlan> {
    if whole_word
        && !pattern.is_empty()
        && pattern
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
    {
        return Some(FastPlan {
            engine: EngineKind::AsciiWholeWord,
            required_needles: vec![],
        });
    }
    if pattern == DECLARATION_PATTERN {
        return Some(FastPlan {
            engine: EngineKind::AnchoredDeclaration,
            required_needles: vec![b"class", b"struct", b"func"],
        });
    }
    if pattern == MARKER_PATTERN {
        return Some(FastPlan {
            engine: EngineKind::AsciiMarker,
            required_needles: vec![b"TODO", b"Search"],
        });
    }
    if mode == RegexSearchMode::Path && path_suffixes(pattern).is_some() {
        return Some(FastPlan {
            engine: EngineKind::PathSuffix,
            required_needles: vec![],
        });
    }
    let required_needles = match pattern {
        r"^\s*(?:class|struct|func)\b" | r"^\s*(class|struct|func)\b" => {
            vec![
                b"class".as_slice(),
                b"struct".as_slice(),
                b"func".as_slice(),
            ]
        }
        r"^import\b" => vec![b"import".as_slice()],
        _ => return None,
    };
    Some(FastPlan {
        engine: EngineKind::AnchoredLinePrefilter,
        required_needles,
    })
}

pub(crate) fn prefilter(plan: &FastPlan, bytes: &[u8], case_insensitive: bool) -> bool {
    if plan.required_needles.is_empty() {
        return true;
    }
    plan.required_needles
        .iter()
        .any(|needle| contains_ascii(bytes, needle, case_insensitive))
}

/// Returns `None` when this plan must fall back to PCRE2, otherwise the exact
/// first match (or an exact no-match) for one ASCII line.
pub(crate) fn direct_line_match(
    plan: &FastPlan,
    pattern: &str,
    bytes: &[u8],
    case_insensitive: bool,
) -> Option<Option<(usize, usize)>> {
    if !bytes.is_ascii() {
        return None;
    }
    match plan.engine {
        EngineKind::AsciiWholeWord => Some(ascii_word(bytes, pattern.as_bytes(), case_insensitive)),
        EngineKind::AnchoredDeclaration => Some(declaration(bytes, case_insensitive)),
        EngineKind::AsciiMarker => Some(marker(bytes, case_insensitive)),
        _ => None,
    }
}

pub(crate) fn direct_path_match(
    plan: &FastPlan,
    pattern: &str,
    bytes: &[u8],
    case_insensitive: bool,
) -> Option<Option<(usize, usize)>> {
    if plan.engine != EngineKind::PathSuffix || !bytes.is_ascii() {
        return None;
    }
    let suffixes = path_suffixes(pattern)?;
    let matched = suffixes.iter().any(|suffix| {
        let start = bytes.len().checked_sub(suffix.len());
        start.is_some_and(|start| {
            let ending = &bytes[start..];
            if case_insensitive {
                ending.eq_ignore_ascii_case(suffix.as_bytes())
            } else {
                ending == suffix.as_bytes()
            }
        })
    });
    Some(matched.then_some((0, bytes.len())))
}

fn ascii_word(bytes: &[u8], needle: &[u8], case_insensitive: bool) -> Option<(usize, usize)> {
    bytes
        .windows(needle.len())
        .enumerate()
        .find_map(|(start, window)| {
            let equal = if case_insensitive {
                window.eq_ignore_ascii_case(needle)
            } else {
                window == needle
            };
            let end = start + needle.len();
            (equal
                && (start == 0 || !is_word(bytes[start - 1]))
                && (end == bytes.len() || !is_word(bytes[end])))
            .then_some((start, end))
        })
}

fn declaration(bytes: &[u8], case_insensitive: bool) -> Option<(usize, usize)> {
    let mut index = 0;
    skip_space(bytes, &mut index);
    let before_final = index;
    if consume(bytes, &mut index, b"final", case_insensitive) {
        if !bytes.get(index).is_some_and(|byte| is_space(*byte)) {
            return None;
        }
        skip_space(bytes, &mut index);
    } else {
        index = before_final;
    }
    let keyword_end = [
        b"class".as_slice(),
        b"struct".as_slice(),
        b"func".as_slice(),
    ]
    .iter()
    .find_map(|word| {
        let mut candidate = index;
        consume(bytes, &mut candidate, word, case_insensitive).then_some(candidate)
    })?;
    index = keyword_end;
    if !bytes.get(index).is_some_and(|byte| is_space(*byte)) {
        return None;
    }
    skip_space(bytes, &mut index);
    if !bytes
        .get(index)
        .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_')
    {
        return None;
    }
    index += 1;
    while bytes.get(index).is_some_and(|byte| is_word(*byte)) {
        index += 1;
    }
    Some((0, index))
}

fn marker(bytes: &[u8], case_insensitive: bool) -> Option<(usize, usize)> {
    for start in 0..bytes.len() {
        if start > 0 && is_word(bytes[start - 1]) {
            continue;
        }
        let mut index = start;
        if !consume(bytes, &mut index, b"TODO-", case_insensitive)
            || bytes
                .get(index..index.saturating_add(3))
                .is_none_or(|digits| !digits.iter().all(u8::is_ascii_digit))
        {
            continue;
        }
        index += 3;
        if bytes.get(index) != Some(&b':') {
            continue;
        }
        index += 1;
        if !bytes.get(index).is_some_and(|byte| is_space(*byte)) {
            continue;
        }
        skip_space(bytes, &mut index);
        if !consume(bytes, &mut index, b"Search", case_insensitive) {
            continue;
        }
        while bytes.get(index).is_some_and(|byte| is_word(*byte)) {
            index += 1;
        }
        return Some((start, index));
    }
    None
}

fn consume(bytes: &[u8], index: &mut usize, expected: &[u8], case_insensitive: bool) -> bool {
    let Some(candidate) = bytes.get(*index..index.saturating_add(expected.len())) else {
        return false;
    };
    let matched = if case_insensitive {
        candidate.eq_ignore_ascii_case(expected)
    } else {
        candidate == expected
    };
    if matched {
        *index += expected.len();
    }
    matched
}

fn skip_space(bytes: &[u8], index: &mut usize) {
    while bytes.get(*index).is_some_and(|byte| is_space(*byte)) {
        *index += 1;
    }
}

fn is_space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | 0x0b | 0x0c)
}

fn is_word(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

fn contains_ascii(haystack: &[u8], needle: &[u8], case_insensitive: bool) -> bool {
    haystack.windows(needle.len()).any(|window| {
        window.iter().zip(needle).all(|(left, right)| {
            if case_insensitive {
                left.to_ascii_lowercase() == right.to_ascii_lowercase()
            } else {
                left == right
            }
        })
    })
}

fn path_suffixes(pattern: &str) -> Option<Vec<String>> {
    let inner = pattern.strip_prefix(r".*\.")?.strip_suffix('$')?;
    let alternatives = inner
        .strip_prefix('(')
        .and_then(|value| value.strip_suffix(')'));
    let values: Vec<&str> =
        alternatives.map_or_else(|| vec![inner], |value| value.split('|').collect());
    if values.is_empty()
        || values.len() > 64
        || values.iter().any(|value| {
            value.is_empty()
                || !value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
        })
    {
        return None;
    }
    Some(
        values
            .into_iter()
            .map(|value| format!(".{value}"))
            .collect(),
    )
}
