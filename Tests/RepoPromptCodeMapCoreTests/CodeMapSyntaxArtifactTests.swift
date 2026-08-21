import CryptoKit
import Foundation
import XCTest
@testable import RepoPromptCodeMapCore

/// P2 step 13: the legacy Swift `CodeMapSyntaxArtifactBuilder` was deleted
/// once the production Rust seam (`RustCodeMapArtifactBuilder`) was verified
/// as a hard-assertion match on all 13 fixtures (see
/// `docs/architecture/rust-codemap-compact-v1.md`, "Step 13 verdict: GO").
///
/// This file used to also exercise the builder directly (decode-failed,
/// empty/no-symbols, oversize, and parse-failure outcome mapping, plus
/// determinism); that coverage now lives against the Rust seam in
/// `Tests/RepoPromptTests/CodeMap/CodeMapRustBuilderOutcomeTests.swift`
/// (moved rather than dropped, since `RustCodeMapArtifactBuilder` lives in
/// `RepoPromptDomainRuntime`, which this target does not depend on).
///
/// What remains here is pure model (de)serialization coverage for
/// `CodeMapSyntaxArtifact`/`CodeMapSyntaxArtifactOutcome`, which is
/// unrelated to the compute engine and was not part of the Rust cutover.
final class CodeMapSyntaxArtifactTests: XCTestCase {
    func testArtifactSerializationIsPathFreeAndRecomputesDerivedValues() throws {
        let artifact = makeArtifact()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(artifact)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            [
                "aliases", "classes", "enums", "exports", "functions", "globalVars", "imports",
                "interfaces", "literalUnions", "macros", "referencedTypes"
            ]
        )
        let forbiddenFragments = [
            "path", "root", "fileid", "session", "worktree", "modification", "fingerprint",
            "digest", "token", "validation"
        ]
        for key in recursiveKeys(object).map({ $0.lowercased() }) {
            XCTAssertFalse(forbiddenFragments.contains { key.contains($0) }, "Unexpected identity key: \(key)")
        }

        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("/private/sentinel/source.swift"))
        XCTAssertEqual(try JSONDecoder().decode(CodeMapSyntaxArtifact.self, from: encoded), artifact)

        var tampered = object
        tampered["apiDescription"] = "PATH-LEAK-SENTINEL"
        tampered["apiTokenCount"] = -1
        tampered["definedTypeNames"] = ["Wrong"]
        let decoded = try JSONDecoder().decode(
            CodeMapSyntaxArtifact.self,
            from: JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys])
        )
        XCTAssertEqual(decoded, artifact)
        XCTAssertFalse(decoded.apiDescription.contains("PATH-LEAK-SENTINEL"))

        var copiedClasses = artifact.classes
        copiedClasses[0].properties.append(PropertyInfo(name: "localMutation", typeName: "Int"))
        XCTAssertFalse(artifact.classes[0].properties.contains { $0.name == "localMutation" })
    }

    func testOutcomeSerializationUsesStableExplicitDiscriminators() throws {
        let cases: [(CodeMapSyntaxArtifactOutcome, String)] = [
            (.readyNoSymbols, #"{"kind":"readyNoSymbols"}"#),
            (.decodeFailed(.undecodable), #"{"failure":"undecodable","kind":"decodeFailed"}"#),
            (
                .oversize(.utf8Bytes(actual: 12, limit: 10)),
                #"{"kind":"oversize","reason":{"actual":12,"kind":"utf8Bytes","limit":10}}"#
            ),
            (.parseFailed(.parserReturnedNilTree), #"{"failure":"parserReturnedNilTree","kind":"parseFailed"}"#),
            (.parseFailed(.parserReturnedNilRoot), #"{"failure":"parserReturnedNilRoot","kind":"parseFailed"}"#)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for (outcome, expectedJSON) in cases {
            let data = try encoder.encode(outcome)
            XCTAssertEqual(String(data: data, encoding: .utf8), expectedJSON)
            XCTAssertEqual(try JSONDecoder().decode(CodeMapSyntaxArtifactOutcome.self, from: data), outcome)
        }

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CodeMapSyntaxArtifactOutcome.self,
                from: Data(#"{"kind":"unsupported"}"#.utf8)
            )
        )
    }

    func testUnsupportedExtensionsRemainOutsideArtifactOutcomes() {
        XCTAssertNil(CodeMapSyntaxEngine.shared.language(forFileExtension: "unsupported"))
        XCTAssertFalse(CodeMapSyntaxEngine.supportsCodeMap(fileExtension: "unsupported"))
    }

    private func makeArtifact() -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: ["Foundation"],
            exports: ["Example"],
            classes: [
                ClassInfo(
                    name: "Example",
                    methods: [
                        FunctionInfo(
                            name: "run",
                            parameters: [],
                            returnType: "Void",
                            definitionLine: "func run()",
                            lineNumber: 3
                        )
                    ],
                    properties: [PropertyInfo(name: "value", typeName: "Int")]
                )
            ],
            interfaces: [],
            aliases: [TypeAliasInfo(name: "Count", definitionLine: "typealias Count = Int")],
            literalUnions: [],
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: ["Int", "Void"]
        )
    }

    private func recursiveKeys(_ value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, value in [key] + recursiveKeys(value) }
        }
        if let array = value as? [Any] {
            return array.flatMap(recursiveKeys)
        }
        return []
    }
}
