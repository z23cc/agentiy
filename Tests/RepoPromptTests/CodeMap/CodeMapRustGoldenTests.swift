import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

/// P2 step 13: Rust production seam (`RustCodeMapArtifactBuilder`, real
/// `AgentryCoreBridge` runtime, no mocking) vs the committed golden corpus
/// in `Tests/RepoPromptCodeMapCoreTests/{Fixtures,Goldens}`.
///
/// This used to be one half of a Swift-vs-Rust differential
/// (`CodeMapRustSwiftDifferentialTests`) that also ran the legacy Swift
/// `CodeMapSyntaxArtifactBuilder`/`CodeMapGenerator` extraction stack as a
/// reference implementation. That differential passed as a hard assertion
/// with 0 field-level mismatches across all 13 fixtures (see
/// `docs/architecture/rust-codemap-compact-v1.md`, "Step 12/13 batch
/// differential" / "Step 13 verdict: GO") immediately before the legacy
/// Swift extraction stack was deleted. With no Swift reference left, this
/// file keeps only the golden comparison -- the Rust engine is now the sole
/// production codemap compute path, and this is its release-confirmation
/// gate against the committed behavior contract.
///
/// This reads the codemap fixture corpus directly off disk (via `#filePath`)
/// rather than depending on the `RepoPromptCodeMapCoreTests` target's
/// `Bundle.module` resources, so no `Package.swift` target/dependency change
/// is required. Fixture list intentionally mirrors
/// `Tests/RepoPromptCodeMapCoreTests/CodeMapFixtureRunner.allFixtureRelativePaths`.
final class CodeMapRustGoldenTests: XCTestCase {
    private static let fixtureRelativePaths = [
        // CE/core
        "c/smoke.c",
        "go/smoke.go",
        "py/smoke.py",
        "swift/smoke.swift",
        "ts/smoke.ts",
        // expanded languages
        "cs/smoke.cs",
        "java/smoke.java",
        "js/smoke.js",
        "rb/smoke.rb",
        "rs/smoke.rs",
        // edge fixtures
        "cpp/edge_methods.cpp",
        "php/edge_namespaces.php",
        "tsx/component.tsx"
    ]

    /// Decisive check: does the *shipped* production seam (Rust) still render
    /// the same `apiDescription`/imports text the committed goldens assert on?
    /// `CodeMapGoldenTests` in `RepoPromptCodeMapCoreTests` was deleted along
    /// with the legacy Swift extractor it exercised (P2 step 13), so this is
    /// now the only golden-comparison coverage for the codemap pipeline.
    func testAllCodeMapFixturesRustEngineMatchesCommittedGoldens() async throws {
        try Self.assertFixtureListMatchesOnDiskCorpus()

        let rustBuilder = RustCodeMapArtifactBuilder()
        var failures: [String] = []
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapRustGoldenDifferential", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for relativePath in Self.fixtureRelativePaths {
            do {
                let rendered = try await Self.renderRustArtifactCodeMap(
                    relativePath: relativePath,
                    rustBuilder: rustBuilder,
                    tempRoot: tempRoot
                )
                let expected = try Self.loadGolden(relativePath: relativePath)
                if rendered != expected {
                    failures.append("\(relativePath): rendered codemap differs from committed golden\n--- golden ---\n\(expected)--- rust ---\n\(rendered)")
                }
            } catch {
                failures.append("\(relativePath): \(error)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Rust engine vs committed golden mismatches (\(failures.count)):\n" + failures.joined(separator: "\n")
        )
    }

    /// Guards against silent corpus drift: if a fixture file is added to or
    /// removed from `Tests/RepoPromptCodeMapCoreTests/Fixtures` without this
    /// list being updated to match, this fails with the exact set
    /// difference instead of the golden comparison silently covering fewer
    /// (or more, harmlessly ignored) fixtures than actually exist on disk.
    private static func assertFixtureListMatchesOnDiskCorpus() throws {
        let fixturesRoot = codeMapCoreTestsRoot(subdirectory: "Fixtures")
        let fileManager = FileManager.default
        let onDiskFiles = try fileManager.subpathsOfDirectory(atPath: fixturesRoot.path)
            .filter { relativePath in
                var isDirectory: ObjCBool = false
                let fullPath = fixturesRoot.appendingPathComponent(relativePath).path
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else { return false }
                return !isDirectory.boolValue && !relativePath.hasSuffix(".DS_Store")
            }
        let expected = Set(fixtureRelativePaths)
        let actual = Set(onDiskFiles)
        XCTAssertEqual(
            actual, expected,
            "On-disk fixture corpus drifted from the golden test's hardcoded list. " +
                "On disk but not in list: \(actual.subtracting(expected).sorted()). " +
                "In list but missing on disk: \(expected.subtracting(actual).sorted())."
        )
    }

    private static func loadFixtureContent(relativePath: String) throws -> String {
        let url = codeMapCoreTestsRoot(subdirectory: "Fixtures").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func loadGolden(relativePath: String) throws -> String {
        let languageDirectory = (relativePath as NSString).deletingLastPathComponent
        let fileName = (relativePath as NSString).lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension
        let url = codeMapCoreTestsRoot(subdirectory: "Goldens")
            .appendingPathComponent("\(languageDirectory)_\(baseName).codemap.txt")
        return try normalize(String(contentsOf: url, encoding: .utf8))
    }

    /// #filePath -> .../Tests/RepoPromptTests/CodeMap/CodeMapRustSwiftDifferentialTests.swift
    private static func codeMapCoreTestsRoot(subdirectory: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CodeMap
            .deletingLastPathComponent() // RepoPromptTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("RepoPromptCodeMapCoreTests/\(subdirectory)", isDirectory: true)
    }

    private static func renderRustArtifactCodeMap(
        relativePath: String,
        rustBuilder: RustCodeMapArtifactBuilder,
        tempRoot: URL
    ) async throws -> String {
        let content = try loadFixtureContent(relativePath: relativePath)
        let fileExtension = (relativePath as NSString).pathExtension
        guard let language = CodeMapSyntaxEngine.shared.language(forFileExtension: fileExtension) else {
            throw CodeMapFixtureError.unsupportedExtension(fileExtension)
        }
        let snapshot = makeSourceSnapshot(content: content)
        guard case let .ready(artifact) = try await rustBuilder.build(source: snapshot, language: language) else {
            throw CodeMapFixtureError.noArtifact(relativePath)
        }
        let virtualURL = tempRoot.appendingPathComponent(relativePath)
        let pathAndImports = (["File: \(virtualURL.path)", "Imports:"] + artifact.imports.map { "  - \($0)" })
            .joined(separator: "\n")
        return normalize(pathAndImports + artifact.apiDescription, tempRoot: tempRoot)
    }

    private static func normalize(_ text: String, tempRoot: URL? = nil) -> String {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if let tempRoot {
            normalized = normalized.replacingOccurrences(of: tempRoot.path, with: "<ROOT>")
        }
        while normalized.hasSuffix("\n\n") {
            normalized.removeLast()
        }
        if !normalized.hasSuffix("\n") {
            normalized.append("\n")
        }
        return normalized
    }

    private static func makeSourceSnapshot(content: String) -> CodeMapCoreSourceSnapshot {
        let data = Data(content.utf8)
        return CodeMapCoreSourceSnapshot(
            rawByteCount: data.count,
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: data))),
            decoderPolicy: .workspaceAutomaticV1,
            decodeResult: .decoded(
                CodeMapDecodedSource(text: content, detectedEncodingRawValue: String.Encoding.utf8.rawValue)
            )
        )
    }
}

private enum CodeMapFixtureError: Error, CustomStringConvertible {
    case unsupportedExtension(String)
    case noArtifact(String)

    var description: String {
        switch self {
        case let .unsupportedExtension(fileExtension):
            "Unsupported fixture extension: \(fileExtension)"
        case let .noArtifact(path):
            "No CodeMapSyntaxArtifact generated for \(path)"
        }
    }
}
