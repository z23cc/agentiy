//! `ScopeRegistry`: the long-lived, ID-addressed holder of `InventoryScope` instances (§1).
//! `InventoryScope` is its first tenant; scopes are addressed by `InventoryScopeId`, never by a
//! proxy object. P4-1 leaves multi-scope-per-process granularity an open question (open question
//! 2) without deciding it -- `ScopeRegistry` supports multiple concurrently open scopes (it is a
//! map, not a singleton cell) without asserting anything about how many a real process will use.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::RuntimeIdentity;

use super::ids::InventoryScopeId;
use super::scope::{InventoryScope, InventoryScopeConfig};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScopeRegistryError {
    IdentityMismatch,
    UnknownScope,
}

#[derive(Default)]
pub struct ScopeRegistry {
    scopes: Mutex<HashMap<InventoryScopeId, Arc<InventoryScope>>>,
}

impl ScopeRegistry {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// `inventoryOpenScope`: mints an `InventoryScopeId` and registers a fresh `InventoryScope`.
    pub fn open_scope(
        &self,
        identity: RuntimeIdentity,
        config: InventoryScopeConfig,
    ) -> Arc<InventoryScope> {
        let scope_id = InventoryScopeId::mint(&super::ids::UuidMinter::fresh());
        let scope = Arc::new(InventoryScope::new(identity, scope_id, config));
        self.scopes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(scope_id, Arc::clone(&scope));
        scope
    }

    #[must_use]
    pub fn get(&self, scope_id: InventoryScopeId) -> Option<Arc<InventoryScope>> {
        self.scopes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&scope_id)
            .cloned()
    }

    /// `inventoryCloseScope`: idempotent. Closing an already-closed or unknown scope id is not an
    /// error -- matches `OperationRegistry`'s idempotent-close precedent.
    pub fn close_scope(
        &self,
        identity: &RuntimeIdentity,
        scope_id: InventoryScopeId,
    ) -> Result<(), ScopeRegistryError> {
        let scope = self
            .scopes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&scope_id);
        let Some(scope) = scope else {
            return Ok(()); // idempotent: already closed / never existed
        };
        if scope.identity() != identity {
            // Put it back: a scope-id/identity mismatch must not silently close someone else's
            // scope.
            self.scopes
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .insert(scope_id, Arc::clone(&scope));
            return Err(ScopeRegistryError::IdentityMismatch);
        }
        scope.close(identity).ok();
        Ok(())
    }

    #[must_use]
    pub fn scope_count(&self) -> usize {
        self.scopes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(nonce: char) -> RuntimeIdentity {
        RuntimeIdentity::new(
            1,
            nonce.to_string().repeat(32),
            "a".repeat(64),
            "b".repeat(64),
        )
        .expect("identity")
    }

    #[test]
    fn open_then_get_then_close_round_trips() {
        let registry = ScopeRegistry::new();
        let identity = identity('a');
        let scope = registry.open_scope(identity.clone(), InventoryScopeConfig::default());
        let id = scope.scope_id();
        assert!(registry.get(id).is_some());
        assert_eq!(registry.scope_count(), 1);
        registry.close_scope(&identity, id).expect("close");
        assert!(registry.get(id).is_none());
        assert_eq!(registry.scope_count(), 0);
    }

    #[test]
    fn closing_unknown_scope_is_idempotent_not_an_error() {
        let registry = ScopeRegistry::new();
        let identity = identity('a');
        let bogus = InventoryScopeId::mint(&super::super::ids::UuidMinter::fresh());
        assert_eq!(registry.close_scope(&identity, bogus), Ok(()));
    }

    #[test]
    fn wrong_identity_cannot_close_someone_elses_scope() {
        let registry = ScopeRegistry::new();
        let owner = identity('a');
        let intruder = identity('b');
        let scope = registry.open_scope(owner, InventoryScopeConfig::default());
        let id = scope.scope_id();
        assert_eq!(
            registry.close_scope(&intruder, id),
            Err(ScopeRegistryError::IdentityMismatch)
        );
        assert!(registry.get(id).is_some());
    }

    #[test]
    fn multiple_scopes_coexist_independently() {
        let registry = ScopeRegistry::new();
        let scope_a = registry.open_scope(identity('a'), InventoryScopeConfig::default());
        let scope_b = registry.open_scope(identity('b'), InventoryScopeConfig::default());
        assert_ne!(scope_a.scope_id(), scope_b.scope_id());
        assert_eq!(registry.scope_count(), 2);
    }
}
