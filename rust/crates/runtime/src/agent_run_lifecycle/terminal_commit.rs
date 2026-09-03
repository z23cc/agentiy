//! Port of `DomainAgentRunTerminalCommitState` (P15): the exclusive terminal-commit phase, the
//! staged receipt binding a commit ID to one ownership, and the publication-result receipt. It
//! executes no teardown and publishes nothing; hosts apply the accepted state.

use super::types::{Ownership, TerminalPublicationResult};
use super::uuid::RunUuid;

/// `DomainAgentRunTerminalCommitBeginResult`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TerminalCommitBeginResult {
    Acquired,
    AlreadyInProgress,
    StaleOwnership,
}

/// `DomainAgentRunTerminalCommitReceipt`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TerminalCommitReceipt {
    pub commit_id: RunUuid,
    pub ownership: Ownership,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TerminalCommitState {
    is_in_progress: bool,
    staged_receipt: Option<TerminalCommitReceipt>,
    publication_result: Option<TerminalPublicationResult>,
    phase_ownership: Option<Ownership>,
}

impl TerminalCommitState {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            is_in_progress: false,
            staged_receipt: None,
            publication_result: None,
            phase_ownership: None,
        }
    }

    #[must_use]
    pub const fn is_in_progress(&self) -> bool {
        self.is_in_progress
    }

    #[must_use]
    pub const fn staged_receipt(&self) -> Option<&TerminalCommitReceipt> {
        self.staged_receipt.as_ref()
    }

    #[must_use]
    pub const fn publication_result(&self) -> Option<&TerminalPublicationResult> {
        self.publication_result.as_ref()
    }

    /// The owner the phase is bound to, once any `begin(Some(_))` or `stage` has named one.
    #[must_use]
    pub const fn phase_ownership(&self) -> Option<&Ownership> {
        self.phase_ownership.as_ref()
    }

    pub fn begin(&mut self, ownership: Option<Ownership>) -> TerminalCommitBeginResult {
        if self.is_in_progress {
            return TerminalCommitBeginResult::AlreadyInProgress;
        }
        if let (Some(existing), Some(ownership)) = (self.phase_ownership, ownership)
            && existing != ownership
        {
            return TerminalCommitBeginResult::StaleOwnership;
        }
        self.is_in_progress = true;
        if let Some(ownership) = ownership {
            self.phase_ownership = Some(ownership);
        }
        TerminalCommitBeginResult::Acquired
    }

    /// Compatibility call sites stage before acquiring the phase; once a phase owner exists,
    /// successor/stale owners are rejected. The owner survives the end of active liveness because
    /// the barrier stages after draining the provider and ending the active run state.
    pub fn stage(&mut self, commit_id: RunUuid, ownership: Ownership) -> bool {
        if !(self.phase_ownership.is_none() || self.phase_ownership == Some(ownership)) {
            return false;
        }
        self.phase_ownership = Some(ownership);
        self.staged_receipt = Some(TerminalCommitReceipt {
            commit_id,
            ownership,
        });
        // A newly staged commit invalidates the result from any prior phase.
        self.publication_result = None;
        true
    }

    /// Intentionally unguarded: a retry may deliver its result after the phase completed, and
    /// binding invalidation can clear the receipt while publication is suspended.
    pub fn record(&mut self, result: TerminalPublicationResult) {
        self.publication_result = Some(result);
    }

    pub const fn abort(&mut self) {
        self.is_in_progress = false;
    }

    pub const fn complete(&mut self) {
        self.is_in_progress = false;
    }

    pub fn invalidate(&mut self) {
        self.staged_receipt = None;
        self.publication_result = None;
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    #[must_use]
    pub fn matches(&self, ownership: Ownership) -> bool {
        self.staged_receipt
            .is_some_and(|receipt| receipt.ownership == ownership)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_run_lifecycle::types::BindingIdentity;

    fn uuid(byte: u8) -> RunUuid {
        RunUuid::from_bytes([byte; 16])
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

    /// Mirrors `testPhaseIsExclusiveAndReportsTypedRejection`.
    #[test]
    fn phase_is_exclusive_and_reports_typed_rejection() {
        let mut state = TerminalCommitState::new();
        assert_eq!(state.begin(None), TerminalCommitBeginResult::Acquired);
        assert_eq!(
            state.begin(None),
            TerminalCommitBeginResult::AlreadyInProgress
        );
        assert!(state.is_in_progress());
        state.abort();
        assert!(!state.is_in_progress());
        assert_eq!(state.begin(None), TerminalCommitBeginResult::Acquired);
    }

    /// Mirrors `testStagedReceiptBindsCommitToOwnershipAndClearsPriorResult`.
    #[test]
    fn staged_receipt_binds_commit_to_ownership_and_clears_prior_result() {
        let mut state = TerminalCommitState::new();
        let owner = ownership(1);
        let commit_id = uuid(9);
        state.record(TerminalPublicationResult::Stale);
        assert!(state.stage(commit_id, owner));
        assert_eq!(
            state.staged_receipt(),
            Some(&TerminalCommitReceipt {
                commit_id,
                ownership: owner
            })
        );
        assert_eq!(state.publication_result(), None);
        assert!(state.matches(owner));
        assert!(!state.matches(ownership(2)));
    }

    /// Mirrors `testPublicationResultMayArriveAfterPhaseCompletes`.
    #[test]
    fn publication_result_may_arrive_after_phase_completes() {
        let mut state = TerminalCommitState::new();
        let owner = ownership(1);
        let _ = state.begin(Some(owner));
        assert!(state.stage(uuid(9), owner));
        state.complete();
        state.record(TerminalPublicationResult::Rejected {
            reason: "transient".to_owned(),
        });
        assert!(!state.is_in_progress());
        assert_eq!(
            state.publication_result(),
            Some(&TerminalPublicationResult::Rejected {
                reason: "transient".to_owned()
            })
        );
        assert!(state.matches(owner));
    }

    /// Mirrors `testBeginRejectsOwnerChangedAfterCompatibilityPreStage`.
    #[test]
    fn begin_rejects_owner_changed_after_compatibility_pre_stage() {
        let mut state = TerminalCommitState::new();
        let first = ownership(1);
        let successor = ownership(2);
        assert!(state.stage(uuid(9), first));
        assert_eq!(
            state.begin(Some(successor)),
            TerminalCommitBeginResult::StaleOwnership
        );
        assert!(!state.is_in_progress());
        assert!(state.matches(first));
    }

    #[test]
    fn begin_without_ownership_never_binds_and_reset_clears_everything() {
        let mut state = TerminalCommitState::new();
        assert_eq!(state.begin(None), TerminalCommitBeginResult::Acquired);
        assert_eq!(state.phase_ownership(), None);
        state.complete();
        let owner = ownership(1);
        assert_eq!(
            state.begin(Some(owner)),
            TerminalCommitBeginResult::Acquired
        );
        assert_eq!(state.phase_ownership(), Some(&owner));
        // A different owner cannot stage while the phase belongs to `owner` even after complete.
        state.complete();
        assert!(!state.stage(uuid(9), ownership(2)));
        state.invalidate();
        assert_eq!(
            state.phase_ownership(),
            Some(&owner),
            "invalidate keeps the owner"
        );
        state.reset();
        assert_eq!(state, TerminalCommitState::new());
    }
}
