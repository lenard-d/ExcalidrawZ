import Foundation
import XCTest
@testable import ExcalidrawZ

final class OwnedCanvasMutationCoordinatorTests: XCTestCase {
    private func session(generation: UInt64 = 1) -> CanvasMutationSession {
        CanvasMutationSession(fileID: "drawing", saveSession: UUID(), loadGeneration: generation)
    }

    @MainActor
    func testFlushWaitsForRegisteredOperationBeforeCapturingScene() async throws {
        let coordinator = OwnedCanvasMutationCoordinator()
        let owner = session()
        let gate = MutationGate()
        var scene = "before"
        let operation = Task { @MainActor in
            try await coordinator.perform(in: owner) {
                try await gate.pause()
                scene = "after"
            }
        }
        await gate.waitUntilPaused()
        XCTAssertTrue(coordinator.hasPendingSave)
        var capturedScene: String?
        let flushStarted = XCTestExpectation(description: "Flush started")
        let flush = Task { @MainActor in
            flushStarted.fulfill()
            if await coordinator.waitUntilIdle() { capturedScene = scene }
        }
        let started = await XCTWaiter.fulfillment(of: [flushStarted], timeout: 2)
        XCTAssertEqual(started, .completed)
        XCTAssertNil(capturedScene)
        await gate.release()
        try await operation.value
        await flush.value
        XCTAssertEqual(capturedScene, "after")
        XCTAssertTrue(coordinator.hasPendingSave)
        let revision = try XCTUnwrap(coordinator.pendingRevision(for: owner))
        coordinator.acknowledge(revision)
        XCTAssertFalse(coordinator.hasPendingSave)
    }

    @MainActor
    func testOperationFailureKeepsDirtyUntilSuccessfulSave() async throws {
        let coordinator = OwnedCanvasMutationCoordinator()
        let owner = session()
        do {
            try await coordinator.perform(in: owner) { throw CocoaError(.coderInvalidValue) }
            XCTFail("The bridge failure must reach its caller")
        } catch is CocoaError { }
        XCTAssertTrue(coordinator.hasPendingSave)
        let idle = await coordinator.waitUntilIdle()
        XCTAssertTrue(idle)
        let revision = try XCTUnwrap(coordinator.pendingRevision(for: owner))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("drawing.excalidraw")
        try Data("old".utf8).write(to: url)
        let saves = ExternalFileSaveCoordinator()
        _ = await saves.recordRead(try ExternalFileVersion(content: Data(contentsOf: url), at: url), at: url)
        do {
            try await saves.save(Data("partial live scene".utf8), to: url) { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        } catch is ExternalFileSaveFailure { }
        XCTAssertTrue(coordinator.hasPendingSave)
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
        try await saves.retry(at: url, writer: ExternalFileWriter.write)
        coordinator.acknowledge(revision)
        XCTAssertEqual(try Data(contentsOf: url), Data("partial live scene".utf8))
        XCTAssertFalse(coordinator.hasPendingSave)
    }

    @MainActor
    func testCancelledFlushDoesNotCancelOrAcknowledgeOperation() async throws {
        let coordinator = OwnedCanvasMutationCoordinator()
        let owner = session()
        let gate = MutationGate()
        var completed = false
        let operation = Task { @MainActor in
            try await coordinator.perform(in: owner) { try await gate.pause(); completed = true }
        }
        await gate.waitUntilPaused()
        let flush = Task { await coordinator.waitUntilIdle() }
        flush.cancel()
        let canLeave = await flush.value
        XCTAssertFalse(canLeave)
        XCTAssertFalse(completed)
        XCTAssertTrue(coordinator.hasPendingSave)
        await gate.release()
        try await operation.value
        XCTAssertTrue(completed)
        XCTAssertTrue(coordinator.hasPendingSave)
    }

    @MainActor
    func testOldSnapshotCannotAcknowledgeNewerMutation() async throws {
        let coordinator = OwnedCanvasMutationCoordinator()
        let owner = session()
        try await coordinator.perform(in: owner) {}
        let first = try XCTUnwrap(coordinator.pendingRevision(for: owner))
        try await coordinator.perform(in: owner) {}
        coordinator.acknowledge(first)
        XCTAssertTrue(coordinator.hasPendingSave)
        let latest = try XCTUnwrap(coordinator.pendingRevision(for: owner))
        coordinator.acknowledge(latest)
        XCTAssertFalse(coordinator.hasPendingSave)
    }

    @MainActor
    func testSameFileReloadHasDifferentOwnedSession() async throws {
        var loads = DocumentLoadStateMachine()
        let firstLoad = try XCTUnwrap(loads.begin(fileID: "drawing", force: false))
        XCTAssertTrue(loads.confirm(firstLoad))
        let saveSession = UUID()
        let first = CanvasMutationSession(fileID: "drawing", saveSession: saveSession, loadGeneration: loads.generation)
        let secondLoad = try XCTUnwrap(loads.begin(fileID: "drawing", force: true))
        XCTAssertTrue(loads.confirm(secondLoad))
        let second = CanvasMutationSession(fileID: "drawing", saveSession: saveSession, loadGeneration: loads.generation)
        XCTAssertNotEqual(first, second)
        let coordinator = OwnedCanvasMutationCoordinator()
        try await coordinator.perform(in: first) {}
        XCTAssertNil(coordinator.pendingRevision(for: second))
        XCTAssertTrue(coordinator.hasPendingSave)
    }
}

private actor MutationGate {
    private nonisolated let started = XCTestExpectation(description: "Mutation entered")
    private var released = false

    func pause() async throws {
        started.fulfill()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !released {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    nonisolated func waitUntilPaused() async {
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(result, .completed)
    }

    func release() { released = true }
}
