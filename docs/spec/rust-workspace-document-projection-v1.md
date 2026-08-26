# Rust workspace document projection v1

Date: 2026-08-25
Status: P5-4e complete revision/health row authority
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

## P5-4c amendment — generation-leased headless read authority

P5-4c makes the first production document read cut. Direct-headless canonical workspace tools now
source workspace root paths and the bound context's prompt/selection from an immutable Rust snapshot,
not by reparsing the Swift workspace bytes. `DomainWorkspaceStatefulRustProjector.readWorkspace`
opens the exact currently committed generation, pages it under the projector's single-operation
permit, rejects missing/invalid progress, and always closes the snapshot handle. The observer validates
the active physical-storage lease epoch immediately before and after that suspending read.

Swift still supplies the revision/health/file-URL envelope needed by mutation CAS and filesystem
routing. It is used as a fence, not as the returned canonical prompt/selection value: each read derives
the expected complete projection, accepts Rust only on exact equality, then re-reads Swift and requires
the source document digest to remain unchanged. Missing or stale rows reconcile directly under the
same lease, bypassing completed-observation deduplication after LRU eviction or a full publication.
The existing tool watchdog bounds operation-permit wait, Rust paging, cancellation cleanup, and all
10-ms retries under one one-second request deadline. Stateful production runtimes fail closed when the
fence cannot converge; injected comparison projectors have no read-authority capability and also fail
closed rather than silently reactivating Swift values.

This does not yet move workspace/context revision state, health, mutation commands, workspace JSON
filesystem I/O, or the storage lease into Rust. Those remain later Phase 5 cuts; the narrower
roots/prompt/selection boundary is now production Rust read authority rather than armed shadow state.

### P5-4c done-when

- Direct-headless roots, prompt, and selection are constructed from Rust projection values after an
  exact complete-projection comparison and Swift digest revalidation.
- Missing or stale projection data is reconciled directly through the stateful projector; stale lease,
  stopped scope, injected comparison-only projector, persistent mismatch, or timeout fails closed.
- Stateful projector tests prove repeated immutable reads, read-driven LRU refresh, identical-digest
  recovery after eviction, missing-workspace rejection, and handle cleanup; focused direct-headless
  selection/prompt tests preserve existing observable behavior.

## P5-4d amendment — atomic publication-cursor read fence

P5-4d closes the remaining scope-level race in the P5-4c read plane. Opening a Rust projection
snapshot now captures its immutable document generation and the current catalog revision,
publication sequence, event-log floor, and event-log count while holding the same scope-state lock.
The generated FFI handle and Swift ARC lease retain those values for the handle's lifetime; a later
cursor-only publication cannot relabel an already-open document generation.

`DomainContextStore` exposes one actor-isolated Swift read fence containing the workspace
revision/health envelope plus its catalog revision and publication sequence. Direct-headless reads
accept a Rust projection only when its cursor equals that fence, then re-read the complete Swift fence
and require cursor and document digest stability. A lagging publication worker is allowed to converge
within the existing one-second total watchdog; dropped or permanently divergent publication state
fails closed.

A missing Rust row still returns its immutable generation and cursor. Reconciliation therefore cannot
confuse an LRU eviction with a newer complete publication that removed the workspace: it proceeds only
when the original generation, catalog revision, and publication sequence remain exact under one
projector operation permit. The upsert is additionally wrapped in a short-lived workspace
reconciliation permit, so mutation-access drain waits for the operation and a retired storage owner
cannot commit after lease handoff. Permit validation runs immediately before every Rust mutation and
again before releasing the projector permit. Reconciliation can repair missing/stale document content,
but cannot manufacture or advance a publication cursor.

This slice deliberately does **not** claim per-workspace or per-context revision/health authority.
Rust's bounded event tail contains only the revision payload of individual events and cannot reconstruct
the complete current envelope for every retained workspace. Moving that envelope requires a later
schema/publication change that sends and persists the complete revision/health table; Swift remains
its authority until then.

### P5-4d done-when

- Runtime and real-bridge tests prove a snapshot handle retains the cursor captured at open while a
  later cursor-only or document-changing publication advances only newly opened handles.
- Stateful projector reads return generation plus the exact Rust catalog/event cursor.
- Direct-headless production reads require equal Rust/Swift cursors and stable Swift cursor/digest
  fences without adding an unbounded wait or Swift value fallback; stale-generation repair and
  post-removal resurrection are rejected under a drain-aware reconciliation permit.
- Focused Rust, FFI, bridge, domain-runtime, and direct-headless tests plus generated-binding, format,
  lint, guardrail, and diff checks pass.

## P5-4e amendment — complete revision/health row authority

P5-4e moves the current per-workspace and per-context revision/health envelope into the same immutable
Rust catalog row as the semantic document projection. A complete Swift publication supplies every
workspace snapshot, including workspace revisions/health and one context envelope for every projected
context in exact document order. Rust validates identity/order parity, closed health-kind/reason
invariants, and revision monotonicity before atomically installing the complete catalog and publication
cursor. Snapshot paging returns the sidecar from the captured generation; readers never infer current
state from the bounded event tail.

Document-only projection remains available for comparison and parser tests, but such an upsert cannot
claim authority for revisions or health: changing a row through that path clears its authority sidecar.
A direct-headless read accepts only a complete sidecar whose row was read under the same Rust cursor as
the Swift fence. Missing/stale rows are repaired with the complete Swift workspace snapshot through an
exact generation/catalog-revision/publication-sequence CAS while holding the drain-aware reconciliation
permit; a newer removal, publication, or lease epoch rejects the repair.

The sidecar is included in retained-heap accounting and in the per-entry checkpoint checksum. The V1
checkpoint JSON remains backward-readable: older entries omit the optional sidecar and retain their
existing checksum; new entries serialize and authenticate it. Recovery of an older or document-only
row therefore yields an explicitly unavailable envelope and must reconcile before serving production
revision/health reads. Health reasons are data, not event diagnostics: writable/removed carry no
reason, while external-conflict/degraded-read-only require a nonempty bounded reason.

Swift still owns workspace document file URLs, filesystem I/O, mutation command admission, persistence
journals, and the physical storage lease. Direct-headless constructs its returned workspace/context
revision and health values from Rust after reusing only Swift-owned document/topology bytes and after a
final cursor/digest fence. This slice does not yet move mutation execution or durable workspace JSON
persistence into Rust.

### P5-4e done-when

- Runtime tests prove complete-envelope publication, immutable old-generation reads, document-only
  invalidation, exact-cursor repair, checkpoint round-trip, and corrupt/misaligned envelope rejection.
- Generated FFI and bridge tests carry the complete optional sidecar with closed validation and no
  independent event-tail reconstruction.
- Direct-headless tests prove workspace/context revisions and health are sourced from Rust while file
  URLs and document bytes remain Swift-owned and final-fenced.
- Focused runtime, FFI, bridge, observer, lease, and direct-headless tests plus codegen, product build,
  format, lint, guardrails, and diff checks pass.

## P5-5a-a amendment — bounded working-journal compatibility gate

The persistence cut begins at the complete artifact boundary, not one command at a time. Every
production mutation path that creates, replaces, saves, reloads, repairs, or resolves a workspace can
touch the same V1 working journal. Allowing Swift and Rust to author different transitions would create
two state machines over one file, so no production writer flips until Rust covers the complete
transition inventory and the replacement can be atomic.

P5-5a-a adds a stateless Rust validator/canonicalizer for the existing `DomainWorkingJournal` V1 wire
shape. It admits at most 128 MiB, validates workspace identity, file URL, revision invariants, SHA-256
digests, Foundation UUID-keyed dictionary shapes, the 256-operation ledger ceiling, pending-save
identity/digest syntax, timestamps, and the dirty/working-bytes envelope. It then emits bounded,
deterministic JSON plus its digest. Embedded workspace-document decode and pending-save recovery policy
remain at the existing Swift layer so corrupt working bytes still produce the established per-workspace
read-only degradation and crash markers need not appear in the bounded operation ledger.

The typed FFI, Bridge, and DomainRuntime adapter preserve the existing V1 artifact. Real-Core tests
encode the fixture with Foundation `JSONEncoder`, validate it in Rust, and decode Rust's canonical bytes
with Foundation `JSONDecoder`; invalid input and receipt identity mismatch fail closed. The physical
file, storage lease, filesystem lock, atomic replacement, workspace JSON, catalog, saved-revision
record, deletion tombstone, command admission, and event publication remain Swift-owned in this
pre-cut slice. Production `DomainPersistenceCoordinator` does not call the new adapter yet, so there is
no dual-write or behavior change.

The next atomic slice must replace all production Swift journal decode/encode entry points together.
Its commit algorithm must prepare against exact current bytes, revalidate the mutation permit and
raw-byte digest under the existing file lock, atomically write only Rust-produced bytes, and perform no
fallible Rust call after the saved document becomes authoritative. Save ordering and `pendingSave`
crash recovery remain unchanged; Rust transition-policy ownership is a later boundary.

### P5-5a-a done-when

- Runtime tests cover deterministic Foundation-compatible V1 validation plus future schema, invalid
  context/revision/document, pending-save, operation-ledger, and size rejection.
- Real FFI and Swift Bridge tests prove generated binding ownership, exact workspace identity, bounded
  pre-dispatch rejection, and Foundation encode/Rust canonicalize/Foundation decode parity.
- The DomainRuntime adapter verifies the returned digest and expected workspace identity without a
  Swift semantic fallback.
- Source audit confirms the production writer is still singular and Swift-owned until every V1 journal
  transition can flip atomically in P5-5a-b.

## P5-5a-b amendment — production Rust journal codec authority

P5-5a-b makes Rust the mandatory production codec and invariant gate for every V1 working-journal read,
proposal, repair, and replacement. Swift still constructs semantic transitions and owns the workspace
storage lease, mutation permit, file locks, workspace/catalog/revision/tombstone ordering, and physical
I/O. This is one artifact-boundary authority flip; it is not a second writer and does not claim Rust
transition-policy or filesystem authority.

Before entering `DomainBlockingIO`, the coordinator captures a short-lived prepared validator bound to
one exact live Rust runtime identity. The immutable capability performs synchronous FFI validation while
the existing catalog/workspace locks are held, so no actor hop or suspension is introduced inside a
filesystem transaction. Runtime stop, poison, or identity replacement fails before the corresponding
journal write; already prepared immutable bytes remain valid if the runtime subsequently closes.

All physical journal reads use one descriptor and an incremental 128 MiB ceiling. Existing bytes are
interpreted only from Rust-returned canonical bytes. Swift proposals are encoded only as validator input,
then compared field-for-field with the Rust-decoded receipt; only Rust canonical bytes may reach the
single journal replacement helper. Immediately before replacement, that helper rereads the exact raw
artifact under the workspace lock and compares presence plus raw-byte digest. A mismatch writes nothing
and reports the current Rust-decoded revision without automatic retry.

Create and save prepare both pending and committed candidates before their first durable journal write.
Their ordering remains unchanged: create is pending journal, document, committed journal, saved-revision,
then catalog; save is pending journal, document authority point, then best-effort committed journal and
saved-revision. Post-document finalization failure still returns the clean commit receipt and leaves the
pending artifact for restart recovery. Bootstrap/reload do not rewrite merely noncanonical V1 bytes, and
corrupt working-document bytes retain the existing saved-document read-only degradation behavior.
Cancellation is latched before create's first durable journal replacement; after the pending marker is
written, its remaining journal/document/catalog transaction is non-cancellable so the caller cannot
observe cancellation with an unpublished orphan. Rust runtime/identity loss aborts bootstrap globally
instead of masquerading as a corrupt workspace, while corrupt/future artifacts remain explicitly
per-workspace unavailable. Pending-save recovery distinguishes a legitimate digest miss from a thrown
Rust validation failure and never silently reactivates the stale pending overlay.

### P5-5a-b done-when

- `DomainPersistenceCoordinator` prepares a nonoptional validator for bootstrap, reload/refresh,
  create/repair/delete, and every working/save/reload/rebase transition.
- Production source contains exactly one journal-path write, fed only by Rust canonical bytes; there is
  no raw Swift `DomainWorkingJournal` decoder or unbounded `Data(contentsOf:)` journal read.
- Existing authority tests retain create/save/delete, external reload/rebase, pending-save restart,
  corrupt working-document, read overlay, cancellation, and lease-handoff behavior.
- Focused Rust, FFI, Bridge, DomainRuntime, source-guard, formatting, lint, generated-binding, guardrail,
  and product-build checks pass.

## P5-5b amendment — Rust working-journal transition authority

P5-5b moves the complete V1 working-journal state machine behind the same prepared Rust capability as
the codec. Swift sends a closed tagged command plus the exact current canonical artifact and optional
workspace document bytes. Rust validates the current artifact, applies one of eight transitions
(`seed`, `recoverPending`, `create`, `unchanged`, `working`, `save`, `externalReload`, or
`conflictRebase`), enforces revision and pending-save policy, trims the operation ledger to the existing
seven-day/256-entry limits, and returns canonical primary plus optional committed candidates. Create and
save are planned in one call, before any durable write, so no fallible Rust work occurs after the
workspace document becomes authoritative.

Production `DomainPersistenceCoordinator` contains no `DomainWorkingJournal` constructor and no Swift
operation-retention implementation. It verifies the typed Rust receipts and continues to own the
physical transaction: workspace storage lease and epoch permit, catalog/workspace file locks, exact
raw-byte digest CAS, atomic journal replacement, workspace JSON, saved-revision sidecar, deletion
sidecar, catalog publication, and crash-ordering semantics. A stale expected revision, malformed command,
invalid Rust receipt, or stopped prepared runtime fails closed without a Swift transition fallback.
Conflict-rebase preserves the established invalid-document projection for an invalid revision shape;
all other internal transition-contract violations remain persistence failures.

This is still one Swift filesystem writer. Rust does not open workspace-storage paths, hold the kernel
lease, or independently persist a journal. The next persistence cut may move a larger durable transaction
or catalog policy boundary, but it must not create dual writers or weaken the current byte-CAS and
post-document recovery guarantees.

### P5-5b done-when

- Rust unit tests exercise all eight transition kinds, primary/committed planning, document requirements,
  exact expected-revision fences, pending recovery, external reload, and conflict rebase.
- Real FFI, Bridge, and DomainRuntime tests prove Foundation command encoding reaches Rust and returns
  canonical candidates that decode to the established Swift model.
- Existing persistence-authority regressions preserve create/save/delete, deduplication, pending restart,
  reload/rebase, cancellation, lease handoff, and crash ordering with no observable behavior change.
- A production source guard proves one journal write point, eight Rust transition call sites, zero Swift
  journal constructors, and zero Swift operation trimming; focused build/style/guardrail checks pass.

## P5-5c amendment — Rust durable metadata policy authority

P5-5c moves the remaining per-workspace saved-revision record and deletion-tombstone construction policy
behind the prepared Rust persistence capability. Rust validates the exact V1 schema, identities,
revision/digest/timestamp fields, recorded operation, and size limits, then returns canonical bytes plus a
typed digest-bound receipt. Production Swift no longer constructs or semantically decodes either record.
A missing, stale, future, oversized, or malformed optional saved-revision sidecar retains the established
revision-zero recovery behavior, but that verdict now comes from Rust. Swift reads the sidecar through a
single descriptor with the shared 128 MiB cap; an oversized artifact performs a bounded exact-runtime
availability probe before recovering, and an unavailable prepared Rust runtime fails closed rather than
reactivating a Swift decoder.

Create, save, and external reload plan the saved-revision artifact before the first durable transaction
write. Delete likewise plans its initial tombstone before publishing the catalog deletion authority point.
After that authority point, filesystem cleanup remains best-effort: Rust may re-plan the tombstone with the
bounded cleanup-warning diagnostic, but failure to plan or rewrite the recoverable sidecar cannot turn an
already-authoritative delete into a failed command. The returned deletion receipt reports every observed
cleanup warning even when the optional diagnostic sidecar cannot be rewritten.

Swift remains the only filesystem writer and retains the workspace storage lease/epoch permit, locks,
atomic file replacement, artifact ordering, catalog encoding, and create/delete catalog authority point.
P5-5c is not the catalog-state-machine flip: catalog entry/deletion reconciliation and crash-policy
ownership are deliberately reserved for P5-5d so there is no mixed authority over one publication point.

### P5-5c done-when

- Rust and real FFI tests cover saved-revision planning/validation, tombstone planning, canonical bytes,
  invalid digests, identity receipts, and cleanup-warning diagnostics.
- Production create/save/reload/delete paths write only Rust canonical saved-revision/tombstone bytes and
  have zero Swift constructors, encoders, or tombstone-warning rewrite helpers for those artifacts.
- Existing persistence-authority tests preserve revision recovery, create/save/reload/delete ordering,
  deletion cleanup warnings, cancellation, and lease handoff without an observable behavior change.
- Focused Bridge/DomainRuntime tests, generated-binding checks, product build, format, lint, Rust format,
  guardrails, and diff checks pass.

## P5-5d amendment — Rust workspace-catalog state-machine authority

P5-5d moves the complete V1 workspace-catalog semantic boundary behind the same exact-runtime prepared
persistence capability. Rust validates catalog schema, revision, timestamps, workspace identities, file
URLs, unique live and deleted identities, disjoint live/deleted sets, embedded deletion tombstones,
input/output size, and canonical bytes. Revision advance is checked and rejects `UInt64.max`; it can never
wrap to an older fence. A closed transition planner owns the four established policies: legacy `seed` at
revision zero, create/recreate
`upsert` with sorted live entries and removal of the same identity's tombstone, authoritative `delete`
with stable surviving order and replacement tombstone, and crash-recovery `recoverCreate` with sorted live
entries while preserving tombstones. Every mutating transition consumes the exact validated current
revision and returns a digest-bound canonical candidate before Swift performs a catalog write.

All production catalog semantic reads use this Rust validator: bootstrap, targeted refresh, current
revision, mutation admission, and lazy migration. Missing-catalog fallback may still read the legacy Swift
index because Rust performs no filesystem I/O, but Rust must construct and validate the revision-zero
catalog before it can be published or used by a mutation. Bootstrap also validates deletion sidecars
through Rust; Swift may materialize verified canonical records into domain values but cannot independently
decode or repair catalog/tombstone semantics.

Swift remains the sole physical writer. It retains the workspace storage lease and epoch permit,
catalog/workspace file locks, atomic replacement, workspace document/journal/metadata ordering, rollback
artifacts, and post-delete best-effort cleanup. Catalog publication remains the create/delete authority
point, but the bytes and state transition at that point are exclusively Rust-planned. Existing corruption
behavior is preserved: bootstrap/refresh project malformed or future catalogs as degraded read-only,
ordinary mutations fail closed, missing catalogs retain legacy fallback, duplicate or overlapping
live/deleted identities are rejected, and catalog tombstones suppress live entries. Sidecars are never
deletion authority: bootstrap probes at most the catalog's deletion count, using exact UUID filenames, and
accepts a sidecar only when every authoritative tombstone field except the cleanup diagnostic matches.

### P5-5d done-when

- Rust tests cover validation plus seed/upsert/delete/recover-create transitions, exact revision fences,
  stable ordering, tombstone replacement/removal, duplicate identity rejection, future schema, malformed
  timestamps/URLs, and input/output limits.
- Real FFI/Bridge/DomainRuntime tests prove canonical catalog and tombstone receipts remain bound to every
  requested identity, revision, URL, timestamp, and operation before any write.
- Production `DomainPersistence` contains one catalog-path write fed only by Rust canonical bytes and zero
  catalog/tombstone constructors, JSON decoders, encoders, or Swift sorting/filtering state transitions.
- Existing bootstrap/refresh/create/delete/recreate/pending-create recovery, corruption, cancellation, and
  lease-handoff regressions retain observable behavior; focused build/style/codegen/guardrail checks pass.

## P5-5e amendment — Rust save transaction and pending-save recovery authority

P5-5e moves the save-specific durable state machine behind the exact-runtime prepared Rust persistence
capability. Rust prepares one bounded transaction from the exact nonmissing raw journal snapshot, the
Rust-canonical effective journal, candidate workspace-document bytes, optional current disk-document
bytes, and the closed save command. Rust proves the effective journal is either that raw snapshot's
canonical form or its exact pending-save recovery against the supplied disk document; it also projects
the candidate document and requires the requested workspace identity. It owns artifact order, action
identity/digest binding, the workspace-document
authority point, pre- versus post-authority failure classification, and restart recognition of a pending
save. The persisted V1 journal, workspace document, and saved-revision schemas do not change.

The transaction yields closed directives for pending-journal CAS replacement, workspace-document atomic
replacement, committed-journal CAS replacement, saved-revision atomic replacement, and terminal
committed/failed outcomes. Every action report must match the current action identity and expected digest;
out-of-order or conflicting replay fails closed. Pending-journal or document failure is a failed save.
Successful document replacement activates a prevalidated commit receipt and is the sole authority
transition: every later journal/revision/runtime/cancellation failure yields committed with recoverable
finalization status and can never become a false failed retry.

Pending-save restart classification is likewise Rust-owned. Rust validates the exact journal, optional
bounded document bytes, document digest, projected workspace identity, and recovery transition. Missing
or digest-mismatched documents remain uncommitted; matching but corrupt/wrong-identity documents fail as
corruption; a valid match returns the Rust-canonical clean journal. Swift no longer derives commitment
from a digest comparison or invokes the generic `save`/`recoverPending` transitions in production.

Swift remains the sole filesystem writer and retains the storage lease/epoch permit, catalog→workspace
lock order, path capabilities, single-descriptor bounded reads, exact raw-journal digest CAS, atomic
fsync/rename, and artifact cleanup. Only `ENOENT` is represented as an absent document; oversized,
permission, I/O, and cancellation failures propagate and can never be reclassified as missing. `DomainWorkspaceContextAuthority` continues to own command admission,
deduplication, in-memory records, results, and publication order. Create, delete, external reload,
conflict rebase, and catalog policy are unchanged by this slice.

### P5-5e done-when

- Rust tests cover the complete directive sequence, exact action/digest reports, external-document
  conflict parity, failure/cancellation at every action, terminal replay/close behavior, and pending-save
  recovery for missing, mismatched, valid, malformed, wrong-identity, future, and oversized inputs.
- Real FFI and Bridge tests prove the transaction object is exact-runtime bound before authority, returns
  a prevalidated commit receipt with the document directive, and cannot be confused with generic journal
  APIs.
- Production save executes only Rust directives; source guards prove zero direct generic `save` and
  `recoverPending` decisions while preserving the one physical journal-write choke point.
- Existing save/restart/CAS/cancellation/lease-handoff regressions plus focused Rust, FFI, Bridge,
  DomainRuntime, generated-binding, product-build, format, lint, guardrail, and diff checks pass.

## P5-5f0 amendment — exact raw catalog replacement fence

Every production workspace-catalog mutation now captures the physical artifact's exact presence and raw
SHA-256 digest in the same bounded read that supplies Rust validation. The single catalog write choke
point first writes and fsyncs its temporary candidate, then Swift reopens and rereads the live artifact
and requires exact presence and raw-digest equality immediately before rename. Semantically equivalent
re-encoding with the same catalog revision is still a conflict; staging latency cannot let a planner
overwrite bytes it did not observe.

The fence covers create/recreate publication, delete authority, crashed-create recovery, and lazy
migration from an absent catalog. A mismatch performs no write and returns the existing revision conflict
surface after Rust validates the newly observed catalog. Rust remains semantic catalog authority while
Swift retains the storage lease, catalog lock, bounded descriptor reads, digest comparison, and physical
fsync/rename. Supported writers must honor the catalog lock; a non-cooperating writer that replaces the
path after the final comparison but before rename is outside this protocol because POSIX rename has no
compare-and-swap primitive. This closes the shared durability prerequisite before P5-5f1 moves delete
sequencing behind a prepared Rust transaction.

### P5-5f0 done-when

- The only catalog write helper requires an exact raw snapshot, Rust validation candidate, logical
  expected revision, and prepared validator.
- Every production catalog writer supplies the snapshot captured before planning; there is no unguarded
  catalog write overload.
- A deterministic regression replaces the catalog with different raw bytes at the same revision after
  temporary-file staging but before final validation, proving the mutation conflicts, removes the staged
  candidate, and preserves the external bytes and workspace.
- Authority/source-guard tests, formatting, lint, product build, guardrails, and diff checks pass.

## P5-5f1 amendment — prepared Rust delete authority transaction

P5-5f1 moves delete preparation and its durable authority classification behind one exact-runtime Rust
transaction. Rust consumes the exact raw/effective catalog pair, the effective workspace journal, and a
closed request containing workspace/file identity, working/catalog revisions, recorded operation, and
deletion timestamp. It validates every input, plans the canonical deletion tombstone and catalog delete
transition, binds them into one request digest, and yields a single `publishCatalog` action carrying the
exact raw-catalog digest, logical revision fence, canonical catalog bytes, and a prevalidated commit
receipt.

The catalog replacement remains the sole delete authority point. A cancelled, conflicting, or failed
catalog action terminates as failed; a digest-bound successful report terminates as committed. Once the
physical catalog rename succeeds, runtime or reporting failure can never turn the delete into a false
failed retry: Swift activates the attached receipt before reporting success and continues committed
finalization from that receipt if Rust becomes unavailable.

Swift retains the storage lease and mutation permit, runtime-policy to catalog to workspace lock order,
bounded reads, P5-5f0 staged raw-byte CAS replacement, and all path capabilities. Rust preparation
requires the requested live catalog identity and file URL plus the exact applied-delete operation envelope;
a stopped exact runtime cannot advance a pre-authority transaction. Deletion-sidecar publication plus
journal, revision, document, git-data, and managed-directory cleanup execute only after a committed Rust
receipt and a durable catalog-directory sync. A rename followed by directory-sync failure remains applied
in-process through the attached receipt, but preserves every artifact and reports an indeterminate cleanup
warning. Generic catalog `tombstone + delete` planning is no longer reachable from the production delete
path; create, recovery, lazy migration, and post-delete cleanup-warning enrichment are unchanged.

### P5-5f1 done-when

- Rust tests cover exact input binding, the single directive and receipt, action identity/digest replay,
  cancellation/conflict/write failure, close/runtime lifetime, and the pre/post-authority boundary.
- Real FFI and Bridge tests prove the prepared object and receipt are exact-runtime bound and reject
  malformed or contradictory catalog/journal/request inputs.
- Production delete executes only the prepared Rust directive; its only pre-authority physical mutation
  is the P5-5f0 catalog CAS write, and all cleanup starts after receipt activation.
- Existing delete/recreate/restart/corruption/cancellation/lease-handoff tests plus focused Rust, FFI,
  Bridge, DomainRuntime, codegen, product-build, style, guardrail, and diff checks pass.
