import AgentryUniFFIRaw
import Foundation

/// Immutable, validated projection of Rust's P8 MCP/tool catalog authority.
public struct CoreMcpToolCatalogSnapshot: Equatable, Sendable {
    public let catalogVersion: UInt16
    public let definitionSchemaVersion: UInt16
    public let digest: String
    public let tools: [CoreMcpToolRecord]

    public init(raw: AgentryUniFFIRaw.CoreMcpToolCatalogV1) throws {
        guard raw.catalogVersion == 1,
              raw.definitionSchemaVersion == 1,
              raw.tools.count == 27,
              raw.digest.count == 64,
              raw.digest.allSatisfy(\.isHexDigit),
              raw.digest == raw.digest.lowercased()
        else {
            throw CoreTransportError.unexpected("invalid MCP catalog version, digest, or count")
        }
        var names = Set<String>()
        let tools = try raw.tools.map { tool -> CoreMcpToolRecord in
            try Self.validate(tool: tool, names: &names)
            return CoreMcpToolRecord(raw: tool)
        }
        guard tools.count == raw.tools.count else {
            throw CoreTransportError.unexpected("MCP catalog tool count changed across FFI")
        }
        catalogVersion = raw.catalogVersion
        definitionSchemaVersion = raw.definitionSchemaVersion
        digest = raw.digest
        self.tools = tools
    }

    private static func validate(
        tool: AgentryUniFFIRaw.CoreMcpToolDefinitionV1,
        names: inout Set<String>
    ) throws {
        guard names.insert(tool.name).inserted,
              !tool.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let schemaData = tool.inputSchemaJson.data(using: .utf8),
              let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
              schema["type"] as? String == "object",
              allowedCapabilities.contains(tool.capability),
              allowedAdmissionClasses.contains(tool.admissionClass),
              allowedScopes.contains(tool.scope),
              !tool.registrationScopes.isEmpty,
              Set(tool.registrationScopes).count == tool.registrationScopes.count,
              Set(tool.registrationScopes).isSubset(of: allowedRegistrationScopes),
              tool.registrationScopes.contains(tool.scope)
        else {
            throw CoreTransportError.unexpected("invalid MCP catalog tool metadata")
        }
        if let operationPolicy = tool.operationPolicy {
            guard !operationPolicy.argumentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !operationPolicy.operations.isEmpty,
                  operationPolicy.operations.allSatisfy({ !$0.isEmpty }),
                  Set(operationPolicy.operations).count == operationPolicy.operations.count,
                  allowedNormalizations.contains(operationPolicy.normalization),
                  operationPolicy.aliases.allSatisfy({ alias in
                      !alias.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && operationPolicy.operations.contains(alias.canonicalOperation)
                  }),
                  Set(operationPolicy.aliases.map(\.alias)).count == operationPolicy.aliases.count,
                  operationPolicy.defaultOperation.map({ operationPolicy.operations.contains($0) }) ?? true
            else {
                throw CoreTransportError.unexpected("invalid MCP catalog operation policy")
            }
        }
        guard tool.limits.resourceLease.map({ $0 > 0 }) ?? true,
              tool.limits.resourceScope.map(allowedResourceScopes.contains) ?? true
        else {
            throw CoreTransportError.unexpected("invalid MCP catalog resource limits")
        }
    }

    private static let allowedScopes: Set<String> = ["application", "window"]
    private static let allowedRegistrationScopes: Set<String> = ["application", "window", "standalone"]
    private static let allowedCapabilities: Set<String> = [
        "app_settings", "workspace_mutate", "selection_mutate", "file_management", "structural_explore",
        "file_read", "file_search", "workspace_read", "prompt_mutate", "conversation_helper",
        "agent_conversation_send", "conversation_send", "conversation_log", "git_read", "worktree_manage",
        "discovery", "user_interaction", "agent_explore_control", "agent_external_control",
        "agent_reasoning_control", "agent_session_control", "file_content_edit", "history_read"
    ]
    private static let allowedAdmissionClasses: Set<String> = [
        "exclusive", "control", "small_read", "file_read", "git_read", "file_search"
    ]
    private static let allowedNormalizations: Set<String> = ["exact", "lowercased", "trimmed_lowercased"]
    private static let allowedResourceScopes: Set<String> = ["application", "window", "repository"]
}

public struct CoreMcpToolRecord: Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String
    public let title: String?
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
    public let idempotentHint: Bool?
    public let openWorldHint: Bool?
    public let enabledByDefault: Bool
    public let scope: String
    public let registrationScopes: [String]
    public let capability: String
    public let admissionClass: String
    public let operationPolicy: CoreMcpToolOperationPolicy?
    public let limits: CoreMcpToolLimits
    public let sharedRead: Bool

    fileprivate init(raw: AgentryUniFFIRaw.CoreMcpToolDefinitionV1) {
        name = raw.name
        description = raw.description
        inputSchemaJSON = raw.inputSchemaJson
        title = raw.title
        readOnlyHint = raw.readOnlyHint
        destructiveHint = raw.destructiveHint
        idempotentHint = raw.idempotentHint
        openWorldHint = raw.openWorldHint
        enabledByDefault = raw.enabledByDefault
        scope = raw.scope
        registrationScopes = raw.registrationScopes
        capability = raw.capability
        admissionClass = raw.admissionClass
        operationPolicy = raw.operationPolicy.map(CoreMcpToolOperationPolicy.init(raw:))
        limits = CoreMcpToolLimits(raw: raw.limits)
        sharedRead = raw.sharedRead
    }
}

public struct CoreMcpToolOperationPolicy: Equatable, Sendable {
    public let argumentKey: String
    public let operations: [String]
    public let aliases: [CoreMcpToolAlias]
    public let defaultOperation: String?
    public let normalization: String

    fileprivate init(raw: AgentryUniFFIRaw.CoreMcpToolOperationPolicyV1) {
        argumentKey = raw.argumentKey
        operations = raw.operations
        aliases = raw.aliases.map(CoreMcpToolAlias.init(raw:))
        defaultOperation = raw.defaultOperation
        normalization = raw.normalization
    }
}

public struct CoreMcpToolAlias: Equatable, Sendable {
    public let alias: String
    public let canonicalOperation: String

    public init(alias: String, canonicalOperation: String) {
        self.alias = alias
        self.canonicalOperation = canonicalOperation
    }

    fileprivate init(raw: AgentryUniFFIRaw.CoreMcpToolAliasV1) {
        alias = raw.alias
        canonicalOperation = raw.canonicalOperation
    }
}

public struct CoreMcpToolLimits: Equatable, Sendable {
    public let connectionLane: UInt32
    public let resourceLease: UInt32?
    public let resourceScope: String?

    fileprivate init(raw: AgentryUniFFIRaw.CoreMcpToolLimitsV1) {
        connectionLane = raw.connectionLane
        resourceLease = raw.resourceLease
        resourceScope = raw.resourceScope
    }
}
