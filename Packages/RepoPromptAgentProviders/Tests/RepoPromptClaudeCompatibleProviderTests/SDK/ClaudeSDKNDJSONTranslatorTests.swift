import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeSDKNDJSONTranslatorTests: XCTestCase {
    func testAssistantToolAndResultSmokePreservesUsageArgsAndStableInvocationID() throws {
        var translator = ClaudeSDKNDJSONTranslator(
            treatsToolResultErrorsAsHostOwned: { $0 == "mcp__RepoPromptCE__read_file" }
        )
        let line = jsonLine([
            "type": "assistant",
            "message": [
                "usage": [
                    "input_tokens": 7,
                    "output_tokens": 3,
                    "cache_read_input_tokens": 5,
                    "cache_creation_input_tokens": 2
                ],
                "content": [
                    ["type": "text", "text": "Hello"],
                    [
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "mcp__RepoPromptCE__read_file",
                        "input": ["path": "Sources/App.swift"]
                    ]
                ]
            ]
        ])

        let results = translator.parseNDJSONLine(line)

        XCTAssertEqual(results.map(\.type), ["usage", "content", "tool_call"])
        guard results.count == 3 else { return }
        XCTAssertEqual(results[0].promptTokens, 7)
        XCTAssertEqual(results[0].completionTokens, 3)
        XCTAssertEqual(results[0].contextUsedTokens, 14)
        XCTAssertEqual(results[1].text, "Hello")
        XCTAssertEqual(results[2].toolName, "mcp__RepoPromptCE__read_file")
        let invocationID = try XCTUnwrap(results[2].toolInvocationID)
        XCTAssertEqual(try jsonObject(from: results[2].toolArgsJSON), ["path": "Sources/App.swift"])

        let resultLine = jsonLine([
            "type": "user",
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_1",
                    "content": [["type": "text", "text": "contents"]]
                ]]
            ]
        ])
        let toolResult = try XCTUnwrap(translator.parseNDJSONLine(resultLine).first)
        XCTAssertEqual(toolResult.type, "tool_result")
        XCTAssertEqual(toolResult.toolName, "mcp__RepoPromptCE__read_file")
        XCTAssertEqual(toolResult.toolOutput, "contents")
        XCTAssertEqual(toolResult.toolInvocationID, invocationID)
        XCTAssertNil(toolResult.toolIsError, "Host-owned tool result errors are tracked by the host completion handler, not inferred here.")
    }

    func testLifecycleAndStreamSmokeCoversSessionCancellationDeltaStopAndContextUsage() throws {
        var translator = ClaudeSDKNDJSONTranslator()

        let initResults = translator.parseNDJSONLine(jsonLine([
            "type": "system",
            "subtype": "init",
            "session_id": "claude-session-1"
        ]))
        XCTAssertEqual(initResults.map(\.type), [ClaudeProviderStreamResult.lifecycleType])
        XCTAssertEqual(translator.cliSessionID, "claude-session-1")

        let usage = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "message_start",
                "message": [
                    "usage": [
                        "inputTokens": 4,
                        "outputTokens": 0,
                        "cacheReadInputTokens": 6
                    ]
                ]
            ]
        ]))
        XCTAssertEqual(usage.first?.type, "usage")
        XCTAssertEqual(usage.first?.contextUsedTokens, 10)

        let delta = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "partial"]
            ]
        ]))
        XCTAssertEqual(delta.first?.type, "content")
        XCTAssertEqual(delta.first?.text, "partial")

        let stop = translator.parseNDJSONLine(jsonLine([
            "type": "stream_event",
            "event": [
                "type": "message_delta",
                "delta": ["stop_reason": "end_turn"],
                "usage": ["input_tokens": 4, "output_tokens": 9]
            ]
        ]))
        XCTAssertEqual(stop.map(\.type), ["usage", "message_stop"])
        XCTAssertEqual(stop.last?.stopReason, "end_turn")

        let cancelled = translator.parseNDJSONLine(jsonLine([
            "type": "result",
            "subtype": "error_during_execution",
            "session_id": "claude-session-2",
            "is_error": true,
            "errors": ["Request was aborted by user"],
            "stop_reason": "cancelled",
            "usage": ["input_tokens": 11, "output_tokens": 0],
            "total_cost_usd": 0.12
        ]))
        XCTAssertEqual(cancelled.map(\.type), ["message_stop"])
        let cancelledStop = try XCTUnwrap(cancelled.first)
        XCTAssertEqual(cancelledStop.providerSessionID, "claude-session-2")
        XCTAssertEqual(cancelledStop.promptTokens, 11)
        XCTAssertEqual(cancelledStop.completionTokens, 0)
        XCTAssertEqual(cancelledStop.cost, 0.12)
        XCTAssertEqual(cancelledStop.stopReason, "cancelled")
        XCTAssertEqual(translator.cliSessionID, "claude-session-2")
    }

    /// Two-arm pin for the Foundation `.prettyPrinted, .sortedKeys` byte format that
    /// `rust/crates/runtime/src/agent_claude/translator.rs`'s
    /// `foundation_pretty_printed_json_matches_a_captured_foundation_sample_byte_for_byte` test
    /// asserts against on the Rust side (captured live from this exact Foundation call). Without
    /// this, "the Rust port is byte-exact" rested on a one-sided check -- this closes the gap by
    /// running the SAME nested/sorted-keys/array value through the real
    /// `serializeJSONObjectString` call site (tool_use `input` -> `toolArgsJSON`) and comparing to
    /// the identical literal.
    func testToolArgsJSONMatchesTheFoundationPrettyPrintByteFormatCapturedOnTheRustSide() throws {
        var translator = ClaudeSDKNDJSONTranslator()
        let line = jsonLine([
            "type": "assistant",
            "message": [
                "content": [
                    [
                        "type": "tool_use",
                        "id": "toolu_pretty_print_pin",
                        "name": "some_tool",
                        "input": ["b": 2, "a": ["x": 1, "y": [1, 2, 3]], "c": "hello"]
                    ]
                ]
            ]
        ])

        let results = translator.parseNDJSONLine(line)
        let toolCall = try XCTUnwrap(results.first { $0.type == "tool_call" })

        let expected = "{\n  \"a\" : {\n    \"x\" : 1,\n    \"y\" : [\n      1,\n      2,\n      3\n    ]\n  },\n  \"b\" : 2,\n  \"c\" : \"hello\"\n}"
        XCTAssertEqual(toolCall.toolArgsJSON, expected)
    }

    private func jsonObject(from jsonString: String?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let value = try XCTUnwrap(jsonString, file: file, line: line)
        let data = Data(value.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String], file: file, line: line)
    }

    private func jsonLine(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            XCTFail("Invalid JSON fixture", file: file, line: line)
            return Data()
        }
        return data
    }
}
