import Foundation
#if os(iOS)
import UIKit
#endif
import Logging

/// Owns the platform-specific access lifetime for documents opened in place.
/// FileState supplies the URLs still owned by workspaces and editor sessions;
/// this store handles document sessions, security-scope leases, and cleanup.
final class OpenInPlaceAccessStore {
    private let logger = Logger(label: "OpenInPlaceAccessStore")
    private var closeTasks: [URL: Task<Void, Never>] = [:]
    private var retainedURLs: Set<URL> = []

#if os(iOS)
    private var sessions: [URL: OpenInPlaceDocumentSession] = [:]
#else
    private var leases: [URL: SecurityScopedResourceLease] = [:]
#endif

    @MainActor
    func prepareAccess(to url: URL) async throws {
        let key = url.standardizedFileURL
        retainAccess(to: key)
#if os(iOS)
        guard sessions[key] == nil else { return }

        do {
            sessions[key] = try await OpenInPlaceDocumentSession.open(url: url)
        } catch {
            retainedURLs.remove(key)
            throw error
        }
        logger.debug("Opened external document session: \(url.lastPathComponent)")
#else
        guard leases[key] == nil else { return }
        guard let lease = SecurityScopedResourceLease(url: url) else {
            retainedURLs.remove(key)
            logger.warning("Failed to retain open-in-place access: \(url.lastPathComponent)")
            throw AppError.urlError(.startAccessingSecurityScopedResourceFailed)
        }
        leases[key] = lease
        logger.debug("Retained open-in-place access: \(url.lastPathComponent)")
#endif
    }

    @MainActor
    func retainAccess(to url: URL) {
        let key = url.standardizedFileURL
        retainedURLs.insert(key)
        if let closeTask = closeTasks.removeValue(forKey: key) {
            closeTask.cancel()
            logger.debug("Cancelled open-in-place access release: \(key.lastPathComponent)")
        }
    }

    @MainActor
    func content(for url: URL) -> Data? {
#if os(iOS)
        sessions[url.standardizedFileURL]?.content
#else
        nil
#endif
    }

    @MainActor
    func writer(for url: URL) -> ExternalFileSaveCoordinator.Writer? {
#if os(iOS)
        guard let session = sessions[url.standardizedFileURL] else { return nil }
        return { content, target, baseline in
            guard await session.url.standardizedFileURL == target.standardizedFileURL else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try await session.save(content: content, replacing: baseline)
            return try ExternalFileVersion(content: content, at: target)
        }
#else
        return ExternalFileWriter.write
#endif
    }

    @MainActor
    func save(_ content: Data, to url: URL, replacing baseline: ExternalFileVersion) async throws -> Bool {
#if os(iOS)
        guard let session = sessions[url.standardizedFileURL] else { return false }
        try await session.save(content: content, replacing: baseline)
        return true
#else
        return false
#endif
    }

    @MainActor
    func releaseAccess(to url: URL) {
        let key = url.standardizedFileURL
#if os(iOS)
        retainedURLs.remove(key)
        guard sessions[key] != nil, closeTasks[key] == nil else { return }
        logger.debug("Scheduled external document session close: \(key.lastPathComponent)")
        closeTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }

            self.closeTasks[key] = nil
            guard !self.retainedURLs.contains(key),
                  let session = self.sessions[key] else {
                return
            }
            guard await session.close() else {
                self.logger.error("External document close failed; retaining session: \(key.lastPathComponent)")
                return
            }
            self.sessions[key] = nil
            self.logger.debug("Closed external document session: \(key.lastPathComponent)")
        }
#else
        retainedURLs.remove(key)
        guard leases[key] != nil, closeTasks[key] == nil else { return }
        logger.debug("Scheduled open-in-place access release: \(key.lastPathComponent)")
        closeTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }

            self.closeTasks[key] = nil
            guard !self.retainedURLs.contains(key) else { return }
            self.leases[key] = nil
            self.logger.debug("Released open-in-place access: \(key.lastPathComponent)")
        }
#endif
    }
}

#if os(iOS)

/// Keeps an external document open for the lifetime of a Temporary workspace.
/// `UIDocument` owns the security-scoped URL and acts as its file presenter.
@MainActor
final class OpenInPlaceDocumentSession {
    var url: URL { document.fileURL }

    private let document: OpenInPlaceDataDocument

    private init(url: URL, document: OpenInPlaceDataDocument) {
        self.document = document
    }

    static func open(url: URL) async throws -> OpenInPlaceDocumentSession {
        let document = OpenInPlaceDataDocument(fileURL: url)
        let didOpen = await withCheckedContinuation { continuation in
            document.open { success in
                continuation.resume(returning: success)
            }
        }

        guard didOpen else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url])
        }

        let session = OpenInPlaceDocumentSession(url: url, document: document)
        return session
    }

    var content: Data {
        document.content
    }

    func save(content: Data, replacing baseline: ExternalFileVersion) async throws {
        try Task.checkCancellation()
        guard !document.documentState.contains(.inConflict) else {
            throw CocoaError(.fileWriteFileExists)
        }
        document.replaceContent(with: content, replacing: baseline)
        let didSave = await withCheckedContinuation { continuation in
            document.save(to: url, for: .forOverwriting) { success in
                continuation.resume(returning: success)
            }
        }
        guard didSave else {
            throw document.lastWriteError ?? CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        document.acknowledgeSave()
    }

    func close() async -> Bool {
        guard !document.documentState.contains(.closed) else { return true }
        guard !document.hasUnsavedChanges else { return false }
        let didClose = await withCheckedContinuation { continuation in
            document.close { success in
                continuation.resume(returning: success)
            }
        }
        return didClose
    }
}

private final class OpenInPlaceDataDocument: UIDocument {
    private let contentLock = NSLock()
    private var storedContent = Data()
    private var baseline: ExternalFileVersion?
    private var writeError: Error?
    private var pendingContent = false

    var content: Data { contentLock.withLock { storedContent } }
    var lastWriteError: Error? { contentLock.withLock { writeError } }

    func replaceContent(with content: Data, replacing baseline: ExternalFileVersion) {
        contentLock.withLock {
            storedContent = content
            pendingContent = true
            self.baseline = baseline
            writeError = nil
        }
        updateChangeCount(.done)
    }

    func acknowledgeSave() {
        contentLock.withLock { pendingContent = false }
    }

    override func load(fromContents
 contents: Any, ofType typeName: String?) throws {
        guard !contentLock.withLock({ pendingContent }) else {
            throw CocoaError(.fileWriteFileExists)
        }
        if let data = contents as? Data {
            contentLock.withLock { storedContent = data }
        } else if let fileWrapper = contents as? FileWrapper,
                  let data = fileWrapper.regularFileContents {
            contentLock.withLock { storedContent = data }
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    override func contents(forType typeName: String) throws -> Any {
        content
    }

    override func writeContents(_ contents: Any, to url: URL, for saveOperation: UIDocument.SaveOperation, originalContentsURL: URL?) throws {
        do {
            guard let baseline = contentLock.withLock({ baseline }),
                  let originalContentsURL else {
                throw CocoaError(.fileWriteUnknown)
            }
            let current = try ExternalFileVersion(content: Data(contentsOf: originalContentsURL), at: originalContentsURL)
            try baseline.validateReplacement(of: current)
            // UIDocument owns coordination and safe replacement. Do not nest a coordinator here.
            try super.writeContents(contents, to: url, for: saveOperation, originalContentsURL: originalContentsURL)
        } catch {
            contentLock.withLock { writeError = error }
            throw error
        }
    }
}
#else
private final class SecurityScopedResourceLease {
    let url: URL

    init?(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        self.url = url
    }

    deinit {
        url.stopAccessingSecurityScopedResource()
    }
}
#endif
