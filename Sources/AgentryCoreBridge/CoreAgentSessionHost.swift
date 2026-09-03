import AgentryUniFFIRaw
import Foundation

// ADR-0011 P2 (design §11 "编解码归属"): the bridge surface over the agent-host-v1 codec and the
// session event log. Swift never parses protobuf or log bytes; the typed `AgentHost…V1` /
// `AgentSessionLog…V1` records generated from `agent_host_v1.proto` are the vocabulary both the
// host shell and the Swift clients speak, so they are re-exported here by name rather than mirrored
// a second time (precedent: `CoreInventoryDiagnosticsV1`). The two Rust objects are wrapped so that
// callers outside the bridge never import `AgentryUniFFIRaw` and every failure arrives as a
// `CoreBridgeError`.

/// Build identity of the Rust core linked into this process. The agent-host handshake compares it
/// in both directions (design §5.3); a mismatch fails closed because both sides must share one codec.
public enum CoreBuildIdentity {
    public static let buildFingerprint: String = AgentryCoreBindingIdentity.buildFingerprint
    public static let abiEpoch: UInt32 = AgentryCoreBindingIdentity.abiEpoch
}

// MARK: - Typed record re-exports (generated vocabulary of agent_host_v1.proto)

public typealias AgentHostAgentSessionEventBodyV1 = AgentryUniFFIRaw.AgentHostAgentSessionEventBodyV1
public typealias AgentHostAgentSessionEventV1 = AgentryUniFFIRaw.AgentHostAgentSessionEventV1
public typealias AgentHostAgentSessionSnapshotV1 = AgentryUniFFIRaw.AgentHostAgentSessionSnapshotV1
public typealias AgentHostApprovalCancelledV1 = AgentryUniFFIRaw.AgentHostApprovalCancelledV1
public typealias AgentHostApprovalDecisionKindV1 = AgentryUniFFIRaw.AgentHostApprovalDecisionKindV1
public typealias AgentHostApprovalDecisionV1 = AgentryUniFFIRaw.AgentHostApprovalDecisionV1
public typealias AgentHostApprovalKindV1 = AgentryUniFFIRaw.AgentHostApprovalKindV1
public typealias AgentHostApprovalPolicyV1 = AgentryUniFFIRaw.AgentHostApprovalPolicyV1
public typealias AgentHostApprovalRequestIdSourceV1 = AgentryUniFFIRaw.AgentHostApprovalRequestIdSourceV1
public typealias AgentHostApprovalRequestV1 = AgentryUniFFIRaw.AgentHostApprovalRequestV1
public typealias AgentHostArtifactRefV1 = AgentryUniFFIRaw.AgentHostArtifactRefV1
public typealias AgentHostAttachReplayV1 = AgentryUniFFIRaw.AgentHostAttachReplayV1
public typealias AgentHostAttachResultV1 = AgentryUniFFIRaw.AgentHostAttachResultV1
public typealias AgentHostAttachV1 = AgentryUniFFIRaw.AgentHostAttachV1
public typealias AgentHostCapabilityV1 = AgentryUniFFIRaw.AgentHostCapabilityV1
public typealias AgentHostChoiceAnswerV1 = AgentryUniFFIRaw.AgentHostChoiceAnswerV1
public typealias AgentHostClientKindV1 = AgentryUniFFIRaw.AgentHostClientKindV1
public typealias AgentHostClientMessageBodyV1 = AgentryUniFFIRaw.AgentHostClientMessageBodyV1
public typealias AgentHostClientMessageV1 = AgentryUniFFIRaw.AgentHostClientMessageV1
public typealias AgentHostCommandAcceptedV1 = AgentryUniFFIRaw.AgentHostCommandAcceptedV1
public typealias AgentHostCommandRejectedV1 = AgentryUniFFIRaw.AgentHostCommandRejectedV1
public typealias AgentHostCommandRejectionReasonV1 = AgentryUniFFIRaw.AgentHostCommandRejectionReasonV1
public typealias AgentHostCommandRequestCommandV1 = AgentryUniFFIRaw.AgentHostCommandRequestCommandV1
public typealias AgentHostCommandRequestV1 = AgentryUniFFIRaw.AgentHostCommandRequestV1
public typealias AgentHostCommandResponseOutcomeV1 = AgentryUniFFIRaw.AgentHostCommandResponseOutcomeV1
public typealias AgentHostCommandResponseV1 = AgentryUniFFIRaw.AgentHostCommandResponseV1
public typealias AgentHostCommandResultCaseV1 = AgentryUniFFIRaw.AgentHostCommandResultCaseV1
public typealias AgentHostCommandResultV1 = AgentryUniFFIRaw.AgentHostCommandResultV1
public typealias AgentHostCommandSettledSettlementV1 = AgentryUniFFIRaw.AgentHostCommandSettledSettlementV1
public typealias AgentHostCommandSettledV1 = AgentryUniFFIRaw.AgentHostCommandSettledV1
public typealias AgentHostDetachV1 = AgentryUniFFIRaw.AgentHostDetachV1
public typealias AgentHostDetachedV1 = AgentryUniFFIRaw.AgentHostDetachedV1
public typealias AgentHostElicitationActionV1 = AgentryUniFFIRaw.AgentHostElicitationActionV1
public typealias AgentHostElicitationAnswerV1 = AgentryUniFFIRaw.AgentHostElicitationAnswerV1
public typealias AgentHostEpochTransitionKindV1 = AgentryUniFFIRaw.AgentHostEpochTransitionKindV1
public typealias AgentHostEventNotificationV1 = AgentryUniFFIRaw.AgentHostEventNotificationV1
public typealias AgentHostExecutableIdentityV1 = AgentryUniFFIRaw.AgentHostExecutableIdentityV1
public typealias AgentHostFailureReasonV1 = AgentryUniFFIRaw.AgentHostFailureReasonV1
public typealias AgentHostFieldAnswerV1 = AgentryUniFFIRaw.AgentHostFieldAnswerV1
public typealias AgentHostForkedFromV1 = AgentryUniFFIRaw.AgentHostForkedFromV1
public typealias AgentHostHandshakeRejectReasonV1 = AgentryUniFFIRaw.AgentHostHandshakeRejectReasonV1
public typealias AgentHostHandshakeRejectedV1 = AgentryUniFFIRaw.AgentHostHandshakeRejectedV1
public typealias AgentHostHelloV1 = AgentryUniFFIRaw.AgentHostHelloV1
public typealias AgentHostHostControlActionV1 = AgentryUniFFIRaw.AgentHostHostControlActionV1
public typealias AgentHostHostControlResultCaseV1 = AgentryUniFFIRaw.AgentHostHostControlResultCaseV1
public typealias AgentHostHostControlResultV1 = AgentryUniFFIRaw.AgentHostHostControlResultV1
public typealias AgentHostHostControlV1 = AgentryUniFFIRaw.AgentHostHostControlV1
public typealias AgentHostHostMessageBodyV1 = AgentryUniFFIRaw.AgentHostHostMessageBodyV1
public typealias AgentHostHostMessageV1 = AgentryUniFFIRaw.AgentHostHostMessageV1
public typealias AgentHostHostNoticeKindV1 = AgentryUniFFIRaw.AgentHostHostNoticeKindV1
public typealias AgentHostHostNoticeV1 = AgentryUniFFIRaw.AgentHostHostNoticeV1
public typealias AgentHostImportedV1 = AgentryUniFFIRaw.AgentHostImportedV1
public typealias AgentHostInteractionAnswerAnswerV1 = AgentryUniFFIRaw.AgentHostInteractionAnswerAnswerV1
public typealias AgentHostInteractionAnswerV1 = AgentryUniFFIRaw.AgentHostInteractionAnswerV1
public typealias AgentHostInteractionEventKindV1 = AgentryUniFFIRaw.AgentHostInteractionEventKindV1
public typealias AgentHostInteractionEventV1 = AgentryUniFFIRaw.AgentHostInteractionEventV1
public typealias AgentHostInteractionFieldV1 = AgentryUniFFIRaw.AgentHostInteractionFieldV1
public typealias AgentHostInteractionKindV1 = AgentryUniFFIRaw.AgentHostInteractionKindV1
public typealias AgentHostInteractionOptionV1 = AgentryUniFFIRaw.AgentHostInteractionOptionV1
public typealias AgentHostInteractionRequestedV1 = AgentryUniFFIRaw.AgentHostInteractionRequestedV1
public typealias AgentHostInteractionRespondedV1 = AgentryUniFFIRaw.AgentHostInteractionRespondedV1
public typealias AgentHostInteractionResponseDispositionV1 = AgentryUniFFIRaw.AgentHostInteractionResponseDispositionV1
public typealias AgentHostInteractionResponseTypeV1 = AgentryUniFFIRaw.AgentHostInteractionResponseTypeV1
public typealias AgentHostInteractionSettledV1 = AgentryUniFFIRaw.AgentHostInteractionSettledV1
public typealias AgentHostInteractionSettlementV1 = AgentryUniFFIRaw.AgentHostInteractionSettlementV1
public typealias AgentHostInterruptOutcomeV1 = AgentryUniFFIRaw.AgentHostInterruptOutcomeV1
public typealias AgentHostInterruptResultV1 = AgentryUniFFIRaw.AgentHostInterruptResultV1
public typealias AgentHostInterruptV1 = AgentryUniFFIRaw.AgentHostInterruptV1
public typealias AgentHostKeyValueV1 = AgentryUniFFIRaw.AgentHostKeyValueV1
public typealias AgentHostLifecycleStageV1 = AgentryUniFFIRaw.AgentHostLifecycleStageV1
public typealias AgentHostListSessionsV1 = AgentryUniFFIRaw.AgentHostListSessionsV1
public typealias AgentHostMutationKeyV1 = AgentryUniFFIRaw.AgentHostMutationKeyV1
public typealias AgentHostOperationConflictV1 = AgentryUniFFIRaw.AgentHostOperationConflictV1
public typealias AgentHostOperationUncertainV1 = AgentryUniFFIRaw.AgentHostOperationUncertainV1
public typealias AgentHostPendingInteractionV1 = AgentryUniFFIRaw.AgentHostPendingInteractionV1
public typealias AgentHostPermissionPolicyV1 = AgentryUniFFIRaw.AgentHostPermissionPolicyV1
public typealias AgentHostPrepareUpdateResultV1 = AgentryUniFFIRaw.AgentHostPrepareUpdateResultV1
public typealias AgentHostPrepareUpdateV1 = AgentryUniFFIRaw.AgentHostPrepareUpdateV1
public typealias AgentHostProtocolLimitsV1 = AgentryUniFFIRaw.AgentHostProtocolLimitsV1
public typealias AgentHostProviderSettingV1 = AgentryUniFFIRaw.AgentHostProviderSettingV1
public typealias AgentHostResnapshotReasonV1 = AgentryUniFFIRaw.AgentHostResnapshotReasonV1
public typealias AgentHostResnapshotRequiredV1 = AgentryUniFFIRaw.AgentHostResnapshotRequiredV1
public typealias AgentHostRespondInteractionV1 = AgentryUniFFIRaw.AgentHostRespondInteractionV1
public typealias AgentHostRetryIntentV1 = AgentryUniFFIRaw.AgentHostRetryIntentV1
public typealias AgentHostRunLifecycleEventKindV1 = AgentryUniFFIRaw.AgentHostRunLifecycleEventKindV1
public typealias AgentHostRunLifecycleEventV1 = AgentryUniFFIRaw.AgentHostRunLifecycleEventV1
public typealias AgentHostRunStageChangedV1 = AgentryUniFFIRaw.AgentHostRunStageChangedV1
public typealias AgentHostRunStartedV1 = AgentryUniFFIRaw.AgentHostRunStartedV1
public typealias AgentHostRunTerminatedV1 = AgentryUniFFIRaw.AgentHostRunTerminatedV1
public typealias AgentHostRuntimeErrorV1 = AgentryUniFFIRaw.AgentHostRuntimeErrorV1
public typealias AgentHostRuntimeEventKindV1 = AgentryUniFFIRaw.AgentHostRuntimeEventKindV1
public typealias AgentHostRuntimeEventV1 = AgentryUniFFIRaw.AgentHostRuntimeEventV1
public typealias AgentHostRuntimeInitStatusV1 = AgentryUniFFIRaw.AgentHostRuntimeInitStatusV1
public typealias AgentHostRuntimeInitializeResponseV1 = AgentryUniFFIRaw.AgentHostRuntimeInitializeResponseV1
public typealias AgentHostSessionCheckpointV1 = AgentryUniFFIRaw.AgentHostSessionCheckpointV1
public typealias AgentHostSessionListV1 = AgentryUniFFIRaw.AgentHostSessionListV1
public typealias AgentHostSessionMetadataChangedV1 = AgentryUniFFIRaw.AgentHostSessionMetadataChangedV1
public typealias AgentHostSessionSpecV1 = AgentryUniFFIRaw.AgentHostSessionSpecV1
public typealias AgentHostSessionStartedV1 = AgentryUniFFIRaw.AgentHostSessionStartedV1
public typealias AgentHostSessionStatusV1 = AgentryUniFFIRaw.AgentHostSessionStatusV1
public typealias AgentHostSessionSummaryV1 = AgentryUniFFIRaw.AgentHostSessionSummaryV1
public typealias AgentHostShutdownAcceptedV1 = AgentryUniFFIRaw.AgentHostShutdownAcceptedV1
public typealias AgentHostShutdownModeV1 = AgentryUniFFIRaw.AgentHostShutdownModeV1
public typealias AgentHostShutdownV1 = AgentryUniFFIRaw.AgentHostShutdownV1
public typealias AgentHostSnapshotBeginV1 = AgentryUniFFIRaw.AgentHostSnapshotBeginV1
public typealias AgentHostSnapshotChunkV1 = AgentryUniFFIRaw.AgentHostSnapshotChunkV1
public typealias AgentHostSnapshotEndV1 = AgentryUniFFIRaw.AgentHostSnapshotEndV1
public typealias AgentHostStartV1 = AgentryUniFFIRaw.AgentHostStartV1
public typealias AgentHostSteerDeliveryV1 = AgentryUniFFIRaw.AgentHostSteerDeliveryV1
public typealias AgentHostSteerV1 = AgentryUniFFIRaw.AgentHostSteerV1
public typealias AgentHostSteeredV1 = AgentryUniFFIRaw.AgentHostSteeredV1
public typealias AgentHostStopReasonV1 = AgentryUniFFIRaw.AgentHostStopReasonV1
public typealias AgentHostStopV1 = AgentryUniFFIRaw.AgentHostStopV1
public typealias AgentHostStoppedV1 = AgentryUniFFIRaw.AgentHostStoppedV1
public typealias AgentHostStreamResultV1 = AgentryUniFFIRaw.AgentHostStreamResultV1
public typealias AgentHostStructuredAnswerV1 = AgentryUniFFIRaw.AgentHostStructuredAnswerV1
public typealias AgentHostTerminalOutcomeKindV1 = AgentryUniFFIRaw.AgentHostTerminalOutcomeKindV1
public typealias AgentHostTerminalOutcomeV1 = AgentryUniFFIRaw.AgentHostTerminalOutcomeV1
public typealias AgentHostTerminationSignalKindV1 = AgentryUniFFIRaw.AgentHostTerminationSignalKindV1
public typealias AgentHostTerminationSignalV1 = AgentryUniFFIRaw.AgentHostTerminationSignalV1
public typealias AgentHostTextAnswerV1 = AgentryUniFFIRaw.AgentHostTextAnswerV1
public typealias AgentHostToolDispositionV1 = AgentryUniFFIRaw.AgentHostToolDispositionV1
public typealias AgentHostToolPreferenceV1 = AgentryUniFFIRaw.AgentHostToolPreferenceV1
public typealias AgentHostTranscriptEntryV1 = AgentryUniFFIRaw.AgentHostTranscriptEntryV1
public typealias AgentHostTranscriptRoleV1 = AgentryUniFFIRaw.AgentHostTranscriptRoleV1
public typealias AgentHostTurnCompletedV1 = AgentryUniFFIRaw.AgentHostTurnCompletedV1
public typealias AgentHostTurnEpochV1 = AgentryUniFFIRaw.AgentHostTurnEpochV1
public typealias AgentHostUserMessageV1 = AgentryUniFFIRaw.AgentHostUserMessageV1
public typealias AgentHostWelcomeV1 = AgentryUniFFIRaw.AgentHostWelcomeV1
public typealias AgentSessionLogCompactReceiptV1 = AgentryUniFFIRaw.AgentSessionLogCompactReceiptV1
public typealias AgentSessionLogDurabilityV1 = AgentryUniFFIRaw.AgentSessionLogDurabilityV1
public typealias AgentSessionLogEntryV1 = AgentryUniFFIRaw.AgentSessionLogEntryV1
public typealias AgentSessionLogFileNamesV1 = AgentryUniFFIRaw.AgentSessionLogFileNamesV1
public typealias AgentSessionLogOpenOptionsV1 = AgentryUniFFIRaw.AgentSessionLogOpenOptionsV1
public typealias AgentSessionLogOpenReportV1 = AgentryUniFFIRaw.AgentSessionLogOpenReportV1
public typealias AgentSessionLogReadBatchV1 = AgentryUniFFIRaw.AgentSessionLogReadBatchV1
public typealias AgentSessionLogSnapshotLoadV1 = AgentryUniFFIRaw.AgentSessionLogSnapshotLoadV1
public typealias AgentSessionLogStatusV1 = AgentryUniFFIRaw.AgentSessionLogStatusV1
public typealias AgentSessionLogTornTailReasonV1 = AgentryUniFFIRaw.AgentSessionLogTornTailReasonV1
public typealias AgentSessionLogTornTailV1 = AgentryUniFFIRaw.AgentSessionLogTornTailV1

// MARK: - Error mapping

enum CoreAgentSessionHostErrorMapping {
    static func map(_ error: Error) -> CoreBridgeError {
        guard let error = error as? AgentryUniFFIRaw.CoreError else {
            if let bridgeError = error as? CoreBridgeError { return bridgeError }
            return .transportFailure(String(describing: error))
        }
        return switch error {
        case .InvalidArgument: .invalidArgument
        case .InternalPanic: .runtimeInvalidated
        case let .AgentHostFrameMalformed(message): .agentHostFrameMalformed(message)
        case let .AgentHostFrameTooLarge(actual, maximum): .agentHostFrameTooLarge(actual: actual, maximum: maximum)
        case let .AgentSessionLogIo(operation, message): .agentSessionLogIo(operation: operation, message: message)
        case let .AgentSessionLogNotFound(path): .agentSessionLogNotFound(path: path)
        case let .AgentSessionLogInvalidFile(message): .agentSessionLogInvalidFile(message)
        case let .AgentSessionLogUnsupportedSchemaVersion(found, supported):
            .agentSessionLogUnsupportedSchemaVersion(found: found, supported: supported)
        case let .AgentSessionLogSessionMismatch(expected, found):
            .agentSessionLogSessionMismatch(expected: expected, found: found)
        case let .AgentSessionLogInvalidSessionId(value): .agentSessionLogInvalidSessionId(value)
        case let .AgentSessionLogRecordTooLarge(actual, maximum):
            .agentSessionLogRecordTooLarge(actual: actual, maximum: maximum)
        case let .AgentSessionLogCursorOutOfRange(cursor, nextCursor):
            .agentSessionLogCursorOutOfRange(cursor: cursor, nextCursor: nextCursor)
        case let .AgentSessionLogMalformedRecord(cursor, message):
            .agentSessionLogMalformedRecord(cursor: cursor, message: message)
        case let .AgentSessionLogSnapshotRejected(message): .agentSessionLogSnapshotRejected(message)
        case .AgentSessionLogClosed: .agentSessionLogClosed
        default: .transportFailure(String(describing: error))
        }
    }

    static func rethrow<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch {
            throw map(error)
        }
    }
}

// MARK: - Codec

/// Stateless agent-host-v1 codec (`AgentHostProtocolV1`). One per process is plenty; every call is a
/// bounded synchronous pure function of its input.
public final class CoreAgentHostProtocol: Sendable {
    private let raw: AgentHostProtocolV1

    public init() {
        raw = AgentHostProtocolV1()
    }

    /// The frozen v1 limits (protocol version, frame prefix, frame/chunk/snapshot caps, log schema).
    public func limits() throws -> AgentHostProtocolLimitsV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.limits() }
    }

    /// `AgentSession-<UUID>.events` / `.snapshot` file names for `sessionID` (any-case RFC 4122 text).
    public func sessionLogFileNames(sessionID: String) throws -> AgentSessionLogFileNamesV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.sessionLogFileNames(sessionId: sessionID) }
    }

    /// Parses the 4-byte big-endian length prefix and enforces the payload cap.
    public func framePayloadLength(prefix: Data) throws -> UInt32 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.framePayloadLength(prefix: prefix) }
    }

    /// Encodes one client -> host message as a complete frame (prefix + payload).
    public func encodeClientMessage(_ message: AgentHostClientMessageV1) throws -> Data {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.encodeClientMessage(message: message) }
    }

    /// Decodes exactly one complete client -> host frame (prefix + payload).
    public func decodeClientMessage(frame: Data) throws -> AgentHostClientMessageV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.decodeClientMessage(frame: frame) }
    }

    /// Encodes one host -> client message as a complete frame (prefix + payload).
    public func encodeHostMessage(_ message: AgentHostHostMessageV1) throws -> Data {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.encodeHostMessage(message: message) }
    }

    /// Decodes exactly one complete host -> client frame (prefix + payload).
    public func decodeHostMessage(frame: Data) throws -> AgentHostHostMessageV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.decodeHostMessage(frame: frame) }
    }

    /// Encodes a snapshot body: what `SnapshotChunk.data` chunks concatenate to.
    public func encodeSnapshot(_ snapshot: AgentHostAgentSessionSnapshotV1) throws -> Data {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.encodeSnapshot(snapshot: snapshot) }
    }

    /// Decodes a reassembled snapshot body.
    public func decodeSnapshot(bytes: Data) throws -> AgentHostAgentSessionSnapshotV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.decodeSnapshot(bytes: bytes) }
    }

    /// `MutationKey.argument_fingerprint` for a command (design §5.4).
    public func commandFingerprint(_ command: AgentHostCommandRequestV1) throws -> String {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.commandFingerprint(command: command) }
    }

    /// The idempotency key of a mutating command; `nil` for read-only commands.
    public func mutationKey(_ command: AgentHostCommandRequestV1) throws -> AgentHostMutationKeyV1? {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.mutationKey(command: command) }
    }
}

// MARK: - Session event log

/// One open session event log (`AgentSessionLog`, design §7.2). Single writer per file: the host
/// holds it; clients read through the host. Every call is synchronous and bounded.
public final class CoreAgentSessionLog: Sendable {
    private let raw: AgentSessionLog

    private init(raw: AgentSessionLog) {
        self.raw = raw
    }

    /// Opens (or creates) the log at `path` for `sessionID`, validates the header, scans every record,
    /// truncates a torn tail, and loads the snapshot when asked. A newer schema version fails closed
    /// with `CoreBridgeError.agentSessionLogUnsupportedSchemaVersion` and must never be worked around.
    public static func open(
        path: String,
        sessionID: String,
        options: AgentSessionLogOpenOptionsV1
    ) throws -> CoreAgentSessionLog {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try CoreAgentSessionLog(raw: AgentSessionLog.open(path: path, sessionId: sessionID, options: options))
        }
    }

    public func openReport() throws -> AgentSessionLogOpenReportV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.openReport() }
    }

    public func status() throws -> AgentSessionLogStatusV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.status() }
    }

    /// Appends one event and returns its cursor (`delivery_cursor`).
    public func append(
        _ event: AgentHostAgentSessionEventV1,
        durability: AgentSessionLogDurabilityV1
    ) throws -> UInt64 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.append(event: event, durability: durability) }
    }

    /// `fdatasync` of every deferred append (turn boundary).
    public func sync() throws {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.sync() }
    }

    /// Positional bounded read from `cursor` (1-based).
    public func readFrom(cursor: UInt64, maxRecords: UInt32, maxBytes: UInt32) throws -> AgentSessionLogReadBatchV1 {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.readFrom(cursor: cursor, maxRecords: maxRecords, maxBytes: maxBytes)
        }
    }

    /// Syncs the log, then atomically replaces the derived `.snapshot`.
    public func compact(_ snapshot: AgentHostAgentSessionSnapshotV1) throws -> AgentSessionLogCompactReceiptV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.compact(snapshot: snapshot) }
    }

    public func loadSnapshot() throws -> AgentSessionLogSnapshotLoadV1 {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.loadSnapshot() }
    }

    /// Syncs deferred appends and releases the file; later calls fail with `agentSessionLogClosed`.
    public func close() throws {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.close() }
    }
}
