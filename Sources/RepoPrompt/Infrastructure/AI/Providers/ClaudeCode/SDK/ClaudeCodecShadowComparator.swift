#if DEBUG
    import AgentryCoreBridge
    import Foundation

    /// P6-5 (`docs/designs/p6-claude-vertical-2026-08-23.md` §11 P6-5, `docs/architecture/
    /// rust-agent-claude-v1.md` §3.4's "codec, on live bytes" rung, §14): the DEBUG-only live
    /// shadow arm. Feeds every raw inbound protocol line `ClaudeNativeProcessSessionController`
    /// observes to an independent Swift-arm translator AND to the Rust shadow arm
    /// (`ClaudeCodecDebugShadowSession`, `AgentryCoreBridge`), asserting event-stream equality.
    ///
    /// **Independence from the live controller, by construction.** This type never touches
    /// `ClaudeNativeProcessSessionController`'s private state (its own `translator`, turn-ID queue,
    /// etc.) -- it holds its own, freshly-constructed `ClaudeSDKNDJSONTranslator` and computes
    /// everything from the same raw bytes the controller itself observes, mirroring P4-5's
    /// `WorkspaceInventoryScopeShadowForwarder` pattern (an independent shadow computation from the
    /// same inputs, never a hook into the authority's internals).
    ///
    /// **Scope, matching the Rust arm's `debug_shadow.rs` doc exactly.** A line is only compared
    /// when BOTH arms' *primary* decode (plain JSON parse, no repair pass, no D-1 recovery
    /// heuristic) succeeds or both fail identically; lines that only decode via repair/recovery are
    /// out of the live shadow arm's scope by construction (already covered by the P6-3 corpus
    /// differential, the `claude-ndjson-v1` fuzz target, and P6-4's synthetic-CLI matrix -- design
    /// §3.4). A *disagreement* about primary-decode success itself (one arm's JSON library accepts
    /// bytes the other rejects) is reported as a `decodeDisagreement` mismatch -- that would be a
    /// genuine, live-traffic-only finding, not something this comparator silently absorbs.
    ///
    /// **Zero suspension points on the hot path.** `observe(_:)` is synchronous and non-throwing,
    /// matching P4-5's acceptance condition ("zero suspension points added to the hot path") -- safe
    /// to call inline from `handleLine`'s actor-isolated body.
    final class ClaudeCodecShadowComparator {
        struct Mismatch: CustomStringConvertible {
            enum Kind {
                case decodeDisagreement(swiftDecoded: Bool, rustKind: String)
                case rustBufferUnparseable(String)
                case countMismatch(swiftCount: Int, rustCount: Int)
                case fieldMismatch(index: Int, field: String, swiftValue: String, rustValue: String)
            }

            let lineIndex: Int
            let linePreview: String
            let kind: Kind

            var description: String {
                "line #\(lineIndex) [\(linePreview)]: \(kind)"
            }
        }

        private var swiftTranslator = ClaudeSDKNDJSONTranslator()
        private let rustSession = ClaudeCodecDebugShadowSession()

        private(set) var lineIndex = 0
        private(set) var comparedCount = 0
        private(set) var skippedCount = 0
        private(set) var mismatches: [Mismatch] = []

        /// Observes one raw inbound protocol line -- call at the very top of `handleLine`, before
        /// any decode attempt, so the comparator sees exactly the bytes production does.
        func observe(_ lineData: Data) {
            lineIndex += 1
            guard let trimmed = Self.trimmedASCIIWhitespace(lineData), !trimmed.isEmpty else { return }

            let swiftObject = (try? JSONSerialization.jsonObject(with: trimmed, options: [])) as? [String: Any]
            let swiftDecoded = swiftObject != nil

            let rustBuffer = rustSession.decodeLine(lineData)
            guard let rustOutcome = (try? JSONSerialization.jsonObject(with: rustBuffer)) as? [String: Any],
                  let rustKind = rustOutcome["kind"] as? String
            else {
                recordMismatch(.rustBufferUnparseable(String(data: rustBuffer, encoding: .utf8) ?? "<non-utf8>"), lineData: lineData)
                return
            }

            let rustDecoded = rustKind != "not_comparable"
            guard swiftDecoded == rustDecoded else {
                recordMismatch(.decodeDisagreement(swiftDecoded: swiftDecoded, rustKind: rustKind), lineData: lineData)
                return
            }
            guard swiftDecoded else {
                skippedCount += 1
                return
            }

            comparedCount += 1
            let swiftResults = swiftTranslator.parseNDJSONLine(lineData)
            let rustResults = (rustOutcome["results"] as? [[String: Any]]) ?? []
            guard swiftResults.count == rustResults.count else {
                recordMismatch(.countMismatch(swiftCount: swiftResults.count, rustCount: rustResults.count), lineData: lineData)
                return
            }
            for (index, pair) in zip(swiftResults, rustResults).enumerated() {
                compareOneResult(pair.0, pair.1, index: index, lineData: lineData)
            }
        }

        // MARK: - Field comparison

        /// Field coverage is exhaustive over `AIStreamResult`'s wire-shaped stored properties minus
        /// exactly two, both excluded for a stated structural reason rather than by omission:
        /// - `toolInvocationID` (Rust's `translator.rs` module doc: a synthetic `InvocationId(u64)`
        ///   can never structurally match Swift's `UUID`; tool correlation is checked by *relative*
        ///   identity within each arm instead, not cross-arm value equality).
        /// - `cleanupHandle` (a Swift-only runtime handle with no wire representation at all --
        ///   `debug_shadow_ffi.rs`'s `stream_result_to_json` has no corresponding key).
        ///
        /// Every other field -- including `cost` and `contentMessageID`, both actively populated by
        /// both arms' translators (`translator.rs`'s `total_cost_usd`/`content_message_id` handling,
        /// `ClaudeSDKNDJSONTranslator.swift`'s matching reads) -- is compared as a normalized string
        /// so numeric/bool/string mismatches all funnel through one code path. If `AIStreamResult`
        /// grows a new wire-shaped field, add it here explicitly; there is no reflection-based
        /// fallback, so an unlisted field is silently uncompared.
        private func compareOneResult(_ swift: AIStreamResult, _ rust: [String: Any], index: Int, lineData: Data) {
            func check(_ field: String, _ swiftValue: String?, _ rustKey: String) {
                let rustValue = (rust[rustKey] as? String)
                if swiftValue != rustValue {
                    recordMismatch(
                        .fieldMismatch(index: index, field: field, swiftValue: swiftValue ?? "<nil>", rustValue: rustValue ?? "<nil>"),
                        lineData: lineData
                    )
                }
            }
            func checkNumber(_ field: String, _ swiftValue: Int?, _ rustKey: String) {
                let rustValue = (rust[rustKey] as? NSNumber)?.intValue
                if swiftValue != rustValue {
                    recordMismatch(
                        .fieldMismatch(index: index, field: field, swiftValue: Self.describe(swiftValue), rustValue: Self.describe(rustValue)),
                        lineData: lineData
                    )
                }
            }
            func checkBool(_ field: String, _ swiftValue: Bool?, _ rustKey: String) {
                let rustValue = (rust[rustKey] as? Bool)
                if swiftValue != rustValue {
                    recordMismatch(
                        .fieldMismatch(index: index, field: field, swiftValue: Self.describe(swiftValue), rustValue: Self.describe(rustValue)),
                        lineData: lineData
                    )
                }
            }
            /// Both arms parse the same JSON number token for `total_cost_usd`, so exact bit equality
            /// is the correct comparison -- no tolerance window is introduced, matching this
            /// comparator's zero-tolerance stance on every other field.
            func checkDouble(_ field: String, _ swiftValue: Double?, _ rustKey: String) {
                let rustValue = (rust[rustKey] as? NSNumber)?.doubleValue
                if swiftValue != rustValue {
                    recordMismatch(
                        .fieldMismatch(index: index, field: field, swiftValue: Self.describe(swiftValue), rustValue: Self.describe(rustValue)),
                        lineData: lineData
                    )
                }
            }

            check("type/kind", swift.type, "kind")
            check("text", swift.text, "text")
            check("reasoning", swift.reasoning, "reasoning")
            checkNumber("promptTokens", swift.promptTokens, "promptTokens")
            checkNumber("completionTokens", swift.completionTokens, "completionTokens")
            checkDouble("cost", swift.cost, "cost")
            check("toolName", swift.toolName, "toolName")
            check("toolArgs", swift.toolArgs, "toolArgs")
            check("toolOutput", swift.toolOutput, "toolOutput")
            check("toolResultJSON", swift.toolResultJSON, "toolResultJSON")
            check("toolArgsJSON", swift.toolArgsJSON, "toolArgsJSON")
            checkBool("toolIsError", swift.toolIsError, "toolIsError")
            check("providerSessionID", swift.providerSessionID, "providerSessionID")
            check("stopReason", swift.stopReason, "stopReason")
            checkNumber("modelContextWindow", swift.modelContextWindow, "modelContextWindow")
            checkNumber("contextUsedTokens", swift.contextUsedTokens, "contextUsedTokens")
            check("contentMessageID", swift.contentMessageID, "contentMessageID")
        }

        /// Shared, non-generic-closure-context formatting for mismatch messages -- pulled out of
        /// `compareOneResult`'s local functions because inlining an equivalent `.map(String.init) ??
        /// "<nil>"` expression directly in each closure's call to `recordMismatch` overloaded the
        /// type-checker (`swift build` failed with "failed to produce diagnostic for expression" on
        /// the `checkDouble` closure specifically, once a fourth near-identical local function was
        /// added); a single concretely-typed helper keeps each closure's own expression simple.
        private static func describe(_ value: (some Any)?) -> String {
            guard let value else { return "<nil>" }
            return String(describing: value)
        }

        private func recordMismatch(_ kind: Mismatch.Kind, lineData: Data) {
            let preview = String(data: lineData.prefix(200), encoding: .utf8) ?? "<non-utf8>"
            mismatches.append(Mismatch(lineIndex: lineIndex, linePreview: preview, kind: kind))
        }

        private static func trimmedASCIIWhitespace(_ data: Data) -> Data? {
            let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20]
            guard var start = data.indices.first else { return data }
            var end = data.index(before: data.endIndex)
            guard !data.isEmpty else { return data }
            while start < data.endIndex, whitespace.contains(data[start]) {
                start = data.index(after: start)
            }
            guard start < data.endIndex else { return Data() }
            while end > start, whitespace.contains(data[end]) {
                end = data.index(before: end)
            }
            return data[start ... end]
        }
    }
#endif
