import Foundation
import RepoPromptDomainRuntime

/// The app-side launch boundary for the single-use private-child carrier.
///
/// Every authority field is removed before adding the current task-local values so
/// nested providers cannot inherit a stale endpoint, identity, token, or run binding.
enum DomainChildLaunchEnvironmentBridge {
    private static let carrierKeys = DomainChildLaunchCarrier.environmentKeys

    static func mergingCurrentCarrier(
        into environment: [String: String]
    ) -> [String: String] {
        var merged = environment
        for key in carrierKeys {
            merged.removeValue(forKey: key)
        }
        guard let carrier = DomainChildLaunchContext.current else { return merged }
        for key in carrierKeys {
            if let value = carrier.environment[key], !value.isEmpty {
                merged[key] = value
            }
        }
        return merged
    }
}
