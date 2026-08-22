@testable import AgentryCoreBridge
import Foundation
import os
import XCTest

/// Covers the ed9a4bbc/§11.7 production diagnostics channel added on top of
/// the panic forensics ring buffer: `CorePanicForensicsBridge` must fire
/// exactly when an invalidation was panic-driven (`.internalPanic` /
/// `.runtimePoisoned`) and stay silent for every other invalidation reason,
/// even though both paths call the same `AgentryCoreBridge.invalidate()`.
final class CorePanicForensicsBridgeTests: XCTestCase {
    override func tearDown() {
        // The observer slot is process-global (by design -- see
        // `CorePanicForensicsBridge`'s doc comment); it must not leak a
        // closure captured by this test into later, unrelated tests.
        CorePanicForensicsBridge.setObserver(nil)
        super.tearDown()
    }

    func testObserverFiresWithForensicsOnPanicDrivenInvalidation() async throws {
        let captured = OSAllocatedUnfairLock<[CorePanicForensicsEvent]>(initialState: [])
        CorePanicForensicsBridge.setObserver { event in
            captured.withLock { $0.append(event) }
        }

        let transport = FakeCoreTransport()
        let forensics = ["thread=\"main\" at panic_forensics.rs:1:1: boom\nbacktrace..."]
        transport.returnPanicForensics(forensics)
        transport.failCompute(with: .runtimePoisoned)
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.computeClient()

        await XCTAssertThrowsCoreErrorAsync {
            try await client.extractCodeMapBatchV1(.init(subjects: [
                .init(languageID: 1, source: "struct S {}")
            ]))
        } verify: {
            XCTAssertEqual($0 as? CoreComputeError, .runtimePoisoned)
        }

        let events = captured.withLock { $0 }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.panicRecords, forensics)
        XCTAssertTrue(events.first?.trigger.contains("runtimePoisoned") ?? false)
    }

    func testObserverDoesNotFireOnUnrelatedInvalidation() async throws {
        let captured = OSAllocatedUnfairLock<[CorePanicForensicsEvent]>(initialState: [])
        CorePanicForensicsBridge.setObserver { event in
            captured.withLock { $0.append(event) }
        }

        let transport = FakeCoreTransport()
        // No panic forensics configured (defaults to `[]`): `.runtimeStopped`
        // still invalidates the bridge -- same `invalidate()` call as the
        // panic case -- but is not panic-driven, so the observer must not
        // fire. This is the discriminator under test, not just "does
        // invalidate() still work".
        transport.failCompute(with: .runtimeStopped)
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.computeClient()

        await XCTAssertThrowsCoreErrorAsync {
            try await client.extractCodeMapBatchV1(.init(subjects: [
                .init(languageID: 1, source: "struct S {}")
            ]))
        } verify: {
            XCTAssertEqual($0 as? CoreComputeError, .runtimeStopped)
        }

        XCTAssertTrue(captured.withLock { $0 }.isEmpty)
    }

    func testObserverDoesNotFireOnHandshakeMismatch() async throws {
        let captured = OSAllocatedUnfairLock<[CorePanicForensicsEvent]>(initialState: [])
        CorePanicForensicsBridge.setObserver { event in
            captured.withLock { $0.append(event) }
        }

        let transport = FakeCoreTransport()
        transport.overrideHandshake(CoreTransportHandshake(
            runtimeIdentity: .fixture,
            abiEpoch: CoreExpectedIdentity.generated.abiEpoch &+ 1,
            payloadSchemaVersions: [1],
            buildFingerprint: CoreExpectedIdentity.generated.buildFingerprint,
            bindingChecksum: CoreExpectedIdentity.generated.bindingChecksum
        ))
        let bridge = AgentryCoreBridge(transport: transport)
        await XCTAssertThrowsCoreErrorAsync {
            try await bridge.initialize()
        } verify: {
            XCTAssertEqual($0 as? CoreBridgeError, .incompatibleBindings)
        }

        XCTAssertTrue(captured.withLock { $0 }.isEmpty)
    }
}
