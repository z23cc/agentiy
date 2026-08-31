#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

runtime_sources="Sources/RepoPromptDomainRuntime"
direct_sources="Sources/RepoPromptMCP"

if grep -R -n -E '^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI)([[:space:]]|$)' "$runtime_sources"; then
  echo "error: RepoPromptDomainRuntime must remain independent of AppKit and SwiftUI" >&2
  exit 1
fi

for forbidden in \
  MCPFoundationStandaloneBackend \
  MCPDomainCanonicalToolManifest \
  RECORD_MCP_WINDOW_TOOL_CATALOG \
  MCPServerViewModel; do
  if grep -R -n --include='*.swift' --include='*.json' "$forbidden" "$runtime_sources" "$direct_sources"; then
    echo "error: forbidden duplicate or app-owned headless authority: $forbidden" >&2
    exit 1
  fi
done

for retired in \
  ServiceRegistry \
  MCPWindowToolRuntime \
  MCPWindowToolDependencies \
  MCPWindowToolContext \
  MCPWindowToolCatalogService \
  MCPWindowToolGroup \
  MCPAppToolDependencies \
  sharedBindingRuntime \
  appAdapterTools \
  activeTabCompatibility \
  PresentationActiveContextFallback \
  usesPresentationActiveContext \
  allowLegacyImplicitRouting \
  shouldUseGenericTabBindingCompatibility \
  TabScopedContext \
  DomainProtectedMutationStage \
  migratedToolNames; do
  if grep -R -n --include='*.swift' "$retired" Sources; then
    echo "error: retired M7 migration authority remains in production sources: $retired" >&2
    exit 1
  fi
done

if grep -R -n --include='*.swift' -E '@MainActor|^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI|Combine)([[:space:]]|$)' "$runtime_sources"; then
  echo "error: RepoPromptDomainRuntime must have zero domain-owned MainActor or UI dependencies" >&2
  exit 1
fi

generated_catalog="$runtime_sources/MCPDomainGeneratedToolDefinitions.swift"
rust_catalog="rust/crates/proto/catalog/mcp_catalog_v1.json"
if [[ ! -f "$generated_catalog" || ! -f "$rust_catalog" ]]; then
  echo "error: missing generated Rust-owned MCP catalog projection" >&2
  exit 1
fi
if [[ -f "$runtime_sources/MCPDomainCanonicalToolDefinitions.swift" ]] \
  || grep -R -n --include='*.swift' -E 'Data\(base64Encoded|MCPDomainCanonicalToolDefinitions' "$runtime_sources" "$direct_sources"; then
  echo "error: retired Swift MCP catalog authority remains in headless sources" >&2
  exit 1
fi
if ! grep -q 'catalogProvider' "$direct_sources/DirectHeadlessMCPService.swift" \
  || ! grep -q 'prepared.catalog' "$direct_sources/DirectHeadlessMCPService.swift" \
  || grep -q 'MCPDomainGeneratedToolDefinitions' "$direct_sources/DirectHeadlessMCPService.swift"; then
  echo "error: headless backend must consume the verified runtime MCP catalog handoff" >&2
  exit 1
fi

if ! grep -q 'domainHost.installCatalog' "$runtime_sources/RepoPromptDomainRuntime.swift" \
  || ! grep -q 'makeResourceAdmissionControllers' "$runtime_sources/MCPDomainHost.swift" \
  || ! grep -q 'case repository' "$runtime_sources/MCPDomainHost.swift" \
  || ! grep -q 'runtimeCatalog' "$runtime_sources/MCPDomainHost.swift" \
  || ! grep -q 'canonicalDefinitionMismatch' "$runtime_sources/MCPDomainToolRegistry.swift" \
  || ! grep -q 'canonicalJSONData' Sources/AgentryCoreBridge/MCPToolCatalogBridge.swift; then
  echo "error: MCP domain admission must install and consume one verified catalog snapshot" >&2
  exit 1
fi

if ! grep -q 'rustOperationIdentity' Sources/RepoPrompt/Infrastructure/MCP/Policies/MCPToolAdmissionPolicy.swift \
  || ! grep -q 'coreMcpToolOperationIdentity' Sources/RepoPromptDomainRuntime/AgentryCoreService.swift \
  || ! grep -q 'static var smallReadCallLaneLimit' Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift; then
  echo "error: production MCP diagnostics must use the Rust catalog operation resolver and dynamic limits" >&2
  exit 1
fi

if ! grep -q 'operationResolver' "$runtime_sources/MCPDomainHost.swift" \
  || ! grep -q 'operationResolver' Sources/RepoPromptDomainRuntime/RepoPromptDomainRuntime.swift \
  || ! grep -q 'operationResolver' Sources/RepoPrompt/App/AppDomainRuntimeComposition.swift \
  || ! grep -q 'resolveOperation' "$runtime_sources/MCPDomainHost.swift" \
  || ! grep -q 'pendingInvocationIDs' "$runtime_sources/MCPDomainHost.swift" \
  || ! grep -q 'validateOperation' "$direct_sources/DirectHeadlessMCPService.swift" \
  || grep -q 'supportedOperations' "$direct_sources/DirectHeadlessMCPService.swift" \
  || grep -q 'MCPDomainToolCatalog.entry' Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift; then
  echo "error: production MCP execution must use host-owned Rust operation and catalog handoff" >&2
  exit 1
fi

if find "$runtime_sources" "$direct_sources" -type f \( -iname '*tool*manifest*.json' -o -iname '*schema*manifest*.json' \) -print -quit | grep -q .; then
  echo "error: headless canonical schemas must not be copied into a resource manifest" >&2
  exit 1
fi

if ! grep -q 'MCPStdioServerTransport' "$direct_sources/DirectHeadlessMCPService.swift"; then
  echo "error: headless backend must use its terminal-aware bounded stdio transport" >&2
  exit 1
fi

if grep -E -q '(^|[^[:alnum:]_])StdioTransport\(' "$direct_sources/DirectHeadlessMCPService.swift"; then
  echo "error: headless backend must not install the SDK stdio dispatcher" >&2
  exit 1
fi

m6b_contract="Scripts/Fixtures/headless_mcp_domain_runtime_m6b_contract.json"
if [[ ! -f "$m6b_contract" ]] || ! python3 - "$m6b_contract" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
assert value["schema_version"] == 1
assert value["milestone"] == "M6B"
assert value["authority"]["production"] == "DomainChildLaunchAuthority"
assert value["authority"]["routing_token_owner"] == "DomainRoutingCoordinator"
assert value["authority"]["credential_binding"] == "run_id_provider_purpose_exact"
assert value["endpoint"]["identity"] == "device_inode_fenced"
assert value["endpoint"]["cleanup"] == "bounded_identity_fenced_idempotent"
assert value["token"]["format"] == "nonempty_control_free"
assert value["token"]["run_fence"] == "run_id_checked_before_consumption"
assert value["token"]["replay"] == "bounded_consumed_revoked_expired_tombstones"
assert value["lifecycle"]["admission"] == "token_and_endpoint_identity_before_mcp_handler"
assert value["carrier"]["inherited_values"] == "all_stripped_before_current_task_local_merge"
assert len(value["carrier"]["environment_keys"]) == 7
assert value["compatibility"]["mcp_wire_schema_changed"] is False
PY
then
  echo "error: M6B private child endpoint contract fixture drifted or is invalid JSON" >&2
  exit 1
fi

if ! grep -q 'package actor DomainChildLaunchAuthority' "$runtime_sources/DomainCredentialEnvelope.swift" \
  || ! grep -q 'DomainChildLaunchAuthority(' "$direct_sources/DirectHeadlessChildEndpoint.swift" \
  || grep -q 'DomainPrivateChildLaunchHarness(' "$direct_sources/DirectHeadlessChildEndpoint.swift"; then
  echo "error: production child launch must use the explicit DomainChildLaunchAuthority" >&2
  exit 1
fi

for carrier_key in \
  endpointEnvironmentKey endpointIdentityEnvironmentKey launchTokenEnvironmentKey \
  credentialEnvelopeEnvironmentKey clientPrincipalEnvironmentKey \
  providerIdentifierEnvironmentKey runIDEnvironmentKey; do
  if ! grep -q "$carrier_key" "$runtime_sources/DomainCredentialEnvelope.swift" \
    || ! grep -q 'environmentKeys' "$direct_sources/DirectHeadlessCapabilityBackends.swift" \
    || ! grep -q 'environmentKeys' Sources/RepoPrompt/Infrastructure/AI/Agents/DomainChildLaunchEnvironmentBridge.swift; then
    echo "error: private child carrier key set is not single-sourced across launch boundaries" >&2
    exit 1
  fi
done

canonical_workspace_service="$runtime_sources/MCPDomainCanonicalWorkspaceService.swift"
direct_workspace_adapter="$direct_sources/DirectHeadlessWorkspaceBackends.swift"
if [[ ! -f "$canonical_workspace_service" ]] \
  || ! grep -q 'MCPDomainCanonicalWorkspaceService' "$direct_workspace_adapter"; then
  echo "error: direct workspace tools must adapt the canonical domain workspace service" >&2
  exit 1
fi

if grep -E -n 'String\(contentsOf|FileManager\.default\.enumerator|NSRegularExpression' "$direct_workspace_adapter"; then
  echo "error: direct workspace adapter must not duplicate canonical read/search/tree implementations" >&2
  exit 1
fi

capability_adapters="Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAppPhysicalCapabilityAdapters.swift"
for family in Execution Context Selection Files Prompt; do
  if ! grep -q "struct $family" "$capability_adapters"; then
    echo "error: missing typed app physical capability family: $family" >&2
    exit 1
  fi
done

if grep -q '@dynamicMemberLookup' "$capability_adapters"; then
  echo "error: physical capability families must not expose dynamic-member forwarding" >&2
  exit 1
fi

if grep -R -n --include='MCP*ToolProvider.swift' \
  -E 'dependencies:[[:space:]]+MCPAppPhysicalCapabilityAdapters([[:space:],?)]|$)' \
  Sources/RepoPrompt/Infrastructure/MCP/WindowTools; then
  echo "error: providers must receive only explicit physical capability families" >&2
  exit 1
fi

if grep -E -q 'stored_(dependency|family)_(count|families)' Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json; then
  echo "error: the retired flat closure dependency bag contract must not return" >&2
  exit 1
fi

if ! grep -q 'MCPDomainReadToolProvider' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift"; then
  echo "error: standalone composition must reuse the canonical read provider" >&2
  exit 1
fi

if ! grep -q 'protectedMutationProvider.protectedBinding' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift" \
  || ! grep -q 'longRunningToolProvider.wrapping' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift"; then
  echo "error: standalone bindings must install both security decorators" >&2
  exit 1
fi

echo "Headless runtime guardrails passed."
