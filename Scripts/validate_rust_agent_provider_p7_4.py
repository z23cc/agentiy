#!/usr/bin/env python3
"""Validate the offline P7-4 provider conformance contract.

This validator is intentionally credential-free and network-free. It validates only the committed
capability matrix and release-gate metadata; it never starts a provider or mutates the workspace.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
MILESTONE = "P7-4"
PROTOCOLS = ("codexAppServer", "acp", "claudeHeadless")
CAPABILITY_FIELDS = (
    "owns_process_lifetime",
    "owns_line_framing",
    "serializes_stdin_writes",
    "emits_ordered_events",
    "bounds_stderr",
    "emits_process_exit_terminal_event",
    "supports_semantic_requests",
    "supports_typed_notifications",
    "supports_typed_server_requests",
    "supports_typed_state",
    "supports_token_cancellation",
    "supports_typed_control_receipts",
    "preserves_json_rpc_id_type",
    "supports_generic_send_line",
    "supports_start_with_stdin",
    "translates_stream_results",
)
COMMON = {
    "owns_process_lifetime": True,
    "owns_line_framing": True,
    "serializes_stdin_writes": True,
    "emits_ordered_events": True,
    "bounds_stderr": True,
    "emits_process_exit_terminal_event": True,
}
EXPECTED_PROTOCOLS = {
    "codexAppServer": {
        **COMMON,
        "supports_semantic_requests": True,
        "supports_typed_notifications": True,
        "supports_typed_server_requests": True,
        "supports_typed_state": True,
        "supports_token_cancellation": True,
        "supports_typed_control_receipts": False,
        "preserves_json_rpc_id_type": True,
        "supports_generic_send_line": False,
        "supports_start_with_stdin": False,
        "translates_stream_results": False,
    },
    "acp": {
        **COMMON,
        "supports_semantic_requests": True,
        "supports_typed_notifications": True,
        "supports_typed_server_requests": True,
        "supports_typed_state": True,
        "supports_token_cancellation": True,
        "supports_typed_control_receipts": True,
        "preserves_json_rpc_id_type": True,
        "supports_generic_send_line": False,
        "supports_start_with_stdin": False,
        "translates_stream_results": False,
    },
    "claudeHeadless": {
        **COMMON,
        "supports_semantic_requests": False,
        "supports_typed_notifications": False,
        "supports_typed_server_requests": False,
        "supports_typed_state": False,
        "supports_token_cancellation": False,
        "supports_typed_control_receipts": False,
        "preserves_json_rpc_id_type": False,
        "supports_generic_send_line": True,
        "supports_start_with_stdin": True,
        "translates_stream_results": True,
    },
}


class ContractError(ValueError):
    """A bounded, user-actionable contract validation failure."""


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


def validate_contract(contract: Any) -> None:
    root = _require_object(contract, "contract")
    _require_exact_keys(
        root,
        {"schema_version", "milestone", "protocols", "synthetic_certification", "live_soak", "abi_epoch_decision"},
        "contract",
    )
    if type(root["schema_version"]) is not int or root["schema_version"] != SCHEMA_VERSION:
        raise ContractError(f"schema_version must be integer {SCHEMA_VERSION}")
    if root["milestone"] != MILESTONE:
        raise ContractError(f"milestone must be {MILESTONE}")

    protocols = _require_object(root["protocols"], "protocols")
    _require_exact_keys(protocols, set(PROTOCOLS), "protocols")
    expected_keys = set(CAPABILITY_FIELDS)
    for protocol in PROTOCOLS:
        row = _require_object(protocols[protocol], f"protocols.{protocol}")
        _require_exact_keys(row, expected_keys, f"protocols.{protocol}")
        expected = EXPECTED_PROTOCOLS[protocol]
        for field in CAPABILITY_FIELDS:
            value = row[field]
            if not isinstance(value, bool):
                raise ContractError(f"protocols.{protocol}.{field} must be boolean")
            if value != expected[field]:
                raise ContractError(
                    f"protocols.{protocol}.{field} expected {expected[field]!r}, got {value!r}"
                )

    synthetic = _require_object(root["synthetic_certification"], "synthetic_certification")
    _require_exact_keys(
        synthetic,
        {"required", "credential_free", "network_required", "processes", "swift_test_filter", "rust_test_filter"},
        "synthetic_certification",
    )
    if synthetic["required"] is not True or synthetic["credential_free"] is not True:
        raise ContractError("synthetic certification must be required and credential_free")
    if synthetic["network_required"] is not False:
        raise ContractError("synthetic certification must not require network")
    if synthetic["processes"] != ["synthetic_shell_child"]:
        raise ContractError("synthetic certification process list changed")
    if synthetic["swift_test_filter"] != "CoreAgentProviderConformanceTests":
        raise ContractError("unexpected Swift conformance filter")
    if synthetic["rust_test_filter"] != "conformance":
        raise ContractError("unexpected Rust conformance filter")

    live = _require_object(root["live_soak"], "live_soak")
    _require_exact_keys(live, {"deferred", "credential_dependent", "visible_app_required", "reason"}, "live_soak")
    if live["deferred"] is not True or live["credential_dependent"] is not True or live["visible_app_required"] is not True:
        raise ContractError("live soak must remain deferred and credential/visible-app dependent")
    if not isinstance(live["reason"], str) or not live["reason"].strip():
        raise ContractError("live soak must include a non-empty deferral reason")

    abi = _require_object(root["abi_epoch_decision"], "abi_epoch_decision")
    _require_exact_keys(abi, {"epoch", "reason"}, "abi_epoch_decision")
    if type(abi["epoch"]) is not int or abi["epoch"] != 1:
        raise ContractError("P7-4 additive exports must retain integer ABI epoch 1")
    if not isinstance(abi["reason"], str) or not abi["reason"].strip():
        raise ContractError("ABI decision must include a non-empty reason")


def default_fixture() -> Path:
    return Path(__file__).resolve().parent / "Fixtures" / "rust_agent_provider_p7_4_conformance.json"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=default_fixture())
    parser.add_argument("--check", action="store_true", help="check mode (accepted for CI symmetry)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        contract = json.loads(
            args.fixture.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
        validate_contract(contract)
    except FileNotFoundError:
        print(f"P7-4 conformance contract missing: {args.fixture}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as error:
        print(f"P7-4 conformance contract is invalid JSON: {error}", file=sys.stderr)
        return 2
    except ContractError as error:
        print(f"P7-4 conformance contract rejected: {error}", file=sys.stderr)
        return 2
    print(f"P7-4 provider conformance contract: valid ({len(PROTOCOLS)} protocols, schema {SCHEMA_VERSION})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
