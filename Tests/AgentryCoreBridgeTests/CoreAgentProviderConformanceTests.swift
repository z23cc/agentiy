@testable import AgentryCoreBridge
import Foundation
import XCTest

final class CoreAgentProviderConformanceTests: XCTestCase {
    func testOfflineConformanceMatrixMatchesRustProfiles() async throws {
        let bridge = try await AgentryCoreBridge.start()
        addTeardownBlock {
            _ = try? await bridge.close()
        }
        for protocolKind in [CoreAgentProviderProtocol.codexAppServer, .acp, .claudeHeadless] {
            let command = protocolKind == .claudeHeadless ? "cat >/dev/null" : "sleep 1"
            let session = try await CoreAgentProviderSession.open(
                bridge: bridge,
                command: "/bin/sh",
                arguments: ["-c", command],
                environment: [:],
                workingDirectory: nil,
                protocolKind: protocolKind
            )
            addTeardownBlock {
                await session.shutdown()
            }
            let snapshot = try await session.conformanceSnapshot()
            let validation = try await session.validateConformance()
            XCTAssertTrue(validation.valid, "\(protocolKind) must satisfy the Rust profile")
            XCTAssertTrue(validation.violations.isEmpty)
            XCTAssertEqual(snapshot.protocolKind, protocolKind)
            XCTAssertEqual(snapshot.schemaVersion, 1)
            XCTAssertTrue(snapshot.ownsProcessLifetime)
            XCTAssertTrue(snapshot.ownsLineFraming)
            XCTAssertTrue(snapshot.serializesStdinWrites)
            XCTAssertTrue(snapshot.emitsOrderedEvents)
            XCTAssertTrue(snapshot.boundsStderr)
            XCTAssertTrue(snapshot.emitsProcessExitTerminalEvent)

            switch protocolKind {
            case .codexAppServer:
                XCTAssertTrue(snapshot.supportsSemanticRequests)
                XCTAssertTrue(snapshot.supportsTypedNotifications)
                XCTAssertTrue(snapshot.supportsTypedServerRequests)
                XCTAssertTrue(snapshot.supportsTypedState)
                XCTAssertTrue(snapshot.supportsTokenCancellation)
                XCTAssertFalse(snapshot.supportsTypedControlReceipts)
                XCTAssertTrue(snapshot.preservesJSONRPCIDType)
                XCTAssertFalse(snapshot.supportsGenericSendLine)
                XCTAssertFalse(snapshot.supportsStartWithStdin)
                XCTAssertFalse(snapshot.translatesStreamResults)
            case .acp:
                XCTAssertTrue(snapshot.supportsSemanticRequests)
                XCTAssertTrue(snapshot.supportsTypedNotifications)
                XCTAssertTrue(snapshot.supportsTypedServerRequests)
                XCTAssertTrue(snapshot.supportsTypedState)
                XCTAssertTrue(snapshot.supportsTokenCancellation)
                XCTAssertTrue(snapshot.supportsTypedControlReceipts)
                XCTAssertTrue(snapshot.preservesJSONRPCIDType)
                XCTAssertFalse(snapshot.supportsGenericSendLine)
                XCTAssertFalse(snapshot.supportsStartWithStdin)
                XCTAssertFalse(snapshot.translatesStreamResults)
            case .claudeHeadless:
                XCTAssertFalse(snapshot.supportsSemanticRequests)
                XCTAssertFalse(snapshot.supportsTypedNotifications)
                XCTAssertFalse(snapshot.supportsTypedServerRequests)
                XCTAssertFalse(snapshot.supportsTypedState)
                XCTAssertFalse(snapshot.supportsTokenCancellation)
                XCTAssertFalse(snapshot.supportsTypedControlReceipts)
                XCTAssertFalse(snapshot.preservesJSONRPCIDType)
                XCTAssertTrue(snapshot.supportsGenericSendLine)
                XCTAssertTrue(snapshot.supportsStartWithStdin)
                XCTAssertTrue(snapshot.translatesStreamResults)
            }
        }
    }

    func testConformanceQueriesDoNotStartOrAdvanceProviderEvents() async throws {
        let bridge = try await AgentryCoreBridge.start()
        addTeardownBlock {
            _ = try? await bridge.close()
        }
        let session = try await CoreAgentProviderSession.open(
            bridge: bridge,
            command: "/bin/sh",
            arguments: ["-c", "sleep 1"],
            environment: [:],
            workingDirectory: nil,
            protocolKind: .codexAppServer
        )
        addTeardownBlock {
            await session.shutdown()
        }
        let stream = try await session.events()
        addTeardownBlock {
            try? await stream.close()
        }
        let before = try await session.conformanceSnapshot()
        let validation = try await session.validateConformance()
        XCTAssertTrue(validation.valid)

        _ = try await session.start()
        let after = try await session.conformanceSnapshot()
        XCTAssertEqual(after, before)

        var iterator = stream.makeAsyncIterator()
        var events: [CoreAgentProviderEvent] = []
        for _ in 0 ..< 3 {
            guard let event = try await iterator.next() else { break }
            events.append(event)
            if event.kind == "processStarted" { break }
        }
        XCTAssertEqual(events.first?.kind, "processStarted")
        XCTAssertEqual(events.first?.sequence, 1)
        XCTAssertTrue(zip(events, events.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
    }
}
