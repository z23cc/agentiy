import Darwin
import Foundation
import RepoPromptShared

/// Filesystem contract of the Agent Session Host (ADR-0011 decision 4; design §5.1, §7.2).
///
/// - socket: `/tmp/agentry-mcp-<uid>/agentry-agent-host-{D-}<protocolVersion>.sock`, the bootstrap
///   socket's directory and flavor naming rule, directory mode 0700.
/// - lease: `<Application Support>/Agentry/.agentry-domain-runtime/locks/agent-host-v1.lock`, one
///   `flock` per user; owner metadata beside it is diagnostic only.
/// - session logs: `AgentSession-<UUID>.events` / `.snapshot` inside each workspace's
///   `AgentSessions/` directory, beside the Swift-written `AgentSession-<UUID>.json`.
///
/// When `AGENTRY_APPLICATION_SUPPORT_ROOT` redirects Application Support (the test seam every other
/// runtime component honours), the socket moves into a per-root subdirectory of the same per-user
/// socket directory so an isolated host never collides with the developer's real one. The Rust host
/// binary of design §8 P7 must reproduce exactly these rules.
package struct AgentSessionHostPaths: Equatable {
    package static let leaseFileName = "agent-host-v1.lock"
    package static let leaseOwnerFileName = "agent-host-owner-v1.json"
    package static let workspacesDirectoryName = "Workspaces"
    package static let agentSessionsDirectoryName = "AgentSessions"

    package let applicationSupportRoot: URL
    package let buildFlavor: MCPFilesystemIdentity.BuildFlavor
    package let protocolVersion: UInt32
    package let socketDirectory: URL
    package let socketURL: URL
    package let lockDirectory: URL
    package let lockFileURL: URL
    package let ownerMetadataURL: URL
    package let workspacesRoot: URL

    package static var currentBuildFlavor: MCPFilesystemIdentity.BuildFlavor {
        #if DEBUG
            .debug
        #else
            .release
        #endif
    }

    package init(
        applicationSupportRoot: URL,
        buildFlavor: MCPFilesystemIdentity.BuildFlavor = Self.currentBuildFlavor,
        protocolVersion: UInt32,
        isolatedSocketDirectory: Bool = false,
        userID: uid_t = getuid()
    ) {
        let root = applicationSupportRoot.standardizedFileURL
        self.applicationSupportRoot = root
        self.buildFlavor = buildFlavor
        self.protocolVersion = protocolVersion

        let identity = MCPFilesystemIdentity.agentry(buildFlavor)
        var socketDirectory = identity.socketDirectoryURL(userID: userID)
        if isolatedSocketDirectory {
            let digest = DomainContentDigest.sha256(Data(root.path.utf8))
            socketDirectory = socketDirectory
                .appendingPathComponent("hosts", isDirectory: true)
                .appendingPathComponent(String(digest.prefix(12)), isDirectory: true)
        }
        self.socketDirectory = socketDirectory
        let flavorInfix = buildFlavor == .debug ? "D-" : ""
        socketURL = socketDirectory.appendingPathComponent(
            "agentry-agent-host-\(flavorInfix)\(protocolVersion).sock",
            isDirectory: false
        )

        lockDirectory = root
            .appendingPathComponent(".agentry-domain-runtime", isDirectory: true)
            .appendingPathComponent("locks", isDirectory: true)
        lockFileURL = lockDirectory.appendingPathComponent(Self.leaseFileName, isDirectory: false)
        ownerMetadataURL = lockDirectory.appendingPathComponent(Self.leaseOwnerFileName, isDirectory: false)
        workspacesRoot = root.appendingPathComponent(Self.workspacesDirectoryName, isDirectory: true)
    }

    /// Resolves the per-user paths for this process, honouring the Application Support override.
    package static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        buildFlavor: MCPFilesystemIdentity.BuildFlavor = Self.currentBuildFlavor,
        protocolVersion: UInt32
    ) -> AgentSessionHostPaths {
        let overrideKey = AgentryProductIdentity.applicationSupportRootOverrideEnvironmentKey
        let overridden = environment[overrideKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root: URL = if let overridden, !overridden.isEmpty {
            URL(fileURLWithPath: (overridden as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            AgentryProductIdentity.applicationSupportRootURL()
        }
        return AgentSessionHostPaths(
            applicationSupportRoot: root,
            buildFlavor: buildFlavor,
            protocolVersion: protocolVersion,
            isolatedSocketDirectory: overridden.map { !$0.isEmpty } ?? false
        )
    }

    /// `AgentSessions/` directory of one workspace. `workspaceID` is the opaque wire identifier and
    /// must be a single safe path component; the host never resolves paths that arrive on the wire.
    package func sessionDirectory(workspaceID: String) throws -> URL {
        guard Self.isSafePathComponent(workspaceID) else {
            throw AgentSessionHostPathError.invalidWorkspaceIdentifier(workspaceID)
        }
        return workspacesRoot
            .appendingPathComponent(workspaceID, isDirectory: true)
            .appendingPathComponent(Self.agentSessionsDirectoryName, isDirectory: true)
    }

    /// Prefers an existing `Workspace-{name}-{uuid}` folder so host logs land beside GUI JSON.
    package func resolvedSessionDirectory(workspaceID: String, fileManager: FileManager = .default) throws -> URL {
        let direct = try sessionDirectory(workspaceID: workspaceID)
        if fileManager.fileExists(atPath: direct.path) {
            return direct
        }
        if let uuid = UUID(uuidString: workspaceID),
           let named = existingNamedWorkspaceDirectory(containing: uuid, fileManager: fileManager)
        {
            return named.appendingPathComponent(Self.agentSessionsDirectoryName, isDirectory: true)
        }
        return direct
    }

    package func existingNamedWorkspaceDirectory(
        containing uuid: UUID,
        fileManager: FileManager = .default
    ) -> URL? {
        let needle = uuid.uuidString
        guard let workspaces = try? fileManager.contentsOfDirectory(
            at: workspacesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return workspaces.first { folder in
            let name = folder.lastPathComponent
            return name.caseInsensitiveCompare(needle) == .orderedSame
                || name.uppercased().hasSuffix("-\(needle.uppercased())")
        }
    }

    /// Every `AgentSessions/` directory currently on disk (restart recovery scan, design §7.3).
    package func existingSessionDirectories(fileManager: FileManager = .default) -> [URL] {
        guard let workspaces = try? fileManager.contentsOfDirectory(
            at: workspacesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return workspaces
            .map { $0.appendingPathComponent(Self.agentSessionsDirectoryName, isDirectory: true) }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    package static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, value != ".", value != ".." else { return false }
        return !value.contains("/") && !value.contains("\0") && !value.hasPrefix(".")
    }
}

package enum AgentSessionHostPathError: Error, Equatable {
    case invalidWorkspaceIdentifier(String)
    case socketPathTooLong(String)
}
