//! JSON helpers shared by the Codex/ACP classifiers and the permission matcher.
//!
//! Inputs are already-parsed `serde_json::Value` trees. The JSON-RPC transport
//! (`provider_json_rpc`) is the untrusted-byte boundary; this layer does not
//! decode wire frames.

use serde_json::{Map, Value};

/// Trim a JSON string; empty after trim is `None`.
#[must_use]
pub fn trimmed_string(value: Option<&Value>) -> Option<String> {
    let Value::String(text) = value? else {
        return None;
    };
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// First non-empty string among `keys` at the object root.
#[must_use]
pub fn first_string(object: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(text) = trimmed_string(object.get(*key)) {
            return Some(text);
        }
    }
    None
}

/// Walk a dotted object path (`["rawInput", "title"]`) and return the leaf.
#[must_use]
pub fn value_at<'a>(object: &'a Map<String, Value>, path: &[&str]) -> Option<&'a Value> {
    let mut current = object;
    for (index, key) in path.iter().enumerate() {
        let next = current.get(*key)?;
        if index + 1 == path.len() {
            return Some(next);
        }
        current = next.as_object()?;
    }
    None
}

/// Collect unique trimmed strings at `paths`, preserving first-seen order.
#[must_use]
pub fn collect_strings(object: &Map<String, Value>, paths: &[&[&str]]) -> Vec<String> {
    let mut values = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for path in paths {
        if let Some(text) = trimmed_string(value_at(object, path))
            && seen.insert(text.clone())
        {
            values.push(text);
        }
    }
    values
}

/// Recursively extract ACP `content` text (`type == "text"` / nested / arrays / raw string).
#[must_use]
pub fn extract_content_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(text.clone())
            }
        }
        Value::Array(items) => {
            let parts: Vec<String> = items.iter().filter_map(extract_content_text).collect();
            if parts.is_empty() {
                None
            } else {
                Some(parts.join(""))
            }
        }
        Value::Object(object) => {
            let type_name = first_string(object, &["type"]).map(|value| value.to_ascii_lowercase());
            if type_name.as_deref() == Some("text")
                && let Some(text) = object.get("text").and_then(Value::as_str)
            {
                return Some(text.to_string());
            }
            if let Some(nested) = object.get("content") {
                return extract_content_text(nested);
            }
            if let Some(nested) = object.get("output") {
                return extract_content_text(nested);
            }
            None
        }
        _ => None,
    }
}

/// Compact JSON for a value; strings are returned as-is (Swift `serializeJSON`).
#[must_use]
pub fn serialize_json(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Null => None,
        other => serde_json::to_string(other).ok(),
    }
}

/// Parse a JSON object; anything else is `None`.
#[must_use]
pub fn parse_object(raw: &str) -> Option<Map<String, Value>> {
    match serde_json::from_str::<Value>(raw).ok()? {
        Value::Object(object) => Some(object),
        _ => None,
    }
}

/// Best-effort integer (Swift `intValue` / `NSNumber`).
#[must_use]
pub fn int_value(value: &Value) -> Option<i64> {
    match value {
        Value::Number(number) => number
            .as_i64()
            .or_else(|| number.as_u64().and_then(|value| i64::try_from(value).ok()))
            .or_else(|| {
                number.as_f64().and_then(|value| {
                    if value.is_finite() {
                        Some(value as i64)
                    } else {
                        None
                    }
                })
            }),
        Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

/// Best-effort float (Swift `doubleValue`).
#[must_use]
pub fn float_value(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => number.as_f64(),
        Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

/// SHA-256 first 16 bytes as an uppercase hyphenated UUID (Swift `UUID.uuidString`).
#[must_use]
pub fn sha256_uuid(seed: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(seed.as_bytes());
    format_uuid_bytes(&digest[..16])
}

#[must_use]
pub fn format_uuid_bytes(bytes: &[u8]) -> String {
    debug_assert!(bytes.len() >= 16);
    format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn first_string_skips_empty_and_non_strings() {
        let object = json!({"a": "", "b": 1, "c": " ok "})
            .as_object()
            .cloned()
            .unwrap();
        assert_eq!(first_string(&object, &["a", "b", "c"]).as_deref(), Some("ok"));
    }

    #[test]
    fn extract_content_joins_text_parts() {
        let value = json!([
            {"type": "text", "text": "hello "},
            {"type": "text", "text": "world"}
        ]);
        assert_eq!(extract_content_text(&value).as_deref(), Some("hello world"));
    }

    #[test]
    fn sha256_uuid_is_uppercase_hyphenated() {
        let rendered = sha256_uuid("acp-tool|call-1");
        assert_eq!(rendered.len(), 36);
        assert!(rendered.chars().all(|ch| ch.is_ascii_hexdigit() || ch == '-'));
        assert_eq!(&rendered[8..9], "-");
        assert_eq!(rendered, rendered.to_ascii_uppercase());
    }
}
