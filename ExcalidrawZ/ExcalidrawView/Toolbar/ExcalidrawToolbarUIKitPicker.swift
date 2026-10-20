#if os(iOS)
import SwiftUI
import UIKit

/// Uses native touch tracking so a drag can preview segments and commit on release.
struct ExcalidrawToolbarUIKitPicker: UIViewRepresentable {
    let items: [ExcalidrawToolbarToolPresentation.Item]
    @Binding var selection: ExcalidrawTool?
    var size: CGFloat = 20
    var withFooter = true
    @Environment(\.displayScale) private var displayScale

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = context.coordinator.makeControl()
        updateUIView(control, context: context)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.update(
            control, items: items, selection: $selection,
            size: size, withFooter: withFooter, scale: displayScale
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width: CGFloat(items.count) * size * 2, height: max(44, size * 2.2))
    }

    @MainActor
    final class Coordinator: NSObject {
        private var selection: Binding<ExcalidrawTool?>
        private var displayedItems: [ExcalidrawToolbarToolPresentation.Item] = []
        private var renderedSize: CGFloat?
        private var renderedFooter: Bool?
        private var renderedScale: CGFloat?

        init(selection: Binding<ExcalidrawTool?>) { self.selection = selection }

        func makeControl() -> UISegmentedControl {
            let control = UISegmentedControl()
            control.accessibilityIdentifier = "toolbar.toolPicker"
            let clearDivider = UIImage()
            for left: UIControl.State in [.normal, .selected] {
                for right: UIControl.State in [.normal, .selected] {
                    control.setDividerImage(clearDivider, forLeftSegmentState: left,
                                            rightSegmentState: right, barMetrics: .default)
                }
            }
            control.addTarget(self, action: #selector(commitSelection(_:)), for: .valueChanged)
            return control
        }

        func update(
            _ control: UISegmentedControl,
            items: [ExcalidrawToolbarToolPresentation.Item],
            selection: Binding<ExcalidrawTool?>,
            size: CGFloat, withFooter: Bool, scale: CGFloat
        ) {
            self.selection = selection
            // An unrelated SwiftUI update must not reset the native drag preview.
            guard !control.isTracking else { return }
            if displayedItems != items || renderedSize != size || renderedFooter != withFooter || renderedScale != scale {
                control.removeAllSegments()
                displayedItems = items
                renderedSize = size
                renderedFooter = withFooter
                renderedScale = scale
                for (index, item) in items.enumerated() {
                    let renderer = ImageRenderer(content: SegmentedToolPickerItemView(
                        tool: item.tool, size: size, withFooter: withFooter,
                        shortcutLabel: item.shortcutLabel
                    ).environment(\.colorScheme, .light))
                    renderer.scale = scale
                    let action = UIAction(
                        title: item.menuTitle(localizedName: item.tool.localization),
                        image: renderer.uiImage?.withRenderingMode(.alwaysTemplate)
                    ) { _ in }
                    control.insertSegment(action: action, at: index, animated: false)
                    control.setWidth(size * 2, forSegmentAt: index)
                }
            }
            control.selectedSegmentIndex = items.firstIndex { $0.tool == selection.wrappedValue }
                ?? UISegmentedControl.noSegment
        }

        @objc private func commitSelection(_ control: UISegmentedControl) {
            guard displayedItems.indices.contains(control.selectedSegmentIndex) else { return }
            selection.wrappedValue = displayedItems[control.selectedSegmentIndex].tool
        }
    }
}
#endif
