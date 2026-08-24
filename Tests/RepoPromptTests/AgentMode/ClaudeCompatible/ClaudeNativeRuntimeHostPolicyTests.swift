import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeNativeRuntimeHostPolicyTests: XCTestCase {
    enum ResolverError: Error {
        case unsupportedModel
    }

    actor RecordingLaunchEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
        private(set) var requestedModels: [String?] = []

        func resolve(
            variant _: ClaudeCodeRuntimeVariant,
            requestedModel: String?
        ) async throws -> ClaudeCodeLaunchEnvironment {
            requestedModels.append(requestedModel)
            guard requestedModel != "glm-5-turbo:xhigh" else {
                throw ResolverError.unsupportedModel
            }
            return ClaudeCodeLaunchEnvironment(
                effectiveModel: "sonnet",
                environmentOverrides: [:],
                backend: .compatible(.glmZAI)
            )
        }
    }

    func testRustAdapterPassesEncodedGLMModelToHostResolver() async throws {
        let resolver = RecordingLaunchEnvironmentResolver()
        let config = ClaudeCodeAgentConfig.agentMode(
            commandName: "/usr/bin/false",
            runtimeVariant: .glm,
            permissionMode: "default",
            allowNativeBashTool: false,
            disallowedBuiltInTools: [],
            mcpStrictMode: false,
            toolSearchEnabled: false
        )
        let controller = ClaudeRustBackedNativeSessionAdapter(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: config,
            runtimeConfig: ClaudeCompatiblePluginBridge.runtimeConfig(from: config, mode: .agentMode),
            environmentResolver: resolver
        )

        do {
            _ = try await controller.startOrResume(
                existingSessionID: nil,
                model: "glm-5-turbo:xhigh",
                effortLevel: nil,
                systemPromptOverride: nil
            )
            XCTFail("Expected encoded unsupported GLM XHigh model to be rejected by the resolver")
        } catch ResolverError.unsupportedModel {
            // Expected before any process or core scope is created.
        }

        let requestedModels = await resolver.requestedModels
        XCTAssertEqual(requestedModels, ["glm-5-turbo:xhigh"])
    }

    func testRepoPromptPermissionAutoApprovalClassifierPreservesMatchProvenance() throws {
        let repoPromptPayload: [String: Any] = [
            "tool_name": "mcp__RepoPromptCE__read_file",
            "tool_use_id": "toolu_read_1",
            "input": ["path": "Sources/App.swift"]
        ]

        let match = try XCTUnwrap(ClaudeNativeRuntimeHostPolicy.repoPromptPermissionAutoApprovalMatch(
            toolName: "mcp__RepoPromptCE__read_file",
            requestPayload: repoPromptPayload
        ))
        XCTAssertEqual(match.source, .topLevelToolName)
        XCTAssertEqual(match.normalizedToolName, "read_file")

        let nestedMatch = try XCTUnwrap(ClaudeNativeRuntimeHostPolicy.repoPromptPermissionAutoApprovalMatch(
            toolName: "Bash",
            requestPayload: [
                "permission_suggestions": [["rules": [["toolName": "mcp__RepoPromptCE__read_file"]]]]
            ]
        ))
        XCTAssertEqual(nestedMatch.source, .nestedToolName)
        XCTAssertEqual(nestedMatch.normalizedToolName, "read_file")

        XCTAssertNil(ClaudeNativeRuntimeHostPolicy.repoPromptPermissionAutoApprovalMatch(
            toolName: "Bash",
            requestPayload: ["input": ["command": "rm -rf /tmp/example"]]
        ))
    }
}
