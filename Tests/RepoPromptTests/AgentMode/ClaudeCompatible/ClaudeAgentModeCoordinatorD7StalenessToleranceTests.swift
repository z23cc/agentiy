import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// D-7 (`docs/architecture/rust-agent-claude-v1.md` §9, design §7's drift register): once the
/// controller moves behind an FFI, `hasTurnInFlight`/`hasActiveSession` become event-derived facts
/// rather than synchronous actor reads and can legitimately be stale by the time the caller acts
/// on them. The census recorded two surviving call sites, each already staleness-tolerant by
/// construction because a subsequent guard (`intentIsCurrent`/`sessionOwnsClaudeController`) or
/// downstream error path re-validates before anything destructive happens. These two tests pin
/// each site's tolerated-staleness contract directly, now that the Rust-backed adapter
/// (`ClaudeRustBackedNativeSessionAdapter`) exists and makes "event-derived, can be stale" a real
/// property of a real second arm rather than a hypothetical one.
@MainActor
extension AgentModeRunServiceLifecycleTests {
    /// Site 1: `ensureClaudeNativeSession`'s launch-settings-changed branch
    /// (`ClaudeAgentModeCoordinator.swift`, "guard !hasTurnInFlight else { return .ready }"). A
    /// stale `true` here is tolerated by design -- recycling to the new launch settings is
    /// *deferred* to the next idle call rather than interrupting a turn that may genuinely still
    /// be in flight. This test proves the deferral, not just its absence of a crash: the original
    /// controller must remain installed, unrecycled, and the outcome must be `.ready`.
    func testEnsureClaudeNativeSessionDefersRecycleWhileATurnIsInFlightD7SiteOne() async throws {
        let recorder = LifecycleRecorder()
        let staleTurnInFlightController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "stale-turn-in-flight",
            hasTurnInFlight: true
        )
        let harness = makeHarness(
            recorder: recorder,
            claudeControllerFactory: { _, _, _, _ in
                recorder.record("factory:unexpected-recycle")
                return LifecycleFakeNativeController(recorder: recorder, label: "unexpected-recycle")
            }
        )
        let session = makeRunningClaudeSession(controller: staleTurnInFlightController, host: harness.host)
        session.permissionProfile = .mcpSafeDefaults
        // Deliberately mismatched relative to `.mcpSafeDefaults`'s resolved runtime policy, so
        // `ensureClaudeNativeSession` detects permissionModeChanged/bashToolChanged/
        // mcpStrictModeChanged and enters the branch this test targets (mirrors
        // `testQueuedClaudeSteeringRecreatesControllerBeforeSendWhenPermissionsTighten`'s recipe
        // for producing the same mismatch, but drives `ensureClaudeNativeSession` directly instead
        // of through the steering queue, which recreates unconditionally and would not exercise
        // this guard).
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode,
            allowNativeBashTool: true,
            mcpStrictMode: false
        )

        let ownership = try XCTUnwrap(session.activeRunOwnership)
        let runID = try XCTUnwrap(session.runID)
        let outcome = await harness.host.claudeCoordinator.ensureClaudeNativeSession(
            session: session,
            intent: .runAttempt(ownership: ownership, runID: runID)
        )

        XCTAssertEqual(outcome, .ready, "a stale hasTurnInFlight=true must defer recycle, not fail or supersede")
        XCTAssertFalse(recorder.contains("stale-turn-in-flight:shutdown"), "the in-flight controller must not be torn down")
        XCTAssertFalse(recorder.contains("factory:unexpected-recycle"), "no replacement controller may be constructed while deferred")
        guard let finalController = session.claudeController else {
            return XCTFail("expected the original controller to remain installed")
        }
        XCTAssertEqual(
            ObjectIdentifier(finalController as AnyObject),
            ObjectIdentifier(staleTurnInFlightController as AnyObject),
            "the original in-flight controller must remain the session's installed controller"
        )
    }

    /// Site 2: the pre-send liveness guard inside `sendClaudeNativeMessage`
    /// ("let hasActiveSession = await controller.hasActiveSession; ... guard hasActiveSession else
    /// { ...fail... }"). A stale `true` here is tolerated differently from site 1: rather than
    /// deferring, the send is attempted anyway and falls through to `sendUserMessage`'s own error
    /// handling if the session has genuinely died underneath -- exactly the
    /// `NativeAgentRuntimeControllerError.processNotRunning` shape the design names as what a real
    /// dead session surfaces as (the same error class `shouldAttemptFreshStartRecovery` treats as
    /// fresh-start-eligible on the *next* `ensureClaudeNativeSession` call). This test pins the
    /// immediate half of that contract: a stale-true `hasActiveSession` combined with a genuinely
    /// dead transport must produce a clean `.failed` outcome and a visible chat error item, never a
    /// crash, a hang, or a silently swallowed failure.
    func testSendClaudeNativeMessageFailsCleanlyWhenActiveSessionIsStaleD7SiteTwo() async throws {
        let recorder = LifecycleRecorder()
        let staleActiveSessionController = LifecycleFakeNativeController(
            recorder: recorder,
            label: "stale-active-session",
            sendUserMessageFailure: NativeAgentRuntimeControllerError.processNotRunning
        )
        let harness = makeHarness(recorder: recorder, claudeController: staleActiveSessionController)
        let session = makeRunningClaudeSession(controller: staleActiveSessionController, host: harness.host)
        let runtime = resolvedClaudeLaunchPolicy(profile: session.permissionProfile, harness: harness)
        setClaudeControllerLaunchSettings(
            for: session,
            coordinator: harness.host.claudeCoordinator,
            permissionMode: runtime?.permissionMode,
            allowNativeBashTool: runtime?.allowNativeBashTool,
            mcpStrictMode: runtime?.mcpStrictMode
        )

        let ownership = try XCTUnwrap(session.activeRunOwnership)
        let runID = try XCTUnwrap(session.runID)
        let outcome = await harness.host.claudeCoordinator.sendClaudeNativeMessage(
            session: session,
            text: "stale hasActiveSession must not corrupt state",
            attachments: [],
            intent: .runAttempt(ownership: ownership, runID: runID)
        )

        guard case let .failed(message) = outcome else {
            return XCTFail(
                "expected a clean .failed outcome once the staleness-tolerant hasActiveSession=true "
                    + "read is contradicted by sendUserMessage, got \(outcome)"
            )
        }
        XCTAssertTrue(recorder.contains("stale-active-session:send-failed"), "sendUserMessage must actually have been attempted, not short-circuited")
        XCTAssertTrue(message.contains("Claude native send failed"))
        XCTAssertEqual(session.items.last?.kind, .error, "the failure must be visible to the user as a chat error item")
    }
}
