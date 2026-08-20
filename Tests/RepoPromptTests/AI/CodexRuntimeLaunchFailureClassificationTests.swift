import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexRuntimeLaunchFailureClassificationTests: XCTestCase {
    func testSentinelClassifierAcceptsPrefixedMessagesAndRejectsRewrittenGuidance() {
        XCTAssertTrue(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "Agentry could not start Codex: the bundled package is missing. Reinstall Agentry."
            )
        )
        XCTAssertTrue(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "\n  Agentry could not start Codex: leading whitespace is tolerated."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "The selected Codex runtime could not be started. Reinstall Agentry or configure a valid explicit override."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "Permission denied. Ensure the 'codex' executable is accessible."
            )
        )
        XCTAssertFalse(
            CodexProviderHelpers.isCodexExecutableUnavailableMessage(
                "Codex is unavailable because Agentry could not start Codex: (prefix must lead the message)"
            )
        )
    }
}
