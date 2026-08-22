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

    /// Smoke coverage for the real UniFFI binding: there is no FFI-exposed
    /// way to deliberately panic the real Rust runtime from Swift (the
    /// equivalent of `panic_for_test` is `#[cfg(test)]`-only inside the ffi
    /// crate itself -- a real-runtime panic test lives Rust-side, see
    /// `agentry_ffi::api::tests::panic_forensics_survives_poisoning_and_names_the_panic_site`).
    /// This just confirms `AgentryCoreBridge.corePanicForensics()` -- callable
    /// with no live bridge instance -- resolves and executes through the real
    /// generated binding without trapping.
    func testCorePanicForensicsIsCallableAgainstRealBindingWithNoLiveBridge() {
        let forensics = AgentryCoreBridge.corePanicForensics()
        // No real Rust panic has occurred in this process, so this is
        // typically empty; the assertion that matters is that the call
        // above resolved and returned through the real binding at all.
        XCTAssertTrue(forensics.allSatisfy { !$0.isEmpty })
    }
}
