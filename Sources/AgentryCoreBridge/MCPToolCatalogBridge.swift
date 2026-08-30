import AgentryUniFFIRaw
import CryptoKit
import Foundation

/// Immutable, independently verified projection of Rust's P9 MCP/tool catalog authority.
/// The canonical payload is retained so downstream domain runtimes can carry the exact bytes
/// that were hashed and verified rather than reconstructing a second catalog.
public struct CoreMcpToolCatalogSnapshot: Equatable, Sendable {
    public let catalogVersion: UInt16
    public let definitionSchemaVersion: UInt16
    public let digest: String
    public let canonicalCatalogJSON: Data
    public let tools: [CoreMcpToolRecord]

    public init(raw: AgentryUniFFIRaw.CoreMcpToolCatalogV1) throws {
        guard raw.catalogVersion == 1,
              raw.definitionSchemaVersion == 1,
              raw.tools.count == Self.expectedToolOrder.count,
              raw.digest.count == 64,
              raw.digest.allSatisfy(\.isHexDigit),
              raw.digest == raw.digest.lowercased(),
              !raw.canonicalCatalogJson.isEmpty
        else {
            throw CoreTransportError.unexpected("invalid MCP catalog version, digest, payload, or count")
        }
        let payload = try Self.decodeCanonicalPayload(raw.canonicalCatalogJson)
        guard try Self.canonicalJSONData(payload.object) == raw.canonicalCatalogJson else {
            throw CoreTransportError.unexpected("MCP catalog payload is not canonical")
        }
        let payloadDigest = SHA256.hash(data: raw.canonicalCatalogJson)
            .map { String(format: "%02x", $0) }
            .joined()
        guard payloadDigest == raw.digest else {
            throw CoreTransportError.unexpected("MCP catalog canonical payload digest mismatch")
        }
        var names = Set<String>()
        let tools = try raw.tools.enumerated().map { index, tool -> CoreMcpToolRecord in
            guard tool.name == Self.expectedToolOrder[index] else {
                throw CoreTransportError.unexpected("MCP catalog tool order changed across FFI")
            }
            try Self.validate(tool: tool, names: &names)
            try Self.validatePayloadRecord(
                payloadTool: payload.tools[index],
                rawTool: tool
            )
            return CoreMcpToolRecord(raw: tool)
        }
        guard tools.count == raw.tools.count,
              names.count == Self.expectedToolOrder.count
        else {
            throw CoreTransportError.unexpected("MCP catalog tool count changed across FFI")
        }
        catalogVersion = raw.catalogVersion
        definitionSchemaVersion = raw.definitionSchemaVersion
        digest = raw.digest
        canonicalCatalogJSON = raw.canonicalCatalogJson
        self.tools = tools
    }

    private static func decodeCanonicalPayload(
        _ bytes: Data
    ) throws -> CanonicalPayload {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let catalogVersion = object["catalog_version"] as? NSNumber,
              let definitionSchemaVersion = object["definition_schema_version"] as? NSNumber,
              catalogVersion.intValue == 1,
              definitionSchemaVersion.intValue == 1,
              let tools = object["tools"] as? [[String: Any]],
              tools.count == expectedToolOrder.count
        else {
            throw CoreTransportError.unexpected("invalid MCP catalog canonical payload")
        }
        return CanonicalPayload(object: object, tools: tools)
    }

    private struct CanonicalPayload {
        let object: [String: Any]
        let tools: [[String: Any]]
    }

    private static func canonicalJSONData(_ value: Any) throws -> Data {
        var data = Data()
        try appendCanonicalJSON(value, to: &data)
        return data
    }

    private static func appendCanonicalJSON(_ value: Any, to data: inout Data) throws {
        if value is NSNull {
            data.append(contentsOf: [110, 117, 108, 108]) // null
            return
        }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            if type == "c" {
                data.append(contentsOf: value.boolValue ? [116, 114, 117, 101] : [102, 97, 108, 115, 101])
                return
            }
            let number = value.stringValue
            guard !number.isEmpty else {
                throw CoreTransportError.unexpected("MCP catalog payload contains an invalid number")
            }
            data.append(contentsOf: number.utf8)
            return
        }
        if let value = value as? Bool {
            data.append(contentsOf: value ? [116, 114, 117, 101] : [102, 97, 108, 115, 101])
            return
        }
        if let value = value as? String {
            appendJSONString(value, to: &data)
            return
        }
        if let value = value as? [Any] {
            data.append(91) // [
            for (index, item) in value.enumerated() {
                if index > 0 { data.append(44) } // ,
                try appendCanonicalJSON(item, to: &data)
            }
            data.append(93) // ]
            return
        }
        if let value = value as? [String: Any] {
            data.append(123) // {
            for (index, key) in value.keys.sorted().enumerated() {
                if index > 0 { data.append(44) } // ,
                appendJSONString(key, to: &data)
                data.append(58) // :
                guard let item = value[key] else {
                    throw CoreTransportError.unexpected("MCP catalog payload contains a missing object value")
                }
                try appendCanonicalJSON(item, to: &data)
            }
            data.append(125) // }
            return
        }
        throw CoreTransportError.unexpected("MCP catalog payload contains an unsupported JSON value")
    }

    private static func appendJSONString(_ value: String, to data: inout Data) {
        data.append(34) // "
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 8: data.append(contentsOf: [92, 98]) // \\b
            case 9: data.append(contentsOf: [92, 116]) // \\t
            case 10: data.append(contentsOf: [92, 110]) // \\n
            case 12: data.append(contentsOf: [92, 102]) // \\f
            case 13: data.append(contentsOf: [92, 114]) // \\r
            case 0...31:
                data.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
            case 34: data.append(contentsOf: [92, 34]) // \\"
            case 92: data.append(contentsOf: [92, 92]) // \\\\
            default:
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        data.append(34) // "
    }

    private static func validatePayloadRecord(
        payloadTool: [String: Any],
        rawTool: AgentryUniFFIRaw.CoreMcpToolDefinitionV1
    ) throws {
        guard let schemaData = rawTool.inputSchemaJson.data(using: .utf8) else {
            throw CoreTransportError.unexpected("MCP catalog typed record has invalid schema")
        }
        let schema: Any
        do {
            schema = try JSONSerialization.jsonObject(with: schemaData)
        } catch {
            throw CoreTransportError.unexpected("MCP catalog typed record has invalid schema")
        }
        let operationPolicy: Any = rawTool.operationPolicy.map(Self.jsonOperationPolicy) ?? NSNull()
        let expected = Self.jsonTool(
            rawTool,
            schema: schema,
            operationPolicy: operationPolicy
        )
        guard let expectedData = try? canonicalJSONData(expected),
              let actualData = try? canonicalJSONData(payloadTool),
              expectedData == actualData,
              try canonicalJSONData(schema) == schemaData
        else {
            throw CoreTransportError.unexpected("MCP catalog typed record differs from canonical payload")
        }
    }

    private static func jsonTool(
        _ tool: AgentryUniFFIRaw.CoreMcpToolDefinitionV1,
        schema: Any,
        operationPolicy: Any
    ) -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "input_schema": schema,
            "annotations": [
                "title": optionalJSON(tool.title),
                "readOnlyHint": optionalJSON(tool.readOnlyHint),
                "destructiveHint": optionalJSON(tool.destructiveHint),
                "idempotentHint": optionalJSON(tool.idempotentHint),
                "openWorldHint": optionalJSON(tool.openWorldHint)
            ],
            "enabled_by_default": tool.enabledByDefault,
            "scope": tool.scope,
            "registration_scopes": tool.registrationScopes,
            "capability": tool.capability,
            "admission_class": tool.admissionClass,
            "operation_policy": operationPolicy,
            "limits": [
                "connection_lane": tool.limits.connectionLane,
                "resource_lease": optionalJSON(tool.limits.resourceLease),
                "resource_scope": optionalJSON(tool.limits.resourceScope)
            ],
            "shared_read": tool.sharedRead
        ]
    }

    private static func jsonOperationPolicy(
        _ policy: AgentryUniFFIRaw.CoreMcpToolOperationPolicyV1
    ) -> [String: Any] {
        let aliases = Dictionary(uniqueKeysWithValues: policy.aliases.map {
            ($0.alias, $0.canonicalOperation)
        })
        return [
            "argument_key": policy.argumentKey,
            "operations": policy.operations,
            "aliases": aliases,
            "default_operation": optionalJSON(policy.defaultOperation),
            "normalization": policy.normalization
        ]
    }

    private static func optionalJSON(_ value: Any?) -> Any {
        value ?? NSNull()
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

    private static let expectedToolOrder = [
        "app_settings", "bind_context", "manage_workspaces", "manage_selection", "file_actions",
        "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context",
        "prompt", "apply_edits", "oracle_utils", "ask_oracle", "oracle_send", "oracle_chat_log",
        "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "agent_run",
        "agent_manage", "share_thoughts", "set_status", "wait_for_next_user_instruction", "history"
    ]
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

public enum CoreMcpToolOperationInput: Equatable, Sendable {
    case missing
    case value(String)
    case malformed

    var raw: AgentryUniFFIRaw.CoreMcpToolOperationInputV1 {
        switch self {
        case .missing:
            .missing
        case let .value(value):
            .value(value)
        case .malformed:
            .malformed
        }
    }
}

public struct CoreMcpToolOperationIdentity: Equatable, Sendable {
    public let canonicalTool: String
    public let normalizedOperation: String

    public init(canonicalTool: String, normalizedOperation: String) {
        self.canonicalTool = canonicalTool
        self.normalizedOperation = normalizedOperation
    }

    init(raw: AgentryUniFFIRaw.CoreMcpToolOperationIdentityV1) {
        canonicalTool = raw.canonicalTool
        normalizedOperation = raw.normalizedOperation
    }
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
