import Foundation

/// Generated shared-read projection. The Rust catalog owns schema, ordering, and membership.
package enum MCPDomainReadToolDefinitions {
    package static let definitions: [MCPDomainToolDefinition] = MCPDomainGeneratedToolDefinitions.records
        .filter(\.sharedRead)
        .map(\.definition)

    package static let toolNames: [String] = definitions.map(\.name)

    package static func definition(named name: String) -> MCPDomainToolDefinition? {
        definitions.first { $0.name == name }
    }
}
