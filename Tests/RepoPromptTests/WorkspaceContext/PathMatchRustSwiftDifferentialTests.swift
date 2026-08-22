import AgentryCoreBridge
@testable import RepoPromptApp
import XCTest

/// Differential parity test for the P3-3 slice-1 workspace path-matching SCORING KERNEL Rust port:
/// every case below drives BOTH the real Swift kernel
/// (`PathMatcher.computeWeightedMatchScorePrecleaned` -- visibility relaxed from `private`
/// specifically for this harness, see that function's doc comment) and the real Rust seam
/// (`RustPathMatchScorer`, the real `AgentryCoreBridge` runtime, no mocking) with the same
/// fixture, then asserts EXACT equality between the two -- bit-identical `Double` via
/// `scoreBits`, plus the integer-scaled wire value as drift insurance. Hard assertions from day
/// one, no `XCTExpectFailure`.
///
/// Wire-shape note: the Rust kernel's returned score already folds in the
/// `fuzzyMatchWithSuffixLimit` selected-root `+0.5` bonus (see
/// `rust/crates/runtime/src/pathmatch/score.rs`'s module doc for why that's considered part of
/// "the scoring core" for this slice). `computeWeightedMatchScorePrecleaned` itself does NOT apply
/// that bonus -- its caller does -- so this test's "Swift expected score" is the raw kernel result
/// plus that bonus when the candidate's root ordinal is in `selectedRootOrdinals`.
///
/// Cleaning/casing scope note (see `score.rs`'s module doc for the full rationale): every string
/// sent to Rust is `PathMatcher.cleaned(_:).lowercased()` -- run through the REAL production
/// `cleaned()` function, then lowercased, exactly matching what `computeWeightedMatchScorePrecleaned`
/// produces internally for `caseSensitive: false` (the only value any call site ever passes).
final class PathMatchRustSwiftDifferentialTests: XCTestCase {
    // MARK: - Fixture shape

    private struct Candidate {
        let ordinal: UInt64
        let path: String // relativePath, e.g. "Sources/App.swift"; "" means zero components
        let rootOrdinal: UInt64

        init(_ ordinal: UInt64, _ path: String, rootOrdinal: UInt64 = 0) {
            self.ordinal = ordinal
            self.path = path
            self.rootOrdinal = rootOrdinal
        }
    }

    private func cleanedLower(_ s: String) -> String {
        PathMatcher.cleaned(s).lowercased()
    }

    /// Builds the wire component for `s`: `cleaned(s).lowercased()` as `text`, plus
    /// `cleaned(s).count` (Swift grapheme count, PRE-lowering) as `characterCount` and
    /// `cleaned(s).utf8.count` (PRE-lowering byte length) as `cleanedByteLength` -- exactly the
    /// contract `CorePathMatchComponentV1` documents.
    private func component(_ s: String) -> CorePathMatchComponentV1 {
        let cleanedValue = PathMatcher.cleaned(s)
        return CorePathMatchComponentV1(
            text: cleanedValue.lowercased(),
            characterCount: cleanedValue.count,
            cleanedByteLength: cleanedValue.utf8.count
        )
    }

    private func pathComponents(_ path: String) -> [String] {
        path.isEmpty ? [] : path.split(separator: "/").map(String.init)
    }

    /// Drives both sides for `query` against every `candidate` and asserts exact parity,
    /// including which candidates matched at all (Swift `nil` vs. absence from the Rust response).
    /// Returns the set of ordinals Swift matched, so callers can additionally assert a fixture
    /// produced at least one real match rather than trivially passing via both sides being empty.
    @discardableResult
    private func assertParity(
        query: [String],
        candidates: [Candidate],
        threshold: Double,
        selectedRootOrdinals: Set<UInt64> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Set<UInt64> {
        XCTAssertEqual(
            Set(candidates.map(\.ordinal)).count, candidates.count,
            "fixture bug: duplicate candidate ordinals", file: file, line: line
        )

        let userComponentsClean = query.map { PathMatcher.cleaned($0) }
        let queryWire = query.map(component)

        var expectedScores: [UInt64: Double] = [:]
        var wireCandidates: [CorePathMatchCandidateV1] = []

        for candidate in candidates {
            let components = pathComponents(candidate.path)
            let record = FrozenFileRecord(
                name: components.last ?? "",
                relativePath: candidate.path,
                fullPath: "/root/\(candidate.path)",
                rootFolderPath: "/root"
            )
            let raw = PathMatcher.computeWeightedMatchScorePrecleaned(
                item: .file(record),
                userComponentsClean: userComponentsClean,
                threshold: threshold
            )
            if let raw {
                let bonus = selectedRootOrdinals.contains(candidate.rootOrdinal) ? 0.5 : 0.0
                expectedScores[candidate.ordinal] = raw + bonus
            }

            let tailCount = min(components.count, queryWire.count)
            let tailRaw = tailCount == 0 ? [] : Array(components.suffix(tailCount))
            wireCandidates.append(CorePathMatchCandidateV1(
                ordinal: candidate.ordinal,
                rootOrdinal: candidate.rootOrdinal,
                totalComponentCount: components.count,
                tailComponents: tailRaw.map(component)
            ))
        }

        let rustResults = try await RustPathMatchScorer().score(
            query: queryWire,
            candidates: wireCandidates,
            threshold: threshold,
            selectedRootOrdinals: selectedRootOrdinals
        )

        var rustByOrdinal: [UInt64: CorePathMatchScoreV1] = [:]
        for result in rustResults {
            XCTAssertNil(rustByOrdinal[result.ordinal], "duplicate ordinal \(result.ordinal) in Rust response", file: file, line: line)
            rustByOrdinal[result.ordinal] = result
        }

        XCTAssertEqual(
            Set(expectedScores.keys), Set(rustByOrdinal.keys),
            "match-set mismatch between Swift and Rust", file: file, line: line
        )

        for candidate in candidates {
            guard let expectedScore = expectedScores[candidate.ordinal] else {
                XCTAssertNil(
                    rustByOrdinal[candidate.ordinal],
                    "ordinal \(candidate.ordinal) (\(candidate.path)) unexpectedly matched in Rust but not Swift",
                    file: file, line: line
                )
                continue
            }
            guard let rustEntry = rustByOrdinal[candidate.ordinal] else {
                XCTFail(
                    "ordinal \(candidate.ordinal) (\(candidate.path)) expected Swift score \(expectedScore) but Rust returned no match",
                    file: file, line: line
                )
                continue
            }
            XCTAssertEqual(
                rustEntry.scoreBits, expectedScore.bitPattern,
                "bit-identical score mismatch for ordinal \(candidate.ordinal) (\(candidate.path)): "
                    + "swift=\(expectedScore) rust=\(rustEntry.score)",
                file: file, line: line
            )
            XCTAssertEqual(
                rustEntry.scaledScore, Int64((expectedScore * 1_000_000).rounded()),
                "scaled score mismatch for ordinal \(candidate.ordinal) (\(candidate.path))",
                file: file, line: line
            )
        }

        return Set(expectedScores.keys)
    }

    // MARK: - Existing PathMatchingRecoveryTests fixture shapes

    func testMultiRootExactAndTypoCandidates() async throws {
        let matched = try await assertParity(
            query: ["App.swift"],
            candidates: [
                Candidate(1, "src/App.swift"),
                Candidate(2, "src/Apt.swift"), // 1-char substitution
                Candidate(3, "OnlyWeb.swift")
            ],
            threshold: 0.9
        )
        XCTAssertFalse(matched.isEmpty, "the exact candidate must match on both sides")
    }

    func testUnicodeStoredCandidatesAgainstAsciiQuery() async throws {
        try await assertParity(
            query: ["angstrom.swift"],
            candidates: [
                Candidate(1, "Sources/Ångström.swift"),
                Candidate(2, "Sources/文件.swift")
            ],
            threshold: 0.9
        )
    }

    // MARK: - ASCII typo / separator / depth variants

    func testAsciiTypoVariantsAcrossThresholds() async throws {
        for threshold in [0.85, 0.9, 0.95] {
            let matched = try await assertParity(
                query: ["src", "AppDelegate.swift"],
                candidates: [
                    Candidate(1, "src/AppDelegate.swift"), // exact
                    Candidate(2, "src/AppDelegat.swift"), // 1-char drop
                    Candidate(3, "src/AppDelegateX.swift"), // 1-char insert
                    Candidate(4, "srd/AppDelegate.swift"), // dir typo
                    Candidate(5, "a/b/c/src/AppDelegate.swift") // extra depth
                ],
                threshold: threshold
            )
            XCTAssertTrue(matched.contains(1), "the exact candidate must match at threshold \(threshold)")
        }
    }

    func testSeparatorFoldVariantsBothBranchesConsidered() async throws {
        // similarityScoreMax = max(stripSeparators: false, true) -- these pairs are constructed so
        // the two branches disagree and the fold branch must win for a match to occur.
        try await assertParity(
            query: ["foo-bar.swift"],
            candidates: [
                Candidate(1, "foobar.swift"), // matches only via the stripSeparators branch
                Candidate(2, "foo_bar.swift") // dash vs underscore, both folded away
            ],
            threshold: 0.95
        )
    }

    func testDepthPenaltyAcrossVaryingExtraComponents() async throws {
        try await assertParity(
            query: ["Model.swift"],
            candidates: (0 ... 5).map { extra in
                Candidate(UInt64(extra), (Array(repeating: "d", count: extra) + ["Model.swift"]).joined(separator: "/"))
            },
            threshold: 0.9
        )
    }

    // MARK: - Selected-root ties

    func testSelectedRootBonusBreaksATieBetweenIdenticalCandidates() async throws {
        let matched = try await assertParity(
            query: ["Shared.swift"],
            candidates: [
                Candidate(1, "Shared.swift", rootOrdinal: 10),
                Candidate(2, "Shared.swift", rootOrdinal: 20)
            ],
            threshold: 0.9,
            selectedRootOrdinals: [20]
        )
        XCTAssertEqual(matched, [1, 2], "both exact candidates must match, differing only by the selected-root bonus")
    }

    func testNoSelectedRootsMeansNoBonusAnywhere() async throws {
        try await assertParity(
            query: ["Shared.swift"],
            candidates: [
                Candidate(1, "Shared.swift", rootOrdinal: 10),
                Candidate(2, "Shared.swift", rootOrdinal: 20)
            ],
            threshold: 0.9,
            selectedRootOrdinals: []
        )
    }

    // MARK: - Composed/decomposed Unicode and non-ASCII case pairs

    func testComposedVersusDecomposedAccentedQuery() async throws {
        let decomposedE = "e\u{0301}" // combining acute accent
        let composedE = "\u{00E9}" // precomposed é
        try await assertParity(
            query: ["caf\(decomposedE).swift"],
            candidates: [
                Candidate(1, "caf\(composedE).swift"),
                Candidate(2, "cafe.swift")
            ],
            threshold: 0.9
        )
    }

    func testNonAsciiCasePairsTurkishAndSharpS() async throws {
        // Turkish dotted capital İ vs ASCII lowercase i; German sharp-s capital ẞ vs ß.
        try await assertParity(
            query: ["\u{0130}stanbul.swift"], // İstanbul.swift
            candidates: [
                Candidate(1, "istanbul.swift")
            ],
            threshold: 0.9
        )
        try await assertParity(
            query: ["stra\u{1E9E}e.swift"], // straẞe.swift
            candidates: [
                Candidate(1, "stra\u{00DF}e.swift") // straße.swift
            ],
            threshold: 0.9
        )
    }

    func testCombiningAcuteAccentPrecomposesAwayBeforeReachingTheGuard() async throws {
        // NOTE: this does NOT stress the grapheme-vs-scalar length-guard boundary -- NFC
        // precomposition (inside `cleaned()`) merges each "e" + COMBINING ACUTE ACCENT pair into a
        // single precomposed 'é' scalar BEFORE the alphanumeric filter runs, so by the time the
        // guard reads `.count`, scalar count == grapheme count here (4 of each). This is a basic
        // parity check for that precomposition step; see
        // `testDevanagariViramaClusterGraphemeVsScalarLengthGuardDivergence` below for a fixture
        // that DOES reach a real scalar-vs-grapheme divergence (combining marks with no canonical
        // precomposed form).
        let combiningQuery = (0 ..< 4).map { _ in "e\u{0301}" }.joined() + ".swift"
        try await assertParity(
            query: [combiningQuery],
            candidates: [
                Candidate(1, "eeee.swift"),
                Candidate(2, "eeeeeeeeee.swift"),
                Candidate(3, "eeeeeeeeeeeeee.swift")
            ],
            threshold: 0.7
        )
    }

    func testDevanagariViramaClusterGraphemeVsScalarLengthGuardDivergence() async throws {
        // A Devanagari virama cluster ("\u{0915}\u{094D}\u{0916}") survives `cleaned()`'s
        // alphanumeric filter as THREE separate scalars (the virama itself is category `Mn`, so
        // it's dropped from the ALLOWED set but the two consonant letters either side of it are
        // NOT dropped) yet Swift's ICU grapheme segmentation still counts the whole cluster as ONE
        // grapheme. A query/candidate pair built from repeated clusters therefore has a SMALL
        // grapheme-count difference but a LARGE scalar-count difference -- exactly the case
        // `score.rs`'s module doc (point 3) documents as the reason the length guard reads a
        // precomputed grapheme count rather than `text.chars().count()`. See
        // `guard_uses_precomputed_char_count_not_scalar_count` in `score.rs` for the isolated
        // Rust-only reproduction of the bug this wire field prevents.
        let cluster = "\u{0915}\u{094D}\u{0916}"
        let query = "test" + String(repeating: cluster, count: 5) + ".swift" // 5 graphemes, 15 scalars in the stem
        let candidate = "test" + String(repeating: cluster, count: 8) + ".swift" // 8 graphemes, 24 scalars in the stem

        let matched = try await assertParity(
            query: [query],
            candidates: [Candidate(1, candidate)],
            threshold: 0.5
        )
        XCTAssertEqual(
            matched, [1],
            "grapheme-count diff (3) must clear the length guard even though the scalar-count diff (9) would not"
        )
    }

    // MARK: - Homoglyph / fullwidth / zero-width inputs

    func testFullwidthDigitsAndLettersFoldToAscii() async throws {
        try await assertParity(
            query: ["\u{FF21}\u{FF22}\u{FF23}123.swift"], // fullwidth "ABC123.swift"
            candidates: [
                Candidate(1, "ABC123.swift"),
                Candidate(2, "abc123.swift")
            ],
            threshold: 0.9
        )
    }

    func testEmDashHomoglyphFoldsToAsciiHyphen() async throws {
        try await assertParity(
            query: ["foo\u{2014}bar.swift"], // em dash
            candidates: [
                Candidate(1, "foo-bar.swift"),
                Candidate(2, "foobar.swift")
            ],
            threshold: 0.9
        )
    }

    func testZeroWidthJoinerIsDroppedFromBothSides() async throws {
        try await assertParity(
            query: ["foo\u{200D}bar.swift"], // zero width joiner embedded
            candidates: [
                Candidate(1, "foobar.swift")
            ],
            threshold: 0.9
        )
    }

    // MARK: - >256-byte fallback (exact/case-insensitive equality only)

    func test255And256And257ByteBoundaryBothSides() async throws {
        func paddedComponent(byteCount: Int) -> String {
            // ".swift" is 6 ASCII bytes; pad the stem with 'a' so the FULL component is exactly
            // `byteCount` bytes.
            String(repeating: "a", count: byteCount - 6) + ".swift"
        }

        let at255 = paddedComponent(byteCount: 255)
        let at256 = paddedComponent(byteCount: 256)
        let at257 = paddedComponent(byteCount: 257)
        var at257OneCharDiff = at257
        at257OneCharDiff.removeLast(7)
        at257OneCharDiff += "b.swift"

        let matched255 = try await assertParity(
            query: [at255],
            candidates: [Candidate(1, at255)],
            threshold: 0.5
        )
        XCTAssertEqual(matched255, [1], "identical 255-byte components must match")

        let matched256 = try await assertParity(
            query: [at256],
            candidates: [Candidate(1, at256)],
            threshold: 0.5
        )
        XCTAssertEqual(matched256, [1], "identical 256-byte components must match")

        let matched257 = try await assertParity(
            query: [at257],
            candidates: [
                Candidate(1, at257), // identical >256-byte strings
                Candidate(2, at257OneCharDiff) // one-byte-different >256-byte strings
            ],
            threshold: 0.5
        )
        XCTAssertEqual(matched257, [1], "only the byte-identical >256-byte candidate may match")
    }

    // MARK: - Empty / edge cases

    func testEmptyQueryAgainstVaryingCandidateDepths() async throws {
        try await assertParity(
            query: [],
            candidates: [
                Candidate(1, ""),
                Candidate(2, "a.swift"),
                Candidate(3, "a/b/c.swift")
            ],
            threshold: 0.9
        )
    }

    func testCandidateShorterThanQueryIsImmediateNilOnBothSides() async throws {
        try await assertParity(
            query: ["src", "App.swift"],
            candidates: [
                Candidate(1, "App.swift"), // 1 component < query's 2
                Candidate(2, "") // 0 components
            ],
            threshold: 0.5
        )
    }

    func testFirstAlphanumericByteGuardRejectsOnBothSides() async throws {
        try await assertParity(
            query: ["zzz.swift"],
            candidates: [Candidate(1, "aaa.swift")],
            threshold: 0.5 // deliberately lax: the guard, not the threshold, must reject
        )
    }

    // MARK: - 256-byte gate: precomputed pre-lowering byte length, not the pooled (lowered) text's

    // own length

    func testByteGateUsesPreLoweringLengthAcrossTheLoweringByteGrowthBoundary() async throws {
        // İ (U+0130, 2 UTF-8 bytes) lowercases to "i" + COMBINING DOT ABOVE (3 UTF-8 bytes) --
        // lowering GROWS byte length. Swift's real 256-byte gate runs on the CLEANED-but-not-yet-
        // lowered string. Pick a repeat count where the CLEANED length sits at exactly 256 (Swift
        // takes the real Levenshtein DP path) while the LOWERED length exceeds 256 (an
        // implementation that gated on the lowered pooled text's own length would instead take the
        // exact-equality-only fallback). A prior version of this kernel did exactly that and
        // diverged from Swift on the one-diff case below (see `score.rs`'s
        // `gate_uses_precomputed_cleaned_byte_len_not_lowered_text_len` unit test for the isolated
        // reproduction).
        let dottedI = "\u{0130}"
        // 125 * 2 = 250 + 6 (".swift") = 256 cleaned bytes (<=256); 125 * 3 = 375 + 6 = 381
        // lowered bytes (>256).
        let repeated = String(repeating: dottedI, count: 125)
        let query = repeated + ".swift"

        let cleanedQuery = PathMatcher.cleaned(query)
        XCTAssertEqual(cleanedQuery.utf8.count, 256, "fixture precondition: cleaned length must be exactly 256")
        XCTAssertGreaterThan(
            cleanedQuery.lowercased().utf8.count, 256, "fixture precondition: lowered length must be >256"
        )

        // Swap the LAST İ for 'ı' (U+0131, LATIN SMALL LETTER DOTLESS I): also 2 cleaned UTF-8
        // bytes (keeps the candidate's CLEANED length <=256, same gate branch as the exact case)
        // but already-lowercase so it does NOT expand under `.lowercased()` the way İ does (keeps
        // the candidate's LOWERED length symmetric with the exact case too, still >256). An ASCII
        // replacement would instead trip the (unrelated) `firstAlnumLowercasedByte` guard before
        // the 256-byte gate is even reached, since the İ-only stem has no ASCII alnum byte ahead of
        // ".swift" -- masking the very thing this fixture exists to exercise.
        var candidateOneDiff = repeated
        candidateOneDiff.removeLast()
        candidateOneDiff += "\u{0131}" // ı
        candidateOneDiff += ".swift"

        let matched = try await assertParity(
            query: [query],
            candidates: [
                Candidate(1, query), // byte-identical candidate
                Candidate(2, candidateOneDiff) // single-scalar content difference near the tail
            ],
            threshold: 0.5
        )
        XCTAssertEqual(matched, [1, 2], "both the identical and near-identical candidates must match via the real DP path")
    }

    // MARK: - `exactMatchOnly` (0.9999) filename-position quirk -- confirmed as real production

    // behavior, not a Rust-only artifact (see `score.rs`'s Rust unit test of the same name).

    func testExactMatchOnlyThresholdRejectsEvenAByteIdenticalFilenameOnBothSides() async throws {
        try await assertParity(
            query: ["App.swift"],
            candidates: [
                Candidate(1, "App.swift"), // byte-identical candidate
                Candidate(2, "Apt.swift")
            ],
            threshold: 0.9999
        )
    }
}
