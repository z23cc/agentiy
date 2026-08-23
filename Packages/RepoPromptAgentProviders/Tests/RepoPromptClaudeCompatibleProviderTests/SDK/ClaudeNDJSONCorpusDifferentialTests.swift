import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

/// P6-3 (`docs/architecture/rust-agent-claude-v1.md` §2–§6, `docs/designs/p6-claude-vertical-2026-08-23.md`
/// §3.4/§11) — the **Swift arm** of the codec/translator corpus differential. The Rust arm
/// (`rust/crates/runtime/src/agent_claude/`) reads the identical corpus files under
/// `rust/crates/runtime/tests/fixtures/claude-ndjson/v1/synthetic/` and asserts the same expected
/// outcomes, hand-derived from this package's real (not paraphrased) behavior.
///
/// Scope note, stated rather than left implicit (mirrors design §3.4's own honesty about what a
/// corpus differential does and does not validate): this package is Foundation-only and does not
/// depend on the app target, so it can drive `ClaudeSDKProtocolCodec` and `ClaudeSDKNDJSONTranslator`
/// directly (design §11's literal reference-arm definition: "the Swift package translator, driven
/// line-by-line as the controller drives it today"), but it cannot reach the app-target-only D-1
/// recovery heuristics (`ClaudeNativeProcessSessionController`'s private `recover*IfNeeded` methods)
/// or `LineFramer`/`repairJSONStringControlCharacters` (`Sources/RepoPrompt/Infrastructure/Process/
/// ProcessStreamFraming.swift`) -- those are private to a different SwiftPM package/target entirely,
/// not merely `private`-restricted within reach of `@testable import`. For the D-1/D-2 corpus
/// fixtures below, this suite therefore asserts only the **primary decode outcome** (that
/// `ClaudeSDKProtocolCodec.decodeLine` throws `.invalidJSON` for the malformed lines, matching "the
/// same parse that already failed" precondition every recovery heuristic assumes); the recovery
/// heuristics themselves are ported byte-exactly into Rust and asserted there against the same
/// fixtures per the hand-verified `MANIFEST.json` `expectedBehavior` prose (independently checked
/// against `ClaudeNativeProcessSessionController.swift`'s actual source during P6-3's authoring).
final class ClaudeNDJSONCorpusDifferentialTests: XCTestCase {
    // MARK: - Corpus location

    /// Walks up from this source file to the repository root, then into the shared corpus
    /// directory the design's P6-3 slice names as the differential's fixture set.
    private static let corpusSyntheticDirectory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        // .../Packages/RepoPromptAgentProviders/Tests/RepoPromptClaudeCompatibleProviderTests/SDK/<this file>
        // 6 components below repo root: Packages, RepoPromptAgentProviders, Tests,
        // RepoPromptClaudeCompatibleProviderTests, SDK, <filename>.
        for _ in 0 ..< 6 {
            url.deleteLastPathComponent()
        }
        return url
            .appendingPathComponent("rust")
            .appendingPathComponent("crates")
            .appendingPathComponent("runtime")
            .appendingPathComponent("tests")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("claude-ndjson")
            .appendingPathComponent("v1")
            .appendingPathComponent("synthetic")
    }()

    private func corpusLines(
        _ fixtureName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [Data] {
        let url = Self.corpusSyntheticDirectory.appendingPathComponent(fixtureName)
        let data = try XCTUnwrap(try? Data(contentsOf: url), "missing corpus fixture \(fixtureName) at \(url.path)", file: file, line: line)
        // NDJSON: split on raw \n exactly as the framer's non-JSON-candidate / candidate-then-\n
        // paths ultimately hand a codec-ready line to the codec -- these fixtures contain no
        // embedded raw newlines inside JSON strings, so a plain split is faithful here.
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    // MARK: - D-1/D-2 fixtures: primary-decode-fails precondition only (see class doc)

    func testMalformedCorpusFixturesFailPrimaryDecodeWithInvalidJSON() throws {
        let malformedFixtures = [
            "d1-concatenated-split-positive.ndjson",
            "d1-concatenated-split-negative.ndjson",
            "d1-embedded-tail-positive.ndjson",
            "d1-embedded-tail-negative.ndjson",
            "non-utf8-bytes.ndjson"
        ]
        for fixture in malformedFixtures {
            let lines = try corpusLines(fixture)
            XCTAssertFalse(lines.isEmpty, fixture)
            for lineData in lines {
                XCTAssertThrowsError(try ClaudeSDKProtocolCodec.decodeLine(lineData), fixture) { error in
                    XCTAssertEqual(error as? ClaudeSDKProtocolCodec.CodecError, .invalidJSON, fixture)
                }
            }
        }
    }

    /// `d1-json-control-char-repair-embedded-lf.ndjson` is a **single logical line** once framed
    /// (the embedded raw `0x0A` sits inside a JSON string, so `LineFramer`'s quote-tracking keeps
    /// it as one line -- design §3.4/MANIFEST). This package-level test cannot exercise the
    /// framer, so it asserts against the framed line directly (the two raw bytes joined on the
    /// literal newline) and confirms the codec's *own* inline sanitize-and-retry (§2.1) succeeds
    /// without any controller-level recovery -- exactly as MANIFEST's `expectedBehavior` records.
    func testControlCharRepairFixtureCodecOwnSanitizeSucceedsWithoutControllerRecovery() throws {
        let rawLines = try corpusLines("d1-json-control-char-repair-embedded-lf.ndjson")
        XCTAssertEqual(rawLines.count, 2, "fixture is two raw \\n-delimited chunks that the framer reassembles into one logical line")
        var framedLine = rawLines[0]
        framedLine.append(0x0A)
        framedLine.append(rawLines[1])
        let inbound = try XCTUnwrap(try ClaudeSDKProtocolCodec.decodeLine(framedLine))
        guard case let .streamPayload(payload) = inbound else {
            return XCTFail("expected a stream payload")
        }
        XCTAssertEqual(payload["status"]?.stringValue, "line one\nline two")
    }

    // MARK: - Translator-body real-capture-shaped fixtures (design §3.4's "realCaptureOnly" gap)

    func testThinkingAndReasoningDeltaAreSilentlyDroppedWhenFeatureDisabled() throws {
        let lines = try corpusLines("realcapture-thinking-and-reasoning-dropped.ndjson")
        XCTAssertEqual(lines.count, 2)

        var translator = ClaudeSDKNDJSONTranslator()
        let assistantResults = translator.parseNDJSONLine(lines[0])
        XCTAssertEqual(assistantResults.map(\.type), ["content"], "thinking block must be dropped, not surfaced as reasoning or content")
        XCTAssertEqual(assistantResults.first?.text, "Here is the answer.")

        let deltaResults = translator.parseNDJSONLine(lines[1])
        XCTAssertTrue(deltaResults.isEmpty, "thinking_delta must be dropped, not forwarded, while the reasoning feature is disabled")
    }

    func testResultWithoutErrorsEmitsFinalContentThenMessageStop() throws {
        let lines = try corpusLines("realcapture-result-without-errors.ndjson")
        XCTAssertEqual(lines.count, 1)
        var translator = ClaudeSDKNDJSONTranslator()
        let results = translator.parseNDJSONLine(lines[0])
        XCTAssertEqual(results.map(\.type), ["final_content", "message_stop"])
        XCTAssertEqual(results[0].text, "All done.")
        let stop = results[1]
        XCTAssertEqual(stop.promptTokens, 120)
        XCTAssertEqual(stop.completionTokens, 45)
        XCTAssertEqual(stop.cost, 0.0421)
        XCTAssertEqual(stop.providerSessionID, "claude-session-realcapture-1")
        XCTAssertEqual(stop.stopReason, "end_turn")
        XCTAssertNil(stop.contextUsedTokens, "result.usage is an aggregate billed-turn total, not a live context snapshot (§2.3)")
    }

    func testResultWithGenuineErrorIsNotSuppressed() throws {
        let lines = try corpusLines("realcapture-result-with-genuine-error.ndjson")
        XCTAssertEqual(lines.count, 1)
        var translator = ClaudeSDKNDJSONTranslator()
        let results = translator.parseNDJSONLine(lines[0])
        XCTAssertEqual(results.map(\.type), ["error", "message_stop"])
        XCTAssertEqual(results[0].text, "Maximum turns exceeded for this task")
        XCTAssertEqual(results[1].providerSessionID, "claude-session-realcapture-2")
    }

    func testSessionStateChangedSequenceIncludingIdleEmitsLowercasedTrimmedText() throws {
        let lines = try corpusLines("realcapture-session-state-changed-idle-sequence.ndjson")
        XCTAssertEqual(lines.count, 3)
        var translator = ClaudeSDKNDJSONTranslator()
        let texts = try lines.map { line -> String in
            let results = translator.parseNDJSONLine(line)
            XCTAssertEqual(results.map(\.type), ["session_state_changed"])
            return try XCTUnwrap(results.first?.text)
        }
        // Line 2 has no session_state/sessionState key -- current_state is the first present
        // fallback key in the design's documented lookup order.
        XCTAssertEqual(texts, ["running", "compacting", "idle"])
    }

    func testCanUseToolControlRequestResponseRoundTripDecodesAtCodecLevel() throws {
        let lines = try corpusLines("realcapture-can-use-tool-round-trip.ndjson")
        XCTAssertEqual(lines.count, 2)

        guard case let .controlRequest(request) = try XCTUnwrap(try ClaudeSDKProtocolCodec.decodeLine(lines[0])) else {
            return XCTFail("expected a control_request")
        }
        XCTAssertEqual(request.requestID, "req-1")
        XCTAssertEqual(request.subtype, "can_use_tool")
        XCTAssertEqual(request.request["tool_name"]?.stringValue, "Bash")
        XCTAssertEqual(request.request["input"]?.objectValue?["command"]?.stringValue, "ls")

        guard case let .controlResponse(response) = try XCTUnwrap(try ClaudeSDKProtocolCodec.decodeLine(lines[1])) else {
            return XCTFail("expected a control_response")
        }
        XCTAssertEqual(response.requestID, "req-1")
        XCTAssertEqual(response.subtype, "success")
        XCTAssertEqual(response.response?["behavior"]?.stringValue, "allow")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.pendingPermissionRequests, [])
    }
}
