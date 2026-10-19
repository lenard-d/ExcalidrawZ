import Foundation

/// Used under the document controller's lock to join edit admission and reload admission.
struct ExternalCanvasEditState {
    private(set) var revision: UInt64 = 0
    private var activeEvents = 0

    mutating func beginEvent(isDirty: Bool) {
        activeEvents += 1
        if isDirty { revision &+= 1 }
    }

    mutating func endEvent() {
        activeEvents -= 1
    }

    func canReload(expectedRevision: UInt64) -> Bool {
        revision == expectedRevision && activeEvents == 0
    }
}

/// A conditional replacement is accepted only at the point that arms the real canvas load.
@MainActor
final class ExternalCanvasReloadRequest {
    let fileID: String
    let editRevision: UInt64
    let loadGeneration: UInt64?
    private let isCurrent: () -> Bool
    private let onAccept: () -> Void
    private let onReject: () -> Void
    private var started = false
    private var finished = false

    init(
        fileID: String,
        editRevision: UInt64,
        loadGeneration: UInt64? = nil,
        isCurrent: @escaping () -> Bool,
        onAccept: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        self.fileID = fileID
        self.editRevision = editRevision
        self.loadGeneration = loadGeneration
        self.isCurrent = isCurrent
        self.onAccept = onAccept
        self.onReject = onReject
    }

    func start(fileID: String, armLoad: () -> Bool) -> Bool {
        guard !started, !finished else { return false }
        guard !Task.isCancelled, self.fileID == fileID, isCurrent(), armLoad() else {
            finished = true
            onReject()
            return false
        }
        started = true
        return true
    }

    func finish(didLoad: Bool) {
        guard started, !finished else { return }
        finished = true
        guard didLoad, !Task.isCancelled, isCurrent() else {
            onReject()
            return
        }
        onAccept()
    }
}
