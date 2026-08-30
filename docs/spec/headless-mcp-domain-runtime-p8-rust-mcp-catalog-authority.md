# Headless MCP Domain Runtime P8 — Rust Catalog Authority

Status: implemented (2026-08-30).

## Contract

`rust/crates/proto/catalog/mcp_catalog_v1.json` is the sole authored MCP/tool-catalog
record. It contains the ordered 27-tool schema, annotations, registration scope,
capability, admission class, operation policy/aliases, resource limits, and shared-read
projection marker. Records are validated at runtime and fingerprinted with a lowercase
SHA-256 digest.

`xtask mcp-catalog generate` emits the Swift `MCPDomainGeneratedToolDefinitions` artifact
and the readable review projection. `xtask mcp-catalog check` is deterministic and fails
when either artifact is stale. Swift does not retain a base64 schema or a hand-written
catalog table.

## Boundary

The FFI `CoreRuntime.mcpToolCatalogV1` export provides an immutable, identity-fenced
snapshot for diagnostics and cross-language parity. `AgentryCoreBridge.mcpToolCatalog()`
validates version, digest, ordering, names, and object schemas. The P9 runtime handoff
(`headless-mcp-domain-runtime-p9-catalog-handoff.md`) supersedes the P8 diagnostic-only
consumer boundary: production Domain registration and headless tools now consume the
verified runtime snapshot and fail closed when it is unavailable. Execution providers and
routing remain Swift-owned physical adapters.

## Compatibility

Tool names, order, schema bytes, annotations, enabled defaults, operation normalization,
aliases, admission classes, and registration scope behavior are unchanged from the
pre-handoff catalog. The readable JSON remains review-only and is never loaded as a
runtime resource. Legacy `MCPDomainCanonicalToolDefinitions.swift` and independent
Swift catalog entries are retired.
