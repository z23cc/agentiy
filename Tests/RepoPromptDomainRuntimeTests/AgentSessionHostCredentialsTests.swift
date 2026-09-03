import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// Design §10 / §11 #4: one-shot debug envelopes are 0600 files the host redeems and zeros.
/// No Keychain UI — temp Application Support only.
final class AgentSessionHostCredentialsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentry-envelope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    func testPublishWrites0600FileAndRedeemZerosThenDeletes() throws {
        let envelopeID = UUID()
        let secret = Data("debug-ephemeral-secret".utf8)
        try AgentSessionHostCredentials.publishEnvelope(
            envelopeID: envelopeID,
            bytes: secret,
            applicationSupportRoot: root
        )
        let url = AgentSessionHostCredentials.envelopeDirectory(applicationSupportRoot: root)
            .appendingPathComponent(envelopeID.uuidString.lowercased(), isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)

        let redeemed = try AgentSessionHostCredentials.redeemEnvelope(
            envelopeID: envelopeID.uuidString,
            applicationSupportRoot: root
        )
        XCTAssertEqual(redeemed, secret)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        XCTAssertThrowsError(
            try AgentSessionHostCredentials.redeemEnvelope(
                envelopeID: envelopeID.uuidString,
                applicationSupportRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? AgentSessionHostCredentialError, .unavailable)
        }
    }

    func testMissingEnvelopeFailCloses() {
        XCTAssertThrowsError(
            try AgentSessionHostCredentials.redeemEnvelope(
                envelopeID: UUID().uuidString,
                applicationSupportRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? AgentSessionHostCredentialError, .unavailable)
        }
    }

    func testGLMSecretOverlaysAuthToken() {
        let environment = AgentSessionHostCredentials.environment(
            forProviderID: "claudeCodeGLM",
            envelopeSecret: "glm-token"
        )
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "glm-token")
        XCTAssertTrue(AgentSessionHostCredentials.requiresHostSuppliedSecret(providerID: "claudeCodeGLM"))
        XCTAssertTrue(AgentSessionHostCredentials.requiresHostSuppliedSecret(providerID: "kimiCode"))
        XCTAssertFalse(AgentSessionHostCredentials.requiresHostSuppliedSecret(providerID: "claudeCode"))
    }

    func testEnvironmentWithoutEnvelopeDoesNotInventASecret() {
        let environment = AgentSessionHostCredentials.environment(
            forProviderID: "kimiCode",
            envelopeSecret: nil
        )
        XCTAssertEqual(
            environment["ANTHROPIC_API_KEY"],
            ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        )
    }
}
