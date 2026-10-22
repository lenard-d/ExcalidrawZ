//
//  ExcalidrawDocumentProgrammaticSnapshotCommitter.swift
//  ExcalidrawZ
//
//  Captures snapshots after Swift-driven canvas mutations.
//

import Foundation

final class ExcalidrawDocumentProgrammaticSnapshotCommitter: @unchecked Sendable {
    private let lock = NSLock()
    private weak var delegate: ExcalidrawDocumentSnapshotCoordinatorDelegate?
    private var commitTask: Task<Void, Never>?
    private let mutations = OwnedCanvasMutationCoordinator()

    var hasPendingSave: Bool { mutations.hasPendingSave }

    func waitUntilIdle() async -> Bool { await mutations.waitUntilIdle() }

    @MainActor
    func performOwnedMutation(
        in session: CanvasMutationSession,
        reason: String,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        delegate?.snapshotCoordinatorCore?.parent?.fileState.noteProgrammaticCanvasMutation(fileID: session.fileID)
        defer {
            if delegate?.snapshotCoordinatorCore?.documentSyncController.isCurrentCanvasMutationSession(session) == true {
                schedule(reason: reason)
            }
        }
        try await mutations.perform(in: session, operation: operation)
    }

    @MainActor
    func pendingRevision(fileID: String) -> OwnedCanvasMutationCoordinator.Revision? {
        guard let session = delegate?.snapshotCoordinatorCore?.documentSyncController.captureCanvasMutationSession(),
              session.fileID == fileID else { return nil }
        return mutations.pendingRevision(for: session)
    }

    func acknowledge(_ revision: OwnedCanvasMutationCoordinator.Revision?) {
        if let revision { mutations.acknowledge(revision) }
    }

    func attach(delegate: ExcalidrawDocumentSnapshotCoordinatorDelegate) {
        self.delegate = delegate
    }

    func reset() {
        lock.lock()
        commitTask?.cancel()
        commitTask = nil
        lock.unlock()
    }

    /// Marks a native Swift mutation as locally dirty and schedules a live
    /// canvas snapshot save. This is intentionally separate from normal
    /// `stateChanged` because these mutations may not produce a reliable
    /// autosave event while the editor is outside explicit edit mode on iOS.
    @MainActor
    func schedule(reason: String) {
        guard let core = delegate?.snapshotCoordinatorCore,
              let fileID = core.parent?.file?.id else {
            return
        }

        core.parent?.fileState.noteProgrammaticCanvasMutation(fileID: fileID)
        _ = core.parent?.fileState.captureCanvasSave(expectedFileID: fileID)
        if let session = core.documentSyncController.captureCanvasMutationSession() {
            mutations.recordMutation(in: session)
        }
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                try Task.checkCancellation()
                await self?.commit(
                    reason: reason,
                    expectedFileID: fileID
                )
            } catch {
                return
            }
        }

        lock.lock()
        commitTask?.cancel()
        commitTask = task
        lock.unlock()
    }

    /// Captures the current WebView scene after a Swift-driven mutation and
    /// persists it if the canvas is still showing the same file.
    private func commit(
        reason: String,
        expectedFileID: String
    ) async {
        guard let delegate,
              let core = delegate.snapshotCoordinatorCore else { return }

        guard await mutations.waitUntilIdle() else { return }
        let pendingRevision = await pendingRevision(fileID: expectedFileID)
        let onError = core.publishError
        let currentFileID = await MainActor.run { core.parent?.file?.id }
        guard currentFileID == expectedFileID else { return }

        let type = await MainActor.run { core.parent?.type }
        let savingType = await MainActor.run { core.parent?.savingType }

        do {
            let loadedID = core.documentSyncController.currentLoadedFileID
            guard delegate.snapshotCoordinatorCanApplyStateChanged(
                currentFileID: currentFileID,
                webLoadedFileID: loadedID,
                isCollaboration: type == .collaboration
            ) else {
                return
            }

            let capture = await MainActor.run { core.parent?.fileState.captureCanvasSave(expectedFileID: expectedFileID) }
            guard let capture else { throw CancellationError() }
            let snapshot = try await core.getCurrentFileSnapshot()
            let fileData = try delegate.snapshotCoordinatorMakeFileData(from: snapshot)
            try await delegate.snapshotCoordinatorApplyCanvasFileData(
                fileData,
                currentFileID: currentFileID,
                type: type,
                savingType: savingType,
                markProgrammaticCommit: true,
                capture: capture
            )
            capture.acknowledgeDurable { acknowledge(pendingRevision) }
            core.logger.debug("Committed programmatic canvas mutation: \(reason)")
        } catch is CancellationError {
            return
        } catch {
            core.logger.error("Failed to commit programmatic canvas mutation \(reason): \(error)")
            onError(error)
        }
    }
}
