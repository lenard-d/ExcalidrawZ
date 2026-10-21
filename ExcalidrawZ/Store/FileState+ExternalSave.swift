import Foundation

extension FileState {
    @MainActor
    func captureCanvasSave(expectedFileID: String? = nil, intent: CanvasSaveCoverage = .fullScene) -> CanvasSaveCapture? {
        guard let activeFile = currentActiveFile,
              let session = canvasCoordinator(for: activeFile)?.documentSyncController.captureCanvasMutationSession(),
              expectedFileID == nil || session.fileID == expectedFileID else { return nil }
        return canvasSaveCoordinator.capture(owner: session, intent: intent)
    }

    @MainActor
    func applyExternalCanvasSnapshot(_ apply: () -> Void) {
        isApplyingExternalCanvasSnapshot = true
        defer { isApplyingExternalCanvasSnapshot = false }
        apply()
    }

    func recordExternalFileRead(_ content: Data, at url: URL) async throws -> UUID {
        try await Self.registerExternalFileRead(content, at: url)
    }

    static func registerExternalFileRead(_ content: Data, at url: URL) async throws -> UUID {
        let session = UUID()
        let version = try await Task.detached(priority: .utility) {
            try await LocalFolder.withSecurityScopedAccessToContainingFolder(for: url) {
                try ExternalFileVersion(content: content, at: url)
            }
        }.value
        guard await ExternalFileSaveCoordinator.shared.recordRead(version, at: url, session: session) else {
            throw ExternalFileSaveFailure(url: url, cause: ExternalFileConflict())
        }
        return session
    }

    @MainActor
    func prepareExternalFileReload(at url: URL) async throws -> (content: Data, session: UUID)? {
        try await prepareExternalFileReload { owner, hasPendingCanvasEdits in
            try await LocalFolder.withSecurityScopedAccessToContainingFolder(for: url) {
                try await ExternalFileSaveCoordinator.shared.prepareReload(
                    at: url, session: owner.session, hasPendingCanvasEdits: hasPendingCanvasEdits
                )
            }
        }
    }

    @MainActor
    func prepareExternalFileReload(
        preparation: (ExternalSaveTerminationToken, Bool) async throws -> (content: Data, session: UUID)?
    ) async throws -> (content: Data, session: UUID)? {
        let owner = terminationSaveToken
        let hasPendingCanvasEdits = hasPendingExternalSnapshot
        let replacement: (content: Data, session: UUID)?
        do {
            replacement = try await preparation(owner, hasPendingCanvasEdits)
        } catch {
            guard terminationSaveToken == owner else { throw CancellationError() }
            throw error
        }
        guard terminationSaveToken == owner else {
            if let replacement { await releaseUnusedExternalSaveSession(replacement.session) }
            throw CancellationError()
        }
        return replacement
    }

    @MainActor
    func saveRestoredExternalCanvas(_ file: ExcalidrawFile, at url: URL) async throws {
        guard let activeFile = currentActiveFile,
              let target = capturedCanvasSaveTarget(for: activeFile),
              case .localFile(let capturedURL, _, _) = target.kind,
              capturedURL.standardizedFileURL == url.standardizedFileURL,
              let content = file.content else { throw CancellationError() }
        try await flushPendingCanvasSnapshotBeforeExternalMutation(fileID: activeFile.id)
        let token = terminationSaveToken
        let mutationSession = UUID()
        try await ExternalFileSaveCoordinator.shared.forkSession(at: capturedURL, from: target.saveSessionID, to: mutationSession)
        defer { Task { await releaseUnusedExternalSaveSession(mutationSession) } }
        try await ExternalFileSaveCoordinator.shared.save(
            content, to: capturedURL, session: mutationSession, writer: Self.externalFileWriter(for: target)
        )
        await acceptExternalMutation(file, session: mutationSession, expectedToken: token)
    }

    @MainActor
    func acceptExternalMutation(
        _ file: ExcalidrawFile,
        session: UUID,
        expectedToken: ExternalSaveTerminationToken
    ) async {
        guard let controller = excalidrawWebCoordinator?.documentSyncController,
              let revision = expectedToken.editRevision else { return }
        let request = ExternalCanvasReloadRequest(
            fileID: file.id,
            editRevision: revision,
            loadGeneration: expectedToken.loadGeneration,
            isCurrent: {
                self.terminationSaveToken.hasSameOwnerAndEdits(as: expectedToken)
                    && !self.hasPendingExternalSnapshot
                    && self.excalidrawWebCoordinator?.documentSyncController === controller
            },
            onAccept: {
                self.installExternalSaveSession(session)
                NotificationCenter.default.post(
                    name: .activeCanvasFileDidRestore, object: file,
                    userInfo: ["saveOwner": ObjectIdentifier(self)]
                )
            },
            onReject: {
                if let activeFile = self.currentActiveFile {
                    switch activeFile {
                        case .localFile(let url), .temporaryFile(let url):
                            self.reportExternalSaveFailure(ExternalFileConflict(), at: url)
                        default:
                            break
                    }
                }
            }
        )
        await controller.load(file, force: true, externalReload: request)
    }

    @MainActor
    func installExternalSaveSession(_ session: UUID) {
        let previousSession = externalSaveSessionID
        canvasSaveCoordinator.invalidate()
        externalSaveSessionID = session
        if previousSession != session {
            excalidrawWebCoordinator?.documentSyncController.externalSaveSessionDidChange()
        }
        Task { await ExternalFileSaveCoordinator.shared.releaseSession(previousSession) }
    }

    @MainActor
    func releaseUnusedExternalSaveSession(_ session: UUID) async {
        guard session != externalSaveSessionID else { return }
        await ExternalFileSaveCoordinator.shared.releaseSession(session)
    }

    static func externalFileWriter(for target: CapturedCanvasSaveTarget) -> ExternalFileSaveCoordinator.Writer {
        target.externalWriter ?? externalFileWriter(isOpenInPlace: target.isOpenInPlace)
    }

    static func externalFileWriter(isOpenInPlace: Bool) -> ExternalFileSaveCoordinator.Writer {
        { content, url, baseline in
            if isOpenInPlace {
#if os(iOS)
                throw CocoaError(.fileWriteNoPermission)
#else
                return try await ExternalFileWriter.write(content, to: url, replacing: baseline)
#endif
            }
            return try await LocalFolder.withSecurityScopedAccessToContainingFolder(for: url) {
                try await ExternalFileWriter.write(content, to: url, replacing: baseline)
            }
        }
    }

    @MainActor
    func reportExternalSaveFailure(_ error: Error, at url: URL, force: Bool = false) {
        if force || reportedExternalSaveFailures.insert(url.standardizedFileURL).inserted {
            externalSaveErrorMessage = error is ExternalFileSaveFailure
                ? error.localizedDescription
                : ExternalFileSaveFailure(url: url, cause: error).localizedDescription
        }
    }

    @MainActor
    func retryCurrentExternalSave() async {
        guard let activeFile = currentActiveFile,
              let target = capturedCanvasSaveTarget(for: activeFile),
              case .localFile(let url, _, _) = target.kind else { return }
        await excalidrawWebCoordinator?.documentSyncController.flushPendingDirtySnapshot(
            reason: "retryExternalSave", force: true, expectedFileID: activeFile.id
        )
        guard !Task.isCancelled else { return }
        do {
            try await ExternalFileSaveCoordinator.shared.retry(
                at: url, session: target.saveSessionID, writer: Self.externalFileWriter(for: target)
            )
            guard excalidrawWebCoordinator?.documentSyncController.hasPendingDirtySnapshot != true else {
                throw CocoaError(.fileWriteUnknown)
            }
            reportedExternalSaveFailures.remove(url.standardizedFileURL)
            externalSaveErrorMessage = nil
        } catch {
            reportExternalSaveFailure(error, at: url, force: true)
        }
    }

    @MainActor
    func persistExternalCanvasUpdate(_ file: ExcalidrawFile, to url: URL, capture: CanvasSaveCapture? = nil) async throws {
        guard shouldAcceptCanvasUpdate(fileID: url.absoluteString, label: url.lastPathComponent),
              let activeFile = currentActiveFile,
              let target = capturedCanvasSaveTarget(for: activeFile),
              case .localFile(let capturedURL, let newCheckpoint, let suppressCheckpoint) = target.kind,
              capturedURL.standardizedFileURL == url.standardizedFileURL else {
            throw CancellationError()
        }
        guard let capture = capture ?? captureCanvasSave(expectedFileID: file.id) else { throw CancellationError() }
        do {
            try await Self.saveCapturedLocalCanvasUpdate(
                to: url, with: file, writer: Self.externalFileWriter(for: target), session: target.saveSessionID, capture: capture,
                newCheckpoint: newCheckpoint, suppressCheckpoint: suppressCheckpoint, logger: logger
            )
            reportedExternalSaveFailures.remove(url.standardizedFileURL)
            externalSaveErrorMessage = nil
            didUpdateFile = true
            objectWillChange.send()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            reportExternalSaveFailure(error, at: url)
            throw error
        }
    }
}

extension FileState: ExternalSaveTerminationParticipant {
    @MainActor
    var terminationSaveToken: ExternalSaveTerminationToken {
        ExternalSaveTerminationToken(
            fileID: currentActiveFile?.id,
            session: externalSaveSessionID,
            editRevision: excalidrawWebCoordinator?.documentSyncController.externalReloadRevision,
            loadGeneration: excalidrawWebCoordinator?.documentSyncController.currentLoadGeneration
        )
    }

    @MainActor
    var hasPendingExternalSnapshot: Bool {
        switch currentActiveFile {
            case .localFile, .temporaryFile:
                excalidrawWebCoordinator?.documentSyncController.hasPendingDirtySnapshot == true
            default:
                false
        }
    }
}
