//! Explicit typed identifiers for the P4-3a stateful inventory scope.
//!
//! Per `docs/architecture/rust-inventory-scope-v1.md` §1: handles are explicit IDs, not proxy
//! objects. `RootId` reuses the raw 16-byte UUID representation `inventory::builders::InventoryUuid`
//! already used by `InventoryFileRecord`/`InventoryFolderRecord`/`InventoryRootRecord` so a caller's
//! root identity round-trips byte-for-byte through this scope with no re-encoding.
//!
//! `InventoryScopeId` and `RootLifetimeId` are minted by the scope itself (never supplied by a
//! caller) via `UuidMinter`, which supports both process-entropy minting (`fresh`, mirroring
//! `RuntimeIdentity::fresh`'s nonce shape) and a deterministic seeded mode (`seeded` +
//! `next_bytes`, a splitmix64 stream) for reproducible tests -- the "UUID minting with test seed"
//! requirement named in the P4-3a scope.
//!
//! **Deviation from a literal UUID shape, flagged:** `SnapshotHandleId` and `BulkLoadId` are
//! monotonic per-scope counters rather than minted UUIDs. The contract requires these to be
//! explicit typed IDs (not proxy objects); it does not require them to be UUID-shaped, and
//! `InventoryScopeConfig`/`InventoryRootOpenV1` naming elsewhere in the contract is silent on
//! their representation. A counter scoped to one `Mutex`-guarded scope is simpler, cheaper to
//! hash, and structurally cannot collide within that scope's lifetime. This is the minimal choice
//! the task's process asks for where the contract underspecifies a shape.

use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Reuses the byte-exact UUID representation the P3-2 inventory builders already use, so a
/// `RootId` passed into `InventoryScope::open_root` is the exact same 16 bytes that appear as
/// `InventoryFileRecord.root_id` / `InventoryRootRecord.id` with no re-encoding step.
pub type RootId = crate::inventory::InventoryUuid;

macro_rules! uuid_id {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
        pub struct $name([u8; 16]);

        impl $name {
            #[must_use]
            pub const fn from_bytes(bytes: [u8; 16]) -> Self {
                Self(bytes)
            }

            #[must_use]
            pub const fn as_bytes(&self) -> &[u8; 16] {
                &self.0
            }

            #[must_use]
            pub fn mint(minter: &UuidMinter) -> Self {
                Self(minter.next_bytes())
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                for byte in &self.0 {
                    write!(formatter, "{byte:02x}")?;
                }
                Ok(())
            }
        }
    };
}

uuid_id!(InventoryScopeId);
uuid_id!(RootLifetimeId);

impl InventoryScopeId {
    /// P4-4b: the generic P0 `SubscriptionHub`/FFI subscription surface addresses queues by
    /// `crate::ScopeId` (a canonical dashed-hex UUID string, `operation.rs`'s `uuid_identifier!`),
    /// not by this module's own hyphen-less `uuid_id!` string shape -- the two macros produce
    /// incompatible `Display` formats. This is the one, single-sourced conversion between them:
    /// reinterpret this id's 16 bytes as a `u128` and format it through `ScopeId::from_u128`,
    /// which reuses the exact canonical-hex-with-dashes formatting `ScopeId::parse`'s
    /// `is_canonical_uuid` check accepts (format-only: no UUID version/variant nibble
    /// requirement -- verified by `to_subscription_scope_id_round_trips_through_scope_id_parse`
    /// below), so the derived string is always a valid `ScopeId`. The FFI layer
    /// (`rust/crates/ffi/src/api.rs`) calls this once, at `inventoryOpenScope` time, and returns
    /// it to Swift as `InventoryScopeHandleV1.subscriptionScopeId` -- Swift never re-derives it.
    #[must_use]
    pub fn to_subscription_scope_id(&self) -> crate::ScopeId {
        crate::ScopeId::from_u128(u128::from_be_bytes(self.0))
    }
}

/// Monotonic per-scope counter identifiers (see module doc comment for the shape rationale).
macro_rules! counter_id {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
        pub struct $name(u64);

        impl $name {
            #[must_use]
            pub const fn from_raw(value: u64) -> Self {
                Self(value)
            }

            #[must_use]
            pub const fn raw(&self) -> u64 {
                self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(formatter, "{}", self.0)
            }
        }
    };
}

counter_id!(SnapshotHandleId);
counter_id!(BulkLoadId);

/// A process-unique-enough monotonic counter used to mint `SnapshotHandleId`/`BulkLoadId` values
/// scoped to one `InventoryScope`. Not `pub`: callers never construct handle/bulk-load ids
/// themselves.
#[derive(Debug, Default)]
pub(crate) struct CounterMinter(u64);

impl CounterMinter {
    pub(crate) fn next(&mut self) -> u64 {
        self.0 += 1;
        self.0
    }
}

/// Opaque per-generation identity token. Two `GenerationToken`s compare equal iff they were
/// minted for the same published generation of the same root -- the mechanical-port anchor for
/// `WorkspaceCatalogShardTests`'s `===` reference-identity assertions
/// (`rust-inventory-scope-v1.md` §4 "Instance-identity contract"): "same generation ⇒ same
/// `generationToken`".
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct GenerationToken {
    root_lifetime: RootLifetimeId,
    generation: u64,
}

impl GenerationToken {
    pub(crate) const fn new(root_lifetime: RootLifetimeId, generation: u64) -> Self {
        Self {
            root_lifetime,
            generation,
        }
    }

    #[must_use]
    pub const fn root_lifetime(&self) -> RootLifetimeId {
        self.root_lifetime
    }

    #[must_use]
    pub const fn generation(&self) -> u64 {
        self.generation
    }
}

/// Mints `InventoryScopeId`/`RootLifetimeId` values.
///
/// Two modes:
/// - `fresh()`: process-entropy minting (mirrors `RuntimeIdentity::fresh`'s nonce shape), for
///   production use.
/// - `seeded(seed)`: deterministic splitmix64-derived minting, for reproducible property/unit
///   tests -- the "UUID minting with test seed" requirement.
pub struct UuidMinter {
    seeded_state: Option<AtomicU64>,
}

impl UuidMinter {
    #[must_use]
    pub const fn fresh() -> Self {
        Self { seeded_state: None }
    }

    #[must_use]
    pub const fn seeded(seed: u64) -> Self {
        Self {
            seeded_state: Some(AtomicU64::new(seed)),
        }
    }

    #[must_use]
    pub fn next_bytes(&self) -> [u8; 16] {
        match &self.seeded_state {
            Some(state) => {
                let hi = splitmix64(state);
                let lo = splitmix64(state);
                let mut bytes = [0u8; 16];
                bytes[..8].copy_from_slice(&hi.to_be_bytes());
                bytes[8..].copy_from_slice(&lo.to_be_bytes());
                bytes
            }
            None => fresh_entropy_bytes(),
        }
    }

    /// Mints raw bytes shaped as an RFC4122 version-4 UUID (version nibble `0100` at byte 6's
    /// high bits, variant bits `10` at byte 8's two high bits). This is the shape file/folder
    /// record identity requires (§4.1.1 of `docs/designs/p4-workspace-inventory-authority-v2-
    /// 2026-08-22.md`: "Rust mints v4-shaped UUIDs from a per-scope CSPRNG"), matching what
    /// Swift's `Foundation.UUID()` already produces at today's pre-cutover Swift-side mint site
    /// (`WorkspaceFileRecord.id`'s default). `next_bytes` is unchanged and still used for
    /// `InventoryScopeId`/`RootLifetimeId` -- those are opaque internal tokens, never round-
    /// tripped through `Foundation.UUID`, so they do not need this shape.
    #[must_use]
    pub fn next_v4_bytes(&self) -> [u8; 16] {
        let mut bytes = self.next_bytes();
        bytes[6] = (bytes[6] & 0x0F) | 0x40;
        bytes[8] = (bytes[8] & 0x3F) | 0x80;
        bytes
    }
}

impl Default for UuidMinter {
    fn default() -> Self {
        Self::fresh()
    }
}

fn splitmix64(state: &AtomicU64) -> u64 {
    let mut z = state
        .fetch_add(0x9E37_79B9_7F4A_7C15, Ordering::Relaxed)
        .wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

static NEXT_NONCE: AtomicU64 = AtomicU64::new(1);

fn fresh_entropy_bytes() -> [u8; 16] {
    let counter = u128::from(NEXT_NONCE.fetch_add(1, Ordering::Relaxed));
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let process = u128::from(std::process::id());
    let nonce = elapsed ^ counter.rotate_left(37) ^ (process << 64);
    nonce.to_be_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seeded_minter_is_deterministic_across_instances() {
        let a = UuidMinter::seeded(42);
        let b = UuidMinter::seeded(42);
        assert_eq!(a.next_bytes(), b.next_bytes());
        assert_eq!(a.next_bytes(), b.next_bytes());
    }

    #[test]
    fn seeded_minter_advances_between_calls() {
        let minter = UuidMinter::seeded(7);
        let first = minter.next_bytes();
        let second = minter.next_bytes();
        assert_ne!(first, second);
    }

    #[test]
    fn fresh_minter_never_repeats_within_a_short_burst() {
        let minter = UuidMinter::fresh();
        let mut seen = std::collections::HashSet::new();
        for _ in 0..256 {
            assert!(seen.insert(minter.next_bytes()));
        }
    }

    #[test]
    fn to_subscription_scope_id_round_trips_through_scope_id_parse() {
        let minter = UuidMinter::seeded(11);
        let scope_id = InventoryScopeId::mint(&minter);
        let derived = scope_id.to_subscription_scope_id();
        let parsed = crate::ScopeId::parse(derived.as_str()).expect("derived scope id must parse");
        assert_eq!(parsed, derived);
        // Distinct `InventoryScopeId`s must never collide onto the same `ScopeId` (the
        // conversion is a byte reinterpretation, so this is really asserting `UuidMinter`
        // doesn't repeat within this small sample -- already covered by
        // `fresh_minter_never_repeats_within_a_short_burst`, re-asserted here through the actual
        // conversion this hub-addressing depends on).
        let other = InventoryScopeId::mint(&minter);
        assert_ne!(other.to_subscription_scope_id(), derived);
    }

    #[test]
    fn v4_bytes_are_shaped_as_rfc4122_version_4() {
        let minter = UuidMinter::seeded(99);
        for _ in 0..64 {
            let bytes = minter.next_v4_bytes();
            assert_eq!(bytes[6] & 0xF0, 0x40, "version nibble must be 4: {bytes:02x?}");
            assert_eq!(bytes[8] & 0xC0, 0x80, "variant bits must be RFC4122 (10): {bytes:02x?}");
        }
    }

    #[test]
    fn v4_bytes_are_deterministic_under_a_seeded_minter() {
        let a = UuidMinter::seeded(1234);
        let b = UuidMinter::seeded(1234);
        assert_eq!(a.next_v4_bytes(), b.next_v4_bytes());
        assert_eq!(a.next_v4_bytes(), b.next_v4_bytes());
    }

    #[test]
    fn v4_bytes_advance_and_do_not_repeat_within_a_short_burst() {
        let minter = UuidMinter::seeded(5);
        let mut seen = std::collections::HashSet::new();
        for _ in 0..256 {
            assert!(seen.insert(minter.next_v4_bytes()));
        }
    }

    #[test]
    fn generation_token_equality_is_root_lifetime_and_generation_scoped() {
        let lifetime_a = RootLifetimeId::from_bytes([1; 16]);
        let lifetime_b = RootLifetimeId::from_bytes([2; 16]);
        let token_a1 = GenerationToken::new(lifetime_a, 1);
        let token_a1_again = GenerationToken::new(lifetime_a, 1);
        let token_a2 = GenerationToken::new(lifetime_a, 2);
        let token_b1 = GenerationToken::new(lifetime_b, 1);
        assert_eq!(token_a1, token_a1_again);
        assert_ne!(token_a1, token_a2);
        assert_ne!(token_a1, token_b1);
    }
}
