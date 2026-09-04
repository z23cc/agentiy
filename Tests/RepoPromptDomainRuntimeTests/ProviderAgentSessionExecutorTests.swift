@testable import AgentryCoreBridge
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// P3 leftover: one scripted Codex turn and one scripted ACP turn through
/// `ProviderAgentSessionExecutor`. No live network.
final class ProviderAgentSessionExecutorTests: XCTestCase {
    func testCodexTurnClassifiesStreamAndCompletes() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-1"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-1"}}"#.utf8)
        }
        let sink = CollectingSink()
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: Self.codexSpec(message: "hello host"),
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        let receipt = try executor.start(spec: Self.codexSpec(message: "hello host"))
        XCTAssertFalse(receipt.runID.isEmpty)

        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }
        transport.emit(.notification(
            method: "item/agentMessage/delta",
            paramsJSON: #"{"delta":"hello-host"}"#
        ))
        transport.emit(.notification(
            method: "turn/completed",
            paramsJSON: #"{"turn":{"id":"turn-1","status":"completed"}}"#
        ))

        waitUntil(sink) { sink in
            sink.streamTexts.contains("hello-host") && sink.completedOutcomes.contains(.completed)
        }
        XCTAssertTrue(transport.recordedRequests.contains(where: { $0.method == "initialize" }))
        XCTAssertTrue(transport.recordedRequests.contains(where: { $0.method == "thread/start" }))
        XCTAssertTrue(transport.recordedRequests.contains(where: { $0.method == "turn/start" }))
        executor.terminate()
    }

    func testACPTurnNormalizesSessionUpdateAndCompletes() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "session/new") { _ in
            Data(#"{"sessionId":"s-1"}"#.utf8)
        }
        transport.setHandler(for: "session/prompt") { [weak transport] _ in
            transport?.emit(.notification(
                method: "session/update",
                paramsJSON: #"{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"acp-hello"}}}"#
            ))
            return Data(#"{"stopReason":"end_turn"}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.acpSpec(message: "hello acp")
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        let receipt = try executor.start(spec: spec)
        XCTAssertFalse(receipt.runID.isEmpty)
        waitUntil(sink) { sink in
            sink.streamTexts.contains("acp-hello") && sink.completedOutcomes.contains(.completed)
        }
        XCTAssertTrue(transport.recordedRequests.contains(where: { $0.method == "initialize" }))
        XCTAssertTrue(transport.recordedRequests.contains(where: { $0.method == "session/new" }))
        XCTAssertTrue(transport.recordedRequests.contains(where: { $0.method == "session/prompt" }))
        executor.terminate()
    }

    func testDeclineUnattendedAsksAndWaitsWhenNoClientAnswers() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-wait"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-wait"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "needs approval",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .declineUnattended,
                toolPreferences: [],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }
        transport.emit(.serverRequest(
            idJSON: Data("\"req-1\"".utf8),
            idDisplay: "req-1",
            method: "item/commandExecution/requestApproval",
            paramsJSON: #"{"threadId":"thread-wait","reason":"run ls","command":"ls"}"#
        ))
        waitUntil(sink) { !$0.interactionIDs.isEmpty }
        XCTAssertTrue(transport.recordedResponds.isEmpty, "DECLINE_UNATTENDED with zero clients must wait, not deny")
        XCTAssertTrue(sink.completedOutcomes.isEmpty)

        let interactionID = try XCTUnwrap(sink.interactionIDs.first)
        try executor.deliverInteractionAnswer(
            interactionID: interactionID,
            answer: AgentHostInteractionAnswerV1(
                skipped: false,
                answer: .approval(AgentHostApprovalDecisionV1(kind: .accept, execpolicyAmendmentJson: ""))
            )
        )
        waitUntil(transport) { !$0.recordedResponds.isEmpty }
        let result = try XCTUnwrap(String(data: transport.recordedResponds[0].resultJSON, encoding: .utf8))
        XCTAssertTrue(result.contains("accept"))
        executor.terminate()
    }

    private static func message(_ text: String) -> AgentHostUserMessageV1 {
        AgentHostUserMessageV1(
            messageId: UUID().uuidString.lowercased(),
            text: text,
            attachments: [],
            createdAt: AgentSessionHostClock.rfc3339()
        )
    }

    private static func spec(
        providerID: String,
        message: String,
        modelID: String = "test-model",
        reasoningEffort: String = "",
        policy: AgentHostPermissionPolicyV1?
    ) -> AgentHostSessionSpecV1 {
        AgentHostSessionSpecV1(
            sessionId: UUID().uuidString.lowercased(),
            workspaceId: "ws-test",
            worktreeId: "/tmp",
            sessionName: "provider executor test",
            providerId: providerID,
            agentId: providerID,
            agentDisplayName: providerID,
            modelId: modelID,
            reasoningEffort: reasoningEffort,
            parentSessionId: "",
            parentForkCursor: 0,
            initialMessage: Self.message(message),
            permissionPolicy: policy,
            credentialEnvelopeId: "",
            resumeProviderSessionId: ""
        )
    }

    private static func codexSpec(
        message: String,
        modelID: String = "test-model",
        reasoningEffort: String = "",
        policy: AgentHostPermissionPolicyV1? = nil
    ) -> AgentHostSessionSpecV1 {
        spec(providerID: "codexExec", message: message, modelID: modelID, reasoningEffort: reasoningEffort, policy: policy)
    }

    private static func acpSpec(message: String, policy: AgentHostPermissionPolicyV1? = nil) -> AgentHostSessionSpecV1 {
        spec(providerID: "openCode", message: message, policy: policy)
    }

    func testCodexRunningUpdateEmitsCommandExecutionDeltaStream() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-1"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-1"}}"#.utf8)
        }
        let sink = CollectingSink()
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: Self.codexSpec(message: "hello codex"),
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        let receipt = try executor.start(spec: Self.codexSpec(message: "hello codex"))
        XCTAssertFalse(receipt.runID.isEmpty)

        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }
        transport.emit(.notification(
            method: "item/commandExecution/outputDelta",
            paramsJSON: #"{"itemId":"0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081","delta":"building project...\n"}"#
        ))
        transport.emit(.notification(
            method: "turn/completed",
            paramsJSON: #"{"turn":{"id":"turn-1","status":"completed"}}"#
        ))

        waitUntil(sink) { sink in
            sink.streamResults.contains(where: { $0.itemType == "commandExecution" && $0.text == "building project...\n" })
                && sink.completedOutcomes.contains(.completed)
        }
        executor.terminate()
    }

    func testACPStrictAutoApprovalSelectsOptionWhenServerMatches() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "session/new") { _ in
            Data(#"{"sessionId":"s-1"}"#.utf8)
        }
        transport.setHandler(for: "session/prompt") { [weak transport] _ in
            transport?.emit(.serverRequest(
                idJSON: Data("\"req-acp-1\"".utf8),
                idDisplay: "req-acp-1",
                method: "session/request_permission",
                paramsJSON: """
                {
                    "toolCall": {
                        "toolCallId": "tc-1",
                        "title": "mcp__RepoPromptCE__read_file",
                        "server": "RepoPromptCE",
                        "kind": "read"
                    },
                    "options": [
                        {"optionId": "allow_once", "kind": "allow_once"},
                        {"optionId": "reject_once", "kind": "reject_once"}
                    ]
                }
                """
            ))
            for _ in 0..<100 {
                if let responds = transport?.recordedResponds, !responds.isEmpty { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return Data(#"{"stopReason":"end_turn"}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.acpSpec(
            message: "hello acp",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .never,
                toolPreferences: [],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { !$0.recordedResponds.isEmpty }
        let result = try XCTUnwrap(String(data: transport.recordedResponds[0].resultJSON, encoding: .utf8))
        XCTAssertTrue(result.contains("allow_once"))
        XCTAssertTrue(result.contains("selected"))
        XCTAssertTrue(sink.interactionIDs.isEmpty, "Strict RepoPrompt tool match must be auto-approved without asking")
        executor.terminate()
    }

    func testACPStrictAutoApprovalFallsBackToAskWhenServerDoesNotMatch() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "session/new") { _ in
            Data(#"{"sessionId":"s-2"}"#.utf8)
        }
        transport.setHandler(for: "session/prompt") { [weak transport] _ in
            transport?.emit(.serverRequest(
                idJSON: Data("\"req-acp-2\"".utf8),
                idDisplay: "req-acp-2",
                method: "session/request_permission",
                paramsJSON: """
                {
                    "toolCall": {
                        "toolCallId": "tc-2",
                        "title": "external_custom_tool",
                        "kind": "custom"
                    },
                    "options": [
                        {"optionId": "allow_once", "kind": "allow_once"},
                        {"optionId": "reject_once", "kind": "reject_once"}
                    ]
                }
                """
            ))
            for _ in 0..<150 {
                if let responds = transport?.recordedResponds, !responds.isEmpty { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return Data(#"{"stopReason":"end_turn"}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.acpSpec(
            message: "hello acp external tool",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .never,
                toolPreferences: [],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(sink) { !$0.interactionIDs.isEmpty }
        XCTAssertTrue(transport.recordedResponds.isEmpty, "Non-RepoPrompt tool must fall back to ask interaction even under never/allowAll")

        let interactionID = try XCTUnwrap(sink.interactionIDs.first)
        try executor.deliverInteractionAnswer(
            interactionID: interactionID,
            answer: AgentHostInteractionAnswerV1(
                skipped: false,
                answer: .approval(AgentHostApprovalDecisionV1(kind: .accept, execpolicyAmendmentJson: ""))
            )
        )

        waitUntil(transport) { !$0.recordedResponds.isEmpty }
        let result = try XCTUnwrap(String(data: transport.recordedResponds[0].resultJSON, encoding: .utf8))
        XCTAssertTrue(result.contains("selected"))
        executor.terminate()
    }


    func testClaudeToolPermissionInterceptionAndDelivery() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-claude-test"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-claude-test"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "claude interception test",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .declineUnattended,
                toolPreferences: [],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }

        let claudeEvent = CoreAgentSessionEvent(
            kind: "approvalRequest",
            turnID: 1,
            fields: [
                "requestId": "claude-req-1",
                "toolName": "shell_command",
                "inputJson": #"{"cmd":"ls"}"#
            ]
        )
        executor.handleClaudeEvent(claudeEvent)

        waitUntil(sink) { !$0.interactionIDs.isEmpty }
        XCTAssertNil(executor.lastClaudePermissionDecision, "Should wait for interaction, not immediately respond")

        let interactionID = try XCTUnwrap(sink.interactionIDs.first)
        try executor.deliverInteractionAnswer(
            interactionID: interactionID,
            answer: AgentHostInteractionAnswerV1(
                skipped: false,
                answer: .approval(AgentHostApprovalDecisionV1(kind: .accept, execpolicyAmendmentJson: ""))
            )
        )

        waitUntil(executor) { $0.lastClaudePermissionDecision != nil }
        XCTAssertEqual(executor.lastClaudePermissionDecision?.requestID, "claude-req-1")
        XCTAssertEqual(executor.lastClaudePermissionDecision?.decision, .allow(includeUpdatedPermissions: false))
        executor.terminate()
    }

    func testClaudeToolPermissionAutoDenyWhenPolicyDenies() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-claude-deny"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-claude-deny"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "claude deny test",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .never,
                toolPreferences: [
                    AgentHostToolPreferenceV1(toolId: "forbidden_tool", disposition: .deny)
                ],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }

        let claudeEvent = CoreAgentSessionEvent(
            kind: "approvalRequest",
            turnID: 1,
            fields: [
                "requestId": "claude-req-deny-1",
                "toolName": "forbidden_tool",
                "inputJson": "{}"
            ]
        )
        executor.handleClaudeEvent(claudeEvent)

        waitUntil(executor) { $0.lastClaudePermissionDecision != nil }
        XCTAssertEqual(executor.lastClaudePermissionDecision?.requestID, "claude-req-deny-1")
        XCTAssertEqual(executor.lastClaudePermissionDecision?.decision, .deny(message: "Permission denied by policy", interrupt: false))
        XCTAssertTrue(sink.interactionIDs.isEmpty, "Deny disposition must respond directly without asking")
        executor.terminate()
    }

    func testClaudeCanUseToolInterceptionAndDeclineDelivery() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-claude-decline"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-claude-decline"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "claude can_use_tool decline test",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .declineUnattended,
                toolPreferences: [],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }

        // Test with kind: "can_use_tool" and snake_case fields
        let claudeEvent = CoreAgentSessionEvent(
            kind: "can_use_tool",
            turnID: 1,
            fields: [
                "request_id": "claude-req-decline-1",
                "tool_name": "custom_reader",
                "input": ["file": "sensitive.txt"]
            ]
        )
        executor.handleClaudeEvent(claudeEvent)

        waitUntil(sink) { !$0.interactionIDs.isEmpty }
        XCTAssertTrue(sink.stages.contains(.waitingForInteraction))
        XCTAssertNil(executor.lastClaudePermissionDecision)

        let interactionID = try XCTUnwrap(sink.interactionIDs.first)
        try executor.deliverInteractionAnswer(
            interactionID: interactionID,
            answer: AgentHostInteractionAnswerV1(
                skipped: false,
                answer: .approval(AgentHostApprovalDecisionV1(kind: .decline, execpolicyAmendmentJson: ""))
            )
        )

        waitUntil(executor) { $0.lastClaudePermissionDecision != nil }
        XCTAssertEqual(executor.lastClaudePermissionDecision?.requestID, "claude-req-decline-1")
        XCTAssertEqual(executor.lastClaudePermissionDecision?.decision, .deny(message: "Permission declined by user", interrupt: false))
        XCTAssertEqual(sink.stages.last, AgentHostLifecycleStageV1.running)
        executor.terminate()
    }

    func testClaudeToolPermissionSkippedAnswersWithInterrupt() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-claude-skip"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-claude-skip"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "claude skip test",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .declineUnattended,
                toolPreferences: [],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }

        let claudeEvent = CoreAgentSessionEvent(
            kind: "approvalRequest",
            turnID: 1,
            fields: [
                "requestId": "claude-req-skip-1",
                "toolName": "shell_command",
                "inputJson": #"{"cmd":"ls"}"#
            ]
        )
        executor.handleClaudeEvent(claudeEvent)

        waitUntil(sink) { !$0.interactionIDs.isEmpty }
        let interactionID = try XCTUnwrap(sink.interactionIDs.first)

        try executor.deliverInteractionAnswer(
            interactionID: interactionID,
            answer: AgentHostInteractionAnswerV1(
                skipped: true,
                answer: nil
            )
        )

        waitUntil(executor) { $0.lastClaudePermissionDecision != nil }
        XCTAssertEqual(executor.lastClaudePermissionDecision?.requestID, "claude-req-skip-1")
        XCTAssertEqual(executor.lastClaudePermissionDecision?.decision, .deny(message: "Permission cancelled by user", interrupt: true))
        executor.terminate()
    }

    func testClaudeToolPermissionAutoAllowWhenPolicyAllows() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-claude-allow"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-claude-allow"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "claude auto allow test",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .never,
                toolPreferences: [
                    AgentHostToolPreferenceV1(toolId: "trusted_tool", disposition: .allow)
                ],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }

        let claudeEvent = CoreAgentSessionEvent(
            kind: "can_use_tool",
            turnID: 1,
            fields: [
                "request_id": "claude-req-allow-1",
                "tool_name": "trusted_tool",
                "input": [:]
            ]
        )
        executor.handleClaudeEvent(claudeEvent)

        waitUntil(executor) { $0.lastClaudePermissionDecision != nil }
        XCTAssertEqual(executor.lastClaudePermissionDecision?.requestID, "claude-req-allow-1")
        XCTAssertEqual(executor.lastClaudePermissionDecision?.decision, .allow(includeUpdatedPermissions: false))
        XCTAssertTrue(sink.interactionIDs.isEmpty, "Auto-approved tool must not emit interaction request")
        XCTAssertFalse(sink.stages.contains(.waitingForInteraction))
        executor.terminate()
    }

    func testClaudeToolPermissionInterruptionAbortsPendingInteraction() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-claude-abort"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-claude-abort"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "claude abort test",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .declineUnattended,
                toolPreferences: [],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        let receipt = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }

        let claudeEvent = CoreAgentSessionEvent(
            kind: "approvalRequest",
            turnID: 1,
            fields: [
                "requestId": "claude-req-abort-1",
                "toolName": "shell_command",
                "inputJson": #"{"cmd":"ls"}"#
            ]
        )
        executor.handleClaudeEvent(claudeEvent)

        waitUntil(sink) { !$0.interactionIDs.isEmpty }
        XCTAssertTrue(sink.stages.contains(.waitingForInteraction))
        let interactionID = try XCTUnwrap(sink.interactionIDs.first)

        // Cancel the turn while parked in waitingForInteraction
        let outcome = executor.interrupt(turnID: receipt.turnID)
        XCTAssertEqual(outcome, AgentHostInterruptOutcomeV1.acknowledged)

        waitUntil(sink) { $0.completedOutcomes.contains(.cancelled) }

        // Attempting to deliver an answer after cancellation must fail cleanly
        XCTAssertThrowsError(
            try executor.deliverInteractionAnswer(
                interactionID: interactionID,
                answer: AgentHostInteractionAnswerV1(
                    skipped: false,
                    answer: .approval(AgentHostApprovalDecisionV1(kind: .accept, execpolicyAmendmentJson: ""))
                )
            )
        ) { error in
            guard case AgentSessionExecutorError.unknownInteraction = error else {
                XCTFail("Expected unknownInteraction error, got \(error)")
                return
            }
        }
        executor.terminate()
    }

    func testClaudeApprovalCancelledRestoresRunningStage() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-claude-cancel"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-claude-cancel"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "claude approvalCancelled test",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .declineUnattended,
                toolPreferences: [],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }

        let claudeEvent = CoreAgentSessionEvent(
            kind: "approvalRequest",
            turnID: 1,
            fields: [
                "requestId": "claude-req-cancel-event-1",
                "toolName": "shell_command",
                "inputJson": #"{"cmd":"ls"}"#
            ]
        )
        executor.handleClaudeEvent(claudeEvent)

        waitUntil(sink) { !$0.interactionIDs.isEmpty }
        XCTAssertTrue(sink.stages.contains(.waitingForInteraction))

        // Claude cancels approval
        let cancelEvent = CoreAgentSessionEvent(
            kind: "approvalCancelled",
            turnID: 1,
            fields: ["request_id": "claude-req-cancel-event-1"]
        )
        executor.handleClaudeEvent(cancelEvent)

        waitUntil(sink) { $0.stages.last == AgentHostLifecycleStageV1.running }

        // Interaction was cleared, deliverAnswer throws unknownInteraction
        XCTAssertThrowsError(
            try executor.deliverInteractionAnswer(
                interactionID: "claude-req-cancel-event-1",
                answer: AgentHostInteractionAnswerV1(
                    skipped: false,
                    answer: .approval(AgentHostApprovalDecisionV1(kind: .accept, execpolicyAmendmentJson: ""))
                )
            )
        )
        executor.terminate()
    }

    func testClaudeConcurrentDeliverAndInterruptRace() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-claude-race"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-claude-race"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "claude race test",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .declineUnattended,
                toolPreferences: [],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        let receipt = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "turn/start" }) }

        let claudeEvent = CoreAgentSessionEvent(
            kind: "approvalRequest",
            turnID: 1,
            fields: [
                "requestId": "claude-req-race-1",
                "toolName": "shell_command",
                "inputJson": #"{"cmd":"ls"}"#
            ]
        )
        executor.handleClaudeEvent(claudeEvent)

        waitUntil(sink) { !$0.interactionIDs.isEmpty }
        let interactionID = try XCTUnwrap(sink.interactionIDs.first)

        // Race deliverInteractionAnswer and interruptTurn across threads
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            _ = try? executor.deliverInteractionAnswer(
                interactionID: interactionID,
                answer: AgentHostInteractionAnswerV1(
                    skipped: false,
                    answer: .approval(AgentHostApprovalDecisionV1(kind: .accept, execpolicyAmendmentJson: ""))
                )
            )
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            _ = executor.interrupt(turnID: receipt.turnID)
            group.leave()
        }
        let waitResult = group.wait(timeout: .now() + 3.0)
        XCTAssertEqual(waitResult, .success, "Concurrent deliver and interrupt must not deadlock")
        executor.terminate()
    }

    func testACPToolPreferenceDenyOverridesAutoApproval() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "session/new") { _ in
            Data(#"{"sessionId":"s-acp-deny"}"#.utf8)
        }
        transport.setHandler(for: "session/prompt") { [weak transport] _ in
            transport?.emit(.serverRequest(
                idJSON: Data("\"req-deny-1\"".utf8),
                idDisplay: "req-deny-1",
                method: "session/request_permission",
                paramsJSON: """
                {
                    "toolCall": {
                        "toolCallId": "tc-deny-1",
                        "title": "mcp__RepoPromptCE__run_command",
                        "server": "RepoPromptCE",
                        "kind": "execute"
                    },
                    "options": [
                        {"optionId": "allow_once", "kind": "allow_once"},
                        {"optionId": "reject_once", "kind": "reject_once"}
                    ]
                }
                """
            ))
            for _ in 0..<100 {
                if let responds = transport?.recordedResponds, !responds.isEmpty { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return Data(#"{"stopReason":"end_turn"}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.acpSpec(
            message: "deny override test",
            policy: AgentHostPermissionPolicyV1(
                approvalPolicy: .never,
                toolPreferences: [
                    AgentHostToolPreferenceV1(toolId: "mcp__RepoPromptCE__run_command", disposition: .deny)
                ],
                providerSettings: [],
                interactionTimeoutSeconds: 0
            )
        )
        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { !$0.recordedResponds.isEmpty }
        let result = try XCTUnwrap(String(data: transport.recordedResponds[0].resultJSON, encoding: .utf8))
        XCTAssertTrue(result.contains("cancelled") || result.contains("reject_once"), "Must decline tool call: \(result)")
        XCTAssertTrue(sink.interactionIDs.isEmpty, "Deny disposition must reject immediately without asking user")
        executor.terminate()
    }

    func testCodexReasoningEffortEmptyRequestedEffortSelectsModelDefault() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "initialize") { _ in
            Data("""
            {
                "models": [
                    {
                        "id": "o3-mini",
                        "displayName": "o3-mini",
                        "isDefault": true,
                        "supportedReasoningEfforts": ["low", "medium", "high"],
                        "defaultReasoningEffort": "low"
                    }
                ]
            }
            """.utf8)
        }
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-effort-default"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-effort-1"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "test empty effort",
            modelID: "o3-mini",
            reasoningEffort: ""
        )

        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "thread/start" }) }
        let threadReq = try XCTUnwrap(transport.recordedRequests.first(where: { $0.method == "thread/start" }))
        let paramsText = try XCTUnwrap(threadReq.paramsJSON)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(paramsText.utf8)) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "o3-mini")
        XCTAssertEqual(obj["effort"] as? String, "low", "Empty requestedEffort must resolve to model defaultReasoningEffort 'low'")
        executor.terminate()
    }

    func testCodexReasoningEffortInvalidRequestedEffortFallsBackToModelDefault() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "initialize") { _ in
            Data("""
            {
                "models": [
                    {
                        "id": "o3-mini",
                        "displayName": "o3-mini",
                        "isDefault": true,
                        "supportedReasoningEfforts": ["low", "medium", "high"],
                        "defaultReasoningEffort": "high"
                    }
                ]
            }
            """.utf8)
        }
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-effort-invalid"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-effort-2"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "test invalid effort",
            modelID: "o3-mini",
            reasoningEffort: "super_invalid_effort_level_9000"
        )

        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "thread/start" }) }
        let threadReq = try XCTUnwrap(transport.recordedRequests.first(where: { $0.method == "thread/start" }))
        let paramsText = try XCTUnwrap(threadReq.paramsJSON)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(paramsText.utf8)) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "o3-mini")
        XCTAssertEqual(obj["effort"] as? String, "high", "Invalid effort must be sanitized and fall back to model default 'high'")
        executor.terminate()
    }

    func testCodexModelListFallbackWhenInitializeEmpty() throws {
        let transport = ProviderHostedScriptedTransport()
        transport.setHandler(for: "initialize") { _ in
            Data(#"{"models":[]}"#.utf8)
        }
        transport.setHandler(for: "model/list") { _ in
            Data("""
            {
                "data": [
                    {
                        "id": "gpt-5.4-fallback",
                        "displayName": "GPT 5.4 Fallback",
                        "isDefault": true,
                        "supportedReasoningEfforts": ["medium", "high"],
                        "defaultReasoningEffort": "medium"
                    }
                ]
            }
            """.utf8)
        }
        transport.setHandler(for: "thread/start") { _ in
            Data(#"{"thread":{"id":"thread-fallback"}}"#.utf8)
        }
        transport.setHandler(for: "turn/start") { _ in
            Data(#"{"turn":{"id":"turn-fallback"}}"#.utf8)
        }
        let sink = CollectingSink()
        let spec = Self.codexSpec(
            message: "test model/list fallback",
            modelID: "",
            reasoningEffort: ""
        )

        let executor = ProviderAgentSessionExecutor(
            sessionID: UUID().uuidString.lowercased(),
            spec: spec,
            sink: sink,
            applicationSupportRoot: FileManager.default.temporaryDirectory,
            hostedTransport: transport
        )

        _ = try executor.start(spec: spec)
        waitUntil(transport) { $0.recordedRequests.contains(where: { $0.method == "thread/start" }) }
        XCTAssertTrue(transport.recordedRequests.contains(where: { $0.method == "model/list" }), "Must query model/list when initialize has empty models")
        let threadReq = try XCTUnwrap(transport.recordedRequests.first(where: { $0.method == "thread/start" }))
        let paramsText = try XCTUnwrap(threadReq.paramsJSON)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(paramsText.utf8)) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "gpt-5.4-fallback")
        XCTAssertEqual(obj["effort"] as? String, "medium")
        executor.terminate()
    }

    private func waitUntil<T>(
        _ value: T,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: (T) -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(value) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for executor fixture", file: file, line: line)
    }
}

private final class CollectingSink: AgentSessionExecutorSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [AgentHostAgentSessionEventBodyV1] = []

    func emit(_ body: AgentHostAgentSessionEventBodyV1) {
        lock.withLock { bodies.append(body) }
    }

    var streamTexts: [String] {
        lock.withLock {
            bodies.compactMap { body in
                guard case let .runtimeEvent(event) = body, case let .stream(stream) = event.kind else { return nil }
                return stream.text
            }
        }
    }

    var streamResults: [AgentHostStreamResultV1] {
        lock.withLock {
            bodies.compactMap { body in
                guard case let .runtimeEvent(event) = body, case let .stream(stream) = event.kind else { return nil }
                return stream
            }
        }
    }

    var completedOutcomes: [AgentHostTerminalOutcomeKindV1] {
        lock.withLock {
            bodies.compactMap { body in
                guard case let .runLifecycle(event) = body, case let .terminated(terminated) = event.kind else {
                    return nil
                }
                return terminated.outcome?.kind
            }
        }
    }

    var interactionIDs: [String] {
        lock.withLock {
            bodies.compactMap { body in
                guard case let .interaction(event) = body, case let .requested(requested) = event.kind else {
                    return nil
                }
                return requested.interaction?.interactionId
            }
        }
    }

    var stages: [AgentHostLifecycleStageV1] {
        lock.withLock {
            bodies.compactMap { body in
                guard case let .runLifecycle(event) = body, case let .stageChanged(stage) = event.kind else {
                    return nil
                }
                return stage.stage
            }
        }
    }
}
