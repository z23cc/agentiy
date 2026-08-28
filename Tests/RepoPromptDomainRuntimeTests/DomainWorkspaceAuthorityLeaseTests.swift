import Darwin
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceAuthorityLeaseTests: XCTestCase {
    func testIndependentRuntimeInstancesContendUntilTheHolderReleases() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let firstIdentity = makeIdentity(mode: .app)
        let secondIdentity = makeIdentity(mode: .standalone)
        let first = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: firstIdentity
        )
        let second = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: secondIdentity
        )

        let firstStatus = await first.testAcquire()
        guard case let .held(firstOwner) = firstStatus else {
            return XCTFail("expected first lease holder, got \(firstStatus)")
        }
        XCTAssertEqual(firstOwner.runtimeID, firstIdentity.runtimeID)
        XCTAssertEqual(firstOwner.mode, DomainRuntimeMode.app.rawValue)

        let contendedStatus = await second.testAcquire()
        guard case let .contended(observedOwner) = contendedStatus else {
            return XCTFail("expected second lease to contend, got \(contendedStatus)")
        }
        XCTAssertEqual(observedOwner, firstOwner)

        await first.testRelease()
        let secondStatus = await second.testAcquire()
        guard case let .held(secondOwner) = secondStatus else {
            return XCTFail("expected second lease to acquire after release, got \(secondStatus)")
        }
        XCTAssertEqual(secondOwner.runtimeID, secondIdentity.runtimeID)
        XCTAssertNotEqual(secondOwner.leaseEpoch, firstOwner.leaseEpoch)
        XCTAssertEqual(try readOwner(from: second.scope.ownerMetadataURL), secondOwner)

        await second.testRelease()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.scope.ownerMetadataURL.path))
        let firstReleasedStatus = await first.status()
        let secondReleasedStatus = await second.status()
        XCTAssertEqual(firstReleasedStatus, .released)
        XCTAssertEqual(secondReleasedStatus, .released)
    }

    func testStaleMetadataCannotBlockAFreeKernelLease() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let lease = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .app)
        )
        let staleOwner = DomainWorkspaceAuthorityLeaseOwner(
            identity: makeIdentity(mode: .standalone),
            profileIdentifier: configuration.profileIdentifier,
            storageScopeDigest: lease.scope.storageScopeDigest,
            acquiredAt: Date(timeIntervalSince1970: 1)
        )
        try writeOwner(staleOwner, to: lease.scope.ownerMetadataURL)

        let status = await lease.testAcquire()
        guard case let .held(owner) = status else {
            return XCTFail("stale metadata must not block a free lock, got \(status)")
        }
        XCTAssertNotEqual(owner.leaseEpoch, staleOwner.leaseEpoch)
        XCTAssertEqual(try readOwner(from: lease.scope.ownerMetadataURL), owner)
        await lease.testRelease()
    }

    func testCorruptMetadataCannotBlockAFreeKernelLease() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let lease = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .standalone)
        )
        try FileManager.default.createDirectory(
            at: lease.scope.ownerMetadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: lease.scope.ownerMetadataURL)

        let status = await lease.testAcquire()
        guard case .held = status else {
            return XCTFail("corrupt metadata must not block a free lock, got \(status)")
        }
        XCTAssertNotNil(try readOwner(from: lease.scope.ownerMetadataURL))
        await lease.testRelease()
    }

    func testMetadataTamperingCannotPreemptALiveHolder() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let first = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .app)
        )
        let second = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .standalone)
        )
        guard case .held = await first.testAcquire() else {
            return XCTFail("first lease did not acquire")
        }
        try Data("tampered".utf8).write(to: first.scope.ownerMetadataURL, options: .atomic)

        let status = await second.testAcquire()
        XCTAssertEqual(status, .contended(observedOwner: nil))
        guard case .held = await first.status() else {
            return XCTFail("metadata must not change the live kernel owner")
        }

        await first.testRelease()
        guard case .held = await second.testAcquire() else {
            return XCTFail("second lease did not acquire after the live holder released")
        }
        await second.testRelease()
    }

    func testSymlinkAliasesResolveToOneLeaseScope() throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)

        let direct = DomainWorkspaceAuthorityLeaseScope(
            configuration: makeConfiguration(storageDirectory: actual)
        )
        let indirect = DomainWorkspaceAuthorityLeaseScope(
            configuration: makeConfiguration(storageDirectory: alias)
        )

        XCTAssertEqual(
            direct.canonicalWorkspaceStorageDirectory,
            indirect.canonicalWorkspaceStorageDirectory
        )
        XCTAssertEqual(direct.lockFileURL, indirect.lockFileURL)
        XCTAssertEqual(direct.ownerMetadataURL, indirect.ownerMetadataURL)
        XCTAssertEqual(direct.storageScopeDigest, indirect.storageScopeDigest)
    }

    func testProfilesSharingAWorkspaceStorageRootContendOnOneScope() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStorageDirectory = root.appendingPathComponent("shared-workspaces", isDirectory: true)
        let firstConfiguration = makeConfiguration(
            storageDirectory: root.appendingPathComponent("first-runtime", isDirectory: true),
            workspaceStorageDirectory: workspaceStorageDirectory,
            profileIdentifier: "first"
        )
        let secondConfiguration = makeConfiguration(
            storageDirectory: root.appendingPathComponent("second-runtime", isDirectory: true),
            workspaceStorageDirectory: workspaceStorageDirectory,
            profileIdentifier: "second"
        )
        let first = DomainWorkspaceAuthorityLease(
            configuration: firstConfiguration,
            identity: makeIdentity(mode: .app)
        )
        let second = DomainWorkspaceAuthorityLease(
            configuration: secondConfiguration,
            identity: makeIdentity(mode: .standalone)
        )

        XCTAssertEqual(first.scope, second.scope)
        guard case .held = await first.testAcquire() else {
            return XCTFail("first profile did not acquire the shared physical scope")
        }
        guard case .contended = await second.testAcquire() else {
            return XCTFail("second profile must contend on the shared physical scope")
        }
        await first.testRelease()
        guard case .held = await second.testAcquire() else {
            return XCTFail("second profile did not acquire after handoff")
        }
        await second.testRelease()
    }

    func testDistinctWorkspaceStorageRootsPartitionLeaseScopes() throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DomainWorkspaceAuthorityLeaseScope(
            configuration: makeConfiguration(
                storageDirectory: root,
                workspaceStorageDirectory: root.appendingPathComponent("first-workspaces", isDirectory: true)
            )
        )
        let second = DomainWorkspaceAuthorityLeaseScope(
            configuration: makeConfiguration(
                storageDirectory: root,
                workspaceStorageDirectory: root.appendingPathComponent("second-workspaces", isDirectory: true)
            )
        )

        XCTAssertNotEqual(first.lockFileURL, second.lockFileURL)
        XCTAssertNotEqual(first.storageScopeDigest, second.storageScopeDigest)
    }

    func testStorageScopeDigestHasAFixedPortableVector() {
        XCTAssertEqual(
            DomainWorkspaceAuthorityLeaseScope.storageScopeDigest(
                canonicalWorkspacePath: "/tmp/agentry/Workspaces"
            ),
            "f68efb392cd1119e04cd913c22f942246e478d73e9f1de580e00ad6dd8ab8572"
        )
    }

    func testReleaseDuringSuspendedAcquisitionInvalidatesAndClosesTheDescriptor() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let lease = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .app)
        )
        let gate = LeaseAcquisitionSuspensionGate()
        await lease.testSetAfterBlockingAcquisition {
            await gate.suspend()
        }

        let acquisition = Task { await lease.testAcquire() }
        await gate.waitUntilSuspended()
        await lease.testRelease()
        await gate.resume()

        let invalidatedStatus = await acquisition.value
        let finalStatus = await lease.status()
        XCTAssertEqual(invalidatedStatus, .released)
        XCTAssertEqual(finalStatus, .released)

        let contender = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .standalone)
        )
        guard case .held = await contender.testAcquire() else {
            return XCTFail("invalidated acquisition leaked its kernel descriptor")
        }
        await contender.testRelease()
    }

    func testLeaseArtifactsUsePrivatePermissions() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = DomainWorkspaceAuthorityLease(
            configuration: makeConfiguration(storageDirectory: root),
            identity: makeIdentity(mode: .app)
        )
        guard case .held = await lease.testAcquire() else {
            return XCTFail("lease did not acquire")
        }

        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: lease.scope.lockDirectory.path)[.posixPermissions]
                as? NSNumber
        )
        let lockPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: lease.scope.lockFileURL.path)[.posixPermissions]
                as? NSNumber
        )
        let ownerPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: lease.scope.ownerMetadataURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
        XCTAssertEqual(lockPermissions.intValue & 0o777, 0o600)
        XCTAssertEqual(ownerPermissions.intValue & 0o777, 0o600)
        await lease.testRelease()
    }

    func testMutationAccessReconcilesBeforeIssuingCommandPermits() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = DomainWorkspaceAuthorityLease(
            configuration: makeConfiguration(storageDirectory: root),
            identity: makeIdentity(mode: .app)
        )
        let access = DomainWorkspaceMutationAccess(lease: lease)

        let activated = await access.activate { permit in
            do {
                try await permit.validate(expectedStorageScopeDigest: lease.scope.storageScopeDigest)
                return permit.kind == .reconciliation
            } catch {
                return false
            }
        }
        XCTAssertEqual(activated.state, .writable)
        let commandKind = try await access.withCommandPermit { permit in
            try await permit.validate(expectedStorageScopeDigest: lease.scope.storageScopeDigest)
            return permit.kind
        }
        XCTAssertEqual(commandKind, .command)
        let reconciliationKind = try await access.withReconciliationPermit { permit in
            try await permit.validate(expectedStorageScopeDigest: lease.scope.storageScopeDigest)
            return permit.kind
        }
        XCTAssertEqual(reconciliationKind, .reconciliation)

        await access.beginDrain()
        await access.finishDrainAndRelease()
        let released = await access.snapshot()
        XCTAssertEqual(released.state, .released)
    }

    func testCopiedPermitExpiresAndForeignRegistryRejectsIt() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let first = DomainWorkspaceMutationAccess(lease: DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .app)
        ))
        let second = DomainWorkspaceMutationAccess(lease: DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .standalone)
        ))
        let firstActivation = await first.activate { _ in true }
        XCTAssertEqual(firstActivation.state, .writable)

        let copiedPermit = try await first.withCommandPermit { $0 }
        XCTAssertThrowsError(try copiedPermit.validateSynchronously(
            expectedStorageScopeDigest: first.scope.storageScopeDigest
        )) { error in
            XCTAssertEqual(error as? DomainWorkspaceMutationAccessError, .invalidPermit)
        }

        await first.beginDrain()
        await first.finishDrainAndRelease()
        let secondActivation = await second.activate { _ in true }
        XCTAssertEqual(secondActivation.state, .writable)
        let foreignRegistryRejected = try await second.withCommandPermit { permit in
            do {
                try first.permitRegistry.validate(
                    permit,
                    expectedStorageScopeDigest: first.scope.storageScopeDigest
                )
                return false
            } catch {
                return true
            }
        }
        XCTAssertTrue(foreignRegistryRejected)
        await second.beginDrain()
        await second.finishDrainAndRelease()
    }

    func testWorkspaceLeaseTokenIsValidOnlyForItsWritableEpoch() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = DomainWorkspaceMutationAccess(lease: DomainWorkspaceAuthorityLease(
            configuration: makeConfiguration(storageDirectory: root),
            identity: makeIdentity(mode: .app)
        ))
        let activated = await access.activate { _ in true }
        XCTAssertEqual(activated.state, .writable)
        let token = try await access.workspaceLeaseToken()
        try await token.validate(expectedStorageScopeDigest: access.scope.storageScopeDigest)

        await access.beginDrain()
        do {
            try await token.validate(expectedStorageScopeDigest: access.scope.storageScopeDigest)
            XCTFail("draining access unexpectedly retained a writable workspace lease token")
        } catch {
            XCTAssertEqual(error as? DomainWorkspaceMutationAccessError, .invalidPermit)
        }
        await access.finishDrainAndRelease()
    }

    func testFailedReconciliationRelinquishesAndRetriesWithAFreshEpoch() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = DomainWorkspaceAuthorityLease(
            configuration: makeConfiguration(storageDirectory: root),
            identity: makeIdentity(mode: .app)
        )
        let access = DomainWorkspaceMutationAccess(lease: lease)
        let epochs = LeaseEpochRecorder()

        let failed = await access.activate { permit in
            await epochs.append(permit.leaseEpoch)
            return false
        }
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.reason, "canonical_storage_reconciliation_failed")
        XCTAssertNil(failed.owner)

        let recovered = await access.activate { permit in
            await epochs.append(permit.leaseEpoch)
            return true
        }
        XCTAssertEqual(recovered.state, .writable)
        let recordedEpochs = await epochs.values()
        XCTAssertEqual(recordedEpochs.count, 2)
        XCTAssertNotEqual(recordedEpochs[0], recordedEpochs[1])
        await access.beginDrain()
        await access.finishDrainAndRelease()
    }

    func testContendedAccessRejectsCommandsUntilHolderHandoff() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let first = DomainWorkspaceMutationAccess(lease: DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .app)
        ))
        let second = DomainWorkspaceMutationAccess(lease: DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .standalone)
        ))

        let firstActivation = await first.activate { _ in true }
        XCTAssertEqual(firstActivation.state, .writable)
        let contended = await second.activate { _ in true }
        XCTAssertEqual(contended.state, .contended)
        do {
            _ = try await second.withCommandPermit { _ in true }
            XCTFail("contended access issued a command permit")
        } catch let error as DomainWorkspaceMutationAccessError {
            XCTAssertEqual(error, .unavailable(reason: "canonical_storage_lease_contended"))
        }

        await first.beginDrain()
        await first.finishDrainAndRelease()
        let secondActivation = await second.activate { _ in true }
        XCTAssertEqual(secondActivation.state, .writable)
        await second.beginDrain()
        await second.finishDrainAndRelease()
    }

    func testDrainWaitsForActiveCommandPermitBeforeReleasingLease() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = DomainWorkspaceMutationAccess(lease: DomainWorkspaceAuthorityLease(
            configuration: makeConfiguration(storageDirectory: root),
            identity: makeIdentity(mode: .app)
        ))
        let activation = await access.activate { _ in true }
        XCTAssertEqual(activation.state, .writable)
        let gate = MutationPermitSuspensionGate()
        let command = Task {
            try await access.withCommandPermit { _ in
                await gate.suspend()
                return true
            }
        }
        await gate.waitUntilSuspended()
        await access.beginDrain()
        let draining = await access.snapshot()
        XCTAssertEqual(draining.state, .draining)
        XCTAssertEqual(draining.activePermitCount, 1)

        let finish = Task { await access.finishDrainAndRelease() }
        try await Task.sleep(for: .milliseconds(25))
        let stillDraining = await access.snapshot()
        XCTAssertEqual(stillDraining.state, .draining)
        await gate.resume()
        let commandCompleted = try await command.value
        XCTAssertTrue(commandCompleted)
        await finish.value
        let released = await access.snapshot()
        XCTAssertEqual(released.state, .released)
    }

    func testKilledExternalProcessReleasesKernelLease() async throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = makeConfiguration(storageDirectory: root)
        let lease = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: makeIdentity(mode: .app)
        )
        try FileManager.default.createDirectory(
            at: lease.scope.lockDirectory,
            withIntermediateDirectories: true
        )
        let readyURL = root.appendingPathComponent("external-holder-ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import fcntl,pathlib,sys,time; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).write_text('ready'); time.sleep(30)",
            lease.scope.lockFileURL.path,
            readyURL.path
        ]
        try process.run()
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: readyURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path))
        let contended = await lease.testAcquire()
        XCTAssertEqual(contended, .contended(observedOwner: nil))

        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        process.waitUntilExit()
        guard case .held = await lease.testAcquire() else {
            return XCTFail("kernel did not release the external process lease after SIGKILL")
        }
        await lease.testRelease()
    }

    func testWorkspaceDocumentScopeRejectsPrefixCollisionsAndAcceptsMissingDescendants() throws {
        let root = try makeStorageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaces = root.appendingPathComponent("Workspaces", isDirectory: true)
        let scope = DomainWorkspaceAuthorityLeaseScope(configuration: makeConfiguration(
            storageDirectory: root,
            workspaceStorageDirectory: workspaces
        ))
        let inside = workspaces
            .appendingPathComponent("Workspace-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspace.json")
        let prefixCollision = root
            .appendingPathComponent("Workspaces-copy", isDirectory: true)
            .appendingPathComponent("workspace.json")

        XCTAssertTrue(scope.containsWorkspaceDocument(inside))
        XCTAssertFalse(scope.containsWorkspaceDocument(workspaces))
        XCTAssertFalse(scope.containsWorkspaceDocument(prefixCollision))
    }

    private func makeStorageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("domain-workspace-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeConfiguration(
        storageDirectory: URL,
        workspaceStorageDirectory: URL? = nil,
        profileIdentifier: String = "lease-fixture"
    ) -> DomainRuntimeConfiguration {
        DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: profileIdentifier,
            storageDirectory: storageDirectory,
            workspaceStorageDirectory: workspaceStorageDirectory,
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

    private func writeOwner(
        _ owner: DomainWorkspaceAuthorityLeaseOwner,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(owner).write(to: url, options: .atomic)
    }

    private func readOwner(from url: URL) throws -> DomainWorkspaceAuthorityLeaseOwner {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            DomainWorkspaceAuthorityLeaseOwner.self,
            from: Data(contentsOf: url)
        )
    }
}

private actor LeaseEpochRecorder {
    private var epochs: [UUID] = []

    func append(_ epoch: UUID) {
        epochs.append(epoch)
    }

    func values() -> [UUID] {
        epochs
    }
}

private actor MutationPermitSuspensionGate {
    private var isSuspended = false
    private var isResumed = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isResumed else { return }
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        guard !isResumed else { return }
        isResumed = true
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor LeaseAcquisitionSuspensionGate {
    private var isSuspended = false
    private var isResumed = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isResumed else { return }
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        guard !isResumed else { return }
        isResumed = true
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
