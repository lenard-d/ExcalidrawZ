import XCTest
import CoreData
@testable import ExcalidrawZ

@MainActor
final class LinkedFolderRefreshTests: XCTestCase {
    func testCompleteReadReconcilesOnceAndKeepsCheckpoints() async throws {
        let fixture = try Fixture()
        let added = fixture.rootURL.appendingPathComponent("added")
        let probe = Probe(tree: [fixture.rootURL: [added], added: []])

        try await fixture.refresh(provider: probe.provider(root: fixture.rootURL))

        XCTAssertEqual(try fixture.folderURLs(), [fixture.rootURL, added])
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(fixture.checkpoint.content, Data([7, 8]))
        XCTAssertEqual(probe.calls, ["resolve", "start", "list", "bookmark", "list", "stop"])
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
        do {
            try await older.value
            XCTFail("The older refresh must be cancelled")
        } catch is CancellationError {}
        XCTAssertEqual(try fixture.folderURLs(), [fixture.rootURL, added])
        XCTAssertEqual(old.calls.last, "stop")
        XCTAssertEqual(recent.calls.last, "stop")
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
        let moved = fixture.rootURL.appendingPathExtension("moved")
        let child = moved.appendingPathComponent("old")
        let probe = Probe(tree: [moved: [child], child: []])
        try await fixture.refresh(provider: probe.provider(root: moved))
        XCTAssertEqual(fixture.root.url, moved)
        XCTAssertEqual(fixture.child.url, child)
        XCTAssertEqual(fixture.checkpoint.url, child.appendingPathComponent("drawing.excalidraw"))
        XCTAssertEqual(fixture.root.bookmarkData, Data(moved.path.utf8))
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
    override func save() throws {
        if failNextSave {
            failNextSave = false
            throw Failure.save
        }
        try super.save()
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
