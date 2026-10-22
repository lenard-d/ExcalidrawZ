// CLI-only scaffolding. The runner inserts exact controller methods and publisher.
import Foundation
import Combine

final class ControllerProbe {
    struct LoadFailure { init(_ error: Error?) {} }
    enum LoadCompletion { case succeeded, failed(LoadFailure), superseded }
    enum LoadEvent { case started(fileID: String), finished(fileID: String, completion: LoadCompletion), reset }
    enum LoadOutcome { case skipped, loaded, superseded, failed }
    enum Reason { case preparingFileLoad, canvasFileLoad, coreFileLoad }
    struct Suppression { let fileID: String; let reason: Reason; let startedAt: Date }
    struct EditState { func canReload(expectedRevision: UInt64) -> Bool { true } }
    struct SnapshotCoordinator { func reset() {} }
    struct Snapshot: Equatable { let generation: UInt64; let confirmed: String?; let pending: Bool }
    private let lock = NSLock()
    private var loadState = DocumentLoadStateMachine()
    private var stateChangeSuppressions: [UUID: Suppression] = [:]
    private var externalEditState = EditState()
    private let snapshotCoordinator = SnapshotCoordinator()
    private let loadEventContinuation: AsyncStream<LoadEvent>.Continuation
    init() {
        var continuation: AsyncStream<LoadEvent>.Continuation!
        _ = AsyncStream<LoadEvent> { continuation = $0 }
        loadEventContinuation = continuation
    }
    private func pruneExpiredStateChangeSuppressions() {}
    private func clearStateChangeSuppressions(reason: Reason, fileID: String) {}
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(generation: loadState.generation, confirmed: loadState.confirmedFileID, pending: loadState.currentRequest != nil)
    }
    func start(force: Bool = false, expected: UInt64? = nil) -> DocumentLoadStateMachine.Request? {
        beginCanvasFileLoad(fileID: "drawing", force: force, expectedLoadGeneration: expected)?.0
    }
    func confirm(_ request: DocumentLoadStateMachine.Request) -> Bool { commitLoadedFile(request) }
    func fail(_ request: DocumentLoadStateMachine.Request) { _ = finishCanvasFileLoad(request, outcome: .failed, failure: LoadFailure(nil)) }
    // INSERT PUBLISHER
    // INSERT METHODS
}

let controller = ControllerProbe()
var first: [ControllerProbe.Snapshot] = []
var second: [ControllerProbe.Snapshot] = []
let one = controller.canvasMutationSessionChanges.sink { first.append(controller.snapshot()) }
let two = controller.canvasMutationSessionChanges.sink { second.append(controller.snapshot()) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let initial = controller.start()!
require(first == [.init(generation: 1, confirmed: nil, pending: true)], "both subscribers must observe load admission")
require(controller.confirm(initial), "initial confirmation")
let captured = controller.snapshot()
require(first.last == captured && !captured.pending && captured.confirmed == "drawing", "confirmation makes current session available")
let count = first.count
require(controller.start() == nil, "duplicate clean load rejected")
require(first.count == count, "rejected load emits no state change")
let forced = controller.start(force: true)!
require(first.last?.pending == true && first.last?.generation != captured.generation, "same-ID forced reload invalidates captured generation before completion")
require(controller.start(force: true, expected: captured.generation) == nil, "stale generation cannot enter")
require(first.count == count + 1, "stale rejected admission emits no event")
require(!controller.confirm(initial), "stale completion rejected")
require(first.count == count + 1, "stale completion emits no event")
controller.fail(forced)
require(first.last?.pending == false && first.last?.generation == forced.generation, "failed current load announces changed admission state")
let retry = controller.start(force: true)!
require(controller.confirm(retry), "retry confirms")
require(first.last?.generation == retry.generation && first.last?.confirmed == "drawing", "retry exposes latest confirmed generation")
controller.resetFileLoadState()
require(first.last?.confirmed == nil && first.last?.pending == false && first.last!.generation > retry.generation, "reset expires confirmed session")
require(first == second, "independent subscribers receive same state sequence")
withExtendedLifetime((one, two)) {}
print("PASS: admission, rejection, same-ID generation, current/stale completion, failure, reset, two reentrant subscribers")
