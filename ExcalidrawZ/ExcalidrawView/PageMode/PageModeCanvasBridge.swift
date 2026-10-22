import Foundation
import WebKit

/// Keeps all page commands within the loaded drawing's save session.
@MainActor
final class PageModeCanvasBridge {
    private let core: ExcalidrawCore
    private let toolState: ToolState
    private let fileState: FileState
    private let lockedContentState: LockedContentStateStore
    private let session: CanvasMutationSession

    init(core: ExcalidrawCore, toolState: ToolState, fileState: FileState, lockedContentState: LockedContentStateStore) throws {
        guard lockedContentState.activeFileLockState != .locked,
              !core.isLoading, !core.webView.isLoading,
              let session = core.documentSyncController.captureCanvasMutationSession() else {
            throw PageModeError.unavailable
        }
        self.core = core
        self.toolState = toolState
        self.fileState = fileState
        self.lockedContentState = lockedContentState
        self.session = session
        try validate()
    }

    func makeController() -> PageModeController {
        let controller = PageModeController(execute: { try await self.execute($0) }, render: { try await self.render($0, page: $1) }, isCurrent: { self.isCurrent() })
        controller.observeSessionChanges(core.documentSyncController.canvasMutationSessionChanges)
        return controller
    }

    private func isCurrent() -> Bool {
        lockedContentState.activeFileLockState != .locked &&
        fileState.currentActiveFile?.id == session.fileID &&
        toolState.excalidrawWebCoordinator === core &&
        !core.isLoading && !core.webView.isLoading &&
        core.documentSyncController.isCurrentCanvasMutationSession(session)
    }

    private func validate() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw PageModeError.documentChanged }
    }

    private func execute(_ command: PageModeCommand) async throws -> String {
        try validate()
        let json = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        if !command.changesScene { return try await call(commandJSON: json) }
        var result: String?
        try await core.documentSyncController.performOwnedCanvasMutation(reason: "pages-\(command.action.rawValue)") { owner in
            try self.validate()
            guard owner == self.session else { throw PageModeError.documentChanged }
            result = try await self.call(commandJSON: json)
        }
        try validate()
        guard let result else { throw PageModeError.documentChanged }
        return result
    }

    private func call(commandJSON: String) async throws -> String {
        try await run(script: PageModeSceneScript.body, arguments: ["expectedFileID": session.fileID, "commandJSON": commandJSON])
    }

    private func render(_ snapshot: PageModeExportSnapshot, page: PageModePage) async throws -> Data {
        let base64 = try await run(script: PageModeExportSnapshot.renderScript, arguments: ["expectedFileID": session.fileID, "sceneJSON": snapshot.sceneJSON, "pageID": page.id])
        guard let data = Data(base64Encoded: base64) else { throw PageModeError.invalidExport }
        return data
    }

    private func run(script: String, arguments: [String: Any]) async throws -> String {
        try validate()
        do {
            let result = try await core.webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
            try validate()
            guard let result = result as? String else { throw PageModeError.failedAction }
            return result
        } catch {
            try validate()
            let nativeError = error as NSError
            if nativeError.domain == WKError.errorDomain,
               nativeError.code == WKError.javaScriptExceptionOccurred.rawValue {
                let message = nativeError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
                let code = message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
                throw PageModeError(rawValue: code) ?? .failedAction
            }
            throw error
        }
    }
}
