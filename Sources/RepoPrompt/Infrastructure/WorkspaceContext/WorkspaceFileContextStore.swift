import Combine
import CoreServices
import Dispatch
import Foundation
import RepoPromptCodeMapCore
import RepoPromptSearchCore
#if DEBUG
    import AgentryCoreBridge
    import CryptoKit
    import RepoPromptDomainRuntime
#endif

enum WorkspaceFileTreePresentationMode: String {
    case none
    case selected
    case full
    case folders
    case auto

    init(fileTreeOption: FileTreeOption) {
        switch fileTreeOption {
        case .none:
            self = .none
        case .selected:
            self = .selected
        case .files:
            self = .full
        case .auto:
            self = .auto
        }
    }
}

typealias WorkspaceFileTreeSnapshotMode = WorkspaceFileTreePresentationMode

struct WorkspaceBoundedFolderExpansionResult: Equatable {
    let files: [WorkspaceFileRecord]
    let handled: Bool
    let displayPath: String?
    let issue: PathResolutionIssue?
    let didExceedLimit: Bool
    let visitedUniqueFileCount: Int
}

struct WorkspaceBoundedCodeStructureFileResolution: Equatable {
    let files: [WorkspaceFileRecord]
    let didExceedLimit: Bool
    let visitedUniqueFileCount: Int
}

struct WorkspaceFileTreePresentationRequest {
    fileprivate let selectedFileIDs: Set<UUID>
    let mode: WorkspaceFileTreePresentationMode
    let filePathDisplay: FilePathDisplay
    let onlyIncludeRootsWithSelectedFiles: Bool
    let includeLegend: Bool
    let showCodeMapMarkers: Bool
    let rootScope: WorkspaceLookupRootScope
    let startPath: String?
    let maxDepth: Int?

    init(
        mode: WorkspaceFileTreePresentationMode,
        filePathDisplay: FilePathDisplay,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeLegend: Bool,
        showCodeMapMarkers: Bool = true,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        startPath: String? = nil,
        maxDepth: Int? = nil
    ) {
        selectedFileIDs = []
        self.mode = mode
        self.filePathDisplay = filePathDisplay
        self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
        self.includeLegend = includeLegend
        self.showCodeMapMarkers = showCodeMapMarkers
        self.rootScope = rootScope
        self.startPath = startPath
        self.maxDepth = maxDepth
    }
}

typealias WorkspaceFileTreeSnapshotRequest = WorkspaceFileTreePresentationRequest

enum WorkspaceFileCatalogMaterializationResult: Equatable {
    case materialized(WorkspaceFileRecord)
    case ineligible(CatalogRegularFileIneligibilityReason)

    var file: WorkspaceFileRecord? {
        if case let .materialized(file) = self { return file }
        return nil
    }

    var ineligibilityReason: CatalogRegularFileIneligibilityReason? {
        if case let .ineligible(reason) = self { return reason }
        return nil
    }
}

enum WorkspaceExplicitFileMaterializationResult: Equatable {
    case materialized(WorkspaceFileRecord)
    case noCandidate
    case blocked
    case ambiguous
}

enum WorkspaceExplicitCatalogFileLookupResult: Equatable {
    case matched(WorkspaceFileRecord)
    case noCandidate
    case blocked
    case ambiguous
}

struct WorkspaceDisplayRootRefsSnapshot: Equatable {
    let visibleRoots: [WorkspaceRootRef]
    let allRoots: [WorkspaceRootRef]
}

private final class WorkspaceSessionRootLifetimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func advance() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func snapshot(physicalRootPaths: [String]) -> WorkspaceSessionRootLifetimeSnapshot {
        lock.lock()
        let capturedGeneration = generation
        lock.unlock()
        return WorkspaceSessionRootLifetimeSnapshot(
            clock: self,
            generation: capturedGeneration,
            physicalRootPaths: physicalRootPaths
        )
    }

    func performIfGenerationCurrent(
        generation expectedGeneration: UInt64,
        operation: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        operation()
        return true
    }
}

struct WorkspaceSessionRootLifetimeSnapshot: @unchecked Sendable {
    fileprivate let clock: WorkspaceSessionRootLifetimeClock
    fileprivate let generation: UInt64
    fileprivate let physicalRootPaths: [String]

    func isGenerationCurrent() -> Bool {
        clock.performIfGenerationCurrent(
            generation: generation,
            operation: {}
        )
    }

    func isCurrent() async -> Bool {
        let physicalRootPaths = physicalRootPaths
        let rootsExist = await Task.detached(priority: .userInitiated) {
            physicalRootPaths.allSatisfy { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        }.value
        guard rootsExist else { return false }
        return isGenerationCurrent()
    }

    @discardableResult
    func performIfGenerationCurrent(_ operation: () -> Void) -> Bool {
        clock.performIfGenerationCurrent(
            generation: generation,
            operation: operation
        )
    }
}

actor WorkspaceFileContextStore {
    enum CodemapGraphIndexBuildStoreEventKind: String, Hashable {
        case rootInventoryAndSearchReady
        case scheduled
        case started
        case eligibilityEligible
        case eligibilityTerminal
        case eligibilityTransient
        case setupJoining
        case engineScheduling
        case handedOff
        case cancelled
        case superseded
        case retryScheduled
        case retryStarted
        case retryExhausted
        case prioritizeNow
        case repositoryAuthorityDetached
    }

    #if DEBUG
        enum CodemapGraphIndexBuildLaunchPolicyForTesting: Equatable {
            case enabled
            case disabled
        }

        struct CodemapGraphIndexBuildStoreEvent: Hashable {
            let ordinal: UInt64
            let rootEpoch: WorkspaceCodemapRootEpoch
            let kind: CodemapGraphIndexBuildStoreEventKind
            let launchPhase: WorkspaceCodemapGraphIndexLaunchPhase
            let uptimeNanoseconds: UInt64
        }

        enum RootCatalogShardFallbackReason: String, CaseIterable, Hashable {
            case missingReusableShard
            case generationGap
            case fullResync
            case unsafeOrAmbiguousBatch
            case retentionBoundary
            case patchThresholdExceeded
            case patchApplicationBackstop
            case shadowValidationMismatch
        }

        struct RootCatalogShardGenerationDebugSnapshot: Equatable {
            let rootID: UUID
            let lifetimeID: UUID?
            let publishedTopologyGeneration: UInt64?
            let liveTopologyGenerations: [UInt64]
            let retainedTopologyGenerations: [UInt64]
            let buildCount: Int
            let pathIndexBuildCount: Int
            let overlayPathIndexBuildCount: Int
            let patchCount: Int
            let authoritativeRebuildCount: Int
            let fallbackCount: Int
            let fallbackReasonCounts: [RootCatalogShardFallbackReason: Int]
            let lastAppliedIndexGeneration: UInt64?
            let deltaStateDirty: Bool
            let backstopCount: Int
            let maxLiveGenerationCount: Int
        }

        struct RootCatalogShardDebugSnapshot: Equatable {
            let liveGenerationCapPerRoot: Int
            let maxPatchLogicalMutationCount: Int
            let publishedShardCount: Int
            let totalBuildCount: Int
            let totalBackstopCount: Int
            let singleShardCompositionReuseCount: Int
            let genericMergeElementVisitCount: Int
            let shadowComparisonCount: Int
            let shadowMismatchCount: Int
            let lastShadowByteCount: Int
            let roots: [RootCatalogShardGenerationDebugSnapshot]
        }

        struct StoreWorkDiagnosticsSnapshot: Equatable {
            let invalidations: [CatalogInvalidationDebugEvent]
            let catalogRebuild: CatalogRebuildDebugSnapshot
            let rootCatalogShards: RootCatalogShardDebugSnapshot
        }

        struct PublishedSeededAuthorityDebugSnapshot: Equatable {
            let epoch: UInt64
            let isBlocked: Bool
            let activeMutationDepth: Int
            let isReconciling: Bool
            let reconciliationFailed: Bool
            let waiterCount: Int
            let fullCrawlCount: Int
        }

        struct ReadSearchRootDiagnosticsSnapshot: Equatable {
            let rootID: UUID
            let rootToken: UUID
            let rootPath: String
            let rootKind: String
            let crawlCount: Int
            let watcherActive: Bool
            let explicitWatcherDemand: Bool
            let sessionWorktreeOwnerCount: Int
            let ingress: WorkspaceFileSystemIngressCoordinator.DebugSnapshot
            let barrier: ScopedIngressBarrierDebugSnapshot
            let freshness: FileSystemService.FreshnessWorkDiagnosticsSnapshot
            let invalidation: PublicationInvalidationHistoryDebugSnapshot
            let producedAppliedIndexGeneration: UInt64
        }

        struct ApplyEditsRebaseProbePathSnapshot: Equatable {
            let rootID: UUID
            let rootLifetimeID: UUID
            let rootToken: UUID
            let rootPath: String
            let fileID: UUID
            let fullPath: String
            let relativePath: String
            let isSessionWorktree: Bool
            let producedAppliedIndexGeneration: UInt64
        }

        private final class PublicationInvalidationRecorder: @unchecked Sendable {
            let preparedDeltaCount: Int
            var topologyInvalidationCount = 0
            var catalogGenerationAdvanceCount = 0
            var searchCatalogCacheClearCount = 0
            var pathWorkerInvalidationRequestCount = 0
            var contentInvalidationCount = 0
            var decodedCacheInvalidationRequestCount = 0
            var codemapInvalidationRequestCount = 0
            var appliedIndexEventYieldCount = 0
            var distinctContentKeys = Set<WorkspaceSearchContentCacheKey>()

            init(preparedDeltaCount: Int) {
                self.preparedDeltaCount = preparedDeltaCount
            }
        }

        private struct PublicationInvalidationHistoryState {
            var totalObservedPublicationCount = 0
            var samples: [PublicationInvalidationDebugSample] = []
        }

        @TaskLocal private static var activePublicationInvalidationRecorder: PublicationInvalidationRecorder?
        private static let publicationInvalidationSampleLimit = 32
    #endif

    struct CodemapGraphIndexBuildRetryPolicy: @unchecked Sendable {
        let maximumRetryCount: Int
        let initialBackoffNanoseconds: UInt64
        let maximumBackoffNanoseconds: UInt64
        let nowNanoseconds: @Sendable () -> UInt64
        let sleep: @Sendable (UInt64) async throws -> Void

        static let production = Self(
            maximumRetryCount: 3,
            initialBackoffNanoseconds: 250_000_000,
            maximumBackoffNanoseconds: 2_000_000_000,
            nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
            sleep: { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        )

        func backoffNanoseconds(forAttempt attempt: Int) -> UInt64 {
            guard attempt > 1 else { return min(initialBackoffNanoseconds, maximumBackoffNanoseconds) }
            var delay = min(initialBackoffNanoseconds, maximumBackoffNanoseconds)
            for _ in 1 ..< attempt {
                if delay >= maximumBackoffNanoseconds { return maximumBackoffNanoseconds }
                let (doubled, overflow) = delay.multipliedReportingOverflow(by: 2)
                delay = overflow ? maximumBackoffNanoseconds : min(doubled, maximumBackoffNanoseconds)
            }
            return delay
        }
    }

    private static let maximumRetainedCodemapPresentationRecordsPerRoot = 64
    private static let maximumCodemapPresentationRequestsPerBundle = 4096

    private struct RootState {
        let lifetimeID: UUID
        let root: WorkspaceRootRecord
        let service: FileSystemService
        var folderIDsByRelativePath: [String: UUID]
        var fileIDsByRelativePath: [String: UUID]
        var childFolderIDsByFolderID: [UUID: [UUID]]
        var childFileIDsByFolderID: [UUID: [UUID]]
    }

    private struct PendingSeededRoot {
        let id: WorkspacePendingSeededRootID
        let token: WorkspaceSessionWorktreeOwnershipToken
        let bindingFingerprint: String
        let standardizedPath: String
        let initializationID: FileSystemSeedInitializationID
        let loadConfiguration: RootLoadConfiguration
        let startupContext: WorktreeStartupContext
        var phase: WorkspacePendingSeededRootPhase
        var state: RootState
        var indexes: RootIndexBuffers
        var captureIdentity: FileSystemSeedCaptureIdentity?
        var authorityFence: GitWorkspacePendingInitializationAuthorityFence?
        var authorityInvalidationGeneration: UInt64
        var authorityAcceptedMetadataWatermark: UInt64
        var authorityMutationDepth: Int
        var snapshot: WorkspaceRootReusableSnapshot?
        var targetPlanHandle: WorkspaceRootTargetSeedPlanHandle?
        var authorityClaim: WorkspaceRootSeedServingAuthorityClaim?
        var attachment: WatcherPublisherAttachment?
        // P4-6b reroute: replaces `preparedShard: RootCatalogShard?` -- readiness for live
        // publication is now "Rust has the validated record set" rather than "a Swift-side shard
        // object was built". See `preparePendingSeededRoot`'s reroute comment.
        var rustSeeded: Bool
        var lastAppliedServicePublicationSequence: UInt64
        var lastAppliedWatcherWatermark: FileSystemWatcherIngressMailbox.Watermark
        var activationProof: FileSystemSeedPublicationActivationProof?
        var terminalFallbackReason: WorkspaceRootSeedFallbackReason?
    }

    private struct PublishedSeededAuthorityState {
        var epoch: UInt64
        var pendingInvalidationGeneration: UInt64?
        var pendingAcceptedMetadataWatermark: UInt64
        var activeMutationDepth: Int
        var isBlocked: Bool
        var isReconciling: Bool
        var reconciliationFailed: Bool
        var fullCrawlAttemptedGeneration: UInt64?
        var fullCrawlCompletedGeneration: UInt64?
    }

    private enum PendingSeededRootAttempt {
        case prepared(WorkspacePendingSeededRootPreparation)
        case fallback(WorkspaceRootSeedFallbackReason)
    }

    private struct CodemapRootAuthority: Equatable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let standardizedRootPath: String
        let catalogGeneration: UInt64
        let ingressGeneration: UInt64
    }

    private enum CodemapEligibilityResolution {
        case eligible
        case terminal(WorkspaceCodemapGitTerminalUnavailableReason, WorkspaceCodemapNonGitFilesystemProof?)
        case transient(WorkspaceCodemapGitTransientUnavailableReason)
        case stale
        case cancelled
    }

    private struct CodemapEligibilityFlight {
        let id: UUID
        let authority: CodemapRootAuthority
        let task: Task<CodemapEligibilityResolution, Never>
    }

    private struct CodemapCompletedEligibility {
        let authority: CodemapRootAuthority
        let result: CodemapEligibilityResolution
    }

    private struct CodemapGraphIndexBuildLaunch {
        let id: UUID
        let authority: CodemapRootAuthority
        let retryAttempt: Int
        var phase: WorkspaceCodemapGraphIndexLaunchPhase
        var task: Task<Void, Never>?
        let createdUptimeNanoseconds: UInt64
        var phaseEnteredUptimeNanoseconds: UInt64
    }

    private struct CodemapGraphIndexRetryExhaustion {
        let attempt: Int
        let uptimeNanoseconds: UInt64
    }

    private struct CodemapGraphIndexBuildRetry {
        let id: UUID
        let authority: CodemapRootAuthority
        let attempt: Int
        let deadlineNanoseconds: UInt64
        let task: Task<Void, Never>
    }

    /// UI-status lower bound for coverage that remains valid while a path-level
    /// invalidation replaces the current projection job.
    private struct CodemapRootStatusCoverageBaseline {
        var retainedCandidateCount: UInt64
        var invalidatedCandidateFileIDs: Set<UUID>
    }

    private enum CodemapSetupDisposition {
        case ready
        case unavailable(WorkspaceCodemapArtifactDemandUnavailableReason)
    }

    private enum CodemapInvalidationCommand {
        case modified(Set<String>)
        case deleted(Set<String>)
        case renamed(from: String, to: String)
        case securityExcluded(Set<String>)
        case watcherGap
        case checkout
        case repositoryAuthority
        case catalogAdvanced
        case unload
    }

    private final class CodemapDemandCompletion: @unchecked Sendable {
        private struct Waiter {
            let continuation: CheckedContinuation<Void, Never>
            var deadlineTask: Task<Void, Never>?
        }

        private let lock = NSLock()
        private var didComplete = false
        private var waitersByID: [UUID: Waiter] = [:]

        var waiterCount: Int {
            lock.withLock { waitersByID.count }
        }

        func wait(until deadline: ContinuousClock.Instant) async {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled, ContinuousClock.now < deadline else {
                        continuation.resume()
                        return
                    }

                    lock.lock()
                    guard !didComplete else {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waitersByID[waiterID] = Waiter(
                        continuation: continuation,
                        deadlineTask: nil
                    )
                    lock.unlock()

                    let deadlineTask = Task { [weak self] in
                        try? await Task.sleep(until: deadline, clock: .continuous)
                        guard !Task.isCancelled else { return }
                        self?.resume(waiterID)
                    }
                    lock.lock()
                    if waitersByID[waiterID] != nil {
                        waitersByID[waiterID]?.deadlineTask = deadlineTask
                        lock.unlock()
                    } else {
                        lock.unlock()
                        deadlineTask.cancel()
                    }
                    if Task.isCancelled {
                        resume(waiterID)
                    }
                }
            } onCancel: {
                self.resume(waiterID)
            }
        }

        func wait() async {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume()
                        return
                    }

                    lock.lock()
                    guard !didComplete else {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waitersByID[waiterID] = Waiter(
                        continuation: continuation,
                        deadlineTask: nil
                    )
                    lock.unlock()

                    if Task.isCancelled {
                        resume(waiterID)
                    }
                }
            } onCancel: {
                self.resume(waiterID)
            }
        }

        func resolve() {
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            let waiters = Array(waitersByID.values)
            waitersByID.removeAll()
            lock.unlock()

            for waiter in waiters {
                waiter.deadlineTask?.cancel()
                waiter.continuation.resume()
            }
        }

        private func resume(_ waiterID: UUID) {
            lock.lock()
            let waiter = waitersByID.removeValue(forKey: waiterID)
            lock.unlock()
            waiter?.deadlineTask?.cancel()
            waiter?.continuation.resume()
        }
    }

    private struct CodemapDemandRecord {
        let ticket: WorkspaceCodemapArtifactDemandTicket
        let identity: WorkspaceCodemapArtifactBindingIdentity
        let language: LanguageType
        let owner: WorkspaceCodemapLiveDemandOwner
        let completion: CodemapDemandCompletion
        var retainIDs: Set<UUID>
        var result: WorkspaceCodemapArtifactDemandResult
        var task: Task<Void, Never>?
    }

    private struct CodemapPublishedStructureCapture {
        let request: WorkspaceCodemapPublishedArtifactLookupRequest
        let rootEpoch: WorkspaceCodemapRootEpoch
        let authority: CodemapRootAuthority
        let engine: WorkspaceCodemapBindingEngine
        let logicalPath: WorkspaceCodemapLogicalPresentationPath
    }

    private enum CodemapWarmPublishedMarkerReplayDisposition {
        case applied
        case alreadyCurrent
        case stale
    }

    private struct CodemapPresentationRecord {
        let id: WorkspaceCodemapFrozenPresentationBundleID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let entries: [WorkspaceCodemapFrozenPresentationEntry]
        let handles: [WorkspaceCodemapLiveFrozenArtifactHandle]
        let requestIDs: Set<UUID>
    }

    private final class CodemapSharedTaskDeadlineRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resolve(_ value: Bool) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    private struct CodemapRootSession {
        let authority: CodemapRootAuthority
        var endpoint: WorkspaceCodemapBindingIntegrationEndpoint?
        var routeToken: WorkspaceCodemapBindingIntegrationRouteToken?
        var runtime: CodeMapArtifactRuntime?
        var engine: WorkspaceCodemapBindingEngine?
        var setupTask: Task<CodemapSetupDisposition, Never>?
        var setupDisposition: CodemapSetupDisposition?
        var pathGenerationsByRelativePath: [String: UInt64] = [:]
        var markerReadinessByFileID: [UUID: WorkspaceCodemapMarkerReadinessChange] = [:]
        var markerReadinessRevision: UInt64 = 0
        var demandsByFileID: [UUID: CodemapDemandRecord] = [:]
        var bundlesByRequestID: [UUID: WorkspaceCodemapLiveOverlayBundle] = [:]
        var presentationRecordsByID: [
            WorkspaceCodemapFrozenPresentationBundleID: CodemapPresentationRecord
        ] = [:]
        var graphStatusTask: Task<Void, Never>?
        var graphWorkerRecoveryStatusTask: Task<Void, Never>?
        var selectionGraph: WorkspaceCodemapSelectionGraph?
    }

    private struct DetachedCodemapSession: @unchecked Sendable {
        let authority: CodemapRootAuthority
        let registry: WorkspaceCodemapBindingIntegrationRegistry?
        let routeToken: WorkspaceCodemapBindingIntegrationRouteToken?
        let engine: WorkspaceCodemapBindingEngine?
        let owners: [WorkspaceCodemapLiveDemandOwner]
        let setupTask: Task<CodemapSetupDisposition, Never>?
        let demandTasks: [Task<Void, Never>]
        let graphStatusTask: Task<Void, Never>?
        let graphWorkerRecoveryStatusTask: Task<Void, Never>?
        let selectionGraph: WorkspaceCodemapSelectionGraph?
        let preloadLaunchTask: Task<Void, Never>?
        let eligibilityTask: Task<CodemapEligibilityResolution, Never>?
        let graphIndexRetryTask: Task<Void, Never>?
        let predecessorTasks: [Task<Void, Never>]
        let invalidationCommands: [CodemapInvalidationCommand]
        let graphInvalidationReason: WorkspaceCodemapGraphRevocationReason
    }

    private struct CodemapPathFenceToken: Hashable {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let standardizedRelativePaths: Set<String>
        let shouldRescheduleGraphIndex: Bool
    }

    private struct CodemapRootMutationFenceToken: Hashable {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
    }

    enum CodemapPathInvalidationStage: String, CaseIterable {
        case rootMutationFence = "root_mutation_fence"
        case cleanupFlight = "cleanup_flight"
        case predecessorFlight = "predecessor_flight"
        case graphContributionFence = "graph_contribution_fence"
        case setup
        case engineInvalidation = "engine_invalidation"
        case completionPublication = "completion_publication"
    }

    private struct CodemapPathInvalidationFlight {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let task: Task<Void, Never>
    }

    private struct CodemapCleanupFlight {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let task: Task<Void, Never>
    }

    private struct DetachedWatcherStop {
        let index: Int
        let rootID: UUID
        let rootPath: String
        let completionLatch: WorkspaceRootUnloadCompletionLatch
        let task: Task<Void, Never>
    }

    private struct RootLoadConfiguration: Hashable {
        let kind: WorkspaceRootKind
        let gitignorePolicyIdentity: WorkspaceGitignorePolicyIdentity
        let respectRepoIgnore: Bool
        let respectCursorignore: Bool
        let skipSymlinks: Bool
        let enableHierarchicalIgnores: Bool
    }

    private struct RootLoadCompletionIdentity {
        let rootID: UUID
        let lifetimeID: UUID
    }

    private final class RootLoadFlightCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var completionIdentity: RootLoadCompletionIdentity?

        func record(rootID: UUID, lifetimeID: UUID) {
            lock.lock()
            completionIdentity = RootLoadCompletionIdentity(
                rootID: rootID,
                lifetimeID: lifetimeID
            )
            lock.unlock()
        }

        func identity() -> RootLoadCompletionIdentity? {
            lock.lock()
            let identity = completionIdentity
            lock.unlock()
            return identity
        }
    }

    private struct RootLoadFlight {
        let id: UUID
        let task: Task<WorkspaceRootRecord, Error>
        let completion: RootLoadFlightCompletion
    }

    private struct SessionWorktreeRootLifetimeKey: Hashable {
        let rootID: UUID
        let lifetimeID: UUID
    }

    private struct WatcherInfrastructureKey: Hashable {
        let rootID: UUID
        let lifetimeID: UUID
    }

    private struct WatcherPublisherAttachment {
        let subscription: WorkspaceFileSystemIngressCoordinator.Subscription
        let cancellable: AnyCancellable
    }

    private struct WatcherInfrastructureFlight {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct SessionWorktreeOwnershipRecord {
        let bindingFingerprint: String
        let roots: [WorkspaceSessionWorktreeOwnedRoot]
        let pendingSeededRootIDs: [WorkspacePendingSeededRootID]
    }

    private struct SessionWorktreeReservedLoadFlight {
        let ownerID: UUID
        let standardizedPath: String
        let flight: RootLoadFlight
    }

    #if DEBUG
        private struct SessionWorktreeOrphanLoadCleanup {
            let ownerID: UUID
            let standardizedPath: String
            let task: Task<Void, Never>
        }
    #endif

    private struct SessionWorktreeOwnershipRemoval {
        var ownedRoots: [WorkspaceSessionWorktreeOwnedRoot] = []
        var reservedLoadFlights: [SessionWorktreeReservedLoadFlight] = []
        var pendingSeededRootIDs: [WorkspacePendingSeededRootID] = []

        mutating func append(_ other: SessionWorktreeOwnershipRemoval) {
            ownedRoots.append(contentsOf: other.ownedRoots)
            reservedLoadFlights.append(contentsOf: other.reservedLoadFlights)
            pendingSeededRootIDs.append(contentsOf: other.pendingSeededRootIDs)
        }
    }

    private final class RootLoadTaskWaitRace: @unchecked Sendable {
        private let lock = NSLock()
        private var resolution: Result<WorkspaceRootRecord, Error>?
        private var continuation: CheckedContinuation<WorkspaceRootRecord, Error>?

        func value() async throws -> WorkspaceRootRecord {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let resolution {
                    lock.unlock()
                    continuation.resume(with: resolution)
                } else {
                    precondition(self.continuation == nil)
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func resolve(_ resolution: Result<WorkspaceRootRecord, Error>) {
            let continuation: CheckedContinuation<WorkspaceRootRecord, Error>?
            lock.lock()
            guard self.resolution == nil else {
                lock.unlock()
                return
            }
            self.resolution = resolution
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: resolution)
        }

        func cancel() {
            resolve(.failure(CancellationError()))
        }
    }

    private final class WatcherInfrastructureTaskWaitRace: @unchecked Sendable {
        private let lock = NSLock()
        private var resolution: Result<Void, Error>?
        private var continuation: CheckedContinuation<Void, Error>?

        func value() async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let resolution {
                    lock.unlock()
                    continuation.resume(with: resolution)
                } else {
                    precondition(self.continuation == nil)
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func resolve(_ resolution: Result<Void, Error>) {
            let continuation: CheckedContinuation<Void, Error>?
            lock.lock()
            guard self.resolution == nil else {
                lock.unlock()
                return
            }
            self.resolution = resolution
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: resolution)
        }

        func cancel() {
            resolve(.failure(CancellationError()))
        }
    }

    private struct SliceRebaseSourceCacheKey: Hashable {
        let rootID: UUID
        let rootLifetimeID: UUID
        let fileID: UUID
        let relativePath: String
    }

    private struct SliceRebaseSourceCacheEntry {
        let snapshot: WorkspaceSliceRebaseSourceSnapshot
        let byteCost: Int
        var accessOrdinal: UInt64
    }

    private enum CatalogInvalidationReason: String, Hashable {
        case fileSystemPublication = "file_system_publication"
        case rootLoad = "root_load"
        case rootUnload = "root_unload"
        case explicitMaterialization = "explicit_materialization"
        case managedFilePromotion = "managed_file_promotion"
        case catalogMutation = "catalog_mutation"
        case cacheCapacity = "cache_capacity"
    }

    private final class PublicationInvalidationBatch {
        var topologyInvalidationRequested = false
        var affectedRootKinds = Set<WorkspaceRootKind>()
        var affectedRootIDs = Set<UUID>()
        var reasons = Set<CatalogInvalidationReason>()
        var searchContentInvalidations = WorkspaceSearchContentInvalidationBatch()
    }

    private struct ScopedIngressBarrierTarget {
        let watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
        let acceptedServicePublicationSequence: UInt64

        func covers(_ other: ScopedIngressBarrierTarget) -> Bool {
            watcherAcceptedWatermark >= other.watcherAcceptedWatermark
                && acceptedServicePublicationSequence >= other.acceptedServicePublicationSequence
        }

        func merging(_ other: ScopedIngressBarrierTarget) -> ScopedIngressBarrierTarget {
            ScopedIngressBarrierTarget(
                watcherAcceptedWatermark: max(watcherAcceptedWatermark, other.watcherAcceptedWatermark),
                acceptedServicePublicationSequence: max(
                    acceptedServicePublicationSequence,
                    other.acceptedServicePublicationSequence
                )
            )
        }
    }

    private struct ScopedIngressBarrierCompletedCut {
        let target: ScopedIngressBarrierTarget
        let sample: WorkspaceIngressBarrierSample
    }

    #if DEBUG
        private struct ScopedIngressBarrierTaskOutput {
            let sample: WorkspaceIngressBarrierSample
            let completedAtNanoseconds: UInt64
        }
    #else
        private typealias ScopedIngressBarrierTaskOutput = WorkspaceIngressBarrierSample
    #endif

    private final class ScopedIngressBarrierJoin: @unchecked Sendable {
        private let lock = NSLock()
        private var isCompleted = false
        private var completedOutput: ScopedIngressBarrierTaskOutput?
        private var waiters: [UUID: CheckedContinuation<ScopedIngressBarrierTaskOutput?, Never>] = [:]

        func value() async -> ScopedIngressBarrierTaskOutput? {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else if isCompleted {
                        let output = completedOutput
                        lock.unlock()
                        continuation.resume(returning: output)
                    } else {
                        waiters[waiterID] = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                cancelWaiter(id: waiterID)
            }
        }

        func complete(with output: ScopedIngressBarrierTaskOutput?) {
            let continuations: [CheckedContinuation<ScopedIngressBarrierTaskOutput?, Never>]
            lock.lock()
            guard !isCompleted else {
                lock.unlock()
                return
            }
            isCompleted = true
            completedOutput = output
            continuations = Array(waiters.values)
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            continuations.forEach { $0.resume(returning: output) }
        }

        private func cancelWaiter(id waiterID: UUID) {
            let continuation: CheckedContinuation<ScopedIngressBarrierTaskOutput?, Never>?
            lock.lock()
            continuation = waiters.removeValue(forKey: waiterID)
            lock.unlock()
            continuation?.resume(returning: nil)
        }
    }

    private final class AppliedIngressTimeoutRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[WorkspaceIngressBarrierSample], Error>?
        private var pendingResult: Result<[WorkspaceIngressBarrierSample], Error>?
        private var operationTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var isResolved = false

        func install(continuation: CheckedContinuation<[WorkspaceIngressBarrierSample], Error>) {
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(with: pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func install(operationTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
            lock.lock()
            if isResolved {
                lock.unlock()
                operationTask.cancel()
                timeoutTask.cancel()
                return
            }
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }

        func resolve(_ result: Result<[WorkspaceIngressBarrierSample], Error>) {
            lock.lock()
            guard !isResolved else {
                lock.unlock()
                return
            }
            isResolved = true
            let continuation = continuation
            self.continuation = nil
            if continuation == nil {
                pendingResult = result
            }
            let operationTask = operationTask
            let timeoutTask = timeoutTask
            self.operationTask = nil
            self.timeoutTask = nil
            lock.unlock()

            operationTask?.cancel()
            timeoutTask?.cancel()
            continuation?.resume(with: result)
        }
    }

    private final class ScopedIngressBarrierFlight {
        let token: UInt64
        let target: ScopedIngressBarrierTarget
        let join: ScopedIngressBarrierJoin
        var task: Task<Void, Never>?
        #if DEBUG
            let startedAtNanoseconds: UInt64
        #endif

        init(
            token: UInt64,
            target: ScopedIngressBarrierTarget,
            join: ScopedIngressBarrierJoin,
            startedAtNanoseconds: UInt64 = 0
        ) {
            self.token = token
            self.target = target
            self.join = join
            #if DEBUG
                self.startedAtNanoseconds = startedAtNanoseconds
            #endif
        }
    }

    private final class ScopedIngressBarrierPendingFlight {
        var target: ScopedIngressBarrierTarget
        let join: ScopedIngressBarrierJoin
        #if DEBUG
            let enqueuedAtNanoseconds: UInt64
        #endif

        init(
            target: ScopedIngressBarrierTarget,
            join: ScopedIngressBarrierJoin,
            enqueuedAtNanoseconds: UInt64 = 0
        ) {
            self.target = target
            self.join = join
            #if DEBUG
                self.enqueuedAtNanoseconds = enqueuedAtNanoseconds
            #endif
        }
    }

    private final class ScopedIngressBarrierRootFlightState {
        var active: ScopedIngressBarrierFlight?
        var pending: ScopedIngressBarrierPendingFlight?

        init(
            active: ScopedIngressBarrierFlight? = nil,
            pending: ScopedIngressBarrierPendingFlight? = nil
        ) {
            self.active = active
            self.pending = pending
        }
    }

    #if DEBUG
        struct ScopedIngressBarrierStats: Equatable {
            let launchCount: Int
            let joinCount: Int
            let successorCount: Int
            let coalescedSuccessorCount: Int
            let noopCount: Int
        }

        struct ScopedIngressBarrierDebugSnapshot: Equatable {
            struct Active: Equatable {
                let targetWatcherWatermark: UInt64
                let targetServicePublicationSequence: UInt64
                let ageMilliseconds: UInt64
            }

            struct Pending: Equatable {
                let targetWatcherWatermark: UInt64
                let targetServicePublicationSequence: UInt64
                let ageMilliseconds: UInt64
            }

            struct Completed: Equatable {
                let token: UInt64
                let targetWatcherWatermark: UInt64
                let targetServicePublicationSequence: UInt64
                let publishedServicePublicationSequence: UInt64
                let appliedServicePublicationSequence: UInt64
                let appliedWatcherWatermark: UInt64
                let durationMilliseconds: UInt64
            }

            let launchCount: Int
            let joinCount: Int
            let successorCount: Int
            let coalescedSuccessorCount: Int
            let completionCount: Int
            let noopCount: Int
            let totalWaitMilliseconds: UInt64
            let maxWaitMilliseconds: UInt64
            let active: Active?
            let pending: Pending?
            let lastCompleted: Completed?
        }

        struct PublicationInvalidationDebugSample: Equatable {
            let servicePublicationSequence: UInt64
            let watcherAcceptedWatermark: UInt64?
            let preparedDeltaCount: Int
            let topologyInvalidationCount: Int
            let catalogGenerationAdvanceCount: Int
            let searchCatalogCacheClearCount: Int
            let pathWorkerInvalidationRequestCount: Int
            let contentInvalidationCount: Int
            let distinctContentKeyCount: Int
            let decodedCacheInvalidationRequestCount: Int
            let codemapInvalidationRequestCount: Int
            let appliedIndexEventYieldCount: Int
        }

        struct PublicationInvalidationHistoryDebugSnapshot: Equatable {
            let retainedSampleLimit: Int
            let totalObservedPublicationCount: Int
            let droppedPublicationSampleCount: Int
            let samples: [PublicationInvalidationDebugSample]
        }

        struct CatalogInvalidationDebugEvent: Equatable {
            let sequence: UInt64
            let reasons: [String]
            let affectedRootIDs: [UUID]
            let affectedRootKinds: [String]
            let evictedScopes: [String]
        }

        struct CatalogRebuildDebugSnapshot: Equatable {
            let rebuildCount: Int
            let filterMicroseconds: UInt64
            let sortMicroseconds: UInt64
            let fileSortMicroseconds: UInt64
            let folderSortMicroseconds: UInt64
            let sortResidualMicroseconds: UInt64
            let sortReconciliationDeltaMicroseconds: Int64
            let sortInvocationCount: Int
            let sortFileInputCount: Int
            let sortFolderInputCount: Int
            let materializationMicroseconds: UInt64
            let pathIndexKeyMicroseconds: UInt64
            let pathIndexConstructionMicroseconds: UInt64
            let compositionCacheResidualMicroseconds: UInt64
            let totalMicroseconds: UInt64
            let lastFileCount: Int
            let lastRootCount: Int
        }

    #endif

    #if DEBUG
        private var rootLoadWillStartHandler: (@Sendable (String) async -> Void)?
        private var sessionWorktreeDrainDidEnterLoadFlightWaitHandler: (@Sendable () -> Void)?
        private var sessionWorktreeDrainLoadFlightWaiterCount = 0
        private var rootLoadDidJoinInFlightHandler: (@Sendable (String) async -> Void)?
        private var rootUnloadDidDetachHandler: (@Sendable ([String]) async -> Void)?
        private var ensureIndexedFilesEligibilityDidResolveHandler: (@Sendable (UUID, String) async -> Void)?
        private var contextBuilderSelectionCandidateEligibilityDidResolveHandler: (@Sendable (UUID) async -> Void)?
        private var publishedGitArtifactIngressDidRegisterHandler: (@Sendable (UUID, String) async -> Void)?
        private var watcherSinkWillApplyHandler: (@Sendable (UUID) async -> Void)?
        private var storeEditDeferredPublicationDidRegisterHandler: (@Sendable (UUID, String) async -> Void)?
        private var publisherIngressWillWaitHandler: (@Sendable (Set<UUID>) async -> Void)?
        private var watcherPublisherIngressDidOpenHandler: (@Sendable (UUID, UUID) async -> Void)?
        private var watcherInfrastructureDidJoinFlightHandler: (@Sendable (UUID, UUID) async -> Void)?
        private var watcherServiceStateWillReconcileHandler: (@Sendable (UUID, Bool) async -> Void)?
        private var watcherStopWillBeginHandler: (@Sendable (UUID) async -> Void)?
        private var rootUnloadTerminationDidCompleteHandler: (@Sendable (WorkspaceRootUnloadTerminationDiagnostics) async -> Void)?
        private var appliedIngressDidCaptureWatermarksHandler: (@Sendable ([UUID: UInt64]) async -> Void)?
        private var scopedIngressBarrierWillFlushHandler: (@Sendable (UUID) async -> Void)?
        private var watcherActivationFailurePointForNewServicesForTesting: FileSystemService.WatcherActivationFailurePoint?
        private var seededShardPreparationShouldFailForTesting = false
        private var pendingSeededRootDidBecomeReadyHandler: (@Sendable (String) async -> Void)?
        private var pendingSeededRootDidActivateHandler: (@Sendable (String) async -> Void)?
        private var seededPublicationActivationShouldFailForTesting = false
        private var publishedSeededAuthorityFullCrawlCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierLaunchCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierJoinCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierSuccessorCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierCoalescedSuccessorCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierCompletionCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierNoopCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierTotalWaitMillisecondsByRootID: [UUID: UInt64] = [:]
        private var scopedIngressBarrierMaxWaitMillisecondsByRootID: [UUID: UInt64] = [:]
        private var lastCompletedScopedIngressBarrierByRootID: [UUID: ScopedIngressBarrierDebugSnapshot.Completed] = [:]
        private var publicationInvalidationHistoryByRootID: [UUID: PublicationInvalidationHistoryState] = [:]
        private var rootCrawlCountsByRootID: [UUID: Int] = [:]
        private var nextCatalogInvalidationSequence: UInt64 = 0
        private var catalogInvalidationHistory: [CatalogInvalidationDebugEvent] = []
        private var catalogRebuildCount = 0
        private var catalogRebuildFilterMicroseconds: UInt64 = 0
        private var catalogRebuildSortMicroseconds: UInt64 = 0
        private var catalogRebuildFileSortMicroseconds: UInt64 = 0
        private var catalogRebuildFolderSortMicroseconds: UInt64 = 0
        private var catalogRebuildSortResidualMicroseconds: UInt64 = 0
        private var catalogRebuildSortReconciliationDeltaMicroseconds: Int64 = 0
        private var catalogRebuildSortInvocationCount = 0
        private var catalogRebuildSortFileInputCount = 0
        private var catalogRebuildSortFolderInputCount = 0
        private var catalogRebuildMaterializationMicroseconds: UInt64 = 0
        private var catalogRebuildPathIndexKeyMicroseconds: UInt64 = 0
        private var catalogRebuildPathIndexConstructionMicroseconds: UInt64 = 0
        private var catalogRebuildCompositionCacheResidualMicroseconds: UInt64 = 0
        private var catalogRebuildTotalMicroseconds: UInt64 = 0
        private var catalogRebuildLastFileCount = 0
        private var catalogRebuildLastRootCount = 0
        private var rootCatalogShardBuildCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardFullPathIndexBuildCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardOverlayPathIndexBuildCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardPatchCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardAuthoritativeRebuildCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardFallbackCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardFallbackReasonCountsByRootID: [UUID: [RootCatalogShardFallbackReason: Int]] = [:]
        private var rootCatalogShardFallbackLifetimeIDsByRootID: [UUID: UUID] = [:]
        private var rootCatalogShardBackstopCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardMaxLiveGenerationCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardSingleShardCompositionReuseCount = 0
        private var rootCatalogShardGenericMergeElementVisitCount = 0
        private var rootCatalogShardShadowComparisonCount = 0
        private var rootCatalogShardShadowMismatchCount = 0
        private var rootCatalogShardLastShadowByteCount = 0

        func setCodemapGraphIndexBuildStartHandlerForTesting(
            _ handler: (@Sendable (WorkspaceCodemapRootEpoch) async -> Void)?
        ) {
            codemapGraphIndexBuildStartHandler = handler
        }

        func setCodemapGraphIndexCatalogBuildHandlerForTesting(
            _ handler: (@Sendable (WorkspaceCodemapRootEpoch) async -> Void)?
        ) {
            codemapGraphIndexCatalogBuildHandler = handler
        }

        func codemapGraphIndexBuildStoreEventsForTesting(
            rootID: UUID? = nil
        ) -> [CodemapGraphIndexBuildStoreEvent] {
            codemapGraphIndexBuildStoreEvents.filter { event in
                rootID.map { event.rootEpoch.rootID == $0 } ?? true
            }
        }

        func debugCodemapGraphIndexStoreEvents(
            rootID: UUID? = nil,
            sinceOrdinal: UInt64?,
            limit: Int
        ) -> CodemapGraphStatusStoreEventPage {
            let rootEvents = codemapGraphIndexBuildStoreEvents.filter { event in
                rootID.map { event.rootEpoch.rootID == $0 } ?? true
            }
            let events = Array(rootEvents.lazy.filter { event in
                sinceOrdinal.map { event.ordinal > $0 } ?? true
            }.prefix(min(max(0, limit), 1024)).map { event in
                CodemapGraphStatusStoreEventSnapshot(
                    ordinal: event.ordinal,
                    rootEpoch: event.rootEpoch,
                    kind: event.kind.rawValue,
                    launchPhase: CodemapFullLoadDebugSupport.launchPhaseName(event.launchPhase),
                    uptimeNanoseconds: event.uptimeNanoseconds
                )
            })
            return CodemapGraphStatusStoreEventPage(
                firstOrdinal: rootEvents.first?.ordinal ?? 0,
                lastOrdinal: rootEvents.last?.ordinal ?? 0,
                nextOrdinal: events.last?.ordinal,
                events: events
            )
        }

        func codemapGraphIndexBuildLaunchPhaseForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> WorkspaceCodemapGraphIndexLaunchPhase? {
            codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch]?.phase
        }

        func codemapEligibilityFlightCountForTesting() -> Int {
            codemapEligibilityFlightsByRootEpoch.count
        }

        func codemapGraphIndexBuildRetrySnapshotForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> (attempt: Int, deadlineNanoseconds: UInt64)? {
            codemapGraphIndexBuildRetriesByRootEpoch[rootEpoch].map {
                (attempt: $0.attempt, deadlineNanoseconds: $0.deadlineNanoseconds)
            }
        }

        func codemapGraphIndexRetryExhaustionForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> (attempt: Int, uptimeNanoseconds: UInt64)? {
            codemapGraphIndexRetryExhaustionByRootEpoch[rootEpoch].map {
                (attempt: $0.attempt, uptimeNanoseconds: $0.uptimeNanoseconds)
            }
        }

        func debugAcquireCodemapGraphIndexAdmissionHold(
            rootID: UUID,
            expiresAfterMilliseconds: UInt64
        ) async -> (
            holdID: UUID,
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        )? {
            guard let owner = debugCodemapBindingEngine(rootID: rootID),
                  let acquired = await owner.engine.debugAcquireGraphIndexAdmissionHold(
                      rootEpoch: owner.rootEpoch,
                      expiresAfterMilliseconds: expiresAfterMilliseconds
                  )
            else { return nil }
            debugCodemapGraphIndexHoldOwners[acquired.holdID] = owner
            debugCodemapGraphIndexHoldExpiryTasks[acquired.holdID] = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: (expiresAfterMilliseconds + 1000) * 1_000_000
                )
                guard !Task.isCancelled else { return }
                await self?.debugForgetCodemapGraphIndexAdmissionHold(acquired.holdID)
            }
            return acquired
        }

        func debugReleaseCodemapGraphIndexAdmissionHold(
            rootID: UUID,
            holdID: UUID
        ) async -> (
            released: Bool,
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        )? {
            let owner: (rootEpoch: WorkspaceCodemapRootEpoch, engine: WorkspaceCodemapBindingEngine)
            if let retained = debugCodemapGraphIndexHoldOwners[holdID] {
                guard retained.rootEpoch.rootID == rootID else { return nil }
                owner = retained
            } else {
                guard let current = debugCodemapBindingEngine(rootID: rootID) else { return nil }
                owner = current
            }
            let released = await owner.engine.debugReleaseGraphIndexAdmissionHold(
                holdID,
                rootEpoch: owner.rootEpoch
            )
            debugCodemapGraphIndexHoldOwners.removeValue(forKey: holdID)
            debugCodemapGraphIndexHoldExpiryTasks.removeValue(forKey: holdID)?.cancel()
            return released
        }

        func debugCodemapGraphIndexAdmissionSnapshot(
            rootID: UUID
        ) async -> (
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        )? {
            guard let owner = debugCodemapBindingEngine(rootID: rootID) else { return nil }
            return await owner.engine.debugGraphIndexAdmissionSnapshot(rootEpoch: owner.rootEpoch)
        }

        private struct DebugCodemapFullLoadCapture {
            let rootEpoch: WorkspaceCodemapRootEpoch
            let catalogGeneration: UInt64
            let ingressGeneration: UInt64
            let rootKind: WorkspaceRootKind
            let launchPhase: WorkspaceCodemapGraphIndexLaunchPhase?
            let terminalReason: WorkspaceCodemapGitTerminalUnavailableReason?
            let engine: WorkspaceCodemapBindingEngine?
            let milestones: [CodemapFullLoadMilestone]

            var identity: CodemapFullLoadRootIdentity {
                CodemapFullLoadRootIdentity(
                    rootEpoch: rootEpoch,
                    catalogGeneration: catalogGeneration,
                    ingressGeneration: ingressGeneration,
                    engineIdentity: engine.map(ObjectIdentifier.init)
                )
            }
        }

        private struct DebugCodemapFullLoadEngineObservation {
            let graph: WorkspaceCodemapGraphIncrementalAccounting?
            let accounting: WorkspaceCodemapBindingEngineAccounting?
            let queueWaitMilliseconds: [UInt64]
        }

        func debugCodemapGraphStatusSnapshot(
            rootID: UUID? = nil,
            includeEvents: Bool = false,
            sinceStoreOrdinal: UInt64? = nil,
            sinceEngineOrdinal: UInt64? = nil,
            eventLimit: Int = 256
        ) async -> CodemapGraphStatusSnapshot {
            let captures = rootsForPathLookup(scope: .visibleWorkspace)
                .filter { root in rootID.map { $0 == root.id } ?? true }
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .compactMap { root -> (
                    rootEpoch: WorkspaceCodemapRootEpoch,
                    rootKind: WorkspaceRootKind,
                    catalogGeneration: UInt64,
                    ingressGeneration: UInt64,
                    eligibilityFlightPresent: Bool,
                    launch: CodemapGraphStatusLaunchSnapshot?,
                    engine: WorkspaceCodemapBindingEngine?
                )? in
                    guard let state = rootStatesByID[root.id] else { return nil }
                    let rootEpoch = WorkspaceCodemapRootEpoch(
                        rootID: root.id,
                        rootLifetimeID: state.lifetimeID
                    )
                    let session = codemapSessionsByRootEpoch[rootEpoch]
                    let launch = codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch]
                    let retry = codemapGraphIndexBuildRetriesByRootEpoch[rootEpoch]
                    let exhaustion = codemapGraphIndexRetryExhaustionByRootEpoch[rootEpoch]
                    let authority = session?.authority
                        ?? launch?.authority
                        ?? codemapEligibilityFlightsByRootEpoch[rootEpoch]?.authority
                        ?? codemapCompletedEligibilityByRootEpoch[rootEpoch]?.authority
                        ?? retry?.authority
                    let launchSnapshot = launch.map {
                        CodemapGraphStatusLaunchSnapshot(
                            id: $0.id,
                            phase: $0.phase,
                            retryAttempt: $0.retryAttempt,
                            taskPresent: $0.task != nil,
                            createdUptimeNanoseconds: $0.createdUptimeNanoseconds,
                            phaseEnteredUptimeNanoseconds: $0.phaseEnteredUptimeNanoseconds,
                            retry: retry.map {
                                CodemapGraphStatusRetrySnapshot(
                                    attempt: $0.attempt,
                                    deadlineUptimeNanoseconds: $0.deadlineNanoseconds
                                )
                            },
                            retryExhaustion: exhaustion.map {
                                CodemapGraphStatusRetryExhaustionSnapshot(
                                    attempt: $0.attempt,
                                    uptimeNanoseconds: $0.uptimeNanoseconds
                                )
                            }
                        )
                    }
                    return (
                        rootEpoch: rootEpoch,
                        rootKind: root.kind,
                        catalogGeneration: authority?.catalogGeneration
                            ?? catalogGenerationsByRootID[root.id]
                            ?? 0,
                        ingressGeneration: authority?.ingressGeneration
                            ?? codemapAuthorityGenerationsByRootEpoch[rootEpoch]
                            ?? 0,
                        eligibilityFlightPresent: codemapEligibilityFlightsByRootEpoch[rootEpoch] != nil,
                        launch: launchSnapshot,
                        engine: session?.engine
                    )
                }

            var accountingByEngine: [ObjectIdentifier: WorkspaceCodemapBindingEngineAccounting] = [:]
            var roots: [CodemapGraphStatusRootSnapshot] = []
            for capture in captures {
                let accounting: WorkspaceCodemapBindingEngineAccounting?
                let admission: CodemapGraphStatusAdmissionSnapshot?
                let manifest: CodemapGraphStatusManifestSnapshot?
                let engineEvents: WorkspaceCodemapGraphIndexDebugEventPage?
                if let engine = capture.engine {
                    let identity = ObjectIdentifier(engine)
                    if let existing = accountingByEngine[identity] {
                        accounting = existing
                    } else {
                        let observed = await engine.accounting()
                        accountingByEngine[identity] = observed
                        accounting = observed
                    }
                    let observedAdmission = await engine.debugGraphIndexAdmissionSnapshot(
                        rootEpoch: capture.rootEpoch
                    )
                    admission = CodemapGraphStatusAdmissionSnapshot(
                        metrics: observedAdmission.metrics,
                        queueWaitMilliseconds: observedAdmission.queueWaitMilliseconds
                    )
                    let observedManifest = await engine.debugManifestFailureSnapshot(
                        rootEpoch: capture.rootEpoch
                    )
                    let observedManifestMeasurements = await engine.debugManifestMeasurementSnapshot(
                        rootEpoch: capture.rootEpoch
                    )
                    manifest = CodemapGraphStatusManifestSnapshot(
                        failureCounts: observedManifest.counts,
                        lastFailure: observedManifest.lastFailure,
                        measurements: observedManifestMeasurements
                    )
                    engineEvents = includeEvents
                        ? await engine.debugGraphIndexEvents(
                            rootID: capture.rootEpoch.rootID,
                            sinceOrdinal: sinceEngineOrdinal,
                            limit: eventLimit
                        )
                        : nil
                } else {
                    accounting = nil
                    admission = nil
                    manifest = nil
                    engineEvents = nil
                }
                let milestones = codemapGraphIndexBuildStoreEvents
                    .filter { $0.rootEpoch == capture.rootEpoch }
                    .map {
                        CodemapGraphStatusStoreEventSnapshot(
                            ordinal: $0.ordinal,
                            rootEpoch: $0.rootEpoch,
                            kind: $0.kind.rawValue,
                            launchPhase: CodemapFullLoadDebugSupport.launchPhaseName($0.launchPhase),
                            uptimeNanoseconds: $0.uptimeNanoseconds
                        )
                    }
                roots.append(CodemapGraphStatusRootSnapshot(
                    rootEpoch: capture.rootEpoch,
                    catalogGeneration: capture.catalogGeneration,
                    ingressGeneration: capture.ingressGeneration,
                    rootKind: capture.rootKind,
                    eligibilityFlightPresent: capture.eligibilityFlightPresent,
                    launch: capture.launch,
                    job: accounting?.graphIndexRoots.first { $0.rootEpoch == capture.rootEpoch },
                    admission: admission,
                    manifest: manifest,
                    milestones: milestones,
                    engineEvents: engineEvents
                ))
            }
            let accountings = Array(accountingByEngine.values)
            return CodemapGraphStatusSnapshot(
                sampledUptimeNanoseconds: codemapGraphIndexBuildRetryPolicy.nowNanoseconds(),
                roots: roots,
                storeEvents: includeEvents
                    ? debugCodemapGraphIndexStoreEvents(
                        rootID: rootID,
                        sinceOrdinal: sinceStoreOrdinal,
                        limit: eventLimit
                    )
                    : nil,
                graphIndexJobCount: accountings.reduce(0) { $0 + $1.graphIndexJobCount },
                queuedGraphIndexBatchCount: accountings.reduce(0) {
                    $0 + $1.queuedGraphIndexBatchCount
                },
                activeGraphIndexBatchCount: accountings.reduce(0) {
                    $0 + $1.activeGraphIndexBatchCount
                },
                drainingGraphIndexTaskCount: accountings.reduce(0) {
                    $0 + $1.drainingGraphIndexTaskCount
                }
            )
        }

        func debugCodemapFullLoadAggregateSnapshot(
            expectedWorkspaceID: UUID
        ) async -> CodemapFullLoadAggregateSnapshot {
            let initial = debugCaptureCodemapFullLoadUniverse()
            let sampled = DispatchTime.now().uptimeNanoseconds
            guard !initial.isEmpty else {
                return CodemapFullLoadAggregateSnapshot(
                    expectedWorkspaceID: expectedWorkspaceID,
                    state: .incompleteDiagnostics,
                    sampledUptimeNanoseconds: sampled,
                    visibleRootCount: 0,
                    eligibleRootCount: 0,
                    readyRootCount: 0,
                    terminalIneligibleRootCount: 0,
                    excludedRootCount: 0,
                    pendingRootCount: 0,
                    failedRootCount: 0,
                    supersededRootCount: 0,
                    cohort: "mixed",
                    roots: [],
                    metrics: [:],
                    resources: [:],
                    queueWaitMilliseconds: []
                )
            }

            var observations: [WorkspaceCodemapRootEpoch: DebugCodemapFullLoadEngineObservation] = [:]
            for capture in initial {
                guard let engine = capture.engine else {
                    observations[capture.rootEpoch] = DebugCodemapFullLoadEngineObservation(
                        graph: nil,
                        accounting: nil,
                        queueWaitMilliseconds: []
                    )
                    continue
                }
                let graph = await engine.selectionGraph(rootEpoch: capture.rootEpoch)?.incrementalAccounting()
                let accounting = await engine.accounting()
                let admission = await engine.debugGraphIndexAdmissionSnapshot(rootEpoch: capture.rootEpoch)
                observations[capture.rootEpoch] = DebugCodemapFullLoadEngineObservation(
                    graph: graph,
                    accounting: accounting,
                    queueWaitMilliseconds: admission.queueWaitMilliseconds
                )
            }

            let revalidated = debugCaptureCodemapFullLoadUniverse()
            let universeIsCurrent = CodemapFullLoadDebugSupport.universeMatches(
                initial.map(\.identity),
                revalidated.map(\.identity)
            )
            let roots = initial.map { capture in
                debugCodemapFullLoadRootSnapshot(
                    capture: capture,
                    observation: observations[capture.rootEpoch],
                    universeIsCurrent: universeIsCurrent
                )
            }

            let metrics = roots.reduce(into: [String: UInt64]()) {
                $0 = CodemapFullLoadDebugSupport.adding($0, $1.metrics)
            }
            let resources = roots.reduce(into: [String: UInt64]()) {
                $0 = CodemapFullLoadDebugSupport.adding($0, $1.resources)
            }
            let queueWaitMilliseconds = roots.flatMap(\.queueWaitMilliseconds)
            let proofCount = roots.count(where: { $0.state == .ready })
            let ineligibleCount = roots.count(where: { $0.state == .terminalIneligible })
            let excludedCount = roots.count(where: { $0.state == .excluded })
            let pendingCount = roots.count(where: { $0.state == .pending })
            let failedCount = roots.count(where: { $0.state == .failed })
            let supersededCount = roots.count(where: { $0.state == .superseded })
            let eligibleCount = proofCount + pendingCount + failedCount + supersededCount

            return CodemapFullLoadAggregateSnapshot(
                expectedWorkspaceID: expectedWorkspaceID,
                state: CodemapFullLoadDebugSupport.aggregateState(for: roots),
                sampledUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                visibleRootCount: roots.count,
                eligibleRootCount: eligibleCount,
                readyRootCount: proofCount,
                terminalIneligibleRootCount: ineligibleCount,
                excludedRootCount: excludedCount,
                pendingRootCount: pendingCount,
                failedRootCount: failedCount,
                supersededRootCount: supersededCount,
                cohort: CodemapFullLoadDebugSupport.cohort(metrics: metrics),
                roots: roots,
                metrics: metrics,
                resources: resources,
                queueWaitMilliseconds: queueWaitMilliseconds
            )
        }

        private func debugCaptureCodemapFullLoadUniverse() -> [DebugCodemapFullLoadCapture] {
            rootsForPathLookup(scope: .visibleWorkspace)
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .compactMap { root in
                    guard let state = rootStatesByID[root.id] else { return nil }
                    let rootEpoch = WorkspaceCodemapRootEpoch(
                        rootID: root.id,
                        rootLifetimeID: state.lifetimeID
                    )
                    let session = codemapSessionsByRootEpoch[rootEpoch]
                    let launch = codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch]
                    let completed = codemapCompletedEligibilityByRootEpoch[rootEpoch]
                    let authority = session?.authority
                        ?? launch?.authority
                        ?? codemapEligibilityFlightsByRootEpoch[rootEpoch]?.authority
                        ?? completed?.authority
                        ?? codemapGraphIndexBuildRetriesByRootEpoch[rootEpoch]?.authority
                    let terminalReason: WorkspaceCodemapGitTerminalUnavailableReason? = if case let .terminal(reason, _)? = completed?.result {
                        reason
                    } else {
                        nil
                    }
                    let milestones = codemapGraphIndexBuildStoreEvents
                        .filter { $0.rootEpoch == rootEpoch }
                        .map {
                            CodemapFullLoadMilestone(
                                kind: $0.kind.rawValue,
                                uptimeNanoseconds: $0.uptimeNanoseconds
                            )
                        }
                    return DebugCodemapFullLoadCapture(
                        rootEpoch: rootEpoch,
                        catalogGeneration: authority?.catalogGeneration
                            ?? catalogGenerationsByRootID[root.id]
                            ?? 0,
                        ingressGeneration: authority?.ingressGeneration
                            ?? codemapAuthorityGenerationsByRootEpoch[rootEpoch]
                            ?? 0,
                        rootKind: root.kind,
                        launchPhase: launch?.phase,
                        terminalReason: terminalReason,
                        engine: session?.engine,
                        milestones: milestones
                    )
                }
        }

        private func debugCodemapFullLoadRootSnapshot(
            capture: DebugCodemapFullLoadCapture,
            observation: DebugCodemapFullLoadEngineObservation?,
            universeIsCurrent: Bool
        ) -> CodemapFullLoadRootSnapshot {
            let accounting = observation?.accounting
            let metrics = accounting.map(CodemapFullLoadDebugSupport.metrics) ?? [:]
            let resources = accounting.map(CodemapFullLoadDebugSupport.resources) ?? [:]
            let launchPhase = capture.launchPhase.map(CodemapFullLoadDebugSupport.launchPhaseName)

            guard universeIsCurrent else {
                return CodemapFullLoadRootSnapshot(
                    rootEpoch: capture.rootEpoch,
                    catalogGeneration: capture.catalogGeneration,
                    ingressGeneration: capture.ingressGeneration,
                    rootKind: CodemapFullLoadDebugSupport.rootKindName(capture.rootKind),
                    state: .superseded,
                    reason: "visible_root_universe_or_epoch_changed",
                    launchPhase: launchPhase,
                    graphIndexPhase: nil,
                    supportedCandidateCount: nil,
                    processedCandidateCount: nil,
                    terminalCount: nil,
                    lastGraphChangeSequence: nil,
                    readyUptimeNanoseconds: nil,
                    metrics: metrics,
                    resources: resources,
                    queueWaitMilliseconds: observation?.queueWaitMilliseconds ?? [],
                    milestones: capture.milestones
                )
            }

            var state: CodemapFullLoadRootState = .pending
            var reason: String?
            var graphIndexPhase: String?
            var supportedCandidateCount: UInt64?
            var processedCandidateCount: UInt64?
            var terminalCount: UInt64?
            var lastGraphChangeSequence: UInt64?
            var readyUptimeNanoseconds: UInt64?

            if let terminalReason = capture.terminalReason {
                state = .terminalIneligible
                reason = terminalReason.rawValue
            } else {
                if let graph = observation?.graph {
                    lastGraphChangeSequence = graph.graphRevision
                    if let revoked = graph.revocationReason {
                        state = .superseded
                        reason = "graph_revoked_\(revoked)"
                    } else if let coverage = graph.coverage, coverage.isComplete,
                              graph.appliedGeneration == graph.observedGeneration,
                              !graph.updatesPending,
                              !graph.reconciling
                    {
                        state = .ready
                        graphIndexPhase = "ready"
                        supportedCandidateCount = coverage.supportedCount
                        processedCandidateCount = coverage.classifiedCount
                        terminalCount = coverage.terminalCount
                        readyUptimeNanoseconds = graph.lastCommittedUptimeNanoseconds
                    } else {
                        state = .pending
                        graphIndexPhase = graph.reconciling ? "reconciling" : "indexing"
                        supportedCandidateCount = graph.coverage?.supportedCount
                        processedCandidateCount = graph.coverage?.classifiedCount
                        terminalCount = graph.coverage?.terminalCount
                        reason = graph.updatesPending ? "graph_updates_pending" : nil
                    }
                } else if capture.launchPhase == .handedOff {
                    state = .failed
                    reason = "eligible_root_missing_graph_after_handoff"
                } else if capture.launchPhase == .cancelled || capture.launchPhase == .superseded {
                    state = .failed
                    reason = "graph_index_launch_\(launchPhase ?? "terminal")"
                } else {
                    reason = "awaiting_eligibility_setup_or_graph"
                }
            }

            return CodemapFullLoadRootSnapshot(
                rootEpoch: capture.rootEpoch,
                catalogGeneration: capture.catalogGeneration,
                ingressGeneration: capture.ingressGeneration,
                rootKind: CodemapFullLoadDebugSupport.rootKindName(capture.rootKind),
                state: state,
                reason: reason,
                launchPhase: launchPhase,
                graphIndexPhase: graphIndexPhase,
                supportedCandidateCount: supportedCandidateCount,
                processedCandidateCount: processedCandidateCount,
                terminalCount: terminalCount,
                lastGraphChangeSequence: lastGraphChangeSequence,
                readyUptimeNanoseconds: readyUptimeNanoseconds,
                metrics: metrics,
                resources: resources,
                queueWaitMilliseconds: observation?.queueWaitMilliseconds ?? [],
                milestones: capture.milestones
            )
        }

        func debugCodemapEnginePresent(rootID: UUID) -> Bool {
            debugCodemapBindingEngine(rootID: rootID) != nil
        }

        func codemapBindingEngineAccountingForTesting(
            rootID: UUID
        ) async -> WorkspaceCodemapBindingEngineAccounting? {
            guard let owner = debugCodemapBindingEngine(rootID: rootID) else { return nil }
            return await owner.engine.accounting()
        }

        func debugSetCodemapGraphIndexWorkerRecoveryStateForTesting(
            rootID: UUID,
            state: WorkspaceCodemapGraphIndexWorkerRecoveryState
        ) -> Bool {
            guard let root = rootStatesByID[rootID] else { return false }
            let rootEpoch = WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: root.lifetimeID)
            switch state {
            case .available:
                codemapGraphIndexWorkerRecoveryExhaustedRootEpochs.remove(rootEpoch)
            case .exhausted:
                codemapGraphIndexWorkerRecoveryExhaustedRootEpochs.insert(rootEpoch)
            }
            publishCodemapRootStatusesIfChanged()
            return true
        }

        private func debugCodemapBindingEngine(
            rootID: UUID
        ) -> (rootEpoch: WorkspaceCodemapRootEpoch, engine: WorkspaceCodemapBindingEngine)? {
            let matchingSessions: [(key: WorkspaceCodemapRootEpoch, value: CodemapRootSession)] =
                codemapSessionsByRootEpoch.filter {
                    $0.key.rootID == rootID && $0.value.engine != nil
                }
            let newestSession: (key: WorkspaceCodemapRootEpoch, value: CodemapRootSession)? =
                matchingSessions.max { lhs, rhs in
                    lhs.value.authority.catalogGeneration < rhs.value.authority.catalogGeneration
                }
            guard let newestSession,
                  let engine = newestSession.value.engine
            else { return nil }
            return (newestSession.key, engine)
        }

        private func debugForgetCodemapGraphIndexAdmissionHold(_ holdID: UUID) {
            debugCodemapGraphIndexHoldOwners.removeValue(forKey: holdID)
            debugCodemapGraphIndexHoldExpiryTasks.removeValue(forKey: holdID)
        }

        func setRootLoadWillStartHandler(_ handler: (@Sendable (String) async -> Void)?) {
            rootLoadWillStartHandler = handler
        }

        func setSessionWorktreeDrainDidEnterLoadFlightWaitHandler(
            _ handler: (@Sendable () -> Void)?
        ) {
            sessionWorktreeDrainDidEnterLoadFlightWaitHandler = handler
        }

        func sessionWorktreeDrainLoadFlightWaiterCountForTesting() -> Int {
            sessionWorktreeDrainLoadFlightWaiterCount
        }

        func setRootLoadDidJoinInFlightHandler(_ handler: (@Sendable (String) async -> Void)?) {
            rootLoadDidJoinInFlightHandler = handler
        }

        func setRootUnloadDidDetachHandler(_ handler: (@Sendable ([String]) async -> Void)?) {
            rootUnloadDidDetachHandler = handler
        }

        func setEnsureIndexedFilesEligibilityDidResolveHandler(_ handler: (@Sendable (UUID, String) async -> Void)?) {
            ensureIndexedFilesEligibilityDidResolveHandler = handler
        }

        func setContextBuilderSelectionCandidateEligibilityDidResolveHandler(
            _ handler: (@Sendable (UUID) async -> Void)?
        ) {
            contextBuilderSelectionCandidateEligibilityDidResolveHandler = handler
        }

        func setPublishedGitArtifactIngressDidRegisterHandler(
            _ handler: (@Sendable (UUID, String) async -> Void)?
        ) {
            publishedGitArtifactIngressDidRegisterHandler = handler
        }

        func setWatcherSinkWillApplyHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
            watcherSinkWillApplyHandler = handler
        }

        func setPublisherIngressWillWaitHandler(_ handler: (@Sendable (Set<UUID>) async -> Void)?) {
            publisherIngressWillWaitHandler = handler
        }

        func setWatcherPublisherIngressDidOpenHandler(_ handler: (@Sendable (UUID, UUID) async -> Void)?) {
            watcherPublisherIngressDidOpenHandler = handler
        }

        func setWatcherInfrastructureDidJoinFlightHandler(_ handler: (@Sendable (UUID, UUID) async -> Void)?) {
            watcherInfrastructureDidJoinFlightHandler = handler
        }

        func watcherInfrastructureFlightCountForTesting(rootID: UUID) -> Int {
            watcherInfrastructureFlightsByKey.keys.count(where: { $0.rootID == rootID })
        }

        func setWatcherServiceStateWillReconcileHandler(_ handler: (@Sendable (UUID, Bool) async -> Void)?) {
            watcherServiceStateWillReconcileHandler = handler
        }

        func setWatcherStopWillBeginHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
            watcherStopWillBeginHandler = handler
        }

        func setRootUnloadTerminationDidCompleteHandler(
            _ handler: (@Sendable (WorkspaceRootUnloadTerminationDiagnostics) async -> Void)?
        ) {
            rootUnloadTerminationDidCompleteHandler = handler
        }

        func setAppliedIngressDidCaptureWatermarksHandler(_ handler: (@Sendable ([UUID: UInt64]) async -> Void)?) {
            appliedIngressDidCaptureWatermarksHandler = handler
        }

        func setScopedIngressBarrierWillFlushHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
            scopedIngressBarrierWillFlushHandler = handler
        }

        func setWatcherActivationFailureForNewServicesForTesting(
            _ failurePoint: FileSystemService.WatcherActivationFailurePoint?
        ) {
            watcherActivationFailurePointForNewServicesForTesting = failurePoint
        }

        func setSeededShardPreparationFailureForTesting(_ enabled: Bool) {
            seededShardPreparationShouldFailForTesting = enabled
        }

        func setPendingSeededRootDidBecomeReadyHandler(
            _ handler: (@Sendable (String) async -> Void)?
        ) {
            pendingSeededRootDidBecomeReadyHandler = handler
        }

        func setPendingSeededRootDidActivateHandler(
            _ handler: (@Sendable (String) async -> Void)?
        ) {
            pendingSeededRootDidActivateHandler = handler
        }

        func setSeededPublicationActivationFailureForTesting(_ shouldFail: Bool) {
            seededPublicationActivationShouldFailForTesting = shouldFail
        }

        func handleSeededAuthorityInvalidationForTesting(
            _ event: GitWorkspaceAuthorityInvalidationEvent
        ) {
            handleSeededAuthorityInvalidation(event)
        }

        func publishedSeededAuthoritySnapshotForTesting(
            rootID: UUID
        ) -> PublishedSeededAuthorityDebugSnapshot? {
            guard let state = publishedSeededAuthorityStatesByRootID[rootID] else { return nil }
            return PublishedSeededAuthorityDebugSnapshot(
                epoch: state.epoch,
                isBlocked: state.isBlocked,
                activeMutationDepth: state.activeMutationDepth,
                isReconciling: state.isReconciling,
                reconciliationFailed: state.reconciliationFailed,
                waiterCount: publishedSeededAuthorityWaitersByRootID[rootID]?.count ?? 0,
                fullCrawlCount: publishedSeededAuthorityFullCrawlCountsByRootID[rootID] ?? 0
            )
        }

        func publishedSeededAuthorityIsCurrentForTesting(rootID: UUID) -> Bool {
            publishedSeededAuthorityIsQueryable(rootID: rootID)
        }

        func waitForPublishedSeededAuthorityReconciliationForTesting(rootID: UUID) async {
            while let task = seededAuthorityReconciliationTasksByRootID[rootID] {
                await task.value
            }
        }

        func waitForPublishedSeededAuthorityWaiterForTesting(rootID: UUID) async {
            while publishedSeededAuthorityWaitersByRootID[rootID]?.isEmpty != false {
                await Task.yield()
            }
        }

        func waitForPublishedSeededAuthorityMutationDepthForTesting(
            rootID: UUID,
            atLeast expectedDepth: Int
        ) async {
            while (publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth ?? 0) < expectedDepth {
                await Task.yield()
            }
        }

        func scopedIngressBarrierStatsForTesting(rootID: UUID) -> ScopedIngressBarrierStats {
            ScopedIngressBarrierStats(
                launchCount: scopedIngressBarrierLaunchCountsByRootID[rootID] ?? 0,
                joinCount: scopedIngressBarrierJoinCountsByRootID[rootID] ?? 0,
                successorCount: scopedIngressBarrierSuccessorCountsByRootID[rootID] ?? 0,
                coalescedSuccessorCount: scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID] ?? 0,
                noopCount: scopedIngressBarrierNoopCountsByRootID[rootID] ?? 0
            )
        }

        func scopedIngressBarrierFlightCountForTesting() -> Int {
            scopedIngressBarrierFlightStatesByRootID.values.reduce(0) { count, state in
                count + (state.active == nil ? 0 : 1) + (state.pending == nil ? 0 : 1)
            }
        }

        func resetScopedIngressBarrierDiagnosticsForTesting(rootID: UUID) {
            scopedIngressBarrierLaunchCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierJoinCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierSuccessorCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierCoalescedSuccessorCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierCompletionCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierNoopCountsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierTotalWaitMillisecondsByRootID.removeValue(forKey: rootID)
            scopedIngressBarrierMaxWaitMillisecondsByRootID.removeValue(forKey: rootID)
            lastCompletedScopedIngressBarrierByRootID.removeValue(forKey: rootID)
            completedScopedIngressBarrierCutsByRootID.removeValue(forKey: rootID)
        }

        func fileSystemServiceForTesting(rootID: UUID) -> FileSystemService? {
            rootStatesByID[rootID]?.service
        }

        func debugApplyEditsRebaseProbePathSnapshot(
            fullPath rawFullPath: String,
            rootScope: WorkspaceLookupRootScope
        ) async -> ApplyEditsRebaseProbePathSnapshot? {
            let fullPath = StandardizedPath.absolute(rawFullPath)
            guard let root = rootsForPathLookup(scope: rootScope)
                .filter({ StandardizedPath.isDescendant(fullPath, of: $0.standardizedFullPath) })
                .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count }),
                let state = rootStatesByID[root.id]
            else { return nil }
            let relativePath = URL(fileURLWithPath: fullPath)
                .relativePath(from: URL(fileURLWithPath: root.standardizedFullPath))
            guard let file = await file(rootID: root.id, relativePath: relativePath),
                  file.standardizedFullPath == fullPath
            else { return nil }
            return ApplyEditsRebaseProbePathSnapshot(
                rootID: root.id,
                rootLifetimeID: state.lifetimeID,
                rootToken: state.service.diagnosticRootToken,
                rootPath: root.standardizedFullPath,
                fileID: file.id,
                fullPath: file.standardizedFullPath,
                relativePath: file.standardizedRelativePath,
                isSessionWorktree: root.kind == .sessionWorktree,
                producedAppliedIndexGeneration: appliedIndexGenerationsByRootID[root.id] ?? 0
            )
        }

        func readSearchRootDiagnosticsSnapshot(
            recentPublicationLimit: Int = 8
        ) async -> [ReadSearchRootDiagnosticsSnapshot] {
            let requestedLimit = min(max(0, recentPublicationLimit), Self.publicationInvalidationSampleLimit)
            var snapshots: [ReadSearchRootDiagnosticsSnapshot] = []
            snapshots.reserveCapacity(rootLoadOrder.count)
            for rootID in rootLoadOrder {
                guard let state = rootStatesByID[rootID] else { continue }
                let history = publicationInvalidationHistoryByRootID[rootID] ?? PublicationInvalidationHistoryState()
                let freshness = await state.service.freshnessWorkDiagnosticsSnapshot()
                let watcherActive = await state.service.isWatchingForChangesForTesting()
                snapshots.append(ReadSearchRootDiagnosticsSnapshot(
                    rootID: rootID,
                    rootToken: state.service.diagnosticRootToken,
                    rootPath: state.root.standardizedFullPath,
                    rootKind: Self.rootKindDiagnosticLabel(state.root.kind),
                    crawlCount: rootCrawlCountsByRootID[rootID] ?? 0,
                    watcherActive: watcherActive,
                    explicitWatcherDemand: explicitWatcherDemandRootIDs.contains(rootID),
                    sessionWorktreeOwnerCount: sessionWorktreeOwnerCount(rootID: rootID, lifetimeID: state.lifetimeID),
                    ingress: publisherIngressCoordinator.debugSnapshot(rootID: rootID),
                    barrier: scopedIngressBarrierDebugSnapshot(rootID: rootID),
                    freshness: freshness,
                    invalidation: PublicationInvalidationHistoryDebugSnapshot(
                        retainedSampleLimit: Self.publicationInvalidationSampleLimit,
                        totalObservedPublicationCount: history.totalObservedPublicationCount,
                        droppedPublicationSampleCount: max(0, history.totalObservedPublicationCount - history.samples.count),
                        samples: requestedLimit == 0 ? [] : Array(history.samples.suffix(requestedLimit))
                    ),
                    producedAppliedIndexGeneration: appliedIndexGenerationsByRootID[rootID] ?? 0
                ))
            }
            return snapshots
        }

        func storeWorkDiagnosticsSnapshot() -> StoreWorkDiagnosticsSnapshot {
            StoreWorkDiagnosticsSnapshot(
                invalidations: catalogInvalidationHistory,
                catalogRebuild: CatalogRebuildDebugSnapshot(
                    rebuildCount: catalogRebuildCount,
                    filterMicroseconds: catalogRebuildFilterMicroseconds,
                    sortMicroseconds: catalogRebuildSortMicroseconds,
                    fileSortMicroseconds: catalogRebuildFileSortMicroseconds,
                    folderSortMicroseconds: catalogRebuildFolderSortMicroseconds,
                    sortResidualMicroseconds: catalogRebuildSortResidualMicroseconds,
                    sortReconciliationDeltaMicroseconds: catalogRebuildSortReconciliationDeltaMicroseconds,
                    sortInvocationCount: catalogRebuildSortInvocationCount,
                    sortFileInputCount: catalogRebuildSortFileInputCount,
                    sortFolderInputCount: catalogRebuildSortFolderInputCount,
                    materializationMicroseconds: catalogRebuildMaterializationMicroseconds,
                    pathIndexKeyMicroseconds: catalogRebuildPathIndexKeyMicroseconds,
                    pathIndexConstructionMicroseconds: catalogRebuildPathIndexConstructionMicroseconds,
                    compositionCacheResidualMicroseconds: catalogRebuildCompositionCacheResidualMicroseconds,
                    totalMicroseconds: catalogRebuildTotalMicroseconds,
                    lastFileCount: catalogRebuildLastFileCount,
                    lastRootCount: catalogRebuildLastRootCount
                ),
                rootCatalogShards: rootCatalogShardDebugSnapshot()
            )
        }

        private func recordCatalogInvalidation(
            reasons: Set<CatalogInvalidationReason>,
            affectedRootIDs: Set<UUID>,
            affectedRootKinds: Set<WorkspaceRootKind>,
            evictedScopes: [WorkspaceLookupRootScope]
        ) {
            nextCatalogInvalidationSequence &+= 1
            catalogInvalidationHistory.append(CatalogInvalidationDebugEvent(
                sequence: nextCatalogInvalidationSequence,
                reasons: reasons.map(\.rawValue).sorted(),
                affectedRootIDs: affectedRootIDs.sorted { $0.uuidString < $1.uuidString },
                affectedRootKinds: affectedRootKinds.map(Self.rootKindDiagnosticLabel).sorted(),
                evictedScopes: evictedScopes.map(Self.scopeDiagnosticLabel).sorted()
            ))
            if catalogInvalidationHistory.count > 64 {
                catalogInvalidationHistory.removeFirst(catalogInvalidationHistory.count - 64)
            }
        }

        private func recordCatalogRebuild(
            filterMicroseconds: UInt64,
            sortMicroseconds: UInt64,
            fileSortMicroseconds: UInt64,
            folderSortMicroseconds: UInt64,
            sortResidualMicroseconds: UInt64,
            sortReconciliationDeltaMicroseconds: Int64,
            sortInvocationCount: Int,
            sortFileInputCount: Int,
            sortFolderInputCount: Int,
            materializationMicroseconds: UInt64,
            pathIndexKeyMicroseconds: UInt64,
            pathIndexConstructionMicroseconds: UInt64,
            compositionCacheResidualMicroseconds: UInt64,
            totalMicroseconds: UInt64,
            fileCount: Int,
            rootCount: Int
        ) {
            catalogRebuildCount += 1
            catalogRebuildFilterMicroseconds &+= filterMicroseconds
            catalogRebuildSortMicroseconds &+= sortMicroseconds
            catalogRebuildFileSortMicroseconds &+= fileSortMicroseconds
            catalogRebuildFolderSortMicroseconds &+= folderSortMicroseconds
            catalogRebuildSortResidualMicroseconds &+= sortResidualMicroseconds
            catalogRebuildSortReconciliationDeltaMicroseconds += sortReconciliationDeltaMicroseconds
            catalogRebuildSortInvocationCount += sortInvocationCount
            catalogRebuildSortFileInputCount += sortFileInputCount
            catalogRebuildSortFolderInputCount += sortFolderInputCount
            catalogRebuildMaterializationMicroseconds &+= materializationMicroseconds
            catalogRebuildPathIndexKeyMicroseconds &+= pathIndexKeyMicroseconds
            catalogRebuildPathIndexConstructionMicroseconds &+= pathIndexConstructionMicroseconds
            catalogRebuildCompositionCacheResidualMicroseconds &+= compositionCacheResidualMicroseconds
            catalogRebuildTotalMicroseconds &+= totalMicroseconds
            catalogRebuildLastFileCount = fileCount
            catalogRebuildLastRootCount = rootCount
        }

        private func rootCatalogShardDebugSnapshot() -> RootCatalogShardDebugSnapshot {
            var trackedRootIDs = Set(rootStatesByID.keys)
            trackedRootIDs.formUnion(publishedRootCatalogShardsByRootID.keys)
            trackedRootIDs.formUnion(rootCatalogShardWeakReferencesByRootID.keys)

            let staleDiagnosticRootIDs = Set(rootCatalogShardBuildCountsByRootID.keys).subtracting(trackedRootIDs)
            for rootID in staleDiagnosticRootIDs {
                rootCatalogShardBuildCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardFullPathIndexBuildCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardOverlayPathIndexBuildCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardPatchCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardAuthoritativeRebuildCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardFallbackCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardFallbackReasonCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardFallbackLifetimeIDsByRootID.removeValue(forKey: rootID)
                rootCatalogShardBackstopCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardMaxLiveGenerationCountsByRootID.removeValue(forKey: rootID)
            }

            let roots = trackedRootIDs.sorted { $0.uuidString < $1.uuidString }.map { rootID in
                let liveShards = liveRootCatalogShards(rootID: rootID)
                let publishedShard = publishedRootCatalogShardsByRootID[rootID]
                let liveGenerations = liveShards.map(\.key.topologyGeneration).sorted()
                let retainedGenerations = liveShards.compactMap { shard -> UInt64? in
                    guard let publishedShard else { return shard.key.topologyGeneration }
                    return shard === publishedShard ? nil : shard.key.topologyGeneration
                }.sorted()
                let maxLiveCount = max(
                    rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] ?? 0,
                    liveShards.count
                )
                rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] = maxLiveCount
                let lifetimeID = publishedShard?.key.lifetimeID
                    ?? rootCatalogShardDeltaStatesByRootID[rootID]?.lifetimeID
                    ?? rootStatesByID[rootID]?.lifetimeID
                    ?? rootCatalogShardFallbackLifetimeIDsByRootID[rootID]
                    ?? liveShards.first?.key.lifetimeID
                if let lifetimeID {
                    resetRootCatalogShardFallbackDiagnosticsIfLifetimeChanged(
                        rootID: rootID,
                        lifetimeID: lifetimeID
                    )
                }
                return RootCatalogShardGenerationDebugSnapshot(
                    rootID: rootID,
                    lifetimeID: lifetimeID,
                    publishedTopologyGeneration: publishedShard?.key.topologyGeneration,
                    liveTopologyGenerations: liveGenerations,
                    retainedTopologyGenerations: retainedGenerations,
                    buildCount: rootCatalogShardBuildCountsByRootID[rootID] ?? 0,
                    pathIndexBuildCount: rootCatalogShardFullPathIndexBuildCountsByRootID[rootID] ?? 0,
                    overlayPathIndexBuildCount: rootCatalogShardOverlayPathIndexBuildCountsByRootID[rootID] ?? 0,
                    patchCount: rootCatalogShardPatchCountsByRootID[rootID] ?? 0,
                    authoritativeRebuildCount: rootCatalogShardAuthoritativeRebuildCountsByRootID[rootID] ?? 0,
                    fallbackCount: rootCatalogShardFallbackCountsByRootID[rootID] ?? 0,
                    fallbackReasonCounts: rootCatalogShardFallbackReasonCountsByRootID[rootID] ?? [:],
                    lastAppliedIndexGeneration: rootCatalogShardDeltaStatesByRootID[rootID]?.lastAppliedIndexGeneration,
                    deltaStateDirty: rootCatalogShardDeltaStatesByRootID[rootID]?.isDirty ?? false,
                    backstopCount: rootCatalogShardBackstopCountsByRootID[rootID] ?? 0,
                    maxLiveGenerationCount: maxLiveCount
                )
            }
            return RootCatalogShardDebugSnapshot(
                liveGenerationCapPerRoot: Self.maxLiveRootCatalogShardGenerationsPerRoot,
                maxPatchLogicalMutationCount: Self.maxRootCatalogShardPatchLogicalMutationCount,
                publishedShardCount: publishedRootCatalogShardsByRootID.count,
                totalBuildCount: rootCatalogShardBuildCountsByRootID.values.reduce(0, +),
                totalBackstopCount: rootCatalogShardBackstopCountsByRootID.values.reduce(0, +),
                singleShardCompositionReuseCount: rootCatalogShardSingleShardCompositionReuseCount,
                genericMergeElementVisitCount: rootCatalogShardGenericMergeElementVisitCount,
                shadowComparisonCount: rootCatalogShardShadowComparisonCount,
                shadowMismatchCount: rootCatalogShardShadowMismatchCount,
                lastShadowByteCount: rootCatalogShardLastShadowByteCount,
                roots: roots
            )
        }

        private static func rootKindDiagnosticLabel(_ kind: WorkspaceRootKind) -> String {
            switch kind {
            case .primaryWorkspace: "primary_workspace"
            case .workspaceGitData: "workspace_git_data"
            case .supplementalSystem: "supplemental_system"
            case .sessionWorktree: "session_worktree"
            }
        }

        private static func scopeDiagnosticLabel(_ scope: WorkspaceLookupRootScope) -> String {
            switch scope {
            case .visibleWorkspace:
                "visible_workspace"
            case .visibleWorkspacePlusGitData:
                "visible_workspace_plus_git_data"
            case .allLoaded:
                "all_loaded"
            case .allLoadedExcludingGitData:
                "all_loaded_excluding_git_data"
            case let .sessionBoundWorkspace(logicalRootPaths, physicalRootPaths):
                "session_bound_workspace(logical=\(logicalRootPaths.sorted().joined(separator: ","));physical=\(physicalRootPaths.sorted().joined(separator: ",")))"
            case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots):
                "validated_session_bound_workspace(logical=\(canonicalRoots.map(\.standardizedFullPath).sorted().joined(separator: ","));physical=\(physicalRoots.map(\.standardizedFullPath).sorted().joined(separator: ",")))"
            }
        }

        private static func debugElapsedMicroseconds(since start: UInt64, through end: UInt64) -> UInt64 {
            end >= start ? (end - start) / 1000 : 0
        }

        private func scopedIngressBarrierDebugSnapshot(rootID: UUID) -> ScopedIngressBarrierDebugSnapshot {
            let now = debugNowNanoseconds()
            let state = scopedIngressBarrierFlightStatesByRootID[rootID]
            let active = state?.active.map { flight in
                ScopedIngressBarrierDebugSnapshot.Active(
                    targetWatcherWatermark: flight.target.watcherAcceptedWatermark.rawValue,
                    targetServicePublicationSequence: flight.target.acceptedServicePublicationSequence,
                    ageMilliseconds: Self.elapsedMilliseconds(
                        since: flight.startedAtNanoseconds,
                        now: now
                    )
                )
            }
            let pending = state?.pending.map { pending in
                ScopedIngressBarrierDebugSnapshot.Pending(
                    targetWatcherWatermark: pending.target.watcherAcceptedWatermark.rawValue,
                    targetServicePublicationSequence: pending.target.acceptedServicePublicationSequence,
                    ageMilliseconds: Self.elapsedMilliseconds(
                        since: pending.enqueuedAtNanoseconds,
                        now: now
                    )
                )
            }
            return ScopedIngressBarrierDebugSnapshot(
                launchCount: scopedIngressBarrierLaunchCountsByRootID[rootID] ?? 0,
                joinCount: scopedIngressBarrierJoinCountsByRootID[rootID] ?? 0,
                successorCount: scopedIngressBarrierSuccessorCountsByRootID[rootID] ?? 0,
                coalescedSuccessorCount: scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID] ?? 0,
                completionCount: scopedIngressBarrierCompletionCountsByRootID[rootID] ?? 0,
                noopCount: scopedIngressBarrierNoopCountsByRootID[rootID] ?? 0,
                totalWaitMilliseconds: scopedIngressBarrierTotalWaitMillisecondsByRootID[rootID] ?? 0,
                maxWaitMilliseconds: scopedIngressBarrierMaxWaitMillisecondsByRootID[rootID] ?? 0,
                active: active,
                pending: pending,
                lastCompleted: lastCompletedScopedIngressBarrierByRootID[rootID]
            )
        }

        func retainedReadSearchDiagnosticRootIDsForTesting() -> Set<UUID> {
            Set(scopedIngressBarrierLaunchCountsByRootID.keys)
                .union(scopedIngressBarrierJoinCountsByRootID.keys)
                .union(scopedIngressBarrierSuccessorCountsByRootID.keys)
                .union(scopedIngressBarrierCoalescedSuccessorCountsByRootID.keys)
                .union(scopedIngressBarrierCompletionCountsByRootID.keys)
                .union(scopedIngressBarrierNoopCountsByRootID.keys)
                .union(scopedIngressBarrierTotalWaitMillisecondsByRootID.keys)
                .union(scopedIngressBarrierMaxWaitMillisecondsByRootID.keys)
                .union(lastCompletedScopedIngressBarrierByRootID.keys)
                .union(publicationInvalidationHistoryByRootID.keys)
                .union(rootCrawlCountsByRootID.keys)
        }

        private func recordScopedIngressBarrierCompletion(
            rootID: UUID,
            token: UInt64,
            target: ScopedIngressBarrierTarget,
            sample: WorkspaceIngressBarrierSample,
            startedAtNanoseconds: UInt64,
            completedAtNanoseconds: UInt64
        ) {
            guard rootStatesByID[rootID] != nil else { return }
            scopedIngressBarrierCompletionCountsByRootID[rootID, default: 0] += 1
            let durationMilliseconds = Self.elapsedMilliseconds(
                since: startedAtNanoseconds,
                now: completedAtNanoseconds
            )
            scopedIngressBarrierTotalWaitMillisecondsByRootID[rootID, default: 0] += durationMilliseconds
            scopedIngressBarrierMaxWaitMillisecondsByRootID[rootID] = max(
                scopedIngressBarrierMaxWaitMillisecondsByRootID[rootID] ?? 0,
                durationMilliseconds
            )
            guard token > (lastCompletedScopedIngressBarrierByRootID[rootID]?.token ?? 0) else { return }
            lastCompletedScopedIngressBarrierByRootID[rootID] = ScopedIngressBarrierDebugSnapshot.Completed(
                token: token,
                targetWatcherWatermark: target.watcherAcceptedWatermark.rawValue,
                targetServicePublicationSequence: target.acceptedServicePublicationSequence,
                publishedServicePublicationSequence: sample.publishedServicePublicationSequence,
                appliedServicePublicationSequence: sample.appliedServicePublicationSequence,
                appliedWatcherWatermark: sample.appliedWatcherWatermark,
                durationMilliseconds: durationMilliseconds
            )
        }

        private func recordPublicationInvalidationDiagnostics(
            rootID: UUID,
            servicePublicationSequence: UInt64,
            watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
            recorder: PublicationInvalidationRecorder
        ) {
            guard rootStatesByID[rootID] != nil else { return }
            let sample = makePublicationInvalidationDebugSample(
                servicePublicationSequence: servicePublicationSequence,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                recorder: recorder
            )
            var history = publicationInvalidationHistoryByRootID[rootID] ?? PublicationInvalidationHistoryState()
            history.totalObservedPublicationCount += 1
            history.samples.append(sample)
            if history.samples.count > Self.publicationInvalidationSampleLimit {
                history.samples.removeFirst(history.samples.count - Self.publicationInvalidationSampleLimit)
            }
            publicationInvalidationHistoryByRootID[rootID] = history
        }

        private func makePublicationInvalidationDebugSample(
            servicePublicationSequence: UInt64,
            watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
            recorder: PublicationInvalidationRecorder
        ) -> PublicationInvalidationDebugSample {
            PublicationInvalidationDebugSample(
                servicePublicationSequence: servicePublicationSequence,
                watcherAcceptedWatermark: watcherAcceptedWatermark?.rawValue,
                preparedDeltaCount: recorder.preparedDeltaCount,
                topologyInvalidationCount: recorder.topologyInvalidationCount,
                catalogGenerationAdvanceCount: recorder.catalogGenerationAdvanceCount,
                searchCatalogCacheClearCount: recorder.searchCatalogCacheClearCount,
                pathWorkerInvalidationRequestCount: recorder.pathWorkerInvalidationRequestCount,
                contentInvalidationCount: recorder.contentInvalidationCount,
                distinctContentKeyCount: recorder.distinctContentKeys.count,
                decodedCacheInvalidationRequestCount: recorder.decodedCacheInvalidationRequestCount,
                codemapInvalidationRequestCount: recorder.codemapInvalidationRequestCount,
                appliedIndexEventYieldCount: recorder.appliedIndexEventYieldCount
            )
        }

        private static func elapsedMilliseconds(since start: UInt64, now: UInt64) -> UInt64 {
            guard now >= start else { return 0 }
            return (now - start) / 1_000_000
        }

        func searchDecodedContentCacheSnapshotForTesting() async -> WorkspaceSearchDecodedContentCache.Snapshot {
            await searchDecodedContentCache.snapshotForTesting()
        }

        func interactiveReadCacheSnapshotForTesting() async -> WorkspaceInteractiveReadCache.Snapshot {
            await interactiveReadCache.snapshotForTesting()
        }

        func searchLaneSnapshotForTesting() async -> StoreBackedWorkspaceSearchLane.Snapshot {
            await storeBackedSearchLane.snapshotForTesting()
        }

        func configureSearchLaneForTesting(
            _ configuration: StoreBackedWorkspaceSearchLane.Configuration
        ) async -> StoreBackedWorkspaceSearchLane.DebugConfigurationUpdateResult {
            await storeBackedSearchLane.configureForTesting(configuration)
        }

        func resetSearchLaneConfigurationForTesting() async -> StoreBackedWorkspaceSearchLane.DebugConfigurationUpdateResult {
            await storeBackedSearchLane.resetConfigurationForTesting()
        }

        func setSearchLanePermitAcquiredHandlerForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) async {
            await storeBackedSearchLane.setPermitAcquiredHandlerForTesting(handler)
        }

        func setStoreEditDeferredPublicationDidRegisterHandlerForTesting(
            _ handler: (@Sendable (UUID, String) async -> Void)?
        ) {
            storeEditDeferredPublicationDidRegisterHandler = handler
        }

        func setSearchContentReadChunkHandlerForTesting(
            rootID: UUID,
            _ handler: (@Sendable (String) async -> Void)?
        ) async throws {
            let state = try state(for: rootID)
            await state.service.setContentReadChunkHandlerForTesting(handler)
        }

        func resetSearchContentFingerprintRequestCountForTesting(rootID: UUID) async throws {
            let state = try state(for: rootID)
            await state.service.resetContentFingerprintRequestCountForTesting()
        }

        func searchContentFingerprintRequestCountForTesting(rootID: UUID) async throws -> Int {
            let state = try state(for: rootID)
            return await state.service.contentFingerprintRequestCountSnapshotForTesting()
        }

        func setCachedSearchContentWatcherActiveOverrideForTesting(
            rootID: UUID,
            _ isActive: Bool?
        ) async throws {
            let state = try state(for: rootID)
            await state.service.setCachedSearchContentWatcherActiveOverrideForTesting(isActive)
        }
    #endif

    private enum ExplicitDiskLookupCandidatesResult {
        case candidates([(rootID: UUID, relativePath: String)])
        case ambiguousAlias
    }

    private struct RootIndexBuffers {
        var foldersByID: [UUID: WorkspaceFolderRecord] = [:]
        var filesByID: [UUID: WorkspaceFileRecord] = [:]
        var folderIDsByStandardizedFullPath: [String: UUID] = [:]
        var fileIDsByStandardizedFullPath: [String: UUID] = [:]
    }

    private struct RootCatalogCanonicalConfigurationIdentity: Hashable {
        let canonicalPath: String
        let loadConfiguration: RootLoadConfiguration
    }

    private struct RootCatalogShardKey: Hashable {
        let canonicalConfigurationIdentity: RootCatalogCanonicalConfigurationIdentity
        let rootID: UUID
        let lifetimeID: UUID
        let topologyGeneration: UInt64
    }

    private struct RootCatalogProjectionFile {
        let file: WorkspaceFileRecord
        let language: LanguageType
    }

    private final class RootCatalogShard: @unchecked Sendable {
        let key: RootCatalogShardKey
        let root: WorkspaceRootRecord
        let files: [WorkspaceFileRecord]
        let projectionFiles: [RootCatalogProjectionFile]
        let projectionFileIndexByID: [UUID: Int]
        let folders: [WorkspaceFolderRecord]
        let entries: [WorkspaceSearchCatalogEntry]
        /// P4-7c c3: `pathSearchIndex: WorkspaceSearchRootPathIndex?` deleted -- it was always `nil`
        /// in production since P4-7b b3 (`makeRootPathSearchIndex` deleted, D-14) and the type it
        /// pointed at is deleted this slice.
        let appliedIndexGeneration: UInt64

        var folderCount: Int {
            folders.count
        }

        init(
            key: RootCatalogShardKey,
            root: WorkspaceRootRecord,
            files: [WorkspaceFileRecord],
            precomputedProjectionFiles: [RootCatalogProjectionFile]? = nil,
            folders: [WorkspaceFolderRecord],
            entries: [WorkspaceSearchCatalogEntry],
            appliedIndexGeneration: UInt64
        ) {
            self.key = key
            self.root = root
            self.files = files
            let projectionFiles = precomputedProjectionFiles ?? files
                .compactMap { file in
                    let fileExtension = (file.name as NSString).pathExtension
                    guard SyntaxManager.supportsCodeMap(fileExtension: fileExtension),
                          let language = SyntaxManager.shared.language(forFileExtension: fileExtension)
                    else { return nil }
                    return RootCatalogProjectionFile(file: file, language: language)
                }
                .sorted { lhs, rhs in
                    WorkspaceInventoryOrdering.searchRootCatalogFilePrecedes(lhs.file, rhs.file)
                }
            self.projectionFiles = projectionFiles
            projectionFileIndexByID = Dictionary(
                uniqueKeysWithValues: projectionFiles.enumerated().map { ($0.element.file.id, $0.offset) }
            )
            self.folders = folders
            self.entries = entries
            self.appliedIndexGeneration = appliedIndexGeneration
        }
    }

    private struct CodemapGraphIndexCatalogShardBuildSnapshot: @unchecked Sendable {
        let authority: CodemapRootAuthority
        let key: RootCatalogShardKey
        let root: WorkspaceRootRecord
        let appliedIndexGeneration: UInt64
        let graphIndexInvalidationGeneration: UInt64
        let files: [WorkspaceFileRecord]
        let folders: [WorkspaceFolderRecord]
        let managedOnlyFileIDs: Set<UUID>
        let managedOnlyFolderIDs: Set<UUID>
    }

    private enum CodemapGraphIndexCatalogShardPublicationDisposition {
        case ready
        case retry
        case unavailable
    }

    private final class WeakRootCatalogShardReference {
        weak var shard: RootCatalogShard?

        init(_ shard: RootCatalogShard) {
            self.shard = shard
        }
    }

    private struct AuthoritativeCatalogComponents {
        let files: [WorkspaceFileRecord]
        let folders: [WorkspaceFolderRecord]
        let entries: [WorkspaceSearchCatalogEntry]
    }

    private struct RootCatalogShardDeltaState {
        let lifetimeID: UUID
        var lastAppliedIndexGeneration: UInt64
        var isDirty: Bool
        let capability: WorkspaceSearchCatalogAccessRequirement
    }

    private enum RootCatalogShardBuildKind {
        case patch
        case authoritative
    }

    private struct RootCatalogShardBuilderOutput {
        let files: [WorkspaceFileRecord]
        let folders: [WorkspaceFolderRecord]
        let logicalMutationCount: Int
        let pathIndexChangedFileIDs: Set<UUID>
    }

    private struct SearchCatalogRootDependency: Hashable {
        let canonicalIdentity: String
        let rootID: UUID
        let lifetimeID: UUID
        let generation: UInt64
    }

    private enum SearchCatalogSnapshotValidationToken: Hashable {
        case staticScope(generation: UInt64)
        case sessionBound(
            logicalRootPaths: [String],
            physicalRootPaths: [String],
            dependencies: [SearchCatalogRootDependency]
        )
    }

    private struct SearchCatalogSnapshotCacheEntry {
        let validationToken: SearchCatalogSnapshotValidationToken
        let capability: WorkspaceSearchCatalogAccessRequirement
        let snapshot: WorkspaceSearchCatalogSnapshot
        var lastAccessSequence: UInt64
    }

    private struct SessionCatalogGenerationState {
        let validationToken: SearchCatalogSnapshotValidationToken
        let generation: UInt64
    }

    private struct StaticPathMatchSnapshotCacheEntry {
        let snapshot: StaticPathMatchData
        var lastAccessSequence: UInt64
    }

    private let sessionRootLifetimeClock = WorkspaceSessionRootLifetimeClock()
    private var rootStatesByID: [UUID: RootState] = [:]
    private var rootIDsByStandardizedPath: [String: UUID] = [:]
    // P4-6b table deletion: the cross-root global `filesByID`/`foldersByID`/
    // `fileIDsByStandardizedFullPath`/`folderIDsByStandardizedFullPath` tables (design doc
    // Appendix A1) are deleted here. Rust's InventoryScope is now the sole authority for file/
    // folder record content; every former reader was traced and converted to the async
    // Rust-routed accessors in the P4-6b table-deletion conversion ledger
    // (Tests/RepoPromptTests/WorkspaceContext/P4-6b-table-deletion-conversion-ledger.md) before
    // this deletion landed -- any reference the compiler still finds below this point is a
    // genuinely missed site, not an expected one.
    private var managedOnlyFileIDs = Set<UUID>()
    private var managedOnlyFolderIDs = Set<UUID>()
    private var rootLoadOrder: [UUID] = []
    private var unloadingRootPaths: Set<String> = []
    private var unloadWaitersByRootPath: [String: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var rootLoadFlightsByPath: [String: RootLoadFlight] = [:]
    private var rootLoadConfigurationsByPath: [String: RootLoadConfiguration] = [:]
    private var catalogGenerationsByScope: [WorkspaceLookupRootScope: UInt64] = [
        .visibleWorkspace: 0,
        .visibleWorkspacePlusGitData: 0,
        .allLoaded: 0
    ]
    private var catalogGenerationsByRootID: [UUID: UInt64] = [:]
    private var sessionCatalogGenerationStatesByScope: [WorkspaceLookupRootScope: SessionCatalogGenerationState] = [:]
    private var nextSessionCatalogGeneration: UInt64 = 0
    private var searchCatalogSnapshotsByScope: [WorkspaceLookupRootScope: SearchCatalogSnapshotCacheEntry] = [:]
    private var nextSearchCatalogSnapshotAccessSequence: UInt64 = 0
    private var publishedRootCatalogShardsByRootID: [UUID: RootCatalogShard] = [:]
    private var rootCatalogShardWeakReferencesByRootID: [UUID: [WeakRootCatalogShardReference]] = [:]
    private var rootCatalogShardDeltaStatesByRootID: [UUID: RootCatalogShardDeltaState] = [:]
    private var pathMatchSnapshotIdentitiesByScope: [WorkspaceLookupRootScope: PathMatchCacheIdentity] = [:]
    private var staticPathMatchSnapshotsByScope: [WorkspaceLookupRootScope: StaticPathMatchSnapshotCacheEntry] = [:]
    private var nextStaticPathMatchSnapshotAccessSequence: UInt64 = 0
    private let storeBackedSearchLane: StoreBackedWorkspaceSearchLane
    private let rootReusableSnapshotCoordinator = WorkspaceRootReusableSnapshotCoordinator.shared
    private let rootMaterializationHintEvaluator = WorkspaceRootMaterializationHintEvaluator.shared
    private let rootSeedPlanner = WorkspaceRootSeedPlanner.shared
    private let workspaceStateAuthority = GitWorkspaceStateAuthority.shared
    private let worktreeSeedGitService = GitService()
    private let searchDecodedContentCache = WorkspaceSearchDecodedContentCache()
    private let interactiveReadCache = WorkspaceInteractiveReadCache()
    private let searchContentSchedulerOwnerID = UUID()
    private let interactiveReadSchedulerOwnerID = UUID()
    #if os(macOS)
        private let searchContentMemoryPressureSource: DispatchSourceMemoryPressure
    #endif
    private var searchContentInvalidationEpochsByFileID: [UUID: UInt64] = [:]
    private var nextSearchContentInvalidationEpoch: UInt64 = 0
    private var activePublicationInvalidationBatch: PublicationInvalidationBatch?
    private static let maxCachedSearchCatalogSnapshotScopes = 16
    private static let maxCachedStaticPathMatchSnapshotScopes = 16
    /// Covers overlapping readers/index builds while bounding retained full-root arrays. At the cap,
    /// callers receive an authoritative uncached rebuild until older ARC leases drain.
    private static let maxLiveRootCatalogShardGenerationsPerRoot = 8
    // The checked-in WI-3 baseline (`docs/investigations/mcp-tool-throughput-wi3-baseline-2026-06-11.md`)
    // records authoritative catalog rebuild work in roots/files, and its fixture
    // proves a three-file/two-root rebuild, but it does not establish a multi-record crossover.
    // Patch exactly one logical catalog record—the common single-file watcher case—and rebuild for
    // every broader batch until measured evidence supports increasing this deliberately conservative cap.
    private static let maxRootCatalogShardPatchLogicalMutationCount = 1
    private static let defaultMaxPendingDeltasPerRoot = 10000
    private let pathMatchWorker = PathMatchWorker()
    private let deferredReplayBuffer = DeferredReplayBufferActor(
        maxPendingDeltasPerRoot: WorkspaceFileContextStore.defaultMaxPendingDeltasPerRoot
    )
    private let codemapRuntimeProvider: CodeMapArtifactRuntimeProvider.Factory
    private let codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe
    private let codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe
    private let codemapGraphIndexBuildRetryPolicy: CodemapGraphIndexBuildRetryPolicy
    private let selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory
    private let selectionGraphQueryBudgetPolicy: WorkspaceCodemapAutomaticSelectionBudgetPolicy
    private let automaticSelectionAccountingMaximum: Int
    private let codemapDemandRequestHook: @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void
    private let codemapCancellationCleanupHook: @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void
    private let codemapReadyPublicationHook: @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void
    private let codemapGraphPublicationWaiter: @Sendable (WorkspaceCodemapRootEpoch) async -> Void
    private let codemapDemandResultHook: @Sendable (
        WorkspaceCodemapArtifactDemandTicket,
        WorkspaceCodemapBindingDemandResult
    ) async -> WorkspaceCodemapBindingDemandResult
    private let codemapAutomaticSelectionQueryHook: @Sendable (WorkspaceCodemapRootEpoch) async -> Void
    private struct TerminalNonGitCodemapCacheEntry {
        let standardizedRootPath: String
        let proof: WorkspaceCodemapNonGitFilesystemProof
    }

    private var codemapSessionsByRootEpoch: [WorkspaceCodemapRootEpoch: CodemapRootSession] = [:]
    private var codemapEligibilityFlightsByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapEligibilityFlight
    ] = [:]
    private var codemapCompletedEligibilityByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapCompletedEligibility
    ] = [:]
    private var codemapGraphIndexBuildLaunchesByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapGraphIndexBuildLaunch
    ] = [:]
    private var codemapGraphIndexBuildRetriesByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapGraphIndexBuildRetry
    ] = [:]
    private var codemapGraphIndexRetryExhaustionByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapGraphIndexRetryExhaustion
    ] = [:]
    private var terminalNonGitCodemapCacheByEpoch: [
        WorkspaceCodemapRootEpoch: TerminalNonGitCodemapCacheEntry
    ] = [:]
    #if DEBUG
        private let codemapGraphIndexBuildLaunchPolicyForTesting: CodemapGraphIndexBuildLaunchPolicyForTesting
        private var debugCodemapGraphIndexHoldOwners: [
            UUID: (rootEpoch: WorkspaceCodemapRootEpoch, engine: WorkspaceCodemapBindingEngine)
        ] = [:]
        private var debugCodemapGraphIndexHoldExpiryTasks: [UUID: Task<Void, Never>] = [:]
        private var codemapGraphIndexBuildStoreEvents: [CodemapGraphIndexBuildStoreEvent] = []
        private var nextCodemapGraphIndexBuildStoreEventOrdinal: UInt64 = 0
        private var codemapGraphIndexBuildStartHandler: (@Sendable (WorkspaceCodemapRootEpoch) async -> Void)?
        private var codemapGraphIndexCatalogBuildHandler: (@Sendable (WorkspaceCodemapRootEpoch) async -> Void)?
        private var codeStructureSelectedMetadataResolutionRequestCountForTesting = 0
        private var codemapPresentationCandidateRequestCountForTesting = 0
        private var codemapArtifactDemandRequestCountForTesting = 0
        private var codemapPresentationFreezeRequestCountForTesting = 0
        private var codemapSetupTaskCreationCountForTesting = 0
        private var codemapDemandTaskCreationCountForTesting = 0
        private var codemapTargetedReadyFreezeCountForTesting = 0
        private var codemapFullRootGraphFreezeCountForTesting = 0
        private var filesInRootRequestCountForTesting = 0
        /// P4-7a phase a3 byte-accounting done-when (design §5.3): a call counter on
        /// `searchCatalogSnapshot`, the sole choke point that vends `.entries` -- asserted zero
        /// across a `.suggestion`-routed `AgentFileTagSuggestionService.suggestions(for:)` call to
        /// discharge "the whole-entries walk is provably gone," per §11's proof requirement.
        private var searchCatalogSnapshotCallCountForTesting = 0
        private var appliedIndexRecordLookupRequestCountForTesting = 0
        private var appliedIndexRecordLookupRequestedRecordCountForTesting = 0
        private var appliedIndexRootSnapshotRequestCountForTesting = 0
        private var codemapPathInvalidationStageHandlerForTesting:
            (@Sendable (WorkspaceCodemapRootEpoch, UUID, CodemapPathInvalidationStage) async -> Void)?
        private var discardedCodemapPathFenceReleaseCounterForTesting = 0
    #endif
    private var codemapCleanupFlightsByRootID: [UUID: CodemapCleanupFlight] = [:]
    private var codemapPathInvalidationFlightsByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapPathInvalidationFlight
    ] = [:]
    private var codemapPathFenceTokensByID: [UUID: CodemapPathFenceToken] = [:]
    private var codemapRootMutationFenceTokensByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapRootMutationFenceToken
    ] = [:]
    private var codemapRootMutationFenceWaitersByRootEpoch: [
        WorkspaceCodemapRootEpoch: [UUID: CheckedContinuation<Void, Never>]
    ] = [:]
    private var codemapPathQuiescenceWaitersByRootEpoch: [
        WorkspaceCodemapRootEpoch: [UUID: CheckedContinuation<Void, Never>]
    ] = [:]
    private var codemapGraphIndexBuildReschedulePendingRootEpochs: Set<WorkspaceCodemapRootEpoch> = []
    private var codemapSuspendedRootEpochs: Set<WorkspaceCodemapRootEpoch> = []
    private var codemapResumeTransitionIDsByRootEpoch: [WorkspaceCodemapRootEpoch: UUID] = [:]
    private var codemapGraphAccountingByRootEpoch: [
        WorkspaceCodemapRootEpoch: WorkspaceCodemapGraphIncrementalAccounting
    ] = [:]
    private var codemapGraphIndexWorkerRecoveryExhaustedRootEpochs: Set<WorkspaceCodemapRootEpoch> = []
    private var codemapRootStatusCoverageBaselinesByRootEpoch: [
        WorkspaceCodemapRootEpoch: CodemapRootStatusCoverageBaseline
    ] = [:]
    private var codemapRootStatusContinuations: [
        UUID: AsyncStream<WorkspaceCodemapRootStatusUpdate>.Continuation
    ] = [:]
    private var codemapRootStatusRevision: UInt64 = 0
    private var lastPublishedCodemapRootStatuses: [WorkspaceCodemapRootStatusSnapshot] = []
    private var codemapPathLocalCatalogMutationDepthByRootID: [UUID: Int] = [:]
    private var codemapAuthorityGenerationsByRootEpoch: [WorkspaceCodemapRootEpoch: UInt64] = [:]
    private var codemapGraphIndexInvalidationGenerationsByRootEpoch: [
        WorkspaceCodemapRootEpoch: UInt64
    ] = [:]
    private var codemapMarkerReadinessContinuations: [
        UUID: AsyncStream<WorkspaceCodemapMarkerReadinessEvent>.Continuation
    ] = [:]
    private var fileSystemDeltaContinuations: [UUID: AsyncStream<WorkspaceFileSystemDeltaEvent>.Continuation] = [:]
    private var appliedIndexContinuations: [UUID: AsyncStream<WorkspaceAppliedIndexBatchEvent>.Continuation] = [:]
    private var appliedIndexGenerationsByRootID: [UUID: UInt64] = [:]
    private var sliceRebaseSourceEntries: [SliceRebaseSourceCacheKey: SliceRebaseSourceCacheEntry] = [:]
    private var sliceRebaseSourceEstimatedBytes = 0
    private var sliceRebaseSourceAccessOrdinal: UInt64 = 0
    private static let maxSliceRebaseSourceEntryCount = 64
    private static let maxSliceRebaseSourceTotalBytes = 32 * 1024 * 1024
    private static let maxSliceRebaseSourceEntryBytes = 8 * 1024 * 1024
    private var watcherPublisherAttachmentsByKey: [WatcherInfrastructureKey: WatcherPublisherAttachment] = [:]
    private var watcherInfrastructureFlightsByKey: [WatcherInfrastructureKey: WatcherInfrastructureFlight] = [:]
    private var explicitWatcherDemandRootIDs = Set<UUID>()
    private var explicitWatcherDemandGenerationByKey: [WatcherInfrastructureKey: UInt64] = [:]
    private var latestSessionWorktreeOwnershipGenerationByOwnerID: [UUID: UInt64] = [:]
    private var installedSessionWorktreeOwnershipTokenByOwnerID: [UUID: WorkspaceSessionWorktreeOwnershipToken] = [:]
    private var sessionWorktreeOwnershipRecordsByToken: [WorkspaceSessionWorktreeOwnershipToken: SessionWorktreeOwnershipRecord] = [:]
    private var sessionWorktreeOwnershipTokensByRootLifetime: [SessionWorktreeRootLifetimeKey: Set<WorkspaceSessionWorktreeOwnershipToken>] = [:]
    private var sessionWorktreeReservationTokensByStandardizedPath: [String: Set<WorkspaceSessionWorktreeOwnershipToken>] = [:]
    private var sessionWorktreeReservedPathsByToken: [WorkspaceSessionWorktreeOwnershipToken: Set<String>] = [:]
    private var sessionWorktreeReservationLoadFlightsByToken: [WorkspaceSessionWorktreeOwnershipToken: [String: RootLoadFlight]] = [:]
    #if DEBUG
        private var sessionWorktreeOrphanLoadCleanupsByID: [UUID: SessionWorktreeOrphanLoadCleanup] = [:]
        private var sessionWorktreeOrphanLoadCleanupOverflowCount = 0
        private static let maximumSessionWorktreeOrphanLoadCleanupRecords = 64
    #endif
    private var pendingSeededRootsByID: [WorkspacePendingSeededRootID: PendingSeededRoot] = [:]
    private var pendingSeededRootIDsByStandardizedPath: [String: WorkspacePendingSeededRootID] = [:]
    #if DEBUG
        private var pendingReceiptConsumptionDecisionByToken: [
            WorkspaceSessionWorktreeOwnershipToken:
                (correlationID: UUID, decision: WorktreeStartupInstrumentation.ReceiptConsumptionDecision)
        ] = [:]
    #endif
    private var pendingSeededRootVisibilityWaitersByPath: [
        String: [UUID: CheckedContinuation<Void, Error>]
    ] = [:]
    private var seededAuthorityInvalidationListenerTask: Task<Void, Never>?
    private var publishedSeededAuthorityFencesByRootID: [UUID: GitWorkspacePendingInitializationAuthorityFence] = [:]
    private var publishedSeededAuthorityClaimsByRootID: [UUID: WorkspaceRootSeedServingAuthorityClaim] = [:]
    private var publishedSeededAuthorityStatesByRootID: [UUID: PublishedSeededAuthorityState] = [:]
    private var publishedSeededAuthorityWaitersByRootID: [
        UUID: [UUID: CheckedContinuation<Void, Error>]
    ] = [:]
    private var seededAuthorityPendingGenerationByRootID: [UUID: UInt64] = [:]
    private var seededAuthorityReconciliationTasksByRootID: [UUID: Task<Void, Never>] = [:]
    private let publisherIngressCoordinator: WorkspaceFileSystemIngressCoordinator
    private let unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy
    private var scopedIngressBarrierFlightStatesByRootID: [UUID: ScopedIngressBarrierRootFlightState] = [:]
    private var completedScopedIngressBarrierCutsByRootID: [UUID: ScopedIngressBarrierCompletedCut] = [:]
    private var nextScopedIngressBarrierToken: UInt64 = 0
    private static let maxConcurrentScopedIngressBarriers = 8
    #if DEBUG
        private let debugNowNanoseconds: @Sendable () -> UInt64
        private let isCatalogShardShadowValidationEnabled: Bool
    #endif

    // P4-6b: the production mutation/read authority (`WorkspaceInventoryScopeAuthority`). Opened
    // lazily on first use -- see that type's doc comment for the root-lifecycle technique it
    // shares with the (now-deleted) shadow forwarder. Ships in release builds; unlike the shadow
    // forwarder this is not `#if DEBUG`.
    private var inventoryScopeAuthority: WorkspaceInventoryScopeAuthority?

    // P4-6b republication arming (design doc §4.3): the adapter is constructed, subscribed, and
    // merging as of this commit, but its output is deliberately routed to
    // `republishedInventoryScopeEvents()` rather than `appliedIndexContinuations` -- see
    // `startInventoryScopeRepublicationTaskIfNeeded`'s header comment for the two open gaps
    // (generation-counter provenance, `modifiedFileSourceSnapshotsByID`'s synchronous-take
    // lifetime) that keep the actual source flip a follow-on rather than part of this commit.
    private var inventoryScopeRepublicationTask: Task<Void, Never>?
    private var inventoryScopeRepublicationAdapter: WorkspaceInventoryScopeRepublicationAdapter?
    private var republishedInventoryScopeEventContinuations: [UUID: AsyncStream<WorkspaceAppliedIndexBatchEvent>.Continuation] = [:]

    struct WorkspaceInventoryScopeAuthorityUnavailable: Error {}

    private func inventoryScopeAuthorityInstance() async throws -> WorkspaceInventoryScopeAuthority {
        if let inventoryScopeAuthority { return inventoryScopeAuthority }
        guard let bridge = try await AgentryCoreService.shared.runtime() as? AgentryCoreBridge else {
            throw WorkspaceInventoryScopeAuthorityUnavailable()
        }
        let authority = WorkspaceInventoryScopeAuthority(bridge: bridge)
        inventoryScopeAuthority = authority
        return authority
    }

    /// Promoted from the (now-deleted) `inventoryScopeRepublicationRootInfoForTesting` --
    /// resolves a root's current Swift-owned path/lifetime facts for
    /// `WorkspaceInventoryScopeRepublicationAdapter`'s `rootInfo` closure (design doc §4.2: root
    /// binding/topology facts stay Swift-owned both before and after the cutover).
    private func inventoryScopeRepublicationRootInfo(rootID: UUID) -> WorkspaceInventoryScopeRepublicationRootInfo? {
        guard let state = rootStatesByID[rootID] else { return nil }
        return WorkspaceInventoryScopeRepublicationRootInfo(
            standardizedFullPath: state.root.standardizedFullPath,
            lifetimeID: state.lifetimeID
        )
    }

    /// P4-6b republication arming (design doc §4.3): starts, once per store, a hub-wide
    /// subscription over the authority's own event stream (`authority.events()` takes no
    /// `rootID` -- one subscription per store, not one per root, matching the adapter's own
    /// `.gap` handling being hub-wide rather than per-root), feeding
    /// `WorkspaceInventoryScopeRepublicationAdapter` and publishing its output on
    /// `republishedInventoryScopeEvents()`.
    ///
    /// Deliberately does **not** feed `appliedIndexContinuations` (the real `appliedIndexEvents()`
    /// stream `WorkspaceSearchService`/`WorkspaceFilesViewModel` subscribe to today via
    /// `publishAppliedIndexEvent`). Two gaps keep that flip a follow-on rather than part of this
    /// commit:
    ///
    /// 1. **Generation-counter provenance is unproven.** `publishAppliedIndexEvent` numbers
    ///    generations from Swift's own `nextAppliedIndexGeneration(forRootID:)` counter; this
    ///    adapter numbers them from Rust's `generationAdvanced.appliedIndexGeneration`. Nothing
    ///    proves the two counters agree for an already-loaded root. Both consumers guard on
    ///    `event.generation > handledGeneration` -- a silent mismatch would make that guard drop
    ///    every event until Rust's numbering catches up, with no crash and no focused-test
    ///    signal. `publishAppliedIndexEvent` also applies a discoverability filter
    ///    (`isDiscoverableFileID`/`isDiscoverableFolderID`, which reads Swift-side
    ///    `managedOnlyFileIDs`/`managedOnlyFolderIDs`) and an empty-batch suppression guard that
    ///    this adapter path does not re-apply.
    /// 2. **`modifiedFileSourceSnapshotsByID` assumes a co-located producer.** Design doc §4.3
    ///    point 3 calls the merge "a local join, not a cross-cutting redesign" because
    ///    `takeSliceRebaseSource` -- a **take**, consumed exactly once -- is called synchronously
    ///    inside `publishAppliedIndexEvent` at the mutation call site. A second, asynchronous
    ///    consumer subscribing to Rust's event stream cannot take the same resource without
    ///    inventing a stash/eviction lifetime the design never specified. This method therefore
    ///    republishes with `modifiedFileSourceSnapshotsByID` always empty: correct for every
    ///    other field, incomplete for the one field `WorkspaceFilesViewModel`'s slice-rebase path
    ///    needs -- which is exactly why this is armed, not flipped.
    private func startInventoryScopeRepublicationTaskIfNeeded(authority: WorkspaceInventoryScopeAuthority) {
        guard inventoryScopeRepublicationTask == nil else { return }
        let adapter = WorkspaceInventoryScopeRepublicationAdapter { [weak self] rootID in
            await self?.inventoryScopeRepublicationRootInfo(rootID: rootID)
        }
        inventoryScopeRepublicationAdapter = adapter
        inventoryScopeRepublicationTask = Task { [weak self] in
            guard let stream = try? await authority.events() else { return }
            do {
                for try await event in stream {
                    guard let self else { return }
                    guard let republished = await adapter.ingest(event) else { continue }
                    await yieldRepublishedInventoryScopeEvent(republished)
                }
            } catch {
                // Subscription ended (root/scope closed, or a genuine transport error). Nothing
                // downstream depends on this stream in production yet (see this method's header
                // comment), so there is nothing to resync -- the task simply exits.
            }
        }
    }

    private func yieldRepublishedInventoryScopeEvent(_ event: WorkspaceAppliedIndexBatchEvent) {
        for continuation in republishedInventoryScopeEventContinuations.values {
            continuation.yield(event)
        }
    }

    #if DEBUG
        init(
            searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
            debugNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production,
            enableCatalogShardShadowValidation: Bool = true,
            codemapRuntimeProvider: @escaping CodeMapArtifactRuntimeProvider.Factory = {
                try CodeMapArtifactRuntime.processWide()
            },
            codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .production,
            codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe = .production(),
            codemapGraphIndexBuildRetryPolicy: CodemapGraphIndexBuildRetryPolicy = .production,
            codemapGraphIndexBuildLaunchPolicyForTesting: CodemapGraphIndexBuildLaunchPolicyForTesting = .enabled,
            selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
            selectionGraphQueryBudgetPolicy: WorkspaceCodemapAutomaticSelectionBudgetPolicy = .initial,
            automaticSelectionAccountingMaximum: Int = .max,
            codemapDemandRequestHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket
            ) async -> Void = { _ in },
            codemapCancellationCleanupHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket
            ) async -> Void = { _ in },
            codemapReadyPublicationHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket
            ) async -> Void = { _ in },
            codemapGraphPublicationWaiter: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void = { _ in
                try? await Task.sleep(for: .milliseconds(10))
            },
            codemapDemandResultHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket,
                WorkspaceCodemapBindingDemandResult
            ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result },
            codemapAutomaticSelectionQueryHook: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void = { _ in }
        ) {
            storeBackedSearchLane = StoreBackedWorkspaceSearchLane(configuration: searchLaneConfiguration)
            self.debugNowNanoseconds = debugNowNanoseconds
            self.unloadTerminationPolicy = unloadTerminationPolicy
            self.codemapRuntimeProvider = codemapRuntimeProvider
            self.codemapLocalGitClassificationProbe = codemapLocalGitClassificationProbe
            self.codemapGitEligibilityProbe = codemapGitEligibilityProbe
            self.codemapGraphIndexBuildRetryPolicy = codemapGraphIndexBuildRetryPolicy
            self.codemapGraphIndexBuildLaunchPolicyForTesting = codemapGraphIndexBuildLaunchPolicyForTesting
            self.selectionGraphFactory = selectionGraphFactory
            self.selectionGraphQueryBudgetPolicy = selectionGraphQueryBudgetPolicy
            precondition(automaticSelectionAccountingMaximum >= 0)
            self.automaticSelectionAccountingMaximum = automaticSelectionAccountingMaximum
            self.codemapDemandRequestHook = codemapDemandRequestHook
            self.codemapCancellationCleanupHook = codemapCancellationCleanupHook
            self.codemapReadyPublicationHook = codemapReadyPublicationHook
            self.codemapGraphPublicationWaiter = codemapGraphPublicationWaiter
            self.codemapDemandResultHook = codemapDemandResultHook
            self.codemapAutomaticSelectionQueryHook = codemapAutomaticSelectionQueryHook
            isCatalogShardShadowValidationEnabled = enableCatalogShardShadowValidation
            publisherIngressCoordinator = WorkspaceFileSystemIngressCoordinator(debugNowNanoseconds: debugNowNanoseconds)
            #if os(macOS)
                let source = DispatchSource.makeMemoryPressureSource(
                    eventMask: [.warning, .critical],
                    queue: .global(qos: .utility)
                )
                searchContentMemoryPressureSource = source
                source.setEventHandler { [weak self] in
                    Task { await self?.clearSearchDecodedContentCache() }
                }
                source.activate()
            #endif
        }
    #else
        init(
            searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production,
            codemapRuntimeProvider: @escaping CodeMapArtifactRuntimeProvider.Factory = {
                try CodeMapArtifactRuntime.processWide()
            },
            codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .production,
            codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe = .production(),
            codemapGraphIndexBuildRetryPolicy: CodemapGraphIndexBuildRetryPolicy = .production,
            selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
            selectionGraphQueryBudgetPolicy: WorkspaceCodemapAutomaticSelectionBudgetPolicy = .initial,
            automaticSelectionAccountingMaximum: Int = .max,
            codemapDemandRequestHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket
            ) async -> Void = { _ in },
            codemapCancellationCleanupHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket
            ) async -> Void = { _ in },
            codemapReadyPublicationHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket
            ) async -> Void = { _ in },
            codemapGraphPublicationWaiter: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void = { _ in
                try? await Task.sleep(for: .milliseconds(10))
            },
            codemapDemandResultHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket,
                WorkspaceCodemapBindingDemandResult
            ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result },
            codemapAutomaticSelectionQueryHook: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void = { _ in }
        ) {
            storeBackedSearchLane = StoreBackedWorkspaceSearchLane(configuration: searchLaneConfiguration)
            self.unloadTerminationPolicy = unloadTerminationPolicy
            self.codemapRuntimeProvider = codemapRuntimeProvider
            self.codemapLocalGitClassificationProbe = codemapLocalGitClassificationProbe
            self.codemapGitEligibilityProbe = codemapGitEligibilityProbe
            self.codemapGraphIndexBuildRetryPolicy = codemapGraphIndexBuildRetryPolicy
            self.selectionGraphFactory = selectionGraphFactory
            self.selectionGraphQueryBudgetPolicy = selectionGraphQueryBudgetPolicy
            precondition(automaticSelectionAccountingMaximum >= 0)
            self.automaticSelectionAccountingMaximum = automaticSelectionAccountingMaximum
            self.codemapDemandRequestHook = codemapDemandRequestHook
            self.codemapCancellationCleanupHook = codemapCancellationCleanupHook
            self.codemapReadyPublicationHook = codemapReadyPublicationHook
            self.codemapGraphPublicationWaiter = codemapGraphPublicationWaiter
            self.codemapDemandResultHook = codemapDemandResultHook
            self.codemapAutomaticSelectionQueryHook = codemapAutomaticSelectionQueryHook
            publisherIngressCoordinator = WorkspaceFileSystemIngressCoordinator()
            #if os(macOS)
                let source = DispatchSource.makeMemoryPressureSource(
                    eventMask: [.warning, .critical],
                    queue: .global(qos: .utility)
                )
                searchContentMemoryPressureSource = source
                source.setEventHandler { [weak self] in
                    Task { await self?.clearSearchDecodedContentCache() }
                }
                source.activate()
            #endif
        }
    #endif

    deinit {
        #if os(macOS)
            searchContentMemoryPressureSource.cancel()
        #endif
        for session in codemapSessionsByRootEpoch.values {
            session.setupTask?.cancel()
            for demand in session.demandsByFileID.values {
                demand.task?.cancel()
            }
            session.graphStatusTask?.cancel()
            session.graphWorkerRecoveryStatusTask?.cancel()
            for bundle in session.bundlesByRequestID.values {
                bundle.close()
            }
        }
        for flight in codemapCleanupFlightsByRootID.values {
            flight.task.cancel()
        }
        for flight in codemapPathInvalidationFlightsByRootEpoch.values {
            flight.task.cancel()
        }
        for attachment in watcherPublisherAttachmentsByKey.values {
            attachment.cancellable.cancel()
        }
        for flight in watcherInfrastructureFlightsByKey.values {
            flight.task.cancel()
        }
        for continuation in codemapMarkerReadinessContinuations.values {
            continuation.finish()
        }
        for continuation in codemapRootStatusContinuations.values {
            continuation.finish()
        }
        for continuation in fileSystemDeltaContinuations.values {
            continuation.finish()
        }
        for continuation in appliedIndexContinuations.values {
            continuation.finish()
        }
        inventoryScopeRepublicationTask?.cancel()
        for continuation in republishedInventoryScopeEventContinuations.values {
            continuation.finish()
        }
        if let inventoryScopeAuthority {
            Task { await inventoryScopeAuthority.close() }
        }
    }

    func roots() -> [WorkspaceRootRecord] {
        rootLoadOrder.compactMap { rootStatesByID[$0]?.root }
    }

    func rootRecords(forRootFolderPaths rootFolderPaths: [String], includeSystemRoots: Bool = true) -> [WorkspaceRootRecord] {
        let standardizedRootPaths = Set(rootFolderPaths.map { ($0 as NSString).standardizingPath })
        guard !standardizedRootPaths.isEmpty else { return [] }
        return rootLoadOrder.compactMap { rootID in
            guard let root = rootStatesByID[rootID]?.root,
                  standardizedRootPaths.contains(root.standardizedFullPath),
                  includeSystemRoots || !root.isSystemRoot
            else {
                return nil
            }
            return root
        }
    }

    func fileSystemDeltaEvents() -> AsyncStream<WorkspaceFileSystemDeltaEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            fileSystemDeltaContinuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFileSystemDeltaContinuation(id: streamID) }
            }
        }
    }

    private func removeFileSystemDeltaContinuation(id: UUID) {
        fileSystemDeltaContinuations.removeValue(forKey: id)
    }

    func appliedIndexEvents() -> AsyncStream<WorkspaceAppliedIndexBatchEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            appliedIndexContinuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeAppliedIndexContinuation(id: streamID) }
            }
        }
    }

    private func removeAppliedIndexContinuation(id: UUID) {
        appliedIndexContinuations.removeValue(forKey: id)
    }

    /// P4-6b republication arming (design doc §4.3) -- see
    /// `startInventoryScopeRepublicationTaskIfNeeded`'s header comment for why this is a
    /// separate stream from `appliedIndexEvents()` rather than that method's new production
    /// source. No production consumer subscribes to this yet; it exists so the future flip is
    /// "point the two consumers here, delete `publishAppliedIndexEvent`" rather than designing
    /// the translation under cutover time pressure.
    func republishedInventoryScopeEvents() async -> AsyncStream<WorkspaceAppliedIndexBatchEvent> {
        // Deliberately lazy and scoped to this call, not to `inventoryScopeAuthorityInstance()`
        // (a ubiquitous hot path every mutation/read routes through) -- starting a background
        // subscription as a side effect of *every* authority creation would put every test and
        // every production root-load on the hook for this stream's own startup cost/risk even
        // though nothing consumes it yet. Only a caller that actually wants the republished
        // stream pays for it.
        if let authority = try? await inventoryScopeAuthorityInstance() {
            startInventoryScopeRepublicationTaskIfNeeded(authority: authority)
        }
        let streamID = UUID()
        return AsyncStream { continuation in
            republishedInventoryScopeEventContinuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeRepublishedInventoryScopeEventContinuation(id: streamID) }
            }
        }
    }

    private func removeRepublishedInventoryScopeEventContinuation(id: UUID) {
        republishedInventoryScopeEventContinuations.removeValue(forKey: id)
    }

    func startWatchingRoot(id rootID: UUID) async throws {
        let state = try state(for: rootID)
        let key = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
        let demandGeneration = (explicitWatcherDemandGenerationByKey[key] ?? 0) &+ 1
        explicitWatcherDemandGenerationByKey[key] = demandGeneration
        explicitWatcherDemandRootIDs.insert(rootID)
        do {
            try await reconcileAggregateWatcherDemand(rootID: rootID)
        } catch {
            if explicitWatcherDemandGenerationByKey[key] == demandGeneration,
               isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: key.lifetimeID)
            {
                explicitWatcherDemandRootIDs.remove(rootID)
                try? await reconcileAggregateWatcherDemand(rootID: rootID)
            }
            throw error
        }
    }

    private func ensureWatcherInfrastructure(state: RootState, rootID: UUID) async throws {
        let key = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: key.lifetimeID) else {
            throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(state.root.standardizedFullPath)
        }
        if let flight = watcherInfrastructureFlightsByKey[key] {
            #if DEBUG
                if let watcherInfrastructureDidJoinFlightHandler {
                    await watcherInfrastructureDidJoinFlightHandler(rootID, key.lifetimeID)
                }
            #endif
            try await awaitWatcherInfrastructureFlight(flight)
            return
        }

        let flightID = UUID()
        let rootPath = state.root.standardizedFullPath
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                try await performWatcherInfrastructureSetup(key: key, rootPath: rootPath)
                await clearWatcherInfrastructureFlight(key: key, expectedID: flightID)
            } catch {
                await clearWatcherInfrastructureFlight(key: key, expectedID: flightID)
                throw error
            }
        }
        let flight = WatcherInfrastructureFlight(id: flightID, task: task)
        watcherInfrastructureFlightsByKey[key] = flight
        try await awaitWatcherInfrastructureFlight(flight)
    }

    private func awaitWatcherInfrastructureFlight(_ flight: WatcherInfrastructureFlight) async throws {
        let race = WatcherInfrastructureTaskWaitRace()
        Task {
            let result = await flight.task.result
            race.resolve(result)
        }
        try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            race.cancel()
        }
    }

    private func clearWatcherInfrastructureFlight(key: WatcherInfrastructureKey, expectedID: UUID) {
        guard watcherInfrastructureFlightsByKey[key]?.id == expectedID else { return }
        watcherInfrastructureFlightsByKey.removeValue(forKey: key)
    }

    private func performWatcherInfrastructureSetup(
        key: WatcherInfrastructureKey,
        rootPath: String
    ) async throws {
        while true {
            guard let state = rootStatesByID[key.rootID],
                  state.lifetimeID == key.lifetimeID,
                  hasAggregateWatcherDemand(rootID: key.rootID, lifetimeID: key.lifetimeID)
            else {
                throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(rootPath)
            }

            let subscription: WorkspaceFileSystemIngressCoordinator.Subscription
            if let attachment = watcherPublisherAttachmentsByKey[key],
               publisherIngressCoordinator.isPublisherIngressOpen(attachment.subscription)
            {
                subscription = attachment.subscription
            } else {
                watcherPublisherAttachmentsByKey.removeValue(forKey: key)?.cancellable.cancel()
                guard let attachedSubscription = try await attachPublisherIngress(
                    state: state,
                    key: key
                ) else {
                    guard isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID),
                          hasAggregateWatcherDemand(rootID: key.rootID, lifetimeID: key.lifetimeID)
                    else {
                        throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(rootPath)
                    }
                    continue
                }
                subscription = attachedSubscription
            }

            do {
                try await reconcileWatcherServiceState(state.service, rootID: key.rootID)
                await waitForCurrentPublisherIngress(rootIDs: [key.rootID])
            } catch {
                removeWatcherPublisherAttachment(key: key, subscription: subscription)
                if isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID) {
                    try? await reconcileWatcherServiceState(state.service, rootID: key.rootID)
                    await waitForCurrentPublisherIngress(rootIDs: [key.rootID])
                }
                throw error
            }

            guard isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID),
                  hasAggregateWatcherDemand(rootID: key.rootID, lifetimeID: key.lifetimeID)
            else {
                removeWatcherPublisherAttachment(key: key, subscription: subscription)
                if isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID) {
                    try? await reconcileWatcherServiceState(state.service, rootID: key.rootID)
                    await waitForCurrentPublisherIngress(rootIDs: [key.rootID])
                }
                throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(rootPath)
            }
            guard watcherPublisherAttachmentsByKey[key]?.subscription == subscription,
                  publisherIngressCoordinator.isPublisherIngressOpen(subscription)
            else {
                continue
            }
            return
        }
    }

    private func attachPublisherIngress(
        state: RootState,
        key: WatcherInfrastructureKey
    ) async throws -> WorkspaceFileSystemIngressCoordinator.Subscription? {
        guard isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID) else { return nil }
        let root = state.root
        let diagnosticRootToken = state.service.diagnosticRootToken
        let publisherIngressCoordinator = publisherIngressCoordinator
        let subscription = publisherIngressCoordinator.openPublisherIngress(rootID: key.rootID) { [weak self] publication, publicationCorrelation in
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.storeSinkBegan,
                correlation: publicationCorrelation,
                EditFlowPerf.Dimensions(
                    changeCount: publication.deltas.count,
                    rootToken: diagnosticRootToken.uuidString,
                    ingressSequence: publication.watcherAcceptedWatermark?.rawValue,
                    barrierSequence: publication.servicePublicationSequence
                )
            )
            await self?.handleObservedPublisherFileSystemPublication(
                publication,
                root: root,
                expectedLifetimeID: key.lifetimeID,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken
            )
        }
        #if DEBUG
            if let watcherPublisherIngressDidOpenHandler {
                await watcherPublisherIngressDidOpenHandler(key.rootID, key.lifetimeID)
            }
        #endif
        let publisher = await state.service.publisherForChanges()
        guard isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID),
              publisherIngressCoordinator.isPublisherIngressOpen(subscription)
        else {
            publisherIngressCoordinator.closePublisherIngress(subscription)
            return nil
        }
        let cancellable = publisher.sink { publication in
            #if DEBUG || EDIT_FLOW_PERF
                let publicationCorrelation = EditFlowPerf.currentFileSystemPublicationCorrelation
            #else
                let publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil
            #endif
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.storeSinkScheduled,
                correlation: publicationCorrelation,
                EditFlowPerf.Dimensions(
                    changeCount: publication.deltas.count,
                    rootToken: diagnosticRootToken.uuidString,
                    ingressSequence: publication.watcherAcceptedWatermark?.rawValue,
                    barrierSequence: publication.servicePublicationSequence
                )
            )
            publisherIngressCoordinator.accept(
                subscription,
                publication: publication,
                lifecycleCorrelation: publicationCorrelation
            )
        }
        guard isRootLifetimeCurrent(rootID: key.rootID, expectedLifetimeID: key.lifetimeID),
              publisherIngressCoordinator.isPublisherIngressOpen(subscription)
        else {
            cancellable.cancel()
            publisherIngressCoordinator.closePublisherIngress(subscription)
            return nil
        }
        watcherPublisherAttachmentsByKey[key] = WatcherPublisherAttachment(
            subscription: subscription,
            cancellable: cancellable
        )
        return subscription
    }

    /// Opens canonical publisher ingress before subscribing to the hidden
    /// service, preserving the same sink-boundary ordering as published roots.
    private func attachPendingSeededRootPublisherIngress(
        pendingID: WorkspacePendingSeededRootID
    ) async throws -> WatcherPublisherAttachment {
        guard let pending = pendingSeededRootsByID[pendingID] else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        let rootID = pending.state.root.id
        let lifetimeID = pending.state.lifetimeID
        let coordinator = publisherIngressCoordinator
        let subscription = coordinator.openPublisherIngress(rootID: rootID) { [weak self] publication, _ in
            await self?.handlePendingSeededRootPublication(
                publication,
                pendingID: pendingID,
                expectedRootID: rootID,
                expectedLifetimeID: lifetimeID
            )
        }
        let publisher = await pending.state.service.publisherForChanges()
        guard let current = pendingSeededRootsByID[pendingID],
              current.state.root.id == rootID,
              current.state.lifetimeID == lifetimeID,
              coordinator.isPublisherIngressOpen(subscription)
        else {
            coordinator.closePublisherIngress(subscription)
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        let cancellable = publisher.sink { publication in
            coordinator.accept(
                subscription,
                publication: publication,
                lifecycleCorrelation: nil
            )
        }
        guard let current = pendingSeededRootsByID[pendingID],
              current.state.root.id == rootID,
              current.state.lifetimeID == lifetimeID,
              coordinator.isPublisherIngressOpen(subscription)
        else {
            cancellable.cancel()
            coordinator.closePublisherIngress(subscription)
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        return WatcherPublisherAttachment(subscription: subscription, cancellable: cancellable)
    }

    private func handlePendingSeededRootPublication(
        _ publication: FileSystemDeltaPublication,
        pendingID: WorkspacePendingSeededRootID,
        expectedRootID: UUID,
        expectedLifetimeID: UUID
    ) {
        guard var pending = pendingSeededRootsByID[pendingID],
              pending.state.root.id == expectedRootID,
              pending.state.lifetimeID == expectedLifetimeID,
              pending.terminalFallbackReason == nil
        else { return }

        guard case .replaying = pending.phase else {
            if pending.phase == .readyForCommit {
                pending.terminalFallbackReason = .serviceIngressGenerationChanged
                pendingSeededRootsByID[pendingID] = pending
            }
            return
        }

        let expectedSequence = pending.lastAppliedServicePublicationSequence &+ 1
        guard publication.servicePublicationSequence == expectedSequence else {
            pending.terminalFallbackReason = .pendingIngressSequenceGap
            pendingSeededRootsByID[pendingID] = pending
            return
        }
        guard !publication.requiresFullResync,
              publication.source == .watcher || publication.source == .watcherBarrierNoop ||
              publication.source == .authorityTargetedReconcile
        else {
            pending.terminalFallbackReason = switch publication.source {
            case .overflowRootRescan: .watcherOverflow
            case .recoveryFullResync: .watcherRecoveryUncertain
            case .watcher, .watcherBarrierNoop, .syntheticMutation, .authorityTargetedReconcile: .watcherDrop
            }
            pendingSeededRootsByID[pendingID] = pending
            return
        }

        pending.lastAppliedServicePublicationSequence = publication.servicePublicationSequence
        if let watermark = publication.watcherAcceptedWatermark {
            guard watermark >= pending.lastAppliedWatcherWatermark else {
                pending.terminalFallbackReason = .pendingIngressSequenceGap
                pendingSeededRootsByID[pendingID] = pending
                return
            }
            pending.lastAppliedWatcherWatermark = watermark
        }
        pendingSeededRootsByID[pendingID] = pending
    }

    private func removeWatcherPublisherAttachment(
        key: WatcherInfrastructureKey,
        subscription: WorkspaceFileSystemIngressCoordinator.Subscription
    ) {
        if watcherPublisherAttachmentsByKey[key]?.subscription == subscription {
            watcherPublisherAttachmentsByKey.removeValue(forKey: key)?.cancellable.cancel()
        }
        publisherIngressCoordinator.closePublisherIngress(subscription)
    }

    #if DEBUG
        func attachPublisherIngressWithoutStartingWatcherForTesting(rootID: UUID) async throws -> Bool {
            let state = try state(for: rootID)
            let key = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
            if let attachment = watcherPublisherAttachmentsByKey[key],
               publisherIngressCoordinator.isPublisherIngressOpen(attachment.subscription)
            {
                return true
            }
            return try await attachPublisherIngress(state: state, key: key) != nil
        }
    #endif

    func stopWatchingRoot(id rootID: UUID) async {
        if let state = rootStatesByID[rootID] {
            let key = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
            explicitWatcherDemandGenerationByKey[key, default: 0] &+= 1
        }
        explicitWatcherDemandRootIDs.remove(rootID)
        try? await reconcileAggregateWatcherDemand(rootID: rootID)
    }

    func nextSessionWorktreeOwnershipGeneration(ownerID: UUID) -> UInt64 {
        (latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] ?? 0) &+ 1
    }

    private func pendingSeededRootIsCurrent(
        _ pendingID: WorkspacePendingSeededRootID,
        token: WorkspaceSessionWorktreeOwnershipToken,
        standardizedPath: String,
        expectedPhase: WorkspacePendingSeededRootPhase? = nil
    ) -> Bool {
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[token.ownerID] == token.generation,
              let record = sessionWorktreeOwnershipRecordsByToken[token],
              record.pendingSeededRootIDs.contains(pendingID),
              sessionWorktreeReservedPathsByToken[token]?.contains(standardizedPath) == true,
              pendingSeededRootIDsByStandardizedPath[standardizedPath] == pendingID,
              let pending = pendingSeededRootsByID[pendingID],
              pending.token == token,
              pending.standardizedPath == standardizedPath
        else { return false }
        return expectedPhase == nil || pending.phase == expectedPhase
    }

    private func requirePendingSeededRootCurrent(
        _ pendingID: WorkspacePendingSeededRootID,
        token: WorkspaceSessionWorktreeOwnershipToken,
        standardizedPath: String,
        expectedPhase: WorkspacePendingSeededRootPhase? = nil
    ) throws {
        guard pendingSeededRootIsCurrent(
            pendingID,
            token: token,
            standardizedPath: standardizedPath,
            expectedPhase: expectedPhase
        ) else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
    }

    private func installValidatedPendingAuthorityFence(
        _ candidate: GitWorkspacePendingInitializationAuthorityFence,
        pendingID: WorkspacePendingSeededRootID,
        token: WorkspaceSessionWorktreeOwnershipToken,
        standardizedPath: String,
        expectedPhase: WorkspacePendingSeededRootPhase
    ) async throws {
        guard await workspaceStateAuthority.pendingInitializationAuthorityFenceIsCurrent(candidate) else {
            throw GitWorkspaceAuthorityUnavailableReason.superseded
        }
        try requirePendingSeededRootCurrent(
            pendingID,
            token: token,
            standardizedPath: standardizedPath,
            expectedPhase: expectedPhase
        )
        guard workspaceStateAuthority
            .pendingInitializationAuthorityFenceIsSynchronouslyCurrent(candidate),
            var pending = pendingSeededRootsByID[pendingID],
            pending.authorityInvalidationGeneration <= candidate.lease.invalidationGeneration,
            pending.authorityAcceptedMetadataWatermark <= candidate.acceptedMetadataWatermark,
            pending.authorityMutationDepth == 0,
            pending.terminalFallbackReason == nil
        else {
            throw GitWorkspaceAuthorityUnavailableReason.superseded
        }
        pending.authorityFence = candidate
        pending.authorityInvalidationGeneration = candidate.lease.invalidationGeneration
        pending.authorityAcceptedMetadataWatermark = candidate.acceptedMetadataWatermark
        pendingSeededRootsByID[pendingID] = pending
    }

    private func preparePendingSeededRoot(
        token: WorkspaceSessionWorktreeOwnershipToken,
        bindingFingerprint: String,
        standardizedPath: String,
        hint: WorkspaceRootMaterializationHint,
        startupContext: WorktreeStartupContext
    ) async throws -> PendingSeededRootAttempt {
        guard hint.creationReceipt.witnessCoverage.endEventID > 0 else {
            WorktreeStartupInstrumentation.recordSeedReceiptJournalCut(present: false)
            return .fallback(.witnessGap)
        }
        WorktreeStartupInstrumentation.recordSeedReceiptJournalCut(present: true)
        try Task.checkCancellation()
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[token.ownerID] == token.generation,
              sessionWorktreeReservedPathsByToken[token]?.contains(standardizedPath) == true,
              pendingSeededRootIDsByStandardizedPath[standardizedPath] == nil,
              rootIDsByStandardizedPath[standardizedPath] == nil
        else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }

        let service: FileSystemService
        do {
            service = try await FileSystemService(
                path: standardizedPath,
                respectRepoIgnore: true,
                respectCursorignore: true,
                skipSymlinks: true,
                enableHierarchicalIgnores: true
            )
        } catch {
            return .fallback(.watcherActivationFailure)
        }
        try Task.checkCancellation()
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[token.ownerID] == token.generation,
              sessionWorktreeReservedPathsByToken[token]?.contains(standardizedPath) == true
        else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }
        #if DEBUG
            if let watcherActivationFailurePointForNewServicesForTesting {
                await service.setWatcherActivationFailureForTesting(
                    watcherActivationFailurePointForNewServicesForTesting
                )
            }
            await service.setSeededPublicationActivationFailureForTesting(
                seededPublicationActivationShouldFailForTesting
            )
        #endif

        let topology = try makePendingSeededRootTopology(
            standardizedPath: standardizedPath,
            service: service
        )
        // P4-6b reroute: open the Rust root as soon as this root's identity is minted, mirroring
        // the ordinary crawl path (`loadRoot`). Safe to do before the root is Swift-visible --
        // nothing else can reach this freshly-minted `rootID` yet -- and idempotent if this
        // function's second call (`finalTopology`, below) re-opens with the same lifetime id.
        // `discardPendingSeededRoot` closes this binding on every abort/fallback path so a
        // pending attempt that never reaches live publication cannot leak an open Rust root.
        if let authority = try? await inventoryScopeAuthorityInstance() {
            _ = try? await authority.openRootIfNeeded(
                rootID: topology.state.root.id,
                swiftLifetimeID: topology.state.lifetimeID,
                name: topology.state.root.name,
                standardizedFullPath: topology.state.root.standardizedFullPath
            )
        }
        let pendingID = WorkspacePendingSeededRootID()
        let initializationID = FileSystemSeedInitializationID()
        let loadConfiguration = RootLoadConfiguration(
            kind: .sessionWorktree,
            gitignorePolicyIdentity: .current,
            respectRepoIgnore: true,
            respectCursorignore: true,
            skipSymlinks: true,
            enableHierarchicalIgnores: true
        )
        pendingSeededRootsByID[pendingID] = PendingSeededRoot(
            id: pendingID,
            token: token,
            bindingFingerprint: bindingFingerprint,
            standardizedPath: standardizedPath,
            initializationID: initializationID,
            loadConfiguration: loadConfiguration,
            startupContext: startupContext,
            phase: .reserved,
            state: topology.state,
            indexes: topology.indexes,
            captureIdentity: nil,
            authorityFence: nil,
            authorityInvalidationGeneration: 0,
            authorityAcceptedMetadataWatermark: 0,
            authorityMutationDepth: 0,
            snapshot: nil,
            targetPlanHandle: nil,
            authorityClaim: nil,
            attachment: nil,
            rustSeeded: false,
            lastAppliedServicePublicationSequence: 0,
            lastAppliedWatcherWatermark: .zero,
            activationProof: nil,
            terminalFallbackReason: nil
        )
        pendingSeededRootIDsByStandardizedPath[standardizedPath] = pendingID
        try registerPendingSessionWorktreeRoot(
            pendingID,
            standardizedPath: standardizedPath,
            token: token,
            bindingFingerprint: bindingFingerprint
        )

        do {
            let attachment = try await attachPendingSeededRootPublisherIngress(pendingID: pendingID)
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .reserved
            )
            pendingSeededRootsByID[pendingID]?.attachment = attachment

            await ensureSeededAuthorityInvalidationListener()
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .reserved
            )

            let journalCut = FileSystemSeedReplayJournalCut(
                fseventID: FSEventStreamEventId(hint.creationReceipt.witnessCoverage.endEventID)
            )
            let capture = try await service.startWatchingForSeedPreparation(
                since: journalCut,
                initializationID: initializationID
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .reserved
            )
            pendingSeededRootsByID[pendingID]?.captureIdentity = capture
            pendingSeededRootsByID[pendingID]?.lastAppliedWatcherWatermark = capture.initialAcceptedWatermark
            pendingSeededRootsByID[pendingID]?.phase = .watcherCapturing
            WorktreeStartupInstrumentation.record(
                .seedWatcherAttached,
                context: startupContext,
                route: .diffSeedServing
            )

            pendingSeededRootsByID[pendingID]?.phase = .planning
            let planningOutcome = await rootSeedPlanner.planForServing(hint: hint, service: service)
            try Task.checkCancellation()
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .planning
            )
            let planHandle: WorkspaceRootTargetSeedPlanHandle
            let authorityClaim: WorkspaceRootSeedServingAuthorityClaim
            let authorityFence: GitWorkspacePendingInitializationAuthorityFence
            switch planningOutcome {
            case let .fallback(reason):
                await fallBackPendingSeededRoot(
                    pendingID,
                    reason: reason,
                    startupContext: startupContext
                )
                return .fallback(reason)
            case let .planned(handle, claim):
                planHandle = handle
                authorityClaim = claim
                guard let fence = await claim.authorityFence() else {
                    await fallBackPendingSeededRoot(
                        pendingID,
                        reason: .authorityUnstable,
                        startupContext: startupContext
                    )
                    return .fallback(.authorityUnstable)
                }
                // Record the coordinator claim before the awaited fence
                // validation can publish its non-owning fence value into
                // pending state. Abort cleanup must never mistake that shared
                // value for a store-owned lease.
                pendingSeededRootsByID[pendingID]?.authorityClaim = claim
                let validatedFence = try await claim.validatePendingAuthorityFence(
                    replacing: fence
                )
                authorityFence = validatedFence
                try await installValidatedPendingAuthorityFence(
                    validatedFence,
                    pendingID: pendingID,
                    token: token,
                    standardizedPath: standardizedPath,
                    expectedPhase: .planning
                )
            }

            let snapshot = planHandle.snapshot
            guard snapshot.compatibilityKey == hint.creationReceipt.parentCompatibilityKey else {
                await fallBackPendingSeededRoot(
                    pendingID,
                    reason: .compatibilityMismatch,
                    startupContext: startupContext
                )
                return .fallback(.compatibilityMismatch)
            }
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .planning
            )
            pendingSeededRootsByID[pendingID]?.snapshot = snapshot
            pendingSeededRootsByID[pendingID]?.targetPlanHandle = planHandle

            let inventory = try await service.prepareSeededInventory(
                planHandle: planHandle,
                initializationID: initializationID
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .planning
            )
            try await service.installSeededInventory(inventory)
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .planning
            )
            pendingSeededRootsByID[pendingID]?.phase = .seedInstalled

            let replayCut = try await service.captureSeedReplayAcceptedWatermark(
                initializationID: initializationID
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .seedInstalled
            )
            pendingSeededRootsByID[pendingID]?.phase = .replaying(replayCut)
            let replay = try await service.flushSeedReplay(
                through: replayCut,
                initializationID: initializationID
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .replaying(replayCut)
            )
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: topology.state.root.id,
                servicePublicationSequence: replay.finalServicePublicationSequence
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .replaying(replayCut)
            )
            guard let reconciled = pendingSeededRootsByID[pendingID],
                  reconciled.terminalFallbackReason == nil,
                  reconciled.lastAppliedServicePublicationSequence == replay.finalServicePublicationSequence,
                  reconciled.lastAppliedWatcherWatermark >= replay.requestedAcceptedWatermark
            else {
                let reason = pendingSeededRootsByID[pendingID]?.terminalFallbackReason
                    ?? .pendingIngressSequenceGap
                await fallBackPendingSeededRoot(
                    pendingID,
                    reason: reason,
                    startupContext: startupContext
                )
                return .fallback(reason)
            }
            guard !replay.ignoreControlPathsChanged else {
                await fallBackPendingSeededRoot(
                    pendingID,
                    reason: .changedIgnoreAuthority,
                    startupContext: startupContext
                )
                return .fallback(.changedIgnoreAuthority)
            }
            WorktreeStartupInstrumentation.record(
                .seedReplayFenced,
                context: startupContext,
                route: .diffSeedServing
            )
            WorktreeStartupInstrumentation.recordSeedReplay(
                acceptedPayloadCount: replay.acceptedPayloadCount,
                acceptedEventCount: replay.acceptedEventCount,
                initializationWatermarkDelta: Int(
                    replay.requestedAcceptedWatermark.rawValue
                        &- capture.initialAcceptedWatermark.rawValue
                ),
                serviceSequenceDelta: Int(replay.finalServicePublicationSequence),
                changedPathCount: replay.changedRelativePaths.count
            )

            let validatedFence = try await authorityClaim.validatePendingAuthorityFence(
                replacing: authorityFence
            )
            try await installValidatedPendingAuthorityFence(
                validatedFence,
                pendingID: pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .replaying(replayCut)
            )
            WorktreeStartupInstrumentation.recordSeedMetadataRevalidation(
                used: validatedFence.revalidationUsed
            )
            try requirePendingSeededRootCurrent(
                pendingID,
                token: token,
                standardizedPath: standardizedPath,
                expectedPhase: .replaying(replayCut)
            )

            pendingSeededRootsByID[pendingID]?.phase = .preparingShard
            let finalTopology = try makePendingSeededRootTopology(
                standardizedPath: standardizedPath,
                service: service,
                inventorySnapshot: replay.inventorySnapshot,
                root: topology.state.root,
                lifetimeID: topology.state.lifetimeID
            )
            let components = buildPendingCatalogComponents(
                root: finalTopology.state.root,
                indexes: finalTopology.indexes
            )
            #if DEBUG
                if seededShardPreparationShouldFailForTesting {
                    await fallBackPendingSeededRoot(
                        pendingID,
                        reason: .seededShardPreparationFailure,
                        startupContext: startupContext
                    )
                    return .fallback(.seededShardPreparationFailure)
                }
            #endif
            // P4-6b reroute, P4-7c c1 update: `WorkspaceSeededRootReplayValidator.evaluate` (no
            // C-engine dependency, `Models/WorkspaceSeededRootReplayVerdict.swift`) is kept purely
            // for its validation side effect -- it is the diff-seeded fast path's own correctness
            // self-check (replayed diff vs. cached base snapshot), not a search-index nicety. A
            // `.disagrees` verdict means the replay disagreed with the snapshot and must fall back
            // to the ordinary full crawl, exactly as before this reroute. No index object is ever
            // constructed on this path any more -- Rust builds its own path-search index
            // internally from the seeded records below (contract doc §5.2/§11; the already-ported
            // orchestration in `rust/crates/runtime/src/inventory_scope/path_index/`), so no
            // Swift-side `WorkspaceSearchRootPathIndex`/`RootCatalogShard` is constructed for this
            // root.
            guard case let .agrees(replayStatistics) = WorkspaceSeededRootReplayValidator.evaluate(
                snapshot: snapshot,
                planHandle: planHandle,
                additionalChangedRelativePaths: replay.changedRelativePaths,
                root: finalTopology.state.root,
                authoritativeEntries: components.entries
            ) else {
                await fallBackPendingSeededRoot(
                    pendingID,
                    reason: .seededShardPreparationFailure,
                    startupContext: startupContext
                )
                return .fallback(.seededShardPreparationFailure)
            }
            // Seed Rust with the validated record set via the same per-item discovery choke
            // points (`indexFolder`/`indexFile`) the live watcher-driven crawl path already uses
            // -- not a bulk-discovery call, because a single fresh root's folders can reference
            // sibling folders minted in the same batch, and the per-item path's recursive
            // `ensureRustFolderID` walk already resolves that correctly and is proven in
            // production. Folders first (order does not matter for correctness -- ancestors are
            // minted on demand -- only for avoiding redundant lookups).
            for folder in components.folders {
                await indexFolder(relativePath: folder.relativePath, root: finalTopology.state.root)
            }
            for file in components.files {
                await indexFile(relativePath: file.relativePath, root: finalTopology.state.root)
            }
            guard var ready = pendingSeededRootsByID[pendingID],
                  ready.phase == .preparingShard,
                  ready.state.root.id == topology.state.root.id,
                  ready.state.lifetimeID == topology.state.lifetimeID
            else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }

            ready.state = finalTopology.state
            ready.indexes = finalTopology.indexes
            ready.targetPlanHandle = nil
            ready.rustSeeded = true
            ready.phase = .readyForCommit
            pendingSeededRootsByID[pendingID] = ready
            WorktreeStartupInstrumentation.recordSeedProjectedPreparation(
                baseEntryCount: replayStatistics.baseEntryCount,
                overlayEntryCount: replayStatistics.overlayEntryCount,
                tombstoneCount: replayStatistics.tombstoneCount
            )
            WorktreeStartupInstrumentation.record(
                .seedReadyForCommit,
                context: startupContext,
                route: .diffSeedServing
            )
            #if DEBUG
                if let pendingSeededRootDidBecomeReadyHandler {
                    await pendingSeededRootDidBecomeReadyHandler(standardizedPath)
                    try requirePendingSeededRootCurrent(
                        pendingID,
                        token: token,
                        standardizedPath: standardizedPath,
                        expectedPhase: .readyForCommit
                    )
                }
            #endif
            return .prepared(WorkspacePendingSeededRootPreparation(id: pendingID))
        } catch is CancellationError {
            await abortPendingSeededRoots([pendingID])
            throw CancellationError()
        } catch let error as WorkspaceSessionWorktreeOwnershipError {
            await abortPendingSeededRoots([pendingID])
            throw error
        } catch let error as FileSystemWatcherActivationError {
            await fallBackPendingSeededRoot(
                pendingID,
                reason: .watcherActivationFailure,
                startupContext: startupContext
            )
            _ = error
            return .fallback(.watcherActivationFailure)
        } catch let error as FileSystemSeedReplayError {
            let reason: WorkspaceRootSeedFallbackReason = switch error {
            case .mailboxOverflow: .watcherOverflow
            case .unsafeEventFlags: .watcherDrop
            case .recoveryRequired, .fullResyncRequired: .watcherRecoveryUncertain
            case .acceptedWatermarkGap, .requestedWatermarkNotPublished,
                 .watcherIngressChanged, .watcherNotActive,
                 .requestedWatermarkPredatesCapture, .requestedWatermarkNotYetAccepted:
                .pendingIngressSequenceGap
            case .invalidJournalCut: .witnessGap
            case .watcherActivationTimedOut: .watcherActivationFailure
            case .watcherAlreadyActive, .initializationAlreadyActive,
                 .initializationNotCurrent, .inventoryNotInstalled,
                 .invalidSeedInventoryPath, .replayAlreadyCompleted:
                .serviceIngressGenerationChanged
            }
            await fallBackPendingSeededRoot(
                pendingID,
                reason: reason,
                startupContext: startupContext
            )
            return .fallback(reason)
        } catch {
            await fallBackPendingSeededRoot(
                pendingID,
                reason: .authorityUnstable,
                startupContext: startupContext
            )
            return .fallback(.authorityUnstable)
        }
    }

    private func ensureSeededAuthorityInvalidationListener() async {
        guard seededAuthorityInvalidationListenerTask == nil else { return }
        let events = await workspaceStateAuthority.invalidationEvents()
        seededAuthorityInvalidationListenerTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handleSeededAuthorityInvalidation(event)
            }
        }
    }

    private func handleSeededAuthorityInvalidation(
        _ event: GitWorkspaceAuthorityInvalidationEvent
    ) {
        let affectedPendingIDs = pendingSeededRootsByID.compactMap { pendingID, pending in
            pending.authorityFence?.repositoryKey == event.repositoryKey ? pendingID : nil
        }
        for pendingID in affectedPendingIDs {
            guard var pending = pendingSeededRootsByID[pendingID] else { continue }
            pending.authorityInvalidationGeneration = max(
                pending.authorityInvalidationGeneration,
                event.invalidationGeneration
            )
            pending.authorityAcceptedMetadataWatermark = max(
                pending.authorityAcceptedMetadataWatermark,
                event.acceptedMetadataWatermark
            )
            switch event.kind {
            case .mutationBegan:
                pending.authorityMutationDepth += 1
            case .mutationCompleted:
                pending.authorityMutationDepth = max(0, pending.authorityMutationDepth - 1)
            case .metadata:
                break
            }
            pendingSeededRootsByID[pendingID] = pending
        }

        let affectedRootIDs = publishedSeededAuthorityFencesByRootID.compactMap { rootID, fence in
            fence.repositoryKey == event.repositoryKey ? rootID : nil
        }
        for rootID in affectedRootIDs {
            var state = publishedSeededAuthorityStatesByRootID[rootID] ?? PublishedSeededAuthorityState(
                epoch: 0,
                pendingInvalidationGeneration: nil,
                pendingAcceptedMetadataWatermark: 0,
                activeMutationDepth: 0,
                isBlocked: false,
                isReconciling: false,
                reconciliationFailed: false,
                fullCrawlAttemptedGeneration: nil,
                fullCrawlCompletedGeneration: nil
            )
            let wasBlocked = state.isBlocked
            state.epoch &+= 1
            state.pendingInvalidationGeneration = max(
                state.pendingInvalidationGeneration ?? 0,
                event.invalidationGeneration
            )
            state.pendingAcceptedMetadataWatermark = max(
                state.pendingAcceptedMetadataWatermark,
                event.acceptedMetadataWatermark
            )
            state.isBlocked = true
            state.reconciliationFailed = false
            switch event.kind {
            case .mutationBegan:
                state.activeMutationDepth += 1
            case .mutationCompleted:
                state.activeMutationDepth = max(0, state.activeMutationDepth - 1)
            case .metadata:
                break
            }
            publishedSeededAuthorityStatesByRootID[rootID] = state
            if !wasBlocked, let root = rootStatesByID[rootID]?.root {
                invalidatePathMatchSnapshot(
                    affectedRootKinds: [root.kind],
                    reason: .catalogMutation,
                    affectedRootIDs: [rootID]
                )
            }
            seededAuthorityPendingGenerationByRootID[rootID] = max(
                seededAuthorityPendingGenerationByRootID[rootID] ?? 0,
                event.invalidationGeneration
            )
            schedulePublishedSeededAuthorityReconciliationIfPossible(rootID: rootID)
        }
    }

    private func schedulePublishedSeededAuthorityReconciliationIfPossible(rootID: UUID) {
        guard publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth == 0,
              seededAuthorityReconciliationTasksByRootID[rootID] == nil,
              seededAuthorityPendingGenerationByRootID[rootID] != nil
        else { return }
        seededAuthorityReconciliationTasksByRootID[rootID] = Task { [weak self] in
            await self?.reconcilePublishedSeededAuthority(rootID: rootID)
        }
    }

    private func reconcilePublishedSeededAuthority(rootID: UUID) async {
        while let capturedGeneration = seededAuthorityPendingGenerationByRootID[rootID],
              let fence = publishedSeededAuthorityFencesByRootID[rootID],
              let authorityClaim = publishedSeededAuthorityClaimsByRootID[rootID],
              let state = rootStatesByID[rootID]
        {
            guard publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth == 0 else { break }
            seededAuthorityPendingGenerationByRootID.removeValue(forKey: rootID)
            publishedSeededAuthorityStatesByRootID[rootID]?.isReconciling = true
            do {
                let replacement = try await authorityClaim
                    .recapturePublishedAuthorityFence(replacing: fence)
                guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: state.lifetimeID),
                      publishedSeededAuthorityFencesByRootID[rootID] == fence,
                      publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth == 0,
                      seededAuthorityPendingGenerationByRootID[rootID].map({ $0 > capturedGeneration }) != true,
                      await workspaceStateAuthority.pendingInitializationAuthorityFenceIsCurrent(replacement),
                      workspaceStateAuthority
                      .pendingInitializationAuthorityFenceIsSynchronouslyCurrent(replacement)
                else {
                    continue
                }

                if replacement.snapshot != fence.snapshot {
                    guard await reconcilePublishedSeededAuthorityChange(
                        rootID: rootID,
                        state: state,
                        base: fence,
                        replacement: replacement,
                        capturedGeneration: capturedGeneration
                    ) else {
                        failPublishedSeededAuthorityReconciliation(rootID: rootID, state: state)
                        break
                    }
                    guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: state.lifetimeID),
                          publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth == 0,
                          seededAuthorityPendingGenerationByRootID[rootID].map({ $0 > capturedGeneration }) != true,
                          await workspaceStateAuthority.pendingInitializationAuthorityFenceIsCurrent(replacement),
                          workspaceStateAuthority
                          .pendingInitializationAuthorityFenceIsSynchronouslyCurrent(replacement)
                    else {
                        continue
                    }
                }
                publishedSeededAuthorityFencesByRootID[rootID] = replacement
                markPublishedSeededAuthorityCurrent(rootID: rootID)
            } catch {
                if await workspaceStateAuthority.collectionMutationFenceReason(
                    for: fence.repositoryKey
                ) != nil {
                    seededAuthorityPendingGenerationByRootID[rootID] = max(
                        seededAuthorityPendingGenerationByRootID[rootID] ?? 0,
                        capturedGeneration
                    )
                    publishedSeededAuthorityStatesByRootID[rootID]?.isBlocked = true
                    break
                }
                guard publishedSeededAuthorityStatesByRootID[rootID]?.activeMutationDepth == 0 else { break }
                if publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlAttemptedGeneration == nil,
                   isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: state.lifetimeID)
                {
                    publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlAttemptedGeneration = capturedGeneration
                    #if DEBUG
                        publishedSeededAuthorityFullCrawlCountsByRootID[rootID, default: 0] += 1
                    #endif
                    if await state.service.reconcileEntireTreeForAuthorityChange() {
                        publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlCompletedGeneration = capturedGeneration
                    }
                    await waitForCurrentPublisherIngress(rootIDs: [rootID])
                }
                if await retirePublishedSeededAuthorityAfterUnifiedFullCrawl(rootID: rootID, state: state) {
                    break
                }
                failPublishedSeededAuthorityReconciliation(rootID: rootID, state: state)
                break
            }
            guard seededAuthorityPendingGenerationByRootID[rootID].map({ $0 > capturedGeneration }) == true else {
                break
            }
        }
        seededAuthorityReconciliationTasksByRootID.removeValue(forKey: rootID)
        publishedSeededAuthorityStatesByRootID[rootID]?.isReconciling = false
        schedulePublishedSeededAuthorityReconciliationIfPossible(rootID: rootID)
    }

    private func markPublishedSeededAuthorityCurrent(rootID: UUID) {
        guard var authority = publishedSeededAuthorityStatesByRootID[rootID] else { return }
        authority.pendingInvalidationGeneration = nil
        authority.isBlocked = false
        authority.isReconciling = false
        authority.reconciliationFailed = false
        authority.fullCrawlAttemptedGeneration = nil
        authority.fullCrawlCompletedGeneration = nil
        publishedSeededAuthorityStatesByRootID[rootID] = authority
        resumePublishedSeededAuthorityWaiters(rootID: rootID, error: nil)
    }

    private enum PublishedSeededAuthorityReconcilePlan {
        case adoptWithoutScan
        case targetedFolders(folders: Set<String>, modifiedFiles: Set<String>)
        case fullCrawl
    }

    private func reconcilePublishedSeededAuthorityChange(
        rootID: UUID,
        state: RootState,
        base: GitWorkspacePendingInitializationAuthorityFence,
        replacement: GitWorkspacePendingInitializationAuthorityFence,
        capturedGeneration: UInt64
    ) async -> Bool {
        let plan = await publishedSeededAuthorityReconcilePlan(
            base: base,
            replacement: replacement
        )
        switch plan {
        case .adoptWithoutScan:
            return true
        case let .targetedFolders(folders, modifiedFiles):
            guard await state.service.reconcileFoldersForAuthorityChange(
                folders: folders,
                modifiedFiles: modifiedFiles
            ) else {
                return await reconcileEntireTreeForPublishedAuthorityChange(
                    rootID: rootID,
                    state: state,
                    capturedGeneration: capturedGeneration
                )
            }
            await waitForCurrentPublisherIngress(rootIDs: [rootID])
            return true
        case .fullCrawl:
            return await reconcileEntireTreeForPublishedAuthorityChange(
                rootID: rootID,
                state: state,
                capturedGeneration: capturedGeneration
            )
        }
    }

    private func reconcileEntireTreeForPublishedAuthorityChange(
        rootID: UUID,
        state: RootState,
        capturedGeneration: UInt64
    ) async -> Bool {
        guard publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlAttemptedGeneration == nil else {
            return false
        }
        publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlAttemptedGeneration = capturedGeneration
        #if DEBUG
            publishedSeededAuthorityFullCrawlCountsByRootID[rootID, default: 0] += 1
        #endif
        guard await state.service.reconcileEntireTreeForAuthorityChange() else { return false }
        publishedSeededAuthorityStatesByRootID[rootID]?.fullCrawlCompletedGeneration = capturedGeneration
        await waitForCurrentPublisherIngress(rootIDs: [rootID])
        return true
    }

    private func publishedSeededAuthorityReconcilePlan(
        base: GitWorkspacePendingInitializationAuthorityFence,
        replacement: GitWorkspacePendingInitializationAuthorityFence
    ) async -> PublishedSeededAuthorityReconcilePlan {
        let baseSnapshot = base.snapshot
        let replacementSnapshot = replacement.snapshot
        guard publishedSeededAuthoritySnapshotsShareTargetedReconcileEnvelope(baseSnapshot, replacementSnapshot),
              base.targetLayout == replacement.targetLayout,
              base.repositoryRelativeRootPrefix == replacement.repositoryRelativeRootPrefix
        else {
            return .fullCrawl
        }
        guard baseSnapshot.treeOID != replacementSnapshot.treeOID else {
            // Tree-identical authority churn (for example index-only invalidation) does not
            // require filesystem reconciliation. Any same-tree working-tree writes must still
            // arrive through the live watcher, matching ordinary edit freshness semantics.
            return .adoptWithoutScan
        }
        do {
            let deltas = try await worktreeSeedGitService.diffTrees(
                baseTreeOID: baseSnapshot.treeOID,
                targetTreeOID: replacementSnapshot.treeOID,
                in: replacement.targetLayout,
                prefix: replacement.repositoryRelativeRootPrefix
            )
            guard let target = targetedAuthorityReconcileTarget(
                from: deltas,
                prefix: replacement.repositoryRelativeRootPrefix
            ) else {
                return .fullCrawl
            }
            return target.folders.isEmpty && target.modifiedFiles.isEmpty
                ? .adoptWithoutScan
                : .targetedFolders(folders: target.folders, modifiedFiles: target.modifiedFiles)
        } catch {
            return .fullCrawl
        }
    }

    private func publishedSeededAuthoritySnapshotsShareTargetedReconcileEnvelope(
        _ base: GitWorkspaceAuthoritySnapshot,
        _ target: GitWorkspaceAuthoritySnapshot
    ) -> Bool {
        base.repositoryKey == target.repositoryKey
            && base.repositoryNamespace == target.repositoryNamespace
            && base.objectFormat == target.objectFormat
            && base.repositoryRelativeRootPrefix == target.repositoryRelativeRootPrefix
            && base.repositoryBindingEpoch == target.repositoryBindingEpoch
            && base.layoutGeneration == target.layoutGeneration
            && base.checkoutConfigurationGeneration == target.checkoutConfigurationGeneration
            && base.policyIdentity == target.policyIdentity
    }

    private func targetedAuthorityReconcileTarget(
        from deltas: [GitTreeDeltaRecord],
        prefix: GitRepositoryRelativeRootPrefix
    ) -> (folders: Set<String>, modifiedFiles: Set<String>)? {
        var folders = Set<String>()
        var modifiedFiles = Set<String>()
        for delta in deltas {
            if delta.oldMode == "160000" || delta.newMode == "160000" {
                return nil
            }
            switch delta.status {
            case .added, .deleted, .renamed, .copied:
                break
            case .modified:
                guard let rootRelativePath = rootRelativePath(
                    delta.repositoryRelativePath,
                    prefix: prefix
                ) else { return nil }
                if targetedAuthorityReconcileRequiresFullCrawl(rootRelativePath) {
                    return nil
                }
                modifiedFiles.insert(rootRelativePath)
            case .typeChanged, .unmerged:
                return nil
            }
            guard collectTargetedAuthorityReconcileFolder(
                repositoryRelativePath: delta.repositoryRelativePath,
                prefix: prefix,
                into: &folders
            ) else {
                return nil
            }
            if let source = delta.sourceRepositoryRelativePath {
                guard collectTargetedAuthorityReconcileFolder(
                    repositoryRelativePath: source,
                    prefix: prefix,
                    into: &folders
                ) else {
                    return nil
                }
            }
        }
        return (folders, modifiedFiles)
    }

    private func collectTargetedAuthorityReconcileFolder(
        repositoryRelativePath: String,
        prefix: GitRepositoryRelativeRootPrefix,
        into folders: inout Set<String>
    ) -> Bool {
        guard let rootRelativePath = rootRelativePath(
            repositoryRelativePath,
            prefix: prefix
        ) else {
            return false
        }
        if rootRelativePath.isEmpty {
            folders.insert("")
            return true
        }
        if targetedAuthorityReconcileRequiresFullCrawl(rootRelativePath) {
            return false
        }
        collectAuthorityReconcileAncestorFolders(for: rootRelativePath, into: &folders)
        return true
    }

    private func collectAuthorityReconcileAncestorFolders(
        for rootRelativePath: String,
        into folders: inout Set<String>
    ) {
        var folder = authorityReconcileParentDirectory(of: rootRelativePath)
        while true {
            folders.insert(folder)
            guard !folder.isEmpty else { return }
            folder = authorityReconcileParentDirectory(of: folder)
        }
    }

    private func authorityReconcileParentDirectory(of relativePath: String) -> String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private func rootRelativePath(
        _ repositoryRelativePath: String,
        prefix: GitRepositoryRelativeRootPrefix
    ) -> String? {
        let prefixValue = prefix.value
        guard !prefixValue.isEmpty else { return repositoryRelativePath }
        guard repositoryRelativePath == prefixValue || repositoryRelativePath.hasPrefix(prefixValue + "/") else {
            return nil
        }
        if repositoryRelativePath == prefixValue { return "" }
        return String(repositoryRelativePath.dropFirst(prefixValue.count + 1))
    }

    private func targetedAuthorityReconcileRequiresFullCrawl(_ rootRelativePath: String) -> Bool {
        let components = rootRelativePath.split(separator: "/")
        return components.contains { component in
            component == ".gitignore"
                || component == ".gitattributes"
                || component == ".worktreeinclude"
                || component == ".repo_ignore"
                || component == ".cursorignore"
        }
    }

    private func retirePublishedSeededAuthorityAfterUnifiedFullCrawl(
        rootID: UUID,
        state: RootState
    ) async -> Bool {
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: state.lifetimeID),
              let authority = publishedSeededAuthorityStatesByRootID[rootID],
              authority.activeMutationDepth == 0,
              authority.fullCrawlCompletedGeneration != nil
        else { return false }

        seededAuthorityPendingGenerationByRootID.removeValue(forKey: rootID)
        let claim = publishedSeededAuthorityClaimsByRootID.removeValue(forKey: rootID)
        let fence = publishedSeededAuthorityFencesByRootID.removeValue(forKey: rootID)
        publishedSeededAuthorityStatesByRootID.removeValue(forKey: rootID)
        resumePublishedSeededAuthorityWaiters(rootID: rootID, error: nil)
        if let claim {
            await claim.release()
        } else if let fence {
            await workspaceStateAuthority.releasePendingInitializationAuthorityFence(fence)
        }
        return true
    }

    private func failPublishedSeededAuthorityReconciliation(rootID: UUID, state: RootState) {
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: state.lifetimeID),
              var authority = publishedSeededAuthorityStatesByRootID[rootID]
        else { return }
        authority.isBlocked = true
        authority.isReconciling = false
        authority.reconciliationFailed = true
        publishedSeededAuthorityStatesByRootID[rootID] = authority
        resumePublishedSeededAuthorityWaiters(
            rootID: rootID,
            error: WorkspaceSessionWorktreeOwnershipError.unavailableRoot(state.root.standardizedFullPath)
        )
    }

    private func publishedSeededAuthorityIsQueryable(rootID: UUID) -> Bool {
        guard let fence = publishedSeededAuthorityFencesByRootID[rootID] else { return true }
        guard let state = publishedSeededAuthorityStatesByRootID[rootID],
              !state.isBlocked,
              !state.reconciliationFailed
        else { return false }
        return workspaceStateAuthority.pendingInitializationAuthorityFenceIsSynchronouslyCurrent(fence)
    }

    private func requirePublishedSeededAuthorityFresh(rootID: UUID) async throws {
        while publishedSeededAuthorityFencesByRootID[rootID] != nil {
            if publishedSeededAuthorityIsQueryable(rootID: rootID) { return }
            guard let state = publishedSeededAuthorityStatesByRootID[rootID],
                  !state.reconciliationFailed,
                  state.isBlocked
            else {
                let path = rootStatesByID[rootID]?.root.standardizedFullPath ?? rootID.uuidString
                throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(path)
            }
            let waiterID = UUID()
            let _: Void = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    publishedSeededAuthorityWaitersByRootID[rootID, default: [:]][waiterID] = continuation
                }
            } onCancel: {
                Task { await self.cancelPublishedSeededAuthorityWaiter(rootID: rootID, waiterID: waiterID) }
            }
        }
    }

    private func cancelPublishedSeededAuthorityWaiter(rootID: UUID, waiterID: UUID) {
        guard let continuation = publishedSeededAuthorityWaitersByRootID[rootID]?
            .removeValue(forKey: waiterID)
        else { return }
        if publishedSeededAuthorityWaitersByRootID[rootID]?.isEmpty == true {
            publishedSeededAuthorityWaitersByRootID.removeValue(forKey: rootID)
        }
        continuation.resume(throwing: CancellationError())
    }

    private func resumePublishedSeededAuthorityWaiters(rootID: UUID, error: Error?) {
        let waiters = publishedSeededAuthorityWaitersByRootID.removeValue(forKey: rootID) ?? [:]
        for continuation in waiters.values {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private func fallBackPendingSeededRoot(
        _ pendingID: WorkspacePendingSeededRootID,
        reason: WorkspaceRootSeedFallbackReason,
        startupContext: WorktreeStartupContext
    ) async {
        guard var pending = pendingSeededRootsByID[pendingID] else { return }
        if case .fallingBack = pending.phase { return }
        pending.phase = .fallingBack(reason)
        pending.terminalFallbackReason = pending.terminalFallbackReason ?? reason
        pendingSeededRootsByID[pendingID] = pending
        WorktreeStartupInstrumentation.record(
            .seedFallback,
            context: startupContext,
            route: .diffSeedServing,
            fallback: reason
        )
        WorktreeStartupInstrumentation.recordSeedFullCrawlFallback()
        await discardPendingSeededRoot(pendingID, terminalPhase: .aborted)
    }

    private func abortPendingSeededRoots(_ pendingIDs: [WorkspacePendingSeededRootID]) async {
        for pendingID in pendingIDs {
            await discardPendingSeededRoot(pendingID, terminalPhase: .aborted)
        }
    }

    private func discardPendingSeededRoot(
        _ pendingID: WorkspacePendingSeededRootID,
        terminalPhase: WorkspacePendingSeededRootPhase
    ) async {
        guard var pending = pendingSeededRootsByID[pendingID] else { return }
        pending.phase = terminalPhase
        pendingSeededRootsByID[pendingID] = pending
        await pending.state.service.abortSeededPreparation(initializationID: pending.initializationID)
        pending.attachment?.cancellable.cancel()
        if let subscription = pending.attachment?.subscription {
            publisherIngressCoordinator.closePublisherIngress(subscription)
            await publisherIngressCoordinator.waitForCurrentPublisherIngress(rootIDs: [pending.state.root.id])
        }
        if let authorityClaim = pending.authorityClaim {
            await authorityClaim.release()
        } else if let fence = pending.authorityFence {
            await worktreeSeedGitService.releasePendingInitializationAuthorityFence(fence)
        }
        // P4-6b reroute: this pending root's Rust binding (opened eagerly in
        // `preparePendingSeededRoot` so the validated replay could be seeded into it) never
        // reaches the live-publication critical section on an abort/fallback -- close it here so
        // a discarded attempt cannot leak an open root in `WorkspaceInventoryScopeAuthority`.
        // `discardPendingSeededRoot` is the single funnel point for both `abortPendingSeededRoots`
        // and `fallBackPendingSeededRoot`.
        if let authority = try? await inventoryScopeAuthorityInstance() {
            await authority.closeRoot(rootID: pending.state.root.id)
        }
        pendingSeededRootsByID.removeValue(forKey: pendingID)
        if pendingSeededRootIDsByStandardizedPath[pending.standardizedPath] == pendingID {
            pendingSeededRootIDsByStandardizedPath.removeValue(forKey: pending.standardizedPath)
        }
        finishPendingSeededRootVisibility(path: pending.standardizedPath)
        if let record = sessionWorktreeOwnershipRecordsByToken[pending.token] {
            sessionWorktreeOwnershipRecordsByToken[pending.token] = SessionWorktreeOwnershipRecord(
                bindingFingerprint: record.bindingFingerprint,
                roots: record.roots,
                pendingSeededRootIDs: record.pendingSeededRootIDs.filter { $0 != pendingID }
            )
        }
    }

    func prepareSessionWorktreeOwnership(
        ownerID: UUID,
        bindingFingerprint: String,
        physicalRootPaths: [String],
        startupContext: WorktreeStartupContext? = nil,
        initializationHintsByPhysicalRootPath: [String: WorkspaceRootMaterializationHint] = [:]
    ) async throws -> WorkspaceSessionWorktreeOwnershipPreparation {
        #if DEBUG
            var receiptConsumptionDecision = WorktreeStartupInstrumentation.ReceiptConsumptionDecision()
        #endif
        let standardizedPaths = Array(Set(physicalRootPaths.map {
            StandardizedPath.absolute(($0 as NSString).expandingTildeInPath)
        })).sorted()
        if let installedToken = installedSessionWorktreeOwnershipTokenByOwnerID[ownerID],
           let installedRecord = sessionWorktreeOwnershipRecordsByToken[installedToken],
           installedRecord.bindingFingerprint == bindingFingerprint,
           installedRecord.roots.map(\.standardizedPhysicalPath).sorted() == standardizedPaths,
           sessionWorktreeOwnershipRecordIsCurrent(installedRecord)
        {
            #if DEBUG
                if let startupContext {
                    receiptConsumptionDecision.ownershipReused = true
                    receiptConsumptionDecision.finalObservation = .disabled
                    WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                        correlationID: startupContext.correlationID,
                        decision: receiptConsumptionDecision
                    )
                }
            #endif
            return WorkspaceSessionWorktreeOwnershipPreparation(
                token: installedToken,
                bindingFingerprint: bindingFingerprint,
                roots: installedRecord.roots,
                reusesInstalledOwnership: true
            )
        }

        let generation = (latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] ?? 0) &+ 1
        #if DEBUG
            receiptConsumptionDecision.ownershipReused = false
        #endif
        latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] = generation
        let installedToken = installedSessionWorktreeOwnershipTokenByOwnerID[ownerID]
        let token = WorkspaceSessionWorktreeOwnershipToken(ownerID: ownerID, generation: generation)
        let supersededTokens = sessionWorktreeOwnershipRecordsByToken.keys.filter {
            $0.ownerID == ownerID && $0 != installedToken
        }
        var supersededResources = SessionWorktreeOwnershipRemoval()
        for supersededToken in supersededTokens {
            supersededResources.append(removeSessionWorktreeOwnershipToken(supersededToken))
        }
        await cleanupOrphanedSessionWorktreeResources(supersededResources)
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }

        sessionWorktreeOwnershipRecordsByToken[token] = SessionWorktreeOwnershipRecord(
            bindingFingerprint: bindingFingerprint,
            roots: [],
            pendingSeededRootIDs: []
        )
        reserveSessionWorktreePaths(standardizedPaths, for: token)
        do {
            var preparedRoots: [WorkspaceSessionWorktreeOwnedRoot] = []
            var materializationHintObservations: [String: WorkspaceRootMaterializationHintObservation] = [:]
            var pendingSeededRootPreparations: [WorkspacePendingSeededRootPreparation] = []
            for path in standardizedPaths {
                try Task.checkCancellation()
                guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation else {
                    throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
                }
                let hint = initializationHintsByPhysicalRootPath[path]
                #if DEBUG
                    if let hint, let startupContext {
                        receiptConsumptionDecision.ownerGenerationMatch = hint.expectedOwnerBindingGeneration == generation
                            ? .match
                            : .mismatch
                        receiptConsumptionDecision.hintSessionMatch = hint.agentSessionID == ownerID
                            ? .match
                            : .mismatch
                        receiptConsumptionDecision.hintCorrelationMatch = hint.correlationID == startupContext.correlationID
                            ? .match
                            : .mismatch
                        receiptConsumptionDecision.hintOwnerMatch = startupContext.agentSessionID == ownerID
                            ? .match
                            : .mismatch
                    }
                #endif
                var servingFallbackReason: WorkspaceRootSeedFallbackReason?
                if let startupContext,
                   startupContext.flags.serveDiffSeededWorktreeStartup,
                   startupContext.servingControl == .automatic,
                   let hint
                {
                    let observation: WorkspaceRootMaterializationHintObservation = if hint.expectedOwnerBindingGeneration != generation
                        || hint.agentSessionID != ownerID
                        || startupContext.agentSessionID != ownerID
                    {
                        .fallback(.ownerSuperseded)
                    } else {
                        await rootMaterializationHintEvaluator.observe(
                            hint,
                            observationEnabled: true
                        )
                    }
                    try Task.checkCancellation()
                    guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation else {
                        throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
                    }
                    materializationHintObservations[path] = observation
                    #if DEBUG
                        switch observation {
                        case .observationDisabled:
                            receiptConsumptionDecision.initialHintObservation = .disabled
                        case let .fallback(reason):
                            receiptConsumptionDecision.initialHintObservation = .fallback(reason)
                        case .eligible:
                            receiptConsumptionDecision.initialHintObservation = .eligible
                        }
                    #endif
                    switch observation {
                    case .observationDisabled:
                        break
                    case let .fallback(reason):
                        servingFallbackReason = reason
                        WorktreeStartupInstrumentation.record(
                            .seedFallback,
                            context: startupContext,
                            route: .diffSeedServing,
                            fallback: reason
                        )
                    case .eligible:
                        let attempt = try await FileSystemService.withContentReadForegroundActivity(
                            kind: .rootLoad
                        ) {
                            try await self.preparePendingSeededRoot(
                                token: token,
                                bindingFingerprint: bindingFingerprint,
                                standardizedPath: path,
                                hint: hint,
                                startupContext: startupContext
                            )
                        }
                        switch attempt {
                        case let .prepared(preparation):
                            #if DEBUG
                                receiptConsumptionDecision.pendingSeededPreparationResult = .eligible
                                receiptConsumptionDecision.fullCrawlPerformed = false
                                receiptConsumptionDecision.finalObservation = .eligible
                                receiptConsumptionDecision.selectedRoute = .diffSeedServing
                            #endif
                            pendingSeededRootPreparations.append(preparation)
                            continue
                        case let .fallback(reason):
                            #if DEBUG
                                receiptConsumptionDecision.pendingSeededPreparationResult = .fallback(reason)
                            #endif
                            servingFallbackReason = reason
                            materializationHintObservations[path] = .fallback(reason)
                        }
                    }
                }

                if let startupContext {
                    #if DEBUG
                        receiptConsumptionDecision.fullCrawlPerformed = true
                        receiptConsumptionDecision.selectedRoute = .fullCrawl
                    #endif
                    WorktreeStartupInstrumentation.record(
                        .rootLoadStarted,
                        context: startupContext,
                        route: .fullCrawl
                    )
                }
                var isDirectory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(path)
                }
                let root: WorkspaceRootRecord
                do {
                    root = try await loadRoot(
                        path: path,
                        kind: .sessionWorktree,
                        respectRepoIgnore: true,
                        respectCursorignore: true,
                        sessionWorktreeReservationToken: token
                    )
                } catch is IgnoreRulePolicyResolutionError {
                    throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(path)
                }
                try Task.checkCancellation()
                guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation,
                      let state = rootStatesByID[root.id],
                      state.root.kind == .sessionWorktree,
                      state.root.standardizedFullPath == path
                else {
                    if latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] != generation {
                        throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
                    }
                    throw WorkspaceSessionWorktreeOwnershipError.invalidRootKind(path)
                }
                let ownedRoot = WorkspaceSessionWorktreeOwnedRoot(
                    rootID: root.id,
                    lifetimeID: state.lifetimeID,
                    standardizedPhysicalPath: path
                )
                preparedRoots.append(ownedRoot)
                try convertSessionWorktreeReservationToClaim(
                    token: token,
                    bindingFingerprint: bindingFingerprint,
                    preparedRoots: preparedRoots,
                    ownedRoot: ownedRoot
                )
                try await reconcileAggregateWatcherDemand(rootID: root.id)
                try Task.checkCancellation()
                guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation,
                      isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: state.lifetimeID),
                      let rootCatalogGeneration = catalogGenerationsByRootID[root.id],
                      let appliedIndexGeneration = appliedIndexGenerationsByRootID[root.id]
                else {
                    throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
                }

                let observation: WorkspaceRootMaterializationHintObservation = if let servingFallbackReason {
                    .fallback(servingFallbackReason)
                } else if startupContext?.servingControl == .forceFullCrawl {
                    .fallback(.noReceipt)
                } else if let hint,
                          hint.expectedOwnerBindingGeneration != generation
                          || hint.agentSessionID != ownerID
                          || startupContext?.agentSessionID != ownerID
                {
                    .fallback(.ownerSuperseded)
                } else {
                    await rootMaterializationHintEvaluator.observe(
                        hint,
                        observationEnabled: startupContext?.flags.observeDiffSeededWorktreeStartup ?? false
                    )
                }
                #if DEBUG
                    switch observation {
                    case .observationDisabled:
                        receiptConsumptionDecision.finalObservation = .disabled
                        receiptConsumptionDecision.initialHintObservation = receiptConsumptionDecision.initialHintObservation
                            ?? .disabled
                    case let .fallback(reason):
                        receiptConsumptionDecision.finalObservation = .fallback(reason)
                        receiptConsumptionDecision.initialHintObservation = receiptConsumptionDecision.initialHintObservation
                            ?? .fallback(reason)
                    case .eligible:
                        receiptConsumptionDecision.finalObservation = .eligible
                        receiptConsumptionDecision.initialHintObservation = receiptConsumptionDecision.initialHintObservation
                            ?? .eligible
                    }
                #endif
                if servingFallbackReason == nil,
                   startupContext?.servingControl != .forceFullCrawl,
                   case let .fallback(reason) = observation,
                   let startupContext,
                   startupContext.flags.observeDiffSeededWorktreeStartup
                {
                    WorktreeStartupInstrumentation.record(
                        .shadowVerified,
                        context: startupContext,
                        route: .diffSeedObservation,
                        fallback: reason
                    )
                }
                if servingFallbackReason == nil,
                   startupContext?.servingControl != .forceFullCrawl,
                   case .eligible = observation,
                   let hint,
                   let startupContext,
                   startupContext.flags.observeDiffSeededWorktreeStartup
                {
                    let planningOutcome = await rootSeedPlanner.plan(hint: hint, service: state.service)
                    switch planningOutcome {
                    case let .fallback(reason):
                        WorktreeStartupInstrumentation.record(
                            .shadowVerified,
                            context: startupContext,
                            route: .diffSeedObservation,
                            fallback: reason
                        )
                    case let .planned(planHandle):
                        // P4-6a / bucket C: rewired onto the two O(1)-aggregate-shaped
                        // functions plus one batched `inventoryPathLookups` call over the
                        // whole manifest, replacing 5 inline table reads (§4.3.1.2). The
                        // manifest is materialized before the single lookup call rather
                        // than resolved per-record, so this is one call per scan, not one
                        // call per record. `state` (captured before this branch's awaits)
                        // is passed explicitly to both helpers so this shadow comparison
                        // keeps comparing against the exact snapshot it compared against
                        // pre-refactor -- no new staleness window. Named test:
                        // `testPrepareSessionWorktreeOwnershipShadowComparisonMatchesManifestAgainstBatchedLookup`.
                        let authoritativeFileCount = await discoverableFileCount(in: state)
                        let authoritativeFolderCount = await discoverableFolderCount(in: state)
                        var plannedFileCount = 0
                        var plannedFolderCount = 0
                        var matches = true
                        do {
                            let reader = try planHandle.makeReader()
                            var manifestRecords: [(relativePath: String, disposition: WorkspaceRootTargetSeedPlanDisposition)] = []
                            var queriedPaths: Set<String> = []
                            while let record = try reader.next() {
                                guard let relativePath = String(data: record.relativePathBytes, encoding: .utf8),
                                      Data(relativePath.utf8) == record.relativePathBytes
                                else {
                                    matches = false
                                    continue
                                }
                                manifestRecords.append((relativePath, record.disposition))
                                queriedPaths.insert(relativePath)
                            }
                            let lookups = await inventoryPathLookups(in: state, relativePaths: queriedPaths)
                            for (relativePath, disposition) in manifestRecords {
                                switch disposition {
                                case .ordinaryFile:
                                    plannedFileCount += 1
                                    guard lookups.files[relativePath]?.fileID != nil,
                                          lookups.files[relativePath]?.isDiscoverable == true
                                    else { matches = false
                                        continue
                                    }
                                case .ordinaryDirectory:
                                    plannedFolderCount += 1
                                    guard lookups.folders[relativePath]?.folderID != nil,
                                          lookups.folders[relativePath]?.isDiscoverable == true
                                    else { matches = false
                                        continue
                                    }
                                case .policyIgnoredTrackedFile:
                                    if lookups.files[relativePath]?.fileID != nil,
                                       lookups.files[relativePath]?.isDiscoverable == true
                                    { matches = false }
                                case .baseTombstone:
                                    break
                                }
                            }
                            matches = matches
                                && reader.validationState == .verified
                                && plannedFileCount == authoritativeFileCount
                                && plannedFolderCount == authoritativeFolderCount
                        } catch {
                            matches = false
                        }
                        WorktreeStartupInstrumentation.recordInventoryComparison(matched: matches)
                        if matches {
                            // P4-7c c1: this branch used to also build a `WorkspaceRootSeedShadowPreparation`
                            // for `installRootSeedSearchShadow` to consume later -- that consumer's own
                            // output (`rootSeedSearchShadowsByRootID`) had zero production readers once
                            // `.recordsAndPathIndexes` became unreachable at P4-7b (D-14), so it and this
                            // construction are deleted together; the `matches`-based `.shadowVerified`
                            // diagnostic below is independent of it and is preserved verbatim.
                            WorktreeStartupInstrumentation.record(
                                .shadowVerified,
                                context: startupContext,
                                route: .diffSeedObservation
                            )
                        } else {
                            WorktreeStartupInstrumentation.record(
                                .shadowVerified,
                                context: startupContext,
                                route: .diffSeedObservation,
                                fallback: .unexplainedFilesystemEntry
                            )
                        }
                    }
                }
                guard latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] == generation,
                      isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: state.lifetimeID),
                      catalogGenerationsByRootID[root.id] == rootCatalogGeneration,
                      appliedIndexGenerationsByRootID[root.id] == appliedIndexGeneration
                else {
                    materializationHintObservations[path] = .fallback(.serviceIngressGenerationChanged)
                    throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
                }
                materializationHintObservations[path] = observation
            }
            #if DEBUG
                if let startupContext {
                    if pendingSeededRootPreparations.isEmpty {
                        WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                            correlationID: startupContext.correlationID,
                            decision: receiptConsumptionDecision
                        )
                    } else {
                        pendingReceiptConsumptionDecisionByToken[token] = (
                            correlationID: startupContext.correlationID,
                            decision: receiptConsumptionDecision
                        )
                    }
                }
            #endif
            return WorkspaceSessionWorktreeOwnershipPreparation(
                token: token,
                bindingFingerprint: bindingFingerprint,
                roots: preparedRoots,
                reusesInstalledOwnership: false,
                materializationHintObservationsByPhysicalRootPath: materializationHintObservations,
                pendingSeededRootPreparations: pendingSeededRootPreparations
            )
        } catch {
            #if DEBUG
                if let startupContext {
                    WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                        correlationID: startupContext.correlationID,
                        decision: receiptConsumptionDecision
                    )
                }
            #endif
            let resources = removeSessionWorktreeOwnershipToken(token)
            await cleanupOrphanedSessionWorktreeResources(resources)
            throw error
        }
    }

    @discardableResult
    func commitSessionWorktreeOwnership(
        _ preparation: WorkspaceSessionWorktreeOwnershipPreparation
    ) async throws -> [WorkspaceSessionWorktreeOwnedRoot] {
        if preparation.reusesInstalledOwnership {
            guard installedSessionWorktreeOwnershipTokenByOwnerID[preparation.token.ownerID] == preparation.token,
                  let record = sessionWorktreeOwnershipRecordsByToken[preparation.token],
                  sessionWorktreeOwnershipRecordIsCurrent(record)
            else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            return record.roots
        }
        if !preparation.pendingSeededRootPreparations.isEmpty {
            return try await commitPendingSeededSessionWorktreeOwnership(preparation)
        }
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID] == preparation.token.generation,
              let record = sessionWorktreeOwnershipRecordsByToken[preparation.token],
              record.bindingFingerprint == preparation.bindingFingerprint,
              record.roots == preparation.roots,
              record.pendingSeededRootIDs == preparation.pendingSeededRootPreparations.map(\.id),
              sessionWorktreeOwnershipRecordIsCurrent(record)
        else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }

        if record.roots.isEmpty {
            installedSessionWorktreeOwnershipTokenByOwnerID.removeValue(forKey: preparation.token.ownerID)
            var releasedResources = removeSessionWorktreeOwnershipToken(preparation.token)
            let previousTokens = sessionWorktreeOwnershipRecordsByToken.keys.filter {
                $0.ownerID == preparation.token.ownerID
            }
            for previousToken in previousTokens {
                releasedResources.append(removeSessionWorktreeOwnershipToken(previousToken))
            }
            scheduleOrphanedSessionWorktreeResourceCleanup(releasedResources)
            return []
        }

        let previousToken = installedSessionWorktreeOwnershipTokenByOwnerID.updateValue(
            preparation.token,
            forKey: preparation.token.ownerID
        )
        var previousResources = SessionWorktreeOwnershipRemoval()
        if let previousToken, previousToken != preparation.token {
            previousResources = removeSessionWorktreeOwnershipToken(previousToken)
        }
        scheduleOrphanedSessionWorktreeResourceCleanup(previousResources)
        return record.roots
    }

    private func commitPendingSeededSessionWorktreeOwnership(
        _ preparation: WorkspaceSessionWorktreeOwnershipPreparation
    ) async throws -> [WorkspaceSessionWorktreeOwnedRoot] {
        let pendingIDs = preparation.pendingSeededRootPreparations.map(\.id)
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID]
            == preparation.token.generation,
            let record = sessionWorktreeOwnershipRecordsByToken[preparation.token],
            record.bindingFingerprint == preparation.bindingFingerprint,
            record.roots == preparation.roots,
            record.pendingSeededRootIDs == pendingIDs,
            sessionWorktreeVisibleRootsAreCurrent(record.roots),
            pendingIDs.allSatisfy({ pendingID in
                guard let pending = pendingSeededRootsByID[pendingID],
                      pending.token == preparation.token,
                      pending.bindingFingerprint == preparation.bindingFingerprint,
                      pending.phase == .readyForCommit,
                      pending.rustSeeded,
                      pending.attachment.map({
                          publisherIngressCoordinator.isPublisherIngressOpen($0.subscription)
                      }) == true,
                      pendingSeededRootIDsByStandardizedPath[pending.standardizedPath] == pendingID,
                      rootIDsByStandardizedPath[pending.standardizedPath] == nil,
                      sessionWorktreeReservedPathsByToken[preparation.token]?
                      .contains(pending.standardizedPath) == true
                else { return false }
                return true
            })
        else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }

        // Metadata callbacks may have arrived after preparation returned. Each
        // pending root gets at most the single event-triggered recapture owned by
        // its fence; no timer or polling path is introduced.
        do {
            for pendingID in pendingIDs {
                guard let pending = pendingSeededRootsByID[pendingID],
                      let fence = pending.authorityFence,
                      let authorityClaim = pending.authorityClaim
                else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }
                let validated = try await authorityClaim
                    .validatePendingAuthorityFence(replacing: fence)
                try await installValidatedPendingAuthorityFence(
                    validated,
                    pendingID: pendingID,
                    token: preparation.token,
                    standardizedPath: pending.standardizedPath,
                    expectedPhase: .readyForCommit
                )
                WorktreeStartupInstrumentation.recordSeedMetadataRevalidation(
                    used: validated.revalidationUsed
                )
            }
        } catch let error as WorkspaceSessionWorktreeOwnershipError {
            throw error
        } catch {
            return try await fallBackPendingSeededRootsDuringCommit(
                preparation,
                pendingIDs: pendingIDs,
                reason: .authorityUnstable
            )
        }

        // Resume each watcher while its root is still private. Any publication
        // that lands before the ingress handoff invalidates the prepared shard
        // and takes the ordinary one-shot crawl route.
        for pendingID in pendingIDs {
            guard let pending = pendingSeededRootsByID[pendingID] else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            guard let proof = await pending.state.service.activateSeededPublication(
                initializationID: pending.initializationID
            ) else {
                return try await fallBackPendingSeededRootsDuringCommit(
                    preparation,
                    pendingIDs: pendingIDs,
                    reason: .watcherActivationFailure
                )
            }
            try requirePendingSeededRootCurrent(
                pendingID,
                token: preparation.token,
                standardizedPath: pending.standardizedPath,
                expectedPhase: .readyForCommit
            )
            pendingSeededRootsByID[pendingID]?.activationProof = proof
            #if DEBUG
                if let pendingSeededRootDidActivateHandler {
                    await pendingSeededRootDidActivateHandler(pending.standardizedPath)
                }
            #endif
            try requirePendingSeededRootCurrent(
                pendingID,
                token: preparation.token,
                standardizedPath: pending.standardizedPath,
                expectedPhase: .readyForCommit
            )
            await publisherIngressCoordinator.waitForCurrentPublisherIngress(
                rootIDs: [pending.state.root.id]
            )
            guard let current = pendingSeededRootsByID[pendingID],
                  current.terminalFallbackReason == nil,
                  await current.state.service.seededPublicationActivationIsCurrent(proof)
            else {
                return try await fallBackPendingSeededRootsDuringCommit(
                    preparation,
                    pendingIDs: pendingIDs,
                    reason: .serviceIngressGenerationChanged
                )
            }
        }

        guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID]
            == preparation.token.generation,
            let currentRecord = sessionWorktreeOwnershipRecordsByToken[preparation.token],
            currentRecord.bindingFingerprint == preparation.bindingFingerprint,
            currentRecord.roots == preparation.roots,
            currentRecord.pendingSeededRootIDs == pendingIDs,
            sessionWorktreeVisibleRootsAreCurrent(currentRecord.roots)
        else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }

        var pendingRoots: [PendingSeededRoot] = []
        pendingRoots.reserveCapacity(pendingIDs.count)
        for pendingID in pendingIDs {
            guard let pending = pendingSeededRootsByID[pendingID],
                  pending.phase == .readyForCommit,
                  pending.rustSeeded,
                  let attachment = pending.attachment,
                  pending.activationProof != nil,
                  let authorityFence = pending.authorityFence,
                  publisherIngressCoordinator.isPublisherIngressOpen(attachment.subscription),
                  pending.lastAppliedServicePublicationSequence > 0,
                  pending.lastAppliedWatcherWatermark > .zero,
                  rootIDsByStandardizedPath[pending.standardizedPath] == nil
            else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }
            guard workspaceStateAuthority
                .pendingInitializationAuthorityFenceIsSynchronouslyCurrent(authorityFence),
                pending.authorityMutationDepth == 0,
                pending.terminalFallbackReason == nil
            else {
                return try await fallBackPendingSeededRootsDuringCommit(
                    preparation,
                    pendingIDs: pendingIDs,
                    reason: .authorityUnstable
                )
            }
            pendingRoots.append(pending)
        }

        var pausedHandoffSubscriptions: [WorkspaceFileSystemIngressCoordinator.Subscription] = []
        defer {
            for subscription in pausedHandoffSubscriptions {
                _ = publisherIngressCoordinator.resumeDrainAfterHandoff(subscription)
            }
        }
        for pending in pendingRoots {
            guard let attachment = pending.attachment else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            let root = pending.state.root
            let diagnosticRootToken = pending.state.service.diagnosticRootToken
            let publishedLifetimeID = pending.state.lifetimeID
            let replacement: WorkspaceFileSystemIngressCoordinator.DrainHandler = { [weak self] publication, correlation in
                await self?.handleObservedPublisherFileSystemPublication(
                    publication,
                    root: root,
                    expectedLifetimeID: publishedLifetimeID,
                    publicationCorrelation: correlation,
                    diagnosticRootToken: diagnosticRootToken
                )
            }
            if !publisherIngressCoordinator.pauseDrainAndReplaceHandler(
                attachment.subscription,
                drainHandler: replacement
            ) {
                await publisherIngressCoordinator.waitForCurrentPublisherIngress(rootIDs: [root.id])
                guard pendingSeededRootsByID[pending.id]?.terminalFallbackReason == nil,
                      publisherIngressCoordinator.pauseDrainAndReplaceHandler(
                          attachment.subscription,
                          drainHandler: replacement
                      )
                else {
                    for subscription in pausedHandoffSubscriptions {
                        _ = publisherIngressCoordinator.resumeDrainAfterHandoff(subscription)
                    }
                    return try await fallBackPendingSeededRootsDuringCommit(
                        preparation,
                        pendingIDs: pendingIDs,
                        reason: .serviceIngressGenerationChanged
                    )
                }
            }
            pausedHandoffSubscriptions.append(attachment.subscription)
        }

        for pending in pendingRoots {
            guard let proof = pending.activationProof,
                  await pending.state.service.seededPublicationActivationIsCurrent(proof),
                  pendingSeededRootIsCurrent(
                      pending.id,
                      token: preparation.token,
                      standardizedPath: pending.standardizedPath,
                      expectedPhase: .readyForCommit
                  )
            else {
                for subscription in pausedHandoffSubscriptions {
                    _ = publisherIngressCoordinator.resumeDrainAfterHandoff(subscription)
                }
                return try await fallBackPendingSeededRootsDuringCommit(
                    preparation,
                    pendingIDs: pendingIDs,
                    reason: .serviceIngressGenerationChanged
                )
            }
        }

        guard pendingRoots.compactMap(\.authorityFence).count == pendingRoots.count else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        let publicationFences = pendingRoots.compactMap(\.authorityFence)

        // No await, callback, task creation, or throwing operation is allowed
        // from the authority permit through the complete visible-state assignment.
        var installedRoots = currentRecord.roots
        var newlyPublishedRootIDs = Set<UUID>()
        var newlyPublishedPaths: [String] = []
        var pendingServices: [(FileSystemService, FileSystemSeedPublicationActivationProof, WorktreeStartupContext)] = []
        var previousToken: WorkspaceSessionWorktreeOwnershipToken?
        let didPublish = workspaceStateAuthority.withPendingInitializationAuthorityPublicationPermit(
            publicationFences
        ) {
            guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID]
                == preparation.token.generation,
                sessionWorktreeOwnershipRecordsByToken[preparation.token]?.pendingSeededRootIDs == pendingIDs,
                pendingRoots.allSatisfy({ pending in
                    guard let fence = pending.authorityFence,
                          let current = pendingSeededRootsByID[pending.id]
                    else { return false }
                    return current.phase == .readyForCommit
                        && current.authorityFence == fence
                        && current.authorityInvalidationGeneration == fence.lease.invalidationGeneration
                        && current.authorityAcceptedMetadataWatermark == fence.acceptedMetadataWatermark
                        && current.authorityMutationDepth == 0
                        && current.terminalFallbackReason == nil
                }),
                pausedHandoffSubscriptions.allSatisfy({
                    publisherIngressCoordinator.resumeDrainAfterHandoff($0)
                })
            else { return false }

            for pending in pendingRoots {
                guard let fence = pending.authorityFence,
                      let authorityClaim = pending.authorityClaim,
                      let activationProof = pending.activationProof
                else { return false }
                let root = pending.state.root
                let ownedRoot = WorkspaceSessionWorktreeOwnedRoot(
                    rootID: root.id,
                    lifetimeID: pending.state.lifetimeID,
                    standardizedPhysicalPath: pending.standardizedPath
                )
                // P4-6b reroute: no `commit(pending.indexes)` / shard-cache registration --
                // Rust was already seeded with this root's validated record set during
                // `preparePendingSeededRoot` (which could await; this permit closure cannot).
                // This mirrors the ordinary crawl path's own "go live" step (`loadRoot`'s tail),
                // which also does no local-table commit and no shard registration post-cutover.
                rootIDsByStandardizedPath[pending.standardizedPath] = root.id
                rootStatesByID[root.id] = pending.state
                rootLoadConfigurationsByPath[pending.standardizedPath] = pending.loadConfiguration
                rootLoadOrder.append(root.id)
                appliedIndexGenerationsByRootID[root.id] = 0
                catalogGenerationsByRootID[root.id] = 0
                if let attachment = pending.attachment {
                    watcherPublisherAttachmentsByKey[WatcherInfrastructureKey(
                        rootID: root.id,
                        lifetimeID: pending.state.lifetimeID
                    )] = attachment
                }
                let lifetimeKey = SessionWorktreeRootLifetimeKey(
                    rootID: root.id,
                    lifetimeID: pending.state.lifetimeID
                )
                sessionWorktreeOwnershipTokensByRootLifetime[lifetimeKey, default: []]
                    .insert(preparation.token)
                removeSessionWorktreeReservation(
                    standardizedPath: pending.standardizedPath,
                    token: preparation.token
                )
                installedRoots.append(ownedRoot)
                newlyPublishedRootIDs.insert(root.id)
                newlyPublishedPaths.append(pending.standardizedPath)
                pendingServices.append((pending.state.service, activationProof, pending.startupContext))
                publishedSeededAuthorityFencesByRootID[root.id] = fence
                publishedSeededAuthorityClaimsByRootID[root.id] = authorityClaim
                publishedSeededAuthorityStatesByRootID[root.id] = PublishedSeededAuthorityState(
                    epoch: 0,
                    pendingInvalidationGeneration: nil,
                    pendingAcceptedMetadataWatermark: fence.acceptedMetadataWatermark,
                    activeMutationDepth: 0,
                    isBlocked: false,
                    isReconciling: false,
                    reconciliationFailed: false,
                    fullCrawlAttemptedGeneration: nil,
                    fullCrawlCompletedGeneration: nil
                )
                pendingSeededRootsByID.removeValue(forKey: pending.id)
                pendingSeededRootIDsByStandardizedPath.removeValue(forKey: pending.standardizedPath)
                #if DEBUG
                    rootCrawlCountsByRootID[root.id] = 0
                #endif
            }
            sessionRootLifetimeClock.advance()
            sessionWorktreeOwnershipRecordsByToken[preparation.token] = SessionWorktreeOwnershipRecord(
                bindingFingerprint: preparation.bindingFingerprint,
                roots: installedRoots,
                pendingSeededRootIDs: []
            )
            previousToken = installedSessionWorktreeOwnershipTokenByOwnerID.updateValue(
                preparation.token,
                forKey: preparation.token.ownerID
            )
            return true
        } ?? false

        // The authority publication permit holds a non-recursive synchronous mutex.
        // Path snapshot invalidation may synchronously verify published authority fences,
        // so perform it immediately after the permit releases the mutex. This remains one
        // uninterrupted store-actor turn: no other store operation can observe published
        // roots before their path-match snapshots are invalidated.
        if didPublish {
            invalidatePathMatchSnapshot(
                affectedRootKinds: [.sessionWorktree],
                reason: .rootLoad,
                affectedRootIDs: newlyPublishedRootIDs
            )
        }

        guard didPublish else {
            for subscription in pausedHandoffSubscriptions {
                _ = publisherIngressCoordinator.resumeDrainAfterHandoff(subscription)
            }
            return try await fallBackPendingSeededRootsDuringCommit(
                preparation,
                pendingIDs: pendingIDs,
                reason: .authorityUnstable
            )
        }

        var previousResources = SessionWorktreeOwnershipRemoval()
        if let previousToken, previousToken != preparation.token {
            previousResources = removeSessionWorktreeOwnershipToken(previousToken)
        }
        // Watchers were activated and revalidated while private. Finalization
        // only retires the proof; visibility waiters remain held until it succeeds.
        for (service, activationProof, context) in pendingServices {
            guard await service.finalizeSeededPublication(activationProof) else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            WorktreeStartupInstrumentation.record(
                .seedPublished,
                context: context,
                route: .diffSeedServing
            )
        }
        #if DEBUG
            if let pendingDecision = pendingReceiptConsumptionDecisionByToken.removeValue(
                forKey: preparation.token
            ) {
                WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                    correlationID: pendingDecision.correlationID,
                    decision: pendingDecision.decision
                )
            }
        #endif
        for path in newlyPublishedPaths {
            finishPendingSeededRootVisibility(path: path)
        }
        for pending in pendingRoots {
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: pending.state.root.id,
                rootLifetimeID: pending.state.lifetimeID
            )
            recordCodemapRootReadyForGraphIndexBuild(rootEpoch: rootEpoch)
            publishCodemapRootStatusesIfChanged()
            scheduleCodemapGraphIndexBuildAfterRootReady(rootEpoch: rootEpoch)
        }
        scheduleOrphanedSessionWorktreeResourceCleanup(previousResources)
        return installedRoots
    }

    private func fallBackPendingSeededRootsDuringCommit(
        _ preparation: WorkspaceSessionWorktreeOwnershipPreparation,
        pendingIDs: [WorkspacePendingSeededRootID],
        reason: WorkspaceRootSeedFallbackReason
    ) async throws -> [WorkspaceSessionWorktreeOwnedRoot] {
        guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID]
            == preparation.token.generation
        else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }
        let pending = pendingIDs.compactMap { pendingSeededRootsByID[$0] }
        guard pending.count == pendingIDs.count else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        for root in pending {
            await fallBackPendingSeededRoot(
                root.id,
                reason: reason,
                startupContext: root.startupContext
            )
        }

        var roots = sessionWorktreeOwnershipRecordsByToken[preparation.token]?.roots ?? []
        for root in pending {
            guard latestSessionWorktreeOwnershipGenerationByOwnerID[preparation.token.ownerID]
                == preparation.token.generation
            else { throw WorkspaceSessionWorktreeOwnershipError.staleUpdate }
            WorktreeStartupInstrumentation.record(
                .rootLoadStarted,
                context: root.startupContext,
                route: .fullCrawl
            )
            let loaded = try await loadRoot(
                path: root.standardizedPath,
                kind: .sessionWorktree,
                respectRepoIgnore: true,
                respectCursorignore: true,
                sessionWorktreeReservationToken: preparation.token
            )
            guard let loadedState = rootStatesByID[loaded.id] else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            let owned = WorkspaceSessionWorktreeOwnedRoot(
                rootID: loaded.id,
                lifetimeID: loadedState.lifetimeID,
                standardizedPhysicalPath: root.standardizedPath
            )
            roots.append(owned)
            try convertSessionWorktreeReservationToClaim(
                token: preparation.token,
                bindingFingerprint: preparation.bindingFingerprint,
                preparedRoots: roots,
                ownedRoot: owned
            )
            try await reconcileAggregateWatcherDemand(rootID: loaded.id)
        }
        let replacement = WorkspaceSessionWorktreeOwnershipPreparation(
            token: preparation.token,
            bindingFingerprint: preparation.bindingFingerprint,
            roots: roots,
            reusesInstalledOwnership: false,
            materializationHintObservationsByPhysicalRootPath:
            preparation.materializationHintObservationsByPhysicalRootPath
        )
        let committedRoots = try await commitSessionWorktreeOwnership(replacement)
        #if DEBUG
            if var pendingDecision = pendingReceiptConsumptionDecisionByToken.removeValue(
                forKey: preparation.token
            ) {
                pendingDecision.decision.pendingSeededPreparationResult = .fallback(reason)
                pendingDecision.decision.fullCrawlPerformed = true
                pendingDecision.decision.finalObservation = .fallback(reason)
                pendingDecision.decision.selectedRoute = .fullCrawl
                WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                    correlationID: pendingDecision.correlationID,
                    decision: pendingDecision.decision
                )
            }
        #endif
        return committedRoots
    }

    func abortSessionWorktreeOwnership(
        _ preparation: WorkspaceSessionWorktreeOwnershipPreparation
    ) async {
        #if DEBUG
            terminalizePendingReceiptConsumptionDecision(for: preparation.token)
        #endif
        guard !preparation.reusesInstalledOwnership,
              installedSessionWorktreeOwnershipTokenByOwnerID[preparation.token.ownerID] != preparation.token
        else { return }
        let resources = removeSessionWorktreeOwnershipToken(preparation.token)
        await cleanupOrphanedSessionWorktreeResources(resources)
    }

    func releaseSessionWorktreeOwnership(ownerID: UUID) async {
        latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID, default: 0] &+= 1
        installedSessionWorktreeOwnershipTokenByOwnerID.removeValue(forKey: ownerID)
        let tokens = sessionWorktreeOwnershipRecordsByToken.keys.filter { $0.ownerID == ownerID }
        var resources = SessionWorktreeOwnershipRemoval()
        for token in tokens {
            resources.append(removeSessionWorktreeOwnershipToken(token))
        }
        await cleanupOrphanedSessionWorktreeResources(resources)
    }

    func sessionWorktreeOwnershipCovers(
        ownerID: UUID,
        bindingFingerprint: String,
        physicalRootPaths: Set<String>
    ) -> Bool {
        guard let token = installedSessionWorktreeOwnershipTokenByOwnerID[ownerID],
              let record = sessionWorktreeOwnershipRecordsByToken[token],
              record.bindingFingerprint == bindingFingerprint,
              Set(record.roots.map(\.standardizedPhysicalPath)) == Set(physicalRootPaths.map {
                  StandardizedPath.absolute(($0 as NSString).expandingTildeInPath)
              }),
              sessionWorktreeOwnershipRecordIsCurrent(record)
        else { return false }
        return true
    }

    func installedSessionWorktreeRoots(
        ownerID: UUID,
        bindingFingerprint: String,
        physicalRootPaths: Set<String>
    ) -> [WorkspaceRootRecord]? {
        guard sessionWorktreeOwnershipCovers(
            ownerID: ownerID,
            bindingFingerprint: bindingFingerprint,
            physicalRootPaths: physicalRootPaths
        ),
            let token = installedSessionWorktreeOwnershipTokenByOwnerID[ownerID],
            let record = sessionWorktreeOwnershipRecordsByToken[token]
        else { return nil }
        return record.roots.compactMap { rootStatesByID[$0.rootID]?.root }
    }

    func validateSessionRootAuthorization(
        _ authorization: WorkspaceSessionRootAuthorization
    ) -> WorkspaceSessionRootAuthorizationMismatch? {
        sessionRootAuthorizationMismatch(authorization)
    }

    private func sessionRootAuthorizationMismatch(
        _ authorization: WorkspaceSessionRootAuthorization
    ) -> WorkspaceSessionRootAuthorizationMismatch? {
        guard let token = installedSessionWorktreeOwnershipTokenByOwnerID[authorization.sessionID] else {
            return .token
        }
        guard token.generation == authorization.ownershipGeneration else {
            return .generation
        }
        guard let record = sessionWorktreeOwnershipRecordsByToken[token] else {
            return .token
        }
        guard sessionWorktreeOwnershipRecordIsCurrent(record) else {
            return .rootClaim
        }
        guard let ownedRoot = record.roots.first(where: { $0.rootID == authorization.root.id }) else {
            return .rootID
        }
        guard ownedRoot.lifetimeID == authorization.lifetimeID else {
            return .lifetime
        }
        guard ownedRoot.standardizedPhysicalPath == authorization.root.standardizedFullPath else {
            return .path
        }
        guard let state = rootStatesByID[authorization.root.id] else {
            return .rootID
        }
        guard state.lifetimeID == authorization.lifetimeID else {
            return .lifetime
        }
        guard state.root.kind == .sessionWorktree else {
            return .kind
        }
        guard state.root.standardizedFullPath == authorization.root.standardizedFullPath else {
            return .path
        }
        let lifetimeKey = SessionWorktreeRootLifetimeKey(
            rootID: authorization.root.id,
            lifetimeID: authorization.lifetimeID
        )
        guard sessionWorktreeOwnershipTokensByRootLifetime[lifetimeKey]?.contains(token) == true else {
            return .rootClaim
        }
        return nil
    }

    #if DEBUG
        enum SessionWorktreeOwnershipDrainDebugError: Error {
            case invalidExpectedPathDigests
        }

        struct SessionWorktreeOwnershipDrainDebugSnapshot: Equatable {
            let ownerID: UUID
            let ownerGeneration: UInt64
            let expectedPhysicalPathDigests: [String]
            let actorEntryDelayNanoseconds: UInt64
            let installedTokenCount: Int
            let provisionalTokenCount: Int
            let rootClaimCount: Int
            let pathReservationCount: Int
            let matchingLiveRootCount: Int
            let matchingWatcherAttachmentCount: Int
            let pendingSeededRootCount: Int
            let pendingVisibilityWaiterCount: Int
            let queuedPublicationCount: Int
            let applyingPublicationCount: Int
            let outstandingPublicationCount: Int
            let publisherWaiterCount: Int
            let unloadingRootCount: Int
            let reservedLoadFlightCount: Int
            let isDrained: Bool
        }

        struct SessionWorktreeOwnershipDebugSnapshot: Equatable {
            let installedOwnerCount: Int
            let provisionalOwnerCount: Int
            let rootClaimCount: Int
            let pathReservationCount: Int
            let explicitWatcherDemandCount: Int
            let pendingSeededRootCount: Int
            let pendingVisibilityWaiterCount: Int
        }

        func sessionWorktreeOwnershipDrainSnapshotForTesting(
            ownerID: UUID,
            expectedPhysicalPathDigests: Set<String>,
            requestedAtNanoseconds: UInt64
        ) async throws -> SessionWorktreeOwnershipDrainDebugSnapshot {
            guard !expectedPhysicalPathDigests.isEmpty,
                  expectedPhysicalPathDigests.count <= 16,
                  expectedPhysicalPathDigests.allSatisfy({
                      $0.count == 64 && $0.allSatisfy(\.isHexDigit)
                  })
            else { throw SessionWorktreeOwnershipDrainDebugError.invalidExpectedPathDigests }

            let matchingCleanupTasks: [Task<Void, Never>] =
                sessionWorktreeOrphanLoadCleanupsByID.values.compactMap { cleanup in
                    guard cleanup.ownerID == ownerID,
                          expectedPhysicalPathDigests.contains(
                              Self.sessionWorktreePathDigest(cleanup.standardizedPath)
                          )
                    else { return nil }
                    return cleanup.task
                }
            if !matchingCleanupTasks.isEmpty {
                sessionWorktreeDrainLoadFlightWaiterCount += 1
                sessionWorktreeDrainDidEnterLoadFlightWaitHandler?()
                for task in matchingCleanupTasks {
                    await task.value
                }
                sessionWorktreeDrainLoadFlightWaiterCount -= 1
            }

            let entry = DispatchTime.now().uptimeNanoseconds
            let ownerTokens = Set(sessionWorktreeOwnershipRecordsByToken.keys.filter { $0.ownerID == ownerID })
            let installedToken = installedSessionWorktreeOwnershipTokenByOwnerID[ownerID]
            let installedTokenCount = installedToken.map { ownerTokens.contains($0) ? 1 : 0 } ?? 0
            let provisionalTokenCount = ownerTokens.count - installedTokenCount
            let rootClaimCount = sessionWorktreeOwnershipTokensByRootLifetime.values.reduce(0) {
                $0 + $1.intersection(ownerTokens).count
            }
            let pathReservationCount = sessionWorktreeReservationTokensByStandardizedPath.values.reduce(0) {
                $0 + $1.intersection(ownerTokens).count
            }
            let matchingLiveRootIDs: Set<UUID> = Set(rootStatesByID.compactMap { entry -> UUID? in
                let (rootID, state) = entry
                guard state.root.kind == .sessionWorktree,
                      expectedPhysicalPathDigests.contains(Self.sessionWorktreePathDigest(state.root.standardizedFullPath))
                else { return nil }
                return rootID
            })
            let matchingPending = pendingSeededRootsByID.values.filter {
                expectedPhysicalPathDigests.contains(Self.sessionWorktreePathDigest($0.standardizedPath))
            }
            var matchingIngressRootIDs = matchingLiveRootIDs
            matchingIngressRootIDs.formUnion(matchingPending.map(\.state.root.id))
            let matchingWatcherAttachmentCount = watcherPublisherAttachmentsByKey.keys.count {
                matchingIngressRootIDs.contains($0.rootID)
            }
            let pendingVisibilityWaiterCount = pendingSeededRootVisibilityWaitersByPath.reduce(0) {
                expectedPhysicalPathDigests.contains(Self.sessionWorktreePathDigest($1.key))
                    ? $0 + $1.value.count
                    : $0
            }
            let ingressSnapshots = matchingIngressRootIDs.map {
                publisherIngressCoordinator.debugSnapshot(rootID: $0)
            }
            let queuedPublicationCount = ingressSnapshots.reduce(0) { $0 + $1.queuedPublicationCount }
            let applyingPublicationCount = ingressSnapshots.reduce(0) { $0 + $1.applyingPublicationCount }
            let outstandingPublicationCount = ingressSnapshots.reduce(0) { $0 + $1.outstandingPublicationCount }
            let publisherWaiterCount = ingressSnapshots.reduce(0) { $0 + $1.waiterCount }
            let unloadingRootCount = unloadingRootPaths.count {
                expectedPhysicalPathDigests.contains(Self.sessionWorktreePathDigest($0))
            }
            let reservedLoadFlightCount = sessionWorktreeOrphanLoadCleanupsByID.values.count { cleanup in
                cleanup.ownerID == ownerID
                    && expectedPhysicalPathDigests.contains(
                        Self.sessionWorktreePathDigest(cleanup.standardizedPath)
                    )
            } + sessionWorktreeOrphanLoadCleanupOverflowCount
            let componentCounts = [
                installedTokenCount,
                provisionalTokenCount,
                rootClaimCount,
                pathReservationCount,
                matchingLiveRootIDs.count,
                matchingWatcherAttachmentCount,
                matchingPending.count,
                pendingVisibilityWaiterCount,
                queuedPublicationCount,
                applyingPublicationCount,
                outstandingPublicationCount,
                publisherWaiterCount,
                unloadingRootCount,
                reservedLoadFlightCount
            ]
            return SessionWorktreeOwnershipDrainDebugSnapshot(
                ownerID: ownerID,
                ownerGeneration: latestSessionWorktreeOwnershipGenerationByOwnerID[ownerID] ?? 0,
                expectedPhysicalPathDigests: expectedPhysicalPathDigests.sorted(),
                actorEntryDelayNanoseconds: entry >= requestedAtNanoseconds ? entry - requestedAtNanoseconds : 0,
                installedTokenCount: installedTokenCount,
                provisionalTokenCount: provisionalTokenCount,
                rootClaimCount: rootClaimCount,
                pathReservationCount: pathReservationCount,
                matchingLiveRootCount: matchingLiveRootIDs.count,
                matchingWatcherAttachmentCount: matchingWatcherAttachmentCount,
                pendingSeededRootCount: matchingPending.count,
                pendingVisibilityWaiterCount: pendingVisibilityWaiterCount,
                queuedPublicationCount: queuedPublicationCount,
                applyingPublicationCount: applyingPublicationCount,
                outstandingPublicationCount: outstandingPublicationCount,
                publisherWaiterCount: publisherWaiterCount,
                unloadingRootCount: unloadingRootCount,
                reservedLoadFlightCount: reservedLoadFlightCount,
                isDrained: componentCounts.allSatisfy { $0 == 0 }
            )
        }

        private nonisolated static func sessionWorktreePathDigest(_ path: String) -> String {
            let standardized = StandardizedPath.absolute((path as NSString).expandingTildeInPath)
            return SHA256.hash(data: Data(standardized.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }

        func sessionWorktreeOwnershipDebugSnapshotForTesting() -> SessionWorktreeOwnershipDebugSnapshot {
            let installedTokens = Set(installedSessionWorktreeOwnershipTokenByOwnerID.values)
            return SessionWorktreeOwnershipDebugSnapshot(
                installedOwnerCount: installedTokens.count,
                provisionalOwnerCount: sessionWorktreeOwnershipRecordsByToken.keys.count(where: { !installedTokens.contains($0) }),
                rootClaimCount: sessionWorktreeOwnershipTokensByRootLifetime.values.reduce(0) { $0 + $1.count },
                pathReservationCount: sessionWorktreeReservationTokensByStandardizedPath.values.reduce(0) { $0 + $1.count },
                explicitWatcherDemandCount: explicitWatcherDemandRootIDs.count,
                pendingSeededRootCount: pendingSeededRootsByID.count,
                pendingVisibilityWaiterCount: pendingSeededRootVisibilityWaitersByPath.values.reduce(0) {
                    $0 + $1.count
                }
            )
        }
    #endif

    private func sessionWorktreeOwnershipRecordIsCurrent(_ record: SessionWorktreeOwnershipRecord) -> Bool {
        guard record.pendingSeededRootIDs.isEmpty else { return false }
        return sessionWorktreeVisibleRootsAreCurrent(record.roots)
    }

    private func sessionWorktreeVisibleRootsAreCurrent(
        _ roots: [WorkspaceSessionWorktreeOwnedRoot]
    ) -> Bool {
        roots.allSatisfy { root in
            let watcherKey = WatcherInfrastructureKey(rootID: root.rootID, lifetimeID: root.lifetimeID)
            guard let state = rootStatesByID[root.rootID],
                  state.lifetimeID == root.lifetimeID,
                  state.root.kind == .sessionWorktree,
                  state.root.standardizedFullPath == root.standardizedPhysicalPath,
                  let attachment = watcherPublisherAttachmentsByKey[watcherKey],
                  publisherIngressCoordinator.isPublisherIngressOpen(attachment.subscription)
            else { return false }
            let key = SessionWorktreeRootLifetimeKey(rootID: root.rootID, lifetimeID: root.lifetimeID)
            return sessionWorktreeOwnershipTokensByRootLifetime[key]?.isEmpty == false
        }
    }

    private func reserveSessionWorktreePaths(
        _ standardizedPaths: [String],
        for token: WorkspaceSessionWorktreeOwnershipToken
    ) {
        guard !standardizedPaths.isEmpty else { return }
        let paths = Set(standardizedPaths)
        sessionWorktreeReservedPathsByToken[token] = paths
        for path in paths {
            sessionWorktreeReservationTokensByStandardizedPath[path, default: []].insert(token)
        }
    }

    private func registerSessionWorktreeReservationLoadFlight(
        _ flight: RootLoadFlight,
        standardizedPath: String,
        token: WorkspaceSessionWorktreeOwnershipToken
    ) {
        guard sessionWorktreeReservedPathsByToken[token]?.contains(standardizedPath) == true else { return }
        sessionWorktreeReservationLoadFlightsByToken[token, default: [:]][standardizedPath] = flight
    }

    private func convertSessionWorktreeReservationToClaim(
        token: WorkspaceSessionWorktreeOwnershipToken,
        bindingFingerprint: String,
        preparedRoots: [WorkspaceSessionWorktreeOwnedRoot],
        ownedRoot: WorkspaceSessionWorktreeOwnedRoot
    ) throws {
        guard let record = sessionWorktreeOwnershipRecordsByToken[token],
              record.bindingFingerprint == bindingFingerprint,
              record.roots == Array(preparedRoots.dropLast()),
              preparedRoots.last == ownedRoot,
              sessionWorktreeReservedPathsByToken[token]?.contains(ownedRoot.standardizedPhysicalPath) == true,
              sessionWorktreeReservationTokensByStandardizedPath[
                  ownedRoot.standardizedPhysicalPath
              ]?.contains(token) == true
        else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }

        sessionWorktreeOwnershipRecordsByToken[token] = SessionWorktreeOwnershipRecord(
            bindingFingerprint: bindingFingerprint,
            roots: preparedRoots,
            pendingSeededRootIDs: record.pendingSeededRootIDs
        )
        let rootKey = SessionWorktreeRootLifetimeKey(
            rootID: ownedRoot.rootID,
            lifetimeID: ownedRoot.lifetimeID
        )
        sessionWorktreeOwnershipTokensByRootLifetime[rootKey, default: []].insert(token)
        removeSessionWorktreeReservation(
            standardizedPath: ownedRoot.standardizedPhysicalPath,
            token: token
        )
    }

    private func registerPendingSessionWorktreeRoot(
        _ pendingID: WorkspacePendingSeededRootID,
        standardizedPath: String,
        token: WorkspaceSessionWorktreeOwnershipToken,
        bindingFingerprint: String
    ) throws {
        guard let record = sessionWorktreeOwnershipRecordsByToken[token],
              record.bindingFingerprint == bindingFingerprint,
              sessionWorktreeReservedPathsByToken[token]?.contains(standardizedPath) == true,
              sessionWorktreeReservationTokensByStandardizedPath[standardizedPath]?.contains(token) == true,
              !record.pendingSeededRootIDs.contains(pendingID)
        else {
            throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
        }
        sessionWorktreeOwnershipRecordsByToken[token] = SessionWorktreeOwnershipRecord(
            bindingFingerprint: record.bindingFingerprint,
            roots: record.roots,
            pendingSeededRootIDs: record.pendingSeededRootIDs + [pendingID]
        )
    }

    private func removeSessionWorktreeReservation(
        standardizedPath: String,
        token: WorkspaceSessionWorktreeOwnershipToken
    ) {
        sessionWorktreeReservationTokensByStandardizedPath[standardizedPath]?.remove(token)
        if sessionWorktreeReservationTokensByStandardizedPath[standardizedPath]?.isEmpty == true {
            sessionWorktreeReservationTokensByStandardizedPath.removeValue(forKey: standardizedPath)
        }
        sessionWorktreeReservedPathsByToken[token]?.remove(standardizedPath)
        sessionWorktreeReservationLoadFlightsByToken[token]?.removeValue(forKey: standardizedPath)
        if sessionWorktreeReservedPathsByToken[token]?.isEmpty == true {
            sessionWorktreeReservedPathsByToken.removeValue(forKey: token)
        }
        if sessionWorktreeReservationLoadFlightsByToken[token]?.isEmpty == true {
            sessionWorktreeReservationLoadFlightsByToken.removeValue(forKey: token)
        }
    }

    private func removeSessionWorktreeOwnershipToken(
        _ token: WorkspaceSessionWorktreeOwnershipToken
    ) -> SessionWorktreeOwnershipRemoval {
        #if DEBUG
            terminalizePendingReceiptConsumptionDecision(for: token)
        #endif
        let record = sessionWorktreeOwnershipRecordsByToken.removeValue(forKey: token)
        let reservedPaths = sessionWorktreeReservedPathsByToken.removeValue(forKey: token) ?? []
        let reservedLoadFlightsByPath =
            sessionWorktreeReservationLoadFlightsByToken.removeValue(forKey: token) ?? [:]
        for path in reservedPaths {
            sessionWorktreeReservationTokensByStandardizedPath[path]?.remove(token)
            if sessionWorktreeReservationTokensByStandardizedPath[path]?.isEmpty == true {
                sessionWorktreeReservationTokensByStandardizedPath.removeValue(forKey: path)
            }
        }
        for root in record?.roots ?? [] {
            let key = SessionWorktreeRootLifetimeKey(rootID: root.rootID, lifetimeID: root.lifetimeID)
            sessionWorktreeOwnershipTokensByRootLifetime[key]?.remove(token)
            if sessionWorktreeOwnershipTokensByRootLifetime[key]?.isEmpty == true {
                sessionWorktreeOwnershipTokensByRootLifetime.removeValue(forKey: key)
            }
        }
        return SessionWorktreeOwnershipRemoval(
            ownedRoots: record?.roots ?? [],
            reservedLoadFlights: reservedLoadFlightsByPath.compactMap { path, flight in
                guard reservedPaths.contains(path) else { return nil }
                return SessionWorktreeReservedLoadFlight(
                    ownerID: token.ownerID,
                    standardizedPath: path,
                    flight: flight
                )
            },
            pendingSeededRootIDs: record?.pendingSeededRootIDs ?? []
        )
    }

    #if DEBUG
        func terminalizeReceiptConsumptionDecision(
            _ preparation: WorkspaceSessionWorktreeOwnershipPreparation
        ) {
            terminalizePendingReceiptConsumptionDecision(for: preparation.token)
        }

        private func terminalizePendingReceiptConsumptionDecision(
            for token: WorkspaceSessionWorktreeOwnershipToken
        ) {
            guard let pendingDecision = pendingReceiptConsumptionDecisionByToken.removeValue(
                forKey: token
            ) else { return }
            WorktreeStartupInstrumentation.recordReceiptConsumptionDecision(
                correlationID: pendingDecision.correlationID,
                decision: pendingDecision.decision
            )
        }
    #endif

    private func scheduleOrphanedSessionWorktreeResourceCleanup(
        _ resources: SessionWorktreeOwnershipRemoval
    ) {
        guard !resources.ownedRoots.isEmpty || !resources.reservedLoadFlights.isEmpty
            || !resources.pendingSeededRootIDs.isEmpty
        else { return }
        Task { await cleanupOrphanedSessionWorktreeResources(resources) }
    }

    private func cleanupOrphanedSessionWorktreeResources(
        _ resources: SessionWorktreeOwnershipRemoval
    ) async {
        await abortPendingSeededRoots(resources.pendingSeededRootIDs)
        await cleanupOrphanedSessionWorktreeRoots(resources.ownedRoots)
        scheduleOrphanedSessionWorktreeLoadFlightCleanup(resources.reservedLoadFlights)
    }

    private func cleanupOrphanedSessionWorktreeRoots(
        _ roots: [WorkspaceSessionWorktreeOwnedRoot]
    ) async {
        var seen = Set<SessionWorktreeRootLifetimeKey>()
        for root in roots {
            let key = SessionWorktreeRootLifetimeKey(rootID: root.rootID, lifetimeID: root.lifetimeID)
            guard seen.insert(key).inserted,
                  isRootLifetimeCurrent(rootID: root.rootID, expectedLifetimeID: root.lifetimeID),
                  rootStatesByID[root.rootID]?.root.standardizedFullPath == root.standardizedPhysicalPath,
                  !hasAggregateWatcherDemand(rootID: root.rootID, lifetimeID: root.lifetimeID)
            else { continue }
            try? await reconcileAggregateWatcherDemand(rootID: root.rootID)
            guard isRootLifetimeCurrent(rootID: root.rootID, expectedLifetimeID: root.lifetimeID),
                  !hasAggregateWatcherDemand(rootID: root.rootID, lifetimeID: root.lifetimeID),
                  rootStatesByID[root.rootID]?.root.kind == .sessionWorktree,
                  rootStatesByID[root.rootID]?.root.standardizedFullPath == root.standardizedPhysicalPath
            else { continue }
            await unloadRoot(id: root.rootID)
        }
    }

    private func scheduleOrphanedSessionWorktreeLoadFlightCleanup(
        _ reservations: [SessionWorktreeReservedLoadFlight]
    ) {
        var scheduledFlightIDs = Set<UUID>()
        for reservation in reservations where scheduledFlightIDs.insert(reservation.flight.id).inserted {
            #if DEBUG
                let cleanupID = UUID()
                let tracked = sessionWorktreeOrphanLoadCleanupsByID.count
                    < Self.maximumSessionWorktreeOrphanLoadCleanupRecords
                if !tracked {
                    sessionWorktreeOrphanLoadCleanupOverflowCount &+= 1
                }
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.completeOrphanedSessionWorktreeLoadFlightCleanup(
                        reservation,
                        cleanupID: tracked ? cleanupID : nil
                    )
                }
                if tracked {
                    sessionWorktreeOrphanLoadCleanupsByID[cleanupID] = SessionWorktreeOrphanLoadCleanup(
                        ownerID: reservation.ownerID,
                        standardizedPath: reservation.standardizedPath,
                        task: task
                    )
                }
            #else
                Task { [weak self] in
                    guard let self else { return }
                    await self.completeOrphanedSessionWorktreeLoadFlightCleanup(
                        reservation,
                        cleanupID: nil
                    )
                }
            #endif
        }
    }

    private func completeOrphanedSessionWorktreeLoadFlightCleanup(
        _ reservation: SessionWorktreeReservedLoadFlight,
        cleanupID: UUID?
    ) async {
        if let root = try? await reservation.flight.task.value,
           let identity = reservation.flight.completion.identity(),
           root.id == identity.rootID
        {
            await cleanupOrphanedSessionWorktreeRoots([
                WorkspaceSessionWorktreeOwnedRoot(
                    rootID: identity.rootID,
                    lifetimeID: identity.lifetimeID,
                    standardizedPhysicalPath: reservation.standardizedPath
                )
            ])
        }
        #if DEBUG
            if let cleanupID {
                sessionWorktreeOrphanLoadCleanupsByID.removeValue(forKey: cleanupID)
            } else if sessionWorktreeOrphanLoadCleanupOverflowCount > 0 {
                sessionWorktreeOrphanLoadCleanupOverflowCount -= 1
            }
        #endif
    }

    private func sessionWorktreeOwnerCount(rootID: UUID, lifetimeID: UUID) -> Int {
        sessionWorktreeOwnershipTokensByRootLifetime[
            SessionWorktreeRootLifetimeKey(rootID: rootID, lifetimeID: lifetimeID)
        ]?.count ?? 0
    }

    private func hasAggregateWatcherDemand(rootID: UUID, lifetimeID: UUID) -> Bool {
        let hasPathReservation: Bool = if let state = rootStatesByID[rootID], state.lifetimeID == lifetimeID {
            sessionWorktreeReservationTokensByStandardizedPath[
                state.root.standardizedFullPath
            ]?.isEmpty == false
        } else {
            false
        }
        return explicitWatcherDemandRootIDs.contains(rootID)
            || sessionWorktreeOwnerCount(rootID: rootID, lifetimeID: lifetimeID) > 0
            || hasPathReservation
    }

    private func reconcileAggregateWatcherDemand(rootID: UUID) async throws {
        guard let state = rootStatesByID[rootID] else {
            await waitForCurrentPublisherIngress(rootIDs: [rootID])
            return
        }
        if hasAggregateWatcherDemand(rootID: rootID, lifetimeID: state.lifetimeID) {
            try await ensureWatcherInfrastructure(state: state, rootID: rootID)
            return
        }
        let key = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
        watcherPublisherAttachmentsByKey.removeValue(forKey: key)?.cancellable.cancel()
        publisherIngressCoordinator.closePublisherIngress(rootID: rootID)
        try await reconcileWatcherServiceState(state.service, rootID: rootID)
        await waitForCurrentPublisherIngress(rootIDs: [rootID])
    }

    private func reconcileWatcherServiceState(_ service: FileSystemService, rootID: UUID) async throws {
        while true {
            let shouldWatch = publisherIngressCoordinator.hasOpenPublisherIngress(rootID: rootID)
            #if DEBUG
                if let watcherServiceStateWillReconcileHandler {
                    await watcherServiceStateWillReconcileHandler(rootID, shouldWatch)
                }
            #endif
            if shouldWatch {
                try await service.startWatchingForChanges()
            } else {
                await service.stopWatchingForChanges()
            }
            guard shouldWatch != publisherIngressCoordinator.hasOpenPublisherIngress(rootID: rootID) else { return }
        }
    }

    private func waitForCurrentPublisherIngress(rootIDs: Set<UUID>) async {
        #if DEBUG
            if publisherIngressCoordinator.pendingPublisherIngressCount(rootIDs: rootIDs) > 0,
               let publisherIngressWillWaitHandler
            {
                await publisherIngressWillWaitHandler(rootIDs)
            }
        #endif
        await publisherIngressCoordinator.waitForCurrentPublisherIngress(rootIDs: rootIDs)
    }

    private func yieldFileSystemDeltaEvent(_ event: WorkspaceFileSystemDeltaEvent) {
        for continuation in fileSystemDeltaContinuations.values {
            continuation.yield(event)
        }
    }

    private func yieldAppliedIndexEvent(_ event: WorkspaceAppliedIndexBatchEvent) async {
        // Canonical batches are the only delta authority for search shards. Raw FSEvents first
        // mutate the store indexes and can never patch a published shard directly.
        await applyAppliedIndexEventToRootCatalogShard(event)
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.appliedIndexEventYieldCount += 1
        #endif
        for continuation in appliedIndexContinuations.values {
            continuation.yield(event)
        }
    }

    private func nextAppliedIndexGeneration(forRootID rootID: UUID) -> UInt64 {
        let next = (appliedIndexGenerationsByRootID[rootID] ?? 0) &+ 1
        appliedIndexGenerationsByRootID[rootID] = next
        return next
    }

    func replayObservedFileSystemDeltas(rootID: UUID, deltas: [FileSystemDelta]) async {
        guard let root = rootStatesByID[rootID]?.root else { return }
        await handleObservedFileSystemDeltas(deltas, root: root)
    }

    #if DEBUG
        func replayPublisherFileSystemDeltasForCodemapIndependenceTesting(
            rootID: UUID,
            deltas: [FileSystemDelta],
            servicePublicationSequence: UInt64
        ) async throws {
            let state = try state(for: rootID)
            let preparedDeltas = prepareObservedFileSystemDeltas(deltas, root: state.root)
            await applyPreparedIndexDeltas(
                rootID: rootID,
                deltas: preparedDeltas,
                expectedLifetimeID: state.lifetimeID,
                watcherAcceptedWatermark: nil,
                servicePublicationSequence: servicePublicationSequence,
                publicationCorrelation: nil,
                diagnosticRootToken: state.service.diagnosticRootToken
            )
        }

        func replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: UUID,
            deltas: [FileSystemDelta]
        ) async throws -> PublicationInvalidationDebugSample {
            let root = try state(for: rootID).root
            let preparedDeltas = prepareObservedFileSystemDeltas(deltas, root: root)
            let recorder = await applyPreparedIndexDeltasRecordingInvalidations(
                rootID: rootID,
                deltas: preparedDeltas
            )
            return makePublicationInvalidationDebugSample(
                servicePublicationSequence: 0,
                watcherAcceptedWatermark: nil,
                recorder: recorder
            )
        }

        func publishSyntheticFileSystemDeltasForTesting(rootID: UUID, deltas: [FileSystemDelta]) async throws {
            let state = try state(for: rootID)
            await state.service.publishFileSystemDeltas(deltas, source: .syntheticMutation)
        }

        func publisherIngressCountForTesting(rootID: UUID) -> Int {
            publisherIngressCoordinator.pendingPublisherIngressCount(rootIDs: [rootID])
        }

        func rootWatcherIsActiveForTesting(rootID: UUID) async throws -> Bool {
            let state = try state(for: rootID)
            return await state.service.isWatchingForChangesForTesting()
        }

        func acceptWatcherPayloadForTesting(
            rootID: UUID,
            events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)],
            scheduleDrain: Bool = true
        ) async throws -> FileSystemWatcherIngressMailbox.Watermark? {
            let state = try state(for: rootID)
            return await state.service.acceptWatcherPayloadForTesting(events, scheduleDrain: scheduleDrain)
        }

        func appliedIngressSnapshotForTesting(rootID: UUID) -> WorkspaceFileSystemIngressCoordinator.AppliedSnapshot {
            publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
        }

        func acceptedWatcherWatermarkForTesting(rootID: UUID) throws -> FileSystemWatcherIngressMailbox.Watermark {
            try state(for: rootID).service.captureAcceptedWatcherWatermark()
        }

        func publisherIngressDebugSnapshotForTesting(
            rootID: UUID
        ) -> WorkspaceFileSystemIngressCoordinator.DebugSnapshot {
            publisherIngressCoordinator.debugSnapshot(rootID: rootID)
        }

        func waitUntilPublisherIngressAppliedForTesting(
            rootID: UUID,
            servicePublicationSequence: UInt64
        ) async {
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: servicePublicationSequence
            )
        }

        func rootLifetimeIDForTesting(rootID: UUID) throws -> UUID {
            try state(for: rootID).lifetimeID
        }

        func applyAppliedIndexEventToRootCatalogShardForTesting(
            _ event: WorkspaceAppliedIndexBatchEvent
        ) async {
            await applyAppliedIndexEventToRootCatalogShard(event)
        }

        func recordRootCatalogShardFallbackForTesting(
            rootID: UUID,
            lifetimeID: UUID,
            reason: RootCatalogShardFallbackReason
        ) {
            recordRootCatalogShardFallback(
                rootID: rootID,
                lifetimeID: lifetimeID,
                reason: reason
            )
        }

        func advanceRootCatalogTopologyGenerationForTesting(rootID: UUID) {
            catalogGenerationsByRootID[rootID, default: 0] &+= 1
        }

        func replayPublisherFileSystemPublicationForTesting(
            rootID: UUID,
            expectedLifetimeID: UUID,
            deltas: [FileSystemDelta],
            requiresFullResync: Bool = false
        ) async {
            guard let root = rootStatesByID[rootID]?.root else { return }
            await handleObservedFileSystemDeltas(
                deltas,
                root: root,
                expectedLifetimeID: expectedLifetimeID,
                requiresFullResync: requiresFullResync
            )
        }
    #endif

    private func handleObservedPublisherFileSystemPublication(
        _ publication: FileSystemDeltaPublication,
        root: WorkspaceRootRecord,
        expectedLifetimeID: UUID,
        publicationCorrelation: EditFlowPerf.LifecycleCorrelation?,
        diagnosticRootToken: UUID
    ) async {
        #if DEBUG
            if let watcherSinkWillApplyHandler {
                await watcherSinkWillApplyHandler(root.id)
            }
        #endif
        guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
        #if DEBUG
            MCPApplyEditsRebaseProbeRecorder.recordPublisherIngress(
                rootID: root.id,
                source: publication.source,
                deltas: publication.deltas
            )
        #endif
        if publication.source == .overflowRootRescan || publication.source == .recoveryFullResync {
            await invalidateRetainedSearchContentForRecoveryUncertainty(rootID: root.id)
            guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
        }
        await handleObservedFileSystemDeltas(
            publication.deltas,
            root: root,
            expectedLifetimeID: expectedLifetimeID,
            publicationCorrelation: publicationCorrelation,
            diagnosticRootToken: diagnosticRootToken,
            watcherAcceptedWatermark: publication.watcherAcceptedWatermark,
            servicePublicationSequence: publication.servicePublicationSequence,
            requiresFullResync: publication.requiresFullResync
        )
    }

    private func handleObservedFileSystemDeltas(
        _ deltas: [FileSystemDelta],
        root: WorkspaceRootRecord,
        expectedLifetimeID: UUID? = nil,
        publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        diagnosticRootToken: UUID? = nil,
        watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark? = nil,
        servicePublicationSequence: UInt64? = nil,
        requiresFullResync: Bool = false
    ) async {
        guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
        for delta in deltas {
            guard await isDiscoveryFacingFileSystemDelta(delta, rootID: root.id) else { continue }
            guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
            yieldFileSystemDeltaEvent(WorkspaceFileSystemDeltaEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                delta: delta
            ))
        }
        let preparedDeltas = prepareObservedFileSystemDeltas(deltas, root: root)
        #if DEBUG
            await applyPreparedIndexDeltas(
                rootID: root.id,
                deltas: preparedDeltas,
                expectedLifetimeID: expectedLifetimeID,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                servicePublicationSequence: servicePublicationSequence,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken,
                requiresFullResync: requiresFullResync
            )
        #else
            await applyPreparedIndexDeltas(
                rootID: root.id,
                deltas: preparedDeltas,
                expectedLifetimeID: expectedLifetimeID,
                servicePublicationSequence: servicePublicationSequence,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken,
                requiresFullResync: requiresFullResync
            )
        #endif
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.WorkspaceIngress.storeCanonicalApplyCompleted,
            correlation: publicationCorrelation,
            EditFlowPerf.Dimensions(
                appliedCount: preparedDeltas.count,
                rootToken: diagnosticRootToken?.uuidString,
                ingressSequence: watcherAcceptedWatermark?.rawValue,
                barrierSequence: servicePublicationSequence
            )
        )
    }

    private func prepareObservedFileSystemDeltas(
        _ deltas: [FileSystemDelta],
        root: WorkspaceRootRecord
    ) -> [PreparedFileSystemDelta] {
        FileSystemDeltaPreparation.coalesce(deltas, inRoot: root.standardizedFullPath)
            .compactMap { FileSystemDeltaPreparation.prepare($0, inRoot: root.standardizedFullPath) }
    }

    private func isDiscoveryFacingFileSystemDelta(_ delta: FileSystemDelta, rootID: UUID) async -> Bool {
        guard let state = rootStatesByID[rootID] else { return false }
        switch delta {
        case let .fileAdded(relativePath):
            return await state.service.catalogEligibleRegularFileExists(relativePath: relativePath)
        case let .folderAdded(relativePath):
            return await state.service.catalogFolderIsDiscoverable(relativePath: relativePath)
        case let .fileRemoved(relativePath), let .fileModified(relativePath, _):
            guard let file = await file(rootID: rootID, relativePath: relativePath) else { return false }
            return isDiscoverableFileID(file.id)
        case let .folderRemoved(relativePath), let .folderModified(relativePath, _):
            guard let folder = await folder(rootID: rootID, relativePath: relativePath) else { return false }
            return isDiscoverableFolderID(folder.id)
        }
    }

    func files(inRoot rootID: UUID) async -> [WorkspaceFileRecord] {
        #if DEBUG
            filesInRootRequestCountForTesting += 1
        #endif
        guard let pageIndex = await fetchFileTreePageIndex(rootID: rootID) else { return [] }
        return pageIndex.filesByID.values
            .filter { isDiscoverableFileID($0.id) }
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    /// P4-6b table-deletion conversion: only a bare id is known here (no root, no path), so the
    /// owning root/record must come from a scope-wide id fact rather than a global dict lookup.
    func file(id fileID: UUID) async -> WorkspaceFileRecord? {
        guard isDiscoverableFileID(fileID),
              let authority = try? await inventoryScopeAuthorityInstance(),
              let block = try? await authority.resolveRecordsScopeWide(fileIDs: [fileID], folderIDs: []),
              let fact = block.filesByID[fileID]
        else { return nil }
        return WorkspaceInventoryScopeRepublicationAdapter.workspaceFileRecord(id: fileID, fact: fact)
    }

    private struct LoadedRootReusableSnapshotCurrentness {
        let rootID: UUID
        let lifetimeID: UUID
        let standardizedPath: String
        let catalogGeneration: UInt64
        let appliedIndexGeneration: UInt64
        let acceptedWatcherWatermark: UInt64
        let acceptedServicePublicationSequence: UInt64
    }

    private func loadedRootReusableSnapshotCurrentness(
        _ currentness: LoadedRootReusableSnapshotCurrentness
    ) -> WorkspaceRootReusableSnapshotCoordinator.CurrentnessValidation {
        guard let state = rootStatesByID[currentness.rootID],
              state.lifetimeID == currentness.lifetimeID,
              state.root.standardizedFullPath == currentness.standardizedPath
        else {
            return .stale(.loadedRootOwnerStale)
        }
        guard catalogGenerationsByRootID[currentness.rootID] == currentness.catalogGeneration,
              appliedIndexGenerationsByRootID[currentness.rootID] == currentness.appliedIndexGeneration
        else {
            return .stale(.loadedRootCatalogStale)
        }
        guard state.service.captureAcceptedWatcherWatermark().rawValue == currentness.acceptedWatcherWatermark else {
            return .stale(.loadedRootWatcherStale)
        }
        let ingress = publisherIngressCoordinator.appliedSnapshot(rootID: currentness.rootID)
        guard ingress.acceptedServicePublicationSequence == currentness.acceptedServicePublicationSequence,
              ingress.appliedServicePublicationSequence >= currentness.acceptedServicePublicationSequence,
              ingress.appliedWatcherWatermark.rawValue >= currentness.acceptedWatcherWatermark
        else {
            return .stale(.loadedRootWatcherStale)
        }
        return .current
    }

    private func loadedRootCatalogBatchEvidence(
        currentness: LoadedRootReusableSnapshotCurrentness,
        relativePaths: [String],
        service: FileSystemService,
        expectedPolicyIdentity: WorkspaceRootCatalogPolicyIdentity
    ) async -> WorkspaceRootReusableSnapshotCoordinator.CatalogBatchEvidenceResult {
        switch loadedRootReusableSnapshotCurrentness(currentness) {
        case .current:
            break
        case let .stale(cause):
            return .stale(cause)
        }
        guard let state = rootStatesByID[currentness.rootID], state.service === service,
              let exactPaths = WorkspaceRootByteExactPathSet(relativePaths, rejectExactDuplicates: true)
        else { return .stale(.loadedRootOwnerStale) }
        // OI-2 fix (contract doc §12.5 resolution): `state.fileIDsByRelativePath` is only ever
        // populated by the legacy bulk-crawl choke points (`indexFiles`/`indexFolders`, plural,
        // used solely by the initial `loadRoot` crawl). Every live/incremental discovery path
        // post-P4-6b (`indexFile`/`indexFolder`, singular -- watcher events, worktree creation,
        // seeded-root replay) routes straight through the Rust authority and never touches this
        // Swift dict, so a file discovered any way other than the initial crawl always read back
        // `nil` here -- `discoverable = false` for a genuinely discoverable, tracked file -- and
        // tripped the `(true, _)`/`(false, _)` mismatch branch below against real git evidence,
        // unconditionally producing `.catalogMismatch`. `inventoryPathLookups(in:relativePaths:)`
        // (the same batched Rust-authoritative path/discoverability fact lookup already used by
        // the codemap/B1/bucket-C read sites) is the live replacement.
        let pathLookups = await inventoryPathLookups(in: state, relativePaths: exactPaths.sortedKeys.map(\.value))
        var discoverableByPath: [WorkspaceRootByteExactPathKey: Bool] = [:]
        discoverableByPath.reserveCapacity(exactPaths.count)
        for path in exactPaths.sortedKeys {
            discoverableByPath[path] = pathLookups.files[path.value]?.isDiscoverable ?? false
        }
        guard let evidence = await service.catalogProjectionEvidence(
            forCommittedRegularPaths: exactPaths
        ) else { return .stale(.loadedRootCatalogStale) }
        switch loadedRootReusableSnapshotCurrentness(currentness) {
        case .current:
            break
        case let .stale(cause):
            return .stale(cause)
        }
        guard evidence.policyIdentity == expectedPolicyIdentity,
              Set(evidence.dispositionsByRelativePath.keys) == exactPaths.keys
        else { return .stale(.loadedRootCatalogStale) }
        for (path, disposition) in evidence.dispositionsByRelativePath {
            let discoverable = discoverableByPath[path] == true
            switch (discoverable, disposition) {
            case (true, .searchableRegularFile), (false, .policyIgnoredRegularFile):
                break
            case (true, _), (false, _):
                return .catalogMismatch
            }
        }
        return .evidence(evidence)
    }

    func admitReusableSnapshotForLoadedRoot(
        rootID: UUID,
        expectedStandardizedPath: String,
        prefixControlEvidenceCacheMode: GitPrefixControlEvidenceCacheMode = .bypassReadAndAdmission
    ) async throws -> WorkspaceRootReusableSnapshotCoordinator.ObservationResult {
        guard !Task.isCancelled else {
            return .failed(.init(stage: .loadedRootValidation, cause: .cancelled))
        }
        guard let initialState = rootStatesByID[rootID],
              initialState.root.standardizedFullPath == expectedStandardizedPath
        else {
            return .failed(.init(stage: .loadedRootValidation, cause: .loadedRootOwnerStale))
        }
        let initialLifetimeID = initialState.lifetimeID
        let rootRef = WorkspaceRootRef(
            id: initialState.root.id,
            name: initialState.root.name,
            fullPath: initialState.root.standardizedFullPath
        )
        let ingressSamples = await {
            #if DEBUG
                let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                    .begin(.loadedRootIngressFence)
                defer { span?.end() }
            #endif
            return await awaitAppliedIngress(rootRefs: [rootRef])
        }()
        guard !Task.isCancelled else {
            return .failed(.init(stage: .initialCurrentness, cause: .cancelled))
        }
        guard ingressSamples.count == 1,
              let ingressSample = ingressSamples.first,
              ingressSample.rootID == rootID,
              ingressSample.rootPath == expectedStandardizedPath
        else {
            return .failed(.init(stage: .initialCurrentness, cause: .loadedRootWatcherStale))
        }
        guard let state = rootStatesByID[rootID],
              state.lifetimeID == initialLifetimeID,
              state.root.standardizedFullPath == expectedStandardizedPath
        else {
            return .failed(.init(stage: .initialCurrentness, cause: .loadedRootOwnerStale))
        }
        guard let catalogGeneration = catalogGenerationsByRootID[rootID],
              let appliedIndexGeneration = appliedIndexGenerationsByRootID[rootID]
        else {
            return .failed(.init(stage: .initialCurrentness, cause: .loadedRootCatalogStale))
        }

        let acceptedWatcherWatermark = state.service.captureAcceptedWatcherWatermark().rawValue
        let ingress = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
        guard ingressSample.appliedWatcherWatermark >= acceptedWatcherWatermark,
              ingressSample.appliedServicePublicationSequence >= ingress.acceptedServicePublicationSequence,
              ingress.appliedWatcherWatermark.rawValue >= acceptedWatcherWatermark,
              ingress.appliedServicePublicationSequence >= ingress.acceptedServicePublicationSequence
        else {
            return .failed(.init(stage: .initialCurrentness, cause: .loadedRootWatcherStale))
        }

        let currentness = LoadedRootReusableSnapshotCurrentness(
            rootID: rootID,
            lifetimeID: initialLifetimeID,
            standardizedPath: expectedStandardizedPath,
            catalogGeneration: catalogGeneration,
            appliedIndexGeneration: appliedIndexGeneration,
            acceptedWatcherWatermark: acceptedWatcherWatermark,
            acceptedServicePublicationSequence: ingress.acceptedServicePublicationSequence
        )
        switch loadedRootReusableSnapshotCurrentness(currentness) {
        case .current:
            break
        case let .stale(cause):
            return .failed(.init(stage: .initialCurrentness, cause: cause))
        }
        let rootURL = URL(fileURLWithPath: expectedStandardizedPath).standardizedFileURL
        let service = state.service
        let catalogPolicyIdentity = await {
            #if DEBUG
                let span = WorktreeStartupPreparationInstrumentation.currentRecorder?
                    .begin(.loadedRootPolicySnapshot)
                defer { span?.end() }
            #endif
            return await service.currentWorkspaceRootCatalogPolicyIdentity()
        }()

        let result = await rootReusableSnapshotCoordinator.observeStreamedAuthoritativeFullLoad(
            rootURL: rootURL,
            catalogPolicyIdentity: catalogPolicyIdentity,
            prefixControlEvidenceCacheMode: prefixControlEvidenceCacheMode,
            catalogBatchEvidenceProvider: { [weak self] relativePaths in
                guard let self else { return .stale(.loadedRootOwnerStale) }
                return await loadedRootCatalogBatchEvidence(
                    currentness: currentness,
                    relativePaths: relativePaths,
                    service: service,
                    expectedPolicyIdentity: catalogPolicyIdentity
                )
            },
            currentnessValidator: { [weak self] in
                guard let self else { return .stale(.loadedRootOwnerStale) }
                return await loadedRootReusableSnapshotCurrentness(currentness)
            }
        )
        guard case let .admitted(snapshotIdentity) = result else {
            return result
        }
        #if DEBUG
            let finalCurrentnessSpan = WorktreeStartupPreparationInstrumentation.currentRecorder?
                .begin(.finalLoadedRootCurrentness)
            defer { finalCurrentnessSpan?.end() }
        #endif
        if Task.isCancelled {
            await workspaceStateAuthority.revokeReusableSnapshotAdmissions(
                snapshotIdentity: snapshotIdentity
            )
            return .failed(.init(stage: .finalLoadedRootCurrentness, cause: .cancelled))
        }
        switch loadedRootReusableSnapshotCurrentness(currentness) {
        case .current:
            return result
        case let .stale(cause):
            await workspaceStateAuthority.revokeReusableSnapshotAdmissions(
                snapshotIdentity: snapshotIdentity
            )
            return .failed(.init(stage: .finalLoadedRootCurrentness, cause: cause))
        }
    }

    /// Item 0 fix (P4-7b tail, P4-6b regression): includes the synthesized root-marker folder
    /// (relativePath == ""), matching the pre-P4-6b table's `folderIDsByRelativePath` which always
    /// carried it under the "" key. `GitWorktreeCreationReceiptTests` already `.subtracting([""])`
    /// in anticipation of this.
    func folders(inRoot rootID: UUID) async -> [WorkspaceFolderRecord] {
        guard let pageIndex = await fetchFileTreePageIndex(rootID: rootID) else { return [] }
        var folders = pageIndex.foldersByID.values
            .filter { isDiscoverableFolderID($0.id) }
        if let marker = rootFolderRecord(rootID: rootID) {
            folders.append(marker)
        }
        return folders.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    // MARK: - P4-6a fact-returning inventory read surface

    ///
    /// `inventoryRecordFacts` is the Swift-authority precursor to Rust's
    /// `inventoryResolveRecords` (docs/architecture/rust-inventory-scope-v1.md §5.3,
    /// docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md §4.3.1.1). It
    /// returns per-id INDEPENDENT FACTS about exactly the ten inventory tables named in
    /// Appendix A of that design -- never a verdict. Every codemap call site (B1/B3) and
    /// `appliedIndexRecordLookup` itself compose their own predicate from these facts;
    /// this function filters nothing and must never gain a table it doesn't already
    /// read here. Absent ids resolve to `record == nil`; the other fields are then
    /// meaningless and must not be consulted (mirrors R1 gating R2..R5 in the reference
    /// predicate).
    ///
    /// Deliberately excluded from the fact block, and left as call-site reads exactly
    /// where they sit today: `rootStatesByID` existence/`publishedSeededAuthorityIsQueryable`
    /// (function-level gates, not per-id facts -- folding them in here would silently add
    /// a clause at every B1 site, none of which gates on them today), and any
    /// codemap-owned state (`catalogGenerationsByRootID`, `codemapSessionsByRootEpoch`,
    /// `allowedRootIDs`, path-shape validation) which is not one of the ten inventory
    /// tables and is out of P4's scope entirely.
    struct WorkspaceInventoryFileRecordFact {
        /// R1: `filesByID[fileID]`. `nil` means the id does not exist; every other
        /// field is then meaningless.
        let record: WorkspaceFileRecord?
        /// R3: the record's own root's `fileIDsByRelativePath[record.standardizedRelativePath] == fileID`.
        let pathRoundTripsToSelf: Bool
        /// R4: `isDiscoverableFileID(fileID)`.
        let isDiscoverable: Bool
    }

    struct WorkspaceInventoryFolderRecordFact {
        /// R1: `foldersByID[folderID]`. `nil` means the id does not exist; every other
        /// field is then meaningless.
        let record: WorkspaceFolderRecord?
        /// R3: the record's own root's `folderIDsByRelativePath[record.standardizedRelativePath] == folderID`.
        let pathRoundTripsToSelf: Bool
        /// R4: `isDiscoverableFolderID(folderID)`.
        let isDiscoverable: Bool
    }

    /// One synchronous, atomic read of the ten inventory tables for every requested id,
    /// files and folders together in a single call so per-scan callers (codemap) and
    /// `appliedIndexRecordLookup` share one DEBUG request-count instrumentation point
    /// (P4-6a done-when: the four `appliedIndexRecordLookupDiagnosticsForTesting`
    /// consumers observe the per-scan call shape). No `await` occurs anywhere in this
    /// function, so all facts are mutually consistent against one generation.
    /// P4-6b prep slice 1: `async` so this primitive is delegation-capable (Rust's
    /// `resolveRecords` is an FFI call, inherently async), while its body still reads
    /// Swift's authoritative tables directly -- authority is unchanged in this slice.
    /// P4-6b table-deletion conversion (ledger entry `inventoryRecordFacts`): routes through the
    /// Rust authority's scope-wide id resolve instead of the deleted `filesByID`/`foldersByID`
    /// globals and `RootState`'s per-root path maps. `pathRoundTripsToSelf`/`isDiscoverable` are
    /// now read directly off the fact block -- Rust's own resolve already re-derives R3/R4
    /// against its authoritative tables under the same lock acquisition as R1 (contract doc
    /// §5.3), so there is no separate `rootStatesByID`/discoverability-set read needed here.
    func inventoryRecordFacts(
        fileIDs: [UUID],
        folderIDs: [UUID]
    ) async -> (
        filesByID: [UUID: WorkspaceInventoryFileRecordFact],
        foldersByID: [UUID: WorkspaceInventoryFolderRecordFact]
    ) {
        #if DEBUG
            appliedIndexRecordLookupRequestCountForTesting += 1
            appliedIndexRecordLookupRequestedRecordCountForTesting += fileIDs.count + folderIDs.count
        #endif
        guard let authority = try? await inventoryScopeAuthorityInstance(),
              let block = try? await authority.resolveRecordsScopeWide(fileIDs: fileIDs, folderIDs: folderIDs)
        else {
            let absentFiles = Dictionary(uniqueKeysWithValues: fileIDs.map {
                ($0, WorkspaceInventoryFileRecordFact(record: nil, pathRoundTripsToSelf: false, isDiscoverable: false))
            })
            let absentFolders = Dictionary(uniqueKeysWithValues: folderIDs.map {
                ($0, WorkspaceInventoryFolderRecordFact(record: nil, pathRoundTripsToSelf: false, isDiscoverable: false))
            })
            return (absentFiles, absentFolders)
        }

        var files: [UUID: WorkspaceInventoryFileRecordFact] = [:]
        files.reserveCapacity(fileIDs.count)
        for fileID in fileIDs {
            guard let fact = block.filesByID[fileID], fact.exists else {
                files[fileID] = WorkspaceInventoryFileRecordFact(
                    record: nil,
                    pathRoundTripsToSelf: false,
                    isDiscoverable: false
                )
                continue
            }
            files[fileID] = WorkspaceInventoryFileRecordFact(
                record: WorkspaceInventoryScopeRepublicationAdapter.workspaceFileRecord(id: fileID, fact: fact),
                pathRoundTripsToSelf: fact.pathRoundTripsToSelf,
                isDiscoverable: fact.isDiscoverable
            )
        }

        var folders: [UUID: WorkspaceInventoryFolderRecordFact] = [:]
        folders.reserveCapacity(folderIDs.count)
        for folderID in folderIDs {
            guard let fact = block.foldersByID[folderID], fact.exists else {
                folders[folderID] = WorkspaceInventoryFolderRecordFact(
                    record: nil,
                    pathRoundTripsToSelf: false,
                    isDiscoverable: false
                )
                continue
            }
            folders[folderID] = WorkspaceInventoryFolderRecordFact(
                record: WorkspaceInventoryScopeRepublicationAdapter.workspaceFolderRecord(id: folderID, fact: fact),
                pathRoundTripsToSelf: fact.pathRoundTripsToSelf,
                isDiscoverable: fact.isDiscoverable
            )
        }

        return (files, folders)
    }

    /// Verdict-returning facade over `inventoryRecordFacts`, kept byte-for-byte
    /// behavior-identical to its pre-P4-6a form for its two existing external
    /// consumers (`AgentContextFileBrowseService`, `WorkspaceFilesViewModel`), per
    /// design §4.3.1 point 5 ("it is already a supported external API... becomes a
    /// thin facade"). R5 (`filesByID[fileID] == record`) is dropped rather than
    /// emulated: both operands come from the same live synchronous read with no
    /// `await` between bind and compare, so on an actor the comparison is an
    /// unfalsifiable tautology (design §4.3.1.1 result 2, D-11). The DEBUG counters
    /// increment exactly once per call, on every path, matching the pre-refactor
    /// function which incremented before its early-return guard.
    /// P4-6b prep slice 1: `async` for the same reason as `inventoryRecordFacts`, which
    /// this delegates to.
    func appliedIndexRecordLookup(
        rootID: UUID,
        fileIDs: [UUID],
        folderIDs: [UUID]
    ) async -> WorkspaceAppliedIndexRecordLookup? {
        guard publishedSeededAuthorityIsQueryable(rootID: rootID),
              let state = rootStatesByID[rootID]
        else {
            #if DEBUG
                appliedIndexRecordLookupRequestCountForTesting += 1
                appliedIndexRecordLookupRequestedRecordCountForTesting += fileIDs.count + folderIDs.count
            #endif
            return nil
        }

        let facts = await inventoryRecordFacts(fileIDs: fileIDs, folderIDs: folderIDs)

        var matchingFilesByID: [UUID: WorkspaceFileRecord] = [:]
        matchingFilesByID.reserveCapacity(fileIDs.count)
        for fileID in fileIDs {
            guard let fact = facts.filesByID[fileID],
                  let record = fact.record,
                  record.rootID == rootID,
                  fact.pathRoundTripsToSelf,
                  fact.isDiscoverable
            else { continue }
            matchingFilesByID[fileID] = record
        }

        var matchingFoldersByID: [UUID: WorkspaceFolderRecord] = [:]
        matchingFoldersByID.reserveCapacity(folderIDs.count)
        for folderID in folderIDs {
            guard let fact = facts.foldersByID[folderID],
                  let record = fact.record,
                  record.rootID == rootID,
                  fact.pathRoundTripsToSelf,
                  fact.isDiscoverable
            else { continue }
            matchingFoldersByID[folderID] = record
        }

        return WorkspaceAppliedIndexRecordLookup(
            root: state.root,
            generation: appliedIndexGenerationsByRootID[rootID] ?? 0,
            filesByID: matchingFilesByID,
            foldersByID: matchingFoldersByID
        )
    }

    // MARK: - P4-6a path-keyed inventory read surface

    struct WorkspaceInventoryPathFileFact {
        /// `state.fileIDsByRelativePath[path]` for the queried root's state.
        let fileID: UUID?
        /// `filesByID[fileID]`, present only when `fileID` resolved.
        let record: WorkspaceFileRecord?
        /// `isDiscoverableFileID(fileID)`; `false` when `fileID` is `nil`.
        let isDiscoverable: Bool
    }

    struct WorkspaceInventoryPathFolderFact {
        /// `state.folderIDsByRelativePath[path]` for the queried root's state.
        let folderID: UUID?
        /// `foldersByID[folderID]`, present only when `folderID` resolved.
        let record: WorkspaceFolderRecord?
        /// `isDiscoverableFolderID(folderID)`; `false` when `folderID` is `nil`.
        let isDiscoverable: Bool
    }

    /// Batch path→ID fact lookup, the Swift-authority precursor to Rust's
    /// `inventoryLookupPaths` (design §4.3.1.1 result 3, §4.3.1.2; architecture §5.3).
    /// Serves B3 (`destructiveCodemapGraphFence`, `retainCodemapRootStatusCoverageAcrossPathInvalidation`),
    /// the path-keyed B1 sites, and bucket C's `prepareSessionWorktreeOwnership` manifest
    /// loop. One call per scan resolves every requested relative path against one root's
    /// `fileIDsByRelativePath` / `folderIDsByRelativePath`, atomically with the id-keyed
    /// records they resolve to — facts, not a verdict; absent paths resolve to `nil` ids.
    /// P4-6b prep slice 1: `async` for the same reason as `inventoryRecordFacts`.
    func inventoryPathLookups(
        rootID: UUID,
        relativePaths: some Sequence<String>
    ) async -> (
        files: [String: WorkspaceInventoryPathFileFact],
        folders: [String: WorkspaceInventoryPathFolderFact]
    ) {
        guard let state = rootStatesByID[rootID] else { return ([:], [:]) }
        return await inventoryPathLookups(in: state, relativePaths: relativePaths)
    }

    // P4-6b table-deletion conversion (ledger entries `inventoryPathLookups(in:)` /
    // `inventoryFileRecordFacts(in:)`): the "state-scoped, not a live re-fetch" distinction
    // these two overloads existed for is moot now that path/id resolution is itself an
    // inherently-live, atomic-under-one-Rust-lock call (contract doc §5.3) rather than a
    // dictionary read against a value the caller could stash across a suspension point --
    // there is no longer a "stale captured table" for `state` to protect against, only
    // `state.root.id` to route the request at. Both overloads now delegate straight to their
    // `rootID`-keyed siblings.
    private func inventoryPathLookups(
        in state: RootState,
        relativePaths: some Sequence<String>
    ) async -> (
        files: [String: WorkspaceInventoryPathFileFact],
        folders: [String: WorkspaceInventoryPathFolderFact]
    ) {
        guard let authority = try? await inventoryScopeAuthorityInstance() else { return ([:], [:]) }
        var files: [String: WorkspaceInventoryPathFileFact] = [:]
        var folders: [String: WorkspaceInventoryPathFolderFact] = [:]
        var uniquePaths: [String] = []
        var seenPaths = Set<String>()
        #if DEBUG
            var requestedPathCountForTesting = 0
        #endif
        for path in relativePaths {
            #if DEBUG
                requestedPathCountForTesting += 1
            #endif
            if seenPaths.insert(path).inserted {
                uniquePaths.append(path)
            }
        }
        if let lookup = try? await authority.lookupPaths(rootID: state.root.id, relativePaths: uniquePaths) {
            for path in uniquePaths {
                guard let fact = lookup.factsByPath[path] else {
                    files[path] = WorkspaceInventoryPathFileFact(fileID: nil, record: nil, isDiscoverable: false)
                    folders[path] = WorkspaceInventoryPathFolderFact(folderID: nil, record: nil, isDiscoverable: false)
                    continue
                }
                files[path] = WorkspaceInventoryPathFileFact(
                    fileID: fact.fileID,
                    record: fact.fileID.flatMap { WorkspaceInventoryScopeRepublicationAdapter.workspaceFileRecord(id: $0, fact: fact) },
                    isDiscoverable: fact.fileID != nil ? fact.isDiscoverable : false
                )
                folders[path] = WorkspaceInventoryPathFolderFact(
                    folderID: fact.folderID,
                    record: fact.folderID.flatMap { WorkspaceInventoryScopeRepublicationAdapter.workspaceFolderRecord(id: $0, fact: fact) },
                    isDiscoverable: fact.folderID != nil ? fact.isDiscoverable : false
                )
            }
        } else {
            for path in uniquePaths {
                files[path] = WorkspaceInventoryPathFileFact(fileID: nil, record: nil, isDiscoverable: false)
                folders[path] = WorkspaceInventoryPathFolderFact(folderID: nil, record: nil, isDiscoverable: false)
            }
        }
        #if DEBUG
            appliedIndexRecordLookupRequestCountForTesting += 1
            appliedIndexRecordLookupRequestedRecordCountForTesting += requestedPathCountForTesting
        #endif
        return (files, folders)
    }

    /// Delegates straight to `inventoryRecordFacts`, which already owns the DEBUG request-count
    /// increment (once per call, `fileIDs.count` -- the raw, non-deduped input array, matching
    /// this function's pre-conversion counting exactly). Duplicate ids collapse harmlessly into
    /// the same dictionary key.
    private func inventoryFileRecordFacts(
        in state: RootState,
        fileIDs: some Sequence<UUID>
    ) async -> [UUID: WorkspaceInventoryFileRecordFact] {
        await inventoryRecordFacts(fileIDs: Array(fileIDs), folderIDs: []).filesByID
    }

    // MARK: - P4-6a bucket-C aggregates (§4.3.1.2)

    ///
    /// Swift-authority precursor to Rust's O(1) `discoverableFileCount` /
    /// `discoverableFolderCount` per-root counters. The Rust side maintains these
    /// incrementally at every one of the 16 A2 mutation scopes (Appendix A) and pins
    /// them with a counter-equals-traversal differential (P4-3a done-when); that
    /// incremental-maintenance machinery and its differential are NOT built here --
    /// undertaking it now, without that differential harness, across 16 mutation sites
    /// in a step whose gate is behavior preservation would trade a correctness risk
    /// (a missed decrement silently diverging the counter from ground truth) for an
    /// optimization this step does not require, since Swift already computes the count
    /// cheaply today. What P4-6a rewires is the *call shape*: `prepareSessionWorktreeOwnership`
    /// now calls one named, documented function instead of inlining the traversal, so
    /// the P4-6b cutover replaces this function's body with a field read and touches no
    /// call site. Flagged explicitly, not silently deferred -- see the P4-6a report.
    /// P4-6b table-deletion conversion: pages the whole root once via the Tier-1 ephemeral index
    /// (`fetchFileTreePageIndex`, §6.1) rather than the deleted per-root path maps. Rust's own
    /// O(1) incrementally-maintained counters (referenced in this function's own doc comment
    /// above) are still not built -- this remains a full traversal, same deviation the P4-6a
    /// delta table already recorded, now against the paged Rust read instead of a local
    /// dictionary. The root-marker folder (`relativePath == ""`) is never sent to Rust in the
    /// first place (root-marker exclusion, `makePendingSeededRootTopology`'s doc comment), so
    /// the old `!relativePath.isEmpty` guard has no equivalent left to preserve.
    private func discoverableFileCount(in state: RootState) async -> Int {
        guard let pageIndex = await fetchFileTreePageIndex(rootID: state.root.id) else { return 0 }
        return pageIndex.filesByID.keys.count(where: isDiscoverableFileID)
    }

    private func discoverableFolderCount(in state: RootState) async -> Int {
        guard let pageIndex = await fetchFileTreePageIndex(rootID: state.root.id) else { return 0 }
        return pageIndex.foldersByID.keys.count(where: isDiscoverableFolderID)
    }

    func appliedIndexRootSnapshot(rootID: UUID) async -> WorkspaceAppliedIndexRootSnapshot? {
        #if DEBUG
            appliedIndexRootSnapshotRequestCountForTesting += 1
        #endif
        guard publishedSeededAuthorityIsQueryable(rootID: rootID),
              let root = rootStatesByID[rootID]?.root
        else { return nil }
        return await WorkspaceAppliedIndexRootSnapshot(
            root: root,
            generation: appliedIndexGenerationsByRootID[rootID] ?? 0,
            files: files(inRoot: rootID),
            folders: folders(inRoot: rootID)
        )
    }

    struct ReadFileAutoSelectionCatalogValidationSnapshot: Equatable {
        let visibleCatalogGeneration: UInt64
        let rootScopeCatalogGeneration: UInt64
        let rootScopeAvailability: WorkspaceLookupRootScopeAvailability
    }

    func readFileAutoSelectionCatalogValidationSnapshot(
        rootScope: WorkspaceLookupRootScope
    ) -> ReadFileAutoSelectionCatalogValidationSnapshot {
        ReadFileAutoSelectionCatalogValidationSnapshot(
            visibleCatalogGeneration: scopedSnapshotGeneration(scope: .visibleWorkspace),
            rootScopeCatalogGeneration: scopedSnapshotGeneration(scope: rootScope),
            rootScopeAvailability: rootScopeAvailability(rootScope)
        )
    }

    func catalogGeneration(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) -> UInt64 {
        scopedSnapshotGeneration(scope: rootScope)
    }

    func catalogDiagnostics(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) async -> WorkspaceCatalogDiagnostics {
        let roots = rootsForPathLookup(scope: rootScope)
        var folderCount = 0
        var fileCount = 0
        for root in roots {
            guard let pageIndex = await fetchFileTreePageIndex(rootID: root.id) else { continue }
            folderCount += pageIndex.foldersByID.keys.count(where: isDiscoverableFolderID)
            fileCount += pageIndex.filesByID.keys.count(where: isDiscoverableFileID)
        }
        return WorkspaceCatalogDiagnostics(
            generation: scopedSnapshotGeneration(scope: rootScope),
            rootScope: rootScope,
            rootCount: roots.count,
            folderCount: folderCount,
            fileCount: fileCount
        )
    }

    func withStoreBackedSearchAccess<T>(
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass?,
        operation: @Sendable (FileSearchActor) async throws -> T
    ) async throws -> T {
        try await storeBackedSearchLane.withSearchAccess(
            searchMode: searchMode,
            admissionClass: admissionClass,
            operation: operation
        )
    }

    func sessionBoundRootScopeValidationSnapshot(
        _ rootScope: WorkspaceLookupRootScope,
        expectedPhysicalRoots: [WorkspaceRootRef]
    ) -> WorkspaceSessionRootLifetimeSnapshot? {
        guard !expectedPhysicalRoots.isEmpty else { return nil }
        let expectedPaths = Set(expectedPhysicalRoots.map(\.standardizedFullPath))
        let requestedMatches: Bool
        switch rootScope {
        case let .sessionBoundWorkspace(_, requestedPhysicalRootPaths):
            requestedMatches = Set(requestedPhysicalRootPaths.map {
                StandardizedPath.absolute(($0 as NSString).expandingTildeInPath)
            }) == expectedPaths
        case let .validatedSessionBoundWorkspace(canonicalRoots, requestedPhysicalRoots):
            let requestedValidation = WorkspaceLookupRootSelectorValidator.validate(
                canonicalRoots: canonicalRoots,
                physicalRoots: requestedPhysicalRoots
            )
            let expectedValidation = WorkspaceLookupRootSelectorValidator.validate(
                canonicalRoots: [],
                physicalRoots: Set(expectedPhysicalRoots)
            )
            if case let .valid(requestedSelector) = requestedValidation,
               case let .valid(expectedSelector) = expectedValidation
            {
                requestedMatches = requestedSelector.physicalRootPathsByID
                    == expectedSelector.physicalRootPathsByID
            } else {
                requestedMatches = false
            }
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded, .allLoadedExcludingGitData:
            requestedMatches = false
        }
        guard requestedMatches,
              expectedPhysicalRoots.allSatisfy({ expectedRoot in
                  guard let currentRoot = rootStatesByID[expectedRoot.id]?.root else { return false }
                  return currentRoot.kind == .sessionWorktree
                      && currentRoot.standardizedFullPath == expectedRoot.standardizedFullPath
              })
        else { return nil }
        guard rootScopeAvailability(rootScope) == .available else { return nil }

        return sessionRootLifetimeClock.snapshot(physicalRootPaths: expectedPaths.sorted())
    }

    func rootScopeAvailability(_ rootScope: WorkspaceLookupRootScope) -> WorkspaceLookupRootScopeAvailability {
        let missing: [String]
        switch rootScope {
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded, .allLoadedExcludingGitData:
            return .available
        case let .sessionBoundWorkspace(requestedCanonicalRootPaths, requestedPhysicalRootPaths):
            guard !requestedCanonicalRootPaths.isEmpty || !requestedPhysicalRootPaths.isEmpty else {
                return .sessionWorktreeUnavailable(missingPhysicalRootPaths: [])
            }
            let requested = Set(requestedPhysicalRootPaths.map {
                StandardizedPath.absolute(($0 as NSString).expandingTildeInPath)
            })
            missing = requested.filter { path in
                guard let rootID = rootIDsByStandardizedPath[path],
                      rootStatesByID[rootID]?.root.kind == .sessionWorktree,
                      publishedSeededAuthorityIsQueryable(rootID: rootID)
                else { return true }
                var isDirectory: ObjCBool = false
                return !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) ||
                    !isDirectory.boolValue
            }.sorted()
        case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots):
            guard !canonicalRoots.isEmpty || !physicalRoots.isEmpty else {
                return .sessionWorktreeUnavailable(missingPhysicalRootPaths: [])
            }
            guard case let .valid(selector) = WorkspaceLookupRootSelectorValidator.validate(
                canonicalRoots: canonicalRoots,
                physicalRoots: physicalRoots
            ) else {
                return .sessionWorktreeUnavailable(missingPhysicalRootPaths: [])
            }
            missing = (
                selector.canonicalRootPathsByID.map { ($0.key, $0.value, WorkspaceRootKind.primaryWorkspace) }
                    + selector.physicalRootPathsByID.map { ($0.key, $0.value, WorkspaceRootKind.sessionWorktree) }
            )
            .compactMap { rootID, expectedPath, expectedKind in
                guard let currentRoot = rootStatesByID[rootID]?.root,
                      currentRoot.kind == expectedKind,
                      currentRoot.standardizedFullPath == expectedPath,
                      publishedSeededAuthorityIsQueryable(rootID: rootID)
                else { return expectedPath }
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: currentRoot.standardizedFullPath,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue ? nil : currentRoot.standardizedFullPath
            }.sorted()
        }
        return missing.isEmpty
            ? .available
            : .sessionWorktreeUnavailable(missingPhysicalRootPaths: missing)
    }

    #if DEBUG
        private struct CatalogSortProjection {
            let file: WorkspaceFileRecord
            let standardizedSortPath: String
        }

        /// P4-6b table-deletion conversion: pages every root in scope once (`fetchFileTreePageIndex`)
        /// instead of filtering the deleted global tables by `allowedRootIDs`. This is a
        /// benchmark/attribution probe (`StoreBackedWorkspaceSearchTests`,
        /// `WorkspaceFileSearchIndexTimeToReadyBenchmarkTests`), not part of the shadow apparatus.
        func debugAuthoritativeCatalogSortProbe(
            rootScope: WorkspaceLookupRootScope,
            warmupCount: Int = 1,
            measuredCount: Int = 3
        ) async -> WorkspaceCatalogSortAttributionProbe {
            guard rootScopeAvailability(rootScope) == .available else {
                return WorkspaceCatalogSortAttributionProbe(
                    status: .unavailable,
                    sourceFileCount: 0,
                    sourceFolderCount: 0,
                    samples: [],
                    directAndProjectedOrdersMatch: true,
                    firstMismatchIndex: nil,
                    orderedFileIDs: []
                )
            }

            let roots = rootsForPathLookup(scope: rootScope)
            let usesRootLocalFileOrder = roots.count == 1
            var sourceFiles: [WorkspaceFileRecord] = []
            var sourceFolders: [WorkspaceFolderRecord] = []
            for root in roots {
                guard let pageIndex = await fetchFileTreePageIndex(rootID: root.id) else { continue }
                sourceFiles.append(contentsOf: pageIndex.filesByID.values.filter { isDiscoverableFileID($0.id) })
                sourceFolders.append(contentsOf: pageIndex.foldersByID.values.filter { isDiscoverableFolderID($0.id) })
                // Item 0 fix (P4-7b tail, P4-6b regression): include the synthesized root-marker
                // folder, matching `folders(inRoot:)`/`buildAuthoritativeCatalogComponents`.
                if let marker = rootFolderRecord(rootID: root.id) {
                    sourceFolders.append(marker)
                }
            }
            guard !sourceFiles.isEmpty || !sourceFolders.isEmpty else {
                return WorkspaceCatalogSortAttributionProbe(
                    status: .empty,
                    sourceFileCount: 0,
                    sourceFolderCount: 0,
                    samples: [],
                    directAndProjectedOrdersMatch: true,
                    firstMismatchIndex: nil,
                    orderedFileIDs: []
                )
            }

            func directFilePrecedes(_ lhs: WorkspaceFileRecord, _ rhs: WorkspaceFileRecord) -> Bool {
                usesRootLocalFileOrder
                    ? WorkspaceInventoryOrdering.searchRootCatalogFilePrecedes(lhs, rhs)
                    : WorkspaceInventoryOrdering.searchCatalogFilePrecedes(lhs, rhs)
            }

            func projectionPrecedes(_ lhs: CatalogSortProjection, _ rhs: CatalogSortProjection) -> Bool {
                switch WorkspaceInventoryOrdering.compareUTF8Binary(lhs.standardizedSortPath, rhs.standardizedSortPath) {
                case .orderedAscending:
                    true
                case .orderedDescending:
                    false
                case .orderedSame:
                    WorkspaceInventoryOrdering.compareUTF8Binary(
                        lhs.file.id.uuidString,
                        rhs.file.id.uuidString
                    ) == .orderedAscending
                }
            }

            func timedDirectFileSort() -> (nanoseconds: UInt64, files: [WorkspaceFileRecord]) {
                let start = WorkspaceFileSearchDebugTiming.now()
                let files = sourceFiles.sorted(by: directFilePrecedes)
                let end = WorkspaceFileSearchDebugTiming.now()
                return (
                    WorkspaceFileSearchDebugTiming.elapsed(since: start, through: end),
                    files
                )
            }

            func timedProjectedPipeline() -> (
                keyNanoseconds: UInt64,
                assemblyNanoseconds: UInt64,
                sortNanoseconds: UInt64,
                mappingNanoseconds: UInt64,
                projections: [CatalogSortProjection],
                files: [WorkspaceFileRecord]
            ) {
                let keyStart = WorkspaceFileSearchDebugTiming.now()
                let standardizedSortPaths = sourceFiles.map {
                    usesRootLocalFileOrder
                        ? $0.standardizedRelativePath
                        : $0.standardizedFullPath
                }
                let keyEnd = WorkspaceFileSearchDebugTiming.now()

                let assemblyStart = WorkspaceFileSearchDebugTiming.now()
                let projections = zip(sourceFiles, standardizedSortPaths).map {
                    CatalogSortProjection(file: $0.0, standardizedSortPath: $0.1)
                }
                let assemblyEnd = WorkspaceFileSearchDebugTiming.now()

                let sortStart = WorkspaceFileSearchDebugTiming.now()
                let orderedProjections = projections.sorted(by: projectionPrecedes)
                let sortEnd = WorkspaceFileSearchDebugTiming.now()

                let mappingStart = WorkspaceFileSearchDebugTiming.now()
                let orderedFiles = orderedProjections.map(\.file)
                let mappingEnd = WorkspaceFileSearchDebugTiming.now()

                return (
                    WorkspaceFileSearchDebugTiming.elapsed(since: keyStart, through: keyEnd),
                    WorkspaceFileSearchDebugTiming.elapsed(since: assemblyStart, through: assemblyEnd),
                    WorkspaceFileSearchDebugTiming.elapsed(since: sortStart, through: sortEnd),
                    WorkspaceFileSearchDebugTiming.elapsed(since: mappingStart, through: mappingEnd),
                    projections,
                    orderedFiles
                )
            }

            let excludedWarmupCount = max(0, warmupCount)
            let retainedMeasuredCount = max(0, measuredCount)
            var samples: [WorkspaceCatalogSortAttributionSample] = []
            samples.reserveCapacity(retainedMeasuredCount)
            var allOrdersMatch = true
            var firstMismatchIndex: Int?
            var orderedFileIDs: [UUID] = []

            for repetitionIndex in 0 ..< (excludedWarmupCount + retainedMeasuredCount) {
                let direct: (nanoseconds: UInt64, files: [WorkspaceFileRecord])
                let projected: (
                    keyNanoseconds: UInt64,
                    assemblyNanoseconds: UInt64,
                    sortNanoseconds: UInt64,
                    mappingNanoseconds: UInt64,
                    projections: [CatalogSortProjection],
                    files: [WorkspaceFileRecord]
                )
                if repetitionIndex.isMultiple(of: 2) {
                    direct = timedDirectFileSort()
                    projected = timedProjectedPipeline()
                } else {
                    projected = timedProjectedPipeline()
                    direct = timedDirectFileSort()
                }

                let folderStart = WorkspaceFileSearchDebugTiming.now()
                _ = sourceFolders.sorted(by: WorkspaceInventoryOrdering.searchCatalogFolderPrecedes)
                let folderEnd = WorkspaceFileSearchDebugTiming.now()
                let directIDs = direct.files.map(\.id)
                let projectedIDs = projected.files.map(\.id)
                let sharedIndexRange = 0 ..< min(directIDs.count, projectedIDs.count)
                let mismatchIndex = sharedIndexRange.first { directIDs[$0] != projectedIDs[$0] }
                    ?? (directIDs.count == projectedIDs.count ? nil : sharedIndexRange.upperBound)
                let ordersMatch = mismatchIndex == nil

                var directFileComparatorCalls = 0
                _ = sourceFiles.sorted {
                    directFileComparatorCalls += 1
                    return directFilePrecedes($0, $1)
                }
                var projectedFileComparatorCalls = 0
                _ = projected.projections.sorted {
                    projectedFileComparatorCalls += 1
                    return projectionPrecedes($0, $1)
                }
                var folderComparatorCalls = 0
                _ = sourceFolders.sorted {
                    folderComparatorCalls += 1
                    return WorkspaceInventoryOrdering.searchCatalogFolderPrecedes($0, $1)
                }

                guard repetitionIndex >= excludedWarmupCount else { continue }
                if orderedFileIDs.isEmpty {
                    orderedFileIDs = directIDs
                }
                allOrdersMatch = allOrdersMatch && ordersMatch
                if firstMismatchIndex == nil {
                    firstMismatchIndex = mismatchIndex
                }
                samples.append(WorkspaceCatalogSortAttributionSample(
                    directFileSortNanoseconds: direct.nanoseconds,
                    directFolderSortNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                        since: folderStart,
                        through: folderEnd
                    ),
                    keyDerivationNanoseconds: projected.keyNanoseconds,
                    projectionAssemblyNanoseconds: projected.assemblyNanoseconds,
                    projectedFileSortNanoseconds: projected.sortNanoseconds,
                    projectionMappingNanoseconds: projected.mappingNanoseconds,
                    directFileComparatorCalls: directFileComparatorCalls,
                    projectedFileComparatorCalls: projectedFileComparatorCalls,
                    folderComparatorCalls: folderComparatorCalls,
                    directAndProjectedOrdersMatch: ordersMatch,
                    firstMismatchIndex: mismatchIndex
                ))
            }

            return WorkspaceCatalogSortAttributionProbe(
                status: .completed,
                sourceFileCount: sourceFiles.count,
                sourceFolderCount: sourceFolders.count,
                samples: samples,
                directAndProjectedOrdersMatch: allOrdersMatch,
                firstMismatchIndex: firstMismatchIndex,
                orderedFileIDs: orderedFileIDs
            )
        }
    #endif

    /// P4-7b b3: the default drops to `.recordsOnly` -- `WorkspaceSearchService` (the last caller
    /// that ever requested `.recordsAndPathIndexes`) now consumes `searchRootQueryHandles`
    /// instead. P4-7c c3 deletes `.recordsAndPathIndexes` outright, so a caller that still asks for
    /// it no longer compiles, rather than silently under-delivering or tripping a runtime
    /// precondition.
    func searchCatalogAccess(
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        requirement: WorkspaceSearchCatalogAccessRequirement = .recordsOnly
    ) async -> WorkspaceSearchCatalogAccess {
        let availability = rootScopeAvailability(rootScope)
        guard availability == .available else {
            return .unavailable(availability)
        }
        return await .available(searchCatalogSnapshot(rootScope: rootScope, requirement: requirement))
    }

    /// P4-7b b3: same default change as `searchCatalogAccess`, same reason.
    func searchCatalogSnapshot(
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        requirement: WorkspaceSearchCatalogAccessRequirement = .recordsOnly
    ) async -> WorkspaceSearchCatalogSnapshot {
        #if DEBUG
            searchCatalogSnapshotCallCountForTesting += 1
        #endif
        let catalogSnapshotState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.catalogSnapshot)
        if rootsForPathLookupIgnoringPublishedAuthority(scope: rootScope).contains(where: {
            !publishedSeededAuthorityIsQueryable(rootID: $0.id)
        }) {
            searchCatalogSnapshotsByScope.removeValue(forKey: rootScope)
        }
        let validationToken = searchCatalogSnapshotValidationToken(scope: rootScope)
        if var cached = searchCatalogSnapshotsByScope[rootScope] {
            if cached.validationToken == validationToken {
                if cached.capability.satisfies(requirement) {
                    cached.lastAccessSequence = nextSearchCatalogAccessSequence()
                    searchCatalogSnapshotsByScope[rootScope] = cached
                    EditFlowPerf.end(
                        EditFlowPerf.Stage.Search.catalogSnapshot,
                        catalogSnapshotState,
                        EditFlowPerf.Dimensions(
                            fileCount: cached.snapshot.diagnostics.fileCount,
                            cacheHit: true,
                            rootCount: cached.snapshot.diagnostics.rootCount,
                            folderCount: cached.snapshot.diagnostics.folderCount
                        )
                    )
                    return cached.snapshot
                }
            } else {
                searchCatalogSnapshotsByScope.removeValue(forKey: rootScope)
            }
        }
        #if DEBUG
            let rebuildStart = WorkspaceFileSearchDebugTiming.now()
            let catalogBuildObserver = WorkspaceFileSearchCatalogBuildObserver()
        #endif
        let roots = rootsForPathLookup(scope: rootScope)
        let generation = scopedSnapshotGeneration(scope: rootScope, validationToken: validationToken)
        var shouldCacheSnapshot = false
        let snapshot: WorkspaceSearchCatalogSnapshot
        #if DEBUG
            let preparedShards = await WorkspaceFileSearchDebugContext.$catalogBuildObserver.withValue(
                catalogBuildObserver
            ) {
                await prepareAndPublishRootCatalogShardBatch(for: roots, requirement: requirement)
            }
        #else
            let preparedShards = await prepareAndPublishRootCatalogShardBatch(for: roots, requirement: requirement)
        #endif
        if let shards = preparedShards {
            var composedSnapshot = composeSearchCatalogSnapshot(
                rootScope: rootScope,
                generation: generation,
                roots: roots,
                shards: shards
            )
            shouldCacheSnapshot = true
            #if DEBUG
                if isCatalogShardShadowValidationEnabled {
                    let authoritativeSnapshot = await buildAuthoritativeSearchCatalogSnapshot(
                        rootScope: rootScope,
                        generation: generation,
                        roots: roots
                    )
                    let composedBytes = catalogShadowBytes(composedSnapshot)
                    let authoritativeBytes = catalogShadowBytes(authoritativeSnapshot)
                    let shadowMatches = composedBytes == authoritativeBytes
                    recordRootCatalogShardShadowComparison(
                        matched: shadowMatches,
                        byteCount: authoritativeBytes.count
                    )
                    if !shadowMatches {
                        for shard in shards {
                            recordRootCatalogShardFallback(
                                rootID: shard.key.rootID,
                                lifetimeID: shard.key.lifetimeID,
                                reason: .shadowValidationMismatch
                            )
                        }
                        assertionFailure("Root catalog shard composition diverged from the authoritative full rebuild")
                        composedSnapshot = await buildAuthoritativeSearchCatalogSnapshot(
                            rootScope: rootScope,
                            generation: generation,
                            roots: roots
                        )
                        shouldCacheSnapshot = false
                    }
                }
            #endif
            snapshot = composedSnapshot
        } else {
            #if DEBUG
                snapshot = await WorkspaceFileSearchDebugContext.$catalogBuildObserver.withValue(
                    catalogBuildObserver
                ) {
                    await buildAuthoritativeSearchCatalogSnapshot(
                        rootScope: rootScope,
                        generation: generation,
                        roots: roots
                    )
                }
            #else
                snapshot = await buildAuthoritativeSearchCatalogSnapshot(
                    rootScope: rootScope,
                    generation: generation,
                    roots: roots
                )
            #endif
        }
        EditFlowPerf.end(
            EditFlowPerf.Stage.Search.catalogSnapshot,
            catalogSnapshotState,
            EditFlowPerf.Dimensions(
                fileCount: snapshot.diagnostics.fileCount,
                cacheHit: false,
                rootCount: snapshot.diagnostics.rootCount,
                folderCount: snapshot.diagnostics.folderCount
            )
        )
        if shouldCacheSnapshot {
            cacheSearchCatalogSnapshot(
                snapshot,
                validationToken: validationToken,
                capability: requirement,
                scope: rootScope
            )
        }
        #if DEBUG
            let rebuildEnd = WorkspaceFileSearchDebugTiming.now()
            let phaseNanoseconds = catalogBuildObserver.snapshot()
            let filterMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(phaseNanoseconds.filterNanoseconds)
            let sortMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(phaseNanoseconds.sortNanoseconds)
            let fileSortMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.fileSortNanoseconds
            )
            let folderSortMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.folderSortNanoseconds
            )
            let sortResidualMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.sortResidualNanoseconds
            )
            let sortReconciliationDeltaMicroseconds =
                phaseNanoseconds.sortReconciliationDeltaNanoseconds / 1000
            let materializationMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.materializationNanoseconds
            )
            let pathIndexKeyMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.pathIndexKeyNanoseconds
            )
            let pathIndexConstructionMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                phaseNanoseconds.pathIndexConstructionNanoseconds
            )
            let totalMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(
                WorkspaceFileSearchDebugTiming.elapsed(since: rebuildStart, through: rebuildEnd)
            )
            let classifiedMicroseconds = filterMicroseconds &+ sortMicroseconds &+ materializationMicroseconds
                &+ pathIndexKeyMicroseconds &+ pathIndexConstructionMicroseconds
            let compositionCacheResidualMicroseconds = totalMicroseconds >= classifiedMicroseconds
                ? totalMicroseconds - classifiedMicroseconds
                : 0
            let catalogPhases = WorkspaceFileSearchPhaseSnapshot.Catalog(
                rebuildCount: 1,
                filterMicroseconds: filterMicroseconds,
                sortMicroseconds: sortMicroseconds,
                fileSortMicroseconds: fileSortMicroseconds,
                folderSortMicroseconds: folderSortMicroseconds,
                sortResidualMicroseconds: sortResidualMicroseconds,
                sortReconciliationDeltaMicroseconds: sortReconciliationDeltaMicroseconds,
                sortInvocationCount: phaseNanoseconds.sortInvocationCount,
                sortFileInputCount: phaseNanoseconds.sortFileInputCount,
                sortFolderInputCount: phaseNanoseconds.sortFolderInputCount,
                materializationMicroseconds: materializationMicroseconds,
                pathIndexKeyMicroseconds: pathIndexKeyMicroseconds,
                pathIndexConstructionMicroseconds: pathIndexConstructionMicroseconds,
                compositionCacheResidualMicroseconds: compositionCacheResidualMicroseconds,
                totalMicroseconds: totalMicroseconds,
                fileCount: snapshot.files.count,
                rootCount: roots.count
            )
            recordCatalogRebuild(
                filterMicroseconds: filterMicroseconds,
                sortMicroseconds: sortMicroseconds,
                fileSortMicroseconds: fileSortMicroseconds,
                folderSortMicroseconds: folderSortMicroseconds,
                sortResidualMicroseconds: sortResidualMicroseconds,
                sortReconciliationDeltaMicroseconds: sortReconciliationDeltaMicroseconds,
                sortInvocationCount: phaseNanoseconds.sortInvocationCount,
                sortFileInputCount: phaseNanoseconds.sortFileInputCount,
                sortFolderInputCount: phaseNanoseconds.sortFolderInputCount,
                materializationMicroseconds: materializationMicroseconds,
                pathIndexKeyMicroseconds: pathIndexKeyMicroseconds,
                pathIndexConstructionMicroseconds: pathIndexConstructionMicroseconds,
                compositionCacheResidualMicroseconds: compositionCacheResidualMicroseconds,
                totalMicroseconds: totalMicroseconds,
                fileCount: snapshot.files.count,
                rootCount: roots.count
            )
            WorkspaceFileSearchDebugContext.collector?.recordCatalogRebuild(catalogPhases)
        #endif
        return snapshot
    }

    /// P4-7b §4.3 (phase b2): vends one open Rust snapshot handle per root in `rootScope`,
    /// alongside -- not instead of, at b2 -- `searchCatalogSnapshot`'s Swift-built
    /// `rootPathIndexes`. `inventoryScopeAuthorityInstance()` stays private to the store;
    /// `WorkspaceSearchService` must not grow an authority dependency (§4.3's ownership rule), both
    /// to keep the generation plumbing in one place and to keep the search actor testable without
    /// a live Rust scope. Returns `nil` if the scope is unavailable or any root's handle fails to
    /// open -- an all-or-nothing vend, matching `precondition(rootPathIndexes.count == roots.count)`'s
    /// existing all-or-nothing shape for the Swift arm.
    ///
    /// `scopeGeneration` is read via the same `scopedSnapshotGeneration`/`searchCatalogSnapshotValidationToken`
    /// pair `searchCatalogSnapshot` uses -- the Swift scope generation, not any Rust generation
    /// (§1.5 Check B).
    func searchRootQueryHandles(
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceSearchRootQueryHandles? {
        guard rootScopeAvailability(rootScope) == .available else { return nil }
        let generation = scopedSnapshotGeneration(scope: rootScope)
        let roots = rootsForPathLookup(scope: rootScope)
        guard let authority = try? await inventoryScopeAuthorityInstance() else { return nil }
        var perRoot: [WorkspaceSearchRootQueryHandle] = []
        perRoot.reserveCapacity(roots.count)
        for root in roots {
            guard let state = rootStatesByID[root.id],
                  let snapshot = try? await authority.openSnapshot(rootID: root.id)
            else { continue }
            perRoot.append(WorkspaceSearchRootQueryHandle(
                identity: WorkspaceSearchRootPathIndexIdentity(
                    rootID: root.id,
                    lifetimeID: state.lifetimeID,
                    topologyGeneration: catalogGenerationsByRootID[root.id] ?? 0
                ),
                rootPath: root.standardizedFullPath,
                rootName: root.name,
                snapshot: snapshot
            ))
        }
        guard perRoot.count == roots.count else { return nil }
        return WorkspaceSearchRootQueryHandles(scopeGeneration: generation, perRoot: perRoot)
    }

    /// P4-7a phase a3 (design doc §5.3): the store-vended seam `AgentFileTagSuggestionService`
    /// calls for its `.suggestion` cutover. `inventoryScopeAuthorityInstance()` stays private to
    /// the store, the same ownership rule `searchRootQueryHandles` above applies for
    /// `WorkspaceSearchService` -- the suggestion service must not grow an authority dependency
    /// either. Unlike `searchRootQueryHandles`'s held-per-generation handles (§4.5, justified for
    /// the steady-state interactive search path), this opens and closes one snapshot per call
    /// (`WorkspaceInventoryScopeAuthority.query`'s existing shape) -- `.Suggestion` only serves the
    /// cold-start/stale-window/worktree-bound fallback cases (design §3), not a per-keystroke path,
    /// so the retention-budget machinery §4.5 built for the common case is not warranted here.
    func suggestionQuery(
        rootID: UUID,
        pattern: String,
        limit: UInt64,
        nonEmptyRelativePrefix: String,
        emptyRelativePathValue: String,
        logicalPrefix: (nonEmptyRelativePrefix: String, emptyRelativePathValue: String)?
    ) async throws -> CoreInventoryQueryResult {
        let authority = try await inventoryScopeAuthorityInstance()
        return try await authority.query(
            rootID: rootID,
            pattern: pattern,
            limit: limit,
            haystackVariant: .suggestion,
            nonEmptyRelativePrefix: nonEmptyRelativePrefix,
            emptyRelativePathValue: emptyRelativePathValue,
            logicalPrefix: logicalPrefix
        )
    }

    private func prepareAndPublishRootCatalogShardBatch(
        for roots: [WorkspaceRootRecord],
        requirement: WorkspaceSearchCatalogAccessRequirement
    ) async -> [RootCatalogShard]? {
        // P4-7c c3: the `rootsNeedingPromotion` accumulation deleted. It existed to upgrade a
        // `.recordsOnly` shard to `.recordsAndPathIndexes` on demand; that capability is deleted
        // this slice (D-14 already made it unreachable at P4-7b b3), so nothing can ever populate
        // it.
        var keysByRootID: [UUID: RootCatalogShardKey] = [:]
        keysByRootID.reserveCapacity(roots.count)
        var rootsNeedingAuthoritativeBuild: [(root: WorkspaceRootRecord, key: RootCatalogShardKey)] = []
        rootsNeedingAuthoritativeBuild.reserveCapacity(roots.count)

        for root in roots {
            guard let key = rootCatalogShardKey(for: root) else { return nil }
            keysByRootID[root.id] = key
            guard let published = publishedRootCatalogShardsByRootID[root.id], published.key == key else {
                rootsNeedingAuthoritativeBuild.append((root, key))
                continue
            }
        }

        for candidate in rootsNeedingAuthoritativeBuild {
            let liveGenerationCount = liveRootCatalogShards(rootID: candidate.root.id).count
            if rootCatalogShardDeltaStatesByRootID[candidate.root.id]?.isDirty == true,
               liveGenerationCount >= Self.maxLiveRootCatalogShardGenerationsPerRoot
            {
                return nil
            }
            guard canPublishAnotherRootCatalogShard(rootID: candidate.root.id) else {
                #if DEBUG
                    recordRootCatalogShardFallback(
                        rootID: candidate.root.id,
                        lifetimeID: candidate.key.lifetimeID,
                        reason: .retentionBoundary
                    )
                #endif
                markRootCatalogShardDirty(
                    rootID: candidate.root.id,
                    lifetimeID: candidate.key.lifetimeID,
                    lastAppliedIndexGeneration: appliedIndexGenerationsByRootID[candidate.root.id] ?? 0,
                    capability: rootCatalogShardDeltaStatesByRootID[candidate.root.id]?.capability ?? .recordsOnly
                )
                publishedRootCatalogShardsByRootID.removeValue(forKey: candidate.root.id)
                return nil
            }
        }
        // Build the complete replacement batch privately; the actor publishes it with one assignment below.
        var newlyBuiltShardsByRootID: [UUID: (shard: RootCatalogShard, kind: RootCatalogShardBuildKind)] = [:]
        newlyBuiltShardsByRootID.reserveCapacity(rootsNeedingAuthoritativeBuild.count)
        for candidate in rootsNeedingAuthoritativeBuild {
            let appliedIndexGeneration = appliedIndexGenerationsByRootID[candidate.root.id] ?? 0
            let shard = await buildAuthoritativeRootCatalogShard(
                root: candidate.root,
                key: candidate.key,
                appliedIndexGeneration: appliedIndexGeneration
            )
            newlyBuiltShardsByRootID[candidate.root.id] = (shard, .authoritative)
        }

        var publication = publishedRootCatalogShardsByRootID
        publication.reserveCapacity(max(publication.count, roots.count))
        for root in roots {
            guard let key = keysByRootID[root.id] else { return nil }
            if let newlyBuilt = newlyBuiltShardsByRootID[root.id]?.shard {
                publication[root.id] = newlyBuilt
            } else if let retained = publishedRootCatalogShardsByRootID[root.id], retained.key == key {
                publication[root.id] = retained
            } else {
                return nil
            }
        }

        publishedRootCatalogShardsByRootID = publication
        for built in newlyBuiltShardsByRootID.values {
            switch built.kind {
            case .authoritative:
                rootCatalogShardDeltaStatesByRootID[built.shard.key.rootID] = RootCatalogShardDeltaState(
                    lifetimeID: built.shard.key.lifetimeID,
                    lastAppliedIndexGeneration: built.shard.appliedIndexGeneration,
                    isDirty: false,
                    capability: .recordsOnly
                )
            case .patch:
                break
            }
            registerPublishedRootCatalogShard(built.shard, kind: built.kind)
        }
        return roots.compactMap { publication[$0.id] }
    }

    private func rootCatalogShardKey(for root: WorkspaceRootRecord) -> RootCatalogShardKey? {
        guard let state = rootStatesByID[root.id],
              let loadConfiguration = rootLoadConfigurationsByPath[root.standardizedFullPath]
        else { return nil }
        return RootCatalogShardKey(
            canonicalConfigurationIdentity: RootCatalogCanonicalConfigurationIdentity(
                canonicalPath: root.standardizedFullPath,
                loadConfiguration: loadConfiguration
            ),
            rootID: root.id,
            lifetimeID: state.lifetimeID,
            topologyGeneration: catalogGenerationsByRootID[root.id] ?? 0
        )
    }

    private func buildAuthoritativeRootCatalogShard(
        root: WorkspaceRootRecord,
        key: RootCatalogShardKey,
        appliedIndexGeneration: UInt64
    ) async -> RootCatalogShard {
        let components = await buildAuthoritativeCatalogComponents(roots: [root])
        return RootCatalogShard(
            key: key,
            root: root,
            files: components.files,
            folders: components.folders,
            entries: components.entries,
            appliedIndexGeneration: appliedIndexGeneration
        )
    }

    // P4-7c c1: `installRootSeedSearchShadow`, `rootSeedSearchShadowControl`, and
    // `invalidateRootSeedSearchShadow` were deleted here. Their sole output
    // (`rootSeedSearchShadowsByRootID`) had zero production readers once P4-7b made
    // `.recordsAndPathIndexes` unreachable from any production caller (D-14) -- the only reader,
    // `rootSeedSearchShadowControl`, was only ever called from `buildAuthoritativeRootPathIndexes`,
    // which only runs for that retired capability. See `docs/architecture/rust-inventory-scope-v1.md`
    // §13's P4-7c amendment.

    private func registerPublishedRootCatalogShard(
        _ shard: RootCatalogShard,
        kind: RootCatalogShardBuildKind
    ) {
        rootCatalogShardWeakReferencesByRootID[shard.key.rootID, default: []]
            .append(WeakRootCatalogShardReference(shard))
        #if DEBUG
            rootCatalogShardBuildCountsByRootID[shard.key.rootID, default: 0] += 1
            switch kind {
            case .patch:
                rootCatalogShardPatchCountsByRootID[shard.key.rootID, default: 0] += 1
            case .authoritative:
                rootCatalogShardAuthoritativeRebuildCountsByRootID[shard.key.rootID, default: 0] += 1
            }
            // P4-7c c3: the `switch shard.pathSearchIndex?.buildKind` increment block deleted --
            // `pathSearchIndex` no longer exists on `RootCatalogShard`. It was already always `nil`
            // in production since P4-7b b3, so `rootCatalogShardFullPathIndexBuildCountsByRootID`/
            // `rootCatalogShardOverlayPathIndexBuildCountsByRootID` were already permanently empty
            // (every read site sums to 0) -- deleting the dead increment site changes no observable
            // behavior. The dictionaries themselves are left in place unincremented rather than
            // deleted: ~20 existing test assertions across `WorkspaceCatalogShardTests`,
            // `StoreBackedWorkspaceSearchTests`, and `WorkspaceFileContextStoreTests` read
            // `pathIndexBuildCount`/`overlayPathIndexBuildCount` expecting 0, and still do.
            let liveCount = liveRootCatalogShards(rootID: shard.key.rootID).count
            rootCatalogShardMaxLiveGenerationCountsByRootID[shard.key.rootID] = max(
                rootCatalogShardMaxLiveGenerationCountsByRootID[shard.key.rootID] ?? 0,
                liveCount
            )
        #endif
    }

    private func liveRootCatalogShards(rootID: UUID) -> [RootCatalogShard] {
        let live = (rootCatalogShardWeakReferencesByRootID[rootID] ?? []).compactMap(\.shard)
        if live.isEmpty {
            rootCatalogShardWeakReferencesByRootID.removeValue(forKey: rootID)
        } else {
            rootCatalogShardWeakReferencesByRootID[rootID] = live.map(WeakRootCatalogShardReference.init)
        }
        return live
    }

    private func canPublishAnotherRootCatalogShard(rootID: UUID) -> Bool {
        let liveGenerations = liveRootCatalogShards(rootID: rootID)
        guard liveGenerations.count < Self.maxLiveRootCatalogShardGenerationsPerRoot else {
            #if DEBUG
                rootCatalogShardBackstopCountsByRootID[rootID, default: 0] += 1
                rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] = max(
                    rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] ?? 0,
                    liveGenerations.count
                )
            #endif
            return false
        }
        return true
    }

    private func applyAppliedIndexEventToRootCatalogShard(_ event: WorkspaceAppliedIndexBatchEvent) async {
        if event.isRootUnload {
            publishedRootCatalogShardsByRootID.removeValue(forKey: event.rootID)
            rootCatalogShardDeltaStatesByRootID.removeValue(forKey: event.rootID)
            return
        }

        guard let state = rootStatesByID[event.rootID],
              state.root.standardizedFullPath == StandardizedPath.absolute(event.rootPath),
              let currentKey = rootCatalogShardKey(for: state.root)
        else {
            publishedRootCatalogShardsByRootID.removeValue(forKey: event.rootID)
            rootCatalogShardDeltaStatesByRootID.removeValue(forKey: event.rootID)
            return
        }

        guard let previousShard = publishedRootCatalogShardsByRootID[event.rootID] else {
            guard let deltaState = rootCatalogShardDeltaStatesByRootID[event.rootID],
                  deltaState.lifetimeID == state.lifetimeID
            else {
                // The actor's authoritative records and generations already include this batch.
                // Keep catalog publication fully lazy until a caller requests a catalog capability.
                return
            }
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: deltaState.isDirty ? .retentionBoundary : .missingReusableShard
                )
            #endif
            await rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: deltaState.capability
            )
            return
        }
        // P4-7c c3: `previousShard.pathSearchIndex` no longer exists -- it was always `nil` in
        // production since P4-7b b3, so this was always `.recordsOnly` already.
        let fallbackRequirement: WorkspaceSearchCatalogAccessRequirement = .recordsOnly
        let deltaState = rootCatalogShardDeltaStatesByRootID[event.rootID] ?? RootCatalogShardDeltaState(
            lifetimeID: previousShard.key.lifetimeID,
            lastAppliedIndexGeneration: previousShard.appliedIndexGeneration,
            isDirty: false,
            capability: fallbackRequirement
        )
        guard deltaState.lifetimeID == state.lifetimeID,
              previousShard.key.lifetimeID == state.lifetimeID,
              previousShard.key.rootID == event.rootID,
              previousShard.key.canonicalConfigurationIdentity == currentKey.canonicalConfigurationIdentity
        else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .unsafeOrAmbiguousBatch
                )
            #endif
            await rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        if deltaState.isDirty {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .retentionBoundary
                )
            #endif
            await rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        if event.requiresFullResync {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .fullResync
                )
            #endif
            await rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        if deltaState.lastAppliedIndexGeneration == UInt64.max || event.generation == 0 {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .generationGap
                )
            #endif
            await rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        guard event.generation == deltaState.lastAppliedIndexGeneration + 1 else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .generationGap
                )
            #endif
            await rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }

        let hasTopologyMutation = !event.upsertedFiles.isEmpty
            || !event.upsertedFolders.isEmpty
            || !event.removedFileIDs.isEmpty
            || !event.removedFolderIDs.isEmpty
            || !event.removedFilePaths.isEmpty
            || !event.removedFolderPaths.isEmpty
        let expectedTopologyGeneration: UInt64
        if hasTopologyMutation {
            guard previousShard.key.topologyGeneration != UInt64.max else {
                #if DEBUG
                    recordRootCatalogShardFallback(
                        rootID: event.rootID,
                        lifetimeID: state.lifetimeID,
                        reason: .generationGap
                    )
                #endif
                await rebuildRootCatalogShardAuthoritatively(
                    root: state.root,
                    key: currentKey,
                    appliedIndexGeneration: event.generation,
                    requirement: fallbackRequirement
                )
                return
            }
            expectedTopologyGeneration = previousShard.key.topologyGeneration + 1
        } else {
            expectedTopologyGeneration = previousShard.key.topologyGeneration
        }
        guard currentKey.topologyGeneration == expectedTopologyGeneration else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .unsafeOrAmbiguousBatch
                )
            #endif
            await rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        guard let builderOutput = await buildRootCatalogShardPatch(event: event, previousShard: previousShard) else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .patchApplicationBackstop
                )
            #endif
            await rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        guard builderOutput.logicalMutationCount <= Self.maxRootCatalogShardPatchLogicalMutationCount else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .patchThresholdExceeded
                )
            #endif
            await rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                requirement: fallbackRequirement
            )
            return
        }
        guard canPublishAnotherRootCatalogShard(rootID: event.rootID) else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: event.rootID,
                    lifetimeID: state.lifetimeID,
                    reason: .retentionBoundary
                )
            #endif
            markRootCatalogShardDirty(
                rootID: event.rootID,
                lifetimeID: state.lifetimeID,
                lastAppliedIndexGeneration: event.generation,
                capability: fallbackRequirement
            )
            publishedRootCatalogShardsByRootID.removeValue(forKey: event.rootID)
            return
        }

        let patchedEntries = builderOutput.files.map { WorkspaceSearchCatalogEntry(file: $0, root: state.root) }
        let patchedShard = RootCatalogShard(
            key: currentKey,
            root: state.root,
            files: builderOutput.files,
            folders: builderOutput.folders,
            entries: patchedEntries,
            appliedIndexGeneration: event.generation
        )
        var publication = publishedRootCatalogShardsByRootID
        publication[event.rootID] = patchedShard
        publishedRootCatalogShardsByRootID = publication
        rootCatalogShardDeltaStatesByRootID[event.rootID] = RootCatalogShardDeltaState(
            lifetimeID: state.lifetimeID,
            lastAppliedIndexGeneration: event.generation,
            isDirty: false,
            capability: fallbackRequirement
        )
        registerPublishedRootCatalogShard(patchedShard, kind: .patch)
    }

    /// Every call site passes `requirement:` explicitly (derived from a saved capability or
    /// fallback requirement); this default is unreachable in practice and changed to `.recordsOnly`
    /// only for consistency with `searchCatalogSnapshot`/`searchCatalogAccess`'s P4-7b b3 defaults.
    private func rebuildRootCatalogShardAuthoritatively(
        root: WorkspaceRootRecord,
        key: RootCatalogShardKey,
        appliedIndexGeneration: UInt64,
        requirement: WorkspaceSearchCatalogAccessRequirement = .recordsOnly
    ) async {
        guard canPublishAnotherRootCatalogShard(rootID: root.id) else {
            #if DEBUG
                recordRootCatalogShardFallback(
                    rootID: root.id,
                    lifetimeID: key.lifetimeID,
                    reason: .retentionBoundary
                )
            #endif
            markRootCatalogShardDirty(
                rootID: root.id,
                lifetimeID: key.lifetimeID,
                lastAppliedIndexGeneration: appliedIndexGeneration,
                capability: requirement
            )
            publishedRootCatalogShardsByRootID.removeValue(forKey: root.id)
            return
        }
        let rebuiltShard = await buildAuthoritativeRootCatalogShard(
            root: root,
            key: key,
            appliedIndexGeneration: appliedIndexGeneration
        )
        var publication = publishedRootCatalogShardsByRootID
        publication[root.id] = rebuiltShard
        publishedRootCatalogShardsByRootID = publication
        rootCatalogShardDeltaStatesByRootID[root.id] = RootCatalogShardDeltaState(
            lifetimeID: key.lifetimeID,
            lastAppliedIndexGeneration: appliedIndexGeneration,
            isDirty: false,
            capability: requirement
        )
        registerPublishedRootCatalogShard(rebuiltShard, kind: .authoritative)
    }

    private func markRootCatalogShardDirty(
        rootID: UUID,
        lifetimeID: UUID,
        lastAppliedIndexGeneration: UInt64,
        capability: WorkspaceSearchCatalogAccessRequirement
    ) {
        rootCatalogShardDeltaStatesByRootID[rootID] = RootCatalogShardDeltaState(
            lifetimeID: lifetimeID,
            lastAppliedIndexGeneration: lastAppliedIndexGeneration,
            isDirty: true,
            capability: capability
        )
    }

    #if DEBUG
        private func resetRootCatalogShardFallbackDiagnosticsIfLifetimeChanged(
            rootID: UUID,
            lifetimeID: UUID
        ) {
            guard rootCatalogShardFallbackLifetimeIDsByRootID[rootID] != lifetimeID else { return }
            rootCatalogShardFallbackLifetimeIDsByRootID[rootID] = lifetimeID
            rootCatalogShardFallbackCountsByRootID.removeValue(forKey: rootID)
            rootCatalogShardFallbackReasonCountsByRootID.removeValue(forKey: rootID)
        }

        private func recordRootCatalogShardFallback(
            rootID: UUID,
            lifetimeID: UUID,
            reason: RootCatalogShardFallbackReason
        ) {
            resetRootCatalogShardFallbackDiagnosticsIfLifetimeChanged(
                rootID: rootID,
                lifetimeID: lifetimeID
            )
            rootCatalogShardFallbackCountsByRootID[rootID, default: 0] += 1
            rootCatalogShardFallbackReasonCountsByRootID[rootID, default: [:]][reason, default: 0] += 1
            assert(
                rootCatalogShardFallbackCountsByRootID[rootID]
                    == rootCatalogShardFallbackReasonCountsByRootID[rootID]?.values.reduce(0, +)
            )
        }
    #endif

    /// P4-6b table-deletion conversion: these two wrappers turned out to still be live production
    /// machinery (the general search-catalog shard cache, not just codemap or the shadow
    /// apparatus) -- misclassified as a pure deletion target in the first pass of the conversion
    /// ledger. Corrected here: re-sourced from a per-root paged Rust read instead of the deleted
    /// globals, using the exact same conservative pattern as the B2 codemap-shard conversion and
    /// the discoverable-count aggregates (fix the dead-table read now; a fuller migration of the
    /// shard-cache architecture onto Rust's own projected-shard surface remains a flagged
    /// follow-up, not a correctness gap -- see the conversion ledger).
    private func buildRootCatalogShardPatch(
        event: WorkspaceAppliedIndexBatchEvent,
        previousShard: RootCatalogShard
    ) async -> RootCatalogShardBuilderOutput? {
        guard let pageIndex = await fetchFileTreePageIndex(rootID: event.rootID) else { return nil }
        guard let patch = WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch(
            event: event,
            previousFiles: previousShard.files,
            previousFolders: previousShard.folders,
            filesByID: pageIndex.filesByID,
            foldersByID: pageIndex.foldersByID,
            maxLogicalMutationCount: Self.maxRootCatalogShardPatchLogicalMutationCount
        ) else { return nil }
        return RootCatalogShardBuilderOutput(
            files: patch.files,
            folders: patch.folders,
            logicalMutationCount: patch.logicalMutationCount,
            pathIndexChangedFileIDs: patch.pathIndexChangedFileIDs
        )
    }

    private func buildAuthoritativeCatalogComponents(
        roots: [WorkspaceRootRecord]
    ) async -> AuthoritativeCatalogComponents {
        var filesByID: [UUID: WorkspaceFileRecord] = [:]
        var foldersByID: [UUID: WorkspaceFolderRecord] = [:]
        for root in roots {
            guard let pageIndex = await fetchFileTreePageIndex(rootID: root.id) else { continue }
            filesByID.merge(pageIndex.filesByID) { _, new in new }
            foldersByID.merge(pageIndex.foldersByID) { _, new in new }
            // Item 0 fix (P4-7b tail, P4-6b regression): the root's own self-referencing folder
            // marker is never sent to Rust (root-marker exclusion) and so is absent from
            // `pageIndex.foldersByID`. Pre-P4-6b, `state.foldersByID` always carried it (the diff at
            // `fe14d61e` -- "`state.folderIDsByRelativePath`'s keys ... always included the root
            // marker" -- documents the invariant this restores); synthesize it here, matching
            // `rootFolderRecord(rootID:)` and `buildStaticSnapshot`'s identical synthesis, so shard
            // folder counts/sort input again include it as they did before the table deletion.
            if let marker = rootFolderRecord(rootID: root.id) {
                foldersByID[marker.id] = marker
            }
        }
        let components = WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents(
            roots: roots,
            filesByID: filesByID,
            foldersByID: foldersByID,
            managedOnlyFileIDs: managedOnlyFileIDs,
            managedOnlyFolderIDs: managedOnlyFolderIDs
        )
        return AuthoritativeCatalogComponents(
            files: components.files,
            folders: components.folders,
            entries: components.entries
        )
    }

    /// Builds the publication payload for a hidden root without consulting any
    /// globally visible store map. This is the catalog half of the 8D atomic
    /// root publication invariant.
    private func buildPendingCatalogComponents(
        root: WorkspaceRootRecord,
        indexes: RootIndexBuffers
    ) -> AuthoritativeCatalogComponents {
        let components = WorkspaceInventoryCatalogBuilders.buildPendingCatalogComponents(
            root: root,
            filesByID: indexes.filesByID,
            foldersByID: indexes.foldersByID
        )
        return AuthoritativeCatalogComponents(
            files: components.files,
            folders: components.folders,
            entries: components.entries
        )
    }

    private func buildAuthoritativeSearchCatalogSnapshot(
        rootScope: WorkspaceLookupRootScope,
        generation: UInt64,
        roots: [WorkspaceRootRecord]
    ) async -> WorkspaceSearchCatalogSnapshot {
        let components = await buildAuthoritativeCatalogComponents(roots: roots)
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: generation,
            rootScope: rootScope,
            rootCount: roots.count,
            folderCount: components.folders.count,
            fileCount: components.files.count
        )
        return WorkspaceSearchCatalogSnapshot(
            generation: generation,
            rootScope: rootScope,
            roots: roots,
            files: components.files,
            entries: components.entries,
            diagnostics: diagnostics
        )
    }

    // P4-7c c3: `buildAuthoritativeRootPathIndexes` deleted -- its sole caller
    // (`buildAuthoritativeSearchCatalogSnapshot`, above) always passed `requirement.requiresPathIndexes
    // == false` in production since P4-7b b3; the type it built, `WorkspaceSearchRootPathIndex`, no
    // longer exists (`PathSearchIndex.swift` is deleted this slice).

    private func composeSearchCatalogSnapshot(
        rootScope: WorkspaceLookupRootScope,
        generation: UInt64,
        roots: [WorkspaceRootRecord],
        shards: [RootCatalogShard]
    ) -> WorkspaceSearchCatalogSnapshot {
        let merged: (files: [WorkspaceFileRecord], entries: [WorkspaceSearchCatalogEntry])
        if let shard = shards.first, shards.count == 1 {
            merged = (shard.files, shard.entries)
            #if DEBUG
                rootCatalogShardSingleShardCompositionReuseCount += 1
            #endif
        } else {
            merged = mergeRootCatalogShards(shards)
            #if DEBUG
                rootCatalogShardGenericMergeElementVisitCount += merged.files.count
            #endif
        }
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: generation,
            rootScope: rootScope,
            rootCount: roots.count,
            folderCount: shards.reduce(0) { $0 + $1.folderCount },
            fileCount: merged.files.count
        )
        // P4-7c c3: the `requirement.requiresPathIndexes` branch that unwrapped
        // `shard.pathSearchIndex` (`preconditionFailure`-ing on `nil`, per D-14) is deleted --
        // `pathSearchIndex` no longer exists on `RootCatalogShard`, and `requirement` is always
        // `.recordsOnly` (the enum's only remaining case).
        return WorkspaceSearchCatalogSnapshot(
            generation: generation,
            rootScope: rootScope,
            roots: roots,
            files: merged.files,
            entries: merged.entries,
            diagnostics: diagnostics,
            generationLease: WorkspaceSearchCatalogGenerationLease(
                retaining: shards.map { $0 as AnyObject }
            )
        )
    }

    private func mergeRootCatalogShards(
        _ shards: [RootCatalogShard]
    ) -> (files: [WorkspaceFileRecord], entries: [WorkspaceSearchCatalogEntry]) {
        WorkspaceInventoryCatalogBuilders.mergeRootCatalogShardFileEntryLists(
            shards.map { (files: $0.files, entries: $0.entries) }
        )
    }

    #if DEBUG
        private func recordRootCatalogShardShadowComparison(matched: Bool, byteCount: Int) {
            rootCatalogShardShadowComparisonCount += 1
            rootCatalogShardLastShadowByteCount = byteCount
            if !matched {
                rootCatalogShardShadowMismatchCount += 1
            }
        }

        private func catalogShadowBytes(_ snapshot: WorkspaceSearchCatalogSnapshot) -> Data {
            let null = NSNull()
            let roots: [[String: Any]] = snapshot.roots.map { root in
                [
                    "id": root.id.uuidString,
                    "name": root.name,
                    "full_path": root.fullPath,
                    "standardized_full_path": root.standardizedFullPath,
                    "is_system_root": root.isSystemRoot,
                    "kind": Self.rootKindDiagnosticLabel(root.kind)
                ]
            }
            let files: [[String: Any]] = snapshot.files.map { file in
                [
                    "id": file.id.uuidString,
                    "root_id": file.rootID.uuidString,
                    "name": file.name,
                    "relative_path": file.relativePath,
                    "standardized_relative_path": file.standardizedRelativePath,
                    "full_path": file.fullPath,
                    "standardized_full_path": file.standardizedFullPath,
                    "parent_folder_id": file.parentFolderID.map { $0.uuidString as Any } ?? null,
                    "modification_date_bits": file.modificationDate.map {
                        String($0.timeIntervalSinceReferenceDate.bitPattern) as Any
                    } ?? null
                ]
            }
            let entries: [[String: Any]] = snapshot.entries.map { entry in
                [
                    "id": entry.id.uuidString,
                    "root_id": entry.rootID.uuidString,
                    "root_path": entry.rootPath,
                    "root_name": entry.rootName,
                    "name": entry.name,
                    "relative_path": entry.relativePath,
                    "standardized_relative_path": entry.standardizedRelativePath,
                    "full_path": entry.fullPath,
                    "standardized_full_path": entry.standardizedFullPath,
                    "display_path": entry.displayPath
                ]
            }
            let object: [String: Any] = [
                "generation": String(snapshot.generation),
                "root_scope": Self.scopeDiagnosticLabel(snapshot.rootScope),
                "roots": roots,
                "files": files,
                "entries": entries,
                "diagnostics": [
                    "generation": String(snapshot.diagnostics.generation),
                    "root_scope": Self.scopeDiagnosticLabel(snapshot.diagnostics.rootScope),
                    "root_count": snapshot.diagnostics.rootCount,
                    "folder_count": snapshot.diagnostics.folderCount,
                    "file_count": snapshot.diagnostics.fileCount,
                    "total_item_count": snapshot.diagnostics.totalItemCount
                ]
            ]
            return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    #endif

    func directFolderChildren(
        rootID: UUID,
        relativePath: String = ""
    ) async -> WorkspaceDirectFolderChildrenSnapshot? {
        let key = StandardizedPath.relative(relativePath)
        if key.isEmpty {
            guard let root = rootStatesByID[rootID]?.root else { return nil }
            return await directFolderChildren(folderID: root.id)
        }
        guard let folder = await folder(rootID: rootID, relativePath: key) else { return nil }
        return await directFolderChildren(folderID: folder.id)
    }

    func directFolderChildren(folderID: UUID) async -> WorkspaceDirectFolderChildrenSnapshot? {
        guard isDiscoverableFolderID(folderID) else { return nil }
        let ownedRootAndFolder: (rootID: UUID, folder: WorkspaceFolderRecord)? = if let root = rootStatesByID.values.first(where: { $0.root.id == folderID })?.root {
            // The root-marker folder itself: synthesized locally (root-marker exclusion).
            (root.id, WorkspaceFolderRecord(
                id: root.id, rootID: root.id, name: root.name,
                relativePath: "", fullPath: root.fullPath, parentFolderID: nil
            ))
        } else if let authority = try? await inventoryScopeAuthorityInstance(),
                  let block = try? await authority.resolveRecordsScopeWide(fileIDs: [], folderIDs: [folderID]),
                  let fact = block.foldersByID[folderID],
                  let folder = WorkspaceInventoryScopeRepublicationAdapter.workspaceFolderRecord(id: folderID, fact: fact)
        {
            (folder.rootID, folder)
        } else {
            nil
        }
        guard let (rootID, folder) = ownedRootAndFolder,
              let state = rootStatesByID[rootID],
              let pageIndex = await fetchFileTreePageIndex(rootID: rootID)
        else { return nil }
        let childFolders = (pageIndex.childFolderIDsByFolderID[folderID] ?? [])
            .filter(isDiscoverableFolderID)
            .compactMap { pageIndex.foldersByID[$0] }
            .sorted(by: compareDirectChildFolders)
        let childFiles = (pageIndex.childFileIDsByFolderID[folderID] ?? [])
            .filter(isDiscoverableFileID)
            .compactMap { pageIndex.filesByID[$0] }
            .sorted(by: compareDirectChildFiles)
        return WorkspaceDirectFolderChildrenSnapshot(
            generation: scopedSnapshotGeneration(scope: .allLoaded),
            root: state.root,
            folder: folder,
            childFolders: childFolders,
            childFiles: childFiles
        )
    }

    private func compareDirectChildFolders(_ lhs: WorkspaceFolderRecord, _ rhs: WorkspaceFolderRecord) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
        }
        if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
            return lhs.standardizedRelativePath.utf8.lexicographicallyPrecedes(rhs.standardizedRelativePath.utf8)
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func compareDirectChildFiles(_ lhs: WorkspaceFileRecord, _ rhs: WorkspaceFileRecord) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
        }
        if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
            return lhs.standardizedRelativePath.utf8.lexicographicallyPrecedes(rhs.standardizedRelativePath.utf8)
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    @discardableResult
    func warmPathLookupIndexes(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) async -> UInt64 {
        while true {
            let staticData = await buildStaticSnapshot(scope: rootScope)
            let warmedGeneration = await pathMatchWorker.prepare(staticData: staticData)
            let currentGeneration = scopedSnapshotGeneration(scope: rootScope)
            if warmedGeneration == currentGeneration || Task.isCancelled {
                return warmedGeneration
            }
        }
    }

    /// Awaits callback payloads accepted before the captured cut through canonical store application.
    ///
    /// FSEvents not yet delivered by macOS remain outside this contract. Later accepted callbacks
    /// may join the same actor-visible batch or overflow sentinel, so the captured watcher cut is a
    /// lower bound rather than a strict exclusion boundary. Synthetic publications are ordered with
    /// watcher publications and included in the downstream service-publication cut, but they do not
    /// advance watcher-accepted watermarks.
    func awaitAppliedIngressForAllRoots() async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootLoadOrder)
    }

    /// Awaits freshness only for roots represented by `rootScope`.
    /// Concurrent requests for the same root share a watermark-keyed flight when the
    /// existing flight covers both the callback-accepted and publisher-accepted cuts.
    func awaitAppliedIngress(rootScope: WorkspaceLookupRootScope) async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootsForPathLookup(scope: rootScope).map(\.id))
    }

    func awaitAppliedIngress(rootRefs: [WorkspaceRootRef]) async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootRefs.map(\.id))
    }

    func contentSearchFreshnessPolicy(
        rootScope: WorkspaceLookupRootScope,
        appliedIngressSamples: [WorkspaceIngressBarrierSample]
    ) async -> FileContentFreshnessPolicy {
        await contentSearchFreshnessPolicy(
            rootRefs: rootRefs(scope: rootScope),
            appliedIngressSamples: appliedIngressSamples
        )
    }

    func contentSearchFreshnessPolicy(
        rootRefs: [WorkspaceRootRef],
        appliedIngressSamples: [WorkspaceIngressBarrierSample]
    ) async -> FileContentFreshnessPolicy {
        guard !rootRefs.isEmpty,
              appliedIngressSamples.count == rootRefs.count
        else {
            return .validateDiskMetadata
        }
        let samplesByRootID = Dictionary(uniqueKeysWithValues: appliedIngressSamples.map { ($0.rootID, $0) })
        for root in rootRefs {
            guard let state = rootStatesByID[root.id],
                  let sample = samplesByRootID[root.id],
                  await state.service.canUseCachedSearchContent(
                      afterAppliedWatcherWatermark: sample.appliedWatcherWatermark
                  ),
                  publisherIngressCoordinator.appliedSnapshot(rootID: root.id)
                  .acceptedServicePublicationSequence <= sample.appliedServicePublicationSequence
            else {
                return .validateDiskMetadata
            }
        }
        return .cachedMetadata
    }

    /// Resolves the narrowest safe workspace freshness scope for an explicit request.
    /// Absolute paths await only their containing loaded root. Absolute paths outside all
    /// loaded roots (including always-readable support files) do not pay a workspace barrier.
    /// Relative and alias-shaped paths await the caller's fallback scope because resolution
    /// may depend on more than one candidate root.
    func awaitAppliedIngressForExplicitRequest(
        userPath: String,
        fallbackScope: WorkspaceLookupRootScope
    ) async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngressForExplicitRequest(
            userPath: userPath,
            fallbackRootRefs: rootRefs(scope: fallbackScope)
        )
    }

    func awaitAppliedIngressForExplicitRequest(
        userPath: String,
        fallbackRootRefs: [WorkspaceRootRef]
    ) async -> [WorkspaceIngressBarrierSample] {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.hasPrefix("/") else {
            return await awaitAppliedIngress(rootIDs: fallbackRootRefs.map(\.id))
        }
        let containingRootID = fallbackRootRefs
            .filter { StandardizedPath.isDescendant(standardized, of: $0.standardizedFullPath) }
            .max { $0.standardizedFullPath.count < $1.standardizedFullPath.count }?
            .id
        guard let containingRootID else { return [] }
        return await awaitAppliedIngress(rootIDs: [containingRootID])
    }

    func awaitAppliedIngressForExplicitRequest(
        userPath: String,
        fallbackScope: WorkspaceLookupRootScope,
        timeout: Duration
    ) async throws -> [WorkspaceIngressBarrierSample] {
        try await awaitAppliedIngressForExplicitRequest(
            userPath: userPath,
            fallbackRootRefs: rootRefs(scope: fallbackScope),
            timeout: timeout
        )
    }

    func awaitAppliedIngressForExplicitRequest(
        userPath: String,
        fallbackRootRefs: [WorkspaceRootRef],
        timeout: Duration
    ) async throws -> [WorkspaceIngressBarrierSample] {
        try await awaitAppliedIngressWithTimeout(timeout) { [self] in
            await awaitAppliedIngressForExplicitRequest(
                userPath: userPath,
                fallbackRootRefs: fallbackRootRefs
            )
        }
    }

    /// Awaits one shared freshness barrier for every path participating in a single mutation.
    /// Root IDs are deduplicated before waiting, so a move never spends the preflight timeout
    /// once for its source and again for its destination.
    func awaitAppliedIngressForExplicitRequests(
        userPaths: [String],
        fallbackScope: WorkspaceLookupRootScope,
        timeout: Duration
    ) async throws -> [WorkspaceIngressBarrierSample] {
        let fallbackRootRefs = rootRefs(scope: fallbackScope)
        let rootIDs = userPaths.flatMap { userPath in
            explicitRequestIngressRootIDs(
                userPath: userPath,
                fallbackRootRefs: fallbackRootRefs
            )
        }
        return try await awaitAppliedIngressWithTimeout(timeout) { [self] in
            await awaitAppliedIngress(rootIDs: rootIDs)
        }
    }

    private func explicitRequestIngressRootIDs(
        userPath: String,
        fallbackRootRefs: [WorkspaceRootRef]
    ) -> [UUID] {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.hasPrefix("/") else {
            return fallbackRootRefs.map(\.id)
        }
        let containingRootID = fallbackRootRefs
            .filter { StandardizedPath.isDescendant(standardized, of: $0.standardizedFullPath) }
            .max { $0.standardizedFullPath.count < $1.standardizedFullPath.count }?
            .id
        return containingRootID.map { [$0] } ?? []
    }

    private func awaitAppliedIngressWithTimeout(
        _ timeout: Duration,
        operation: @escaping @Sendable () async -> [WorkspaceIngressBarrierSample]
    ) async throws -> [WorkspaceIngressBarrierSample] {
        let race = AppliedIngressTimeoutRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation: continuation)
                let operationTask = Task {
                    let samples = await operation()
                    race.resolve(.success(samples))
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    race.resolve(.failure(WorkspaceAppliedIngressWaitError.timedOut))
                }
                race.install(operationTask: operationTask, timeoutTask: timeoutTask)
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    }

    private func awaitAppliedIngress(rootIDs: [UUID]) async -> [WorkspaceIngressBarrierSample] {
        let orderedRootIDs = rootIDs.reduce(into: [UUID]()) { result, rootID in
            guard rootStatesByID[rootID] != nil, !result.contains(rootID) else { return }
            result.append(rootID)
        }
        guard !orderedRootIDs.isEmpty else { return [] }

        let targetsByRootID = Dictionary(uniqueKeysWithValues: orderedRootIDs.compactMap { rootID in
            rootStatesByID[rootID].map { state in
                (
                    rootID,
                    ScopedIngressBarrierTarget(
                        watcherAcceptedWatermark: state.service.captureAcceptedWatcherWatermark(),
                        acceptedServicePublicationSequence: publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
                            .acceptedServicePublicationSequence
                    )
                )
            }
        })

        #if DEBUG
            if let appliedIngressDidCaptureWatermarksHandler {
                await appliedIngressDidCaptureWatermarksHandler(targetsByRootID.mapValues { $0.watcherAcceptedWatermark.rawValue })
            }
        #endif

        var samplesByIndex: [Int: WorkspaceIngressBarrierSample] = [:]
        for chunkStart in stride(from: 0, to: orderedRootIDs.count, by: Self.maxConcurrentScopedIngressBarriers) {
            guard !Task.isCancelled else { break }
            let chunkEnd = min(chunkStart + Self.maxConcurrentScopedIngressBarriers, orderedRootIDs.count)
            await withTaskGroup(of: (Int, WorkspaceIngressBarrierSample?).self) { group in
                for index in chunkStart ..< chunkEnd {
                    let rootID = orderedRootIDs[index]
                    guard let target = targetsByRootID[rootID] else { continue }
                    group.addTask { [weak self] in
                        guard !Task.isCancelled, let self else { return (index, nil) }
                        guard await (try? requirePublishedSeededAuthorityFresh(rootID: rootID)) != nil else {
                            return (index, nil)
                        }
                        let sample = await awaitAppliedIngress(rootID: rootID, target: target)
                        guard await (try? requirePublishedSeededAuthorityFresh(rootID: rootID)) != nil else {
                            return (index, nil)
                        }
                        return (index, sample)
                    }
                }
                for await (index, sample) in group {
                    if let sample { samplesByIndex[index] = sample }
                }
            }
        }
        return samplesByIndex.keys.sorted().compactMap { samplesByIndex[$0] }
    }

    private func awaitAppliedIngress(
        rootID: UUID,
        target: ScopedIngressBarrierTarget
    ) async -> WorkspaceIngressBarrierSample? {
        guard !Task.isCancelled, let state = rootStatesByID[rootID] else { return nil }
        if completedScopedIngressBarrierCutsByRootID[rootID] != nil {
            let applied = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
            if applied.appliedWatcherWatermark >= target.watcherAcceptedWatermark,
               applied.appliedServicePublicationSequence >= target.acceptedServicePublicationSequence
            {
                #if DEBUG
                    scopedIngressBarrierNoopCountsByRootID[rootID, default: 0] += 1
                #endif
                return WorkspaceIngressBarrierSample(
                    rootID: rootID,
                    rootPath: state.root.standardizedFullPath,
                    pendingRawEventCountBeforeFlush: 0,
                    acceptedWatcherWatermark: target.watcherAcceptedWatermark.rawValue,
                    publishedServicePublicationSequence: target.acceptedServicePublicationSequence,
                    appliedServicePublicationSequence: applied.appliedServicePublicationSequence,
                    appliedWatcherWatermark: applied.appliedWatcherWatermark.rawValue
                )
            }
        }
        let flightState = scopedIngressBarrierFlightStatesByRootID[rootID]
            ?? ScopedIngressBarrierRootFlightState()

        if let active = flightState.active, active.target.covers(target) {
            #if DEBUG
                scopedIngressBarrierJoinCountsByRootID[rootID, default: 0] += 1
            #endif
            guard let output = await active.join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        if let pending = flightState.pending, pending.target.covers(target) {
            #if DEBUG
                scopedIngressBarrierJoinCountsByRootID[rootID, default: 0] += 1
                scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID, default: 0] += 1
            #endif
            guard let output = await pending.join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        if let pending = flightState.pending {
            pending.target = pending.target.merging(target)
            #if DEBUG
                scopedIngressBarrierJoinCountsByRootID[rootID, default: 0] += 1
                scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID, default: 0] += 1
            #endif
            guard let output = await pending.join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        if flightState.active != nil {
            let join = ScopedIngressBarrierJoin()
            #if DEBUG
                let enqueuedAtNanoseconds = debugNowNanoseconds()
                scopedIngressBarrierSuccessorCountsByRootID[rootID, default: 0] += 1
            #else
                let enqueuedAtNanoseconds: UInt64 = 0
            #endif
            flightState.pending = ScopedIngressBarrierPendingFlight(
                target: target,
                join: join,
                enqueuedAtNanoseconds: enqueuedAtNanoseconds
            )
            scopedIngressBarrierFlightStatesByRootID[rootID] = flightState
            guard let output = await join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        let join = ScopedIngressBarrierJoin()
        launchScopedIngressBarrier(
            rootID: rootID,
            target: target,
            join: join,
            flightState: flightState
        )
        guard let output = await join.value() else { return nil }
        return scopedIngressBarrierSample(from: output)
    }

    private func launchScopedIngressBarrier(
        rootID: UUID,
        target: ScopedIngressBarrierTarget,
        join: ScopedIngressBarrierJoin,
        flightState: ScopedIngressBarrierRootFlightState
    ) {
        guard let state = rootStatesByID[rootID] else {
            join.complete(with: nil)
            return
        }
        nextScopedIngressBarrierToken &+= 1
        let token = nextScopedIngressBarrierToken
        let publisherIngressCoordinator = publisherIngressCoordinator
        let root = state.root
        let service = state.service
        #if DEBUG
            scopedIngressBarrierLaunchCountsByRootID[rootID, default: 0] += 1
            let barrierCompletionNowNanoseconds = debugNowNanoseconds
            let barrierStartedAtNanoseconds = barrierCompletionNowNanoseconds()
            let scopedIngressBarrierWillFlushHandler = scopedIngressBarrierWillFlushHandler
            let publisherIngressWillWaitHandler = publisherIngressWillWaitHandler
        #else
            let barrierStartedAtNanoseconds: UInt64 = 0
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        #else
            let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil
        #endif
        let flight = ScopedIngressBarrierFlight(
            token: token,
            target: target,
            join: join,
            startedAtNanoseconds: barrierStartedAtNanoseconds
        )
        flightState.active = flight
        scopedIngressBarrierFlightStatesByRootID[rootID] = flightState
        flight.task = Task { [weak self] in
            #if DEBUG
                if let scopedIngressBarrierWillFlushHandler {
                    await scopedIngressBarrierWillFlushHandler(rootID)
                }
            #endif
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            #if DEBUG
                let pendingCount = await service.pendingRawEventCountForDiagnostics()
            #else
                let pendingCount = 0
            #endif
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.rootFlushBegan,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    pendingRawEventCount: pendingCount,
                    rootToken: service.diagnosticRootToken.uuidString,
                    ingressSequence: target.watcherAcceptedWatermark.rawValue
                )
            )
            #if DEBUG
                if target.acceptedServicePublicationSequence > publisherIngressCoordinator.appliedSnapshot(rootID: rootID).appliedServicePublicationSequence,
                   let publisherIngressWillWaitHandler
                {
                    await publisherIngressWillWaitHandler([rootID])
                }
            #endif
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: target.acceptedServicePublicationSequence
            )
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            let publishedSequence = await service.flushPendingEventsNow(
                throughAcceptedWatcherWatermark: target.watcherAcceptedWatermark
            )
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            let acceptedDownstreamCut = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
                .acceptedServicePublicationSequence
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: max(target.acceptedServicePublicationSequence, acceptedDownstreamCut)
            )
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            let applied = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.rootFlushEnded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    pendingRawEventCount: pendingCount,
                    rootToken: service.diagnosticRootToken.uuidString,
                    ingressSequence: applied.appliedWatcherWatermark.rawValue,
                    barrierSequence: applied.appliedServicePublicationSequence
                )
            )
            let sample = WorkspaceIngressBarrierSample(
                rootID: rootID,
                rootPath: root.standardizedFullPath,
                pendingRawEventCountBeforeFlush: pendingCount,
                acceptedWatcherWatermark: target.watcherAcceptedWatermark.rawValue,
                publishedServicePublicationSequence: publishedSequence,
                appliedServicePublicationSequence: applied.appliedServicePublicationSequence,
                appliedWatcherWatermark: applied.appliedWatcherWatermark.rawValue
            )
            #if DEBUG
                let output = ScopedIngressBarrierTaskOutput(
                    sample: sample,
                    completedAtNanoseconds: barrierCompletionNowNanoseconds()
                )
            #else
                let output = sample
            #endif
            if let self {
                await finishScopedIngressBarrier(
                    rootID: rootID,
                    token: token,
                    target: target,
                    output: output,
                    startedAtNanoseconds: barrierStartedAtNanoseconds,
                    join: join
                )
            } else {
                join.complete(with: output)
            }
        }
    }

    private func finishScopedIngressBarrier(
        rootID: UUID,
        token: UInt64,
        target: ScopedIngressBarrierTarget,
        output: ScopedIngressBarrierTaskOutput?,
        startedAtNanoseconds: UInt64,
        join: ScopedIngressBarrierJoin
    ) {
        guard let flightState = scopedIngressBarrierFlightStatesByRootID[rootID],
              flightState.active?.token == token
        else {
            join.complete(with: output)
            return
        }
        flightState.active = nil
        if let output {
            completedScopedIngressBarrierCutsByRootID[rootID] = ScopedIngressBarrierCompletedCut(
                target: target,
                sample: scopedIngressBarrierSample(from: output)
            )
        }
        #if DEBUG
            if let output {
                recordScopedIngressBarrierCompletion(
                    rootID: rootID,
                    token: token,
                    target: target,
                    sample: output.sample,
                    startedAtNanoseconds: startedAtNanoseconds,
                    completedAtNanoseconds: output.completedAtNanoseconds
                )
            }
        #endif

        if let output, let pending = flightState.pending {
            flightState.pending = nil
            launchScopedIngressBarrier(
                rootID: rootID,
                target: pending.target,
                join: pending.join,
                flightState: flightState
            )
            join.complete(with: output)
            return
        }

        let pending = flightState.pending
        flightState.pending = nil
        scopedIngressBarrierFlightStatesByRootID.removeValue(forKey: rootID)
        if output == nil {
            pending?.join.complete(with: nil)
        }
        join.complete(with: output)
    }

    private func scopedIngressBarrierSample(
        from output: ScopedIngressBarrierTaskOutput
    ) -> WorkspaceIngressBarrierSample {
        #if DEBUG
            output.sample
        #else
            output
        #endif
    }

    /// Compatibility wrapper for callers that still consume the original diagnostic shape.
    func flushPendingServiceEventsForAllRoots() async -> [(rootPath: String, pendingRawEventCountBeforeFlush: Int)] {
        await awaitAppliedIngressForAllRoots().map { sample in
            (sample.rootPath, sample.pendingRawEventCountBeforeFlush)
        }
    }

    // MARK: - Deferred replay buffer ownership

    func updateDeferredReplayRoutingState(
        isWindowFocused: Bool,
        isReplayActive: Bool,
        routingVersion: UInt64
    ) async {
        await deferredReplayBuffer.updateRoutingState(
            isWindowFocused: isWindowFocused,
            isReplayActive: isReplayActive,
            routingVersion: routingVersion
        )
    }

    func updateDeferredReplayImmediateChunkSizeOverride(_ chunkSize: Int?) async {
        await deferredReplayBuffer.updateImmediateReplayChunkSizeOverride(chunkSize)
    }

    func registerDeferredReplayRootGeneration(_ generation: UInt64, forRootKey rootKey: String) async {
        await deferredReplayBuffer.registerActiveRootGeneration(generation, forRootKey: rootKey)
    }

    func unregisterDeferredReplayRootGeneration(forRootKey rootKey: String) async {
        await deferredReplayBuffer.unregisterActiveRootGeneration(forRootKey: rootKey)
    }

    func ingestDeferredReplayLiveDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String,
        rootGeneration: UInt64
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.ingestLiveDeltas(deltas, forRootKey: rootKey, rootGeneration: rootGeneration)
    }

    func ingestDeferredReplayLiveDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.ingestLiveDeltas(deltas, forRootKey: rootKey)
    }

    func finishDeferredReplayPreparedImmediateIngress(_ immediateReplay: PreparedImmediateReplay) async {
        await deferredReplayBuffer.finishPreparedImmediateIngress(immediateReplay)
    }

    func enqueueDeferredReplayDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.enqueueDeferredDeltas(deltas, forRootKey: rootKey)
    }

    func drainDeferredReplayPreparedBatches(
        preferredRootOrder: [String],
        chunkSize: Int
    ) async -> [PreparedFileSystemReplayBatch] {
        await deferredReplayBuffer.drainPreparedBatches(
            preferredRootOrder: preferredRootOrder,
            chunkSize: chunkSize
        )
    }

    func clearDeferredReplayRoot(_ rootKey: String) async {
        await deferredReplayBuffer.clearRoot(rootKey)
    }

    func clearDeferredReplayBuffer() async {
        await deferredReplayBuffer.clearAll()
    }

    func hasDeferredReplayPendingWork() async -> Bool {
        await deferredReplayBuffer.hasPendingWork()
    }

    func pendingDeferredReplayDeltaCount(forRootKey rootKey: String) async -> Int {
        await deferredReplayBuffer.pendingDeltaCount(forRootKey: rootKey)
    }

    func deferredReplayPendingWorkSnapshot() async -> DeferredReplayPendingWorkSnapshot {
        await deferredReplayBuffer.pendingWorkSnapshot()
    }

    #if DEBUG
        func deferredReplayDiagnosticsSnapshot() async -> DeferredReplayBufferDiagnostics {
            await deferredReplayBuffer.diagnosticsSnapshot()
        }

        func gitignorePolicyIdentityForTesting(rootID: UUID) -> WorkspaceGitignorePolicyIdentity? {
            guard let root = rootStatesByID[rootID]?.root else { return nil }
            return rootLoadConfigurationsByPath[root.standardizedFullPath]?.gitignorePolicyIdentity
        }
    #endif

    func refreshFileSystemSettings(
        rootID: UUID,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        skipSymlinks: Bool,
        enableHierarchicalIgnores: Bool
    ) async throws -> Bool {
        let state = try state(for: rootID)
        try await state.service.updateRespectRepoIgnore(respectRepoIgnore)
        try await state.service.updateRespectCursorignore(respectCursorignore)
        await state.service.updateSkipSymlinks(skipSymlinks)
        await state.service.updateEnableHierarchicalIgnores(enableHierarchicalIgnores)
        try await state.service.refreshIgnoreRules()
        return await state.service.takePendingIgnoreRulesChange() != nil
    }

    /// P4-6b table-deletion conversion: `state.folderIDsByRelativePath`'s keys (which always
    /// included the root marker "" -> root.id, always discoverable) are replaced by one paged
    /// read plus the same explicit "" insertion, preserving the pre-conversion invariant that
    /// the root path itself is always included in the reconciliation scan.
    @discardableResult
    func reconcileLoadedRootCatalogWithDisk(rootID: UUID) async -> [FileSystemDelta] {
        guard let state = rootStatesByID[rootID] else { return [] }
        let root = state.root
        guard let pageIndex = await fetchFileTreePageIndex(rootID: rootID) else { return [] }
        var folderPaths = Set(
            pageIndex.foldersByID.values
                .filter { isDiscoverableFolderID($0.id) }
                .map(\.standardizedRelativePath)
        )
        folderPaths.insert("")
        guard !folderPaths.isEmpty else { return [] }

        let deltas: [FileSystemDelta]
        do {
            deltas = try await state.service.scanFoldersInParallel(folderPaths.sorted()).deltas
        } catch {
            return []
        }
        guard !deltas.isEmpty,
              let currentRoot = rootStatesByID[rootID]?.root,
              currentRoot.standardizedFullPath == root.standardizedFullPath
        else { return deltas }

        await handleObservedFileSystemDeltas(deltas, root: root)
        return deltas
    }

    func ensureIndexedFiles(paths: [String]) async -> [String] {
        struct EligibleFile {
            let fullPath: String
            let rootID: UUID
            let rootPath: String
            let relativePath: String
        }

        var eligibleFiles: [EligibleFile] = []
        for rawPath in paths {
            let fullPath = StandardizedPath.absolute(rawPath)
            guard let root = loadedRoot(containing: fullPath),
                  let service = rootStatesByID[root.id]?.service
            else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let relativePath = relativePath(for: fullPath, rootPath: root.standardizedFullPath)
            guard !relativePath.isEmpty,
                  await file(rootID: root.id, relativePath: relativePath) == nil,
                  await service.catalogEligibleRegularFileExists(relativePath: relativePath)
            else { continue }
            #if DEBUG
                if let ensureIndexedFilesEligibilityDidResolveHandler {
                    await ensureIndexedFilesEligibilityDidResolveHandler(root.id, fullPath)
                }
            #endif
            eligibleFiles.append(EligibleFile(
                fullPath: fullPath,
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                relativePath: relativePath
            ))
        }

        var codemapFencesByRootID: [UUID: CodemapRootMutationFenceToken] = [:]
        for rootID in Set(eligibleFiles.map(\.rootID)) {
            if let fence = await beginCodemapRootMutationFence(
                rootID: rootID,
                command: .catalogAdvanced
            ) {
                codemapFencesByRootID[rootID] = fence
            }
        }
        var indexed: [String] = []
        var upsertedFilesByRoot: [UUID: [WorkspaceFileRecord]] = [:]
        defer {
            for (rootID, fence) in codemapFencesByRootID {
                finishCodemapRootMutationFence(
                    fence,
                    didCommitMutation: upsertedFilesByRoot[rootID]?.isEmpty == false
                )
            }
        }
        for eligible in eligibleFiles {
            guard codemapFencesByRootID[eligible.rootID] != nil,
                  let state = rootStatesByID[eligible.rootID],
                  state.root.id == eligible.rootID,
                  state.root.standardizedFullPath == eligible.rootPath,
                  rootIDsByStandardizedPath[eligible.rootPath] == eligible.rootID,
                  loadedRoot(containing: eligible.fullPath)?.id == eligible.rootID,
                  await file(rootID: eligible.rootID, relativePath: eligible.relativePath) == nil,
                  await folder(rootID: eligible.rootID, relativePath: eligible.relativePath) == nil
            else { continue }
            await indexFile(relativePath: eligible.relativePath, root: state.root)
            guard let newFile = await file(rootID: eligible.rootID, relativePath: eligible.relativePath) else { continue }
            indexed.append(eligible.fullPath)
            upsertedFilesByRoot[eligible.rootID, default: []].append(newFile)
        }
        if !indexed.isEmpty {
            let affectedKinds = Set(upsertedFilesByRoot.keys.compactMap { rootStatesByID[$0]?.root.kind })
            invalidatePathMatchSnapshot(
                affectedRootKinds: affectedKinds,
                reason: .explicitMaterialization,
                affectedRootIDs: Set(upsertedFilesByRoot.keys)
            )
            // P4-6b: no manual publish here -- `indexFile` above already applied each mutation to
            // the Rust authority, and the event-drain loop republishes from Rust's own event
            // stream (design doc §4.3).
        }
        return indexed
    }

    private func loadedRoot(containing fullPath: String) -> WorkspaceRootRecord? {
        rootStatesByID.values
            .map(\.root)
            .filter { fullPath == $0.standardizedFullPath || fullPath.hasPrefix($0.standardizedFullPath + "/") }
            .max { $0.standardizedFullPath.count < $1.standardizedFullPath.count }
    }

    private func relativePath(for fullPath: String, rootPath: String) -> String {
        guard fullPath != rootPath else { return "" }
        let start = fullPath.index(fullPath.startIndex, offsetBy: rootPath.count)
        let suffix = fullPath[start...]
        return StandardizedPath.relative(String(suffix).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func makeFileTreePresentation(
        selection: StoredSelection,
        request: WorkspaceFileTreePresentationRequest,
        lookupContext: WorkspaceLookupContext,
        codemapPresentation: WorkspaceCodemapOperationPresentation,
        profile: PathLocateProfile = .uiAssisted
    ) async -> WorkspaceFileTreePresentation {
        await makeFileTreePresentation(
            selection: selection,
            request: request,
            lookupContext: lookupContext,
            renderableCodemapFileIDs: Set(codemapPresentation.renderedEntriesByFileID.keys),
            codemapCoverage: codemapPresentation.coverage,
            codemapIssues: codemapPresentation.issues,
            profile: profile
        )
    }

    /// Renders file-tree codemap markers from the actor's current ready snapshot only.
    /// This path intentionally performs no artifact demand, readiness wait, or presentation freeze.
    func makeCurrentSnapshotFileTreePresentation(
        selection: StoredSelection,
        request: WorkspaceFileTreePresentationRequest,
        lookupContext: WorkspaceLookupContext,
        profile: PathLocateProfile = .uiAssisted
    ) async -> WorkspaceFileTreePresentation {
        #if DEBUG
            let benchmarkMetricTag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
            let benchmarkStarted = DispatchTime.now().uptimeNanoseconds
            defer {
                let benchmarkFinished = DispatchTime.now().uptimeNanoseconds
                WorktreeStartupInstrumentation.recordBenchmarkPassiveTree(
                    tag: benchmarkMetricTag,
                    durationMicroseconds: (benchmarkFinished - benchmarkStarted) / 1000
                )
            }
        #endif
        let unmarkedSnapshot = await makeFileTreeSelectionSnapshot(
            selection: selection,
            request: request,
            renderableCodemapFileIDs: [],
            profile: profile
        )
        let rootDisplayNames = await lookupContext.logicalRootDisplayNamesByRootID(store: self)
        let renderableCodemapFileIDs = request.showCodeMapMarkers
            ? currentRenderableCodemapFileIDs(rootScope: request.rootScope)
            : Set<UUID>()
        let snapshot = fileTreeSnapshot(
            unmarkedSnapshot,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            showCodeMapMarkers: request.showCodeMapMarkers
        )
        let logicalSnapshot = snapshot.logicalized(
            roots: rootRefs(scope: request.rootScope),
            rootDisplayNamesByRootID: rootDisplayNames
        )
        return WorkspaceFileTreePresentation(
            content: WorkspaceFileTreePresentationRenderer.render(logicalSnapshot),
            rootCount: logicalSnapshot.roots.count,
            usesLegend: logicalSnapshot.includeLegend,
            codemapCoverage: .complete,
            codemapIssues: []
        )
    }

    private func makeFileTreePresentation(
        selection: StoredSelection,
        request: WorkspaceFileTreePresentationRequest,
        lookupContext: WorkspaceLookupContext,
        renderableCodemapFileIDs: Set<UUID>,
        codemapCoverage: WorkspaceCodemapOperationPresentationCoverage,
        codemapIssues: [WorkspaceCodemapOperationIssue],
        profile: PathLocateProfile
    ) async -> WorkspaceFileTreePresentation {
        let snapshot = await makeFileTreeSelectionSnapshot(
            selection: selection,
            request: request,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            profile: profile
        )
        let roots = rootRefs(scope: request.rootScope)
        let rootDisplayNames = await lookupContext.logicalRootDisplayNamesByRootID(store: self)
        let logicalSnapshot = snapshot.logicalized(
            roots: roots,
            rootDisplayNamesByRootID: rootDisplayNames
        )
        return WorkspaceFileTreePresentation(
            content: WorkspaceFileTreePresentationRenderer.render(logicalSnapshot),
            rootCount: logicalSnapshot.roots.count,
            usesLegend: logicalSnapshot.includeLegend,
            codemapCoverage: codemapCoverage,
            codemapIssues: codemapIssues
        )
    }

    private func currentRenderableCodemapFileIDs(
        rootScope: WorkspaceLookupRootScope
    ) -> Set<UUID> {
        var fileIDs = Set<UUID>()
        for root in rootRefs(scope: rootScope) {
            guard let state = rootStatesByID[root.id] else { continue }
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: root.id,
                rootLifetimeID: state.lifetimeID
            )
            guard let session = codemapSessionsByRootEpoch[rootEpoch],
                  codemapAuthorityIsCurrent(session.authority)
            else { continue }
            fileIDs.formUnion(session.markerReadinessByFileID.keys)
        }
        return fileIDs
    }

    private func fileTreeSnapshot(
        _ snapshot: FileTreeSelectionSnapshot,
        renderableCodemapFileIDs: Set<UUID>,
        showCodeMapMarkers: Bool
    ) -> FileTreeSelectionSnapshot {
        FileTreeSelectionSnapshot(
            roots: snapshot.roots.map {
                fileTreeFolderSnapshot(
                    $0,
                    renderableCodemapFileIDs: renderableCodemapFileIDs
                )
            },
            selectedFileIDs: snapshot.selectedFileIDs,
            mode: snapshot.mode,
            showFullPaths: snapshot.showFullPaths,
            onlyIncludeRootsWithSelectedFiles: snapshot.onlyIncludeRootsWithSelectedFiles,
            includeLegend: snapshot.includeLegend,
            showCodeMapMarkers: showCodeMapMarkers,
            maxDepth: snapshot.maxDepth
        )
    }

    private func fileTreeFolderSnapshot(
        _ folder: FileTreeFolderSnapshot,
        renderableCodemapFileIDs: Set<UUID>
    ) -> FileTreeFolderSnapshot {
        FileTreeFolderSnapshot(
            id: folder.id,
            name: folder.name,
            fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath,
            standardizedRootPath: folder.standardizedRootPath,
            children: folder.children.map { child in
                switch child {
                case let .folder(childFolder):
                    .folder(fileTreeFolderSnapshot(
                        childFolder,
                        renderableCodemapFileIDs: renderableCodemapFileIDs
                    ))
                case let .file(file):
                    .file(FileTreeFileSnapshot(
                        id: file.id,
                        name: file.name,
                        fileExtension: file.fileExtension,
                        hasCodeMap: renderableCodemapFileIDs.contains(file.id)
                    ))
                }
            }
        )
    }

    func makeFileTreeSelectionSnapshot(
        selection: StoredSelection,
        request: WorkspaceFileTreeSnapshotRequest,
        profile: PathLocateProfile = .uiAssisted
    ) async -> FileTreeSelectionSnapshot {
        let renderableCodemapFileIDs = Set<UUID>()
        return await makeFileTreeSelectionSnapshot(
            selection: selection,
            request: request,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            profile: profile
        )
    }

    func makeFileTreeSelectionSnapshot(
        selection: StoredSelection,
        request: WorkspaceFileTreeSnapshotRequest,
        renderableCodemapFileIDs: Set<UUID>,
        profile: PathLocateProfile = .uiAssisted
    ) async -> FileTreeSelectionSnapshot {
        var selectedStoreFileIDs = Set<UUID>()
        for path in selection.selectedPaths {
            guard let result = await lookupSelectionPath(path, profile: profile, rootScope: request.rootScope) else { continue }
            if let file = result.file {
                selectedStoreFileIDs.insert(file.id)
            }
            if let folder = result.folder,
               let pageIndex = await fetchFileTreePageIndex(rootID: folder.rootID)
            {
                selectedStoreFileIDs.formUnion(descendantFileIDs(in: folder.id, pageIndex: pageIndex))
            }
        }
        for (path, _) in selection.slices {
            guard let result = await lookupSelectionPath(path, profile: profile, rootScope: request.rootScope),
                  let file = result.file
            else { continue }
            selectedStoreFileIDs.insert(file.id)
        }
        return await makeFileTreeSelectionSnapshot(
            request,
            selectedStoreFileIDs: selectedStoreFileIDs,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            profile: profile
        )
    }

    func lookupSelectionPaths(_ requests: [WorkspacePathLookupRequest]) async -> [String: WorkspacePathLookupResult] {
        var results: [String: WorkspacePathLookupResult] = [:]
        results.reserveCapacity(requests.count)
        for request in requests {
            guard let result = await lookupSelectionPath(
                request.userPath,
                profile: request.profile,
                rootScope: request.rootScope
            ) else { continue }
            results[request.userPath] = result
        }
        return results
    }

    private func lookupSelectionPath(
        _ userPath: String,
        profile: PathLocateProfile,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspacePathLookupResult? {
        switch await lookupCatalogFileForExplicitRequest(userPath, rootScope: rootScope) {
        case let .matched(file):
            return await lookupPath(rootID: file.rootID, relativePath: file.standardizedRelativePath)
        case .ambiguous, .blocked:
            return nil
        case .noCandidate:
            break
        }
        switch try? await materializeExplicitlyRequestedFile(userPath, rootScope: rootScope) {
        case let .some(.materialized(file)):
            return await lookupPath(rootID: file.rootID, relativePath: file.standardizedRelativePath)
        case .some(.ambiguous), .some(.blocked):
            return nil
        case .some(.noCandidate), .none:
            break
        }
        if let direct = await directAbsoluteLookup(userPath, rootScope: rootScope), isDiscoverableLookupResult(direct) {
            return direct
        }
        if let direct = await directUnambiguousRelativeLookup(userPath, rootScope: rootScope), isDiscoverableLookupResult(direct) {
            return direct
        }
        return await lookupPath(userPath, profile: profile, rootScope: rootScope)
    }

    private func directAbsoluteLookup(_ userPath: String, rootScope: WorkspaceLookupRootScope) async -> WorkspacePathLookupResult? {
        let expanded = (userPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let standardizedPath = StandardizedPath.absolute(expanded)
        guard let root = rootsForPathLookup(scope: rootScope)
            .filter({ candidate in
                standardizedPath == candidate.standardizedFullPath
                    || standardizedPath.hasPrefix(candidate.standardizedFullPath + "/")
            })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        else { return nil }
        let relativePath = relativePath(for: standardizedPath, rootPath: root.standardizedFullPath)
        return await lookupPath(rootID: root.id, relativePath: relativePath)
    }

    private func directUnambiguousRelativeLookup(_ userPath: String, rootScope: WorkspaceLookupRootScope) async -> WorkspacePathLookupResult? {
        let expanded = (userPath as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return nil }
        let relativePath = StandardizedPath.relative(expanded)
        guard !relativePath.isEmpty else { return nil }
        var matches: [WorkspacePathLookupResult] = []
        for root in rootsForPathLookup(scope: rootScope) {
            guard let match = await lookupPath(rootID: root.id, relativePath: relativePath) else { continue }
            matches.append(match)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func isDiscoverableLookupResult(_ result: WorkspacePathLookupResult) -> Bool {
        if let file = result.file, !isDiscoverableFileID(file.id) { return false }
        if let folder = result.folder, !isDiscoverableFolderID(folder.id) { return false }
        return true
    }

    private func descendantFileIDs(in folderID: UUID, pageIndex: FileTreePageIndex) -> Set<UUID> {
        var fileIDs = Set((pageIndex.childFileIDsByFolderID[folderID] ?? []).filter(isDiscoverableFileID))
        for childFolderID in (pageIndex.childFolderIDsByFolderID[folderID] ?? []).filter(isDiscoverableFolderID) {
            fileIDs.formUnion(descendantFileIDs(in: childFolderID, pageIndex: pageIndex))
        }
        return fileIDs
    }

    private func makeFileTreeSelectionSnapshot(
        _ request: WorkspaceFileTreeSnapshotRequest,
        selectedStoreFileIDs: Set<UUID>,
        renderableCodemapFileIDs: Set<UUID>
    ) async -> FileTreeSelectionSnapshot {
        await makeFileTreeSelectionSnapshot(
            request,
            selectedStoreFileIDs: selectedStoreFileIDs,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            startFolder: nil
        )
    }

    private func makeFileTreeSelectionSnapshot(
        _ request: WorkspaceFileTreeSnapshotRequest,
        selectedStoreFileIDs: Set<UUID>,
        renderableCodemapFileIDs: Set<UUID>,
        profile: PathLocateProfile
    ) async -> FileTreeSelectionSnapshot {
        let trimmedStartPath = request.startPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedStartPath, !trimmedStartPath.isEmpty else {
            return await makeFileTreeSelectionSnapshot(
                request,
                selectedStoreFileIDs: selectedStoreFileIDs,
                renderableCodemapFileIDs: renderableCodemapFileIDs,
                startFolder: nil
            )
        }
        let startFolder = await resolveFileTreeStartFolder(
            trimmedStartPath,
            request: request,
            profile: profile
        )
        return await makeFileTreeSelectionSnapshot(
            request,
            selectedStoreFileIDs: selectedStoreFileIDs,
            renderableCodemapFileIDs: renderableCodemapFileIDs,
            startFolder: startFolder
        )
    }

    private func resolveFileTreeStartFolder(
        _ trimmedStartPath: String,
        request: WorkspaceFileTreeSnapshotRequest,
        profile: PathLocateProfile
    ) async -> WorkspaceFolderRecord? {
        let roots = rootRefs(scope: request.rootScope)
        let resolution = await resolveFolderInput(
            trimmedStartPath,
            rootScope: request.rootScope,
            profile: profile,
            rootRefs: roots,
            validateIssue: true,
            allowGeneralLookupFallback: false
        )
        return resolution.folder
    }

    private func makeFileTreeSelectionSnapshot(
        _ request: WorkspaceFileTreeSnapshotRequest,
        selectedStoreFileIDs: Set<UUID>,
        renderableCodemapFileIDs: Set<UUID>,
        startFolder: WorkspaceFolderRecord?
    ) async -> FileTreeSelectionSnapshot {
        let selectedFileIDs = selectedStoreFileIDs
        let explicitlyIncludedManagedOnlyFileIDs = request.mode == .selected
            ? Set(selectedFileIDs.filter { managedOnlyFileIDs.contains($0) })
            : []
        let explicitlyIncludedManagedOnlyFolderIDs = await managedOnlyAncestorFolderIDs(for: explicitlyIncludedManagedOnlyFileIDs)
        var roots: [FileTreeFolderSnapshot] = []
        if let startFolder,
           let root = rootStatesByID[startFolder.rootID]?.root,
           let pageIndex = await fetchFileTreePageIndex(rootID: startFolder.rootID)
        {
            var visited = Set<UUID>()
            roots = makeFileTreeFolderSnapshot(
                startFolder,
                rootStandardizedPath: root.standardizedFullPath,
                pageIndex: pageIndex,
                visited: &visited,
                renderableCodemapFileIDs: renderableCodemapFileIDs,
                explicitlyIncludedManagedOnlyFileIDs: explicitlyIncludedManagedOnlyFileIDs,
                explicitlyIncludedManagedOnlyFolderIDs: explicitlyIncludedManagedOnlyFolderIDs
            ).map { [$0] } ?? []
        } else if request.startPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            roots = []
        } else {
            for root in rootsForPathLookup(scope: request.rootScope) {
                guard let pageIndex = await fetchFileTreePageIndex(rootID: root.id) else { continue }
                // The root's own self-referencing folder marker (id == rootID, relativePath == "")
                // is never sent to Rust (root-marker exclusion, see
                // `WorkspaceInventoryScopeShadowForwarder`'s doc comment) -- constructed here rather
                // than fetched.
                let rootFolder = WorkspaceFolderRecord(
                    id: root.id, rootID: root.id, name: root.name,
                    relativePath: "", fullPath: root.fullPath, parentFolderID: nil
                )
                var visited = Set<UUID>()
                if let snapshot = makeFileTreeFolderSnapshot(
                    rootFolder,
                    rootStandardizedPath: root.standardizedFullPath,
                    pageIndex: pageIndex,
                    visited: &visited,
                    renderableCodemapFileIDs: renderableCodemapFileIDs,
                    explicitlyIncludedManagedOnlyFileIDs: explicitlyIncludedManagedOnlyFileIDs,
                    explicitlyIncludedManagedOnlyFolderIDs: explicitlyIncludedManagedOnlyFolderIDs
                ) {
                    roots.append(snapshot)
                }
            }
        }

        return FileTreeSelectionSnapshot(
            roots: roots,
            selectedFileIDs: selectedFileIDs,
            mode: request.mode.rawValue,
            showFullPaths: request.filePathDisplay == .full,
            onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
            includeLegend: request.includeLegend,
            showCodeMapMarkers: request.showCodeMapMarkers,
            maxDepth: request.maxDepth
        )
    }

    /// P4-6b: an ephemeral, per-call, in-memory index built from one paged read of the authority
    /// (Tier-1, contract doc §6.1) -- not a retained mirror (the charter's single-authority rule
    /// forbids retaining table content across a suspension boundary; this is built fresh on every
    /// file-tree snapshot request and discarded when the request returns).
    private struct FileTreePageIndex {
        var filesByID: [UUID: WorkspaceFileRecord] = [:]
        var foldersByID: [UUID: WorkspaceFolderRecord] = [:]
        var childFolderIDsByFolderID: [UUID: [UUID]] = [:]
        var childFileIDsByFolderID: [UUID: [UUID]] = [:]
    }

    private func fetchFileTreePageIndex(rootID: UUID) async -> FileTreePageIndex? {
        guard let authority = try? await inventoryScopeAuthorityInstance(),
              let snapshot = try? await authority.openSnapshot(rootID: rootID)
        else { return nil }
        defer { Task { await snapshot.close() } }
        var index = FileTreePageIndex()
        var offset: UInt64 = 0
        while true {
            guard let page = try? await snapshot.page(offset: offset, limit: 4096) else { break }
            for coreFile in page.files {
                let file = WorkspaceInventoryScopeRepublicationAdapter.workspaceFileRecord(coreFile)
                index.filesByID[file.id] = file
                if let parentID = file.parentFolderID {
                    index.childFileIDsByFolderID[parentID, default: []].append(file.id)
                }
            }
            for coreFolder in page.folders {
                let folder = WorkspaceInventoryScopeRepublicationAdapter.workspaceFolderRecord(coreFolder)
                index.foldersByID[folder.id] = folder
                if let parentID = folder.parentFolderID {
                    index.childFolderIDsByFolderID[parentID, default: []].append(folder.id)
                }
            }
            offset += page.returnedCount
            if !page.hasMore || page.returnedCount == 0 { break }
        }
        return index
    }

    func codemapMarkerReadinessUpdates() -> AsyncStream<WorkspaceCodemapMarkerReadinessEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            codemapMarkerReadinessContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeCodemapMarkerReadinessContinuation(id) }
            }
        }
    }

    private func removeCodemapMarkerReadinessContinuation(_ id: UUID) {
        codemapMarkerReadinessContinuations.removeValue(forKey: id)
    }

    func codemapRootStatusUpdates() -> AsyncStream<WorkspaceCodemapRootStatusUpdate> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            codemapRootStatusContinuations[id] = continuation
            continuation.yield(currentCodemapRootStatusUpdate())
            continuation.onTermination = { _ in
                Task { await self.removeCodemapRootStatusContinuation(id) }
            }
        }
    }

    func codemapRootStatusSnapshot(rootID: UUID) -> WorkspaceCodemapRootStatusSnapshot? {
        guard let state = rootStatesByID[rootID] else { return nil }
        return makeCodemapRootStatusSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: state.lifetimeID)
        )
    }

    func setCodemapGenerationSuspended(
        rootID: UUID,
        suspended: Bool
    ) async -> WorkspaceCodemapRootSuspensionUpdateResult {
        guard let state = rootStatesByID[rootID] else { return .rootUnavailable }
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: state.lifetimeID)

        if suspended {
            let cancelledResume = codemapResumeTransitionIDsByRootEpoch.removeValue(forKey: rootEpoch) != nil
            let inserted = codemapSuspendedRootEpochs.insert(rootEpoch).inserted
            guard inserted || cancelledResume else { return .unchanged }
            codemapGraphIndexBuildReschedulePendingRootEpochs.remove(rootEpoch)
            publishCodemapRootStatusesIfChanged()
            if inserted {
                let engine = codemapSessionsByRootEpoch[rootEpoch]?.engine
                _ = detachCodemapSession(rootEpoch: rootEpoch)
                if let engine {
                    await engine.cancelGraphIndex(rootEpoch: rootEpoch)
                }
            }
            return .changed
        }

        guard codemapSuspendedRootEpochs.contains(rootEpoch),
              codemapResumeTransitionIDsByRootEpoch[rootEpoch] == nil
        else { return .unchanged }
        let resumeID = UUID()
        codemapResumeTransitionIDsByRootEpoch[rootEpoch] = resumeID
        if let cleanup = codemapCleanupFlightsByRootID[rootID] {
            await cleanup.task.value
        }
        guard rootStatesByID[rootID]?.lifetimeID == rootEpoch.rootLifetimeID else {
            if codemapResumeTransitionIDsByRootEpoch[rootEpoch] == resumeID {
                codemapResumeTransitionIDsByRootEpoch.removeValue(forKey: rootEpoch)
            }
            return .rootUnavailable
        }
        guard codemapResumeTransitionIDsByRootEpoch[rootEpoch] == resumeID,
              codemapSuspendedRootEpochs.remove(rootEpoch) != nil
        else { return .unchanged }
        codemapResumeTransitionIDsByRootEpoch.removeValue(forKey: rootEpoch)
        scheduleCodemapGraphIndexBuildAfterRootReady(rootEpoch: rootEpoch)
        publishCodemapRootStatusesIfChanged()
        return .changed
    }

    func prioritizeCodemapGraphIndexNow(
        rootID: UUID
    ) async -> WorkspaceCodemapGraphIndexPrioritizeDisposition {
        guard let state = rootStatesByID[rootID] else { return .unavailable }
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: state.lifetimeID)
        guard !codemapGenerationIsSuspended(rootEpoch: rootEpoch) else { return .unavailable }
        codemapGraphIndexRetryExhaustionByRootEpoch.removeValue(forKey: rootEpoch)
        codemapGraphIndexBuildRetriesByRootEpoch.removeValue(forKey: rootEpoch)?.task.cancel()
        recordCodemapGraphIndexBuildStoreEvent(
            .prioritizeNow,
            rootEpoch: rootEpoch,
            phase: codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch]?.phase ?? .notScheduled
        )
        if let engine = codemapSessionsByRootEpoch[rootEpoch]?.engine {
            let disposition = await engine.prioritizeGraphIndexNow(rootEpoch: rootEpoch)
            if disposition != .unavailable {
                codemapGraphIndexWorkerRecoveryExhaustedRootEpochs.remove(rootEpoch)
            }
            publishCodemapRootStatusesIfChanged()
            return disposition
        }
        if let launch = codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch] {
            switch launch.phase {
            case .transientRetry, .retryExhausted, .cancelled, .superseded:
                codemapGraphIndexBuildLaunchesByRootEpoch.removeValue(forKey: rootEpoch)
            case .notScheduled, .eligibilityQueued, .setupJoining, .engineScheduling,
                 .handedOff, .terminalNonGit:
                return .promoted
            }
        }
        scheduleCodemapGraphIndexBuildAfterRootReady(rootEpoch: rootEpoch)
        publishCodemapRootStatusesIfChanged()
        return codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch] == nil ? .unavailable : .scheduled
    }

    private func removeCodemapRootStatusContinuation(_ id: UUID) {
        codemapRootStatusContinuations.removeValue(forKey: id)
    }

    private func codemapGenerationIsSuspended(rootEpoch: WorkspaceCodemapRootEpoch) -> Bool {
        codemapSuspendedRootEpochs.contains(rootEpoch)
    }

    func currentCodemapRootStatusUpdate() -> WorkspaceCodemapRootStatusUpdate {
        WorkspaceCodemapRootStatusUpdate(
            revision: codemapRootStatusRevision,
            roots: currentCodemapRootStatusSnapshots()
        )
    }

    private func currentCodemapRootStatusSnapshots() -> [WorkspaceCodemapRootStatusSnapshot] {
        rootLoadOrder.compactMap { rootID in
            guard let state = rootStatesByID[rootID] else { return nil }
            return makeCodemapRootStatusSnapshot(
                rootEpoch: WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: state.lifetimeID)
            )
        }
    }

    private func makeCodemapRootStatusSnapshot(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> WorkspaceCodemapRootStatusSnapshot {
        let suspended = codemapGenerationIsSuspended(rootEpoch: rootEpoch)
        let accounting = codemapGraphAccountingByRootEpoch[rootEpoch]
        let launchPhase = codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch]?.phase
        let unavailableReason: WorkspaceCodemapRootStatusUnavailableReason? = if codemapGraphIndexWorkerRecoveryExhaustedRootEpochs.contains(rootEpoch) {
            .workerRecoveryExhausted
        } else {
            switch launchPhase {
            case .terminalNonGit: .notGitRepository
            case .retryExhausted: .retryExhausted
            default: nil
            }
        }
        let availability: WorkspaceCodemapRootAvailability = if accounting?.revocationReason != nil {
            .revoked
        } else if unavailableReason != nil {
            .unavailable
        } else if accounting == nil || accounting?.graphRevision == 0 {
            switch launchPhase {
            case .eligibilityQueued, .setupJoining, .engineScheduling, .handedOff, .transientRetry:
                .indexing
            case .terminalNonGit, .retryExhausted:
                .unavailable
            case .notScheduled, .cancelled, .superseded, nil:
                .notInitialized
            }
        } else if accounting?.reconciling == true {
            .reconciling
        } else if accounting?.coverage?.isComplete != true {
            .indexing
        } else if accounting?.activeApply == true || accounting?.updatesPending == true {
            .updating
        } else {
            .ready
        }
        let zeroGeneration = WorkspaceCodemapSelectionGraphContributionGeneration(rawValue: 0)
        return WorkspaceCodemapRootStatusSnapshot(
            rootEpoch: rootEpoch,
            availability: availability,
            isGenerationSuspended: suspended,
            coverage: accounting?.coverage,
            graphRevision: accounting.flatMap { $0.graphRevision == 0 ? nil : $0.graphRevision },
            appliedGeneration: accounting?.appliedGeneration ?? zeroGeneration,
            observedGeneration: accounting?.observedGeneration ?? zeroGeneration,
            updatesPending: accounting?.updatesPending ?? false,
            reconciliationAttempt: accounting?.reconciliationAttempt,
            reconciliationDeadlineUptimeNanoseconds: accounting?.reconciliationDeadlineUptimeNanoseconds,
            commitCadence: WorkspaceCodemapGraphCommitCadence(
                successfulCommitCount: accounting?.successfulCommitCount ?? 0,
                resyncCommitCount: accounting?.resyncCommitCount ?? 0,
                lastCommittedUptimeNanoseconds: accounting?.lastCommittedUptimeNanoseconds,
                lastCommitIntervalMilliseconds: accounting?.lastCommitIntervalMilliseconds
            ),
            diagnostics: WorkspaceCodemapGraphRootDiagnostics(
                rejectedApplyCount: accounting?.rejectedApplyCount ?? 0,
                fencedFileCount: accounting?.fencedFileCount ?? 0,
                activeApply: accounting?.activeApply ?? false,
                safetyCounter: accounting?.safetyCounter ?? 0,
                revocationReason: accounting?.revocationReason,
                diffPullCount: accounting?.diffPullCount ?? 0,
                resyncPullCount: accounting?.resyncPullCount ?? 0,
                revokedPullCount: accounting?.revokedPullCount ?? 0,
                lastChangedFileCount: accounting?.lastChangedFileCount ?? 0,
                lastAffectedSourceCount: accounting?.lastAffectedSourceCount ?? 0,
                totalChangedFileCount: accounting?.totalChangedFileCount ?? 0,
                totalAffectedSourceCount: accounting?.totalAffectedSourceCount ?? 0,
                currentQueryCount: accounting?.currentQueryCount ?? 0,
                pendingQueryCount: accounting?.pendingQueryCount ?? 0,
                partialCoverageQueryCount: accounting?.partialCoverageQueryCount ?? 0,
                reconciliationStartedCount: accounting?.reconciliationStartedCount ?? 0,
                reconciliationCoalescedCount: accounting?.reconciliationCoalescedCount ?? 0,
                reconciliationCommittedCount: accounting?.reconciliationCommittedCount ?? 0,
                reconciliationRetryCount: accounting?.reconciliationRetryCount ?? 0,
                reconciliationRevokedCount: accounting?.reconciliationRevokedCount ?? 0,
                receiptValidationCount: accounting?.receiptValidationCount ?? 0,
                receiptRejectionCount: accounting?.receiptRejectionCount ?? 0,
                lastApplyDurationMilliseconds: accounting?.lastApplyDurationMilliseconds,
                maximumApplyDurationMilliseconds: accounting?.maximumApplyDurationMilliseconds,
                highFanoutApplyCount: accounting?.highFanoutApplyCount ?? 0,
                observedToAppliedGenerationLag: accounting?.observedToAppliedGenerationLag ?? 0
            ),
            unavailableReason: unavailableReason
        )
    }

    private func publishCodemapRootStatusesIfChanged() {
        let roots = currentCodemapRootStatusSnapshots()
        guard roots != lastPublishedCodemapRootStatuses else { return }
        lastPublishedCodemapRootStatuses = roots
        codemapRootStatusRevision &+= 1
        let update = WorkspaceCodemapRootStatusUpdate(revision: codemapRootStatusRevision, roots: roots)
        for continuation in codemapRootStatusContinuations.values {
            continuation.yield(update)
        }
    }

    @discardableResult
    func loadRoot(
        path: String,
        isSystemRoot: Bool = false,
        kind: WorkspaceRootKind? = nil,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        skipSymlinks: Bool = true,
        enableHierarchicalIgnores: Bool = true,
        cancelUnderlyingLoadOnCallerCancellation: Bool = false,
        sessionWorktreeReservationToken: WorkspaceSessionWorktreeOwnershipToken? = nil
    ) async throws -> WorkspaceRootRecord {
        let standardizedPath = (path as NSString).standardizingPath
        #if DEBUG
            let rootLoadRouteStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let rootLoadName = URL(fileURLWithPath: standardizedPath).lastPathComponent
        #endif
        try Task.checkCancellation()
        try await waitForRootUnloadIfNeeded(standardizedPath: standardizedPath)
        try Task.checkCancellation()
        try await waitForPendingSeededRootVisibilityIfNeeded(
            standardizedPath: standardizedPath,
            bypassToken: sessionWorktreeReservationToken
        )
        try Task.checkCancellation()
        if let sessionWorktreeReservationToken {
            guard sessionWorktreeReservedPathsByToken[
                sessionWorktreeReservationToken
            ]?.contains(standardizedPath) == true else {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
        }
        let loadConfiguration = RootLoadConfiguration(
            kind: kind ?? (isSystemRoot ? .supplementalSystem : .primaryWorkspace),
            gitignorePolicyIdentity: .current,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            skipSymlinks: skipSymlinks,
            enableHierarchicalIgnores: enableHierarchicalIgnores
        )
        if let existingID = rootIDsByStandardizedPath[standardizedPath],
           let existing = rootStatesByID[existingID]?.root
        {
            guard let existingConfiguration = rootLoadConfigurationsByPath[standardizedPath], existingConfiguration == loadConfiguration else {
                throw WorkspaceFileContextStoreError.rootAlreadyLoadedWithDifferentConfiguration(standardizedPath)
            }
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "store.rootLoad.existing",
                    fields: [
                        "rootName": rootLoadName,
                        "rootID": WorkspaceRestorePerfLog.shortID(existing.id),
                        "kind": "\(loadConfiguration.kind)",
                        "duration": rootLoadRouteStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return existing
        }
        if let inFlight = rootLoadFlightsByPath[standardizedPath] {
            guard rootLoadConfigurationsByPath[standardizedPath] == loadConfiguration else {
                throw WorkspaceFileContextStoreError.rootLoadInFlightWithDifferentConfiguration(standardizedPath)
            }
            if let sessionWorktreeReservationToken {
                registerSessionWorktreeReservationLoadFlight(
                    inFlight,
                    standardizedPath: standardizedPath,
                    token: sessionWorktreeReservationToken
                )
            }
            #if DEBUG
                WorkspaceRestorePerfLog.event(
                    "store.rootLoad.joinInFlight",
                    fields: [
                        "rootName": rootLoadName,
                        "kind": "\(loadConfiguration.kind)"
                    ]
                )
                if let rootLoadDidJoinInFlightHandler {
                    await rootLoadDidJoinInFlightHandler(standardizedPath)
                }
            #endif
            return try await awaitRootLoadTask(
                inFlight.task,
                flightID: inFlight.id,
                standardizedPath: standardizedPath,
                cancelUnderlyingLoadOnCallerCancellation: cancelUnderlyingLoadOnCallerCancellation
            )
        }

        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.scheduled",
                fields: [
                    "rootName": rootLoadName,
                    "kind": "\(loadConfiguration.kind)"
                ]
            )
        #endif
        let completion = RootLoadFlightCompletion()
        let task = Task { [weak self] in
            guard let self else { throw WorkspaceFileContextStoreError.storeDeallocated }
            return try await FileSystemService.withContentReadForegroundActivity(kind: .rootLoad) {
                try await self.performLoadRoot(
                    standardizedPath: standardizedPath,
                    isSystemRoot: isSystemRoot,
                    kind: kind,
                    respectRepoIgnore: respectRepoIgnore,
                    respectCursorignore: respectCursorignore,
                    skipSymlinks: skipSymlinks,
                    enableHierarchicalIgnores: enableHierarchicalIgnores,
                    completion: completion
                )
            }
        }
        let flightID = UUID()
        let flight = RootLoadFlight(
            id: flightID,
            task: task,
            completion: completion
        )
        rootLoadFlightsByPath[standardizedPath] = flight
        rootLoadConfigurationsByPath[standardizedPath] = loadConfiguration
        if let sessionWorktreeReservationToken {
            registerSessionWorktreeReservationLoadFlight(
                flight,
                standardizedPath: standardizedPath,
                token: sessionWorktreeReservationToken
            )
        }
        Task { [weak self] in
            _ = try? await task.value
            await self?.clearCompletedRootLoadTask(
                standardizedPath: standardizedPath,
                expectedFlightID: flightID
            )
        }
        return try await awaitRootLoadTask(
            task,
            flightID: flightID,
            standardizedPath: standardizedPath,
            cancelUnderlyingLoadOnCallerCancellation: cancelUnderlyingLoadOnCallerCancellation
        )
    }

    private func awaitRootLoadTask(
        _ task: Task<WorkspaceRootRecord, Error>,
        flightID: UUID,
        standardizedPath: String,
        cancelUnderlyingLoadOnCallerCancellation: Bool
    ) async throws -> WorkspaceRootRecord {
        let race = RootLoadTaskWaitRace()
        Task {
            await race.resolve(task.result)
        }
        let root = try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            race.cancel()
            guard cancelUnderlyingLoadOnCallerCancellation else { return }
            task.cancel()
            Task {
                await self.cancelRootLoad(
                    standardizedPath: standardizedPath,
                    expectedFlightID: flightID
                )
            }
        }
        try Task.checkCancellation()
        return root
    }

    func cancelRootLoad(path: String) {
        let standardizedPath = (path as NSString).standardizingPath
        guard let flight = rootLoadFlightsByPath[standardizedPath] else { return }
        flight.task.cancel()
        removeRootLoadFlight(
            standardizedPath: standardizedPath,
            expectedFlightID: flight.id
        )
    }

    private func cancelRootLoad(
        standardizedPath: String,
        expectedFlightID: UUID
    ) {
        guard let flight = rootLoadFlightsByPath[standardizedPath],
              flight.id == expectedFlightID
        else { return }
        flight.task.cancel()
        removeRootLoadFlight(
            standardizedPath: standardizedPath,
            expectedFlightID: expectedFlightID
        )
    }

    private func clearCompletedRootLoadTask(
        standardizedPath: String,
        expectedFlightID: UUID
    ) {
        removeRootLoadFlight(
            standardizedPath: standardizedPath,
            expectedFlightID: expectedFlightID
        )
    }

    private func removeRootLoadFlight(
        standardizedPath: String,
        expectedFlightID: UUID
    ) {
        guard rootLoadFlightsByPath[standardizedPath]?.id == expectedFlightID else { return }
        rootLoadFlightsByPath.removeValue(forKey: standardizedPath)
        if rootIDsByStandardizedPath[standardizedPath] == nil {
            rootLoadConfigurationsByPath.removeValue(forKey: standardizedPath)
        }
    }

    private func performLoadRoot(
        standardizedPath: String,
        isSystemRoot: Bool,
        kind: WorkspaceRootKind?,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        skipSymlinks: Bool,
        enableHierarchicalIgnores: Bool,
        completion: RootLoadFlightCompletion
    ) async throws -> WorkspaceRootRecord {
        #if DEBUG
            let benchmarkMetricTag = WorktreeStartupInstrumentation.currentBenchmarkMetricTag
            let benchmarkFilesystemStarted = DispatchTime.now().uptimeNanoseconds
            defer {
                let finished = DispatchTime.now().uptimeNanoseconds
                WorktreeStartupInstrumentation.recordBenchmarkFilesystemWork(
                    tag: benchmarkMetricTag,
                    durationMicroseconds: finished >= benchmarkFilesystemStarted
                        ? (finished - benchmarkFilesystemStarted) / 1000
                        : 0,
                    itemCount: 1
                )
            }
        #endif
        if let existingID = rootIDsByStandardizedPath[standardizedPath],
           let existingState = rootStatesByID[existingID]
        {
            completion.record(
                rootID: existingState.root.id,
                lifetimeID: existingState.lifetimeID
            )
            return existingState.root
        }

        #if DEBUG
            if let rootLoadWillStartHandler {
                await rootLoadWillStartHandler(standardizedPath)
            }
        #endif

        let rootURL = URL(fileURLWithPath: standardizedPath).standardizedFileURL
        #if DEBUG
            let performLoadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.begin",
                fields: [
                    "rootName": rootURL.lastPathComponent,
                    "kind": "\(kind ?? (isSystemRoot ? .supplementalSystem : .primaryWorkspace))",
                    "isSystemRoot": "\(isSystemRoot)"
                ]
            )
        #endif
        let root = if let kind {
            WorkspaceRootRecord(name: rootURL.lastPathComponent, fullPath: rootURL.path, kind: kind)
        } else {
            WorkspaceRootRecord(name: rootURL.lastPathComponent, fullPath: rootURL.path, isSystemRoot: isSystemRoot)
        }
        let service = try await FileSystemService(
            path: root.fullPath,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            skipSymlinks: skipSymlinks,
            enableHierarchicalIgnores: enableHierarchicalIgnores
        )
        #if DEBUG
            if let watcherActivationFailurePointForNewServicesForTesting {
                await service.setWatcherActivationFailureForTesting(
                    watcherActivationFailurePointForNewServicesForTesting
                )
            }
        #endif

        #if DEBUG
            var rootRecordCreatedFields: [String: String] = [
                "rootName": root.name,
                "rootID": WorkspaceRestorePerfLog.shortID(root.id),
                "kind": "\(root.kind)",
                "durationSinceStoreRootLoadBegin": performLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
            ]
            rootRecordCreatedFields.merge(
                WorkspaceRootLoadDiagnostics.rootRecordCreatedFields(forPath: standardizedPath),
                uniquingKeysWith: { _, diagnostic in diagnostic }
            )
            WorkspaceRestorePerfLog.event("store.rootLoad.rootRecordCreated", fields: rootRecordCreatedFields)
        #endif

        let state = RootState(
            lifetimeID: UUID(),
            root: root,
            service: service,
            folderIDsByRelativePath: [:],
            fileIDsByRelativePath: [:],
            childFolderIDsByFolderID: [:],
            childFileIDsByFolderID: [:]
        )

        // P4-6b: the Rust root must be open before any indexFolders/indexFiles call below can
        // apply a mutation against it. The root's own self-referencing folder marker (id ==
        // root.id, relativePath == "") is never sent to Rust (root-marker exclusion) -- it is
        // reconstructed on demand wherever it's needed (see the file-tree snapshot code) rather
        // than staged here.
        if let authority = try? await inventoryScopeAuthorityInstance() {
            _ = try? await authority.openRootIfNeeded(
                rootID: root.id, swiftLifetimeID: state.lifetimeID, name: root.name, standardizedFullPath: root.standardizedFullPath
            )
        }

        #if DEBUG
            let coldStartWalkStart = WorkspaceFileSearchDebugTiming.now()
            let walkStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            var chunkCount = 0
        #endif
        for try await event in await service.loadContentsInChunks(of: rootURL) {
            try Task.checkCancellation()
            guard case let .preparedItems(chunk) = event else { continue }
            #if DEBUG
                chunkCount += 1
                if chunkCount == 1 {
                    var firstChunkFields: [String: String] = [
                        "rootName": root.name,
                        "rootID": WorkspaceRestorePerfLog.shortID(root.id),
                        "chunkFolders": "\(chunk.folders.count)",
                        "chunkFiles": "\(chunk.files.count)",
                        "durationSinceStoreRootLoadBegin": performLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                    firstChunkFields.merge(
                        WorkspaceRootLoadDiagnostics.firstPreparedChunkFields(forPath: standardizedPath),
                        uniquingKeysWith: { _, diagnostic in diagnostic }
                    )
                    WorkspaceRestorePerfLog.event("store.rootLoad.firstPreparedChunk", fields: firstChunkFields)
                }
            #endif
            await indexFolders(chunk.folders, root: root)
            await indexFiles(chunk.files, root: root)
        }
        try Task.checkCancellation()
        #if DEBUG
            WorkspaceFileSearchDebugContext.coldStartCollector?.recordRootCrawl(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: coldStartWalkStart,
                    through: WorkspaceFileSearchDebugTiming.now()
                ),
                files: 0,
                folders: 0
            )
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.walk",
                fields: [
                    "rootName": root.name,
                    "chunkCount": "\(chunkCount)",
                    "duration": walkStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        // P4-6b: `indexFolders`/`indexFiles` above already applied every mutation to the Rust
        // authority per chunk -- no separate commit step (the pre-cutover staged-then-committed
        // `RootIndexBuffers` pattern no longer applies; Rust's own bulk-load control plane
        // already atomically stages-then-publishes, contract doc §5.2).
        if root.kind == .sessionWorktree {
            sessionRootLifetimeClock.advance()
        }
        rootIDsByStandardizedPath[root.standardizedFullPath] = root.id
        rootStatesByID[root.id] = state
        completion.record(rootID: root.id, lifetimeID: state.lifetimeID)
        rootLoadOrder.append(root.id)
        appliedIndexGenerationsByRootID[root.id] = 0
        catalogGenerationsByRootID[root.id] = 0
        #if DEBUG
            rootCrawlCountsByRootID[root.id, default: 0] += 1
        #endif
        invalidatePathMatchSnapshot(
            affectedRootKinds: [root.kind],
            reason: .rootLoad,
            affectedRootIDs: [root.id]
        )
        if root.kind == .sessionWorktree,
           WorktreeStartupFeatureFlags.current().observeDiffSeededWorktreeStartup
        {
            _ = try? await admitReusableSnapshotForLoadedRoot(
                rootID: root.id,
                expectedStandardizedPath: root.standardizedFullPath
            )
        }
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: root.id,
            rootLifetimeID: state.lifetimeID
        )
        recordCodemapRootReadyForGraphIndexBuild(rootEpoch: rootEpoch)
        publishCodemapRootStatusesIfChanged()
        scheduleCodemapGraphIndexBuildAfterRootReady(rootEpoch: rootEpoch)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.end",
                fields: [
                    "rootName": root.name,
                    "rootID": WorkspaceRestorePerfLog.shortID(root.id),
                    "duration": performLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        return root
    }

    /// Constructs fresh target-local IDs and records for a pending seeded root.
    /// No source-worktree record, metadata, descriptor, or cache is reused.
    private func makePendingSeededRootTopology(
        standardizedPath: String,
        service: FileSystemService,
        inventorySnapshot: FileSystemSeededInventorySnapshot? = nil,
        root existingRoot: WorkspaceRootRecord? = nil,
        lifetimeID existingLifetimeID: UUID? = nil
    ) throws -> (state: RootState, indexes: RootIndexBuffers) {
        let rootURL = URL(fileURLWithPath: standardizedPath).standardizedFileURL
        let root = existingRoot ?? WorkspaceRootRecord(
            name: rootURL.lastPathComponent,
            fullPath: rootURL.path,
            kind: .sessionWorktree
        )
        var state = RootState(
            lifetimeID: existingLifetimeID ?? UUID(),
            root: root,
            service: service,
            folderIDsByRelativePath: [:],
            fileIDsByRelativePath: [:],
            childFolderIDsByFolderID: [:],
            childFileIDsByFolderID: [:]
        )
        var indexes = RootIndexBuffers()
        let rootFolder = WorkspaceFolderRecord(
            id: root.id,
            rootID: root.id,
            name: root.name,
            relativePath: "",
            fullPath: root.fullPath,
            parentFolderID: nil
        )
        indexes.foldersByID[rootFolder.id] = rootFolder
        indexes.folderIDsByStandardizedFullPath[rootFolder.standardizedFullPath] = rootFolder.id
        state.folderIDsByRelativePath[""] = rootFolder.id

        if let inventorySnapshot {
            let reader = try inventorySnapshot.makeReader()
            while let item = try reader.next() {
                let dto = FSItemDTO(
                    relativePath: item.relativePath,
                    isDirectory: item.isDirectory,
                    hierarchy: item.relativePath.split(separator: "/").count
                )
                if item.isDirectory {
                    indexFolders([dto], root: root, state: &state, indexes: &indexes)
                } else {
                    indexFiles([dto], root: root, state: &state, indexes: &indexes)
                }
            }
        }
        return (state, indexes)
    }

    // P4-6b reroute (STOP-then-reroute, see docs/architecture/rust-inventory-scope-v1.md
    // §12): the diff-seeded worktree fast path's whole value is avoiding a filesystem crawl by
    // replaying a cached diff into a complete record set entirely offline. That computation must
    // stay pure/local -- it also backs `WorkspaceProjectedPathSearchIndex`'s replay-consistency
    // validation below, which is NOT a search-index nicety but the fast path's own correctness
    // self-check (a `nil` there means the diff replay disagreed with the cached snapshot, and
    // triggers a fallback to the ordinary full crawl). These three helpers are therefore restored
    // verbatim from the pre-cutover implementation -- pure functions over caller-supplied `state`/
    // `indexes`, never touching the deleted global `filesByID`/`foldersByID`/path maps -- as a
    // distinct overload from the live Rust-routed `indexFolders(_:root:)`/`indexFiles(_:root:)`
    // choke points used by the ordinary crawl path. Once the replay is validated, the resulting
    // record set is fed through those *other*, already-Rust-routed choke points
    // (`indexFolder`/`indexFile`, called from `preparePendingSeededRoot` below) to seed Rust --
    // reusing the exact mechanism already proven correct for live discovery, rather than a new
    // bulk-discovery primitive whose parent-id-ordering semantics against a single fresh root are
    // unproven.
    private func indexFolders(_ items: [FSItemDTO], root: WorkspaceRootRecord, state: inout RootState, indexes: inout RootIndexBuffers) {
        for item in items {
            let relativePath = StandardizedPath.relative(item.relativePath)
            guard state.folderIDsByRelativePath[relativePath] == nil else { continue }
            let parentPath = (relativePath as NSString).deletingLastPathComponent
            let parentID = ensureParentFolderID(for: parentPath, root: root, state: &state, indexes: &indexes)
            let folder = WorkspaceFolderRecord(
                rootID: root.id,
                name: URL(fileURLWithPath: relativePath).lastPathComponent,
                relativePath: relativePath,
                fullPath: (root.fullPath as NSString).appendingPathComponent(relativePath),
                parentFolderID: parentID
            )
            indexes.foldersByID[folder.id] = folder
            indexes.folderIDsByStandardizedFullPath[folder.standardizedFullPath] = folder.id
            state.folderIDsByRelativePath[folder.standardizedRelativePath] = folder.id
            state.childFolderIDsByFolderID[parentID, default: []].append(folder.id)
        }
    }

    private func indexFiles(_ items: [FSItemDTO], root: WorkspaceRootRecord, state: inout RootState, indexes: inout RootIndexBuffers) {
        for item in items {
            let relativePath = StandardizedPath.relative(item.relativePath)
            guard state.fileIDsByRelativePath[relativePath] == nil else { continue }
            let parentID = ensureParentFolderID(for: (relativePath as NSString).deletingLastPathComponent, root: root, state: &state, indexes: &indexes)
            let file = WorkspaceFileRecord(
                rootID: root.id,
                name: URL(fileURLWithPath: relativePath).lastPathComponent,
                relativePath: relativePath,
                fullPath: (root.fullPath as NSString).appendingPathComponent(relativePath),
                parentFolderID: parentID
            )
            indexes.filesByID[file.id] = file
            indexes.fileIDsByStandardizedFullPath[file.standardizedFullPath] = file.id
            state.fileIDsByRelativePath[file.standardizedRelativePath] = file.id
            state.childFileIDsByFolderID[parentID, default: []].append(file.id)
        }
    }

    private func ensureParentFolderID(for relativePath: String, root: WorkspaceRootRecord, state: inout RootState, indexes: inout RootIndexBuffers) -> UUID {
        let key = StandardizedPath.relative(relativePath)
        if key.isEmpty || key == "." { return root.id }
        if let existing = state.folderIDsByRelativePath[key] { return existing }

        let parentPath = (key as NSString).deletingLastPathComponent
        let parentID = ensureParentFolderID(for: parentPath, root: root, state: &state, indexes: &indexes)
        let folder = WorkspaceFolderRecord(
            rootID: root.id,
            name: URL(fileURLWithPath: key).lastPathComponent,
            relativePath: key,
            fullPath: (root.fullPath as NSString).appendingPathComponent(key),
            parentFolderID: parentID
        )
        indexes.foldersByID[folder.id] = folder
        indexes.folderIDsByStandardizedFullPath[folder.standardizedFullPath] = folder.id
        state.folderIDsByRelativePath[folder.standardizedRelativePath] = folder.id
        state.childFolderIDsByFolderID[parentID, default: []].append(folder.id)
        return folder.id
    }

    private func waitForRootUnloadIfNeeded(standardizedPath: String) async throws {
        try Task.checkCancellation()
        while unloadingRootPaths.contains(standardizedPath) {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    unloadWaitersByRootPath[standardizedPath, default: [:]][waiterID] = continuation
                }
            } onCancel: {
                Task { await self.cancelRootUnloadWaiter(standardizedPath: standardizedPath, waiterID: waiterID) }
            }
            try Task.checkCancellation()
        }
    }

    private func waitForPendingSeededRootVisibilityIfNeeded(
        standardizedPath: String,
        bypassToken: WorkspaceSessionWorktreeOwnershipToken?
    ) async throws {
        while let pendingID = pendingSeededRootIDsByStandardizedPath[standardizedPath],
              let pending = pendingSeededRootsByID[pendingID]
        {
            if pending.token == bypassToken {
                throw WorkspaceSessionWorktreeOwnershipError.staleUpdate
            }
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pendingSeededRootVisibilityWaitersByPath[standardizedPath, default: [:]][waiterID] = continuation
                }
            } onCancel: {
                Task {
                    await self.cancelPendingSeededRootVisibilityWaiter(
                        standardizedPath: standardizedPath,
                        waiterID: waiterID
                    )
                }
            }
            try Task.checkCancellation()
        }
    }

    private func cancelPendingSeededRootVisibilityWaiter(
        standardizedPath: String,
        waiterID: UUID
    ) {
        guard let continuation = pendingSeededRootVisibilityWaitersByPath[standardizedPath]?
            .removeValue(forKey: waiterID)
        else { return }
        if pendingSeededRootVisibilityWaitersByPath[standardizedPath]?.isEmpty == true {
            pendingSeededRootVisibilityWaitersByPath.removeValue(forKey: standardizedPath)
        }
        continuation.resume(throwing: CancellationError())
    }

    private func finishPendingSeededRootVisibility(path: String) {
        let waiters = pendingSeededRootVisibilityWaitersByPath.removeValue(forKey: path) ?? [:]
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func cancelRootUnloadWaiter(standardizedPath: String, waiterID: UUID) {
        guard let waiter = unloadWaitersByRootPath[standardizedPath]?.removeValue(forKey: waiterID) else { return }
        if unloadWaitersByRootPath[standardizedPath]?.isEmpty == true {
            unloadWaitersByRootPath.removeValue(forKey: standardizedPath)
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finishRootUnload(for standardizedPaths: [String]) {
        for path in standardizedPaths {
            unloadingRootPaths.remove(path)
            let waiters = unloadWaitersByRootPath.removeValue(forKey: path) ?? [:]
            for waiter in waiters.values {
                waiter.resume()
            }
        }
    }

    func unloadRoot(id rootID: UUID) async {
        await unloadRoots(ids: [rootID])
    }

    func unloadRoots(ids rootIDs: [UUID]) async {
        var seenRootIDs = Set<UUID>()
        let orderedRootIDs = rootIDs.filter { seenRootIDs.insert($0).inserted }
        guard !orderedRootIDs.isEmpty else { return }

        var statesToUnload: [(rootID: UUID, state: RootState, pageIndex: FileTreePageIndex?)] = []
        var codemapCleanupFlights: [CodemapCleanupFlight] = []
        var codemapCleanupIDs = Set<UUID>()
        var seededAuthorityFencesToRelease: [GitWorkspacePendingInitializationAuthorityFence] = []
        var seededAuthorityClaimsToRelease: [WorkspaceRootSeedServingAuthorityClaim] = []
        var ownershipResourcesReleasedByUnload = SessionWorktreeOwnershipRemoval()
        var invalidatedOwnershipTokens = Set<WorkspaceSessionWorktreeOwnershipToken>()
        for rootID in orderedRootIDs {
            if let claim = publishedSeededAuthorityClaimsByRootID.removeValue(forKey: rootID) {
                seededAuthorityClaimsToRelease.append(claim)
                publishedSeededAuthorityFencesByRootID.removeValue(forKey: rootID)
            } else if let fence = publishedSeededAuthorityFencesByRootID.removeValue(forKey: rootID) {
                seededAuthorityFencesToRelease.append(fence)
            }
            publishedSeededAuthorityStatesByRootID.removeValue(forKey: rootID)
            let unavailablePath = rootStatesByID[rootID]?.root.standardizedFullPath ?? rootID.uuidString
            resumePublishedSeededAuthorityWaiters(
                rootID: rootID,
                error: WorkspaceSessionWorktreeOwnershipError.unavailableRoot(unavailablePath)
            )
            seededAuthorityPendingGenerationByRootID.removeValue(forKey: rootID)
            seededAuthorityReconciliationTasksByRootID.removeValue(forKey: rootID)?.cancel()
            explicitWatcherDemandRootIDs.remove(rootID)
            if let state = rootStatesByID[rootID] {
                let watcherKey = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
                explicitWatcherDemandGenerationByKey.removeValue(forKey: watcherKey)
            }
            if let state = rootStatesByID[rootID], state.root.kind == .sessionWorktree {
                let lifetimeKey = SessionWorktreeRootLifetimeKey(rootID: rootID, lifetimeID: state.lifetimeID)
                let ownershipTokens = (sessionWorktreeOwnershipTokensByRootLifetime[lifetimeKey] ?? [])
                    .union(sessionWorktreeReservationTokensByStandardizedPath[state.root.standardizedFullPath] ?? [])
                for token in ownershipTokens where invalidatedOwnershipTokens.insert(token).inserted {
                    latestSessionWorktreeOwnershipGenerationByOwnerID[token.ownerID, default: 0] &+= 1
                    if installedSessionWorktreeOwnershipTokenByOwnerID[token.ownerID] == token {
                        installedSessionWorktreeOwnershipTokenByOwnerID.removeValue(forKey: token.ownerID)
                    }
                    ownershipResourcesReleasedByUnload.append(removeSessionWorktreeOwnershipToken(token))
                }
            }
            if let flightState = scopedIngressBarrierFlightStatesByRootID.removeValue(forKey: rootID) {
                flightState.active?.task?.cancel()
                flightState.active?.join.complete(with: nil)
                flightState.pending?.join.complete(with: nil)
            }
            completedScopedIngressBarrierCutsByRootID.removeValue(forKey: rootID)
            if let state = rootStatesByID[rootID] {
                let watcherKey = WatcherInfrastructureKey(rootID: rootID, lifetimeID: state.lifetimeID)
                watcherPublisherAttachmentsByKey.removeValue(forKey: watcherKey)?.cancellable.cancel()
                watcherInfrastructureFlightsByKey.removeValue(forKey: watcherKey)?.task.cancel()
            }
            publisherIngressCoordinator.closePublisherIngress(rootID: rootID)
            if rootStatesByID[rootID]?.root.kind == .sessionWorktree {
                sessionRootLifetimeClock.advance()
            }
            guard let state = rootStatesByID.removeValue(forKey: rootID) else { continue }
            // P4-6b table-deletion conversion: the root's file ids (needed below to clean up
            // `searchContentInvalidationEpochsByFileID`) must be paged from Rust *before*
            // `closeRoot` below -- once closed, the authority can no longer serve reads for this
            // root. `RootState`'s own path maps are permanently empty post-cutover and can no
            // longer supply this list.
            let unloadingPageIndex = await fetchFileTreePageIndex(rootID: rootID)
            if let inventoryScopeAuthority {
                await inventoryScopeAuthority.closeRoot(rootID: rootID)
            }
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: rootID,
                rootLifetimeID: state.lifetimeID
            )
            codemapRootMutationFenceTokensByRootEpoch.removeValue(forKey: rootEpoch)
            let rootMutationWaiters = codemapRootMutationFenceWaitersByRootEpoch.removeValue(
                forKey: rootEpoch
            ) ?? [:]
            for continuation in rootMutationWaiters.values {
                continuation.resume()
            }
            let pathQuiescenceWaiters = codemapPathQuiescenceWaitersByRootEpoch.removeValue(
                forKey: rootEpoch
            ) ?? [:]
            for continuation in pathQuiescenceWaiters.values {
                continuation.resume()
            }
            codemapGraphIndexBuildReschedulePendingRootEpochs.remove(rootEpoch)
            codemapSuspendedRootEpochs.remove(rootEpoch)
            codemapResumeTransitionIDsByRootEpoch.removeValue(forKey: rootEpoch)
            codemapGraphAccountingByRootEpoch.removeValue(forKey: rootEpoch)
            codemapGraphIndexWorkerRecoveryExhaustedRootEpochs.remove(rootEpoch)
            codemapRootStatusCoverageBaselinesByRootEpoch.removeValue(forKey: rootEpoch)
            publishCodemapRootStatusesIfChanged()
            if let cleanup = detachCodemapSession(
                rootEpoch: rootEpoch,
                invalidationCommands: [.unload],
                graphInvalidationReason: .rootUnloaded
            ),
                codemapCleanupIDs.insert(cleanup.id).inserted
            {
                codemapCleanupFlights.append(cleanup)
            }
            codemapAuthorityGenerationsByRootEpoch.removeValue(forKey: rootEpoch)
            codemapGraphIndexInvalidationGenerationsByRootEpoch.removeValue(forKey: rootEpoch)
            terminalNonGitCodemapCacheByEpoch.removeValue(forKey: rootEpoch)
            let pathFenceTokenIDs = codemapPathFenceTokensByID.compactMap { entry in
                entry.value.rootEpoch == rootEpoch ? entry.key : nil
            }
            for tokenID in pathFenceTokenIDs {
                removeCodemapPathFenceToken(id: tokenID)
            }
            statesToUnload.append((rootID, state, unloadingPageIndex))
        }
        for claim in seededAuthorityClaimsToRelease {
            await claim.release()
        }
        for fence in seededAuthorityFencesToRelease {
            await worktreeSeedGitService.releasePendingInitializationAuthorityFence(fence)
        }
        guard !statesToUnload.isEmpty else { return }
        invalidatePathMatchSnapshot(
            affectedRootKinds: Set(statesToUnload.map(\.state.root.kind)),
            reason: .rootUnload,
            affectedRootIDs: Set(statesToUnload.map(\.rootID))
        )
        for entry in statesToUnload {
            for fileID in entry.pageIndex.map({ Array($0.filesByID.keys) }) ?? [] {
                searchContentInvalidationEpochsByFileID.removeValue(forKey: fileID)
            }
            removeSliceRebaseSources(rootID: entry.rootID, rootLifetimeID: entry.state.lifetimeID)
            await searchDecodedContentCache.invalidate(rootID: entry.rootID)
            await interactiveReadCache.invalidate(rootID: entry.rootID)
        }
        #if DEBUG
            let rootUnloadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let rootUnloadFileCount = statesToUnload.reduce(0) { $0 + ($1.pageIndex?.filesByID.count ?? 0) }
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.begin",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "fileCount": "\(rootUnloadFileCount)"
                ]
            )
            let detachStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif

        let unloadingPaths = statesToUnload.map(\.state.root.standardizedFullPath)
        for path in unloadingPaths {
            unloadingRootPaths.insert(path)
        }
        #if DEBUG
            if let rootUnloadDidDetachHandler {
                await rootUnloadDidDetachHandler(unloadingPaths)
            }
        #endif

        let removedRootIDSet = Set(statesToUnload.map(\.rootID))
        rootLoadOrder.removeAll { removedRootIDSet.contains($0) }
        for entry in statesToUnload {
            rootIDsByStandardizedPath.removeValue(forKey: entry.state.root.standardizedFullPath)
            rootLoadConfigurationsByPath.removeValue(forKey: entry.state.root.standardizedFullPath)
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.detach",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": detachStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let stopWatchersStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif

        // Stop each detached service exactly once. The caller only waits through a bounded
        // completion latch; cancellation cannot interrupt synchronous FSEvents flush work.
        let detachedWatcherStops = startDetachedWatcherStops(statesToUnload.map { ($0.rootID, $0.state) })
        #if DEBUG
            if publisherIngressCoordinator.pendingPublisherIngressCount(rootIDs: removedRootIDSet) > 0,
               let publisherIngressWillWaitHandler
            {
                await publisherIngressWillWaitHandler(removedRootIDSet)
            }
        #endif
        let removedRootIDsInOrder = statesToUnload.map(\.rootID)
        async let publisherIngressReports = publisherIngressCoordinator.terminateClosedPublisherIngress(
            rootIDs: removedRootIDsInOrder,
            gracefulDrainTimeoutNanoseconds: unloadTerminationPolicy.publisherIngressGraceNanoseconds,
            sleep: unloadTerminationPolicy.sleep
        )
        let watcherStopReports = await awaitDetachedWatcherStops(detachedWatcherStops)
        let resolvedPublisherIngressReports = await publisherIngressReports
        let terminationDiagnostics = WorkspaceRootUnloadTerminationDiagnostics(
            publisherIngressReports: resolvedPublisherIngressReports,
            watcherStopReports: watcherStopReports
        )
        WorkspaceRootUnloadDiagnosticsLog.record(terminationDiagnostics)
        #if DEBUG
            if let rootUnloadTerminationDidCompleteHandler {
                await rootUnloadTerminationDidCompleteHandler(terminationDiagnostics)
            }
        #endif
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.stopWatchers",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": stopWatchersStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let indexCleanupStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif

        // P4-6b table-deletion conversion: this root's discoverable file/folder ids+paths (for
        // the emitted unload event) and the "forget this id was managed-only" cleanup now come
        // from the pre-close paged snapshot (`entry.pageIndex`, captured above before `closeRoot`)
        // instead of the deleted global tables / `RootState`'s path maps. `managedOnlyFileIDs`/
        // `managedOnlyFolderIDs` remain a genuine Swift-local mirror (contract doc's own framing),
        // so removing entries from them here is still correct and necessary.
        for entry in statesToUnload {
            let rootID = entry.rootID
            let state = entry.state
            let allFiles = entry.pageIndex.map { Array($0.filesByID.values) } ?? []
            let allFolders = entry.pageIndex.map { Array($0.foldersByID.values) } ?? []
            let discoverableFiles = allFiles.filter { isDiscoverableFileID($0.id) }
            let discoverableFolders = allFolders.filter { isDiscoverableFolderID($0.id) }
            for folder in allFolders {
                managedOnlyFolderIDs.remove(folder.id)
            }
            for file in allFiles {
                managedOnlyFileIDs.remove(file.id)
            }
            let generation = nextAppliedIndexGeneration(forRootID: rootID)
            await yieldAppliedIndexEvent(WorkspaceAppliedIndexBatchEvent(
                rootID: rootID,
                rootPath: state.root.standardizedFullPath,
                generation: generation,
                rootLifetimeID: state.lifetimeID,
                removedFileIDs: discoverableFiles.map(\.id),
                removedFolderIDs: discoverableFolders.map(\.id),
                removedFilePaths: discoverableFiles.map(\.standardizedRelativePath).sorted(),
                removedFolderPaths: discoverableFolders.map(\.standardizedRelativePath).sorted(),
                requiresFullResync: true,
                isRootUnload: true
            ))
            appliedIndexGenerationsByRootID.removeValue(forKey: rootID)
            catalogGenerationsByRootID.removeValue(forKey: rootID)
            #if DEBUG
                publicationInvalidationHistoryByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierLaunchCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierJoinCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierSuccessorCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierCoalescedSuccessorCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierCompletionCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierNoopCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierTotalWaitMillisecondsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierMaxWaitMillisecondsByRootID.removeValue(forKey: rootID)
                lastCompletedScopedIngressBarrierByRootID.removeValue(forKey: rootID)
                rootCrawlCountsByRootID.removeValue(forKey: rootID)
            #endif
        }

        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.indexCleanup",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "removedFiles": "\(rootUnloadFileCount)",
                    "duration": indexCleanupStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        for cleanup in codemapCleanupFlights {
            await cleanup.task.value
        }
        finishRootUnload(for: unloadingPaths)
        let removedLifetimeKeys = Set(statesToUnload.map {
            SessionWorktreeRootLifetimeKey(rootID: $0.rootID, lifetimeID: $0.state.lifetimeID)
        })
        let removedStandardizedPaths = Set(statesToUnload.map(\.state.root.standardizedFullPath))
        await cleanupOrphanedSessionWorktreeResources(SessionWorktreeOwnershipRemoval(
            ownedRoots: ownershipResourcesReleasedByUnload.ownedRoots.filter {
                !removedLifetimeKeys.contains(
                    SessionWorktreeRootLifetimeKey(rootID: $0.rootID, lifetimeID: $0.lifetimeID)
                )
            },
            reservedLoadFlights: ownershipResourcesReleasedByUnload.reservedLoadFlights.filter {
                !removedStandardizedPaths.contains($0.standardizedPath)
            }
        ))
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.end",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": rootUnloadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    private func startDetachedWatcherStops(
        _ statesToUnload: [(rootID: UUID, state: RootState)]
    ) -> [DetachedWatcherStop] {
        statesToUnload.enumerated().map { index, entry in
            let completionLatch = WorkspaceRootUnloadCompletionLatch()
            let service = entry.state.service
            #if DEBUG
                let watcherStopWillBeginHandler = watcherStopWillBeginHandler
            #endif
            let task = Task.detached {
                #if DEBUG
                    if let watcherStopWillBeginHandler {
                        await watcherStopWillBeginHandler(entry.rootID)
                    }
                #endif
                await service.stopWatchingForChanges()
                completionLatch.complete()
            }
            return DetachedWatcherStop(
                index: index,
                rootID: entry.rootID,
                rootPath: entry.state.root.standardizedFullPath,
                completionLatch: completionLatch,
                task: task
            )
        }
    }

    private func awaitDetachedWatcherStops(
        _ stops: [DetachedWatcherStop]
    ) async -> [WorkspaceRootWatcherStopReport] {
        await withTaskGroup(of: (Int, WorkspaceRootWatcherStopReport).self) { group in
            for stop in stops {
                group.addTask { [unloadTerminationPolicy] in
                    let outcome = await WorkspaceRootUnloadBoundedWait.waitForCompletion(
                        stop.completionLatch,
                        timeoutNanoseconds: unloadTerminationPolicy.watcherStopGraceNanoseconds,
                        sleep: unloadTerminationPolicy.sleep
                    )
                    if outcome != .completed {
                        stop.task.cancel()
                    }
                    return (
                        stop.index,
                        WorkspaceRootWatcherStopReport(
                            rootID: stop.rootID,
                            rootPath: stop.rootPath,
                            outcome: outcome,
                            graceNanoseconds: unloadTerminationPolicy.watcherStopGraceNanoseconds
                        )
                    )
                }
            }
            var reports: [(Int, WorkspaceRootWatcherStopReport)] = []
            for await report in group {
                reports.append(report)
            }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // P4-6b: routes through the Rust authority's path-keyed fact lookup (B3, contract doc §5.3).
    // D-13 (see `inventoryRecordFacts`'s doc comment for the full reasoning): the fact wire
    // carries only standardized paths, so the reconstructed record's raw `.relativePath`/
    // `.fullPath` hold the standardized string, not the true original raw string.
    //
    // P4-6b item 1 fix (`docs/architecture/rust-inventory-scope-v1.md` §12.3): `fact.parentFolderID`
    // is Rust's convention (root-marker excluded -- a top-level item's parent is genuinely `nil`
    // there, per the contract doc §4's "instance-identity" note and the republication adapter's own
    // `denormalizedParentFolderID` doc comment). Swift's own record convention self-references the
    // root (`parentFolderID == rootID`) for a top-level item instead. Passing `fact.parentFolderID`
    // straight through (as this used to) silently produced a record whose `parentFolderID` disagreed
    // with the same file/folder's Rust-round-tripped reconstruction elsewhere (e.g.
    // `WorkspaceInventoryScopeRepublicationAdapter.workspaceFileRecord(_:)`, which does denormalize),
    // making `buildRootCatalogShardPatch`'s upserted-record equality guard
    // (`WorkspaceInventoryCatalogBuilders.swift`) fail on every top-level upsert and fall back to
    // `.patchApplicationBackstop` -- not a `modificationDate` round-trip precision loss, the leading
    // hypothesis recorded when this was quarantined turned out to be wrong.
    func file(rootID: UUID, relativePath: String) async -> WorkspaceFileRecord? {
        guard let authority = try? await inventoryScopeAuthorityInstance(),
              let result = try? await authority.lookupPaths(rootID: rootID, relativePaths: [StandardizedPath.relative(relativePath)]),
              let fact = result.factsByPath[StandardizedPath.relative(relativePath)], fact.exists,
              let fileID = fact.fileID, let factRootID = fact.rootID,
              let stdRel = fact.standardizedRelativePath, let stdFull = fact.standardizedFullPath,
              let name = fact.name
        else { return nil }
        return WorkspaceFileRecord(
            id: fileID, rootID: factRootID, name: name,
            relativePath: stdRel, fullPath: stdFull,
            parentFolderID: WorkspaceInventoryScopeRepublicationAdapter.denormalizedParentFolderID(
                fact.parentFolderID, rootID: factRootID
            ),
            modificationDate: fact.modificationDate
        )
    }

    // Item 0 fix (P4-7b tail, P4-6b regression): the root's own self-referencing folder marker
    // (id == rootID, relativePath == "") is never sent to Rust (root-marker exclusion, matching
    // `rootFolderRecord(rootID:)`/`buildStaticSnapshot`'s synthesis) -- pre-P4-6b,
    // `state.folderIDsByRelativePath` always carried this marker under the "" key, so this general
    // accessor must still answer it rather than falling through to a Rust lookup that always misses.
    func folder(rootID: UUID, relativePath: String) async -> WorkspaceFolderRecord? {
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        if standardizedRelativePath.isEmpty {
            return rootFolderRecord(rootID: rootID)
        }
        guard let authority = try? await inventoryScopeAuthorityInstance(),
              let result = try? await authority.lookupPaths(rootID: rootID, relativePaths: [StandardizedPath.relative(relativePath)]),
              let fact = result.factsByPath[StandardizedPath.relative(relativePath)], fact.exists,
              let folderID = fact.folderID, let factRootID = fact.rootID,
              let stdRel = fact.standardizedRelativePath, let stdFull = fact.standardizedFullPath,
              let name = fact.name
        else { return nil }
        return WorkspaceFolderRecord(
            id: folderID, rootID: factRootID, name: name,
            relativePath: stdRel, fullPath: stdFull,
            parentFolderID: WorkspaceInventoryScopeRepublicationAdapter.denormalizedParentFolderID(
                fact.parentFolderID, rootID: factRootID
            ),
            modificationDate: fact.modificationDate
        )
    }

    func cachedSearchContentSnapshot(
        for expectedRecord: WorkspaceFileRecord
    ) async -> FileSearchContentSnapshot {
        guard publishedSeededAuthorityIsQueryable(rootID: expectedRecord.rootID) else {
            return staleSearchContentSnapshot(for: expectedRecord)
        }
        guard let current = await file(
            rootID: expectedRecord.rootID,
            relativePath: expectedRecord.standardizedRelativePath
        ), current.id == expectedRecord.id else {
            return staleSearchContentSnapshot(for: expectedRecord)
        }
        let epoch = searchContentInvalidationEpochsByFileID[current.id] ?? 0
        let cacheKey = WorkspaceSearchContentCacheKey(
            rootID: current.rootID,
            fileID: current.id,
            standardizedRelativePath: current.standardizedRelativePath
        )
        guard let cached = await searchDecodedContentCache.cachedSnapshot(
            for: cacheKey,
            invalidationEpoch: epoch
        ), await searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
            return staleSearchContentSnapshot(for: current)
        }
        if let state = rootStatesByID[current.rootID] {
            await retainSliceRebaseSource(
                content: cached.content,
                modificationDate: cached.modificationDate,
                file: current,
                rootLifetimeID: state.lifetimeID
            )
        }
        return FileSearchContentSnapshot(
            content: cached.content,
            contentRevision: cached.revision,
            modificationDate: cached.modificationDate,
            isFresh: true
        )
    }

    func searchContentSnapshot(
        for expectedRecord: WorkspaceFileRecord,
        freshnessPolicy: FileContentFreshnessPolicy = .validateDiskMetadata
    ) async throws -> FileSearchContentSnapshot {
        try await requirePublishedSeededAuthorityFresh(rootID: expectedRecord.rootID)
        for attempt in 0 ..< 2 {
            try Task.checkCancellation()
            guard let state = rootStatesByID[expectedRecord.rootID],
                  let current = await file(rootID: expectedRecord.rootID, relativePath: expectedRecord.standardizedRelativePath),
                  current.id == expectedRecord.id
            else {
                return staleSearchContentSnapshot(for: expectedRecord)
            }

            let service = state.service
            let epoch = searchContentInvalidationEpochsByFileID[current.id] ?? 0
            let cacheKey = WorkspaceSearchContentCacheKey(
                rootID: current.rootID,
                fileID: current.id,
                standardizedRelativePath: current.standardizedRelativePath
            )
            if case .cachedMetadata = freshnessPolicy,
               let cached = await searchDecodedContentCache.cachedSnapshot(
                   for: cacheKey,
                   invalidationEpoch: epoch
               )
            {
                guard await searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                    if attempt == 0 { continue }
                    return staleSearchContentSnapshot(for: current)
                }
                await retainSliceRebaseSource(
                    content: cached.content,
                    modificationDate: cached.modificationDate,
                    file: current,
                    rootLifetimeID: state.lifetimeID
                )
                try await requirePublishedSeededAuthorityFresh(rootID: current.rootID)
                return FileSearchContentSnapshot(
                    content: cached.content,
                    contentRevision: cached.revision,
                    modificationDate: cached.modificationDate,
                    isFresh: true
                )
            }
            let fingerprint: FileContentFingerprint
            do {
                fingerprint = try await service.contentFingerprint(
                    ofRelativePath: current.standardizedRelativePath
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch FileSystemError.fileNotFound {
                await pruneCatalogFileIfStillCurrent(current)
                return staleSearchContentSnapshot(for: current)
            } catch {
                return staleSearchContentSnapshot(for: current)
            }

            guard await searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                if attempt == 0 { continue }
                return staleSearchContentSnapshot(for: current)
            }

            let schedulerOwnerID = searchContentSchedulerOwnerID
            do {
                let cached = try await searchDecodedContentCache.snapshot(
                    for: cacheKey,
                    fingerprint: fingerprint,
                    invalidationEpoch: epoch
                ) {
                    try await service.loadValidatedContent(
                        ofRelativePath: current.standardizedRelativePath,
                        expectedFingerprint: fingerprint,
                        workloadClass: .contentSearch,
                        schedulerOwnerID: schedulerOwnerID
                    )
                }
                guard let cached else {
                    if attempt == 0 { continue }
                    return staleSearchContentSnapshot(for: current)
                }
                guard await searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                    if attempt == 0 { continue }
                    return staleSearchContentSnapshot(for: current)
                }
                await retainSliceRebaseSource(
                    content: cached.content,
                    modificationDate: cached.modificationDate,
                    file: current,
                    rootLifetimeID: state.lifetimeID
                )
                try await requirePublishedSeededAuthorityFresh(rootID: current.rootID)
                return FileSearchContentSnapshot(
                    content: cached.content,
                    contentRevision: cached.revision,
                    modificationDate: cached.modificationDate,
                    isFresh: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ContentReadSchedulerError {
                throw error
            } catch FileContentValidationError.fingerprintChanged {
                if attempt == 0 { continue }
                return staleSearchContentSnapshot(for: current)
            } catch FileSystemError.fileNotFound {
                await pruneCatalogFileIfStillCurrent(current)
                return staleSearchContentSnapshot(for: current)
            } catch {
                return staleSearchContentSnapshot(for: current)
            }
        }
        return staleSearchContentSnapshot(for: expectedRecord)
    }

    func interactiveReadSnapshot(
        for expectedRecord: WorkspaceFileRecord
    ) async throws -> WorkspaceInteractiveReadSnapshot? {
        try await FileSystemService.withContentReadForegroundActivity(kind: .interactiveRead) {
            try await self.interactiveReadSnapshotWithinForegroundActivity(for: expectedRecord)
        }
    }

    private func interactiveReadSnapshotWithinForegroundActivity(
        for expectedRecord: WorkspaceFileRecord
    ) async throws -> WorkspaceInteractiveReadSnapshot? {
        try await requirePublishedSeededAuthorityFresh(rootID: expectedRecord.rootID)
        for attempt in 0 ..< 2 {
            try Task.checkCancellation()
            guard let state = rootStatesByID[expectedRecord.rootID],
                  let current = await file(
                      rootID: expectedRecord.rootID,
                      relativePath: expectedRecord.standardizedRelativePath
                  ),
                  current.id == expectedRecord.id
            else {
                return nil
            }

            let service = state.service
            let epoch = searchContentInvalidationEpochsByFileID[current.id] ?? 0
            let cacheKey = WorkspaceInteractiveReadCacheKey(
                rootID: current.rootID,
                rootLifetimeID: state.lifetimeID,
                fileID: current.id,
                standardizedRelativePath: current.standardizedRelativePath
            )
            let fingerprint: FileContentFingerprint
            do {
                fingerprint = try await service.contentFingerprint(
                    ofRelativePath: current.standardizedRelativePath
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch FileSystemError.fileNotFound {
                await pruneCatalogFileIfStillCurrent(current)
                return nil
            } catch {
                return nil
            }

            guard await searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                if attempt == 0 { continue }
                return nil
            }

            let schedulerOwnerID = interactiveReadSchedulerOwnerID
            do {
                let cached = try await interactiveReadCache.snapshot(
                    for: cacheKey,
                    fingerprint: fingerprint,
                    invalidationEpoch: epoch
                ) {
                    let loaded = try await service.loadValidatedContent(
                        ofRelativePath: current.standardizedRelativePath,
                        expectedFingerprint: fingerprint,
                        workloadClass: .interactiveRead,
                        schedulerOwnerID: schedulerOwnerID
                    )
                    guard let content = loaded.content else { return nil }
                    return await WorkspaceInteractiveReadProcessor.prepareOffActor(content)
                }
                guard let preparedContent = cached.preparedContent else {
                    if attempt == 0 { continue }
                    return nil
                }
                guard await searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                    if attempt == 0 { continue }
                    return nil
                }
                await retainSliceRebaseSource(
                    content: preparedContent.linesWithEndings.joined(),
                    modificationDate: fingerprint.modificationDate,
                    file: current,
                    rootLifetimeID: state.lifetimeID
                )
                try await requirePublishedSeededAuthorityFresh(rootID: current.rootID)
                return WorkspaceInteractiveReadSnapshot(
                    preparedContent: preparedContent,
                    cacheHit: cached.cacheHit
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ContentReadSchedulerError {
                throw error
            } catch FileContentValidationError.fingerprintChanged {
                if attempt == 0 { continue }
                return nil
            } catch FileSystemError.fileNotFound {
                await pruneCatalogFileIfStillCurrent(current)
                return nil
            } catch {
                return nil
            }
        }
        return nil
    }

    func clearSearchDecodedContentCache() async {
        await searchDecodedContentCache.clear()
        await interactiveReadCache.clear()
        clearSliceRebaseSources()
    }

    func readContentPrefix(
        rootID: UUID,
        relativePath: String,
        maximumBytes: Int,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> FileContentPrefix? {
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        let state = try state(for: rootID)
        let result = try await state.service.loadContentPrefix(
            ofRelativePath: StandardizedPath.relative(relativePath),
            maximumBytes: maximumBytes,
            workloadClass: workloadClass
        )
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        return result
    }

    func readContent(
        rootID: UUID,
        relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> String? {
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        let state = try state(for: rootID)
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.ReadFile.storeReadContentEntered,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                workloadClass: workloadClass.rawValue,
                rootToken: state.service.diagnosticRootToken.uuidString
            )
        )
        let forwardState = EditFlowPerf.begin(
            EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue)
        )
        do {
            let content = try await state.service.loadContent(
                ofRelativePath: StandardizedPath.relative(relativePath),
                workloadClass: workloadClass
            )
            try await requirePublishedSeededAuthorityFresh(rootID: rootID)
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: "returned", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: "returned",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            return content
        } catch {
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: error is CancellationError ? "cancelled" : "error", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: error is CancellationError ? "cancelled" : "error",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            throw error
        }
    }

    func readValidatedContentSnapshot(
        rootID: UUID,
        relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> ValidatedFileContentSnapshot {
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let fingerprint = try await state.service.contentFingerprint(ofRelativePath: standardizedRelativePath)
        let result = try await state.service.loadValidatedContent(
            ofRelativePath: standardizedRelativePath,
            expectedFingerprint: fingerprint,
            workloadClass: workloadClass
        )
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        return result
    }

    func readContentWithDate(
        rootID: UUID,
        relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> (content: String?, modificationDate: Date) {
        try await requirePublishedSeededAuthorityFresh(rootID: rootID)
        let state = try state(for: rootID)
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.ReadFile.storeReadContentEntered,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                workloadClass: workloadClass.rawValue,
                rootToken: state.service.diagnosticRootToken.uuidString
            )
        )
        let forwardState = EditFlowPerf.begin(
            EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue)
        )
        do {
            let loaded = try await state.service.loadContentWithDate(
                ofRelativePath: StandardizedPath.relative(relativePath),
                workloadClass: workloadClass
            )
            try await requirePublishedSeededAuthorityFresh(rootID: rootID)
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: "returned", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: "returned",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            return loaded
        } catch {
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: error is CancellationError ? "cancelled" : "error", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: error is CancellationError ? "cancelled" : "error",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            throw error
        }
    }

    func fileExistsOnDisk(rootID: UUID, relativePath: String) async throws -> Bool {
        let state = try state(for: rootID)
        return await state.service.fileExistsOnDisk(relativePath: StandardizedPath.relative(relativePath))
    }

    func fileModificationDate(rootID: UUID, relativePath: String) async throws -> Date {
        let state = try state(for: rootID)
        return try await state.service.getFileModificationDate(atRelativePath: StandardizedPath.relative(relativePath))
    }

    func itemModificationDateIfAvailable(rootID: UUID, relativePath: String) async throws -> Date? {
        let state = try state(for: rootID)
        return await state.service.getItemModificationDateIfAvailable(atRelativePath: StandardizedPath.relative(relativePath))
    }

    func refreshIgnoreRules(rootID: UUID) async throws {
        let state = try state(for: rootID)
        try await state.service.refreshIgnoreRules()
    }

    func fullPath(rootID: UUID, relativePath: String) async -> String? {
        guard let state = rootStatesByID[rootID] else { return nil }
        return await state.service.fullPath(forRelativePath: StandardizedPath.relative(relativePath))
    }

    /// P4-6a / B1 site 1 (id-keyed, sync). One batched `inventoryRecordFacts` call
    /// before the scan, replacing per-item `filesByID` / discoverability / path
    /// round-trip reads. Named test:
    /// `testCodemapAutomaticSelectionSourceIdentitiesSkipsManagedOnlyFiles`.
    func codemapAutomaticSelectionSourceIdentities(
        forFileIDs sourceFileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope
    ) async -> [WorkspaceCodemapAutomaticSelectionSourceIdentity] {
        let allowedRootIDs = Set(rootsForPathLookup(scope: rootScope).map(\.id))
        let facts = await inventoryRecordFacts(fileIDs: sourceFileIDs, folderIDs: []).filesByID
        var seenFileIDs = Set<UUID>()
        return sourceFileIDs.compactMap { fileID in
            guard seenFileIDs.insert(fileID).inserted,
                  let fact = facts[fileID],
                  let file = fact.record,
                  allowedRootIDs.contains(file.rootID),
                  fact.isDiscoverable,
                  let state = rootStatesByID[file.rootID],
                  fact.pathRoundTripsToSelf,
                  catalogGenerationsByRootID[file.rootID] != nil
            else { return nil }
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: file.rootID,
                rootLifetimeID: state.lifetimeID
            )
            guard let session = codemapSessionsByRootEpoch[rootEpoch],
                  codemapAuthorityIsCurrent(session.authority)
            else { return nil }
            let requestGeneration = session.pathGenerationsByRelativePath[file.standardizedRelativePath]
                ?? session.authority.ingressGeneration
            return WorkspaceCodemapAutomaticSelectionSourceIdentity(
                rootEpoch: rootEpoch,
                fileID: fileID,
                catalogGeneration: session.authority.catalogGeneration,
                requestGeneration: requestGeneration
            )
        }
    }

    func codemapOperationPresentationCandidates(
        forFileIDs fileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:],
        includeCompleteRootCatalogs: Bool = false
    ) async -> WorkspaceCodemapOperationCandidateCollection {
        #if DEBUG
            codemapPresentationCandidateRequestCountForTesting += 1
        #endif
        let scopedRoots = rootsForPathLookup(scope: rootScope)
        let allowedRootIDs = Set(scopedRoots.map(\.id))
        let defaultRootLabels = WorkspaceLogicalRootIdentity.labels(for: scopedRoots.compactMap { root in
            guard let state = rootStatesByID[root.id] else { return nil }
            return WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: root.id,
                rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: root.id,
                    rootLifetimeID: state.lifetimeID
                ),
                preferredName: root.name
            )
        })
        let effectiveRootLabels = defaultRootLabels.merging(logicalRootDisplayNamesByRootID) {
            _, supplied in supplied
        }
        // P4-6a / B1 site 2 (id-keyed, sync, per-clause failure attribution). One
        // batched `inventoryRecordFacts` call before the scan. Named test:
        // `testCodemapOperationPresentationCandidatesServesManagedOnlyFile`.
        let facts = await inventoryRecordFacts(fileIDs: fileIDs, folderIDs: []).filesByID
        var seenFileIDs = Set<UUID>()
        var candidates: [WorkspaceCodemapOperationPresentationCandidate] = []
        var issues: [WorkspaceCodemapOperationCandidateIssue] = []

        for fileID in fileIDs where seenFileIDs.insert(fileID).inserted {
            guard let fact = facts[fileID], let file = fact.record, fact.isDiscoverable else {
                issues.append(.fileNotCataloged(fileID))
                continue
            }
            guard allowedRootIDs.contains(file.rootID) else {
                issues.append(.fileOutsideRootScope(fileID))
                continue
            }
            guard let state = rootStatesByID[file.rootID],
                  fact.pathRoundTripsToSelf,
                  let catalogGeneration = catalogGenerationsByRootID[file.rootID]
            else {
                issues.append(.fileNotCataloged(fileID))
                continue
            }
            guard let logicalPath = WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: effectiveRootLabels[file.rootID] ?? state.root.name,
                standardizedRelativePath: file.standardizedRelativePath
            ) else {
                issues.append(.logicalPathUnavailable(fileID))
                continue
            }
            candidates.append(WorkspaceCodemapOperationPresentationCandidate(
                fileID: fileID,
                rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: file.rootID,
                    rootLifetimeID: state.lifetimeID
                ),
                catalogGeneration: catalogGeneration,
                logicalPath: logicalPath
            ))
        }

        candidates.sort {
            if $0.logicalPath.displayPath != $1.logicalPath.displayPath {
                return $0.logicalPath.displayPath.utf8.lexicographicallyPrecedes(
                    $1.logicalPath.displayPath.utf8
                )
            }
            return $0.fileID.uuidString < $1.fileID.uuidString
        }
        var completeRootCatalogs: [WorkspaceCodemapOperationCompleteRootCatalogReceipt] = []
        if includeCompleteRootCatalogs {
            // Same site (4th occurrence): one batched `inventoryRecordFacts` call per
            // root scan, replacing the per-file `isDiscoverableFileID` / `filesByID`
            // read inside `.filter`. Manual loop, not `.compactMap`, because the
            // per-root call is now `async` -- `Array.compactMap`'s closure does not
            // support `await`; the loop is otherwise behavior-identical (same per-root
            // call, same guard, same filter/sort).
            for root in rootsForPathLookup(scope: rootScope) {
                guard let state = rootStatesByID[root.id],
                      let catalogGeneration = catalogGenerationsByRootID[root.id]
                else { continue }
                let rootFileIDs = Array(state.fileIDsByRelativePath.values)
                let rootFacts = await inventoryRecordFacts(fileIDs: rootFileIDs, folderIDs: []).filesByID
                let supportedFileIDs = rootFileIDs.filter { fileID in
                    guard let fact = rootFacts[fileID], fact.isDiscoverable, let file = fact.record else { return false }
                    let fileExtension = (file.name as NSString).pathExtension
                    return SyntaxManager.supportsCodeMap(fileExtension: fileExtension)
                }.sorted { $0.uuidString < $1.uuidString }
                completeRootCatalogs.append(WorkspaceCodemapOperationCompleteRootCatalogReceipt(
                    rootEpoch: WorkspaceCodemapRootEpoch(
                        rootID: root.id,
                        rootLifetimeID: state.lifetimeID
                    ),
                    catalogGeneration: catalogGeneration,
                    supportedFileIDs: supportedFileIDs
                ))
            }
            completeRootCatalogs.sort { codemapRootEpochPrecedes($0.rootEpoch, $1.rootEpoch) }
            let requestedCandidateIDs = Set(candidates.map(\.fileID))
            let missingFileIDs = completeRootCatalogs.flatMap(\.supportedFileIDs)
                .filter { !requestedCandidateIDs.contains($0) }
            if !missingFileIDs.isEmpty {
                issues.append(.incompleteRootSet(missingFileIDs: missingFileIDs))
            }
        }
        issues.sort { candidateIssueSortKey($0) < candidateIssueSortKey($1) }
        return WorkspaceCodemapOperationCandidateCollection(
            candidates: candidates,
            issues: issues,
            completeRootCatalogs: completeRootCatalogs
        )
    }

    private func candidateIssueSortKey(
        _ issue: WorkspaceCodemapOperationCandidateIssue
    ) -> String {
        switch issue {
        case let .fileNotCataloged(fileID):
            "0:file_not_cataloged:\(fileID.uuidString)"
        case let .fileOutsideRootScope(fileID):
            "1:file_outside_root_scope:\(fileID.uuidString)"
        case let .logicalPathUnavailable(fileID):
            "2:logical_path_unavailable:\(fileID.uuidString)"
        case let .incompleteRootSet(missingFileIDs):
            "3:incomplete_root_set:\(missingFileIDs.map(\.uuidString).sorted().joined(separator: ","))"
        }
    }

    func automaticCodemapSelectionSourceLimit() -> Int {
        selectionGraphQueryBudgetPolicy.maximumRawSourceCount
    }

    private func codemapAutomaticSelectionRootScopeEpochs(
        _ rootScope: WorkspaceLookupRootScope
    ) -> [WorkspaceCodemapRootEpoch] {
        rootsForPathLookup(scope: rootScope).compactMap { root in
            guard let state = rootStatesByID[root.id] else { return nil }
            return WorkspaceCodemapRootEpoch(rootID: root.id, rootLifetimeID: state.lifetimeID)
        }.sorted(by: workspaceCodemapRootEpochPrecedes)
    }

    func resolveAutomaticCodemapSelection(
        sources: [WorkspaceCodemapAutomaticSelectionSourceIdentity],
        rootScope: WorkspaceLookupRootScope
    ) async throws -> WorkspaceCodemapAutomaticSelectionResult {
        try Task.checkCancellation()
        let policy = selectionGraphQueryBudgetPolicy
        guard !sources.isEmpty else {
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .unavailable([.emptySources])
            )
        }
        guard sources.count <= policy.maximumRawSourceCount else {
            let issue = WorkspaceCodemapAutomaticSelectionIssue.budget(.sourceLimit(
                attempted: sources.count,
                limit: policy.maximumRawSourceCount
            ))
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .unavailable([issue])
            )
        }

        var seenSlots = Set<WorkspaceCodemapRootScopedFileSlot>()
        let uniqueSources = sources.filter {
            seenSlots.insert(WorkspaceCodemapRootScopedFileSlot(source: $0)).inserted
        }
        guard uniqueSources.count <= policy.maximumUniqueSourceCount else {
            let issue = WorkspaceCodemapAutomaticSelectionIssue.budget(.uniqueSourceLimit(
                attempted: uniqueSources.count,
                limit: policy.maximumUniqueSourceCount
            ))
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .unavailable([issue])
            )
        }

        let rootScopeEpochs = codemapAutomaticSelectionRootScopeEpochs(rootScope)
        let allowedEpochs = Set(rootScopeEpochs)
        let sourcesByRoot = Dictionary(grouping: uniqueSources, by: \.rootEpoch)
        let orderedRoots = sourcesByRoot.keys.sorted(by: workspaceCodemapRootEpochPrecedes)
        guard orderedRoots.count <= policy.maximumRootCount else {
            let issue = WorkspaceCodemapAutomaticSelectionIssue.budget(.rootLimit(
                attempted: orderedRoots.count,
                limit: policy.maximumRootCount
            ))
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .unavailable([issue])
            )
        }

        var rootResults: [WorkspaceCodemapAutomaticSelectionRootResult] = []
        var acceptedTargetCount = 0
        var acceptedResolutionCount = 0
        var acceptedFailureCount = 0
        var acceptedByteCount = 0

        for rootEpoch in orderedRoots {
            try Task.checkCancellation()
            let rootSources = (sourcesByRoot[rootEpoch] ?? []).sorted {
                if $0.fileID != $1.fileID { return $0.fileID.uuidString < $1.fileID.uuidString }
                return $0.requestGeneration < $1.requestGeneration
            }
            guard allowedEpochs.contains(rootEpoch),
                  let state = rootStatesByID[rootEpoch.rootID],
                  state.lifetimeID == rootEpoch.rootLifetimeID,
                  let session = codemapSessionsByRootEpoch[rootEpoch],
                  let engine = session.engine
            else {
                rootResults.append(WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    status: .unavailable,
                    targets: [],
                    sources: [],
                    issues: [.rootEpochChanged(rootEpoch)],
                    coverage: nil,
                    graphTargetCount: 0,
                    graphResolutionCount: 0,
                    graphReferenceFailureCount: 0,
                    graphByteCount: 0,
                    receipt: nil
                ))
                continue
            }

            // P4-6a / B1 site 3 (id-keyed, async, D-8). One batched
            // `inventoryRecordFacts` call per root scan -- entirely before this
            // function's first `await` (`engine.selectionGraph` below), so no new
            // staleness window opens. The post-await re-check further down
            // (`currentSession.engine === engine`, `currentSession.authority == session.authority`,
            // root lifetime) is this site's existing D-8 anchor and is untouched.
            // Named test: `testResolveAutomaticCodemapSelectionServesManagedOnlyFile`.
            let facts = await inventoryRecordFacts(fileIDs: rootSources.map(\.fileID), folderIDs: []).filesByID
            var validSources: [WorkspaceCodemapAutomaticSelectionSourceIdentity] = []
            var sourceIssues: [WorkspaceCodemapAutomaticSelectionIssue] = []
            for source in rootSources {
                guard source.catalogGeneration == session.authority.catalogGeneration,
                      let fact = facts[source.fileID],
                      let file = fact.record,
                      file.rootID == rootEpoch.rootID,
                      fact.isDiscoverable,
                      fact.pathRoundTripsToSelf
                else {
                    sourceIssues.append(.sourceNotCataloged(source))
                    continue
                }
                let currentGeneration = session.pathGenerationsByRelativePath[file.standardizedRelativePath]
                    ?? session.authority.ingressGeneration
                guard currentGeneration == source.requestGeneration else {
                    sourceIssues.append(.sourceGenerationChanged(
                        source,
                        committedGeneration: currentGeneration
                    ))
                    continue
                }
                validSources.append(source)
            }
            guard !validSources.isEmpty else {
                rootResults.append(WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    status: .unavailable,
                    targets: [],
                    sources: [],
                    issues: sourceIssues.sorted(by: automaticSelectionIssuePrecedes),
                    coverage: nil,
                    graphTargetCount: 0,
                    graphResolutionCount: 0,
                    graphReferenceFailureCount: 0,
                    graphByteCount: 0,
                    receipt: nil
                ))
                continue
            }

            guard let graph = await engine.selectionGraph(rootEpoch: rootEpoch) else {
                rootResults.append(WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    status: .pending,
                    targets: [],
                    sources: [],
                    issues: (sourceIssues + [.graphNotInitialized(rootEpoch)])
                        .sorted(by: automaticSelectionIssuePrecedes),
                    coverage: nil,
                    graphTargetCount: 0,
                    graphResolutionCount: 0,
                    graphReferenceFailureCount: 0,
                    graphByteCount: 0,
                    receipt: nil
                ))
                continue
            }

            let remainingTargets = max(0, policy.maximumTargetCount - acceptedTargetCount)
            let remainingResolutions = max(0, policy.maximumResolutionCount - acceptedResolutionCount)
            let remainingFailures = max(0, policy.maximumReferenceFailureCount - acceptedFailureCount)
            let remainingBytes = max(0, policy.maximumByteCount - acceptedByteCount)
            let disposition = await graph.automaticSelectionLatest(.init(
                rootEpoch: rootEpoch,
                sources: validSources.map {
                    .init(fileID: $0.fileID, requestGeneration: $0.requestGeneration)
                },
                maximumTargetCount: remainingTargets,
                maximumResolutionCount: remainingResolutions,
                maximumReferenceFailureCount: remainingFailures,
                maximumByteCount: remainingBytes
            ))

            guard let currentSession = codemapSessionsByRootEpoch[rootEpoch],
                  currentSession.engine === engine,
                  currentSession.authority == session.authority,
                  rootStatesByID[rootEpoch.rootID]?.lifetimeID == rootEpoch.rootLifetimeID
            else {
                rootResults.append(WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    status: .unavailable,
                    targets: [],
                    sources: [],
                    issues: [.rootEpochChanged(rootEpoch)],
                    coverage: nil,
                    graphTargetCount: 0,
                    graphResolutionCount: 0,
                    graphReferenceFailureCount: 0,
                    graphByteCount: 0,
                    receipt: nil
                ))
                continue
            }

            switch disposition {
            case .pending:
                rootResults.append(WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    status: .pending,
                    targets: [],
                    sources: [],
                    issues: (sourceIssues + [.graphNotInitialized(rootEpoch)])
                        .sorted(by: automaticSelectionIssuePrecedes),
                    coverage: nil,
                    graphTargetCount: 0,
                    graphResolutionCount: 0,
                    graphReferenceFailureCount: 0,
                    graphByteCount: 0,
                    receipt: nil
                ))
            case let .revoked(reason):
                rootResults.append(WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    status: .unavailable,
                    targets: [],
                    sources: [],
                    issues: (sourceIssues + [.graphRevoked(rootEpoch, reason)])
                        .sorted(by: automaticSelectionIssuePrecedes),
                    coverage: nil,
                    graphTargetCount: 0,
                    graphResolutionCount: 0,
                    graphReferenceFailureCount: 0,
                    graphByteCount: 0,
                    receipt: nil
                ))
            case let .budget(reason):
                rootResults.append(WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    status: .unavailable,
                    targets: [],
                    sources: [],
                    issues: (sourceIssues + [.budget(reason)])
                        .sorted(by: automaticSelectionIssuePrecedes),
                    coverage: nil,
                    graphTargetCount: 0,
                    graphResolutionCount: 0,
                    graphReferenceFailureCount: 0,
                    graphByteCount: 0,
                    receipt: nil
                ))
            case .cancelled:
                throw CancellationError()
            case let .ready(graphResult):
                var issues = sourceIssues
                for graphSource in graphResult.sources {
                    guard let source = validSources.first(where: { $0.fileID == graphSource.fileID }) else { continue }
                    switch graphSource.state {
                    case .covered:
                        break
                    case .pending:
                        issues.append(.sourcePending(source))
                    case .notIndexed:
                        issues.append(.sourceNotIndexed(source))
                    case .excluded:
                        issues.append(.sourceExcluded(source))
                    case .fenced:
                        issues.append(.sourceFenced(source))
                    case let .staleGeneration(_, committed):
                        issues.append(.sourceGenerationChanged(source, committedGeneration: committed))
                    }
                }
                if case .updatesPending = graphResult.freshness {
                    issues.append(.updatesPending(rootEpoch))
                }
                if graphResult.reconciling {
                    issues.append(.reconciling(rootEpoch))
                }

                var targets: [WorkspaceCodemapAutomaticSelectionTarget] = []
                // P4-6b table-deletion conversion: batched `inventoryRecordFacts` over this
                // iteration's target ids, hoisted before the loop (matching this site's own B1
                // shape elsewhere in this function). `fact.pathRoundTripsToSelf` is exactly R3
                // (`state.fileIDsByRelativePath[record.standardizedRelativePath] == fileID`),
                // read directly off the fact rather than the deleted per-root path map.
                let targetFacts = await inventoryRecordFacts(
                    fileIDs: graphResult.targets.map(\.fileID),
                    folderIDs: []
                ).filesByID
                for graphTarget in graphResult.targets {
                    guard let fact = targetFacts[graphTarget.fileID],
                          let file = fact.record,
                          file.rootID == rootEpoch.rootID,
                          fact.isDiscoverable,
                          fact.pathRoundTripsToSelf,
                          file.standardizedRelativePath == graphTarget.standardizedRelativePath
                    else {
                        issues.append(.targetNotCataloged(rootEpoch: rootEpoch, fileID: graphTarget.fileID))
                        continue
                    }
                    let currentGeneration = currentSession.pathGenerationsByRelativePath[file.standardizedRelativePath]
                        ?? currentSession.authority.ingressGeneration
                    guard currentGeneration == graphTarget.requestGeneration else {
                        issues.append(.targetGenerationChanged(rootEpoch: rootEpoch, fileID: graphTarget.fileID))
                        continue
                    }
                    guard let logicalPath = WorkspaceCodemapLogicalPresentationPath(
                        rootDisplayName: state.root.name,
                        standardizedRelativePath: file.standardizedRelativePath
                    ) else {
                        issues.append(.targetLogicalPathUnavailable(
                            rootEpoch: rootEpoch,
                            fileID: graphTarget.fileID
                        ))
                        continue
                    }
                    targets.append(.init(
                        rootEpoch: rootEpoch,
                        fileID: file.id,
                        catalogGeneration: currentSession.authority.catalogGeneration,
                        requestGeneration: currentGeneration,
                        logicalPath: logicalPath
                    ))
                }
                targets.sort(by: automaticSelectionTargetPrecedes)
                let seeds = validSources.map {
                    WorkspaceCodemapAutomaticSelectionGraphSeed(
                        fileID: $0.fileID,
                        requestGeneration: $0.requestGeneration
                    )
                }
                let affected = Set(seeds.map(\.fileID)).union(targets.map(\.fileID))
                let receiptDisposition = await graph.revalidate(
                    graphResult.receipt,
                    affectedFileIDs: affected
                )
                let rootReceipt: WorkspaceCodemapAutomaticSelectionRootReceipt?
                switch receiptDisposition {
                case .valid:
                    rootReceipt = WorkspaceCodemapAutomaticSelectionRootReceipt(
                        rootEpoch: rootEpoch,
                        graphReceipt: graphResult.receipt,
                        sources: seeds,
                        targets: targets
                    )
                case let .invalid(reason):
                    issues.append(.receiptInvalid(rootEpoch: rootEpoch, reason: reason))
                    rootReceipt = nil
                    targets.removeAll()
                case let .revoked(reason):
                    issues.append(.graphRevoked(rootEpoch, reason))
                    rootReceipt = nil
                    targets.removeAll()
                }

                if rootReceipt != nil {
                    acceptedTargetCount += targets.count
                    acceptedResolutionCount += graphResult.resolutionCount
                    acceptedFailureCount += graphResult.referenceFailureCount
                    acceptedByteCount += graphResult.materializedByteCount
                }
                let hasPendingSource = graphResult.sources.contains {
                    $0.state == .pending || $0.state == .notIndexed
                }
                let status: WorkspaceCodemapAutomaticSelectionStatus = if !targets.isEmpty, !issues.isEmpty {
                    .partial
                } else if hasPendingSource || graphResult.reconciling {
                    targets.isEmpty ? .pending : .partial
                } else if rootReceipt == nil {
                    .unavailable
                } else {
                    .ok
                }
                rootResults.append(WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: rootEpoch,
                    status: status,
                    targets: targets,
                    sources: graphResult.sources,
                    issues: issues.sorted(by: automaticSelectionIssuePrecedes),
                    coverage: graphResult.coverage,
                    graphTargetCount: graphResult.targets.count,
                    graphResolutionCount: graphResult.resolutionCount,
                    graphReferenceFailureCount: graphResult.referenceFailureCount,
                    graphByteCount: graphResult.materializedByteCount,
                    receipt: rootReceipt
                ))
            }
        }

        let receiptRoots = rootResults.compactMap { result -> WorkspaceCodemapAutomaticSelectionRootReceipt? in
            guard !result.targets.isEmpty else { return nil }
            return result.receipt
        }
        let receipt = receiptRoots.isEmpty ? nil : WorkspaceCodemapAutomaticSelectionReceipt(
            rootScope: rootScope,
            rootScopeEpochs: rootScopeEpochs,
            roots: receiptRoots
        )
        return WorkspaceCodemapAutomaticSelectionResult(roots: rootResults, receipt: receipt)
    }

    func revalidateAutomaticCodemapSelection(
        _ receipt: WorkspaceCodemapAutomaticSelectionReceipt,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspaceCodemapAutomaticSelectionRevalidation {
        let currentEpochs = codemapAutomaticSelectionRootScopeEpochs(rootScope)
        guard receipt.rootScope == rootScope, receipt.rootScopeEpochs == currentEpochs else {
            let issues: [WorkspaceCodemapAutomaticSelectionIssue] = [.rootScopeChanged]
            return WorkspaceCodemapAutomaticSelectionRevalidation(
                roots: receipt.roots.map { .invalid(rootEpoch: $0.rootEpoch, issues: issues) },
                validTargets: [],
                issues: issues
            )
        }

        var roots: [WorkspaceCodemapAutomaticSelectionRootRevalidation] = []
        var validTargets: [WorkspaceCodemapAutomaticSelectionTarget] = []
        var allIssues: [WorkspaceCodemapAutomaticSelectionIssue] = []
        for rootReceipt in receipt.roots.sorted(by: {
            workspaceCodemapRootEpochPrecedes($0.rootEpoch, $1.rootEpoch)
        }) {
            let rootEpoch = rootReceipt.rootEpoch
            guard let state = rootStatesByID[rootEpoch.rootID],
                  state.lifetimeID == rootEpoch.rootLifetimeID,
                  let session = codemapSessionsByRootEpoch[rootEpoch],
                  let engine = session.engine,
                  let graph = await engine.selectionGraph(rootEpoch: rootEpoch)
            else {
                let issues: [WorkspaceCodemapAutomaticSelectionIssue] = [.rootEpochChanged(rootEpoch)]
                roots.append(.invalid(rootEpoch: rootEpoch, issues: issues))
                allIssues.append(contentsOf: issues)
                continue
            }
            let graphDisposition = await graph.revalidate(
                rootReceipt.graphReceipt,
                affectedFileIDs: rootReceipt.affectedFileIDs
            )
            guard let currentSession = codemapSessionsByRootEpoch[rootEpoch],
                  currentSession.engine === engine,
                  currentSession.authority == session.authority
            else {
                let issues: [WorkspaceCodemapAutomaticSelectionIssue] = [.rootEpochChanged(rootEpoch)]
                roots.append(.invalid(rootEpoch: rootEpoch, issues: issues))
                allIssues.append(contentsOf: issues)
                continue
            }
            var issues: [WorkspaceCodemapAutomaticSelectionIssue] = []
            var rootWideFailure = false
            switch graphDisposition {
            case .valid:
                break
            case let .invalid(reason):
                rootWideFailure = true
                issues.append(.receiptInvalid(rootEpoch: rootEpoch, reason: reason))
            case let .revoked(reason):
                rootWideFailure = true
                issues.append(.graphRevoked(rootEpoch, reason))
            }
            // P4-6a / B1 site 4 (id-keyed, async, D-8; PC-1 discoverability gap --
            // must stay absent). `state` is the same captured snapshot the post-await
            // code already reads elsewhere in this scope (no live re-fetch): one
            // batched `inventoryFileRecordFacts(in:fileIDs:)` call per scan. Named
            // test: `testRevalidateAutomaticCodemapSelectionServesManagedOnlyFile`.
            let seedFacts = await inventoryFileRecordFacts(in: state, fileIDs: rootReceipt.sources.map(\.fileID))
            for seed in rootReceipt.sources {
                guard let fact = seedFacts[seed.fileID],
                      let file = fact.record,
                      file.rootID == rootEpoch.rootID,
                      fact.pathRoundTripsToSelf,
                      (
                          currentSession.pathGenerationsByRelativePath[file.standardizedRelativePath]
                              ?? currentSession.authority.ingressGeneration
                      ) == seed.requestGeneration
                else {
                    rootWideFailure = true
                    if let source = await codemapAutomaticSelectionSourceIdentities(
                        forFileIDs: [seed.fileID],
                        rootScope: rootScope
                    ).first {
                        issues.append(.sourceGenerationChanged(source, committedGeneration: nil))
                    } else {
                        issues.append(.rootEpochChanged(rootEpoch))
                    }
                    continue
                }
            }
            var validRootTargets: [WorkspaceCodemapAutomaticSelectionTarget] = []
            if !rootWideFailure {
                let targetFacts = await inventoryFileRecordFacts(in: state, fileIDs: rootReceipt.targets.map(\.fileID))
                for target in rootReceipt.targets {
                    guard let fact = targetFacts[target.fileID],
                          let file = fact.record,
                          file.rootID == rootEpoch.rootID,
                          fact.pathRoundTripsToSelf,
                          target.catalogGeneration == currentSession.authority.catalogGeneration,
                          target.logicalPath.standardizedRelativePath == file.standardizedRelativePath,
                          (
                              currentSession.pathGenerationsByRelativePath[file.standardizedRelativePath]
                                  ?? currentSession.authority.ingressGeneration
                          ) == target.requestGeneration
                    else {
                        issues.append(.targetGenerationChanged(
                            rootEpoch: rootEpoch,
                            fileID: target.fileID
                        ))
                        continue
                    }
                    validRootTargets.append(target)
                }
            }
            issues.sort(by: automaticSelectionIssuePrecedes)
            if rootWideFailure || (!rootReceipt.targets.isEmpty && validRootTargets.isEmpty) {
                roots.append(.invalid(rootEpoch: rootEpoch, issues: issues))
            } else {
                validRootTargets.sort(by: automaticSelectionTargetPrecedes)
                roots.append(.valid(rootEpoch: rootEpoch, targets: validRootTargets))
                validTargets.append(contentsOf: validRootTargets)
            }
            allIssues.append(contentsOf: issues)
        }
        validTargets.sort(by: automaticSelectionTargetPrecedes)
        allIssues.sort(by: automaticSelectionIssuePrecedes)
        return WorkspaceCodemapAutomaticSelectionRevalidation(
            roots: roots,
            validTargets: validTargets,
            issues: allIssues
        )
    }

    func requestAutomaticCodemapTargetWithOwnership(
        target: WorkspaceCodemapAutomaticSelectionTarget,
        rootReceipt: WorkspaceCodemapAutomaticSelectionRootReceipt,
        rootScope: WorkspaceLookupRootScope,
        priority: CodeMapArtifactBuildPriority = .background
    ) async -> WorkspaceCodemapArtifactDemandOwnedResult? {
        guard rootReceipt.rootEpoch == target.rootEpoch,
              rootReceipt.targets.contains(target)
        else { return nil }
        let receipt = WorkspaceCodemapAutomaticSelectionReceipt(
            rootScope: rootScope,
            rootScopeEpochs: codemapAutomaticSelectionRootScopeEpochs(rootScope),
            roots: [rootReceipt]
        )
        let revalidation = await revalidateAutomaticCodemapSelection(receipt, rootScope: rootScope)
        guard revalidation.validTargets.contains(target) else { return nil }
        let owned = await requestCodemapArtifactWithOwnership(forFileID: target.fileID, priority: priority)
        let ticket: WorkspaceCodemapArtifactDemandTicket? = switch owned.result {
        case let .pending(ticket): ticket
        case let .ready(ready): ready.ticket
        case .unavailable: nil
        }
        if let ticket,
           ticket.rootEpoch != target.rootEpoch ||
           ticket.fileID != target.fileID ||
           ticket.catalogGeneration != target.catalogGeneration ||
           ticket.requestGeneration != target.requestGeneration ||
           ticket.pathGeneration != target.requestGeneration
        {
            return nil
        }
        return owned
    }

    private func currentCodemapAuthority(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> CodemapRootAuthority? {
        guard !codemapGenerationIsSuspended(rootEpoch: rootEpoch),
              let state = rootStatesByID[rootEpoch.rootID],
              state.lifetimeID == rootEpoch.rootLifetimeID
        else { return nil }
        if let session = codemapSessionsByRootEpoch[rootEpoch],
           codemapAuthorityMatchesLoadedRoot(session.authority)
        {
            return session.authority
        }
        if let launch = codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch],
           codemapAuthorityMatchesLoadedRoot(launch.authority)
        {
            return launch.authority
        }
        if let flight = codemapEligibilityFlightsByRootEpoch[rootEpoch],
           codemapAuthorityMatchesLoadedRoot(flight.authority)
        {
            return flight.authority
        }
        if let completed = codemapCompletedEligibilityByRootEpoch[rootEpoch],
           codemapAuthorityMatchesLoadedRoot(completed.authority)
        {
            return completed.authority
        }
        if let retry = codemapGraphIndexBuildRetriesByRootEpoch[rootEpoch],
           codemapAuthorityMatchesLoadedRoot(retry.authority)
        {
            return retry.authority
        }
        let generation = codemapAuthorityGenerationsByRootEpoch[rootEpoch] ?? 1
        guard generation > 0 else { return nil }
        codemapAuthorityGenerationsByRootEpoch[rootEpoch] = generation
        return CodemapRootAuthority(
            rootEpoch: rootEpoch,
            standardizedRootPath: state.root.standardizedFullPath,
            catalogGeneration: generation,
            ingressGeneration: generation
        )
    }

    private func recordCodemapGraphIndexBuildStoreEvent(
        _ kind: CodemapGraphIndexBuildStoreEventKind,
        rootEpoch: WorkspaceCodemapRootEpoch,
        phase: WorkspaceCodemapGraphIndexLaunchPhase
    ) {
        #if DEBUG
            nextCodemapGraphIndexBuildStoreEventOrdinal &+= 1
            codemapGraphIndexBuildStoreEvents.append(CodemapGraphIndexBuildStoreEvent(
                ordinal: nextCodemapGraphIndexBuildStoreEventOrdinal,
                rootEpoch: rootEpoch,
                kind: kind,
                launchPhase: phase,
                uptimeNanoseconds: codemapGraphIndexBuildRetryPolicy.nowNanoseconds()
            ))
            if codemapGraphIndexBuildStoreEvents.count > 2048 {
                codemapGraphIndexBuildStoreEvents.removeFirst(
                    codemapGraphIndexBuildStoreEvents.count - 2048
                )
            }
        #endif
    }

    private func recordCodemapRootReadyForGraphIndexBuild(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        recordCodemapGraphIndexBuildStoreEvent(
            .rootInventoryAndSearchReady,
            rootEpoch: rootEpoch,
            phase: .notScheduled
        )
    }

    /// Records launch state and creates the background task only. Git eligibility, runtime,
    /// integration-route, manifest, CAS, source, and graph work all begin in the task body.
    private func scheduleCodemapGraphIndexBuildAfterRootReady(
        rootEpoch: WorkspaceCodemapRootEpoch,
        retryAttempt: Int = 0
    ) {
        #if DEBUG
            guard codemapGraphIndexBuildLaunchPolicyForTesting == .enabled else { return }
        #endif
        guard !codemapGenerationIsSuspended(rootEpoch: rootEpoch),
              codemapCleanupFlightsByRootID[rootEpoch.rootID] == nil,
              codemapRootMutationFenceTokensByRootEpoch[rootEpoch] == nil,
              let authority = currentCodemapAuthority(rootEpoch: rootEpoch),
              codemapPreflightAuthorityIsCurrent(authority)
        else { return }
        if let existing = codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch] {
            switch existing.phase {
            case .cancelled, .superseded, .transientRetry:
                break
            case .notScheduled, .eligibilityQueued, .setupJoining, .engineScheduling,
                 .handedOff, .terminalNonGit, .retryExhausted:
                return
            }
        }

        let launchID = UUID()
        let createdUptimeNanoseconds = codemapGraphIndexBuildRetryPolicy.nowNanoseconds()
        codemapGraphIndexRetryExhaustionByRootEpoch.removeValue(forKey: rootEpoch)
        codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch] = CodemapGraphIndexBuildLaunch(
            id: launchID,
            authority: authority,
            retryAttempt: retryAttempt,
            phase: .eligibilityQueued,
            task: nil,
            createdUptimeNanoseconds: createdUptimeNanoseconds,
            phaseEnteredUptimeNanoseconds: createdUptimeNanoseconds
        )
        recordCodemapGraphIndexBuildStoreEvent(
            .scheduled,
            rootEpoch: rootEpoch,
            phase: .eligibilityQueued
        )
        let task = Task<Void, Never>(priority: .utility) { [weak self] in
            guard let self else { return }
            await runCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority
            )
        }
        guard var launch = codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch],
              launch.id == launchID
        else {
            task.cancel()
            return
        }
        launch.task = task
        codemapGraphIndexBuildLaunchesByRootEpoch[rootEpoch] = launch
        publishCodemapRootStatusesIfChanged()
    }

    private func runCodemapGraphIndexBuildLaunch(
        launchID: UUID,
        authority: CodemapRootAuthority
    ) async {
        #if DEBUG
            if let codemapGraphIndexBuildStartHandler {
                await codemapGraphIndexBuildStartHandler(authority.rootEpoch)
            }
        #endif
        guard !Task.isCancelled,
              codemapGraphIndexBuildLaunchIsCurrent(launchID: launchID, authority: authority)
        else {
            finishCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority,
                phase: .cancelled
            )
            return
        }
        recordCodemapGraphIndexBuildStoreEvent(
            .started,
            rootEpoch: authority.rootEpoch,
            phase: .eligibilityQueued
        )

        let eligibility: CodemapEligibilityResolution = if let cached = cachedCodemapEligibility(authority: authority) {
            cached
        } else {
            await resolveCodemapEligibility(authority: authority)
        }
        guard !Task.isCancelled,
              codemapGraphIndexBuildLaunchIsCurrent(launchID: launchID, authority: authority)
        else {
            finishCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority,
                phase: .cancelled
            )
            return
        }
        switch eligibility {
        case .eligible:
            recordCodemapGraphIndexBuildStoreEvent(
                .eligibilityEligible,
                rootEpoch: authority.rootEpoch,
                phase: .setupJoining
            )
        case let .terminal(reason, _):
            let unavailable = WorkspaceCodemapArtifactDemandUnavailableReason.gitTerminal(reason)
            installCodemapTerminalSetupDisposition(unavailable, authority: authority)
            let phase: WorkspaceCodemapGraphIndexLaunchPhase = reason == .nonGit
                ? .terminalNonGit
                : .superseded
            recordCodemapGraphIndexBuildStoreEvent(
                .eligibilityTerminal,
                rootEpoch: authority.rootEpoch,
                phase: phase
            )
            finishCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority,
                phase: phase
            )
            return
        case .transient:
            recordCodemapGraphIndexBuildStoreEvent(
                .eligibilityTransient,
                rootEpoch: authority.rootEpoch,
                phase: .transientRetry
            )
            finishCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority,
                phase: .transientRetry
            )
            scheduleCodemapGraphIndexBuildRetry(
                launchID: launchID,
                authority: authority
            )
            return
        case .stale:
            finishCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority,
                phase: .superseded
            )
            return
        case .cancelled:
            finishCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority,
                phase: .cancelled
            )
            return
        }

        guard let setup = ensureCodemapSetupTask(authority: authority) else {
            finishCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority,
                phase: .superseded
            )
            return
        }
        updateCodemapGraphIndexBuildLaunchPhase(
            .setupJoining,
            launchID: launchID,
            authority: authority
        )
        recordCodemapGraphIndexBuildStoreEvent(
            .setupJoining,
            rootEpoch: authority.rootEpoch,
            phase: .setupJoining
        )
        let setupDisposition = await setup.value
        guard !Task.isCancelled,
              codemapGraphIndexBuildLaunchIsCurrent(launchID: launchID, authority: authority)
        else {
            finishCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority,
                phase: .cancelled
            )
            return
        }
        guard case .ready = setupDisposition else {
            let retryable = codemapSetupDispositionIsRetryable(setupDisposition)
            let phase: WorkspaceCodemapGraphIndexLaunchPhase = retryable
                ? .transientRetry
                : .superseded
            finishCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority,
                phase: phase
            )
            if retryable {
                scheduleCodemapGraphIndexBuildRetry(
                    launchID: launchID,
                    authority: authority
                )
            }
            return
        }
        guard let engine = codemapSessionsByRootEpoch[authority.rootEpoch]?.engine else {
            finishCodemapGraphIndexBuildLaunch(
                launchID: launchID,
                authority: authority,
                phase: .superseded
            )
            return
        }

        updateCodemapGraphIndexBuildLaunchPhase(
            .engineScheduling,
            launchID: launchID,
            authority: authority
        )
        recordCodemapGraphIndexBuildStoreEvent(
            .engineScheduling,
            rootEpoch: authority.rootEpoch,
            phase: .engineScheduling
        )
        let disposition = await engine.scheduleGraphIndex(rootEpoch: authority.rootEpoch)
        guard codemapGraphIndexBuildLaunchIsCurrent(launchID: launchID, authority: authority) else {
            return
        }
        finishCodemapGraphIndexBuildLaunch(
            launchID: launchID,
            authority: authority,
            phase: disposition
        )
        if disposition == .handedOff {
            recordCodemapGraphIndexBuildStoreEvent(
                .handedOff,
                rootEpoch: authority.rootEpoch,
                phase: .handedOff
            )
        }
    }

    private func resolveCodemapEligibility(
        authority: CodemapRootAuthority
    ) async -> CodemapEligibilityResolution {
        var requiresGitPreflight = false
        if let completed = codemapCompletedEligibilityByRootEpoch[authority.rootEpoch],
           completed.authority == authority,
           codemapPreflightAuthorityIsCurrent(authority)
        {
            if case let .terminal(.nonGit, proof?) = completed.result {
                switch codemapLocalGitClassificationProbe.validate(proof) {
                case .current:
                    return completed.result
                case .requiresLocalReclassification:
                    break
                case .requiresGitPreflight:
                    requiresGitPreflight = true
                }
                codemapCompletedEligibilityByRootEpoch.removeValue(forKey: authority.rootEpoch)
                terminalNonGitCodemapCacheByEpoch.removeValue(forKey: authority.rootEpoch)
            } else {
                return completed.result
            }
        }
        if let cached = terminalNonGitCodemapCacheByEpoch[authority.rootEpoch] {
            guard cached.standardizedRootPath == authority.standardizedRootPath,
                  codemapPreflightAuthorityIsCurrent(authority)
            else {
                terminalNonGitCodemapCacheByEpoch.removeValue(forKey: authority.rootEpoch)
                return .stale
            }
            switch codemapLocalGitClassificationProbe.validate(cached.proof) {
            case .current:
                return .terminal(.nonGit, cached.proof)
            case .requiresLocalReclassification:
                break
            case .requiresGitPreflight:
                requiresGitPreflight = true
            }
            terminalNonGitCodemapCacheByEpoch.removeValue(forKey: authority.rootEpoch)
        }

        let flight: CodemapEligibilityFlight
        if let existing = codemapEligibilityFlightsByRootEpoch[authority.rootEpoch],
           existing.authority == authority
        {
            flight = existing
        } else {
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else { return CodemapEligibilityResolution.cancelled }
                return await performCodemapEligibility(
                    authority: authority,
                    requiresGitPreflight: requiresGitPreflight
                )
            }
            flight = CodemapEligibilityFlight(id: id, authority: authority, task: task)
            codemapEligibilityFlightsByRootEpoch[authority.rootEpoch] = flight
        }

        let result = await flight.task.value
        if codemapEligibilityFlightsByRootEpoch[authority.rootEpoch]?.id == flight.id {
            codemapEligibilityFlightsByRootEpoch.removeValue(forKey: authority.rootEpoch)
        }
        switch result {
        case .eligible, .terminal:
            if codemapPreflightAuthorityIsCurrent(authority) {
                codemapCompletedEligibilityByRootEpoch[authority.rootEpoch] = .init(
                    authority: authority,
                    result: result
                )
            }
        case .transient, .stale, .cancelled:
            break
        }
        if case let .terminal(.nonGit, proof?) = result,
           codemapPreflightAuthorityIsCurrent(authority),
           codemapLocalGitClassificationProbe.validate(proof) == .current
        {
            terminalNonGitCodemapCacheByEpoch[authority.rootEpoch] = .init(
                standardizedRootPath: authority.standardizedRootPath,
                proof: proof
            )
        }
        return result
    }

    private func cachedCodemapEligibility(
        authority: CodemapRootAuthority
    ) -> CodemapEligibilityResolution? {
        guard let session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority
        else { return nil }
        if case .ready? = session.setupDisposition, session.engine != nil {
            return .eligible
        }
        if case let .unavailable(reason)? = session.setupDisposition {
            switch reason {
            case let .gitTerminal(reason):
                return .terminal(reason, nil)
            case let .gitTransient(reason):
                return .transient(reason)
            default:
                return nil
            }
        }
        return nil
    }

    private func performCodemapEligibility(
        authority: CodemapRootAuthority,
        requiresGitPreflight: Bool
    ) async -> CodemapEligibilityResolution {
        let rootURL = URL(fileURLWithPath: authority.standardizedRootPath, isDirectory: true)
        if !requiresGitPreflight {
            let local = await codemapLocalGitClassificationProbe.resolve(rootURL)
            guard !Task.isCancelled else { return .cancelled }
            guard codemapPreflightAuthorityIsCurrent(authority) else { return .stale }
            if case let .definitelyNonGit(proof) = local,
               codemapLocalGitClassificationProbe.validate(proof) == .current
            {
                return .terminal(.nonGit, proof)
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        guard codemapPreflightAuthorityIsCurrent(authority) else { return .stale }
        let result = await codemapGitEligibilityProbe.resolve(rootURL)
        guard !Task.isCancelled else { return .cancelled }
        guard codemapPreflightAuthorityIsCurrent(authority) else { return .stale }
        return switch result {
        case .eligible:
            .eligible
        case let .terminalUnavailable(reason):
            .terminal(reason, nil)
        case let .transientUnavailable(reason):
            .transient(reason)
        }
    }

    private func installCodemapTerminalSetupDisposition(
        _ disposition: WorkspaceCodemapArtifactDemandUnavailableReason,
        authority: CodemapRootAuthority
    ) {
        guard codemapPreflightAuthorityIsCurrent(authority) else { return }
        codemapCompletedEligibilityByRootEpoch.removeValue(forKey: authority.rootEpoch)
        if var session = codemapSessionsByRootEpoch[authority.rootEpoch] {
            guard session.authority == authority,
                  session.setupTask == nil,
                  session.setupDisposition == nil
            else { return }
            session.setupDisposition = .unavailable(disposition)
            codemapSessionsByRootEpoch[authority.rootEpoch] = session
        } else {
            var session = CodemapRootSession(authority: authority)
            session.setupDisposition = .unavailable(disposition)
            codemapSessionsByRootEpoch[authority.rootEpoch] = session
        }
    }

    private func ensureCodemapSetupTask(
        authority: CodemapRootAuthority
    ) -> Task<CodemapSetupDisposition, Never>? {
        guard !codemapGenerationIsSuspended(rootEpoch: authority.rootEpoch),
              codemapPreflightAuthorityIsCurrent(authority)
        else { return nil }
        codemapCompletedEligibilityByRootEpoch.removeValue(forKey: authority.rootEpoch)
        if let existing = codemapSessionsByRootEpoch[authority.rootEpoch] {
            guard existing.authority == authority else { return nil }
            if let setupTask = existing.setupTask { return setupTask }
            if let disposition = existing.setupDisposition {
                return Task { disposition }
            }
        } else {
            codemapSessionsByRootEpoch[authority.rootEpoch] = CodemapRootSession(
                authority: authority
            )
        }
        #if DEBUG
            codemapSetupTaskCreationCountForTesting += 1
        #endif
        let setupTask = Task { [weak self] in
            guard let self else {
                return CodemapSetupDisposition.unavailable(.cancelled)
            }
            return await performCodemapSetup(authority: authority)
        }
        codemapSessionsByRootEpoch[authority.rootEpoch]?.setupTask = setupTask
        return setupTask
    }

    private func codemapGraphIndexBuildLaunchIsCurrent(
        launchID: UUID,
        authority: CodemapRootAuthority
    ) -> Bool {
        guard let launch = codemapGraphIndexBuildLaunchesByRootEpoch[authority.rootEpoch],
              launch.id == launchID,
              launch.authority == authority,
              !codemapGenerationIsSuspended(rootEpoch: authority.rootEpoch),
              codemapPreflightAuthorityIsCurrent(authority)
        else { return false }
        return true
    }

    private func updateCodemapGraphIndexBuildLaunchPhase(
        _ phase: WorkspaceCodemapGraphIndexLaunchPhase,
        launchID: UUID,
        authority: CodemapRootAuthority,
        uptimeNanoseconds: UInt64? = nil
    ) {
        guard var launch = codemapGraphIndexBuildLaunchesByRootEpoch[authority.rootEpoch],
              launch.id == launchID,
              launch.authority == authority
        else { return }
        launch.phase = phase
        launch.phaseEnteredUptimeNanoseconds = uptimeNanoseconds
            ?? codemapGraphIndexBuildRetryPolicy.nowNanoseconds()
        codemapGraphIndexBuildLaunchesByRootEpoch[authority.rootEpoch] = launch
        publishCodemapRootStatusesIfChanged()
    }

    private func finishCodemapGraphIndexBuildLaunch(
        launchID: UUID,
        authority: CodemapRootAuthority,
        phase: WorkspaceCodemapGraphIndexLaunchPhase
    ) {
        guard var launch = codemapGraphIndexBuildLaunchesByRootEpoch[authority.rootEpoch],
              launch.id == launchID,
              launch.authority == authority
        else { return }
        launch.phase = phase
        launch.task = nil
        launch.phaseEnteredUptimeNanoseconds = codemapGraphIndexBuildRetryPolicy.nowNanoseconds()
        codemapGraphIndexBuildLaunchesByRootEpoch[authority.rootEpoch] = launch
        publishCodemapRootStatusesIfChanged()
        if phase == .cancelled || phase == .superseded {
            recordCodemapGraphIndexBuildStoreEvent(
                phase == .cancelled ? .cancelled : .superseded,
                rootEpoch: authority.rootEpoch,
                phase: phase
            )
        }
    }

    private func codemapSetupDispositionIsRetryable(
        _ disposition: CodemapSetupDisposition
    ) -> Bool {
        guard case let .unavailable(reason) = disposition else { return false }
        return !codemapUnavailableIsStable(reason)
    }

    private func scheduleCodemapGraphIndexBuildRetry(
        launchID: UUID,
        authority: CodemapRootAuthority
    ) {
        guard !codemapGenerationIsSuspended(rootEpoch: authority.rootEpoch),
              let launch = codemapGraphIndexBuildLaunchesByRootEpoch[authority.rootEpoch],
              launch.id == launchID,
              launch.authority == authority,
              launch.phase == .transientRetry,
              codemapPreflightAuthorityIsCurrent(authority),
              codemapGraphIndexBuildRetriesByRootEpoch[authority.rootEpoch] == nil
        else { return }
        let attempt = launch.retryAttempt + 1
        guard attempt <= codemapGraphIndexBuildRetryPolicy.maximumRetryCount else {
            let exhaustionUptimeNanoseconds = codemapGraphIndexBuildRetryPolicy.nowNanoseconds()
            let exhausted = CodemapGraphIndexRetryExhaustion(
                attempt: attempt,
                uptimeNanoseconds: exhaustionUptimeNanoseconds
            )
            codemapGraphIndexRetryExhaustionByRootEpoch[authority.rootEpoch] = exhausted
            updateCodemapGraphIndexBuildLaunchPhase(
                .retryExhausted,
                launchID: launchID,
                authority: authority,
                uptimeNanoseconds: exhaustionUptimeNanoseconds
            )
            recordCodemapGraphIndexBuildStoreEvent(
                .retryExhausted,
                rootEpoch: authority.rootEpoch,
                phase: .retryExhausted
            )
            return
        }
        let delay = codemapGraphIndexBuildRetryPolicy.backoffNanoseconds(forAttempt: attempt)
        let now = codemapGraphIndexBuildRetryPolicy.nowNanoseconds()
        let (candidateDeadline, overflow) = now.addingReportingOverflow(delay)
        let deadline = overflow ? UInt64.max : candidateDeadline
        let retryID = UUID()
        let sleep = codemapGraphIndexBuildRetryPolicy.sleep
        let task = Task<Void, Never>(priority: .utility) { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self else { return }
            await performCodemapGraphIndexBuildRetry(
                retryID: retryID,
                authority: authority,
                attempt: attempt,
                deadlineNanoseconds: deadline
            )
        }
        codemapGraphIndexBuildRetriesByRootEpoch[authority.rootEpoch] = .init(
            id: retryID,
            authority: authority,
            attempt: attempt,
            deadlineNanoseconds: deadline,
            task: task
        )
        recordCodemapGraphIndexBuildStoreEvent(
            .retryScheduled,
            rootEpoch: authority.rootEpoch,
            phase: .transientRetry
        )
    }

    private func performCodemapGraphIndexBuildRetry(
        retryID: UUID,
        authority: CodemapRootAuthority,
        attempt: Int,
        deadlineNanoseconds: UInt64
    ) async {
        guard let retry = codemapGraphIndexBuildRetriesByRootEpoch[authority.rootEpoch],
              retry.id == retryID,
              retry.authority == authority,
              retry.attempt == attempt,
              retry.deadlineNanoseconds == deadlineNanoseconds
        else { return }
        codemapGraphIndexBuildRetriesByRootEpoch.removeValue(forKey: authority.rootEpoch)
        guard !Task.isCancelled,
              !codemapGenerationIsSuspended(rootEpoch: authority.rootEpoch),
              codemapGraphIndexBuildRetryPolicy.nowNanoseconds() >= deadlineNanoseconds,
              codemapPreflightAuthorityIsCurrent(authority)
        else { return }
        recordCodemapGraphIndexBuildStoreEvent(
            .retryStarted,
            rootEpoch: authority.rootEpoch,
            phase: .transientRetry
        )

        if let setupDisposition = codemapSessionsByRootEpoch[authority.rootEpoch]?.setupDisposition,
           codemapSetupDispositionIsRetryable(setupDisposition)
        {
            _ = detachCodemapSession(
                rootEpoch: authority.rootEpoch,
                invalidationCommands: [.catalogAdvanced]
            )
            await awaitCodemapCleanupFlights(rootIDs: [authority.rootEpoch.rootID])
            guard !Task.isCancelled else { return }
        }
        scheduleCodemapGraphIndexBuildAfterRootReady(
            rootEpoch: authority.rootEpoch,
            retryAttempt: attempt
        )
    }

    func requestCodemapArtifact(
        forFileID fileID: UUID,
        priority: CodeMapArtifactBuildPriority = .demand
    ) async -> WorkspaceCodemapArtifactDemandResult {
        await requestCodemapArtifactWithOwnership(forFileID: fileID, priority: priority).result
    }

    func requestCodemapArtifactWithOwnership(
        forFileID fileID: UUID,
        priority: CodeMapArtifactBuildPriority = .demand
    ) async -> WorkspaceCodemapArtifactDemandOwnedResult {
        #if DEBUG
            codemapArtifactDemandRequestCountForTesting += 1
        #endif
        // P4-6a / B1 site 5 (id-keyed, async, no generation/lifetime re-check to
        // piggyback D-8 on -- per-iteration batch-of-one calls at each of this site's
        // two independent read points, matching its pre-refactor re-read-after-await
        // shape exactly rather than hoisting across the `await` below. R5
        // (`filesByID[file.id] == file`) is dropped here: both operands are the same
        // live synchronous read with no intervening `await` (§4.3.1.1 result 2).
        let firstPassFact = await inventoryRecordFacts(fileIDs: [fileID], folderIDs: []).filesByID[fileID]
        guard let file = firstPassFact?.record else {
            return .init(result: .unavailable(.fileNotCataloged), ownership: .notAcquired)
        }
        guard let state = rootStatesByID[file.rootID] else {
            return .init(result: .unavailable(.rootNotLoaded), ownership: .notAcquired)
        }
        guard firstPassFact?.pathRoundTripsToSelf == true
        else {
            return .init(result: .unavailable(.fileNotCataloged), ownership: .notAcquired)
        }

        let fileExtension = (file.name as NSString).pathExtension
        guard let language = SyntaxManager.shared.language(forFileExtension: fileExtension),
              SyntaxManager.supportsCodeMap(fileExtension: fileExtension)
        else {
            return .init(result: .unavailable(.unsupportedFileType), ownership: .notAcquired)
        }
        guard let identity = WorkspaceCodemapArtifactBindingIdentity(
            rootID: file.rootID,
            rootLifetimeID: state.lifetimeID,
            fileID: file.id,
            standardizedRootPath: state.root.standardizedFullPath,
            standardizedRelativePath: file.standardizedRelativePath,
            standardizedFullPath: file.standardizedFullPath
        ) else {
            return .init(result: .unavailable(.staleCurrentness), ownership: .notAcquired)
        }

        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: file.rootID,
            rootLifetimeID: state.lifetimeID
        )
        if codemapGenerationIsSuspended(rootEpoch: rootEpoch) {
            return .init(result: .unavailable(.cancelled), ownership: .notAcquired)
        }
        if codemapCleanupFlightsByRootID[file.rootID] != nil ||
            codemapRootMutationFenceTokensByRootEpoch[rootEpoch] != nil ||
            codemapPathIsFenced(rootEpoch: rootEpoch, relativePath: file.standardizedRelativePath)
        {
            return .init(result: .unavailable(.busy(retryAfterMilliseconds: nil)), ownership: .notAcquired)
        }

        guard let authority = currentCodemapAuthority(rootEpoch: rootEpoch) else {
            return .init(result: .unavailable(.staleCurrentness), ownership: .notAcquired)
        }
        if let retry = codemapGraphIndexBuildRetriesByRootEpoch[rootEpoch],
           retry.authority == authority
        {
            let now = codemapGraphIndexBuildRetryPolicy.nowNanoseconds()
            let remainingNanoseconds = retry.deadlineNanoseconds > now
                ? retry.deadlineNanoseconds - now
                : 0
            return .init(
                result: .unavailable(.busy(
                    retryAfterMilliseconds: Int(exactly: remainingNanoseconds / 1_000_000)
                )),
                ownership: .notAcquired
            )
        }
        if let existing = codemapSessionsByRootEpoch[rootEpoch],
           !codemapAuthorityMatchesLoadedRoot(existing.authority)
        {
            _ = detachCodemapSession(
                rootEpoch: rootEpoch,
                invalidationCommands: [.repositoryAuthority]
            )
            return .init(result: .unavailable(.busy(retryAfterMilliseconds: nil)), ownership: .notAcquired)
        }

        if case let .unavailable(reason)? =
            codemapSessionsByRootEpoch[rootEpoch]?.setupDisposition,
            codemapUnavailableIsStable(reason)
        {
            var shouldReturnStableUnavailable = true
            if case .gitTerminal(.nonGit) = reason,
               let cached = terminalNonGitCodemapCacheByEpoch[rootEpoch]
            {
                if cached.standardizedRootPath == authority.standardizedRootPath,
                   codemapLocalGitClassificationProbe.validate(cached.proof) == .current
                {
                    shouldReturnStableUnavailable = true
                } else {
                    codemapCompletedEligibilityByRootEpoch.removeValue(forKey: rootEpoch)
                    codemapSessionsByRootEpoch.removeValue(forKey: rootEpoch)
                    shouldReturnStableUnavailable = false
                }
            }
            if shouldReturnStableUnavailable {
                return .init(result: .unavailable(reason), ownership: .notAcquired)
            }
        }

        if codemapSessionsByRootEpoch[rootEpoch] == nil {
            let eligibility = await resolveCodemapEligibility(authority: authority)
            // D-8 (batch-of-one, fresh post-await read): `currentFile == file` is the
            // captured-operand form (D-11) -- `file` was bound before this `await`, so
            // this comparison is genuinely falsifiable and must not be dropped.
            let postEligibilityFact = await inventoryRecordFacts(fileIDs: [file.id], folderIDs: []).filesByID[file.id]
            guard codemapPreflightAuthorityIsCurrent(authority),
                  let currentFile = postEligibilityFact?.record,
                  currentFile == file,
                  postEligibilityFact?.pathRoundTripsToSelf == true
            else {
                return .init(result: .unavailable(.staleCurrentness), ownership: .notAcquired)
            }
            switch eligibility {
            case .eligible:
                break
            case let .terminal(reason, _):
                installCodemapTerminalSetupDisposition(.gitTerminal(reason), authority: authority)
                return .init(result: .unavailable(.gitTerminal(reason)), ownership: .notAcquired)
            case let .transient(reason):
                return .init(result: .unavailable(.gitTransient(reason)), ownership: .notAcquired)
            case .stale:
                return .init(result: .unavailable(.staleCurrentness), ownership: .notAcquired)
            case .cancelled:
                return .init(result: .unavailable(.cancelled), ownership: .notAcquired)
            }
        }

        if var session = codemapSessionsByRootEpoch[rootEpoch],
           var existing = session.demandsByFileID[file.id]
        {
            switch existing.result {
            case .pending, .ready:
                let joinedTicket = retainedCodemapTicket(for: existing.ticket)
                await codemapDemandRequestHook(joinedTicket)
                existing.retainIDs.insert(joinedTicket.retainID)
                session.demandsByFileID[file.id] = existing
                codemapSessionsByRootEpoch[rootEpoch] = session
                return .init(
                    result: codemapDemandResult(existing.result, for: joinedTicket),
                    ownership: .joined(joinedTicket)
                )
            case let .unavailable(reason) where codemapUnavailableIsStable(reason):
                return .init(result: existing.result, ownership: .notAcquired)
            case .unavailable:
                break
            }
        }
        if case let .unavailable(reason)? =
            codemapSessionsByRootEpoch[rootEpoch]?.setupDisposition,
            !codemapUnavailableIsStable(reason)
        {
            if codemapGraphIndexBuildRetriesByRootEpoch[rootEpoch] != nil {
                return .init(
                    result: .unavailable(.busy(retryAfterMilliseconds: nil)),
                    ownership: .notAcquired
                )
            }
            _ = detachCodemapSession(rootEpoch: rootEpoch)
            return .init(result: .unavailable(.busy(retryAfterMilliseconds: nil)), ownership: .notAcquired)
        }

        if codemapSessionsByRootEpoch[rootEpoch] == nil {
            codemapSessionsByRootEpoch[rootEpoch] = CodemapRootSession(authority: authority)
        }

        let pathGeneration = codemapSessionsByRootEpoch[rootEpoch]?
            .pathGenerationsByRelativePath[file.standardizedRelativePath] ?? authority.ingressGeneration
        let ticket = WorkspaceCodemapArtifactDemandTicket(
            retainID: UUID(),
            requestID: UUID(),
            rootEpoch: rootEpoch,
            fileID: file.id,
            requestGeneration: pathGeneration,
            catalogGeneration: authority.catalogGeneration,
            pathGeneration: pathGeneration,
            ingressGeneration: authority.ingressGeneration
        )
        await codemapDemandRequestHook(ticket)
        let owner = WorkspaceCodemapLiveDemandOwner()
        let completion = CodemapDemandCompletion()
        var record = CodemapDemandRecord(
            ticket: ticket,
            identity: identity,
            language: language,
            owner: owner,
            completion: completion,
            retainIDs: [ticket.retainID],
            result: .pending(ticket),
            task: nil
        )

        _ = ensureCodemapSetupTask(authority: authority)

        codemapSessionsByRootEpoch[rootEpoch]?.demandsByFileID[file.id] = record
        #if DEBUG
            codemapDemandTaskCreationCountForTesting += 1
        #endif
        let demandTask = Task { [weak self, completion] in
            defer { completion.resolve() }
            guard let self else { return }
            await performCodemapDemand(ticket: ticket, priority: priority)
        }
        record.task = demandTask
        codemapSessionsByRootEpoch[rootEpoch]?.demandsByFileID[file.id] = record
        return .init(result: .pending(ticket), ownership: .created(ticket))
    }

    func codemapArtifactDemandStatus(
        _ ticket: WorkspaceCodemapArtifactDemandTicket
    ) async -> WorkspaceCodemapArtifactDemandResult {
        guard await codemapDemandIsCurrent(ticket),
              let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
              .demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket)
        else {
            return .unavailable(.staleCurrentness)
        }
        guard record.retainIDs.contains(ticket.retainID) else {
            if case .unavailable(.cancelled) = record.result {
                return .unavailable(.cancelled)
            }
            return .unavailable(.staleCurrentness)
        }
        return codemapDemandResult(record.result, for: ticket)
    }

    func waitForCodemapArtifactDemandChange(
        _ ticket: WorkspaceCodemapArtifactDemandTicket,
        deadline: ContinuousClock.Instant
    ) async -> WorkspaceCodemapArtifactDemandResult {
        guard await codemapDemandIsCurrent(ticket),
              let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
              .demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket),
              record.retainIDs.contains(ticket.retainID)
        else {
            return .unavailable(.staleCurrentness)
        }

        let current = codemapDemandResult(record.result, for: ticket)
        guard case .pending = current, record.task != nil else {
            return current
        }
        await record.completion.wait(until: deadline)
        return await codemapArtifactDemandStatus(ticket)
    }

    func retryBusyCodemapArtifactDemand(
        _ ticket: WorkspaceCodemapArtifactDemandTicket,
        priority: CodeMapArtifactBuildPriority
    ) async -> WorkspaceCodemapArtifactDemandResult {
        guard await codemapDemandIsCurrent(ticket),
              var session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              let record = session.demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket),
              record.retainIDs.contains(ticket.retainID),
              case .unavailable(.busy) = record.result
        else {
            return await codemapArtifactDemandStatus(ticket)
        }
        guard record.retainIDs.count == 1 else {
            return codemapDemandResult(record.result, for: ticket)
        }
        session.demandsByFileID.removeValue(forKey: ticket.fileID)
        let bundle = session.bundlesByRequestID.removeValue(forKey: ticket.requestID)
        codemapSessionsByRootEpoch[ticket.rootEpoch] = session
        bundle?.close()
        if let engine = session.engine {
            await codemapCancellationCleanupHook(ticket)
            _ = await engine.cancel(owner: record.owner)
        }
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        return await requestCodemapArtifact(forFileID: ticket.fileID, priority: priority)
    }

    func queryCodemapStructureGraphs(
        seedFileIDs: [UUID],
        direction: WorkspaceCodemapStructureTraversalDirection?,
        maximumDepth: Int,
        budget: WorkspaceCodemapGraphQueryBudget,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String] = [:]
    ) async throws -> WorkspaceCodemapStructureAggregateResult {
        try Task.checkCancellation()
        let scopedRoots = rootsForPathLookup(scope: rootScope)
        let allowedRootIDs = Set(scopedRoots.map(\.id))
        let defaultRootLabels = WorkspaceLogicalRootIdentity.labels(for: scopedRoots.compactMap { root in
            guard let state = rootStatesByID[root.id] else { return nil }
            return WorkspaceLogicalRootIdentity.RootDescriptor(
                physicalRootID: root.id,
                rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: root.id,
                    rootLifetimeID: state.lifetimeID
                ),
                preferredName: root.name
            )
        })
        let rootLabels = defaultRootLabels.merging(logicalRootDisplayNamesByRootID) { _, supplied in supplied }
        var requestIssues: [WorkspaceCodemapStructureIssueRecord] = []
        var seedsByRootEpoch: [WorkspaceCodemapRootEpoch: [UUID]] = [:]
        var seedPathsByFileID: [UUID: String] = [:]
        // P4-6a / B1 site 6 (id-keyed, async; no generation/lifetime clause to
        // piggyback D-8 on for this synchronous seed-resolution scan -- one batched
        // call before the loop is safe here since nothing in this loop awaits).
        // Named test: `testQueryCodemapStructureGraphsServesManagedOnlyFile`.
        var seenFileIDs = Set<UUID>()
        let seedFacts = await inventoryRecordFacts(fileIDs: seedFileIDs, folderIDs: []).filesByID
        for fileID in seedFileIDs where seenFileIDs.insert(fileID).inserted {
            guard let fact = seedFacts[fileID], let file = fact.record, fact.isDiscoverable,
                  allowedRootIDs.contains(file.rootID),
                  let state = rootStatesByID[file.rootID],
                  fact.pathRoundTripsToSelf
            else {
                requestIssues.append(WorkspaceCodemapStructureIssueRecord(
                    code: "path_not_found",
                    phase: "seed_resolution",
                    path: nil,
                    retryable: false,
                    retryAfterMilliseconds: nil,
                    attempted: nil,
                    limit: nil,
                    message: "A requested seed is no longer available in the captured root scope."
                ))
                continue
            }
            let rootEpoch = WorkspaceCodemapRootEpoch(
                rootID: file.rootID,
                rootLifetimeID: state.lifetimeID
            )
            seedsByRootEpoch[rootEpoch, default: []].append(fileID)
            seedPathsByFileID[fileID] = WorkspaceCodemapLogicalPresentationPath(
                rootDisplayName: rootLabels[file.rootID] ?? state.root.name,
                standardizedRelativePath: file.standardizedRelativePath
            )?.displayPath
        }

        var remainingNodes = budget.maximumNodeCount
        var remainingEdges = budget.maximumEdgeCount
        var remainingBytes = budget.maximumGraphByteCount
        var roots: [WorkspaceCodemapStructureRootResult] = []
        for rootEpoch in seedsByRootEpoch.keys.sorted(by: codemapRootEpochPrecedes) {
            try Task.checkCancellation()
            guard let state = rootStatesByID[rootEpoch.rootID],
                  state.lifetimeID == rootEpoch.rootLifetimeID
            else { continue }
            let rootName = rootLabels[rootEpoch.rootID] ?? state.root.name
            let rootSeedIDs = (seedsByRootEpoch[rootEpoch] ?? []).sorted {
                let lhs = seedPathsByFileID[$0] ?? $0.uuidString
                let rhs = seedPathsByFileID[$1] ?? $1.uuidString
                if lhs != rhs { return lhs.utf8.lexicographicallyPrecedes(rhs.utf8) }
                return $0.uuidString < $1.uuidString
            }
            let raw: WorkspaceCodemapGraphStructureRootResult
            if remainingNodes <= 0 || remainingBytes == 0 {
                raw = await WorkspaceCodemapGraphStructureRootResult(
                    rootEpoch: rootEpoch,
                    status: .partial,
                    coverage: nil,
                    updatesPending: false,
                    reconciling: false,
                    receipt: nil,
                    // Deliberately unguarded, matching pre-refactor: no discoverability
                    // filter, no path round-trip check -- a fresh per-iteration batch
                    // fetch over `rootSeedIDs`, not a per-item table subscript.
                    seeds: {
                        let sizeLimitFacts = await inventoryRecordFacts(fileIDs: rootSeedIDs, folderIDs: []).filesByID
                        return rootSeedIDs.map {
                            WorkspaceCodemapGraphStructureSeed(
                                fileID: $0,
                                standardizedRelativePath: sizeLimitFacts[$0]?.record?.standardizedRelativePath,
                                state: .notIndexed
                            )
                        }
                    }(),
                    nodes: [],
                    edges: [],
                    unresolved: [],
                    truncation: WorkspaceCodemapGraphStructureTruncation(droppedNodeCount: rootSeedIDs.count),
                    issues: [.sizeLimit]
                )
            } else if let session = codemapSessionsByRootEpoch[rootEpoch],
                      codemapAuthorityIsCurrent(session.authority),
                      let engine = session.engine,
                      let graph = await engine.selectionGraph(rootEpoch: rootEpoch)
            {
                let capturedAuthority = session.authority
                raw = try await graph.traverseLatest(WorkspaceCodemapGraphStructureQuery(
                    seedFileIDs: rootSeedIDs,
                    direction: direction,
                    maximumDepth: maximumDepth,
                    budget: WorkspaceCodemapGraphQueryBudget(
                        maximumTokenCount: budget.maximumTokenCount,
                        maximumNodeCount: remainingNodes,
                        maximumEdgeCount: remainingEdges,
                        maximumGraphByteCount: remainingBytes,
                        graphEvidenceTokenCount: budget.graphEvidenceTokenCount,
                        renderTokenCount: budget.renderTokenCount
                    )
                ))
                if let receipt = raw.receipt {
                    let affectedFileIDs = Set(raw.nodes.map(\.fileID)).union(raw.seeds.map(\.fileID))
                    switch await graph.revalidate(receipt, affectedFileIDs: affectedFileIDs) {
                    case .valid:
                        break
                    case .invalid, .revoked:
                        roots.append(unavailableCodemapStructureRoot(
                            rootEpoch: rootEpoch,
                            rootName: rootName,
                            seedFileIDs: rootSeedIDs,
                            seedPathsByFileID: seedPathsByFileID,
                            code: "graph_revalidation_failed",
                            message: "The committed graph changed across a destructive safety boundary."
                        ))
                        continue
                    }
                }
                guard codemapSessionsByRootEpoch[rootEpoch]?.authority == capturedAuthority else {
                    roots.append(partialCodemapStructureRoot(
                        raw,
                        rootName: rootName,
                        seedPathsByFileID: seedPathsByFileID,
                        additionalIssue: WorkspaceCodemapStructureIssueRecord(
                            code: "updates_pending",
                            phase: "graph_revalidation",
                            path: nil,
                            retryable: true,
                            retryAfterMilliseconds: 100,
                            attempted: nil,
                            limit: nil,
                            message: "The root advanced while its committed graph result was being assembled."
                        )
                    ))
                    continue
                }
            } else {
                let isNonGit = terminalNonGitCodemapCacheByEpoch[rootEpoch] != nil
                roots.append(WorkspaceCodemapStructureRootResult(
                    rootEpoch: rootEpoch,
                    rootDisplayName: rootName,
                    status: isNonGit ? .unavailable : .pending,
                    coverage: nil,
                    updatesPending: !isNonGit,
                    seeds: rootSeedIDs.map {
                        WorkspaceCodemapStructureSeedResult(
                            fileID: $0,
                            path: seedPathsByFileID[$0] ?? rootName,
                            state: isNonGit ? .notIndexed : .pending
                        )
                    },
                    nodes: [],
                    edges: [],
                    unresolved: [],
                    truncation: nil,
                    issues: [WorkspaceCodemapStructureIssueRecord(
                        code: isNonGit ? "git_root_unavailable" : "graph_indexing",
                        phase: "graph_snapshot",
                        path: nil,
                        retryable: !isNonGit,
                        retryAfterMilliseconds: isNonGit ? nil : 100,
                        attempted: nil,
                        limit: nil,
                        message: isNonGit
                            ? "Code structure is unavailable because this root has no Git repository authority."
                            : "The root-local committed graph is still being initialized."
                    )],
                    receipt: nil
                ))
                continue
            }

            let mapped = mapCodemapStructureRoot(
                raw,
                rootName: rootName,
                seedPathsByFileID: seedPathsByFileID
            )
            roots.append(mapped)
            remainingNodes = max(0, remainingNodes - mapped.nodes.count)
            remainingEdges = max(0, remainingEdges - mapped.edges.count)
            var usedBytes = UInt64(0)
            for node in mapped.nodes {
                let nodeBytes = UInt64(node.path.utf8.count) + 96
                usedBytes = usedBytes.addingReportingOverflow(nodeBytes).overflow
                    ? .max
                    : usedBytes + nodeBytes
            }
            for edge in mapped.edges {
                var edgeBytes = UInt64(edge.fromPath.utf8.count + edge.toPath.utf8.count) + 128
                for symbol in edge.symbols {
                    edgeBytes = edgeBytes.addingReportingOverflow(UInt64(symbol.utf8.count)).overflow
                        ? .max
                        : edgeBytes + UInt64(symbol.utf8.count)
                }
                usedBytes = usedBytes.addingReportingOverflow(edgeBytes).overflow
                    ? .max
                    : usedBytes + edgeBytes
            }
            remainingBytes = usedBytes >= remainingBytes ? 0 : remainingBytes - usedBytes
        }

        let hasUsefulData = roots.contains(where: \.hasUsefulData)
        let status: WorkspaceCodemapStructureStatus = if hasUsefulData {
            requestIssues.isEmpty && roots.allSatisfy { $0.status == .ok } ? .ok : .partial
        } else if roots.contains(where: { $0.status == .pending }) {
            .pending
        } else {
            .unavailable
        }
        return WorkspaceCodemapStructureAggregateResult(
            status: status,
            roots: roots,
            issues: requestIssues
        )
    }

    func revalidateCodemapStructureGraphs(
        _ result: WorkspaceCodemapStructureAggregateResult
    ) async -> [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult] {
        var dispositions: [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult] = [:]
        for root in result.roots {
            guard let receipt = root.receipt,
                  let session = codemapSessionsByRootEpoch[root.rootEpoch],
                  codemapAuthorityIsCurrent(session.authority),
                  let engine = session.engine,
                  let graph = await engine.selectionGraph(rootEpoch: root.rootEpoch)
            else {
                if root.hasUsefulData {
                    dispositions[root.rootEpoch] = .invalid(
                        code: "graph_unavailable",
                        message: "The root-local graph is no longer available."
                    )
                }
                continue
            }
            let affectedFileIDs = Set(root.nodes.map(\.fileID)).union(root.seeds.map(\.fileID))
            switch await graph.revalidate(receipt, affectedFileIDs: affectedFileIDs) {
            case let .valid(freshness):
                dispositions[root.rootEpoch] = .valid(updatesPending: freshness != .current)
            case .invalid:
                dispositions[root.rootEpoch] = .invalid(
                    code: "graph_revalidation_failed",
                    message: "The committed graph crossed a destructive safety boundary."
                )
            case .revoked:
                dispositions[root.rootEpoch] = .invalid(
                    code: "graph_revoked",
                    message: "The root-local committed graph was revoked."
                )
            }
        }
        return dispositions
    }

    private func mapCodemapStructureRoot(
        _ raw: WorkspaceCodemapGraphStructureRootResult,
        rootName: String,
        seedPathsByFileID: [UUID: String]
    ) -> WorkspaceCodemapStructureRootResult {
        func logicalPath(fileID: UUID, relativePath: String?) -> String {
            if let seedPath = seedPathsByFileID[fileID] { return seedPath }
            guard let relativePath,
                  let path = WorkspaceCodemapLogicalPresentationPath(
                      rootDisplayName: rootName,
                      standardizedRelativePath: relativePath
                  )
            else { return rootName }
            return path.displayPath
        }
        let nodePaths = Dictionary(uniqueKeysWithValues: raw.nodes.map {
            ($0.fileID, logicalPath(fileID: $0.fileID, relativePath: $0.standardizedRelativePath))
        })
        return WorkspaceCodemapStructureRootResult(
            rootEpoch: raw.rootEpoch,
            rootDisplayName: rootName,
            status: raw.status,
            coverage: raw.coverage,
            updatesPending: raw.updatesPending,
            seeds: raw.seeds.map {
                WorkspaceCodemapStructureSeedResult(
                    fileID: $0.fileID,
                    path: logicalPath(fileID: $0.fileID, relativePath: $0.standardizedRelativePath),
                    state: $0.state
                )
            },
            nodes: raw.nodes.map {
                WorkspaceCodemapStructureNodeResult(
                    fileID: $0.fileID,
                    path: nodePaths[$0.fileID] ?? rootName,
                    depth: $0.depth,
                    isSeed: $0.isSeed,
                    reachedBy: $0.reachedBy
                )
            },
            edges: raw.edges.compactMap {
                guard let from = nodePaths[$0.sourceFileID], let to = nodePaths[$0.targetFileID] else { return nil }
                return WorkspaceCodemapStructureEdgeResult(
                    fromPath: from,
                    toPath: to,
                    symbols: $0.symbols,
                    ambiguous: $0.ambiguous
                )
            },
            unresolved: raw.unresolved.compactMap {
                guard let from = nodePaths[$0.sourceFileID] else { return nil }
                return WorkspaceCodemapStructureUnresolvedResult(
                    fromPath: from,
                    name: $0.referencedName,
                    reason: $0.reason
                )
            },
            truncation: raw.truncation,
            issues: raw.issues.map {
                codemapStructureIssueRecord(
                    $0,
                    path: { fileID in
                        logicalPath(
                            fileID: fileID,
                            relativePath: raw.seeds.first(where: { $0.fileID == fileID })?.standardizedRelativePath
                        )
                    }
                )
            },
            receipt: raw.receipt
        )
    }

    private func partialCodemapStructureRoot(
        _ raw: WorkspaceCodemapGraphStructureRootResult,
        rootName: String,
        seedPathsByFileID: [UUID: String],
        additionalIssue: WorkspaceCodemapStructureIssueRecord
    ) -> WorkspaceCodemapStructureRootResult {
        let mapped = mapCodemapStructureRoot(raw, rootName: rootName, seedPathsByFileID: seedPathsByFileID)
        return WorkspaceCodemapStructureRootResult(
            rootEpoch: mapped.rootEpoch,
            rootDisplayName: mapped.rootDisplayName,
            status: mapped.hasUsefulData ? .partial : mapped.status,
            coverage: mapped.coverage,
            updatesPending: true,
            seeds: mapped.seeds,
            nodes: mapped.nodes,
            edges: mapped.edges,
            unresolved: mapped.unresolved,
            truncation: mapped.truncation,
            issues: mapped.issues + [additionalIssue],
            receipt: mapped.receipt
        )
    }

    private func unavailableCodemapStructureRoot(
        rootEpoch: WorkspaceCodemapRootEpoch,
        rootName: String,
        seedFileIDs: [UUID],
        seedPathsByFileID: [UUID: String],
        code: String,
        message: String
    ) -> WorkspaceCodemapStructureRootResult {
        WorkspaceCodemapStructureRootResult(
            rootEpoch: rootEpoch,
            rootDisplayName: rootName,
            status: .unavailable,
            coverage: nil,
            updatesPending: false,
            seeds: seedFileIDs.map {
                WorkspaceCodemapStructureSeedResult(
                    fileID: $0,
                    path: seedPathsByFileID[$0] ?? rootName,
                    state: .notIndexed
                )
            },
            nodes: [],
            edges: [],
            unresolved: [],
            truncation: nil,
            issues: [WorkspaceCodemapStructureIssueRecord(
                code: code,
                phase: "graph_revalidation",
                path: nil,
                retryable: false,
                retryAfterMilliseconds: nil,
                attempted: nil,
                limit: nil,
                message: message
            )],
            receipt: nil
        )
    }

    private func codemapStructureIssueRecord(
        _ issue: WorkspaceCodemapGraphStructureIssue,
        path: (UUID) -> String
    ) -> WorkspaceCodemapStructureIssueRecord {
        switch issue {
        case .emptySeeds:
            .init(code: "empty_seeds", phase: "seed_resolution", path: nil, retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "No usable seed files were supplied.")
        case .updatesPending:
            .init(code: "updates_pending", phase: "graph_snapshot", path: nil, retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "The committed graph is usable but newer updates are pending.")
        case .watcherGapReconciling:
            .init(code: "watcher_gap_reconciling", phase: "graph_snapshot", path: nil, retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "The root is reconciling a watcher gap; committed graph data remains usable.")
        case .indexing:
            .init(code: "graph_indexing", phase: "graph_snapshot", path: nil, retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "The root graph is still indexing.")
        case let .seedPending(fileID):
            .init(code: "seed_pending", phase: "graph_snapshot", path: path(fileID), retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "The seed has not contributed to the committed graph yet.")
        case let .seedNotIndexed(fileID):
            .init(code: "seed_not_indexed", phase: "graph_snapshot", path: path(fileID), retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "The seed is not indexed in the committed graph.")
        case let .seedExcluded(fileID):
            .init(code: "seed_excluded", phase: "graph_snapshot", path: path(fileID), retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "The seed is excluded from codemap indexing.")
        case let .seedFenced(fileID):
            .init(code: "seed_fenced", phase: "graph_revalidation", path: path(fileID), retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "The seed crossed a destructive safety fence.")
        case .sizeLimit:
            .init(code: "graph_size_limit", phase: "graph_traversal", path: nil, retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "Graph output was deterministically truncated to fit the requested output size.")
        case .deadline:
            .init(code: "graph_deadline", phase: "graph_traversal", path: nil, retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "The fixed graph traversal deadline was reached; partial data remains usable.")
        case .graphRevoked:
            .init(code: "graph_revoked", phase: "graph_snapshot", path: nil, retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "The root-local committed graph is unavailable.")
        case .graphPending:
            .init(code: "graph_indexing", phase: "graph_snapshot", path: nil, retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "No committed graph snapshot is available yet.")
        }
    }

    private func codemapRootEpochPrecedes(
        _ lhs: WorkspaceCodemapRootEpoch,
        _ rhs: WorkspaceCodemapRootEpoch
    ) -> Bool {
        if lhs.rootID != rhs.rootID {
            return lhs.rootID.uuidString < rhs.rootID.uuidString
        }
        return lhs.rootLifetimeID.uuidString < rhs.rootLifetimeID.uuidString
    }

    func freezeCodemapPresentation(
        _ requests: [WorkspaceCodemapPresentationRequest]
    ) async -> WorkspaceCodemapPresentationFreezeDisposition {
        #if DEBUG
            codemapPresentationFreezeRequestCountForTesting += 1
        #endif
        guard !requests.isEmpty else {
            return .unavailable(.emptyRequest)
        }
        let entryLimit = Self.maximumCodemapPresentationRequestsPerBundle
        guard requests.count <= entryLimit else {
            return .unavailable(.entryLimitExceeded(limit: entryLimit))
        }

        let rootEpoch = requests[0].ticket.rootEpoch
        guard requests.allSatisfy({ $0.ticket.rootEpoch == rootEpoch }) else {
            return .unavailable(.mixedRootEpoch)
        }

        var fileIDs = Set<UUID>()
        for request in requests where !fileIDs.insert(request.ticket.fileID).inserted {
            return .unavailable(.duplicateFileID(request.ticket.fileID))
        }

        guard let originalSession = codemapSessionsByRootEpoch[rootEpoch] else {
            return .unavailable(.staleCurrentness)
        }
        let retainedLimit = Self.maximumRetainedCodemapPresentationRecordsPerRoot
        guard originalSession.presentationRecordsByID.count < retainedLimit else {
            return .unavailable(.retainedBundleLimitExceeded(limit: retainedLimit))
        }

        var pairs: [(
            entry: WorkspaceCodemapFrozenPresentationEntry,
            handle: WorkspaceCodemapLiveFrozenArtifactHandle
        )] = []
        pairs.reserveCapacity(requests.count)

        for request in requests {
            let ticket = request.ticket
            guard await codemapDemandIsCurrent(ticket),
                  let demandRecord = codemapSessionsByRootEpoch[rootEpoch]?
                  .demandsByFileID[ticket.fileID],
                  codemapTicketsShareDemand(demandRecord.ticket, ticket)
            else {
                return .unavailable(.staleCurrentness)
            }

            let ready: WorkspaceCodemapArtifactDemandReady
            switch demandRecord.result {
            case let .pending(pendingTicket):
                guard pendingTicket == ticket else {
                    return .unavailable(.staleCurrentness)
                }
                return .unavailable(.pending(ticket))
            case let .unavailable(reason):
                return .unavailable(.demandUnavailable(ticket, reason))
            case let .ready(currentReady):
                ready = currentReady
            }

            guard codemapTicketsShareDemand(ready.ticket, ticket),
                  ready.identity == demandRecord.identity,
                  ready.identity.rootID == ticket.rootEpoch.rootID,
                  ready.identity.rootLifetimeID == ticket.rootEpoch.rootLifetimeID,
                  ready.identity.fileID == ticket.fileID,
                  ready.snapshot.rootEpoch == ticket.rootEpoch,
                  ready.snapshot.fileID == ticket.fileID,
                  ready.snapshot.requestGeneration == ticket.requestGeneration
            else {
                return .unavailable(.staleCurrentness)
            }
            guard request.logicalPath.standardizedRelativePath ==
                ready.identity.standardizedRelativePath,
                request.logicalPath.standardizedRelativePath ==
                ready.snapshot.standardizedRelativePath
            else {
                return .unavailable(.logicalPathMismatch(ticket.fileID))
            }

            let artifactKey: CodeMapArtifactKey
            let outcome: WorkspaceCodemapLiveArtifactOutcome
            do {
                artifactKey = try ready.handle.artifactKey()
                outcome = try ready.handle.outcome()
            } catch {
                return .unavailable(.handleRevoked(ticket.fileID))
            }
            guard artifactKey == ready.snapshot.artifactKey,
                  outcome == ready.snapshot.outcome
            else {
                return .unavailable(.staleCurrentness)
            }

            pairs.append((
                entry: WorkspaceCodemapFrozenPresentationEntry(
                    ticket: ticket,
                    logicalPath: request.logicalPath,
                    artifactKey: artifactKey,
                    outcome: outcome
                ),
                handle: ready.handle
            ))
        }

        pairs.sort { lhs, rhs in
            let lhsPath = lhs.entry.logicalPath.displayPath
            let rhsPath = rhs.entry.logicalPath.displayPath
            if lhsPath != rhsPath {
                return lhsPath < rhsPath
            }
            return lhs.entry.ticket.fileID.uuidString < rhs.entry.ticket.fileID.uuidString
        }

        for pair in pairs {
            let entry = pair.entry
            guard await codemapDemandIsCurrent(entry.ticket),
                  let demandRecord = codemapSessionsByRootEpoch[rootEpoch]?
                  .demandsByFileID[entry.ticket.fileID],
                  case let .ready(ready) = demandRecord.result,
                  codemapPresentationReadyMatches(
                      ready,
                      demandRecord: demandRecord,
                      entry: entry
                  )
            else {
                return .unavailable(.staleCurrentness)
            }
            do {
                guard try pair.handle.artifactKey() == entry.artifactKey,
                      try pair.handle.outcome() == entry.outcome
                else {
                    return .unavailable(.staleCurrentness)
                }
            } catch {
                return .unavailable(.handleRevoked(entry.ticket.fileID))
            }
        }

        guard var currentSession = codemapSessionsByRootEpoch[rootEpoch],
              currentSession.authority == originalSession.authority,
              currentSession.presentationRecordsByID.count < retainedLimit
        else {
            return .unavailable(.staleCurrentness)
        }

        let id = WorkspaceCodemapFrozenPresentationBundleID()
        let entries = pairs.map(\.entry)
        let handles = pairs.map(\.handle)
        var callerHandles: [WorkspaceCodemapLiveFrozenArtifactHandle] = []
        callerHandles.reserveCapacity(handles.count)
        for (index, handle) in handles.enumerated() {
            do {
                try callerHandles.append(handle.retainingLease())
            } catch {
                return .unavailable(.handleRevoked(entries[index].ticket.fileID))
            }
        }
        let record = CodemapPresentationRecord(
            id: id,
            rootEpoch: rootEpoch,
            entries: entries,
            handles: handles,
            requestIDs: Set(entries.map(\.ticket.requestID))
        )
        let bundle = WorkspaceCodemapFrozenPresentationBundle(
            id: id,
            rootEpoch: rootEpoch,
            entries: entries,
            handles: callerHandles
        )
        currentSession.presentationRecordsByID[id] = record
        codemapSessionsByRootEpoch[rootEpoch] = currentSession
        return .ready(bundle)
    }

    func renderCodemapPresentation(
        _ bundle: WorkspaceCodemapFrozenPresentationBundle
    ) async -> WorkspaceCodemapPresentationRenderDisposition {
        guard let session = codemapSessionsByRootEpoch[bundle.rootEpoch],
              let record = session.presentationRecordsByID[bundle.id]
        else {
            return .unavailable(.bundleNotRetained)
        }
        guard record.id == bundle.id,
              record.rootEpoch == bundle.rootEpoch,
              record.entries == bundle.entries,
              record.entries.count == record.handles.count
        else {
            return .unavailable(.bundleMetadataMismatch)
        }

        var renderedEntries: [WorkspaceCodemapRenderedPresentationEntry] = []
        renderedEntries.reserveCapacity(record.entries.count)

        for (entry, handle) in zip(record.entries, record.handles) {
            guard await codemapDemandIsCurrent(entry.ticket),
                  let demandRecord = codemapSessionsByRootEpoch[record.rootEpoch]?
                  .demandsByFileID[entry.ticket.fileID],
                  case let .ready(ready) = demandRecord.result,
                  codemapPresentationReadyMatches(
                      ready,
                      demandRecord: demandRecord,
                      entry: entry
                  )
            else {
                return .unavailable(.staleCurrentness(entry.ticket))
            }

            do {
                guard try handle.artifactKey() == entry.artifactKey,
                      try handle.outcome() == entry.outcome
                else {
                    return .unavailable(.staleCurrentness(entry.ticket))
                }
                guard let rendered = try handle.renderedCodemap(
                    displayPath: entry.logicalPath.displayPath
                ) else {
                    return .unavailable(.noRenderableCodemap(entry.ticket.fileID))
                }
                renderedEntries.append(WorkspaceCodemapRenderedPresentationEntry(
                    ticket: entry.ticket,
                    logicalPath: entry.logicalPath,
                    artifactKey: entry.artifactKey,
                    outcome: entry.outcome,
                    text: rendered.text,
                    tokenCount: rendered.tokenCount
                ))
            } catch {
                return .unavailable(.handleRevoked(entry.ticket.fileID))
            }
        }

        for (entry, handle) in zip(record.entries, record.handles) {
            guard await codemapDemandIsCurrent(entry.ticket) else {
                return .unavailable(.staleCurrentness(entry.ticket))
            }
            do {
                guard try handle.artifactKey() == entry.artifactKey,
                      try handle.outcome() == entry.outcome
                else {
                    return .unavailable(.staleCurrentness(entry.ticket))
                }
            } catch {
                return .unavailable(.handleRevoked(entry.ticket.fileID))
            }
        }

        return .ready(renderedEntries)
    }

    func revalidateCodemapOperationPresentationForPublication(
        _ receipt: WorkspaceCodemapOperationPresentationPublicationReceipt,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspaceCodemapOperationPublicationDisposition {
        guard receipt.rootScope == rootScope else { return .stale(.rootScope) }
        let allowedRootIDs = Set(rootsForPathLookup(scope: rootScope).map(\.id))

        if receipt.completeRootSet {
            guard allowedRootIDs == Set(receipt.completeRootCatalogs.map(\.rootEpoch.rootID)) else {
                return .stale(.rootScope)
            }
            // P4-6a / B1 site 7 (id-keyed, async, D-8; full reference predicate
            // intact -- no discoverability gap here). One batched call per root scan.
            for catalog in receipt.completeRootCatalogs {
                guard let state = rootStatesByID[catalog.rootEpoch.rootID],
                      state.lifetimeID == catalog.rootEpoch.rootLifetimeID
                else { return .stale(.rootEpoch(catalog.rootEpoch)) }
                guard catalogGenerationsByRootID[catalog.rootEpoch.rootID] == catalog.catalogGeneration else {
                    return .stale(.rootEpoch(catalog.rootEpoch))
                }
                let rootFileIDs = Array(state.fileIDsByRelativePath.values)
                let rootFacts = await inventoryRecordFacts(fileIDs: rootFileIDs, folderIDs: []).filesByID
                let currentSupportedFileIDs = rootFileIDs.filter { fileID in
                    guard let fact = rootFacts[fileID], fact.isDiscoverable, let file = fact.record else { return false }
                    return SyntaxManager.supportsCodeMap(
                        fileExtension: (file.name as NSString).pathExtension
                    )
                }.sorted { $0.uuidString < $1.uuidString }
                guard currentSupportedFileIDs == catalog.supportedFileIDs else {
                    return .stale(.rootEpoch(catalog.rootEpoch))
                }
            }
        }

        // D-8: one batched call over `receipt.candidates` -- this whole function's
        // only `await` (the trailing `revalidateAutomaticCodemapSelection` call) is
        // strictly after every table read in this function, so no new staleness
        // window opens by hoisting here.
        let candidateFacts = await inventoryRecordFacts(fileIDs: receipt.candidates.map(\.fileID), folderIDs: []).filesByID
        for candidate in receipt.candidates {
            let rootEpoch = candidate.rootEpoch
            guard allowedRootIDs.contains(rootEpoch.rootID),
                  let state = rootStatesByID[rootEpoch.rootID],
                  state.lifetimeID == rootEpoch.rootLifetimeID
            else { return .stale(.rootEpoch(rootEpoch)) }
            guard catalogGenerationsByRootID[rootEpoch.rootID] == candidate.catalogGeneration,
                  let fact = candidateFacts[candidate.fileID],
                  let file = fact.record,
                  file.rootID == rootEpoch.rootID,
                  fact.isDiscoverable,
                  fact.pathRoundTripsToSelf,
                  candidate.logicalPath.rootDisplayName == (
                      receipt.logicalRootDisplayNamesByRootID[rootEpoch.rootID] ?? state.root.name
                  ),
                  candidate.logicalPath.standardizedRelativePath == file.standardizedRelativePath
            else { return .stale(.catalog(fileID: candidate.fileID)) }
        }

        for ticket in receipt.demandTickets {
            guard allowedRootIDs.contains(ticket.rootEpoch.rootID),
                  await codemapDemandIsCurrent(ticket),
                  let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
                  .demandsByFileID[ticket.fileID],
                  codemapTicketsShareDemand(record.ticket, ticket),
                  record.retainIDs.contains(ticket.retainID),
                  case let .ready(ready) = record.result,
                  codemapTicketsShareDemand(ready.ticket, ticket)
            else { return .stale(.demand(ticket)) }
        }

        for bundle in receipt.bundles {
            guard let record = codemapSessionsByRootEpoch[bundle.rootEpoch]?
                .presentationRecordsByID[bundle.bundleID],
                record.id == bundle.bundleID,
                record.rootEpoch == bundle.rootEpoch,
                record.entries.count == record.handles.count
            else {
                return .stale(.bundle(
                    rootEpoch: bundle.rootEpoch,
                    bundleID: bundle.bundleID
                ))
            }
            let retainedEntriesByFileID = Dictionary(
                uniqueKeysWithValues: zip(record.entries, record.handles).map { entry, handle in
                    (entry.ticket.fileID, (entry, handle))
                }
            )
            for entry in bundle.entries {
                guard let (retainedEntry, handle) = retainedEntriesByFileID[entry.ticket.fileID],
                      retainedEntry == entry
                else {
                    return .stale(.bundle(
                        rootEpoch: bundle.rootEpoch,
                        bundleID: bundle.bundleID
                    ))
                }
                guard let demandRecord = codemapSessionsByRootEpoch[bundle.rootEpoch]?
                    .demandsByFileID[entry.ticket.fileID],
                    demandRecord.retainIDs.contains(entry.ticket.retainID),
                    case let .ready(ready) = demandRecord.result,
                    codemapPresentationReadyMatches(
                        ready,
                        demandRecord: demandRecord,
                        entry: entry
                    )
                else {
                    return .stale(.bundle(
                        rootEpoch: bundle.rootEpoch,
                        bundleID: bundle.bundleID
                    ))
                }
                do {
                    guard try handle.artifactKey() == entry.artifactKey,
                          try handle.outcome() == entry.outcome
                    else {
                        return .stale(.bundle(
                            rootEpoch: bundle.rootEpoch,
                            bundleID: bundle.bundleID
                        ))
                    }
                } catch {
                    return .stale(.bundle(
                        rootEpoch: bundle.rootEpoch,
                        bundleID: bundle.bundleID
                    ))
                }
            }
        }

        if let automaticReceipt = receipt.automaticReceipt {
            let revalidation = await revalidateAutomaticCodemapSelection(
                automaticReceipt,
                rootScope: rootScope
            )
            guard revalidation.validTargets.count == automaticReceipt.roots.flatMap(\.targets).count else {
                return .stale(.automatic(revalidation.issues))
            }
        }
        return .current
    }

    func releaseCodemapPresentation(
        _ bundle: WorkspaceCodemapFrozenPresentationBundle
    ) -> Bool {
        guard var session = codemapSessionsByRootEpoch[bundle.rootEpoch],
              let record = session.presentationRecordsByID[bundle.id],
              record.rootEpoch == bundle.rootEpoch,
              record.entries == bundle.entries
        else {
            return false
        }
        session.presentationRecordsByID.removeValue(forKey: bundle.id)
        codemapSessionsByRootEpoch[bundle.rootEpoch] = session
        return true
    }

    func releaseReadyCodemapArtifactDemandRetain(
        _ ticket: WorkspaceCodemapArtifactDemandTicket,
        deadline: ContinuousClock.Instant? = nil
    ) async -> Bool {
        guard await codemapDemandIsCurrent(ticket),
              let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
              .demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket),
              case .ready = record.result
        else { return false }
        return await cancelCodemapArtifactDemand(ticket, deadline: deadline)
    }

    private func codemapDeadlineIsCurrent(_ deadline: ContinuousClock.Instant?) -> Bool {
        !Task.isCancelled && deadline.map { ContinuousClock.now < $0 } != false
    }

    private func waitForCodemapSharedTask(
        _ task: Task<Void, Never>,
        deadline: ContinuousClock.Instant?
    ) async -> Bool {
        guard codemapDeadlineIsCurrent(deadline) else { return false }
        guard let deadline else {
            await task.value
            return !Task.isCancelled
        }
        let completed = await withCheckedContinuation { continuation in
            let race = CodemapSharedTaskDeadlineRace(continuation)
            Task {
                await task.value
                race.resolve(ContinuousClock.now < deadline)
            }
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                race.resolve(false)
            }
        }
        return completed && codemapDeadlineIsCurrent(deadline)
    }

    func cancelCodemapArtifactDemand(
        _ ticket: WorkspaceCodemapArtifactDemandTicket,
        deadline: ContinuousClock.Instant? = nil
    ) async -> Bool {
        guard await codemapDemandIsCurrent(ticket),
              var session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              var record = session.demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket),
              record.retainIDs.remove(ticket.retainID) != nil
        else {
            return false
        }
        if !record.retainIDs.isEmpty {
            session.demandsByFileID[ticket.fileID] = record
            codemapSessionsByRootEpoch[ticket.rootEpoch] = session
            return true
        }
        if case .unavailable(.cancelled) = record.result {
            return true
        }
        let shouldRevokeReadyArtifact = if case .ready = record.result {
            true
        } else {
            false
        }

        record.task?.cancel()
        let presentationIDs = session.presentationRecordsByID.compactMap { id, presentation in
            presentation.requestIDs.contains(ticket.requestID) ? id : nil
        }
        for id in presentationIDs {
            session.presentationRecordsByID.removeValue(forKey: id)
        }
        let retainedBundle = session.bundlesByRequestID.removeValue(forKey: ticket.requestID)
        record.result = .unavailable(.cancelled)
        record.task = nil
        session.demandsByFileID[ticket.fileID] = record
        codemapSessionsByRootEpoch[ticket.rootEpoch] = session
        retainedBundle?.close()
        let cleanupTask = Task { [weak self] in
            await self?.finishCancelledCodemapArtifactDemand(
                ticket,
                record: record,
                engine: session.engine,
                shouldRevokeReadyArtifact: shouldRevokeReadyArtifact
            )
            return ()
        }
        _ = await waitForCodemapSharedTask(cleanupTask, deadline: deadline)
        return true
    }

    private func finishCancelledCodemapArtifactDemand(
        _ ticket: WorkspaceCodemapArtifactDemandTicket,
        record: CodemapDemandRecord,
        engine: WorkspaceCodemapBindingEngine?,
        shouldRevokeReadyArtifact: Bool
    ) async {
        if let engine {
            await codemapCancellationCleanupHook(ticket)
            _ = await engine.cancel(owner: record.owner)
            if shouldRevokeReadyArtifact {
                _ = await engine.revokeReadyArtifact(
                    rootEpoch: ticket.rootEpoch,
                    fileID: ticket.fileID,
                    requestGeneration: ticket.requestGeneration
                )
            }
        }
        if var currentSession = codemapSessionsByRootEpoch[ticket.rootEpoch],
           let currentRecord = currentSession.demandsByFileID[ticket.fileID],
           codemapTicketsShareDemand(currentRecord.ticket, ticket),
           currentRecord.retainIDs.isEmpty,
           case .unavailable(.cancelled) = currentRecord.result
        {
            currentSession.demandsByFileID.removeValue(forKey: ticket.fileID)
            codemapSessionsByRootEpoch[ticket.rootEpoch] = currentSession
        }
    }

    #if DEBUG
        struct CodemapPresentationOperationCounts: Equatable {
            let selectedMetadataResolutionRequests: Int
            let presentationCandidateRequests: Int
            let artifactDemandRequests: Int
            let presentationFreezeRequests: Int
            let setupTasksCreated: Int
            let demandTasksCreated: Int
            let targetedReadyFreezes: Int
            let fullRootGraphFreezes: Int
        }

        func setCodemapPathInvalidationStageHandlerForTesting(
            _ handler: (@Sendable (WorkspaceCodemapRootEpoch, UUID, CodemapPathInvalidationStage) async -> Void)?
        ) {
            codemapPathInvalidationStageHandlerForTesting = handler
        }

        func codemapPathQuiescenceWaiterCountForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> Int {
            codemapPathQuiescenceWaitersByRootEpoch[rootEpoch]?.count ?? 0
        }

        func codemapPathFenceCountForTesting(rootID: UUID, relativePath: String) -> Int {
            let path = StandardizedPath.relative(relativePath)
            return codemapPathFenceTokensByID.values.count { token in
                token.rootEpoch.rootID == rootID && token.standardizedRelativePaths.contains(path)
            }
        }

        func discardedCodemapPathFenceReleaseCountForTesting() -> Int {
            discardedCodemapPathFenceReleaseCounterForTesting
        }

        func pendingCodemapGraphIndexRescheduleCountForTesting() -> Int {
            codemapGraphIndexBuildReschedulePendingRootEpochs.count
        }

        func revokeReadyCodemapArtifactContributionForTesting(
            _ ticket: WorkspaceCodemapArtifactDemandTicket
        ) async -> Bool {
            guard await codemapDemandIsCurrent(ticket),
                  let engine = codemapSessionsByRootEpoch[ticket.rootEpoch]?.engine
            else { return false }
            return await engine.revokeReadyArtifact(
                rootEpoch: ticket.rootEpoch,
                fileID: ticket.fileID,
                requestGeneration: ticket.requestGeneration
            )
        }

        func codemapPresentationOperationCountsForTesting() -> CodemapPresentationOperationCounts {
            CodemapPresentationOperationCounts(
                selectedMetadataResolutionRequests: codeStructureSelectedMetadataResolutionRequestCountForTesting,
                presentationCandidateRequests: codemapPresentationCandidateRequestCountForTesting,
                artifactDemandRequests: codemapArtifactDemandRequestCountForTesting,
                presentationFreezeRequests: codemapPresentationFreezeRequestCountForTesting,
                setupTasksCreated: codemapSetupTaskCreationCountForTesting,
                demandTasksCreated: codemapDemandTaskCreationCountForTesting,
                targetedReadyFreezes: codemapTargetedReadyFreezeCountForTesting,
                fullRootGraphFreezes: codemapFullRootGraphFreezeCountForTesting
            )
        }

        func resetFilesInRootRequestCountForTesting() {
            filesInRootRequestCountForTesting = 0
        }

        /// P4-7a phase a3 byte-accounting done-when: reset before a `.suggestion`-routed
        /// `AgentFileTagSuggestionService.suggestions(for:)` call, then assert
        /// `searchCatalogSnapshotRequestCountForTesting()` is still zero afterward.
        func resetSearchCatalogSnapshotRequestCountForTesting() {
            searchCatalogSnapshotCallCountForTesting = 0
        }

        func searchCatalogSnapshotRequestCountForTesting() -> Int {
            searchCatalogSnapshotCallCountForTesting
        }

        func fileEnumerationRequestCountForTesting() -> Int {
            filesInRootRequestCountForTesting
        }

        func resetAppliedIndexRecordLookupDiagnosticsForTesting() {
            appliedIndexRecordLookupRequestCountForTesting = 0
            appliedIndexRecordLookupRequestedRecordCountForTesting = 0
            appliedIndexRootSnapshotRequestCountForTesting = 0
        }

        func appliedIndexRecordLookupDiagnosticsForTesting() -> (
            lookupRequests: Int,
            requestedRecords: Int,
            rootSnapshots: Int
        ) {
            (
                lookupRequests: appliedIndexRecordLookupRequestCountForTesting,
                requestedRecords: appliedIndexRecordLookupRequestedRecordCountForTesting,
                rootSnapshots: appliedIndexRootSnapshotRequestCountForTesting
            )
        }

        func codemapArtifactDemandRetainCountForTesting(
            _ ticket: WorkspaceCodemapArtifactDemandTicket
        ) -> Int {
            guard let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
                .demandsByFileID[ticket.fileID],
                codemapTicketsShareDemand(record.ticket, ticket)
            else { return 0 }
            return record.retainIDs.count
        }

        func codemapArtifactDemandWaiterCountForTesting(
            _ ticket: WorkspaceCodemapArtifactDemandTicket
        ) -> Int {
            guard let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
                .demandsByFileID[ticket.fileID],
                codemapTicketsShareDemand(record.ticket, ticket)
            else { return 0 }
            return record.completion.waiterCount
        }

        func waitForCodemapArtifactDemandCompletionForTesting(
            _ ticket: WorkspaceCodemapArtifactDemandTicket
        ) async -> WorkspaceCodemapArtifactDemandResult {
            guard await codemapDemandIsCurrent(ticket),
                  let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
                  .demandsByFileID[ticket.fileID],
                  codemapTicketsShareDemand(record.ticket, ticket),
                  record.retainIDs.contains(ticket.retainID)
            else {
                return .unavailable(.staleCurrentness)
            }
            let current = codemapDemandResult(record.result, for: ticket)
            guard case .pending = current, record.task != nil else {
                return current
            }
            await record.completion.wait()
            return await codemapArtifactDemandStatus(ticket)
        }

        func codemapArtifactDemandRetainCountForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch,
            fileID: UUID
        ) -> Int {
            codemapSessionsByRootEpoch[rootEpoch]?.demandsByFileID[fileID]?.retainIDs.count ?? 0
        }

        struct CodemapArtifactDemandCleanupSnapshot: Equatable {
            let demandRecordPresent: Bool
            let bundlePresent: Bool
            let ownerCount: Int
            let liveOverlayPresent: Bool
        }

        func codemapArtifactDemandCleanupSnapshotForTesting(
            _ ticket: WorkspaceCodemapArtifactDemandTicket
        ) async -> CodemapArtifactDemandCleanupSnapshot {
            let session = codemapSessionsByRootEpoch[ticket.rootEpoch]
            let demandRecordPresent = session?.demandsByFileID[ticket.fileID] != nil
            let bundlePresent = session?.bundlesByRequestID[ticket.requestID] != nil
            let engine = session?.engine
            let ownerCount = await engine?.accounting().ownerCount ?? 0
            let liveBundle = await engine?.freezeReadyArtifact(
                rootEpoch: ticket.rootEpoch,
                fileID: ticket.fileID,
                requestGeneration: ticket.requestGeneration
            )
            let liveOverlayPresent = liveBundle != nil
            liveBundle?.close()
            return CodemapArtifactDemandCleanupSnapshot(
                demandRecordPresent: demandRecordPresent,
                bundlePresent: bundlePresent,
                ownerCount: ownerCount,
                liveOverlayPresent: liveOverlayPresent
            )
        }

        func codemapPresentationRetainCountForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> Int {
            codemapSessionsByRootEpoch[rootEpoch]?.presentationRecordsByID.count ?? 0
        }
    #endif

    private func performCodemapSetup(
        authority: CodemapRootAuthority
    ) async -> CodemapSetupDisposition {
        guard codemapAuthorityIsCurrent(authority) else {
            return .unavailable(.staleCurrentness)
        }

        let runtime: CodeMapArtifactRuntime
        do {
            runtime = try codemapRuntimeProvider()
        } catch {
            let disposition = CodemapSetupDisposition.unavailable(.runtimeFailure)
            publishCodemapSetupDisposition(disposition, authority: authority)
            return disposition
        }
        guard codemapAuthorityIsCurrent(authority), !Task.isCancelled else {
            return .unavailable(.staleCurrentness)
        }

        let endpoint = WorkspaceCodemapBindingIntegrationEndpoint(
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { [weak self] identity, fingerprint, maximumBytes, ownerID in
                guard let self else {
                    throw WorkspaceCodemapBindingIntegrationRoutingError.routeDetached(
                        WorkspaceCodemapRootEpoch(
                            rootID: identity.rootID,
                            rootLifetimeID: identity.rootLifetimeID
                        )
                    )
                }
                return try await readCodemapSource(
                    identity: identity,
                    expectedFingerprint: fingerprint,
                    maximumBytes: maximumBytes,
                    ownerID: ownerID,
                    authority: authority
                )
            },
            catalogClient: WorkspaceCodemapBindingCatalogClient { [weak self] rootEpoch, relativePath in
                guard let self else { return nil }
                return await codemapManifestCandidate(
                    rootEpoch: rootEpoch,
                    relativePath: relativePath,
                    authority: authority
                )
            } readGraphIndexCatalogPage: { [weak self] request in
                guard let self else { return .unavailable(.rootNotCurrent) }
                return await readCodemapGraphIndexCatalogPage(
                    request,
                    authority: authority
                )
            } revalidateGraphIndexCatalogToken: { [weak self] rootEpoch, token in
                guard let self else { return .unavailable(.rootNotCurrent) }
                return await revalidateCodemapGraphIndexCatalogToken(
                    rootEpoch: rootEpoch,
                    token: token,
                    authority: authority
                )
            } publishMarkerReadiness: { [weak self] update in
                guard let self else { return false }
                return await acceptCodemapMarkerReadinessUpdate(
                    update,
                    authority: authority
                )
            }
        )
        let registry = runtime.bindingIntegrationRegistry
        guard let routeToken = await registry.register(
            rootEpoch: authority.rootEpoch,
            endpoint: endpoint
        ) else {
            let disposition = CodemapSetupDisposition.unavailable(.routeConflict)
            publishCodemapSetupDisposition(disposition, authority: authority)
            return disposition
        }
        guard codemapAuthorityIsCurrent(authority), !Task.isCancelled else {
            _ = await registry.unregister(routeToken)
            return .unavailable(.staleCurrentness)
        }

        codemapSessionsByRootEpoch[authority.rootEpoch]?.endpoint = endpoint
        codemapSessionsByRootEpoch[authority.rootEpoch]?.routeToken = routeToken
        codemapSessionsByRootEpoch[authority.rootEpoch]?.runtime = runtime

        let engine: WorkspaceCodemapBindingEngine
        do {
            engine = try runtime.bindingEngine()
        } catch {
            _ = await registry.unregister(routeToken)
            if codemapAuthorityIsCurrent(authority) {
                codemapSessionsByRootEpoch[authority.rootEpoch]?.endpoint = nil
                codemapSessionsByRootEpoch[authority.rootEpoch]?.routeToken = nil
                codemapSessionsByRootEpoch[authority.rootEpoch]?.runtime = nil
            }
            let disposition = CodemapSetupDisposition.unavailable(.runtimeFailure)
            publishCodemapSetupDisposition(disposition, authority: authority)
            return disposition
        }
        guard codemapAuthorityIsCurrent(authority), !Task.isCancelled else {
            _ = await registry.unregister(routeToken)
            await fenceLateCodemapSetup(engine: engine, authority: authority)
            return .unavailable(.staleCurrentness)
        }
        codemapSessionsByRootEpoch[authority.rootEpoch]?.engine = engine

        let registration = WorkspaceCodemapBindingRootRegistration(
            rootID: authority.rootEpoch.rootID,
            rootLifetimeID: authority.rootEpoch.rootLifetimeID,
            loadedRootURL: URL(fileURLWithPath: authority.standardizedRootPath, isDirectory: true),
            catalogGeneration: authority.catalogGeneration,
            ingressGeneration: authority.ingressGeneration
        )
        let rootSelectionGraph = selectionGraphFactory.make(rootEpoch: authority.rootEpoch)
        let registrationResult = await engine.registerRoot(
            registration,
            selectionGraph: rootSelectionGraph
        )
        guard codemapAuthorityIsCurrent(authority), !Task.isCancelled else {
            _ = await registry.unregister(routeToken)
            await fenceLateCodemapSetup(engine: engine, authority: authority)
            return .unavailable(.staleCurrentness)
        }

        let disposition: CodemapSetupDisposition = switch registrationResult {
        case .registered, .exactDuplicate:
            .ready
        case let .unavailable(state):
            switch state {
            case let .terminalUnavailable(reason):
                .unavailable(.gitTerminal(reason))
            case let .transientUnavailable(reason, _):
                .unavailable(.gitTransient(reason))
            case .unresolved, .resolving, .eligible:
                .unavailable(.registrationFailed)
            }
        case .busy:
            .unavailable(.busy(retryAfterMilliseconds: nil))
        case .failed:
            .unavailable(.registrationFailed)
        }
        publishCodemapSetupDisposition(disposition, authority: authority)
        if case .ready = disposition {
            if let graph = await engine.selectionGraph(rootEpoch: authority.rootEpoch),
               graph === rootSelectionGraph,
               var session = codemapSessionsByRootEpoch[authority.rootEpoch],
               session.authority == authority,
               session.engine === engine
            {
                session.selectionGraph = graph
                codemapSessionsByRootEpoch[authority.rootEpoch] = session
            }
            startCodemapGraphStatusObserver(authority: authority, engine: engine)
        }
        return disposition
    }

    private func startCodemapGraphStatusObserver(
        authority: CodemapRootAuthority,
        engine: WorkspaceCodemapBindingEngine
    ) {
        guard var session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority,
              session.engine === engine
        else { return }
        session.graphStatusTask?.cancel()
        session.graphWorkerRecoveryStatusTask?.cancel()
        let task = Task { [weak self] in
            guard let graph = await engine.selectionGraph(rootEpoch: authority.rootEpoch) else { return }
            let stream = await graph.statusUpdates()
            for await accounting in stream {
                guard !Task.isCancelled else { return }
                await self?.acceptCodemapGraphStatus(
                    accounting,
                    authority: authority,
                    engine: engine,
                    graph: graph
                )
            }
        }
        session.graphStatusTask = task
        session.graphWorkerRecoveryStatusTask = Task { [weak self] in
            let stream = await engine.graphIndexWorkerRecoveryUpdates(rootEpoch: authority.rootEpoch)
            for await state in stream {
                guard !Task.isCancelled else { return }
                await self?.acceptCodemapGraphIndexWorkerRecoveryState(
                    state,
                    authority: authority,
                    engine: engine
                )
            }
        }
        codemapSessionsByRootEpoch[authority.rootEpoch] = session
    }

    private func acceptCodemapGraphStatus(
        _ accounting: WorkspaceCodemapGraphIncrementalAccounting,
        authority: CodemapRootAuthority,
        engine: WorkspaceCodemapBindingEngine,
        graph: WorkspaceCodemapSelectionGraph
    ) {
        guard let session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority,
              session.engine === engine,
              session.selectionGraph === graph,
              codemapAuthorityIsCurrent(authority)
        else { return }
        codemapGraphAccountingByRootEpoch[authority.rootEpoch] = accounting
        publishCodemapRootStatusesIfChanged()
    }

    private func acceptCodemapGraphIndexWorkerRecoveryState(
        _ state: WorkspaceCodemapGraphIndexWorkerRecoveryState,
        authority: CodemapRootAuthority,
        engine: WorkspaceCodemapBindingEngine
    ) {
        guard let session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority,
              session.engine === engine,
              codemapAuthorityIsCurrent(authority)
        else { return }
        let changed = switch state {
        case .available:
            codemapGraphIndexWorkerRecoveryExhaustedRootEpochs.remove(authority.rootEpoch) != nil
        case .exhausted:
            codemapGraphIndexWorkerRecoveryExhaustedRootEpochs.insert(authority.rootEpoch).inserted
        }
        if changed {
            publishCodemapRootStatusesIfChanged()
        }
    }

    private func performCodemapDemand(
        ticket: WorkspaceCodemapArtifactDemandTicket,
        priority: CodeMapArtifactBuildPriority
    ) async {
        guard await codemapDemandIsCurrent(ticket),
              let session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              let record = session.demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket)
        else { return }

        let setupDisposition: CodemapSetupDisposition = if let existing = session.setupDisposition {
            existing
        } else if let setupTask = session.setupTask {
            await setupTask.value
        } else {
            .unavailable(.runtimeFailure)
        }

        guard await codemapDemandIsCurrent(ticket), !Task.isCancelled,
              let refreshedSession = codemapSessionsByRootEpoch[ticket.rootEpoch],
              let refreshedRecord = refreshedSession.demandsByFileID[ticket.fileID],
              refreshedRecord.ticket == ticket
        else { return }

        switch setupDisposition {
        case let .unavailable(reason):
            await publishCodemapDemandResult(.unavailable(reason), ticket: ticket)
            return
        case .ready:
            break
        }
        guard let engine = refreshedSession.engine else {
            await publishCodemapDemandResult(.unavailable(.runtimeFailure), ticket: ticket)
            return
        }

        let engineResult = await engine.demand(WorkspaceCodemapBindingDemand(
            owner: refreshedRecord.owner,
            identity: refreshedRecord.identity,
            requestGeneration: ticket.requestGeneration,
            catalogGeneration: ticket.catalogGeneration,
            pathGeneration: ticket.pathGeneration,
            ingressGeneration: ticket.ingressGeneration,
            priority: priority,
            language: refreshedRecord.language
        ))
        let result = await codemapDemandResultHook(ticket, engineResult)
        guard await codemapDemandIsCurrent(ticket), !Task.isCancelled else { return }

        switch result {
        case let .ready(snapshot), let .alreadyReady(snapshot):
            await publishCodemapReady(
                snapshot: snapshot,
                engine: engine,
                ticket: ticket
            )
        case let .unavailable(reason):
            await publishCodemapDemandResult(
                .unavailable(.demandUnavailable(reason)),
                ticket: ticket
            )
        case let .busy(retryAfterMilliseconds):
            await publishCodemapDemandResult(
                .unavailable(.busy(retryAfterMilliseconds: retryAfterMilliseconds)),
                ticket: ticket
            )
        case .rejected(.staleCompletion):
            await publishCodemapDemandResult(.unavailable(.staleCurrentness), ticket: ticket)
        case let .rejected(rejection):
            await publishCodemapDemandResult(
                .unavailable(.rejected(rejection)),
                ticket: ticket
            )
        case .cancelled:
            await publishCodemapDemandResult(.unavailable(.cancelled), ticket: ticket)
        }
    }

    private func publishCodemapReady(
        snapshot: WorkspaceCodemapLiveReadySnapshot,
        engine: WorkspaceCodemapBindingEngine,
        ticket: WorkspaceCodemapArtifactDemandTicket
    ) async {
        guard await codemapDemandIsCurrent(ticket),
              let record = codemapSessionsByRootEpoch[ticket.rootEpoch]?
              .demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket)
        else { return }

        await codemapReadyPublicationHook(ticket)
        #if DEBUG
            codemapTargetedReadyFreezeCountForTesting += 1
        #endif
        guard let bundle = await engine.freezeReadyArtifact(
            rootEpoch: ticket.rootEpoch,
            fileID: ticket.fileID,
            requestGeneration: ticket.requestGeneration
        ) else {
            await publishCodemapDemandResult(.unavailable(.staleCurrentness), ticket: ticket)
            return
        }
        guard await codemapDemandIsCurrent(ticket),
              bundle.rootEpoch == ticket.rootEpoch,
              bundle.catalogGeneration == ticket.catalogGeneration,
              snapshot.rootEpoch == ticket.rootEpoch,
              snapshot.fileID == ticket.fileID,
              snapshot.standardizedRelativePath == record.identity.standardizedRelativePath,
              snapshot.requestGeneration == ticket.requestGeneration,
              let frozenSnapshot = try? bundle.snapshot().first(where: {
                  $0.fileID == ticket.fileID &&
                      $0.standardizedRelativePath == record.identity.standardizedRelativePath &&
                      $0.requestGeneration == ticket.requestGeneration &&
                      $0.artifactKey == snapshot.artifactKey
              }),
              frozenSnapshot == snapshot,
              let handle = try? bundle.handle(for: ticket.fileID),
              (try? handle.artifactKey()) == snapshot.artifactKey
        else {
            bundle.close()
            if await codemapDemandIsCurrent(ticket) {
                await publishCodemapDemandResult(.unavailable(.staleCurrentness), ticket: ticket)
            }
            return
        }

        guard var session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              session.demandsByFileID[ticket.fileID]?.ticket == ticket
        else {
            bundle.close()
            return
        }
        session.bundlesByRequestID[ticket.requestID] = bundle
        codemapSessionsByRootEpoch[ticket.rootEpoch] = session

        let ready = WorkspaceCodemapArtifactDemandReady(
            ticket: ticket,
            identity: record.identity,
            snapshot: snapshot,
            handle: handle
        )
        guard await publishCodemapDemandResult(.ready(ready), ticket: ticket) else {
            codemapSessionsByRootEpoch[ticket.rootEpoch]?
                .bundlesByRequestID.removeValue(forKey: ticket.requestID)
            bundle.close()
            return
        }
    }

    private func fenceLateCodemapSetup(
        engine: WorkspaceCodemapBindingEngine,
        authority: CodemapRootAuthority
    ) async {
        if codemapAuthorityMatchesLoadedRoot(authority) {
            _ = await engine.invalidateRepositoryAuthority(rootEpoch: authority.rootEpoch)
        } else {
            await engine.unloadRoot(rootEpoch: authority.rootEpoch)
        }
    }

    private func publishCodemapSetupDisposition(
        _ disposition: CodemapSetupDisposition,
        authority: CodemapRootAuthority
    ) {
        guard codemapAuthorityIsCurrent(authority) else { return }
        codemapSessionsByRootEpoch[authority.rootEpoch]?.setupDisposition = disposition
        codemapSessionsByRootEpoch[authority.rootEpoch]?.setupTask = nil
    }

    @discardableResult
    private func publishCodemapDemandResult(
        _ result: WorkspaceCodemapArtifactDemandResult,
        ticket: WorkspaceCodemapArtifactDemandTicket
    ) async -> Bool {
        guard await codemapDemandIsCurrent(ticket),
              var session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              var record = session.demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket)
        else { return false }
        record.result = result
        record.task = nil
        session.demandsByFileID[ticket.fileID] = record
        codemapSessionsByRootEpoch[ticket.rootEpoch] = session
        return true
    }

    private func codemapGraphIndexCatalogShardAndToken(
        authority: CodemapRootAuthority
    ) -> (shard: RootCatalogShard, token: WorkspaceCodemapGraphIndexCatalogToken)? {
        guard codemapAuthorityIsCurrent(authority),
              let state = rootStatesByID[authority.rootEpoch.rootID],
              state.lifetimeID == authority.rootEpoch.rootLifetimeID,
              state.root.standardizedFullPath == authority.standardizedRootPath,
              let shard = publishedRootCatalogShardsByRootID[authority.rootEpoch.rootID],
              shard.key.rootID == authority.rootEpoch.rootID,
              shard.key.lifetimeID == authority.rootEpoch.rootLifetimeID,
              shard.root.id == authority.rootEpoch.rootID,
              shard.root.standardizedFullPath == authority.standardizedRootPath,
              shard.key.canonicalConfigurationIdentity.canonicalPath == authority.standardizedRootPath,
              catalogGenerationsByRootID[authority.rootEpoch.rootID] != nil
        else { return nil }
        return (
            shard,
            WorkspaceCodemapGraphIndexCatalogToken(
                rootEpoch: authority.rootEpoch,
                topologyGeneration: shard.key.topologyGeneration,
                appliedIndexGeneration: shard.appliedIndexGeneration,
                catalogGeneration: authority.catalogGeneration,
                ingressGeneration: authority.ingressGeneration,
                graphIndexInvalidationGeneration:
                codemapGraphIndexInvalidationGenerationsByRootEpoch[authority.rootEpoch] ?? 1
            )
        )
    }

    private func advanceCodemapGraphIndexInvalidationGeneration(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        let current = codemapGraphIndexInvalidationGenerationsByRootEpoch[rootEpoch] ?? 1
        codemapGraphIndexInvalidationGenerationsByRootEpoch[rootEpoch] = current == .max
            ? 0
            : current + 1
    }

    private func codemapGraphIndexCatalogIsFenced(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        codemapPathFenceTokensByID.values.contains { $0.rootEpoch == rootEpoch }
            || codemapRootMutationFenceTokensByRootEpoch[rootEpoch] != nil
            || codemapPathInvalidationFlightsByRootEpoch[rootEpoch] != nil
            || (codemapPathLocalCatalogMutationDepthByRootID[rootEpoch.rootID] ?? 0) > 0
    }

    private func ensureCodemapGraphIndexCatalogShard(
        authority: CodemapRootAuthority
    ) async -> Bool {
        for _ in 0 ..< 2 {
            if codemapGraphIndexCatalogShardAndToken(authority: authority) != nil {
                return true
            }
            guard let snapshot = await codemapGraphIndexCatalogShardBuildSnapshot(authority: authority) else {
                return false
            }
            #if DEBUG
                let buildHandler = codemapGraphIndexCatalogBuildHandler
            #endif
            let shard = await Task.detached(priority: .userInitiated) { [snapshot] in
                #if DEBUG
                    if let buildHandler {
                        await buildHandler(snapshot.authority.rootEpoch)
                    }
                #endif
                return Self.buildCodemapGraphIndexCatalogShard(snapshot: snapshot)
            }.value
            guard !Task.isCancelled else { return false }
            switch publishCodemapGraphIndexCatalogShard(shard, snapshot: snapshot) {
            case .ready:
                return true
            case .retry:
                continue
            case .unavailable:
                return false
            }
        }
        return codemapGraphIndexCatalogShardAndToken(authority: authority) != nil
    }

    /// P4-6a / B2 (the projected-shard call shape, design §4.3.1's "other two codemap
    /// shapes"). `codemapGraphIndexCatalogShardBuildSnapshot` (actor-isolated capture)
    /// and `buildCodemapGraphIndexCatalogShard` (nonisolated static, run inside
    /// `Task.detached` by `ensureCodemapGraphIndexCatalogShard` above) together are the
    /// "single projected-shard function" this step's remit describes; they are
    /// deliberately NOT merged into one Swift function, because doing so would
    /// collapse the actor-isolated/off-actor split the design calls out as essential
    /// ("the sort/filter/projection work happens off the actor" -- §4.3.1; "this site
    /// ... must not be serialized behind an in-flight authoritative rebuild" -- §5.2).
    /// This snapshot capture already reads each root's full table in one synchronous
    /// pass (no per-item guard chain to route through a fact primitive -- there is no
    /// predicate here, only a whole-root materialization), so it is left as-is; the
    /// pair is documented together as this step's B2 read-shape boundary. Swift stays
    /// authoritative; the future `inventoryOpenProjectedShard` delegation point is
    /// exactly this pair's call site (`ensureCodemapGraphIndexCatalogShard`).
    private func codemapGraphIndexCatalogShardBuildSnapshot(
        authority: CodemapRootAuthority
    ) async -> CodemapGraphIndexCatalogShardBuildSnapshot? {
        guard codemapAuthorityIsCurrent(authority),
              !codemapGraphIndexCatalogIsFenced(rootEpoch: authority.rootEpoch),
              let state = rootStatesByID[authority.rootEpoch.rootID],
              state.lifetimeID == authority.rootEpoch.rootLifetimeID,
              state.root.standardizedFullPath == authority.standardizedRootPath,
              let key = rootCatalogShardKey(for: state.root),
              let appliedIndexGeneration = appliedIndexGenerationsByRootID[authority.rootEpoch.rootID],
              let pageIndex = await fetchFileTreePageIndex(rootID: authority.rootEpoch.rootID)
        else { return nil }
        guard codemapAuthorityIsCurrent(authority),
              !codemapGraphIndexCatalogIsFenced(rootEpoch: authority.rootEpoch)
        else { return nil }
        return CodemapGraphIndexCatalogShardBuildSnapshot(
            authority: authority,
            key: key,
            root: state.root,
            appliedIndexGeneration: appliedIndexGeneration,
            graphIndexInvalidationGeneration:
            codemapGraphIndexInvalidationGenerationsByRootEpoch[authority.rootEpoch] ?? 1,
            files: Array(pageIndex.filesByID.values),
            folders: Array(pageIndex.foldersByID.values),
            managedOnlyFileIDs: managedOnlyFileIDs,
            managedOnlyFolderIDs: managedOnlyFolderIDs
        )
    }

    private nonisolated static func buildCodemapGraphIndexCatalogShard(
        snapshot: CodemapGraphIndexCatalogShardBuildSnapshot
    ) -> RootCatalogShard {
        let files = snapshot.files
            .filter { !snapshot.managedOnlyFileIDs.contains($0.id) }
            .sorted(by: WorkspaceInventoryOrdering.searchRootCatalogFilePrecedes)
        let folders = snapshot.folders
            .filter { !snapshot.managedOnlyFolderIDs.contains($0.id) }
            .sorted(by: WorkspaceInventoryOrdering.searchCatalogFolderPrecedes)
        let entries = files.map { WorkspaceSearchCatalogEntry(file: $0, root: snapshot.root) }
        let syntaxManager = SyntaxManager()
        let projectionFiles = files.compactMap { file -> RootCatalogProjectionFile? in
            let fileExtension = (file.name as NSString).pathExtension
            guard SyntaxManager.supportsCodeMap(fileExtension: fileExtension),
                  let language = syntaxManager.language(forFileExtension: fileExtension)
            else { return nil }
            return RootCatalogProjectionFile(file: file, language: language)
        }
        return RootCatalogShard(
            key: snapshot.key,
            root: snapshot.root,
            files: files,
            precomputedProjectionFiles: projectionFiles,
            folders: folders,
            entries: entries,
            appliedIndexGeneration: snapshot.appliedIndexGeneration
        )
    }

    private func publishCodemapGraphIndexCatalogShard(
        _ shard: RootCatalogShard,
        snapshot: CodemapGraphIndexCatalogShardBuildSnapshot
    ) -> CodemapGraphIndexCatalogShardPublicationDisposition {
        if codemapGraphIndexCatalogShardAndToken(authority: snapshot.authority) != nil {
            return .ready
        }
        guard codemapAuthorityIsCurrent(snapshot.authority),
              !codemapGraphIndexCatalogIsFenced(rootEpoch: snapshot.authority.rootEpoch),
              let state = rootStatesByID[snapshot.authority.rootEpoch.rootID],
              state.lifetimeID == snapshot.authority.rootEpoch.rootLifetimeID,
              state.root.standardizedFullPath == snapshot.authority.standardizedRootPath,
              rootCatalogShardKey(for: state.root) == snapshot.key,
              appliedIndexGenerationsByRootID[snapshot.authority.rootEpoch.rootID]
              == snapshot.appliedIndexGeneration,
              (codemapGraphIndexInvalidationGenerationsByRootEpoch[snapshot.authority.rootEpoch] ?? 1)
              == snapshot.graphIndexInvalidationGeneration
        else {
            return codemapAuthorityIsCurrent(snapshot.authority) ? .retry : .unavailable
        }
        guard canPublishAnotherRootCatalogShard(rootID: snapshot.authority.rootEpoch.rootID) else {
            return .unavailable
        }
        publishedRootCatalogShardsByRootID[snapshot.authority.rootEpoch.rootID] = shard
        rootCatalogShardDeltaStatesByRootID[snapshot.authority.rootEpoch.rootID] = RootCatalogShardDeltaState(
            lifetimeID: snapshot.authority.rootEpoch.rootLifetimeID,
            lastAppliedIndexGeneration: snapshot.appliedIndexGeneration,
            isDirty: false,
            capability: .recordsOnly
        )
        registerPublishedRootCatalogShard(shard, kind: .authoritative)
        publishCodemapRootStatusesIfChanged()
        return .ready
    }

    private func readCodemapGraphIndexCatalogPage(
        _ request: WorkspaceCodemapGraphIndexCatalogPageRequest,
        authority: CodemapRootAuthority
    ) async -> WorkspaceCodemapGraphIndexCatalogPageDisposition {
        guard request.rootEpoch == authority.rootEpoch else { return .stale }
        guard request.cursor == nil || request.token != nil else { return .stale }
        guard codemapAuthorityIsCurrent(authority) else { return .stale }
        if codemapGraphIndexCatalogIsFenced(rootEpoch: authority.rootEpoch) {
            return request.token == nil ? .unavailable(.catalogNotReady) : .stale
        }
        guard await ensureCodemapGraphIndexCatalogShard(authority: authority) else {
            return codemapAuthorityIsCurrent(authority)
                ? .unavailable(.catalogNotReady)
                : .stale
        }
        guard let current = codemapGraphIndexCatalogShardAndToken(authority: authority) else {
            return .unavailable(.catalogNotReady)
        }
        guard request.token == nil || request.token == current.token else { return .stale }
        guard let session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority
        else { return .stale }

        let startIndex: Int
        if let cursor = request.cursor {
            guard let cursorIndex = current.shard.projectionFileIndexByID[cursor.fileID],
                  current.shard.projectionFiles[cursorIndex].file.standardizedRelativePath
                  == cursor.standardizedRelativePath
            else { return .stale }
            startIndex = cursorIndex + 1
        } else {
            startIndex = 0
        }

        var entries: [WorkspaceCodemapGraphIndexCatalogCandidate] = []
        entries.reserveCapacity(min(
            request.maximumEntryCount,
            current.shard.projectionFiles.count - startIndex
        ))
        var pathByteCount: UInt64 = 0
        var nextIndex = startIndex
        // P4-6a / B2 (`readCodemapGraphIndexCatalogPage`, async, D-8/D-11). One
        // batched `inventoryRecordFacts` call over this page's candidate ids, hoisted
        // before the loop (fully synchronous from here to the end of the function --
        // no new staleness window). `fact.record == file` is the D-11 captured-operand
        // form: `file` comes from `current.shard.projectionFiles[nextIndex].file`, a
        // record frozen into the shard behind the earlier `await
        // ensureCodemapGraphIndexCatalogShard`, and the comparison is genuinely
        // falsifiable -- it is preserved, not dropped. `state.fileIDsByRelativePath[...]`
        // stays a direct read: it checks the *captured* file's own path, which the
        // fact primitive (keyed by live-record path) cannot substitute for.
        // P4-6b table-deletion conversion: `state.fileIDsByRelativePath[...]`'s captured-path
        // round trip is now a batched `inventoryPathLookups` call (path-keyed, distinct from
        // `pageFacts`'s id-keyed `inventoryRecordFacts` batch above) over the same page, hoisted
        // for the same D-8 reason -- fully synchronous from here to the end of the function, no
        // new staleness window versus the pre-conversion direct-table read.
        let pageFacts = await inventoryRecordFacts(
            fileIDs: current.shard.projectionFiles[startIndex...].map(\.file.id),
            folderIDs: []
        ).filesByID
        let pagePathLookups = await inventoryPathLookups(
            rootID: authority.rootEpoch.rootID,
            relativePaths: current.shard.projectionFiles[startIndex...].map(\.file.standardizedRelativePath)
        ).files
        while nextIndex < current.shard.projectionFiles.count,
              entries.count < request.maximumEntryCount
        {
            let projectionFile = current.shard.projectionFiles[nextIndex]
            let file = projectionFile.file
            guard let state = rootStatesByID[authority.rootEpoch.rootID],
                  state.lifetimeID == authority.rootEpoch.rootLifetimeID,
                  pagePathLookups[file.standardizedRelativePath]?.fileID == file.id,
                  let fact = pageFacts[file.id],
                  fact.record == file,
                  fact.isDiscoverable,
                  let identity = WorkspaceCodemapArtifactBindingIdentity(
                      rootID: authority.rootEpoch.rootID,
                      rootLifetimeID: authority.rootEpoch.rootLifetimeID,
                      fileID: file.id,
                      standardizedRootPath: authority.standardizedRootPath,
                      standardizedRelativePath: file.standardizedRelativePath,
                      standardizedFullPath: file.standardizedFullPath
                  )
            else { return .stale }

            guard let candidatePathByteCount = UInt64(exactly: file.standardizedRelativePath.utf8.count),
                  candidatePathByteCount <= request.maximumPathByteCount
            else { return .unavailable(.catalogUnavailable) }
            let (nextPathByteCount, overflow) = pathByteCount.addingReportingOverflow(candidatePathByteCount)
            guard !overflow else { return .unavailable(.catalogUnavailable) }
            if nextPathByteCount > request.maximumPathByteCount {
                break
            }

            let pathGeneration = session.pathGenerationsByRelativePath[file.standardizedRelativePath]
                ?? authority.ingressGeneration
            entries.append(WorkspaceCodemapGraphIndexCatalogCandidate(
                identity: identity,
                language: projectionFile.language,
                requestGeneration: pathGeneration,
                pathGeneration: pathGeneration
            ))
            pathByteCount = nextPathByteCount
            nextIndex += 1
        }

        guard !entries.isEmpty || nextIndex == current.shard.projectionFiles.count else {
            return .unavailable(.catalogUnavailable)
        }
        let isEnd = nextIndex == current.shard.projectionFiles.count
        let nextCursor = isEnd ? nil : entries.last.map {
            WorkspaceCodemapGraphIndexCatalogCursor(
                standardizedRelativePath: $0.identity.standardizedRelativePath,
                fileID: $0.identity.fileID
            )
        }
        guard let supportedCandidateCountThroughPage = UInt64(exactly: nextIndex),
              let projectedSupportedCandidateTotal = UInt64(exactly: current.shard.projectionFiles.count)
        else {
            return .unavailable(.catalogUnavailable)
        }
        switch WorkspaceCodemapGraphIndexCatalogPage.validated(
            request: request,
            token: current.token,
            entries: entries,
            nextCursor: nextCursor,
            isEnd: isEnd,
            supportedCandidateCountThroughPage: supportedCandidateCountThroughPage,
            projectedSupportedCandidateTotal: projectedSupportedCandidateTotal
        ) {
        case let .success(page):
            return .page(page)
        case .failure:
            return .unavailable(.catalogUnavailable)
        }
    }

    private func revalidateCodemapGraphIndexCatalogToken(
        rootEpoch: WorkspaceCodemapRootEpoch,
        token: WorkspaceCodemapGraphIndexCatalogToken,
        authority: CodemapRootAuthority
    ) -> WorkspaceCodemapGraphIndexCatalogTokenDisposition {
        guard rootEpoch == authority.rootEpoch, token.rootEpoch == rootEpoch else { return .stale }
        guard codemapAuthorityIsCurrent(authority) else { return .stale }
        guard !codemapGraphIndexCatalogIsFenced(rootEpoch: rootEpoch) else { return .stale }
        guard let current = codemapGraphIndexCatalogShardAndToken(authority: authority) else {
            return .unavailable(.catalogNotReady)
        }
        return current.token == token ? .current : .stale
    }

    private func acceptCodemapMarkerReadinessUpdate(
        _ update: WorkspaceCodemapMarkerReadinessUpdate,
        authority: CodemapRootAuthority
    ) async -> Bool {
        guard update.rootEpoch == authority.rootEpoch,
              codemapAuthorityIsCurrent(authority),
              !codemapGraphIndexCatalogIsFenced(rootEpoch: authority.rootEpoch),
              let initialSession = codemapSessionsByRootEpoch[authority.rootEpoch],
              initialSession.authority == authority
        else { return false }

        // P4-6a / B1 site 9 (path-keyed, async, D-8): one batched
        // `inventoryPathLookups` call over this synchronous scan of `update.changes`
        // (no `await` before this point in the function). R4 (discoverability) stays
        // absent, per §4.3.1.1's six-site gap registry (PC-4) -- must not be added.
        let firstPassLookups = await inventoryPathLookups(
            rootID: authority.rootEpoch.rootID,
            relativePaths: update.changes.map(\.standardizedRelativePath)
        )
        let securityExcludedPaths = Set(update.changes.compactMap { change -> String? in
            guard change.state == .securityExcluded,
                  change.standardizedRelativePath == StandardizedPath.relative(change.standardizedRelativePath),
                  !change.standardizedRelativePath.isEmpty,
                  let fact = firstPassLookups.files[change.standardizedRelativePath],
                  fact.fileID == change.fileID,
                  let file = fact.record,
                  file.rootID == authority.rootEpoch.rootID,
                  file.standardizedRelativePath == change.standardizedRelativePath
            else { return nil }
            let pathGeneration = initialSession.pathGenerationsByRelativePath[change.standardizedRelativePath]
                ?? authority.ingressGeneration
            guard change.requestGeneration == pathGeneration,
                  change.pathGeneration == pathGeneration
            else { return nil }
            return change.standardizedRelativePath
        })
        if !securityExcludedPaths.isEmpty {
            guard let fence = await destructiveCodemapGraphFence(
                rootID: authority.rootEpoch.rootID,
                commands: [.securityExcluded(securityExcludedPaths)]
            ), let engine = initialSession.engine,
            let graph = await engine.selectionGraph(rootEpoch: authority.rootEpoch)
            else { return false }
            switch await graph.latestSnapshot() {
            case .pending:
                break
            case .ready:
                guard case .fenced = await graph.fenceFiles(
                    fileIDs: fence.fileIDs,
                    reason: fence.reason
                ) else { return false }
            case .revoked:
                return false
            }
        }

        guard codemapAuthorityIsCurrent(authority),
              !codemapGraphIndexCatalogIsFenced(rootEpoch: authority.rootEpoch),
              var session = codemapSessionsByRootEpoch[authority.rootEpoch],
              session.authority == authority
        else { return false }
        // D-8: a fresh, independent batched lookup -- not reused from `firstPassLookups`.
        // The `await`s above (engine.selectionGraph / graph.latestSnapshot /
        // graph.fenceFiles) are exactly the staleness window D-8 exists to detect;
        // re-deriving `session` and re-checking `codemapAuthorityIsCurrent` just above
        // is the site's existing generation re-check this hoist piggybacks on.
        let secondPassLookups = await inventoryPathLookups(
            rootID: authority.rootEpoch.rootID,
            relativePaths: update.changes.map(\.standardizedRelativePath)
        )
        var appliedChanges: [WorkspaceCodemapMarkerReadinessChange] = []
        for change in update.changes {
            guard change.standardizedRelativePath == StandardizedPath.relative(
                change.standardizedRelativePath
            ),
                !change.standardizedRelativePath.isEmpty,
                !codemapPathIsFenced(
                    rootEpoch: authority.rootEpoch,
                    relativePath: change.standardizedRelativePath
                ),
                let fact = secondPassLookups.files[change.standardizedRelativePath],
                fact.fileID == change.fileID,
                let file = fact.record,
                file.rootID == authority.rootEpoch.rootID,
                file.standardizedRelativePath == change.standardizedRelativePath
            else { continue }
            let pathGeneration = session.pathGenerationsByRelativePath[change.standardizedRelativePath]
                ?? authority.ingressGeneration
            guard change.requestGeneration == pathGeneration,
                  change.pathGeneration == pathGeneration
            else { continue }

            switch change.state {
            case .ready:
                guard session.markerReadinessByFileID[change.fileID] != change else { continue }
                session.markerReadinessByFileID[change.fileID] = change
                appliedChanges.append(change)
            case .unavailable, .securityExcluded:
                guard let removed = session.markerReadinessByFileID.removeValue(forKey: change.fileID) else {
                    continue
                }
                appliedChanges.append(WorkspaceCodemapMarkerReadinessChange(
                    fileID: removed.fileID,
                    standardizedRelativePath: removed.standardizedRelativePath,
                    requestGeneration: change.requestGeneration,
                    pathGeneration: change.pathGeneration,
                    state: change.state
                ))
            }
        }

        guard !appliedChanges.isEmpty else { return true }
        session.markerReadinessRevision &+= 1
        let event = WorkspaceCodemapMarkerReadinessEvent(
            rootEpoch: authority.rootEpoch,
            revision: session.markerReadinessRevision,
            changes: appliedChanges
        )
        codemapSessionsByRootEpoch[authority.rootEpoch] = session
        #if DEBUG
            WorktreeStartupInstrumentation.recordBenchmarkMarkerPublication(
                tag: WorktreeStartupInstrumentation.currentBenchmarkMetricTag,
                rootID: authority.rootEpoch.rootID,
                rootLifetimeID: authority.rootEpoch.rootLifetimeID,
                revision: session.markerReadinessRevision,
                effectiveChangeCount: appliedChanges.count,
                source: .publishedUpdate
            )
        #endif
        yieldCodemapMarkerReadiness(event)
        return true
    }

    #if DEBUG
        func acceptCodemapMarkerReadinessUpdateForTesting(
            _ update: WorkspaceCodemapMarkerReadinessUpdate
        ) async -> Bool {
            guard let authority = codemapSessionsByRootEpoch[update.rootEpoch]?.authority else {
                return false
            }
            return await acceptCodemapMarkerReadinessUpdate(update, authority: authority)
        }

        /// P4-6a test shim (site 11, PC-6 gap): `codemapDemandIsCurrent` is `private`;
        /// it takes no authority parameter (it re-derives everything from the ticket),
        /// so this shim is a direct pass-through with no setup of its own.
        func codemapDemandIsCurrentForTesting(
            _ ticket: WorkspaceCodemapArtifactDemandTicket
        ) async -> Bool {
            await codemapDemandIsCurrent(ticket)
        }

        func codemapMarkerReadinessSnapshotForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> (revision: UInt64, changes: [WorkspaceCodemapMarkerReadinessChange])? {
            codemapSessionsByRootEpoch[rootEpoch].map {
                (
                    revision: $0.markerReadinessRevision,
                    changes: $0.markerReadinessByFileID.values.sorted {
                        $0.standardizedRelativePath < $1.standardizedRelativePath
                    }
                )
            }
        }

        @discardableResult
        func clearCodemapMarkerReadinessForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch,
            fileID: UUID
        ) -> Bool {
            guard var session = codemapSessionsByRootEpoch[rootEpoch],
                  let removed = session.markerReadinessByFileID.removeValue(forKey: fileID)
            else { return false }
            let pathGeneration = session.pathGenerationsByRelativePath[
                removed.standardizedRelativePath
            ] ?? session.authority.ingressGeneration
            let change = WorkspaceCodemapMarkerReadinessChange(
                fileID: removed.fileID,
                standardizedRelativePath: removed.standardizedRelativePath,
                requestGeneration: pathGeneration,
                pathGeneration: pathGeneration,
                state: .unavailable
            )
            session.markerReadinessRevision &+= 1
            codemapSessionsByRootEpoch[rootEpoch] = session
            yieldCodemapMarkerReadiness(WorkspaceCodemapMarkerReadinessEvent(
                rootEpoch: rootEpoch,
                revision: session.markerReadinessRevision,
                changes: [change]
            ))
            return true
        }
    #endif

    /// P4-6a / B1 site 8 (path-keyed, sync). `rootStatesByID[rootEpoch.rootID]`
    /// existence is no longer bound as a standalone gate: `inventoryPathLookups`
    /// returns an absent fact for a missing root, which fails the second guard exactly
    /// as the original's combined guard failed on a missing `state` -- provably
    /// equivalent because this function's only observable effect is its return value
    /// (no side effects, no per-clause diagnostics). R4 (discoverability) stays absent
    /// per §4.3.1.1's six-site gap registry (PC-3) -- must not be added. Named test:
    /// `testCodemapManifestCandidateReturnsCandidateForManagedOnlyFile`.
    private func codemapManifestCandidate(
        rootEpoch: WorkspaceCodemapRootEpoch,
        relativePath: String,
        authority: CodemapRootAuthority
    ) async -> WorkspaceCodemapManifestBindingCandidate? {
        guard rootEpoch == authority.rootEpoch,
              codemapAuthorityIsCurrent(authority),
              let session = codemapSessionsByRootEpoch[rootEpoch],
              session.authority == authority
        else { return nil }
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !StandardizedPath.containsNUL(relativePath),
              standardizedRelativePath == relativePath,
              standardizedRelativePath != "..",
              !standardizedRelativePath.hasPrefix("../")
        else { return nil }
        let fact = await inventoryPathLookups(
            rootID: rootEpoch.rootID,
            relativePaths: [standardizedRelativePath]
        ).files[standardizedRelativePath]
        guard let fileID = fact?.fileID,
              let file = fact?.record,
              file.rootID == rootEpoch.rootID,
              file.standardizedRelativePath == standardizedRelativePath,
              let identity = WorkspaceCodemapArtifactBindingIdentity(
                  rootID: rootEpoch.rootID,
                  rootLifetimeID: rootEpoch.rootLifetimeID,
                  fileID: file.id,
                  standardizedRootPath: authority.standardizedRootPath,
                  standardizedRelativePath: standardizedRelativePath,
                  standardizedFullPath: file.standardizedFullPath
              )
        else { return nil }
        let pathGeneration = session.pathGenerationsByRelativePath[standardizedRelativePath]
            ?? authority.ingressGeneration
        guard pathGeneration > 0 else { return nil }
        return WorkspaceCodemapManifestBindingCandidate(
            identity: identity,
            requestGeneration: pathGeneration,
            pathGeneration: pathGeneration,
            ingressGeneration: authority.ingressGeneration
        )
    }

    private func readCodemapSource(
        identity: WorkspaceCodemapArtifactBindingIdentity,
        expectedFingerprint: GitBlobLStatFingerprint,
        maximumBytes: Int64,
        ownerID: UUID,
        authority: CodemapRootAuthority
    ) async throws -> ValidatedRawFileContentSnapshot {
        // P4-6a / B1 site 10 (path-keyed, async, D-8). `state` stays a direct read
        // (needed below for `.service` / `.root`, not folded into the fact). R4
        // (discoverability) stays absent per §4.3.1.1's six-site gap registry (PC-5).
        guard WorkspaceCodemapRootEpoch(
            rootID: identity.rootID,
            rootLifetimeID: identity.rootLifetimeID
        ) == authority.rootEpoch,
            codemapAuthorityIsCurrent(authority),
            let state = rootStatesByID[identity.rootID],
            state.root.standardizedFullPath == identity.standardizedRootPath
        else {
            throw WorkspaceCodemapBindingIntegrationRoutingError.routeDetached(authority.rootEpoch)
        }
        let firstPassFact = await inventoryPathLookups(
            in: state,
            relativePaths: [identity.standardizedRelativePath]
        ).files[identity.standardizedRelativePath]
        guard let fileID = firstPassFact?.fileID,
              fileID == identity.fileID,
              let file = firstPassFact?.record,
              file.standardizedFullPath == identity.standardizedFullPath
        else {
            throw WorkspaceCodemapBindingIntegrationRoutingError.routeDetached(authority.rootEpoch)
        }

        let snapshot = try await state.service.loadValidatedRawContent(
            ofRelativePath: identity.standardizedRelativePath,
            expectedFingerprint: FileContentFingerprint(
                deviceID: expectedFingerprint.device,
                fileNumber: expectedFingerprint.inode,
                byteSize: expectedFingerprint.size,
                modificationSeconds: expectedFingerprint.modificationSeconds,
                modificationNanoseconds: expectedFingerprint.modificationNanoseconds,
                statusChangeSeconds: expectedFingerprint.changeSeconds,
                statusChangeNanoseconds: expectedFingerprint.changeNanoseconds
            ),
            maximumBytes: maximumBytes,
            workloadClass: .codemap,
            schedulerOwnerID: ownerID
        )
        // D-8: a fresh, independent lookup against `currentState`, re-fetched after
        // the `loadValidatedRawContent` await above -- this is the site's own
        // pre-existing post-await re-check (lifetimeID + root path + path→id), now
        // routed through the shared fact primitive rather than direct table reads.
        guard codemapAuthorityIsCurrent(authority),
              let currentState = rootStatesByID[identity.rootID],
              currentState.lifetimeID == identity.rootLifetimeID,
              currentState.root.standardizedFullPath == identity.standardizedRootPath
        else {
            throw WorkspaceCodemapBindingIntegrationRoutingError.routeDetached(authority.rootEpoch)
        }
        let secondPassFact = await inventoryPathLookups(
            in: currentState,
            relativePaths: [identity.standardizedRelativePath]
        ).files[identity.standardizedRelativePath]
        guard secondPassFact?.fileID == identity.fileID,
              let currentFile = secondPassFact?.record,
              currentFile.standardizedFullPath == identity.standardizedFullPath
        else {
            throw WorkspaceCodemapBindingIntegrationRoutingError.routeDetached(authority.rootEpoch)
        }
        return snapshot
    }

    private func codemapAuthorityMatchesLoadedRoot(
        _ authority: CodemapRootAuthority
    ) -> Bool {
        guard let state = rootStatesByID[authority.rootEpoch.rootID],
              state.lifetimeID == authority.rootEpoch.rootLifetimeID,
              state.root.standardizedFullPath == authority.standardizedRootPath
        else { return false }
        return true
    }

    private func codemapPreflightAuthorityIsCurrent(
        _ authority: CodemapRootAuthority
    ) -> Bool {
        codemapAuthorityMatchesLoadedRoot(authority)
            && codemapAuthorityGenerationsByRootEpoch[authority.rootEpoch]
            == authority.catalogGeneration
    }

    private func codemapAuthorityIsCurrent(
        _ authority: CodemapRootAuthority
    ) -> Bool {
        codemapSessionsByRootEpoch[authority.rootEpoch]?.authority == authority &&
            codemapAuthorityMatchesLoadedRoot(authority)
    }

    /// P4-6a / B1 site 11 (path-keyed, sync). R4 (discoverability) stays absent per
    /// §4.3.1.1's six-site gap registry (PC-6) -- must not be added. Named test:
    /// `testCodemapDemandIsCurrentTrueForManagedOnlyFile`.
    /// P4-6b prep slice 1: `async` so this gatekeeping primitive is delegation-capable,
    /// matching `inventoryRecordFacts`/`inventoryPathLookups`. A live-testing pass
    /// initially suspected this conversion of causing `CodemapAutomaticSelectionGraphNativeTests`
    /// to time out (a reentrancy-window hypothesis: this function gates 20+ call sites
    /// in the timing-sensitive demand/ticket state machine); that suspicion was
    /// disproven by comparison against the unmodified baseline (`git stash` of this
    /// file) -- the same suite fails identically, with or without this conversion.
    /// The actual cause is a pre-existing, already-tracked bug in
    /// `WorkspaceCodemapBindingEngine.swift`'s `resolveGraphIndexCandidate`, which
    /// folds bridge/runtime errors into `.transient`/`.retry` with no terminal case
    /// (`docs/investigations/full-suite-test-hang-2026-08-21.md`), unrelated to
    /// inventory authority or this read-facade work.
    private func codemapDemandIsCurrent(
        _ ticket: WorkspaceCodemapArtifactDemandTicket
    ) async -> Bool {
        guard ticket.requestGeneration > 0,
              ticket.catalogGeneration > 0,
              ticket.pathGeneration > 0,
              ticket.ingressGeneration > 0,
              ticket.requestGeneration == ticket.pathGeneration,
              let session = codemapSessionsByRootEpoch[ticket.rootEpoch],
              session.authority.catalogGeneration == ticket.catalogGeneration,
              session.authority.ingressGeneration == ticket.ingressGeneration,
              codemapAuthorityIsCurrent(session.authority),
              let record = session.demandsByFileID[ticket.fileID],
              codemapTicketsShareDemand(record.ticket, ticket),
              (
                  session.pathGenerationsByRelativePath[record.identity.standardizedRelativePath]
                      ?? session.authority.ingressGeneration
              ) == ticket.pathGeneration
        else { return false }
        let fact = await inventoryPathLookups(
            rootID: ticket.rootEpoch.rootID,
            relativePaths: [record.identity.standardizedRelativePath]
        ).files[record.identity.standardizedRelativePath]
        guard fact?.fileID == ticket.fileID,
              fact?.record?.rootID == ticket.rootEpoch.rootID
        else { return false }
        return true
    }

    private func retainedCodemapTicket(
        for ticket: WorkspaceCodemapArtifactDemandTicket
    ) -> WorkspaceCodemapArtifactDemandTicket {
        WorkspaceCodemapArtifactDemandTicket(
            retainID: UUID(),
            requestID: ticket.requestID,
            rootEpoch: ticket.rootEpoch,
            fileID: ticket.fileID,
            requestGeneration: ticket.requestGeneration,
            catalogGeneration: ticket.catalogGeneration,
            pathGeneration: ticket.pathGeneration,
            ingressGeneration: ticket.ingressGeneration
        )
    }

    private func codemapTicketsShareDemand(
        _ lhs: WorkspaceCodemapArtifactDemandTicket,
        _ rhs: WorkspaceCodemapArtifactDemandTicket
    ) -> Bool {
        lhs.requestID == rhs.requestID &&
            lhs.rootEpoch == rhs.rootEpoch &&
            lhs.fileID == rhs.fileID &&
            lhs.requestGeneration == rhs.requestGeneration &&
            lhs.catalogGeneration == rhs.catalogGeneration &&
            lhs.pathGeneration == rhs.pathGeneration &&
            lhs.ingressGeneration == rhs.ingressGeneration
    }

    private func codemapDemandResult(
        _ result: WorkspaceCodemapArtifactDemandResult,
        for ticket: WorkspaceCodemapArtifactDemandTicket
    ) -> WorkspaceCodemapArtifactDemandResult {
        switch result {
        case .unavailable:
            result
        case .pending:
            .pending(ticket)
        case let .ready(ready):
            .ready(WorkspaceCodemapArtifactDemandReady(
                ticket: ticket,
                identity: ready.identity,
                snapshot: ready.snapshot,
                handle: ready.handle
            ))
        }
    }

    private func codemapPresentationReadyMatches(
        _ ready: WorkspaceCodemapArtifactDemandReady,
        demandRecord: CodemapDemandRecord,
        entry: WorkspaceCodemapFrozenPresentationEntry
    ) -> Bool {
        let ticket = entry.ticket
        return codemapTicketsShareDemand(demandRecord.ticket, ticket) &&
            codemapTicketsShareDemand(ready.ticket, ticket) &&
            ready.identity == demandRecord.identity &&
            ready.identity.rootID == ticket.rootEpoch.rootID &&
            ready.identity.rootLifetimeID == ticket.rootEpoch.rootLifetimeID &&
            ready.identity.fileID == ticket.fileID &&
            ready.identity.standardizedRelativePath ==
            entry.logicalPath.standardizedRelativePath &&
            ready.snapshot.rootEpoch == ticket.rootEpoch &&
            ready.snapshot.fileID == ticket.fileID &&
            ready.snapshot.standardizedRelativePath ==
            entry.logicalPath.standardizedRelativePath &&
            ready.snapshot.requestGeneration == ticket.requestGeneration &&
            ready.snapshot.artifactKey == entry.artifactKey &&
            ready.snapshot.outcome == entry.outcome
    }

    private func codemapUnavailableIsStable(
        _ reason: WorkspaceCodemapArtifactDemandUnavailableReason
    ) -> Bool {
        switch reason {
        case .rootNotLoaded, .fileNotCataloged, .unsupportedFileType:
            true
        case let .gitTerminal(reason):
            reason != .releasedRootEpoch
        case let .demandUnavailable(reason):
            reason != .transient
        case .gitTransient, .busy, .rejected, .routeConflict, .registrationFailed,
             .runtimeFailure, .staleCurrentness, .cancelled:
            false
        }
    }

    private func codemapPathIsFenced(
        rootEpoch: WorkspaceCodemapRootEpoch,
        relativePath: String
    ) -> Bool {
        let path = StandardizedPath.relative(relativePath)
        return codemapPathInvalidationFlightsByRootEpoch[rootEpoch] != nil
            || codemapPathFenceTokensByID.values.contains {
                $0.rootEpoch == rootEpoch && $0.standardizedRelativePaths.contains(path)
            }
    }

    private func standardizedCodemapInvalidationCommand(
        _ command: CodemapInvalidationCommand
    ) -> CodemapInvalidationCommand? {
        switch command {
        case let .modified(paths):
            let safe = Set(paths.map(StandardizedPath.relative).filter { !$0.isEmpty })
            return safe.isEmpty ? nil : .modified(safe)
        case let .deleted(paths):
            let safe = Set(paths.map(StandardizedPath.relative).filter { !$0.isEmpty })
            return safe.isEmpty ? nil : .deleted(safe)
        case let .securityExcluded(paths):
            let safe = Set(paths.map(StandardizedPath.relative).filter { !$0.isEmpty })
            return safe.isEmpty ? nil : .securityExcluded(safe)
        case let .renamed(from, to):
            let oldPath = StandardizedPath.relative(from)
            let newPath = StandardizedPath.relative(to)
            guard !oldPath.isEmpty, !newPath.isEmpty else { return nil }
            return .renamed(from: oldPath, to: newPath)
        case .watcherGap, .checkout, .repositoryAuthority, .catalogAdvanced, .unload:
            return command
        }
    }

    private func codemapPaths(
        in commands: [CodemapInvalidationCommand]
    ) -> Set<String> {
        var paths = Set<String>()
        for command in commands {
            switch command {
            case let .modified(commandPaths), let .deleted(commandPaths),
                 let .securityExcluded(commandPaths):
                paths.formUnion(commandPaths)
            case let .renamed(from, to):
                paths.insert(from)
                paths.insert(to)
            case .watcherGap, .checkout, .repositoryAuthority, .catalogAdvanced, .unload:
                break
            }
        }
        return paths
    }

    private func fenceCodemapPaths(
        rootID: UUID,
        commands rawCommands: [CodemapInvalidationCommand]
    ) async -> CodemapPathFenceToken? {
        let launch = beginCodemapPathInvalidation(rootID: rootID, commands: rawCommands)
        await launch.task?.value
        return launch.token
    }

    /// Revokes path-level authority immediately for an explicit file mutation without making
    /// disk I/O wait behind retained publisher-derived codemap convergence. The returned token
    /// and retained flight continue fencing demand/projection admission until derived work settles.
    private func beginCodemapPathFence(
        rootID: UUID,
        commands: [CodemapInvalidationCommand]
    ) -> CodemapPathFenceToken? {
        beginCodemapPathInvalidation(rootID: rootID, commands: commands).token
    }

    /// Invalidates codemap graph-index authority synchronously, while letting publisher ingress
    /// commit the basic catalog without awaiting derived engine/graph convergence.
    private func beginCodemapPathInvalidation(
        rootID: UUID,
        commands rawCommands: [CodemapInvalidationCommand],
        publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        diagnosticRootToken: UUID? = nil,
        servicePublicationSequence: UInt64? = nil
    ) -> (token: CodemapPathFenceToken?, task: Task<Void, Never>?) {
        let commands = rawCommands.compactMap(standardizedCodemapInvalidationCommand)
        let paths = codemapPaths(in: commands)
        guard !paths.isEmpty, let state = rootStatesByID[rootID] else { return (nil, nil) }
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: state.lifetimeID)

        retainCodemapRootStatusCoverageAcrossPathInvalidation(
            rootEpoch: rootEpoch,
            standardizedRelativePaths: paths
        )
        advanceCodemapGraphIndexInvalidationGeneration(rootEpoch: rootEpoch)
        _ = cancelCodemapGraphIndexBuildLaunchForInvalidation(rootEpoch: rootEpoch)

        let token = CodemapPathFenceToken(
            id: UUID(),
            rootEpoch: rootEpoch,
            standardizedRelativePaths: paths,
            shouldRescheduleGraphIndex: true
        )
        codemapPathFenceTokensByID[token.id] = token

        let predecessorTask = codemapPathInvalidationFlightsByRootEpoch[rootEpoch]?.task
        let cleanupTask = codemapCleanupFlightsByRootID[rootID]?.task
        guard var session = codemapSessionsByRootEpoch[rootEpoch] else {
            #if DEBUG
                guard codemapPathInvalidationStageHandlerForTesting != nil else {
                    return (token, nil)
                }
                let flightID = UUID()
                let task = Task { [weak self] in
                    guard let self else { return }
                    await reportCodemapPathInvalidationStage(
                        .rootMutationFence,
                        rootEpoch: rootEpoch,
                        flightID: flightID,
                        publicationCorrelation: publicationCorrelation,
                        diagnosticRootToken: diagnosticRootToken,
                        servicePublicationSequence: servicePublicationSequence
                    )
                    await finishCodemapPathInvalidationWithoutAuthority(
                        flightID: flightID,
                        rootEpoch: rootEpoch
                    )
                }
                codemapPathInvalidationFlightsByRootEpoch[rootEpoch] = CodemapPathInvalidationFlight(
                    id: flightID,
                    rootEpoch: rootEpoch,
                    task: task
                )
                return (token, task)
            #else
                return (token, nil)
            #endif
        }

        let removedMarkerReadiness = session.markerReadinessByFileID.values
            .filter { paths.contains($0.standardizedRelativePath) }
            .map {
                WorkspaceCodemapMarkerReadinessChange(
                    fileID: $0.fileID,
                    standardizedRelativePath: $0.standardizedRelativePath,
                    requestGeneration: $0.requestGeneration,
                    pathGeneration: $0.pathGeneration,
                    state: .unavailable
                )
            }
            .sorted {
                if $0.standardizedRelativePath != $1.standardizedRelativePath {
                    return $0.standardizedRelativePath < $1.standardizedRelativePath
                }
                return $0.fileID.uuidString < $1.fileID.uuidString
            }
        for change in removedMarkerReadiness {
            session.markerReadinessByFileID.removeValue(forKey: change.fileID)
        }
        let markerReadinessEvent: WorkspaceCodemapMarkerReadinessEvent? = if removedMarkerReadiness.isEmpty {
            nil
        } else {
            WorkspaceCodemapMarkerReadinessEvent(
                rootEpoch: rootEpoch,
                revision: session.markerReadinessRevision &+ 1,
                changes: removedMarkerReadiness
            )
        }
        if markerReadinessEvent != nil {
            session.markerReadinessRevision &+= 1
        }

        var affectedRecords: [CodemapDemandRecord] = []
        for (fileID, record) in session.demandsByFileID where paths.contains(record.identity.standardizedRelativePath) {
            affectedRecords.append(record)
            session.demandsByFileID.removeValue(forKey: fileID)
            session.bundlesByRequestID.removeValue(forKey: record.ticket.requestID)?.close()
        }
        let affectedRequestIDs = Set(affectedRecords.map(\.ticket.requestID))
        session.presentationRecordsByID = session.presentationRecordsByID.filter {
            $0.value.requestIDs.isDisjoint(with: affectedRequestIDs)
        }
        for record in affectedRecords {
            record.task?.cancel()
        }
        for path in paths {
            let current = session.pathGenerationsByRelativePath[path] ?? session.authority.ingressGeneration
            session.pathGenerationsByRelativePath[path] = current == .max ? .max : current + 1
        }

        let graph = session.selectionGraph
        codemapSessionsByRootEpoch[rootEpoch] = session
        if let markerReadinessEvent {
            yieldCodemapMarkerReadiness(markerReadinessEvent)
        }

        let flightID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await reportCodemapPathInvalidationStage(
                .rootMutationFence,
                rootEpoch: rootEpoch,
                flightID: flightID,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken,
                servicePublicationSequence: servicePublicationSequence
            )
            guard await waitForCodemapRootMutationFenceIfNeeded(rootEpoch: rootEpoch) else {
                await finishCodemapPathInvalidation(flightID: flightID, authority: session.authority)
                return
            }
            if let cleanupTask {
                await reportCodemapPathInvalidationStage(
                    .cleanupFlight,
                    rootEpoch: rootEpoch,
                    flightID: flightID,
                    publicationCorrelation: publicationCorrelation,
                    diagnosticRootToken: diagnosticRootToken,
                    servicePublicationSequence: servicePublicationSequence
                )
                await cleanupTask.value
            }
            if let predecessorTask {
                await reportCodemapPathInvalidationStage(
                    .predecessorFlight,
                    rootEpoch: rootEpoch,
                    flightID: flightID,
                    publicationCorrelation: publicationCorrelation,
                    diagnosticRootToken: diagnosticRootToken,
                    servicePublicationSequence: servicePublicationSequence
                )
                await predecessorTask.value
            }
            guard await codemapAuthorityIsCurrent(session.authority) else {
                await finishCodemapPathInvalidation(flightID: flightID, authority: session.authority)
                return
            }
            await performCodemapPathInvalidation(
                flightID: flightID,
                authority: session.authority,
                engine: session.engine,
                setupTask: session.setupTask,
                graph: graph,
                commands: commands,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken,
                servicePublicationSequence: servicePublicationSequence
            )
        }
        codemapPathInvalidationFlightsByRootEpoch[rootEpoch] = CodemapPathInvalidationFlight(
            id: flightID,
            rootEpoch: rootEpoch,
            task: task
        )
        return (token, task)
    }

    /// P4-6a / B3: `state.fileIDsByRelativePath[path]` rewired onto `inventoryPathLookups`,
    /// hoisted once for the whole batch (this function is fully synchronous -- no D-8
    /// window). `state` itself is still read directly for the unrelated `lifetimeID`
    /// gate, which is not one of the ten inventory tables. Named test:
    /// `testRetainCodemapRootStatusCoverageSkipsPathsAbsentFromProjectionOrAlreadyInvalidated`.
    ///
    /// P4-6b table-deletion conversion superseded the P4-6a-era routing below:
    /// `inventoryPathLookups`'s state-scoped overload became Rust-routed (inherently
    /// `async`) once the underlying tables were deleted, which this function cannot take on
    /// (see the synchronous-contract reasoning below, unchanged). The path->id check now reads
    /// `shard.projectionFiles` directly instead -- already Swift-resident, already fetched
    /// synchronously in this same function, and the exact shard this check validates against.
    ///
    /// P4-6b prep slice 1: deliberately kept synchronous. This function's sole caller,
    /// `beginCodemapPathInvalidation`,
    /// is itself deliberately synchronous ("invalidates codemap graph-index authority
    /// synchronously... without awaiting derived engine/graph convergence" -- its own doc
    /// comment) and has 7+ call sites on ingress-adjacent paths; making it `async` to
    /// accommodate this one primitive would ripple a real synchronization-contract change
    /// through code this slice's remit does not cover. The state-scoped overload is exactly
    /// the id-map read this call needs and stays out of the async-delegation surface for
    /// the same reason discussed on that overload's own doc comment.
    private func retainCodemapRootStatusCoverageAcrossPathInvalidation(
        rootEpoch: WorkspaceCodemapRootEpoch,
        standardizedRelativePaths: Set<String>
    ) {
        guard var baseline = codemapRootStatusCoverageBaselinesByRootEpoch[rootEpoch],
              let state = rootStatesByID[rootEpoch.rootID],
              state.lifetimeID == rootEpoch.rootLifetimeID,
              let authority = currentCodemapAuthority(rootEpoch: rootEpoch),
              let shard = codemapGraphIndexCatalogShardAndToken(authority: authority)?.shard
        else { return }

        // P4-6b table-deletion conversion: `inventoryPathLookups`'s state-scoped overload is now
        // itself Rust-routed (inherently `await`-ing), which this function's own doc comment
        // above explicitly forbids taking on (its caller `beginCodemapPathInvalidation` is
        // deliberately synchronous across 7+ ingress-adjacent call sites -- ripple-changing that
        // contract is out of this pass's remit, same reasoning as the B2 shard conversion).
        // `shard` -- already fetched synchronously two lines above -- is an equally valid,
        // already-Swift-resident data source for exactly this path->id check, so this builds a
        // local path->id map from the shard's own `projectionFiles` instead of calling the
        // primitive at all.
        let pathToFileID = Dictionary(
            shard.projectionFiles.map { ($0.file.standardizedRelativePath, $0.file.id) },
            uniquingKeysWith: { first, _ in first }
        )
        for path in standardizedRelativePaths {
            guard let fileID = pathToFileID[path],
                  shard.projectionFileIndexByID[fileID] != nil,
                  baseline.invalidatedCandidateFileIDs.insert(fileID).inserted
            else { continue }
            baseline.retainedCandidateCount = baseline.retainedCandidateCount > 0
                ? baseline.retainedCandidateCount - 1
                : 0
        }
        codemapRootStatusCoverageBaselinesByRootEpoch[rootEpoch] = baseline
    }

    private func performCodemapPathInvalidation(
        flightID: UUID,
        authority: CodemapRootAuthority,
        engine: WorkspaceCodemapBindingEngine?,
        setupTask: Task<CodemapSetupDisposition, Never>?,
        graph: WorkspaceCodemapSelectionGraph?,
        commands: [CodemapInvalidationCommand],
        publicationCorrelation: EditFlowPerf.LifecycleCorrelation?,
        diagnosticRootToken: UUID?,
        servicePublicationSequence: UInt64?
    ) async {
        func report(_ stage: CodemapPathInvalidationStage) async {
            await reportCodemapPathInvalidationStage(
                stage,
                rootEpoch: authority.rootEpoch,
                flightID: flightID,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken,
                servicePublicationSequence: servicePublicationSequence
            )
        }

        let destructiveFence = await destructiveCodemapGraphFence(
            rootID: authority.rootEpoch.rootID,
            commands: commands
        )
        if let setupTask {
            await report(.setup)
            _ = await setupTask.value
        }
        let resolvedEngine = engine ?? codemapSessionsByRootEpoch[authority.rootEpoch]?.engine
        if let resolvedEngine {
            // Destructive ordering is deliberate: remove the overlay contribution first, then
            // install the cumulative graph fence, and only then publish consumer completion.
            await report(.engineInvalidation)
            await applyCodemapInvalidationCommands(
                commands,
                rootEpoch: authority.rootEpoch,
                engine: resolvedEngine
            )
        }
        if let graph, let destructiveFence, !destructiveFence.fileIDs.isEmpty {
            await report(.graphContributionFence)
            _ = await graph.fenceFiles(
                fileIDs: destructiveFence.fileIDs,
                reason: destructiveFence.reason
            )
        }
        await report(.completionPublication)
        await finishCodemapPathInvalidation(
            flightID: flightID,
            authority: authority
        )
    }

    /// P4-6a / B3: rewired onto `inventoryPathLookups`. `rootStatesByID[rootID]` missing
    /// is no longer an early-return guard -- `inventoryPathLookups` returns empty fact
    /// maps for a missing root, every path then resolves to `fileID == nil`, `fileIDs`
    /// stays empty, and the function returns `nil` exactly as it did before, just via
    /// the shared empty-facts path rather than a dedicated guard. Named test:
    /// `testDestructiveCodemapGraphFenceReturnsNilWhenRootStateMissingOrNoCommandsMatch`.
    private func destructiveCodemapGraphFence(
        rootID: UUID,
        commands: [CodemapInvalidationCommand]
    ) async -> (fileIDs: Set<UUID>, reason: WorkspaceCodemapGraphFenceReason)? {
        let queriedPaths: Set<String> = commands.reduce(into: []) { paths, command in
            switch command {
            case let .deleted(commandPaths), let .securityExcluded(commandPaths):
                paths.formUnion(commandPaths)
            case let .renamed(from, to):
                paths.insert(from)
                paths.insert(to)
            case .modified, .watcherGap, .checkout, .repositoryAuthority, .catalogAdvanced, .unload:
                break
            }
        }
        let lookups = await inventoryPathLookups(rootID: rootID, relativePaths: queriedPaths).files
        var fileIDs = Set<UUID>()
        var reason: WorkspaceCodemapGraphFenceReason = .deleted
        for command in commands {
            switch command {
            case let .deleted(paths):
                fileIDs.formUnion(paths.compactMap { lookups[$0]?.fileID })
            case let .renamed(from, to):
                reason = .renamed
                if let fileID = lookups[from]?.fileID { fileIDs.insert(fileID) }
                if let fileID = lookups[to]?.fileID { fileIDs.insert(fileID) }
            case let .securityExcluded(paths):
                reason = .securityExcluded
                fileIDs.formUnion(paths.compactMap { lookups[$0]?.fileID })
            case .modified, .watcherGap, .checkout, .repositoryAuthority, .catalogAdvanced, .unload:
                break
            }
        }
        return fileIDs.isEmpty ? nil : (fileIDs, reason)
    }

    private func reportCodemapPathInvalidationStage(
        _ stage: CodemapPathInvalidationStage,
        rootEpoch: WorkspaceCodemapRootEpoch,
        flightID: UUID,
        publicationCorrelation: EditFlowPerf.LifecycleCorrelation?,
        diagnosticRootToken: UUID?,
        servicePublicationSequence: UInt64?
    ) async {
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.WorkspaceIngress.codemapInvalidationStage,
            correlation: publicationCorrelation,
            EditFlowPerf.Dimensions(
                outcome: stage.rawValue,
                rootToken: diagnosticRootToken?.uuidString,
                barrierSequence: servicePublicationSequence,
                observerToken: flightID.uuidString
            )
        )
        #if DEBUG
            await codemapPathInvalidationStageHandlerForTesting?(rootEpoch, flightID, stage)
        #endif
    }

    @discardableResult
    private func removeCodemapPathInvalidationFlight(
        rootEpoch: WorkspaceCodemapRootEpoch,
        flightID: UUID
    ) -> Bool {
        guard codemapPathInvalidationFlightsByRootEpoch[rootEpoch]?.id == flightID else { return false }
        codemapPathInvalidationFlightsByRootEpoch.removeValue(forKey: rootEpoch)
        return true
    }

    @discardableResult
    private func removeCodemapPathFenceToken(id: UUID) -> Bool {
        codemapPathFenceTokensByID.removeValue(forKey: id) != nil
    }

    private func finishCodemapPathInvalidationWithoutAuthority(
        flightID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        guard removeCodemapPathInvalidationFlight(rootEpoch: rootEpoch, flightID: flightID) else { return }
        schedulePendingCodemapGraphIndexBuildIfFullyUnfenced(rootEpoch: rootEpoch)
        resumeCodemapPathQuiescenceWaitersIfNeeded(rootEpoch: rootEpoch)
    }

    private func finishCodemapPathInvalidation(
        flightID: UUID,
        authority: CodemapRootAuthority
    ) async {
        guard codemapPathInvalidationFlightsByRootEpoch[authority.rootEpoch]?.id == flightID else {
            return
        }
        defer {
            if removeCodemapPathInvalidationFlight(rootEpoch: authority.rootEpoch, flightID: flightID) {
                schedulePendingCodemapGraphIndexBuildIfFullyUnfenced(
                    rootEpoch: authority.rootEpoch
                )
                resumeCodemapPathQuiescenceWaitersIfNeeded(rootEpoch: authority.rootEpoch)
            }
        }
        guard codemapAuthorityIsCurrent(authority) else { return }
    }

    private func releaseCodemapPathFence(
        _ token: CodemapPathFenceToken?,
        didCommitMutation: Bool = true
    ) {
        guard let token else { return }
        guard removeCodemapPathFenceToken(id: token.id) else {
            #if DEBUG
                discardedCodemapPathFenceReleaseCounterForTesting += 1
            #endif
            return
        }
        // The fence itself advanced projection/path authority and cancelled old work. A failed
        // disk mutation still needs one restoration preload, while committed work needs the same
        // reschedule against the new public catalog.
        if token.shouldRescheduleGraphIndex {
            codemapGraphIndexBuildReschedulePendingRootEpochs.insert(token.rootEpoch)
        }
        _ = didCommitMutation
        schedulePendingCodemapGraphIndexBuildIfFullyUnfenced(rootEpoch: token.rootEpoch)
        resumeCodemapPathQuiescenceWaitersIfNeeded(rootEpoch: token.rootEpoch)
    }

    private func retainCodemapPathFenceUntilMutationDrain(
        _ token: CodemapPathFenceToken?,
        service: FileSystemService,
        relativePaths: Set<String>
    ) {
        Task { [weak self] in
            await service.awaitMutationDrain(conflictingWith: relativePaths)
            await self?.releaseCodemapPathFence(token, didCommitMutation: true)
        }
    }

    private func cancelCodemapGraphIndexBuildLaunchForInvalidation(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Task<Void, Never>? {
        codemapGraphIndexRetryExhaustionByRootEpoch.removeValue(forKey: rootEpoch)
        codemapGraphIndexBuildRetriesByRootEpoch.removeValue(forKey: rootEpoch)?.task.cancel()
        guard let launch = codemapGraphIndexBuildLaunchesByRootEpoch.removeValue(
            forKey: rootEpoch
        ) else { return nil }
        launch.task?.cancel()
        recordCodemapGraphIndexBuildStoreEvent(
            .superseded,
            rootEpoch: rootEpoch,
            phase: .superseded
        )
        return launch.task
    }

    private func detachCodemapSession(
        rootEpoch: WorkspaceCodemapRootEpoch,
        invalidationCommands: [CodemapInvalidationCommand] = [.catalogAdvanced],
        graphInvalidationReason: WorkspaceCodemapGraphRevocationReason =
            .repositoryAuthorityChanged
    ) -> CodemapCleanupFlight? {
        codemapGraphIndexRetryExhaustionByRootEpoch.removeValue(forKey: rootEpoch)
        let launch = codemapGraphIndexBuildLaunchesByRootEpoch.removeValue(forKey: rootEpoch)
        launch?.task?.cancel()
        if launch != nil {
            recordCodemapGraphIndexBuildStoreEvent(
                .cancelled,
                rootEpoch: rootEpoch,
                phase: .cancelled
            )
        }
        let eligibilityFlight = codemapEligibilityFlightsByRootEpoch.removeValue(forKey: rootEpoch)
        eligibilityFlight?.task.cancel()
        let graphIndexRetry = codemapGraphIndexBuildRetriesByRootEpoch.removeValue(forKey: rootEpoch)
        graphIndexRetry?.task.cancel()
        let completedEligibility = codemapCompletedEligibilityByRootEpoch.removeValue(
            forKey: rootEpoch
        )
        let session = codemapSessionsByRootEpoch.removeValue(forKey: rootEpoch)
        codemapGraphAccountingByRootEpoch.removeValue(forKey: rootEpoch)
        codemapGraphIndexWorkerRecoveryExhaustedRootEpochs.remove(rootEpoch)
        codemapRootStatusCoverageBaselinesByRootEpoch.removeValue(forKey: rootEpoch)
        publishCodemapRootStatusesIfChanged()
        if let session, !session.markerReadinessByFileID.isEmpty {
            let changes = session.markerReadinessByFileID.values.map {
                WorkspaceCodemapMarkerReadinessChange(
                    fileID: $0.fileID,
                    standardizedRelativePath: $0.standardizedRelativePath,
                    requestGeneration: $0.requestGeneration,
                    pathGeneration: $0.pathGeneration,
                    state: .unavailable
                )
            }.sorted {
                if $0.standardizedRelativePath != $1.standardizedRelativePath {
                    return $0.standardizedRelativePath < $1.standardizedRelativePath
                }
                return $0.fileID.uuidString < $1.fileID.uuidString
            }
            yieldCodemapMarkerReadiness(WorkspaceCodemapMarkerReadinessEvent(
                rootEpoch: rootEpoch,
                revision: session.markerReadinessRevision &+ 1,
                changes: changes
            ))
        }
        guard session != nil || launch != nil || eligibilityFlight != nil || completedEligibility != nil
            || graphIndexRetry != nil
        else {
            return codemapCleanupFlightsByRootID[rootEpoch.rootID]
        }
        advanceCodemapGraphIndexInvalidationGeneration(rootEpoch: rootEpoch)
        guard let authority = session?.authority ?? launch?.authority ?? eligibilityFlight?.authority
            ?? completedEligibility?.authority ?? graphIndexRetry?.authority
        else {
            return codemapCleanupFlightsByRootID[rootEpoch.rootID]
        }
        let authorityGeneration = codemapAuthorityGenerationsByRootEpoch[rootEpoch]
            ?? authority.ingressGeneration
        codemapAuthorityGenerationsByRootEpoch[rootEpoch] = authorityGeneration == .max
            ? 0
            : authorityGeneration + 1
        session?.setupTask?.cancel()
        session?.graphStatusTask?.cancel()
        session?.graphWorkerRecoveryStatusTask?.cancel()
        let demandRecords = session.map { Array($0.demandsByFileID.values) } ?? []
        for record in demandRecords {
            record.task?.cancel()
        }
        for bundle in session.map({ Array($0.bundlesByRequestID.values) }) ?? [] {
            bundle.close()
        }
        let predecessorTasks = codemapPathInvalidationFlightsByRootEpoch[rootEpoch]
            .map { [$0.task] } ?? []
        let detached = DetachedCodemapSession(
            authority: authority,
            registry: session?.runtime?.bindingIntegrationRegistry,
            routeToken: session?.routeToken,
            engine: session?.engine,
            owners: demandRecords.map(\.owner),
            setupTask: session?.setupTask,
            demandTasks: demandRecords.compactMap(\.task),
            graphStatusTask: session?.graphStatusTask,
            graphWorkerRecoveryStatusTask: session?.graphWorkerRecoveryStatusTask,
            selectionGraph: session?.selectionGraph,
            preloadLaunchTask: launch?.task,
            eligibilityTask: eligibilityFlight?.task,
            graphIndexRetryTask: graphIndexRetry?.task,
            predecessorTasks: predecessorTasks,
            invalidationCommands: invalidationCommands.compactMap(
                standardizedCodemapInvalidationCommand
            ),
            graphInvalidationReason: graphInvalidationReason
        )
        return startCodemapCleanup(detached)
    }

    private func startCodemapCleanup(
        _ detached: DetachedCodemapSession
    ) -> CodemapCleanupFlight {
        if let existing = codemapCleanupFlightsByRootID[detached.authority.rootEpoch.rootID] {
            return existing
        }
        let cleanupID = UUID()
        let task = Task { [weak self] in
            for predecessorTask in detached.predecessorTasks {
                await predecessorTask.value
            }
            if let graphStatusTask = detached.graphStatusTask {
                await graphStatusTask.value
            }
            if let graphWorkerRecoveryStatusTask = detached.graphWorkerRecoveryStatusTask {
                await graphWorkerRecoveryStatusTask.value
            }
            await detached.selectionGraph?.shutdown(reason: detached.graphInvalidationReason)
            if let registry = detached.registry, let routeToken = detached.routeToken {
                _ = await registry.unregister(routeToken)
            }
            if let engine = detached.engine {
                await self?.applyCodemapInvalidationCommands(
                    detached.invalidationCommands,
                    rootEpoch: detached.authority.rootEpoch,
                    engine: engine
                )
                for owner in detached.owners {
                    _ = await engine.cancel(owner: owner)
                }
                if detached.invalidationCommands.contains(where: {
                    if case .unload = $0 { true } else { false }
                }) {
                    await engine.unloadRoot(rootEpoch: detached.authority.rootEpoch)
                }
            }
            if let setupTask = detached.setupTask {
                _ = await setupTask.value
            }
            if let preloadLaunchTask = detached.preloadLaunchTask {
                await preloadLaunchTask.value
            }
            if let eligibilityTask = detached.eligibilityTask {
                _ = await eligibilityTask.value
            }
            if let graphIndexRetryTask = detached.graphIndexRetryTask {
                await graphIndexRetryTask.value
            }
            for demandTask in detached.demandTasks {
                await demandTask.value
            }
            await self?.finishCodemapCleanup(
                rootID: detached.authority.rootEpoch.rootID,
                cleanupID: cleanupID
            )
        }
        let flight = CodemapCleanupFlight(
            id: cleanupID,
            rootEpoch: detached.authority.rootEpoch,
            task: task
        )
        codemapCleanupFlightsByRootID[detached.authority.rootEpoch.rootID] = flight
        return flight
    }

    private func applyCodemapInvalidationCommands(
        _ commands: [CodemapInvalidationCommand],
        rootEpoch: WorkspaceCodemapRootEpoch,
        engine: WorkspaceCodemapBindingEngine
    ) async {
        for command in commands {
            switch command {
            case let .modified(paths):
                _ = await engine.invalidateModified(
                    rootEpoch: rootEpoch,
                    standardizedRelativePaths: paths
                )
            case let .deleted(paths):
                _ = await engine.invalidateDeleted(
                    rootEpoch: rootEpoch,
                    standardizedRelativePaths: paths
                )
            case let .renamed(from, to):
                _ = await engine.invalidateRenamed(rootEpoch: rootEpoch, from: from, to: to)
            case .securityExcluded:
                // GraphIndex has already replaced the visible overlay slot. This command exists
                // only to route the immediate cumulative safety fence before marker publication.
                break
            case .watcherGap:
                _ = await engine.invalidateWatcherGap(rootEpoch: rootEpoch)
            case .checkout:
                _ = await engine.invalidateCheckout(rootEpoch: rootEpoch)
            case .repositoryAuthority:
                _ = await engine.invalidateRepositoryAuthority(rootEpoch: rootEpoch)
            case .catalogAdvanced:
                _ = await engine.invalidateCatalog(rootEpoch: rootEpoch)
            case .unload:
                break
            }
        }
    }

    private func finishCodemapCleanup(rootID: UUID, cleanupID: UUID) {
        guard codemapCleanupFlightsByRootID[rootID]?.id == cleanupID else { return }
        let rootEpoch = codemapCleanupFlightsByRootID[rootID]?.rootEpoch
        codemapCleanupFlightsByRootID.removeValue(forKey: rootID)
        if let rootEpoch {
            schedulePendingCodemapGraphIndexBuildIfFullyUnfenced(rootEpoch: rootEpoch)
        }
    }

    private func awaitCodemapCleanupFlights(rootIDs: Set<UUID>) async {
        let flights = rootIDs.compactMap { codemapCleanupFlightsByRootID[$0] }
        for flight in flights {
            await flight.task.value
        }
    }

    private func beginCodemapRootMutationFence(
        rootID: UUID,
        command: CodemapInvalidationCommand
    ) async -> CodemapRootMutationFenceToken? {
        guard let initialState = rootStatesByID[rootID] else { return nil }
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: rootID,
            rootLifetimeID: initialState.lifetimeID
        )
        let token: CodemapRootMutationFenceToken
        while true {
            guard await waitForCodemapRootMutationFenceIfNeeded(rootEpoch: rootEpoch),
                  !Task.isCancelled,
                  rootStatesByID[rootID]?.lifetimeID == rootEpoch.rootLifetimeID
            else {
                return nil
            }
            if codemapPathWorkIsQuiescent(rootEpoch: rootEpoch) {
                token = CodemapRootMutationFenceToken(id: UUID(), rootEpoch: rootEpoch)
                codemapRootMutationFenceTokensByRootEpoch[rootEpoch] = token
                break
            }
            // Drain path work before acquiring the root fence. Retained path flights wait on an
            // already-held root fence, so installing the root fence first would make each side
            // wait for the other. After path work drains, loop back through the root-fence lane so
            // competing root mutations remain serialized.
            guard await waitForCodemapPathQuiescenceIfNeeded(rootEpoch: rootEpoch) else {
                return nil
            }
        }
        var didTransferFenceOwnership = false
        defer {
            if !didTransferFenceOwnership {
                finishCodemapRootMutationFence(token, didCommitMutation: false)
            }
        }
        await fenceCodemapRootAuthority(rootIDs: [rootID], command: command)
        guard !Task.isCancelled,
              rootStatesByID[rootID]?.lifetimeID == rootEpoch.rootLifetimeID
        else {
            return nil
        }
        didTransferFenceOwnership = true
        return token
    }

    private func codemapPathWorkIsQuiescent(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        codemapPathInvalidationFlightsByRootEpoch[rootEpoch] == nil &&
            !codemapPathFenceTokensByID.values.contains(where: { $0.rootEpoch == rootEpoch })
    }

    private func waitForCodemapPathQuiescenceIfNeeded(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> Bool {
        while !codemapPathWorkIsQuiescent(rootEpoch: rootEpoch) {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if codemapPathWorkIsQuiescent(rootEpoch: rootEpoch) ||
                        Task.isCancelled ||
                        rootStatesByID[rootEpoch.rootID]?.lifetimeID != rootEpoch.rootLifetimeID
                    {
                        continuation.resume()
                    } else {
                        codemapPathQuiescenceWaitersByRootEpoch[rootEpoch, default: [:]][waiterID] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelCodemapPathQuiescenceWaiter(rootEpoch: rootEpoch, waiterID: waiterID) }
            }
            guard !Task.isCancelled,
                  rootStatesByID[rootEpoch.rootID]?.lifetimeID == rootEpoch.rootLifetimeID
            else { return false }
        }
        return true
    }

    private func cancelCodemapPathQuiescenceWaiter(
        rootEpoch: WorkspaceCodemapRootEpoch,
        waiterID: UUID
    ) {
        guard let continuation = codemapPathQuiescenceWaitersByRootEpoch[rootEpoch]?
            .removeValue(forKey: waiterID)
        else { return }
        if codemapPathQuiescenceWaitersByRootEpoch[rootEpoch]?.isEmpty == true {
            codemapPathQuiescenceWaitersByRootEpoch.removeValue(forKey: rootEpoch)
        }
        continuation.resume()
    }

    private func resumeCodemapPathQuiescenceWaitersIfNeeded(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        guard codemapPathWorkIsQuiescent(rootEpoch: rootEpoch) else { return }
        let waiters = codemapPathQuiescenceWaitersByRootEpoch.removeValue(forKey: rootEpoch) ?? [:]
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func waitForCodemapRootMutationFenceIfNeeded(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> Bool {
        while codemapRootMutationFenceTokensByRootEpoch[rootEpoch] != nil {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if codemapRootMutationFenceTokensByRootEpoch[rootEpoch] == nil || Task.isCancelled {
                        continuation.resume()
                    } else {
                        codemapRootMutationFenceWaitersByRootEpoch[rootEpoch, default: [:]][waiterID] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelCodemapRootMutationFenceWaiter(rootEpoch: rootEpoch, waiterID: waiterID) }
            }
            guard !Task.isCancelled,
                  rootStatesByID[rootEpoch.rootID]?.lifetimeID == rootEpoch.rootLifetimeID
            else { return false }
        }
        return true
    }

    private func cancelCodemapRootMutationFenceWaiter(
        rootEpoch: WorkspaceCodemapRootEpoch,
        waiterID: UUID
    ) {
        guard let continuation = codemapRootMutationFenceWaitersByRootEpoch[rootEpoch]?
            .removeValue(forKey: waiterID)
        else { return }
        if codemapRootMutationFenceWaitersByRootEpoch[rootEpoch]?.isEmpty == true {
            codemapRootMutationFenceWaitersByRootEpoch.removeValue(forKey: rootEpoch)
        }
        continuation.resume()
    }

    private func finishCodemapRootMutationFence(
        _ token: CodemapRootMutationFenceToken?,
        didCommitMutation: Bool
    ) {
        guard let token,
              codemapRootMutationFenceTokensByRootEpoch[token.rootEpoch] == token
        else { return }
        codemapRootMutationFenceTokensByRootEpoch.removeValue(forKey: token.rootEpoch)
        // Root fencing detaches the previous authority before the mutation begins. Restore
        // preload even when the disk operation fails; successful mutations observe the same
        // post-publication scheduling point.
        if rootStatesByID[token.rootEpoch.rootID]?.lifetimeID == token.rootEpoch.rootLifetimeID {
            codemapGraphIndexBuildReschedulePendingRootEpochs.insert(token.rootEpoch)
        }
        _ = didCommitMutation
        let waiters = codemapRootMutationFenceWaitersByRootEpoch.removeValue(forKey: token.rootEpoch) ?? [:]
        for continuation in waiters.values {
            continuation.resume()
        }
        schedulePendingCodemapGraphIndexBuildIfFullyUnfenced(rootEpoch: token.rootEpoch)
    }

    private func schedulePendingCodemapGraphIndexBuildIfFullyUnfenced(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        if codemapGenerationIsSuspended(rootEpoch: rootEpoch) {
            codemapGraphIndexBuildReschedulePendingRootEpochs.remove(rootEpoch)
            return
        }
        guard codemapGraphIndexBuildReschedulePendingRootEpochs.contains(rootEpoch),
              codemapRootMutationFenceTokensByRootEpoch[rootEpoch] == nil,
              codemapPathInvalidationFlightsByRootEpoch[rootEpoch] == nil,
              !codemapPathFenceTokensByID.values.contains(where: { $0.rootEpoch == rootEpoch }),
              codemapCleanupFlightsByRootID[rootEpoch.rootID] == nil,
              rootStatesByID[rootEpoch.rootID]?.lifetimeID == rootEpoch.rootLifetimeID
        else { return }
        codemapGraphIndexBuildReschedulePendingRootEpochs.remove(rootEpoch)
        scheduleCodemapGraphIndexBuildAfterRootReady(rootEpoch: rootEpoch)
    }

    private func fenceCodemapRootAuthority(
        rootIDs: [UUID],
        command: CodemapInvalidationCommand
    ) async {
        let loadedRootIDs = Set(rootIDs.filter { rootStatesByID[$0] != nil })
        guard !loadedRootIDs.isEmpty else { return }
        let affectedRootEpochs = Set(codemapSessionsByRootEpoch.keys)
            .union(codemapGraphIndexBuildLaunchesByRootEpoch.keys)
            .union(codemapEligibilityFlightsByRootEpoch.keys)
            .union(codemapCompletedEligibilityByRootEpoch.keys)
            .union(codemapGraphIndexBuildRetriesByRootEpoch.keys)
            .union(codemapAuthorityGenerationsByRootEpoch.keys)
            .filter { loadedRootIDs.contains($0.rootID) }
        if case .watcherGap = command {
            for rootEpoch in affectedRootEpochs {
                if let engine = codemapSessionsByRootEpoch[rootEpoch]?.engine {
                    _ = await engine.invalidateWatcherGap(rootEpoch: rootEpoch)
                } else {
                    // Terminal eligibility roots do not own a binding engine yet. Preserve their
                    // store-owned retry path while graph-bearing roots reconcile through the
                    // engine-owned pull loop above. A watcher gap invalidates the prior terminal
                    // classification, so retire both its launch and stable setup disposition.
                    _ = cancelCodemapGraphIndexBuildLaunchForInvalidation(rootEpoch: rootEpoch)
                    codemapCompletedEligibilityByRootEpoch.removeValue(forKey: rootEpoch)
                    if var session = codemapSessionsByRootEpoch[rootEpoch], session.engine == nil {
                        session.setupTask?.cancel()
                        session.setupTask = nil
                        session.setupDisposition = nil
                        codemapSessionsByRootEpoch[rootEpoch] = session
                    }
                    codemapGraphIndexBuildReschedulePendingRootEpochs.insert(rootEpoch)
                    schedulePendingCodemapGraphIndexBuildIfFullyUnfenced(rootEpoch: rootEpoch)
                }
            }
            return
        }
        for rootEpoch in affectedRootEpochs {
            let previousGeneration = codemapAuthorityGenerationsByRootEpoch[rootEpoch]
            let cleanup = detachCodemapSession(
                rootEpoch: rootEpoch,
                invalidationCommands: [command]
            )
            if cleanup == nil,
               let previousGeneration,
               codemapAuthorityGenerationsByRootEpoch[rootEpoch] == previousGeneration
            {
                advanceCodemapGraphIndexInvalidationGeneration(rootEpoch: rootEpoch)
                codemapAuthorityGenerationsByRootEpoch[rootEpoch] = previousGeneration == .max
                    ? 0
                    : previousGeneration + 1
            }
        }
        await awaitCodemapCleanupFlights(rootIDs: loadedRootIDs)
    }

    func fenceCodemapAuthorityForCheckoutMutation(rootIDs: [UUID]) async {
        await fenceCodemapRootAuthority(rootIDs: rootIDs, command: .checkout)
    }

    func fenceCodemapAuthorityForRepositoryAuthorityMutation(rootIDs: [UUID]) async {
        await fenceCodemapRootAuthority(rootIDs: rootIDs, command: .repositoryAuthority)
    }

    @discardableResult
    func createFile(
        rootID: UUID,
        relativePath: String,
        content: String,
        validating rootScope: WorkspaceLookupRootScope? = nil
    ) async throws -> WorkspaceFileCatalogMaterializationResult {
        if let rootScope {
            guard rootScopeAvailability(rootScope) == .available,
                  rootsForPathLookup(scope: rootScope).contains(where: { $0.id == rootID })
            else {
                throw WorkspaceFileContextStoreError.rootNotLoaded(rootID)
            }
        }
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let codemapFence = beginCodemapPathFence(
            rootID: rootID,
            commands: [.modified([standardizedRelativePath])]
        )
        var didCommitCatalogMutation = false
        var retainedFenceUntilMutationDrain = false
        defer {
            if !retainedFenceUntilMutationDrain {
                releaseCodemapPathFence(
                    codemapFence,
                    didCommitMutation: didCommitCatalogMutation
                )
            }
        }
        do {
            try await state.service.createFile(atRelativePath: standardizedRelativePath, content: content)
        } catch is CancellationError {
            retainedFenceUntilMutationDrain = true
            retainCodemapPathFenceUntilMutationDrain(
                codemapFence,
                service: state.service,
                relativePaths: [standardizedRelativePath]
            )
            throw CancellationError()
        }
        let result = try await materializeCatalogFileAfterDiskWrite(
            rootID: rootID,
            relativePath: standardizedRelativePath,
            codemapPathLocalMutation: true
        )
        if case .materialized = result {
            didCommitCatalogMutation = true
        }
        return result
    }

    @discardableResult
    func editFile(
        rootID: UUID,
        relativePath: String,
        newContent: String,
        expectedOriginalContent: String? = nil
    ) async throws -> WorkspaceFileCatalogMaterializationResult? {
        let state = try state(for: rootID)
        let expectedLifetimeID = state.lifetimeID
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let codemapFence = beginCodemapPathFence(
            rootID: rootID,
            commands: [.modified([standardizedRelativePath])]
        )
        var didCommitCodemapMutation = false
        var retainedFenceUntilMutationDrain = false
        defer {
            if !retainedFenceUntilMutationDrain {
                releaseCodemapPathFence(
                    codemapFence,
                    didCommitMutation: didCommitCodemapMutation
                )
            }
        }
        let deferredPublicationToken: FileSystemDeferredEditPublicationToken
        do {
            let token = if let expectedOriginalContent {
                try await state.service.editFileIfUnchanged(
                    atRelativePath: standardizedRelativePath,
                    newContent: newContent,
                    expectedOriginalContent: expectedOriginalContent,
                    modificationPublicationPolicy: .deferSyntheticModificationToSuccessfulCaller
                )
            } else {
                try await state.service.editFile(
                    atRelativePath: standardizedRelativePath,
                    newContent: newContent,
                    modificationPublicationPolicy: .deferSyntheticModificationToSuccessfulCaller
                )
            }
            guard let token else {
                throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                    "store-owned edit completed without a deferred modification publication token"
                )
            }
            deferredPublicationToken = token
            didCommitCodemapMutation = true
        } catch is CancellationError {
            retainedFenceUntilMutationDrain = true
            retainCodemapPathFenceUntilMutationDrain(
                codemapFence,
                service: state.service,
                relativePaths: [standardizedRelativePath]
            )
            throw CancellationError()
        } catch FileSystemError.fileNotFound {
            didCommitCodemapMutation = await withCodemapPathLocalCatalogMutation(rootID: rootID) {
                await pruneCatalogFileMissingOnDisk(
                    rootID: rootID,
                    relativePath: standardizedRelativePath,
                    publishDelta: true
                )
            }
            throw FileSystemError.fileNotFound
        }

        do {
            #if DEBUG
                if let storeEditDeferredPublicationDidRegisterHandler {
                    await storeEditDeferredPublicationDidRegisterHandler(rootID, standardizedRelativePath)
                }
            #endif
            try Task.checkCancellation()
            guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else {
                throw WorkspaceFileContextStoreError.rootNotLoaded(rootID)
            }

            let result: WorkspaceFileCatalogMaterializationResult?
            let publishedCanonicalModification: Bool
            if let file = await file(rootID: rootID, relativePath: standardizedRelativePath) {
                invalidateSearchContent(file)
                publishedCanonicalModification = isDiscoverableFileID(file.id)
                if publishedCanonicalModification {
                    await publishAppliedIndexEvent(root: state.root, modifiedFileIDs: [file.id])
                    #if DEBUG
                        MCPApplyEditsRebaseProbeRecorder.recordStoreModification(
                            rootID: rootID,
                            fileID: file.id,
                            generation: appliedIndexGenerationsByRootID[rootID] ?? 0
                        )
                    #endif
                }
                result = .materialized(file)
            } else {
                let materialization = try await materializeCatalogFileAfterDiskWrite(
                    rootID: rootID,
                    relativePath: standardizedRelativePath,
                    codemapPathLocalMutation: true
                )
                result = materialization
                switch materialization {
                case let .materialized(file):
                    publishedCanonicalModification = isDiscoverableFileID(file.id)
                case .ineligible:
                    publishedCanonicalModification = false
                }
            }

            await state.service.resolveDeferredEditPublication(
                deferredPublicationToken,
                resolution: publishedCanonicalModification
                    ? .callerPublishedCanonicalModification
                    : .publishSyntheticFallback
            )
            return result
        } catch {
            await state.service.resolveDeferredEditPublication(
                deferredPublicationToken,
                resolution: .publishSyntheticFallback
            )
            throw error
        }
    }

    func moveFile(rootID: UUID, from oldRelativePath: String, to newRelativePath: String) async throws {
        let state = try state(for: rootID)
        let oldPath = StandardizedPath.relative(oldRelativePath)
        let newPath = StandardizedPath.relative(newRelativePath)
        let codemapFence = beginCodemapPathFence(
            rootID: rootID,
            commands: [.renamed(from: oldPath, to: newPath)]
        )
        var didCommitCodemapMutation = false
        var retainedFenceUntilMutationDrain = false
        defer {
            if !retainedFenceUntilMutationDrain {
                releaseCodemapPathFence(
                    codemapFence,
                    didCommitMutation: didCommitCodemapMutation
                )
            }
        }
        let oldFile = await file(rootID: rootID, relativePath: oldPath)
        let oldFileWasDiscoverable = oldFile.map { isDiscoverableFileID($0.id) } ?? false
        do {
            try await state.service.moveFile(
                atRelativePath: oldPath,
                toRelativePath: newPath
            )
        } catch is CancellationError {
            retainedFenceUntilMutationDrain = true
            retainCodemapPathFenceUntilMutationDrain(
                codemapFence,
                service: state.service,
                relativePaths: [oldPath, newPath]
            )
            throw CancellationError()
        }
        didCommitCodemapMutation = true
        let destinationEligibility = await state.service.registerExplicitlyManagedRegularFile(relativePath: newPath)
        let destinationManagedOnly: Bool
        switch destinationEligibility {
        case .eligible:
            destinationManagedOnly = false
        case .ineligible(.ignored):
            destinationManagedOnly = true
        case let .ineligible(reason):
            throw WorkspaceFileContextStoreError.catalogMaterializationFailed("moved file is not catalog-eligible at destination: \(reason.description)")
        }
        await withCodemapPathLocalCatalogMutation(rootID: rootID) {
            await removeFile(relativePath: oldPath, rootID: rootID)
            await indexFile(relativePath: newPath, root: state.root, managedOnly: destinationManagedOnly)
            let upsertedFile = destinationManagedOnly ? nil : await file(rootID: rootID, relativePath: newPath)
            await publishAppliedIndexEvent(
                root: state.root,
                upsertedFiles: upsertedFile.map { [$0] } ?? [],
                removedFileIDs: oldFileWasDiscoverable ? (oldFile.map { [$0.id] } ?? []) : [],
                removedFilePaths: oldFileWasDiscoverable ? (oldFile.map { [$0.standardizedRelativePath] } ?? []) : []
            )
        }
    }

    func deleteFile(rootID: UUID, relativePath: String) async throws {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let codemapFence = beginCodemapPathFence(
            rootID: rootID,
            commands: [.deleted([standardizedRelativePath])]
        )
        var didCommitCodemapMutation = false
        var retainedFenceUntilMutationDrain = false
        defer {
            if !retainedFenceUntilMutationDrain {
                releaseCodemapPathFence(
                    codemapFence,
                    didCommitMutation: didCommitCodemapMutation
                )
            }
        }
        let oldFile = await file(rootID: rootID, relativePath: standardizedRelativePath)
        let oldFileWasDiscoverable = oldFile.map { isDiscoverableFileID($0.id) } ?? false
        do {
            try await state.service.deleteFile(atRelativePath: standardizedRelativePath)
        } catch is CancellationError {
            retainedFenceUntilMutationDrain = true
            retainCodemapPathFenceUntilMutationDrain(
                codemapFence,
                service: state.service,
                relativePaths: [standardizedRelativePath]
            )
            throw CancellationError()
        } catch FileSystemError.fileNotFound {
            if oldFile != nil {
                didCommitCodemapMutation = await withCodemapPathLocalCatalogMutation(rootID: rootID) {
                    await pruneCatalogFileMissingOnDisk(
                        rootID: rootID,
                        relativePath: standardizedRelativePath,
                        publishDelta: true
                    )
                }
            }
            throw FileSystemError.fileNotFound
        }
        didCommitCodemapMutation = true
        await withCodemapPathLocalCatalogMutation(rootID: rootID) {
            await removeFile(relativePath: standardizedRelativePath, rootID: rootID)
            if let oldFile, oldFileWasDiscoverable {
                await publishAppliedIndexEvent(root: state.root, removedFileIDs: [oldFile.id], removedFilePaths: [oldFile.standardizedRelativePath])
            }
        }
    }

    func moveItemToTrash(rootID: UUID, relativePath: String) async throws {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let oldFile = await file(rootID: rootID, relativePath: standardizedRelativePath)
        let oldFileWasDiscoverable = oldFile.map { isDiscoverableFileID($0.id) } ?? false
        let oldFolder = await folder(rootID: rootID, relativePath: standardizedRelativePath)
        let oldFolderWasDiscoverable = oldFolder.map { isDiscoverableFolderID($0.id) } ?? false
        // P4-6b table-deletion conversion: the descendant-file-path scan (`state
        // .fileIDsByRelativePath.keys` prefix filter) is now `descendantFiles(in:)`, the same
        // owning-root-then-page primitive already used elsewhere for folder descendant walks.
        let affectedPaths: Set<String> = if let oldFolder {
            await Set(descendantFiles(in: oldFolder.id).map(\.standardizedRelativePath))
        } else {
            [standardizedRelativePath]
        }
        let codemapFence = beginCodemapPathFence(
            rootID: rootID,
            commands: [.deleted(affectedPaths)]
        )
        var didCommitCodemapMutation = false
        var retainedFenceUntilMutationDrain = false
        defer {
            if !retainedFenceUntilMutationDrain {
                releaseCodemapPathFence(
                    codemapFence,
                    didCommitMutation: didCommitCodemapMutation
                )
            }
        }
        do {
            try await state.service.moveItemToTrash(atRelativePath: standardizedRelativePath)
        } catch is CancellationError {
            retainedFenceUntilMutationDrain = true
            retainCodemapPathFenceUntilMutationDrain(
                codemapFence,
                service: state.service,
                relativePaths: [standardizedRelativePath]
            )
            throw CancellationError()
        } catch FileSystemError.fileNotFound {
            if oldFile != nil || oldFolder != nil {
                didCommitCodemapMutation = await withCodemapPathLocalCatalogMutation(rootID: rootID) {
                    await pruneCatalogItemMissingOnDisk(
                        rootID: rootID,
                        relativePath: standardizedRelativePath,
                        publishDelta: true
                    )
                }
            }
            throw FileSystemError.fileNotFound
        }
        didCommitCodemapMutation = true
        await withCodemapPathLocalCatalogMutation(rootID: rootID) {
            if let oldFile {
                await removeFile(relativePath: standardizedRelativePath, rootID: rootID)
                if oldFileWasDiscoverable {
                    await publishAppliedIndexEvent(root: state.root, removedFileIDs: [oldFile.id], removedFilePaths: [oldFile.standardizedRelativePath])
                }
            } else if let oldFolder {
                let removal = await removeFolderTree(relativePath: standardizedRelativePath, rootID: rootID)
                await publishAppliedIndexEvent(
                    root: state.root,
                    removedFileIDs: removal.fileIDs,
                    removedFolderIDs: removal.folderIDs.isEmpty && oldFolderWasDiscoverable ? [oldFolder.id] : removal.folderIDs,
                    removedFilePaths: removal.filePaths,
                    removedFolderPaths: removal.folderPaths.isEmpty && oldFolderWasDiscoverable ? [oldFolder.standardizedRelativePath] : removal.folderPaths
                )
            }
        }
    }

    func validateCatalogFileStillPresent(_ file: WorkspaceFileRecord) async -> WorkspaceFileRecord? {
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.contentFreshnessStoreEntered,
            correlation: lifecycleCorrelation
        )
        let validationState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.contentFreshnessValidationStoreActorBody)
        var outcome = "missing"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentFreshnessValidationStoreActorBody,
                validationState,
                EditFlowPerf.Dimensions(outcome: outcome)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.contentFreshnessStoreReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(outcome: outcome)
            )
        }
        guard let state = rootStatesByID[file.rootID],
              let current = await self.file(rootID: file.rootID, relativePath: file.standardizedRelativePath)
        else { return nil }
        if await state.service.regularFileExistsOnDisk(relativePath: current.standardizedRelativePath) {
            outcome = "current"
            return current
        }
        _ = await fenceAndPruneCatalogFileMissingOnDisk(
            rootID: file.rootID,
            relativePath: current.standardizedRelativePath,
            publishDelta: true
        )
        return nil
    }

    @discardableResult
    func pruneMissingCatalogFilesForExactMutationLookup(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> Bool {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var candidates: [WorkspaceFileRecord] = []
        func appendCandidate(rootID: UUID, relativePath: String) async {
            guard let file = await file(rootID: rootID, relativePath: relativePath),
                  !candidates.contains(where: { $0.id == file.id })
            else { return }
            candidates.append(file)
        }
        func appendAbsoluteCandidate(_ path: String) async {
            let absolute = StandardizedPath.absolute(path)
            guard let root = loadedRoot(containing: absolute),
                  rootsForPathLookup(scope: rootScope).contains(where: { $0.id == root.id }),
                  let file = await file(rootID: root.id, relativePath: relativePath(for: absolute, rootPath: root.standardizedFullPath)),
                  !candidates.contains(where: { $0.id == file.id })
            else { return }
            candidates.append(file)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardizedInput = (expanded as NSString).standardizingPath
        let roots = rootRefs(scope: rootScope)
        if standardizedInput.hasPrefix("/") {
            await appendAbsoluteCandidate(standardizedInput)
            let pseudoAlias = standardizedInput.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch WorkspaceAliasResolver.resolve(userPath: pseudoAlias, roots: roots, options: RootAliasOptions(requireRemainder: true)) {
            case let .prefixed(root, _, remainder):
                await appendCandidate(rootID: root.id, relativePath: remainder)
            case .ambiguous, .bareRoot, .notAliasPrefixed:
                break
            }
        } else {
            switch WorkspaceAliasResolver.resolve(userPath: standardizedInput, roots: roots, options: RootAliasOptions(requireRemainder: true)) {
            case let .prefixed(root, _, remainder):
                await appendCandidate(rootID: root.id, relativePath: remainder)
            case .ambiguous, .bareRoot, .notAliasPrefixed:
                break
            }
            let relative = StandardizedPath.relative(standardizedInput)
            if !relative.isEmpty {
                for root in roots {
                    await appendCandidate(rootID: root.id, relativePath: relative)
                }
            }
        }

        var pruned = false
        for candidate in candidates {
            if await validateCatalogFileStillPresent(candidate) == nil {
                pruned = true
            }
        }
        return pruned
    }

    /// Returns an exact cataloged file without touching disk. Disk recovery for ignored
    /// files is intentionally reserved for absolute-path misses.
    func lookupCatalogFileForExplicitRequest(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceExplicitCatalogFileLookupResult {
        await lookupCatalogFileForExplicitRequest(
            userPath,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func lookupCatalogFileForExplicitRequest(
        _ userPath: String,
        rootRefs roots: [WorkspaceRootRef]
    ) async -> WorkspaceExplicitCatalogFileLookupResult {
        #if DEBUG || EDIT_FLOW_PERF
            var exactCatalogLookupOutcome = "noCandidate"
            var exactCatalogLookupRoute = "empty"
            let exactCatalogLookupActorBody = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.exactCatalogLookupActorBody)
            defer {
                let dimensions = EditFlowPerf.Dimensions(status: exactCatalogLookupRoute, outcome: exactCatalogLookupOutcome)
                EditFlowPerf.end(
                    EditFlowPerf.Stage.ReadFile.exactCatalogLookupActorBody,
                    exactCatalogLookupActorBody,
                    dimensions
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.ReadFile.exactCatalogLookupResolved,
                    dimensions
                )
            }
        #endif

        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noCandidate }
        guard !StandardizedPath.containsNUL(trimmed) else {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "blocked"
                exactCatalogLookupOutcome = "blocked"
            #endif
            return .blocked
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = StandardizedPath.absolute(expanded)

        if standardized.hasPrefix("/") {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "absolute"
            #endif
            guard let root = roots
                .filter({ StandardizedPath.isDescendant(standardized, of: $0.standardizedFullPath) })
                .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
            else { return .noCandidate }
            let relativePath = String(standardized.dropFirst(root.standardizedFullPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let file = await file(rootID: root.id, relativePath: relativePath) else { return .noCandidate }
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "matched"
            #endif
            return .matched(file)
        }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: roots,
            options: RootAliasOptions(requireRemainder: true)
        ) {
        case let .prefixed(root, _, remainder):
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "rootAlias"
            #endif
            guard let file = await file(rootID: root.id, relativePath: remainder) else { return .noCandidate }
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "matched"
            #endif
            return .matched(file)
        case .ambiguous:
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "rootAlias"
                exactCatalogLookupOutcome = "ambiguous"
            #endif
            return .ambiguous
        case .bareRoot, .notAliasPrefixed:
            break
        }

        #if DEBUG || EDIT_FLOW_PERF
            exactCatalogLookupRoute = "relative"
        #endif
        let relativePath = StandardizedPath.relative(standardized)
        guard !relativePath.isEmpty,
              relativePath != "..",
              !relativePath.hasPrefix("../")
        else {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "blocked"
            #endif
            return .blocked
        }
        var matches: [WorkspaceFileRecord] = []
        for root in roots {
            guard let match = await file(rootID: root.id, relativePath: relativePath) else { continue }
            matches.append(match)
        }
        guard matches.count <= 1 else {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "ambiguous"
            #endif
            return .ambiguous
        }
        guard let match = matches.first else { return .noCandidate }
        #if DEBUG || EDIT_FLOW_PERF
            exactCatalogLookupOutcome = "matched"
        #endif
        return .matched(match)
    }

    func resolveExactExistingWorkspaceFile(
        _ input: WorkspaceExactFileInput,
        namespace: WorkspaceExactFileNamespace
    ) async throws -> WorkspaceExactExistingFileResolution {
        switch input {
        case let .absolute(path):
            guard let target = exactAbsoluteTarget(path, namespace: namespace) else { return .noCandidate }
            if target.relativePath.isEmpty {
                guard rootStatesByID[target.binding.lookupRoot.id] != nil else { return .claimedMissing }
                return try .directory(exactDirectoryMatch(
                    binding: target.binding,
                    relativePath: target.relativePath,
                    namespace: namespace
                ))
            }
            let candidates = await exactFileCandidates(
                relativePath: target.relativePath,
                bindings: [target.binding]
            )
            if let directoryBinding = candidates.directoryBindings.first {
                return try .directory(exactDirectoryMatch(
                    binding: directoryBinding,
                    relativePath: target.relativePath,
                    namespace: namespace
                ))
            }
            switch try await materializeSingleExactFile(
                from: candidates,
                relativePath: target.relativePath
            ) {
            case let .materialized(file):
                return try await .matched(exactExistingFileMatch(file, namespace: namespace))
            case .blocked:
                return .issue(.unresolved(input: path))
            case .noCandidate:
                return .claimedMissing
            case .ambiguous:
                throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                    "An exact absolute path produced multiple candidates: \(path)."
                )
            }

        case let .explicitRoot(alias, relativePath):
            switch exactAliasBinding(alias: alias, namespace: namespace) {
            case let .success(binding):
                let candidates = await exactFileCandidates(
                    relativePath: relativePath,
                    bindings: [binding]
                )
                if let directoryBinding = candidates.directoryBindings.first {
                    return try .directory(exactDirectoryMatch(
                        binding: directoryBinding,
                        relativePath: relativePath,
                        namespace: namespace
                    ))
                }
                switch try await materializeSingleExactFile(from: candidates, relativePath: relativePath) {
                case let .materialized(file):
                    return try await .matched(exactExistingFileMatch(file, namespace: namespace))
                case .blocked:
                    return .issue(.unresolved(input: input.renderedPath))
                case .noCandidate:
                    return .claimedMissing
                case .ambiguous:
                    throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                        "An explicit root path produced multiple candidates: \(input.renderedPath)."
                    )
                }
            case let .failure(issue):
                return .issue(issue)
            }

        case let .relative(relativePath):
            let literalCandidates = await exactFileCandidates(
                relativePath: relativePath,
                bindings: namespace.rootBindings
            )
            if literalCandidates.matches.count > 1 {
                return .issue(.ambiguousRootMatch(
                    input: relativePath,
                    candidateRoots: literalCandidates.matches.map(\.binding.preferredClientRoot)
                ))
            }
            if literalCandidates.blocked || literalCandidates.hasUnavailableBinding {
                return .issue(.unresolved(input: relativePath))
            }
            if let literalCandidate = literalCandidates.matches.first {
                switch try await materializeSingleExactFile(
                    from: literalCandidates,
                    relativePath: relativePath
                ) {
                case let .materialized(file):
                    return try await .matched(exactExistingFileMatch(file, namespace: namespace))
                case .blocked:
                    return .issue(.unresolved(input: relativePath))
                case .noCandidate:
                    return .noCandidate
                case .ambiguous:
                    throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                        "A single literal candidate became ambiguous: \(literalCandidate.binding.lookupRoot.fullPath)."
                    )
                }
            }
            if literalCandidates.directoryBindings.count > 1 {
                return .issue(.ambiguousRootMatch(
                    input: relativePath,
                    candidateRoots: literalCandidates.directoryBindings.map(\.preferredClientRoot)
                ))
            }
            if let directoryBinding = literalCandidates.directoryBindings.first {
                return try .directory(exactDirectoryMatch(
                    binding: directoryBinding,
                    relativePath: relativePath,
                    namespace: namespace
                ))
            }
            if literalCandidates.blocked {
                return .issue(.unresolved(input: relativePath))
            }

            switch WorkspaceAliasResolver.resolve(
                userPath: relativePath,
                roots: namespace.clientRoots,
                options: RootAliasOptions(requireRemainder: true)
            ) {
            case let .prefixed(clientRoot, _, remainder):
                guard let binding = namespace.rootBindings.first(where: {
                    $0.clientRoots.contains(where: { $0.id == clientRoot.id })
                }) else { return .noCandidate }
                let aliasCandidates = await exactFileCandidates(
                    relativePath: remainder,
                    bindings: [binding]
                )
                if let directoryBinding = aliasCandidates.directoryBindings.first {
                    return try .directory(exactDirectoryMatch(
                        binding: directoryBinding,
                        relativePath: remainder,
                        namespace: namespace
                    ))
                }
                switch try await materializeSingleExactFile(from: aliasCandidates, relativePath: remainder) {
                case let .materialized(file):
                    return try await .matched(exactExistingFileMatch(file, namespace: namespace))
                case .blocked:
                    return .issue(.unresolved(input: relativePath))
                case .noCandidate:
                    return .noCandidate
                case .ambiguous:
                    throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                        "One alias binding produced multiple exact candidates: \(binding.lookupRoot.fullPath)."
                    )
                }
            case let .ambiguous(alias, matchingRoots):
                return .issue(.ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
            case .bareRoot, .notAliasPrefixed:
                return .noCandidate
            }
        }
    }

    private func exactAbsoluteTarget(
        _ path: String,
        namespace: WorkspaceExactFileNamespace
    ) -> (binding: WorkspaceExactFileNamespace.RootBinding, relativePath: String)? {
        let standardized = StandardizedPath.absolute(path)
        let physicalMatch = namespace.rootBindings
            .filter {
                $0.lookupRole == .projectedPhysical
                    && StandardizedPath.isDescendant(standardized, of: $0.lookupRoot.standardizedFullPath)
            }
            .max { $0.lookupRoot.standardizedFullPath.count < $1.lookupRoot.standardizedFullPath.count }
        if let physicalMatch {
            return (
                physicalMatch,
                relativePath(for: standardized, rootPath: physicalMatch.lookupRoot.standardizedFullPath)
            )
        }

        let clientMatch = namespace.rootBindings.flatMap { binding in
            binding.clientRoots.map { (clientRoot: $0, binding: binding) }
        }
        .filter { StandardizedPath.isDescendant(standardized, of: $0.clientRoot.standardizedFullPath) }
        .max { $0.clientRoot.standardizedFullPath.count < $1.clientRoot.standardizedFullPath.count }
        guard let clientMatch else { return nil }
        return (
            clientMatch.binding,
            relativePath(for: standardized, rootPath: clientMatch.clientRoot.standardizedFullPath)
        )
    }

    private func exactAliasBinding(
        alias: String,
        namespace: WorkspaceExactFileNamespace
    ) -> Result<WorkspaceExactFileNamespace.RootBinding, PathResolutionIssue> {
        let matches = namespace.rootBindings.compactMap { binding -> (
            binding: WorkspaceExactFileNamespace.RootBinding,
            roots: [WorkspaceRootRef]
        )? in
            let roots = binding.clientRoots.filter {
                namespace.explicitAlias(clientRootID: $0.id)?.caseInsensitiveCompare(alias) == .orderedSame
            }
            return roots.isEmpty ? nil : (binding, roots)
        }
        guard matches.count <= 1 else {
            return .failure(.ambiguousAlias(
                alias: alias,
                matchingRoots: matches.flatMap(\.roots)
            ))
        }
        guard let match = matches.first else { return .failure(.unresolved(input: alias)) }
        return .success(match.binding)
    }

    private func exactDirectoryMatch(
        binding: WorkspaceExactFileNamespace.RootBinding,
        relativePath: String,
        namespace: WorkspaceExactFileNamespace
    ) throws -> WorkspaceExactDirectoryMatch {
        let displayPath: String
        if relativePath.isEmpty {
            displayPath = binding.preferredClientRoot.name
        } else if namespace.clientRoots.count == 1 {
            displayPath = relativePath
        } else {
            guard let alias = namespace.explicitAlias(clientRootID: binding.preferredClientRoot.id) else {
                throw WorkspaceFileContextStoreError.exactFileNamespaceMissingAlias(binding.preferredClientRoot.id)
            }
            displayPath = "\(alias)//\(relativePath)"
        }
        return WorkspaceExactDirectoryMatch(
            lookupRoot: binding.lookupRoot,
            relativePath: relativePath,
            displayPath: displayPath
        )
    }

    private struct ExactFileCandidate {
        let binding: WorkspaceExactFileNamespace.RootBinding
        let file: WorkspaceFileRecord?
    }

    private struct ExactFileCandidates {
        let matches: [ExactFileCandidate]
        let blocked: Bool
        let hasUnavailableBinding: Bool
        let directoryBindings: [WorkspaceExactFileNamespace.RootBinding]
    }

    private func exactFileCandidates(
        relativePath: String,
        bindings: [WorkspaceExactFileNamespace.RootBinding]
    ) async -> ExactFileCandidates {
        var matches: [ExactFileCandidate] = []
        var blocked = false
        var hasUnavailableBinding = false
        var directoryBindings: [WorkspaceExactFileNamespace.RootBinding] = []
        for binding in bindings {
            if let candidate = await file(rootID: binding.lookupRoot.id, relativePath: relativePath),
               let current = await validateCatalogFileStillPresent(candidate)
            {
                matches.append(ExactFileCandidate(binding: binding, file: current))
                continue
            }
            guard let state = rootStatesByID[binding.lookupRoot.id] else {
                hasUnavailableBinding = true
                continue
            }
            switch await state.service.catalogRegularFileEligibility(relativePath: relativePath) {
            case .eligible, .ineligible(.ignored):
                matches.append(ExactFileCandidate(binding: binding, file: nil))
            case .ineligible(.missingOrDirectory):
                if directoryAppearsPresentOnDisk(root: state.root, relativePath: relativePath) {
                    directoryBindings.append(binding)
                }
                _ = await fenceAndPruneCatalogFileMissingOnDisk(
                    rootID: binding.lookupRoot.id,
                    relativePath: relativePath,
                    publishDelta: true
                )
            case .ineligible:
                blocked = true
            }
        }
        return ExactFileCandidates(
            matches: matches,
            blocked: blocked,
            hasUnavailableBinding: hasUnavailableBinding,
            directoryBindings: directoryBindings
        )
    }

    private func materializeSingleExactFile(
        from candidates: ExactFileCandidates,
        relativePath: String
    ) async throws -> WorkspaceExplicitFileMaterializationResult {
        guard candidates.matches.count <= 1 else { return .ambiguous }
        guard let candidate = candidates.matches.first else {
            return candidates.blocked ? .blocked : .noCandidate
        }
        if let file = candidate.file { return .materialized(file) }
        let physicalPath = StandardizedPath.join(
            standardizedRoot: candidate.binding.lookupRoot.standardizedFullPath,
            standardizedRelativePath: relativePath
        )
        return try await materializeExplicitlyRequestedFile(
            physicalPath,
            rootRefs: [candidate.binding.lookupRoot]
        )
    }

    private func exactExistingFileMatch(
        _ file: WorkspaceFileRecord,
        namespace: WorkspaceExactFileNamespace
    ) async throws -> WorkspaceExactExistingFileMatch {
        let candidates = await exactFileCandidates(
            relativePath: file.standardizedRelativePath,
            bindings: namespace.rootBindings
        )
        let relativePathUsesAliasFallback = switch WorkspaceAliasResolver.resolve(
            userPath: file.standardizedRelativePath,
            roots: namespace.clientRoots,
            options: RootAliasOptions(requireRemainder: true)
        ) {
        case .prefixed:
            true
        case .ambiguous, .bareRoot, .notAliasPrefixed:
            false
        }
        let relativePathRoundTrips = try? WorkspaceExactFileInput.parse(file.standardizedRelativePath)
            == .relative(file.standardizedRelativePath)
        if candidates.matches.count == 1,
           candidates.matches[0].file?.id == file.id,
           !candidates.blocked,
           !candidates.hasUnavailableBinding,
           !relativePathUsesAliasFallback,
           relativePathRoundTrips == true
        {
            return WorkspaceExactExistingFileMatch(file: file, canonicalPath: file.standardizedRelativePath)
        }
        guard let binding = namespace.binding(lookupRootID: file.rootID) else {
            throw WorkspaceFileContextStoreError.exactFileNamespaceMissingRoot(file.rootID)
        }
        guard let alias = namespace.explicitAlias(clientRootID: binding.preferredClientRoot.id) else {
            throw WorkspaceFileContextStoreError.exactFileNamespaceMissingAlias(binding.preferredClientRoot.id)
        }
        return WorkspaceExactExistingFileMatch(
            file: file,
            canonicalPath: "\(alias)//\(file.standardizedRelativePath)"
        )
    }

    /// Resolves an exact file path that the caller explicitly requested, even when
    /// discovery policy hides it. Ignore rules remain discovery filters: background scans,
    /// replay, tree rendering, search, and fuzzy matching still skip managed-only files.
    func materializeExplicitlyRequestedFile(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws -> WorkspaceExplicitFileMaterializationResult {
        try await materializeExplicitlyRequestedFile(
            userPath,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func materializeExplicitlyRequestedFile(
        _ userPath: String,
        rootRefs roots: [WorkspaceRootRef]
    ) async throws -> WorkspaceExplicitFileMaterializationResult {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noCandidate }
        guard !StandardizedPath.containsNUL(trimmed) else { return .blocked }
        guard (trimmed as NSString).expandingTildeInPath.hasPrefix("/") else { return .noCandidate }

        let candidates: [(rootID: UUID, relativePath: String)]
        switch explicitDiskLookupCandidates(for: trimmed, rootRefs: roots) {
        case let .candidates(resolvedCandidates):
            candidates = resolvedCandidates
        case .ambiguousAlias:
            return .ambiguous
        }
        var materializable: [(rootID: UUID, relativePath: String, managedOnly: Bool)] = []
        var foundBlockedCandidate = false
        for candidate in candidates {
            guard let state = rootStatesByID[candidate.rootID] else { continue }
            switch await state.service.catalogRegularFileEligibility(relativePath: candidate.relativePath) {
            case .eligible:
                materializable.append((candidate.rootID, candidate.relativePath, false))
            case .ineligible(.ignored):
                materializable.append((candidate.rootID, candidate.relativePath, true))
            case .ineligible(.missingOrDirectory):
                _ = await fenceAndPruneCatalogFileMissingOnDisk(
                    rootID: candidate.rootID,
                    relativePath: candidate.relativePath,
                    publishDelta: true
                )
                continue
            case .ineligible:
                foundBlockedCandidate = true
            }
        }
        guard materializable.count <= 1 else { return .ambiguous }
        guard let candidate = materializable.first,
              let state = rootStatesByID[candidate.rootID]
        else { return foundBlockedCandidate ? .blocked : .noCandidate }
        let registeredEligibility = await state.service.registerExplicitlyManagedRegularFile(relativePath: candidate.relativePath)
        let managedOnly: Bool
        switch registeredEligibility {
        case .eligible:
            managedOnly = false
        case .ineligible(.ignored):
            managedOnly = true
        case .ineligible(.missingOrDirectory):
            _ = await fenceAndPruneCatalogFileMissingOnDisk(
                rootID: candidate.rootID,
                relativePath: candidate.relativePath,
                publishDelta: true
            )
            return .noCandidate
        case .ineligible:
            return .blocked
        }
        guard let codemapFence = await beginCodemapRootMutationFence(
            rootID: candidate.rootID,
            command: .catalogAdvanced
        ) else { return .noCandidate }
        do {
            let materialized = try await materializeCatalogRegularFile(
                rootID: candidate.rootID,
                relativePath: candidate.relativePath,
                managedOnly: managedOnly
            )
            await awaitCodemapCleanupFlights(rootIDs: [candidate.rootID])
            finishCodemapRootMutationFence(codemapFence, didCommitMutation: true)
            return .materialized(materialized)
        } catch {
            finishCodemapRootMutationFence(codemapFence, didCommitMutation: false)
            throw error
        }
    }

    @discardableResult
    func materializeCatalogFileAfterDiskWrite(
        rootID: UUID,
        relativePath: String,
        codemapPathLocalMutation: Bool = false
    ) async throws -> WorkspaceFileCatalogMaterializationResult {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let eligibility = await state.service.registerExplicitlyManagedRegularFile(relativePath: standardizedRelativePath)

        func materialize(managedOnly: Bool) async throws -> WorkspaceFileCatalogMaterializationResult {
            let perform = {
                try await self.materializeCatalogRegularFile(
                    rootID: rootID,
                    relativePath: standardizedRelativePath,
                    managedOnly: managedOnly
                )
            }
            let file = if codemapPathLocalMutation {
                try await withCodemapPathLocalCatalogMutation(rootID: rootID, perform)
            } else {
                try await perform()
            }
            return .materialized(file)
        }

        switch eligibility {
        case .ineligible(.ignored):
            // A direct app/MCP write is an explicit request to manage this exact file.
            // Keep it available for follow-up read_file/apply_edits calls without making
            // ignored siblings discoverable through scans or replay.
            return try await materialize(managedOnly: true)
        case let .ineligible(reason):
            guard isExpectedDiskWriteCatalogIneligibility(reason) else {
                throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                    "file was written but is not catalog-eligible after the write: \(reason.description)"
                )
            }
            return .ineligible(reason)
        case .eligible:
            return try await materialize(managedOnly: false)
        }
    }

    func ingressPublishedGitArtifacts(
        _ request: WorkspacePublishedGitArtifactIngressRequest
    ) async -> WorkspacePublishedGitArtifactIngressResult {
        func staleRootResult() -> WorkspacePublishedGitArtifactIngressResult {
            WorkspacePublishedGitArtifactIngressResult(outcomes: request.artifacts.map {
                WorkspacePublishedGitArtifactIngressOutcome(artifact: $0, status: .staleRoot)
            })
        }

        guard let initialState = exactRootState(
            expectedRoot: request.root,
            expectedKind: .workspaceGitData
        ) else {
            return staleRootResult()
        }
        let expectedBatchLifetimeID = initialState.lifetimeID
        guard let codemapFence = await beginCodemapRootMutationFence(
            rootID: request.root.id,
            command: .catalogAdvanced
        ) else { return staleRootResult() }
        var didPublishCatalogMutation = false
        defer {
            finishCodemapRootMutationFence(
                codemapFence,
                didCommitMutation: didPublishCatalogMutation
            )
        }
        guard let fencedState = exactRootState(
            expectedRoot: request.root,
            expectedKind: .workspaceGitData
        ), fencedState.lifetimeID == expectedBatchLifetimeID else {
            return staleRootResult()
        }

        var outcomes: [WorkspacePublishedGitArtifactIngressOutcome] = []
        var seenAbsolutePaths = Set<String>()

        func append(
            _ artifact: GitDiffPublishedArtifact,
            _ status: WorkspacePublishedGitArtifactIngressOutcomeStatus
        ) {
            outcomes.append(WorkspacePublishedGitArtifactIngressOutcome(
                artifact: artifact,
                status: status
            ))
        }

        for artifact in request.artifacts {
            let relativePath = artifact.gitDataRelativePath
            guard GitDiffArtifactPathPolicy.isSafeRelativeArtifactPath(relativePath) else {
                append(artifact, .invalidRelativePath)
                continue
            }

            let absolutePath = artifact.absolutePath
            guard absolutePath.hasPrefix("/"),
                  !StandardizedPath.containsNUL(absolutePath),
                  StandardizedPath.isDescendant(absolutePath, of: request.root.standardizedFullPath),
                  absolutePath != request.root.standardizedFullPath
            else {
                append(artifact, .outsideExpectedRoot)
                continue
            }

            let reconstructedPath = StandardizedPath.join(
                standardizedRoot: request.root.standardizedFullPath,
                standardizedRelativePath: relativePath
            )
            guard reconstructedPath == absolutePath else {
                append(artifact, .outsideExpectedRoot)
                continue
            }

            guard seenAbsolutePaths.insert(absolutePath).inserted else {
                append(artifact, .duplicateOf(path: absolutePath))
                continue
            }

            guard let state = exactRootState(
                expectedRoot: request.root,
                expectedKind: .workspaceGitData
            ), state.lifetimeID == expectedBatchLifetimeID else {
                return staleRootResult()
            }
            let eligibility = await state.service.registerExplicitlyManagedRegularFile(
                relativePath: relativePath
            )
            #if DEBUG
                if let publishedGitArtifactIngressDidRegisterHandler {
                    await publishedGitArtifactIngressDidRegisterHandler(request.root.id, relativePath)
                }
            #endif

            guard let revalidatedState = exactRootState(
                expectedRoot: request.root,
                expectedKind: .workspaceGitData
            ), revalidatedState.lifetimeID == expectedBatchLifetimeID else {
                return staleRootResult()
            }

            let managedOnly: Bool
            switch eligibility {
            case .eligible:
                managedOnly = false
            case .ineligible(.ignored):
                managedOnly = true
            case .ineligible(.missingOrDirectory):
                await pruneCatalogFileMissingOnDisk(
                    rootID: request.root.id,
                    relativePath: relativePath,
                    publishDelta: true
                )
                append(artifact, .missingOnDisk)
                continue
            case let .ineligible(reason):
                append(artifact, .ineligible(reason: reason))
                continue
            }

            do {
                let record = try await materializeCatalogRegularFile(
                    rootID: request.root.id,
                    relativePath: relativePath,
                    managedOnly: managedOnly
                )
                didPublishCatalogMutation = true
                append(artifact, .cataloged(record: record))
            } catch {
                if !regularFileAppearsPresentOnDisk(
                    root: revalidatedState.root,
                    relativePath: relativePath
                ) {
                    append(artifact, .missingOnDisk)
                } else {
                    append(artifact, .materializationFailed(reason: error.localizedDescription))
                }
            }
        }

        guard let finalState = exactRootState(
            expectedRoot: request.root,
            expectedKind: .workspaceGitData
        ), finalState.lifetimeID == expectedBatchLifetimeID else {
            return staleRootResult()
        }
        await awaitCodemapCleanupFlights(rootIDs: [request.root.id])
        return WorkspacePublishedGitArtifactIngressResult(outcomes: outcomes)
    }

    private func explicitDiskLookupCandidates(
        for userPath: String,
        rootRefs roots: [WorkspaceRootRef]
    ) -> ExplicitDiskLookupCandidatesResult {
        let expanded = (userPath as NSString).expandingTildeInPath
        let standardized = StandardizedPath.absolute(expanded)
        var candidates: [(rootID: UUID, relativePath: String)] = []
        var seen = Set<String>()

        func append(root: WorkspaceRootRef, relativePath rawRelativePath: String) {
            let relativePath = StandardizedPath.relative(rawRelativePath)
            guard !relativePath.isEmpty,
                  relativePath != "..",
                  !relativePath.hasPrefix("../")
            else { return }
            let absolutePath = StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: relativePath
            )
            guard StandardizedPath.isDescendant(absolutePath, of: root.standardizedFullPath) else { return }
            let key = "\(root.id.uuidString)|\(relativePath)"
            guard seen.insert(key).inserted else { return }
            candidates.append((root.id, relativePath))
        }

        func appendAbsolute(_ absolutePath: String) {
            guard let root = roots
                .filter({ StandardizedPath.isDescendant(absolutePath, of: $0.standardizedFullPath) })
                .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
            else { return }
            let relativePath = String(absolutePath.dropFirst(root.standardizedFullPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            append(root: root, relativePath: relativePath)
        }

        if standardized.hasPrefix("/") {
            appendAbsolute(standardized)
            return .candidates(candidates)
        }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: roots,
            options: RootAliasOptions(requireRemainder: true)
        ) {
        case let .prefixed(root, _, remainder):
            append(root: root, relativePath: remainder)
            return .candidates(candidates)
        case .ambiguous:
            return .ambiguousAlias
        case .bareRoot, .notAliasPrefixed:
            break
        }

        for root in roots {
            append(root: root, relativePath: standardized)
        }
        return .candidates(candidates)
    }

    private func materializeCatalogRegularFile(
        rootID: UUID,
        relativePath: String,
        managedOnly: Bool
    ) async throws -> WorkspaceFileRecord {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        if let existing = await file(rootID: rootID, relativePath: standardizedRelativePath) {
            let wasManagedOnly = managedOnlyFileIDs.contains(existing.id)
            if !managedOnly {
                await promoteToDiscoverable(existing)
                if wasManagedOnly {
                    invalidatePathMatchSnapshot(
                        affectedRootKinds: [state.root.kind],
                        reason: .managedFilePromotion,
                        affectedRootIDs: [state.root.id]
                    )
                    await publishAppliedIndexEvent(
                        root: state.root,
                        upsertedFiles: [existing],
                        upsertedFolders: ancestorFolders(for: standardizedRelativePath, rootID: rootID)
                    )
                }
            }
            return existing
        }

        guard regularFileAppearsPresentOnDisk(root: state.root, relativePath: standardizedRelativePath) else {
            throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                "eligible file disappeared before it could be added to the workspace catalog: \(standardizedRelativePath)"
            )
        }
        await indexFile(relativePath: standardizedRelativePath, root: state.root, managedOnly: managedOnly)
        guard let file = await file(rootID: rootID, relativePath: standardizedRelativePath) else {
            throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                "eligible file exists on disk but the workspace catalog did not return a record: \(standardizedRelativePath)"
            )
        }
        if !managedOnly {
            await publishAppliedIndexEvent(
                root: state.root,
                upsertedFiles: [file],
                upsertedFolders: ancestorFolders(for: standardizedRelativePath, rootID: rootID)
            )
        }
        return file
    }

    private func isExpectedDiskWriteCatalogIneligibility(_ reason: CatalogRegularFileIneligibilityReason) -> Bool {
        switch reason {
        case .ignored, .symbolicLink, .nonRegularFile, .symlinkComponent, .outsideCanonicalRoot, .outsideRoot:
            true
        case .invalidRelativePath, .missingOrDirectory:
            false
        }
    }

    private func regularFileAppearsPresentOnDisk(root: WorkspaceRootRecord, relativePath: String) -> Bool {
        let fullPath = StandardizedPath.join(standardizedRoot: root.standardizedFullPath, standardizedRelativePath: StandardizedPath.relative(relativePath))
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        if let values = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            if values.isSymbolicLink == true { return false }
            if values.isRegularFile == false { return false }
        }
        return true
    }

    private func directoryAppearsPresentOnDisk(root: WorkspaceRootRecord, relativePath: String) -> Bool {
        let fullPath = StandardizedPath.join(standardizedRoot: root.standardizedFullPath, standardizedRelativePath: StandardizedPath.relative(relativePath))
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if let values = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            if values.isSymbolicLink == true { return false }
            if values.isDirectory == false { return false }
        }
        return true
    }

    @discardableResult
    private func fenceAndPruneCatalogFileMissingOnDisk(
        rootID: UUID,
        relativePath: String,
        publishDelta: Bool
    ) async -> Bool {
        let path = StandardizedPath.relative(relativePath)
        let token = await fenceCodemapPaths(
            rootID: rootID,
            commands: [.deleted([path])]
        )
        let didPrune = await withCodemapPathLocalCatalogMutation(rootID: rootID) {
            await pruneCatalogFileMissingOnDisk(
                rootID: rootID,
                relativePath: path,
                publishDelta: publishDelta
            )
        }
        releaseCodemapPathFence(token, didCommitMutation: didPrune)
        return didPrune
    }

    @discardableResult
    private func pruneCatalogFileMissingOnDisk(
        rootID: UUID,
        relativePath: String,
        publishDelta: Bool
    ) async -> Bool {
        guard let state = rootStatesByID[rootID],
              let oldFile = await file(rootID: rootID, relativePath: relativePath)
        else { return false }
        let oldFileWasDiscoverable = isDiscoverableFileID(oldFile.id)
        await removeFile(relativePath: oldFile.standardizedRelativePath, rootID: rootID)
        if publishDelta, oldFileWasDiscoverable {
            await publishAppliedIndexEvent(root: state.root, removedFileIDs: [oldFile.id], removedFilePaths: [oldFile.standardizedRelativePath])
        }
        return true
    }

    @discardableResult
    private func pruneCatalogItemMissingOnDisk(
        rootID: UUID,
        relativePath: String,
        publishDelta: Bool
    ) async -> Bool {
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        if await pruneCatalogFileMissingOnDisk(rootID: rootID, relativePath: standardizedRelativePath, publishDelta: publishDelta) {
            return true
        }
        guard let state = rootStatesByID[rootID],
              let oldFolder = await folder(rootID: rootID, relativePath: standardizedRelativePath)
        else { return false }
        let oldFolderWasDiscoverable = isDiscoverableFolderID(oldFolder.id)
        let removal = await removeFolderTree(relativePath: standardizedRelativePath, rootID: rootID)
        if publishDelta {
            await publishAppliedIndexEvent(
                root: state.root,
                removedFileIDs: removal.fileIDs,
                removedFolderIDs: removal.folderIDs.isEmpty && oldFolderWasDiscoverable ? [oldFolder.id] : removal.folderIDs,
                removedFilePaths: removal.filePaths,
                removedFolderPaths: removal.folderPaths.isEmpty && oldFolderWasDiscoverable ? [oldFolder.standardizedRelativePath] : removal.folderPaths
            )
        }
        return true
    }

    #if DEBUG
        private func applyPreparedIndexDeltas(
            rootID: UUID,
            deltas: [PreparedFileSystemDelta],
            expectedLifetimeID: UUID? = nil,
            watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
            servicePublicationSequence: UInt64?,
            publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
            diagnosticRootToken: UUID? = nil,
            requiresFullResync: Bool = false
        ) async {
            guard let servicePublicationSequence else {
                await applyPreparedIndexDeltasBody(
                    rootID: rootID,
                    deltas: deltas,
                    expectedLifetimeID: expectedLifetimeID,
                    publicationCorrelation: publicationCorrelation,
                    diagnosticRootToken: diagnosticRootToken,
                    requiresFullResync: requiresFullResync
                )
                return
            }
            let recorder = await applyPreparedIndexDeltasRecordingInvalidations(
                rootID: rootID,
                deltas: deltas,
                expectedLifetimeID: expectedLifetimeID,
                servicePublicationSequence: servicePublicationSequence,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken,
                requiresFullResync: requiresFullResync
            )
            guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
            recordPublicationInvalidationDiagnostics(
                rootID: rootID,
                servicePublicationSequence: servicePublicationSequence,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                recorder: recorder
            )
        }

        private func applyPreparedIndexDeltasRecordingInvalidations(
            rootID: UUID,
            deltas: [PreparedFileSystemDelta],
            expectedLifetimeID: UUID? = nil,
            servicePublicationSequence: UInt64? = nil,
            publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
            diagnosticRootToken: UUID? = nil,
            requiresFullResync: Bool = false
        ) async -> PublicationInvalidationRecorder {
            let recorder = PublicationInvalidationRecorder(preparedDeltaCount: deltas.count)
            await Self.$activePublicationInvalidationRecorder.withValue(recorder) {
                await applyPreparedIndexDeltasBody(
                    rootID: rootID,
                    deltas: deltas,
                    expectedLifetimeID: expectedLifetimeID,
                    servicePublicationSequence: servicePublicationSequence,
                    publicationCorrelation: publicationCorrelation,
                    diagnosticRootToken: diagnosticRootToken,
                    requiresFullResync: requiresFullResync
                )
            }
            return recorder
        }
    #else
        private func applyPreparedIndexDeltas(
            rootID: UUID,
            deltas: [PreparedFileSystemDelta],
            expectedLifetimeID: UUID? = nil,
            servicePublicationSequence: UInt64? = nil,
            publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
            diagnosticRootToken: UUID? = nil,
            requiresFullResync: Bool = false
        ) async {
            await applyPreparedIndexDeltasBody(
                rootID: rootID,
                deltas: deltas,
                expectedLifetimeID: expectedLifetimeID,
                servicePublicationSequence: servicePublicationSequence,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken,
                requiresFullResync: requiresFullResync
            )
        }
    #endif

    /// P4-6b table-deletion conversion: the P4-6a delta table left this site unrewired --
    /// "a prefix scan producing paths, not a point lookup producing an ID", which
    /// `inventoryPathLookups`'s per-path fact contract cannot express. The cutover's paged
    /// Tier-1 read (`fetchFileTreePageIndex`) closes this without a new contract primitive: it
    /// already materializes every file's `standardizedRelativePath` for the root, so the prefix
    /// filter runs the same way it always did, just against the paged records instead of the
    /// deleted `RootState.fileIDsByRelativePath` map's keys. Runs before `removeFolderTree`
    /// actually removes anything, so the folder and its descendants are still present to page.
    private func codemapWatcherInvalidationCommands(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        requiresFullResync: Bool
    ) async -> (rootCommand: CodemapInvalidationCommand?, pathCommands: [CodemapInvalidationCommand]) {
        if requiresFullResync {
            return (.watcherGap, [])
        }
        var commands: [CodemapInvalidationCommand] = []
        var pageIndex: FileTreePageIndex?
        for prepared in deltas {
            switch prepared.delta {
            case .fileAdded:
                commands.append(.modified([prepared.relativePath]))
            case .fileModified:
                commands.append(.modified([prepared.relativePath]))
            case .fileRemoved:
                commands.append(.deleted([prepared.relativePath]))
            case .folderRemoved:
                let folderPath = StandardizedPath.relative(prepared.relativePath)
                if pageIndex == nil {
                    pageIndex = await fetchFileTreePageIndex(rootID: rootID)
                }
                let pagedFiles: [WorkspaceFileRecord] = pageIndex.map { Array($0.filesByID.values) } ?? []
                let descendantPaths = Set(
                    pagedFiles.map(\.standardizedRelativePath).filter {
                        $0 == folderPath || $0.hasPrefix(folderPath + "/")
                    }
                )
                if !descendantPaths.isEmpty {
                    commands.append(.deleted(descendantPaths))
                }
            case .folderAdded, .folderModified:
                break
            }
        }
        return (nil, commands)
    }

    private func applyPreparedIndexDeltasBody(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        expectedLifetimeID: UUID? = nil,
        servicePublicationSequence: UInt64? = nil,
        publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        diagnosticRootToken: UUID? = nil,
        requiresFullResync: Bool = false
    ) async {
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
        var didCommitRepositoryMutation = false
        let repositoryMutationFence = await beginCodemapRepositoryAuthorityMutationIfNeeded(
            rootID: rootID,
            deltas: deltas,
            requiresFullResync: requiresFullResync
        )
        defer {
            finishCodemapRootMutationFence(
                repositoryMutationFence,
                didCommitMutation: didCommitRepositoryMutation
            )
        }
        let applicableDeltas = await preflightPreparedIndexDeltas(
            rootID: rootID,
            deltas: deltas,
            expectedLifetimeID: expectedLifetimeID
        )
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
        let invalidation = await codemapWatcherInvalidationCommands(
            rootID: rootID,
            deltas: applicableDeltas,
            requiresFullResync: requiresFullResync
        )
        if let rootCommand = invalidation.rootCommand {
            if repositoryMutationFence == nil {
                await fenceCodemapRootAuthority(rootIDs: [rootID], command: rootCommand)
            }
            guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
            await applyPreparedIndexDeltaMutations(
                rootID: rootID,
                deltas: applicableDeltas,
                requiresFullResync: requiresFullResync
            )
            didCommitRepositoryMutation = repositoryMutationFence != nil
            // Publisher application has already revoked the old root codemap authority. Keep the
            // derived cleanup flight retained/fenced, but do not hold the basic catalog publication
            // open on its completion. Direct codemap-sensitive callers retain the synchronous fence.
            if servicePublicationSequence == nil {
                await awaitCodemapCleanupFlights(rootIDs: [rootID])
            }
            if repositoryMutationFence == nil, let current = rootStatesByID[rootID] {
                scheduleCodemapGraphIndexBuildAfterRootReady(rootEpoch: WorkspaceCodemapRootEpoch(
                    rootID: rootID,
                    rootLifetimeID: current.lifetimeID
                ))
            }
            return
        }

        if repositoryMutationFence != nil {
            guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
            await applyPreparedIndexDeltaMutations(
                rootID: rootID,
                deltas: applicableDeltas,
                requiresFullResync: requiresFullResync
            )
            didCommitRepositoryMutation = true
            return
        }

        let token: CodemapPathFenceToken? = if let servicePublicationSequence {
            beginCodemapPathInvalidation(
                rootID: rootID,
                commands: invalidation.pathCommands,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken,
                servicePublicationSequence: servicePublicationSequence
            ).token
        } else {
            await fenceCodemapPaths(
                rootID: rootID,
                commands: invalidation.pathCommands
            )
        }
        var didCommitPathMutation = false
        defer {
            releaseCodemapPathFence(token, didCommitMutation: didCommitPathMutation)
        }
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
        await withCodemapPathLocalCatalogMutation(rootID: rootID) {
            await applyPreparedIndexDeltaMutations(
                rootID: rootID,
                deltas: applicableDeltas,
                requiresFullResync: requiresFullResync
            )
        }
        #if DEBUG
            if let recorder = Self.activePublicationInvalidationRecorder,
               recorder.topologyInvalidationCount == 0
            {
                recorder.codemapInvalidationRequestCount += token?.standardizedRelativePaths.count ?? 0
            }
        #endif
        didCommitPathMutation = true
    }

    private func beginCodemapRepositoryAuthorityMutationIfNeeded(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        requiresFullResync: Bool
    ) async -> CodemapRootMutationFenceToken? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: state.lifetimeID)
        if requiresFullResync {
            terminalNonGitCodemapCacheByEpoch.removeValue(forKey: rootEpoch)
        }
        let repositoryLayoutMayHaveChanged = deltas.contains { prepared in
            let path = prepared.relativePath
            return path == ".git" || path.hasPrefix(".git/") || path == "HEAD" ||
                path == "objects" || path.hasPrefix("objects/") || path == "refs" || path.hasPrefix("refs/")
        }
        guard repositoryLayoutMayHaveChanged else { return nil }

        terminalNonGitCodemapCacheByEpoch.removeValue(forKey: rootEpoch)
        recordCodemapGraphIndexBuildStoreEvent(
            .repositoryAuthorityDetached,
            rootEpoch: rootEpoch,
            phase: .superseded
        )
        return await beginCodemapRootMutationFence(
            rootID: rootID,
            command: .repositoryAuthority
        )
    }

    private func preflightPreparedIndexDeltas(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        expectedLifetimeID: UUID? = nil
    ) async -> [PreparedFileSystemDelta] {
        var applicableDeltas: [PreparedFileSystemDelta] = []
        applicableDeltas.reserveCapacity(deltas.count)
        for prepared in deltas {
            switch prepared.delta {
            case .fileAdded:
                guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID),
                      let service = rootStatesByID[rootID]?.service,
                      await service.catalogEligibleRegularFileExists(relativePath: prepared.relativePath),
                      isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID)
                else { continue }
                applicableDeltas.append(prepared)
            case .folderAdded:
                guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID),
                      let service = rootStatesByID[rootID]?.service,
                      await service.catalogFolderIsDiscoverable(relativePath: prepared.relativePath),
                      isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID)
                else { continue }
                applicableDeltas.append(prepared)
            case .fileRemoved, .folderRemoved, .fileModified, .folderModified:
                applicableDeltas.append(prepared)
            }
        }
        return applicableDeltas
    }

    /// P4-6b: walks every path component above `relativePath` and returns the (Rust-authoritative)
    /// folder record for each ancestor that resolves, root-to-leaf order not guaranteed. Republishing
    /// an already-current ancestor as part of an applied-index upsert batch is harmless and matches
    /// this function's own "repeated add deltas are harmless" upsert philosophy -- so this replaces
    /// the pre-cutover `discoverableParentFolders`/`newlyIndexedParentFolders` distinction (both of
    /// which read the now-deleted local `folderIDsByRelativePath` table) with a single unconditional
    /// ancestor walk over the async, Rust-routed `folder(rootID:relativePath:)` accessor.
    private func ancestorFolders(for relativePath: String, rootID: UUID) async -> [WorkspaceFolderRecord] {
        var results: [WorkspaceFolderRecord] = []
        var current = (relativePath as NSString).deletingLastPathComponent
        while !current.isEmpty, current != "." {
            if let folder = await folder(rootID: rootID, relativePath: current) {
                results.append(folder)
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return results
    }

    private func applyPreparedIndexDeltaMutations(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        requiresFullResync: Bool = false
    ) async {
        guard let root = rootStatesByID[rootID]?.root else { return }
        precondition(activePublicationInvalidationBatch == nil)
        let invalidationBatch = PublicationInvalidationBatch()
        activePublicationInvalidationBatch = invalidationBatch
        defer { activePublicationInvalidationBatch = nil }

        var upsertedFiles: [WorkspaceFileRecord] = []
        var upsertedFolders: [WorkspaceFolderRecord] = []
        var removedFileIDs: [UUID] = []
        var removedFolderIDs: [UUID] = []
        var removedFilePaths: [String] = []
        var removedFolderPaths: [String] = []
        var modifiedFileIDs: [UUID] = []
        var modifiedFolderIDs: [UUID] = []
        for prepared in deltas {
            let relativePath = prepared.relativePath
            switch prepared.delta {
            case .fileAdded:
                guard regularFileAppearsPresentOnDisk(root: root, relativePath: relativePath) else { continue }
                let existingFile = await file(rootID: rootID, relativePath: relativePath)
                if let existingFile {
                    invalidateSearchContent(existingFile)
                }
                await indexFile(relativePath: relativePath, root: root)
                if let file = await file(rootID: rootID, relativePath: relativePath) {
                    // Publish existing records too: file-system deltas may have already
                    // indexed the catalog while UI replay still has optimistic UUIDs.
                    // Treating add as an upsert lets subscribers reconcile to store IDs.
                    upsertedFiles.append(file)
                    await upsertedFolders.append(contentsOf: ancestorFolders(for: relativePath, rootID: rootID))
                }
            case .folderAdded:
                guard directoryAppearsPresentOnDisk(root: root, relativePath: relativePath) else { continue }
                await indexFolder(relativePath: relativePath, root: root)
                if let folder = await folder(rootID: rootID, relativePath: relativePath) {
                    // Same upsert semantics as files: repeated folder add deltas are
                    // harmless and allow UI identity reconciliation.
                    upsertedFolders.append(folder)
                }
            case .fileRemoved:
                if let oldFile = await file(rootID: rootID, relativePath: relativePath) {
                    let oldFileWasDiscoverable = isDiscoverableFileID(oldFile.id)
                    await removeFile(relativePath: relativePath, rootID: rootID)
                    if oldFileWasDiscoverable {
                        removedFileIDs.append(oldFile.id)
                        removedFilePaths.append(oldFile.standardizedRelativePath)
                    }
                }
            case .folderRemoved:
                if let oldFolder = await folder(rootID: rootID, relativePath: relativePath) {
                    let oldFolderWasDiscoverable = isDiscoverableFolderID(oldFolder.id)
                    let removal = await removeFolderTree(relativePath: relativePath, rootID: rootID)
                    removedFileIDs.append(contentsOf: removal.fileIDs)
                    removedFolderIDs.append(contentsOf: removal.folderIDs.isEmpty && oldFolderWasDiscoverable ? [oldFolder.id] : removal.folderIDs)
                    removedFilePaths.append(contentsOf: removal.filePaths)
                    removedFolderPaths.append(contentsOf: removal.folderPaths.isEmpty && oldFolderWasDiscoverable ? [oldFolder.standardizedRelativePath] : removal.folderPaths)
                }
            case .fileModified:
                if let file = await file(rootID: rootID, relativePath: relativePath) {
                    invalidateSearchContent(file)
                    if isDiscoverableFileID(file.id) { modifiedFileIDs.append(file.id) }
                }
            case .folderModified:
                if let folder = await folder(rootID: rootID, relativePath: relativePath), isDiscoverableFolderID(folder.id) {
                    modifiedFolderIDs.append(folder.id)
                }
            }
        }

        finalizePublicationInvalidations(invalidationBatch)
        await publishAppliedIndexEvent(
            root: root,
            upsertedFiles: upsertedFiles,
            upsertedFolders: upsertedFolders,
            removedFileIDs: removedFileIDs,
            removedFolderIDs: removedFolderIDs,
            removedFilePaths: removedFilePaths,
            removedFolderPaths: removedFolderPaths,
            modifiedFileIDs: modifiedFileIDs,
            modifiedFolderIDs: modifiedFolderIDs,
            requiresFullResync: requiresFullResync
        )
    }

    func lookupPath(
        _ userPath: String,
        profile: PathLocateProfile = .uiAssisted,
        rootScope: WorkspaceLookupRootScope = .allLoaded
    ) async -> WorkspacePathLookupResult? {
        let request = WorkspacePathLookupRequest(userPath: userPath, profile: profile, rootScope: rootScope)
        return await lookupPath(request)
    }

    func lookupPath(_ request: WorkspacePathLookupRequest) async -> WorkspacePathLookupResult? {
        let normalizedPath = normalizeUserInputPath(request.userPath)
        guard !normalizedPath.isEmpty else { return nil }

        let selectedFileFullPaths = request.selectedFileFullPaths
        let staticData = await buildStaticSnapshot(scope: request.rootScope)
        guard let match = await pathMatchWorker.locate(
            userPath: normalizedPath,
            profile: request.profile,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths)
        ) else { return nil }
        return await lookupResult(input: request.userPath, match: match)
    }

    func lookupPath(
        _ request: WorkspacePathLookupRequest,
        rootRefs: [WorkspaceRootRef]
    ) async -> WorkspacePathLookupResult? {
        let normalizedPath = normalizeUserInputPath(request.userPath)
        guard !normalizedPath.isEmpty else { return nil }

        let selectedFileFullPaths = request.selectedFileFullPaths
        let staticData = await buildStaticSnapshot(scope: request.rootScope, rootRefs: rootRefs)
        guard let match = await pathMatchWorker.locate(
            userPath: normalizedPath,
            profile: request.profile,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths)
        ) else { return nil }
        return await lookupResult(input: request.userPath, match: match)
    }

    func lookupPaths(_ requests: [WorkspacePathLookupRequest]) async -> [String: WorkspacePathLookupResult] {
        struct LookupBatchKey: Hashable {
            let rootScope: WorkspaceLookupRootScope
            let profile: PathLocateProfile
            let selectedFileFullPaths: Set<String>
        }

        var grouped: [LookupBatchKey: [(original: String, normalized: String)]] = [:]
        for request in requests {
            let normalizedPath = normalizeUserInputPath(request.userPath)
            guard !normalizedPath.isEmpty else { continue }
            let key = LookupBatchKey(
                rootScope: request.rootScope,
                profile: request.profile,
                selectedFileFullPaths: request.selectedFileFullPaths
            )
            grouped[key, default: []].append((request.userPath, normalizedPath))
        }

        var results: [String: WorkspacePathLookupResult] = [:]
        for (key, paths) in grouped {
            let staticData = await buildStaticSnapshot(scope: key.rootScope)
            let matches = await pathMatchWorker.locateMany(
                userPaths: paths.map(\.normalized),
                profile: key.profile,
                staticData: staticData,
                selectedFileFullPaths: key.selectedFileFullPaths,
                selectionSig: selectionSignature(for: key.selectedFileFullPaths)
            )
            for path in paths {
                guard let match = matches[path.normalized],
                      let result = await lookupResult(input: path.original, match: match)
                else { continue }
                results[path.original] = result
            }
        }
        return results
    }

    func findCreationPath(
        userPath: String,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        selectedFileFullPaths: Set<String> = []
    ) async -> FileCreationResult? {
        let normalizedPath = normalizeUserInputPath(userPath)
        guard !normalizedPath.isEmpty else { return nil }
        let staticData = await buildStaticSnapshot(scope: rootScope)
        return await pathMatchWorker.findCreationPath(
            userPath: normalizedPath,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths)
        )
    }

    func resolveCreationPath(
        userPath: String,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        selectedFileFullPaths: Set<String> = [],
        mode: CreationResolutionMode
    ) async -> FileCreationResolution? {
        let normalizedPath = normalizeUserInputPath(userPath)
        guard !normalizedPath.isEmpty else { return nil }
        let staticData = await buildStaticSnapshot(scope: rootScope)
        return await pathMatchWorker.resolveCreationPath(
            userPath: normalizedPath,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths),
            mode: mode
        )
    }

    // P4-6b table-deletion conversion: the table-keyed pre-lookup (`state.fileIDsByRelativePath`/
    // `state.folderIDsByRelativePath` then `filesByID`/`foldersByID`) is redundant once
    // `lookupResult(input:root:correctedPath:)` itself re-standardizes `correctedPath` and
    // resolves it authoritatively via the async `file`/`folder` accessors -- passing
    // `relativePath` straight through gives the identical result the two-step form did
    // (any record previously found via a standardized-path key always carries that same
    // standardized path as its own field), one fewer round trip.
    func lookupPath(rootID: UUID, relativePath: String) async -> WorkspacePathLookupResult? {
        guard let state = rootStatesByID[rootID] else { return nil }
        return await lookupResult(input: relativePath, root: state.root, correctedPath: relativePath)
    }

    func lookupDiscoverablePath(rootID: UUID, relativePath: String) async -> WorkspacePathLookupResult? {
        guard publishedSeededAuthorityIsQueryable(rootID: rootID),
              let result = await lookupPath(rootID: rootID, relativePath: relativePath),
              isDiscoverableLookupResult(result)
        else { return nil }
        return result
    }

    func lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspacePathLookupResult? {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !StandardizedPath.containsNUL(trimmed) else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let standardizedPath = StandardizedPath.absolute(expanded)
        guard let root = rootsForPathLookup(scope: rootScope)
            .filter({ StandardizedPath.isDescendant(standardizedPath, of: $0.standardizedFullPath) })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        else { return nil }
        let relativePath = relativePath(for: standardizedPath, rootPath: root.standardizedFullPath)
        guard let result = await lookupPath(rootID: root.id, relativePath: relativePath),
              isDiscoverableLookupResult(result)
        else { return nil }
        return result
    }

    func rootRefs(scope: WorkspaceLookupRootScope = .allLoaded) -> [WorkspaceRootRef] {
        rootsForPathLookup(scope: scope).map {
            WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.standardizedFullPath)
        }
    }

    func codemapRootEpochs(scope: WorkspaceLookupRootScope = .allLoaded) -> [UUID: WorkspaceCodemapRootEpoch] {
        Dictionary(uniqueKeysWithValues: rootsForPathLookup(scope: scope).compactMap { root in
            guard let state = rootStatesByID[root.id] else { return nil }
            return (
                root.id,
                WorkspaceCodemapRootEpoch(rootID: root.id, rootLifetimeID: state.lifetimeID)
            )
        })
    }

    /// Returns one already-loaded root by exact path and kind without consulting a lookup scope.
    /// This is intentionally not a discovery API: it never loads, enumerates, or aliases roots.
    func exactRootRef(path: String, kind: WorkspaceRootKind) -> WorkspaceRootRef? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !StandardizedPath.containsNUL(trimmed),
              trimmed.hasPrefix("/")
        else { return nil }

        let standardizedPath = StandardizedPath.absolute(trimmed)
        guard let rootID = rootIDsByStandardizedPath[standardizedPath],
              let state = rootStatesByID[rootID],
              publishedSeededAuthorityIsQueryable(rootID: rootID),
              state.root.kind == kind,
              state.root.standardizedFullPath == standardizedPath
        else { return nil }

        return WorkspaceRootRef(
            id: state.root.id,
            name: state.root.name,
            fullPath: state.root.standardizedFullPath
        )
    }

    /// Resolves one Context Builder selection candidate against an exact Agent-owned
    /// session root. This route never consults another root, aliases, general lookup, or
    /// raw filesystem fallback.
    func resolveContextBuilderSelectionCandidate(
        path rawPath: String,
        authorization: WorkspaceSessionRootAuthorization,
        folderPolicy: SelectedGitDiffFolderPolicy
    ) async throws -> WorkspaceAuthorizedSelectionCandidateResolution {
        try Task.checkCancellation()
        if let mismatch = sessionRootAuthorizationMismatch(authorization) {
            return .staleAuthority(mismatch)
        }

        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !StandardizedPath.containsNUL(trimmed)
        else {
            return .blockedOrAmbiguous(.invalidPath)
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .blockedOrAmbiguous(.invalidPath)
        }
        let standardizedPath = StandardizedPath.absolute(expanded)
        let selectsAuthorizedRoot = standardizedPath == authorization.root.standardizedFullPath
        guard selectsAuthorizedRoot
            || StandardizedPath.isDescendant(
                standardizedPath,
                of: authorization.root.standardizedFullPath
            )
        else {
            return .blockedOrAmbiguous(.outsideAuthorizedRoot)
        }

        if selectsAuthorizedRoot {
            let expandsFolders = switch folderPolicy {
            case .filesOnly: false
            case .expandFolders: true
            }
            guard expandsFolders,
                  let folder = rootFolderRecord(rootID: authorization.root.id)
            else {
                return .noCandidate
            }
            if let mismatch = sessionRootAuthorizationMismatch(authorization) {
                return .staleAuthority(mismatch)
            }
            return await .resolved(files: descendantFiles(in: folder.id), route: .catalogFolder)
        }

        let relativePath = relativePath(
            for: standardizedPath,
            rootPath: authorization.root.standardizedFullPath
        )
        guard !relativePath.isEmpty,
              relativePath != "..",
              !relativePath.hasPrefix("../")
        else {
            return .blockedOrAmbiguous(.outsideAuthorizedRoot)
        }
        guard let state = rootStatesByID[authorization.root.id] else {
            return .staleAuthority(.rootID)
        }

        let eligibility = await state.service.catalogRegularFileEligibility(
            relativePath: relativePath
        )
        #if DEBUG
            if let contextBuilderSelectionCandidateEligibilityDidResolveHandler {
                await contextBuilderSelectionCandidateEligibilityDidResolveHandler(authorization.root.id)
            }
        #endif
        try Task.checkCancellation()
        if let mismatch = sessionRootAuthorizationMismatch(authorization) {
            return .staleAuthority(mismatch)
        }

        switch eligibility {
        case .eligible, .ineligible(.ignored):
            if let record = await file(rootID: authorization.root.id, relativePath: relativePath),
               record.rootID == authorization.root.id,
               record.standardizedFullPath == standardizedPath
            {
                return .resolved(files: [record], route: .catalogFile)
            }

            let registered = await state.service.registerExplicitlyManagedRegularFile(
                relativePath: relativePath
            )
            try Task.checkCancellation()
            if let mismatch = sessionRootAuthorizationMismatch(authorization) {
                return .staleAuthority(mismatch)
            }
            let managedOnly: Bool
            switch registered {
            case .eligible:
                managedOnly = false
            case .ineligible(.ignored):
                managedOnly = true
            case .ineligible(.missingOrDirectory):
                return .noCandidate
            case let .ineligible(reason):
                return .blockedOrAmbiguous(
                    contextBuilderSelectionCandidateBlock(for: reason)
                )
            }
            do {
                let record = try await materializeCatalogRegularFile(
                    rootID: authorization.root.id,
                    relativePath: relativePath,
                    managedOnly: managedOnly
                )
                if let mismatch = sessionRootAuthorizationMismatch(authorization) {
                    return .staleAuthority(mismatch)
                }
                return .resolved(files: [record], route: .materializedFile)
            } catch {
                return .blockedOrAmbiguous(.materializationFailed)
            }

        case .ineligible(.missingOrDirectory):
            let expandsFolders = switch folderPolicy {
            case .filesOnly: false
            case .expandFolders: true
            }
            guard expandsFolders,
                  let folder = await folder(rootID: authorization.root.id, relativePath: relativePath),
                  isDiscoverableFolderID(folder.id)
            else {
                return .noCandidate
            }
            if let mismatch = sessionRootAuthorizationMismatch(authorization) {
                return .staleAuthority(mismatch)
            }
            return await .resolved(files: descendantFiles(in: folder.id), route: .catalogFolder)

        case let .ineligible(reason):
            return .blockedOrAmbiguous(
                contextBuilderSelectionCandidateBlock(for: reason)
            )
        }
    }

    private func contextBuilderSelectionCandidateBlock(
        for reason: CatalogRegularFileIneligibilityReason
    ) -> WorkspaceAuthorizedSelectionCandidateBlock {
        switch reason {
        case .invalidRelativePath:
            .invalidPath
        case .outsideRoot:
            .outsideAuthorizedRoot
        case .symbolicLink:
            .symbolicLink
        case .symlinkComponent:
            .symlinkComponent
        case .outsideCanonicalRoot:
            .outsideCanonicalRoot
        case .nonRegularFile:
            .nonRegularFile
        case .missingOrDirectory, .ignored:
            .materializationFailed
        }
    }

    /// Returns one exact catalog record under a previously frozen root identity.
    /// Missing records remain missing; this never materializes an ignored or on-disk file.
    func exactCatalogFile(
        absolutePath: String,
        expectedRoot: WorkspaceRootRef,
        expectedKind: WorkspaceRootKind
    ) async -> WorkspaceFileRecord? {
        guard let state = exactRootState(expectedRoot: expectedRoot, expectedKind: expectedKind) else {
            return nil
        }
        guard publishedSeededAuthorityIsQueryable(rootID: state.root.id) else { return nil }

        let trimmed = absolutePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !StandardizedPath.containsNUL(trimmed),
              trimmed.hasPrefix("/")
        else { return nil }

        let standardizedPath = StandardizedPath.absolute(trimmed)
        guard StandardizedPath.isDescendant(standardizedPath, of: state.root.standardizedFullPath),
              standardizedPath != state.root.standardizedFullPath
        else { return nil }

        let relativePath = relativePath(for: standardizedPath, rootPath: state.root.standardizedFullPath)
        guard let record = await file(rootID: state.root.id, relativePath: relativePath),
              record.rootID == state.root.id,
              record.standardizedFullPath == standardizedPath
        else { return nil }
        return record
    }

    /// Reads one exact, already-cataloged record and revalidates its root lifetime after the await.
    /// No raw absolute-path or filesystem fallback is permitted.
    func readExactCatalogFile(
        _ file: WorkspaceFileRecord,
        expectedRoot: WorkspaceRootRef
    ) async -> String? {
        guard await (try? requirePublishedSeededAuthorityFresh(rootID: file.rootID)) != nil else { return nil }
        guard let state = exactRootState(expectedRoot: expectedRoot, expectedKind: .workspaceGitData),
              file.rootID == state.root.id,
              let current = await self.file(rootID: state.root.id, relativePath: file.standardizedRelativePath),
              current.id == file.id,
              current.standardizedFullPath == file.standardizedFullPath
        else { return nil }

        let expectedLifetimeID = state.lifetimeID
        let content = try? await state.service.loadContent(ofRelativePath: file.standardizedRelativePath)

        guard await (try? requirePublishedSeededAuthorityFresh(rootID: file.rootID)) != nil else { return nil }

        guard let currentState = rootStatesByID[expectedRoot.id],
              currentState.lifetimeID == expectedLifetimeID,
              currentState.root.standardizedFullPath == expectedRoot.standardizedFullPath,
              currentState.root.kind == .workspaceGitData,
              let revalidated = await self.file(rootID: expectedRoot.id, relativePath: file.standardizedRelativePath),
              revalidated.id == file.id,
              revalidated.standardizedFullPath == file.standardizedFullPath
        else { return nil }
        return content
    }

    private func exactRootState(
        expectedRoot: WorkspaceRootRef,
        expectedKind: WorkspaceRootKind
    ) -> RootState? {
        guard let state = rootStatesByID[expectedRoot.id],
              state.root.id == expectedRoot.id,
              state.root.standardizedFullPath == expectedRoot.standardizedFullPath,
              state.root.kind == expectedKind
        else { return nil }
        return state
    }

    func displayRootRefsSnapshot() -> WorkspaceDisplayRootRefsSnapshot {
        WorkspaceDisplayRootRefsSnapshot(
            visibleRoots: rootRefs(scope: .visibleWorkspace),
            allRoots: rootRefs(scope: .allLoaded)
        )
    }

    func exactPathResolutionIssue(
        for userPath: String,
        kind: WorkspaceExactPathLookupKind,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> PathResolutionIssue? {
        await exactPathResolutionIssue(
            for: userPath,
            kind: kind,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func exactPathResolutionIssue(
        for userPath: String,
        kind: WorkspaceExactPathLookupKind,
        rootRefs roots: [WorkspaceRootRef]
    ) async -> PathResolutionIssue? {
        let trimmedInput = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return .emptyInput }
        if StandardizedPath.containsNUL(trimmedInput) {
            return .invalidPathCharacters(
                input: trimmedInput,
                reason: "embedded NUL (\\0) characters are not allowed"
            )
        }
        let expanded = (trimmedInput as NSString).expandingTildeInPath
        let standardized = StandardizedPath.absolute(expanded)
        guard !standardized.hasPrefix("/") else { return nil }

        guard !roots.isEmpty else { return nil }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: roots,
            options: RootAliasOptions(requireRemainder: false, allowCompatibilityAlias: true)
        ) {
        case let .ambiguous(alias, matchingRoots):
            return .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)
        case let .bareRoot(root, _):
            switch kind {
            case .folder, .either:
                if rootStatesByID[root.id] != nil { return nil }
            case .file:
                break
            }
        case let .prefixed(root, _, remainder):
            let absolute = StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: StandardizedPath.relative(remainder)
            )
            if await exactRecordExists(standardizedFullPath: absolute, kind: kind) { return nil }
        case .notAliasPrefixed:
            break
        }

        let relative = StandardizedPath.relative(standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !relative.isEmpty else { return nil }
        var matchingRoots: [WorkspaceRootRef] = []
        for root in roots {
            let absolute = StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: relative
            )
            if await exactRecordExists(standardizedFullPath: absolute, kind: kind) {
                matchingRoots.append(root)
            }
        }
        guard matchingRoots.count > 1 else { return nil }
        return .ambiguousRootMatch(input: trimmedInput, candidateRoots: matchingRoots)
    }

    func lookupFiles(
        atPaths paths: [String],
        profile: PathLocateProfile = .mcpSelection,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> [String: WorkspaceFileRecord] {
        var files: [String: WorkspaceFileRecord] = [:]
        var generalLookupPaths: [String] = []
        for path in paths {
            switch await lookupCatalogFileForExplicitRequest(path, rootScope: rootScope) {
            case let .matched(file):
                files[path] = file
                continue
            case .ambiguous, .blocked:
                continue
            case .noCandidate:
                break
            }
            switch try? await materializeExplicitlyRequestedFile(path, rootScope: rootScope) {
            case let .some(.materialized(file)):
                files[path] = file
            case .some(.ambiguous), .some(.blocked):
                continue
            case .some(.noCandidate), .none:
                generalLookupPaths.append(path)
            }
        }
        let requests = generalLookupPaths.map { WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope) }
        let results = await lookupPaths(requests)
        for path in generalLookupPaths where files[path] == nil {
            if let file = results[path]?.file {
                files[path] = file
            }
        }
        return files
    }

    func resolveFolderInput(
        _ path: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        profile: PathLocateProfile = .mcpSelection
    ) async -> (folder: WorkspaceFolderRecord?, displayPath: String?, issue: PathResolutionIssue?) {
        await resolveFolderInput(
            path,
            rootScope: rootScope,
            profile: profile,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func resolveFolderInput(
        _ path: String,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile,
        rootRefs roots: [WorkspaceRootRef],
        validateIssue: Bool = true,
        allowGeneralLookupFallback: Bool = true
    ) async -> (folder: WorkspaceFolderRecord?, displayPath: String?, issue: PathResolutionIssue?) {
        let cleaned = normalizeUserInputPath(path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return (nil, nil, .emptyInput) }

        if validateIssue,
           let issue = await exactPathResolutionIssue(for: cleaned, kind: .folder, rootRefs: roots)
        {
            return (nil, nil, issue)
        }

        if cleaned.hasPrefix("/") {
            let absolute = StandardizedPath.absolute(cleaned)
            if let root = roots.first(where: { absolute == $0.standardizedFullPath || absolute.hasPrefix($0.standardizedFullPath + "/") }) {
                let relative = relativePath(for: absolute, rootPath: root.standardizedFullPath)
                if let folder = await folder(rootID: root.id, relativePath: relative), isDiscoverableFolderID(folder.id) {
                    return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
                }
            }
            let pseudoAlias = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch WorkspaceAliasResolver.resolve(userPath: pseudoAlias, roots: roots, options: RootAliasOptions(requireRemainder: false)) {
            case let .bareRoot(root, _):
                if let folder = rootFolderRecord(rootID: root.id) {
                    return (folder, ClientPathFormatter.displayPath(root: root, relativePath: "", visibleRoots: roots), nil)
                }
            case let .prefixed(root, _, remainder):
                if let folder = await folder(rootID: root.id, relativePath: remainder), isDiscoverableFolderID(folder.id) {
                    return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
                }
            case let .ambiguous(alias, matchingRoots):
                return (nil, nil, .ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
            case .notAliasPrefixed:
                break
            }
        }

        switch WorkspaceAliasResolver.resolve(userPath: cleaned, roots: roots, options: RootAliasOptions(requireRemainder: false)) {
        case let .bareRoot(root, _):
            if let folder = rootFolderRecord(rootID: root.id) {
                return (folder, ClientPathFormatter.displayPath(root: root, relativePath: "", visibleRoots: roots), nil)
            }
        case let .prefixed(root, _, remainder):
            if let folder = await folder(rootID: root.id, relativePath: remainder), isDiscoverableFolderID(folder.id) {
                return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
            }
        case let .ambiguous(alias, matchingRoots):
            return (nil, nil, .ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
        case .notAliasPrefixed:
            break
        }

        let relative = StandardizedPath.relative(cleaned)
        var directRelativeMatches: [(WorkspaceRootRef, WorkspaceFolderRecord)] = []
        for root in roots {
            guard let folder = await folder(rootID: root.id, relativePath: relative), isDiscoverableFolderID(folder.id) else { continue }
            directRelativeMatches.append((root, folder))
        }
        if directRelativeMatches.count == 1, let match = directRelativeMatches.first {
            return (
                match.1,
                ClientPathFormatter.displayPath(root: match.0, relativePath: match.1.standardizedRelativePath, visibleRoots: roots),
                nil
            )
        }

        guard allowGeneralLookupFallback else { return (nil, nil, nil) }
        let generalLookupState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.folderResolutionGeneralLookupFallback)
        let lookup = await lookupPath(
            WorkspacePathLookupRequest(userPath: cleaned, profile: profile, rootScope: rootScope),
            rootRefs: roots
        )
        EditFlowPerf.end(
            EditFlowPerf.Stage.ReadFile.folderResolutionGeneralLookupFallback,
            generalLookupState,
            EditFlowPerf.Dimensions(outcome: lookup?.folder == nil ? "noFolder" : "folder")
        )
        if let folder = lookup?.folder,
           let root = roots.first(where: { $0.id == folder.rootID })
        {
            return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
        }
        return (nil, nil, nil)
    }

    func expandFolderInputToFiles(
        _ path: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        profile: PathLocateProfile = .mcpSelection
    ) async -> WorkspaceFolderExpansionResult {
        let resolution = await resolveFolderInput(path, rootScope: rootScope, profile: profile)
        if let folder = resolution.folder {
            return await WorkspaceFolderExpansionResult(
                files: descendantFiles(in: folder.id),
                handled: true,
                displayPath: resolution.displayPath,
                issue: nil
            )
        }
        if let issue = resolution.issue {
            return WorkspaceFolderExpansionResult(files: [], handled: false, displayPath: nil, issue: issue)
        }
        return WorkspaceFolderExpansionResult(files: [], handled: false, displayPath: nil, issue: .unresolved(input: path))
    }

    func resolveSelectedCodeStructureFiles(
        atPaths paths: [String],
        rootScope: WorkspaceLookupRootScope,
        maximumUniqueFileCount: Int
    ) async -> WorkspaceBoundedCodeStructureFileResolution {
        precondition(maximumUniqueFileCount > 0)
        #if DEBUG
            codeStructureSelectedMetadataResolutionRequestCountForTesting += 1
        #endif
        var files: [WorkspaceFileRecord] = []
        var seenStandardizedFullPaths = Set<String>()

        for path in paths {
            switch await lookupCatalogFileForExplicitRequest(path, rootScope: rootScope) {
            case let .matched(file):
                guard seenStandardizedFullPaths.insert(file.standardizedFullPath).inserted else {
                    continue
                }
                files.append(file)
                if files.count > maximumUniqueFileCount {
                    return WorkspaceBoundedCodeStructureFileResolution(
                        files: files,
                        didExceedLimit: true,
                        visitedUniqueFileCount: files.count
                    )
                }
                continue
            case .ambiguous, .blocked:
                continue
            case .noCandidate:
                break
            }

            let folderResolution = await expandFolderInputToFiles(
                path,
                rootScope: rootScope,
                profile: .mcpSelection,
                excludingStandardizedFullPaths: seenStandardizedFullPaths,
                maximumUniqueFileCount: maximumUniqueFileCount - files.count,
                allowGeneralLookupFallback: false
            )
            guard folderResolution.handled else { continue }
            for file in folderResolution.files
                where seenStandardizedFullPaths.insert(file.standardizedFullPath).inserted
            {
                files.append(file)
            }
            if folderResolution.didExceedLimit {
                return WorkspaceBoundedCodeStructureFileResolution(
                    files: files,
                    didExceedLimit: true,
                    visitedUniqueFileCount: files.count
                )
            }
        }
        return WorkspaceBoundedCodeStructureFileResolution(
            files: files,
            didExceedLimit: false,
            visitedUniqueFileCount: files.count
        )
    }

    func expandFolderInputToFiles(
        _ path: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        profile: PathLocateProfile = .mcpSelection,
        excludingStandardizedFullPaths: Set<String>,
        maximumUniqueFileCount: Int,
        allowGeneralLookupFallback: Bool = true
    ) async -> WorkspaceBoundedFolderExpansionResult {
        precondition(maximumUniqueFileCount >= 0)
        let resolution = await resolveFolderInput(
            path,
            rootScope: rootScope,
            profile: profile,
            rootRefs: rootRefs(scope: rootScope),
            allowGeneralLookupFallback: allowGeneralLookupFallback
        )
        if let folder = resolution.folder {
            let traversal = await boundedDescendantFiles(
                in: folder.id,
                excludingStandardizedFullPaths: excludingStandardizedFullPaths,
                maximumUniqueFileCount: maximumUniqueFileCount
            )
            return WorkspaceBoundedFolderExpansionResult(
                files: traversal.files,
                handled: true,
                displayPath: resolution.displayPath,
                issue: nil,
                didExceedLimit: traversal.didExceedLimit,
                visitedUniqueFileCount: traversal.files.count
            )
        }
        if let issue = resolution.issue {
            return WorkspaceBoundedFolderExpansionResult(
                files: [],
                handled: false,
                displayPath: nil,
                issue: issue,
                didExceedLimit: false,
                visitedUniqueFileCount: 0
            )
        }
        return WorkspaceBoundedFolderExpansionResult(
            files: [],
            handled: false,
            displayPath: nil,
            issue: .unresolved(input: path),
            didExceedLimit: false,
            visitedUniqueFileCount: 0
        )
    }

    private func boundedDescendantFiles(
        in folderID: UUID,
        excludingStandardizedFullPaths: Set<String>,
        maximumUniqueFileCount: Int
    ) async -> (files: [WorkspaceFileRecord], didExceedLimit: Bool) {
        guard let authority = try? await inventoryScopeAuthorityInstance(),
              let block = try? await authority.resolveRecordsScopeWide(fileIDs: [], folderIDs: [folderID]),
              let fact = block.foldersByID[folderID], fact.exists, let rootID = fact.rootID,
              let pageIndex = await fetchFileTreePageIndex(rootID: rootID)
        else { return ([], false) }

        var files: [WorkspaceFileRecord] = []
        var seenStandardizedFullPaths = excludingStandardizedFullPaths
        var visitedFolderIDs = Set<UUID>()

        func visit(_ currentFolderID: UUID) -> Bool {
            guard visitedFolderIDs.insert(currentFolderID).inserted else { return false }

            for fileID in pageIndex.childFileIDsByFolderID[currentFolderID] ?? [] {
                guard isDiscoverableFileID(fileID),
                      let file = pageIndex.filesByID[fileID],
                      seenStandardizedFullPaths.insert(file.standardizedFullPath).inserted
                else { continue }
                files.append(file)
                if files.count > maximumUniqueFileCount { return true }
            }
            for childFolderID in pageIndex.childFolderIDsByFolderID[currentFolderID] ?? [] {
                guard isDiscoverableFolderID(childFolderID) else { continue }
                if visit(childFolderID) { return true }
            }
            return false
        }

        let didExceedLimit = visit(folderID)
        return (files, didExceedLimit)
    }

    /// P4-6b table-deletion conversion: no per-root context is available here (the caller only
    /// has an absolute path), so this routes through `loadedRoot(containing:)` (any loaded root,
    /// matching this function's pre-conversion cross-root global-dict lookup) and the ordinary
    /// async `file`/`folder` accessors.
    private func exactRecordExists(standardizedFullPath: String, kind: WorkspaceExactPathLookupKind) async -> Bool {
        let absolute = StandardizedPath.absolute(standardizedFullPath)
        guard let root = loadedRoot(containing: absolute) else { return false }
        let relative = relativePath(for: absolute, rootPath: root.standardizedFullPath)
        switch kind {
        case .file:
            return await file(rootID: root.id, relativePath: relative) != nil
        case .folder:
            return await folder(rootID: root.id, relativePath: relative) != nil
        case .either:
            if await file(rootID: root.id, relativePath: relative) != nil { return true }
            return await folder(rootID: root.id, relativePath: relative) != nil
        }
    }

    /// The root's own self-referencing folder marker (id == rootID, relativePath == "") is never
    /// sent to Rust (root-marker exclusion) -- constructed locally from the root record itself,
    /// matching the identical synthesis already used by the file-tree snapshot code.
    private func rootFolderRecord(rootID: UUID) -> WorkspaceFolderRecord? {
        guard let root = rootStatesByID[rootID]?.root else { return nil }
        return WorkspaceFolderRecord(
            id: root.id, rootID: root.id, name: root.name,
            relativePath: "", fullPath: root.fullPath, parentFolderID: nil
        )
    }

    /// P4-6b table-deletion conversion: only a folder id is known here (no path, no root), so the
    /// owning root must be resolved first via a scope-wide id fact, then the whole root is paged
    /// once to answer the descendant walk (mirrors `fetchFileTreePageIndex`'s existing Tier-1
    /// shape; the recursive walk itself is unchanged, just against the paged adjacency maps
    /// instead of `RootState`'s per-root maps).
    private func descendantFiles(in folderID: UUID) async -> [WorkspaceFileRecord] {
        guard let authority = try? await inventoryScopeAuthorityInstance(),
              let block = try? await authority.resolveRecordsScopeWide(fileIDs: [], folderIDs: [folderID]),
              let fact = block.foldersByID[folderID], fact.exists, let rootID = fact.rootID,
              let pageIndex = await fetchFileTreePageIndex(rootID: rootID)
        else { return [] }
        let ids = descendantFileIDs(in: folderID, pageIndex: pageIndex)
        return ids.compactMap { pageIndex.filesByID[$0] }
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    private func lookupResult(input: String, match: PathMatchLocation) async -> WorkspacePathLookupResult? {
        let rootPath = (match.rootPath as NSString).standardizingPath
        guard let rootID = rootIDsByStandardizedPath[rootPath],
              let state = rootStatesByID[rootID]
        else { return nil }
        return await lookupResult(input: input, root: state.root, correctedPath: match.correctedPath)
    }

    private func lookupResult(input: String, root: WorkspaceRootRecord, correctedPath: String) async -> WorkspacePathLookupResult? {
        let correctedPath = StandardizedPath.relative(correctedPath)
        let file = await file(rootID: root.id, relativePath: correctedPath)
        let folder = await folder(rootID: root.id, relativePath: correctedPath)
        guard file != nil || folder != nil else { return nil }
        return WorkspacePathLookupResult(
            input: input,
            location: WorkspacePathLocation(rootID: root.id, rootPath: root.standardizedFullPath, correctedPath: correctedPath),
            file: file,
            folder: folder
        )
    }

    private func buildStaticSnapshot(scope: WorkspaceLookupRootScope) async -> StaticPathMatchData {
        let cacheIdentity = pathMatchCacheIdentity(scope: scope)
        if var cached = staticPathMatchSnapshotsByScope[scope],
           cached.snapshot.cacheIdentity == cacheIdentity
        {
            cached.lastAccessSequence = nextStaticPathMatchSnapshotAccessSequenceValue()
            staticPathMatchSnapshotsByScope[scope] = cached
            return cached.snapshot
        }
        let snapshot = await buildStaticSnapshot(
            rootRefs: rootRefs(scope: scope),
            cacheIdentity: cacheIdentity
        )
        cacheStaticPathMatchSnapshot(snapshot, scope: scope)
        return snapshot
    }

    private func buildStaticSnapshot(
        scope: WorkspaceLookupRootScope,
        rootRefs roots: [WorkspaceRootRef]
    ) async -> StaticPathMatchData {
        await buildStaticSnapshot(
            rootRefs: roots,
            cacheIdentity: pathMatchCacheIdentity(scope: scope, rootRefs: roots)
        )
    }

    /// P4-6b table-deletion conversion: the caching/eviction/identity layer above is unchanged --
    /// only this inner gather's data source changed, from the deleted global `filesByID`/
    /// `foldersByID` (filtered post-hoc by `allowedRootIDs`) to one paged `fetchFileTreePageIndex`
    /// read per root in scope, merged into the same flat full-path-keyed maps. This is the
    /// largest single read surface in the app for free-text path matching (`lookupPath`/
    /// `lookupPaths`/`findCreationPath`/`resolveCreationPath` all route through it), so the
    /// per-root/per-record shape is preserved exactly -- same `FrozenFileRecord`/
    /// `FrozenFolderRecord` construction, same first-occurrence-wins de-dup by full path, same
    /// sorted-then-insert ordering (this time inherent to iterating one paged root at a time in
    /// `rootRefs` order, each root's own records already full-path-sorted by the page walk).
    private func buildStaticSnapshot(
        rootRefs roots: [WorkspaceRootRef],
        cacheIdentity: PathMatchCacheIdentity
    ) async -> StaticPathMatchData {
        let snapshotState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild, snapshotState) }
        var fileRecords: [String: FileRecord] = [:]
        var folderRecords: [String: FolderRecord] = [:]
        var rootFolders: [FolderRecord] = []
        for root in roots {
            guard let pageIndex = await fetchFileTreePageIndex(rootID: root.id) else { continue }
            for file in pageIndex.filesByID.values.sorted(by: { $0.standardizedFullPath < $1.standardizedFullPath }) {
                guard isDiscoverableFileID(file.id),
                      fileRecords[file.standardizedFullPath] == nil
                else { continue }
                fileRecords[file.standardizedFullPath] = FrozenFileRecord(
                    name: file.name,
                    relativePath: file.standardizedRelativePath,
                    fullPath: file.standardizedFullPath,
                    rootFolderPath: root.standardizedFullPath
                ) as FileRecord
            }
            for folder in pageIndex.foldersByID.values.sorted(by: { $0.standardizedFullPath < $1.standardizedFullPath }) {
                guard isDiscoverableFolderID(folder.id),
                      folderRecords[folder.standardizedFullPath] == nil
                else { continue }
                folderRecords[folder.standardizedFullPath] = FrozenFolderRecord(
                    name: folder.name,
                    relativePath: folder.standardizedRelativePath,
                    fullPath: folder.standardizedFullPath,
                    rootPath: root.standardizedFullPath,
                    displayName: folder.name
                ) as FolderRecord
            }
            // Root-marker exclusion: the root's own self-referencing folder is never sent to
            // Rust, so it is synthesized locally here, matching `rootFolderRecord(rootID:)`.
            rootFolders.append(FrozenFolderRecord(
                name: root.name,
                relativePath: "",
                fullPath: root.standardizedFullPath,
                rootPath: root.standardizedFullPath,
                displayName: root.name
            ) as FolderRecord)
        }
        return StaticPathMatchData(
            filesByFullPath: fileRecords,
            foldersByFullPath: folderRecords,
            rootFolders: rootFolders,
            cacheScopeID: cacheIdentity.scopeID,
            id: cacheIdentity.snapshotID
        )
    }

    private func cacheStaticPathMatchSnapshot(
        _ snapshot: StaticPathMatchData,
        scope: WorkspaceLookupRootScope
    ) {
        if staticPathMatchSnapshotsByScope[scope] == nil,
           staticPathMatchSnapshotsByScope.count >= Self.maxCachedStaticPathMatchSnapshotScopes,
           let eviction = staticPathMatchSnapshotsByScope.min(by: {
               $0.value.lastAccessSequence < $1.value.lastAccessSequence
           })
        {
            staticPathMatchSnapshotsByScope.removeValue(forKey: eviction.key)
            if pathMatchSnapshotIdentitiesByScope[eviction.key] == eviction.value.snapshot.cacheIdentity {
                pathMatchSnapshotIdentitiesByScope.removeValue(forKey: eviction.key)
            }
            invalidatePathMatchCache(snapshotIdentities: [eviction.value.snapshot.cacheIdentity])
        }
        pathMatchSnapshotIdentitiesByScope[scope] = snapshot.cacheIdentity
        staticPathMatchSnapshotsByScope[scope] = StaticPathMatchSnapshotCacheEntry(
            snapshot: snapshot,
            lastAccessSequence: nextStaticPathMatchSnapshotAccessSequenceValue()
        )
    }

    private func nextStaticPathMatchSnapshotAccessSequenceValue() -> UInt64 {
        nextStaticPathMatchSnapshotAccessSequence &+= 1
        return nextStaticPathMatchSnapshotAccessSequence
    }

    private func pathMatchCacheIdentity(scope: WorkspaceLookupRootScope) -> PathMatchCacheIdentity {
        PathMatchCacheIdentity(
            scopeID: scopeDiscriminator(scope),
            snapshotID: scopedSnapshotGeneration(scope: scope)
        )
    }

    private func pathMatchCacheIdentity(
        scope: WorkspaceLookupRootScope,
        rootRefs roots: [WorkspaceRootRef]
    ) -> PathMatchCacheIdentity {
        var hasher = Hasher()
        hasher.combine("explicitRootRefs")
        hasher.combine(scopeDiscriminator(scope))
        for root in roots {
            hasher.combine(root.id)
            hasher.combine(root.standardizedFullPath)
            hasher.combine(rootStatesByID[root.id]?.lifetimeID)
            hasher.combine(catalogGenerationsByRootID[root.id] ?? 0)
        }
        return PathMatchCacheIdentity(
            scopeID: scopeDiscriminator(scope),
            snapshotID: UInt64(bitPattern: Int64(hasher.finalize()))
        )
    }

    #if DEBUG
        func staticPathMatchSnapshotCacheCountForTesting() -> Int {
            staticPathMatchSnapshotsByScope.count
        }

        func searchCatalogSnapshotCacheCountForTesting() -> Int {
            searchCatalogSnapshotsByScope.count
        }

        /// P4-7b §4.3 b2 done-when (RK-12): Swift's own discoverability-filter membership, for the
        /// differential that compares it against Rust's `managed_only` copy
        /// (`WorkspaceInventoryFileRecordFact.isDiscoverable` / `.FolderRecordFact.isDiscoverable`
        /// via `inventoryRecordFacts`). Compare these raw ID sets, not a derived "resulting
        /// discoverable records" set -- the latter also differs by the Item 0 root-marker-folder
        /// synthesis (docs/architecture/rust-inventory-scope-v1.md §12.5), which is a Swift-only
        /// synthetic record Rust never claims to filter and is not part of what this done-when means.
        func managedOnlyFileIDsForTesting() -> Set<UUID> {
            managedOnlyFileIDs
        }

        func managedOnlyFolderIDsForTesting() -> Set<UUID> {
            managedOnlyFolderIDs
        }

        /// P4-7b §4.5 done-when: the handle counters (`openHandleCount` in particular) the
        /// handle-lifecycle soak reads to assert no leak across the soak's open/close cycles.
        func inventoryScopeDiagnosticsForTesting() async -> CoreInventoryDiagnosticsV1? {
            guard let authority = try? await inventoryScopeAuthorityInstance() else { return nil }
            return try? await authority.diagnostics()
        }

        func sessionCatalogGenerationForTesting(scope: WorkspaceLookupRootScope) -> UInt64? {
            sessionCatalogGenerationStatesByScope[scope]?.generation
        }
    #endif

    private func scopedSnapshotGeneration(scope: WorkspaceLookupRootScope) -> UInt64 {
        scopedSnapshotGeneration(
            scope: scope,
            validationToken: searchCatalogSnapshotValidationToken(scope: scope)
        )
    }

    private func scopedSnapshotGeneration(
        scope: WorkspaceLookupRootScope,
        validationToken: SearchCatalogSnapshotValidationToken
    ) -> UInt64 {
        switch validationToken {
        case let .staticScope(generation):
            return generation
        case .sessionBound:
            if let state = sessionCatalogGenerationStatesByScope[scope],
               state.validationToken == validationToken
            {
                return state.generation
            }
            nextSessionCatalogGeneration &+= 1
            let generation = nextSessionCatalogGeneration
            sessionCatalogGenerationStatesByScope[scope] = SessionCatalogGenerationState(
                validationToken: validationToken,
                generation: generation
            )
            return generation
        }
    }

    private func searchCatalogSnapshotValidationToken(
        scope: WorkspaceLookupRootScope
    ) -> SearchCatalogSnapshotValidationToken {
        switch scope {
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded, .allLoadedExcludingGitData:
            var hasher = Hasher()
            hasher.combine((catalogGenerationsByScope[scope] ?? 0) &* 3 &+ scopeDiscriminator(scope))
            for root in rootsForPathLookupIgnoringPublishedAuthority(scope: scope) {
                guard publishedSeededAuthorityFencesByRootID[root.id] != nil else { continue }
                hasher.combine(root.id)
                hasher.combine(publishedSeededAuthorityStatesByRootID[root.id]?.epoch ?? 0)
                hasher.combine(publishedSeededAuthorityIsQueryable(rootID: root.id))
            }
            let generation = UInt64(bitPattern: Int64(hasher.finalize()))
            return .staticScope(generation: generation)
        case let .sessionBoundWorkspace(logicalRootPaths, physicalRootPaths):
            let normalizedLogicalRootPaths = normalizedSessionSelectorPaths(logicalRootPaths).sorted()
            let normalizedPhysicalRootPaths = normalizedSessionSelectorPaths(physicalRootPaths).sorted()
            let dependencies = rootsForPathLookup(scope: scope).compactMap { root -> SearchCatalogRootDependency? in
                guard let state = rootStatesByID[root.id] else { return nil }
                return SearchCatalogRootDependency(
                    canonicalIdentity: root.standardizedFullPath,
                    rootID: root.id,
                    lifetimeID: state.lifetimeID,
                    generation: catalogGenerationsByRootID[root.id] ?? 0
                )
            }.sorted {
                if $0.canonicalIdentity == $1.canonicalIdentity {
                    return $0.rootID.uuidString < $1.rootID.uuidString
                }
                return $0.canonicalIdentity < $1.canonicalIdentity
            }
            return .sessionBound(
                logicalRootPaths: normalizedLogicalRootPaths,
                physicalRootPaths: normalizedPhysicalRootPaths,
                dependencies: dependencies
            )
        case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots):
            let normalizedLogicalRootPaths = canonicalRoots.map(\.standardizedFullPath).sorted()
            let normalizedPhysicalRootPaths = physicalRoots.map(\.standardizedFullPath).sorted()
            let dependencies = rootsForPathLookup(scope: scope).compactMap { root -> SearchCatalogRootDependency? in
                guard let state = rootStatesByID[root.id] else { return nil }
                return SearchCatalogRootDependency(
                    canonicalIdentity: root.standardizedFullPath,
                    rootID: root.id,
                    lifetimeID: state.lifetimeID,
                    generation: catalogGenerationsByRootID[root.id] ?? 0
                )
            }.sorted {
                if $0.canonicalIdentity == $1.canonicalIdentity {
                    return $0.rootID.uuidString < $1.rootID.uuidString
                }
                return $0.canonicalIdentity < $1.canonicalIdentity
            }
            return .sessionBound(
                logicalRootPaths: normalizedLogicalRootPaths,
                physicalRootPaths: normalizedPhysicalRootPaths,
                dependencies: dependencies
            )
        }
    }

    private func cacheSearchCatalogSnapshot(
        _ snapshot: WorkspaceSearchCatalogSnapshot,
        validationToken: SearchCatalogSnapshotValidationToken,
        capability: WorkspaceSearchCatalogAccessRequirement,
        scope: WorkspaceLookupRootScope
    ) {
        if searchCatalogSnapshotsByScope[scope] == nil,
           searchCatalogSnapshotsByScope.count >= Self.maxCachedSearchCatalogSnapshotScopes,
           let eviction = searchCatalogSnapshotsByScope.min(by: {
               $0.value.lastAccessSequence < $1.value.lastAccessSequence
           })
        {
            evictSearchCatalogSnapshots(
                scopes: [eviction.key],
                reasons: [.cacheCapacity],
                affectedRootIDs: Set(eviction.value.snapshot.roots.map(\.id)),
                affectedRootKinds: Set(eviction.value.snapshot.roots.map(\.kind))
            )
        }
        searchCatalogSnapshotsByScope[scope] = SearchCatalogSnapshotCacheEntry(
            validationToken: validationToken,
            capability: capability,
            snapshot: snapshot,
            lastAccessSequence: nextSearchCatalogAccessSequence()
        )
    }

    private func nextSearchCatalogAccessSequence() -> UInt64 {
        nextSearchCatalogSnapshotAccessSequence &+= 1
        return nextSearchCatalogSnapshotAccessSequence
    }

    private func scopeDiscriminator(_ scope: WorkspaceLookupRootScope) -> UInt64 {
        switch scope {
        case .visibleWorkspace:
            return 0
        case .visibleWorkspacePlusGitData:
            return 1
        case .allLoaded:
            return 2
        case .allLoadedExcludingGitData:
            return 3
        case let .sessionBoundWorkspace(canonicalRootPaths, physicalRootPaths):
            var hasher = Hasher()
            hasher.combine("sessionBoundWorkspace")
            hasher.combine(normalizedSessionSelectorPaths(canonicalRootPaths).sorted())
            hasher.combine(normalizedSessionSelectorPaths(physicalRootPaths).sorted())
            return UInt64(bitPattern: Int64(hasher.finalize()))
        case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots):
            var hasher = Hasher()
            hasher.combine("validatedSessionBoundWorkspace")
            hasher.combine(canonicalRoots.sorted { $0.id.uuidString < $1.id.uuidString })
            hasher.combine(physicalRoots.sorted { $0.id.uuidString < $1.id.uuidString })
            return UInt64(bitPattern: Int64(hasher.finalize()))
        }
    }

    private func withCodemapPathLocalCatalogMutation<T>(
        rootID: UUID,
        _ body: () async throws -> T
    ) async rethrows -> T {
        codemapPathLocalCatalogMutationDepthByRootID[rootID, default: 0] += 1
        defer {
            let next = (codemapPathLocalCatalogMutationDepthByRootID[rootID] ?? 1) - 1
            if next == 0 {
                codemapPathLocalCatalogMutationDepthByRootID.removeValue(forKey: rootID)
            } else {
                codemapPathLocalCatalogMutationDepthByRootID[rootID] = next
            }
        }
        return try await body()
    }

    private func bumpCatalogGenerations(
        affectedRootKinds: Set<WorkspaceRootKind>,
        affectedRootIDs: Set<UUID>
    ) {
        guard !affectedRootKinds.isEmpty || !affectedRootIDs.isEmpty else { return }
        for scope in WorkspaceFileContextStore.catalogGenerationScopes {
            guard scopeIncludesAnyRootKind(scope, affectedRootKinds) else { continue }
            catalogGenerationsByScope[scope] = (catalogGenerationsByScope[scope] ?? 0) &+ 1
            #if DEBUG
                Self.activePublicationInvalidationRecorder?.catalogGenerationAdvanceCount += 1
            #endif
        }
        let rootIDsToAdvance = affectedRootIDs.isEmpty
            ? Set(rootStatesByID.values.compactMap { affectedRootKinds.contains($0.root.kind) ? $0.root.id : nil })
            : affectedRootIDs
        for rootID in rootIDsToAdvance {
            catalogGenerationsByRootID[rootID] = (catalogGenerationsByRootID[rootID] ?? 0) &+ 1
        }
        let rootIDsRequiringAuthorityFence = rootIDsToAdvance.filter {
            codemapPathLocalCatalogMutationDepthByRootID[$0] == nil
        }
        let rootEpochsRequiringAuthorityFence = Set(codemapSessionsByRootEpoch.keys)
            .union(codemapGraphIndexBuildLaunchesByRootEpoch.keys)
            .union(codemapEligibilityFlightsByRootEpoch.keys)
            .union(codemapCompletedEligibilityByRootEpoch.keys)
            .union(codemapGraphIndexBuildRetriesByRootEpoch.keys)
            .filter { rootIDsRequiringAuthorityFence.contains($0.rootID) }
        for rootEpoch in rootEpochsRequiringAuthorityFence {
            _ = detachCodemapSession(
                rootEpoch: rootEpoch,
                invalidationCommands: [.catalogAdvanced]
            )
        }
    }

    private static let catalogGenerationScopes: [WorkspaceLookupRootScope] = [
        .visibleWorkspace,
        .visibleWorkspacePlusGitData,
        .allLoaded,
        .allLoadedExcludingGitData
    ]

    private func scopeIncludesAnyRootKind(_ scope: WorkspaceLookupRootScope, _ kinds: Set<WorkspaceRootKind>) -> Bool {
        switch scope {
        case .visibleWorkspace:
            kinds.contains(.primaryWorkspace)
        case .visibleWorkspacePlusGitData:
            kinds.contains(.primaryWorkspace) || kinds.contains(.workspaceGitData)
        case .allLoaded:
            true
        case .allLoadedExcludingGitData:
            kinds.contains { $0 != .workspaceGitData }
        case .sessionBoundWorkspace, .validatedSessionBoundWorkspace:
            kinds.contains(.primaryWorkspace) || kinds.contains(.sessionWorktree)
        }
    }

    private func normalizedSessionSelectorPaths(_ paths: Set<String>) -> Set<String> {
        Set(paths.map { StandardizedPath.absolute(($0 as NSString).expandingTildeInPath) })
    }

    private func rootsForPathLookup(scope: WorkspaceLookupRootScope) -> [WorkspaceRootRecord] {
        rootsForPathLookupIgnoringPublishedAuthority(scope: scope).filter {
            publishedSeededAuthorityIsQueryable(rootID: $0.id)
        }
    }

    private func rootsForPathLookupIgnoringPublishedAuthority(
        scope: WorkspaceLookupRootScope
    ) -> [WorkspaceRootRecord] {
        let allRoots = roots()
        switch scope {
        case .visibleWorkspace:
            return allRoots.filter { $0.kind == .primaryWorkspace }
        case .visibleWorkspacePlusGitData:
            return allRoots.filter { $0.kind == .primaryWorkspace || $0.kind == .workspaceGitData }
        case .allLoaded:
            return allRoots
        case .allLoadedExcludingGitData:
            return allRoots.filter { $0.kind != .workspaceGitData }
        case let .sessionBoundWorkspace(canonicalRootPaths, physicalRootPaths):
            let normalizedCanonicalRootPaths = normalizedSessionSelectorPaths(canonicalRootPaths)
            let normalizedPhysicalRootPaths = normalizedSessionSelectorPaths(physicalRootPaths)
            return allRoots.filter { root in
                switch root.kind {
                case .primaryWorkspace:
                    normalizedCanonicalRootPaths.contains(root.standardizedFullPath)
                case .sessionWorktree:
                    normalizedPhysicalRootPaths.contains(root.standardizedFullPath)
                case .workspaceGitData, .supplementalSystem:
                    false
                }
            }
        case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots):
            guard case let .valid(selector) = WorkspaceLookupRootSelectorValidator.validate(
                canonicalRoots: canonicalRoots,
                physicalRoots: physicalRoots
            ) else { return [] }
            return allRoots.filter { root in
                switch root.kind {
                case .primaryWorkspace:
                    selector.canonicalRootPathsByID[root.id] == root.standardizedFullPath
                case .sessionWorktree:
                    selector.physicalRootPathsByID[root.id] == root.standardizedFullPath
                case .workspaceGitData, .supplementalSystem:
                    false
                }
            }
        }
    }

    private func normalizeUserInputPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    @discardableResult
    private func evictInvalidSearchCatalogSnapshots(
        reasons: Set<CatalogInvalidationReason>,
        affectedRootIDs: Set<UUID> = [],
        affectedRootKinds: Set<WorkspaceRootKind> = []
    ) -> [WorkspaceLookupRootScope] {
        let scopes = Set(searchCatalogSnapshotsByScope.compactMap { scope, entry in
            entry.validationToken == searchCatalogSnapshotValidationToken(scope: scope) ? nil : scope
        })
        return evictSearchCatalogSnapshots(
            scopes: scopes,
            reasons: reasons,
            affectedRootIDs: affectedRootIDs,
            affectedRootKinds: affectedRootKinds
        )
    }

    @discardableResult
    private func evictSearchCatalogSnapshots(
        scopes: Set<WorkspaceLookupRootScope>,
        reasons: Set<CatalogInvalidationReason>,
        affectedRootIDs: Set<UUID> = [],
        affectedRootKinds: Set<WorkspaceRootKind> = []
    ) -> [WorkspaceLookupRootScope] {
        let evictedScopes = Array(scopes).filter { searchCatalogSnapshotsByScope.removeValue(forKey: $0) != nil }
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.searchCatalogCacheClearCount += 1
            recordCatalogInvalidation(
                reasons: reasons,
                affectedRootIDs: affectedRootIDs,
                affectedRootKinds: affectedRootKinds,
                evictedScopes: evictedScopes
            )
        #endif
        return evictedScopes
    }

    private func staleSearchContentSnapshot(for record: WorkspaceFileRecord) -> FileSearchContentSnapshot {
        FileSearchContentSnapshot(
            content: nil,
            contentRevision: nil,
            modificationDate: record.modificationDate ?? .distantPast,
            isFresh: false
        )
    }

    private func searchContentRecordIsCurrent(
        _ record: WorkspaceFileRecord,
        invalidationEpoch: UInt64
    ) async -> Bool {
        guard let current = await file(rootID: record.rootID, relativePath: record.standardizedRelativePath),
              current.id == record.id
        else { return false }
        return (searchContentInvalidationEpochsByFileID[record.id] ?? 0) == invalidationEpoch
    }

    private func pruneCatalogFileIfStillCurrent(_ record: WorkspaceFileRecord) async {
        guard let current = await file(rootID: record.rootID, relativePath: record.standardizedRelativePath),
              current.id == record.id
        else { return }
        _ = await fenceAndPruneCatalogFileMissingOnDisk(
            rootID: current.rootID,
            relativePath: current.standardizedRelativePath,
            publishDelta: true
        )
    }

    private func retainSliceRebaseSource(
        content: String?,
        modificationDate: Date,
        file: WorkspaceFileRecord,
        rootLifetimeID: UUID
    ) async {
        guard let content else { return }
        let byteCost = content.utf8.count
        guard byteCost <= Self.maxSliceRebaseSourceEntryBytes,
              let state = rootStatesByID[file.rootID],
              state.lifetimeID == rootLifetimeID,
              await self.file(rootID: file.rootID, relativePath: file.standardizedRelativePath)?.id == file.id
        else { return }
        let key = SliceRebaseSourceCacheKey(
            rootID: file.rootID,
            rootLifetimeID: rootLifetimeID,
            fileID: file.id,
            relativePath: file.standardizedRelativePath
        )
        if let previous = sliceRebaseSourceEntries.removeValue(forKey: key) {
            sliceRebaseSourceEstimatedBytes -= previous.byteCost
        }
        sliceRebaseSourceAccessOrdinal &+= 1
        let snapshot = WorkspaceSliceRebaseSourceSnapshot(
            rootID: file.rootID,
            rootLifetimeID: rootLifetimeID,
            fileID: file.id,
            relativePath: file.standardizedRelativePath,
            fullPath: file.standardizedFullPath,
            text: content,
            modificationTime: modificationDate.timeIntervalSince1970
        )
        sliceRebaseSourceEntries[key] = SliceRebaseSourceCacheEntry(
            snapshot: snapshot,
            byteCost: byteCost,
            accessOrdinal: sliceRebaseSourceAccessOrdinal
        )
        sliceRebaseSourceEstimatedBytes += byteCost
        trimSliceRebaseSourcesIfNeeded()
    }

    private func takeSliceRebaseSource(
        rootID: UUID,
        rootLifetimeID: UUID,
        file: WorkspaceFileRecord
    ) -> WorkspaceSliceRebaseSourceSnapshot? {
        let key = SliceRebaseSourceCacheKey(
            rootID: rootID,
            rootLifetimeID: rootLifetimeID,
            fileID: file.id,
            relativePath: file.standardizedRelativePath
        )
        guard let entry = sliceRebaseSourceEntries.removeValue(forKey: key) else { return nil }
        sliceRebaseSourceEstimatedBytes -= entry.byteCost
        guard entry.snapshot.fullPath == file.standardizedFullPath else { return nil }
        if let recordTime = file.modificationDate?.timeIntervalSince1970,
           abs(recordTime - entry.snapshot.modificationTime) > 0.001
        {
            return nil
        }
        return entry.snapshot
    }

    private func trimSliceRebaseSourcesIfNeeded() {
        while sliceRebaseSourceEntries.count > Self.maxSliceRebaseSourceEntryCount
            || sliceRebaseSourceEstimatedBytes > Self.maxSliceRebaseSourceTotalBytes
        {
            guard let oldest = sliceRebaseSourceEntries.min(by: { $0.value.accessOrdinal < $1.value.accessOrdinal }) else {
                break
            }
            sliceRebaseSourceEstimatedBytes -= oldest.value.byteCost
            sliceRebaseSourceEntries.removeValue(forKey: oldest.key)
        }
    }

    private func clearSliceRebaseSources() {
        sliceRebaseSourceEntries.removeAll(keepingCapacity: true)
        sliceRebaseSourceEstimatedBytes = 0
    }

    private func removeSliceRebaseSources(
        rootID: UUID,
        rootLifetimeID: UUID? = nil,
        fileID: UUID? = nil
    ) {
        let keys = sliceRebaseSourceEntries.keys.filter { key in
            guard key.rootID == rootID else { return false }
            if let rootLifetimeID, key.rootLifetimeID != rootLifetimeID { return false }
            if let fileID, key.fileID != fileID { return false }
            return true
        }
        for key in keys {
            if let removed = sliceRebaseSourceEntries.removeValue(forKey: key) {
                sliceRebaseSourceEstimatedBytes -= removed.byteCost
            }
        }
    }

    func sliceRebasePathState(fullPath rawFullPath: String) -> WorkspaceSliceRebasePathState? {
        let fullPath = StandardizedPath.absolute(rawFullPath)
        guard let root = rootStatesByID.values
            .map(\.root)
            .filter({ fullPath == $0.standardizedFullPath || fullPath.hasPrefix($0.standardizedFullPath + "/") })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count }),
            let state = rootStatesByID[root.id]
        else { return nil }
        return WorkspaceSliceRebasePathState(
            rootID: root.id,
            rootLifetimeID: state.lifetimeID,
            rootKind: root.kind,
            appliedIndexGeneration: appliedIndexGenerationsByRootID[root.id] ?? 0
        )
    }

    func sliceRebaseFileIsCurrent(
        rootID: UUID,
        rootLifetimeID: UUID,
        fileID: UUID,
        relativePath: String,
        fullPath: String
    ) async -> Bool {
        guard let state = rootStatesByID[rootID], state.lifetimeID == rootLifetimeID,
              let current = await file(rootID: rootID, relativePath: relativePath)
        else { return false }
        return current.id == fileID && current.standardizedFullPath == StandardizedPath.absolute(fullPath)
    }

    private func invalidateSearchContent(_ file: WorkspaceFileRecord) {
        let key = WorkspaceSearchContentCacheKey(
            rootID: file.rootID,
            fileID: file.id,
            standardizedRelativePath: file.standardizedRelativePath
        )
        #if DEBUG
            if let recorder = Self.activePublicationInvalidationRecorder {
                recorder.contentInvalidationCount += 1
                recorder.distinctContentKeys.insert(key)
            }
        #endif
        nextSearchContentInvalidationEpoch &+= 1
        let invalidationEpoch = nextSearchContentInvalidationEpoch
        searchContentInvalidationEpochsByFileID[file.id] = invalidationEpoch
        if let activePublicationInvalidationBatch {
            activePublicationInvalidationBatch.searchContentInvalidations.record(key, through: invalidationEpoch)
            return
        }
        Task {
            await searchDecodedContentCache.invalidate(key, through: invalidationEpoch)
            await interactiveReadCache.invalidate(key, through: invalidationEpoch)
        }
    }

    private func invalidateRetainedSearchContentForRecoveryUncertainty(rootID: UUID) async {
        guard rootStatesByID[rootID] != nil, let pageIndex = await fetchFileTreePageIndex(rootID: rootID) else { return }
        var invalidations = WorkspaceSearchContentInvalidationBatch()
        for file in pageIndex.filesByID.values {
            let key = WorkspaceSearchContentCacheKey(
                rootID: file.rootID,
                fileID: file.id,
                standardizedRelativePath: file.standardizedRelativePath
            )
            nextSearchContentInvalidationEpoch &+= 1
            let invalidationEpoch = nextSearchContentInvalidationEpoch
            searchContentInvalidationEpochsByFileID[file.id] = invalidationEpoch
            invalidations.record(key, through: invalidationEpoch)
        }
        guard !invalidations.isEmpty else { return }
        await searchDecodedContentCache.invalidate(invalidations)
        await interactiveReadCache.invalidate(invalidations)
    }

    private func finalizePublicationInvalidations(_ batch: PublicationInvalidationBatch) {
        if batch.topologyInvalidationRequested {
            performPathMatchSnapshotInvalidation(
                affectedRootKinds: batch.affectedRootKinds,
                reasons: batch.reasons.isEmpty ? [.fileSystemPublication] : batch.reasons,
                affectedRootIDs: batch.affectedRootIDs
            )
        }
        guard !batch.searchContentInvalidations.isEmpty else { return }
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.decodedCacheInvalidationRequestCount += 1
        #endif
        let searchContentInvalidations = batch.searchContentInvalidations
        Task {
            await searchDecodedContentCache.invalidate(searchContentInvalidations)
            await interactiveReadCache.invalidate(searchContentInvalidations)
        }
    }

    private func invalidatePathMatchSnapshot(
        affectedRootKinds: Set<WorkspaceRootKind>,
        reason: CatalogInvalidationReason = .catalogMutation,
        affectedRootIDs: Set<UUID> = []
    ) {
        if let activePublicationInvalidationBatch {
            activePublicationInvalidationBatch.topologyInvalidationRequested = true
            activePublicationInvalidationBatch.affectedRootKinds.formUnion(affectedRootKinds)
            activePublicationInvalidationBatch.affectedRootIDs.formUnion(affectedRootIDs)
            activePublicationInvalidationBatch.reasons.insert(.fileSystemPublication)
            return
        }
        performPathMatchSnapshotInvalidation(
            affectedRootKinds: affectedRootKinds,
            reasons: [reason],
            affectedRootIDs: affectedRootIDs
        )
    }

    private func performPathMatchSnapshotInvalidation(
        affectedRootKinds: Set<WorkspaceRootKind>,
        reasons: Set<CatalogInvalidationReason>,
        affectedRootIDs: Set<UUID>
    ) {
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.topologyInvalidationCount += 1
        #endif
        bumpCatalogGenerations(
            affectedRootKinds: affectedRootKinds,
            affectedRootIDs: affectedRootIDs
        )
        // Keep the previous immutable shard until the canonical applied-index batch arrives.
        // The batch either publishes a contiguous patch or replaces it from the authoritative root snapshot.
        evictInvalidSearchCatalogSnapshots(
            reasons: reasons,
            affectedRootIDs: affectedRootIDs,
            affectedRootKinds: affectedRootKinds
        )
        let stalePathMatchIdentities = Set(pathMatchSnapshotIdentitiesByScope.compactMap { scope, identity in
            identity == pathMatchCacheIdentity(scope: scope) ? nil : identity
        })
        pathMatchSnapshotIdentitiesByScope = pathMatchSnapshotIdentitiesByScope.filter { scope, identity in
            identity == pathMatchCacheIdentity(scope: scope)
        }
        staticPathMatchSnapshotsByScope = staticPathMatchSnapshotsByScope.filter { scope, entry in
            entry.snapshot.cacheIdentity == pathMatchCacheIdentity(scope: scope)
        }
        invalidatePathMatchCache(snapshotIdentities: stalePathMatchIdentities)
    }

    private func invalidatePathMatchCache(snapshotIdentities: Set<PathMatchCacheIdentity>) {
        guard !snapshotIdentities.isEmpty else { return }
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.pathWorkerInvalidationRequestCount += 1
        #endif
        Task { await pathMatchWorker.invalidateCache(snapshotIdentities: snapshotIdentities) }
    }

    // P4-6b: the choke points below route through the Rust authority. Ancestor-folder creation
    // (`ensureRustFolderID`) walks one level per Rust round trip -- acceptable because ancestor
    // chains in practice are shallow and, for the high-volume bulk-load path, parents are almost
    // always already indexed (an earlier chunk/earlier item in the same chunk), so the recursive
    // walk short-circuits immediately in the common case. `managedOnlyFileIDs`/`managedOnlyFolderIDs`
    // (§4.1 item 4) are kept as a Swift-local mirror rather than round-tripping through Rust's own
    // production promotion of this state (`setFileManagedOnly`/`setFolderManagedOnly`, added this
    // same commit) for *every* synchronous discoverability read throughout codemap logic (54 call
    // sites) -- Rust's copy is kept in sync at every mutation that changes it below, so both
    // remain a boolean membership flag, not a second copy of record content.

    private func indexFolder(relativePath: String, root: WorkspaceRootRecord) async {
        guard let authority = try? await inventoryScopeAuthorityInstance() else { return }
        let folderID = await ensureRustFolderID(for: relativePath, root: root, rootID: root.id, managedOnly: false)
        if let folderID, managedOnlyFolderIDs.contains(folderID) {
            managedOnlyFolderIDs.remove(folderID)
            _ = try? await authority.setFolderManagedOnly(rootID: root.id, folderID: folderID, managedOnly: false)
        }
        if let folder = await folder(rootID: root.id, relativePath: relativePath) {
            await promoteFolderToDiscoverable(folder)
        }
        invalidatePathMatchSnapshot(affectedRootKinds: [root.kind], affectedRootIDs: [root.id])
    }

    private func indexFile(relativePath: String, root: WorkspaceRootRecord, managedOnly: Bool = false) async {
        guard let authority = try? await inventoryScopeAuthorityInstance() else { return }
        let key = StandardizedPath.relative(relativePath)
        var mintedFileID: UUID?
        if let lookup = try? await authority.lookupPaths(rootID: root.id, relativePaths: [key]),
           let fact = lookup.factsByPath[key], fact.exists, let existingID = fact.fileID
        {
            mintedFileID = existingID
        } else {
            let parentPath = (key as NSString).deletingLastPathComponent
            let parentID = await ensureRustFolderID(for: parentPath, root: root, rootID: root.id, managedOnly: managedOnly)
            let discovered = CoreDiscoveredFileRecordV1(
                rootID: root.id,
                name: URL(fileURLWithPath: key).lastPathComponent,
                relativePath: key, standardizedRelativePath: key,
                fullPath: (root.fullPath as NSString).appendingPathComponent(key),
                standardizedFullPath: (root.standardizedFullPath as NSString).appendingPathComponent(key),
                parentFolderID: (parentID == root.id) ? nil : parentID,
                modificationDate: nil
            )
            if let receipt = try? await authority.applyDeltaDiscovery(
                rootID: root.id, source: "workspace-file-context-store-mint",
                event: CoreInventoryDiscoveryAppliedIndexBatchEventV1(
                    rootID: root.id, upsertedFiles: [discovered], upsertedFolders: [],
                    removedFileIDs: [], removedFolderIDs: [], removedFilePaths: [], removedFolderPaths: [],
                    modifiedFileIDs: [], modifiedFolderIDs: []
                )
            ), let newID = receipt.mintedFileIDs.first {
                mintedFileID = newID
                if managedOnly {
                    managedOnlyFileIDs.insert(newID)
                    _ = try? await authority.setFileManagedOnly(rootID: root.id, fileID: newID, managedOnly: true)
                }
            }
        }
        guard let fileID = mintedFileID else { return }
        if managedOnly {
            if !managedOnlyFileIDs.contains(fileID) {
                managedOnlyFileIDs.insert(fileID)
                _ = try? await authority.setFileManagedOnly(rootID: root.id, fileID: fileID, managedOnly: true)
            }
        } else if let file = await file(rootID: root.id, relativePath: relativePath) {
            await promoteToDiscoverable(file)
        }
        invalidatePathMatchSnapshot(affectedRootKinds: [root.kind], affectedRootIDs: [root.id])
    }

    /// Root-to-leaf ancestor walk: resolves (or mints via discovery) every path component above
    /// `relativePath` and, per the mint-once contract (contract doc §11.4), returns the immediate
    /// containing folder's id -- or `nil` for a folder path itself, whose own id the caller mints
    /// separately once its parent is known. `managedOnly` marks freshly-minted ancestors managed-
    /// only when indexing a managed-only file/folder (mirroring the pre-cutover behavior of
    /// `newlyIndexedParentFolders`); pre-existing ancestors are left exactly as Rust already has
    /// them (mirroring `discoverableParentFolders`'s "already discoverable" no-op case).
    @discardableResult
    private func ensureRustFolderID(
        for relativePath: String,
        root: WorkspaceRootRecord,
        rootID: UUID,
        managedOnly: Bool
    ) async -> UUID? {
        let key = StandardizedPath.relative(relativePath)
        if key.isEmpty || key == "." { return rootID }
        guard let authority = try? await inventoryScopeAuthorityInstance() else { return nil }
        if let lookup = try? await authority.lookupPaths(rootID: rootID, relativePaths: [key]),
           let fact = lookup.factsByPath[key], fact.exists, let existingID = fact.folderID
        {
            return existingID
        }
        let parentPath = (key as NSString).deletingLastPathComponent
        guard let parentID = await ensureRustFolderID(for: parentPath, root: root, rootID: rootID, managedOnly: managedOnly) else { return nil }
        let discovered = CoreDiscoveredFolderRecordV1(
            rootID: rootID,
            name: URL(fileURLWithPath: key).lastPathComponent,
            relativePath: key, standardizedRelativePath: key,
            fullPath: (root.fullPath as NSString).appendingPathComponent(key),
            standardizedFullPath: (root.standardizedFullPath as NSString).appendingPathComponent(key),
            parentFolderID: (parentID == rootID) ? nil : parentID,
            modificationDate: nil
        )
        guard let receipt = try? await authority.applyDeltaDiscovery(
            rootID: rootID, source: "workspace-file-context-store-mint",
            event: CoreInventoryDiscoveryAppliedIndexBatchEventV1(
                rootID: rootID, upsertedFiles: [], upsertedFolders: [discovered],
                removedFileIDs: [], removedFolderIDs: [], removedFilePaths: [], removedFolderPaths: [],
                modifiedFileIDs: [], modifiedFolderIDs: []
            )
        ), let mintedID = receipt.mintedFolderIDs.first else { return nil }
        if managedOnly {
            managedOnlyFolderIDs.insert(mintedID)
            _ = try? await authority.setFolderManagedOnly(rootID: rootID, folderID: mintedID, managedOnly: true)
        }
        return mintedID
    }

    private func publishAppliedIndexEvent(
        root: WorkspaceRootRecord,
        upsertedFiles: [WorkspaceFileRecord] = [],
        upsertedFolders: [WorkspaceFolderRecord] = [],
        removedFileIDs: [UUID] = [],
        removedFolderIDs: [UUID] = [],
        removedFilePaths: [String] = [],
        removedFolderPaths: [String] = [],
        modifiedFileIDs: [UUID] = [],
        modifiedFolderIDs: [UUID] = [],
        requiresFullResync: Bool = false
    ) async {
        let upsertedFiles = upsertedFiles.filter { isDiscoverableFileID($0.id) }
        let upsertedFolders = upsertedFolders.filter { isDiscoverableFolderID($0.id) }
        let modifiedFileIDs = modifiedFileIDs.filter(isDiscoverableFileID)
        let modifiedFolderIDs = modifiedFolderIDs.filter(isDiscoverableFolderID)
        guard requiresFullResync || !upsertedFiles.isEmpty || !upsertedFolders.isEmpty || !removedFileIDs.isEmpty || !removedFolderIDs.isEmpty || !removedFilePaths.isEmpty || !removedFolderPaths.isEmpty || !modifiedFileIDs.isEmpty || !modifiedFolderIDs.isEmpty else { return }
        let rootLifetimeID = rootStatesByID[root.id]?.lifetimeID
        // P4-6b table-deletion conversion: `filesByID[fileID]` (the modified file's current
        // record, needed by `takeSliceRebaseSource`) is now a batched `inventoryRecordFacts`
        // call over `modifiedFileIDs` instead of the deleted global dict.
        let modifiedFileRecords = await inventoryRecordFacts(fileIDs: modifiedFileIDs, folderIDs: []).filesByID
        let modifiedFileSourceSnapshotsByID: [UUID: WorkspaceSliceRebaseSourceSnapshot] = Dictionary(
            uniqueKeysWithValues: modifiedFileIDs.compactMap { fileID -> (UUID, WorkspaceSliceRebaseSourceSnapshot)? in
                guard let rootLifetimeID,
                      let file = modifiedFileRecords[fileID]?.record,
                      let snapshot = takeSliceRebaseSource(
                          rootID: root.id,
                          rootLifetimeID: rootLifetimeID,
                          file: file
                      )
                else { return nil }
                return (fileID, snapshot)
            }
        )
        let generation = nextAppliedIndexGeneration(forRootID: root.id)
        #if DEBUG
            MCPApplyEditsRebaseProbeRecorder.recordAppliedIndexModification(
                rootID: root.id,
                fileIDs: modifiedFileIDs,
                generation: generation
            )
        #endif
        await yieldAppliedIndexEvent(WorkspaceAppliedIndexBatchEvent(
            rootID: root.id,
            rootPath: root.standardizedFullPath,
            generation: generation,
            rootLifetimeID: rootLifetimeID,
            modifiedFileSourceSnapshotsByID: modifiedFileSourceSnapshotsByID,
            upsertedFiles: upsertedFiles.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath },
            upsertedFolders: upsertedFolders.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath },
            removedFileIDs: removedFileIDs,
            removedFolderIDs: removedFolderIDs,
            removedFilePaths: removedFilePaths.sorted(),
            removedFolderPaths: removedFolderPaths.sorted(),
            modifiedFileIDs: modifiedFileIDs,
            modifiedFolderIDs: modifiedFolderIDs,
            requiresFullResync: requiresFullResync
        ))
    }

    /// P4-6b: routes removal through Rust by path -- `state_machine.rs`'s `apply_event_to_maps`
    /// resolves `removed_file_paths`/`removed_folder_paths` against its own live maps (contract
    /// doc §11.4's removal-by-path form), so no pre-lookup is needed here, unlike modify/discover.
    private func removeFile(relativePath: String, rootID: UUID) async {
        guard let state = rootStatesByID[rootID], let authority = try? await inventoryScopeAuthorityInstance() else { return }
        let key = StandardizedPath.relative(relativePath)
        // Read discoverability + id before removal -- managedOnlyFileIDs membership and the
        // returned id are only meaningful pre-removal (mirrors the pre-cutover ordering).
        let existing = await file(rootID: rootID, relativePath: key)
        if let existing {
            removeSliceRebaseSources(rootID: rootID, fileID: existing.id)
            invalidateSearchContent(existing)
            searchContentInvalidationEpochsByFileID.removeValue(forKey: existing.id)
            managedOnlyFileIDs.remove(existing.id)
        }
        _ = try? await authority.applyDelta(
            rootID: rootID, source: "workspace-file-context-store-remove",
            event: CoreInventoryAppliedIndexBatchEventV1(
                rootID: rootID, upsertedFiles: [], upsertedFolders: [],
                removedFileIDs: [], removedFolderIDs: [],
                removedFilePaths: [key], removedFolderPaths: [],
                modifiedFileIDs: [], modifiedFolderIDs: []
            )
        )
        if existing != nil {
            invalidatePathMatchSnapshot(affectedRootKinds: [state.root.kind], affectedRootIDs: [state.root.id])
        }
    }

    private func removeFolder(relativePath: String, rootID: UUID) async {
        guard let state = rootStatesByID[rootID], let authority = try? await inventoryScopeAuthorityInstance() else { return }
        let key = StandardizedPath.relative(relativePath)
        if let existing = await folder(rootID: rootID, relativePath: key) {
            managedOnlyFolderIDs.remove(existing.id)
        }
        _ = try? await authority.applyDelta(
            rootID: rootID, source: "workspace-file-context-store-remove",
            event: CoreInventoryAppliedIndexBatchEventV1(
                rootID: rootID, upsertedFiles: [], upsertedFolders: [],
                removedFileIDs: [], removedFolderIDs: [],
                removedFilePaths: [], removedFolderPaths: [key],
                modifiedFileIDs: [], modifiedFolderIDs: []
            )
        )
        invalidatePathMatchSnapshot(affectedRootKinds: [state.root.kind], affectedRootIDs: [state.root.id])
    }

    /// P4-6b: whole-subtree removal. Discoverability of the tree's contents can no longer be
    /// cheaply enumerated from a local path map (`state.fileIDsByRelativePath` is gone), so this
    /// pages the subtree via the authority's paged snapshot, filtering to paths under `key`
    /// client-side (the authority has no "list by path prefix" query -- pagination + prefix filter
    /// is the existing Tier-1 shape, contract doc §6.1) rather than adding one for a single,
    /// user-initiated, non-hot-path action.
    private func removeFolderTree(relativePath: String, rootID: UUID) async -> (fileIDs: [UUID], folderIDs: [UUID], filePaths: [String], folderPaths: [String]) {
        guard let state = rootStatesByID[rootID], let authority = try? await inventoryScopeAuthorityInstance() else { return ([], [], [], []) }
        let key = StandardizedPath.relative(relativePath)
        guard !key.isEmpty, await folder(rootID: rootID, relativePath: key) != nil else { return ([], [], [], []) }

        var filePaths: [String] = []
        var folderPaths: [String] = []
        if let snapshot = try? await authority.openSnapshot(rootID: rootID) {
            var offset: UInt64 = 0
            while true {
                guard let page = try? await snapshot.page(offset: offset, limit: 4096) else { break }
                filePaths.append(
                    contentsOf: page.files.map(\.standardizedRelativePath)
                        .filter { $0 == key || $0.hasPrefix(key + "/") }
                )
                folderPaths.append(
                    contentsOf: page.folders.map(\.standardizedRelativePath)
                        .filter { $0 == key || $0.hasPrefix(key + "/") }
                )
                offset += page.returnedCount
                if !page.hasMore || page.returnedCount == 0 { break }
            }
            await snapshot.close()
        }
        folderPaths.sort { $0.count > $1.count }

        var removedFileIDs: [UUID] = []
        var removedFilePaths: [String] = []
        for path in filePaths {
            guard let existing = await file(rootID: rootID, relativePath: path) else { continue }
            let wasDiscoverable = isDiscoverableFileID(existing.id)
            await removeFile(relativePath: path, rootID: rootID)
            if wasDiscoverable {
                removedFileIDs.append(existing.id)
                removedFilePaths.append(path)
            }
        }
        var removedFolderIDs: [UUID] = []
        var removedFolderPaths: [String] = []
        for path in folderPaths {
            guard let existing = await folder(rootID: rootID, relativePath: path) else { continue }
            let wasDiscoverable = isDiscoverableFolderID(existing.id)
            await removeFolder(relativePath: path, rootID: rootID)
            if wasDiscoverable {
                removedFolderIDs.append(existing.id)
                removedFolderPaths.append(path)
            }
        }
        invalidatePathMatchSnapshot(affectedRootKinds: [state.root.kind], affectedRootIDs: [state.root.id])
        return (removedFileIDs, removedFolderIDs, removedFilePaths, removedFolderPaths)
    }

    private func isDiscoverableFileID(_ fileID: UUID) -> Bool {
        !managedOnlyFileIDs.contains(fileID)
    }

    private func isDiscoverableFolderID(_ folderID: UUID) -> Bool {
        !managedOnlyFolderIDs.contains(folderID)
    }

    private func promoteToDiscoverable(_ file: WorkspaceFileRecord) async {
        guard let authority = try? await inventoryScopeAuthorityInstance() else { return }
        if managedOnlyFileIDs.remove(file.id) != nil {
            _ = try? await authority.setFileManagedOnly(rootID: file.rootID, fileID: file.id, managedOnly: false)
        }
        if let folderID = file.parentFolderID {
            await promoteFolderToDiscoverable(rootID: file.rootID, folderID: folderID, authority: authority)
        }
    }

    private func promoteFolderToDiscoverable(_ folder: WorkspaceFolderRecord) async {
        guard let authority = try? await inventoryScopeAuthorityInstance() else { return }
        await promoteFolderToDiscoverable(rootID: folder.rootID, folderID: folder.id, authority: authority)
    }

    /// Walks the parent chain by id (`resolveRecordsScopeWide`, since only the id -- not a path
    /// -- is known at each step) rather than by the now-deleted `foldersByID` map.
    private func promoteFolderToDiscoverable(
        rootID: UUID,
        folderID: UUID,
        authority: WorkspaceInventoryScopeAuthority
    ) async {
        var currentID: UUID? = folderID
        while let id = currentID {
            if managedOnlyFolderIDs.remove(id) != nil {
                _ = try? await authority.setFolderManagedOnly(rootID: rootID, folderID: id, managedOnly: false)
            }
            guard let block = try? await authority.resolveRecordsScopeWide(fileIDs: [], folderIDs: [id]),
                  let fact = block.foldersByID[id], fact.exists
            else { break }
            currentID = fact.parentFolderID
        }
    }

    private func yieldCodemapMarkerReadiness(_ event: WorkspaceCodemapMarkerReadinessEvent) {
        for continuation in codemapMarkerReadinessContinuations.values {
            continuation.yield(event)
        }
    }

    private func isRootLifetimeCurrent(rootID: UUID, expectedLifetimeID: UUID?) -> Bool {
        guard let state = rootStatesByID[rootID] else { return false }
        guard let expectedLifetimeID else { return true }
        return state.lifetimeID == expectedLifetimeID
    }

    private func state(for rootID: UUID) throws -> RootState {
        guard let state = rootStatesByID[rootID] else {
            throw WorkspaceFileContextStoreError.rootNotLoaded(rootID)
        }
        return state
    }

    private func managedOnlyAncestorFolderIDs(for fileIDs: Set<UUID>) async -> Set<UUID> {
        guard !fileIDs.isEmpty, let authority = try? await inventoryScopeAuthorityInstance() else { return [] }
        var folderIDs = Set<UUID>()
        guard let fileBlock = try? await authority.resolveRecordsScopeWide(fileIDs: Array(fileIDs), folderIDs: []) else { return [] }
        var pendingFolderID = Set(fileIDs.compactMap { fileBlock.filesByID[$0]?.parentFolderID })
        while !pendingFolderID.isEmpty {
            let newlyInserted = pendingFolderID.subtracting(folderIDs)
            guard !newlyInserted.isEmpty else { break }
            folderIDs.formUnion(newlyInserted)
            guard let folderBlock = try? await authority.resolveRecordsScopeWide(fileIDs: [], folderIDs: Array(newlyInserted)) else { break }
            pendingFolderID = Set(newlyInserted.compactMap { folderBlock.foldersByID[$0]?.parentFolderID })
        }
        return folderIDs
    }

    private func makeFileTreeFolderSnapshot(
        _ folder: WorkspaceFolderRecord,
        rootStandardizedPath: String,
        pageIndex: FileTreePageIndex,
        visited: inout Set<UUID>,
        renderableCodemapFileIDs: Set<UUID>,
        explicitlyIncludedManagedOnlyFileIDs: Set<UUID> = [],
        explicitlyIncludedManagedOnlyFolderIDs: Set<UUID> = []
    ) -> FileTreeFolderSnapshot? {
        guard visited.insert(folder.id).inserted else { return nil }

        let childFolders = (pageIndex.childFolderIDsByFolderID[folder.id] ?? [])
            .filter { isDiscoverableFolderID($0) || explicitlyIncludedManagedOnlyFolderIDs.contains($0) }
            .compactMap { pageIndex.foldersByID[$0] }
            .sorted { $0.name < $1.name }
        let childFiles = (pageIndex.childFileIDsByFolderID[folder.id] ?? [])
            .filter { isDiscoverableFileID($0) || explicitlyIncludedManagedOnlyFileIDs.contains($0) }
            .compactMap { pageIndex.filesByID[$0] }
            .sorted { $0.name < $1.name }

        var children: [FileTreeNodeSnapshot] = []
        children.reserveCapacity(childFolders.count + childFiles.count)
        for childFolder in childFolders {
            if let snapshot = makeFileTreeFolderSnapshot(
                childFolder,
                rootStandardizedPath: rootStandardizedPath,
                pageIndex: pageIndex,
                visited: &visited,
                renderableCodemapFileIDs: renderableCodemapFileIDs,
                explicitlyIncludedManagedOnlyFileIDs: explicitlyIncludedManagedOnlyFileIDs,
                explicitlyIncludedManagedOnlyFolderIDs: explicitlyIncludedManagedOnlyFolderIDs
            ) {
                children.append(.folder(snapshot))
            }
        }
        for file in childFiles {
            children.append(.file(FileTreeFileSnapshot(
                id: file.id,
                name: file.name,
                fileExtension: (file.name as NSString).pathExtension.isEmpty ? nil : (file.name as NSString).pathExtension,
                hasCodeMap: renderableCodemapFileIDs.contains(file.id)
            )))
        }

        return FileTreeFolderSnapshot(
            id: folder.id,
            name: folder.name,
            fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath,
            standardizedRootPath: rootStandardizedPath,
            children: children
        )
    }

    /// P4-6b: batch entry points used by the root-load bulk-chunk path (`FSItemDTO` inputs are
    /// hierarchy-ordered -- parents before children -- by that path's own contract). Each new
    /// item still costs its own discovery-mint round trip (a genuine, documented performance
    /// trade-off versus the pre-cutover single in-actor dictionary insert -- follow-up
    /// optimization, not a correctness gap: the mint-once/ancestor-creation contract is what
    /// matters here, and per-item `indexFile`/`indexFolder` already implement it correctly).
    private func indexFolders(_ items: [FSItemDTO], root: WorkspaceRootRecord) async {
        for item in items {
            await indexFolder(relativePath: item.relativePath, root: root)
        }
    }

    private func indexFiles(_ items: [FSItemDTO], root: WorkspaceRootRecord) async {
        for item in items {
            await indexFile(relativePath: item.relativePath, root: root)
        }
    }
}

enum WorkspaceAppliedIngressWaitError: Error, Equatable {
    case timedOut
}

extension WorkspaceAppliedIngressWaitError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .timedOut:
            "Workspace freshness timed out before pending file-system ingress was applied."
        }
    }
}

enum WorkspaceFileContextStoreError: Error, Equatable {
    case rootNotLoaded(UUID)
    case exactFileNamespaceMissingRoot(UUID)
    case exactFileNamespaceMissingAlias(UUID)
    case storeDeallocated
    case rootAlreadyLoadedWithDifferentConfiguration(String)
    case rootLoadInFlightWithDifferentConfiguration(String)
    case catalogMaterializationFailed(String)
}

extension WorkspaceFileContextStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .rootNotLoaded(id):
            "Workspace root is not loaded: \(id)."
        case let .exactFileNamespaceMissingRoot(id):
            "Exact file namespace does not contain workspace root: \(id)."
        case let .exactFileNamespaceMissingAlias(id):
            "Exact file namespace does not contain a canonical alias for client root: \(id)."
        case .storeDeallocated:
            "Workspace file context store was deallocated."
        case let .rootAlreadyLoadedWithDifferentConfiguration(path):
            "Workspace root is already loaded with a different configuration: \(path)."
        case let .rootLoadInFlightWithDifferentConfiguration(path):
            "Workspace root load is already in flight with a different configuration: \(path)."
        case let .catalogMaterializationFailed(message):
            message
        }
    }
}
