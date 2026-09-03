# ADR-0014: File System Watcher Ingress Authority — Swift Platform Stream Adapter Canonical with Rust Watermark Queue (Charter Phase 7 / §18 Item 6 Resolution)

**Status:** Accepted (charter §16 Phase 7, §18 item 6; User ruling 2026-09-03)
**Date:** 2026-09-03
**Decision owner:** User
**Governing decisions:** Charter §16 Phase 7, §18 item 6; ADR-0001, ADR-0003, ADR-0007, ADR-0008
**Related specifications:** `rust/crates/runtime/src/agent_watcher.rs`, `Sources/AgentryCoreBridge/CoreFileSystemWatcherSession.swift`

---

## Context

Charter §18 Item 6 left an open architectural question:
> "6. FSEvents 长期留 Swift adapter 还是迁 Rust；先以现有 watermark/barrier 合同做 parity harness。"

File system change observation on macOS depends on the Darwin CoreServices `FSEventStream` C API. Two competing end-state topologies were considered:

1. **Pure Rust Watcher**: Porting the entire OS event stream subscription into Rust using third-party crates (e.g., `notify`, `fsevent-sys`, or raw `core-foundation-sys`), driving `CFRunLoop` or `dispatch` directly from Rust threads.
2. **Split Authority (Swift Platform Adapter + Rust Ingress Authority)**: Retaining the native Darwin event stream lifecycle in Swift, while placing all event queuing, monotonic watermarking, FIFO sequencing, backpressure collapsing, and overflow syntheses into `agentry-runtime::agent_watcher`.

---

## Decision

1. **Swift Darwin Platform Adapter is Canonical**:
   - The native Swift adapter (`Sources/AgentryCoreBridge/CoreFileSystemWatcherSession.swift` and `Sources/RepoPrompt/Infrastructure/FileSystem/`) remains the permanent, canonical bridge to macOS CoreServices `FSEventStream`.
   - Third-party Rust filesystem watching crates (`notify`, `fsevent-sys`, `fsevent`) are **explicitly banned** to preserve ADR-0007 supply-chain discipline and avoid foreign thread/runloop lifecycle hazards.

2. **Rust Owns Sole Ingress, Queue, and Watermark Authority**:
   - CoreServices and Swift own the OS platform stream and callback invocation, but **must never** own the accepted-event queue or collapse logic.
   - `agentry_runtime::agent_watcher` (`AgentWatcherScope`) receives already-owned event values, assigns monotonic per-scope watermarks, preserves strict FIFO delivery, and deterministically collapses bounded pressure into an explicit `OverflowRootRescan` payload.
   - No raw callback pointer, runloop reference, or platform Darwin object crosses the UniFFI boundary (conforming strictly to ADR-0001).

3. **Strict Zero-Queue Swift Invariant**:
   - The Swift platform callback must perform immediate forwarding into Rust or drop based on static path early-filters (`FileSystemWatcherEarlyFilter`).
   - Swift is prohibited from maintaining secondary in-memory event queues, duplicate watermarks, or independent debounce accumulators. All debounce and overflow semantics belong to Rust.

4. **Stream Resilience and Scope Reset**:
   - Watcher scopes in Rust are reusable across stream restarts.
   - Stream interruptions or path resubscriptions trigger a scope `reset`, which discards pending transient evidence while preserving the monotonic high-watermark progression.

---

## Consequences

- **Charter §18 Item 6 Formally Resolved**: The long-term architecture for filesystem watching is permanently locked: Swift provides the platform Darwin stream; Rust owns ingress authority, watermarks, and backpressure.
- **Zero Third-Party Crate Overhead**: Eliminates the need to pull in external macOS FFI crates into the Rust workspace, maintaining the lean dependency graph mandated by ADR-0007.
- **Strict Concurrency Safety**: Prevents Darwin CFRunLoop and dispatch queue threading models from leaking into Rust executor runtimes or corrupting actor boundaries.
