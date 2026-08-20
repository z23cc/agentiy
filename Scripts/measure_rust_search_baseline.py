#!/usr/bin/env python3
"""Export, verify, and measure the pre-P1 Swift search baseline test binary."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
FIXTURE_ROOT = ROOT / "rust/benchmarks/fixtures/v1/swift-baseline"
RESULT_PATH = ROOT / "rust/benchmarks/results/v1/swift-search-reference.json"
SLO_PATH = ROOT / "rust/benchmarks/slo-v1.json"
FIXTURE_NAMES = ("file-tree-batch", "codemap", "search-results", "transcript")
EXPORT_FILTER = "RepoPromptTests.RustSearchSwiftBaselineExportTests/testExportCurrentSwiftPayloadsWhenRequested"
MEASURE_FILTER = "RepoPromptTests.RustSearchSwiftBaselineExportTests/testMeasureCurrentSwiftPayloadsWhenRequested"
EXPORT_ENV = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_EXPORT_DIR"
FIXTURE_ENV = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_FIXTURE_DIR"
MEASURE_ENV = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_MEASURE_OUTPUT"


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def run(command: list[str], *, env: dict[str, str] | None = None) -> None:
    print("$ " + " ".join(command), flush=True)
    subprocess.run(command, cwd=ROOT, env=env, check=True)


def run_test(test_filter: str, environment: dict[str, str], *, skip_build: bool) -> None:
    framework_root = ROOT / "Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
    environment = environment.copy()
    environment["DYLD_FRAMEWORK_PATH"] = str(framework_root)
    command = [
        "swift",
        "test",
        "--configuration",
        "release",
        "-Xswiftc",
        "-DDEBUG",
        "-Xlinker",
        "-rpath",
        "-Xlinker",
        str(framework_root),
        "--test-product",
        "RepoPromptTests",
    ]
    if skip_build:
        command.append("--skip-build")
    command.extend(["--filter", test_filter])
    run(command, env=environment)


def export_once(destination: Path, *, skip_build: bool) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment[EXPORT_ENV] = str(destination)
    run_test(EXPORT_FILTER, environment, skip_build=skip_build)
    missing = [name for name in FIXTURE_NAMES if not (destination / f"{name}.json").is_file()]
    if missing:
        raise RuntimeError(f"Swift exporter omitted fixtures: {', '.join(missing)}")


def import_export(destination: Path) -> None:
    run(
        [
            sys.executable,
            "Scripts/extract_rust_ffi_baselines.py",
            "--swift-export-dir",
            str(destination),
        ]
    )


def verify_committed_baseline() -> None:
    run(
        [
            sys.executable,
            "Scripts/extract_rust_ffi_baselines.py",
            "--check",
            "--require-swift-baseline",
        ]
    )


def compare_exports(first: Path, second: Path) -> None:
    for name in FIXTURE_NAMES:
        relative = f"{name}.json"
        if (first / relative).read_bytes() != (second / relative).read_bytes():
            raise RuntimeError(f"Swift baseline export is not byte-identical: {relative}")


def swift_compiler_identity() -> str:
    completed = subprocess.run(
        ["swift", "--version"], cwd=ROOT, text=True, capture_output=True, check=True
    )
    lines = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    return lines[0] if lines else "unknown"


def architecture_identity() -> str:
    value = platform.machine().lower()
    return "aarch64" if value == "arm64" else value


def write_reference_report(raw_path: Path) -> str:
    raw = json.loads(raw_path.read_text(encoding="utf-8"))
    if raw.get("warmupIterations") != 1_000 or raw.get("sampleIterations") != 10_000:
        raise RuntimeError("measurement iteration counts do not match slo-v1.json")
    report = {
        **raw,
        "measurementPolicy": {
            "allocationCount": "malloc-zone live blocks sampled after decode/apply",
            "mallocBytes": "malloc-zone bytes in use sampled after decode/apply",
            "peakRSS": "getrusage process peak resident bytes",
            "signpostIntervals": ["decode", "apply"],
        },
        "runner": {
            "architecture": architecture_identity(),
            "compiler": swift_compiler_identity(),
            "profile": "release",
            "target": "test-binary",
            "testDefines": ["DEBUG"],
        },
    }
    encoded = canonical_json(report)
    RESULT_PATH.parent.mkdir(parents=True, exist_ok=True)
    RESULT_PATH.write_bytes(encoded)
    return hashlib.sha256(encoded).hexdigest()


def update_slo(reference_digest: str) -> None:
    slo = json.loads(SLO_PATH.read_text(encoding="utf-8"))
    caps_before = json.dumps(slo.get("caps"), sort_keys=True)
    slo["status"] = "absolute-caps-frozen-swift-baseline-captured"
    baseline = slo.setdefault("swiftBaseline", {})
    baseline["status"] = "captured"
    baseline["referenceReport"] = {
        "path": "rust/benchmarks/results/v1/swift-search-reference.json",
        "sha256": reference_digest,
        "sourceImplementation": "swift-search-pre-p1",
    }
    baseline["candidateGate"] = {
        "allocationsCountMaximumReferenceRatio": 1.25,
        "cpuP99MaximumReferenceRatio": 1.10,
        "jitActiveRequiredForEligiblePatterns": True,
        "mallocBytesMaximumReferenceRatio": 1.25,
        "peakRSSMaximumReferenceRatio": 1.25,
        "wallP99MaximumReferenceRatio": 1.10,
    }
    if json.dumps(slo.get("caps"), sort_keys=True) != caps_before:
        raise RuntimeError("refusing to modify frozen P0 absolute caps")
    SLO_PATH.write_text(json.dumps(slo, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def verify_reference_digest() -> None:
    slo = json.loads(SLO_PATH.read_text(encoding="utf-8"))
    reference = slo.get("swiftBaseline", {}).get("referenceReport", {})
    expected = reference.get("sha256")
    if not expected:
        raise RuntimeError("slo-v1.json does not declare the Swift reference digest")
    actual = hashlib.sha256(RESULT_PATH.read_bytes()).hexdigest()
    if actual != expected:
        raise RuntimeError("Swift reference report digest does not match slo-v1.json")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("export", "check", "measure"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.mode == "export":
            with tempfile.TemporaryDirectory(prefix="agentry-swift-baseline-export-") as temporary:
                destination = Path(temporary)
                export_once(destination, skip_build=False)
                import_export(destination)
        elif args.mode == "check":
            with tempfile.TemporaryDirectory(prefix="agentry-swift-baseline-check-a-") as first_raw, tempfile.TemporaryDirectory(
                prefix="agentry-swift-baseline-check-b-"
            ) as second_raw:
                first = Path(first_raw)
                second = Path(second_raw)
                export_once(first, skip_build=False)
                export_once(second, skip_build=True)
                compare_exports(first, second)
            verify_committed_baseline()
            if RESULT_PATH.is_file():
                verify_reference_digest()
        else:
            verify_committed_baseline()
            with tempfile.TemporaryDirectory(prefix="agentry-swift-baseline-measure-") as temporary:
                raw_path = Path(temporary) / "raw-report.json"
                environment = os.environ.copy()
                environment[FIXTURE_ENV] = str(FIXTURE_ROOT)
                environment[MEASURE_ENV] = str(raw_path)
                run_test(MEASURE_FILTER, environment, skip_build=False)
                digest = write_reference_report(raw_path)
                update_slo(digest)
        print(f"Swift search baseline {args.mode} completed.")
        return 0
    except (OSError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Swift search baseline {args.mode} failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
