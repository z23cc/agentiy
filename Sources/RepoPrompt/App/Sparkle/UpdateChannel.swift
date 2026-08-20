import Foundation
import Sparkle

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    static let userDefaultsKey = "AgentryUpdateChannel"
    static let stableFeedInfoDictionaryKey = "AgentrySparkleStableFeedURL"
    static let betaFeedInfoDictionaryKey = "AgentrySparkleBetaFeedURL"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        }
    }

    var shortDescription: String {
        switch self {
        case .stable: "Curated releases only."
        case .beta: "Signed and notarized preview releases."
        }
    }

    var feedURLString: String {
        Self.feedURLString(for: self, infoDictionary: Bundle.main.infoDictionary)
    }

    static func feedURLString(
        for channel: UpdateChannel,
        infoDictionary: [String: Any]?
    ) -> String {
        let key = switch channel {
        case .stable: stableFeedInfoDictionaryKey
        case .beta: betaFeedInfoDictionaryKey
        }
        return (infoDictionary?[key] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func load(defaults: UserDefaults = .standard) -> UpdateChannel {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let channel = UpdateChannel(rawValue: rawValue)
        else {
            return .stable
        }
        return channel
    }

    static func store(_ channel: UpdateChannel, defaults: UserDefaults = .standard) {
        defaults.set(channel.rawValue, forKey: userDefaultsKey)
    }
}

final class SparkleUpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        let feedURL = UpdateChannel.load().feedURLString
        return feedURL.isEmpty ? nil : feedURL
    }
}
