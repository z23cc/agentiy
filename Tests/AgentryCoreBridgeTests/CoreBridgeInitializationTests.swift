import Darwin
import XCTest
@testable import AgentryCoreBridge

final class CoreBridgeInitializationTests: XCTestCase {
    func testInjectedFingerprintMismatchFailsClosed() async throws {
        let transport = FakeCoreTransport()
        transport.overrideHandshake(CoreTransportHandshake(
            runtimeIdentity: .fixture,
            abiEpoch: CoreRuntimeIdentity.fixture.abiEpoch,
            payloadSchemaVersions: [1],
            buildFingerprint: String(repeating: "f", count: 64),
            bindingChecksum: CoreRuntimeIdentity.fixture.bindingChecksum
        ))
        let bridge = AgentryCoreBridge(transport: transport)

        do {
            _ = try await bridge.initialize()
            XCTFail("expected binding mismatch")
        } catch {
            XCTAssertEqual(error as? CoreBridgeError, .incompatibleBindings)
        }
        do {
            _ = try await bridge.runtimeIdentity()
            XCTFail("mismatched bridge must remain invalid")
        } catch {
            XCTAssertEqual(error as? CoreBridgeError, .runtimeInvalidated)
        }
    }

    func testWakeDescriptorIsMarkedCloseOnExec() async throws {
        let transport = FakeCoreTransport()
        let bridge = AgentryCoreBridge(transport: transport)

        _ = try await bridge.initialize()

        XCTAssertNotEqual(transport.duplicatedWakeFDFlags & FD_CLOEXEC, 0)
        _ = try await bridge.close()
    }

    func testRealRustRuntimeInitializesInProcess() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let identity = try await bridge.runtimeIdentity()
        XCTAssertEqual(identity.abiEpoch, 1)
        XCTAssertEqual(identity.buildFingerprint, CoreRuntimeIdentity.fixture.buildFingerprint)
        _ = try await bridge.close()
    }
}
