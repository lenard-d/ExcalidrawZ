#if DEBUG && os(iOS) && targetEnvironment(simulator)
import Combine
import CoreData
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import ExcalidrawZ

/// Requires the isolated simulator app host. The inline page replaces only the web application.
final class ExcalidrawDocumentSyncControllerTests: XCTestCase {
    @MainActor
    func testExternalReloadPreparationRejectsSameFileEditDuringRead() async throws {
        let fixture = try await CanvasControllerFixture.open()
        addTeardownBlock { await fixture.close() }
        let state = fixture.state
        let originalOwner = state.terminationSaveToken
        let gate = SaveTestGate()
        let reload = Task {
            try await state.prepareExternalFileReload { _, _ in
                try await gate.pause()
                return nil
            }
        }
        fixture.cancelOnClose(reload)
        try await gate.waitUntilPaused()
        try await fixture.setScene(2)
        let message = try fixture.stateMessage(["revision": 2, "contentDirty": true])
        _ = try XCTUnwrap(fixture.core.documentSyncController.admitStateChanged(message))
        let current = state.terminationSaveToken
        XCTAssertEqual(current.fileID, originalOwner.fileID)
        XCTAssertEqual(current.session, originalOwner.session)
        XCTAssertEqual(current.loadGeneration, originalOwner.loadGeneration)
        XCTAssertNotEqual(current.editRevision, originalOwner.editRevision)
        state.externalSaveErrorMessage = "Current synthetic error"
        await gate.release()
        do { _ = try await boundedSaveTestValue(reload); XCTFail("A newer edit must invalidate the old preparation") }
        catch is CancellationError { }
        XCTAssertEqual(state.terminationSaveToken, current)
        XCTAssertEqual(state.externalSaveErrorMessage, "Current synthetic error")
    }

    @MainActor
    func testExternalReloadPreparationRejectsOldErrorAfterSameFileReload() async throws {
        let fixture = try await CanvasControllerFixture.open()
        addTeardownBlock { await fixture.close() }
        let state = fixture.state
        let originalOwner = state.terminationSaveToken
        let gate = SaveTestGate()
        let preparation = Task {
            try await state.prepareExternalFileReload { _, _ in
                try await gate.pause()
                throw CocoaError(.fileReadNoPermission)
            }
        }
        fixture.cancelOnClose(preparation)
        try await gate.waitUntilPaused()
        let load = Task { await fixture.core.documentSyncController.load(fixture.model.file, force: true).didLoad }
        fixture.cancelOnClose(load)
        let didLoad = try await boundedSaveTestValue(load)
        XCTAssertTrue(didLoad)
        let current = state.terminationSaveToken
        XCTAssertEqual(current.fileID, originalOwner.fileID)
        XCTAssertEqual(current.session, originalOwner.session)
        XCTAssertNotEqual(current.loadGeneration, originalOwner.loadGeneration)
        state.externalSaveErrorMessage = "Replacement load error"
        await gate.release()
        do { _ = try await boundedSaveTestValue(preparation); XCTFail("The previous load's error must cancel") }
        catch is CancellationError { }
        XCTAssertEqual(state.terminationSaveToken, current)
        XCTAssertEqual(state.externalSaveErrorMessage, "Replacement load error")
    }

    @MainActor
    func testMetadataSupersedingUnmaterializedContentStillSchedulesItsCompletedScene() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let controller = fixture.core.documentSyncController
        var errors: [NSError] = []
        fixture.core.publishError = { errors.append($0 as NSError) }
        try await fixture.setScene(2)
        try await fixture.evaluate("window.sceneRevision = 3")
        let full = try fixture.stateMessage(["revision": 2, "contentDirty": true])
        let metadata = try fixture.stateMessage([
            "revision": 3, "contentDirty": false, "appStateDirty": true,
            "appState": ["gridSize": 20]
        ])
        // Both bridge admissions happen before either save Task runs.
        let fullAdmission = try XCTUnwrap(controller.admitStateChanged(full))
        let metadataAdmission = try XCTUnwrap(controller.admitStateChanged(metadata))
        XCTAssertTrue(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
        await controller.save(full, admission: fullAdmission)
        await controller.save(metadata, admission: metadataAdmission)
        let before = try await fixture.integer("window.snapshotReads")
        try await fixture.reportContentCompletion(2, stateRevision: 3)
        let saved = Task {
            while controller.hasPendingDirtySnapshot { try await Task.sleep(for: .milliseconds(10)) }
        }
        fixture.cancelOnClose(saved)
        try await boundedSaveTestValue(saved)
        let after = try await fixture.integer("window.snapshotReads")
        let disk = try await fixture.libraryElementIDs()
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(disk, ["revision-2"])
        XCTAssertFalse(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
        XCTAssertTrue(errors.isEmpty)
        // No explicit flush or switch supplied the missing full snapshot.
    }

    @MainActor
    func testAppStateOnlyResumptionWithdrawsCompletionQueuedBehindActualWrite() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let controller = fixture.core.documentSyncController
        var errors: [NSError] = []
        fixture.core.publishError = { errors.append($0 as NSError) }
        let held = LibrarySaveControl(phase: .afterStorage)
        addTeardownBlock { await held.release() }
        try await fixture.install(held)
        try await fixture.setScene(1)
        try await fixture.recordDirtyScene()
        try await held.waitUntilPaused()
        try await fixture.setScene(2)
        try await fixture.recordDirtyScene()
        try await fixture.reportContentCompletion(2)
        let before = try await fixture.integer("window.snapshotReads")
        try await fixture.evaluate("window.sceneRevision = 3; window.scene.appState.cursorButton = 'down'")
        let resumed = try fixture.stateMessage([
            "revision": 3, "contentDirty": false, "appStateDirty": true,
            "contentInteractionActive": true, "appState": ["gridSize": 20]
        ])
        let admission = try XCTUnwrap(controller.admitStateChanged(resumed))
        await controller.save(resumed, admission: admission)
        await held.release()
        let returned = Task {
            while !(await held.resumedAfterRelease) { try await Task.sleep(for: .milliseconds(1)) }
        }
        fixture.cancelOnClose(returned)
        try await boundedSaveTestValue(returned)
        try await Task.sleep(for: .milliseconds(200))
        let duringContact = try await fixture.integer("window.snapshotReads")
        XCTAssertEqual(duringContact, before, "Resumed input must retain the ordinary five-second full cadence")
        XCTAssertTrue(controller.hasPendingDirtySnapshot)
        XCTAssertTrue(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
        XCTAssertTrue(errors.isEmpty)
        // Finishing the same content again restores its eligibility, without a new content-dirty event.
        try await fixture.evaluate("window.sceneRevision = 4; window.scene.appState.cursorButton = 'up'")
        try await fixture.reportContentCompletion(2, stateRevision: 4)
        let finished = Task {
            while controller.hasPendingDirtySnapshot { try await Task.sleep(for: .milliseconds(10)) }
        }
        fixture.cancelOnClose(finished)
        try await boundedSaveTestValue(finished)
        let finalDisk = try await fixture.libraryElementIDs()
        XCTAssertEqual(finalDisk, ["revision-2"])
        XCTAssertFalse(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
        XCTAssertTrue(errors.isEmpty)
    }

    @MainActor
    func testCompletionHintKeepsHeldFullSaveCurrentUntilItsRealReceipt() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let core = try XCTUnwrap(fixture.core)
        let controller = core.documentSyncController
        var errors: [NSError] = []
        core.publishError = { errors.append($0 as NSError) }
        // Establish the ordinary scheduler's previous start through the real public route.
        try await fixture.setScene(1)
        try await fixture.recordDirtyScene()
        let initial = Task {
            while controller.hasPendingDirtySnapshot { try await Task.sleep(for: .milliseconds(10)) }
        }
        fixture.cancelOnClose(initial)
        try await boundedSaveTestValue(initial)

        let held = LibrarySaveControl(phase: .afterStorage)
        addTeardownBlock { await held.release() }
        try await fixture.install(held)
        try await fixture.setScene(2)
        try await fixture.recordDirtyScene()
        try await fixture.reportContentCompletion(2)
        try await held.waitUntilPaused()
        XCTAssertTrue(controller.hasPendingDirtySnapshot)
        XCTAssertTrue(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
        let disk = try await fixture.libraryElementIDs()
        XCTAssertEqual(disk, ["revision-2"])

        // A duplicate timing-only notification must not replace the held capture's admission.
        try await fixture.reportContentCompletion(2)
        await held.release()
        let finished = Task {
            while controller.hasPendingDirtySnapshot { try await Task.sleep(for: .milliseconds(10)) }
        }
        fixture.cancelOnClose(finished)
        try await boundedSaveTestValue(finished)
        let resumed = await held.resumedAfterRelease
        XCTAssertTrue(resumed, "The selected write must return after explicit release, not a timeout and retry")
        XCTAssertTrue(errors.isEmpty)
        XCTAssertFalse(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
        let confirmed = try await fixture.libraryElementIDs()
        XCTAssertEqual(confirmed, ["revision-2"])
    }

    @MainActor
    func testFailedCompletionSaveRetainsLatestContentForCompletionRetry() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let core = try XCTUnwrap(fixture.core)
        let controller = core.documentSyncController
        let reported = expectation(description: "The actual storage failure stays visible")
        var errors: [NSError] = []
        core.publishError = {
            errors.append($0 as NSError)
            if errors.count == 1 { reported.fulfill() }
        }
        try await fixture.installFailure()
        try await fixture.setScene(2)
        try await fixture.recordDirtyScene()
        try await fixture.reportContentCompletion(2)
        await fulfillment(of: [reported], timeout: 2)
        XCTAssertTrue(controller.hasPendingDirtySnapshot)
        XCTAssertTrue(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
        XCTAssertTrue(errors.contains { $0.domain == NSCocoaErrorDomain && $0.code == CocoaError.fileWriteNoPermission.rawValue })
        let unchanged = try await fixture.libraryElementIDs()
        XCTAssertEqual(unchanged, [])
        try await fixture.clearControl()
        try await fixture.setScene(3)
        try await fixture.recordDirtyScene()
        try await fixture.reportContentCompletion(3)
        let retried = Task {
            while controller.hasPendingDirtySnapshot { try await Task.sleep(for: .milliseconds(10)) }
        }
        fixture.cancelOnClose(retried)
        try await boundedSaveTestValue(retried)
        let latest = try await fixture.libraryElementIDs()
        XCTAssertEqual(latest, ["revision-3"])
        XCTAssertFalse(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
    }

    @MainActor
    func testCompletionHintForCleanSceneDoesNotCreatePendingWorkOrPullSnapshot() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let core = try XCTUnwrap(fixture.core)
        let before = try await fixture.integer("window.snapshotReads")
        let externalRevision = core.documentSyncController.externalReloadRevision
        try await fixture.reportContentCompletion(1)
        XCTAssertFalse(core.documentSyncController.hasPendingDirtySnapshot)
        XCTAssertEqual(core.documentSyncController.externalReloadRevision, externalRevision)
        let after = try await fixture.integer("window.snapshotReads")
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testCompletionAdmittedBeforeSameFileReloadCannotAdvanceReplacementSession() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let core = try XCTUnwrap(fixture.core)
        let controller = core.documentSyncController
        let original = try XCTUnwrap(controller.captureCanvasMutationSession())
        let metadata = try JSONDecoder().decode(ExcalidrawCore.StateChangedMetadata.self,
            from: JSONSerialization.data(withJSONObject: [
                "revision": 2, "completedContentRevision": 2,
                "contentDirty": false, "appStateDirty": false,
                "currentFileId": original.fileID
            ]))
        let oldMessage = ExcalidrawCore.StateChangedMessageData(state: nil, fileData: nil, metadata: metadata)
        let oldAdmission = try XCTUnwrap(controller.admitStateChanged(oldMessage))
        let reload = Task { await controller.load(fixture.model.file, force: true).didLoad }
        fixture.cancelOnClose(reload)
        let didLoad = try await boundedSaveTestValue(reload)
        XCTAssertTrue(didLoad)
        let replacement = try XCTUnwrap(controller.captureCanvasMutationSession())
        XCTAssertEqual(replacement.fileID, original.fileID)
        XCTAssertGreaterThan(replacement.loadGeneration, original.loadGeneration)
        XCTAssertFalse(controller.isCurrentCanvasMutationSession(original))

        try await fixture.setScene(2)
        try await fixture.recordDirtyScene()
        let before = try await fixture.integer("window.snapshotReads")
        await controller.save(oldMessage, admission: oldAdmission)
        // The ordinary first snapshot waits one second. A stale completion must not advance it.
        try await Task.sleep(for: .milliseconds(200))
        let after = try await fixture.integer("window.snapshotReads")
        XCTAssertEqual(after, before)
        XCTAssertTrue(controller.hasPendingDirtySnapshot)
        XCTAssertTrue(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
    }

    @MainActor
    func testPublicForcedLoadInvalidatesCapturedSessionAndBroadcastsToBothSubscribers() async throws {
        let fixture = try await CanvasControllerFixture.open()
        addTeardownBlock { await fixture.close() }
        let controller = fixture.core.documentSyncController
        let original = try XCTUnwrap(controller.captureCanvasMutationSession())
        let first = LoadObservations(controller)
        let second = LoadObservations(controller)

        // Duplicate public admission must keep the existing token and emit nothing.
        let duplicate = await controller.load(fixture.model.file)
        if case .skipped = duplicate { } else { XCTFail("A confirmed duplicate must be skipped") }
        XCTAssertEqual(controller.captureCanvasMutationSession(), original)
        XCTAssertTrue(first.values.isEmpty)
        XCTAssertTrue(second.values.isEmpty)

        try await fixture.evaluate("window.holdNextLoad = true")
        let reload = Task { await controller.load(fixture.model.file, force: true).didLoad }
        fixture.cancelOnClose(reload)
        try await fixture.waitForJavaScript("window.loadPaused === true")
        XCTAssertTrue(controller.hasPendingFileLoad)
        XCTAssertFalse(controller.isCurrentCanvasMutationSession(original))
        XCTAssertNil(controller.captureCanvasMutationSession())
        XCTAssertGreaterThan(controller.currentLoadGeneration, original.loadGeneration)
        let pendingGeneration = controller.currentLoadGeneration
        XCTAssertEqual(first.values, [.init(generation: pendingGeneration, fileID: original.fileID, pending: true)])
        XCTAssertEqual(second.values, first.values)

        let rejected = await controller.load(fixture.model.file)
        if case .skipped = rejected { } else { XCTFail("An in-flight duplicate must be skipped") }
        XCTAssertEqual(controller.currentLoadGeneration, pendingGeneration)
        XCTAssertEqual(first.values.count, 1)
        XCTAssertEqual(second.values, first.values)

        try await fixture.evaluate("window.releaseLoad()")
        let loaded = try await boundedSaveTestValue(reload, timeout: .seconds(8))
        XCTAssertTrue(loaded)
        let replacement = try XCTUnwrap(controller.captureCanvasMutationSession())
        XCTAssertEqual(replacement.fileID, original.fileID)
        XCTAssertEqual(replacement.saveSession, original.saveSession)
        XCTAssertEqual(replacement.loadGeneration, pendingGeneration)
        XCTAssertFalse(controller.isCurrentCanvasMutationSession(original))
        XCTAssertTrue(controller.isCurrentCanvasMutationSession(replacement))
        XCTAssertEqual(first.values.last, .init(generation: pendingGeneration, fileID: original.fileID, pending: false))
        XCTAssertEqual(first.values.count, 2)
        XCTAssertEqual(second.values, first.values)

        controller.resetFileLoadState()
        XCTAssertNil(controller.captureCanvasMutationSession())
        XCTAssertFalse(controller.isCurrentCanvasMutationSession(replacement))
        XCTAssertEqual(first.values.last, .init(generation: controller.currentLoadGeneration, fileID: nil, pending: false))
        XCTAssertGreaterThan(controller.currentLoadGeneration, replacement.loadGeneration)
        XCTAssertEqual(first.values.count, 3)
        XCTAssertEqual(second.values, first.values)
    }

    @MainActor
    func testRealSessionInstallPublishesAssignedTokenWithoutReloadingTheScene() async throws {
        let fixture = try await CanvasControllerFixture.open()
        addTeardownBlock { await fixture.close() }
        let controller = fixture.core.documentSyncController
        let original = try XCTUnwrap(controller.captureCanvasMutationSession())
        let scene = try await fixture.scene()
        let loadCount = try await fixture.integer("window.loadCalls")
        var first: [CanvasMutationSession?] = []
        var second: [CanvasMutationSession?] = []
        let one = controller.canvasMutationSessionChanges.sink {
            MainActor.assumeIsolated { first.append(controller.captureCanvasMutationSession()) }
        }
        let two = controller.canvasMutationSessionChanges.sink {
            MainActor.assumeIsolated { second.append(controller.captureCanvasMutationSession()) }
        }
        defer { one.cancel(); two.cancel() }
        let uuid = UUID()
        fixture.state.installExternalSaveSession(uuid)
        let current = try XCTUnwrap(controller.captureCanvasMutationSession())
        XCTAssertEqual(current.fileID, original.fileID)
        XCTAssertEqual(current.loadGeneration, original.loadGeneration)
        XCTAssertEqual(current.saveSession, uuid)
        XCTAssertFalse(controller.isCurrentCanvasMutationSession(original))
        XCTAssertEqual(first, [current])
        XCTAssertEqual(second, [current])
        fixture.state.installExternalSaveSession(uuid)
        XCTAssertEqual(first, [current])
        XCTAssertEqual(second, [current])
        XCTAssertEqual(controller.captureCanvasMutationSession(), current)
        let afterScene = try await fixture.scene()
        let afterLoadCount = try await fixture.integer("window.loadCalls")
        XCTAssertEqual(afterScene, scene)
        XCTAssertEqual(afterLoadCount, loadCount)
    }

    @MainActor
    func testRealMediaHelperKeepsLifecycleFlushAndRecoveryWaitingForItsScene() async throws {
        let fixture = try await CanvasControllerFixture.open()
        addTeardownBlock { await fixture.close() }
        let core = try XCTUnwrap(fixture.core)
        let controller = core.documentSyncController
        let owner = try XCTUnwrap(controller.captureCanvasMutationSession())
        let mutation = Task {
            try await core.loadImageToExcalidrawCanvas(imageData: Data([1, 2, 3]), type: "image/png")?.elementCount
        }
        fixture.cancelOnClose(mutation)
        try await fixture.waitForJavaScript("window.imagePaused === true")
        XCTAssertTrue(controller.hasPendingDirtySnapshot, "The real helper must own dirty work before its bridge await")

        let earlyFlush = expectation(description: "Flush must not finish while the helper is held")
        let earlyRecovery = expectation(description: "Recovery must not finish while the helper is held")
        earlyFlush.isInverted = true
        earlyRecovery.isInverted = true
        let flushStarted = expectation(description: "Lifecycle flush invoked")
        let recoveryStarted = expectation(description: "Recovery export invoked")
        var checkingEarlyCompletion = true
        let flush = Task {
            flushStarted.fulfill()
            await controller.flushPendingDirtySnapshot(reason: "sceneBackground", force: true, expectedFileID: owner.fileID)
            if checkingEarlyCompletion { earlyFlush.fulfill() }
        }
        let recovery = Task {
            recoveryStarted.fulfill()
            let file = try await controller.currentCanvasFileForRecoveryExport()
            if checkingEarlyCompletion { earlyRecovery.fulfill() }
            return file
        }
        fixture.cancelOnClose(flush)
        fixture.cancelOnClose(recovery)
        await fulfillment(of: [flushStarted, recoveryStarted], timeout: 2)
        await fulfillment(of: [earlyFlush, earlyRecovery], timeout: 0.1)
        checkingEarlyCompletion = false
        let readsWhileHeld = try await fixture.integer("window.snapshotReads")
        XCTAssertEqual(readsWhileHeld, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.original)
        try await fixture.evaluate("window.releaseImage()")
        let elementCount = try await boundedSaveTestValue(mutation)
        XCTAssertEqual(elementCount, 1)
        try await boundedSaveTestValue(flush, timeout: .seconds(8))
        let recovered = try await boundedSaveTestValue(recovery, timeout: .seconds(8))
        XCTAssertEqual(recovered.id, owner.fileID)
        XCTAssertTrue(controller.isCurrentCanvasMutationSession(owner))
        let expected = try await fixture.scene()
        let persisted = try fixture.persistedScene(from: expected)
        XCTAssertEqual(try fixture.scene(from: Data(contentsOf: fixture.url)), persisted)
        XCTAssertEqual(try fixture.scene(from: XCTUnwrap(recovered.content)), expected)
        XCTAssertEqual(try fixture.scene(from: XCTUnwrap(fixture.model.file?.content)), persisted)
        XCTAssertFalse(controller.hasPendingDirtySnapshot)
        let pending = await ExternalFileSaveCoordinator.shared.pendingContent(at: fixture.url, session: owner.saveSession)
        XCTAssertNil(pending)
    }

    @MainActor
    func testLibraryFlushWaitsForRealRepositoryReturnBeforeAcknowledging() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let controller = fixture.core.documentSyncController
        let control = LibrarySaveControl(phase: .afterStorage)
        addTeardownBlock { await control.release() }
        try await fixture.install(control)
        try await fixture.setScene(2)
        try await fixture.recordDirtyScene()
        let completed = expectation(description: "Flush waits for the held repository")
        completed.isInverted = true
        var checking = true
        let flush = Task {
            await controller.flushPendingDirtySnapshot(reason: "sceneBackground", force: true)
            if checking { completed.fulfill() }
        }
        fixture.cancelOnClose(flush)
        try await control.waitUntilPaused()
        await fulfillment(of: [completed], timeout: 0.1)
        checking = false
        XCTAssertTrue(controller.hasPendingDirtySnapshot)
        XCTAssertTrue(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
        let written = try await fixture.libraryElementIDs()
        XCTAssertEqual(written, ["revision-2"], "This gate follows the real local storage return")
        await control.release()
        try await boundedSaveTestValue(flush)
        XCTAssertFalse(controller.hasPendingDirtySnapshot)
        let persisted = try await fixture.libraryElementIDs()
        XCTAssertEqual(persisted, ["revision-2"])
    }

    @MainActor
    func testLibraryFailureKeepsMirrorDirtyIntentAndNavigationVetoUntilRetry() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let core = try XCTUnwrap(fixture.core)
        let controller = core.documentSyncController
        let owner = try XCTUnwrap(controller.captureCanvasMutationSession())
        var errors: [NSError] = []
        core.publishError = { errors.append($0 as NSError) }
        try await fixture.installFailure()
        try await fixture.setScene(3)
        try await fixture.recordDirtyScene()
        let failedFlush = Task { await controller.flushPendingDirtySnapshot(reason: "sceneBackground", force: true) }
        fixture.cancelOnClose(failedFlush)
        try await boundedSaveTestValue(failedFlush)
        XCTAssertTrue(controller.hasPendingDirtySnapshot)
        XCTAssertTrue(fixture.state.canvasSaveCoordinator.hasPendingFullContent)
        let oldDisk = try await fixture.libraryElementIDs()
        XCTAssertEqual(oldDisk, [])
        XCTAssertTrue(errors.contains { $0.domain == NSCocoaErrorDomain && $0.code == CocoaError.fileWriteNoPermission.rawValue })
        let mirror = try fixture.scene(from: XCTUnwrap(fixture.model.file?.content))
        XCTAssertEqual((mirror["elements"] as? [[String: Any]])?.first?["id"] as? String, "revision-3")
        let close = Task { await fixture.state.requestActiveFileChange(nil) }
        fixture.cancelOnClose(close)
        let accepted = try await boundedSaveTestValue(close)
        XCTAssertFalse(accepted)
        XCTAssertEqual(fixture.state.currentActiveFile?.id, owner.fileID)
        try await fixture.clearControl()
        let retry = Task { await controller.flushPendingDirtySnapshot(reason: "retry", force: true) }
        fixture.cancelOnClose(retry)
        try await boundedSaveTestValue(retry)
        XCTAssertFalse(controller.hasPendingDirtySnapshot)
        let retried = try await fixture.libraryElementIDs()
        XCTAssertEqual(retried, ["revision-3"])
    }

    @MainActor
    func testLibraryOlderRepositoryCallCannotOverwriteNewerCompletedScene() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let controller = fixture.core.documentSyncController
        var errors: [NSError] = []
        fixture.core.publishError = { errors.append($0 as NSError) }
        let control = LibrarySaveControl(phase: .beforeStorage)
        addTeardownBlock { await control.release() }
        try await fixture.install(control)
        try await fixture.setScene(1)
        let old = Task { try await fixture.sendFullScene() }
        fixture.cancelOnClose(old)
        try await control.waitUntilPaused()
        try await fixture.setScene(2)
        let latest = Task { try await fixture.sendFullScene() }
        fixture.cancelOnClose(latest)
        try await boundedSaveTestValue(latest)
        let confirm = Task { await controller.flushPendingDirtySnapshot(reason: "confirmLatest", force: true) }
        fixture.cancelOnClose(confirm)
        try await boundedSaveTestValue(confirm)
        XCTAssertFalse(controller.hasPendingDirtySnapshot)
        let newestDisk = try await fixture.libraryElementIDs()
        XCTAssertEqual(newestDisk, ["revision-2"])
        await control.release()
        try await boundedSaveTestValue(old)
        let resumed = await control.resumedAfterRelease
        XCTAssertTrue(resumed, "The selected old call must resume after explicit release, not time out")
        XCTAssertTrue(errors.isEmpty, "A caught controller error cannot substitute for an old write completing")
        let finalDisk = try await fixture.libraryElementIDs()
        XCTAssertEqual(finalDisk, ["revision-2"], "A late old call must not replace newer durable content")
        XCTAssertFalse(controller.hasPendingDirtySnapshot)
    }

    @MainActor
    func testLibraryOlderAppStateWriteCannotOverwriteNewerCompletedScene() async throws {
        try await assertOlderLibraryAppStateCannotOverwriteNewerScene(capturedTarget: false)
    }

    @MainActor
    func testLibraryOlderCapturedAppStateWriteCannotOverwriteNewerCompletedScene() async throws {
        try await assertOlderLibraryAppStateCannotOverwriteNewerScene(capturedTarget: true)
    }

    @MainActor
    private func assertOlderLibraryAppStateCannotOverwriteNewerScene(capturedTarget: Bool) async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let controller = fixture.core.documentSyncController
        var errors: [NSError] = []
        fixture.core.publishError = { errors.append($0 as NSError) }
        try await fixture.setScene(1)
        let initial = Task { try await fixture.sendFullScene() }
        fixture.cancelOnClose(initial)
        try await boundedSaveTestValue(initial)

        let owner = try XCTUnwrap(fixture.state.currentActiveFile)
        let target = try XCTUnwrap(fixture.state.capturedCanvasSaveTarget(for: owner))
        let control = LibrarySaveControl(phase: .beforeStorage)
        addTeardownBlock { await control.release() }
        try await fixture.install(control)
        try await fixture.evaluate("window.scene.appState.gridSize = 20")
        try await fixture.recordDirtyAppState()
        let old = Task {
            if capturedTarget {
                await controller.flushPendingDirtySnapshotToCapturedTarget(
                    reason: "sceneBackground", expectedFileID: owner.id, target: target
                )
            } else {
                await controller.flushPendingDirtySnapshot(reason: "sceneBackground")
            }
        }
        fixture.cancelOnClose(old)
        try await control.waitUntilPaused()
        XCTAssertTrue(controller.hasPendingDirtySnapshot)

        try await fixture.setScene(2)
        try await fixture.evaluate("window.scene.appState.gridSize = 40")
        let latest = Task { try await fixture.sendFullScene() }
        fixture.cancelOnClose(latest)
        try await boundedSaveTestValue(latest)
        let confirm = Task { await controller.flushPendingDirtySnapshot(reason: "confirmLatest", force: true) }
        fixture.cancelOnClose(confirm)
        try await boundedSaveTestValue(confirm)
        let newestDisk = try await fixture.libraryDocument()
        XCTAssertEqual((newestDisk["elements"] as? [[String: Any]])?.first?["id"] as? String, "revision-2")
        XCTAssertEqual((newestDisk["appState"] as? [String: Any])?["gridSize"] as? Int, 40)
        XCTAssertFalse(controller.hasPendingDirtySnapshot)

        await control.release()
        try await boundedSaveTestValue(old)
        let resumed = await control.resumedAfterRelease
        XCTAssertTrue(resumed, "The old metadata call must resume after explicit release")
        XCTAssertTrue(errors.isEmpty, "A superseded metadata write must not report a save failure")
        let finalDisk = try await fixture.libraryDocument()
        XCTAssertEqual(finalDisk as NSDictionary, newestDisk as NSDictionary)
        XCTAssertFalse(controller.hasPendingDirtySnapshot)
    }

    @MainActor
    func testLibrarySwitchKeepsOriginalOwnerUntilHeldSaveFinishes() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let owner = try XCTUnwrap(fixture.state.currentActiveFile?.id)
        let control = LibrarySaveControl(phase: .beforeStorage)
        addTeardownBlock { await control.release() }
        try await fixture.install(control)
        try await fixture.setScene(4)
        try await fixture.recordDirtyScene()
        let transition = Task { await fixture.state.requestActiveFileChange(.temporaryFile(fixture.url)) }
        fixture.cancelOnClose(transition)
        try await control.waitUntilPaused()
        XCTAssertEqual(fixture.state.currentActiveFile?.id, owner)
        XCTAssertTrue(fixture.core.documentSyncController.hasPendingDirtySnapshot)
        let oldDisk = try await fixture.libraryElementIDs()
        XCTAssertEqual(oldDisk, [])
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.original)
        await control.release()
        let accepted = try await boundedSaveTestValue(transition)
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.state.currentActiveFile?.id, fixture.url.absoluteString)
        let saved = try await fixture.libraryElementIDs()
        XCTAssertEqual(saved, ["revision-4"])
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.original, "Outgoing content must stay on its library target")
    }

    @MainActor
    func testLibraryNewerCaptureDuringHeldFlushRemainsPendingUntilItsOwnWrite() async throws {
        let fixture = try await CanvasControllerFixture.open(library: true)
        addTeardownBlock { await fixture.close() }
        let controller = fixture.core.documentSyncController
        let control = LibrarySaveControl(phase: .afterStorage)
        addTeardownBlock { await control.release() }
        try await fixture.install(control)
        try await fixture.setScene(5)
        try await fixture.recordDirtyScene()
        let old = Task { await controller.flushPendingDirtySnapshot(reason: "sceneBackground", force: true) }
        fixture.cancelOnClose(old)
        try await control.waitUntilPaused()
        try await fixture.setScene(6)
        try await fixture.recordDirtyScene()
        await control.release()
        try await boundedSaveTestValue(old)
        XCTAssertTrue(controller.hasPendingDirtySnapshot, "The older receipt cannot acknowledge a newer capture")
        try await fixture.clearControl()
        let retry = Task { await controller.flushPendingDirtySnapshot(reason: "retryLatest", force: true) }
        fixture.cancelOnClose(retry)
        try await boundedSaveTestValue(retry)
        let persisted = try await fixture.libraryElementIDs()
        XCTAssertEqual(persisted, ["revision-6"])
        XCTAssertFalse(controller.hasPendingDirtySnapshot)
    }
}

/// The existing bounded gate holds only the first selected real repository operation.
private actor LibrarySaveControl {
    let gate = SaveTestGate()
    let phase: FileRepository.CanvasSaveTestPhase
    private var entered = false
    private(set) var resumedAfterRelease = false
    init(phase: FileRepository.CanvasSaveTestPhase) { self.phase = phase }
    func visit(_ phase: FileRepository.CanvasSaveTestPhase) async throws {
        guard phase == self.phase, !entered else { return }
        entered = true
        try await gate.pause()
        resumedAfterRelease = true
    }
    func waitUntilPaused() async throws { try await gate.waitUntilPaused() }
    func release() async { await gate.release() }
}

private struct ObservedLoad: Equatable {
    let generation: UInt64
    let fileID: String?
    let pending: Bool
}

/// Synchronous subscribers reenter the real lock-taking public getters.
private final class LoadObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [ObservedLoad] = []
    private var subscription: AnyCancellable?
    var values: [ObservedLoad] { lock.withLock { observations } }

    init(_ controller: ExcalidrawDocumentSyncController) {
        subscription = controller.canvasMutationSessionChanges.sink { [weak self] in
            let value = ObservedLoad(generation: controller.currentLoadGeneration,
                                     fileID: controller.currentLoadedFileID,
                                     pending: controller.hasPendingFileLoad)
            self?.lock.withLock { self?.observations.append(value) }
        }
    }
}

@MainActor
private final class CanvasControllerModel: ObservableObject {
    @Published var file: ExcalidrawFile?
    @Published var loadingState: ExcalidrawCanvasView.LoadingState = .idle
}

@MainActor
private struct ControllerTestCanvas: View {
    @ObservedObject var model: CanvasControllerModel
    var body: some View {
        ExcalidrawCanvasView(file: $model.file, loadingState: $model.loadingState, onError: { _ in })
    }
}

@MainActor
private final class CanvasControllerFixture {
    private struct SetupFailure: Error, CustomStringConvertible {
        let stage: String
        let underlying: Error

        var description: String {
            "Canvas controller fixture setup failed during \(stage): \(String(reflecting: type(of: underlying))): \(underlying)"
        }
    }

    // Keep a vetoed fixture and its live owner available until the test process exits.
    private static var retainedFixtures: [CanvasControllerFixture] = []
    private(set) var libraryFile: File?
    private var libraryGroup: ExcalidrawZ.Group?
    let libraryName = "Library-save-test-" + UUID().uuidString
    let state = FileState()
    let model = CanvasControllerModel()
    let toolState = ToolState()
    let exportState = ExportState()
    let preferences = CanvasPreferencesState()
    let lockedContentState = LockedContentStateStore()
    let directory: URL
    let url: URL
    let original = Data(##"{"type":"excalidraw","version":2,"source":"native-test","elements":[],"files":{},"appState":{"gridSize":10,"viewBackgroundColor":"#ffffff"}}"##.utf8)
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
    private(set) var core: ExcalidrawCore!
    private var taskCleanup: [@MainActor () async -> Bool] = []

    private init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("synthetic.excalidraw")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: url)
    }

    static func open(library: Bool = false) async throws -> CanvasControllerFixture {
        let fixture = try CanvasControllerFixture()
        var stage = "prepare open-in-place access"
        do {
            if library {
                guard ProcessInfo.processInfo.environment["EXCALIDRAWZ_ISOLATED_UI_TESTS"] == "1",
                      ProcessInfo.processInfo.environment["EXCALIDRAWZ_LIBRARY_SAVE_TESTS"] == "1",
                      Bundle.main.bundleIdentifier == "de.lenard.excalidrawz.test.integration.ExcalidrawZ",
                      !ICloudContainerConfiguration.current.isCloudKitEnabled else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                stage = "create the unique synthetic library record"
                let context = PersistenceController.shared.container.viewContext
                let group = ExcalidrawZ.Group(name: fixture.libraryName, context: context)
                try context.save()
                fixture.libraryGroup = group
                let id = try await PersistenceController.shared.fileRepository.createFile(
                    name: fixture.libraryName, content: fixture.original, groupObjectID: group.objectID
                )
                let file = try XCTUnwrap(try context.existingObject(with: id) as? File)
                fixture.libraryFile = file
                guard await fixture.state.requestActiveFileChange(.file(file)) else { throw SaveTestWaitError.timedOut }
            } else {
                // Match the actual open-from-URL entry point, including its UIDocument writer.
                try await fixture.state.prepareOpenInPlaceAccess(to: fixture.url)
                stage = "accept the synthetic document as active"
                let accepted = await fixture.state.requestActiveFileChange(.temporaryFile(fixture.url))
                guard accepted else { throw SaveTestWaitError.timedOut }
                stage = "capture the real document writer"
                let target = try XCTUnwrap(fixture.state.capturedCanvasSaveTarget(for: .temporaryFile(fixture.url)))
                XCTAssertTrue(target.isOpenInPlace)
                _ = try XCTUnwrap(target.externalWriter)
            }
            let view = ControllerTestCanvas(model: fixture.model)
                .environmentObject(fixture.state).environmentObject(fixture.toolState)
                .environmentObject(fixture.exportState).environmentObject(fixture.preferences)
                .environmentObject(fixture.lockedContentState)
                .environmentObject(AppPreference())
            fixture.window.rootViewController = UIHostingController(rootView: view)
            fixture.window.isHidden = false
            stage = "attach the canvas core and parent"
            try await fixture.waitUntil { fixture.toolState.excalidrawWebCoordinator?.parent != nil }
            fixture.core = try XCTUnwrap(fixture.toolState.excalidrawWebCoordinator)
            stage = "drain the queued initial refresh"
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            // Keep actual Core/parent/controller wiring; provide a deterministic, nonpersistent web page.
            fixture.core.webView.navigationDelegate = nil
            fixture.core.webView.stopLoading()
            stage = "load the inline web fixture"
            fixture.core.webView.loadHTMLString(Self.html, baseURL: nil)
            try await fixture.waitForJavaScript("window.fixtureReady === true")
            fixture.core.hasInjectIndexedDBData = true
            fixture.core.isNavigating = false
            fixture.core.isDocumentLoaded = true
            stage = "decode the synthetic document"
            fixture.model.file = try ExcalidrawFile(data: fixture.original, id: try XCTUnwrap(fixture.state.currentActiveFile?.id))
            stage = "confirm the loaded canvas session and temporary row"
            try await fixture.waitUntil {
                fixture.core.documentSyncController.captureCanvasMutationSession() != nil
                    && (library || fixture.state.temporaryFiles.contains(fixture.url))
            }
            if !library {
                stage = "record the external read baseline"
                let session = try await fixture.state.recordExternalFileRead(fixture.original, at: fixture.url)
                fixture.state.installExternalSaveSession(session)
            }
            stage = "wait for the update gate to accept canvas saves"
            try await fixture.waitUntil { !fixture.state.shouldIgnoreUpdate && !fixture.core.isLoading }
            return fixture
        } catch {
            let failure = SetupFailure(stage: stage, underlying: error)
            await fixture.close()
            throw failure
        }
    }

    func cancelOnClose<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>) {
        taskCleanup.append {
            task.cancel()
            do {
                _ = try await boundedSaveTestValue(task)
                return true
            } catch SaveTestWaitError.timedOut {
                return false
            } catch {
                // A completed task error still confirms that the task has stopped.
                return true
            }
        }
    }

    func close() async {
        // Release held bridge work before cancelling/resetting its native owner.
        if core != nil {
            try? await evaluate("window.releaseLoad?.(); window.releaseImage?.();")
        }
        if let libraryFile {
            try? await PersistenceController.shared.fileRepository.setCanvasSaveTestControl(
                fileObjectID: libraryFile.objectID, expectedName: libraryName, operation: nil
            )
        }
        for cleanup in taskCleanup {
            guard await cleanup() else {
                Self.retainedFixtures.append(self)
                XCTFail("Synthetic task completion unconfirmed; live owner and data retained at \(directory.path)")
                return
            }
        }
        let session = state.externalSaveSessionID
        var stage = "flush the original canvas owner"
        do {
            if let core {
                let flush = Task { await core.documentSyncController.flushPendingDirtySnapshot(reason: "testCleanup", force: true) }
                try await boundedSaveTestValue(flush, timeout: .seconds(8))
            }
            stage = "accept navigation close with the core and writer attached"
            let close = Task { await state.requestActiveFileChange(nil) }
            let accepted = try await boundedSaveTestValue(close, timeout: .seconds(8))
            guard accepted else {
                Self.retainedFixtures.append(self)
                XCTFail("Synthetic navigation close was vetoed; live owner and data retained at \(directory.path)")
                return
            }
            let pending = await ExternalFileSaveCoordinator.shared.pendingContent(at: url, session: session)
            guard pending == nil, core?.documentSyncController.hasPendingDirtySnapshot != true else {
                Self.retainedFixtures.append(self)
                XCTFail("Synthetic save remains pending after close; owner and data retained at \(directory.path)")
                return
            }
        } catch {
            Self.retainedFixtures.append(self)
            XCTFail("Synthetic cleanup failed during \(stage): \(error); owner and data retained at \(directory.path)")
            return
        }
        core?.documentSyncController.resetFileLoadState()
        core?.webView.stopLoading()
        core?.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        core?.parent = nil
        state.currentGroupPublisherCancellables.forEach { $0.cancel() }
        state.excalidrawWebCoordinator = nil
        toolState.excalidrawWebCoordinator = nil
        exportState.excalidrawWebCoordinator = nil
        preferences.coordinator = nil
        window.isHidden = true
        window.rootViewController = nil
        await ExternalFileSaveCoordinator.shared.releaseSession(session)
        state.temporaryFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        do {
            // Access ownership closes UIDocument after its existing five-second grace period.
            try await waitUntil {
                !NSFileCoordinator.filePresenters.contains {
                    $0.presentedItemURL?.standardizedFileURL == self.url.standardizedFileURL
                }
            }
            let pending = await ExternalFileSaveCoordinator.shared.pendingContent(at: url, session: session)
            guard pending == nil else {
                XCTFail("Synthetic failed save retained for diagnosis at \(directory.path)")
                return
            }
            if let libraryFile {
                try await PersistenceController.shared.fileRepository.delete(
                    fileObjectID: libraryFile.objectID, forcePermanently: true
                )
                if let libraryGroup {
                    let context = PersistenceController.shared.container.viewContext
                    context.delete(libraryGroup)
                    try context.save()
                }
            }
            try FileManager.default.removeItem(at: directory)
        } catch {
            XCTFail("Synthetic document cleanup did not finish: \(error)")
        }
    }

    func install(_ control: LibrarySaveControl) async throws {
        let file = try XCTUnwrap(libraryFile)
        XCTAssertEqual(state.currentActiveFile?.id, file.id?.uuidString)
        try await PersistenceController.shared.fileRepository.setCanvasSaveTestControl(
            fileObjectID: file.objectID, expectedName: libraryName
        ) { phase in try await control.visit(phase) }
    }

    func installFailure() async throws {
        let file = try XCTUnwrap(libraryFile)
        try await PersistenceController.shared.fileRepository.setCanvasSaveTestControl(
            fileObjectID: file.objectID, expectedName: libraryName
        ) { phase in
            if phase == .beforeStorage { throw CocoaError(.fileWriteNoPermission) }
        }
    }

    func clearControl() async throws {
        let file = try XCTUnwrap(libraryFile)
        try await PersistenceController.shared.fileRepository.setCanvasSaveTestControl(
            fileObjectID: file.objectID, expectedName: libraryName, operation: nil
        )
    }

    func setScene(_ revision: Int) async throws {
        try await evaluate("""
        window.scene.elements = [{type:"rectangle", id:"revision-\(revision)", x:\(revision), y:2,
          width:3, height:4, strokeColor:"#000000", backgroundColor:"transparent", fillStyle:"solid",
          strokeWidth:1, strokeStyle:"solid", roughness:0, opacity:100, angle:0,
          seed:1, version:\(revision), versionNonce:1, isDeleted:false, groupIds:[]}];
        window.sceneRevision = \(revision);
        """)
    }

    func sendFullScene() async throws {
        let json = try JSONSerialization.data(withJSONObject: try await scene())
        let message = ExcalidrawCore.StateChangedMessageData(
            state: nil, fileData: .init(documentData: json, elements: nil, files: [:]), metadata: nil
        )
        let admission = try XCTUnwrap(core.documentSyncController.admitStateChanged(message))
        await core.documentSyncController.save(message, admission: admission)
    }

    func recordDirtyScene() async throws {
        let metadata = try JSONDecoder().decode(ExcalidrawCore.StateChangedMetadata.self,
            from: Data("{\"revision\":\(try await integer("window.sceneRevision")),\"contentDirty\":true}".utf8))
        let message = ExcalidrawCore.StateChangedMessageData(state: nil, fileData: nil, metadata: metadata)
        let admission = try XCTUnwrap(core.documentSyncController.admitStateChanged(message))
        await core.documentSyncController.save(message, admission: admission)
    }

    func stateMessage(_ fields: [String: Any]) throws -> ExcalidrawCore.StateChangedMessageData {
        var fields = fields
        fields["currentFileId"] = try XCTUnwrap(model.file?.id)
        let metadata = try JSONDecoder().decode(ExcalidrawCore.StateChangedMetadata.self,
            from: JSONSerialization.data(withJSONObject: fields))
        return .init(state: nil, fileData: nil, metadata: metadata)
    }

    func reportContentCompletion(_ revision: Int, stateRevision: Int? = nil) async throws {
        let metadata = try JSONDecoder().decode(ExcalidrawCore.StateChangedMetadata.self,
            from: JSONSerialization.data(withJSONObject: [
                "revision": stateRevision ?? revision, "completedContentRevision": revision,
                "contentDirty": false, "appStateDirty": false,
                "currentFileId": try XCTUnwrap(model.file?.id)
            ]))
        let message = ExcalidrawCore.StateChangedMessageData(state: nil, fileData: nil, metadata: metadata)
        let admission = try XCTUnwrap(core.documentSyncController.admitStateChanged(message))
        await core.documentSyncController.save(message, admission: admission)
    }

    func recordDirtyAppState() async throws {
        let currentScene = try await scene()
        let json = try JSONSerialization.data(withJSONObject: [
            "revision": try await integer("window.sceneRevision"),
            "appStateDirty": true,
            "appState": try XCTUnwrap(currentScene["appState"])
        ])
        let metadata = try JSONDecoder().decode(ExcalidrawCore.StateChangedMetadata.self, from: json)
        let message = ExcalidrawCore.StateChangedMessageData(state: nil, fileData: nil, metadata: metadata)
        let admission = try XCTUnwrap(core.documentSyncController.admitStateChanged(message))
        await core.documentSyncController.save(message, admission: admission)
    }

    func libraryElementIDs() async throws -> [String] {
        let object = try await libraryDocument()
        return try XCTUnwrap(object["elements"] as? [[String: Any]]).compactMap { $0["id"] as? String }
    }

    func libraryDocument() async throws -> [String: Any] {
        let id = try XCTUnwrap(libraryFile?.objectID)
        let context = PersistenceController.shared.newTaskContext()
        let path = try await context.perform {
            let file = try XCTUnwrap(try context.existingObject(with: id) as? File)
            return try XCTUnwrap(file.filePath)
        }
        let data = try await LocalStorageManager().loadContent(relativePath: path)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object
    }

    func evaluate(_ script: String) async throws {
        let task = Task { _ = try await core.webView.evaluateJavaScript(script) }
        try await boundedSaveTestValue(task)
    }

    func integer(_ script: String) async throws -> Int {
        let task = Task { try await core.webView.evaluateJavaScript(script) as? Int }
        let value = try await boundedSaveTestValue(task)
        return try XCTUnwrap(value)
    }

    func scene() async throws -> NSDictionary {
        let task = Task { try await core.webView.evaluateJavaScript("JSON.stringify(window.scene)") as? String }
        let value = try await boundedSaveTestValue(task)
        let json = try XCTUnwrap(value)
        return try scene(from: Data(json.utf8))
    }

    func scene(from data: Data) throws -> NSDictionary {
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return ["elements": try XCTUnwrap(document["elements"]),
                "appState": try XCTUnwrap(document["appState"]),
                "files": try XCTUnwrap(document["files"])] as NSDictionary
    }

    func persistedScene(from liveScene: NSDictionary) throws -> NSDictionary {
        var expected = try XCTUnwrap(liveScene as? [String: Any])
        var appState = try XCTUnwrap(expected["appState"] as? [String: Any])
        appState["name"] = "synthetic"
        expected["appState"] = appState
        return expected as NSDictionary
    }

    func waitForJavaScript(_ condition: String) async throws {
        try await waitUntil {
            guard !self.core.webView.isLoading else { return false }
            let task = Task { (try? await self.core.webView.evaluateJavaScript(condition)) as? Bool }
            return try await boundedSaveTestValue(task) == true
        }
    }

    private func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while true {
            if try await condition() { return }
            guard ContinuousClock.now < deadline else { throw SaveTestWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let html = #"""
    <!doctype html><script>
    window.scene = {elements: [], appState: {gridSize: 10, viewBackgroundColor: "#ffffff"}, files: {}};
    window.loadCalls = 0; window.snapshotReads = 0; window.sceneRevision = 1;
    const helper = {
      _api: {getAppState: () => window.scene.appState},
      async loadFileBuffer(buffer, id, requestId) {
        window.loadCalls++;
        if (window.holdNextLoad) {
          window.holdNextLoad = false;
          window.loadPaused = true;
          await new Promise(resolve => window.releaseLoad = resolve);
          window.loadPaused = false;
        }
        window.scene = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer)));
        helper.currentFileId = id;
        return {fileId: id, requestId, elementCount: window.scene.elements.length, durationMs: 0};
      },
      requestCurrentFileSaveStream: () => ({supported: false}),
      getCurrentFileSnapshot() { window.snapshotReads++; return {...window.scene, revision: window.sceneRevision}; },
      async loadImageBuffer(buffer, type) {
        window.imagePaused = true;
        await new Promise(resolve => window.releaseImage = resolve);
        window.imagePaused = false;
        window.scene.elements.push({type:"rectangle", id:"completed-image-operation", x:1, y:2,
          width:3, height:4, strokeColor:"#000000", backgroundColor:"transparent", fillStyle:"solid",
          strokeWidth:1, strokeStyle:"solid", roughness:0, opacity:100, angle:0,
          seed:1, version:1, versionNonce:1, isDeleted:false, groupIds:[]});
        return {elementCount: window.scene.elements.length, durationMs: 0};
      }
    };
    window.excalidrawZHelper = new Proxy(helper, {get: (target, key) => target[key] ?? (() => null)});
    window.fixtureReady = true;
    </script>
    """#
}
#endif
