#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 ./Scripts/agentry_identity_guardrails.py
python3 ./Scripts/rust_ffi_guardrails.py
./Scripts/source_layout_guardrails.sh
./Scripts/contributor_allowlist_guardrails.sh
./Scripts/swiftpm_notice_guardrails.sh
./Scripts/codex_vendor_guardrails.sh
./Scripts/headless_runtime_guardrails.sh
./Scripts/agent_session_boundary_guardrails.sh
python3 ./Scripts/validate_rust_agent_provider_p7_4.py --check
