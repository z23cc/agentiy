use crate::RuntimeIdentity;
use crate::identity::is_lower_hex;
use std::fmt;
use std::time::Instant;

macro_rules! uuid_identifier {
    ($name:ident) => {
        #[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
        pub struct $name(String);

        impl $name {
            pub fn parse(value: impl Into<String>) -> Result<Self, IdentifierError> {
                let value = value.into();
                if is_canonical_uuid(&value) {
                    Ok(Self(value))
                } else {
                    Err(IdentifierError::InvalidUuid)
                }
            }

            pub fn from_u128(value: u128) -> Self {
                let hex = format!("{value:032x}");
                Self(format!(
                    "{}-{}-{}-{}-{}",
                    &hex[0..8],
                    &hex[8..12],
                    &hex[12..16],
                    &hex[16..20],
                    &hex[20..32]
                ))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }
    };
}

uuid_identifier!(OperationId);
uuid_identifier!(ScopeId);

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct RequestFingerprint(String);

impl RequestFingerprint {
    pub fn parse(value: impl Into<String>) -> Result<Self, IdentifierError> {
        let value = value.into();
        if is_lower_hex(&value, 64) {
            Ok(Self(value))
        } else {
            Err(IdentifierError::InvalidFingerprint)
        }
    }

    pub fn repeated(nibble: char) -> Self {
        assert!(matches!(nibble, '0'..='9' | 'a'..='f'));
        Self(std::iter::repeat_n(nibble, 64).collect())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IdentifierError {
    InvalidUuid,
    InvalidFingerprint,
}

impl fmt::Display for IdentifierError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidUuid => {
                formatter.write_str("identifier must be a lowercase canonical UUID")
            }
            Self::InvalidFingerprint => {
                formatter.write_str("fingerprint must be 64 lowercase hexadecimal characters")
            }
        }
    }
}

impl std::error::Error for IdentifierError {}

fn is_canonical_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte),
        })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalOutcome {
    Success,
    Cancelled,
    DeadlineExceeded,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OperationState {
    Admitted,
    Running,
    CancelRequested,
    Terminal(TerminalOutcome),
}

impl OperationState {
    pub const fn is_terminal(self) -> bool {
        matches!(self, Self::Terminal(_))
    }
}

#[derive(Clone, Debug)]
pub struct AdmissionRequest {
    pub operation_id: OperationId,
    pub fingerprint: RequestFingerprint,
    pub scope: ScopeId,
    pub deadline_unix_millis: Option<u64>,
    pub runtime_identity: RuntimeIdentity,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdmissionOutcome {
    Accepted,
    Duplicate(OperationState),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CancelOutcome {
    Requested,
    Tombstoned,
    AlreadyRequested,
    AlreadyTerminal,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct OperationDiagnostics {
    pub duplicate_cancels: u64,
    pub late_terminal_results: u64,
    pub collisions: u64,
    pub expired_tombstones: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OperationSnapshot {
    pub operation_id: OperationId,
    pub fingerprint: RequestFingerprint,
    pub scope: ScopeId,
    pub runtime_identity: RuntimeIdentity,
    pub state: OperationState,
    pub deadline: Option<Instant>,
}
