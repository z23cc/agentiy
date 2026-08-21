import Foundation

package enum LanguageType: String, CaseIterable, Comparable, Codable, Sendable {
    case swift, js, c_sharp, python, c, rust, cpp, go, java, ts, tsx, php, ruby

    package var displayName: String {
        switch self {
        case .swift: "Swift"
        case .js: "JavaScript"
        case .c_sharp: "C#"
        case .python: "Python"
        case .c: "C"
        case .rust: "Rust"
        case .cpp: "C++"
        case .go: "Go"
        case .java: "Java"
        case .ts: "TypeScript"
        case .tsx: "TSX"
        case .php: "PHP"
        case .ruby: "Ruby"
        }
    }

    package static func < (lhs: LanguageType, rhs: LanguageType) -> Bool {
        lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
    }
}

/// P2 step 13: parsing, query compilation, and extraction moved to the Rust
/// core (`rust/crates/runtime/src/codemap/`), and the Swift tree-sitter
/// grammar supply chain was deleted. This engine no longer links tree-sitter;
/// it only owns language detection and the cache/pipeline identity inputs,
/// which mirror the Rust authority via `CodeMapPipelineFingerprints`
/// (machine-checked by `rust/crates/runtime/tests/codemap_query_contract.rs`).
package struct CodeMapLanguagePipelineDescriptor: Sendable {
    package let stableLanguageID: CodeMapPipelineLanguageID
    package let grammarRevision: String
    package let treeSitterABIVersion: UInt32
    package let querySHA256: CodeMapSHA256Digest
}

package enum CodeMapSyntaxEngineError: Error, Equatable, Sendable {
    case missingPipelineFingerprint(language: LanguageType)
    case invalidPipelineFingerprint(language: LanguageType)
}

package struct CodeMapSyntaxEngine: Sendable {
    package static let shared = CodeMapSyntaxEngine()

    package static let parseLineLimit = 25_000
    package static let parseUTF16Limit = 1_500_000
    package static let parseUTF8Limit = 5_000_000

    package static let extensionToLanguage: [String: LanguageType] = [
        "swift": .swift,
        "js": .js,
        "cs": .c_sharp,
        "py": .python,
        "c": .c,
        "rs": .rust,
        "cpp": .cpp,
        "go": .go,
        "java": .java,
        "ts": .ts,
        "tsx": .tsx,
        "php": .php,
        "rb": .ruby
    ]

    package init() {}

    package func language(forFileExtension fileExtension: String) -> LanguageType? {
        Self.extensionToLanguage[fileExtension.lowercased()]
    }

    package static func isSupportedFileExtension(_ fileExtension: String) -> Bool {
        extensionToLanguage[fileExtension.lowercased()] != nil
    }

    package static func supportsCodeMap(fileExtension: String) -> Bool {
        extensionToLanguage[fileExtension.lowercased()] != nil
    }

    package static func isLightweight(language: LanguageType) -> Bool {
        switch language {
        case .php, .ruby, .ts, .tsx, .js:
            true
        default:
            false
        }
    }

    package static func stableLanguageID(for languageType: LanguageType) -> CodeMapPipelineLanguageID {
        switch languageType {
        case .swift: .swift
        case .js: .javascript
        case .c_sharp: .cSharp
        case .python: .python
        case .c: .c
        case .rust: .rust
        case .cpp: .cpp
        case .go: .go
        case .java: .java
        case .ts: .typescript
        case .tsx: .tsx
        case .php: .php
        case .ruby: .ruby
        }
    }

    package func codeMapPipelineDescriptor(
        for languageType: LanguageType
    ) throws -> CodeMapLanguagePipelineDescriptor {
        guard let fingerprint = CodeMapPipelineFingerprints.table[languageType] else {
            throw CodeMapSyntaxEngineError.missingPipelineFingerprint(language: languageType)
        }
        guard fingerprint.treeSitterABIVersion > 0,
              let digestBytes = Data(codeMapHexEncoded: fingerprint.querySHA256Hex),
              let digest = try? CodeMapSHA256Digest(bytes: digestBytes)
        else {
            throw CodeMapSyntaxEngineError.invalidPipelineFingerprint(language: languageType)
        }
        return CodeMapLanguagePipelineDescriptor(
            stableLanguageID: Self.stableLanguageID(for: languageType),
            grammarRevision: fingerprint.grammarRevision,
            treeSitterABIVersion: fingerprint.treeSitterABIVersion,
            querySHA256: digest
        )
    }

    package func pipelineIdentity(
        for languageType: LanguageType,
        decoderPolicy: CodeMapSourceDecoderPolicy
    ) throws -> CodeMapPipelineIdentity {
        let descriptor = try codeMapPipelineDescriptor(for: languageType)
        return try CodeMapPipelineIdentity(
            languageID: descriptor.stableLanguageID,
            decoderPolicy: decoderPolicy,
            grammarRevision: descriptor.grammarRevision,
            treeSitterABIVersion: descriptor.treeSitterABIVersion,
            codeMapQuerySHA256: descriptor.querySHA256,
            extractorVersion: CodeMapSemanticVersion(major: 2, minor: 0, patch: 0),
            generatorVersion: CodeMapSemanticVersion(major: 2, minor: 0, patch: 0),
            artifactSchemaVersion: 1,
            oversizeParsePolicyVersion: 1,
            limits: [
                CodeMapPipelineNamedLimit(
                    name: "jsts-max-appended-continuation-lines",
                    // Frozen identity input: this was `CodeMapGenerator.jstsMaxAppendedContinuationLines`
                    // (deleted with the legacy Swift extraction stack in P2 step 13). The
                    // artifact-key/pipeline-identity contract requires this value stay
                    // byte-identical to what was previously hashed, so it is hardcoded here
                    // rather than recomputed.
                    value: 80
                ),
                CodeMapPipelineNamedLimit(name: "parse-line-count", value: UInt64(Self.parseLineLimit)),
                CodeMapPipelineNamedLimit(name: "parse-utf16-code-units", value: UInt64(Self.parseUTF16Limit)),
                CodeMapPipelineNamedLimit(name: "parse-utf8-bytes", value: UInt64(Self.parseUTF8Limit))
            ],
            flags: [
                CodeMapPipelineNamedFlag(name: "filename-main-class-shaping", enabled: false),
                CodeMapPipelineNamedFlag(
                    name: "jsts-signature-extraction",
                    enabled: languageType == .js || languageType == .ts || languageType == .tsx
                ),
                CodeMapPipelineNamedFlag(
                    name: "lightweight-extraction",
                    enabled: Self.isLightweight(language: languageType)
                ),
                CodeMapPipelineNamedFlag(name: "path-free-artifact-finalization", enabled: true),
                CodeMapPipelineNamedFlag(name: "rust-core-compute", enabled: true),
                CodeMapPipelineNamedFlag(name: "swift-range-strategy", enabled: languageType == .swift),
                CodeMapPipelineNamedFlag(
                    name: "typescript-range-strategy",
                    enabled: languageType == .ts || languageType == .tsx
                )
            ]
        )
    }
}

extension Data {
    /// Strict lowercase/uppercase hex decoding for pipeline fingerprint digests.
    package init?(codeMapHexEncoded hex: String) {
        let characters = Array(hex.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = characters[index].codeMapHexNibble,
                  let low = characters[index + 1].codeMapHexNibble
            else { return nil }
            bytes.append((high << 4) | low)
            index += 2
        }
        self = bytes
    }
}

private extension UInt8 {
    var codeMapHexNibble: UInt8? {
        switch self {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): self - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): self - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): self - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
