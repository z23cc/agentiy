import XCTest
@testable import AgentryCoreBridge

private actor BlockingFirstCoreEventDecoder: CoreEventDecoding {
    private var firstDecodeStarted = false
    private var firstDecodeReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func decode(_ payload: Data) async throws -> CoreDecodedPayload {
        let text = String(decoding: payload, as: UTF8.self)
        if text == "one" {
            firstDecodeStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            if !firstDecodeReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        return .utf8(text)
    }

    func waitUntilFirstDecodeStarts() async {
        if firstDecodeStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstDecode() {
        firstDecodeReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

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

    func testOverlappingWakeCallbacksCannotReorderEventsAcrossAnAsyncDecode() async throws {
        let transport = FakeCoreTransport()
        let decoder = BlockingFirstCoreEventDecoder()
        let bridge = AgentryCoreBridge(transport: transport, decoder: decoder)
        _ = try await bridge.initialize()
        let subscription = try await bridge.openSubscription(scopeID: CoreScopeID())
        var iterator = subscription.events.makeAsyncIterator()

        transport.enqueue([CoreTransportDrainBatch(
            events: [CoreTransportEvent(
                kind: .data,
                authoritySequence: 1,
                deliveryCursor: 1,
                payload: Data("one".utf8),
                payloadOmitted: false
            )],
            hasMore: false,
            nextDeliveryCursor: 2,
            droppedCount: 0,
            oversize: nil
        )])
        transport.wake()
        await decoder.waitUntilFirstDecodeStarts()

        // The first drainer is now suspended inside `decoder.decode`. A second wake used to enter
        // the actor reentrantly, drain this newer batch, and yield "two" before "one". Repeating the
        // wake removes scheduler timing from the regression while the first decode remains gated.
        transport.enqueue([CoreTransportDrainBatch(
            events: [CoreTransportEvent(
                kind: .terminal,
                authoritySequence: 2,
                deliveryCursor: 2,
                payload: Data("two".utf8),
                payloadOmitted: false
            )],
            hasMore: false,
            nextDeliveryCursor: 3,
            droppedCount: 0,
            oversize: nil
        )])
        for _ in 0 ..< 8 {
            transport.wake()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            transport.actions.count(where: { $0 == "drain" }),
            1,
            "overlapping wake callbacks must coalesce while the single drainer owns the subscription"
        )

        await decoder.releaseFirstDecode()
        let first = try await iterator.next()
        let second = try await iterator.next()
        XCTAssertEqual([first?.payload, second?.payload], [.utf8("one"), .utf8("two")])
        XCTAssertEqual([first?.authoritySequence, second?.authoritySequence], [1, 2])

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
