# Rust workspace document projection v1

Date: 2026-08-25
Status: P5-1a read-only parity substrate
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

P5-1b may arm the projector behind the production read lifecycle as a comparison-only observer.
No Rust authority or storage writer claim is permitted until that later slice proves continuous
parity and explicitly crosses the cutover gates.
