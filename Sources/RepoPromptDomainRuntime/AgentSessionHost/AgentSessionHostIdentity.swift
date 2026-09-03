import AgentryCoreBridge
import Darwin
import Foundation

/// Executable identity of this process for `Hello` / `Welcome` (design §5.3).
package enum AgentSessionHostExecutableIdentity {
    package static func current() -> AgentHostExecutableIdentityV1 {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        return AgentHostExecutableIdentityV1(
            bundleIdentifier: bundle.bundleIdentifier ?? "",
            executableName: currentExecutableURL()?.lastPathComponent ?? "",
            version: info["CFBundleShortVersionString"] as? String ?? "",
            buildNumber: info["CFBundleVersion"] as? String ?? "",
            pid: UInt32(getpid()),
            codeSigningTeamIdentifier: ""
        )
    }

    package static func currentExecutableURL() -> URL? {
        executableURL(forProcess: getpid())
    }

    package static func executableURL(forProcess processID: pid_t) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The enclosing `.app` bundle of an executable, when it lives inside one.
    package static func bundleRoot(of executable: URL) -> URL? {
        var cursor = executable
        while cursor.pathComponents.count > 1 {
            cursor.deleteLastPathComponent()
            if cursor.pathExtension == "app" { return cursor }
        }
        return nil
    }
}

/// Decides whether a connecting peer is the same product build as the host. The kernel-reported peer
/// pid is the trusted input; the `Hello.executable` block is informational and cross-checked only.
package protocol AgentSessionHostPeerVerifier: Sendable {
    func verify(peerProcessID: pid_t?, hello: AgentHostHelloV1) -> AgentSessionHostPeerVerdict
}

package enum AgentSessionHostPeerVerdict: Equatable {
    case accepted
    case rejected(detail: String)
}

/// Production rule: the peer's executable must be this executable, or live in the same `.app` bundle
/// (the GUI `Agentry` and `agentry-mcp` share one bundle), and any bundle identifier the peer claims
/// must match ours.
package struct AgentSessionHostSameProductPeerVerifier: AgentSessionHostPeerVerifier {
    package init() {}

    package func verify(peerProcessID: pid_t?, hello: AgentHostHelloV1) -> AgentSessionHostPeerVerdict {
        guard let peerProcessID else { return .rejected(detail: "peer pid unavailable") }
        guard let own = AgentSessionHostExecutableIdentity.currentExecutableURL() else {
            return .rejected(detail: "own executable path unavailable")
        }
        guard let peer = AgentSessionHostExecutableIdentity.executableURL(forProcess: peerProcessID) else {
            return .rejected(detail: "peer executable path unavailable for pid \(peerProcessID)")
        }
        let sameExecutable = peer.path == own.path
        let sameBundle: Bool = {
            guard let ownBundle = AgentSessionHostExecutableIdentity.bundleRoot(of: own),
                  let peerBundle = AgentSessionHostExecutableIdentity.bundleRoot(of: peer)
            else { return false }
            return ownBundle.path == peerBundle.path
        }()
        guard sameExecutable || sameBundle else {
            return .rejected(detail: "peer executable \(peer.path) is not \(own.path)")
        }
        let ownBundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        if let claimed = hello.executable?.bundleIdentifier, !claimed.isEmpty, !ownBundleIdentifier.isEmpty,
           claimed != ownBundleIdentifier
        {
            return .rejected(detail: "bundle identifier \(claimed) is not \(ownBundleIdentifier)")
        }
        return .accepted
    }
}

/// Accepts any live peer. Test seam for cross-process suites whose client is the XCTest runner.
package struct AgentSessionHostAcceptAnyPeerVerifier: AgentSessionHostPeerVerifier {
    package init() {}

    package func verify(peerProcessID: pid_t?, hello _: AgentHostHelloV1) -> AgentSessionHostPeerVerdict {
        peerProcessID == nil ? .rejected(detail: "peer pid unavailable") : .accepted
    }
}
