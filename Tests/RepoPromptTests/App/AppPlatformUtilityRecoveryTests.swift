import CryptoKit
@testable import RepoPromptApp
import XCTest

final class AppPlatformUtilityRecoveryTests: XCTestCase {
    func testAgentSessionDeepLinkURLRoundTripsAndRejectsInvalidScopedRoutes() throws {
        let route = try AgentSessionDeepLinkRoute(
            windowID: 7,
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            sessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        )

        XCTAssertEqual(route.url.scheme, AppDeepLinkURLScheme.canonical)
        XCTAssertEqual(AppDeepLinkRoute.parse(url: route.url), .route(.agentSession(route)))

        let sessionID = try XCTUnwrap(route.sessionID)
        let legacyAgentRoute = try XCTUnwrap(URL(string: "repoprompt://agent/session?workspace_id=\(route.workspaceID.uuidString)&tab_id=\(route.tabID.uuidString)&session_id=\(sessionID.uuidString)&window_id=7"))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: legacyAgentRoute), .route(.agentSession(route)))

        let missingWorkspace = try XCTUnwrap(URL(string: "repoprompt-ce://agent/session?tab_id=\(route.tabID.uuidString)"))
        let malformedSession = try XCTUnwrap(URL(string: "repoprompt-ce://agent/session?workspace_id=\(route.workspaceID.uuidString)&tab_id=\(route.tabID.uuidString)&session_id=not-a-uuid"))
        let unsupportedAgentPath = try XCTUnwrap(URL(string: "repoprompt-ce://agent/other?workspace_id=\(route.workspaceID.uuidString)&tab_id=\(route.tabID.uuidString)"))

        XCTAssertEqual(AppDeepLinkRoute.parse(url: missingWorkspace), .invalidScopedRoute)
        XCTAssertEqual(AppDeepLinkRoute.parse(url: malformedSession), .invalidScopedRoute)
        XCTAssertEqual(AppDeepLinkRoute.parse(url: unsupportedAgentPath), .invalidScopedRoute)
    }

    func testCanonicalAndLegacySchemesRouteOpeners() throws {
        XCTAssertTrue(AppDeepLinkURLScheme.isSupported("repoprompt-ce"))
        XCTAssertTrue(AppDeepLinkURLScheme.isSupported("REPOPROMPT-CE"))
        XCTAssertTrue(AppDeepLinkURLScheme.isSupported("repoprompt"))
        XCTAssertTrue(AppDeepLinkURLScheme.isSupported("REPOPROMPT"))
        XCTAssertFalse(AppDeepLinkURLScheme.isSupported("https"))
        XCTAssertFalse(AppDeepLinkURLScheme.isSupported(nil))

        let ceOpen = try XCTUnwrap(URL(string: "repoprompt-ce://open//Users/example/Project?workspace=Review&files=Sources/App.swift,README.md&prompt=Review%20this&focus=true&ephemeral=true"))
        let legacyOpen = try XCTUnwrap(URL(string: "repoprompt://open//Users/example/Project?persist=false"))
        let cePrompt = try XCTUnwrap(URL(string: "repoprompt-ce://prompt?title=Review&content=Review%20the%20selection&focus=true"))
        let legacyPrompt = try XCTUnwrap(URL(string: "repoprompt://prompt?title=Review&content=Review%20the%20selection&focus=true"))
        let unsupportedScheme = try XCTUnwrap(URL(string: "https://open//Users/example/Project"))

        XCTAssertEqual(AppDeepLinkRoute.parse(url: ceOpen), .route(.legacyURL(ceOpen)))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: legacyOpen), .route(.legacyURL(legacyOpen)))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: cePrompt), .route(.legacyURL(cePrompt)))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: legacyPrompt), .route(.legacyURL(legacyPrompt)))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: unsupportedScheme), .unsupported)
    }

    @MainActor
    func testAgentSessionURLQueuesWhenNoLiveWindowsAreRegistered() async throws {
        let manager = WindowStatesManager.shared
        let originalWindows = manager.allWindows
        let originalPendingURLs = manager.pendingURLs
        manager.allWindows = []
        manager.pendingURLs = []
        defer {
            manager.allWindows = originalWindows
            manager.pendingURLs = originalPendingURLs
        }

        let route = try AgentSessionDeepLinkRoute(
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            sessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        )

        await AppDeepLinkRouter(windowStatesManager: manager).route(url: route.url)

        XCTAssertEqual(manager.pendingURLs, [route.url])
    }

    @MainActor
    func testInAppAgentSessionRouteReturnsResultWithoutQueueingURL() async throws {
        let manager = WindowStatesManager.shared
        let originalWindows = manager.allWindows
        let originalPendingURLs = manager.pendingURLs
        manager.allWindows = []
        manager.pendingURLs = []
        defer {
            manager.allWindows = originalWindows
            manager.pendingURLs = originalPendingURLs
        }

        let route = try AgentSessionDeepLinkRoute(
            workspaceID: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            tabID: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            sessionID: XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        )

        let result = await AppDeepLinkRouter(windowStatesManager: manager).route(agentSession: route)

        XCTAssertEqual(result, .workspaceUnavailable)
        XCTAssertEqual(manager.pendingURLs, [])
    }

    func testAppcastParserSelectsHighestInlineVersionAndKeepsMetadata() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <item>
                    <title>Version 2.1.9</title>
                    <sparkle:shortVersionString>2.1.9</sparkle:shortVersionString>
                    <sparkle:version>319</sparkle:version>
                    <enclosure url="https://example.com/RepoPrompt-2.1.9.zip" />
                </item>
                <item>
                    <title>Beta build 320 · v2.1.20 · commit abc1234def56</title>
                    <sparkle:shortVersionString>2.1.20</sparkle:shortVersionString>
                    <sparkle:version>320</sparkle:version>
                    <pubDate>Tue, 21 Apr 2026 12:28:34 +0000</pubDate>
                    <sparkle:releaseNotesLink>https://example.com/release-notes.html</sparkle:releaseNotesLink>
                    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                    <enclosure url="https://example.com/RepoPrompt-2.1.20.zip" />
                </item>
            </channel>
        </rss>
        """

        let version = try XCTUnwrap(AppcastParser().parse(data: Data(xml.utf8)))

        XCTAssertEqual(version.version, "2.1.20")
        XCTAssertEqual(version.buildNumber, "320")
        XCTAssertEqual(version.title, "Beta build 320 · v2.1.20 · commit abc1234def56")
        XCTAssertEqual(AvailableUpdateNotice.marketingVersion(fromBetaTitle: version.title), "2.1.20")
        XCTAssertEqual(AvailableUpdateNotice.shortCommitSHA(fromBetaTitle: version.title), "abc1234def56")
        XCTAssertEqual(version.releaseNotesURL, "https://example.com/release-notes.html")
        XCTAssertEqual(version.downloadURL, "https://example.com/RepoPrompt-2.1.20.zip")
        XCTAssertEqual(version.minimumSystemVersion, "14.0")
        XCTAssertNotNil(version.date)
    }

    func testUpdateChannelDefaultsToStableAndPersistsBetaSelection() throws {
        let suiteName = "UpdateChannelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(UpdateChannel.load(defaults: defaults), .stable)

        UpdateChannel.store(.beta, defaults: defaults)

        XCTAssertEqual(UpdateChannel.load(defaults: defaults), .beta)
        XCTAssertEqual(UpdateChannel.userDefaultsKey, "AgentryUpdateChannel")
        XCTAssertEqual(
            UpdateChannel.feedURLString(for: .stable, infoDictionary: provisionedSparkleInfo),
            "https://updates.example/agentry-stable/releases/latest/download/appcast.xml"
        )
        XCTAssertEqual(
            UpdateChannel.feedURLString(for: .beta, infoDictionary: provisionedSparkleInfo),
            "https://updates.example/agentry-beta/releases/latest/download/appcast.xml"
        )

        defaults.set("tip", forKey: UpdateChannel.userDefaultsKey)
        XCTAssertEqual(UpdateChannel.load(defaults: defaults), .stable)
        defaults.set("manually-injected", forKey: UpdateChannel.userDefaultsKey)
        XCTAssertEqual(UpdateChannel.load(defaults: defaults), .stable)
    }

    func testSparkleUpdaterManagerAcceptsOnlyProvisionedStableAndBetaConfiguration() {
        XCTAssertTrue(SparkleUpdaterManager.validateSparkleConfiguration(
            infoDictionary: provisionedSparkleInfo,
            selectedChannel: .stable
        ).isValid)
        XCTAssertTrue(SparkleUpdaterManager.validateSparkleConfiguration(
            infoDictionary: provisionedSparkleInfo,
            selectedChannel: .beta
        ).isValid)

        var invalidConfigurations: [[String: Any]] = []
        var placeholders = provisionedSparkleInfo
        placeholders[UpdateChannel.stableFeedInfoDictionaryKey] = "__AGENTRY_SPARKLE_STABLE_FEED_URL__"
        invalidConfigurations.append(placeholders)
        var emptyBeta = provisionedSparkleInfo
        emptyBeta[UpdateChannel.betaFeedInfoDictionaryKey] = "  "
        invalidConfigurations.append(emptyBeta)
        var invalidURL = provisionedSparkleInfo
        invalidURL[UpdateChannel.betaFeedInfoDictionaryKey] = "not-a-url"
        invalidConfigurations.append(invalidURL)
        var legacyFeed = provisionedSparkleInfo
        legacyFeed[UpdateChannel.stableFeedInfoDictionaryKey] =
            "https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml"
        legacyFeed["SUFeedURL"] = legacyFeed[UpdateChannel.stableFeedInfoDictionaryKey]
        invalidConfigurations.append(legacyFeed)
        var mixedCaseLegacyStableFeed = provisionedSparkleInfo
        mixedCaseLegacyStableFeed[UpdateChannel.stableFeedInfoDictionaryKey] =
            "https://github.com/RepoPrompt/RepoPrompt-CE-Updates/releases/latest/download/appcast.xml"
        mixedCaseLegacyStableFeed["SUFeedURL"] = mixedCaseLegacyStableFeed[UpdateChannel.stableFeedInfoDictionaryKey]
        invalidConfigurations.append(mixedCaseLegacyStableFeed)
        var mixedCaseLegacyTipFeed = provisionedSparkleInfo
        mixedCaseLegacyTipFeed[UpdateChannel.betaFeedInfoDictionaryKey] =
            "https://github.com/RepoPrompt/RepoPrompt-CE-Tip-Updates/releases/latest/download/appcast.xml"
        invalidConfigurations.append(mixedCaseLegacyTipFeed)
        for configuration in invalidConfigurations {
            let validation = SparkleUpdaterManager.validateSparkleConfiguration(
                infoDictionary: configuration,
                selectedChannel: .stable
            )
            XCTAssertFalse(validation.isValid)
            XCTAssertEqual(validation.message, SparkleUpdaterManager.unprovisionedConfigurationMessage)
        }

        guard let knownRejectedKey = provisionedSparkleInfo["SUPublicEDKey"] as? String else {
            XCTFail("Missing test Sparkle public key")
            return
        }
        let knownRejectedDigest = SHA256.hash(data: Data(knownRejectedKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let digestMatchedValidation = SparkleUpdaterManager.debugValidateSparkleConfiguration(
            infoDictionary: provisionedSparkleInfo,
            selectedChannel: .stable,
            rejectedPublicEdKeySHA256: knownRejectedDigest
        )
        XCTAssertFalse(digestMatchedValidation.isValid)
        XCTAssertEqual(
            digestMatchedValidation.message,
            SparkleUpdaterManager.unprovisionedConfigurationMessage
        )
    }

    func testAppcastParserPrefersHighestBuildNumberForSameMarketingVersion() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <item>
                    <sparkle:shortVersionString>1.0.27</sparkle:shortVersionString>
                    <sparkle:version>28</sparkle:version>
                </item>
                <item>
                    <sparkle:shortVersionString>1.0.27</sparkle:shortVersionString>
                    <sparkle:version>412</sparkle:version>
                </item>
            </channel>
        </rss>
        """

        let version = try XCTUnwrap(AppcastParser().parse(data: Data(xml.utf8)))

        XCTAssertEqual(version.version, "1.0.27")
        XCTAssertEqual(version.buildNumber, "412")
    }

    func testBetaBuildVersionSortsBetweenAdjacentStableBuilds() throws {
        let currentStable = try XCTUnwrap(SparkleBuildVersion("28"))
        let beta = try XCTUnwrap(SparkleBuildVersion("28.7.95"))
        let nextStable = try XCTUnwrap(SparkleBuildVersion("29"))

        XCTAssertGreaterThan(beta, currentStable)
        XCTAssertGreaterThan(nextStable, beta)
        XCTAssertEqual(SparkleBuildVersion("28"), SparkleBuildVersion("28.0.0"))
        XCTAssertNil(SparkleBuildVersion("28.7.95.1"))
    }

    func testAvailableUpdateNoticeKeepsDetectedChannelAndCentralizesBetaCopy() {
        let notice = AvailableUpdateNotice(
            channel: .beta,
            version: "1.0.28",
            buildNumber: "29.8.52",
            shortCommitSHA: "abc1234def56",
            date: nil,
            releaseNotes: "https://updates.example/agentry-beta/releases/tag/beta-abc1234def56"
        )

        XCTAssertEqual(notice.toolbarLabel, "Beta build 29.8.52")
        XCTAssertEqual(notice.availabilityStatus, "Beta build 29.8.52 · Version v1.0.28 · Commit abc1234def56 is available")
        XCTAssertEqual(notice.menuInstallTitle, "Install Beta Build 29.8.52 (v1.0.28, commit abc1234def56)…")
        XCTAssertEqual(notice.installButtonTitle, "Install Beta Build 29.8.52")
        XCTAssertEqual(notice.accessibilityLabel, "Beta build 29.8.52 · Version v1.0.28 · Commit abc1234def56 update available")
        XCTAssertEqual(notice.availableTooltip, "Beta build 29.8.52 · Version v1.0.28 · Commit abc1234def56 is available — click for update details")
        XCTAssertEqual(notice.accessibilityHint, "Opens Sparkle's update details and install dialog.")
        XCTAssertEqual(notice.channel, .beta)
    }

    func testStableUpdateNoticeUsesStableCopyWithoutBetaLabel() {
        let notice = AvailableUpdateNotice(
            channel: .stable,
            version: "v1.0.29",
            buildNumber: "30",
            shortCommitSHA: nil,
            date: nil,
            releaseNotes: nil
        )

        XCTAssertEqual(notice.toolbarLabel, "Update v1.0.29")
        XCTAssertEqual(notice.availabilityStatus, "Version v1.0.29 · Build 30 is available")
        XCTAssertEqual(notice.menuInstallTitle, "Install Update v1.0.29 (build 30)…")
        XCTAssertEqual(notice.installButtonTitle, "Install Update")
        XCTAssertEqual(notice.availableTooltip, "Version v1.0.29 · Build 30 is available — click to install")
        XCTAssertEqual(notice.accessibilityHint, "Opens Sparkle's update and install dialog.")
        XCTAssertFalse(notice.availableTooltip.localizedCaseInsensitiveContains("release notes"))
        XCTAssertFalse(notice.availabilityStatus.contains("Beta"))
    }

    func testUncorrelatedSparkleNoUpdatePreservesNewerRequestAndNoticeDisposition() throws {
        var observerState = SparkleUserInitiatedObserverState()
        let olderRequestID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let newerRequestID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        let olderRequest = observerState.begin(channel: .beta, requestID: olderRequestID)
        XCTAssertTrue(observerState.finish(request: olderRequest))
        let newerRequest = observerState.begin(channel: .beta, requestID: newerRequestID)

        let disposition = observerState.receiveUncorrelatedNoUpdate()

        XCTAssertEqual(disposition, .preserveNoticeAndRequest)
        XCTAssertEqual(observerState.activeRequest, newerRequest)
        XCTAssertFalse(observerState.finish(request: olderRequest))
        XCTAssertEqual(observerState.activeRequest, newerRequest)
    }

    func testSparklePositiveResultTargetsOnlyMatchingActiveRequestForSettlement() throws {
        var observerState = SparkleUserInitiatedObserverState()
        let requestID = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))

        XCTAssertNil(observerState.requestToSettle(afterPositiveResultFor: .beta))
        let betaRequest = observerState.begin(channel: .beta, requestID: requestID)
        XCTAssertEqual(observerState.requestToSettle(afterPositiveResultFor: .beta), betaRequest)
        XCTAssertNil(observerState.requestToSettle(afterPositiveResultFor: .stable))
        XCTAssertEqual(observerState.activeRequest, betaRequest)
    }

    func testSparklePositiveResultsCannotDowngradeKnownBuilds() {
        XCTAssertTrue(SparkleUpdaterManager.sparkleResultIsNotOlderThanKnownUpdate(
            candidateBuildNumber: "29.8.52",
            knownBuildNumber: nil
        ))
        XCTAssertTrue(SparkleUpdaterManager.sparkleResultIsNotOlderThanKnownUpdate(
            candidateBuildNumber: "29.8.52",
            knownBuildNumber: "29.8.52"
        ))
        XCTAssertTrue(SparkleUpdaterManager.sparkleResultIsNotOlderThanKnownUpdate(
            candidateBuildNumber: "29.8.53",
            knownBuildNumber: "29.8.52"
        ))
        XCTAssertFalse(SparkleUpdaterManager.sparkleResultIsNotOlderThanKnownUpdate(
            candidateBuildNumber: "29.8.51",
            knownBuildNumber: "29.8.52"
        ))
        XCTAssertFalse(SparkleUpdaterManager.sparkleResultIsNotOlderThanKnownUpdate(
            candidateBuildNumber: "not-a-build",
            knownBuildNumber: "29.8.52"
        ))
    }

    func testSparkleDisplayVersionNormalizationRemovesBetaDecoration() {
        let enrichedBetaTitle = "Beta build 29.8.52 · v1.0.28 · commit abc1234def56"

        XCTAssertEqual(
            AvailableUpdateNotice.marketingVersion(fromBetaTitle: enrichedBetaTitle),
            "1.0.28"
        )
        XCTAssertNil(AvailableUpdateNotice.marketingVersion(fromBetaTitle: "Beta build v1.0.27"))
        XCTAssertEqual(
            SparkleUpdaterManager.presentationVersion(
                channel: .beta,
                displayVersion: "1.0.28",
                title: enrichedBetaTitle
            ),
            "1.0.28"
        )
        XCTAssertEqual(
            SparkleUpdaterManager.presentationVersion(
                channel: .beta,
                displayVersion: "Beta build v1.0.27",
                title: "Beta build v1.0.27"
            ),
            "1.0.27"
        )
        XCTAssertEqual(
            SparkleUpdaterManager.presentationVersion(
                channel: .stable,
                displayVersion: "v1.0.29",
                title: enrichedBetaTitle
            ),
            "1.0.29"
        )

        let betaIdentities = SparkleVersionDisplay.formattedIdentities(
            availableDisplayVersion: "1.1.0",
            availableBuildNumber: "31.11.89",
            availableTitle: "Beta build 31.11.89 · v1.1.0 · commit abc1234def56",
            installedDisplayVersion: "1.1.0",
            installedBuildNumber: "31.10.88"
        )
        XCTAssertEqual(betaIdentities.available, "v1.1.0 (31.11.89)")
        XCTAssertEqual(betaIdentities.installed, "1.1.0 (31.10.88)")

        var installedDisplayVersion: NSString = "1.1.0"
        let availableDisplayVersion = SparkleVersionDisplay.apply(
            betaIdentities,
            toInstalledDisplayVersion: &installedDisplayVersion
        )
        XCTAssertEqual(availableDisplayVersion, "v1.1.0 (31.11.89)")
        XCTAssertEqual(installedDisplayVersion, "1.1.0 (31.10.88)")

        let stableIdentities = SparkleVersionDisplay.formattedIdentities(
            availableDisplayVersion: "1.2.0",
            availableBuildNumber: "32",
            availableTitle: "Version 1.2.0",
            installedDisplayVersion: "1.1.0",
            installedBuildNumber: "31"
        )
        XCTAssertEqual(stableIdentities.available, "v1.2.0 (32)")
        XCTAssertEqual(stableIdentities.installed, "1.1.0 (31)")

        let legacyBetaIdentities = SparkleVersionDisplay.formattedIdentities(
            availableDisplayVersion: "Beta build v1.0.27",
            availableBuildNumber: "29.8.51",
            availableTitle: "Beta build v1.0.27",
            installedDisplayVersion: "v1.0.26",
            installedBuildNumber: "29.8.50"
        )
        XCTAssertEqual(legacyBetaIdentities.available, "v1.0.27 (29.8.51)")
        XCTAssertEqual(legacyBetaIdentities.installed, "1.0.26 (29.8.50)")
    }

    func testAppcastRequestIdentityRejectsDelayedAndOverlappingResults() throws {
        let delayedBetaRequest = try AppcastCheckRequestIdentity(
            id: XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            channel: .beta
        )
        let latestStableRequest = try AppcastCheckRequestIdentity(
            id: XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222")),
            channel: .stable
        )

        XCTAssertFalse(SparkleUpdaterManager.appcastResultIsCurrent(
            request: delayedBetaRequest,
            activeRequest: latestStableRequest,
            selectedChannel: .stable
        ))
        XCTAssertTrue(SparkleUpdaterManager.appcastResultIsCurrent(
            request: latestStableRequest,
            activeRequest: latestStableRequest,
            selectedChannel: .stable
        ))

        let supersededStableRequest = AppcastCheckRequestIdentity(channel: .stable)
        XCTAssertFalse(SparkleUpdaterManager.appcastResultIsCurrent(
            request: supersededStableRequest,
            activeRequest: latestStableRequest,
            selectedChannel: .stable
        ))
        XCTAssertFalse(SparkleUpdaterManager.appcastResultIsCurrent(
            request: latestStableRequest,
            activeRequest: nil,
            selectedChannel: .stable
        ))
    }

    func testSparkleAppcastItemURLIdentifiesOnlyExactTrustedUpdateChannels() throws {
        let betaURL = try XCTUnwrap(URL(
            string: "https://updates.example/agentry-beta/releases/download/beta-abc/Agentry.zip"
        ))
        let stableURL = try XCTUnwrap(URL(
            string: "https://updates.example/agentry-stable/releases/download/v1.0.29/Agentry.zip"
        ))
        let lookalikeRepositoryURL = try XCTUnwrap(URL(
            string: "https://updates.example/agentry-stable-evil/releases/download/v1/Agentry.zip"
        ))
        let queryURL = try XCTUnwrap(URL(
            string: "https://updates.example/agentry-stable/releases/download/v1/Agentry.zip?mirror=1"
        ))
        let insecureURL = try XCTUnwrap(URL(
            string: "http://updates.example/agentry-stable/releases/download/v1/Agentry.zip"
        ))
        let malformedDownloadURL = try XCTUnwrap(URL(
            string: "https://updates.example/agentry-stable/releases/download/v1"
        ))

        XCTAssertEqual(SparkleUpdaterManager.updateChannel(forAppcastItemURL: betaURL, infoDictionary: provisionedSparkleInfo), .beta)
        XCTAssertEqual(SparkleUpdaterManager.updateChannel(forAppcastItemURL: stableURL, infoDictionary: provisionedSparkleInfo), .stable)
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: lookalikeRepositoryURL, infoDictionary: provisionedSparkleInfo))
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: queryURL, infoDictionary: provisionedSparkleInfo))
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: insecureURL, infoDictionary: provisionedSparkleInfo))
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: malformedDownloadURL, infoDictionary: provisionedSparkleInfo))
        XCTAssertNil(SparkleUpdaterManager.updateChannel(forAppcastItemURL: nil, infoDictionary: provisionedSparkleInfo))
    }

    private var provisionedSparkleInfo: [String: Any] {
        [
            UpdateChannel.stableFeedInfoDictionaryKey:
                "https://updates.example/agentry-stable/releases/latest/download/appcast.xml",
            UpdateChannel.betaFeedInfoDictionaryKey:
                "https://updates.example/agentry-beta/releases/latest/download/appcast.xml",
            "SUFeedURL": "https://updates.example/agentry-stable/releases/latest/download/appcast.xml",
            "SUPublicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        ]
    }
}
