# Headless MCP Domain Runtime P10 — Admission Handoff

Status: implemented (2026-08-30).

## Contract

P9 established the verified Rust catalog snapshot as the input to domain registration. P10
extends that boundary to admission itself: the same snapshot now owns host resource-lane
construction, capability-based advertisement, and pre-admission classification. No production
path reconstructs a lane limit from a Swift admission-class table.

The canonical payload remains byte-compatible. `read_file` deliberately encodes its
machine-derived content-read capacity as `connection_lane: 0` and `resource_lease: null`.
`MCPDomainCatalogSnapshot.configuredLimits` resolves that explicit host-derived marker to
`ContentReadConcurrencyCapacity.maximumConcurrentReads`; all other limits are taken verbatim
from the Rust payload. The payload bytes and digest are never rewritten.

## Startup and lifecycle

`MCPDomainRuntime.start()` obtains the catalog once, validates both consumers without side
effects, installs it into `MCPDomainToolRegistry` and `MCPDomainHost`, then publishes the
process facade and only then bootstraps workspace state. Any commit failure rolls both actor
states back before degradation escapes. Host installation constructs separate
application/window exclusive, small-read, file-read, and repository git-read controllers from
the snapshot. Limits for one admission class/resource scope must be present, positive, and
uniform; malformed or inconsistent limits fail closed and leave the runtime degraded. A runtime
configured with a catalog provider cannot resolve, register, or admit tools before installation.

The host snapshot exposes the installed catalog digest for diagnostics and lifecycle tests.
Drain closes every snapshot-derived controller exactly once. Runtime shutdown clears the
process compatibility facade only when its digest still owns the slot, preventing stale catalog
state from crossing a stopped runtime. Direct fixture hosts without a provider retain their
isolated compatibility controller construction; that path is not used by application or
standalone production composition.

## Policy and transport boundary

`MCPDomainHostPolicy` resolves tool existence, capability, admission class, explicit-grant
checks, and role advertisement from its installed `MCPDomainCatalogSnapshot`. The policy catalog
offers snapshot-aware overloads so standalone advertisement and host policy use the exact same
ordered records. The app transport's static helpers remain compatibility adapters for existing
callers, but their catalog-derived sets and lane limits are computed rather than cached and
therefore observe the installed runtime snapshot. Production operation evidence resolves via
the Rust operation resolver; the synchronous Swift helper remains fixture-only.

No MCP wire schema, tool name, alias, annotation, registration scope, routing behavior, physical
I/O, lease/CAS behavior, or event publication behavior changes. Catalog absence, typed-record drift,
canonical-byte drift, binding definition mismatch, invalid effective limits, stale registrations,
repository admission failure, and runtime identity failures remain fail-closed.

## Verification gates

- `MCPDomainHostTests` covers successful digest/limit handoff, repository admission, canonical
  binding mismatch, runtime shutdown cleanup, and degraded fail-closed startup.
- `CoreMCPToolCatalogTests` rejects a semantically equivalent but non-canonical payload byte
  ordering, proving the bridge enforces Rust's exact canonical representation.
- Standalone and direct-headless composition tests continue to resolve the complete 27-tool
  snapshot and use snapshot-aware policy advertisement.
- Rust catalog/FFI payload parity, UniFFI generation, Swift builds, lint, and repository
  guardrails remain required before handoff.
