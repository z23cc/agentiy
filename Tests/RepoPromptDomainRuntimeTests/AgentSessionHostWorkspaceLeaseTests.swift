import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// P8: host fence-claims `DomainWorkspaceAuthorityLease` when unused, refuses a GUI-shaped holder,
/// and releases on explicit shutdown. No second lock.
final class AgentSessionHostWorkspaceLeaseTests: XCTestCase {
    func testClaimsWhenNoHolderAndReleases() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let host = AgentSessionHostWorkspaceLease(
            configuration: configuration,
            identity: makeIdentity(mode: .standalone)
        )

        XCTAssertEqual(AgentSessionHostWorkspaceLease.observe(configuration: configuration), .unused)
        let decision = await host.fenceClaim()
        guard case let .claimed(owner) = decision else {
            return XCTFail("expected claim, got \(decision)")
        }
        XCTAssertEqual(owner.mode, DomainRuntimeMode.standalone.rawValue)
        XCTAssertFalse(owner.isGUIShaped)

        let observation = AgentSessionHostWorkspaceLease.observe(configuration: configuration)
        XCTAssertEqual(observation, .held(owner))
        XCTAssertFalse(observation.hasLiveGUIHolder)

        await host.release()
        XCTAssertEqual(AgentSessionHostWorkspaceLease.observe(configuration: configuration), .unused)
    }

    func testMustNotClaimWhenGUIShapedHolderExists() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let gui = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .app)
        )
        let guiStatus = await gui.testAcquire()
        guard case let .held(guiOwner) = guiStatus else {
            return XCTFail("GUI fixture must hold the lease, got \(guiStatus)")
        }
        XCTAssertTrue(guiOwner.isGUIShaped)
        XCTAssertTrue(AgentSessionHostWorkspaceLease.observe(configuration: configuration).hasLiveGUIHolder)

        let host = AgentSessionHostWorkspaceLease(
            configuration: configuration,
            identity: makeIdentity(mode: .standalone)
        )
        let decision = await host.fenceClaim()
        guard case let .refusedGUI(observed) = decision else {
            return XCTFail("host must not steal a GUI holder, got \(decision)")
        }
        XCTAssertEqual(observed.runtimeID, guiOwner.runtimeID)
        guard case .held = await gui.status() else {
            return XCTFail("GUI holder must remain the writer")
        }

        await gui.testRelease()
        let after = await host.fenceClaim()
        guard case .claimed = after else {
            return XCTFail("host may claim after the GUI releases, got \(after)")
        }
        await host.release()
    }

    func testReleaseOnHostShutdownLeavesFlockFree() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let host = AgentSessionHostWorkspaceLease(
            configuration: configuration,
            identity: makeIdentity(mode: .standalone)
        )
        guard case .claimed = await host.fenceClaim() else {
            return XCTFail("setup claim failed")
        }
        await host.release()
        let contender = AgentSessionHostWorkspaceLease(
            configuration: configuration,
            identity: makeIdentity(mode: .standalone)
        )
        let decision = await contender.fenceClaim()
        guard case .claimed = decision else {
            return XCTFail("released host lease must be reclaimable, got \(decision)")
        }
        await contender.release()
    }

    private func makeStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentry-host-workspace-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeConfiguration(storageDirectory: URL) -> DomainRuntimeConfiguration {
        DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "host-workspace-lease",
            storageDirectory: storageDirectory,
            eventDirectory: storageDirectory.appendingPathComponent("events", isDirectory: true),
            temporaryDirectory: storageDirectory.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        )
    }

    private func makeIdentity(mode: DomainRuntimeMode) -> DomainRuntimeIdentity {
        DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: ProcessInfo.processInfo.processIdentifier,
            mode: mode,
            createdAt: Date()
        )
    }
}
