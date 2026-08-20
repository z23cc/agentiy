use std::fmt;

/// Explicit fail-closed failures produced by the versioned decoder.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DecodeError {
    HeaderTooShort { actual: usize, minimum: usize },
    InvalidMagic,
    UnsupportedSchemaVersion { actual: u16 },
    UnknownPayloadKind { actual: u16 },
    UnsupportedFlags { actual: u32 },
    EnvelopeTooLarge { actual: usize, maximum: usize },
    DeclaredPayloadTooLarge { declared: usize, maximum: usize },
    TruncatedPayload { declared: usize, actual: usize },
    TrailingBytes { declared: usize, actual: usize },
    DecodedSizeExceeded { actual: usize, maximum: usize },
    CollectionTooLarge { actual: usize, maximum: usize },
    StringTooLong { actual: usize, maximum: usize },
    InvalidUtf8,
}

impl fmt::Display for DecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::HeaderTooShort { actual, minimum } => {
                write!(
                    formatter,
                    "envelope header is {actual} bytes; requires {minimum}"
                )
            }
            Self::InvalidMagic => formatter.write_str("invalid envelope magic"),
            Self::UnsupportedSchemaVersion { actual } => {
                write!(formatter, "unsupported envelope schema version {actual}")
            }
            Self::UnknownPayloadKind { actual } => {
                write!(formatter, "unknown payload kind {actual}")
            }
            Self::UnsupportedFlags { actual } => {
                write!(formatter, "unsupported envelope flags {actual:#x}")
            }
            Self::EnvelopeTooLarge { actual, maximum } => {
                write!(
                    formatter,
                    "envelope is {actual} bytes; maximum is {maximum}"
                )
            }
            Self::DeclaredPayloadTooLarge { declared, maximum } => write!(
                formatter,
                "declared payload is {declared} bytes; maximum is {maximum}"
            ),
            Self::TruncatedPayload { declared, actual } => write!(
                formatter,
                "payload declares {declared} bytes but only {actual} remain"
            ),
            Self::TrailingBytes { declared, actual } => write!(
                formatter,
                "payload declares {declared} bytes but {actual} remain"
            ),
            Self::DecodedSizeExceeded { actual, maximum } => write!(
                formatter,
                "decoded value is {actual} bytes; maximum is {maximum}"
            ),
            Self::CollectionTooLarge { actual, maximum } => write!(
                formatter,
                "collection has {actual} items; maximum is {maximum}"
            ),
            Self::StringTooLong { actual, maximum } => {
                write!(formatter, "string is {actual} bytes; maximum is {maximum}")
            }
            Self::InvalidUtf8 => formatter.write_str("string is not valid UTF-8"),
        }
    }
}

impl std::error::Error for DecodeError {}
