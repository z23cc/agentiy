import Foundation
import RepoPromptShared

/// Removes leftover workspace directory shells that were created before persistence
/// committed `workspace.json` and were never entered in the canonical catalog.
///
/// Launch runs this against the live Workspaces root so previous-install residue
/// (empty `Workspace-*` trees with only `_git_data` / `AgentSessions` / `Chats`)
/// is deleted instead of accumulating. Fail-closed: a readable catalog that
/// references a directory, a present `workspace.json`, extra top-level names, or
/// a corrupt catalog all skip deletion.
package enum WorkspaceOrphanShellPruner {
    package struct Report: Equatable, Sendable {
        package var removed: [URL]
        package var skippedBecauseCatalogUnreadable: Bool

        package init(removed: [URL] = [], skippedBecauseCatalogUnreadable: Bool = false) {
            self.removed = removed
            self.skippedBecauseCatalogUnreadable = skippedBecauseCatalogUnreadable
        }
    }

    private static let workspaceDirectoryPrefix = "Workspace-"
    private static let workspaceDocumentName = "workspace.json"
    private static let runtimeDirectoryName = ".agentry-domain-runtime"
    private static let catalogFileName = "workspace-catalog.json"
    private static let allowedShellChildNames: Set<String> = [
        "_git_data",
        "AgentSessions",
        "Chats",
        ".DS_Store"
    ]

    package static func defaultWorkspacesRoot(fileManager: FileManager = .default) -> URL {
        AgentryProductIdentity.applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent("Workspaces", isDirectory: true)
    }

    package static func prune(
        workspacesRoot: URL,
        fileManager: FileManager = .default
    ) -> Report {
        let root = workspacesRoot.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return Report()
        }

        let protected: Set<String>
        do {
            protected = try protectedWorkspaceDirectories(
                workspacesRoot: root,
                fileManager: fileManager
            )
        } catch {
            return Report(skippedBecauseCatalogUnreadable: true)
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return Report()
        }

        var removed: [URL] = []
        for child in children {
            let directory = child.standardizedFileURL
            guard isOrphanShell(
                directory: directory,
                protectedDirectories: protected,
                fileManager: fileManager
            ) else { continue }
            do {
                try fileManager.removeItem(at: directory)
                removed.append(directory)
            } catch {
                continue
            }
        }
        return Report(removed: removed)
    }

    private static func isOrphanShell(
        directory: URL,
        protectedDirectories: Set<String>,
        fileManager: FileManager
    ) -> Bool {
        let name = directory.lastPathComponent
        guard name.hasPrefix(workspaceDirectoryPrefix) else { return false }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }

        if protectedDirectories.contains(directory.path) {
            return false
        }

        let documentURL = directory.appendingPathComponent(workspaceDocumentName)
        if fileManager.fileExists(atPath: documentURL.path) {
            return false
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            return false
        }

        return contents.allSatisfy { allowedShellChildNames.contains($0.lastPathComponent) }
    }

    private static func protectedWorkspaceDirectories(
        workspacesRoot: URL,
        fileManager: FileManager
    ) throws -> Set<String> {
        let catalogURL = workspacesRoot
            .appendingPathComponent(runtimeDirectoryName, isDirectory: true)
            .appendingPathComponent(catalogFileName)
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            return []
        }
        let data = try Data(contentsOf: catalogURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogParseError.unreadable
        }
        guard let entries = json["entries"] as? [[String: Any]] else {
            throw CatalogParseError.unreadable
        }

        var protected: Set<String> = []
        for entry in entries {
            guard let fileURLValue = entry["fileURL"] as? String,
                  let directory = workspaceDirectory(fromCatalogFileURL: fileURLValue)
            else {
                throw CatalogParseError.unreadable
            }
            protected.insert(directory.path)
        }
        return protected
    }

    private static func workspaceDirectory(fromCatalogFileURL value: String) -> URL? {
        let documentURL: URL
        if let parsed = URL(string: value), parsed.isFileURL {
            documentURL = parsed
        } else if value.hasPrefix("/") {
            documentURL = URL(fileURLWithPath: value)
        } else {
            return nil
        }
        return documentURL.deletingLastPathComponent().standardizedFileURL
    }

    private enum CatalogParseError: Error {
        case unreadable
    }
}
