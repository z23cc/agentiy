import AgentryCoreBridge
import Foundation

/// Resolves the ADR-0011 P7 Rust `agent-host` binary.
///
/// The Swift MCP CLI product is also named `agentry-mcp`. Production never spawns that
/// product: the bundled helper is `agentry-agent-host`, and the Cargo artifact lives only
/// under `.build/cargo/` (or `rust/target/`).
package enum AgentSessionHostExecutable {
    package static let bundledHelperName = "agentry-agent-host"
    package static let cargoBinaryName = "agentry-mcp"
    package static let overrideEnvironmentKey = "AGENTRY_AGENT_HOST_EXECUTABLE"

    /// First existing Rust host on the spawn path, or `nil` if it has not been built/packaged.
    package static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment[overrideEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            let url = URL(fileURLWithPath: override)
            if isExecutable(url, fileManager: fileManager), isRustAgentHost(url) {
                return url
            }
        }

        if let bundled = Bundle.main.url(forAuxiliaryExecutable: bundledHelperName),
           isExecutable(bundled, fileManager: fileManager)
        {
            return bundled
        }

        let bundleFallback = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(bundledHelperName)")
        if isExecutable(bundleFallback, fileManager: fileManager) {
            return bundleFallback
        }

        for candidate in cargoCandidates(environment: environment) where isExecutable(candidate, fileManager: fileManager) {
            return candidate
        }
        return nil
    }

    package static func isRustAgentHost(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let path = url.standardizedFileURL.path
        if name == bundledHelperName {
            return true
        }
        guard name == cargoBinaryName else { return false }
        return path.contains("/.build/cargo/") || path.contains("/rust/target/")
    }

    package static func looksLikeSwiftMCPCLI(_ url: URL) -> Bool {
        url.lastPathComponent == cargoBinaryName && !isRustAgentHost(url)
    }

    private static func isExecutable(_ url: URL, fileManager: FileManager) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }

    private static func cargoCandidates(environment: [String: String]) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        func append(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            urls.append(url)
        }

        if let cargoDir = environment["CARGO_TARGET_DIR"], !cargoDir.isEmpty {
            for url in binaries(underCargoTarget: URL(fileURLWithPath: cargoDir, isDirectory: true)) {
                append(url)
            }
        }

        for root in searchRoots() {
            let cargo = root.appendingPathComponent(".build/cargo", isDirectory: true)
            for url in binaries(underCargoTarget: cargo) {
                append(url)
            }
            let rustTarget = root.appendingPathComponent("rust/target", isDirectory: true)
            for url in binaries(underCargoTarget: rustTarget) {
                append(url)
            }
        }
        return urls
    }

    private static func binaries(underCargoTarget cargo: URL) -> [URL] {
        let triples = ["aarch64-apple-darwin", ""]
        let profiles = ["debug", "release"]
        var urls: [URL] = []
        for triple in triples {
            for profile in profiles {
                var cursor = cargo
                if !triple.isEmpty {
                    cursor = cursor.appendingPathComponent(triple, isDirectory: true)
                }
                urls.append(cursor.appendingPathComponent(profile, isDirectory: true).appendingPathComponent(cargoBinaryName))
            }
        }
        return urls
    }

    private static func searchRoots() -> [URL] {
        var roots: [URL] = []
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            if !roots.contains(where: { $0.path == standardized.path }) {
                roots.append(standardized)
            }
        }
        add(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        var cursor = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0 ..< 10 {
            add(cursor)
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path {
                break
            }
            cursor = parent
        }
        return roots
    }
}

/// Environment overlays for spawning `agentry-mcp agent-host`.
///
/// Production must set `AGENTRY_AGENT_HOST_LIVE` so Claude/Codex/ACP do not fall through to
/// `ScriptedTransport` echo. Tests force live off and stamp the UniFFI build fingerprint so
/// the Rust host's Welcome matches the Swift client's Hello.
package enum AgentSessionHostLaunchEnvironment {
    package static let liveFlagKey = "AGENTRY_AGENT_HOST_LIVE"
    package static let fingerprintKey = "AGENTRY_HOST_BUILD_FINGERPRINT"
    package static let fingerprintAliasKey = "AGENTRY_CORE_BUILD_FINGERPRINT"
    package static let acceptAnyPeerKey = "AGENTRY_AGENT_HOST_ACCEPT_ANY_PEER"
    package static let workingDirectoryKey = "AGENTRY_AGENT_HOST_WORKING_DIRECTORY"
    package static let requireCredentialKey = "AGENTRY_AGENT_HOST_REQUIRE_CREDENTIAL"
    /// Instructs host-arranged Agentry MCP children to use `--backend auto` (P8).
    package static let mcpBackendKey = "AGENTRY_AGENT_HOST_MCP_BACKEND"

    /// Inherited process environment plus live I/O and the GUI's core fingerprint.
    /// Secrets stay in the inherited environment; this overlay never enables Keychain.
    package static func production(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment[liveFlagKey] = "1"
        environment[fingerprintKey] = CoreBuildIdentity.buildFingerprint
        environment[fingerprintAliasKey] = CoreBuildIdentity.buildFingerprint
        environment[mcpBackendKey] = "auto"
        environment.removeValue(forKey: "AGENTRY_AGENT_HOST_READ_KEYCHAIN")
        environment.removeValue(forKey: acceptAnyPeerKey)
        return environment
    }

    /// Isolated-host test overlay: scripted transport, any-peer, matching fingerprint.
    package static func testProcess(from base: [String: String]) -> [String: String] {
        var environment = base
        environment[liveFlagKey] = "0"
        environment[fingerprintKey] = CoreBuildIdentity.buildFingerprint
        environment[fingerprintAliasKey] = CoreBuildIdentity.buildFingerprint
        environment[acceptAnyPeerKey] = "1"
        return environment
    }
}
