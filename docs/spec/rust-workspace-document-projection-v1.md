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
live/deleted identities are rejected without salvaging or reactivating the ambiguous live row, and
catalog tombstones suppress live entries. Sidecars are never
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

## P5-5f2 amendment — prepared Rust create and recovery authority transaction

P5-5f2 moves fresh create, recreate, and interrupted-create recovery behind one exact-runtime Rust
transaction. Rust consumes the exact raw/effective catalog pair, raw/effective journal state, canonical
workspace document bytes, and a closed request containing workspace/file identity, catalog revision,
create operation, context revision/digest tables, and timestamp. It rejects an existing live identity,
validates recreate tombstones, binds every input into one request digest, and plans the pending/committed
journal, saved-revision sidecar, deletion-sidecar removal, and canonical catalog upsert.

A fresh create or recreate yields the ordered actions `writePendingJournal`, `publishWorkspaceDocument`,
`writeCommittedJournal`, `writeSavedRevision`, `removeDeletionSidecar`, and `publishCatalog`. Interrupted
create recovery accepts only a digest-matching document plus a Rust-validated effective journal containing
the exact applied create marker; it yields only `publishCatalog`. Recovery may clear the same identity's
tombstone because the bound committed create marker proves that recreate artifacts were durably staged.
An arbitrary missing catalog row, stale Swift record, or mismatched URL can never synthesize identity.

The exact raw-CAS catalog rename remains the sole create authority point. Every earlier action is
pre-authority and rolls back its staged document/journal/revision artifacts on in-process failure. The
Rust request validator binds each supplied context digest to the canonical raw `composeTabs` object,
requires exact initial `1/1/clean` workspace/context revisions, one matching create operation, and any
same-identity tombstone's complete applied-delete semantics. Pending-save recovery additionally binds the
pending operation ID to that sole create marker.

Immediately before catalog replacement, the prepared transaction acquires a one-shot Rust runtime
authority permit. Shutdown and permit admission share the runtime lifecycle lock; if shutdown wins, no
rename begins, and if the commit wins, the runtime cannot reach `Stopped` until the synchronous rename and
receipt activation return. After rename, the attached Rust receipt defines success even if reporting fails.
Directory-sync uncertainty preserves the staged artifacts so a later recovery can safely re-publish
identity.

Read-only bootstrap never exposes a catalog-absent journal. Lease-backed reconciliation scans only the
bounded runtime-owned journal directory, validates the exact disk document, and submits every candidate to
the Rust recovery transaction under catalog/workspace locks; it does not exclude tombstoned identities or
construct a Swift recovery candidate. Swift retains storage lease, mutation permit, lock order, bounded
descriptor I/O, raw digest comparison, path capabilities, physical writes/removals, and rollback execution;
it no longer constructs or interprets the create/recovery journal or catalog transition in the production
path.

### P5-5f2 done-when

- Rust tests cover fresh create, recreate, interrupted recovery, exact raw/effective input binding,
  contradictory operation/context/catalog state, action order/replay, cancellation/conflict/write failure,
  close/runtime lifetime, and authority receipt activation.
- Real FFI and Bridge tests cover the prepared object, all action payloads, recovery-only publication, and
  runtime stop immediately before and after catalog authority.
- Production create and missing-entry recovery execute only Rust directives; generic `upsert` and
  `recoverCreate` catalog planning have zero production callers.
- Existing create/recreate/restart/pending-create recovery/CAS/cancellation/lease-handoff regressions plus
  focused Rust, FFI, Bridge, DomainRuntime, codegen, product-build, style, guardrail, and diff checks pass.

## P5-5g amendment — prepared Rust working-journal mutation authority

P5-5g moves `unchanged`, `working`, `externalReload`, and `conflictRebase` commits behind one
exact-runtime prepared Rust transaction. Rust consumes the exact raw/effective journal pair, the complete
semantic transition, canonical candidate document bytes, the current bounded disk document when required,
and the current catalog revision. It validates workspace/file identity, raw/effective recovery equivalence,
revision CAS, context tables and digests, operation ledger, external-document digest, and the resulting
canonical journal before yielding any physical action.

The transaction yields `writeJournal` and, only for external reload, `writeSavedRevision`. The journal CAS
rename is the authority point. Immediately before that rename, Swift must acquire the transaction's
one-shot Rust runtime authority permit; shutdown and admission share the runtime lifecycle lock. A failure
before journal replacement is a failed mutation. Once the journal receipt is activated, a later revision
sidecar failure is reported as committed with `revisionSidecarMissing`, never as a retryable failed
mutation; DomainRuntime preserves that condition in the external-reload publication diagnostic. The
journal success report is accepted only while the transaction-owned authority permit remains active,
and consumes that permit atomically with receipt activation. Exact action reports are replay-safe;
wrong action IDs, digests, runtime identities, duplicate permit acquisition, post-close calls, and
contradictory inputs fail closed.

Swift retains the storage lease and epoch permit, catalog/workspace lock order, bounded descriptor reads,
path capabilities, exact raw-digest compare-and-swap, physical atomic writes, and error translation. It no
longer independently plans these four journal transitions, decides their action sequence, or reports
post-authority failures as pre-authority failure. Save, create, delete, and bootstrap recovery retain their
specialized prepared transactions.

### P5-5g done-when

- Rust tests cover all four mutation kinds, exact raw/effective binding, stale revision and disk document,
  context/operation contradictions, action replay, cancellation/conflict/write failure, partial success,
  close/runtime lifetime, and one-shot authority admission.
- Real FFI and Bridge tests cover the prepared object, action/receipt payloads, external-reload sidecar,
  runtime stop before/after journal authority, and malformed input rejection.
- Production callers execute only the prepared Rust directives; direct `planJournalTransition` plus
  `replaceJournal` composition has zero callers for these four mutation kinds.
- Existing working/save/external-reload/conflict/cancellation/restart/lease-handoff regressions plus focused
  Rust, FFI, Bridge, DomainRuntime, codegen, product-build, style, guardrail, and diff checks pass.

## P5-5h amendment — Rust-owned post-authority finalization verdicts

P5-5h removes the last Swift semantic inference from prepared working-journal and save finalization. Every
Rust action now carries optional `postAuthoritySuccessFinalization` and
`postAuthorityFailureFinalization` verdicts. Pre-authority actions carry neither. The document/journal
authority action carries the exact committed fallback for a physical success whose report cannot be
returned, and later post-authority journal/revision actions carry both success and failure verdicts. Swift
selects only by the physical I/O fact it directly owns; it no longer derives finalization from receipt
shape, action kind, or whether a saved-revision receipt is present.

The verdict matrix is closed in Rust. A working-journal authority write without a revision sidecar
finalizes immediately; external reload retains `revisionSidecarMissing` until its sidecar succeeds. A save
document write retains the pending journal, committed-journal success advances to
`revisionSidecarMissing`, committed-journal failure retains the pending journal, and saved-revision
success/failure yields `finalized`/`revisionSidecarMissing`. Bridge and DomainRuntime validate that exact
matrix before exposing a typed directive. Domain execution additionally requires the closed action order,
rejects terminal success before a physical authority point, and compares the terminal receipt/finalization
with the already activated Rust receipt/verdict. After authority, a malformed terminal or failed directive
falls back only to that previously attached Rust verdict, so transport drift cannot create a false retry.

Missing production journals also stop using the generic transition-plan tuple in `DomainPersistence`.
The typed `seedWorkingJournal` adapter submits the seed policy to Rust and returns exactly one validated
canonical journal. Swift retains the storage lease, bounded descriptor reads, file locks, raw-digest CAS,
atomic replacement, and error translation; Rust remains the sole planner and finalization authority.

### P5-5h done-when

- Rust tests assert the complete pre/post-authority verdict matrix and its agreement with terminal reports.
- Real FFI and Bridge tests preserve every verdict across generated bindings and after exact-runtime stop.
- Production `DomainPersistence` contains no generic `planJournalTransition` helper and no receipt-shape or
  hard-coded post-authority finalization inference.
- Existing save, working, external-reload, conflict-rebase, restart, cancellation, and lease-handoff
  regressions plus focused Rust, FFI, Bridge, DomainRuntime, codegen, product-build, style, guardrail, and
  diff checks pass.

## P5-5i amendment — dedicated Rust missing-journal seed authority

P5-5i removes the final production Domain consumer of the generic working-journal transition-plan tuple.
The exact-runtime Rust seed operation accepts the established bounded `kind: seed` request, rejects every
other transition kind, reuses the canonical generic seed implementation, and returns exactly one
`WorkspaceWorkingJournalValidationV1`. Rust therefore owns both seed semantics and the invariant that a
missing-journal seed has no secondary committed candidate.

`DomainPersistence` continues to supply factual workspace identity, file URL, revision state, saved digest,
context digests, and timestamp. Its typed adapter now calls only the scalar seed endpoint and validates the
returned identity, URL, canonical bytes, and digest. DomainRuntime no longer exposes or consumes a generic
`primary`/`committed` journal plan. The lower-level Core generic planner remains available only for
compatibility and differential testing; it has no production Domain caller.

Seeding remains preparatory and establishes no filesystem authority. Swift retains the storage lease,
bounded descriptor reads, locks, raw-digest CAS, atomic replacement, and selection of Rust-provided
post-authority verdicts from physical I/O success or failure. A stopped runtime, malformed/oversized seed,
or invalid seed state fails before any specialized transaction or journal write begins.

### P5-5i done-when

- Rust tests prove dedicated seed output is byte-identical to the generic seed primary, deterministic, and
  rejects malformed and non-seed requests.
- Real FFI and Bridge tests cover canonical seed output, input bounds, generic differential parity, and the
  exact-runtime shutdown fence.
- `DomainWorkspaceRustJournal` contains no generic transition-plan type, `planTransition` adapter, or
  `primary`/`committed` interpretation; `DomainPersistence` retains exactly one typed seed caller.
- Existing missing-journal/bootstrap/save/recovery regressions plus focused Rust, FFI, Bridge,
  DomainRuntime, codegen, product-build, style, guardrail, and diff checks pass.

## P5-5j amendment — generic journal planner transport retirement

P5-5j removes the generic working-journal transition planner from the Rust FFI contract and Swift Bridge.
After P5-5i there are no production or Domain test callers: missing-journal seed uses its scalar Rust
endpoint, while create, recovery, save, and journal mutations use their specialized exact-runtime prepared
transactions. The former generic request/plan/response records and `planTransition` prepared-validator API
therefore no longer express a supported cross-language authority boundary.

The generic planner implementation remains private inside the Rust journal module. Dedicated seed and
prepared transaction constructors reuse it to produce canonical candidates, so there is still one
transition algorithm and no behavior fork. Its Rust unit tests retain all-kind coverage and seed
differential parity; cross-language tests now exercise only supported typed operations. Removing the
transport surface does not change storage lease ownership, physical I/O, CAS, action sequencing, or
post-authority finalization.

### P5-5j done-when

- The generic planner function and plan type are private to the Rust journal module and retain their existing
  unit coverage.
- UniFFI, generated C/Swift bindings, Core transport, and prepared validator expose no generic journal
  transition planner records or method.
- Production Domain source and tests use only validation, scalar seed, metadata/catalog operations, pending
  recovery, and specialized prepared transactions.
- FFI export tests, real Bridge tests, Domain source guards, deterministic codegen, product build, style,
  guardrails, Rust formatting, and diff checks pass.

## P5-5k amendment — dedicated catalog seed and generic planner transport retirement

P5-5k removes the final production use of the generic workspace-catalog transition planner. Missing-catalog
bootstrap and legacy migration now submit only a typed seed request through `seedCatalog`; Rust rejects any
non-seed transition before returning a canonical revision-zero catalog. Create/recreate, recovery, and delete
continue to use their specialized prepared transactions, so no mutable catalog policy requires a generic
Swift-visible planner.

The generic catalog transition enum and planner remain private inside the Rust journal module because the
prepared transaction constructors reuse the same upsert, delete, and recovery algorithm. UniFFI and the
Swift Bridge expose only catalog validation and scalar seed operations. DomainRuntime no longer defines a
catalog transition enum or interprets transition-specific receipts; it verifies the dedicated seed's
revision, timestamp, entries, deletion set, canonical bytes, and digest before the existing lease-backed
physical publication path can use it.

### P5-5k done-when

- The generic catalog planner is private to Rust and retains seed/upsert/delete/recovery, revision-overflow,
  duplicate-identity, URL, and timestamp unit coverage.
- UniFFI, generated C/Swift bindings, Core transport, and prepared validator expose no generic catalog
  transition request or method; the scalar seed endpoint is exact-runtime fenced and bounded.
- `DomainPersistence` has exactly one catalog seed caller, used only for missing-catalog bootstrap/migration;
  all catalog mutations remain specialized prepared transactions.
- Real FFI/Bridge seed tests, Domain seed/authority/source-guard regressions, deterministic codegen, product
  build, style, guardrails, Rust formatting, and diff checks pass.

## P5-5l amendment — metadata planner transport retirement

P5-5l removes standalone saved-revision planning from the cross-language contract. Every production saved
revision candidate is already attached to a specialized Rust create, journal-mutation, or save transaction;
Swift only validates existing sidecars during reads. The saved-revision request planner therefore becomes a
private Rust helper reused by those prepared transactions, while the validation endpoint remains public.

Deletion tombstone creation likewise remains private to the Rust delete transaction. The only post-authority
need is recording best-effort artifact-cleanup diagnostics in the non-authoritative tombstone sidecar and
return receipt. A dedicated cleanup-amendment endpoint accepts the exact canonical authoritative tombstone
bytes plus a bounded JSON warning list, revalidates the tombstone, changes only the operation diagnostic, and
returns canonical bytes. Swift must verify every tombstone field except that diagnostic remains identical.
Pending-save resolution remains a supported production recovery boundary and is not retired in this slice.

### P5-5l done-when

- Saved-revision and general deletion-tombstone planner functions are private to Rust; prepared transactions
  retain their existing metadata generation and finalization coverage.
- UniFFI, generated bindings, Core transport, and Domain expose no standalone saved-revision or general
  deletion-tombstone planner, only validation plus the dedicated cleanup amendment.
- Cleanup amendment rejects non-canonical authoritative tombstone bytes and empty, malformed, oversized, or
  invalid warning requests; the final canonical artifact remains size-bounded and preserves every authoritative
  tombstone field except the exact `artifact_cleanup_incomplete` diagnostic.
- `DomainPersistence` invokes cleanup amendment only after delete authority, never before catalog publication;
  pending-save recovery remains unchanged.
- Focused Rust/FFI/Bridge/Domain delete, restart, metadata, source-guard, codegen, product-build, style,
  guardrail, formatting, and diff checks pass.

## P5-6a amendment — Rust workspace-command identity parity candidate

P5-6a starts the mutation-authority cutover at the immutable operation-identity boundary. Rust accepts one
bounded typed command-identity request covering the five established workspace commands, the four command
origins, every expected revision fence, and the protected-agent identity set. It validates UUID, digest,
file-URL, optional-field, and cardinality shape; applies the frozen sort and length-prefixed UTF-8 encoding;
and returns the canonical workspace identity plus the SHA-256 operation fingerprint used for durable
collision and deduplication decisions.

This slice is comparison-only. Swift remains the sole production command admission and mutation authority,
keeps its existing fingerprint implementation as the parity oracle, and performs no Rust-backed write. The
candidate is exact-runtime fenced and available only through the prepared persistence capability so stopped
or replaced runtimes fail closed. A later slice must arm a bounded observer, register performance and
behavioral parity evidence, and explicitly flip the common app/headless command path before deleting the
Swift oracle.

### P5-6a done-when

- Rust covers create, replace, save, delete, and external-conflict resolution; app-presentation, app-MCP,
  standalone, and external-reload origins; nil/non-nil revision fences; and protected-identity stable order.
- Invalid UUIDs, digests, file URLs, contradictory optional fields, and oversized protected-identity sets fail
  closed without producing a fingerprint.
- Typed UniFFI, generated bindings, Bridge, and Domain prepared-validator adapters preserve the request and
  receipt without a second fingerprint implementation.
- Real-Core Domain differential fixtures match the frozen Swift fingerprint for every command/origin family.
- Production command execution remains Swift-authoritative and source guards prevent accidental candidate
  use as mutation admission before the P5-6 cutover gate is explicitly closed.

## P5-6b amendment — bounded command-identity comparison observer

P5-6b arms the P5-6a candidate on the common admitted workspace-command path without changing command
behavior. Immediately after the existing Swift authority computes and times its operation fingerprint, it
submits the immutable command envelope, fingerprint, and elapsed time to a synchronous, non-suspending
observation sink. The sink copies only the compact identity fields Rust requires; it never retains workspace
or context document bytes. It never calls Rust, awaits work, acquires a mutation permit, or influences
deduplication, collision handling,
persistence, disposition, or publication. A stopped, saturated, or unavailable observer only records a
dropped/error sample; Swift remains the sole production mutation authority.

The observer owns one serial worker and a bounded FIFO. Production limits are 64 pending commands, 64 MiB of
combined active-plus-pending compact identity input, 32 MiB per command, and 256 protected identities.
Variable URL/digest bytes and the bounded fixed-field identity array are charged with checked arithmetic;
workspace metadata, workspace document `Data`, and context document `Data` are absent from the queued type.
When capacity is exhausted, the oldest pending sample is discarded; an active comparison is never evicted. One
`bufferingNewest(1)` wake signal coalesces scheduling only—the exact FIFO and all bounds remain under the
observer lock. Shutdown first closes mutation admission and waits for every already-issued command permit to
finish. It then atomically closes observer ingress, counts pending/active cancellation and later rejected
observations as dropped, cancels and awaits the worker, and rejects later observations.

The worker invokes the exact-runtime Rust prepared capability on detached work and compares its value with the
Swift fingerprint captured at admission. No second Swift fingerprint implementation exists in the observer.
Only aggregate, privacy-safe dimensions are emitted: command kind, origin family, result, input-size bucket,
and latency bucket. Operation/workspace/context identities, paths, raw fingerprints, document bytes, and
content digests never enter metrics. A read-only evidence snapshot exposes matched, mismatched, failed,
dropped, completed, and aggregate Swift/Rust timing counters. It can report behavioral parity only after an
explicit positive caller-supplied minimum completed-sample floor; zero can never establish parity. It never
selects a performance threshold or flips production authority automatically.

### P5-6b done-when

- The authority path performs one non-suspending observation after its existing Swift fingerprint read and
  contains no Rust call, await, retry, or outcome dependency.
- Deterministic tests cover match, mismatch, Rust failure, count/byte pressure, oversized commands, shutdown,
  active cancellation, and observation while the projector is suspended.
- Runtime lifecycle starts the observer before commands are admitted and cancels/awaits it during drain;
  injected projectors remain available for exact tests without enabling a Swift fallback.
- Metrics and evidence contain no command identity, UUID, URL, digest, raw bytes, or other workspace content;
  the production cutover gate remains explicitly closed.
- Focused DomainRuntime tests, source guards, product build, style, guardrails, and diff checks pass.

## P5-6c amendment — Rust command-identity production authority

P5-6c promotes the immutable command identity from comparison candidate to the production mutation-admission
input. After the storage mutation permit is admitted, DomainRuntime constructs the bounded compact identity
input and awaits the exact-runtime Rust prepared capability before any deduplication, collision lookup,
validation, revision fence, or persistence planning. The returned lowercase SHA-256 fingerprint is the only
fingerprint passed to operation lookup and every durable or transient ledger record. Invalid compact input,
Rust/runtime failure, cancellation, or an invalid receipt rejects the command without recording its operation
ID; Swift fingerprinting is never a fallback.

The existing bounded observer remains temporarily armed as a differential oracle. Only after Rust succeeds,
Swift computes the frozen legacy fingerprint and submits both completed values and their measured latencies to
the non-suspending observer. That precomputed-authority fast path performs no second Rust call; it can affect
only privacy-safe parity metrics. Queue pressure, observer shutdown, mismatch, or Swift-oracle failure cannot
change the Rust fingerprint or command outcome. The legacy Swift implementation remains solely for this
bounded comparison and is not consulted by deduplication, collision handling, persistence, or publication.

This slice does not yet move the durable operation ledger lookup into Rust. The 4,096-entry global index and
256-entry per-workspace index remain Swift-owned projections of Rust-validated journal/catalog records. The
next admission slice must move lookup, restart reconstruction, and collision/dedup receipt selection behind a
bounded Rust state protocol before those Swift indexes can be deleted.

### P5-6c done-when

- The common app/headless command path obtains one exact-runtime Rust fingerprint before operation lookup and
  uses that exact value for create, replace, save, delete, conflict resolution, and transient ledger writes.
- Rust failure, cancellation, invalid compact input, and malformed receipts reject without a Swift fallback or
  retained operation ID, so a later healthy runtime may retry the same envelope.
- The comparison observer accepts a precomputed Rust authority result without issuing a duplicate Rust call;
  its mismatches, failures, drops, and lifecycle remain diagnostics-only.
- Deterministic tests inject divergent Rust/Swift identities and prove deduplication/collision follows Rust,
  plus fail-closed retry and observer no-second-call behavior.
- Source guards, focused command/authority/runtime tests, product build, style, guardrails, and diff checks pass.

## P5-6d amendment — prepared Rust operation-admission index

P5-6d moves durable replay and operation-ID collision lookup behind one exact-runtime prepared Rust
capability. A newly prepared index is seeded atomically from the already Rust-validated live workspace
operation ledgers plus catalog deletion operations. Rust canonicalizes and validates every operation receipt,
derives the bounded 4,096-entry global index and each bounded 256-entry workspace index, and applies the
frozen lookup order: exact workspace first, then global. A matching fingerprint returns the complete prior
receipt and its lookup scope, a different fingerprint returns collision, and an absent operation returns
unseen. No caller may synthesize a deduplicated receipt from partial fields.

The prepared capability supports bounded insert, complete replacement, workspace-index removal, diagnostics,
and idempotent close. Global-only transient/deletion records never enter a workspace index; durable live
workspace receipts enter both. Removing a workspace drops only its local index because the established global
process-lifetime collision fence retains prior workspace operations until normal bounded eviction. Complete
replacement first collapses exact duplicate operation receipts, then deterministically sorts distinct IDs by
recorded timestamp and operation UUID, retains the newest bounded suffix, and reconstructs the same state after
restart. A duplicate ID with different timestamps retains the newest receipt; conflicting receipts tied on the
same timestamp are rejected in either input order. The global index plus all workspace indexes may retain at
most 65,536 receipts, and a live insert preflights that aggregate fence before mutating either index.

Every operation revalidates the captured Rust runtime identity and lifecycle. Closed, stopped, stale, malformed,
oversized, or internally inconsistent state fails closed without mutating the index. DomainRuntime now uses the
Rust decision as its production replay/collision authority. A synchronous operation-ID reservation is installed
before the first persistence suspension, so actor reentrancy cannot admit two unseen executions; matching
waiters retry the Rust durable lookup after the owner finishes, while a different fingerprint collides
immediately. A committed transaction must return its exact authoritative operation receipt. Missing or
mismatched receipts never fall back to a Swift provisional value: the physical commit remains successful, but
mutation admission is quarantined and projected read-only.

### P5-6d done-when

- Rust tests cover workspace-first lookup, global fallback, matching replay, collision, unseen, deterministic
  seed order, duplicate collapse before capacity, ambiguous duplicate rejection in both input orders, per-index
  and 65,536 aggregate capacity fences, atomic overflow rejection, global-only insertion, workspace removal,
  replacement, malformed receipts, close, and restart reconstruction.
- Typed UniFFI and Bridge preserve the complete prior receipt and lookup scope under exact runtime identity;
  no JSON or partial-receipt fallback crosses the authority boundary.
- Domain bootstrap/reconciliation replaces the whole Rust index from Rust-validated durable state before
  mutation admission; every successful/transient ledger update is mirrored synchronously or quarantines the
  capability for complete rebuild before the next lookup.
- Production deduplication/collision and receipt selection use only the Rust decision. Swift global/workspace
  operation indexes and lookup code are absent; a non-queryable 4,096-entry seed buffer exists only to rebuild
  the exact-runtime Rust capability after quarantine while preserving process-lifetime transient fences.
- Focused Rust/FFI/Bridge/Domain restart, collision, capacity, lifecycle, source-guard, product-build, style,
  guardrail, formatting, and diff checks pass.

## P5-6e amendment — Swift admission lookup retirement

P5-6e removes the final Swift replay/collision lookup and every per-workspace operation index. Workspace
records retain their Rust-validated journal operations only as persistence state. The sole remaining global
projection is an ordered, bounded reconstruction seed buffer: it exposes no operation-ID lookup and cannot
answer replay or collision. Rust remains the only production decision authority before persistence, after CAS
refresh, after workspace removal, and across lease reconciliation.

The seed buffer retains at most 4,096 complete receipts and feeds only complete prepared-capability replacement.
Every actual receipt update is synchronously inserted into Rust; any Rust mutation failure quarantines the
capability and the next admission must rebuild the complete Rust state or remain read-only. Source guards ban
the retired Swift index type, fields, subscripts, and differential lookup helper.

## P5-6f amendment — durable Rust admission reconciliation

P5-6f removes the final Swift-owned command-admission reconstruction buffer. The prepared Rust capability now
accepts one atomic durable reconciliation: it validates and reconstructs the complete durable workspace index
set, merges it with the existing process-lifetime global collision fence, re-applies deterministic global and
aggregate capacity limits, and publishes the replacement only after every check succeeds. A durable receipt
that conflicts with an already-admitted global identity rejects the reconciliation without changing either
index.

Swift constructs only the transient typed payload obtained from the current Rust-validated catalog tombstones
and workspace journals; it retains no global receipt cache and cannot answer, sort, trim, or repair operation
identity state. Lease acquisition performs durable reconciliation before mutation admission. Later catalog
reloads reconcile the exact durable workspace set while Rust preserves global transient receipts. Targeted CAS
refresh submits the exact refreshed workspace operations or authoritative deletion receipt; missing receipts,
invalid state, capacity failure, and runtime loss quarantine admission and project read-only rather than
rebuilding or inferring locally.

### P5-6f done-when

- Rust tests prove process-global receipts survive durable reconciliation, durable workspace indexes are
  replaced exactly, conflicting reconciliation is atomic, capacity remains bounded, and close/runtime fences
  still fail closed.
- Typed UniFFI, Bridge, and Domain adapters expose durable reconciliation without JSON or partial receipt
  reconstruction.
- `BoundedDomainOperationSeedBuffer`, `globalOperationSeeds`, lazy admission creation, and complete Swift
  replacement are absent from production source.
- Lease acquisition, catalog reload, CAS workspace refresh, and CAS deletion preserve replay/collision behavior;
  the deletion delta is taken from the Rust-validated catalog tombstone rather than synthesized in Swift.
- Focused Rust/FFI/Bridge/Domain authority, source-guard, codegen, product-build, style, guardrail, formatting,
  and diff checks pass.

## P5-6g amendment — Swift command-identity oracle retirement

P5-6g removes the comparison-only Swift command fingerprint implementation and its bounded observer after
Rust command identity and durable admission reconciliation become the sole production decision path. The
runtime no longer owns, starts, drains, injects, or exposes a command-identity comparison worker. The admitted
command path performs exactly one exact-runtime Rust identity request and uses that validated lowercase SHA-256
receipt for pending-command pairing, replay/collision decisions, persistence receipts, and publication.

`DomainWorkspaceCommandEnvelope` is now data only; it cannot locally derive an operation fingerprint. Rust
contract tests verify deterministic receipts, distinct command/origin coverage, and protected-identity stable
ordering without retaining a second semantic implementation as an oracle. Source guards ban the retired Swift
fingerprint accessor, observer sink, projector injection, and runtime lifecycle surface. This removes diagnostic
queueing and comparison metrics only; command outcomes, storage lease ownership, physical I/O, and failure
behavior remain unchanged.

### P5-6g done-when

- No production or test source defines `DomainWorkspaceRustCommandIdentityObserver`, its sink, or its projector
  injection and lifecycle surface.
- `DomainWorkspaceCommandEnvelope` contains no fingerprint algorithm, and production admission contains no
  Swift fingerprint read or fallback.
- Exact-runtime Rust identity remains required before pending-command pairing and prepared admission lookup;
  cancellation, malformed receipt, or runtime loss still fail closed.
- Focused command-identity, authority, lifecycle, source-guard, product-build, style, guardrail, formatting, and
  diff checks pass.

## P5-7a amendment — atomic prepared command preflight

P5-7a combines immutable command identity and durable replay/collision lookup into one exact-runtime operation
on the prepared Rust command-admission capability. The receipt contains the validated canonical workspace
identity, command kind, lowercase SHA-256 fingerprint, and the admission decision captured from the same locked
Rust state. Production may not call the standalone identity export and then separately ask the prepared index
for a decision.

Swift retains the workspace-storage lease, mutation permit, actor-local in-flight waiter coordination, physical
I/O, and command execution routing. The bounded prepared preflight and the actor-local pending check/reservation
execute synchronously in one authority actor turn; an `.unseen` receipt therefore cannot miss a reservation that
appears and disappears across actor reentrancy. A waiter that resumes after an identical in-flight command
completes must request a fresh Rust preflight before proceeding, so the newly inserted durable receipt is
observed; it may not reuse an earlier `.unseen` result. Semantic request validation rejects only that command and
does not quarantine the shared prepared capability; malformed receipts or runtime/capability failures fail closed
and quarantine it. Test-only resolver injection remains isolated from the default production path and cannot
enable a Swift fingerprint or lookup fallback.

### P5-7a done-when

- Runtime tests prove preflight identity/decision consistency, replay, collision, invalid input, close, and exact
  runtime fences.
- Typed UniFFI and Bridge receipts reject partial success/error shapes, mismatched workspace or command identity,
  malformed digest, and invalid replay receipts.
- The production authority performs one prepared preflight before pending reservation, repeats it after waiter
  wake-up, and contains no standalone identity-plus-decision pair.
- Cancellation or Rust/capability failure records no operation and remains retryable; focused Runtime/FFI/Bridge/
  Domain authority, source-guard, codegen, product-build, style, guardrail, formatting, and diff checks pass.
