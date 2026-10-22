import Foundation
import XCTest
@testable import ExcalidrawZ

final class ExternalFileSaveCoordinatorTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Drawing.excalidraw")
        try Data("original".utf8).write(to: url)
        return url
    }

    private func register(_ coordinator: ExternalFileSaveCoordinator, at url: URL) async throws {
        let version = try ExternalFileVersion(content: Data(contentsOf: url), at: url)
        let accepted = await coordinator.recordRead(version, at: url)
        XCTAssertTrue(accepted)
    }

    func testPreparedMutationCannotOverwriteInterveningEditorSave() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let editor = UUID()
        let mutation = UUID()
        _ = await coordinator.recordRead(try ExternalFileVersion(content: Data(contentsOf: url), at: url), at: url, session: editor)
        try await coordinator.forkSession(at: url, from: editor, to: mutation)
        try await coordinator.save(Data("new editor content".utf8), to: url, session: editor, writer: ExternalFileWriter.write)
        do {
            try await coordinator.save(Data("prepared restore".utf8), to: url, session: mutation, writer: ExternalFileWriter.write)
            XCTFail("An intervening edit must conflict with the prepared mutation")
        } catch let failure as ExternalFileSaveFailure {
            XCTAssertTrue(failure.cause is ExternalFileConflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("new editor content".utf8))
        let pending = await coordinator.pendingContent(at: url, session: mutation)
        XCTAssertEqual(pending, Data("prepared restore".utf8))
    }

    func testSuccessfulMutationSessionSupportsNextEditorSave() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let editor = UUID()
        let mutation = UUID()
        _ = await coordinator.recordRead(try ExternalFileVersion(content: Data(contentsOf: url), at: url), at: url, session: editor)
        try await coordinator.forkSession(at: url, from: editor, to: mutation)
        try await coordinator.save(Data("restored drawing".utf8), to: url, session: mutation, writer: ExternalFileWriter.write)
        await coordinator.releaseSession(editor)
        try await coordinator.save(Data("edit after restore".utf8), to: url, session: mutation, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), Data("edit after restore".utf8))
    }

    func testFailedEditorSaveCannotBeBypassedByPreparedMutation() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let editor = UUID()
        _ = await coordinator.recordRead(try ExternalFileVersion(content: Data(contentsOf: url), at: url), at: url, session: editor)
        do {
            try await coordinator.save(Data("unsaved editor content".utf8), to: url, session: editor) { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        } catch is ExternalFileSaveFailure { }
        do {
            try await coordinator.forkSession(at: url, from: editor, to: UUID())
            XCTFail("Failed pending content must prevent a replacement mutation")
        } catch is ExternalFileSaveFailure { }
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
        let pending = await coordinator.pendingContent(at: url, session: editor)
        XCTAssertEqual(pending, Data("unsaved editor content".utf8))
    }

    func testStaleReaderCannotAdoptAnotherReadersBaseline() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let firstSession = UUID()
        let secondSession = UUID()
        let original = try ExternalFileVersion(content: Data(contentsOf: url), at: url)
        let firstAccepted = await coordinator.recordRead(original, at: url, session: firstSession)
        XCTAssertTrue(firstAccepted)
        try Data("external edit".utf8).write(to: url)
        let external = try ExternalFileVersion(content: Data(contentsOf: url), at: url)
        let secondAccepted = await coordinator.recordRead(external, at: url, session: secondSession)
        XCTAssertTrue(secondAccepted)
        do {
            try await coordinator.save(Data("stale local edit".utf8), to: url, session: firstSession, writer: ExternalFileWriter.write)
            XCTFail("A second reader must not advance the first reader's expected version")
        } catch is ExternalFileSaveFailure { }
        XCTAssertEqual(try Data(contentsOf: url), external.content)
        let pending = await coordinator.pendingContent(at: url, session: firstSession)
        XCTAssertEqual(pending, Data("stale local edit".utf8))
        try await coordinator.save(Data("second reader edit".utf8), to: url, session: secondSession, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), Data("second reader edit".utf8))
        do {
            try await coordinator.retry(at: url, session: firstSession, writer: ExternalFileWriter.write)
            XCTFail("Another reader's save must not acknowledge stale edits")
        } catch is ExternalFileSaveFailure { }
    }

    func testPreparedButRejectedReloadDoesNotAdvanceActiveReader() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let activeSession = UUID()
        let preparedReloadSession = UUID()
        let original = try ExternalFileVersion(content: Data(contentsOf: url), at: url)
        _ = await coordinator.recordRead(original, at: url, session: activeSession)
        try Data("external edit".utf8).write(to: url)
        let refreshed = try ExternalFileVersion(content: Data(contentsOf: url), at: url)
        _ = await coordinator.recordRead(refreshed, at: url, session: preparedReloadSession)
        // The editor rejects this prepared reload after a new dirty event.
        // Its current captured target still carries activeSession.
        do {
            try await coordinator.save(Data("edit during reload".utf8), to: url, session: activeSession, writer: ExternalFileWriter.write)
            XCTFail("A prepared read must not change the active reader's baseline")
        } catch is ExternalFileSaveFailure { }
        XCTAssertEqual(try Data(contentsOf: url), refreshed.content)
        let pending = await coordinator.pendingContent(at: url, session: activeSession)
        XCTAssertEqual(pending, Data("edit during reload".utf8))
    }

    func testAcceptedIdenticalReplacementSessionSupportsNextEdit() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let original = try ExternalFileVersion(content: Data(contentsOf: url), at: url)
        try XCTSkipIf(original.identity == nil, "File system does not supply identity")
        let oldSession = UUID()
        let acceptedSession = UUID()
        _ = await coordinator.recordRead(original, at: url, session: oldSession)
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("old"))
        try original.content.write(to: url)
        let replacement = try ExternalFileVersion(content: Data(contentsOf: url), at: url)
        XCTAssertEqual(replacement.content, original.content)
        XCTAssertNotEqual(replacement.identity, original.identity)
        let accepted = await coordinator.recordRead(replacement, at: url, session: acceptedSession)
        XCTAssertTrue(accepted)
        await coordinator.releaseSession(oldSession)
        try await coordinator.save(Data("next edit".utf8), to: url, session: acceptedSession, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), Data("next edit".utf8))
        let pending = await coordinator.pendingContent(at: url, session: acceptedSession)
        XCTAssertNil(pending)
    }

    func testMetadataMergePreservesLatestViewportAndSceneState() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let latest = Data(#"{"elements":["latest"],"appState":{"scrollX":99,"zoom":{"value":2},"name":"Native","gridSize":20}}"#.utf8)
        try latest.write(to: url)
        try await register(coordinator, at: url)
        let stale = Data(#"{"elements":["stale"],"appState":{"scrollX":0,"zoom":{"value":1},"name":"Old","gridSize":40}}"#.utf8)
        try await coordinator.saveAppState(from: stale, to: url, writer: ExternalFileWriter.write)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let appState = try XCTUnwrap(result["appState"] as? [String: Any])
        XCTAssertEqual(result["elements"] as? [String], ["latest"])
        XCTAssertEqual(appState["gridSize"] as? Int, 40)
        XCTAssertEqual(appState["scrollX"] as? Int, 99)
        XCTAssertEqual(appState["zoom"] as? [String: Int], ["value": 2])
        XCTAssertEqual(appState["name"] as? String, "Native")
    }

    func testCleanCloseReleasesBaselineAndReopenUsesNewRead() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let closed = UUID()
        _ = await coordinator.recordRead(try ExternalFileVersion(content: Data(contentsOf: url), at: url), at: url, session: closed)
        try await coordinator.save(Data("saved".utf8), to: url, session: closed, writer: ExternalFileWriter.write)
        await coordinator.releaseSession(closed)
        do {
            try await coordinator.save(Data("late callback".utf8), to: url, session: closed, writer: ExternalFileWriter.write)
            XCTFail("A closed clean session must no longer have a baseline")
        } catch is ExternalFileSaveFailure { }
        XCTAssertEqual(try Data(contentsOf: url), Data("saved".utf8))
        let reopened = UUID()
        _ = await coordinator.recordRead(try ExternalFileVersion(content: Data(contentsOf: url), at: url), at: url, session: reopened)
        try await coordinator.save(Data("reopened edit".utf8), to: url, session: reopened, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), Data("reopened edit".utf8))
    }

    func testReleaseRetainsFailedSessionUntilRetry() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let failed = UUID()
        _ = await coordinator.recordRead(try ExternalFileVersion(content: Data(contentsOf: url), at: url), at: url, session: failed)
        do {
            try await coordinator.save(Data("unsaved edit".utf8), to: url, session: failed) { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        } catch is ExternalFileSaveFailure { }
        await coordinator.releaseSession(failed)
        let pending = await coordinator.pendingContent(at: url, session: failed)
        XCTAssertEqual(pending, Data("unsaved edit".utf8))
        try await coordinator.retry(at: url, session: failed, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), Data("unsaved edit".utf8))
    }

    func testReleaseCannotEvictInFlightOrOtherReaderBaseline() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let first = UUID()
        let second = UUID()
        let original = try ExternalFileVersion(content: Data(contentsOf: url), at: url)
        _ = await coordinator.recordRead(original, at: url, session: first)
        _ = await coordinator.recordRead(original, at: url, session: second)
        let gate = SaveGate()
        let write = Task {
            try await coordinator.save(Data("first edit".utf8), to: url, session: first) { content, target, baseline in
                try await gate.pause()
                return try await ExternalFileWriter.write(content, to: target, replacing: baseline)
            }
        }
        await gate.waitUntilPaused()
        await coordinator.releaseSession(first)
        await gate.release()
        try await write.value
        do {
            try await coordinator.save(Data("late callback".utf8), to: url, session: first, writer: ExternalFileWriter.write)
            XCTFail("A released session must be cleaned after its in-flight write succeeds")
        } catch let failure as ExternalFileSaveFailure {
            XCTAssertFalse(failure.cause is ExternalFileConflict)
        }
        // Reader two still has its own original expected version, so its conflict must be detected.
        do {
            try await coordinator.save(Data("stale second edit".utf8), to: url, session: second, writer: ExternalFileWriter.write)
            XCTFail("Expected the second reader's independent conflict")
        } catch let failure as ExternalFileSaveFailure {
            XCTAssertTrue(failure.cause is ExternalFileConflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("first edit".utf8))
    }

    func testFailureKeepsOriginalAndPendingUntilRetry() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        try await register(coordinator, at: url)
        let latest = Data("latest drawing".utf8)
        do {
            try await coordinator.save(latest, to: url) { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
            XCTFail("A failed writer must fail its caller")
        } catch is ExternalFileSaveFailure { }
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
        let pending = await coordinator.pendingContent(at: url)
        XCTAssertEqual(pending, latest)
        let reloadAccepted = await coordinator.recordRead(try ExternalFileVersion(content: Data("remote".utf8), at: url), at: url)
        XCTAssertFalse(reloadAccepted)
        try await coordinator.retry(at: url, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), latest)
        let remaining = await coordinator.pendingContent(at: url)
        XCTAssertNil(remaining)
    }

    func testRetryUsesLatestPayloadAndCapturedTarget() async throws {
        let first = try fixture()
        let second = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        try await register(coordinator, at: first)
        try await register(coordinator, at: second)
        for payload in ["old", "latest"] {
            do {
                try await coordinator.save(Data(payload.utf8), to: first) { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
                XCTFail("Expected failure")
            } catch is ExternalFileSaveFailure { }
        }
        try await coordinator.save(Data("second drawing".utf8), to: second, writer: ExternalFileWriter.write)
        try await coordinator.retry(at: first, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: first), Data("latest".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second drawing".utf8))
    }

    func testExternalChangeIsPreservedAndRetryStillRefusesOverwrite() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        try await register(coordinator, at: url)
        try Data("external edit".utf8).write(to: url)
        do {
            try await coordinator.save(Data("local edit".utf8), to: url, writer: ExternalFileWriter.write)
            XCTFail("Must reject changed baseline")
        } catch is ExternalFileSaveFailure { }
        do {
            try await coordinator.retry(at: url, writer: ExternalFileWriter.write)
            XCTFail("Retry must not reset the baseline")
        } catch is ExternalFileSaveFailure { }
        XCTAssertEqual(try Data(contentsOf: url), Data("external edit".utf8))
        let pending = await coordinator.pendingContent(at: url)
        XCTAssertEqual(pending, Data("local edit".utf8))
    }

    func testDeletedFileIsNotRecreatedBySave() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        try await register(coordinator, at: url)
        try FileManager.default.removeItem(at: url)
        do {
            try await coordinator.save(Data("local edit".utf8), to: url, writer: ExternalFileWriter.write)
            XCTFail("Must not recreate a deleted target")
        } catch is ExternalFileSaveFailure { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let pending = await coordinator.pendingContent(at: url)
        XCTAssertNotNil(pending)
    }

    func testRecreatedFileWithSameBytesHasDifferentIdentity() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let original = try ExternalFileVersion(content: Data(contentsOf: url), at: url)
        try XCTSkipIf(original.identity == nil, "File system does not supply identity")
        try await register(coordinator, at: url)
        // Keep the old inode allocated so a new file cannot reuse it.
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("old"))
        try original.content.write(to: url)
        do {
            try await coordinator.save(Data("local edit".utf8), to: url, writer: ExternalFileWriter.write)
            XCTFail("Must reject replacement identity")
        } catch is ExternalFileSaveFailure { }
        XCTAssertEqual(try Data(contentsOf: url), original.content)
    }

    func testUnregisteredMovedTargetCannotReceiveWrite() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        try await register(coordinator, at: url)
        let moved = url.deletingLastPathComponent().appendingPathComponent("Moved.excalidraw")
        try FileManager.default.moveItem(at: url, to: moved)
        do {
            try await coordinator.save(Data("local edit".utf8), to: moved, writer: ExternalFileWriter.write)
            XCTFail("A new URL needs an accepted read")
        } catch is ExternalFileSaveFailure { }
        XCTAssertEqual(try Data(contentsOf: moved), Data("original".utf8))
    }

    func testStandardizedAliasesSharePendingContent() async throws {
        let url = try fixture()
        let alias = url.deletingLastPathComponent().appendingPathComponent("sub/../Drawing.excalidraw")
        let coordinator = ExternalFileSaveCoordinator()
        try await register(coordinator, at: url)
        do {
            try await coordinator.save(Data("latest".utf8), to: alias) { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        } catch is ExternalFileSaveFailure { }
        try await coordinator.retry(at: url, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), Data("latest".utf8))
    }

    func testQueuedRevisionsFinishWithLatestContent() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        try await register(coordinator, at: url)
        let gate = SaveGate()
        let first = Task {
            try await coordinator.save(Data("first".utf8), to: url) { content, target, baseline in
                try await gate.pause()
                return try await ExternalFileWriter.write(content, to: target, replacing: baseline)
            }
        }
        await gate.waitUntilPaused()
        let second = Task { try await coordinator.save(Data("latest".utf8), to: url, writer: ExternalFileWriter.write) }
        try await waitForPending(Data("latest".utf8), at: url, coordinator: coordinator)
        await gate.release()
        try await first.value
        try await second.value
        XCTAssertEqual(try Data(contentsOf: url), Data("latest".utf8))
    }

    func testAppStateSaveKeepsElementsFromQueuedContent() async throws {
        let url = try fixture()
        let initial = Data(#"{"elements":["original"],"appState":{"currentItemStrokeColor":"old"}}"#.utf8)
        try initial.write(to: url)
        let coordinator = ExternalFileSaveCoordinator()
        try await register(coordinator, at: url)
        let gate = SaveGate()
        let full = Data(#"{"elements":["latest"],"appState":{"currentItemStrokeColor":"old"}}"#.utf8)
        let first = Task {
            try await coordinator.save(full, to: url) { content, target, baseline in
                try await gate.pause()
                return try await ExternalFileWriter.write(content, to: target, replacing: baseline)
            }
        }
        await gate.waitUntilPaused()
        let metadata = Data(#"{"elements":["stale"],"appState":{"currentItemStrokeColor":"new"}}"#.utf8)
        let second = Task { try await coordinator.saveAppState(from: metadata, to: url, writer: ExternalFileWriter.write) }
        try await waitForPendingUpdate(at: url, coordinator: coordinator) { data in
            guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let appState = document["appState"] as? [String: String] else { return false }
            return appState["currentItemStrokeColor"] == "new"
        }
        await gate.release()
        try await first.value
        try await second.value
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(result["elements"] as? [String], ["latest"])
        XCTAssertEqual(result["appState"] as? [String: String], ["currentItemStrokeColor": "new"])
    }

    func testFailedAppStateRetryKeepsLatestQueuedElements() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        try Data(#"{"elements":["original"],"appState":{"currentItemStrokeColor":"old"}}"#.utf8).write(to: url)
        try await register(coordinator, at: url)
        do {
            try await coordinator.save(Data(#"{"elements":["latest"],"appState":{"currentItemStrokeColor":"old"}}"#.utf8), to: url) { _, _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch is ExternalFileSaveFailure { }
        do {
            try await coordinator.saveAppState(from: Data(#"{"elements":["stale"],"appState":{"currentItemStrokeColor":"new"}}"#.utf8), to: url) { _, _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
            XCTFail("App-state failure must reach the caller")
        } catch is ExternalFileSaveFailure { }
        try await coordinator.retry(at: url, writer: ExternalFileWriter.write)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(result["elements"] as? [String], ["latest"])
        XCTAssertEqual(result["appState"] as? [String: String], ["currentItemStrokeColor": "new"])
    }

    func testSupersededQueuedRevisionCannotOverwriteLatest() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        try await register(coordinator, at: url)
        let gate = SaveGate()
        let first = Task {
            try await coordinator.save(Data("first".utf8), to: url) { content, target, baseline in
                try await gate.pause()
                return try await ExternalFileWriter.write(content, to: target, replacing: baseline)
            }
        }
        await gate.waitUntilPaused()
        let second = Task { try await coordinator.save(Data("second".utf8), to: url, writer: ExternalFileWriter.write) }
        try await waitForPending(Data("second".utf8), at: url, coordinator: coordinator)
        let latest = Task { try await coordinator.save(Data("latest".utf8), to: url, writer: ExternalFileWriter.write) }
        try await waitForPending(Data("latest".utf8), at: url, coordinator: coordinator)
        await gate.release()
        try await first.value
        do { try await second.value; XCTFail("Superseded save must not acknowledge durability") } catch is CancellationError { }
        try await latest.value
        XCTAssertEqual(try Data(contentsOf: url), Data("latest".utf8))
    }

    func testCancelledQueuedSaveKeepsPendingForLaterRetry()
 async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        try await register(coordinator, at: url)
        let gate = SaveGate()
        let first = Task {
            try await coordinator.save(Data("first".utf8), to: url) { content, target, baseline in
                try await gate.pause()
                return try await ExternalFileWriter.write(content, to: target, replacing: baseline)
            }
        }
        await gate.waitUntilPaused()
        let second = Task { try await coordinator.save(Data("latest".utf8), to: url, writer: ExternalFileWriter.write) }
        try await waitForPending(Data("latest".utf8), at: url, coordinator: coordinator)
        second.cancel()
        await gate.release()
        try await first.value
        do { try await second.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        try await coordinator.retry(at: url, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), Data("latest".utf8))
    }

    private func waitForPending(_ content: Data, at url: URL, coordinator: ExternalFileSaveCoordinator) async throws {
        try await waitForPendingUpdate(at: url, coordinator: coordinator) { $0 == content }
    }

    private func waitForPendingUpdate(
        at url: URL,
        coordinator: ExternalFileSaveCoordinator,
        matching predicate: (Data) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let data = await coordinator.pendingContent(at: url), predicate(data) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Save did not enter the queue")
        throw SaveWaitError.timeout
    }
}

private enum SaveWaitError: Error { case timeout }

private actor SaveGate {
    private nonisolated let started = XCTestExpectation(description: "Writer entered")
    private var released = false

    func pause() async throws {
        started.fulfill()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !released {
            guard ContinuousClock.now < deadline else { throw SaveWaitError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    nonisolated func waitUntilPaused() async {
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(result, .completed)
    }

    func release() {
        released = true
    }
}
