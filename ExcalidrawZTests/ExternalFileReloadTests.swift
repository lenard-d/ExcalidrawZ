import Foundation
import XCTest
@testable import ExcalidrawZ

final class ExternalFileReloadTests: XCTestCase {
    private let original = Data(#"{"elements":[{"id":"original"}],"files":{},"appState":{}}"#.utf8)
    private let saved = Data(#"{"elements":[{"id":"saved"}],"files":{},"appState":{}}"#.utf8)
    private let latest = Data(#"{"elements":[{"id":"latest-stroke"}],"files":{},"appState":{}}"#.utf8)

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Synthetic.excalidraw")
        try original.write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> ExternalFileVersion {
        try ExternalFileVersion(content: Data(contentsOf: url), at: url)
    }

    func testConfirmedSaveNotificationDuringNewStrokeDoesNotReload() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        try await coordinator.save(saved, to: url, session: session, writer: ExternalFileWriter.write)
        let notification = try read(url)
        let replacement = try await coordinator.prepareReload(notification, at: url, session: session, hasPendingCanvasEdits: true)
        XCTAssertNil(replacement)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), latest)
    }

    func testDuplicateNotificationPreservesFailedPendingEditsAndRetry() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        do {
            try await coordinator.save(latest, to: url, session: session) { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
            XCTFail("The injected write must fail")
        } catch is ExternalFileSaveFailure { }
        let replacement = try await coordinator.prepareReload(try read(url), at: url, session: session, hasPendingCanvasEdits: true)
        XCTAssertNil(replacement)
        let pending = await coordinator.pendingContent(at: url, session: session)
        XCTAssertEqual(pending, latest)
        try await coordinator.retry(at: url, session: session, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), latest)
    }

    func testChangedBytesWithPendingStrokeRejectReloadAndOverwrite() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        try saved.write(to: url)
        do {
            _ = try await coordinator.prepareReload(try read(url), at: url, session: session, hasPendingCanvasEdits: true)
            XCTFail("A real changed version must not replace a live stroke")
        } catch is ExternalFileConflict { }
        do {
            try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
            XCTFail("The real changed version must not be overwritten")
        } catch let failure as ExternalFileSaveFailure {
            XCTAssertTrue(failure.cause is ExternalFileConflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), saved)
        let pending = await coordinator.pendingContent(at: url, session: session)
        XCTAssertEqual(pending, latest)
    }

    func testSameBytesWithNewIdentityAreNotAnOwnSaveNotification() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        let baseline = try read(url)
        _ = await coordinator.recordRead(baseline, at: url, session: session)
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("old"))
        try original.write(to: url)
        let replacement = try read(url)
        XCTAssertNotNil(baseline.identity)
        XCTAssertNotEqual(baseline.identity, replacement.identity)
        do {
            _ = try await coordinator.prepareReload(replacement, at: url, session: session, hasPendingCanvasEdits: true)
            XCTFail("Equal bytes cannot hide a different file identity")
        } catch is ExternalFileConflict { }
        do {
            try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
            XCTFail("The stale identity must still block the writer")
        } catch let failure as ExternalFileSaveFailure {
            XCTAssertTrue(failure.cause is ExternalFileConflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCleanExternalReplacementRequiresItsOwnAcceptedSession() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let oldSession = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: oldSession)
        try saved.write(to: url)
        let prepared = try await coordinator.prepareReload(try read(url), at: url, session: oldSession, hasPendingCanvasEdits: false)
        let newSession = try XCTUnwrap(prepared)
        do {
            try await coordinator.save(latest, to: url, session: oldSession, writer: ExternalFileWriter.write)
            XCTFail("Preparation cannot change the old session baseline")
        } catch is ExternalFileSaveFailure { }
        try await coordinator.save(latest, to: url, session: newSession, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), latest)
    }

    func testAnotherSessionCannotClaimThisSessionsConfirmedSave() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let first = UUID()
        let second = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: first)
        _ = await coordinator.recordRead(try read(url), at: url, session: second)
        try await coordinator.save(saved, to: url, session: first, writer: ExternalFileWriter.write)
        do {
            _ = try await coordinator.prepareReload(try read(url), at: url, session: second, hasPendingCanvasEdits: true)
            XCTFail("A different session must not absorb the first session's saved version")
        } catch is ExternalFileConflict { }
    }

    @MainActor
    func testFileStateDuplicatePreparationDoesNotChangeOwnerOrLiveError() async throws {
        let url = try fixture()
        let state = FileState()
        let session = try await state.recordExternalFileRead(original, at: url)
        state.installExternalSaveSession(session)
        let owner = state.terminationSaveToken
        state.reportExternalSaveFailure(CocoaError(.fileWriteNoPermission), at: url)
        let existingError = state.externalSaveErrorMessage
        let replacement = try await state.prepareExternalFileReload(at: url)
        XCTAssertNil(replacement)
        XCTAssertEqual(state.terminationSaveToken, owner)
        XCTAssertEqual(state.externalSaveErrorMessage, existingError)
        await ExternalFileSaveCoordinator.shared.releaseSession(session)
    }

    @MainActor
    func testDelayedSaveANotificationAfterSaveBReadsConfirmedB() async throws {
        let url = try fixture()
        let state = FileState()
        let session = try await state.recordExternalFileRead(original, at: url)
        state.installExternalSaveSession(session)
        let coordinator = ExternalFileSaveCoordinator.shared
        try await coordinator.save(saved, to: url, session: session, writer: ExternalFileWriter.write)
        let delayedNotification = try read(url)
        try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
        let current = try await ExternalFileVersion.read(at: url)
        XCTAssertEqual(delayedNotification.content, saved)
        XCTAssertEqual(current.content, latest)
        XCTAssertNotEqual(delayedNotification.identity, current.identity)
        let owner = state.terminationSaveToken
        let replacement = try await state.prepareExternalFileReload(at: url)
        XCTAssertNil(replacement)
        XCTAssertEqual(state.terminationSaveToken, owner)
        XCTAssertEqual(try Data(contentsOf: url), latest)
        await coordinator.releaseSession(session)
    }

    @MainActor
    func testDelayedOwnNotificationCannotHideANewerExternalEdit() async throws {
        let url = try fixture()
        let state = FileState()
        let session = try await state.recordExternalFileRead(original, at: url)
        state.installExternalSaveSession(session)
        let coordinator = ExternalFileSaveCoordinator.shared
        try await coordinator.save(saved, to: url, session: session, writer: ExternalFileWriter.write)
        try latest.write(to: url)
        let prepared = try await state.prepareExternalFileReload(at: url)
        let replacement = try XCTUnwrap(prepared)
        XCTAssertEqual(replacement.content, latest)
        XCTAssertNotEqual(replacement.session, session)
        do {
            try await coordinator.save(original, to: url, session: session, writer: ExternalFileWriter.write)
            XCTFail("A delayed notification cannot advance the original writer baseline")
        } catch let failure as ExternalFileSaveFailure {
            XCTAssertTrue(failure.cause is ExternalFileConflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), latest)
        await coordinator.releaseSession(replacement.session)
        await coordinator.releaseSession(session)
    }
}
