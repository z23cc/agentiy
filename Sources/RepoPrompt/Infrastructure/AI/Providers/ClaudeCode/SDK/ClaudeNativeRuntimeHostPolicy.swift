import Foundation

/// Host-owned policy facts consumed by the Rust-backed interactive Claude runtime.
///
/// This type deliberately contains only macOS/app concerns that must remain outside Rust: the
/// DEBUG raw-event-log switch/path and the existing RepoPrompt MCP auto-approval classifier. It
/// owns no process, wire, translation, or turn state.
enum ClaudeNativeRuntimeHostPolicy {
    private static let rawEventLogFilePathKey = "claudeRawEventLogFilePath"
    static let rawEventLoggingEnabledKey = "claudeRawEventLoggingEnabled"

    static func isRawEventFileLoggingEnabled(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
            defaults.bool(forKey: rawEventLoggingEnabledKey)
        #else
            false
        #endif
    }

    static func normalizedSessionIdentifier(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "unknown-session" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let normalized = String(scalars)
        return normalized.isEmpty ? "unknown-session" : normalized
    }

    static func makeRawEventLogFileURL(
        workspacePath _: String?,
        sessionID: String,
        defaults: UserDefaults = .standard
    ) -> URL? {
        let overridePath = defaults.string(forKey: rawEventLogFilePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseDirectory: URL = {
            if let overridePath, !overridePath.isEmpty {
                let expanded = NSString(string: overridePath).expandingTildeInPath
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
            return MCPFilesystemConstants.identity.temporaryRootURL()
                .appendingPathComponent("ClaudeRawEvents", isDirectory: true)
        }()
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = timestampFormatter.string(from: Date())
        let fileName = "claude-session-\(sessionID)-\(timestamp).jsonl"
        return baseDirectory.appendingPathComponent(fileName)
    }

    static func repoPromptPermissionAutoApprovalMatch(
        toolName: String,
        requestPayload: [String: Any]
    ) -> MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch? {
        MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
            requestToolName: toolName,
            requestPayload: requestPayload
        )
    }
}
