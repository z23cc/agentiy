import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceRustProjectionObserverTests: XCTestCase {
    func testComparisonReportsDuplicateRustContextIdentityWithoutTrapping() async throws {
        let value = try document(name: "Duplicate Context")
        let expected = try DomainWorkspaceRustProjection.swiftProjection(value)
        let context = try XCTUnwrap(expected.contexts.first)
        let actual = DomainWorkspaceDocumentReadProjection(
            workspaceID: expected.workspaceID,
            schemaVersion: expected.schemaVersion,
            name: expected.name,
            repoPaths: expected.repoPaths,
            activeContextID: expected.activeContextID,
            contexts: expected.contexts + [context]
        )

        let fields = DomainWorkspaceRustProjection.mismatchFields(
            expected: expected,
            actual: actual
        )

        XCTAssertTrue(fields.contains(.contextCount))
        XCTAssertTrue(fields.contains(.contextOrder))
    }

    func testObserverQuarantinesExactMismatchDigestAndRecoversOnNewDigest() async throws {
        let workspaceID = UUID()
        let metrics = MetricCollector()
        let script = MismatchThenMatchProjector()
        let observer = makeObserver(metrics: metrics.sink) { data in
            try await script.project(data)
        }
        await observer.start()

        let first = try document(
            workspaceID: workspaceID,
            name: "First",
            prompt: "SECRET_PROMPT_SENTINEL",
            selectedPaths: ["/SECRET/PATH/SENTINEL.swift"]
        )
        observer.sink.observe(first, source: .workspaceRead)
        observer.sink.observe(first, source: .canonicalWorkspaceRead)
        let observedMismatch = await waitFor { await observer.snapshot().mismatchedCount == 1 }
        XCTAssertTrue(observedMismatch)
        let firstCallCount = await script.callCount()
        XCTAssertEqual(firstCallCount, 1)

        observer.sink.observe(first, source: .catalogSnapshot)
        let quarantinedSnapshot = await observer.snapshot()
        XCTAssertGreaterThanOrEqual(quarantinedSnapshot.deduplicatedCount, 2)
        let quarantinedCallCount = await script.callCount()
        XCTAssertEqual(quarantinedCallCount, 1, "the quarantined digest must not be retried")

        let second = try document(
            workspaceID: workspaceID,
            name: "Second",
            prompt: "SECRET_PROMPT_SENTINEL",
            selectedPaths: ["/SECRET/PATH/SENTINEL.swift"]
        )
        observer.sink.observe(second, source: .commandOutcome)
        let observedRecovery = await waitFor {
            let snapshot = await observer.snapshot()
            return snapshot.matchedCount == 1 && snapshot.recoveredCount == 1
        }
        XCTAssertTrue(observedRecovery)
        let recoveredCallCount = await script.callCount()
        XCTAssertEqual(recoveredCallCount, 2)

        let recordedDimensions = metrics.snapshot().flatMap { $0.dimensions.values }
        XCTAssertFalse(recordedDimensions.contains { $0.contains("SECRET_PROMPT_SENTINEL") })
        XCTAssertFalse(recordedDimensions.contains { $0.contains("SECRET/PATH") })
        await observer.shutdown()
    }

    func testObserverBoundsPendingQueueAndUsesLatestOldestEviction() async throws {
        let gate = ControlledProjector()
        let observer = makeObserver(
            limits: .init(
                maximumPendingDocumentCount: 2,
                maximumRetainedInputBytes: 1024 * 1024,
                maximumDocumentBytes: 1024 * 1024,
                maximumCompletedWorkspaceCount: 8
            )
        ) { data in
            try await gate.project(data)
        }
        await observer.start()

        let first = try document(name: "First")
        observer.sink.observe(first, source: .workspaceRead)
        await gate.waitUntilFirstProjectionStarted()

        let second = try document(name: "Second")
        let third = try document(name: "Third")
        let fourth = try document(name: "Fourth")
        observer.sink.observe(second, source: .workspaceRead)
        observer.sink.observe(third, source: .workspaceRead)
        observer.sink.observe(fourth, source: .workspaceRead)

        let bounded = await observer.snapshot()
        XCTAssertTrue(bounded.hasActiveProjection)
        XCTAssertEqual(bounded.pendingDocumentCount, 2)
        XCTAssertEqual(bounded.droppedCount, 1)
        XCTAssertGreaterThan(bounded.activeInputBytes, 0)
        XCTAssertGreaterThan(bounded.pendingInputBytes, 0)

        await gate.releaseFirstProjection()
        let drained = await waitFor { await observer.snapshot().matchedCount == 3 }
        XCTAssertTrue(drained)
        let projectedWorkspaceIDs = await gate.projectedWorkspaceIDs()
        XCTAssertEqual(projectedWorkspaceIDs, [first.workspaceID, third.workspaceID, fourth.workspaceID])
        await observer.shutdown()
    }

    func testReobservedCompletedDigestSupersedesDifferentActiveProjection() async throws {
        let workspaceID = UUID()
        let gate = SecondProjectionGate()
        let observer = makeObserver { data in
            try await gate.project(data)
        }
        await observer.start()
        let first = try document(workspaceID: workspaceID, name: "Digest-A")
        let second = try document(workspaceID: workspaceID, name: "Digest-B")
        observer.sink.observe(first, source: .workspaceRead)
        let firstCompleted = await waitFor { await observer.snapshot().matchedCount == 1 }
        XCTAssertTrue(firstCompleted)

        observer.sink.observe(second, source: .workspaceRead)
        await gate.waitUntilSecondProjectionStarted()
        observer.sink.observe(first, source: .workspaceRead)
        await gate.releaseSecondProjection()
        let superseded = await waitFor { await observer.snapshot().ignoredLateResultCount == 1 }
        XCTAssertTrue(superseded)

        observer.sink.observe(first, source: .catalogSnapshot)
        let callCount = await gate.callCount()
        XCTAssertEqual(callCount, 2, "the latest completed digest must remain deduplicated")
        let snapshot = await observer.snapshot()
        XCTAssertEqual(snapshot.matchedCount, 1)
        XCTAssertEqual(snapshot.completedWorkspaceCount, 1)
        await observer.shutdown()
    }

    func testObserverEnforcesActivePlusPendingByteBound() async throws {
        let gate = ControlledProjector()
        let first = try document(name: "ByteActive", prompt: String(repeating: "a", count: 512))
        let second = try document(name: "ByteEvicted", prompt: String(repeating: "b", count: 512))
        let third = try document(name: "ByteLatest", prompt: String(repeating: "c", count: 512))
        let observer = makeObserver(
            limits: .init(
                maximumPendingDocumentCount: 8,
                maximumRetainedInputBytes: first.documentBytes.count + third.documentBytes.count,
                maximumDocumentBytes: 4096,
                maximumCompletedWorkspaceCount: 8
            )
        ) { data in
            try await gate.project(data)
        }
        await observer.start()
        observer.sink.observe(first, source: .workspaceRead)
        await gate.waitUntilFirstProjectionStarted()

        observer.sink.observe(second, source: .workspaceRead)
        observer.sink.observe(third, source: .workspaceRead)

        let bounded = await observer.snapshot()
        XCTAssertEqual(bounded.pendingDocumentCount, 1)
        XCTAssertEqual(bounded.pendingInputBytes, third.documentBytes.count)
        XCTAssertEqual(bounded.droppedCount, 1)
        await gate.releaseFirstProjection()
        let drained = await waitFor { await observer.snapshot().matchedCount == 2 }
        XCTAssertTrue(drained)
        let projectedWorkspaceIDs = await gate.projectedWorkspaceIDs()
        XCTAssertEqual(projectedWorkspaceIDs, [first.workspaceID, third.workspaceID])
        await observer.shutdown()
    }

    func testObserverBoundsCompletedDigestStateAndEvictedDigestRetries() async throws {
        let projector = CountingProjector()
        let observer = makeObserver(
            limits: .init(
                maximumPendingDocumentCount: 8,
                maximumRetainedInputBytes: 1024 * 1024,
                maximumDocumentBytes: 1024 * 1024,
                maximumCompletedWorkspaceCount: 2
            )
        ) { data in
            try await projector.project(data)
        }
        await observer.start()
        let first = try document(name: "LRU-First")
        let second = try document(name: "LRU-Second")
        let third = try document(name: "LRU-Third")
        observer.sink.observe(first, source: .workspaceRead)
        observer.sink.observe(second, source: .workspaceRead)
        let firstPair = await waitFor { await observer.snapshot().matchedCount == 2 }
        XCTAssertTrue(firstPair)

        observer.sink.observe(first, source: .catalogSnapshot)
        observer.sink.observe(third, source: .workspaceRead)
        let thirdCompleted = await waitFor { await observer.snapshot().matchedCount == 3 }
        XCTAssertTrue(thirdCompleted)
        let completedWorkspaceCount = await observer.snapshot().completedWorkspaceCount
        XCTAssertEqual(completedWorkspaceCount, 2)

        observer.sink.observe(first, source: .workspaceRead)
        observer.sink.observe(second, source: .workspaceRead)
        let retried = await waitFor { await observer.snapshot().matchedCount == 4 }
        XCTAssertTrue(retried)
        let callCount = await projector.callCount()
        XCTAssertEqual(callCount, 4, "touching the first digest must evict and retry the second")
        await observer.shutdown()
    }

    func testOversizedDocumentUsesMetadataOnlyFailureWithoutCallingProjector() async throws {
        let projector = CountingProjector()
        let observer = makeObserver(
            limits: .init(
                maximumPendingDocumentCount: 2,
                maximumRetainedInputBytes: 1024,
                maximumDocumentBytes: 64,
                maximumCompletedWorkspaceCount: 2
            )
        ) { data in
            try await projector.project(data)
        }
        await observer.start()
        let oversized = try document(name: "Oversized", prompt: String(repeating: "x", count: 512))
        XCTAssertGreaterThan(oversized.documentBytes.count, 64)

        observer.sink.observe(oversized, source: .workspaceRead)

        let failed = await waitFor { await observer.snapshot().failedCount == 1 }
        XCTAssertTrue(failed)
        let snapshot = await observer.snapshot()
        XCTAssertFalse(snapshot.hasActiveProjection)
        XCTAssertEqual(snapshot.pendingDocumentCount, 0)
        XCTAssertEqual(snapshot.activeInputBytes + snapshot.pendingInputBytes, 0)
        let callCount = await projector.callCount()
        XCTAssertEqual(callCount, 0)
        await observer.shutdown()
    }

    func testShutdownClosesIngressClearsPendingAndIgnoresCancelledResult() async throws {
        let firstStarted = AsyncSignal()
        let observer = makeObserver { data in
            await firstStarted.signal()
            try await Task.sleep(for: .seconds(60))
            let document = try DomainWorkspaceDocument.decode(
                documentBytes: data,
                fileURL: URL(fileURLWithPath: "/tmp/projection-shutdown.json")
            )
            return try DomainWorkspaceRustProjection.swiftProjection(document)
        }
        await observer.start()
        observer.sink.observe(try document(name: "Active"), source: .workspaceRead)
        await firstStarted.wait()
        observer.sink.observe(try document(name: "Pending"), source: .workspaceRead)

        await observer.shutdown()
        let stopped = await observer.snapshot()
        XCTAssertFalse(stopped.isAcceptingObservations)
        XCTAssertFalse(stopped.hasActiveProjection)
        XCTAssertEqual(stopped.pendingDocumentCount, 0)
        XCTAssertEqual(stopped.completedWorkspaceCount, 0)
        XCTAssertEqual(stopped.matchedCount, 0)
        XCTAssertEqual(stopped.ignoredLateResultCount, 1)

        observer.sink.observe(try document(name: "AfterStop"), source: .workspaceRead)
        let afterStoppedObservation = await observer.snapshot()
        XCTAssertEqual(afterStoppedObservation, stopped)
    }

    func testRuntimeReadReturnsWhileProjectionIsSuspended() async throws {
        let directory = temporaryDirectory(name: "ProjectionNonBlocking")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = ControlledProjector()
        let runtime = MCPDomainRuntime(
            configuration: configuration(directory: directory),
            workspaceProjectionProjector: { data in
                try await gate.project(data)
            }
        )
        try await runtime.start()
        let value = try document(name: "Visible")

        let returned = await runtime.workspaceStore.registerReadDocument(value)

        XCTAssertEqual(returned.document.contentDigest, value.contentDigest)
        await gate.waitUntilFirstProjectionStarted()
        let suspendedSnapshot = await runtime.workspaceRustProjectionObserver.snapshot()
        XCTAssertTrue(suspendedSnapshot.hasActiveProjection)
        await gate.releaseFirstProjection()
        let completed = await waitFor {
            await runtime.workspaceRustProjectionObserver.snapshot().matchedCount == 1
        }
        XCTAssertTrue(completed)
        _ = await runtime.shutdown()
    }

    func testStatefulRustProjectorEvictsLeastRecentlyUsedWorkspacesBeforeCapacity() async throws {
        let projector = DomainWorkspaceStatefulRustProjector(
            scopeID: UUID(),
            maximumRetainedWorkspaceCount: 2
        )
        let first = try document(name: "Rust-LRU-First")
        let second = try document(name: "Rust-LRU-Second")
        let third = try document(name: "Rust-LRU-Third")

        let firstProjection = try await projector.project(documentBytes: first.documentBytes)
        XCTAssertEqual(firstProjection.name, "Rust-LRU-First")
        let secondProjection = try await projector.project(documentBytes: second.documentBytes)
        XCTAssertEqual(secondProjection.name, "Rust-LRU-Second")
        _ = try await projector.project(documentBytes: first.documentBytes)
        let thirdProjection = try await projector.project(documentBytes: third.documentBytes)
        XCTAssertEqual(thirdProjection.name, "Rust-LRU-Third")
        let reloadedSecondProjection = try await projector.project(documentBytes: second.documentBytes)
        XCTAssertEqual(reloadedSecondProjection.name, "Rust-LRU-Second")
        let evictedFirst = try await projector.readWorkspace(workspaceID: first.workspaceID)
        XCTAssertNil(evictedFirst.projection, "the least-recently-used first workspace should have been evicted")
        let reconciledFirst = try await projector.project(documentBytes: first.documentBytes)
        XCTAssertEqual(reconciledFirst.name, "Rust-LRU-First")
        let rereadFirst = try await projector.readWorkspace(workspaceID: first.workspaceID)
        let expectedFirst = try DomainWorkspaceRustProjection.swiftProjection(first)
        XCTAssertEqual(rereadFirst.projection, expectedFirst)
        await projector.shutdown()
    }

    func testInjectedComparisonProjectorCannotServeAuthoritativeReads() async throws {
        let observer = makeObserver { data in
            let value = try DomainWorkspaceDocument.decode(
                documentBytes: data,
                fileURL: URL(fileURLWithPath: "/tmp/comparison-only.json")
            )
            return try DomainWorkspaceRustProjection.swiftProjection(value)
        }
        await observer.start()

        do {
            _ = try await observer.authoritativeWorkspaceProjection(workspaceID: UUID())
            XCTFail("comparison-only projector must not reactivate Swift read authority")
        } catch DomainWorkspaceStatefulRustProjectionError.authoritativeReadUnavailable {
            // Expected.
        }
        await observer.shutdown()
    }

    func testStatefulRustProjectorReadsCommittedWorkspaceWithoutMutatingGeneration() async throws {
        let projector = DomainWorkspaceStatefulRustProjector(scopeID: UUID())
        let value = try document(
            name: "Rust Read Authority",
            prompt: "authoritative prompt"
        )
        let expected = try DomainWorkspaceRustProjection.swiftProjection(value)

        _ = try await projector.project(documentBytes: value.documentBytes)
        let first = try await projector.readWorkspace(workspaceID: value.workspaceID)
        let second = try await projector.readWorkspace(workspaceID: value.workspaceID)

        XCTAssertEqual(first.projection, expected)
        XCTAssertNil(first.authority, "document-only projection cannot claim revision/health authority")
        XCTAssertEqual(second.projection, expected)
        XCTAssertNil(second.authority)
        XCTAssertEqual(first.generation, second.generation)
        XCTAssertEqual(first.catalogRevision, 0)
        XCTAssertEqual(first.publicationSequence, 0)
        let missing = try await projector.readWorkspace(workspaceID: UUID())
        XCTAssertNil(missing.projection)
        XCTAssertEqual(missing.generation, first.generation)
        XCTAssertEqual(missing.catalogRevision, first.catalogRevision)
        XCTAssertEqual(missing.publicationSequence, first.publicationSequence)
        await projector.shutdown()
    }

    func testStatefulRustProjectorReadCarriesAtomicPublicationCursor() async throws {
        let projector = DomainWorkspaceStatefulRustProjector(scopeID: UUID())
        let value = try document(name: "Rust Cursor Authority")
        let revisions = DomainRevisionState(
            workingRevision: 4,
            savedRevision: 3,
            dirtyRevision: 4
        )
        let workspace = snapshot(
            document: value,
            revisions: revisions,
            health: .externalConflict(reason: "external_update")
        )
        let publication = try await projector.publish(
            workspaces: [workspace],
            event: publicationEvent(
                sequence: 7,
                catalogRevision: 4,
                workspaceID: value.workspaceID
            )
        )
        XCTAssertEqual(publication.receipt.publicationSequence, 7)
        XCTAssertEqual(publication.receipt.catalogRevision, 4)

        let read = try await projector.readWorkspace(workspaceID: value.workspaceID)
        XCTAssertEqual(read.projection, try DomainWorkspaceRustProjection.swiftProjection(value))
        XCTAssertEqual(read.authority, DomainWorkspaceRustProjection.authorityProjection(workspace))
        XCTAssertEqual(read.generation, publication.receipt.generation)
        XCTAssertEqual(read.catalogRevision, 4)
        XCTAssertEqual(read.publicationSequence, 7)
        XCTAssertEqual(read.eventLogFloorSequence, 7)
        XCTAssertEqual(read.eventLogCount, 1)
        await projector.shutdown()
    }

    func testDocumentOnlyMutationInvalidatesCompleteAuthoritySidecar() async throws {
        let projector = DomainWorkspaceStatefulRustProjector(scopeID: UUID())
        let workspaceID = UUID()
        let before = try document(workspaceID: workspaceID, name: "Before")
        let workspace = snapshot(
            document: before,
            revisions: .init(workingRevision: 1, savedRevision: 0, dirtyRevision: 1),
            health: .writable
        )
        _ = try await projector.publish(
            workspaces: [workspace],
            event: publicationEvent(sequence: 1, catalogRevision: 1, workspaceID: workspaceID)
        )
        let authoritative = try await projector.readWorkspace(workspaceID: workspaceID)
        XCTAssertNotNil(authoritative.authority)

        let changed = try document(workspaceID: workspaceID, name: "After")
        _ = try await projector.project(documentBytes: changed.documentBytes)
        let invalidated = try await projector.readWorkspace(workspaceID: workspaceID)
        XCTAssertEqual(invalidated.projection?.name, "After")
        XCTAssertNil(invalidated.authority)
        XCTAssertEqual(invalidated.catalogRevision, 1)
        XCTAssertEqual(invalidated.publicationSequence, 1)
        await projector.shutdown()
    }

    func testStatefulRustProjectorRejectsStaleReconciliationAfterNewerRemoval() async throws {
        let projector = DomainWorkspaceStatefulRustProjector(scopeID: UUID())
        let value = try document(name: "Removed Before Repair")
        _ = try await projector.publish(
            documents: [value],
            event: publicationEvent(
                sequence: 7,
                catalogRevision: 4,
                workspaceID: value.workspaceID
            )
        )
        let stale = try await projector.readWorkspace(workspaceID: value.workspaceID)
        _ = try await projector.publish(
            documents: [],
            event: publicationEvent(
                sequence: 8,
                catalogRevision: 5,
                workspaceID: value.workspaceID
            )
        )

        do {
            _ = try await projector.reconcileWorkspace(
                workspace: DomainWorkspaceSnapshot(
                    document: value,
                    revisions: .initial,
                    health: .writable,
                    contexts: value.metadata.contexts.map {
                        DomainContextSnapshot(metadata: $0, revisions: .initial, health: .writable)
                    }
                ),
                expectedGeneration: stale.generation,
                expectedCatalogRevision: stale.catalogRevision,
                expectedPublicationSequence: stale.publicationSequence,
                validateLease: {}
            )
            XCTFail("stale reconciliation unexpectedly resurrected a removed workspace")
        } catch DomainWorkspaceStatefulRustProjectionError.authoritativeFenceMismatch {
            // Expected.
        }
        let current = try await projector.readWorkspace(workspaceID: value.workspaceID)
        XCTAssertNil(current.projection)
        XCTAssertEqual(current.catalogRevision, 5)
        XCTAssertEqual(current.publicationSequence, 8)
        await projector.shutdown()
    }

    func testPublicationObserverPreservesSequenceAndMarksExplicitRebase() async throws {
        let recorder = PublicationRecorder()
        let observer = makeObserver(
            publicationProjector: { documents, event in
                await recorder.publish(documents: documents, event: event)
            },
            projector: { data in
                let document = try DomainWorkspaceDocument.decode(
                    documentBytes: data,
                    fileURL: URL(fileURLWithPath: "/tmp/publication-projection.json")
                )
                return try DomainWorkspaceRustProjection.swiftProjection(document)
            }
        )
        await observer.start()
        let value = try document(name: "Publication")

        observer.sink.observePublication(
            publicationEvent(sequence: 10, catalogRevision: 4, workspaceID: value.workspaceID),
            documents: [value]
        )
        observer.sink.observePublication(
            publicationEvent(sequence: 11, catalogRevision: 5, workspaceID: value.workspaceID),
            documents: [value]
        )

        let completed = await waitFor { await observer.snapshot().publicationMatchedCount == 2 }
        XCTAssertTrue(completed)
        let snapshot = await observer.snapshot()
        XCTAssertEqual(snapshot.publicationRebasedCount, 1)
        XCTAssertEqual(snapshot.publicationFailedCount, 0)
        let sequences = await recorder.sequences()
        XCTAssertEqual(sequences, [10, 11])
        await observer.shutdown()
    }

    func testPublicationObserverBoundsPendingCatalogSnapshots() async throws {
        let gate = ControlledPublicationProjector()
        let observer = makeObserver(
            limits: .init(
                maximumPendingDocumentCount: 2,
                maximumRetainedInputBytes: 1024 * 1024,
                maximumDocumentBytes: 1024 * 1024,
                maximumCompletedWorkspaceCount: 2,
                maximumPendingPublicationCount: 2
            ),
            publicationProjector: { documents, event in
                await gate.publish(documents: documents, event: event)
            },
            projector: { data in
                let document = try DomainWorkspaceDocument.decode(
                    documentBytes: data,
                    fileURL: URL(fileURLWithPath: "/tmp/publication-bound.json")
                )
                return try DomainWorkspaceRustProjection.swiftProjection(document)
            }
        )
        await observer.start()
        let value = try document(name: "Bounded Publication")
        observer.sink.observePublication(
            publicationEvent(sequence: 1, catalogRevision: 1, workspaceID: value.workspaceID),
            documents: [value]
        )
        await gate.waitUntilFirstPublicationStarted()
        for sequence in 2 ... 4 {
            observer.sink.observePublication(
                publicationEvent(
                    sequence: UInt64(sequence),
                    catalogRevision: UInt64(sequence),
                    workspaceID: value.workspaceID
                ),
                documents: [value]
            )
        }

        let bounded = await observer.snapshot()
        XCTAssertEqual(bounded.pendingPublicationCount, 2)
        XCTAssertEqual(bounded.publicationDroppedCount, 1)
        XCTAssertGreaterThan(bounded.pendingPublicationInputBytes, 0)
        await gate.releaseFirstPublication()
        let drained = await waitFor { await observer.snapshot().publicationMatchedCount == 3 }
        XCTAssertTrue(drained)
        let sequences = await gate.sequences()
        XCTAssertEqual(sequences, [1, 3, 4])
        await observer.shutdown()
    }

    func testOversizedPublicationUsesMetadataOnlyFailureWithoutCallingProjector() async throws {
        let recorder = PublicationRecorder()
        let observer = makeObserver(
            limits: .init(
                maximumPendingDocumentCount: 2,
                maximumRetainedInputBytes: 1024,
                maximumDocumentBytes: 64,
                maximumCompletedWorkspaceCount: 2,
                maximumPendingPublicationCount: 2
            ),
            publicationProjector: { documents, event in
                await recorder.publish(documents: documents, event: event)
            },
            projector: { data in
                let document = try DomainWorkspaceDocument.decode(
                    documentBytes: data,
                    fileURL: URL(fileURLWithPath: "/tmp/oversized-publication.json")
                )
                return try DomainWorkspaceRustProjection.swiftProjection(document)
            }
        )
        await observer.start()
        let oversized = try document(name: "Oversized Publication", prompt: String(repeating: "x", count: 512))
        XCTAssertGreaterThan(oversized.documentBytes.count, 64)

        observer.sink.observePublication(
            publicationEvent(sequence: 1, catalogRevision: 1, workspaceID: oversized.workspaceID),
            documents: [oversized]
        )

        let failed = await waitFor { await observer.snapshot().publicationFailedCount == 1 }
        XCTAssertTrue(failed)
        let snapshot = await observer.snapshot()
        XCTAssertEqual(snapshot.pendingPublicationCount, 0)
        XCTAssertEqual(snapshot.pendingPublicationInputBytes, 0)
        let sequences = await recorder.sequences()
        XCTAssertEqual(sequences, [])
        await observer.shutdown()
    }

    func testDocumentAndPublicationIngressShareOneRetainedByteBudget() async throws {
        let gate = ControlledProjector()
        let recorder = PublicationRecorder()
        let active = try document(name: "Shared Budget Active", prompt: String(repeating: "a", count: 512))
        let publication = try document(name: "Shared Budget Publication", prompt: String(repeating: "b", count: 512))
        let maximumRetainedInputBytes = max(active.documentBytes.count, publication.documentBytes.count)
        let observer = makeObserver(
            limits: .init(
                maximumPendingDocumentCount: 2,
                maximumRetainedInputBytes: maximumRetainedInputBytes,
                maximumDocumentBytes: max(active.documentBytes.count, publication.documentBytes.count) + 1,
                maximumCompletedWorkspaceCount: 2,
                maximumPendingPublicationCount: 2
            ),
            publicationProjector: { documents, event in
                await recorder.publish(documents: documents, event: event)
            },
            projector: { data in
                try await gate.project(data)
            }
        )
        await observer.start()
        observer.sink.observe(active, source: .workspaceRead)
        await gate.waitUntilFirstProjectionStarted()

        observer.sink.observePublication(
            publicationEvent(sequence: 1, catalogRevision: 1, workspaceID: publication.workspaceID),
            documents: [publication]
        )

        let bounded = await observer.snapshot()
        XCTAssertEqual(bounded.publicationDroppedCount, 1)
        XCTAssertEqual(bounded.pendingPublicationCount, 0)
        XCTAssertLessThanOrEqual(
            bounded.activeInputBytes + bounded.pendingInputBytes + bounded.pendingPublicationInputBytes,
            maximumRetainedInputBytes
        )
        let sequences = await recorder.sequences()
        XCTAssertEqual(sequences, [])
        await gate.releaseFirstProjection()
        let drained = await waitFor { await observer.snapshot().matchedCount == 1 }
        XCTAssertTrue(drained)
        await observer.shutdown()
    }

    func testProductionCheckpointRestoresNonemptyProjectionAcrossRuntimeRestart() async throws {
        let directory = temporaryDirectory(name: "ProjectionCheckpointRestart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = configuration(directory: directory)
        let workspaceID = UUID()
        let workspaceFileURL = configuration.workspaceStorageDirectory
            .appendingPathComponent("Restarted-\(workspaceID.uuidString)", isDirectory: true)
            .appendingPathComponent("workspace.json")
        let value = try document(
            workspaceID: workspaceID,
            name: "Restarted",
            prompt: "durable projection",
            fileURL: workspaceFileURL
        )

        let first = MCPDomainRuntime(configuration: configuration)
        try await first.start()
        let initial = await first.workspaceStore.snapshot()
        let created = await first.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: initial.catalogRevision,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(value)
        ))
        XCTAssertEqual(created.disposition, .applied)
        let firstPersisted = await waitFor(timeoutIterations: 500) {
            await first.workspaceRustProjectionObserver.snapshot().checkpointPersistedCount >= 3
        }
        XCTAssertTrue(firstPersisted)
        let loadedFirstCheckpoint = try await first.persistenceCoordinator.loadWorkspaceProjectionCheckpointData()
        let firstCheckpoint = try XCTUnwrap(loadedFirstCheckpoint)
        let firstObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: firstCheckpoint) as? [String: Any]
        )
        let firstGeneration = try XCTUnwrap((firstObject["generation"] as? NSNumber)?.uint64Value)
        let firstEntries = try XCTUnwrap(firstObject["entries"] as? [[String: Any]])
        let firstContentDigest = try XCTUnwrap(firstEntries.first?["contentDigest"] as? String)
        XCTAssertGreaterThan(firstGeneration, 0)
        _ = await first.shutdown()

        let second = MCPDomainRuntime(configuration: configuration)
        try await second.start()
        let recovered = await waitFor(timeoutIterations: 500) {
            let snapshot = await second.workspaceRustProjectionObserver.snapshot()
            return snapshot.checkpointRecoveredCount == 1
                && snapshot.checkpointPersistedCount >= 2
                && snapshot.publicationMatchedCount >= 1
        }
        let recoverySnapshot = await second.workspaceRustProjectionObserver.snapshot()
        XCTAssertTrue(recovered, "restart recovery did not settle: \(recoverySnapshot)")
        XCTAssertEqual(recoverySnapshot.checkpointRecoveryFailedCount, 0)
        XCTAssertEqual(recoverySnapshot.checkpointPersistenceFailedCount, 0)
        XCTAssertEqual(recoverySnapshot.publicationFailedCount, 0)
        XCTAssertEqual(recoverySnapshot.publicationRebasedCount, 1)
        let restoredCatalog = await second.workspaceStore.snapshot()
        XCTAssertEqual(restoredCatalog.workspaces.map(\.document.workspaceID), [workspaceID])

        let loadedSecondCheckpoint = try await second.persistenceCoordinator.loadWorkspaceProjectionCheckpointData()
        let secondCheckpoint = try XCTUnwrap(loadedSecondCheckpoint)
        let secondObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: secondCheckpoint) as? [String: Any]
        )
        let secondGeneration = try XCTUnwrap(
            (secondObject["generation"] as? NSNumber)?.uint64Value
        )
        XCTAssertGreaterThan(
            secondGeneration,
            firstGeneration,
            "restart health transitions must publish new complete authority rows even when document bytes match"
        )
        let secondEntries = try XCTUnwrap(secondObject["entries"] as? [[String: Any]])
        XCTAssertEqual(secondEntries.first?["contentDigest"] as? String, firstContentDigest)
        XCTAssertNotNil(secondEntries.first?["authority"] as? [String: Any])
        XCTAssertEqual((secondObject["publicationSequence"] as? NSNumber)?.uint64Value, 2)
        let events = try XCTUnwrap(secondObject["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(
            events.compactMap { ($0["sequence"] as? NSNumber)?.uint64Value },
            [1, 2],
            "bootstrap rebases at sequence 1 before the lease-acquired publication at sequence 2"
        )
        _ = await second.shutdown()
    }

    func testContendingRuntimeCannotRecoverOrPersistProjectionWithoutWorkspaceLease() async throws {
        let directory = temporaryDirectory(name: "ProjectionCheckpointContention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = configuration(directory: directory)
        let holder = MCPDomainRuntime(configuration: configuration)
        try await holder.start()
        let workspaceID = UUID()
        let workspaceFileURL = configuration.workspaceStorageDirectory
            .appendingPathComponent("Takeover-\(workspaceID.uuidString)", isDirectory: true)
            .appendingPathComponent("workspace.json")
        let initial = await holder.workspaceStore.snapshot()
        let created = await holder.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: initial.catalogRevision,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .createWorkspace(try document(
                workspaceID: workspaceID,
                name: "Takeover",
                fileURL: workspaceFileURL
            ))
        ))
        XCTAssertEqual(created.disposition, .applied)
        let holderPersisted = await waitFor(timeoutIterations: 500) {
            await holder.workspaceRustProjectionObserver.snapshot().checkpointPersistedCount >= 3
        }
        XCTAssertTrue(holderPersisted)

        let contender = MCPDomainRuntime(configuration: configuration)
        try await contender.start()
        let runtimeSnapshot = await contender.snapshot()
        XCTAssertEqual(runtimeSnapshot.lifecycle, .degraded)
        let projectionSnapshot = await contender.workspaceRustProjectionObserver.snapshot()
        XCTAssertTrue(projectionSnapshot.isAcceptingObservations)
        XCTAssertFalse(projectionSnapshot.hasActiveProjection)
        XCTAssertEqual(projectionSnapshot.checkpointRecoveredCount, 0)
        XCTAssertEqual(projectionSnapshot.checkpointRecoveryFailedCount, 0)
        XCTAssertEqual(projectionSnapshot.checkpointPersistedCount, 0)
        XCTAssertEqual(projectionSnapshot.checkpointPersistenceFailedCount, 0)
        XCTAssertEqual(projectionSnapshot.matchedCount, 0)
        XCTAssertEqual(projectionSnapshot.publicationMatchedCount, 0)

        _ = await holder.shutdown()
        let tookOver = await waitFor(timeoutIterations: 500) {
            let runtime = await contender.snapshot()
            let projection = await contender.workspaceRustProjectionObserver.snapshot()
            return runtime.lifecycle == .ready
                && projection.checkpointRecoveredCount == 1
                && projection.checkpointPersistedCount >= 3
                && projection.publicationMatchedCount >= 3
        }
        let takeoverProjection = await contender.workspaceRustProjectionObserver.snapshot()
        XCTAssertTrue(tookOver, "contender did not activate after lease release: \(takeoverProjection)")
        XCTAssertEqual(takeoverProjection.checkpointRecoveryFailedCount, 0)
        XCTAssertEqual(takeoverProjection.checkpointPersistenceFailedCount, 0)
        let contenderCatalog = await contender.workspaceStore.snapshot()
        XCTAssertEqual(contenderCatalog.workspaces.map(\.document.workspaceID), [workspaceID])

        _ = await contender.shutdown()
    }

    func testProductionRuntimeObserverUsesRealRustProjection() async throws {
        let directory = temporaryDirectory(name: "ProjectionRealCore")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MCPDomainRuntime(configuration: configuration(directory: directory))
        try await runtime.start()
        let value = try document(name: "Real Core", prompt: "compare")

        _ = await runtime.workspaceStore.registerReadDocument(value)

        let matched = await waitFor(timeoutIterations: 500) {
            await runtime.workspaceRustProjectionObserver.snapshot().matchedCount == 1
        }
        XCTAssertTrue(matched)
        let observerSnapshot = await runtime.workspaceRustProjectionObserver.snapshot()
        XCTAssertEqual(observerSnapshot.failedCount, 0)
        XCTAssertEqual(observerSnapshot.mismatchedCount, 0)
        let publicationMatched = await waitFor(timeoutIterations: 500) {
            await runtime.workspaceRustProjectionObserver.snapshot().publicationMatchedCount >= 1
        }
        let publicationSnapshot = await runtime.workspaceRustProjectionObserver.snapshot()
        XCTAssertTrue(
            publicationMatched,
            "bootstrap publication must reach the real Rust state: \(publicationSnapshot)"
        )
        XCTAssertEqual(publicationSnapshot.publicationFailedCount, 0)
        _ = await runtime.shutdown()
    }

    private func makeObserver(
        metrics: DomainRuntimeMetricsSink = .disabled,
        limits: DomainWorkspaceRustProjectionObserver.Limits = .production,
        publicationProjector: DomainWorkspaceRustProjectionObserver.PublicationProjector? = nil,
        projector: @escaping DomainWorkspaceRustProjectionObserver.Projector
    ) -> DomainWorkspaceRustProjectionObserver {
        DomainWorkspaceRustProjectionObserver(
            identity: DomainRuntimeIdentity(
                runtimeID: UUID(),
                lifecycleGeneration: 1,
                processID: 1,
                mode: .standalone,
                createdAt: Date()
            ),
            metrics: metrics,
            limits: limits,
            projector: projector,
            publicationProjector: publicationProjector
        )
    }

    private func document(
        workspaceID: UUID = UUID(),
        name: String,
        prompt: String = "prompt",
        selectedPaths: [String] = ["Sources/App.swift"],
        fileURL: URL? = nil
    ) throws -> DomainWorkspaceDocument {
        let contextID = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": name,
            "repoPaths": ["/repo/\(name)"],
            "activeComposeTabID": contextID.uuidString,
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": prompt,
                "selectedPaths": selectedPaths
            ]]
        ], options: [.sortedKeys])
        return try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: fileURL ?? URL(fileURLWithPath: "/tmp/\(workspaceID.uuidString).json")
        )
    }

    private func snapshot(
        document: DomainWorkspaceDocument,
        revisions: DomainRevisionState,
        health: DomainAuthorityHealth
    ) -> DomainWorkspaceSnapshot {
        DomainWorkspaceSnapshot(
            document: document,
            revisions: revisions,
            health: health,
            contexts: document.metadata.contexts.map { metadata in
                DomainContextSnapshot(
                    metadata: metadata,
                    revisions: revisions,
                    health: health
                )
            }
        )
    }

    private func publicationEvent(
        sequence: UInt64,
        catalogRevision: UInt64,
        workspaceID: UUID
    ) -> DomainWorkspaceEvent {
        DomainWorkspaceEvent(
            runtimeID: UUID(),
            sequence: sequence,
            catalogRevision: catalogRevision,
            kind: .workingStateCommitted,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: nil,
            origin: nil,
            revisions: .init(
                workingRevision: catalogRevision,
                savedRevision: catalogRevision == 0 ? 0 : catalogRevision - 1,
                dirtyRevision: catalogRevision
            ),
            timestamp: Date(),
            diagnostic: nil
        )
    }

    private func configuration(directory: URL) -> DomainRuntimeConfiguration {
        DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "projection-observer-tests-\(UUID().uuidString)",
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

    private func waitFor(
        timeoutIterations: Int = 200,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< timeoutIterations {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor PublicationRecorder {
    private var observedSequences: [UInt64] = []

    func publish(
        documents: [DomainWorkspaceDocument],
        event: DomainWorkspaceEvent
    ) -> Bool {
        let expectedNext = observedSequences.last.map { $0 + 1 }
        observedSequences.append(event.sequence)
        return expectedNext != event.sequence
    }

    func sequences() -> [UInt64] {
        observedSequences
    }
}

private actor ControlledPublicationProjector {
    private var observedSequences: [UInt64] = []
    private var firstStarted = false
    private var firstReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func publish(
        documents: [DomainWorkspaceDocument],
        event: DomainWorkspaceEvent
    ) async -> Bool {
        observedSequences.append(event.sequence)
        guard observedSequences.count == 1 else { return false }
        firstStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !firstReleased else { return true }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return true
    }

    func waitUntilFirstPublicationStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstPublication() {
        guard !firstReleased else { return }
        firstReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func sequences() -> [UInt64] {
        observedSequences
    }
}

private actor MismatchThenMatchProjector {
    private var calls = 0

    func project(_ data: Data) throws -> DomainWorkspaceDocumentReadProjection {
        calls += 1
        let document = try DomainWorkspaceDocument.decode(
            documentBytes: data,
            fileURL: URL(fileURLWithPath: "/tmp/projection-script.json")
        )
        let expected = try DomainWorkspaceRustProjection.swiftProjection(document)
        guard calls == 1 else { return expected }
        return DomainWorkspaceDocumentReadProjection(
            workspaceID: expected.workspaceID,
            schemaVersion: expected.schemaVersion,
            name: "intentional mismatch",
            repoPaths: expected.repoPaths,
            activeContextID: expected.activeContextID,
            contexts: expected.contexts
        )
    }

    func callCount() -> Int {
        calls
    }
}

private actor SecondProjectionGate {
    private var calls = 0
    private var secondStarted = false
    private var secondReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func project(_ data: Data) async throws -> DomainWorkspaceDocumentReadProjection {
        calls += 1
        let call = calls
        let document = try DomainWorkspaceDocument.decode(
            documentBytes: data,
            fileURL: URL(fileURLWithPath: "/tmp/projection-second-gate.json")
        )
        if call == 2 {
            secondStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !secondReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        return try DomainWorkspaceRustProjection.swiftProjection(document)
    }

    func waitUntilSecondProjectionStarted() async {
        guard !secondStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseSecondProjection() {
        guard !secondReleased else { return }
        secondReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func callCount() -> Int {
        calls
    }
}

private actor CountingProjector {
    private var calls = 0

    func project(_ data: Data) throws -> DomainWorkspaceDocumentReadProjection {
        calls += 1
        let document = try DomainWorkspaceDocument.decode(
            documentBytes: data,
            fileURL: URL(fileURLWithPath: "/tmp/projection-counting.json")
        )
        return try DomainWorkspaceRustProjection.swiftProjection(document)
    }

    func callCount() -> Int {
        calls
    }
}

private actor ControlledProjector {
    private var calls: [UUID] = []
    private var firstStarted = false
    private var firstReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func project(_ data: Data) async throws -> DomainWorkspaceDocumentReadProjection {
        let document = try DomainWorkspaceDocument.decode(
            documentBytes: data,
            fileURL: URL(fileURLWithPath: "/tmp/projection-gate.json")
        )
        calls.append(document.workspaceID)
        if calls.count == 1 {
            firstStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !firstReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        return try DomainWorkspaceRustProjection.swiftProjection(document)
    }

    func waitUntilFirstProjectionStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstProjection() {
        guard !firstReleased else { return }
        firstReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func projectedWorkspaceIDs() -> [UUID] {
        calls
    }
}

private actor AsyncSignal {
    private var didSignal = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        didSignal = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !didSignal else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class MetricCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DomainRuntimeMetric] = []

    var sink: DomainRuntimeMetricsSink {
        DomainRuntimeMetricsSink { [weak self] metric in
            self?.lock.withLock {
                self?.values.append(metric)
            }
        }
    }

    func snapshot() -> [DomainRuntimeMetric] {
        lock.withLock { values }
    }
}
