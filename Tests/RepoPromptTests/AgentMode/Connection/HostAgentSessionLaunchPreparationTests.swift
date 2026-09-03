import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// GUI-side debug envelope publish and path-shaped cwd. Injected secret provider — no Keychain UI.
final class HostAgentSessionLaunchPreparationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentry-launch-prep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    func testDebugEphemeralPublishesEnvelopeIDOnly() async throws {
        let context = HostAgentSessionLaunchPreparation.Context(
            applicationSupportRoot: root,
            putsEnvelopeIDOnWire: true,
            secretProvider: { _ in "ephemeral-secret" }
        )
        let prepared = try await HostAgentSessionLaunchPreparation.prepare(
            spec(provider: .kimiCode, worktreeID: nil),
            context: context,
            workingDirectory: "/tmp/workspace-root"
        )
        let envelopeID = try XCTUnwrap(prepared.credentialEnvelopeID)
        XCTAssertFalse(envelopeID.isEmpty)
        XCTAssertEqual(prepared.worktreeID, "/tmp/workspace-root")
        let url = AgentSessionHostCredentials.envelopeDirectory(applicationSupportRoot: root)
            .appendingPathComponent(envelopeID, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
        let bytes = try AgentSessionHostCredentials.redeemEnvelope(
            envelopeID: envelopeID,
            applicationSupportRoot: root
        )
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "ephemeral-secret")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDisabledContextDoesNotPublishEnvelope() async throws {
        let context = HostAgentSessionLaunchPreparation.Context(
            applicationSupportRoot: root,
            putsEnvelopeIDOnWire: false,
            secretProvider: { _ in "must-not-publish" }
        )
        let prepared = try await HostAgentSessionLaunchPreparation.prepare(
            spec(provider: .kimiCode, worktreeID: nil, envelopeID: UUID().uuidString),
            context: context,
            workingDirectory: "/Users/example/project"
        )
        XCTAssertNil(prepared.credentialEnvelopeID)
        XCTAssertEqual(prepared.worktreeID, "/Users/example/project")
        let envelopes = AgentSessionHostCredentials.envelopeDirectory(applicationSupportRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopes.path))
    }

    func testPortablePathPublishesEnvelopeInReleaseShapedContext() async throws {
        let context = HostAgentSessionLaunchPreparation.Context(
            applicationSupportRoot: root,
            putsEnvelopeIDOnWire: true,
            secretProvider: { _ in "release-portable-secret" }
        )
        let prepared = try await HostAgentSessionLaunchPreparation.prepare(
            spec(provider: .kimiCode, worktreeID: nil),
            context: context
        )
        let envelopeID = try XCTUnwrap(prepared.credentialEnvelopeID)
        let bytes = try AgentSessionHostCredentials.redeemEnvelope(
            envelopeID: envelopeID,
            applicationSupportRoot: root
        )
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "release-portable-secret")
    }

    func testRequiredProviderMissingSecretFailCloses() async {
        let context = HostAgentSessionLaunchPreparation.Context(
            applicationSupportRoot: root,
            putsEnvelopeIDOnWire: true,
            secretProvider: { _ in nil }
        )
        do {
            _ = try await HostAgentSessionLaunchPreparation.prepare(
                spec(provider: .kimiCode, worktreeID: nil),
                context: context
            )
            XCTFail("expected fail closed")
        } catch let error as AgentSessionConnectionError {
            guard case let .commandRejected(detail) = error else {
                return XCTFail("expected commandRejected, got \(error)")
            }
            XCTAssertTrue(detail.contains("credential"), detail)
        } catch {
            XCTFail("unexpected \(error)")
        }
        let envelopes = AgentSessionHostCredentials.envelopeDirectory(applicationSupportRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopes.path))
    }

    func testOfficialClaudeWithoutSecretDoesNotPublish() async throws {
        let context = HostAgentSessionLaunchPreparation.Context(
            applicationSupportRoot: root,
            putsEnvelopeIDOnWire: true,
            secretProvider: { _ in nil }
        )
        let prepared = try await HostAgentSessionLaunchPreparation.prepare(
            spec(provider: .claudeCode, worktreeID: "/repo"),
            context: context
        )
        XCTAssertNil(prepared.credentialEnvelopeID)
        XCTAssertEqual(prepared.worktreeID, "/repo")
    }

    func testPathShapedWorktreeIDWinsOverFallback() async throws {
        let context = HostAgentSessionLaunchPreparation.Context.disabled(applicationSupportRoot: root)
        let prepared = try await HostAgentSessionLaunchPreparation.prepare(
            spec(provider: .claudeCode, worktreeID: "/bound/worktree"),
            context: context,
            workingDirectory: "/fallback/root"
        )
        XCTAssertEqual(prepared.worktreeID, "/bound/worktree")
        XCTAssertNil(prepared.credentialEnvelopeID)
    }

    private func spec(
        provider: AgentProviderKind,
        worktreeID: String?,
        envelopeID: String? = nil
    ) -> AgentSessionStartSpec {
        AgentSessionStartSpec(
            tabID: UUID(),
            message: AgentSessionUserMessage(text: "hello"),
            provider: provider,
            worktreeID: worktreeID,
            credentialEnvelopeID: envelopeID
        )
    }
}
