//! Port of `DomainAgentRunProcessIdentityState` (P18). The process UUID is a correlation and
//! stale-cleanup fence, not proof that a provider process is alive; the terminal-drain
//! generation invalidates callbacks captured before a drain and is reset when a new logical
//! attempt begins.

use super::uuid::RunUuid;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct ProcessIdentityState {
    run_id: Option<RunUuid>,
    terminal_drain_generation: u64,
}

impl ProcessIdentityState {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            run_id: None,
            terminal_drain_generation: 0,
        }
    }

    #[must_use]
    pub const fn with(run_id: Option<RunUuid>, terminal_drain_generation: u64) -> Self {
        Self {
            run_id,
            terminal_drain_generation,
        }
    }

    #[must_use]
    pub const fn run_id(&self) -> Option<RunUuid> {
        self.run_id
    }

    #[must_use]
    pub const fn terminal_drain_generation(&self) -> u64 {
        self.terminal_drain_generation
    }

    /// Installs the identity for a start or resume. Re-installing the same identity is
    /// idempotent; installing a successor intentionally replaces the old identity.
    pub const fn install(&mut self, run_id: RunUuid) {
        self.run_id = Some(run_id);
    }

    /// Clears only when the caller still owns the exact process UUID. Returns whether it cleared.
    pub fn clear_if_current(&mut self, run_id: RunUuid) -> bool {
        if self.run_id != Some(run_id) {
            return false;
        }
        self.run_id = None;
        true
    }

    /// Clears for a transition whose contract is that no process may survive.
    pub const fn force_clear(&mut self) {
        self.run_id = None;
    }

    /// Callbacks captured before the drain become stale. Wrapping, like Swift `&+=`.
    pub const fn bump_terminal_drain_generation(&mut self) {
        self.terminal_drain_generation = self.terminal_drain_generation.wrapping_add(1);
    }

    /// A new attempt keeps an intentionally reused process identity but never inherits the prior
    /// attempt's drain generation.
    pub const fn reset_for_new_attempt(&mut self) {
        self.terminal_drain_generation = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uuid(byte: u8) -> RunUuid {
        RunUuid::from_bytes([byte; 16])
    }

    /// Mirrors `testProcessIdentityUsesExactRunFenceAndForceClearSemantics`.
    #[test]
    fn exact_run_fence_and_force_clear_semantics() {
        let first = uuid(1);
        let successor = uuid(2);
        let mut identity = ProcessIdentityState::new();

        identity.install(first);
        identity.bump_terminal_drain_generation();
        assert_eq!(identity.run_id(), Some(first));
        assert_eq!(identity.terminal_drain_generation(), 1);

        assert!(!identity.clear_if_current(successor));
        assert_eq!(identity.run_id(), Some(first));

        identity.install(successor);
        assert!(!identity.clear_if_current(first));
        assert_eq!(identity.run_id(), Some(successor));
        assert!(identity.clear_if_current(successor));
        assert_eq!(identity.run_id(), None);

        identity.install(first);
        identity.force_clear();
        assert_eq!(identity.run_id(), None);
    }

    #[test]
    fn force_clear_does_not_touch_drain_generation_and_bump_wraps() {
        let mut identity = ProcessIdentityState::with(Some(uuid(3)), u64::MAX);
        identity.force_clear();
        assert_eq!(identity.terminal_drain_generation(), u64::MAX);
        identity.bump_terminal_drain_generation();
        assert_eq!(identity.terminal_drain_generation(), 0);
        identity.reset_for_new_attempt();
        assert_eq!(identity, ProcessIdentityState::new());
    }
}
