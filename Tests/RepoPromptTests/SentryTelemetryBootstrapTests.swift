@testable import RepoPromptApp
import XCTest

final class SentryTelemetryBootstrapTests: XCTestCase {
    func testAgentryDSNUsesNewDebugEnvironmentOverrideAndPlistKeyOnly() {
        let plistDSN = "https://plist@example.invalid/1"
        let environmentDSN = "https://environment@example.invalid/2"
        let infoDictionary: [String: Any] = [
            "AgentrySentryDSN": "  \(plistDSN)  ",
            "RepoPromptSentryDSN": "https://legacy@example.invalid/3"
        ]

        XCTAssertEqual(
            SentryTelemetryBootstrap.configuredDSN(
                environment: ["AGENTRY_SENTRY_DSN": "  \(environmentDSN)  "],
                infoDictionary: infoDictionary,
                allowEnvironmentOverride: true
            ),
            environmentDSN
        )
        XCTAssertEqual(
            SentryTelemetryBootstrap.configuredDSN(
                environment: ["REPOPROMPT_SENTRY_DSN": "https://legacy@example.invalid/4"],
                infoDictionary: infoDictionary,
                allowEnvironmentOverride: true
            ),
            plistDSN
        )
        XCTAssertEqual(
            SentryTelemetryBootstrap.configuredDSN(
                environment: ["AGENTRY_SENTRY_DSN": environmentDSN],
                infoDictionary: infoDictionary,
                allowEnvironmentOverride: false
            ),
            plistDSN
        )
        XCTAssertNil(SentryTelemetryBootstrap.configuredDSN(
            environment: ["REPOPROMPT_SENTRY_DSN": "https://legacy@example.invalid/4"],
            infoDictionary: ["RepoPromptSentryDSN": "https://legacy@example.invalid/3"],
            allowEnvironmentOverride: true
        ))
    }

    func testAgentryTelemetryKillSwitchDoesNotAcceptLegacyAlias() {
        for value in ["1", "true", "YES", "on"] {
            XCTAssertTrue(SentryTelemetryBootstrap.isEnvironmentDisabled(
                environment: ["AGENTRY_TELEMETRY_DISABLED": value]
            ))
        }
        XCTAssertFalse(SentryTelemetryBootstrap.isEnvironmentDisabled(
            environment: ["REPOPROMPT_TELEMETRY_DISABLED": "1"]
        ))
        XCTAssertFalse(SentryTelemetryBootstrap.isEnvironmentDisabled(
            environment: ["AGENTRY_TELEMETRY_DISABLED": "0"]
        ))
    }
}
