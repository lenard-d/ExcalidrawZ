#if os(iOS)
import SwiftUI
import UIKit

/// Previews the contacted segment and commits the tool only on a valid release.
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
            let items: [ExcalidrawToolbarToolPresentation.Item]
            let initialSelection: ExcalidrawTool?
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
        private var isFinishingContact = false

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
            control.addTarget(self, action: #selector(commitSelection(_:event:)), for: .valueChanged)
            control.addTarget(self, action: #selector(touchDown(_:event:)), for: .touchDown)
            control.addTarget(self, action: #selector(touchMoved(_:event:)), for: [.touchDragInside, .touchDragOutside, .touchDragEnter, .touchDragExit])
            control.addTarget(self, action: #selector(touchReleased(_:event:)), for: .touchUpInside)
            control.addTarget(self, action: #selector(touchCancelled(_:)), for: [.touchUpOutside, .touchCancel])
            return control
        }

        func update(
            _ control: UISegmentedControl,
            items: [ExcalidrawToolbarToolPresentation.Item],
            selection: Binding<ExcalidrawTool?>,
            size: CGFloat, withFooter: Bool, scale: CGFloat
        ) {
            self.selection = selection
            if contact != nil || control.isTracking {
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

        @objc private func commitSelection(_ control: UISegmentedControl, event: UIEvent?) {
            // Touch selection is committed by its release handler, including an unchanged native index.
            guard contact == nil, !isFinishingContact, event?.allTouches?.isEmpty != false else { return }
            guard displayedItems.indices.contains(control.selectedSegmentIndex) else { return }
            selection.wrappedValue = displayedItems[control.selectedSegmentIndex].tool
        }

        @objc private func touchDown(_ control: UISegmentedControl, event: UIEvent?) {
            guard let point = event?.allTouches?.first?.location(in: control) else { return }
            beginContact(control, at: point)
        }

        @objc private func touchMoved(_ control: UISegmentedControl, event: UIEvent?) {
            guard let point = event?.allTouches?.first?.location(in: control) else { return }
            moveContact(control, to: point)
        }

        @objc private func touchReleased(_ control: UISegmentedControl, event: UIEvent?) {
            guard let point = event?.allTouches?.first?.location(in: control) else {
                cancelContact(control)
                return
            }
            endContact(control, at: point)
        }

        @objc private func touchCancelled(_ control: UISegmentedControl) {
            cancelContact(control)
        }

        func beginContact(_ control: UISegmentedControl, at point: CGPoint) {
            guard control.isEnabled, segment(at: point, in: control) != nil else { return }
            isFinishingContact = false
            contact = Contact(items: displayedItems, initialSelection: selection.wrappedValue)
            moveContact(control, to: point)
        }

        func moveContact(_ control: UISegmentedControl, to point: CGPoint) {
            guard let contact, !contact.invalidated else { return }
            guard let index = segment(at: point, in: control) else {
                restoreSelection(control)
                return
            }
            control.selectedSegmentIndex = index
        }

        func endContact(_ control: UISegmentedControl, at point: CGPoint) {
            if let contact, !contact.invalidated,
               contact.initialSelection == selection.wrappedValue,
               contact.items == displayedItems,
               let index = segment(at: point, in: control) {
                selection.wrappedValue = contact.items[index].tool
            }
            finishContact(control)
        }

        func cancelContact(_ control: UISegmentedControl) {
            finishContact(control)
        }

        private func finishContact(_ control: UISegmentedControl) {
            contact = nil
            isFinishingContact = true
            restoreSelection(control)
            // Rebuild a deferred configuration only after UIKit has finished the touch event.
            DispatchQueue.main.async { [weak self, weak control] in
                guard let self, let control, self.contact == nil, !control.isTracking else { return }
                self.isFinishingContact = false
                if let pending = self.pendingRender {
                    self.update(control, items: pending.items, selection: self.selection,
                                size: pending.size, withFooter: pending.withFooter, scale: pending.scale)
                } else {
                    self.restoreSelection(control)
                }
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
