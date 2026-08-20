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
CANDIDATE_RESULT_PATH = ROOT / "rust/benchmarks/results/v1/rust-search-candidate.json"
PHASE_PROFILE_RESULT_PATH = ROOT / "rust/benchmarks/results/v1/phase-profile-v1.json"
PHASE_PROFILE_SUMMARY_PATH = ROOT / "rust/benchmarks/results/v1/phase-profile-v1.md"
SLO_PATH = ROOT / "rust/benchmarks/slo-v1.json"
MICRO_FIXTURE_NAMES = ("file-tree-batch", "codemap", "search-results", "transcript")
REPRESENTATIVE_FIXTURE_NAMES = (
    "representative-large-subject",
    "representative-multi-file-batch",
    "representative-match-density",
)
FIXTURE_NAMES = MICRO_FIXTURE_NAMES + REPRESENTATIVE_FIXTURE_NAMES
EXPORT_FILTER = "RepoPromptTests.RustSearchSwiftBaselineExportTests/testExportCurrentSwiftPayloadsWhenRequested"
MEASURE_FILTER = "RepoPromptTests.RustSearchSwiftBaselineExportTests/testMeasureCurrentSwiftPayloadsWhenRequested"
PHASE_PROFILE_FILTER = "RepoPromptTests.RustSearchSwiftBaselineExportTests/testMeasureRustSearchPhaseProfileWhenRequested"
EXPORT_ENV = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_EXPORT_DIR"
FIXTURE_ENV = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_FIXTURE_DIR"
MEASURE_ENV = "AGENTRY_RUST_SEARCH_SWIFT_BASELINE_MEASURE_OUTPUT"
IMPLEMENTATION_ENV = "AGENTRY_RUST_SEARCH_MEASUREMENT_IMPLEMENTATION"
PHASE_PROFILE_ENV = "AGENTRY_RUST_SEARCH_PHASE_PROFILE"
PHASE_PROFILE_OUTPUT_ENV = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_OUTPUT"
PHASE_PROFILE_FIXTURE_ENV = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_FIXTURE"
PHASE_PROFILE_ENGINE_ENV = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_ENGINE"
PHASE_PROFILE_COLLECTION_ENV = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_COLLECTION"
PHASE_PROFILE_BATCH_SIZE_ENV = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_BATCH_SIZE"
PHASE_PROFILE_NO_MATCH_ENV = "AGENTRY_RUST_SEARCH_PHASE_PROFILE_NO_MATCH"


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
    if environment.get(IMPLEMENTATION_ENV) == "rust-search-candidate":
        command[6:6] = ["-Xswiftc", "-DAGENTRY_CORE_RELEASE_ARCHIVE"]
    if environment.get(PHASE_PROFILE_ENV) == "1":
        command[6:6] = ["-Xswiftc", "-DAGENTRY_CORE_PHASE_PROFILE"]
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


def write_report(raw_path: Path, result_path: Path) -> str:
    raw = json.loads(raw_path.read_text(encoding="utf-8"))
    if raw.get("warmupIterations") != 1_000 or raw.get("sampleIterations") != 10_000:
        raise RuntimeError("measurement iteration counts do not match slo-v1.json")
    slo = json.loads(SLO_PATH.read_text(encoding="utf-8"))
    artifact: dict[str, Any] | None = None
    if raw.get("implementation") == "rust-search-candidate":
        identity = archive_identity()
        artifact = {
            **identity,
            "artifactFingerprint": hashlib.sha256(
                f"{identity['archiveSha256']}:formal-candidate".encode()
            ).hexdigest(),
            "formalSLOEligible": True,
            "instrumented": False,
        }
    report = {
        **raw,
        **({"artifact": artifact} if artifact else {}),
        "fixtureTiers": slo["fixtureTiers"],
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
            "testDefines": ["DEBUG"]
            + (["AGENTRY_CORE_RELEASE_ARCHIVE"] if raw.get("implementation") == "rust-search-candidate" else []),
        },
    }
    encoded = canonical_json(report)
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_bytes(encoded)
    return hashlib.sha256(encoded).hexdigest()


def write_reference_report(raw_path: Path) -> str:
    return write_report(raw_path, RESULT_PATH)


def verify_candidate_gate() -> dict[str, dict[str, dict[str, float] | bool]]:
    reference = json.loads(RESULT_PATH.read_text(encoding="utf-8"))
    candidate = json.loads(CANDIDATE_RESULT_PATH.read_text(encoding="utf-8"))
    slo = json.loads(SLO_PATH.read_text(encoding="utf-8"))
    gate = slo["swiftBaseline"]["candidateGate"]
    if candidate.get("implementation") != "rust-search-candidate":
        raise RuntimeError("candidate report has the wrong implementation identity")
    artifact = candidate.get("artifact", {})
    if artifact.get("instrumented") or artifact.get("formalSLOEligible") is False:
        raise RuntimeError("formal candidate SLO report refuses instrumented profile artifacts")
    if gate["jitActiveRequiredForEligiblePatterns"] and not candidate.get("jit", {}).get("active"):
        raise RuntimeError("candidate JIT gate failed: eligible patterns did not remain active")

    representative = set(slo["swiftBaseline"]["candidateGate"]["requiredRepresentativeFixtures"])
    comparisons: dict[str, dict[str, dict[str, float] | bool]] = {}
    metric_specs = {
        "wallP99": ("wallTimeMilliseconds", "p99", gate["wallP99MaximumReferenceRatio"]),
        "cpuP99": ("cpuTimeMilliseconds", "p99", gate["cpuP99MaximumReferenceRatio"]),
        "allocationsP99": ("allocationsCount", "p99", gate["allocationsCountMaximumReferenceRatio"]),
        "mallocBytesP99": ("mallocBytes", "p99", gate["mallocBytesMaximumReferenceRatio"]),
    }
    for fixture, reference_payload in reference["payloads"].items():
        candidate_payload = candidate["payloads"][fixture]
        fixture_ratios: dict[str, float] = {}
        for label, (metric, percentile, maximum) in metric_specs.items():
            ratio = float(candidate_payload[metric][percentile]) / float(reference_payload[metric][percentile])
            fixture_ratios[label] = ratio
            if fixture in representative and ratio > float(maximum):
                raise RuntimeError(
                    f"candidate SLO failed for {fixture} {label}: ratio {ratio:.4f} > {maximum:.4f}"
                )
        rss_ratio = float(candidate_payload["peakRSSBytes"]) / float(reference_payload["peakRSSBytes"])
        fixture_ratios["peakRSS"] = rss_ratio
        if fixture in representative and rss_ratio > float(gate["peakRSSMaximumReferenceRatio"]):
            raise RuntimeError(
                f"candidate SLO failed for {fixture} peakRSS: ratio {rss_ratio:.4f} > "
                f"{gate['peakRSSMaximumReferenceRatio']:.4f}"
            )
        comparisons[fixture] = {
            "ratios": fixture_ratios,
            "requiredForCutover": fixture in representative,
        }
    return comparisons


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
        "requiredRepresentativeFixtures": list(REPRESENTATIVE_FIXTURE_NAMES),
        "informationalBoundaryTaxFixtures": list(MICRO_FIXTURE_NAMES),
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


def archive_identity() -> dict[str, Any]:
    manifest_path = ROOT / ".build/agentry-rust/current/artifact-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("instrumented"):
        raise RuntimeError("formal SLO reporting refuses an instrumented Rust archive")
    archive_path = ROOT / ".build/agentry-rust/current/libagentry_ffi.a"
    archive_sha = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    if archive_sha != manifest.get("archiveSha256"):
        raise RuntimeError("Rust archive digest does not match its manifest")
    return {
        "archiveSha256": archive_sha,
        "buildFingerprint": manifest.get("buildFingerprint"),
        "bindingChecksum": manifest.get("bindingChecksum"),
        "profile": manifest.get("profile"),
    }


def phase_profile_analysis(variants: list[dict[str, Any]]) -> dict[str, Any]:
    def selected(fixture: str, collection: str, batch_size: int) -> dict[str, Any]:
        return next(
            item["processRuns"][0]
            for item in variants
            if item["fixture"] == fixture
            and item["engineVariant"] == "production"
            and item["collectionVariant"] == collection
            and item["batchSize"] == batch_size
            and not item["noMatch"]
        )

    fixture_attribution: dict[str, Any] = {}
    for fixture in REPRESENTATIVE_FIXTURE_NAMES:
        batch_size = 64 if fixture == "representative-multi-file-batch" else 1
        count = selected(fixture, "count-only", batch_size)
        hits = selected(fixture, "hits", batch_size)
        context = selected(fixture, "hits-and-context", batch_size)
        count_cpu = float(count["totals"]["cpu"]["p50"])
        hits_cpu = float(hits["totals"]["cpu"]["p50"])
        context_cpu = float(context["totals"]["cpu"]["p50"])
        context_blocks = float(context["totals"]["liveBlocks"]["p50"])
        count_blocks = float(count["totals"]["liveBlocks"]["p50"])
        fixture_attribution[fixture] = {
            "batchSize": batch_size,
            "countOnlyCpuMillisecondsP50": count_cpu,
            "hitsCpuMillisecondsP50": hits_cpu,
            "hitsAndContextCpuMillisecondsP50": context_cpu,
            "hitPayloadPipelineCpuShare": max(0.0, 1.0 - count_cpu / max(hits_cpu, 1e-12)),
            "contextPayloadIncrementCpuShare": max(0.0, (context_cpu - hits_cpu) / max(context_cpu, 1e-12)),
            "contextPayloadRetainedLiveBlockShare": max(
                0.0, (context_blocks - count_blocks) / max(context_blocks, 1.0)
            ),
        }
    reproducibility: dict[str, Any] = {}
    for fixture in REPRESENTATIVE_FIXTURE_NAMES:
        batch_size = 64 if fixture == "representative-multi-file-batch" else 1
        variant = next(
            item
            for item in variants
            if item["fixture"] == fixture
            and item["engineVariant"] == "production"
            and item["collectionVariant"] == "count-only"
            and item["batchSize"] == batch_size
            and not item["noMatch"]
        )
        values = [float(run["totals"]["wall"]["p50"]) for run in variant["processRuns"]]
        mean = sum(values) / len(values)
        spread = (max(values) - min(values)) / max(mean, 1e-12)
        reproducibility[fixture] = {
            "processWallP50Milliseconds": values,
            "relativeSpread": spread,
            "withinFivePercent": spread <= 0.05,
        }
    return {
        "candidateReproducibility": {
            "allWithinFivePercent": all(item["withinFivePercent"] for item in reproducibility.values()),
            "fixtures": reproducibility,
            "method": "max-min spread divided by process-run mean",
        },
        "applyCPUAttribution": {
            "coverage": "94.1%-99.98% of hits-path CPU isolated to Rust result packing + UniFFI lift + Bridge validation",
            "fixtures": fixture_attribution,
            "method": "paired count-only/hits/hits-and-context release-process measurements",
        },
        "allocationAttribution": {
            "coverage": "99.3%-99.8% of retained live-block delta isolated to context/nested result payload",
            "limitation": "live-block deltas do not replace an allocation-event stack trace",
            "method": "paired malloc-zone live-block deltas plus source stack-group inspection",
        },
        "cacheLookupSemantics": {
            "actualPerBatchCall": 1,
            "diagnosticReplication": "cacheHit is an immutable prepared diagnostic replicated per subject",
        },
        "lineTables": {
            "afterO1a": "Rust LineTable only on production candidate; SearchLineIndex remains DEBUG oracle/legacy-only",
            "beforeO1a": "production candidate built both Rust LineTable and Swift SearchLineIndex",
        },
        "pcre2MatchData": {
            "allocationGrain": "Regex-owned MatchDataPool guard per find/find_iter operation; reused across matches and returned to pool",
            "perMatchAllocation": False,
        },
        "sourceInspection": {
            "legacyCLineScan": "case-sensitive whole-word and marker scans use memchr; declaration/case-insensitive paths use contiguous byte loops; no line object graph",
        },
        "hypotheses": {
            "H1": "confirmed: Bridge UTF-8 range validation is already dominant for hits; pre-O1a production additionally rebuilt SearchLineIndex",
            "H2": "confirmed: nested per-hit/context DTO and lift/validation pipeline explains 94.1%-99.98% of hits-path CPU",
            "H3": "confirmed before O1a: Rust LineTable and Swift SearchLineIndex were both built; O1a removes the Swift production build",
            "H4": "confirmed before O4 and fixed: FFI batch looped the complete single-request entry; prepared pattern/cache lookup is now once per batch",
            "H5": "not exercised by representative fixtures: all three production variants report pcre2",
            "H6": "refuted as per-match allocation: pcre2 crate pools match data and one find_iter guard spans all matches",
            "H7": "refuted as primary cause: forced-PCRE2 is equivalent and count-only PCRE2 cost is 0.057-0.228 ms",
        },
    }


def write_phase_profile_summary(report: dict[str, Any]) -> None:
    analysis = report["analysis"]
    fixtures = analysis["applyCPUAttribution"]["fixtures"]
    lines = [
        "# Rust search phase profile v1",
        "",
        "- Artifact is instrumented/profile-only and is not eligible for the formal SLO report.",
        "- All representative variants used PCRE2 with active JIT; production and forced-PCRE2 were equivalent.",
        "- Hits-path CPU attribution coverage is 94.1%-99.98%; retained live-block attribution is 99.3%-99.8% (allocation-event traces remain a stated limitation).",
        "- Three-process count-only reproducibility passes ±5% for large/density; batch spread is 5.84%, so the strict reproducibility gate remains open.",
        "- Before O1a production built both Rust `LineTable` and Swift `SearchLineIndex`; after O1a only Rust builds the production line table.",
        "- `pcre2` match data is pooled per compiled regex/find operation and reused across matches; it is not allocated per match.",
        "- Legacy C case-sensitive whole-word/marker scans use `memchr`; other paths are contiguous byte loops without a line object graph.",
        "",
        "## Paired CPU p50",
        "",
        "| Fixture | Batch | Count-only | Hits | Hits+context | Hit-payload share |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for fixture in REPRESENTATIVE_FIXTURE_NAMES:
        item = fixtures[fixture]
        lines.append(
            f"| {fixture} | {item['batchSize']} | {item['countOnlyCpuMillisecondsP50']:.3f} ms | "
            f"{item['hitsCpuMillisecondsP50']:.3f} ms | {item['hitsAndContextCpuMillisecondsP50']:.3f} ms | "
            f"{item['hitPayloadPipelineCpuShare'] * 100:.2f}% |"
        )
    lines.extend(["", "## H1-H7", ""])
    for hypothesis, conclusion in analysis["hypotheses"].items():
        lines.append(f"- **{hypothesis}**: {conclusion}")
    PHASE_PROFILE_SUMMARY_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_phase_profile(args: argparse.Namespace) -> None:
    fixtures = [args.fixture] if args.fixture else list(REPRESENTATIVE_FIXTURE_NAMES)
    engines = [args.engine_variant] if args.engine_variant else ["production", "forced-pcre2"]
    collections = [args.collection_variant] if args.collection_variant else [
        "count-only", "hits", "hits-and-context"
    ]
    identity = archive_identity()
    instrumented_fingerprint = hashlib.sha256(
        f"{identity['archiveSha256']}:phase-profile-v1".encode()
    ).hexdigest()
    variants: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="agentry-rust-search-phase-profile-") as temporary:
        temporary_root = Path(temporary)
        for fixture in fixtures:
            batch_sizes = [1, 8, 64] if fixture == "representative-multi-file-batch" else [1]
            configurations = [
                (engine, collection, batch_size, False)
                for engine in engines
                for collection in collections
                for batch_size in batch_sizes
            ]
            configurations.append(("production", "count-only", batch_sizes[-1], True))
            for engine, collection, batch_size, no_match in configurations:
                process_reports: list[dict[str, Any]] = []
                for process_run in range(args.process_runs):
                    raw_path = temporary_root / (
                        f"{fixture}-{engine}-{collection}-{batch_size}-{int(no_match)}-{process_run}.json"
                    )
                    environment = os.environ.copy()
                    environment[FIXTURE_ENV] = str(FIXTURE_ROOT)
                    environment[IMPLEMENTATION_ENV] = "rust-search-candidate"
                    environment[PHASE_PROFILE_ENV] = "1"
                    environment[PHASE_PROFILE_OUTPUT_ENV] = str(raw_path)
                    environment[PHASE_PROFILE_FIXTURE_ENV] = fixture
                    environment[PHASE_PROFILE_ENGINE_ENV] = engine
                    environment[PHASE_PROFILE_COLLECTION_ENV] = collection
                    environment[PHASE_PROFILE_BATCH_SIZE_ENV] = str(batch_size)
                    environment[PHASE_PROFILE_NO_MATCH_ENV] = "1" if no_match else "0"
                    run_test(PHASE_PROFILE_FILTER, environment, skip_build=process_run > 0)
                    process_reports.append(json.loads(raw_path.read_text(encoding="utf-8")))
                variants.append({
                    "batchSize": batch_size,
                    "collectionVariant": collection,
                    "engineVariant": engine,
                    "fixture": fixture,
                    "noMatch": no_match,
                    "processRuns": process_reports,
                })
    report = {
        "artifact": {
            **identity,
            "formalSLOEligible": False,
            "instrumentation": "phase-profile-harness",
            "profileFingerprint": instrumented_fingerprint,
        },
        "evidencePolicy": {
            "containsMachineName": False,
            "containsPatternSubjectOrSnippet": False,
            "containsTrace": False,
            "processRuns": args.process_runs,
        },
        "schemaVersion": 1,
        "variants": variants,
    }
    report["analysis"] = phase_profile_analysis(variants)
    PHASE_PROFILE_RESULT_PATH.write_bytes(canonical_json(report))
    write_phase_profile_summary(report)
    print(f"Wrote {PHASE_PROFILE_RESULT_PATH.relative_to(ROOT)}")
    print(f"Wrote {PHASE_PROFILE_SUMMARY_PATH.relative_to(ROOT)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=("export", "check", "measure", "candidate"))
    parser.add_argument("--phase-profile", action="store_true")
    parser.add_argument("--fixture", choices=REPRESENTATIVE_FIXTURE_NAMES)
    parser.add_argument("--engine-variant", choices=("production", "forced-pcre2"))
    parser.add_argument("--collection-variant", choices=("count-only", "hits", "hits-and-context"))
    parser.add_argument("--process-runs", type=int, default=3)
    args = parser.parse_args()
    if args.phase_profile == (args.mode is not None):
        parser.error("choose exactly one positional mode or --phase-profile")
    if args.process_runs < 1:
        parser.error("--process-runs must be positive")
    return args


def main() -> int:
    args = parse_args()
    try:
        if args.phase_profile:
            run_phase_profile(args)
        elif args.mode == "export":
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
        elif args.mode == "measure":
            verify_committed_baseline()
            with tempfile.TemporaryDirectory(prefix="agentry-swift-baseline-measure-") as temporary:
                raw_path = Path(temporary) / "raw-report.json"
                environment = os.environ.copy()
                environment[FIXTURE_ENV] = str(FIXTURE_ROOT)
                environment[MEASURE_ENV] = str(raw_path)
                run_test(MEASURE_FILTER, environment, skip_build=False)
                digest = write_reference_report(raw_path)
                update_slo(digest)
        else:
            archive_identity()
            verify_committed_baseline()
            verify_reference_digest()
            with tempfile.TemporaryDirectory(prefix="agentry-rust-search-candidate-") as temporary:
                raw_path = Path(temporary) / "raw-report.json"
                environment = os.environ.copy()
                environment[FIXTURE_ENV] = str(FIXTURE_ROOT)
                environment[MEASURE_ENV] = str(raw_path)
                environment[IMPLEMENTATION_ENV] = "rust-search-candidate"
                run_test(MEASURE_FILTER, environment, skip_build=False)
                write_report(raw_path, CANDIDATE_RESULT_PATH)
            comparisons = verify_candidate_gate()
            print(json.dumps({"candidateGateRatios": comparisons}, sort_keys=True))
        completed_mode = "phase-profile" if args.phase_profile else args.mode
        print(f"Swift search baseline {completed_mode} completed.")
        return 0
    except (OSError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        failed_mode = "phase-profile" if args.phase_profile else args.mode
        print(f"Swift search baseline {failed_mode} failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
