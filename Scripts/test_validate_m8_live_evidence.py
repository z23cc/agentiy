#!/usr/bin/env python3
"""Contract tests for the M8 live-certification receipt validator."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import validate_m8_live_evidence as validator


ROOT = Path(__file__).resolve().parent
CONTRACT = validator.load_json(ROOT / "Fixtures" / "headless_mcp_domain_runtime_m8_contract.json", "contract")


def receipt(*, status: str = "blocked", evidence_id: str | None = None) -> dict:
    observed = "2026-08-31T00:00:00Z"
    checks = {
        check: {
            "status": status,
            "observed_at": observed,
            "evidence_id": evidence_id if status == "passed" else None,
            "summary": "bounded certification diagnostic",
        }
        for check in validator.CHECKS
    }
    return {
        "schema_version": 1,
        "kind": "m8_live_certification",
        "milestone": "M8",
        "commit_sha": "a" * 40,
        "started_at": observed,
        "finished_at": observed,
        "environment": {
            "os": "Darwin",
            "architecture": "arm64",
            "codex_cli_version": "codex-cli 0.149.1",
            "claude_cli_version": "2.1.246",
            "provider_credentials_present": {
                "codexAppServer": False,
                "acp": False,
                "claudeHeadless": False,
            },
            "signing_identity_present": True,
        },
        "checks": checks,
        "promotion": {
            "status": "not_authorized",
            "default_backend": "app",
            "reason": "automatic backend promotion remains disabled",
        },
    }


class M8EvidenceTests(unittest.TestCase):
    def test_contract_and_blocked_receipt_are_valid(self) -> None:
        validator.validate_contract(CONTRACT)
        validator.validate_receipt(receipt(), CONTRACT)

    def test_commit_mismatch_is_rejected(self) -> None:
        with self.assertRaisesRegex(validator.EvidenceError, "does not match"):
            validator.validate_receipt(receipt(), CONTRACT, expected_commit="b" * 40)

    def test_passed_check_requires_scoped_evidence(self) -> None:
        value = receipt(status="passed", evidence_id=None)
        with self.assertRaisesRegex(validator.EvidenceError, "evidence_id"):
            validator.validate_receipt(value, CONTRACT)

    def test_unknown_check_is_rejected(self) -> None:
        value = receipt()
        value["checks"]["unknown"] = value["checks"].pop(validator.CHECKS[0])
        with self.assertRaisesRegex(validator.EvidenceError, "keys mismatch"):
            validator.validate_receipt(value, CONTRACT)

    def test_secret_marker_is_rejected(self) -> None:
        value = receipt()
        value["checks"][validator.CHECKS[0]]["summary"] = "credential token leaked"
        with self.assertRaisesRegex(validator.EvidenceError, "forbidden"):
            validator.validate_receipt(value, CONTRACT)

    def test_authorized_requires_explicit_flag(self) -> None:
        value = receipt(status="passed", evidence_id="m8-every-check")
        value["promotion"]["status"] = "authorized"
        with self.assertRaisesRegex(validator.EvidenceError, "explicit"):
            validator.validate_receipt(value, CONTRACT)

    def test_authorized_all_passes_with_flag(self) -> None:
        value = receipt(status="passed", evidence_id="m8-every-check")
        value["promotion"]["status"] = "authorized"
        validator.validate_receipt(value, CONTRACT, allow_authorized=True)

    def test_duplicate_json_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"schema_version":1,"schema_version":1}\n', encoding="utf-8")
            with self.assertRaisesRegex(validator.EvidenceError, "duplicate"):
                validator.load_json(path, "receipt")

    def test_boolean_and_float_schema_drift_are_rejected(self) -> None:
        boolean_value = receipt()
        boolean_value["schema_version"] = True
        with self.assertRaises(validator.EvidenceError):
            validator.validate_receipt(boolean_value, CONTRACT)
        float_value = receipt()
        float_value["environment"]["signing_identity_present"] = 1.0
        with self.assertRaises(validator.EvidenceError):
            validator.validate_receipt(float_value, CONTRACT)

    def test_environment_version_is_not_an_arbitrary_output_channel(self) -> None:
        value = receipt()
        value["environment"]["codex_cli_version"] = "/tmp/credential-dump"
        with self.assertRaises(validator.EvidenceError):
            validator.validate_receipt(value, CONTRACT)


if __name__ == "__main__":
    unittest.main()
