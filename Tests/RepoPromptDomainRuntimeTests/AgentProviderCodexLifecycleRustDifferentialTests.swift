import AgentryCoreBridge
import Foundation
import XCTest

/// ADR-0011 P6 leftover (B track) differential: leftover Codex bash / file-change
/// lifecycle synthesis. Named fixtures plus a SplitMix64 corpus. Reproduce with
/// `AGENTRY_P6_LIFECYCLE_DIFFERENTIAL_SEED`; widen with
/// `AGENTRY_P6_LIFECYCLE_DIFFERENTIAL_SCALE`.
final class AgentProviderCodexLifecycleRustDifferentialTests: XCTestCase {
    private let rust = CoreAgentProviderCodexLifecycle()
    private let oracle = P6LifecycleOracle.State()

    override func setUp() {
        super.setUp()
        try? rust.reset()
        oracle.reset()
    }

    // MARK: - Named fixtures

    func testNamedFileChangeStartDeltaComplete() throws {
        let startParams = #"{"item":{"id":"fc-1","type":"fileChange","status":"in_progress","changes":[{"path":"a.rs","diff":"+x","kind":"update"}]}}"#
        p6LifecycleAssertEventEqual(
            try rust.applyFileChange(method: "item/started", paramsJSON: startParams),
            oracle.applyFileChange(method: "item/started", paramsJSON: startParams)
        )
        XCTAssertEqual(try rust.applyFileChange(method: "item/started", paramsJSON: startParams)?.kind, "call")

        let deltaParams = #"{"itemId":"fc-1","delta":"chunk"}"#
        p6LifecycleAssertEventEqual(
            try rust.applyFileChange(method: "item/fileChange/outputDelta", paramsJSON: deltaParams),
            oracle.applyFileChange(method: "item/fileChange/outputDelta", paramsJSON: deltaParams)
        )

        let doneParams = #"{"item":{"id":"fc-1","type":"fileChange","status":"completed","changes":[{"path":"a.rs","diff":"+x","kind":"update"}]}}"#
        p6LifecycleAssertEventEqual(
            try rust.applyFileChange(method: "item/completed", paramsJSON: doneParams),
            oracle.applyFileChange(method: "item/completed", paramsJSON: doneParams)
        )
        p6LifecycleAssertCanonicalEqual(try rust.canonicalState(), oracle)
    }

    func testNamedLateDeltaSuppressedAfterComplete() throws {
        let startParams = #"{"item":{"id":"fc-term","type":"file_change","status":"running"}}"#
        _ = try rust.applyFileChange(method: "item/started", paramsJSON: startParams)
        _ = oracle.applyFileChange(method: "item/started", paramsJSON: startParams)
        let doneParams = #"{"item":{"id":"fc-term","type":"file_change","status":"completed"}}"#
        _ = try rust.applyFileChange(method: "item/completed", paramsJSON: doneParams)
        _ = oracle.applyFileChange(method: "item/completed", paramsJSON: doneParams)
        let late = #"{"itemId":"fc-term","delta":"late"}"#
        XCTAssertNil(try rust.applyFileChangeOutputDelta(paramsJSON: late))
        XCTAssertNil(oracle.applyOutputDelta(paramsJSON: late))
        p6LifecycleAssertCanonicalEqual(try rust.canonicalState(), oracle)
    }

    func testNamedRestartClearsTerminalMarker() throws {
        let item = #"{"item":{"id":"fc-restart","type":"fileChange","status":"completed"}}"#
        _ = try rust.applyFileChange(method: "item/started", paramsJSON: item)
        _ = oracle.applyFileChange(method: "item/started", paramsJSON: item)
        _ = try rust.applyFileChange(method: "item/completed", paramsJSON: item)
        _ = oracle.applyFileChange(method: "item/completed", paramsJSON: item)
        _ = try rust.applyFileChange(method: "item/started", paramsJSON: item)
        _ = oracle.applyFileChange(method: "item/started", paramsJSON: item)
        let delta = #"{"itemId":"fc-restart","delta":"again"}"#
        p6LifecycleAssertEventEqual(
            try rust.applyFileChangeOutputDelta(paramsJSON: delta),
            oracle.applyOutputDelta(paramsJSON: delta)
        )
        p6LifecycleAssertCanonicalEqual(try rust.canonicalState(), oracle)
    }

    func testNamedUniqueBashRunningUpdate() throws {
        let invocation = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        var oracleItems = [
            P6LifecycleOracle.BashItem(
                kind: "toolCall",
                toolName: "bash",
                invocationID: invocation,
                argsJSON: #"{"command":"ls"}"#,
                resultJSON: nil,
                toolIsError: nil
            ),
        ]
        let update = P6LifecycleOracle.RunningUpdate(
            invocationID: invocation,
            processID: "12",
            appendedOutput: "hello",
            sealsAssistantBoundary: false
        )
        let rustApply = try rust.applyCommandExecutionRunningUpdate(update.rustRecord, items: oracleItems.map(\.rustRecord))
        let oracleApplied = P6LifecycleOracle.applyRunningUpdate(update, to: &oracleItems)
        XCTAssertTrue(rustApply.applied)
        XCTAssertTrue(oracleApplied)
        p6LifecycleAssertItemsEqual(rustApply.items, oracleItems)
        XCTAssertEqual(rustApply.items[0].kind, "toolResult")
        XCTAssertTrue(P6LifecycleJSON.equal(rustApply.items[0].resultJson, oracleItems[0].resultJSON))
    }

    func testNamedSanitizeCSIAndBackspace() throws {
        XCTAssertEqual(try rust.sanitizeCommandOutput("ab\u{0008}c"), "ac")
        XCTAssertEqual(P6LifecycleSanitizer.sanitize("ab\u{0008}c"), "ac")
        XCTAssertEqual(try rust.sanitizeCommandOutput("\u{001B}[31mred\u{001B}[0m"), "red")
        XCTAssertEqual(P6LifecycleSanitizer.sanitize("\u{001B}[31mred\u{001B}[0m"), "red")
        XCTAssertEqual(
            try rust.sanitizeCommandOutput("ok\r\nline"),
            P6LifecycleSanitizer.sanitize("ok\r\nline")
        )
    }

    func testNamedStableInvocationUUIDAndHash() throws {
        let uuid = "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081"
        let hashed = "call_abc"
        let rustUUID = try rust.parseCommandExecutionRunningUpdate(
            method: "item/commandExecution/outputDelta",
            paramsJSON: #"{"itemId":"\#(uuid)","delta":"x"}"#
        )
        let oracleUUID = P6LifecycleOracle.parseRunningUpdate(
            method: "item/commandExecution/outputDelta",
            paramsJSON: #"{"itemId":"\#(uuid)","delta":"x"}"#
        )
        p6LifecycleAssertUpdateEqual(rustUUID, oracleUUID)
        XCTAssertEqual(rustUUID?.invocationId, uuid.uppercased())

        let rustHash = try rust.parseCommandExecutionRunningUpdate(
            method: "codex/event/exec_command_output_delta",
            paramsJSON: #"{"call_id":"\#(hashed)","delta":"x"}"#
        )
        let oracleHash = P6LifecycleOracle.parseRunningUpdate(
            method: "codex/event/exec_command_output_delta",
            paramsJSON: #"{"call_id":"\#(hashed)","delta":"x"}"#
        )
        p6LifecycleAssertUpdateEqual(rustHash, oracleHash)
        XCTAssertEqual(rustHash?.invocationId?.count, 36)
        XCTAssertEqual(rustHash?.invocationId.map { String($0[$0.index($0.startIndex, offsetBy: 14)]) }, "5")
    }

    func testNamedWithRunningStatusPatchesProcessAndOutput() throws {
        let raw = #"{"type":"commandExecution","status":"pending","exit_code":-1}"#
        let rustJSON = try rust.withCommandExecutionRunningStatus(
            resultJSON: raw,
            processId: "99",
            appendOutput: "out"
        )
        let oracleJSON = P6LifecycleOracle.withRunningStatus(raw: raw, processID: "99", appendOutput: "out")
        XCTAssertTrue(P6LifecycleJSON.equal(rustJSON, oracleJSON), "rust=\(rustJSON) oracle=\(oracleJSON)")
    }

    func testNamedIgnoreNonFileChangeLifecycle() throws {
        let params = #"{"item":{"id":"bash-1","type":"commandExecution"}}"#
        XCTAssertNil(try rust.applyFileChangeLifecycle(method: "item/started", paramsJSON: params))
        XCTAssertNil(oracle.applyLifecycle(method: "item/started", paramsJSON: params))
        XCTAssertNil(try rust.applyFileChangeLifecycle(method: "turn/started", paramsJSON: params))
        XCTAssertNil(oracle.applyLifecycle(method: "turn/started", paramsJSON: params))
    }

    // MARK: - Seeded corpus

    func testSeededFileChangeCorpusAgrees() throws {
        var rng = P6ASplitMix64(seed: P6LifecycleDifferentialConfiguration.seed)
        let scale = P6LifecycleDifferentialConfiguration.scale
        let ids = ["fc-a", "fc-b", "fc-c", "call_xyz", "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081"]
        let statuses = ["in_progress", "completed", "failed", "cancelled", ""]
        let deltas = ["chunk", " more", "\u{001B}[31mx\u{001B}[0m", "ab\u{0008}c", "   "]
        let methods = ["item/started", "item/completed", "item/fileChange/outputDelta", "turn/started"]
        try rust.reset()
        oracle.reset()
        for step in 0 ..< (64 * scale) {
            let method = methods[rng.below(methods.count)]
            let id = ids[rng.below(ids.count)]
            let status = statuses[rng.below(statuses.count)]
            let delta = deltas[rng.below(deltas.count)]
            let params: String
            if method.contains("output") {
                params = p6LifecycleEncode(["itemId": id, "delta": delta])
            } else {
                params = p6LifecycleEncode([
                    "item": [
                        "id": id,
                        "type": "fileChange",
                        "status": status,
                        "changes": [["path": "f\(step).rs", "diff": "+\(delta)", "kind": "update"]],
                    ] as [String: Any],
                ])
            }
            p6LifecycleAssertEventEqual(
                try rust.applyFileChange(method: method, paramsJSON: params),
                oracle.applyFileChange(method: method, paramsJSON: params)
            )
        }
        p6LifecycleAssertCanonicalEqual(try rust.canonicalState(), oracle)
    }

    func testSeededRunningUpdateCorpusAgrees() throws {
        var rng = P6ASplitMix64(seed: P6LifecycleDifferentialConfiguration.seed &+ 1)
        let scale = P6LifecycleDifferentialConfiguration.scale
        let toolNames = ["bash", "shell", "local_shell", "apply_patch", "read_file"]
        let kinds = ["toolCall", "toolResult"]
        for _ in 0 ..< (32 * scale) {
            var oracleItems: [P6LifecycleOracle.BashItem] = []
            let count = rng.below(3) + 1
            for index in 0 ..< count {
                let invocation: String? = rng.percent(70)
                    ? "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAA\(index)"
                    : (rng.percent(50) ? (stableInvocationID("call_\(index)") ?? "call_\(index)") : nil)
                oracleItems.append(
                    P6LifecycleOracle.BashItem(
                        kind: kinds[rng.below(kinds.count)],
                        toolName: toolNames[rng.below(toolNames.count)],
                        invocationID: invocation,
                        argsJSON: #"{"command":"ls \#(index)"}"#,
                        resultJSON: rng.percent(40)
                            ? #"{"type":"commandExecution","status":"running","processId":"\#(10 + index)"}"#
                            : (rng.percent(30) ? #"{"type":"commandExecution","status":"completed","exitCode":0}"# : nil),
                        toolIsError: rng.percent(10) ? true : nil
                    )
                )
            }
            let target = oracleItems[rng.below(oracleItems.count)]
            let update = P6LifecycleOracle.RunningUpdate(
                invocationID: rng.percent(60) ? target.invocationID : nil,
                processID: rng.percent(40) ? "1\(rng.below(3))" : nil,
                appendedOutput: rng.percent(80) ? ["hello", "\u{001B}[0m", "ab\u{0008}c", ""][rng.below(4)] : nil,
                sealsAssistantBoundary: false
            )
            let rustApply = try rust.applyCommandExecutionRunningUpdate(
                update.rustRecord,
                items: oracleItems.map(\.rustRecord)
            )
            var expected = oracleItems
            let applied = P6LifecycleOracle.applyRunningUpdate(update, to: &expected)
            XCTAssertEqual(rustApply.applied, applied)
            p6LifecycleAssertItemsEqual(rustApply.items, expected)
        }
    }

    func testSeededSanitizeAndParseAgree() throws {
        var rng = P6ASplitMix64(seed: P6LifecycleDifferentialConfiguration.seed &+ 2)
        let scale = P6LifecycleDifferentialConfiguration.scale
        let samples = [
            "", "plain", "ab\u{0008}c", "\u{001B}[31mred\u{001B}[0m", "ok\rnew", "a\r\nb",
            "\u{001B}]0;title\u{0007}x", "hello\u{0007}world",
        ]
        for _ in 0 ..< (16 * scale) {
            let sample = samples[rng.below(samples.count)]
            XCTAssertEqual(try rust.sanitizeCommandOutput(sample), P6LifecycleSanitizer.sanitize(sample), sample)
        }
        let methods = [
            "item/commandExecution/outputDelta",
            "codex/event/exec_command_output_delta",
            "session/update",
        ]
        for _ in 0 ..< (16 * scale) {
            let method = methods[rng.below(methods.count)]
            let id = rng.percent(50) ? "0193a4b2-7c3e-7f10-8a2b-9c4d5e6f7081" : "call_abc"
            let params = #"{"itemId":"\#(id)","processId":"7","delta":"out","stdin":""}"#
            p6LifecycleAssertUpdateEqual(
                try rust.parseCommandExecutionRunningUpdate(method: method, paramsJSON: params),
                P6LifecycleOracle.parseRunningUpdate(method: method, paramsJSON: params)
            )
        }
    }
}
