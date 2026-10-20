//
//  ExcalidrawDocumentSyncController.swift
//  ExcalidrawZ
//
//  Coordinates host-driven file loads with WebView stateChanged events.
//

import Foundation
import Combine
import UniformTypeIdentifiers

/// Owns the synchronization boundary between the native `ExcalidrawCanvasView`
/// binding and the embedded Excalidraw WebView.
///
/// Excalidraw can emit `stateChanged` events while the host is loading or
/// force-reloading a file. Applying those events blindly can persist an empty
/// or stale scene over the real file. This controller tracks which file is
/// expected in the WebView, suppresses load-induced events, and only applies
/// saves when the native file id still matches the WebView's loaded file id.
///
/// Swift-driven canvas mutations and metadata-only dirty events are delegated
/// to `ExcalidrawDocumentSnapshotCoordinator`, then routed back through this
/// controller's persistence bridge when a full snapshot must be applied.
final class ExcalidrawDocumentSyncController: @unchecked Sendable {
    struct LoadFailure: LocalizedError, Sendable {
        let message: String

        init(_ error: Error?) {
            self.message = error?.localizedDescription ?? "The file could not be loaded."
        }

        var errorDescription: String? { message }
    }

    enum LoadCompletion: Sendable {
        case succeeded
        case failed(LoadFailure)
        case superseded
    }

    enum LoadEvent: Sendable {
        case started(fileID: String)
        case finished(fileID: String, completion: LoadCompletion)
        case reset
    }

    enum LoadOutcome {
        case skipped
        case loaded(LoadFileResult)
        case superseded
        case failed

        var didLoad: Bool {
            if case .loaded = self {
                return true
            }
            return false
        }

    }

    private enum StateChangeSuppressionReason {
        case preparingFileLoad
        case canvasFileLoad
        case coreFileLoad
    }

    private struct StateChangeSuppression {
        let fileID: String
        let reason: StateChangeSuppressionReason
        let startedAt: Date
    }

    private let lock = NSLock()
    private var externalEditState = ExternalCanvasEditState()
    var externalReloadRevision: UInt64 { lock.withLock { externalEditState.revision } }
    var currentLoadGeneration: UInt64 { lock.withLock { loadState.generation } }
    private weak var core: ExcalidrawCore?
    private let snapshotCoordinator = ExcalidrawDocumentSnapshotCoordinator()
    private let canvasMutationSessionChangeSubject = PassthroughSubject<Void, Never>()
    /// Broadcasts admission changes. Observers must recheck their captured session.
    var canvasMutationSessionChanges: AnyPublisher<Void, Never> {
        canvasMutationSessionChangeSubject.eraseToAnyPublisher()
    }

    let loadEvents: AsyncStream<LoadEvent>
    private let loadEventContinuation: AsyncStream<LoadEvent>.Continuation
    private var loadState = DocumentLoadStateMachine()
    /// Temporary guards used to ignore `stateChanged` events produced by file
    /// loading itself rather than by user or tool edits.
    private var stateChangeSuppressions: [UUID: StateChangeSuppression] = [:]
    init() {
        var continuation: AsyncStream<LoadEvent>.Continuation?
        self.loadEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.loadEventContinuation = continuation!
        snapshotCoordinator.attach(delegate: self)
    }

    var currentLoadedFileID: String? {
        lock.lock()
        let fileID = loadState.confirmedFileID
        lock.unlock()
        return fileID
    }

    var hasPendingFileLoad: Bool {
        lock.lock()
        let hasPendingLoad = loadState.currentRequest != nil
        lock.unlock()
        return hasPendingLoad
    }

    @MainActor
    func externalSaveSessionDidChange() {
        canvasMutationSessionChangeSubject.send()
    }

    @MainActor
    func captureCanvasMutationSession() -> CanvasMutationSession? {
        guard let fileState = core?.parent?.fileState,
              let fileID = core?.parent?.file?.id,
              fileState.currentActiveFile?.id == fileID else { return nil }
        return lock.withLock {
            guard loadState.currentRequest == nil, loadState.confirmedFileID == fileID else { return nil }
            return CanvasMutationSession(
                fileID: fileID, saveSession: fileState.externalSaveSessionID,
                loadGeneration: loadState.generation
            )
        }
    }

    @MainActor
    func isCurrentCanvasMutationSession(_ session: CanvasMutationSession) -> Bool {
        captureCanvasMutationSession() == session
    }

    @MainActor
    func performOwnedCanvasMutation(
        reason: String,
        operation: @escaping @MainActor (CanvasMutationSession) async throws -> Void
    ) async throws {
        guard let session = captureCanvasMutationSession(),
              beginReceivedStateChanged(isCoreLoading: core?.isLoading == true, hasDirtyChanges: true) == nil else {
            throw CancellationError()
        }
        defer { lock.withLock { externalEditState.endEvent() } }
        guard core?.parent?.fileState.captureCanvasSave(expectedFileID: session.fileID) != nil else {
            throw CancellationError()
        }
        try await snapshotCoordinator.performOwnedCanvasMutation(in: session, reason: reason) {
            guard self.isCurrentCanvasMutationSession(session) else { throw CancellationError() }
            try await operation(session)
            guard self.isCurrentCanvasMutationSession(session) else { throw CancellationError() }
        }
    }

    @MainActor
    func currentCanvasFileForRecoveryExport() async throws -> ExcalidrawFile {
        guard let core,
              let session = captureCanvasMutationSession(),
              let fileState = core.parent?.fileState,
              var file = core.parent?.file else { throw CancellationError() }
        let token = fileState.terminationSaveToken
        let snapshot = try await CanvasRecoverySnapshot.capture(
            owner: token,
            currentOwner: { self.isCurrentCanvasMutationSession(session) ? fileState.terminationSaveToken : nil },
            waitUntilIdle: { await self.snapshotCoordinator.waitForOwnedCanvasOperations() },
            read: { try await core.getCurrentFileSnapshot() }
        )
        try file.update(data: Self.makeFileData(from: snapshot))
        return file
    }

    func waitUntilFileIsLoaded(
        _ fileID: String,
        timeout: TimeInterval
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while currentLoadedFileID != fileID {
            try Task.checkCancellation()
            guard Date() < deadline else { return false }
            try await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    func attach(core: ExcalidrawCore) {
        self.core = core
    }

    /// Called before the SwiftUI binding points the WebView at a different
    /// file. This arms a short suppression window so pre-load WebView events do
    /// not write into the previous or next file.
    func setTargetFileID(_ fileID: String?) {
        lock.lock()
        pruneExpiredStateChangeSuppressions()
        stateChangeSuppressions = stateChangeSuppressions.filter { _, suppression in
            suppression.reason != .preparingFileLoad
        }

        if let fileID, loadState.confirmedFileID != fileID {
            stateChangeSuppressions[UUID()] = .init(
                fileID: fileID,
                reason: .preparingFileLoad,
                startedAt: Date()
            )
        }
        lock.unlock()
    }

    /// Loads a complete file into the WebView and records the file id only
    /// after the JS side confirms it has applied the scene.
    @discardableResult
    func load(
        _ file: ExcalidrawFile?,
        force: Bool = false,
        externalReload: ExternalCanvasReloadRequest? = nil
    ) async -> LoadOutcome {
        guard let file, let data = file.content else {
            core.map {
                logFileLoad($0.logger, "Document load skipped: missing file or content", level: .warning)
            }
            return .failed
        }

        return await load(
            fileID: file.id,
            data: data,
            force: force,
            validateCurrentParentFile: true,
            externalReload: externalReload
        )
    }

    @discardableResult
    func load(
        fileID: String,
        data: Data,
        force: Bool = false,
        validateCurrentParentFile: Bool = false,
        externalReload: ExternalCanvasReloadRequest? = nil
    ) async -> LoadOutcome {
        let shouldPreserveLiveViewport = force && currentLoadedFileID == fileID

        let startedLoad = await MainActor.run { () -> (DocumentLoadStateMachine.Request, UUID)? in
            var started: (DocumentLoadStateMachine.Request, UUID)?
            if let externalReload {
                guard externalReload.start(fileID: fileID, armLoad: {
                    started = self.beginCanvasFileLoad(
                        fileID: fileID, force: force,
                        expectedEditRevision: externalReload.editRevision,
                        expectedLoadGeneration: externalReload.loadGeneration
                    )
                    if started != nil {
                        self.core?.parent?.fileState.canvasSaveCoordinator.invalidate()
                        self.snapshotCoordinator.cancelPendingSnapshotCommits()
                    }
                    return started != nil
                }) else { return nil }
            } else {
                started = self.beginCanvasFileLoad(fileID: fileID, force: force)
                if started != nil {
                    self.core?.parent?.fileState.canvasSaveCoordinator.invalidate()
                    self.snapshotCoordinator.cancelPendingSnapshotCommits()
                }
            }
            return started
        }
        guard let (request, canvasToken) = startedLoad else { return .skipped }

        defer {
            endStateChangeSuppression(canvasToken)
        }

        let outcome = await loadStartedFile(
            request: request, fileID: fileID, data: data,
            preservingLiveViewport: shouldPreserveLiveViewport,
            validateCurrentParentFile: validateCurrentParentFile
        )
        await MainActor.run {
            // Load admission and this installation run on MainActor without an intervening await.
            let isCurrentLoad = self.lock.withLock { self.loadState.isConfirmed(request) }
            externalReload?.finish(didLoad: outcome.didLoad, isCurrentLoad: isCurrentLoad)
        }
        return outcome
    }

    private func loadStartedFile(
        request: DocumentLoadStateMachine.Request,
        fileID: String,
        data: Data,
        preservingLiveViewport: Bool,
        validateCurrentParentFile: Bool
    ) async -> LoadOutcome {
        let dataForLoad = await dataByPreparingViewportForLoad(
            data,
            fileID: fileID,
            preservingLiveViewport: preservingLiveViewport
        )

        let maxAttempts = 2
        var lastError: Error?
        for attempt in 1...maxAttempts {
            let transportRequestID = "\(request.id)-attempt-\(attempt)"
            guard !Task.isCancelled else {
                return finishCanvasFileLoad(
                    request,
                    outcome: .failed,
                    failure: LoadFailure(CancellationError())
                )
            }

            guard isCurrentLoadRequest(request) else {
                return .superseded
            }

            if validateCurrentParentFile {
                let isStillCurrent = await MainActor.run {
                    core?.parent?.file?.id == fileID
                }
                guard isStillCurrent else {
                    return finishCanvasFileLoad(request, outcome: .superseded)
                }
            }

            let result: LoadFileResult?
            do {
                result = try await loadPreparedFile(
                    request: request,
                    transportRequestID: transportRequestID,
                    data: dataForLoad
                )
            } catch {
                lastError = error
                result = nil
            }

            guard isCurrentLoadRequest(request) else {
                return .superseded
            }

            if validateCurrentParentFile {
                let isStillCurrent = await MainActor.run {
                    core?.parent?.file?.id == fileID
                }
                guard isStillCurrent else {
                    return finishCanvasFileLoad(request, outcome: .superseded)
                }
            }

            if let result,
               result.fileId == request.fileID,
               result.requestId == transportRequestID,
               commitLoadedFile(request) {
                return .loaded(result)
            }

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        core?.logger.warning(
            "Failed to load file \(fileID) into Excalidraw after retries requestID=\(request.id)"
        )
        if let lastError, isCurrentLoadRequest(request) {
            core?.publishError(lastError)
        }
        return finishCanvasFileLoad(
            request,
            outcome: .failed,
            failure: LoadFailure(lastError)
        )
    }

    struct StateChangedAdmission {
        let capture: CanvasSaveCapture?
    }

    /// WebKit calls this before creating the asynchronous save task.
    @MainActor
    func admitStateChanged(_ data: ExcalidrawCore.StateChangedMessageData) -> StateChangedAdmission? {
        guard let core else { return nil }
        let isDirty = data.fileData != nil || data.metadata?.hasAnyDirtyChanges == true
        guard beginReceivedStateChanged(isCoreLoading: core.isLoading, hasDirtyChanges: isDirty) == nil else {
            return nil
        }
        let intent: CanvasSaveCoverage = data.fileData != nil || data.metadata?.shouldPullContentSnapshot == true
            ? .fullScene : .appState
        return StateChangedAdmission(capture: isDirty ? core.parent?.fileState.captureCanvasSave(intent: intent) : nil)
    }

    @MainActor
    func save(_ data: ExcalidrawCore.StateChangedMessageData, admission: StateChangedAdmission) async {
        defer { lock.withLock { externalEditState.endEvent() } }
        guard let core else { return }
        let capture = admission.capture
        let isDirty = data.fileData != nil || data.metadata?.hasAnyDirtyChanges == true
        guard !isDirty || capture?.isCurrent == true || core.parent?.type == .collaboration else { return }
        let type = core.parent?.type
        let currentFileID = core.parent?.file?.id
        let onError = core.publishError

        if let metadata = data.metadata, data.fileData == nil {
            if metadata.shouldPullContentSnapshot {
                await core.noteAcceptedContentChange()
            }
            snapshotCoordinator.handleStateChangedMetadata(
                metadata,
                currentFileID: currentFileID,
                type: type,
                savingType: core.parent?.savingType,
                capture: capture
            )
            return
        }

        guard let fileData = data.fileData else { return }

        do {
            let loadedID = currentLoadedFileID
            guard self.canApplyStateChanged(
                currentFileID: currentFileID,
                webLoadedFileID: loadedID,
                isCollaboration: type == .collaboration
            ) else {
                return
            }

            await core.noteAcceptedContentChange()
            try await applyCanvasFileData(
                fileData,
                currentFileID: currentFileID,
                type: type,
                savingType: core.parent?.savingType,
                markProgrammaticCommit: false,
                capture: capture
            )
        } catch is CancellationError where capture?.isCurrent == false || Task.isCancelled {
            return
        } catch {
            onError(error)
        }
    }

    var hasPendingDirtySnapshot: Bool { snapshotCoordinator.hasPendingDirtySnapshot }

    func flushPendingDirtySnapshot(
        reason: String,
        force: Bool = false,
        expectedFileID: String? = nil,
        validateParentFileID: Bool = true
    ) async {
        await snapshotCoordinator.flushPendingDirtySnapshot(
            reason: reason,
            force: force,
            expectedFileID: expectedFileID,
            validateParentFileID: validateParentFileID
        )
        let state = await MainActor.run { () -> (FileState, FileState.CapturedCanvasSaveTarget)? in
            guard let fileState = core?.parent?.fileState,
                  let activeFile = fileState.currentActiveFile,
                  expectedFileID == nil || activeFile.id == expectedFileID,
                  let target = fileState.capturedCanvasSaveTarget(for: activeFile) else { return nil }
            return (fileState, target)
        }
        if let (fileState, target) = state,
           case .localFile(let url, _, _) = target.kind {
            do {
                try await ExternalFileSaveCoordinator.shared.retry(
                    at: url, session: target.saveSessionID, writer: FileState.externalFileWriter(for: target)
                )
            } catch {
                await fileState.reportExternalSaveFailure(error, at: url)
            }
        }
    }

    func flushPendingDirtySnapshotToCapturedTarget(
        reason: String,
        expectedFileID: String,
        target: FileState.CapturedCanvasSaveTarget,
        forceCurrentAppState: Bool = false
    ) async {
        await snapshotCoordinator.flushPendingDirtySnapshotToCapturedTarget(
            reason: reason,
            expectedFileID: expectedFileID,
            target: target,
            forceCurrentAppState: forceCurrentAppState
        )
    }

    @MainActor
    func scheduleProgrammaticMutationCommit(reason: String) {
        snapshotCoordinator.scheduleProgrammaticMutationCommit(reason: reason)
    }

    /// Shared persistence bridge for both WebView autosave events and explicit
    /// snapshot commits. This keeps PNG/SVG export-backed documents and normal
    /// `.excalidraw` documents on the same validation path.
    private func applyCanvasFileData(

        _ fileData: ExcalidrawCore.ExcalidrawFileData,
        currentFileID: String?,
        type: ExcalidrawCanvasView.ExcalidrawType?,
        savingType: UTType?,
        markProgrammaticCommit: Bool,
        capture: CanvasSaveCapture?
    ) async throws {
        if let capture {
            try await capture.performSave {
                try await applyAdmittedCanvasFileData(
                    fileData, currentFileID: currentFileID, type: type, savingType: savingType,
                    markProgrammaticCommit: markProgrammaticCommit, capture: capture
                )
            }
        } else {
            try await applyAdmittedCanvasFileData(
                fileData, currentFileID: currentFileID, type: type, savingType: savingType,
                markProgrammaticCommit: markProgrammaticCommit, capture: nil
            )
        }
    }

    private enum CanvasPersistenceTarget {
        case external(FileState, URL)
        case library(FileState.CapturedCanvasSaveTarget)
    }

    private func applyAdmittedCanvasFileData(
        _ fileData: ExcalidrawCore.ExcalidrawFileData,
        currentFileID: String?,
        type: ExcalidrawCanvasView.ExcalidrawType?,
        savingType: UTType?,
        markProgrammaticCommit: Bool,
        capture: CanvasSaveCapture?
    ) async throws {
        guard let core else { throw CancellationError() }

        guard beginReceivedStateChanged(isCoreLoading: core.isLoading, hasDirtyChanges: false) == nil else {
            throw CancellationError()
        }
        defer { lock.withLock { externalEditState.endEvent() } }
        guard var updatedFile = await MainActor.run(body: { core.parent?.file }) else {
            throw CancellationError()
        }
        var preparedUpdate: ExcalidrawFile.PreparedCanvasDataUpdate?
        switch savingType {
            case .some(.excalidrawPNG), .some(.png):
                let elements = try await Self.elements(from: fileData)
                updatedFile.content = try await core.exportElementsToPNGData(
                    elements: elements, embedScene: true, colorScheme: .light
                )
            case .some(.excalidrawSVG), .some(.svg):
                let elements = try await Self.elements(from: fileData)
                updatedFile.content = try await core.exportElementsToSVGData(
                    elements: elements, embedScene: true, colorScheme: .light
                )
            default:
                guard let existingContent = updatedFile.content else { throw CocoaError(.fileWriteUnknown) }
                let fileDataForPersistence = try await canvasFileDataForPersistence(fileData, currentFileID: currentFileID)
                let update = try await Task.detached(priority: .utility) {
                    try ExcalidrawFile.prepareCanvasDataUpdate(existingContent: existingContent, data: fileDataForPersistence)
                }.value
                preparedUpdate = update
                updatedFile.apply(update)
        }

        let fileToApply = updatedFile
        let updateToApply = preparedUpdate
        let persistenceTarget = try await MainActor.run { () throws -> CanvasPersistenceTarget? in
            guard capture?.isCurrent != false else { throw CancellationError() }
            guard type == .collaboration || core.parent?.file?.id == currentFileID else {
                throw CancellationError()
            }
            if markProgrammaticCommit, let currentFileID {
                core.parent?.fileState.noteProgrammaticCanvasMutation(fileID: currentFileID)
            }
            if type == .normal, let fileState = core.parent?.fileState,
               let activeFile = fileState.currentActiveFile {
                switch activeFile {
                    case .localFile(let url), .temporaryFile(let url):
                        // Mirror the live scene for export, but do not start a second save task.
                        fileState.applyExternalCanvasSnapshot { core.parent?.file = fileToApply }
                        return .external(fileState, url)
                    default:
                        break
                }
            }
            if updateToApply != nil, type == .normal,
               let fileState = core.parent?.fileState,
               case .file(let activeFile) = fileState.currentActiveFile {
                guard activeFile.id?.uuidString == currentFileID,
                      let target = fileState.prepareLibraryCanvasSaveTarget(activeFile) else {
                    throw CancellationError()
                }
                // Keep the live mirror even if the awaited persistence fails.
                core.parent?.file = fileToApply
                return .library(target)
            }
            core.parent?.file = fileToApply
            return nil
        }
        switch persistenceTarget {
            case .external(let fileState, let url):
                try await fileState.persistExternalCanvasUpdate(fileToApply, to: url, capture: capture)
            case .library(let target):
                // applyCanvasFileData already owns capture.performSave. Do not nest it.
                try await FileState.persistCapturedCanvasUpdate(target, with: fileToApply, capture: capture)
            case nil:
                break
        }
    }

    /// Converts a live JS snapshot into the same payload shape used by the
    /// `stateChanged` message.
    private static func makeFileData(
        from snapshot: ExcalidrawCore.CurrentFileSnapshot
    ) throws -> ExcalidrawCore.ExcalidrawFileData {
        return .init(documentData: try snapshot.documentData(), elements: nil, files: [:])
    }

    /// A same-document replacement keeps the WebView's live viewport for every
    /// file source. Initial loads only apply a sidecar for sources whose
    /// viewport is intentionally device-local.
    private func dataByPreparingViewportForLoad(
        _ data: Data,
        fileID: String,
        preservingLiveViewport: Bool
    ) async -> Data {
        let usesLocalViewportSidecar = await usesLocalViewportSidecar(fileID: fileID)

        do {
            if preservingLiveViewport,
               let core,
               let appState = try? await core.getCurrentAppState(),
               let dataWithLiveViewport = try await ExcalidrawViewportStateStore.shared.contentData(
                    data,
                    preservingViewportFrom: appState,
                    sidecarFileID: usesLocalViewportSidecar ? fileID : nil
               ) {
                return dataWithLiveViewport
            }

            guard usesLocalViewportSidecar else {
                return data
            }

            return try await ExcalidrawViewportStateStore.shared.contentDataByApplyingStoredViewport(
                to: data,
                fileID: fileID
            )
        } catch {
            core?.logger.warning("Failed to apply local viewport state for file \(fileID): \(error)")
            return data
        }
    }

    private func canvasFileDataForPersistence(
        _ fileData: ExcalidrawCore.ExcalidrawFileData,
        currentFileID: String?
    ) async throws -> ExcalidrawCore.ExcalidrawFileData {
        var fileDataForPersistence = fileData

        if let currentFileID,
           await usesLocalViewportSidecar(fileID: currentFileID) {
            fileDataForPersistence.documentData = try await ExcalidrawViewportStateStore.shared.contentDataBySeparatingViewport(
                from: fileData.documentData,
                fileID: currentFileID
            )
        }

        fileDataForPersistence.documentData = try ExcalidrawDocumentAppStatePersistence.documentData(
            fileDataForPersistence.documentData,
            settingNativeFileName: await nativeFileNameForPersistence(currentFileID: currentFileID)
        )
        return fileDataForPersistence
    }

    private func usesLocalViewportSidecar(fileID: String) async -> Bool {
        await MainActor.run {
            guard core?.parent?.type == .normal,
                  let activeFile = core?.parent?.fileState.currentActiveFile,
                  activeFile.usesLocalViewportSidecar else {
                return false
            }
            return activeFile.id == fileID
        }
    }

    private func nativeFileNameForPersistence(currentFileID: String?) async -> String? {
        await MainActor.run {
            guard let activeFile = core?.parent?.fileState.currentActiveFile,
                  currentFileID == nil || activeFile.id == currentFileID else {
                return nil
            }
            return activeFile.name
        }
    }

    private static func elements(
        from fileData: ExcalidrawCore.ExcalidrawFileData
    ) async throws -> [ExcalidrawElement] {
        if let elements = fileData.elements {
            return elements
        }

        return try await Task.detached(priority: .utility) {
            let payload = try JSONDecoder().decode(
                SnapshotElementsPayload.self,
                from: fileData.documentData
            )
            return payload.elements
        }.value
    }

    private struct SnapshotElementsPayload: Decodable {
        var elements: [ExcalidrawElement]
    }

    private func loadPreparedFile(
        request: DocumentLoadStateMachine.Request,
        transportRequestID: String,
        data: Data
    ) async throws -> LoadFileResult? {
        guard let core else { return nil }

        let suppressionToken = beginCoreFileLoad(fileID: request.fileID)
        defer {
            endStateChangeSuppression(suppressionToken)
        }

        guard await core.waitUntilReadyForFileLoad(fileID: request.fileID) else {
            logFileLoad(
                core.logger,
                "File load skipped: core not ready id=\(request.fileID)",
                level: .warning
            )
            return nil
        }

        guard isCurrentLoadRequest(request) else { return nil }

        return try await core.webActor.loadFile(
            id: request.fileID,
            requestID: transportRequestID,
            data: data
        )
    }

    private func beginCanvasFileLoad(
        fileID: String,
        force: Bool,
        expectedEditRevision: UInt64? = nil,
        expectedLoadGeneration: UInt64? = nil
    ) -> (DocumentLoadStateMachine.Request, UUID)? {
        lock.lock()
        if let expectedEditRevision, !externalEditState.canReload(expectedRevision: expectedEditRevision) {
            lock.unlock()
            return nil
        }
        pruneExpiredStateChangeSuppressions()
        clearStateChangeSuppressions(reason: .preparingFileLoad, fileID: fileID)
        stateChangeSuppressions = stateChangeSuppressions.filter { _, suppression in
            suppression.reason != .canvasFileLoad && suppression.reason != .coreFileLoad
        }

        guard let request = loadState.begin(fileID: fileID, force: force, expectedGeneration: expectedLoadGeneration) else {
            lock.unlock()
            return nil
        }

        let token = UUID()
        stateChangeSuppressions[token] = .init(
            fileID: fileID,
            reason: .canvasFileLoad,
            startedAt: Date()
        )
        lock.unlock()
        canvasMutationSessionChangeSubject.send()
        loadEventContinuation.yield(.started(fileID: fileID))
        return (request, token)
    }

    private func beginCoreFileLoad(fileID: String) -> UUID {
        beginStateChangeSuppression(fileID: fileID, reason: .coreFileLoad)
    }

    private func endStateChangeSuppression(_ token: UUID) {
        lock.lock()
        stateChangeSuppressions.removeValue(forKey: token)
        lock.unlock()
    }

    private func isCurrentLoadRequest(_ request: DocumentLoadStateMachine.Request) -> Bool {
        lock.lock()
        let isCurrent = loadState.isCurrent(request)
        lock.unlock()
        return isCurrent
    }

    private func commitLoadedFile(_ request: DocumentLoadStateMachine.Request) -> Bool {
        lock.lock()
        let didCommit = loadState.confirm(request)
        lock.unlock()
        if didCommit {
            canvasMutationSessionChangeSubject.send()
            loadEventContinuation.yield(
                .finished(fileID: request.fileID, completion: .succeeded)
            )
        }
        return didCommit
    }

    private func finishCanvasFileLoad(
        _ request: DocumentLoadStateMachine.Request,
        outcome: LoadOutcome,
        failure: LoadFailure? = nil
    ) -> LoadOutcome {
        lock.lock()
        let wasCurrent = loadState.fail(request)
        lock.unlock()
        if wasCurrent {
            canvasMutationSessionChangeSubject.send()
            let completion: LoadCompletion = switch outcome {
                case .failed:
                    .failed(failure ?? LoadFailure(nil))
                case .superseded:
                    .superseded
                case .skipped, .loaded:
                    .superseded
            }
            loadEventContinuation.yield(
                .finished(fileID: request.fileID, completion: completion)
            )
        }
        return wasCurrent ? outcome : .superseded
    }

    func resetFileLoadState() {
        snapshotCoordinator.reset()
        lock.lock()
        loadState.reset()
        stateChangeSuppressions.removeAll()
        lock.unlock()
        canvasMutationSessionChangeSubject.send()
        loadEventContinuation.yield(.reset)
    }

    private func beginReceivedStateChanged(isCoreLoading: Bool, hasDirtyChanges: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredStateChangeSuppressions()
        let suppression = latestStateChangeSuppression()
        let pendingFileID = loadState.currentRequest?.fileID

        if let pendingFileID {
            return "document load pending id=\(pendingFileID)"
        }

        if let suppression {
            return "suppressed during file load id=\(suppression.fileID)"
        }

        if isCoreLoading {
            return "core loading"
        }

        externalEditState.beginEvent(isDirty: hasDirtyChanges)
        return nil
    }

    private func canApplyStateChanged(
        currentFileID: String?,
        webLoadedFileID: String?,
        isCollaboration: Bool
    ) -> Bool {
        if isCollaboration {
            return true
        }

        guard let currentFileID else {
            return false
        }

        return webLoadedFileID == currentFileID
    }

    private func beginStateChangeSuppression(
        fileID: String,
        reason: StateChangeSuppressionReason
    ) -> UUID {
        let token = UUID()
        lock.lock()
        pruneExpiredStateChangeSuppressions()
        stateChangeSuppressions[token] = .init(
            fileID: fileID,
            reason: reason,
            startedAt: Date()
        )
        lock.unlock()
        return token
    }

    private func pruneExpiredStateChangeSuppressions() {
        let now = Date()
        stateChangeSuppressions = stateChangeSuppressions.filter { _, suppression in
            now.timeIntervalSince(suppression.startedAt) <= 8
        }
    }

    private func clearStateChangeSuppressions(
        reason: StateChangeSuppressionReason,
        fileID: String
    ) {
        stateChangeSuppressions = stateChangeSuppressions.filter { _, suppression in
            !(suppression.reason == reason && suppression.fileID == fileID)
        }
    }

    private func latestStateChangeSuppression() -> StateChangeSuppression? {
        stateChangeSuppressions.values.max { lhs, rhs in
            lhs.startedAt < rhs.startedAt
        }
    }

#if DEBUG
    private func debugStateChangedSummary(_ data: ExcalidrawCore.StateChangedMessageData) -> String {
        if let metadata = data.metadata, data.fileData == nil {
            return debugMetadataSummary(metadata)
        }

        if data.fileData != nil {
            return "payload=fullSnapshot"
        }

        return "payload=empty"
    }

    private func debugMetadataSummary(_ metadata: ExcalidrawCore.StateChangedMetadata) -> String {
        [
            "payload=metadata",
            "revision=\(metadata.revision.map(String.init) ?? "nil")",
            "dirty=\(metadata.dirty.map(String.init) ?? "nil")",
            "contentDirty=\(metadata.contentDirty.map(String.init) ?? "nil")",
            "appStateDirty=\(metadata.appStateDirty.map(String.init) ?? "nil")",
            "currentFileId=\(metadata.currentFileId ?? "nil")",
            "elements=\(metadata.elementCount.map(String.init) ?? "nil")",
            "fileElements=\(metadata.fileElementCount.map(String.init) ?? "nil")",
            "appStateKeys=\(metadata.appStateKeyCount.map(String.init) ?? "nil")",
            "appStateChars=\(metadata.appStateChars.map(String.init) ?? "nil")"
        ].joined(separator: " ")
    }
#endif
}

extension ExcalidrawDocumentSyncController: ExcalidrawDocumentSnapshotCoordinatorDelegate {
    var snapshotCoordinatorCore: ExcalidrawCore? {
        core
    }

    func snapshotCoordinatorCanApplyStateChanged(
        currentFileID: String?,
        webLoadedFileID: String?,
        isCollaboration: Bool
    ) -> Bool {
        canApplyStateChanged(
            currentFileID: currentFileID,
            webLoadedFileID: webLoadedFileID,
            isCollaboration: isCollaboration
        )
    }

    func snapshotCoordinatorApplyCanvasFileData(
        _ fileData: ExcalidrawCore.ExcalidrawFileData,
        currentFileID: String?,
        type: ExcalidrawCanvasView.ExcalidrawType?,
        savingType: UTType?,
        markProgrammaticCommit: Bool,
        capture: CanvasSaveCapture?
    ) async throws {
        try await applyCanvasFileData(
            fileData,
            currentFileID: currentFileID,
            type: type,
            savingType: savingType,
            markProgrammaticCommit: markProgrammaticCommit,
            capture: capture
        )
    }

    func snapshotCoordinatorMakeFileData(
        from snapshot: ExcalidrawCore.CurrentFileSnapshot
    ) throws -> ExcalidrawCore.ExcalidrawFileData {
        try Self.makeFileData(from: snapshot)
    }
}
