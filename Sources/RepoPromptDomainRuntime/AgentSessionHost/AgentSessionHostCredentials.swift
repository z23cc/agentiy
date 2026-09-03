import Foundation

/// Runtime credential overlay for the Agent Session Host (ADR-0011 addendum 2026-09-03).
///
/// Secrets reach the host only via: (a) a 0600 one-shot envelope file plus `envelopeID` on
/// `Start`/`SessionSpec` — the host redeems, zeros, and deletes; (b) the already-present
/// process environment inherited from the GUI/CLI spawn (never logged). There is no Keychain
/// path. Missing required secrets fail closed.
package enum AgentSessionHostCredentials {
    package static let envelopeDirectoryName = "envelopes"

    package static func envelopeDirectory(applicationSupportRoot: URL) -> URL {
        applicationSupportRoot
            .appendingPathComponent(".agentry-domain-runtime", isDirectory: true)
            .appendingPathComponent(envelopeDirectoryName, isDirectory: true)
    }

    /// Publishes one-shot envelope bytes for a host in another process. Portable for debug and release.
    package static func publishEnvelope(
        envelopeID: UUID,
        bytes: Data,
        applicationSupportRoot: URL
    ) throws {
        let directory = envelopeDirectory(applicationSupportRoot: applicationSupportRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        let url = directory.appendingPathComponent(envelopeID.uuidString.lowercased(), isDirectory: false)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reads and zeros the one-shot envelope. Missing/empty → fail closed.
    package static func redeemEnvelope(envelopeID: String, applicationSupportRoot: URL) throws -> Data {
        let trimmed = envelopeID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, AgentSessionHostPaths.isSafePathComponent(trimmed) else {
            throw AgentSessionHostCredentialError.unavailable
        }
        let url = envelopeDirectory(applicationSupportRoot: applicationSupportRoot)
            .appendingPathComponent(trimmed, isDirectory: false)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw AgentSessionHostCredentialError.unavailable
        }
        let zeros = Data(count: data.count)
        try zeros.write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: url)
        return data
    }

    /// Compatible backends cannot fall back to the vendor CLI login; missing bytes fail closed.
    package static func requiresHostSuppliedSecret(providerID: String) -> Bool {
        switch providerID {
        case "claudeCodeGLM", "kimiCode", "customClaudeCompatible":
            true
        default:
            false
        }
    }

    package static func environment(forProviderID providerID: String, envelopeSecret: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        guard let secret = envelopeSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
            return environment
        }
        environment[secretEnvironmentKey(forProviderID: providerID)] = secret
        return environment
    }

    package static func secretEnvironmentKey(forProviderID providerID: String) -> String {
        switch providerID {
        case "codexExec": "OPENAI_API_KEY"
        case "openCode": "OPENCODE_API_KEY"
        case "cursor": "CURSOR_API_KEY"
        case "claudeCodeGLM": "ANTHROPIC_AUTH_TOKEN"
        default: "ANTHROPIC_API_KEY"
        }
    }
}

package enum AgentSessionHostCredentialError: Error, Equatable {
    case unavailable
}
