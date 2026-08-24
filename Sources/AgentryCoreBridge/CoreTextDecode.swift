import Foundation

/// Stable, platform-neutral encoding identity produced by Rust textdecode-v1.
public enum CoreTextEncodingV1: Sendable, Equatable, Hashable {
    case utf8
    case utf16BigEndian
    case utf16LittleEndian
    case utf32BigEndian
    case utf32LittleEndian
    case legacy(ianaName: String)
}

/// One complete-buffer decode result. Rust owns detection and byte-to-text interpretation;
/// Swift uses the encoding identity only when it must preserve an existing file's write format.
public struct CoreTextDecodeResultV1: Sendable, Equatable {
    public static let contractVersion: UInt16 = 1

    public let text: String
    public let encoding: CoreTextEncodingV1
    public let bomPresent: Bool
    public let hadReplacements: Bool
    public let policyID: String

    public init(
        text: String,
        encoding: CoreTextEncodingV1,
        bomPresent: Bool,
        hadReplacements: Bool,
        policyID: String
    ) {
        self.text = text
        self.encoding = encoding
        self.bomPresent = bomPresent
        self.hadReplacements = hadReplacements
        self.policyID = policyID
    }
}

public extension CoreComputeClient {
    /// Decodes one complete raw byte buffer through Rust's workspace-automatic-v2 policy.
    func decodeTextV1(_ rawBytes: Data) async throws -> CoreTextDecodeResultV1 {
        try Task.checkCancellation()
        let context = try await bridge.prepareDirectComputeOperation()
        do {
            let result = try await Task.detached(priority: nil) {
                try context.transport.textDecodeV1(
                    identity: context.identity,
                    rawBytes: rawBytes
                )
            }.value
            try Task.checkCancellation()
            try await bridge.validateComputeCompletion(identity: context.identity)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await bridge.mapComputeFailure(error)
        }
    }
}

extension CoreRuntimeTransport {
    func textDecodeV1(
        identity: CoreRuntimeIdentity,
        rawBytes: Data
    ) throws -> CoreTextDecodeResultV1 {
        throw CoreTransportError.unexpected("textdecode transport is unavailable")
    }
}

struct CoreDirectComputeOperationContext {
    let transport: any CoreRuntimeTransport
    let identity: CoreRuntimeIdentity
}
