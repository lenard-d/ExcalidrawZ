#if os(iOS)
import UIKit
import WebKit
import XCTest
@testable import ExcalidrawZ

@MainActor
final class ToolbarKeyboardCommandTests: XCTestCase {
    func testNumberCommandsSelectTheConfiguredOrderAfterReload() throws {
        var order = ExcalidrawToolbarToolOrder()
        order.move(from: IndexSet(integer: 3), to: 6)
        let restored = ExcalidrawToolbarToolOrder(storedData: order.storedData)
        var selectedTools: [ExcalidrawTool] = []
        let webView = makeWebView { key in
            if case .number(let number) = key,
               let tool = restored.tool(forShortcutNumber: number) {
                selectedTools.append(tool)
            }
        }

        for input in ["6", "4", "0"] {
            let command = try numberCommand(input, in: webView)
            webView.perform(command.action, with: command)
        }

        XCTAssertEqual(selectedTools, [.ellipse, .arrow, .eraser])
    }

    func testCachedCommandCannotChangeToolsDuringTextEntry() throws {
        var dispatchCount = 0
        let webView = makeWebView { _ in dispatchCount += 1 }
        let command = try numberCommand("4", in: webView)

        webView.shouldHandleInput = false

        XCTAssertFalse(webView.canPerformAction(try XCTUnwrap(command.action), withSender: command))
        XCTAssertFalse(webView.keyCommands?.contains { $0.action == command.action } ?? false)
        webView.perform(command.action, with: command)
        XCTAssertEqual(dispatchCount, 0)

        webView.shouldHandleInput = true
        webView.perform(command.action, with: command)
        XCTAssertEqual(dispatchCount, 1)
    }

    func testCachedCommandCannotChangeToolsWhenCanvasIsInactive() throws {
        var dispatchCount = 0
        let webView = makeWebView { _ in dispatchCount += 1 }
        let command = try numberCommand("4", in: webView)

        webView.nativeInteractionEnabled = false

        XCTAssertFalse(webView.canPerformAction(try XCTUnwrap(command.action), withSender: command))
        webView.perform(command.action, with: command)
        XCTAssertEqual(dispatchCount, 0)
    }

    func testModifiedAndInvalidCommandsDoNotChangeTools() throws {
        var dispatchCount = 0
        let webView = makeWebView { _ in dispatchCount += 1 }
        let command = try numberCommand("4", in: webView)
        let action = try XCTUnwrap(command.action)

        for modifiers: UIKeyModifierFlags in [.command, .control, .alternate, .shift] {
            let modified = UIKeyCommand(input: "4", modifierFlags: modifiers, action: action)
            webView.perform(modified.action, with: modified)
        }
        for input in ["", "11", "x"] {
            let invalid = UIKeyCommand(input: input, modifierFlags: [], action: action)
            webView.perform(invalid.action, with: invalid)
        }

        XCTAssertEqual(dispatchCount, 0)
        XCTAssertFalse(command.wantsPriorityOverSystemBehavior)
    }

    private func numberCommand(_ input: String, in webView: ExcalidrawWebView) throws -> UIKeyCommand {
        try XCTUnwrap(webView.keyCommands?.first { $0.input == input && $0.modifierFlags.isEmpty })
    }

    private func makeWebView(
        handler: @escaping (ExcalidrawWebView.ToolbarActionKey) -> Void
    ) -> ExcalidrawWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return ExcalidrawWebView(frame: .zero, configuration: configuration, toolbarActionHandler: handler)
    }
}
#endif
