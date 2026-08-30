# Headless MCP Domain Runtime P9 — Runtime Catalog Handoff

Status: implemented (2026-08-30).

## Contract

`rust/crates/proto/catalog/mcp_catalog_v1.json` remains the sole authored MCP/tool
catalog. Rust validates the frozen 27-tool order, closed metadata sets, registration
scopes, operation policy shape, and resource limits before exposing the catalog. The
canonical payload is recursively key-sorted, compact JSON; its lowercase SHA-256 digest
is the identity of the snapshot.

`CoreRuntime.mcpToolCatalogV1` returns the digest, exact canonical payload bytes, and
typed records. `CoreRuntime.mcpToolOperationIdentityV1` resolves normalization, defaults,
and aliases (including `rename -> move` and `handoff -> extract_handoff`) from that same
catalog. Both exports are runtime-identity fenced and fail closed.

## Runtime boundary

`AgentryCoreBridge.mcpToolCatalog()` independently hashes and parses the canonical payload,
checks the frozen order, and compares every typed FFI record against its payload record
before returning a snapshot. `MCPDomainCatalogSnapshot` carries the verified bytes and
metadata into `MCPDomainRuntime` through `DomainRuntimeConfiguration.catalogProvider`.
Production App and DirectHeadless compositions require this handoff before registration;
missing or malformed catalog state leaves the runtime degraded and rejects registration.

App and standalone registration, read definitions, tool advertisement, capability
classification, operation identity, and configured limits consume the installed runtime
snapshot. The generated Swift catalog remains only a compatibility fixture for direct
unit-test construction; it is not used by the production handoff paths. Physical tool
execution, routing, lease/CAS, and event publication remain Swift-owned adapters.

## Compatibility and safety

The external MCP contract is unchanged: all 27 names, frozen order, schemas, annotations,
enabled defaults, scopes, capabilities, admission classes, operation policy, aliases, and
limits remain byte-compatible. Canonical payload/digest mismatch, typed-record drift,
unknown metadata, stale runtime identity, and absent startup handoff are fail-closed. No
visible app launch or restart is required for this phase.
