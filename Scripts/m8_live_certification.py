#!/usr/bin/env python3
"""Run the M8 live-certification gates and write a redacted, commit-bound receipt.

The runner never places credential material, paths, command output, or raw provider
messages in the receipt. Operational gates that cannot be proved in the current
environment are recorded as ``blocked`` or ``deferred``; they are never inferred
from an offline test or a tool version check.
"""
from __future__ import annotations

import argparse
import datetime as _datetime
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from validate_m8_live_evidence import (
    CHECKS,
    EvidenceError,
    current_head,
    load_json,
    validate_contract,
    validate_receipt,
)

_CREDENTIAL_KEYS = {
    "codexAppServer": ("OPENAI_API_KEY", "CODEX_API_KEY"),
    "acp": ("CURSOR_API_KEY", "GROK_API_KEY", "OPENCODE_API_KEY", "AGENTRY_ACP_API_KEY"),
    "claudeHeadless": ("ANTHROPIC_API_KEY", "CLAUDE_API_KEY"),
}
_CLI_COMMANDS = {
    "codexAppServer": ("codex", "--version"),
    "acp": ("opencode", "--version"),
    "claudeHeadless": ("claude", "--version"),
}
_SIGNING_KEYS = (
    "SIGN_IDENTITY",
    "REPOPROMPT_PROVISIONING_PROFILE",
    "SPARKLE_PRIVATE_KEY",
    "NOTARYTOOL_PRIVATE_KEY",
    "NOTARYTOOL_KEY_ID",
    "NOTARYTOOL_ISSUER_ID",
    "AGENTRY_SPARKLE_STABLE_FEED_URL",
    "GH_TOKEN",
)
_UNSAFE_OUTPUT = re.compile(r"(?i)(?:api[_-]?key|authorization|password|secret|token|bearer|private[_-]?key|/users/|/home/)")


def _utc_now() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _summary(value: str, fallback: str) -> str:
    """Return a short receipt-safe summary without output or filesystem details."""
    line = " ".join(value.split())
    if not line:
        return fallback
    if _UNSAFE_OUTPUT.search(line):
        return fallback
    # Keep receipts stable and prevent accidental leakage from third-party tools.
    return line[:220]


def _run(argv: list[str], repo_root: Path, timeout: float = 30.0) -> tuple[int, str]:
    try:
        result = subprocess.run(
            argv,
            cwd=repo_root,
            env=os.environ.copy(),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return 124, type(error).__name__
    output = (result.stdout or "") + (result.stderr or "")
    # The caller only uses this to choose a bounded reason. Never persist it.
    return result.returncode, output


def _run_initialize(binary: Path, repo_root: Path, timeout: float = 30.0) -> tuple[int, str]:
    """Run one bounded MCP initialize with EOF; return only process status/output."""
    payload = (
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
        '{"protocolVersion":"2024-11-05","capabilities":{},'
        '"clientInfo":{"name":"m8-certification","version":"1"}}}\n'
    )
    try:
        result = subprocess.run(
            [str(binary), "--backend", "auto"],
            cwd=repo_root,
            env=os.environ.copy(),
            input=payload,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return 124, type(error).__name__
    return result.returncode, (result.stdout or "") + (result.stderr or "")


def _tool_version(command: tuple[str, str]) -> str:
    executable = shutil.which(command[0])
    if executable is None:
        return "unavailable"
    code, output = _run(list(command), Path.cwd(), timeout=8.0)
    if code != 0:
        return "unavailable"
    first = " ".join(output.splitlines()[0].split()) if output.splitlines() else "available"
    # Keep only a conventional version token. Never persist arbitrary tool
    # output (a substituted executable must not get a receipt exfiltration
    # channel).
    match = re.search(r"\b\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9_.-]+)?\b", first)
    return match.group(0) if match else "available"


def _credential_presence() -> dict[str, bool]:
    return {
        provider: any(bool(os.environ.get(key, "").strip()) for key in keys)
        for provider, keys in _CREDENTIAL_KEYS.items()
    }


def _signing_identity_present() -> bool:
    if os.environ.get("SIGN_IDENTITY", "").strip():
        return True
    try:
        result = subprocess.run(
            ["security", "find-identity", "-v", "-p", "codesigning"],
            capture_output=True,
            text=True,
            timeout=8.0,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and "valid identities found" in (result.stdout or "")


def _row(status: str, summary: str, observed_at: str, evidence_id: str | None = None) -> dict[str, Any]:
    return {"status": status, "observed_at": observed_at, "evidence_id": evidence_id, "summary": _summary(summary, "no diagnostic summary")}


def _provider_smoke(args: argparse.Namespace, root: Path, credentials: dict[str, bool], versions: dict[str, str], observed: str) -> dict[str, Any]:
    if not args.live:
        return _row("deferred", "live execution was not requested", observed)
    missing = [provider for provider, present in credentials.items() if not present]
    if missing:
        return _row("blocked", "explicit provider credentials are absent for one or more matrix entries", observed)
    unavailable = [provider for provider, version in versions.items() if version == "unavailable"]
    if unavailable:
        return _row("blocked", "one or more provider executables are unavailable", observed)
    if not args.provider_matrix:
        return _row("blocked", "three-provider matrix execution was not requested", observed)
    if os.environ.get("AGENTRY_M8_COORDINATED"):
        return _row("blocked", "visible provider matrix smoke must run outside its coordinating daemon job", observed)
    # A generic Agent Mode smoke exercises one configured provider, not the
    # Codex/ACP/Claude matrix. Keep this external evidence-dependent until each
    # provider has an individually identified run and receipt.
    return _row("blocked", "per-provider live receipts are required before matrix certification", observed)


def _auto_matrix(args: argparse.Namespace, root: Path, observed: str) -> dict[str, Any]:
    if not args.live:
        return _row("deferred", "live backend matrix was not requested", observed)
    if not args.auto_matrix:
        return _row("blocked", "app-available and app-unavailable probes were not authorized as a pair", observed)
    if os.environ.get("AGENTRY_M8_COORDINATED"):
        return _row("blocked", "live backend matrix requires a dedicated coordinating subjob", observed)
    # The focused suite is a prerequisite, never a substitute for both live
    # process states. It gives a deterministic diagnostic before the live probe.
    prerequisite = ["swift", "test", "--filter", "MCPBackendSelectionTests"]
    if not os.environ.get("AGENTRY_M8_COORDINATED"):
        prerequisite = ["./conductor", "test", "--filter", "MCPBackendSelectionTests"]
    code, _ = _run(prerequisite, root, timeout=300.0)
    if code != 0:
        return _row("blocked", "backend selection prerequisite suite failed", observed)
    candidates = [
        root / ".build" / "out" / "Products" / "Debug" / "agentry-mcp",
        root / ".build" / "arm64-apple-macosx" / "debug" / "agentry-mcp",
    ]
    binary = next((candidate for candidate in candidates if candidate.is_file()), None)
    if binary is None:
        return _row("blocked", "live backend probe executable is unavailable", observed)
    probe_code, _ = _run_initialize(binary, root, timeout=30.0)
    if probe_code != 0:
        return _row("blocked", "app-unavailable backend probe did not complete successfully", observed)
    return _row("blocked", "app-unavailable fallback was observed but app-available pair is not collected", observed)


def _sleep_wake(args: argparse.Namespace, observed: str) -> dict[str, Any]:
    if not args.live:
        return _row("deferred", "sleep and wake was not requested", observed)
    if not args.system_sleep:
        return _row("blocked", "system power transition requires the explicit system-sleep flag", observed)
    # Sleeping the host from a session that must write its receipt is unsafe;
    # the signed operational run must provide an external wake and collection
    # channel. We deliberately do not call pmset here.
    return _row("blocked", "host sleep and externally verified wake are unavailable to this session", observed)


def _signed_artifact(args: argparse.Namespace, root: Path, observed: str) -> dict[str, Any]:
    if not args.live:
        return _row("deferred", "signed artifact packaging was not requested", observed)
    missing = [key for key in _SIGNING_KEYS if not os.environ.get(key, "").strip()]
    if missing:
        return _row("blocked", "release signing and publication prerequisites are not provisioned", observed)
    code, _ = _run(["./Scripts/release.sh", "preflight"], root, timeout=900.0)
    if code != 0:
        return _row("blocked", "release preflight rejected the current environment", observed)
    # `release.sh artifact` intentionally creates an ad-hoc, non-distributable
    # candidate. It cannot satisfy this gate; official signing/notarization is
    # a separately authorized publish path and must provide its own receipt.
    return _row("blocked", "available artifact path is ad-hoc and not notarized", observed)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, default=Path(__file__).resolve().parent / "Fixtures" / "headless_mcp_domain_runtime_m8_contract.json")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--record", type=Path)
    parser.add_argument("--live", action="store_true", help="attempt operational gates; without this all live checks are deferred")
    parser.add_argument("--provider-matrix", action="store_true", help="assert that the visible smoke is the authorized provider matrix run")
    parser.add_argument("--auto-matrix", action="store_true", help="run the deterministic backend prerequisite before live matrix collection")
    parser.add_argument("--system-sleep", action="store_true", help="record the explicit system-sleep request; this runner never sleeps the host")
    parser.add_argument("--agent-timeout", type=int, default=120)
    parser.add_argument("--authorize-auto", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.repo_root.resolve()
    started = _utc_now()
    try:
        contract = load_json(args.contract, "M8 contract")
        validate_contract(contract)
        commit = current_head(root)
    except (EvidenceError, OSError) as error:
        print(f"M8 certification could not start: {error}", file=sys.stderr)
        return 2

    credentials = _credential_presence()
    versions = {provider: _tool_version(command) for provider, command in _CLI_COMMANDS.items()}
    environment = {
        "os": platform.system(),
        "architecture": platform.machine() or "unknown",
        "codex_cli_version": versions["codexAppServer"],
        "claude_cli_version": versions["claudeHeadless"],
        "provider_credentials_present": credentials,
        "signing_identity_present": _signing_identity_present(),
    }
    observed = _utc_now()
    checks = {
        "live_provider_smoke": _provider_smoke(args, root, credentials, versions, observed),
        "live_auto_matrix": _auto_matrix(args, root, observed),
        "sleep_wake_soak": _sleep_wake(args, observed),
        "signed_release_artifact": _signed_artifact(args, root, observed),
    }
    try:
        ending_commit = current_head(root)
    except EvidenceError as error:
        print(f"M8 certification could not finalize: {error}", file=sys.stderr)
        return 2
    if ending_commit != commit:
        print("M8 certification could not finalize: repository HEAD changed during certification", file=sys.stderr)
        return 2
    all_passed = all(checks[name]["status"] == "passed" for name in CHECKS)
    promotion = {
        "status": "authorized" if all_passed and args.authorize_auto else "not_authorized",
        "default_backend": "app",
        "reason": "all M8 checks passed with explicit authorization" if all_passed and args.authorize_auto else "automatic backend promotion remains disabled",
    }
    receipt = {
        "schema_version": 1,
        "kind": "m8_live_certification",
        "milestone": "M8",
        "commit_sha": commit,
        "started_at": started,
        "finished_at": _utc_now(),
        "environment": environment,
        "checks": checks,
        "promotion": promotion,
    }
    try:
        validate_receipt(receipt, contract, expected_commit=commit, allow_authorized=args.authorize_auto)
    except EvidenceError as error:
        print(f"M8 receipt construction rejected: {error}", file=sys.stderr)
        return 2
    record = args.record or root / ".build" / "validation-artifacts" / "m8" / f"m8-live-{commit[:12]}.json"
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(json.dumps(receipt, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    passed = sum(checks[name]["status"] == "passed" for name in CHECKS)
    print(f"M8 certification receipt: {record}")
    print(f"M8 certification result: {passed}/{len(CHECKS)} checks passed; promotion={promotion['status']}")
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
