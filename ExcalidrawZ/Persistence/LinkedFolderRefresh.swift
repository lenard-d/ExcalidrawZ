import Foundation

/// Serializes blocking provider work without holding a managed object context.
/// Cancellation takes effect after an in-progress provider call returns.
actor LinkedFolderRefresh {
    static let shared = LinkedFolderRefresh()

    struct FolderState: Equatable, Sendable {
        let identifier: URL
        let parentIdentifier: URL?
        let url: URL?
        let filePath: String?
        let bookmarkData: Data?
    }

    struct Request: Sendable {
        let bookmarkData: Data
        let rootURL: URL?
        let folderURL: URL?
        let isRoot: Bool
        let recursively: Bool
        let revision: [FolderState]
    }

    struct ResolvedBookmark: Sendable {
        let url: URL
        let isStale: Bool
    }

    struct Provider: Sendable {
        let resolve: @Sendable (Data) throws -> ResolvedBookmark
        let startAccess: @Sendable (URL) throws -> Void
        let stopAccess: @Sendable (URL) -> Void
        let bookmark: @Sendable (URL) throws -> Data
        /// Returns classified, visible child directories. An incomplete read throws.
        let directoryContents: @Sendable (URL) throws -> [URL]
    }

    struct Directory: Sendable {
        let url: URL
        let children: [URL]
    }

    struct Plan: Sendable {
        let request: Request
        let rootURL: URL
        let bookmarkData: Data
        let directories: [Directory]
        let newFolderBookmarks: [URL: Data]

        /// Call on the context queue, with the revision read on that same queue.
        @discardableResult
        func apply(
            ifCurrent revision: [FolderState]?,
            _ action: () throws -> Void
        ) rethrows -> Bool {
            guard revision == request.revision else { return false }
            try action()
            return true
        }
    }

    struct DirectoryNotReady: Error {}
    struct InvalidLocation: Error {}

    func read(_ request: Request, provider: Provider) throws -> Plan {
        try Task.checkCancellation()
        let resolved = try provider.resolve(request.bookmarkData)
        try provider.startAccess(resolved.url)
        defer { provider.stopAccess(resolved.url) }
        try Task.checkCancellation()

        let rootURL = resolved.url.standardizedFileURL
        let bookmarkData: Data
        if resolved.isStale || request.rootURL != rootURL {
            bookmarkData = try provider.bookmark(rootURL)
        } else {
            bookmarkData = request.bookmarkData
        }

        let folderURL: URL
        if request.isRoot {
            folderURL = rootURL
        } else if let oldRoot = request.rootURL,
                  let target = request.folderURL?.rebased(from: oldRoot, to: rootURL) {
            folderURL = target
        } else {
            throw InvalidLocation()
        }

        let knownURLs = Set(request.revision.compactMap { state -> URL? in
            guard let url = state.url ?? state.filePath.map({ URL(fileURLWithPath: $0) }) else {
                return nil
            }
            return request.rootURL.flatMap { url.rebased(from: $0, to: rootURL) }
                ?? url.standardizedFileURL
        })
        var pending = [folderURL]
        var visited: Set<URL> = []
        var directories: [Directory] = []
        var newFolderBookmarks: [URL: Data] = [:]

        while let url = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(url).inserted else { continue }
            let children = try provider.directoryContents(url).map(\.standardizedFileURL)
            try Task.checkCancellation()
            for child in children where !knownURLs.contains(child) {
                try Task.checkCancellation()
                newFolderBookmarks[child] = try provider.bookmark(child)
            }
            directories.append(Directory(url: url, children: children))
            if request.recursively {
                pending.append(contentsOf: children)
            }
        }
        try Task.checkCancellation()
        return Plan(
            request: request,
            rootURL: rootURL,
            bookmarkData: bookmarkData,
            directories: directories,
            newFolderBookmarks: newFolderBookmarks
        )
    }
}
