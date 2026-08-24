@testable import RepoPromptApp
import XCTest

final class GitignoreCompilerCharacterizationTests: XCTestCase {
    func testParserSkipsCommentsAndPreservesEscapedLeadingMarkers() {
        let compiled = GitignoreCompiler.compile(content: """

          # comment after leading whitespace
        \\#literal
        \\!literal
        !\\!allowed
        """)

        XCTAssertEqual(compiled.outcome(for: "#literal", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "!literal", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "!allowed", isDirectory: false), .allow)
        XCTAssertEqual(compiled.outcome(for: "comment after leading whitespace", isDirectory: false), .noMatch)
    }

    func testParserNormalizesSlashesAndScopesSlashPatternsToIgnoreDirectory() {
        let compiled = GitignoreCompiler.compile(
            content: "  /foo//bar/  ",
            directoryPath: "nested/"
        )

        XCTAssertEqual(compiled.outcome(for: "nested/foo/bar", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "nested/foo/bar/file.txt", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "foo/bar", isDirectory: true), .noMatch)
        XCTAssertEqual(compiled.outcome(for: "other/nested/foo/bar", isDirectory: true), .noMatch)
    }

    func testParserTrimsUnescapedTrailingWhitespaceAndPreservesEscapedWhitespace() {
        let compiled = GitignoreCompiler.compile(content: "plain   \nescaped\\ \ntabbed\\\t")

        XCTAssertEqual(compiled.outcome(for: "plain", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "plain ", isDirectory: false), .noMatch)
        XCTAssertEqual(compiled.outcome(for: "escaped ", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "tabbed\t", isDirectory: false), .ignore)
    }

    func testParserUsesA1023BytePatternBufferAndCStringPrefixes() {
        let boundary = String(repeating: "a", count: 1023)
        let overlong = boundary + "b"
        let nulTerminated = "prefix\0ignored"
        let compiled = GitignoreCompiler.compile(content: "\(boundary)\n\(overlong)\n\(nulTerminated)")

        XCTAssertEqual(compiled.outcome(for: boundary, isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: overlong, isDirectory: false), .noMatch)
        XCTAssertEqual(compiled.outcome(for: "prefix", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "prefixignored", isDirectory: false), .noMatch)
    }

    func testSlashlessPatternsMatchBasenamesAtAnyDepth() {
        let compiled = GitignoreCompiler.compile(content: "*.log\nfile?.txt\n[ab].md\n[!a].swift\n[[:digit:]].csv")

        XCTAssertEqual(compiled.outcome(for: "nested/deep.log", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "nested/file1.txt", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "a.md", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "b.swift", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "7.csv", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "a.swift", isDirectory: false), .noMatch)
        XCTAssertEqual(compiled.outcome(for: "nested/file10.txt", isDirectory: false), .noMatch)
    }

    func testGitignoreMatchingIsCaseSensitiveAndDoesNotProtectLeadingPeriods() {
        let compiled = GitignoreCompiler.compile(content: "*.LOG\n*")

        XCTAssertEqual(compiled.outcome(for: ".hidden", isDirectory: false), .ignore)
        XCTAssertEqual(GitignoreCompiler.compile(content: "*.LOG").outcome(for: "trace.log", isDirectory: false), .noMatch)
        XCTAssertEqual(GitignoreCompiler.compile(content: "*.LOG").outcome(for: "trace.LOG", isDirectory: false), .ignore)
    }

    func testGlobstarOnlyCrossesDirectoriesAtRecognizedBoundaries() {
        let compiled = GitignoreCompiler.compile(content: "a/**/b\nlogs/**\na**b")

        XCTAssertEqual(compiled.outcome(for: "a/b", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "a/one/two/b", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "logs", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "logs/archive/old.txt", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "axxb", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "a/x/b", isDirectory: false), .ignore)
    }

    func testAnchoringDirectoryAncestryAndReversePrecedenceRemainStable() {
        let compiled = GitignoreCompiler.compile(content: """
        /build/
        logs/
        !logs/keep.log
        logs/keep.log
        !logs/keep.log
        """)

        XCTAssertEqual(compiled.outcome(for: "build", isDirectory: true), .ignore)
        XCTAssertEqual(compiled.outcome(for: "build/output.txt", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "src/build", isDirectory: true), .noMatch)
        XCTAssertEqual(compiled.outcome(for: "src/logs/debug.log", isDirectory: false), .ignore)
        XCTAssertEqual(compiled.outcome(for: "logs/keep.log", isDirectory: false), .allow)
        XCTAssertTrue(compiled.requiresTraversal(for: "logs"))
    }

    func testEmptyPathAndOverlongBasenameBehaviorRemainStable() {
        XCTAssertEqual(GitignoreCompiler.compile(content: "**").outcome(for: "", isDirectory: false), .ignore)
        XCTAssertEqual(GitignoreCompiler.compile(content: "*").outcome(for: "", isDirectory: false), .noMatch)

        let overlongBasename = String(repeating: "x", count: 1024)
        XCTAssertEqual(
            GitignoreCompiler.compile(content: "*").outcome(for: overlongBasename, isDirectory: false),
            .noMatch
        )
        XCTAssertEqual(
            GitignoreCompiler.compile(content: "x*").outcome(for: "parent/\(overlongBasename)", isDirectory: false),
            .noMatch
        )
    }
}
