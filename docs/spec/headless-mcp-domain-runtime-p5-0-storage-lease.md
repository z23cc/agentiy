# Headless MCP domain runtime — P5-0 canonical workspace writer lease

Date: 2026-08-25
Status: P5-0b production admission, reconciliation, and drain integration implemented
Authority baseline: [`headless-mcp-domain-runtime-m2-context-authority.md`](headless-mcp-domain-runtime-m2-context-authority.md)
Governing decision: [`ADR-0006`](../architecture/adr-0006-release-and-stopgap-policies.md)

## Purpose and current boundary

Phase 5 cannot add a Rust workspace mutation path while app and standalone runtimes may independently
write the same canonical workspace storage. The current Swift `DomainWorkspaceContextAuthority` is the
only production workspace/context authority. It already owns operation IDs, workspace/context/catalog
revisions, CAS, journals, tombstones, crash recovery, external reconciliation, and event publication.
P5-0 adds the missing runtime-lifetime ownership layer without weakening any of those defenses.

P5-0a froze the language-neutral lease protocol and added the Swift kernel-lock primitive. P5-0b
constructs one process-wide lease in `MCPDomainRuntime`, forces durable reconciliation before writable
health, admits commands through epoch-bound permits, and drains all admitted permits before orderly
release. Every canonical workspace persistence writer and lazy migration validates the same permit at
both its async facade and blocking lock boundary. This closes the Swift single-writer prerequisite; it
does **not** itself add a Rust mutation or durable shadow path.

## Scope identity and artifacts

One lease scope is the physical canonical `workspaceStorageDirectory`. `profileIdentifier` and the
runtime's separate `storageDirectory` are excluded: two profiles or runtime-state roots that address
the same workspace storage must contend on one kernel lease.

Canonicalization is portable and deterministic: standardize the absolute input path, walk upward to
the nearest existing ancestor, resolve symlinks on that ancestor, then append the standardized
nonexistent tail components in order. This makes aliases agree even before the workspace or lease
directory exists. Lease artifacts live under that physical workspace root:

```text
<canonical-workspace-storage>/.agentry-domain-runtime/locks/
  workspace-authority-v1.lock
  workspace-authority-owner-v1.json
```

`storageScopeDigest` is lowercase SHA-256 over the exact UTF-8 domain, one NUL byte, and the
canonical absolute workspace-storage path:

```text
agentry-workspace-authority-lease-v1\0<canonical workspace-storage path>
```

Frozen compatibility vector:

```text
path:   /tmp/agentry/Workspaces
digest: f68efb392cd1119e04cd913c22f942246e478d73e9f1de580e00ad6dd8ab8572
```

The lock directory is mode `0700`; lock and metadata files are mode `0600`. A catalog entry whose
custom workspace document lies outside `workspaceStorageDirectory` is not silently covered by this
scope. Such a document remains readable through the routing overlay but is projected read-only and any
canonical mutation is rejected before persistence.

## Ownership protocol

`workspace-authority-v1.lock` is opened with `O_CREAT | O_RDWR | O_CLOEXEC` and held with a
nonblocking exclusive `flock`. The open descriptor is retained for the entire mutation-authority
lifetime. The kernel lock is the **only** ownership proof.

- First successful holder owns mutation rights.
- A live holder is never preempted using PID, mode, timestamp, or metadata.
- A crash releases ownership when the kernel closes the descriptor.
- Stale or corrupt metadata cannot block a free lock.
- Metadata tampering cannot transfer a live lock.
- App and standalone modes use the identical protocol; P5-0 does not give GUI mode unsafe priority.
- Contenders fail closed. GUI proxy/handoff policy is a later, separate topology decision.

There is no heartbeat or timestamp expiry. Runtime activation retries nonblocking acquisition during
external-reload polling; every newly acquired epoch completes a fresh durable reconciliation before the
first command permit is issued.

## Diagnostic owner metadata v1

`workspace-authority-owner-v1.json` is sorted-key JSON with ISO-8601 dates:

| Field | Type | Meaning |
|---|---|---|
| `version` | integer | Exact schema version `1` |
| `runtimeID` | UUID string | Runtime instance identity |
| `lifecycleGeneration` | unsigned integer | Runtime lifecycle generation |
| `processID` | signed integer | Diagnostic process ID only |
| `mode` | string | `app` or `standalone` |
| `profileIdentifier` | string | Exact profile identifier |
| `storageScopeDigest` | lowercase SHA-256 | Lease scope identity |
| `implementation` | string | `swift` in P5-0a; later `rust` |
| `leaseEpoch` | UUID string | Unique successful acquisition epoch |
| `acquiredAt` | ISO-8601 string | Diagnostic acquisition time |

The holder atomically replaces metadata only after acquiring the lock. On orderly release it removes
metadata only when the stored `leaseEpoch` still matches, then unlocks and closes the descriptor.
Failure to read or remove metadata never extends ownership.

## Verified current persistence writer/lock audit

`DomainPersistenceCoordinator.bootstrapBlocking` is read-only. Pending-save resolution constructs a
clean in-memory journal view but does not finalize it at bootstrap. The canonical workspace writers
are:

| Writer | Current per-operation serialization | Durable effects |
|---|---|---|
| `persistCreated` | lazy-migration `runtime-policy.lock`, then `workspace-catalog.lock` + workspace-ID lock | intent/clean journal, workspace document, revision, catalog, prior tombstone cleanup |
| `repairRecoveredCreate` | `workspace-catalog.lock` + workspace-ID lock | repairs a missing catalog entry |
| `persistUnchanged` | `workspace-catalog.lock` + workspace-ID lock | operation-bearing working journal |
| `persistWorking` | `workspace-catalog.lock` + workspace-ID lock | dirty working journal/context revisions |
| `persistSaved` | `workspace-catalog.lock` + workspace-ID lock | pending journal, workspace document, clean journal/revision |
| `persistExternalReload` | `workspace-catalog.lock` + workspace-ID lock | clean journal/revision after external change |
| `persistConflictRebase` | `workspace-catalog.lock` + workspace-ID lock | rebased dirty journal |
| `persistDeleted` | lazy-migration `runtime-policy.lock`, then `workspace-catalog.lock` + workspace-ID lock | catalog tombstone, sidecar, best-effort artifact cleanup |
| `ensureLazyMigration` | `runtime-policy.lock` | rollback copy/manifest, initial catalog, runtime policy |

These locks and CAS checks remain defense-in-depth. They are bounded operation locks, not a
runtime-lifetime owner. Every row above now requires one active epoch-valid permit before and inside its
blocking lock scope. Protected-mutation settings, direct settings, agent-session metadata, and
worktree-binding stores use separate domain locks and remain outside this workspace/context lease slice.

## P5-0a primitive and P5-0b access tests

`DomainWorkspaceAuthorityLease` owns the descriptor inside an actor and performs filesystem syscalls
on a utility queue. It supports one nonblocking acquisition attempt, retry after contention/failure,
idempotent held-state reads, and terminal orderly release. An acquisition generation invalidates any
suspended blocking result when release wins during actor reentrancy; an invalidated result closes its
descriptor before returning. P5-0b layers `DomainWorkspaceMutationAccess` over it and connects that access actor to production
composition.

`DomainWorkspaceAuthorityLeaseTests` proves:

- independent app/standalone instances contend on separate descriptors;
- release allows exactly the contender to acquire a fresh epoch;
- stale and corrupt metadata do not block a free kernel lock;
- metadata tampering cannot preempt a live holder;
- symlink aliases and nonexistent tails resolve to one physical scope;
- different profiles sharing one workspace root contend, while distinct workspace roots partition;
- the language-neutral scope digest matches a fixed compatibility vector;
- release during suspended acquisition cannot resurrect ownership or leak a descriptor;
- artifacts use private permissions;
- reconciliation precedes command-permit admission and failed reconciliation relinquishes ownership;
- contended access issues no permit and retries on a fresh epoch after handoff;
- orderly drain waits for an active command permit before releasing;
- a real external process killed with `SIGKILL` releases the kernel lease;
- missing descendants are in-scope while path-prefix collisions are rejected.

## P5-0b shipped integration and evidence

The production topology now satisfies the atomic gate:

1. `MCPDomainRuntime` owns one lease/access actor per process-wide runtime, never per window.
2. Startup bootstraps read state, acquires the lease, performs a fresh catalog/journal/external
   reconciliation, and only then projects writable health.
3. Each command obtains a short-lived opaque permit before deduplication or validation. Contended,
   acquiring, reconciling, draining, and released states reject without retaining the operation ID.
4. All eight canonical writers plus lazy migration validate scope digest, lease epoch, access identity,
   and active permit membership before entering blocking I/O and again inside durable lock scopes.
5. Reads remain available while contention projects catalog, workspace, context, and registration
   health as degraded read-only. Documents outside the leased physical root are readable but cannot
   reach a writer.
6. External polling retries acquisition. Every successful handoff uses a fresh epoch and reruns full
   durable reconciliation before command admission.
7. Shutdown blocks new permits before host drain, awaits every admitted permit, then removes matching
   diagnostics and releases the kernel descriptor.
8. Existing CAS, short operation locks, atomic writes, cancellation, tombstones, and recovery remain
   live defense-in-depth.
9. Focused tests cover app/standalone contention, no-recording retry across handoff, fresh-epoch
   reconciliation, active-permit drain, strict path scope, and a real external process killed with
   `SIGKILL` before successful reacquisition.

Compatibility limit: binaries older than P5-0b do not know this lease and therefore do not participate
in its mutual exclusion. Mixed-version simultaneous access remains unsupported; schema downgrade and
normal release/update sequencing must prevent an older process from writing beside a P5-0b holder.

The Phase-4 Swift single-writer prerequisite is complete. P5-1a's read-only Rust workspace
document/context/prompt/selection projection is now implemented through a typed UniFFI surface and
real-core Swift differential; it retains no bytes and does not participate in the lease or production
read path. P5-1b may arm that projection as a comparison-only observer. Production Rust mutation and
persistence still require their own continuous parity, soak, stateful snapshot, schema, and cutover
gates.
