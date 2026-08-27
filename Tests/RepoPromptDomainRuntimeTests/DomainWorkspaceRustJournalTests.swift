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

    func testPreparedCommandIdentityMatchesFrozenSwiftOracleForEveryCommandAndOrigin() async throws {
        let workspaceID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/CommandIdentity-\(workspaceID.uuidString).json")
        func document(_ marker: String) -> DomainWorkspaceDocument {
            DomainWorkspaceDocument(
                workspaceID: workspaceID,
                fileURL: fileURL,
                documentBytes: Data(marker.utf8),
                metadata: DomainWorkspaceMetadata(
                    workspaceID: workspaceID,
                    schemaVersion: 1,
                    name: "Workspace",
                    repoPaths: [],
                    customStoragePath: nil,
                    isSystemWorkspace: false,
                    isHiddenInMenus: false,
                    isEphemeral: false,
                    activeContextID: nil,
                    contexts: []
                )
            )
        }
        let protected = [
            DomainProtectedAgentIdentity(
                tabID: try XCTUnwrap(UUID(
                    uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff"
                )),
                location: .stashed,
                activeAgentSessionID: nil,
                isPinned: false
            ),
            DomainProtectedAgentIdentity(
                tabID: try XCTUnwrap(UUID(
                    uuidString: "00000000-0000-0000-0000-000000000001"
                )),
                location: .composed,
                activeAgentSessionID: try XCTUnwrap(UUID(
                    uuidString: "abcdefab-cdef-abcd-efab-cdefabcdefab"
                )),
                isPinned: true
            )
        ]
        let envelopes = [
            DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                expectedCatalogRevision: nil,
                expectedWorkspaceRevision: nil,
                expectedContextRevision: nil,
                origin: .appPresentation(windowID: 42),
                command: .createWorkspace(document("create"))
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                expectedCatalogRevision: 7,
                expectedWorkspaceRevision: 8,
                expectedContextRevision: 9,
                origin: .appMCP(connectionID: UUID()),
                command: .replaceWorkingDocument(document("replace"))
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                expectedWorkspaceRevision: 3,
                origin: .appMCP(connectionID: nil),
                command: .saveWorkspaceDocument(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                expectedCatalogRevision: 4,
                expectedWorkspaceRevision: 5,
                origin: .standalone,
                command: .deleteWorkspace(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                expectedWorkspaceRevision: 6,
                expectedContextRevision: 7,
                origin: .externalReload,
                command: .resolveExternalConflict(
                    workspaceID: workspaceID,
                    acceptExternal: false,
                    protectedAgentIdentities: protected
                )
            )
        ]
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        for envelope in envelopes {
            XCTAssertEqual(try prepared.commandIdentity(envelope), envelope.fingerprint)
        }
        let reversed = DomainWorkspaceCommandEnvelope(
            operationID: envelopes[4].operationID,
            expectedWorkspaceRevision: 6,
            expectedContextRevision: 7,
            origin: .externalReload,
            command: .resolveExternalConflict(
                workspaceID: workspaceID,
                acceptExternal: false,
                protectedAgentIdentities: Array(protected.reversed())
            )
        )
        XCTAssertEqual(reversed.fingerprint, envelopes[4].fingerprint)
        XCTAssertEqual(try prepared.commandIdentity(reversed), envelopes[4].fingerprint)
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

    func testPreparedValidatorSeedsMissingJournalWithRustOwnedScalarValidation() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Seeded-\(workspaceID.uuidString).json")
        let savedDigest = String(repeating: "a", count: 64)
        let contextDigests = [contextID: String(repeating: "b", count: 64)]
        let updatedAt = Date(timeIntervalSinceReferenceDate: 12)
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        let seeded = try prepared.seedWorkingJournal(
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: .initial,
            savedDigest: savedDigest,
            contextDigests: contextDigests,
            updatedAt: updatedAt
        )
        let repeated = try prepared.seedWorkingJournal(
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: .initial,
            savedDigest: savedDigest,
            contextDigests: contextDigests,
            updatedAt: updatedAt
        )

        XCTAssertEqual(seeded.journal, repeated.journal)
        XCTAssertEqual(seeded.canonicalBytes, repeated.canonicalBytes)
        XCTAssertEqual(seeded.contentDigest, repeated.contentDigest)
        XCTAssertEqual(seeded.journal.workspaceID, workspaceID)
        XCTAssertEqual(seeded.journal.fileURL, fileURL)
        XCTAssertEqual(seeded.journal.revisions, .initial)
        XCTAssertEqual(seeded.journal.savedDigest, savedDigest)
        XCTAssertEqual(seeded.journal.contextDigests, contextDigests)
        XCTAssertNil(seeded.journal.pendingSave)
        XCTAssertNil(seeded.journal.workingDocument)

        XCTAssertThrowsError(try prepared.seedWorkingJournal(
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: DomainRevisionState(
                workingRevision: 0,
                savedRevision: 1,
                dirtyRevision: nil
            ),
            savedDigest: savedDigest,
            contextDigests: contextDigests,
            updatedAt: updatedAt
        )) { error in
            XCTAssertEqual(
                error as? DomainPersistenceError,
                .writeFailed("working_journal_transition_invalid")
            )
        }
    }

    func testPreparedValidatorValidatesMetadataAndAmendsOnlyDeletionCleanupDiagnostic() async throws {
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

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let savedRecord = DomainSavedRevisionRecord(
            version: DomainSavedRevisionRecord.schemaVersion,
            workspaceID: workspaceID,
            savedRevision: 9,
            documentDigest: documentDigest,
            operationID: operationID,
            updatedAt: timestamp
        )
        let validatedSaved = try prepared.validateSavedRevision(
            encoder.encode(savedRecord),
            expectedWorkspaceID: workspaceID,
            expectedDocumentDigest: documentDigest
        )
        XCTAssertEqual(validatedSaved.record, savedRecord)
        XCTAssertEqual(DomainContentDigest.sha256(validatedSaved.canonicalBytes), validatedSaved.contentDigest)
        XCTAssertThrowsError(try prepared.validateSavedRevision(
            validatedSaved.canonicalBytes,
            expectedWorkspaceID: workspaceID,
            expectedDocumentDigest: String(repeating: "0", count: 64)
        )) { error in
            XCTAssertEqual(error as? DomainPersistenceError, .corruptJournal)
        }

        let originalTombstone = DomainDeletionTombstone(
            version: DomainDeletionTombstone.schemaVersion,
            workspaceID: workspaceID,
            fileURL: fileURL,
            operation: operation,
            deletedAt: timestamp
        )
        let authoritative = try prepared.validateDeletionTombstone(
            encoder.encode(originalTombstone)
        )
        XCTAssertEqual(authoritative.tombstone, originalTombstone)
        XCTAssertNil(authoritative.tombstone.operation.diagnostic)
        XCTAssertEqual(
            DomainContentDigest.sha256(authoritative.canonicalBytes),
            authoritative.contentDigest
        )

        let warnings = ["revision sidecar: denied", "workspace document: busy"]
        let amended = try prepared.amendDeletionTombstoneCleanup(
            authoritative: authoritative,
            cleanupWarnings: warnings
        )
        XCTAssertEqual(amended.tombstone.workspaceID, originalTombstone.workspaceID)
        XCTAssertEqual(amended.tombstone.fileURL, originalTombstone.fileURL)
        XCTAssertEqual(amended.tombstone.deletedAt, originalTombstone.deletedAt)
        XCTAssertEqual(amended.tombstone.operation.operationID, originalTombstone.operation.operationID)
        XCTAssertEqual(amended.tombstone.operation.fingerprint, originalTombstone.operation.fingerprint)
        XCTAssertEqual(amended.tombstone.operation.before, originalTombstone.operation.before)
        XCTAssertEqual(amended.tombstone.operation.after, originalTombstone.operation.after)
        XCTAssertEqual(
            amended.tombstone.operation.diagnostic,
            "artifact_cleanup_incomplete: \(warnings.joined(separator: "; "))"
        )
    }

    func testPreparedValidatorSeedsAndValidatesRustOwnedCatalog() async throws {
        let workspaceID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Catalog-\(workspaceID.uuidString).json")
        let seedTime = Date(timeIntervalSinceReferenceDate: 30)
        let entries: [DomainPersistenceCoordinator.RuntimeWorkspaceCatalog.Entry] = [
            .init(workspaceID: workspaceID, fileURL: fileURL)
        ]
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        let seed = try prepared.seedCatalog(entries: entries, updatedAt: seedTime)
        let repeated = try prepared.seedCatalog(entries: entries, updatedAt: seedTime)
        XCTAssertEqual(seed.catalog.revision, 0)
        XCTAssertEqual(seed.catalog.entries, entries)
        XCTAssertEqual(seed.catalog.deletions, [])
        XCTAssertEqual(seed.canonicalBytes, repeated.canonicalBytes)
        XCTAssertEqual(seed.contentDigest, repeated.contentDigest)
        XCTAssertEqual(
            try prepared.validateCatalog(seed.canonicalBytes).catalog,
            seed.catalog
        )
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
