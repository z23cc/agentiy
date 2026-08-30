//! P7 watcher ingress authority.
//!
//! CoreServices owns the platform stream and callback invocation, but it must not own the
//! accepted-event queue.  This module receives already-owned event values, assigns a monotonic
//! per-scope watermark, preserves FIFO delivery, and collapses bounded pressure to one explicit
//! root-rescan payload.  No callback pointer or platform object crosses this boundary.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex};

use crate::{RuntimeIdentity, ScopeId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WatcherEvent {
    pub path: String,
    pub flags: u64,
    pub event_id: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WatcherPayloadContents {
    Entries(Vec<WatcherEvent>),
    OverflowRootRescan {
        highest_event_id: u64,
        changed_ignore_absolute_paths: Vec<String>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcceptedWatcherPayload {
    pub lowest_accepted_watermark: u64,
    pub accepted_high_watermark: u64,
    pub contents: WatcherPayloadContents,
}

impl AcceptedWatcherPayload {
    pub fn raw_entry_count(&self) -> usize {
        match &self.contents {
            WatcherPayloadContents::Entries(entries) => entries.len(),
            WatcherPayloadContents::OverflowRootRescan { .. } => 1,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WatcherSnapshot {
    pub accepted_high_watermark: u64,
    pub queued_low_watermark: Option<u64>,
    pub queued_high_watermark: Option<u64>,
    pub queued_payload_count: u64,
    pub queued_raw_entry_count: u64,
    pub has_overflow_root_rescan: bool,
    pub is_accepting: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WatcherError {
    IdentityMismatch,
    ScopeClosed,
    InvalidArgument(&'static str),
}

impl std::fmt::Display for WatcherError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::IdentityMismatch => formatter.write_str("runtime identity mismatch"),
            Self::ScopeClosed => formatter.write_str("watcher scope is closed"),
            Self::InvalidArgument(value) => write!(formatter, "invalid watcher argument: {value}"),
        }
    }
}

impl std::error::Error for WatcherError {}

struct WatcherState {
    accepting: bool,
    next_watermark: u64,
    accepted_high_watermark: u64,
    queue: VecDeque<AcceptedWatcherPayload>,
    queued_raw_entry_count: usize,
    has_overflow_root_rescan: bool,
}

/// A single filesystem-root watcher mailbox. The scope remains reusable across stream restarts;
/// `reset` discards pending evidence while preserving its monotonic watermark.
pub struct AgentWatcherScope {
    identity: RuntimeIdentity,
    id: ScopeId,
    root_path: String,
    max_queued_raw_entries: usize,
    state: Mutex<WatcherState>,
}

impl AgentWatcherScope {
    fn new(
        identity: RuntimeIdentity,
        id: ScopeId,
        root_path: String,
        max_queued_raw_entries: usize,
    ) -> Result<Arc<Self>, WatcherError> {
        if root_path.trim().is_empty() {
            return Err(WatcherError::InvalidArgument("root_path"));
        }
        if max_queued_raw_entries == 0 {
            return Err(WatcherError::InvalidArgument("max_queued_raw_entries"));
        }
        Ok(Arc::new(Self {
            identity,
            id,
            root_path,
            max_queued_raw_entries,
            state: Mutex::new(WatcherState {
                accepting: true,
                next_watermark: 0,
                accepted_high_watermark: 0,
                queue: VecDeque::new(),
                queued_raw_entry_count: 0,
                has_overflow_root_rescan: false,
            }),
        }))
    }

    pub fn id(&self) -> ScopeId {
        self.id.clone()
    }

    pub fn root_path(&self) -> &str {
        &self.root_path
    }

    fn validate(&self, identity: &RuntimeIdentity) -> Result<(), WatcherError> {
        if &self.identity == identity {
            Ok(())
        } else {
            Err(WatcherError::IdentityMismatch)
        }
    }

    pub fn start_accepting(&self, identity: &RuntimeIdentity) -> Result<(), WatcherError> {
        self.validate(identity)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.accepting = true;
        Ok(())
    }

    pub fn reset(&self, identity: &RuntimeIdentity) -> Result<(), WatcherError> {
        self.validate(identity)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.accepting = false;
        state.queue.clear();
        state.queued_raw_entry_count = 0;
        state.has_overflow_root_rescan = false;
        Ok(())
    }

    pub fn capture_watermark(&self, identity: &RuntimeIdentity) -> Result<u64, WatcherError> {
        self.validate(identity)?;
        let state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Ok(state.accepted_high_watermark)
    }

    pub fn ingest(
        &self,
        identity: &RuntimeIdentity,
        entries: &[WatcherEvent],
    ) -> Result<Option<u64>, WatcherError> {
        self.validate(identity)?;
        if entries.is_empty() {
            return Ok(None);
        }
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !state.accepting {
            return Err(WatcherError::ScopeClosed);
        }
        state.next_watermark = state.next_watermark.saturating_add(1);
        state.accepted_high_watermark = state.next_watermark;
        let payload = AcceptedWatcherPayload {
            lowest_accepted_watermark: state.next_watermark,
            accepted_high_watermark: state.next_watermark,
            contents: WatcherPayloadContents::Entries(entries.to_vec()),
        };
        Self::append_or_collapse(&mut state, payload, self.max_queued_raw_entries);
        Ok(Some(state.next_watermark))
    }

    pub fn take_next(
        &self,
        identity: &RuntimeIdentity,
        through: Option<u64>,
    ) -> Result<Option<AcceptedWatcherPayload>, WatcherError> {
        self.validate(identity)?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(first) = state.queue.front() else {
            return Ok(None);
        };
        if through.is_some_and(|target| first.lowest_accepted_watermark > target) {
            return Ok(None);
        }
        let payload = state
            .queue
            .pop_front()
            .expect("front was present immediately above");
        state.queued_raw_entry_count = state
            .queued_raw_entry_count
            .saturating_sub(payload.raw_entry_count());
        if state.queue.is_empty() {
            state.has_overflow_root_rescan = false;
        }
        Ok(Some(payload))
    }

    pub fn snapshot(&self, identity: &RuntimeIdentity) -> Result<WatcherSnapshot, WatcherError> {
        self.validate(identity)?;
        let state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let first = state.queue.front();
        let last = state.queue.back();
        Ok(WatcherSnapshot {
            accepted_high_watermark: state.accepted_high_watermark,
            queued_low_watermark: first.map(|payload| payload.lowest_accepted_watermark),
            queued_high_watermark: last.map(|payload| payload.accepted_high_watermark),
            queued_payload_count: state.queue.len() as u64,
            queued_raw_entry_count: state.queued_raw_entry_count as u64,
            has_overflow_root_rescan: state.has_overflow_root_rescan,
            is_accepting: state.accepting,
        })
    }

    fn append_or_collapse(
        state: &mut WatcherState,
        payload: AcceptedWatcherPayload,
        max_queued_raw_entries: usize,
    ) {
        if state.has_overflow_root_rescan
            || state
                .queued_raw_entry_count
                .saturating_add(payload.raw_entry_count())
                > max_queued_raw_entries
        {
            let mut payloads: Vec<AcceptedWatcherPayload> = state.queue.drain(..).collect();
            payloads.push(payload);
            let collapsed = Self::collapse(payloads);
            state.queue.push_back(collapsed);
            state.queued_raw_entry_count = 1;
            state.has_overflow_root_rescan = true;
            return;
        }
        state.queued_raw_entry_count = state
            .queued_raw_entry_count
            .saturating_add(payload.raw_entry_count());
        state.queue.push_back(payload);
    }

    fn collapse(payloads: Vec<AcceptedWatcherPayload>) -> AcceptedWatcherPayload {
        let mut lowest = u64::MAX;
        let mut highest = 0;
        let mut highest_event_id = 0;
        let mut changed_ignore_absolute_paths = HashSet::new();
        for payload in &payloads {
            lowest = lowest.min(payload.lowest_accepted_watermark);
            highest = highest.max(payload.accepted_high_watermark);
            match &payload.contents {
                WatcherPayloadContents::Entries(entries) => {
                    for entry in entries {
                        highest_event_id = highest_event_id.max(entry.event_id);
                        if Self::is_ignore_control_path(&entry.path) {
                            changed_ignore_absolute_paths.insert(entry.path.clone());
                        }
                    }
                }
                WatcherPayloadContents::OverflowRootRescan {
                    highest_event_id: event_id,
                    changed_ignore_absolute_paths: paths,
                } => {
                    highest_event_id = highest_event_id.max(*event_id);
                    changed_ignore_absolute_paths.extend(paths.iter().cloned());
                }
            }
        }
        let mut changed_ignore_absolute_paths: Vec<_> =
            changed_ignore_absolute_paths.into_iter().collect();
        changed_ignore_absolute_paths.sort();
        AcceptedWatcherPayload {
            lowest_accepted_watermark: lowest,
            accepted_high_watermark: highest,
            contents: WatcherPayloadContents::OverflowRootRescan {
                highest_event_id,
                changed_ignore_absolute_paths,
            },
        }
    }

    fn is_ignore_control_path(path: &str) -> bool {
        path.rsplit('/').next().is_some_and(|filename| {
            matches!(
                filename.to_ascii_lowercase().as_str(),
                ".gitignore" | ".repo_ignore" | ".cursorignore"
            )
        })
    }
}

pub struct ScopeRegistry {
    scopes: Mutex<HashMap<ScopeId, Arc<AgentWatcherScope>>>,
    next_id: Mutex<u128>,
}

impl ScopeRegistry {
    pub fn new() -> Self {
        Self {
            scopes: Mutex::new(HashMap::new()),
            next_id: Mutex::new(1),
        }
    }

    pub fn open_scope(
        &self,
        identity: RuntimeIdentity,
        root_path: String,
        max_queued_raw_entries: usize,
    ) -> Result<Arc<AgentWatcherScope>, WatcherError> {
        let id = {
            let mut next = self
                .next_id
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let value = *next;
            *next = next.saturating_add(1);
            ScopeId::from_u128(value)
        };
        let scope =
            AgentWatcherScope::new(identity, id.clone(), root_path, max_queued_raw_entries)?;
        self.scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(id, Arc::clone(&scope));
        Ok(scope)
    }

    pub fn scope(&self, id: &ScopeId) -> Option<Arc<AgentWatcherScope>> {
        self.scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(id)
            .cloned()
    }

    pub fn close_scope(
        &self,
        identity: &RuntimeIdentity,
        id: &ScopeId,
    ) -> Result<(), WatcherError> {
        let scope = self
            .scopes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(id);
        let Some(scope) = scope else {
            return Ok(());
        };
        if &scope.identity != identity {
            self.scopes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(id.clone(), scope);
            return Err(WatcherError::IdentityMismatch);
        }
        let _ = scope.reset(identity);
        Ok(())
    }
}

impl Default for ScopeRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity() -> RuntimeIdentity {
        RuntimeIdentity::new(
            1,
            "0123456789abcdef0123456789abcdef",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
        )
        .unwrap()
    }

    fn event(path: &str, id: u64) -> WatcherEvent {
        WatcherEvent {
            path: path.into(),
            flags: 7,
            event_id: id,
        }
    }

    #[test]
    fn accepts_fifo_batches_with_monotonic_watermarks() {
        let scope = ScopeRegistry::new()
            .open_scope(identity(), "/tmp/root".into(), 8)
            .unwrap();
        assert_eq!(
            scope
                .ingest(&identity(), &[event("/tmp/root/a", 1)])
                .unwrap(),
            Some(1)
        );
        assert_eq!(
            scope
                .ingest(&identity(), &[event("/tmp/root/b", 2)])
                .unwrap(),
            Some(2)
        );
        let first = scope.take_next(&identity(), None).unwrap().unwrap();
        let second = scope.take_next(&identity(), None).unwrap().unwrap();
        assert_eq!(first.lowest_accepted_watermark, 1);
        assert_eq!(second.lowest_accepted_watermark, 2);
        assert!(scope.take_next(&identity(), None).unwrap().is_none());
    }

    #[test]
    fn pressure_collapse_preserves_cut_and_ignore_controls() {
        let scope = ScopeRegistry::new()
            .open_scope(identity(), "/tmp/root".into(), 2)
            .unwrap();
        scope
            .ingest(&identity(), &[event("/tmp/root/.gitignore", 11)])
            .unwrap();
        scope
            .ingest(&identity(), &[event("/tmp/root/a", 12)])
            .unwrap();
        scope
            .ingest(&identity(), &[event("/tmp/root/b", 13)])
            .unwrap();
        let snapshot = scope.snapshot(&identity()).unwrap();
        assert_eq!(snapshot.accepted_high_watermark, 3);
        assert_eq!(snapshot.queued_payload_count, 1);
        assert!(snapshot.has_overflow_root_rescan);
        let payload = scope.take_next(&identity(), Some(3)).unwrap().unwrap();
        assert_eq!(payload.lowest_accepted_watermark, 1);
        assert_eq!(payload.accepted_high_watermark, 3);
        assert_eq!(payload.raw_entry_count(), 1);
        assert!(matches!(
            payload.contents,
            WatcherPayloadContents::OverflowRootRescan {
                highest_event_id: 13,
                ..
            }
        ));
    }

    #[test]
    fn stale_cut_does_not_consume_later_payload() {
        let scope = ScopeRegistry::new()
            .open_scope(identity(), "/tmp/root".into(), 8)
            .unwrap();
        scope
            .ingest(&identity(), &[event("/tmp/root/a", 1)])
            .unwrap();
        assert!(scope.take_next(&identity(), Some(0)).unwrap().is_none());
        assert!(scope.take_next(&identity(), Some(1)).unwrap().is_some());
    }

    #[test]
    fn reset_discards_pending_but_keeps_watermark_and_identity_fence() {
        let scope = ScopeRegistry::new()
            .open_scope(identity(), "/tmp/root".into(), 8)
            .unwrap();
        scope
            .ingest(&identity(), &[event("/tmp/root/a", 1)])
            .unwrap();
        scope.reset(&identity()).unwrap();
        assert_eq!(scope.capture_watermark(&identity()).unwrap(), 1);
        assert!(scope.take_next(&identity(), None).unwrap().is_none());
        assert_eq!(
            scope.ingest(&identity(), &[event("/tmp/root/b", 2)]),
            Err(WatcherError::ScopeClosed)
        );
    }
}
