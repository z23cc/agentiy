import AgentryCoreBridge
import Foundation

/// Where an executor publishes what happened. The router behind it owns ordering, the event log,
/// derived state, and fanout; the executor never sees sockets, cursors, or attachments (design §4.2).
/// `emit` is synchronous and may be called from any thread; calls from one executor must be made in
/// causal order because the order of `emit` calls is the order of log cursors.
package protocol AgentSessionExecutorSink: AnyObject, Sendable {
    func emit(_ body: AgentHostAgentSessionEventBodyV1)
}

/// One hosted session's execution half (design §4.2 `SessionExecutor`): it owns the provider session
/// and the run/turn reduction for exactly one session and reports through its sink. The router may
/// call any method from any thread, one call at a time per executor. Nothing here may assume the
/// router lives in the same process; P3 supplies the real provider-backed implementation.
package protocol AgentSessionExecutor: AnyObject, Sendable {
    var sessionID: String { get }

    /// Starts the provider session and, when `spec.initialMessage` is set, the first turn. Returns once
    /// the run has been accepted; `RunLifecycle` / `RuntimeEvent` records then arrive through the sink.
    func start(spec: AgentHostSessionSpecV1) throws -> AgentSessionExecutorRunReceipt

    /// Delivers a follow-up user message. The router has already recorded the `UserMessage` event.
    func steer(message: AgentHostUserMessageV1, delivery: AgentHostSteerDeliveryV1) throws -> AgentSessionExecutorRunReceipt

    /// Interrupts the running turn; `turnID` empty means "whatever is running".
    func interrupt(turnID: String) -> AgentHostInterruptOutcomeV1

    /// Delivers the winning answer of an interaction the router has already settled in the log.
    func deliverInteractionAnswer(interactionID: String, answer: AgentHostInteractionAnswerV1) throws

    /// Ends the session for good. Returns the terminal status the router records.
    func stop(reason: AgentHostStopReasonV1) -> AgentHostSessionStatusV1

    /// Host shutdown or idle exit: release provider resources (subprocesses included) and stop
    /// emitting. The host reaps whatever survives this call before it exits (design §7.3).
    func terminate()
}

package struct AgentSessionExecutorRunReceipt: Equatable {
    package var runID: String
    package var turnID: String

    package init(runID: String, turnID: String) {
        self.runID = runID
        self.turnID = turnID
    }
}

package enum AgentSessionExecutorError: Error, Equatable {
    case alreadyStarted
    case notStarted
    case terminated
    case unknownInteraction(String)
}

/// Creates executors for the router. P2 ships only the scripted stub; P3 registers provider-backed
/// executors here (design §8).
package protocol AgentSessionExecutorFactory: Sendable {
    func makeExecutor(
        sessionID: String,
        spec: AgentHostSessionSpecV1,
        sink: AgentSessionExecutorSink
    ) throws -> AgentSessionExecutor
}

// MARK: - Scripted stub executor (P2)

/// Deterministic behaviour of the stub: every turn streams `streamChunksPerTurn` content chunks and,
/// unless told otherwise, completes by itself. It spawns nothing.
package struct AgentSessionScriptedExecutorScript: Equatable {
    package var streamChunksPerTurn: Int
    package var chunkText: String
    /// When false the turn stays `running` until `interrupt` or `stop`.
    package var autoCompleteTurns: Bool
    /// When true each turn raises one approval interaction and completes only after it is answered.
    package var requestApprovalBeforeCompleting: Bool
    /// Pause between chunks; lets tests observe a running turn.
    package var chunkDelay: TimeInterval

    package init(
        streamChunksPerTurn: Int = 3,
        chunkText: String = "scripted-chunk ",
        autoCompleteTurns: Bool = true,
        requestApprovalBeforeCompleting: Bool = false,
        chunkDelay: TimeInterval = 0
    ) {
        self.streamChunksPerTurn = streamChunksPerTurn
        self.chunkText = chunkText
        self.autoCompleteTurns = autoCompleteTurns
        self.requestApprovalBeforeCompleting = requestApprovalBeforeCompleting
        self.chunkDelay = chunkDelay
    }
}

package struct AgentSessionScriptedExecutorFactory: AgentSessionExecutorFactory {
    package var script: AgentSessionScriptedExecutorScript

    package init(script: AgentSessionScriptedExecutorScript = AgentSessionScriptedExecutorScript()) {
        self.script = script
    }

    package func makeExecutor(
        sessionID: String,
        spec _: AgentHostSessionSpecV1,
        sink: AgentSessionExecutorSink
    ) throws -> AgentSessionExecutor {
        AgentSessionScriptedExecutor(sessionID: sessionID, script: script, sink: sink)
    }
}

/// The P2 test executor: emits scripted `RunLifecycle` / `RuntimeEvent` / `Interaction` records on a
/// private serial queue so the router observes the same asynchrony a provider subprocess produces.
package final class AgentSessionScriptedExecutor: AgentSessionExecutor, @unchecked Sendable {
    package let sessionID: String
    package let script: AgentSessionScriptedExecutorScript

    private let sink: AgentSessionExecutorSink
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var started = false
    private var terminated = false
    private var epoch: UInt64 = 0
    private var currentRun: AgentSessionExecutorRunReceipt?
    private var cancelledTurnIDs: Set<String> = []
    private var pendingInteraction: (id: String, run: AgentSessionExecutorRunReceipt)?

    package init(sessionID: String, script: AgentSessionScriptedExecutorScript, sink: AgentSessionExecutorSink) {
        self.sessionID = sessionID
        self.script = script
        self.sink = sink
        queue = DispatchQueue(label: "com.agentry.agent-host.scripted-executor.\(sessionID)")
    }

    package func start(spec: AgentHostSessionSpecV1) throws -> AgentSessionExecutorRunReceipt {
        try lock.withLock {
            guard !terminated else { throw AgentSessionExecutorError.terminated }
            guard !started else { throw AgentSessionExecutorError.alreadyStarted }
            started = true
        }
        sink.emit(.runtimeEvent(AgentHostRuntimeEventV1(
            runId: "",
            turnId: "",
            kind: .runtimeInit(AgentHostRuntimeInitStatusV1(
                providerSessionId: "scripted-\(sessionID)",
                tools: [],
                mcpServerStatuses: [],
                initializeResponse: nil
            ))
        )))
        guard let message = spec.initialMessage else {
            return AgentSessionExecutorRunReceipt(runID: "", turnID: "")
        }
        return beginTurn(message: message, transition: .initial)
    }

    package func steer(
        message: AgentHostUserMessageV1,
        delivery _: AgentHostSteerDeliveryV1
    ) throws -> AgentSessionExecutorRunReceipt {
        try lock.withLock {
            guard !terminated else { throw AgentSessionExecutorError.terminated }
            guard started else { throw AgentSessionExecutorError.notStarted }
        }
        return beginTurn(message: message, transition: .relatedFollowUp)
    }

    package func interrupt(turnID: String) -> AgentHostInterruptOutcomeV1 {
        let run: AgentSessionExecutorRunReceipt? = lock.withLock {
            guard let currentRun else { return nil }
            if !turnID.isEmpty, turnID != currentRun.turnID { return nil }
            cancelledTurnIDs.insert(currentRun.turnID)
            return currentRun
        }
        guard let run else { return .noTurnInFlight }
        queue.async { [self] in
            terminateRun(run, kind: .cancelled, outcome: .cancelled, failureReason: .cancelled)
        }
        return .acknowledged
    }

    package func deliverInteractionAnswer(interactionID: String, answer _: AgentHostInteractionAnswerV1) throws {
        let run: AgentSessionExecutorRunReceipt = try lock.withLock {
            guard let pendingInteraction, pendingInteraction.id == interactionID else {
                throw AgentSessionExecutorError.unknownInteraction(interactionID)
            }
            self.pendingInteraction = nil
            return pendingInteraction.run
        }
        queue.async { [self] in
            completeTurn(run)
        }
    }

    package func stop(reason _: AgentHostStopReasonV1) -> AgentHostSessionStatusV1 {
        let run: AgentSessionExecutorRunReceipt? = lock.withLock {
            terminated = true
            pendingInteraction = nil
            guard let currentRun else { return nil }
            cancelledTurnIDs.insert(currentRun.turnID)
            return currentRun
        }
        if let run {
            queue.sync { [self] in
                terminateRun(run, kind: .cancelled, outcome: .cancelled, failureReason: .cancelled)
            }
            return .cancelled
        }
        return .completed
    }

    package func terminate() {
        lock.withLock {
            terminated = true
            if let currentRun { cancelledTurnIDs.insert(currentRun.turnID) }
            currentRun = nil
            pendingInteraction = nil
        }
        queue.sync {}
    }

    // MARK: Turn script

    private func beginTurn(
        message: AgentHostUserMessageV1,
        transition: AgentHostEpochTransitionKindV1
    ) -> AgentSessionExecutorRunReceipt {
        let receipt = AgentSessionExecutorRunReceipt(runID: UUID().uuidString.lowercased(), turnID: UUID().uuidString.lowercased())
        let turnEpoch: AgentHostTurnEpochV1 = lock.withLock {
            epoch += 1
            currentRun = receipt
            return AgentHostTurnEpochV1(turnId: receipt.turnID, epoch: epoch, transition: transition)
        }
        queue.async { [self] in
            guard isLive(receipt) else { return }
            emitLifecycle(receipt, epoch: turnEpoch, kind: .started(AgentHostRunStartedV1(
                attemptId: UUID().uuidString.lowercased(),
                message: message
            )))
            emitLifecycle(receipt, epoch: turnEpoch, kind: .stageChanged(AgentHostRunStageChangedV1(
                stage: .running,
                retryIntent: .none
            )))
            for index in 0 ..< max(0, script.streamChunksPerTurn) {
                if script.chunkDelay > 0 { Thread.sleep(forTimeInterval: script.chunkDelay) }
                guard isLive(receipt) else { return }
                emitStream(receipt, itemType: "content", text: "\(script.chunkText)\(index)")
            }
            guard isLive(receipt) else { return }
            if script.requestApprovalBeforeCompleting {
                requestApproval(receipt, epoch: turnEpoch)
                return
            }
            if script.autoCompleteTurns {
                completeTurn(receipt)
            }
        }
        return receipt
    }

    private func isLive(_ receipt: AgentSessionExecutorRunReceipt) -> Bool {
        lock.withLock { !terminated && currentRun == receipt && !cancelledTurnIDs.contains(receipt.turnID) }
    }

    private func requestApproval(_ receipt: AgentSessionExecutorRunReceipt, epoch: AgentHostTurnEpochV1) {
        let interactionID = UUID().uuidString.lowercased()
        lock.withLock { pendingInteraction = (interactionID, receipt) }
        let request = AgentHostApprovalRequestV1(
            approvalId: interactionID,
            requestId: interactionID,
            requestIdSource: .unspecified,
            method: "scripted/approval",
            kind: .commandExecution,
            threadId: "",
            turnId: receipt.turnID,
            itemId: "",
            reason: "scripted approval",
            command: ["true"],
            cwd: "",
            grantRoot: "",
            proposedExecpolicyAmendmentJson: "",
            details: []
        )
        let pending = AgentHostPendingInteractionV1(
            interactionId: interactionID,
            interactionGeneration: Data(interactionID.utf8.prefix(8)),
            kind: .approval,
            responseType: .decision,
            title: "Scripted approval",
            prompt: "Approve the scripted command?",
            context: "",
            allowsMultiple: false,
            options: [],
            fields: [],
            details: [],
            approval: request,
            requestedAt: AgentSessionHostClock.rfc3339(),
            timeoutSeconds: 0,
            runId: receipt.runID,
            turnId: receipt.turnID
        )
        sink.emit(.interaction(AgentHostInteractionEventV1(kind: .requested(AgentHostInteractionRequestedV1(interaction: pending)))))
        emitLifecycle(receipt, epoch: epoch, kind: .stageChanged(AgentHostRunStageChangedV1(
            stage: .waitingForInteraction,
            retryIntent: .none
        )))
    }

    private func completeTurn(_ receipt: AgentSessionExecutorRunReceipt) {
        guard isLive(receipt) else { return }
        let text = (0 ..< max(0, script.streamChunksPerTurn)).map { "\(script.chunkText)\($0)" }.joined()
        emitStream(receipt, itemType: "final_content", text: text)
        sink.emit(.runtimeEvent(AgentHostRuntimeEventV1(
            runId: receipt.runID,
            turnId: receipt.turnID,
            kind: .turnCompleted(AgentHostTurnCompletedV1(turnId: receipt.turnID, stopReason: "end_turn"))
        )))
        terminateRun(receipt, kind: .completed, outcome: .completed, failureReason: .unspecified, assistantText: text)
    }

    private func terminateRun(
        _ receipt: AgentSessionExecutorRunReceipt,
        kind: AgentHostTerminationSignalKindV1,
        outcome: AgentHostTerminalOutcomeKindV1,
        failureReason: AgentHostFailureReasonV1,
        assistantText: String? = nil
    ) {
        let shouldEmit: Bool = lock.withLock {
            guard currentRun == receipt else { return false }
            currentRun = nil
            cancelledTurnIDs.remove(receipt.turnID)
            return true
        }
        guard shouldEmit else { return }
        sink.emit(.runLifecycle(AgentHostRunLifecycleEventV1(
            runId: receipt.runID,
            epoch: nil,
            kind: .terminated(AgentHostRunTerminatedV1(
                outcome: AgentHostTerminalOutcomeV1(kind: outcome, assistantText: assistantText, failureReason: failureReason),
                signal: AgentHostTerminationSignalV1(kind: kind, assistantText: assistantText, failureReason: failureReason)
            ))
        )))
    }

    private func emitLifecycle(
        _ receipt: AgentSessionExecutorRunReceipt,
        epoch: AgentHostTurnEpochV1,
        kind: AgentHostRunLifecycleEventKindV1
    ) {
        sink.emit(.runLifecycle(AgentHostRunLifecycleEventV1(runId: receipt.runID, epoch: epoch, kind: kind)))
    }

    private func emitStream(_ receipt: AgentSessionExecutorRunReceipt, itemType: String, text: String) {
        sink.emit(.runtimeEvent(AgentHostRuntimeEventV1(
            runId: receipt.runID,
            turnId: receipt.turnID,
            kind: .stream(AgentHostStreamResultV1(
                itemType: itemType,
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
        )))
    }
}
