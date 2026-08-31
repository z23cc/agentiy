@testable import AgentryCoreBridge
import Foundation
import XCTest

final class CoreAgentProviderSessionTests: XCTestCase {
    func testRustProviderSessionPublishesOrderedCodexTransportEvents() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let session = try await CoreAgentProviderSession.open(
            bridge: bridge,
            command: "/bin/sh",
            arguments: [
                "-c",
                "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"ready\"}' '{\"jsonrpc\":\"2.0\",\"id\":\"server-1\",\"method\":\"approval/request\",\"params\":{\"reason\":\"confirm\"}}'"
            ],
            environment: [:],
            workingDirectory: nil,
            protocolKind: .codexAppServer
        )
        let stream = try await session.events()
        let receipt = try await session.start()
        XCTAssertGreaterThan(receipt.pid, 0)

        var iterator = stream.makeAsyncIterator()
        var events: [CoreAgentProviderEvent] = []
        for _ in 0 ..< 8 {
            guard let event = try await iterator.next() else { break }
            events.append(event)
            if event.kind == "processExited" { break }
        }

        XCTAssertTrue(events.contains(where: { $0.kind == "processStarted" }))
        XCTAssertTrue(events.contains(where: { event in
            guard event.kind == "notification",
                  let payload = event.payloadDictionary,
                  let method = payload["method"] as? String
            else { return false }
            return method == "ready"
        }))
        XCTAssertTrue(events.contains(where: { event in
            guard event.kind == "serverRequest",
                  let payload = event.payloadDictionary,
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String
            else { return false }
            return id == "server-1" && method == "approval/request"
        }))
        XCTAssertTrue(events.contains(where: { $0.kind == "processExited" }))
        XCTAssertTrue(events.map(\.sequence).isStrictlyIncreasing)

        await session.shutdown()
        _ = try await bridge.close()
    }

    func testRustCodexRequestAndStateAreRustOwned() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let session = try await CoreAgentProviderSession.open(
            bridge: bridge,
            command: "/bin/sh",
            arguments: [
                "-c",
                "IFS= read -r line; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}'"
            ],
            environment: [:],
            workingDirectory: nil,
            protocolKind: .codexAppServer
        )
        _ = try await session.start()
        let result = try await session.codexRequest(
            method: "initialize",
            params: nil,
            timeoutMilliseconds: 2_000
        )
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(response["ok"] as? Bool, true)
        let state = try await session.codexState()
        XCTAssertTrue(state.initialized)
        XCTAssertEqual(state.lifecycle, "initialized")
        XCTAssertEqual(state.pendingRequestCount, 0)
        await session.shutdown()
        _ = try await bridge.close()
    }

    func testRustCodexRequestCancellationSettlesTheMatchingPendingRequest() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let session = try await CoreAgentProviderSession.open(
            bridge: bridge,
            command: "/bin/sh",
            arguments: ["-c", "IFS= read -r line; sleep 1"],
            environment: [:],
            workingDirectory: nil,
            protocolKind: .codexAppServer
        )
        _ = try await session.start()
        let cancellationToken = "codex-cancel-test"
        let request = Task {
            try await session.codexRequest(
                method: "initialize",
                params: nil,
                timeoutMilliseconds: nil,
                cancellationToken: cancellationToken
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        let didCancel = try await session.codexCancel(cancellationToken: cancellationToken)
        XCTAssertTrue(didCancel)
        do {
            _ = try await request.value
            XCTFail("cancelled Codex request must not remain pending")
        } catch let error as CoreBridgeError {
            XCTAssertEqual(error, .agentProviderCodexCancelled("initialize"))
        }
        let state = try await session.codexState()
        XCTAssertEqual(state.pendingRequestCount, 0)
        await session.shutdown()
        _ = try await bridge.close()
    }

    func testRustProviderSessionPreservesMalformedLineAndRejectsWritesAfterExit() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let session = try await CoreAgentProviderSession.open(
            bridge: bridge,
            command: "/bin/sh",
            arguments: ["-c", "printf 'not-json\\n'"],
            environment: [:],
            workingDirectory: nil,
            protocolKind: .acp
        )
        let stream = try await session.events()
        _ = try await session.start()

        var iterator = stream.makeAsyncIterator()
        var malformedPayload: String?
        var processExited = false
        for _ in 0 ..< 8 {
            guard let event = try await iterator.next() else { break }
            if event.kind == "providerMessage",
               let envelope = event.payloadDictionary,
               let payload = envelope["payload"] as? String
            {
                malformedPayload = payload
            }
            if event.kind == "processExited" {
                processExited = true
                break
            }
        }

        XCTAssertEqual(malformedPayload, "not-json")
        XCTAssertTrue(processExited)
        do {
            _ = try await session.sendLine(Data("{}".utf8))
            XCTFail("writes after process exit must be rejected")
        } catch let error as CoreBridgeError {
            XCTAssertEqual(error, .agentProviderNotRunning)
        }

        await session.shutdown()
        _ = try await bridge.close()
    }

    func testRustClaudeHeadlessSessionPublishesTranslatedResults() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let session = try await CoreAgentProviderSession.open(
            bridge: bridge,
            command: "/bin/sh",
            arguments: [
                "-c",
                "cat >/dev/null; printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}' '{\"type\":\"result\",\"result\":\"hello\",\"session_id\":\"session-1\"}'"
            ],
            environment: [:],
            workingDirectory: nil,
            protocolKind: .claudeHeadless
        )
        let stream = try await session.events()
        _ = try await session.startWithStdin(Data("prompt".utf8))

        var iterator = stream.makeAsyncIterator()
        var results: [[String: Any]] = []
        var processExited = false
        for _ in 0 ..< 12 {
            guard let event = try await iterator.next() else { break }
            if event.kind == "streamResult",
               let envelope = event.payloadDictionary,
               let result = envelope["result"] as? [String: Any]
            {
                results.append(result)
            }
            if event.kind == "processExited" {
                processExited = true
                break
            }
        }

        XCTAssertTrue(results.contains { $0["type"] as? String == "content" && $0["text"] as? String == "hello" })
        XCTAssertTrue(results.contains { $0["type"] as? String == "message_stop" && $0["provider_session_id"] as? String == "session-1" })
        XCTAssertTrue(processExited)
        await session.shutdown()
        _ = try await bridge.close()
    }
}

private extension Collection where Element: Comparable {
    var isStrictlyIncreasing: Bool {
        zip(self, dropFirst()).allSatisfy(<)
    }
}
