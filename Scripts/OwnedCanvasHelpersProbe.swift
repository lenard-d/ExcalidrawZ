import Foundation
import JavaScriptCore

// Only the bridge, persistence adapter and unrelated UI dependencies are fixtures.
// The runner inserts exact production methods and compiles the real save modules.
struct ProbeFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProbeFailure(description: message) }
}

@MainActor
final class BridgeGate {
    var entered = false
    var released = false
    func pause() async throws {
        entered = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !released {
            if ContinuousClock.now >= deadline { throw ProbeFailure(description: "Bridge gate timeout") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func waitForEntry() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered {
            if ContinuousClock.now >= deadline { throw ProbeFailure(description: "Bridge did not start") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

struct ExcalidrawElement: Codable { let id: String }
struct ReplaceAllElementsOptions: Codable {}
struct CreateElementsOptions: Codable {}
struct UpdateElementOperation: Codable { let id: String }
struct InvalidJavaScriptResult: Error {}
// INSERT IMAGE RESULT
struct ExcalidrawFile {
    var id = "A"
    var content: Data? = Data("before".utf8)
    mutating func update(data: Data) throws { content = data }
}
enum CanvasType { case normal, collaboration }
enum SavingType { case excalidrawFile }
struct SceneSnapshot { let revision: Int?; let content: Data }
struct ProbeLogger {
    func debug(_ message: String) {}
    func error(_ message: String) {}
}

@MainActor
final class FixtureFileState {
    var currentActiveFile: ExcalidrawFile? = .init()
    var externalSaveSessionID = UUID()
    let canvasSaveCoordinator = CanvasSaveCoordinator()
    weak var core: ExcalidrawCore?
    var terminationSaveToken: CanvasMutationSession? { core?.documentSyncController.captureCanvasMutationSession() }
    func noteProgrammaticCanvasMutation(fileID: String) {}
    func captureCanvasSave(expectedFileID: String?) -> CanvasSaveCapture? {
        guard let owner = core?.documentSyncController.captureCanvasMutationSession(),
              owner.fileID == expectedFileID else { return nil }
        return canvasSaveCoordinator.capture(owner: owner)
    }
}
@MainActor
final class FixtureParent {
    var file: ExcalidrawFile? = .init()
    let fileState = FixtureFileState()
    var type: CanvasType = .normal
    var savingType: SavingType = .excalidrawFile
}

@MainActor
final class FixtureWebView {
    enum World { case page }
    var isLoading = false
    var currentFileID = "A"
    var scene = "before"
    var gate: BridgeGate?
    var failure: Error?
    var calls = 0
    var ownedAtEntry = false
    var nullImageResult = false
    weak var core: ExcalidrawCore?
    func callAsyncJavaScript(_ script: String, arguments: [String: Any], contentWorld: World) async throws -> Any? {
        calls += 1
        ownedAtEntry = core?.documentSyncController.snapshot.hasPendingSave == true
        try await gate?.pause()
        if let failure { throw failure }
        let context = JSContext()!
        context.evaluateScript("""
        var window = globalThis;
        var probeScene = "before";
        var probeFinished = false;
        var probeError = null;
        window.excalidrawZHelper = {
            _api: {}, currentFileId: "",
            replaceAllElements() { probeScene = 'after-' + this.currentFileId; },
            addElements() { probeScene = 'after-' + this.currentFileId; },
            updateElements() { probeScene = 'after-' + this.currentFileId; },
            removeElements() { probeScene = 'after-' + this.currentFileId; },
            loadImageBuffer() { probeScene = 'after-' + this.currentFileId; return Promise.resolve({elementCount: 7, durationMs: 12.5}); }
        };
        """)
        context.objectForKeyedSubscript("excalidrawZHelper")?.setValue(currentFileID, forProperty: "currentFileId")
        if nullImageResult {
            context.evaluateScript("excalidrawZHelper.loadImageBuffer = function() { probeScene = 'after-' + this.currentFileId; return Promise.resolve(null); };")
        }
        for (key, value) in arguments { context.setObject(value, forKeyedSubscript: key as NSString) }
        context.evaluateScript("""
        (async function() { \(script) })().then(
            value => { globalThis.probeResult = value; probeFinished = true; },
            error => { probeError = String(error); probeFinished = true; }
        );
        """)
        if let exception = context.exception { throw ProbeFailure(description: exception.toString()) }
        try require(context.objectForKeyedSubscript("probeFinished")!.toBool(), "JavaScript fixture did not settle")
        if let error = context.objectForKeyedSubscript("probeError"), !error.isNull {
            throw ProbeFailure(description: error.toString())
        }
        scene = context.objectForKeyedSubscript("probeScene")!.toString()
        return context.objectForKeyedSubscript("probeResult")?.toObject()
    }
}

final class ExcalidrawCore {
    enum JSONValue: Codable { case string(String) }
    var parent: FixtureParent?
    let webView: FixtureWebView
    let documentSyncController = ExcalidrawDocumentSyncController()
    var isLoading = false
    let logger = ProbeLogger()
    var publishError: (Error) -> Void = { _ in }
    var reads: [String] = []
    @MainActor init() {
        parent = FixtureParent()
        webView = FixtureWebView()
        parent?.fileState.core = self
        webView.core = self
        documentSyncController.core = self
        documentSyncController.snapshot.delegate = documentSyncController
        documentSyncController.snapshot.programmaticCommitter.attach(delegate: documentSyncController)
        let request = documentSyncController.loadState.begin(fileID: "A", force: false)!
        precondition(documentSyncController.loadState.confirm(request))
    }
    func encodeJSON<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    func makeJavaScriptHelperCall(_ value: String) -> String { value }
    func decodeJavaScriptHelperResult<Value>(_ value: Any?, as: Value.Type) throws -> Value {
        guard let value = value as? Value else { throw InvalidJavaScriptResult() }
        return value
    }
    @MainActor func getCurrentFileSnapshot() async throws -> SceneSnapshot {
        reads.append(webView.scene)
        return SceneSnapshot(revision: 1, content: Data(webView.scene.utf8))
    }
}

// INSERT ELEMENTS
// INSERT MEDIA

protocol ExcalidrawDocumentSnapshotCoordinatorDelegate: AnyObject {
    var snapshotCoordinatorCore: ExcalidrawCore? { get }
    func snapshotCoordinatorCanApplyStateChanged(currentFileID: String?, webLoadedFileID: String?, isCollaboration: Bool) -> Bool
    func snapshotCoordinatorMakeFileData(from snapshot: SceneSnapshot) throws -> Data
    func snapshotCoordinatorApplyCanvasFileData(_ data: Data, currentFileID: String?, type: CanvasType?, savingType: SavingType?, markProgrammaticCommit: Bool, capture: CanvasSaveCapture) async throws
}

final class ExcalidrawDocumentSyncController: ExcalidrawDocumentSnapshotCoordinatorDelegate, @unchecked Sendable {
    let lock = NSLock()
    var externalEditState = ExternalCanvasEditState()
    var loadState = DocumentLoadStateMachine()
    weak var core: ExcalidrawCore?
    let snapshot = ExcalidrawDocumentSnapshotCoordinator()
    var snapshotCoordinator: ExcalidrawDocumentSnapshotCoordinator { snapshot }
    var currentLoadedFileID: String? { lock.withLock { loadState.confirmedFileID } }
    var snapshotCoordinatorCore: ExcalidrawCore? { core }
    func pruneExpiredStateChangeSuppressions() {}
    struct Suppression { let fileID: String }
    func latestStateChangeSuppression() -> Suppression? { nil }
    static func makeFileData(from snapshot: SceneSnapshot) throws -> Data { snapshot.content }
    func snapshotCoordinatorCanApplyStateChanged(currentFileID: String?, webLoadedFileID: String?, isCollaboration: Bool) -> Bool { currentFileID == webLoadedFileID }
    func snapshotCoordinatorMakeFileData(from snapshot: SceneSnapshot) throws -> Data { snapshot.content }
    func snapshotCoordinatorApplyCanvasFileData(_ data: Data, currentFileID: String?, type: CanvasType?, savingType: SavingType?, markProgrammaticCommit: Bool, capture: CanvasSaveCapture) async throws {
        try await capture.performSave {
            try capture.withAdmission { snapshot.persisted = data }
        }
    }
    @MainActor func scheduleProgrammaticMutationCommit(reason: String) { snapshot.scheduleProgrammaticMutationCommit(reason: reason) }
    // INSERT CONTROLLER
}

final class FixtureContentScheduler {
    struct FlushState { let expectedFileID: String?; let expectedRevision: Int? }
    func waitForCommitToFinish() async -> Bool { true }
    func takeFlushState() -> FlushState? { nil }
    func hasPendingDirtySnapshot() -> Bool { false }
    func markCommitted(snapshotRevision: Int?, fallbackRevision: Int?) {}
}
final class FixtureAppStateSaver {
    var pendingRevision: UInt64 = 0
    func acknowledgeFullSnapshot(_ revision: UInt64) {}
    func flushCurrentAppState(reason: String) async -> Bool { false }
    func flush(reason: String) async {}
}
final class ExcalidrawDocumentSnapshotCoordinator: @unchecked Sendable {
    weak var delegate: ExcalidrawDocumentSnapshotCoordinatorDelegate?
    let programmaticCommitter = ExcalidrawDocumentProgrammaticSnapshotCommitter()
    let contentScheduler = FixtureContentScheduler()
    let appStateSaver = FixtureAppStateSaver()
    var persisted: Data?
    var hasPendingSave: Bool { programmaticCommitter.hasPendingSave }
    // INSERT SNAPSHOT
}

@main
struct OwnedCanvasHelpersProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func run() async throws {
        let mutations: [(String, @MainActor (ExcalidrawCore) async throws -> Void)] = [
            ("replace", { try await $0.replaceAllElements([ExcalidrawElement(id: "new")]) }),
            ("replaceRaw", { try await $0.replaceAllElements(rawElementsJSON: "[]") }),
            ("add", { try await $0.addElements([ExcalidrawElement(id: "new")]) }),
            ("update", { try await $0.updateElements([UpdateElementOperation(id: "old")]) }),
            ("remove", { try await $0.removeElements(ids: ["old"]) }),
            ("image", { let result = try await $0.loadImageToExcalidrawCanvas(imageData: Data([1]), type: "png"); try require(result?.elementCount == 7 && result?.durationMs == 12.5, "Image result changed") })
        ]
        for (name, mutate) in mutations {
            let core = ExcalidrawCore()
            let gate = BridgeGate()
            core.webView.gate = gate
            let mutation = Task { @MainActor in try await mutate(core) }
            defer { gate.released = true; mutation.cancel(); core.documentSyncController.snapshot.programmaticCommitter.reset() }
            try await gate.waitForEntry()
            let flush = Task { await core.documentSyncController.snapshot.flushPendingDirtySnapshot(reason: "lifecycle", force: true) }
            let recovery = Task { @MainActor in try await core.documentSyncController.currentCanvasFileForRecoveryExport() }
            defer { flush.cancel(); recovery.cancel() }
            try await Task.sleep(for: .milliseconds(20))
            try require(core.reads.isEmpty, "\(name): flush/recovery read an incomplete scene")
            try require(core.webView.ownedAtEntry, "\(name): bridge entered before ownership")
            try require(core.documentSyncController.snapshot.persisted == nil, "\(name): old scene became durable")
            gate.released = true
            try await mutation.value
            await flush.value
            let recovered = try await recovery.value
            try require(recovered.content == Data("after-A".utf8), "\(name): recovery did not contain completed scene")
            try require(core.documentSyncController.snapshot.persisted == Data("after-A".utf8), "\(name): flush missed original owner scene")
            try require(!core.parent!.fileState.canvasSaveCoordinator.hasPendingSave, "\(name): durable scene stayed pending")
            print("PASS \(name): ownership before bridge; lifecycle and recovery wait; exact final scene/result")
        }
        try await verifyRejectedOwnerAndBridgeErrors()
        try await verifyCancelledWaiters()
        try await verifyStaleCompletion(sameFile: true)
        try await verifyStaleCompletion(sameFile: false)
        try await verifyParentlessAndLockedCanvas()
        try await verifyEmptyMutationsAndOptionalImageResult()
    }

    @MainActor static func verifyRejectedOwnerAndBridgeErrors() async throws {
        for wrongOwner in [false, true] {
            let core = ExcalidrawCore()
            defer { core.documentSyncController.snapshot.programmaticCommitter.reset() }
            if wrongOwner { core.webView.currentFileID = "B" }
            else { core.webView.failure = CocoaError(.coderInvalidValue) }
            do {
                try await core.addElements([ExcalidrawElement(id: "new")])
                throw ProbeFailure(description: "Bridge failure was swallowed")
            } catch is CocoaError {
                try require(!wrongOwner, "Wrong error type")
            } catch let failure as ProbeFailure {
                try require(wrongOwner && failure.description.contains("canvas document changed"), "Unexpected bridge error: \(failure)")
            }
            try require(core.webView.scene == "before", "Wrong-owner/failed bridge changed scene")
            try require(core.documentSyncController.snapshot.hasPendingSave, "Bridge failure cleared pending content")
            try require(core.parent!.fileState.canvasSaveCoordinator.hasPendingSave, "Failure produced a durable receipt")
            print("PASS \(wrongOwner ? "wrong JS owner" : "bridge failure"): error propagates; scene protected; pending retained")
        }
    }

    @MainActor static func verifyCancelledWaiters() async throws {
        let core = ExcalidrawCore()
        let gate = BridgeGate()
        core.webView.gate = gate
        let mutation = Task { @MainActor in try await core.addElements([ExcalidrawElement(id: "new")]) }
        defer { gate.released = true; mutation.cancel(); core.documentSyncController.snapshot.programmaticCommitter.reset() }
        try await gate.waitForEntry()
        let flush = Task { await core.documentSyncController.snapshot.flushPendingDirtySnapshot(reason: "cancelledLifecycle", force: true) }
        let recovery = Task { @MainActor in try await core.documentSyncController.currentCanvasFileForRecoveryExport() }
        defer { flush.cancel(); recovery.cancel() }
        flush.cancel()
        recovery.cancel()
        await flush.value
        do { _ = try await recovery.value; throw ProbeFailure(description: "Cancelled recovery returned stale content") }
        catch is CancellationError {}
        try require(core.reads.isEmpty, "Cancelled waiter read an unfinished scene")
        try require(core.parent!.fileState.canvasSaveCoordinator.hasPendingSave, "Cancellation cleared pending content")
        gate.released = true
        try await mutation.value
        await core.documentSyncController.snapshot.flushPendingDirtySnapshot(reason: "retry", force: true)
        try require(core.documentSyncController.snapshot.persisted == Data("after-A".utf8), "Retry did not save completed scene")
        try require(!core.parent!.fileState.canvasSaveCoordinator.hasPendingSave, "Retry did not acknowledge real receipt")
        print("PASS cancelled lifecycle/recovery waits: no early read/receipt; bridge completes; later flush saves")
    }

    @MainActor static func verifyStaleCompletion(sameFile: Bool) async throws {
        let core = ExcalidrawCore()
        let gate = BridgeGate()
        core.webView.gate = gate
        let mutation = Task { @MainActor in try await core.addElements([ExcalidrawElement(id: "new")]) }
        defer { gate.released = true; mutation.cancel(); core.documentSyncController.snapshot.programmaticCommitter.reset() }
        try await gate.waitForEntry()
        let previous = core.documentSyncController.captureCanvasMutationSession()!
        let newID = sameFile ? "A" : "B"
        let request = core.documentSyncController.loadState.begin(fileID: newID, force: true)!
        precondition(core.documentSyncController.loadState.confirm(request))
        core.parent!.file!.id = newID
        core.parent!.fileState.currentActiveFile!.id = newID
        core.parent!.fileState.externalSaveSessionID = UUID()
        core.parent!.fileState.canvasSaveCoordinator.invalidate()
        core.documentSyncController.snapshot.programmaticCommitter.reset()
        // Keep JS at the captured document, as an already-submitted bridge may complete before its replacement load.
        try require(core.documentSyncController.captureCanvasMutationSession() != previous, "Reload did not change owner")
        gate.released = true
        do { try await mutation.value; throw ProbeFailure(description: "Stale mutation returned success") }
        catch is CancellationError {}
        try require(!core.parent!.fileState.canvasSaveCoordinator.hasPendingSave, "Old completion dirtied the new owner")
        try require(core.documentSyncController.snapshot.persisted == nil, "Old completion saved the new owner")
        try require(core.documentSyncController.snapshot.hasPendingSave, "Old unresolved mutation was acknowledged")
        print("PASS stale \(sameFile ? "same-file generation" : "different-file owner"): no new-owner scheduling or false receipt")
    }

    @MainActor static func verifyParentlessAndLockedCanvas() async throws {
        let sandbox = ExcalidrawCore()
        sandbox.parent = nil
        try await sandbox.replaceAllElements([])
        try require(sandbox.webView.scene == "after-A", "Parentless proposal reset broke")
        try require(!sandbox.documentSyncController.snapshot.hasPendingSave, "Parentless preview acquired a save owner")
        let collaboration = ExcalidrawCore()
        collaboration.parent!.type = .collaboration
        collaboration.documentSyncController.loadState.reset()
        collaboration.webView.currentFileID = "room"
        try await collaboration.addElements([ExcalidrawElement(id: "shared")])
        try require(collaboration.webView.scene == "after-room", "Explicit collaboration bridge broke")
        try require(!collaboration.documentSyncController.snapshot.hasPendingSave, "Collaboration acquired a local document receipt")
        let unloaded = ExcalidrawCore()
        unloaded.documentSyncController.loadState.reset()
        do { try await unloaded.addElements([ExcalidrawElement(id: "new")]); throw ProbeFailure(description: "Normal unloaded document used collaboration bypass") }
        catch is CancellationError {}
        try require(unloaded.webView.calls == 0, "Normal document with no session reached bridge")
        let locked = ExcalidrawCore()
        locked.parent!.file = nil // Production Editor.prepareEditorForLockedFile removes this binding.
        do { try await locked.addElements([ExcalidrawElement(id: "new")]); throw ProbeFailure(description: "Locked canvas accepted mutation") }
        catch is CancellationError {}
        try require(locked.webView.calls == 0, "Locked canvas reached JavaScript")
        print("PASS explicit preview/collaboration bypass only; normal unloaded and locked documents reject before bridge")
    }

    @MainActor static func verifyEmptyMutationsAndOptionalImageResult() async throws {
        let core = ExcalidrawCore()
        defer { core.documentSyncController.snapshot.programmaticCommitter.reset() }
        try await core.addElements([])
        try await core.updateElements([])
        try await core.removeElements(ids: [])
        try require(core.webView.calls == 0 && !core.documentSyncController.snapshot.hasPendingSave, "Empty mutations acquired dirty work")
        core.webView.nullImageResult = true
        let result = try await core.loadImageToExcalidrawCanvas(imageData: Data([1]), type: "png")
        try require(result == nil, "Optional image acknowledgement changed")
        try require(core.documentSyncController.snapshot.hasPendingSave, "Image work lost its pending snapshot")
        print("PASS empty element no-ops and optional image result preservation")
    }
}
