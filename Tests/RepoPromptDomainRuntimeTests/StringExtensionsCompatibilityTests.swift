import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class StringExtensionsCompatibilityTests: XCTestCase {
    func testSimilarityUsesEffectiveCStringBytesAndByteLengthAlgorithmBoundary() {
        XCTAssertEqual("same\0left".similarityFast(to: "same\0right"), 1.0)
        XCTAssertEqual("café".similarityFast(to: "cafe"), 0.8, accuracy: 0.000_000_1)

        let sixtyFourBytes = String(repeating: "a", count: 31) + "b" + String(repeating: "a", count: 32)
        XCTAssertEqual(
            String(repeating: "a", count: 64).similarityFast(to: sixtyFourBytes),
            63.0 / 64.0,
            accuracy: 0.000_000_1
        )

        let sixtyFiveBytes = String(repeating: "a", count: 32) + "b" + String(repeating: "a", count: 32)
        XCTAssertEqual(
            String(repeating: "a", count: 65).similarityFast(to: sixtyFiveBytes),
            124.0 / 128.0,
            accuracy: 0.000_000_1
        )

        XCTAssertEqual("abcdef".similarityFast(to: "abqdef"), 5.0 / 6.0, accuracy: 0.000_000_1)
        XCTAssertEqual("abcdef".similarityFast(to: "abqxef"), 0.4, accuracy: 0.000_000_1)
    }

    func testLevenshteinUsesUTF8CodePointsAndPreservesCapSemantics() {
        XCTAssertEqual("".levenshteinDistance(to: ""), 0)
        XCTAssertEqual("🙂".levenshteinDistance(to: "🙃"), 1)
        XCTAssertEqual("café".levenshteinDistance(to: "cafe"), 1)
        XCTAssertEqual("cafe\u{301}".levenshteinDistance(to: "café"), 2)
        XCTAssertEqual("abc\0left".levenshteinDistance(to: "abc\0right"), 0)
        XCTAssertEqual("kitten".levenshteinDistance(to: "sitting", maxAllowedDistance: 2), 3)
        XCTAssertEqual("kitten".levenshteinDistance(to: "sitting", maxAllowedDistance: 3), 3)
        XCTAssertEqual("kitten".levenshteinDistance(to: "sitting", maxAllowedDistance: -2), 3)
        XCTAssertEqual("a".levenshteinDistance(to: "b", maxAllowedDistance: 0), 1)
        XCTAssertEqual("".levenshteinDistance(to: "abcdef", maxAllowedDistance: 2), 6)
        XCTAssertEqual("abcdef".levenshteinDistance(to: "", maxAllowedDistance: 2), 6)
        XCTAssertEqual("".levenshteinDistance(to: "a", maxAllowedDistance: 0), 1)
        XCTAssertEqual("".levenshteinDistance(to: "ab", maxAllowedDistance: 2), 2)
    }

    func testLongestCommonSubsequenceUsesUTF8CodePointsAndLeftColumnTieBreak() {
        XCTAssertEqual("ab".longestCommonSubsequence(with: "ba"), "b")
        XCTAssertEqual("A🙂B".longestCommonSubsequence(with: "X🙂Y"), "🙂")
        XCTAssertEqual("prefix\0left".longestCommonSubsequence(with: "prefix\0right"), "prefix")
        XCTAssertEqual("".longestCommonSubsequence(with: "anything"), "")
    }

    func testDiceUsesASCIIFoldedUTF8ByteBigramMultisets() {
        XCTAssertEqual("".diceCoefficient(against: ""), 0.0)
        XCTAssertEqual("A".diceCoefficient(against: "a"), 0.0)
        XCTAssertEqual("AB".diceCoefficient(against: "ab"), 1.0)
        XCTAssertEqual("Ä".diceCoefficient(against: "ä"), 0.0)
        XCTAssertEqual("aaaa".diceCoefficient(against: "aaa"), 0.8, accuracy: 0.000_000_1)
        XCTAssertEqual("ab\0left".diceCoefficient(against: "AB\0right"), 1.0)
    }

    func testBulkDiceKeepsFirstBestTieAndThresholdSemantics() {
        let tied = String.bulkDiceBestMatch(
            pattern: "TEST",
            candidates: ["test", "TeSt", "toast"],
            threshold: 1.0
        )
        XCTAssertEqual(tied?.index, 0)
        XCTAssertEqual(tied?.score ?? -1, 1.0)

        XCTAssertNil(String.bulkDiceBestMatch(pattern: "ab", candidates: ["ac"], threshold: 0.1))
        XCTAssertEqual(
            String.bulkDiceBestMatch(pattern: "ab\0x", candidates: ["AB\0y"], threshold: 1.0)?.index,
            0
        )

        let exactNonUnitThreshold = 2.0 / 3.0
        let nonUnitTie = String.bulkDiceBestMatch(
            pattern: "abcd",
            candidates: ["abce", "abcf"],
            threshold: exactNonUnitThreshold
        )
        XCTAssertEqual(nonUnitTie?.index, 0)
        XCTAssertEqual(nonUnitTie?.score ?? -1, exactNonUnitThreshold, accuracy: 0.000_000_1)
        XCTAssertNil(String.bulkDiceBestMatch(pattern: "a", candidates: ["x", "y"], threshold: 0.0))
    }

    func testSplitContentPreservesCLineAndDetectedEndingRules() {
        assertSplit("", lines: [], ending: "\n")
        assertSplit("abc", lines: ["abc"], ending: "\n")
        assertSplit("a\n", lines: ["a"], ending: "\n")
        assertSplit("\n", lines: [""], ending: "\n")
        assertSplit("a\nb\r\nc\r", lines: ["a", "b", "c"], ending: "\r")
        assertSplit("a\r\nb\r\nc\n", lines: ["a", "b", "c"], ending: "\r\n")
        assertSplit("a\nb\0ignored\rmore", lines: ["a", "b"], ending: "\n")
    }

    func testIndentationEncodingCountsOnlyASCIISpaceAndTabAndTrimsTrailingASCIIWhitespace() {
        XCTAssertEqual(String.encodeIndentationAsSpaces(" \t foo \t\n"), "<s6>foo")
        XCTAssertEqual(String.encodeIndentationAsSpaces(" \t"), "<s5>")
        XCTAssertEqual(String.encodeIndentationAsSpaces("\u{00A0}x\u{00A0}"), "<s0>\u{00A0}x\u{00A0}")
        XCTAssertEqual(String.encodeIndentationAsSpaces("  x\0ignored"), "<s2>x")
    }

    func testIndentationDecodingRequiresStrictBoundedNumericTag() {
        XCTAssertEqual(String.decodeIndentation("<s2>x"), "  x")
        XCTAssertEqual(String.decodeIndentation("<t2>x"), "\t\tx")
        XCTAssertEqual(String.decodeIndentation("<s0>"), "")

        for malformed in ["plain", "<s>x", "<q2>x", "<s-1>x", "<s+1>x", "<s1000001>x"] {
            XCTAssertEqual(String.decodeIndentation(malformed), malformed)
        }

        let million = String.decodeIndentation("<s1000000>x")
        XCTAssertEqual(million.utf8.count, 1_000_001)
        XCTAssertTrue(million.hasSuffix("x"))

        let nineteenDigitCount = "<s\(String(repeating: "0", count: 18))1>x"
        XCTAssertEqual(String.decodeIndentation(nineteenDigitCount), " x")
        let twentyDigitCount = "<s\(String(repeating: "0", count: 19))1>x"
        XCTAssertEqual(String.decodeIndentation(twentyDigitCount), twentyDigitCount)
        XCTAssertEqual(String.decodeIndentation("<s2>x\0ignored"), "  x")
    }

    func testTrimCommonLeadingWhitespacePreservesDetectedEndingButNotFinalTerminator() {
        XCTAssertEqual(String.trimCommonLeadingWhitespacePreservingLineEndings(""), "")
        XCTAssertEqual(
            String.trimCommonLeadingWhitespacePreservingLineEndings("\tfoo\r\n    bar\r\n\t\t\r\n"),
            "foo\r\nbar\r\n    "
        )
        XCTAssertEqual(
            String.trimCommonLeadingWhitespacePreservingLineEndings("    &lt;x&gt;\n    y"),
            "<x>\ny"
        )
        XCTAssertEqual(
            String.trimCommonLeadingWhitespacePreservingLineEndings("  a\n  b\r"),
            "a\rb"
        )
        XCTAssertEqual(String.trimCommonLeadingWhitespacePreservingLineEndings("  \t"), "      ")
        XCTAssertEqual(
            String.trimCommonLeadingWhitespacePreservingLineEndings("  a\n  b\0ignored"),
            "a\nb"
        )
    }

    func testEscapingAndUnescapingOperateOnEffectiveBytes() {
        let source = "\\\"\n\r\t🙂"
        XCTAssertEqual(source.escapedString(), "\\\\\\\"\\n\\r\\t🙂")
        XCTAssertEqual(source.escapedString().unescaped(), source)
        XCTAssertEqual("\\q".unescaped(), "\\q")
        XCTAssertEqual("tail\\".unescaped(), "tail\\")
        XCTAssertEqual("a\0ignored".escapedString(), "a")
        XCTAssertEqual("a\0ignored".unescaped(), "a")
    }

    func testHTMLDecodingUsesFixedCaseSensitiveSinglePassTable() {
        XCTAssertEqual(
            "&lt;&gt;&amp;&quot;&#39;&nbsp;&#160;".decodingHTMLEntities(),
            "<>&\"'  "
        )
        XCTAssertEqual("&amp;lt;".decodingHTMLEntities(), "&lt;")
        XCTAssertEqual("&LT;&unknown;".decodingHTMLEntities(), "&LT;&unknown;")
        XCTAssertEqual("&lt;\0&gt;".decodingHTMLEntities(), "<")
    }

    func testWhitespaceCondensingUsesASCIIWhitespaceAndNBSPOnly() {
        XCTAssertEqual(" \t\n\u{000B}\u{000C}\r x\u{00A0}\u{00A0}y ".condensingWhitespace(), " x y ")
        XCTAssertEqual("a\u{2003}\u{2003}b".condensingWhitespace(), "a\u{2003}\u{2003}b")
        XCTAssertEqual("a\0 ignored".condensingWhitespace(), "a")
    }

    func testFNV1aHashesEffectiveUTF8Bytes() {
        XCTAssertEqual("".fnv1a64(), 0xCBF2_9CE4_8422_2325)
        XCTAssertEqual("hello".fnv1a64(), 0xA430_D846_80AA_BD0B)
        XCTAssertEqual("é".fnv1a64(), 0x0AC2_1707_B718_1E01)
        XCTAssertEqual("hello\0ignored".fnv1a64(), "hello".fnv1a64())
    }

    func testFuzzySpacePreservesSpecialWhitespaceAndEmptyPatternRules() {
        XCTAssertFalse("".fuzzySpaceMatch(""))
        XCTAssertTrue("".fuzzySpaceMatch("", caseInsensitive: true))
        XCTAssertTrue(" ".fuzzySpaceMatch("\u{00A0}\u{2003}"))
        XCTAssertFalse("a b".fuzzySpaceMatch("a\u{00A0}b"))
        XCTAssertTrue("a\u{00A0}b".fuzzySpaceMatch("a \t\u{2003}b"))
        XCTAssertTrue("a\tb".fuzzySpaceMatch("a\tb"))
        XCTAssertFalse("a\tb".fuzzySpaceMatch("a b"))
        XCTAssertTrue("A B".fuzzySpaceMatch("a   b", caseInsensitive: true))
        XCTAssertFalse("Ä".fuzzySpaceMatch("ä", caseInsensitive: true))
        XCTAssertTrue("a ".fuzzySpaceMatch("a"))
        XCTAssertTrue("a".fuzzySpaceMatch("a\u{00A0}"))
        XCTAssertTrue("ignored\0".fuzzySpaceMatch("ignored\0suffix"))
    }

    func testCanonicalKeyPreservesPipelineOrderASCIIFoldingAnd150ByteRepair() {
        XCTAssertEqual(String.canonicalKey(" public FINAL class Foo__—--Bar => "), "foo-bar")
        XCTAssertEqual(String.canonicalKey("&LT;Ä&gt;"), "&lt;Ä>")
        XCTAssertEqual(String.canonicalKey("\u{00A0}public\tfoo\u{00A0}:"), "foo")
        XCTAssertEqual(String.canonicalKey("a─━═b"), "a-b")
        XCTAssertNil(String.canonicalKey(" \t\u{00A0}"))
        XCTAssertNil(String.canonicalKey(":"))
        XCTAssertEqual(String.canonicalKey("name\0ignored"), "name")

        let crossingScalar = String(repeating: "a", count: 149) + "🙂tail"
        XCTAssertEqual(String.canonicalKey(crossingScalar), String(repeating: "a", count: 149) + "�")
        XCTAssertEqual(String.canonicalKey(String(repeating: "b", count: 151))?.utf8.count, 150)
    }

    private func assertSplit(
        _ content: String,
        lines expectedLines: [String],
        ending expectedEnding: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let (lines, ending) = String.splitContentPreservingLineEndings(content)
        XCTAssertEqual(lines, expectedLines, file: file, line: line)
        XCTAssertEqual(ending, expectedEnding, file: file, line: line)
    }
}
