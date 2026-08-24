#if DEBUG
    import Foundation

    /// P6-7 (`docs/designs/p6-claude-vertical-2026-08-23.md` §11 P6-7): the DEBUG-only selection
    /// flag that lets a developer opt an interactive `claudeCode` Agent Mode session into the
    /// Rust-backed `NativeAgentRuntimeControlling` arm (`ClaudeRustBackedNativeSessionAdapter`)
    /// instead of the still-authoritative `ClaudeCompatibleNativeSessionAdapter` /
    /// `ClaudeNativeProcessSessionController` path. Wired at
    /// `ClaudeAgentModeCoordinator.makeDefaultController`.
    ///
    /// **Deliberately an environment variable, not an `app_settings`/UserDefaults key.** This
    /// arm is not authoritative (design §11 P6-7's own step-list line: "still not authoritative"),
    /// has no product-facing UI, and is not itself a persistent user preference -- it is a
    /// developer-only lever for the P6-8 real-CLI soak (item 8, separately gated on user
    /// approval) and ad hoc manual verification. An env var keeps it out of the persisted
    /// settings surface entirely, with no migration/reset concern once P6-8 deletes this whole
    /// file (design §15.3 item 10: no permanent per-domain switch survives cutover).
    ///
    /// **Release absence.** This entire file is `#if DEBUG`-gated, as is its only call site
    /// (`ClaudeAgentModeCoordinator.makeDefaultController`'s Rust-arm branch) and the adapter type
    /// itself (`ClaudeRustBackedNativeSessionAdapter.swift`). A release build therefore contains no
    /// reference to this flag, the env var name, or the adapter type at all -- verified by
    /// `ClaudeRustBackedAdapterReleaseAbsenceTests`.
    enum ClaudeRustBackedNativeSessionAdapterSelection {
        static let environmentVariableName = "AGENTRY_CLAUDE_RUST_BACKED_ADAPTER"

        static var isEnabled: Bool {
            isEnabled(environment: ProcessInfo.processInfo.environment)
        }

        static func isEnabled(environment: [String: String]) -> Bool {
            guard let raw = environment[environmentVariableName]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return false
            }
            return raw == "1" || raw == "true" || raw == "yes"
        }
    }
#endif
