//
//  SparkleUpdateManager.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-28.
//

import Combine
import CryptoKit
import Sparkle
import SwiftUI

#if DEBUG
    private var sparkleUpdaterManagerDebugLoggingEnabled = false
    private func sparkleUpdaterManagerDebugLog(_ message: @autoclosure () -> String) {
        guard sparkleUpdaterManagerDebugLoggingEnabled else { return }
        print("[SparkleUpdaterManager] \(message())")
    }
#else
    private func sparkleUpdaterManagerDebugLog(_ message: @autoclosure () -> String) {}
#endif

/// Class to monitor updates and provide UI notifications
final class SparkleUpdaterManager: ObservableObject {
    /// Singleton instance - set by AppDelegate on launch
    static var shared: SparkleUpdaterManager!
    static let unprovisionedConfigurationMessage =
        "Agentry update configuration is not provisioned. Update checks are disabled."
    private static let legacyRepoPromptPublicEdKeySHA256 =
        "baffc4fc73168247f232f8f9d79d09abfdfca5c0b46651ccf78f436e17e2cdee"

    private struct CanonicalURL: Hashable {
        let scheme: String
        let host: String
        let port: Int?
        let path: String
    }

    private struct AcceptedSparkleConfiguration {
        let channel: UpdateChannel
        let feed: CanonicalURL
        let publicEdKey: String
    }

    private struct AppcastUpdateInfo {
        let latestVersion: String
        let latestBuildNumber: String?
        let title: String?
        let date: Date?
        let releaseNotes: String?
    }

    private static func canonicalizeFeedURL(_ raw: String) -> CanonicalURL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              !url.path.isEmpty
        else { return nil }

        // Normalize trailing slash
        var path = url.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        return CanonicalURL(scheme: "https", host: host, port: nil, path: path)
    }

    private static func acceptedConfigurations(
        infoDictionary: [String: Any]
    ) -> [AcceptedSparkleConfiguration] {
        guard let publicEdKey = configuredString("SUPublicEDKey", in: infoDictionary) else { return [] }
        return UpdateChannel.allCases.compactMap { channel in
            let rawFeed = UpdateChannel.feedURLString(for: channel, infoDictionary: infoDictionary)
            guard let canonical = canonicalizeFeedURL(rawFeed) else { return nil }
            return AcceptedSparkleConfiguration(
                channel: channel,
                feed: canonical,
                publicEdKey: publicEdKey
            )
        }
    }

    private static func configuredString(_ key: String, in infoDictionary: [String: Any]) -> String? {
        guard let value = infoDictionary[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("__"),
              !trimmed.hasSuffix("__")
        else { return nil }
        return trimmed
    }

    private static func isLegacyRepoPromptFeed(_ feed: CanonicalURL) -> Bool {
        guard feed.host == "github.com" else { return false }
        let normalizedPath = feed.path.lowercased()
        return normalizedPath.hasPrefix("/repoprompt/repoprompt-ce-updates/") ||
            normalizedPath.hasPrefix("/repoprompt/repoprompt-ce-tip-updates/")
    }

    private static func isValidPublicEdKey(
        _ value: String,
        rejectedPublicEdKeySHA256: String
    ) -> Bool {
        let digest = SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return digest != rejectedPublicEdKeySHA256 && Data(base64Encoded: value)?.count == 32
    }

    static func validateSparkleConfiguration(
        infoDictionary: [String: Any],
        selectedChannel: UpdateChannel
    ) -> (isValid: Bool, message: String?) {
        validateSparkleConfiguration(
            infoDictionary: infoDictionary,
            selectedChannel: selectedChannel,
            rejectedPublicEdKeySHA256: legacyRepoPromptPublicEdKeySHA256
        )
    }

    private static func validateSparkleConfiguration(
        infoDictionary: [String: Any],
        selectedChannel: UpdateChannel,
        rejectedPublicEdKeySHA256: String
    ) -> (isValid: Bool, message: String?) {
        let stableRaw = UpdateChannel.feedURLString(for: .stable, infoDictionary: infoDictionary)
        let betaRaw = UpdateChannel.feedURLString(for: .beta, infoDictionary: infoDictionary)
        guard let publicEdKey = configuredString("SUPublicEDKey", in: infoDictionary),
              configuredString(UpdateChannel.stableFeedInfoDictionaryKey, in: infoDictionary) != nil,
              configuredString(UpdateChannel.betaFeedInfoDictionaryKey, in: infoDictionary) != nil,
              let standardFeedRaw = configuredString("SUFeedURL", in: infoDictionary)
        else {
            return (false, unprovisionedConfigurationMessage)
        }

        guard isValidPublicEdKey(
            publicEdKey,
            rejectedPublicEdKeySHA256: rejectedPublicEdKeySHA256
        ),
            let stableFeed = canonicalizeFeedURL(stableRaw),
            let betaFeed = canonicalizeFeedURL(betaRaw),
            let standardFeed = canonicalizeFeedURL(standardFeedRaw),
            stableFeed != betaFeed,
            standardFeed == stableFeed,
            !isLegacyRepoPromptFeed(stableFeed),
            !isLegacyRepoPromptFeed(betaFeed)
        else {
            return (false, unprovisionedConfigurationMessage)
        }

        let selectedRaw = UpdateChannel.feedURLString(for: selectedChannel, infoDictionary: infoDictionary)
        guard let selectedFeed = canonicalizeFeedURL(selectedRaw) else {
            return (false, unprovisionedConfigurationMessage)
        }
        let accepted = acceptedConfigurations(infoDictionary: infoDictionary)
        guard accepted.count == UpdateChannel.allCases.count,
              accepted.contains(where: {
                  $0.channel == selectedChannel && $0.feed == selectedFeed && $0.publicEdKey == publicEdKey
              })
        else {
            return (false, unprovisionedConfigurationMessage)
        }

        return (true, nil)
    }

    /// Cleans corrupt Sparkle preferences that may cause crashes
    /// Call this BEFORE initializing SPUStandardUpdaterController
    static func cleanCorruptPreferences() {
        let versionKeys = ["SUSkippedVersion", "SUSkippedMinorVersion"]
        for key in versionKeys {
            if let value = UserDefaults.standard.object(forKey: key), !(value is String) {
                UserDefaults.standard.removeObject(forKey: key)
                sparkleUpdaterManagerDebugLog("Removed corrupt preference '\(key)': was \(type(of: value)), expected String")
            }
        }
    }

    private let updaterController: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()
    private var updaterStarted = false
    private var periodicCheckTimer: Timer?
    private var appcastCheckTask: Task<AppcastUpdateInfo?, Never>?
    private var activeAppcastCheckRequest: AppcastCheckRequestIdentity?
    private var userInitiatedObserverState = SparkleUserInitiatedObserverState()
    private var userCheckResetWorkItem: DispatchWorkItem?
    private let httpClient: HTTPClient = DefaultHTTPClient.uiCriticalClient

    /// How often to check for updates (12 hours in seconds)
    private static let updateCheckInterval: TimeInterval = 12 * 60 * 60

    /// UserDefaults key for last passive appcast check timestamp
    private static let lastCheckKey = "SparkleLastUpdateCheck"

    /// UserDefaults key for Agentry's passive appcast-check preference.
    private static let passiveAppcastChecksKey = "AgentryPassiveAppcastChecksEnabled"

    /// Expose updater for settings UI
    var updater: SPUUpdater {
        updaterController.updater
    }

    @Published var canCheckForUpdates = false
    @Published private(set) var availableUpdate: AvailableUpdateNotice?
    @Published private(set) var sparkleConfigurationValid = true
    @Published private(set) var updatesDisabledMessage: String? = nil
    @Published private(set) var updateChannel: UpdateChannel

    /// Compatibility projections for diagnostics and callers. The notice
    /// remains the sole authority for update identity and presentation.
    var updateAvailable: Bool {
        availableUpdate != nil
    }

    var updateVersion: String? {
        availableUpdate?.version
    }

    var updateBuildNumber: String? {
        availableUpdate?.buildNumber
    }

    var updateDate: Date? {
        availableUpdate?.date
    }

    var updateDescription: String? {
        availableUpdate?.releaseNotes
    }

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: Self.passiveAppcastChecksKey)
            forceSparkleAutomaticChecksOff()
            if automaticallyChecksForUpdates {
                setupPeriodicUpdateCheck()
            } else {
                periodicCheckTimer?.invalidate()
                periodicCheckTimer = nil
                invalidateActiveAppcastCheck()
            }
        }
    }

    init(updaterController: SPUStandardUpdaterController) {
        self.updaterController = updaterController
        updateChannel = UpdateChannel.load()
        automaticallyChecksForUpdates = Self.loadPassiveAppcastChecksPreference(
            defaultingTo: updaterController.updater.automaticallyChecksForUpdates
        )
        UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: Self.passiveAppcastChecksKey)
        updaterController.updater.automaticallyChecksForUpdates = false

        let validation = Self.validateSparkleConfiguration(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            selectedChannel: updateChannel
        )
        sparkleConfigurationValid = validation.isValid
        updatesDisabledMessage = validation.message

        if !sparkleConfigurationValid {
            disableUpdatesForIntegrityFailure()
        }
    }

    func startUpdater() {
        guard sparkleConfigurationValid, !updaterStarted else { return }

        // Install observers before activation so no Sparkle event can race registration.
        setupObservers()
        updaterController.startUpdater()
        updaterStarted = true
        forceSparkleAutomaticChecksOff()
        canCheckForUpdates = updaterController.updater.canCheckForUpdates

        // Schedule a background check after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.performInitialUpdateCheck()
        }

        // Setup periodic passive update checking if enabled.
        setupPeriodicUpdateCheck()
    }

    private static func loadPassiveAppcastChecksPreference(defaultingTo sparkleAutomaticChecks: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: passiveAppcastChecksKey) != nil {
            return UserDefaults.standard.bool(forKey: passiveAppcastChecksKey)
        }
        return sparkleAutomaticChecks
    }

    deinit {
        periodicCheckTimer?.invalidate()
        appcastCheckTask?.cancel()
        userCheckResetWorkItem?.cancel()
    }

    /// Performs initial passive update check using appcast parsing only.
    private func performInitialUpdateCheck() {
        guard updaterStarted, sparkleConfigurationValid, automaticallyChecksForUpdates else { return }
        Task {
            await performPassiveAppcastCheck()
        }
    }

    /// Sets up a timer to periodically check for updates
    private func setupPeriodicUpdateCheck() {
        periodicCheckTimer?.invalidate()
        periodicCheckTimer = nil
        guard updaterStarted, sparkleConfigurationValid, automaticallyChecksForUpdates else { return }
        forceSparkleAutomaticChecksOff()
        // Check if we need to do an immediate check based on last check time
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        let timeSinceLastCheck = now - lastCheck

        if lastCheck == 0 || timeSinceLastCheck >= Self.updateCheckInterval {
            // Either first run or enough time has passed, check now
            Task {
                await performPassiveAppcastCheck()
            }
        }

        // Schedule periodic passive checks every 12 hours using appcast parsing only.
        periodicCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.updateCheckInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.performPassiveAppcastCheck()
            }
        }
    }

    @discardableResult
    private func performPassiveAppcastCheck() async -> Bool {
        await Self.performPassiveAppcastCheck {
            await self.checkAppcastDirectly()
        }
    }

    @discardableResult
    static func performPassiveAppcastCheck(
        check: () async -> Bool,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) async -> Bool {
        let succeeded = await check()
        if succeeded {
            defaults.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
        }
        return succeeded
    }

    /// Directly fetches and parses the appcast.xml to check for updates.
    /// Returns true only when the appcast fetch and parse produced update info.
    @discardableResult
    func checkAppcastDirectly() async -> Bool {
        guard updaterStarted, sparkleConfigurationValid, userInitiatedObserverState.activeRequest == nil else {
            return false
        }

        let checkedChannel = updateChannel
        let requestIdentity = AppcastCheckRequestIdentity(channel: checkedChannel)
        let feedURL = checkedChannel.feedURLString
        guard let url = URL(string: feedURL) else {
            sparkleUpdaterManagerDebugLog("Invalid update feed URL for channel \(checkedChannel.rawValue): \(feedURL)")
            return false
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let currentBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let client = httpClient
        invalidateActiveAppcastCheck()
        activeAppcastCheckRequest = requestIdentity
        let task = Task.detached(priority: .utility) {
            await Self.fetchAndParseAppcast(feedURL: url, httpClient: client)
        }
        appcastCheckTask = task
        let appcastInfo = await task.value

        return await MainActor.run {
            guard Self.appcastResultIsCurrent(
                request: requestIdentity,
                activeRequest: self.activeAppcastCheckRequest,
                selectedChannel: self.updateChannel
            ), self.userInitiatedObserverState.activeRequest == nil else {
                sparkleUpdaterManagerDebugLog("Discarding stale appcast result for channel \(checkedChannel.rawValue)")
                return false
            }

            defer {
                self.activeAppcastCheckRequest = nil
                self.appcastCheckTask = nil
            }

            guard !task.isCancelled else { return false }
            self.apply(
                appcastInfo: appcastInfo,
                currentVersion: currentVersion,
                currentBuildNumber: currentBuildNumber,
                checkedChannel: checkedChannel
            )
            return appcastInfo != nil
        }
    }

    static func appcastResultIsCurrent(
        request: AppcastCheckRequestIdentity,
        activeRequest: AppcastCheckRequestIdentity?,
        selectedChannel: UpdateChannel
    ) -> Bool {
        request == activeRequest && request.channel == selectedChannel
    }

    static func updateChannel(
        forAppcastItemURL url: URL?,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> UpdateChannel? {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else { return nil }

        return UpdateChannel.allCases.first { channel in
            let feedURLString = UpdateChannel.feedURLString(for: channel, infoDictionary: infoDictionary)
            guard let feedURL = URL(string: feedURLString),
                  feedURL.scheme?.lowercased() == url.scheme?.lowercased(),
                  feedURL.host?.lowercased() == url.host?.lowercased(),
                  feedURL.port == url.port,
                  let releasesRange = feedURL.path.range(of: "/releases/")
            else { return false }

            let repositoryPath = String(feedURL.path[..<releasesRange.lowerBound])
            let downloadPrefix = "\(repositoryPath)/releases/download/"
            guard url.path.hasPrefix(downloadPrefix) else { return false }
            let downloadComponents = url.path
                .dropFirst(downloadPrefix.count)
                .split(separator: "/", omittingEmptySubsequences: false)
            return downloadComponents.count == 2 && downloadComponents.allSatisfy { !$0.isEmpty }
        }
    }

    static func makePassiveAppcastRequest(feedURL: URL) -> URLRequest {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    static func testFetchAndParseAppcastVersion(feedURL: URL, httpClient: HTTPClient) async -> String? {
        await fetchAndParseAppcast(feedURL: feedURL, httpClient: httpClient)?.latestVersion
    }

    private static func fetchAndParseAppcast(feedURL: URL, httpClient: HTTPClient) async -> AppcastUpdateInfo? {
        let request = makePassiveAppcastRequest(feedURL: feedURL)

        do {
            guard !Task.isCancelled else { return nil }
            let response = try await httpClient.data(for: request)
            guard response.http.statusCode == 200 else {
                sparkleUpdaterManagerDebugLog("Failed to fetch appcast: \(response.http.statusCode)")
                return nil
            }
            guard !Task.isCancelled else { return nil }
            let data = response.data
            return await Task.detached(priority: .utility) {
                let parser = AppcastParser()
                guard let latestVersion = parser.parse(data: data) else {
                    sparkleUpdaterManagerDebugLog("Failed to parse appcast - no versions found")
                    return nil
                }
                return AppcastUpdateInfo(
                    latestVersion: latestVersion.version,
                    latestBuildNumber: latestVersion.buildNumber,
                    title: latestVersion.title,
                    date: latestVersion.date,
                    releaseNotes: latestVersion.releaseNotesURL ?? latestVersion.description
                )
            }.value
        } catch {
            sparkleUpdaterManagerDebugLog("Failed to fetch/parse appcast: \(error)")
            return nil
        }
    }

    @MainActor
    private func apply(
        appcastInfo: AppcastUpdateInfo?,
        currentVersion: String,
        currentBuildNumber: String,
        checkedChannel: UpdateChannel
    ) {
        guard let appcastInfo else {
            sparkleUpdaterManagerDebugLog("Appcast check failed; preserving previous update state")
            return
        }

        let isNewer = appcastInfo.latestBuildNumber.flatMap { latestBuild in
            isBuildNumber(latestBuild, newerThan: currentBuildNumber)
        } ?? isVersion(appcastInfo.latestVersion, newerThan: currentVersion)

        if isNewer {
            let presentationVersion = Self.presentationVersion(
                channel: checkedChannel,
                displayVersion: appcastInfo.latestVersion,
                title: appcastInfo.title
            )
            applyAvailableUpdateState(
                channel: checkedChannel,
                version: presentationVersion,
                buildNumber: appcastInfo.latestBuildNumber,
                shortCommitSHA: AvailableUpdateNotice.shortCommitSHA(fromBetaTitle: appcastInfo.title),
                date: appcastInfo.date,
                description: appcastInfo.releaseNotes
            )
            sparkleUpdaterManagerDebugLog("Update available: \(appcastInfo.latestVersion) build \(appcastInfo.latestBuildNumber ?? "<missing>") (current: \(currentVersion) build \(currentBuildNumber))")
        } else {
            clearUpdateState()
            sparkleUpdaterManagerDebugLog("No update available. Current: \(currentVersion) build \(currentBuildNumber), Latest: \(appcastInfo.latestVersion) build \(appcastInfo.latestBuildNumber ?? "<missing>")")
        }
    }

    /// Compares two version strings to determine if the first is newer than the second
    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let v1Components = v1.split(separator: ".").compactMap { Int($0) }
        let v2Components = v2.split(separator: ".").compactMap { Int($0) }

        let maxLength = max(v1Components.count, v2Components.count)

        for i in 0 ..< maxLength {
            let v1Part = i < v1Components.count ? v1Components[i] : 0
            let v2Part = i < v2Components.count ? v2Components[i] : 0

            if v1Part > v2Part { return true }
            if v1Part < v2Part { return false }
        }
        return false
    }

    private func isBuildNumber(_ lhs: String, newerThan rhs: String) -> Bool? {
        guard let lhsValue = SparkleBuildVersion(lhs),
              let rhsValue = SparkleBuildVersion(rhs)
        else { return nil }
        return lhsValue > rhsValue
    }

    private func setupObservers() {
        // Observe canCheckForUpdates changes
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in
                DispatchQueue.main.async { [weak self] in
                    guard let self, canCheckForUpdates != canCheck else { return }
                    canCheckForUpdates = canCheck
                }
            }
            .store(in: &cancellables)

        // Sparkle notifications do not carry a request token we can correlate with
        // user-initiated cycles. Positive results are safe to apply only for the
        // selected channel and may not downgrade a newer known build. A no-update
        // result is never allowed to clear a notice or finish a request.
        NotificationCenter.default.publisher(for: .init("SUUpdaterDidFindValidUpdateNotification"))
            .sink { [weak self] notification in
                guard let appcastItem = notification.userInfo?[SUUpdaterAppcastItemNotificationKey] as? SUAppcastItem else { return }

                DispatchQueue.main.async {
                    guard let self,
                          let resultChannel = Self.updateChannel(forAppcastItemURL: appcastItem.fileURL),
                          resultChannel == self.updateChannel,
                          Self.sparkleResultIsNotOlderThanKnownUpdate(
                              candidateBuildNumber: appcastItem.versionString,
                              knownBuildNumber: self.availableUpdate?.buildNumber
                          )
                    else {
                        sparkleUpdaterManagerDebugLog("Discarding mismatched or older Sparkle update result")
                        return
                    }

                    self.applyAvailableUpdateState(
                        channel: resultChannel,
                        version: Self.presentationVersion(
                            channel: resultChannel,
                            displayVersion: appcastItem.displayVersionString,
                            title: appcastItem.title
                        ),
                        buildNumber: appcastItem.versionString,
                        shortCommitSHA: AvailableUpdateNotice.shortCommitSHA(fromBetaTitle: appcastItem.title),
                        date: appcastItem.date,
                        description: appcastItem.releaseNotesURL?.absoluteString ?? appcastItem.itemDescription
                    )
                    if let request = self.userInitiatedObserverState.requestToSettle(
                        afterPositiveResultFor: resultChannel
                    ) {
                        self.scheduleUserInitiatedSparkleCheckReset(for: request, after: 0)
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .init("SUUpdaterDidNotFindUpdateNotification"))
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch self.userInitiatedObserverState.receiveUncorrelatedNoUpdate() {
                    case .preserveNoticeAndRequest:
                        sparkleUpdaterManagerDebugLog("Ignoring uncorrelatable Sparkle no-update result; preserving notice and request state")
                    }
                }
            }
            .store(in: &cancellables)

        // Listen for app restart notifications
        NotificationCenter.default.publisher(for: .init("SUUpdaterWillRestartNotification"))
            .sink { _ in
                sparkleUpdaterManagerDebugLog("Sparkle is about to restart the application for update installation")
                NotificationCenter.default.post(name: .appWillRestartForUpdate, object: nil)
            }
            .store(in: &cancellables)
    }

    static func sparkleResultIsNotOlderThanKnownUpdate(
        candidateBuildNumber: String,
        knownBuildNumber: String?
    ) -> Bool {
        guard let knownBuildNumber,
              let knownBuild = SparkleBuildVersion(knownBuildNumber)
        else { return true }
        guard let candidateBuild = SparkleBuildVersion(candidateBuildNumber) else { return false }
        return candidateBuild >= knownBuild
    }

    static func presentationVersion(
        channel: UpdateChannel,
        displayVersion: String,
        title: String?
    ) -> String {
        let fallbackVersion = sanitizeVersionString(displayVersion)
        guard channel == .beta else { return fallbackVersion }
        return AvailableUpdateNotice.marketingVersion(fromBetaTitle: title) ?? fallbackVersion
    }

    static func sanitizeVersionString(_ version: String) -> String {
        var version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.lowercased().hasPrefix("beta build") {
            version.removeFirst("beta build".count)
            version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if version.lowercased().hasPrefix("v") {
            version.removeFirst()
        }
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return version.components(separatedBy: allowedCharacters.inverted).joined()
    }

    private func applyAvailableUpdateState(
        channel: UpdateChannel,
        version: String,
        buildNumber: String?,
        shortCommitSHA: String?,
        date: Date?,
        description: String?
    ) {
        let notice = AvailableUpdateNotice(
            channel: channel,
            version: version,
            buildNumber: buildNumber,
            shortCommitSHA: shortCommitSHA,
            date: date,
            releaseNotes: description
        )
        if availableUpdate != notice {
            availableUpdate = notice
        }
    }

    private func clearUpdateState() {
        if availableUpdate != nil {
            availableUpdate = nil
        }
    }

    private func invalidateActiveAppcastCheck() {
        appcastCheckTask?.cancel()
        appcastCheckTask = nil
        activeAppcastCheckRequest = nil
    }

    func setUpdateChannel(_ channel: UpdateChannel) {
        guard updateChannel != channel else { return }
        invalidateActiveAppcastCheck()
        if userInitiatedObserverState.activeRequest == nil,
           updaterController.updater.sessionInProgress
        {
            let request = userInitiatedObserverState.begin(channel: updateChannel)
            scheduleUserInitiatedSparkleCheckReset(for: request)
        }
        updateChannel = channel
        UpdateChannel.store(channel)
        clearUpdateState()
        updaterController.updater.resetUpdateCycle()
        setupPeriodicUpdateCheck()
    }

    func checkForUpdates(silent: Bool = false) {
        guard updaterStarted, sparkleConfigurationValid else { return }
        if silent {
            // Passive checks are appcast-only by design; Sparkle UI remains user-initiated.
            guard automaticallyChecksForUpdates else { return }
            Task {
                await performPassiveAppcastCheck()
            }
        } else {
            beginUserInitiatedSparkleCheck()
        }
    }

    func installUpdate() {
        guard updaterStarted, sparkleConfigurationValid else { return }
        beginUserInitiatedSparkleCheck()
    }

    private func beginUserInitiatedSparkleCheck() {
        if let activeRequest = userInitiatedObserverState.activeRequest {
            guard !updaterController.updater.sessionInProgress else { return }
            finishUserInitiatedSparkleCheck(request: activeRequest)
        }

        invalidateActiveAppcastCheck()

        let request = userInitiatedObserverState.begin(channel: updateChannel)
        scheduleUserInitiatedSparkleCheckReset(for: request)
        updaterController.checkForUpdates(nil)
    }

    private func finishUserInitiatedSparkleCheck(request: SparkleUserInitiatedObserverState.Request) {
        guard userInitiatedObserverState.finish(request: request) else { return }
        userCheckResetWorkItem?.cancel()
        userCheckResetWorkItem = nil
    }

    private func cancelUserInitiatedSparkleCheck() {
        userInitiatedObserverState.cancel()
        userCheckResetWorkItem?.cancel()
        userCheckResetWorkItem = nil
    }

    private func scheduleUserInitiatedSparkleCheckReset(
        for request: SparkleUserInitiatedObserverState.Request,
        after delay: TimeInterval = 300
    ) {
        userCheckResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  userInitiatedObserverState.activeRequest == request
            else { return }
            if updaterController.updater.sessionInProgress {
                scheduleUserInitiatedSparkleCheckReset(for: request, after: 5)
            } else {
                finishUserInitiatedSparkleCheck(request: request)
            }
        }
        userCheckResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func forceSparkleAutomaticChecksOff() {
        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.automaticallyChecksForUpdates = false
        }
    }

    // MARK: - Sparkle Integrity

    private func disableUpdatesForIntegrityFailure() {
        clearUpdateState()
        cancelUserInitiatedSparkleCheck()
        canCheckForUpdates = false
        automaticallyChecksForUpdates = false
        updaterController.updater.automaticallyChecksForUpdates = false

        // Ensure there is always a user-visible reason if we disable updates
        if updatesDisabledMessage == nil {
            updatesDisabledMessage = Self.unprovisionedConfigurationMessage
        }
    }
}

#if DEBUG
    extension SparkleUpdaterManager {
        static var debugLastCheckKey: String {
            lastCheckKey
        }

        static var debugPassiveAppcastChecksKey: String {
            passiveAppcastChecksKey
        }

        static var debugExpectedFeedURL: String {
            UpdateChannel.stable.feedURLString
        }

        static var debugBetaFeedURL: String {
            UpdateChannel.beta.feedURLString
        }

        static func debugFeedURLMatchesExpected(_ raw: String) -> Bool {
            guard let canonical = canonicalizeFeedURL(raw) else { return false }
            return acceptedConfigurations(infoDictionary: Bundle.main.infoDictionary ?? [:])
                .contains { $0.feed == canonical }
        }

        static func debugValidateSparkleConfiguration(
            infoDictionary: [String: Any],
            selectedChannel: UpdateChannel,
            rejectedPublicEdKeySHA256: String
        ) -> (isValid: Bool, message: String?) {
            validateSparkleConfiguration(
                infoDictionary: infoDictionary,
                selectedChannel: selectedChannel,
                rejectedPublicEdKeySHA256: rejectedPublicEdKeySHA256
            )
        }

        static func debugIsVersion(_ lhs: String, newerThan rhs: String) -> Bool {
            let lhsComponents = lhs.split(separator: ".").compactMap { Int($0) }
            let rhsComponents = rhs.split(separator: ".").compactMap { Int($0) }
            let maxLength = max(lhsComponents.count, rhsComponents.count)

            for index in 0 ..< maxLength {
                let lhsPart = index < lhsComponents.count ? lhsComponents[index] : 0
                let rhsPart = index < rhsComponents.count ? rhsComponents[index] : 0
                if lhsPart > rhsPart { return true }
                if lhsPart < rhsPart { return false }
            }
            return false
        }

        @MainActor
        func debugPublishedSnapshot() -> [String: Any] {
            var snapshot: [String: Any] = [
                "sparkle_configuration_valid": sparkleConfigurationValid,
                "selected_update_channel": updateChannel.rawValue,
                "active_feed_url": updateChannel.feedURLString,
                "accepted_feed_urls": UpdateChannel.allCases.map(\.feedURLString),
                "updater_started": updaterStarted,
                "updates_disabled_message": updatesDisabledMessage ?? NSNull(),
                "can_check_for_updates": canCheckForUpdates,
                "sparkle_can_check_for_updates": updaterController.updater.canCheckForUpdates,
                "passive_appcast_checks_enabled": automaticallyChecksForUpdates,
                "sparkle_automatically_checks_for_updates": updaterController.updater.automaticallyChecksForUpdates,
                "update_available": updateAvailable,
                "update_version": updateVersion ?? NSNull(),
                "update_build_number": updateBuildNumber ?? NSNull(),
                "update_date_present": updateDate != nil,
                "update_description_present": updateDescription != nil,
                "appcast_task_present": appcastCheckTask != nil
            ]
            if let updateDate {
                snapshot["update_date_epoch"] = updateDate.timeIntervalSince1970
            } else {
                snapshot["update_date_epoch"] = NSNull()
            }
            if let appcastCheckTask {
                snapshot["appcast_task_cancelled"] = appcastCheckTask.isCancelled
            } else {
                snapshot["appcast_task_cancelled"] = NSNull()
            }
            return snapshot
        }

        @discardableResult
        func debugTriggerPassiveCheck() async -> Bool {
            await performPassiveAppcastCheck()
        }
    }
#endif
