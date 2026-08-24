# Rust Agent Claude Vertical Contract v1

Status: **P6-1 contract freeze**, per `docs/designs/p6-claude-vertical-2026-08-23.md` (APPROVED). This document freezes behavior before any Rust implementation exists (P6-3+). It does not authorize product cutover by itself — cutover is P6-8, gated on the de-risking experiments (P6-2), the codec/process/stream/transcript differentials (P6-3…P6-7), and the full §15.3 gate list. Scope is the `claudeCode` provider kind only (`AgentProviderKind`); GLM/Kimi/custom-Claude-compatible are P6-9, and the headless one-shot Claude provider is out of this vertical entirely (design §1.3).

Every behavioral rule below is ported, not paraphrased, from the current Swift implementation. Anchors are cited so a future differential can be written directly against them. Where this document's line numbers drift from a later commit, the source file is authoritative; re-anchor rather than silently trusting this document.

## 1. Scope and ownership

The target production chain, once P6-8 lands, is `ClaudeAgentModeCoordinator.makeDefaultController` → `AgentryCoreBridge` → typed UniFFI → an `agentry-runtime` Claude agent scope. Rust owns process spawn/supervision, byte-to-event decode (framer + codec + translator), turn-lifecycle/terminal-event authority, interrupt fencing, and the permission *protocol* half. Swift retains transcript mutation, tool-card UI, run-state ownership, session persistence, permission *policy* (auto-approval matching, secure-store decisions), the MCP config lease, the expected-agent-PID fence, and the MCP-idle steering safe point.

| Layer | Owner (post-P6-8) | Note |
|---|---|---|
| CLI argv construction | Rust | §2.5 |
| Launch environment resolution (Keychain, sanitizer, carrier merge) | Swift | resolved map passed in |
| MCP config lease + `--mcp-config` path | Swift | host-owned lease; path passed in |
| `posix_spawn` + pgroup/sigmask/CLOEXEC/chdir | Rust | §5.1 |
| Reaping / SIGTERM→SIGKILL escalation | Rust, own children only | §5.2 |
| stdout read → frame → decode → translate | Rust, co-located (INV-P6-1) | §5.3, §2 |
| stderr tail retention | Rust | 256 KiB tail parity |
| Control-request correlation + timeouts | Rust | §2.2 |
| Turn lifecycle / result→idle authority / interrupt outcome | Rust | §3, §4 |
| Permission protocol (receive `can_use_tool`, write response line) | Rust | |
| Permission policy (auto-approval match, approval modeling, secure store) | Swift | `provider-plugins.md` ownership table |
| Expected-agent-PID registration | Swift, ordered after PID return | §5.1 |
| MCP-idle / tool-ack / child-wait safe point | Swift | §7.2 |
| Transcript mutation, tool cards, run state, session persistence | Swift | design §6, unchanged |
| `NativeAgentRuntimeControlling` conformance | Swift adapter | `ClaudeCompatibleNativeSessionAdapter.swift:10`; swap point is `ClaudeAgentModeCoordinator.makeDefaultController` (`ClaudeAgentModeCoordinator.swift:165-186`) |

### 1.1 Co-location invariant

> **INV-P6-1.** No production code path may cross the FFI per protocol line, per NDJSON payload, or per stream token. If the Rust codec is authoritative for a session, the process that produced those bytes is supervised by the same Rust scope, in the same crate, with no Swift hop between read and decode.

The only per-line export that may ever exist is `agent_claude_decode_line_debug_v1`, DEBUG-feature-gated, used solely by the P6-5 shadow arm. A release-build guardrail test (landed at P6-5) asserts that symbol's absence from the release binary. No production export accepts a single protocol line.

### 1.2 Topology: GUI-scope-only, verified by construction

The interactive Claude native runtime is a GUI-scope capability with exactly one implementation and one topology, enforced structurally rather than assumed: `ClaudeNativeProcessSessionController` is constructed only inside `ClaudeAgentModeCoordinator.makeDefaultController` (`ClaudeAgentModeCoordinator.swift:165-186`, invoked as the `claudeControllerFactory` default at `:157`); `ClaudeAgentModeCoordinator` is constructed only inside `AgentModeViewModel` (`:1735`, `:1951`), a `@MainActor` GUI view model; and `Sources/RepoPromptMCP` never constructs either symbol (`Scripts/source_layout_guardrails.sh` §11 enforces this reachability chain on every guardrail run — see that section's comment for the precise, narrower claim it makes, including the correction that `Sources/RepoPromptMCP` is *not* literally free of every "claude" substring, only of construction sites). Charter §15.3 gate 5 (topology parity) is therefore satisfied by this drift guard, not by a parallel headless cutover. The guard cannot yet assert anything about the post-cutover Rust agent scope, which does not exist at P6-1; extending it is a P6-8 obligation.

The headless Claude path (`ClaudeCodeAgentProvider`, one-shot `-p`, `HeadlessAgentProvider`) is a different implementation of a different capability and stays out of this vertical for its entire duration, including P6-9's variant-parity pass.

## 2. The `stream-json` wire subset actually consumed

Ported from `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeSDKProtocolCodec.swift` (208 lines) and `ClaudeSDKNDJSONTranslator.swift` (952 lines) — the Foundation-only package implementation the two core facades (`ClaudeSDKProtocolCodec.swift` 118 lines, `ClaudeSDKNDJSONTranslator.swift` 64 lines) delegate to.

### 2.1 Envelope layer (codec)

Every inbound NDJSON line is first trimmed of ASCII whitespace (empty ⇒ no message) and parsed as a JSON object. Two parse attempts are made: the raw bytes, then — only on failure — a JSON-string-control-character repair pass (`sanitizeJSONControlCharactersInStrings`, escapes any byte `< 0x20` found *inside* a JSON string value as `\u00XX`) followed by a second parse attempt. Both failing raises `CodecError.invalidJSON`; a well-formed object whose `type` fails a required-field check for its type raises `CodecError.unsupportedPayload`.

The envelope's top-level `type` field selects one of five `InboundMessage` cases:

| `type` | Required fields | Case |
|---|---|---|
| `control_request` | `request_id` (string), `request` (object, with `request.subtype` defaulting to `""` if absent) | `.controlRequest(requestID, request, subtype)` |
| `control_response` | `response` (object) containing `request_id` (string) and `subtype` (string); optional `response.response` (object), `response.error` (string), `response.pending_permission_requests` (array of objects) | `.controlResponse(requestID, subtype, response, error, pendingPermissionRequests)` |
| `control_cancel_request` | `request_id` (string) | `.controlCancelRequest(requestID)` |
| `keep_alive` | — | `.keepAlive` |
| anything else | — | `.streamPayload(object)` — the full decoded object, dispatched to the translator (§2.3) |

A `control_request`/`control_response` missing a required field is `.unsupportedPayload`, **not** silently dropped as a stream payload — the codec distinguishes "this is a control envelope with a malformed shape" from "this is not a control envelope at all."

Outbound encodings (Swift/Rust → CLI, one JSON object per line):

- `encodeUserMessage(text:sessionID:)` → `{"type":"user","message":{"role":"user","content":[{"type":"text","text":<text>}]},"parent_tool_use_id":null}`, plus `"session_id"` when a non-empty session ID is known.
- `encodeControlRequest(requestID:request:)` → `{"type":"control_request","request_id":<id>,"request":<request>}`.
- `encodeControlResponseSuccess(requestID:response:)` → `{"type":"control_response","response":{"subtype":"success","request_id":<id>[,"response":<response>]}}`.
- `encodeControlResponseError(requestID:error:)` → `{"type":"control_response","response":{"subtype":"error","request_id":<id>,"error":<error>}}`.

Every outbound line is written as one atomic `write(2)`: JSON body + a single trailing `0x0A`, never two separate writes (`ClaudeNativeProcessSessionController.swift:842-866` — "Two separate writes could theoretically be split if the pipe reader consumes data between them").

### 2.2 Control-request correlation and timeouts

`sendControlRequest(request:timeoutSeconds:)` (`:780-824`) registers a pending continuation **before** writing to stdin (closes a race where the CLI replies before the continuation exists), optionally arms a timeout `Task` that resolves `ControllerError.controlRequestTimedOut(requestID:)`, then writes the line. A write failure removes the continuation/timeout and resumes the caller with the write error rather than leaking a pending entry. `sendControlRequestWithoutResponse(request:)` is the fire-and-forget variant used for permission responses (`shutdownOnFailure: false` so a dead transport doesn't shut down the session before the caller can emit a failed-turn completion).

`sendLine(_:shutdownOnFailure:)` (`:842-866`) is the sole outbound write path (used by both `sendUserMessage` and control requests/responses); a write failure schedules `shutdown()` unless the caller opted out.

### 2.3 Inbound message-type catalog (translator)

`parseMessageDictionary` dispatches on the decoded object's `type` field to one of thirteen shapes. Every branch first extracts `session_id`/`sessionId` if present and records it as `cliSessionID`.

| `type` | Handler | Emits |
|---|---|---|
| `system` | `parseSystemMessage` | subtype-dependent, see below |
| `assistant`, `message` | `parseAssistantMessage` | `usage`, `content`/`reasoning`/`tool_call`/`tool_result` (one result per content block) |
| `user` | `parseUserMessage` | `tool_result` (one per `content` block whose `type == "tool_result"`; non-tool-result blocks are ignored) |
| `stream_event` | `parseStreamEvent` | subtype-dependent, see below |
| `tool_use` (top-level) | `parseTopLevelToolUse` | one `tool_call` |
| `tool_result` (top-level) | `parseTopLevelToolResult` | one `tool_result` |
| `result` | `parseResultMessage` | optional `error`, optional `final_content`, always one `message_stop` (§3's turn-boundary signal) |
| `tool_progress` | `parseToolProgressMessage` | zero or one `tool_progress` |
| `auth_status` | `parseAuthStatusMessage` | one `auth_status` |
| `tool_use_summary` | `parseToolUseSummaryMessage` | zero or one `system` |
| `rate_limit_event` | `parseRateLimitEventMessage` | zero or one `system` (suppressed entirely when `rate_limit_info.status == "allowed"`) |
| `error` | inline | one `error`, only if `error`/`message` is non-empty |
| anything else | — | `[]` (silently ignored) |

**`system` subtypes** (`parseSystemMessage`), matched case-insensitively:

- `init` → one lifecycle result, `ClaudeProviderStreamResult.lifecycleType` text `"initialized"`; also records `cliSessionID` from `session_id`/`sessionId` if present. This is the `runtime.init` signal used to publish `latestRuntimeInitTools`/`latestRuntimeInitMcpServerStatuses` (`ClaudeNativeProcessSessionController.swift:1284-1287` via `parseSystemInitFields`, matched independently of the translator on the raw payload).
- `status` → `"status"` result; `"compacting"` (case-insensitive) is rewritten to `"Compacting context"`; any other non-empty, non-`"null"` status is passed through verbatim.
- `task_started` → `"system"` result, `"Task started"` joined with optional `task_id`/`description` fragments via `" — "`.
- `task_notification` → `"system"` result, `"Task update"` joined with optional `task_id`/`status`/`summary`.
- `compact_boundary` → `"system"` result, `"Context compacted"` joined with optional `trigger`/`pre_tokens` (only if `> 0`) from `compact_metadata`.
- `session_state_changed` → `"session_state_changed"` result, text = the lowercased, trimmed value of the first present key among `session_state`, `sessionState`, `state`, `current_state`, `currentState`. **This is a turn boundary, not a progress ping** — see §3, §7.1's "trap" row.
- `task_progress` → `"task_progress"` result, joined `message`/`text`/`summary`/`description`/`status` fragments, falling back to `"Task <task_id>"` if none are present. Run-state preview only, not a transcript row.
- anything else with a non-empty `message` field → `"system"` result carrying it verbatim; otherwise `[]`.

**`stream_event` sub-events** (`parseStreamEvent`, keyed on `event.type`):

- `content_block_delta` with `delta.type == "text_delta"` → `"content"` result (non-empty `delta.text` only).
- `content_block_delta` with `delta.type == "thinking_delta"` → `"reasoning"` result carrying `delta.thinking`, **gated on `ClaudeReasoningExtractionFeature.isEnabled`** (a feature flag; disabled ⇒ silently dropped, not emitted as `content`).
- `message_start` → `"usage"` result if `message.usage` parses (§2.4); otherwise `[]`.
- `message_delta` → up to two results: a `"usage"` result if `event.usage` parses, and a `"message_stop"` result (carrying `stopReason`) if `delta.stop_reason`/`delta.stopReason` is non-empty. **This `message_stop` is a forwarded stream event, not the authoritative turn boundary** — see §3.
- `message_stop` → one `"message_stop"` result with no fields. Also not a turn boundary on its own.
- anything else → `[]`.

**`assistant`/`message` content blocks** (`payload["content"]` array, or a plain-string/array-of-strings fallback via `extractString` when `content` is not an array — the fallback still preceded by the `usage` result if present):

- `text` → `"content"` result (non-empty `text` only).
- `thinking` → `"reasoning"` result carrying `block["thinking"]`, gated on `ClaudeReasoningExtractionFeature.isEnabled` exactly as the streamed delta form.
- `tool_use` → `"tool_call"` result; `name` defaults to `"tool"`; the tool-use ID (first present of `tool_use_id`/`toolUseId`/`toolUseID`/`id`) is recorded in a `toolNameByToolUseID` map keyed for later `tool_result` name resolution; `input` is serialized to a pretty-printed, sorted-key JSON string (`nil` if empty or not JSON-serializable) and carried as both `toolArgs` and `toolArgsJSON`; a stable per-tool-use `invocationID` (`UUID`, generated once and cached) is attached.
- `tool_result` → `"tool_result"` result; tool name resolves via `resolveToolName` (prefer explicit `name`, fall back to the cached name from the matching `tool_use`, fall back to `"tool"`); `isError` resolves via `inferToolResultError` (§2.5); output resolves via `serializeToolResultContent` (§2.6); the same cached `invocationID` is reused.
- any other block type → ignored.

**`user` message content blocks**: identical `tool_result` handling to the assistant-message branch, but *only* blocks whose `type == "tool_result"` are considered — everything else in the array is silently skipped (this is where Claude echoes tool results back through the user-role channel in some transports).

**`result` message** (`parseResultMessage`) — the authoritative turn-boundary payload, ported behaviorally in §3:

- `usage` parses via §2.4.
- `is_error` (bool, `is_error`/`isError`), `subtype` (lowercased/trimmed), and `errors` (array of strings or `{message|error}` objects, plus a fallback single `error`/`message` field) feed `extractResultErrorMessages`. An error result is emitted (`type: "error"`, text = first error message) **unless** `shouldSuppressResultErrorEmission` (§2.7) determines every collected error is an interrupt/cancel artifact.
- `result` (string) → `"final_content"` result if non-empty.
- Always exactly one `"message_stop"` result carrying `promptTokens`/`completionTokens` (from usage), `cost` (`total_cost_usd`), `providerSessionID` (the observed `cliSessionID`), `stopReason`, and `modelContextWindow` (§2.4). **`contextUsedTokens` is intentionally `nil` on this result** — the result's `usage` is an aggregate billed-turn total, not a live context snapshot; live context snapshots come only from stream `usage` events (`message_start`/`message_delta`).

### 2.4 Usage and context-window parsing

`parseUsage(_:)` reads `input_tokens`/`inputTokens`, `output_tokens`/`outputTokens`, `cache_read_input_tokens`/`cacheReadInputTokens`, `cache_creation_input_tokens`/`cacheCreationInputTokens` (each via `numberToInt`, tolerant of `Int`, `Double`, `NSNumber`, or numeric `String`). Returns `nil` if none of the four are present. `inputTokens`/`outputTokens` are clamped to `≥ 0`. `contextUsedTokens` is the saturating (never-overflow, `Int.max`-clamped) sum of clamped `input + cacheRead + cacheCreation`, computed only when at least one of `input`/`cacheRead`/`cacheCreation` was present (i.e. not derivable from `output` alone).

`parseModelContextWindow(_:)` scans `modelUsage`'s values for the first positive `contextWindow` field.

### 2.5 CLI argv (`buildArguments`, `ClaudeNativeProcessSessionController.swift:1971-2009`)

Base flags, always present: `-p --verbose --output-format stream-json --input-format stream-json --permission-prompt-tool stdio`. Conditionally appended, in this order:

1. `--append-system-prompt <glmZAIAppendSystemPrompt>` when `config.runtimeVariant == .glm` — carried but inert for `claudeCode`. The literal value (`"Running within this desktop app."`) is chosen to avoid the trigger words `Claude`/`Anthropic`/`agent`/`SDK` so it cannot itself re-trigger the z.ai shedding behavior it works around (issue #295).
2. `--resume <existingSessionID>` when resuming a session (non-empty ID). RepoPrompt instructions are delivered in provider-bound user messages on both fresh starts and resumes — no `-p <prompt>` flag is ever used.
3. `--allow-dangerously-skip-permissions` when `config.permissionMode` case-insensitively equals `"bypassPermissions"`.
4. `--mcp-config <configURL.path>` (plus `--strict-mcp-config` if `config.mcpStrictMode`) when a config lease is active.
5. `--disallowedTools <comma-joined list>` when `config.disallowedBuiltInTools` is non-empty.

Prompt text is never a CLI argument. The CLI is spawned once per session (not once per turn); `-p` here selects the SDK's programmatic/print protocol mode, not a one-shot prompt.

### 2.6 Tool-result content serialization (`serializeToolResultContent`)

`nil` → `""`. A plain string → itself, unchanged. An array of `{type, text}` blocks → the text of every block whose (lowercased) `type` is `"text"` or `"output_text"`, trimmed, filtered non-empty, joined by `"\n"` (falls through to the generic path if that yields nothing). Any other valid JSON object/array → pretty-printed, sorted-key JSON string. Anything else → `String(describing:)`.

### 2.7 Tool-result error inference (`inferToolResultError`)

If `treatsToolResultErrorsAsHostOwned(toolName)` (§8) is true, returns `nil` immediately — RepoPrompt's own MCP tool status is tracked by the host's completion handler, not inferred here. Otherwise: explicit `is_error`/`isError` boolean wins outright; failing that, `inferToolResultErrorSignal` recurses through the tool-result payload and (if still `nil`) the raw result payload, checking in order per object: explicit `is_error`/`isError`; a `status`/`result`/`outcome`/`state`/`subtype` string classified by `inferStatusError` (`ok`/`success`/`succeeded`/`complete`/`completed` ⇒ `false`; `error`/`failed`/`failure`/`rejected`/`denied`/`cancelled`/`canceled` ⇒ `true`; anything else ⇒ `nil`, keep looking); an `exitCode`/`exit_code`/`code` field (`0` ⇒ `false`, `> 0` ⇒ `true`); a non-empty `error`/`error_message`/`errorMessage` string ⇒ `true`; a non-empty `errors` array ⇒ `true`; `success`/`ok == true` ⇒ `false`; then recurse into nested keys `tool_result`/`toolResult`/`result`/`output`/`response`/`content`/`payload`/`data`/`value`/`tool_use_result`/`toolUseResult`; finally, a non-empty `content` array with no other signal ⇒ `false` (presence of content blocks is itself a weak success signal). Arrays recurse element-wise: any `true` short-circuits to `true`; otherwise `false` if any element resolved, else `nil`. JSON-shaped strings are parsed and recursed into.

### 2.8 Interrupt/cancel/error suppression (`shouldSuppressResultErrorEmission`, §2.3's `result` handling)

An error result is suppressed only when **every** collected error message, lowercased, either contains one of the tokens `interrupt`/`cancel`/`aborted`/`"request was aborted"` (`isInterruptedTurnSignal`) or matches `ClaudeAbortArtifactFilter.shouldSuppressUserFacingError`. A single non-artifact error among several defeats suppression. This is D-1/D-2's suppression rule (§9).

## 3. Turn lifecycle / terminal-event authority

Ported from `ClaudeNativeProcessSessionController.swift:1269-1489`. This section is the single most behaviorally delicate part of the vertical (design R4) and must be ported as a state machine, not paraphrased.

```text
Idle ──send_user_message──▶ TurnInFlight{turn_id, seq}
TurnInFlight ──payload.type=="result" && translated=="message_stop"──▶
    if observed_session_state_changed:  ResultObserved{status}   (turn NOT dequeued; turnInFlight stays true)
    else:                               Completed{status}        (legacy immediate path)
ResultObserved ──session_state_changed(text=="idle")──▶ Completed{status}
ResultObserved ──fallback_timer(1.0s, generation-tokened)──▶ Completed{status}  + `lifecycle.idleFallback`
any ──stdout EOF──▶ flush deferred with original status; remaining turn IDs ⇒ Failed + one `.error`
any ──shutdown──▶ flush deferred with original status (never rewritten to Failed)
```

Rules, each anchored:

- A turn completes **only** when the *original envelope's* `type == "result"` and the translated stream result is `"message_stop"` (`:1269-1382`, `isResultPayload = payloadType == "result"`, checked alongside `result.type == "message_stop"`). Forwarded `message_delta`/`message_stop` stream events also translate to `"message_stop"` results but do **not** carry `isResultPayload == true`, so they are emitted to the event stream but never dequeue a turn ID or complete anything.
- Once `session_state_changed` has been observed at least once in the session (`observedSessionStateChangedEvents`, set the first time any `session_state_changed` result is produced), turn completion **defers**: the determined status is appended to `pendingAuthoritativeTurnStatuses` and the turn ID is deliberately **not** dequeued yet — `turnInFlight` (== `hasPendingTurnIDs`) stays `true` across the whole result→idle window. Before this first observation, completion is immediate on `result`/`message_stop` ("legacy mode").
- `sessionStateChanged(idle)` — a `session_state_changed` result whose text, lowercased, equals exactly `"idle"` — releases the head of `pendingAuthoritativeTurnStatuses` via `completeNextDeferredTurnIfPending`: cancels/clears the fallback task, dequeues one turn ID, emits `.turnCompleted(turnID:status:)`, then reschedules a fallback for any remaining deferred entries.
- A generation-tokened fallback timer (`authoritativeTurnIdleFallbackSeconds`, default **1.0 s**) fires if `idle` never arrives: only ever one live fallback task at a time (armed for the head of the deferred queue), each carrying a monotonically incrementing generation so a stale firing after cancellation/rescheduling is ignored (`authoritativeIdleFallbackGeneration`). On fire: dequeue one turn ID, emit `.turnCompleted`, write a `lifecycle.idleFallback` raw-event record, reschedule for the next deferred entry if any remain.
- `turnWasInterrupted` (set by a successful `interruptTurn` ACK, §4) short-circuits `determineTurnStatus` to `.cancelled` and is consumed (reset to `false`) on that read — so exactly one subsequent result determination sees it, matching "the very next result after an ACKed interrupt is a cancellation side effect, not a real failure."
- The cancelled-signal token set, checked case-insensitively/trimmed against `subtype`, `stop_reason`, the translator's `stopReasonHint`, a nested `event.delta.stop_reason`, and every collected result error string: `interrupt`, `cancel`, `aborted`, `"request was aborted"` (substring match, not exact). Any hit ⇒ `.cancelled`.
- Otherwise: `is_error == true`, or `subtype` containing `"error"`, or a non-empty `errors[]` ⇒ `.failed`. Everything else ⇒ `.completed`.
- **Shutdown/EOF flush** (`cancelAuthoritativeLifecycleState`, called from both `shutdown()` and `handleStdoutEOF()`): cancels the fallback task, then drains `pendingAuthoritativeTurnStatuses` in order, dequeuing and emitting `.turnCompleted` **with each entry's already-determined status — never rewritten to `.failed`**, because the result that established the status was already observed; only the `idle` confirmation was missing.
- **EOF beyond the deferred queue**: after the flush above, any turn IDs still in the queue that were never in `pendingAuthoritativeTurnStatuses` at all (no `result` ever seen for them) are drained via `drainAllTurnIDs()` and each emitted as `.turnCompleted(status: .failed)`, preceded by exactly one `.error("Claude process exited unexpectedly.")` if the drained set is non-empty.
- Three `assertionFailure` sites guard invariant violations that should be structurally unreachable: a `result`/`message_stop` with no pending turn ID (`:1372`), a deferred-idle completion with no pending turn ID (`:1401`), and an idle-fallback firing with no pending turn ID (`:1439`). Per design D-4, the Rust port replaces each with a counted diagnostic plus a lossless `protocolDrift` event — a panic in this authority is worse than a logged inconsistency (charter §14.1).

**The `sessionStateChanged(idle)` classification trap** (design §5.2): it looks like a routine progress ping and is in fact the turn-boundary release signal. Any implementation that classifies it as coalescible/droppable progress silently loses turn completions under load. It must be `lossless` in the event catalog (§7.1) precisely because it is terminal-event authority, not status preview.

## 4. Interrupt: one fenced command, five outcomes

Today `interruptTurn(reason:)` (`:460-490`) is atomic with the actor and the coordinator's `hasTurnInFlight` pre-check (`ClaudeAgentModeCoordinator.swift:1091`) is a cheap same-actor read. Once the controller moves behind an FFI, that pre-check becomes a stale read and a TOCTOU the current design does not have. The redesign removes the pre-check rather than making it remote.

```text
agent_interrupt_turn(identity, scope_id, turn_generation: u64, reason: String)
    -> InterruptReceiptV1 { request_id }
```

- `turn_generation` is a fencing token: monotonic per session, returned by `send_user_message` and carried on every turn event. An interrupt naming a superseded generation must never be applied to the wrong turn.
- Rust owns the interrupt-ACK deadline: **1.5 s** (`:462`, `sendControlRequest(request: ["subtype": "interrupt", "reason": reason], timeoutSeconds: 1.5)`), because `turnWasInterrupted` (§3) must be set consistently with the outcome. Swift keeps an outer deadline as belt-and-braces only.
- The outcome arrives as an `interruptOutcome` terminal-class event (§7.1) correlated by `request_id`; no async FFI method.

| Outcome | Meaning | Payload | Coordinator treatment |
|---|---|---|---|
| `acknowledged` | Claude ACKed the interrupt for the named generation | — | Proceed with the superseding turn. Today's `.acknowledged` path, unchanged (`:469-473`). |
| `noTurnInFlight` | The named generation **is** current, and nothing is running under it | `current_generation` (equal to the named one) | Proceed. Today's `guard turnInFlight else { return .noTurnInFlight }` (`:461`), unchanged in meaning. |
| `staleGeneration` *(new)* | The named generation is superseded; `current_generation` is authoritative and a turn may be live under it | `current_generation`, `current_turn_in_flight: Bool` | **Do not proceed blindly.** Re-sync to `current_generation`; if `current_turn_in_flight`, re-issue the interrupt against it **once** (bounded single retry, never a loop); map a second `staleGeneration` result to `failed`. If `!current_turn_in_flight`, proceed. |
| `timedOut` | No ACK within 1.5 s | `current_generation` | Re-check in-flight state and proceed only if the turn already ended. Today's `.controlRequestTimedOut` path (`:475-480`), unchanged. |
| `failed` | Transport dead, process gone, or write error | `current_generation` | As `timedOut`. Today's catch-all failure path (`:481-488`), unchanged. |

`current_generation` rides **every** outcome (not only `staleGeneration`) — one extra `u64`, lets the bridge resynchronize without a second round trip. The bounded single retry on `staleGeneration` is deliberate: an unbounded retry loop against a session producing back-to-back turns would livelock; the second-attempt-to-`failed` mapping routes that case into the existing race-tolerant `timedOut`/`failed` branch rather than inventing a new one.

Today's raw-event records at this boundary — `turn.interrupted`, `turn.interrupt.timedOut`, `turn.interrupt.failed` — are preserved 1:1 by kind (§8); `staleGeneration`'s retry gets its own record kind, additive.

## 5. Process supervision contract

### 5.1 Spawn: mirror `posix_spawnp`; `tokio::process` rejected

Ported line-for-line from `ProcessLauncher.swift` (336 lines). Every attribute is load-bearing:

- **Pipes**: three pipes (stdin/stdout/stderr), each end `FD_CLOEXEC` via `POSIXDescriptorSupport.setCloseOnExec`, plus `POSIX_SPAWN_CLOEXEC_DEFAULT` (Darwin-specific spawn flag; no `std::process` equivalent) so any *other* open FD in the parent is closed-on-exec by default in the child.
- **File actions**: `dup2` stdin-read→`STDIN_FILENO`, stdout-write→`STDOUT_FILENO`, stderr-write→`STDERR_FILENO`; explicit `close` of the parent-retained write/read ends inside the child; `posix_spawn_file_actions_addchdir_np` for the working directory (Darwin-only; a no-op branch exists for non-Darwin but this vertical is arm64-only per the charter, so that branch is dead in practice).
- **Signal defaults**: `posix_spawnattr_setsigdefault` restores default `SIGPIPE` disposition in the child (the parent's write path is `configureNoSigPipe`-hardened; the child must see normal pipe semantics) — flag `POSIX_SPAWN_SETSIGDEF`.
- **Signal mask**: `posix_spawnattr_setsigmask` sets an **empty** mask — `posix_spawn` otherwise inherits the calling thread's mask, and an inherited blocked `SIGCHLD` can strand a child's async waiter after its shell has exited — flag `POSIX_SPAWN_SETSIGMASK`.
- **Process group**: `posix_spawnattr_setpgroup(&attributes, 0)` places the child in its own new process group — flag `POSIX_SPAWN_SETPGROUP`. Cancellation/timeout cleanup signals the whole group so reparented same-PGID descendants cannot survive a cleanup.
- **argv/envp**: `strdup`'d C strings, `nil`-terminated, `free`'d after spawn (`defer`).
- **Return**: `SpawnedProcess { pid, processGroupID: pid, stdin, stdout, stderr }` — `pid` doubles as `processGroupID` because the child is the group leader of its own new group.

`tokio::process` is rejected for four independent reasons (charter §11.4 says so directly; it reaps via a global SIGCHLD handler, colliding with §5.2's sole-`waitpid`-owner discipline; `POSIX_SPAWN_CLOEXEC_DEFAULT` has no `std::process` equivalent and `pre_exec` reintroduces async-signal-safety hazards `posix_spawn` avoids; and the needed dependency surface — `process`+`signal`(+`net` for `AsyncFd`) tokio features — is unnecessary once §5.2/§5.3 are designed around plain threads and a shared kqueue).

The spawn command Rust receives carries: resolved absolute command path, argv, the **already-resolved** environment map (Swift keeps resolving Keychain/sanitizer/carrier merge per charter §11.2), working directory. Rust returns `pid` + `pgid` synchronously so §5.4's host-coupling ordering holds. **The environment map is never logged, never enters the observability ring buffer, and never appears in a raw-event record** — matching today's `process.spawned` record, which carries `command`/`arguments`/`workingDirectory` and deliberately **not** `environment` (`ClaudeNativeProcessSessionController.swift:605-612`; design R8).

### 5.2 Reaping: mirror the whole `ChildStatusReaperRegistry` architecture, not just PID targeting

Ported from `ProcessTermination.swift`'s `ChildStatusReaperRegistry` (`:58-232`). PID-targeted `waitpid` alone is only half the discipline; the other, equally load-bearing half is **zero dedicated threads per child** (`:58-61`, verbatim: *"A process source scales with the number of live children without occupying one worker thread per child, while the serial queue preserves exactly one destructive `waitpid` owner for each PID."*). The Rust reaper mirrors both halves:

| Property | Swift `ChildStatusReaperRegistry` | Rust agent reaper |
|---|---|---|
| Exit notification | `DispatchSourceProcess` (kqueue `EVFILT_PROC`/`NOTE_EXIT`) per PID, one shared serial queue (`:126-139`) | one process-wide kqueue fd; one `EVFILT_PROC`/`NOTE_EXIT` registration per PID |
| Dedicated threads | zero per child; one shared `userInitiated` `DispatchQueue` | zero per child; one process-wide reaper thread, `userInitiated` QoS |
| Missed-kevent self-heal | per-PID `DispatchSourceTimer`, **0.5 s** interval, 100 ms leeway — "kevent exit delivery is not contractual under load" (`:99-105`) | `EVFILT_TIMER` on the same kqueue, same 0.5 s interval, same rationale |
| Registration-boundary coverage | three probe points: registration handler (`source.setRegistrationHandler`, `:141`), the repeating fallback timer (`:149`), and a direct post-`activate()` probe (`:161-164`) | same three probe points |
| Non-destructive probe | `waitid(P_PID, id_t(pid), &info, WEXITED\|WNOHANG\|WNOWAIT)` first (never consumes the status); destructive `waitpid(pid, &status, mode.waitOptions)` second (`:174-200`) | identical two-step; `WNOWAIT` on the probe keeps the status waitable so a probe never consumes it |
| Sole-owner guard | PID→`Entry` map (`entries: [pid_t: Entry]`) + per-registration `UUID` token, checked before every reap/complete (`:111`, `:125`, `:175`, `:213`) | PID→entry map + per-registration token, identical check discipline |
| ECHILD | `ProcessTerminationError.childOwnershipLost(pid:)`, surfaced through the completion callback (`:44-51`) | typed `ChildOwnershipLost`, surfaced as a diagnostic event |
| Escalation | SIGTERM to the process group → grace (default 2.0 s) → SIGKILL to the group; "root exited but group survives" handled explicitly (`terminateAndReapStatus`, `:339-450` and `:480-487`) | identical two-stage escalation, own children only |
| `shutdown` idempotency | guarded, reaps before declaring closed (`:520-608` `shutdown()`) | Rust scope's `shutdown` command is idempotent, reaps before returning closed |

**Never `waitpid(-1)`, never `WAIT_MYPGRP`. No SIGCHLD handler is installed anywhere in the process.** The two reap-ownership sets (Swift's registry, Rust's reaper) are disjoint by PID; neither can steal from the other because each PID is registered with exactly one owner.

**Orphan backstop**: if a scope is dropped without `shutdown` (the Rust analogue of the Swift controller's `deinit`, `:254-278`), a process-wide orphan registry signals the group and hands the PID to the **shared reaper** above -- never to a new dedicated thread, which would reintroduce the per-child cost this section removes. This is a backstop per charter §6.1 rule 7, never the product lifecycle.

**Reclamation policy for orphan-backstop registrations (P6-4, closing a gap the P6-2 spike found).** Contract text through P6-2 said the orphan PID is "handed to the shared reaper" but did not say who reclaims its map entry once reaped -- and by definition nothing does on the orphan-backstop path, since there is no waiter left. The P6-2 soak measured the consequence concretely: 40 of 400 `ScopeDropWithoutWait` cycles left a permanently-resident entry (P6-2 results doc §5, finding 3). **Decision, landed at P6-4: provenance-typed registration, not a time-based grace period.** The reaper exposes two registration entry points distinguished by what happens to a completed entry: `register(pid) -> token` (**owned** -- reclaimed only by the caller's own explicit `forget(pid, token)`, unchanged from today) and `register_orphan(pid)` (**orphan** -- issues **no token**, so no caller can ever construct a valid `wait_for_exit`/`forget` call for it; the reaper reclaims the map entry itself, immediately, the instant the reap resolves). A time-based grace period was considered and rejected: `wait_for_exit` returns `Option`, so a reclaimed-but-never-queried entry is indistinguishable from "still running" to a caller that raced the grace window, and an escalation path (`terminate_and_reap`) reading that as `None` would `killpg` a PID the OS may already have recycled. Provenance typing removes the ambiguity at the type level: an orphan entry's map residency is exactly `[registered, reaped]`, never longer -- verified by a 200-cycle soak asserting zero residual entries at `rust/crates/runtime/src/agent_claude/process/reaper.rs`'s own tests, and recorded in `rust/benchmarks/results/v1/p6-4-process-supervisor-v1.md` §2. **Post-landing correction:** the shape above was under-specified on first landing -- the real `ScopeDropWithoutWait` PID is already registered **owned** at spawn time (not never-registered), so a backstop that re-registered it fresh via `register_orphan` collided (`AlreadyRegistered`) and silently no-op'd, leaving the owned entry resident forever. `Reaper::reassign_as_orphan(pid, token)` converts an existing owned slot to orphan provenance **in place**, confirmed by the scope's own still-valid token, and is what `terminate_and_orphan` (the actual `ScopeDropWithoutWait` entry point) uses; `register_orphan`/`terminate_orphan_backstop` remain for a PID genuinely never registered with this reaper. `reassign_as_orphan` returns whether the child was already reaped at the moment of the call, and `terminate_and_orphan` skips signaling when so -- narrowing, not eliminating, the recycled-PID window (the reaper thread can still reap between the check and the `killpg`, the same inherent TOCTOU sliver `terminate_and_reap`/`ProcessTermination.swift` already have). See the p6-4 results doc §2 for the corrected tests.

**Thread budget: 2 per session (stdout reader, stderr reader) + 1 process-wide reaper — `2N + 1` for N concurrent sessions.** Reaping contributes zero per-session threads. This is a measured pass criterion at P6-4/E-P6-2 Part B (N = 1, 4, 16), not an assumption.

**Supply-chain note (dependency-surface delta, verified against the vendored `nix`/`libc` source at their pinned versions, not assumed — recorded for `cargo deny`; see §12).** `nix = "=0.30.1"` is already a pinned `rust/` workspace dependency (`rust/Cargo.toml:31`), already consumed by `wake_pipe.rs` for pipe/fcntl work (currently with only the `fs` feature enabled in `agentry-runtime`'s `Cargo.toml`); `libc 0.2.189` is already present transitively. The exact feature set §5.1/§5.2 need is `process` (gates `nix::spawn` — `posix_spawn`/`posix_spawnp`, `PosixSpawnAttr`, `PosixSpawnFileActions` — and `nix::sys::wait` — `waitpid`, `waitid`), `event` (gates `nix::sys::event` — `kqueue()`, `kevent()`), and `signal` (gates `nix::sys::signal::SigSet`, needed to build the sigmask/sigdefault arguments) — feature flags on an already-audited crate, not a new third-party crate.

**Verified coverage and a genuine, confirmed gap — not a hypothetical one.** `nix::spawn::posix_spawnp`, `PosixSpawnAttr::{init, set_flags, set_pgroup, set_sigdefault, set_sigmask}`, `PosixSpawnFileActions::{init, add_dup2, add_open, add_close}`, `nix::sys::wait::{waitpid, waitid}`, and `nix::sys::event::{kqueue, kevent}` are all safe (`pub fn`, not `pub unsafe fn`) — consuming them from `agentry-runtime` needs **zero** new `unsafe` blocks. Two Darwin-specific pieces §5.1 needs are **not** covered, confirmed by reading the pinned crate sources directly rather than assumed: (1) `PosixSpawnFlags`' `libc_bitflags!` macro only names `POSIX_SPAWN_RESETIDS`/`SETPGROUP`/`SETSIGDEF`/`SETSIGMASK` — `POSIX_SPAWN_CLOEXEC_DEFAULT` (present in `libc` as `libc::POSIX_SPAWN_CLOEXEC_DEFAULT = 0x4000` on Apple targets) is not a named flag, so P6-4 must confirm whether the generated bitflags type exposes a raw-bits constructor that admits it without `unsafe`, or falls back to (2); (2) **`posix_spawn_file_actions_addchdir_np` has no wrapper anywhere in `nix` 0.30.1, and `libc` 0.2.189 declares it only for `linux-gnu`/`linux-musl`/`cygwin`/`hurd`/`solarish` — it is absent from every Apple-target module.** Working-directory parity with today's `ProcessLauncher.swift:186-196` therefore requires a hand-declared `extern "C"` binding for exactly this one Darwin libc symbol, unconditionally — this is the design's named fallback (§4.2's "if pinning turns up an unexpected gap"), confirmed necessary rather than merely anticipated. `nix::sys::event`'s `EVFILT_PROC`/`EVFILT_TIMER` constants are covered by the `event` feature; no extern binding is needed there.

**`[workspace.lints.rust] unsafe_code = "forbid"` is set at `rust/Cargo.toml:53`.** The confirmed `addchdir_np` extern binding is unconditionally `unsafe` FFI, so a scoped `#[allow(unsafe_code)]` exception on whichever crate/module hosts the spawner (expected: `agentry-runtime`, or a narrower sub-module) is a confirmed P6-4 prerequisite, not a contingent one — **this document surfaces it but does not resolve it**; P6-4 must land the exception deliberately, narrowly scoped to the spawn-attribute module, rather than discover it mid-implementation or scope it to the whole crate.

### 5.3 Draining without deadlock (INV-P6-2)

**The hazard.** Today: `FileHandle.readabilityHandler` → `FileHandleChunkChannel.yield` (`.unbounded` `AsyncStream`, `FileHandleChunkChannel.swift:17,22`) → a single consumer `Task` → `LineFramer` → decode → emit. Unbounded buffering means an arbitrarily fast child can grow parent memory without bound — the recon's flagged hazard. The "obvious" fix, bounding the channel and blocking the producer, is suspected to create a worse hazard: stdout consumer stalls (queue full) → parent stops draining the stdout pipe → the pipe buffer fills → the child blocks in `write(stdout)` → **if** the CLI services stdin and stdout through a shared I/O pump, the child never reads its stdin → an outstanding control request the parent is awaiting (e.g. the 1.5 s interrupt ACK, §4) can never be answered → the stall never clears.

**This inference's load-bearing step is explicitly marked as unverified, not established fact.** The parent-side half is verified: `startStdoutReader` (`:867-889`) always drains and re-arms the `readabilityHandler` regardless of consumer speed, because yielding to an unbounded continuation never blocks. What is *not* verified is "the child blocks in `write(stdout)`" ⇒ "the child never reads its stdin" — a claim about the closed-source `claude` CLI's internal I/O model. No bounded-channel configuration has ever run in this codebase, so the deadlock has never been observed; it is a conservative, defensible inference, not a measured fact.

**Pre-registered falsifying observable** (owned by P6-8's real-binary soak, §11 of the design doc): pause parent stdout draining for a bounded interval while an interrupt is issued; if the control response still arrives, the assumption is falsified and this section is amended to record it. The invariant below does not depend on the outcome — unconditional draining forecloses the failure class either way, at a cost (§5.2's `2N+1` thread budget) already paid regardless.

> **INV-P6-2.** There is no intermediate byte channel between the pipe and the decoder. One reader per stream performs `read()` → frame → decode → translate → non-blocking publish, inline. The stdout pipe is drained unconditionally and continuously, whatever the state of the event queue.

Consequences:

- Backpressure is **never** applied to the stdout byte lane. Loss under overload happens only on the **event** lane (§7), modeled as a gap with resnapshot recovery, never on the byte lane, where loss would corrupt the protocol.
- Each reader is a plain blocking `std::thread` doing `read()` — no new tokio features (§5.1), no `AsyncFd`. Two per session (stdout, stderr); reaping adds zero per-session threads (§5.2). Reader threads and the shared reaper thread both take `userInitiated` QoS (charter §11.5), matching `ProcessTermination.swift:107-110`'s queue QoS.
- The stdout reader never blocks on a stdin write and never awaits a control response. Outbound writes go through a separate serialized writer using the existing single-`write` framing (§2.1) and no-SIGPIPE hardening; a write failure marks the transport dead rather than stalling the reader.
- **Why readers keep per-session threads while reaping does not.** A reap event does trivial, bounded work (one `waitid` probe, one `waitpid`, one event publish) — one shared thread serves every child, exactly like Swift's one shared serial queue. A reader event does *unbounded* work under this invariant (framing + JSON decode + translation of a line that may reach the 8 MiB cap, §5.4) — a shared reader thread would turn one session's large payload into head-of-line blocking on every other session's transport. Isolation is worth a thread there and is not needed for reaping.

### 5.4 The four memory caps — and no fifth

With INV-P6-2 there is no intermediate byte queue to bound. Per-session memory is bounded by exactly four named caps, each with an explicit overflow policy:

| Cap | Value | Overflow policy | Source |
|---|---|---|---|
| Framer carry (per stream) | 8 MiB max line / 16 MiB max carry / 128 KiB tail-retain | drop prefix, retain tail, reset quote/JSON-candidacy state, emit `framer.overflow` diagnostic | port of `ProcessStreamFraming.swift:LineFramer.Limits.default` (`:47-51`) and its overflow branch (`:151-163`) |
| Per-subscription event queue | 256 events / 1 MiB, +1 reserved terminal slot / 4 KiB reserved control bytes | coalesce by key; evict lossy entries before lossless; gap record on loss; oversize ⇒ `PayloadRejected` + `resnapshot_required` | existing `rust/crates/runtime/src/subscription.rs:7-12`, `:239-294`, `:300-417` |
| Per-turn resnapshot buffer *(new — D-8)* | 8 MiB, tuned by E-P6-3's observed maximum with a wide margin (≥4×) | truncate **head**, emit a lossless `transcriptTruncated` marker event, increment a diagnostic counter | new machinery; makes gap-recovery possible by retaining enough of the live turn to answer a resnapshot |
| stderr tail | 256 KiB | ring buffer, tail retained | port of `appendTail(limit: 256 * 1024)` (`ClaudeNativeProcessSessionController.swift:913`, generic helper at `ProcessStreamFraming.swift:4-10`) |

**No fifth structure is permitted.** Any new per-session accumulation must either fit inside one of these four caps or arrive with its own registered cap, overflow policy, and drift entry — "small in practice" is not a bound.

The framer's exact bytes-to-lines algorithm (JSON-candidacy quote/escape tracking, only active when a line starts with `{`/`[`; every non-candidate line splits on every raw `\n`; `\r\n`/`\n` both stripped as line terminators) ports byte-for-byte from `ProcessStreamFraming.swift:LineFramer` — this is the framer the P6-3 re-chunking pass (design §3.4) replays at adversarial 1-byte/prime-sized/in-escape/mid-UTF-8-scalar read boundaries.

## 6. Recovery heuristics and suppression (D-1, D-2 — byte-exact port, not drift)

Four decode-recovery heuristics exist because real CLI builds emit malformed lines; each is the difference between a degraded turn and a dead run. Simplification is explicitly refused at this slice — every threshold below is a named constant with corpus coverage (P6-3), including negative cases.

1. **Concatenated-segment split** (`recoverConcatenatedInboundMessagesIfNeeded`, `:1017-1052`). Only attempted when the line is `≤ maxConcatenatedRecoveryBytes = 2 MiB` (skipping emits `protocol.decode.concatenatedRecoverySkipped`). `splitConcatenatedJSONObjectPayloads` brace-depth-scans the line for multiple top-level `{...}` JSON objects (quote/escape aware) and, if `> 1` segment is found, attempts to decode each independently via the codec; each successful segment is routed as its own inbound message and logged as `protocol.inbound.recoveredSegment`; a segment that still fails logs `protocol.decode.recoveredSegmentSkipped`. `recoveredCount > 0` ⇒ recovery succeeded (`protocol.decode.recovered`).
2. **Embedded-tail scan** (`recoverEmbeddedInboundTailIfNeeded`, `:1058-1099`). Scans only the last `maxTailRecoveryScanBytes = 256 KiB` of the line (or the whole line if shorter) for byte-exact occurrences of the marker `{"type":"` (`jsonObjectMarkerBytes`, a raw byte scan, no String conversion). Skips a marker at absolute offset 0 (that's the same parse that already failed). Tries candidate offsets **from the end** (rightmost/latest embedded JSON preferred); the first offset whose suffix decodes successfully wins, is routed, and logs `protocol.inbound.recoveredTail` with `startOffset`/`byteCount`/a UTF-8 preview.
3. **JSON string control-character repair** (`recoverInvalidJSONStringControlCharsIfNeeded`, `:1136-1144`, delegating to `repairJSONStringControlCharacters` in `ProcessStreamFraming.swift:257-303`). Only applies when the line contains a raw `0x0A`/`0x0D` byte and its first non-whitespace byte is `{` or `[`. Rewrites in-string raw LF→`\n`, CR→`\r`, and any other byte `< 0x20`→`\u00XX`, leaving out-of-string bytes untouched. A successful re-decode logs `protocol.decode.recoveredJSONStringControlChars`.
4. **Plaintext-assistant salvage** (`recoverPlaintextAssistantDeltaIfNeeded` / `recoverablePlaintextAssistantFragment`, `:1146-1214`). Only attempted while a turn is in flight (`turnInFlight`). The trimmed line, decoded as UTF-8, qualifies only if **all** hold: `≥ 40` characters; contains no tab; does not start with `{`, `[`, or the marker `{"type":"`; has `≥ 24` Unicode letters; has `≥ 4` "long words" (maximal runs of letters/digits with length `≥ 4`, split on any other character); has `≤ 8` brace/bracket/semicolon symbols (`{}[];`); does not start with `.` or `/`. A qualifying fragment is emitted directly as a `"content"` `AIStreamResult` (bypassing the translator) and logged as `protocol.decode.recoveredPlaintext`.

`handleLine` (`:946-980`) tries these four in order — (1), (2), (3), (4) — only on `CodecError.invalidJSON` (not `.unsupportedPayload`, which is a well-formed-but-wrong-shape control envelope and is never subject to recovery); the first to succeed short-circuits the rest. All four failing logs `protocol.decode.skipped` with a 512-byte preview and, in `DEBUG`, emits a visible `"system"` warning to the transcript (`emitDebugDecodeSkippedNotice`). A codec error that is *not* `CodecError` at all (e.g. a `JSONSerialization` throw outside the codec's own error type) is treated as fatal: `protocol.decode.failed` is logged and the session calls `failProtocolAndShutdown`.

**Suppression rules** (D-2, `shouldSuppressUserFacingStreamResult`, `:1489-1508`): a `"system"` result whose text starts with `"Task started"` or `"Task update"` is suppressed — surfacing these prematurely ends the active assistant transcript segment and makes the UI look finished mid-turn. An `"error"` result is suppressed when `ClaudeAbortArtifactFilter.shouldSuppressUserFacingError` recognizes it as an abort artifact (JSON parse errors from killed tool processes, the bundled CLI stack-trace variant, non-fatal lock warnings, MCP abort errors). Everything else passes through.

**Heuristic 3's open question, closed at P6-3.** `MANIFEST.json`'s `d1-json-control-char-repair-embedded-lf.ndjson` entry asked whether any real-traffic shape makes the codec's own inline sanitize-and-retry (§2.1) fail while heuristic 3's byte-level repair still succeeds. Checked on the four axes that could produce an asymmetry — control-byte range, in-string/escape tracking, backslash-escape handling, and behavior on invalid UTF-8 — the first three are identical between the two, and the fourth (the codec's sanitize requires the whole line to already be valid UTF-8 before it scans; heuristic 3's byte-level repair does not) never actually distinguishes them, because heuristic 3 does not *fix* a genuinely-invalid UTF-8 byte sequence — it only escapes `0x0A`/`0x0D`/`< 0x20` bytes while tracking quotes, leaving any invalid continuation byte (`≥ 0x80`) untouched, so a line invalid for reasons unrelated to a raw control character still fails the final JSON parse after repair, for the same reason it failed before. **No reachable distinguishing input exists**: heuristic 3 is a defense-in-depth backstop with no currently-reachable distinct trigger, not an exercised-but-untested path — recorded as a finding, not left preliminary. It is still ported byte-exactly per D-1's simplification-refused rule. Full reasoning and the Rust port live at `rust/crates/runtime/src/agent_claude/recovery.rs`'s module doc comment.

## 7. Stream and cancel plane

### 7.1 Event catalog and loss classification

Ported from design §5.2. Classification governs the bounded event queue's pressure policy (§5.4) and must be exactly this, because a misclassification either silently loses a terminal fact or wastes reserved terminal capacity on routine chatter.

| Event | Class | Coalescing key | Rationale |
|---|---|---|---|
| `assistantDelta` / `reasoningDelta` | lossless (payload-carrying) | — | Text is append-only; a silent drop corrupts the transcript. Under sustained pressure these evict lossy entries first; failing that, produce a gap → Swift resnapshots the turn from the §5.4 per-turn buffer. |
| `toolUseStarted` / `toolResult` | lossless | — | Drives tool cards and MCP-idle ack parity (§7.2). |
| `approvalRequest` / `approvalCancelled` | lossless, terminal-class reserve | — | A dropped approval request deadlocks the run. Uses `RESERVED_TERMINAL_SLOTS = 1` / `RESERVED_TERMINAL_CONTROL_BYTES = 4096` (`subscription.rs`). |
| `turnCompleted` | lossless, terminal-class reserve | — | First-terminal-wins (charter §9.1). |
| `interruptOutcome` | lossless, terminal-class reserve | — | §4. |
| `runtimeInit` | coalescible | `runtimeInit:<session>` | Already deduplicated against the last emitted status today (`:1519-1531`); replace-by-key is the same semantic. |
| `taskProgress` / `sessionStateChanged` (non-`idle`) | coalescible | `progress:<session>` | Run-state preview only (§2.3's `task_progress`/non-`idle` `session_state_changed` handling, `:1345-1364`). |
| `sessionStateChanged(idle)` | **lossless** | — | It is a turn boundary (§3). Classifying it as progress silently loses turn completions — this is the named trap. |
| `stderrTail` / `framerOverflow` / `protocolDrift` | droppable diagnostic | `diag:<kind>` | Counters survive; individual records need not. |
| `transcriptTruncated` | lossless | — | D-8's marker (§5.4). |

### 7.2 MCP-idle gating stays Swift-side (not a deferral)

`awaitSteeringInterruptSafePoint` (`ClaudeAgentModeCoordinator.swift:777-819`) composes three host-side facts before an interrupt is allowed to proceed: (1) `awaitNoActiveMCPTools(runID)` — zero in-flight MCP tool executions inside Agentry's own MCP server; (2) `handler.awaitExplicitProviderToolResultAcks(for:atLeast:)` — provider tool-result ack parity; (3) `hasActiveChildAgentRunWaits(runID)` — whether the run is blocked in child `agent_run.wait` scopes. All three are facts about the host (MCP server domain, Phase 5), not the subprocess. The safe point is composed in Swift; Rust receives only the resulting interrupt command, fenced by `turn_generation` (§4). The bounded-timeout structure, including the `timedOut(stillActive: false)` tolerance branch that proceeds anyway when local MCP execution is idle and only a provider ack lags (`:1103-1108`), is preserved verbatim. The generation fence is what makes the split safe: a stale interrupt is rejected by construction (§4's `staleGeneration` outcome), not by a race-tolerant re-check.

## 8. Host-owned-tool-name data contract

The package translator's `treatsToolResultErrorsAsHostOwned:` closure (`ClaudeSDKNDJSONTranslator.swift:9,13`, wired to `MCPIntegrationHelper.isRepoPromptToolName`) is the one host coupling in otherwise Foundation-only, app-independent package code. A synchronous host callback in the hot path is forbidden across the FFI (charter §5.3, §8.4) — but `isRepoPromptToolName` (`MCPIntegrationHelper.swift:229-231`) resolves through `resolveRepoPromptToolName` (`:198-209`), a **pure string function**: trim, lowercase, strip a `functions.` prefix, strip an explicit server-name prefix, look up a canonical alias table. Its only external input is the constant `repoPromptMCPServerName` (`:36`).

**Decision: the closure becomes data.** At session-open, Rust receives the server name plus the canonical alias set once (not per-call), and evaluates the equivalent predicate itself, in-process, with no FFI crossing on the hot tool-result path. A differential asserts the Rust predicate agrees with the Swift one over the full alias table plus adversarial prefixed/normalized/`functions.`-prefixed forms — this is E-P6-1 pass criterion (c).

## 9. Terminal-event / drift register cross-reference

This document's §3–§6 are the byte-exact/behavior-exact port targets for design drift items D-1 through D-9. Nothing in §2–§8 above introduces new behavior beyond D-8 (the per-turn resnapshot buffer, §5.4) and D-9 (raw-event records produced Rust-side, §10 below, same keys/shapes, additive kinds only). D-3 (idle-fallback timer moves to a Rust timer thread; value/generation-token/record preserved), D-6 (stream results cross as a versioned compact payload, field-for-field), and D-7 (`hasTurnInFlight`/`hasActiveSession` become event-derived facts; the two surviving Swift call sites — the provider-identity-transition recycle deferral at `ClaudeAgentModeCoordinator.swift:377-383` and the pre-send liveness guard at `:963-969` — are already staleness-tolerant, each immediately re-validated by `intentIsCurrent`/`sessionOwnsClaudeController` guards) are process-boundary consequences, not behavior changes, and are named here for traceability rather than re-specified.

**Not drift, and must not become drift**: turn-ID FIFO ordering; the result→idle deferral window; `turnWasInterrupted ⇒ cancelled`; EOF ⇒ pending turns fail; the meaning of each of today's four interrupt outcomes (§4's fifth is additive); the spawn attribute set (§5.1); the sole-reaper discipline (§5.2); approval-request stable IDs (`ClaudeNativeProcessSessionController.swift:2030-2040`, `AgentApprovalRequest.stableID(requestID:method:kind:threadID:turnID:itemID:)`); auto-approval matching semantics; `--resume` behavior and `providerSessionID` persistence (design §6, unchanged for this vertical).

## 10. Raw-event record-kind inventory (R9), frozen at P6-1

Every `writeRawEventLogRecord(kind:...)` call site in `ClaudeNativeProcessSessionController.swift`, enumerated exhaustively by a source-wide regex scan for `kind: "..."` literals rather than by eye (44 distinct kinds across 49 call sites plus the one function definition; several kinds recur at more than one call site — e.g. `translator.streamResult` at three, `session.flagSettingsApplied`/`turn.interrupt.failed`/`control.request.sent` at two each — which is why 49 ≠ 44). This is the set the DEBUG `agent_mode.claude_raw_event_logging_enabled` / `agent_mode.claude_raw_event_log_file_path` instrument produces today, and the set the Rust port must reproduce under the **same** `app_settings` keys (charter §11.7 forbids a second switch system) with the **same** record shape. The set may **gain** Rust-only kinds (e.g. a `turn.interrupt.staleGeneration` retry record, §4); it may **not lose** any kind below without a named, reviewed replacement.

| Kind | Emission site (anchor) |
|---|---|
| `session.startOrResume` | session start/resume entered, after `ensureRawEventLogFileReadyIfNeeded` (`:392`) |
| `process.spawned` | spawn, after `ProcessLauncher.spawn` returns (`:605-612`) |
| `process.stderr` | every stderr chunk (`:914`) |
| `process.stdoutEOF` | stdout EOF (`:1901`) |
| `protocol.outbound.raw` | every outbound line, both `sendLine` call sites (`:846`) |
| `protocol.inbound.raw` | every inbound line, before decode (`:947`) |
| `protocol.inbound.streamPayload` | decoded `.streamPayload` case (`:989`) |
| `protocol.inbound.controlRequest` | decoded `.controlRequest` case (`:992`) |
| `protocol.inbound.controlResponse` | decoded `.controlResponse` case (`:999`) |
| `protocol.inbound.controlCancelRequest` | decoded `.controlCancelRequest` case (`:1008`) |
| `protocol.inbound.keepAlive` | decoded `.keepAlive` case (`:1011`) |
| `protocol.inbound.recoveredSegment` | concatenated-split recovery, per successful segment (`:1036`) |
| `protocol.inbound.recoveredTail` | embedded-tail recovery, on success (`:1095`) |
| `protocol.decode.skipped` | all four recovery heuristics failed (`:962`) |
| `protocol.decode.failed` | non-`CodecError` decode failure ⇒ fatal (`:975`) |
| `protocol.decode.concatenatedRecoverySkipped` | concatenated recovery skipped, line `> 2 MiB` (`:1022`) |
| `protocol.decode.recoveredSegmentSkipped` | concatenated recovery, one segment still failed (`:1040`) |
| `protocol.decode.recovered` | concatenated recovery, at least one segment succeeded (`:1048`) |
| `protocol.decode.recoveredJSONStringControlChars` | control-char repair recovery, on success (`:1139`) |
| `protocol.decode.recoveredPlaintext` | plaintext-assistant salvage, on success (`:1152`) |
| `framer.overflow` | `LineFramer` carry/line overflow (`:928`) |
| `framer.nonJSONCandidateReset` | `LineFramer` quote-state force-reset for a non-JSON-candidate line (`:936`) |
| `runtime.init.stream` | `system/init` payload parsed for tools/MCP statuses (`:1286`) |
| `translator.streamResult` | every non-suppressed translated stream result (`:1349`, `:1359`, `:1368`) |
| `translator.streamResultSuppressed` | a stream result matched D-2 suppression (`:1365`) |
| `lifecycle.idleFallback` | idle-fallback timer fired (`:1443`) |
| `turn.interrupted` | interrupt ACKed (`:470`) |
| `turn.interrupt.timedOut` | interrupt ACK deadline exceeded (`:476`) |
| `turn.interrupt.failed` | interrupt failed (transport/write error) (`:481`, `:487`) |
| `control.request.sent` | outbound control request registered (both `sendControlRequest` and the fire-and-forget `sendControlRequestWithoutResponse`, `:790`, `:832`) |
| `control.request.received` | inbound `control_request` routed (`:1771`) |
| `control.request.cancelled` | inbound `control_cancel_request` routed (`:1856`) |
| `control.response.received` | inbound `control_response` routed (`:1869`) |
| `approval.request.emitted` | a `can_use_tool` request surfaced as an approval request (`:1812`) |
| `approval.autoApprove.repoPrompt` | RepoPrompt-owned tool auto-approved (`:1787`) |
| `approval.autoApprove.fallback` | fallback auto-approval matched (`:1824`) |
| `approval.response.sent` | a permission decision written back to the CLI (`:501`) |
| `session.initialized` | `initialize` control response received (`:664`) |
| `session.permissionModeInitialized` | permission-mode control response received (`:731`) |
| `session.flagSettingsDeferred` | flag-settings application deferred (launch-env change requires restart) (`:425`) |
| `session.flagSettingsPending` | flag-settings application pending initial handshake (`:435`) |
| `session.flagSettingsApplied` | flag-settings control response received (`:443`, `:717`) |
| `session.shutdown` | `shutdown()` entered (`:521`) |
| `session.failProtocol` | fatal protocol failure path (`:2201`) |

## 11. System lifecycle declarations (charter §11.6, design §4.7)

Charter §11.6 makes two declarations a per-domain obligation, not an optional refinement. This vertical's:

**Sleep/wake — parity with today, no new recovery behavior.** The child survives system sleep: macOS neither signals nor reaps it, the process group stays intact, no exit event fires; nothing in §5.2 changes across the boundary. The CLI's own network state may not survive sleep — an API failure surfaces as a `result` payload with `errors[]` ⇒ turn `.failed` (§3); or the CLI goes silent, and the turn stays in flight with no result and no `idle`. **Silence is unbounded today** (no wall-clock turn watchdog exists), and this vertical does **not** add one — a watchdog is a product behavior change belonging in its own slice with its own drift entry, not smuggled in under a language migration. **Timer semantics are pinned**: the 1.0 s idle fallback (§3), the 1.5 s interrupt-ACK deadline (§4), and the 0.5 s reaper fallback probe (§5.2) must all run on a monotonic clock that does not advance during system sleep, matching the `Task.sleep`/`DispatchSourceTimer` behavior they replace. P6-4 arms each timer, simulates a sleep-length clock discontinuity, and asserts neither a spurious immediate fire nor a skipped fire. The reaper's 0.5 s fallback probe is the designed recovery for a `NOTE_EXIT` delivered or missed across a sleep boundary — it self-heals on the next probe. Sudden termination (disable while an Agent run is active) stays a Swift-side policy; the Rust scope's only obligation is to keep exposing run liveness so that policy keeps working after the controller moves (P6-8 test).

**Window-closed-but-process-alive — the run survives, the subscription does not.** Scope lifetime binds to the run/session, never to a window — already true today (the controller is owned by the coordinator, owned by `AgentModeViewModel`, not by any window); a closing window must not terminate a live agent process. A subscription whose consumer disappears must be **closed, not abandoned** — an undrained bounded queue (§5.4) fills, coalesces, gaps, and converts every subsequent event into a permanent gap generator that also pins its byte budget. Policy: closing the last presentation consumer closes its subscription; it does not stop the run (P6-6 test: no subscription outlives its drainer). With zero subscribers, the scope keeps supervising the process and keeps the turn state machine authoritative; it publishes nothing (nobody to publish to); terminal facts — turn completion, `providerSessionID`, per-turn usage — are retained in scope state. A reattaching window gets them through `open_subscription`'s atomic bootstrap snapshot (charter §9.3), not replayed events — the per-turn resnapshot buffer (§5.4) is what makes that snapshot answerable, so it is retained while the run is live regardless of subscriber count. Swift-side transcript persistence is unchanged (design §6): a window reopening after a long headless stretch reads persisted history plus a live bootstrap, exactly as today.

## 12. Dependency-surface delta and `cargo deny`

P6-1 pins the exact `nix` feature set §5.1/§5.2 need — `process`, `event`, `signal`, alongside the already-enabled `fs` — in `rust/crates/runtime/Cargo.toml`, and re-runs `cargo deny` against it now, before any implementation exists, so the supply-chain decision is reviewed at contract-freeze time rather than discovered mid-slice. See the commit landing this pinning for the recorded `cargo deny` result and whether `rust/Cargo.lock` changed (an unchanged lock is itself the evidence the delta is feature-flags-only, not a new dependency). §5.1's verified coverage/gap analysis is the load-bearing content here: `nix` 0.30.1 safely covers `posix_spawnp`, spawn-attribute setters (`RESETIDS`/`SETPGROUP`/`SETSIGDEF`/`SETSIGMASK`), file actions (`dup2`/`open`/`close`), `waitpid`/`waitid`, and `kqueue`/`kevent` with zero new `unsafe` in `agentry-runtime`; `posix_spawn_file_actions_addchdir_np` has no wrapper in `nix` and is absent from `libc` 0.2.189 on every Apple target, so P6-4 needs exactly one hand-declared `extern "C"` binding for it, and correspondingly exactly one scoped `unsafe_code` lint exception (`rust/Cargo.toml:53` sets `forbid` workspace-wide) — both confirmed necessary, not merely anticipated, and recorded here as a named prerequisite this document surfaces but does not resolve.

## 13. Boundary exclusions

P6-1 does not migrate or own, and no later Claude-vertical step migrates without its own design/ADR:

- The Agent Mode transcript store, tool tracking, tool cards, run-state ownership, or approval UI (core-owned per `docs/architecture/provider-plugins.md`).
- `AgentSession`/`AgentSessionIndex` persistence — format, schema version, and write path stay Swift-owned for the entire Claude vertical (design §6; charter §15.3 gate 4 exempt).
- The headless one-shot Claude provider (`ClaudeCodeAgentProvider`, `HeadlessAgentProvider`).
- GLM / Kimi / custom Claude-compatible (deferred to P6-9).
- Codex, ACP, or any other provider family.
- The MCP-idle steering safe point's host-side facts (§7.2) — Phase 5 territory.
- The Host Capability Broker's Agent-domain wiring (charter §11.1) — the charter-idiomatic `HostRequest` alternative for the MCP lease/PID-fence ordering is explicitly not taken in this vertical (design §4.6); today's window and race-tolerance are the parity bar, not an improvement.

## 14. Cutover rule

This document is a contract freeze. The Rust implementation must pass the codec/translator differential (P6-3, cargo-only), the process-supervision synthetic-CLI matrix and spawn-attribute parity (P6-4, cargo-only), the DEBUG shadow-arm zero-mismatch gate on live bytes (P6-5), the FFI/bridge surface tests including the five-outcome interrupt reachability test and the no-orphan-subscription test (P6-6), and the turn-level differential plus observability parity (P6-7) before P6-8's cutover commit. Runtime or parity errors never trigger an automatic Swift fallback. After cutover, rollback is source/artifact rollback only (charter §15.3 item 10) — the Swift controller survives only as the implementation of the three not-yet-migrated variants (P6-9), and is deleted in P6-9's commit, not kept as a live rollback switch.

---

## 15. P6-7 amendments

Findings and additions made while building P6-7's turn-level differential, recorded here per this document's own "re-anchor rather than silently trusting this document" rule (§0) and the campaign's drift-register discipline. `docs/designs/p6-claude-vertical-2026-08-23.md` is gitignored and cannot be the durable record of these; this section is.

### 15.1 D-10: `shutdown()`'s deferred-flush ordering bug (Swift-side, fixed)

§3's state machine states "any --shutdown--> flush deferred with original status (never rewritten to Failed)." Swift's `cancelAuthoritativeLifecycleState()` (called from `shutdown()`) implements this correctly in isolation, but `shutdown()` called `clearTurnIDQueue()` **before** `cancelAuthoritativeLifecycleState()` -- the latter dequeues one turn ID per flushed deferred status, guarded by `hasPendingTurnIDs`, so clearing the queue first emptied it out from under that guard and the flush loop broke on its first iteration. **Result: `shutdown()` silently dropped every deferred `ResultObserved` turn completion**, contradicting this section and diverging from Rust's `turn_state::on_shutdown`, which already implemented the contractual behavior (found and documented in P6-5's `turn_state.rs` module doc, landed at `a8bd85bc`, with the exact delta named at `e0d4d290`). Swift's stdout-EOF path (`handleStdoutEOF`) has no such ordering bug and was already correct -- confirming this was an isolated ordering defect, not intentional drift. **Fixed**: `shutdown()` now calls `cancelAuthoritativeLifecycleState()` before `clearTurnIDQueue()`, matching the EOF path and this section's stated contract. Regression coverage: `ClaudeNativeShutdownDeferredFlushTests` (`Tests/RepoPromptTests/AgentMode/ClaudeCompatible/`).

### 15.2 D-6 amendment: the P6-6 event-publishing fidelity gap, closed

`agent_claude::scope`'s `emit_stream_result` (P6-6) published only one field per translated `StreamResult` kind (e.g. `content`/`reasoning` carried only `text`; every other kind -- `usage`, `status`, `system`, `final_content`, `auth_status`, a forwarded non-authoritative `message_stop`, and any future kind -- collapsed into a `taskProgress` event carrying only `text`), with the module's own code comment naming full per-kind fidelity as "P6-7's turn-level differential's job." **Closed**: every published stream event now carries the full non-nil `StreamResult` field set (`stream_result_wire_fields`, `scope.rs`) -- `type`, `text`, `reasoning`, `prompt_tokens`, `completion_tokens`, `cost`, `tool_name`, `tool_args`, `tool_output`, `invocation_id`, `tool_result_json`, `tool_args_json`, `tool_is_error`, `provider_session_id`, `stop_reason`, `model_context_window`, `context_used_tokens`, `content_message_id` -- mirroring `ClaudeCodecShadowComparator.compareOneResult`'s already-reviewed exhaustive field list (P6-5's `e0d4d290` follow-up) including its same two structural exclusions (`toolInvocationID`: a synthetic `InvocationId(u64)` can never structurally match Swift's `UUID`, carried as `invocation_id` for within-arm correlation only; `cleanupHandle`: Swift-only, no wire representation). `type` carries the original translator kind string since the coarse `AgentClaudeEventKind` (§7.1's pressure-policy classification) cannot reconstruct it alone.

A second, related gap: `handle_authoritative_result` (the `result`/`message_stop` turn-boundary path) published only the minimal `turnCompleted` event, discarding the authoritative result's own usage/cost/providerSessionID/stopReason/modelContextWindow fields entirely. Swift's `handleStreamPayload` always `emit(.stream(result))`s the authoritative result **before** its own turn-completion bookkeeping (`ClaudeNativeProcessSessionController.swift:1358` precedes `:1370`). **Closed**: `handle_authoritative_result` now also routes `result` through `emit_stream_result` (publishing it as a `taskProgress`-classified event with the full field set above) before publishing `turnCompleted`, matching Swift's ordering. Coverage: `every_stream_result_field_rides_the_wire_not_just_one_field_per_kind` (`rust/crates/runtime/tests/agent_claude_scope.rs`), driven against a real synthetic-CLI child through the actual spawn/read/frame/decode/translate/publish pipeline.

### 15.3 `apply_model_and_effort` ACK parity, closed

§2.2 ports `sendControlRequest`'s register-before-write, timeout-bounded shape generically, but P6-6's `apply_model_and_effort` shipped as a scope-reduced, fire-and-forget placeholder (no ACK tracking, no timeout, no response payload) -- its own doc comment named full parity as "P6-7's job." Swift's live-update call site (`applyModelAndEffort(model:effortLevel:)`, `:460-491`) `await`s `sendControlRequest(request:timeoutSeconds: 5.0)` and throws on timeout/transport failure.

**Closed, mirroring `agent_interrupt_turn`'s command+event shape exactly** (charter §8.2's fast-enqueue contract): `apply_model_and_effort` now returns a `request_id` immediately (identity/closed checks and request construction run synchronously), while the genuine ACK round trip (`control::send_control_request`, a 5 s timeout matching Swift's live-update deadline) runs on a background thread. The outcome -- `applied` (carrying the control response payload under a `response` field when present), `timedOut`, or `failed` (carrying an `error` field) -- publishes later as a new **`flagSettingsApplied`** terminal-class event (§7.1: lossless, reserved-terminal-slot, additive per §9's "may gain Rust-only kinds") correlated by the same `request_id`.

**FFI surface change, not additive**: `agent_apply_model_and_effort`'s return type changed from throws-only (void) to `-> AgentClaudeFlagSettingsReceiptV1 { request_id: String }`, mirroring `AgentClaudeInterruptReceiptV1`. **ABI-epoch decision: no bump.** Recorded in full in `rust/ffi-contract/exports.txt`'s inline comment and `rust/ffi-contract/abi-v1.json`'s `agentClaudeV1.abiEpochDecision` field: Swift bindings and the Rust FFI archive are always regenerated and rebuilt together from the same commit, never independently versioned or shipped, and `buildFingerprint`/`bindingChecksum` (recomputed and validated via `staleRuntimeIdentity` on every raw call) already catch binding/archive staleness at a finer grain than `abiEpoch` guards; `abiEpoch` protects the coarse envelope/wire-format layer (header layout, payload kinds), which this change does not touch.

**Remaining Swift-side consumption is not yet built.** This section closes the Rust-side ACK-tracking gap and updates `Sources/AgentryCoreBridge/CoreAgentSession.swift`'s facade to the new receipt shape so the app keeps compiling, but the Rust-backed `NativeAgentRuntimeControlling` adapter that would actually await this event and surface `async throws` semantics to the coordinator (per-P6-7 §1 bullet, "a second `NativeAgentRuntimeControlling` implementation backed by the Rust scope") does not exist yet -- closed in §15.4 below.

### 15.4 The adapter, the DEBUG selection flag, and the turn-level differential, closed; D-9/R9 still owed

This section closes the predecessor's §15.3 remaining-work note: the P6-7 §11 step-list's primary deliverable ("a second `NativeAgentRuntimeControlling` implementation backed by the Rust scope, selectable by a DEBUG-only flag") and its turn-level differential now exist, both landed and green as of `dcc09247`.

**`ClaudeRustBackedNativeSessionAdapter`** (`Sources/RepoPrompt/Features/AgentMode/Providers/ClaudeCompatible/`, entirely `#if DEBUG`-gated) wraps one `CoreAgentSession` and implements `NativeAgentRuntimeControlling` in full, decoding the contract §7.1 wire-kind catalog back into the same `NativeAgentRuntimeEvent`/`AIStreamResult`/`AgentApprovalRequest` shapes the still-authoritative Swift arm produces. It resolves command path and launch environment through the exact same pure helpers the Swift controller uses (`CommandPathResolver`, `ProcessEnvironmentBuilder`, `ClaudeCodeLaunchEnvironmentResolving`) rather than re-deriving them, and reconstructs `AIStreamResult` via `ClaudeCompatiblePluginBridge.streamResult(from:)` -- the same package-DTO mapping the Swift arm calls -- fed from `stream_result_wire_fields`'s full field set (§15.2). It owns three impedance mismatches in-adapter: `turnGeneration: u64` (which the wire also carries as `turn_id` -- `send_user_message` mints one value that serves both roles, confirmed by reading `scope.rs`) mapped bidirectionally to the protocol's `UUID` turn IDs, and used directly to answer `hasTurnInFlight` (D-7) as an event-derived fact (a generation is pending from `sendUserMessage` until its `turnCompleted` arrives, regardless of status); command+event correlation registries (keyed by `request_id`) for `interruptTurn`/`applyModelAndEffort`, each with a belt-and-braces outer deadline above Rust's own authoritative one; and the five-outcome-to-four-outcome interrupt mapping, absorbing `staleGeneration` via §4's bounded single retry so the shared `NativeAgentRuntimeInterruptOutcome` (§7's not-drift four cases) is never widened.

**Selection** is `ClaudeRustBackedNativeSessionAdapterSelection` (same directory, also entirely `#if DEBUG`), gated on the `AGENTRY_CLAUDE_RUST_BACKED_ADAPTER` environment variable rather than an `app_settings`/UserDefaults key -- deliberately, since this arm is not authoritative, has no product UI, and (§15.3 item 10) must not survive as a permanent per-domain switch past P6-8/P6-9. Wired at `ClaudeAgentModeCoordinator.makeDefaultController`'s existing swap point. `ClaudeRustBackedAdapterReleaseAbsenceTests` strips every `#if DEBUG` block from the adapter, the selection flag, and the coordinator and asserts none of the three symbol/env-var names survive in the release projection -- the §1.1 release-guardrail discipline, mirrored for this Swift-side flag. The §1.2 headless-isolation guardrail (`Scripts/source_layout_guardrails.sh` §11) is extended with the same reachability-chain check `ClaudeNativeProcessSessionController` already has, confining `ClaudeRustBackedNativeSessionAdapter(` construction to `ClaudeAgentModeCoordinator.swift`.

**The turn-level differential** (`Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeRustBackedTurnLevelDifferentialTests.swift`) drives both arms against the identical real `agent-claude-synthetic-cli` child process in its `scripted` mode (`rust/crates/runtime/tests/support/synthetic_cli.rs`) -- real spawn, real EOF/shutdown, no in-process parsing, per this task's predecessor-derisked approach. `AGENT_CLAUDE_SYNTHETIC_CLI_ARGS` is injected through each arm's existing `ClaudeCodeLaunchEnvironmentResolving` constructor seam, so both arms exercise their real, unmodified `buildArguments`/`build_arguments` path while the synthetic CLI overrides its own mode from the env var rather than positional argv -- neither arm needed a raw-argv test escape hatch. The canonical comparator normalizes arm-local turn/tool-invocation UUIDs to first-appearance ordinals (not exclusion, so a real correlation bug still surfaces) and asserts byte-identical `AIStreamResult` sequences, one approval round-trip, the `session_state_changed(running)` -> `result` -> `session_state_changed(idle)` deferred-completion path, and `providerSessionID` across both arms.

**D-7** (§9): the two surviving staleness-tolerant call sites now each carry a named regression test (`Tests/RepoPromptTests/AgentMode/ClaudeCompatible/ClaudeAgentModeCoordinatorD7StalenessToleranceTests.swift`), exercised against the existing `LifecycleFakeNativeController` test double (widened with an optional `sendUserMessageFailure` override) rather than the real adapter, since the property being pinned is about the *coordinator's* tolerance for a stale boolean, not about the adapter's own correctness (which the differential above already covers).

**A real, confirmed gap found while building the adapter, not fixed in this session.** `agent_claude::scope::AgentClaudeScope::start_or_resume` never sends the CLI's SDK `initialize` control request (`ClaudeNativeProcessSessionController.initializeIfNeeded`/`buildInitializeRequest`, the `systemPrompt` override parameter) before accepting user messages -- confirmed by reading `agent_claude::permission` and `scope.rs` end to end; the sole `"initialize"` string in `rust/crates/runtime/src/agent_claude/` is an unrelated negative test fixture (`permission.rs`'s `a_non_can_use_tool_subtype_is_not_recognized`). This does not affect the turn-level differential above (the synthetic CLI's `scripted`-mode background responder ACKs *any* control request regardless of subtype, so both arms' handshakes -- Rust's absent one and Swift's real one -- complete equally against it) or any cargo-only/corpus differential, but it is confirmed to matter against the real `claude` CLI, which is presumed to expect this handshake. **This must be closed before the P6-8 real-CLI soak (item 8 below) has any chance of passing.** No design/contract line currently owns sending it Rust-side; the fix is a new `agent_claude::scope` method (mirroring `apply_model_and_effort`'s command+event shape, since the initialize response should be observable) invoked once at the top of `start_or_resume`, with its own contract-doc row and drift entry if the response shape differs from a no-op today.

**Owed and explicitly deferred: D-9/R9, the 44-kind raw-event-log record inventory, Rust-side.** §10's inventory (frozen at P6-1) has not moved -- Rust still produces none of these 44 kinds under the `agent_mode.claude_raw_event_logging_enabled`/`agent_mode.claude_raw_event_log_file_path` `app_settings` keys. This is the P6-7 step-list's named "observability parity (R9) demonstrated by producing byte-comparable raw-event records under the same `app_settings` keys" requirement, and it is the largest remaining piece of P6-7's own scope -- deliberately not started this session per the task's own guidance ("if context gets tight ... beats starting 5 and leaving regenerated bindings mid-flight"), since it is the only P6-7 item that touches the full `rust/` protocol (config-field addition -> `cargo run --locked -p xtask -- generate` -> `make dev-cargo-archive` -> identity-file regen -> `make dev-cargo-test CARGO_PACKAGE=all` -> `make dev-cargo-codegen-check` -> Swift consumption) rather than being cargo-only or Swift-only. Recorded design, per this document's §9 ("D-9 must not ride the event plane... Rust writes the file itself"): the resolved log-file path and enabled flag are new `CoreAgentClaudeScopeConfigV1` fields (Swift already resolves both today via `ClaudeNativeProcessSessionController.isRawEventFileLoggingEnabled()`/its raw-event-log-file `app_settings` read, so this is plumbing, not new policy); Rust writes each of the 44 kinds directly to that file from inside the scope at the same call sites the Swift port's behavior already anchors them to (framer/codec/translator/turn-state/control/permission/session-lifecycle modules each already know their own equivalent moment); no kind may cross the FFI/event plane. A `cargo`-only differential (comparable to E-P6-1's corpus differential) asserting the Rust-written log's record shapes match Swift's, plus a live-synthetic-CLI-driven test asserting kind-set completeness (all 44 present, none missing, Rust-only-additive kinds allowed per §10's rule), is the closing gate.

**Item 8 (P6-8's bounded real-binary soak against the actual `claude` CLI) remains blocked-named, unchanged from prior sessions: E-P6-1 user approval outstanding.** Nothing in this session unblocks it, and per the finding above, it cannot pass yet regardless -- the missing `initialize` handshake would need to be closed first.

### 15.5 The missing `initialize`/`set_permission_mode` handshake, closed

This section closes §15.4's confirmed gap. `AgentClaudeScope::start_or_resume` now performs the full session-startup control-request handshake synchronously, blocking the FFI-crossing call until it completes or the transport dies, before returning `StartReceipt` -- mirroring Swift's `startOrResume` awaiting `initializeIfNeeded()` before returning a `SessionRef` (`:445-447`) rather than adopting the command+event async pattern `apply_model_and_effort`/`interrupt_turn` use. That choice is deliberate, not a simplification: Swift's own equivalent is already a blocking `await` chain with the identical observable contract (the caller cannot send a user message until the handshake is done), so blocking here is parity, not a new async-FFI precedent (charter §5.3/§8.2 still hold -- this is not a *new* async foreign method, it is the existing synchronous `start_or_resume` command doing more work before returning, exactly as it already did for spawn).

**Sequence, ported verbatim from `initializeIfNeeded`/`buildInitializeRequest` (`:701-720`, `:795-800`) and `applyInitialPermissionModeIfNeeded`/`buildSetPermissionModeRequest` (`:730-736`, `:812-819`):** `initialize` (carrying `systemPrompt` when `AgentClaudeScopeConfig.system_prompt` is set -- new field, threaded from a new `CoreAgentClaudeScopeConfigV1.system_prompt` FFI field, from a new `CoreAgentSessionConfig.systemPromptOverride`, finally consumed by `ClaudeRustBackedNativeSessionAdapter.startOrResume`'s previously-discarded `systemPromptOverride` parameter -- §15.4 named this adapter parameter as "accepted for protocol conformance but has no effect"; it now has one), then `set_permission_mode` whenever `AgentClaudeScopeConfig.permission_mode` is non-empty after trimming -- reusing the *existing* `permission_mode` field `build_arguments` already reads for the `--allow-dangerously-skip-permissions` argv flag, not a new config surface. **`--resume` does not skip or reorder either request**: `initializeIfNeeded` never branches on `existingSessionID`, and neither does `perform_startup_handshake`.

**Deliberately not ported: `applyInitialFlagSettingsIfNeeded` (`:775-789`, the initial `apply_flag_settings` model/effort request).** On the Rust arm that role is already filled by a *different*, already-landed call site -- `ClaudeRustBackedNativeSessionAdapter.startOrResume`'s post-`startOrResume` best-effort `applyModelAndEffort` call (§15.3) -- which fires the equivalent `set_model_and_effort` request without blocking session start-up on its ACK. Porting a second, blocking copy into `perform_startup_handshake` would race that adapter call and double-send the settings request; the adapter's non-blocking placement is that section's own documented intentional design, not an oversight this section closes. This is a named, reasoned scope boundary, not a silent gap: contract §1's ownership table and §2.5's argv row are unaffected, and no `claude` CLI behavior depends on the *order* of flag-settings vs. initialize/permission-mode (they are independent control-request subtypes).

**No bounded timeout, matching Swift's actual (undocumented-as-a-feature) behavior.** `sendControlRequest(request:)`'s default is `timeoutSeconds: TimeInterval? = nil` (`:838`) -- no timeout task is ever armed for `initialize`/`set_permission_mode` in Swift today. The only thing that unblocks a stuck handshake is `failPendingControlRequests` from `handleStdoutEOF`/`shutdown` (`:1994`, `2010`). The Rust port is exact, not an improvement: [`control::send_control_request_blocking`] (new, `control.rs`) uses `mpsc::Receiver::recv()` (no deadline) rather than `recv_timeout`, and is unblocked only by [`ControlCorrelator::fail_all`] from `on_stdout_eof`/`shutdown` -- the same two call sites Swift's `failPendingControlRequests` fires from. A control response with `subtype != "success"` fails the handshake with the CLI's own error message (new `AgentScopeError::ControlResponseError`, mapped to a new `CoreError::AgentClaudeControlResponseError` FFI variant and a matching `CoreTransportError`/`CoreBridgeError` Swift case), porting `handleControlResponse`'s `"error"` subtype branch (`:1962-1963`) -- a distinction the pre-existing `interrupt_turn`/`apply_model_and_effort` control-request call sites still do not make (any `ControlOutcome::Response` there is treated as success regardless of subtype); left as-is, named rather than silently widened, since fixing it is unrelated to this gap.

**On handshake failure, `start_or_resume` tears the process down and returns the error** (`self.shutdown(identity)` then `Err(handshake_error)`), matching Swift's `startOrResume` catch block (`if process != nil ... { await shutdown() }; throw error`, `:450-453`) -- a half-initialized scope is never left for the caller to believe is running.

**Synthetic-CLI coverage, `rust/crates/runtime/tests/support/synthetic_cli.rs`'s `scripted` mode extended with two new race-free directives** (both enforced inside the responder thread's own send decision, never a script-side poll, after an early `AWAITACKS`-based draft measurably flaked under load -- see the directives' own doc comments for the mechanism): `AWAITACKS <n>` blocks the main script thread until the responder has sent `<n>` ACKs (sequences a script's own `OUT` lines strictly after the handshake completes); `NOACK_AFTER <n>` ACKs exactly the first `<n>` requests then permanently starves every request after that (drives a deterministic missing-ACK/EOF-classification outcome without racing a `NOACK` toggle against the handshake's own ACK). Coverage lands across both crates:
- `rust/crates/runtime/tests/agent_claude_scope.rs`: every existing `start_or_resume` call site updated to actually complete the handshake (`well-behaved`/`stdin-closed-after-delay`-based tests that had no responder capability moved to `scripted` mode or gained a leading ack-then-close step in the mode itself); **`interrupt_times_out_when_the_synthetic_cli_never_acks`/`apply_model_and_effort_times_out_when_the_synthetic_cli_never_acks`** now use `NOACK_AFTER 1` to starve only the *second* control request, proving the handshake's own `initialize` ACK is unaffected by a script that means to starve something else -- this is the "resume-vs-start variants per what Swift actually does" coverage's negative half (a missing-ACK, EOF-driven failure classification distinct from an artificial timeout, since Swift has none for this handshake). The positive half -- a resume (`start_or_resume(identity, Some(resume_session_id))`) still runs the identical handshake, not just a fresh start -- is now its own directed test, `start_or_resume_runs_the_full_handshake_on_a_resume_not_just_a_fresh_start`, rather than resting solely on the differential's own `existingSessionID: nil` coverage (which only exercised the negative case).
- **`initialize` response `session_id` capture:** a new `ACK_SESSION_ID <id>` `scripted`-mode directive (pre-scanned into the responder's initial state before it is spawned, so a leading directive cannot lose the race against the responder ACKing the handshake's own first request before the main script thread reaches it) lets a test supply a `session_id` inside the *nested* `response.response` body the real Claude Code SDK's control-response envelope carries it in (`codec::ControlResponse.response: Option<Map>`), isolating `send_initialize_request`'s `recordObservedSessionID`-mirroring capture (`scope.rs:507-513`) from the pre-existing stream-message capture path (`translator.rs:110-111,143-145`) every other test exercises. `initialize_response_session_id_is_captured_and_rides_a_later_message_stop` proves the id observed only from the handshake response rides a later `message_stop`'s `provider_session_id` (`translator.rs:523-524,551`, the same field `--resume` continuity reads).
- `rust/crates/ffi/src/api.rs`: the same treatment for the FFI-crossing twins (`agent_claude_full_lifecycle_round_trips_through_the_ffi_surface`, `agent_claude_interrupt_stale_generation_is_reachable_through_the_ffi_surface`, `agent_claude_every_command_rejects_a_mismatched_runtime_identity`), plus the `stdin-closed-after-delay` mode fix covering `agent_claude_interrupt_failed_is_reachable_through_the_ffi_surface` automatically.
- `Tests/RepoPromptTests/AI/AgentClaudeSameProcessReaperCoexistenceTests.swift`: its `/bin/sleep` stand-in (inert pre-§15.5, since `start_or_resume` sent nothing requiring a response) moved to the real synthetic CLI in `scripted` mode -- the reaper-coexistence property under test is unaffected, only the child now genuinely completes `start_or_resume` instead of failing the handshake on an immediate argv-error exit.
- **Differential margin bump, and what was actually located.** The turn-level differential (`ClaudeRustBackedTurnLevelDifferentialTests`, §15.4) already drives `start_or_resume(existingSessionID: nil)` through both arms every run; its own config sets a non-empty `permissionMode`, so this section's change added a real second handshake request (`set_permission_mode`) to every run of that suite, not just a hypothetical. When this section's handshake first landed, the differential's assertion failed with the Rust arm missing its `approvalRequest`/`sessionStateChanged(running)` events relative to the Swift arm's sequence -- an *ordering* symptom, not a missing-event one. Widening the script's margin (`SLEEP 200` -> `SLEEP 500`) made the failure stop reproducing, but a margin bump cannot by itself prove the fix was correct if the true defect were an ordering inversion produced inside the Rust scope's own single-threaded, sequential `handle_line` -> `publish` path (it structurally cannot reorder two lines processed back to back on one reader thread). A follow-up cargo-only test, `approval_request_and_session_state_changed_drain_in_publish_order`, reproduces the differential's exact two adjacent lines (a `can_use_tool` control_request immediately followed by `session_state_changed(running)`) through the real scope/`SubscriptionHub` pipeline with no Swift hop at all, and asserts the drained order matches publish order. It passes, repeatably -- **located, not just mitigated:** the Rust-side publish/hub pipeline preserves this ordering; whatever raced under `--filter Claude`'s full concurrent load was downstream of it (the Swift adapter's own event pump / `AsyncThrowingStream` hop, or plain wall-clock contention from the handshake's now-real round trip landing later under load), not a defect in this section's Rust-side change. The `SLEEP 500` margin is retained as a practical mitigation for that downstream/timing race, not documented as a root-cause fix.

**Not done in this session, named as follow-up:** the handshake's own control-response payload (`initialize`'s account/session-id/tool-list snapshot, `set_permission_mode`'s response) is not published as an event -- §15.4's `ClaudeRustBackedNativeSessionAdapter` doc comment already names `RuntimeInitStatus`'s tool list / MCP status map / `InitializeResponseSnapshot` as unreconstructed at this layer, and that gap is unchanged by this section. Observability parity (raw-event-log records for `session.initialized`/`session.permissionModeInitialized`, §10's inventory) is D-9/R9, owed and explicitly deferred below, unchanged.

D-9/R9's inventory-parity work below is the remaining P6-7 item; this section's closure was sequenced first because it was cargo/FFI-scoped work with no config-plumbing dependency on D-9's own new config fields, and because §15.4 named it as a hard blocker for the P6-8 real-CLI soak regardless of D-9's own status.
