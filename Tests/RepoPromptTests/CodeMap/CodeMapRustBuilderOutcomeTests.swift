import AgentryCoreBridge
import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

/// P2 step 13: the legacy Swift `CodeMapSyntaxArtifactBuilder` (and its
/// `CodeMapSyntaxQuerying`/`QueryStub` mocking seam) was deleted once the
/// production Rust seam (`RustCodeMapArtifactBuilder`) was verified as a
/// hard-assertion match on all 13 fixtures (see
/// `docs/architecture/rust-codemap-compact-v1.md`, "Step 12/13 batch
/// differential" / "Step 13 verdict: GO").
///
/// The former `Tests/RepoPromptCodeMapCoreTests/CodeMapSyntaxArtifactTests.swift`
/// mixed two concerns: pure model (de)serialization tests (which stayed in
/// that file, unchanged, since `CodeMapSyntaxArtifact`/`CodeMapSyntaxArtifactOutcome`
/// are still the persisted model regardless of which engine produces them)
/// and builder-outcome-classification tests (decode-failed / empty /
/// oversize / parse-failed mapping), which lived here because Rust's own
/// test suite (`rust/crates/runtime/tests`) does not yet directly exercise
/// these outcome variants with matching boundary assertions -- so this
/// coverage is preserved here against the Rust seam rather than dropped.
///
/// Decode-failed, empty-source, comment-only, and line-count-oversize
/// outcomes are exercised for real (real content, real bridge, no mocking).
/// UTF-8/UTF-16 oversize and the two parse-failure outcomes are not
/// naturally reachable through real tree-sitter parsing of small fixture
/// content (a nil parse tree/root is a defensive branch, not something
/// valid grammars produce), so those cases inject a synthetic
/// `CoreCodeMapBatchResultV1` through `RustCodeMapArtifactBuilder`'s
/// `extract` seam -- this still exercises the real production
/// `RustCodeMapArtifactBuilder.materialize` mapping code, only replacing
/// the outer FFI transport response, the same pattern already used by
/// `CodeMapArtifactBuildCoordinatorTests`.
final class CodeMapRustBuilderOutcomeTests: XCTestCase {
    func testBuilderMapsDecodeFailedEmptyAndCommentOnlySourcesForReal() async throws {
        let builder = RustCodeMapArtifactBuilder()

        let decodeFailedOutcome = try await builder.build(source: makeFailedSource(), language: .swift)
        XCTAssertEqual(decodeFailedOutcome, .decodeFailed(.undecodable))

        let emptyOutcome = try await builder.build(source: makeSource(text: ""), language: .swift)
        XCTAssertEqual(emptyOutcome, .readyNoSymbols)

        let commentOnlyOutcome = try await builder.build(source: makeSource(text: "// comment only"), language: .swift)
        XCTAssertEqual(commentOnlyOutcome, .readyNoSymbols)
    }

    func testBuilderMapsRealLineCountOversize() async throws {
        let builder = RustCodeMapArtifactBuilder()
        let lineOversizeSource = makeSource(
            text: String(repeating: "\n", count: CodeMapSyntaxEngine.parseLineLimit)
        )
        let outcome = try await builder.build(source: lineOversizeSource, language: .swift)
        XCTAssertEqual(
            outcome,
            .oversize(
                .lines(
                    actual: CodeMapSyntaxEngine.parseLineLimit + 1,
                    limit: CodeMapSyntaxEngine.parseLineLimit
                )
            )
        )
    }

    func testBuilderMapsCoreUTF16OversizeOutcome() async throws {
        let text = "let value = 1"
        let outcome = try await buildWithSyntheticOutcome(
            text: text,
            language: .swift,
            outcome: .oversizeUTF16Units(actual: 11, limit: 10)
        )
        XCTAssertEqual(outcome, .oversize(.utf16Units(actual: 11, limit: 10)))
    }

    func testBuilderMapsCoreParseFailedNilTreeOutcome() async throws {
        let text = "let value = 1"
        let outcome = try await buildWithSyntheticOutcome(
            text: text,
            language: .swift,
            outcome: .parseFailedNilTree
        )
        XCTAssertEqual(outcome, .parseFailed(.parserReturnedNilTree))
    }

    func testBuilderMapsCoreParseFailedNilRootOutcome() async throws {
        let text = "let value = 1"
        let outcome = try await buildWithSyntheticOutcome(
            text: text,
            language: .swift,
            outcome: .parseFailedNilRoot
        )
        XCTAssertEqual(outcome, .parseFailed(.parserReturnedNilRoot))
    }

    func testBuilderPropagatesExactTransportError() async throws {
        struct TransportProbeError: Error, Equatable {}
        let builder = RustCodeMapArtifactBuilder { _ in throw TransportProbeError() }

        do {
            _ = try await builder.build(source: makeSource(text: "struct Example {}"), language: .swift)
            XCTFail("Expected the transport error to propagate")
        } catch let error as TransportProbeError {
            XCTAssertEqual(error, TransportProbeError())
        }
    }

    func testReadyArtifactIsDeterministicAcrossSourceMetadataAndHasNoFilenameInput() async throws {
        let content = """
        struct Example {
            let value: Int
        }
        """
        let builder = RustCodeMapArtifactBuilder()
        let first = makeSource(text: content, digestSeed: 1)
        let second = makeSource(text: content, digestSeed: 50)
        let firstOutcome = try await builder.build(source: first, language: .swift)
        let repeatedOutcome = try await builder.build(source: first, language: .swift)
        let otherMetadataOutcome = try await builder.build(source: second, language: .swift)

        XCTAssertEqual(firstOutcome, repeatedOutcome)
        XCTAssertEqual(firstOutcome, otherMetadataOutcome)
        guard case let .ready(artifact) = firstOutcome else {
            return XCTFail("Expected representative Swift content to produce an artifact.")
        }
        XCTAssertEqual(artifact.classes.map(\.name), ["Example"])
        XCTAssertFalse(artifact.apiDescription.contains("source.swift"))
        XCTAssertFalse(artifact.apiDescription.contains("other-name.swift"))

        let javaOutcome = try await builder.build(
            source: makeSource(text: "void helper() {}"),
            language: .java
        )
        guard case let .ready(javaArtifact) = javaOutcome else {
            return XCTFail("Expected representative Java content to produce an artifact.")
        }
        XCTAssertEqual(javaArtifact.functions.map(\.name), ["helper"])
        XCTAssertTrue(javaArtifact.classes.isEmpty)
    }

    // MARK: - Helpers

    private func buildWithSyntheticOutcome(
        text: String,
        language: LanguageType,
        outcome: CoreCodeMapSubjectOutcome
    ) async throws -> CodeMapSyntaxArtifactOutcome {
        let byteCount = UInt64(Data(text.utf8).count)
        let builder = RustCodeMapArtifactBuilder { _ in
            .init(subjects: [
                .init(languageID: language.coreCodeMapLanguageID, sourceByteCount: byteCount, outcome: outcome)
            ])
        }
        return try await builder.build(source: makeSource(text: text), language: language)
    }

    private func makeSource(text: String, digestSeed: UInt8 = 1) -> CodeMapCoreSourceSnapshot {
        let data = Data(text.utf8)
        var digestInput = data
        digestInput.append(digestSeed)
        return CodeMapCoreSourceSnapshot(
            rawByteCount: data.count,
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: digestInput))),
            decoderPolicy: .workspaceAutomaticV1,
            decodeResult: .decoded(
                CodeMapDecodedSource(
                    text: text,
                    detectedEncodingRawValue: String.Encoding.utf8.rawValue
                )
            ),
            rawBytes: data
        )
    }

    private func makeFailedSource() -> CodeMapCoreSourceSnapshot {
        let bytes = Data([0xFF, 0xFE, 0x00, 0xD8])
        return CodeMapCoreSourceSnapshot(
            rawByteCount: bytes.count,
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: bytes))),
            decoderPolicy: .workspaceAutomaticV1,
            decodeResult: .failed(.undecodable),
            rawBytes: bytes
        )
    }
}
