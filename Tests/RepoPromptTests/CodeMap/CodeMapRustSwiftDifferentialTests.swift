import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

/// Step 12 batch differential: runs the legacy Swift codemap extractor
/// (`CodeMapSyntaxArtifactBuilder`) and the Rust-backed production seam
/// (`RustCodeMapArtifactBuilder`, real `AgentryCoreBridge` runtime, no mocking)
/// against every fixture in `Tests/RepoPromptCodeMapCoreTests/Fixtures` and
/// asserts field-by-field artifact parity per
/// `docs/architecture/rust-codemap-compact-v1.md` §Parity.
///
/// This reads the codemap fixture corpus directly off disk (via `#filePath`)
/// rather than depending on the `RepoPromptCodeMapCoreTests` target's
/// `Bundle.module` resources, so no `Package.swift` target/dependency change
/// is required. Fixture list intentionally mirrors
/// `Tests/RepoPromptCodeMapCoreTests/CodeMapFixtureRunner.allFixtureRelativePaths`.
final class CodeMapRustSwiftDifferentialTests: XCTestCase {
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

    func testAllCodeMapFixturesProduceIdenticalArtifactsAcrossSwiftAndRustEngines() async throws {
        try Self.assertFixtureListMatchesOnDiskCorpus()

        let rustBuilder = RustCodeMapArtifactBuilder()
        var failures: [String] = []

        for relativePath in Self.fixtureRelativePaths {
            do {
                try await Self.diffFixture(relativePath, rustBuilder: rustBuilder, into: &failures)
            } catch {
                failures.append("\(relativePath): fixture setup failed: \(error)")
            }
        }

        // Step 12/13 gate (see docs/architecture/rust-codemap-compact-v1.md):
        // the legacy Swift extractor and the Rust production seam must
        // produce field-identical persisted artifacts -- all persisted
        // fields and array order, not just the rendered summary text. This
        // is a hard assertion, not an expected failure: a regression here
        // must fail CI.
        XCTAssertTrue(
            failures.isEmpty,
            "Codemap Swift/Rust differential mismatches (\(failures.count)):\n" + failures.joined(separator: "\n")
        )
    }

    /// Decisive check: does the *shipped* production seam (Rust) still render
    /// the same `apiDescription`/imports text the committed goldens assert on?
    /// `CodeMapGoldenTests` in `RepoPromptCodeMapCoreTests` only exercises the
    /// legacy Swift extractor, so it cannot catch a Rust-side rendering
    /// regression after `db53cf09` switched the production seam to Rust.
    func testAllCodeMapFixturesRustEngineMatchesCommittedGoldens() async throws {
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

    private static func diffFixture(
        _ relativePath: String,
        rustBuilder: RustCodeMapArtifactBuilder,
        into failures: inout [String]
    ) async throws {
        let content = try loadFixtureContent(relativePath: relativePath)
        let fileExtension = (relativePath as NSString).pathExtension
        guard let language = CodeMapSyntaxEngine.shared.language(forFileExtension: fileExtension) else {
            failures.append("\(relativePath): unsupported fixture extension \(fileExtension)")
            return
        }
        let snapshot = makeSourceSnapshot(content: content)

        let swiftOutcome: CodeMapSyntaxArtifactOutcome
        do {
            swiftOutcome = try CodeMapSyntaxArtifactBuilder.build(source: snapshot, language: language)
        } catch {
            failures.append("\(relativePath): Swift extractor threw \(error)")
            return
        }

        let rustOutcome: CodeMapSyntaxArtifactOutcome
        do {
            rustOutcome = try await rustBuilder.build(source: snapshot, language: language)
        } catch {
            failures.append("\(relativePath): Rust extractor threw \(error)")
            return
        }

        if swiftOutcome == rustOutcome {
            return
        }

        guard case let .ready(swiftArtifact) = swiftOutcome, case let .ready(rustArtifact) = rustOutcome else {
            failures.append("\(relativePath): outcome case differs: swift=\(swiftOutcome) rust=\(rustOutcome)")
            return
        }

        let mismatches = CodeMapArtifactDiffer.diff(swift: swiftArtifact, rust: rustArtifact)
        for mismatch in mismatches {
            failures.append("\(relativePath): \(mismatch.field): \(mismatch.detail)")
        }
        // `CodeMapArtifactDiffer` is a best-effort, field-by-field differ
        // used only to render an actionable message; the actual gate above
        // is `swiftOutcome == rustOutcome` (derived `Equatable`, covering
        // every field including any the differ doesn't yet model). If the
        // two `.ready` artifacts are `Equatable`-unequal but the differ
        // reports zero mismatches, the differ is incomplete -- fail loudly
        // instead of silently passing on an undetected divergence.
        if mismatches.isEmpty {
            failures.append(
                "\(relativePath): CodeMapSyntaxArtifact instances are Equatable-unequal but " +
                    "CodeMapArtifactDiffer found no field-level mismatch -- the differ is incomplete " +
                    "and must be extended to cover the diverging field."
            )
        }
    }

    /// Guards against silent corpus drift: if a fixture file is added to or
    /// removed from `Tests/RepoPromptCodeMapCoreTests/Fixtures` without this
    /// list being updated to match, this fails with the exact set
    /// difference instead of the differential silently covering fewer (or
    /// more, harmlessly ignored) fixtures than actually exist on disk.
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
            "On-disk fixture corpus drifted from the differential's hardcoded list. " +
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

/// Field-by-field artifact differ used only to render an actionable failure
/// message; the pass/fail gate is `CodeMapSyntaxArtifactOutcome` exact
/// `Equatable` equality above.
private enum CodeMapArtifactDiffer {
    struct Mismatch {
        let field: String
        let detail: String
    }

    static func diff(swift: CodeMapSyntaxArtifact, rust: CodeMapSyntaxArtifact) -> [Mismatch] {
        var mismatches: [Mismatch] = []

        diffArray("imports", swift.imports, rust.imports, into: &mismatches)
        diffArray("exports", swift.exports, rust.exports, into: &mismatches)
        diffArray("literalUnions", swift.literalUnions, rust.literalUnions, into: &mismatches)
        diffArray("macros", swift.macros, rust.macros, into: &mismatches)
        diffArray("referencedTypes", swift.referencedTypes, rust.referencedTypes, into: &mismatches)
        diffAliases(swift.aliases, rust.aliases, into: &mismatches)
        diffEnums(swift.enums, rust.enums, into: &mismatches)
        diffGlobalVars(swift.globalVars, rust.globalVars, into: &mismatches)
        diffFunctions("functions", swift.functions, rust.functions, into: &mismatches)
        diffClasses(swift.classes, rust.classes, into: &mismatches)
        diffInterfaces(swift.interfaces, rust.interfaces, into: &mismatches)

        if swift.apiDescription != rust.apiDescription {
            mismatches.append(Mismatch(
                field: "apiDescription",
                detail: "swift=\(swift.apiDescription.debugDescription) rust=\(rust.apiDescription.debugDescription)"
            ))
        }
        if swift.definedTypeNames != rust.definedTypeNames {
            mismatches.append(Mismatch(
                field: "definedTypeNames",
                detail: "swift=\(swift.definedTypeNames.sorted()) rust=\(rust.definedTypeNames.sorted())"
            ))
        }

        return mismatches
    }

    private static func diffArray<T: Equatable>(
        _ field: String,
        _ lhs: [T],
        _ rhs: [T],
        into mismatches: inout [Mismatch]
    ) {
        guard lhs.count == rhs.count else {
            mismatches.append(Mismatch(field: field, detail: "count swift=\(lhs.count) rust=\(rhs.count)"))
            return
        }
        for (index, pair) in zip(lhs, rhs).enumerated() where pair.0 != pair.1 {
            mismatches.append(Mismatch(field: "\(field)[\(index)]", detail: "swift=\(pair.0) rust=\(pair.1)"))
        }
    }

    private static func diffAliases(
        _ lhs: [TypeAliasInfo],
        _ rhs: [TypeAliasInfo],
        into mismatches: inout [Mismatch]
    ) {
        guard lhs.count == rhs.count else {
            mismatches.append(Mismatch(field: "aliases", detail: "count swift=\(lhs.count) rust=\(rhs.count)"))
            return
        }
        for (index, pair) in zip(lhs, rhs).enumerated() {
            let base = "aliases[\(index)]"
            if pair.0.name != pair.1.name {
                mismatches.append(Mismatch(field: "\(base).name", detail: "swift=\(pair.0.name) rust=\(pair.1.name)"))
            }
            if pair.0.definitionLine != pair.1.definitionLine {
                mismatches.append(Mismatch(
                    field: "\(base).definitionLine",
                    detail: "swift=\(pair.0.definitionLine.debugDescription) rust=\(pair.1.definitionLine.debugDescription)"
                ))
            }
        }
    }

    private static func diffEnums(_ lhs: [EnumInfo], _ rhs: [EnumInfo], into mismatches: inout [Mismatch]) {
        guard lhs.count == rhs.count else {
            mismatches.append(Mismatch(field: "enums", detail: "count swift=\(lhs.count) rust=\(rhs.count)"))
            return
        }
        for (index, pair) in zip(lhs, rhs).enumerated() {
            let base = "enums[\(index)]"
            if pair.0.name != pair.1.name {
                mismatches.append(Mismatch(field: "\(base).name", detail: "swift=\(pair.0.name) rust=\(pair.1.name)"))
            }
            diffArray("\(base).cases", pair.0.cases, pair.1.cases, into: &mismatches)
        }
    }

    private static func diffGlobalVars(
        _ lhs: [VariableInfo],
        _ rhs: [VariableInfo],
        into mismatches: inout [Mismatch]
    ) {
        guard lhs.count == rhs.count else {
            mismatches.append(Mismatch(field: "globalVars", detail: "count swift=\(lhs.count) rust=\(rhs.count)"))
            return
        }
        for (index, pair) in zip(lhs, rhs).enumerated() {
            let base = "globalVars[\(index)]"
            if pair.0.name != pair.1.name {
                mismatches.append(Mismatch(field: "\(base).name", detail: "swift=\(pair.0.name) rust=\(pair.1.name)"))
            }
            if pair.0.typeName != pair.1.typeName {
                mismatches.append(Mismatch(
                    field: "\(base).typeName",
                    detail: "swift=\(String(describing: pair.0.typeName)) rust=\(String(describing: pair.1.typeName))"
                ))
            }
            if pair.0.definitionLine != pair.1.definitionLine {
                mismatches.append(Mismatch(
                    field: "\(base).definitionLine",
                    detail: "swift=\(pair.0.definitionLine.debugDescription) rust=\(pair.1.definitionLine.debugDescription)"
                ))
            }
        }
    }

    private static func diffProperties(
        _ base: String,
        _ lhs: [PropertyInfo],
        _ rhs: [PropertyInfo],
        into mismatches: inout [Mismatch]
    ) {
        guard lhs.count == rhs.count else {
            mismatches.append(Mismatch(field: base, detail: "count swift=\(lhs.count) rust=\(rhs.count)"))
            return
        }
        for (index, pair) in zip(lhs, rhs).enumerated() {
            let field = "\(base)[\(index)]"
            if pair.0.name != pair.1.name {
                mismatches.append(Mismatch(field: "\(field).name", detail: "swift=\(pair.0.name) rust=\(pair.1.name)"))
            }
            if pair.0.typeName != pair.1.typeName {
                mismatches.append(Mismatch(
                    field: "\(field).typeName",
                    detail: "swift=\(String(describing: pair.0.typeName)) rust=\(String(describing: pair.1.typeName))"
                ))
            }
        }
    }

    private static func diffFunctions(
        _ base: String,
        _ lhs: [FunctionInfo],
        _ rhs: [FunctionInfo],
        into mismatches: inout [Mismatch]
    ) {
        guard lhs.count == rhs.count else {
            mismatches.append(Mismatch(field: base, detail: "count swift=\(lhs.count) rust=\(rhs.count)"))
            return
        }
        for (index, pair) in zip(lhs, rhs).enumerated() {
            let field = "\(base)[\(index)]"
            let (l, r) = pair
            if l.name != r.name {
                mismatches.append(Mismatch(field: "\(field).name", detail: "swift=\(l.name) rust=\(r.name)"))
            }
            if l.returnType != r.returnType {
                mismatches.append(Mismatch(
                    field: "\(field).returnType",
                    detail: "swift=\(String(describing: l.returnType)) rust=\(String(describing: r.returnType))"
                ))
            }
            if l.definitionLine != r.definitionLine {
                mismatches.append(Mismatch(
                    field: "\(field).definitionLine",
                    detail: "swift=\(l.definitionLine.debugDescription) rust=\(r.definitionLine.debugDescription)"
                ))
            }
            if l.lineNumber != r.lineNumber {
                mismatches.append(Mismatch(
                    field: "\(field).lineNumber",
                    detail: "swift=\(String(describing: l.lineNumber)) rust=\(String(describing: r.lineNumber))"
                ))
            }
            guard l.parameters.count == r.parameters.count else {
                mismatches.append(Mismatch(
                    field: "\(field).parameters",
                    detail: "count swift=\(l.parameters.count) rust=\(r.parameters.count)"
                ))
                continue
            }
            for (pIndex, pPair) in zip(l.parameters, r.parameters).enumerated() where pPair.0 != pPair.1 {
                mismatches.append(Mismatch(
                    field: "\(field).parameters[\(pIndex)]",
                    detail: "swift=\(pPair.0) rust=\(pPair.1)"
                ))
            }
        }
    }

    private static func diffClasses(_ lhs: [ClassInfo], _ rhs: [ClassInfo], into mismatches: inout [Mismatch]) {
        guard lhs.count == rhs.count else {
            mismatches.append(Mismatch(field: "classes", detail: "count swift=\(lhs.count) rust=\(rhs.count)"))
            return
        }
        for (index, pair) in zip(lhs, rhs).enumerated() {
            let base = "classes[\(index)]"
            if pair.0.name != pair.1.name {
                mismatches.append(Mismatch(field: "\(base).name", detail: "swift=\(pair.0.name) rust=\(pair.1.name)"))
            }
            diffFunctions("\(base).methods", pair.0.methods, pair.1.methods, into: &mismatches)
            diffProperties("\(base).properties", pair.0.properties, pair.1.properties, into: &mismatches)
        }
    }

    private static func diffInterfaces(
        _ lhs: [InterfaceInfo],
        _ rhs: [InterfaceInfo],
        into mismatches: inout [Mismatch]
    ) {
        guard lhs.count == rhs.count else {
            mismatches.append(Mismatch(field: "interfaces", detail: "count swift=\(lhs.count) rust=\(rhs.count)"))
            return
        }
        for (index, pair) in zip(lhs, rhs).enumerated() {
            let base = "interfaces[\(index)]"
            if pair.0.name != pair.1.name {
                mismatches.append(Mismatch(field: "\(base).name", detail: "swift=\(pair.0.name) rust=\(pair.1.name)"))
            }
            diffFunctions("\(base).methods", pair.0.methods, pair.1.methods, into: &mismatches)
            diffProperties("\(base).properties", pair.0.properties, pair.1.properties, into: &mismatches)
        }
    }
}
