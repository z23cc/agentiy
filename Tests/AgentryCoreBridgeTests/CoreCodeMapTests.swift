@testable import AgentryCoreBridge
import Foundation
import XCTest

final class CoreCodeMapTests: XCTestCase {
    func testRealSwiftCodeMapRoundTrip() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let source = """
        struct Greeter {
            let prefix: String
            func greet(name: String) -> String { "\\(prefix), \\(name)" }
        }
        """

        let result = try await client.extractCodeMapBatchV1(.init(subjects: [
            .init(languageID: 1, source: source)
        ]))

        XCTAssertEqual(result.subjects.count, 1)
        XCTAssertEqual(result.subjects[0].languageID, 1)
        XCTAssertEqual(result.subjects[0].sourceByteCount, UInt64(source.utf8.count))
        guard case let .ready(artifact) = result.subjects[0].outcome else {
            return XCTFail("expected ready Swift codemap")
        }
        XCTAssertEqual(artifact.classes.map(\.name), ["Greeter"])
        XCTAssertFalse(artifact.classes[0].methods.isEmpty && artifact.functions.isEmpty)
        _ = try await bridge.close()
    }

    func testRealDecodeFailedOutcomeAndStaleIdentityReject() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let result = try await client.extractCodeMapBatchV1(.init(subjects: [
            .init(languageID: 1, sourceKind: .decodeFailedUndecodable, sourceUTF8: Data())
        ]))
        XCTAssertEqual(result.subjects.map(\.outcome), [.decodeFailedUndecodable])
        _ = try await bridge.close()

        let transport = try UniFFICoreRuntimeTransport(configuration: .init(), expected: .generated)
        let handshake = try transport.initialize()
        let cancellation = try transport.createLeafCancellation(identity: handshake.runtimeIdentity)
        let stale = CoreRuntimeIdentity(
            abiEpoch: handshake.runtimeIdentity.abiEpoch,
            instanceNonce: "ffffffffffffffffffffffffffffffff",
            buildFingerprint: handshake.runtimeIdentity.buildFingerprint,
            bindingChecksum: handshake.runtimeIdentity.bindingChecksum
        )
        XCTAssertThrowsError(try transport.codeMapExtractBatchCompactV1(
            identity: stale,
            cancellation: cancellation,
            request: .init(subjects: [.init(languageID: 1, source: "struct S {}")])
        )) {
            XCTAssertEqual($0 as? CoreTransportError, .staleRuntimeIdentity)
        }
        try transport.closeLeafCancellation(cancellation, identity: handshake.runtimeIdentity)
        _ = try transport.beginShutdown(identity: handshake.runtimeIdentity)
    }

    func testMalformedUTF8ScalarTableInvalidatesBridgeFailClosed() async throws {
        let transport = FakeCoreTransport()
        transport.returnCodeMapResult(malformedScalarFixture())
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.computeClient()

        await XCTAssertThrowsCoreErrorAsync {
            try await client.extractCodeMapBatchV1(.init(subjects: [
                .init(languageID: 1, source: "x")
            ]))
        } verify: {
            XCTAssertEqual($0 as? CoreComputeError, .malformedResponse)
        }
        await XCTAssertThrowsCoreErrorAsync {
            try await bridge.computeClient()
        } verify: {
            XCTAssertEqual($0 as? CoreBridgeError, .runtimeInvalidated)
        }
    }

    func testPoisonedComputeInvalidatesBridge() async throws {
        let transport = FakeCoreTransport()
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
        await XCTAssertThrowsCoreErrorAsync {
            try await bridge.computeClient()
        } verify: {
            XCTAssertEqual($0 as? CoreBridgeError, .runtimeInvalidated)
        }
    }

    private func malformedScalarFixture() -> CoreCompactCodeMapBatchResultV1 {
        let zero = CoreCompactTableRange(start: 0, count: 0)
        return .init(
            subjectSummaries: [.init(
                languageID: 1,
                sourceByteCount: 1,
                outcomeTag: .ready,
                outcomeActual: 0,
                outcomeLimit: 0,
                blob: .init(start: 0, count: 2),
                strings: .init(start: 0, count: 2),
                stringIndices: zero,
                classPool: zero,
                interfacePool: zero,
                aliasPool: zero,
                functionPool: zero,
                parameterPool: zero,
                propertyPool: zero,
                enumPool: zero,
                variablePool: zero,
                imports: zero,
                exports: zero,
                classes: zero,
                interfaces: zero,
                aliases: zero,
                literalUnions: zero,
                functions: zero,
                enums: zero,
                globalVariables: zero,
                macros: zero,
                referencedTypes: zero
            )],
            utf8Blob: Data([0xC3, 0xA9]),
            stringRangeWords: [0, 1, 1, 2],
            stringIndexWords: [],
            classWords: [],
            interfaceWords: [],
            aliasWords: [],
            functionWords: [],
            parameterWords: [],
            propertyWords: [],
            enumWords: [],
            variableWords: []
        )
    }
}
