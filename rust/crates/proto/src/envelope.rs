use crate::DecodeError;

pub const MAGIC: [u8; 4] = *b"AGRY";
pub const HEADER_BYTES: usize = 16;
pub const MAXIMUM_ENVELOPE_BYTES: usize = 1_048_576;
pub const MAXIMUM_PAYLOAD_BYTES: usize = MAXIMUM_ENVELOPE_BYTES - HEADER_BYTES;
pub const DEFAULT_MAXIMUM_COLLECTION_ITEMS: usize = 65_536;
pub const DEFAULT_MAXIMUM_STRING_BYTES: usize = 262_144;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum PayloadKind {
    Control = 1,
    Data = 2,
    HostRequest = 3,
    HostResponse = 4,
}

impl TryFrom<u16> for PayloadKind {
    type Error = DecodeError;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Control),
            2 => Ok(Self::Data),
            3 => Ok(Self::HostRequest),
            4 => Ok(Self::HostResponse),
            actual => Err(DecodeError::UnknownPayloadKind { actual }),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DecodeLimits {
    pub maximum_envelope_bytes: usize,
    pub maximum_decoded_bytes: usize,
    pub maximum_collection_items: usize,
    pub maximum_string_bytes: usize,
}

impl Default for DecodeLimits {
    fn default() -> Self {
        Self {
            maximum_envelope_bytes: MAXIMUM_ENVELOPE_BYTES,
            maximum_decoded_bytes: MAXIMUM_PAYLOAD_BYTES,
            maximum_collection_items: DEFAULT_MAXIMUM_COLLECTION_ITEMS,
            maximum_string_bytes: DEFAULT_MAXIMUM_STRING_BYTES,
        }
    }
}

impl DecodeLimits {
    pub fn validate_decoded_size(self, actual: usize) -> Result<(), DecodeError> {
        if actual > self.maximum_decoded_bytes {
            return Err(DecodeError::DecodedSizeExceeded {
                actual,
                maximum: self.maximum_decoded_bytes,
            });
        }
        Ok(())
    }

    pub fn validate_collection_len(self, actual: usize) -> Result<(), DecodeError> {
        if actual > self.maximum_collection_items {
            return Err(DecodeError::CollectionTooLarge {
                actual,
                maximum: self.maximum_collection_items,
            });
        }
        Ok(())
    }

    pub fn decode_utf8<'a>(self, bytes: &'a [u8]) -> Result<&'a str, DecodeError> {
        if bytes.len() > self.maximum_string_bytes {
            return Err(DecodeError::StringTooLong {
                actual: bytes.len(),
                maximum: self.maximum_string_bytes,
            });
        }
        std::str::from_utf8(bytes).map_err(|_| DecodeError::InvalidUtf8)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Envelope<'a> {
    pub schema_version: u16,
    pub payload_kind: PayloadKind,
    pub payload: &'a [u8],
}

impl<'a> Envelope<'a> {
    pub fn decode(bytes: &'a [u8]) -> Result<Self, DecodeError> {
        Self::decode_with_limits(bytes, DecodeLimits::default())
    }

    pub fn decode_with_limits(bytes: &'a [u8], limits: DecodeLimits) -> Result<Self, DecodeError> {
        if bytes.len() > limits.maximum_envelope_bytes {
            return Err(DecodeError::EnvelopeTooLarge {
                actual: bytes.len(),
                maximum: limits.maximum_envelope_bytes,
            });
        }
        if bytes.len() < HEADER_BYTES {
            return Err(DecodeError::HeaderTooShort {
                actual: bytes.len(),
                minimum: HEADER_BYTES,
            });
        }
        if bytes[..4] != MAGIC {
            return Err(DecodeError::InvalidMagic);
        }

        let schema_version = u16::from_be_bytes([bytes[4], bytes[5]]);
        if schema_version != crate::ENVELOPE_SCHEMA_VERSION {
            return Err(DecodeError::UnsupportedSchemaVersion {
                actual: schema_version,
            });
        }
        let payload_kind = PayloadKind::try_from(u16::from_be_bytes([bytes[6], bytes[7]]))?;
        let flags = u32::from_be_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]);
        if flags != 0 {
            return Err(DecodeError::UnsupportedFlags { actual: flags });
        }

        let declared = u32::from_be_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]) as usize;
        let maximum_payload = limits.maximum_envelope_bytes.saturating_sub(HEADER_BYTES);
        if declared > maximum_payload {
            return Err(DecodeError::DeclaredPayloadTooLarge {
                declared,
                maximum: maximum_payload,
            });
        }
        limits.validate_decoded_size(declared)?;

        let actual = bytes.len() - HEADER_BYTES;
        if actual < declared {
            return Err(DecodeError::TruncatedPayload { declared, actual });
        }
        if actual > declared {
            return Err(DecodeError::TrailingBytes { declared, actual });
        }

        Ok(Self {
            schema_version,
            payload_kind,
            payload: &bytes[HEADER_BYTES..],
        })
    }

    pub fn encode(payload_kind: PayloadKind, payload: &[u8]) -> Result<Vec<u8>, DecodeError> {
        let limits = DecodeLimits::default();
        limits.validate_decoded_size(payload.len())?;
        let total =
            HEADER_BYTES
                .checked_add(payload.len())
                .ok_or(DecodeError::EnvelopeTooLarge {
                    actual: usize::MAX,
                    maximum: limits.maximum_envelope_bytes,
                })?;
        if total > limits.maximum_envelope_bytes {
            return Err(DecodeError::EnvelopeTooLarge {
                actual: total,
                maximum: limits.maximum_envelope_bytes,
            });
        }

        let payload_length =
            u32::try_from(payload.len()).map_err(|_| DecodeError::DeclaredPayloadTooLarge {
                declared: payload.len(),
                maximum: u32::MAX as usize,
            })?;
        let mut encoded = Vec::with_capacity(total);
        encoded.extend_from_slice(&MAGIC);
        encoded.extend_from_slice(&crate::ENVELOPE_SCHEMA_VERSION.to_be_bytes());
        encoded.extend_from_slice(&(payload_kind as u16).to_be_bytes());
        encoded.extend_from_slice(&0_u32.to_be_bytes());
        encoded.extend_from_slice(&payload_length.to_be_bytes());
        encoded.extend_from_slice(payload);
        Ok(encoded)
    }
}
