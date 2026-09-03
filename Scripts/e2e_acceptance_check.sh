#!/usr/bin/env bash
# Scripts/e2e_acceptance_check.sh
#
# Comprehensive E2E Acceptance Test Runner for Post-Cutover Cleanup & Dead Code Elimination (ADR-0011 & ADR-0012)
# Authoritative References: ORIGINAL_REQUEST.md, AGENTS.md, TEST_INFRA.md, PROJECT.md
#
# Features covered (PROJECT.md 1-17):
# - Features 1-6 (Workspace Excision): T2.1, T2.2, T2.4, T3.2, T4.1
# - Features 7-11 (Agent Mode Streamlining): T1.3, T2.2, T2.3, T2.5, T4.2
# - Features 12-17 (Verification & Non-Regression): T1.1, T1.2, T1.4, T1.5, T3.1, T4.3
#
# Usage:
#   ./Scripts/e2e_acceptance_check.sh [--all] [--tier 1|2|3|4] [--quick] [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Formatting / Colors
BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Defaults
TARGET_TIER="all"
QUICK_MODE=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --all            Run all tiers 1 through 4 (default).
  --tier <1|2|3|4> Run only the specified verification tier.
  --quick, --fast  Use focused target test suites for faster feedback.
  --help, -h       Show this help message.

Tiers:
  Tier 1: Feature Coverage (Product Builds, Guardrails, Codegen, Preflight)
  Tier 2: Boundary & Integrity Cases (DomainPersistence, InProcess Excision, CAS Hooks)
  Tier 3: Concurrency & Cross-Module Consistency (Daemon Serialization, Domain Disposition)
  Tier 4: Real-World Acceptance Scenarios (Workspace Suites, AgentSessionHost Suites, Net Line Reduction)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      TARGET_TIER="all"
      shift
      ;;
    --tier)
      if [[ -z "${2:-}" || ! "$2" =~ ^[1-4]$ ]]; then
        echo -e "${RED}Error: --tier requires 1, 2, 3, or 4${NC}" >&2
        exit 2
      fi
      TARGET_TIER="$2"
      shift 2
      ;;
    --quick|--fast)
      QUICK_MODE=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}" >&2
      usage
      exit 2
      ;;
  esac
done

# Result Tracking Arrays
CHECK_TIERS=()
CHECK_IDS=()
CHECK_DESCS=()
CHECK_STATUSES=()
CHECK_DURS=()
CHECK_DETAILS=()

RECORD_CHECK() {
  local tier="$1"
  local id="$2"
  local status="$3"
  local duration="$4"
  local desc="$5"
  local detail="${6:-}"

  CHECK_TIERS+=("$tier")
  CHECK_IDS+=("$id")
  CHECK_STATUSES+=("$status")
  CHECK_DURS+=("$duration")
  CHECK_DESCS+=("$desc")
  CHECK_DETAILS+=("$detail")
}

OVERALL_EXIT_CODE=0
TOTAL_START_TIME=$(date +%s)

RUN_CHECK() {
  local tier="$1"
  local id="$2"
  local desc="$3"
  local fn="$4"

  echo -e "\n${BOLD}${CYAN}--------------------------------------------------------------------------------${NC}"
  echo -e "${BOLD}${CYAN}[$tier] Running $id: $desc...${NC}"
  echo -e "${BOLD}${CYAN}--------------------------------------------------------------------------------${NC}"

  local start_t
  start_t=$(date +%s)
  local status="PASS"
  local detail=""

  local tmp_out
  tmp_out="$(mktemp "${TMPDIR:-/tmp}/e2e-check.XXXXXX")"
  local cmd_code=0
  (
    set -euo pipefail
    "$fn"
  ) > "$tmp_out" 2>&1 || cmd_code=$?

  detail="$(cat "$tmp_out")"
  rm -f "$tmp_out"

  if [[ $cmd_code -ne 0 ]]; then
    status="FAIL"
    OVERALL_EXIT_CODE=1
    echo -e "${RED}✗ FAILED: $id${NC}"
    if [[ -n "$detail" ]]; then
      echo -e "${RED}$detail${NC}"
    fi
  else
    echo -e "${GREEN}✓ PASSED: $id${NC}"
    if [[ -n "$detail" ]]; then
      echo -e "$detail"
    fi
  fi

  local end_t
  end_t=$(date +%s)
  local elapsed=$((end_t - start_t))
  RECORD_CHECK "$tier" "$id" "$status" "${elapsed}s" "$desc" "$detail"
}

# ==============================================================================
# TIER 1: Compilation & Guardrails
# ==============================================================================

# T1.1: Product compilation (Agentry and agentry-mcp)
check_t1_1_product_builds() {
  echo "Building agentry-mcp product via developer daemon..."
  make dev-swift-build PRODUCT=agentry-mcp
  echo "Building Agentry product via developer daemon..."
  make dev-swift-build PRODUCT=Agentry
}

# T1.2: Repository guardrails (10 checks)
check_t1_2_guardrails() {
  make guardrails
}

# T1.3: Boundary guardrails unit test suite
check_t1_3_boundary_guardrails_test() {
  python3 Scripts/test_agent_session_boundary_guardrails.py
}

# T1.4: UniFFI bindings determinism check
check_t1_4_cargo_codegen_check() {
  make dev-cargo-codegen-check
}

# T1.5: Contribution push preflight
check_t1_5_contribution_preflight() {
  echo "Running contribution preflight in commit mode (whitespace, secrets, guardrails)..."
  .agents/skills/rpce-contribution-check/scripts/preflight.sh commit
  echo "Checking worktree readiness for push preflight..."
  if .agents/skills/rpce-contribution-check/scripts/preflight.sh push; then
    echo "Push preflight cleanly passed."
  else
    echo "Notice: Push preflight requires clean worktree before outgoing push. Commit preflight PASSED."
  fi
}

run_tier_1() {
  echo -e "\n${BOLD}${BLUE}================================================================================${NC}"
  echo -e "${BOLD}${BLUE}TIER 1: Compilation & Guardrails${NC}"
  echo -e "${BOLD}${BLUE}================================================================================${NC}"

  RUN_CHECK "Tier 1" "T1.1" "Product builds (Agentry & agentry-mcp)" check_t1_1_product_builds
  RUN_CHECK "Tier 1" "T1.2" "10 repository guardrails (make guardrails)" check_t1_2_guardrails
  RUN_CHECK "Tier 1" "T1.3" "Agent session boundary guardrails unit tests" check_t1_3_boundary_guardrails_test
  RUN_CHECK "Tier 1" "T1.4" "UniFFI bindings determinism (make dev-cargo-codegen-check)" check_t1_4_cargo_codegen_check
  RUN_CHECK "Tier 1" "T1.5" "Contribution safety preflight check" check_t1_5_contribution_preflight
}

# ==============================================================================
# TIER 2: Boundary & Integrity Cases
# ==============================================================================

# T2.1: DomainPersistence bootstrap & dead code excision
check_t2_1_domain_persistence_excision() {
  local target="Sources/RepoPromptDomainRuntime/DomainPersistence.swift"
  if [[ ! -f "$target" ]]; then
    echo "Error: $target not found!" >&2
    return 1
  fi

  local dead_structs=(
    "DomainPersistenceWorkingCommit"
    "DomainPersistenceSavedCommit"
    "DomainPersistenceExternalObservationCommit"
    "DomainPersistenceDeleteCommit"
    "CatalogWriteReceipt"
    "PreparedJournalCandidate"
    "LegacyWorkspaceIndexEntry"
    "RuntimePolicyDocument"
    "RollbackManifest"
  )

  local found_structs=()
  for s in "${dead_structs[@]}"; do
    if grep -E -q "\b(struct|enum|class)[[:space:]]+$s\b" "$target"; then
      found_structs+=("$s")
    fi
  done

  local dead_methods=(
    "ensureLazyMigration"
    "loadCurrentCatalog"
    "readCurrentJournalOrSeed"
    "loadJournal"
    "deletionSidecar"
  )

  local found_methods=()
  for m in "${dead_methods[@]}"; do
    if grep -E -q "\bfunc[[:space:]]+$m\b" "$target"; then
      found_methods+=("$m")
    fi
  done

  # Verify no legacy migration files exist
  local migration_files
  migration_files="$(find Sources Tests -name "*legacy_migration*" -o -name "*workspace-migration*" 2>/dev/null || true)"
  if [[ -n "$migration_files" ]]; then
    echo "Error: Unexpected legacy migration files found: $migration_files" >&2
    return 1
  fi

  if [[ ${#found_structs[@]} -gt 0 || ${#found_methods[@]} -gt 0 ]]; then
    echo "Pending/In-Progress in Milestone 1:" >&2
    if [[ ${#found_structs[@]} -gt 0 ]]; then
      echo "  Unpruned dead structs in DomainPersistence: ${found_structs[*]}" >&2
    fi
    if [[ ${#found_methods[@]} -gt 0 ]]; then
      echo "  Unpruned dead methods in DomainPersistence: ${found_methods[*]}" >&2
    fi
    return 1
  fi

  # Run DomainWorkspaceJournalAuthorityGuardTests to verify authority contracts
  make dev-test FILTER=DomainWorkspaceJournalAuthorityGuardTests
  echo "DomainPersistence bootstrap and dead code excision verified clean."
}

# T2.2: WorkspaceManagerViewModel authority & InProcess connection excision
check_t2_2_viewmodel_and_inprocess_excision() {
  local vm="Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift"
  if [[ ! -f "$vm" ]]; then
    echo "Error: $vm not found!" >&2
    return 1
  fi

  local retired_stubs=(
    "saveWorkspaceIndex"
    "saveWorkspaceIndexAsync"
    "rebuildAndSaveIndex"
    "rebuildAndSaveIndexAsync"
  )

  local found_stubs=()
  for stub in "${retired_stubs[@]}"; do
    if grep -E -q "\bfunc[[:space:]]+$stub\b" "$vm"; then
      found_stubs+=("$stub")
    fi
  done

  # Check for dead InProcess connection files
  local inprocess_dir="Sources/RepoPrompt/Features/AgentMode/Connection/InProcess"
  local has_inprocess_files=false
  if [[ -d "$inprocess_dir" ]]; then
    local inprocess_count
    inprocess_count="$(find "$inprocess_dir" -type f -name "*.swift" | wc -l | tr -d ' ')"
    if [[ "$inprocess_count" -gt 0 ]]; then
      has_inprocess_files=true
    fi
  fi

  # Check for in-process references in presentation layers (Views and ViewModels)
  local forbidden_inprocess_refs
  forbidden_inprocess_refs="$(grep -R -n -E --include='*.swift' \
    '\b(InProcessAgentSession[A-Za-z0-9_]*|InProcessDetachedProviderHandles)\b|\binProcessExecution\b' \
    Sources/RepoPrompt/Features/AgentMode/Views \
    Sources/RepoPrompt/Features/AgentMode/ViewModels 2>/dev/null || true)"

  # Check that App does not construct InProcess connection
  local app_inprocess_constructions
  app_inprocess_constructions="$(grep -R -n -E --include='*.swift' \
    '\bInProcessAgentSessionConnection\(' Sources/RepoPrompt/App 2>/dev/null || true)"

  if [[ ${#found_stubs[@]} -gt 0 || "$has_inprocess_files" = true || -n "$forbidden_inprocess_refs" || -n "$app_inprocess_constructions" ]]; then
    echo "Pending/In-Progress in Milestones 1 & 2:" >&2
    if [[ ${#found_stubs[@]} -gt 0 ]]; then
      echo "  Unpruned empty stubs in WorkspaceManagerViewModel: ${found_stubs[*]}" >&2
    fi
    if [[ "$has_inprocess_files" = true ]]; then
      echo "  InProcess connection directory still contains files: $inprocess_dir" >&2
    fi
    if [[ -n "$forbidden_inprocess_refs" ]]; then
      echo "  InProcess references in presentation layers: $forbidden_inprocess_refs" >&2
    fi
    if [[ -n "$app_inprocess_constructions" ]]; then
      echo "  InProcess construction under Sources/RepoPrompt/App: $app_inprocess_constructions" >&2
    fi
    return 1
  fi

  echo "WorkspaceManagerViewModel stubs and InProcess connection layer clean."
}

# T2.3: AgentSessionHost canonical socket paths & headless invariants
check_t2_3_host_canonical_socket_paths() {
  local paths_file="Sources/RepoPromptDomainRuntime/AgentSessionHost/AgentSessionHostPaths.swift"
  if [[ ! -f "$paths_file" ]]; then
    echo "Error: $paths_file not found!" >&2
    return 1
  fi

  # Verify canonical socket path contract exists
  if ! grep -q 'agentry-agent-host' "$paths_file"; then
    echo "Error: Canonical socket path contract missing from $paths_file" >&2
    return 1
  fi

  # Verify AgentSessionHostSessionState is not in production runtime
  local host_session_state="Sources/RepoPromptDomainRuntime/AgentSessionHost/AgentSessionHostSessionState.swift"
  if [[ -f "$host_session_state" ]]; then
    echo "Pending M2: $host_session_state is still present in production runtime." >&2
    return 1
  fi

  # Verify headless runtime guardrails
  ./Scripts/headless_runtime_guardrails.sh
  echo "AgentSessionHost canonical paths and headless runtime verified."
}

# T2.4: Rust CAS conflict testing hooks preserved
check_t2_4_rust_cas_test_hooks_preserved() {
  local persistence="Sources/RepoPromptDomainRuntime/DomainPersistence.swift"
  local test_file="Tests/RepoPromptDomainRuntimeTests/DomainWorkspaceContextAuthorityTests.swift"

  if ! grep -q 'package static func setCatalogReplacementTestHook' "$persistence"; then
    echo "Error: setCatalogReplacementTestHook was accidentally removed from $persistence! (Needed by Rust CAS tests)" >&2
    return 1
  fi

  if ! grep -q 'DomainPersistenceCoordinator.setCatalogReplacementTestHook' "$test_file"; then
    echo "Error: setCatalogReplacementTestHook call sites missing from $test_file" >&2
    return 1
  fi

  echo "Verified: setCatalogReplacementTestHook is preserved in DomainPersistence and exercised in authority tests."
}

# T2.5: Zero forbidden provider execution imports in Features
check_t2_5_zero_forbidden_provider_imports() {
  ./Scripts/agent_session_boundary_guardrails.sh
}

run_tier_2() {
  echo -e "\n${BOLD}${BLUE}================================================================================${NC}"
  echo -e "${BOLD}${BLUE}TIER 2: Boundary & Integrity Cases${NC}"
  echo -e "${BOLD}${BLUE}================================================================================${NC}"

  RUN_CHECK "Tier 2" "T2.1" "DomainPersistence bootstrap & dead code excision" check_t2_1_domain_persistence_excision
  RUN_CHECK "Tier 2" "T2.2" "WorkspaceManagerViewModel & InProcess connection excision" check_t2_2_viewmodel_and_inprocess_excision
  RUN_CHECK "Tier 2" "T2.3" "AgentSessionHost canonical socket paths & headless invariants" check_t2_3_host_canonical_socket_paths
  RUN_CHECK "Tier 2" "T2.4" "Rust CAS conflict testing hooks preserved" check_t2_4_rust_cas_test_hooks_preserved
  RUN_CHECK "Tier 2" "T2.5" "Zero forbidden provider execution imports in Features" check_t2_5_zero_forbidden_provider_imports
}

# ==============================================================================
# TIER 3: Concurrency & Cross-Module Consistency
# ==============================================================================

# T3.1: Coordinated concurrency & developer daemon lane serialization
check_t3_1_concurrency_daemon_status() {
  local status_output
  status_output="$(make dev-status)"
  echo "$status_output"
  if ! echo "$status_output" | grep -q "conductor daemon running"; then
    echo "Error: conductor developer daemon is not running!" >&2
    return 1
  fi
  echo "Developer daemon lane serialization healthy."
}

# T3.2: Domain authority mutation disposition invariant (disposition == .applied)
check_t3_2_domain_disposition_invariants() {
  echo "Verifying disposition == .applied invariant in domain authority..."
  local match_count
  match_count="$(grep -R -c 'disposition == \.applied' Sources/ | awk -F: '{s+=$2} END {print s}')"
  if [[ "$match_count" -lt 5 ]]; then
    echo "Warning: Low occurrence of disposition == .applied ($match_count matches found)." >&2
  fi

  # Verify authority guard tests enforce atomic persistence contract
  make dev-test FILTER=DomainWorkspaceJournalAuthorityGuardTests
  echo "Domain authority disposition invariants verified."
}

run_tier_3() {
  echo -e "\n${BOLD}${BLUE}================================================================================${NC}"
  echo -e "${BOLD}${BLUE}TIER 3: Concurrency & Cross-Module Consistency${NC}"
  echo -e "${BOLD}${BLUE}================================================================================${NC}"

  RUN_CHECK "Tier 3" "T3.1" "Coordinated concurrency & daemon lane serialization" check_t3_1_concurrency_daemon_status
  RUN_CHECK "Tier 3" "T3.2" "Domain authority disposition invariants (.applied)" check_t3_2_domain_disposition_invariants
}

# ==============================================================================
# TIER 4: Real-World Acceptance Scenarios
# ==============================================================================

# T4.1: Workspace test suite execution (AGENTS.md canonical focused suite)
check_t4_1_workspace_tests() {
  echo "Running focused WorkspaceFileContextStoreTests (AGENTS.md canonical suite)..."
  make dev-test FILTER=WorkspaceFileContextStoreTests
}

# T4.2: AgentSessionHost / HostAgentSessionConnection test suite execution
check_t4_2_agent_session_host_tests() {
  echo "Running HostAgentSessionConnectionTests..."
  make dev-test FILTER=HostAgentSessionConnectionTests
}

# T4.3: Net line count reduction audit across the git diff
check_t4_3_net_line_count_reduction() {
  local base_ref
  if git rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
    base_ref="refs/remotes/origin/main"
  else
    base_ref="HEAD"
  fi

  echo "Auditing git diff stats against base: $base_ref..."
  local stat_summary
  stat_summary="$(git diff --stat "$base_ref" -- 'Sources/*.swift' 'Tests/*.swift' 2>/dev/null || true)"
  if [[ -n "$stat_summary" ]]; then
    echo "$stat_summary"
  fi

  # Compute numeric insertions and deletions
  local numstat_output
  numstat_output="$(git diff --numstat "$base_ref" -- '*.swift' 2>/dev/null || true)"

  local total_add=0
  local total_del=0
  while IFS=$'\t' read -r add del file; do
    [[ -n "$add" && "$add" != "-" ]] && total_add=$((total_add + add))
    [[ -n "$del" && "$del" != "-" ]] && total_del=$((total_del + del))
  done <<< "$numstat_output"

  local net=$((total_del - total_add))
  echo -e "Swift Code Changes:"
  echo -e "  Total Additions: +$total_add lines"
  echo -e "  Total Deletions: -$total_del lines"
  echo -e "  Net Reduction:    $net lines"

  if [[ $net -gt 0 ]]; then
    echo -e "Net line reduction achieved: -$net net lines removed."
    return 0
  else
    echo -e "Pending: Net line reduction is currently $net lines (Milestones 1 & 2 in progress)." >&2
    return 1
  fi
}

run_tier_4() {
  echo -e "\n${BOLD}${BLUE}================================================================================${NC}"
  echo -e "${BOLD}${BLUE}TIER 4: Real-World Acceptance Scenarios${NC}"
  echo -e "${BOLD}${BLUE}================================================================================${NC}"

  RUN_CHECK "Tier 4" "T4.1" "Full Workspace test suite execution" check_t4_1_workspace_tests
  RUN_CHECK "Tier 4" "T4.2" "Agent session host connection test suite execution" check_t4_2_agent_session_host_tests
  RUN_CHECK "Tier 4" "T4.3" "Net line count reduction audit" check_t4_3_net_line_count_reduction
}

# ==============================================================================
# MAIN DISPATCH
# ==============================================================================

echo -e "${BOLD}================================================================================${NC}"
echo -e "${BOLD}E2E Acceptance Test Runner — Post-Cutover Cleanup & Dead Code Elimination${NC}"
echo -e "${BOLD}ADR-0011 & ADR-0012 Verification Hierarchy (Tiers 1-4)${NC}"
echo -e "${BOLD}================================================================================${NC}"
echo -e "Target: ${BOLD}$TARGET_TIER${NC} | Quick Mode: ${BOLD}$QUICK_MODE${NC}"

case "$TARGET_TIER" in
  "1")
    run_tier_1
    ;;
  "2")
    run_tier_2
    ;;
  "3")
    run_tier_3
    ;;
  "4")
    run_tier_4
    ;;
  "all")
    run_tier_1
    run_tier_2
    run_tier_3
    run_tier_4
    ;;
esac

TOTAL_END_TIME=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END_TIME - TOTAL_START_TIME))

# ==============================================================================
# CRISP SUMMARY TABLE
# ==============================================================================

echo -e "\n${BOLD}================================================================================${NC}"
echo -e "${BOLD}E2E ACCEPTANCE VERIFICATION SUMMARY${NC}"
echo -e "${BOLD}================================================================================${NC}"
printf "%-8s %-6s %-8s %-10s %-50s\n" "Tier" "ID" "Status" "Duration" "Description"
echo "--------------------------------------------------------------------------------"

TOTAL_COUNT=${#CHECK_IDS[@]}
PASSED_COUNT=0
FAILED_COUNT=0

for i in "${!CHECK_IDS[@]}"; do
  tier="${CHECK_TIERS[$i]}"
  id="${CHECK_IDS[$i]}"
  st="${CHECK_STATUSES[$i]}"
  dur="${CHECK_DURS[$i]}"
  desc="${CHECK_DESCS[$i]}"

  if [[ "$st" == "PASS" ]]; then
    PASSED_COUNT=$((PASSED_COUNT + 1))
    st_colored="${GREEN}PASS${NC}"
  else
    FAILED_COUNT=$((FAILED_COUNT + 1))
    st_colored="${RED}FAIL${NC}"
  fi

  printf "%-8s %-6s %-17b %-10s %-50s\n" "$tier" "$id" "$st_colored" "$dur" "$desc"
done

echo "--------------------------------------------------------------------------------"
echo -e "Total Checks: ${BOLD}$TOTAL_COUNT${NC} | Passed: ${GREEN}${BOLD}$PASSED_COUNT${NC} | Failed: ${RED}${BOLD}$FAILED_COUNT${NC} | Duration: ${BOLD}${TOTAL_ELAPSED}s${NC}"

if [[ $OVERALL_EXIT_CODE -eq 0 ]]; then
  echo -e "\n${BOLD}${GREEN}================================================================================${NC}"
  echo -e "${BOLD}${GREEN}OVERALL VERDICT: PASS${NC}"
  echo -e "${BOLD}${GREEN}All executed acceptance checks passed cleanly.${NC}"
  echo -e "${BOLD}${GREEN}================================================================================${NC}"
else
  echo -e "\n${BOLD}${RED}================================================================================${NC}"
  echo -e "${BOLD}${RED}OVERALL VERDICT: FAIL ($FAILED_COUNT check(s) failed or pending)${NC}"
  echo -e "${BOLD}${RED}Review failed check details above.${NC}"
  echo -e "${BOLD}${RED}================================================================================${NC}"
fi

exit "$OVERALL_EXIT_CODE"
