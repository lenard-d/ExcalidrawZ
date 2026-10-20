import Foundation
import UniformTypeIdentifiers
extension UTType { static var excalidrawFile: UTType { .json } }

struct ProbeFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ProbeFailure(description: message) }
}

actor PreparationGate {
    private var entered = false
    private var released = false
    func pause() async throws {
        entered = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !released {
            guard ContinuousClock.now < deadline else { throw ProbeFailure(description: "Preparation timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered {
            guard ContinuousClock.now < deadline else { throw ProbeFailure(description: "Preparation did not start") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func release() { released = true }
}

actor WriterGate {
    private var entered = false
    private var released = false
    func pauseIgnoringCancellation() async throws {
        entered = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !released {
            guard ContinuousClock.now < deadline else { throw ProbeFailure(description: "Writer timed out") }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.001) { continuation.resume() }
            }
        }
    }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered {
            guard ContinuousClock.now < deadline else { throw ProbeFailure(description: "Writer did not start") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func release() { released = true }
}

actor ExcalidrawViewportStateStore {
    static let shared = ExcalidrawViewportStateStore()
    var gate: PreparationGate?
    func hold(_ gate: PreparationGate?) { self.gate = gate }
    func appStateBySeparatingViewport(_ state: ExcalidrawCore.JSONValue, fileID: String) async throws -> ExcalidrawCore.JSONValue {
        try await gate?.pause()
        return state
    }
}

struct Logger {
    func debug(_ message: String) {}
    func error(_ message: String) {}
}
enum CanvasType { case normal, collaboration }
struct Document { let id = "drawing"; var content: Data }
final class Parent {
    let fileState: FileState
    var file: Document?
    var type: CanvasType = .normal
    var savingType: UTType? = nil
    init(_ state: FileState, content: Data) { fileState = state; file = Document(content: content) }
}
final class ExcalidrawCore {
    struct InvalidJavaScriptResult: Error {}
    // INSERT JSON VALUE
    struct StateChangedMetadata {
        let appStateDirty: Bool?
        let appState: JSONValue?
        let currentFileId: String?
    }
    let logger = Logger()
    var parent: Parent?
    var errors: [Error] = []
    lazy var publishError: (Error) -> Void = { [weak self] error in self?.errors.append(error) }
    let documentSyncController = FixtureSyncController()
    func getCurrentAppState() async throws -> JSONValue { .object(["gridSize": .number(20)]) }
}
final class FixtureSyncController { var currentLoadedFileID: String? = "drawing" }
protocol ExcalidrawDocumentSnapshotCoordinatorDelegate: AnyObject { var snapshotCoordinatorCore: ExcalidrawCore? { get } }
final class Delegate: ExcalidrawDocumentSnapshotCoordinatorDelegate {
    let snapshotCoordinatorCore: ExcalidrawCore?
    init(_ core: ExcalidrawCore) { snapshotCoordinatorCore = core }
}

final class FileState {
    enum ActiveFile {
        case localFile(URL), temporaryFile(URL), library
        var id: String { "drawing" }
        var name: String { "synthetic" }
        var usesLocalViewportSidecar: Bool { true }
    }
    struct CapturedCanvasSaveTarget {
        enum Kind {
            case localFile, collaborationFile
            var usesLocalViewportSidecar: Bool { true }
            var nativeFileName: String? { nil }
        }
        let kind = Kind.localFile
        let url: URL
        let session: UUID
        let saves: ExternalFileSaveCoordinator
        let writer: ExternalFileSaveCoordinator.Writer
    }
    let url: URL
    let session = UUID()
    let coordinator = CanvasSaveCoordinator()
    let saves = ExternalFileSaveCoordinator()
    var currentActiveFile: ActiveFile?
    var reportedErrors: [Error] = []
    var writer: ExternalFileSaveCoordinator.Writer = ExternalFileWriter.write
    init(_ url: URL) { self.url = url; currentActiveFile = .localFile(url) }
    var owner: CanvasMutationSession { .init(fileID: "drawing", saveSession: session, loadGeneration: 1) }
    func captureCanvasSave(expectedFileID: String?, intent: CanvasSaveCoverage = .fullScene) -> CanvasSaveCapture? {
        guard expectedFileID == "drawing" else { return nil }
        return coordinator.capture(owner: owner, intent: intent)
    }
    func target() -> CapturedCanvasSaveTarget { .init(url: url, session: session, saves: saves, writer: writer) }
    func reportExternalSaveFailure(_ error: Error, at url: URL) { reportedErrors.append(error) }
    func updateAppStateOnlyForCurrentFile(expectedFileID: String?, content: Data, capture: CanvasSaveCapture?) async throws {
        try await saves.saveAppState(from: content, to: url, session: session, capture: capture, writer: writer)
    }
    static func saveCapturedAppStateOnlyUpdate(_ target: CapturedCanvasSaveTarget, content: Data, capture: CanvasSaveCapture?) async throws {
        try await target.saves.saveAppState(from: content, to: target.url, session: target.session, capture: capture, writer: target.writer)
    }
}

@main
struct AppStateCancellationProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func run() async throws {
        for route in CommitRoute.allCases {
            for failure in WriteFailure.allCases { try await failedWrite(route, failure: failure) }
            try await cancelledStartedWrite(route)
            try await cancelledStartedWriteFailure(route)
            try await supersededStartedWrite(route)
            try await supersededPreparation(route)
            try await cancelledPreparation(route)
        }
    }

    enum CommitRoute: String, CaseIterable { case current, captured }
    enum WriteFailure: CaseIterable, Equatable { case cocoa, cancellation, conflict }

    @MainActor final class Fixture {
        let directory: URL
        let url: URL
        let original = Data(#"{"elements":[{"id":"kept"}],"appState":{"gridSize":10}}"#.utf8)
        let state: FileState
        let core: ExcalidrawCore
        let delegate: Delegate
        let saver = ExcalidrawDocumentAppStateSnapshotSaver()

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("synthetic.excalidraw")
            try original.write(to: url)
            state = FileState(url)
            _ = await state.saves.recordRead(try ExternalFileVersion(content: original, at: url), at: url, session: state.session)
            core = ExcalidrawCore()
            core.parent = Parent(state, content: original)
            delegate = Delegate(core)
            saver.attach(delegate: delegate)
        }

        func cleanup() {
            saver.reset()
            try? FileManager.default.removeItem(at: directory)
        }

        func record(_ grid: Double) {
            let metadata = ExcalidrawCore.StateChangedMetadata(appStateDirty: true, appState: .object(["gridSize": .number(grid)]), currentFileId: "drawing")
            let capture = state.captureCanvasSave(expectedFileID: "drawing", intent: .appState)
            saver.recordLatestAppState(metadata, capture: capture)
            saver.schedule(metadata, currentFileID: "drawing", savingType: nil)
        }

        func flush(_ route: CommitRoute) async {
            switch route {
                case .current: await saver.flush(reason: "controlled")
                case .captured:
                    await saver.flushToCapturedTarget(reason: "controlled", expectedFileID: "drawing", target: state.target(), capturedContent: original)
            }
        }

        func requirePending(_ message: String) throws {
            try require(saver.hasPendingSave && state.coordinator.hasPendingSave, message)
        }

        func requireSaved(_ grid: Int) throws {
            let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            try require((document?["appState"] as? [String: Any])?["gridSize"] as? Int == grid, "Wrong saved metadata")
            try require((document?["elements"] as? [[String: Any]])?.first?["id"] as? String == "kept", "Metadata save lost drawing content")
            try require(!saver.hasPendingSave && !state.coordinator.hasPendingSave, "Real latest receipt was not acknowledged")
        }

        func requireVisibleError(_ matches: (Error) -> Bool) throws {
            try require(core.errors.count == 1 && state.reportedErrors.count == 1, "Real save failure was hidden or duplicated")
            try require(matches(core.errors[0]) && matches(state.reportedErrors[0]), "Wrong error reached caller reporting")
        }
    }

    @MainActor static func supersededPreparation(_ route: CommitRoute) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        fixture.record(20)
        let gate = PreparationGate()
        await ExcalidrawViewportStateStore.shared.hold(gate)
        let old = Task { await fixture.flush(route) }
        defer { old.cancel(); Task { await gate.release() } }
        try await gate.waitUntilEntered()
        fixture.record(30)
        await gate.release()
        await old.value
        await ExcalidrawViewportStateStore.shared.hold(nil)
        try require(fixture.core.errors.isEmpty && fixture.state.reportedErrors.isEmpty, "Superseded \(route.rawValue) app-state preparation publishes a false save error")
        try fixture.requirePending("Supersession cleared the latest pending state")
        try require(try Data(contentsOf: fixture.url) == fixture.original, "Superseded preparation wrote old state")
        await fixture.flush(route)
        try fixture.requireSaved(30)
        print("PASS superseded \(route.rawValue): no error, latest dirty retained, exact latest retry durable")
    }

    @MainActor static func cancelledPreparation(_ route: CommitRoute) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        fixture.record(20)
        let gate = PreparationGate()
        await ExcalidrawViewportStateStore.shared.hold(gate)
        let task = Task { await fixture.flush(route) }
        defer { task.cancel(); Task { await gate.release() } }
        try await gate.waitUntilEntered()
        task.cancel()
        await task.value
        await ExcalidrawViewportStateStore.shared.hold(nil)
        try require(fixture.core.errors.isEmpty && fixture.state.reportedErrors.isEmpty, "Cancelled preparation publishes a false save error")
        try fixture.requirePending("Cancellation cleared dirty state")
        try require(try Data(contentsOf: fixture.url) == fixture.original, "Cancelled preparation wrote bytes")
        let pending = await fixture.state.saves.pendingContent(at: fixture.url, session: fixture.state.session)
        try require(pending == nil, "Cancelled preparation reached writer admission")
        fixture.record(30)
        await fixture.flush(route)
        try fixture.requireSaved(30)
        print("PASS cancelled \(route.rawValue): no error or receipt, dirty retained, latest retry durable")
    }

    @MainActor static func failedWrite(_ route: CommitRoute, failure: WriteFailure) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        await ExcalidrawViewportStateStore.shared.hold(nil)
        fixture.record(20)
        switch failure {
            case .cocoa: fixture.state.writer = { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
            case .cancellation: fixture.state.writer = { _, _, _ in throw CancellationError() }
            case .conflict: try Data(#"{"elements":[{"id":"external"}],"appState":{"gridSize":10}}"#.utf8).write(to: fixture.url)
        }
        let before = try Data(contentsOf: fixture.url)
        await fixture.flush(route)
        switch failure {
            case .cocoa:
                try fixture.requireVisibleError { ($0 as? ExternalFileSaveFailure)?.cause is CocoaError }
            case .cancellation:
                try fixture.requireVisibleError { $0 is CancellationError }
            case .conflict:
                try fixture.requireVisibleError { ($0 as? ExternalFileSaveFailure)?.cause is ExternalFileConflict }
        }
        try fixture.requirePending("Real failure cleared dirty state")
        try require(try Data(contentsOf: fixture.url) == before, "Failed write changed disk")
        let pending = await fixture.state.saves.pendingContent(at: fixture.url, session: fixture.state.session)
        guard let pending else { throw ProbeFailure(description: "Failed writer has no pending bytes") }
        let pendingDocument = try JSONSerialization.jsonObject(with: pending) as? [String: Any]
        try require((pendingDocument?["appState"] as? [String: Any])?["gridSize"] as? Int == 20, "Writer did not retain failed metadata bytes")
        if failure != .conflict {
            fixture.state.writer = ExternalFileWriter.write
            fixture.record(30)
            await fixture.flush(route)
            try fixture.requireSaved(30)
        }
        print("PASS failed \(route.rawValue) \(failure): error visible, disk protected, pending retained")
    }

    @MainActor static func cancelledStartedWrite(_ route: CommitRoute) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        await ExcalidrawViewportStateStore.shared.hold(nil)
        fixture.record(20)
        let gate = WriterGate()
        fixture.state.writer = { content, url, baseline in
            try await gate.pauseIgnoringCancellation()
            return try await Task.detached { try await ExternalFileWriter.write(content, to: url, replacing: baseline) }.value
        }
        let task = Task { await fixture.flush(route) }
        defer { task.cancel(); Task { await gate.release() } }
        try await gate.waitUntilEntered()
        task.cancel()
        try fixture.requirePending("Started writer got an early receipt")
        await gate.release()
        await task.value
        try fixture.requireSaved(20)
        let pending = await fixture.state.saves.pendingContent(at: fixture.url, session: fixture.state.session)
        try require(pending == nil && fixture.core.errors.isEmpty && fixture.state.reportedErrors.isEmpty, "Real successful writer result was replaced by caller cancellation")
        print("PASS cancelled started \(route.rawValue) writer: true success and receipt preserved")
    }

    @MainActor static func cancelledStartedWriteFailure(_ route: CommitRoute) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        await ExcalidrawViewportStateStore.shared.hold(nil)
        fixture.record(20)
        let gate = WriterGate()
        fixture.state.writer = { _, _, _ in
            try await gate.pauseIgnoringCancellation()
            throw CocoaError(.fileWriteNoPermission)
        }
        let task = Task { await fixture.flush(route) }
        defer { task.cancel(); Task { await gate.release() } }
        try await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        await task.value
        try fixture.requireVisibleError { ($0 as? ExternalFileSaveFailure)?.cause is CocoaError }
        try fixture.requirePending("Cancelled caller hid a real write failure")
        try require(try Data(contentsOf: fixture.url) == fixture.original, "Failed cancelled write changed disk")
        fixture.state.writer = ExternalFileWriter.write
        fixture.record(30)
        await fixture.flush(route)
        try fixture.requireSaved(30)
        print("PASS cancelled started \(route.rawValue) writer failure: genuine error visible, latest retry durable")
    }

    @MainActor static func supersededStartedWrite(_ route: CommitRoute) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        await ExcalidrawViewportStateStore.shared.hold(nil)
        fixture.record(20)
        let gate = WriterGate()
        fixture.state.writer = { content, url, baseline in
            try await gate.pauseIgnoringCancellation()
            return try await ExternalFileWriter.write(content, to: url, replacing: baseline)
        }
        let old = Task { await fixture.flush(route) }
        defer { old.cancel(); Task { await gate.release() } }
        try await gate.waitUntilEntered()
        fixture.record(30)
        await gate.release()
        await old.value
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any]
        try require((document?["appState"] as? [String: Any])?["gridSize"] as? Int == 20, "Started writer lost its true result")
        try fixture.requirePending("Old true receipt cleared newer pending edits")
        try require(fixture.core.errors.isEmpty && fixture.state.reportedErrors.isEmpty, "Superseded successful writer published an error")
        fixture.state.writer = ExternalFileWriter.write
        await fixture.flush(route)
        try fixture.requireSaved(30)
        print("PASS superseded started \(route.rawValue) writer: true old result, latest pending retained and retried")
    }

}
