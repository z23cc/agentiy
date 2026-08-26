//! P5 Workspace/context/selection projection and stateful snapshot substrate.
//!
//! Contract: `docs/spec/rust-workspace-document-projection-v1.md`. P5-1's single-document
//! projector remains pure. P5-2a adds an in-memory, generation-CAS catalog of immutable semantic
//! projections; it still performs no filesystem I/O and owns no persistence or writer lease.

use serde::de::{Error as DeError, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet, VecDeque};
use std::fmt;
use std::io::{self, Write};
use std::sync::{Arc, Mutex};

pub const WORKSPACE_DOCUMENT_PROJECTION_CONTRACT_VERSION_V1: u16 = 1;
pub const MAXIMUM_WORKSPACE_DOCUMENT_PROJECTION_BYTES_V1: usize = 32 * 1024 * 1024;
pub const MAXIMUM_SUPPORTED_WORKSPACE_SCHEMA_VERSION: i64 = 1;
pub const DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_COUNT: usize = 256;
pub const DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_RETAINED_BYTES: usize = 64 * 1024 * 1024;
pub const MAXIMUM_WORKSPACE_PROJECTION_PUBLICATION_EVENT_COUNT: usize = 256;
pub const MAXIMUM_WORKSPACE_PROJECTION_HEALTH_REASON_BYTES: usize = 64 * 1024;
pub const WORKSPACE_PROJECTION_CHECKPOINT_SCHEMA_VERSION_V1: u16 = 1;
pub const MAXIMUM_WORKSPACE_PROJECTION_CHECKPOINT_BYTES_V1: usize = 128 * 1024 * 1024;

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
    pub content_digest: String,
    pub retained_bytes: usize,
    pub projection: WorkspaceDocumentProjection,
    /// Complete revision/health authority for this exact row, or `None` after a document-only
    /// observation/checkpoint from before P5-4e. Production reads must reconcile before use.
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceProjectionOpenedSnapshot {
    pub handle_id: WorkspaceProjectionSnapshotHandleId,
    pub snapshot: Arc<WorkspaceProjectionSnapshot>,
    pub catalog_revision: u64,
    pub publication_sequence: u64,
    pub event_log_floor_sequence: u64,
    pub event_log_count: usize,
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
pub struct WorkspaceProjectionPublicationReceipt {
    pub projection: WorkspaceProjectionMutationReceipt,
    pub previous_catalog_revision: u64,
    pub previous_publication_sequence: u64,
    pub catalog_revision: u64,
    pub publication_sequence: u64,
    pub event_log_floor_sequence: u64,
    pub event_log_count: usize,
    pub rebased: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceProjectionCheckpointEntryV1 {
    content_digest: String,
    projection_checksum: String,
    projection: WorkspaceDocumentProjection,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    authority: Option<WorkspaceProjectionAuthorityState>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(transparent)]
struct WorkspaceProjectionCheckpointEntriesV1(Vec<WorkspaceProjectionCheckpointEntryV1>);

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(transparent)]
struct WorkspaceProjectionCheckpointEventsV1(Vec<WorkspaceProjectionPublicationEvent>);

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceProjectionCheckpointV1 {
    version: u16,
    scope_id: String,
    generation: u64,
    catalog_revision: u64,
    publication_sequence: u64,
    event_log_floor_sequence: u64,
    entries: WorkspaceProjectionCheckpointEntriesV1,
    events: WorkspaceProjectionCheckpointEventsV1,
}

struct PreparedWorkspaceProjectionCheckpoint {
    generation: u64,
    entries_by_workspace_id: BTreeMap<String, Arc<WorkspaceProjectionEntry>>,
    publication: WorkspaceProjectionPublicationState,
}

impl<'de> Deserialize<'de> for WorkspaceProjectionCheckpointEntriesV1 {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct EntriesVisitor;

        impl<'de> Visitor<'de> for EntriesVisitor {
            type Value = WorkspaceProjectionCheckpointEntriesV1;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a bounded workspace projection checkpoint entry array")
            }

            fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
            where
                A: SeqAccess<'de>,
            {
                let capacity = sequence
                    .size_hint()
                    .unwrap_or(0)
                    .min(DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_COUNT);
                let mut entries = Vec::with_capacity(capacity);
                let mut retained_bytes = 0usize;
                while let Some(entry) =
                    sequence.next_element::<WorkspaceProjectionCheckpointEntryV1>()?
                {
                    if entries.len() >= DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_COUNT {
                        return Err(A::Error::custom(
                            "workspace checkpoint entry count exceeded",
                        ));
                    }
                    let entry_bytes = projection_retained_bytes(
                        &entry.projection,
                        entry.authority.as_ref(),
                        entry.content_digest.len(),
                    );
                    retained_bytes = retained_bytes.checked_add(entry_bytes).ok_or_else(|| {
                        A::Error::custom("workspace checkpoint retained bytes overflowed")
                    })?;
                    if retained_bytes > DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_RETAINED_BYTES {
                        return Err(A::Error::custom(
                            "workspace checkpoint retained bytes exceeded",
                        ));
                    }
                    entries.push(entry);
                }
                Ok(WorkspaceProjectionCheckpointEntriesV1(entries))
            }
        }

        deserializer.deserialize_seq(EntriesVisitor)
    }
}

impl<'de> Deserialize<'de> for WorkspaceProjectionCheckpointEventsV1 {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct EventsVisitor;

        impl<'de> Visitor<'de> for EventsVisitor {
            type Value = WorkspaceProjectionCheckpointEventsV1;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a bounded workspace projection checkpoint event array")
            }

            fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
            where
                A: SeqAccess<'de>,
            {
                let capacity = sequence
                    .size_hint()
                    .unwrap_or(0)
                    .min(MAXIMUM_WORKSPACE_PROJECTION_PUBLICATION_EVENT_COUNT);
                let mut events = Vec::with_capacity(capacity);
                while let Some(event) =
                    sequence.next_element::<WorkspaceProjectionPublicationEvent>()?
                {
                    if events.len() >= MAXIMUM_WORKSPACE_PROJECTION_PUBLICATION_EVENT_COUNT {
                        return Err(A::Error::custom(
                            "workspace checkpoint event count exceeded",
                        ));
                    }
                    events.push(event);
                }
                Ok(WorkspaceProjectionCheckpointEventsV1(events))
            }
        }

        deserializer.deserialize_seq(EventsVisitor)
    }
}

struct CappedWorkspaceProjectionCheckpointWriter {
    bytes: Vec<u8>,
    maximum_bytes: usize,
    attempted_bytes: usize,
}

impl CappedWorkspaceProjectionCheckpointWriter {
    fn new(maximum_bytes: usize) -> Self {
        Self {
            bytes: Vec::new(),
            maximum_bytes,
            attempted_bytes: 0,
        }
    }
}

struct WorkspaceProjectionCheckpointDigestWriter(Sha256);

impl Write for WorkspaceProjectionCheckpointDigestWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.0.update(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Write for CappedWorkspaceProjectionCheckpointWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let attempted = self
            .bytes
            .len()
            .checked_add(buffer.len())
            .unwrap_or(usize::MAX);
        self.attempted_bytes = self.attempted_bytes.max(attempted);
        if attempted > self.maximum_bytes {
            return Err(io::Error::new(
                io::ErrorKind::FileTooLarge,
                "workspace projection checkpoint exceeded its byte limit",
            ));
        }
        self.bytes.extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceProjectionCatalogError {
    Projection(WorkspaceDocumentProjectionError),
    GenerationMismatch {
        expected: u64,
        actual: u64,
    },
    DuplicateWorkspaceId(String),
    WorkspaceCapacityExceeded {
        actual: usize,
        maximum: usize,
    },
    RetainedBytesExceeded {
        actual: usize,
        maximum: usize,
    },
    GenerationExhausted,
    PublicationCursorMismatch {
        expected_catalog_revision: u64,
        actual_catalog_revision: u64,
        expected_publication_sequence: u64,
        actual_publication_sequence: u64,
    },
    InvalidPublicationSequence {
        expected: u64,
        actual: u64,
    },
    CatalogRevisionRegressed {
        previous: u64,
        next: u64,
    },
    InvalidPublicationIdentity,
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
            Self::PublicationCursorMismatch {
                expected_catalog_revision,
                actual_catalog_revision,
                expected_publication_sequence,
                actual_publication_sequence,
            } => write!(
                formatter,
                "workspace projection publication cursor mismatch: expected catalog {expected_catalog_revision} / sequence {expected_publication_sequence}, actual catalog {actual_catalog_revision} / sequence {actual_publication_sequence}"
            ),
            Self::InvalidPublicationSequence { expected, actual } => write!(
                formatter,
                "workspace projection publication sequence is invalid: expected {expected}, actual {actual}"
            ),
            Self::CatalogRevisionRegressed { previous, next } => write!(
                formatter,
                "workspace projection catalog revision regressed from {previous} to {next}"
            ),
            Self::InvalidPublicationIdentity => {
                formatter.write_str("workspace projection publication identity is invalid")
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

/// P5-2a's stateful Rust substrate. Mutations prepare and validate complete immutable values before
/// acquiring the commit lock, then use exact generation CAS. A failed command never changes the
/// active generation. Snapshots are `Arc` leases, so readers can retain an old generation while a
/// later generation becomes current without copying or observing mixed state.
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

    /// Atomically replaces the complete catalog. Projection, duplicate detection, and capacity
    /// validation happen before the generation CAS; a stale caller can never partially install.
    pub fn replace_documents(
        &self,
        expected_generation: u64,
        documents: &[Vec<u8>],
    ) -> Result<WorkspaceProjectionMutationReceipt, WorkspaceProjectionCatalogError> {
        if documents.len() > self.limits.maximum_workspace_count {
            return Err(WorkspaceProjectionCatalogError::WorkspaceCapacityExceeded {
                actual: documents.len(),
                maximum: self.limits.maximum_workspace_count,
            });
        }
        let mut raw_input_bytes = 0usize;
        let mut prepared = BTreeMap::new();
        for document in documents {
            raw_input_bytes = raw_input_bytes.saturating_add(document.len());
            if raw_input_bytes > self.limits.maximum_retained_bytes {
                return Err(WorkspaceProjectionCatalogError::RetainedBytesExceeded {
                    actual: raw_input_bytes,
                    maximum: self.limits.maximum_retained_bytes,
                });
            }
            let entry = Arc::new(prepare_projection_entry(document, None)?);
            let workspace_id = entry.projection.workspace_id.clone();
            if prepared.insert(workspace_id.clone(), entry).is_some() {
                return Err(WorkspaceProjectionCatalogError::DuplicateWorkspaceId(
                    workspace_id,
                ));
            }
        }
        self.validate_capacity(&prepared)?;

        let mut state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionCatalogError::StateUnavailable)?;
        require_generation(&state, expected_generation)?;
        if entries_have_same_content(&state.entries_by_workspace_id, &prepared) {
            return Ok(unchanged_receipt(&state));
        }
        self.commit_entries(&mut state, prepared)
    }

    /// Atomically replaces the complete catalog with document projections plus their full
    /// revision/health authority sidecars.
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
        self.validate_capacity(&prepared)?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionCatalogError::StateUnavailable)?;
        require_generation(&state, expected_generation)?;
        if entries_have_same_content(&state.entries_by_workspace_id, &prepared) {
            return Ok(unchanged_receipt(&state));
        }
        self.commit_entries(&mut state, prepared)
    }

    /// Inserts or replaces one complete authority row under exact generation CAS. This is used
    /// only to repair an evicted/invalidated row while the enclosing scope cursor remains fixed.
    pub fn upsert_published_workspace(
        &self,
        expected_generation: u64,
        workspace: &WorkspaceProjectionPublishedWorkspace,
    ) -> Result<WorkspaceProjectionMutationReceipt, WorkspaceProjectionCatalogError> {
        let entry = Arc::new(prepare_projection_entry(
            &workspace.document_bytes,
            Some(workspace.authority.clone()),
        )?);
        let workspace_id = entry.projection.workspace_id.clone();
        let mut state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionCatalogError::StateUnavailable)?;
        require_generation(&state, expected_generation)?;
        if state
            .entries_by_workspace_id
            .get(&workspace_id)
            .is_some_and(|current| {
                current.content_digest == entry.content_digest
                    && current.authority == entry.authority
            })
        {
            return Ok(unchanged_receipt(&state));
        }
        let mut prepared = state.entries_by_workspace_id.clone();
        prepared.insert(workspace_id, entry);
        self.validate_capacity(&prepared)?;
        self.commit_entries(&mut state, prepared)
    }

    /// Inserts or replaces one canonical document under exact generation CAS. A changed
    /// document-only row explicitly clears any formerly authoritative revision/health sidecar.
    pub fn upsert_document(
        &self,
        expected_generation: u64,
        document: &[u8],
    ) -> Result<WorkspaceProjectionMutationReceipt, WorkspaceProjectionCatalogError> {
        let entry = Arc::new(prepare_projection_entry(document, None)?);
        let workspace_id = entry.projection.workspace_id.clone();
        let mut state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionCatalogError::StateUnavailable)?;
        require_generation(&state, expected_generation)?;
        if state
            .entries_by_workspace_id
            .get(&workspace_id)
            .is_some_and(|current| current.content_digest == entry.content_digest)
        {
            return Ok(unchanged_receipt(&state));
        }
        let mut prepared = state.entries_by_workspace_id.clone();
        prepared.insert(workspace_id, entry);
        self.validate_capacity(&prepared)?;
        self.commit_entries(&mut state, prepared)
    }

    /// Removes one workspace under exact generation CAS. Removing an absent identity is a no-op.
    pub fn remove_workspace(
        &self,
        expected_generation: u64,
        workspace_id: &str,
    ) -> Result<WorkspaceProjectionMutationReceipt, WorkspaceProjectionCatalogError> {
        let canonical_workspace_id = canonical_uuid(workspace_id)
            .ok_or(WorkspaceDocumentProjectionError::MissingWorkspaceId)?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionCatalogError::StateUnavailable)?;
        require_generation(&state, expected_generation)?;
        if !state
            .entries_by_workspace_id
            .contains_key(&canonical_workspace_id)
        {
            return Ok(unchanged_receipt(&state));
        }
        let mut prepared = state.entries_by_workspace_id.clone();
        prepared.remove(&canonical_workspace_id);
        self.commit_entries(&mut state, prepared)
    }

    fn restore_checkpoint(
        &self,
        generation: u64,
        entries_by_workspace_id: BTreeMap<String, Arc<WorkspaceProjectionEntry>>,
    ) -> Result<Arc<WorkspaceProjectionSnapshot>, WorkspaceProjectionCatalogError> {
        let retained_bytes = self.validate_capacity(&entries_by_workspace_id)?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionCatalogError::StateUnavailable)?;
        require_generation(&state, 0)?;
        if !state.entries_by_workspace_id.is_empty() {
            return Err(WorkspaceProjectionCatalogError::GenerationMismatch {
                expected: 0,
                actual: state.snapshot.generation,
            });
        }
        let snapshot = Arc::new(WorkspaceProjectionSnapshot {
            generation,
            retained_bytes,
            entries: entries_by_workspace_id.values().cloned().collect(),
        });
        state.entries_by_workspace_id = entries_by_workspace_id;
        state.snapshot = Arc::clone(&snapshot);
        Ok(snapshot)
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

    fn commit_entries(
        &self,
        state: &mut WorkspaceProjectionCatalogState,
        entries_by_workspace_id: BTreeMap<String, Arc<WorkspaceProjectionEntry>>,
    ) -> Result<WorkspaceProjectionMutationReceipt, WorkspaceProjectionCatalogError> {
        let previous_generation = state.snapshot.generation;
        let generation = previous_generation
            .checked_add(1)
            .ok_or(WorkspaceProjectionCatalogError::GenerationExhausted)?;
        let retained_bytes = self.validate_capacity(&entries_by_workspace_id)?;
        let snapshot = Arc::new(WorkspaceProjectionSnapshot {
            generation,
            retained_bytes,
            entries: entries_by_workspace_id.values().cloned().collect(),
        });
        state.entries_by_workspace_id = entries_by_workspace_id;
        state.snapshot = Arc::clone(&snapshot);
        Ok(WorkspaceProjectionMutationReceipt {
            previous_generation,
            generation,
            changed: true,
            snapshot,
        })
    }
}

pub const DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_SCOPE_COUNT: usize = 16;
pub const DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_SNAPSHOT_HANDLE_COUNT: usize = 64;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct WorkspaceProjectionSnapshotHandleId(u64);

impl WorkspaceProjectionSnapshotHandleId {
    pub fn from_raw(raw: u64) -> Self {
        Self(raw)
    }

    pub fn raw(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkspaceProjectionScopeError {
    InvalidScopeId,
    ScopeAlreadyOpen(String),
    UnknownScope(String),
    ScopeCapacityExceeded { actual: usize, maximum: usize },
    ScopeClosed(String),
    SnapshotHandleCapacityExceeded { actual: usize, maximum: usize },
    UnknownSnapshotHandle(u64),
    HandleIdExhausted,
    ScopeIncarnationExhausted,
    CheckpointTooLarge { actual: usize, maximum: usize },
    FutureCheckpoint(u16),
    InvalidCheckpoint,
    CheckpointStateConflict,
    StateUnavailable,
    Catalog(WorkspaceProjectionCatalogError),
}

impl fmt::Display for WorkspaceProjectionScopeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidScopeId => formatter.write_str("workspace projection scope id is invalid"),
            Self::ScopeAlreadyOpen(scope_id) => {
                write!(
                    formatter,
                    "workspace projection scope {scope_id} is already open"
                )
            }
            Self::UnknownScope(scope_id) => {
                write!(
                    formatter,
                    "workspace projection scope {scope_id} is unknown"
                )
            }
            Self::ScopeCapacityExceeded { actual, maximum } => write!(
                formatter,
                "workspace projection registry has {actual} scopes; maximum is {maximum}"
            ),
            Self::ScopeClosed(scope_id) => {
                write!(formatter, "workspace projection scope {scope_id} is closed")
            }
            Self::SnapshotHandleCapacityExceeded { actual, maximum } => write!(
                formatter,
                "workspace projection scope has {actual} snapshot handles; maximum is {maximum}"
            ),
            Self::UnknownSnapshotHandle(handle_id) => {
                write!(
                    formatter,
                    "workspace projection snapshot handle {handle_id} is unknown"
                )
            }
            Self::HandleIdExhausted => {
                formatter.write_str("workspace projection snapshot handle ids are exhausted")
            }
            Self::ScopeIncarnationExhausted => {
                formatter.write_str("workspace projection scope incarnations are exhausted")
            }
            Self::CheckpointTooLarge { actual, maximum } => write!(
                formatter,
                "workspace projection checkpoint has {actual} bytes; maximum is {maximum}"
            ),
            Self::FutureCheckpoint(version) => write!(
                formatter,
                "workspace projection checkpoint schema {version} is unsupported"
            ),
            Self::InvalidCheckpoint => {
                formatter.write_str("workspace projection checkpoint is invalid")
            }
            Self::CheckpointStateConflict => formatter.write_str(
                "workspace projection checkpoint recovery requires a pristine empty scope",
            ),
            Self::StateUnavailable => {
                formatter.write_str("workspace projection scope state is unavailable")
            }
            Self::Catalog(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for WorkspaceProjectionScopeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Catalog(error) => Some(error),
            _ => None,
        }
    }
}

impl From<WorkspaceProjectionCatalogError> for WorkspaceProjectionScopeError {
    fn from(error: WorkspaceProjectionCatalogError) -> Self {
        Self::Catalog(error)
    }
}

enum WorkspaceProjectionPublicationInput<'a> {
    Documents(&'a [Vec<u8>]),
    Published(&'a [WorkspaceProjectionPublishedWorkspace]),
}

struct WorkspaceProjectionScopeState {
    closed: bool,
    next_snapshot_handle_id: u64,
    retained_snapshot_bytes: usize,
    snapshots_by_handle_id:
        BTreeMap<WorkspaceProjectionSnapshotHandleId, Arc<WorkspaceProjectionSnapshot>>,
    publication: WorkspaceProjectionPublicationState,
}

/// One explicitly partitioned domain-runtime scope. The scope gate serializes close against catalog
/// commands and handle opens so no mutation can commit after `close` returns.
pub struct WorkspaceProjectionScope {
    scope_id: String,
    scope_incarnation: u64,
    catalog: WorkspaceProjectionCatalog,
    maximum_snapshot_handle_count: usize,
    maximum_snapshot_retained_bytes: usize,
    state: Mutex<WorkspaceProjectionScopeState>,
}

impl WorkspaceProjectionScope {
    pub fn scope_id(&self) -> &str {
        &self.scope_id
    }

    pub fn scope_incarnation(&self) -> u64 {
        self.scope_incarnation
    }

    pub fn replace_documents(
        &self,
        expected_generation: u64,
        documents: &[Vec<u8>],
    ) -> Result<WorkspaceProjectionMutationReceipt, WorkspaceProjectionScopeError> {
        let state = self.lock_open_state()?;
        let receipt = self
            .catalog
            .replace_documents(expected_generation, documents)?;
        drop(state);
        Ok(receipt)
    }

    pub fn upsert_document(
        &self,
        expected_generation: u64,
        document: &[u8],
    ) -> Result<WorkspaceProjectionMutationReceipt, WorkspaceProjectionScopeError> {
        let state = self.lock_open_state()?;
        let receipt = self
            .catalog
            .upsert_document(expected_generation, document)?;
        drop(state);
        Ok(receipt)
    }

    pub fn upsert_published_workspace(
        &self,
        expected_generation: u64,
        expected_catalog_revision: u64,
        expected_publication_sequence: u64,
        workspace: &WorkspaceProjectionPublishedWorkspace,
    ) -> Result<WorkspaceProjectionMutationReceipt, WorkspaceProjectionScopeError> {
        let state = self.lock_open_state()?;
        if state.publication.catalog_revision != expected_catalog_revision
            || state.publication.publication_sequence != expected_publication_sequence
        {
            return Err(WorkspaceProjectionCatalogError::PublicationCursorMismatch {
                expected_catalog_revision,
                actual_catalog_revision: state.publication.catalog_revision,
                expected_publication_sequence,
                actual_publication_sequence: state.publication.publication_sequence,
            }
            .into());
        }
        let receipt = self
            .catalog
            .upsert_published_workspace(expected_generation, workspace)?;
        drop(state);
        Ok(receipt)
    }

    pub fn remove_workspace(
        &self,
        expected_generation: u64,
        workspace_id: &str,
    ) -> Result<WorkspaceProjectionMutationReceipt, WorkspaceProjectionScopeError> {
        let state = self.lock_open_state()?;
        let receipt = self
            .catalog
            .remove_workspace(expected_generation, workspace_id)?;
        drop(state);
        Ok(receipt)
    }

    /// Compatibility publication for document-only projection callers. The resulting rows carry no
    /// revision/health authority sidecar.
    pub fn publish_state(
        &self,
        expected_generation: u64,
        expected_catalog_revision: u64,
        expected_publication_sequence: u64,
        rebased: bool,
        documents: &[Vec<u8>],
        event: WorkspaceProjectionPublicationEvent,
    ) -> Result<WorkspaceProjectionPublicationReceipt, WorkspaceProjectionScopeError> {
        self.publish_state_input(
            expected_generation,
            expected_catalog_revision,
            expected_publication_sequence,
            rebased,
            WorkspaceProjectionPublicationInput::Documents(documents),
            event,
        )
    }

    /// Atomically installs the complete semantic projections, revision/health sidecars, and
    /// Swift-visible publication cursor.
    pub fn publish_authoritative_state(
        &self,
        expected_generation: u64,
        expected_catalog_revision: u64,
        expected_publication_sequence: u64,
        rebased: bool,
        workspaces: &[WorkspaceProjectionPublishedWorkspace],
        event: WorkspaceProjectionPublicationEvent,
    ) -> Result<WorkspaceProjectionPublicationReceipt, WorkspaceProjectionScopeError> {
        self.publish_state_input(
            expected_generation,
            expected_catalog_revision,
            expected_publication_sequence,
            rebased,
            WorkspaceProjectionPublicationInput::Published(workspaces),
            event,
        )
    }

    fn publish_state_input(
        &self,
        expected_generation: u64,
        expected_catalog_revision: u64,
        expected_publication_sequence: u64,
        rebased: bool,
        input: WorkspaceProjectionPublicationInput<'_>,
        event: WorkspaceProjectionPublicationEvent,
    ) -> Result<WorkspaceProjectionPublicationReceipt, WorkspaceProjectionScopeError> {
        let mut state = self.lock_open_state()?;
        validate_publication_event_identities(&event)?;
        let previous_catalog_revision = state.publication.catalog_revision;
        let previous_publication_sequence = state.publication.publication_sequence;
        if expected_catalog_revision != previous_catalog_revision
            || expected_publication_sequence != previous_publication_sequence
        {
            return Err(WorkspaceProjectionCatalogError::PublicationCursorMismatch {
                expected_catalog_revision,
                actual_catalog_revision: previous_catalog_revision,
                expected_publication_sequence,
                actual_publication_sequence: previous_publication_sequence,
            }
            .into());
        }
        let expected_sequence = previous_publication_sequence
            .checked_add(1)
            .ok_or(WorkspaceProjectionCatalogError::GenerationExhausted)?;
        let sequence_is_valid = if rebased {
            event.sequence >= expected_sequence
        } else {
            event.sequence == expected_sequence
        };
        if !sequence_is_valid {
            return Err(
                WorkspaceProjectionCatalogError::InvalidPublicationSequence {
                    expected: expected_sequence,
                    actual: event.sequence,
                }
                .into(),
            );
        }
        if event.catalog_revision < previous_catalog_revision {
            return Err(WorkspaceProjectionCatalogError::CatalogRevisionRegressed {
                previous: previous_catalog_revision,
                next: event.catalog_revision,
            }
            .into());
        }

        let projection = match input {
            WorkspaceProjectionPublicationInput::Documents(documents) => self
                .catalog
                .replace_documents(expected_generation, documents)?,
            WorkspaceProjectionPublicationInput::Published(workspaces) => self
                .catalog
                .replace_published_workspaces(expected_generation, workspaces)?,
        };
        if rebased {
            state.publication.events.clear();
            state.publication.event_log_floor_sequence = event.sequence;
        }
        state.publication.catalog_revision = event.catalog_revision;
        state.publication.publication_sequence = event.sequence;
        state.publication.events.push_back(event);
        while state.publication.events.len() > MAXIMUM_WORKSPACE_PROJECTION_PUBLICATION_EVENT_COUNT
        {
            state.publication.events.pop_front();
        }
        state.publication.event_log_floor_sequence = state
            .publication
            .events
            .front()
            .map(|event| event.sequence)
            .unwrap_or_else(|| state.publication.publication_sequence.saturating_add(1));
        Ok(WorkspaceProjectionPublicationReceipt {
            projection,
            previous_catalog_revision,
            previous_publication_sequence,
            catalog_revision: state.publication.catalog_revision,
            publication_sequence: state.publication.publication_sequence,
            event_log_floor_sequence: state.publication.event_log_floor_sequence,
            event_log_count: state.publication.events.len(),
            rebased,
        })
    }

    pub fn publication_state(
        &self,
    ) -> Result<WorkspaceProjectionPublicationState, WorkspaceProjectionScopeError> {
        let state = self.lock_open_state()?;
        Ok(state.publication.clone())
    }

    pub fn export_checkpoint(&self) -> Result<Vec<u8>, WorkspaceProjectionScopeError> {
        let state = self.lock_open_state()?;
        let snapshot = self.catalog.snapshot()?;
        let entries = snapshot
            .entries
            .iter()
            .map(|entry| {
                Ok(WorkspaceProjectionCheckpointEntryV1 {
                    content_digest: entry.content_digest.clone(),
                    projection_checksum: checkpoint_projection_checksum(
                        &entry.content_digest,
                        &entry.projection,
                        entry.authority.as_ref(),
                    )?,
                    projection: entry.projection.clone(),
                    authority: entry.authority.clone(),
                })
            })
            .collect::<Result<Vec<_>, WorkspaceProjectionScopeError>>()?;
        let checkpoint = WorkspaceProjectionCheckpointV1 {
            version: WORKSPACE_PROJECTION_CHECKPOINT_SCHEMA_VERSION_V1,
            scope_id: self.scope_id.clone(),
            generation: snapshot.generation,
            catalog_revision: state.publication.catalog_revision,
            publication_sequence: state.publication.publication_sequence,
            event_log_floor_sequence: state.publication.event_log_floor_sequence,
            entries: WorkspaceProjectionCheckpointEntriesV1(entries),
            events: WorkspaceProjectionCheckpointEventsV1(
                state.publication.events.iter().cloned().collect(),
            ),
        };
        let mut writer = CappedWorkspaceProjectionCheckpointWriter::new(
            MAXIMUM_WORKSPACE_PROJECTION_CHECKPOINT_BYTES_V1,
        );
        if serde_json::to_writer(&mut writer, &checkpoint).is_err() {
            if writer.attempted_bytes > writer.maximum_bytes {
                return Err(WorkspaceProjectionScopeError::CheckpointTooLarge {
                    actual: writer.attempted_bytes,
                    maximum: writer.maximum_bytes,
                });
            }
            return Err(WorkspaceProjectionScopeError::InvalidCheckpoint);
        }
        Ok(writer.bytes)
    }

    pub fn restore_checkpoint(
        &self,
        checkpoint_bytes: &[u8],
    ) -> Result<Arc<WorkspaceProjectionSnapshot>, WorkspaceProjectionScopeError> {
        self.restore_checkpoint_with_publication_mode(checkpoint_bytes, false)
    }

    /// Restores the exact projection generation/digests after fully validating the persisted event
    /// tail, but intentionally starts a new process-local publication epoch. Swift's domain event
    /// sequence restarts at one after process launch; retaining the old cursor would either invent
    /// cross-process continuity or reject the current bootstrap baseline.
    pub fn restore_checkpoint_for_new_publication_epoch(
        &self,
        checkpoint_bytes: &[u8],
    ) -> Result<Arc<WorkspaceProjectionSnapshot>, WorkspaceProjectionScopeError> {
        self.restore_checkpoint_with_publication_mode(checkpoint_bytes, true)
    }

    fn restore_checkpoint_with_publication_mode(
        &self,
        checkpoint_bytes: &[u8],
        begin_new_publication_epoch: bool,
    ) -> Result<Arc<WorkspaceProjectionSnapshot>, WorkspaceProjectionScopeError> {
        let prepared = prepare_workspace_projection_checkpoint(
            checkpoint_bytes,
            &self.scope_id,
            &self.catalog,
        )?;
        let mut state = self.lock_open_state()?;
        let current = self.catalog.snapshot()?;
        if current.generation != 0
            || !current.entries.is_empty()
            || state.next_snapshot_handle_id != 0
            || !state.snapshots_by_handle_id.is_empty()
            || state.retained_snapshot_bytes != 0
            || state.publication != WorkspaceProjectionPublicationState::default()
        {
            return Err(WorkspaceProjectionScopeError::CheckpointStateConflict);
        }
        let snapshot = self
            .catalog
            .restore_checkpoint(prepared.generation, prepared.entries_by_workspace_id)?;
        state.publication = if begin_new_publication_epoch {
            WorkspaceProjectionPublicationState::default()
        } else {
            prepared.publication
        };
        Ok(snapshot)
    }

    pub fn open_snapshot(
        &self,
        expected_generation: Option<u64>,
    ) -> Result<
        (
            WorkspaceProjectionSnapshotHandleId,
            Arc<WorkspaceProjectionSnapshot>,
        ),
        WorkspaceProjectionScopeError,
    > {
        let opened = self.open_snapshot_with_publication(expected_generation)?;
        Ok((opened.handle_id, opened.snapshot))
    }

    /// Opens one immutable document generation and captures the publication cursor under the
    /// same scope-state lock. A cursor returned here can never describe a publication before or
    /// after the generation retained by the handle.
    pub fn open_snapshot_with_publication(
        &self,
        expected_generation: Option<u64>,
    ) -> Result<WorkspaceProjectionOpenedSnapshot, WorkspaceProjectionScopeError> {
        let mut state = self.lock_open_state()?;
        let snapshot = self.catalog.snapshot()?;
        if let Some(expected) = expected_generation {
            if expected != snapshot.generation {
                return Err(WorkspaceProjectionCatalogError::GenerationMismatch {
                    expected,
                    actual: snapshot.generation,
                }
                .into());
            }
        }
        let next_count = state.snapshots_by_handle_id.len().saturating_add(1);
        if next_count > self.maximum_snapshot_handle_count {
            return Err(
                WorkspaceProjectionScopeError::SnapshotHandleCapacityExceeded {
                    actual: next_count,
                    maximum: self.maximum_snapshot_handle_count,
                },
            );
        }
        let next_retained_bytes = state
            .retained_snapshot_bytes
            .saturating_add(snapshot.retained_bytes);
        if next_retained_bytes > self.maximum_snapshot_retained_bytes {
            return Err(WorkspaceProjectionCatalogError::RetainedBytesExceeded {
                actual: next_retained_bytes,
                maximum: self.maximum_snapshot_retained_bytes,
            }
            .into());
        }
        let raw = state
            .next_snapshot_handle_id
            .checked_add(1)
            .ok_or(WorkspaceProjectionScopeError::HandleIdExhausted)?;
        state.next_snapshot_handle_id = raw;
        let handle_id = WorkspaceProjectionSnapshotHandleId(raw);
        state
            .snapshots_by_handle_id
            .insert(handle_id, Arc::clone(&snapshot));
        state.retained_snapshot_bytes = next_retained_bytes;
        Ok(WorkspaceProjectionOpenedSnapshot {
            handle_id,
            snapshot,
            catalog_revision: state.publication.catalog_revision,
            publication_sequence: state.publication.publication_sequence,
            event_log_floor_sequence: state.publication.event_log_floor_sequence,
            event_log_count: state.publication.events.len(),
        })
    }

    pub fn read_snapshot(
        &self,
        handle_id: WorkspaceProjectionSnapshotHandleId,
    ) -> Result<Arc<WorkspaceProjectionSnapshot>, WorkspaceProjectionScopeError> {
        let state = self.lock_open_state()?;
        state.snapshots_by_handle_id.get(&handle_id).cloned().ok_or(
            WorkspaceProjectionScopeError::UnknownSnapshotHandle(handle_id.raw()),
        )
    }

    pub fn close_snapshot(
        &self,
        handle_id: WorkspaceProjectionSnapshotHandleId,
    ) -> Result<(), WorkspaceProjectionScopeError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionScopeError::StateUnavailable)?;
        if let Some(snapshot) = state.snapshots_by_handle_id.remove(&handle_id) {
            state.retained_snapshot_bytes = state
                .retained_snapshot_bytes
                .saturating_sub(snapshot.retained_bytes);
        }
        Ok(())
    }

    pub fn diagnostics(
        &self,
    ) -> Result<(u64, usize, WorkspaceProjectionPublicationState), WorkspaceProjectionScopeError>
    {
        let state = self.lock_open_state()?;
        let generation = self.catalog.snapshot()?.generation;
        Ok((
            generation,
            state.snapshots_by_handle_id.len(),
            state.publication.clone(),
        ))
    }

    pub fn close(&self) -> Result<(), WorkspaceProjectionScopeError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionScopeError::StateUnavailable)?;
        state.closed = true;
        state.snapshots_by_handle_id.clear();
        state.retained_snapshot_bytes = 0;
        Ok(())
    }

    fn lock_open_state(
        &self,
    ) -> Result<
        std::sync::MutexGuard<'_, WorkspaceProjectionScopeState>,
        WorkspaceProjectionScopeError,
    > {
        let state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionScopeError::StateUnavailable)?;
        if state.closed {
            return Err(WorkspaceProjectionScopeError::ScopeClosed(
                self.scope_id.clone(),
            ));
        }
        Ok(state)
    }
}

struct WorkspaceProjectionScopeRegistryState {
    accepting_new_scopes: bool,
    next_scope_incarnation: u64,
    scopes_by_id: BTreeMap<String, Arc<WorkspaceProjectionScope>>,
}

/// Process-local registry partitioned by explicit domain-runtime scope UUID.
pub struct WorkspaceProjectionScopeRegistry {
    maximum_scope_count: usize,
    state: Mutex<WorkspaceProjectionScopeRegistryState>,
}

impl WorkspaceProjectionScopeRegistry {
    pub fn new(maximum_scope_count: usize) -> Self {
        Self {
            maximum_scope_count,
            state: Mutex::new(WorkspaceProjectionScopeRegistryState {
                accepting_new_scopes: true,
                next_scope_incarnation: 0,
                scopes_by_id: BTreeMap::new(),
            }),
        }
    }

    pub fn open_scope(
        &self,
        scope_id: &str,
        catalog_limits: WorkspaceProjectionCatalogLimits,
        maximum_snapshot_handle_count: usize,
    ) -> Result<Arc<WorkspaceProjectionScope>, WorkspaceProjectionScopeError> {
        let scope_id =
            canonical_uuid(scope_id).ok_or(WorkspaceProjectionScopeError::InvalidScopeId)?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionScopeError::StateUnavailable)?;
        if !state.accepting_new_scopes {
            return Err(WorkspaceProjectionScopeError::ScopeClosed(scope_id));
        }
        if state.scopes_by_id.contains_key(&scope_id) {
            return Err(WorkspaceProjectionScopeError::ScopeAlreadyOpen(scope_id));
        }
        let next_count = state.scopes_by_id.len().saturating_add(1);
        if next_count > self.maximum_scope_count {
            return Err(WorkspaceProjectionScopeError::ScopeCapacityExceeded {
                actual: next_count,
                maximum: self.maximum_scope_count,
            });
        }
        let scope_incarnation = state
            .next_scope_incarnation
            .checked_add(1)
            .ok_or(WorkspaceProjectionScopeError::ScopeIncarnationExhausted)?;
        state.next_scope_incarnation = scope_incarnation;
        let scope = Arc::new(WorkspaceProjectionScope {
            scope_id: scope_id.clone(),
            scope_incarnation,
            catalog: WorkspaceProjectionCatalog::new(catalog_limits),
            maximum_snapshot_handle_count,
            maximum_snapshot_retained_bytes: catalog_limits.maximum_retained_bytes,
            state: Mutex::new(WorkspaceProjectionScopeState {
                closed: false,
                next_snapshot_handle_id: 0,
                retained_snapshot_bytes: 0,
                snapshots_by_handle_id: BTreeMap::new(),
                publication: WorkspaceProjectionPublicationState::default(),
            }),
        });
        state.scopes_by_id.insert(scope_id, Arc::clone(&scope));
        Ok(scope)
    }

    pub fn scope(
        &self,
        scope_id: &str,
        scope_incarnation: u64,
    ) -> Result<Arc<WorkspaceProjectionScope>, WorkspaceProjectionScopeError> {
        let scope_id =
            canonical_uuid(scope_id).ok_or(WorkspaceProjectionScopeError::InvalidScopeId)?;
        let state = self
            .state
            .lock()
            .map_err(|_| WorkspaceProjectionScopeError::StateUnavailable)?;
        let scope = state
            .scopes_by_id
            .get(&scope_id)
            .cloned()
            .ok_or_else(|| WorkspaceProjectionScopeError::UnknownScope(scope_id.clone()))?;
        if scope.scope_incarnation() != scope_incarnation {
            return Err(WorkspaceProjectionScopeError::ScopeClosed(scope_id));
        }
        Ok(scope)
    }

    pub fn close_scope(
        &self,
        scope_id: &str,
        scope_incarnation: u64,
    ) -> Result<(), WorkspaceProjectionScopeError> {
        let scope_id =
            canonical_uuid(scope_id).ok_or(WorkspaceProjectionScopeError::InvalidScopeId)?;
        let scope = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| WorkspaceProjectionScopeError::StateUnavailable)?;
            if let Some(current) = state.scopes_by_id.get(&scope_id) {
                if current.scope_incarnation() != scope_incarnation {
                    return Err(WorkspaceProjectionScopeError::ScopeClosed(scope_id));
                }
            }
            state.scopes_by_id.remove(&scope_id)
        };
        if let Some(scope) = scope {
            scope.close()?;
        }
        Ok(())
    }

    pub fn close_all(&self) -> Result<(), WorkspaceProjectionScopeError> {
        let scopes = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| WorkspaceProjectionScopeError::StateUnavailable)?;
            state.accepting_new_scopes = false;
            std::mem::take(&mut state.scopes_by_id)
                .into_values()
                .collect::<Vec<_>>()
        };
        for scope in scopes {
            scope.close()?;
        }
        Ok(())
    }
}

impl Default for WorkspaceProjectionScopeRegistry {
    fn default() -> Self {
        Self::new(DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_SCOPE_COUNT)
    }
}

fn validate_publication_event_identities(
    event: &WorkspaceProjectionPublicationEvent,
) -> Result<(), WorkspaceProjectionCatalogError> {
    for identity in [
        event.workspace_id.as_deref(),
        event.context_id.as_deref(),
        event.operation_id.as_deref(),
    ]
    .into_iter()
    .flatten()
    {
        if canonical_uuid(identity).as_deref() != Some(identity) {
            return Err(WorkspaceProjectionCatalogError::InvalidPublicationIdentity);
        }
    }
    Ok(())
}

fn prepare_workspace_projection_checkpoint(
    checkpoint_bytes: &[u8],
    expected_scope_id: &str,
    catalog: &WorkspaceProjectionCatalog,
) -> Result<PreparedWorkspaceProjectionCheckpoint, WorkspaceProjectionScopeError> {
    if checkpoint_bytes.len() > MAXIMUM_WORKSPACE_PROJECTION_CHECKPOINT_BYTES_V1 {
        return Err(WorkspaceProjectionScopeError::CheckpointTooLarge {
            actual: checkpoint_bytes.len(),
            maximum: MAXIMUM_WORKSPACE_PROJECTION_CHECKPOINT_BYTES_V1,
        });
    }
    let checkpoint: WorkspaceProjectionCheckpointV1 = serde_json::from_slice(checkpoint_bytes)
        .map_err(|_| WorkspaceProjectionScopeError::InvalidCheckpoint)?;
    if checkpoint.version > WORKSPACE_PROJECTION_CHECKPOINT_SCHEMA_VERSION_V1 {
        return Err(WorkspaceProjectionScopeError::FutureCheckpoint(
            checkpoint.version,
        ));
    }
    if checkpoint.version != WORKSPACE_PROJECTION_CHECKPOINT_SCHEMA_VERSION_V1
        || canonical_uuid(&checkpoint.scope_id).as_deref() != Some(checkpoint.scope_id.as_str())
        || checkpoint.scope_id != expected_scope_id
        || (checkpoint.generation == 0 && !checkpoint.entries.0.is_empty())
    {
        return Err(WorkspaceProjectionScopeError::InvalidCheckpoint);
    }

    let mut entries_by_workspace_id = BTreeMap::new();
    for entry in checkpoint.entries.0 {
        if !is_lowercase_sha256(&entry.content_digest)
            || !is_lowercase_sha256(&entry.projection_checksum)
            || !is_valid_checkpoint_projection(&entry.projection)
            || entry
                .authority
                .as_ref()
                .is_some_and(|authority| !is_valid_authority_state(&entry.projection, authority))
            || checkpoint_projection_checksum(
                &entry.content_digest,
                &entry.projection,
                entry.authority.as_ref(),
            )? != entry.projection_checksum
        {
            return Err(WorkspaceProjectionScopeError::InvalidCheckpoint);
        }
        let workspace_id = entry.projection.workspace_id.clone();
        let retained_bytes = projection_retained_bytes(
            &entry.projection,
            entry.authority.as_ref(),
            entry.content_digest.len(),
        );
        let prepared = Arc::new(WorkspaceProjectionEntry {
            content_digest: entry.content_digest,
            retained_bytes,
            projection: entry.projection,
            authority: entry.authority,
        });
        if entries_by_workspace_id
            .insert(workspace_id, prepared)
            .is_some()
        {
            return Err(WorkspaceProjectionScopeError::InvalidCheckpoint);
        }
    }
    catalog.validate_capacity(&entries_by_workspace_id)?;

    let events: VecDeque<_> = checkpoint.events.0.into();
    if !is_valid_checkpoint_publication(
        checkpoint.catalog_revision,
        checkpoint.publication_sequence,
        checkpoint.event_log_floor_sequence,
        &events,
    ) {
        return Err(WorkspaceProjectionScopeError::InvalidCheckpoint);
    }
    Ok(PreparedWorkspaceProjectionCheckpoint {
        generation: checkpoint.generation,
        entries_by_workspace_id,
        publication: WorkspaceProjectionPublicationState {
            catalog_revision: checkpoint.catalog_revision,
            publication_sequence: checkpoint.publication_sequence,
            event_log_floor_sequence: checkpoint.event_log_floor_sequence,
            events,
        },
    })
}

fn checkpoint_projection_checksum(
    content_digest: &str,
    projection: &WorkspaceDocumentProjection,
    authority: Option<&WorkspaceProjectionAuthorityState>,
) -> Result<String, WorkspaceProjectionScopeError> {
    let mut writer = WorkspaceProjectionCheckpointDigestWriter(Sha256::new());
    writer
        .0
        .update(b"agentry-workspace-projection-checkpoint-entry-v1");
    writer.0.update([0]);
    writer.0.update(content_digest.as_bytes());
    writer.0.update([0]);
    serde_json::to_writer(&mut writer, projection)
        .map_err(|_| WorkspaceProjectionScopeError::InvalidCheckpoint)?;
    if let Some(authority) = authority {
        writer.0.update([0]);
        writer.0.update(b"authority-v1");
        writer.0.update([0]);
        serde_json::to_writer(&mut writer, authority)
            .map_err(|_| WorkspaceProjectionScopeError::InvalidCheckpoint)?;
    }
    Ok(format!("{:x}", writer.0.finalize()))
}

fn is_lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn is_valid_checkpoint_projection(projection: &WorkspaceDocumentProjection) -> bool {
    if canonical_uuid(&projection.workspace_id).as_deref() != Some(projection.workspace_id.as_str())
        || projection.schema_version > MAXIMUM_SUPPORTED_WORKSPACE_SCHEMA_VERSION
        || projection
            .active_context_id
            .as_deref()
            .is_some_and(|id| canonical_uuid(id).as_deref() != Some(id))
    {
        return false;
    }
    let mut context_ids = HashSet::new();
    projection.contexts.iter().all(|context| {
        canonical_uuid(&context.context_id).as_deref() == Some(context.context_id.as_str())
            && context_ids.insert(context.context_id.as_str())
            && context
                .active_agent_session_id
                .as_deref()
                .is_none_or(|id| canonical_uuid(id).as_deref() == Some(id))
            && context
                .active_chat_session_id
                .as_deref()
                .is_none_or(|id| canonical_uuid(id).as_deref() == Some(id))
    })
}

fn is_valid_checkpoint_publication(
    catalog_revision: u64,
    publication_sequence: u64,
    event_log_floor_sequence: u64,
    events: &VecDeque<WorkspaceProjectionPublicationEvent>,
) -> bool {
    if publication_sequence == 0 {
        return catalog_revision == 0 && event_log_floor_sequence == 1 && events.is_empty();
    }
    if events.is_empty() || events.len() > MAXIMUM_WORKSPACE_PROJECTION_PUBLICATION_EVENT_COUNT {
        return false;
    }
    let Some(first) = events.front() else {
        return false;
    };
    let Some(last) = events.back() else {
        return false;
    };
    if first.sequence != event_log_floor_sequence
        || last.sequence != publication_sequence
        || last.catalog_revision != catalog_revision
    {
        return false;
    }
    let mut previous_sequence: Option<u64> = None;
    let mut previous_catalog_revision: Option<u64> = None;
    for event in events {
        if event.sequence == 0 || validate_publication_event_identities(event).is_err() {
            return false;
        }
        if let Some(previous) = previous_sequence {
            if previous.checked_add(1) != Some(event.sequence) {
                return false;
            }
        }
        if previous_catalog_revision.is_some_and(|previous| event.catalog_revision < previous) {
            return false;
        }
        previous_sequence = Some(event.sequence);
        previous_catalog_revision = Some(event.catalog_revision);
    }
    true
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

fn require_generation(
    state: &WorkspaceProjectionCatalogState,
    expected_generation: u64,
) -> Result<(), WorkspaceProjectionCatalogError> {
    let actual = state.snapshot.generation;
    if actual != expected_generation {
        return Err(WorkspaceProjectionCatalogError::GenerationMismatch {
            expected: expected_generation,
            actual,
        });
    }
    Ok(())
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

fn unchanged_receipt(
    state: &WorkspaceProjectionCatalogState,
) -> WorkspaceProjectionMutationReceipt {
    WorkspaceProjectionMutationReceipt {
        previous_generation: state.snapshot.generation,
        generation: state.snapshot.generation,
        changed: false,
        snapshot: Arc::clone(&state.snapshot),
    }
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

    #[test]
    fn catalog_atomically_replaces_in_canonical_order_and_deduplicates_exact_content() {
        let catalog = WorkspaceProjectionCatalog::new(WorkspaceProjectionCatalogLimits::default());
        let workspace_b = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";
        let document_b = workspace_document(workspace_b, "Second");
        let document_a = workspace_document(WORKSPACE_ID, "First");

        let receipt = catalog
            .replace_documents(0, &[document_b.clone(), document_a.clone()])
            .expect("atomic replacement");
        assert!(receipt.changed);
        assert_eq!(receipt.previous_generation, 0);
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
            .replace_documents(1, &[document_a, document_b])
            .expect("same exact documents are a no-op regardless of input order");
        assert!(!unchanged.changed);
        assert_eq!(unchanged.generation, 1);
        assert!(Arc::ptr_eq(&receipt.snapshot, &unchanged.snapshot));
    }

    #[test]
    fn catalog_generation_mismatch_and_duplicate_rejection_leave_state_unchanged() {
        let catalog = WorkspaceProjectionCatalog::new(WorkspaceProjectionCatalogLimits::default());
        let original = workspace_document(WORKSPACE_ID, "Original");
        let committed = catalog
            .replace_documents(0, std::slice::from_ref(&original))
            .expect("initial replacement");

        let mismatch = catalog
            .upsert_document(0, &workspace_document(WORKSPACE_ID, "Stale"))
            .expect_err("stale CAS must fail");
        assert_eq!(
            mismatch,
            WorkspaceProjectionCatalogError::GenerationMismatch {
                expected: 0,
                actual: 1
            }
        );
        let duplicate = catalog
            .replace_documents(1, &[original.clone(), original])
            .expect_err("duplicate identity must fail");
        assert_eq!(
            duplicate,
            WorkspaceProjectionCatalogError::DuplicateWorkspaceId(
                "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_owned()
            )
        );
        let current = catalog.snapshot().expect("current snapshot");
        assert!(Arc::ptr_eq(&committed.snapshot, &current));
    }

    #[test]
    fn old_snapshot_lease_remains_immutable_across_upsert_and_remove() {
        let catalog = WorkspaceProjectionCatalog::new(WorkspaceProjectionCatalogLimits::default());
        let first = catalog
            .upsert_document(0, &workspace_document(WORKSPACE_ID, "Before"))
            .expect("first upsert");
        let second = catalog
            .upsert_document(1, &workspace_document(WORKSPACE_ID, "After"))
            .expect("second upsert");

        assert_eq!(first.snapshot.generation, 1);
        assert_eq!(first.snapshot.entries[0].projection.name, "Before");
        assert_eq!(second.snapshot.generation, 2);
        assert_eq!(second.snapshot.entries[0].projection.name, "After");
        let removed = catalog
            .remove_workspace(2, WORKSPACE_ID)
            .expect("remove existing workspace");
        assert_eq!(removed.generation, 3);
        assert!(removed.snapshot.entries.is_empty());
        assert_eq!(first.snapshot.entries[0].projection.name, "Before");
        assert_eq!(second.snapshot.entries[0].projection.name, "After");

        let absent = catalog
            .remove_workspace(3, WORKSPACE_ID)
            .expect("removing absent workspace is a no-op");
        assert!(!absent.changed);
        assert_eq!(absent.generation, 3);
        assert!(Arc::ptr_eq(&removed.snapshot, &absent.snapshot));
    }

    #[test]
    fn catalog_capacity_failures_do_not_publish_a_generation() {
        let count_limited = WorkspaceProjectionCatalog::new(WorkspaceProjectionCatalogLimits {
            maximum_workspace_count: 1,
            maximum_retained_bytes: usize::MAX,
        });
        let too_many = count_limited
            .replace_documents(
                0,
                &[
                    workspace_document(WORKSPACE_ID, "First"),
                    workspace_document("bbbbbbbb-cccc-dddd-eeee-ffffffffffff", "Second"),
                ],
            )
            .expect_err("workspace limit must fail closed");
        assert_eq!(
            too_many,
            WorkspaceProjectionCatalogError::WorkspaceCapacityExceeded {
                actual: 2,
                maximum: 1
            }
        );
        assert_eq!(
            count_limited
                .snapshot()
                .expect("unchanged snapshot")
                .generation,
            0
        );

        let byte_limited = WorkspaceProjectionCatalog::new(WorkspaceProjectionCatalogLimits {
            maximum_workspace_count: 1,
            maximum_retained_bytes: 1,
        });
        assert!(matches!(
            byte_limited.upsert_document(0, &workspace_document(WORKSPACE_ID, "Too large")),
            Err(WorkspaceProjectionCatalogError::RetainedBytesExceeded { maximum: 1, .. })
        ));
        assert_eq!(
            byte_limited
                .snapshot()
                .expect("unchanged snapshot")
                .generation,
            0
        );
    }

    #[test]
    fn scope_registry_partitions_catalog_generations_and_rejects_duplicate_open() {
        let registry = WorkspaceProjectionScopeRegistry::default();
        let scope_a_id = "10101010-1111-2222-3333-444444444444";
        let scope_b_id = "20202020-1111-2222-3333-444444444444";
        let scope_a = registry
            .open_scope(
                scope_a_id,
                WorkspaceProjectionCatalogLimits::default(),
                DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_SNAPSHOT_HANDLE_COUNT,
            )
            .expect("scope A");
        let scope_b = registry
            .open_scope(
                scope_b_id,
                WorkspaceProjectionCatalogLimits::default(),
                DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_SNAPSHOT_HANDLE_COUNT,
            )
            .expect("scope B");
        scope_a
            .upsert_document(0, &workspace_document(WORKSPACE_ID, "A"))
            .expect("scope A mutation");

        assert_eq!(scope_a.diagnostics().expect("scope A diagnostics").0, 1);
        assert_eq!(scope_a.diagnostics().expect("scope A diagnostics").1, 0);
        assert_eq!(scope_b.diagnostics().expect("scope B diagnostics").0, 0);
        assert_eq!(scope_b.diagnostics().expect("scope B diagnostics").1, 0);
        assert_eq!(
            registry
                .open_scope(scope_a_id, WorkspaceProjectionCatalogLimits::default(), 1)
                .err(),
            Some(WorkspaceProjectionScopeError::ScopeAlreadyOpen(
                scope_a_id.to_owned()
            ))
        );
    }

    #[test]
    fn scope_snapshot_handles_retain_generation_and_are_bounded() {
        let registry = WorkspaceProjectionScopeRegistry::default();
        let scope = registry
            .open_scope(
                "30303030-1111-2222-3333-444444444444",
                WorkspaceProjectionCatalogLimits::default(),
                1,
            )
            .expect("scope");
        scope
            .upsert_document(0, &workspace_document(WORKSPACE_ID, "Before"))
            .expect("initial mutation");
        let (handle, opened) = scope.open_snapshot(Some(1)).expect("snapshot handle");
        scope
            .upsert_document(1, &workspace_document(WORKSPACE_ID, "After"))
            .expect("later mutation");

        let retained = scope.read_snapshot(handle).expect("retained generation");
        assert!(Arc::ptr_eq(&opened, &retained));
        assert_eq!(retained.generation, 1);
        assert_eq!(retained.entries[0].projection.name, "Before");
        assert_eq!(
            scope.open_snapshot(None).err(),
            Some(
                WorkspaceProjectionScopeError::SnapshotHandleCapacityExceeded {
                    actual: 2,
                    maximum: 1
                }
            )
        );
        scope.close_snapshot(handle).expect("idempotent close");
        scope.close_snapshot(handle).expect("second close");
        let (_, current) = scope.open_snapshot(Some(2)).expect("capacity released");
        assert_eq!(current.entries[0].projection.name, "After");
    }

    #[test]
    fn closing_scope_invalidates_retained_scope_and_reopen_starts_fresh() {
        let registry = WorkspaceProjectionScopeRegistry::default();
        let scope_id = "40404040-1111-2222-3333-444444444444";
        let retired = registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 1)
            .expect("retired scope");
        retired
            .upsert_document(0, &workspace_document(WORKSPACE_ID, "Retired"))
            .expect("retired mutation");
        registry
            .close_scope(scope_id, retired.scope_incarnation())
            .expect("close scope");
        assert!(matches!(
            retired.open_snapshot(None),
            Err(WorkspaceProjectionScopeError::ScopeClosed(_))
        ));
        assert!(matches!(
            registry.scope(scope_id, retired.scope_incarnation()),
            Err(WorkspaceProjectionScopeError::UnknownScope(_))
        ));

        let fresh = registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 1)
            .expect("fresh scope");
        assert_ne!(retired.scope_incarnation(), fresh.scope_incarnation());
        assert_eq!(fresh.diagnostics().expect("fresh diagnostics").0, 0);
        assert_eq!(fresh.diagnostics().expect("fresh diagnostics").1, 0);
        assert!(matches!(
            registry.scope(scope_id, retired.scope_incarnation()),
            Err(WorkspaceProjectionScopeError::ScopeClosed(_))
        ));
        assert!(matches!(
            registry.close_scope(scope_id, retired.scope_incarnation()),
            Err(WorkspaceProjectionScopeError::ScopeClosed(_))
        ));
        assert_eq!(
            registry
                .scope(scope_id, fresh.scope_incarnation())
                .expect("fresh incarnation")
                .scope_incarnation(),
            fresh.scope_incarnation()
        );
    }

    #[test]
    fn snapshot_retained_bytes_are_bounded_independently_of_handle_count() {
        let registry = WorkspaceProjectionScopeRegistry::default();
        let scope = registry
            .open_scope(
                "50505050-1111-2222-3333-444444444444",
                WorkspaceProjectionCatalogLimits {
                    maximum_workspace_count: 1,
                    maximum_retained_bytes: 700,
                },
                64,
            )
            .expect("scope");
        scope
            .upsert_document(0, &workspace_document(WORKSPACE_ID, "Retained"))
            .expect("mutation fits catalog bound");
        let (first, snapshot) = scope.open_snapshot(Some(1)).expect("first lease");
        assert!(snapshot.retained_bytes <= 700);
        assert!(matches!(
            scope.open_snapshot(Some(1)),
            Err(WorkspaceProjectionScopeError::Catalog(
                WorkspaceProjectionCatalogError::RetainedBytesExceeded { maximum: 700, .. }
            ))
        ));
        scope.close_snapshot(first).expect("release retained bytes");
        scope
            .open_snapshot(Some(1))
            .expect("lease capacity restored");
    }

    #[test]
    fn authoritative_rows_are_immutable_checkpointed_and_document_only_updates_invalidate_them() {
        let scope_id = "51515151-1111-2222-3333-444444444444";
        let registry = WorkspaceProjectionScopeRegistry::default();
        let scope = registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 2)
            .expect("scope");
        let document = workspace_document(WORKSPACE_ID, "Authority");
        let first_authority = authority_state(1, WorkspaceProjectionHealthKind::Writable, None);
        scope
            .publish_authoritative_state(
                0,
                0,
                0,
                true,
                &[WorkspaceProjectionPublishedWorkspace {
                    document_bytes: document.clone(),
                    authority: first_authority.clone(),
                }],
                publication_event(1, 1, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("first authority publication");
        let (old_handle, old) = scope.open_snapshot(Some(1)).expect("old snapshot");

        let second_authority = authority_state(
            2,
            WorkspaceProjectionHealthKind::ExternalConflict,
            Some("external_update"),
        );
        scope
            .publish_authoritative_state(
                1,
                1,
                1,
                false,
                &[WorkspaceProjectionPublishedWorkspace {
                    document_bytes: document.clone(),
                    authority: second_authority.clone(),
                }],
                publication_event(2, 2, WorkspaceProjectionPublicationKind::ExternalConflict),
            )
            .expect("authority-only publication");
        assert_eq!(old.entries[0].authority.as_ref(), Some(&first_authority));
        assert_eq!(
            scope
                .read_snapshot(old_handle)
                .expect("old retained snapshot")
                .entries[0]
                .authority
                .as_ref(),
            Some(&first_authority)
        );
        let current = scope.open_snapshot(Some(2)).expect("current snapshot").1;
        assert_eq!(
            current.entries[0].authority.as_ref(),
            Some(&second_authority)
        );

        let checkpoint = scope.export_checkpoint().expect("checkpoint");
        let restored_registry = WorkspaceProjectionScopeRegistry::default();
        let restored = restored_registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 1)
            .expect("restored scope");
        let restored_snapshot = restored.restore_checkpoint(&checkpoint).expect("restore");
        assert_eq!(
            restored_snapshot.entries[0].authority.as_ref(),
            Some(&second_authority)
        );

        let changed = workspace_document(WORKSPACE_ID, "Document-only change");
        let receipt = restored
            .upsert_document(restored_snapshot.generation, &changed)
            .expect("document-only invalidation");
        assert_eq!(receipt.snapshot.entries[0].authority, None);
    }

    #[test]
    fn authoritative_row_validation_rejects_invalid_health_without_mutation() {
        let registry = WorkspaceProjectionScopeRegistry::default();
        let scope = registry
            .open_scope(
                "52525252-1111-2222-3333-444444444444",
                WorkspaceProjectionCatalogLimits::default(),
                1,
            )
            .expect("scope");
        let invalid = WorkspaceProjectionPublishedWorkspace {
            document_bytes: workspace_document(WORKSPACE_ID, "Invalid"),
            authority: authority_state(1, WorkspaceProjectionHealthKind::Writable, Some("reason")),
        };
        assert_eq!(
            scope
                .publish_authoritative_state(
                    0,
                    0,
                    0,
                    true,
                    &[invalid],
                    publication_event(1, 1, WorkspaceProjectionPublicationKind::Bootstrapped),
                )
                .expect_err("writable health cannot carry a reason"),
            WorkspaceProjectionScopeError::Catalog(
                WorkspaceProjectionCatalogError::InvalidAuthorityState
            )
        );
        assert_eq!(scope.diagnostics().expect("diagnostics").0, 0);
        assert_eq!(
            scope.publication_state().expect("publication"),
            WorkspaceProjectionPublicationState::default()
        );
    }

    #[test]
    fn registry_close_all_permanently_rejects_new_scopes() {
        let registry = WorkspaceProjectionScopeRegistry::default();
        let scope_id = "60606060-1111-2222-3333-444444444444";
        let scope = registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 1)
            .expect("scope");
        registry.close_all().expect("close registry");
        assert!(matches!(
            scope.diagnostics(),
            Err(WorkspaceProjectionScopeError::ScopeClosed(_))
        ));
        assert!(matches!(
            registry.open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 1),
            Err(WorkspaceProjectionScopeError::ScopeClosed(_))
        ));
        registry.close_all().expect("idempotent close all");
    }

    #[test]
    fn publication_state_atomically_tracks_projection_revision_and_exact_sequence() {
        let registry = WorkspaceProjectionScopeRegistry::default();
        let scope = registry
            .open_scope(
                "70707070-1111-2222-3333-444444444444",
                WorkspaceProjectionCatalogLimits::default(),
                1,
            )
            .expect("scope");
        let first = publication_event(7, 41, WorkspaceProjectionPublicationKind::Bootstrapped);
        let rebased = scope
            .publish_state(
                0,
                0,
                0,
                true,
                &[workspace_document(WORKSPACE_ID, "First")],
                first.clone(),
            )
            .expect("initial rebase");
        assert_eq!(rebased.projection.generation, 1);
        assert_eq!(rebased.catalog_revision, 41);
        assert_eq!(rebased.publication_sequence, 7);
        assert_eq!(rebased.event_log_floor_sequence, 7);
        assert_eq!(rebased.event_log_count, 1);
        assert!(rebased.rebased);
        let first_snapshot = scope
            .open_snapshot_with_publication(Some(1))
            .expect("first snapshot cursor");
        assert_eq!(first_snapshot.catalog_revision, 41);
        assert_eq!(first_snapshot.publication_sequence, 7);
        assert_eq!(first_snapshot.event_log_floor_sequence, 7);
        assert_eq!(first_snapshot.event_log_count, 1);

        let second = publication_event(
            8,
            42,
            WorkspaceProjectionPublicationKind::WorkingStateCommitted,
        );
        let appended = scope
            .publish_state(
                1,
                41,
                7,
                false,
                &[workspace_document(WORKSPACE_ID, "Second")],
                second.clone(),
            )
            .expect("continuous append");
        assert_eq!(appended.projection.generation, 2);
        assert_eq!(appended.previous_catalog_revision, 41);
        assert_eq!(appended.previous_publication_sequence, 7);
        assert_eq!(first_snapshot.catalog_revision, 41);
        assert_eq!(first_snapshot.publication_sequence, 7);
        scope
            .close_snapshot(first_snapshot.handle_id)
            .expect("close first snapshot");
        let second_snapshot = scope
            .open_snapshot_with_publication(Some(2))
            .expect("second snapshot cursor");
        assert_eq!(second_snapshot.catalog_revision, 42);
        assert_eq!(second_snapshot.publication_sequence, 8);
        assert_eq!(second_snapshot.event_log_floor_sequence, 7);
        assert_eq!(second_snapshot.event_log_count, 2);
        scope
            .close_snapshot(second_snapshot.handle_id)
            .expect("close second snapshot");
        assert_eq!(
            scope.publication_state().expect("state").events,
            [first, second]
        );
    }

    #[test]
    fn publication_state_rejects_gaps_without_mutation_and_bounds_log() {
        let registry = WorkspaceProjectionScopeRegistry::default();
        let scope = registry
            .open_scope(
                "80808080-1111-2222-3333-444444444444",
                WorkspaceProjectionCatalogLimits::default(),
                1,
            )
            .expect("scope");
        scope
            .publish_state(
                0,
                0,
                0,
                true,
                &[workspace_document(WORKSPACE_ID, "Initial")],
                publication_event(1, 1, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("initial publication");
        assert!(matches!(
            scope.publish_state(
                1,
                1,
                1,
                false,
                &[workspace_document(WORKSPACE_ID, "Must not commit")],
                publication_event(3, 2, WorkspaceProjectionPublicationKind::WorkspaceCreated),
            ),
            Err(WorkspaceProjectionScopeError::Catalog(
                WorkspaceProjectionCatalogError::InvalidPublicationSequence {
                    expected: 2,
                    actual: 3
                }
            ))
        ));
        assert_eq!(scope.diagnostics().expect("unchanged generation").0, 1);
        assert_eq!(scope.diagnostics().expect("unchanged generation").1, 0);
        assert_eq!(
            scope
                .publication_state()
                .expect("unchanged cursor")
                .publication_sequence,
            1
        );
        assert!(matches!(
            scope.publish_state(
                1,
                0,
                0,
                true,
                &[workspace_document(WORKSPACE_ID, "Stale rebase")],
                publication_event(4, 4, WorkspaceProjectionPublicationKind::WorkspaceCreated),
            ),
            Err(WorkspaceProjectionScopeError::Catalog(
                WorkspaceProjectionCatalogError::PublicationCursorMismatch {
                    actual_catalog_revision: 1,
                    actual_publication_sequence: 1,
                    ..
                }
            ))
        ));
        assert!(matches!(
            scope.publish_state(
                1,
                1,
                1,
                true,
                &[workspace_document(WORKSPACE_ID, "Regressed rebase")],
                publication_event(4, 0, WorkspaceProjectionPublicationKind::WorkspaceCreated),
            ),
            Err(WorkspaceProjectionScopeError::Catalog(
                WorkspaceProjectionCatalogError::CatalogRevisionRegressed {
                    previous: 1,
                    next: 0
                }
            ))
        ));
        let unchanged = scope.diagnostics().expect("rebase failures stay atomic");
        assert_eq!(unchanged.0, 1);
        assert_eq!(unchanged.2.catalog_revision, 1);
        assert_eq!(unchanged.2.publication_sequence, 1);

        let mut generation = 1;
        for sequence in 2_u64..=300 {
            let receipt = scope
                .publish_state(
                    generation,
                    sequence - 1,
                    sequence - 1,
                    false,
                    &[workspace_document(
                        WORKSPACE_ID,
                        &format!("Revision {sequence}"),
                    )],
                    publication_event(
                        sequence,
                        sequence,
                        WorkspaceProjectionPublicationKind::WorkingStateCommitted,
                    ),
                )
                .expect("bounded append");
            generation = receipt.projection.generation;
        }
        let state = scope.publication_state().expect("bounded state");
        assert_eq!(
            state.events.len(),
            MAXIMUM_WORKSPACE_PROJECTION_PUBLICATION_EVENT_COUNT
        );
        assert_eq!(state.event_log_floor_sequence, 45);
        assert_eq!(state.publication_sequence, 300);
    }

    #[test]
    fn checkpoint_round_trip_restores_exact_generation_cursor_and_digest() {
        let scope_id = "90909090-1111-2222-3333-444444444444";
        let registry = WorkspaceProjectionScopeRegistry::default();
        let scope = registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 2)
            .expect("scope");
        scope
            .publish_state(
                0,
                0,
                0,
                true,
                &[workspace_document(WORKSPACE_ID, "First")],
                publication_event(7, 41, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("initial publication");
        let second_document = workspace_document(WORKSPACE_ID, "Second");
        scope
            .publish_state(
                1,
                41,
                7,
                false,
                std::slice::from_ref(&second_document),
                publication_event(
                    8,
                    42,
                    WorkspaceProjectionPublicationKind::WorkingStateCommitted,
                ),
            )
            .expect("second publication");
        let checkpoint = scope.export_checkpoint().expect("checkpoint");
        registry
            .close_scope(scope_id, scope.scope_incarnation())
            .expect("close original");

        let restored = registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 2)
            .expect("restored scope");
        let restored_snapshot = restored
            .restore_checkpoint(&checkpoint)
            .expect("restore checkpoint");
        assert_eq!(restored_snapshot.generation, 2);
        assert_eq!(restored_snapshot.entries[0].projection.name, "Second");
        assert_eq!(
            restored
                .export_checkpoint()
                .expect("deterministic re-export"),
            checkpoint
        );
        let (handle, retained) = restored
            .open_snapshot(Some(2))
            .expect("retained recovered generation");
        let cursor_only = restored
            .publish_state(
                2,
                42,
                8,
                false,
                &[second_document],
                publication_event(
                    9,
                    43,
                    WorkspaceProjectionPublicationKind::OperationDeduplicated,
                ),
            )
            .expect("same-document continuation");
        assert!(!cursor_only.projection.changed);
        assert_eq!(cursor_only.projection.generation, 2);
        assert_eq!(cursor_only.publication_sequence, 9);
        assert_eq!(retained.entries[0].projection.name, "Second");
        restored.close_snapshot(handle).expect("close snapshot");
    }

    #[test]
    fn checkpoint_restart_mode_retains_projection_generation_and_resets_publication_epoch() {
        let scope_id = "91919191-1111-2222-3333-444444444444";
        let source_registry = WorkspaceProjectionScopeRegistry::default();
        let source = source_registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 1)
            .expect("source");
        let document = workspace_document(WORKSPACE_ID, "Restarted");
        source
            .publish_state(
                0,
                0,
                0,
                true,
                std::slice::from_ref(&document),
                publication_event(9, 12, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("source publication");
        let checkpoint = source.export_checkpoint().expect("checkpoint");
        source_registry
            .close_scope(scope_id, source.scope_incarnation())
            .expect("close source");

        let target_registry = WorkspaceProjectionScopeRegistry::default();
        let target = target_registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 1)
            .expect("target");
        let restored = target
            .restore_checkpoint_for_new_publication_epoch(&checkpoint)
            .expect("restart restore");
        assert_eq!(restored.generation, 1);
        assert_eq!(
            restored.entries[0].content_digest,
            format!("{:x}", Sha256::digest(&document))
        );
        assert_eq!(
            target.publication_state().expect("reset publication"),
            WorkspaceProjectionPublicationState::default()
        );
        let baseline = target
            .publish_state(
                1,
                0,
                0,
                true,
                &[document],
                publication_event(1, 12, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("new epoch bootstrap");
        assert!(!baseline.projection.changed);
        assert_eq!(baseline.projection.generation, 1);
        assert_eq!(baseline.publication_sequence, 1);
    }

    #[test]
    fn checkpoint_recovery_rejects_invalid_future_cross_scope_and_nonpristine_state_atomically() {
        let scope_id = "a0a0a0a0-1111-2222-3333-444444444444";
        let registry = WorkspaceProjectionScopeRegistry::default();
        let source = registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 1)
            .expect("source");
        source
            .publish_state(
                0,
                0,
                0,
                true,
                &[workspace_document(WORKSPACE_ID, "Checkpoint")],
                publication_event(1, 1, WorkspaceProjectionPublicationKind::Bootstrapped),
            )
            .expect("source publication");
        let checkpoint = source.export_checkpoint().expect("checkpoint");
        assert!(matches!(
            source.restore_checkpoint(&checkpoint),
            Err(WorkspaceProjectionScopeError::CheckpointStateConflict)
        ));

        let target_registry = WorkspaceProjectionScopeRegistry::default();
        let target = target_registry
            .open_scope(scope_id, WorkspaceProjectionCatalogLimits::default(), 1)
            .expect("target");
        let mut future: Value = serde_json::from_slice(&checkpoint).expect("decode checkpoint");
        future["version"] = Value::from(2);
        assert!(matches!(
            target.restore_checkpoint(&serde_json::to_vec(&future).expect("future bytes")),
            Err(WorkspaceProjectionScopeError::FutureCheckpoint(2))
        ));
        let mut wrong_scope: Value =
            serde_json::from_slice(&checkpoint).expect("decode checkpoint");
        wrong_scope["scopeId"] = Value::from("b0b0b0b0-1111-2222-3333-444444444444");
        assert!(matches!(
            target.restore_checkpoint(&serde_json::to_vec(&wrong_scope).expect("scope bytes")),
            Err(WorkspaceProjectionScopeError::InvalidCheckpoint)
        ));
        let mut invalid_digest: Value =
            serde_json::from_slice(&checkpoint).expect("decode checkpoint");
        invalid_digest["entries"][0]["contentDigest"] = Value::from("not-a-sha256");
        assert!(matches!(
            target.restore_checkpoint(
                &serde_json::to_vec(&invalid_digest).expect("invalid digest bytes")
            ),
            Err(WorkspaceProjectionScopeError::InvalidCheckpoint)
        ));
        let mut unbound_projection: Value =
            serde_json::from_slice(&checkpoint).expect("decode checkpoint");
        unbound_projection["entries"][0]["projection"]["name"] = Value::from("tampered");
        assert!(matches!(
            target.restore_checkpoint(
                &serde_json::to_vec(&unbound_projection).expect("tampered projection bytes")
            ),
            Err(WorkspaceProjectionScopeError::InvalidCheckpoint)
        ));
        let mut excessive_entries: Value =
            serde_json::from_slice(&checkpoint).expect("decode checkpoint");
        let entry = excessive_entries["entries"][0].clone();
        excessive_entries["entries"] = Value::Array(
            (0..=DEFAULT_MAXIMUM_WORKSPACE_PROJECTION_COUNT)
                .map(|_| entry.clone())
                .collect(),
        );
        assert!(matches!(
            target.restore_checkpoint(
                &serde_json::to_vec(&excessive_entries).expect("excessive entry bytes")
            ),
            Err(WorkspaceProjectionScopeError::InvalidCheckpoint)
        ));
        let mut excessive_events: Value =
            serde_json::from_slice(&checkpoint).expect("decode checkpoint");
        let event = excessive_events["events"][0].clone();
        excessive_events["events"] = Value::Array(
            (0..=MAXIMUM_WORKSPACE_PROJECTION_PUBLICATION_EVENT_COUNT)
                .map(|_| event.clone())
                .collect(),
        );
        assert!(matches!(
            target.restore_checkpoint(
                &serde_json::to_vec(&excessive_events).expect("excessive event bytes")
            ),
            Err(WorkspaceProjectionScopeError::InvalidCheckpoint)
        ));
        let mut invalid_tail: Value =
            serde_json::from_slice(&checkpoint).expect("decode checkpoint");
        invalid_tail["publicationSequence"] = Value::from(2);
        assert!(matches!(
            target.restore_checkpoint(
                &serde_json::to_vec(&invalid_tail).expect("invalid tail bytes")
            ),
            Err(WorkspaceProjectionScopeError::InvalidCheckpoint)
        ));
        let unchanged = target.diagnostics().expect("failed recovery stays atomic");
        assert_eq!(unchanged.0, 0);
        assert_eq!(unchanged.1, 0);
        assert_eq!(unchanged.2, WorkspaceProjectionPublicationState::default());

        let bounded_registry = WorkspaceProjectionScopeRegistry::default();
        let bounded = bounded_registry
            .open_scope(
                scope_id,
                WorkspaceProjectionCatalogLimits {
                    maximum_workspace_count: 1,
                    maximum_retained_bytes: 1,
                },
                1,
            )
            .expect("bounded target");
        assert!(matches!(
            bounded.restore_checkpoint(&checkpoint),
            Err(WorkspaceProjectionScopeError::Catalog(
                WorkspaceProjectionCatalogError::RetainedBytesExceeded { .. }
            ))
        ));
        assert_eq!(bounded.diagnostics().expect("bounded atomicity").0, 0);
    }

    #[test]
    fn checkpoint_writer_caps_highly_escaped_output_during_serialization() {
        let mut writer = CappedWorkspaceProjectionCheckpointWriter::new(64);
        let value = String::from_utf8(vec![1; 64]).expect("control-character string");
        assert!(serde_json::to_writer(&mut writer, &value).is_err());
        assert!(writer.bytes.len() <= 64);
        assert!(writer.attempted_bytes > 64);
    }

    fn publication_event(
        sequence: u64,
        catalog_revision: u64,
        kind: WorkspaceProjectionPublicationKind,
    ) -> WorkspaceProjectionPublicationEvent {
        WorkspaceProjectionPublicationEvent {
            sequence,
            catalog_revision,
            kind,
            workspace_id: Some(WORKSPACE_ID.to_ascii_lowercase()),
            context_id: None,
            operation_id: None,
            revisions: Some(WorkspaceProjectionRevisionState {
                working_revision: catalog_revision,
                saved_revision: catalog_revision.saturating_sub(1),
                dirty_revision: Some(catalog_revision),
            }),
        }
    }

    fn authority_state(
        revision: u64,
        health_kind: WorkspaceProjectionHealthKind,
        reason: Option<&str>,
    ) -> WorkspaceProjectionAuthorityState {
        WorkspaceProjectionAuthorityState {
            revisions: WorkspaceProjectionRevisionState {
                working_revision: revision,
                saved_revision: revision.saturating_sub(1),
                dirty_revision: Some(revision),
            },
            health: WorkspaceProjectionHealth {
                kind: health_kind,
                reason: reason.map(str::to_owned),
            },
            contexts: Vec::new(),
        }
    }

    fn workspace_document(workspace_id: &str, name: &str) -> Vec<u8> {
        format!(r#"{{"id":"{workspace_id}","schemaVersion":1,"name":"{name}"}}"#).into_bytes()
    }
}
