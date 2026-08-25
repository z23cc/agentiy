import AgentryCoreBridge
import Foundation
@testable import RepoPromptApp
import XCTest

// P5-2 through P5-5 Rust republication (design doc §4.3). `WorkspaceFileContextStore` validates
// exact transaction plans and feeds the same canonical events to production `appliedIndexEvents()`
// and the differential `republishedInventoryScopeEvents()` mirror. These cases pin hidden-load
// suppression, Rust/Swift generation alignment, serialized mutation capture, raw-batch identity,
// canonical slice sources, managed-only suppression, bounded-plan degradation, subscription-safe
// fallback, and lifetime-correct unload at the Swift visibility seam.
#if DEBUG
    final class WorkspaceInventoryScopeRepublicationArmingTests: XCTestCase {
        private var stores: [WorkspaceFileContextStore] = []
        private var temporaryRoots: [URL] = []

        override func tearDown() async throws {
            for store in stores {
                let rootIDs = await store.roots().map(\.id)
                await store.unloadRoots(ids: rootIDs)
            }
            stores.removeAll()
            for root in temporaryRoots {
                try? FileManager.default.removeItem(at: root)
            }
            temporaryRoots.removeAll()
            try await super.tearDown()
        }

        /// Drives a real file-add mutation through the normal service/synthetic-delta path (the
        /// same production path `publishAppliedIndexEvent`'s callers use), and asserts the armed
        /// republication path independently observes it: a matching root ID, an upserted file
        /// naming the new path, a non-degenerate (> 0) Rust-sourced generation, and -- documenting
        /// the known, deliberate gap rather than silently relying on it --
        /// `modifiedFileSourceSnapshotsByID` empty even though this is an add, not a modify (the
        /// merge that would populate it for a genuine modify is not wired yet; see this file's
        /// header comment).
        func testArmedRepublicationPathObservesARealFileAddIndependentlyOfTheProductionStream() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationArmingAdd")
            try write("a", to: root.appendingPathComponent("App.swift"))
            let store = makeStore()
            let republishedStream = await store.republishedInventoryScopeEvents()
            let collector = RepublishedEventCollector()
            let collectorTask = Task { await collector.run(republishedStream) }
            let productionStream = await store.appliedIndexEvents()
            let productionCollector = RepublishedEventCollector()
            let productionCollectorTask = Task { await productionCollector.run(productionStream) }

            let record = try await store.loadRoot(path: root.path)
            let attached = try await store.attachPublisherIngressWithoutStartingWatcherForTesting(rootID: record.id)
            XCTAssertTrue(attached, "the synthetic mutation must have exactly one deterministic publisher ingress")
            let hiddenLoadEvents = await collector.waitForAtLeast(1, timeoutSeconds: 0.2)
            XCTAssertTrue(hiddenLoadEvents.isEmpty, "pre-visibility Rust crawl generations must remain below the activation floor")

            let addedURL = root.appendingPathComponent("Added.swift")
            try write("added", to: addedURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: record.id, deltas: [.fileAdded("Added.swift")])
            _ = await store.flushPendingServiceEventsForAllRoots()

            let events = await collector.waitForAtLeast(1, timeoutSeconds: 10)
            let productionEvents = await productionCollector.waitForAtLeast(1, timeoutSeconds: 10)
            collectorTask.cancel()
            productionCollectorTask.cancel()

            let addedEvent = try XCTUnwrap(
                events.last { $0.upsertedFiles.contains { $0.name == "Added.swift" } },
                "the armed republication path never observed a republished event naming Added.swift among \(events)"
            )
            let productionAddedEvent = try XCTUnwrap(
                productionEvents.last { $0.upsertedFiles.contains { $0.name == "Added.swift" } }
            )
            let armedSummary = eventSummary(events)
            let productionSummary = eventSummary(productionEvents)
            XCTAssertEqual(addedEvent.rootID, record.id)
            XCTAssertFalse(addedEvent.isRootUnload)
            XCTAssertEqual(
                addedEvent.generation,
                1,
                "armed=\(armedSummary); production=\(productionSummary)"
            )
            XCTAssertEqual(
                addedEvent.generation,
                productionAddedEvent.generation,
                "armed=\(armedSummary); production=\(productionSummary)"
            )
            XCTAssertFalse(
                addedEvent.requiresFullResync,
                "armed=\(armedSummary); production=\(productionSummary)"
            )
            XCTAssertTrue(
                addedEvent.modifiedFileSourceSnapshotsByID.isEmpty,
                "add events have no pre-modification slice source to join"
            )
        }

        func testVisibleMoveIntoIgnoredPathPublishesOneCanonicalRemoval() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationVisibleToIgnoredMove")
            try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
            try write("visible\n", to: root.appendingPathComponent("Visible.swift"))
            let store = makeStore()
            let armedStream = await store.republishedInventoryScopeEvents()
            let armedCollector = RepublishedEventCollector()
            let armedCollectorTask = Task { await armedCollector.run(armedStream) }
            let productionStream = await store.appliedIndexEvents()
            let productionCollector = RepublishedEventCollector()
            let productionCollectorTask = Task { await productionCollector.run(productionStream) }

            let rootRecord = try await store.loadRoot(path: root.path)
            let maybeVisibleFile = await store.file(rootID: rootRecord.id, relativePath: "Visible.swift")
            let visibleFile = try XCTUnwrap(maybeVisibleFile)
            try await store.moveFile(
                rootID: rootRecord.id,
                from: "Visible.swift",
                to: "Hidden.ignored"
            )

            let armedEvents = await armedCollector.waitForAtLeast(1, timeoutSeconds: 10)
            let productionEvents = await productionCollector.waitForAtLeast(1, timeoutSeconds: 10)
            _ = await armedCollector.waitForAtLeast(2, timeoutSeconds: 0.2)
            _ = await productionCollector.waitForAtLeast(2, timeoutSeconds: 0.2)
            let allArmedEvents = await armedCollector.eventsSnapshot()
            let allProductionEvents = await productionCollector.eventsSnapshot()
            let armed = try XCTUnwrap(armedEvents.first)
            let production = try XCTUnwrap(productionEvents.first)

            XCTAssertEqual(allArmedEvents.count, 1)
            XCTAssertEqual(allProductionEvents.count, 1)
            XCTAssertEqual(armed.generation, production.generation)
            XCTAssertEqual(armed.rootLifetimeID, production.rootLifetimeID)
            XCTAssertEqual(armed.removedFileIDs, [visibleFile.id])
            XCTAssertEqual(armed.removedFilePaths, ["Visible.swift"])
            XCTAssertTrue(armed.upsertedFiles.isEmpty)
            XCTAssertFalse(armed.requiresFullResync)
            XCTAssertEqual(eventSummary([armed]), eventSummary([production]))

            armedCollectorTask.cancel()
            productionCollectorTask.cancel()
        }

        func testRustUnloadPublishesCanonicalMonotonicEventAtSwiftVisibilitySeam() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationCanonicalUnload")
            try write("seed\n", to: root.appendingPathComponent("Seed.swift"))
            let store = makeStore()
            let rustStream = await store.republishedInventoryScopeEvents()
            let rustCollector = RepublishedEventCollector()
            let rustCollectorTask = Task { await rustCollector.run(rustStream) }
            let productionStream = await store.appliedIndexEvents()
            let productionCollector = RepublishedEventCollector()
            let productionCollectorTask = Task { await productionCollector.run(productionStream) }
            let record = try await store.loadRoot(path: root.path)
            let maybeSeed = await store.file(rootID: record.id, relativePath: "Seed.swift")
            let seed = try XCTUnwrap(maybeSeed)

            try await store.createFile(rootID: record.id, relativePath: "Created.swift", content: "created")
            let mutationEvents = await productionCollector.waitForAtLeast(1, timeoutSeconds: 10)
            let mutation = try XCTUnwrap(mutationEvents.first)
            await store.unloadRoot(id: record.id)

            let rustEvents = await rustCollector.waitForAtLeast(2, timeoutSeconds: 10)
            let productionEvents = await productionCollector.waitForAtLeast(2, timeoutSeconds: 10)
            let rustUnload = try XCTUnwrap(rustEvents.last)
            let productionUnload = try XCTUnwrap(productionEvents.last)
            XCTAssertTrue(rustUnload.isRootUnload)
            XCTAssertTrue(productionUnload.isRootUnload)
            XCTAssertEqual(productionUnload.generation, mutation.generation + 1)
            XCTAssertEqual(productionUnload.rootLifetimeID, mutation.rootLifetimeID)
            XCTAssertTrue(productionUnload.removedFileIDs.contains(seed.id))
            XCTAssertEqual(eventSummary([rustUnload]), eventSummary([productionUnload]))

            rustCollectorTask.cancel()
            productionCollectorTask.cancel()
        }

        func testArmedRepublicationRealEditMatchesProductionSliceSourceExactlyOnce() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationArmingEdit")
            let fileURL = root.appendingPathComponent("App.swift")
            let original = "one\ntwo\nthree\n"
            try write(original, to: fileURL)
            let store = makeStore()
            let republishedStream = await store.republishedInventoryScopeEvents()
            let armedCollector = RepublishedEventCollector()
            let armedCollectorTask = Task { await armedCollector.run(republishedStream) }

            let rootRecord = try await store.loadRoot(path: root.path)
            let maybeFile = await store.file(rootID: rootRecord.id, relativePath: "App.swift")
            let file = try XCTUnwrap(maybeFile)
            let readSnapshot = try await store.interactiveReadSnapshot(for: file)
            XCTAssertEqual(readSnapshot?.preparedContent.linesWithEndings.joined(), original)

            let productionStream = await store.appliedIndexEvents()
            let productionCollector = RepublishedEventCollector()
            let productionCollectorTask = Task { await productionCollector.run(productionStream) }

            _ = try await store.editFile(
                rootID: rootRecord.id,
                relativePath: "App.swift",
                newContent: "first edit\n"
            )
            let firstArmedEvents = await armedCollector.waitForAtLeast(1, timeoutSeconds: 10)
            let firstProductionEvents = await productionCollector.waitForAtLeast(1, timeoutSeconds: 10)
            let firstArmed = try XCTUnwrap(firstArmedEvents.last { $0.modifiedFileIDs.contains(file.id) })
            let firstProduction = try XCTUnwrap(firstProductionEvents.last { $0.modifiedFileIDs.contains(file.id) })
            XCTAssertEqual(firstArmed.generation, firstProduction.generation)
            XCTAssertEqual(firstArmed.rootLifetimeID, firstProduction.rootLifetimeID)
            XCTAssertEqual(firstArmed.modifiedFileSourceSnapshotsByID[file.id], firstProduction.modifiedFileSourceSnapshotsByID[file.id])
            XCTAssertEqual(firstArmed.modifiedFileSourceSnapshotsByID[file.id]?.text, original)
            XCTAssertFalse(firstArmed.requiresFullResync)

            let maybeCurrentFile = await store.file(rootID: rootRecord.id, relativePath: "App.swift")
            let currentFile = try XCTUnwrap(maybeCurrentFile)
            let firstEditRead = try await store.interactiveReadSnapshot(for: currentFile)
            XCTAssertEqual(firstEditRead?.preparedContent.linesWithEndings.joined(), "first edit\n")
            _ = try await store.editFile(
                rootID: rootRecord.id,
                relativePath: "App.swift",
                newContent: "second edit\n"
            )
            let secondArmedEvents = await armedCollector.waitForAtLeast(2, timeoutSeconds: 10)
            let secondProductionEvents = await productionCollector.waitForAtLeast(2, timeoutSeconds: 10)
            let secondArmed = try XCTUnwrap(secondArmedEvents.filter { $0.modifiedFileIDs.contains(file.id) }.last)
            let secondProduction = try XCTUnwrap(secondProductionEvents.filter { $0.modifiedFileIDs.contains(file.id) }.last)
            XCTAssertEqual(secondArmed.modifiedFileSourceSnapshotsByID[file.id]?.text, "first edit\n")
            XCTAssertEqual(secondArmed.modifiedFileSourceSnapshotsByID[file.id], secondProduction.modifiedFileSourceSnapshotsByID[file.id])
            XCTAssertEqual(secondArmed.generation, secondProduction.generation)

            _ = try await store.editFile(
                rootID: rootRecord.id,
                relativePath: "App.swift",
                newContent: "third edit\n"
            )
            let thirdArmedEvents = await armedCollector.waitForAtLeast(3, timeoutSeconds: 10)
            let thirdProductionEvents = await productionCollector.waitForAtLeast(3, timeoutSeconds: 10)
            let armedModifications = thirdArmedEvents.filter { $0.modifiedFileIDs.contains(file.id) }
            let productionModifications = thirdProductionEvents.filter { $0.modifiedFileIDs.contains(file.id) }
            XCTAssertEqual(armedModifications.count, 3)
            XCTAssertEqual(productionModifications.count, 3)
            XCTAssertNil(armedModifications.last?.modifiedFileSourceSnapshotsByID[file.id])
            XCTAssertNil(productionModifications.last?.modifiedFileSourceSnapshotsByID[file.id])
            XCTAssertEqual(armedModifications.last?.generation, productionModifications.last?.generation)

            armedCollectorTask.cancel()
            productionCollectorTask.cancel()
        }

        func testConcurrentEditsSerializeRustApplyThroughCanonicalPublication() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationConcurrentEdits")
            let fileURL = root.appendingPathComponent("App.swift")
            let original = "original\n"
            try write(original, to: fileURL)
            let store = makeStore()
            let republishedStream = await store.republishedInventoryScopeEvents()
            let armedCollector = RepublishedEventCollector()
            let armedCollectorTask = Task { await armedCollector.run(republishedStream) }
            let rootRecord = try await store.loadRoot(path: root.path)
            let maybeFile = await store.file(rootID: rootRecord.id, relativePath: "App.swift")
            let file = try XCTUnwrap(maybeFile)
            _ = try await store.interactiveReadSnapshot(for: file)

            let productionStream = await store.appliedIndexEvents()
            let productionCollector = RepublishedEventCollector()
            let productionCollectorTask = Task { await productionCollector.run(productionStream) }
            let applyGate = FirstInvocationSuspensionGate()
            await store.setInventoryScopeContentModificationDidApplyHandlerForTesting { rootID, _ in
                guard rootID == rootRecord.id else { return }
                await applyGate.suspendFirstInvocation()
            }

            let firstEditTask = Task {
                try await store.editFile(
                    rootID: rootRecord.id,
                    relativePath: "App.swift",
                    newContent: "first edit\n"
                )
            }
            await applyGate.waitUntilFirstInvocationSuspended()
            let secondEditTask = Task {
                try await store.editFile(
                    rootID: rootRecord.id,
                    relativePath: "App.swift",
                    newContent: "second edit\n"
                )
            }

            var waiterCount = 0
            for _ in 0 ..< 100 {
                waiterCount = await store.inventoryCatalogPublicationPermitWaiterCountForTesting(
                    rootID: rootRecord.id
                )
                if waiterCount == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(waiterCount, 1, "the second edit must wait before its disk write")
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "first edit\n")

            await applyGate.releaseFirstInvocation()
            _ = try await firstEditTask.value
            _ = try await secondEditTask.value
            await store.setInventoryScopeContentModificationDidApplyHandlerForTesting(nil)

            let armedEvents = await armedCollector.waitForAtLeast(2, timeoutSeconds: 10)
            let productionEvents = await productionCollector.waitForAtLeast(2, timeoutSeconds: 10)
            let armedModifications = armedEvents.filter { $0.modifiedFileIDs.contains(file.id) }
            let productionModifications = productionEvents.filter { $0.modifiedFileIDs.contains(file.id) }
            XCTAssertEqual(armedModifications.count, 2)
            XCTAssertEqual(productionModifications.count, 2)
            XCTAssertEqual(armedModifications[0].modifiedFileSourceSnapshotsByID[file.id]?.text, original)
            XCTAssertNil(armedModifications[1].modifiedFileSourceSnapshotsByID[file.id])
            XCTAssertEqual(
                armedModifications.map(\.modifiedFileSourceSnapshotsByID),
                productionModifications.map(\.modifiedFileSourceSnapshotsByID)
            )
            XCTAssertEqual(armedModifications.map(\.generation), productionModifications.map(\.generation))
            XCTAssertTrue(armedModifications.allSatisfy { !$0.requiresFullResync })

            armedCollectorTask.cancel()
            productionCollectorTask.cancel()
        }

        func testPublicationPermitWaitsForCanonicalShardDeliveryBeforeNextDiskWrite() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationDeliveryAcknowledgement")
            let fileURL = root.appendingPathComponent("App.swift")
            try write("original\n", to: fileURL)
            let store = makeStore()
            let productionStream = await store.appliedIndexEvents()
            let productionCollector = RepublishedEventCollector()
            let productionCollectorTask = Task { await productionCollector.run(productionStream) }
            let rootRecord = try await store.loadRoot(path: root.path)
            guard await waitForStoreActivation(store, rootID: rootRecord.id) != nil else {
                let stateSummary = await store.inventoryScopeRepublicationStateSummaryForTesting(
                    rootID: rootRecord.id
                )
                XCTFail("the root never activated Rust republication: \(stateSummary)")
                return
            }
            let deliveryGate = FirstInvocationSuspensionGate()
            await store.setInventoryScopeRepublicationDeliveryWillApplyHandlerForTesting { rootID, _ in
                guard rootID == rootRecord.id else { return }
                await deliveryGate.suspendFirstInvocation()
            }
            let firstEditTask = Task {
                try await store.editFile(
                    rootID: rootRecord.id,
                    relativePath: "App.swift",
                    newContent: "first edit\n"
                )
            }
            var deliverySuspended = false
            for _ in 0 ..< 200 {
                deliverySuspended = await deliveryGate.isFirstInvocationSuspended()
                if deliverySuspended { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard deliverySuspended else {
                firstEditTask.cancel()
                _ = try? await firstEditTask.value
                await store.setInventoryScopeRepublicationDeliveryWillApplyHandlerForTesting(nil)
                XCTFail("the first canonical delivery never reached the deterministic suspension hook")
                return
            }
            let secondEditTask = Task {
                try await store.editFile(
                    rootID: rootRecord.id,
                    relativePath: "App.swift",
                    newContent: "second edit\n"
                )
            }

            var waiterCount = 0
            for _ in 0 ..< 100 {
                waiterCount = await store.inventoryCatalogPublicationPermitWaiterCountForTesting(
                    rootID: rootRecord.id
                )
                if waiterCount == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(waiterCount, 1, "the next mutation must wait for canonical delivery")
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "first edit\n")

            await deliveryGate.releaseFirstInvocation()
            _ = try await firstEditTask.value
            _ = try await secondEditTask.value
            await store.setInventoryScopeRepublicationDeliveryWillApplyHandlerForTesting(nil)

            let events = await productionCollector.waitForAtLeast(2, timeoutSeconds: 10)
            XCTAssertEqual(events.map(\.generation), [1, 2])
            XCTAssertTrue(events.allSatisfy { !$0.requiresFullResync })
            productionCollectorTask.cancel()
        }

        func testArmedRepublicationPathObservesRealWatcherContentModification() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationArmingWatcherModify")
            let fileURL = root.appendingPathComponent("App.swift")
            try write("before\n", to: fileURL)
            let store = makeStore()
            let republishedStream = await store.republishedInventoryScopeEvents()
            let armedCollector = RepublishedEventCollector()
            let armedCollectorTask = Task { await armedCollector.run(republishedStream) }

            let rootRecord = try await store.loadRoot(path: root.path)
            let attached = try await store.attachPublisherIngressWithoutStartingWatcherForTesting(rootID: rootRecord.id)
            XCTAssertTrue(attached)
            let maybeFile = await store.file(rootID: rootRecord.id, relativePath: "App.swift")
            let file = try XCTUnwrap(maybeFile)
            try write("after\n", to: fileURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(
                rootID: rootRecord.id,
                deltas: [.fileModified("App.swift", nil)]
            )
            _ = await store.flushPendingServiceEventsForAllRoots()

            let events = await armedCollector.waitForAtLeast(1, timeoutSeconds: 10)
            let modified = try XCTUnwrap(events.last { $0.modifiedFileIDs.contains(file.id) })
            XCTAssertEqual(modified.rootID, rootRecord.id)
            XCTAssertGreaterThan(modified.generation, 0)
            XCTAssertFalse(modified.requiresFullResync)
            armedCollectorTask.cancel()
        }

        func testUnarmedEmptyFullResyncDoesNotAdvanceRustButArmedAnchorPublishes() async throws {
            let unarmedRoot = try makeTemporaryRoot(name: "RepublicationUnarmedEmptyResync")
            let unarmedStore = makeStore()
            let unarmedRecord = try await unarmedStore.loadRoot(path: unarmedRoot.path)
            let generationBefore = try await unarmedStore.inventoryScopeAppliedIndexGenerationForTesting(
                rootID: unarmedRecord.id
            )
            try await unarmedStore.publishEmptyFullResyncForTesting(rootID: unarmedRecord.id)
            let generationAfter = try await unarmedStore.inventoryScopeAppliedIndexGenerationForTesting(
                rootID: unarmedRecord.id
            )
            XCTAssertEqual(generationAfter, generationBefore)

            let armedRoot = try makeTemporaryRoot(name: "RepublicationArmedEmptyResync")
            let armedStore = makeStore()
            let armedStream = await armedStore.republishedInventoryScopeEvents()
            let armedCollector = RepublishedEventCollector()
            let armedCollectorTask = Task { await armedCollector.run(armedStream) }
            let productionStream = await armedStore.appliedIndexEvents()
            let productionCollector = RepublishedEventCollector()
            let productionCollectorTask = Task { await productionCollector.run(productionStream) }
            let armedRecord = try await armedStore.loadRoot(path: armedRoot.path)

            try await armedStore.publishEmptyFullResyncForTesting(rootID: armedRecord.id)
            let armedEvents = await armedCollector.waitForAtLeast(1, timeoutSeconds: 10)
            let productionEvents = await productionCollector.waitForAtLeast(1, timeoutSeconds: 10)
            let armedEvent = try XCTUnwrap(armedEvents.first)
            let productionEvent = try XCTUnwrap(productionEvents.first)
            XCTAssertTrue(armedEvent.requiresFullResync)
            XCTAssertEqual(eventSummary([armedEvent]), eventSummary([productionEvent]))

            armedCollectorTask.cancel()
            productionCollectorTask.cancel()
        }

        func testPrecisionLossImmediatelyPublishesRetainedCanonicalEventWithFullResync() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationPrecisionLossFallback")
            let store = makeStore()
            let mirrorStream = await store.republishedInventoryScopeEvents()
            let mirrorCollector = RepublishedEventCollector()
            let mirrorCollectorTask = Task { await mirrorCollector.run(mirrorStream) }
            let productionStream = await store.appliedIndexEvents()
            let productionCollector = RepublishedEventCollector()
            let productionCollectorTask = Task { await productionCollector.run(productionStream) }
            let rootRecord = try await store.loadRoot(path: root.path)

            try await store.publishPrecisionLostFullResyncForTesting(rootID: rootRecord.id)

            let mirrorEvents = await mirrorCollector.waitForAtLeast(1, timeoutSeconds: 10)
            let productionEvents = await productionCollector.waitForAtLeast(1, timeoutSeconds: 10)
            let mirror = try XCTUnwrap(mirrorEvents.first)
            let production = try XCTUnwrap(productionEvents.first)
            XCTAssertTrue(mirror.requiresFullResync)
            XCTAssertTrue(production.requiresFullResync)
            XCTAssertEqual(eventSummary([mirror]), eventSummary([production]))
            let retainedPlanCount = await store.inventoryScopeRepublicationPresentationPlanCountForTesting()
            XCTAssertEqual(retainedPlanCount, 0)

            mirrorCollectorTask.cancel()
            productionCollectorTask.cancel()
        }

        func testCanonicalPresentationPlanIsBoundedAndOverflowForcesResync() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationPlanBound")
            let store = makeStore()
            let stream = await store.republishedInventoryScopeEvents()
            let collector = RepublishedEventCollector()
            let collectorTask = Task { await collector.run(stream) }
            let rootRecord = try await store.loadRoot(path: root.path)
            let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: rootRecord.id)

            try await store.configureInventoryScopeRepublicationActivationForTesting(
                rootID: rootRecord.id,
                rustLifetimeID: "rust-lifetime",
                rustGenerationFloor: 100,
                logicalGenerationFloor: 0
            )
            let maximum = await store.maximumInventoryScopeRepublicationPresentationPlanCountForTesting()
            for offset in 1 ... maximum {
                let installed = try await store.retainInventoryScopeRepublicationSuppressionPlanForTesting(
                    rootID: rootRecord.id,
                    rustGeneration: UInt64(100 + offset)
                )
                XCTAssertTrue(installed)
            }
            let retainedCount = await store.inventoryScopeRepublicationPresentationPlanCountForTesting()
            XCTAssertEqual(retainedCount, maximum)

            let overflowInstalled = try await store.retainInventoryScopeRepublicationSuppressionPlanForTesting(
                rootID: rootRecord.id,
                rustGeneration: UInt64(101 + maximum)
            )
            XCTAssertFalse(overflowInstalled)
            let countAfterOverflow = await store.inventoryScopeRepublicationPresentationPlanCountForTesting()
            XCTAssertEqual(countAfterOverflow, 0)

            await store.injectInventoryScopeRepublicationCandidateForTesting(
                rustLifetimeID: "rust-lifetime",
                event: WorkspaceAppliedIndexBatchEvent(
                    rootID: rootRecord.id,
                    rootPath: rootRecord.standardizedFullPath,
                    generation: 101,
                    rootLifetimeID: lifetimeID
                )
            )
            let events = await collector.waitForAtLeast(1, timeoutSeconds: 1)
            let overflowDelivery = try XCTUnwrap(events.first)
            XCTAssertTrue(overflowDelivery.requiresFullResync)
            collectorTask.cancel()
        }

        func testLargeIDOnlySuppressionPlanExceedsRetainedByteBound() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationPlanByteBound")
            let store = makeStore()
            _ = await store.republishedInventoryScopeEvents()
            let rootRecord = try await store.loadRoot(path: root.path)
            try await store.configureInventoryScopeRepublicationActivationForTesting(
                rootID: rootRecord.id,
                rustLifetimeID: "rust-lifetime",
                rustGenerationFloor: 100,
                logicalGenerationFloor: 0
            )
            let id = UUID()
            let largeIDOnlyBatch = [UUID](repeating: id, count: 131_072)
            let installed = try await store.retainInventoryScopeRepublicationSuppressionPlanForTesting(
                rootID: rootRecord.id,
                rustGeneration: 101,
                modifiedFileIDs: largeIDOnlyBatch
            )
            XCTAssertFalse(installed)
            let retainedCount = await store.inventoryScopeRepublicationPresentationPlanCountForTesting()
            XCTAssertEqual(retainedCount, 0)
        }

        func testStoreRebasesRustGenerationFloorAndStagesBehindMutationFence() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationActivationFence")
            let store = makeStore()
            let record = try await store.loadRoot(path: root.path)
            let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: record.id)
            let stream = await store.republishedInventoryScopeEvents()
            let collector = RepublishedEventCollector()
            let collectorTask = Task { await collector.run(stream) }

            try await store.configureInventoryScopeRepublicationActivationForTesting(
                rootID: record.id,
                rustLifetimeID: "rust-lifetime",
                rustGenerationFloor: 100,
                logicalGenerationFloor: 0
            )
            await store.beginInventoryCatalogMutationPublicationFenceForTesting(rootID: record.id)
            await store.injectInventoryScopeRepublicationCandidateForTesting(
                rustLifetimeID: "rust-lifetime",
                event: WorkspaceAppliedIndexBatchEvent(
                    rootID: record.id,
                    rootPath: record.standardizedFullPath,
                    generation: 101,
                    rootLifetimeID: lifetimeID
                )
            )
            let stagedEvents = await collector.eventsSnapshot()
            XCTAssertTrue(stagedEvents.isEmpty)

            await store.finishInventoryCatalogMutationPublicationFenceForTesting(rootID: record.id)
            let events = await collector.waitForAtLeast(1, timeoutSeconds: 1)
            let event = try XCTUnwrap(events.first)
            XCTAssertEqual(event.generation, 1)
            XCTAssertEqual(event.rootLifetimeID, lifetimeID)
            XCTAssertFalse(event.requiresFullResync)

            await store.injectInventoryScopeRepublicationCandidateForTesting(
                rustLifetimeID: "rust-lifetime",
                event: WorkspaceAppliedIndexBatchEvent(
                    rootID: record.id,
                    rootPath: record.standardizedFullPath,
                    generation: 100,
                    rootLifetimeID: lifetimeID
                )
            )
            let afterStaleCandidate = await collector.eventsSnapshot()
            XCTAssertEqual(afterStaleCandidate.count, 1, "events at or below the activation floor stay suppressed")
            collectorTask.cancel()
        }

        func testAdapterSkipsBulkOnlyGenerationBeforeTheNextDeltaPair() async throws {
            let rootID = UUID()
            let adapter = makeAdapter(rootIDs: [rootID])

            await assertNoOutput(
                generationAdvanced(
                    rootID: rootID,
                    generation: 0,
                    catalogGeneration: 0,
                    rebuiltAuthoritative: true
                ),
                from: adapter
            )
            await assertNoOutput(
                generationAdvanced(rootID: rootID, generation: 2, catalogGeneration: 1),
                from: adapter
            )

            let delta = try await requireOutput(emptyBatch(rootID: rootID), from: adapter)
            XCTAssertEqual(delta.generation, 2)
            XCTAssertFalse(delta.requiresFullResync)
        }

        func testStoreDropsUncorrelatedGenerationZeroAndResyncsNextCandidate() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationZeroGeneration")
            let store = makeStore()
            let record = try await store.loadRoot(path: root.path)
            let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: record.id)
            let stream = await store.republishedInventoryScopeEvents()
            let collector = RepublishedEventCollector()
            let collectorTask = Task { await collector.run(stream) }

            try await store.configureInventoryScopeRepublicationActivationForTesting(
                rootID: record.id,
                rustLifetimeID: "rust-lifetime",
                rustGenerationFloor: 100,
                logicalGenerationFloor: 0
            )
            await store.injectInventoryScopeRepublicationCandidateForTesting(
                rustLifetimeID: "rust-lifetime",
                event: WorkspaceAppliedIndexBatchEvent(
                    rootID: record.id,
                    rootPath: record.standardizedFullPath,
                    generation: 0,
                    rootLifetimeID: lifetimeID
                )
            )
            let uncorrelatedEvents = await collector.eventsSnapshot()
            XCTAssertTrue(uncorrelatedEvents.isEmpty)

            await store.injectInventoryScopeRepublicationCandidateForTesting(
                rustLifetimeID: "rust-lifetime",
                event: WorkspaceAppliedIndexBatchEvent(
                    rootID: record.id,
                    rootPath: record.standardizedFullPath,
                    generation: 101,
                    rootLifetimeID: lifetimeID
                )
            )
            let events = await collector.waitForAtLeast(1, timeoutSeconds: 1)
            let recovered = try XCTUnwrap(events.first)
            XCTAssertEqual(recovered.generation, 1)
            XCTAssertTrue(recovered.requiresFullResync)
            collectorTask.cancel()
        }

        func testSkippedGenerationWithoutSuppressionPlanForcesNextVisibleResync() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationMissingSuppressionPlan")
            let store = makeStore()
            let stream = await store.republishedInventoryScopeEvents()
            let collector = RepublishedEventCollector()
            let collectorTask = Task { await collector.run(stream) }
            let record = try await store.loadRoot(path: root.path)
            let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: record.id)
            try await store.configureInventoryScopeRepublicationActivationForTesting(
                rootID: record.id,
                rustLifetimeID: "rust-lifetime",
                rustGenerationFloor: 100,
                logicalGenerationFloor: 0
            )
            let installed = try await store.retainInventoryScopeRepublicationSuppressionPlanForTesting(
                rootID: record.id,
                rustGeneration: 102
            )
            XCTAssertTrue(installed)
            await store.injectInventoryScopeRepublicationSuppressionCandidateForTesting(
                rootID: record.id,
                rustGeneration: 102
            )
            let suppressedEvents = await collector.eventsSnapshot()
            XCTAssertTrue(suppressedEvents.isEmpty)

            await store.injectInventoryScopeRepublicationCandidateForTesting(
                rustLifetimeID: "rust-lifetime",
                event: WorkspaceAppliedIndexBatchEvent(
                    rootID: record.id,
                    rootPath: record.standardizedFullPath,
                    generation: 103,
                    rootLifetimeID: lifetimeID
                )
            )
            let events = await collector.waitForAtLeast(1, timeoutSeconds: 1)
            let recovered = try XCTUnwrap(events.first)
            XCTAssertTrue(recovered.requiresFullResync)
            collectorTask.cancel()
        }

        func testStoreRetriesQuarantinedActivationAndForcesRecoveryResync() async throws {
            let root = try makeTemporaryRoot(name: "RepublicationActivationRetry")
            let store = makeStore()
            let stream = await store.republishedInventoryScopeEvents()
            let collector = RepublishedEventCollector()
            let collectorTask = Task { await collector.run(stream) }
            let record = try await store.loadRoot(path: root.path)
            let lifetimeID = try await store.rootLifetimeIDForTesting(rootID: record.id)

            try await store.quarantineInventoryScopeRepublicationActivationForTesting(rootID: record.id)
            let recoveredActivation = await waitForStoreActivation(store, rootID: record.id)
            let activation = try XCTUnwrap(recoveredActivation, "quarantined activation did not recover")
            await store.injectInventoryScopeRepublicationCandidateForTesting(
                rustLifetimeID: activation.rustLifetimeID,
                event: WorkspaceAppliedIndexBatchEvent(
                    rootID: record.id,
                    rootPath: record.standardizedFullPath,
                    generation: activation.lastRustGeneration + 1,
                    rootLifetimeID: lifetimeID
                )
            )

            let events = await collector.waitForAtLeast(1, timeoutSeconds: 1)
            let recovered = try XCTUnwrap(events.first)
            XCTAssertEqual(recovered.generation, 1)
            XCTAssertTrue(recovered.requiresFullResync)
            collectorTask.cancel()
        }

        func testAdapterPairsConsecutiveGenerationsFIFOForSameRoot() async throws {
            let rootID = UUID()
            let adapter = makeAdapter(rootIDs: [rootID])

            await assertNoOutput(generationAdvanced(rootID: rootID, generation: 10), from: adapter)
            await assertNoOutput(generationAdvanced(rootID: rootID, generation: 11), from: adapter)

            let firstCandidate = await adapter.ingest(emptyBatch(rootID: rootID))
            let secondCandidate = await adapter.ingest(emptyBatch(rootID: rootID))
            let first = try XCTUnwrap(firstCandidate)
            let second = try XCTUnwrap(secondCandidate)

            XCTAssertEqual(first.generation, 10)
            XCTAssertFalse(first.requiresFullResync)
            XCTAssertEqual(second.generation, 11)
            XCTAssertFalse(second.requiresFullResync)
        }

        func testAdapterCandidateCarriesExactRawBatchAndSeparatesRebuildFromIntegrityResync() async throws {
            let rootID = UUID()
            let modifiedFileID = UUID()
            let adapter = makeAdapter(rootIDs: [rootID])
            let rawBatch = CoreInventoryAppliedIndexBatchEventV1(
                rootID: rootID,
                upsertedFiles: [],
                upsertedFolders: [],
                removedFileIDs: [],
                removedFolderIDs: [],
                removedFilePaths: [],
                removedFolderPaths: [],
                modifiedFileIDs: [modifiedFileID],
                modifiedFolderIDs: []
            )

            await assertNoOutput(
                generationAdvanced(rootID: rootID, generation: 7, rebuiltAuthoritative: true),
                from: adapter
            )
            let output = await adapter.ingestCandidate(.appliedIndexBatch(rawBatch))
            let candidate = try XCTUnwrap(output)

            XCTAssertEqual(candidate.rustGeneration, 7)
            XCTAssertEqual(candidate.rawBatch, rawBatch)
            XCTAssertEqual(candidate.rustRootLifetimeID, "lifetime-\(rootID.uuidString)")
            XCTAssertTrue(candidate.rebuiltAuthoritative)
            XCTAssertFalse(candidate.correlationIntegrityRequiresResync)
            XCTAssertTrue(
                candidate.event.requiresFullResync,
                "the compatibility event continues combining rebuild and integrity until canonical plans consume them separately"
            )
        }

        func testAdapterCandidateMarksMissingPairAsIntegrityLossWithoutInventingRebuild() async throws {
            let rootID = UUID()
            let removedFileID = UUID()
            let adapter = makeAdapter(rootIDs: [rootID])
            let rawBatch = CoreInventoryAppliedIndexBatchEventV1(
                rootID: rootID,
                upsertedFiles: [],
                upsertedFolders: [],
                removedFileIDs: [removedFileID],
                removedFolderIDs: [],
                removedFilePaths: ["Hidden.swift"],
                removedFolderPaths: [],
                modifiedFileIDs: [],
                modifiedFolderIDs: []
            )

            let output = await adapter.ingestCandidate(.appliedIndexBatch(rawBatch))
            let candidate = try XCTUnwrap(output)

            XCTAssertEqual(candidate.rustGeneration, 0)
            XCTAssertEqual(candidate.rawBatch, rawBatch)
            XCTAssertNil(candidate.rustRootLifetimeID)
            XCTAssertTrue(candidate.correlationIntegrityRequiresResync)
            XCTAssertFalse(candidate.rebuiltAuthoritative)
            XCTAssertTrue(candidate.event.requiresFullResync)
        }

        func testAdapterGapForcesEveryRootsNextDeliveryToResync() async throws {
            let rootA = UUID()
            let rootB = UUID()
            let adapter = makeAdapter(rootIDs: [rootA, rootB])

            await assertNoOutput(.gap(droppedCount: 1), from: adapter)

            await assertNoOutput(generationAdvanced(rootID: rootA, generation: 1), from: adapter)
            let firstA = try await requireOutput(emptyBatch(rootID: rootA), from: adapter)
            XCTAssertTrue(firstA.requiresFullResync)

            await assertNoOutput(generationAdvanced(rootID: rootB, generation: 1), from: adapter)
            let firstB = try await requireOutput(emptyBatch(rootID: rootB), from: adapter)
            XCTAssertTrue(firstB.requiresFullResync, "root A must not consume root B's gap obligation")

            await assertNoOutput(generationAdvanced(rootID: rootA, generation: 2), from: adapter)
            let secondA = try await requireOutput(emptyBatch(rootID: rootA), from: adapter)
            XCTAssertFalse(secondA.requiresFullResync, "each root consumes a gap epoch exactly once")
        }

        func testAdapterResnapshotRequiredSupportsRootScopedAndGlobalInvalidation() async throws {
            let rootA = UUID()
            let rootB = UUID()
            let adapter = makeAdapter(rootIDs: [rootA, rootB])

            await assertNoOutput(
                .resnapshotRequired(.init(rootID: rootA, reason: .identityChanged)),
                from: adapter
            )
            await assertNoOutput(generationAdvanced(rootID: rootA, generation: 1), from: adapter)
            let scopedA = try await requireOutput(emptyBatch(rootID: rootA), from: adapter)
            XCTAssertTrue(scopedA.requiresFullResync)
            await assertNoOutput(generationAdvanced(rootID: rootB, generation: 1), from: adapter)
            let unscopedB = try await requireOutput(emptyBatch(rootID: rootB), from: adapter)
            XCTAssertFalse(unscopedB.requiresFullResync)

            await assertNoOutput(.resnapshotRequired(.init(rootID: nil, reason: .backstop)), from: adapter)
            await assertNoOutput(generationAdvanced(rootID: rootA, generation: 2), from: adapter)
            let globalA = try await requireOutput(emptyBatch(rootID: rootA), from: adapter)
            XCTAssertTrue(globalA.requiresFullResync)
            await assertNoOutput(generationAdvanced(rootID: rootB, generation: 2), from: adapter)
            let globalB = try await requireOutput(emptyBatch(rootID: rootB), from: adapter)
            XCTAssertTrue(globalB.requiresFullResync)
        }

        func testAdapterRootPublishedClearsStaleGenerationCorrelation() async throws {
            let rootID = UUID()
            let adapter = makeAdapter(rootIDs: [rootID])

            await assertNoOutput(generationAdvanced(rootID: rootID, generation: 99), from: adapter)
            await assertNoOutput(
                .rootPublished(.init(rootID: rootID, rootLifetimeID: "new-lifetime")),
                from: adapter
            )
            await assertNoOutput(
                generationAdvanced(rootID: rootID, generation: 1, rustLifetimeID: "new-lifetime"),
                from: adapter
            )

            let event = try await requireOutput(emptyBatch(rootID: rootID), from: adapter)
            XCTAssertEqual(event.generation, 1)
            XCTAssertFalse(event.requiresFullResync)
        }

        func testAdapterRejectsStaleLifetimeEventsAfterRootRebind() async throws {
            let rootID = UUID()
            let adapter = makeAdapter(rootIDs: [rootID])

            await assertNoOutput(
                .rootPublished(.init(rootID: rootID, rootLifetimeID: "current-lifetime")),
                from: adapter
            )
            await assertNoOutput(
                generationAdvanced(rootID: rootID, generation: 99, rustLifetimeID: "stale-lifetime"),
                from: adapter
            )
            await assertNoOutput(
                generationAdvanced(rootID: rootID, generation: 1, rustLifetimeID: "current-lifetime"),
                from: adapter
            )
            let recovered = try await requireOutput(emptyBatch(rootID: rootID), from: adapter)
            XCTAssertEqual(recovered.generation, 1)
            XCTAssertTrue(recovered.requiresFullResync)

            await assertNoOutput(
                .rootUnloaded(.init(rootID: rootID, rootLifetimeID: "stale-lifetime")),
                from: adapter
            )
            await assertNoOutput(
                generationAdvanced(rootID: rootID, generation: 2, rustLifetimeID: "current-lifetime"),
                from: adapter
            )
            let stillCurrent = try await requireOutput(emptyBatch(rootID: rootID), from: adapter)
            XCTAssertEqual(stillCurrent.generation, 2)
            XCTAssertFalse(stillCurrent.requiresFullResync)

            let unload = try await requireOutput(
                .rootUnloaded(.init(rootID: rootID, rootLifetimeID: "current-lifetime")),
                from: adapter
            )
            XCTAssertTrue(unload.isRootUnload)
        }

        func testAdapterBoundsPerRootPendingGenerationsAndRecoversWithResync() async throws {
            let rootID = UUID()
            let adapter = makeAdapter(rootIDs: [rootID])

            for generation in 0 ... WorkspaceInventoryScopeRepublicationAdapter.maxPendingGenerationsPerRoot {
                await assertNoOutput(
                    generationAdvanced(rootID: rootID, generation: UInt64(generation)),
                    from: adapter
                )
            }

            let overflowRecovery = try await requireOutput(emptyBatch(rootID: rootID), from: adapter)
            XCTAssertEqual(overflowRecovery.generation, 0)
            XCTAssertTrue(overflowRecovery.requiresFullResync)

            await assertNoOutput(generationAdvanced(rootID: rootID, generation: 1000), from: adapter)
            let recovered = try await requireOutput(emptyBatch(rootID: rootID), from: adapter)
            XCTAssertEqual(recovered.generation, 1000)
            XCTAssertFalse(recovered.requiresFullResync)
        }

        func testAdapterBoundsScopeWidePendingGenerationsAndResyncsEveryAffectedRoot() async throws {
            let fullRootCount = WorkspaceInventoryScopeRepublicationAdapter.maxPendingGenerationCount
                / WorkspaceInventoryScopeRepublicationAdapter.maxPendingGenerationsPerRoot
            let roots = (0 ... fullRootCount).map { _ in UUID() }
            let adapter = makeAdapter(rootIDs: roots)

            for rootID in roots.dropLast() {
                for generation in 0 ..< WorkspaceInventoryScopeRepublicationAdapter.maxPendingGenerationsPerRoot {
                    await assertNoOutput(
                        generationAdvanced(rootID: rootID, generation: UInt64(generation)),
                        from: adapter
                    )
                }
            }
            let overflowRoot = try XCTUnwrap(roots.last)
            await assertNoOutput(generationAdvanced(rootID: overflowRoot, generation: 1), from: adapter)

            let overflowDelivery = try await requireOutput(emptyBatch(rootID: overflowRoot), from: adapter)
            XCTAssertEqual(overflowDelivery.generation, 0)
            XCTAssertTrue(overflowDelivery.requiresFullResync)

            let previouslyQueuedRoot = roots[0]
            let clearedDelivery = try await requireOutput(emptyBatch(rootID: previouslyQueuedRoot), from: adapter)
            XCTAssertEqual(clearedDelivery.generation, 0)
            XCTAssertTrue(clearedDelivery.requiresFullResync)

            await assertNoOutput(
                generationAdvanced(rootID: previouslyQueuedRoot, generation: 1000),
                from: adapter
            )
            let recovered = try await requireOutput(emptyBatch(rootID: previouslyQueuedRoot), from: adapter)
            XCTAssertEqual(recovered.generation, 1000)
            XCTAssertFalse(recovered.requiresFullResync)
        }

        // MARK: - Helpers

        private func waitForStoreActivation(
            _ store: WorkspaceFileContextStore,
            rootID: UUID
        ) async -> (rustLifetimeID: String, lastRustGeneration: UInt64)? {
            for _ in 0 ..< 400 {
                if let activation = await store.inventoryScopeRepublicationActivationForTesting(rootID: rootID) {
                    return activation
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return nil
        }

        private func eventSummary(_ events: [WorkspaceAppliedIndexBatchEvent]) -> String {
            events.map { event in
                let fileNames = event.upsertedFiles.map(\.name).sorted().joined(separator: ",")
                return "g=\(event.generation),files=[\(fileNames)],resync=\(event.requiresFullResync)"
            }.joined(separator: " | ")
        }

        private func assertNoOutput(
            _ event: CoreInventoryScopeEvent,
            from adapter: WorkspaceInventoryScopeRepublicationAdapter
        ) async {
            let output = await adapter.ingest(event)
            XCTAssertNil(output)
        }

        private func requireOutput(
            _ event: CoreInventoryScopeEvent,
            from adapter: WorkspaceInventoryScopeRepublicationAdapter
        ) async throws -> WorkspaceAppliedIndexBatchEvent {
            let output = await adapter.ingest(event)
            return try XCTUnwrap(output)
        }

        private func makeAdapter(rootIDs: [UUID]) -> WorkspaceInventoryScopeRepublicationAdapter {
            let infoByRootID = Dictionary(uniqueKeysWithValues: rootIDs.map { rootID in
                (
                    rootID,
                    WorkspaceInventoryScopeRepublicationRootInfo(
                        standardizedFullPath: "/tmp/\(rootID.uuidString)",
                        lifetimeID: rootID
                    )
                )
            })
            return WorkspaceInventoryScopeRepublicationAdapter { rootID in
                infoByRootID[rootID]
            }
        }

        private func generationAdvanced(
            rootID: UUID,
            generation: UInt64,
            rustLifetimeID: String? = nil,
            catalogGeneration: UInt64? = nil,
            rebuiltAuthoritative: Bool = false
        ) -> CoreInventoryScopeEvent {
            .generationAdvanced(
                .init(
                    rootID: rootID,
                    rootLifetimeID: rustLifetimeID ?? "lifetime-\(rootID.uuidString)",
                    appliedIndexGeneration: generation,
                    catalogGeneration: catalogGeneration,
                    rebuiltAuthoritative: rebuiltAuthoritative,
                    upsertedCount: 0,
                    removedCount: 0,
                    modifiedCount: 0
                )
            )
        }

        private func emptyBatch(rootID: UUID) -> CoreInventoryScopeEvent {
            .appliedIndexBatch(
                .init(
                    rootID: rootID,
                    upsertedFiles: [],
                    upsertedFolders: [],
                    removedFileIDs: [],
                    removedFolderIDs: [],
                    removedFilePaths: [],
                    removedFolderPaths: [],
                    modifiedFileIDs: [],
                    modifiedFolderIDs: []
                )
            )
        }

        private func makeStore() -> WorkspaceFileContextStore {
            let store = WorkspaceFileContextStore()
            stores.append(store)
            return store
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepoPrompt-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            temporaryRoots.append(url)
            return url
        }

        private func write(_ content: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private actor FirstInvocationSuspensionGate {
        private var invocationCount = 0
        private var firstInvocationIsSuspended = false
        private var firstInvocationWasReleased = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func suspendFirstInvocation() async {
            invocationCount += 1
            guard invocationCount == 1 else { return }
            firstInvocationIsSuspended = true
            let pendingStartWaiters = startWaiters
            startWaiters.removeAll()
            pendingStartWaiters.forEach { $0.resume() }
            guard !firstInvocationWasReleased else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func waitUntilFirstInvocationSuspended() async {
            guard !firstInvocationIsSuspended else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func isFirstInvocationSuspended() -> Bool {
            firstInvocationIsSuspended
        }

        func releaseFirstInvocation() {
            guard !firstInvocationWasReleased else { return }
            firstInvocationWasReleased = true
            let pendingReleaseWaiters = releaseWaiters
            releaseWaiters.removeAll()
            pendingReleaseWaiters.forEach { $0.resume() }
        }
    }

    /// Minimal single-writer collector over `republishedInventoryScopeEvents()`. Deliberately
    /// polls with a bounded deadline rather than waiting on a continuation/task-group -- matching
    /// `CoreInventoryScopeEventCollector` (`CoreInventoryScopeEventsTests.swift`)'s own doc
    /// comment on why: a genuine delivery problem on this event-stream surface (wake-pipe race,
    /// actor deadlock) must fail the test fast and legibly via the deadline, not hang the whole
    /// run indefinitely the way an unresolved continuation would.
    private actor RepublishedEventCollector {
        private var events: [WorkspaceAppliedIndexBatchEvent] = []

        func run(_ stream: AsyncStream<WorkspaceAppliedIndexBatchEvent>) async {
            for await event in stream {
                events.append(event)
            }
        }

        func eventsSnapshot() -> [WorkspaceAppliedIndexBatchEvent] {
            events
        }

        func waitForAtLeast(_ count: Int, timeoutSeconds: Double) async -> [WorkspaceAppliedIndexBatchEvent] {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while events.count < count, Date() < deadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return events
        }
    }
#endif
