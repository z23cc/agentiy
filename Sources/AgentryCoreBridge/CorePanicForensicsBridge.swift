import os

/// A Rust panic-driven runtime invalidation, ready for a production
/// diagnostics channel to attach the captured Rust panic record to whatever
/// error report it is filing for the enclosing `.internalPanic` /
/// `.runtimePoisoned` mapped error.
///
/// See the rewrite charter §11.7: "Rust panic guard 捕获的 panic 携带 Rust
/// backtrace 经 Swift 侧上报 Sentry（复用现有 enable/disable 与隐私开关），
/// 单通道，不引入 sentry-rust 第二 SDK." This event is the payload for that
/// single channel.
public struct CorePanicForensicsEvent: Sendable, Equatable {
    /// Description of the mapped-error call site that observed the panic
    /// (e.g. `"compute transport error: internalPanic"`), matching the text
    /// already recorded in `AgentryCoreBridge`'s DEBUG invalidation log --
    /// see `noteInvalidationTrigger`.
    public let trigger: String

    /// The Rust-side panic ring buffer contents at the moment of
    /// invalidation, oldest first -- see `PanicRecord::describe` in
    /// `rust/crates/runtime/src/panic_forensics.rs`. Never empty when this
    /// event fires (see `CorePanicForensicsBridge.notify`).
    public let panicRecords: [String]
}

/// A closure that receives every panic-driven `AgentryCoreBridge`
/// invalidation in this process.
public typealias CorePanicForensicsObserver = @Sendable (CorePanicForensicsEvent) -> Void

/// A process-wide, opt-in sink for `CorePanicForensicsEvent`s.
///
/// `AgentryCoreBridge` is a low-level target that must not depend upward on
/// any app-level telemetry SDK (the rewrite charter's dependency direction
/// rule, §12.2: `RepoPromptApp -> AgentryCoreBridge -> AgentryUniFFIRaw`,
/// never the reverse). This is the seam that lets a host app register
/// interest without that dependency: a host sets
/// `CorePanicForensicsBridge.setObserver` once at startup (alongside
/// wherever it starts its own telemetry SDK) to receive every panic-driven
/// invalidation, across every `AgentryCoreBridge` instance in the process.
///
/// Left unset (`nil`) by default, so tests, the headless `agentry-mcp`
/// process, and any other host with no interest in this signal pay nothing
/// and see no behavior change -- `AgentryCoreBridge.invalidate()` always
/// keeps working identically whether or not an observer is registered.
///
/// Fires at most once per invalidation, synchronously, on whatever
/// isolation context `AgentryCoreBridge.invalidate()` happens to be running
/// on. Observers must be cheap and must not block or re-enter any
/// `AgentryCoreBridge` -- hop actors or queue their own work if they need
/// to do I/O.
public enum CorePanicForensicsBridge {
    private static let storage = OSAllocatedUnfairLock<CorePanicForensicsObserver?>(initialState: nil)

    /// Registers (or clears, with `nil`) the process-wide observer. Last
    /// write wins; there is intentionally only one slot -- this is a single
    /// diagnostics channel, not a general pub/sub bus (charter §11.7: "单
    /// 通道，不引入 sentry-rust 第二 SDK").
    public static func setObserver(_ observer: CorePanicForensicsObserver?) {
        storage.withLock { $0 = observer }
    }

    /// Called by `AgentryCoreBridge.invalidate()` exactly when the
    /// invalidation was panic-driven (`panicRecords` non-empty). Not part of
    /// the public API surface: hosts only ever set an observer, never
    /// trigger one.
    static func notify(_ event: CorePanicForensicsEvent) {
        let observer = storage.withLock { $0 }
        observer?(event)
    }
}
