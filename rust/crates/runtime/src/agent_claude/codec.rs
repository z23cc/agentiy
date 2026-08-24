//! Port of `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/
//! ClaudeSDKProtocolCodec.swift` (208 lines) -- the envelope layer (contract §2.1). Byte-exact per
//! design D-1: every parse attempt, error classification, and outbound encoding below must match
//! the Swift source, not a paraphrase of it.
//!
//! `serde_json::Value`/`Map` stand in for the Swift package's `ClaudeProviderJSONValue` DTO --
//! there is no FFI crossing at this slice (design INV-P6-1: "zero FFI dependency... no export
//! exists yet"), so no wire-shape freeze is needed for this internal representation.

use serde_json::{Map, Value};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodecError {
    InvalidJson,
    UnsupportedPayload,
}

impl std::fmt::Display for CodecError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CodecError::InvalidJson => write!(f, "invalidJSON"),
            CodecError::UnsupportedPayload => write!(f, "unsupportedPayload"),
        }
    }
}

impl std::error::Error for CodecError {}

#[derive(Debug, Clone, PartialEq)]
pub struct ControlRequest {
    pub request_id: String,
    pub request: Map<String, Value>,
    pub subtype: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ControlResponse {
    pub request_id: String,
    pub subtype: String,
    pub response: Option<Map<String, Value>>,
    pub error: Option<String>,
    pub pending_permission_requests: Vec<Map<String, Value>>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum InboundMessage {
    StreamPayload(Map<String, Value>),
    ControlRequest(ControlRequest),
    ControlResponse(ControlResponse),
    ControlCancelRequest { request_id: String },
    KeepAlive,
}

fn string_value(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn object_value(object: &Map<String, Value>, key: &str) -> Option<Map<String, Value>> {
    object.get(key).and_then(Value::as_object).cloned()
}

/// Port of `ClaudeSDKProtocolCodec.decodeLine(_:)`. `None` mirrors the Swift function's `nil`
/// return for an empty/all-whitespace line (contract §2.1: "trimmed of ASCII whitespace (empty ⇒
/// no message)").
pub fn decode_line(line_data: &[u8]) -> Result<Option<InboundMessage>, CodecError> {
    decode_line_with(line_data, parse_json_object)
}

fn decode_line_with(
    line_data: &[u8],
    parse: impl FnOnce(&[u8]) -> Result<Map<String, Value>, CodecError>,
) -> Result<Option<InboundMessage>, CodecError> {
    let Some(trimmed) = super::framer::trimmed_ascii_whitespace(line_data) else {
        return Ok(None);
    };
    if trimmed.is_empty() {
        return Ok(None);
    }
    let object = parse(trimmed)?;

    let message_type = object.get("type").and_then(Value::as_str).unwrap_or("");
    match message_type {
        "control_request" => {
            let (Some(request_id), Some(request)) = (
                string_value(&object, "request_id"),
                object_value(&object, "request"),
            ) else {
                return Err(CodecError::UnsupportedPayload);
            };
            let subtype = string_value(&request, "subtype").unwrap_or_default();
            Ok(Some(InboundMessage::ControlRequest(ControlRequest {
                request_id,
                request,
                subtype,
            })))
        }
        "control_response" => {
            let Some(envelope) = object_value(&object, "response") else {
                return Err(CodecError::UnsupportedPayload);
            };
            let (Some(request_id), Some(subtype)) = (
                string_value(&envelope, "request_id"),
                string_value(&envelope, "subtype"),
            ) else {
                return Err(CodecError::UnsupportedPayload);
            };
            let response_object = object_value(&envelope, "response");
            let error = string_value(&envelope, "error");
            let pending_permission_requests = envelope
                .get("pending_permission_requests")
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_object)
                        .cloned()
                        .collect()
                })
                .unwrap_or_default();
            Ok(Some(InboundMessage::ControlResponse(ControlResponse {
                request_id,
                subtype,
                response: response_object,
                error,
                pending_permission_requests,
            })))
        }
        "control_cancel_request" => {
            let Some(request_id) = string_value(&object, "request_id") else {
                return Err(CodecError::UnsupportedPayload);
            };
            Ok(Some(InboundMessage::ControlCancelRequest { request_id }))
        }
        "keep_alive" => Ok(Some(InboundMessage::KeepAlive)),
        _ => Ok(Some(InboundMessage::StreamPayload(object))),
    }
}

fn decode_object(data: &[u8]) -> Result<Map<String, Value>, CodecError> {
    let value: Value = serde_json::from_slice(data).map_err(|_| CodecError::InvalidJson)?;
    match value {
        Value::Object(map) => Ok(map),
        _ => Err(CodecError::InvalidJson),
    }
}

/// Port of `ClaudeSDKProtocolCodec.parseJSONObject(from:)` (`:85-109`): try the raw bytes, then --
/// only on failure -- a JSON-string-control-character repair pass followed by a second attempt.
fn parse_json_object(data: &[u8]) -> Result<Map<String, Value>, CodecError> {
    if let Ok(object) = decode_object(data) {
        return Ok(object);
    }
    let Some(text) = std::str::from_utf8(data).ok() else {
        return Err(CodecError::InvalidJson);
    };
    let Some(sanitized) = sanitize_json_control_characters_in_strings(text) else {
        return Err(CodecError::InvalidJson);
    };
    decode_object(sanitized.as_bytes()).map_err(|_| CodecError::InvalidJson)
}

/// Port of `ClaudeSDKProtocolCodec.sanitizeJSONControlCharactersInStrings(in:)` (`:111-151`).
/// Escapes any byte `< 0x20` found *inside* a JSON string value as `\u00XX`. Requires the input to
/// already be valid UTF-8 (this is the asymmetry with `framer::repair_json_string_control_characters`,
/// which operates on raw bytes with no such requirement -- see `agent_claude::recovery`'s doc
/// comment for why that asymmetry never yields a distinguishing input in practice).
fn sanitize_json_control_characters_in_strings(raw: &str) -> Option<String> {
    if raw.is_empty() {
        return None;
    }
    let mut output = String::with_capacity(raw.len() + 8);
    let mut in_string = false;
    let mut is_escaping = false;
    let mut did_sanitize = false;

    for ch in raw.chars() {
        if in_string {
            if is_escaping {
                output.push(ch);
                is_escaping = false;
                continue;
            }
            match ch {
                '\\' => {
                    output.push(ch);
                    is_escaping = true;
                }
                '"' => {
                    output.push(ch);
                    in_string = false;
                }
                _ => {
                    if (ch as u32) < 0x20 {
                        output.push_str(&format!("\\u{:04X}", ch as u32));
                        did_sanitize = true;
                    } else {
                        output.push(ch);
                    }
                }
            }
        } else {
            output.push(ch);
            if ch == '"' {
                in_string = true;
            }
        }
    }

    if did_sanitize { Some(output) } else { None }
}

/// Port of `encodeUserMessage(text:sessionID:)`.
pub fn encode_user_message(text: &str, session_id: Option<&str>) -> Vec<u8> {
    let mut payload = serde_json::json!({
        "type": "user",
        "message": {
            "role": "user",
            "content": [{"type": "text", "text": text}]
        },
        "parent_tool_use_id": Value::Null,
    });
    if let Some(session_id) = session_id {
        if !session_id.is_empty() {
            payload["session_id"] = Value::String(session_id.to_string());
        }
    }
    serde_json::to_vec(&payload).expect("payload is a valid JSON value")
}

/// Port of `encodeControlRequest(requestID:request:)`.
pub fn encode_control_request(request_id: &str, request: &Map<String, Value>) -> Vec<u8> {
    let payload = serde_json::json!({
        "type": "control_request",
        "request_id": request_id,
        "request": request,
    });
    serde_json::to_vec(&payload).expect("payload is a valid JSON value")
}

/// Port of `encodeControlResponseSuccess(requestID:response:)`.
pub fn encode_control_response_success(
    request_id: &str,
    response: Option<&Map<String, Value>>,
) -> Vec<u8> {
    let mut envelope = serde_json::json!({
        "subtype": "success",
        "request_id": request_id,
    });
    if let Some(response) = response {
        if !response.is_empty() {
            envelope["response"] = Value::Object(response.clone());
        }
    }
    let payload = serde_json::json!({
        "type": "control_response",
        "response": envelope,
    });
    serde_json::to_vec(&payload).expect("payload is a valid JSON value")
}

/// Port of `encodeControlResponseError(requestID:error:)`.
pub fn encode_control_response_error(request_id: &str, error: &str) -> Vec<u8> {
    let payload = serde_json::json!({
        "type": "control_response",
        "response": {
            "subtype": "error",
            "request_id": request_id,
            "error": error,
        }
    });
    serde_json::to_vec(&payload).expect("payload is a valid JSON value")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_or_whitespace_line_decodes_to_none() {
        assert_eq!(decode_line(b"").unwrap(), None);
        assert_eq!(decode_line(b"   \t\r\n  ").unwrap(), None);
    }

    #[test]
    fn control_request_round_trips_through_own_encoder() {
        let mut request = Map::new();
        request.insert(
            "subtype".to_string(),
            Value::String("can_use_tool".to_string()),
        );
        request.insert("tool_name".to_string(), Value::String("Bash".to_string()));
        let encoded = encode_control_request("req-1", &request);
        let decoded = decode_line(&encoded).unwrap().unwrap();
        match decoded {
            InboundMessage::ControlRequest(req) => {
                assert_eq!(req.request_id, "req-1");
                assert_eq!(req.subtype, "can_use_tool");
                assert_eq!(
                    req.request.get("tool_name").and_then(Value::as_str),
                    Some("Bash")
                );
            }
            other => panic!("expected ControlRequest, got {other:?}"),
        }
    }

    #[test]
    fn control_response_missing_request_id_is_unsupported_payload() {
        let line = br#"{"type":"control_response","response":{"subtype":"success"}}"#;
        assert_eq!(decode_line(line), Err(CodecError::UnsupportedPayload));
    }

    #[test]
    fn keep_alive_and_control_cancel_decode() {
        assert_eq!(
            decode_line(br#"{"type":"keep_alive"}"#).unwrap(),
            Some(InboundMessage::KeepAlive)
        );
        assert_eq!(
            decode_line(br#"{"type":"control_cancel_request","request_id":"req-9"}"#).unwrap(),
            Some(InboundMessage::ControlCancelRequest {
                request_id: "req-9".to_string()
            })
        );
    }

    #[test]
    fn unknown_type_is_a_stream_payload() {
        let decoded = decode_line(br#"{"type":"assistant","message":{}}"#)
            .unwrap()
            .unwrap();
        assert!(matches!(decoded, InboundMessage::StreamPayload(_)));
    }

    #[test]
    fn top_level_non_object_json_is_invalid_not_unsupported() {
        // A syntactically valid JSON array is still `.invalidJSON` per the codec's own contract
        // (§2.1): it never reaches the `type`-dispatch switch at all.
        assert_eq!(decode_line(b"[1,2,3]"), Err(CodecError::InvalidJson));
    }

    #[test]
    fn embedded_raw_lf_inside_a_string_is_repaired_by_the_codecs_own_sanitize_pass() {
        let line =
            b"{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"line one\nline two\"}";
        let decoded = decode_line(line).unwrap().unwrap();
        match decoded {
            InboundMessage::StreamPayload(payload) => {
                assert_eq!(
                    payload.get("status").and_then(Value::as_str),
                    Some("line one\nline two")
                );
            }
            other => panic!("expected StreamPayload, got {other:?}"),
        }
    }

    #[test]
    fn genuinely_invalid_utf8_is_invalid_json_even_after_sanitize_attempt() {
        let mut line = br#"{"type":"system","subtype":"status","status":""#.to_vec();
        line.push(0xFF); // lone invalid UTF-8 byte inside the string
        line.extend_from_slice(br#""}"#);
        assert_eq!(decode_line(&line), Err(CodecError::InvalidJson));
    }
}
