#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failures=0
fail() {
  printf 'ERROR: %s\n' "$*" >&2
  failures=$((failures + 1))
}

print_matches() {
  local label="$1"
  shift
  local output
  output="$($@ 2>/dev/null || true)"
  if [[ -n "$output" ]]; then
    fail "$label"
    printf '%s\n' "$output" >&2
  fi
}

# 0. Required layout roots/files should exist before negative scans run.
required_dirs=(
  "Sources/RepoPromptExecutable"
  "Sources/RepoPrompt/Features"
  "Sources/RepoPrompt/Infrastructure"
  "Sources/RepoPrompt/Infrastructure/SyntaxParsing"
  "Sources/RepoPromptShared/MCP"
  "Sources/RepoPromptWorkspaceCore"
  "Sources/RepoPromptSearchCore"
  "Sources/RepoPromptDomainRuntime"
  "Sources/CAgentryRustCore"
  "Sources/AgentryUniFFIRaw/Generated"
  "Sources/AgentryCoreBridge"
  "Tests/AgentryCoreBridgeTests"
  "Tests/RepoPromptTests"
  "Tests/RepoPromptWorkspaceCoreTests"
  "Tests/RepoPromptSearchCoreTests"
  "Tests/RepoPromptDomainRuntimeTests"
)
for dir in "${required_dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    fail "required source layout directory missing: $dir"
  fi
done

removed_regex_paths=(
  "Sources/RepoPromptRegexCore"
  "Sources/CSwiftPCRE2"
  "Tests/RepoPromptRegexCoreTests"
)
for path in "${removed_regex_paths[@]}"; do
  if [[ -e "$path" ]]; then
    fail "removed legacy regex path exists: $path"
  fi
done
if grep -R -n -E 'RepoPromptRegexCore|CSwiftPCRE2' Package.swift Sources Tests \
  --exclude='*.pyc' >/tmp/agentry-removed-regex-matches 2>/dev/null; then
  fail "removed legacy regex target or module reference returned"
  cat /tmp/agentry-removed-regex-matches >&2
fi

allowed_rust_top_level_entries=(
  ".cargo"
  "Cargo.lock"
  "Cargo.toml"
  "audit.toml"
  "benchmarks"
  "crates"
  "deny.toml"
  "ffi-contract"
  "fuzz"
  "rust-toolchain.toml"
  "spikes"
  "tools"
)
if [[ -d rust ]]; then
  unexpected_rust_entries="$(comm -23 \
    <(find rust -mindepth 1 -maxdepth 1 -exec basename {} \; | sort) \
    <(printf '%s\n' "${allowed_rust_top_level_entries[@]}" | sort))"
  if [[ -n "$unexpected_rust_entries" ]]; then
    printf '%s\n' "$unexpected_rust_entries" >&2
    fail "unexpected top-level rust path; experiments belong under rust/spikes and integrated crates under rust/crates"
  fi
fi

repo_prompt_entry="Sources/RepoPromptExecutable/RepoPromptExecutable.swift"
if [[ ! -f "$repo_prompt_entry" ]]; then
  fail "required thin RepoPrompt executable entry missing: $repo_prompt_entry"
fi
unexpected_repo_prompt_executable_files=""
if [[ -d "Sources/RepoPromptExecutable" ]]; then
  unexpected_repo_prompt_executable_files="$(find Sources/RepoPromptExecutable -type f ! -path "$repo_prompt_entry" -print)"
fi
if [[ -n "$unexpected_repo_prompt_executable_files" ]]; then
  fail "thin RepoPrompt executable target contains implementation files"
  printf '%s\n' "$unexpected_repo_prompt_executable_files" >&2
fi
repo_prompt_app_main_declarations="$(grep -R -n -E '^[[:space:]]*@main([[:space:]]|$)' Sources/RepoPrompt --include='*.swift' || true)"
if [[ -n "$repo_prompt_app_main_declarations" ]]; then
  fail "RepoPromptApp implementation target must not declare @main"
  printf '%s\n' "$repo_prompt_app_main_declarations" >&2
fi
repo_prompt_entry_main_count="$(grep -c -E '^[[:space:]]*@main([[:space:]]|$)' "$repo_prompt_entry" || true)"
if [[ "$repo_prompt_entry_main_count" -ne 1 ]]; then
  fail "thin RepoPrompt executable entry must declare exactly one @main"
fi

shared_mcp_required_files=(
  "Sources/RepoPromptShared/MCP/MCPControlMessages.swift"
  "Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift"
  "Sources/RepoPromptShared/MCP/MCPExternalClientEvent.swift"
)
for file in "${shared_mcp_required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    fail "required shared MCP file missing: $file"
  fi
done

# P2 step 13: the Swift tree-sitter supply chain (SwiftTreeSitter wrapper,
# grammar packages, TreeSitterScannerSupport shim) was deleted; the Rust core
# owns parsing. Negative guards below (inside the dump-package check) keep it
# from returning.

if ! tree_sitter_dependency_manifest_output="$(python3 <<'PY'
import json
import re
import subprocess
from pathlib import Path

errors = []
manifest_text = Path("Package.swift").read_text()
resolved = json.loads(Path("Package.resolved").read_text())
resolved_pins = {pin["identity"]: pin for pin in resolved["pins"]}
package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True))
targets = {target["name"]: target for target in package["targets"]}
repo_prompt = targets.get("RepoPrompt", {})
repo_prompt_app = targets.get("RepoPromptApp", {})
repo_prompt_dependencies = repo_prompt.get("dependencies", [])
repo_prompt_app_dependencies = repo_prompt_app.get("dependencies", [])
repo_prompt_app_products = {
    (dependency["product"][0], dependency["product"][1])
    for dependency in repo_prompt_app_dependencies
    if "product" in dependency
}
repo_prompt_mcp = targets.get("RepoPromptMCP", {})
repo_prompt_mcp_dependencies = repo_prompt_mcp.get("dependencies", [])
repo_prompt_code_map_core = targets.get("RepoPromptCodeMapCore", {})
repo_prompt_code_map_core_dependencies = repo_prompt_code_map_core.get("dependencies", [])
repo_prompt_code_map_core_products = {
    (dependency["product"][0], dependency["product"][1])
    for dependency in repo_prompt_code_map_core_dependencies
    if "product" in dependency
}

if repo_prompt.get("type") != "executable":
    errors.append("RepoPrompt target must remain executable")
if repo_prompt.get("path") != "Sources/RepoPromptExecutable":
    errors.append("RepoPrompt target must remain the thin Sources/RepoPromptExecutable entry target")
repo_prompt_by_name_dependencies = [dependency["byName"][0] for dependency in repo_prompt_dependencies if dependency.get("byName")]
if len(repo_prompt_dependencies) != 1 or repo_prompt_by_name_dependencies != ["RepoPromptApp"]:
    errors.append("RepoPrompt executable target must depend only on RepoPromptApp")
if repo_prompt_app.get("type") != "regular":
    errors.append("RepoPromptApp target must remain an internal library target")
if repo_prompt_app.get("path") != "Sources/RepoPrompt":
    errors.append("RepoPromptApp target must retain the Sources/RepoPrompt implementation path")

workspace_core = targets.get("RepoPromptWorkspaceCore")
if workspace_core is None:
    errors.append("RepoPromptWorkspaceCore target missing")
else:
    if workspace_core.get("type") != "regular": errors.append("RepoPromptWorkspaceCore must remain an internal regular target")
    if workspace_core.get("path") != "Sources/RepoPromptWorkspaceCore": errors.append("RepoPromptWorkspaceCore target path drifted")
    if workspace_core.get("dependencies", []): errors.append("RepoPromptWorkspaceCore must not declare target or package dependencies")
    if workspace_core.get("settings", []): errors.append("RepoPromptWorkspaceCore must not declare compiler settings")

workspace_core_tests = targets.get("RepoPromptWorkspaceCoreTests")
if workspace_core_tests is None:
    errors.append("RepoPromptWorkspaceCoreTests target missing")
else:
    test_dependencies = [dependency["byName"][0] for dependency in workspace_core_tests.get("dependencies", []) if dependency.get("byName")]
    if workspace_core_tests.get("type") != "test": errors.append("RepoPromptWorkspaceCoreTests must remain a test target")
    if workspace_core_tests.get("path") != "Tests/RepoPromptWorkspaceCoreTests": errors.append("RepoPromptWorkspaceCoreTests target path drifted")
    if test_dependencies != ["RepoPromptWorkspaceCore"] or len(workspace_core_tests.get("dependencies", [])) != 1:
        errors.append("RepoPromptWorkspaceCoreTests must depend only on RepoPromptWorkspaceCore")

search_core = targets.get("RepoPromptSearchCore")
if search_core is None:
    errors.append("RepoPromptSearchCore target missing")
else:
    search_dependencies = [dependency["byName"][0] for dependency in search_core.get("dependencies", []) if dependency.get("byName")]
    if search_core.get("type") != "regular": errors.append("RepoPromptSearchCore must remain an internal regular target")
    if search_core.get("path") != "Sources/RepoPromptSearchCore": errors.append("RepoPromptSearchCore target path drifted")
    if search_dependencies != ["AgentryCoreBridge"] or len(search_core.get("dependencies", [])) != 1:
        errors.append("RepoPromptSearchCore must depend only on AgentryCoreBridge")
    if '"swiftLanguageMode":{"_0":"6"}' not in json.dumps(search_core.get("settings", [])).replace(" ", ""):
        errors.append("RepoPromptSearchCore must compile in Swift 6 language mode")

search_core_tests = targets.get("RepoPromptSearchCoreTests")
if search_core_tests is None:
    errors.append("RepoPromptSearchCoreTests target missing")
else:
    search_test_dependencies = [dependency["byName"][0] for dependency in search_core_tests.get("dependencies", []) if dependency.get("byName")]
    if search_core_tests.get("type") != "test": errors.append("RepoPromptSearchCoreTests must remain a test target")
    if search_core_tests.get("path") != "Tests/RepoPromptSearchCoreTests": errors.append("RepoPromptSearchCoreTests target path drifted")
    if search_test_dependencies != ["RepoPromptSearchCore", "AgentryCoreBridge"] or len(search_core_tests.get("dependencies", [])) != 2:
        errors.append("RepoPromptSearchCoreTests must depend only on RepoPromptSearchCore and AgentryCoreBridge")
    if '"swiftLanguageMode":{"_0":"6"}' not in json.dumps(search_core_tests.get("settings", [])).replace(" ", ""):
        errors.append("RepoPromptSearchCoreTests must compile in Swift 6 language mode")

ffi_expected = {
    "CAgentryRustCore": ("regular", "Sources/CAgentryRustCore", []),
    "AgentryUniFFIRaw": ("regular", "Sources/AgentryUniFFIRaw", ["CAgentryRustCore"]),
    "AgentryCoreBridge": ("regular", "Sources/AgentryCoreBridge", ["AgentryUniFFIRaw"]),
    "AgentryCoreBridgeTests": ("test", "Tests/AgentryCoreBridgeTests", ["AgentryCoreBridge"]),
}
for name, (target_type, path, expected_dependencies) in ffi_expected.items():
    target = targets.get(name)
    if target is None:
        errors.append(f"{name} target missing")
        continue
    dependencies = [dependency["byName"][0] for dependency in target.get("dependencies", []) if dependency.get("byName")]
    if target.get("type") != target_type: errors.append(f"{name} target type drifted")
    if target.get("path") != path: errors.append(f"{name} target path drifted")
    if dependencies != expected_dependencies or len(target.get("dependencies", [])) != len(expected_dependencies):
        errors.append(f"{name} dependency boundary drifted: expected {expected_dependencies}, got {dependencies}")
c_agentry = targets.get("CAgentryRustCore", {})
if c_agentry.get("sources") != ["shim.c"]:
    errors.append("CAgentryRustCore must compile only shim.c")
if c_agentry.get("publicHeadersPath") != "include":
    errors.append("CAgentryRustCore must retain include as its public-header directory")
c_agentry_flags = [
    setting.get("kind", {}).get("unsafeFlags", {}).get("_0", [])
    for setting in c_agentry.get("settings", [])
]
if not any(any(flag.endswith("/libagentry_ffi.a") for flag in flags) for flags in c_agentry_flags):
    errors.append("CAgentryRustCore must retain Rust static-library linkage")
native_suffixes = (".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".h", ".hh", ".hpp", ".hxx")
for name, target in targets.items():
    native_sources = [
        source for source in (target.get("sources") or [])
        if source.lower().endswith(native_suffixes)
    ]
    if name == "CAgentryRustCore":
        if native_sources != ["shim.c"]:
            errors.append(f"CAgentryRustCore native source list drifted: {native_sources}")
    elif native_sources:
        errors.append(f"first-party SwiftPM target must not compile C-family sources: {name}: {native_sources}")
fixture_roots = (
    "Tests/RepoPromptCodeMapCoreTests/Fixtures/c",
    "Tests/RepoPromptCodeMapCoreTests/Fixtures/cpp",
)
for name, target in targets.items():
    if name == "RepoPromptCodeMapCoreTests":
        continue
    target_path = target.get("path") or ""
    for fixture_root in fixture_roots:
        if target_path == fixture_root or target_path.startswith(fixture_root + "/") or fixture_root.startswith(target_path + "/"):
            errors.append(f"data-only parser fixture root must not be owned by target {name}: {fixture_root}")
for name in ("AgentryUniFFIRaw", "AgentryCoreBridge", "AgentryCoreBridgeTests"):
    target = targets.get(name, {})
    settings_text = json.dumps(target.get("settings", []))
    if '"swiftLanguageMode":{"_0":"6"}' not in settings_text.replace(" ", ""):
        errors.append(f"{name} must compile in Swift 6 language mode")
    if "-strict-concurrency=complete" not in settings_text or "-warnings-as-errors" not in settings_text:
        errors.append(f"{name} must use complete strict concurrency and warnings-as-errors")
for product in package.get("products", []):
    if any(name in product.get("targets", []) for name in ffi_expected):
        errors.append("Rust FFI targets must remain internal package targets")

app_by_name_dependencies = [dependency["byName"][0] for dependency in repo_prompt_app_dependencies if dependency.get("byName")]
repo_prompt_mcp_by_name_dependencies = [dependency["byName"][0] for dependency in repo_prompt_mcp_dependencies if dependency.get("byName")]
if "RepoPromptC" in targets:
    errors.append("retired RepoPromptC target must not return")
for consumer_name, dependencies in (
    ("RepoPromptApp", app_by_name_dependencies),
    ("RepoPromptMCP", repo_prompt_mcp_by_name_dependencies),
):
    if "RepoPromptC" in dependencies:
        errors.append(f"{consumer_name} must not depend on retired RepoPromptC")
if app_by_name_dependencies.count("RepoPromptWorkspaceCore") != 1:
    errors.append("RepoPromptApp must depend exactly once on RepoPromptWorkspaceCore")
if app_by_name_dependencies.count("AgentryCoreBridge") != 1:
    errors.append("RepoPromptApp must depend exactly once on AgentryCoreBridge")
if app_by_name_dependencies.count("RepoPromptSearchCore") != 1:
    errors.append("RepoPromptApp must depend exactly once on RepoPromptSearchCore")
for removed_target in ("RepoPromptRegexCore", "CSwiftPCRE2", "RepoPromptRegexCoreTests"):
    if removed_target in targets:
        errors.append(f"removed legacy regex target must not return: {removed_target}")
for consumer in ("RepoPrompt", "RepoPromptApp", "RepoPromptMCP", "RepoPromptSearchCore", "RepoPromptSearchCoreTests", "RepoPromptShared", "RepoPromptTests"):
    dependencies = [dependency["byName"][0] for dependency in targets.get(consumer, {}).get("dependencies", []) if dependency.get("byName")]
    if consumer != "RepoPromptApp" and "RepoPromptWorkspaceCore" in dependencies:
        errors.append(f"{consumer} must not directly depend on RepoPromptWorkspaceCore")
    if any(name in dependencies for name in ("CAgentryRustCore", "AgentryUniFFIRaw")):
        errors.append(f"{consumer} must not consume raw Rust FFI targets")
    if consumer in ("RepoPrompt", "RepoPromptMCP", "RepoPromptShared") and "AgentryCoreBridge" in dependencies:
        errors.append(f"{consumer} must not directly depend on AgentryCoreBridge")
for source in Path("Sources/RepoPrompt").rglob("*.swift"):
    text = source.read_text()
    if re.search(r"^\s*import\s+(?:AgentryUniFFIRaw|CAgentryRustCore)\b", text, re.MULTILINE):
        errors.append(f"RepoPromptApp source must not import raw Rust FFI modules: {source}")
for product in package.get("products", []):
    if "RepoPromptWorkspaceCore" in product.get("targets", []): errors.append("RepoPromptWorkspaceCore must not be exposed as a package product")
    if "RepoPromptSearchCore" in product.get("targets", []): errors.append("RepoPromptSearchCore must not be exposed as a package product")


# P2 step 13: no tree-sitter package of any kind may return to the Swift graph.
for banned_identity in list(resolved_pins):
    if "tree-sitter" in banned_identity:
        errors.append(f"tree-sitter package must not return after P2 step 13: {banned_identity}")
if re.search(r"tree-?sitter", manifest_text, re.IGNORECASE):
    errors.append("Package.swift must not reference tree-sitter after P2 step 13")
if "https://github.com/ChimeHQ/SwiftTreeSitter" in manifest_text or "swifttreesitter" in resolved_pins:
    errors.append("ChimeHQ SwiftTreeSitter must not coexist with the RepoPrompt fork")
if "https://github.com/ChimeHQ/Neon" in manifest_text or '.product(name: "Neon"' in manifest_text or "neon" in resolved_pins:
    errors.append("Neon package/product must remain removed")

if "TreeSitterScannerSupport" in targets:
    errors.append("TreeSitterScannerSupport target must not return after P2 step 13")
if repo_prompt_code_map_core_dependencies:
    errors.append("RepoPromptCodeMapCore must have no target or package dependencies after P2 step 13")
if app_by_name_dependencies.count("RepoPromptCodeMapCore") != 1:
    errors.append("RepoPromptApp must depend exactly once on RepoPromptCodeMapCore")

# M1 headless domain runtime is an internal AppKit-free owner boundary. During the
# two-commit migration it may be staged in Swift 5 or promoted to Swift 6, but the
# runtime and owner tests must move together and retain complete checking.
#
# P2 step 13 (rust-codemap-compact-v1.md / rust-apply-edits-compact-v1.md): the
# boundary is "no GUI/AppKit/app-lifecycle dependency", not "no Rust core". The
# standalone headless `agentry-mcp` binary and the GUI app share one Rust core
# runtime (`AgentryCoreService`, `RustCodeMapArtifactBuilder`,
# `RustApplyEditsComputer`), all hosted in this target, so both processes reach
# it through the same seam instead of each depending on the legacy Swift
# codemap/apply-edits compute engines. `AgentryCoreBridge` is a pure compute
# façade (Foundation/Dispatch/Darwin only, no AppKit/SwiftUI/Combine/MainActor),
# so this remains AppKit-free.
domain_runtime = targets.get("RepoPromptDomainRuntime")
domain_runtime_tests = targets.get("RepoPromptDomainRuntimeTests")
if domain_runtime is None:
    errors.append("RepoPromptDomainRuntime target missing")
else:
    if domain_runtime.get("type") != "regular": errors.append("RepoPromptDomainRuntime must remain an internal regular target")
    if domain_runtime.get("path") != "Sources/RepoPromptDomainRuntime": errors.append("RepoPromptDomainRuntime target path drifted")
    runtime_by_name = [
        dependency["byName"][0]
        for dependency in domain_runtime.get("dependencies", [])
        if dependency.get("byName")
    ]
    runtime_products = {
        (dependency["product"][0], dependency["product"][1])
        for dependency in domain_runtime.get("dependencies", [])
        if "product" in dependency
    }
    if runtime_by_name != ["RepoPromptShared", "RepoPromptCodeMapCore", "AgentryCoreBridge"] or runtime_products != {("Logging", "swift-log"), ("MCP", "swift-sdk")} or len(domain_runtime.get("dependencies", [])) != 5:
        errors.append("RepoPromptDomainRuntime dependencies must remain RepoPromptShared, RepoPromptCodeMapCore, AgentryCoreBridge, Logging, and pinned MCP")
if domain_runtime_tests is None:
    errors.append("RepoPromptDomainRuntimeTests target missing")
else:
    owner_by_name = [dependency["byName"][0] for dependency in domain_runtime_tests.get("dependencies", []) if dependency.get("byName")]
    owner_products = {
        (dependency["product"][0], dependency["product"][1])
        for dependency in domain_runtime_tests.get("dependencies", [])
        if "product" in dependency
    }
    if domain_runtime_tests.get("type") != "test": errors.append("RepoPromptDomainRuntimeTests must remain a test target")
    if domain_runtime_tests.get("path") != "Tests/RepoPromptDomainRuntimeTests": errors.append("RepoPromptDomainRuntimeTests target path drifted")
    if owner_by_name != ["RepoPromptDomainRuntime"] or owner_products != {("MCP", "swift-sdk")} or len(domain_runtime_tests.get("dependencies", [])) != 2:
        errors.append("RepoPromptDomainRuntimeTests must depend only on RepoPromptDomainRuntime and MCP")

def swift_language_modes(target):
    return [
        setting.get("kind", {}).get("swiftLanguageMode", {}).get("_0")
        for setting in target.get("settings", [])
        if setting.get("kind", {}).get("swiftLanguageMode")
    ]

def strict_concurrency_features(target):
    return [
        setting.get("kind", {}).get("enableExperimentalFeature", {}).get("_0")
        for setting in target.get("settings", [])
        if setting.get("kind", {}).get("enableExperimentalFeature")
    ]

if domain_runtime is not None and domain_runtime_tests is not None:
    runtime_modes = swift_language_modes(domain_runtime)
    owner_modes = swift_language_modes(domain_runtime_tests)
    if runtime_modes != owner_modes:
        errors.append("RepoPromptDomainRuntime and owner tests must use the same Swift language mode")
    elif runtime_modes == ["5"]:
        if strict_concurrency_features(domain_runtime) != ["StrictConcurrency"] or strict_concurrency_features(domain_runtime_tests) != ["StrictConcurrency"]:
            errors.append("Swift 5 domain runtime and owner tests must retain complete StrictConcurrency checking")
    elif runtime_modes != ["6"]:
        errors.append("RepoPromptDomainRuntime and owner tests must be either Swift 5 + StrictConcurrency or Swift 6")
if app_by_name_dependencies.count("RepoPromptDomainRuntime") != 1:
    errors.append("RepoPromptApp must depend exactly once on RepoPromptDomainRuntime")
repo_prompt_tests_dependencies = [dependency["byName"][0] for dependency in targets.get("RepoPromptTests", {}).get("dependencies", []) if dependency.get("byName")]
if repo_prompt_tests_dependencies.count("RepoPromptDomainRuntime") != 1:
    errors.append("RepoPromptTests must directly consume RepoPromptDomainRuntime for adapter evidence")

code_map_core_tests = targets.get("RepoPromptCodeMapCoreTests", {})
core_test_dependencies = [
    dependency["byName"][0]
    for dependency in code_map_core_tests.get("dependencies", [])
    if dependency.get("byName")
]
if code_map_core_tests.get("path") != "Tests/RepoPromptCodeMapCoreTests":
    errors.append("RepoPromptCodeMapCoreTests target path drifted")
if core_test_dependencies != ["RepoPromptCodeMapCore"]:
    errors.append("RepoPromptCodeMapCoreTests must depend only on RepoPromptCodeMapCore")

# P2 step 13: CodeMapCore must stay free of tree-sitter imports; the Rust core owns parsing.
for core_source in Path("Sources/RepoPromptCodeMapCore").rglob("*.swift"):
    if re.search(r"^\s*import\s+(?:SwiftTreeSitter|TreeSitter\w+)\b", core_source.read_text(), re.MULTILINE):
        errors.append(f"CodeMapCore source must not import tree-sitter modules after P2 step 13: {core_source}")
if Path("Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h").exists():
    errors.append("retired RepoPromptApp bridging header must not return")

if errors:
    raise SystemExit("\n".join(errors))
PY
)"; then
  fail "Tree-sitter dependency, product, or scanner-support contract drifted"
  printf '%s\n' "$tree_sitter_dependency_manifest_output" >&2
fi

retired_tree_sitter_grammar_dirs=(
  "Sources/RepoPromptTreeSitterCGrammar"
  "Sources/RepoPromptTreeSitterCSharpGrammar"
  "Sources/RepoPromptTreeSitterCPPGrammar"
  "Sources/RepoPromptTreeSitterGoGrammar"
  "Sources/RepoPromptTreeSitterJavaGrammar"
  "Sources/RepoPromptTreeSitterJavaScriptGrammar"
  "Sources/RepoPromptTreeSitterPHPGrammar"
  "Sources/RepoPromptTreeSitterPythonGrammar"
  "Sources/RepoPromptTreeSitterRubyGrammar"
  "Sources/RepoPromptTreeSitterRustGrammar"
  "Sources/RepoPromptTreeSitterSwiftGrammar"
  "Sources/RepoPromptTreeSitterTypeScriptGrammar"
)
for dir in "${retired_tree_sitter_grammar_dirs[@]}"; do
  if [[ -e "$dir" ]]; then
    fail "retired local Tree-sitter grammar directory exists: $dir"
  fi
done

# RepoPromptWorkspaceCore is a Foundation-only path-policy boundary.
workspace_core_source_dir="Sources/RepoPromptWorkspaceCore"
if [[ -d "$workspace_core_source_dir" ]]; then
  unexpected_workspace_core_files="$(find "$workspace_core_source_dir" -type f ! -name '*.swift' -print)"
  if [[ -n "$unexpected_workspace_core_files" ]]; then
    fail "RepoPromptWorkspaceCore contains non-Swift source files"
    printf '%s\n' "$unexpected_workspace_core_files" >&2
  fi

  if ! workspace_core_imports="$(xcrun swiftc -frontend -emit-imported-modules "$workspace_core_source_dir"/*.swift 2>&1 | sort -u)"; then
    fail "Swift compiler could not inspect RepoPromptWorkspaceCore imports"
    printf '%s\n' "$workspace_core_imports" >&2
  elif [[ "$workspace_core_imports" != "Foundation" ]]; then
    fail "RepoPromptWorkspaceCore compiler import allowlist is Foundation only"
    printf '%s\n' "$workspace_core_imports" >&2
  fi
fi

# RepoPromptSearchCore owns AppKit-free search values and deterministic Rust-backed filtering.
search_core_source_dir="Sources/RepoPromptSearchCore"
if [[ -d "$search_core_source_dir" ]]; then
  unexpected_search_core_files="$(find "$search_core_source_dir" -type f ! -name '*.swift' -print)"
  if [[ -n "$unexpected_search_core_files" ]]; then
    fail "RepoPromptSearchCore contains non-Swift source files"
    printf '%s\n' "$unexpected_search_core_files" >&2
  fi
  search_core_ui_imports="$(grep -R -n -E '^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI)\b' "$search_core_source_dir" --include='*.swift' || true)"
  if [[ -n "$search_core_ui_imports" ]]; then
    fail "RepoPromptSearchCore must remain AppKit/SwiftUI free"
    printf '%s\n' "$search_core_ui_imports" >&2
  fi
fi

# RepoPromptDomainRuntime owns Sendable MCP catalog/runtime values, the M2
# workspace/context authorities, M3 shared reads, M4 protected mutation policy, and
# M5 long-running lifecycle wrappers. Physical app backends remain injected and the
# owner stays free of UI/provider implementations.
domain_runtime_source_dir="Sources/RepoPromptDomainRuntime"
if [[ -d "$domain_runtime_source_dir" ]]; then
  unexpected_domain_runtime_files="$(find "$domain_runtime_source_dir" -type f ! -name '*.swift' -print)"
  if [[ -n "$unexpected_domain_runtime_files" ]]; then
    fail "RepoPromptDomainRuntime contains non-Swift source files"
    printf '%s\n' "$unexpected_domain_runtime_files" >&2
  fi
  print_matches \
    "RepoPromptDomainRuntime imports an app/UI framework" \
    grep -R -n -E '^import[[:space:]]+(AppKit|SwiftUI|Combine)$' "$domain_runtime_source_dir"
  print_matches \
    "RepoPromptDomainRuntime declares MainActor ownership" \
    grep -R -n -E '@MainActor' "$domain_runtime_source_dir"
  domain_runtime_required_files=(
    "DomainPersistence.swift"
    "DomainWorkspaceModels.swift"
    "DomainWorkspaceCommand.swift"
    "DomainWorkspaceContextAuthority.swift"
    "DomainRoutingCoordinator.swift"
    "DomainRuntimeMetrics.swift"
    "DomainReadContext.swift"
    "DomainReadSideEffectCoordinator.swift"
    "MCPDomainReadToolDefinitions.swift"
    "MCPDomainReadToolProvider.swift"
    "DomainAgentSessionModels.swift"
    "DomainAgentRunSessionStore.swift"
    "DomainAgentSessionAuthority.swift"
    "DomainAgentSessionLifecycleAuthority.swift"
    "DomainAgentRunLifecycleContracts.swift"
    "DomainAgentRunTerminalCommitContracts.swift"
    "DomainInteractionBroker.swift"
    "DomainCredentialEnvelope.swift"
    "DomainActivityCenter.swift"
    "MCPDomainLongRunningToolProvider.swift"
  )
  for file in "${domain_runtime_required_files[@]}"; do
    if [[ ! -f "$domain_runtime_source_dir/$file" ]]; then
      fail "RepoPromptDomainRuntime M2-M5 authority file missing: $file"
    fi
  done
  m5_contract_fixture="Scripts/Fixtures/headless_mcp_domain_runtime_m5_contract.json"
  if [[ ! -f "$m5_contract_fixture" ]]; then
    fail "M5 AI/Agent contract fixture missing: $m5_contract_fixture"
  elif ! python3 - "$m5_contract_fixture" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
expected = {
    "oracle_utils", "ask_oracle", "oracle_send", "context_builder", "ask_user",
    "agent_explore", "agent_run", "agent_manage", "share_thoughts", "set_status",
    "wait_for_next_user_instruction",
}
assert value["schema_version"] == 2
assert value["milestone"] == "M5"
assert set(value["migrated_tools"]) == expected
assert value["session_lifecycle"]["false_transient_restoration_allowed"] is False
assert value["session_lifecycle"]["wait_admission_while_draining"] == "cancelled"
assert value["session_lifecycle"]["active_prior_owner_claim"] == "unavailable_until_prior_owner_durably_stops"
assert value["session_persistence"]["write_protocol"] == "advisory_lock_digest_cas_atomic_write"
assert value["session_persistence"]["duplicate_session_ids"] == "byte_preserved_degraded_read_only"
assert value["session_persistence"]["committed_base_advances_after_each_successful_cas"] is True
assert value["session_persistence"]["retained_record_limit"] == 512
assert value["interaction"]["default_timeout"] == "Context Builder captured or Agent Mode live global questionTimeoutSeconds setting"
assert value["interaction"]["app_presentation_tombstone_limit"] == 256
assert value["interaction"]["connection_removal_late_waiter"] == "blocked_after_suspended_availability"
assert value["child_launch"]["real_private_endpoint"] == "deferred_to_M6B"
assert value["child_launch"]["codex_cached_runtime_behavior"] == "carrier_merged_only_at_final_process_spawn_boundary"
assert value["child_launch"]["end_to_end_private_connectivity_claimed"] is False
assert set(value["child_launch"]["launch_environment_consumers"]) == {"claude_native", "codex_app_server", "acp_agent"}
assert value["credentials"]["packaged_child_keychain_evidence"] == "unresolved_M0_procedure_record"
assert value["credentials"]["persisted_secret_bytes"] is False
assert value["credentials"]["actual_owned_bytes_instrumented"] is True
assert value["approval"]["routing_opt_out"] is False
assert value["authority"]["typed_policy_errors_preserved"] is True
assert value["authority"]["identity_admission"] == "DomainAgentSessionLifecycleDecisionAuthority"
assert value["authority"]["run_lifecycle"] == "DomainAgentRunLifecycleTracker"
assert value["authority"]["terminal_commit"] == "DomainAgentRunTerminalCommitState"
assert value["public_contract"]["schema_behavior"] == "wrapped_binding_definition_preserved"
assert value["public_contract"]["proxy_behavior_changed"] is False
PY
  then
    fail "M5 AI/Agent contract fixture drifted or is invalid JSON"
  fi
  if ! grep -q 'package actor DomainAgentSessionAuthority' "$domain_runtime_source_dir/DomainAgentRunSessionStore.swift" \
    || ! grep -q 'typealias DomainAgentRunSessionStore = DomainAgentSessionAuthority' "$domain_runtime_source_dir/DomainAgentRunSessionStore.swift"; then
    fail "agent-session lifecycle authority lost its canonical name or compatibility alias"
  fi
  if ! grep -q 'package struct DomainAgentSessionLifecycleDecisionAuthority' "$domain_runtime_source_dir/DomainAgentSessionLifecycleAuthority.swift" \
    || ! grep -q 'typealias Identity = DomainAgentSessionLifecycleIdentity' "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionLifecycleAuthority.swift" \
    || ! grep -q 'decisionAuthority.validateMutationTarget' "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionLifecycleAuthority.swift" \
    || ! grep -q 'decisionAuthority.decideAdmission' "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionLifecycleAuthority.swift"; then
    fail "agent-session identity and admission decisions must be delegated to the Domain authority"
  fi
  if ! grep -q 'package struct DomainAgentRunLifecycleTracker' "$domain_runtime_source_dir/DomainAgentRunLifecycleContracts.swift" \
    || ! grep -q 'typealias AgentRunLifecycleTracker = DomainAgentRunLifecycleTracker' "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunLifecycleContracts.swift" \
    || ! grep -q 'typealias AgentRunOwnership = DomainAgentRunOwnership' "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunLifecycleContracts.swift"; then
    fail "Agent run ownership and liveness must be delegated to the Domain reducer"
  fi
  if ! grep -q 'package struct DomainAgentRunTerminalCommitState' "$domain_runtime_source_dir/DomainAgentRunTerminalCommitContracts.swift" \
    || ! grep -q 'tracker.beginTerminalCommit' "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunAttemptLifecycle.swift" \
    || ! grep -q 'tracker.recordTerminalPublicationResult' "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunAttemptLifecycle.swift" \
    || ! grep -q 'lifecycle.hasTerminalCommit' "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunTerminalCommitBarrier.swift"; then
    fail "Agent run terminal commit phase and result must be delegated to the Domain reducer"
  fi
  if grep -q -E 'private\(set\) var terminalCommitInProgress|private\(set\) var lastTerminalPublicationResult' \
    "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunAttemptLifecycle.swift"; then
    fail "App Agent run lifecycle reintroduced terminal commit authority state"
  fi
  if grep -q -E 'struct AgentRun(Ownership|ProgressSignal|LivenessSnapshot)|enum AgentRun(ProgressRejection|ProgressAcceptance|LifecycleStage|LivenessSignalKind|RetryIntent)|struct AgentRunLifecycleTracker' \
    "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunLifecycleContracts.swift"; then
    fail "App Agent run lifecycle contracts reintroduced a duplicate reducer"
  fi
  if grep -q 'guard current.identity.sessionID' "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentSessionLifecycleAuthority.swift"; then
    fail "App agent-session facade reintroduced a duplicate identity predicate"
  fi
  if ! grep -q 'MCPDomainGeneratedToolDefinitions.records' "$domain_runtime_source_dir/MCPDomainReadToolDefinitions.swift" \
    || ! grep -q 'filter(\\.sharedRead)' "$domain_runtime_source_dir/MCPDomainReadToolDefinitions.swift"; then
    fail "M3 shared read definitions must consume the generated Rust catalog projection"
  fi
  if [[ -f "$domain_runtime_source_dir/MCPDomainCanonicalToolDefinitions.swift" ]]; then
    fail "Swift MCP schema authority was not retired after the Rust catalog handoff"
  fi
  if grep -R -n --include='*.swift' -E 'Data\(base64Encoded|static[[:space:]]+let[[:space:]]+entries:[[:space:]]*\[MCPDomainToolCatalogEntry[[:space:]]*\][[:space:]]*=[[:space:]]*\[' "$domain_runtime_source_dir"; then
    fail "Swift MCP catalog must not contain an opaque base64 or hand-authored entry table"
  fi
  print_matches \
    "RepoPromptDomainRuntime contains app/UI/provider implementation" \
    grep -R -n -E 'WindowState|ViewModel|AgentProvider|Claude[^[:space:]]*Provider|Codex[^[:space:]]*Provider|OpenCode[^[:space:]]*Provider|Cursor[^[:space:]]*Provider' "$domain_runtime_source_dir"
  print_matches \
    "RepoPromptDomainRuntime reintroduced random window incarnations" \
    grep -R -n -E 'windowGeneration.*random|UInt64\.random' "$domain_runtime_source_dir"

  m3_legacy_provider_files=(
    "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift"
    "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPPromptContextToolProvider.swift"
    "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPOracleToolProvider.swift"
    "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPGitToolProvider.swift"
    "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPHistoryToolProvider.swift"
  )
  m3_duplicate_schema_matches="$(grep -n -E 'name:[[:space:]]*(MCPWindowToolName\.(getCodeStructure|getFileTree|readFile|search|workspaceContext|prompt|oracleChatLog|git|history)|"(get_code_structure|get_file_tree|read_file|file_search|workspace_context|prompt|oracle_chat_log|git|history)")' "${m3_legacy_provider_files[@]}" || true)"
  if [[ -n "$m3_duplicate_schema_matches" ]]; then
    fail "M3 read/discovery schema reintroduced in an app provider"
    printf '%s\n' "$m3_duplicate_schema_matches" >&2
  fi

  m3_domain_provider="$domain_runtime_source_dir/MCPDomainReadToolProvider.swift"
  for requirement in 'case workspaceIndependent' 'case workspaceOptional' 'case workspaceRequired'; do
    if ! grep -q "$requirement" "$m3_domain_provider"; then
      fail "M3 per-family context requirement missing: $requirement"
    fi
  done
  if ! grep -q 'case "history", "oracle_chat_log"' "$m3_domain_provider" \
    || ! grep -q 'case "get_file_tree", "git"' "$m3_domain_provider"; then
    fail "M3 historical workspace-independent/optional family mapping changed"
  fi

  m3_app_read_routing="Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+DomainRouting.swift"
  if ! grep -q 'registerForRead' "$m3_app_read_routing"; then
    fail "M3 awaited transient read authority registration missing"
  fi
  if grep -q 'validateDomainReadContext' "$m3_app_read_routing"; then
    fail "M3 read path reintroduced repeated MainActor authority capture"
  fi
  m3_read_resolver="$(sed -n '/func resolveDomainReadContext/,/Runs before the server is stopped/p' "$m3_app_read_routing")"
  if grep -q -E 'registerWindow|publishDomainRoutingBinding' <<<"$m3_read_resolver"; then
    fail "M3 read resolution mutates shared presentation routing"
  fi
  if ! grep -q 'domainReadAppExecutionContexts\[invocation.invocationID\]' "$m3_app_read_routing" \
    || ! grep -q 'releaseDomainReadAppExecutionContext' "$m3_app_read_routing" \
    || ! grep -q 'registerFallbackDomainReadContext' "$m3_app_read_routing" \
    || ! grep -q 'domainRoutingConnectionIDs' "$m3_app_read_routing"; then
    fail "M3 invocation snapshot, fallback authority, or connection-lifecycle seam missing"
  fi
  if ! grep -q 'context.handle == nil' "$m3_domain_provider"; then
    fail "M3 required read authority no longer fails closed"
  fi
  m3_file_backend="Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift"
  m3_prompt_backend="Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPPromptContextToolProvider.swift"
  if ! grep -q 'readAuthority(appContext)' "$m3_file_backend" \
    || ! grep -q 'selectionRefreshedContext(appContext.resolvedTabContext)' "$m3_prompt_backend" \
    || grep -q 'resolveTabContextSnapshot' <<<"$(sed -n '/func selectionRefreshedContext/,/private func simplePromptReply/p' "$m3_prompt_backend")"; then
    fail "M3 app backend stopped consuming captured authority or repeated heavyweight routing"
  fi
  m3_git_backend="Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPGitToolProvider.swift"
  if ! grep -q 'appContext.metadata' "$m3_git_backend" \
    || ! grep -q 'appContext.lookupContext' "$m3_git_backend" \
    || ! grep -q 'appContext?.resolvedTabContext' "$m3_git_backend" \
    || ! grep -q 'capturedWorkspaceID' "$m3_git_backend"; then
    fail "M3 git backend stopped consuming captured authority"
  fi
  if ! sed -n '/commitPrimaryGitDiffArtifactsToCurrentTab(/,/)/p' "$m3_git_backend" | grep -q 'appContext' \
    || ! sed -n '/replaceAdvertisedGitArtifactsForCurrentTab(/,/)/p' "$m3_git_backend" | grep -q 'appContext'; then
    fail "M3 git artifact side effects no longer carry captured authority"
  fi

  m3_side_effects="$domain_runtime_source_dir/DomainReadSideEffectCoordinator.swift"
  if ! grep -q 'case selection' "$m3_side_effects" || ! grep -q 'case gitArtifacts' "$m3_side_effects"; then
    fail "M3 independent selection/Git effect classes missing"
  fi
  if ! grep -q 'await previous.result' "$m3_side_effects"; then
    fail "M3 side-effect chain no longer recovers after an earlier failure"
  fi
  if ! grep -q 'expiredOperationIDs' "$m3_side_effects" \
    || ! grep -q 'receiptUnavailable' "$m3_side_effects"; then
    fail "M3 exact side-effect receipts no longer fail closed after bounded-ledger expiry"
  fi
fi

m2_presentation_bridge="Sources/RepoPrompt/Infrastructure/MCP/AppShared/DomainWorkspacePresentationBridge.swift"
if [[ ! -f "$m2_presentation_bridge" ]]; then
  fail "M2 MainActor workspace presentation bridge missing"
else
  if ! grep -q 'final class DomainWorkspacePresentationBridge' "$m2_presentation_bridge"; then
    fail "M2 workspace presentation bridge declaration missing"
  fi
  if ! grep -q 'guard subscription.snapshot.isBootstrapped' "$m2_presentation_bridge"; then
    fail "M2 workspace presentation bridge lost first-projection readiness gate"
  fi
fi

service_registry_source="Sources/RepoPrompt/Infrastructure/MCP/ServiceRegistry.swift"
print_matches \
  "ServiceRegistry reintroduced stored service/schema/catalog authority" \
  grep -n -E 'static[[:space:]]+(var|let)[[:space:]]+(services|schemas|catalog)|\[any[[:space:]]+Service\]|\[Tool\]' "$service_registry_source"
for forwarding_source in \
  Sources/RepoPrompt/Infrastructure/MCP/MCPGlobalToolNames.swift \
  Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolNames.swift \
  Sources/RepoPrompt/Infrastructure/MCP/Policies/MCPToolCapabilities.swift; do
  print_matches \
    "MCP compatibility facade contains a second literal tool authority: $forwarding_source" \
    grep -n -E '"(app_settings|bind_context|manage_selection|read_file|file_search|agent_run|history)"' "$forwarding_source"
done

# 1. Old top-level layer buckets should not receive files again.
old_buckets=(
  "Sources/RepoPrompt/ViewModels"
  "Sources/RepoPrompt/Views"
  "Sources/RepoPrompt/Services"
  "Sources/RepoPrompt/Models"
  "Sources/RepoPrompt/Notifications"
  "Sources/RepoPrompt/Utils"
  "Sources/RepoPrompt/Shared"
  "Sources/RepoPrompt/Features/SynthaxParsing"
  "Sources/RepoPrompt/Features/Benchmark"
)
for bucket in "${old_buckets[@]}"; do
  if [[ -d "$bucket" ]]; then
    matches="$(find "$bucket" -type f -print)"
    if [[ -n "$matches" ]]; then
      fail "legacy bucket contains files: $bucket"
      printf '%s\n' "$matches" >&2
    fi
  fi
done

# 2. Test-only directories must stay out of the app source target.
print_matches \
  "Tests/TestSupport/Fixtures directory found under Sources/RepoPrompt" \
  find Sources/RepoPrompt -type d \( -name Tests -o -name TestSupport -o -name Fixtures \) -print

# 3. MCPControlMessages.swift has exactly one source of truth.
mcp_control_files=()
while IFS= read -r file; do
  mcp_control_files+=("$file")
done < <(find Sources -name MCPControlMessages.swift -type f -print | sort)
if [[ "${#mcp_control_files[@]}" -ne 1 || "${mcp_control_files[0]:-}" != "Sources/RepoPromptShared/MCP/MCPControlMessages.swift" ]]; then
  fail "MCPControlMessages.swift must exist only at Sources/RepoPromptShared/MCP/MCPControlMessages.swift"
  printf '%s\n' "${mcp_control_files[@]}" >&2
fi

# 3a. MCP filesystem and event wire identity also have one shared source of truth.
mcp_identity_files=()
while IFS= read -r file; do
  mcp_identity_files+=("$file")
done < <(find Sources -name MCPFilesystemIdentity.swift -type f -print | sort)
if [[ "${#mcp_identity_files[@]}" -ne 1 || "${mcp_identity_files[0]:-}" != "Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift" ]]; then
  fail "MCPFilesystemIdentity.swift must exist only under RepoPromptShared"
  printf '%s\n' "${mcp_identity_files[@]}" >&2
fi

mcp_event_declarations="$(grep -R -l -E '^(public )?struct MCPExternalClientEvent' Sources --include='*.swift' | sort || true)"
if [[ "$mcp_event_declarations" != "Sources/RepoPromptShared/MCP/MCPExternalClientEvent.swift" ]]; then
  fail "MCPExternalClientEvent wire DTO must be declared only under RepoPromptShared"
  printf '%s\n' "$mcp_event_declarations" >&2
fi

# 4. Parser fixtures and sample parser inputs must not live in app source.
print_matches \
  "parser fixture/test directory found under app syntax parsing source" \
  find Sources/RepoPrompt/Infrastructure/SyntaxParsing -type d \( -iname '*fixture*' -o -iname '*test*' \) -print
print_matches \
  "parser fixture-like sample input found under app syntax parsing source" \
  find Sources/RepoPrompt/Infrastructure/SyntaxParsing -type f \( \
    -iname '*fixture*' -o -iname '*test*' -o \
    -name '*.dart' -o -name '*.go' -o -name '*.java' -o -name '*.js' -o -name '*.jsx' -o \
    -name '*.py' -o -name '*.rb' -o -name '*.rs' -o -name '*.ts' -o -name '*.tsx' -o \
    -name '*.php' -o -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' \
  \) -print

# 5. Agent/MCP runtime paths must stay off WorkspaceFiles UI view-model dependencies.
# UI views may still depend on WorkspaceFilesViewModel/FileViewModel/FolderViewModel until
# the later UI-adapter simplification items, but runtime code must use WorkspaceContext values.
print_matches \
  "Agent/MCP runtime source references WorkspaceFilesViewModel/FileViewModel/FolderViewModel" \
  grep -R -n -E 'WorkspaceFilesViewModel|FileViewModel|FolderViewModel' \
    Sources/RepoPrompt/Features/AgentMode/ViewModels \
    Sources/RepoPrompt/Features/ContextBuilder/ViewModels \
    Sources/RepoPrompt/Infrastructure/MCP

# 6. Removed native tree visualization, IDE-mode tree search, and eager root materialization
# seams must not return. Keep unique deleted symbols global, but scope generic names to
# their former owners.
removed_artifact_paths=(
  "Sources/RepoPrompt/Features/AgentMode/Views/AgentFileTreeBottomPanelView.swift"
  "Sources/RepoPrompt/Features/WorkspaceFiles/Views/FileTree/NativeFileTree"
  "Sources/RepoPrompt/Features/Search/ViewModels/SearchFileTreeViewModel.swift"
)
for path in "${removed_artifact_paths[@]}"; do
  if [[ -e "$path" ]]; then
    fail "removed native-tree/search artifact path exists: $path"
  fi
done

print_matches \
  "removed native-tree/workspace-loading/search seam referenced in Sources" \
  grep -R -n -E 'AgentFileTreeBottomPanelView|FileTreeViewWrapper|FileTreeViewController|NativeFileTree|SearchFileTreeViewModel|RootDescendantMaterialization|legacyMaterializedRootKeys|legacyMaterializeDescendantsRecursively|legacyEager' \
    Sources/RepoPrompt
print_matches \
  "WindowState references removed searchViewModel wiring" \
  grep -n -E 'searchViewModel' Sources/RepoPrompt/App/WindowState.swift
print_matches \
  "WorkspaceFilesViewModel references removed recursive eager loading seam" \
  grep -n -E 'loadContentsRecursively' Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift

# Agent Mode terminal settlement stays free of the app's concrete session
# class (AgentTabSession) and uses provider-neutral domain terminal command
# vocabulary directly.
terminal_session_neutral_files=(
  "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunTerminalSessionBinding.swift"
  "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunTerminalCommitBarrier.swift"
)
for path in "${terminal_session_neutral_files[@]}"; do
  if [[ ! -f "$path" ]]; then
      fail "required session-neutral terminal settlement source missing: $path"
    continue
  fi
  print_matches \
      "session-neutral terminal settlement source references the concrete agent session class: $path" \
    grep -n -E 'AgentModeViewModel\.TabSession|AgentTabSession' "$path"
  print_matches \
      "domain-vocabulary terminal settlement source references app-nested terminal command type: $path" \
    grep -n -E 'AgentModeViewModel\.AttachmentTurnDisposition|AgentModeRunService\.CancellationCompletion' "$path"
done

# Claude runtime coordination must use its closed host capability surface rather
# than retaining or attaching the concrete AgentModeViewModel. The session type
# is the extracted top-level AgentTabSession; AgentModeViewModel.TabSession is a
# source-compatibility alias only.
claude_coordinator_source="Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift"
if [[ ! -f "$claude_coordinator_source" ]]; then
  fail "required Claude agent-mode coordinator source missing: $claude_coordinator_source"
else
  print_matches \
    "ClaudeAgentModeCoordinator stores concrete AgentModeViewModel authority" \
    grep -n -E '(^|[[:space:]])(weak[[:space:]]+)?(var|let)[[:space:]]+[[:alnum:]_]+[[:space:]]*:[[:space:]]*AgentModeViewModel[?]?[[:space:]]*$' \
      "$claude_coordinator_source"
  print_matches \
    "ClaudeAgentModeCoordinator reintroduced attach(viewModel:)" \
    grep -n -E 'func[[:space:]]+attach\(viewModel:[[:space:]]*AgentModeViewModel[?]?\)' \
      "$claude_coordinator_source"
fi

# The Agent Mode session type is the extracted top-level AgentTabSession.
# `AgentModeViewModel.TabSession` must remain a source-compatibility typealias to
# that exact class (no parallel session authority), and Agent Mode runtime code
# must name AgentTabSession directly instead of the view-model-qualified alias.
agent_tab_session_source="Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentTabSession.swift"
if [[ ! -f "$agent_tab_session_source" ]]; then
  fail "required extracted agent session source missing: $agent_tab_session_source"
else
  if ! grep -q -F 'typealias TabSession = AgentTabSession' "$agent_tab_session_source"; then
    fail "AgentTabSession source lost the AgentModeViewModel.TabSession source-compatibility typealias"
  fi
fi
print_matches \
  "Agent Mode runtime source references the view-model-qualified session alias (use AgentTabSession)" \
  grep -R -n -F 'AgentModeViewModel.TabSession' \
    Sources/RepoPrompt/Features/AgentMode/Runtime

# 7. Removed IDE-era Prompt selected-files panel and Prompt-owned preset bottom bar
# artifacts must not return. The live compact selected-files surface is
# SelectedFilesGrid/FilePreviewPopover, and Settings owns its chat preset picker.
removed_prompt_cleanup_paths=(
  "Sources/RepoPrompt/Features/Prompt/Views/Components/PresetBottomBar.swift"
  "Sources/RepoPrompt/Features/Prompt/Views/Components/SelectedFileView.swift"
  "Sources/RepoPrompt/Features/Prompt/ViewModels/Selection/SelectedFilesPanelViewModel.swift"
)
for path in "${removed_prompt_cleanup_paths[@]}"; do
  if [[ -e "$path" ]]; then
    fail "removed Prompt UI cleanup artifact path exists: $path"
  fi
done

print_matches \
  "removed Prompt selected-files/preset-bottom-bar symbol referenced in Sources" \
  grep -R -n -E 'PresetBottomBar|SelectedFilesContentView|SelectedFilesPanelViewModel|PresetTwoPanePopover_Copy|CopyPresetPreviewView|PresetTwoPanePopover_Chat' \
    Sources/RepoPrompt

# 8. Agent-authored reports and working notes stay local unless explicitly
# promoted into the contributor-facing documentation set.
allowed_tracked_docs=(
  "docs/architecture/adr-0001-uniffi-raw-binder.md"
  "docs/architecture/adr-0002-hard-fork-baseline-identity-reset.md"
  "docs/architecture/adr-0003-rust-first-authority-non-waivable-contracts.md"
  "docs/architecture/adr-0004-utf8-text-contract-natural-sort.md"
  "docs/architecture/adr-0005-pcre2-jit-regex-engine.md"
  "docs/architecture/adr-0006-release-and-stopgap-policies.md"
  "docs/architecture/adr-0007-toolchain-supply-chain-controls.md"
  "docs/architecture/adr-0008-migration-economics-benchmark-gate.md"
  "docs/architecture/adr-0009-data-plane-schema-and-protocol-authority.md"
  "docs/architecture/adr-0010-vcs-backend-cli-subprocess-canonical.md"
  "docs/architecture/agentry-rewrite-charter.md"
  "docs/architecture/codex-app-server-schema-gate.md"
  "docs/architecture/context-composer.md"
  "docs/architecture/headless-mcp-runtime.md"
  "docs/architecture/provider-plugins.md"
  "docs/architecture/rust-agent-claude-v1.md"
  "docs/architecture/rust-agent-provider-v1.md"
  "docs/architecture/rust-apply-edits-compact-v1.md"
  "docs/architecture/rust-codemap-compact-v1.md"
  "docs/architecture/rust-ffi.md"
  "docs/architecture/rust-inventory-scope-v1.md"
  "docs/architecture/rust-search-leaf-v1.md"
  "docs/architecture/rust-search-parity-v1.md"
  "docs/architecture/rust-search-utf16-inventory-v1.md"
  "docs/architecture/settings-persistence.md"
  "docs/architecture/source-layout.md"
  "docs/architecture/xcode-workspace.md"
  "docs/designs/cross-restart-durability-root-search-cas-2026-06-25.md"
  "docs/mcp-progress.md"
  "docs/migrations/swift-6-2-concurrency-migration-2026-07-18.md"
  "docs/migrations/swift-6-2-concurrency/migration-ledger.md"
  "docs/open-source-readiness.md"
  "docs/privacy/telemetry.md"
  "docs/releasing.md"
  "docs/testing.md"
  "docs/spec/headless-mcp-domain-runtime-m0-contracts.md"
  "docs/spec/headless-mcp-domain-runtime-m0-editflowperf-baseline.json"
  "docs/spec/headless-mcp-domain-runtime-m2-context-authority.md"
  "docs/spec/headless-mcp-domain-runtime-m3-evidence.json"
  "docs/spec/headless-mcp-domain-runtime-m3-read-discovery.md"
  "docs/spec/headless-mcp-domain-runtime-m4-protected-mutations.md"
  "docs/spec/headless-mcp-domain-runtime-m5-ai-agent-interaction.md"
  "docs/spec/headless-mcp-domain-runtime-m6-host-extraction.md"
  "docs/spec/headless-mcp-domain-runtime-m7-cutover.md"
  "docs/spec/headless-mcp-domain-runtime-p8-rust-mcp-catalog-authority.md"
  "docs/spec/headless-mcp-domain-runtime-p9-catalog-handoff.md"
  "docs/spec/headless-mcp-domain-runtime-p10-admission-handoff.md"
  "docs/spec/headless-mcp-domain-runtime-p11-execution-handoff.md"
  "docs/spec/headless-mcp-domain-runtime-p12-agent-session-authority.md"
  "docs/spec/headless-mcp-domain-runtime-p13-agent-session-identity-authority.md"
  "docs/spec/headless-mcp-domain-runtime-p14-agent-run-lifecycle-authority.md"
  "docs/spec/headless-mcp-domain-runtime-p15-agent-run-terminal-commit-authority.md"
  "docs/spec/headless-mcp-domain-runtime-p5-0-storage-lease.md"
  "docs/spec/history-query-tools.md"
  "docs/spec/rust-workspace-document-projection-v1.md"
  "docs/spec/mcp-domain-canonical-tool-definitions.generated.json"
  "docs/worktrees.md"
  "docs/investigations/mcp-tool-throughput-wi3-baseline-2026-06-11.md"
  "docs/investigations/test-coverage-value-audit-ledger-2026-05-29.md"
  "docs/plans/test-coverage-value-audit-2026-05-29.md"
)
existing_tracked_docs=()
while IFS= read -r path; do
  if [[ -e "$path" ]]; then
    existing_tracked_docs+=("$path")
  fi
done < <(git ls-files docs)
unexpected_tracked_docs="$(comm -23 \
  <(printf '%s\n' "${existing_tracked_docs[@]}" | sort) \
  <(printf '%s\n' "${allowed_tracked_docs[@]}" | sort))"
if [[ -n "$unexpected_tracked_docs" ]]; then
  fail "unexpected tracked docs found; keep agent-authored working documents local or add durable docs to the explicit allowlist"
  printf '%s\n' "$unexpected_tracked_docs" >&2
fi

# 9. P4-1 inventory-authority binding constraints (rust-inventory-scope-v1.md §1.1/§1.2
# of docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md): the inventory
# tables are purely in-memory (no durable artifact, charter gate 4 does not bind P4)
# and the authority lives in exactly one GUI-process scope (charter gate 5 is GUI-only,
# headless never reads it). Both are asserted here so neither exemption can silently
# expire as the cutover proceeds.
print_matches \
  "inventory authority must not introduce a durable-artifact writer (DurableArtifact/persistCatalog/writeCatalog)" \
  grep -R -n -E 'DurableArtifact|persistCatalog|writeCatalog' \
    Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift \
    Sources/RepoPrompt/Infrastructure/WorkspaceContext/Inventory

print_matches \
  "headless RepoPromptMCP must not reference the GUI-only inventory authority (WorkspaceFileContextStore/InventoryScope)" \
  grep -R -n -E 'WorkspaceFileContextStore|InventoryScope' \
    Sources/RepoPromptMCP

# RepoPromptDomainRuntime's P3-2 Rust seam carries one known doc-comment reference
# naming the store it is not yet wired into (RustInventoryComputer.swift:11); anything
# beyond that single line is a real regression of the headless-isolation guardrail.
domain_runtime_inventory_refs="$(grep -R -n -E 'WorkspaceFileContextStore|InventoryScope' \
  Sources/RepoPromptDomainRuntime 2>/dev/null || true)"
unexpected_domain_runtime_inventory_refs="$(printf '%s\n' "$domain_runtime_inventory_refs" \
  | grep -v -F 'RustInventoryComputer.swift:11:' || true)"
if [[ -n "$unexpected_domain_runtime_inventory_refs" ]]; then
  fail "RepoPromptDomainRuntime must not reference the GUI-only inventory authority beyond the known RustInventoryComputer.swift:11 doc comment"
  printf '%s\n' "$unexpected_domain_runtime_inventory_refs" >&2
fi

# 10. P4-7b §4.1.0 co-location invariant, hardened to outright deletion at P4-7c c3
# (docs/architecture/rust-inventory-scope-v1.md, amended by
# docs/designs/p4-7-pathsearch-production-cutover-v2-2026-08-23.md §6.5): no build may ship where
# the inventory tables are served from Rust while the search facade builds a Swift path index over
# them. P4-7b b3 made that structurally unreachable (`makeRootPathSearchIndex` deleted, D-14); P4-7c
# c3 goes further and deletes the C-backed Swift index itself -- `PathSearchIndex.swift`,
# `Sources/RepoPromptC/src/Utils/path_search.c`, and `Sources/RepoPromptC/include/path_search.h` --
# so the invariant now holds by construction, not by a single surviving DEBUG-only exception. These
# checks guard against reintroduction: the deleted files must never come back, the deleted
# constructor name must never return, and the deleted types' call shapes (constructor calls, not
# bare type names -- doc-comment provenance references to the deleted history, e.g. in
# `WorkspaceSeededRootReplayVerdict.swift` and this slice's differential test suites, are
# deliberately preserved and must not trip this check) must never reappear anywhere in
# `Sources/RepoPrompt`.
print_matches \
  "removed makeRootPathSearchIndex (P4-7b §4.1.0 co-location invariant) must not return" \
  grep -R -n -F 'makeRootPathSearchIndex(' \
    Sources/RepoPrompt

for deleted_path_search_file in \
  "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift" \
  "Sources/RepoPromptC/src/Utils/path_search.c" \
  "Sources/RepoPromptC/include/path_search.h" \
  "Sources/RepoPromptDomainRuntime/PathSearch/RustPathSearchProbe.swift"; do
  if [[ -e "$deleted_path_search_file" ]]; then
    fail "deleted at P4-7c c3, must not be reintroduced: $deleted_path_search_file"
  fi
done

print_matches \
  "removed PathSearchIndex/WorkspaceSearchRootPathIndex/WorkspaceProjectedPathSearchIndex constructor calls (P4-7c c3 co-location invariant) must not return" \
  grep -R -n -E '(^|[^.[:alnum:]_])PathSearchIndex\(|PathSearchIndex\.build\(|WorkspaceSearchRootPathIndex\(|WorkspaceProjectedPathSearchIndex\(' \
    Sources/RepoPrompt

# `print_matches` reconstructs its command from unquoted `$@`, so a pattern argument containing a
# literal space would be re-split before reaching grep -- every alternative below is intentionally
# space-free (`path_search.h`'s own existence is already guarded by the file-existence loop above,
# so a stray `#include` of it is covered there, not duplicated here).
print_matches \
  "removed path_search.c C engine call sites (P4-7c c3 co-location invariant) must not return" \
  grep -R -n -E 'path_search_create\(|path_search_find\(|path_search_projected_find|path_search_destroy\(|path_search_cancellation_create\(' \
    Sources/RepoPrompt

# 11. RepoPromptC retirement and first-party native-source allowlist. First-party product logic
# remains Swift + Rust. The only compiled C surface is the narrow Rust ABI shim/header pair;
# CodeMap parser examples remain data-only resources, and third-party roots stay out of this scan.
for retired_repoprompt_c_path in \
  "Sources/RepoPromptC" \
  "Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h"; do
  if [[ -e "$retired_repoprompt_c_path" ]]; then
    fail "retired RepoPromptC topology must not return: $retired_repoprompt_c_path"
  fi
done

for required_rust_abi_path in \
  "Sources/CAgentryRustCore/shim.c" \
  "Sources/CAgentryRustCore/include/AgentryCoreFFI.h" \
  "Sources/CAgentryRustCore/include/module.modulemap" \
  "Sources/AgentryUniFFIRaw/Generated/AgentryCore.swift" \
  "Sources/AgentryUniFFIRaw/Generated/AgentryCoreBindingIdentity.swift"; do
  if [[ ! -f "$required_rust_abi_path" ]]; then
    fail "required generated Rust ABI surface missing: $required_rust_abi_path"
  fi
done

print_matches \
  "Package.swift must not restore the retired RepoPromptC target or dependency" \
  grep -n -E '(^|[^[:alnum:]_])RepoPromptC([^[:alnum:]_]|$)' Package.swift

print_matches \
  "first-party Swift must not import the retired RepoPromptC module" \
  grep -R -n -E '^[[:space:]]*import[[:space:]]+RepoPromptC([[:space:]]|$)' Sources Tests

# Exact retired call families from the deleted target. Bare historical prose is allowed; executable
# call shapes are not.
print_matches \
  "retired RepoPromptC repo_* call sites must not return" \
  grep -R -n -E 'repo_(get_file_descriptor_path|create_batch_buffer|free_batch_buffer|score_match|score_matches_batch|compile_wildcard|free_wildcard_pattern|levenshtein_distance|dice_coefficient|longest_common_subsequence|similarity_score|encode_indentation|decode_indentation|decode_html_entities|condense_whitespace|fnv1a64|escape_string|unescape_string|split_content_preserving|free_split|fuzzy_space_match|canonical_key|bulk_dice_best_match|remove_outer_backticks|trim_leading_whitespace|trim_common_leading_whitespace_preserving_endings|extract_description|extract_complexity|wildmatch|gitignore_match|normalize_pattern|parse_gitignore_line)\(' Sources Tests

native_source_files="$(find . -type f \
  \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' \
     -o -name '*.m' -o -name '*.mm' \
     -o -name '*.h' -o -name '*.hh' -o -name '*.hpp' -o -name '*.hxx' \) \
  -not -path './.git/*' \
  -not -path './.build/*' \
  -not -path './.swiftpm/*' \
  -not -path './DerivedData/*' \
  -not -path './build/*' \
  -not -path './Packages/RepoPromptAgentProviders/.build/*' \
  -not -path './Vendor/*' \
  -not -path './ThirdPartyLicenses/*' \
  -print | sed 's#^./##' | LC_ALL=C sort)"
unexpected_native_source_files=""
while IFS= read -r native_source_file; do
  [[ -z "$native_source_file" ]] && continue
  case "$native_source_file" in
    "Sources/CAgentryRustCore/shim.c"|\
    "Sources/CAgentryRustCore/include/AgentryCoreFFI.h"|\
    Tests/RepoPromptCodeMapCoreTests/Fixtures/c/*|\
    Tests/RepoPromptCodeMapCoreTests/Fixtures/cpp/*)
      ;;
    *)
      unexpected_native_source_files+="${unexpected_native_source_files:+$'\n'}$native_source_file"
      ;;
  esac
done <<< "$native_source_files"
if [[ -n "$unexpected_native_source_files" ]]; then
  fail "unexpected first-party C/C++/Objective-C source; only Rust ABI surfaces and explicit parser fixtures are allowed"
  printf '%s\n' "$unexpected_native_source_files" >&2
fi

# 12. P6-10 production-topology guardrail (docs/architecture/rust-agent-claude-v1.md §1.2,
# §15.9-§15.10): the interactive Claude native runtime remains a GUI-scope-only capability with one
# composition root. Standard Claude Code, GLM, Kimi, and custom-compatible variants all construct
# ClaudeRustBackedNativeSessionAdapter there. The obsolete Swift controller/codec/shadow stack and
# the temporary DEBUG selection/shadow bridge were deleted after the final caller audit and must not
# return. The coordinator is constructed only inside AgentModeViewModel, and Sources/RepoPromptMCP
# must construct none of these interactive-runtime symbols. Benign Claude text/classifier references
# in RepoPromptMCP remain allowed.
for retired_claude_runtime_file in \
  "Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeCompatibleNativeSessionAdapter.swift" \
  "Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/ClaudeRustBackedNativeSessionAdapterSelection.swift" \
  "Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeCodecShadowComparator.swift" \
  "Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift" \
  "Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeSDKNDJSONTranslator.swift" \
  "Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeSDKProtocolCodec.swift" \
  "Sources/AgentryCoreBridge/ClaudeCodecDebugShadowBridge.swift" \
  "rust/crates/runtime/src/agent_claude/debug_shadow.rs" \
  "rust/crates/runtime/src/agent_claude/debug_shadow_ffi.rs"; do
  if [[ -e "$retired_claude_runtime_file" ]]; then
    fail "retired at P6-10, must not be reintroduced: $retired_claude_runtime_file"
  fi
done

# P6-9: the Rust-backed adapter is the production authority for all four interactive variants,
# with no DEBUG-only selection flag or runtime rollback switch. Its single construction site remains
# the coordinator.
claude_rust_backed_adapter_construction_sites="$(grep -R -n -F 'ClaudeRustBackedNativeSessionAdapter(' \
  Sources/RepoPrompt 2>/dev/null || true)"
unexpected_claude_rust_backed_adapter_construction_sites="$(printf '%s\n' "$claude_rust_backed_adapter_construction_sites" \
  | grep -v -F 'Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift:' || true)"
if [[ -n "$unexpected_claude_rust_backed_adapter_construction_sites" ]]; then
  fail "ClaudeRustBackedNativeSessionAdapter must be constructed only inside ClaudeAgentModeCoordinator.makeDefaultController"
  printf '%s\n' "$unexpected_claude_rust_backed_adapter_construction_sites" >&2
fi

print_matches \
  "P6-9 removed Claude Rust adapter DEBUG selection flag must not return" \
  grep -R -n -E 'ClaudeRustBackedNativeSessionAdapterSelection|AGENTRY_CLAUDE_RUST_BACKED_ADAPTER' \
    Sources/RepoPrompt

claude_coordinator_construction_sites="$(grep -R -n -F 'ClaudeAgentModeCoordinator(' \
  Sources/RepoPrompt 2>/dev/null || true)"
unexpected_claude_coordinator_construction_sites="$(printf '%s\n' "$claude_coordinator_construction_sites" \
  | grep -v -F 'Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:' || true)"
if [[ -n "$unexpected_claude_coordinator_construction_sites" ]]; then
  fail "ClaudeAgentModeCoordinator must be constructed only inside AgentModeViewModel (the @MainActor GUI view model)"
  printf '%s\n' "$unexpected_claude_coordinator_construction_sites" >&2
fi

print_matches \
  "headless RepoPromptMCP must not construct the interactive Claude native runtime (ClaudeAgentModeCoordinator/ClaudeNativeProcessSessionController/ClaudeRustBackedNativeSessionAdapter)" \
  grep -R -n -E 'ClaudeAgentModeCoordinator\(|ClaudeNativeProcessSessionController\(|ClaudeRustBackedNativeSessionAdapter\(' \
    Sources/RepoPromptMCP

if [[ "$failures" -ne 0 ]]; then
  printf 'Source layout guardrails failed (%s issue%s).\n' "$failures" "$([[ "$failures" == 1 ]] && printf '' || printf 's')" >&2
  exit 1
fi

printf 'OK: source layout guardrails passed.\n'
