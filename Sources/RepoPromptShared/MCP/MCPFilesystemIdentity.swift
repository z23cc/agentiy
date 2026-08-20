import Darwin
import Foundation

/// Shared filesystem and stable-name authority for Agentry MCP products.
///
/// Callers select their build flavor locally and pass it explicitly so this
/// shared target never depends on compile-configuration conditionals.
public struct MCPFilesystemIdentity: Equatable, Sendable {
    public enum Product: String, Sendable {
        case agentry
    }

    public enum BuildFlavor: String, Sendable {
        case debug
        case release
    }

    public static let currentProtocolVersion = 8

    public let product: Product
    public let buildFlavor: BuildFlavor
    public let protocolVersion: Int

    public init(
        product: Product,
        buildFlavor: BuildFlavor,
        protocolVersion: Int = Self.currentProtocolVersion
    ) {
        self.product = product
        self.buildFlavor = buildFlavor
        self.protocolVersion = protocolVersion
    }

    public static func agentry(_ buildFlavor: BuildFlavor) -> Self {
        Self(product: .agentry, buildFlavor: buildFlavor)
    }

    public var socketDirectoryName: String {
        switch product {
        case .agentry:
            "agentry-mcp"
        }
    }

    public var bootstrapSocketName: String {
        switch (product, buildFlavor) {
        case (.agentry, .debug):
            "agentry-D-\(protocolVersion).sock"
        case (.agentry, .release):
            "agentry-\(protocolVersion).sock"
        }
    }

    public var externalEventsDirectoryName: String {
        switch (product, buildFlavor) {
        case (.agentry, .debug):
            "MCPEvents-Agentry-D-\(protocolVersion)"
        case (.agentry, .release):
            "MCPEvents-Agentry-\(protocolVersion)"
        }
    }

    public var applicationSupportDirectoryName: String {
        AgentryProductIdentity.applicationSupportDirectoryName
    }

    public var killSignalsDirectoryName: String {
        switch (product, buildFlavor) {
        case (.agentry, .debug):
            "MCPKillSignals-Agentry-D-\(protocolVersion)"
        case (.agentry, .release):
            "MCPKillSignals-Agentry-\(protocolVersion)"
        }
    }

    public var stableWrapperConfigFileName: String {
        switch buildFlavor {
        case .debug:
            "discovery_debug.json"
        case .release:
            "discovery.json"
        }
    }

    public var networkConfigFileName: String {
        switch buildFlavor {
        case .debug:
            "mcp-config_debug.json"
        case .release:
            "mcp-config.json"
        }
    }

    public var routingStateFileName: String {
        switch buildFlavor {
        case .debug:
            "mcp-routing_debug.json"
        case .release:
            "mcp-routing.json"
        }
    }

    public var userSpaceCLIFileName: String {
        switch buildFlavor {
        case .debug:
            "agentry_cli_debug"
        case .release:
            "agentry_cli"
        }
    }

    public var pathCLICommandName: String {
        switch buildFlavor {
        case .debug:
            "agentry-cli-debug"
        case .release:
            "agentry-cli"
        }
    }

    public var claudeWrapperCommandName: String {
        switch buildFlavor {
        case .debug:
            "claude-agentry-debug"
        case .release:
            "claude-agentry"
        }
    }

    public func socketDirectoryURL(userID: uid_t = getuid()) -> URL {
        URL(fileURLWithPath: "/tmp/\(socketDirectoryName)-\(userID)", isDirectory: true)
    }

    public func bootstrapSocketURL(userID: uid_t = getuid()) -> URL {
        socketDirectoryURL(userID: userID).appendingPathComponent(bootstrapSocketName, isDirectory: false)
    }

    public func applicationSupportRootURL(fileManager: FileManager = .default) -> URL {
        AgentryProductIdentity.applicationSupportRootURL(fileManager: fileManager)
    }

    public func temporaryRootURL(fileManager: FileManager = .default) -> URL {
        AgentryProductIdentity.temporaryRootURL(fileManager: fileManager)
    }

    public func configDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent("MCP", isDirectory: true)
    }

    public func stableWrapperConfigURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(stableWrapperConfigFileName, isDirectory: false)
    }

    public func launchConfigDirectoryURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("LaunchConfigs", isDirectory: true)
    }

    public func externalEventsDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(externalEventsDirectoryName, isDirectory: true)
    }

    public func killSignalsDirectoryURL(fileManager: FileManager = .default) -> URL {
        applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(killSignalsDirectoryName, isDirectory: true)
    }

    public func networkConfigURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(networkConfigFileName, isDirectory: false)
    }

    public func routingStateURL(fileManager: FileManager = .default) -> URL {
        configDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(routingStateFileName, isDirectory: false)
    }

    public func userSpaceCLIURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(AgentryProductIdentity.displayName, isDirectory: true)
            .appendingPathComponent(userSpaceCLIFileName, isDirectory: false)
    }
}
