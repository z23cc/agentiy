import Foundation
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

final class MCPFilesystemIdentityTests: XCTestCase {
    func testExactAgentryV8DebugAndReleaseNames() {
        let debug = MCPFilesystemIdentity.agentry(.debug)
        let release = MCPFilesystemIdentity.agentry(.release)

        XCTAssertEqual(debug.product, .agentry)
        XCTAssertEqual(release.product, .agentry)
        XCTAssertEqual(debug.protocolVersion, 8)
        XCTAssertEqual(release.protocolVersion, 8)
        XCTAssertEqual(debug.socketDirectoryName, "agentry-mcp")
        XCTAssertEqual(release.socketDirectoryName, "agentry-mcp")
        XCTAssertEqual(debug.bootstrapSocketName, "agentry-D-8.sock")
        XCTAssertEqual(release.bootstrapSocketName, "agentry-8.sock")
        XCTAssertEqual(debug.externalEventsDirectoryName, "MCPEvents-Agentry-D-8")
        XCTAssertEqual(release.externalEventsDirectoryName, "MCPEvents-Agentry-8")
        XCTAssertEqual(debug.killSignalsDirectoryName, "MCPKillSignals-Agentry-D-8")
        XCTAssertEqual(release.killSignalsDirectoryName, "MCPKillSignals-Agentry-8")
        XCTAssertNotEqual(debug.bootstrapSocketName, release.bootstrapSocketName)
        XCTAssertNotEqual(debug.externalEventsDirectoryName, release.externalEventsDirectoryName)
    }

    func testAgentryConfigurationCLIAndWrapperNamesShareOneAuthority() {
        let debug = MCPFilesystemIdentity.agentry(.debug)
        let release = MCPFilesystemIdentity.agentry(.release)

        XCTAssertEqual(debug.applicationSupportDirectoryName, "Agentry")
        XCTAssertEqual(release.applicationSupportDirectoryName, "Agentry")
        XCTAssertEqual(debug.stableWrapperConfigFileName, "discovery_debug.json")
        XCTAssertEqual(release.stableWrapperConfigFileName, "discovery.json")
        XCTAssertEqual(debug.networkConfigFileName, "mcp-config_debug.json")
        XCTAssertEqual(release.networkConfigFileName, "mcp-config.json")
        XCTAssertEqual(debug.routingStateFileName, "mcp-routing_debug.json")
        XCTAssertEqual(release.routingStateFileName, "mcp-routing.json")
        XCTAssertEqual(debug.userSpaceCLIFileName, "agentry_cli_debug")
        XCTAssertEqual(release.userSpaceCLIFileName, "agentry_cli")
        XCTAssertEqual(debug.pathCLICommandName, "agentry-cli-debug")
        XCTAssertEqual(release.pathCLICommandName, "agentry-cli")
        XCTAssertEqual(debug.claudeWrapperCommandName, "claude-agentry-debug")
        XCTAssertEqual(release.claudeWrapperCommandName, "claude-agentry")
    }

    func testAgentryProductIdentityOwnsCanonicalRootsAndBundleIdentifiers() throws {
        let fileManager = FileManager.default
        let expectedApplicationSupport = try XCTUnwrap(
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
                .appendingPathComponent("Agentry", isDirectory: true)
        )
        let expectedTemporary = fileManager.temporaryDirectory
            .appendingPathComponent("Agentry", isDirectory: true)

        XCTAssertEqual(AgentryProductIdentity.displayName, "Agentry")
        XCTAssertEqual(AgentryProductIdentity.applicationSupportDirectoryName, "Agentry")
        XCTAssertEqual(AgentryProductIdentity.releaseBundleIdentifier, "io.github.z23cc.agentry")
        XCTAssertEqual(AgentryProductIdentity.debugBundleIdentifier, "io.github.z23cc.agentry.debug")
        XCTAssertEqual(
            AgentryProductIdentity.applicationSupportRootURL(fileManager: fileManager),
            expectedApplicationSupport
        )
        XCTAssertEqual(
            AgentryProductIdentity.temporaryRootURL(fileManager: fileManager),
            expectedTemporary
        )

        for flavor in [MCPFilesystemIdentity.BuildFlavor.debug, .release] {
            let identity = MCPFilesystemIdentity.agentry(flavor)
            XCTAssertEqual(identity.applicationSupportRootURL(fileManager: fileManager), expectedApplicationSupport)
            XCTAssertEqual(identity.temporaryRootURL(fileManager: fileManager), expectedTemporary)
            XCTAssertEqual(
                identity.userSpaceCLIURL(fileManager: fileManager),
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Agentry", isDirectory: true)
                    .appendingPathComponent(identity.userSpaceCLIFileName, isDirectory: false)
            )
        }
    }

    func testSocketURLsUseAgentryV8DirectoryAndFlavorNames() {
        let debug = MCPFilesystemIdentity.agentry(.debug)
        let release = MCPFilesystemIdentity.agentry(.release)

        XCTAssertEqual(debug.socketDirectoryURL(userID: 501).path, "/tmp/agentry-mcp-501")
        XCTAssertEqual(release.socketDirectoryURL(userID: 501).path, "/tmp/agentry-mcp-501")
        XCTAssertEqual(debug.bootstrapSocketURL(userID: 501).path, "/tmp/agentry-mcp-501/agentry-D-8.sock")
        XCTAssertEqual(release.bootstrapSocketURL(userID: 501).path, "/tmp/agentry-mcp-501/agentry-8.sock")
    }

    func testAppAndHelperFilesystemConstantsDelegateToSharedIdentity() throws {
        #if DEBUG
            let expected = MCPFilesystemIdentity.agentry(.debug)
        #else
            let expected = MCPFilesystemIdentity.agentry(.release)
        #endif

        XCTAssertEqual(MCPFilesystemConstants.identity, expected)
        XCTAssertEqual(MCPFilesystemConstants.bootstrapSocketURL(), expected.bootstrapSocketURL())
        XCTAssertEqual(MCPFilesystemConstants.eventsDirectoryURL(), expected.externalEventsDirectoryURL())

        let root = try RepoRoot.url()
        let paths = [
            "Sources/RepoPrompt/Infrastructure/MCP/AppShared/MCPFilesystemConstants.swift",
            "Sources/RepoPromptMCP/Shared/MCPFilesystemConstants.swift"
        ]
        for path in paths {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("MCPFilesystemIdentity.agentry"), path)
            XCTAssertFalse(source.contains("MCPFilesystemIdentity.repoPromptCE"), path)
        }
    }
}
