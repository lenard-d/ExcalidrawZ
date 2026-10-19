import Foundation

struct ExcalidrawToolbarToolPresentation {
    struct Item: Identifiable, Equatable {
        let tool: ExcalidrawTool
        let shortcutLabel: String?

        var id: ExcalidrawTool { tool }

        func menuTitle(localizedName: String) -> String {
            guard let shortcutLabel else { return localizedName }
            return "\(localizedName) (\(shortcutLabel))"
        }
    }

    private let order: ExcalidrawToolbarToolOrder
    let items: [Item]

    init(order: ExcalidrawToolbarToolOrder) {
        self.order = order
        // Assign shortcuts before any layout partition or compact menu filter.
        self.items = order.tools.map {
            Item(tool: $0, shortcutLabel: order.shortcutLabel(for: $0))
        }
    }

    func pickerItems(
        for sizeClass: ExcalidrawToolbarToolSizeClass
    ) -> (primary: [Item], secondary: [Item]) {
        let partition = order.pickerItems(for: sizeClass)
        return (
            items.filter { partition.primary.contains($0.tool) },
            items.filter { partition.secondary.contains($0.tool) }
        )
    }

    var compactItems: [Item] {
        items.filter {
            switch $0.tool {
                case .cursor, .freedraw, .hand, .lasso:
                    false
                default:
                    true
            }
        }
    }
}
