@testable import RepoPromptDomainRuntime
import XCTest

final class WildmatchCompatibilityTests: XCTestCase {
    func testRawOptionValuesMatchTheRetiredCHeader() {
        XCTAssertEqual(RepoWildmatchOptions.noEscape.rawValue, 0x01)
        XCTAssertEqual(RepoWildmatchOptions.pathname.rawValue, 0x02)
        XCTAssertEqual(RepoWildmatchOptions.period.rawValue, 0x04)
        XCTAssertEqual(RepoWildmatchOptions.leadingDir.rawValue, 0x08)
        XCTAssertEqual(RepoWildmatchOptions.caseFold.rawValue, 0x10)
        XCTAssertEqual(RepoWildmatchOptions.prefixDirs.rawValue, 0x20)
        XCTAssertEqual(RepoWildmatchOptions.wildstar.rawValue, 0x40)
    }

    func testGenericMatchingPreservesCaseFoldPathnameAndWildstarInteraction() {
        XCTAssertTrue(RepoWildmatch.matches(pattern: "*.LOG", text: "nested/trace.log", options: .caseFold))
        XCTAssertFalse(RepoWildmatch.matches(
            pattern: "*.LOG",
            text: "nested/trace.log",
            options: [.caseFold, .wildstar]
        ))
        XCTAssertTrue(RepoWildmatch.matches(pattern: "a*", text: "a/b"))
        XCTAssertFalse(RepoWildmatch.matches(pattern: "a*", text: "a/b", options: .pathname))
        XCTAssertTrue(RepoWildmatch.matches(pattern: "**/*.LOG", text: "nested/trace.log", options: [.caseFold, .wildstar]))
        XCTAssertTrue(RepoWildmatch.matches(pattern: "**/*.LOG", text: "trace.LOG", options: [.caseFold, .wildstar]))
        XCTAssertFalse(RepoWildmatch.matches(pattern: "a**b", text: "axxb", options: .wildstar))
    }

    func testEscapingPeriodAndLeadingDirectoryFlagsRemainIndependent() {
        XCTAssertTrue(RepoWildmatch.matches(pattern: "foo/\\*.log", text: "foo/*.log", options: .caseFold))
        XCTAssertFalse(RepoWildmatch.matches(pattern: "foo/\\*.log", text: "foo/bar.log", options: .caseFold))
        XCTAssertFalse(RepoWildmatch.matches(pattern: "*", text: ".hidden", options: .period))
        XCTAssertTrue(RepoWildmatch.matches(pattern: ".*", text: ".hidden", options: .period))
        XCTAssertTrue(RepoWildmatch.matches(pattern: "folder", text: "folder/child", options: [.pathname, .leadingDir]))
        XCTAssertFalse(RepoWildmatch.matches(pattern: "folder", text: "folder/child", options: [.pathname, .prefixDirs]))
    }

    func testRangesPOSIXClassesAndMalformedRangesMatchTheBundledCBehavior() {
        XCTAssertTrue(RepoWildmatch.matches(pattern: "[a-c]", text: "b"))
        XCTAssertTrue(RepoWildmatch.matches(pattern: "[!a]", text: "b"))
        XCTAssertFalse(RepoWildmatch.matches(pattern: "[!a]", text: "a"))
        XCTAssertTrue(RepoWildmatch.matches(pattern: "[[:digit:]]", text: "7"))
        XCTAssertTrue(RepoWildmatch.matches(pattern: "[[:upper:]]", text: "q", options: .caseFold))
        XCTAssertFalse(RepoWildmatch.matches(pattern: "[A-Ā]*", text: "z"))

        XCTAssertFalse(RepoWildmatch.matches(pattern: "[", text: "["))
        XCTAssertTrue(RepoWildmatch.matches(pattern: "[", text: "x["))
        XCTAssertFalse(RepoWildmatch.matches(pattern: "[a", text: "[a"))
        XCTAssertTrue(RepoWildmatch.matches(pattern: "[a", text: "x[a"))
    }

    func testMatchingUsesCStringPrefixesAndASCIICaseFoldingOnly() {
        XCTAssertTrue(RepoWildmatch.matches(pattern: "prefix\0ignored", text: "prefix\0different"))
        XCTAssertTrue(RepoWildmatch.matches(pattern: "ABC", text: "abc", options: .caseFold))
        XCTAssertFalse(RepoWildmatch.matches(pattern: "Ä", text: "ä", options: .caseFold))
    }

    func testGitignoreWrappersPreserveAnchoredAnywhereAndBufferSemantics() {
        XCTAssertFalse(RepoWildmatch.gitignoreMatchesAnchored(pattern: "**", path: "a/b"))
        XCTAssertTrue(RepoWildmatch.gitignoreMatchesAnchored(pattern: "**", path: ""))
        XCTAssertTrue(RepoWildmatch.gitignoreMatchesAnywhere(pattern: "**", path: "a/b"))
        XCTAssertFalse(RepoWildmatch.gitignoreMatchesAnywhere(pattern: "*", path: ""))
        XCTAssertTrue(RepoWildmatch.gitignoreMatchesAnywhere(pattern: "*", path: "a/b"))
        XCTAssertTrue(RepoWildmatch.gitignoreMatchesAnywhere(pattern: "a/**/b", path: "a/b"))
        XCTAssertTrue(RepoWildmatch.gitignoreMatchesAnywhere(pattern: "a/**/b", path: "x/a/q/b"))
        XCTAssertTrue(RepoWildmatch.gitignoreMatchesAnywhere(pattern: "logs/**", path: "logs"))

        let overlongBasename = String(repeating: "x", count: 1024)
        XCTAssertFalse(RepoWildmatch.gitignoreMatchesAnywhere(pattern: "*", path: overlongBasename))
        // The C wrapper returns on the first matching basename, before it reaches
        // the later overlong component and its 1024-byte rejection.
        XCTAssertTrue(RepoWildmatch.gitignoreMatchesAnywhere(pattern: "*", path: "parent/\(overlongBasename)"))
    }

    func testGitignoreLineParserPreservesNormalizationFlagsAndWhitespaceRules() {
        XCTAssertNil(GitignoreLineParser.parse(""))
        XCTAssertNil(GitignoreLineParser.parse("  # comment"))
        XCTAssertEqual(
            GitignoreLineParser.parse("\\#literal"),
            GitignoreParsedLine(pattern: "#literal", isNegation: false, directoryOnly: false, absolute: false)
        )
        XCTAssertEqual(
            GitignoreLineParser.parse("!\\!allowed"),
            GitignoreParsedLine(pattern: "!allowed", isNegation: true, directoryOnly: false, absolute: false)
        )
        XCTAssertEqual(
            GitignoreLineParser.parse(" /foo//bar/  "),
            GitignoreParsedLine(pattern: "foo/bar", isNegation: false, directoryOnly: true, absolute: true)
        )
        XCTAssertEqual(GitignoreLineParser.parse("plain   ")?.pattern, "plain")
        XCTAssertEqual(GitignoreLineParser.parse("escaped\\ ")?.pattern, "escaped ")
        XCTAssertEqual(GitignoreLineParser.parse("even\\\\ ")?.pattern, "even\\\\")
        XCTAssertEqual(GitignoreLineParser.parse("prefix\0ignored")?.pattern, "prefix")
    }

    func testGitignoreLineParserUsesA1023ByteOutputBuffer() {
        let boundary = String(repeating: "a", count: 1023)
        XCTAssertEqual(GitignoreLineParser.parse(boundary)?.pattern, boundary)
        XCTAssertEqual(GitignoreLineParser.parse(boundary + "b")?.pattern, boundary)

        let slashAfterCapacity = boundary + "/"
        XCTAssertEqual(GitignoreLineParser.parse(slashAfterCapacity)?.pattern, boundary)
        XCTAssertEqual(GitignoreLineParser.parse(slashAfterCapacity)?.directoryOnly, false)
    }
}
