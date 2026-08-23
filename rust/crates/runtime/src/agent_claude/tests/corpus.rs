//! P6-3 corpus differential, Rust arm (design §3.4 rung "codec"; contract §6/§9). Each fixture's
//! expected outcome below is hand-verified against `ClaudeNativeProcessSessionController.swift`'s
//! actual source (not paraphrased from `MANIFEST.json` -- the manifest's own `expectedBehavior`
//! prose was itself checked against that source during this slice's authoring, and the two agree).

use std::path::Path;

use super::{framed_lines, read_fixture};
use crate::agent_claude::codec::{self, CodecError};
use crate::agent_claude::recovery::{self, RecoveryDiagnostic, RecoveryOutcome};
use crate::agent_claude::translator::Translator;

fn one_line(name: &str) -> Vec<u8> {
    let lines = framed_lines(name);
    assert_eq!(lines.len(), 1, "{name}: expected exactly one framed line, got {}", lines.len());
    lines.into_iter().next().unwrap()
}

// MARK: - D-1 heuristic 1: concatenated-segment split

#[test]
fn concatenated_split_positive_recovers_both_segments() {
    let line = one_line("d1-concatenated-split-positive.ndjson");
    assert_eq!(codec::decode_line(&line), Err(CodecError::InvalidJson), "trailing data after the first close-brace must fail primary decode");

    let mut diagnostics = Vec::new();
    let outcome = recovery::recover_invalid_json_line(&line, false, |d| diagnostics.push(d));
    match outcome {
        RecoveryOutcome::Recovered(messages) => assert_eq!(messages.len(), 2, "both segments must decode independently"),
        other => panic!("expected Recovered(2 messages), got {other:?}"),
    }
    assert!(
        diagnostics.contains(&RecoveryDiagnostic::Recovered { segments: 2, recovered_segments: 2 }),
        "diagnostics: {diagnostics:?}"
    );
}

#[test]
fn concatenated_split_negative_finds_zero_segments_and_every_heuristic_declines() {
    let line = one_line("d1-concatenated-split-negative.ndjson");
    assert_eq!(codec::decode_line(&line), Err(CodecError::InvalidJson));

    let outcome = recovery::recover_invalid_json_line(&line, true, |_| {});
    assert_eq!(outcome, RecoveryOutcome::Declined, "unterminated JSON candidate: no heuristic can recover it, even with a turn in flight");
}

// MARK: - D-1 heuristic 2: embedded-tail scan

#[test]
fn embedded_tail_positive_recovers_the_trailing_object() {
    let line = one_line("d1-embedded-tail-positive.ndjson");
    assert_eq!(codec::decode_line(&line), Err(CodecError::InvalidJson));

    let mut diagnostics = Vec::new();
    let outcome = recovery::recover_invalid_json_line(&line, false, |d| diagnostics.push(d));
    match outcome {
        RecoveryOutcome::Recovered(messages) => assert_eq!(messages.len(), 1),
        other => panic!("expected Recovered(1 message), got {other:?}"),
    }
    let expected_start = line.len() - br#"{"type":"system","subtype":"status","status":"recovered-from-tail"}"#.len();
    assert!(
        diagnostics.iter().any(|d| matches!(d, RecoveryDiagnostic::RecoveredTail { start_offset, .. } if *start_offset == expected_start)),
        "diagnostics: {diagnostics:?}"
    );
}

#[test]
fn embedded_tail_negative_finds_zero_marker_occurrences() {
    let line = one_line("d1-embedded-tail-negative.ndjson");
    assert_eq!(codec::decode_line(&line), Err(CodecError::InvalidJson));
    assert_eq!(recovery::recover_invalid_json_line(&line, true, |_| {}), RecoveryOutcome::Declined);
}

// MARK: - D-1 heuristic 3 / codec's own inline sanitize (control-char repair; open question closed
// in this module's parent doc comment, `recovery.rs`)

#[test]
fn json_control_char_repair_fixture_is_handled_by_the_codecs_own_sanitize_not_the_controller_heuristic() {
    // This fixture is two raw `\n`-delimited chunks on disk; the embedded control byte sits
    // inside a JSON string, so the *framer* (quote-aware) reassembles them into one logical line
    // before the codec ever sees it -- exactly the MANIFEST's point about this fixture.
    let line = one_line("d1-json-control-char-repair-embedded-lf.ndjson");
    let decoded = codec::decode_line(&line).expect("codec's own inline sanitize must succeed here").unwrap();
    match decoded {
        crate::agent_claude::InboundMessage::StreamPayload(payload) => {
            assert_eq!(payload.get("status").and_then(|v| v.as_str()), Some("line one\nline two"));
        }
        other => panic!("expected StreamPayload, got {other:?}"),
    }
    // Because the primary `decode_line` call already succeeded, `handleLine`'s dispatch (§6) never
    // reaches the recovery heuristics at all for this fixture -- confirmed structurally rather than
    // by calling `recover_invalid_json_line` (which would require an already-failed decode as its
    // precondition, and calling it anyway would misrepresent what `handleLine` actually does).
}

// MARK: - D-1 heuristic 4: plaintext-assistant salvage

#[test]
fn plaintext_salvage_positive_only_fires_while_a_turn_is_in_flight() {
    let line = one_line("d1-plaintext-salvage-positive.ndjson");
    assert_eq!(codec::decode_line(&line), Err(CodecError::InvalidJson));

    assert_eq!(
        recovery::recover_invalid_json_line(&line, false, |_| {}),
        RecoveryOutcome::Declined,
        "HARNESS PRECONDITION (MANIFEST.json): declines when no turn is in flight"
    );

    let mut diagnostics = Vec::new();
    let outcome = recovery::recover_invalid_json_line(&line, true, |d| diagnostics.push(d));
    let expected_text = "The build finished successfully after running every validation check.";
    assert_eq!(outcome, RecoveryOutcome::PlaintextSalvage(expected_text.to_string()));
    assert!(diagnostics.iter().any(|d| matches!(d, RecoveryDiagnostic::RecoveredPlaintext { length } if *length == expected_text.chars().count())));
}

#[test]
fn plaintext_salvage_negative_too_short_declines_regardless_of_turn_state() {
    let line = one_line("d1-plaintext-salvage-negative-too-short.ndjson");
    assert_eq!(codec::decode_line(&line), Err(CodecError::InvalidJson));
    assert_eq!(recovery::recover_invalid_json_line(&line, false, |_| {}), RecoveryOutcome::Declined);
    assert_eq!(recovery::recover_invalid_json_line(&line, true, |_| {}), RecoveryOutcome::Declined);
}

// MARK: - Non-recovery framer/codec fixtures

#[test]
fn crlf_line_ending_decodes_cleanly_after_framer_strips_cr_and_lf() {
    let line = one_line("crlf-line-ending.ndjson");
    assert!(!line.ends_with(b"\r") && !line.ends_with(b"\n"));
    let decoded = codec::decode_line(&line).unwrap().unwrap();
    assert!(matches!(decoded, crate::agent_claude::InboundMessage::StreamPayload(_)));
}

#[test]
fn non_utf8_bytes_fails_primary_decode_and_every_recovery_heuristic_declines() {
    let line = one_line("non-utf8-bytes.ndjson");
    assert_eq!(codec::decode_line(&line), Err(CodecError::InvalidJson));
    // Every heuristic declines: concatenated-split and plaintext-salvage both require the whole
    // blob to be valid UTF-8 (it is not); the embedded marker's only occurrence sits at absolute
    // offset 0 (the same parse that already failed, so it's dropped); control-char repair
    // requires an embedded 0x0A/0x0D, absent here.
    assert_eq!(recovery::recover_invalid_json_line(&line, true, |_| {}), RecoveryOutcome::Declined);
}

#[test]
fn oversized_line_decodes_cleanly_with_no_recovery_dispatch() {
    let line = one_line("oversized-line-over-1mb.ndjson");
    assert!(line.len() > 1024 * 1024);
    let decoded = codec::decode_line(&line).unwrap().unwrap();
    let crate::agent_claude::InboundMessage::StreamPayload(payload) = decoded else {
        panic!("expected StreamPayload");
    };
    let mut translator = Translator::default();
    let results = translator.parse_stream_payload(&payload);
    assert_eq!(results.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["final_content", "message_stop"]);
}

// MARK: - Translator-body real-capture-shaped fixtures (design §3.4's "realCaptureOnly" gap)

fn translate_one(name: &str) -> Vec<crate::agent_claude::StreamResult> {
    let line = one_line(name);
    let payload = match codec::decode_line(&line).unwrap().unwrap() {
        crate::agent_claude::InboundMessage::StreamPayload(payload) => payload,
        other => panic!("{name}: expected a stream payload, got {other:?}"),
    };
    Translator::default().parse_stream_payload(&payload)
}

#[test]
fn realcapture_thinking_and_reasoning_dropped() {
    let lines: Vec<Vec<u8>> = read_fixture("realcapture-thinking-and-reasoning-dropped.ndjson")
        .split(|&b| b == b'\n')
        .filter(|l| !l.is_empty())
        .map(<[u8]>::to_vec)
        .collect();
    assert_eq!(lines.len(), 2);
    let mut translator = Translator::default();

    let assistant_payload = match codec::decode_line(&lines[0]).unwrap().unwrap() {
        crate::agent_claude::InboundMessage::StreamPayload(payload) => payload,
        other => panic!("expected StreamPayload, got {other:?}"),
    };
    let assistant_results = translator.parse_stream_payload(&assistant_payload);
    assert_eq!(assistant_results.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["content"]);
    assert_eq!(assistant_results[0].text.as_deref(), Some("Here is the answer."));

    let delta_payload = match codec::decode_line(&lines[1]).unwrap().unwrap() {
        crate::agent_claude::InboundMessage::StreamPayload(payload) => payload,
        other => panic!("expected StreamPayload, got {other:?}"),
    };
    assert!(translator.parse_stream_payload(&delta_payload).is_empty());
}

#[test]
fn realcapture_result_without_errors() {
    let results = translate_one("realcapture-result-without-errors.ndjson");
    assert_eq!(results.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["final_content", "message_stop"]);
    assert_eq!(results[0].text.as_deref(), Some("All done."));
    assert_eq!(results[1].provider_session_id.as_deref(), Some("claude-session-realcapture-1"));
    assert_eq!(results[1].cost, Some(0.0421));
}

#[test]
fn realcapture_result_with_genuine_error() {
    let results = translate_one("realcapture-result-with-genuine-error.ndjson");
    assert_eq!(results.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["error", "message_stop"]);
    assert_eq!(results[0].text.as_deref(), Some("Maximum turns exceeded for this task"));
}

#[test]
fn realcapture_session_state_changed_idle_sequence() {
    let lines: Vec<Vec<u8>> = read_fixture("realcapture-session-state-changed-idle-sequence.ndjson")
        .split(|&b| b == b'\n')
        .filter(|l| !l.is_empty())
        .map(<[u8]>::to_vec)
        .collect();
    assert_eq!(lines.len(), 3);
    let mut translator = Translator::default();
    let mut texts = Vec::new();
    for line in &lines {
        let payload = match codec::decode_line(line).unwrap().unwrap() {
            crate::agent_claude::InboundMessage::StreamPayload(payload) => payload,
            other => panic!("expected StreamPayload, got {other:?}"),
        };
        let results = translator.parse_stream_payload(&payload);
        assert_eq!(results.iter().map(|r| r.kind.as_str()).collect::<Vec<_>>(), ["session_state_changed"]);
        texts.push(results[0].text.clone().unwrap());
    }
    assert_eq!(texts, ["running", "compacting", "idle"]);
}

#[test]
fn realcapture_can_use_tool_round_trip_decodes_at_codec_level() {
    let lines: Vec<Vec<u8>> = read_fixture("realcapture-can-use-tool-round-trip.ndjson")
        .split(|&b| b == b'\n')
        .filter(|l| !l.is_empty())
        .map(<[u8]>::to_vec)
        .collect();
    assert_eq!(lines.len(), 2);

    let request = match codec::decode_line(&lines[0]).unwrap().unwrap() {
        crate::agent_claude::InboundMessage::ControlRequest(request) => request,
        other => panic!("expected ControlRequest, got {other:?}"),
    };
    assert_eq!(request.request_id, "req-1");
    assert_eq!(request.subtype, "can_use_tool");
    assert_eq!(request.request.get("tool_name").and_then(|v| v.as_str()), Some("Bash"));

    let response = match codec::decode_line(&lines[1]).unwrap().unwrap() {
        crate::agent_claude::InboundMessage::ControlResponse(response) => response,
        other => panic!("expected ControlResponse, got {other:?}"),
    };
    assert_eq!(response.request_id, "req-1");
    assert_eq!(response.subtype, "success");
    assert!(response.error.is_none());
}

// MARK: - Host-owned-tool-name predicate corpus (E-P6-1(c))

#[test]
fn host_owned_tool_name_fixture_is_present_and_covers_the_full_alias_table() {
    // The dedicated fixture-differential test lives in `tool_owned::tests`; this is a corpus-
    // presence smoke check tying it into the same `tests/fixtures/claude-ndjson/v1/` directory
    // this module reads from.
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/claude-ndjson/v1/host-owned-tool-name-cases-v1.json");
    assert!(path.exists(), "{path:?} must exist alongside MANIFEST.json");
}
