use agentry_proto::{
    DecodeError, DecodeLimits, Envelope, HEADER_BYTES, MAXIMUM_ENVELOPE_BYTES,
    MAXIMUM_PAYLOAD_BYTES, PayloadKind,
};
use proptest::prelude::*;

const EMPTY: &[u8] = include_bytes!("fixtures/v1/empty.bin");
const SMALL: &[u8] = include_bytes!("fixtures/v1/small.bin");
const TRUNCATED: &[u8] = include_bytes!("fixtures/v1/truncated.bin");
const UNKNOWN_VERSION: &[u8] = include_bytes!("fixtures/v1/unknown-version.bin");

#[test]
fn decodes_frozen_valid_fixtures() {
    let empty = Envelope::decode(EMPTY).expect("empty fixture should decode");
    assert_eq!(empty.payload_kind, PayloadKind::Control);
    assert!(empty.payload.is_empty());

    let small = Envelope::decode(SMALL).expect("small fixture should decode");
    assert_eq!(small.payload_kind, PayloadKind::Data);
    assert_eq!(
        small.payload,
        br#"{"kind":"synthetic","sequence":1}
"#
    );
}

#[test]
fn rejects_frozen_malformed_fixtures() {
    assert_eq!(
        Envelope::decode(TRUNCATED),
        Err(DecodeError::TruncatedPayload {
            declared: 4,
            actual: 2,
        })
    );
    assert_eq!(
        Envelope::decode(UNKNOWN_VERSION),
        Err(DecodeError::UnsupportedSchemaVersion { actual: 2 })
    );
}

#[test]
fn round_trips_every_payload_kind() {
    for kind in [
        PayloadKind::Control,
        PayloadKind::Data,
        PayloadKind::HostRequest,
        PayloadKind::HostResponse,
    ] {
        let encoded = Envelope::encode(kind, b"synthetic").expect("encode should succeed");
        let decoded = Envelope::decode(&encoded).expect("decode should succeed");
        assert_eq!(decoded.payload_kind, kind);
        assert_eq!(decoded.payload, b"synthetic");
    }
}

#[test]
fn rejects_unknown_kind_flags_trailing_and_declared_oversize() {
    let mut unknown_kind = EMPTY.to_vec();
    unknown_kind[6..8].copy_from_slice(&99_u16.to_be_bytes());
    assert_eq!(
        Envelope::decode(&unknown_kind),
        Err(DecodeError::UnknownPayloadKind { actual: 99 })
    );

    let mut flags = EMPTY.to_vec();
    flags[8..12].copy_from_slice(&1_u32.to_be_bytes());
    assert_eq!(
        Envelope::decode(&flags),
        Err(DecodeError::UnsupportedFlags { actual: 1 })
    );

    let mut trailing = EMPTY.to_vec();
    trailing.push(0);
    assert_eq!(
        Envelope::decode(&trailing),
        Err(DecodeError::TrailingBytes {
            declared: 0,
            actual: 1,
        })
    );

    let mut declared_oversize = EMPTY.to_vec();
    declared_oversize[12..16].copy_from_slice(&u32::MAX.to_be_bytes());
    assert_eq!(
        Envelope::decode(&declared_oversize),
        Err(DecodeError::DeclaredPayloadTooLarge {
            declared: u32::MAX as usize,
            maximum: MAXIMUM_PAYLOAD_BYTES,
        })
    );
}

#[test]
fn enforces_decoded_collection_and_string_limits() {
    let limits = DecodeLimits {
        maximum_envelope_bytes: MAXIMUM_ENVELOPE_BYTES,
        maximum_decoded_bytes: 8,
        maximum_collection_items: 2,
        maximum_string_bytes: 3,
    };
    assert_eq!(
        limits.validate_decoded_size(9),
        Err(DecodeError::DecodedSizeExceeded {
            actual: 9,
            maximum: 8,
        })
    );
    assert_eq!(
        limits.validate_collection_len(3),
        Err(DecodeError::CollectionTooLarge {
            actual: 3,
            maximum: 2,
        })
    );
    assert_eq!(
        limits.decode_utf8(b"four"),
        Err(DecodeError::StringTooLong {
            actual: 4,
            maximum: 3,
        })
    );
    assert_eq!(limits.decode_utf8(&[0xff]), Err(DecodeError::InvalidUtf8));
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 2_048,
        failure_persistence: None,
        ..ProptestConfig::default()
    })]

    #[test]
    fn arbitrary_bytes_never_panic_and_only_exact_envelopes_decode(bytes in prop::collection::vec(any::<u8>(), 0..=(HEADER_BYTES + 2_048))) {
        if let Ok(decoded) = Envelope::decode(&bytes) {
            prop_assert_eq!(bytes.len(), HEADER_BYTES + decoded.payload.len());
            prop_assert!(decoded.payload.len() <= MAXIMUM_PAYLOAD_BYTES);
        }
    }

    #[test]
    fn any_declared_length_larger_than_available_fails_closed(
        declared in 1_u32..=1_048_560_u32,
        actual in 0_usize..128,
    ) {
        prop_assume!(declared as usize > actual);
        let mut bytes = Vec::with_capacity(HEADER_BYTES + actual);
        bytes.extend_from_slice(b"AGRY");
        bytes.extend_from_slice(&1_u16.to_be_bytes());
        bytes.extend_from_slice(&2_u16.to_be_bytes());
        bytes.extend_from_slice(&0_u32.to_be_bytes());
        bytes.extend_from_slice(&declared.to_be_bytes());
        bytes.resize(HEADER_BYTES + actual, 0);
        prop_assert_eq!(
            Envelope::decode(&bytes),
            Err(DecodeError::TruncatedPayload {
                declared: declared as usize,
                actual,
            })
        );
    }
}
