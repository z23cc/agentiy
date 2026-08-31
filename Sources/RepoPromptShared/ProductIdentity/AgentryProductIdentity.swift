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

    /// Environment variable that redirects every Application Support read/write.
    ///
    /// Exists so tests can be given a scratch root instead of the developer's real
    /// container. Without it the XCTest suite creates workspaces, domain-runtime
    /// state, and Codex state directly in `~/Library/Application Support/Agentry`
    /// and never cleans them up.
    public static let applicationSupportRootOverrideEnvironmentKey = "AGENTRY_APPLICATION_SUPPORT_ROOT"

    public static func applicationSupportRootURL(fileManager: FileManager = .default) -> URL {
        if let override = ProcessInfo.processInfo.environment[applicationSupportRootOverrideEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
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
