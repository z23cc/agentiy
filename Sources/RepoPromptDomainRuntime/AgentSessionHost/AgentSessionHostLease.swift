import Darwin
import Foundation

/// Diagnostic record of the current lease holder, written beside the lock file after acquisition.
/// Never used for exclusion decisions; `flock` alone decides (design §4.1).
package struct AgentSessionHostLeaseOwner: Codable, Equatable {
    package static let currentVersion = 1

    package var version: Int
    package var hostInstanceID: String
    package var processID: Int32
    package var buildFingerprint: String
    package var implementation: String
    package var socketPath: String
    package var acquiredAt: Date

    package init(
        hostInstanceID: String,
        processID: Int32 = getpid(),
        buildFingerprint: String,
        implementation: String = "swift",
        socketPath: String,
        acquiredAt: Date = Date()
    ) {
        version = Self.currentVersion
        self.hostInstanceID = hostInstanceID
        self.processID = processID
        self.buildFingerprint = buildFingerprint
        self.implementation = implementation
        self.socketPath = socketPath
        self.acquiredAt = acquiredAt
    }
}

package enum AgentSessionHostLeaseAcquisition {
    case acquired(AgentSessionHostLease)
    /// Another live process holds the lease. `observedOwner` is best-effort diagnostics.
    case contended(observedOwner: AgentSessionHostLeaseOwner?)
    case failed(reason: String)
}

/// The per-user single-host lease: an exclusive non-blocking `flock` on `agent-host-v1.lock`. The
/// kernel releases it when the holder dies (including SIGKILL), so a stale owner file never blocks a
/// successor. Stale-socket cleanup is only legal after this returns `.acquired`.
package final class AgentSessionHostLease: @unchecked Sendable {
    package let paths: AgentSessionHostPaths
    package let owner: AgentSessionHostLeaseOwner

    private let lock = NSLock()
    private var descriptor: Int32

    private init(paths: AgentSessionHostPaths, owner: AgentSessionHostLeaseOwner, descriptor: Int32) {
        self.paths = paths
        self.owner = owner
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    package var isHeld: Bool {
        lock.withLock { descriptor >= 0 }
    }

    package static func acquire(
        paths: AgentSessionHostPaths,
        owner: AgentSessionHostLeaseOwner,
        fileManager: FileManager = .default
    ) -> AgentSessionHostLeaseAcquisition {
        do {
            try fileManager.createDirectory(
                at: paths.lockDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failed(reason: "create lock directory: \(error.localizedDescription)")
        }

        let descriptor = open(paths.lockFileURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return .failed(reason: "open lock file: \(String(cString: strerror(errno)))")
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                return .contended(observedOwner: readOwner(paths: paths))
            }
            return .failed(reason: "flock: \(String(cString: strerror(code)))")
        }

        let lease = AgentSessionHostLease(paths: paths, owner: owner, descriptor: descriptor)
        lease.writeOwnerMetadata()
        return .acquired(lease)
    }

    /// Best-effort read of the holder record; `nil` when absent or unreadable.
    package static func readOwner(paths: AgentSessionHostPaths) -> AgentSessionHostLeaseOwner? {
        guard let data = try? Data(contentsOf: paths.ownerMetadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentSessionHostLeaseOwner.self, from: data)
    }

    /// Releases the `flock` and removes the owner record. Idempotent.
    package func release() {
        let descriptor = lock.withLock {
            let current = self.descriptor
            self.descriptor = -1
            return current
        }
        guard descriptor >= 0 else { return }
        try? FileManager.default.removeItem(at: paths.ownerMetadataURL)
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private func writeOwnerMetadata() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(owner) else { return }
        let temporary = paths.ownerMetadataURL.appendingPathExtension("tmp-\(getpid())")
        do {
            try data.write(to: temporary, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(paths.ownerMetadataURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
