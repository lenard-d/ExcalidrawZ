import Foundation

struct FileCheckpointMetadata: Equatable, Sendable {
    let byteCount: Int
    let elementCount: Int?
}

/// Reads row details without retaining drawing elements, points, or embedded media.
/// Actor isolation keeps parsing off the UI actor and limits concurrent decodes.
actor FileCheckpointMetadataReader {
    static let shared = FileCheckpointMetadataReader()

    func read(_ content: Data) throws -> FileCheckpointMetadata {
        try Task.checkCancellation()
        let summary = try? JSONDecoder().decode(Summary.self, from: content)
        try Task.checkCancellation()
        return FileCheckpointMetadata(
            byteCount: content.count,
            elementCount: summary?.elementCount
        )
    }

    // This is a display summary, not validation for restoring a drawing.
    private struct Summary: Decodable {
        let elementCount: Int

        private enum CodingKeys: String, CodingKey {
            case type, elements
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _ = try container.decode(String.self, forKey: .type)
            elementCount = try container.decodeIfPresent(ElementCount.self, forKey: .elements)?.value ?? 0
        }
    }

    private struct ElementCount: Decodable {
        let value: Int

        init(from decoder: Decoder) throws {
            var elements = try decoder.unkeyedContainer()
            var count = 0
            while !elements.isAtEnd {
                try Task.checkCancellation()
                if try !elements.decode(Element.self).isDeleted {
                    count += 1
                }
            }
            value = count
        }
    }

    private struct Element: Decodable {
        let isDeleted: Bool

        private enum CodingKeys: String, CodingKey {
            case type, isDeleted
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _ = try container.decode(ExcalidrawElementType.self, forKey: .type)
            isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        }
    }
}
