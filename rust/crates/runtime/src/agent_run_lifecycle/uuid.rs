//! 16-byte identity used for every UUID the reducers fence on (tab, session, attempt, commit,
//! token, process run). Rendered in the canonical lowercase hyphenated form; parsed from either
//! case. The reducers never mint one -- identities are always inputs.

use std::fmt;

/// A UUID as raw bytes. Ordering is bytewise so canonical serialization is stable.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct RunUuid([u8; 16]);

/// The text was not `8-4-4-4-12` hexadecimal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunUuidParseError {
    pub value: String,
}

impl fmt::Display for RunUuidParseError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "invalid UUID text {:?}", self.value)
    }
}

impl std::error::Error for RunUuidParseError {}

impl RunUuid {
    #[must_use]
    pub const fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }

    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }

    /// Parses `8-4-4-4-12` hexadecimal (either case).
    pub fn parse(value: &str) -> Result<Self, RunUuidParseError> {
        let invalid = || RunUuidParseError {
            value: value.to_owned(),
        };
        let bytes = value.as_bytes();
        if bytes.len() != 36 {
            return Err(invalid());
        }
        let mut output = [0u8; 16];
        let mut cursor = 0usize;
        for (index, chunk) in bytes.iter().enumerate() {
            if matches!(index, 8 | 13 | 18 | 23) {
                if *chunk != b'-' {
                    return Err(invalid());
                }
                continue;
            }
            let nibble = match chunk {
                b'0'..=b'9' => chunk - b'0',
                b'a'..=b'f' => chunk - b'a' + 10,
                b'A'..=b'F' => chunk - b'A' + 10,
                _ => return Err(invalid()),
            };
            if cursor % 2 == 0 {
                output[cursor / 2] = nibble << 4;
            } else {
                output[cursor / 2] |= nibble;
            }
            cursor += 1;
        }
        Ok(Self(output))
    }
}

impl fmt::Display for RunUuid {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (index, byte) in self.0.iter().enumerate() {
            if matches!(index, 4 | 6 | 8 | 10) {
                formatter.write_str("-")?;
            }
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

impl fmt::Debug for RunUuid {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "RunUuid({self})")
    }
}

#[cfg(test)]
mod tests {
    use super::RunUuid;

    #[test]
    fn parses_and_renders_canonical_form() {
        let text = "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081";
        let parsed = RunUuid::parse(text).unwrap();
        assert_eq!(parsed.to_string(), text);
        assert_eq!(RunUuid::parse(&text.to_uppercase()).unwrap(), parsed);
    }

    #[test]
    fn rejects_malformed_text() {
        for bad in [
            "",
            "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f708",
            "0193a4b27c3e7f108a2b9c4d5e6f7081",
            "0193a4b2_7c3e-7f10-8a2b-9c4d5e6f7081",
            "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f70zz",
        ] {
            assert!(RunUuid::parse(bad).is_err(), "{bad:?}");
        }
    }
}
