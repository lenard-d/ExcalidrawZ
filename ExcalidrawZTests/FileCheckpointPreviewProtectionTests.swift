import CoreData
import SwiftUI
import XCTest
#if targetEnvironment(simulator)
import UIKit
#endif
@testable import ExcalidrawZ

final class FileCheckpointPreviewProtectionTests: XCTestCase {
    @MainActor
    func testLibraryCheckpointWarmPreviewIsRemovedWhenAccessCannotBeResolved() {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        let checkpoint = fileCheckpoint(in: context)
        let owner = checkpoint.entity.relationshipsByName["file"]!
        let file = File(entity: owner.destinationEntity!, insertInto: context)
        checkpoint.file = file
        let previewID = FileCoverCacheCoordinator.checkpointPreviewID(for: checkpoint)
        seedPreview(for: previewID)
        defer { FileItemPreviewCache.shared.removePreviewCache(forID: previewID) }

        // This owner exists only in the test context. The coordinator cannot
        // resolve its protection state and must not keep a warm decrypted image.
        FileCoverCacheCoordinator.shared.request(checkpoint: checkpoint, colorScheme: .light)

        XCTAssertNil(FileItemPreviewCache.shared.getPreviewCache(forID: previewID, colorScheme: .light))
        XCTAssertNil(FileItemPreviewCache.shared.getPreviewCache(forID: previewID, colorScheme: .dark))
    }

    @MainActor
    func testLocalCheckpointWarmPreviewRemainsAvailable() {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        let checkpoint = LocalFileCheckpoint(
            entity: entity(named: "LocalFileCheckpoint", type: LocalFileCheckpoint.self),
            insertInto: context
        )
        checkpoint.id = UUID()
        let previewID = FileCoverCacheCoordinator.checkpointPreviewID(for: checkpoint)
        seedPreview(for: previewID)
        defer { FileItemPreviewCache.shared.removePreviewCache(forID: previewID) }

        FileCoverCacheCoordinator.shared.request(checkpoint: checkpoint, colorScheme: .light)

        XCTAssertNotNil(FileItemPreviewCache.shared.getPreviewCache(forID: previewID, colorScheme: .light))
        XCTAssertNotNil(FileItemPreviewCache.shared.getPreviewCache(forID: previewID, colorScheme: .dark))
    }

    @MainActor
    func testFileCheckpointWithoutLibraryOwnerKeepsWarmPreview() {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        let checkpoint = fileCheckpoint(in: context)
        let previewID = FileCoverCacheCoordinator.checkpointPreviewID(for: checkpoint)
        seedPreview(for: previewID)
        defer { FileItemPreviewCache.shared.removePreviewCache(forID: previewID) }

        FileCoverCacheCoordinator.shared.request(checkpoint: checkpoint, colorScheme: .light)

        XCTAssertNotNil(FileItemPreviewCache.shared.getPreviewCache(forID: previewID, colorScheme: .light))
        XCTAssertNotNil(FileItemPreviewCache.shared.getPreviewCache(forID: previewID, colorScheme: .dark))
    }

    @MainActor
    private func fileCheckpoint(in context: NSManagedObjectContext) -> FileCheckpoint {
        let checkpointEntity = entity(named: "FileCheckpoint", type: FileCheckpoint.self)
        let fileEntity = entity(named: "File", type: File.self)
        let owner = NSRelationshipDescription()
        owner.name = "file"
        owner.destinationEntity = fileEntity
        owner.minCount = 0
        owner.maxCount = 1
        checkpointEntity.properties.append(owner)
        // Relationships do not retain their destination entity. The context's
        // coordinator keeps this model and both entities alive without a store.
        let model = NSManagedObjectModel()
        model.entities = [checkpointEntity, fileEntity]
        context.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let checkpoint = FileCheckpoint(entity: checkpointEntity, insertInto: context)
        checkpoint.id = UUID()
        return checkpoint
    }

    @MainActor
    private func seedPreview(for id: String) {
        for scheme in [ColorScheme.light, .dark] {
            FileItemPreviewCache.shared.setObject(
                PlatformImage(),
                forKey: FileItemPreviewCache.cacheKey(forID: id, colorScheme: scheme)
            )
        }
    }

    private func entity(named name: String, type: NSManagedObject.Type) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(type)
        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = true
        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = true
        entity.properties = [id, updatedAt]
        return entity
    }
}

#if targetEnvironment(simulator)
@MainActor
final class FileCheckpointPreviewRelockTests: XCTestCase {
    func testFailedOwnerReadPreservesProtectionAndRelockRemovesAllWarmVersions() async throws {
        try await withFixture { fixture in
            let observer = fixture.state.previewState(for: .file(fixture.file))
            var versions: [String] = []
            for revision in [1.0, 2.0] {
                fixture.checkpoint.updatedAt = Date(timeIntervalSinceReferenceDate: revision)
                versions.append(await fixture.warmCurrentPreview())
            }

            try await fixture.makeOwnerUnreadable()
            await fixture.state.refresh(file: .file(fixture.file))
            XCTAssertEqual(observer.value, .temporarilyUnlocked)
            await fixture.relock()
            XCTAssertEqual(observer.value, .locked)

            for id in versions {
                for scheme in [ColorScheme.light, .dark] {
                    XCTAssertNil(FileItemPreviewCache.shared.getPreviewCache(forID: id, colorScheme: scheme))
                }
            }

            try fixture.restoreOwnerContent()
            try await fixture.unlock()
            XCTAssertEqual(observer.value, .temporarilyUnlocked)
            _ = await fixture.warmCurrentPreview()
        }
    }

    func testFailedOwnerReadCannotPublishExportFromBeforeRelockAfterRecovery() async throws {
        let gate = ExportGate()
        try await withFixture(exportPNG: gate.export) { fixture in
            defer { gate.release() }
            let id = fixture.trackCurrentPreview()
            fixture.coordinator.request(checkpoint: fixture.checkpoint, colorScheme: .dark)
            await fulfillment(of: [gate.started], timeout: 5)
            XCTAssertEqual(gate.callCount, 1)

            try await fixture.makeOwnerUnreadable()
            await fixture.state.refresh(file: .file(fixture.file))
            await fixture.relock()
            try fixture.restoreOwnerContent()
            try await fixture.unlock()
            gate.release()
            await fixture.coordinator.waitForPendingPreviewWork()

            XCTAssertNil(FileItemPreviewCache.shared.getPreviewCache(forID: id, colorScheme: .light))
            XCTAssertNil(FileItemPreviewCache.shared.getPreviewCache(forID: id, colorScheme: .dark))
            _ = await fixture.warmCurrentPreview()
        }
    }

    func testFailedOwnerReadWithoutKnownProtectionRemainsUnresolvedUntilSuccessfulRead() async throws {
        try await withFixture { fixture in
            // The first real read fails while another store already has an
            // unlock session. It must not infer access from that session.
            let state = LockedContentStateStore()
            let observer = state.previewState(for: .file(fixture.file))
            try await fixture.makeOwnerUnreadable()
            await state.refresh(file: .file(fixture.file))
            XCTAssertNil(observer.value)
            await state.refresh(fileObjectID: fixture.file.objectID, fileID: fixture.file.id!.uuidString)
            XCTAssertNil(observer.value)

            try fixture.restoreOwnerContent()
            fixture.file.content = Data(#"{"type":"excalidraw","elements":[],"appState":{},"files":{}}"#.utf8)
            try fixture.file.managedObjectContext!.save()
            await state.refresh(file: .file(fixture.file))
            XCTAssertEqual(observer.value, .plaintext)
            let revision = state.filePreviewLockStateRevision

            try await fixture.makeOwnerUnreadable()
            await state.refresh(fileObjectID: fixture.file.objectID, fileID: fixture.file.id!.uuidString)
            XCTAssertNil(observer.value)
            XCTAssertGreaterThan(state.filePreviewLockStateRevision, revision)
            state.resetAll()
        }
    }

    func testRelockRemovesWarmLibraryPreviewVersionsInBothAppearances() async throws {
        try await withFixture { fixture in
            var versions: [String] = []
            for revision in [1.0, 2.0] {
                fixture.checkpoint.updatedAt = Date(timeIntervalSinceReferenceDate: revision)
                let id = fixture.trackCurrentPreview()
                versions.append(id)
                for scheme in [ColorScheme.light, .dark] {
                    FileItemPreviewCache.shared.setObject(
                        UIImage(), forKey: FileItemPreviewCache.cacheKey(forID: id, colorScheme: scheme)
                    )
                }
                fixture.coordinator.request(checkpoint: fixture.checkpoint, colorScheme: .light)
                XCTAssertNotNil(FileItemPreviewCache.shared.getPreviewCache(forID: id, colorScheme: .light))
            }

            await fixture.relock()

            for id in versions {
                XCTAssertNil(FileItemPreviewCache.shared.getPreviewCache(forID: id, colorScheme: .light))
                XCTAssertNil(FileItemPreviewCache.shared.getPreviewCache(forID: id, colorScheme: .dark))
            }
        }
    }

    func testExportFromBeforeRelockCannotPublishAfterUnlock() async throws {
        let gate = ExportGate()
        try await withFixture(exportPNG: gate.export) { fixture in
            defer { gate.release() }
            let id = fixture.trackCurrentPreview()
            fixture.coordinator.request(checkpoint: fixture.checkpoint, colorScheme: .light)
            await fulfillment(of: [gate.started], timeout: 5)
            XCTAssertEqual(gate.callCount, 1)

            await fixture.relock()
            try await fixture.unlock()
            gate.release()
            await fixture.coordinator.waitForPendingPreviewWork()

            XCTAssertNil(FileItemPreviewCache.shared.getPreviewCache(forID: id, colorScheme: .light))
            XCTAssertNil(FileItemPreviewCache.shared.getPreviewCache(forID: id, colorScheme: .dark))
        }
    }

    func testRequestAfterUnlockSurvivesInvalidatedExportStillInFlight() async throws {
        let gate = ExportGate()
        try await withFixture(exportPNG: gate.export) { fixture in
            defer { gate.release() }
            let id = fixture.trackCurrentPreview()
            fixture.coordinator.request(checkpoint: fixture.checkpoint, colorScheme: .light)
            await fulfillment(of: [gate.started], timeout: 5)

            await fixture.relock()
            try await fixture.unlock()
            fixture.coordinator.request(checkpoint: fixture.checkpoint, colorScheme: .light)
            gate.release()
            await fixture.coordinator.waitForPendingPreviewWork()

            XCTAssertEqual(gate.callCount, 2)
            XCTAssertNotNil(FileItemPreviewCache.shared.getPreviewCache(forID: id, colorScheme: .light))
        }
    }

    private func withFixture(
        exportPNG: @escaping @MainActor (ExcalidrawFile, ColorScheme) async throws -> Data = { _, _ in
            FileCheckpointPreviewRelockTests.previewPNG()
        },
        body: (Fixture) async throws -> Void
    ) async throws {
        guard ProcessInfo.processInfo.environment["EXCALIDRAWZ_ISOLATED_HISTORY_TESTS"] == "1" else {
            throw XCTSkip("Requires an audited, fresh isolated simulator and explicit opt-in.")
        }
        let fixture = try await Fixture(exportPNG: exportPNG)
        do {
            try await body(fixture)
        } catch {
            try? await fixture.cleanUp()
            throw error
        }
        try await fixture.cleanUp()
    }

    @MainActor
    private final class ExportGate {
        let started = XCTestExpectation(description: "Actual checkpoint export started")
        private(set) var callCount = 0
        private var continuation: CheckedContinuation<Data, Never>?
        private var isReleased = false

        func export(_ file: ExcalidrawFile, _ scheme: ColorScheme) async throws -> Data {
            guard file.id.hasPrefix("checkpoint:") else {
                return FileCheckpointPreviewRelockTests.previewPNG()
            }
            callCount += 1
            guard callCount == 1, !isReleased else {
                return FileCheckpointPreviewRelockTests.previewPNG()
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }

        func release() {
            isReleased = true
            continuation?.resume(returning: FileCheckpointPreviewRelockTests.previewPNG())
            continuation = nil
        }
    }

    @MainActor
    private final class Fixture {
        let file: File
        let checkpoint: FileCheckpoint
        let state = LockedContentStateStore()
        let fileState = FileState()
        let coordinator: FileCoverCacheCoordinator
        private let context: NSManagedObjectContext
        private let key: RecoveryKey
        private let encryptedOwnerContent: Data
        private var previewIDs: Set<String> = []

        init(exportPNG: @escaping @MainActor (ExcalidrawFile, ColorScheme) async throws -> Data) async throws {
            // The caller's opt-in gate runs before this touches app persistence.
            context = PersistenceController.shared.container.viewContext
            key = try RecoveryKeyService.generate()
            let content = Data(#"{"type":"excalidraw","elements":[],"appState":{},"files":{}}"#.utf8)
            let fileID = UUID()
            let checkpointID = UUID()
            let fileContent = try EncryptedContentService.encryptAndVerifyRecovery(
                content, contentType: "file", contentID: fileID.uuidString, recoveryKey: key
            )
            let checkpointContent = try EncryptedContentService.encryptAndVerifyRecovery(
                content, contentType: "fileCheckpoint", contentID: checkpointID.uuidString, recoveryKey: key
            )
            encryptedOwnerContent = fileContent
            file = File(context: context)
            file.id = fileID
            file.name = "Synthetic history privacy test"
            file.content = fileContent
            file.inTrash = false
            checkpoint = FileCheckpoint(context: context)
            checkpoint.id = checkpointID
            checkpoint.updatedAt = Date(timeIntervalSinceReferenceDate: 1)
            checkpoint.content = checkpointContent
            checkpoint.file = file
            coordinator = FileCoverCacheCoordinator(
                fileState: fileState, lockedContentState: state, context: context, exportPNG: exportPNG
            )
            try context.save()
            do {
                try await unlock()
            } catch {
                try? await cleanUp()
                throw error
            }
        }

        func unlock() async throws {
            _ = try await LockedContentUnlockSession.shared.unlock(
                file.content!, recoveryKey: key, expectedContentType: "file", expectedContentID: file.id!.uuidString
            )
            _ = try await LockedContentUnlockSession.shared.unlock(
                checkpoint.content!, recoveryKey: key,
                expectedContentType: "fileCheckpoint", expectedContentID: checkpoint.id!.uuidString
            )
            await state.refresh(file: .file(file))
            XCTAssertEqual(state.previewLockState(for: .file(file)), .temporarilyUnlocked)
        }

        func relock() async {
            await state.relockCurrentSession(activeFile: .file(file))
            XCTAssertEqual(state.previewLockState(for: .file(file)), .locked)
            coordinator.refreshLibraryCoversForLockStateChange(colorScheme: .light)
        }

        func trackCurrentPreview() -> String {
            let id = FileCoverCacheCoordinator.checkpointPreviewID(for: checkpoint)
            previewIDs.insert(id)
            return id
        }

        func warmCurrentPreview() async -> String {
            let id = trackCurrentPreview()
            for scheme in [ColorScheme.light, .dark] {
                coordinator.request(checkpoint: checkpoint, colorScheme: scheme)
                await coordinator.waitForPendingPreviewWork()
                XCTAssertNotNil(FileItemPreviewCache.shared.getPreviewCache(forID: id, colorScheme: scheme))
            }
            return id
        }

        func makeOwnerUnreadable() async throws {
            file.content = nil
            file.filePath = "history-privacy-missing-\(UUID().uuidString).excalidraw"
            try context.save()
            do {
                _ = try await PersistenceController.shared.fileRepository
                    .fileContentLockState(fileObjectID: file.objectID)
                XCTFail("The real owner protection lookup must throw before testing failure handling.")
            } catch {
                // The persisted owner still exists. Only its content read fails.
            }
        }

        func restoreOwnerContent() throws {
            file.content = encryptedOwnerContent
            file.filePath = nil
            try context.save()
        }

        func cleanUp() async throws {
            await state.relockCurrentSession(activeFile: nil)
            await coordinator.waitForPendingPreviewWork()
            for id in previewIDs { FileItemPreviewCache.shared.removePreviewCache(forID: id) }
            context.delete(checkpoint)
            context.delete(file)
            try context.save()
        }
    }

    private static func previewPNG() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.pngData()!
    }
}
#endif
