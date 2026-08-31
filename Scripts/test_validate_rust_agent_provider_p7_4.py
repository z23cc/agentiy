#!/usr/bin/env python3
"""Self-tests for the P7-4 offline provider conformance validator."""
from __future__ import annotations

import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "Scripts" / "validate_rust_agent_provider_p7_4.py"
spec = importlib.util.spec_from_file_location("p7_4_validator", MODULE_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError(f"could not load {MODULE_PATH}")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class ProviderConformanceValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        fixture = ROOT / "Scripts" / "Fixtures" / "rust_agent_provider_p7_4_conformance.json"
        self.contract = json.loads(fixture.read_text(encoding="utf-8"))

    def test_committed_fixture_is_valid(self) -> None:
        validator.validate_contract(self.contract)

    def test_capability_drift_is_rejected(self) -> None:
        changed = copy.deepcopy(self.contract)
        changed["protocols"]["acp"]["supports_typed_state"] = False
        with self.assertRaises(validator.ContractError):
            validator.validate_contract(changed)

    def test_missing_or_extra_protocol_is_rejected(self) -> None:
        missing = copy.deepcopy(self.contract)
        del missing["protocols"]["acp"]
        with self.assertRaises(validator.ContractError):
            validator.validate_contract(missing)
        extra = copy.deepcopy(self.contract)
        extra["protocols"]["future"] = copy.deepcopy(extra["protocols"]["acp"])
        with self.assertRaises(validator.ContractError):
            validator.validate_contract(extra)

    def test_live_soak_cannot_be_claimed_as_synthetic(self) -> None:
        changed = copy.deepcopy(self.contract)
        changed["live_soak"]["deferred"] = False
        with self.assertRaises(validator.ContractError):
            validator.validate_contract(changed)

    def test_integer_fields_reject_boolean_and_float_values(self) -> None:
        schema_bool = copy.deepcopy(self.contract)
        schema_bool["schema_version"] = True
        with self.assertRaises(validator.ContractError):
            validator.validate_contract(schema_bool)

        schema_float = copy.deepcopy(self.contract)
        schema_float["schema_version"] = 1.0
        with self.assertRaises(validator.ContractError):
            validator.validate_contract(schema_float)

        epoch_float = copy.deepcopy(self.contract)
        epoch_float["abi_epoch_decision"]["epoch"] = 1.0
        with self.assertRaises(validator.ContractError):
            validator.validate_contract(epoch_float)

    def test_duplicate_json_keys_are_rejected(self) -> None:
        with self.assertRaises(validator.ContractError):
            json.loads(
                '{"schema_version": 1, "schema_version": 1}',
                object_pairs_hook=validator._reject_duplicate_keys,
            )


if __name__ == "__main__":
    unittest.main()
