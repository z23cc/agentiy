import AgentryCoreBridge
import RepoPromptDomainRuntime
import XCTest

/// Design §5.3 / §9: bidirectional build-fingerprint and protocol-version checks, executable identity,
/// and capability negotiation on the `Hello` → `Welcome | HandshakeRejected` exchange.
final class AgentSessionHostHandshakeTests: XCTestCase {
    private var harness: AgentSessionHostTestHarness!

    override func setUpWithError() throws {
        harness = try AgentSessionHostTestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    func testWelcomeCarriesHostIdentityAndEchoesClient() async throws {
        let server = try harness.startServer()
        let client = try await harness.connect()
        XCTAssertEqual(client.welcome.hostInstanceId, server.hostInstanceID)
        XCTAssertEqual(client.welcome.protocolVersion, harness.limits.protocolVersion)
        XCTAssertEqual(client.welcome.buildFingerprint, CoreBuildIdentity.buildFingerprint)
        XCTAssertEqual(client.welcome.maximumFrameBytes, harness.limits.maximumFrameBytes)
        XCTAssertEqual(client.welcome.maximumSnapshotChunkBytes, harness.limits.maximumSnapshotChunkBytes)
        XCTAssertTrue(client.welcome.capabilities.contains(.snapshotStreaming))
        XCTAssertFalse(client.welcome.clientId.isEmpty)
        let list = try await client.listSessions()
        XCTAssertTrue(list.sessions.isEmpty)
    }

    func testHostRejectsClientWithDifferentBuildFingerprint() async throws {
        try harness.startServer()
        await assertRejected(reason: .buildFingerprintMismatch) { $0.buildFingerprint = "deadbeef-not-this-build" }
    }

    func testHostRejectsClientWithDifferentProtocolVersion() async throws {
        try harness.startServer()
        await assertRejected(reason: .protocolVersionMismatch) { $0.protocolVersionOverride = harness.limits.protocolVersion + 1 }
    }

    func testClientRejectsHostWithUnexpectedBuildFingerprint() async throws {
        try harness.startServer()
        do {
            _ = try await harness.connect { $0.expectedHostBuildFingerprint = "some-other-core-build" }
            XCTFail("expected client-side rejection")
        } catch let AgentSessionHostClientError.hostBuildFingerprintMismatch(expected, actual) {
            XCTAssertEqual(expected, "some-other-core-build")
            XCTAssertEqual(actual, CoreBuildIdentity.buildFingerprint)
        }
    }

    func testHostRejectsPeerFailingExecutableIdentityVerification() async throws {
        struct RejectingVerifier: AgentSessionHostPeerVerifier {
            func verify(peerProcessID _: pid_t?, hello _: AgentHostHelloV1) -> AgentSessionHostPeerVerdict {
                .rejected(detail: "test verifier")
            }
        }
        try harness.startServer { $0.peerVerifier = RejectingVerifier() }
        await assertRejected(reason: .executableIdentityMismatch) { _ in }
    }

    func testHostRejectsClientWithoutSnapshotStreaming() async throws {
        try harness.startServer()
        await assertRejected(reason: .missingCapability) { $0.capabilities = [.canPresent] }
    }

    func testSameProcessPeerPassesProductionVerifier() async throws {
        try harness.startServer { $0.peerVerifier = AgentSessionHostSameProductPeerVerifier() }
        let client = try await harness.connect()
        XCTAssertTrue(client.isConnected)
    }

    func testOversizedFrameClosesConnection() throws {
        try harness.startServer()
        let descriptor = try AgentSessionHostSocketListener.connect(path: harness.paths.socketURL.path)
        let transport = AgentSessionHostFrameTransport(descriptor: descriptor, codec: harness.codec, limits: harness.limits)
        defer { transport.close() }
        var frame = Data()
        let oversized = harness.limits.maximumFramePayloadBytes + 1
        withUnsafeBytes(of: oversized.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(Data(repeating: 0, count: 64))
        try transport.writeFrame(frame)
        XCTAssertThrowsError(try transport.readFrame()) { error in
            guard case AgentSessionHostTransportError.closed = error else {
                return XCTFail("expected closed, got \(error)")
            }
        }
    }

    private func assertRejected(
        reason: AgentHostHandshakeRejectReasonV1,
        configure: (inout AgentSessionHostClientConfiguration) -> Void
    ) async {
        do {
            _ = try await harness.connect(configure)
            XCTFail("expected handshake rejection \(reason)")
        } catch let AgentSessionHostClientError.handshakeRejected(rejected) {
            XCTAssertEqual(rejected.reason, reason, rejected.detail)
            XCTAssertEqual(rejected.hostProtocolVersion, harness.limits.protocolVersion)
            XCTAssertEqual(rejected.hostBuildFingerprint, CoreBuildIdentity.buildFingerprint)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
