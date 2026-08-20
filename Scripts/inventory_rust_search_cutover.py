#!/usr/bin/env python3
"""Generate/check the P1 Rust search cutover UTF-16 and regex inventory."""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
OUTPUT = ROOT / "docs/architecture/rust-search-utf16-inventory-v1.md"

SYMBOL_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (".utf16", re.compile(r"\.utf16")),
    ("NSRange", re.compile(r"\bNSRange\b")),
    ("NSRegularExpression", re.compile(r"\bNSRegularExpression\b")),
    ("RepoPromptRegexCore", re.compile(r"\bRepoPromptRegexCore\b")),
    ("CSwiftPCRE2", re.compile(r"\bCSwiftPCRE2\b")),
    ("repo_wildmatch", re.compile(r"\brepo_wildmatch\b")),
)

REMOVED_PREFIXES = (
    "Sources/CSwiftPCRE2/",
    "Sources/RepoPromptRegexCore/",
)
REMOVED_FILES = {
    "Sources/RepoPrompt/Infrastructure/Regex/PCRE2RegexAdapter.swift",
    "Sources/RepoPrompt/Infrastructure/Regex/PCRE2SearchFastPlans.swift",
}
RENDERING_PREFIXES = (
    "Sources/RepoPrompt/Features/AgentMode/Runtime/Transcript/",
    "Sources/RepoPrompt/Features/AgentMode/Views/",
    "Sources/RepoPrompt/Infrastructure/UI/",
)
RENDERING_FILES = {
    "Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+Types.swift",
    "Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift",
    "Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/FileViewModel.swift",
}
BLOCKER_FILES = {
    "Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h",
    "Sources/RepoPromptCodeMapCore/Extraction/CodeMapPCRE2Regex.swift",
}
CONVERSION_FILES = {
    "Sources/RepoPrompt/Features/Search/SearchMatch.swift",
    "Sources/RepoPrompt/Features/Search/SearchPathFiltering.swift",
    "Sources/RepoPrompt/Infrastructure/Regex/RegexToolkit.swift",
}

CATEGORIES = (
    "removed-with-search-core",
    "rendering-boundary-retained",
    "vendored-delete-blocker",
    "out-of-scope-non-search",
    "requires-p1-conversion",
)

BOUNDARY_AUDIT = (
    ("Sources/RepoPromptWorkspaceCore/StandardizedPath.swift", "excluded", "Path normalization/containment policy remains in WorkspaceCore; no search-leaf ownership."),
    ("Sources/RepoPromptWorkspaceCore/WorkspacePathPolicy.swift", "excluded", "Workspace alias, lookup, authority, and display-path policy remain in WorkspaceCore."),
    ("Tests/RepoPromptWorkspaceCoreTests/WorkspacePathPolicyTests.swift", "excluded oracle", "Retains boundary tests for normalization, aliases, ambiguity, containment, and root selection."),
    ("Tests/RepoPromptRegexCoreTests/PCRE2RegexTests.swift", "migration oracle", "Covers UTF-8 byte ranges, zero-length Unicode progress, limits, sessions, and escaping."),
    ("Tests/RepoPromptRegexCoreTests/PCRE2JITTests.swift", "migration oracle", "Covers legacy JIT environment mapping and disabled/auto/required outcomes."),
    ("Sources/RepoPrompt/Infrastructure/Regex/PCRE2JIT.swift", "absent at baseline", "The planned path does not exist at HEAD; do not create it."),
    ("Sources/RepoPromptRegexCore/RepoPromptRegexRuntime.swift", "actual JIT policy", "Owns REPOPROMPT_PCRE2_JIT mapping in the current implementation."),
    ("Sources/RepoPromptRegexCore/SwiftPCRE2/PCRE2JIT.swift", "actual JIT implementation", "Owns PCRE2 JIT support/probe/stack behavior and is removed with the old search core."),
    ("Sources/RepoPromptCodeMapCore/Extraction/CodeMapPCRE2Regex.swift", "vendored-delete-blocker", "Codemap is out of P1 search scope but must stop consuming RepoPromptRegexCore before vendored deletion."),
    ("Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h", "vendored-delete-blocker", "Contains the CSwiftPCRE2 header include and search wildmatch declaration."),
)

APP_HOOKS = (
    ("Sources/RepoPromptExecutable/RepoPromptExecutable.swift:3", "thin executable @main; delegates to RepoPromptApplication.main()."),
    ("Sources/RepoPrompt/App/RepoPromptApp.swift:109", "SwiftUI composition root via @NSApplicationDelegateAdaptor(AppDelegate.self)."),
    ("Sources/RepoPrompt/App/AppDelegate.swift:21", "NSApplicationDelegate process-lifecycle owner."),
    ("Sources/RepoPrompt/App/AppDelegate.swift:196", "applicationShouldTerminate async shutdown coordination hook."),
    ("Sources/RepoPrompt/App/AppDelegate.swift:227", "applicationWillTerminate defensive synchronous fallback hook."),
)


def category_for(path: str) -> str | None:
    if path.startswith(REMOVED_PREFIXES) or path in REMOVED_FILES:
        return "removed-with-search-core"
    if path in BLOCKER_FILES:
        return "vendored-delete-blocker"
    if path in CONVERSION_FILES:
        return "requires-p1-conversion"
    if path.startswith(RENDERING_PREFIXES) or path in RENDERING_FILES:
        return "rendering-boundary-retained"
    if path.startswith("Sources/"):
        return "out-of-scope-non-search"
    return None


def scan() -> tuple[list[tuple[str, int, tuple[str, ...], str]], list[str]]:
    records: list[tuple[str, int, tuple[str, ...], str]] = []
    unclassified: list[str] = []
    for path in sorted(p for p in SOURCES.rglob("*") if p.is_file()):
        relative = path.relative_to(ROOT).as_posix()
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(lines, start=1):
            symbols = tuple(name for name, pattern in SYMBOL_PATTERNS if pattern.search(line))
            if not symbols:
                continue
            category = category_for(relative)
            if category is None:
                unclassified.append(f"{relative}:{line_number}")
                continue
            records.append((relative, line_number, symbols, category))
    return records, unclassified


def render(records: list[tuple[str, int, tuple[str, ...], str]]) -> str:
    counts = Counter(record[3] for record in records)
    file_counts = {category: len({record[0] for record in records if record[3] == category}) for category in CATEGORIES}
    lines = [
        "# Rust Search UTF-16 and Regex Inventory v1",
        "",
        "> Generated by `python3 Scripts/inventory_rust_search_cutover.py`. Do not edit by hand.",
        "",
        "## Scope and classification policy",
        "",
        "This inventory covers every source line under `Sources/` containing `.utf16`, `NSRange`, `NSRegularExpression`, `RepoPromptRegexCore`, `CSwiftPCRE2`, or `repo_wildmatch`. A source line is one use point even when it contains more than one tracked symbol. Regeneration is review-only; CI uses `--check`, so any added, removed, or shifted use point makes the checked document stale.",
        "",
        "- `removed-with-search-core`: disappears with the old Swift/C regex search implementation.",
        "- `rendering-boundary-retained`: remains only in AppKit/TextKit/snippet or presentation conversion code.",
        "- `vendored-delete-blocker`: out-of-domain consumer/include that must be converted before deleting the vendored target.",
        "- `out-of-scope-non-search`: belongs to codemap, MCP, domain runtime, parsing, persistence, process, diff, or another non-P1 domain.",
        "- `requires-p1-conversion`: production search behavior that must move to the Rust leaf or to the final Swift rendering materializer.",
        "",
        "## Classification summary",
        "",
        "| Classification | Use points | Files |",
        "|---|---:|---:|",
    ]
    for category in CATEGORIES:
        lines.append(f"| `{category}` | {counts[category]} | {file_counts[category]} |")
    lines.extend(["", f"**Total:** {len(records)} use points across {len({record[0] for record in records})} files.", ""])

    for category in CATEGORIES:
        lines.extend([f"## `{category}`", "", "| Location | Symbols |", "|---|---|"])
        for path, line_number, symbols, record_category in records:
            if record_category == category:
                rendered_symbols = ", ".join(f"`{symbol}`" for symbol in symbols)
                lines.append(f"| `{path}:{line_number}` | {rendered_symbols} |")
        lines.append("")

    lines.extend(["## Boundary hard-gate audit", "", "| Path | Status | P1 disposition |", "|---|---|---|"])
    for path, status, disposition in BOUNDARY_AUDIT:
        lines.append(f"| `{path}` | {status} | {disposition} |")

    lines.extend(["", "## App composition and termination hooks", "", "Mechanical locator:", "", "```bash", "rg -n '@main|NSApplicationDelegate|applicationWillTerminate|applicationShouldTerminate' \\", "  Sources/RepoPrompt Sources/RepoPromptExecutable", "```", "", "Search-string false positives such as worktree selector `@main` values are not lifecycle hooks. The actionable results are:", ""])
    for location, disposition in APP_HOOKS:
        lines.append(f"- `{location}` — {disposition}")

    lines.extend(["", "No product code is changed by this inventory. Workspace authority and codemap remain outside the Rust search leaf.", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if the generated inventory is stale or has unclassified uses")
    args = parser.parse_args()

    records, unclassified = scan()
    if unclassified:
        print("unclassified Rust search cutover inventory uses:", file=sys.stderr)
        for item in unclassified:
            print(f"  {item}", file=sys.stderr)
        return 1

    generated = render(records)
    if args.check:
        if not OUTPUT.exists():
            print(f"missing generated inventory: {OUTPUT.relative_to(ROOT)}", file=sys.stderr)
            return 1
        existing = OUTPUT.read_text(encoding="utf-8")
        if existing != generated:
            print(
                "Rust search cutover inventory is stale; regenerate with "
                "`python3 Scripts/inventory_rust_search_cutover.py` and review classifications.",
                file=sys.stderr,
            )
            return 1
        print(f"Rust search cutover inventory is current ({len(records)} use points).")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(generated, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(records)} use points)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
