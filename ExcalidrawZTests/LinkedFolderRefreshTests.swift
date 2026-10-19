import XCTest
import CoreData
@testable import ExcalidrawZ

@MainActor
final class LinkedFolderRefreshTests: XCTestCase {
    func testCompleteReadReconcilesOnceAndKeepsCheckpoints() async throws {
        let fixture = try Fixture()
        let added = fixture.rootURL.appendingPathComponent("added")
        let nested = added.appendingPathComponent("nested")
        let probe = Probe(tree: [fixture.rootURL: [added], added: [nested], nested: []])
        let savesBeforeRefresh = fixture.context.successfulSaves

        try await fixture.refresh(provider: probe.provider(root: fixture.rootURL))

        XCTAssertEqual(try fixture.folderURLs(), [fixture.rootURL, added, nested])
        XCTAssertEqual(fixture.context.successfulSaves - savesBeforeRefresh, 1)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(fixture.checkpoint.content, Data([7, 8]))
        XCTAssertEqual(probe.calls.last, "stop")
    }

    func testNestedReadFailurePreservesEntirePriorTreeAndCanRecover() async throws {
        let fixture = try Fixture()
        let original = try fixture.folderURLs()
        let added = fixture.rootURL.appendingPathComponent("added")
        let probe = Probe(tree: [fixture.rootURL: [added]], failingURL: added)
        do {
            try await fixture.refresh(provider: probe.provider(root: fixture.rootURL))
            XCTFail("An incomplete tree must not be applied")
        } catch Probe.Failure.read {}

        XCTAssertEqual(try fixture.folderURLs(), original)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(probe.calls.last, "stop")
        try await fixture.refresh(provider: Probe(tree: [fixture.rootURL: []]).provider(root: fixture.rootURL))
        XCTAssertEqual(try fixture.folderURLs(), [fixture.rootURL])
        XCTAssertEqual(fixture.checkpoint.content, Data([7, 8]))
    }

    func testBookmarkFailureDoesNotPartiallyRemoveExistingChildren() async throws {
        let fixture = try Fixture()
        let original = try fixture.folderURLs()
        let added = fixture.rootURL.appendingPathComponent("added")
        let probe = Probe(tree: [fixture.rootURL: [added]], failBookmark: true)
        do {
            try await fixture.refresh(provider: probe.provider(root: fixture.rootURL))
            XCTFail("Bookmark failure must abort the read")
        } catch Probe.Failure.bookmark {}
        XCTAssertEqual(try fixture.folderURLs(), original)
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(probe.calls.last, "stop")
    }

    func testBlockedProviderLeavesMainActorResponsiveAndCancellationPreservesTree() async throws {
        let fixture = try Fixture()
        let original = try fixture.folderURLs()
        let probe = Probe(tree: [fixture.rootURL: []], block: true)
        defer { probe.release.signal() }
        let refresh = Task { try await fixture.refresh(provider: probe.provider(root: fixture.rootURL)) }
        await fulfillment(of: [probe.entered], timeout: 2)
        // Reaching this main-actor line while the provider waits is the heartbeat.
        XCTAssertFalse(fixture.context.hasChanges)
        refresh.cancel()
        probe.release.signal()
        do {
            try await refresh.value
            XCTFail("The cancelled result must not be applied")
        } catch is CancellationError {}
        XCTAssertEqual(try fixture.folderURLs(), original)
        XCTAssertEqual(probe.calls, ["resolve", "start", "list", "stop"])
    }

    func testNewerRefreshWinsOverBlockedOlderRefresh() async throws {
        let fixture = try Fixture()
        let old = Probe(tree: [fixture.rootURL: []], block: true)
        defer { old.release.signal() }
        let older = Task { try await fixture.refresh(provider: old.provider(root: fixture.rootURL)) }
        await fulfillment(of: [old.entered], timeout: 2)
        let added = fixture.rootURL.appendingPathComponent("newer")
        let recent = Probe(tree: [fixture.rootURL: [added], added: []])
        let newerStarted = expectation(description: "Newer refresh requested")
        let newer = Task {
            newerStarted.fulfill()
            try await fixture.refresh(provider: recent.provider(root: fixture.rootURL))
        }
        await fulfillment(of: [newerStarted], timeout: 2)
        XCTAssertTrue(recent.calls.isEmpty, "A second provider read must wait for the first to return")
        old.release.signal()
        try await newer.value
        try await older.value
        XCTAssertEqual(try fixture.folderURLs(), [fixture.rootURL, added])
        XCTAssertEqual(old.calls.last, "stop")
        XCTAssertEqual(recent.calls.last, "stop")
    }

    func testReplacingFirstRootStillRefreshesSecondRootAndCompletesCaller() async throws {
        let first = try Fixture()
        let second = try Fixture()
        let blocked = Probe(tree: [first.rootURL: []], block: true)
        defer { blocked.release.signal() }
        let secondProbe = Probe(tree: [second.rootURL: []])
        var callerCompleted = false
        let batch = Task {
            try await first.refresh(provider: blocked.provider(root: first.rootURL))
            try await second.refresh(provider: secondProbe.provider(root: second.rootURL))
            callerCompleted = true
        }
        await fulfillment(of: [blocked.entered], timeout: 2)
        let replacementStarted = expectation(description: "Replacement requested")
        let replacement = Task {
            replacementStarted.fulfill()
            try await first.refresh(provider: Probe(tree: [first.rootURL: []]).provider(root: first.rootURL))
        }
        await fulfillment(of: [replacementStarted], timeout: 2)
        blocked.release.signal()
        try await replacement.value
        try await batch.value
        XCTAssertTrue(callerCompleted)
        XCTAssertEqual(try second.folderURLs(), [second.rootURL])
        XCTAssertEqual(secondProbe.calls.last, "stop")
    }

    func testCancellingBatchCallerDoesNotStartSecondRoot() async throws {
        let first = try Fixture()
        let second = try Fixture()
        let blocked = Probe(tree: [first.rootURL: []], block: true)
        defer { blocked.release.signal() }
        let secondProbe = Probe(tree: [second.rootURL: []])
        let batch = Task {
            try await first.refresh(provider: blocked.provider(root: first.rootURL))
            try await second.refresh(provider: secondProbe.provider(root: second.rootURL))
        }
        await fulfillment(of: [blocked.entered], timeout: 2)
        batch.cancel()
        blocked.release.signal()
        do {
            try await batch.value
            XCTFail("Caller cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertTrue(secondProbe.calls.isEmpty)
        XCTAssertFalse(first.child.isDeleted)
        XCTAssertFalse(second.child.isDeleted)
    }

    func testReplacedReadFailureDoesNotStopOtherRootsOrChangeCachedData() async throws {
        let first = try Fixture()
        let second = try Fixture()
        let originalFirstURLs = try first.folderURLs()
        let blocked = Probe(tree: [:], failingURL: first.rootURL, block: true)
        defer { blocked.release.signal() }
        let batch = Task {
            try await first.refresh(provider: blocked.provider(root: first.rootURL))
            try await second.refresh(provider: Probe(tree: [second.rootURL: []]).provider(root: second.rootURL))
        }
        await fulfillment(of: [blocked.entered], timeout: 2)
        let replacementStarted = expectation(description: "Failing replacement requested")
        let replacement = Task {
            replacementStarted.fulfill()
            try await first.refresh(provider: Probe(tree: [:], failAccess: true).provider(root: first.rootURL))
        }
        await fulfillment(of: [replacementStarted], timeout: 2)
        blocked.release.signal()
        do {
            try await replacement.value
            XCTFail("An active replacement's access error must propagate")
        } catch Probe.Failure.access {}
        try await batch.value
        XCTAssertEqual(try first.folderURLs(), originalFirstURLs)
        XCTAssertEqual(first.checkpoint.content, Data([7, 8]))
        XCTAssertEqual(try second.folderURLs(), [second.rootURL])
        XCTAssertEqual(blocked.calls.last, "stop")
    }

    func testCallerCancellationTakesPrecedenceOverProviderReadError() async throws {
        let fixture = try Fixture()
        let original = try fixture.folderURLs()
        let blocked = Probe(tree: [:], failingURL: fixture.rootURL, block: true)
        defer { blocked.release.signal() }
        let refresh = Task { try await fixture.refresh(provider: blocked.provider(root: fixture.rootURL)) }
        await fulfillment(of: [blocked.entered], timeout: 2)
        refresh.cancel()
        blocked.release.signal()
        do {
            try await refresh.value
            XCTFail("Caller cancellation must propagate even when the provider throws")
        } catch is CancellationError {}
        XCTAssertEqual(try fixture.folderURLs(), original)
        XCTAssertEqual(blocked.calls.last, "stop")
    }

    func testSavedChildInsertionDuringReadRejectsStaleTree() async throws {
        let fixture = try Fixture()
        let probe = Probe(tree: [fixture.rootURL: []], block: true)
        defer { probe.release.signal() }
        let refresh = Task { try await fixture.refresh(provider: probe.provider(root: fixture.rootURL)) }
        await fulfillment(of: [probe.entered], timeout: 2)
        let inserted = LocalFolder(context: fixture.context)
        inserted.url = fixture.rootURL.appendingPathComponent("inserted")
        inserted.bookmarkData = Data([3])
        inserted.parent = fixture.root
        try fixture.context.save()
        probe.release.signal()
        try await refresh.value
        XCTAssertEqual(try fixture.folderURLs(), [fixture.rootURL, fixture.child.url!, inserted.url!])
        XCTAssertEqual(fixture.root.bookmarkData, Data([1]))
    }

    func testCancelledQueuedRefreshDoesNotOpenAnotherScope() async throws {
        let first = try Fixture()
        let second = try Fixture()
        let blocked = Probe(tree: [first.rootURL: []], block: true)
        defer { blocked.release.signal() }
        let active = Task { try await first.refresh(provider: blocked.provider(root: first.rootURL)) }
        await fulfillment(of: [blocked.entered], timeout: 2)
        let queuedProbe = Probe(tree: [second.rootURL: []])
        let queuedStarted = expectation(description: "Refresh queued")
        let queued = Task {
            queuedStarted.fulfill()
            try await second.refresh(provider: queuedProbe.provider(root: second.rootURL))
        }
        await fulfillment(of: [queuedStarted], timeout: 2)
        queued.cancel()
        blocked.release.signal()
        try await active.value
        do {
            try await queued.value
            XCTFail("A cancelled queued refresh must not run")
        } catch is CancellationError {}
        XCTAssertTrue(queuedProbe.calls.isEmpty)
        XCTAssertFalse(second.child.isDeleted)
    }

    func testRelinkWhileReadingRejectsStaleTree() async throws {
        let fixture = try Fixture()
        let originalChild = fixture.child.url
        let probe = Probe(tree: [fixture.rootURL: []], block: true)
        defer { probe.release.signal() }
        let refresh = Task { try await fixture.refresh(provider: probe.provider(root: fixture.rootURL)) }
        await fulfillment(of: [probe.entered], timeout: 2)
        fixture.root.bookmarkData = Data([99])
        try fixture.context.save()
        probe.release.signal()
        try await refresh.value
        XCTAssertEqual(fixture.root.bookmarkData, Data([99]))
        XCTAssertEqual(fixture.child.url, originalChild)
        XCTAssertFalse(fixture.child.isDeleted)
    }

    func testDeleteWhileReadingDoesNotRecreateFolder() async throws {
        let fixture = try Fixture()
        let rootID = fixture.root.objectID
        let probe = Probe(tree: [fixture.rootURL: []], block: true)
        defer { probe.release.signal() }
        let refresh = Task { try await fixture.refresh(provider: probe.provider(root: fixture.rootURL)) }
        await fulfillment(of: [probe.entered], timeout: 2)
        fixture.context.delete(fixture.root)
        try fixture.context.save()
        probe.release.signal()
        try await refresh.value
        let request = NSFetchRequest<LocalFolder>(entityName: "LocalFolder")
        XCTAssertFalse(try fixture.context.fetch(request).contains { $0.objectID == rootID })
    }

    func testCallerEditsDuringReadRemainUnsavedAndUntouched() async throws {
        let fixture = try Fixture()
        let probe = Probe(tree: [fixture.rootURL: []], block: true)
        defer { probe.release.signal() }
        let refresh = Task { try await fixture.refresh(provider: probe.provider(root: fixture.rootURL)) }
        await fulfillment(of: [probe.entered], timeout: 2)
        fixture.checkpoint.content = Data([42])
        probe.release.signal()
        try await refresh.value
        XCTAssertEqual(fixture.checkpoint.content, Data([42]))
        XCTAssertTrue(fixture.context.hasChanges)
        XCTAssertFalse(fixture.child.isDeleted)
        fixture.context.rollback()
        XCTAssertEqual(fixture.checkpoint.content, Data([7, 8]))
    }

    func testPendingCallerEditsSkipProviderWithoutSaving() async throws {
        let fixture = try Fixture()
        fixture.checkpoint.content = Data([42])
        let probe = Probe(tree: [:])
        try await fixture.refresh(provider: probe.provider(root: fixture.rootURL))
        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertTrue(fixture.context.hasChanges)
        fixture.context.rollback()
        XCTAssertEqual(fixture.checkpoint.content, Data([7, 8]))
    }

    func testSaveFailureRollsBackOnlyRefreshAndAllowsRetry() async throws {
        let fixture = try Fixture()
        let original = try fixture.folderURLs()
        let probe = Probe(tree: [fixture.rootURL: []])
        fixture.context.failNextSave = true
        do {
            try await fixture.refresh(provider: probe.provider(root: fixture.rootURL))
            XCTFail("The injected save failure must be returned")
        } catch TestContext.Failure.save {}
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(try fixture.folderURLs(), original)
        try await fixture.refresh(provider: probe.provider(root: fixture.rootURL))
        XCTAssertEqual(try fixture.folderURLs(), [fixture.rootURL])
    }

    func testMovedBookmarkRebasesFoldersAndCheckpointURLsAfterCompleteRead() async throws {
        let fixture = try Fixture()
        let rootID = fixture.root.objectID
        let oldRoot = fixture.rootURL
        let oldCheckpointURL = try XCTUnwrap(fixture.checkpoint.url)
        let moved = fixture.rootURL.appendingPathExtension("moved")
        let child = moved.appendingPathComponent("old")
        let newCheckpointURL = child.appendingPathComponent("drawing.excalidraw")
        ExcalidrawFile.localFileURLIDMapping[oldCheckpointURL] = "synthetic-drawing"
        defer {
            ExcalidrawFile.localFileURLIDMapping.removeValue(forKey: oldCheckpointURL)
            ExcalidrawFile.localFileURLIDMapping.removeValue(forKey: newCheckpointURL)
        }
        let notified = expectation(description: "Successful move announced once")
        notified.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(
            forName: .localFolderResolvedLocationDidChange, object: rootID, queue: nil
        ) { notification in
            XCTAssertEqual(notification.object as? NSManagedObjectID, rootID)
            XCTAssertEqual(notification.userInfo?[LocalFolderLocationChangeUserInfoKey.oldURL] as? URL, oldRoot)
            XCTAssertEqual(notification.userInfo?[LocalFolderLocationChangeUserInfoKey.newURL] as? URL, moved)
            XCTAssertTrue(Thread.isMainThread)
            notified.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let probe = Probe(tree: [moved: [child], child: []])
        try await fixture.refresh(provider: probe.provider(root: moved))
        XCTAssertEqual(fixture.root.url, moved)
        XCTAssertEqual(fixture.child.url, child)
        XCTAssertEqual(fixture.checkpoint.url, child.appendingPathComponent("drawing.excalidraw"))
        XCTAssertEqual(fixture.root.bookmarkData, Data(moved.path.utf8))
        XCTAssertNil(ExcalidrawFile.localFileURLIDMapping[oldCheckpointURL])
        XCTAssertEqual(ExcalidrawFile.localFileURLIDMapping[newCheckpointURL], "synthetic-drawing")
        await fulfillment(of: [notified], timeout: 2)
    }

    func testChildTargetRefreshRebasesAfterRootMoveAndPreservesSibling() async throws {
        let fixture = try Fixture()
        let sibling = LocalFolder(context: fixture.context)
        sibling.url = fixture.rootURL.appendingPathComponent("sibling")
        sibling.bookmarkData = Data([3])
        sibling.parent = fixture.root
        try fixture.context.save()
        let moved = fixture.rootURL.appendingPathExtension("moved")
        let movedChild = moved.appendingPathComponent("old")
        let added = movedChild.appendingPathComponent("created")
        let probe = Probe(tree: [movedChild: [added], added: []])

        try await LocalFolder.refreshChildrenOffMain(
            folderID: fixture.child.objectID, context: fixture.context, provider: probe.provider(root: moved)
        )

        XCTAssertEqual(probe.listedURLs, [movedChild, added])
        XCTAssertEqual(try fixture.folderURLs(), [moved, movedChild, added, moved.appendingPathComponent("sibling")])
        XCTAssertEqual(sibling.parent, fixture.root)
        XCTAssertEqual(fixture.child.parent, fixture.root)
        XCTAssertEqual(fixture.checkpoint.url, movedChild.appendingPathComponent("drawing.excalidraw"))
        XCTAssertEqual(fixture.checkpoint.content, Data([7, 8]))
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testMovedRootSaveFailureKeepsURLsCheckpointsAndFileIDs() async throws {
        let fixture = try Fixture()
        let originalURLs = try fixture.folderURLs()
        let originalCheckpointURL = try XCTUnwrap(fixture.checkpoint.url)
        let moved = fixture.rootURL.appendingPathExtension("moved")
        let movedChild = moved.appendingPathComponent("old")
        let movedCheckpointURL = movedChild.appendingPathComponent("drawing.excalidraw")
        ExcalidrawFile.localFileURLIDMapping[originalCheckpointURL] = "synthetic-drawing"
        defer {
            ExcalidrawFile.localFileURLIDMapping.removeValue(forKey: originalCheckpointURL)
            ExcalidrawFile.localFileURLIDMapping.removeValue(forKey: movedCheckpointURL)
        }
        let notified = expectation(description: "Failed save must not announce a move")
        notified.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: .localFolderResolvedLocationDidChange, object: fixture.root.objectID, queue: nil
        ) { _ in notified.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        fixture.context.failNextSave = true
        do {
            try await fixture.refresh(provider: Probe(tree: [moved: [movedChild], movedChild: []]).provider(root: moved))
            XCTFail("The save failure must propagate")
        } catch TestContext.Failure.save {}
        XCTAssertEqual(try fixture.folderURLs(), originalURLs)
        XCTAssertEqual(fixture.checkpoint.url, originalCheckpointURL)
        XCTAssertEqual(fixture.checkpoint.content, Data([7, 8]))
        XCTAssertEqual(ExcalidrawFile.localFileURLIDMapping[originalCheckpointURL], "synthetic-drawing")
        XCTAssertNil(ExcalidrawFile.localFileURLIDMapping[movedCheckpointURL])
        XCTAssertFalse(fixture.context.hasChanges)
        await fulfillment(of: [notified], timeout: 0.05)
    }

    func testAccessFailureDoesNotStopAnUnopenedScope() async throws {
        let fixture = try Fixture()
        let probe = Probe(tree: [:], failAccess: true)
        do {
            try await fixture.refresh(provider: probe.provider(root: fixture.rootURL))
            XCTFail("Access failure must propagate")
        } catch Probe.Failure.access {}
        XCTAssertEqual(probe.calls, ["resolve", "start"])
        XCTAssertFalse(fixture.child.isDeleted)
    }
}

// All test access follows the context's main-queue confinement.
private final class TestContext: NSManagedObjectContext, @unchecked Sendable {
    enum Failure: Error { case save }
    var failNextSave = false
    private(set) var successfulSaves = 0
    override func save() throws {
        if failNextSave {
            failNextSave = false
            throw Failure.save
        }
        try super.save()
        successfulSaves += 1
    }
}

@MainActor
private final class Fixture {
    let context: TestContext
    let root: LocalFolder
    let child: LocalFolder
    let checkpoint: LocalFileCheckpoint
    let rootURL = URL(fileURLWithPath: "/synthetic-area2/\(UUID().uuidString)")

    init() throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Self.model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        context = TestContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        root = LocalFolder(context: context)
        root.url = rootURL
        root.bookmarkData = Data([1])
        child = LocalFolder(context: context)
        child.url = rootURL.appendingPathComponent("old")
        child.bookmarkData = Data([2])
        child.parent = root
        checkpoint = LocalFileCheckpoint(context: context)
        checkpoint.url = child.url?.appendingPathComponent("drawing.excalidraw")
        checkpoint.content = Data([7, 8])
        try context.save()
    }

    private static let model: NSManagedObjectModel = {
        let folder = NSEntityDescription()
        folder.name = "LocalFolder"
        folder.managedObjectClassName = NSStringFromClass(LocalFolder.self)
        folder.properties = [
            attribute("url", .URIAttributeType), attribute("filePath", .stringAttributeType),
            attribute("bookmarkData", .binaryDataAttributeType), attribute("importedAt", .dateAttributeType),
        ]
        let parent = NSRelationshipDescription()
        parent.name = "parent"
        parent.destinationEntity = folder
        parent.maxCount = 1
        parent.isOptional = true
        let children = NSRelationshipDescription()
        children.name = "children"
        children.destinationEntity = folder
        children.isOptional = true
        children.maxCount = 0
        parent.inverseRelationship = children
        children.inverseRelationship = parent
        folder.properties += [parent, children]
        let checkpointEntity = NSEntityDescription()
        checkpointEntity.name = "LocalFileCheckpoint"
        checkpointEntity.managedObjectClassName = NSStringFromClass(LocalFileCheckpoint.self)
        checkpointEntity.properties = [attribute("url", .URIAttributeType), attribute("content", .binaryDataAttributeType)]
        let model = NSManagedObjectModel()
        model.entities = [folder, checkpointEntity]
        return model
    }()

    func refresh(provider: LinkedFolderRefresh.Provider) async throws {
        try await LocalFolder.refreshChildrenOffMain(folderID: root.objectID, context: context, provider: provider)
    }

    func folderURLs() throws -> Set<URL> {
        Set(try context.fetch(NSFetchRequest<LocalFolder>(entityName: "LocalFolder")).compactMap(\.url))
    }

    private static func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        return attribute
    }
}

private final class Probe: @unchecked Sendable {
    enum Failure: Error { case read, bookmark, access, timeout }
    let entered = XCTestExpectation(description: "Provider entered")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedListURLs: [URL] = []
    private let tree: [URL: [URL]]
    private let failingURL: URL?
    private let block: Bool
    private let failBookmark: Bool
    private let failAccess: Bool

    init(tree: [URL: [URL]], failingURL: URL? = nil, block: Bool = false, failBookmark: Bool = false, failAccess: Bool = false) {
        self.tree = tree
        self.failingURL = failingURL
        self.block = block
        self.failBookmark = failBookmark
        self.failAccess = failAccess
    }

    var calls: [String] { lock.withLock { recordedCalls } }
    var listedURLs: [URL] { lock.withLock { recordedListURLs } }
    private func record(_ call: String) { lock.withLock { recordedCalls.append(call) } }

    func provider(root: URL) -> LinkedFolderRefresh.Provider {
        .init(
            resolve: { [self] _ in record("resolve"); return .init(url: root, isStale: false) },
            startAccess: { [self] _ in record("start"); if failAccess { throw Failure.access } },
            stopAccess: { [self] _ in record("stop") },
            bookmark: { [self] url in
                record("bookmark")
                if failBookmark { throw Failure.bookmark }
                return Data(url.path.utf8)
            },
            directoryContents: { [self] url in
                record("list")
                lock.withLock { recordedListURLs.append(url) }
                if block {
                    entered.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw Failure.timeout }
                }
                if url == failingURL { throw Failure.read }
                return tree[url] ?? []
            }
        )
    }
}
