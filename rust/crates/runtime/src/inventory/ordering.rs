//! Byte-exact port of
//! `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Inventory/WorkspaceInventoryOrdering.swift`.
//!
//! DO NOT change comparison semantics or sort order here for the same reason the Swift source
//! documents: this is catalog-shard ordering, not presentation-layer natural sort.

use super::builders::{InventoryFileRecord, InventoryFolderRecord, InventorySearchCatalogEntry};
use std::cmp::Ordering;

/// Byte-for-byte UTF-8 ordering, independent of locale/Unicode canonicalization. Equivalent to
/// Swift's `compareUTF8Binary`: Rust's `[u8]::cmp` is already lexicographic-then-length ordering,
/// which is exactly what the Swift iterator-pair loop computes.
pub fn compare_utf8_binary(lhs: &str, rhs: &str) -> Ordering {
    lhs.as_bytes().cmp(rhs.as_bytes())
}

fn path_id_order(lhs_path: &str, lhs_id: &[u8; 16], rhs_path: &str, rhs_id: &[u8; 16]) -> Ordering {
    match compare_utf8_binary(lhs_path, rhs_path) {
        Ordering::Equal => lhs_id.cmp(rhs_id),
        other => other,
    }
}

/// Multi-root file ordering, keyed on each file's standardized full (root-qualified) path.
pub fn file_full_path_order(lhs: &InventoryFileRecord, rhs: &InventoryFileRecord) -> Ordering {
    path_id_order(
        &lhs.standardized_full_path,
        &lhs.id,
        &rhs.standardized_full_path,
        &rhs.id,
    )
}

pub fn search_catalog_file_precedes(lhs: &InventoryFileRecord, rhs: &InventoryFileRecord) -> bool {
    file_full_path_order(lhs, rhs) == Ordering::Less
}

/// Single-root file ordering, keyed on each file's standardized root-relative path.
pub fn file_relative_path_order(lhs: &InventoryFileRecord, rhs: &InventoryFileRecord) -> Ordering {
    path_id_order(
        &lhs.standardized_relative_path,
        &lhs.id,
        &rhs.standardized_relative_path,
        &rhs.id,
    )
}

pub fn search_root_catalog_file_precedes(
    lhs: &InventoryFileRecord,
    rhs: &InventoryFileRecord,
) -> bool {
    file_relative_path_order(lhs, rhs) == Ordering::Less
}

/// Search catalog entry ordering, keyed on each entry's standardized full (root-qualified) path.
pub fn entry_order(
    lhs: &InventorySearchCatalogEntry,
    rhs: &InventorySearchCatalogEntry,
) -> Ordering {
    path_id_order(
        &lhs.standardized_full_path,
        &lhs.id,
        &rhs.standardized_full_path,
        &rhs.id,
    )
}

pub fn search_catalog_entry_precedes(
    lhs: &InventorySearchCatalogEntry,
    rhs: &InventorySearchCatalogEntry,
) -> bool {
    entry_order(lhs, rhs) == Ordering::Less
}

/// Folder ordering.
///
/// SCOPE NOTE (P3-2): the Swift comparator (`WorkspaceInventoryOrdering.searchCatalogFolderPrecedes`)
/// deliberately uses Swift's native `String` `==`/`<`, i.e. Unicode *canonical-equivalence*
/// ordering (NFC-normalized comparison), NOT `compareUTF8Binary`. That is preserved verbatim on
/// the Swift side and is explicitly out of scope to "fix" here (see the Swift source's own
/// comment). Byte order agrees with Swift's canonical order for any pair of strings that does not
/// require canonical-combining-class reordering to compare — which covers CJK, emoji, and
/// precomposed/NFC Latin text, i.e. any realistic single-encoding filesystem path. It diverges
/// only when two *different* folder records spell the same logical name with two different
/// Unicode encodings (precomposed vs. decomposed), or when a name contains multiple combining
/// marks in non-canonical order. Porting actual NFC canonical ordering to Rust is a real
/// Unicode-normalization dependency and is out of scope for this byte-exact extraction; pinned
/// as a demonstrated fact (not a hand-simulated byte comparison) by
/// `tests::folder_order_diverges_from_swift_unicode_canonical_equivalence`. See
/// `docs/investigations` P3-2 report for the verification probe.
pub fn folder_order(lhs: &InventoryFolderRecord, rhs: &InventoryFolderRecord) -> Ordering {
    path_id_order(
        &lhs.standardized_full_path,
        &lhs.id,
        &rhs.standardized_full_path,
        &rhs.id,
    )
}

pub fn search_catalog_folder_precedes(
    lhs: &InventoryFolderRecord,
    rhs: &InventoryFolderRecord,
) -> bool {
    folder_order(lhs, rhs) == Ordering::Less
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uuid(byte: u8) -> [u8; 16] {
        let mut bytes = [0u8; 16];
        bytes[15] = byte;
        bytes
    }

    fn file(id: [u8; 16], full: &str, rel: &str) -> InventoryFileRecord {
        InventoryFileRecord {
            id,
            root_id: [0; 16],
            name: full.to_owned(),
            relative_path: rel.to_owned(),
            standardized_relative_path: rel.to_owned(),
            full_path: full.to_owned(),
            standardized_full_path: full.to_owned(),
            parent_folder_id: None,
            modification_date: None,
        }
    }

    fn folder(id: [u8; 16], full: &str) -> InventoryFolderRecord {
        InventoryFolderRecord {
            id,
            root_id: [0; 16],
            name: full.to_owned(),
            relative_path: full.to_owned(),
            standardized_relative_path: full.to_owned(),
            full_path: full.to_owned(),
            standardized_full_path: full.to_owned(),
            parent_folder_id: None,
            modification_date: None,
        }
    }

    #[test]
    fn compare_utf8_binary_matches_lexicographic_bytes() {
        assert_eq!(compare_utf8_binary("a", "b"), Ordering::Less);
        assert_eq!(compare_utf8_binary("ab", "a"), Ordering::Greater);
        assert_eq!(compare_utf8_binary("a", "a"), Ordering::Equal);
        // Prefix ordering: shorter string that is a strict prefix sorts first, matching the
        // Swift iterator loop's `(nil, _?) -> .orderedAscending` case.
        assert_eq!(compare_utf8_binary("ab", "abc"), Ordering::Less);
    }

    /// Pins the claim that raw 16-byte UUID comparison agrees with canonical lowercase
    /// hyphenated `uuidString` comparison (`compareUTF8Binary` on the string form), which is
    /// what Swift's tiebreak actually compares.
    #[test]
    fn uuid_byte_order_matches_canonical_string_order() {
        fn canonical_string(bytes: &[u8; 16]) -> String {
            let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
            format!(
                "{}-{}-{}-{}-{}",
                &hex[0..8],
                &hex[8..12],
                &hex[12..16],
                &hex[16..20],
                &hex[20..32]
            )
        }
        let samples: [[u8; 16]; 6] = [
            [0; 16],
            [0xff; 16],
            uuid(0x01),
            uuid(0x10),
            {
                let mut b = [0u8; 16];
                b[0] = 0x1f;
                b
            },
            {
                let mut b = [0u8; 16];
                b[0] = 0x20;
                b
            },
        ];
        for lhs in &samples {
            for rhs in &samples {
                let byte_order = lhs.cmp(rhs);
                let string_order =
                    compare_utf8_binary(&canonical_string(lhs), &canonical_string(rhs));
                assert_eq!(
                    byte_order, string_order,
                    "byte order for {lhs:?} vs {rhs:?} should match canonical uuid string order"
                );
            }
        }
    }

    #[test]
    fn file_full_path_order_breaks_ties_on_id() {
        let a = file(uuid(1), "/root/a.swift", "a.swift");
        let b = file(uuid(2), "/root/a.swift", "a.swift");
        assert_eq!(file_full_path_order(&a, &b), Ordering::Less);
        assert!(search_catalog_file_precedes(&a, &b));
        assert!(!search_catalog_file_precedes(&b, &a));
    }

    #[test]
    fn file_relative_path_order_uses_relative_path() {
        let a = file(uuid(9), "/root/z.swift", "a.swift");
        let b = file(uuid(1), "/root/a.swift", "z.swift");
        // Full-path order would put `b` first (`/root/a.swift` < `/root/z.swift`); relative-path
        // order must put `a` first instead (`a.swift` < `z.swift`).
        assert_eq!(file_relative_path_order(&a, &b), Ordering::Less);
        assert_eq!(file_full_path_order(&a, &b), Ordering::Greater);
    }

    /// Pins `folder_order`'s documented scope boundary as a demonstrated fact through the real
    /// comparator, not a hand-simulated byte comparison: "cafe\u{0301}" (NFD: e + combining acute
    /// accent) and "caf\u{00e9}" (NFC: precomposed e-acute) are Unicode-canonically equal --
    /// Swift's native `String` `==`/`<` treats them as equal -- but byte-different, so raw UTF-8
    /// byte comparison orders them by their differing bytes. Chosen so the UUID tiebreak a
    /// canonical-equivalence comparator would fall through to (`low_id` < `high_id`) picks the
    /// OPPOSITE order from raw-byte comparison (NFD's bytes sort first), making the divergence
    /// visible rather than accidental. Formerly pinned only by the now-retired
    /// `InventoryRustSwiftDifferentialTests.testFolderComparatorByteOrderVersusCanonicalDivergenceIsDocumented`
    /// (P4-8: `inventory-compute-v1` retirement) -- this is its Rust-side replacement, covering
    /// the same `folder_order` this crate's inventory-scope-v1 path still calls verbatim.
    #[test]
    fn folder_order_diverges_from_swift_unicode_canonical_equivalence() {
        let precomposed = "caf\u{00e9}";
        let decomposed = "cafe\u{0301}";
        assert_ne!(
            precomposed.as_bytes(),
            decomposed.as_bytes(),
            "fixture must be byte-different"
        );

        let low_id = uuid(0x01);
        let high_id = uuid(0xfe);
        let folder_precomposed = folder(low_id, precomposed);
        let folder_decomposed = folder(high_id, decomposed);

        // Raw UTF-8 byte order: the NFD encoding's bytes ('e' = 0x65) sort before the NFC
        // encoding's bytes (precomposed e-acute = 0xC3 0xA9), so the decomposed folder sorts
        // first -- the opposite of what a canonical-equivalence comparator's id tiebreak
        // (low_id < high_id) would produce.
        assert_eq!(
            folder_order(&folder_decomposed, &folder_precomposed),
            Ordering::Less
        );
        assert_eq!(
            folder_order(&folder_precomposed, &folder_decomposed),
            Ordering::Greater
        );
        assert!(search_catalog_folder_precedes(
            &folder_decomposed,
            &folder_precomposed
        ));
    }
}
