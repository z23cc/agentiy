//! agent-host-v1 framing, validation, and fingerprint contract (design §5.2, §5.4).

use agentry_proto::agent_host::v1::{
    Attach, Capability, ClientKind, ClientMessage, CommandRequest, EventNotification,
    ExecutableIdentity, Hello, HostMessage, MutationKey, SessionSpec, SnapshotChunk, Start,
    UserMessage, client_message, command_request, host_message,
};
use agentry_proto::agent_host::{
    FRAME_LENGTH_PREFIX_BYTES, FrameError, MAXIMUM_FRAME_PAYLOAD_BYTES,
    MAXIMUM_SNAPSHOT_CHUNK_BYTES, PROTOCOL_VERSION, command_fingerprint, decode_client_message,
    decode_frame, decode_host_message, encode_client_message, encode_frame, encode_host_message,
    frame_payload_length, mutation_key,
};
use proptest::prelude::*;

/// Frozen encoding of `hello()` as a complete frame. Any change here is a wire-format change and
/// needs a `PROTOCOL_VERSION` bump.
const HELLO_FRAME: &[u8] = &[
    0x00, 0x00, 0x00, 0x37, 0x0a, 0x35, 0x08, 0x01, 0x12, 0x02, 0x66, 0x70, 0x1a, 0x1c, 0x0a, 0x0b,
    0x63, 0x6f, 0x6d, 0x2e, 0x61, 0x67, 0x65, 0x6e, 0x74, 0x72, 0x79, 0x12, 0x0b, 0x61, 0x67, 0x65,
    0x6e, 0x74, 0x72, 0x79, 0x2d, 0x6d, 0x63, 0x70, 0x28, 0x2a, 0x22, 0x02, 0x01, 0x02, 0x2a, 0x09,
    0x63, 0x6c, 0x69, 0x65, 0x6e, 0x74, 0x2d, 0x69, 0x64, 0x30, 0x01,
];

fn hello() -> ClientMessage {
    ClientMessage {
        body: Some(client_message::Body::Hello(Hello {
            protocol_version: PROTOCOL_VERSION,
            build_fingerprint: "fp".to_owned(),
            executable: Some(ExecutableIdentity {
                bundle_identifier: "com.agentry".to_owned(),
                executable_name: "agentry-mcp".to_owned(),
                pid: 42,
                ..ExecutableIdentity::default()
            }),
            capabilities: vec![
                Capability::CanPresent as i32,
                Capability::SnapshotStreaming as i32,
            ],
            client_id: "client-id".to_owned(),
            client_kind: ClientKind::Gui as i32,
        })),
    }
}

fn start(operation_id: &str, fingerprint: &str, text: &str) -> CommandRequest {
    CommandRequest {
        request_id: format!("request-{operation_id}"),
        command: Some(command_request::Command::Start(Start {
            key: Some(MutationKey {
                operation_id: operation_id.to_owned(),
                argument_fingerprint: fingerprint.to_owned(),
            }),
            spec: Some(SessionSpec {
                session_id: "session-1".to_owned(),
                workspace_id: "workspace-1".to_owned(),
                initial_message: Some(UserMessage {
                    message_id: "m1".to_owned(),
                    text: text.to_owned(),
                    ..UserMessage::default()
                }),
                ..SessionSpec::default()
            }),
        })),
    }
}

#[test]
fn hello_frame_encoding_is_frozen() {
    let frame = encode_client_message(&hello()).unwrap();
    assert_eq!(frame, HELLO_FRAME);
    assert_eq!(decode_client_message(HELLO_FRAME).unwrap(), hello());
    assert_eq!(frame_payload_length(&frame[..4]).unwrap(), 0x37);
}

#[test]
fn frames_round_trip_both_directions() {
    let command = ClientMessage {
        body: Some(client_message::Body::Command(start("op", "fp", "hi"))),
    };
    let encoded = encode_client_message(&command).unwrap();
    assert_eq!(decode_client_message(&encoded).unwrap(), command);

    let event = HostMessage {
        body: Some(host_message::Body::Event(EventNotification {
            session_id: "session-1".to_owned(),
            generation: vec![1, 2, 3],
            delivery_cursor: 7,
            event: Some(agentry_proto::agent_host::v1::AgentSessionEvent::default()),
        })),
    };
    let encoded = encode_host_message(&event).unwrap();
    assert_eq!(decode_host_message(&encoded).unwrap(), event);
}

#[test]
fn rejects_short_prefix_oversize_truncated_and_trailing_frames() {
    assert_eq!(
        frame_payload_length(&[0, 0]),
        Err(FrameError::PrefixTooShort { actual: 2 })
    );
    let declared = (MAXIMUM_FRAME_PAYLOAD_BYTES + 1) as u32;
    assert_eq!(
        frame_payload_length(&declared.to_be_bytes()),
        Err(FrameError::PayloadTooLarge {
            declared: MAXIMUM_FRAME_PAYLOAD_BYTES + 1,
            maximum: MAXIMUM_FRAME_PAYLOAD_BYTES,
        })
    );
    assert!(frame_payload_length(&(MAXIMUM_FRAME_PAYLOAD_BYTES as u32).to_be_bytes()).is_ok());

    let truncated = &HELLO_FRAME[..HELLO_FRAME.len() - 3];
    assert_eq!(
        decode_client_message(truncated),
        Err(FrameError::TruncatedPayload {
            declared: 0x37,
            actual: 0x37 - 3,
        })
    );
    let mut trailing = HELLO_FRAME.to_vec();
    trailing.push(0);
    assert_eq!(
        decode_client_message(&trailing),
        Err(FrameError::TrailingBytes { extra: 1 })
    );
    let mut garbage = HELLO_FRAME.to_vec();
    garbage[FRAME_LENGTH_PREFIX_BYTES] = 0xFF;
    assert!(matches!(
        decode_client_message(&garbage),
        Err(FrameError::Malformed { .. })
    ));
}

#[test]
fn rejects_empty_bodies_and_oversized_snapshot_chunks() {
    assert_eq!(
        encode_client_message(&ClientMessage::default()),
        Err(FrameError::EmptyBody)
    );
    let empty_command = ClientMessage {
        body: Some(client_message::Body::Command(CommandRequest::default())),
    };
    assert_eq!(encode_client_message(&empty_command), Err(FrameError::EmptyBody));
    let encoded_empty = encode_frame(&ClientMessage::default()).unwrap();
    assert_eq!(decode_client_message(&encoded_empty), Err(FrameError::EmptyBody));
    assert_eq!(
        encode_host_message(&HostMessage::default()),
        Err(FrameError::EmptyBody)
    );

    let chunk = HostMessage {
        body: Some(host_message::Body::SnapshotChunk(SnapshotChunk {
            session_id: "s".to_owned(),
            chunk_index: 0,
            offset: 0,
            data: vec![0; MAXIMUM_SNAPSHOT_CHUNK_BYTES + 1],
        })),
    };
    assert_eq!(
        encode_host_message(&chunk),
        Err(FrameError::SnapshotChunkTooLarge {
            actual: MAXIMUM_SNAPSHOT_CHUNK_BYTES + 1,
            maximum: MAXIMUM_SNAPSHOT_CHUNK_BYTES,
        })
    );
    let oversized_frame = encode_frame(&chunk).unwrap();
    assert!(matches!(
        decode_host_message(&oversized_frame),
        Err(FrameError::SnapshotChunkTooLarge { .. })
    ));
    let mut maximal = chunk;
    if let Some(host_message::Body::SnapshotChunk(inner)) = maximal.body.as_mut() {
        inner.data.truncate(MAXIMUM_SNAPSHOT_CHUNK_BYTES);
    }
    assert!(encode_host_message(&maximal).is_ok());
}

#[test]
fn refuses_to_encode_above_the_frame_cap() {
    let huge = ClientMessage {
        body: Some(client_message::Body::Command(start(
            "op",
            "fp",
            &"x".repeat(MAXIMUM_FRAME_PAYLOAD_BYTES),
        ))),
    };
    assert!(matches!(
        encode_client_message(&huge),
        Err(FrameError::EncodedTooLarge { .. })
    ));
}

#[test]
fn command_fingerprint_ignores_key_and_request_id_but_not_arguments() {
    let base = start("op-1", "", "hi");
    let fingerprint = command_fingerprint(&base);
    assert_eq!(fingerprint.len(), 64);
    assert_eq!(command_fingerprint(&start("op-2", "anything", "hi")), fingerprint);
    assert_ne!(command_fingerprint(&start("op-1", "", "bye")), fingerprint);
    assert_eq!(
        mutation_key(&base).map(|key| key.operation_id.as_str()),
        Some("op-1")
    );
    let read_only = CommandRequest {
        request_id: "r".to_owned(),
        command: Some(command_request::Command::Attach(Attach {
            session_id: "s".to_owned(),
            resume_cursor: Some(3),
            resume_generation: vec![],
        })),
    };
    assert_eq!(mutation_key(&read_only), None);
    assert_eq!(mutation_key(&CommandRequest::default()), None);
}

#[test]
fn every_enum_starts_at_unspecified_zero() {
    use agentry_proto::agent_host::v1::*;
    assert_eq!(Capability::Unspecified as i32, 0);
    assert_eq!(ClientKind::Unspecified as i32, 0);
    assert_eq!(HandshakeRejectReason::Unspecified as i32, 0);
    assert_eq!(HostNoticeKind::Unspecified as i32, 0);
    assert_eq!(SteerDelivery::Unspecified as i32, 0);
    assert_eq!(StopReason::Unspecified as i32, 0);
    assert_eq!(ShutdownMode::Unspecified as i32, 0);
    assert_eq!(CommandRejectionReason::Unspecified as i32, 0);
    assert_eq!(AttachReplay::Unspecified as i32, 0);
    assert_eq!(InterruptOutcome::Unspecified as i32, 0);
    assert_eq!(InteractionResponseDisposition::Unspecified as i32, 0);
    assert_eq!(SessionStatus::Unspecified as i32, 0);
    assert_eq!(FailureReason::Unspecified as i32, 0);
    assert_eq!(ApprovalPolicy::Unspecified as i32, 0);
    assert_eq!(ToolDisposition::Unspecified as i32, 0);
    assert_eq!(ResnapshotReason::Unspecified as i32, 0);
    assert_eq!(ApprovalRequestIdSource::Unspecified as i32, 0);
    assert_eq!(ApprovalKind::Unspecified as i32, 0);
    assert_eq!(LifecycleStage::Unspecified as i32, 0);
    assert_eq!(RetryIntent::Unspecified as i32, 0);
    assert_eq!(EpochTransitionKind::Unspecified as i32, 0);
    assert_eq!(TerminalOutcomeKind::Unspecified as i32, 0);
    assert_eq!(TerminationSignalKind::Unspecified as i32, 0);
    assert_eq!(InteractionKind::Unspecified as i32, 0);
    assert_eq!(InteractionResponseType::Unspecified as i32, 0);
    assert_eq!(ApprovalDecisionKind::Unspecified as i32, 0);
    assert_eq!(ElicitationAction::Unspecified as i32, 0);
    assert_eq!(InteractionSettlement::Unspecified as i32, 0);
    assert_eq!(TranscriptRole::Unspecified as i32, 0);
    // Unknown numbers stay unknown instead of aliasing a known member.
    assert!(AttachReplay::try_from(99).is_err());
}

proptest! {
    #[test]
    fn arbitrary_bytes_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..2048)) {
        let _ = decode_client_message(&bytes);
        let _ = decode_host_message(&bytes);
        let _: Result<ClientMessage, _> = decode_frame(&bytes);
        let _ = frame_payload_length(&bytes);
    }

    #[test]
    fn framed_payloads_round_trip(text in "[a-zA-Z0-9 ]{0,200}", cursor in any::<u64>()) {
        let message = ClientMessage {
            body: Some(client_message::Body::Command(CommandRequest {
                request_id: text.clone(),
                command: Some(command_request::Command::Attach(Attach {
                    session_id: text,
                    resume_cursor: Some(cursor),
                    resume_generation: cursor.to_be_bytes().to_vec(),
                })),
            })),
        };
        let frame = encode_client_message(&message).unwrap();
        prop_assert_eq!(decode_client_message(&frame).unwrap(), message);
    }
}
