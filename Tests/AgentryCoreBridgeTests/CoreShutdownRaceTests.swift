import XCTest
@testable import AgentryCoreBridge

final class CoreShutdownRaceTests: XCTestCase {
    func testCloseClosesActiveSubscriptionsBeforeShutdown() async throws {
        let transport = FakeCoreTransport()
        let bridge = AgentryCoreBridge(transport: transport)
        _ = try await bridge.initialize()
        _ = try await bridge.openSubscription(scopeID: CoreScopeID())

        _ = try await bridge.close()

        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(transport.actions.suffix(2), ["close-subscription", "shutdown"])
    }

    func testConcurrentCloseIsIdempotent() async throws {
        let transport = FakeCoreTransport()
        let bridge = AgentryCoreBridge(transport: transport)
        _ = try await bridge.initialize()

        try await withThrowingTaskGroup(of: CoreShutdownReceipt.self) { group in
            for _ in 0 ..< 32 {
                group.addTask { try await bridge.close() }
            }
            for try await receipt in group {
                XCTAssertTrue(receipt.alreadyStarted || transport.shutdownCount == 1)
            }
        }
        XCTAssertEqual(transport.shutdownCount, 1)
    }
}
