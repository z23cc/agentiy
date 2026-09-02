import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

class WorkspaceFileContextStoreCodemapSeamTestSupport: XCTestCase {
    func awaitCodemapGraphsReady(
        store: WorkspaceFileContextStore,
        rootIDs: Set<UUID>,
        timeout: Duration = .seconds(60)
    ) async throws -> [WorkspaceCodemapRootStatusSnapshot] {
        precondition(!rootIDs.isEmpty)
        let updates = await store.codemapRootStatusUpdates()
        return try await withThrowingTaskGroup(of: [WorkspaceCodemapRootStatusSnapshot].self) { group in
            group.addTask {
                for await update in updates {
                    try Task.checkCancellation()
                    let roots = update.roots.filter { rootIDs.contains($0.rootEpoch.rootID) }
                    if roots.count == rootIDs.count, roots.allSatisfy({ $0.availability == .ready }) {
                        return roots.sorted {
                            workspaceCodemapRootEpochPrecedes($0.rootEpoch, $1.rootEpoch)
                        }
                    }
                }
                throw CodemapStoreTestError.timedOut
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CodemapStoreTestError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CodemapStoreTestError.timedOut
            }
            return result
        }
    }

    func graphIndexPage(
        _ disposition: WorkspaceCodemapGraphIndexCatalogPageDisposition
    ) throws -> WorkspaceCodemapGraphIndexCatalogPage {
        guard case let .page(page) = disposition else {
            throw CodemapStoreTestError.expectedGraphIndexPage
        }
        return page
    }

    /// Requests a codemap artifact demand and retries through transient unavailability
    /// until the demand settles ready or a stable unavailability/timeout is reached.
    func readyArtifactDemand(
        store: WorkspaceFileContextStore,
        forFileID fileID: UUID,
        priority: CodeMapArtifactBuildPriority = .demand,
        timeout: Duration = .seconds(30),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (ticket: WorkspaceCodemapArtifactDemandTicket, ready: WorkspaceCodemapArtifactDemandReady) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastNonReadyResult: WorkspaceCodemapArtifactDemandResult?
        while clock.now < deadline {
            let initial = await store.requestCodemapArtifact(forFileID: fileID, priority: priority)
            switch initial {
            case let .pending(ticket):
                let result = try await settledResult(store: store, ticket: ticket)
                switch result {
                case let .ready(ready):
                    return (ticket, ready)
                case let .unavailable(reason) where !Self.demandUnavailableIsStable(reason):
                    lastNonReadyResult = result
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                default:
                    lastNonReadyResult = result
                    throw CodemapStoreTestError.expectedReady
                }
            case let .ready(ready):
                return (ready.ticket, ready)
            case let .unavailable(reason) where !Self.demandUnavailableIsStable(reason):
                lastNonReadyResult = initial
                try await Task.sleep(for: .milliseconds(50))
                continue
            default:
                lastNonReadyResult = initial
                throw CodemapStoreTestError.expectedReady
            }
        }
        XCTFail(
            "Timed out waiting for ready codemap artifact demand; last result = \(String(describing: lastNonReadyResult)).",
            file: file,
            line: line
        )
        throw CodemapStoreTestError.timedOut
    }

    private static func demandUnavailableIsStable(
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

    func settledResult(
        store: WorkspaceFileContextStore,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        timeout: Duration = .seconds(15)
    ) async throws -> WorkspaceCodemapArtifactDemandResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let result = await store.codemapArtifactDemandStatus(ticket)
            if case .pending = result {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            return result
        }
        throw CodemapStoreTestError.timedOut
    }
}

enum CodemapStoreTestError: Error {
    case expectedGraphIndexPage
    case expectedReady
    case timedOut
}

final class CodemapRuntimeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var runtimes: [CodeMapArtifactRuntime] = []

    func record(_ runtime: CodeMapArtifactRuntime) -> CodeMapArtifactRuntime {
        lock.withLock { runtimes.append(runtime) }
        return runtime
    }

    func snapshot() -> [CodeMapArtifactRuntime] {
        lock.withLock { runtimes }
    }
}

final class CodemapStoreFixture: @unchecked Sendable {
    let registry = WorkspaceCodemapBindingIntegrationRegistry()
    let providerAccessCount = CodemapLockedCounter()
    let runtimeFactoryCount = CodemapLockedCounter()
    let engineFactoryCount = CodemapLockedCounter()
    let manifestReadCount = CodemapLockedCounter()
    let buildCount = CodemapLockedCounter()
    let buildPriorities = CodemapLockedValues<CodeMapArtifactBuildPriority>()
    let builtSourceTexts = CodemapLockedValues<String>()
    let demandedTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()

    private let sandbox: URL
    private let runtimeTracker: CodemapRuntimeTracker
    private let runtimeProvider: CodeMapArtifactRuntimeProvider

    init(
        name: String,
        syntheticGraphArtifacts: Bool = false,
        artifactBuilder: CodeMapArtifactBuilderClient? = nil,
        artifactCoordinatorPolicy: CodeMapArtifactBuildCoordinatorPolicy = .default,
        bindingEnginePolicy: WorkspaceCodemapBindingEnginePolicy = .default,
        manifestStoreFaultAction: @escaping @Sendable (
            CodeMapRootManifestStoreFaultPoint
        ) -> CodeMapRootManifestStoreFaultAction = { _ in .proceed }
    ) throws {
        let sandbox = try Self.makeSandbox(name: name)
        let artifactRoot = try Self.makeSecureDirectory(in: sandbox, named: "artifacts")
        let registry = registry
        let runtimeFactoryCount = runtimeFactoryCount
        let engineFactoryCount = engineFactoryCount
        let manifestReadCount = manifestReadCount
        let buildCount = buildCount
        let buildPriorities = buildPriorities
        let builtSourceTexts = builtSourceTexts
        let defaultBuilder = artifactBuilder ?? CodeMapArtifactBuilderClient()
        let runtimeTracker = CodemapRuntimeTracker()
        let freshRuntimeFactory: @Sendable () throws -> CodeMapArtifactRuntime = {
            runtimeFactoryCount.increment()
            return try runtimeTracker.record(CodeMapArtifactRuntime(
                rootURL: artifactRoot,
                manifestStoreHooks: CodeMapRootManifestStoreHooks(
                    afterReadAdmission: {
                        manifestReadCount.increment()
                    },
                    faultAction: manifestStoreFaultAction
                ),
                builder: CodeMapArtifactBuilderClient(execute: { input, ownerID, priority in
                    buildCount.increment()
                    buildPriorities.append(priority)
                    if case let .decoded(source) = input.source.decodeResult {
                        builtSourceTexts.append(source.text)
                    }
                    if syntheticGraphArtifacts,
                       case let .decoded(source) = input.source.decodeResult
                    {
                        return CodeMapArtifactBuilderExecution(
                            outcome: .ready(Self.syntheticGraphArtifact(source.text)),
                            permitWaitNanoseconds: 0,
                            buildNanoseconds: 0
                        )
                    }
                    return try await defaultBuilder.execute(input, ownerID, priority)
                }),
                coordinatorPolicy: artifactCoordinatorPolicy,
                bindingIntegrationRegistry: registry,
                bindingEngineFactory: { runtime in
                    engineFactoryCount.increment()
                    return WorkspaceCodemapBindingEngine(
                        runtime: runtime,
                        capabilityService: WorkspaceCodemapGitCapabilityService(
                            namespaceSalt: Data(
                                repeating: 0x6C,
                                count: GitBlobRepositoryNamespace.saltByteCount
                            )
                        ),
                        sourceReader: registry.makeValidatedSourceReaderClient(),
                        catalogClient: registry.makeBindingCatalogClient(),
                        policy: bindingEnginePolicy
                    )
                }
            ))
        }
        runtimeProvider = CodeMapArtifactRuntimeProvider(factory: freshRuntimeFactory)
        self.sandbox = sandbox
        self.runtimeTracker = runtimeTracker
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeStore(
        codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .init { _ in
            .requiresGitPreflight
        },
        codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe = WorkspaceCodemapGitEligibilityProbe { _ in
            .eligible
        },
        codemapGraphIndexBuildRetryPolicy: WorkspaceFileContextStore.CodemapGraphIndexBuildRetryPolicy = .production,
        codemapGraphIndexBuildLaunchPolicy: WorkspaceFileContextStore.CodemapGraphIndexBuildLaunchPolicyForTesting = .enabled,
        selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
        selectionGraphQueryBudgetPolicy: WorkspaceCodemapAutomaticSelectionBudgetPolicy = .initial,
        automaticSelectionAccountingMaximum: Int = .max,
        demandRequestHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        cancellationCleanupHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        readyPublicationHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        demandResultHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket,
            WorkspaceCodemapBindingDemandResult
        ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result },
        automaticSelectionQueryHook: @escaping @Sendable (
            WorkspaceCodemapRootEpoch
        ) async -> Void = { _ in }
    ) -> WorkspaceFileContextStore {
        let providerAccessCount = providerAccessCount
        let runtimeProvider = runtimeProvider
        let demandedTickets = demandedTickets
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerAccessCount.increment()
                return try runtimeProvider.runtime()
            },
            codemapLocalGitClassificationProbe: codemapLocalGitClassificationProbe,
            codemapGitEligibilityProbe: codemapGitEligibilityProbe,
            codemapGraphIndexBuildRetryPolicy: codemapGraphIndexBuildRetryPolicy,
            codemapGraphIndexBuildLaunchPolicyForTesting: codemapGraphIndexBuildLaunchPolicy,
            selectionGraphFactory: selectionGraphFactory,
            selectionGraphQueryBudgetPolicy: selectionGraphQueryBudgetPolicy,
            automaticSelectionAccountingMaximum: automaticSelectionAccountingMaximum,
            codemapDemandRequestHook: { ticket in
                demandedTickets.append(ticket)
                await demandRequestHook(ticket)
            },
            codemapCancellationCleanupHook: cancellationCleanupHook,
            codemapReadyPublicationHook: readyPublicationHook,
            codemapDemandResultHook: demandResultHook,
            codemapAutomaticSelectionQueryHook: automaticSelectionQueryHook
        )
    }

    func runtime() throws -> CodeMapArtifactRuntime {
        try runtimeProvider.runtime()
    }

    func shutdown() async {
        for runtime in runtimeTracker.snapshot() {
            if let engine = try? runtime.bindingEngine() {
                await engine.shutdown()
            }
            await runtime.shutdown()
        }
    }

    static func makeSandbox(name: String) throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WorkspaceFileContextStoreCodemapSeamTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    private static func makeSecureDirectory(in parent: URL, named name: String) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedPath = try directory.path.withCString { pointer -> String in
            guard let resolved = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private static func syntheticGraphArtifact(_ source: String) -> CodeMapSyntaxArtifact {
        let definitions: [String]
        let references: [String]
        if source.contains("let target: Target") {
            definitions = ["Source"]
            references = ["Target"]
        } else if source.contains("protocol FirstSource") {
            definitions = ["FirstSource"]
            references = ["FirstTarget"]
        } else if source.contains("protocol SecondSource") {
            definitions = ["SecondSource"]
            references = ["SecondTarget"]
        } else if source.contains("protocol SourceProtocol") {
            definitions = ["SourceProtocol"]
            if source.contains("ForeignDefinition") {
                references = ["ForeignDefinition"]
            } else if source.contains("FirstTarget"), source.contains("SecondTarget") {
                references = ["FirstTarget", "SecondTarget"]
            } else {
                references = ["Target"]
            }
        } else if source.contains("ForeignDefinition") {
            definitions = ["ForeignDefinition"]
            references = []
        } else if source.contains("FirstTarget") {
            definitions = ["FirstTarget"]
            references = []
        } else if source.contains("SecondTarget") {
            definitions = ["SecondTarget"]
            references = []
        } else if source.contains("Target") {
            definitions = ["Target"]
            references = []
        } else {
            definitions = []
            references = []
        }
        return CodeMapSyntaxArtifact(
            imports: [],
            classes: definitions.map { ClassInfo(name: $0, methods: [], properties: []) },
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: references
        )
    }
}

final class CodemapLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }

    func incrementAndGet() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}

final class CodemapLockedValues<Value: Sendable>: @unchecked Sendable {
    private let condition = AsyncTestCondition<[Value]>([])

    var values: [Value] {
        condition.snapshot()
    }

    func append(_ value: Value) {
        condition.update { $0.append(value) }
    }

    func waitUntilCount(
        _ expectedCount: Int,
        timeout: TimeInterval = TestFenceDefaults.enterWait
    ) async throws {
        try await condition.waitUntil(
            "codemap recorded value count \(expectedCount)",
            timeout: timeout
        ) { $0.count >= expectedCount }
    }
}
