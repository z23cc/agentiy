# Headless MCP domain runtime P11 — Execution handoff

Status: implemented (2026-08-30).

## Contract

P10 moved resource-lane construction and catalog-bound admission into the domain host. P11
completes the invocation handoff: the installed Rust catalog is now the only production source
for operation identity, admission class, and registration scope. Transport adapters may select a
physical window or repository resource, but they cannot reconstruct tool semantics or operation
sets.

Every `MCPDomainHost.invoke` call validates the operation after security identity checks and
before the final active-invocation fence. Production app and standalone runtimes inject the same
Rust operation resolver used by catalog diagnostics. Unknown tools, malformed operation values,
unknown operations, resolver failures, and resolver identities that do not match the installed
entry all fail closed. Fixture-only hosts may use the immutable Rust-projected policy for tests.

## Admission and dispatch

`MCPDomainHost` exposes snapshot-bound lookup for admission class and registration scope. The app
connection manager uses these lookups for evidence classification and exact binding resolution;
it no longer reads a static catalog entry on the call path. Application, window, and multi-
repository leases are created by the host and carry the installed catalog digest. The repository
coordinator canonicalizes Git common-directory identities and atomically acquires all repositories
in a multi-repository call, so the same repository is serialized while unrelated repositories
proceed.

The host reserves an invocation identity before any asynchronous resolver or routing work. This
preserves duplicate-request rejection even when operation resolution suspends. Pending identities
fence duplicate calls immediately but are intentionally not counted as outstanding execution; a
drain may settle while a pre-admission caller is suspended, and that caller observes the final
draining fence when it resumes. Once the final fence admits the request, the pending reservation is
replaced by the host-owned active task and released exactly once on settlement. Catalog validation
and uninstall additionally require the pending set to be empty, so an in-flight pre-admission call
cannot outlive a catalog replacement.

Standalone `tools/call` no longer performs a hard-coded `agent_run`/`agent_explore` operation
switch. It validates arguments through the prepared runtime host, then resolves and invokes the
exact registration. The compatibility helper retained in the direct-headless test target derives
its policy from the generated Rust projection and is not used by production handlers.

## Failure and lifecycle rules

A catalog resolver error is reported as an unavailable operation authority, not as an unknown
operation and never as permission to execute. A Rust identity with a different canonical tool or
an `unknown` operation is rejected. Closing the host closes every catalog-derived controller and
the repository coordinator; waiting leases settle through the same bounded drain path, while
pending invocation reservations are fenced by lifecycle and removed by their owning call. Catalog
uninstall remains possible only after all active leases, waiters, pending invocations, and active
invocations have settled.

No MCP wire schema, operation alias, routing overlay, physical I/O, lease/CAS behavior, or event
publication behavior changes. The change removes only duplicate semantic decisions from transport
and provider adapters.

## Verification gates

- Host tests cover Rust resolver identity, resolver mismatch rejection, duplicate invocation
  fencing across an asynchronous handoff, catalog-bound registration scope/class, repository
  serialization, cancellation, and drain accounting.
- Direct-headless configuration tests derive operation values from the catalog policy and verify
  default, malformed, and unknown-operation behavior.
- Focused Domain host, repository admission, direct-headless, catalog, and policy tests pass.
- Rust/FFI catalog parity, deterministic UniFFI generation, Swift product builds, formatting,
  lint, and repository guardrails remain required before commit.
