#!/usr/bin/env python3
"""Self-tests for the M7 backend cutover and evidence gate."""
from __future__ import annotations

import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "Scripts" / "validate_m7_backend_release.py"
spec = importlib.util.spec_from_file_location("m7_validator", MODULE_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError(f"could not load {MODULE_PATH}")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class M7BackendReleaseValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        contract_path = ROOT / "Scripts" / "Fixtures" / "headless_mcp_domain_runtime_m7_contract.json"
        evidence_path = ROOT / "Scripts" / "Fixtures" / "headless_mcp_domain_runtime_m7_evidence.json"
        self.contract = json.loads(contract_path.read_text(encoding="utf-8"))
        self.evidence = json.loads(evidence_path.read_text(encoding="utf-8"))

    def test_committed_contract_and_evidence_are_valid(self) -> None:
        validator.validate_contract(self.contract)
        validator.validate_evidence(self.evidence, self.contract)

    def test_default_cutover_cannot_move_without_live_evidence(self) -> None:
        changed = copy.deepcopy(self.contract)
        changed["backend_policy"]["default"] = "auto"
        with self.assertRaises(validator.ContractError):
            validator.validate_contract(changed)

        changed_evidence = copy.deepcopy(self.evidence)
        changed_evidence["cutover"]["default_backend"] = "auto"
        with self.assertRaises(validator.ContractError):
            validator.validate_evidence(changed_evidence, self.contract)

    def test_auto_probe_budget_and_protocol_fence_are_strict(self) -> None:
        for key, value in (("max_probe_count", 2), ("probe_timeout_milliseconds", 151)):
            changed = copy.deepcopy(self.contract)
            changed["backend_policy"]["auto"][key] = value
            with self.subTest(key=key), self.assertRaises(validator.ContractError):
                validator.validate_contract(changed)

        changed = copy.deepcopy(self.contract)
        changed["backend_policy"]["auto"]["sends_protocol_bytes"] = True
        with self.assertRaises(validator.ContractError):
            validator.validate_contract(changed)

    def test_unknown_or_missing_evidence_check_is_rejected(self) -> None:
        missing = copy.deepcopy(self.evidence)
        del missing["offline"]["ffi_codegen"]
        with self.assertRaises(validator.ContractError):
            validator.validate_evidence(missing, self.contract)

        extra = copy.deepcopy(self.evidence)
        extra["live"]["future_probe"] = {"status": "deferred", "reason": "not enabled"}
        with self.assertRaises(validator.ContractError):
            validator.validate_evidence(extra, self.contract)

    def test_live_checks_cannot_be_claimed_passed(self) -> None:
        changed = copy.deepcopy(self.evidence)
        changed["live"]["live_auto_matrix"]["status"] = "passed"
        with self.assertRaises(validator.ContractError):
            validator.validate_evidence(changed, self.contract)

    def test_check_mode_rejects_an_evidence_manifest_from_another_path(self) -> None:
        contract_path = ROOT / "Scripts" / "Fixtures" / "headless_mcp_domain_runtime_m7_contract.json"
        foreign_path = ROOT / "Scripts" / "Fixtures" / "foreign-m7-evidence.json"
        result = validator.main(
            ["--check", "--fixture", str(contract_path), "--evidence", str(foreign_path)]
        )
        self.assertEqual(result, 2)

    def test_duplicate_json_keys_are_rejected(self) -> None:
        with self.assertRaises(validator.ContractError):
            json.loads(
                '{"milestone": "M7", "milestone": "M7"}',
                object_pairs_hook=validator._reject_duplicate_keys,
            )

    def test_integer_fields_reject_boolean_and_float_values(self) -> None:
        for field, value in (("schema_version", True), ("schema_version", 1.0)):
            changed = copy.deepcopy(self.contract)
            changed[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(validator.ContractError):
                validator.validate_contract(changed)


if __name__ == "__main__":
    unittest.main()
