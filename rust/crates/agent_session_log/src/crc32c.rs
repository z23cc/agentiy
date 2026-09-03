//! CRC-32C (Castagnoli, reflected polynomial `0x82F63B78`) over record payloads.
//!
//! Hand-rolled (table-driven, table built at compile time) rather than pulled in as a dependency:
//! the format is frozen, the algorithm is 20 lines, and every byte of this crate's dependency
//! surface is an ADR-0007 supply-chain decision.

const POLYNOMIAL: u32 = 0x82F6_3B78;

const fn build_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut index = 0usize;
    while index < 256 {
        // `index < 256` keeps this cast lossless; `as` is the only conversion usable in `const fn`.
        #[allow(clippy::cast_possible_truncation)]
        let mut crc = index as u32;
        let mut bit = 0;
        while bit < 8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ POLYNOMIAL
            } else {
                crc >> 1
            };
            bit += 1;
        }
        table[index] = crc;
        index += 1;
    }
    table
}

static TABLE: [u32; 256] = build_table();

/// CRC-32C of `bytes` (initial value and final XOR both `0xFFFF_FFFF`).
#[must_use]
pub fn crc32c(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &byte in bytes {
        crc = TABLE[((crc ^ u32::from(byte)) & 0xFF) as usize] ^ (crc >> 8);
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::crc32c;

    #[test]
    fn matches_the_standard_check_value() {
        assert_eq!(crc32c(b"123456789"), 0xE306_9283);
    }

    #[test]
    fn matches_the_rfc_3720_zero_vector() {
        assert_eq!(crc32c(&[0u8; 32]), 0x8A91_36AA);
    }

    #[test]
    fn empty_input_is_zero() {
        assert_eq!(crc32c(&[]), 0);
    }
}
