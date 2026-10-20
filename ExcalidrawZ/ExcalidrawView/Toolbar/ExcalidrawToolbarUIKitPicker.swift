#if os(iOS)
import SwiftUI
import UIKit

/// Previews the last contacted tool and commits it on release, including outside the row.
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
        private struct Contact {
            let initialSelection: ExcalidrawTool?
            var lastIndex: Int
            var invalidated = false
        }
        private struct PendingRender {
            let items: [ExcalidrawToolbarToolPresentation.Item]
            let size: CGFloat
            let withFooter: Bool
            let scale: CGFloat
        }
        private var contact: Contact?
        private var pendingRender: PendingRender?

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
            // Keep tap, drag preview, and release in one input path.
            let scrub = UILongPressGestureRecognizer(target: self, action: #selector(handleScrub(_:)))
            scrub.minimumPressDuration = 0
            scrub.allowableMovement = .greatestFiniteMagnitude
            scrub.delaysTouchesBegan = true
            scrub.cancelsTouchesInView = true
            control.addGestureRecognizer(scrub)
            return control
        }

        func update(
            _ control: UISegmentedControl,
            items: [ExcalidrawToolbarToolPresentation.Item],
            selection: Binding<ExcalidrawTool?>,
            size: CGFloat, withFooter: Bool, scale: CGFloat
        ) {
            self.selection = selection
            if contact != nil {
                pendingRender = PendingRender(items: items, size: size, withFooter: withFooter, scale: scale)
                if contact?.initialSelection != selection.wrappedValue || displayedItems != items
                    || renderedSize != size || renderedFooter != withFooter || renderedScale != scale {
                    contact?.invalidated = true
                    restoreSelection(control)
                }
                return
            }
            pendingRender = nil
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
                    let title = item.menuTitle(localizedName: item.tool.localization)
                    let image = renderer.uiImage?.withRenderingMode(.alwaysTemplate)
                    image?.accessibilityLabel = title
                    let action = UIAction(
                        title: title,
                        image: image
                    ) { _ in }
                    control.insertSegment(action: action, at: index, animated: false)
                    control.setWidth(size * 2, forSegmentAt: index)
                }
            }
            restoreSelection(control)
        }

        private func restoreSelection(_ control: UISegmentedControl) {
            control.selectedSegmentIndex = displayedItems.firstIndex { $0.tool == selection.wrappedValue }
                ?? UISegmentedControl.noSegment
        }

        @objc private func commitSelection(_ control: UISegmentedControl) {
            // Accessibility and keyboard actions do not use the contact recognizer.
            guard contact == nil else { return }
            guard displayedItems.indices.contains(control.selectedSegmentIndex) else { return }
            selection.wrappedValue = displayedItems[control.selectedSegmentIndex].tool
        }

        @objc func handleScrub(_ gesture: UILongPressGestureRecognizer) {
            guard let control = gesture.view as? UISegmentedControl else { return }
            let index = control.isEnabled ? segment(at: gesture.location(in: control), in: control) : nil
            switch gesture.state {
            case .began:
                guard contact == nil, let index else { return }
                contact = Contact(initialSelection: selection.wrappedValue, lastIndex: index)
                control.selectedSegmentIndex = index
            case .changed:
                guard let contact, !contact.invalidated else { return }
                if let index {
                    self.contact?.lastIndex = index
                    control.selectedSegmentIndex = index
                }
            case .ended:
                if let contact, !contact.invalidated,
                   contact.initialSelection == selection.wrappedValue, control.isEnabled {
                    let lastIndex = index ?? contact.lastIndex
                    if control.isEnabledForSegment(at: lastIndex) {
                        selection.wrappedValue = displayedItems[lastIndex].tool
                    }
                }
                finishContact(control)
            case .cancelled, .failed:
                finishContact(control)
            default:
                break
            }
        }

        private func finishContact(_ control: UISegmentedControl) {
            contact = nil
            if let pending = pendingRender {
                update(control, items: pending.items, selection: selection,
                       size: pending.size, withFooter: pending.withFooter, scale: pending.scale)
            } else {
                restoreSelection(control)
            }
        }

        private func segment(at point: CGPoint, in control: UISegmentedControl) -> Int? {
            guard control.bounds.contains(point), control.bounds.width > 0, !displayedItems.isEmpty else { return nil }
            let position = Int((point.x - control.bounds.minX) / control.bounds.width * CGFloat(displayedItems.count))
            let index = control.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? displayedItems.count - 1 - position : position
            guard displayedItems.indices.contains(index), control.isEnabledForSegment(at: index) else { return nil }
            return index
        }
    }
}
#endif
