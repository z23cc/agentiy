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
            "Self.trimmedOperations("
        ] {
            XCTAssertFalse(source.contains(forbidden), "Swift journal authority returned: \(forbidden)")
        }
        for required in [
            "private func readRawJournalSnapshot(",
            "validator.validateSynchronously(",
            "private func planJournalTransition(",
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
            "validator.planDeletionTombstone(",
            "private func readSavedRevisionSnapshot(",
            "case let .writeSavedRevision(actionID, validation):",
            "authorityReceipt.savedRevision == nil",
            "validation.canonicalBytes",
            "plannedTombstone.canonicalBytes",
            "cleanupPlan.canonicalBytes",
            "allowsCancellation: false",
            "if isJournalInfrastructureFailure(error)"
        ] {
            XCTAssertTrue(source.contains(required), "Missing Rust journal boundary: \(required)")
        }
        XCTAssertEqual(
            source.components(separatedBy: "planJournalTransition(").count - 1,
            2,
            "Only seed/recovery composition plus the single helper may use the generic Rust planner"
        )
        XCTAssertTrue(source.contains(".seed("), "Missing Rust seed transition")
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
            "validator.planCatalogTransition(",
            "validator.beginCreateTransaction(",
            "validator.beginCreateRecoveryTransaction(",
            "validator.beginDeleteTransaction(",
            "createTransactionLoop: while true",
            "deleteTransactionLoop: while true",
            "private func recoverInterruptedCreates(",
            "transition: .seed("
        ] {
            XCTAssertTrue(source.contains(required), "Missing Rust catalog boundary: \(required)")
        }
        XCTAssertEqual(
            source.components(separatedBy: "validator.planCatalogTransition(").count - 1,
            1,
            "Only shared load/migration seed remains on the generic Rust catalog planner"
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
        XCTAssertFalse(deleteAuthority.contains("transition: .delete("))
        XCTAssertTrue(deleteAuthority.contains("validator.beginDeleteTransaction("))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
