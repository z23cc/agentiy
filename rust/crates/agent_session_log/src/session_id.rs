//! 16-byte session identity stored in every file header.

use crate::error::LogError;
use std::fmt;

/// A session UUID as raw bytes. Parsed from / rendered as the canonical lowercase hyphenated form.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct SessionId([u8; 16]);

impl SessionId {
    #[must_use]
    pub const fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }

    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }

    /// Parses `8-4-4-4-12` hexadecimal (either case). Anything else is `InvalidSessionId`.
    pub fn parse(value: &str) -> Result<Self, LogError> {
        let invalid = || LogError::InvalidSessionId {
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

impl fmt::Display for SessionId {
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

impl fmt::Debug for SessionId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "SessionId({self})")
    }
}

#[cfg(test)]
mod tests {
    use super::SessionId;

    #[test]
    fn parses_and_renders_canonical_form() {
        let text = "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081";
        let id = SessionId::parse(text).unwrap();
        assert_eq!(id.to_string(), text);
        assert_eq!(
            SessionId::parse(&text.to_uppercase()).unwrap().to_string(),
            text
        );
    }

    #[test]
    fn rejects_malformed_values() {
        for value in [
            "",
            "0193a4b2",
            "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f708",
            "0193a4b2_7c3e_7f10_8a2b_9c4d5e6f7081",
            "zz93a4b2-7c3e-7f10-8a2b-9c4d5e6f7081",
        ] {
            assert!(SessionId::parse(value).is_err(), "{value:?}");
        }
    }
}
