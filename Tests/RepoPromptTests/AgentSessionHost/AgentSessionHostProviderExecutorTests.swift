import AgentryCoreBridge
import Foundation
import RepoPromptDomainRuntime
import XCTest

/// P3 leftover: one scripted Codex turn and one scripted ACP turn through
/// `ProviderAgentSessionExecutor`. No live network; stub factory remains the
/// `FILTER=AgentSessionHost` harness default.
final class AgentSessionHostProviderExecutorTests: XCTestCase {
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
            modelId: "test-model",
            reasoningEffort: "",
            parentSessionId: "",
            parentForkCursor: 0,
            initialMessage: Self.message(message),
            permissionPolicy: policy,
            credentialEnvelopeId: "",
            resumeProviderSessionId: ""
        )
    }

    private static func codexSpec(message: String, policy: AgentHostPermissionPolicyV1? = nil) -> AgentHostSessionSpecV1 {
        spec(providerID: "codexExec", message: message, policy: policy)
    }

    private static func acpSpec(message: String) -> AgentHostSessionSpecV1 {
        spec(providerID: "openCode", message: message, policy: nil)
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
}
