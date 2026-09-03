import AgentryCoreBridge
import Foundation

/// One-shot conversion of a GUI `AgentSession-*.json` into an event log (design §7.2).
/// Writes `Imported{legacyDigest}` plus metadata and user/assistant messages. The `.json`
/// file is left in place (P4 stops writing it).
package enum AgentSessionLegacyJSONImport {
    package struct Report: Equatable {
        package var importedSessionIDs: [String] = []
        package var skipped: [AgentSessionRouterRecoveryReport.Skipped] = []
    }

    /// Minimal decode of the GUI session JSON. DomainRuntime must not import app `AgentSession`.
    struct LegacyDocument: Decodable {
        var id: UUID
        var name: String?
        var workspaceID: UUID?
        var agentKind: String?
        var agentModel: String?
        var providerSessionID: String?
        var lastRunState: String?
        var items: [LegacyItem]?

        struct LegacyItem: Decodable {
            var id: UUID?
            var kind: String?
            var text: String?
        }
    }

    package static func importMissingLogs(
        directories: [URL],
        codec: CoreAgentHostProtocol,
        now: String = AgentSessionHostClock.rfc3339()
    ) -> Report {
        var report = Report()
        let fileManager = FileManager.default
        for directory in directories {
            let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files.sorted() where file.hasPrefix("AgentSession-") && file.hasSuffix(".json") {
                let sessionID = String(file.dropFirst("AgentSession-".count).dropLast(".json".count)).lowercased()
                guard UUID(uuidString: sessionID) != nil else {
                    report.skipped.append(.init(path: directory.appendingPathComponent(file).path, reason: "filename is not a UUID"))
                    continue
                }
                let names: AgentSessionLogFileNamesV1
                do {
                    names = try codec.sessionLogFileNames(sessionID: sessionID)
                } catch {
                    report.skipped.append(.init(path: directory.appendingPathComponent(file).path, reason: String(describing: error)))
                    continue
                }
                let eventsURL = directory.appendingPathComponent(names.events)
                if fileManager.fileExists(atPath: eventsURL.path) { continue }
                let jsonURL = directory.appendingPathComponent(file)
                do {
                    try importFile(jsonURL: jsonURL, sessionID: sessionID, directory: directory, codec: codec, now: now)
                    report.importedSessionIDs.append(sessionID)
                } catch {
                    report.skipped.append(.init(path: jsonURL.path, reason: String(describing: error)))
                }
            }
        }
        return report
    }

    private static func importFile(
        jsonURL: URL,
        sessionID: String,
        directory: URL,
        codec: CoreAgentHostProtocol,
        now: String
    ) throws {
        let bytes = try Data(contentsOf: jsonURL)
        let document = try JSONDecoder().decode(LegacyDocument.self, from: bytes)
        let names = try codec.sessionLogFileNames(sessionID: sessionID)
        let log = try CoreAgentSessionLog.open(
            path: directory.appendingPathComponent(names.events).path,
            sessionID: sessionID,
            options: AgentSessionLogOpenOptionsV1(createIfMissing: true, loadSnapshot: false)
        )
        defer { try? log.close() }

        let items = document.items ?? []
        var importedAssistant = false
        let digest = DomainContentDigest.sha256(bytes)
        _ = try log.append(
            AgentHostAgentSessionEventV1(
                recordedAt: now,
                body: .imported(AgentHostImportedV1(
                    legacyDigest: digest,
                    legacyFormat: "json",
                    importedItemCount: UInt64(items.count),
                    importedAt: now
                ))
            ),
            durability: .sync
        )

        var summary = AgentSessionHostMutableSummary(sessionId: sessionID)
        summary.workspaceId = document.workspaceID?.uuidString.lowercased()
            ?? workspaceID(fromSessionDirectory: directory)
        summary.sessionName = document.name ?? ""
        summary.providerId = document.agentKind ?? ""
        summary.agentId = document.agentKind ?? ""
        summary.modelId = document.agentModel ?? ""
        summary.providerSessionId = document.providerSessionID ?? ""
        summary.status = status(from: document.lastRunState)
        summary.statusText = "imported from AgentSession JSON"
        summary.createdAt = now
        summary.updatedAt = now
        summary.transcriptItemCount = UInt64(items.count)
        if let lastAssistant = items.last(where: { $0.kind == "assistant" }) {
            summary.latestAssistantPreview = String((lastAssistant.text ?? "").prefix(200))
        }

        _ = try log.append(
            AgentHostAgentSessionEventV1(
                recordedAt: now,
                body: .sessionMetadataChanged(AgentHostSessionMetadataChangedV1(summary: summary.value))
            ),
            durability: .sync
        )

        for item in items {
            let text = item.text ?? ""
            guard !text.isEmpty else { continue }
            switch item.kind {
            case "user":
                _ = try log.append(
                    AgentHostAgentSessionEventV1(
                        recordedAt: now,
                        body: .userMessage(AgentHostUserMessageV1(
                            messageId: (item.id ?? UUID()).uuidString.lowercased(),
                            text: text,
                            attachments: [],
                            createdAt: now
                        ))
                    ),
                    durability: .deferred
                )
            case "assistant":
                importedAssistant = true
                _ = try log.append(
                    AgentHostAgentSessionEventV1(
                        recordedAt: now,
                        body: .runtimeEvent(AgentHostRuntimeEventV1(
                            runId: "",
                            turnId: "",
                            kind: .stream(AgentHostStreamResultV1(
                                itemType: "final_content",
                                text: text,
                                reasoning: nil,
                                promptTokens: nil,
                                completionTokens: nil,
                                cost: nil,
                                toolName: nil,
                                toolArgs: nil,
                                toolOutput: nil,
                                toolInvocationId: nil,
                                toolResultJson: nil,
                                toolArgsJson: nil,
                                toolIsError: nil,
                                providerSessionId: nil,
                                stopReason: nil,
                                modelContextWindow: nil,
                                contextUsedTokens: nil,
                                contentMessageId: nil
                            ))
                        ))
                    ),
                    durability: .deferred
                )
            default:
                continue
            }
        }
        if importedAssistant {
            _ = try log.append(
                AgentHostAgentSessionEventV1(
                    recordedAt: now,
                    body: .runtimeEvent(AgentHostRuntimeEventV1(
                        runId: "",
                        turnId: "legacy-import",
                        kind: .turnCompleted(AgentHostTurnCompletedV1(turnId: "legacy-import", stopReason: "imported"))
                    ))
                ),
                durability: .sync
            )
        }
        try log.sync()
    }

    private static func workspaceID(fromSessionDirectory directory: URL) -> String {
        let folder = directory.deletingLastPathComponent().lastPathComponent
        if let parsed = DomainWorkspaceStoragePath.parse(folder) {
            return parsed.id.uuidString.lowercased()
        }
        return folder
    }

    private static func status(from raw: String?) -> AgentHostSessionStatusV1 {
        switch raw {
        case "running": .running
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        default: .waitingForInput
        }
    }
}
