use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub const ABI_EPOCH: u32 = 1;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct RuntimeIdentity {
    abi_epoch: u32,
    instance_nonce: String,
    build_fingerprint: String,
    binding_checksum: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum IdentityError {
    IncompatibleAbi { actual: u32 },
    InvalidInstanceNonce,
    InvalidBuildFingerprint,
    InvalidBindingChecksum,
}

impl fmt::Display for IdentityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::IncompatibleAbi { actual } => write!(formatter, "unsupported ABI epoch {actual}"),
            Self::InvalidInstanceNonce => {
                formatter.write_str("instance nonce must be 32 lowercase hexadecimal characters")
            }
            Self::InvalidBuildFingerprint => {
                formatter.write_str("build fingerprint must be 64 lowercase hexadecimal characters")
            }
            Self::InvalidBindingChecksum => {
                formatter.write_str("binding checksum must be 64 lowercase hexadecimal characters")
            }
        }
    }
}

impl std::error::Error for IdentityError {}

impl RuntimeIdentity {
    pub fn new(
        abi_epoch: u32,
        instance_nonce: impl Into<String>,
        build_fingerprint: impl Into<String>,
        binding_checksum: impl Into<String>,
    ) -> Result<Self, IdentityError> {
        if abi_epoch != ABI_EPOCH {
            return Err(IdentityError::IncompatibleAbi { actual: abi_epoch });
        }
        let instance_nonce = instance_nonce.into();
        let build_fingerprint = build_fingerprint.into();
        let binding_checksum = binding_checksum.into();
        if !is_lower_hex(&instance_nonce, 32) {
            return Err(IdentityError::InvalidInstanceNonce);
        }
        if !is_lower_hex(&build_fingerprint, 64) {
            return Err(IdentityError::InvalidBuildFingerprint);
        }
        if !is_lower_hex(&binding_checksum, 64) {
            return Err(IdentityError::InvalidBindingChecksum);
        }
        Ok(Self {
            abi_epoch,
            instance_nonce,
            build_fingerprint,
            binding_checksum,
        })
    }

    pub fn fresh(build_fingerprint: &str, binding_checksum: &str) -> Result<Self, IdentityError> {
        static NEXT_NONCE: AtomicU64 = AtomicU64::new(1);
        let counter = NEXT_NONCE.fetch_add(1, Ordering::Relaxed) as u128;
        let elapsed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let process = u128::from(std::process::id());
        let nonce = elapsed ^ (counter.rotate_left(37)) ^ (process << 64);
        Self::new(
            ABI_EPOCH,
            format!("{nonce:032x}"),
            build_fingerprint,
            binding_checksum,
        )
    }

    pub const fn abi_epoch(&self) -> u32 {
        self.abi_epoch
    }
    pub fn instance_nonce(&self) -> &str {
        &self.instance_nonce
    }
    pub fn build_fingerprint(&self) -> &str {
        &self.build_fingerprint
    }
    pub fn binding_checksum(&self) -> &str {
        &self.binding_checksum
    }
}

pub(crate) fn is_lower_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
