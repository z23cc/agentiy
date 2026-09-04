import AgentryCoreBridge
import Foundation
import RepoPromptDomainRuntime

/// Sparkle / two-phase update gate (design §4.4).
///
/// Connects to an already-running Rust host (`spawn: .never`) and checkpoints
/// before the new binary is allowed to take the lease. No host ⇒ nothing to
/// checkpoint. Host present + `allCheckpointed == false` ⇒ do not replace or
/// stop the host.
enum AgentSessionHostUpdateGate {
    static func prepareUpdateOrAllowIfNoHost() async -> Bool {
        let protocolVersion = (try? CoreAgentHostProtocol().limits().protocolVersion) ?? 1
        let paths = AgentSessionHostPaths.resolve(protocolVersion: protocolVersion)
        var configuration = AgentSessionHostClientConfiguration(paths: paths, clientKind: .gui)
        configuration.spawn = .never
        configuration.connectTimeout = 2
        configuration.responseTimeout = 10
        let client: AgentSessionHostClient
        do {
            client = try await AgentSessionHostClient.connect(configuration: configuration)
        } catch {
            return true
        }
        defer { client.close() }
        do {
            let prepared = try await client.prepareUpdate(deadlineSeconds: 10)
            guard prepared.allCheckpointed else { return false }
            _ = try? await client.shutdown(mode: .graceful, deadlineSeconds: 5)
            return true
        } catch {
            return false
        }
    }
}
