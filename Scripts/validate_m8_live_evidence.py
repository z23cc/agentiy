#!/usr/bin/env python3
"""Validate M8 live-certification receipts and backend promotion evidence.

The validator is intentionally fail-closed. A live result is promotable only when every required
check has a receipt tied to the current commit and an explicit authorization is supplied. Missing
credentials, unavailable infrastructure, and unsafe system operations remain blocked/deferred.
"""
from __future__ import annotations

import argparse
import datetime as _datetime
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
MILESTONE = "M8"
KIND = "m8_live_certification"
CHECKS = (
    "live_provider_smoke",
    "live_auto_matrix",
    "sleep_wake_soak",
    "signed_release_artifact",
)
PROVIDERS = ("codexAppServer", "acp", "claudeHeadless")
STATUSES = ("passed", "blocked", "deferred")
_SHA256 = re.compile(r"^[0-9a-f]{40}$")
_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")
_VERSION = re.compile(r"^(?:available|unavailable|(?:[A-Za-z][A-Za-z0-9_.-]* )?\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9_.-]+)?)$")
_SENSITIVE = re.compile(
    r"(?i)(?:api[_-]?key|authorization|password|secret|token|bearer|private[_-]?key|/users/|/home/)"
)


class EvidenceError(ValueError):
    """A bounded, user-actionable evidence validation failure."""


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _require_object(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{name} must be a JSON object")
    return value


def _require_exact_keys(value: dict[str, Any], expected: set[str], name: str) -> None:
    actual = set(value)
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing or extra:
        details = []
        if missing:
            details.append(f"missing={missing}")
        if extra:
            details.append(f"extra={extra}")
        raise EvidenceError(f"{name} keys mismatch ({'; '.join(details)})")


def _require_string(value: Any, name: str, *, pattern: re.Pattern[str] | None = None) -> None:
    if not isinstance(value, str) or not value.strip():
        raise EvidenceError(f"{name} must be a non-empty string")
    if pattern is not None and not pattern.fullmatch(value):
        raise EvidenceError(f"{name} has an invalid format")


def _require_bool(value: Any, name: str, expected: bool | None = None) -> None:
    if type(value) is not bool or (expected is not None and value is not expected):
        suffix = f" {expected!r}" if expected is not None else ""
        raise EvidenceError(f"{name} must be a boolean{suffix}")


def _require_integer(value: Any, name: str, *, minimum: int | None = None) -> None:
    if type(value) is not int or (minimum is not None and value < minimum):
        suffix = f" >= {minimum}" if minimum is not None else ""
        raise EvidenceError(f"{name} must be an integer{suffix}")


def _require_timestamp(value: Any, name: str) -> None:
    _require_string(value, name, pattern=_TIMESTAMP)
    try:
        _datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise EvidenceError(f"{name} is not a valid UTC timestamp") from error


def _assert_secret_free(value: Any, name: str = "receipt") -> None:
    if isinstance(value, str):
        if _SENSITIVE.search(value):
            raise EvidenceError(f"{name} contains a forbidden secret/path marker")
    elif isinstance(value, dict):
        for key, child in value.items():
            _assert_secret_free(child, f"{name}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _assert_secret_free(child, f"{name}[{index}]")


def load_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_reject_duplicate_keys)
    except FileNotFoundError as error:
        raise EvidenceError(f"{label} missing: {path}") from error
    except json.JSONDecodeError as error:
        raise EvidenceError(f"{label} is invalid JSON: {error}") from error


def validate_contract(contract: Any) -> None:
    root = _require_object(contract, "contract")
    _require_exact_keys(
        root,
        {"schema_version", "milestone", "phase", "required_checks", "provider_matrix", "allowed_statuses", "receipt", "promotion"},
        "contract",
    )
    if type(root["schema_version"]) is not int or root["schema_version"] != SCHEMA_VERSION:
        raise EvidenceError("contract schema_version must be integer 1")
    if root["milestone"] != MILESTONE or root["phase"] != "live_certification_release_candidate":
        raise EvidenceError("contract milestone/phase drifted")
    if root["required_checks"] != list(CHECKS):
        raise EvidenceError("contract required_checks must match canonical M8 order")
    if root["provider_matrix"] != list(PROVIDERS):
        raise EvidenceError("contract provider_matrix must match canonical providers")
    if root["allowed_statuses"] != list(STATUSES):
        raise EvidenceError("contract allowed_statuses drifted")

    receipt = _require_object(root["receipt"], "contract.receipt")
    _require_exact_keys(
        receipt,
        {"schema_version", "kind", "current_head_required", "secret_free", "required_environment_fields"},
        "contract.receipt",
    )
    if type(receipt["schema_version"]) is not int or receipt["schema_version"] != SCHEMA_VERSION:
        raise EvidenceError("receipt schema_version must be integer 1")
    if receipt["kind"] != KIND:
        raise EvidenceError("receipt kind drifted")
    _require_bool(receipt["current_head_required"], "contract.receipt.current_head_required", True)
    _require_bool(receipt["secret_free"], "contract.receipt.secret_free", True)
    required_environment_fields = (
        "os",
        "architecture",
        "codex_cli_version",
        "claude_cli_version",
        "provider_credentials_present",
        "signing_identity_present",
    )
    if receipt["required_environment_fields"] != list(required_environment_fields):
        raise EvidenceError("receipt required_environment_fields drifted")

    promotion = _require_object(root["promotion"], "contract.promotion")
    _require_exact_keys(
        promotion,
        {"current_default_backend", "target_default_backend", "requires_all_checks_passed", "requires_explicit_authorization", "no_automatic_promotion"},
        "contract.promotion",
    )
    if promotion["current_default_backend"] != "app" or promotion["target_default_backend"] != "auto":
        raise EvidenceError("promotion backend policy must remain app -> auto")
    _require_bool(promotion["requires_all_checks_passed"], "contract.promotion.requires_all_checks_passed", True)
    _require_bool(promotion["requires_explicit_authorization"], "contract.promotion.requires_explicit_authorization", True)
    _require_bool(promotion["no_automatic_promotion"], "contract.promotion.no_automatic_promotion", True)


def validate_receipt(receipt: Any, contract: Any, *, expected_commit: str | None = None, allow_authorized: bool = False) -> None:
    root = _require_object(receipt, "receipt")
    _require_exact_keys(root, {"schema_version", "kind", "milestone", "commit_sha", "started_at", "finished_at", "environment", "checks", "promotion"}, "receipt")
    if type(root["schema_version"]) is not int or root["schema_version"] != SCHEMA_VERSION:
        raise EvidenceError("receipt schema_version must be integer 1")
    if root["kind"] != KIND or root["milestone"] != MILESTONE:
        raise EvidenceError("receipt kind/milestone drifted")
    _require_string(root["commit_sha"], "receipt.commit_sha", pattern=_SHA256)
    if expected_commit is not None and root["commit_sha"] != expected_commit:
        raise EvidenceError("receipt commit_sha does not match current HEAD")
    _require_timestamp(root["started_at"], "receipt.started_at")
    _require_timestamp(root["finished_at"], "receipt.finished_at")

    environment = _require_object(root["environment"], "receipt.environment")
    _require_exact_keys(
        environment,
        {"os", "architecture", "codex_cli_version", "claude_cli_version", "provider_credentials_present", "signing_identity_present"},
        "receipt.environment",
    )
    _require_string(environment["os"], "receipt.environment.os")
    _require_string(environment["architecture"], "receipt.environment.architecture")
    for key in ("codex_cli_version", "claude_cli_version"):
        _require_string(environment[key], f"receipt.environment.{key}", pattern=_VERSION)
    credentials = _require_object(environment["provider_credentials_present"], "receipt.environment.provider_credentials_present")
    _require_exact_keys(credentials, set(PROVIDERS), "receipt.environment.provider_credentials_present")
    for provider in PROVIDERS:
        _require_bool(credentials[provider], f"receipt.environment.provider_credentials_present.{provider}")
    _require_bool(environment["signing_identity_present"], "receipt.environment.signing_identity_present")

    checks = _require_object(root["checks"], "receipt.checks")
    _require_exact_keys(checks, set(CHECKS), "receipt.checks")
    for check in CHECKS:
        row = _require_object(checks[check], f"receipt.checks.{check}")
        _require_exact_keys(row, {"status", "observed_at", "evidence_id", "summary"}, f"receipt.checks.{check}")
        status = row["status"]
        if status not in STATUSES:
            raise EvidenceError(f"receipt.checks.{check}.status is invalid")
        _require_timestamp(row["observed_at"], f"receipt.checks.{check}.observed_at")
        if status == "passed":
            _require_string(row["evidence_id"], f"receipt.checks.{check}.evidence_id")
            if not row["evidence_id"].startswith("m8-"):
                raise EvidenceError(f"receipt.checks.{check}.evidence_id must be M8-scoped")
        elif row["evidence_id"] is not None:
            raise EvidenceError(f"blocked/deferred check {check} cannot carry evidence_id")
        _require_string(row["summary"], f"receipt.checks.{check}.summary")

    promotion = _require_object(root["promotion"], "receipt.promotion")
    _require_exact_keys(promotion, {"status", "default_backend", "reason"}, "receipt.promotion")
    if promotion["default_backend"] != "app":
        raise EvidenceError("receipt promotion cannot change the current app default")
    if promotion["status"] not in {"not_authorized", "authorized"}:
        raise EvidenceError("receipt promotion status is invalid")
    _require_string(promotion["reason"], "receipt.promotion.reason")
    all_passed = all(checks[check]["status"] == "passed" for check in CHECKS)
    if promotion["status"] == "authorized" and (not all_passed or not allow_authorized):
        raise EvidenceError("auto promotion requires every check passed and explicit --authorize-auto")
    if promotion["status"] == "not_authorized" and all_passed and allow_authorized:
        raise EvidenceError("--authorize-auto requires an authorized promotion receipt")
    _assert_secret_free(root)


def current_head(repo_root: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise EvidenceError(f"could not resolve current HEAD: {error}") from error
    head = result.stdout.strip()
    if not _SHA256.fullmatch(head):
        raise EvidenceError("git HEAD is not a full commit SHA")
    return head


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, default=Path(__file__).resolve().parent / "Fixtures" / "headless_mcp_domain_runtime_m8_contract.json")
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--check-current-head", action="store_true")
    parser.add_argument("--authorize-auto", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        contract = load_json(args.contract, "M8 contract")
        validate_contract(contract)
        # The contract makes current-head binding mandatory. Keep the flag for
        # backwards-compatible command lines, but never allow it to be omitted.
        expected_commit = current_head(args.repo_root)
        receipt = load_json(args.receipt, "M8 receipt")
        validate_receipt(receipt, contract, expected_commit=expected_commit, allow_authorized=args.authorize_auto)
    except EvidenceError as error:
        print(f"M8 live evidence rejected: {error}", file=sys.stderr)
        return 2
    checks = receipt["checks"]
    passed = sum(checks[key]["status"] == "passed" for key in CHECKS)
    print(f"M8 live evidence: valid ({passed}/{len(CHECKS)} checks passed; promotion={receipt['promotion']['status']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
