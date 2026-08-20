use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use pcre2::bytes::Regex;

use super::{JitStatus, LimitPolicy};

const MAX_ENTRIES: usize = 256;
const MAX_ESTIMATED_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub(crate) struct CacheKey {
    pub(crate) pattern: String,
    pub(crate) case_insensitive: bool,
    pub(crate) multiline: bool,
    pub(crate) policy: LimitPolicy,
}

#[derive(Clone)]
pub(crate) struct CachedRegex {
    pub(crate) regex: Arc<Regex>,
    pub(crate) jit_status: JitStatus,
    pub(crate) cache_hit: bool,
}

struct Entry {
    regex: Arc<Regex>,
    jit_status: JitStatus,
    estimated_bytes: usize,
    used_at: u64,
}

#[derive(Default)]
struct State {
    entries: HashMap<CacheKey, Entry>,
    estimated_bytes: usize,
    clock: u64,
}

#[derive(Default)]
pub(crate) struct PatternCache {
    state: Mutex<State>,
}

impl PatternCache {
    pub(crate) fn get(&self, key: &CacheKey) -> Option<CachedRegex> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.clock = state.clock.wrapping_add(1);
        let used_at = state.clock;
        let entry = state.entries.get_mut(key)?;
        entry.used_at = used_at;
        Some(CachedRegex {
            regex: Arc::clone(&entry.regex),
            jit_status: entry.jit_status,
            cache_hit: true,
        })
    }

    pub(crate) fn insert(
        &self,
        key: CacheKey,
        regex: Arc<Regex>,
        jit_status: JitStatus,
    ) -> CachedRegex {
        let estimated_bytes = key.pattern.len().saturating_mul(16).saturating_add(4_096);
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.clock = state.clock.wrapping_add(1);
        let used_at = state.clock;
        if let Some(previous) = state.entries.remove(&key) {
            state.estimated_bytes = state
                .estimated_bytes
                .saturating_sub(previous.estimated_bytes);
        }
        state.estimated_bytes = state.estimated_bytes.saturating_add(estimated_bytes);
        state.entries.insert(
            key,
            Entry {
                regex: Arc::clone(&regex),
                jit_status,
                estimated_bytes,
                used_at,
            },
        );
        while state.entries.len() > MAX_ENTRIES || state.estimated_bytes > MAX_ESTIMATED_BYTES {
            let Some(oldest) = state
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.used_at)
                .map(|(key, _)| key.clone())
            else {
                break;
            };
            if let Some(removed) = state.entries.remove(&oldest) {
                state.estimated_bytes = state
                    .estimated_bytes
                    .saturating_sub(removed.estimated_bytes);
            }
        }
        CachedRegex {
            regex,
            jit_status,
            cache_hit: false,
        }
    }
}
