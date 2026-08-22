//! Wire/contract types for the textdecode module (design §5.1). Cargo-only in this phase — see
//! `mod.rs`'s scope note. These types are the shape TD-3's FFI layer carries across the boundary
//! unchanged; nothing here has a wire encoding yet.

use encoding_rs::Encoding;

/// Byte order for the two families `textdecode` distinguishes by endianness. `Utf32`'s variant is
/// hand-rolled (design §4.3/§9 D-3: `encoding_rs` does not implement the UTF-32 family); `Utf16`'s
/// exists so the endianness `encoding_rs::UTF_16BE`/`UTF_16LE` already encode is visible on
/// `DetectedEncoding` without a second lookup.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Endian {
    Big,
    Little,
}

/// The encoding `textdecode` actually used to produce `TextDecodeOutcome::text`. Mirrors design
/// §5.1 exactly.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DetectedEncoding {
    Utf8,
    Utf16 {
        endian: Endian,
    },
    /// Hand-rolled — see `Endian`'s doc comment and design §9 D-3.
    Utf32 {
        endian: Endian,
    },
    Legacy(&'static Encoding),
}

/// Whether a byte-order mark was present in the raw input and, if so, which encoding it named.
/// Per design §5.2 step 3 / §9 D-5, BOM bytes are **never** stripped on any path — this is
/// metadata describing what was found, not an instruction to trim anything. `bom` is set to
/// `Present` regardless of whether decoding under the named encoding succeeds cleanly.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BomDisposition {
    Absent,
    Present(DetectedEncoding),
}

/// The wire ID design §5.4 assigns the `CodeMapSourceDecoderPolicy` case TD-3 adds
/// (`"workspace-automatic-v2"`). Cargo-only here: this constant exists so
/// `TextDecodeOutcome::policy_version` has a stable, already-decided value for TD-3 to carry
/// across the FFI; nothing in this phase reads or writes an FFI wire form of it, and TD-3 owns
/// actually wiring `CodeMapSourceDecoderPolicy` itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextDecodePolicyVersion {
    WorkspaceAutomaticV2,
}

impl TextDecodePolicyVersion {
    /// The canonical wire ID design §5.4 assigns this policy version.
    #[must_use]
    pub const fn canonical_id(self) -> &'static str {
        match self {
            Self::WorkspaceAutomaticV2 => "workspace-automatic-v2",
        }
    }
}

/// The result of decoding one byte buffer to canonical UTF-8.
///
/// `textdecode` never fails (design §5.1/§5.3): there is no `Result` and no "undecodable" case.
/// `encoding_rs`'s replacement-decoding constructors cannot fail for any byte sequence in any
/// encoding they implement — every byte either maps or becomes U+FFFD — so this struct is always
/// constructible. `had_replacements` is the flag design §5.3 requires callers to treat as
/// blocking for any write-back-capable consumer (design §9 D-1/R8); that gating decision is
/// binding on TD-3/TD-5, not implemented here, since it has no FFI-reachable consumer yet.
#[derive(Clone, Debug, PartialEq)]
pub struct TextDecodeOutcome {
    /// Canonical UTF-8, scalar-boundary-safe.
    pub text: String,
    pub detected_encoding: DetectedEncoding,
    pub bom: BomDisposition,
    /// `encoding_rs` exposes only a malformed-sequence boolean, not a running replacement count
    /// (design §5.1 note: `decode`/`decode_without_bom_handling` return `(Cow<str>, .., bool)`).
    pub had_replacements: bool,
    pub policy_version: TextDecodePolicyVersion,
}
