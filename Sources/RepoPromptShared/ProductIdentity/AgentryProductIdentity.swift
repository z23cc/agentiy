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

    /// Live user container (`~/Library/Application Support/Agentry`). Ignores XCTest
    /// auto-sandboxing and `AGENTRY_APPLICATION_SUPPORT_ROOT` so identity tests can
    /// assert the shipped path without writing to it.
    public static func canonicalApplicationSupportRootURL(fileManager: FileManager = .default) -> URL {
        let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupportDirectory
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    public static func isHostedXCTestSession(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }

    public static func applicationSupportRootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = resolvedOverrideURL(environment: environment) {
            return override
        }
        if isHostedXCTestSession(environment: environment) {
            return hostedXCTestApplicationSupportRoot(fileManager: fileManager)
        }
        return canonicalApplicationSupportRootURL(fileManager: fileManager)
    }

    private static func resolvedOverrideURL(environment: [String: String]) -> URL? {
        guard let override = environment[applicationSupportRootOverrideEnvironmentKey] else {
            return nil
        }
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(
            fileURLWithPath: (trimmed as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    private static func hostedXCTestApplicationSupportRoot(fileManager: FileManager) -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("agentry-xctest-support", isDirectory: true)
            .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func temporaryRootURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }
}
