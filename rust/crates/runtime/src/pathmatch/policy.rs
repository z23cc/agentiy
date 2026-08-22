//! Port of the LOCALE-INDEPENDENT parts of
//! `Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathCharPolicy.swift`.
//!
//! Scope boundary (documented per the P3-3 slice-1 task): `PathCharPolicy.swift` also performs
//! NFC canonicalization (`String.precomposedStringWithCanonicalMapping`) and a
//! `CharacterSet.alphanumerics` category test in `cleaned()`'s non-ASCII slow path. Both of those
//! are ICU/Foundation Unicode-database lookups with no Rust std equivalent in scope for this
//! slice (adding a normalization crate is out of scope; see the top-level module doc in
//! `super::score` for the full boundary rationale). This module ports only the fixed,
//! locale-independent codepoint table: the ASCII allow-list/lowering, the zero-width/format drop
//! set, and the homoglyph/dash/slash/space fold table (`emit_folded`). It exists so that table has
//! its own Rust-side unit tests proving parity with the Swift table, and so `score.rs` can reuse
//! the (harmless, idempotent) ASCII-lowering step -- it is NOT used to re-clean production wire
//! input. Production callers of the P3-3 scoring kernel (once wired) are expected to run the real
//! `PathCharPolicy`/`PathMatcher.cleaned()` in Swift before crossing the wire, exactly as
//! `PathMatcher.computeWeightedMatchScorePrecleaned` does internally today.

/// Mirrors `PathCharPolicy.isAllowedASCIIByte`.
#[inline]
#[must_use]
pub fn is_allowed_ascii_byte(b: u8) -> bool {
    matches!(
        b,
        0x30..=0x39 // 0-9
            | 0x41..=0x5A // A-Z
            | 0x61..=0x7A // a-z
            | 0x2E // .
            | 0x5F // _
            | 0x2D // -
            | 0x5B | 0x5D // [ ]
            | 0x28 | 0x29 // ( )
            | 0x7B | 0x7D // { }
            | 0x2B // +
            | 0x21 // !
            | 0x23 // #
            | 0x25 // %
            | 0x40 // @
            | 0x2F // /
    )
}

/// Mirrors `PathCharPolicy.toLowerASCII`.
#[inline]
#[must_use]
pub fn to_lower_ascii(b: u8) -> u8 {
    if (0x41..=0x5A).contains(&b) { b + 0x20 } else { b }
}

/// Mirrors `PathCharPolicy.toLowerASCII` applied to a `char` (used by `score.rs`'s harmless,
/// idempotent ASCII-lowering pass over already Swift-lowered input -- see module doc).
#[inline]
#[must_use]
pub fn to_lower_ascii_char(c: char) -> char {
    if c.is_ascii_uppercase() {
        c.to_ascii_lowercase()
    } else {
        c
    }
}

/// Mirrors `PathCharPolicy.isZeroWidthOrFormat`.
#[inline]
#[must_use]
pub fn is_zero_width_or_format(scalar: u32) -> bool {
    matches!(
        scalar,
        0x200B // ZERO WIDTH SPACE
            | 0x200C // ZERO WIDTH NON-JOINER
            | 0x200D // ZERO WIDTH JOINER
            | 0x2060 // WORD JOINER
            | 0xFEFF // ZERO WIDTH NO-BREAK SPACE (BOM)
            | 0x200E // LRM
            | 0x200F // RLM
    )
}

/// Mirrors `PathCharPolicy.emitFolded`: emits the folded ASCII scalar(s) for one input scalar
/// (supports 1-to-N mappings), or the original scalar unchanged if no folding applies.
#[must_use]
pub fn emit_folded(scalar: u32) -> EmitFolded {
    // Multi-length first (so we don't fall through).
    match scalar {
        0x2E3B => return EmitFolded::Three('-', '-', '-'), // ⸻ THREE-EM DASH
        0x2E3A => return EmitFolded::Two('-', '-'),        // ⸺ TWO-EM DASH
        _ => {}
    }

    let single = match scalar {
        // Dashes / hyphens -> '-'
        0x2010 | 0x2011 | 0x2012 | 0x2013 | 0x2014 | 0x2015 | 0x2043 | 0x2212 | 0xFE63 | 0xFF0D => {
            Some('-')
        }
        // Slashes -> '/'
        0x2044 | 0x2215 | 0xFF0F => Some('/'),
        // Fullwidth punctuation
        0xFF3F => Some('_'),
        0xFF0E => Some('.'),
        0xFF3B => Some('['),
        0xFF3D => Some(']'),
        0xFF08 => Some('('),
        0xFF09 => Some(')'),
        0xFF5B => Some('{'),
        0xFF5D => Some('}'),
        0xFF0B => Some('+'),
        0xFF01 => Some('!'),
        0xFF03 => Some('#'),
        0xFF05 => Some('%'),
        0xFF20 => Some('@'),
        // Spaces & space-like -> ASCII space
        0x00A0 | 0x1680 | 0x202F | 0x205F | 0x3000 => Some(' '),
        v if (0x2000..=0x200A).contains(&v) => Some(' '),
        // Fullwidth ASCII digits/letters -> ASCII
        v if (0xFF10..=0xFF19).contains(&v) => char::from_u32(0x30 + (v - 0xFF10)),
        v if (0xFF21..=0xFF3A).contains(&v) => char::from_u32(0x41 + (v - 0xFF21)),
        v if (0xFF41..=0xFF5A).contains(&v) => char::from_u32(0x61 + (v - 0xFF41)),
        _ => None,
    };

    match single {
        Some(c) => EmitFolded::One(c),
        None => match char::from_u32(scalar) {
            Some(c) => EmitFolded::One(c),
            None => EmitFolded::None,
        },
    }
}

/// Result of `emit_folded`: zero, one, two, or three output scalars.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EmitFolded {
    None,
    One(char),
    Two(char, char),
    Three(char, char, char),
}

impl EmitFolded {
    #[must_use]
    pub fn into_vec(self) -> Vec<char> {
        match self {
            EmitFolded::None => Vec::new(),
            EmitFolded::One(a) => vec![a],
            EmitFolded::Two(a, b) => vec![a, b],
            EmitFolded::Three(a, b, c) => vec![a, b, c],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowed_ascii_byte_matches_swift_table() {
        for b in b'0'..=b'9' {
            assert!(is_allowed_ascii_byte(b));
        }
        for b in b'A'..=b'Z' {
            assert!(is_allowed_ascii_byte(b));
        }
        for b in b'a'..=b'z' {
            assert!(is_allowed_ascii_byte(b));
        }
        for &b in b".-_[](){}+!#%@/" {
            assert!(is_allowed_ascii_byte(b), "byte {b:#x} should be allowed");
        }
        for &b in b" ,;:'\"\\^~*=<>?|&" {
            assert!(!is_allowed_ascii_byte(b), "byte {b:#x} should not be allowed");
        }
    }

    #[test]
    fn to_lower_ascii_only_touches_uppercase_ascii() {
        assert_eq!(to_lower_ascii(b'A'), b'a');
        assert_eq!(to_lower_ascii(b'Z'), b'z');
        assert_eq!(to_lower_ascii(b'a'), b'a');
        assert_eq!(to_lower_ascii(b'0'), b'0');
        assert_eq!(to_lower_ascii(b'-'), b'-');
    }

    #[test]
    fn zero_width_and_format_scalars_are_flagged() {
        for scalar in [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x200E, 0x200F] {
            assert!(is_zero_width_or_format(scalar));
        }
        assert!(!is_zero_width_or_format('a' as u32));
    }

    #[test]
    fn em_dash_variants_fold_to_ascii_hyphen() {
        assert_eq!(emit_folded(0x2013).into_vec(), vec!['-']); // en dash
        assert_eq!(emit_folded(0x2014).into_vec(), vec!['-']); // em dash
        assert_eq!(emit_folded(0xFF0D).into_vec(), vec!['-']); // fullwidth hyphen-minus
    }

    #[test]
    fn two_and_three_em_dash_expand_to_multiple_hyphens() {
        assert_eq!(emit_folded(0x2E3A).into_vec(), vec!['-', '-']);
        assert_eq!(emit_folded(0x2E3B).into_vec(), vec!['-', '-', '-']);
    }

    #[test]
    fn fullwidth_digits_and_letters_fold_to_ascii() {
        assert_eq!(emit_folded(0xFF10).into_vec(), vec!['0']);
        assert_eq!(emit_folded(0xFF19).into_vec(), vec!['9']);
        assert_eq!(emit_folded(0xFF21).into_vec(), vec!['A']);
        assert_eq!(emit_folded(0xFF3A).into_vec(), vec!['Z']);
        assert_eq!(emit_folded(0xFF41).into_vec(), vec!['a']);
        assert_eq!(emit_folded(0xFF5A).into_vec(), vec!['z']);
    }

    #[test]
    fn space_like_scalars_fold_to_ascii_space() {
        for scalar in [0x00A0, 0x1680, 0x2000, 0x200A, 0x202F, 0x205F, 0x3000] {
            assert_eq!(emit_folded(scalar).into_vec(), vec![' ']);
        }
    }

    #[test]
    fn unmapped_scalar_passes_through_unchanged() {
        assert_eq!(emit_folded('文' as u32).into_vec(), vec!['文']);
    }
}
