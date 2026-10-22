import Foundation

struct PageModePage: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let width: Double
    let height: Double
    let locked: Bool
    var layout: PageModeLayout?
    var x: Double?
    var y: Double?
}

struct PageModeState: Codable, Sendable {
    let pages: [PageModePage]
    let openedPageID: String?
}

struct PageModeCommand: Encodable, Sendable {
    enum Action: String, Encodable {
        case list, add, rename, move, remove, open, canvas, exportScene, setLayout
    }

    var action: Action
    var pageID: String?
    var title: String?
    var width: Double?
    var height: Double?
    var offset: Int?
    var layout: PageModeLayout?
    var placement: PageModePlacement?

    var changesScene: Bool {
        switch action {
            case .add, .rename, .move, .remove, .setLayout: true
            default: false
        }
    }
}

enum PageModeLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case blank, grid, ruled

    var id: Self { self }

    var title: String {
        switch self {
            case .blank: String(localized: "Blank")
            case .grid: String(localized: "Grid")
            case .ruled: String(localized: "Ruled")
        }
    }
}

enum PageModePlacement: String, Encodable, CaseIterable, Identifiable, Sendable {
    case below, right

    var id: Self { self }
    var title: String {
        switch self {
            case .below: String(localized: "Add below")
            case .right: String(localized: "Add right")
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

enum PageModeError: String, LocalizedError {
    case unavailable
    case documentChanged
    case invalidExport
    case pageMissing
    case viewMode
    case pageLocked
    case invalidSize
    case invalidBounds
    case noSpace
    case failedAction
    case invalidTitle
    case invalidMove
    case invalidLayout
    case spaceOccupied

    var errorDescription: String? {
        switch self {
            case .unavailable:
                String(localized: "Pages are not available while this drawing is locked or loading.")
            case .documentChanged:
                String(localized: "The drawing changed. Open Pages again to continue.")
            case .invalidExport:
                String(localized: "The pages could not be exported. The drawing has not changed.")
            case .pageMissing:
                String(localized: "This page is no longer available. Open Pages again.")
            case .viewMode:
                String(localized: "Leave view mode before changing pages.")
            case .pageLocked:
                String(localized: "Unlock the page frame before changing it.")
            case .invalidSize:
                String(localized: "The page size is not supported.")
            case .invalidBounds:
                String(localized: "The drawing has invalid element bounds.")
            case .noSpace:
                String(localized: "There is no space for another page here.")
            case .failedAction:
                String(localized: "The page action could not be completed. Open Pages again to continue.")
            case .invalidTitle:
                String(localized: "Use a page title with 1 to 120 characters.")
            case .invalidMove:
                String(localized: "The page move is not supported.")
            case .invalidLayout:
                String(localized: "The page layout is not supported.")
            case .spaceOccupied:
                String(localized: "There is drawing content in that space. Choose another direction.")
        }
    }
}
