#!/usr/bin/env python3
"""Generate deterministic Phase 0 fixtures and import pre-redacted Swift samples."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
FIXTURE_ROOT = ROOT / "rust/benchmarks/fixtures/v1"
SWIFT_BASELINE_ROOT = FIXTURE_ROOT / "swift-baseline"
P1_CONTRACT = ROOT / "docs/architecture/rust-search-leaf-v1.md"
SWIFT_SOURCE_IMPLEMENTATION = "swift-search-pre-p1"
SWIFT_FIXTURE_NAMES = {
    "file-tree-batch.json": "file-tree-batch",
    "codemap.json": "codemap",
    "search-results.json": "search-results",
    "transcript.json": "transcript",
}
FORBIDDEN_KEYS = {
    "absolutepath",
    "apikey",
    "credential",
    "homedirectory",
    "machinename",
    "repositoryroot",
    "timestamp",
    "token",
    "username",
}
FORBIDDEN_TEXT = (
    re.compile(r"(?:^|\s)/(?:Users|home)/"),
    re.compile(r"file://", re.IGNORECASE),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{12,}"),
    re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b", re.IGNORECASE),
)


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def envelope(payload_kind: int, payload: bytes, *, version: int = 1, declared_length: int | None = None) -> bytes:
    length = len(payload) if declared_length is None else declared_length
    return struct.pack(">4sHHII", b"AGRY", version, payload_kind, 0, length) + payload


def synthetic_payloads() -> dict[str, Any]:
    return {
        "file-tree-batch.json": {
            "fixtureKind": "file-tree-batch",
            "redacted": True,
            "schemaVersion": 1,
            "payload": {
                "batch": 0,
                "entries": [
                    {"depth": 0, "kind": "directory", "path": "fixture-root"},
                    {"depth": 1, "kind": "file", "path": "fixture-root/source-001.swift", "sizeBytes": 256},
                    {"depth": 1, "kind": "file", "path": "fixture-root/source-002.rs", "sizeBytes": 65536},
                ],
                "hasMore": False,
            },
        },
        "codemap.json": {
            "fixtureKind": "codemap",
            "redacted": True,
            "schemaVersion": 1,
            "payload": {
                "files": [
                    {
                        "path": "fixture-root/source-001.swift",
                        "symbols": [
                            {"kind": "type", "name": "SyntheticType001", "startLine": 1, "endLine": 8},
                            {"kind": "function", "name": "syntheticFunction001", "startLine": 3, "endLine": 7},
                        ],
                    }
                ]
            },
        },
        "search-results.json": {
            "fixtureKind": "search-results",
            "redacted": True,
            "schemaVersion": 1,
            "payload": {
                "query": "synthetic-query",
                "results": [
                    {"line": 3, "path": "fixture-root/source-001.swift", "preview": "synthetic-match-001"},
                    {"line": 17, "path": "fixture-root/source-002.rs", "preview": "synthetic-match-002"},
                ],
            },
        },
        "transcript.json": {
            "fixtureKind": "transcript",
            "redacted": True,
            "schemaVersion": 1,
            "payload": {
                "events": [
                    {"kind": "message", "role": "user", "text": "synthetic-user-message"},
                    {"kind": "message", "role": "assistant", "text": "synthetic-assistant-message"},
                    {"kind": "terminal", "outcome": "success"},
                ]
            },
        },
    }


def standard_outputs() -> dict[Path, bytes]:
    small_payload = canonical_json({"kind": "synthetic", "sequence": 1})
    outputs: dict[Path, bytes] = {
        ROOT / "rust/crates/proto/tests/fixtures/v1/empty.bin": envelope(1, b""),
        ROOT / "rust/crates/proto/tests/fixtures/v1/small.bin": envelope(2, small_payload),
        ROOT / "rust/crates/proto/tests/fixtures/v1/truncated.bin": envelope(2, b"ok", declared_length=4),
        ROOT / "rust/crates/proto/tests/fixtures/v1/unknown-version.bin": envelope(1, b"", version=2),
        ROOT / "rust/fuzz/corpus/envelope_decode/seed-v1.bin": envelope(2, small_payload),
        ROOT / "rust/crates/runtime/tests/fixtures/random-seeds-v1.txt": b"0\n1\n42\n257\n65537\n4294967291\n",
    }
    for name, value in synthetic_payloads().items():
        outputs[FIXTURE_ROOT / "synthetic" / name] = canonical_json(value)

    manifest_entries = []
    for path, content in sorted(outputs.items(), key=lambda item: item[0].as_posix()):
        manifest_entries.append(
            {
                "bytes": len(content),
                "path": path.relative_to(ROOT).as_posix(),
                "sha256": hashlib.sha256(content).hexdigest(),
            }
        )
    outputs[FIXTURE_ROOT / "manifest.json"] = canonical_json(
        {
            "generator": "Scripts/extract_rust_ffi_baselines.py",
            "schemaVersion": 1,
            "source": "synthetic",
            "files": manifest_entries,
        }
    )
    return outputs


def validate_redacted(value: Any, *, location: str = "$") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = re.sub(r"[^a-z]", "", key.lower())
            if normalized in FORBIDDEN_KEYS:
                raise ValueError(f"{location}.{key}: forbidden key in redacted fixture")
            validate_redacted(child, location=f"{location}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            validate_redacted(child, location=f"{location}[{index}]")
    elif isinstance(value, str):
        if value.startswith(("/", "~")):
            raise ValueError(f"{location}: absolute or home-relative path is forbidden")
        for pattern in FORBIDDEN_TEXT:
            if pattern.search(value):
                raise ValueError(f"{location}: text resembles private source data")


def imported_swift_outputs(source: Path) -> dict[Path, bytes]:
    outputs: dict[Path, bytes] = {}
    for name, expected_kind in SWIFT_FIXTURE_NAMES.items():
        source_path = source / name
        try:
            value = json.loads(source_path.read_text(encoding="utf-8"))
        except FileNotFoundError as error:
            raise ValueError(f"missing Swift export: {source_path}") from error
        if not isinstance(value, dict):
            raise ValueError(f"{source_path}: root must be an object")
        if value.get("schemaVersion") != 1 or value.get("fixtureKind") != expected_kind:
            raise ValueError(f"{source_path}: unexpected schemaVersion or fixtureKind")
        if value.get("redacted") is not True:
            raise ValueError(f"{source_path}: redacted must be true")
        validate_redacted(value)
        outputs[SWIFT_BASELINE_ROOT / name] = canonical_json(value)

    entries = []
    for path, content in sorted(outputs.items(), key=lambda item: item[0].as_posix()):
        name = path.name
        entries.append(
            {
                "canonicalSizeBytes": len(content),
                "kind": SWIFT_FIXTURE_NAMES[name],
                "path": path.relative_to(ROOT).as_posix(),
                "sha256": hashlib.sha256(content).hexdigest(),
                "sourceImplementation": SWIFT_SOURCE_IMPLEMENTATION,
            }
        )
    outputs[SWIFT_BASELINE_ROOT / "manifest.json"] = canonical_json(
        {
            "schemaVersion": 1,
            "source": "pre-redacted-swift-export",
            "sourceImplementation": SWIFT_SOURCE_IMPLEMENTATION,
            "files": entries,
        }
    )
    return outputs


def apply_outputs(outputs: dict[Path, bytes], *, check: bool) -> list[str]:
    failures: list[str] = []
    for path, expected in sorted(outputs.items(), key=lambda item: item[0].as_posix()):
        if check:
            try:
                actual = path.read_bytes()
            except FileNotFoundError:
                failures.append(f"missing: {path.relative_to(ROOT)}")
                continue
            if actual != expected:
                failures.append(f"differs: {path.relative_to(ROOT)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(expected)
    return failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify outputs without writing")
    parser.add_argument(
        "--swift-export-dir",
        type=Path,
        help="import four already-redacted JSON exports using the frozen v1 format",
    )
    parser.add_argument(
        "--require-swift-baseline",
        action="store_true",
        help="require and verify the committed pre-P1 Swift baseline",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    outputs = standard_outputs()
    try:
        if args.swift_export_dir is not None:
            outputs.update(imported_swift_outputs(args.swift_export_dir.resolve()))
        elif args.require_swift_baseline or (args.check and P1_CONTRACT.is_file()):
            outputs.update(imported_swift_outputs(SWIFT_BASELINE_ROOT))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"fixture import failed: {error}", file=sys.stderr)
        return 1

    failures = apply_outputs(outputs, check=args.check)
    if failures:
        print("Rust FFI fixture check failed:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    action = "verified" if args.check else "generated"
    print(f"Rust FFI fixtures {action} ({len(outputs)} files).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
