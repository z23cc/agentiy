import AgentryCoreBridge
import Foundation

/// JSON-RPC turn transport used by the host executor. Production wraps
/// `CoreHostedRuntimeSession`; tests inject `ProviderHostedScriptedTransport`.
/// DomainRuntime must not name GUI provider types (source-layout guardrail).
package protocol ProviderHostedRuntimeTransport: AnyObject, Sendable {
    func start() async throws
    func request(method: String, paramsJSON: String?, timeoutMilliseconds: UInt64?) async throws -> Data
    func notify(method: String, paramsJSON: String?) async throws
    func respond(requestIDJSON: Data, resultJSON: Data) async throws
    func respondError(requestIDJSON: Data, code: Int64, message: String) async throws
    func cancelInFlight() async
    func events() async throws -> AsyncStream<ProviderHostedRuntimeInbound>
    func shutdown() async
}

package enum ProviderHostedRuntimeInbound: Sendable {
    case notification(method: String, paramsJSON: String)
    case serverRequest(idJSON: Data, idDisplay: String, method: String, paramsJSON: String)
    case processExited
    case protocolError(String)
}

package enum ProviderHostedRuntimeKind: Sendable {
    case codexAppServer
    case acp
}

enum ProviderHostedJSON {
    static func data(fromJSONObject object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    static func object(from string: String) -> [String: Any] {
        guard let data = string.data(using: .utf8) else { return [:] }
        return object(from: data) ?? [:]
    }

    static func string(fromJSONObject object: Any) -> String {
        guard let data = data(fromJSONObject: object), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func string(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Live process transport. Owns a `CoreHostedRuntimeSession` already opened by the executor.
package final class ProviderHostedLiveTransport: ProviderHostedRuntimeTransport, @unchecked Sendable {
    private let session: CoreHostedRuntimeSession
    private let kind: ProviderHostedRuntimeKind
    private let lock = NSLock()
    private var lastCancellationToken: String?

    package init(session: CoreHostedRuntimeSession, kind: ProviderHostedRuntimeKind) {
        self.session = session
        self.kind = kind
    }

    package func start() async throws {
        _ = try await session.start()
    }

    package func request(method: String, paramsJSON: String?, timeoutMilliseconds: UInt64?) async throws -> Data {
        let params = paramsJSON?.data(using: .utf8)
        let token = UUID().uuidString.lowercased()
        lock.withLock { lastCancellationToken = token }
        defer { lock.withLock { if lastCancellationToken == token { lastCancellationToken = nil } } }
        switch kind {
        case .codexAppServer:
            return try await session.codexRequest(
                method: method,
                params: params,
                timeoutMilliseconds: timeoutMilliseconds,
                cancellationToken: token
            )
        case .acp:
            let response = try await session.agentProviderAcpRequest(
                method: method,
                params: params,
                timeoutMilliseconds: timeoutMilliseconds,
                cancellationToken: token
            )
            return response.result
        }
    }

    package func notify(method: String, paramsJSON: String?) async throws {
        let params = paramsJSON?.data(using: .utf8)
        switch kind {
        case .codexAppServer:
            _ = try await session.codexNotify(method: method, params: params)
        case .acp:
            _ = try await session.agentProviderAcpNotify(method: method, params: params)
        }
    }

    package func respond(requestIDJSON: Data, resultJSON: Data) async throws {
        switch kind {
        case .codexAppServer:
            _ = try await session.codexRespond(requestID: requestIDJSON, result: resultJSON)
        case .acp:
            _ = try await session.agentProviderAcpRespond(requestID: requestIDJSON, result: resultJSON)
        }
    }

    package func respondError(requestIDJSON: Data, code: Int64, message: String) async throws {
        switch kind {
        case .codexAppServer:
            _ = try await session.codexRespondError(requestID: requestIDJSON, code: code, message: message, data: nil)
        case .acp:
            _ = try await session.agentProviderAcpRespondError(
                requestID: requestIDJSON,
                code: code,
                message: message,
                data: nil
            )
        }
    }

    package func cancelInFlight() async {
        let token = lock.withLock { lastCancellationToken }
        guard let token else { return }
        switch kind {
        case .codexAppServer:
            _ = try? await session.codexCancel(cancellationToken: token)
        case .acp:
            _ = try? await session.agentProviderAcpCancel(cancellationToken: token)
        }
    }

    package func events() async throws -> AsyncStream<ProviderHostedRuntimeInbound> {
        let stream = try await session.events()
        return AsyncStream { continuation in
            Task {
                var iterator = stream.makeAsyncIterator()
                do {
                    while let event = try await iterator.next() {
                        continuation.yield(Self.map(event))
                    }
                } catch {
                    continuation.yield(.protocolError(String(describing: error)))
                }
                continuation.finish()
            }
        }
    }

    package func shutdown() async {
        await session.shutdown()
    }

    private static func map(_ event: CoreHostedRuntimeEvent) -> ProviderHostedRuntimeInbound {
        switch event.kind {
        case "processExited":
            return .processExited
        case "protocolError":
            let message = (event.payloadDictionary?["message"] as? String) ?? "protocol error"
            return .protocolError(message)
        case "serverRequest":
            let payload = event.payloadDictionary ?? [:]
            let method = (payload["method"] as? String) ?? ""
            let paramsJSON = paramsJSON(from: payload["params"])
            let idJSON: Data
            if let wire = payload["id_json"] as? String, let data = wire.data(using: .utf8) {
                idJSON = data
            } else if let id = payload["id"], let data = ProviderHostedJSON.data(fromJSONObject: id) {
                idJSON = data
            } else {
                idJSON = Data("null".utf8)
            }
            let idDisplay: String
            if let text = payload["id"] as? String {
                idDisplay = text
            } else if let number = payload["id"] as? NSNumber {
                idDisplay = number.stringValue
            } else {
                idDisplay = ProviderHostedJSON.string(from: idJSON)
            }
            return .serverRequest(idJSON: idJSON, idDisplay: idDisplay, method: method, paramsJSON: paramsJSON)
        default:
            let payload = event.payloadDictionary ?? [:]
            let method = (payload["method"] as? String) ?? event.kind
            return .notification(method: method, paramsJSON: paramsJSON(from: payload["params"]))
        }
    }

    private static func paramsJSON(from value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "{}" }
        if let object = value as? [String: Any] {
            return ProviderHostedJSON.string(fromJSONObject: object)
        }
        return ProviderHostedJSON.string(fromJSONObject: value)
    }
}

/// In-memory JSON-RPC fixture. No process, no network.
package final class ProviderHostedScriptedTransport: ProviderHostedRuntimeTransport, @unchecked Sendable {
    package struct RecordedCall: Equatable, Sendable {
        package var method: String
        package var paramsJSON: String?
    }

    package struct RecordedRespond: Equatable, Sendable {
        package var idJSON: Data
        package var resultJSON: Data
    }

    private let lock = NSLock()
    private var handlers: [String: @Sendable (String?) async throws -> Data] = [:]
    private var recorded: [RecordedCall] = []
    private var recordedRespondCalls: [RecordedRespond] = []
    private var continuation: AsyncStream<ProviderHostedRuntimeInbound>.Continuation?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var cancelled = false

    package init() {}

    package func setHandler(for method: String, _ handler: @escaping @Sendable (String?) async throws -> Data) {
        lock.withLock { handlers[method] = handler }
    }

    package var recordedRequests: [RecordedCall] {
        lock.withLock { recorded }
    }

    package var recordedResponds: [RecordedRespond] {
        lock.withLock { recordedRespondCalls }
    }

    package func emit(_ inbound: ProviderHostedRuntimeInbound) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(inbound)
    }

    package func start() async throws {}

    package func request(method: String, paramsJSON: String?, timeoutMilliseconds _: UInt64?) async throws -> Data {
        lock.withLock { recorded.append(RecordedCall(method: method, paramsJSON: paramsJSON)) }
        let handler = lock.withLock { handlers[method] }
        if let handler {
            return try await handler(paramsJSON)
        }
        return Data("{}".utf8)
    }

    package func notify(method: String, paramsJSON: String?) async throws {
        lock.withLock { recorded.append(RecordedCall(method: method, paramsJSON: paramsJSON)) }
        if let handler = lock.withLock({ handlers[method] }) {
            _ = try await handler(paramsJSON)
        }
    }

    package func respond(requestIDJSON: Data, resultJSON: Data) async throws {
        lock.withLock { recordedRespondCalls.append(RecordedRespond(idJSON: requestIDJSON, resultJSON: resultJSON)) }
    }

    package func respondError(requestIDJSON: Data, code: Int64, message: String) async throws {
        let result = ProviderHostedJSON.string(fromJSONObject: ["error": ["code": code, "message": message]])
        lock.withLock { recordedRespondCalls.append(RecordedRespond(idJSON: requestIDJSON, resultJSON: Data(result.utf8))) }
    }

    package func cancelInFlight() async {
        lock.withLock { cancelled = true }
    }

    package func events() async throws -> AsyncStream<ProviderHostedRuntimeInbound> {
        AsyncStream { continuation in
            self.lock.withLock { self.continuation = continuation }
            continuation.onTermination = { _ in
                self.lock.withLock { self.continuation = nil }
            }
        }
    }

    package func shutdown() async {
        let continuation = lock.withLock { () -> AsyncStream<ProviderHostedRuntimeInbound>.Continuation? in
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.finish()
    }
}
