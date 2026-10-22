// CLI scaffolding. The runner inserts exact production methods and the publisher.
import Foundation
import Combine

actor ExternalFileSaveCoordinator {
    static let shared = ExternalFileSaveCoordinator()
    func releaseSession(_ session: UUID) {}
}

@MainActor final class FileState {
    struct ActiveFile { let id: String }
    var currentActiveFile: ActiveFile? = ActiveFile(id: "drawing")
    var externalSaveSessionID = UUID()
    let canvasSaveCoordinator = CanvasSaveCoordinator()
    var excalidrawWebCoordinator: Coordinator?
    // INSERT INSTALL
}

@MainActor final class Coordinator {
    let documentSyncController: ControllerProbe
    init(_ controller: ControllerProbe) { documentSyncController = controller }
}

@MainActor final class Core {
    struct File { let id = "drawing" }
    final class Parent {
        let fileState: FileState
        var file: File? = File()
        init(_ fileState: FileState) { self.fileState = fileState }
    }
    let parent: Parent?
    init(_ fileState: FileState) { parent = Parent(fileState) }
}

@MainActor final class ControllerProbe {
    let core: Core?
    private let lock = NSLock()
    private var loadState = DocumentLoadStateMachine()
    init(_ state: FileState) {
        core = Core(state)
        let request = loadState.begin(fileID: "drawing", force: false)!
        precondition(loadState.confirm(request))
    }
    // INSERT PUBLISHER
    // INSERT CONTROLLER METHODS
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main struct Probe {
    @MainActor static func main() {
        let state = FileState()
        let controller = ControllerProbe(state)
        state.excalidrawWebCoordinator = Coordinator(controller)
        let original = controller.captureCanvasMutationSession()!
        var first: [CanvasMutationSession?] = []
        var second: [CanvasMutationSession?] = []
        let one = controller.canvasMutationSessionChanges.sink {
            first.append(controller.captureCanvasMutationSession())
        }
        let two = controller.canvasMutationSessionChanges.sink {
            second.append(controller.captureCanvasMutationSession())
        }
        let replacement = UUID()
        state.installExternalSaveSession(replacement)
        let current = controller.captureCanvasMutationSession()!
        require(current.fileID == original.fileID && current.loadGeneration == original.loadGeneration,
                "session replacement must keep the same confirmed file and load generation")
        require(current.saveSession == replacement && current.saveSession != original.saveSession,
                "actual capture must use the assigned save session")
        require(!controller.isCurrentCanvasMutationSession(original), "old owner must be invalid")
        require(controller.isCurrentCanvasMutationSession(current), "new owner must be valid")
        require(first == [current] && second == [current],
                "both subscribers must synchronously observe the assigned token without load or next action")
        state.installExternalSaveSession(replacement)
        require(first == [current] && second == [current], "identical UUID must not emit an owner change")
        require(controller.isCurrentCanvasMutationSession(current), "identical UUID keeps current owner")
        withExtendedLifetime((one, two)) {}
        print("PASS: actual install, real capture token, same file/generation, new UUID, two synchronous subscribers, old owner invalid, identical UUID silent")
    }
}
