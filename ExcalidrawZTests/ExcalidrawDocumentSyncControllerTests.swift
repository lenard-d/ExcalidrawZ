#if os(iOS) && targetEnvironment(simulator)
import Combine
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import ExcalidrawZ

/// Requires the isolated simulator app host. The inline page replaces only the web application.
final class ExcalidrawDocumentSyncControllerTests: XCTestCase {
    @MainActor
    func testPublicForcedLoadInvalidatesCapturedSessionAndBroadcastsToBothSubscribers() async throws {
        let fixture = try await CanvasControllerFixture.open()
        addTeardownBlock { await fixture.close() }
        let controller = fixture.core.documentSyncController
        let original = try XCTUnwrap(controller.captureCanvasMutationSession())
        let first = LoadObservations(controller)
        let second = LoadObservations(controller)

        // Duplicate public admission must keep the existing token and emit nothing.
        let duplicate = await controller.load(fixture.model.file)
        if case .skipped = duplicate { } else { XCTFail("A confirmed duplicate must be skipped") }
        XCTAssertEqual(controller.captureCanvasMutationSession(), original)
        XCTAssertTrue(first.values.isEmpty)
        XCTAssertTrue(second.values.isEmpty)

        try await fixture.evaluate("window.holdNextLoad = true")
        let reload = Task { await controller.load(fixture.model.file, force: true).didLoad }
        fixture.cancelOnClose(reload)
        try await fixture.waitForJavaScript("window.loadPaused === true")
        XCTAssertTrue(controller.hasPendingFileLoad)
        XCTAssertFalse(controller.isCurrentCanvasMutationSession(original))
        XCTAssertNil(controller.captureCanvasMutationSession())
        XCTAssertGreaterThan(controller.currentLoadGeneration, original.loadGeneration)
        let pendingGeneration = controller.currentLoadGeneration
        XCTAssertEqual(first.values, [.init(generation: pendingGeneration, fileID: original.fileID, pending: true)])
        XCTAssertEqual(second.values, first.values)

        let rejected = await controller.load(fixture.model.file)
        if case .skipped = rejected { } else { XCTFail("An in-flight duplicate must be skipped") }
        XCTAssertEqual(controller.currentLoadGeneration, pendingGeneration)
        XCTAssertEqual(first.values.count, 1)
        XCTAssertEqual(second.values, first.values)

        try await fixture.evaluate("window.releaseLoad()")
        let loaded = try await boundedSaveTestValue(reload, timeout: .seconds(8))
        XCTAssertTrue(loaded)
        let replacement = try XCTUnwrap(controller.captureCanvasMutationSession())
        XCTAssertEqual(replacement.fileID, original.fileID)
        XCTAssertEqual(replacement.saveSession, original.saveSession)
        XCTAssertEqual(replacement.loadGeneration, pendingGeneration)
        XCTAssertFalse(controller.isCurrentCanvasMutationSession(original))
        XCTAssertTrue(controller.isCurrentCanvasMutationSession(replacement))
        XCTAssertEqual(first.values.last, .init(generation: pendingGeneration, fileID: original.fileID, pending: false))
        XCTAssertEqual(first.values.count, 2)
        XCTAssertEqual(second.values, first.values)

        controller.resetFileLoadState()
        XCTAssertNil(controller.captureCanvasMutationSession())
        XCTAssertFalse(controller.isCurrentCanvasMutationSession(replacement))
        XCTAssertEqual(first.values.last, .init(generation: controller.currentLoadGeneration, fileID: nil, pending: false))
        XCTAssertGreaterThan(controller.currentLoadGeneration, replacement.loadGeneration)
        XCTAssertEqual(first.values.count, 3)
        XCTAssertEqual(second.values, first.values)
    }

    @MainActor
    func testRealSessionInstallPublishesAssignedTokenWithoutReloadingTheScene() async throws {
        let fixture = try await CanvasControllerFixture.open()
        addTeardownBlock { await fixture.close() }
        let controller = fixture.core.documentSyncController
        let original = try XCTUnwrap(controller.captureCanvasMutationSession())
        let scene = try await fixture.scene()
        let loadCount = try await fixture.integer("window.loadCalls")
        var first: [CanvasMutationSession?] = []
        var second: [CanvasMutationSession?] = []
        let one = controller.canvasMutationSessionChanges.sink {
            MainActor.assumeIsolated { first.append(controller.captureCanvasMutationSession()) }
        }
        let two = controller.canvasMutationSessionChanges.sink {
            MainActor.assumeIsolated { second.append(controller.captureCanvasMutationSession()) }
        }
        defer { one.cancel(); two.cancel() }
        let uuid = UUID()
        fixture.state.installExternalSaveSession(uuid)
        let current = try XCTUnwrap(controller.captureCanvasMutationSession())
        XCTAssertEqual(current.fileID, original.fileID)
        XCTAssertEqual(current.loadGeneration, original.loadGeneration)
        XCTAssertEqual(current.saveSession, uuid)
        XCTAssertFalse(controller.isCurrentCanvasMutationSession(original))
        XCTAssertEqual(first, [current])
        XCTAssertEqual(second, [current])
        fixture.state.installExternalSaveSession(uuid)
        XCTAssertEqual(first, [current])
        XCTAssertEqual(second, [current])
        XCTAssertEqual(controller.captureCanvasMutationSession(), current)
        let afterScene = try await fixture.scene()
        let afterLoadCount = try await fixture.integer("window.loadCalls")
        XCTAssertEqual(afterScene, scene)
        XCTAssertEqual(afterLoadCount, loadCount)
    }

    @MainActor
    func testRealMediaHelperKeepsLifecycleFlushAndRecoveryWaitingForItsScene() async throws {
        let fixture = try await CanvasControllerFixture.open()
        addTeardownBlock { await fixture.close() }
        let core = try XCTUnwrap(fixture.core)
        let controller = core.documentSyncController
        let owner = try XCTUnwrap(controller.captureCanvasMutationSession())
        let mutation = Task {
            try await core.loadImageToExcalidrawCanvas(imageData: Data([1, 2, 3]), type: "image/png")?.elementCount
        }
        fixture.cancelOnClose(mutation)
        try await fixture.waitForJavaScript("window.imagePaused === true")
        XCTAssertTrue(controller.hasPendingDirtySnapshot, "The real helper must own dirty work before its bridge await")

        let earlyFlush = expectation(description: "Flush must not finish while the helper is held")
        let earlyRecovery = expectation(description: "Recovery must not finish while the helper is held")
        earlyFlush.isInverted = true
        earlyRecovery.isInverted = true
        let flushStarted = expectation(description: "Lifecycle flush invoked")
        let recoveryStarted = expectation(description: "Recovery export invoked")
        var checkingEarlyCompletion = true
        let flush = Task {
            flushStarted.fulfill()
            await controller.flushPendingDirtySnapshot(reason: "sceneBackground", force: true, expectedFileID: owner.fileID)
            if checkingEarlyCompletion { earlyFlush.fulfill() }
        }
        let recovery = Task {
            recoveryStarted.fulfill()
            let file = try await controller.currentCanvasFileForRecoveryExport()
            if checkingEarlyCompletion { earlyRecovery.fulfill() }
            return file
        }
        fixture.cancelOnClose(flush)
        fixture.cancelOnClose(recovery)
        await fulfillment(of: [flushStarted, recoveryStarted], timeout: 2)
        await fulfillment(of: [earlyFlush, earlyRecovery], timeout: 0.1)
        checkingEarlyCompletion = false
        let readsWhileHeld = try await fixture.integer("window.snapshotReads")
        XCTAssertEqual(readsWhileHeld, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.original)
        try await fixture.evaluate("window.releaseImage()")
        let elementCount = try await boundedSaveTestValue(mutation)
        XCTAssertEqual(elementCount, 1)
        try await boundedSaveTestValue(flush, timeout: .seconds(8))
        let recovered = try await boundedSaveTestValue(recovery, timeout: .seconds(8))
        XCTAssertEqual(recovered.id, owner.fileID)
        XCTAssertTrue(controller.isCurrentCanvasMutationSession(owner))
        let expected = try await fixture.scene()
        let persisted = try fixture.persistedScene(from: expected)
        XCTAssertEqual(try fixture.scene(from: Data(contentsOf: fixture.url)), persisted)
        XCTAssertEqual(try fixture.scene(from: XCTUnwrap(recovered.content)), expected)
        XCTAssertEqual(try fixture.scene(from: XCTUnwrap(fixture.model.file?.content)), persisted)
        XCTAssertFalse(controller.hasPendingDirtySnapshot)
        let pending = await ExternalFileSaveCoordinator.shared.pendingContent(at: fixture.url, session: owner.saveSession)
        XCTAssertNil(pending)
    }
}

private struct ObservedLoad: Equatable {
    let generation: UInt64
    let fileID: String?
    let pending: Bool
}

/// Synchronous subscribers reenter the real lock-taking public getters.
private final class LoadObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [ObservedLoad] = []
    private var subscription: AnyCancellable?
    var values: [ObservedLoad] { lock.withLock { observations } }

    init(_ controller: ExcalidrawDocumentSyncController) {
        subscription = controller.canvasMutationSessionChanges.sink { [weak self] in
            let value = ObservedLoad(generation: controller.currentLoadGeneration,
                                     fileID: controller.currentLoadedFileID,
                                     pending: controller.hasPendingFileLoad)
            self?.lock.withLock { self?.observations.append(value) }
        }
    }
}

@MainActor
private final class CanvasControllerModel: ObservableObject {
    @Published var file: ExcalidrawFile?
    @Published var loadingState: ExcalidrawCanvasView.LoadingState = .idle
}

@MainActor
private struct ControllerTestCanvas: View {
    @ObservedObject var model: CanvasControllerModel
    var body: some View {
        ExcalidrawCanvasView(file: $model.file, loadingState: $model.loadingState, onError: { _ in })
    }
}

@MainActor
private final class CanvasControllerFixture {
    private struct SetupFailure: Error, CustomStringConvertible {
        let stage: String
        let underlying: Error

        var description: String {
            "Canvas controller fixture setup failed during \(stage): \(String(reflecting: type(of: underlying))): \(underlying)"
        }
    }

    // Keep a vetoed fixture and its live owner available until the test process exits.
    private static var retainedFixtures: [CanvasControllerFixture] = []
    let state = FileState()
    let model = CanvasControllerModel()
    let toolState = ToolState()
    let exportState = ExportState()
    let preferences = CanvasPreferencesState()
    let lockedContentState = LockedContentStateStore()
    let directory: URL
    let url: URL
    let original = Data(##"{"type":"excalidraw","version":2,"source":"native-test","elements":[],"files":{},"appState":{"gridSize":10,"viewBackgroundColor":"#ffffff"}}"##.utf8)
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
    private(set) var core: ExcalidrawCore!
    private var taskCleanup: [@MainActor () async -> Void] = []

    private init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("synthetic.excalidraw")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: url)
    }

    static func open() async throws -> CanvasControllerFixture {
        let fixture = try CanvasControllerFixture()
        var stage = "prepare open-in-place access"
        do {
            // Match the actual open-from-URL entry point, including its UIDocument writer.
            try await fixture.state.prepareOpenInPlaceAccess(to: fixture.url)
            stage = "accept the synthetic document as active"
            let accepted = await fixture.state.requestActiveFileChange(.temporaryFile(fixture.url))
            guard accepted else { throw SaveTestWaitError.timedOut }
            stage = "capture the real document writer"
            let target = try XCTUnwrap(fixture.state.capturedCanvasSaveTarget(for: .temporaryFile(fixture.url)))
            XCTAssertTrue(target.isOpenInPlace)
            _ = try XCTUnwrap(target.externalWriter)
            let view = ControllerTestCanvas(model: fixture.model)
                .environmentObject(fixture.state).environmentObject(fixture.toolState)
                .environmentObject(fixture.exportState).environmentObject(fixture.preferences)
                .environmentObject(fixture.lockedContentState)
                .environmentObject(AppPreference())
            fixture.window.rootViewController = UIHostingController(rootView: view)
            fixture.window.isHidden = false
            stage = "attach the canvas core and parent"
            try await fixture.waitUntil { fixture.toolState.excalidrawWebCoordinator?.parent != nil }
            fixture.core = try XCTUnwrap(fixture.toolState.excalidrawWebCoordinator)
            stage = "drain the queued initial refresh"
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            // Keep actual Core/parent/controller wiring; provide a deterministic, nonpersistent web page.
            fixture.core.webView.navigationDelegate = nil
            fixture.core.webView.stopLoading()
            stage = "load the inline web fixture"
            fixture.core.webView.loadHTMLString(Self.html, baseURL: nil)
            try await fixture.waitForJavaScript("window.fixtureReady === true")
            fixture.core.hasInjectIndexedDBData = true
            fixture.core.isNavigating = false
            fixture.core.isDocumentLoaded = true
            stage = "decode the synthetic document"
            fixture.model.file = try ExcalidrawFile(data: fixture.original, id: fixture.url.absoluteString)
            stage = "confirm the loaded canvas session and temporary row"
            try await fixture.waitUntil {
                fixture.core.documentSyncController.captureCanvasMutationSession() != nil
                    && fixture.state.temporaryFiles.contains(fixture.url)
            }
            stage = "record the external read baseline"
            let session = try await fixture.state.recordExternalFileRead(fixture.original, at: fixture.url)
            fixture.state.installExternalSaveSession(session)
            return fixture
        } catch {
            let failure = SetupFailure(stage: stage, underlying: error)
            await fixture.close()
            throw failure
        }
    }

    func cancelOnClose<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>) {
        taskCleanup.append {
            task.cancel()
            _ = try? await boundedSaveTestValue(task)
        }
    }

    func close() async {
        // Release held bridge work before cancelling/resetting its native owner.
        if core != nil {
            try? await evaluate("window.releaseLoad?.(); window.releaseImage?.();")
        }
        for cleanup in taskCleanup { await cleanup() }
        let session = state.externalSaveSessionID
        var stage = "flush the original canvas owner"
        do {
            if let core {
                let flush = Task { await core.documentSyncController.flushPendingDirtySnapshot(reason: "testCleanup", force: true) }
                try await boundedSaveTestValue(flush, timeout: .seconds(8))
            }
            stage = "accept navigation close with the core and writer attached"
            let close = Task { await state.requestActiveFileChange(nil) }
            let accepted = try await boundedSaveTestValue(close, timeout: .seconds(8))
            guard accepted else {
                Self.retainedFixtures.append(self)
                XCTFail("Synthetic navigation close was vetoed; live owner and data retained at \(directory.path)")
                return
            }
            let pending = await ExternalFileSaveCoordinator.shared.pendingContent(at: url, session: session)
            guard pending == nil, core?.documentSyncController.hasPendingDirtySnapshot != true else {
                Self.retainedFixtures.append(self)
                XCTFail("Synthetic save remains pending after close; owner and data retained at \(directory.path)")
                return
            }
        } catch {
            Self.retainedFixtures.append(self)
            XCTFail("Synthetic cleanup failed during \(stage): \(error); owner and data retained at \(directory.path)")
            return
        }
        core?.documentSyncController.resetFileLoadState()
        core?.webView.stopLoading()
        core?.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        core?.parent = nil
        state.currentGroupPublisherCancellables.forEach { $0.cancel() }
        state.excalidrawWebCoordinator = nil
        toolState.excalidrawWebCoordinator = nil
        exportState.excalidrawWebCoordinator = nil
        preferences.coordinator = nil
        window.isHidden = true
        window.rootViewController = nil
        await ExternalFileSaveCoordinator.shared.releaseSession(session)
        state.temporaryFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        do {
            // Access ownership closes UIDocument after its existing five-second grace period.
            try await waitUntil {
                !NSFileCoordinator.filePresenters.contains {
                    $0.presentedItemURL?.standardizedFileURL == self.url.standardizedFileURL
                }
            }
            let pending = await ExternalFileSaveCoordinator.shared.pendingContent(at: url, session: session)
            guard pending == nil else {
                XCTFail("Synthetic failed save retained for diagnosis at \(directory.path)")
                return
            }
            try FileManager.default.removeItem(at: directory)
        } catch {
            XCTFail("Synthetic document cleanup did not finish: \(error)")
        }
    }

    func evaluate(_ script: String) async throws {
        let task = Task { _ = try await core.webView.evaluateJavaScript(script) }
        try await boundedSaveTestValue(task)
    }

    func integer(_ script: String) async throws -> Int {
        let task = Task { try await core.webView.evaluateJavaScript(script) as? Int }
        let value = try await boundedSaveTestValue(task)
        return try XCTUnwrap(value)
    }

    func scene() async throws -> NSDictionary {
        let task = Task { try await core.webView.evaluateJavaScript("JSON.stringify(window.scene)") as? String }
        let value = try await boundedSaveTestValue(task)
        let json = try XCTUnwrap(value)
        return try scene(from: Data(json.utf8))
    }

    func scene(from data: Data) throws -> NSDictionary {
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return ["elements": try XCTUnwrap(document["elements"]),
                "appState": try XCTUnwrap(document["appState"]),
                "files": try XCTUnwrap(document["files"])] as NSDictionary
    }

    func persistedScene(from liveScene: NSDictionary) throws -> NSDictionary {
        var expected = try XCTUnwrap(liveScene as? [String: Any])
        var appState = try XCTUnwrap(expected["appState"] as? [String: Any])
        appState["name"] = "synthetic"
        expected["appState"] = appState
        return expected as NSDictionary
    }

    func waitForJavaScript(_ condition: String) async throws {
        try await waitUntil {
            guard !self.core.webView.isLoading else { return false }
            let task = Task { (try? await self.core.webView.evaluateJavaScript(condition)) as? Bool }
            return try await boundedSaveTestValue(task) == true
        }
    }

    private func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while true {
            if try await condition() { return }
            guard ContinuousClock.now < deadline else { throw SaveTestWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let html = #"""
    <!doctype html><script>
    window.scene = {elements: [], appState: {gridSize: 10, viewBackgroundColor: "#ffffff"}, files: {}};
    window.loadCalls = 0; window.snapshotReads = 0;
    const helper = {
      _api: {getAppState: () => window.scene.appState},
      async loadFileBuffer(buffer, id, requestId) {
        window.loadCalls++;
        if (window.holdNextLoad) {
          window.holdNextLoad = false;
          window.loadPaused = true;
          await new Promise(resolve => window.releaseLoad = resolve);
          window.loadPaused = false;
        }
        window.scene = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer)));
        helper.currentFileId = id;
        return {fileId: id, requestId, elementCount: window.scene.elements.length, durationMs: 0};
      },
      requestCurrentFileSaveStream: () => ({supported: false}),
      getCurrentFileSnapshot() { window.snapshotReads++; return {...window.scene, revision: 1}; },
      async loadImageBuffer(buffer, type) {
        window.imagePaused = true;
        await new Promise(resolve => window.releaseImage = resolve);
        window.imagePaused = false;
        window.scene.elements.push({type:"rectangle", id:"completed-image-operation", x:1, y:2,
          width:3, height:4, strokeColor:"#000000", backgroundColor:"transparent", fillStyle:"solid",
          strokeWidth:1, strokeStyle:"solid", roughness:0, opacity:100, angle:0,
          seed:1, version:1, versionNonce:1, isDeleted:false, groupIds:[]});
        return {elementCount: window.scene.elements.length, durationMs: 0};
      }
    };
    window.excalidrawZHelper = new Proxy(helper, {get: (target, key) => target[key] ?? (() => null)});
    window.fixtureReady = true;
    </script>
    """#
}
#endif
