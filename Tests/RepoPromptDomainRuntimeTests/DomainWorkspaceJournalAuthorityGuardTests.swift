import Foundation
import XCTest

final class DomainWorkspaceJournalAuthorityGuardTests: XCTestCase {
    func testProductionWorkingJournalHasOneRustCanonicalReadWriteBoundary() throws {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("Sources/RepoPromptDomainRuntime/DomainPersistence.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertEqual(
            source.components(separatedBy: "to: journalURL(").count - 1,
            1,
            "Only replaceJournal may write a production working-journal path"
        )
        for forbidden in [
            "decoder.decode(DomainWorkingJournal.self",
            "Data(contentsOf: journalURL(",
            "encoder.encode(journal), to: journalURL(",
            "private func loadJournal(workspaceID: UUID)",
            "try? resolvedPendingSave(",
            "try? boundedWorkspaceDocumentBytes(",
            "transition: .save(",
            "transition: .recoverPending(",
            "DomainWorkingJournal(",
            "DomainSavedRevisionRecord(",
            "DomainDeletionTombstone(",
            "encoder.encode(revision)",
            "encoder.encode(revisionRecord)",
            "encoder.encode(tombstone)",
            "encoder.encode(recordedTombstone)",
            "Data(contentsOf: revisionURL(",
            "tombstoneRecordingCleanupWarnings(",
            "prepareJournalCandidate(",
            "Self.trimmedOperations(",
            "planJournalTransition(",
            "authorityReceipt.savedRevision == nil",
            "return (activatedReceipt, .finalized)",
            "return (activatedReceipt, .revisionSidecarMissing)"
        ] {
            XCTAssertFalse(source.contains(forbidden), "Swift journal authority returned: \(forbidden)")
        }
        for required in [
            "private func readRawJournalSnapshot(",
            "validator.validateSynchronously(",
            "validator.seedWorkingJournal(",
            "private func replaceJournal(",
            "validator.beginCreateTransaction(",
            "validator.beginCreateRecoveryTransaction(",
            "validator.beginSaveTransaction(",
            "validator.beginJournalMutationTransaction(",
            "private func executeJournalMutationTransaction(",
            "transaction.nextDirective()",
            "transaction.acquireAuthorityPermit()",
            "transaction.report(",
            "validator.resolvePendingSave(",
            "deletionSidecarDiagnostic(",
            "case let .publishWorkspaceDocument(",
            "case let .writeCommittedJournal(",
            "candidate.canonicalBytes",
            "validator.validateSavedRevision(",
            "validator.requireRuntimeAvailability()",
            "transaction.planCleanup(",
            "transaction.finishCommandAuthority(",
            "private func readSavedRevisionSnapshot(",
            "postAuthoritySuccessFinalization",
            "postAuthorityFailureFinalization",
            "finalization: postAuthoritySuccessFinalization",
            "activatedFinalization = postAuthorityFailureFinalization",
            "func activatedOutcome()",
            "func activatedCommit(",
            "var expectedActionID: UInt64 = 1",
            "guard actionID == expectedActionID, activatedReceipt == nil",
            "guard receiptsMatch(receipt, outcome.receipt)",
            "guard receiptsMatch(receipt, activatedReceipt)",
            "if let outcome = activatedOutcome() { return outcome }",
            "if let committed = activatedCommit() { return committed }",
            "validation.canonicalBytes",
            "plannedTombstone.canonicalBytes",
            "cleanupPlan.canonicalBytes",
            "allowsCancellation: false",
            "if isJournalInfrastructureFailure(error)"
        ] {
            XCTAssertTrue(source.contains(required), "Missing Rust journal boundary: \(required)")
        }
        XCTAssertEqual(
            source.components(separatedBy: "validator.seedWorkingJournal(").count - 1,
            2,
            "Only typed Rust seed adapters may materialize missing production journals"
        )
        for transition in [
            ".unchanged(",
            ".working(",
            ".externalReload(",
            ".conflictRebase("
        ] {
            XCTAssertTrue(source.contains(transition), "Missing Rust transaction transition: \(transition)")
        }
        let transactionStart = try XCTUnwrap(source.range(
            of: "private func executeJournalMutationTransaction("
        ))
        let unchangedStart = try XCTUnwrap(source.range(
            of: "private func persistUnchangedBlocking(",
            range: transactionStart.lowerBound ..< source.endIndex
        ))
        let transactionAuthority = source[transactionStart.lowerBound ..< unchangedStart.lowerBound]
        XCTAssertTrue(transactionAuthority.contains("transaction.acquireAuthorityPermit()"))
        XCTAssertTrue(transactionAuthority.contains("case let .writeJournal("))
    }

    func testProductionMissingJournalSeedUsesDedicatedRustScalarEndpoint() throws {
        let root = repositoryRoot()
        let adapter = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainWorkspaceRustJournal.swift"
            ),
            encoding: .utf8
        )
        let persistence = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainPersistence.swift"
            ),
            encoding: .utf8
        )

        for forbidden in [
            "struct DomainWorkspaceWorkingJournalTransitionPlan",
            "func planTransition(",
            "core.planTransition(",
            "plan.committed",
            "plan.primary"
        ] {
            XCTAssertFalse(adapter.contains(forbidden), "Swift seed planning authority returned: \(forbidden)")
        }
        for required in [
            "func seedWorkingJournal(",
            "core.seedWorkingJournal(seedRequestBytes: seedRequestBytes)",
            "expectedWorkspaceID: workspaceID",
            "expectedFileURL: fileURL"
        ] {
            XCTAssertTrue(adapter.contains(required), "Missing dedicated Rust seed boundary: \(required)")
        }
        XCTAssertEqual(
            persistence.components(separatedBy: "validator.seedWorkingJournal(").count - 1,
            2,
            "Only typed Rust seed adapters may materialize missing production journals"
        )
    }

    func testGenericWorkingJournalPlannerIsRuntimeInternalOnly() throws {
        let root = repositoryRoot()
        let transportSources = [
            "rust/crates/ffi/src/api.rs",
            "rust/crates/ffi/src/types.rs",
            "Sources/AgentryCoreBridge/CoreBridge.swift",
            "Sources/AgentryCoreBridge/CoreWorkspaceDocumentProjection.swift"
        ]
        let retiredSymbols = [
            "workspace_working_journal_plan_transition_v1",
            "workspaceWorkingJournalPlanTransitionV1",
            "CoreWorkspaceWorkingJournalTransitionRequestV1",
            "CoreWorkspaceWorkingJournalTransitionResponseV1",
            "CoreWorkspaceWorkingJournalTransitionPlanV1",
            "func planTransition("
        ]
        for relativePath in transportSources {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for symbol in retiredSymbols {
                XCTAssertFalse(
                    source.contains(symbol),
                    "Retired generic planner surface returned in \(relativePath): \(symbol)"
                )
            }
        }

        let runtime = try String(
            contentsOf: root.appendingPathComponent(
                "rust/crates/runtime/src/workspace_persistence_journal.rs"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(runtime.contains("fn plan_workspace_working_journal_transition_v1("))
        XCTAssertFalse(runtime.contains("pub fn plan_workspace_working_journal_transition_v1("))
        XCTAssertTrue(runtime.contains("pub fn seed_workspace_working_journal_v1("))
    }

    func testGenericWorkspaceCatalogPlannerIsRuntimeInternalOnly() throws {
        let root = repositoryRoot()
        let transportSources = [
            "rust/crates/ffi/src/api.rs",
            "rust/crates/ffi/src/types.rs",
            "Sources/AgentryCoreBridge/CoreBridge.swift",
            "Sources/AgentryCoreBridge/CoreWorkspaceDocumentProjection.swift",
            "Sources/RepoPromptDomainRuntime/DomainWorkspaceRustJournal.swift"
        ]
        let retiredSymbols = [
            "workspace_catalog_plan_transition_v1",
            "workspaceCatalogPlanTransitionV1",
            "CoreWorkspaceCatalogTransitionRequestV1",
            "func planCatalogTransition(",
            "DomainWorkspaceCatalogTransition"
        ]
        for relativePath in transportSources {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for symbol in retiredSymbols {
                XCTAssertFalse(
                    source.contains(symbol),
                    "Retired generic catalog planner returned in \(relativePath): \(symbol)"
                )
            }
        }

        let runtime = try String(
            contentsOf: root.appendingPathComponent(
                "rust/crates/runtime/src/workspace_persistence_journal.rs"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(runtime.contains("fn plan_workspace_catalog_transition_v1("))
        XCTAssertFalse(runtime.contains("pub fn plan_workspace_catalog_transition_v1("))
        XCTAssertTrue(runtime.contains("pub fn seed_workspace_catalog_v1("))
    }

    func testStandaloneMetadataPlannersAreRustInternalOnlyAndCleanupIsTransactionOwned() throws {
        let root = repositoryRoot()
        let transportSources = [
            "rust/crates/ffi/src/api.rs",
            "rust/crates/ffi/src/types.rs",
            "Sources/AgentryCoreBridge/CoreBridge.swift",
            "Sources/AgentryCoreBridge/CoreWorkspaceDocumentProjection.swift",
            "Sources/RepoPromptDomainRuntime/DomainWorkspaceRustJournal.swift"
        ]
        let retiredSymbols = [
            "workspace_saved_revision_plan_v1",
            "workspaceSavedRevisionPlanV1",
            "workspace_deletion_tombstone_plan_v1",
            "workspaceDeletionTombstonePlanV1",
            "func planSavedRevision(",
            "func planDeletionTombstone(",
            "SavedRevisionPlanRequest",
            "DeletionTombstonePlanRequest"
        ]
        for relativePath in transportSources {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for symbol in retiredSymbols {
                XCTAssertFalse(
                    source.contains(symbol),
                    "Retired standalone metadata planner returned in \(relativePath): \(symbol)"
                )
            }
        }

        let runtime = try String(
            contentsOf: root.appendingPathComponent(
                "rust/crates/runtime/src/workspace_persistence_journal.rs"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(runtime.contains("fn plan_workspace_saved_revision_record_v1("))
        XCTAssertFalse(runtime.contains("pub fn plan_workspace_saved_revision_record_v1("))
        XCTAssertTrue(runtime.contains("fn plan_workspace_deletion_tombstone_v1("))
        XCTAssertFalse(runtime.contains("pub fn plan_workspace_deletion_tombstone_v1("))
        XCTAssertTrue(runtime.contains("pub fn amend_workspace_deletion_tombstone_cleanup_v1("))
    }

    func testProductionCatalogStateMachineIsRustOwnedWithOnePhysicalWriteBoundary() throws {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("Sources/RepoPromptDomainRuntime/DomainPersistence.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertEqual(
            source.components(separatedBy: "to: catalogURL").count - 1,
            1,
            "Only writeCatalog may publish the production workspace catalog"
        )
        for forbidden in [
            "decoder.decode(RuntimeWorkspaceCatalog.self",
            "RuntimeWorkspaceCatalog(",
            "decoder.decode(DomainDeletionTombstone.self",
            "encoder.encode(catalog), to: catalogURL",
            "encoder.encode(nextCatalog), to: catalogURL",
            "encoder.encode(next), to: catalogURL",
            "validateUniqueCatalogEntries("
        ] {
            XCTAssertFalse(source.contains(forbidden), "Swift catalog authority returned: \(forbidden)")
        }
        for required in [
            "private enum RawCatalogSnapshot",
            "private struct ValidatedCatalogSnapshot",
            "private func readCatalogBytes()",
            "private func writeCatalog(",
            "expected: RawCatalogSnapshot",
            "DomainContentDigest.sha256(currentBytes)",
            "validateBeforeReplace:",
            "beforeDirectorySync:",
            "try validateBeforeReplace?()",
            "directory_fsync_failed_",
            "validator.validateCatalog(",
            "validator.prepareInitialSemanticRecovery(",
            "validator.seedCatalog(",
            "validator.beginCreateTransaction(",
            "validator.beginCreateRecoveryTransaction(",
            "validator.beginDeleteTransaction(",
            "createTransactionLoop: while true",
            "deleteTransactionLoop: while true",
            "private func recoverInterruptedCreates("
        ] {
            XCTAssertTrue(source.contains(required), "Missing Rust catalog boundary: \(required)")
        }
        XCTAssertEqual(
            source.components(separatedBy: "validator.seedCatalog(").count - 1,
            1,
            "Only shared load/migration may invoke the dedicated Rust catalog seed endpoint"
        )
        XCTAssertTrue(
            source.contains("let catalogSnapshot = try loadCurrentCatalog("),
            "Migration must reuse the guarded Rust catalog seed path"
        )
        XCTAssertTrue(
            source.contains("now: Date(timeIntervalSinceReferenceDate: 0)"),
            "Catalog-absent migration must persist one process-independent seed identity"
        )
        let migrationStart = try XCTUnwrap(source.range(of: "private func ensureLazyMigration("))
        let lockHelperStart = try XCTUnwrap(source.range(
            of: "private struct DomainPersistenceAtomicWriteReceipt",
            range: migrationStart.lowerBound ..< source.endIndex
        ))
        let migration = source[migrationStart.lowerBound ..< lockHelperStart.lowerBound]
        let migrationCatalogLock = try XCTUnwrap(migration.range(
            of: "withLock(at: lockDirectory.appendingPathComponent(\"workspace-catalog.lock\"))"
        ))
        let migrationCatalogLoad = try XCTUnwrap(migration.range(
            of: "let catalogSnapshot = try loadCurrentCatalog("
        ))
        XCTAssertLessThan(migrationCatalogLock.lowerBound, migrationCatalogLoad.lowerBound)
        let createStart = try XCTUnwrap(source.range(of: "private func persistCreatedBlocking("))
        let unchangedStart = try XCTUnwrap(source.range(
            of: "private func persistUnchangedBlocking(",
            range: createStart.lowerBound ..< source.endIndex
        ))
        let createAuthority = source[createStart.lowerBound ..< unchangedStart.lowerBound]
        XCTAssertFalse(createAuthority.contains("validator.planCatalogTransition("))
        XCTAssertFalse(createAuthority.contains("transition: .upsert("))
        XCTAssertTrue(createAuthority.contains("validator.beginCreateTransaction("))
        XCTAssertTrue(createAuthority.contains("transaction.acquireAuthorityPermit()"))

        let recoveryHelperStart = try XCTUnwrap(source.range(of: "private func withExistingWorkspaceLocks"))
        let catalogReadStart = try XCTUnwrap(source.range(
            of: "private func readCatalogBytes()",
            range: recoveryHelperStart.lowerBound ..< source.endIndex
        ))
        let recoveryAuthority = source[recoveryHelperStart.lowerBound ..< catalogReadStart.lowerBound]
        XCTAssertFalse(recoveryAuthority.contains("validator.planCatalogTransition("))
        XCTAssertFalse(recoveryAuthority.contains("transition: .recoverCreate("))
        XCTAssertTrue(recoveryAuthority.contains("validator.beginCreateRecoveryTransaction("))
        XCTAssertTrue(recoveryAuthority.contains("transaction.acquireAuthorityPermit()"))

        let bootstrapStart = try XCTUnwrap(source.range(of: "private func bootstrapBlocking("))
        let recoveryScanStart = try XCTUnwrap(source.range(
            of: "private func recoverInterruptedCreates(",
            range: bootstrapStart.lowerBound ..< source.endIndex
        ))
        let readOnlyBootstrap = source[bootstrapStart.lowerBound ..< recoveryScanStart.lowerBound]
        XCTAssertFalse(readOnlyBootstrap.contains("loadJournal(workspaceID:"))
        XCTAssertFalse(readOnlyBootstrap.contains("journalURL.pathExtension"))

        let deleteStart = try XCTUnwrap(source.range(of: "private func persistDeletedBlocking("))
        let cleanupStart = try XCTUnwrap(source.range(
            of: "var artifactCleanupWarnings = [String]()",
            range: deleteStart.lowerBound ..< source.endIndex
        ))
        let deleteAuthority = source[deleteStart.lowerBound ..< cleanupStart.lowerBound]
        XCTAssertFalse(deleteAuthority.contains("validator.planDeletionTombstone("))
        XCTAssertFalse(deleteAuthority.contains("transaction.planCleanup("))
        XCTAssertFalse(deleteAuthority.contains("transition: .delete("))
        XCTAssertTrue(deleteAuthority.contains("validator.beginDeleteTransaction("))
        XCTAssertTrue(deleteAuthority.contains("transaction.acquireAuthorityPermit()"))
        let cleanupEnd = try XCTUnwrap(source.range(
            of: "private func finalizeDeletedWorkspaceArtifacts(",
            range: cleanupStart.lowerBound ..< source.endIndex
        ))
        let postAuthorityCleanup = source[cleanupStart.lowerBound ..< cleanupEnd.lowerBound]
        XCTAssertEqual(
            postAuthorityCleanup.components(
                separatedBy: "transaction.planCleanup("
            ).count - 1,
            2,
            "Only the authoritative delete transaction may plan post-authority cleanup facts"
        )
    }

    func testCommandIdentityProductionAdmissionUsesRustWithoutSwiftOracle() throws {
        let root = repositoryRoot()
        let authority = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainWorkspaceContextAuthority.swift"
            ),
            encoding: .utf8
        )
        let command = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainWorkspaceCommand.swift"
            ),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/RepoPromptDomainRuntime.swift"
            ),
            encoding: .utf8
        )
        let adapter = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainWorkspaceRustJournal.swift"
            ),
            encoding: .utf8
        )

        for forbidden in [
            "envelope.fingerprint",
            "commandIdentityObservationSink",
            "swiftFingerprint"
        ] {
            XCTAssertFalse(authority.contains(forbidden), "Retired Swift oracle remains: \(forbidden)")
        }
        XCTAssertFalse(command.contains("package var fingerprint: String"))
        XCTAssertFalse(command.contains("fingerprintComponent"))
        XCTAssertFalse(runtime.contains("DomainWorkspaceRustCommandIdentityObserver"))
        XCTAssertFalse(runtime.contains("workspaceCommandIdentityProjector"))
        for required in [
            "acquisition = try resolveCommandAcquisition(commandIdentityInput)",
            "return try commandAdmission.acquire(input)",
            "case let .claimed(receiptFingerprint, claim)",
            "case let .pending(receiptFingerprint, _)",
            "try await Task.sleep(for: .milliseconds(1))",
            "continue admissionReservation",
            "case let .replay(receiptFingerprint, scope, operation)",
            "fingerprint: fingerprint",
            "unrecordedCommandIdentityRejection(",
            "let preflight = try commandClaim.semanticPreflight(",
            "candidateDocumentBytes: candidateDocumentBytes"
        ] {
            XCTAssertTrue(authority.contains(required), "Missing Rust acquisition boundary: \(required)")
        }
        for retired in [
            "resolveCommandIdentity(",
            "resolveCommandPreflight(",
            "pendingCommandAdmissions",
            "PendingCommandAdmission",
            "commandAdmission.preflight(",
            "commandAdmission.decision("
        ] {
            XCTAssertFalse(authority.contains(retired), "Split production admission remains: \(retired)")
        }
        XCTAssertTrue(adapter.contains("func commandIdentity("))
        XCTAssertTrue(adapter.contains("core.commandIdentity("))
        XCTAssertTrue(adapter.contains("func acquire("))
        XCTAssertTrue(adapter.contains("switch try core.acquire("))
        XCTAssertTrue(adapter.contains("func semanticPreflight("))
        XCTAssertTrue(adapter.contains("core.semanticPreflight("))
        XCTAssertFalse(adapter.contains("core.decision("))
        let commandStart = try XCTUnwrap(authority.range(of: "private func createWorkspace("))
        let commandEnd = try XCTUnwrap(authority.range(of: "private func resolveExternalConflict("))
        let commandPaths = String(authority[commandStart.lowerBound..<commandEnd.lowerBound])
        for retiredSemanticBranch in [
            "if let expected = envelope.expectedCatalogRevision",
            "record.health.acceptsMutations",
            "record.document.contentDigest != document.contentDigest",
            "record.revisions.dirtyRevision != nil",
            "changedContextIDs"
        ] {
            XCTAssertFalse(
                commandPaths.contains(retiredSemanticBranch),
                "Swift semantic command branch remains: \(retiredSemanticBranch)"
            )
        }
    }

    func testCommandReplayAndCollisionProductionAdmissionFinalizesWithRustTransactions() throws {
        let root = repositoryRoot()
        let authority = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainWorkspaceContextAuthority.swift"
            ),
            encoding: .utf8
        )
        let adapter = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainWorkspaceRustJournal.swift"
            ),
            encoding: .utf8
        )
        let persistence = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainPersistence.swift"
            ),
            encoding: .utf8
        )
        let coreBridge = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/AgentryCoreBridge/CoreWorkspaceDocumentProjection.swift"
            ),
            encoding: .utf8
        )
        let rustJournal = try String(
            contentsOf: root.appendingPathComponent(
                "rust/crates/runtime/src/workspace_persistence_journal.rs"
            ),
            encoding: .utf8
        )
        let rustFFI = try String(
            contentsOf: root.appendingPathComponent("rust/crates/ffi/src/api.rs"),
            encoding: .utf8
        )
        let rustTypes = try String(
            contentsOf: root.appendingPathComponent("rust/crates/ffi/src/types.rs"),
            encoding: .utf8
        )

        for required in [
            "private var commandAdmission: DomainWorkspaceRustJournal.PreparedCommandAdmission?",
            "var acquiredClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim?",
            "private func resolveCommandAcquisition(",
            "return try commandAdmission.acquire(input)",
            "loaded.semanticRecovery",
            "let preview = loaded.semanticPreview",
            "let commit = try recovery.commit(expected: preview)",
            "try installSemanticRecoveryAuthority(commit)",
            "let semanticRecovery = durableCatalog.semanticRecovery",
            "let semanticRecovery = refreshed.semanticRecovery",
            "finalizeTransientOutcome(",
            "_ = try commandClaim.finalizeTransient(",
            "commandClaim: commandClaim",
            "recordCommandAdmissionFinalization(",
            "workspace_command_admission_receipt_missing"
        ] {
            XCTAssertTrue(authority.contains(required), "Missing claim-bound Rust admission: \(required)")
        }
        for retired in [
            "BoundedDomainOperationIndex",
            "BoundedDomainOperationSeedBuffer",
            "globalOperationSeeds",
            "ensureCommandAdmission",
            "rebuildCommandAdmission",
            "operationIndex",
            "globalOperations",
            "swiftCommandAdmissionDecision",
            "registerPersistedCommandAdmissionOperation(",
            "registerTransientCommandAdmissionOperation(",
            "removeCommandAdmissionWorkspace(",
            "pendingCommandAdmissions",
            "PendingCommandAdmission",
            "recordTransientOutcome(",
            "decision = try admission.decision(",
            "durableCommandAdmissionRecords(",
            "reconcileCommandAdmission(",
            "reconcileCommandAdmissionWorkspace(",
            "deletedOperations",
            "deletedOperation",
            "private func applyCommandAdmissionRecovery(",
            "private func applyCommandAdmissionTargetRecovery(",
            "commandAdmission.applyFullRecovery(",
            "commandAdmission.applyTargetRecovery(",
        ] {
            XCTAssertFalse(authority.contains(retired), "Retired Swift admission lookup remains: \(retired)")
        }
        XCTAssertFalse(
            authority.contains("?? recorded"),
            "A committed transaction must never synthesize a missing Rust operation receipt"
        )
        XCTAssertFalse(
            authority.contains("?? operation"),
            "A committed transaction must fail closed on a missing Rust operation receipt"
        )
        XCTAssertFalse(
            adapter.contains("try core.replace("),
            "Complete admission replacement must not remain exposed through the Domain adapter"
        )
        XCTAssertFalse(
            adapter.contains("core.removeWorkspace("),
            "Independent Swift workspace admission removal must remain retired"
        )
        XCTAssertFalse(
            adapter.contains("func insert(\n            workspaceID:"),
            "Swift must not expose a generic durable admission insert"
        )
        for required in [
            "struct PreparedCommandAdmission: Sendable",
            "struct PreparedExecutionClaim: Sendable",
            "struct PreparedSemanticRecovery: Sendable",
            "core.prepareInitialSemanticRecovery(",
            "core.prepareSemanticFullRecovery(",
            "core.prepareSemanticTargetRecovery(",
            "materializeSemanticRecoveryPreview(",
            "materializeCommandAdmissionRecoveryReceipt(",
            "switch try core.acquire(",
            "core.finalizeTransient(",
            "transactionBinding",
            "func finishCommandAuthority(",
            "func planCleanup("
        ] {
            XCTAssertTrue(adapter.contains(required), "Missing Rust admission adapter: \(required)")
        }
        for required in [
            "enum DomainWorkspaceCommandAdmissionJournalEvidence",
            "let admissionJournalEvidence: DomainWorkspaceCommandAdmissionJournalEvidence",
            "let semanticRecovery: DomainWorkspaceRustJournal.PreparedSemanticRecovery?",
            "let semanticPreview: DomainWorkspaceSemanticRecoveryPreview?",
            "semanticFullRecoveryEvidence(",
            "semanticTargetRecoveryEvidence(",
            "readSemanticRecoveryArtifact(",
            "applySemanticJournalRewrites(",
            "expectedArtifactDigest",
            "let authorityFinalization: DomainWorkspaceCommandAuthorityFinalization",
            "authorityFinalization: transaction.finishCommandAuthority()",
            "authorityFinalization: result.authorityFinalization",
            "authorityFinalization: finalization.authorityFinalization"
        ] {
            XCTAssertTrue(
                persistence.contains(required),
                "Missing transaction-owned command finalization signal: \(required)"
            )
        }
        XCTAssertFalse(
            persistence.contains("let admissionJournalBytes: Data?"),
            "Unavailable journal evidence must not collapse into authoritative absence"
        )
        for retired in [
            "commandAdmissionFinalizationReconciled",
            "reconcileAdmissionFinalization(",
            "amendDeletionTombstoneCleanup(",
            "struct DomainWorkspaceCommandAdmissionRecovery ",
            "struct DomainWorkspaceCommandAdmissionTargetRecovery ",
            "func beginCommandAdmission(",
            "func applyFullRecovery(",
            "func applyTargetRecovery(",
            "core.beginCommandAdmission(",
            "core.applyFullRecovery(",
            "core.applyTargetRecovery("
        ] {
            XCTAssertFalse(adapter.contains(retired), "Retired durable closeout remains: \(retired)")
            XCTAssertFalse(persistence.contains(retired), "Retired durable closeout remains: \(retired)")
        }
        for retired in [
            "core.preflight(",
            "core.decision(",
            "core.insertTransient(",
            "func preflight(",
            "func decision(",
            "DomainWorkspaceCommandAdmissionSeedRecord",
            "coreCommandAdmissionSeedRecord(",
            "func reconcileDurable(",
            "func reconcileWorkspace("
        ] {
            XCTAssertFalse(adapter.contains(retired), "Retired admission adapter remains: \(retired)")
        }
        for required in [
            "public enum CoreWorkspaceCommandFinalizationV1",
            "public struct CoreWorkspaceCommandAuthorityFinalizationV1",
            "public func beginSaveTransaction(",
            "public func finishCommandAuthority(",
            "public func planCleanup("
        ] {
            XCTAssertTrue(coreBridge.contains(required), "Missing typed Core finalization: \(required)")
        }
        for required in [
            "pub enum CoreWorkspaceCommandFinalizationV1",
            "pub struct CoreWorkspaceCommandAuthorityFinalizationV1",
            "transaction.prepare_claimed_authority_publication(",
            "fn finish_workspace_command_authorities(",
            "pub fn plan_cleanup("
        ] {
            XCTAssertTrue(rustFFI.contains(required), "Missing transaction-owned FFI finalization: \(required)")
        }
        XCTAssertTrue(rustJournal.contains("pub fn cleanup_plan("))
        XCTAssertTrue(rustJournal.contains("pub fn finalize_with_authority("))
        XCTAssertTrue(rustJournal.contains("pub fn prepare_claimed_authority_publication("))
        XCTAssertTrue(rustJournal.contains("authority_publication_reservation: Option<"))
        XCTAssertTrue(rustJournal.contains("validate_claimed_authority_publication_candidate_v1("))
        XCTAssertTrue(rustJournal.contains("pub fn command_authority_publication_kind("))
        XCTAssertTrue(rustFFI.contains("transaction.prepare_claimed_authority_publication("))
        for required in [
            "installCommandAuthorityFinalization(",
            "persisted.authorityFinalization",
            "deleted.authorityFinalization"
        ] {
            XCTAssertTrue(authority.contains(required), "Missing transaction publication cutover: \(required)")
        }
        for retired in [
            "commandAuthorityPublicationCandidate(",
            "DomainWorkspaceAuthorityPublicationCandidate",
            "authorityPublication: authorityPublication"
        ] {
            XCTAssertFalse(authority.contains(retired), "Swift command candidate authority remains: \(retired)")
        }
        for retired in [
            "pub fn preflight(",
            "pub fn decision(",
            "pub fn insert(",
            "pub fn replace(",
            "pub fn remove_workspace("
        ] {
            XCTAssertFalse(rustJournal.contains(retired), "Retired runtime admission API remains: \(retired)")
        }
        XCTAssertFalse(rustFFI.contains("workspace_deletion_tombstone_amend_cleanup_v1"))
        XCTAssertFalse(rustTypes.contains("CoreWorkspaceDeletionTombstoneCleanupRequestV1"))
    }

    func testAggregateProjectionAuthorityPhysicallyRetiresLegacyCompatibilityPlane() throws {
        let root = repositoryRoot()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        let authority = try source(
            "Sources/RepoPromptDomainRuntime/DomainWorkspaceContextAuthority.swift"
        )
        let adapter = try source(
            "Sources/RepoPromptDomainRuntime/DomainWorkspaceRustJournal.swift"
        )
        let directHeadless = try source(
            "Sources/RepoPromptMCP/DirectHeadlessDomainContext.swift"
        )
        let domainSources = try [
            "Sources/RepoPromptDomainRuntime/RepoPromptDomainRuntime.swift",
            "Sources/RepoPromptDomainRuntime/AgentryCoreService.swift",
            "Sources/RepoPromptDomainRuntime/DomainPersistence.swift",
            "Sources/RepoPromptDomainRuntime/DomainWorkspaceRustProjection.swift"
        ].map(source).joined(separator: "\n")
        let bridgeSources = try [
            "Sources/AgentryCoreBridge/CoreBridge.swift",
            "Sources/AgentryCoreBridge/CoreOperations.swift",
            "Sources/AgentryCoreBridge/CoreWorkspaceDocumentProjection.swift",
            "Sources/AgentryCoreBridge/CoreWorkspaceProjectionAuthority.swift"
        ].map(source).joined(separator: "\n")
        let rustSources = try [
            "rust/crates/runtime/src/workspace_context.rs",
            "rust/crates/ffi/src/api.rs",
            "rust/crates/ffi/src/errors.rs",
            "rust/crates/ffi/src/types.rs"
        ].map(source).joined(separator: "\n")
        let generatedSources = try [
            "Sources/AgentryUniFFIRaw/Generated/AgentryCore.swift",
            "Sources/CAgentryRustCore/include/AgentryCoreFFI.h"
        ].map(source).joined(separator: "\n")
        let productionSources = [
            authority,
            adapter,
            directHeadless,
            domainSources,
            bridgeSources,
            rustSources,
            generatedSources
        ].joined(separator: "\n")

        for required in [
            "commandAdmission.publishAuthorityState(",
            "commandAdmission.synchronizeAuthorityProjection(",
            "func workspaceAuthoritativeReadFence(",
            "func authoritativeReadSnapshots()",
            "receipt.previousPublicationSequence == publicationSequence",
            "guard let commandAdmission else { return }",
            "await acquireCommandConvergence()",
            "releaseCommandConvergence()"
        ] {
            XCTAssertTrue(authority.contains(required), "Missing aggregate publication fence: \(required)")
        }
        for required in [
            "core.publishAuthorityState(",
            "core.synchronizeAuthorityProjection(",
            "core.authorityRead(workspaceID:",
            "DomainWorkspaceAuthorityPublicationReceipt("
        ] {
            XCTAssertTrue(adapter.contains(required), "Missing aggregate Domain adapter: \(required)")
        }
        XCTAssertTrue(
            directHeadless.contains("runtime.contextStore.workspaceAuthoritativeReadFence("),
            "Direct-headless must read the actor-captured Rust aggregate row"
        )
        XCTAssertTrue(
            bridgeSources.contains("public struct CoreWorkspaceProjectionPublishedWorkspace"),
            "Shared aggregate projection records must remain in the Bridge"
        )
        XCTAssertTrue(
            rustSources.contains("pub struct WorkspaceProjectionCatalog"),
            "The prepared admission aggregate must retain the bounded Rust projection catalog"
        )
        XCTAssertTrue(
            domainSources.contains(
                "guard lifecycle == .starting, !Task.isCancelled else { return }\n        await workspaceAuthority.bootstrap()"
            ),
            "Cancelled startup must not begin workspace authority bootstrap"
        )

        for retired in [
            "WorkspaceProjectionScopeRegistry",
            "WorkspaceProjectionScopeConfiguration",
            "WorkspaceProjectionScopeHandle",
            "WorkspaceProjectionCheckpointV1",
            "WorkspaceProjectionScopeDiagnostics",
            "workspace_projection_open_scope_v1",
            "DomainWorkspaceStatefulRustProjector",
            "DomainWorkspaceRustProjectionObserver",
            "DomainWorkspaceProjectionObservationSink",
            "workspaceProjectionProjector",
            "loadWorkspaceProjectionCheckpointData(",
            "persistWorkspaceProjectionCheckpointData(",
            "reconcileAuthoritativeWorkspaceProjection(",
            "workspaceRustProjectionObserver.authoritativeWorkspaceProjection(",
            "DomainWorkspaceRustProjection.swiftProjection(",
            "workspace-projection/checkpoint-v1.json",
            "workspaceProjectionOpenScopeV1",
            "workspaceProjectionCloseScopeV1",
            "workspaceProjectionReplaceV1",
            "workspaceProjectionUpsertV1",
            "workspaceProjectionRemoveV1",
            "workspaceProjectionPublishV1",
            "workspaceProjectionExportCheckpointV1",
            "workspaceProjectionRestoreCheckpointV1",
            "workspaceProjectionOpenSnapshotV1",
            "workspaceProjectionSnapshotPageV1",
            "workspaceProjectionCloseSnapshotV1",
            "workspaceProjectionDiagnosticsV1",
            "workspace_projection_open_scope_v1",
            "workspace_projection_replace_v1",
            "workspace_projection_upsert_v1",
            "workspace_projection_remove_v1",
            "workspace_projection_publish_v1",
            "workspace_projection_export_checkpoint_v1",
            "workspace_projection_restore_checkpoint_v1",
            "workspace_projection_open_snapshot_v1",
            "workspace_projection_snapshot_page_v1",
            "workspace_projection_close_snapshot_v1",
            "workspace_projection_diagnostics_v1"
        ] {
            XCTAssertFalse(
                productionSources.contains(retired),
                "Retired projection compatibility surface remains: \(retired)"
            )
        }
        for retiredPath in [
            "Sources/AgentryCoreBridge/CoreWorkspaceProjectionScope.swift",
            "Sources/RepoPromptDomainRuntime/DomainWorkspaceRustProjectionObserver.swift",
            "Tests/RepoPromptDomainRuntimeTests/DomainWorkspaceRustProjectionObserverTests.swift",
            "Tests/RepoPromptDomainRuntimeTests/DomainWorkspaceRustProjectionTests.swift"
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(retiredPath).path),
                "Retired projection compatibility file remains: \(retiredPath)"
            )
        }
    }

    func testClaimBoundWorkspaceLifecycleCompositionHasOneExecutionAuthority() throws {
        let root = repositoryRoot()
        let authority = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainWorkspaceContextAuthority.swift"
            ),
            encoding: .utf8
        )
        let adapter = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainWorkspaceRustJournal.swift"
            ),
            encoding: .utf8
        )
        let persistence = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/DomainPersistence.swift"
            ),
            encoding: .utf8
        )
        let ffi = try String(
            contentsOf: root.appendingPathComponent("rust/crates/ffi/src/api.rs"),
            encoding: .utf8
        )
        let registry = try String(
            contentsOf: root.appendingPathComponent("rust/crates/runtime/src/registry.rs"),
            encoding: .utf8
        )

        for required in [
            "return await withTaskCancellationHandler",
            "cancellationAdmission.cancel(operationID: envelope.operationID)",
            "commandLifecycleStopOutcome(",
            "commandClaim.checkpoint()",
            "finalizeLifecycleCancellation("
        ] {
            XCTAssertTrue(authority.contains(required), "Missing production lifecycle binding: \(required)")
        }
        for required in [
            "func checkpoint() throws -> DomainWorkspaceCommandLifecycleDirective",
            "func cancel(operationID: UUID)",
            "core.cancel(OperationID(",
            "deadlineUnixMilliseconds: UInt64? = nil",
            "CoreBridgeError.operationCancelled",
            "CoreBridgeError.deadlineExpired"
        ] {
            XCTAssertTrue(adapter.contains(required), "Missing typed lifecycle adapter: \(required)")
        }
        XCTAssertGreaterThanOrEqual(
            persistence.components(separatedBy: "transaction.acquireAuthorityPermit()").count - 1,
            4,
            "Every command-backed physical mutation family must cross the Rust authority gate"
        )
        for required in [
            "runtime.attach_managed_operation(managed_request)",
            "begin_managed_authority_operation",
            "finish_workspace_command_authorities",
            "CoreWorkspaceCommandLifecycleDirectiveV1"
        ] {
            XCTAssertTrue(ffi.contains(required), "Missing composite FFI lifecycle seam: \(required)")
        }
        let acquireStart = try XCTUnwrap(
            ffi.range(of: "fn workspace_command_admission_acquire_response(")
        )
        let acquireEnd = try XCTUnwrap(
            ffi.range(
                of: "fn workspace_command_admission_mutation_response(",
                range: acquireStart.upperBound ..< ffi.endIndex
            )
        )
        let workspaceAcquireBoundary = ffi[acquireStart.lowerBound ..< acquireEnd.lowerBound]
        XCTAssertFalse(workspaceAcquireBoundary.contains(".submit("))
        XCTAssertFalse(workspaceAcquireBoundary.contains(".execute("))
        for required in [
            "next_managed_generation",
            "exact_managed_entry_mut",
            "cancel_tombstones",
            "authority_started",
            "ManagedOperationStopReason::Cancelled"
        ] {
            XCTAssertTrue(registry.contains(required), "Missing lifecycle/ABA fence: \(required)")
        }
        for retired in [
            "pendingCommandAdmissions",
            "PendingCommandAdmission",
            "envelope.fingerprint",
            "commandAdmission.preflight(",
            "commandAdmission.decision("
        ] {
            XCTAssertFalse(authority.contains(retired), "Split Swift authority returned: \(retired)")
        }
    }

    func testP58RustOwnsSemanticTransitionAndSwiftSendsIntentOnlyFacts() throws {
        let root = repositoryRoot()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        let rust = try source("rust/crates/runtime/src/workspace_persistence_journal.rs")
        let rustRequestStart = try XCTUnwrap(
            rust.range(of: "struct WorkspaceSaveTransactionRequestV1")
        )
        let rustRequestEnd = try XCTUnwrap(
            rust.range(
                of: "pub enum WorkspaceCreateActionKindV1",
                range: rustRequestStart.upperBound ..< rust.endIndex
            )
        )
        let rustRequests = rust[rustRequestStart.lowerBound ..< rustRequestEnd.lowerBound]
        XCTAssertTrue(rust.contains("pub const WORKSPACE_SEMANTIC_PLANNER_VERSION_V1: u16 = 1;"))
        XCTAssertTrue(rust.contains("catalog_revision: Option<u64>"))
        XCTAssertTrue(rust.contains("recovery_mode: bool"))
        XCTAssertTrue(rust.contains("if request.recovery_mode == operation_facts_present"))
        XCTAssertTrue(
            rust.contains(
                "document_digest.ok_or(WorkspaceWorkingJournalError::InvalidWorkingDocument)?"
            )
        )
        for forbidden in [
            "context_revisions:",
            "context_digests:",
            "context_tombstones:",
            "operations:",
            "new_revision:",
            "new_revisions:",
            "operation: WorkspaceRecordedOperationV1"
        ] {
            XCTAssertFalse(
                rustRequests.contains(forbidden),
                "Semantic transition request still accepts derived state: \(forbidden)"
            )
        }
        for required in [
            "semantic_planner_version: u16",
            "expected_workspace_id: String",
            "expected_file_url: String",
            "expected_working_revision: u64",
            "fingerprint: String",
            "catalog_revision: u64"
        ] {
            XCTAssertTrue(rustRequests.contains(required), "Missing intent-only request fact: \(required)")
        }

        let adapter = try source("Sources/RepoPromptDomainRuntime/DomainWorkspaceRustJournal.swift")
        let adapterRequestStart = try XCTUnwrap(
            adapter.range(of: "private struct DeleteTransactionRequest")
        )
        let adapterRequestEnd = try XCTUnwrap(
            adapter.range(
                of: "struct PreparedCreateTransaction",
                range: adapterRequestStart.upperBound ..< adapter.endIndex
            )
        )
        let adapterRequests = adapter[adapterRequestStart.lowerBound ..< adapterRequestEnd.lowerBound]
        for forbidden in [
            "contextRevisions:",
            "contextTombstones:",
            "operations:",
            "newRevision:",
            "newRevisions:"
        ] {
            XCTAssertFalse(
                adapterRequests.contains(forbidden),
                "Swift transaction request still carries derived state: \(forbidden)"
            )
        }
        for required in [
            "semanticPlannerVersion: UInt16",
            "expectedWorkspaceID: UUID",
            "expectedFileURL: URL",
            "fingerprint: String",
            "catalogRevision: UInt64",
            "recoveryMode: Bool"
        ] {
            XCTAssertTrue(adapterRequests.contains(required), "Missing Swift intent fact: \(required)")
        }

        let authority = try source("Sources/RepoPromptDomainRuntime/DomainWorkspaceContextAuthority.swift")
        let persistence = try source("Sources/RepoPromptDomainRuntime/DomainPersistence.swift")
        for required in [
            "func persistWorkingRecovery(",
            "func persistExternalReloadRecovery(",
            "func persistConflictRebaseRecovery(",
            "recoveryMode: false"
        ] {
            XCTAssertTrue(persistence.contains(required), "Missing explicit recovery/command split: \(required)")
        }
        XCTAssertFalse(
            persistence.contains("commandClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim? = nil"),
            "Command persistence API still permits an unclassified claimless mutation"
        )
        for required in [
            "persistence.persistWorkingRecovery(",
            "persistence.persistExternalObservationRecovery(",
            "persistence.persistConflictRebaseRecovery("
        ] {
            XCTAssertTrue(authority.contains(required), "Recovery path missing explicit boundary: \(required)")
        }
        let commandStart = try XCTUnwrap(authority.range(of: "private func createWorkspace("))
        let commandEnd = try XCTUnwrap(
            authority.range(
                of: "    private func commandPublicationInvalidatesReadRegistration(",
                range: commandStart.upperBound ..< authority.endIndex
            )
        )
        let commandPaths = authority[commandStart.lowerBound ..< commandEnd.lowerBound]
        for forbidden in [
            "Self.updatedContextRevisions(",
            "Self.updatedReadOverlayContextRevisions(",
            "newRevision:",
            "newRevisions:",
            "contextRevisions: context",
            "contextTombstones: context",
            "operations: operations"
        ] {
            XCTAssertFalse(
                commandPaths.contains(forbidden),
                "Durable command/recovery path rebuilt semantic state in Swift: \(forbidden)"
            )
        }
        for required in [
            "private func createWorkspace(",
            "private func deleteWorkspace(",
            "private func replaceWorkingDocument(",
            "private func saveWorkspace(",
            "private func resolveExternalConflict(",
            "persistence.persistCreated(",
            "persistence.persistDeleted(",
            "persistence.persistWorking(",
            "persistence.persistSaved(",
            "persistence.persistExternalReload(",
            "persistence.persistConflictRebase("
        ] {
            XCTAssertTrue(commandPaths.contains(required), "Command path missing expected Rust-owned seam: \(required)")
        }
        let readOverlayStart = try XCTUnwrap(authority.range(of: "func registerReadDocument("))
        let readOverlayEnd = try XCTUnwrap(
            authority.range(
                of: "    func readySnapshot()",
                range: readOverlayStart.upperBound ..< authority.endIndex
            )
        )
        let readOverlayPath = authority[readOverlayStart.lowerBound ..< readOverlayEnd.lowerBound]
        XCTAssertTrue(readOverlayPath.contains("Self.updatedReadOverlayContextRevisions("))
        XCTAssertFalse(commandPaths.contains("DomainRevisionState("))
    }

    func testP59CommandResultReceiptIsRustOwnedAndBoundToPublication() throws {
        let root = repositoryRoot()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        let runtime = try source("rust/crates/runtime/src/workspace_persistence_journal.rs")
        let ffi = try source("rust/crates/ffi/src/api.rs")
        let ffiTypes = try source("rust/crates/ffi/src/types.rs")
        let bridge = try source("Sources/AgentryCoreBridge/CoreBridge.swift")
        let coreModels = try source("Sources/AgentryCoreBridge/CoreWorkspaceDocumentProjection.swift")
        let adapter = try source("Sources/RepoPromptDomainRuntime/DomainWorkspaceRustJournal.swift")
        let persistence = try source("Sources/RepoPromptDomainRuntime/DomainPersistence.swift")
        let authority = try source("Sources/RepoPromptDomainRuntime/DomainWorkspaceContextAuthority.swift")
        let spec = try source("docs/spec/rust-workspace-document-projection-v1.md")

        for required in [
            "enum WorkspaceCommandResultDispositionV1",
            "struct WorkspaceCommandResultV1",
            "pub command_result: Option<WorkspaceCommandResultV1>",
            "fn workspace_command_result_v1(",
            "pub fn command_result(",
            "operation.catalog_revision",
            "operation.resulting_digest"
        ] {
            XCTAssertTrue(runtime.contains(required), "Missing Rust command result authority: \(required)")
        }
        for required in [
            "enum CoreWorkspaceCommandResultDispositionV1",
            "struct CoreWorkspaceCommandResultV1",
            "pub command_result: Option<CoreWorkspaceCommandResultV1>",
            "finish_workspace_command_authorities(",
            "command_result: (command_finalization == CoreWorkspaceCommandFinalizationV1::Reconciled)"
        ] {
            XCTAssertTrue(ffi.contains(required) || ffiTypes.contains(required), "Missing FFI result receipt: \(required)")
        }
        for required in [
            "private static func workspaceCommandResult(",
            "publicationSemanticsValid",
            "workspace command authority finalization is inconsistent",
            "commandFinalization == .reconciled"
        ] {
            XCTAssertTrue(bridge.contains(required), "Missing Bridge receipt fence: \(required)")
        }
        for required in [
            "public struct CoreWorkspaceCommandResultV1",
            "public let commandResult: CoreWorkspaceCommandResultV1?"
        ] {
            XCTAssertTrue(coreModels.contains(required), "Missing Core result model: \(required)")
        }
        for required in [
            "static func materializeCommandResult(",
            "commandResult: commandResult",
            "DomainWorkspaceCommandResult",
            "commandResult = try value.commandResult.map(materializeCommandResult)"
        ] {
            XCTAssertTrue(adapter.contains(required), "Missing Domain result materialization: \(required)")
        }
        XCTAssertTrue(persistence.contains("lhs.commandResult == rhs.commandResult"))
        for required in [
            "private func commandResultOutcome(",
            "let operation = result.operation",
            "workspace_command_result_receipt_missing",
            "result.publicationKind",
            "publication.publicationSequence == self.publicationSequence"
        ] {
            XCTAssertTrue(authority.contains(required), "Missing actor receipt mirror fence: \(required)")
        }
        XCTAssertTrue(spec.contains("## P5-9 amendment — transaction-owned command result receipts"))
        XCTAssertTrue(spec.contains("workspace_command_admission_receipt_missing"))
        for forbidden in [
            "commandAuthorityPublicationCandidate(",
            "DomainWorkspaceAuthorityPublicationCandidate"
        ] {
            XCTAssertFalse(authority.contains(forbidden), "Command path still has an alternate publication authority: \(forbidden)")
        }
    }

    func testP512aProtectedAgentAdmissionIsClaimBoundAndExternalByteExplicit() throws {
        let root = repositoryRoot()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        let authority = try source(
            "Sources/RepoPromptDomainRuntime/DomainWorkspaceContextAuthority.swift"
        )
        let adapter = try source(
            "Sources/RepoPromptDomainRuntime/DomainWorkspaceRustJournal.swift"
        )
        let bridge = try source("Sources/AgentryCoreBridge/CoreBridge.swift")
        let bridgeModels = try source("Sources/AgentryCoreBridge/CoreWorkspaceDocumentProjection.swift")
        let ffi = try source("rust/crates/ffi/src/api.rs")
        let ffiTypes = try source("rust/crates/ffi/src/types.rs")
        let runtime = try source("rust/crates/runtime/src/workspace_persistence_journal.rs")
        let spec = try source("docs/spec/rust-workspace-document-projection-v1.md")

        for required in [
            "let externalDocumentBytes = commandExternalDocument(envelope.command)?.documentBytes",
            "externalDocumentBytes: externalDocumentBytes",
            "diagnostic.hasPrefix(\"protected_agent_identity_\")",
            "case let .resolveExternalConflict(workspaceID, acceptExternal, _)"
        ] {
            XCTAssertTrue(authority.contains(required), "Missing protected-agent admission seam: \(required)")
        }
        XCTAssertTrue(adapter.contains("externalDocumentBytes: Data? = nil"))
        XCTAssertTrue(adapter.contains("externalDocumentDigest: preflight.externalDocumentDigest"))
        XCTAssertTrue(adapter.contains("protectedContextIDs: preflight.protectedContextIDs"))
        XCTAssertTrue(bridge.contains("externalDocumentBytes: externalDocumentBytes"))
        XCTAssertTrue(bridge.contains("externalDocumentDigestIsValid"))
        XCTAssertTrue(bridgeModels.contains("public let protectedContextIDs: [UUID]"))
        XCTAssertTrue(ffi.contains("external_document_bytes: Option<Vec<u8>>"))
        XCTAssertTrue(ffiTypes.contains("pub external_document_digest: Option<String>"))
        XCTAssertTrue(runtime.contains("external_document_digest: Option<String>"))
        XCTAssertTrue(runtime.contains("workspace_protected_agent_conflict_v1("))
        XCTAssertTrue(runtime.contains("protected_agent_identity_precondition_mismatch"))
        XCTAssertTrue(runtime.contains("InvalidOperationLedger"))

        let resolveStart = try XCTUnwrap(authority.range(of: "private func resolveExternalConflict("))
        let resolveEnd = try XCTUnwrap(
            authority.range(
                of: "    private func commandResultOutcome(",
                range: resolveStart.upperBound ..< authority.endIndex
            )
        )
        let resolvePath = authority[resolveStart.lowerBound ..< resolveEnd.lowerBound]
        for retired in [
            "protectedAgentIdentityConflict",
            "protectedAgentIdentities",
            "metadata.agentIdentityClaims"
        ] {
            XCTAssertFalse(
                resolvePath.contains(retired),
                "Swift protected-agent oracle remains in explicit resolution: \(retired)"
            )
        }

        XCTAssertTrue(spec.contains("## P5-12a amendment — claim-bound protected-agent admission"))
        XCTAssertTrue(spec.contains("document bytes remain a separate physical input"))
        XCTAssertTrue(spec.contains("P5-13"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
