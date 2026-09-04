#!/usr/bin/env python3
from __future__ import annotations

from copy import deepcopy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


SCRIPT_PATH = Path(__file__).with_name("generate_xcode_workspace.py")
SPEC = importlib.util.spec_from_file_location("generate_xcode_workspace", SCRIPT_PATH)
assert SPEC and SPEC.loader
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class XcodeWorkspaceGeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = generator.load_package_manifest(generator.REPO_ROOT)
        cls.outputs = generator.render_outputs(generator.REPO_ROOT, cls.manifest)

    def generate_in_temporary_directory(self) -> tuple[tempfile.TemporaryDirectory, Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        destination = root / "xcode"
        generator.write_outputs(
            destination,
            self.outputs,
            default_destination=destination,
            custom_root=root / "custom",
            repository_root=root,
        )
        return temporary, destination

    def test_generation_is_byte_identical(self) -> None:
        temporary, destination = self.generate_in_temporary_directory()
        self.addCleanup(temporary.cleanup)
        first = {path.relative_to(destination): path.read_bytes() for path in destination.rglob("*") if path.is_file()}
        root = Path(temporary.name)
        generator.write_outputs(
            destination,
            self.outputs,
            default_destination=destination,
            custom_root=root / "custom",
            repository_root=root,
        )
        second = {path.relative_to(destination): path.read_bytes() for path in destination.rglob("*") if path.is_file()}
        self.assertEqual(first, second)

    def test_outputs_do_not_embed_checkout_path_or_timestamps(self) -> None:
        checkout = str(generator.REPO_ROOT).encode()
        for path, content in self.outputs.items():
            content_without_working_directory = content.replace(
                f'customWorkingDirectory = "{generator.REPO_ROOT}"'.encode(),
                b"",
            )
            self.assertNotIn(checkout, content_without_working_directory, str(path))
            self.assertNotRegex(content.decode(errors="ignore"), r"20\d\d-\d\d-\d\d[T ]")

    def test_workspace_references_project_and_root_package(self) -> None:
        workspace = self.outputs[Path(generator.WORKSPACE_NAME) / "contents.xcworkspacedata"].decode()
        self.assertIn("group:Agentry.xcodeproj", workspace)
        self.assertIn("group:../..", workspace)

    def test_custom_destination_uses_correct_relative_repository_path(self) -> None:
        destination = generator.REPO_ROOT / ".build/xcode-custom/team/workspace"
        outputs = generator.render_outputs(generator.REPO_ROOT, self.manifest, destination)
        workspace = outputs[Path(generator.WORKSPACE_NAME) / "contents.xcworkspacedata"].decode()
        self.assertIn("group:../../../..", workspace)
        metadata = json.loads(outputs[Path("generation.json")])
        self.assertEqual(metadata["repositoryRelativePath"], "../../../..")

    def test_project_has_delegated_test_scheme(self) -> None:
        path = Path(generator.PROJECT_NAME) / f"xcshareddata/xcschemes/{generator.TEST_SCHEME}.xcscheme"
        scheme = self.outputs[path].decode()
        self.assertIn(f'BlueprintName = "{generator.TEST_SCHEME}"', scheme)
        self.assertIn(f'ReferencedContainer = "container:{generator.PROJECT_NAME}"', scheme)

    def test_workspace_lockfile_is_exact_copy(self) -> None:
        copied = self.outputs[Path(generator.WORKSPACE_NAME) / "xcshareddata/swiftpm/Package.resolved"]
        self.assertEqual((generator.REPO_ROOT / "Package.resolved").read_bytes(), copied)

    def test_generated_readme_documents_native_xcode_limitations(self) -> None:
        readme = self.outputs[Path("README.md")].decode()
        self.assertIn("not mutate `Vendor/`", readme)
        self.assertIn("cargo test", readme)

    def test_developer_workflow_reads_only_agentry_xcode_environment(self) -> None:
        workflow = (generator.REPO_ROOT / "Scripts/xcode_developer_workflow.sh").read_text()
        self.assertIn("AGENTRY_XCODE_UNCOORDINATED", workflow)
        self.assertIn("cargo-test", workflow)
        self.assertNotIn("REPOPROMPT_XCODE_TEST_FILTER", workflow)
        self.assertNotIn("REPOPROMPT_XCODE_UNCOORDINATED", workflow)

    def test_manifest_preserves_thin_app_target_topology(self) -> None:
        products = {product["name"]: product for product in self.manifest["products"]}
        targets = {target["name"]: target for target in self.manifest["targets"]}

        self.assertEqual(products["Agentry"]["targets"], ["RepoPrompt"])
        self.assertEqual(products["agentry-mcp"]["targets"], ["RepoPromptMCP"])
        self.assertEqual(targets["RepoPrompt"]["type"], "executable")
        self.assertEqual(targets["RepoPrompt"]["path"], "Sources/RepoPromptExecutable")
        self.assertEqual(generator._by_name_dependencies(targets["RepoPrompt"]), ["RepoPromptApp"])
        self.assertEqual(len(targets["RepoPrompt"]["dependencies"]), 1)

        self.assertEqual(targets["RepoPromptApp"]["type"], "regular")
        self.assertEqual(targets["RepoPromptApp"]["path"], "Sources/RepoPrompt")
        self.assertNotIn("RepoPromptTests", targets)
        self.assertFalse(any(target.get("type") == "test" for target in self.manifest["targets"]))

        self.assertEqual(targets["RepoPromptDomainRuntime"]["type"], "regular")
        self.assertEqual(targets["RepoPromptDomainRuntime"]["path"], "Sources/RepoPromptDomainRuntime")
        self.assertEqual(
            generator._by_name_dependencies(targets["RepoPromptDomainRuntime"]),
            ["RepoPromptShared", "RepoPromptCodeMapCore", "AgentryCoreBridge"],
        )
        self.assertNotIn("RepoPromptC", targets)
        for name in ("RepoPromptApp", "RepoPromptDomainRuntime", "RepoPromptMCP"):
            self.assertNotIn("RepoPromptC", generator._by_name_dependencies(targets[name]))
        self.assertNotIn("RepoPromptDomainRuntimeTests", targets)

    def test_generation_metadata_records_internal_app_target(self) -> None:
        metadata = json.loads(self.outputs[Path("generation.json")])
        self.assertIn("RepoPrompt", metadata["package"]["targets"])
        self.assertIn("RepoPromptApp", metadata["package"]["targets"])
        self.assertIn("RepoPromptDomainRuntime", metadata["package"]["targets"])
        self.assertNotIn("RepoPromptDomainRuntimeTests", metadata["package"]["targets"])
        self.assertIn("CAgentryRustCore", metadata["package"]["targets"])
        self.assertIn("AgentryUniFFIRaw", metadata["package"]["targets"])
        self.assertIn("AgentryCoreBridge", metadata["package"]["targets"])
        self.assertNotIn("AgentryCoreBridgeTests", metadata["package"]["targets"])
        self.assertNotIn("RepoPromptC", metadata["package"]["targets"])

    def test_generated_outputs_omit_retired_c_target_and_bridging_header(self) -> None:
        rendered = b"\n".join(self.outputs.values())
        self.assertNotIn(b'"RepoPromptC"', rendered)
        self.assertNotIn(b"RepoPrompt-Bridging-Header.h", rendered)
        self.assertNotIn(b"SWIFT_OBJC_BRIDGING_HEADER", rendered)
        self.assertNotIn(b"-import-objc-header", rendered)

    def test_manifest_preserves_private_rust_ffi_target_chain(self) -> None:
        targets = {target["name"]: target for target in self.manifest["targets"]}
        self.assertEqual(targets["CAgentryRustCore"]["path"], "Sources/CAgentryRustCore")
        self.assertEqual(targets["CAgentryRustCore"]["sources"], ["shim.c"])
        self.assertEqual(targets["CAgentryRustCore"]["publicHeadersPath"], "include")
        self.assertTrue((generator.REPO_ROOT / "Sources/CAgentryRustCore/shim.c").is_file())
        self.assertTrue((generator.REPO_ROOT / "Sources/CAgentryRustCore/include/AgentryCoreFFI.h").is_file())
        self.assertTrue((generator.REPO_ROOT / "Sources/CAgentryRustCore/include/module.modulemap").is_file())
        c_settings = [
            setting.get("kind", {}).get("unsafeFlags", {}).get("_0", [])
            for setting in targets["CAgentryRustCore"].get("settings", [])
        ]
        self.assertTrue(
            any(any(flag.endswith("/libagentry_ffi.a") for flag in flags) for flags in c_settings)
        )
        self.assertEqual(generator._by_name_dependencies(targets["CAgentryRustCore"]), [])
        self.assertEqual(
            generator._by_name_dependencies(targets["AgentryUniFFIRaw"]),
            ["CAgentryRustCore"],
        )
        self.assertEqual(
            generator._by_name_dependencies(targets["AgentryCoreBridge"]),
            ["AgentryUniFFIRaw"],
        )
        self.assertNotIn("AgentryCoreBridgeTests", targets)
        products = {target for product in self.manifest["products"] for target in product["targets"]}
        self.assertTrue(
            {"CAgentryRustCore", "AgentryUniFFIRaw", "AgentryCoreBridge"}.isdisjoint(products)
        )

    def test_project_has_exactly_three_convenience_targets(self) -> None:
        project = self.outputs[Path(generator.PROJECT_NAME) / "project.pbxproj"].decode()
        self.assertEqual(project.count("isa = PBXLegacyTarget;"), 3)
        self.assertIn(generator.APP_SCHEME, project)
        self.assertIn(generator.MCP_SCHEME, project)
        self.assertIn(generator.TEST_SCHEME, project)

    def test_convenience_targets_do_not_pass_xcode_build_settings(self) -> None:
        project = self.outputs[Path(generator.PROJECT_NAME) / "project.pbxproj"].decode()
        self.assertEqual(project.count("passBuildSettingsInEnvironment = 0;"), 3)
        self.assertNotIn("passBuildSettingsInEnvironment = 1;", project)

    def test_app_scheme_has_runnable_markers_and_prepare_action(self) -> None:
        path = Path(generator.PROJECT_NAME) / f"xcshareddata/xcschemes/{generator.APP_SCHEME}.xcscheme"
        scheme = self.outputs[path].decode()
        self.assertIn(str(generator.DEFAULT_DEBUG_APP_BUNDLE), scheme)
        self.assertIn("AGENTRY_LAUNCH_SOURCE", scheme)
        self.assertIn("__XCODE_BUILT_PRODUCTS_DIR_PATHS", scheme)
        self.assertIn("prepare-app-run", scheme)
        self.assertNotIn("{repository_path}", scheme)

        document = ET.fromstring(scheme)
        launch_action = document.find("LaunchAction")
        profile_action = document.find("ProfileAction")
        self.assertIsNotNone(launch_action)
        self.assertIsNotNone(profile_action)
        expected_working_directory = str(generator.REPO_ROOT)
        self.assertEqual(
            launch_action.attrib["customWorkingDirectory"],
            expected_working_directory,
        )
        self.assertEqual(
            profile_action.attrib["customWorkingDirectory"],
            expected_working_directory,
        )
        self.assertTrue(Path(expected_working_directory).is_dir())
        expected_runnable = str(generator.DEFAULT_DEBUG_APP_BUNDLE)
        self.assertEqual(
            launch_action.find("PathRunnable").attrib["FilePath"],
            expected_runnable,
        )
        self.assertEqual(
            profile_action.find("PathRunnable").attrib["FilePath"],
            expected_runnable,
        )

        environment = {
            item.attrib["key"]: item.attrib["value"]
            for item in launch_action.findall("./EnvironmentVariables/EnvironmentVariable")
        }
        self.assertEqual(
            environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"],
            "$(PROJECT_DIR)/../../.build/debug",
        )

    def test_mcp_scheme_points_at_debug_executable(self) -> None:
        path = Path(generator.PROJECT_NAME) / f"xcshareddata/xcschemes/{generator.MCP_SCHEME}.xcscheme"
        self.assertIn(".build/debug/agentry-mcp", self.outputs[path].decode())

    def test_xcodebuild_list_uses_expected_command(self) -> None:
        payload = {
            "workspace": {
                "schemes": [
                    generator.APP_SCHEME,
                    generator.MCP_SCHEME,
                    generator.TEST_SCHEME,
                    generator.RUST_BRIDGE_TEST_SCHEME,
                    generator.NATIVE_APP_SCHEME,
                    generator.NATIVE_MCP_SCHEME,
                ],
            },
        }
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(payload),
            stderr="",
        )
        with patch.object(generator.subprocess, "run", return_value=completed) as run:
            generator.validate_xcodebuild_list(Path("/tmp/generated-xcode"))

        command = run.call_args.args[0]
        self.assertEqual(
            command,
            [
                "xcodebuild",
                "-list",
                "-json",
                "-workspace",
                "/tmp/generated-xcode/Agentry.xcworkspace",
            ],
        )
        self.assertNotIn("env", run.call_args.kwargs)

    def test_check_detects_corruption(self) -> None:
        temporary, destination = self.generate_in_temporary_directory()
        self.addCleanup(temporary.cleanup)
        generator.check_outputs(destination, self.outputs)
        (destination / "generation.json").write_text("{}\n")
        with self.assertRaisesRegex(generator.GeneratorError, "stale"):
            generator.check_outputs(destination, self.outputs)
        root = Path(temporary.name)
        generator.write_outputs(
            destination,
            self.outputs,
            default_destination=destination,
            custom_root=root / "custom",
            repository_root=root,
        )
        generator.check_outputs(destination, self.outputs)

    def test_check_ignores_xcode_user_state(self) -> None:
        temporary, destination = self.generate_in_temporary_directory()
        self.addCleanup(temporary.cleanup)
        user_state = (
            destination
            / generator.WORKSPACE_NAME
            / "xcuserdata/developer.xcuserdatad/UserInterfaceState.xcuserstate"
        )
        user_state.parent.mkdir(parents=True)
        user_state.write_text("local state")
        generator.check_outputs(destination, self.outputs)

    def test_check_remains_strict_for_unmanaged_files(self) -> None:
        temporary, destination = self.generate_in_temporary_directory()
        self.addCleanup(temporary.cleanup)
        unexpected = destination / generator.WORKSPACE_NAME / "unexpected.txt"
        unexpected.write_text("not managed")
        with self.assertRaisesRegex(generator.GeneratorError, "unexpected generated file"):
            generator.check_outputs(destination, self.outputs)

    def test_manifest_errors_are_actionable(self) -> None:
        missing_product = deepcopy(self.manifest)
        missing_product["products"] = [
            product for product in missing_product["products"] if product["name"] != "Agentry"
        ]
        with self.assertRaisesRegex(generator.GeneratorError, "executable product 'Agentry'"):
            generator.validate_manifest(missing_product, generator.REPO_ROOT)

        missing_target = deepcopy(self.manifest)
        missing_target["targets"] = [
            target for target in missing_target["targets"] if target["name"] != "RepoPromptShared"
        ]
        with self.assertRaisesRegex(generator.GeneratorError, "target 'RepoPromptShared'"):
            generator.validate_manifest(missing_target, generator.REPO_ROOT)

        missing_app_target = deepcopy(self.manifest)
        missing_app_target["targets"] = [
            target for target in missing_app_target["targets"] if target["name"] != "RepoPromptApp"
        ]
        with self.assertRaisesRegex(generator.GeneratorError, "target 'RepoPromptApp'"):
            generator.validate_manifest(missing_app_target, generator.REPO_ROOT)

        fat_executable = deepcopy(self.manifest)
        for target in fat_executable["targets"]:
            if target["name"] == "RepoPrompt":
                target["path"] = "Sources/RepoPrompt"
        with self.assertRaisesRegex(generator.GeneratorError, "thin Sources/RepoPromptExecutable"):
            generator.validate_manifest(fat_executable, generator.REPO_ROOT)

        wrong_executable_dependency = deepcopy(self.manifest)
        for target in wrong_executable_dependency["targets"]:
            if target["name"] == "RepoPrompt":
                target["dependencies"] = [{"byName": ["RepoPromptShared", None]}]
        with self.assertRaisesRegex(generator.GeneratorError, "depend only on 'RepoPromptApp'"):
            generator.validate_manifest(wrong_executable_dependency, generator.REPO_ROOT)

        restored_xctest_target = deepcopy(self.manifest)
        restored_xctest_target["targets"].append({
            "name": "RepoPromptTests",
            "type": "test",
            "path": "Tests/RepoPromptTests",
        })
        with self.assertRaisesRegex(generator.GeneratorError, "Swift XCTest target must not return"):
            generator.validate_manifest(restored_xctest_target, generator.REPO_ROOT)

        restored_c_target = deepcopy(self.manifest)
        restored_c_target["targets"].append({
            "name": "RepoPromptC",
            "type": "regular",
            "path": "Sources/RepoPromptC",
        })
        with self.assertRaisesRegex(generator.GeneratorError, "Retired first-party C target"):
            generator.validate_manifest(restored_c_target, generator.REPO_ROOT)

        restored_bridging_flags = deepcopy(self.manifest)
        target_map = {target["name"]: target for target in restored_bridging_flags["targets"]}
        target_map["RepoPromptApp"]["settings"].append({
            "kind": {"unsafeFlags": {"_0": [
                "-import-objc-header",
                "Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h",
                "-disable-bridging-pch",
            ]}},
            "tool": "swift",
        })
        with self.assertRaisesRegex(generator.GeneratorError, "must not restore"):
            generator.validate_manifest(restored_bridging_flags, generator.REPO_ROOT)

        missing_rust_bridge_target = deepcopy(self.manifest)
        missing_rust_bridge_target["targets"] = [
            target
            for target in missing_rust_bridge_target["targets"]
            if target["name"] != "AgentryCoreBridge"
        ]
        with self.assertRaisesRegex(generator.GeneratorError, "target 'AgentryCoreBridge'"):
            generator.validate_manifest(missing_rust_bridge_target, generator.REPO_ROOT)

        broken_rust_chain = deepcopy(self.manifest)
        for target in broken_rust_chain["targets"]:
            if target["name"] == "AgentryCoreBridge":
                target["dependencies"] = [{"byName": ["CAgentryRustCore", None]}]
        with self.assertRaisesRegex(generator.GeneratorError, "Rust FFI dependency chain drifted"):
            generator.validate_manifest(broken_rust_chain, generator.REPO_ROOT)

        app_missing_bridge = deepcopy(self.manifest)
        for target in app_missing_bridge["targets"]:
            if target["name"] == "RepoPromptApp":
                target["dependencies"] = [
                    dependency
                    for dependency in target["dependencies"]
                    if dependency.get("byName", [None])[0] != "AgentryCoreBridge"
                ]
        with self.assertRaisesRegex(generator.GeneratorError, "must depend exactly once on AgentryCoreBridge"):
            generator.validate_manifest(app_missing_bridge, generator.REPO_ROOT)

        app_imports_raw = deepcopy(self.manifest)
        for target in app_imports_raw["targets"]:
            if target["name"] == "RepoPromptApp":
                target["dependencies"].append({"byName": ["AgentryUniFFIRaw", None]})
        with self.assertRaisesRegex(generator.GeneratorError, "must not depend on raw Rust FFI"):
            generator.validate_manifest(app_imports_raw, generator.REPO_ROOT)

        exposed_bridge_product = deepcopy(self.manifest)
        exposed_bridge_product["products"].append(
            {"name": "AgentryCoreBridge", "targets": ["AgentryCoreBridge"], "type": {"library": ["automatic"]}}
        )
        with self.assertRaisesRegex(generator.GeneratorError, "must not be exposed"):
            generator.validate_manifest(exposed_bridge_product, generator.REPO_ROOT)

    def test_generation_does_not_modify_package_authority(self) -> None:
        before = {name: digest(generator.REPO_ROOT / name) for name in ("Package.swift", "Package.resolved")}
        temporary, _ = self.generate_in_temporary_directory()
        self.addCleanup(temporary.cleanup)
        after = {name: digest(generator.REPO_ROOT / name) for name in ("Package.swift", "Package.resolved")}
        self.assertEqual(before, after)

    def test_destination_rejects_destructive_paths(self) -> None:
        with self.assertRaisesRegex(generator.GeneratorError, "dedicated custom-output root"):
            generator.validate_destination(generator.REPO_ROOT)
        with self.assertRaisesRegex(generator.GeneratorError, "dedicated custom-output root"):
            generator.validate_destination(generator.REPO_ROOT / "Sources")

    def test_custom_destination_is_confined_to_dedicated_subtree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            default = root / "xcode"
            custom = root / "xcode-custom"
            accepted = generator.validate_destination(
                custom / "team/workspace",
                default,
                custom,
                root,
            )
            self.assertEqual(accepted, custom / "team/workspace")
            with self.assertRaisesRegex(generator.GeneratorError, "dedicated custom-output root"):
                generator.validate_destination(root / "other", default, custom, root)
            with self.assertRaisesRegex(generator.GeneratorError, "dedicated custom-output root"):
                generator.validate_destination(custom, default, custom, root)

    def test_existing_unowned_destination_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "xcode"
            destination.mkdir()
            sentinel = destination / "sentinel.txt"
            sentinel.write_text("keep me")
            with self.assertRaisesRegex(generator.GeneratorError, "non-generator-owned"):
                generator.write_outputs(
                    destination,
                    self.outputs,
                    default_destination=destination,
                    custom_root=root / "custom",
                    repository_root=root,
                )
            self.assertEqual(sentinel.read_text(), "keep me")

    def test_legacy_generated_destination_is_replaced_with_agentry_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "xcode"
            destination.mkdir()
            (destination / generator.LEGACY_OWNERSHIP_MARKER).write_text(
                f"{generator.LEGACY_GENERATOR_ID}\n"
            )
            (destination / "legacy-generated-file").write_text("replace me")

            generator.write_outputs(
                destination,
                self.outputs,
                default_destination=destination,
                custom_root=root / "custom",
                repository_root=root,
            )

            self.assertEqual(
                (destination / generator.OWNERSHIP_MARKER).read_text(),
                f"{generator.GENERATOR_ID}\n",
            )
            self.assertFalse((destination / generator.LEGACY_OWNERSHIP_MARKER).exists())
            self.assertFalse((destination / "legacy-generated-file").exists())

    def test_destination_rejects_symlink_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            destination = root / "xcode"
            destination.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(generator.GeneratorError, "symlinked destination component"):
                generator.validate_destination(
                    destination,
                    destination,
                    root / "custom",
                    root,
                )

    def test_uncoordinated_prepare_run_is_rejected_without_side_effects(self) -> None:
        environment = os.environ.copy()
        environment["CONFIGURATION"] = "Debug"
        environment["AGENTRY_XCODE_UNCOORDINATED"] = "1"
        result = subprocess.run(
            [generator.REPO_ROOT / "Scripts/xcode_developer_workflow.sh", "prepare-app-run"],
            cwd=generator.REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build/test-only", result.stderr)


if __name__ == "__main__":
    unittest.main()
