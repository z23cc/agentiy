import Foundation

/// Product-wide identity authority for Agentry-owned filesystem locations and bundle identifiers.
///
/// This namespace intentionally has no instance state. Runtime components should derive product
/// roots from these values rather than duplicating names or probing pre-Agentry locations.
public enum AgentryProductIdentity {
    public static let displayName = "Agentry"
    public static let applicationSupportDirectoryName = "Agentry"
    public static let releaseBundleIdentifier = "io.github.z23cc.agentry"
    public static let debugBundleIdentifier = "io.github.z23cc.agentry.debug"

    public static func applicationSupportRootURL(fileManager: FileManager = .default) -> URL {
        let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupportDirectory
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    public static func temporaryRootURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }
}
