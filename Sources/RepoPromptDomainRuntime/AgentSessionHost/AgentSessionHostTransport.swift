import AgentryCoreBridge
import Darwin
import Foundation

package enum AgentSessionHostTransportError: Error, Equatable {
    case closed
    case io(operation: String, message: String)
    case socketPathTooLong(String)
    case connectTimedOut
}

/// Client-side Unix-domain connect to the Rust `agentry-mcp agent-host` socket.
package enum AgentSessionHostSocketListener {
    /// Connects to the host socket, failing fast when nothing listens.
    package static func connect(path: String) throws -> Int32 {
        var address = try socketAddress(path: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw errnoError("socket") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let error = errnoError("connect")
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw AgentSessionHostTransportError.socketPathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
            buffer[bytes.count] = 0
        }
        return address
    }

    static func errnoError(_ operation: String) -> AgentSessionHostTransportError {
        .io(operation: operation, message: String(cString: strerror(errno)))
    }
}

/// One connected stream socket carrying agent-host-v1 frames. Reads are blocking and meant for a
/// dedicated reader thread; writes are serialized and blocking. The 4-byte prefix is parsed by the
/// Rust codec (`framePayloadLength`) so the payload cap is enforced before any payload byte is read;
/// an oversized frame surfaces as `CoreBridgeError.agentHostFrameTooLarge` and the caller closes.
package final class AgentSessionHostFrameTransport: @unchecked Sendable {
    package let codec: CoreAgentHostProtocol
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var descriptor: Int32
    private let prefixLength: Int

    package init(descriptor: Int32, codec: CoreAgentHostProtocol, limits: AgentHostProtocolLimitsV1) {
        self.descriptor = descriptor
        self.codec = codec
        prefixLength = Int(limits.frameLengthPrefixBytes)
        var noSigpipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
    }

    package var isOpen: Bool {
        stateLock.withLock { descriptor >= 0 }
    }

    /// Process identifier of the peer, when the kernel reports it (`LOCAL_PEERPID`).
    package var peerProcessID: pid_t? {
        let descriptor = stateLock.withLock { self.descriptor }
        guard descriptor >= 0 else { return nil }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// Reads one complete frame (prefix + payload). Throws `.closed` at EOF.
    package func readFrame() throws -> Data {
        try readLock.withLock {
            let prefix = try readExactly(prefixLength)
            let payloadLength = try codec.framePayloadLength(prefix: prefix)
            var frame = prefix
            if payloadLength > 0 {
                try frame.append(readExactly(Int(payloadLength)))
            }
            return frame
        }
    }

    /// Writes one already-encoded frame. Serialized across callers.
    package func writeFrame(_ frame: Data) throws {
        try writeLock.withLock {
            var offset = 0
            while offset < frame.count {
                let descriptor = stateLock.withLock { self.descriptor }
                guard descriptor >= 0 else { throw AgentSessionHostTransportError.closed }
                let written = frame.withUnsafeBytes { buffer -> Int in
                    Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), frame.count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EPIPE || errno == ECONNRESET { throw AgentSessionHostTransportError.closed }
                    throw AgentSessionHostSocketListener.errnoError("write")
                }
                if written == 0 { throw AgentSessionHostTransportError.closed }
                offset += written
            }
        }
    }

    /// Shuts the socket down in both directions so a blocked reader wakes with `.closed`. Idempotent.
    package func close() {
        let descriptor = stateLock.withLock {
            let current = self.descriptor
            self.descriptor = -1
            return current
        }
        guard descriptor >= 0 else { return }
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let descriptor = stateLock.withLock { self.descriptor }
            guard descriptor >= 0 else { throw AgentSessionHostTransportError.closed }
            let received = data.withUnsafeMutableBytes { buffer -> Int in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if received < 0 {
                if errno == EINTR { continue }
                if errno == ECONNRESET || errno == EBADF { throw AgentSessionHostTransportError.closed }
                throw AgentSessionHostSocketListener.errnoError("read")
            }
            if received == 0 { throw AgentSessionHostTransportError.closed }
            offset += received
        }
        return data
    }
}

/// RFC 3339 timestamps used by every wire and log record.
package enum AgentSessionHostClock {
    /// ISO8601DateFormatter is documented thread-safe; it merely lacks a Sendable annotation.
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    package static func rfc3339(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }

    package static func date(rfc3339: String) -> Date? {
        formatter.date(from: rfc3339) ?? ISO8601DateFormatter().date(from: rfc3339)
    }
}
