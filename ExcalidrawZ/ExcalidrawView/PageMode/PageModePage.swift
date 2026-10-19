import Foundation

struct PageModePage: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let width: Double
    let height: Double
    let locked: Bool
}

struct PageModeState: Codable, Sendable {
    let pages: [PageModePage]
    let openedPageID: String?
}

struct PageModeCommand: Encodable, Sendable {
    enum Action: String, Encodable {
        case list, add, rename, move, remove, open, canvas, exportScene
    }

    var action: Action
    var pageID: String?
    var title: String?
    var width: Double?
    var height: Double?
    var offset: Int?

    var changesScene: Bool {
        switch action {
            case .add, .rename, .move, .remove: true
            default: false
        }
    }
}

enum PageModePaper: String, CaseIterable, Identifiable {
    case a4Portrait, a4Landscape

    var id: Self { self }

    var title: String {
        switch self {
            case .a4Portrait: String(localized: "A4 portrait")
            case .a4Landscape: String(localized: "A4 landscape")
        }
    }

    var width: Double { self == .a4Portrait ? 595 : 842 }
    var height: Double { self == .a4Portrait ? 842 : 595 }
}

enum PageModeError: LocalizedError {
    case unavailable
    case documentChanged
    case invalidExport

    var errorDescription: String? {
        switch self {
            case .unavailable:
                String(localized: "Pages are not available while this drawing is locked or loading.")
            case .documentChanged:
                String(localized: "The drawing changed. Open Pages again to continue.")
            case .invalidExport:
                String(localized: "The pages could not be exported. The drawing has not changed.")
        }
    }
}
