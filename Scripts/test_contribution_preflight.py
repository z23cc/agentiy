#!/usr/bin/env python3
"""Regression tests for the Agentry contribution preflight safety gate."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
PREFLIGHT_SOURCE = REPO_ROOT / ".agents/skills/rpce-contribution-check/scripts/preflight.sh"

GUARDRAILS_TARGET = "guardrails"
HEAVYWEIGHT_MAKE_TARGETS = [
    "conductor-selftest",
    "dev-lint",
    "xcode-generator-test",
    "dev-cargo-test",
    "dev-cargo-codegen-check",
    "dev-cargo-deny",
]
ORDINARY_SUBPROCESS_TIMEOUT_SECONDS = 90


class ContributionPreflightTests(unittest.TestCase):
    def run_git(self, repo: Path, *args: str) -> None:
        subprocess.run(["git", *args], cwd=repo, check=True, text=True, capture_output=True)

    def write_stub(self, bin_dir: Path, name: str, log_env_name: str) -> None:
        stub = bin_dir / name
        stub.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            f"printf '%s\\n' \"$*\" >> \"${{{log_env_name}:?}}\"\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)

    def create_repo(self, root: Path, *, outgoing_path: str | None = None) -> tuple[Path, Path, dict[str, str]]:
        repo = root / "work"
        repo.mkdir()
        self.run_git(repo, "init", "-b", "main")
        self.run_git(repo, "config", "user.name", "Preflight Tests")
        self.run_git(repo, "config", "user.email", "preflight-tests@example.invalid")

        preflight = repo / ".agents/skills/rpce-contribution-check/scripts/preflight.sh"
        preflight.parent.mkdir(parents=True)
        shutil.copy2(PREFLIGHT_SOURCE, preflight)
        preflight.chmod(0o755)
        (repo / ".gitignore").write_text(".build/\n", encoding="utf-8")
        (repo / "README.md").write_text("fixture\n", encoding="utf-8")
        self.run_git(repo, "add", ".")
        self.run_git(repo, "commit", "-m", "initial")
        self.run_git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        self.run_git(repo, "checkout", "-b", "feature")

        if outgoing_path is not None:
            target = repo / outgoing_path
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                target.write_text(target.read_text(encoding="utf-8") + "\n# fixture change\n", encoding="utf-8")
            else:
                target.write_text("// fixture\n", encoding="utf-8")
            self.run_git(repo, "add", outgoing_path)
            self.run_git(repo, "commit", "-m", "feature change")

        bin_dir = root / "bin"
        bin_dir.mkdir()
        self.write_stub(bin_dir, "make", "RPCE_STUB_MAKE_LOG")
        self.write_stub(bin_dir, "gitleaks", "RPCE_STUB_GITLEAKS_LOG")
        fixture_python = Path("/usr/bin/python3")
        if sys.platform != "darwin" or not fixture_python.exists():
            fixture_python = Path(sys.executable)
        (bin_dir / "python3").symlink_to(fixture_python)

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
        env["RPCE_STUB_MAKE_LOG"] = str(root / "make.log")
        env["RPCE_STUB_GITLEAKS_LOG"] = str(root / "gitleaks.log")
        env["TMPDIR"] = str(root)
        return repo, preflight, env

    def run_preflight(self, repo: Path, preflight: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(preflight), *args],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            timeout=ORDINARY_SUBPROCESS_TIMEOUT_SECONDS,
        )

    def log_lines(self, env: dict[str, str], name: str) -> list[str]:
        path = Path(env[name])
        if not path.exists():
            return []
        return path.read_text(encoding="utf-8").splitlines()

    def make_lines(self, env: dict[str, str]) -> list[str]:
        return self.log_lines(env, "RPCE_STUB_MAKE_LOG")

    def gitleaks_lines(self, env: dict[str, str]) -> list[str]:
        return self.log_lines(env, "RPCE_STUB_GITLEAKS_LOG")

    def assert_no_heavyweight_make_targets(self, make_lines: list[str]) -> None:
        for target in HEAVYWEIGHT_MAKE_TARGETS:
            self.assertNotIn(target, make_lines)

    def test_push_is_safety_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="Sources/RepoPrompt/Example.swift"
            )

            result = self.run_preflight(repo, preflight, env, "push")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(self.make_lines(env), [GUARDRAILS_TARGET])
            self.assert_no_heavyweight_make_targets(self.make_lines(env))
            self.assertTrue(
                any(line.startswith("git ") and "--log-opts=" in line for line in self.gitleaks_lines(env))
            )
            self.assertIn("whitespace, secrets, and guardrails only", result.stdout)

    def test_pr_ready_is_a_push_synonym(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="Sources/RepoPrompt/Example.swift"
            )

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(self.make_lines(env), [GUARDRAILS_TARGET])
            self.assert_no_heavyweight_make_targets(self.make_lines(env))
            self.assertIn("whitespace, secrets, and guardrails only", result.stdout)

    def test_commit_scans_staged_index_without_push_or_heavy_lanes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(Path(tmp))
            staged = repo / "staged.txt"
            staged.write_text("fixture\n", encoding="utf-8")
            self.run_git(repo, "add", "staged.txt")

            result = self.run_preflight(repo, preflight, env, "commit")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(self.make_lines(env), [GUARDRAILS_TARGET])
            self.assert_no_heavyweight_make_targets(self.make_lines(env))
            gitleaks_lines = self.gitleaks_lines(env)
            self.assertTrue(any(line.startswith("dir ") for line in gitleaks_lines))
            self.assertFalse(any(line.startswith("git ") for line in gitleaks_lines))

    def test_extra_arguments_fail_instead_of_silently_ignoring_full_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="Sources/RepoPrompt/Example.swift"
            )

            result = self.run_preflight(repo, preflight, env, "push", "--full")

            self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
            self.assertIn("usage:", result.stderr + result.stdout)
            self.assertEqual(self.make_lines(env), [])
            self.assertEqual(self.gitleaks_lines(env), [])

    def test_signal_traps_and_direct_execution_remain_unchanged(self) -> None:
        source = PREFLIGHT_SOURCE.read_text(encoding="utf-8")
        for expected in [
            "trap 'exit 129' HUP",
            "trap 'exit 130' INT",
            "trap 'exit 143' TERM",
        ]:
            self.assertIn(expected, source)
        for forbidden in ["run_foreground", "signal-relay", "set -m", "kill -s"]:
            self.assertNotIn(forbidden, source)


class NativeSourceGuardrailTests(unittest.TestCase):
    def copy_guardrail_fixture(self, destination: Path) -> Path:
        fixture = destination / "repo"
        shutil.copytree(
            REPO_ROOT,
            fixture,
            ignore=shutil.ignore_patterns(
                ".build",
                ".git",
                "__pycache__",
                "prompt-exports",
                "target",
                "ThirdPartyLicenses",
                "Vendor",
            ),
        )
        return fixture

    def run_source_layout_guardrail(self, fixture: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "Scripts/source_layout_guardrails.sh"],
            cwd=fixture,
            text=True,
            capture_output=True,
            timeout=60,
        )

    def test_first_party_native_source_allowlist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fixture = self.copy_guardrail_fixture(Path(tmp))

            allowed_paths = (
                "Sources/CAgentryRustCore/shim.c",
                "Sources/CAgentryRustCore/include/AgentryCoreFFI.h",
                "ThirdPartyLicenses/guardrail_fixture.c",
                "Vendor/guardrail_fixture.mm",
            )
            for relative_path in allowed_paths[2:]:
                path = fixture / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("/* guardrail fixture */\n", encoding="utf-8")
            for relative_path in allowed_paths[:2]:
                self.assertTrue((fixture / relative_path).is_file(), relative_path)

            allowed = self.run_source_layout_guardrail(fixture)
            self.assertEqual(allowed.returncode, 0, allowed.stderr + allowed.stdout)
            self.assertIn("OK: source layout guardrails passed.", allowed.stdout)

            forbidden_product_paths = (
                "Sources/RepoPrompt/GuardrailFixture.c",
                "Sources/RepoPrompt/GuardrailFixture.mm",
            )
            for relative_path in forbidden_product_paths:
                (fixture / relative_path).write_text("/* forbidden product source */\n", encoding="utf-8")

            forbidden_products = self.run_source_layout_guardrail(fixture)
            forbidden_output = forbidden_products.stderr + forbidden_products.stdout
            self.assertNotEqual(forbidden_products.returncode, 0, forbidden_output)
            self.assertIn("unexpected first-party C/C++/Objective-C source", forbidden_output)
            for relative_path in forbidden_product_paths:
                self.assertIn(relative_path, forbidden_output)
                (fixture / relative_path).unlink()

            native_target_dir = fixture / "Sources/NativeGuardrailFixture"
            native_target_dir.mkdir()
            (native_target_dir / "fixture.c").write_text("void guardrail_fixture(void) {}\n", encoding="utf-8")
            package_path = fixture / "Package.swift"
            package_text = package_path.read_text(encoding="utf-8")
            insertion_point = "        .binaryTarget(name: \"Sparkle\", path: \"Vendor/Sparkle/Sparkle.xcframework\")"
            self.assertIn(insertion_point, package_text)
            package_path.write_text(
                package_text.replace(
                    insertion_point,
                    "        .target(\n"
                    "            name: \"NativeGuardrailFixture\",\n"
                    "            path: \"Sources/NativeGuardrailFixture\",\n"
                    "            sources: [\"fixture.c\"]\n"
                    "        ),\n"
                    + insertion_point,
                    1,
                ),
                encoding="utf-8",
            )

            native_target = self.run_source_layout_guardrail(fixture)
            native_target_output = native_target.stderr + native_target.stdout
            self.assertNotEqual(native_target.returncode, 0, native_target_output)
            self.assertIn(
                "first-party SwiftPM target must not compile C-family sources: "
                "NativeGuardrailFixture: ['fixture.c']",
                native_target_output,
            )


if __name__ == "__main__":
    unittest.main()
