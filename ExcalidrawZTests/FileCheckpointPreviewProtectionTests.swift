import CoreData
import SwiftUI
import XCTest
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
        let owner = NSRelationshipDescription()
        owner.name = "file"
        owner.destinationEntity = entity(named: "File", type: File.self)
        owner.minCount = 0
        owner.maxCount = 1
        checkpointEntity.properties.append(owner)
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
