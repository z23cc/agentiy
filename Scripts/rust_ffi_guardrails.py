#!/usr/bin/env python3
"""Fast, offline guardrails for the Phase 0 Rust FFI foundation."""

from __future__ import annotations

import json
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
RUST = ROOT / "rust"
EXPECTED_MEMBERS = [
    "crates/proto",
    "crates/runtime",
    "crates/ffi",
    "tools/xtask",
]
EXPECTED_DEFAULT_MEMBERS = ["crates/proto", "crates/runtime", "crates/ffi"]
PRODUCT_MANIFESTS = {
    "agentry-proto": RUST / "crates/proto/Cargo.toml",
    "agentry-runtime": RUST / "crates/runtime/Cargo.toml",
    "agentry-ffi": RUST / "crates/ffi/Cargo.toml",
}


def load_toml(path: Path, failures: list[str]) -> dict[str, Any]:
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        failures.append(f"cannot read valid TOML {path.relative_to(ROOT)}: {error}")
        return {}


def dependency_names(manifest: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for table_name in ("dependencies", "dev-dependencies", "build-dependencies"):
        table = manifest.get(table_name, {})
        if isinstance(table, dict):
            names.update(table)
    return names


def main() -> int:
    failures: list[str] = []
    required_paths = [
        RUST / "Cargo.toml",
        RUST / "Cargo.lock",
        RUST / "rust-toolchain.toml",
        RUST / ".cargo/config.toml",
        RUST / "deny.toml",
        RUST / "audit.toml",
        RUST / "ffi-contract/abi-v1.json",
        RUST / "ffi-contract/exports.txt",
        RUST / "benchmarks/slo-v1.json",
        ROOT / "Scripts/extract_rust_ffi_baselines.py",
    ]
    required_paths.extend(PRODUCT_MANIFESTS.values())
    for path in required_paths:
        if not path.is_file():
            failures.append(f"required file missing: {path.relative_to(ROOT)}")

    workspace = load_toml(RUST / "Cargo.toml", failures)
    workspace_table = workspace.get("workspace", {})
    if workspace_table.get("members") != EXPECTED_MEMBERS:
        failures.append("rust/Cargo.toml workspace members drifted from the frozen member patterns")
    if workspace_table.get("default-members") != EXPECTED_DEFAULT_MEMBERS:
        failures.append("rust/Cargo.toml default-members must contain only proto/runtime/ffi")
    if workspace_table.get("resolver") != "3":
        failures.append("rust/Cargo.toml must use resolver = 3")

    workspace_package = workspace.get("workspace", {}).get("package", {})
    if workspace_package.get("rust-version") != "1.97.1":
        failures.append("workspace rust-version must match the pinned 1.97.1 toolchain")

    workspace_dependencies = workspace.get("workspace", {}).get("dependencies", {})
    for name in ("uniffi", "uniffi_bindgen"):
        if workspace_dependencies.get(name) != "=0.32.0":
            failures.append(f"workspace dependency {name} must be pinned to =0.32.0")

    for profile_name in ("dev", "release"):
        profile = workspace.get("profile", {}).get(profile_name, {})
        if profile.get("panic") != "unwind":
            failures.append(f"profile.{profile_name}.panic must be unwind")
    for profile_name in ("test", "bench"):
        if "panic" in workspace.get("profile", {}).get(profile_name, {}):
            failures.append(f"profile.{profile_name}.panic must be omitted because Cargo ignores it")
    release = workspace.get("profile", {}).get("release", {})
    if release.get("debug") != 2 or release.get("strip") is not False:
        failures.append("release profile must retain debug = 2 and strip = false")

    product_dependencies: dict[str, set[str]] = {}
    for expected_name, path in PRODUCT_MANIFESTS.items():
        manifest = load_toml(path, failures)
        if manifest.get("package", {}).get("name") != expected_name:
            failures.append(f"{path.relative_to(ROOT)} package name must be {expected_name}")
        product_dependencies[expected_name] = dependency_names(manifest)

    if "agentry-proto" not in product_dependencies.get("agentry-runtime", set()):
        failures.append("agentry-runtime must depend on agentry-proto")
    ffi_dependencies = product_dependencies.get("agentry-ffi", set())
    if not {"agentry-proto", "agentry-runtime", "uniffi"}.issubset(ffi_dependencies):
        failures.append("agentry-ffi must depend on proto/runtime/uniffi")
    for package, dependencies in product_dependencies.items():
        uniffi_dependencies = {name for name in dependencies if name.startswith("uniffi")}
        if package == "agentry-ffi":
            if uniffi_dependencies != {"uniffi"}:
                failures.append("agentry-ffi may use only the uniffi umbrella product dependency")
        elif uniffi_dependencies:
            failures.append(f"{package} must not depend on UniFFI")

    ffi_manifest = load_toml(PRODUCT_MANIFESTS["agentry-ffi"], failures)
    if ffi_manifest.get("lib", {}).get("crate-type") != ["staticlib"]:
        failures.append("agentry-ffi crate-type must be staticlib only")

    # P6-4 (docs/architecture/rust-agent-claude-v1.md §5.1/§5.2/§12, design §4.1): the process
    # supervisor is built entirely on plain threads + a shared kqueue reaper, deliberately without
    # any new tokio feature (tokio::process is rejected; see the contract's §5.1). A silent tokio
    # feature addition here would be exactly the kind of dependency-surface drift the design's own
    # "no new tokio features, asserted by a guardrail check" P6-4 done-when line exists to catch.
    runtime_manifest = load_toml(PRODUCT_MANIFESTS["agentry-runtime"], failures)
    tokio_dependency = runtime_manifest.get("dependencies", {}).get("tokio", {})
    if not isinstance(tokio_dependency, dict) or sorted(tokio_dependency.get("features", [])) != [
        "macros",
        "rt",
        "sync",
        "time",
    ]:
        failures.append(
            "agentry-runtime's tokio features must stay exactly {macros, rt, sync, time} -- "
            "P6-4's process supervisor deliberately needs no new tokio feature (process/signal/net)"
        )
    nix_dependency = runtime_manifest.get("dependencies", {}).get("nix", {})
    if not isinstance(nix_dependency, dict) or sorted(nix_dependency.get("features", [])) != [
        "event",
        "fs",
        "process",
        "signal",
    ]:
        failures.append(
            "agentry-runtime's nix features must stay exactly {event, fs, process, signal} -- "
            "the P6-1-pinned set the spawner/reaper need, no more"
        )

    # P6-4: exactly two `#[allow(unsafe_code)]` sites are confirmed prerequisites --
    # `agent_claude::process::addchdir` (the `posix_spawn_file_actions_addchdir_np` extern "C"
    # binding) and `agent_claude::process::reaper::waitid_probe` (a second Apple-specific `nix`
    # gap found during P6-2, wrapping the already-declared `libc::waitid`). A third site anywhere
    # in `agentry-runtime`'s `src/` would be an unreviewed expansion of the crate's `unsafe_code`
    # exception, which this crate declined `[lints] workspace = true` specifically to keep narrow
    # (see `rust/crates/runtime/Cargo.toml`'s own comment).
    unsafe_allow_sites: list[str] = []
    for path in sorted((RUST / "crates/runtime/src").rglob("*.rs")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for line_number, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            # Only a real attribute counts -- doc comments (`///`, `//!`) that merely *mention*
            # `#[allow(unsafe_code)]` in prose (as this file's own module docs do, describing where
            # the sites live) must not be counted as a third/fourth site.
            if stripped.startswith("#[allow(unsafe_code)") or stripped.startswith("#![allow(unsafe_code)"):
                unsafe_allow_sites.append(f"{path.relative_to(ROOT)}:{line_number}")
    expected_unsafe_allow_sites = {
        "rust/crates/runtime/src/agent_claude/process/addchdir.rs",
        "rust/crates/runtime/src/agent_claude/process/reaper.rs",
    }
    actual_files = {site.split(":", 1)[0] for site in unsafe_allow_sites}
    if len(unsafe_allow_sites) != 2 or actual_files != expected_unsafe_allow_sites:
        failures.append(
            "agentry-runtime's src/ must contain exactly two #[allow(unsafe_code)] sites "
            f"({sorted(expected_unsafe_allow_sites)}); found {unsafe_allow_sites}"
        )
    lib_rs_text = (RUST / "crates/runtime/src/lib.rs").read_text(encoding="utf-8", errors="replace")
    if "#![deny(unsafe_code)]" not in lib_rs_text or "#![forbid(unsafe_code)]" in lib_rs_text:
        failures.append(
            "rust/crates/runtime/src/lib.rs must carry #![deny(unsafe_code)] (not forbid) -- "
            "P6-4's two scoped #[allow(unsafe_code)] exceptions require deny, not forbid"
        )

    xtask = load_toml(RUST / "tools/xtask/Cargo.toml", failures)
    xtask_dependencies = dependency_names(xtask)
    if "uniffi_bindgen" not in xtask_dependencies:
        failures.append("xtask must own the exact-version UniFFI bindgen dependency")

    toolchain = load_toml(RUST / "rust-toolchain.toml", failures).get("toolchain", {})
    if toolchain.get("channel") != "1.97.1":
        failures.append("rust-toolchain.toml channel must be exactly 1.97.1")
    if toolchain.get("targets") != ["aarch64-apple-darwin"]:
        failures.append("rust-toolchain.toml must contain only the arm64 Apple target")
    if toolchain.get("components") != ["rustfmt", "clippy"] or toolchain.get("profile") != "minimal":
        failures.append("rust-toolchain.toml components/profile drifted")

    cargo_config = load_toml(RUST / ".cargo/config.toml", failures)
    if cargo_config != {
        "build": {
            "target": "aarch64-apple-darwin",
            "target-dir": "../../.build/cargo",
        }
    }:
        failures.append("rust/.cargo/config.toml must contain only the frozen arm64 build target and target-dir")

    lockfile = RUST / "Cargo.lock"
    if lockfile.is_file():
        if "version = 4" not in lockfile.read_text(encoding="utf-8", errors="replace"):
            failures.append("rust/Cargo.lock must be a Cargo v4 lockfile")
        ignored = subprocess.run(
            ["git", "check-ignore", "-q", "rust/Cargo.lock"], cwd=ROOT, check=False
        )
        if ignored.returncode == 0:
            failures.append("rust/Cargo.lock must not be ignored")
    if (RUST / "target").exists():
        failures.append("rust/target must not exist; use the controlled target directory")

    try:
        abi = json.loads((RUST / "ffi-contract/abi-v1.json").read_text(encoding="utf-8"))
        if abi.get("abiEpoch") != 1 or abi.get("envelope", {}).get("schemaVersion") != 1:
            failures.append("ABI epoch and envelope schema must both be 1")
        if abi.get("supportedTargets") != ["aarch64-apple-darwin"]:
            failures.append("ABI contract must support only aarch64-apple-darwin")
        if abi.get("envelope", {}).get("maximumEnvelopeBytes") != 1_048_576:
            failures.append("ABI contract maximum envelope must be 1 MiB")
    except (OSError, json.JSONDecodeError) as error:
        failures.append(f"cannot read valid ABI contract: {error}")

    fixture_check = subprocess.run(
        [sys.executable, "Scripts/extract_rust_ffi_baselines.py", "--check"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if fixture_check.returncode != 0:
        detail = fixture_check.stderr.strip() or fixture_check.stdout.strip()
        failures.append(f"deterministic fixture check failed: {detail}")

    if failures:
        print("Rust FFI guardrails failed:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print("Rust FFI guardrails passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
