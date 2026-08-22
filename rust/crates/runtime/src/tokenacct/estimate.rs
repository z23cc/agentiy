//! Pure functions ported byte-for-byte from `TokenCalculationService.estimateTokens` /
//! `WorkspaceTextLineCounter.countLines` / `TokenCalculationService.extractFolderPath` and the
//! `TokenInfo` formatted-string/percentage derivation. See `super`'s module doc for why none of
//! these need a Unicode text-segmentation dependency.

/// Mirrors `TokenCalculationService.estimateTokens(utf8ByteCount:)`:
/// `Int((Double(utf8ByteCount) / 4.0) * 1.05)`.
///
/// The expression is replicated verbatim -- `1.05` is not exactly representable in binary
/// floating point, so this performs exactly one division followed by one rounded multiplication,
/// then truncates toward zero (`as u64`, matching Swift's `Int(Double)` truncating initializer).
/// Any algebraically-equivalent reformulation (e.g. `* 0.2625`, or an integer `n * 21 / 80`) is a
/// *different* rounding sequence and can disagree by one on specific byte counts.
#[must_use]
pub fn estimate_tokens_from_byte_count(utf8_byte_count: u64) -> u64 {
    ((utf8_byte_count as f64 / 4.0) * 1.05) as u64
}

/// Mirrors `TokenCalculationService.estimateTokens(for:)`: byte-count estimate over `text`'s
/// UTF-8 encoding length.
#[must_use]
pub fn estimate_tokens(text: &str) -> u64 {
    estimate_tokens_from_byte_count(text.len() as u64)
}

/// Mirrors `WorkspaceTextLineCounter.countLines(in:)`: a byte-level scan counting line
/// terminators (bare `\n`, bare `\r`, and `\r\n` as one), plus one more if the text does not end
/// on a line terminator. Bytes `10` (`\n`) and `13` (`\r`) can never occur as a continuation byte
/// inside a multi-byte UTF-8 sequence, so scanning raw bytes (rather than `char`s or grapheme
/// clusters) is safe and produces the identical result Swift's `UTF8View` scan does.
#[must_use]
pub fn count_lines(text: &str) -> u64 {
    if text.is_empty() {
        return 0;
    }

    let mut count: u64 = 0;
    let mut previous_was_carriage_return = false;
    let mut last_was_line_ending = false;

    for byte in text.as_bytes() {
        match byte {
            10 => {
                if previous_was_carriage_return {
                    previous_was_carriage_return = false;
                } else {
                    count += 1;
                }
                last_was_line_ending = true;
            }
            13 => {
                count += 1;
                previous_was_carriage_return = true;
                last_was_line_ending = true;
            }
            _ => {
                previous_was_carriage_return = false;
                last_was_line_ending = false;
            }
        }
    }

    if last_was_line_ending {
        count
    } else {
        count + 1
    }
}

/// Mirrors `TokenCalculationService.extractFolderPath(from:)`:
/// `relativePath.split(separator: "/")` (Swift's default `omittingEmptySubsequences: true`,
/// i.e. leading/doubled/trailing `/` never produce empty components), then `count > 1 ?
/// dropLast().joined(separator: "/") : ""`.
///
/// Rust's `str::split('/')` does NOT omit empty subsequences by default, so a naive port
/// (`relative_path.split('/')`) diverges on exactly these inputs: `"/a/b.txt"` (leading `/`),
/// `"a//b/c.txt"` (doubled `/`), `"a/b/"` (trailing `/`). Filtering empty components first
/// restores parity.
#[must_use]
pub fn extract_folder_path(relative_path: &str) -> String {
    let components: Vec<&str> = relative_path
        .split('/')
        .filter(|part| !part.is_empty())
        .collect();
    if components.len() > 1 {
        components[..components.len() - 1].join("/")
    } else {
        String::new()
    }
}

/// Mirrors `TokenInfo.init`'s `formatted = String(format: "%.2fk", Double(count) / 1000.0)`.
#[must_use]
pub fn format_token_count(count: u64) -> String {
    format!("{:.2}k", count as f64 / 1000.0)
}

/// Mirrors `TokenInfo.init`'s `percentage = totalTokens > 0 ? Double(count) / Double(totalTokens)
/// : 0`.
#[must_use]
pub fn percentage(count: u64, total_tokens: u64) -> f64 {
    if total_tokens > 0 {
        count as f64 / total_tokens as f64
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn estimate_tokens_from_byte_count_matches_canonical_arithmetic() {
        let cases = [
            (0u64, 0u64),
            (1, 0),
            (3, 0),
            (4, 1),
            (5, 1),
            (127, 33),
            (1024, 268),
            (10_000, 2625),
        ];
        for (bytes, expected) in cases {
            assert_eq!(
                estimate_tokens_from_byte_count(bytes),
                expected,
                "byte_count={bytes}"
            );
            assert_eq!(
                estimate_tokens_from_byte_count(bytes),
                ((bytes as f64 / 4.0) * 1.05) as u64
            );
        }
    }

    #[test]
    fn estimate_tokens_uses_utf8_byte_length_not_char_count() {
        assert_eq!(estimate_tokens(""), 0);
        // "é" is 1 Swift Character / 1 Unicode scalar but 2 UTF-8 bytes.
        assert_eq!(estimate_tokens("é"), estimate_tokens_from_byte_count(2));
        // A multi-scalar grapheme cluster (family emoji, ZWJ sequence): 4 codepoints, 25 bytes.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
        assert_eq!(family.len(), 25);
        assert_eq!(estimate_tokens(family), estimate_tokens_from_byte_count(25));
    }

    #[test]
    fn count_lines_matches_swift_line_counter_semantics() {
        let cases: &[(&str, u64)] = &[
            ("", 0),
            ("a", 1),
            ("a\n", 1),
            ("a\nb", 2),
            ("a\nb\n", 2),
            ("\n", 1),
            ("\r", 1),
            ("\r\n", 1),
            ("\n\r", 2),
            ("\r\r", 2),
            ("\r\r\n", 2),
            ("a\r\nb\r\nc", 3),
            ("a\r\nb\r\n", 2),
            ("   ", 1),
        ];
        for (text, expected) in cases {
            assert_eq!(count_lines(text), *expected, "text={text:?}");
        }
    }

    #[test]
    fn extract_folder_path_omits_empty_components_like_swift_split() {
        let cases: &[(&str, &str)] = &[
            ("a.txt", ""),
            ("dir/a.txt", "dir"),
            ("dir/sub/a.txt", "dir/sub"),
            ("/a/b.txt", "a"),
            ("a//b/c.txt", "a/b"),
            ("a/b/", "a"),
            ("", ""),
            ("/", ""),
        ];
        for (path, expected) in cases {
            assert_eq!(extract_folder_path(path), *expected, "path={path:?}");
        }
    }

    #[test]
    fn format_token_count_and_percentage_basic_cases() {
        assert_eq!(format_token_count(0), "0.00k");
        assert_eq!(format_token_count(1000), "1.00k");
        assert_eq!(format_token_count(1500), "1.50k");
        assert_eq!(percentage(0, 0), 0.0);
        assert_eq!(percentage(50, 0), 0.0);
        assert_eq!(percentage(50, 100), 0.5);
    }
}
