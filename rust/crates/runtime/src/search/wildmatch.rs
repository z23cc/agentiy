use std::collections::HashMap;

pub(crate) fn matches(pattern: &str, text: &str, case_insensitive: bool) -> bool {
    let wildstar = pattern.contains("**");
    let mut memo = HashMap::new();
    match_from(
        pattern.as_bytes(),
        text.as_bytes(),
        0,
        0,
        wildstar,
        case_insensitive,
        &mut memo,
    )
}

fn match_from(
    pattern: &[u8],
    text: &[u8],
    pattern_index: usize,
    text_index: usize,
    pathname: bool,
    case_insensitive: bool,
    memo: &mut HashMap<(usize, usize), bool>,
) -> bool {
    if let Some(result) = memo.get(&(pattern_index, text_index)) {
        return *result;
    }
    let mut p = pattern_index;
    let mut t = text_index;
    let result = loop {
        if p == pattern.len() {
            break t == text.len();
        }
        match pattern[p] {
            b'?' => {
                if t == text.len() || (pathname && text[t] == b'/') {
                    break false;
                }
                p += 1;
                t += 1;
            }
            b'*' => {
                let mut stars = 1usize;
                while pattern.get(p + stars) == Some(&b'*') {
                    stars += 1;
                }
                let wildstar = pathname && stars >= 2;
                p += stars;
                if p == pattern.len() {
                    break wildstar || !pathname || !text[t..].contains(&b'/');
                }
                if wildstar
                    && pattern.get(p) == Some(&b'/')
                    && match_from(pattern, text, p + 1, t, pathname, case_insensitive, memo)
                {
                    break true;
                }
                let mut cursor = t;
                let matched = loop {
                    if match_from(pattern, text, p, cursor, pathname, case_insensitive, memo) {
                        break true;
                    }
                    if cursor == text.len() || (!wildstar && pathname && text[cursor] == b'/') {
                        break false;
                    }
                    cursor += 1;
                };
                break matched;
            }
            b'[' => {
                if t == text.len() || (pathname && text[t] == b'/') {
                    break false;
                }
                match character_class(pattern, p + 1, text[t], case_insensitive) {
                    Some((matched, next)) if matched => {
                        p = next;
                        t += 1;
                    }
                    Some(_) => break false,
                    None => {
                        if !byte_eq(b'[', text[t], case_insensitive) {
                            break false;
                        }
                        p += 1;
                        t += 1;
                    }
                }
            }
            b'\\' => {
                let literal = pattern.get(p + 1).copied().unwrap_or(b'\\');
                let advance = usize::from(p + 1 < pattern.len()) + 1;
                if t == text.len() || !byte_eq(literal, text[t], case_insensitive) {
                    break false;
                }
                p += advance;
                t += 1;
            }
            literal => {
                if t == text.len() || !byte_eq(literal, text[t], case_insensitive) {
                    break false;
                }
                p += 1;
                t += 1;
            }
        }
    };
    memo.insert((pattern_index, text_index), result);
    result
}

fn character_class(
    pattern: &[u8],
    mut index: usize,
    value: u8,
    case_insensitive: bool,
) -> Option<(bool, usize)> {
    let negated = matches!(pattern.get(index), Some(b'!' | b'^'));
    if negated {
        index += 1;
    }
    let mut matched = false;
    let mut had_item = false;
    while index < pattern.len() && pattern[index] != b']' {
        had_item = true;
        let start = if pattern[index] == b'\\' {
            index += 1;
            *pattern.get(index)?
        } else {
            pattern[index]
        };
        index += 1;
        if pattern.get(index) == Some(&b'-')
            && pattern.get(index + 1).is_some_and(|byte| *byte != b']')
        {
            index += 1;
            let end = pattern[index];
            index += 1;
            let candidate = folded(value, case_insensitive);
            matched |= (folded(start, case_insensitive)..=folded(end, case_insensitive))
                .contains(&candidate);
        } else {
            matched |= byte_eq(start, value, case_insensitive);
        }
    }
    if !had_item || pattern.get(index) != Some(&b']') {
        None
    } else {
        Some((matched != negated, index + 1))
    }
}

fn byte_eq(left: u8, right: u8, case_insensitive: bool) -> bool {
    folded(left, case_insensitive) == folded(right, case_insensitive)
}

fn folded(value: u8, case_insensitive: bool) -> u8 {
    if case_insensitive {
        value.to_ascii_lowercase()
    } else {
        value
    }
}
