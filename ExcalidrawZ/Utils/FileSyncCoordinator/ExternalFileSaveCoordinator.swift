import Foundation

/// A read or confirmed write, including the file identity when the provider supplies one.
struct ExternalFileVersion: @unchecked Sendable {
    let content: Data
    let identity: NSObject?

    init(content: Data, at url: URL) throws {
        self.content = content
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        identity = try freshURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier as? NSObject
    }

    /// Reads bytes and identity in the same coordinated access, not from a cached notification.
    @Sendable static func read(at url: URL) async throws -> ExternalFileVersion {
        try await FileCoordinator.shared.coordinatedRead(url: url) { target in
            try ExternalFileVersion(content: Data(contentsOf: target), at: target)
        }
    }

    func validateReplacement(of current: ExternalFileVersion) throws {
        guard content == current.content,
              identity == current.identity else {
            throw ExternalFileConflict()
        }
    }
}

struct ExternalFileConflict: LocalizedError {
    var errorDescription: String? {
        "The file changed outside this window. Export a copy to keep both versions."
    }
}

struct ExternalFileSaveFailure: LocalizedError {

    let url: URL
    let cause: Error

    var errorDescription: String? {
        "Could not save \"\(url.lastPathComponent)\". \(cause.localizedDescription) "
        + "Your edits remain in this window. Export a copy before you close the app."
    }
}

/// Keeps failed edits in memory and orders writes to each captured target.
/// This is not crash recovery. Only a successful writer advances the baseline.
actor ExternalFileSaveCoordinator {
    typealias Writer = @Sendable (Data, URL, ExternalFileVersion) async throws -> ExternalFileVersion
    typealias Reader = @Sendable (URL) async throws -> ExternalFileVersion
    enum ReloadWriteWait { case selected, finished }

    static let shared = ExternalFileSaveCoordinator()

    private struct Target: Hashable {
        let url: URL
        let session: UUID?
    }

    private struct Pending {
        let generation: UInt64
        let content: Data
        let capture: CanvasSaveCapture?
        let coverage: CanvasSaveCoverage
    }

    private var generation: UInt64 = 0
    private var baselines: [Target: ExternalFileVersion] = [:]
    private var pending: [Target: Pending] = [:]
    private var writes: [URL: Task<Void, Never>] = [:]
    private var writeGenerations: [URL: UInt64] = [:]
    private var activeWrites: Set<Target> = []
    private var releasedSessions: Set<UUID> = []

    /// Refuses a reload that would replace unsaved edits or an active write.
    @discardableResult
    func recordRead(_ version: ExternalFileVersion, at url: URL, session: UUID? = nil) -> Bool {
        let key = Target(url: url.standardizedFileURL, session: session)
        guard pending[key] == nil, writes[key.url] == nil else { return false }
        baselines[key] = version
        return true
    }

    /// A receipt can advance while the coordinated read waits. Retry only that unsettled read.
    func prepareReload(
        at url: URL, session: UUID?, hasPendingCanvasEdits: Bool,
        observeWriteWait: (@Sendable (ReloadWriteWait) async throws -> Void)? = nil,
        reader: Reader = ExternalFileVersion.read
    ) async throws -> (content: Data, session: UUID)? {
        let key = Target(url: url.standardizedFileURL, session: session)
        for _ in 0..<3 {
            try Task.checkCancellation()
            let awaitedGeneration = writeGenerations[key.url]
            let awaitedWrite = writes[key.url]
            try await observeWriteWait?(.selected)
            await awaitedWrite?.value
            try await observeWriteWait?(.finished)
            guard awaitedGeneration == writeGenerations[key.url],
                  !activeWrites.contains(where: { $0.url == key.url }) else { continue }
            let writeGeneration = writeGenerations[key.url]
            let baseline = baselines[key]
            let version = try await reader(key.url)
            try Task.checkCancellation()
            guard writeGeneration == writeGenerations[key.url],
                  !activeWrites.contains(where: { $0.url == key.url }),
                  baseline?.content == baselines[key]?.content,
                  baseline?.identity == baselines[key]?.identity else { continue }
            if let baseline = baselines[key],
               baseline.content == version.content,
               baseline.identity == version.identity {
                return nil
            }
            guard !hasPendingCanvasEdits, pending[key] == nil else { throw ExternalFileConflict() }
            let replacement = UUID()
            baselines[Target(url: key.url, session: replacement)] = version
            return (version.content, replacement)
        }
        // Leave live edits and the confirmed baseline intact until a stable notification can be read.
        throw CancellationError()
    }

    /// Clean sessions can release large drawing baselines. Failed and active saves stay retained.
    func releaseSession(_ session: UUID) {
        releasedSessions.insert(session)
        for key in Array(baselines.keys) where key.session == session {
            guard pending[key] == nil, !activeWrites.contains(key) else { continue }
            baselines[key] = nil
        }
        if !baselines.keys.contains(where: { $0.session == session }) {
            releasedSessions.remove(session)
        }
    }

    func pendingContent(at url: URL, session: UUID? = nil) -> Data? {
        pending[Target(url: url.standardizedFileURL, session: session)]?.content
    }

    /// A separate mutation keeps its original expected version while the editor can still receive edits.
    func forkSession(at url: URL, from source: UUID?, to session: UUID) throws {
        let key = Target(url: url.standardizedFileURL, session: source)
        guard pending[key] == nil, writes[key.url] == nil, let baseline = baselines[key] else {
            throw ExternalFileSaveFailure(url: key.url, cause: CocoaError(.fileWriteUnknown))
        }
        baselines[Target(url: key.url, session: session)] = baseline
    }

    func save(_ content: Data, to url: URL, session: UUID? = nil, capture: CanvasSaveCapture? = nil, writer: @escaping Writer) async throws {
        try await enqueue(content, to: url, session: session, capture: capture, coverage: .fullScene, writer: writer)
    }

    private func enqueue(_ content: Data, to url: URL, session: UUID?, capture: CanvasSaveCapture?, coverage: CanvasSaveCoverage, writer: @escaping Writer) async throws {
        let key = Target(url: url.standardizedFileURL, session: session)
        generation &+= 1
        let request = Pending(generation: generation, content: content, capture: capture, coverage: coverage)
        if let capture {
            guard capture.owner.saveSession == session else { throw CancellationError() }
            try capture.withAdmission { pending[key] = request }
        } else {
            pending[key] = request
        }
        let previousWrite = writes[key.url]
        let operation = Task {
            await previousWrite?.value
            try Task.checkCancellation()
            try await self.write(request, to: key, writer: writer)
        }
        writes[key.url] = Task { _ = try? await operation.value }
        writeGenerations[key.url] = request.generation
        defer {
            if writeGenerations[key.url] == request.generation {
                writes[key.url] = nil
                writeGenerations[key.url] = nil
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExternalFileSaveFailure(url: key.url, cause: error)
        }
    }

    func retry(at url: URL, session: UUID? = nil, writer: @escaping Writer) async throws {
        let key = Target(url: url.standardizedFileURL, session: session)
        guard let request = pending[key] else { return }
        try await enqueue(request.content, to: url, session: session, capture: request.capture, coverage: request.coverage, writer: writer)
    }

    /// Metadata saves merge into the latest queued drawing, or the confirmed drawing.
    func saveAppState(from content: Data, to url: URL, session: UUID? = nil, capture: CanvasSaveCapture? = nil, writer: @escaping Writer) async throws {
        let key = Target(url: url.standardizedFileURL, session: session)
        guard let source = pending[key]?.content ?? baselines[key]?.content,
              var document = try JSONSerialization.jsonObject(with: source) as? [String: Any],
              let update = try JSONSerialization.jsonObject(with: content) as? [String: Any],
              let appState = update["appState"] else {
            throw ExternalFileSaveFailure(url: key.url, cause: CocoaError(.fileReadUnknown))
        }
        document["appState"] = ExcalidrawDocumentAppStatePersistence.appStateObjectByMergingAppStateOnlyPersistentFields(
            from: appState, into: document["appState"] ?? [:], nativeFileName: nil
        )
        try await enqueue(JSONSerialization.data(withJSONObject: document), to: key.url, session: session, capture: capture, coverage: .appState, writer: writer)
    }

    private func write(_ request: Pending, to key: Target, writer: Writer) async throws {
        guard pending[key]?.generation == request.generation else {
            throw CancellationError()
        }
        guard let baseline = baselines[key] else {
            throw CocoaError(.fileReadUnknown)
        }
        activeWrites.insert(key)
        defer {
            activeWrites.remove(key)
            if let session = key.session, releasedSessions.contains(session) {
                releaseSession(session)
            }
        }
        let saved: ExternalFileVersion
        if let capture = request.capture {
            try capture.withAdmission {}
            var receipt: ExternalFileVersion?
            try await capture.performSave(coverage: request.coverage) {
                receipt = try await writer(request.content, key.url, baseline)
            }
            guard let receipt else { throw CocoaError(.fileWriteUnknown) }
            saved = receipt
        } else {
            saved = try await writer(request.content, key.url, baseline)
        }
        baselines[key] = saved
        if pending[key]?.generation == request.generation {
            pending[key] = nil
        }
    }
}

enum ExternalFileWriter {
    /// The comparison and replacement share one coordinated write operation.
    @Sendable static func write(_ content: Data, to url: URL, replacing baseline: ExternalFileVersion) async throws -> ExternalFileVersion {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var coordinationError: NSError?
                var result: Result<ExternalFileVersion, Error>?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                    result = Result {
                        let current = try ExternalFileVersion(content: Data(contentsOf: target), at: target)
                        try baseline.validateReplacement(of: current)
                        try content.write(to: target, options: .atomic)
                        return try ExternalFileVersion(content: content, at: target)
                    }
                }
                if let coordinationError {
                    continuation.resume(throwing: coordinationError)
                } else {
                    continuation.resume(with: result ?? .failure(CocoaError(.fileWriteUnknown)))
                }
            }
        }
    }
}
