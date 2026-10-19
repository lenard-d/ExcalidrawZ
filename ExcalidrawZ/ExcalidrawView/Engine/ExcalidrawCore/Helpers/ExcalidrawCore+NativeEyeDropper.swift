//
//  ExcalidrawCore+NativeEyeDropper.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/08/17.
//

import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension ExcalidrawCore {
    struct NativeEyeDropperRequest: Codable, Sendable {
        let requestId: String
        let colorPickerType: String?
        let theme: String?
    }

    struct CancelNativeEyeDropperRequest: Codable, Sendable {
        let requestId: String
        let reason: String?
    }

    struct NativeEyeDropperCompletion: Encodable, Sendable {
        let requestId: String
        var color: String?
        var cancelled: Bool?

        static func selected(requestId: String, color: String) -> Self {
            Self(requestId: requestId, color: color, cancelled: nil)
        }

        static func cancelled(requestId: String) -> Self {
            Self(requestId: requestId, color: nil, cancelled: true)
        }
    }

    @MainActor
    func setNativeEyeDropperEnabled(_ enabled: Bool) async throws {
        _ = try await webView.callAsyncJavaScript(
            "window.excalidrawZHelper.setNativeEyeDropperEnabled(enabled);",
            arguments: ["enabled": enabled],
            contentWorld: .page
        )
    }

    @MainActor
    func completeNativeEyeDropper(_ completion: NativeEyeDropperCompletion) async throws {
        let payload = try encodeJSON(completion)
        _ = try await webView.callAsyncJavaScript(
            "window.excalidrawZHelper.completeNativeEyeDropper(\(payload));",
            arguments: [:],
            contentWorld: .page
        )
    }
}

final class ExcalidrawNativeEyeDropperCoordinator: NSObject {
    private weak var core: ExcalidrawCore?
    private var activeRequest: ExcalidrawCore.NativeEyeDropperRequest?
    private let onComplete: @MainActor (ExcalidrawCore.NativeEyeDropperCompletion) async throws -> Void

#if os(macOS)
    private let sampleColor: @MainActor () async -> NSColor?
#elseif os(iOS)
    private var colorPicker: UIColorPickerViewController?
    private var didSelectColor = false
#endif

    init(core: ExcalidrawCore) {
        self.core = core
        self.onComplete = { [weak core] completion in
            try await core?.completeNativeEyeDropper(completion)
        }
#if os(macOS)
        self.sampleColor = {
            await NSColorSampler().sample()
        }
#endif
        super.init()
    }

#if os(macOS)
    init(
        sampleColor: @escaping @MainActor () async -> NSColor?,
        onComplete: @escaping @MainActor (ExcalidrawCore.NativeEyeDropperCompletion) async throws -> Void
    ) {
        self.sampleColor = sampleColor
        self.onComplete = onComplete
        super.init()
    }
#endif

    @MainActor
    func request(_ request: ExcalidrawCore.NativeEyeDropperRequest) async {
#if os(iOS)
        if let colorPicker {
            colorPicker.delegate = nil
            colorPicker.dismiss(animated: false)
            self.colorPicker = nil
        }
#endif
        let previousRequest = activeRequest
        activeRequest = request
        if let previousRequest {
            await send(.cancelled(requestId: previousRequest.requestId))
        }
        guard activeRequest?.requestId == request.requestId else { return }

#if os(macOS)
        let color = await sampleColor()
        guard activeRequest?.requestId == request.requestId else {
            return
        }
        guard let color,
              let hex = Self.sRGBHex(color) else {
            await complete(.cancelled(requestId: request.requestId))
            return
        }
        await complete(.selected(requestId: request.requestId, color: hex))
#elseif os(iOS)
        guard let presenter = presentationViewController() else {
            core?.logger.warning("Unable to present native eye dropper without an active view controller")
            await complete(.cancelled(requestId: request.requestId))
            return
        }

        didSelectColor = false
        let picker = UIColorPickerViewController()
        picker.delegate = self
        picker.supportsAlpha = false
        switch request.theme {
            case "dark":
                picker.overrideUserInterfaceStyle = .dark
            case "light":
                picker.overrideUserInterfaceStyle = .light
            default:
                picker.overrideUserInterfaceStyle = .unspecified
        }
        colorPicker = picker
        presenter.present(picker, animated: true)
#endif
    }

    @MainActor
    func cancel(requestId: String) {
        guard activeRequest?.requestId == requestId else { return }
        // The web request is already settled. Do not echo a completion back to it.
        invalidate()
    }

    @MainActor
    func invalidate() {
        activeRequest = nil
#if os(macOS)
        // AppKit retains the sampler until it ends and offers no cancel method.
        // Its eventual result is ignored after the request is cleared.
#elseif os(iOS)
        colorPicker?.delegate = nil
        colorPicker?.dismiss(animated: false)
        colorPicker = nil
        didSelectColor = false
#endif
    }

    @MainActor
    private func complete(_ completion: ExcalidrawCore.NativeEyeDropperCompletion) async {
        guard activeRequest?.requestId == completion.requestId else { return }
        activeRequest = nil
        await send(completion)
    }

    @MainActor
    private func send(_ completion: ExcalidrawCore.NativeEyeDropperCompletion) async {
        do {
            try await onComplete(completion)
        } catch {
            core?.logger.warning("Failed to complete native eye dropper request \(completion.requestId): \(error)")
        }
    }

#if os(macOS)
    private static func sRGBHex(_ color: NSColor) -> String? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        return hex(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent
        )
    }
#elseif os(iOS)
    @MainActor
    private func presentationViewController() -> UIViewController? {
        let rootViewController = core?.webView.window?.rootViewController
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .rootViewController
        return rootViewController?.nativeEyeDropperTopmostViewController
    }

    private static func sRGBHex(_ color: UIColor) -> String? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.cgColor.converted(
                to: colorSpace,
                intent: .defaultIntent,
                options: nil
              ),
              let components = converted.components,
              components.count >= 3 else {
            return nil
        }
        return hex(red: components[0], green: components[1], blue: components[2])
    }
#endif

    private static func hex(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        let component: (CGFloat) -> Int = { value in
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            component(red),
            component(green),
            component(blue)
        )
    }
}

#if os(iOS)
extension ExcalidrawNativeEyeDropperCoordinator: UIColorPickerViewControllerDelegate {
    @MainActor
    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        guard viewController === colorPicker else { return }
        didSelectColor = true
    }

    @MainActor
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        guard viewController === colorPicker,
              let request = activeRequest else {
            return
        }
        colorPicker = nil
        guard didSelectColor,
              let hex = Self.sRGBHex(viewController.selectedColor) else {
            Task { @MainActor in
                await complete(.cancelled(requestId: request.requestId))
            }
            return
        }
        Task { @MainActor in
            await complete(.selected(requestId: request.requestId, color: hex))
        }
    }
}

private extension UIViewController {
    var nativeEyeDropperTopmostViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.nativeEyeDropperTopmostViewController
        }
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.nativeEyeDropperTopmostViewController
        }
        if let tabBarController = self as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return selectedViewController.nativeEyeDropperTopmostViewController
        }
        return self
    }
}
#endif
