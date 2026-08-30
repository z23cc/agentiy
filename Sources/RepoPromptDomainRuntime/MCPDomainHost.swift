import Foundation
import MCP

package enum MCPDomainHostLifecycle: String, CaseIterable, Sendable {
    case accepting
    case draining
    case drained
}

package enum MCPDomainHostError: Error, Equatable, Sendable {
    case draining
    case duplicateInvocationID(UUID)
    case unknownTool(String)
    case scopeUnavailable(toolName: String, scope: MCPDomainToolRegistrationScope)
    case staleRegistration(toolName: String)
    case runtimeGenerationMismatch
    case connectionRegistrationInvalid
    case catalogUnavailable
    case invalidCatalogLimits
    case invalidOperation(toolName: String)
    case operationResolverUnavailable
}

package typealias MCPDomainToolOperationResolver = @Sendable (
    String,
    MCPDomainToolOperationInput
) async throws -> MCPDomainToolOperationIdentity

package struct MCPDomainHostResolution: Sendable {
    package let toolName: String
    package let scope: MCPDomainToolRegistrationScope
    package let registrationHandle: MCPDomainToolRegistrationHandle
    package let definition: MCPDomainToolDefinition

    package init(
        toolName: String,
        scope: MCPDomainToolRegistrationScope,
        registrationHandle: MCPDomainToolRegistrationHandle,
        definition: MCPDomainToolDefinition
    ) {
        self.toolName = toolName
        self.scope = scope
        self.registrationHandle = registrationHandle
        self.definition = definition
    }
}

package struct MCPDomainAdmittedContext: Equatable, Sendable {
    package let connectionID: UUID
    package let windowID: Int
    package let workspaceID: UUID
    package let contextID: UUID

    package init(
        connectionID: UUID,
        windowID: Int,
        workspaceID: UUID,
        contextID: UUID
    ) {
        self.connectionID = connectionID
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.contextID = contextID
    }
}

package enum MCPDomainAdmittedContextValues {
    @TaskLocal package static var current: MCPDomainAdmittedContext?
}

package struct MCPDomainHostInvocation: Sendable {
    package let invocationID: UUID
    package let connectionID: UUID
    package let resolution: MCPDomainHostResolution
    package let arguments: [String: Value]
    package let securityContext: DomainToolInvocationSecurityContext
    package let admittedContext: MCPDomainAdmittedContext?
    package let submittedAt: ContinuousClock.Instant

    package init(
        invocationID: UUID,
        connectionID: UUID,
        resolution: MCPDomainHostResolution,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext,
        admittedContext: MCPDomainAdmittedContext? = nil,
        submittedAt: ContinuousClock.Instant = ContinuousClock().now
    ) {
        precondition(admittedContext == nil || admittedContext?.connectionID == connectionID)
        self.invocationID = invocationID
        self.connectionID = connectionID
        self.resolution = resolution
        self.arguments = arguments
        self.securityContext = securityContext
        self.admittedContext = admittedContext
        self.submittedAt = submittedAt
    }
}

package struct MCPDomainHostSnapshot: Equatable, Sendable {
    package let lifecycle: MCPDomainHostLifecycle
    package let catalogDigest: String?
    package let activeInvocationCount: Int
    package let connectionsWithActiveInvocationsCount: Int
    package let activeResourceAdmissionLeaseCount: Int
    package let resourceAdmissionWaiterCount: Int
    package let terminalConnectionFenceCount: Int
}

package struct MCPDomainHostDrainResult: Equatable, Sendable {
    package let settledInvocationCount: Int
    package let detachedInvocationCount: Int
    package let deadlineExpired: Bool
    package let callerCancelled: Bool
}

/// Protocol-neutral owner for catalog resolution and exact domain-binding invocation.
/// Transports and the app presentation shell resolve routing/admission before entry;
/// this actor owns registry-generation fencing, invocation cancellation, and drain.
package actor MCPDomainHost {
    private struct ActiveInvocation {
        let connectionID: UUID
        let connectionGeneration: UInt64
        let task: Task<Value, Error>
    }

    private enum ResourceAdmissionKind: Hashable {
        case exclusiveApplication
        case exclusiveWindow
        case smallRead
        case fileRead
        case repository
    }

    private struct RequestProgressRecord {
        let handle: MCPDomainRequestProgressHandle
        let connectionGeneration: UInt64
        let state: MCPRequestProgressState
    }

    package nonisolated let identity: DomainRuntimeIdentity
    package nonisolated let registry: MCPDomainToolRegistry
    package nonisolated let routingCoordinator: DomainRoutingCoordinator

    private let metrics: DomainRuntimeMetricsSink
    private let beforeFinalAdmission: @Sendable () async -> Void
    private let requiresRuntimeCatalog: Bool
    private let operationResolver: MCPDomainToolOperationResolver?
    private var runtimeCatalog: MCPDomainCatalogSnapshot?
    private var resourceAdmissionControllers: [ResourceAdmissionKind: MCPDomainToolResourceAdmissionController]
    private var repositoryAdmissionCoordinator: MCPDomainRepositoryAdmissionCoordinator?
    private static func makeFallbackResourceAdmissionControllers() -> [ResourceAdmissionKind: MCPDomainToolResourceAdmissionController] {
        [
            .exclusiveApplication: MCPDomainToolResourceAdmissionController(
                limit: MCPDomainToolAdmissionLimits.exclusiveConnection
            ),
            .exclusiveWindow: MCPDomainToolResourceAdmissionController(
                limit: MCPDomainToolAdmissionLimits.exclusiveConnection
            ),
            .smallRead: MCPDomainToolResourceAdmissionController(
                limit: MCPDomainToolAdmissionLimits.smallReadPerWindow
            ),
            .fileRead: MCPDomainToolResourceAdmissionController(
                limit: MCPDomainToolAdmissionLimits.fileReadPerWindow
            )
        ]
    }

    private var lifecycle: MCPDomainHostLifecycle = .accepting
    private var pendingInvocationIDs: Set<UUID> = []
    private var activeInvocations: [UUID: ActiveInvocation] = [:]
    private var invocationIDsByConnection: [UUID: Set<UUID>] = [:]
    private var requestProgressByStateID: [UUID: RequestProgressRecord] = [:]
    private var terminalConnectionGenerationByID: [UUID: UInt64] = [:]
    private var releasedConnectionGenerationByID: [UUID: UInt64] = [:]

    package init(
        identity: DomainRuntimeIdentity,
        registry: MCPDomainToolRegistry,
        routingCoordinator: DomainRoutingCoordinator,
        metrics: DomainRuntimeMetricsSink = .disabled,
        beforeFinalAdmission: @escaping @Sendable () async -> Void = {},
        requiresRuntimeCatalog: Bool = false,
        operationResolver: MCPDomainToolOperationResolver? = nil
    ) {
        self.identity = identity
        self.registry = registry
        self.routingCoordinator = routingCoordinator
        self.metrics = metrics
        self.beforeFinalAdmission = beforeFinalAdmission
        self.requiresRuntimeCatalog = requiresRuntimeCatalog
        self.operationResolver = operationResolver
        resourceAdmissionControllers = requiresRuntimeCatalog
            ? [:]
            : Self.makeFallbackResourceAdmissionControllers()
        repositoryAdmissionCoordinator = requiresRuntimeCatalog
            ? nil
            : MCPDomainRepositoryAdmissionCoordinator(
                limit: MCPDomainToolAdmissionLimits.gitReadPerRepository
            )
    }

    /// Validates the verified Rust catalog without mutating host state. Runtime composition uses
    /// this before committing the same immutable snapshot to registry and host.
    package func validateCatalog(_ catalog: MCPDomainCatalogSnapshot) throws {
        guard runtimeCatalog == nil,
              lifecycle == .accepting,
              pendingInvocationIDs.isEmpty,
              activeInvocations.isEmpty,
              resourceAdmissionControllers.values.allSatisfy({
                  let snapshot = $0.snapshot()
                  return snapshot.activeLeaseCount == 0 && snapshot.waiterCount == 0
              }),
              repositoryAdmissionCoordinator == nil
                  || repositoryAdmissionCoordinator?.snapshot().activeLeaseCount == 0,
              repositoryAdmissionCoordinator == nil
                  || repositoryAdmissionCoordinator?.snapshot().waiterCount == 0
        else {
            throw MCPDomainHostError.catalogUnavailable
        }
        _ = try Self.makeResourceAdmissionControllers(from: catalog)
        _ = try Self.makeRepositoryAdmissionLimit(from: catalog)
    }

    /// Commits a catalog after validation. Resource lease controllers are rebuilt from the exact
    /// snapshot limits, so the host never silently uses a stale Swift capacity.
    package func installCatalog(_ catalog: MCPDomainCatalogSnapshot) throws {
        try validateCatalog(catalog)
        let controllers = try Self.makeResourceAdmissionControllers(from: catalog)
        let repositoryLimit = try Self.makeRepositoryAdmissionLimit(from: catalog)
        runtimeCatalog = catalog
        resourceAdmissionControllers = controllers
        repositoryAdmissionCoordinator = MCPDomainRepositoryAdmissionCoordinator(
            limit: repositoryLimit,
            catalogDigest: catalog.digest
        )
    }

    package func uninstallCatalog(expectedDigest: String) -> Bool {
        guard runtimeCatalog?.digest == expectedDigest,
              lifecycle == .accepting,
              pendingInvocationIDs.isEmpty,
              activeInvocations.isEmpty,
              resourceAdmissionControllers.values.allSatisfy({
                  let snapshot = $0.snapshot()
                  return snapshot.activeLeaseCount == 0 && snapshot.waiterCount == 0
              }),
              repositoryAdmissionCoordinator == nil
                  || repositoryAdmissionCoordinator?.snapshot().activeLeaseCount == 0,
              repositoryAdmissionCoordinator == nil
                  || repositoryAdmissionCoordinator?.snapshot().waiterCount == 0
        else { return false }
        runtimeCatalog = nil
        resourceAdmissionControllers = requiresRuntimeCatalog
            ? [:]
            : Self.makeFallbackResourceAdmissionControllers()
        repositoryAdmissionCoordinator = requiresRuntimeCatalog
            ? nil
            : MCPDomainRepositoryAdmissionCoordinator(
                limit: MCPDomainToolAdmissionLimits.gitReadPerRepository
            )
        return true
    }

    package func runtimeCatalogSnapshot() -> MCPDomainCatalogSnapshot? {
        runtimeCatalog
    }

    package func catalogForPolicy() -> MCPDomainCatalogSnapshot? {
        runtimeCatalog
    }

    /// Returns the installed catalog entry for a transport adapter without exposing a
    /// process-global Swift catalog fallback to production callers.
    package func catalogEntry(named toolName: String) -> MCPDomainToolCatalogEntry? {
        runtimeCatalog?.entry(named: toolName)
            ?? (requiresRuntimeCatalog ? nil : MCPDomainToolCatalog.entry(named: toolName))
    }

    package func admissionClass(for toolName: String) -> MCPToolAdmissionClass? {
        catalogEntry(named: toolName)?.admissionClass
    }

    package func registrationScope(
        for toolName: String,
        windowID: Int?
    ) -> MCPDomainToolRegistrationScope? {
        guard let entry = catalogEntry(named: toolName) else { return nil }
        switch entry.scope {
        case .application:
            return .application
        case .window:
            return windowID.map(MCPDomainToolRegistrationScope.window)
        case .standalone:
            return nil
        }
    }

    /// Resolves and validates an operation against the installed Rust catalog. A configured
    /// resolver is authoritative in production; fixture hosts use the immutable catalog
    /// projection, which is still sourced from the same canonical Rust artifact.
    package func resolveOperation(
        toolName: String,
        arguments: [String: Value]
    ) async throws -> MCPDomainToolOperationIdentity {
        guard let entry = catalogEntry(named: toolName) else {
            throw MCPDomainHostError.unknownTool(toolName)
        }
        guard let operationPolicy = entry.operationPolicy else {
            return MCPDomainToolOperationIdentity(
                canonicalTool: entry.name,
                normalizedOperation: MCPDomainToolOperationIdentity.callOperation
            )
        }
        let input: MCPDomainToolOperationInput
        if let raw = arguments[operationPolicy.argumentKey] {
            guard let value = raw.stringValue else {
                throw MCPDomainHostError.invalidOperation(toolName: toolName)
            }
            input = .value(value)
        } else {
            input = .missing
        }
        let identity: MCPDomainToolOperationIdentity
        guard operationResolver != nil || !requiresRuntimeCatalog else {
            throw MCPDomainHostError.operationResolverUnavailable
        }
        if let operationResolver {
            do {
                identity = try await operationResolver(toolName, input)
            } catch {
                throw MCPDomainHostError.operationResolverUnavailable
            }
        } else {
            identity = MCPDomainToolOperationIdentity(
                canonicalTool: entry.name,
                normalizedOperation: operationPolicy.normalizedOperation(for: input)
            )
        }
        guard identity.canonicalTool == entry.name,
              identity.normalizedOperation != MCPDomainToolOperationIdentity.unknownOperation
        else {
            throw MCPDomainHostError.invalidOperation(toolName: toolName)
        }
        return identity
    }

    package func validateOperation(
        toolName: String,
        arguments: [String: Value]
    ) async throws {
        _ = try await resolveOperation(toolName: toolName, arguments: arguments)
    }

    package var requiresRuntimeCatalogForPolicy: Bool {
        requiresRuntimeCatalog
    }

    private static func makeResourceAdmissionControllers(
        from catalog: MCPDomainCatalogSnapshot
    ) throws -> [ResourceAdmissionKind: MCPDomainToolResourceAdmissionController] {
        func limit(
            admissionClass: MCPToolAdmissionClass,
            resourceScope: MCPDomainToolResourceLimitScope
        ) throws -> Int {
            let limits = catalog.entries.compactMap { entry -> Int? in
                guard entry.admissionClass == admissionClass,
                      let configured = catalog.configuredLimits(for: entry.name),
                      configured.resourceScope == resourceScope
                else { return nil }
                return configured.resourceLease
            }
            guard let first = limits.first,
                  first > 0,
                  limits.allSatisfy({ $0 == first })
            else {
                throw MCPDomainHostError.invalidCatalogLimits
            }
            return first
        }

        return try [
            .exclusiveApplication: MCPDomainToolResourceAdmissionController(
                limit: limit(admissionClass: .exclusive, resourceScope: .application)
            ),
            .exclusiveWindow: MCPDomainToolResourceAdmissionController(
                limit: limit(admissionClass: .exclusive, resourceScope: .window)
            ),
            .smallRead: MCPDomainToolResourceAdmissionController(
                limit: limit(admissionClass: .smallRead, resourceScope: .window)
            ),
            .fileRead: MCPDomainToolResourceAdmissionController(
                limit: limit(admissionClass: .fileRead, resourceScope: .window)
            ),
        ]
    }

    private static func makeRepositoryAdmissionLimit(
        from catalog: MCPDomainCatalogSnapshot
    ) throws -> Int {
        let limits = catalog.entries.compactMap { entry -> Int? in
            guard entry.admissionClass == .gitRead,
                  let configured = catalog.configuredLimits(for: entry.name),
                  configured.resourceScope == .repository
            else { return nil }
            return configured.resourceLease
        }
        guard let first = limits.first,
              first > 0,
              limits.allSatisfy({ $0 == first })
        else {
            throw MCPDomainHostError.invalidCatalogLimits
        }
        return first
    }

    package func catalogSnapshot() async -> MCPDomainToolCatalogSnapshot {
        await registry.snapshot()
    }

    package func resolve(
        toolName: String,
        scope: MCPDomainToolRegistrationScope
    ) async throws -> MCPDomainHostResolution {
        guard !requiresRuntimeCatalog || runtimeCatalog != nil else {
            throw MCPDomainHostError.catalogUnavailable
        }
        guard (runtimeCatalog?.entry(named: toolName)
            ?? (requiresRuntimeCatalog ? nil : MCPDomainToolCatalog.entry(named: toolName))) != nil else {
            throw MCPDomainHostError.unknownTool(toolName)
        }
        guard let resolved = await registry.resolve(toolName: toolName, scope: scope) else {
            throw MCPDomainHostError.scopeUnavailable(toolName: toolName, scope: scope)
        }
        return makeResolution(resolved)
    }

    package func resolveUniqueWindowTool(toolName: String) async throws -> MCPDomainHostResolution? {
        guard !requiresRuntimeCatalog || runtimeCatalog != nil else {
            throw MCPDomainHostError.catalogUnavailable
        }
        guard (runtimeCatalog?.entry(named: toolName)
            ?? (requiresRuntimeCatalog ? nil : MCPDomainToolCatalog.entry(named: toolName))) != nil else {
            throw MCPDomainHostError.unknownTool(toolName)
        }
        guard let resolved = await registry.resolveUniqueWindowTool(toolName: toolName) else {
            return nil
        }
        return makeResolution(resolved)
    }

    package func invoke(_ invocation: MCPDomainHostInvocation) async throws -> Value {
        let clock = ContinuousClock()
        let hostEntry = clock.now
        recordTimingMetric(
            name: "mcp_domain_host_queue_wait",
            toolName: invocation.resolution.toolName,
            duration: invocation.submittedAt.duration(to: hostEntry),
            outcome: "entered"
        )
        guard lifecycle == .accepting else {
            throw MCPDomainHostError.draining
        }
        guard activeInvocations[invocation.invocationID] == nil else {
            throw MCPDomainHostError.duplicateInvocationID(invocation.invocationID)
        }
        guard pendingInvocationIDs.insert(invocation.invocationID).inserted else {
            throw MCPDomainHostError.duplicateInvocationID(invocation.invocationID)
        }
        let ownsPendingInvocation = true
        var didAdmitInvocation = false
        defer {
            if ownsPendingInvocation, !didAdmitInvocation {
                pendingInvocationIDs.remove(invocation.invocationID)
                markDrainedIfSettled()
            }
        }
        try validateSecurityContext(invocation)
        _ = try await resolveOperation(
            toolName: invocation.resolution.toolName,
            arguments: invocation.arguments
        )

        guard let resolved = await registry.resolve(
            toolName: invocation.resolution.toolName,
            scope: invocation.resolution.scope
        ) else {
            throw MCPDomainHostError.scopeUnavailable(
                toolName: invocation.resolution.toolName,
                scope: invocation.resolution.scope
            )
        }
        guard resolved.handle == invocation.resolution.registrationHandle,
              await registry.isActive(resolved.handle)
        else {
            throw MCPDomainHostError.staleRegistration(toolName: invocation.resolution.toolName)
        }

        let currentRegistration: DomainConnectionRegistration
        do {
            currentRegistration = try await routingCoordinator.currentRegistration(
                connectionID: invocation.connectionID
            )
        } catch {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }
        guard currentRegistration.runtimeID == identity.runtimeID,
              currentRegistration.generation == invocation.securityContext.connectionGeneration
        else {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }

        await beforeFinalAdmission()

        // Actor reentrancy permits drain to begin across any validation suspension above.
        // This final check and active-map insertion form the authoritative admission fence:
        // there is no suspension between them, so beginDrain cannot miss a late invocation.
        guard lifecycle == .accepting else {
            throw MCPDomainHostError.draining
        }
        guard activeInvocations[invocation.invocationID] == nil else {
            throw MCPDomainHostError.duplicateInvocationID(invocation.invocationID)
        }
        guard pendingInvocationIDs.remove(invocation.invocationID) != nil else {
            throw MCPDomainHostError.duplicateInvocationID(invocation.invocationID)
        }
        guard !isConnectionGenerationTerminal(
            connectionID: invocation.connectionID,
            generation: invocation.securityContext.connectionGeneration
        ) else {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }
        let metrics = metrics
        let toolName = invocation.resolution.toolName
        let task = Task {
            let executionStartedAt = clock.now
            do {
                try Task.checkCancellation()
                guard await self.registry.isActive(resolved.handle) else {
                    throw MCPDomainHostError.staleRegistration(toolName: toolName)
                }
                let value = try await MCPDomainInvocationSecurityContext.$current.withValue(
                    invocation.securityContext
                ) {
                    try await MCPDomainAdmittedContextValues.$current.withValue(
                        invocation.admittedContext
                    ) {
                        try await resolved.binding(invocation.arguments)
                    }
                }
                Self.recordTimingMetric(
                    metrics: metrics,
                    name: "mcp_domain_host_execution",
                    toolName: toolName,
                    duration: executionStartedAt.duration(to: clock.now),
                    outcome: "success"
                )
                return value
            } catch {
                Self.recordTimingMetric(
                    metrics: metrics,
                    name: "mcp_domain_host_execution",
                    toolName: toolName,
                    duration: executionStartedAt.duration(to: clock.now),
                    outcome: error is CancellationError ? "cancelled" : "error"
                )
                throw error
            }
        }
        activeInvocations[invocation.invocationID] = ActiveInvocation(
            connectionID: invocation.connectionID,
            connectionGeneration: invocation.securityContext.connectionGeneration,
            task: task
        )
        pendingInvocationIDs.remove(invocation.invocationID)
        didAdmitInvocation = true
        invocationIDsByConnection[invocation.connectionID, default: []].insert(invocation.invocationID)

        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                finishInvocation(invocation.invocationID)
                return value
            } catch {
                finishInvocation(invocation.invocationID)
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    package func beginRequestProgress(
        connectionID: UUID,
        connectionGeneration: UInt64,
        invocationID: UUID,
        token: ProgressToken
    ) -> MCPDomainRequestProgressHandle? {
        guard lifecycle == .accepting,
              !isConnectionGenerationTerminal(
                  connectionID: connectionID,
                  generation: connectionGeneration
              )
        else { return nil }
        let handle = MCPDomainRequestProgressHandle(
            stateID: UUID(),
            connectionID: connectionID,
            invocationID: invocationID
        )
        requestProgressByStateID[handle.stateID] = RequestProgressRecord(
            handle: handle,
            connectionGeneration: connectionGeneration,
            state: MCPRequestProgressState(token: token)
        )
        return handle
    }

    package func sendRequestProgress(
        _ handle: MCPDomainRequestProgressHandle,
        through transport: any MCPDomainProgressTransport,
        message: String?
    ) async {
        guard let record = requestProgressByStateID[handle.stateID],
              record.handle == handle
        else { return }
        await record.state.send(through: transport, message: message)
    }

    package func finishRequestProgress(_ handle: MCPDomainRequestProgressHandle) async {
        guard let record = requestProgressByStateID.removeValue(forKey: handle.stateID),
              record.handle == handle
        else { return }
        await record.state.invalidate()
    }

    /// Acquires the resource lane declared by the installed Rust catalog. Callers provide only
    /// the already-resolved physical resource; they cannot select a different admission class or
    /// reconstruct a limit in the app shell.
    package func acquireToolResourceAdmission(
        toolName: String,
        resource: MCPDomainToolResourceAdmissionController.Resource
    ) async throws -> MCPDomainToolAdmissionLease {
        guard lifecycle == .accepting else { throw MCPDomainHostError.draining }
        guard let entry = runtimeCatalog?.entry(named: toolName)
            ?? (requiresRuntimeCatalog ? nil : MCPDomainToolCatalog.entry(named: toolName)),
            let configured = runtimeCatalog?.configuredLimits(for: toolName)
                ?? (requiresRuntimeCatalog ? nil : MCPDomainToolCatalog.configuredLimits(for: toolName))
        else {
            throw MCPDomainHostError.catalogUnavailable
        }

        let kind: ResourceAdmissionKind
        switch resource {
        case .appWide:
            guard entry.admissionClass == .exclusive,
                  configured.resourceScope == .application
            else { throw MCPDomainHostError.invalidCatalogLimits }
            kind = .exclusiveApplication
        case .window:
            guard configured.resourceScope == .window else {
                throw MCPDomainHostError.invalidCatalogLimits
            }
            switch entry.admissionClass {
            case .exclusive: kind = .exclusiveWindow
            case .smallRead: kind = .smallRead
            case .fileRead: kind = .fileRead
            default: throw MCPDomainHostError.invalidCatalogLimits
            }
        case .repository:
            return try await acquireRepositoryResourceAdmission(
                toolName: toolName,
                repositoryKeys: [resourceKey(resource)]
            )
        }
        guard let controller = resourceAdmissionControllers[kind] else {
            throw MCPDomainHostError.catalogUnavailable
        }
        let lease = try await controller.acquire(resource)
        guard lifecycle == .accepting else {
            _ = lease.release()
            throw MCPDomainHostError.draining
        }
        return MCPDomainToolAdmissionLease(
            toolName: toolName,
            catalogDigest: runtimeCatalog?.digest,
            releaseAction: { _ = lease.release() }
        )
    }

    package func acquireRepositoryResourceAdmission(
        toolName: String,
        repositoryKeys: [String]
    ) async throws -> MCPDomainToolAdmissionLease {
        guard lifecycle == .accepting else { throw MCPDomainHostError.draining }
        guard let entry = runtimeCatalog?.entry(named: toolName)
            ?? (requiresRuntimeCatalog ? nil : MCPDomainToolCatalog.entry(named: toolName)),
            entry.admissionClass == .gitRead,
            let configured = runtimeCatalog?.configuredLimits(for: toolName)
                ?? (requiresRuntimeCatalog ? nil : MCPDomainToolCatalog.configuredLimits(for: toolName)),
            configured.resourceScope == .repository,
            let coordinator = repositoryAdmissionCoordinator
        else {
            throw MCPDomainHostError.catalogUnavailable
        }
        let lease = try await coordinator.acquire(repositoryKeys: repositoryKeys)
        guard lifecycle == .accepting else {
            _ = lease.release()
            throw MCPDomainHostError.draining
        }
        return MCPDomainToolAdmissionLease(
            toolName: toolName,
            catalogDigest: runtimeCatalog?.digest,
            releaseAction: { _ = lease.release() }
        )
    }

    package func acquireMutationResourceAdmission(
        _ resource: MCPDomainToolResourceAdmissionController.Resource
    ) async throws -> MCPDomainToolAdmissionLease {
        switch resource {
        case .appWide:
            try await acquireToolResourceAdmission(
                toolName: MCPGlobalToolName.appSettings,
                resource: resource
            )
        case let .window(windowID):
            try await acquireToolResourceAdmission(
                toolName: MCPWindowToolName.manageSelection,
                resource: .window(windowID)
            )
        case let .repository(repositoryKey):
            try await acquireRepositoryResourceAdmission(
                toolName: MCPWindowToolName.git,
                repositoryKeys: [repositoryKey]
            )
        }
    }

    package func acquireSmallReadResourceAdmission(
        windowID: Int
    ) async throws -> MCPDomainToolAdmissionLease {
        try await acquireToolResourceAdmission(
            toolName: MCPWindowToolName.getFileTree,
            resource: .window(windowID)
        )
    }

    package func acquireFileReadResourceAdmission(
        windowID: Int
    ) async throws -> MCPDomainToolAdmissionLease {
        try await acquireToolResourceAdmission(
            toolName: MCPWindowToolName.readFile,
            resource: .window(windowID)
        )
    }

    private func resourceKey(
        _ resource: MCPDomainToolResourceAdmissionController.Resource
    ) -> String {
        if case let .repository(key) = resource { return key }
        return ""
    }

    package func cancelInvocations(
        connectionID: UUID,
        connectionGeneration: UInt64
    ) async {
        terminalConnectionGenerationByID[connectionID] = max(
            terminalConnectionGenerationByID[connectionID] ?? 0,
            connectionGeneration
        )
        let progressRecords = requestProgressByStateID.values.filter {
            $0.handle.connectionID == connectionID
                && $0.connectionGeneration <= connectionGeneration
        }
        for record in progressRecords {
            requestProgressByStateID.removeValue(forKey: record.handle.stateID)
            await record.state.invalidate()
        }

        let invocationIDs = invocationIDsByConnection[connectionID] ?? []
        for invocationID in invocationIDs {
            guard let invocation = activeInvocations[invocationID],
                  invocation.connectionGeneration <= connectionGeneration
            else { continue }
            invocation.task.cancel()
        }
    }

    /// Releases the terminal-generation fence after routing has removed this exact
    /// connection generation. If cancelled work is still settling, cleanup is deferred
    /// until the last matching invocation leaves the active map.
    package func releaseConnection(
        connectionID: UUID,
        connectionGeneration: UInt64
    ) {
        releasedConnectionGenerationByID[connectionID] = max(
            releasedConnectionGenerationByID[connectionID] ?? 0,
            connectionGeneration
        )
        pruneTerminalConnectionFenceIfSafe(connectionID: connectionID)
    }

    package func beginDrain() {
        guard lifecycle == .accepting else { return }
        lifecycle = .draining
        var closedControllerIDs = Set<ObjectIdentifier>()
        for controller in resourceAdmissionControllers.values {
            guard closedControllerIDs.insert(ObjectIdentifier(controller)).inserted else { continue }
            _ = controller.close()
        }
        _ = repositoryAdmissionCoordinator?.close()
        for invocation in activeInvocations.values {
            invocation.task.cancel()
        }
        markDrainedIfSettled()
    }

    package func drain(timeout: Duration) async -> MCPDomainHostDrainResult {
        beginDrain()
        let progressRecords = Array(requestProgressByStateID.values)
        requestProgressByStateID.removeAll()
        for record in progressRecords {
            await record.state.invalidate()
        }
        let initialCount = activeInvocations.count
        guard hasOutstandingWork else {
            lifecycle = .drained
            return MCPDomainHostDrainResult(
                settledInvocationCount: 0,
                detachedInvocationCount: 0,
                deadlineExpired: false,
                callerCancelled: false
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var callerCancelled = false
        while hasOutstandingWork, clock.now < deadline {
            if Task.isCancelled {
                callerCancelled = true
                break
            }
            let remaining = clock.now.duration(to: deadline)
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(10)))
            } catch is CancellationError {
                callerCancelled = true
                break
            } catch {
                break
            }
        }

        let detachedCount = activeInvocations.count
        let deadlineExpired = hasOutstandingWork && !callerCancelled && clock.now >= deadline
        markDrainedIfSettled()
        return MCPDomainHostDrainResult(
            settledInvocationCount: max(0, initialCount - detachedCount),
            detachedInvocationCount: detachedCount,
            deadlineExpired: deadlineExpired,
            callerCancelled: callerCancelled
        )
    }

    package func snapshot() -> MCPDomainHostSnapshot {
        let admission = resourceAdmissionSnapshot
        return MCPDomainHostSnapshot(
            lifecycle: lifecycle,
            catalogDigest: runtimeCatalog?.digest,
            activeInvocationCount: activeInvocations.count,
            connectionsWithActiveInvocationsCount: invocationIDsByConnection.count,
            activeResourceAdmissionLeaseCount: admission.activeLeaseCount,
            resourceAdmissionWaiterCount: admission.waiterCount,
            terminalConnectionFenceCount: terminalConnectionGenerationByID.count
        )
    }

    private func makeResolution(_ resolved: MCPDomainResolvedTool) -> MCPDomainHostResolution {
        MCPDomainHostResolution(
            toolName: resolved.binding.definition.name,
            scope: resolved.scope,
            registrationHandle: resolved.handle,
            definition: resolved.binding.definition
        )
    }

    private func validateSecurityContext(_ invocation: MCPDomainHostInvocation) throws {
        let context = invocation.securityContext
        guard context.runtimeID == identity.runtimeID,
              context.runtimeGeneration == identity.lifecycleGeneration
        else {
            throw MCPDomainHostError.runtimeGenerationMismatch
        }
        guard context.connectionID == invocation.connectionID,
              context.invocationID == invocation.invocationID
        else {
            throw MCPDomainHostError.connectionRegistrationInvalid
        }
    }

    private func recordTimingMetric(
        name: String,
        toolName: String,
        duration: Duration,
        outcome: String
    ) {
        Self.recordTimingMetric(
            metrics: metrics,
            name: name,
            toolName: toolName,
            duration: duration,
            outcome: outcome
        )
    }

    private nonisolated static func recordTimingMetric(
        metrics: DomainRuntimeMetricsSink,
        name: String,
        toolName: String,
        duration: Duration,
        outcome: String
    ) {
        let components = duration.components
        let microseconds = max(
            0,
            components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
        )
        metrics.record(DomainRuntimeMetric(
            phase: .runtime,
            name: name,
            dimensions: [
                "tool_name": toolName,
                "duration_microseconds": String(microseconds),
                "outcome": outcome
            ]
        ))
    }

    private func finishInvocation(_ invocationID: UUID) {
        guard let invocation = activeInvocations.removeValue(forKey: invocationID) else { return }
        invocationIDsByConnection[invocation.connectionID]?.remove(invocationID)
        if invocationIDsByConnection[invocation.connectionID]?.isEmpty == true {
            invocationIDsByConnection.removeValue(forKey: invocation.connectionID)
        }
        pruneTerminalConnectionFenceIfSafe(connectionID: invocation.connectionID)
        markDrainedIfSettled()
    }

    private func pruneTerminalConnectionFenceIfSafe(connectionID: UUID) {
        guard let terminalGeneration = terminalConnectionGenerationByID[connectionID],
              let releasedGeneration = releasedConnectionGenerationByID[connectionID],
              releasedGeneration >= terminalGeneration
        else { return }
        let hasUnsettledGeneration = activeInvocations.values.contains {
            $0.connectionID == connectionID && $0.connectionGeneration <= releasedGeneration
        }
        guard !hasUnsettledGeneration else { return }
        terminalConnectionGenerationByID.removeValue(forKey: connectionID)
        releasedConnectionGenerationByID.removeValue(forKey: connectionID)
    }

    private func isConnectionGenerationTerminal(
        connectionID: UUID,
        generation: UInt64
    ) -> Bool {
        guard let terminalGeneration = terminalConnectionGenerationByID[connectionID] else {
            return false
        }
        return generation <= terminalGeneration
    }

    private var resourceAdmissionSnapshot: (activeLeaseCount: Int, waiterCount: Int) {
        var activeLeaseCount = 0
        var waiterCount = 0
        var seenControllerIDs = Set<ObjectIdentifier>()
        for controller in resourceAdmissionControllers.values {
            guard seenControllerIDs.insert(ObjectIdentifier(controller)).inserted else { continue }
            let snapshot = controller.snapshot()
            activeLeaseCount += snapshot.activeLeaseCount
            waiterCount += snapshot.waiterCount
        }
        if let repositoryAdmissionCoordinator {
            let snapshot = repositoryAdmissionCoordinator.snapshot()
            activeLeaseCount += snapshot.activeLeaseCount
            waiterCount += snapshot.waiterCount
        }
        return (activeLeaseCount, waiterCount)
    }

    private var hasOutstandingWork: Bool {
        let admission = resourceAdmissionSnapshot
        // Pending IDs fence duplicate requests but are intentionally not counted as outstanding
        // execution: a drain may settle while a pre-admission caller is suspended, and that
        // caller will observe the final draining fence when it resumes.
        return !activeInvocations.isEmpty
            || admission.activeLeaseCount > 0
            || admission.waiterCount > 0
    }

    private func markDrainedIfSettled() {
        if lifecycle == .draining, !hasOutstandingWork {
            lifecycle = .drained
        }
    }
}
