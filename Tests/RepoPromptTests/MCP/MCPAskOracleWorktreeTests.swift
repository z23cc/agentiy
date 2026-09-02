import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class MCPAskOracleWorktreeTests: XCTestCase {
        func testOracleCleanupHelperInvokesAIQueriesServiceDelete() async {
            let recorder = OracleCleanupRecorder()
            let oracle = makeOracleViewModel(cleanupRecorder: recorder)
            let handle = ProviderConversationCleanupHandle(
                provider: "test-provider",
                conversationID: "oracle-thread"
            )

            await oracle.cleanupOracleProviderConversation(handle, model: .claude4Sonnet)

            let calls = recorder.calls()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.handle, handle)
            XCTAssertEqual(calls.first?.model, .claude4Sonnet)
            XCTAssertEqual(calls.first?.action, .delete)
        }

        func testOracleSendContextKeepsConversationOwnerSeparateFromDelegatedPackagingSource() throws {
            let childTabID = UUID()
            let childWorkspaceID = UUID()
            let childSessionID = UUID()
            let childRunID = UUID()
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let sourceRunID = UUID()
            let delegationID = UUID()
            let sourceSelection = StoredSelection(
                selectedPaths: ["/tmp/source/Sources/Feature.swift"],
                codemapAutoEnabled: false
            )
            let sourceCapability = SelectedGitArtifactCapability(
                workspaceID: childWorkspaceID,
                workspaceDirectoryPath: "/tmp/workspace",
                gitDataRoot: WorkspaceRootRef(
                    id: UUID(),
                    name: "_git_data",
                    fullPath: "/tmp/workspace/_git_data"
                ),
                creatorTabID: sourceTabID,
                sessionID: sourceSessionID,
                boundCheckouts: [],
                canonicalWorkspaceRootPaths: ["/tmp/source"]
            )
            let sourceReviewContext = FrozenPromptGitReviewContext(
                artifactCapability: sourceCapability,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            )
            let capturedSource = AgentRunOracleReviewSource.Captured(
                delegationID: delegationID,
                sourceTabID: sourceTabID,
                workspaceID: childWorkspaceID,
                sourceSelectionRevision: 42,
                promptText: "source prompt",
                selection: sourceSelection,
                lookupContext: .visibleWorkspace,
                reviewGitContext: sourceReviewContext,
                sourceAgentSessionID: sourceSessionID,
                sourceAgentRunID: sourceRunID,
                sourceWorktreeBindings: []
            )
            let delegated = DelegatedAgentRunOracleReviewContext(
                source: .captured(capturedSource),
                target: AgentRunOracleReviewTargetSnapshot(
                    tabID: childTabID,
                    workspaceID: childWorkspaceID,
                    agentSessionID: childSessionID,
                    activationID: UUID(),
                    expectedParentSessionID: sourceSessionID,
                    worktreeBindings: [],
                    validationFailure: nil
                ),
                targetRunID: childRunID
            )
            let packaging = try OracleViewModel.OracleSendPackagingContext(delegated: delegated)
            let context = OracleViewModel.OracleSendTabContext(
                tabID: childTabID,
                workspaceID: childWorkspaceID,
                origin: .askOracle,
                agentModeSessionID: childSessionID,
                agentModeRunID: childRunID,
                packaging: packaging
            )

            XCTAssertEqual(context.tabID, childTabID)
            XCTAssertEqual(context.agentModeSessionID, childSessionID)
            XCTAssertEqual(context.agentModeRunID, childRunID)
            XCTAssertEqual(context.packaging.sourceTabID, sourceTabID)
            XCTAssertEqual(context.packaging.sourceAgentSessionID, sourceSessionID)
            XCTAssertEqual(context.packaging.sourceAgentRunID, sourceRunID)
            XCTAssertEqual(context.packaging.selection, sourceSelection)
            XCTAssertEqual(
                context.packaging.provenance,
                .delegated(delegationID: delegationID)
            )
            guard case let .delegated(artifactDelegation) = try XCTUnwrap(
                context.packaging.reviewGitContext.artifactCapability
            ).access else {
                return XCTFail("Expected delegated artifact capability")
            }
            XCTAssertEqual(artifactDelegation.sourceTabID, sourceTabID)
            XCTAssertEqual(artifactDelegation.targetTabID, childTabID)
            XCTAssertEqual(artifactDelegation.targetAgentSessionID, childSessionID)
            XCTAssertEqual(artifactDelegation.targetAgentRunID, childRunID)
            XCTAssertEqual(
                context.packaging.reviewGitContext.artifactDelegationConsumer,
                SelectedGitArtifactDelegationConsumer(
                    workspaceID: childWorkspaceID,
                    tabID: childTabID,
                    agentSessionID: childSessionID,
                    agentRunID: childRunID,
                    boundCheckouts: []
                )
            )
        }

        func testExplicitOracleContinuationRequiresExactAgentSessionAndRunOwner() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let owned = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID
            )
            let unownedLegacy = ChatSession(composeTabID: tabID)

            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: UUID()
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: UUID(),
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    unownedLegacy,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: nil
                )
            )
            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    unownedLegacy,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )
        }

        func testOracleLogLookupDoesNotAdoptLegacyOrSiblingRun() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let exact = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID,
                savedAt: Date(timeIntervalSince1970: 1)
            )
            let newerSibling = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: UUID(),
                savedAt: Date(timeIntervalSince1970: 3)
            )
            let newestLegacy = ChatSession(
                composeTabID: tabID,
                savedAt: Date(timeIntervalSince1970: 4)
            )

            XCTAssertEqual(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, newerSibling, exact],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )?.id,
                exact.id
            )
            XCTAssertNil(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, newerSibling],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
        }
    }

    @MainActor
    private func makeOracleViewModel(cleanupRecorder: OracleCleanupRecorder) -> OracleViewModel {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(
            keyManager: keyManager,
            cleanupProviderConversationOverride: { handle, model, action in
                cleanupRecorder.record(handle: handle, model: model, action: action)
                return .succeeded(message: "oracle cleanup")
            }
        )
        let fileManager = WorkspaceFilesViewModel()
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: fileManager,
            apiSettingsViewModel: apiSettings,
            windowID: -298,
            settingsManager: WindowSettingsManager(windowID: -298)
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        return OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
    }

    private final class OracleCleanupRecorder: @unchecked Sendable {
        struct Call {
            let handle: ProviderConversationCleanupHandle
            let model: AIModel
            let action: ProviderConversationCleanupAction
        }

        private let lock = NSLock()
        private var recordedCalls: [Call] = []

        func record(
            handle: ProviderConversationCleanupHandle,
            model: AIModel,
            action: ProviderConversationCleanupAction
        ) {
            lock.lock()
            recordedCalls.append(.init(handle: handle, model: model, action: action))
            lock.unlock()
        }

        func calls() -> [Call] {
            lock.lock()
            let calls = recordedCalls
            lock.unlock()
            return calls
        }
    }
#endif
