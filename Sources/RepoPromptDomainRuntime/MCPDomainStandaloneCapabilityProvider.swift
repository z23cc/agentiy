import Foundation
import MCP

/// Protocol-neutral argument carrier used by physical capability backends.
/// Backends decode only the request type for the capability they implement; MCP `Value`
/// never appears in a backend protocol signature.
package struct DomainPhysicalToolRequest: Sendable {
    package let argumentsJSON: Data
    package let securityContext: DomainToolInvocationSecurityContext?

    package init(
        argumentsJSON: Data,
        securityContext: DomainToolInvocationSecurityContext?
    ) {
        self.argumentsJSON = argumentsJSON
        self.securityContext = securityContext
    }

    init(arguments: [String: Value]) throws {
        argumentsJSON = try JSONEncoder().encode(arguments)
        securityContext = MCPDomainInvocationSecurityContext.current
    }
}

package struct DomainPhysicalReadRequest: Sendable {
    package let request: DomainPhysicalToolRequest
    package let context: DomainReadInvocationContext
    package let sideEffects: MCPDomainReadSideEffectEmitter

    package init(
        request: DomainPhysicalToolRequest,
        context: DomainReadInvocationContext,
        sideEffects: MCPDomainReadSideEffectEmitter
    ) {
        self.request = request
        self.context = context
        self.sideEffects = sideEffects
    }
}

package struct DomainPhysicalToolResult: Sendable {
    package let json: Data

    package init(json: Data) {
        self.json = json
    }

    package init<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        json = try encoder.encode(value)
    }

    func mcpValue() throws -> Value {
        try JSONDecoder().decode(Value.self, from: json)
    }
}

package protocol DomainGlobalControlBackend: Sendable {
    func accessSettings(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func routeContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func manageWorkspaceLifecycle(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
}

package protocol DomainWorkspaceCapabilityBackend: Sendable {
    func mutateSelection(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func inspectCodeStructure(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func renderFileTree(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func readFile(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func searchFiles(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func renderWorkspaceContext(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func accessPrompt(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
}

package protocol DomainFilesystemMutationBackend: Sendable {
    func manageFiles(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func applyFileEdits(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
}

package protocol DomainConversationCapabilityBackend: Sendable {
    func accessOracleUtilities(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func startOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func continueOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func readOracleLog(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func buildContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func requestUserInput(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
}

package protocol DomainVersionControlCapabilityBackend: Sendable {
    func inspectGit(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
    func manageWorktree(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
}

package protocol DomainAgentCapabilityBackend: Sendable {
    func explore(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func run(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func manage(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func shareThoughts(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func publishStatus(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    func waitForInstruction(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
}

package protocol DomainHistoryCapabilityBackend: Sendable {
    func inspectHistory(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult
}

package struct MCPDomainStandaloneCapabilityBackends: Sendable {
    package let global: any DomainGlobalControlBackend
    package let workspace: any DomainWorkspaceCapabilityBackend
    package let filesystem: any DomainFilesystemMutationBackend
    package let conversation: any DomainConversationCapabilityBackend
    package let versionControl: any DomainVersionControlCapabilityBackend
    package let agent: any DomainAgentCapabilityBackend
    package let history: any DomainHistoryCapabilityBackend

    package init(
        global: any DomainGlobalControlBackend,
        workspace: any DomainWorkspaceCapabilityBackend,
        filesystem: any DomainFilesystemMutationBackend,
        conversation: any DomainConversationCapabilityBackend,
        versionControl: any DomainVersionControlCapabilityBackend,
        agent: any DomainAgentCapabilityBackend,
        history: any DomainHistoryCapabilityBackend
    ) {
        self.global = global
        self.workspace = workspace
        self.filesystem = filesystem
        self.conversation = conversation
        self.versionControl = versionControl
        self.agent = agent
        self.history = history
    }
}

package struct MCPDomainStandaloneToolInstallation: Sendable {
    package let globalRegistration: MCPDomainToolRegistrationHandle
    package let standaloneRegistration: MCPDomainToolRegistrationHandle
    package let scopeID: DomainStandaloneScopeID
}

package enum MCPDomainStandaloneToolInstaller {
    package static func install(
        runtime: MCPDomainRuntime,
        scopeID: DomainStandaloneScopeID,
        backends: MCPDomainStandaloneCapabilityBackends,
        catalog: MCPDomainCatalogSnapshot? = nil
    ) async throws -> MCPDomainStandaloneToolInstallation {
        let runtimeCatalog: MCPDomainCatalogSnapshot?
        if let catalog {
            runtimeCatalog = catalog
        } else {
            runtimeCatalog = await runtime.toolRegistry.catalogSnapshot()
        }
        let orderedToolNames = runtimeCatalog?.orderedToolNames ?? MCPDomainToolCatalog.orderedToolNames
        let globalToolNames = runtimeCatalog?.globalToolNames ?? MCPGlobalToolName.orderedToolNames
        let standaloneToolNames = runtimeCatalog?.windowToolNames ?? MCPWindowToolName.orderedToolNames
        let readDefinitions = runtimeCatalog?.definitions.filter { runtimeCatalog?.sharedReadToolNames.contains($0.name) == true }
            ?? MCPDomainReadToolDefinitions.definitions
        let readProvider = MCPDomainReadToolProvider(
            resolveContext: { _, requirement in
                try await resolveReadContext(runtime: runtime, requirement: requirement)
            },
            refreshContext: { handle in
                try await runtime.routingCoordinator.refreshReadContext(handle)
            },
            backend: MCPDomainReadToolBackend { toolName, context, arguments, sideEffects in
                let request = try DomainPhysicalReadRequest(
                    request: DomainPhysicalToolRequest(arguments: arguments),
                    context: context,
                    sideEffects: sideEffects
                )
                let result: DomainPhysicalToolResult = switch toolName {
                case MCPWindowToolName.getCodeStructure:
                    try await backends.workspace.inspectCodeStructure(request)
                case MCPWindowToolName.getFileTree:
                    try await backends.workspace.renderFileTree(request)
                case MCPWindowToolName.readFile:
                    try await backends.workspace.readFile(request)
                case MCPWindowToolName.search:
                    try await backends.workspace.searchFiles(request)
                case MCPWindowToolName.workspaceContext:
                    try await backends.workspace.renderWorkspaceContext(request)
                case MCPWindowToolName.prompt:
                    try await backends.workspace.accessPrompt(request)
                case MCPWindowToolName.oracleChatLog:
                    try await backends.conversation.readOracleLog(request)
                case MCPWindowToolName.git:
                    try await backends.versionControl.inspectGit(request)
                case MCPWindowToolName.history:
                    try await backends.history.inspectHistory(request)
                default:
                    throw MCPDomainToolRegistryError.unknownToolName(toolName)
                }
                return try result.mcpValue()
            },
            sideEffects: runtime.readSideEffectCoordinator,
            definitions: readDefinitions
        )

        var rawBindings = readProvider.bindings
        rawBindings.append(contentsOf: try capabilityBindings(backends: backends, catalog: runtimeCatalog))
        let names = rawBindings.map(\.definition.name)
        guard names.count == orderedToolNames.count,
              Set(names) == Set(orderedToolNames),
              Set(names).count == names.count
        else {
            throw MCPDomainToolRegistryError.emptyRegistration
        }

        let decorated = rawBindings.map { binding in
            runtime.protectedMutationProvider.protectedBinding(
                runtime.longRunningToolProvider.wrapping(binding)
            )
        }
        let byName = Dictionary(uniqueKeysWithValues: decorated.map { ($0.definition.name, $0) })
        let globalBindings = globalToolNames.compactMap { byName[$0] }
        let standaloneBindings = standaloneToolNames.compactMap { byName[$0] }

        let globalRegistration = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(),
            scope: .application,
            bindings: globalBindings
        )
        do {
            let standaloneRegistration = try await runtime.toolRegistry.register(
                registrationID: MCPDomainToolRegistrationID(),
                scope: .standalone(id: scopeID),
                bindings: standaloneBindings
            )
            return MCPDomainStandaloneToolInstallation(
                globalRegistration: globalRegistration,
                standaloneRegistration: standaloneRegistration,
                scopeID: scopeID
            )
        } catch {
            _ = await runtime.toolRegistry.unregister(globalRegistration)
            throw error
        }
    }

    package static func uninstall(
        _ installation: MCPDomainStandaloneToolInstallation,
        runtime: MCPDomainRuntime
    ) async {
        _ = await runtime.toolRegistry.unregister(installation.standaloneRegistration)
        _ = await runtime.toolRegistry.unregister(installation.globalRegistration)
    }

    private static func resolveReadContext(
        runtime: MCPDomainRuntime,
        requirement: DomainReadContextRequirement
    ) async throws -> DomainReadInvocationContext {
        guard let securityContext = MCPDomainInvocationSecurityContext.current else {
            if requirement == .workspaceRequired {
                throw DomainReadContextResolutionError.connectionUnavailable
            }
            return DomainReadInvocationContext(handle: nil, connectionID: nil)
        }
        let registration = try await runtime.routingCoordinator.currentRegistration(
            connectionID: securityContext.connectionID
        )
        do {
            let handle = try await runtime.routingCoordinator.resolveReadContext(connection: registration)
            return DomainReadInvocationContext(
                invocationID: securityContext.invocationID,
                handle: handle,
                connectionID: securityContext.connectionID
            )
        } catch {
            if requirement == .workspaceRequired { throw error }
            return DomainReadInvocationContext(
                invocationID: securityContext.invocationID,
                handle: nil,
                connectionID: securityContext.connectionID
            )
        }
    }

    private static func capabilityBindings(
        backends: MCPDomainStandaloneCapabilityBackends,
        catalog: MCPDomainCatalogSnapshot?
    ) throws -> [MCPDomainToolBinding] {
        [
            try binding(MCPGlobalToolName.appSettings, backends.global.accessSettings, catalog: catalog),
            try binding(MCPGlobalToolName.bindContext, backends.global.routeContext, catalog: catalog),
            try binding(MCPGlobalToolName.manageWorkspaces, backends.global.manageWorkspaceLifecycle, catalog: catalog),
            try binding(MCPWindowToolName.manageSelection, backends.workspace.mutateSelection, catalog: catalog),
            try binding(MCPWindowToolName.fileActions, backends.filesystem.manageFiles, catalog: catalog),
            try binding(MCPWindowToolName.applyEdits, backends.filesystem.applyFileEdits, catalog: catalog),
            try binding(MCPWindowToolName.oracleUtils, backends.conversation.accessOracleUtilities, catalog: catalog),
            try binding(MCPWindowToolName.askOracle, backends.conversation.startOracleConversation, catalog: catalog),
            try binding(MCPWindowToolName.oracleSend, backends.conversation.continueOracleConversation, catalog: catalog),
            try binding(MCPWindowToolName.manageWorktree, backends.versionControl.manageWorktree, catalog: catalog),
            try binding(MCPWindowToolName.contextBuilder, backends.conversation.buildContext, catalog: catalog),
            try binding(MCPWindowToolName.askUser, backends.conversation.requestUserInput, catalog: catalog),
            try binding(MCPWindowToolName.agentExplore, backends.agent.explore, catalog: catalog),
            try binding(MCPWindowToolName.agentRun, backends.agent.run, catalog: catalog),
            try binding(MCPWindowToolName.agentManage, backends.agent.manage, catalog: catalog),
            try binding(MCPWindowToolName.shareThoughts, backends.agent.shareThoughts, catalog: catalog),
            try binding(MCPWindowToolName.setStatus, backends.agent.publishStatus, catalog: catalog),
            try binding(MCPWindowToolName.waitForNextInstruction, backends.agent.waitForInstruction, catalog: catalog),
        ]
    }

    private static func binding(
        _ name: String,
        _ operation: @escaping @Sendable (DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult,
        catalog: MCPDomainCatalogSnapshot?
    ) throws -> MCPDomainToolBinding {
        guard let definition = catalog?.definitions.first(where: { $0.name == name })
            ?? MCPDomainGeneratedToolDefinitions.definition(named: name) else {
            throw MCPDomainToolRegistryError.unknownToolName(name)
        }
        return MCPDomainToolBinding(definition: definition) { arguments in
            let request = try DomainPhysicalToolRequest(arguments: arguments)
            return try await operation(request).mcpValue()
        }
    }
}
