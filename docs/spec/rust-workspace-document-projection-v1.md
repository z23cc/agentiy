# Rust workspace document projection v1

Date: 2026-08-25
Status: P5-4b lease-backed checkpoint arming and restart recovery
Predecessor: [`headless-mcp-domain-runtime-p5-0-storage-lease.md`](headless-mcp-domain-runtime-p5-0-storage-lease.md)

## Purpose and boundary

P5-0b closes the process-wide Swift single-writer prerequisite. P5-1a adds the first Rust
Workspace/Context/Selection domain surface: a deterministic, complete-buffer projection of one
canonical `workspace.json` document. The projection is read-only and side-effect free. It does not
acquire the storage lease, read paths, create a catalog, publish events, mutate selection/prompt,
write journals, or replace `DomainWorkspaceContextAuthority`.

Swift remains the production authority in this slice. Rust output is consumed only by focused
parity tests and later shadow wiring. Production cutover remains gated on armed parity, stateful
snapshot identity, diagnostics, persistence/recovery, lease ownership, and migration economics.

## Export

`CoreRuntime.workspaceDocumentProjectionV1` accepts:

- the exact initialized Rust runtime identity;
- `contractVersion == 1`;
- one complete `workspace.json` byte buffer no larger than 32 MiB (33,554,432 bytes).

The Swift bridge rejects a larger buffer before detached transport dispatch; Rust repeats the same
bound before JSON parsing for direct FFI callers. It returns one typed projection or
`CoreError.invalidArgument`. The export is synchronous and panic-contained like the existing
text-decode and compact compute surfaces. Input bytes are never retained after return. Once dispatched,
cancellation drops the bounded late result rather than attempting to interrupt `serde_json` mid-parse.

## Projection shape

The result preserves document order and contains:

- `workspaceID`: required UUID string;
- `schemaVersion`: JSON integer, default `1`, maximum supported `1`;
- `name`: string, default `"Untitled Workspace"`;
- `repoPaths`: an all-string JSON array, otherwise empty;
- `activeContextID`: valid UUID string or absent;
- `contexts`: `composeTabs` order, with each record containing:
  - required unique `contextID` UUID string;
  - `name`, default `"Untitled"`;
  - valid optional `activeAgentSessionID` and `activeChatSessionID` UUID strings;
  - `prompt`, default empty string;
  - `selection`, taken from an all-string `selectedPaths` array, then the legacy all-string
    `selection` alias, otherwise empty.

UUID acceptance is case-insensitive canonical `8-4-4-4-12` hexadecimal form, matching Swift
`UUID(uuidString:)`. Returned UUID strings are lowercase canonical form so the wire has one stable
representation; Swift converts them back to `UUID` before comparing domain identity.

## Rejection and compatibility rules

The whole projection rejects:

- a non-object top level;
- a missing/non-string/invalid workspace ID;
- an input larger than 32 MiB;
- a schema version greater than `1` after Swift-compatible `NSNumber.intValue` coercion; JSON
  booleans project as `0`/`1`, while missing or other nonnumeric values use the default `1`;
- any composed context that is not an object, lacks a valid ID, or repeats an earlier context ID.

A missing or non-array `composeTabs` value means no contexts. Unknown fields are ignored. Invalid
optional UUIDs become absent. Mixed-type path/selection arrays do not partially project: they use the
specified empty/fallback behavior. Stashed tabs remain outside this projection because they do not
participate in the canonical headless prompt/selection read shape.

The ordering and fallback rules intentionally mirror `DomainWorkspaceDocument.decode` plus
`DirectHeadlessDomainContext.snapshot`. Differential tests compare semantic UUIDs, context order,
prompt, and selection rather than JSON serialization bytes.

## P5-1a done-when

- Rust unit tests cover the success/default/alias/order, boolean/numeric schema, size-bound, and
  rejection matrix.
- The real UniFFI export validates runtime identity and contract version.
- Swift bridge mapping rejects malformed Rust UUID output.
- A real-core differential compares Rust projection with the existing Swift decoder/read projection.
- Code generation is deterministic and all focused Rust/Swift gates pass.

## P5-1b amendment — always-armed comparison observer

P5-1b arms the same real Rust projector behind production Workspace/Context read visibility while
leaving Swift as the sole authority. `MCPDomainRuntime` owns one observer for its lifetime and
injects only a synchronous, nonthrowing ingress sink into `DomainWorkspaceContextAuthority`.
Authority reads never await Rust, encode JSON, construct the expected projection, record metrics,
or create one task per observation. Mismatch, bridge failure, queue pressure, and observer shutdown
must not change a snapshot, command outcome, revision, event, authority health, or runtime lifecycle.

The observer sees canonical documents installed by bootstrap and lease reconciliation, documents
returned by catalog/workspace/canonical/read-registration seams, documents carried by command
outcomes, and canonical records after a changed or recovery-pending external reload. Conflict
candidates that are not yet production-visible are excluded. Duplicate hooks are permitted because
work is deduplicated by the exact `(workspaceID, contentDigest)` pair.

### Bounded ingress and lifetime

The ingress is locked and synchronous before any asynchronous work exists. One serial worker owns
encoding-free Swift projection construction, the Rust call, semantic comparison, and metrics. Its
production bounds are:

- one active projection;
- at most 32 pending documents, with at most one pending document per workspace;
- at most 64 MiB of retained active-plus-pending input bytes;
- the existing 32 MiB per-document Rust input limit;
- at most 256 completed digest states.

A newer document replaces the pending item for its workspace. Oldest pending items are evicted until
both queue bounds hold; an item still unable to fit is dropped and remains eligible on a later
observation. The active item is never evicted and remains byte-charged until completion. The 64 MiB
limit is a retained-input bound, not a whole-process peak-memory guarantee. Oversized documents are
represented only by bounded metadata and are rejected without retaining their bytes or calling Rust.

Matched, mismatched, and failed results deduplicate the same digest. A mismatch or failure
quarantines only that exact workspace/digest; any new digest is eligible immediately, and bounded
LRU eviction also makes an old digest eligible again. Mismatch diagnostics contain only closed field
names. Metrics may contain runtime/workspace IDs, source/result categories, counts, byte counts, and
closed error reasons; they must never include document names, prompts, paths, differing values,
raw bridge diagnostics, or document bytes.

Runtime shutdown atomically closes ingress and clears pending work before cancelling and awaiting the
worker. A late Rust result is discarded without committing digest state or a terminal comparison
metric. Retained store facades may continue calling the closed sink safely, but cannot refill it.
The observer cannot restart after shutdown.

### P5-1b done-when

- Deterministic tests pin active/pending deduplication, latest-wins replacement, count/byte eviction,
  exact-digest quarantine, new-digest recovery, bounded completed state, and shutdown cleanup.
- Field-level comparison covers workspace scalars, ordered roots/contexts, context identity/session
  fields, prompt, and selection without recording values.
- A gated projector proves authority reads and command completion do not wait for comparison.
- A real-core runtime test observes a production-wired document through the existing UniFFI export.
- Focused tests, formatting, lint, guardrails, and the affected Swift product build pass.

P5-1b does not grant Rust workspace, context, selection, catalog, persistence, or mutation authority.
A later slice must evaluate the accumulated parity evidence and explicitly cross those cutover gates.

## P5-2a amendment — stateful generation-CAS projection catalog

P5-2a adds the first stateful Rust workspace substrate without changing production authority. One
`WorkspaceProjectionCatalog` owns an in-memory table of immutable semantic projections. A catalog
instance is deliberately scope-local: the later FFI registry must key it by the explicit domain
runtime scope identity because one process-wide Rust core can serve multiple Swift domain profiles.
No process-global workspace table is permitted.

The catalog supports three exact-generation CAS commands:

- atomically replace the full document set;
- insert or replace one canonical document;
- remove one canonical workspace identity.

Projection, duplicate detection, and capacity validation complete before the commit lock. The lock
then verifies `expectedGeneration == currentGeneration`; any projection error, duplicate workspace
ID, stale generation, capacity failure, or generation overflow leaves the current snapshot and
generation unchanged. Exact byte-identical document sets are no-ops even when input order differs.
Workspace IDs are stored in canonical UUID order, while each document retains its canonical context,
prompt, root, and selection order.

Every accepted change publishes a new immutable `Arc` snapshot containing its generation, bounded
retained-byte accounting, and ordered entries. Readers can retain an older snapshot lease across a
later mutation and never observe mixed generations. The active catalog is fail-closed at 256
workspaces and 64 MiB of conservative retained projection bytes by default; it never evicts an
authoritative entry to satisfy capacity. Snapshot leases can intentionally retain retired generations
until their readers close, so the later FFI handle registry must separately bound open handles.

P5-2a performs no filesystem I/O, journaling, recovery, event publication, lease acquisition, or
Swift cutover.

### P5-2a done-when

- Full replacement is atomic and canonical-order deterministic.
- Exact-content replacement is a generation-preserving no-op.
- Stale CAS, duplicate identity, and count/byte capacity failures publish nothing.
- Upsert and removal advance exactly one generation when they change state.
- Retained old snapshot leases stay immutable across later upsert and removal.
- Focused Rust runtime tests and formatting pass before the FFI slice begins.

## P5-2b/c amendment — scope-keyed FFI snapshots and armed stateful parity

P5-2b exposes the catalog through a generated UniFFI control plane and a bridge-owned ARC facade.
The surface opens/closes an explicit UUID scope, applies full replacement/upsert/removal under exact
CAS, opens bounded immutable snapshot handles, pages canonical ordered projections, closes handles
idempotently, and reports generation/open-handle diagnostics. Every open receives a process-lifetime
monotonic scope incarnation token; every later command, page, close, and diagnostic must present the
exact `(scopeID, incarnation)` pair. Reopening the same UUID therefore cannot let a retired Swift
facade close, mutate, page, or consume a handle from the new scope even when numeric handle IDs are
reused. New typed errors preserve unknown, closed, duplicate-open, generation-conflict, handle, and
capacity outcomes through the Swift bridge. The App layer never imports the raw binding or sees a
numeric handle.

FFI configuration is capped at the compiled 256-workspace, 64-MiB catalog, and 64-handle ceilings;
callers may only request tighter limits. Full replacement rejects excessive document count and raw
input bytes before projecting the vector. Snapshot leases are separately charged against the
scope's retained-byte ceiling as well as the handle-count ceiling, and close releases both charges.
Runtime shutdown permanently closes the projection registry under its registration lock before
draining existing scopes, so no concurrent open can survive the drain.

P5-2c replaces the default production comparison observer's stateless projection call with one
`DomainWorkspaceStatefulRustProjector` per domain runtime. Its scope ID is exactly
`DomainRuntimeIdentity.runtimeID`, so GUI/headless profiles sharing the process-wide Rust core remain
isolated. The observer's existing single worker is the only writer: it upserts the canonical document
at its exact last generation, opens that resulting immutable snapshot, pages until it resolves the
same workspace identity, and only then performs semantic parity comparison. The projector keeps a
128-workspace LRU below Rust's compiled 256-workspace ceiling; it removes the least-recently-used
identity under exact generation CAS before admitting a new one, and capacity failures trigger bounded
additional eviction rather than permanently poisoning comparison for later workspace churn. Shutdown
first drains the worker, clears the LRU/generation state, and then closes the Rust scope and all
retained handles. Explicit projector injection used by deterministic tests is unchanged.

This is still comparison-only authority. Swift continues to own catalog reads, command results,
selection/prompt mutation, persistence, recovery, and the storage writer lease. The next cutover gate
is a Rust-owned revision/event protocol plus durable journal/recovery under the existing Swift lease;
no read or mutation caller may switch merely because the stateful parity scope is armed.

### P5-2b/c done-when

- Real FFI tests prove CAS conflict, retired-generation paging, canonical order, diagnostics,
  compiled configuration caps, incarnation-safe reopen, and idempotent close.
- The Swift ARC facade validates the caller's previous generation, exact snapshot generation,
  offset/limit/cardinality/progress flags, and closes snapshots/scopes explicitly with deinit only as
  a backstop. Locally closed facades reject new operations before transport dispatch.
- The production observer uses one runtime-ID-partitioned stateful scope and still cannot delay or
  change any Swift authority outcome.
- Generated bindings/identity are deterministic; focused bridge/domain tests, product build, lint,
  and guardrails pass.

## P5-3 amendment — atomic revision/publication shadow state

P5-3 extends the same runtime-partitioned Rust scope with the first catalog revision and event
protocol. `DomainWorkspaceContextAuthority.publish` remains Swift's sole visible ordering point: it
constructs the existing consumer event, yields it unchanged, and synchronously offers that event plus
the complete canonical document set to a bounded nonthrowing observer ingress. No command, read,
subscriber, persistence write, or lease decision awaits Rust.

The observer's publication worker sends one atomic Rust command containing the complete documents,
the caller's last projection generation and publication cursor, and the next closed event facts:
kind, optional workspace/context/operation UUIDs, and optional working/saved/dirty revisions. Under
one scope gate Rust validates all UUIDs, exact document-generation CAS, exact catalog/sequence cursor,
sequence continuity, and non-regressing catalog revision before replacing the immutable projection
and appending the event. A rejected command changes neither documents nor the publication cursor.
The initial observation and any bounded-ingress gap are explicit full rebases; normal delivery may
never infer or skip a missing sequence.

The in-scope event log retains at most 256 fixed-shape events and reports its floor, count, catalog
revision, and publication sequence through typed receipts and diagnostics. The bridge verifies the
entire receipt, including projection-generation movement/no-op, workspace cardinality, exact event
cursor, rebase disposition, and log floor/count arithmetic. Diagnostic and metric dimensions remain
closed facts and counts; command origin, diagnostic text, document values, prompts, selection paths,
and raw bytes do not enter the Rust event log.

Publication ingress retains at most 16 complete catalog observations. Document and publication
ingresses share one 64-MiB active-plus-pending byte budget rather than independently claiming that
ceiling; every publication document also obeys the 32-MiB per-document limit and an oversized
catalog is retained as metadata-only failure. Oldest pending observations are dropped under pressure;
the next surviving sequence necessarily performs an explicit complete-state rebase. Both workers
share one async projector permit, so actor reentrancy cannot race their exact generation CAS calls.
Shutdown closes and clears both ingresses, cancels and awaits both workers, then closes the Rust
scope.

P5-3 is still shadow-only. Swift continues to own catalog/revision reads, production event delivery,
selection/prompt mutations, durable journals, recovery, and the storage writer lease. A later slice
must add durable Rust persistence/recovery and prove restart equivalence before any authority flip.

### P5-3 done-when

- Rust tests pin atomic projection/cursor commit, gap rejection without mutation, explicit rebase,
  catalog-revision monotonicity, and the 256-event rolling floor.
- Real FFI/bridge tests pin cursor-only no-op generations, typed diagnostics, and rejected-gap state
  preservation.
- Observer tests pin exact publication order, bounded catalog ingress, drop accounting, explicit
  rebase accounting, and production bootstrap delivery through the real Rust core.
- Focused Rust, bridge, and domain tests plus generated-binding, product-build, lint, and guardrail
  gates pass.

## P5-4a amendment — bounded restart checkpoint and atomic recovery core

P5-4a freezes the Rust-owned restart-checkpoint schema before any filesystem or FFI arming. A scope
can export one bounded fixed-field JSON checkpoint containing its exact stable scope UUID, projection
generation, catalog revision, publication cursor/log floor, complete semantic projections, raw
content digests, a domain-separated digest-to-projection checksum per entry, and the bounded
fixed-shape event tail. The checkpoint deliberately does not contain
canonical workspace document bytes, lease metadata, paths, commands, or operation diagnostics; it is
a restart-equivalence artifact for the Rust shadow state, not yet a replacement for Swift's canonical
workspace documents and working journals.

Recovery is permitted only into a pristine open scope: generation zero, an empty catalog, no
publication events, and no snapshot handles. The complete checkpoint is decoded and validated before
the scope gate is acquired. Validation rejects an input above 128 MiB, an unknown/future schema,
a mismatched or noncanonical scope UUID, duplicate/noncanonical workspace or context identities,
invalid lowercase SHA-256 digests, count/retained-byte overflow, impossible generation-zero content,
noncontiguous event sequences, inconsistent log floor/tail, regressing event catalog revisions,
digest/projection checksum mismatch, and a final event cursor that does not exactly match the
checkpoint cursor. Entry and event arrays are rejected by streaming visitors as soon as their
compiled count/retained-byte limits are crossed; export streams through a 128-MiB capped writer rather
than allocating an unbounded escaped JSON result. A failed recovery changes no
catalog generation, projection, publication cursor, event, or handle state.

A successful recovery installs the checkpoint's original generation without synthesizing a mutation,
restores canonical workspace-ID ordering and the exact rolling event tail, and preserves each entry's
raw-document digest. Republishing the same original documents therefore remains a projection no-op
while advancing only the publication cursor. Export is deterministic for a given scope state, so a
checkpoint exported after recovery is byte-identical to its source.

P5-4a itself performs no filesystem I/O and exposes no FFI. Swift remains the persistence/recovery
and lease authority until the P5-4b arming below.

### P5-4a done-when

- Runtime tests prove deterministic export, byte-identical re-export, original-generation recovery,
  same-document cursor-only continuation, and immutable retained snapshots after later publication.
- Corrupt/future/cross-scope/state-conflicting checkpoints fail atomically.
- Checkpoint count, retained-byte, digest, identity, generation, and event-log invariants are bounded
  and validated independently of serde acceptance.
- Rust formatting and the full runtime package tests pass; generated binding identity remains current.

## P5-4b amendment — lease-backed checkpoint arming and restart recovery

P5-4b exports the P5-4a codec through the generated UniFFI control plane and arms it in the production
comparison observer. The scope identifier is no longer the ephemeral domain runtime UUID: it is a
stable UUID derived from the canonical physical workspace-storage lease digest. Only the runtime that
holds that physical workspace authority lease may open, recover, publish, or persist the stable Rust
scope. A competing read-only runtime keeps its bounded observer ingress inactive and cannot collide
with or overwrite the writer's checkpoint.

Swift continues to own filesystem syscalls and the kernel lease in this slice. The Rust-produced
checkpoint bytes live at
`<workspaceStorage>/.agentry-domain-runtime/workspace-projection/checkpoint-v1.json`. Reads use one
file descriptor from size validation through incremental capped I/O and stop at the Rust 128-MiB
checkpoint ceiling even if the artifact grows or is replaced while being read. Every write validates
its current opaque mutation permit before dispatch and again while holding a dedicated checkpoint file lock, then atomically
replaces the artifact. A publication is compared first; only its exact in-scope post-publication
checkpoint may be written. Checkpoint I/O or recovery failure is shadow-only, emits closed metrics,
and cannot change Swift authority health, command outcome, revision, event delivery, or lifecycle.

Domain publication sequence is process-local and restarts from zero. Recovery therefore has two
explicit modes. Exact recovery restores the original event cursor and remains available for same-epoch
bridge contracts. Production process restart fully validates the persisted tail and projection
checksums, restores the original projection generation/digests, then deliberately begins a new
publication epoch with catalog revision and sequence reset to zero, the empty-log floor reset to one,
and the event tail emptied. The
first current-process bootstrap publication is an explicit sequence-1 rebase. It must remain a
projection-generation no-op when Swift's canonical documents match the checkpoint; cross-process
cursor continuity is never invented.

The observer opens bounded ingress before Swift bootstrap so it cannot miss bootstrap or lease
reconciliation facts, but its document/publication workers remain paused. After Swift acquires the
workspace mutation lease, a stable epoch token is validated before checkpoint I/O, the pristine Rust
scope is explicitly opened under that token even when no checkpoint exists, and every worker operation
revalidates the same lease epoch. A dedicated bounded recovery loop retries lease takeover even when
external reload polling is disabled. Shutdown cancels and awaits startup/reload/takeover activation,
stops both workers, terminally closes the stable Rust scope, and only then releases the Swift lease.

### P5-4b done-when

- Runtime and real bridge tests cover exact restore plus new-publication-epoch restore, complete
  receipt validation, corrupt checkpoint atomicity, and deterministic export.
- Persistence tests prove the 128-MiB single-descriptor read bound, pre-dispatch and lock-held permit
  validation, and atomic checkpoint replacement below the canonical workspace-storage root.
- A real two-runtime restart test persists a nonempty projection, closes the first scope, restores the
  original generation/digest under a new runtime identity, and accepts the current bootstrap as a
  sequence-1 projection no-op.
- A competing runtime without the physical workspace lease cannot activate or persist the Rust scope;
  after the holder exits it takes over without external reload polling, restores the stable scope, and
  resumes exact checkpoint persistence.
- Focused runtime, FFI, bridge, and domain tests plus code generation, product build, formatting,
  lint, guardrails, and diff checks pass.
