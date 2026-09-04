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
}
