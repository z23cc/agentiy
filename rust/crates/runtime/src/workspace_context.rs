//! P5-1a read-only workspace/context/selection projection.
//!
//! Contract: `docs/spec/rust-workspace-document-projection-v1.md`. This module is deliberately
//! pure: it parses one complete byte buffer, retains nothing, and performs no filesystem or
//! mutation-authority work.

use serde_json::{Map, Value};
use std::collections::HashSet;
use std::fmt;

pub const WORKSPACE_DOCUMENT_PROJECTION_CONTRACT_VERSION_V1: u16 = 1;
pub const MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1: usize = 32 * 1024 * 1024;
pub const MAXIMUM_SUPPORTED_WORKSPACE_SCHEMA_VERSION: i64 = 1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceContextProjection {
    pub context_id: String,
    pub name: String,
    pub active_agent_session_id: Option<String>,
    pub active_chat_session_id: Option<String>,
    pub prompt: String,
    pub selection: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceDocumentProjection {
    pub workspace_id: String,
    pub schema_version: i64,
    pub name: String,
    pub repo_paths: Vec<String>,
    pub active_context_id: Option<String>,
    pub contexts: Vec<WorkspaceContextProjection>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceDocumentProjectionError {
    InputTooLarge {
        actual_bytes: usize,
        maximum_bytes: usize,
    },
    InvalidTopLevel,
    MissingWorkspaceId,
    FutureSchema(i64),
    InvalidContext(Option<String>),
}

impl fmt::Display for WorkspaceDocumentProjectionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InputTooLarge {
                actual_bytes,
                maximum_bytes,
            } => write!(
                formatter,
                "workspace document has {actual_bytes} bytes; maximum is {maximum_bytes}"
            ),
            Self::InvalidTopLevel => {
                formatter.write_str("workspace document must be a JSON object")
            }
            Self::MissingWorkspaceId => formatter.write_str("workspace document has no valid id"),
            Self::FutureSchema(version) => {
                write!(formatter, "workspace schema {version} is unsupported")
            }
            Self::InvalidContext(None) => formatter.write_str("workspace context has no valid id"),
            Self::InvalidContext(Some(id)) => {
                write!(formatter, "workspace context id {id} is duplicated")
            }
        }
    }
}

impl std::error::Error for WorkspaceDocumentProjectionError {}

pub fn project_workspace_document_v1(
    document_bytes: &[u8],
) -> Result<WorkspaceDocumentProjection, WorkspaceDocumentProjectionError> {
    if document_bytes.len() > MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1 {
        return Err(WorkspaceDocumentProjectionError::InputTooLarge {
            actual_bytes: document_bytes.len(),
            maximum_bytes: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
        });
    }
    let value: Value = serde_json::from_slice(document_bytes)
        .map_err(|_| WorkspaceDocumentProjectionError::InvalidTopLevel)?;
    let object = value
        .as_object()
        .ok_or(WorkspaceDocumentProjectionError::InvalidTopLevel)?;
    let workspace_id = required_uuid(object.get("id"))
        .ok_or(WorkspaceDocumentProjectionError::MissingWorkspaceId)?;
    let schema_version = schema_version(object)?;

    let mut seen_context_ids = HashSet::new();
    let mut contexts = Vec::new();
    if let Some(raw_contexts) = object.get("composeTabs").and_then(Value::as_array) {
        contexts.reserve(raw_contexts.len());
        for raw_context in raw_contexts {
            let context = raw_context
                .as_object()
                .ok_or(WorkspaceDocumentProjectionError::InvalidContext(None))?;
            let context_id = required_uuid(context.get("id"))
                .ok_or(WorkspaceDocumentProjectionError::InvalidContext(None))?;
            if !seen_context_ids.insert(context_id.clone()) {
                return Err(WorkspaceDocumentProjectionError::InvalidContext(Some(
                    context_id,
                )));
            }
            contexts.push(project_context(context_id, context));
        }
    }

    Ok(WorkspaceDocumentProjection {
        workspace_id,
        schema_version,
        name: string_or(object.get("name"), "Untitled Workspace"),
        repo_paths: all_strings(object.get("repoPaths")).unwrap_or_default(),
        active_context_id: optional_uuid(object.get("activeComposeTabID")),
        contexts,
    })
}

fn project_context(context_id: String, context: &Map<String, Value>) -> WorkspaceContextProjection {
    let selection = all_strings(context.get("selectedPaths"))
        .or_else(|| all_strings(context.get("selection")))
        .unwrap_or_default();
    WorkspaceContextProjection {
        context_id,
        name: string_or(context.get("name"), "Untitled"),
        active_agent_session_id: optional_uuid(context.get("activeAgentSessionID")),
        active_chat_session_id: optional_uuid(context.get("activeChatSessionID")),
        prompt: string_or(context.get("prompt"), ""),
        selection,
    }
}

fn schema_version(object: &Map<String, Value>) -> Result<i64, WorkspaceDocumentProjectionError> {
    let version = match object.get("schemaVersion") {
        Some(Value::Number(number)) => number
            .as_i64()
            .or_else(|| {
                number
                    .as_u64()
                    .map(|value| i64::try_from(value).unwrap_or(i64::MAX))
            })
            .or_else(|| number.as_f64().map(|value| value.trunc() as i64))
            .unwrap_or(1),
        Some(Value::Bool(value)) => i64::from(*value),
        _ => 1,
    };
    if version > MAXIMUM_SUPPORTED_WORKSPACE_SCHEMA_VERSION {
        Err(WorkspaceDocumentProjectionError::FutureSchema(version))
    } else {
        Ok(version)
    }
}

fn string_or(value: Option<&Value>, fallback: &str) -> String {
    value.and_then(Value::as_str).unwrap_or(fallback).to_owned()
}

fn all_strings(value: Option<&Value>) -> Option<Vec<String>> {
    value?
        .as_array()?
        .iter()
        .map(|item| item.as_str().map(str::to_owned))
        .collect()
}

fn required_uuid(value: Option<&Value>) -> Option<String> {
    canonical_uuid(value?.as_str()?)
}

fn optional_uuid(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).and_then(canonical_uuid)
}

fn canonical_uuid(value: &str) -> Option<String> {
    if value.len() != 36
        || !value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
    {
        return None;
    }
    Some(value.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORKSPACE_ID: &str = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
    const CONTEXT_A: &str = "11111111-2222-3333-4444-555555555555";
    const CONTEXT_B: &str = "66666666-7777-8888-9999-AAAAAAAAAAAA";

    #[test]
    fn projects_order_prompt_selection_aliases_and_optional_identities() {
        let bytes = format!(
            r#"{{
                "id":"{WORKSPACE_ID}",
                "schemaVersion":1,
                "name":"Workspace",
                "repoPaths":["/a","/b"],
                "activeComposeTabID":"{CONTEXT_B}",
                "composeTabs":[
                    {{
                        "id":"{CONTEXT_A}",
                        "name":"First",
                        "prompt":"alpha",
                        "selectedPaths":["A.swift","B.swift"],
                        "selection":["legacy-ignored"],
                        "activeAgentSessionID":"BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF",
                        "activeChatSessionID":"not-a-uuid"
                    }},
                    {{
                        "id":"{CONTEXT_B}",
                        "name":"Second",
                        "selection":["Legacy.swift"]
                    }}
                ]
            }}"#
        );
        let projected = project_workspace_document_v1(bytes.as_bytes()).expect("projection");

        assert_eq!(
            projected.workspace_id,
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        );
        assert_eq!(projected.repo_paths, ["/a", "/b"]);
        assert_eq!(
            projected.active_context_id.as_deref(),
            Some("66666666-7777-8888-9999-aaaaaaaaaaaa")
        );
        assert_eq!(
            projected
                .contexts
                .iter()
                .map(|context| context.context_id.as_str())
                .collect::<Vec<_>>(),
            [
                "11111111-2222-3333-4444-555555555555",
                "66666666-7777-8888-9999-aaaaaaaaaaaa"
            ]
        );
        assert_eq!(projected.contexts[0].prompt, "alpha");
        assert_eq!(projected.contexts[0].selection, ["A.swift", "B.swift"]);
        assert_eq!(
            projected.contexts[0].active_agent_session_id.as_deref(),
            Some("bbbbbbbb-cccc-dddd-eeee-ffffffffffff")
        );
        assert_eq!(projected.contexts[0].active_chat_session_id, None);
        assert_eq!(projected.contexts[1].prompt, "");
        assert_eq!(projected.contexts[1].selection, ["Legacy.swift"]);
    }

    #[test]
    fn defaults_missing_and_malformed_optional_fields_without_partial_arrays() {
        let bytes = format!(
            r#"{{
                "id":"{WORKSPACE_ID}",
                "schemaVersion":"not-a-number",
                "repoPaths":["/valid",7],
                "activeComposeTabID":"invalid",
                "composeTabs":[{{
                    "id":"{CONTEXT_A}",
                    "selectedPaths":["valid",7],
                    "selection":["fallback"]
                }}]
            }}"#
        );
        let projected = project_workspace_document_v1(bytes.as_bytes()).expect("projection");

        assert_eq!(projected.schema_version, 1);
        assert_eq!(projected.name, "Untitled Workspace");
        assert!(projected.repo_paths.is_empty());
        assert_eq!(projected.active_context_id, None);
        assert_eq!(projected.contexts[0].name, "Untitled");
        assert_eq!(projected.contexts[0].selection, ["fallback"]);
    }

    #[test]
    fn coerces_numeric_and_boolean_schema_like_swift_nsnumber() {
        for (literal, expected) in [("false", 0), ("true", 1)] {
            let boolean = format!(r#"{{"id":"{WORKSPACE_ID}","schemaVersion":{literal}}}"#);
            assert_eq!(
                project_workspace_document_v1(boolean.as_bytes())
                    .expect("Foundation booleans bridge through NSNumber")
                    .schema_version,
                expected
            );
        }
        let accepted = format!(r#"{{"id":"{WORKSPACE_ID}","schemaVersion":1.9}}"#);
        assert_eq!(
            project_workspace_document_v1(accepted.as_bytes())
                .expect("fractional schema truncates toward zero")
                .schema_version,
            1
        );
        let future = format!(r#"{{"id":"{WORKSPACE_ID}","schemaVersion":2.1}}"#);
        assert_eq!(
            project_workspace_document_v1(future.as_bytes()),
            Err(WorkspaceDocumentProjectionError::FutureSchema(2))
        );
    }

    #[test]
    fn missing_or_non_array_contexts_are_empty() {
        for bytes in [
            format!(r#"{{"id":"{WORKSPACE_ID}"}}"#),
            format!(r#"{{"id":"{WORKSPACE_ID}","composeTabs":{{}}}}"#),
        ] {
            let projected = project_workspace_document_v1(bytes.as_bytes()).expect("projection");
            assert!(projected.contexts.is_empty());
        }
    }

    #[test]
    fn rejects_oversized_input_before_json_parsing() {
        let oversized = vec![b' '; MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1 + 1];
        assert_eq!(
            project_workspace_document_v1(&oversized),
            Err(WorkspaceDocumentProjectionError::InputTooLarge {
                actual_bytes: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1 + 1,
                maximum_bytes: MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1,
            })
        );
    }

    #[test]
    fn rejects_top_level_identity_future_schema_and_invalid_contexts() {
        assert_eq!(
            project_workspace_document_v1(b"[]"),
            Err(WorkspaceDocumentProjectionError::InvalidTopLevel)
        );
        assert_eq!(
            project_workspace_document_v1(br#"{"name":"missing"}"#),
            Err(WorkspaceDocumentProjectionError::MissingWorkspaceId)
        );
        let future = format!(r#"{{"id":"{WORKSPACE_ID}","schemaVersion":2}}"#);
        assert_eq!(
            project_workspace_document_v1(future.as_bytes()),
            Err(WorkspaceDocumentProjectionError::FutureSchema(2))
        );
        let missing_context =
            format!(r#"{{"id":"{WORKSPACE_ID}","composeTabs":[{{"name":"missing"}}]}}"#);
        assert_eq!(
            project_workspace_document_v1(missing_context.as_bytes()),
            Err(WorkspaceDocumentProjectionError::InvalidContext(None))
        );
        let duplicate = format!(
            r#"{{"id":"{WORKSPACE_ID}","composeTabs":[{{"id":"{CONTEXT_A}"}},{{"id":"{CONTEXT_A}"}}]}}"#
        );
        assert_eq!(
            project_workspace_document_v1(duplicate.as_bytes()),
            Err(WorkspaceDocumentProjectionError::InvalidContext(Some(
                CONTEXT_A.to_ascii_lowercase()
            )))
        );
    }
}
