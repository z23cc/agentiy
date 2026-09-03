import AgentryCoreBridge
import Foundation
import RepoPromptDomainRuntime

/// Credential publish and path-shaped cwd for a live host start (ADR-0011 addendum 2026-09-03).
///
/// Envelope is the portable secret path for debug and release. This type does not call
/// Security.framework. Secrets come from an injected provider or the process environment.
enum HostAgentSessionLaunchPreparation {
    struct Context: Sendable {
        var applicationSupportRoot: URL
        /// When `true`, a resolved secret is written as a 0600 envelope and `envelopeID` is put on the wire.
        var putsEnvelopeIDOnWire: Bool
        var secretProvider: @Sendable (String) async -> String?

        static func disabled(applicationSupportRoot: URL = FileManager.default.temporaryDirectory) -> Context {
            Context(
                applicationSupportRoot: applicationSupportRoot,
                putsEnvelopeIDOnWire: false,
                secretProvider: { _ in nil }
            )
        }

        static func production() -> Context {
            let protocolVersion = (try? CoreAgentHostProtocol().limits().protocolVersion) ?? 1
            let paths = AgentSessionHostPaths.resolve(protocolVersion: protocolVersion)
            return Context(
                applicationSupportRoot: paths.applicationSupportRoot,
                putsEnvelopeIDOnWire: true,
                secretProvider: { providerID in
                    let key = AgentSessionHostCredentials.secretEnvironmentKey(forProviderID: providerID)
                    let value = ProcessInfo.processInfo.environment[key]?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (value?.isEmpty == false) ? value : nil
                }
            )
        }
    }

    static func looksLikeFilesystemPath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")
    }

    static func resolveWorkingDirectory(spec: AgentSessionStartSpec, fallback: String?) -> String? {
        if let existing = spec.worktreeID, looksLikeFilesystemPath(existing) {
            return (existing as NSString).expandingTildeInPath
        }
        if let fallback, looksLikeFilesystemPath(fallback) {
            return (fallback as NSString).expandingTildeInPath
        }
        return nil
    }

    static func prepare(
        _ spec: AgentSessionStartSpec,
        context: Context,
        workingDirectory: String? = nil
    ) async throws -> AgentSessionStartSpec {
        let cwd = resolveWorkingDirectory(spec: spec, fallback: workingDirectory)
        guard context.putsEnvelopeIDOnWire else {
            return spec.withHostLaunchOverrides(worktreeID: cwd, credentialEnvelopeID: nil)
        }
        if let existing = spec.credentialEnvelopeID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty
        {
            return spec.withHostLaunchOverrides(worktreeID: cwd, credentialEnvelopeID: existing.lowercased())
        }
        let providerID = (spec.provider ?? .claudeCode).rawValue
        let required = AgentSessionHostCredentials.requiresHostSuppliedSecret(providerID: providerID)
        let secret = await context.secretProvider(providerID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let secret, !secret.isEmpty {
            let envelopeID = UUID()
            try AgentSessionHostCredentials.publishEnvelope(
                envelopeID: envelopeID,
                bytes: Data(secret.utf8),
                applicationSupportRoot: context.applicationSupportRoot
            )
            return spec.withHostLaunchOverrides(
                worktreeID: cwd,
                credentialEnvelopeID: envelopeID.uuidString.lowercased()
            )
        }
        if required {
            throw AgentSessionConnectionError.commandRejected("required provider credential is unavailable")
        }
        return spec.withHostLaunchOverrides(worktreeID: cwd, credentialEnvelopeID: nil)
    }
}
