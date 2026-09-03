//! Port of `DomainAgentRunTerminalSettlementCoordinator` (P16): bounded provider-successor
//! tombstones and ownership-bound teardown tokens. It never stores a task, closure, transcript, or
//! UI reference; hosts keep those and use the token fence when they complete them.

use std::collections::{BTreeMap, HashSet, VecDeque};

use super::types::Ownership;
use super::uuid::RunUuid;

/// `DomainAgentRunTerminalSettlementCoordinator.maxProviderSuccessorTombstones`.
pub const MAX_PROVIDER_SUCCESSOR_TOMBSTONES: usize = 512;

/// `DomainAgentRunTerminalTeardownRegistrationResult`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TeardownRegistrationResult {
    Registered,
    AlreadyRegistered,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TerminalSettlementCoordinator {
    consumed_provider_successor_ids: HashSet<RunUuid>,
    consumed_provider_successor_order: VecDeque<RunUuid>,
    // Ordered so canonical serialization is deterministic; Swift uses an unordered dictionary
    // whose iteration order is never observed.
    teardown_token_by_ownership: BTreeMap<Ownership, RunUuid>,
}

impl TerminalSettlementCoordinator {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn has_consumed_provider_successor(&self, id: RunUuid) -> bool {
        self.consumed_provider_successor_ids.contains(&id)
    }

    /// Records a successfully delivered successor callback. Failed deliveries are deliberately not
    /// tombstoned so a later publication retry can deliver the successor again. Returns whether a
    /// new tombstone was recorded.
    pub fn record_provider_successor_consumption(
        &mut self,
        id: RunUuid,
        delivery_succeeded: bool,
    ) -> bool {
        if !delivery_succeeded {
            return false;
        }
        if !self.consumed_provider_successor_ids.insert(id) {
            return false;
        }
        self.consumed_provider_successor_order.push_back(id);
        while self.consumed_provider_successor_order.len() > MAX_PROVIDER_SUCCESSOR_TOMBSTONES {
            if let Some(expired) = self.consumed_provider_successor_order.pop_front() {
                self.consumed_provider_successor_ids.remove(&expired);
            }
        }
        true
    }

    #[must_use]
    pub fn consumed_provider_successor_count(&self) -> usize {
        self.consumed_provider_successor_ids.len()
    }

    /// Oldest-first tombstone order (the FIFO eviction order).
    pub fn consumed_provider_successor_ids_in_order(&self) -> impl Iterator<Item = &RunUuid> {
        self.consumed_provider_successor_order.iter()
    }

    pub fn register_teardown(
        &mut self,
        ownership: Ownership,
        token: RunUuid,
    ) -> TeardownRegistrationResult {
        if self.teardown_token_by_ownership.contains_key(&ownership) {
            return TeardownRegistrationResult::AlreadyRegistered;
        }
        self.teardown_token_by_ownership.insert(ownership, token);
        TeardownRegistrationResult::Registered
    }

    #[must_use]
    pub fn has_pending_teardown(&self, ownership: Ownership) -> bool {
        self.teardown_token_by_ownership.contains_key(&ownership)
    }

    #[must_use]
    pub fn teardown_token(&self, ownership: Ownership) -> Option<RunUuid> {
        self.teardown_token_by_ownership.get(&ownership).copied()
    }

    /// Completes only the currently registered token; a stale completion from an older host task
    /// cannot clear a replacement obligation.
    pub fn complete_teardown(&mut self, ownership: Ownership, token: RunUuid) -> bool {
        if self.teardown_token_by_ownership.get(&ownership) != Some(&token) {
            return false;
        }
        self.teardown_token_by_ownership.remove(&ownership);
        true
    }

    /// Pending teardown obligations in canonical (ownership) order.
    pub fn pending_teardowns(&self) -> impl Iterator<Item = (&Ownership, &RunUuid)> {
        self.teardown_token_by_ownership.iter()
    }

    pub fn reset(&mut self) {
        self.consumed_provider_successor_ids.clear();
        self.consumed_provider_successor_order.clear();
        self.teardown_token_by_ownership.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_run_lifecycle::types::BindingIdentity;

    fn uuid(byte: u8) -> RunUuid {
        RunUuid::from_bytes([byte; 16])
    }

    fn uuid_n(value: u32) -> RunUuid {
        let mut bytes = [0u8; 16];
        bytes[12..].copy_from_slice(&value.to_be_bytes());
        RunUuid::from_bytes(bytes)
    }

    fn ownership(seed: u8) -> Ownership {
        Ownership {
            attempt_id: uuid(seed),
            binding: BindingIdentity {
                tab_id: uuid(seed.wrapping_add(50)),
                persistent_session_id: Some(uuid(seed.wrapping_add(100))),
                persistent_binding_generation: None,
                binding_transition_generation: 0,
                generation: uuid(seed.wrapping_add(150)),
            },
            turn_epoch: None,
        }
    }

    /// Mirrors `testProviderSuccessorConsumptionIsExactlyOnce`.
    #[test]
    fn provider_successor_consumption_is_exactly_once() {
        let mut coordinator = TerminalSettlementCoordinator::new();
        let successor = uuid(1);
        assert!(!coordinator.has_consumed_provider_successor(successor));
        assert!(coordinator.record_provider_successor_consumption(successor, true));
        assert!(coordinator.has_consumed_provider_successor(successor));
        assert!(!coordinator.record_provider_successor_consumption(successor, true));
        assert_eq!(coordinator.consumed_provider_successor_count(), 1);
    }

    /// Mirrors `testFailedSuccessorDeliveryDoesNotCreateATombstone`.
    #[test]
    fn failed_successor_delivery_does_not_create_a_tombstone() {
        let mut coordinator = TerminalSettlementCoordinator::new();
        let successor = uuid(1);
        assert!(!coordinator.has_consumed_provider_successor(successor));
        assert_eq!(coordinator.consumed_provider_successor_count(), 0);
        assert!(!coordinator.record_provider_successor_consumption(successor, false));
        assert!(!coordinator.has_consumed_provider_successor(successor));
        assert!(coordinator.record_provider_successor_consumption(successor, true));
    }

    /// Mirrors `testSuccessorTombstonesUseBoundedFIFOEviction`.
    #[test]
    fn successor_tombstones_use_bounded_fifo_eviction() {
        let mut coordinator = TerminalSettlementCoordinator::new();
        let first = uuid_n(1_000_000);
        assert!(coordinator.record_provider_successor_consumption(first, true));
        for index in 1..MAX_PROVIDER_SUCCESSOR_TOMBSTONES {
            assert!(coordinator.record_provider_successor_consumption(
                uuid_n(u32::try_from(index).unwrap()),
                true
            ));
        }
        assert_eq!(
            coordinator.consumed_provider_successor_count(),
            MAX_PROVIDER_SUCCESSOR_TOMBSTONES
        );
        assert!(coordinator.has_consumed_provider_successor(first));

        let newest = uuid_n(2_000_000);
        assert!(coordinator.record_provider_successor_consumption(newest, true));
        assert_eq!(
            coordinator.consumed_provider_successor_count(),
            MAX_PROVIDER_SUCCESSOR_TOMBSTONES
        );
        assert!(!coordinator.has_consumed_provider_successor(first));
        assert!(coordinator.has_consumed_provider_successor(newest));
    }

    /// Mirrors `testTeardownRegistrationAndCompletionAreTokenBound`.
    #[test]
    fn teardown_registration_and_completion_are_token_bound() {
        let mut coordinator = TerminalSettlementCoordinator::new();
        let owner = ownership(1);
        let token = uuid(7);
        let stale = uuid(8);
        assert_eq!(
            coordinator.register_teardown(owner, token),
            TeardownRegistrationResult::Registered
        );
        assert!(coordinator.has_pending_teardown(owner));
        assert_eq!(coordinator.teardown_token(owner), Some(token));
        assert_eq!(
            coordinator.register_teardown(owner, uuid(9)),
            TeardownRegistrationResult::AlreadyRegistered
        );
        assert!(!coordinator.complete_teardown(owner, stale));
        assert!(coordinator.has_pending_teardown(owner));
        assert!(coordinator.complete_teardown(owner, token));
        assert!(!coordinator.has_pending_teardown(owner));
        assert!(!coordinator.complete_teardown(owner, token));
    }

    /// Mirrors `testTeardownTokensAreIndependentAcrossOwners`.
    #[test]
    fn teardown_tokens_are_independent_across_owners() {
        let mut coordinator = TerminalSettlementCoordinator::new();
        let first = ownership(1);
        let second = ownership(2);
        let first_token = uuid(7);
        let second_token = uuid(8);
        assert_eq!(
            coordinator.register_teardown(first, first_token),
            TeardownRegistrationResult::Registered
        );
        assert_eq!(
            coordinator.register_teardown(second, second_token),
            TeardownRegistrationResult::Registered
        );
        assert!(coordinator.complete_teardown(first, first_token));
        assert!(!coordinator.has_pending_teardown(first));
        assert!(coordinator.has_pending_teardown(second));
        assert!(coordinator.complete_teardown(second, second_token));
    }

    /// Mirrors `testResetClearsSettlementFences`.
    #[test]
    fn reset_clears_settlement_fences() {
        let mut coordinator = TerminalSettlementCoordinator::new();
        let owner = ownership(1);
        let successor = uuid(3);
        let token = uuid(7);
        assert!(coordinator.record_provider_successor_consumption(successor, true));
        assert_eq!(
            coordinator.register_teardown(owner, token),
            TeardownRegistrationResult::Registered
        );
        coordinator.reset();
        assert!(!coordinator.has_consumed_provider_successor(successor));
        assert!(!coordinator.has_pending_teardown(owner));
        assert_eq!(coordinator.teardown_token(owner), None);
        assert_eq!(coordinator, TerminalSettlementCoordinator::new());
    }
}
