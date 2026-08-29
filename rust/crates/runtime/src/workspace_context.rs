//! P5 workspace/context projection values and aggregate preparation substrate.
//!
//! Contract: `docs/spec/rust-workspace-document-projection-v1.md`. The pure document projector
//! and bounded immutable catalog preparation are shared by the prepared command-admission
//! aggregate. P5-7i retired the independently stateful scope, snapshot-handle, and checkpoint
//! compatibility plane; this module performs no filesystem I/O and owns no runtime lifecycle.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet, VecDeque};
use std::fmt;
use std::sync::{Arc, Mutex};

pub const WORKSPACE_DOCUMENT_PROJECTION_CONTRACT_VERSION_V1: u16 = 1;
pub const MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1: usize = 32 * 1024 * 1024;
pub const MAXIMUM_SUPPORTED_WORKSPACE_SCHEMA_VERSION: i64 = 1;
pub const DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_COUNT: usize = 256;
pub const DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_RETAINED_BYTES: usize = 64 * 1024 * 1024;
pub const MAXIMUM_WORKSPACE_PROJECTION_PUBLICATION_EVENT_COUNT: usize = 256;
pub const MAXIMUM_WORKSPACE_PROJECTION_HEALTH_REASON_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceContextProjection {
    pub context_id: String,
    pub name: String,
    pub active_agent_session_id: Option<String>,
    pub active_chat_session_id: Option<String>,
    pub prompt: String,
    pub selection: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceDocumentProjection {
    pub workspace_id: String,
    pub schema_version: i64,
    pub name: String,
    pub repo_paths: Vec<String>,
    pub active_context_id: Option<String>,
    pub contexts: Vec<WorkspaceContextProjection>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceProjectionHealthKind {
    Writable,
    ExternalConflict,
    DegradedReadOnly,
    Removed,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceProjectionHealth {
    pub kind: WorkspaceProjectionHealthKind,
    pub reason: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceProjectionRevisionState {
    pub working_revision: u64,
    pub saved_revision: u64,
    pub dirty_revision: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceContextAuthorityState {
    pub context_id: String,
    pub revisions: WorkspaceProjectionRevisionState,
    pub health: WorkspaceProjectionHealth,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceProjectionAuthorityState {
    pub revisions: WorkspaceProjectionRevisionState,
    pub health: WorkspaceProjectionHealth,
    pub contexts: Vec<WorkspaceContextAuthorityState>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceProjectionPublishedWorkspace {
    pub document_bytes: Vec<u8>,
    pub authority: WorkspaceProjectionAuthorityState,
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WorkspaceProjectionCatalogLimits {
    pub maximum_workspace_count: usize,
    pub maximum_retained_bytes: usize,
}

impl Default for WorkspaceProjectionCatalogLimits {
    fn default() -> Self {
        Self {
            maximum_workspace_count: DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_COUNT,
            maximum_retained_bytes: DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_RETAINED_BYTES,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceProjectionEntry {
    /// Canonical document bytes retained by the Rust authority so transaction-owned publication
    /// can merge an updated target row with the immutable non-target aggregate without asking Swift
    /// to reconstruct semantic candidates.
    pub document_bytes: Vec<u8>,
    pub content_digest: String,
    pub retained_bytes: usize,
    pub projection: WorkspaceDocumentProjection,
    pub authority: Option<WorkspaceProjectionAuthorityState>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceProjectionSnapshot {
    pub generation: u64,
    pub retained_bytes: usize,
    /// Canonical workspace-id order. Entries and their semantic projections are immutable.
    pub entries: Vec<Arc<WorkspaceProjectionEntry>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceProjectionMutationReceipt {
    pub previous_generation: u64,
    pub generation: u64,
    pub changed: bool,
    pub snapshot: Arc<WorkspaceProjectionSnapshot>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceProjectionPublicationKind {
    Bootstrapped,
    WorkspaceCreated,
    WorkspaceDeleted,
    WorkingStateCommitted,
    SavedDocumentCommitted,
    ExternalReloaded,
    ExternalConflict,
    Degraded,
    RoutingChanged,
    OperationDeduplicated,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceProjectionPublicationEvent {
    pub sequence: u64,
    pub catalog_revision: u64,
    pub kind: WorkspaceProjectionPublicationKind,
    pub workspace_id: Option<String>,
    pub context_id: Option<String>,
    pub operation_id: Option<String>,
    pub revisions: Option<WorkspaceProjectionRevisionState>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceProjectionPublicationState {
    pub catalog_revision: u64,
    pub publication_sequence: u64,
    pub event_log_floor_sequence: u64,
    pub events: VecDeque<WorkspaceProjectionPublicationEvent>,
}

impl Default for WorkspaceProjectionPublicationState {
    fn default() -> Self {
        Self {
            catalog_revision: 0,
            publication_sequence: 0,
            event_log_floor_sequence: 1,
            events: VecDeque::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceProjectionCatalogError {
    Projection(WorkspaceDocumentProjectionError),
    GenerationMismatch { expected: u64, actual: u64 },
    DuplicateWorkspaceId(String),
    WorkspaceCapacityExceeded { actual: usize, maximum: usize },
    RetainedBytesExceeded { actual: usize, maximum: usize },
    GenerationExhausted,
    InvalidAuthorityState,
    StateUnavailable,
}

impl fmt::Display for WorkspaceProjectionCatalogError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Projection(error) => write!(formatter, "workspace projection failed: {error}"),
            Self::GenerationMismatch { expected, actual } => write!(
                formatter,
                "workspace projection generation mismatch: expected {expected}, actual {actual}"
            ),
            Self::DuplicateWorkspaceId(workspace_id) => {
                write!(
                    formatter,
                    "workspace id {workspace_id} occurs more than once"
                )
            }
            Self::WorkspaceCapacityExceeded { actual, maximum } => write!(
                formatter,
                "workspace projection catalog has {actual} workspaces; maximum is {maximum}"
            ),
            Self::RetainedBytesExceeded { actual, maximum } => write!(
                formatter,
                "workspace projection catalog retains {actual} bytes; maximum is {maximum}"
            ),
            Self::GenerationExhausted => {
                formatter.write_str("workspace projection generation is exhausted")
            }
            Self::InvalidAuthorityState => {
                formatter.write_str("workspace projection authority state is invalid")
            }
            Self::StateUnavailable => {
                formatter.write_str("workspace projection catalog state is unavailable")
            }
        }
    }
}

impl std::error::Error for WorkspaceProjectionCatalogError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Projection(error) => Some(error),
            _ => None,
        }
    }
}

impl From<WorkspaceDocumentProjectionError> for WorkspaceProjectionCatalogError {
    fn from(error: WorkspaceDocumentProjectionError) -> Self {
        Self::Projection(error)
    }
}

struct WorkspaceProjectionCatalogState {
    entries_by_workspace_id: BTreeMap<String, Arc<WorkspaceProjectionEntry>>,
    snapshot: Arc<WorkspaceProjectionSnapshot>,
}

/// Bounded immutable catalog preparation shared by the prepared admission aggregate. The catalog
/// is intentionally local to one preparation; runtime authority and lifecycle remain in the
/// aggregate that consumes the returned snapshot.
pub struct WorkspaceProjectionCatalog {
    limits: WorkspaceProjectionCatalogLimits,
    state: Mutex<WorkspaceProjectionCatalogState>,
}

impl WorkspaceProjectionCatalog {
    pub fn new(limits: WorkspaceProjectionCatalogLimits) -> Self {
        Self {
            limits,
            state: Mutex::new(WorkspaceProjectionCatalogState {
                entries_by_workspace_id: BTreeMap::new(),
                snapshot: Arc::new(WorkspaceProjectionSnapshot {
                    generation: 0,
                    retained_bytes: 0,
                    entries: Vec::new(),
                }),
            }),
        }
    }

    pub fn snapshot(
        &self,
    ) -> Result<Arc<WorkspaceProjectionSnapshot>, WorkspaceProjectionCatalogError> {
        let state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionCatalogError::StateUnavailable)?;
        Ok(Arc::clone(&state.snapshot))
    }

    pub fn replace_published_workspaces(
        &self,
        expected_generation: u64,
        workspaces: &[WorkspaceProjectionPublishedWorkspace],
    ) -> Result<WorkspaceProjectionMutationReceipt, WorkspaceProjectionCatalogError> {
        if workspaces.len() > self.limits.maximum_workspace_count {
            return Err(WorkspaceProjectionCatalogError::WorkspaceCapacityExceeded {
                actual: workspaces.len(),
                maximum: self.limits.maximum_workspace_count,
            });
        }
        let mut raw_input_bytes = 0usize;
        let mut prepared = BTreeMap::new();
        for workspace in workspaces {
            raw_input_bytes = raw_input_bytes.saturating_add(workspace.document_bytes.len());
            if raw_input_bytes > self.limits.maximum_retained_bytes {
                return Err(WorkspaceProjectionCatalogError::RetainedBytesExceeded {
                    actual: raw_input_bytes,
                    maximum: self.limits.maximum_retained_bytes,
                });
            }
            let entry = Arc::new(prepare_projection_entry(
                &workspace.document_bytes,
                Some(workspace.authority.clone()),
            )?);
            let workspace_id = entry.projection.workspace_id.clone();
            if prepared.insert(workspace_id.clone(), entry).is_some() {
                return Err(WorkspaceProjectionCatalogError::DuplicateWorkspaceId(
                    workspace_id,
                ));
            }
        }
        let retained_bytes = self.validate_capacity(&prepared)?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionCatalogError::StateUnavailable)?;
        let actual_generation = state.snapshot.generation;
        if actual_generation != expected_generation {
            return Err(WorkspaceProjectionCatalogError::GenerationMismatch {
                expected: expected_generation,
                actual: actual_generation,
            });
        }
        if entries_have_same_content(&state.entries_by_workspace_id, &prepared) {
            return Ok(WorkspaceProjectionMutationReceipt {
                previous_generation: actual_generation,
                generation: actual_generation,
                changed: false,
                snapshot: Arc::clone(&state.snapshot),
            });
        }
        let generation = actual_generation
            .checked_add(1)
            .ok_or(WorkspaceProjectionCatalogError::GenerationExhausted)?;
        let snapshot = Arc::new(WorkspaceProjectionSnapshot {
            generation,
            retained_bytes,
            entries: prepared.values().cloned().collect(),
        });
        state.entries_by_workspace_id = prepared;
        state.snapshot = Arc::clone(&snapshot);
        Ok(WorkspaceProjectionMutationReceipt {
            previous_generation: actual_generation,
            generation,
            changed: true,
            snapshot,
        })
    }

    fn validate_capacity(
        &self,
        entries: &BTreeMap<String, Arc<WorkspaceProjectionEntry>>,
    ) -> Result<usize, WorkspaceProjectionCatalogError> {
        if entries.len() > self.limits.maximum_workspace_count {
            return Err(WorkspaceProjectionCatalogError::WorkspaceCapacityExceeded {
                actual: entries.len(),
                maximum: self.limits.maximum_workspace_count,
            });
        }
        let retained_bytes = entries.values().fold(0usize, |total, entry| {
            total.saturating_add(entry.retained_bytes)
        });
        if retained_bytes > self.limits.maximum_retained_bytes {
            return Err(WorkspaceProjectionCatalogError::RetainedBytesExceeded {
                actual: retained_bytes,
                maximum: self.limits.maximum_retained_bytes,
            });
        }
        Ok(retained_bytes)
    }
}

fn prepare_projection_entry(
    document: &[u8],
    authority: Option<WorkspaceProjectionAuthorityState>,
) -> Result<WorkspaceProjectionEntry, WorkspaceProjectionCatalogError> {
    let projection = project_workspace_document_v1(document)?;
    if authority
        .as_ref()
        .is_some_and(|authority| !is_valid_authority_state(&projection, authority))
    {
        return Err(WorkspaceProjectionCatalogError::InvalidAuthorityState);
    }
    let content_digest = format!("{:x}", Sha256::digest(document));
    let retained_bytes =
        projection_retained_bytes(&projection, authority.as_ref(), content_digest.len());
    Ok(WorkspaceProjectionEntry {
        document_bytes: document.to_vec(),
        content_digest,
        retained_bytes,
        projection,
        authority,
    })
}

fn projection_retained_bytes(
    projection: &WorkspaceDocumentProjection,
    authority: Option<&WorkspaceProjectionAuthorityState>,
    digest_bytes: usize,
) -> usize {
    const STRING_OVERHEAD: usize = 32;
    const PROJECTION_OVERHEAD: usize = 256;
    const CONTEXT_OVERHEAD: usize = 192;

    fn string_cost(value: &str) -> usize {
        value.len().saturating_add(STRING_OVERHEAD)
    }

    let mut total = PROJECTION_OVERHEAD.saturating_add(digest_bytes);
    total = total.saturating_add(string_cost(&projection.workspace_id));
    total = total.saturating_add(string_cost(&projection.name));
    for path in &projection.repo_paths {
        total = total.saturating_add(string_cost(path));
    }
    if let Some(active_context_id) = &projection.active_context_id {
        total = total.saturating_add(string_cost(active_context_id));
    }
    for context in &projection.contexts {
        total = total.saturating_add(CONTEXT_OVERHEAD);
        total = total.saturating_add(string_cost(&context.context_id));
        total = total.saturating_add(string_cost(&context.name));
        total = total.saturating_add(string_cost(&context.prompt));
        if let Some(session_id) = &context.active_agent_session_id {
            total = total.saturating_add(string_cost(session_id));
        }
        if let Some(session_id) = &context.active_chat_session_id {
            total = total.saturating_add(string_cost(session_id));
        }
        for path in &context.selection {
            total = total.saturating_add(string_cost(path));
        }
    }
    if let Some(authority) = authority {
        const AUTHORITY_OVERHEAD: usize = 128;
        const CONTEXT_AUTHORITY_OVERHEAD: usize = 96;
        total = total.saturating_add(AUTHORITY_OVERHEAD);
        total = total.saturating_add(health_retained_bytes(&authority.health));
        for context in &authority.contexts {
            total = total.saturating_add(CONTEXT_AUTHORITY_OVERHEAD);
            total = total.saturating_add(string_cost(&context.context_id));
            total = total.saturating_add(health_retained_bytes(&context.health));
        }
    }
    total
}

fn health_retained_bytes(health: &WorkspaceProjectionHealth) -> usize {
    const STRING_OVERHEAD: usize = 32;
    health
        .reason
        .as_ref()
        .map_or(0, |reason| reason.len().saturating_add(STRING_OVERHEAD))
}

fn is_valid_authority_state(
    projection: &WorkspaceDocumentProjection,
    authority: &WorkspaceProjectionAuthorityState,
) -> bool {
    is_valid_revision_state(authority.revisions)
        && is_valid_health(&authority.health)
        && authority.contexts.len() == projection.contexts.len()
        && authority
            .contexts
            .iter()
            .zip(&projection.contexts)
            .all(|(authority, context)| {
                authority.context_id == context.context_id
                    && is_valid_revision_state(authority.revisions)
                    && is_valid_health(&authority.health)
            })
}

pub(crate) fn is_valid_revision_state(revisions: WorkspaceProjectionRevisionState) -> bool {
    revisions.saved_revision <= revisions.working_revision
        && revisions
            .dirty_revision
            .is_none_or(|dirty| dirty == revisions.working_revision)
}

fn is_valid_health(health: &WorkspaceProjectionHealth) -> bool {
    match health.kind {
        WorkspaceProjectionHealthKind::Writable | WorkspaceProjectionHealthKind::Removed => {
            health.reason.is_none()
        }
        WorkspaceProjectionHealthKind::ExternalConflict
        | WorkspaceProjectionHealthKind::DegradedReadOnly => {
            health.reason.as_ref().is_some_and(|reason| {
                !reason.is_empty()
                    && reason.len() <= MAXIMUM_WORKSPACE_PROJECTION_HEALTH_REASON_BYTES
            })
        }
    }
}

fn entries_have_same_content(
    left: &BTreeMap<String, Arc<WorkspaceProjectionEntry>>,
    right: &BTreeMap<String, Arc<WorkspaceProjectionEntry>>,
) -> bool {
    left.len() == right.len()
        && left
            .iter()
            .zip(right)
            .all(|((left_id, left_entry), (right_id, right_entry))| {
                left_id == right_id
                    && left_entry.content_digest == right_entry.content_digest
                    && left_entry.authority == right_entry.authority
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

pub(crate) fn canonical_uuid(value: &str) -> Option<String> {
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
        assert_eq!(projected.contexts[0].selection, ["A.swift", "B.swift"]);
        assert_eq!(projected.contexts[1].selection, ["Legacy.swift"]);
        assert_eq!(
            projected.contexts[0].active_agent_session_id.as_deref(),
            Some("bbbbbbbb-cccc-dddd-eeee-ffffffffffff")
        );
        assert_eq!(projected.contexts[0].active_chat_session_id, None);
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
        assert_eq!(projected.contexts[0].selection, ["fallback"]);
    }

    #[test]
    fn coerces_schema_like_swift_nsnumber() {
        for (literal, expected) in [("false", 0), ("true", 1)] {
            let document = format!(r#"{{"id":"{WORKSPACE_ID}","schemaVersion":{literal}}}"#);
            assert_eq!(
                project_workspace_document_v1(document.as_bytes())
                    .expect("boolean schema")
                    .schema_version,
                expected
            );
        }
        let future = format!(r#"{{"id":"{WORKSPACE_ID}","schemaVersion":2.1}}"#);
        assert_eq!(
            project_workspace_document_v1(future.as_bytes()),
            Err(WorkspaceDocumentProjectionError::FutureSchema(2))
        );
    }

    #[test]
    fn rejects_identity_size_and_context_failures() {
        assert_eq!(
            project_workspace_document_v1(b"[]"),
            Err(WorkspaceDocumentProjectionError::InvalidTopLevel)
        );
        assert_eq!(
            project_workspace_document_v1(br#"{"name":"missing"}"#),
            Err(WorkspaceDocumentProjectionError::MissingWorkspaceId)
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
        let oversized = vec![b' '; MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1 + 1];
        assert!(matches!(
            project_workspace_document_v1(&oversized),
            Err(WorkspaceDocumentProjectionError::InputTooLarge { .. })
        ));
    }

    #[test]
    fn authoritative_catalog_preparation_is_atomic_bounded_and_canonical() {
        let catalog = WorkspaceProjectionCatalog::new(WorkspaceProjectionCatalogLimits::default());
        let workspace_b = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";
        let workspaces = [
            published_workspace(workspace_b, "Second"),
            published_workspace(WORKSPACE_ID, "First"),
        ];
        let receipt = catalog
            .replace_published_workspaces(0, &workspaces)
            .expect("authoritative replacement");
        assert!(receipt.changed);
        assert_eq!(receipt.generation, 1);
        assert_eq!(
            receipt
                .snapshot
                .entries
                .iter()
                .map(|entry| entry.projection.workspace_id.as_str())
                .collect::<Vec<_>>(),
            [
                "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
            ]
        );
        let unchanged = catalog
            .replace_published_workspaces(1, &workspaces)
            .expect("exact replacement is a no-op");
        assert!(!unchanged.changed);
        assert!(Arc::ptr_eq(&receipt.snapshot, &unchanged.snapshot));
    }

    #[test]
    fn authoritative_catalog_rejects_invalid_authority_and_capacity_atomically() {
        let catalog = WorkspaceProjectionCatalog::new(WorkspaceProjectionCatalogLimits {
            maximum_workspace_count: 1,
            maximum_retained_bytes: usize::MAX,
        });
        let invalid = WorkspaceProjectionPublishedWorkspace {
            document_bytes: workspace_document(WORKSPACE_ID, "Invalid"),
            authority: WorkspaceProjectionAuthorityState {
                revisions: revision(1),
                health: WorkspaceProjectionHealth {
                    kind: WorkspaceProjectionHealthKind::Writable,
                    reason: Some("invalid".to_owned()),
                },
                contexts: Vec::new(),
            },
        };
        assert_eq!(
            catalog.replace_published_workspaces(0, &[invalid]),
            Err(WorkspaceProjectionCatalogError::InvalidAuthorityState)
        );
        assert_eq!(catalog.snapshot().expect("unchanged").generation, 0);

        let too_many = [
            published_workspace(WORKSPACE_ID, "First"),
            published_workspace("bbbbbbbb-cccc-dddd-eeee-ffffffffffff", "Second"),
        ];
        assert!(matches!(
            catalog.replace_published_workspaces(0, &too_many),
            Err(WorkspaceProjectionCatalogError::WorkspaceCapacityExceeded { maximum: 1, .. })
        ));
        assert_eq!(catalog.snapshot().expect("still unchanged").generation, 0);
    }

    fn published_workspace(
        workspace_id: &str,
        name: &str,
    ) -> WorkspaceProjectionPublishedWorkspace {
        WorkspaceProjectionPublishedWorkspace {
            document_bytes: workspace_document(workspace_id, name),
            authority: WorkspaceProjectionAuthorityState {
                revisions: revision(1),
                health: WorkspaceProjectionHealth {
                    kind: WorkspaceProjectionHealthKind::Writable,
                    reason: None,
                },
                contexts: Vec::new(),
            },
        }
    }

    fn revision(value: u64) -> WorkspaceProjectionRevisionState {
        WorkspaceProjectionRevisionState {
            working_revision: value,
            saved_revision: value,
            dirty_revision: None,
        }
    }

    fn workspace_document(workspace_id: &str, name: &str) -> Vec<u8> {
        format!(r#"{{"id":"{workspace_id}","schemaVersion":1,"name":"{name}"}}"#).into_bytes()
    }
}
