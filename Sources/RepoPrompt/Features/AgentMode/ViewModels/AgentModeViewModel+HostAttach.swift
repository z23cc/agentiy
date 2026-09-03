import Foundation
import MCP

@MainActor
extension AgentModeViewModel {
    /// Attaches this window (or MCP handle) to a host-owned session and hydrates the
    /// per-window presentation cache. Execution stays on the host.
    @discardableResult
    func attachHostSession(
        sessionID: UUID,
        resume: AgentSessionCursor? = nil
    ) async throws -> AgentSessionAttachResult {
        if let existing = (try? authoritativeLiveSession(for: sessionID)) ?? nil {
            let result = try await sessionConnection.attach(
                sessionID: sessionID,
                resume: resume
            )
            applyHostAttachSnapshot(result, to: existing)
            scheduleListedHostSessionRefresh()
            return result
        }
        // Attach on the host first so an unknown session_id cannot mint a local tab.
        let result = try await sessionConnection.attach(
            sessionID: sessionID,
            resume: resume
        )
        let session = try await ensureSessionForHostAttach(sessionID: sessionID)
        applyHostAttachSnapshot(result, to: session)
        scheduleListedHostSessionRefresh()
        return result
    }

    /// Best-effort attach used by wait/steer/respond auto-attach. Host unavailability
    /// must not fence a local session this window already owns.
    @discardableResult
    func attachHostSessionIfAvailable(
        sessionID: UUID,
        resume: AgentSessionCursor? = nil
    ) async -> AgentSessionAttachResult? {
        do {
            return try await attachHostSession(sessionID: sessionID, resume: resume)
        } catch {
            Self.steeringDebugLog(
                "[AgentSessionConnection] attach unavailable session=\(sessionID) error=\(Self.connectionRejectionMessage(error))"
            )
            return nil
        }
    }

    /// Attaches only when this window has not yet subscribed.
    func attachHostSessionIfNeeded(sessionID: UUID) async {
        guard let session = (try? authoritativeLiveSession(for: sessionID)) ?? nil,
              session.latestConnectionCursor == nil
        else { return }
        _ = await attachHostSessionIfAvailable(sessionID: sessionID)
    }

    /// Sidebar / Agents View: attach and switch this window onto the session.
    func attachAndOpenHostSession(sessionID: UUID) async {
        do {
            let result = try await attachHostSession(sessionID: sessionID)
            if let promptManager {
                await promptManager.switchComposeTab(result.snapshot.tabID)
            }
        } catch {
            Self.steeringDebugLog(
                "[AgentSessionConnection] sidebar attach failed session=\(sessionID) error=\(Self.connectionRejectionMessage(error))"
            )
        }
    }

    /// Unsubscribes this client. Never stops host execution.
    func detachHostSession(sessionID: UUID) async {
        await sessionConnection.detach(sessionID: sessionID)
        if let session = (try? authoritativeLiveSession(for: sessionID)) ?? nil {
            session.latestConnectionSnapshot = nil
            session.latestConnectionCursor = nil
        }
        scheduleListedHostSessionRefresh()
    }

    func scheduleListedHostSessionRefresh() {
        listedHostSessionsRefreshTask?.cancel()
        listedHostSessionsRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshListedHostSessions()
        }
    }

    func refreshListedHostSessions() async {
        let workspaceID = workspaceManager?.activeWorkspaceID
        let listed: [AgentSessionListedSummary]
        do {
            listed = try await sessionConnection.listSessions(
                includeTerminal: false,
                workspaceID: workspaceID
            )
        } catch {
            return
        }
        guard listedHostSessions != listed else { return }
        listedHostSessions = listed
        sidebarListProjectionCache = nil
        lastSidebarContentFingerprint = nil
        ui.sessionSidebar.refresh()
    }

    func attachableHostSessions(
        workspaceID: UUID?,
        composeTabs: [ComposeTabState]
    ) -> [AgentSessionListedSummary] {
        let openSessionIDs = Set(composeTabs.compactMap(\.activeAgentSessionID))
            .union(Set(sessions.values.compactMap(\.activeAgentSessionID)))
        return listedHostSessions.filter { listed in
            if openSessionIDs.contains(listed.sessionID) { return false }
            if let workspaceID, let listedWorkspace = listed.workspaceID, listedWorkspace != workspaceID {
                return false
            }
            return true
        }
    }

    private func ensureSessionForHostAttach(sessionID: UUID) async throws -> TabSession {
        if let existing = (try? authoritativeLiveSession(for: sessionID)) ?? nil {
            return existing
        }
        let target = try await mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: true,
            sessionName: nil,
            inheritWorktreeBindings: false
        )
        let session = await ensureSessionReady(tabID: target.tabID)
        guard session.activeAgentSessionID == sessionID else {
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
        return session
    }

    func applyHostAttachSnapshot(_ result: AgentSessionAttachResult, to session: TabSession) {
        let snapshot = result.snapshot
        if !snapshot.items.isEmpty || session.items.isEmpty {
            session.setItemsSilently(snapshot.items, reason: .hostAttach)
        }
        session.runState = snapshot.runState
        session.selectedAgent = snapshot.provider
        if !snapshot.modelRaw.isEmpty {
            session.selectedModelRaw = snapshot.modelRaw
        }
        session.providerSessionID = snapshot.providerSessionID
        session.latestConnectionSnapshot = snapshot
        session.latestConnectionCursor = result.cursor
        session.hasLoadedPersistedState = true
        if let sessionID = snapshot.sessionID ?? session.activeAgentSessionID {
            upsertSessionIndex(
                sessionID: sessionID,
                tabID: session.tabID,
                name: codexThreadDisplayName(for: session.tabID),
                lastUserMessageAt: session.lastUserMessageAt,
                savedAt: Date(),
                lastRunStateRaw: snapshot.runState.rawValue,
                itemCount: snapshot.items.count,
                agentKindRaw: snapshot.provider.rawValue,
                agentModelRaw: snapshot.modelRaw,
                agentReasoningEffortRaw: session.selectedReasoningEffortRaw,
                autoEditEnabled: session.autoEditEnabled,
                parentSessionID: session.parentSessionID,
                isMCPOriginated: session.isMCPOriginated,
                worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
                activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
            )
        }
        handleObservedMCPStateChange(for: session)
        if session.tabID == currentTabID {
            requestUIRefresh(tabID: session.tabID)
        }
        syncSidebarUIState(refresh: true, reason: .sessionList)
    }
}
