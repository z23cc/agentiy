@testable import AgentryCoreBridge
import Foundation
import XCTest

final class CoreAgentProviderSessionTests: XCTestCase {
    func testRustProviderSessionPublishesOrderedCodexTransportEvents() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let session = try await CoreAgentProviderSession.open(
            bridge: bridge,
            command: "/bin/sh",
            arguments: ["-c", "printf '{\"jsonrpc\":\"2.0\",\"method\":\"ready\"}\\n'"],
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
            guard event.kind == "providerMessage",
                  let payload = event.payloadDictionary?["payload"] as? [String: Any]
            else { return false }
            return payload["method"] as? String == "ready"
        }))
        XCTAssertTrue(events.contains(where: { $0.kind == "processExited" }))
        XCTAssertTrue(events.map(\.sequence).isStrictlyIncreasing)

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
}

private extension Collection where Element: Comparable {
    var isStrictlyIncreasing: Bool {
        zip(self, dropFirst()).allSatisfy(<)
    }
}
