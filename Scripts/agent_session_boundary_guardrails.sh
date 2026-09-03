#!/usr/bin/env bash
# Agent session boundary guardrails (ADR-0011, design §6 / §9).
#
# Agent Mode presentation code (`Features/AgentMode/{Views,ViewModels}`) may talk to
# execution only through `AgentSessionConnection`. It must not name provider execution
# types, socket/transport details, host protocol types, or the concrete in-process
# connection implementation. Only the composition root under `Sources/RepoPrompt/App`
# may construct a concrete connection.
#
# Usage: Scripts/agent_session_boundary_guardrails.sh [repo-root]
set -euo pipefail

if [[ $# -gt 0 ]]; then
  ROOT_DIR="$(cd "$1" && pwd)"
else
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
cd "$ROOT_DIR"

agent_mode_root="Sources/RepoPrompt/Features/AgentMode"
presentation_dirs=(
  "$agent_mode_root/Views"
  "$agent_mode_root/ViewModels"
)
composition_root="Sources/RepoPrompt/App"
connection_root="$agent_mode_root/Connection"
tab_session="$agent_mode_root/ViewModels/AgentTabSession.swift"
mcp_sources="Sources/RepoPromptMCP"

failures=0

fail() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}

existing_presentation_dirs=()
for dir in "${presentation_dirs[@]}"; do
  if [[ -d "$dir" ]]; then
    existing_presentation_dirs+=("$dir")
  fi
done
if [[ ${#existing_presentation_dirs[@]} -eq 0 ]]; then
  echo "error: no Agent Mode presentation directories found under $agent_mode_root" >&2
  exit 1
fi

# Reports every presentation-layer line matching an extended regex.
presentation_violations() {
  grep -R -n -E --include='*.swift' -e "$1" "${existing_presentation_dirs[@]}" || true
}

check_presentation_forbidden() {
  local label="$1"
  local pattern="$2"
  local matches
  matches="$(presentation_violations "$pattern")"
  if [[ -n "$matches" ]]; then
    echo "$matches"
    fail "Agent Mode views/view models must not reference $label (route through AgentSessionConnection)"
  fi
}

# 1. Provider execution types (design §6 boundary invariant).
check_presentation_forbidden "provider execution types" \
  '\b(ClaudeRustBackedNativeSessionAdapter|CodexAppServerClient|ACPAgentSessionController|CoreAgentSession|CoreAgentProviderSession|CoreAgentProviderRuntimeTransport)\b'

# 2. Socket paths and transport primitives (design §5 belongs to the connection).
check_presentation_forbidden "socket paths or transport primitives" \
  '(\.sock\b|agentry-agent-host|\bsocketPath\b|\bAF_UNIX\b|\bSOCK_STREAM\b|\bsockaddr_un\b|[Uu]nix[ -]?[Dd]omain[ -]?[Ss]ocket|\bNWConnection\b|\bMCPFilesystemIdentity\b)'

# 3. Host protocol types (design §5 wire vocabulary is connection-internal).
check_presentation_forbidden "host protocol types" \
  '\b(HostAgentSessionConnection|AgentSessionHost[A-Za-z0-9_]*|agent_host_v1|AgentHostFrame[A-Za-z0-9_]*|AgentHostHello[A-Za-z0-9_]*)\b'

# 4. Concrete connection implementation and in-process execution state. Only the
#    composition root knows the concrete type; execution state is owned by the connection.
check_presentation_forbidden "the concrete in-process connection or its execution state" \
  '\b(InProcessAgentSession[A-Za-z0-9_]*|InProcessDetachedProviderHandles)\b|\binProcessExecution\b'

# 5. Provider controller handles must not be read off sessions by presentation code.
check_presentation_forbidden "provider controller handles" \
  '\.(codexController|claudeController|acpController)\b'

# 6. AgentTabSession is a presentation cache: no stored provider controller properties.
if [[ -f "$tab_session" ]]; then
  if grep -n -E '^[[:space:]]*(var|let)[[:space:]]+(codexController|claudeController|acpController|provider)[[:space:]]*[:=]' "$tab_session"; then
    fail "AgentTabSession must not store provider controllers (execution state lives behind AgentSessionConnection)"
  fi
else
  fail "missing $tab_session"
fi

# 7. Concrete connection construction is confined: Host under App; InProcess is tests-only
#    (Connection folder may name the type; App must not construct InProcess after P3).
host_constructions="$(grep -R -n -E --include='*.swift' \
  '\bHostAgentSessionConnection\(' Sources \
  | grep -v -E "^$composition_root/" \
  | grep -v -E "^$connection_root/" || true)"
if [[ -n "$host_constructions" ]]; then
  echo "$host_constructions"
  fail "HostAgentSessionConnection may only be constructed under $composition_root"
fi
inprocess_constructions="$(grep -R -n -E --include='*.swift' \
  '\bInProcessAgentSessionConnection\(' Sources \
  | grep -v -E "^$connection_root/" || true)"
if [[ -n "$inprocess_constructions" ]]; then
  echo "$inprocess_constructions"
  fail "InProcessAgentSessionConnection is tests-only; construct HostAgentSessionConnection under $composition_root"
fi

# 8. The seam must exist where the design places it.
seam_file="$connection_root/AgentSessionConnection.swift"
if [[ ! -f "$seam_file" ]]; then
  fail "missing client seam $seam_file"
elif ! grep -q -E '^[[:space:]]*protocol[[:space:]]+AgentSessionConnection[[:space:]]*:[[:space:]]*Actor' "$seam_file"; then
  fail "$seam_file must declare 'protocol AgentSessionConnection: Actor'"
fi

# 10. Execution commands enter the in-process stack only through the seam executor (P1.5).
#     Presentation may still construct the run service (its hooks are presentation callbacks)
#     but must not start/cancel runs or answer approvals on it or the coordinators directly.
check_presentation_forbidden "execution commands on the run service or coordinators (start/cancel/approval)" \
  '\brunService\.(startRun|cancelRun)\(|\b(codexCoordinator|claudeCoordinator)\.submitApprovalDecision\('

# 9. The future host lives in RepoPromptMCP; it must remain AppKit/SwiftUI free (design §9).
if [[ -d "$mcp_sources" ]]; then
  if grep -R -n -E --include='*.swift' '^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI)([[:space:]]|$)' "$mcp_sources"; then
    fail "$mcp_sources must remain independent of AppKit and SwiftUI"
  fi
fi

if [[ $failures -gt 0 ]]; then
  echo "Agent session boundary guardrails failed ($failures finding(s))." >&2
  exit 1
fi

echo "Agent session boundary guardrails passed."
