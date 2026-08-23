#if DEBUG
    import Foundation

    // P6-5 (`docs/designs/p6-claude-vertical-2026-08-23.md` §11 P6-5, `docs/architecture/
    // rust-agent-claude-v1.md` §14): raw, hand-declared bindings for the sole per-line FFI export
    // this vertical ever carries -- `agent_claude_decode_line_debug_v1`
    // (`rust/crates/runtime/src/agent_claude/debug_shadow_ffi.rs`), DEBUG-only on both sides
    // (`#[cfg(debug_assertions)]` Rust-side, this whole file `#if DEBUG`-gated Swift-side).
    //
    // **Why `@_silgen_name` instead of a `CAgentryRustCore` header + `module.modulemap` entry.**
    // Both of those files are UniFFI/xtask-generated (`rust/ffi-contract/generated-manifest.json`
    // fingerprints them); hand-editing either risks a silent overwrite on the next
    // `cargo run -p xtask -- generate`, or requires teaching that tool about a symbol it must
    // never itself generate (this symbol is deliberately outside UniFFI's scaffolding -- see the
    // Rust module's own doc for why). `@_silgen_name` resolves a C-ABI symbol by its linker name
    // directly, with no header/modulemap involvement: the symbol is present in `libagentry_ffi.a`
    // (already linked transitively into this target via `AgentryUniFFIRaw` -> `CAgentryRustCore`)
    // for a debug archive and absent for a release archive, so a release build of this file simply
    // never resolves it -- but the file itself is also `#if DEBUG`-gated regardless, so release
    // Swift compilation never even emits a reference to try to resolve.

    @_silgen_name("agent_claude_debug_shadow_open_v1")
    private func rpce_agent_claude_debug_shadow_open_v1() -> UInt64

    @_silgen_name("agent_claude_debug_shadow_close_v1")
    private func rpce_agent_claude_debug_shadow_close_v1(_ handle: UInt64)

    @_silgen_name("agent_claude_decode_line_debug_v1")
    private func rpce_agent_claude_decode_line_debug_v1(
        _ handle: UInt64,
        _ linePointer: UnsafePointer<UInt8>?,
        _ lineLength: Int,
        _ outLength: UnsafeMutablePointer<Int>
    ) -> UnsafeMutablePointer<UInt8>?

    @_silgen_name("agent_claude_debug_shadow_free_buffer_v1")
    private func rpce_agent_claude_debug_shadow_free_buffer_v1(_ pointer: UnsafeMutablePointer<UInt8>?, _ length: Int)

    /// DEBUG-only Swift wrapper session over the raw symbol quartet above. One instance per live
    /// Claude session for the lifetime the shadow comparator is attached (opened alongside the real
    /// controller's session, closed at `deinit`) -- mirrors
    /// `rust/crates/runtime/src/agent_claude/debug_shadow_ffi.rs`'s own ownership model doc.
    public final class ClaudeCodecDebugShadowSession {
        private let handle: UInt64

        public init() {
            handle = rpce_agent_claude_debug_shadow_open_v1()
        }

        deinit {
            rpce_agent_claude_debug_shadow_close_v1(handle)
        }

        /// Decodes one inbound protocol line through the Rust shadow arm, returning the raw JSON
        /// outcome payload (`{"kind": "stream"|"non_stream"|"not_comparable"|"unknown_handle",
        /// "results": [...]}`, `debug_shadow_ffi.rs`'s `outcome_to_json`) as `Data` for the caller
        /// to parse. An empty `Data` return (rather than a thrown error) signals the Rust side
        /// returned a null pointer, which the current implementation never actually does but which
        /// this wrapper handles defensively rather than force-unwrapping.
        public func decodeLine(_ lineData: Data) -> Data {
            var outLength = 0
            let resultPointer: UnsafeMutablePointer<UInt8>? = lineData.withUnsafeBytes { rawBuffer in
                let basePointer = rawBuffer.bindMemory(to: UInt8.self).baseAddress
                return rpce_agent_claude_decode_line_debug_v1(handle, basePointer, lineData.count, &outLength)
            }
            guard let resultPointer else { return Data() }
            defer { rpce_agent_claude_debug_shadow_free_buffer_v1(resultPointer, outLength) }
            return Data(bytes: resultPointer, count: outLength)
        }
    }
#endif
