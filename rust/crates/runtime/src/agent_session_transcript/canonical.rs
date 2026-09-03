//! Shared helpers for the transcript reducer's canonical JSON rendering.
//!
//! The object builder itself lives in `agent_run_lifecycle::canonical` so both P6-a and P6-b
//! emit the same escaping. This module only owns byte rendering used by generation fields.

/// Lowercase hex with no separator (matches the Swift differential encoder).
#[must_use]
pub fn hex_bytes(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut rendered = String::with_capacity(bytes.len().saturating_mul(2));
    for byte in bytes {
        rendered.push(HEX[usize::from(byte >> 4)] as char);
        rendered.push(HEX[usize::from(byte & 0x0f)] as char);
    }
    rendered
}

#[cfg(test)]
mod tests {
    use super::hex_bytes;

    #[test]
    fn renders_lowercase_hex_without_separator() {
        assert_eq!(hex_bytes(&[]), "");
        assert_eq!(hex_bytes(&[0x00, 0xab, 0xff]), "00abff");
    }
}
