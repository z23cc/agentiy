import Foundation
@testable import RepoPromptApp
import XCTest

final class CECLINamingAndRoutingTests: XCTestCase {
    func testCanonicalAgentryCLICommandsAndStableConfigUseAgentryIdentity() {
        do {
            let caseLabel = "testCanonicalAgentryPathCommandNames"
            #if DEBUG
                XCTAssertEqual(CLIPathInstaller.cliCommandName, "agentry-cli-debug", caseLabel)
                XCTAssertEqual(CLIPathInstaller.claudeRPCommandName, "claude-agentry-debug", caseLabel)
            #else
                XCTAssertEqual(CLIPathInstaller.cliCommandName, "agentry-cli", caseLabel)
                XCTAssertEqual(CLIPathInstaller.claudeRPCommandName, "claude-agentry", caseLabel)
            #endif
        }

        do {
            let caseLabel = "testConfigExporterUsesAgentryOwnedStablePath"
            let path = MCPConfigExportService.stableWrapperConfigURL.path
            XCTAssertTrue(path.contains("Library/Application Support/Agentry/MCP"), caseLabel + ": " + path)
            #if DEBUG
                XCTAssertTrue(CLIPathInstaller.test_claudeRPScriptContent().contains(path), caseLabel)
            #endif
        }
    }

    func testUserSpaceSymlinkPathUsesStableNoSpaceDirectory() {
        let path = CLISymlinkManagerUserSpace.userSymlinkPath
        let expectedDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Agentry", isDirectory: true)
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent(), expectedDirectory, path)
        XCTAssertFalse(path.contains(" "), path)
        #if DEBUG
            XCTAssertTrue(path.hasSuffix("agentry_cli_debug"), path)
        #else
            XCTAssertTrue(path.hasSuffix("agentry_cli"), path)
        #endif
    }

    #if DEBUG
        func testClaudeAgentryWrapperMarkerDetection() {
            let generated = CLIPathInstaller.test_claudeRPScriptContent()
            XCTAssertTrue(generated.contains("# claude-agentry: Claude Code wrapper configured for Agentry"))
            XCTAssertTrue(generated.contains("command -v claude"))
            XCTAssertTrue(generated.contains("$HOME/.claude/local/claude"))
            XCTAssertTrue(generated.contains("exec \"$claude_bin\""))
            XCTAssertTrue(CLIPathInstaller.test_isManagedClaudeRPScript(generated))
            XCTAssertFalse(CLIPathInstaller.test_isManagedClaudeRPScript("# claude-rpce: Claude Code wrapper configured for RepoPrompt CE\n"))
            XCTAssertFalse(CLIPathInstaller.test_isManagedClaudeRPScript("#!/bin/bash\necho '# claude-agentry: Claude Code wrapper configured for Agentry'\n"))
            XCTAssertFalse(CLIPathInstaller.test_isManagedClaudeRPScript("#!/bin/bash\necho unrelated\n"))
        }
    #endif
}
