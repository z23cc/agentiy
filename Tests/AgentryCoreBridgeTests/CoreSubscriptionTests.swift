import XCTest
@testable import AgentryCoreBridge

final class CoreSubscriptionTests: XCTestCase {
    func testBootstrapWakeDrainHasMoreOverflowGapAndRearm() async throws {
        let transport = FakeCoreTransport()
        let bridge = AgentryCoreBridge(transport: transport)
        _ = try await bridge.initialize()
        let subscription = try await bridge.openSubscription(scopeID: CoreScopeID())
        XCTAssertEqual(subscription.streamID, 11)
        XCTAssertEqual(subscription.nextDeliveryCursor, 1)
        XCTAssertEqual(subscription.initialSnapshot, .utf8("snapshot"))

        transport.enqueue([
            CoreTransportDrainBatch(
                events: [CoreTransportEvent(
                    kind: .data,
                    authoritySequence: 1,
                    deliveryCursor: 1,
                    payload: Data("one".utf8),
                    payloadOmitted: false
                )],
                hasMore: true,
                nextDeliveryCursor: 2,
                droppedCount: 3,
                oversize: nil
            ),
            CoreTransportDrainBatch(
                events: [CoreTransportEvent(
                    kind: .terminal,
                    authoritySequence: 2,
                    deliveryCursor: 2,
                    payload: Data("done".utf8),
                    payloadOmitted: false
                )],
                hasMore: false,
                nextDeliveryCursor: 3,
                droppedCount: 0,
                oversize: CoreTransportOversize(
                    actualBytes: 2_000_000,
                    maximumBytes: 1_048_576,
                    resnapshotRequired: true
                )
            ),
        ])

        var iterator = subscription.events.makeAsyncIterator()
        transport.wake()
        let first = try await iterator.next()
        let second = try await iterator.next()
        let third = try await iterator.next()
        let fourth = try await iterator.next()
        let events = [first, second, third, fourth]

        XCTAssertEqual(events.compactMap { $0 }.map(\.kind), [.data, .gap, .terminal, .payloadRejected])
        XCTAssertEqual(events[1]?.payload, .gap(droppedCount: 3))
        XCTAssertEqual(
            events[3]?.payload,
            .rejected(actualBytes: 2_000_000, maximumBytes: 1_048_576, resnapshotRequired: true)
        )
        XCTAssertTrue(transport.actions.contains("rearm"))
        try await bridge.closeSubscription(subscription)
        _ = try await bridge.close()
    }

    func testOldRuntimeIdentityIsRejectedForHostResponse() async throws {
        let transport = FakeCoreTransport()
        let bridge = AgentryCoreBridge(transport: transport)
        _ = try await bridge.initialize()
        let stale = CoreRuntimeIdentity(
            abiEpoch: 1,
            instanceNonce: "ffffffffffffffffffffffffffffffff",
            buildFingerprint: CoreRuntimeIdentity.fixture.buildFingerprint,
            bindingChecksum: CoreRuntimeIdentity.fixture.bindingChecksum
        )
        do {
            try await bridge.respondHostRequest(CoreHostResponse(
                requestID: "request",
                runtimeIdentity: stale,
                payload: Data()
            ))
            XCTFail("stale response must be rejected")
        } catch {
            XCTAssertEqual(error as? CoreBridgeError, .staleRuntimeIdentity)
        }
        _ = try await bridge.close()
    }
}
