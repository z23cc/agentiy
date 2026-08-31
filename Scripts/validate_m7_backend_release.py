#!/usr/bin/env python3
"""Validate the M7 backend cutover and release-evidence contract.

This gate is deliberately deterministic, credential-free, and network-free. It validates the
backend-selection invariants and the checked-in evidence ledger. Live credentials, visible-app
lifecycle, sleep/wake, and signing remain explicitly deferred rather than being inferred here.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
MILESTONE = "M7"
BACKENDS = ("app", "headless", "auto")
OFFLINE_CHECKS = (
    "backend_selection_matrix",
    "canonical_state_root",
    "provider_conformance",
    "ffi_codegen",
    "source_guardrails",
)
LIVE_DEFERRED_CHECKS = (
    "live_provider_smoke",
    "live_auto_matrix",
    "sleep_wake_soak",
    "signed_release_artifact",
)


class ContractError(ValueError):
    """A bounded, user-actionable contract or evidence validation failure."""


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Reject duplicate JSON object keys instead of silently taking the last value."""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _require_object(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{name} must be a JSON object")
    return value


def _require_exact_keys(value: dict[str, Any], expected: set[str], name: str) -> None:
    actual = set(value)
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing or extra:
        detail: list[str] = []
        if missing:
            detail.append(f"missing={missing}")
        if extra:
            detail.append(f"extra={extra}")
        raise ContractError(f"{name} keys mismatch ({'; '.join(detail)})")


def _require_string(value: Any, name: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise ContractError(f"{name} must be a non-empty string")


def _require_bool(value: Any, name: str, expected: bool) -> None:
    if type(value) is not bool or value is not expected:
        raise ContractError(f"{name} must be {expected!r}")


def _require_integer(value: Any, name: str, expected: int) -> None:
    if type(value) is not int or value != expected:
        raise ContractError(f"{name} must be integer {expected}")


def _require_unique_strings(value: Any, name: str, expected: tuple[str, ...]) -> None:
    if value != list(expected):
        raise ContractError(f"{name} must be exactly {list(expected)!r} in canonical order")
    if any(not isinstance(item, str) or not item.strip() for item in value):
        raise ContractError(f"{name} must contain non-empty strings")


def validate_contract(contract: Any) -> None:
    root = _require_object(contract, "contract")
    _require_exact_keys(
        root,
        {"schema_version", "milestone", "phase", "backend_policy", "state_continuity", "release_gate", "compatibility"},
        "contract",
    )
    _require_integer(root["schema_version"], "schema_version", SCHEMA_VERSION)
    if root["milestone"] != MILESTONE:
        raise ContractError(f"milestone must be {MILESTONE}")
    if root["phase"] != "backend_cutover_release_evidence":
        raise ContractError("phase must identify backend cutover release evidence")

    backend = _require_object(root["backend_policy"], "backend_policy")
    _require_exact_keys(backend, {"allowed", "default", "interactive_exec_allowed", "auto"}, "backend_policy")
    _require_unique_strings(backend["allowed"], "backend_policy.allowed", BACKENDS)
    if backend["default"] != "app":
        raise ContractError("app must remain the default until live evidence authorizes cutover")
    _require_unique_strings(backend["interactive_exec_allowed"], "backend_policy.interactive_exec_allowed", ("app",))

    auto = _require_object(backend["auto"], "backend_policy.auto")
    _require_exact_keys(
        auto,
        {
            "probe",
            "max_probe_count",
            "probe_timeout_milliseconds",
            "sends_protocol_bytes",
            "private_endpoint_inspected",
            "selection_before_initialize",
            "post_initialize_switch",
            "retry_after_selection",
            "available_result",
            "unavailable_result",
        },
        "backend_policy.auto",
    )
    if auto["probe"] != "bootstrap_socket_connect_only":
        raise ContractError("auto must use the bootstrap connect-only probe")
    _require_integer(auto["max_probe_count"], "backend_policy.auto.max_probe_count", 1)
    _require_integer(auto["probe_timeout_milliseconds"], "backend_policy.auto.probe_timeout_milliseconds", 150)
    _require_bool(auto["sends_protocol_bytes"], "backend_policy.auto.sends_protocol_bytes", False)
    _require_bool(auto["private_endpoint_inspected"], "backend_policy.auto.private_endpoint_inspected", False)
    _require_bool(auto["selection_before_initialize"], "backend_policy.auto.selection_before_initialize", True)
    if auto["post_initialize_switch"] != "forbidden" or auto["retry_after_selection"] != "forbidden":
        raise ContractError("auto cannot switch or retry after a backend has been selected")
    if auto["available_result"] != "app" or auto["unavailable_result"] != "headless":
        raise ContractError("auto result mapping drifted")

    state = _require_object(root["state_continuity"], "state_continuity")
    _require_exact_keys(
        state,
        {
            "canonical_relative_root",
            "forbidden_relative_roots",
            "app_and_headless_same_root",
            "selection_without_window_id",
            "backend_specific_durable_schema",
            "overlay_persistence",
        },
        "state_continuity",
    )
    if state["canonical_relative_root"] != "Workspaces":
        raise ContractError("canonical state root must remain Workspaces")
    _require_unique_strings(state["forbidden_relative_roots"], "state_continuity.forbidden_relative_roots", ("Headless",))
    _require_bool(state["app_and_headless_same_root"], "state_continuity.app_and_headless_same_root", True)
    _require_bool(state["selection_without_window_id"], "state_continuity.selection_without_window_id", True)
    _require_bool(state["backend_specific_durable_schema"], "state_continuity.backend_specific_durable_schema", False)
    _require_bool(state["overlay_persistence"], "state_continuity.overlay_persistence", False)

    release = _require_object(root["release_gate"], "release_gate")
    _require_exact_keys(
        release,
        {"offline_required_checks", "live_deferred_checks", "default_cutover", "evidence_manifest", "runner"},
        "release_gate",
    )
    _require_unique_strings(release["offline_required_checks"], "release_gate.offline_required_checks", OFFLINE_CHECKS)
    _require_unique_strings(release["live_deferred_checks"], "release_gate.live_deferred_checks", LIVE_DEFERRED_CHECKS)
    if release["default_cutover"] != "blocked_until_live_evidence":
        raise ContractError("default cutover must remain blocked until live evidence")
    if release["evidence_manifest"] != "Scripts/Fixtures/headless_mcp_domain_runtime_m7_evidence.json":
        raise ContractError("evidence manifest path drifted")
    if release["runner"] != "Scripts/m7_backend_certification.sh":
        raise ContractError("certification runner path drifted")

    compatibility = _require_object(root["compatibility"], "compatibility")
    compatibility_keys = {
        "mcp_wire_schema_changed",
        "mcp_catalog_changed",
        "interactive_exec_behavior_changed",
        "private_endpoint_behavior_changed",
        "automatic_default_enabled",
    }
    _require_exact_keys(compatibility, compatibility_keys, "compatibility")
    for key in sorted(compatibility_keys):
        _require_bool(compatibility[key], f"compatibility.{key}", False)


def validate_evidence(manifest: Any, contract: Any) -> None:
    root = _require_object(manifest, "evidence")
    _require_exact_keys(root, {"schema_version", "milestone", "offline", "live", "cutover"}, "evidence")
    _require_integer(root["schema_version"], "evidence.schema_version", SCHEMA_VERSION)
    if root["milestone"] != MILESTONE:
        raise ContractError(f"evidence.milestone must be {MILESTONE}")
    release = _require_object(contract["release_gate"], "contract.release_gate")

    offline = _require_object(root["offline"], "evidence.offline")
    _require_exact_keys(offline, set(release["offline_required_checks"]), "evidence.offline")
    for check in OFFLINE_CHECKS:
        row = _require_object(offline[check], f"evidence.offline.{check}")
        _require_exact_keys(row, {"status", "evidence"}, f"evidence.offline.{check}")
        if row["status"] != "passed":
            raise ContractError(f"offline check {check} must be passed")
        _require_string(row["evidence"], f"evidence.offline.{check}.evidence")

    live = _require_object(root["live"], "evidence.live")
    _require_exact_keys(live, set(release["live_deferred_checks"]), "evidence.live")
    for check in LIVE_DEFERRED_CHECKS:
        row = _require_object(live[check], f"evidence.live.{check}")
        _require_exact_keys(row, {"status", "reason"}, f"evidence.live.{check}")
        if row["status"] != "deferred":
            raise ContractError(f"live check {check} must remain deferred")
        _require_string(row["reason"], f"evidence.live.{check}.reason")

    cutover = _require_object(root["cutover"], "evidence.cutover")
    _require_exact_keys(cutover, {"default_backend", "status", "reason"}, "evidence.cutover")
    if cutover["default_backend"] != "app" or cutover["status"] != "not_authorized":
        raise ContractError("evidence cannot authorize automatic default cutover")
    _require_string(cutover["reason"], "evidence.cutover.reason")


def default_fixture() -> Path:
    return Path(__file__).resolve().parent / "Fixtures" / "headless_mcp_domain_runtime_m7_contract.json"


def default_evidence() -> Path:
    return Path(__file__).resolve().parent / "Fixtures" / "headless_mcp_domain_runtime_m7_evidence.json"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=default_fixture())
    parser.add_argument("--evidence", type=Path, default=default_evidence())
    parser.add_argument("--check", action="store_true", help="check mode (accepted for CI symmetry)")
    return parser.parse_args(argv)


def _load(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_reject_duplicate_keys)
    except FileNotFoundError as error:
        raise ContractError(f"{label} missing: {path}") from error
    except json.JSONDecodeError as error:
        raise ContractError(f"{label} is invalid JSON: {error}") from error


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        contract = _load(args.fixture, "M7 backend contract")
        validate_contract(contract)
        if args.check:
            expected_evidence = args.fixture.resolve().parent / Path(contract["release_gate"]["evidence_manifest"]).name
            if args.evidence.resolve() != expected_evidence:
                raise ContractError(
                    "check mode requires the evidence manifest beside the selected contract "
                    f"at {expected_evidence}"
                )
        evidence = _load(args.evidence, "M7 evidence manifest")
        validate_evidence(evidence, contract)
    except ContractError as error:
        print(f"M7 backend release gate rejected: {error}", file=sys.stderr)
        return 2
    print(
        "M7 backend release gate: valid "
        f"({len(OFFLINE_CHECKS)} offline checks passed, "
        f"{len(LIVE_DEFERRED_CHECKS)} live checks deferred; default=app)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
