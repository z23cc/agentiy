import Foundation

/// Provider-neutral process identity and terminal-drain generation for one Agent run host.
///
/// The process UUID is a correlation and stale-cleanup fence, not proof that a provider process
/// is alive. The terminal-drain generation invalidates provider callbacks after a terminal drain
/// and is reset when a new logical attempt begins. This value owns no transcript, provider,
/// persistence, task, or UI state.
package struct DomainAgentRunProcessIdentityState: Equatable, Sendable {
    package private(set) var runID: UUID?
    package private(set) var terminalDrainGeneration: UInt64

    package init(
        runID: UUID? = nil,
        terminalDrainGeneration: UInt64 = 0
    ) {
        self.runID = runID
        self.terminalDrainGeneration = terminalDrainGeneration
    }

    /// Installs the process identity for a start or resume operation. Re-installing the same
    /// identity is idempotent; installing a successor intentionally replaces the old identity.
    package mutating func install(_ runID: UUID) {
        self.runID = runID
    }

    /// Clears an identity only when the caller still owns the exact process UUID. A stale
    /// provider cleanup cannot clear a successor process identity.
    @discardableResult
    package mutating func clear(ifCurrent runID: UUID) -> Bool {
        guard self.runID == runID else { return false }
        self.runID = nil
        return true
    }

    /// Clears the identity for a transition whose contract is that no process may survive.
    /// Run-scoped cleanup should use `clear(ifCurrent:)` instead.
    package mutating func forceClear() {
        runID = nil
    }

    /// Bumps the terminal-drain generation so callbacks captured before the drain become stale.
    package mutating func bumpTerminalDrainGeneration() {
        terminalDrainGeneration &+= 1
    }

    /// A new logical attempt reuses the installed process identity when appropriate, but never
    /// carries the prior attempt's provider-drain generation into the successor.
    package mutating func resetForNewAttempt() {
        terminalDrainGeneration = 0
    }
}
