import Foundation
import XCTest
@testable import ExcalidrawZ

final class ExternalFolderDirectoryScannerTests: XCTestCase {
    private enum ReadFailure: Error {
        case unavailable
    }

    func testListsVisibleDirectoriesAndPackagesWithoutFollowingLinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let visible = root.appendingPathComponent("Notes", isDirectory: true)
        let package = root.appendingPathComponent("Archive.app", isDirectory: true)
        for url in [visible, package, root.appendingPathComponent(".hidden")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("Drawing.excalidraw"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Cycle"),
            withDestinationURL: root
        )
        let scanner = ExternalFolderDirectoryScanner(contents: { try Self.readDirectory(at: $0) })

        let directories = try scanner.visibleSubdirectories(at: root)

        XCTAssertEqual(Set(directories.map(\.lastPathComponent)), ["Notes", "Archive.app"])
    }

    func testSuccessfulEmptyDirectoryRemainsEmpty() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = ExternalFolderDirectoryScanner(contents: { try Self.readDirectory(at: $0) })

        XCTAssertEqual(try scanner.visibleSubdirectories(at: root), [])
    }

    func testDirectoryReadFailureIsNotAnEmptyResult() {
        let scanner = ExternalFolderDirectoryScanner(contents: { _ in
            throw ReadFailure.unavailable
        })

        XCTAssertThrowsError(try scanner.visibleSubdirectories(at: URL(fileURLWithPath: "/unused"))) {
            XCTAssertTrue($0 is ReadFailure)
        }
    }

    func testMetadataFailureAfterValidEntryDoesNotReturnPartialResult() {
        let first = URL(fileURLWithPath: "/unused/First")
        let second = URL(fileURLWithPath: "/unused/Unavailable")
        let scanner = ExternalFolderDirectoryScanner(
            contents: { _ in [first, second] },
            metadata: { url in
                if url == second { throw ReadFailure.unavailable }
                return .init(isDirectory: true, isHidden: false, isSymbolicLink: false)
            }
        )

        XCTAssertThrowsError(try scanner.visibleSubdirectories(at: first.deletingLastPathComponent())) {
            XCTAssertTrue($0 is ReadFailure)
        }
    }

    func testVanishedListedDirectoryFailsClassification() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Previously visible", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let scanner = ExternalFolderDirectoryScanner(contents: { url in
            let entries = try Self.readDirectory(at: url)
            try FileManager.default.removeItem(at: child)
            // A provider can return entries without cached resource metadata.
            return entries.map { URL(fileURLWithPath: $0.path) }
        })

        XCTAssertThrowsError(try scanner.visibleSubdirectories(at: root)) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadNoSuchFile)
        }
    }

    func testMissingRequiredMetadataIsNotClassifiedAsAbsent() {
        let child = URL(fileURLWithPath: "/unused/Child")
        let incomplete: [ExternalFolderDirectoryScanner.Metadata] = [
            .init(isDirectory: nil, isHidden: false, isSymbolicLink: false),
            .init(isDirectory: true, isHidden: nil, isSymbolicLink: false),
            .init(isDirectory: true, isHidden: false, isSymbolicLink: nil),
        ]
        for values in incomplete {
            let scanner = ExternalFolderDirectoryScanner(
                contents: { _ in [child] },
                metadata: { _ in values }
            )

            XCTAssertThrowsError(try scanner.visibleSubdirectories(at: child.deletingLastPathComponent())) {
                XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadUnknown)
            }
        }
    }

    func testHiddenAndSymbolicLinkDirectoriesAreNotTraversed() throws {
        let hidden = URL(fileURLWithPath: "/unused/HiddenByMetadata")
        let link = URL(fileURLWithPath: "/unused/ProviderLink")
        let scanner = ExternalFolderDirectoryScanner(
            contents: { _ in [hidden, link] },
            metadata: { url in
                .init(isDirectory: true, isHidden: url == hidden, isSymbolicLink: url == link)
            }
        )

        XCTAssertEqual(try scanner.visibleSubdirectories(at: hidden.deletingLastPathComponent()), [])
    }

    func testCancellationBeforeScanDoesNotStartProviderRead() async {
        let gate = AsyncStream<Void>.makeStream()
        let scanner = ExternalFolderDirectoryScanner(contents: { _ in
            XCTFail("A cancelled scan must not start a provider read")
            return []
        })
        let task = Task.detached {
            for await _ in gate.stream { break }
            return try scanner.visibleSubdirectories(at: URL(fileURLWithPath: "/unused"))
        }
        task.cancel()
        gate.continuation.finish()

        await assertCancelled(task)
    }

    func testCancellationDuringProviderReadRejectsReturnedEntries() async {
        let entered = expectation(description: "Provider read entered")
        let gate = DispatchSemaphore(value: 0)
        let scanner = ExternalFolderDirectoryScanner(
            contents: { _ in
                entered.fulfill()
                gate.wait()
                return [URL(fileURLWithPath: "/unused/Child")]
            },
            metadata: { _ in
                XCTFail("Cancellation must stop classification after the provider returns")
                return .init(isDirectory: true, isHidden: false, isSymbolicLink: false)
            }
        )
        let task = Task.detached {
            try scanner.visibleSubdirectories(at: URL(fileURLWithPath: "/unused"))
        }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        gate.signal()

        await assertCancelled(task)
    }

    func testCancellationDuringMetadataReadStopsBeforeNextEntry() async {
        let entered = expectation(description: "Metadata read entered")
        let gate = DispatchSemaphore(value: 0)
        let first = URL(fileURLWithPath: "/unused/First")
        let second = URL(fileURLWithPath: "/unused/Second")
        let scanner = ExternalFolderDirectoryScanner(
            contents: { _ in [first, second] },
            metadata: { url in
                if url == first {
                    entered.fulfill()
                    gate.wait()
                } else {
                    XCTFail("Cancellation must stop before another metadata read")
                }
                return .init(isDirectory: true, isHidden: false, isSymbolicLink: false)
            }
        )
        let task = Task.detached {
            try scanner.visibleSubdirectories(at: first.deletingLastPathComponent())
        }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        gate.signal()

        await assertCancelled(task)
    }

    func testRefreshPlansOnlyVisibleDirectoriesUsingProductionScanner() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let visible = root.appendingPathComponent("Notes", isDirectory: true)
        let nested = visible.appendingPathComponent("Exercises", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".hidden/Private"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: visible.appendingPathComponent("Cycle"),
            withDestinationURL: root
        )
        let scanner = ExternalFolderDirectoryScanner(contents: { try Self.readDirectory(at: $0) })
        let provider = Self.refreshProvider(root: root, scanner: scanner)

        let plan = try await LinkedFolderRefresh().read(Self.refreshRequest(root: root), provider: provider)

        XCTAssertEqual(
            Set(plan.directories.map { $0.url.standardizedFileURL.path }),
            Set([root, visible, nested].map { $0.standardizedFileURL.path })
        )
        XCTAssertEqual(Set(plan.newFolderBookmarks.keys.map(\.lastPathComponent)), ["Notes", "Exercises"])
    }

    func testRefreshFailsWhenScannerCannotClassifyRetainedChild() async {
        let root = URL(fileURLWithPath: "/unused")
        let child = root.appendingPathComponent("Retained")
        let scanner = ExternalFolderDirectoryScanner(
            contents: { _ in [child] },
            metadata: { _ in throw ReadFailure.unavailable }
        )
        let request = LinkedFolderRefresh.Request(
            bookmarkData: Data(), rootURL: root, folderURL: root,
            isRoot: true, recursively: true,
            revision: [
                .init(identifier: root, parentIdentifier: nil, url: root, filePath: root.path, bookmarkData: Data()),
                .init(identifier: child, parentIdentifier: root, url: child, filePath: child.path, bookmarkData: Data()),
            ]
        )

        do {
            _ = try await LinkedFolderRefresh().read(request, provider: Self.refreshProvider(root: root, scanner: scanner))
            XCTFail("Metadata failure for a retained child must not produce a refresh plan")
        } catch {
            XCTAssertTrue(error is ReadFailure)
        }
    }

    private static func refreshRequest(root: URL) -> LinkedFolderRefresh.Request {
        .init(
            bookmarkData: Data(), rootURL: root, folderURL: root,
            isRoot: true, recursively: true,
            revision: [.init(identifier: root, parentIdentifier: nil, url: root, filePath: root.path, bookmarkData: Data())]
        )
    }

    private static func refreshProvider(
        root: URL,
        scanner: ExternalFolderDirectoryScanner
    ) -> LinkedFolderRefresh.Provider {
        .init(
            resolve: { _ in .init(url: root, isStale: false) },
            startAccess: { _ in },
            stopAccess: { _ in },
            bookmark: { _ in Data() },
            directoryContents: { try scanner.visibleSubdirectories(at: $0) }
        )
    }

    private func assertCancelled(_ task: Task<[URL], Error>) async {
        switch await task.result {
        case .success:
            XCTFail("Cancelled scan returned a directory list")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func readDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(ExternalFolderDirectoryScanner.resourceKeys)
        )
    }
}
