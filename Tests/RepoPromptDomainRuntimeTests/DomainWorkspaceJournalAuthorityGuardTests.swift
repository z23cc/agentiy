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
            "candidate.canonicalBytes",
            "validator.planSavedRevision(",
            "validator.validateSavedRevision(",
            "validator.requireRuntimeAvailability()",
            "validator.planDeletionTombstone(",
            "private func readSavedRevisionSnapshot(",
            "savedRevision.canonicalBytes",
            "revision.canonicalBytes",
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
            9,
            "Eight production transition call sites plus the single helper must stay Rust-owned"
        )
        for transition in [
            ".seed(",
            ".recoverPending(",
            ".create(",
            ".unchanged(",
            ".working(",
            ".save(",
            ".externalReload(",
            ".conflictRebase("
        ] {
            XCTAssertTrue(source.contains(transition), "Missing Rust transition: \(transition)")
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
