import AgentryCoreBridge
import Foundation
import XCTest

// ADR-0011 P6 leftover differential harness: Swift oracle copies of the leftover
// `CodexNativeSessionController` file-change + bash running-update reducers vs the
// Rust twin behind `CoreAgentProviderCodexLifecycle`. Any disagreement is a Rust
// bug (fix in Rust). Never change product Swift from this file. Compare JSON as
// parsed objects (product `jsonString` is pretty-printed; Rust emits compact
// serde JSON). Fixtures stay BMP/ASCII because Swift `count` is graphemes.

enum P6LifecycleDifferentialConfiguration {
    static let defaultSeed: UInt64 = 0xD6E7_5EED_0000_0006

    static var seed: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["AGENTRY_P6_LIFECYCLE_DIFFERENTIAL_SEED"],
           let value = UInt64(raw)
        {
            return value
        }
        return defaultSeed
    }

    static var scale: Int {
        if let raw = ProcessInfo.processInfo.environment["AGENTRY_P6_LIFECYCLE_DIFFERENTIAL_SCALE"],
           let value = Int(raw), value > 0
        {
            return value
        }
        return 1
    }
}

enum P6LifecycleJSON {
    static func object(_ raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    static func canonical(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(value),
              let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8)
        else {
            return raw
        }
        return text
    }

    static func equal(_ lhs: String?, _ rhs: String?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        return canonical(lhs) == canonical(rhs)
    }
}

// MARK: - Oracle (copy of leftover CodexNativeSessionController reducers)

enum P6LifecycleOracle {
    struct Event: Equatable {
        var kind: String
        var name: String
        var invocationID: String?
        var argsJSON: String?
        var resultJSON: String?
        var isError: Bool?
        var dedupKey: String
    }

    struct StreamState {
        var itemID: String
        var invocationID: String?
        var argsJSON: String?
        var latestResultJSON: String?
        var accumulatedOutput: String
        var status: String
    }

    struct RunningUpdate: Equatable {
        var invocationID: String?
        var processID: String?
        var appendedOutput: String?
        var sealsAssistantBoundary: Bool
    }

    struct BashItem: Equatable {
        var kind: String
        var toolName: String?
        var invocationID: String?
        var argsJSON: String?
        var resultJSON: String?
        var toolIsError: Bool?
    }

    final class State {
        var byItem: [String: StreamState] = [:]
        var terminalItemIDs: Set<String> = []

        func reset() {
            byItem.removeAll()
            terminalItemIDs.removeAll()
        }

        func applyFileChange(method: String, paramsJSON: String) -> Event? {
            let lower = method.lowercased()
            if looksLikeFileChangeDelta(lower) {
                return applyOutputDelta(paramsJSON: paramsJSON)
            }
            return applyLifecycle(method: method, paramsJSON: paramsJSON)
        }

        func applyLifecycle(method: String, paramsJSON: String) -> Event? {
            let lower = method.lowercased()
            let isStarted = lower == "item/started"
            let isCompleted = lower == "item/completed"
            guard isStarted || isCompleted else { return nil }
            guard let params = P6LifecycleJSON.object(paramsJSON) else { return nil }
            guard let candidate = toolItemCandidates(params).first(where: candidateLooksLikeFileChange)
            else { return nil }
            guard let itemID = stringValue(candidate, ["id", "itemId", "item_id"]) else { return nil }
            let invocationID = stableInvocationID(itemID)
            let existing = byItem[itemID]
            let argsJSON = applyPatchArgsJSON(candidate) ?? existing?.argsJSON
            let statusInfo = normalizedApplyPatchStatus(
                stringValue(candidate, ["status"]),
                isCompletedLifecycle: isCompleted
            )
            let resultJSON = applyPatchResultJSON(candidate, accumulated: existing?.accumulatedOutput)

            if isStarted {
                terminalItemIDs.remove(itemID)
                byItem[itemID] = StreamState(
                    itemID: itemID,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    latestResultJSON: resultJSON,
                    accumulatedOutput: existing?.accumulatedOutput ?? "",
                    status: statusInfo.status
                )
                return Event(
                    kind: "call",
                    name: "apply_patch",
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    resultJSON: nil,
                    isError: nil,
                    dedupKey: toolDedupKey(itemID: itemID, toolName: "apply_patch", argsJSON: argsJSON, resultJSON: nil)
                )
            }

            byItem.removeValue(forKey: itemID)
            terminalItemIDs.insert(itemID)
            return Event(
                kind: "result",
                name: "apply_patch",
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: statusInfo.isError,
                dedupKey: toolDedupKey(
                    itemID: itemID,
                    toolName: "apply_patch",
                    argsJSON: argsJSON,
                    resultJSON: resultJSON
                )
            )
        }

        func applyOutputDelta(paramsJSON: String) -> Event? {
            guard let params = P6LifecycleJSON.object(paramsJSON) else { return nil }
            let message = (params["msg"] as? [String: Any]) ?? params
            guard let itemID = stringValue(message, ["itemId", "item_id", "id"]) else { return nil }
            guard !terminalItemIDs.contains(itemID) else { return nil }
            let invocationID = stableInvocationID(itemID)
            let rawOutput = rawStringValue(message, ["delta", "output", "text", "message", "content"])
            let sanitizedOutput: String? = rawOutput.map { output in
                let sanitized = P6LifecycleSanitizer.sanitize(output)
                if sanitized.isEmpty,
                   !output.isEmpty,
                   output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return output
                }
                return sanitized
            }

            var state = byItem[itemID] ?? StreamState(
                itemID: itemID,
                invocationID: invocationID,
                argsJSON: nil,
                latestResultJSON: nil,
                accumulatedOutput: "",
                status: "running"
            )
            if let sanitizedOutput {
                state.accumulatedOutput = cappedRunningOutput(state.accumulatedOutput + sanitizedOutput)
            }
            state.status = "running"
            let resultJSON = applyPatchRunningResultJSON(
                raw: state.latestResultJSON,
                accumulated: state.accumulatedOutput,
                status: state.status
            )
            state.latestResultJSON = resultJSON
            byItem[itemID] = state
            return Event(
                kind: "result",
                name: "apply_patch",
                invocationID: state.invocationID,
                argsJSON: state.argsJSON,
                resultJSON: resultJSON,
                isError: false,
                dedupKey: toolDedupKey(
                    itemID: itemID,
                    toolName: "apply_patch",
                    argsJSON: state.argsJSON,
                    resultJSON: resultJSON
                )
            )
        }

        func canonicalObject() -> [String: Any] {
            let items: [[String: Any]] = byItem.keys.sorted().map { id in
                let state = byItem[id]!
                return [
                    "itemId": id,
                    "invocationId": state.invocationID as Any,
                    "args": state.argsJSON as Any,
                    "status": state.status,
                    "accumulatedChars": state.accumulatedOutput.count,
                ]
            }
            return [
                "fileChangeItems": items,
                "terminalItemIDs": terminalItemIDs.sorted(),
            ]
        }
    }

    static func parseRunningUpdate(method: String, paramsJSON: String) -> RunningUpdate? {
        guard let params = P6LifecycleJSON.object(paramsJSON) else { return nil }
        let lower = method.lowercased()
        if lower.contains("exec_command_output_delta")
            || lower.contains("commandexecution/outputdelta")
            || lower.contains("command_execution/output_delta")
        {
            return parseExecOutputDelta(params)
        }
        return parseRunningUpdateFromNotification(params)
    }

    static func applyRunningUpdate(_ update: RunningUpdate, to items: inout [BashItem]) -> Bool {
        var index = RunningIndex(items: items)
        guard let target = runningTarget(update: update, items: items, index: &index) else {
            return false
        }
        var item = items[target]
        if item.toolIsError != true, commandExecutionResultIndicatesTerminal(item.resultJSON) {
            return false
        }
        var didChange = false
        if item.kind == "toolCall" {
            item.kind = "toolResult"
            didChange = true
        }
        if item.toolIsError != false {
            item.toolIsError = false
            didChange = true
        }
        if shouldPatchRunningPayload(
            raw: item.resultJSON,
            processID: update.processID,
            appendOutput: update.appendedOutput
        ) {
            let patched = withRunningStatus(
                raw: item.resultJSON,
                processID: update.processID,
                appendOutput: update.appendedOutput
            )
            if patched != item.resultJSON {
                item.resultJSON = patched
                didChange = true
            }
        }
        guard didChange else { return false }
        items[target] = item
        return true
    }

    static func withRunningStatus(raw: String?, processID: String?, appendOutput: String?) -> String {
        var object = P6LifecycleJSON.object(raw) ?? [:]
        seedAggregatedOutputIfNeeded(&object, raw: raw)
        markRunning(&object, processID: processID)
        mergeAggregatedOutput(&object, appendOutput: appendOutput)
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: []),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return raw ?? "{\"type\":\"commandExecution\",\"status\":\"running\"}"
    }
}

// MARK: - File-change helpers

private func looksLikeFileChangeDelta(_ method: String) -> Bool {
    method.contains("file_change/output")
        || method.contains("filechange/output")
        || method.contains("item_file_change_output")
        || method.contains("file_change_output")
}

private func candidateLooksLikeFileChange(_ candidate: [String: Any]) -> Bool {
    let typeRaw = stringValue(candidate, ["type", "itemType", "item_type"])?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    return typeRaw.contains("filechange") || typeRaw.contains("file_change")
}

private func toolItemCandidates(_ params: [String: Any]) -> [[String: Any]] {
    var candidates: [[String: Any]] = []
    if let item = params["item"] as? [String: Any] {
        candidates.append(item)
    }
    for key in ["msg", "payload", "event"] {
        if let envelope = params[key] as? [String: Any] {
            if let item = envelope["item"] as? [String: Any] {
                candidates.append(item)
            }
            candidates.append(envelope)
        }
    }
    candidates.append(params)
    return candidates
}

private func applyPatchArgsJSON(_ candidate: [String: Any]) -> String? {
    let changes = applyPatchChangePayloads(candidate)
    var seen: Set<String> = []
    let paths = changes.compactMap { payload -> String? in
        guard let path = payload["path"] as? String, !path.isEmpty else { return nil }
        guard seen.insert(path).inserted else { return nil }
        return path
    }
    guard !paths.isEmpty || !changes.isEmpty else { return nil }
    var payload: [String: Any] = ["change_count": max(changes.count, paths.count)]
    if let first = paths.first {
        payload["path"] = first
    }
    if paths.count > 1 {
        payload["paths"] = paths
    }
    return jsonString(payload)
}

private func applyPatchResultJSON(_ candidate: [String: Any], accumulated: String?) -> String {
    let changes = applyPatchChangePayloads(candidate)
    let status = normalizedApplyPatchStatus(stringValue(candidate, ["status"]), isCompletedLifecycle: false)
    var payload: [String: Any] = [
        "status": status.status,
        "changes": changes,
        "change_count": changes.count,
        "summary_only": false,
    ]
    if let accumulated, !accumulated.isEmpty {
        payload["output"] = accumulated
    }
    return jsonString(payload) ?? "{\"status\":\"\(status.status)\",\"changes\":[],\"change_count\":0}"
}

private func applyPatchRunningResultJSON(raw: String?, accumulated: String, status: String) -> String {
    var object = P6LifecycleJSON.object(raw) ?? [:]
    object["status"] = status
    object["summary_only"] = false
    if object["changes"] == nil {
        object["changes"] = []
    }
    if object["change_count"] == nil {
        let changes = object["changes"] as? [Any] ?? []
        object["change_count"] = changes.count
    }
    if !accumulated.isEmpty {
        object["output"] = accumulated
    }
    return jsonString(object) ?? "{\"status\":\"running\",\"changes\":[],\"change_count\":0}"
}

private func applyPatchChangePayloads(_ candidate: [String: Any]) -> [[String: Any]] {
    let rawChanges = candidate["changes"] as? [Any] ?? []
    return rawChanges.compactMap { rawChange in
        guard let change = rawChange as? [String: Any],
              let path = stringValue(change, ["path"]),
              let diff = rawStringValue(change, ["diff"])
        else {
            return nil
        }
        let kindInfo = normalizedApplyPatchKind(change["kind"])
        var payload: [String: Any] = [
            "path": path,
            "kind": kindInfo.kind,
            "diff": diff,
        ]
        if let movePath = kindInfo.movePath, !movePath.isEmpty {
            payload["move_path"] = movePath
        }
        return payload
    }
}

private func normalizedApplyPatchKind(_ raw: Any?) -> (kind: String, movePath: String?) {
    if let raw = raw as? String {
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), nil)
    }
    if let object = raw as? [String: Any] {
        let kind = dictString(object, "type")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "update"
        let movePath = dictString(object, "movePath") ?? dictString(object, "move_path")
        return (kind, movePath)
    }
    return ("update", nil)
}

private func normalizedApplyPatchStatus(
    _ rawStatus: String?,
    isCompletedLifecycle: Bool
) -> (status: String, isError: Bool?) {
    let normalized = rawStatus?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    switch normalized {
    case "inprogress", "in_progress", "running", "pending":
        return isCompletedLifecycle ? ("success", false) : ("running", false)
    case "completed", "success", "succeeded", "ok":
        return ("success", false)
    case "declined", "rejected":
        return ("declined", true)
    case "cancelled", "canceled", "interrupted", "stopped", "terminated":
        return ("cancelled", true)
    case "failed", "failure", "error":
        return ("failed", true)
    default:
        if isCompletedLifecycle, normalized.isEmpty {
            return ("success", false)
        }
        return (normalized.isEmpty ? "running" : normalized, nil)
    }
}

private func jsonString(_ value: Any) -> String? {
    if let value = value as? String { return value }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
          let json = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return json
}

private func toolDedupKey(itemID: String?, toolName: String, argsJSON: String?, resultJSON: String?) -> String {
    if let itemID = itemID?.trimmingCharacters(in: .whitespacesAndNewlines), !itemID.isEmpty {
        return itemID
    }
    return "\(toolName)|\(argsJSON ?? "")|\(resultJSON ?? "")"
}

private func stringValue(_ candidate: [String: Any], _ keys: [String]) -> String? {
    for key in keys {
        if let value = candidate[key] as? String, !value.isEmpty {
            return value
        }
    }
    return nil
}

private func rawStringValue(_ candidate: [String: Any], _ keys: [String]) -> String? {
    for key in keys {
        if let value = candidate[key] as? String {
            return value
        }
    }
    return nil
}

private func dictString(_ object: [String: Any], _ key: String) -> String? {
    if let value = object[key] as? String { return value }
    if let value = object[key] as? NSNumber { return value.stringValue }
    return nil
}

private func dictBool(_ object: [String: Any], _ key: String) -> Bool? {
    object[key] as? Bool
}

private func dictInt(_ object: [String: Any], _ key: String) -> Int? {
    if let value = object[key] as? Int { return value }
    if let value = object[key] as? NSNumber { return value.intValue }
    if let value = object[key] as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}

// MARK: - Running update

private let commandExecutionOutputKeys = [
    "formattedOutput", "formatted_output", "aggregatedOutput", "aggregated_output",
    "output", "stdout", "stderr", "combinedOutput", "combined_output",
    "recentOutput", "recent_output", "text", "message", "content", "result", "log", "logs",
]
private let runningStatusWords: Set<String> = [
    "running", "in_progress", "inprogress", "in-progress", "pending",
]
private let terminalStatusWords: Set<String> = [
    "completed", "complete", "success", "succeeded", "ok", "failed", "failure", "error",
    "cancelled", "canceled", "terminated", "stopped", "done", "exited", "finished",
    "timeout", "timed_out", "killed",
]
private let maxRunningAggregatedOutputCharacters = 24_000
private let runningOutputTruncationMarker = "\n...(output truncated)...\n"

private struct RunningIndex {
    var invocation: [String: Int] = [:]
    var process: [String: Int] = [:]

    init(items: [P6LifecycleOracle.BashItem]) {
        for (index, item) in items.enumerated() {
            guard normalizedExternalToolName(item.toolName) == "bash" else { continue }
            if let id = item.invocationID {
                invocation[id] = index
            }
            if let pid = commandExecutionProcessID(item.resultJSON) {
                process[pid] = index
            }
        }
    }
}

private func runningTarget(
    update: P6LifecycleOracle.RunningUpdate,
    items: [P6LifecycleOracle.BashItem],
    index: inout RunningIndex
) -> Int? {
    if let id = update.invocationID, let at = index.invocation[id], isBashItem(items, at) {
        return at
    }
    if let pid = update.processID, let at = index.process[pid], isBashItem(items, at) {
        return at
    }
    let requiresCorrelation = update.invocationID != nil || (update.processID?.isEmpty == false)
    if let unique = uniqueFallback(items, requireCorrelationForError: requiresCorrelation) {
        return unique
    }
    if let id = update.invocationID,
       let at = items.lastIndex(where: {
           $0.invocationID == id && normalizedExternalToolName($0.toolName) == "bash"
       })
    {
        return at
    }
    if let pid = update.processID,
       let at = items.lastIndex(where: {
           normalizedExternalToolName($0.toolName) == "bash"
               && commandExecutionProcessID($0.resultJSON) == pid
       })
    {
        return at
    }
    return uniqueFallback(items, requireCorrelationForError: requiresCorrelation)
}

private func isBashItem(_ items: [P6LifecycleOracle.BashItem], _ index: Int) -> Bool {
    items.indices.contains(index) && normalizedExternalToolName(items[index].toolName) == "bash"
}

private func uniqueFallback(
    _ items: [P6LifecycleOracle.BashItem],
    requireCorrelationForError: Bool
) -> Int? {
    var resolved: Int?
    for (index, item) in items.enumerated() {
        guard isFallbackEligible(item, requireCorrelationForError: requireCorrelationForError) else {
            continue
        }
        if resolved != nil { return nil }
        resolved = index
    }
    return resolved
}

private func isFallbackEligible(
    _ item: P6LifecycleOracle.BashItem,
    requireCorrelationForError: Bool
) -> Bool {
    guard normalizedExternalToolName(item.toolName) == "bash" else { return false }
    if item.toolIsError == true {
        return requireCorrelationForError
    }
    return !commandExecutionResultIndicatesTerminal(item.resultJSON)
}

private func shouldPatchRunningPayload(raw: String?, processID: String?, appendOutput: String?) -> Bool {
    if appendOutput?.isEmpty == false { return true }
    guard let object = P6LifecycleJSON.object(raw) else { return true }
    let type = (dictString(object, "type") ?? "").lowercased()
    if !type.contains("command") { return true }
    if object["process_id"] != nil
        || object["aggregated_output"] != nil
        || object["exit_code"] != nil
        || object["code"] != nil
    {
        return true
    }
    if commandExecutionExitCode(object) != nil { return true }
    let existing = dictString(object, "processId") ?? dictString(object, "process_id")
    if let processID = processID?.trimmingCharacters(in: .whitespacesAndNewlines),
       !processID.isEmpty,
       processID != existing
    {
        return true
    }
    guard let status = commandExecutionStatusWord(object) else { return true }
    return !runningStatusWords.contains(status)
}

private func commandExecutionResultIndicatesTerminal(_ raw: String?) -> Bool {
    guard let object = P6LifecycleJSON.object(raw) else { return false }
    let exit = commandExecutionExitCode(object)
    let processID = commandExecutionProcessID(raw)
    if let exit {
        if exit >= 0 { return true }
        return processID == nil
    }
    if let status = commandExecutionStatusWord(object) {
        if runningStatusWords.contains(status) { return false }
        if terminalStatusWords.contains(status) { return true }
    }
    if dictBool(object, "success") == true || dictBool(object, "ok") == true {
        return true
    }
    if let error = dictString(object, "error")?.trimmingCharacters(in: .whitespacesAndNewlines),
       !error.isEmpty
    {
        return true
    }
    return false
}

private func commandExecutionExitCode(_ object: [String: Any]) -> Int? {
    dictInt(object, "exitCode") ?? dictInt(object, "exit_code") ?? dictInt(object, "code")
}

private func commandExecutionStatusWord(_ object: [String: Any]) -> String? {
    dictString(object, "status")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func commandExecutionProcessID(_ raw: String?) -> String? {
    guard let object = P6LifecycleJSON.object(raw) else { return nil }
    for key in ["processId", "process_id"] {
        if let value = dictString(object, key), !value.isEmpty {
            return value
        }
    }
    return nil
}

private func parseExecOutputDelta(_ params: [String: Any]) -> P6LifecycleOracle.RunningUpdate? {
    let message = (params["msg"] as? [String: Any]) ?? params
    guard let callID = stringValue(message, ["call_id", "callId", "itemId", "item_id", "id"]) else {
        return nil
    }
    let chunk = stringValue(message, ["chunk"])
    let output = decodeExecChunk(chunk)
        ?? stringValue(message, ["delta", "output", "text", "message", "content"])
    let sanitized = output.map(P6LifecycleSanitizer.sanitize)
    let trimmed = sanitized?.trimmingCharacters(in: .whitespacesAndNewlines)
    return P6LifecycleOracle.RunningUpdate(
        invocationID: stableInvocationID(callID),
        processID: stringValue(message, ["process_id", "processId"]),
        appendedOutput: (trimmed?.isEmpty == false) ? sanitized : nil,
        sealsAssistantBoundary: false
    )
}

private func parseRunningUpdateFromNotification(_ params: [String: Any]) -> P6LifecycleOracle.RunningUpdate? {
    var invocationID: String?
    var processID: String?
    var output: String?
    var seals = false
    for candidate in toolItemCandidates(params) {
        if invocationID == nil {
            invocationID = stableInvocationID(stringValue(candidate, [
                "itemId", "item_id", "callId", "call_id", "id", "invocationId", "invocation_id",
            ]))
        }
        if processID == nil {
            processID = stringValue(candidate, ["processId", "process_id"])
        }
        if output == nil {
            for key in commandExecutionOutputKeys {
                if let raw = stringValue(candidate, [key]) {
                    let sanitized = P6LifecycleSanitizer.sanitize(raw)
                    if !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        output = sanitized
                        break
                    }
                }
            }
        }
        if let stdin = rawStringValue(candidate, ["stdin"]), stdin.isEmpty {
            seals = true
        }
    }
    guard invocationID != nil || (processID?.isEmpty == false) else { return nil }
    return P6LifecycleOracle.RunningUpdate(
        invocationID: invocationID,
        processID: processID,
        appendedOutput: output,
        sealsAssistantBoundary: seals
    )
}

private func decodeExecChunk(_ chunk: String?) -> String? {
    guard let chunk, !chunk.isEmpty else { return nil }
    let filtered = chunk.unicodeScalars.filter { scalar in
        scalar != " " && scalar != "\n" && scalar != "\t" && scalar != "\r" && scalar != "="
    }
    let compact = String(String.UnicodeScalarView(filtered))
    guard let data = Data(base64Encoded: compact),
          let decoded = String(data: data, encoding: .utf8),
          !decoded.isEmpty
    else {
        return chunk
    }
    return decoded
}

private func seedAggregatedOutputIfNeeded(_ object: inout [String: Any], raw: String?) {
    guard object.isEmpty,
          let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty
    else { return }
    let sanitized = P6LifecycleSanitizer.sanitize(raw)
    guard !sanitized.isEmpty else { return }
    object["aggregatedOutput"] = sanitized
}

private func markRunning(_ object: inout [String: Any], processID: String?) {
    let type = dictString(object, "type")
    object["type"] = (type?.isEmpty == false) ? (object["type"] ?? "commandExecution") : "commandExecution"
    object["status"] = "running"
    object.removeValue(forKey: "exitCode")
    object.removeValue(forKey: "exit_code")
    object.removeValue(forKey: "code")
    let existing = dictString(object, "processId") ?? dictString(object, "process_id")
    if let processID = processID?.trimmingCharacters(in: .whitespacesAndNewlines), !processID.isEmpty {
        object["processId"] = processID
    } else if let existing, !existing.isEmpty {
        object["processId"] = existing
    }
    object.removeValue(forKey: "process_id")
}

private func mergeAggregatedOutput(_ object: inout [String: Any], appendOutput: String?) {
    var aggregated = dictString(object, "aggregatedOutput")
        ?? dictString(object, "aggregated_output")
        ?? outputText(object)
        ?? ""
    if !aggregated.isEmpty, containsControlOrEscape(aggregated) {
        aggregated = P6LifecycleSanitizer.sanitize(aggregated)
    }
    if let appendOutput, !appendOutput.isEmpty {
        let sanitized = P6LifecycleSanitizer.sanitize(appendOutput)
        if !sanitized.isEmpty {
            aggregated += sanitized
        }
    }
    if !aggregated.isEmpty {
        object["aggregatedOutput"] = cappedRunningOutput(aggregated)
    }
    object.removeValue(forKey: "aggregated_output")
}

private func outputText(_ object: [String: Any]) -> String? {
    for key in commandExecutionOutputKeys {
        if let value = dictString(object, key) {
            let sanitized = P6LifecycleSanitizer.sanitize(value)
            if !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return sanitized
            }
        }
    }
    return nil
}

private func containsControlOrEscape(_ text: String) -> Bool {
    text.contains("\u{001B}") || text.contains("\u{009B}") || text.contains("\u{0008}") || text.contains("\r")
}

private func cappedRunningOutput(_ raw: String) -> String {
    guard raw.count > maxRunningAggregatedOutputCharacters else { return raw }
    let suffix = String(raw.suffix(maxRunningAggregatedOutputCharacters))
    if suffix.hasPrefix(runningOutputTruncationMarker) {
        return suffix
    }
    return runningOutputTruncationMarker + suffix
}

private func normalizedExternalToolName(_ raw: String?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    let lowered = trimmed.lowercased()
    let suffix = lowered.split(separator: ".").last.map(String.init) ?? lowered
    switch suffix {
    case "local_shell", "shell", "unified_exec", "exec_command", "run_shell_command", "bash":
        return "bash"
    case "filechange", "file_change", "apply_patch":
        return "apply_patch"
    default:
        return suffix
    }
}

func stableInvocationID(_ rawItemID: String?) -> String? {
    guard let raw = rawItemID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    if let parsed = UUID(uuidString: raw) {
        return parsed.uuidString
    }
    var hashA: UInt64 = 0xCBF2_9CE4_8422_2325
    var hashB: UInt64 = 0x9E37_79B9_7F4A_7C15
    for (index, byte) in raw.utf8.enumerated() {
        hashA ^= UInt64(byte)
        hashA &*= 0x100_0000_01B3
        hashB ^= UInt64(byte) &+ UInt64(index & 0xFF)
        hashB &*= 0x100_0000_01B3
        hashB = (hashB << 13) | (hashB >> 51)
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(16)
    bytes.append(contentsOf: withUnsafeBytes(of: hashA.bigEndian) { Array($0) })
    bytes.append(contentsOf: withUnsafeBytes(of: hashB.bigEndian) { Array($0) })
    guard bytes.count == 16 else { return nil }
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )).uuidString
}

// MARK: - Sanitizer (copy of CommandExecutionOutputSanitizer)

enum P6LifecycleSanitizer {
    private static let escapeChar = "\u{001B}"
    private static let csiRegex = try! NSRegularExpression(
        pattern: #"(?:\x1B\[|\x9B)[0-?]*[ -/]*[@-~]"#,
        options: []
    )
    private static let oscRegex = try! NSRegularExpression(
        pattern: #"\x1B\][\s\S]*?(?:\x07|\x1B\\)"#,
        options: []
    )
    private static let dcsRegex = try! NSRegularExpression(
        pattern: #"\x1B[P^_X][\s\S]*?\x1B\\"#,
        options: []
    )
    private static let singleEscapeRegex = try! NSRegularExpression(
        pattern: #"\x1B[@-Z\\-_]"#,
        options: []
    )

    static func sanitize(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        guard requiresSanitization(raw) else { return raw }
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = stripEscapeSequences(text)
        text = applyBackspaces(text)
        text = applyCarriageReturnOverwrite(text)
        return stripUnwantedControlScalars(text)
    }

    private static func stripEscapeSequences(_ input: String) -> String {
        guard input.contains(escapeChar) || input.contains("\u{009B}") else { return input }
        let fullRange = NSRange(input.startIndex ..< input.endIndex, in: input)
        var output = csiRegex.stringByReplacingMatches(in: input, options: [], range: fullRange, withTemplate: "")
        let rangeAfterCSI = NSRange(output.startIndex ..< output.endIndex, in: output)
        output = oscRegex.stringByReplacingMatches(in: output, options: [], range: rangeAfterCSI, withTemplate: "")
        let rangeAfterOSC = NSRange(output.startIndex ..< output.endIndex, in: output)
        output = dcsRegex.stringByReplacingMatches(in: output, options: [], range: rangeAfterOSC, withTemplate: "")
        let rangeAfterDCS = NSRange(output.startIndex ..< output.endIndex, in: output)
        return singleEscapeRegex.stringByReplacingMatches(in: output, options: [], range: rangeAfterDCS, withTemplate: "")
    }

    private static func requiresSanitization(_ input: String) -> Bool {
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x1B, 0x9B, 0x08, 0x0D:
                return true
            case 0x00 ... 0x1F where scalar.value != 0x09 && scalar.value != 0x0A:
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func applyBackspaces(_ input: String) -> String {
        guard input.contains("\u{0008}") else { return input }
        var output = ""
        output.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            if scalar.value == 0x08 {
                if !output.isEmpty {
                    output.removeLast()
                }
                continue
            }
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    private static func applyCarriageReturnOverwrite(_ input: String) -> String {
        guard input.contains("\r") else { return input }
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let rewritten = lines.map { line -> String in
            guard let segment = line.split(separator: "\r", omittingEmptySubsequences: false).last else {
                return ""
            }
            return String(segment)
        }
        return rewritten.joined(separator: "\n")
    }

    private static func stripUnwantedControlScalars(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x20 ... 0x10FFFF:
                output.unicodeScalars.append(scalar)
            default:
                continue
            }
        }
        return output
    }
}

// MARK: - Dual helpers

func p6LifecycleAssertEventEqual(
    _ rust: AgentProviderCodexLifecycleEventV1?,
    _ oracle: P6LifecycleOracle.Event?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if rust == nil && oracle == nil { return }
    guard let rust, let oracle else {
        XCTFail("event presence rust=\(rust != nil) oracle=\(oracle != nil)", file: file, line: line)
        return
    }
    XCTAssertEqual(rust.kind, oracle.kind, "kind", file: file, line: line)
    XCTAssertEqual(rust.name, oracle.name, "name", file: file, line: line)
    XCTAssertEqual(rust.invocationId, oracle.invocationID, "invocationId", file: file, line: line)
    XCTAssertTrue(P6LifecycleJSON.equal(rust.argsJson, oracle.argsJSON), "argsJSON", file: file, line: line)
    XCTAssertTrue(P6LifecycleJSON.equal(rust.resultJson, oracle.resultJSON), "resultJSON", file: file, line: line)
    XCTAssertEqual(rust.isError, oracle.isError, "isError", file: file, line: line)
    XCTAssertEqual(rust.dedupKey, oracle.dedupKey, "dedupKey", file: file, line: line)
}

func p6LifecycleAssertUpdateEqual(
    _ rust: AgentProviderCodexRunningUpdateV1?,
    _ oracle: P6LifecycleOracle.RunningUpdate?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if rust == nil && oracle == nil { return }
    guard let rust, let oracle else {
        XCTFail("update presence rust=\(rust != nil) oracle=\(oracle != nil)", file: file, line: line)
        return
    }
    XCTAssertEqual(rust.invocationId, oracle.invocationID, "invocationId", file: file, line: line)
    XCTAssertEqual(rust.processId, oracle.processID, "processId", file: file, line: line)
    XCTAssertEqual(rust.appendedOutput, oracle.appendedOutput, "appendedOutput", file: file, line: line)
    XCTAssertEqual(rust.sealsAssistantBoundary, oracle.sealsAssistantBoundary, "seals", file: file, line: line)
}

func p6LifecycleAssertItemsEqual(
    _ rust: [AgentProviderCodexBashItemV1],
    _ oracle: [P6LifecycleOracle.BashItem],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(rust.count, oracle.count, "item count", file: file, line: line)
    for (index, pair) in zip(rust, oracle).enumerated() {
        XCTAssertEqual(pair.0.kind, pair.1.kind, "item[\(index)].kind", file: file, line: line)
        XCTAssertEqual(pair.0.toolName, pair.1.toolName, "item[\(index)].toolName", file: file, line: line)
        XCTAssertEqual(pair.0.invocationId, pair.1.invocationID, "item[\(index)].invocationId", file: file, line: line)
        XCTAssertTrue(
            P6LifecycleJSON.equal(pair.0.argsJson, pair.1.argsJSON),
            "item[\(index)].argsJSON",
            file: file,
            line: line
        )
        XCTAssertTrue(
            P6LifecycleJSON.equal(pair.0.resultJson, pair.1.resultJSON),
            "item[\(index)].resultJSON",
            file: file,
            line: line
        )
        XCTAssertEqual(pair.0.toolIsError, pair.1.toolIsError, "item[\(index)].toolIsError", file: file, line: line)
    }
}

func p6LifecycleAssertCanonicalEqual(
    _ rustJSON: String,
    _ oracle: P6LifecycleOracle.State,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let rustObject = P6LifecycleJSON.object(rustJSON) else {
        XCTFail("rust canonical is not an object: \(rustJSON)", file: file, line: line)
        return
    }
    let rustItems = rustObject["fileChangeItems"] as? [[String: Any]] ?? []
    let oracleItems = oracle.canonicalObject()["fileChangeItems"] as? [[String: Any]] ?? []
    XCTAssertEqual(rustItems.count, oracleItems.count, "fileChangeItems count", file: file, line: line)
    for (index, pair) in zip(rustItems, oracleItems).enumerated() {
        XCTAssertEqual(pair.0["itemId"] as? String, pair.1["itemId"] as? String, "item[\(index)].itemId", file: file, line: line)
        XCTAssertEqual(pair.0["status"] as? String, pair.1["status"] as? String, "item[\(index)].status", file: file, line: line)
        XCTAssertEqual(
            pair.0["accumulatedChars"] as? Int ?? (pair.0["accumulatedChars"] as? NSNumber)?.intValue,
            pair.1["accumulatedChars"] as? Int,
            "item[\(index)].accumulatedChars",
            file: file,
            line: line
        )
        let rustInv = pair.0["invocationId"] as? String
        let oracleInv = pair.1["invocationId"] as? String
        XCTAssertEqual(rustInv, oracleInv, "item[\(index)].invocationId", file: file, line: line)
        XCTAssertTrue(
            P6LifecycleJSON.equal(pair.0["args"] as? String, pair.1["args"] as? String),
            "item[\(index)].args",
            file: file,
            line: line
        )
    }
    let rustTerminal = rustObject["terminalItemIds"] as? [String] ?? []
    let oracleTerminal = oracle.terminalItemIDs.sorted()
    XCTAssertEqual(rustTerminal, oracleTerminal, "terminalItemIds", file: file, line: line)
}

extension AgentProviderCodexBashItemV1 {
    var p6LifecycleOracle: P6LifecycleOracle.BashItem {
        P6LifecycleOracle.BashItem(
            kind: kind,
            toolName: toolName,
            invocationID: invocationId,
            argsJSON: argsJson,
            resultJSON: resultJson,
            toolIsError: toolIsError
        )
    }
}

extension P6LifecycleOracle.BashItem {
    var rustRecord: AgentProviderCodexBashItemV1 {
        AgentProviderCodexBashItemV1(
            kind: kind,
            toolName: toolName,
            invocationId: invocationID,
            argsJson: argsJSON,
            resultJson: resultJSON,
            toolIsError: toolIsError
        )
    }
}

func p6LifecycleEncode(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let text = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }
    return text
}

extension P6LifecycleOracle.RunningUpdate {
    var rustRecord: AgentProviderCodexRunningUpdateV1 {
        AgentProviderCodexRunningUpdateV1(
            invocationId: invocationID,
            processId: processID,
            appendedOutput: appendedOutput,
            sealsAssistantBoundary: sealsAssistantBoundary
        )
    }
}
