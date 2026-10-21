import CoreData
import XCTest
#if os(iOS)
import SwiftUI
#endif
@testable import ExcalidrawZ

final class ExportFilePreparationTests: XCTestCase {
    func testExternalURLExportPreservesEmbeddedMediaAndContent() async throws {
        let store = try ExportMediaStore()
        addTeardownBlock { try await store.close() }
        _ = try await store.seed()
        let embedded = resource("embedded", data: "data:image/png;base64,ZW1iZWRkZWQ=")
        var file = try document(id: "file:///synthetic/External.excalidraw", resources: [embedded])
        let expectedElements = file.elements

        try await file.syncFiles(context: store.context)
        try file.prepareContentForExport(fileName: "Synthetic external")

        let exported = try ExcalidrawFile(data: XCTUnwrap(file.content))
        XCTAssertEqual(exported.files, [embedded.id: embedded])
        XCTAssertEqual(exported.elements, expectedElements)
        XCTAssertEqual(exported.elements.map(\.id), ["shape"])
        XCTAssertEqual(file.id, "file:///synthetic/External.excalidraw")
    }

    func testLibraryExportUsesOnlyOwnerMediaAndEmbeddedCopyWins() async throws {
        let store = try ExportMediaStore()
        addTeardownBlock { try await store.close() }
        let owner = try await store.seed()
        _ = try await store.seed(mediaID: "unrelated")
        let embedded = resource("stored", data: "data:image/png;base64,bGl2ZQ==")
        var file = try document(id: owner.uuidString, resources: [embedded])

        try await file.syncFiles(context: store.context)

        let exported = try ExcalidrawFile(data: XCTUnwrap(file.content))
        XCTAssertEqual(exported.files, [embedded.id: embedded])
    }

    func testLibraryMediaMetadataSurvivesPrivateContextAndDiskRoundTrip() async throws {
        let store = try ExportMediaStore()
        addTeardownBlock { try await store.close() }
        let owner = try await store.seed()
        var file = try document(id: owner.uuidString.lowercased())
        let expectedElements = file.elements

        try await file.syncFiles(context: store.context)
        try file.prepareContentForExport(fileName: "Synthetic library")
        let destination = store.directory.appendingPathComponent("export.excalidraw")
        try XCTUnwrap(file.content).write(to: destination, options: .atomic)
        let exported = try ExcalidrawFile(data: Data(contentsOf: destination))

        XCTAssertEqual(exported.files, ["stored": store.expectedResource])
        XCTAssertEqual(exported.elements, expectedElements)
        XCTAssertEqual(exported.elements.map(\.id), ["shape"])
    }

    func testUnavailableLibraryMediaDoesNotRemoveEmbeddedResources() async throws {
        let store = try ExportMediaStore()
        addTeardownBlock { try await store.close() }
        let owner = try await store.seed(dataURL: nil)
        let embedded = resource("embedded", data: "data:image/png;base64,a2VlcA==")
        var file = try document(id: owner.uuidString, resources: [embedded])

        try await file.syncFiles(context: store.context)

        XCTAssertEqual(file.files, [embedded.id: embedded])
        let exported = try ExcalidrawFile(data: XCTUnwrap(file.content))
        XCTAssertEqual(exported.files, file.files)
    }

    func testMainQueueContextExportsLibraryMediaFromAsyncCaller() async throws {
        let store = try ExportMediaStore(concurrencyType: .mainQueueConcurrencyType)
        addTeardownBlock { try await store.close() }
        let owner = try await store.seed()
        var file = try document(id: owner.uuidString)

        try await file.syncFiles(context: store.context)

        XCTAssertEqual(file.files, ["stored": store.expectedResource])
    }

    func testLibraryExportLoadsStorageMediaBeforeCoreDataFallback() async throws {
        try requireIsolatedStorage()
        let store = try ExportMediaStore()
        addTeardownBlock { try await store.close() }
        let mediaID = UUID().uuidString
        let path = try await FileStorageManager.shared.saveMediaItem(
            dataURL: store.expectedResource.dataURL, mediaID: mediaID
        )
        addTeardownBlock {
            try await FileStorageManager.shared.deleteContent(relativePath: path, fileID: mediaID)
        }
        let owner = try await store.seed(
            mediaID: mediaID, dataURL: "data:image/png;base64,b2xk", filePath: path
        )
        var file = try document(id: owner.uuidString)

        try await file.syncFiles(context: store.context)

        var expected = store.expectedResource
        expected.id = mediaID
        XCTAssertEqual(file.files, [mediaID: expected])
    }

    func testMissingStorageFallsBackToCoreDataMedia() async throws {
        try requireIsolatedStorage()
        let store = try ExportMediaStore()
        addTeardownBlock { try await store.close() }
        let owner = try await store.seed(filePath: "media/" + UUID().uuidString + ".svg")
        var file = try document(id: owner.uuidString)

        try await file.syncFiles(context: store.context)

        XCTAssertEqual(file.files, ["stored": store.expectedResource])
    }

    private func requireIsolatedStorage() throws {
        guard Bundle.main.bundleIdentifier == "de.lenard.excalidrawz.test.integration.ExcalidrawZ",
              !ICloudContainerConfiguration.current.isCloudKitEnabled else {
            throw XCTSkip("Shared storage tests require the isolated local test app.")
        }
    }

#if os(iOS)
    @MainActor
    func testNativeExportViewPreparesExternalDocumentWithEmbeddedMedia() async throws {
        try await assertNativeExport(library: false)
    }

    @MainActor
    func testNativeExportViewPreparesLibraryDocumentWithStoredMedia() async throws {
        try await assertNativeExport(library: true)
    }

    @MainActor
    private func assertNativeExport(library: Bool) async throws {
        guard Bundle.main.bundleIdentifier == "de.lenard.excalidrawz.test.integration.ExcalidrawZ",
              !ICloudContainerConfiguration.current.isCloudKitEnabled else {
            throw XCTSkip("Native export hosting requires the isolated local test app.")
        }
        let store = try ExportMediaStore()
        addTeardownBlock { try await store.close() }
        let owner = try await store.seed()
        let embedded = resource("embedded", data: "data:image/png;base64,bmF0aXZl")
        var file = try document(
            id: library ? owner.uuidString : "file:///synthetic/Native.excalidraw",
            resources: library ? [] : [embedded]
        )
        let name = "Export-test-" + UUID().uuidString
        file.name = name
        let expectedElements = file.elements
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = UIHostingController(
            rootView: ExportFileView(file: file).environment(\.managedObjectContext, store.context)
        )
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // The production view's task writes its prepared share copy to a replacement directory.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var exportedURL: URL?
        while ContinuousClock.now < deadline, exportedURL == nil {
            let enumerator = FileManager.default.enumerator(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            )
            exportedURL = enumerator?.compactMap { $0 as? URL }.first {
                $0.lastPathComponent == name + ".excalidraw"
            }
            if exportedURL == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let url = try XCTUnwrap(exportedURL, "The actual ExportFileView task did not create its share copy.")
        defer { try? FileManager.default.removeItem(at: url) }
        let exported = try ExcalidrawFile(data: Data(contentsOf: url))
        let expected = library ? store.expectedResource : embedded
        XCTAssertEqual(exported.files, [expected.id: expected])
        XCTAssertEqual(exported.elements, expectedElements)
        XCTAssertEqual(exported.elements.map(\.id), ["shape"])
    }
#endif

    private func document(id: String, resources: [ExcalidrawFile.ResourceFile] = []) throws -> ExcalidrawFile {
        let shape = try JSONDecoder().decode(ExcalidrawElement.self, from: Data(##"""
        {"id":"shape","type":"rectangle","x":10,"y":20,"width":100,"height":80,"strokeColor":"#000000","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"angle":0,"seed":1,"version":1,"versionNonce":1,"isDeleted":false,"groupIds":[]}
        """##.utf8))
        var file = ExcalidrawFile(
            source: "export-test", files: Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) }),
            version: 2, elements: [shape], appState: .init(), type: "excalidraw"
        )
        file.id = id
        file.content = try JSONEncoder().encode(file)
        return file
    }

    private func resource(_ id: String, data: String) -> ExcalidrawFile.ResourceFile {
        .init(mimeType: "image/png", id: id, createdAt: .distantPast, dataURL: data, lastRetrievedAt: .distantPast)
    }
}

private final class ExportMediaStore {
    let directory: URL
    let context: NSManagedObjectContext
    private let coordinator: NSPersistentStoreCoordinator
    let expectedResource = ExcalidrawFile.ResourceFile(
        mimeType: "image/svg+xml", id: "stored", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        dataURL: "data:image/svg+xml;base64,PHN2Zy8+", lastRetrievedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )

    init(concurrencyType: NSManagedObjectContextConcurrencyType = .privateQueueConcurrencyType) throws {
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "Model", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil,
            at: directory.appendingPathComponent("synthetic.sqlite")
        )
        context = NSManagedObjectContext(concurrencyType: concurrencyType)
        context.persistentStoreCoordinator = coordinator
    }

    func seed(
        mediaID: String = "stored",
        dataURL: String? = "data:image/svg+xml;base64,PHN2Zy8+",
        filePath: String? = nil
    ) async throws -> UUID {
        let id = UUID()
        try await context.perform {
            let file = ExcalidrawZ.File(context: self.context)
            file.id = id
            let media = MediaItem(context: self.context)
            media.file = file
            media.id = mediaID
            media.dataURL = dataURL
            media.filePath = filePath
            media.mimeType = self.expectedResource.mimeType
            media.createdAt = self.expectedResource.createdAt
            media.lastRetrievedAt = self.expectedResource.lastRetrievedAt
            try self.context.save()
            self.context.reset()
        }
        return id
    }

    func close() async throws {
        await context.perform { self.context.reset() }
        for store in coordinator.persistentStores { try coordinator.remove(store) }
        try FileManager.default.removeItem(at: directory)
    }
}
