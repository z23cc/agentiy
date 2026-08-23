import AgentryCoreBridge
import Foundation

/// P4-7b b1/b2's root-generation identity triple (rootID + lifetimeID + topologyGeneration).
/// Originally defined in `PathSearchIndex.swift` (deleted at P4-7c c3) as
/// `WorkspaceSearchRootPathIndexIdentity`; relocated here verbatim (same name, same three fields,
/// same `Equatable`/`Hashable` conformance) because `WorkspaceSearchRootQueryHandle.identity`,
/// below, is its one surviving production consumer -- the Swift `WorkspaceSearchRootPathIndex` it
/// was originally named after no longer exists.
struct WorkspaceSearchRootPathIndexIdentity: Equatable, Hashable {
    let rootID: UUID
    let lifetimeID: UUID
    let topologyGeneration: UInt64
}

/// P4-7b §4.3/§4.5: one open Rust snapshot handle for one root, vended by
/// `WorkspaceFileContextStore.searchRootQueryHandles(rootScope:)`.
///
/// `identity` mirrors the pre-P4-7c Swift arm's root-generation bookkeeping (see
/// `WorkspaceSearchRootPathIndexIdentity`'s doc comment, above) -- this is deliberately not a new
/// identity shape.
///
/// ARC-driven close (§4.5 item 3): `CoreInventorySnapshot` itself already closes its Rust-side
/// handle from its own `deinit` (its doc comment: "`close()` is idempotent and the product-facing
/// lifecycle mechanism, `deinit` is the backstop only"). Retaining it here, inside a `Sendable`
/// value the caller holds for exactly as long as it needs the generation, is the entire retention
/// mechanism -- there is no separate close bookkeeping on this type or its holder.
struct WorkspaceSearchRootQueryHandle {
    let identity: WorkspaceSearchRootPathIndexIdentity
    let rootPath: String
    let rootName: String
    let snapshot: CoreInventorySnapshot
}

/// P4-7b §4.3/§4.5: the store-vended value the search service will consume at the b3 flip.
///
/// `scopeGeneration` is the Swift scope generation (§1.5 Check B, the staleness key) -- callers
/// must key `isStale`/`currentIndexedGeneration`/`pendingGeneration` off this field, never off a
/// Rust generation on any individual handle. The two counters are different counters (contract doc
/// §12.2: their agreement is unproven), and coupling to Rust's would inherit that gap silently.
///
/// Retention budget (§4.5): at most one *ready* set per scope plus at most one *in-flight* set
/// during a rebuild is the caller's responsibility to uphold (≤2 open handles per root,
/// attributable to search, against the scope-wide `cap = 8`) -- this type itself does not enforce
/// it.
struct WorkspaceSearchRootQueryHandles {
    let scopeGeneration: UInt64
    let perRoot: [WorkspaceSearchRootQueryHandle]

    func handle(rootID: UUID) -> WorkspaceSearchRootQueryHandle? {
        perRoot.first { $0.identity.rootID == rootID }
    }
}
