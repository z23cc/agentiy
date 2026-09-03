import Darwin
import Foundation

/// Language-neutral identity for one physical canonical workspace-storage root.
///
/// P5-0a freezes this path contract before either Swift production admission or a Rust authority
/// consumes it. Resolving the nearest existing ancestor keeps path aliases from creating
/// independent mutation owners even when the workspace directory itself has not been created yet.
/// Profile identity is diagnostic only: profiles that address the same physical workspace root
/// must contend on one kernel lease.
package struct DomainWorkspaceAuthorityLeaseScope: Equatable, Sendable {
    package let canonicalWorkspaceStorageDirectory: URL
    package let lockDirectory: URL
    package let lockFileURL: URL
    package let ownerMetadataURL: URL
    package let storageScopeDigest: String

    package init(configuration: DomainRuntimeConfiguration) {
        let canonicalWorkspaceStorageDirectory = Self.canonicalDirectory(
            configuration.workspaceStorageDirectory
        )
        let lockDirectory = canonicalWorkspaceStorageDirectory
            .appendingPathComponent(".agentry-domain-runtime", isDirectory: true)
            .appendingPathComponent("locks", isDirectory: true)

        self.canonicalWorkspaceStorageDirectory = canonicalWorkspaceStorageDirectory
        self.lockDirectory = lockDirectory
        lockFileURL = lockDirectory.appendingPathComponent("workspace-authority-v1.lock")
        ownerMetadataURL = lockDirectory.appendingPathComponent("workspace-authority-owner-v1.json")
        storageScopeDigest = Self.storageScopeDigest(
            canonicalWorkspacePath: canonicalWorkspaceStorageDirectory.path
        )
    }

    /// Portable v1 digest material: exact UTF-8 domain, one NUL, then the canonical absolute
    /// workspace-storage path. Profile identity is deliberately excluded because multiple profiles
    /// may still address the same physical `Workspaces` root.
    package static func storageScopeDigest(canonicalWorkspacePath: String) -> String {
        let material = "agentry-workspace-authority-lease-v1\u{0}\(canonicalWorkspacePath)"
        return DomainContentDigest.sha256(Data(material.utf8))
    }

    /// True only when `fileURL` is a strict descendant of this physical workspace-storage root.
    /// The candidate uses the exact same nearest-existing-ancestor canonicalization as the scope,
    /// so a missing document cannot escape through a symlinked parent or string-prefix collision.
    package func containsWorkspaceDocument(_ fileURL: URL) -> Bool {
        let rootComponents = canonicalWorkspaceStorageDirectory.pathComponents
        let candidateComponents = Self.canonicalDirectory(fileURL).pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    /// Resolves the nearest existing ancestor, then appends any nonexistent tail components after
    /// lexical standardization. This makes aliases agree before the lease directory itself exists.
    private static func canonicalDirectory(_ url: URL) -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while existingAncestor.path != "/",
              !FileManager.default.fileExists(atPath: existingAncestor.path)
        {
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }
        var resolved = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return resolved.standardizedFileURL
    }
}

/// Best-effort diagnostics for a held lease. The kernel `flock`, never this document, is the
/// ownership authority. Stale, corrupt, or future metadata cannot block a free lock or preempt a
/// live holder.
package struct DomainWorkspaceAuthorityLeaseOwner: Codable, Equatable, Sendable {
    package static let schemaVersion = 1

    package let version: Int
    package let runtimeID: UUID
    package let lifecycleGeneration: UInt64
    package let processID: Int32
    package let mode: String
    package let profileIdentifier: String
    package let storageScopeDigest: String
    package let implementation: String
    package let leaseEpoch: UUID
    package let acquiredAt: Date

    /// GUI-shaped holders use `DomainRuntimeMode.app`. Headless / host fence-claims use `standalone`.
    package var isGUIShaped: Bool {
        mode == DomainRuntimeMode.app.rawValue
    }

    package init(
        identity: DomainRuntimeIdentity,
        profileIdentifier: String,
        storageScopeDigest: String,
        leaseEpoch: UUID = UUID(),
        acquiredAt: Date = Date()
    ) {
        version = Self.schemaVersion
        runtimeID = identity.runtimeID
        lifecycleGeneration = identity.lifecycleGeneration
        processID = identity.processID
        mode = identity.mode.rawValue
        self.profileIdentifier = profileIdentifier
        self.storageScopeDigest = storageScopeDigest
        implementation = "swift"
        self.leaseEpoch = leaseEpoch
        self.acquiredAt = Date(
            timeIntervalSince1970: acquiredAt.timeIntervalSince1970.rounded(.down)
        )
    }
}

package enum DomainWorkspaceAuthorityLeaseStatus: Equatable, Sendable {
    case idle
    case acquiring
    case held(DomainWorkspaceAuthorityLeaseOwner)
    case contended(observedOwner: DomainWorkspaceAuthorityLeaseOwner?)
    case failed(reason: String)
    case released
}

/// Cross-process peek of the workspace-authority flock. Does not write owner metadata and
/// does not retain the lock. The kernel flock is the ownership authority.
package enum DomainWorkspaceAuthorityLeaseObservation: Equatable, Sendable {
    case unused
    case held(DomainWorkspaceAuthorityLeaseOwner?)
    case failed(reason: String)

    package var liveGUIHolder: DomainWorkspaceAuthorityLeaseOwner? {
        guard case let .held(owner) = self, let owner, owner.isGUIShaped else { return nil }
        return owner
    }

    package var hasLiveGUIHolder: Bool {
        liveGUIHolder != nil
    }
}

package enum DomainWorkspaceMutationAccessState: String, Equatable, Sendable {
    case unavailable
    case acquiring
    case reconciling
    case writable
    case contended
    case failed
    case draining
    case released
}

package struct DomainWorkspaceMutationAccessSnapshot: Equatable, Sendable {
    package let generation: UInt64
    package let state: DomainWorkspaceMutationAccessState
    package let reason: String
    package let storageScopeDigest: String
    package let owner: DomainWorkspaceAuthorityLeaseOwner?
    package let observedContendingOwner: DomainWorkspaceAuthorityLeaseOwner?
    package let activePermitCount: Int

    package var acceptsMutations: Bool {
        state == .writable
    }
}

package enum DomainWorkspaceMutationAccessError: Error, Equatable, Sendable {
    case unavailable(reason: String)
    case invalidPermit
}

package enum DomainWorkspaceMutationPermitKind: String, Equatable, Sendable {
    case reconciliation
    case command
}

/// Runtime-scoped proof that the physical workspace lease is still held in the writable epoch that
/// activated a long-lived derived authority. Unlike an operation permit, this token does not hold
/// drain open; callers must stop and close the derived authority before mutation-access drain.
package struct DomainWorkspaceMutationLeaseToken: Sendable {
    package let storageScopeDigest: String
    package let leaseEpoch: UUID

    fileprivate let accessID: UUID
    fileprivate let registry: DomainWorkspaceMutationPermitRegistry

    package func validate(expectedStorageScopeDigest: String) async throws {
        try registry.validate(self, expectedStorageScopeDigest: expectedStorageScopeDigest)
    }
}

/// Opaque, epoch-bound proof that one operation was admitted while the runtime held the physical
/// workspace lease. Copies remain valid only while their issuing access actor retains `permitID`.
package struct DomainWorkspaceMutationPermit: Sendable {
    package let storageScopeDigest: String
    package let leaseEpoch: UUID
    package let kind: DomainWorkspaceMutationPermitKind

    fileprivate let permitID: UUID
    fileprivate let accessID: UUID
    fileprivate let registry: DomainWorkspaceMutationPermitRegistry

    fileprivate init(
        permitID: UUID,
        accessID: UUID,
        storageScopeDigest: String,
        leaseEpoch: UUID,
        kind: DomainWorkspaceMutationPermitKind,
        registry: DomainWorkspaceMutationPermitRegistry
    ) {
        self.permitID = permitID
        self.accessID = accessID
        self.storageScopeDigest = storageScopeDigest
        self.leaseEpoch = leaseEpoch
        self.kind = kind
        self.registry = registry
    }

    package func validate(expectedStorageScopeDigest: String) async throws {
        try registry.validate(self, expectedStorageScopeDigest: expectedStorageScopeDigest)
    }

    package func validateSynchronously(expectedStorageScopeDigest: String) throws {
        try registry.validate(self, expectedStorageScopeDigest: expectedStorageScopeDigest)
    }
}

/// Synchronous permit validity shared by the access actor and blocking persistence workers. The
/// registry is the blocking-boundary authority: drain preserves already admitted IDs, while epoch
/// invalidation and release atomically make every copied permit fail before another durable write.
package final class DomainWorkspaceMutationPermitRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let accessID: UUID
    private let storageScopeDigest: String
    private var state: DomainWorkspaceMutationAccessState = .unavailable
    private var leaseEpoch: UUID?
    private var activePermits: [UUID: DomainWorkspaceMutationPermitKind] = [:]

    fileprivate init(accessID: UUID, storageScopeDigest: String) {
        self.accessID = accessID
        self.storageScopeDigest = storageScopeDigest
    }

    fileprivate func transition(
        to state: DomainWorkspaceMutationAccessState,
        leaseEpoch: UUID?
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.state = state
        self.leaseEpoch = leaseEpoch
        if leaseEpoch == nil {
            activePermits.removeAll(keepingCapacity: true)
        }
    }

    fileprivate func issue(
        permitID: UUID,
        kind: DomainWorkspaceMutationPermitKind,
        leaseEpoch: UUID
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard self.leaseEpoch == leaseEpoch,
              state == .reconciling || state == .writable
        else { return }
        activePermits[permitID] = kind
    }

    fileprivate func finish(permitID: UUID) {
        lock.lock()
        activePermits.removeValue(forKey: permitID)
        lock.unlock()
    }

    package func validate(
        _ permit: DomainWorkspaceMutationPermit,
        expectedStorageScopeDigest: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard permit.accessID == accessID,
              permit.registry === self,
              permit.storageScopeDigest == storageScopeDigest,
              permit.storageScopeDigest == expectedStorageScopeDigest,
              permit.leaseEpoch == leaseEpoch,
              activePermits[permit.permitID] == permit.kind,
              state == .reconciling || state == .writable || state == .draining
        else {
            throw DomainWorkspaceMutationAccessError.invalidPermit
        }
    }

    package func validate(
        _ token: DomainWorkspaceMutationLeaseToken,
        expectedStorageScopeDigest: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard token.accessID == accessID,
              token.registry === self,
              token.storageScopeDigest == storageScopeDigest,
              token.storageScopeDigest == expectedStorageScopeDigest,
              token.leaseEpoch == leaseEpoch,
              state == .writable
        else {
            throw DomainWorkspaceMutationAccessError.invalidPermit
        }
    }
}

/// Runtime-lifetime, kernel-enforced mutation ownership primitive for one workspace persistence
/// scope. P5-0b composes it with `DomainWorkspaceMutationAccess`; every canonical workspace writer
/// requires an epoch-valid permit while this descriptor remains held.
package actor DomainWorkspaceAuthorityLease {
    private enum BlockingAcquisition: Sendable {
        case acquired(descriptor: Int32, owner: DomainWorkspaceAuthorityLeaseOwner)
        case contended(observedOwner: DomainWorkspaceAuthorityLeaseOwner?)
        case failed(reason: String)
    }

    package nonisolated let scope: DomainWorkspaceAuthorityLeaseScope

    private let identity: DomainRuntimeIdentity
    private let profileIdentifier: String
    private var descriptor: Int32?
    private var currentStatus: DomainWorkspaceAuthorityLeaseStatus = .idle
    private var acquisitionGeneration: UInt64 = 0

    #if DEBUG
        private var testAfterBlockingAcquisition: (@Sendable () async -> Void)?
    #endif

    package init(
        configuration: DomainRuntimeConfiguration,
        identity: DomainRuntimeIdentity
    ) {
        scope = DomainWorkspaceAuthorityLeaseScope(configuration: configuration)
        self.identity = identity
        profileIdentifier = configuration.profileIdentifier
    }

    deinit {
        if let descriptor {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    package func status() -> DomainWorkspaceAuthorityLeaseStatus {
        currentStatus
    }

        #if DEBUG
            package func testSetAfterBlockingAcquisition(
            _ hook: (@Sendable () async -> Void)?
        ) {
            testAfterBlockingAcquisition = hook
        }

        @discardableResult
        package func testAcquire() async -> DomainWorkspaceAuthorityLeaseStatus {
            await acquire()
        }

        package func testRelease() async {
            await release()
        }
    #endif

    /// Peek the kernel lock without retaining it or rewriting owner metadata.
    package nonisolated static func observe(
        scope: DomainWorkspaceAuthorityLeaseScope
    ) -> DomainWorkspaceAuthorityLeaseObservation {
        observeBlocking(scope: scope)
    }

    /// Host / headless fence-claim. Same acquire as mutation access.
    @discardableResult
    package func fenceClaim() async -> DomainWorkspaceAuthorityLeaseStatus {
        await acquire()
    }

    package func releaseHeld() async {
        await release()
    }

    /// Attempts one nonblocking acquisition. Contended and recoverable failure states may retry;
    /// an explicitly released lease is terminal and cannot be reacquired.
    @discardableResult
    fileprivate func acquire() async -> DomainWorkspaceAuthorityLeaseStatus {
        switch currentStatus {
        case .held, .acquiring:
            return currentStatus
        case .released:
            return .failed(reason: "canonical_storage_lease_released")
        case .idle, .contended, .failed:
            break
        }
        guard !Task.isCancelled else {
            currentStatus = .failed(reason: "canonical_storage_lease_acquisition_cancelled")
            return currentStatus
        }

        acquisitionGeneration &+= 1
        let acquisitionGeneration = acquisitionGeneration
        currentStatus = .acquiring
        let scope = scope
        let owner = DomainWorkspaceAuthorityLeaseOwner(
            identity: identity,
            profileIdentifier: profileIdentifier,
            storageScopeDigest: scope.storageScopeDigest
        )
        let result = await Self.runBlocking {
            Self.acquireBlocking(scope: scope, owner: owner)
        }

        #if DEBUG
            if let testAfterBlockingAcquisition {
                await testAfterBlockingAcquisition()
            }
        #endif

        guard self.acquisitionGeneration == acquisitionGeneration,
              currentStatus == .acquiring
        else {
            if case let .acquired(descriptor, acquiredOwner) = result {
                await Self.runBlocking {
                    Self.releaseBlocking(
                        descriptor: descriptor,
                        owner: acquiredOwner,
                        metadataURL: scope.ownerMetadataURL
                    )
                }
            }
            return currentStatus
        }

        if Task.isCancelled {
            self.acquisitionGeneration &+= 1
            currentStatus = .failed(reason: "canonical_storage_lease_acquisition_cancelled")
            if case let .acquired(descriptor, acquiredOwner) = result {
                await Self.runBlocking {
                    Self.releaseBlocking(
                        descriptor: descriptor,
                        owner: acquiredOwner,
                        metadataURL: scope.ownerMetadataURL
                    )
                }
            }
            return currentStatus
        }

        switch result {
        case let .acquired(acquiredDescriptor, acquiredOwner):
            descriptor = acquiredDescriptor
            currentStatus = .held(acquiredOwner)
        case let .contended(observedOwner):
            currentStatus = .contended(observedOwner: observedOwner)
        case let .failed(reason):
            currentStatus = .failed(reason: reason)
        }
        return currentStatus
    }

    /// Releases ownership without terminally closing the primitive. P5-0b uses this after a failed
    /// reconciliation so a later retry must acquire a fresh epoch and reconcile again.
    fileprivate func relinquishForRetry() async {
        await release(terminal: false)
    }

    /// Removes matching diagnostics while the kernel lock is still held, then unlocks and closes
    /// the descriptor. Metadata cleanup failure never extends ownership; descriptor release is the
    /// authoritative handoff. Terminal release prevents a stopped runtime from reacquiring.
    fileprivate func release() async {
        await release(terminal: true)
    }

    private func release(terminal: Bool) async {
        acquisitionGeneration &+= 1
        guard case let .held(owner) = currentStatus, let descriptor else {
            currentStatus = terminal ? .released : .idle
            self.descriptor = nil
            return
        }
        currentStatus = terminal ? .released : .idle
        self.descriptor = nil
        let metadataURL = scope.ownerMetadataURL
        await Self.runBlocking {
            Self.releaseBlocking(
                descriptor: descriptor,
                owner: owner,
                metadataURL: metadataURL
            )
        }
    }

    private nonisolated static func acquireBlocking(
        scope: DomainWorkspaceAuthorityLeaseScope,
        owner: DomainWorkspaceAuthorityLeaseOwner
    ) -> BlockingAcquisition {
        do {
            try FileManager.default.createDirectory(
                at: scope.lockDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scope.lockDirectory.path
            )
        } catch {
            return .failed(reason: "canonical_storage_lease_directory_failed")
        }

        let descriptor = open(
            scope.lockFileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            return .failed(reason: "canonical_storage_lease_open_failed_\(errno)")
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            close(descriptor)
            return .failed(reason: "canonical_storage_lease_permissions_failed_\(code)")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let observedOwner = readOwnerMetadata(scope.ownerMetadataURL)
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                return .contended(observedOwner: observedOwner)
            }
            return .failed(reason: "canonical_storage_lease_acquire_failed_\(code)")
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try DomainPersistenceAtomicWriter.write(
                encoder.encode(owner),
                to: scope.ownerMetadataURL
            )
            return .acquired(descriptor: descriptor, owner: owner)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            return .failed(reason: "canonical_storage_lease_metadata_failed")
        }
    }

    private nonisolated static func releaseBlocking(
        descriptor: Int32,
        owner: DomainWorkspaceAuthorityLeaseOwner,
        metadataURL: URL
    ) {
        if readOwnerMetadata(metadataURL)?.leaseEpoch == owner.leaseEpoch {
            _ = unlink(metadataURL.path)
        }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private nonisolated static func observeBlocking(
        scope: DomainWorkspaceAuthorityLeaseScope
    ) -> DomainWorkspaceAuthorityLeaseObservation {
        let descriptor = open(
            scope.lockFileURL.path,
            O_RDONLY | O_CLOEXEC
        )
        if descriptor < 0 {
            if errno == ENOENT {
                return .unused
            }
            return .failed(reason: "canonical_storage_lease_observe_open_failed_\(errno)")
        }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return .unused
        }
        let code = errno
        if code == EWOULDBLOCK || code == EAGAIN {
            return .held(readOwnerMetadata(scope.ownerMetadataURL))
        }
        return .failed(reason: "canonical_storage_lease_observe_failed_\(code)")
    }

    private nonisolated static func readOwnerMetadata(
        _ url: URL
    ) -> DomainWorkspaceAuthorityLeaseOwner? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let owner = try? decoder.decode(DomainWorkspaceAuthorityLeaseOwner.self, from: data),
              owner.version == DomainWorkspaceAuthorityLeaseOwner.schemaVersion
        else { return nil }
        return owner
    }

    private nonisolated static func runBlocking<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: operation())
            }
        }
    }
}

/// Process-wide admission and drain authority layered over one kernel lease. The runtime owns one
/// instance; windows, commands, and persistence workers only receive short-lived opaque permits.
package actor DomainWorkspaceMutationAccess {
    private nonisolated let lease: DomainWorkspaceAuthorityLease
    package nonisolated let scope: DomainWorkspaceAuthorityLeaseScope
    package nonisolated let permitRegistry: DomainWorkspaceMutationPermitRegistry

    private let accessID: UUID
    private var transitionGeneration: UInt64 = 0
    private var state: DomainWorkspaceMutationAccessState = .unavailable
    private var failedReason: String?
    private var owner: DomainWorkspaceAuthorityLeaseOwner?
    private var observedContendingOwner: DomainWorkspaceAuthorityLeaseOwner?
    private var activePermitIDs: Set<UUID> = []
    private var permitDrainWaiters: [CheckedContinuation<Void, Never>] = []

    package init(lease: DomainWorkspaceAuthorityLease) {
        let accessID = UUID()
        self.accessID = accessID
        self.lease = lease
        scope = lease.scope
        permitRegistry = DomainWorkspaceMutationPermitRegistry(
            accessID: accessID,
            storageScopeDigest: lease.scope.storageScopeDigest
        )
    }

    package func snapshot() -> DomainWorkspaceMutationAccessSnapshot {
        DomainWorkspaceMutationAccessSnapshot(
            generation: transitionGeneration,
            state: state,
            reason: reason,
            storageScopeDigest: scope.storageScopeDigest,
            owner: owner,
            observedContendingOwner: observedContendingOwner,
            activePermitCount: activePermitIDs.count
        )
    }

    /// Acquires a fresh epoch and runs one forced durable reconciliation before command permits can
    /// be issued. Concurrent activation attempts observe the current stable/in-progress state and
    /// never start a second acquisition or reconciliation.
    @discardableResult
    package func activate(
        reconcile: @escaping @Sendable (DomainWorkspaceMutationPermit) async -> Bool
    ) async -> DomainWorkspaceMutationAccessSnapshot {
        switch state {
        case .writable, .acquiring, .reconciling, .draining, .released:
            return snapshot()
        case .unavailable, .contended, .failed:
            break
        }

        transition(to: .acquiring)
        failedReason = nil
        observedContendingOwner = nil
        let leaseStatus = await lease.acquire()
        guard state == .acquiring else { return snapshot() }

        switch leaseStatus {
        case let .held(acquiredOwner):
            owner = acquiredOwner
            transition(to: .reconciling)
            let permit = issuePermit(kind: .reconciliation, owner: acquiredOwner)
            let reconciled = await reconcile(permit)
            finishPermit(permit)
            guard state == .reconciling else { return snapshot() }
            if reconciled, !Task.isCancelled {
                transition(to: .writable)
            } else {
                owner = nil
                failedReason = "canonical_storage_reconciliation_failed"
                transition(to: .failed)
                await lease.relinquishForRetry()
                guard state == .failed else { return snapshot() }
            }
        case let .contended(observedOwner):
            owner = nil
            observedContendingOwner = observedOwner
            transition(to: .contended)
        case let .failed(reason):
            owner = nil
            failedReason = reason
            transition(to: .failed)
        case .idle, .acquiring:
            owner = nil
            failedReason = "canonical_storage_lease_acquisition_incomplete"
            transition(to: .failed)
        case .released:
            owner = nil
            transition(to: .released)
        }
        return snapshot()
    }

    package func workspaceLeaseToken() throws -> DomainWorkspaceMutationLeaseToken {
        guard state == .writable, let owner else {
            throw DomainWorkspaceMutationAccessError.unavailable(reason: reason)
        }
        return DomainWorkspaceMutationLeaseToken(
            storageScopeDigest: scope.storageScopeDigest,
            leaseEpoch: owner.leaseEpoch,
            accessID: accessID,
            registry: permitRegistry
        )
    }

    package func withCommandPermit<T: Sendable>(
        _ operation: @escaping @Sendable (DomainWorkspaceMutationPermit) async throws -> T
    ) async throws -> T {
        try await withPermit(kind: .command, operation)
    }

    package func withReconciliationPermit<T: Sendable>(
        _ operation: @escaping @Sendable (DomainWorkspaceMutationPermit) async throws -> T
    ) async throws -> T {
        try await withPermit(kind: .reconciliation, operation)
    }

    private func withPermit<T: Sendable>(
        kind: DomainWorkspaceMutationPermitKind,
        _ operation: @escaping @Sendable (DomainWorkspaceMutationPermit) async throws -> T
    ) async throws -> T {
        guard state == .writable, let owner else {
            throw DomainWorkspaceMutationAccessError.unavailable(reason: reason)
        }
        let permit = issuePermit(kind: kind, owner: owner)
        do {
            let result = try await operation(permit)
            finishPermit(permit)
            return result
        } catch {
            finishPermit(permit)
            throw error
        }
    }

    package func beginDrain() {
        guard state != .released else { return }
        transition(to: .draining)
        failedReason = nil
        observedContendingOwner = nil
    }

    package func waitForDrain() async {
        while !activePermitIDs.isEmpty {
            await withCheckedContinuation { continuation in
                permitDrainWaiters.append(continuation)
            }
        }
    }

    package func finishDrainAndRelease() async {
        if state != .draining, state != .released {
            beginDrain()
        }
        await waitForDrain()
        guard state != .released else { return }
        owner = nil
        transition(to: .released)
        await lease.release()
    }

    private func transition(to next: DomainWorkspaceMutationAccessState) {
        guard state != next else { return }
        state = next
        transitionGeneration &+= 1
        permitRegistry.transition(to: next, leaseEpoch: owner?.leaseEpoch)
    }

    private var reason: String {
        switch state {
        case .unavailable:
            "canonical_storage_lease_not_acquired"
        case .acquiring:
            "canonical_storage_lease_acquiring"
        case .reconciling:
            "canonical_storage_lease_reconciling"
        case .writable:
            "canonical_storage_lease_writable"
        case .contended:
            "canonical_storage_lease_contended"
        case .failed:
            failedReason ?? "canonical_storage_lease_failed"
        case .draining:
            "canonical_storage_lease_draining"
        case .released:
            "canonical_storage_lease_released"
        }
    }

    private func issuePermit(
        kind: DomainWorkspaceMutationPermitKind,
        owner: DomainWorkspaceAuthorityLeaseOwner
    ) -> DomainWorkspaceMutationPermit {
        let permitID = UUID()
        activePermitIDs.insert(permitID)
        permitRegistry.issue(permitID: permitID, kind: kind, leaseEpoch: owner.leaseEpoch)
        transitionGeneration &+= 1
        return DomainWorkspaceMutationPermit(
            permitID: permitID,
            accessID: accessID,
            storageScopeDigest: scope.storageScopeDigest,
            leaseEpoch: owner.leaseEpoch,
            kind: kind,
            registry: permitRegistry
        )
    }

    private func finishPermit(_ permit: DomainWorkspaceMutationPermit) {
        guard permit.accessID == accessID,
              activePermitIDs.remove(permit.permitID) != nil
        else { return }
        permitRegistry.finish(permitID: permit.permitID)
        transitionGeneration &+= 1
        guard activePermitIDs.isEmpty else { return }
        let waiters = permitDrainWaiters
        permitDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
