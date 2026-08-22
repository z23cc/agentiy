#!/usr/bin/env python3
"""Fail when active Agentry surfaces reintroduce the retired product identity."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SELF_PATH = Path(__file__).resolve().relative_to(ROOT).as_posix()
ACTIVE_ROOTS = (
    "Sources/",
    "rust/",
    "AppBundle/",
    "Scripts/",
    ".github/workflows/",
    ".agents/skills/",
    "docs/architecture/",
)
ACTIVE_FILES = {
    "README.md",
    "CLAUDE.md",
    "AGENTS.md",
    "docs/releasing.md",
    "docs/testing.md",
}
FORBIDDEN = (
    "RepoPrompt CE",
    "com.pvncher.repoprompt",
    "rpce-cli-debug",
    "repoprompt_ce_cli_debug",
    "repoprompt-mcp",
    "Application Support/RepoPrompt CE",
    "REPOPROMPT_MCP_HEADLESS_PROFILE",
    "REPOPROMPT_MCP_WORKING_DIRS",
)

# These are evidence that Agentry does not adopt or manage the retired lineage.
LEGACY_PROOF_LINES = {
    "Scripts/load_release_metadata.sh": (
        "legacy RepoPrompt CE feed",
        "legacy RepoPrompt CE signing key",
    ),
    "Sources/RepoPrompt/Infrastructure/AI/Providers/OpenCode/OpenCodeIntegrationConfiguration.swift": (
        'let generatedNames: Set = ["repoprompt_cli", "repoprompt_cli_debug", "repoprompt-mcp"]',
    ),
    "Sources/RepoPrompt/Infrastructure/Security/KeychainService.swift": (
        'static let legacyCanonicalServiceName = "com.pvncher.repoprompt.ce.keychain"',
        'static let officialV2ServiceName = "com.pvncher.repoprompt.ce.developer-id.keychain.v2"',
        'static let localSelfSignedServiceNamePrefix = "com.pvncher.repoprompt.ce.local-self-signed."',
        'static let debugServiceName = "com.pvncher.repoprompt.ce.debug.keychain"',
    ),
    "Tests/RepoPromptTests/MCP/DirectHeadlessRuntimeConfigurationTests.swift": (
        '"REPOPROMPT_MCP_HEADLESS_PROFILE": "legacy-profile"',
        '"REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": legacyProfile.path',
        '"REPOPROMPT_MCP_WORKING_DIRS": legacyRoot.path',
    ),
    # ADR-0002 narrates the identity-reset ruling itself and must name the
    # retired identity it replaced; this is historical evidence, not a live
    # surface reintroducing it.
    "docs/architecture/adr-0002-hard-fork-baseline-identity-reset.md": (
        "identity guard sweep including upstream's original `com.pvncher.repoprompt` namespace",
        "no import or migration of the old `RepoPrompt CE` root",
        "No first-run migration path exists from the old `RepoPrompt CE` install",
    ),
    # docs/architecture/agentry-rewrite-charter.md is a frozen, version-controlled
    # snapshot of the pre-rename design narrative (ADR ruling 14). It must name the
    # retired identity to be a faithful historical record; these five lines are the
    # full, exhaustive set of forbidden-token occurrences in the snapshot as of the
    # ADR ruling 14 commit and are read as history, not as a live/prescriptive
    # surface reintroducing the retired identity.
    "docs/architecture/agentry-rewrite-charter.md": (
        "RepoPrompt CE 的正式 hard fork",
        "本文回答：如果长期将 RepoPrompt CE 演进为",
        "上游原始命名空间 `com.pvncher.repoprompt` 全量",
        "不读取、不迁移旧 `RepoPrompt CE` 目录",
        "CLI 与 MCP 服务名：`rpce-cli-debug` → `agentry-cli-debug`",
    ),
}
HISTORICAL_CHANGELOG = "Sources/RepoPrompt/App/Changelog.swift"
HISTORICAL_CHANGELOG_LINE = (
    'Text("RepoPrompt CE makes the core feature set available without paid license gates:")'
)


def tracked_files() -> list[str]:
    output = subprocess.check_output(
        ["git", "ls-files", "-z"], cwd=ROOT
    ).decode("utf-8", errors="surrogateescape")
    return [path for path in output.split("\0") if path]


def is_active(path: str) -> bool:
    if path == SELF_PATH:
        return False
    if path in ACTIVE_FILES or any(path.startswith(root) for root in ACTIVE_ROOTS):
        if path.startswith("Scripts/test_") or path.startswith("Scripts/Fixtures/item0_"):
            return False
        if path.startswith(("docs/investigations/", "docs/migrations/", "docs/plans/")):
            return False
        return True
    return False


def allowed(path: str, line: str, token: str) -> bool:
    if path == HISTORICAL_CHANGELOG:
        return token == "RepoPrompt CE" and line.strip() == HISTORICAL_CHANGELOG_LINE
    if any(marker in line for marker in LEGACY_PROOF_LINES.get(path, ())):
        return True
    # Internal Swift module/target names (RepoPromptApp, RepoPromptMCP, etc.) and
    # the GitHub repository slug repoprompt/repoprompt-ce are intentionally not
    # forbidden tokens. They therefore need no broad path exemption here.
    return False


def main() -> int:
    failures: list[str] = []
    for relative in tracked_files():
        if not is_active(relative):
            continue
        path = ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for line_number, line in enumerate(text.splitlines(), 1):
            for token in FORBIDDEN:
                if token in line and not allowed(relative, line, token):
                    failures.append(f"{relative}:{line_number}: forbidden active identity {token!r}")
    if failures:
        print("Agentry identity guardrail failed:", file=sys.stderr)
        print("\n".join(f"  {failure}" for failure in failures), file=sys.stderr)
        return 1
    print("Agentry identity guardrail passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
