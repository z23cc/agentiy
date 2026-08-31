import Foundation

package enum DomainRuntimeMode: String, CaseIterable, Sendable {
    case app
    case standalone
}

package struct DomainRuntimeConfiguration: Sendable {
    package let mode: DomainRuntimeMode
    package let profileIdentifier: String
    package let storageDirectory: URL
    package let workspaceStorageDirectory: URL
    package let eventDirectory: URL
    package let temporaryDirectory: URL
    package let legacyRuntimeDefaults: [String: Data]
    package let externalReloadInterval: Duration?
    package let externalReloadMaximumInterval: Duration
    package let metrics: DomainRuntimeMetricsSink
    package let hostDrainTimeout: Duration
    /// When set, startup must obtain a verified Rust catalog before registrations can proceed.
    package let catalogProvider: (@Sendable () async throws -> MCPDomainCatalogSnapshot)?
    /// Optional Rust-backed operation resolver used by the host's final invocation fence.
    package let operationResolver: MCPDomainToolOperationResolver?

    package init(
        mode: DomainRuntimeMode,
        profileIdentifier: String,
        storageDirectory: URL,
        workspaceStorageDirectory: URL? = nil,
        eventDirectory: URL,
        temporaryDirectory: URL,
        legacyRuntimeDefaults: [String: Data] = [:],
        externalReloadInterval: Duration? = .seconds(1),
        externalReloadMaximumInterval: Duration = .seconds(30),
        metrics: DomainRuntimeMetricsSink = .disabled,
        hostDrainTimeout: Duration = .seconds(5),
        catalogProvider: (@Sendable () async throws -> MCPDomainCatalogSnapshot)? = nil,
        operationResolver: MCPDomainToolOperationResolver? = nil
    ) {
        self.mode = mode
        self.profileIdentifier = profileIdentifier
        self.storageDirectory = storageDirectory
        self.workspaceStorageDirectory = workspaceStorageDirectory
            ?? storageDirectory.appendingPathComponent("Workspaces", isDirectory: true)
        self.eventDirectory = eventDirectory
        self.temporaryDirectory = temporaryDirectory
        self.legacyRuntimeDefaults = legacyRuntimeDefaults
        self.externalReloadInterval = externalReloadInterval
        self.externalReloadMaximumInterval = externalReloadMaximumInterval
        self.metrics = metrics
        self.hostDrainTimeout = hostDrainTimeout
        self.catalogProvider = catalogProvider
        self.operationResolver = operationResolver
    }
}

package struct DomainRuntimeIdentity: Hashable, Sendable {
    package let runtimeID: UUID
    package let lifecycleGeneration: UInt64
    package let processID: Int32
    package let mode: DomainRuntimeMode
    package let createdAt: Date

    package init(
        runtimeID: UUID,
        lifecycleGeneration: UInt64,
        processID: Int32,
        mode: DomainRuntimeMode,
        createdAt: Date
    ) {
        self.runtimeID = runtimeID
        self.lifecycleGeneration = lifecycleGeneration
        self.processID = processID
        self.mode = mode
        self.createdAt = createdAt
    }
}

package enum DomainRuntimeLifecycle: String, CaseIterable, Sendable {
    case created
    case starting
    case ready
    case draining
    case stopped
    case degraded
}

package struct DomainRuntimeSnapshot: Sendable {
    package let identity: DomainRuntimeIdentity
    package let lifecycle: DomainRuntimeLifecycle
    package let publicationSequence: UInt64
    package let catalogRevision: UInt64
    package let workspacePublicationSequence: UInt64
    package let workspaceCatalogRevision: UInt64
    package let workspaceHealth: DomainAuthorityHealth
    package let workspaceMutationAccess: DomainWorkspaceMutationAccessSnapshot
    package let routingRevision: UInt64
    package let agentSessionPersistenceHealth: DomainAgentSessionPersistenceHealth
    package let agentSessionEventSequence: UInt64
    package let agentSessionEventTailCount: Int
    package let activityPublicationSequence: UInt64
    package let activeActivityCount: Int
    package let recentTerminalActivityCount: Int
    package let hostLifecycle: MCPDomainHostLifecycle
    package let activeHostInvocationCount: Int
}

package struct DomainShutdownResult: Sendable {
    package let identity: DomainRuntimeIdentity
    package let previousLifecycle: DomainRuntimeLifecycle
    package let finalLifecycle: DomainRuntimeLifecycle
}

package enum DomainRuntimeLifecycleError: Error, Equatable, Sendable {
    case stoppedRuntimeCannotRestart
}

package actor MCPDomainRuntime {
    package nonisolated let identity: DomainRuntimeIdentity
    package nonisolated let configuration: DomainRuntimeConfiguration
    package nonisolated let toolRegistry: MCPDomainToolRegistry
    package nonisolated let domainHost: MCPDomainHost
    package nonisolated let persistenceCoordinator: DomainPersistenceCoordinator
    package nonisolated let workspaceStore: DomainWorkspaceStore
    package nonisolated let contextStore: DomainContextStore
    package nonisolated let routingCoordinator: DomainRoutingCoordinator
    package nonisolated let standaloneScopeCoordinator: DomainStandaloneScopeCoordinator
    package nonisolated let readSideEffectCoordinator: DomainReadSideEffectCoordinator
    package nonisolated let mutationPolicyStore: DomainMutationPolicyStore
    package nonisolated let mutationApprovalBroker: DomainMutationApprovalBroker
    package nonisolated let mutationJournal: DomainMutationJournal
    package nonisolated let protectedMutationProvider: MCPDomainProtectedMutationToolProvider
    /// Canonical durable/lifecycle authority for agent sessions. `agentSessionStore` below is
    /// retained as a source-compatible run-control alias for MCP/provider adapters.
    package nonisolated let agentSessionAuthority: DomainAgentSessionAuthority
    package nonisolated var agentSessionStore: DomainAgentSessionAuthority {
        agentSessionAuthority
    }
    package nonisolated let agentWorktreeBindingStore: DomainAgentWorktreeBindingStore
    package nonisolated let interactionBroker: DomainInteractionBroker
    package nonisolated let activityCenter: DomainActivityCenter
    package nonisolated let credentialEnvelopeStore: DomainCredentialEnvelopeStore
    package nonisolated let longRunningToolProvider: MCPDomainLongRunningToolProvider
    private nonisolated let workspaceMutationAccess: DomainWorkspaceMutationAccess
    private let workspaceAuthority: DomainWorkspaceContextAuthority
    private var lifecycle: DomainRuntimeLifecycle = .created
    private var publicationSequence: UInt64 = 0
    private var startTask: Task<Void, Never>?
    private var externalReloadTask: Task<Void, Never>?
    private var workspaceMutationAccessRecoveryTask: Task<Void, Never>?

    package init(
        configuration: DomainRuntimeConfiguration,
        runtimeID: UUID = UUID(),
        lifecycleGeneration: UInt64 = 1,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        createdAt: Date = Date(),
        registryID: UUID = UUID(),
        workspaceCommandIdentityResolver: DomainWorkspaceCommandIdentityResolver? = nil,
        prepareChildLaunch: @escaping MCPDomainLongRunningToolProvider.PrepareChildLaunch = { _, _, _ in nil }
    ) {
        self.configuration = configuration
        let runtimeIdentity = DomainRuntimeIdentity(
            runtimeID: runtimeID,
            lifecycleGeneration: lifecycleGeneration,
            processID: processID,
            mode: configuration.mode,
            createdAt: createdAt
        )
        identity = runtimeIdentity
        toolRegistry = MCPDomainToolRegistry(
            registryID: registryID,
            requiresRuntimeCatalog: configuration.catalogProvider != nil
        )
        let workspaceAuthorityLease = DomainWorkspaceAuthorityLease(
            configuration: configuration,
            identity: runtimeIdentity
        )
        let workspaceMutationAccess = DomainWorkspaceMutationAccess(
            lease: workspaceAuthorityLease
        )
        self.workspaceMutationAccess = workspaceMutationAccess
        let persistence = DomainPersistenceCoordinator(
            configuration: configuration,
            identity: runtimeIdentity,
            workspaceAuthorityScope: workspaceAuthorityLease.scope,
            workspaceMutationPermitRegistry: workspaceMutationAccess.permitRegistry
        )
        persistenceCoordinator = persistence
        let authority = DomainWorkspaceContextAuthority(
            identity: runtimeIdentity,
            persistence: persistence,
            mutationAccess: workspaceMutationAccess,
            metrics: configuration.metrics,
            commandIdentityResolver: workspaceCommandIdentityResolver
        )
        workspaceAuthority = authority
        let workspaceStore = DomainWorkspaceStore(authority: authority)
        let contextStore = DomainContextStore(authority: authority)
        self.workspaceStore = workspaceStore
        self.contextStore = contextStore
        let routingCoordinator = DomainRoutingCoordinator(
            identity: runtimeIdentity,
            contextStore: contextStore,
            metrics: configuration.metrics
        )
        self.routingCoordinator = routingCoordinator
        standaloneScopeCoordinator = DomainStandaloneScopeCoordinator(
            identity: runtimeIdentity,
            workspaceStore: workspaceStore,
            contextStore: contextStore,
            routingCoordinator: routingCoordinator
        )
        domainHost = MCPDomainHost(
            identity: runtimeIdentity,
            registry: toolRegistry,
            routingCoordinator: routingCoordinator,
            metrics: configuration.metrics,
            requiresRuntimeCatalog: configuration.catalogProvider != nil,
            operationResolver: configuration.operationResolver
        )
        readSideEffectCoordinator = DomainReadSideEffectCoordinator(identity: runtimeIdentity)
        let mutationPolicyStore = DomainMutationPolicyStore(
            persistence: persistence,
            identity: runtimeIdentity,
            profileIdentifier: configuration.profileIdentifier
        )
        self.mutationPolicyStore = mutationPolicyStore
        mutationApprovalBroker = DomainMutationApprovalBroker()
        let mutationJournal = DomainMutationJournal(
            persistence: persistence,
            profileIdentifier: configuration.profileIdentifier,
            createdAt: createdAt
        )
        self.mutationJournal = mutationJournal
        protectedMutationProvider = MCPDomainProtectedMutationToolProvider(
            policyStore: mutationPolicyStore,
            journal: mutationJournal
        )
        agentSessionAuthority = DomainAgentSessionAuthority(
            identity: runtimeIdentity,
            persistence: persistence,
            profileIdentifier: configuration.profileIdentifier
        )
        agentWorktreeBindingStore = DomainAgentWorktreeBindingStore(
            persistence: persistence,
            profileIdentifier: configuration.profileIdentifier
        )
        let interactionBroker = DomainInteractionBroker()
        let activityCenter = DomainActivityCenter(identity: runtimeIdentity)
        let credentialEnvelopeStore = DomainCredentialEnvelopeStore(identity: runtimeIdentity)
        self.interactionBroker = interactionBroker
        self.activityCenter = activityCenter
        self.credentialEnvelopeStore = credentialEnvelopeStore
        longRunningToolProvider = MCPDomainLongRunningToolProvider(
            identity: runtimeIdentity,
            policyStore: mutationPolicyStore,
            interactionBroker: interactionBroker,
            activityCenter: activityCenter,
            prepareChildLaunch: prepareChildLaunch
        )
    }

    package func start() async throws {
        switch lifecycle {
        case .created:
            lifecycle = .starting
            publishSnapshot()
            startTask = Task { [weak self] in
                await self?.performStart()
            }
        case .starting:
            break
        case .ready, .degraded:
            return
        case .draining, .stopped:
            throw DomainRuntimeLifecycleError.stoppedRuntimeCannotRestart
        }
        let task = startTask
        await task?.value
    }

    private func performStart() async {
        guard lifecycle == .starting, !Task.isCancelled else { return }
        if let catalogProvider = configuration.catalogProvider {
            do {
                let catalog = try await catalogProvider()
                // Prepare every consumer before committing either side. The shared process
                // facade is installed only after both actors have accepted the exact digest;
                // any later failure rolls the actor-local state back before degradation escapes.
                try await toolRegistry.validateCatalog(catalog)
                try await domainHost.validateCatalog(catalog)
                try await toolRegistry.installCatalog(catalog)
                do {
                    try await domainHost.installCatalog(catalog)
                    guard MCPDomainToolCatalog.installRuntimeCatalog(catalog) else {
                        throw MCPDomainToolRegistryError.catalogUnavailable
                    }
                } catch {
                    _ = await domainHost.uninstallCatalog(expectedDigest: catalog.digest)
                    _ = await toolRegistry.uninstallCatalog(expectedDigest: catalog.digest)
                    _ = MCPDomainToolCatalog.clearRuntimeCatalog(expectedDigest: catalog.digest)
                    throw error
                }
            } catch {
                // A production runtime without a verified Rust catalog is not allowed to
                // register or advertise tools. Keep the lifecycle degraded and fail closed.
                startTask = nil
                lifecycle = .degraded
                publishSnapshot()
                return
            }
        }
        await workspaceAuthority.bootstrap()
        guard lifecycle == .starting, !Task.isCancelled else { return }
        await mutationPolicyStore.bootstrap()
        guard lifecycle == .starting, !Task.isCancelled else { return }
        await agentSessionAuthority.bootstrap()
        guard lifecycle == .starting, !Task.isCancelled else { return }
        await agentWorktreeBindingStore.bootstrap()
        guard lifecycle == .starting, !Task.isCancelled else { return }
        let mutationAccess = await workspaceAuthority.activateMutationAccess()
        guard lifecycle == .starting, !Task.isCancelled else { return }
        let workspaceSnapshot = await workspaceAuthority.snapshot()
        let agentSessions = await agentSessionAuthority.snapshot()
        guard lifecycle == .starting, !Task.isCancelled else { return }
        startTask = nil
        lifecycle = workspaceSnapshot.health.acceptsMutations
            && mutationAccess.acceptsMutations
            && agentSessions.persistenceHealth == .ready
            ? .ready
            : .degraded
        publishSnapshot()
        startExternalReloadPollingIfNeeded()
        if !mutationAccess.acceptsMutations {
            startWorkspaceMutationAccessRecoveryIfNeeded()
        }
    }

    package func shutdown() async -> DomainShutdownResult {
        let previousLifecycle = lifecycle
        guard lifecycle != .stopped else {
            return DomainShutdownResult(
                identity: identity,
                previousLifecycle: previousLifecycle,
                finalLifecycle: .stopped
            )
        }
        lifecycle = .draining
        let pendingStart = startTask
        let pendingExternalReload = externalReloadTask
        let pendingMutationAccessRecovery = workspaceMutationAccessRecoveryTask
        startTask = nil
        externalReloadTask = nil
        workspaceMutationAccessRecoveryTask = nil
        pendingStart?.cancel()
        pendingExternalReload?.cancel()
        pendingMutationAccessRecovery?.cancel()
        publishSnapshot()
        await pendingStart?.value
        await pendingExternalReload?.value
        await pendingMutationAccessRecovery?.value
        await workspaceAuthority.beginMutationAccessDrain()
        await workspaceMutationAccess.waitForDrain()
        _ = await domainHost.drain(timeout: configuration.hostDrainTimeout)
        if let catalogDigest = await domainHost.runtimeCatalogSnapshot()?.digest {
            _ = MCPDomainToolCatalog.clearRuntimeCatalog(expectedDigest: catalogDigest)
        }
        await mutationApprovalBroker.shutdown()
        await interactionBroker.shutdown()
        _ = await agentSessionAuthority.shutdown()
        await activityCenter.shutdown()
        await credentialEnvelopeStore.shutdown()
        await readSideEffectCoordinator.shutdown()
        await routingCoordinator.shutdown()
        await workspaceAuthority.finishMutationAccessDrainAndRelease()
        lifecycle = .stopped
        publishSnapshot()
        return DomainShutdownResult(
            identity: identity,
            previousLifecycle: previousLifecycle,
            finalLifecycle: .stopped
        )
    }

    package func snapshot() async -> DomainRuntimeSnapshot {
        let catalog = await toolRegistry.snapshot()
        let workspaces = await workspaceAuthority.snapshot()
        let workspaceMutationAccess = await workspaceAuthority.mutationAccessStateSnapshot()
        let routing = await routingCoordinator.snapshot()
        let agentSessions = await agentSessionAuthority.snapshot()
        let activities = await activityCenter.snapshot()
        let host = await domainHost.snapshot()
        if lifecycle == .ready || lifecycle == .degraded {
            let next = resolvedLifecycle(
                workspaceHealth: workspaces.health,
                agentPersistenceHealth: agentSessions.persistenceHealth
            )
            if next != lifecycle {
                lifecycle = next
                publishSnapshot()
            }
        }
        return DomainRuntimeSnapshot(
            identity: identity,
            lifecycle: lifecycle,
            publicationSequence: publicationSequence,
            catalogRevision: catalog.revision,
            workspacePublicationSequence: workspaces.publicationSequence,
            workspaceCatalogRevision: workspaces.catalogRevision,
            workspaceHealth: workspaces.health,
            workspaceMutationAccess: workspaceMutationAccess,
            routingRevision: routing.revision,
            agentSessionPersistenceHealth: agentSessions.persistenceHealth,
            agentSessionEventSequence: await agentSessionAuthority.currentSessionEventSequence(),
            agentSessionEventTailCount: await agentSessionAuthority.sessionEventTailCount(),
            activityPublicationSequence: activities.publicationSequence,
            activeActivityCount: activities.active.count,
            recentTerminalActivityCount: activities.recentTerminal.count,
            hostLifecycle: host.lifecycle,
            activeHostInvocationCount: host.activeInvocationCount
        )
    }

    private func startExternalReloadPollingIfNeeded() {
        guard externalReloadTask == nil,
              let minimumInterval = configuration.externalReloadInterval
        else { return }
        let maximumInterval = max(
            minimumInterval,
            configuration.externalReloadMaximumInterval
        )
        externalReloadTask = Task { [weak self] in
            var interval = minimumInterval
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                let activity = await workspaceStore.reloadExternalChanges()
                await synchronizeLifecycleWithWorkspaceHealth()
                interval = switch activity {
                case .changed:
                    minimumInterval
                case .unchanged, .recoveryPending:
                    min(interval * 2, maximumInterval)
                }
            }
        }
    }

    private func startWorkspaceMutationAccessRecoveryIfNeeded() {
        guard workspaceMutationAccessRecoveryTask == nil,
              lifecycle == .ready || lifecycle == .degraded
        else { return }
        workspaceMutationAccessRecoveryTask = Task { [weak self] in
            await self?.runWorkspaceMutationAccessRecovery()
        }
    }

    private func runWorkspaceMutationAccessRecovery() async {
        defer { workspaceMutationAccessRecoveryTask = nil }
        let minimumInterval: Duration = .milliseconds(100)
        let maximumInterval: Duration = .seconds(30)
        var retryInterval = minimumInterval
        while !Task.isCancelled {
            let current = await workspaceAuthority.mutationAccessStateSnapshot()
            guard !current.acceptsMutations else { return }
            do {
                try await Task.sleep(for: retryInterval)
            } catch {
                return
            }
            guard !Task.isCancelled, lifecycle == .ready || lifecycle == .degraded else { return }
            let next = await workspaceAuthority.activateMutationAccess()
            await synchronizeLifecycleWithWorkspaceHealth()
            if next.acceptsMutations {
                retryInterval = minimumInterval
            } else {
                retryInterval = min(retryInterval * 2, maximumInterval)
            }
        }
    }

    private func synchronizeLifecycleWithWorkspaceHealth() async {
        guard lifecycle == .ready || lifecycle == .degraded else { return }
        let snapshot = await workspaceAuthority.snapshot()
        let agentSessions = await agentSessionAuthority.snapshot()
        let next = resolvedLifecycle(
            workspaceHealth: snapshot.health,
            agentPersistenceHealth: agentSessions.persistenceHealth
        )
        guard next != lifecycle else { return }
        lifecycle = next
        publishSnapshot()
    }

    private func resolvedLifecycle(
        workspaceHealth: DomainAuthorityHealth,
        agentPersistenceHealth: DomainAgentSessionPersistenceHealth
    ) -> DomainRuntimeLifecycle {
        workspaceHealth.acceptsMutations && agentPersistenceHealth == .ready ? .ready : .degraded
    }

    private func publishSnapshot() {
        publicationSequence &+= 1
    }
}
