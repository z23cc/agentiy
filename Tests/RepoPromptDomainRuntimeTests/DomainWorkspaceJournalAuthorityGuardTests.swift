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
            1,
            "Only the typed Rust seed adapter may materialize a missing production journal"
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
            1,
            "Only the missing-journal path may invoke the dedicated Rust seed endpoint"
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
            "unrecordedCommandIdentityRejection("
        ] {
            XCTAssertTrue(authority.contains(required), "Missing Rust acquisition boundary: \(required)")
        }
        for retired in [
            "resolveCommandIdentity(",
            "resolveCommandPreflight(",
            "preflight =",
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
        XCTAssertFalse(adapter.contains("func preflight("))
        XCTAssertFalse(adapter.contains("core.preflight("))
        XCTAssertFalse(adapter.contains("core.decision("))
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
            ".admissionRecovery"
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
            "let commandFinalization: DomainWorkspaceCommandFinalization",
            "commandFinalization: transaction.finishCommandAuthority()",
            "commandFinalization: result.commandFinalization",
            "commandFinalization: finalization.commandFinalization"
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
            "public func finishCommandAuthority(",
            "public func planCleanup("
        ] {
            XCTAssertTrue(coreBridge.contains(required), "Missing typed Core finalization: \(required)")
        }
        for required in [
            "pub enum CoreWorkspaceCommandFinalizationV1",
            "fn finish_workspace_command_authorities(",
            "pub fn plan_cleanup("
        ] {
            XCTAssertTrue(rustFFI.contains(required), "Missing transaction-owned FFI finalization: \(required)")
        }
        XCTAssertTrue(rustJournal.contains("pub fn cleanup_plan("))
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

    func testAggregateProjectionAuthorityRetiresProductionObserverRepairAndCheckpointPaths() throws {
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
        let directHeadless = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptMCP/DirectHeadlessDomainContext.swift"
            ),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RepoPromptDomainRuntime/RepoPromptDomainRuntime.swift"
            ),
            encoding: .utf8
        )

        for required in [
            "commandAdmission.publishAuthorityState(",
            "commandAdmission.synchronizeAuthorityProjection(",
            "func workspaceAuthoritativeReadFence(",
            "func authoritativeReadSnapshots()",
            "receipt.previousPublicationSequence == publicationSequence",
            "guard let commandAdmission else { return }"
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
            runtime.contains("let comparisonProjector: DomainWorkspaceRustProjectionObserver.Projector"),
            "Production observer must remain comparison-only"
        )
        for retired in [
            "projectionObservationSink.observePublication(",
            "reconcileAuthoritativeWorkspaceProjection(",
            "workspaceRustProjectionObserver.authoritativeWorkspaceProjection(",
            "DomainWorkspaceRustProjection.swiftProjection(",
            "publicationSequence &+= 1"
        ] {
            XCTAssertFalse(authority.contains(retired), "Retired authority observer path remains: \(retired)")
            XCTAssertFalse(directHeadless.contains(retired), "Retired direct-headless repair remains: \(retired)")
        }
        for retired in [
            "activateWorkspaceRustProjectionIfPossible(",
            "workspaceProjectionLeaseToken",
            "loadWorkspaceProjectionCheckpointData()",
            "persistWorkspaceProjectionCheckpointData("
        ] {
            XCTAssertFalse(runtime.contains(retired), "Retired production checkpoint path remains: \(retired)")
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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
