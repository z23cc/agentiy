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
            "validator.amendDeletionTombstoneCleanup(",
            "private func readSavedRevisionSnapshot(",
            "postAuthoritySuccessFinalization",
            "postAuthorityFailureFinalization",
            "finalization: postAuthoritySuccessFinalization",
            "activatedFinalization = postAuthorityFailureFinalization",
            "func activatedOutcome()",
            "func activatedCommit()",
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

    func testStandaloneMetadataPlannersAreRustInternalOnlyAndCleanupAmendmentIsNarrow() throws {
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
            "validator.validateDeletionTombstone(",
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
            source.contains("let catalogSnapshot = try loadCurrentCatalog(now: now, validator: validator)"),
            "Migration must reuse the guarded Rust catalog seed path"
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
            of: "let catalogSnapshot = try loadCurrentCatalog(now: now, validator: validator)"
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
        XCTAssertFalse(deleteAuthority.contains("validator.amendDeletionTombstoneCleanup("))
        XCTAssertFalse(deleteAuthority.contains("transition: .delete("))
        XCTAssertTrue(deleteAuthority.contains("validator.beginDeleteTransaction("))
        let cleanupEnd = try XCTUnwrap(source.range(
            of: "private func finalizeDeletedWorkspaceArtifacts(",
            range: cleanupStart.lowerBound ..< source.endIndex
        ))
        let postAuthorityCleanup = source[cleanupStart.lowerBound ..< cleanupEnd.lowerBound]
        XCTAssertEqual(
            postAuthorityCleanup.components(
                separatedBy: "validator.amendDeletionTombstoneCleanup("
            ).count - 1,
            2,
            "Only post-authority cleanup may amend the non-authoritative tombstone diagnostic"
        )
    }

    func testCommandIdentityCandidateDoesNotPrematurelyReplaceSwiftMutationAdmission() throws {
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

        XCTAssertEqual(
            authority.components(separatedBy: "envelope.fingerprint").count - 1,
            3,
            "P5-6a remains comparison-only; Swift must retain all production identity reads"
        )
        XCTAssertFalse(
            authority.contains("commandIdentity("),
            "Rust parity candidate must not become production admission before the cutover gate"
        )
        XCTAssertTrue(adapter.contains("func commandIdentity("))
        XCTAssertTrue(adapter.contains("core.commandIdentity("))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
