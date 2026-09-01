#!/usr/bin/env python3
"""Fast, offline guardrails for the Phase 0 Rust FFI foundation."""

from __future__ import annotations

import json
import re
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


# --- Export-inventory completeness (ADR-0001 G1 "raw export inventory") ---------------------
#
# `rust/ffi-contract/exports.txt` is the hand-authored capability-boundary inventory that
# ADR-0001's G1 Contract gate cites as evidence for "UniFFI is accepted only for these
# capabilities". Nothing verified it against the real export surface, so it silently stopped
# being maintained around P4/P7: 48 entries are declared while the generated header exposes
# 148 method/constructor exports.
#
# The generated C header is the authoritative, machine-produced inventory -- UniFFI emits one
# `uniffi_agentry_ffi_checksum_{kind}_{owner}_{fn}` symbol per export, and
# `xtask generate --check` already proves the committed header is byte-identical to a clean
# regeneration. This check derives the actual surface from it and fails when a NEW export
# appears that exports.txt does not claim.
#
# Direction matters: `Owner.methodName` -> `owner_method_name` is deterministic, while the
# reverse is not (`corepreparedworkspacecommandadmissionv1` cannot be recovered to its
# original casing). So we lower/snake the DECLARED entries and check the actual symbols are
# claimed -- never the other way round.
#
# Free functions (`_func_` kind) are skipped: exports.txt's `Owner.method(...)` grammar has no
# form for them.
#
# ponytail: the 100 pre-existing unregistered exports are pinned below rather than backfilled.
# Backfilling exports.txt rotates bindingChecksum (sha256(abi-v1.json || 0x00 || exports.txt))
# AND buildFingerprint (exports.txt is in xtask's BUILD_INPUT_PATHS), which invalidates the
# committed AgentryCoreBindingIdentity.swift and fails every raw call with staleRuntimeIdentity
# until `cargo run -p xtask -- generate` plus an archive rebuild land together. That is a
# maintainer change with its own regen/rebuild/test cycle, not a guardrail edit. Upgrade path:
# backfill the signatures, regenerate, then delete this baseline entirely.
UNREGISTERED_EXPORT_BASELINE = {
    "corepreparedworkspacecommandadmissionv1_acquire",
    "corepreparedworkspacecommandadmissionv1_authority_read",
    "corepreparedworkspacecommandadmissionv1_begin_external_observation_recovery_transaction",
    "corepreparedworkspacecommandadmissionv1_close",
    "corepreparedworkspacecommandadmissionv1_diagnostics",
    "corepreparedworkspacecommandadmissionv1_prepare_external_observation_recovery",
    "corepreparedworkspacecommandadmissionv1_prepare_semantic_full_recovery",
    "corepreparedworkspacecommandadmissionv1_prepare_semantic_target_recovery",
    "corepreparedworkspacecommandadmissionv1_publish_authority_state",
    "corepreparedworkspacecommandadmissionv1_synchronize_authority_projection",
    "corepreparedworkspacecreatetransactionv1_acquire_authority_permit",
    "corepreparedworkspacecreatetransactionv1_close",
    "corepreparedworkspacecreatetransactionv1_finish_command_authority",
    "corepreparedworkspacecreatetransactionv1_next_directive",
    "corepreparedworkspacecreatetransactionv1_report_action",
    "corepreparedworkspacedeletetransactionv1_acquire_authority_permit",
    "corepreparedworkspacedeletetransactionv1_close",
    "corepreparedworkspacedeletetransactionv1_finish_command_authority",
    "corepreparedworkspacedeletetransactionv1_next_directive",
    "corepreparedworkspacedeletetransactionv1_plan_cleanup",
    "corepreparedworkspacedeletetransactionv1_report_action",
    "corepreparedworkspacejournalmutationtransactionv1_acquire_authority_permit",
    "corepreparedworkspacejournalmutationtransactionv1_close",
    "corepreparedworkspacejournalmutationtransactionv1_finish_claimless_authority_publication",
    "corepreparedworkspacejournalmutationtransactionv1_finish_command_authority",
    "corepreparedworkspacejournalmutationtransactionv1_next_directive",
    "corepreparedworkspacejournalmutationtransactionv1_report_action",
    "corepreparedworkspacesavetransactionv1_acquire_authority_permit",
    "corepreparedworkspacesavetransactionv1_close",
    "corepreparedworkspacesavetransactionv1_finish_command_authority",
    "corepreparedworkspacesavetransactionv1_next_directive",
    "corepreparedworkspacesavetransactionv1_report_action",
    "corepreparedworkspacesemanticrecoveryv1_close",
    "corepreparedworkspacesemanticrecoveryv1_commit",
    "corepreparedworkspacesemanticrecoveryv1_preview",
    "coreruntime_agent_provider_acp_cancel",
    "coreruntime_agent_provider_acp_notify",
    "coreruntime_agent_provider_acp_request",
    "coreruntime_agent_provider_acp_respond",
    "coreruntime_agent_provider_acp_respond_error",
    "coreruntime_agent_provider_acp_state",
    "coreruntime_agent_provider_codex_cancel",
    "coreruntime_agent_provider_codex_notify",
    "coreruntime_agent_provider_codex_request",
    "coreruntime_agent_provider_codex_respond",
    "coreruntime_agent_provider_codex_respond_error",
    "coreruntime_agent_provider_codex_state",
    "coreruntime_agent_provider_conformance_snapshot",
    "coreruntime_agent_provider_open_scope",
    "coreruntime_agent_provider_send_line",
    "coreruntime_agent_provider_shutdown",
    "coreruntime_agent_provider_start",
    "coreruntime_agent_provider_start_with_stdin",
    "coreruntime_agent_provider_validate_conformance",
    "coreruntime_file_system_watcher_capture_watermark",
    "coreruntime_file_system_watcher_close_scope",
    "coreruntime_file_system_watcher_ingest",
    "coreruntime_file_system_watcher_open_scope",
    "coreruntime_file_system_watcher_reset",
    "coreruntime_file_system_watcher_snapshot",
    "coreruntime_file_system_watcher_start_accepting",
    "coreruntime_file_system_watcher_take_next",
    "coreruntime_inventory_apply_delta_discovery_v1",
    "coreruntime_inventory_close_composed_snapshot",
    "coreruntime_inventory_composed_snapshot_page",
    "coreruntime_inventory_open_composed_snapshot",
    "coreruntime_inventory_push_bulk_chunk_discovery",
    "coreruntime_inventory_resolve_records_scope_wide",
    "coreruntime_inventory_set_file_managed_only",
    "coreruntime_inventory_set_folder_managed_only",
    "coreruntime_panic_forensics",
    "coreruntime_path_match_locate_many_v1",
    "coreruntime_path_match_score_v1",
    "coreruntime_path_search_find_v1",
    "coreruntime_text_decode_v1",
    "coreruntime_token_accounting_v1",
    "coreruntime_workspace_catalog_seed_v1",
    "coreruntime_workspace_catalog_validate_v1",
    "coreruntime_workspace_command_identity_v1",
    "coreruntime_workspace_create_transaction_begin_v1",
    "coreruntime_workspace_delete_transaction_begin_v1",
    "coreruntime_workspace_deletion_tombstone_validate_v1",
    "coreruntime_workspace_document_projection_v1",
    "coreruntime_workspace_journal_mutation_transaction_begin_v1",
    "coreruntime_workspace_pending_save_resolve_v1",
    "coreruntime_workspace_save_transaction_begin_v1",
    "coreruntime_workspace_saved_revision_validate_v1",
    "coreruntime_workspace_semantic_initial_recovery_prepare_v1",
    "coreruntime_workspace_working_journal_seed_v1",
    "coreruntime_workspace_working_journal_validate_v1",
    "coreworkspacecommandexecutionclaimv1_abandon",
    "coreworkspacecommandexecutionclaimv1_checkpoint",
    "coreworkspacecommandexecutionclaimv1_close",
    "coreworkspacecommandexecutionclaimv1_finalize_transient",
    "coreworkspacecommandexecutionclaimv1_fingerprint",
    "coreworkspacecommandexecutionclaimv1_generation",
    "coreworkspacecommandexecutionclaimv1_operation_id",
    "coreworkspacecommandexecutionclaimv1_semantic_preflight",
    "coreworkspacecommandexecutionclaimv1_workspace_id",
    "coreworkspacecreateauthoritypermitv1_close",
}


def camel_to_snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def declared_export_keys(text: str) -> set[str]:
    """`CoreRuntime.agentOpenScope(...) throws -> X` -> `coreruntime_agent_open_scope`."""
    keys: set[str] = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"([A-Za-z0-9]+)\.([A-Za-z0-9]+)", line)
        if match:
            owner, method = match.groups()
            keys.add(f"{owner.lower()}_{camel_to_snake(method)}")
    return keys


def check_fuzz_target_coverage(failures: list[str]) -> None:
    """Every declared fuzz target must actually run in CI.

    Same failure class as the export inventory above: a hand-maintained list (ci.yml's fuzz
    steps) silently drifting from the real surface (rust/fuzz/Cargo.toml's declared targets).
    This drifted for real -- `agent_command_v1` and `claude_ndjson_v1` were added the same day
    (2026-08-24); only the latter was wired into CI, so the one hand-rolled wire decode in the
    Claude vertical went unfuzzed while `rust-ffi.md` still advertised "five bounded fuzz jobs".
    ADR-0007 makes fuzz/advisory coverage a fail-closed CI gate, so an unrun target is a gate
    hole, not a cosmetic gap.

    Ceiling: the declared surface is `rust/fuzz/Cargo.toml`'s `[[bin]]` list, so a
    `fuzz_targets/*.rs` file with no `[[bin]]` entry is invisible here (it is also unbuildable
    by `cargo fuzz`, so it cannot silently pass CI either). Verified 9/9 in sync at the time
    this check landed.
    """
    manifest_path = RUST / "fuzz/Cargo.toml"
    workflow_path = ROOT / ".github/workflows/ci.yml"
    manifest = load_toml(manifest_path, failures)
    if not manifest:
        return
    try:
        workflow = workflow_path.read_text(encoding="utf-8")
    except OSError as error:
        failures.append(f"cannot read {workflow_path.relative_to(ROOT)}: {error}")
        return

    declared = {
        binary["name"]
        for binary in manifest.get("bin", [])
        if isinstance(binary, dict) and "name" in binary
    }
    if not declared:
        failures.append(
            "rust/fuzz/Cargo.toml declares no [[bin]] fuzz targets; the coverage check cannot "
            "run fail-closed"
        )
        return

    invoked = set(re.findall(r"cargo fuzz run ([A-Za-z0-9_]+)", workflow))
    for name in sorted(declared - invoked):
        failures.append(
            f"fuzz target `{name}` is declared in rust/fuzz/Cargo.toml but never run in "
            ".github/workflows/ci.yml (ADR-0007 fail-closed fuzz coverage); add a "
            "`cargo fuzz run` step"
        )
    for name in sorted(invoked - declared):
        failures.append(
            f".github/workflows/ci.yml runs fuzz target `{name}`, which rust/fuzz/Cargo.toml "
            "does not declare; the CI step will fail"
        )


def check_export_inventory(failures: list[str]) -> None:
    header = ROOT / "Sources/CAgentryRustCore/include/AgentryCoreFFI.h"
    exports = RUST / "ffi-contract/exports.txt"
    try:
        header_text = header.read_text(encoding="utf-8")
        exports_text = exports.read_text(encoding="utf-8")
    except OSError as error:
        failures.append(f"cannot read generated header or export inventory: {error}")
        return

    actual = set(
        re.findall(
            r"uniffi_agentry_ffi_checksum_(?:method|constructor)_([a-z0-9_]+)", header_text
        )
    )
    if not actual:
        failures.append(
            "no UniFFI checksum symbols found in AgentryCoreFFI.h; the export-inventory "
            "completeness check cannot run fail-closed"
        )
        return

    declared = declared_export_keys(exports_text)

    # Self-check for the Owner.method -> owner_method_name mapping above. Every declared entry
    # must resolve to a real symbol; an orphan means either exports.txt claims a capability that
    # is not exported (an inventory-integrity bug) or this parser's casing rule has drifted from
    # UniFFI's. Without this arm a broken mapping would degrade silently into "everything is
    # unregistered" with no indication of the real cause.
    for name in sorted(declared - actual):
        failures.append(
            f"exports.txt declares `{name}`, which matches no UniFFI export symbol; either the "
            "entry is stale or Owner.method -> owner_method_name mapping drifted"
        )

    unclaimed = actual - declared - UNREGISTERED_EXPORT_BASELINE
    for name in sorted(unclaimed):
        failures.append(
            f"FFI export `{name}` is exported across the boundary but not registered in "
            "rust/ffi-contract/exports.txt (ADR-0001 G1 capability-boundary inventory); "
            "add its signature line, then regenerate identity artifacts"
        )

    stale = UNREGISTERED_EXPORT_BASELINE - actual
    for name in sorted(stale):
        failures.append(
            f"UNREGISTERED_EXPORT_BASELINE lists `{name}`, which no longer exists; "
            "remove it from the baseline"
        )

    redundant = UNREGISTERED_EXPORT_BASELINE & declared
    for name in sorted(redundant):
        failures.append(
            f"`{name}` is now registered in exports.txt; remove it from "
            "UNREGISTERED_EXPORT_BASELINE"
        )


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

    check_export_inventory(failures)
    check_fuzz_target_coverage(failures)

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
