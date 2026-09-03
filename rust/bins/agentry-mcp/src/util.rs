//! Random ids and generation bytes. No extra crate: `/dev/urandom` is enough.

use std::fs::File;
use std::io::Read;

#[must_use]
pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    if let Ok(mut file) = File::open("/dev/urandom") {
        let _ = file.read_exact(&mut bytes);
    }
    bytes
}

#[must_use]
pub fn uuid_v4() -> String {
    let mut bytes = random_bytes::<16>();
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    format_uuid(&bytes)
}

#[must_use]
pub fn format_uuid(bytes: &[u8; 16]) -> String {
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
}

#[must_use]
pub fn mint_generation(host_nonce: &[u8; 16], attempt: u64) -> Vec<u8> {
    let mut generation = Vec::with_capacity(24);
    generation.extend_from_slice(host_nonce);
    generation.extend_from_slice(&attempt.to_be_bytes());
    generation
}

#[must_use]
pub fn hex_digest(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(out, "{byte:02x}");
    }
    out
}
