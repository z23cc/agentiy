import Foundation

package enum MCPGlobalToolName {
    package static let appSettings = "app_settings"
    package static let bindContext = "bind_context"
    package static let manageWorkspaces = "manage_workspaces"

    package static var orderedToolNames: [String] {
        MCPDomainToolCatalog.globalToolNames
    }
}

package enum MCPWindowToolName {
    package static let manageSelection = "manage_selection"
    package static let fileActions = "file_actions"
    package static let getCodeStructure = "get_code_structure"
    package static let getFileTree = "get_file_tree"
    package static let readFile = "read_file"
    package static let search = "file_search"
    package static let workspaceContext = "workspace_context"
    package static let prompt = "prompt"
    package static let applyEdits = "apply_edits"
    package static let oracleUtils = "oracle_utils"
    package static let askOracle = "ask_oracle"
    package static let oracleSend = "oracle_send"
    package static let oracleChatLog = "oracle_chat_log"
    package static let git = "git"
    package static let manageWorktree = "manage_worktree"
    package static let contextBuilder = "context_builder"
    package static let askUser = "ask_user"
    package static let agentExplore = "agent_explore"
    package static let agentRun = "agent_run"
    package static let agentManage = "agent_manage"
    package static let history = "history"
    package static let shareThoughts = "share_thoughts"
    package static let setStatus = "set_status"
    package static let waitForNextInstruction = "wait_for_next_user_instruction"

    package static var orderedToolNames: [String] {
        MCPDomainToolCatalog.windowToolNames
    }
}

package enum MCPDomainToolScopeKind: String, CaseIterable, Sendable {
    case application
    case window
    case standalone
}

package enum MCPToolCapability: String, CaseIterable, Hashable, Sendable {
    case conversationSend = "conversation_send"
    case conversationHelper = "conversation_helper"
    case conversationLog = "conversation_log"
    case workspaceRead = "workspace_read"
    case workspaceMutate = "workspace_mutate"
    case fileRead = "file_read"
    case fileSearch = "file_search"
    case selectionMutate = "selection_mutate"
    case promptMutate = "prompt_mutate"
    case historyRead = "history_read"
    // Preserve the legacy agent_manage list_agents wire capability while using the
    // more precise M1 intent name internally.
    case statusPublication = "agent_session_control"
    case discovery
    case userInteraction = "user_interaction"
    case agentExternalControl = "agent_external_control"
    case agentExploreControl = "agent_explore_control"
    case agentReasoningControl = "agent_reasoning_control"
    case fileContentEdit = "file_content_edit"
    case fileManagement = "file_management"
    case structuralExplore = "structural_explore"
    case agentConversationSend = "agent_conversation_send"
    case gitRead = "git_read"
    case worktreeManage = "worktree_manage"
    case appSettings = "app_settings"

    package var externalName: String {
        rawValue
    }
}

package enum MCPToolAdmissionClass: String, CaseIterable, Sendable {
    case exclusive
    case control
    case smallRead = "small_read"
    case fileRead = "file_read"
    case gitRead = "git_read"
    case fileSearch = "file_search"
}

package enum MCPDomainToolOperationInput: Equatable, Sendable {
    case missing
    case value(String)
    case malformed
}

package struct MCPDomainToolOperationIdentity: Equatable, Hashable, Sendable {
    package static let unknownToolName = "unknown"
    package static let unknownOperation = "unknown"
    package static let callOperation = "call"

    package let canonicalTool: String
    package let normalizedOperation: String

    package init(canonicalTool: String, normalizedOperation: String) {
        self.canonicalTool = canonicalTool
        self.normalizedOperation = normalizedOperation
    }

    package static let unknown = MCPDomainToolOperationIdentity(
        canonicalTool: unknownToolName,
        normalizedOperation: unknownOperation
    )
}

package enum MCPDomainToolResourceLimitScope: String, Hashable, Sendable {
    case application
    case window
    case repository
}

package struct MCPDomainToolConfiguredLimits: Equatable, Sendable {
    package let connectionLane: Int
    package let resourceLease: Int?
    package let resourceScope: MCPDomainToolResourceLimitScope?
}

package enum MCPDomainToolOperationNormalization: String, Hashable, Sendable {
    case exact
    case lowercased
    case trimmedLowercased = "trimmed_lowercased"
}

package struct MCPDomainToolOperationPolicy: Hashable, Sendable {
    package let argumentKey: String
    package let canonicalOperationByInput: [String: String]
    package let defaultOperation: String?
    package let normalization: MCPDomainToolOperationNormalization

    package init(
        argumentKey: String = "op",
        operations: [String],
        aliases: [String: String] = [:],
        defaultOperation: String? = nil,
        normalization: MCPDomainToolOperationNormalization
    ) {
        var canonicalOperationByInput = Dictionary(uniqueKeysWithValues: operations.map { ($0, $0) })
        for (alias, canonical) in aliases {
            precondition(canonicalOperationByInput[canonical] != nil)
            canonicalOperationByInput[alias] = canonical
        }
        if let defaultOperation {
            precondition(canonicalOperationByInput[defaultOperation] != nil)
        }
        self.argumentKey = argumentKey
        self.canonicalOperationByInput = canonicalOperationByInput
        self.defaultOperation = defaultOperation
        self.normalization = normalization
    }

    package func normalizedOperation(for input: MCPDomainToolOperationInput) -> String {
        let candidate: String
        switch input {
        case .missing:
            return defaultOperation ?? MCPDomainToolOperationIdentity.unknownOperation
        case let .value(rawValue):
            candidate = switch normalization {
            case .exact:
                rawValue
            case .lowercased:
                rawValue.lowercased()
            case .trimmedLowercased:
                rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        case .malformed:
            return MCPDomainToolOperationIdentity.unknownOperation
        }
        return canonicalOperationByInput[candidate]
            ?? MCPDomainToolOperationIdentity.unknownOperation
    }
}

package struct MCPDomainToolCatalogEntry: Hashable, Sendable {
    package let name: String
    package let scope: MCPDomainToolScopeKind
    package let capability: MCPToolCapability
    package let admissionClass: MCPToolAdmissionClass
    package let operationPolicy: MCPDomainToolOperationPolicy?
    package let registrationScopes: [MCPDomainToolScopeKind]

    package init(
        name: String,
        scope: MCPDomainToolScopeKind,
        capability: MCPToolCapability,
        admissionClass: MCPToolAdmissionClass
    ) {
        self.name = name
        self.scope = scope
        self.capability = capability
        self.admissionClass = admissionClass
        self.operationPolicy = nil
        self.registrationScopes = scope == .application ? [.application] : [.window, .standalone]
    }

    package init(
        name: String,
        scope: MCPDomainToolScopeKind,
        capability: MCPToolCapability,
        admissionClass: MCPToolAdmissionClass,
        operationPolicy: MCPDomainToolOperationPolicy?
    ) {
        self.name = name
        self.scope = scope
        self.capability = capability
        self.admissionClass = admissionClass
        self.operationPolicy = operationPolicy
        self.registrationScopes = scope == .application ? [.application] : [.window, .standalone]
    }

    package init(
        name: String,
        scope: MCPDomainToolScopeKind,
        capability: MCPToolCapability,
        admissionClass: MCPToolAdmissionClass,
        operationPolicy: MCPDomainToolOperationPolicy?,
        registrationScopes: [MCPDomainToolScopeKind]
    ) {
        self.name = name
        self.scope = scope
        self.capability = capability
        self.admissionClass = admissionClass
        self.operationPolicy = operationPolicy
        self.registrationScopes = registrationScopes
    }

    package func supports(registrationScope: MCPDomainToolRegistrationScope) -> Bool {
        registrationScopes.contains(registrationScope.kind)
    }
}

private final class MCPDomainToolCatalogRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: MCPDomainCatalogSnapshot?

    func install(_ snapshot: MCPDomainCatalogSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let current = self.snapshot, current.digest != snapshot.digest {
            return false
        }
        self.snapshot = snapshot
        return true
    }

    func read() -> MCPDomainCatalogSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func clear(expectedDigest: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard snapshot?.digest == expectedDigest else { return false }
        snapshot = nil
        return true
    }
}

package enum MCPDomainToolCatalog {
    private static let runtimeState = MCPDomainToolCatalogRuntimeState()

    @discardableResult
    package static func installRuntimeCatalog(_ snapshot: MCPDomainCatalogSnapshot) -> Bool {
        runtimeState.install(snapshot)
    }

    @discardableResult
    package static func clearRuntimeCatalog(expectedDigest: String) -> Bool {
        runtimeState.clear(expectedDigest: expectedDigest)
    }

    package static func runtimeCatalogSnapshot() -> MCPDomainCatalogSnapshot? {
        runtimeState.read()
    }

    /// Generated from the Rust-owned `mcp_catalog_v1.json`; this projection contains no
    /// hand-authored tool names, schemas, capabilities, or operation policies.
    package static let entries: [MCPDomainToolCatalogEntry] = MCPDomainGeneratedToolDefinitions.records.compactMap { record in
        guard let scope = MCPDomainToolScopeKind(rawValue: record.scope),
              let capability = MCPToolCapability(rawValue: record.capability),
              let admissionClass = MCPToolAdmissionClass(rawValue: record.admissionClass)
        else {
            return nil
        }
        let registrationScopes = record.registrationScopes.compactMap(MCPDomainToolScopeKind.init(rawValue:))
        guard registrationScopes.count == record.registrationScopes.count,
              !registrationScopes.isEmpty,
              registrationScopes.contains(scope)
        else {
            return nil
        }
        let operationPolicy = record.operationPolicy.flatMap { policy -> MCPDomainToolOperationPolicy? in
            guard let normalization = MCPDomainToolOperationNormalization(rawValue: policy.normalization),
                  !policy.argumentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !policy.operations.isEmpty,
                  Set(policy.operations).count == policy.operations.count,
                  policy.operations.allSatisfy({ !$0.isEmpty }),
                  policy.aliases.allSatisfy({ alias, canonical in
                      !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && policy.operations.contains(canonical)
                  }),
                  policy.defaultOperation.map({ policy.operations.contains($0) }) ?? true
            else {
                return nil
            }
            return MCPDomainToolOperationPolicy(
                argumentKey: policy.argumentKey,
                operations: policy.operations,
                aliases: policy.aliases,
                defaultOperation: policy.defaultOperation,
                normalization: normalization
            )
        }
        if record.operationPolicy != nil, operationPolicy == nil {
            return nil
        }
        return MCPDomainToolCatalogEntry(
            name: record.name,
            scope: scope,
            capability: capability,
            admissionClass: admissionClass,
            operationPolicy: operationPolicy,
            registrationScopes: registrationScopes
        )
    }

    package static var orderedToolNames: [String] {
        runtimeState.read()?.orderedToolNames ?? entries.map(\.name)
    }

    package static var globalToolNames: [String] {
        runtimeState.read()?.globalToolNames ?? entries.filter { $0.scope == .application }.map(\.name)
    }

    package static var windowToolNames: [String] {
        runtimeState.read()?.windowToolNames ?? entries.filter { $0.scope == .window }.map(\.name)
    }

    package static var classifications: [String: MCPToolAdmissionClass] {
        Dictionary(uniqueKeysWithValues: (runtimeState.read()?.entries ?? entries).map { ($0.name, $0.admissionClass) })
    }

    private static let entriesByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

    package static func entry(named toolName: String) -> MCPDomainToolCatalogEntry? {
        runtimeState.read()?.entry(named: toolName) ?? entriesByName[toolName]
    }

    package static func toolNames(for capabilities: Set<MCPToolCapability>) -> Set<String> {
        if let snapshot = runtimeState.read() {
            return snapshot.toolNames(for: capabilities)
        }
        return Set(entries.lazy.filter { capabilities.contains($0.capability) }.map(\.name))
    }

    package static func capabilities(for toolName: String) -> Set<MCPToolCapability> {
        entry(named: toolName).map { [$0.capability] } ?? []
    }

    package static func admissionClass(for toolName: String) -> MCPToolAdmissionClass? {
        entry(named: toolName)?.admissionClass
    }

    package static func operationArgumentKey(for toolName: String) -> String? {
        entry(named: toolName)?.operationPolicy?.argumentKey
    }

    package static func operationIdentity(
        for toolName: String,
        input: MCPDomainToolOperationInput
    ) -> MCPDomainToolOperationIdentity {
        if let snapshot = runtimeState.read() {
            return snapshot.operationIdentity(for: toolName, input: input)
        }
        guard let entry = entry(named: toolName) else { return .unknown }
        return MCPDomainToolOperationIdentity(
            canonicalTool: entry.name,
            normalizedOperation: entry.operationPolicy?.normalizedOperation(for: input)
                ?? MCPDomainToolOperationIdentity.callOperation
        )
    }

    package static func configuredLimits(for toolName: String) -> MCPDomainToolConfiguredLimits? {
        if let snapshot = runtimeState.read() {
            return snapshot.configuredLimits(for: toolName)
        }
        guard let entry = entry(named: toolName) else { return nil }
        let connectionLane: Int = switch entry.admissionClass {
        case .exclusive: MCPDomainToolAdmissionLimits.exclusiveConnection
        case .control: MCPDomainToolAdmissionLimits.controlConnection
        case .smallRead: MCPDomainToolAdmissionLimits.smallReadConnection
        case .fileRead: MCPDomainToolAdmissionLimits.fileReadConnection
        case .gitRead: MCPDomainToolAdmissionLimits.gitReadConnection
        case .fileSearch: MCPDomainToolAdmissionLimits.fileSearchConnection
        }
        let resource: (limit: Int, scope: MCPDomainToolResourceLimitScope)? = switch entry.admissionClass {
        case .exclusive:
            (
                MCPDomainToolAdmissionLimits.exclusiveConnection,
                entry.scope == .application ? .application : .window
            )
        case .smallRead: (MCPDomainToolAdmissionLimits.smallReadPerWindow, .window)
        case .fileRead: (MCPDomainToolAdmissionLimits.fileReadPerWindow, .window)
        case .gitRead: (MCPDomainToolAdmissionLimits.gitReadPerRepository, .repository)
        case .control, .fileSearch: nil
        }
        return MCPDomainToolConfiguredLimits(
            connectionLane: connectionLane,
            resourceLease: resource?.limit,
            resourceScope: resource?.scope
        )
    }
}
