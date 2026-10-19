import Foundation

/// Classifies one directory while the caller holds access to its linked root.
/// Read failures and cancellation never return a partial directory list.
struct ExternalFolderDirectoryScanner: Sendable {
    struct Metadata: Sendable {
        let isDirectory: Bool?
        let isHidden: Bool?
        let isSymbolicLink: Bool?
    }

    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey,
    ]

    private let contents: @Sendable (URL) throws -> [URL]
    private let metadata: @Sendable (URL) throws -> Metadata

    init(
        contents: @escaping @Sendable (URL) throws -> [URL],
        metadata: @escaping @Sendable (URL) throws -> Metadata = { try Self.readMetadata(at: $0) }
    ) {
        self.contents = contents
        self.metadata = metadata
    }

    /// Keeps visible packages eligible, as in the existing folder tree.
    /// Symbolic links are not directories to traverse outside the linked root.
    func visibleSubdirectories(at url: URL) throws -> [URL] {
        try Task.checkCancellation()
        let entries = try contents(url)
        try Task.checkCancellation()

        var directories: [URL] = []
        for entry in entries {
            try Task.checkCancellation()
            let values = try metadata(entry)
            try Task.checkCancellation()

            guard let isDirectory = values.isDirectory else {
                throw Self.unavailableMetadata(at: entry)
            }
            guard isDirectory else { continue }
            guard let isHidden = values.isHidden,
                  let isSymbolicLink = values.isSymbolicLink else {
                throw Self.unavailableMetadata(at: entry)
            }
            if !isHidden && !isSymbolicLink {
                directories.append(entry)
            }
        }

        try Task.checkCancellation()
        return directories
    }

    private static func readMetadata(at url: URL) throws -> Metadata {
        let values = try url.resourceValues(forKeys: resourceKeys)
        return Metadata(
            isDirectory: values.isDirectory,
            isHidden: values.isHidden,
            isSymbolicLink: values.isSymbolicLink
        )
    }

    private static func unavailableMetadata(at url: URL) -> CocoaError {
        CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
    }
}
