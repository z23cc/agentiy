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
            "validator.beginSaveTransaction(",
            "transaction.nextDirective()",
            "transaction.report(",
            "validator.resolvePendingSave(",
            "deletionSidecarDiagnostic(",
            "case let .publishWorkspaceDocument(",
            "case let .writeCommittedJournal(",
            "candidate.canonicalBytes",
            "validator.planSavedRevision(",
            "validator.validateSavedRevision(",
            "validator.requireRuntimeAvailability()",
            "validator.planDeletionTombstone(",
            "private func readSavedRevisionSnapshot(",
            "savedRevision.canonicalBytes",
            "case let .writeSavedRevision(actionID, validation):",
            "validation.canonicalBytes",
            "revisionRecord.canonicalBytes",
            "plannedTombstone.canonicalBytes",
            "cleanupPlan.canonicalBytes",
            "allowsCancellation: false",
            "if isJournalInfrastructureFailure(error)"
        ] {
            XCTAssertTrue(source.contains(required), "Missing Rust journal boundary: \(required)")
        }
        XCTAssertEqual(
            source.components(separatedBy: "planJournalTransition(").count - 1,
            7,
            "Six non-save transition call sites plus the single helper must stay Rust-owned"
        )
        for transition in [
            ".seed(",
            ".create(",
            ".unchanged(",
            ".working(",
            ".externalReload(",
            ".conflictRebase("
        ] {
            XCTAssertTrue(source.contains(transition), "Missing Rust transition: \(transition)")
        }
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
            "validator.beginDeleteTransaction(",
            "deleteTransactionLoop: while true",
            "transition: .seed(",
            "transition: .upsert(",
            "transition: .recoverCreate("
        ] {
            XCTAssertTrue(source.contains(required), "Missing Rust catalog boundary: \(required)")
        }
        XCTAssertEqual(
            source.components(separatedBy: "validator.planCatalogTransition(").count - 1,
            3,
            "Create, recovery, and shared load/migration seed must stay Rust-owned"
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
