#!/usr/bin/env python3
"""Positive/negative coverage for Scripts/agent_session_boundary_guardrails.sh (ADR-0011 §9)."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "Scripts" / "agent_session_boundary_guardrails.sh"

AGENT_MODE = "Sources/RepoPrompt/Features/AgentMode"
VIEW_MODELS = f"{AGENT_MODE}/ViewModels"
VIEWS = f"{AGENT_MODE}/Views"
TAB_SESSION = f"{VIEW_MODELS}/AgentTabSession.swift"
SEAM = f"{AGENT_MODE}/Connection/AgentSessionConnection.swift"
COMPOSITION_ROOT = "Sources/RepoPrompt/App/WindowStateComposition.swift"
MCP_MAIN = "Sources/RepoPromptMCP/main.swift"

CLEAN_FIXTURE = {
    f"{VIEW_MODELS}/AgentModeViewModel.swift": (
        "import Foundation\n"
        "@MainActor final class AgentModeViewModel {\n"
        "    let sessionConnection: any AgentSessionConnection\n"
        "    init(sessionConnection: any AgentSessionConnection) { self.sessionConnection = sessionConnection }\n"
        "}\n"
    ),
    TAB_SESSION: (
        "import Foundation\n"
        "@MainActor final class AgentTabSession {\n"
        "    let tabID: UUID\n"
        "    var connectionAttachment: (any AgentSessionConnectionAttachment)?\n"
        "    var latestConnectionCursor: AgentSessionCursor?\n"
        "    init(tabID: UUID) { self.tabID = tabID }\n"
        "}\n"
    ),
    f"{VIEWS}/AgentModeView.swift": "import SwiftUI\nstruct AgentModeView: View { var body: some View { Text(\"agent\") } }\n",
    SEAM: (
        "import Foundation\n"
        "protocol AgentSessionConnection: Actor {\n"
        "    func detach(sessionID: UUID) async\n"
        "}\n"
        "protocol AgentSessionConnectionAttachment: AnyObject {}\n"
        "struct AgentSessionCursor: Hashable { let generation: Data; let deliveryCursor: UInt64 }\n"
    ),
    f"{AGENT_MODE}/Connection/InProcess/InProcessAgentSessionConnection.swift": (
        "import Foundation\n"
        "actor InProcessAgentSessionConnection: AgentSessionConnection {\n"
        "    func detach(sessionID: UUID) async {}\n"
        "}\n"
    ),
    f"{AGENT_MODE}/Runtime/Codex/CodexAgentModeCoordinator.swift": (
        "import Foundation\n"
        "final class CodexAgentModeCoordinator {\n"
        "    func controller(for session: AgentTabSession) -> CodexAppServerClient? { nil }\n"
        "}\n"
    ),
    COMPOSITION_ROOT: (
        "import Foundation\n"
        "enum WindowStateComposition {\n"
        "    static func make() -> AgentModeViewModel {\n"
        "        AgentModeViewModel(sessionConnection: HostAgentSessionConnection())\n"
        "    }\n"
        "}\n"
    ),
    MCP_MAIN: "import Foundation\nprint(\"agentry-mcp\")\n",
}


class AgentSessionBoundaryGuardrailTests(unittest.TestCase):
    def run_guardrail(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), str(root)],
            capture_output=True,
            text=True,
            check=False,
        )

    def write_fixture(self, root: Path, overrides: dict[str, str] | None = None) -> None:
        files = dict(CLEAN_FIXTURE)
        if overrides:
            files.update(overrides)
        for relative, content in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    def assert_fails_with(self, overrides: dict[str, str], expected_message: str) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_fixture(root, overrides)
            result = self.run_guardrail(root)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn(expected_message, result.stderr)
            self.assertNotIn("guardrails passed", result.stdout)

    def test_clean_fixture_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_fixture(root)
            result = self.run_guardrail(root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Agent session boundary guardrails passed.", result.stdout)

    def test_repository_passes(self) -> None:
        result = self.run_guardrail(REPO_ROOT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Agent session boundary guardrails passed.", result.stdout)

    def test_aggregator_runs_boundary_guardrail(self) -> None:
        aggregator = (REPO_ROOT / "Scripts" / "guardrails.sh").read_text(encoding="utf-8")
        self.assertIn("./Scripts/agent_session_boundary_guardrails.sh", aggregator)

    def test_provider_execution_types_are_rejected_in_view_models(self) -> None:
        for symbol in (
            "ClaudeRustBackedNativeSessionAdapter",
            "CodexAppServerClient",
            "ACPAgentSessionController",
            "CoreAgentSession",
            "CoreAgentProviderSession",
        ):
            with self.subTest(symbol=symbol):
                self.assert_fails_with(
                    {f"{VIEW_MODELS}/Leak.swift": f"import Foundation\nlet leak: {symbol}? = nil\n"},
                    "must not reference provider execution types",
                )

    def test_provider_execution_types_are_rejected_in_views(self) -> None:
        self.assert_fails_with(
            {f"{VIEWS}/Leak.swift": "import SwiftUI\nstruct Leak { let client: CodexAppServerClient? }\n"},
            "must not reference provider execution types",
        )

    def test_socket_paths_are_rejected(self) -> None:
        for snippet in (
            'let path = "/tmp/agentry-mcp/agentry-agent-host-v1.sock"',
            "let socketPath = URL(fileURLWithPath: path)",
            "var address = sockaddr_un()",
            "let identity = MCPFilesystemIdentity.shared",
        ):
            with self.subTest(snippet=snippet):
                self.assert_fails_with(
                    {f"{VIEW_MODELS}/Leak.swift": f"import Foundation\n{snippet}\n"},
                    "must not reference socket paths or transport primitives",
                )

    def test_host_protocol_types_are_rejected(self) -> None:
        for symbol in ("HostAgentSessionConnection", "AgentSessionHostRuntime", "AgentHostFrameV1"):
            with self.subTest(symbol=symbol):
                self.assert_fails_with(
                    {f"{VIEW_MODELS}/Leak.swift": f"import Foundation\nlet host: {symbol}? = nil\n"},
                    "must not reference host protocol types",
                )

    def test_concrete_connection_and_execution_state_are_rejected_in_presentation(self) -> None:
        for snippet in (
            "let connection = InProcessAgentSessionConnection()",
            "let state: InProcessAgentSessionExecutionState? = nil",
            "let controller = session.inProcessExecution.codexController",
        ):
            with self.subTest(snippet=snippet):
                self.assert_fails_with(
                    {f"{VIEW_MODELS}/Leak.swift": f"import Foundation\n{snippet}\n"},
                    "must not reference the concrete in-process connection or its execution state",
                )

    def test_controller_handles_are_rejected_in_presentation(self) -> None:
        for member in ("codexController", "claudeController", "acpController"):
            with self.subTest(member=member):
                self.assert_fails_with(
                    {f"{VIEW_MODELS}/Leak.swift": f"import Foundation\nfunc probe(_ s: AnyObject) -> Bool {{ s.{member} != nil }}\n"},
                    "must not reference provider controller handles",
                )

    def test_execution_commands_are_rejected_in_presentation(self) -> None:
        for snippet in (
            "func go(_ s: AnyObject) async { await runService.startRun(tabID: UUID(), session: s) }",
            "func go(_ s: AnyObject) async { await runService.cancelRun(tabID: UUID(), session: s) }",
            "func go(_ s: AnyObject) { codexCoordinator.submitApprovalDecision(session: s, decision: .accept) }",
            "func go(_ s: AnyObject) { claudeCoordinator.submitApprovalDecision(session: s, decision: .accept) }",
        ):
            with self.subTest(snippet=snippet):
                self.assert_fails_with(
                    {f"{VIEW_MODELS}/Leak.swift": f"import Foundation\n{snippet}\n"},
                    "must not reference execution commands on the run service or coordinators",
                )

    def test_constructing_the_run_service_in_presentation_is_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_fixture(
                root,
                {
                    f"{VIEW_MODELS}/Wiring.swift": (
                        "import Foundation\n"
                        "func make() -> AgentModeRunService { AgentModeRunService(dependencies: deps, hooks: hooks) }\n"
                        "// cancelAgentRun → runService.cancelRun only uses agentTask for a belt-and-suspenders call\n"
                    )
                },
            )
            result = self.run_guardrail(root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_tab_session_may_not_store_controllers(self) -> None:
        for declaration in (
            "var codexController: AnyObject?",
            "var claudeController: AnyObject?",
            "var acpController: AnyObject?",
            "var provider: AnyObject?",
        ):
            with self.subTest(declaration=declaration):
                self.assert_fails_with(
                    {
                        TAB_SESSION: (
                            "import Foundation\n"
                            "@MainActor final class AgentTabSession {\n"
                            f"    {declaration}\n"
                            "}\n"
                        )
                    },
                    "AgentTabSession must not store provider controllers",
                )

    def test_concrete_connection_construction_outside_composition_root_is_rejected(self) -> None:
        self.assert_fails_with(
            {
                f"{AGENT_MODE}/Runtime/Bootstrap.swift": (
                    "import Foundation\nlet connection = InProcessAgentSessionConnection()\n"
                )
            },
            "InProcessAgentSessionConnection is tests-only",
        )

    def test_seam_protocol_must_exist_as_actor_protocol(self) -> None:
        self.assert_fails_with(
            {SEAM: "import Foundation\nprotocol AgentSessionConnection: AnyObject {}\n"},
            "must declare 'protocol AgentSessionConnection: Actor'",
        )

    def test_mcp_target_may_not_import_appkit(self) -> None:
        self.assert_fails_with(
            {MCP_MAIN: "import AppKit\nprint(\"agentry-mcp\")\n"},
            "Sources/RepoPromptMCP must remain independent of AppKit and SwiftUI",
        )

    def test_every_finding_is_reported_before_failing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_fixture(
                root,
                {
                    f"{VIEW_MODELS}/Leak.swift": (
                        "import Foundation\n"
                        "let client: CodexAppServerClient? = nil\n"
                        "let host: HostAgentSessionConnection? = nil\n"
                    )
                },
            )
            result = self.run_guardrail(root)
            self.assertEqual(result.returncode, 1)
            self.assertIn("provider execution types", result.stderr)
            self.assertIn("host protocol types", result.stderr)
            self.assertIn("failed (2 finding(s))", result.stderr)


if __name__ == "__main__":
    unittest.main()
