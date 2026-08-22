import Foundation

package enum CodeMapSourceDecoderPolicy: String, Codable, Hashable, Sendable {
    case workspaceAutomaticV1
    /// TD-3 (`docs/designs/textdecode-policy-v2-2026-08-22.md` §5.4/§6.1): raw-bytes cutover --
    /// `CodeMapCoreSourceSnapshot.rawBytes` is shipped across the FFI instead of a Swift-decoded,
    /// then re-encoded, `String`; Rust's `textdecode()` runs as codemap's first step. A pipeline-
    /// identity input (§3.2), so cutover rotates the artifact-cache digest automatically.
    case workspaceAutomaticV2
    #if DEBUG
        case testOnlyMismatch
    #endif
}

package struct CodeMapRawSourceDigest: Hashable, Codable, Sendable {
    private static let requiredByteCount = 32

    package let bytes: Data

    package init(bytes: Data) {
        precondition(bytes.count == Self.requiredByteCount, "A raw source digest must contain exactly 32 SHA-256 bytes.")
        self.bytes = bytes
    }

    package var lowercaseHex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decodedBytes = try container.decode(Data.self)
        guard decodedBytes.count == Self.requiredByteCount else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A raw source digest must contain exactly 32 SHA-256 bytes."
            )
        }
        bytes = decodedBytes
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

package struct CodeMapDecodedSource: Equatable, Sendable {
    package let text: String
    package let detectedEncodingRawValue: UInt

    package init(text: String, detectedEncodingRawValue: UInt) {
        self.text = text
        self.detectedEncodingRawValue = detectedEncodingRawValue
    }
}

package enum CodeMapSourceDecodeFailure: String, Codable, Equatable, Sendable {
    case undecodable
}

package enum CodeMapSourceDecodeResult: Equatable, Sendable {
    case decoded(CodeMapDecodedSource)
    case failed(CodeMapSourceDecodeFailure)
}

package struct CodeMapCoreSourceSnapshot: Equatable, Sendable {
    package let rawByteCount: Int
    package let rawSHA256: CodeMapRawSourceDigest
    package let decoderPolicy: CodeMapSourceDecoderPolicy
    package let decodeResult: CodeMapSourceDecodeResult
    /// TD-3 §6.1 (closes the round-1 review's Critical-1 model-gap finding): the raw,
    /// pre-decode source bytes, required so `RustCodeMapArtifactBuilder` can ship them across
    /// the FFI directly under `.workspaceAutomaticV2` instead of re-encoding `decodeResult`'s
    /// already-Swift-decoded text. Populated by every caller (both the GUI's
    /// `CodeMapArtifactBuildCoordinator`-facing `CodeMapSourceSnapshot.coreSnapshot` and the
    /// headless `MCPDomainCanonicalWorkspaceService`) regardless of `decoderPolicy`, since it is
    /// cheap to carry and keeps this type's invariants uniform across both hosts.
    package let rawBytes: Data

    package init(
        rawByteCount: Int,
        rawSHA256: CodeMapRawSourceDigest,
        decoderPolicy: CodeMapSourceDecoderPolicy,
        decodeResult: CodeMapSourceDecodeResult,
        rawBytes: Data
    ) {
        self.rawByteCount = rawByteCount
        self.rawSHA256 = rawSHA256
        self.decoderPolicy = decoderPolicy
        self.decodeResult = decodeResult
        self.rawBytes = rawBytes
    }
}
