import AgentryCoreBridge
import Foundation
import MCP
import RepoPromptDomainRuntime

typealias MCPToolAdmissionClass = RepoPromptDomainRuntime.MCPToolAdmissionClass
typealias MCPToolOperationIdentity = RepoPromptDomainRuntime.MCPDomainToolOperationIdentity

extension MCPToolAdmissionClass {
    var connectionLane: MCPConnectionCallLane {
        switch self {
        case .exclusive:
            .ordinary
        case .control:
            .control
        case .smallRead:
            .smallRead
        case .fileRead:
            .fileRead
        case .gitRead:
            .gitRead
        case .fileSearch:
            .fileSearch
        }
    }
}

enum MCPToolAdmissionPolicy {
    /// Keep app-host admission aligned with the package-level domain limits.
    /// Runtime-derived limits observe the verified catalog installed by the domain runtime.
    /// The Swift constants are compatibility values for isolated policy fixtures only.
    static var exclusiveConnectionLimit: Int {
        limit(for: MCPGlobalToolName.appSettings, fallback: MCPDomainToolAdmissionLimits.exclusiveConnection)
    }

    static var controlConnectionLimit: Int {
        limit(for: MCPWindowToolName.agentManage, fallback: MCPDomainToolAdmissionLimits.controlConnection)
    }

    static var smallReadConnectionLimit: Int {
        limit(for: MCPWindowToolName.getFileTree, fallback: MCPDomainToolAdmissionLimits.smallReadConnection)
    }

    static var smallReadPerWindowLimit: Int {
        limit(for: MCPWindowToolName.getFileTree, fallback: MCPDomainToolAdmissionLimits.smallReadPerWindow, resource: true)
    }

    static var fileReadConnectionLimit: Int {
        limit(for: MCPWindowToolName.readFile, fallback: MCPDomainToolAdmissionLimits.fileReadConnection)
    }

    static var fileReadPerWindowLimit: Int {
        limit(for: MCPWindowToolName.readFile, fallback: MCPDomainToolAdmissionLimits.fileReadPerWindow, resource: true)
    }

    static var gitReadConnectionLimit: Int {
        limit(for: MCPWindowToolName.git, fallback: MCPDomainToolAdmissionLimits.gitReadConnection)
    }

    static var fileSearchConnectionLimit: Int {
        limit(for: MCPWindowToolName.search, fallback: MCPDomainToolAdmissionLimits.fileSearchConnection)
    }

    static var gitReadPerRepositoryLimit: Int {
        limit(for: MCPWindowToolName.git, fallback: MCPDomainToolAdmissionLimits.gitReadPerRepository, resource: true)
    }

    static let classifications = MCPDomainToolCatalog.classifications

    static func classification(forCanonicalToolName toolName: String) -> MCPToolAdmissionClass? {
        MCPDomainToolCatalog.admissionClass(for: toolName)
    }

    private static func limit(for toolName: String, fallback: Int, resource: Bool = false) -> Int {
        guard let configured = MCPDomainToolCatalog.configuredLimits(for: toolName) else {
            return fallback
        }
        if resource {
            return configured.resourceLease ?? fallback
        }
        return configured.connectionLane > 0 ? configured.connectionLane : fallback
    }

    static func operationIdentity(
        forCanonicalToolName toolName: String,
        arguments: [String: Value]
    ) -> MCPToolOperationIdentity {
        MCPDomainToolCatalog.operationIdentity(for: toolName, input: operationInput(
            forCanonicalToolName: toolName,
            arguments: arguments
        ))
    }

    /// Fixture-only adapter retained for isolated policy tests. Production call paths resolve
    /// operation identity through MCPDomainHost, which owns the installed Rust catalog handoff.
    static func rustOperationIdentity(
        forCanonicalToolName toolName: String,
        arguments: [String: Value]
    ) async -> MCPToolOperationIdentity {
        let input = operationInput(forCanonicalToolName: toolName, arguments: arguments)
        do {
            let owner = try await AgentryCoreService.shared.runtime()
            let rawInput: CoreMcpToolOperationInput = switch input {
            case .missing: .missing
            case let .value(value): .value(value)
            case .malformed: .malformed
            }
            let identity = try await owner.coreMcpToolOperationIdentity(
                toolName: toolName,
                input: rawInput
            )
            return MCPToolOperationIdentity(
                canonicalTool: identity.canonicalTool,
                normalizedOperation: identity.normalizedOperation
            )
        } catch {
            return .unknown
        }
    }

    private static func operationInput(
        forCanonicalToolName toolName: String,
        arguments: [String: Value]
    ) -> MCPDomainToolOperationInput {
        if let argumentKey = MCPDomainToolCatalog.operationArgumentKey(for: toolName),
           let value = arguments[argumentKey]
        {
            return value.stringValue.map(MCPDomainToolOperationInput.value) ?? .malformed
        }
        return .missing
    }
}
