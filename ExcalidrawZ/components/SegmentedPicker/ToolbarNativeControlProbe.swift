#if DEBUG && os(iOS) && targetEnvironment(simulator)
import SwiftUI
import UIKit

/// Temporary native-control comparison. Selection never reaches the canvas.
struct ToolbarNativeControlProbe: UIViewRepresentable {
    enum Kind: String {
        case segmented
        case tabbar
    }

    static var requestedKind: Kind? {
        let value = ProcessInfo.processInfo.environment["EXCALIDRAWZ_TOOLBAR_NATIVE_PROBE"] ?? ""
        return Kind(rawValue: value)
    }

    let kind: Kind

    private let choices = [
        (name: "Rectangle (1)", symbol: "rectangle"),
        (name: "Diamond (2)", symbol: "diamond"),
        (name: "Ellipse (3)", symbol: "circle")
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(kind: kind)
    }

    func makeUIView(context: Context) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 2

        let control: UIView
        switch kind {
        case .segmented:
            let actions = choices.enumerated().map { index, choice in
                UIAction(title: choice.name, image: segmentImage(symbol: choice.symbol, number: index + 1)) { _ in }
            }
            let segmented = UISegmentedControl(frame: .zero, actions: actions)
            segmented.isMomentary = false
            segmented.selectedSegmentIndex = 0
            let transparent = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
            for left: UIControl.State in [.normal, .selected] {
                for right: UIControl.State in [.normal, .selected] {
                    segmented.setDividerImage(transparent, forLeftSegmentState: left, rightSegmentState: right, barMetrics: .default)
                }
            }
            segmented.addTarget(context.coordinator, action: #selector(Coordinator.segmentChanged(_:)), for: .valueChanged)
            control = segmented
        case .tabbar:
            let tabbar = UITabBar()
            tabbar.itemPositioning = .fill
            tabbar.items = choices.enumerated().map { index, choice in
                let item = UITabBarItem(title: String(index + 1), image: UIImage(systemName: choice.symbol), tag: index)
                item.accessibilityLabel = choice.name
                return item
            }
            tabbar.selectedItem = tabbar.items?.first
            tabbar.delegate = context.coordinator
            control = tabbar
        }
        control.accessibilityIdentifier = "toolbarNativeControlProbe.control"
        control.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stack.addArrangedSubview(control)

        let trace = UILabel()
        trace.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        trace.textAlignment = .center
        trace.accessibilityIdentifier = "toolbarNativeControlProbe.trace"
        context.coordinator.trace = trace
        context.coordinator.showInitialSelection()
        stack.addArrangedSubview(trace)
        return stack
    }

    func updateUIView(_ uiView: UIStackView, context: Context) {
        // Preserve the native control's tracking and selection during view updates.
    }

    private func segmentImage(symbol: String, number: Int) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 28, height: 30)).image { _ in
            UIImage(systemName: symbol)?.withTintColor(.black).draw(in: CGRect(x: 5, y: 0, width: 18, height: 18))
            let text = String(number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 9),
                .foregroundColor: UIColor.black
            ]
            let width = text.size(withAttributes: attributes).width
            text.draw(at: CGPoint(x: (28 - width) / 2, y: 20), withAttributes: attributes)
        }.withRenderingMode(.alwaysTemplate)
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        private let kind: Kind
        private var commits = 0
        weak var trace: UILabel?

        init(kind: Kind) {
            self.kind = kind
        }

        func showInitialSelection() {
            show(index: 0)
        }

        @objc func segmentChanged(_ sender: UISegmentedControl) {
            commits += 1
            show(index: sender.selectedSegmentIndex)
        }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            commits += 1
            show(index: item.tag)
        }

        private func show(index: Int) {
            trace?.text = "\(kind.rawValue): selected=\(index + 1); commits=\(commits)"
        }
    }
}
#endif
