import Foundation
import RepoPromptDomainRuntime

// MARK: - Client seam (ADR-0011, design §6)

/// Client-facing seam between Agent Mode presentation and Agent Mode execution.
///
/// `AgentModeViewModel` and the MCP tool surfaces are clients of this protocol; they never
/// touch provider controllers, transports, or run-lifecycle reducers directly. The GUI
/// production conformer is `HostAgentSessionConnection`. `InProcessAgentSessionConnection`
/// is tests-only. The host carries the same vocabulary over a socket without any client
/// change (design §4.2 "拓扑透明不变量"): a client must not be able to tell which topology
/// it is talking to.
///
/// Every mutating command carries an `operationID` so a client retry after an uncertain
/// outcome is idempotent (design §5.4). Commands are addressed by the persistent Agent
/// session ID except `start`, whose spec names the tab that will host the new session.
///
/// Result types mirror the frozen wire contract (`agent_host_v1.proto`
/// `CommandResponse.result`): `start` ↔ `SessionStarted`, `steer` ↔ `Steered`,
/// `interrupt` ↔ `InterruptResult`, `respond` ↔ `InteractionResponded`, `stop` ↔ `Stopped`,
/// `attach` ↔ `AttachResult`. Every settlement is observable twice, exactly like the wire:
/// as the returned value and as the `commandSettled` event carrying the same payload.
protocol AgentSessionConnection: Actor {
    /// Subscribes to a session and returns its current snapshot plus the cursor to resume from.
    /// `resume` is the last cursor the client observed; the connection replays what it can and
    /// reports the replay fidelity in the result.
    func attach(sessionID: UUID, resume: AgentSessionCursor?) async throws -> AgentSessionAttachResult
    /// Unsubscribes from a session. Detaching never stops execution.
    func detach(sessionID: UUID) async
    /// Starts a run. Mirrors `SessionStarted`: the persistent session ID the run is bound to
    /// plus the provider send outcome for the initial message.
    func start(_ spec: AgentSessionStartSpec, operationID: UUID) async throws -> AgentSessionStartResult
    /// Sends a follow-up message into a live session. Mirrors `Steered`.
    func steer(sessionID: UUID, message: AgentSessionUserMessage, operationID: UUID) async throws -> AgentSessionSteerResult
    /// Cancels the current run while keeping the session and its provider handle alive.
    /// Mirrors `InterruptResult`.
    func interrupt(sessionID: UUID, reason: AgentSessionInterruptReason, operationID: UUID) async throws -> AgentSessionInterruptResult
    /// Answers a pending interaction (approval, question, elicitation, hook review).
    /// Mirrors `InteractionResponded`.
    func respond(sessionID: UUID, interactionID: UUID, answer: AgentInteractionAnswer, operationID: UUID) async throws -> AgentSessionRespondResult
    /// Cancels any run and releases the session's provider process. The persisted session
    /// survives. Mirrors `Stopped`.
    func stop(sessionID: UUID, reason: AgentSessionStopReason, operationID: UUID) async throws -> AgentSessionStopResult
    /// Ordered event feed for every attached session plus command lifecycle notifications.
    var events: AsyncStream<AgentSessionConnectionEvent> { get }
    /// Unsubscribes every attached session. Detaching never stops execution (GUI quit).
    func detachAll() async
    /// Asks the host to checkpoint every session before a binary replacement. In-process
    /// connections report success because there is no host to replace.
    func prepareHostUpdate() async throws -> AgentSessionPrepareUpdateResult
    /// Lists host-owned sessions (design §5.4 `list_sessions`). Presentation uses this
    /// to show attachable sessions that are not open in this window.
    func listSessions(includeTerminal: Bool, workspaceID: UUID?) async throws -> [AgentSessionListedSummary]
}

extension AgentSessionConnection {
    /// `stop` with the wire default reason (`STOP_REASON_USER_REQUESTED`).
    func stop(sessionID: UUID, operationID: UUID) async throws -> AgentSessionStopResult {
        try await stop(sessionID: sessionID, reason: .userRequested, operationID: operationID)
    }
}

/// Result of `prepareHostUpdate`. `allCheckpointed == false` means the host must not be
/// replaced or stopped (design §4.4).
struct AgentSessionPrepareUpdateResult: Equatable {
    let allCheckpointed: Bool
    let detail: String
}

/// Presentation-safe host session row (design §5.4 `list_sessions`). No wire types.
struct AgentSessionListedSummary: Equatable, Identifiable {
    var id: UUID {
        sessionID
    }

    let sessionID: UUID
    let workspaceID: UUID?
    let sessionName: String
    let runState: AgentSessionRunState
    let attachedClientCount: Int
    let lastCursor: UInt64
    let generation: Data
    let statusText: String
}

// MARK: - Cursor and replay

/// Opaque replay position (design §5.5).
///
/// `generation` identifies one execution lineage; it changes whenever the host or the
/// in-process execution state behind a session is recreated, at which point earlier
/// `deliveryCursor` values are meaningless and the client must resnapshot. Clients never
/// interpret the bytes; they only hand the cursor back on `attach`.
struct AgentSessionCursor: Hashable, Codable {
    let generation: Data
    let deliveryCursor: UInt64

    /// True when `other` was minted by the same generation, so `deliveryCursor`
    /// values are comparable.
    func sharesGeneration(with other: AgentSessionCursor) -> Bool {
        generation == other.generation
    }
}

/// How faithfully `attach(resume:)` could replay what happened since the supplied cursor.
enum AgentSessionReplayFidelity: String, Equatable {
    /// Every event after the resume cursor was replayed.
    case complete
    /// Some events after the resume cursor are gone; the snapshot is authoritative.
    case partial
    /// The resume cursor belongs to another generation or replay is not supported; the
    /// snapshot is the only truth.
    case unavailable
}

/// Presentation-facing state of one session, sufficient to rebuild a client cache.
///
/// The transcript projection is carried as source `AgentChatItem`s; the client owns the
/// derived projections (`AgentTabSession` today).
struct AgentSessionSnapshot: Equatable {
    enum PendingInteraction: Equatable {
        case approval(UUID)
        case askUser(UUID)
        case userInput(UUID)
        case mcpElicitation(UUID)
        case codexHookReview(UUID)
        case permissions(UUID)
    }

    let tabID: UUID
    let sessionID: UUID?
    let provider: AgentProviderKind
    let modelRaw: String
    let runState: AgentSessionRunState
    let runID: UUID?
    let providerSessionID: String?
    let items: [AgentChatItem]
    let pendingInteraction: PendingInteraction?
}

/// Mirrors `AttachResult`.
struct AgentSessionAttachResult {
    let snapshot: AgentSessionSnapshot
    let cursor: AgentSessionCursor
    let replay: AgentSessionReplayFidelity
}

// MARK: - Commands

/// User-authored message for `start` and `steer`. Mirrors `UserMessage`.
///
/// `messageID` is minted by the client (wire: `UserMessage.message_id`) so the optimistic
/// transcript bubble and the execution-side record share one identity. `draftText` is the
/// raw composer text the client wants restored if the send is refused; it is not on the
/// wire — the in-process executor stores it in provider steering queues today, and P3 keeps
/// the restore client-side by reacting to a refused `sendOutcome`.
struct AgentSessionUserMessage: Equatable {
    let messageID: UUID
    let text: String
    let attachments: [AgentImageAttachment]
    let taggedFileAttachments: [AgentTaggedFileAttachment]
    let draftText: String?
    /// In-process only: Codex steer-ack attempt the client already opened. The wire has
    /// no equivalent — the host owns acknowledgement — so `HostAgentSessionConnection`
    /// ignores it.
    let codexAttemptID: UUID?

    init(
        messageID: UUID = UUID(),
        text: String,
        attachments: [AgentImageAttachment] = [],
        taggedFileAttachments: [AgentTaggedFileAttachment] = [],
        draftText: String? = nil,
        codexAttemptID: UUID? = nil
    ) {
        self.messageID = messageID
        self.text = text
        self.attachments = attachments
        self.taggedFileAttachments = taggedFileAttachments
        self.draftText = draftText
        self.codexAttemptID = codexAttemptID
    }
}

/// Execution-side context a client threads through `start` unchanged.
///
/// The in-process executor hands the client a submission context when a Codex send may be
/// durably queued and expects it back on the resulting `start`; presentation stores the
/// reference but never inspects it. The wire has no equivalent — the host owns queueing —
/// so `HostAgentSessionConnection` ignores it.
protocol AgentSessionStartExecutionContext {}

extension AgentTabSession.CodexFallbackSubmissionContext: AgentSessionStartExecutionContext {}

/// Everything the connection needs to start a run.
///
/// P1 note: in-process execution is still tab-addressed, so the spec names the tab whose
/// presentation cache will host the session. `resumeSessionID` continues a persisted session
/// in that tab; `nil` starts a fresh one. Provider/model overrides are optional so the
/// tab's current selection remains authoritative when they are omitted.
///
/// Host-only fields (`workspaceID`, `sessionName`, `worktreeID`, `credentialEnvelopeID`,
/// `resumeProviderSessionID`) are ignored by the in-process executor. `executionContext`
/// is ignored by `HostAgentSessionConnection`.
struct AgentSessionStartSpec {
    let tabID: UUID
    let resumeSessionID: UUID?
    let message: AgentSessionUserMessage
    let provider: AgentProviderKind?
    let modelRaw: String?
    let executionContext: (any AgentSessionStartExecutionContext)?
    let workspaceID: UUID?
    let sessionName: String?
    let worktreeID: String?
    let credentialEnvelopeID: String?
    let resumeProviderSessionID: String?

    init(
        tabID: UUID,
        resumeSessionID: UUID? = nil,
        message: AgentSessionUserMessage,
        provider: AgentProviderKind? = nil,
        modelRaw: String? = nil,
        executionContext: (any AgentSessionStartExecutionContext)? = nil,
        workspaceID: UUID? = nil,
        sessionName: String? = nil,
        worktreeID: String? = nil,
        credentialEnvelopeID: String? = nil,
        resumeProviderSessionID: String? = nil
    ) {
        self.tabID = tabID
        self.resumeSessionID = resumeSessionID
        self.message = message
        self.provider = provider
        self.modelRaw = modelRaw
        self.executionContext = executionContext
        self.workspaceID = workspaceID
        self.sessionName = sessionName
        self.worktreeID = worktreeID
        self.credentialEnvelopeID = credentialEnvelopeID
        self.resumeProviderSessionID = resumeProviderSessionID
    }

    func withHostLaunchOverrides(worktreeID: String?, credentialEnvelopeID: String?) -> AgentSessionStartSpec {
        AgentSessionStartSpec(
            tabID: tabID,
            resumeSessionID: resumeSessionID,
            message: message,
            provider: provider,
            modelRaw: modelRaw,
            executionContext: executionContext,
            workspaceID: workspaceID,
            sessionName: sessionName,
            worktreeID: worktreeID,
            credentialEnvelopeID: credentialEnvelopeID,
            resumeProviderSessionID: resumeProviderSessionID
        )
    }
}

/// Why a client interrupts a run. Mirrors `Interrupt.reason` and, for the in-process
/// executor, selects the cancellation intent and settlement point of the wrapped stack.
enum AgentSessionInterruptReason: String, Equatable {
    /// The user stopped the run; settles at terminal publication.
    case userRequested
    /// A newer steer supersedes the in-flight turn; settles at terminal publication.
    case supersededBySteer
    /// The session's execution location (worktree/cwd) is changing; queued undelivered
    /// work is restored rather than replayed. Settles at terminal publication.
    case executionLocationChange
    /// The hosting runtime is shutting down; settles only after the exactly-once
    /// attempt/provider teardown finished.
    case runtimeShutdown
    /// The client is about to destroy provider-owned infrastructure; settles only after
    /// the exactly-once attempt/provider teardown finished.
    case clientTeardown
}

/// Mirrors `StopReason`.
enum AgentSessionStopReason: String, Equatable {
    case userRequested
    case workspaceClosing
    case executionLocationChange
    case hostPolicy
}

/// Client answer to a pending interaction. Each case maps onto one existing
/// interaction vocabulary; nothing new is introduced here.
enum AgentInteractionAnswer: Equatable {
    case approval(AgentApprovalDecision)
    case askUser(draftsByQuestionID: [String: AgentAskUserDraft])
    /// Mirrors `InteractionAnswer.skipped` for an ask-user prompt.
    case skipAskUser
    case userInput(AgentRequestUserInputResponse)
    case mcpElicitation(AgentMCPElicitationResponse)
    case codexHookReview(AgentCodexHookReviewDecision)
    case permissions(AgentApprovalDecision)
}

enum AgentSessionConnectionError: Error, Equatable {
    /// No attached or live session with this ID.
    case sessionNotFound(UUID)
    /// The `operationID` was already used for a different command payload.
    case operationConflict(UUID)
    /// The in-process execution stack is not installed (composition-root wiring error).
    case executorUnavailable
    /// The answer kind does not match any pending interaction of the session.
    case interactionNotPending(UUID)
    /// The executor rejected the command; `message` is presentation-ready.
    case commandRejected(String)
    /// The socket dropped between accept and settle, or the host returned `uncertain`.
    /// Clients re-attach and read the log; they must not retry blindly.
    case uncertain(operationID: UUID, detail: String)
}

// MARK: - Command results (mirrors of `CommandResponse.result`)

/// Provider-neutral outcome of handing a user message to the provider. Mirrors the
/// `SessionStarted.send_outcome` / `Steered.send_outcome` vocabulary; the in-process
/// executor maps the provider coordinators' native send outcomes onto it losslessly.
enum AgentSessionSendOutcome: Equatable {
    /// Accepted for delivery; the provider's acknowledgement (or failure) arrives as run
    /// events. Providers without a synchronous acknowledgement settle here.
    case accepted
    /// The provider acknowledged the message synchronously.
    case sent
    /// Durably queued behind the active turn; `queueID` identifies the queue entry.
    case queuedForNextTurn(queueID: UUID)
    /// Refused before it reached the provider.
    case rejectedBeforeDispatch(reason: String)
    /// The target changed between acceptance and dispatch.
    case staleTarget(reason: String)
    /// Cancelled before dispatch.
    case cancelled
    /// The provider refused or failed the send.
    case failed(reason: String)

    /// True when the message reached the provider or a durable queue.
    var didSend: Bool {
        switch self {
        case .accepted, .sent, .queuedForNextTurn: true
        case .rejectedBeforeDispatch, .staleTarget, .cancelled, .failed: false
        }
    }
}

/// Mirrors `SessionStarted`.
struct AgentSessionStartResult: Equatable {
    let sessionID: UUID
    let sendOutcome: AgentSessionSendOutcome
    /// Cursor to resume from after the start; mirrors `SessionStarted.generation/next_cursor`.
    let cursor: AgentSessionCursor
}

/// Mirrors `Steered`.
struct AgentSessionSteerResult: Equatable {
    let sessionID: UUID
    let messageID: UUID
    let sendOutcome: AgentSessionSendOutcome
    /// Cursor at which the steer was recorded; mirrors `Steered.recorded_cursor`.
    let recordedCursor: AgentSessionCursor
}

/// Mirrors `InterruptResult.Outcome`.
enum AgentSessionInterruptOutcome: String, Equatable {
    case acknowledged
    case noTurnInFlight
    case staleGeneration
    case timedOut
    case failed
}

/// Mirrors `InterruptResult`.
struct AgentSessionInterruptResult: Equatable {
    let sessionID: UUID
    let outcome: AgentSessionInterruptOutcome
    let detail: String?
}

/// Mirrors `InteractionResponded.Disposition`.
enum AgentInteractionResponseDisposition: String, Equatable {
    case accepted
    case superseded
    case staleGeneration
    case unknownInteraction
    case expired
}

/// Mirrors `InteractionResponded`.
struct AgentSessionRespondResult: Equatable {
    let sessionID: UUID
    let interactionID: UUID
    let disposition: AgentInteractionResponseDisposition
}

/// Mirrors `Stopped`.
struct AgentSessionStopResult: Equatable {
    let sessionID: UUID
    /// Run state after the stop settled; mirrors `Stopped.status`.
    let status: AgentSessionRunState
}

// MARK: - Events

/// Settlement of one command as published on `events`. Mirrors the `CommandResponse.result`
/// oneof: one payload case per command plus `CommandRejected`.
enum AgentSessionCommandOutcome: Equatable {
    case started(AgentSessionStartResult)
    case steered(AgentSessionSteerResult)
    case interrupted(AgentSessionInterruptResult)
    case interactionResponded(AgentSessionRespondResult)
    case stopped(AgentSessionStopResult)
    case rejected(AgentSessionConnectionError)

    var sessionID: UUID? {
        switch self {
        case let .started(result): result.sessionID
        case let .steered(result): result.sessionID
        case let .interrupted(result): result.sessionID
        case let .interactionResponded(result): result.sessionID
        case let .stopped(result): result.sessionID
        case .rejected: nil
        }
    }
}

/// Everything a client can observe through the seam (design §5.5).
///
/// Runtime payloads reuse the provider-neutral `NativeAgentRuntimeEvent` DTOs and the
/// typed `DomainAgentRunTerminalOutcome` termination; the seam does not invent a
/// parallel vocabulary. Every session-scoped event carries the cursor a client should
/// persist so a later `attach(resume:)` can continue from it.
enum AgentSessionConnectionEvent {
    case attached(sessionID: UUID, cursor: AgentSessionCursor)
    case detached(sessionID: UUID)
    case commandAccepted(sessionID: UUID?, operationID: UUID, cursor: AgentSessionCursor?)
    case commandSettled(sessionID: UUID?, operationID: UUID, outcome: AgentSessionCommandOutcome, cursor: AgentSessionCursor?)
    case runtime(sessionID: UUID, event: NativeAgentRuntimeEvent, cursor: AgentSessionCursor)
    case runTerminated(sessionID: UUID, outcome: DomainAgentRunTerminalOutcome, cursor: AgentSessionCursor)
    /// The generation behind `sessionID` changed; cached cursors are stale and the client
    /// must `attach` again to obtain a fresh snapshot.
    case resnapshotRequired(sessionID: UUID)

    var sessionID: UUID? {
        switch self {
        case let .attached(sessionID, _),
             let .detached(sessionID),
             let .runtime(sessionID, _, _),
             let .runTerminated(sessionID, _, _),
             let .resnapshotRequired(sessionID):
            sessionID
        case let .commandAccepted(sessionID, _, _),
             let .commandSettled(sessionID, _, _, _):
            sessionID
        }
    }

    var operationID: UUID? {
        switch self {
        case let .commandAccepted(_, operationID, _),
             let .commandSettled(_, operationID, _, _):
            operationID
        case .attached, .detached, .runtime, .runTerminated, .resnapshotRequired:
            nil
        }
    }

    /// Cursor carried by session-scoped events; `nil` for detach/resnapshot and for
    /// command events that are not yet bound to a session.
    var cursor: AgentSessionCursor? {
        switch self {
        case let .attached(_, cursor),
             let .runtime(_, _, cursor),
             let .runTerminated(_, _, cursor):
            cursor
        case let .commandAccepted(_, _, cursor),
             let .commandSettled(_, _, _, cursor):
            cursor
        case .detached, .resnapshotRequired:
            nil
        }
    }
}

// MARK: - Client cache attachment slot

/// Marker for execution-side state a connection parks alongside a client presentation
/// cache. Presentation code stores the reference but never inspects it; only the
/// connection implementation that created it may downcast.
protocol AgentSessionConnectionAttachment: AnyObject {}
