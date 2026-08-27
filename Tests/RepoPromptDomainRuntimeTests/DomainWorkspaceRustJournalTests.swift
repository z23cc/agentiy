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

    func testPreparedCommandIdentityIsStableAndCanonicalForEveryCommandAndOrigin() async throws {
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
        let operationID = UUID()
        let envelopes = [
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedCatalogRevision: nil,
                expectedWorkspaceRevision: nil,
                expectedContextRevision: nil,
                origin: .appPresentation(windowID: 42),
                command: .createWorkspace(document("create"))
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedCatalogRevision: 7,
                expectedWorkspaceRevision: 8,
                expectedContextRevision: 9,
                origin: .appMCP(connectionID: UUID()),
                command: .replaceWorkingDocument(document("replace"))
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedWorkspaceRevision: 3,
                origin: .appMCP(connectionID: nil),
                command: .saveWorkspaceDocument(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedCatalogRevision: 4,
                expectedWorkspaceRevision: 5,
                origin: .standalone,
                command: .deleteWorkspace(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
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

        let fingerprints = try envelopes.map { envelope in
            let fingerprint = try prepared.commandIdentity(envelope)
            XCTAssertEqual(try prepared.commandIdentity(envelope), fingerprint)
            XCTAssertEqual(fingerprint.count, 64)
            XCTAssertNotNil(fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
            return fingerprint
        }
        XCTAssertEqual(Set(fingerprints).count, envelopes.count)

        let fieldIsolationEnvelopes = [
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                origin: .standalone,
                command: .saveWorkspaceDocument(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                origin: .externalReload,
                command: .saveWorkspaceDocument(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedWorkspaceRevision: 1,
                origin: .standalone,
                command: .saveWorkspaceDocument(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                origin: .standalone,
                command: .deleteWorkspace(workspaceID: workspaceID)
            )
        ]
        XCTAssertEqual(
            Set(try fieldIsolationEnvelopes.map(prepared.commandIdentity)).count,
            fieldIsolationEnvelopes.count,
            "command kind, origin, and revision fences must each affect Rust identity"
        )
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
        XCTAssertEqual(try prepared.commandIdentity(reversed), fingerprints[4])
    }

    func testPreparedCommandAdmissionRoundTripsCompleteDomainReceipt() async throws {
        let workspaceID = UUID()
        let operationID = UUID()
        let revisions = DomainRevisionState(
            workingRevision: 3,
            savedRevision: 2,
            dirtyRevision: 3
        )
        let outcome = DomainCommandOutcome(
            operationID: operationID,
            disposition: .applied,
            before: nil,
            after: revisions,
            catalogRevision: 7,
            resultingDigest: String(repeating: "a", count: 64)
        )
        let operation = DomainRecordedOperation(
            fingerprint: String(repeating: "f", count: 64),
            recordedAt: Date(timeIntervalSinceReferenceDate: 42.5),
            outcome: outcome
        )
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let validator = try await DomainWorkspaceRustJournal.prepare(coreService: service)
        let admission = try validator.beginCommandAdmission(records: [
            .init(workspaceID: workspaceID, operation: operation),
        ])
        defer { admission.close() }

        XCTAssertEqual(
            try admission.decision(
                workspaceID: workspaceID,
                operationID: operationID,
                fingerprint: operation.fingerprint
            ),
            .replay(scope: .workspace, operation: operation)
        )
        XCTAssertEqual(
            try admission.decision(
                workspaceID: workspaceID,
                operationID: operationID,
                fingerprint: String(repeating: "e", count: 64)
            ),
            .collision(scope: .workspace)
        )

        let preflightEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: 7,
            expectedWorkspaceRevision: 3,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: workspaceID)
        )
        let preflightInput = try XCTUnwrap(DomainWorkspaceCommandIdentityInput(preflightEnvelope))
        let unseenPreflight = try admission.preflight(preflightInput)
        XCTAssertEqual(unseenPreflight.decision, .unseen)
        let preflightOperation = DomainRecordedOperation(
            fingerprint: unseenPreflight.fingerprint,
            recordedAt: Date(timeIntervalSinceReferenceDate: 43),
            outcome: DomainCommandOutcome(
                operationID: preflightEnvelope.operationID,
                disposition: .unchanged,
                before: revisions,
                after: revisions,
                catalogRevision: 7,
                resultingDigest: nil
            )
        )
        _ = try admission.insert(workspaceID: workspaceID, operation: preflightOperation)
        XCTAssertEqual(
            try admission.preflight(preflightInput).decision,
            .replay(scope: .workspace, operation: preflightOperation)
        )

        let transient = DomainRecordedOperation(
            fingerprint: String(repeating: "d", count: 64),
            recordedAt: Date(timeIntervalSinceReferenceDate: 43.5),
            outcome: DomainCommandOutcome(
                operationID: UUID(),
                disposition: .applied,
                before: revisions,
                after: revisions,
                catalogRevision: 7,
                resultingDigest: String(repeating: "b", count: 64)
            )
        )
        _ = try admission.insert(workspaceID: nil, operation: transient)
        let durableReplacement = DomainRecordedOperation(
            fingerprint: String(repeating: "c", count: 64),
            recordedAt: Date(timeIntervalSinceReferenceDate: 44.5),
            outcome: DomainCommandOutcome(
                operationID: UUID(),
                disposition: .unchanged,
                before: revisions,
                after: revisions,
                catalogRevision: 8,
                resultingDigest: String(repeating: "b", count: 64)
            )
        )
        _ = try admission.reconcileDurable([
            .init(workspaceID: workspaceID, operation: durableReplacement),
        ])
        XCTAssertEqual(
            try admission.decision(
                workspaceID: workspaceID,
                operationID: transient.operationID,
                fingerprint: transient.fingerprint
            ),
            .replay(scope: .global, operation: transient)
        )
        XCTAssertEqual(
            try admission.decision(
                workspaceID: workspaceID,
                operationID: durableReplacement.operationID,
                fingerprint: durableReplacement.fingerprint
            ),
            .replay(scope: .workspace, operation: durableReplacement)
        )

        _ = try admission.removeWorkspace(workspaceID)
        XCTAssertEqual(
            try admission.decision(
                workspaceID: workspaceID,
                operationID: operationID,
                fingerprint: operation.fingerprint
            ),
            .replay(scope: .global, operation: operation)
        )
        admission.close()
        XCTAssertThrowsError(try admission.diagnostics()) { error in
            XCTAssertEqual(
                error as? DomainPersistenceError,
                .writeFailed("workspace_save_transaction_invalid")
            )
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

    func testProductionDeduplicationAndCollisionUseInjectedRustIdentity() async throws {
        let directory = temporaryDirectory(name: "command-identity-authority")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = CommandIdentityAuthorityResolverScript(steps: [
            .value(String(repeating: "a", count: 64)),
            .value(String(repeating: "b", count: 64))
        ])
        let runtime = MCPDomainRuntime(
            configuration: commandIdentityConfiguration(directory: directory),
            workspaceProjectionProjector: { _ in
                throw CommandIdentityAuthorityTestError.projectorFailed
            },
            workspaceCommandIdentityResolver: { input in
                try await resolver.resolve(input)
            }
        )
        try await runtime.start()
        let envelope = commandIdentityEnvelope()

        let first = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(first.disposition, .invalid)
        XCTAssertEqual(first.errorCode, .workspaceUnavailable)
        let second = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(second.disposition, .invalid)
        XCTAssertEqual(second.errorCode, .operationIDCollision)
        let invocationCount = await resolver.invocationCount
        XCTAssertEqual(invocationCount, 2)
        _ = await runtime.shutdown()
    }

    func testRustIdentityFailureDoesNotRecordOperationAndRetryCanProceed() async throws {
        let directory = temporaryDirectory(name: "command-identity-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rustFingerprint = String(repeating: "c", count: 64)
        let resolver = CommandIdentityAuthorityResolverScript(steps: [
            .failure,
            .value(rustFingerprint),
            .value(rustFingerprint)
        ])
        let runtime = MCPDomainRuntime(
            configuration: commandIdentityConfiguration(directory: directory),
            workspaceProjectionProjector: { _ in
                throw CommandIdentityAuthorityTestError.projectorFailed
            },
            workspaceCommandIdentityResolver: { input in
                try await resolver.resolve(input)
            }
        )
        try await runtime.start()
        let envelope = commandIdentityEnvelope()

        let rejected = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(rejected.disposition, .readOnly)
        XCTAssertEqual(rejected.errorCode, .runtimeReadOnlyDegraded)
        XCTAssertEqual(rejected.diagnostic, "workspace_command_identity_rust_unavailable")
        let retried = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(retried.disposition, .invalid)
        XCTAssertEqual(retried.errorCode, .workspaceUnavailable)
        let deduplicated = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(deduplicated.disposition, .deduplicated)
        XCTAssertEqual(deduplicated.errorCode, .workspaceUnavailable)
        _ = await runtime.shutdown()
    }

    func testCancellationAfterResolverSuccessDoesNotRecordOperation() async throws {
        let directory = temporaryDirectory(name: "command-identity-cancelled")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = CommandIdentityAuthorityCancellationResolver()
        let runtime = MCPDomainRuntime(
            configuration: commandIdentityConfiguration(directory: directory),
            workspaceProjectionProjector: { _ in
                throw CommandIdentityAuthorityTestError.projectorFailed
            },
            workspaceCommandIdentityResolver: { input in
                await resolver.resolve(input)
            }
        )
        try await runtime.start()
        let envelope = commandIdentityEnvelope()
        let cancelledTask = Task { await runtime.workspaceStore.execute(envelope) }
        let resolverStarted = await waitForCommandIdentityResolver { await resolver.hasStarted }
        XCTAssertTrue(resolverStarted)

        cancelledTask.cancel()
        await resolver.release()
        let cancelled = await cancelledTask.value
        XCTAssertEqual(cancelled.disposition, .failed)
        XCTAssertEqual(cancelled.errorCode, .cancelled)
        XCTAssertEqual(cancelled.diagnostic, "workspace_command_identity_cancelled")

        let retried = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(retried.disposition, .invalid)
        XCTAssertEqual(retried.errorCode, .workspaceUnavailable)
        _ = await runtime.shutdown()
    }

    private func commandIdentityEnvelope() -> DomainWorkspaceCommandEnvelope {
        DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: 1,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: UUID())
        )
    }

    private func commandIdentityConfiguration(directory: URL) -> DomainRuntimeConfiguration {
        DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "command-identity-authority-\(UUID().uuidString)",
            storageDirectory: directory,
            eventDirectory: directory.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: directory.appendingPathComponent("Temp", isDirectory: true),
            externalReloadInterval: nil
        )
    }

    private func temporaryDirectory(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPrompt-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func waitForCommandIdentityResolver(
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< 200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private enum CommandIdentityAuthorityTestError: Error {
    case projectorFailed
}

private actor CommandIdentityAuthorityCancellationResolver {
    private(set) var hasStarted = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var invocationCount = 0

    func resolve(_: DomainWorkspaceCommandIdentityInput) async -> String {
        invocationCount += 1
        if invocationCount == 1 {
            hasStarted = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            return String(repeating: "d", count: 64)
        }
        return String(repeating: "e", count: 64)
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CommandIdentityAuthorityResolverScript {
    enum Step: Sendable {
        case value(String)
        case failure
    }

    private var steps: [Step]
    private(set) var invocationCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func resolve(_: DomainWorkspaceCommandIdentityInput) throws -> String {
        invocationCount += 1
        guard !steps.isEmpty else {
            throw CommandIdentityAuthorityTestError.projectorFailed
        }
        switch steps.removeFirst() {
        case let .value(value):
            return value
        case .failure:
            throw CommandIdentityAuthorityTestError.projectorFailed
        }
    }
}
