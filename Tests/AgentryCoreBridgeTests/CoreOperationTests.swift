import XCTest
@testable import AgentryCoreBridge

final class CoreOperationTests: XCTestCase {
    func testExecuteUsesTypedIDAndCancelledTaskCreatesTombstoneBeforeAdmission() async throws {
        let transport = FakeCoreTransport()
        let bridge = AgentryCoreBridge(transport: transport)
        _ = try await bridge.initialize()
        let command = try fixtureCommand()

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await bridge.execute(command)
        }
        do {
            _ = try await cancelled.value
            XCTFail("cancelled task must not be admitted")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(transport.actions.contains(where: { $0.hasPrefix("cancel:") }))
        XCTAssertFalse(transport.actions.contains(where: { $0.hasPrefix("execute:") }))

        let admitted = try await bridge.execute(command)
        XCTAssertEqual(admitted.disposition, .accepted)
        XCTAssertEqual(admitted.state, .admitted)
        XCTAssertNotNil(UUID(uuidString: admitted.operationID.rawValue))
        _ = try await bridge.close()
    }

    func testPanicPoisonInvalidatesFacadeAndRejectsLaterCalls() async throws {
        let transport = FakeCoreTransport()
        transport.failExecute(with: .internalPanic)
        let bridge = AgentryCoreBridge(transport: transport)
        _ = try await bridge.initialize()

        do {
            _ = try await bridge.execute(try fixtureCommand())
            XCTFail("panic must invalidate bridge")
        } catch {
            XCTAssertEqual(error as? CoreBridgeError, .runtimeInvalidated)
        }
        do {
            _ = try await bridge.execute(try fixtureCommand())
            XCTFail("invalidated bridge must reject later work")
        } catch {
            XCTAssertEqual(error as? CoreBridgeError, .runtimeInvalidated)
        }
    }
}
