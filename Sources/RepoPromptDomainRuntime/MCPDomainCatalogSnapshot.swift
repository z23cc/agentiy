import AgentryCoreBridge
import Foundation
import MCP

/// Runtime catalog handoff installed from the verified Rust/FFI snapshot. It carries the
/// canonical bytes and digest alongside the typed definitions so registration and advertisement
/// cannot silently fall back to the generated Swift catalog in production.
package struct MCPDomainCatalogSnapshot: Sendable {
    package let catalogVersion: UInt16
    package let definitionSchemaVersion: UInt16
    package let digest: String
    package let canonicalCatalogJSON: Data
    package let definitions: [MCPDomainToolDefinition]
    package let entries: [MCPDomainToolCatalogEntry]
    package let sharedReadToolNames: Set<String>
    private let limitsByToolName: [String: MCPDomainToolConfiguredLimits]
    private let fingerprintsByToolName: [String: MCPDomainToolFingerprint]

    private let entriesByName: [String: MCPDomainToolCatalogEntry]

    package init(core: CoreMcpToolCatalogSnapshot) throws {
        guard core.catalogVersion == 1,
              core.definitionSchemaVersion == 1,
              core.tools.count == 27,
              core.canonicalCatalogJSON.isEmpty == false
        else {
            throw CoreBridgeError.invalidArgument
        }

        var definitions: [MCPDomainToolDefinition] = []
        var entries: [MCPDomainToolCatalogEntry] = []
        var sharedReadNames = Set<String>()
        var limitsByName: [String: MCPDomainToolConfiguredLimits] = [:]
        var fingerprintsByName: [String: MCPDomainToolFingerprint] = [:]
        var seenNames = Set<String>()
        for record in core.tools {
            guard seenNames.insert(record.name).inserted,
                  let scope = MCPDomainToolScopeKind(rawValue: record.scope),
                  let capability = MCPToolCapability(rawValue: record.capability),
                  let admissionClass = MCPToolAdmissionClass(rawValue: record.admissionClass),
                  let inputSchemaData = record.inputSchemaJSON.data(using: .utf8),
                  let inputSchema = try? JSONDecoder().decode(Value.self, from: inputSchemaData)
            else {
                throw CoreBridgeError.invalidArgument
            }
            let registrationScopes = record.registrationScopes.compactMap(MCPDomainToolScopeKind.init(rawValue:))
            guard registrationScopes.count == record.registrationScopes.count,
                  !registrationScopes.isEmpty,
                  registrationScopes.contains(scope)
            else {
                throw CoreBridgeError.invalidArgument
            }
            let operationPolicy: MCPDomainToolOperationPolicy?
            if let rawPolicy = record.operationPolicy {
                guard let normalization = MCPDomainToolOperationNormalization(rawValue: rawPolicy.normalization),
                      !rawPolicy.argumentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !rawPolicy.operations.isEmpty,
                      Set(rawPolicy.operations).count == rawPolicy.operations.count,
                      rawPolicy.operations.allSatisfy({ !$0.isEmpty }),
                      rawPolicy.aliases.allSatisfy({ alias in
                          !alias.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && rawPolicy.operations.contains(alias.canonicalOperation)
                      }),
                      Set(rawPolicy.aliases.map(\.alias)).count == rawPolicy.aliases.count,
                      rawPolicy.defaultOperation.map({ rawPolicy.operations.contains($0) }) ?? true
                else {
                    throw CoreBridgeError.invalidArgument
                }
                operationPolicy = MCPDomainToolOperationPolicy(
                    argumentKey: rawPolicy.argumentKey,
                    operations: rawPolicy.operations,
                    aliases: Dictionary(uniqueKeysWithValues: rawPolicy.aliases.map {
                        ($0.alias, $0.canonicalOperation)
                    }),
                    defaultOperation: rawPolicy.defaultOperation,
                    normalization: normalization
                )
            } else {
                operationPolicy = nil
            }
            let definition = MCPDomainToolDefinition(
                name: record.name,
                description: record.description,
                inputSchema: inputSchema,
                annotations: MCPDomainToolAnnotations(
                    title: record.title,
                    readOnlyHint: record.readOnlyHint,
                    destructiveHint: record.destructiveHint,
                    idempotentHint: record.idempotentHint,
                    openWorldHint: record.openWorldHint
                ),
                isEnabledByDefault: record.enabledByDefault
            )
            let entry = MCPDomainToolCatalogEntry(
                name: record.name,
                scope: scope,
                capability: capability,
                admissionClass: admissionClass,
                operationPolicy: operationPolicy,
                registrationScopes: registrationScopes
            )
            definitions.append(definition)
            entries.append(entry)
            fingerprintsByName[record.name] = try MCPDomainToolFingerprint(definition: definition)
            limitsByName[record.name] = MCPDomainToolConfiguredLimits(
                connectionLane: Int(record.limits.connectionLane),
                resourceLease: record.limits.resourceLease.map(Int.init),
                resourceScope: record.limits.resourceScope.flatMap(MCPDomainToolResourceLimitScope.init(rawValue:))
            )
            if record.sharedRead {
                sharedReadNames.insert(record.name)
            }
        }
        guard definitions.count == 27,
              entries.count == definitions.count
        else {
            throw CoreBridgeError.invalidArgument
        }
        catalogVersion = core.catalogVersion
        definitionSchemaVersion = core.definitionSchemaVersion
        digest = core.digest
        canonicalCatalogJSON = core.canonicalCatalogJSON
        self.definitions = definitions
        self.entries = entries
        sharedReadToolNames = sharedReadNames
        limitsByToolName = limitsByName
        fingerprintsByToolName = fingerprintsByName
        entriesByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
    }

    package var orderedToolNames: [String] {
        definitions.map(\.name)
    }

    package var globalToolNames: [String] {
        entries.filter { $0.scope == .application }.map(\.name)
    }

    package var windowToolNames: [String] {
        entries.filter { $0.scope == .window }.map(\.name)
    }

    package func entry(named toolName: String) -> MCPDomainToolCatalogEntry? {
        entriesByName[toolName]
    }

    package func toolNames(for capabilities: Set<MCPToolCapability>) -> Set<String> {
        Set(entries.lazy.filter { capabilities.contains($0.capability) }.map(\.name))
    }

    package func capabilities(for toolName: String) -> Set<MCPToolCapability> {
        entry(named: toolName).map { [$0.capability] } ?? []
    }

    package func admissionClass(for toolName: String) -> MCPToolAdmissionClass? {
        entry(named: toolName)?.admissionClass
    }

    package func fingerprint(for toolName: String) -> MCPDomainToolFingerprint? {
        fingerprintsByToolName[toolName]
    }

    package func operationArgumentKey(for toolName: String) -> String? {
        entry(named: toolName)?.operationPolicy?.argumentKey
    }

    package func operationIdentity(
        for toolName: String,
        input: MCPDomainToolOperationInput
    ) -> MCPDomainToolOperationIdentity {
        guard let entry = entry(named: toolName) else { return .unknown }
        return MCPDomainToolOperationIdentity(
            canonicalTool: entry.name,
            normalizedOperation: entry.operationPolicy?.normalizedOperation(for: input)
                ?? MCPDomainToolOperationIdentity.callOperation
        )
    }

    /// Returns effective runtime limits. Rust encodes `0`/`null` for the machine-derived
    /// content-read lane; resolving that host capacity here keeps every consumer on the same
    /// snapshot without changing the canonical payload bytes or digest.
    package func configuredLimits(for toolName: String) -> MCPDomainToolConfiguredLimits? {
        guard let raw = limitsByToolName[toolName],
              let entry = entry(named: toolName)
        else { return nil }
        let machineReadCapacity = ContentReadConcurrencyCapacity.maximumConcurrentReads
        let connectionLane = raw.connectionLane == 0 && entry.admissionClass == .fileRead
            ? machineReadCapacity
            : raw.connectionLane
        let resourceLease = raw.resourceLease
            ?? (
                entry.admissionClass == .fileRead && raw.resourceScope == .window
                    ? machineReadCapacity
                    : nil
            )
        return MCPDomainToolConfiguredLimits(
            connectionLane: connectionLane,
            resourceLease: resourceLease,
            resourceScope: raw.resourceScope
        )
    }
}
