import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceRustJournalTests: XCTestCase {
    func testRustValidationRoundTripsSwiftV1JournalAndRejectsIdentityMismatch() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let revisions = DomainRevisionState(
            workingRevision: 1,
            savedRevision: 0,
            dirtyRevision: 1
        )
        let documentBytes = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Workspace",
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": "working",
                "selectedPaths": []
            ]]
        ], options: [.sortedKeys])
        let operationID = UUID()
        let operation = DomainRecordedOperation(
            fingerprint: String(repeating: "c", count: 64),
            recordedAt: Date(timeIntervalSinceReferenceDate: 41.5),
            outcome: DomainCommandOutcome(
                operationID: operationID,
                disposition: .applied,
                before: .initial,
                after: revisions,
                catalogRevision: 1,
                resultingDigest: DomainContentDigest.sha256(documentBytes)
            )
        )
        let journal = DomainWorkingJournal(
            workspaceID: workspaceID,
            fileURL: URL(fileURLWithPath: "/tmp/Workspace.json"),
            revisions: revisions,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: documentBytes,
            contextRevisions: [contextID: revisions],
            contextDigests: [contextID: String(repeating: "b", count: 64)],
            contextTombstones: [:],
            operations: [operation],
            pendingSave: DomainPendingSave(
                operationID: operationID,
                documentDigest: DomainContentDigest.sha256(documentBytes)
            ),
            updatedAt: Date(timeIntervalSinceReferenceDate: 42.5)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(journal)
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }

        let validated = try await DomainWorkspaceRustJournal.validate(
            bytes,
            expectedWorkspaceID: workspaceID,
            coreService: service
        )

        XCTAssertEqual(validated.journal.workspaceID, workspaceID)
        XCTAssertEqual(validated.journal.revisions, revisions)
        XCTAssertEqual(validated.journal.operations, [operation])
        XCTAssertEqual(validated.journal.pendingSave?.operationID, operationID)
        XCTAssertEqual(
            DomainContentDigest.sha256(validated.canonicalBytes),
            validated.contentDigest
        )
        do {
            _ = try await DomainWorkspaceRustJournal.validate(
                bytes,
                expectedWorkspaceID: UUID(),
                coreService: service
            )
            XCTFail("mismatched workspace identity unexpectedly validated")
        } catch {
            XCTAssertEqual(error as? DomainPersistenceError, .corruptJournal)
        }
    }

    func testPreparedValidatorRunsSynchronouslyAndMatchesAsyncBoundary() async throws {
        let workspaceID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Prepared-\(workspaceID.uuidString).json")
        let journal = DomainWorkingJournal(
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: .initial,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: nil,
            contextRevisions: [:],
            contextDigests: [:],
            contextTombstones: [:],
            operations: [],
            updatedAt: Date(timeIntervalSinceReferenceDate: 7.5)
        )
        let bytes = try JSONEncoder().encode(journal)
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        let synchronous = try await Task.detached {
            try prepared.validateSynchronously(
                bytes,
                expectedWorkspaceID: workspaceID,
                expectedFileURL: fileURL
            )
        }.value
        let asynchronous = try await DomainWorkspaceRustJournal.validate(
            bytes,
            expectedWorkspaceID: workspaceID,
            expectedFileURL: fileURL,
            coreService: service
        )

        XCTAssertEqual(synchronous.journal, journal)
        XCTAssertEqual(synchronous.canonicalBytes, asynchronous.canonicalBytes)
        XCTAssertEqual(synchronous.contentDigest, asynchronous.contentDigest)
        XCTAssertThrowsError(try prepared.validateSynchronously(
            bytes,
            expectedWorkspaceID: workspaceID,
            expectedFileURL: URL(fileURLWithPath: "/tmp/other.json")
        )) { error in
            XCTAssertEqual(error as? DomainPersistenceError, .corruptJournal)
        }
    }

    func testPreparedValidatorPlansCreateAndPendingRecoveryWithRustOwnedBytes() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let operationID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Planned-\(workspaceID.uuidString).json")
        let documentBytes = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "composeTabs": [["id": contextID.uuidString]]
        ], options: [.sortedKeys])
        let dirty = DomainRevisionState(
            workingRevision: 1,
            savedRevision: 0,
            dirtyRevision: 1
        )
        let operation = DomainRecordedOperation(
            fingerprint: String(repeating: "c", count: 64),
            recordedAt: Date(timeIntervalSinceReferenceDate: 11),
            outcome: DomainCommandOutcome(
                operationID: operationID,
                disposition: .applied,
                before: nil,
                after: dirty,
                catalogRevision: 1,
                resultingDigest: DomainContentDigest.sha256(documentBytes)
            )
        )
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        let create = try prepared.planTransition(
            current: nil,
            transition: .create(
                workspaceID: workspaceID,
                fileURL: fileURL,
                contextRevisions: [contextID: dirty],
                contextDigests: [contextID: String(repeating: "b", count: 64)],
                operation: operation,
                operationID: operationID,
                updatedAt: Date(timeIntervalSinceReferenceDate: 12)
            ),
            documentBytes: documentBytes
        )
        let committed = try XCTUnwrap(create.committed)
        XCTAssertEqual(create.primary.journal.revisions, dirty)
        XCTAssertEqual(create.primary.journal.pendingSave?.operationID, operationID)
        XCTAssertEqual(committed.journal.revisions.savedRevision, 1)
        XCTAssertNil(committed.journal.pendingSave)
        XCTAssertNil(committed.journal.workingDocument)

        let recovered = try prepared.planTransition(
            current: create.primary.journal,
            transition: .recoverPending(expectedWorkspaceID: workspaceID)
        )
        XCTAssertNil(recovered.committed)
        XCTAssertEqual(recovered.primary.canonicalBytes, committed.canonicalBytes)

        XCTAssertThrowsError(try prepared.planTransition(
            current: committed.journal,
            transition: .conflictRebase(
                expectedRevisions: committed.journal.revisions,
                newRevisions: DomainRevisionState(
                    workingRevision: 3,
                    savedRevision: 1,
                    dirtyRevision: 3
                ),
                externalSavedDigest: DomainContentDigest.sha256(documentBytes),
                contextRevisions: committed.journal.contextRevisions,
                contextDigests: committed.journal.contextDigests,
                contextTombstones: [:],
                operations: committed.journal.operations,
                updatedAt: Date(timeIntervalSinceReferenceDate: 13)
            ),
            documentBytes: documentBytes
        )) { error in
            XCTAssertEqual(error as? DomainPersistenceError, .invalidWorkspaceDocument)
        }

        XCTAssertThrowsError(try prepared.planTransition(
            current: committed.journal,
            transition: .conflictRebase(
                expectedRevisions: committed.journal.revisions,
                newRevisions: committed.journal.revisions,
                externalSavedDigest: DomainContentDigest.sha256(documentBytes),
                contextRevisions: [
                    contextID: DomainRevisionState(
                        workingRevision: 0,
                        savedRevision: 1,
                        dirtyRevision: nil
                    )
                ],
                contextDigests: committed.journal.contextDigests,
                contextTombstones: [:],
                operations: committed.journal.operations,
                updatedAt: Date(timeIntervalSinceReferenceDate: 14)
            )
        )) { error in
            XCTAssertEqual(
                error as? DomainPersistenceError,
                .writeFailed("working_journal_transition_invalid")
            )
        }
    }

    func testPreparedValidatorPlansSavedRevisionAndDeletionMetadataWithRustOwnedBytes() async throws {
        let workspaceID = UUID()
        let operationID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Deleted-\(workspaceID.uuidString).json")
        let documentDigest = DomainContentDigest.sha256(Data("saved document".utf8))
        let timestamp = Date(timeIntervalSinceReferenceDate: 21.5)
        let operation = DomainRecordedOperation(
            fingerprint: String(repeating: "d", count: 64),
            recordedAt: timestamp,
            outcome: DomainCommandOutcome(
                operationID: operationID,
                disposition: .applied,
                before: DomainRevisionState(
                    workingRevision: 9,
                    savedRevision: 9,
                    dirtyRevision: nil
                ),
                after: nil,
                catalogRevision: 7,
                resultingDigest: documentDigest
            )
        )
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        let saved = try prepared.planSavedRevision(
            workspaceID: workspaceID,
            savedRevision: 9,
            documentDigest: documentDigest,
            operationID: operationID,
            updatedAt: timestamp
        )
        let validatedSaved = try prepared.validateSavedRevision(
            saved.canonicalBytes,
            expectedWorkspaceID: workspaceID,
            expectedDocumentDigest: documentDigest
        )
        XCTAssertEqual(saved.record, validatedSaved.record)
        XCTAssertEqual(saved.record.savedRevision, 9)
        XCTAssertEqual(saved.record.updatedAt, timestamp)
        XCTAssertEqual(saved.canonicalBytes, validatedSaved.canonicalBytes)
        XCTAssertEqual(DomainContentDigest.sha256(saved.canonicalBytes), saved.contentDigest)
        XCTAssertThrowsError(try prepared.validateSavedRevision(
            saved.canonicalBytes,
            expectedWorkspaceID: workspaceID,
            expectedDocumentDigest: String(repeating: "0", count: 64)
        )) { error in
            XCTAssertEqual(error as? DomainPersistenceError, .corruptJournal)
        }

        let plainTombstone = try prepared.planDeletionTombstone(
            workspaceID: workspaceID,
            fileURL: fileURL,
            operation: operation,
            deletedAt: timestamp
        )
        XCTAssertEqual(plainTombstone.tombstone.workspaceID, workspaceID)
        XCTAssertEqual(plainTombstone.tombstone.deletedAt, timestamp)
        XCTAssertEqual(plainTombstone.tombstone.operation, operation)
        XCTAssertNil(plainTombstone.tombstone.operation.diagnostic)
        XCTAssertEqual(
            DomainContentDigest.sha256(plainTombstone.canonicalBytes),
            plainTombstone.contentDigest
        )

        let warnings = ["revision sidecar: denied", "workspace document: busy"]
        let warningTombstone = try prepared.planDeletionTombstone(
            workspaceID: workspaceID,
            fileURL: fileURL,
            operation: operation,
            deletedAt: timestamp,
            cleanupWarnings: warnings
        )
        XCTAssertEqual(
            warningTombstone.tombstone.operation.diagnostic,
            "artifact_cleanup_incomplete: \(warnings.joined(separator: "; "))"
        )
        XCTAssertEqual(warningTombstone.tombstone.operation.operationID, operationID)
    }

    func testPreparedValidatorFailsClosedAfterItsExactRuntimeStops() async throws {
        let workspaceID = UUID()
        let journal = DomainWorkingJournal(
            workspaceID: workspaceID,
            fileURL: URL(fileURLWithPath: "/tmp/Stopped-\(workspaceID.uuidString).json"),
            revisions: .initial,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: nil,
            contextRevisions: [:],
            contextDigests: [:],
            contextTombstones: [:],
            operations: [],
            updatedAt: Date(timeIntervalSinceReferenceDate: 9.5)
        )
        let bytes = try JSONEncoder().encode(journal)
        let service = AgentryCoreService()
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)
        await service.shutdown()

        XCTAssertThrowsError(try prepared.requireRuntimeAvailability()) { error in
            XCTAssertEqual(
                error as? DomainPersistenceError,
                .writeFailed("working_journal_rust_unavailable")
            )
        }
        XCTAssertThrowsError(try prepared.validateSynchronously(
            bytes,
            expectedWorkspaceID: workspaceID,
            expectedFileURL: journal.fileURL
        )) { error in
            XCTAssertEqual(
                error as? DomainPersistenceError,
                .writeFailed("working_journal_rust_unavailable")
            )
        }
    }

    func testInvalidAndFutureJournalFailuresRemainTypedWithoutSwiftSemanticFallback() async throws {
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }

        do {
            _ = try await DomainWorkspaceRustJournal.validate(
                Data("[]".utf8),
                coreService: service
            )
            XCTFail("invalid journal unexpectedly validated")
        } catch {
            XCTAssertEqual(error as? DomainPersistenceError, .corruptJournal)
        }

        let future = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "workspaceID": UUID().uuidString,
            "fileURL": "file:///tmp/Workspace.json",
            "revisions": ["workingRevision": 0, "savedRevision": 0],
            "savedDigest": String(repeating: "a", count: 64),
            "contextRevisions": [],
            "contextDigests": [],
            "contextTombstones": [],
            "operations": [],
            "updatedAt": 1.0
        ], options: [.sortedKeys])
        do {
            _ = try await DomainWorkspaceRustJournal.validate(
                future,
                coreService: service
            )
            XCTFail("future journal unexpectedly validated")
        } catch {
            XCTAssertEqual(error as? DomainPersistenceError, .futureJournal(2))
        }
    }
}
