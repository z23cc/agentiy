import AgentryCoreBridge
import Foundation
import os

/// Bridges the Rust core's WARN/ERROR diagnostics ring buffer
/// (`agentry_runtime::observability`, drained through
/// `AgentryCoreBridge.coreDiagnosticsDrain()`) into macOS unified logging.
///
/// Rewrite charter §11.7: "agentry-runtime 内建 tracing，桥接到
/// os_log/os_signpost（Instruments 可见）与现有诊断文件通道，signpost 命名
/// 沿用现有领域前缀". This type is that bridge -- implemented entirely in
/// Swift rather than by adding a `tracing`/os_log-backend Rust crate:
/// `import os` (`OSLog`, `os_signpost`) is already available here with zero
/// new dependencies, zero `unsafe` (every Rust crate in this workspace is
/// `#![forbid(unsafe_code)]`), and zero `Cargo.lock` churn in a tree several
/// other agents are mid-edit on. See `agentry_runtime::observability`'s
/// module doc comment for the full "why not `tracing`" rationale. Rust's job
/// is only to record WARN/ERROR events into a bounded, pull-based ring
/// buffer (`agentry_runtime::observability::record_diagnostic`) and to keep
/// timing/diagnostic surfaces like `InventoryScope::diagnostics()`
/// FFI-readable; this type is the pull side, matching the callback-free
/// drain shape §9.5 already requires for the main subscription event queue.
enum CoreObservabilityBridge {
    /// Single subsystem for every Rust-core diagnostic, matching the
    /// charter's literal `"agentry.core"` naming so every consumer (this
    /// bridge, any future call site, Instruments filters) agrees on it.
    static let subsystem = "agentry.core"

    private static let log = OSLog(subsystem: subsystem, category: "runtime")

    /// Drains every currently-buffered Rust-core diagnostic event and
    /// forwards each to os_log at a severity derived from the record itself.
    /// Safe to call from any thread/actor and safe to call repeatedly --
    /// draining is destructive on the Rust side (see
    /// `agentry_runtime::observability::drain_diagnostics`), so repeated
    /// calls never double-log the same event; an empty buffer (the common
    /// case) costs one cheap FFI round trip and logs nothing.
    ///
    /// No caller wires this into a periodic tick yet, and nothing in the
    /// Rust tree calls `record_diagnostic` yet either -- both are follow-up
    /// work called out explicitly in the observability handoff report,
    /// deliberately left out of this change so it stays additive and
    /// reviewable: the recommended call sites sit in files this session
    /// either cannot touch (forbidden for the duration of concurrent
    /// migration work) or has no evidence are safe to touch without risking
    /// a collision with that work.
    static func drainToOSLog() {
        for record in AgentryCoreBridge.coreDiagnosticsDrain() {
            os_log("%{public}s", log: log, type: osLogType(for: record), record)
        }
    }

    /// Best-effort severity sniff from the Rust-formatted `describe()` line
    /// (`"[WARN] ..."` / `"[ERROR] ..."` -- see
    /// `agentry_runtime::observability::DiagnosticRecord::describe`).
    /// `os_log` has no direct "warning" type; the `log`-facade convention
    /// (and the `oslog` crate's own level mapping) is WARN -> `.default`,
    /// ERROR -> `.error`, which this mirrors. Defaults to `.error` on
    /// anything unrecognized so a future format change fails loud in
    /// Instruments rather than silently downgrading to `.default`.
    private static func osLogType(for record: String) -> OSLogType {
        if record.hasPrefix("[WARN]") { return .default }
        if record.hasPrefix("[ERROR]") { return .error }
        return .error
    }
}

/// A begin/end `os_signpost` interval for one of the charter's named heavy
/// operations (codemap batch, search batch, inventory bulk), Instruments-
/// visible under the shared `"agentry.core"` subsystem. Reuses the existing
/// domain-prefix vocabulary (`"codemap"`, `"search"`, `"inventory"`) this
/// codebase's Sentry categories and FFI diagnostics already share -- charter
/// §11.7: "signpost 命名沿用现有领域前缀".
///
/// Deliberately a Swift-side wrapper, not a Rust FFI addition: every call
/// site this would wrap already has a natural Swift-side begin/end pair
/// (the `await client.someBatch(...)` call boundary in `AgentryCoreBridge`
/// consumers), so a signpost interval is free to add here with zero new
/// Rust surface. No call site is wired yet -- see the observability
/// handoff report for the recommended adoption points and why they were
/// left for a follow-up change instead of being wired in this one.
struct CoreOperationSignpost {
    private let log: OSLog
    private let name: StaticString
    private let signpostID: OSSignpostID

    /// - Parameters:
    ///   - domain: existing domain prefix (e.g. `"codemap"`, `"search"`,
    ///     `"inventory"`), used as the os_log category so Instruments can
    ///     filter per domain independently of the WARN/ERROR log above.
    ///   - name: signpost interval name shown in Instruments; must be a
    ///     compile-time string literal (the `os_signpost` API's format-
    ///     string requirement).
    init(domain: String, name: StaticString) {
        log = OSLog(subsystem: CoreObservabilityBridge.subsystem, category: domain)
        self.name = name
        signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: signpostID)
    }

    /// Ends the interval. Callers are responsible for calling this exactly
    /// once (e.g. in a `defer`) -- there is no automatic `deinit`-based end,
    /// matching this codebase's existing convention that lifecycle actions
    /// must not rely on `deinit` as their primary mechanism.
    func end() {
        os_signpost(.end, log: log, name: name, signpostID: signpostID)
    }
}
