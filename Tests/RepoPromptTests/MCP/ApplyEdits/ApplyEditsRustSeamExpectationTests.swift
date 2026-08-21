import Foundation
@testable import RepoPromptApp
import XCTest

/// P2 step 13: direct expectation tests against the production Rust seam
/// `RustApplyEditsComputer` (real `AgentryCoreBridge` runtime, no mocking).
///
/// This file replaces the former Swift-vs-Rust differential
/// (`ApplyEditsRustSwiftDifferentialTests`), which compared the legacy Swift
/// `ApplyEditsEngine` against `RustApplyEditsComputer`. That differential
/// passed as a hard assertion on all 16 fixtures (see
/// `docs/architecture/rust-apply-edits-compact-v1.md`, "Step 12 batch
/// differential" / "Step 13 apply-edits verdict: GO") immediately before the
/// legacy Swift engine was deleted; the expected values below were captured
/// verbatim from that passing run against the Rust engine, so this test
/// preserves the exact behavioral contract without needing the deleted
/// Swift reference implementation.
///
/// Six fixtures have documented allowed drift in diff-chunk *shape*
/// (`stats.chunks`, `diffChunks` count/line-type sequence) relative to what
/// the legacy Swift engine used to produce; that drift was certified
/// harmless because `updatedText`/`stats.linesChanged` matched exactly. This
/// test asserts the Rust engine's own (now-authoritative) chunk shape
/// directly rather than re-deriving the drift comparison.
final class ApplyEditsRustFixtureExpectationTests: XCTestCase {
    private struct Fixture {
        let name: String
        let path: String
        let originalText: String
        let mode: ApplyEditsMode
        let verbose: Bool
        let options: ApplyEditsExecutionOptions
    }

    private struct ExpectedOutcome {
        let index: Int
        let status: String
        let error: String?
    }

    private struct ExpectedChunk {
        let startLine: Int
        let types: [DiffLine.LineType]
    }

    private struct ExpectedSuccess {
        let updatedText: String
        let status: ApplyEditsStatus
        let editsRequested: Int
        let editsApplied: Int
        let note: String?
        let fileCreated: Bool
        let fileOverwritten: Bool
        let statsLinesChanged: Int?
        let statsChunks: Int?
        let outcomes: [ExpectedOutcome]?
        let chunks: [ExpectedChunk]
    }

    private enum Expected {
        case success(ExpectedSuccess)
        case invalidParams(String)
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            name: "rewrite_basic",
            path: "file.swift",
            originalText: "old content\n",
            mode: .rewrite(newText: "new content\n", onMissing: .error),
            verbose: true,
            options: .default
        ),
        Fixture(
            name: "single_basic",
            path: "file.swift",
            originalText: "foo baz\n",
            mode: .single(search: "foo", replace: "bar", replaceAll: false),
            verbose: true,
            options: .default
        ),
        Fixture(
            name: "single_escaped_search_fallback",
            path: "file.swift",
            originalText: "let value = \"old\"\n",
            mode: .single(search: #"let value = \"old\"\n"#, replace: #"let value = \"new\"\n"#, replaceAll: false),
            verbose: false,
            options: .default
        ),
        Fixture(
            name: "single_unmatched_throws",
            path: "file.swift",
            originalText: "present\n",
            mode: .single(search: "missing", replace: "replacement", replaceAll: false),
            verbose: false,
            options: .default
        ),
        Fixture(
            name: "single_ambiguous_throws",
            path: "file.swift",
            originalText: "same\nsame\n",
            mode: .single(search: "same", replace: "replacement", replaceAll: false),
            verbose: false,
            options: .default
        ),
        Fixture(
            name: "single_replace_all",
            path: "file.txt",
            originalText: "cat cat cat\n",
            mode: .single(search: "cat", replace: "dog", replaceAll: true),
            verbose: true,
            options: .default
        ),
        Fixture(
            name: "batch_literal_fastpath",
            path: "file.swift",
            originalText: "let value = old\n",
            mode: .batch([ApplyEditsOperation(search: "old", replace: "new", replaceAll: false)]),
            verbose: true,
            options: .default
        ),
        Fixture(
            name: "batch_unmatched_failed",
            path: "file.swift",
            originalText: "present\n",
            mode: .batch([ApplyEditsOperation(search: "missing", replace: "replacement", replaceAll: false)]),
            verbose: false,
            options: .default
        ),
        Fixture(
            name: "batch_diff_success",
            path: "file.swift",
            originalText: "same\nsame\n",
            mode: .batch([
                ApplyEditsOperation(search: "same", replace: "first", replaceAll: false),
                ApplyEditsOperation(search: "same", replace: "second", replaceAll: false)
            ]),
            verbose: true,
            options: .default
        ),
        Fixture(
            name: "batch_diff_partial_ambiguity",
            path: "file.swift",
            originalText: "same\nsame\ntail\n",
            mode: .batch([
                ApplyEditsOperation(search: "same", replace: "replacement", replaceAll: false),
                ApplyEditsOperation(search: "tail", replace: "done", replaceAll: false)
            ]),
            verbose: true,
            options: .default
        ),
        Fixture(
            name: "batch_replace_all_multi",
            path: "Animals.txt",
            originalText: "cat cat\nx\n",
            mode: .batch([
                ApplyEditsOperation(search: "cat", replace: "dog", replaceAll: true),
                ApplyEditsOperation(search: "x", replace: "y", replaceAll: false)
            ]),
            verbose: true,
            options: ApplyEditsExecutionOptions(includeToolCardUnifiedDiff: true)
        ),
        Fixture(
            name: "indentation_tabs_file_spaces_edit",
            path: "file.swift",
            originalText: "func f() {\n\tlet a = 1\n\tlet b = 2\n}\n",
            mode: .single(search: "\tlet a = 1", replace: "    let a = 10", replaceAll: false),
            verbose: true,
            options: .default
        ),
        Fixture(
            name: "crlf_line_endings",
            path: "file.txt",
            originalText: "line1\r\nline2\r\nline3\r\n",
            mode: .single(search: "line2", replace: "replaced", replaceAll: false),
            verbose: true,
            options: .default
        ),
        Fixture(
            name: "unicode_content",
            path: "file.swift",
            originalText: "// 你好，世界 🌍\nfunc greet() {}\n",
            mode: .single(search: "你好，世界", replace: "hello world", replaceAll: false),
            verbose: true,
            options: .default
        ),
        Fixture(
            name: "fuzzy_near_miss_missing_semicolon",
            path: "file.js",
            originalText: "function greet(name) {\n  console.log(name);\n}\n",
            mode: .single(
                search: "function greet(name) {\n  console.log(name)\n}\n",
                replace: "function greet(name) {\n  console.log('hi ' + name);\n}\n",
                replaceAll: false
            ),
            verbose: true,
            options: .default
        ),
        // Single-line near-miss (small in-line difference, no exact literal
        // match) to exercise the Rust engine's bi-gram Dice fuzzy probe path
        // -- the multi-line block above lands on "not found" without ever
        // reaching that probe.
        Fixture(
            name: "fuzzy_near_miss_single_line",
            path: "file.swift",
            originalText: "func total() -> Int {\n    let total = computeSum(values)\n    return total\n}\n",
            mode: .single(
                search: "    let total = computeSum(value)\n",
                replace: "    let total = computeSum(values) * 2\n",
                replaceAll: false
            ),
            verbose: true,
            options: .default
        )
    ]

    private static let expected: [String: Expected] = [
        "rewrite_basic": .success(ExpectedSuccess(
            updatedText: "new content\n",
            status: .success,
            editsRequested: 1,
            editsApplied: 1,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 1,
            statsChunks: 1,
            outcomes: nil,
            chunks: [ExpectedChunk(startLine: 0, types: [.removal, .addition])]
        )),
        "single_basic": .success(ExpectedSuccess(
            updatedText: "bar baz\n",
            status: .success,
            editsRequested: 1,
            editsApplied: 1,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 1,
            statsChunks: 1,
            outcomes: nil,
            chunks: [ExpectedChunk(startLine: 0, types: [.removal, .addition])]
        )),
        "single_escaped_search_fallback": .success(ExpectedSuccess(
            updatedText: "let value = \"new\"\n",
            status: .success,
            editsRequested: 1,
            editsApplied: 1,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 1,
            statsChunks: 1,
            outcomes: nil,
            chunks: [ExpectedChunk(startLine: 0, types: [.removal, .addition])]
        )),
        "single_unmatched_throws": .invalidParams("search block not found in file"),
        "single_ambiguous_throws": .invalidParams(
            "Search text matches multiple locations (lines 1, 2). Please make the search more specific or use replace_all=true."
        ),
        "single_replace_all": .success(ExpectedSuccess(
            updatedText: "dog dog dog\n",
            status: .success,
            editsRequested: 1,
            editsApplied: 1,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 1,
            statsChunks: 1,
            outcomes: nil,
            chunks: [ExpectedChunk(startLine: 0, types: [.removal, .addition])]
        )),
        "batch_literal_fastpath": .success(ExpectedSuccess(
            updatedText: "let value = new\n",
            status: .success,
            editsRequested: 1,
            editsApplied: 1,
            note: "Applied via exact literal replacement",
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 1,
            statsChunks: 1,
            outcomes: [ExpectedOutcome(index: 0, status: "success", error: nil)],
            chunks: [ExpectedChunk(startLine: 0, types: [.removal, .addition])]
        )),
        "batch_unmatched_failed": .success(ExpectedSuccess(
            updatedText: "present\n",
            status: .failed,
            editsRequested: 1,
            editsApplied: 0,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: nil,
            statsChunks: nil,
            outcomes: [ExpectedOutcome(
                index: 0,
                status: "failed",
                error: "search block not found in file (matches are exact, including whitespace/indentation)"
            )],
            chunks: []
        )),
        "batch_diff_success": .success(ExpectedSuccess(
            updatedText: "first\nsecond\n",
            status: .success,
            editsRequested: 2,
            editsApplied: 2,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 2,
            statsChunks: 1,
            outcomes: [
                ExpectedOutcome(index: 0, status: "success", error: nil),
                ExpectedOutcome(index: 1, status: "success", error: nil)
            ],
            chunks: [ExpectedChunk(startLine: 0, types: [.removal, .removal, .addition, .addition])]
        )),
        "batch_diff_partial_ambiguity": .success(ExpectedSuccess(
            updatedText: "same\nsame\ndone\n",
            status: .partial,
            editsRequested: 2,
            editsApplied: 1,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 1,
            statsChunks: 1,
            outcomes: [
                ExpectedOutcome(
                    index: 0,
                    status: "failed",
                    error: "Search block matches multiple locations (lines 1, 2). Please make the block more specific or use the replace_all parameter to replace all occurrences."
                ),
                ExpectedOutcome(index: 1, status: "success", error: nil)
            ],
            chunks: [ExpectedChunk(startLine: 2, types: [.removal, .addition])]
        )),
        "batch_replace_all_multi": .success(ExpectedSuccess(
            updatedText: "dog dog\ny\n",
            status: .success,
            editsRequested: 2,
            editsApplied: 2,
            note: "Applied via exact literal replacement",
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 2,
            statsChunks: 1,
            outcomes: [
                ExpectedOutcome(index: 0, status: "success", error: nil),
                ExpectedOutcome(index: 1, status: "success", error: nil)
            ],
            chunks: [ExpectedChunk(startLine: 0, types: [.removal, .removal, .addition, .addition])]
        )),
        "indentation_tabs_file_spaces_edit": .success(ExpectedSuccess(
            updatedText: "func f() {\n\tlet a = 10\n\tlet b = 2\n}\n",
            status: .success,
            editsRequested: 1,
            editsApplied: 1,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 1,
            statsChunks: 1,
            outcomes: nil,
            chunks: [ExpectedChunk(startLine: 1, types: [.removal, .addition])]
        )),
        "crlf_line_endings": .success(ExpectedSuccess(
            updatedText: "line1\r\nreplaced\r\nline3\r\n",
            status: .success,
            editsRequested: 1,
            editsApplied: 1,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 1,
            statsChunks: 1,
            outcomes: nil,
            chunks: [ExpectedChunk(startLine: 1, types: [.removal, .addition])]
        )),
        "unicode_content": .success(ExpectedSuccess(
            updatedText: "// hello world 🌍\nfunc greet() {}\n",
            status: .success,
            editsRequested: 1,
            editsApplied: 1,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 1,
            statsChunks: 1,
            outcomes: nil,
            chunks: [ExpectedChunk(startLine: 0, types: [.removal, .addition])]
        )),
        "fuzzy_near_miss_missing_semicolon": .invalidParams("search block not found in file"),
        "fuzzy_near_miss_single_line": .success(ExpectedSuccess(
            updatedText: "func total() -> Int {\n    let total = computeSum(values) * 2\n    return total\n}\n",
            status: .success,
            editsRequested: 1,
            editsApplied: 1,
            note: nil,
            fileCreated: false,
            fileOverwritten: false,
            statsLinesChanged: 1,
            statsChunks: 1,
            outcomes: nil,
            chunks: [ExpectedChunk(startLine: 1, types: [.removal, .addition])]
        ))
    ]

    func testAllApplyEditsFixturesMatchCapturedRustSeamExpectations() async {
        let rustComputer = RustApplyEditsComputer()
        var failures: [String] = []

        for fixture in Self.fixtures {
            guard let expectation = Self.expected[fixture.name] else {
                failures.append("\(fixture.name): missing expectation entry")
                continue
            }
            let request = ApplyEditsRequest(path: fixture.path, mode: fixture.mode, verbose: fixture.verbose)
            do {
                let result = try await rustComputer.apply(request: request, to: fixture.originalText, options: fixture.options)
                switch expectation {
                case let .success(expected):
                    Self.compare(fixture: fixture.name, result: result, expected: expected, into: &failures)
                case let .invalidParams(message):
                    failures.append("\(fixture.name): expected invalidParams(\(message.debugDescription)) but succeeded with \(result.updatedText.debugDescription)")
                }
            } catch {
                switch expectation {
                case .success:
                    failures.append("\(fixture.name): expected success but threw \(error)")
                case let .invalidParams(message):
                    guard let applyError = error as? ApplyEditsError else {
                        failures.append("\(fixture.name): threw a non-ApplyEditsError: \(error)")
                        continue
                    }
                    guard case let .invalidParams(actualMessage) = applyError else {
                        failures.append("\(fixture.name): expected invalidParams but threw \(applyError)")
                        continue
                    }
                    if actualMessage != message {
                        failures.append(
                            "\(fixture.name): invalidParams message: expected=\(message.debugDescription) actual=\(actualMessage.debugDescription)"
                        )
                    }
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Apply-edits Rust seam expectation mismatches (\(failures.count)):\n" + failures.joined(separator: "\n")
        )
    }

    private static func compare(
        fixture: String,
        result: ApplyEditsResult,
        expected: ExpectedSuccess,
        into failures: inout [String]
    ) {
        func mismatch(_ field: String, _ actual: String, _ expectedValue: String) {
            failures.append("\(fixture): \(field): expected=\(expectedValue) actual=\(actual)")
        }

        if result.updatedText != expected.updatedText {
            mismatch("updatedText", result.updatedText.debugDescription, expected.updatedText.debugDescription)
        }
        if result.status != expected.status {
            mismatch("status", "\(result.status)", "\(expected.status)")
        }
        if result.editsRequested != expected.editsRequested {
            mismatch("editsRequested", "\(result.editsRequested)", "\(expected.editsRequested)")
        }
        if result.editsApplied != expected.editsApplied {
            mismatch("editsApplied", "\(result.editsApplied)", "\(expected.editsApplied)")
        }
        if result.note != expected.note {
            mismatch("note", String(describing: result.note), String(describing: expected.note))
        }
        if result.fileCreated != expected.fileCreated {
            mismatch("fileCreated", "\(result.fileCreated)", "\(expected.fileCreated)")
        }
        if result.fileOverwritten != expected.fileOverwritten {
            mismatch("fileOverwritten", "\(result.fileOverwritten)", "\(expected.fileOverwritten)")
        }

        switch (result.stats, expected.statsLinesChanged, expected.statsChunks) {
        case (nil, nil, nil):
            break
        case let (.some(stats), .some(expectedLines), .some(expectedChunks)):
            if stats.linesChanged != expectedLines {
                mismatch("stats.linesChanged", "\(stats.linesChanged)", "\(expectedLines)")
            }
            if stats.chunks != expectedChunks {
                mismatch("stats.chunks", "\(stats.chunks)", "\(expectedChunks)")
            }
        default:
            failures.append("\(fixture): stats presence mismatch actual=\(String(describing: result.stats))")
        }

        switch (result.outcomes, expected.outcomes) {
        case (nil, nil):
            break
        case let (.some(actual), .some(expectedOutcomes)):
            if actual.count != expectedOutcomes.count {
                failures.append("\(fixture): outcomes count expected=\(expectedOutcomes.count) actual=\(actual.count)")
            } else {
                for (index, pair) in zip(actual, expectedOutcomes).enumerated() {
                    if pair.0.index != pair.1.index {
                        mismatch("outcomes[\(index)].index", "\(pair.0.index)", "\(pair.1.index)")
                    }
                    if pair.0.status != pair.1.status {
                        mismatch("outcomes[\(index)].status", pair.0.status, pair.1.status)
                    }
                    if pair.0.error != pair.1.error {
                        mismatch(
                            "outcomes[\(index)].error",
                            String(describing: pair.0.error),
                            String(describing: pair.1.error)
                        )
                    }
                }
            }
        default:
            failures.append("\(fixture): outcomes presence mismatch actual=\(String(describing: result.outcomes))")
        }

        if result.diffChunks.count != expected.chunks.count {
            failures.append("\(fixture): diffChunks.count expected=\(expected.chunks.count) actual=\(result.diffChunks.count)")
        } else {
            for (index, pair) in zip(result.diffChunks, expected.chunks).enumerated() {
                if pair.0.startLine != pair.1.startLine {
                    mismatch("diffChunks[\(index)].startLine", "\(pair.0.startLine)", "\(pair.1.startLine)")
                }
                let actualTypes = pair.0.lines.map(\.type)
                if actualTypes != pair.1.types {
                    failures.append(
                        "\(fixture): diffChunks[\(index)].lineTypeSequence expected=\(pair.1.types) actual=\(actualTypes)"
                    )
                }
            }
        }
    }
}
